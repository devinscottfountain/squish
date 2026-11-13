import Foundation

enum FFmpegError: LocalizedError {
    case exited(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .exited(code, message):
            let lines = message.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return "ffmpeg exited with code \(code)." }
            // ffmpeg's first real complaint is the cause; what follows is usually fallout like
            // "Task finished…" or "Nothing was written…". Lead with the cause, then the tail for context.
            let fallout = ["Task finished", "Terminating thread", "Nothing was written", "Error sending frames",
                           "Could not open encoder", "Error while opening encoder", "Conversion failed"]
            let cause = lines.first { line in !fallout.contains { line.contains($0) } } ?? lines[0]
            let tail = lines.suffix(4).filter { $0 != cause }
            return ([Self.readable(cause)] + tail).joined(separator: "\n")
        }
    }

    /// Drops ffmpeg's "[libx264 @ 0x…] " prefix so the cause reads as a sentence.
    static func readable(_ line: String) -> String {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? line : rest.prefix(1).uppercased() + rest.dropFirst()
    }
}

/// One cancellable ffmpeg run at a time, reporting progress from `-progress pipe:1`.
final class FFmpegProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    // Every ffmpeg Squish has started and that hasn't exited yet. Child processes outlive
    // their parent on macOS, so quitting has to stop these explicitly.
    private static let registryLock = NSLock()
    private static var live: [ObjectIdentifier: Process] = [:]

    /// Stops every running ffmpeg: a polite SIGTERM, then SIGKILL for anything still alive after `timeout`.
    static func terminateAll(timeout: TimeInterval = 1.5) {
        let running = registryLock.withLock { Array(live.values) }
        for p in running where p.isRunning { p.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while running.contains(where: \.isRunning) && Date() < deadline { usleep(20_000) }
        for p in running where p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let running = lock.withLock { () -> Process? in
            cancelled = true
            return process
        }
        if let running, running.isRunning { running.terminate() }
    }

    func run(binary: URL, arguments: [String],
             onProgress: @escaping @Sendable (_ seconds: Double, _ speed: Double?) -> Void) async throws {
        if isCancelled { throw CancellationError() }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["-progress", "pipe:1", "-nostats", "-loglevel", "error"] + arguments
        // SVT-AV1 prints "Svt[info]" banners to stderr whatever -loglevel says; 1 keeps only its errors,
        // so a failure message is about the failure.
        process.environment = ProcessInfo.processInfo.environment.merging(["SVT_LOG": "1"]) { _, new in new }

        let parser = ProgressParser(onProgress: onProgress)
        let errors = TextBuffer()
        let status = try await ProcessRunner.launch(process, stdout: { parser.feed($0) },
                                                    stderr: { errors.append($0) }) { launched in
            lock.withLock { self.process = launched }
            FFmpegProcess.registryLock.withLock { FFmpegProcess.live[ObjectIdentifier(launched)] = launched }
            // cancel() may have landed while the process was starting, before there was anything to stop.
            if isCancelled { launched.terminate() }
        }
        _ = FFmpegProcess.registryLock.withLock { FFmpegProcess.live.removeValue(forKey: ObjectIdentifier(process)) }
        if status == 0 { return }
        if isCancelled { throw CancellationError() }
        throw FFmpegError.exited(code: status, message: errors.text)
    }
}

private final class TextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock { data.append(chunk) }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// Turns `-progress` key=value lines into (seconds written, speed) updates, one per block.
final class ProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var seconds: Double = 0
    private var speed: Double?
    private let onProgress: @Sendable (Double, Double?) -> Void

    init(onProgress: @escaping @Sendable (Double, Double?) -> Void) {
        self.onProgress = onProgress
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        var updates: [(Double, Double?)] = []
        lock.withLock {
            buffer += String(decoding: data, as: UTF8.self)
            while let newline = buffer.firstIndex(of: "\n") {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                switch parts[0] {
                case "out_time_us", "out_time_ms":
                    if let micro = Double(value) { seconds = max(0, micro / 1_000_000) }
                case "speed":
                    speed = Double(value.replacingOccurrences(of: "x", with: ""))
                case "progress":
                    updates.append((seconds, speed))
                default:
                    break
                }
            }
        }
        for update in updates { onProgress(update.0, update.1) }
    }
}
