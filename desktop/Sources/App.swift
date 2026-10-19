import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct MoleDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = DashboardStore()
    var body: some Scene {
        Window("Mole Dashboard", id: "dashboard") {
            DashboardView().environmentObject(store)
                .task {
                    delegate.onTerminate = { store.stop() }
                    store.start()
                }
        }
        .defaultSize(width: 1380, height: 940)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Monitoring") {
                Button(store.paused ? "Resume readings" : "Pause readings") { store.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Reconnect collector") { store.reconnect() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
