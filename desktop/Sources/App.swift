import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var onTerminate: (() -> Void)?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = DashboardBrand.appIcon
        NSApp.activate(ignoringOtherApps: true)
    }

    func connect(_ store: DashboardStore) {
        // Reopening the window must preserve a deliberate pause and one collector.
        guard onTerminate == nil else { return }
        onTerminate = { store.stop() }
        store.start()
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
                    delegate.connect(store)
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
        MenuBarExtra {
            DashboardMenu().environmentObject(store)
        } label: {
            Image(nsImage: DashboardBrand.menuIcon)
                .accessibilityLabel("Mole Dashboard")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct DashboardMenu: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var store: DashboardStore

    var body: some View {
        Text("Mole Dashboard")
        Text(store.status)
        if let snapshot = store.snapshot {
            Text("CPU \(Format.number(snapshot.cpu.usage))% · Memory \(Format.number(snapshot.memory.used_percent))%")
        }
        Divider()
        Button("Show Dashboard") {
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("0", modifiers: .command)
        Button(store.paused ? "Resume readings" : "Pause readings") { store.togglePause() }
        Button("Reconnect collector") { store.reconnect() }
        Divider()
        Button("Quit Mole Dashboard") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
