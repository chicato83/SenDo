import Foundation

// MARK: - NUT Protocol Client

/// Client for communicating with the NUT server on Switch via USB
/// Implements the HTTP-like protocol used by Tinfoil/Awoo-Installer/Sphaira
final class NUTClient {
    private let transfer: USBTransfer
    
    init(device: USBDevice) throws {
        self.transfer = USBTransfer(device: device)
        try transfer.configure()
    }
    
    // MARK: - API Methods
    
    /// List available titles/files on the PC that can be installed
    func searchFiles() throws -> [NUTFile] {
        let response = try transfer.sendRequest(path: "/api/search")
        guard let json = try? JSONSerialization.jsonObject(with: response) as? [[String: Any]] else {
            throw NUTError.invalidResponse
        }
        
        return json.compactMap { NUTFile(json: $0) }
    }
    
    /// Get directory listing
    func listDirectory(path: String = "") throws -> NUTDirectory {
        let urlPath = path.isEmpty ? "/api/directoryList" : "/api/directoryList/\(path)"
        let response = try transfer.sendRequest(path: urlPath)
        
        guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw NUTError.invalidResponse
        }
        
        return NUTDirectory(json: json)
    }
    
    /// Get title information
    func getTitles() throws -> [NUTTitle] {
        let response = try transfer.sendRequest(path: "/api/titles")
        guard let json = try? JSONSerialization.jsonObject(with: response) as? [[String: Any]] else {
            throw NUTError.invalidResponse
        }
        
        return json.compactMap { NUTTitle(json: $0) }
    }
    
    /// Download a file by title ID
    func downloadFile(titleId: String, progressHandler: @escaping (Int64, Int64) -> Void) throws -> Data {
        let path = "/api/download/\(titleId)"
        
        // Send initial request
        let response = try transfer.sendRequest(path: path)
        
        // For large files, we need to handle chunked transfer
        // The NUT protocol supports range requests
        var allData = Data()
        let chunkSize: Int64 = 4 * 1024 * 1024 // 4MB chunks
        var offset: Int64 = 0
        
        // Parse initial response to get total size
        if let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
           let size = json["size"] as? Int64 {
            // Range-based download
            while offset < size {
                let end = min(offset + chunkSize - 1, size - 1)
                let rangePath = "\(path)/\(offset)/\(end + 1)"
                let chunkData = try transfer.sendRequest(path: rangePath)
                allData.append(chunkData)
                offset += Int64(chunkData.count)
                progressHandler(offset, size)
            }
        } else {
            // Direct data response
            allData = response
            progressHandler(Int64(response.count), Int64(response.count))
        }
        
        return allData
    }
    
    /// Get file size and metadata
    func getFileInfo(path: String) throws -> NUTFileInfo {
        let response = try transfer.sendRequest(path: "/api/fileSize/\(path)")
        guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw NUTError.invalidResponse
        }
        
        return NUTFileInfo(json: json)
    }
    
    /// Check for title updates
    func getTitleUpdates() throws -> [String: NUTTitleUpdate] {
        let response = try transfer.sendRequest(path: "/api/titleUpdates")
        guard let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw NUTError.invalidResponse
        }
        
        var updates: [String: NUTTitleUpdate] = [:]
        for (key, value) in json {
            if let updateJson = value as? [String: Any] {
                updates[key] = NUTTitleUpdate(json: updateJson)
            }
        }
        return updates
    }
}

// MARK: - NUT Models

struct NUTFile: Identifiable {
    let id: String
    let name: String
    let size: Int64
    let version: Int?
    
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String else {
            return nil
        }
        
        self.id = id
        self.name = name
        self.size = json["size"] as? Int64 ?? 0
        self.version = json["version"] as? Int
    }
}

struct NUTDirectory {
    let directories: [NUTDirEntry]
    let files: [NUTFileEntry]
    
    init(json: [String: Any]) {
        self.directories = (json["dirs"] as? [[String: Any]] ?? []).compactMap { NUTDirEntry(json: $0) }
        self.files = (json["files"] as? [[String: Any]] ?? []).compactMap { NUTFileEntry(json: $0) }
    }
}

struct NUTDirEntry: Identifiable {
    let id: String
    let name: String
    
    init?(json: [String: Any]) {
        guard let name = json["name"] as? String else { return nil }
        self.id = name
        self.name = name
    }
}

struct NUTFileEntry: Identifiable {
    let id: String
    let name: String
    let size: Int64
    let modified: Date?
    
    init?(json: [String: Any]) {
        guard let name = json["name"] as? String else { return nil }
        self.id = name
        self.name = name
        self.size = json["size"] as? Int64 ?? 0
        
        if let mtime = json["mtime"] as? TimeInterval {
            self.modified = Date(timeIntervalSince1970: mtime)
        } else {
            self.modified = nil
        }
    }
}

struct NUTTitle: Identifiable {
    let id: String
    let name: String
    let version: String?
    let size: Int64?
    
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        self.name = json["name"] as? String ?? "Unknown"
        self.version = json["version"] as? String
        self.size = json["size"] as? Int64
    }
}

struct NUTFileInfo {
    let size: Int64
    let modified: Date?
    
    init(json: [String: Any]) {
        self.size = json["size"] as? Int64 ?? 0
        if let mtime = json["mtime"] as? TimeInterval {
            self.modified = Date(timeIntervalSince1970: mtime)
        } else {
            self.modified = nil
        }
    }
}

struct NUTTitleUpdate {
    let id: String
    let version: String?
    let size: Int64?
    
    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        self.version = json["version"] as? String
        self.size = json["size"] as? Int64
    }
}

// MARK: - NUT Error

enum NUTError: LocalizedError {
    case invalidResponse
    case connectionFailed
    case fileNotFound
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Switch"
        case .connectionFailed:
            return "Failed to connect to Switch"
        case .fileNotFound:
            return "File not found on Switch"
        }
    }
}
