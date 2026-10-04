import SwiftUI

struct ConnectionStatusView: View {
    @ObservedObject var viewModel: SenDoViewModel
    
    var body: some View {
        HStack {
            Circle()
                .fill(viewModel.isConnected ? Color.green : Color.red)
                .frame(width: 12, height: 12)
            
            VStack(alignment: .leading) {
                Text(viewModel.connectionStatus)
                    .font(.headline)
                
                if let backupActivity = viewModel.backupActivity {
                    Text(backupActivity)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                } else if viewModel.isConnected {
                    Text("Sphaira listo")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if viewModel.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
