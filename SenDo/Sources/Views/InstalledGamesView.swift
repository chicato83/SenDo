import SwiftUI

struct InstalledGamesView: View {
    @ObservedObject var viewModel: SenDoViewModel
    
    var body: some View {
        VStack {
            if viewModel.completedInstalls.isEmpty {
                VStack {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text("No hay instalaciones completadas")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.completedInstalls) { task in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .frame(width: 30)
                        
                        VStack(alignment: .leading) {
                            Text(task.file.name)
                                .font(.body)
                            
                            Text(task.file.type.displayName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Text(ByteCountFormatter.string(fromByteCount: task.file.size, countStyle: .file))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Instalados")
    }
}
