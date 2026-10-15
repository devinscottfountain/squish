import Foundation

// MARK: - Format

enum Container: String, CaseIterable, Identifiable, Codable {
    case mp4, mov, mkv, webm, gif, webp, apng, pngSequence

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp4: "MP4"
        case .mov: "MOV"
        case .mkv: "MKV"
        case .webm: "WebM"
        case .gif: "GIF"
        case .webp: "WebP"
        case .apng: "APNG"
        case .pngSequence: "PNG frames"
        }
    }

    var fileExtension: String {
        switch self {
        case .pngSequence: "png"
        default: rawValue
        }
    }

    var isAnimatedImage: Bool {
        switch self {
        case .gif, .webp, .apng, .pngSequence: true
        default: false
        }
    }

    var videoCodecs: [VideoCodec] {
        switch self {
        case .mp4: [.h264, .hevc, .av1, .copy]
        case .mov: [.h264, .hevc, .prores, .copy]
        case .mkv: [.h264, .hevc, .av1, .vp9, .copy]
        case .webm: [.vp9, .av1]
        default: []
        }
    }

    var audioCodecs: [AudioCodec] {
        switch self {
        case .mp4: [.aac, .mp3, .copy, .none]
        case .mov: [.aac, .pcm, .copy, .none]
        case .mkv: [.aac, .opus, .flac, .mp3, .copy, .none]
        case .webm: [.opus, .none]
        default: [.none]
        }
    }

    var supportsFastStart: Bool { self == .mp4 || self == .mov }
}

enum VideoCodec: String, CaseIterable, Identifiable, Codable {
    case h264, hevc, av1, vp9, prores, copy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .av1: "AV1"
        case .vp9: "VP9"
        case .prores: "ProRes"
        case .copy: "Passthrough"
        }
    }

    var hasHardwareEncoder: Bool { self == .h264 || self == .hevc }
}

enum AudioCodec: String, CaseIterable, Identifiable, Codable {
    case aac, opus, mp3, flac, pcm, copy, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aac: "AAC"
        case .opus: "Opus"
        case .mp3: "MP3"
        case .flac: "FLAC"
        case .pcm: "PCM"
        case .copy: "Passthrough"
        case .none: "No audio"
        }
    }

    var encoderName: String {
        switch self {
        case .aac: "aac"
        case .opus: "libopus"
        case .mp3: "libmp3lame"
        case .flac: "flac"
        case .pcm: "pcm_s16le"
        case .copy: "copy"
        case .none: ""
        }
    }

    var isLossy: Bool { self == .aac || self == .opus || self == .mp3 }
}

// MARK: - Video

enum RateControl: String, CaseIterable, Identifiable, Codable {
    case quality, bitrate, targetSize, constant

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quality: "Quality"
        case .bitrate: "Bitrate"
        case .targetSize: "File size"
        case .constant: "CBR"
        }
    }
}

enum EncoderSpeed: String, CaseIterable, Identifiable, Codable {
    case fastest, fast, balanced, slow, slowest

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var index: Int { Self.allCases.firstIndex(of: self) ?? 2 }
}

enum Tune: String, CaseIterable, Identifiable, Codable {
    case none, film, animation, grain, stillimage, fastdecode, zerolatency

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .film: "Film"
        case .animation: "Animation"
        case .grain: "Grain"
        case .stillimage: "Still image"
        case .fastdecode: "Fast decode"
        case .zerolatency: "Zero latency"
        }
    }
}

enum H264Profile: String, CaseIterable, Identifiable, Codable {
    case auto, baseline, main, high

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum PixelFormat: String, CaseIterable, Identifiable, Codable {
    case auto, yuv420p, yuv420p10le, yuv422p10le, yuv444p

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .yuv420p: "4:2:0 8-bit"
        case .yuv420p10le: "4:2:0 10-bit"
        case .yuv422p10le: "4:2:2 10-bit"
        case .yuv444p: "4:4:4 8-bit"
        }
    }
}

enum ProResProfile: Int, CaseIterable, Identifiable, Codable {
    case proxy = 0, lt, standard, hq, p4444, p4444xq

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .proxy: "Proxy"
        case .lt: "LT"
        case .standard: "422"
        case .hq: "422 HQ"
        case .p4444: "4444"
        case .p4444xq: "4444 XQ"
        }
    }
}

