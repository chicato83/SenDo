import Foundation

/// Simple file logger for debugging - writes to /tmp/sendo.log
///
/// Bounded and serialized: once the file reaches `maxBytes` it is rotated to
/// `/tmp/sendo.log.1` (replacing the previous one), so a runaway session
/// cannot fill the disk (W4). Every line is still written synchronously with
/// an fsync — that is what makes the log trustworthy after a crash.
enum SenDoLog {
    private static let logFile = URL(fileURLWithPath: "/tmp/sendo.log")
    private static let previousLogFile = URL(fileURLWithPath: "/tmp/sendo.log.1")
    /// Cap of a single log file before it is rotated away.
    private static let maxBytes: Int64 = 4 * 1024 * 1024
    /// Serializes every writer AND the size bookkeeping.
    private static let lock = NSLock()
    /// Bytes written so far; `-1` until the existing file has been measured.
    private static var currentSize: Int64 = -1

    static func setup() {
        lock.lock()
        defer { lock.unlock() }
        // Clear old log
        try? "".write(to: logFile, atomically: true, encoding: .utf8)
        currentSize = 0
        logUnlocked("SenDo logger started")
    }

    static func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        lock.lock()
        defer { lock.unlock() }
        logUnlocked(message, file: file, function: function, line: line)
    }

    private static func logUnlocked(
        _ message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let loc = "\(fileName):\(line)"
        let msg = "[\(timestamp)] [\(loc)] \(function) — \(message)\n"

        guard let data = msg.data(using: .utf8) else { return }
        measureIfNeeded()

        // Rotate before this line would push the file past its cap. `currentSize
        // > 0` keeps a single oversized line from rotating an empty file forever.
        if currentSize > 0 && currentSize + Int64(data.count) > maxBytes {
            rotate()
        }

        // Synchronous write for reliable debugging
        if let fh = try? FileHandle(forWritingTo: logFile) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.synchronizeFile()
            fh.closeFile()
            currentSize += Int64(data.count)
        }
    }

    /// Measures the existing log once, so rotation keeps its budget correct
    /// even when `log()` runs before `setup()`.
    private static func measureIfNeeded() {
        guard currentSize < 0 else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: logFile.path)
        currentSize = (attributes?[.size] as? Int64) ?? 0
    }

    /// Moves the current log aside and starts a fresh one.
    ///
    /// Runs with the lock already held: it writes the marker directly instead
    /// of calling `log()`, which would deadlock on the same lock.
    private static func rotate() {
        let rotatedBytes = currentSize
        try? FileManager.default.removeItem(at: previousLogFile)
        try? FileManager.default.moveItem(at: logFile, to: previousLogFile)
        _ = FileManager.default.createFile(atPath: logFile.path, contents: nil)
        currentSize = 0

        let marker = "[\(ISO8601DateFormatter().string(from: Date()))] [SenDoLog.swift] rotated — previous log (\(rotatedBytes) bytes) kept at /tmp/sendo.log.1\n"
        if let data = marker.data(using: .utf8), let fh = try? FileHandle(forWritingTo: logFile) {
            fh.write(data)
            fh.synchronizeFile()
            fh.closeFile()
            currentSize = Int64(data.count)
        }
    }
}
