import SwiftUI

struct SettingsPanel: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Card {
            VStack(spacing: 0) {
                PillSegmented(selection: $store.mode, options: [.simple, .advanced], stretch: true) {
                    $0 == .simple ? "Simple" : "Advanced"
                }
                .padding(14)

                Rectangle().fill(Theme.divider).frame(height: 1)

                Group {
                    if store.mode == .simple {
                        SimpleSettingsView()
                    } else {
                        AdvancedSettingsView()
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                Rectangle().fill(Theme.divider).frame(height: 1)
                SettingsSummary()
            }
        }
    }
}

/// One-line readout of what will actually happen, like "MP4 · H.264 · CRF 23 · AAC 160k".
struct SettingsSummary: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        let s = store.settings
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
            Text(summary(s))
                .font(Theme.mono)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func summary(_ s: EncodeSettings) -> String {
        var parts = [s.container.label]
        if !s.container.isAnimatedImage {
            var codec = s.videoCodec.label
            if s.videoCodec == .prores { codec += " \(s.proresProfile.label)" }
            if s.hardwareEncoding { codec += " (HW)" }
            parts.append(codec)
            if s.videoCodec != .prores && s.videoCodec != .copy {
                switch s.rateControl {
                case .quality:
                    if let q = CommandBuilder.qualityParameter(for: s) {
                        parts.append(q.flag == "-crf" ? "CRF \(q.value)" : "Q \(q.value)")
                    }
                case .bitrate, .constant: parts.append("\(s.videoBitrateKbps) kbps")
                case .targetSize: parts.append("≤ \(num(s.targetSizeMB)) MB")
                }
            }
        }
        if s.resolution != .original { parts.append(s.resolution.label) }
        if let fps = s.targetFrameRate { parts.append("\(num(fps)) fps") }
        if s.playbackSpeed != 1 { parts.append("\(num(s.playbackSpeed))×") }
        if !s.container.isAnimatedImage {
            if s.audioCodec == .none {
                parts.append("no audio")
            } else if s.audioCodec.isLossy {
                parts.append("\(s.audioCodec.label) \(s.audioBitrateKbps)k")
            } else {
                parts.append(s.audioCodec.label)
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Simple

struct SimpleSettingsView: View {
    @Environment(QueueStore.self) private var store

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    private let formats: [Container] = [.mp4, .mov, .webm, .gif]
    private let sizes: [Double] = [5, 10, 25, 50, 100]

    var body: some View {
        @Bindable var store = store
        let s = store.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Start from")
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(QuickPreset.all) { preset in
                            PresetTile(preset: preset, selected: store.selectedPresetID == preset.id) {
                                store.apply(preset)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Format")
                    ChipRow(selection: store.bind(\.container), options: formats) { $0.label }
                }

                if s.container.isAnimatedImage {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Animation")
                        SettingRow(title: "Frame rate") {
                            PillMenu(selection: store.bind(\.frameRate), options: [.fps12, .fps15, .fps24, .fps30, .original]) { $0.label }
                        }
                        SliderRow(title: "Colors", value: Binding(get: { Double(s.gifMaxColors) }, set: { store.settings.gifMaxColors = Int($0) }),
                                  range: 16...256, step: 8, leading: "Smaller", trailing: "Smoother") { "\(Int($0))" }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Size")
                        PillSegmented(selection: sizeMode, options: [RateControl.quality, .targetSize], stretch: true) {
                            $0 == .quality ? "By quality" : "By file size"
                        }
                        if s.rateControl == .targetSize {
                            SettingRow(title: "Max file size", hint: "Two-pass encode to land just under it") {
                                NumberField(value: $store.settings.targetSizeMB, suffix: "MB", width: 44)
                            }
                            HStack(spacing: 6) {
                                ForEach(sizes, id: \.self) { mb in
                                    Button("\(Int(mb)) MB") { store.settings.targetSizeMB = mb }
                                        .buttonStyle(MiniChipStyle(selected: s.targetSizeMB == mb))
                                }
                            }
                        } else if s.videoCodec == .prores {
                            Note(text: "ProRes is an editing codec with a fixed quality per profile. Pick MP4 or WebM for small files.",
                                 tint: Theme.lilac, symbol: "info.circle.fill")
                        } else {
                            SliderRow(title: "Quality", value: $store.settings.quality, range: 0...100,
                                      leading: "Smaller file", trailing: "Sharper") { qualityWord($0) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Options")
                    SettingRow(title: "Resolution") {
                        PillMenu(selection: store.bind(\.resolution),
                                 options: [.original, .p2160, .p1440, .p1080, .p720, .p480, .p360]) { $0.label }
                    }
                    if !s.container.isAnimatedImage {
                        SettingRow(title: "Audio") {
                            Switch(isOn: Binding(
                                get: { s.audioCodec != .none },
                                set: { on in store.settings.audioCodec = on ? store.settings.container.audioCodecs[0] : .none }
                            ))
                        }
                    }
                    SettingRow(title: "Transparency", hint: transparencyHint(s)) {
                        Switch(isOn: $store.simpleTransparency)
                    }
                    SettingRow(title: "Remove metadata", hint: "Location, camera, dates") {
                        Switch(isOn: $store.settings.stripMetadata)
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.never)
    }

    private var sizeMode: Binding<RateControl> {
        Binding(
            get: { store.settings.rateControl == .targetSize ? .targetSize : .quality },
            set: { store.settings.rateControl = $0 }
        )
    }

    private func transparencyHint(_ s: EncodeSettings) -> String {
        if s.alphaMode == .flatten || !s.outputSupportsAlpha {
            return "Flattened onto \(s.backgroundHex)"
        }
        return "Kept as \(s.alphaFormatName) when the source has it"
    }
}

func qualityWord(_ q: Double) -> String {
    switch q {
    case ..<20: "Tiny"
    case ..<40: "Small"
    case ..<60: "Balanced"
    case ..<80: "High"
    default: "Pristine"
    }
}

struct PresetTile: View {
    let preset: QuickPreset
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(preset.tint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(preset.tint.opacity(0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(preset.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Theme.raised : Theme.field.opacity(hovering ? 0.8 : 0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? preset.tint.opacity(0.8) : Theme.stroke, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MiniChipStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(selected ? Color.black : Theme.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? Theme.text : Theme.field))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Advanced

struct AdvancedSettingsView: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let s = store.settings
        let isImage = s.container.isAnimatedImage
        let encodesVideo = !isImage && s.videoCodec != .copy

        ScrollView {
            VStack(spacing: 8) {
                formatSection(s, isImage: isImage)
                if encodesVideo { videoSection(s) }
                if isImage { animationSection(s) }
                if s.videoCodec != .copy || isImage { frameSection(s) }
                timeSection(s)
                if !isImage { audioSection(s) }
                transparencySection(s)
                metadataSection(s)
                outputSection(s)
            }
            .padding(12)
        }
        .scrollIndicators(.never)
    }

    // MARK: Format

    @ViewBuilder
    private func formatSection(_ s: EncodeSettings, isImage: Bool) -> some View {
        SettingsSection("Format", symbol: "shippingbox.fill", tint: Theme.orange,
                        badge: isImage ? s.container.label : "\(s.container.label) · \(s.videoCodec.label)", expanded: true) {
            SettingRow(title: "Container") {
                PillMenu(selection: store.bind(\.container), options: Container.allCases) { $0.label }
            }
            if !isImage {
                SettingRow(title: "Video codec") {
                    PillMenu(selection: store.bind(\.videoCodec), options: s.container.videoCodecs) { $0.label }
                }
                if s.videoCodec.hasHardwareEncoder {
                    SettingRow(title: "Hardware encoder", hint: "VideoToolbox: much faster, slightly larger files") {
                        Switch(isOn: store.bind(\.useHardwareEncoder))
                    }
                }
            }
            SettingRow(title: "Hardware decoding", hint: "Decode the source on the media engine") {
                Switch(isOn: store.bind(\.useHardwareDecoder))
            }
            ForEach(store.plan(for: store.jobs.first).warnings, id: \.self) { Note(text: $0) }
        }
    }

    // MARK: Video

    @ViewBuilder
    private func videoSection(_ s: EncodeSettings) -> some View {
        SettingsSection("Video", symbol: "film.fill", tint: Theme.yellow, badge: rateBadge(s)) {
            if s.videoCodec == .prores {
                SettingRow(title: "Profile") {
                    PillMenu(selection: store.bind(\.proresProfile), options: ProResProfile.allCases) { $0.label }
                }
            } else {
                PillSegmented(selection: store.bind(\.rateControl), options: RateControl.allCases, stretch: true) { $0.label }

                switch s.rateControl {
                case .quality:
                    SliderRow(title: "Quality", value: store.bind(\.quality), range: 0...100,
                              leading: "Smaller", trailing: "Sharper") { value in
                        var copy = s
                        copy.quality = value
                        guard let q = CommandBuilder.qualityParameter(for: copy) else { return "\(Int(value))" }
                        return q.flag == "-crf" ? "CRF \(q.value)" : "Q \(q.value)"
                    }
                case .bitrate:
                    SettingRow(title: "Target bitrate") { NumberField(value: store.bind(\.videoBitrateKbps), suffix: "kbps") }
                    SettingRow(title: "Max bitrate", hint: "0 = unconstrained") { NumberField(value: store.bind(\.maxBitrateKbps), suffix: "kbps") }
                    SettingRow(title: "Buffer size", hint: "0 = 2× max bitrate") { NumberField(value: store.bind(\.bufferSizeKbps), suffix: "kbps") }
                    SettingRow(title: "Two-pass", hint: "x264, VP9 and AV1 (aom)") { Switch(isOn: store.bind(\.twoPass)) }
                case .targetSize:
                    SettingRow(title: "Target size", hint: "Audio is budgeted in") {
                        NumberField(value: store.bind(\.targetSizeMB), suffix: "MB", width: 48)
                    }
                case .constant:
                    SettingRow(title: "Bitrate", hint: "For streaming and broadcast") {
                        NumberField(value: store.bind(\.videoBitrateKbps), suffix: "kbps")
                    }
                }

                if !s.hardwareEncoding {
                    SettingRow(title: "Encoder speed") {
                        PillMenu(selection: store.bind(\.speed), options: EncoderSpeed.allCases) { $0.label }
                    }
                }
                if !s.hardwareEncoding && (s.videoCodec == .h264 || s.videoCodec == .hevc) {
                    SettingRow(title: "Tune") {
                        PillMenu(selection: store.bind(\.tune), options: Tune.allCases) { $0.label }
                    }
                }
                if s.videoCodec == .h264 {
                    SettingRow(title: "Profile") {
                        PillMenu(selection: store.bind(\.h264Profile), options: H264Profile.allCases) { $0.label }
                    }
                }
                SettingRow(title: "Pixel format") {
                    PillMenu(selection: store.bind(\.pixelFormat), options: PixelFormat.allCases) { $0.label }
                }
                SettingRow(title: "Keyframe every", hint: "0 = encoder default") {
                    NumberField(value: store.bind(\.keyframeIntervalSeconds), suffix: "sec", width: 36)
                }
                if s.videoCodec != .vp9 {
                    SettingRow(title: "B-frames", hint: "-1 = encoder default") {
                        NumberField(value: store.bind(\.bFrames), width: 30)
                    }
                }
            }
            if s.container.supportsFastStart {
                SettingRow(title: "Fast start", hint: "Playback begins before the download finishes") {
                    Switch(isOn: store.bind(\.fastStart))
                }
            }
        }
    }

    private func rateBadge(_ s: EncodeSettings) -> String {
        if s.videoCodec == .prores { return s.proresProfile.label }
        switch s.rateControl {
        case .quality: return qualityWord(s.quality)
        case .bitrate, .constant: return "\(s.videoBitrateKbps) kbps"
        case .targetSize: return "≤ \(num(s.targetSizeMB)) MB"
        }
    }

    // MARK: Animation

    @ViewBuilder
    private func animationSection(_ s: EncodeSettings) -> some View {
        SettingsSection("Animation", symbol: "photo.stack.fill", tint: Theme.pink, badge: s.container.label, expanded: true) {
            if s.container == .gif {
                SliderRow(title: "Palette colors", value: Binding(get: { Double(s.gifMaxColors) }, set: { store.settings.gifMaxColors = Int($0) }),
                          range: 2...256, step: 2) { "\(Int($0))" }
                SettingRow(title: "Dither") {
                    PillMenu(selection: store.bind(\.gifDither), options: GIFDither.allCases) { $0.label }
                }
            }
            if s.container == .webp {
                SettingRow(title: "Lossless") { Switch(isOn: store.bind(\.webpLossless)) }
                if !s.webpLossless {
                    SliderRow(title: "Quality", value: store.bind(\.quality), range: 0...100) { "\(Int($0))" }
                }
            }
            if s.container != .pngSequence {
                SettingRow(title: "Loop count", hint: "0 = forever") {
                    NumberField(value: store.bind(\.loopCount), width: 30)
                }
            }
        }
    }

    // MARK: Frame

    @ViewBuilder
    private func frameSection(_ s: EncodeSettings) -> some View {
        SettingsSection("Frame", symbol: "aspectratio.fill", tint: Theme.teal, badge: frameBadge(s)) {
            SettingRow(title: "Resolution", hint: "Short edge, so portrait works too") {
                PillMenu(selection: store.bind(\.resolution), options: ResolutionPreset.allCases) { $0.label }
            }
            if s.resolution == .custom {
                SettingRow(title: "Size", hint: "0 keeps aspect ratio") {
                    HStack(spacing: 6) {
                        NumberField(value: store.bind(\.customWidth), width: 40)
                        Text("×").foregroundStyle(Theme.tertiary)
                        NumberField(value: store.bind(\.customHeight), width: 40)
                    }
                }
            } else if s.resolution != .original {
                SettingRow(title: "Allow upscaling") { Switch(isOn: store.bind(\.allowUpscale)) }
            }
            SettingRow(title: "Scaler") {
                PillMenu(selection: store.bind(\.scaleAlgorithm), options: ScaleAlgorithm.allCases) { $0.label }
            }
            SettingRow(title: "Frame rate") {
                PillMenu(selection: store.bind(\.frameRate), options: FrameRatePreset.allCases) { $0.label }
            }
            if s.frameRate == .custom {
                SettingRow(title: "Custom rate") { NumberField(value: store.bind(\.customFrameRate), suffix: "fps", width: 44) }
            }
            if s.frameRate != .original {
                SettingRow(title: "Conversion") {
                    PillSegmented(selection: store.bind(\.frameRateMethod), options: FrameRateMethod.allCases, compact: true) { $0.label }
                }
                if s.frameRateMethod == .interpolate {
                    Note(text: "Motion interpolation synthesizes new frames. Smooth slow-mo, but very slow to encode.",
                         tint: Theme.lilac, symbol: "info.circle.fill")
                }
            }

            Rectangle().fill(Theme.divider).frame(height: 1)

            SettingRow(title: "Rotate") {
                PillSegmented(selection: store.bind(\.rotation), options: Rotation.allCases, compact: true) { $0.label }
            }
            SettingRow(title: "Flip") {
                HStack(spacing: 6) {
                    Button("Horizontal") { store.settings.flipHorizontal.toggle() }
                        .buttonStyle(MiniChipStyle(selected: s.flipHorizontal))
                    Button("Vertical") { store.settings.flipVertical.toggle() }
                        .buttonStyle(MiniChipStyle(selected: s.flipVertical))
                }
            }
            SettingRow(title: "Crop", hint: "Pixels off each edge: top, bottom, left, right") {
                EmptyView()
            }
            HStack(spacing: 6) {
                NumberField(value: store.bind(\.cropTop), width: 30)
                NumberField(value: store.bind(\.cropBottom), width: 30)
                NumberField(value: store.bind(\.cropLeft), width: 30)
                NumberField(value: store.bind(\.cropRight), width: 30)
            }

            Rectangle().fill(Theme.divider).frame(height: 1)

            SettingRow(title: "Deinterlace", hint: "For old broadcast and camcorder footage") {
                Switch(isOn: store.bind(\.deinterlace))
            }
            SettingRow(title: "Denoise") {
                PillMenu(selection: store.bind(\.denoise), options: FilterStrength.allCases) { $0.label }
            }
            SettingRow(title: "Sharpen") {
                PillMenu(selection: store.bind(\.sharpen), options: FilterStrength.allCases) { $0.label }
            }
            SliderRow(title: "Brightness", value: store.bind(\.brightness), range: -0.5...0.5) { signed($0) }
            SliderRow(title: "Contrast", value: store.bind(\.contrast), range: 0.5...2) { "\(num(($0 * 100).rounded() / 100))×" }
            SliderRow(title: "Saturation", value: store.bind(\.saturation), range: 0...3) { "\(num(($0 * 100).rounded() / 100))×" }
            SliderRow(title: "Gamma", value: store.bind(\.gamma), range: 0.5...2) { num(($0 * 100).rounded() / 100) }
            if s.hasColorAdjustments {
                Button("Reset color") {
                    store.settings.brightness = 0
                    store.settings.contrast = 1
                    store.settings.saturation = 1
                    store.settings.gamma = 1
                }
                .buttonStyle(MiniChipStyle(selected: false))
            }
        }
    }

    private func frameBadge(_ s: EncodeSettings) -> String {
        var parts: [String] = []
        if s.resolution != .original { parts.append(s.resolution.label) }
        if let fps = s.targetFrameRate { parts.append("\(num(fps)) fps") }
        if s.rotation != .none { parts.append(s.rotation.label) }
        return parts.isEmpty ? "Original" : parts.joined(separator: " · ")
    }

    private func signed(_ v: Double) -> String {
        let rounded = (v * 100).rounded() / 100
        return rounded > 0 ? "+\(num(rounded))" : num(rounded)
    }

    // MARK: Time

    @ViewBuilder
    private func timeSection(_ s: EncodeSettings) -> some View {
        SettingsSection("Time & Speed", symbol: "timer", tint: Theme.lilac,
                        badge: s.playbackSpeed == 1 ? nil : "\(num(s.playbackSpeed))×") {
            SettingRow(title: "Trim start", hint: "Seconds") { NumberField(value: store.bind(\.trimStart), suffix: "s", width: 44) }
            SettingRow(title: "Trim end", hint: "0 = to the end") { NumberField(value: store.bind(\.trimEnd), suffix: "s", width: 44) }
            SliderRow(title: "Speed", value: store.bind(\.playbackSpeed), range: 0.25...4, step: 0.05,
                      leading: "Slow-mo", trailing: "Time-lapse") { "\(num(($0 * 100).rounded() / 100))×" }
            HStack(spacing: 6) {
                ForEach([0.5, 1, 1.5, 2, 4], id: \.self) { value in
                    Button("\(num(value))×") { store.settings.playbackSpeed = value }
                        .buttonStyle(MiniChipStyle(selected: s.playbackSpeed == value))
                }
            }
            SettingRow(title: "Reverse", hint: "Buffers the whole clip in memory") { Switch(isOn: store.bind(\.reverse)) }
            SettingRow(title: "Fade in") { NumberField(value: store.bind(\.fadeIn), suffix: "s", width: 36) }
            SettingRow(title: "Fade out") { NumberField(value: store.bind(\.fadeOut), suffix: "s", width: 36) }
        }
    }

    // MARK: Audio

    @ViewBuilder
    private func audioSection(_ s: EncodeSettings) -> some View {
        SettingsSection("Audio", symbol: "waveform", tint: Theme.green,
                        badge: s.audioCodec.isLossy ? "\(s.audioCodec.label) \(s.audioBitrateKbps)k" : s.audioCodec.label) {
            SettingRow(title: "Codec") {
                PillMenu(selection: store.bind(\.audioCodec), options: s.container.audioCodecs) { $0.label }
            }
            if s.audioCodec.isLossy {
                SettingRow(title: "Bitrate") {
                    PillMenu(selection: store.bind(\.audioBitrateKbps), options: [64, 96, 128, 160, 192, 256, 320]) { "\($0) kbps" }
                }
            }
            if s.audioCodec != .none && s.audioCodec != .copy {
                SettingRow(title: "Sample rate") {
                    PillSegmented(selection: store.bind(\.sampleRate), options: SampleRate.allCases, compact: true) { $0.label }
                }
                SettingRow(title: "Channels") {
                    PillSegmented(selection: store.bind(\.channels), options: AudioChannels.allCases, compact: true) { $0.label }
                }
                SliderRow(title: "Volume", value: store.bind(\.volumeDB), range: -20...20, step: 0.5) { db in
                    db == 0 ? "0 dB" : (db > 0 ? "+\(num(db)) dB" : "\(num(db)) dB")
                }
                SettingRow(title: "Normalize loudness", hint: "EBU R128, −16 LUFS (podcast/web level)") {
                    Switch(isOn: store.bind(\.normalizeLoudness))
                }
            }
        }
    }

    // MARK: Transparency

    @ViewBuilder
    private func transparencySection(_ s: EncodeSettings) -> some View {
        SettingsSection("Transparency", symbol: "checkerboard.rectangle", tint: Theme.indigo, badge: s.alphaMode.label) {
            PillSegmented(selection: store.bind(\.alphaMode), options: AlphaMode.allCases, stretch: true, compact: true) { $0.label }

            if s.outputSupportsAlpha {
                Note(text: "This output can carry alpha as \(s.alphaFormatName).", tint: Theme.green, symbol: "checkmark.circle.fill")
            } else {
                Note(text: "\(s.container.label) / \(s.videoCodec.label) can't carry alpha. Transparent areas get flattened onto the background color. Use ProRes (MOV), VP9 (WebM) or HEVC + hardware encoder (MOV) to keep it.")
            }

            switch s.alphaMode {
            case .auto:
                Note(text: "Keeps alpha when both the source and the output support it, and flattens otherwise.",
                     tint: Theme.lilac, symbol: "info.circle.fill")
            case .chromaKey:
                SettingRow(title: "Key color") { HexColorWell(hex: store.bind(\.keyColorHex)) }
                SliderRow(title: "Similarity", value: store.bind(\.keySimilarity), range: 0.01...1) { num(($0 * 100).rounded() / 100) }
                SliderRow(title: "Edge blend", value: store.bind(\.keyBlend), range: 0...1) { num(($0 * 100).rounded() / 100) }
            default:
                EmptyView()
            }

            if s.alphaMode != .preserve || !s.outputSupportsAlpha {
                SettingRow(title: "Background", hint: "Used wherever alpha is flattened") {
                    HexColorWell(hex: store.bind(\.backgroundHex))
                }
            }
            if s.videoCodec == .hevc && s.hardwareEncoding && s.container == .mov {
                SliderRow(title: "Alpha quality", value: store.bind(\.hevcAlphaQuality), range: 0...1) { num(($0 * 100).rounded() / 100) }
            }
        }
    }

    // MARK: Metadata

    @ViewBuilder
    private func metadataSection(_ s: EncodeSettings) -> some View {
        SettingsSection("Metadata", symbol: "tag.fill", tint: Theme.pink, badge: s.stripMetadata ? "Stripped" : nil) {
            SettingRow(title: "Strip everything", hint: "Camera, dates, GPS, encoder tags") {
                Switch(isOn: store.bind(\.stripMetadata))
            }
            if !s.stripMetadata {
                SettingRow(title: "Remove location") { Switch(isOn: store.bind(\.stripLocation)) }
                SettingRow(title: "Keep chapters") { Switch(isOn: store.bind(\.keepChapters)) }
            }
            SettingRow(title: "Title") { TextPill(placeholder: "Unchanged", text: store.bind(\.metaTitle)) }
            SettingRow(title: "Artist") { TextPill(placeholder: "Unchanged", text: store.bind(\.metaArtist)) }
            SettingRow(title: "Comment") { TextPill(placeholder: "Unchanged", text: store.bind(\.metaComment)) }
            SettingRow(title: "Copyright") { TextPill(placeholder: "Unchanged", text: store.bind(\.metaCopyright)) }
        }
    }

    // MARK: Output

    @ViewBuilder
    private func outputSection(_ s: EncodeSettings) -> some View {
        SettingsSection("Output", symbol: "folder.fill", tint: Theme.secondary,
                        badge: s.outputLocation == .folder ? URL(fileURLWithPath: s.outputFolderPath).lastPathComponent : s.outputLocation.label) {
            PillSegmented(selection: store.bind(\.outputLocation), options: OutputLocation.allCases, stretch: true, compact: true) { $0.label }
            if s.outputLocation == .folder {
                SettingRow(title: s.outputFolderPath.isEmpty ? "No folder chosen" : (s.outputFolderPath as NSString).abbreviatingWithTildeInPath) {
                    Button("Choose…") { store.chooseOutputFolder() }
                        .buttonStyle(MiniChipStyle(selected: false))
                }
            }
            SettingRow(title: "File suffix") { TextPill(placeholder: "none", text: store.bind(\.filenameSuffix), width: 120) }
            SettingRow(title: "Overwrite existing") { Switch(isOn: store.bind(\.overwrite)) }
            SettingRow(title: "Threads", hint: "0 = automatic") { NumberField(value: store.bind(\.threads), width: 30) }
            VStack(alignment: .leading, spacing: 6) {
                Text("Extra ffmpeg arguments")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                TextPill(placeholder: "-tune film -x264-params aq-mode=3", text: store.bind(\.extraArguments), width: nil, monospaced: true)
                Text("Inserted right before the output path.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiary)
            }
            Button("Reset all settings") {
                store.settings = EncodeSettings()
                store.selectedPresetID = nil
            }
            .buttonStyle(MiniChipStyle(selected: false))
        }
    }
}
