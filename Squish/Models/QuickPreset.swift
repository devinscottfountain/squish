import SwiftUI

/// One-tap starting points for Simple mode. Each resets encoding settings, then applies its own.
struct QuickPreset: Identifiable {
    let id: String
    let name: String
    let detail: String
    let symbol: String
    let tint: Color
    let apply: (inout EncodeSettings) -> Void

    static let all: [QuickPreset] = [
        QuickPreset(id: "smaller", name: "Smaller", detail: "Same look, a fraction of the size",
                    symbol: "arrow.down.right.and.arrow.up.left", tint: Theme.orange) { s in
            s.quality = 55
            s.audioBitrateKbps = 128
        },
        QuickPreset(id: "10mb", name: "Under 10 MB", detail: "Discord, Slack, email",
                    symbol: "paperplane", tint: Theme.lilac) { s in
            s.rateControl = .targetSize
            s.targetSizeMB = 10
            s.useHardwareEncoder = false // two-pass software lands much closer to the target
            s.resolution = .p720
            s.audioBitrateKbps = 96
        },
        QuickPreset(id: "web", name: "Web ready", detail: "1080p, fast start, no metadata",
                    symbol: "globe", tint: Theme.teal) { s in
            s.quality = 62
            s.resolution = .p1080
            s.stripMetadata = true
        },
        QuickPreset(id: "hevc", name: "Modern", detail: "HEVC, about half the size of H.264",
                    symbol: "sparkles", tint: Theme.green) { s in
            s.videoCodec = .hevc
            s.quality = 62
        },
        QuickPreset(id: "prores4444", name: "ProRes 4444", detail: "Editing, keeps transparency",
                    symbol: "square.on.square.dashed", tint: Theme.yellow) { s in
            s.container = .mov
            s.videoCodec = .prores
            s.proresProfile = .p4444
            s.alphaMode = .preserve
            s.audioCodec = .pcm
        },
        QuickPreset(id: "webalpha", name: "Web alpha", detail: "WebM VP9 with transparency",
                    symbol: "checkerboard.rectangle", tint: Theme.indigo) { s in
            s.container = .webm
            s.videoCodec = .vp9
            s.alphaMode = .preserve
            s.audioCodec = .opus
            s.quality = 60
        },
        QuickPreset(id: "gif", name: "GIF", detail: "480p, 15 fps, loops",
                    symbol: "photo.stack", tint: Theme.pink) { s in
            s.container = .gif
            s.resolution = .p480
            s.frameRate = .fps15
        },
        QuickPreset(id: "audio", name: "Audio only", detail: "Pull the soundtrack out as M4A",
                    symbol: "waveform", tint: Theme.teal) { s in
            s.container = .m4a
            s.audioCodec = .aac
            s.audioBitrateKbps = 256
        },
        QuickPreset(id: "archive", name: "Archive", detail: "10-bit HEVC, lossless audio",
                    symbol: "archivebox", tint: Theme.red) { s in
            s.container = .mkv
            s.videoCodec = .hevc
            s.useHardwareEncoder = false // smallest files matter more than speed here
            s.quality = 85
            s.speed = .slow
            s.pixelFormat = .yuv420p10le
            s.audioCodec = .flac
        },
    ]
}
