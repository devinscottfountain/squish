import AppKit
import SwiftUI

enum Theme {
    // Translucent so the glass underneath shows through.
    static let raised = Color.white.opacity(0.07)
    static let field = Color.white.opacity(0.07)
    static let knob = Color.white.opacity(0.17)
    static let stroke = Color.white.opacity(0.09)
    static let divider = Color.white.opacity(0.07)
    /// Top-lit edge that sells the glass.
    static let glassEdge = LinearGradient(
        colors: [Color.white.opacity(0.22), Color.white.opacity(0.04), Color.white.opacity(0.08)],
        startPoint: .top, endPoint: .bottom
    )

    static let text = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)

    static let orange = Color(hex: "#F2542D")
    static let yellow = Color(hex: "#F5A524")
    static let lilac = Color(hex: "#8E88E8")
    static let green = Color(hex: "#3CCB6E")
    static let red = Color(hex: "#F26B6B")
    static let indigo = Color(hex: "#6C72E8")
    static let teal = Color(hex: "#3BC7C0")
    static let pink = Color(hex: "#E86BB7")

    static let cardRadius: CGFloat = 22
    static let mono = Font.system(size: 11.5, design: .monospaced)
}

extension Color {
    init(hex: String) {
        var text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        var value: UInt64 = 0
        Scanner(string: text).scanHexInt64(&value)
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

/// Shared motion so every animation in the app feels like it came from the same hand.
/// Strong custom curves (the built-in ones are too soft), and nothing over 300 ms in regular UI.
enum Motion {
    /// Strong ease-out: things that respond to the user or enter the screen.
    static func out(_ duration: Double = 0.2) -> Animation { .timingCurve(0.23, 1, 0.32, 1, duration: duration) }
    /// Strong ease-in-out: things already on screen moving to a new place.
    static func move(_ duration: Double = 0.28) -> Animation { .timingCurve(0.77, 0, 0.175, 1, duration: duration) }
    /// Press feedback: fast enough to feel like the button heard you.
    static let press = out(0.16)
    /// Hover: frequent, so short and plain.
    static let hover = Animation.easeInOut(duration: 0.15)
    /// Exits are quicker than entrances.
    static let exit = out(0.15)
    /// Contextual icon swaps: a spring with no bounce.
    static let icon = Animation.spring(duration: 0.3, bounce: 0)
}

/// Every pressable control shrinks to 0.96 while held, so it feels like it's listening.
/// One value everywhere (below 0.95 reads as exaggerated); `isStatic` turns it off where
/// the motion would distract, such as full-width rows.
struct PressableStyle: ButtonStyle {
    var isStatic = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !isStatic ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// Icon swap values: scale 0.25 → 1, opacity 0 → 1, blur 4 → 0.
struct IconSwapEffect: ViewModifier {
    var shown: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.25)
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 4)
    }
}

/// A staged entrance step: opacity, a 12 pt rise and a 4 pt blur.
struct StagedEnterEffect: ViewModifier {
    var shown: Bool
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 12)
            .blur(radius: shown || reduceMotion ? 0 : 4)
    }
}

/// Outline by default, fill when active, cross-faded with the icon swap values.
struct StateIcon: View {
    let symbol: String
    let filled: Bool

    var body: some View {
        ZStack {
            Image(systemName: symbol).modifier(IconSwapEffect(shown: !filled))
            Image(systemName: symbol).symbolVariant(.fill).modifier(IconSwapEffect(shown: filled))
        }
        .animation(Motion.icon, value: filled)
    }
}

extension AnyTransition {
    /// Small lift and fade for content that appears in place (details, sections). Never from nothing,
    /// never from far away. With Reduce Motion it's a fade only.
    static func reveal(reduceMotion: Bool) -> AnyTransition {
        let enter: AnyTransition = reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: -6)).combined(with: .scale(scale: 0.98, anchor: .top))
        // Exits are softer and quicker than entrances: just fade.
        return .asymmetric(insertion: enter, removal: .opacity.animation(Motion.exit))
    }

    /// Contextual icon appearing or disappearing (hover actions, state swaps).
    static let iconSwap = AnyTransition.modifier(active: IconSwapEffect(shown: false), identity: IconSwapEffect(shown: true))
        .animation(Motion.icon)

    /// One step of a staged entrance (~100 ms apart); leaves with a quick fade.
    static func stagedEnter(delay: Double, reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: StagedEnterEffect(shown: false, reduceMotion: reduceMotion),
                                 identity: StagedEnterEffect(shown: true, reduceMotion: reduceMotion))
                .animation(Motion.out(0.4).delay(delay)),
            removal: .opacity.animation(Motion.exit)
        )
    }
}
