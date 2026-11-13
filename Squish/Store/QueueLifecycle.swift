import Foundation

/// Saving and restoring the queue across launches, keeping the Mac awake during a batch,
/// and leaving nothing behind on quit.
extension QueueStore {
    private struct SavedJob: Codable {
        enum State: String, Codable { case ready, done, failed, cancelled, interrupted }

        var input: String
        var state: State
        var output: String?
        var outputSize: Int64?
        var message: String?
        /// Pinned per-file settings, stored as raw JSON so they survive new options.
        var settings: Data?
    }

    private static var queueFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Squish", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("queue.json")
    }

    /// Queue writes happen here, in order, so a big queue's file write never holds up the main thread.
    private static let saveIO = DispatchQueue(label: "Squish.saveQueue", qos: .utility)

    // MARK: Queue persistence

    /// - Parameter waits: true to finish writing before returning (quitting), after any earlier saves.
    func saveQueue(waits: Bool = false) {
        guard persistsState else { return }
        let saved = jobs.map { job -> SavedJob in
            let state: SavedJob.State = switch job.status {
            case .done: .done
            case .failed: .failed
            case .cancelled: .cancelled
            case .encoding: .interrupted
            case .probing, .ready, .queued: .ready
            }
            return SavedJob(input: job.input.path, state: state, output: job.output?.path,
                            outputSize: job.outputSize, message: job.message,
                            settings: job.customSettings.flatMap { try? JSONEncoder().encode($0) })
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        let file = Self.queueFile
        let write: @Sendable () -> Void = { try? data.write(to: file, options: .atomic) }
        if waits { Self.saveIO.sync(execute: write) } else { Self.saveIO.async(execute: write) }
    }

    /// Brings back the last session's queue. Files that moved or were deleted are skipped.
    func restoreQueue() {
        guard let data = try? Data(contentsOf: Self.queueFile),
              let saved = try? JSONDecoder().decode([SavedJob].self, from: data) else { return }
        let fm = FileManager.default
        var known = Set(jobs.map(\.input.path))
        var restored: [EncodeJob] = []
        for item in saved where fm.fileExists(atPath: item.input) {
            let input = URL(fileURLWithPath: item.input)
            guard known.insert(input.path).inserted else { continue }
            let job = EncodeJob(input: input)
            job.customSettings = item.settings.flatMap(EncodeSettings.decodeLenient)
            let output = item.output.map { URL(fileURLWithPath: $0) }
            switch item.state {
            case .done where output.map({ fm.fileExists(atPath: $0.path) }) == true:
                job.status = .done
                job.output = output
                job.outputSize = item.outputSize
                job.progress = 1
                job.hasCelebrated = true
            case .failed:
                job.status = .failed
                job.message = item.message
            case .interrupted:
                // Squish quit or crashed mid-encode, so whatever is on disk is a partial file.
                if let output { try? fm.removeItem(at: output) }
                job.status = .cancelled
                job.message = "Stopped when Squish quit"
            case .cancelled:
                job.status = .cancelled
                job.message = item.message
            case .ready, .done:
                job.status = .probing
            }
            restored.append(job)
        }
        jobs.append(contentsOf: restored)
    }

    // MARK: Staying awake

    /// Holds off idle system sleep while a batch runs. The display may still sleep.
    func beginKeepAwake() {
        guard keepAwakeActivity == nil else { return }
        keepAwakeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Squish is encoding videos"
        )
    }

    func endKeepAwake() {
        guard let activity = keepAwakeActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        keepAwakeActivity = nil
    }

    // MARK: Quitting

    /// Stops every ffmpeg Squish started, deletes the unfinished output and temporary files,
    /// and saves the queue so it's waiting next time.
    func prepareForQuit() {
        cancelBackgroundWork()
        FFmpegProcess.terminateAll()

        let fm = FileManager.default
        for job in jobs where job.status == .encoding {
            if let output = job.output { try? fm.removeItem(at: output) }
            job.status = .cancelled
            job.message = "Stopped when Squish quit"
        }
        for job in jobs where job.status == .queued { job.status = .ready }

        // Samples, preview frames and two-pass logs all live in the temp folder under "squish-".
        let temp = fm.temporaryDirectory
        for item in (try? fm.contentsOfDirectory(atPath: temp.path)) ?? [] where item.hasPrefix("squish-") {
            try? fm.removeItem(at: temp.appendingPathComponent(item))
        }

        endKeepAwake()
        clearDockProgress()
        saveQueue(waits: true)
        persist()
    }
}
