import AppKit
import SwiftUI

/// Small, quiet touches: the finish sound, Dock progress and trackpad haptics.
@MainActor
enum Delight {
    // MARK: Sound

    private static let sound: NSSound? = {
        guard let url = Bundle.main.url(forResource: "squish", withExtension: "wav") else { return nil }
        let sound = NSSound(contentsOf: url, byReference: true)
        sound?.volume = 0.6
        return sound
    }()

    /// Honors System Settings › Sound › "Play user interface sound effects".
    private static var systemAllowsUISounds: Bool {
        let value = UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled")
        return (value as? Bool) ?? ((value as? Int).map { $0 != 0 } ?? true)
    }

    static func playFinishSound(enabled: Bool) {
        guard enabled, systemAllowsUISounds, let sound else { return }
        sound.stop()
        sound.play()
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
