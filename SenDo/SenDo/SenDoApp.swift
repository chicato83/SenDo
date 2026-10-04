import SwiftUI

@main
struct SenDoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vm = SenDoViewModel()
    
    init() {
        SenDoLog.setup()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: vm)
        }
        .windowResizability(.contentSize)
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

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SenDoLog.log("AppDelegate: applicationDidFinishLaunching — starting USB discovery")
        // Verify the Sphaira CRC32C test vector and packet layout before any
        // hardware traffic, so /tmp/sendo.log always shows the result.
        SPHPacket.runSelfTest()
        USBManager.shared.startDiscovery()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func application(_ application: NSApplication, willEncodeRestorableState coder: NSCoder) {}
    func application(_ application: NSApplication, didRestoreState coder: NSCoder) {}
}

extension Notification.Name {
    static let scanFiles = Notification.Name("scanFiles")
}
