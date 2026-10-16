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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else {
            FFmpegProcess.terminateAll()
            return .terminateNow
        }
        if store.isRunning {
            let alert = NSAlert()
            alert.messageText = "Squish is still encoding"
            alert.informativeText = "Quitting stops the current encode and deletes its unfinished file. Files that already finished are kept, and the rest of the queue will be waiting next time."
            alert.addButton(withTitle: "Stop and Quit")
            alert.addButton(withTitle: "Keep Encoding")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        store.prepareForQuit()
        return .terminateNow
    }
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
            CommandGroup(replacing: .appInfo) { AboutMenuItem() }
            CommandGroup(after: .newItem) {
                Button("Add Videos…") { store.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Choose Output Folder…") { store.chooseOutputFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Queue") {
                Button(store.isRunning ? "Stop" : "Start") { store.isRunning ? store.stop() : store.start(only: nil) }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Retry Failed") { store.retryFailed() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!store.jobs.contains { $0.status == .failed || $0.status == .cancelled })
                Button("Clear Finished") { store.clearFinished(animated: false) }
                    .keyboardShortcut("k")
                Toggle("Play Sound When Done", isOn: Binding(get: { store.playSounds }, set: { store.playSounds = $0 }))
                Divider()
                Button("Simple Mode") { store.mode = .simple }
                    .keyboardShortcut("1")
                Button("Advanced Mode") { store.mode = .advanced }
                    .keyboardShortcut("2")
            }
        }

        Window("About Squish", id: "about") {
            AboutView()
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(width: 380)
                .preferredColorScheme(.dark)
                .containerBackground(.ultraThinMaterial, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)

        Settings {
            SettingsWindow()
                .environment(store)
        }
    }
}
