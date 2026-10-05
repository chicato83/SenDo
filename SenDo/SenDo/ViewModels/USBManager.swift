import Foundation
import Combine

/// Central USB manager — starts USB discovery independently of SwiftUI lifecycle.
/// Shared instance lives in AppDelegate, observable from any ViewModel.
///
/// The Sphaira protocol is PULL-based: the Mac is the server and only OFFERS a
/// list of local files. The Switch picks the files it wants, so there is no
/// remote directory to scan.
@MainActor
final class USBManager: ObservableObject {
    static let shared = USBManager()
    
    /// `UserDefaults` key holding the configured ROM folder (absolute path).
    static let romFolderKey = "romFolder"
    /// `UserDefaults` key holding the configured backup folder (absolute path).
    static let backupFolderKey = "backupFolder"
    
    /// Fallback used until the user picks a backup folder: `~/Downloads/SenDo Backup`.
    static let defaultBackupPath: String = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
        return downloads.appending(path: "SenDo Backup", directoryHint: .isDirectory).path
    }()
    
    @Published var isConnected = false
    @Published var connectionStatus = "Desconectado"
    @Published var availableFiles: [GameFile] = []
    @Published var installQueue: [InstallTask] = []
    @Published var completedInstalls: [InstallTask] = []
    @Published var selectedFiles: Set<String> = []
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var isScanning = false
    
    /// Configured ROM folder, absolute path. `nil` until the user picks one.
    @Published var romFolder: String?
    /// Folder that receives game exports from the Switch, absolute path.
    @Published var backupFolder: String
    /// Receive status for the UI, e.g. `Recibiendo... 12.4 MB`. `nil` when idle.
    @Published var backupActivity: String?
    /// Bytes received so far in the export session currently in flight.
    @Published var backupBytes: Int64 = 0
    
    private var usbDiscovery: USBDiscovery?
    private var phairaClient: SphairaClient?
    /// Guards against an older ROM scan landing after a newer one.
    private var scanGeneration = 0
    /// Name of the file whose export start has already been logged.
    private var lastLoggedBackupFile: String?
    
    /// Dedicated queue for the blocking protocol loop — `USBManager` is `@MainActor`,
    /// so every USB read/write must run off the main thread.
    private let serveQueue = DispatchQueue(label: "com.sendo.usb.serve", qos: .userInitiated)
    /// True while a `serve(...)` session is in flight.
    private var isServing = false
    /// Identity of the CURRENT serve session.
    ///
    /// Bumped on every `beginServing()` and on every disconnect, so a session
    /// that ends after it was superseded — or after its device went away —
    /// can never mutate queue state or raise an alert on its successor's
    /// behalf (W1).
    private var sessionToken: UInt64 = 0
    /// Serve failures in a row. Only the FIRST one of a run raises the alert,
    /// so a flaky link cannot stack error dialogs (W5).
    private var consecutiveSessionFailures = 0
    /// Delay before restarting a session that ENDED WITH AN ERROR. Completed
    /// and idle sessions restart immediately: a failure means the Switch is
    /// misbehaving, so back off before offering a session again.
    private let restartBackoff: TimeInterval = 1.0
    /// Install queue handed to `serve(...)`; the protocol reads it AT HANDSHAKE
    /// TIME, so the box — not a snapshot — keeps the served list fresh.
    private let installFiles = InstallFileList()
    /// Paths the CURRENT session latched into its string table. Only those can
    /// legitimately be marked as completed when the session ends — an item
    /// queued after the latch is served by the NEXT session instead.
    private var latchedPaths: Set<String> = []
    
    private init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.romFolderKey), !stored.isEmpty {
            romFolder = stored
        }
        if let stored = defaults.string(forKey: Self.backupFolderKey), !stored.isEmpty {
            backupFolder = stored
        } else {
            backupFolder = Self.defaultBackupPath
        }
        
        SenDoLog.log("USBManager: init — romFolder=\(romFolder ?? "none"), backupFolder=\(backupFolder)")
        ensureBackupFolderExists()
        
        // The folder persists across launches, so the list must not depend on the
        // user pressing "Reescanear" after every restart.
        if romFolder != nil {
            rescanRomFolder()
        }
    }
    
    func startDiscovery() {
        SenDoLog.log("USBManager: startDiscovery()")
        usbDiscovery = USBDiscovery()
        
        usbDiscovery?.onDeviceConnected = { [weak self] device in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    SenDoLog.log("USBManager: Opening USB device on background thread...")
                    let client = try SphairaClient(device: device)
                    SenDoLog.log("USBManager: Sphaira client created successfully")
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self else { return }
                        self.connectionStatus = "Conectado: \(device.name)"
                        self.isConnected = true
                        self.phairaClient = client
                        self.consecutiveSessionFailures = 0
                        
                        // Serving the queue exactly as it stands right now (possibly
                        // empty) is valid: the Switch receives an empty string table,
                        // shows nothing, sends CMD_QUIT and the loop exits cleanly.
                        // The session then restarts on its own and re-reads the queue.
                        self.syncInstallFiles()
                        self.beginServing()
                    }
                } catch {
                    SenDoLog.log("USBManager: USB connection error: \(error)")
                    DispatchQueue.main.async { [weak self] in
                        self?.connectionStatus = "Error: \(error.localizedDescription)"
                        self?.errorMessage = "Error al conectar: \(error.localizedDescription)"
                        self?.showError = true
                    }
                }
            }
        }
        
        usbDiscovery?.onDeviceDisconnected = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                SenDoLog.log("USBManager: device disconnected — dropping Sphaira client")
                self.connectionStatus = "Desconectado"
                self.isConnected = false
                self.phairaClient = nil
                // Invalidate the in-flight session: when its blocking read
                // finally fails, the stale result must not touch queue state
                // or raise an alert (W1).
                self.sessionToken &+= 1
                self.isServing = false
                self.consecutiveSessionFailures = 0
                // `availableFiles` is a disk-backed ROM list now — unplugging the
                // Switch must not wipe the user's library.
                self.backupActivity = nil
                self.backupBytes = 0
            }
        }
        
        usbDiscovery?.start()
        SenDoLog.log("USBManager: discovery started")
    }
    
    // MARK: - ROM Folder
    
    /// Persists the ROM folder (`UserDefaults` key `"romFolder"`) and rescans it.
    func setRomFolder(_ path: String) {
        let normalized = URL(fileURLWithPath: path).path
        SenDoLog.log("USBManager: setRomFolder -> \(normalized)")
        UserDefaults.standard.set(normalized, forKey: Self.romFolderKey)
        romFolder = normalized
        rescanRomFolder()
    }
    
    /// Persists the backup folder (`UserDefaults` key `"backupFolder"`) and
    /// creates it when it does not exist yet.
    func setBackupFolder(_ path: String) {
        let normalized = URL(fileURLWithPath: path).path
        SenDoLog.log("USBManager: setBackupFolder -> \(normalized)")
        UserDefaults.standard.set(normalized, forKey: Self.backupFolderKey)
        backupFolder = normalized
        ensureBackupFolderExists()
    }
    
    /// Recreates the backup folder on disk. Returns `nil` (and surfaces the
    /// error) when the folder cannot be created.
    @discardableResult
    private func ensureBackupFolderExists() -> URL? {
        let url = URL(fileURLWithPath: backupFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            SenDoLog.log("USBManager: backup folder ready at \(url.path)")
            return url
        } catch {
            SenDoLog.log("USBManager: failed to create backup folder \(url.path): \(error)")
            errorMessage = "No se pudo crear la carpeta de backup: \(error.localizedDescription)"
            showError = true
            return nil
        }
    }
    
    /// Re-runs the recursive ROM scan on a background queue and republishes
    /// `availableFiles` on the main actor.
    ///
    /// `FileManager.enumerator` filters `.nsp`/`.xci`/`.nsz`/`.xcz` (case
    /// insensitive) and skips hidden items; title id and version come from the
    /// filename brackets — see `ROMScanner`.
    func rescanRomFolder() {
        guard let folder = romFolder else {
            SenDoLog.log("USBManager: rescanRomFolder — no ROM folder configured")
            availableFiles = []
            selectedFiles.removeAll()
            isScanning = false
            return
        }
        
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        SenDoLog.log("USBManager: rescanning ROM folder \(folder) (scan #\(generation))")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = ROMScanner.scan(folderPath: folder)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.scanGeneration == generation else {
                    SenDoLog.log("USBManager: dropping stale ROM scan result (a newer scan is running)")
                    return
                }
                self.availableFiles = files
                self.selectedFiles = self.selectedFiles.intersection(Set(files.map(\.id)))
                self.isScanning = false
                SenDoLog.log("USBManager: ROM scan finished — \(files.count) file(s) in \(folder)")
            }
        }
    }
    
    /// Kept for `SenDoViewModel`: a "scan" now means re-scanning the configured
    /// ROM folder (the Mac still cannot enumerate the Switch itself).
    func scanForFiles() async {
        SenDoLog.log("USBManager: scanForFiles — re-scanning the configured ROM folder")
        rescanRomFolder()
    }
    
    // MARK: - Serve Loop
    
    /// Outcome of one serve session, as seen by the protocol loop.
    private enum SessionOutcome {
        /// CMD_QUIT — the Switch walked away cleanly.
        case completed
        /// No session-opening packet (or a quiet link) — the normal state
        /// BETWEEN two sessions, never a failure.
        case idle
        case failed(String)
    }
    
    /// Publishes the current queue to the serving loop, which reads it at
    /// handshake time. Called after every queue mutation.
    private func syncInstallFiles() {
        installFiles.set(installQueue.map { URL(fileURLWithPath: $0.file.path) })
    }
    
    /// Starts the blocking Sphaira server loop on `serveQueue`.
    /// Returns `false` when no client is connected or a session is already
    /// running (the string table of a session is fixed at handshake time).
    @discardableResult
    private func beginServing() -> Bool {
        guard let client = phairaClient else {
            SenDoLog.log("USBManager: beginServing — no Sphaira client")
            return false
        }
        guard !isServing else {
            SenDoLog.log("USBManager: beginServing — a serve session is already active, the file list is refreshed on the next handshake")
            return false
        }
        
        isServing = true
        sessionToken &+= 1
        let token = sessionToken
        // Nothing is latched yet: a session that never reaches the INSTALL
        // handshake (export, or an idle timeout) must not touch queue rows.
        latchedPaths = []
        syncInstallFiles()
        let files = installFiles
        let backupRoot = URL(fileURLWithPath: backupFolder, isDirectory: true)
        SenDoLog.log("USBManager: serve session #\(token) starting — \(files.current.count) file(s) in the queue, backup root \(backupRoot.path)")
        
        serveQueue.async { [weak self] in
            do {
                try client.serve(
                    files: files,
                    backupRoot: backupRoot,
                    onHandshake: { latched in
                        DispatchQueue.main.async { [weak self] in
                            self?.latchedPaths = Set(latched.map(\.path))
                            SenDoLog.log("USBManager: session #\(token) latched \(latched.count) file(s) into its string table")
                        }
                    },
                    onProgress: { bytesSent, totalBytes, currentFilePath in
                        DispatchQueue.main.async { [weak self] in
                            self?.updateServeProgress(filePath: currentFilePath, bytesSent: bytesSent, totalBytes: totalBytes)
                        }
                    },
                    onExportProgress: { bytesReceived, currentFileName in
                        DispatchQueue.main.async { [weak self] in
                            self?.updateBackupProgress(bytesReceived: bytesReceived, currentFileName: currentFileName)
                        }
                    }
                )
                SenDoLog.log("USBManager: serve session #\(token) ended cleanly (CMD_QUIT)")
                DispatchQueue.main.async { [weak self] in
                    self?.finishServing(token: token, outcome: .completed)
                }
            } catch {
                SenDoLog.log("USBManager: serve session #\(token) ended with error: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.finishServing(token: token, outcome: Self.classify(error))
                }
            }
        }
        return true
    }
    
    /// Maps a protocol error to a session outcome, with Spanish UI copy.
    /// Pure: safe to call from the serving thread.
    private nonisolated static func classify(_ error: Error) -> SessionOutcome {
        if let spairaError = error as? SphairaProtocolError {
            switch spairaError {
            case .sessionIdle:
                return .idle
            case .exportInterrupted:
                return .failed("La exportación se interrumpió: uno o más archivos quedaron incompletos")
            default:
                return .failed(spairaError.localizedDescription)
            }
        }
        if let usbError = error as? USBTransferError, case .timeout = usbError {
            // The Switch simply went quiet — expected between sessions.
            return .idle
        }
        return .failed(error.localizedDescription)
    }
    
    /// Runs the next session while the Switch is still connected. The token is
    /// re-checked at fire time, so a disconnect in between can never start a
    /// session against a closed device (W1).
    private func scheduleRestart(after delay: TimeInterval, token: UInt64) {
        guard delay <= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.restartIfNeeded(token: token)
            }
            return
        }
        restartIfNeeded(token: token)
    }
    
    private func restartIfNeeded(token: UInt64) {
        guard sessionToken == token, isConnected, phairaClient != nil, !isServing else {
            SenDoLog.log("USBManager: serve session #\(token) not restarted — connection state changed")
            return
        }
        beginServing()
    }
    
    private func updateServeProgress(filePath: String, bytesSent: Int64, totalBytes: Int64) {
        // Match by FULL path: the queue can hold two games whose
        // `lastPathComponent` is identical.
        guard let index = installQueue.firstIndex(where: {
            $0.status == .installing && $0.file.path == filePath
        }) else { return }
        if totalBytes > 0 {
            installQueue[index].progress = min(1.0, Double(bytesSent) / Double(totalBytes))
        }
    }
    
    /// Export progress: the protocol carries no total size, so only the received
    /// byte count is published (indeterminate progress).
    private func updateBackupProgress(bytesReceived: Int64, currentFileName: String) {
        backupBytes = bytesReceived
        let formatted = ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .file)
        backupActivity = "Recibiendo... \(formatted)"
        // Log per file, not per chunk: a multi-GB export would flood /tmp/sendo.log.
        if currentFileName != lastLoggedBackupFile {
            lastLoggedBackupFile = currentFileName
            SenDoLog.log("USBManager: export started — \(currentFileName) into \(backupFolder)")
        }
    }
    
    /// Ends the session identified by `token` and — if that session is still
    /// the current one — applies its outcome to the queue, raises the alert
    /// (first failure of a run only) and schedules the next session.
    private func finishServing(token: UInt64, outcome: SessionOutcome) {
        guard token == sessionToken else {
            // Superseded (or its device is gone): its result belongs to nobody.
            SenDoLog.log("USBManager: ignoring stale serve session #\(token) result (current session is #\(sessionToken))")
            return
        }
        
        isServing = false
        backupActivity = nil
        backupBytes = 0
        lastLoggedBackupFile = nil
        
        switch outcome {
        case .completed:
            consecutiveSessionFailures = 0
            // Only what THIS session latched can be completed: an item queued
            // after the handshake is served by the next session, and marking
            // it now would report a transfer that never happened.
            for index in installQueue.indices
            where installQueue[index].status == .installing
                && latchedPaths.contains(installQueue[index].file.path) {
                installQueue[index].status = .completed
                installQueue[index].progress = 1.0
                completedInstalls.append(installQueue[index])
            }
            installQueue.removeAll { $0.status == .completed }
            syncInstallFiles()
            SenDoLog.log("USBManager: serve session #\(token) completed (\(latchedPaths.count) file(s) latched)")
            scheduleRestart(after: 0, token: token)
            
        case .idle:
            // Between sessions: the queue is left exactly as it was, and the
            // next session simply offers the list again.
            consecutiveSessionFailures = 0
            syncInstallFiles()
            scheduleRestart(after: 0, token: token)
            
        case .failed(let message):
            // An error is reported against everything the session latched; rows
            // it never latched keep their state and are picked up by the next
            // session. Anything pending a retry is flipped back by the next
            // `startInstallation`.
            for index in installQueue.indices
            where installQueue[index].status == .installing
                && latchedPaths.contains(installQueue[index].file.path) {
                installQueue[index].status = .failed
                installQueue[index].errorMessage = message
            }
            syncInstallFiles()
            consecutiveSessionFailures += 1
            if consecutiveSessionFailures == 1 {
                errorMessage = message
                showError = true
            } else {
                SenDoLog.log("USBManager: serve session #\(token) failed again (\(consecutiveSessionFailures) in a row) — suppressing further alerts")
            }
            scheduleRestart(after: restartBackoff, token: token)
        }
    }
    
    // MARK: - Queue
    
    func addToQueue(_ files: [GameFile]) {
        for file in files {
            installQueue.append(InstallTask(
                id: UUID().uuidString,
                file: file,
                status: .pending,
                progress: 0
            ))
        }
        syncInstallFiles()
    }
    
    func removeFromQueue(_ taskId: String) {
        installQueue.removeAll { $0.id == taskId }
        syncInstallFiles()
    }
    
    func clearQueue() {
        installQueue.removeAll()
        syncInstallFiles()
    }
    
    func addSelectedToQueue() {
        let selected = availableFiles.filter { selectedFiles.contains($0.id) }
        addToQueue(selected)
        selectedFiles.removeAll()
    }
    
    // MARK: - Installation
    
    func startInstallation() async {
        guard phairaClient != nil else {
            errorMessage = "No hay conexión con la Switch"
            showError = true
            return
        }
        
        let pendingCount = installQueue.filter { $0.status == .pending || $0.status == .failed }.count
        guard pendingCount > 0 else {
            SenDoLog.log("USBManager: startInstallation — nothing pending in the queue")
            return
        }
        
        for i in 0..<installQueue.count {
            guard installQueue[i].status == .pending || installQueue[i].status == .failed else { continue }
            installQueue[i].status = .installing
            installQueue[i].progress = 0
        }
        syncInstallFiles()
        SenDoLog.log("USBManager: startInstallation — \(pendingCount) file(s) marked as installing")
        
        // A session that is already serving latched its string table at
        // handshake time; the refreshed list is picked up by the session that
        // follows it, which starts as soon as the current one ends.
        if isServing {
            SenDoLog.log("USBManager: startInstallation — serve session already active, refreshed list is served on the next handshake")
            return
        }
        beginServing()
    }
    
    func toggleSelection(for fileId: String) {
        if selectedFiles.contains(fileId) {
            selectedFiles.remove(fileId)
        } else {
            selectedFiles.insert(fileId)
        }
    }
    
    func selectAll() { selectedFiles = Set(availableFiles.map(\.id)) }
    func deselectAll() { selectedFiles.removeAll() }
}
