import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: SenDoViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            ConnectionStatusView(viewModel: viewModel)
            Divider()
            
            // Sidebar `NavigationLink`s (Explorar, Instalados, Cola, Ajustes) need
            // a navigation container: the split view keeps the sidebar visible and
            // shows the selected destination in the detail column.
            NavigationSplitView {
                SidebarView(viewModel: viewModel)
                    .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
            } detail: {
                DetailView(viewModel: viewModel)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") { }
        } message: {
            Text(viewModel.errorMessage ?? "Error desconocido")
        }
    }
}
