import Foundation

enum FFmpegError: LocalizedError {
    case exited(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .exited(code, message):
            let lines = message.split(separator: "\n").suffix(6).joined(separator: "\n")
            return lines.isEmpty ? "ffmpeg exited with code \(code)." : lines
        }
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
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let parser = ProgressParser(onProgress: onProgress)
        let errors = TextBuffer()
        out.fileHandleForReading.readabilityHandler = { handle in parser.feed(handle.availableData) }
        err.fileHandleForReading.readabilityHandler = { handle in errors.append(handle.availableData) }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { [weak self] finished in
                _ = FFmpegProcess.registryLock.withLock { FFmpegProcess.live.removeValue(forKey: ObjectIdentifier(finished)) }
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                errors.append(err.fileHandleForReading.readDataToEndOfFile())
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else if self?.isCancelled == true {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: FFmpegError.exited(code: finished.terminationStatus, message: errors.text))
                }
            }
            lock.withLock { self.process = process }
            do {
                try process.run()
                FFmpegProcess.registryLock.withLock { FFmpegProcess.live[ObjectIdentifier(process)] = process }
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
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

private final class ProgressParser: @unchecked Sendable {
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
