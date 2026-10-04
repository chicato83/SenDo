import Foundation
import SwiftUI
import Combine

// MARK: - ViewModel (thin wrapper around USBManager)

@MainActor
final class SenDoViewModel: ObservableObject {
    @Published var isConnected = false
    @Published var isScanning = false
    @Published var connectionStatus = "Desconectado"
    @Published var availableFiles: [GameFile] = []
    @Published var installQueue: [InstallTask] = []
    @Published var completedInstalls: [InstallTask] = []
    @Published var selectedFiles: Set<String> = []
    @Published var errorMessage: String?
    @Published var showError = false
    @Published var romFolder: String?
    @Published var backupFolder: String = ""
    @Published var backupActivity: String?
    @Published var backupBytes: Int64 = 0
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        SenDoLog.log("SenDoViewModel: init — observing USBManager.shared")
        
        // Mirror USBManager state
        let mgr = USBManager.shared
        mgr.$isConnected.assign(to: &$isConnected)
        mgr.$isScanning.assign(to: &$isScanning)
        mgr.$connectionStatus.assign(to: &$connectionStatus)
        mgr.$availableFiles.assign(to: &$availableFiles)
        mgr.$installQueue.assign(to: &$installQueue)
        mgr.$completedInstalls.assign(to: &$completedInstalls)
        mgr.$selectedFiles.assign(to: &$selectedFiles)
        mgr.$errorMessage.assign(to: &$errorMessage)
        mgr.$showError.assign(to: &$showError)
        mgr.$romFolder.assign(to: &$romFolder)
        mgr.$backupFolder.assign(to: &$backupFolder)
        mgr.$backupActivity.assign(to: &$backupActivity)
        mgr.$backupBytes.assign(to: &$backupBytes)
    }
    
    // Delegate to USBManager
    func scanForFiles() async { await USBManager.shared.scanForFiles() }
    func setRomFolder(_ path: String) { USBManager.shared.setRomFolder(path) }
    func setBackupFolder(_ path: String) { USBManager.shared.setBackupFolder(path) }
    func rescanRomFolder() { USBManager.shared.rescanRomFolder() }
    func addToQueue(_ files: [GameFile]) { USBManager.shared.addToQueue(files) }
    func removeFromQueue(_ id: String) { USBManager.shared.removeFromQueue(id) }
    func clearQueue() { USBManager.shared.clearQueue() }
    func addSelectedToQueue() { USBManager.shared.addSelectedToQueue() }
    func startInstallation() async { await USBManager.shared.startInstallation() }
    func toggleSelection(for id: String) { USBManager.shared.toggleSelection(for: id) }
    func selectAll() { USBManager.shared.selectAll() }
    func deselectAll() { USBManager.shared.deselectAll() }
    func moveUp(_ id: String) {
        guard let idx = installQueue.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        installQueue.swapAt(idx, idx - 1)
        USBManager.shared.installQueue = installQueue
    }
    func moveDown(_ id: String) {
        guard let idx = installQueue.firstIndex(where: { $0.id == id }), idx < installQueue.count - 1 else { return }
        installQueue.swapAt(idx, idx + 1)
        USBManager.shared.installQueue = installQueue
    }
    func cancelInstallation(_ id: String) {
        if let idx = installQueue.firstIndex(where: { $0.id == id }) {
            installQueue[idx].status = .cancelled
            USBManager.shared.installQueue = installQueue
        }
    }
}
