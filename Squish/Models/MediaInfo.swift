import Foundation

struct MediaInfo: Equatable, Sendable {
    var duration: Double
    var sizeBytes: Int64
    var bitRate: Int
    /// Display size, with rotation metadata already applied.
    var width: Int
    var height: Int
    var frameRate: Double
    var videoCodec: String
    var pixelFormat: String
    var hasAlpha: Bool
    /// VP9 alpha lives in a side channel that only libvpx decodes.
    var needsLibvpxDecoder: Bool
    var hasAudio: Bool
    var audioCodec: String?
    var audioChannels: Int
    var sampleRate: Int

    var summary: String {
        var parts = ["\(width)×\(height)"]
        if frameRate > 0 { parts.append(String(format: frameRate.rounded() == frameRate ? "%.0f fps" : "%.2f fps", frameRate)) }
        parts.append(videoCodec.uppercased())
        if hasAlpha { parts.append("alpha") }
        if duration > 0 { parts.append(Format.duration(duration)) }
        return parts.joined(separator: " · ")
    }
}

enum MediaProbe {
    struct ProbeError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func probe(_ url: URL, ffprobe: URL) async throws -> MediaInfo {
        let result = try await ProcessRunner.run(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ])
        guard result.status == 0 else {
            throw ProbeError(message: String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let output = try JSONDecoder().decode(ProbeOutput.self, from: result.stdout)
        let streams = output.streams ?? []
        guard let video = streams.first(where: { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }) else {
            throw ProbeError(message: "No video stream found.")
        }
        let audio = streams.first(where: { $0.codec_type == "audio" })

        let pixFmt = video.pix_fmt ?? ""
        let alphaTag = video.tags?["alpha_mode"] ?? video.tags?["ALPHA_MODE"]
        let alphaFormats = ["yuva", "rgba", "argb", "bgra", "abgr", "gbrap", "ya8", "ya16", "pal8"]
        let hasAlpha = alphaTag == "1" || alphaFormats.contains(where: { pixFmt.hasPrefix($0) })

        var width = video.width ?? 0
        var height = video.height ?? 0
        let rotation = video.side_data_list?.compactMap(\.rotation).first ?? Double(video.tags?["rotate"] ?? "") ?? 0
        if Int(abs(rotation)) % 180 == 90 { swap(&width, &height) }

        let duration = Double(output.format?.duration ?? "") ?? Double(video.duration ?? "") ?? 0
        let fps = parseRate(video.avg_frame_rate) ?? parseRate(video.r_frame_rate) ?? 0

        return MediaInfo(
            duration: duration,
            sizeBytes: Int64(output.format?.size ?? "") ?? 0,
            bitRate: Int(output.format?.bit_rate ?? "") ?? 0,
            width: width,
            height: height,
            frameRate: fps,
            videoCodec: video.codec_name ?? "?",
            pixelFormat: pixFmt,
            hasAlpha: hasAlpha,
            needsLibvpxDecoder: video.codec_name == "vp9" && alphaTag == "1",
            hasAudio: audio != nil,
            audioCodec: audio?.codec_name,
            audioChannels: audio?.channels ?? 0,
            sampleRate: Int(audio?.sample_rate ?? "") ?? 0
        )
    }

    private static func parseRate(_ text: String?) -> Double? {
        guard let text else { return nil }
        let parts = text.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0, parts[0] != 0 else { return nil }
        return parts[0] / parts[1]
    }
}

private struct ProbeOutput: Decodable {
    struct SideData: Decodable {
        var rotation: Double?
    }

    struct Stream: Decodable {
        var codec_type: String?
        var codec_name: String?
        var width: Int?
        var height: Int?
        var pix_fmt: String?
        var r_frame_rate: String?
        var avg_frame_rate: String?
        var channels: Int?
        var sample_rate: String?
        var duration: String?
        var tags: [String: String]?
        var disposition: [String: Int]?
        var side_data_list: [SideData]?
    }

    struct FormatInfo: Decodable {
        var duration: String?
        var size: String?
        var bit_rate: String?
    }

    var streams: [Stream]?
    var format: FormatInfo?
}

// MARK: - Process helper

enum ProcessRunner {
    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    private final class Box: @unchecked Sendable {
        var data = Data()
    }

    /// Runs a short-lived process to completion and collects its output.
    static func run(_ executable: URL, _ arguments: [String]) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let errBox = Box()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Output(status: process.terminationStatus, stdout: outData, stderr: errBox.data))
            }
        }
    }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
