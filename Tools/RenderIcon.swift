// Renders Squish's app icon and its alternates.
//
//   swiftc -parse-as-library Tools/RenderIcon.swift -o /tmp/render-icon
//   /tmp/render-icon squeeze out.png         one variant at 1024×1024
//   /tmp/render-icon --all Tools/IconAlternates   every variant, plus a comparison sheet
import AppKit
import SwiftUI

private extension Color {
    init(_ hex: UInt32, _ opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

private let orange = Color(0xF2542D)
private let yellow = Color(0xF5A524)
private let cream = Color(0xFFF2DC)

// MARK: - Shared shapes

/// Inward-pointing chevron, like a press squeezing from above or below.
private struct Chevron: Shape {
    var pointingDown: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tipY = pointingDown ? rect.maxY : rect.minY
        let baseY = pointingDown ? rect.minY : rect.maxY
        p.move(to: CGPoint(x: rect.minX, y: baseY))
        p.addLine(to: CGPoint(x: rect.midX, y: tipY))
        p.addLine(to: CGPoint(x: rect.maxX, y: baseY))
        return p
    }
}

private struct RoundedTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        let a = CGPoint(x: rect.minX, y: rect.minY)
        let b = CGPoint(x: rect.maxX, y: rect.midY)
        let c = CGPoint(x: rect.minX, y: rect.maxY)
        let r = rect.width * 0.16
        var p = Path()
        p.move(to: CGPoint(x: (a.x + c.x) / 2, y: (a.y + c.y) / 2))
        p.addArc(tangent1End: a, tangent2End: b, radius: r)
        p.addArc(tangent1End: b, tangent2End: c, radius: r)
        p.addArc(tangent1End: c, tangent2End: a, radius: r)
        p.closeSubpath()
        return p
    }
}

/// The macOS icon body: an 824pt squircle on a 1024 canvas, with a lit top edge.
private struct IconBody<Fill: View, Content: View>: View {
    var edge: Color = .white
    @ViewBuilder var fill: Fill
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 186, style: .continuous)
        ZStack {
            fill
            content
        }
        .frame(width: 824, height: 824)
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [edge.opacity(0.32), edge.opacity(0.03), edge.opacity(0.1)],
                                                   startPoint: .top, endPoint: .bottom), lineWidth: 5))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 14)
        .frame(width: 1024, height: 1024)
    }
}

/// A glossy, squashed rounded rectangle: the "squished" thing in several variants.
private struct Blob: View {
    var colors: [Color]
    var glow: Color
    var width: CGFloat = 560
    var height: CGFloat = 372

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: height * 0.45, style: .continuous)
        shape
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: width * 0.75, height: height * 0.4)
                    .offset(y: -height * 0.29)
                    .blur(radius: 6)
            )
            .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 4))
            .clipShape(shape)
            .frame(width: width, height: height)
            .shadow(color: glow.opacity(0.55), radius: 40, y: 22)
    }
}

private struct Play: View {
    var color: Color = cream
    var size: CGFloat = 128
    var shade: Color = Color(0x9A2410)

    var body: some View {
        RoundedTriangle()
            .fill(color)
            .frame(width: size, height: size * 1.14)
            .offset(x: size * 0.11)
            .shadow(color: shade.opacity(0.45), radius: 10, y: 6)
    }
}

// MARK: - Variants

/// The current icon: a glossy blob pressed by two chevrons.
private struct Squeeze: View {
    var blob: [Color] = [Color(0xFF8B45), orange, Color(0xD93A22)]
    var glow: Color = orange
    var chevron: Color = yellow
    var shade: Color = Color(0x9A2410)

    var body: some View {
        IconBody {
            LinearGradient(colors: [Color(0x34343A), Color(0x16161A)], startPoint: .top, endPoint: .bottom)
            Circle().fill(glow).frame(width: 520).blur(radius: 120).opacity(0.35).offset(y: 40)
        } content: {
            Blob(colors: blob, glow: glow).offset(y: 8)
            Play(shade: shade).offset(y: 8)
            Group {
                Chevron(pointingDown: true)
                    .stroke(chevron, style: StrokeStyle(lineWidth: 36, lineCap: .round, lineJoin: .round))
                    .frame(width: 150, height: 52)
                    .offset(y: -262)
                Chevron(pointingDown: false)
                    .stroke(chevron, style: StrokeStyle(lineWidth: 36, lineCap: .round, lineJoin: .round))
                    .frame(width: 150, height: 52)
                    .offset(y: 278)
            }
            .shadow(color: chevron.opacity(0.5), radius: 16)
        }
    }
}

