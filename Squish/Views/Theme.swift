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
