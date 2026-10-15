import AppKit
import SwiftUI

enum Theme {
    static let window = Color(hex: "#111111")
    static let card = Color(hex: "#1C1C1C")
    static let raised = Color(hex: "#262626")
    static let field = Color(hex: "#2A2A2A")
    static let knob = Color(hex: "#3A3A3A")
    static let stroke = Color.white.opacity(0.07)
    static let divider = Color.white.opacity(0.07)

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
