import Foundation

// MARK: - Sphaira Protocol Server

/// Mac-side implementation of the Sphaira USB install protocol.
///
/// The Mac is the SERVER and the Switch is the CLIENT — this is a PULL protocol.
/// The Switch initiates every step, so the Mac always waits to receive first and
/// never sends an unsolicited packet.
///
/// Flow (verified against `tools/usb_install.py`, `tools/usb_export.py` and
/// `sphaira/source/usb/usb_installer.cpp` / `usb_dumper.cpp`):
///  1. Mac reads the session-opening 24-byte SendPacket and latches the mode
///     from `arg2` (0 -> install, 1 -> export) because `CMD_OPEN` and
///     `CMD_EXPORT` share the value 1.
///  2. INSTALL: Mac writes `ResultPacket(result=0, arg3=stringTableLength, arg4=0)`
///     then the raw string table (UTF-8 names joined by "\n" with a trailing "\n").
///     Loop: read SendPacket.
///     - `CMD_QUIT`  -> write `ResultPacket(0,0,0)` and stop cleanly.
///     - `CMD_OPEN`  -> write the file info result, then serve chunk requests until
///                      the Switch sends `SendDataPacket(offset=0, size=0)` (CloseFile).
///     - anything else -> write `ResultPacket(1,0,0)` and stop.
///  3. EXPORT: ack the header, read the announced path, sanitise it against the
///     backup root, then receive `SendDataPacket` chunks (CRC32C verified) until
///     `SendDataPacket(0,0,0)`; `CMD_QUIT` closes the session.
///
/// Marked `@unchecked Sendable` because the instance is created on one thread and
/// then driven exclusively from the caller's background serve queue. Callers must
/// not run two `serve(files:)` sessions concurrently.
final class SphairaClient: @unchecked Sendable {
    /// Strong reference to the USB device — prevents deallocation which would
    /// free the raw interface pointer held by USBTransfer, causing EXC_BAD_ACCESS.
    private let device: USBDevice
    private let transfer: USBTransfer

    init(device: USBDevice) throws {
        SenDoLog.log("SphairaClient: running protocol self-test...")
        guard SPHPacket.runSelfTest() else {
            throw USBTransferError.protocolError("Sphaira protocol self-test failed — see log")
        }

        SenDoLog.log("SphairaClient: Opening device...")
        // Must open the device before accessing its interface
        try device.open()
        SenDoLog.log("SphairaClient: Creating USB transfer...")
        self.device = device  // retain to keep interface alive
        self.transfer = USBTransfer(device: device)
        SenDoLog.log("SphairaClient: Configuring USB endpoints...")
        try transfer.configure()
        SenDoLog.log("SphairaClient: Ready!")
    }

    /// Blocking server loop. Call from a background thread.
    ///
    /// The FIRST packet of the session latches the mode, because `CMD_OPEN` and
    /// `CMD_EXPORT` share the wire value 1 and would otherwise be ambiguous:
    ///  1. `arg2 == 0` -> INSTALL (the installer handshake uses value 0):
    ///     `ResultPacket(0, stringTableByteCount, 0)` followed by the raw UTF-8
    ///     string table, then the unchanged install command loop. An empty list
    ///     produces a 0-length table, which is valid — the Switch shows no files.
    ///  2. `arg2 == 1` -> EXPORT: `arg3` is the byte length of the incoming
    ///     path. The Mac only RECEIVES; files are written into `backupRoot`.
    ///  3. anything else -> log and close.
    ///
    /// Serves `files` (local Mac paths) for install, and `backupRoot` as the
    /// destination root for export. Reports progress per chunk in both modes.
    func serve(
        files: [URL],
        backupRoot: URL,
        onProgress: @escaping (_ bytesSent: Int64, _ totalBytes: Int64, _ currentFileName: String) -> Void,
        onExportProgress: @escaping (_ bytesReceived: Int64, _ currentFileName: String) -> Void
    ) throws {
        // The Switch speaks first. Wait for it.
        SenDoLog.log("SphairaClient: waiting for the session-opening SendPacket from Switch...")
        let first = try transfer.readPacket(timeout: 15)
        SenDoLog.log(
            String(
                format: "SphairaClient: session packet — arg2(cmd)=0x%08X arg3=0x%08X arg4=0x%08X",
                first.arg2, first.arg3, first.arg4
            )
        )

        switch first.arg2 {
        case SPHProtocol.CMD_QUIT:
            try serveInstall(files: files, onProgress: onProgress)
        case SPHProtocol.CMD_EXPORT:
            try serveExportLoop(firstHeader: first, backupRoot: backupRoot, onExportProgress: onExportProgress)
        default:
            SenDoLog.log("SphairaClient: unknown session-opening command \(first.arg2) — sending RESULT_ERROR and closing")
            try? transfer.sendResult(SPHProtocol.RESULT_ERROR)
            throw SphairaProtocolError.unknownCommand(first.arg2)
        }
    }

