import SwiftUI

struct FileBrowserView: View {
    @ObservedObject var viewModel: SenDoViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Carpeta de ROMs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(viewModel.romFolder ?? "Sin seleccionar")
                        .font(.callout)
                        .foregroundColor(viewModel.romFolder == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                
                Spacer()
                
                if viewModel.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                
                Button("Reescanear") { viewModel.rescanRomFolder() }
                    .disabled(viewModel.romFolder == nil || viewModel.isScanning)
            }
            .padding()
            
            Divider()
            
            HStack {
                Button("Seleccionar todo") { viewModel.selectAll() }
                Button("Deseleccionar") { viewModel.deselectAll() }
                
                Spacer()
                
                Text("\(viewModel.selectedFiles.count) seleccionados")
                    .foregroundColor(.secondary)
            }
            .padding()
            
            Divider()
            
            if viewModel.availableFiles.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    if viewModel.romFolder == nil {
                        Text("Selecciona una carpeta de ROMs en Ajustes")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        
                        Text("Los juegos se escanean de esa carpeta")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if viewModel.isScanning {
                        Text("Escaneando carpeta...")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    } else {
                        Text("No se encontraron archivos")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.availableFiles) { file in
                    FileRowView(
                        file: file,
                        isSelected: viewModel.selectedFiles.contains(file.id)
                    ) {
                        viewModel.toggleSelection(for: file.id)
                    }
                }
            }
        }
        .navigationTitle("Archivos Disponibles")
    }
}
