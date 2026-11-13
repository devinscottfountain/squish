import Foundation

struct MediaInfo: Equatable, Sendable {
    var duration: Double
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
    var colorTransfer: String
    var colorPrimaries: String
    /// "HLG", "HDR10" or "Dolby Vision" when the source is HDR.
    var hdrFormat: String?
    var hasAudio: Bool
    var audioCodec: String?
    var audioChannels: Int
    var sampleRate: Int

    var summary: String {
        var parts = ["\(width)×\(height)"]
        if frameRate > 0 { parts.append(String(format: frameRate.rounded() == frameRate ? "%.0f fps" : "%.2f fps", frameRate)) }
        parts.append(videoCodec.uppercased())
        if hasAlpha { parts.append("alpha") }
        if let hdrFormat { parts.append(hdrFormat) }
        if duration > 0 { parts.append(Format.duration(duration)) }
        return parts.joined(separator: " · ")
    }

    var isHDR: Bool { hdrFormat != nil }
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
        return try parse(result.stdout)
    }

    /// Reads ffprobe's `-show_format -show_streams` JSON.
    static func parse(_ data: Data) throws -> MediaInfo {
        let output = try JSONDecoder().decode(ProbeOutput.self, from: data)
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

        let transfer = video.color_transfer ?? ""
        let dolbyVision = video.side_data_list?.contains { ($0.side_data_type ?? "").contains("DOVI") } ?? false
        let hdrFormat: String? = switch transfer {
        case "arib-std-b67": dolbyVision ? "Dolby Vision" : "HLG"
        case "smpte2084": dolbyVision ? "Dolby Vision" : "HDR10"
        default: nil
        }

        return MediaInfo(
            duration: duration,
            bitRate: Int(output.format?.bit_rate ?? "") ?? 0,
            width: width,
            height: height,
            frameRate: fps,
            videoCodec: video.codec_name ?? "?",
            pixelFormat: pixFmt,
            hasAlpha: hasAlpha,
            needsLibvpxDecoder: video.codec_name == "vp9" && alphaTag == "1",
            colorTransfer: transfer,
            colorPrimaries: video.color_primaries ?? "",
            hdrFormat: hdrFormat,
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
        var side_data_type: String?
        var rotation: Double?
    }

    struct Stream: Decodable {
        var codec_type: String?
        var codec_name: String?
        var width: Int?
        var height: Int?
        var pix_fmt: String?
        var color_transfer: String?
        var color_primaries: String?
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

    /// Runs a short-lived process to completion and collects its output.
    static func run(_ executable: URL, _ arguments: [String]) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Buffer()
        let err = Buffer()
        let status = try await launch(process, stdout: { out.append($0) }, stderr: { err.append($0) })
        return Output(status: status, stdout: out.data, stderr: err.data)
    }

    /// Starts `process` with its output piped to the two callbacks and returns its exit status once it
    /// has exited and both pipes are drained. Nothing blocks a thread while it waits: GCD only has 64,
    /// and a folder of probes each parked on a read used to use them all up and hang.
    static func launch(_ process: Process,
                       stdout: @escaping @Sendable (Data) -> Void,
                       stderr: @escaping @Sendable (Data) -> Void,
                       onLaunch: (Process) -> Void = { _ in }) async throws -> Int32 {
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            let finish = Completion(process: process, continuation: continuation)
            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    finish.outputClosed()
                } else {
                    stdout(chunk)
                }
            }
            err.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    finish.outputClosed()
                } else {
                    stderr(chunk)
                }
            }
            process.terminationHandler = { finish.exited($0.terminationStatus) }
            do {
                try process.run()
                onLaunch(process)
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                finish.fail(error)
            }
        }
    }

    /// Resumes once, after the exit and both end-of-files, in whatever order they arrive.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var openPipes = 2
        private var status: Int32?
        // Held so the process outlives its handlers.
        private var process: Process?
        private var continuation: CheckedContinuation<Int32, Error>?

        init(process: Process, continuation: CheckedContinuation<Int32, Error>) {
            self.process = process
            self.continuation = continuation
        }

        func outputClosed() {
            resumeIfDone { openPipes -= 1 }
        }

        func exited(_ code: Int32) {
            resumeIfDone { status = code }
        }

        func fail(_ error: Error) {
            let pending = lock.withLock { () -> CheckedContinuation<Int32, Error>? in
                defer { continuation = nil; process = nil }
                return continuation
            }
            pending?.resume(throwing: error)
        }

        private func resumeIfDone(_ update: () -> Void) {
            let ready = lock.withLock { () -> (CheckedContinuation<Int32, Error>, Int32)? in
                update()
                guard openPipes <= 0, let status, let continuation else { return nil }
                self.continuation = nil
                process = nil
                return (continuation, status)
            }
            if let ready { ready.0.resume(returning: ready.1) }
        }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ chunk: Data) { lock.withLock { storage.append(chunk) } }
        var data: Data { lock.withLock { storage } }
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
