import Foundation

/// Simple file logger for debugging - writes to /tmp/sendo.log
enum SenDoLog {
    private static let logFile = URL(fileURLWithPath: "/tmp/sendo.log")
    
    static func setup() {
        // Clear old log
        try? "".write(to: logFile, atomically: true, encoding: .utf8)
        log("SenDo logger started")
    }
    
    static func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let loc = "\(fileName):\(line)"
        let msg = "[\(timestamp)] [\(loc)] \(function) — \(message)\n"
        
        // Synchronous write for reliable debugging
        if let data = msg.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: logFile) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.synchronizeFile()
                fh.closeFile()
            }
        }
    }
}