    // MARK: - INSTALL mode

    /// Install handshake + command loop. Unchanged behaviour, only reached now
    /// after the mode has been latched from the first packet.
    private func serveInstall(
        files: [URL],
        onProgress: @escaping (_ bytesSent: Int64, _ totalBytes: Int64, _ currentFileName: String) -> Void
    ) throws {
        // Build the string table: UTF-8 file names joined by "\n" with a trailing "\n".
        // An empty list is valid — the Switch shows nothing and then sends CMD_QUIT.
        var stringTable = Data()
        for file in files {
            stringTable.append(contentsOf: file.lastPathComponent.utf8)
            stringTable.append(0x0A)  // "\n"
        }
        SenDoLog.log("SphairaClient: INSTALL mode — serving \(files.count) file(s), string table = \(stringTable.count) bytes")
        if files.isEmpty {
            SenDoLog.log("SphairaClient: file list is EMPTY — Switch will show nothing and should send CMD_QUIT")
        }

        // 2. Result with the string table length in arg3.
        try transfer.sendResult(SPHProtocol.RESULT_OK, arg3: UInt32(stringTable.count), arg4: 0)

        // 3. Raw string table.
        try transfer.write(stringTable)
        SenDoLog.log("SphairaClient: string table sent (\(stringTable.count) bytes)")

        // 4. Command loop.
        while true {
            let packet = try transfer.readPacket(timeout: 600)
            let cmd = packet.arg2

            if cmd == SPHProtocol.CMD_QUIT {
                SenDoLog.log("SphairaClient: received CMD_QUIT — closing session")
                try transfer.sendResult(SPHProtocol.RESULT_OK)
                SenDoLog.log("SphairaClient: session closed cleanly")
                return
            } else if cmd == SPHProtocol.CMD_OPEN {
                let index = Int(packet.arg3)
                SenDoLog.log("SphairaClient: received CMD_OPEN index=\(index) arg4=\(packet.arg4)")
                try serveOpenFile(index: index, files: files, onProgress: onProgress)
            } else {
                SenDoLog.log("SphairaClient: UNKNOWN command \(cmd) — sending RESULT_ERROR and stopping")
                try? transfer.sendResult(SPHProtocol.RESULT_ERROR)
                throw SphairaProtocolError.unknownCommand(cmd)
            }
        }
    }

    // MARK: - EXPORT mode

