import Foundation

// MARK: - NSZ/XCZ Decompressor

/// Handles decompression of NSZ (compressed NSP) and XCZ (compressed XCI) files
struct NSZDecompressor {
    
    /// Decompress an NSZ file to NSP format
    static func decompressNSZ(inputURL: URL, outputURL: URL, progressHandler: @escaping (Double) -> Void) throws {
        let fileHandle = try FileHandle(forReadingFrom: inputURL)
        defer { fileHandle.closeFile() }
        
        // Read NSZ header
        let headerData = fileHandle.readData(ofLength: 16)
        guard headerData.count >= 16 else {
            throw DecompressionError.invalidHeader
        }
        
        // Verify NSZ magic
        let magic = headerData.subdata(in: 0..<4)
        guard magic == "NSZ0".data(using: .ascii) else {
            throw DecompressionError.invalidMagic
        }
        
        // Get compressed block count
        let blockCount = headerData.subdata(in: 4..<8).withUnsafeBytes {
            $0.load(as: UInt32.self)
        }
        
        // Get original size
        let originalSize = headerData.subdata(in: 8..<16).withUnsafeBytes {
            $0.load(as: UInt64.self)
        }
        
        // Create output file
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { outputHandle.closeFile() }
        
        var totalDecompressed: UInt64 = 0
        let totalSize = UInt64(originalSize)
        
        // Read and decompress blocks
        for _ in 0..<blockCount {
            // Read block header (16 bytes)
            let blockHeader = fileHandle.readData(ofLength: 16)
            guard blockHeader.count >= 16 else {
                throw DecompressionError.invalidBlock
            }
            
            let compressedSize = blockHeader.subdata(in: 0..<8).withUnsafeBytes {
                $0.load(as: UInt64.self)
            }
            
            let decompressedSize = blockHeader.subdata(in: 8..<16).withUnsafeBytes {
                $0.load(as: UInt64.self)
            }
            
            // Read compressed data
            let compressedData = fileHandle.readData(ofLength: Int(compressedSize))
            guard compressedData.count == Int(compressedSize) else {
                throw DecompressionError.truncatedData
            }
            
            // For now, just write the compressed data
            // In a real implementation, we'd decompress using zlib
            // This is a placeholder that will be replaced with actual decompression
            outputHandle.write(compressedData)
            
            totalDecompressed += UInt64(compressedData.count)
            let progress = Double(totalDecompressed) / Double(totalSize)
            progressHandler(min(progress, 1.0))
        }
        
        progressHandler(1.0)
    }
    
    /// Decompress an XCZ file to XCI format
    static func decompressXCZ(inputURL: URL, outputURL: URL, progressHandler: @escaping (Double) -> Void) throws {
        let fileHandle = try FileHandle(forReadingFrom: inputURL)
        defer { fileHandle.closeFile() }
        
        // Read XCZ header
        let headerData = fileHandle.readData(ofLength: 16)
        guard headerData.count >= 16 else {
            throw DecompressionError.invalidHeader
        }
        
        // Verify XCZ magic
        let magic = headerData.subdata(in: 0..<4)
        guard magic == "XCZ0".data(using: .ascii) else {
            throw DecompressionError.invalidMagic
        }
        
        // Get compressed block count
        let blockCount = headerData.subdata(in: 4..<8).withUnsafeBytes {
            $0.load(as: UInt32.self)
        }
        
        // Get original size
        let originalSize = headerData.subdata(in: 8..<16).withUnsafeBytes {
            $0.load(as: UInt64.self)
        }
        
        // Create output file
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { outputHandle.closeFile() }
        
        var totalDecompressed: UInt64 = 0
        let totalSize = UInt64(originalSize)
        
        // Read and decompress blocks
        for _ in 0..<blockCount {
            // Read block header (16 bytes)
            let blockHeader = fileHandle.readData(ofLength: 16)
            guard blockHeader.count >= 16 else {
                throw DecompressionError.invalidBlock
            }
            
            let compressedSize = blockHeader.subdata(in: 0..<8).withUnsafeBytes {
                $0.load(as: UInt64.self)
            }
            
            let decompressedSize = blockHeader.subdata(in: 8..<16).withUnsafeBytes {
                $0.load(as: UInt64.self)
            }
            
            // Read compressed data
            let compressedData = fileHandle.readData(ofLength: Int(compressedSize))
            guard compressedData.count == Int(compressedSize) else {
                throw DecompressionError.truncatedData
            }
            
            // For now, just write the compressed data
            // In a real implementation, we'd decompress using zlib
            outputHandle.write(compressedData)
            
            totalDecompressed += UInt64(compressedData.count)
            let progress = Double(totalDecompressed) / Double(totalSize)
            progressHandler(min(progress, 1.0))
        }
        
        progressHandler(1.0)
    }
    
    /// Check if a file is compressed (NSZ or XCZ)
    static func isCompressed(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "nsz" || ext == "xcz"
    }
    
    /// Get the expected output format for a compressed file
    static func outputFormat(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "nsz":
            return "nsp"
        case "xcz":
            return "xci"
        default:
            return ext
        }
    }
}

// MARK: - Decompression Error

enum DecompressionError: LocalizedError {
    case invalidHeader
    case invalidMagic
    case invalidBlock
    case truncatedData
    case decompressionFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "Invalid compressed file header"
        case .invalidMagic:
            return "Invalid compressed file magic bytes"
        case .invalidBlock:
            return "Invalid compressed block"
        case .truncatedData:
            return "Compressed data is truncated"
        case .decompressionFailed:
            return "Failed to decompress data"
        }
    }
}
