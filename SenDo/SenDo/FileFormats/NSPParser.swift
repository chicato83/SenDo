import Foundation

// MARK: - NSP Parser

/// Parses Nintendo Submission Package (NSP) files
struct NSPParser {
    /// Parse NSP file header and extract metadata
    static func parse(fileURL: URL) throws -> NSPMetadata {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { fileHandle.closeFile() }
        
        // Read PFS0 header
        let headerData = fileHandle.readData(ofLength: 16)
        guard headerData.count >= 16 else {
            throw FileParseError.invalidHeader
        }
        
        // Verify magic "PFS0"
        let magic = headerData.subdata(in: 0..<4)
        guard magic == "PFS0".data(using: .ascii) else {
            throw FileParseError.invalidMagic
        }
        
        // Number of files
        let numFiles = headerData.subdata(in: 4..<8).withUnsafeBytes {
            $0.load(as: UInt32.self)
        }
        
        // String table size
        let stringTableSize = headerData.subdata(in: 8..<12).withUnsafeBytes {
            $0.load(as: UInt32.self)
        }
        
        // Read file entries
        var files: [NSPFileEntry] = []
        var titleId: String?
        var titleName: String?
        
        for _ in 0..<numFiles {
            let entryData = fileHandle.readData(ofLength: 24)
            guard entryData.count >= 24 else {
                throw FileParseError.invalidEntry
            }
            
            let offset = entryData.subdata(in: 0..<8).withUnsafeBytes {
                $0.load(as: UInt64.self)
            }
            
            let size = entryData.subdata(in: 8..<16).withUnsafeBytes {
                $0.load(as: UInt64.self)
            }
            
            let nameOffset = entryData.subdata(in: 16..<20).withUnsafeBytes {
                $0.load(as: UInt32.self)
            }
            
            let _ = entryData.subdata(in: 20..<24).withUnsafeBytes {
                $0.load(as: UInt32.self)
            }
            
            // Read string table to get filename
            let currentPos = fileHandle.offsetInFile
            fileHandle.seek(toFileOffset: UInt64(16 + Int(numFiles) * 24) + UInt64(nameOffset))
            let nameData = fileHandle.readData(ofLength: Int(stringTableSize) - Int(nameOffset))
            let name = String(data: nameData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "unknown"
            fileHandle.seek(toFileOffset: currentPos)
            
            let entry = NSPFileEntry(
                name: name,
                offset: offset,
                size: size
            )
            files.append(entry)
            
            // Try to extract title info from NCA files
            if name.hasSuffix(".nca") || name.hasSuffix(".ncz") {
                // NCA contains title metadata
                // We'll parse it in a more complete implementation
            }
        }
        
        // Try to read CNMT for title info
        for entry in files where entry.name.hasSuffix("cnmt.nca") {
            fileHandle.seek(toFileOffset: entry.offset)
            let ncaData = fileHandle.readData(ofLength: min(Int(entry.size), 1024))
            
            if let cnmt = parseCNMT(from: ncaData) {
                titleId = cnmt.titleId
                titleName = cnmt.titleName
            }
        }
        
        return NSPMetadata(
            fileURL: fileURL,
            titleId: titleId ?? "Unknown",
            titleName: titleName ?? fileURL.deletingPathExtension().lastPathComponent,
            fileSize: try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            files: files,
            isCompressed: false
        )
    }
    
    private static func parseCNMT(from data: Data) -> (titleId: String, titleName: String)? {
        // Simplified CNMT parsing
        // In a full implementation, this would parse the ContentMetaBinary
        guard data.count >= 16 else { return nil }
        
        // Title ID is at offset 0 (8 bytes)
        let titleIdData = data.subdata(in: 0..<8)
        let titleId = titleIdData.map { String(format: "%02x", $0) }.joined()
        
        return (titleId: titleId, titleName: "Game")
    }
}

// MARK: - XCI Parser

/// Parses GameCard Image (XCI) files
struct XCIParser {
    /// Parse XCI file header and extract metadata
    static func parse(fileURL: URL) throws -> XCIMetadata {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { fileHandle.closeFile() }
        
        // Read XCI header
        let headerData = fileHandle.readData(ofLength: 512)
        guard headerData.count >= 512 else {
            throw FileParseError.invalidHeader
        }
        
        // Verify magic "HEAD"
        let magic = headerData.subdata(in: 0..<4)
        guard magic == "HEAD".data(using: .ascii) else {
            throw FileParseError.invalidMagic
        }
        
        // Title ID at offset 0x100 (256)
        let titleIdData = headerData.subdata(in: 0x100..<0x108)
        let titleId = titleIdData.map { String(format: "%02x", $0) }.joined()
        
        // Gamecard size at offset 0x118
        let gcSize = headerData.subdata(in: 0x118..<0x120).withUnsafeBytes {
            $0.load(as: UInt64.self)
        }
        
        // HFS0 offset at offset 0x170
        let hfs0Offset = headerData.subdata(in: 0x170..<0x178).withUnsafeBytes {
            $0.load(as: UInt64.self)
        }
        
        // Parse HFS0 (Header File System 0)
        fileHandle.seek(toFileOffset: hfs0Offset)
        let hfs0Header = fileHandle.readData(ofLength: 16)
        
        let numFiles = hfs0Header.subdata(in: 4..<8).withUnsafeBytes {
            $0.load(as: UInt32.self)
        }
        
        let stringTableSize = hfs0Header.subdata(in: 8..<12).withUnsafeBytes {
            $0.load(as: UInt32.self)
        }
        
        var files: [XCIFileEntry] = []
        
        for _ in 0..<numFiles {
            let entryData = fileHandle.readData(ofLength: 64)
            guard entryData.count >= 64 else { break }
            
            let nameOffset = entryData.subdata(in: 0..<4).withUnsafeBytes {
                $0.load(as: UInt32.self)
            }
            
            let offset = entryData.subdata(in: 8..<16).withUnsafeBytes {
                $0.load(as: UInt64.self)
            }
            
            let size = entryData.subdata(in: 16..<24).withUnsafeBytes {
                $0.load(as: UInt64.self)
            }
            
            // Read name from string table
            let currentPos = fileHandle.offsetInFile
            fileHandle.seek(toFileOffset: hfs0Offset + 16 + UInt64(numFiles) * 64 + UInt64(nameOffset))
            let nameData = fileHandle.readData(ofLength: min(256, Int(stringTableSize) - Int(nameOffset)))
            let name = String(data: nameData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "unknown"
            fileHandle.seek(toFileOffset: currentPos)
            
            files.append(XCIFileEntry(
                name: name,
                offset: hfs0Offset + offset,
                size: size
            ))
        }
        
        return XCIMetadata(
            fileURL: fileURL,
            titleId: titleId,
            titleName: fileURL.deletingPathExtension().lastPathComponent,
            fileSize: try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            gamecardSize: gcSize,
            files: files
        )
    }
}

// MARK: - Metadata Types

struct NSPMetadata {
    let fileURL: URL
    let titleId: String
    let titleName: String
    let fileSize: Int
    let files: [NSPFileEntry]
    let isCompressed: Bool
}

struct XCIMetadata {
    let fileURL: URL
    let titleId: String
    let titleName: String
    let fileSize: Int
    let gamecardSize: UInt64
    let files: [XCIFileEntry]
}

struct NSPFileEntry {
    let name: String
    let offset: UInt64
    let size: UInt64
}

struct XCIFileEntry {
    let name: String
    let offset: UInt64
    let size: UInt64
}

// MARK: - Parse Errors

enum FileParseError: LocalizedError {
    case invalidHeader
    case invalidMagic
    case invalidEntry
    case fileNotFound
    
    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "Invalid file header"
        case .invalidMagic:
            return "Invalid file magic bytes"
        case .invalidEntry:
            return "Invalid file entry"
        case .fileNotFound:
            return "File not found"
        }
    }
}