/// Light and friendly: a squashed orange gummy on cream, with boing lines.
private struct Gummy: View {
    var body: some View {
        IconBody(edge: .white) {
            LinearGradient(colors: [Color(0xFFF6EA), Color(0xF4DCC2)], startPoint: .top, endPoint: .bottom)
        } content: {
            // Soft contact shadow, widened because the gummy is squashed.
            Ellipse()
                .fill(Color(0xB8441F).opacity(0.28))
                .frame(width: 600, height: 70)
                .blur(radius: 22)
                .offset(y: 205)
            Blob(colors: [Color(0xFF9A4D), orange, Color(0xD93A22)], glow: Color(0xB8441F), width: 600, height: 360)
                .offset(y: 30)
            Play(size: 124).offset(y: 30)
            ForEach([-1.0, 1.0], id: \.self) { side in
                VStack(spacing: 34) {
                    Capsule().frame(width: 22, height: 70).rotationEffect(.degrees(side * -24))
                    Capsule().frame(width: 22, height: 96)
                    Capsule().frame(width: 22, height: 70).rotationEffect(.degrees(side * 24))
                }
                .foregroundStyle(Color(0xE0763A).opacity(0.75))
                .offset(x: side * 355, y: 30)
            }
        }
    }
}

/// A frame of film held in a press: the most literal "compress video".
private struct Vise: View {
    var body: some View {
        IconBody {
            LinearGradient(colors: [Color(0x2E3038), Color(0x15161B)], startPoint: .top, endPoint: .bottom)
            Circle().fill(orange).frame(width: 480).blur(radius: 130).opacity(0.3)
        } content: {
            // Film frame, slightly bulging sideways from the pressure.
            ZStack {
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .fill(LinearGradient(colors: [Color(0xFF8B45), orange, Color(0xD93A22)], startPoint: .top, endPoint: .bottom))
                VStack {
                    sprockets
                    Spacer()
                    sprockets
                }
                .padding(.vertical, 22)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(0x1B1C22))
                    .frame(width: 420, height: 168)
                Play(size: 92, shade: .black).offset(y: 0)
            }
            .frame(width: 560, height: 300)
            .shadow(color: orange.opacity(0.5), radius: 30, y: 14)

            ForEach([-1.0, 1.0], id: \.self) { side in
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(LinearGradient(colors: [Color(0xFFC35A), yellow, Color(0xD98A12)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 620, height: 78)
                    Capsule().fill(.white.opacity(0.35)).frame(width: 520, height: 10).offset(y: -22)
                }
                .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                .offset(y: side * 196)
            }
        }
    }

    private var sprockets: some View {
        HStack(spacing: 26) {
            ForEach(0..<8, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(0x1B1C22))
                    .frame(width: 34, height: 26)
            }
        }
    }
}

/// macOS 26 flavor: a frosted glass tile floating over a warm glow.
private struct Glass: View {
    var body: some View {
        IconBody {
            LinearGradient(colors: [Color(0x1E1B2E), Color(0x0E0E14)], startPoint: .top, endPoint: .bottom)
            Circle().fill(orange).frame(width: 420).blur(radius: 90).offset(x: -110, y: 90)
            Circle().fill(Color(0x8E88E8)).frame(width: 360).blur(radius: 100).opacity(0.8).offset(x: 150, y: -120)
            Circle().fill(yellow).frame(width: 200).blur(radius: 70).opacity(0.7).offset(x: 40, y: 170)
        } content: {
            let tile = RoundedRectangle(cornerRadius: 132, style: .continuous)
            ZStack {
                tile.fill(LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                tile.strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.1), .white.opacity(0.35)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 6)
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 250, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            }
            .frame(width: 540, height: 540)
            .shadow(color: .black.opacity(0.3), radius: 30, y: 20)
        }
    }
}

