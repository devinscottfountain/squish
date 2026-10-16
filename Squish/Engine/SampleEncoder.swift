import Foundation

/// Encodes short slices of a clip with the real settings, for size estimates and before/after previews.
struct SampleEncoder {
    var ffmpeg: URL
    var encoders: Set<String>
    var filters: Set<String>

    struct Sample {
        var output: URL
        var bytes: Int64
        /// Seconds of output the sample covers.
        var outDuration: Double
    }

    static var workDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squish-samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The part of the source the user's trim keeps, in source seconds.
    static func keptRange(_ s: EncodeSettings, media: MediaInfo) -> ClosedRange<Double> {
        let start = min(max(0, s.trimStart), media.duration)
        let end = s.trimEnd > start ? min(s.trimEnd, media.duration) : media.duration
        return start...max(start, end)
    }

    /// Encodes `length` source seconds starting at `start` with the given settings.
    func encode(input: URL, media: MediaInfo, settings: EncodeSettings, start: Double, length: Double,
                process: FFmpegProcess) async throws -> Sample {
        var s = settings
        s.normalize()
        s.trimStart = start
        s.trimEnd = start + length
        s.fadeIn = 0
        s.fadeOut = 0
        s.reverse = false
        s.stripMetadata = true
        let name = "sample-\(UUID().uuidString.prefix(8))"
        let output = s.container == .pngSequence
            ? Self.workDirectory.appendingPathComponent(name, isDirectory: true)
            : Self.workDirectory.appendingPathComponent(name).appendingPathExtension(s.container.fileExtension)
        if s.container == .pngSequence {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        let plan = CommandBuilder(settings: s, input: input, output: output, media: media,
                                  encoders: encoders, filters: filters).plan()
        for pass in plan.passes {
            try await process.run(binary: ffmpeg, arguments: pass) { _, _ in }
        }
        return Sample(output: output, bytes: Self.size(of: output), outDuration: plan.expectedDuration)
    }

    /// Renders one frame at `sourceTime` through the same filters but with no compression,
    /// so differences against the encoded frame are purely compression.
    func referenceFrame(input: URL, media: MediaInfo, settings: EncodeSettings, sourceTime: Double,
                        process: FFmpegProcess) async throws -> URL {
        var s = settings
        s.normalize()
        let keepsAlpha = s.producesAlpha(sourceHasAlpha: media.hasAlpha)
        s.container = .pngSequence
        if !keepsAlpha && s.alphaMode != .chromaKey { s.alphaMode = .flatten }
        s.trimStart = sourceTime
        s.trimEnd = sourceTime + 1
        s.fadeIn = 0
        s.fadeOut = 0
        s.reverse = false
        s.extraArguments = "-frames:v 1"
        let dir = Self.workDirectory.appendingPathComponent("ref-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plan = CommandBuilder(settings: s, input: input, output: dir, media: media,
                                  encoders: encoders, filters: filters).plan()
        try await process.run(binary: ffmpeg, arguments: plan.passes[plan.passes.count - 1]) { _, _ in }
        return try Self.firstFile(in: dir)
    }

    /// Pulls one frame out of an encoded sample as PNG.
    func frame(from sample: URL, at time: Double, settings: EncodeSettings, process: FFmpegProcess) async throws -> URL {
        var settings = settings
        settings.normalize()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sample.path, isDirectory: &isDir), isDir.boolValue {
            return try Self.firstFile(in: sample)
        }
        let out = Self.workDirectory.appendingPathComponent("frame-\(UUID().uuidString.prefix(8)).png")
        var args = ["-hide_banner", "-y", "-ss", num(max(0, time))]
        // The built-in VP9 decoder drops alpha; libvpx keeps it.
        if settings.videoCodec == .vp9 && !settings.container.isAnimatedImage { args += ["-c:v", "libvpx-vp9"] }
        args += ["-i", sample.path, "-frames:v", "1", "-pix_fmt", "rgba", out.path]
        try await process.run(binary: ffmpeg, arguments: args) { _, _ in }
        return out
    }

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    private static func firstFile(in dir: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let first = files.first else { throw MediaProbe.ProbeError(message: "No frame was produced.") }
        return first
    }
}
