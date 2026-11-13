import AppKit
import SwiftUI

// Pieces shared by the two before/after compares: the full preview sheet and the live
// thumbnail in the settings panel. Each keeps its own gesture and divider.

enum BeforeAfter {
    /// The image's size scaled to fit the box, aspect kept: the whole frame, letterboxed.
    static func fitted(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return box }
        let scale = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

/// Both frames stacked at the same size; "before" is revealed left of `split` (0...1).
struct SplitImageStack: View {
    let before: NSImage
    let after: NSImage
    let size: CGSize
    let split: CGFloat
    /// nil leaves SwiftUI's default.
    var interpolation: Image.Interpolation?
    /// Neutral inset hairline around each frame, for depth on large images.
    var outlined = false

    var body: some View {
        ZStack(alignment: .leading) {
            frame(after)
            frame(before)
                .mask(alignment: .leading) { Rectangle().frame(width: size.width * split) }
        }
        .frame(width: size.width, height: size.height)
    }

    private func frame(_ image: NSImage) -> some View {
        let resizable = Image(nsImage: image).resizable()
        return (interpolation.map { resizable.interpolation($0) } ?? resizable)
            .frame(width: size.width, height: size.height)
            .overlay { if outlined { Rectangle().strokeBorder(Theme.imageOutline, lineWidth: 1) } }
    }
}

/// "Original" / "Squished" label over a frame. Glass would take on the frame's colors;
/// a dark scrim with white type reads over anything, in either appearance.
struct ScrimTag: View {
    let text: String
    var compact = false

    init(_ text: String, compact: Bool = false) {
        self.text = text
        self.compact = compact
    }

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 10 : 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 3 : 4)
            .background(Capsule().fill(.black.opacity(0.55)))
            .overlay { if !compact { Capsule().strokeBorder(.white.opacity(0.15)) } }
    }
}