    /// Export receive loop.
    ///
    /// `firstHeader` is the already-consumed session-opening
    /// `SendPacket(CMD_EXPORT, pathLength)`; every later file starts with a
    /// header read. Per file the wire order is:
    ///  `SendPacket(CMD_EXPORT, pathLength)` -> ack -> raw path -> ack ->
    ///  `SendDataPacket(offset, size, crc)` -> ack -> payload -> ack(OK|ERROR)
    ///  ... -> `SendDataPacket(0,0,0)` -> ack (end of this file).
    /// A header with `arg2 == 0` while no file is open is `CMD_QUIT`.
    private func serveExportLoop(
        firstHeader: SPHPacket,
        backupRoot: URL,
        onExportProgress: @escaping (_ bytesReceived: Int64, _ currentFileName: String) -> Void
    ) throws {
        SenDoLog.log("SphairaClient: EXPORT mode — path length \(firstHeader.arg3), backup root \(backupRoot.path)")
        var pendingHeader: SPHPacket? = firstHeader

        while true {
            let pathLength: Int
            if let header = pendingHeader {
                pendingHeader = nil
                try transfer.sendResult(SPHProtocol.RESULT_OK)  // ack for the session packet
                pathLength = Int(header.arg3)
            } else {
                let header = try transfer.readPacket(timeout: 600)
                if header.arg2 == SPHProtocol.CMD_QUIT {
                    SenDoLog.log("SphairaClient: export session — CMD_QUIT, closing cleanly")
                    try transfer.sendResult(SPHProtocol.RESULT_OK)
                    return
                }
                guard header.arg2 == SPHProtocol.CMD_EXPORT else {
                    SenDoLog.log("SphairaClient: export session — unexpected command \(header.arg2) — sending RESULT_ERROR and closing")
                    try? transfer.sendResult(SPHProtocol.RESULT_ERROR)
                    throw SphairaProtocolError.unknownCommand(header.arg2)
                }
                try transfer.sendResult(SPHProtocol.RESULT_OK)  // ack for the file header
                pathLength = Int(header.arg3)
            }

            // The path is resolved and the file opened BEFORE the second ack, so
            // a rejected path can be reported instead of leaving the Switch
            // streaming into a destination that does not exist.
            guard let destination = try receiveExportPath(pathLength: pathLength, backupRoot: backupRoot) else {
                // RESULT_ERROR already sent — the Switch aborts and retries or quits.
                continue
            }

            defer { try? destination.handle.close() }
            try receiveExportBody(
                handle: destination.handle,
                url: destination.url,
                onExportProgress: onExportProgress
            )
        }
    }

