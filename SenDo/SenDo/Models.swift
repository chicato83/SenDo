import Foundation
import SwiftUI

// MARK: - Models

struct GameFile: Identifiable, Hashable {
    /// Identity is the absolute path: stable across scans and unique on disk.
    var id: String { path }
    /// Display name — the basename only, never a path.
    let name: String
    /// Absolute path of the file on disk (what the install serve loop opens).
    let path: String
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
    
    /// Maps a path extension (any case) to its type.
    init(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "nsp": self = .nsp
        case "xci": self = .xci
        case "nsz": self = .nsz
        case "xcz": self = .xcz
        default: self = .unknown
        }
    }
    
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
