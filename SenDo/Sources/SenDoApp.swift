import SwiftUI

@main
struct SenDoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Escanear archivos") {
                    NotificationCenter.default.post(name: .scanFiles, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}

extension Notification.Name {
    static let scanFiles = Notification.Name("scanFiles")
}
