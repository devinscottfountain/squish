import AppKit
import SwiftUI

/// Receives files dropped on the Dock icon or sent with `open -a Squish`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: QueueStore? {
        didSet {
            guard let store, !pending.isEmpty else { return }
            store.add(urls: pending)
            pending = []
        }
    }
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let store { store.add(urls: urls) } else { pending += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SquishApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var store = QueueStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .onAppear { delegate.store = store }
                .onOpenURL { url in store.add(urls: [url]) }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Videos…") { store.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Choose Output Folder…") { store.chooseOutputFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Queue") {
                Button(store.isRunning ? "Stop" : "Start") { store.isRunning ? store.stop() : store.start() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Clear Finished") { store.clearFinished() }
                    .keyboardShortcut("k")
                Divider()
                Button("Simple Mode") { store.mode = .simple }
                    .keyboardShortcut("1")
                Button("Advanced Mode") { store.mode = .advanced }
                    .keyboardShortcut("2")
            }
        }
    }
}
