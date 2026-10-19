import SwiftUI

struct SettingsPanel: View {
    @Environment(QueueStore.self) private var store
    @State private var presetName = ""

    var body: some View {
        @Bindable var store = store
        Card {
            VStack(spacing: 0) {
                PillSegmented(selection: $store.mode, options: [.simple, .advanced], stretch: true) {
                    $0 == .simple ? "Simple" : "Advanced"
                }
                // Concentric with the card: card radius 22 = switcher radius ~17 + 5 inset.
                .padding(5)

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
        .alert("Save preset", isPresented: $store.isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                store.saveCurrentAsPreset(named: presetName)
                presetName = ""
            }
            .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { presetName = "" }
        } message: {
            Text(store.settings.summaryText)
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
            if let problem = store.environment.problem(with: s) {
                Text(problem)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.red)
                    .lineLimit(2)
            } else {
                Text(s.summaryText)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            let target = store.previewTarget
            Button {
                store.previewJob = target
            } label: {
                Label("Preview", systemImage: "eye")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.field))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .disabled(target == nil || store.isRunning)
            .opacity(target == nil || store.isRunning ? 0.4 : 1)
            .help(target.map { "Before and after for \($0.name) with these settings (Space)" } ?? "Add a video to preview it")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Simple

struct SimpleSettingsView: View {
    @Environment(QueueStore.self) private var store

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    /// M4A stands in for every audio format here and is labeled "Audio".
    private let formats: [Container] = [.mp4, .mov, .webm, .gif, .m4a]
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
                            PresetTile(preset: preset, selected: store.selectedPresetID == preset.id,
                                       unavailable: store.problem(with: preset)) {
                                store.apply(preset)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Your presets")
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(store.savedPresets) { preset in
                            PresetTile(name: preset.name, detail: preset.settings.summaryText, symbol: "star",
                                       tint: Theme.lilac, selected: store.selectedPresetID == preset.selectionID) {
                                store.apply(preset)
                            }
                            .contextMenu {
                                Button("Update with Current Settings") { store.updatePreset(preset) }
                                Divider()
                                Button("Delete", role: .destructive) { store.deletePreset(preset) }
                            }
                        }
                        SavePresetTile { store.isNamingPreset = true }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Format")
                    ChipRow(selection: formatChoice, options: formats) { $0 == .m4a ? "Audio" : $0.label } unavailable: {
                        store.environment.missingLibrary(for: $0)
                    }
                }

                if s.container.isAudioOnly {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Audio")
                        ChipRow(selection: store.bind(\.container), options: Container.audioFormats) { $0.label }
                        if s.container == .m4a {
                            PillSegmented(selection: store.bind(\.audioCodec), options: [AudioCodec.aac, .alac], stretch: true) {
                                $0 == .aac ? "AAC" : "Lossless (ALAC)"
                            }
                        }
                        if s.audioCodec.isLossy {
                            SettingRow(title: "Bitrate", hint: s.audioBitrateKbps >= 256 ? "Transparent for most music" : nil) {
                                PillMenu(selection: store.bind(\.audioBitrateKbps), options: [96, 128, 160, 192, 256, 320]) { "\($0) kbps" }
                            }
                        } else {
                            Note(text: "Lossless keeps every bit of the original sound. Files are much larger.",
                                 tint: Theme.lilac, symbol: "info.circle.fill")
                        }
                        SettingRow(title: "Even out loudness", hint: "Normalizes to −16 LUFS, a common podcast and web level") {
                            Switch(isOn: store.bind(\.normalizeLoudness))
                        }
                    }
                } else if s.container.isAnimatedImage {
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

                if let target = store.previewTarget, !s.container.isAudioOnly {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            SectionLabel("Preview")
                            Spacer(minLength: 8)
                            Text(target.name)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        LiveThumbnail(job: target)
                        if target.customSettings != nil {
                            Note(text: "This file has its own pinned settings, so the preview shows those.",
                                 tint: Theme.lilac, symbol: "pin.fill")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Options")
                    if !s.container.isAudioOnly && !s.container.isAnimatedImage && s.videoCodec.hasHardwareEncoder {
                        SettingRow(title: "Encoder", hint: s.useHardwareEncoder
                                   ? "Apple media engine: several times faster"
                                   : "Software: smallest files, takes longer") {
                            PillSegmented(selection: store.bind(\.useHardwareEncoder), options: [true, false], compact: true) {
                                $0 ? "Fastest" : "Smallest"
                            }
                        }
                    }
                    if !s.container.isAudioOnly {
                        SettingRow(title: "Resolution") {
                            PillMenu(selection: store.bind(\.resolution),
                                     options: [.original, .p2160, .p1440, .p1080, .p720, .p480, .p360]) { $0.label }
                        }
                    }
                    if !s.container.isAnimatedImage && !s.container.isAudioOnly {
                        SettingRow(title: "Audio") {
                            Switch(isOn: Binding(
                                get: { s.audioCodec != .none },
                                set: { on in store.settings.audioCodec = on ? store.settings.container.audioCodecs[0] : .none }
                            ))
                        }
                    }
                    if !s.container.isAudioOnly && store.jobs.contains(where: { $0.media?.isHDR == true }) {
                        SettingRow(title: "Keep HDR", hint: s.canCarryHDR
                                   ? "Off converts to SDR so it looks right everywhere"
                                   : "Needs HEVC, VP9 or ProRes. Pick Modern, Web alpha or ProRes") {
                            Switch(isOn: Binding(get: { s.hdr == .keep && s.canCarryHDR }, set: { store.settings.hdr = $0 ? .keep : .toSDR }))
                                .disabled(!s.canCarryHDR)
                        }
                    }
                    if !s.container.isAudioOnly {
                        SettingRow(title: "Transparency", hint: transparencyHint(s)) {
                            Switch(isOn: $store.simpleTransparency)
                        }
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

    /// Picking "Audio" while already on an audio format keeps that format.
    private var formatChoice: Binding<Container> {
        Binding(
            get: { store.settings.container.isAudioOnly ? .m4a : store.settings.container },
            set: { picked in
                guard !(picked == .m4a && store.settings.container.isAudioOnly) else { return }
                store.settings.container = picked
                if picked == .m4a { store.settings.audioBitrateKbps = max(store.settings.audioBitrateKbps, 192) }
                store.settings.normalize()
            }
        )
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
    let name: String
    let detail: String
    let symbol: String
    let tint: Color
    let selected: Bool
    /// Set when this ffmpeg can't do what the preset needs; the tile dims and says why.
    var unavailable: String?
    let action: () -> Void
    @State private var hovering = false

    init(name: String, detail: String, symbol: String, tint: Color, selected: Bool, unavailable: String? = nil,
         action: @escaping () -> Void) {
        self.name = name
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
        self.selected = selected
        self.unavailable = unavailable
        self.action = action
    }

    init(preset: QuickPreset, selected: Bool, unavailable: String? = nil, action: @escaping () -> Void) {
        self.init(name: preset.name, detail: preset.detail, symbol: preset.symbol, tint: preset.tint,
                  selected: selected, unavailable: unavailable, action: action)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                StateIcon(symbol: symbol, filled: selected)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(tint.opacity(0.16)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(unavailable ?? detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(unavailable == nil ? Theme.tertiary : Theme.red.opacity(0.85))
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
                    .strokeBorder(selected ? tint.opacity(0.8) : Theme.stroke, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(unavailable != nil)
        .opacity(unavailable != nil ? 0.5 : 1)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(name) preset")
        .accessibilityHint(unavailable ?? detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Dashed "save what I have now" tile at the end of the user's presets.
struct SavePresetTile: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.text : Theme.secondary)
                Text("Save current…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? Theme.text : Theme.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 5]))
                    .foregroundStyle(hovering ? Theme.secondary : Theme.tertiary)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .accessibilityLabel("Save current settings as a preset")
    }
}

struct MiniChipStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(selected ? Theme.onText : Theme.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? Theme.text : Theme.field))
            // ~40 pt tall hit area without changing layout; 3 pt sideways keeps neighbors (6 pt apart) from overlapping.
            .padding(.horizontal, 3).padding(.vertical, 9)
            .contentShape(Rectangle())
            .padding(.horizontal, -3).padding(.vertical, -9)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

// MARK: - Advanced

struct AdvancedSettingsView: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let s = store.settings
        let isImage = s.container.isAnimatedImage
        let audioOnly = s.container.isAudioOnly
        let encodesVideo = !isImage && !audioOnly && s.videoCodec != .copy

        ScrollView {
            VStack(spacing: 8) {
                formatSection(s, isImage: isImage)
                if encodesVideo { videoSection(s) }
                if isImage { animationSection(s) }
                if !audioOnly && (s.videoCodec != .copy || isImage) { frameSection(s) }
                timeSection(s)
                if !isImage { audioSection(s) }
                if !audioOnly { transparencySection(s) }
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
        SettingsSection("Format", symbol: "shippingbox", tint: Theme.orange,
                        badge: isImage ? s.container.label
                            : "\(s.container.label) · \(s.container.isAudioOnly ? s.audioCodec.label : s.videoCodec.label)",
                        expanded: true) {
            SettingRow(title: "Container") {
                PillMenu(selection: store.bind(\.container), options: Container.allCases) { $0.label } unavailable: {
                    store.environment.missingLibrary(for: $0)
                }
            }
            if !isImage && !s.container.isAudioOnly {
                SettingRow(title: "Video codec") {
                    PillMenu(selection: store.bind(\.videoCodec), options: s.container.videoCodecs) { $0.label } unavailable: {
                        store.environment.missingLibrary(for: $0, hardware: s.useHardwareEncoder && $0.hasHardwareEncoder)
                    }
                }
                if s.videoCodec.hasHardwareEncoder {
                    SettingRow(title: "Hardware encoder", hint: s.videoCodec == .prores ? "Apple media engine, about 4× faster for ProRes 422" : "Apple media engine: 2–4× faster at similar size") {
                        Switch(isOn: store.bind(\.useHardwareEncoder))
                    }
                }
            }
            if s.container.isAudioOnly {
                Note(text: "Audio only: the picture is dropped and just the soundtrack is exported.",
                     tint: Theme.lilac, symbol: "waveform")
            } else {
                SettingRow(title: "Hardware decoding", hint: "Decode the source on the media engine") {
                    Switch(isOn: store.bind(\.useHardwareDecoder))
                }
            }
            // Only warn about a real file; a placeholder has no duration or streams to judge.
            if let job = store.jobs.first {
                ForEach(store.plan(for: job).warnings, id: \.self) { Note(text: $0) }
            }
        }
    }

    // MARK: Video

    @ViewBuilder
    private func videoSection(_ s: EncodeSettings) -> some View {
        SettingsSection("Video", symbol: "film", tint: Theme.yellow, badge: rateBadge(s)) {
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
                SettingRow(title: "Pixel format", hint: s.hdr == .keep && s.pixelFormat == .auto ? "Auto picks 10-bit for HDR sources" : nil) {
                    PillMenu(selection: store.bind(\.pixelFormat), options: PixelFormat.allCases) { $0.label }
                }
                SettingRow(title: "HDR sources", hint: s.canCarryHDR ? "iPhone, HLG, HDR10 and Dolby Vision clips" : "\(s.videoCodec.label) is SDR only, so HDR is always converted") {
                    PillSegmented(selection: store.bind(\.hdr), options: HDRHandling.allCases, compact: true) { $0 == .toSDR ? "To SDR" : "Keep" }
                        .disabled(!s.canCarryHDR)
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
        SettingsSection("Animation", symbol: "photo.stack", tint: Theme.pink, badge: s.container.label, expanded: true) {
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
        SettingsSection("Frame", symbol: "aspectratio", tint: Theme.teal, badge: frameBadge(s)) {
            SettingRow(title: "Resolution", hint: "Short edge, so portrait works too") {
                PillMenu(selection: store.bind(\.resolution), options: ResolutionPreset.allCases) { $0.label }
            }
            if s.resolution == .custom {
                SettingRow(title: "Size", hint: "0 keeps aspect ratio", combine: false) {
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
            SettingRow(title: "Flip", combine: false) {
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
                NumberField(value: store.bind(\.cropTop), width: 30).accessibilityLabel("Crop top")
                NumberField(value: store.bind(\.cropBottom), width: 30).accessibilityLabel("Crop bottom")
                NumberField(value: store.bind(\.cropLeft), width: 30).accessibilityLabel("Crop left")
                NumberField(value: store.bind(\.cropRight), width: 30).accessibilityLabel("Crop right")
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
                PillMenu(selection: store.bind(\.audioCodec), options: s.container.audioCodecs) { $0.label } unavailable: {
                    store.environment.missingLibrary(for: $0)
                }
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
        SettingsSection("Metadata", symbol: "tag", tint: Theme.pink, badge: s.stripMetadata ? "Stripped" : nil) {
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
        SettingsSection("Output", symbol: "folder", tint: Theme.secondary,
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
            HStack(spacing: 6) {
                Button("Save as preset…") { store.isNamingPreset = true }
                    .buttonStyle(MiniChipStyle(selected: false))
                Button("Reset all settings") {
                    store.settings = EncodeSettings()
                    store.selectedPresetID = nil
                }
                .buttonStyle(MiniChipStyle(selected: false))
            }
        }
    }
}

// MARK: - Live thumbnail

/// A small before/after of the previewed file that keeps up with the settings. Hover to slide the
/// divider, click for the full preview.
struct LiveThumbnail: View {
    @Environment(QueueStore.self) private var store
    let job: EncodeJob
    @State private var split: CGFloat = 0.5

    var body: some View {
        let current = store.thumbnailIsCurrent(for: job)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button {
            store.previewJob = job
        } label: {
            ZStack {
                if let thumb = job.thumbnail {
                    GeometryReader { geo in
                        let width = geo.size.width
                        ZStack(alignment: .leading) {
                            frame(thumb.after, size: geo.size)
                            frame(thumb.before, size: geo.size)
                                .mask(alignment: .leading) { Rectangle().frame(width: width * split) }
                            Rectangle()
                                .fill(.white)
                                .frame(width: 1.5)
                                .shadow(color: .black.opacity(0.5), radius: 2)
                                .offset(x: width * split - 0.75)
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                split = min(max(point.x / max(width, 1), 0), 1)
                            case .ended:
                                withAnimation(Motion.out(0.3)) { split = 0.5 }
                            }
                        }
                    }
                    // Old frames stay up, softened, while new ones are made.
                    .blur(radius: current ? 0 : 3)
                    .animation(Motion.out(0.2), value: current)
                } else {
                    Theme.field
                }
            }
            .frame(height: 180)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.imageOutline, lineWidth: 1))
            .overlay(alignment: .topLeading) { tag("Original").padding(8) }
            .overlay(alignment: .topTrailing) { tag("Squished").padding(8) }
            .overlay(alignment: .bottomLeading) {
                if !current || job.isMakingThumbnail {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(job.thumbnail == nil ? "Making a preview…" : "Updating…")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.black.opacity(0.55)))
                    .padding(8)
            }
            .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .disabled(store.isRunning)
        .task(id: "\(job.id)-\(current)") {
            if !current { store.scheduleThumbnail() }
        }
        .accessibilityLabel("Preview of \(job.name): original on the left, squished on the right")
        .accessibilityHint("Opens the full before and after preview")
    }

    private func frame(_ image: NSImage, size: CGSize) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.55)))
    }
}
