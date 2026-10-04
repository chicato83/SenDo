import Foundation
import SwiftUI
import Combine

// MARK: - Main ViewModel

/// Central view model managing Switch connection, file transfers, and app state
@MainActor
final class SenDoViewModel: ObservableObject {
    // MARK: - Published Properties
    
    @Published var isConnected = false
    @Published var isScanning = false
    @Published var connectionStatus = "Desconectado"
    
    @Published var availableFiles: [GameFile] = []
    @Published var installQueue: [InstallTask] = []
    @Published var completedInstalls: [InstallTask] = []
    
    @Published var selectedFiles: Set<String> = []
    @Published var errorMessage: String?
    @Published var showError = false
    
    // MARK: - Private Properties
    
    private var usbDiscovery: USBDiscovery?
    private var nutClient: NUTClient?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    init() {
        setupUSBDiscovery()
    }
    
    // MARK: - USB Setup
    
    private func setupUSBDiscovery() {
        usbDiscovery = USBDiscovery()
        
        usbDiscovery?.onDeviceConnected = { [weak self] device in
            Task { @MainActor in
                self?.connectionStatus = "Conectado: \(device.name)"
                self?.isConnected = true
                
                do {
                    self?.nutClient = try NUTClient(device: device)
                    try await self?.scanForFiles()
                } catch {
                    self?.errorMessage = "Error al conectar: \(error.localizedDescription)"
                    self?.showError = true
                }
            }
        }
        
        usbDiscovery?.onDeviceDisconnected = { [weak self] in
            Task { @MainActor in
                self?.connectionStatus = "Desconectado"
                self?.isConnected = false
                self?.nutClient = nil
                self?.availableFiles = []
            }
        }
        
        usbDiscovery?.start()
    }
    
    // MARK: - File Scanning
    
    func scanForFiles() async {
        guard let client = nutClient else { return }
        
        isScanning = true
        defer { isScanning = false }
        
        do {
            let files = try client.searchFiles()
            availableFiles = files.map { file in
                GameFile(
                    id: file.id,
                    name: file.name,
                    titleId: file.id,
                    size: file.size,
                    version: file.version,
                    type: detectFileType(name: file.name),
                    isSelected: false
                )
            }
        } catch {
            errorMessage = "Error al escanear archivos: \(error.localizedDescription)"
            showError = true
        }
    }
    
    private func detectFileType(name: String) -> GameFileType {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "nsp": return .nsp
        case "xci": return .xci
        case "nsz": return .nsz
        case "xcz": return .xcz
        default: return .unknown
        }
    }
    
    // MARK: - Queue Management
    
    func addToQueue(_ files: [GameFile]) {
        for file in files {
            let task = InstallTask(
                id: UUID().uuidString,
                file: file,
                status: .pending,
                progress: 0
            )
            installQueue.append(task)
        }
    }
    
    func removeFromQueue(_ taskId: String) {
        installQueue.removeAll { $0.id == taskId }
    }
    
    func clearQueue() {
        installQueue.removeAll()
    }
    
    func moveUp(_ taskId: String) {
        guard let index = installQueue.firstIndex(where: { $0.id == taskId }),
              index > 0 else { return }
        installQueue.swapAt(index, index - 1)
    }
    
    func moveDown(_ taskId: String) {
        guard let index = installQueue.firstIndex(where: { $0.id == taskId }),
              index < installQueue.count - 1 else { return }
        installQueue.swapAt(index, index + 1)
    }
    
    // MARK: - Installation
    
    func startInstallation() async {
        guard let client = nutClient else {
            errorMessage = "No hay conexión con la Switch"
            showError = true
            return
        }
        
        for i in 0..<installQueue.count {
            guard installQueue[i].status == .pending || installQueue[i].status == .failed else { continue }
            
            installQueue[i].status = .installing
            installQueue[i].progress = 0
            
            do {
                // Check if file needs decompression
                let file = installQueue[i].file
                if NSZDecompressor.isCompressed(url: URL(fileURLWithPath: file.name)) {
                    installQueue[i].status = .decompressing
                    // Decompress first, then send
                    // For now, we'll send the compressed file directly
                    // as Sphaira supports NSZ/XCZ
                }
                
                // Send file to Switch
                let data = try client.downloadFile(titleId: file.titleId) { [weak self] progress, total in
                    Task { @MainActor in
                        self?.installQueue[i].progress = Double(progress) / Double(total)
                    }
                }
                
                installQueue[i].status = .completed
                installQueue[i].progress = 1.0
                completedInstalls.append(installQueue[i])
                
            } catch {
                installQueue[i].status = .failed
                installQueue[i].errorMessage = error.localizedDescription
            }
        }
        
        // Remove completed from queue
        installQueue.removeAll { $0.status == .completed }
    }
    
    func cancelInstallation(_ taskId: String) {
        if let index = installQueue.firstIndex(where: { $0.id == taskId }) {
            installQueue[index].status = .cancelled
        }
    }
    
    // MARK: - Selection
    
    func toggleSelection(for fileId: String) {
        if selectedFiles.contains(fileId) {
            selectedFiles.remove(fileId)
        } else {
            selectedFiles.insert(fileId)
        }
    }
    
    func selectAll() {
        selectedFiles = Set(availableFiles.map(\.id))
    }
    
    func deselectAll() {
        selectedFiles.removeAll()
    }
    
    func addSelectedToQueue() {
        let selected = availableFiles.filter { selectedFiles.contains($0.id) }
        addToQueue(selected)
        deselectAll()
    }
}

// MARK: - Models

struct GameFile: Identifiable, Hashable {
    let id: String
    let name: String
    let titleId: String
    let size: Int64
    let version: Int?
    let type: GameFileType
    var isSelected: Bool
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: GameFile, rhs: GameFile) -> Bool {
        lhs.id == rhs.id
    }
}

enum GameFileType {
    case nsp, xci, nsz, xcz, unknown
    
    var displayName: String {
        switch self {
        case .nsp: return "NSP"
        case .xci: return "XCI"
        case .nsz: return "NSZ (Comprimido)"
        case .xcz: return "XCZ (Comprimido)"
        case .unknown: return "Desconocido"
        }
    }
    
    var icon: String {
        switch self {
        case .nsp, .nsz: return "doc.zipper"
        case .xci, .xcz: return "gamecontroller"
        case .unknown: return "doc"
        }
    }
}

struct InstallTask: Identifiable {
    let id: String
    let file: GameFile
    var status: InstallStatus
    var progress: Double
    var errorMessage: String?
    
    mutating func updateProgress(_ progress: Double) {
        self.progress = progress
    }
}

enum InstallStatus {
    case pending
    case decompressing
    case installing
    case completed
    case failed
    case cancelled
    
    var displayName: String {
        switch self {
        case .pending: return "Pendiente"
        case .decompressing: return "Descomprimiendo"
        case .installing: return "Instalando"
        case .completed: return "Completado"
        case .failed: return "Fallido"
        case .cancelled: return "Cancelado"
        }
    }
    
    var color: Color {
        switch self {
        case .pending: return .gray
        case .decompressing: return .orange
        case .installing: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
    
    var icon: String {
        switch self {
        case .pending: return "clock"
        case .decompressing: return "arrow.triangle.2.circlepath"
        case .installing: return "arrow.down.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle"
        }
    }
}
