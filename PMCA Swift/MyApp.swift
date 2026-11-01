import SwiftUI
import AppKit

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = CameraStore.shared
    var body: some Scene {
        Window("PMCA Swift", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 1100, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !CameraStore.shared.busy {
            guard CameraStore.shared.connected else { return .terminateNow }
            Task {
                await CameraStore.shared.endSession()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        let alert = NSAlert()
        alert.messageText = "A camera operation is still running"
        alert.informativeText = "Wait for it to finish before quitting. Keep the camera connected."
        alert.addButton(withTitle: "Keep open")
        alert.runModal()
        return .terminateCancel
    }
}
