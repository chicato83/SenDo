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

    // MARK: Limits

    /// Longest Switch-supplied export path we are willing to read, in bytes.
    /// `pathLength` arrives as a raw `UInt32` and `readExact` zero-fills its
    /// whole buffer, so an unbounded value would let the Switch make us
    /// allocate up to 4 GiB in a single call (W2).
    private static let maxExportPathLength = 4096
    /// Largest export chunk we buffer, in bytes. Sphaira sends 4 MiB chunks
    /// (`NORMAL_BUFFER_SIZE` in `threaded_file_transfer.cpp`), so 64 MiB is a
    /// wide margin above anything legitimate (W2).
    private static let maxExportChunkSize = 64 * 1024 * 1024
    /// Chunk size used when draining announced-but-rejected bytes.
    private static let drainChunkSize = 64 * 1024
    /// Distinct rejection keys kept for first-seen logging.
    private static let maxTrackedRejections = 128

    // MARK: Rejection accounting

    /// Rejection counter per key — the Switch-supplied path when we have one,
    /// a synthetic key otherwise. Only the FIRST rejection of a key is logged:
    /// a rejected path makes the dumper retry at USB speed, and logging every
    /// attempt would flood the log (W4).
    private var rejectionCounts: [String: Int] = [:]
    private var totalRejections = 0

    /// Records a rejected export, logging the first sighting of `key` and
    /// counting every repeat silently (with a periodic aggregate).
    private func recordExportRejection(_ key: String, reason: String) {
        totalRejections += 1
        if let seen = rejectionCounts[key] {
            rejectionCounts[key] = seen + 1
        } else if rejectionCounts.count < Self.maxTrackedRejections {
            rejectionCounts[key] = 1
            SenDoLog.log("SphairaClient: rejected export \"\(key)\" — \(reason) (further rejections of this key are counted silently)")
        }
        if totalRejections % 100 == 0 {
            SenDoLog.log("SphairaClient: export rejections so far: \(totalRejections)")
        }
    }

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
    ///
    /// `files` is read WHEN the handshake latches INSTALL mode, not when the
    /// session starts: a session stays alive across the Switch's idle gaps
    /// (the caller restarts it), so a snapshot taken minutes earlier would
    /// publish a stale string table.
    ///
    /// `onHandshake` receives exactly that latched list (called on the serving
    /// thread), so the caller can tell which queued items this session is
    /// actually able to transfer — an item queued AFTER the latch will only be
    /// served by the NEXT session, and must not be reported as done by this one.
    func serve(
        files: InstallFileList,
        backupRoot: URL,
        onHandshake: (([URL]) -> Void)? = nil,
        onProgress: @escaping (_ bytesSent: Int64, _ totalBytes: Int64, _ currentFilePath: String) -> Void,
        onExportProgress: @escaping (_ bytesReceived: Int64, _ currentFileName: String) -> Void
    ) throws {
        // The Switch speaks first. Wait for it.
        SenDoLog.log("SphairaClient: waiting for the session-opening SendPacket from Switch...")
        let first: SPHPacket
        do {
            first = try transfer.readPacket(timeout: 15)
        } catch let error as USBTransferError {
            guard case .timeout(let seconds) = error else { throw error }
            // The Switch never started a session — the normal state between
            // two of them. Reported as `sessionIdle`, never as a failure, so
            // the caller does not raise "the Switch stopped responding".
            SenDoLog.log("SphairaClient: no session-opening packet within \(seconds)s — session idle, closing")
            throw SphairaProtocolError.sessionIdle
        }
        SenDoLog.log(
            String(
                format: "SphairaClient: session packet — arg2(cmd)=0x%08X arg3=0x%08X arg4=0x%08X",
                first.arg2, first.arg3, first.arg4
            )
        )

        switch first.arg2 {
        case SPHProtocol.CMD_QUIT:
            try serveInstall(files: files, onHandshake: onHandshake, onProgress: onProgress)
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
        files: InstallFileList,
        onHandshake: (([URL]) -> Void)?,
        onProgress: @escaping (_ bytesSent: Int64, _ totalBytes: Int64, _ currentFilePath: String) -> Void
    ) throws {
        // Read the queue NOW, at handshake time: the session may have been
        // started minutes before the user queued anything.
        let servedFiles = files.current
        onHandshake?(servedFiles)

        // Build the string table: UTF-8 file names joined by "\n" with a trailing "\n".
        // An empty list is valid — the Switch shows nothing and then sends CMD_QUIT.
        var stringTable = Data()
        for file in servedFiles {
            stringTable.append(contentsOf: file.lastPathComponent.utf8)
            stringTable.append(0x0A)  // "\n"
        }
        SenDoLog.log("SphairaClient: INSTALL mode — serving \(servedFiles.count) file(s), string table = \(stringTable.count) bytes")
        if servedFiles.isEmpty {
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
                try serveOpenFile(index: index, files: servedFiles, onProgress: onProgress)
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
        // Set as soon as one file of this session loses chunks. The Switch may
        // still close the session cleanly afterwards, but what landed on disk
        // is incomplete, so the session must end with an error instead of
        // reporting success (W3).
        var interrupted = false

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
                    guard !interrupted else {
                        SenDoLog.log("SphairaClient: export session ends after interrupted file(s) — reporting an error instead of success")
                        throw SphairaProtocolError.exportInterrupted
                    }
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
            let clean = try receiveExportBody(
                handle: destination.handle,
                url: destination.url,
                onExportProgress: onExportProgress
            )
            if !clean {
                interrupted = true
            }
        }
    }

    /// Reads the announced path, sanitises it against `backupRoot`, creates the
    /// parent directories and opens the destination for writing.
    /// Returns `nil` after answering `RESULT_ERROR`.
    private func receiveExportPath(pathLength: Int, backupRoot: URL) throws -> (url: URL, handle: FileHandle)? {
        // Bound the announced length BEFORE readExact allocates it (W2): a raw
        // UInt32 would otherwise let the Switch make us zero-fill up to 4 GiB.
        guard pathLength > 0, pathLength <= Self.maxExportPathLength else {
            let reason = pathLength > 0
                ? "path length \(pathLength) exceeds \(Self.maxExportPathLength) bytes"
                : "path length is not positive"
            recordExportRejection("pathLength=\(pathLength)", reason: reason)
            if pathLength > Self.maxExportPathLength {
                // The header ack already authorised the Switch to send
                // `pathLength` bytes: drain them in bounded chunks so the wire
                // stays in sync rather than buffering them.
                try drain(pathLength, timeout: 60)
            }
            try transfer.sendResult(SPHProtocol.RESULT_ERROR)
            return nil
        }

        let rawBytes = try transfer.readExact(pathLength, timeout: 60)
        guard let rawPath = String(data: rawBytes, encoding: .utf8), !rawPath.isEmpty else {
            recordExportRejection("pathLength=\(pathLength)", reason: "path is empty or not valid UTF-8")
            try transfer.sendResult(SPHProtocol.RESULT_ERROR)
            return nil
        }

        // The path comes from the Switch: never trust it before sanitising.
        let destination: URL
        switch resolveExportDestination(backupRoot: backupRoot, rawPath: rawPath) {
        case .rejected(let reason):
            recordExportRejection(rawPath, reason: reason)
            try transfer.sendResult(SPHProtocol.RESULT_ERROR)
            return nil
        case .accepted(let url):
            destination = url
        }

        let opened: (url: URL, handle: FileHandle)
        do {
            opened = try openExportDestination(destination, backupRoot: backupRoot)
        } catch {
            recordExportRejection(rawPath, reason: "\(error)")
            try transfer.sendResult(SPHProtocol.RESULT_ERROR)
            return nil
        }

        SenDoLog.log("SphairaClient: export destination \(opened.url.path)")
        do {
            try transfer.sendResult(SPHProtocol.RESULT_OK)
        } catch {
            // The ack never reached the Switch: do not leak the open file.
            try? opened.handle.close()
            throw error
        }
        return opened
    }

    /// Result of resolving a Switch-supplied path against the backup root.
    private enum ExportPathResolution {
        case rejected(String)  // English reason, logged once per path
        case accepted(URL)
    }

    /// Creates the parent directories of `destination`, re-checks containment
    /// against the symlink-resolved backup root — the parents exist now, so
    /// `resolvingSymlinksInPath()` cannot be fooled by a missing component —
    /// and opens the leaf for writing.
    private func openExportDestination(
        _ destination: URL,
        backupRoot: URL
    ) throws -> (url: URL, handle: FileHandle) {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // C1: containment is decided by the REAL paths, not the standardised
        // ones — `standardizedFileURL` folds `.`/`..` lexically but never
        // resolves a symlink planted inside the backup folder.
        let realRoot = backupRoot.resolvingSymlinksInPath().standardizedFileURL
        guard realRoot.path != "/" else {
            throw ExportDestinationError.backupRootIsFilesystemRoot
        }
        let realParent = parent.resolvingSymlinksInPath().standardizedFileURL
        guard realParent.path == realRoot.path || realParent.path.hasPrefix(realRoot.path + "/") else {
            throw ExportDestinationError.outsideRoot(parent: realParent.path, root: realRoot.path)
        }

        let finalURL = realParent.appendingPathComponent(destination.lastPathComponent)
        guard finalURL.path != realRoot.path else {
            throw ExportDestinationError.isBackupRoot(root: realRoot.path)
        }
        return (finalURL, try openRegularFileExclusively(at: finalURL))
    }

    /// Opens `url` for writing, refusing anything that is not a brand-new
    /// regular file.
    ///
    /// `lstat` (never `stat`) decides, so an existing symlink, folder or
    /// device is reported instead of followed; `O_EXCL | O_NOFOLLOW` closes
    /// the gap between that check and the open, so the leaf can never be a
    /// symlink. `unlink` runs only after `S_ISREG` held, so a Switch path that
    /// names a folder can never trigger a recursive delete (C2).
    private func openRegularFileExclusively(at url: URL) throws -> FileHandle {
        let path = url.path
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw ExportDestinationError.notRegularFile(path: path)
            }
            // Left-over partial export of this same file: dropping a regular
            // file is safe and keeps the receive buffer starting clean.
            guard unlink(path) == 0 else {
                throw ExportDestinationError.unlinkFailed(path: path, code: errno)
            }
        } else {
            guard errno == ENOENT else {
                throw ExportDestinationError.lstatFailed(path: path, code: errno)
            }
        }

        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            throw ExportDestinationError.openFailed(path: path, code: errno)
        }

        var opened = stat()
        guard fstat(fd, &opened) == 0 else {
            let code = errno
            close(fd)
            throw ExportDestinationError.openFailed(path: path, code: code)
        }
        guard opened.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            close(fd)
            throw ExportDestinationError.notRegularFile(path: path)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Reads and discards `count` bytes so the wire stays in sync after a
    /// Switch-supplied length has been rejected. Never holds more than
    /// `drainChunkSize` bytes at a time.
    private func drain(_ count: Int, timeout: TimeInterval) throws {
        var remaining = count
        while remaining > 0 {
            let chunk = min(remaining, Self.drainChunkSize)
            _ = try transfer.readExact(chunk, timeout: timeout)
            remaining -= chunk
        }
    }

    /// Resolves `rawPath` inside `backupRoot`.
    ///
    /// The boundary is the symlink-resolved root: `.`/`..` components and
    /// control bytes are rejected outright, the standardised result must still
    /// live under that root, and every ancestor that already exists is
    /// re-resolved so a symlink planted inside the backup folder is caught
    /// BEFORE anything is created through it. Returns `.rejected` when the
    /// path must not be used.
    private func resolveExportDestination(backupRoot: URL, rawPath: String) -> ExportPathResolution {
        let root = backupRoot.resolvingSymlinksInPath().standardizedFileURL
        guard root.path != "/" else {
            // Writing through a root that normalises to "/" would put the
            // export anywhere on the machine — refuse instead.
            return .rejected("backup root normalises to /")
        }

        let components = rawPath.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            return .rejected("path has no components")
        }
        for component in components {
            if component == "." || component == ".." {
                return .rejected("illegal path component \"\(component)\"")
            }
            if component.unicodeScalars.contains(where: { $0.value < 0x20 }) {
                return .rejected("path component contains control bytes")
            }
        }

        var destination = root
        for component in components {
            destination.appendPathComponent(component)
        }

        let resolved = destination.standardizedFileURL
        guard resolved.path != root.path else {
            return .rejected("path resolves to the backup root itself")
        }
        guard resolved.path.hasPrefix(root.path + "/") else {
            return .rejected("path resolves to \(resolved.path), outside backup root \(root.path)")
        }

        // Every ancestor that already exists must still be inside the real
        // root; missing ones are created (and re-checked) afterwards.
        var cursor = root
        for component in components.dropLast() {
            cursor.appendPathComponent(component)
            var info = stat()
            guard lstat(cursor.path, &info) == 0 else { continue }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                return .rejected("intermediate component \"\(component)\" is not a directory")
            }
            let real = cursor.resolvingSymlinksInPath().standardizedFileURL
            guard real.path == root.path || real.path.hasPrefix(root.path + "/") else {
                return .rejected("intermediate component \"\(component)\" resolves to \(real.path), outside backup root \(root.path)")
            }
        }

        return .accepted(resolved)
    }

    /// Receives the chunk stream of one file until `SendDataPacket(0,0,0)`.
    ///
    /// Mirrors `tools/usb_export.py`: ack the header first, then read the
    /// payload, verify its CRC32C and only then ack the payload
    /// (`Usb::Write` does `SendAndVerify(packet)` then `SendAndVerify(payload)`).
    ///
    /// Returns `false` when this file lost chunks (CRC mismatch, oversized
    /// announced size or a failed write): the terminator still ends the file
    /// on the wire, but what landed on disk is incomplete and the caller must
    /// not report the export as successful (W3).
    private func receiveExportBody(
        handle: FileHandle,
        url: URL,
        onExportProgress: @escaping (_ bytesReceived: Int64, _ currentFileName: String) -> Void
    ) throws -> Bool {
        let fileName = url.lastPathComponent
        var bytesReceived: Int64 = 0
        var hadError = false

        while true {
            let packet = try transfer.readPacket(timeout: 600)

            let offset = (UInt64(packet.arg2) << 32) | UInt64(packet.arg3)
            let size = Int(packet.arg4)
            let expectedCRC = packet.arg5

            // Ack for the packet itself — before the payload is read.
            try transfer.sendResult(SPHProtocol.RESULT_OK)

            // End of this file.
            if offset == 0 && size == 0 {
                if hadError {
                    SenDoLog.log("SphairaClient: end of export for \(fileName) after \(bytesReceived) bytes — at least one chunk was lost, the file is incomplete")
                } else {
                    SenDoLog.log("SphairaClient: end of export for \(fileName) after \(bytesReceived) bytes")
                }
                return !hadError
            }

            // Bound the announced size BEFORE readExact allocates it (W2): a
            // raw UInt32 would otherwise let the Switch make us zero-fill up
            // to 4 GiB for a single chunk.
            guard size <= Self.maxExportChunkSize else {
                recordExportRejection(
                    "chunk \(fileName) size=\(size)",
                    reason: "chunk size \(size) exceeds \(Self.maxExportChunkSize) bytes"
                )
                // The header is already acked, so the payload is on its way:
                // drain it in bounded chunks and fail the payload ack instead
                // of buffering it.
                try drain(size, timeout: 300)
                hadError = true
                try transfer.sendResult(SPHProtocol.RESULT_ERROR)
                continue
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
                hadError = true
                try transfer.sendResult(SPHProtocol.RESULT_ERROR)
                continue
            }

            do {
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: payload)
            } catch {
                SenDoLog.log("SphairaClient: write failed for \(fileName) at offset \(offset): \(error)")
                hadError = true
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
        onProgress: @escaping (_ bytesSent: Int64, _ totalBytes: Int64, _ currentFilePath: String) -> Void
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
    ///
    /// `onProgress` carries the FULL path (not the bare file name) so the
    /// caller can match the progress against a queued install by path instead
    /// of by name — two games can share a `lastPathComponent`.
    private func transferChunkLoop(
        handle: FileHandle,
        url: URL,
        fileSize: Int64,
        onProgress: @escaping (_ bytesSent: Int64, _ totalBytes: Int64, _ currentFilePath: String) -> Void
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
            onProgress(bytesSent, fileSize, url.path)
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

/// Rejections raised while opening the export destination.
private enum ExportDestinationError: LocalizedError {
    case backupRootIsFilesystemRoot
    case isBackupRoot(root: String)
    case outsideRoot(parent: String, root: String)
    case notRegularFile(path: String)
    case lstatFailed(path: String, code: Int32)
    case unlinkFailed(path: String, code: Int32)
    case openFailed(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .backupRootIsFilesystemRoot:
            return "backup root resolves to the filesystem root"
        case .isBackupRoot(let root):
            return "destination is the backup root itself (\(root))"
        case .outsideRoot(let parent, let root):
            return "parent resolves to \(parent), outside backup root \(root)"
        case .notRegularFile(let path):
            return "existing item at \(path) is not a regular file"
        case .lstatFailed(let path, let code):
            return "lstat failed for \(path) (errno \(code))"
        case .unlinkFailed(let path, let code):
            return "unlink failed for \(path) (errno \(code))"
        case .openFailed(let path, let code):
            return "open failed for \(path) (errno \(code))"
        }
    }
}

/// The install queue, shared between the view-model (which mutates it on the
/// main actor) and the serving loop (which reads it at handshake time).
///
/// A session stays alive across the Switch's idle gaps, so a `[URL]` snapshot
/// taken when the session started would go stale the moment the user queued a
/// game. This box hands the serving loop the CURRENT list every handshake
/// without letting it race the main-actor queue.
final class InstallFileList: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    init(urls: [URL] = []) {
        self.urls = urls
    }

    var current: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    func set(_ newURLs: [URL]) {
        lock.lock()
        urls = newURLs
        lock.unlock()
    }
}
