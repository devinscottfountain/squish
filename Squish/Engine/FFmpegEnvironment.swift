import Foundation
import Observation

/// Finds ffmpeg/ffprobe on this Mac and learns which encoders the build has.
@MainActor @Observable
final class FFmpegEnvironment {
    var ffmpeg: URL?
    var ffprobe: URL?
    var version: String?
    var encoders: Set<String> = []
    var filters: Set<String> = []
    var isChecking = false
    /// True when the ffmpeg found is an Intel build, so it runs translated and much slower.
    var isTranslated = false

    private static let customPathKey = "customFFmpegPath"
    private static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    var isAvailable: Bool { ffmpeg != nil }

    /// The ffmpeg shipped inside Squish.app (release builds), next to its ffprobe.
    static let bundledBinary = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")

    /// Where the ffmpeg in use came from, for display.
    var source: String {
        guard let ffmpeg else { return "" }
        if ffmpeg.standardizedFileURL == Self.bundledBinary.standardizedFileURL { return "Bundled" }
        return hasCustomBinary ? "Custom" : "Installed"
    }

    func refresh() async {
        isChecking = true
        defer { isChecking = false }

        var candidates: [URL] = []
        if let custom = UserDefaults.standard.string(forKey: Self.customPathKey) {
            candidates.append(URL(fileURLWithPath: custom))
        }
        // A binary the user picked wins; then the copy inside the app; then Homebrew and friends.
        candidates.append(Self.bundledBinary)
        candidates += Self.searchDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg") }

        let fm = FileManager.default
        guard let found = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            ffmpeg = nil
            ffprobe = nil
            version = nil
            encoders = []
            filters = []
            return
        }
        ffmpeg = found
        if let lipo = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/lipo"), ["-archs", found.path]) {
            let archs = String(decoding: lipo.stdout, as: UTF8.self)
            isTranslated = !archs.isEmpty && !archs.contains("arm64")
        }
        let probe = found.deletingLastPathComponent().appendingPathComponent("ffprobe")
        ffprobe = fm.isExecutableFile(atPath: probe.path) ? probe : nil

        if let result = try? await ProcessRunner.run(found, ["-hide_banner", "-version"]) {
            let firstLine = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").first ?? ""
            let words = firstLine.split(separator: " ")
            if words.count > 2 { version = String(words[2].prefix(14)) }
        }
        if let result = try? await ProcessRunner.run(found, ["-hide_banner", "-encoders"]) {
            var names = Set<String>()
            for line in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") {
                let words = line.split(separator: " ", omittingEmptySubsequences: true)
                guard words.count >= 2, words[0].count == 6, words[0] != "------" else { continue }
                names.insert(String(words[1]))
            }
            encoders = names
        }
        if let result = try? await ProcessRunner.run(found, ["-hide_banner", "-filters"]) {
            // Lines look like " TS colorspace  V->V  Convert between colorspaces."
            var names = Set<String>()
            for line in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") {
                let words = line.split(separator: " ", omittingEmptySubsequences: true)
                guard words.count >= 3, words[0].count == 2, words[2].contains("->") else { continue }
                names.insert(String(words[1]))
            }
            filters = names
        }
    }

    // MARK: What this build can make

    private func has(_ name: String) -> Bool { encoders.isEmpty || encoders.contains(name) }

    /// Whether this build includes an encoder (assumes yes until the build has been checked).
    func supports(_ encoder: String) -> Bool { has(encoder) }
    func supports(filter: String) -> Bool { filters.isEmpty || filters.contains(filter) }

    /// The library a container needs, if this ffmpeg lacks it.
    func missingLibrary(for container: Container) -> String? {
        switch container {
        case .webp: has("libwebp_anim") || has("libwebp") ? nil : "libwebp"
        case .webm: has("libvpx-vp9") || has("libsvtav1") || has("libaom-av1") ? nil : "libvpx"
        default: nil
        }
    }

    func missingLibrary(for codec: VideoCodec, hardware: Bool) -> String? {
        let needed: [String] = switch codec {
        // With hardware on, the software encoder is an acceptable fallback.
        case .h264: hardware ? ["h264_videotoolbox", "libx264"] : ["libx264"]
        case .hevc: hardware ? ["hevc_videotoolbox", "libx265"] : ["libx265"]
        case .av1: ["libsvtav1", "libaom-av1"]
        case .vp9: ["libvpx-vp9"]
        case .prores: [hardware ? "prores_videotoolbox" : "prores_ks", "prores_ks"]
        case .copy: []
        }
        guard !needed.isEmpty, !needed.contains(where: has) else { return nil }
        return needed[0]
    }

    func missingLibrary(for codec: AudioCodec) -> String? {
        let needed: String? = switch codec {
        case .opus: "libopus"
        case .mp3: "libmp3lame"
        case .aac: "aac"
        case .flac: "flac"
        case .alac: "alac"
        case .pcm: "pcm_s16le"
        case .copy, .none: nil
        }
        guard let needed, !has(needed) else { return nil }
        return needed
    }

    /// A plain sentence describing the first thing these settings need that this ffmpeg can't do.
    func problem(with settings: EncodeSettings) -> String? {
        var s = settings
        s.normalize()
        if let lib = missingLibrary(for: s.container) {
            return "\(s.container.label) needs \(lib), which this ffmpeg doesn't include."
        }
        guard !s.container.isAnimatedImage else { return nil }
        if !s.container.isAudioOnly, let lib = missingLibrary(for: s.videoCodec, hardware: s.hardwareEncoding) {
            return "\(s.videoCodec.label) needs \(lib), which this ffmpeg doesn't include."
        }
        if let lib = missingLibrary(for: s.audioCodec) {
            return "\(s.audioCodec.label) audio needs \(lib), which this ffmpeg doesn't include."
        }
        return nil
    }

    func useCustomBinary(_ url: URL) async {
        UserDefaults.standard.set(url.path, forKey: Self.customPathKey)
        await refresh()
    }

    var hasCustomBinary: Bool { UserDefaults.standard.string(forKey: Self.customPathKey) != nil }

    /// Forgets a chosen binary and goes back to searching Homebrew and the usual places.
    func useDefaultBinary() async {
        UserDefaults.standard.removeObject(forKey: Self.customPathKey)
        await refresh()
    }
}
