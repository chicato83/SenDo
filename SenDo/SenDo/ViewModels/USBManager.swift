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
    /// True while a `serve(files:)` session is in flight.
    private var isServing = false
    
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
                        
                        // Serving the queue exactly as it stands right now (possibly
                        // empty) is valid: the Switch receives an empty string table,
                        // shows nothing, sends CMD_QUIT and the loop exits cleanly.
                        let files = self.installQueue.map { URL(fileURLWithPath: $0.file.path) }
                        SenDoLog.log("USBManager: starting serve on connect with \(files.count) file(s) from installQueue")
                        self.beginServing(files: files)
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
                SenDoLog.log("USBManager: device disconnected — dropping Sphaira client")
                self?.connectionStatus = "Desconectado"
                self?.isConnected = false
                self?.phairaClient = nil
                self?.isServing = false
                // `availableFiles` is a disk-backed ROM list now — unplugging the
                // Switch must not wipe the user's library.
                self?.backupActivity = nil
                self?.backupBytes = 0
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
    
    /// Starts the blocking Sphaira server loop on `serveQueue`.
    /// Returns `false` when a session is already running (the file list of a
    /// session is fixed at handshake time, so it cannot be swapped mid-flight).
    @discardableResult
    private func beginServing(files: [URL]) -> Bool {
        guard let client = phairaClient else {
            SenDoLog.log("USBManager: beginServing — no Sphaira client")
            return false
        }
        guard !isServing else {
            SenDoLog.log("USBManager: beginServing — a serve session is already active, file list is fixed for this session")
            return false
        }
        
        isServing = true
        let backupRoot = URL(fileURLWithPath: backupFolder, isDirectory: true)
        SenDoLog.log("USBManager: serve session starting — \(files.count) file(s), backup root \(backupRoot.path)")
        
        serveQueue.async { [weak self] in
            do {
                try client.serve(
                    files: files,
                    backupRoot: backupRoot,
                    onProgress: { bytesSent, totalBytes, currentFileName in
                        DispatchQueue.main.async { [weak self] in
                            self?.updateServeProgress(fileName: currentFileName, bytesSent: bytesSent, totalBytes: totalBytes)
                        }
                    },
                    onExportProgress: { bytesReceived, currentFileName in
                        DispatchQueue.main.async { [weak self] in
                            self?.updateBackupProgress(bytesReceived: bytesReceived, currentFileName: currentFileName)
                        }
                    }
                )
                SenDoLog.log("USBManager: serve session ended cleanly (CMD_QUIT)")
                DispatchQueue.main.async { [weak self] in
                    self?.finishServing(success: true, message: nil)
                }
            } catch {
                SenDoLog.log("USBManager: serve session ended with error: \(error)")
                let isTimeout: Bool
                if let usbError = error as? USBTransferError, case .timeout = usbError {
                    isTimeout = true
                } else {
                    isTimeout = false
                }
                DispatchQueue.main.async { [weak self] in
                    if isTimeout {
                        // The Switch simply went quiet — expected between sessions.
                        self?.finishServing(success: false, message: "La Switch dejó de responder")
                    } else {
                        self?.finishServing(success: false, message: error.localizedDescription)
                    }
                }
            }
        }
        return true
    }
    
    private func updateServeProgress(fileName: String, bytesSent: Int64, totalBytes: Int64) {
        guard let index = installQueue.firstIndex(where: {
            $0.status == .installing && URL(fileURLWithPath: $0.file.path).lastPathComponent == fileName
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
    
    private func finishServing(success: Bool, message: String?) {
        isServing = false
        backupActivity = nil
        backupBytes = 0
        lastLoggedBackupFile = nil
        
        for index in installQueue.indices where installQueue[index].status == .installing {
            if success {
                installQueue[index].status = .completed
                installQueue[index].progress = 1.0
                completedInstalls.append(installQueue[index])
            } else {
                installQueue[index].status = .failed
                installQueue[index].errorMessage = message ?? "Sesión USB terminada"
            }
        }
        installQueue.removeAll { $0.status == .completed }
        
        if let message = message, !success {
            errorMessage = message
            showError = true
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
    }
    
    func removeFromQueue(_ taskId: String) {
        installQueue.removeAll { $0.id == taskId }
    }
    
    func clearQueue() { installQueue.removeAll() }
    
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
        
        guard !isServing else {
            SenDoLog.log("USBManager: startInstallation — serve session already active, file list is fixed for this session")
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
        
        let files = installQueue.map { URL(fileURLWithPath: $0.file.path) }
        SenDoLog.log("USBManager: startInstallation — serving \(files.count) file(s)")
        beginServing(files: files)
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
