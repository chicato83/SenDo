import SwiftUI

struct FileBrowserView: View {
    @ObservedObject var viewModel: SenDoViewModel
    
    var body: some View {
        VStack(spacing: 0) {
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
                VStack {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text("No se encontraron archivos")
                        .font(.title3)
                        .foregroundColor(.secondary)
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
