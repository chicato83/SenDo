import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings

/// Folder selection for the ROM library and for the backup destination.
///
/// The picked paths are persisted by `USBManager` through `UserDefaults`
/// (`"romFolder"` / `"backupFolder"`); the view only mirrors them.
struct SettingsView: View {
    @ObservedObject var viewModel: SenDoViewModel
    @State private var isPickingRomFolder = false
    @State private var isPickingBackupFolder = false

    var body: some View {
        Form {
            folderRow(
                title: "Carpeta de ROMs",
                subtitle: "Se escanea recursivamente para ofrecer juegos a la Switch",
                path: viewModel.romFolder,
                isPresented: $isPickingRomFolder
            )

            folderRow(
                title: "Carpeta de backup",
                subtitle: "Destino de los juegos exportados desde la Switch",
                path: viewModel.backupFolder,
                isPresented: $isPickingBackupFolder
            )
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 240)
        .navigationTitle("Ajustes")
        .fileImporter(
            isPresented: $isPickingRomFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handle(result) { USBManager.shared.setRomFolder($0) }
        }
        .fileImporter(
            isPresented: $isPickingBackupFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handle(result) { USBManager.shared.setBackupFolder($0) }
        }
    }

    @ViewBuilder
    private func folderRow(
        title: String,
        subtitle: String,
        path: String?,
        isPresented: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(path ?? "Sin seleccionar")
                    .font(.callout)
                    .foregroundColor(path == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            Button(path == nil ? "Seleccionar..." : "Cambiar...") {
                isPresented.wrappedValue = true
            }
        }
        .padding(.vertical, 4)
    }

    private func handle(_ result: Result<[URL], Error>, apply: (String) -> Void) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            SenDoLog.log("SettingsView: folder selected: \(url.path)")
            apply(url.path)
        case .failure(let error):
            SenDoLog.log("SettingsView: folder selection failed: \(error.localizedDescription)")
        }
    }
}
