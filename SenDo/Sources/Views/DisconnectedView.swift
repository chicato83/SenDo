import SwiftUI

struct DisconnectedView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cable.connector")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("Switch no conectada")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Conecta tu Switch por USB y abre Sphaira en modo USB Install")
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(alignment: .leading, spacing: 12) {
                InstructionRow(
                    number: "1",
                    text: "Conecta la Switch por USB-C"
                )
                InstructionRow(
                    number: "2",
                    text: "Abre Sphaira en la Switch"
                )
                InstructionRow(
                    number: "3",
                    text: "Ve a Network > USB Install"
                )
                InstructionRow(
                    number: "4",
                    text: "La Switch aparecera conectada aqui"
                )
            }
            .padding(.top, 20)
        }
        .padding()
    }
}
