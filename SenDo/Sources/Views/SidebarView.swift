import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: SenDoViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            ConnectionStatusView(viewModel: viewModel)
            
            Divider()
            
            List {
                Section("Archivos") {
                    NavigationLink {
                        FileBrowserView(viewModel: viewModel)
                    } label: {
                        Label("Explorar", systemImage: "folder")
                    }
                    
                    NavigationLink {
                        InstalledGamesView(viewModel: viewModel)
                    } label: {
                        Label("Instalados", systemImage: "checkmark.circle")
                    }
                }
                
                Section("Cola") {
                    NavigationLink {
                        QueueView(viewModel: viewModel)
                    } label: {
                        Label("Cola de instalacion", systemImage: "list.bullet")
                    }
                }
            }
            .listStyle(.sidebar)
            
            Spacer()
            
            VStack(spacing: 12) {
                if !viewModel.selectedFiles.isEmpty {
                    Button(action: { viewModel.addSelectedToQueue() }) {
                        Label("Agregar a cola (\(viewModel.selectedFiles.count))", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding()
        }
        .navigationTitle("SenDo")
    }
}