/// Flat and bold: reads at 16pt better than anything glossy.
private struct Bold: View {
    var body: some View {
        IconBody {
            LinearGradient(colors: [Color(0xFF7A3D), Color(0xE8402A)], startPoint: .top, endPoint: .bottom)
        } content: {
            RoundedRectangle(cornerRadius: 58, style: .continuous)
                .fill(cream)
                .frame(width: 250, height: 250)
                .shadow(color: Color(0x9A2410).opacity(0.4), radius: 16, y: 8)
            Play(color: orange, size: 92, shade: .clear)
            let arrows: [(String, CGFloat, CGFloat)] = [
                ("arrow.down.right", -1, -1), ("arrow.down.left", 1, -1),
                ("arrow.up.right", -1, 1), ("arrow.up.left", 1, 1),
            ]
            ForEach(arrows, id: \.0) { name, x, y in
                Image(systemName: name)
                    .font(.system(size: 150, weight: .black))
                    .foregroundStyle(cream)
                    .offset(x: x * 250, y: y * 250)
            }
        }
    }
}

/// The current design in a cooler colorway: lilac blob, orange press.
private struct Night: View {
    var body: some View {
        Squeeze(blob: [Color(0xA9A4F2), Color(0x8E88E8), Color(0x6C72E8)], glow: Color(0x7B76E0),
                chevron: Color(0xFF7A3D), shade: Color(0x2D2A7A))
    }
}

private enum Variant: String, CaseIterable {
    case squeeze, gummy, vise, glass, bold, night

    var title: String {
        switch self {
        case .squeeze: "A · Squeeze (current)"
        case .gummy: "B · Gummy"
        case .vise: "C · Vise"
        case .glass: "D · Glass"
        case .bold: "E · Bold"
        case .night: "F · Night"
        }
    }

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .squeeze: Squeeze()
        case .gummy: Gummy()
        case .vise: Vise()
        case .glass: Glass()
        case .bold: Bold()
        case .night: Night()
        }
    }
}

// MARK: - Comparison sheet

private struct Sheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("Squish icon alternates")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(380), spacing: 28), count: 3), spacing: 36) {
                ForEach(Variant.allCases, id: \.self) { variant in
                    VStack(alignment: .leading, spacing: 14) {
                        variant.view.scaleEffect(300 / 1024).frame(width: 300, height: 300)
                            .frame(maxWidth: .infinity)
                        Text(variant.title)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                        // Dock and Finder sizes on dark and light, where icons actually live.
                        HStack(spacing: 10) {
                            ForEach([64.0, 32.0, 16.0], id: \.self) { size in
                                variant.view.scaleEffect(size / 1024).frame(width: size, height: size)
                            }
                            Spacer().frame(width: 12)
                            HStack(spacing: 10) {
                                ForEach([64.0, 32.0, 16.0], id: \.self) { size in
                                    variant.view.scaleEffect(size / 1024).frame(width: size, height: size)
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(0xECECEE)))
                        }
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white.opacity(0.05)))
                }
            }
        }
        .padding(44)
        .background(Color(0x1A1A1D))
    }
}

// MARK: - Entry

@MainActor
private func writePNG<V: View>(_ view: V, to url: URL, scale: CGFloat = 1) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("render failed for \(url.lastPathComponent)")
    }
    try! png.write(to: url)
}

@main
struct RenderIcon {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--all" {
            let dir = URL(fileURLWithPath: args[2], isDirectory: true)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for variant in Variant.allCases {
                writePNG(variant.view, to: dir.appendingPathComponent("\(variant.rawValue).png"))
            }
            writePNG(Sheet(), to: dir.appendingPathComponent("comparison.png"))
        } else if args.count == 3, let variant = Variant(rawValue: args[1]) {
            writePNG(variant.view, to: URL(fileURLWithPath: args[2]))
        } else {
            print("usage: render-icon <\(Variant.allCases.map(\.rawValue).joined(separator: "|"))> out.png")
            print("       render-icon --all <directory>")
            exit(1)
        }
    }
}