// MARK: - Frame

enum ResolutionPreset: String, CaseIterable, Identifiable, Codable {
    case original, p2160, p1440, p1080, p720, p480, p360, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: "Original"
        case .p2160: "4K"
        case .custom: "Custom"
        default: "\(shortSide ?? 0)p"
        }
    }

    /// Target length of the shorter edge, so portrait video scales the same as landscape.
    var shortSide: Int? {
        switch self {
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        case .p360: 360
        default: nil
        }
    }
}

enum ScaleAlgorithm: String, CaseIterable, Identifiable, Codable {
    case lanczos, bicubic, bilinear, spline, neighbor

    var id: String { rawValue }
    var label: String { rawValue == "neighbor" ? "Nearest" : rawValue.capitalized }
}

enum FrameRatePreset: String, CaseIterable, Identifiable, Codable {
    case original, fps12, fps15, fps24, fps25, fps30, fps50, fps60, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: "Original"
        case .custom: "Custom"
        default: "\(Int(fixedValue ?? 0)) fps"
        }
    }

    var fixedValue: Double? {
        switch self {
        case .fps12: 12
        case .fps15: 15
        case .fps24: 24
        case .fps25: 25
        case .fps30: 30
        case .fps50: 50
        case .fps60: 60
        default: nil
        }
    }
}

enum FrameRateMethod: String, CaseIterable, Identifiable, Codable {
    case drop, blend, interpolate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .drop: "Drop/dup"
        case .blend: "Blend"
        case .interpolate: "Interpolate"
        }
    }
}

enum Rotation: Int, CaseIterable, Identifiable, Codable {
    case none = 0, cw90 = 90, r180 = 180, ccw90 = 270

    var id: Int { rawValue }
    var label: String { self == .none ? "0°" : "\(rawValue)°" }
}

enum FilterStrength: String, CaseIterable, Identifiable, Codable {
    case off, light, medium, strong

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

// MARK: - Audio

enum SampleRate: Int, CaseIterable, Identifiable, Codable {
    case original = 0, hz44100 = 44100, hz48000 = 48000

    var id: Int { rawValue }
    var value: Int? { self == .original ? nil : rawValue }
    var label: String { self == .original ? "Original" : "\(Double(rawValue) / 1000) kHz".replacingOccurrences(of: ".0 ", with: " ") }
}

enum AudioChannels: String, CaseIterable, Identifiable, Codable {
    case original, mono, stereo

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var value: Int? {
        switch self {
        case .original: nil
        case .mono: 1
        case .stereo: 2
        }
    }
}

// MARK: - Transparency, output

enum AlphaMode: String, CaseIterable, Identifiable, Codable {
    case auto, preserve, flatten, chromaKey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .preserve: "Keep"
        case .flatten: "Flatten"
        case .chromaKey: "Key out"
        }
    }
}

enum GIFDither: String, CaseIterable, Identifiable, Codable {
    case none, bayer, floyd_steinberg, sierra2_4a

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .bayer: "Bayer"
        case .floyd_steinberg: "Floyd–Steinberg"
        case .sierra2_4a: "Sierra"
        }
    }
}

enum OutputLocation: String, CaseIterable, Identifiable, Codable {
    case sameAsSource, folder

    var id: String { rawValue }
    var label: String { self == .sameAsSource ? "Next to source" : "Folder" }
}

// MARK: - Settings

struct EncodeSettings: Codable, Equatable {
    // Format
    var container: Container = .mp4
    var videoCodec: VideoCodec = .h264
    var useHardwareEncoder = false
    var useHardwareDecoder = false

    // Rate control
    var rateControl: RateControl = .quality
    /// 0 (smallest) … 100 (best). Mapped onto each encoder's own CRF/quality scale.
    var quality: Double = 60
    var videoBitrateKbps = 5000
    var maxBitrateKbps = 0
    var bufferSizeKbps = 0
    var targetSizeMB: Double = 10
    var twoPass = true