    /// Reads the announced path, sanitises it against `backupRoot`, creates the
    /// parent directories and opens the destination for writing.
    /// Returns `nil` after answering `RESULT_ERROR`.
    private func receiveExportPath(pathLength: Int, backupRoot: URL) throws -> (url: URL, handle: FileHandle)? {
        guard pathLength > 0 else {
            SenDoLog.log("SphairaClient: export path length is 0 — sending RESULT_ERROR")
            try transfer.sendResult(SPHProtocol.RESULT_ERROR)
            return nil
        }

        let rawBytes = try transfer.readExact(pathLength, timeout: 60)
        guard let rawPath = String(data: rawBytes, encoding: .utf8), !rawPath.isEmpty else {
            SenDoLog.log("SphairaClient: export path is empty or not valid UTF-8 — sending RESULT_ERROR")
            try transfer.sendResult(SPHProtocol.RESULT_ERROR)
            return nil
        }

        // The path comes from the Switch: never trust it before sanitising.
        guard let destination = resolveExportDestination(backupRoot: backupRoot, rawPath: rawPath) else {
            SenDoLog.log("SphairaClient: rejected export path \"\(rawPath)\" — sending RESULT_ERROR")
            try transfer.sendResult(SPHProtocol.RESULT_ERROR)
            return nil
        }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Start clean: a previous partial export must not leave stale bytes
            // beyond what this run writes.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                SenDoLog.log("SphairaClient: failed to create \(destination.path) — sending RESULT_ERROR")
                try transfer.sendResult(SPHProtocol.RESULT_ERROR)
                return nil
            }
            let handle = try FileHandle(forWritingTo: destination)
            SenDoLog.log("SphairaClient: export destination \(destination.path)")
            try transfer.sendResult(SPHProtocol.RESULT_OK)
            return (destination, handle)
        } catch {
            SenDoLog.log("SphairaClient: failed to open export destination \(destination.path): \(error)")
            try? transfer.sendResult(SPHProtocol.RESULT_ERROR)
            return nil
        }
    }

    /// Resolves `rawPath` inside `backupRoot`.
    ///
    /// Leading `/` are stripped, `.` and `..` components are rejected, and the
    /// standardised result must still live under the standardised root — the
    /// path arrives from the Switch, so a traversal attempt must never escape
    /// the configured backup folder. Returns `nil` when the path is rejected.
    private func resolveExportDestination(backupRoot: URL, rawPath: String) -> URL? {
        let root = backupRoot.standardizedFileURL
        let components = rawPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            SenDoLog.log("SphairaClient: export path \"\(rawPath)\" has no components")
            return nil
        }
        for component in components where component == "." || component == ".." {
            SenDoLog.log("SphairaClient: export path \"\(rawPath)\" contains illegal component \"\(component)\"")
            return nil
        }

        var destination = root
        for component in components {
            destination.appendPathComponent(component)
        }

        let resolved = destination.standardizedFileURL
        let rootPath = root.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            SenDoLog.log("SphairaClient: export path resolves to \(resolved.path), outside backup root \(rootPath)")
            return nil
        }
        return resolved
    }

    /// Receives the chunk stream of one file until `SendDataPacket(0,0,0)`.
    ///
    /// Mirrors `tools/usb_export.py`: ack the header first, then read the
    /// payload, verify its CRC32C and only then ack the payload
    /// (`Usb::Write` does `SendAndVerify(packet)` then `SendAndVerify(payload)`).
    private func receiveExportBody(
        handle: FileHandle,
        url: URL,
        onExportProgress: @escaping (_ bytesReceived: Int64, _ currentFileName: String) -> Void
    ) throws {
        let fileName = url.lastPathComponent
        var bytesReceived: Int64 = 0

        while true {
            let packet = try transfer.readPacket(timeout: 600)

            let offset = (UInt64(packet.arg2) << 32) | UInt64(packet.arg3)
            let size = Int(packet.arg4)
            let expectedCRC = packet.arg5

            // Ack for the packet itself — before the payload is read.
            try transfer.sendResult(SPHProtocol.RESULT_OK)

            // End of this file.
            if offset == 0 && size == 0 {
                SenDoLog.log("SphairaClient: end of export for \(fileName) after \(bytesReceived) bytes")
                return
            }

            let payload = try transfer.readExact(size, timeout: 300)
            let crc = SphairaCRC32C.checksum(payload)

            guard crc == expectedCRC else {
                SenDoLog.log(
                    String(
                        format: "SphairaClient: CRC mismatch for \(fileName) offset=%llu got=0x%08X expected=0x%08X — RESULT_ERROR, packet discarded",
                        offset, crc, expectedCRC
                    )
                )
                try transfer.sendResult(SPHProtocol.RESULT_ERROR)
                continue
            }

            do {
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: payload)
            } catch {
                SenDoLog.log("SphairaClient: write failed for \(fileName) at offset \(offset): \(error)")
                try transfer.sendResult(SPHProtocol.RESULT_ERROR)
                continue
            }

            try transfer.sendResult(SPHProtocol.RESULT_OK)
            bytesReceived += Int64(payload.count)
            onExportProgress(bytesReceived, fileName)
        }
    }

    // MARK: - CMD_OPEN

    private func serveOpenFile(
        index: Int,
        files: [URL],
        onProgress: @escaping (_ bytesSent: Int64, _ totalBytes: Int64, _ currentFileName: String) -> Void
    ) throws {
        guard index >= 0 && index < files.count else {
            SenDoLog.log("SphairaClient: index \(index) out of range (0..<\(files.count)) — sending RESULT_ERROR")
            try transfer.sendResult(SPHProtocol.RESULT_ERROR)
            return
        }

        let url = files[index]
        let path = url.path

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            SenDoLog.log("SphairaClient: failed to open \(path): \(error) — sending RESULT_ERROR")
            try transfer.sendResult(SPHProtocol.RESULT_ERROR)
            return
        }
        defer { try? handle.close() }

        guard let fileSize = resolveFileSize(of: url, handle: handle) else {
            SenDoLog.log("SphairaClient: failed to determine size of \(path) — sending RESULT_ERROR")
            try transfer.sendResult(SPHProtocol.RESULT_ERROR)
            return
        }

        // Regular files are seekable, so no FLAG_STREAM.
        let flags = SPHProtocol.FLAG_NONE
        let arg3 = (flags << 16) | UInt32((fileSize >> 32) & 0xFFFF)
        let arg4 = UInt32(fileSize & 0xFFFF_FFFF)

        SenDoLog.log("SphairaClient: opened \(path) size=\(fileSize) flags=\(flags) — sending file info result arg3=0x\(String(arg3, radix: 16, uppercase: true)) arg4=0x\(String(arg4, radix: 16, uppercase: true))")
        try transfer.sendResult(SPHProtocol.RESULT_OK, arg3: arg3, arg4: arg4)

        try transferChunkLoop(handle: handle, url: url, fileSize: fileSize, onProgress: onProgress)
        SenDoLog.log("SphairaClient: file transfer finished for \(path)")
    }

    /// Inner chunk loop: answer SendDataPacket requests until CloseFile (offset=0, size=0).
    private func transferChunkLoop(
        handle: FileHandle,
        url: URL,
        fileSize: Int64,
        onProgress: @escaping (_ bytesSent: Int64, _ totalBytes: Int64, _ currentFileName: String) -> Void
    ) throws {
        let fileName = url.lastPathComponent
        var bytesSent: Int64 = 0

        while true {
            let request = try transfer.readPacket(timeout: 60)

            let offset = (UInt64(request.arg2) << 32) | UInt64(request.arg3)
            let size = Int(request.arg4)

            // CloseFile: offset == 0 && size == 0
            if offset == 0 && size == 0 {
                SenDoLog.log("SphairaClient: CloseFile received for \(fileName) after \(bytesSent)/\(fileSize) bytes")
                try transfer.sendResult(SPHProtocol.RESULT_OK)
                return
            }

            guard offset <= UInt64(fileSize) else {
                SenDoLog.log("SphairaClient: offset \(offset) beyond EOF (\(fileSize)) — sending RESULT_ERROR")
                try transfer.sendResult(SPHProtocol.RESULT_ERROR)
                continue
            }

            // Mirror usb_install.py: seek, read up to `size` bytes (a short read at
            // EOF is legal — the Switch trusts arg3/arg4, not the requested size).
            let chunk: Data
            do {
                try handle.seek(toOffset: offset)
                chunk = try readUpTo(handle: handle, count: size)
            } catch {
                SenDoLog.log("SphairaClient: read failed at offset \(offset) size \(size): \(error) — sending RESULT_ERROR")
                try transfer.sendResult(SPHProtocol.RESULT_ERROR)
                continue
            }

            if chunk.count != size {
                SenDoLog.log("SphairaClient: short read for \(fileName) at offset \(offset): got \(chunk.count) of \(size) bytes (EOF)")
            }

            let crc = SphairaCRC32C.checksum(chunk)
            SenDoLog.log(String(format: "SphairaClient: chunk \(fileName) offset=%llu size=%u crc=0x%08X", offset, UInt32(chunk.count), crc))

            try transfer.sendResult(SPHProtocol.RESULT_OK, arg3: UInt32(chunk.count), arg4: crc)
            try transfer.write(chunk)

            bytesSent += Int64(chunk.count)
            onProgress(bytesSent, fileSize, fileName)
        }
    }

    // MARK: - Helpers

    /// Reads up to `count` bytes. Returns fewer only at end of file.
    private func readUpTo(handle: FileHandle, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            guard let piece = try handle.read(upToCount: remaining), !piece.isEmpty else { break }
            result.append(piece)
        }
        return result
    }

    private func resolveFileSize(of url: URL, handle: FileHandle) -> Int64? {
        if let size = try? handle.seekToEnd() {
            try? handle.seek(toOffset: 0)
            return Int64(size)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64
    }
}
