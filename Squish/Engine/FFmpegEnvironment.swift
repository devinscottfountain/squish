import Foundation
import Observation

/// Finds ffmpeg/ffprobe on this Mac and learns which encoders the build has.
@MainActor @Observable
final class FFmpegEnvironment {
    var ffmpeg: URL?
    var ffprobe: URL?
    var version: String?
    var encoders: Set<String> = []
    var isChecking = false

    private static let customPathKey = "customFFmpegPath"
    private static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    var isAvailable: Bool { ffmpeg != nil }

    func refresh() async {
        isChecking = true
        defer { isChecking = false }

        var candidates: [URL] = []
        if let custom = UserDefaults.standard.string(forKey: Self.customPathKey) {
            candidates.append(URL(fileURLWithPath: custom))
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg") { candidates.append(bundled) }
        candidates += Self.searchDirectories.map { URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg") }

        let fm = FileManager.default
        guard let found = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            ffmpeg = nil
            ffprobe = nil
            version = nil
            encoders = []
            return
        }
        ffmpeg = found
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
    }

    func useCustomBinary(_ url: URL) async {
        UserDefaults.standard.set(url.path, forKey: Self.customPathKey)
        await refresh()
    }
}
