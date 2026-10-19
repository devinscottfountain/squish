import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(QueueStore.self) private var store
    @State private var showCommand = false
    @State private var dropTargeted = false
    @State private var spaceMonitor: Any?

    var body: some View {
        @Bindable var store = store
        ZStack(alignment: .bottom) {
            // A light tint over the frosted window so glass panels read against any wallpaper.
            Theme.windowTint.ignoresSafeArea()

            HStack(alignment: .top, spacing: 14) {
                QueueCard()
                SettingsPanel()
                    .frame(width: 370)
            }
            .padding(.horizontal, 14)
            .padding(.top, 34) // just clears the traffic lights
            .padding(.bottom, 88)
            .ignoresSafeArea(edges: .top)

            BottomToolbar(showCommand: $showCommand)
                .padding(.bottom, 18)

            if dropTargeted {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Theme.orange, style: StrokeStyle(lineWidth: 2.5, dash: [10, 8]))
                    .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.orange.opacity(0.06)))
                    .overlay {
                        Label("Drop to add", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().fill(Theme.orange))
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls: urls)
            Delight.thud()
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { dropTargeted = targeted }
        }
        .sheet(isPresented: $showCommand) { CommandSheet() }
        .sheet(item: $store.previewJob) { job in PreviewSheet(job: job) }
        .onChange(of: store.settings) {
            store.persist()
            store.scheduleEstimates()
        }
        .onChange(of: store.mode) { store.persist() }
        .task {
            await store.environment.refresh()
            store.reprobeAll()
        }
        .onAppear { installSpaceToPreview() }
        .onDisappear { spaceMonitor.map(NSEvent.removeMonitor) }
        .preferredColorScheme(store.appearance.colorScheme)
        .containerBackground(.ultraThinMaterial, for: .window)
    }

    /// Space opens the before/after preview for the selected file and closes it again, like Quick Look.
    /// Ignored while typing in a field or while another window (Settings, About) is in front.
    private func installSpaceToPreview() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
            if store.previewJob != nil {
                store.previewJob = nil
                return nil
            }
            guard NSApp.keyWindow === NSApp.mainWindow, !store.isRunning,
                  let target = store.previewTarget else { return event }
            store.previewJob = target
            return nil
        }
    }

}
