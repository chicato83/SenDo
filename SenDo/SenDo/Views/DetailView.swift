import SwiftUI

struct DetailView: View {
    @ObservedObject var viewModel: SenDoViewModel
    
    var body: some View {
        VStack {
            if viewModel.isConnected {
                WelcomeView(viewModel: viewModel)
            } else {
                DisconnectedView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
