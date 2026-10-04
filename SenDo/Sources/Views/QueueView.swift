import SwiftUI

struct QueueView: View {
    @ObservedObject var viewModel: SenDoViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { Task { await viewModel.startInstallation() } }) {
                    Label("Instalar todo", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.installQueue.isEmpty)
                
                Button("Limpiar cola") { viewModel.clearQueue() }
                    .disabled(viewModel.installQueue.isEmpty)
                
                Spacer()
                
                Text("\(viewModel.installQueue.count) en cola")
                    .foregroundColor(.secondary)
            }
            .padding()
            
            Divider()
            
            if viewModel.installQueue.isEmpty {
                VStack {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text("La cola esta vacia")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    
                    Text("Selecciona archivos y agregalos a la cola")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.installQueue) { task in
                        QueueRowView(task: task) { action in
                            handleAction(action, for: task)
                        }
                    }
                    .onMove { source, destination in
                        viewModel.installQueue.move(fromOffsets: source, toOffset: destination)
                    }
                }
            }
        }
        .navigationTitle("Cola de Instalacion")
    }
    
    private func handleAction(_ action: QueueAction, for task: InstallTask) {
        switch action {
        case .moveUp:
            viewModel.moveUp(task.id)
        case .moveDown:
            viewModel.moveDown(task.id)
        case .remove:
            viewModel.removeFromQueue(task.id)
        case .cancel:
            viewModel.cancelInstallation(task.id)
        }
    }
}

enum QueueAction {
    case moveUp, moveDown, remove, cancel
}

struct QueueRowView: View {
    let task: InstallTask
    let onAction: (QueueAction) -> Void
    
    var body: some View {
        HStack {
            Image(systemName: task.status.icon)
                .foregroundColor(task.status.color)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(task.file.name)
                    .font(.body)
                    .lineLimit(1)
                
                HStack {
                    Text(task.status.displayName)
                        .font(.caption)
                        .foregroundColor(task.status.color)
                    
                    if task.status == .installing || task.status == .decompressing {
                        ProgressView(value: task.progress)
                            .frame(width: 100)
                        
                        Text("\(Int(task.progress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if let error = task.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(1)
                    }
                }
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                if task.status == .pending {
                    Button(action: { onAction(.moveUp) }) {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { onAction(.moveDown) }) {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(.plain)
                }
                
                if task.status == .installing || task.status == .decompressing {
                    Button(action: { onAction(.cancel) }) {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                
                Button(action: { onAction(.remove) }) {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}
