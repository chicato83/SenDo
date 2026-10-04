import SwiftUI

struct WelcomeView: View {
    @ObservedObject var viewModel: SenDoViewModel
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            
            Text("Switch Conectada")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Arrastra archivos NSP, XCI, NSZ o XCZ aqui para instalar")
                .font(.title3)
                .foregroundColor(.secondary)
            
            HStack(spacing: 20) {
                StatCard(
                    title: "Archivos disponibles",
                    value: "\(viewModel.availableFiles.count)",
                    icon: "doc.fill"
                )
                
                StatCard(
                    title: "En cola",
                    value: "\(viewModel.installQueue.count)",
                    icon: "list.bullet"
                )
                
                StatCard(
                    title: "Completados",
                    value: "\(viewModel.completedInstalls.count)",
                    icon: "checkmark.circle.fill"
                )
            }
            .padding(.top, 20)
        }
        .padding()
    }
}
