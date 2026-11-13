import AppKit
import SwiftUI

/// Small, quiet touches: sounds, Dock progress and trackpad haptics.
@MainActor
enum Delight {
    // MARK: Sound

    /// The app's sounds, synthesized by Tools/render_sound.py: short, soft, and all in one key.
    enum Sound: String {
        /// A batch finished: a small rising arpeggio.
        case finish
        /// Files landed in the queue: one soft pluck.
        case drop
        /// Nothing in the batch succeeded: two low notes falling.
        case fail
    }

    private static var players: [String: NSSound] = [:]
    private static var alternateDrop = false

    private static func player(_ name: String) -> NSSound? {
        if let cached = players[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        let sound = NSSound(contentsOf: url, byReference: true)
        players[name] = sound
        return sound
    }

    /// Honors System Settings › Sound › "Play user interface sound effects".
    private static var systemAllowsUISounds: Bool {
        let value = UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled")
        return (value as? Bool) ?? ((value as? Int).map { $0 != 0 } ?? true)
    }

    static func play(_ sound: Sound, enabled: Bool) {
        guard enabled, systemAllowsUISounds else { return }
        var name = sound.rawValue
        if sound == .drop {
            // Two pitches take turns, so several drops in a row don't sound mechanical.
            if alternateDrop { name = "drop2" }
            alternateDrop.toggle()
        }
        guard let player = player(name) else { return }
        player.stop()
        player.play()
    }

    // MARK: Dock

    private static var dockView: NSHostingView<DockTileView>?

    /// Shows a thin progress bar on the Dock icon; pass nil to restore the plain icon.
    static func setDockProgress(_ progress: Double?) {
        let tile = NSApp.dockTile
        guard let progress else {
            if dockView != nil {
                tile.contentView = nil
                dockView = nil
                tile.display()
            }
            return
        }
        let view = DockTileView(progress: progress)
        if let dockView {
            dockView.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = host
            dockView = host
        }
        tile.display()
    }

    /// One bounce when a batch finishes while the user is in another app.
    static func announceBatchFinished() {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    // MARK: Haptics

    /// A faint tick on Force Touch trackpads.
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func thud() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

/// The app icon with a slim progress bar along the bottom.
struct DockTileView: View {
    var progress: Double

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
            GeometryReader { geo in
                let width = geo.size.width * 0.66
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.55))
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.yellow, Theme.orange], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(width * min(max(progress, 0), 1), 6))
                }
                .frame(width: width, height: geo.size.height * 0.075)
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .position(x: geo.size.width / 2, y: geo.size.height * 0.86)
            }
        }
    }
}