    // Encoder
    var speed: EncoderSpeed = .balanced
    var tune: Tune = .none
    var h264Profile: H264Profile = .auto
    var pixelFormat: PixelFormat = .auto
    var proresProfile: ProResProfile = .hq
    var keyframeIntervalSeconds: Double = 0
    var bFrames = -1
    var fastStart = true

    // Frame
    var resolution: ResolutionPreset = .original
    var customWidth = 1920
    var customHeight = 0
    var allowUpscale = false
    var scaleAlgorithm: ScaleAlgorithm = .lanczos
    var frameRate: FrameRatePreset = .original
    var customFrameRate: Double = 30
    var frameRateMethod: FrameRateMethod = .drop
    var rotation: Rotation = .none
    var flipHorizontal = false
    var flipVertical = false
    var cropTop = 0
    var cropBottom = 0
    var cropLeft = 0
    var cropRight = 0
    var deinterlace = false
    var denoise: FilterStrength = .off
    var sharpen: FilterStrength = .off
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var gamma: Double = 1

    // Time
    var trimStart: Double = 0
    var trimEnd: Double = 0
    var playbackSpeed: Double = 1
    var reverse = false
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    /// 0 loops forever (GIF / WebP / APNG).
    var loopCount = 0

    // Audio
    var audioCodec: AudioCodec = .aac
    var audioBitrateKbps = 160
    var sampleRate: SampleRate = .original
    var channels: AudioChannels = .original
    var volumeDB: Double = 0
    var normalizeLoudness = false

    // Transparency
    var alphaMode: AlphaMode = .auto
    var backgroundHex = "#000000"
    var keyColorHex = "#00FF00"
    var keySimilarity: Double = 0.3
    var keyBlend: Double = 0.1
    var hevcAlphaQuality: Double = 0.75

    // Animated images
    var gifMaxColors = 256
    var gifDither: GIFDither = .sierra2_4a
    var webpLossless = false

    // Metadata
    var stripMetadata = false
    var stripLocation = true
    var keepChapters = true
    var metaTitle = ""
    var metaArtist = ""
    var metaComment = ""
    var metaCopyright = ""

    // Output
    var outputLocation: OutputLocation = .sameAsSource
    var outputFolderPath = ""
    var filenameSuffix = "-squished"
    var overwrite = false
    var threads = 0
    var extraArguments = ""

    // MARK: Derived

    var hardwareEncoding: Bool { useHardwareEncoder && videoCodec.hasHardwareEncoder }

    var targetFrameRate: Double? {
        frameRate == .custom ? customFrameRate : frameRate.fixedValue
    }

    var hasColorAdjustments: Bool {
        brightness != 0 || contrast != 1 || saturation != 1 || gamma != 1
    }

    var outputSupportsAlpha: Bool {
        if container.isAnimatedImage { return true }
        switch videoCodec {
        case .prores: return container == .mov
        case .vp9: return container == .webm || container == .mkv
        case .hevc: return hardwareEncoding && container == .mov
        default: return false
        }
    }

    var alphaFormatName: String {
        if container == .gif { return "1-bit GIF alpha" }
        if container.isAnimatedImage { return "\(container.label) alpha" }
        switch videoCodec {
        case .prores: return "ProRes 4444"
        case .vp9: return "VP9 alpha"
        case .hevc: return "HEVC alpha"
        default: return "—"
        }
    }

    func producesAlpha(sourceHasAlpha: Bool) -> Bool {
        guard outputSupportsAlpha else { return false }
        switch alphaMode {
        case .auto: return sourceHasAlpha
        case .preserve, .chromaKey: return true
        case .flatten: return false
        }
    }

    /// Keeps codec choices valid for the chosen container.
    mutating func normalize() {
        let videoChoices = container.videoCodecs
        if !videoChoices.isEmpty && !videoChoices.contains(videoCodec) { videoCodec = videoChoices[0] }
        let audioChoices = container.audioCodecs
        if !audioChoices.contains(audioCodec) { audioCodec = audioChoices[0] }
    }

    /// Resets everything except where files go.
    mutating func resetEncoding() {
        var fresh = EncodeSettings()
        fresh.outputLocation = outputLocation
        fresh.outputFolderPath = outputFolderPath
        fresh.filenameSuffix = filenameSuffix
        fresh.overwrite = overwrite
        fresh.threads = threads
        self = fresh
    }
}
