import SwiftUI

extension View {
    /// Frosted glass surface. Liquid Glass on macOS 26, material plus a lit edge before that.
    @ViewBuilder
    func glass<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(liquidGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        if let tint { shape.fill(tint.opacity(0.85)) }
                    }
                }
                .overlay(shape.strokeBorder(Theme.glassEdge, lineWidth: 1))
        }
    }
}

@available(macOS 26.0, *)
private func liquidGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        content
            .clipShape(shape)
            .glass(in: shape)
            .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
    }
}

/// The "Upcoming Bills | All Bills" style switcher.
struct PillSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    var stretch = false
    var compact = false
    let label: (T) -> String
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Text(label(option))
                    .font(.system(size: compact ? 11 : 12.5, weight: .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, compact ? 8 : 12)
                    .padding(.vertical, compact ? 4 : 6)
                    .frame(maxWidth: stretch ? .infinity : nil)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Theme.knob)
                                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "selection", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(Motion.out(0.22)) { selection = option }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label(option))
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { selection = option }
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.field))
    }
}

struct PillMenu<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    /// Why an option can't be picked right now (e.g. a missing ffmpeg library), or nil if it can.
    var unavailable: (T) -> String? = { _ in nil }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                let reason = unavailable(option)
                Button {
                    selection = option
                } label: {
                    if option == selection {
                        Label(label(option), systemImage: "checkmark")
                    } else if let reason {
                        Text("\(label(option)) — needs \(reason)")
                    } else {
                        Text(label(option))
                    }
                }
                .disabled(reason != nil && option != selection)
            }
        } label: {
            HStack(spacing: 6) {
                Text(label(selection)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.field))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(PressableStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var hint: String? = nil
    /// Merge the title and control into one VoiceOver element. Turn off for rows with several controls.
    var combine = true
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                if let hint {
                    Text(hint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: combine ? .combine : .contain)
    }
}

struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.orange)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var leading: String? = nil
    var trailing: String? = nil
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(format(value))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.field))
            }
            Group {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
            }
            .controlSize(.small)
            .tint(Theme.orange)
            .accessibilityLabel(title)
            .accessibilityValue(format(value))
            if leading != nil || trailing != nil {
                HStack {
                    Text(leading ?? "")
                    Spacer()
                    Text(trailing ?? "")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiary)
            }
        }
    }
}

struct NumberField: View {
    @Binding var value: Double
    var suffix: String?
    var width: CGFloat

    init(value: Binding<Double>, suffix: String? = nil, width: CGFloat = 56) {
        _value = value
        self.suffix = suffix
        self.width = width
    }

    init(value: Binding<Int>, suffix: String? = nil, width: CGFloat = 56) {
        _value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) })
        self.suffix = suffix
        self.width = width
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .frame(width: width)
            if let suffix {
                Text(suffix)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.field))
    }
}

struct TextPill: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = 170
    var monospaced = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? Theme.mono : .system(size: 12))
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.field))
    }
}

struct HexColorWell: View {
    @Binding var hex: String

    var body: some View {
        ColorPicker("", selection: Binding(get: { Color(hex: hex) }, set: { hex = $0.hexString }), supportsOpacity: false)
            .labelsHidden()
    }
}

struct ChipRow<T: Hashable>: View {
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    var unavailable: (T) -> String? = { _ in nil }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                let reason = unavailable(option)
                Button {
                    withAnimation(Motion.out(0.2)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Theme.onText : Theme.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(selected ? Theme.text : Theme.field))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .disabled(reason != nil && !selected)
                .opacity(reason != nil && !selected ? 0.4 : 1)
                .help(reason.map { "Needs \($0), which this ffmpeg doesn't include" } ?? "")
            }
        }
    }
}

/// Collapsible group in Advanced mode.
struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var badge: String? = nil
    @State private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: Content

    init(_ title: String, symbol: String, tint: Color, badge: String? = nil, expanded: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.badge = badge
        _expanded = State(initialValue: expanded)
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Motion.out(0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    StateIcon(symbol: symbol, filled: expanded)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.16)))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            // Full-width row: no press scale; the chevron and the reveal are the feedback.
            .buttonStyle(PressableStyle(isStatic: true))
            .accessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(.top, 4)
                .padding(.bottom, 14)
                .transition(.reveal(reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.sectionFill))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.glassEdge.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.tertiary)
    }
}

struct Note: View {
    let text: String
    var tint: Color = Theme.yellow
    var symbol = "exclamationmark.triangle.fill"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
