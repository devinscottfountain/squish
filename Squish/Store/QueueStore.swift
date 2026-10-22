import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class EncodeJob: Identifiable {
    enum Status: Equatable {
        case probing, ready, queued, encoding, done, failed, cancelled
    }

    let id = UUID()
    let input: URL
    let inputSize: Int64
    var media: MediaInfo?
    var status: Status = .probing
    var progress: Double = 0
    var encodeSpeed: Double?
    var eta: TimeInterval?
    var pass = 1
    var passCount = 1
    var output: URL?
    var outputSize: Int64?
    var message: String?
    var warnings: [String] = []
    var command: String?
    var startedAt: Date?
    /// Predicted output size for the current settings.
    var estimate: Int64?
    var isEstimating = false
    /// The big-win shimmer plays once per result, not on every redraw.
    var hasCelebrated = false
    /// Before/after frames for the live thumbnail, with the settings they were made with.
    var thumbnail: PreviewThumbnail?
    var isMakingThumbnail = false
    /// Settings pinned to this file. When nil it follows the shared settings panel.
    var customSettings: EncodeSettings?
    /// The settings this file was queued with, fixed for the length of its run.
    var runSettings: EncodeSettings?

    init(input: URL) {
        self.input = input
        inputSize = Int64((try? input.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    var name: String { input.lastPathComponent }
    var isRunnable: Bool { status == .ready || status == .failed || status == .cancelled }
    /// Finished files can be squished again, e.g. after changing settings. Earlier output is kept.
    var canRunAgain: Bool { isRunnable || status == .done }

    var savings: Double? {
        guard let outputSize, inputSize > 0 else { return nil }
        return 1 - Double(outputSize) / Double(inputSize)
    }
}

@MainActor @Observable
final class QueueStore {
    enum Mode: String {
        case simple, advanced
    }

    var jobs: [EncodeJob] = []
    var settings: EncodeSettings
    var mode: Mode
    var selectedPresetID: String?
    var savedPresets: [SavedPreset] = []
    /// Drives the "name your preset" prompt.
    var isNamingPreset = false
    /// The job shown in the before/after sheet.
    var previewJob: EncodeJob?
    /// The row the user last clicked: the live thumbnail and Space-to-preview follow it.
    var selectedJobID: UUID?
    /// Finish sound on/off (it also follows the system's UI sound setting).
    let persistsState: Bool
    var playSounds: Bool { didSet { if persistsState { UserDefaults.standard.set(playSounds, forKey: Self.soundKey) } } }
    /// Light, dark, or follow the system.
    var appearance: Appearance { didSet { if persistsState { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) } } }
    /// How many files encode at the same time.
    var concurrentJobs: Int { didSet { if persistsState { UserDefaults.standard.set(concurrentJobs, forKey: Self.concurrencyKey) } } }
    /// Bytes saved across every file Squish has ever finished.
    private(set) var lifetimeSavedBytes: Int64
    private(set) var lifetimeFiles: Int
    /// Briefly true after a finished batch is cleared, so the empty state can say "All squished."
    var showAllSquished = false
    var isRunning = false
    let environment = FFmpegEnvironment()

    /// One ffmpeg per file that's encoding right now, so each can be stopped on its own.
    @ObservationIgnored private var processes: [UUID: FFmpegProcess] = [:]
    /// Output paths claimed by running encodes, so parallel jobs never pick the same name.
    @ObservationIgnored private var reservedOutputs: Set<String> = []
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var estimateTask: Task<Void, Never>?
    @ObservationIgnored private var estimatesInFlight = false
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailProcess: FFmpegProcess?
    @ObservationIgnored private var batch: [EncodeJob] = []
    @ObservationIgnored private var allSquishedTask: Task<Void, Never>?
    @ObservationIgnored private var estimateProcess: FFmpegProcess?
    @ObservationIgnored var keepAwakeActivity: NSObjectProtocol?
    /// Settings the current estimates were made with, so unrelated changes don't redo them.
    @ObservationIgnored private var estimatedSettings: EncodeSettings?

    private static let settingsKey = "settings.v1"
    private static let modeKey = "mode"
    private static let presetKey = "preset"
    private static let savedPresetsKey = "savedPresets.v1"
    private static let soundKey = "playSounds"
    private static let concurrencyKey = "concurrentJobs"
    private static let appearanceKey = "appearance"
    private static let lifetimeBytesKey = "lifetimeSavedBytes"
    private static let lifetimeFilesKey = "lifetimeFiles"

    static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "gif", "webp", "apng", "mxf", "mts", "m2ts", "ts",
        "flv", "wmv", "mpg", "mpeg", "3gp", "ogv", "y4m", "hevc", "h264",
    ]

    /// - Parameter persistsState: false gives a throwaway store (for tests) that never reads or writes
    ///   your saved settings, presets, queue or lifetime totals.
    init(persistsState: Bool = true) {
        self.persistsState = persistsState
        let defaults: UserDefaults? = persistsState ? .standard : nil
        if let data = defaults?.data(forKey: Self.settingsKey),
           let saved = EncodeSettings.decodeLenient(data) {
            settings = saved
        } else {
            settings = EncodeSettings()
        }
        mode = Mode(rawValue: defaults?.string(forKey: Self.modeKey) ?? "") ?? .simple
        selectedPresetID = defaults?.string(forKey: Self.presetKey) ?? "smaller"
        if let data = defaults?.data(forKey: Self.savedPresetsKey),
           let presets = try? JSONDecoder().decode([SavedPreset].self, from: data) {
            savedPresets = presets
        }
        playSounds = defaults?.object(forKey: Self.soundKey) as? Bool ?? true
        appearance = Appearance(rawValue: defaults?.string(forKey: Self.appearanceKey) ?? "") ?? .system
        // One at a time by default: each encode already uses every core (measured on an M4 Pro).
        concurrentJobs = min(max(defaults?.object(forKey: Self.concurrencyKey) as? Int ?? 1, 1), 4)
        lifetimeSavedBytes = Int64(defaults?.integer(forKey: Self.lifetimeBytesKey) ?? 0)
        lifetimeFiles = defaults?.integer(forKey: Self.lifetimeFilesKey) ?? 0
        if persistsState { restoreQueue() }
    }

    func persist() {
        guard persistsState else { return }
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(selectedPresetID, forKey: Self.presetKey)
        if let data = try? JSONEncoder().encode(savedPresets) { defaults.set(data, forKey: Self.savedPresetsKey) }
    }

    // MARK: Settings

    /// A binding into settings that keeps codec choices valid after every change.
    func bind<T>(_ keyPath: WritableKeyPath<EncodeSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in
                self.settings[keyPath: keyPath] = newValue
                self.settings.normalize()
            }
        )
    }

    /// Why a built-in preset can't run on this ffmpeg, or nil if it can.
    func problem(with preset: QuickPreset) -> String? {
        var candidate = settings
        candidate.resetEncoding()
        preset.apply(&candidate)
        return environment.problem(with: candidate)
    }

    func apply(_ preset: QuickPreset) {
        var next = settings
        next.resetEncoding()
        preset.apply(&next)
        next.normalize()
        withAnimation(.snappy(duration: 0.25)) {
            settings = next
            selectedPresetID = preset.id
        }
    }

    func apply(_ preset: SavedPreset) {
        var next = preset.settings
        next.adoptOutput(from: settings)
        next.normalize()
        withAnimation(.snappy(duration: 0.25)) {
            settings = next
            selectedPresetID = preset.selectionID
        }
    }

    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = SavedPreset(name: trimmed, settings: settings)
        withAnimation(.snappy) {
            savedPresets.append(preset)
            selectedPresetID = preset.selectionID
        }
        persist()
    }

    func updatePreset(_ preset: SavedPreset) {
        guard let i = savedPresets.firstIndex(where: { $0.id == preset.id }) else { return }
        savedPresets[i].settings = settings
        selectedPresetID = preset.selectionID
        persist()
    }

    func deletePreset(_ preset: SavedPreset) {
        withAnimation(.snappy) { savedPresets.removeAll { $0.id == preset.id } }
        if selectedPresetID == preset.selectionID { selectedPresetID = nil }
        persist()
    }

    var simpleTransparency: Bool {
        get { settings.alphaMode != .flatten && settings.outputSupportsAlpha }
        set {
            if newValue {
                if settings.alphaMode == .flatten { settings.alphaMode = .auto }
                if !settings.outputSupportsAlpha {
                    switch settings.container {
                    case .mp4, .mov:
                        settings.container = .mov
                        settings.videoCodec = .prores
                        settings.proresProfile = .p4444
                    case .webm, .mkv:
                        settings.videoCodec = .vp9
                    default:
                        break
                    }
                }
            } else {
                settings.alphaMode = .flatten
            }
            settings.normalize()
        }
    }

    // MARK: Queue

    var runnableCount: Int { jobs.filter(\.isRunnable).count }
    var hasFinished: Bool { jobs.contains { $0.status == .done } }

    func add(urls: [URL]) {
        let expanded = expand(urls)
        // Adding a file that already finished readies it for another pass instead of being ignored.
        for job in jobs where job.status == .done && expanded.contains(job.input) {
            withAnimation(.snappy) { job.status = .ready }
        }
        let fresh = expanded.filter { url in !jobs.contains(where: { $0.input == url }) }
        for (index, url) in fresh.enumerated() {
            let job = EncodeJob(input: url)
            // Rows cascade in 40 ms apart (capped, so a folder of 200 clips doesn't take seconds).
            withAnimation(Motion.out(0.25).delay(Double(min(index, 8)) * 0.04)) { jobs.append(job) }
            Task { await probe(job) }
        }
        saveQueue()
    }

    func remove(_ job: EncodeJob) {
        if job.status == .encoding { return }
        withAnimation(.snappy) { jobs.removeAll { $0.id == job.id } }
        saveQueue()
    }

    /// - Parameter animated: false for keyboard shortcuts, which should feel instant.
    func clearFinished(animated: Bool = true) {
        if animated {
            withAnimation(Motion.exit) { jobs.removeAll { $0.status == .done } }
        } else {
            jobs.removeAll { $0.status == .done }
        }
        saveQueue()
        guard jobs.isEmpty else { return }
        // A short "All squished." in the empty state, then back to normal.
        allSquishedTask?.cancel()
        withAnimation(Motion.out(0.25)) { showAllSquished = true }
        allSquishedTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.out(0.2)) { showAllSquished = false }
        }
    }

    func reprobeAll() {
        for job in jobs where job.media == nil { Task { await probe(job) } }
    }

    private func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let item = items?.nextObject() as? URL {
                    if isMedia(item) { result.append(item) }
                }
            } else if isMedia(url) {
                result.append(url)
            }
        }
        return result
    }

    private func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if Self.mediaExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    private func probe(_ job: EncodeJob) async {
        guard let ffprobe = environment.ffprobe else {
            if job.status == .probing { job.status = .ready }
            return
        }
        // Restored jobs keep their Done / Failed / Stopped state; only fresh ones show "Reading..".
        if job.status == .ready { job.status = .probing }
        do {
            job.media = try await MediaProbe.probe(job.input, ffprobe: ffprobe)
            if job.status == .probing { job.status = .ready }
            scheduleEstimates(force: true)
        } catch {
            guard job.status == .probing else { return }
            job.status = .failed
            job.message = "Couldn't read this file. \(error.localizedDescription)"
        }
    }

    // MARK: Encoding

    func plan(for job: EncodeJob?) -> EncodePlan {
        let input = job?.input ?? URL(fileURLWithPath: "/path/to/input.mov")
        let settings = job.map(effectiveSettings) ?? settings
        return CommandBuilder(settings: settings, input: input, output: outputURL(for: input, settings: settings),
                              media: job?.media, encoders: environment.encoders, filters: environment.filters).plan()
    }

    var sampleEncoder: SampleEncoder? {
        environment.ffmpeg.map { SampleEncoder(ffmpeg: $0, encoders: environment.encoders, filters: environment.filters) }
    }

    // MARK: Estimates

    /// Re-estimates output sizes shortly after settings settle. Cheap cases are computed, the rest sample-encoded.
    func scheduleEstimates(force: Bool = false) {
        guard force || estimatedSettings != settings else { return }
        estimateTask?.cancel()
        estimateProcess?.cancel()
        estimatedSettings = settings
        for job in jobs where job.status == .ready { job.isEstimating = true }
        let snapshot = settings
        estimatesInFlight = true
        estimateTask = Task {
            defer { if !Task.isCancelled { estimatesInFlight = false } }
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, !isRunning, let encoder = sampleEncoder else {
                for job in jobs { job.isEstimating = false }
                return
            }
            // The previewed file goes first, and its sample doubles as the live thumbnail.
            let target = previewTarget
            let ready = jobs.filter { $0.status == .ready }
            let ordered = ready.filter { $0.id == target?.id } + ready.filter { $0.id != target?.id }
            for job in ordered {
                guard !Task.isCancelled else { return }
                job.isEstimating = true
                let wantsThumbnail = job.id == target?.id && !thumbnailIsCurrent(for: job)
                job.estimate = await estimate(job, settings: job.customSettings ?? snapshot, encoder: encoder,
                                              makeThumbnail: wantsThumbnail)
                job.isEstimating = false
            }
            // A target that isn't waiting to encode (say, already done) still gets a fresh thumbnail.
            if !Task.isCancelled, let target = previewTarget, !thumbnailIsCurrent(for: target) {
                await makeThumbnail(for: target, encoder: encoder)
            }
        }
    }

    // MARK: Live preview

    /// The file the live thumbnail and Space-to-preview use: the selected row, else the first previewable one.
    var previewTarget: EncodeJob? {
        let previewable: (EncodeJob) -> Bool = { job in
            job.media != nil && job.status != .encoding && job.status != .probing
                && !self.effectiveSettings(for: job).container.isAudioOnly
                && self.effectiveSettings(for: job).videoCodec != .copy
        }
        if let id = selectedJobID, let job = jobs.first(where: { $0.id == id }), previewable(job) { return job }
        return jobs.first(where: previewable)
    }

    func thumbnailIsCurrent(for job: EncodeJob) -> Bool {
        job.thumbnail?.settings == effectiveSettings(for: job)
    }

    /// Refreshes the live thumbnail on its own (selection changes, a new file at the top), unless the
    /// estimate pass is about to do it anyway.
    func scheduleThumbnail() {
        guard !isRunning, !estimatesInFlight else { return }
        thumbnailTask?.cancel()
        thumbnailProcess?.cancel()
        thumbnailTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, !isRunning, let encoder = sampleEncoder,
                  let target = previewTarget, !thumbnailIsCurrent(for: target) else { return }
            await makeThumbnail(for: target, encoder: encoder)
        }
    }

    /// A short sample from the middle, just for the thumbnail.
    private func makeThumbnail(for job: EncodeJob, encoder: SampleEncoder) async {
        guard let media = job.media else { return }
        let s = effectiveSettings(for: job)
        let kept = SampleEncoder.keptRange(s, media: media)
        let span = kept.upperBound - kept.lowerBound
        let length = min(1.5, span)
        guard length > 0.2 else { return }
        let start = kept.lowerBound + (span - length) / 2
        let process = FFmpegProcess()
        thumbnailProcess = process
        job.isMakingThumbnail = true
        defer { job.isMakingThumbnail = false }
        guard let sample = try? await encoder.encode(input: job.input, media: media, settings: s, start: start,
                                                     length: length, process: process) else { return }
        defer { try? FileManager.default.removeItem(at: sample.output) }
        await captureThumbnail(job, settings: s, media: media, encoder: encoder, sample: sample, start: start, process: process)
    }

    /// Grabs the middle frame of an encoded sample and the same frame rendered without compression.
    private func captureThumbnail(_ job: EncodeJob, settings s: EncodeSettings, media: MediaInfo, encoder: SampleEncoder,
                                  sample: SampleEncoder.Sample, start: Double, process: FFmpegProcess) async {
        let outTime = sample.outDuration / 2
        let speed = min(max(s.playbackSpeed, 0.25), 4)
        guard let afterURL = try? await encoder.frame(from: sample.output, at: outTime, settings: s, process: process),
              let beforeURL = try? await encoder.referenceFrame(input: job.input, media: media, settings: s,
                                                                sourceTime: start + outTime * speed, process: process)
        else { return }
        defer {
            try? FileManager.default.removeItem(at: afterURL)
            try? FileManager.default.removeItem(at: beforeURL.deletingLastPathComponent())
        }
        // Read the bytes now; NSImage(contentsOf:) can load lazily, after the files are gone.
        guard let afterData = try? Data(contentsOf: afterURL), let beforeData = try? Data(contentsOf: beforeURL),
              let after = NSImage(data: afterData), let before = NSImage(data: beforeData) else { return }
        withAnimation(Motion.out(0.25)) {
            job.thumbnail = PreviewThumbnail(before: before, after: after, settings: s)
        }
    }

    private func estimate(_ job: EncodeJob, settings s: EncodeSettings, encoder: SampleEncoder,
                          makeThumbnail: Bool = false) async -> Int64? {
        guard let media = job.media, media.duration > 0 else { return nil }
        if s.container.isAudioOnly && !media.hasAudio { return nil }
        let direct = directEstimate(job, settings: s, media: media)
        guard direct == nil || makeThumbnail else { return direct }

        // Sample from the middle of the kept range: quality-based sizes depend on content, and the
        // same sample gives the live thumbnail its frames.
        let kept = SampleEncoder.keptRange(s, media: media)
        let span = kept.upperBound - kept.lowerBound
        let length = min(direct == nil ? 4 : 1.5, span)
        guard length > 0.2 else { return direct }
        let start = kept.lowerBound + (span - length) / 2
        let process = FFmpegProcess()
        estimateProcess = process
        if makeThumbnail { job.isMakingThumbnail = true }
        defer { if makeThumbnail { job.isMakingThumbnail = false } }
        guard let sample = try? await encoder.encode(input: job.input, media: media, settings: s, start: start,
                                                     length: length, process: process) else { return direct }
        defer { try? FileManager.default.removeItem(at: sample.output) }
        if makeThumbnail {
            await captureThumbnail(job, settings: s, media: media, encoder: encoder, sample: sample, start: start, process: process)
        }
        if let direct { return direct }
        guard sample.outDuration > 0 else { return nil }
        let full = CommandBuilder(settings: s, input: job.input, output: job.input, media: media,
                                  encoders: environment.encoders, filters: environment.filters).plan()
        return Int64(Double(sample.bytes) * full.expectedDuration / sample.outDuration)
    }

    /// Sizes that don't need a sample encode: passthrough, bitrate, file-size limits and lossy audio.
    private func directEstimate(_ job: EncodeJob, settings s: EncodeSettings, media: MediaInfo) -> Int64? {
        let full = CommandBuilder(settings: s, input: job.input, output: job.input, media: media,
                                  encoders: environment.encoders, filters: environment.filters).plan()
        let outDuration = full.expectedDuration
        let audioKbps = (media.hasAudio && s.audioCodec.isLossy && !s.container.isAnimatedImage) ? s.audioBitrateKbps : 0
        let isVideo = !s.container.isAnimatedImage && !s.container.isAudioOnly

        if s.container.isAudioOnly {
            guard media.hasAudio else { return nil }
            if s.audioCodec.isLossy { return Int64(Double(s.audioBitrateKbps) * 1000 / 8 * outDuration) }
        }

        if isVideo && s.videoCodec == .copy {
            let kept = SampleEncoder.keptRange(s, media: media)
            return Int64(Double(job.inputSize) * (kept.upperBound - kept.lowerBound) / media.duration)
        }
        if isVideo && s.videoCodec != .prores {
            switch s.rateControl {
            case .targetSize:
                // The limit is a ceiling; files already under it stay about the size they are.
                let kept = SampleEncoder.keptRange(s, media: media)
                let current = Int64(Double(job.inputSize) * (kept.upperBound - kept.lowerBound) / media.duration)
                return min(Int64(s.targetSizeMB * 1_000_000 * 0.97), current)
            case .bitrate, .constant:
                return Int64(Double(s.videoBitrateKbps + audioKbps) * 1000 / 8 * outDuration)
            case .quality:
                break
            }
        }

        return nil
    }

    // MARK: Run

    /// The settings a file will actually be encoded with.
    func effectiveSettings(for job: EncodeJob) -> EncodeSettings { job.customSettings ?? settings }

    /// Files that can start right now: runnable, and nothing their settings need is missing.
    /// True when nothing is waiting but some files finished: Squish then runs those again with the
    /// current settings, so a second pass doesn't need clearing the queue.
    var startRunsAgain: Bool {
        !jobs.contains(where: \.isRunnable) && jobs.contains { $0.status == .done }
    }

    /// The files the Squish button would start: everything waiting, or else everything finished.
    private var startCandidates: [EncodeJob] {
        startRunsAgain ? jobs.filter { $0.status == .done } : jobs.filter(\.isRunnable)
    }

    var startableCount: Int {
        startCandidates.filter { environment.problem(with: effectiveSettings(for: $0)) == nil }.count
    }

    /// Why nothing can start, when every candidate file is blocked by a missing ffmpeg feature.
    var startProblem: String? {
        guard startableCount == 0 else { return nil }
        return startCandidates.lazy.compactMap { self.environment.problem(with: self.effectiveSettings(for: $0)) }.first
    }

    private func queue(_ job: EncodeJob) -> Bool {
        let s = effectiveSettings(for: job)
        if let problem = environment.problem(with: s) {
            job.status = .failed
            job.message = problem
            return false
        }
        job.runSettings = s
        job.status = .queued
        job.progress = 0
        job.message = nil
        job.outputSize = nil
        return true
    }

    /// Encodes every runnable file (or, when none are waiting, every finished one again), or just
    /// `subset`, `concurrentJobs` at a time.
    func start(only subset: [EncodeJob]? = nil) {
        guard !isRunning, let ffmpeg = environment.ffmpeg else { return }
        let queued = (subset?.filter(\.canRunAgain) ?? startCandidates).filter { queue($0) }
        guard !queued.isEmpty else {
            saveQueue()
            return
        }
        estimateTask?.cancel()
        estimateProcess?.cancel()
        thumbnailTask?.cancel()
        thumbnailProcess?.cancel()
        persist()
        beginKeepAwake()
        isRunning = true
        batch = queued
        updateDockProgress()
        let workers = min(max(concurrentJobs, 1), 4)
        runTask = Task {
            // Loop again if files were retried while the last workers were finishing up.
            repeat {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<workers {
                        group.addTask { @MainActor in
                            while !Task.isCancelled, let job = self.claimNextJob() {
                                await self.encode(job, settings: job.runSettings ?? self.settings, ffmpeg: ffmpeg)
                                self.updateDockProgress()
                                self.saveQueue()
                            }
                        }
                    }
                }
            } while !Task.isCancelled && jobs.contains(where: { $0.status == .queued })
            isRunning = false
            processes.removeAll()
            endKeepAwake()
            Delight.setDockProgress(nil)
            // Sound and bounce once per batch, not per file.
            if batch.contains(where: { $0.status == .done }) {
                Delight.playFinishSound(enabled: playSounds)
                Delight.announceBatchFinished()
            }
            batch = []
            scheduleEstimates(force: true)
        }
    }

    private func updateDockProgress() {
        guard !batch.isEmpty else { return }
        let total = batch.reduce(0.0) { sum, job in
            switch job.status {
            case .done, .failed, .cancelled: sum + 1
            case .encoding: sum + job.progress
            default: sum
            }
        }
        Delight.setDockProgress(total / Double(batch.count))
    }

    func resetLifetimeTotals() {
        lifetimeSavedBytes = 0
        lifetimeFiles = 0
        UserDefaults.standard.removeObject(forKey: Self.lifetimeBytesKey)
        UserDefaults.standard.removeObject(forKey: Self.lifetimeFilesKey)
    }

    private func recordLifetimeSavings(_ job: EncodeJob) {
        guard let out = job.outputSize, out < job.inputSize else { return }
        lifetimeSavedBytes += job.inputSize - out
        lifetimeFiles += 1
        guard persistsState else { return }
        UserDefaults.standard.set(Int(lifetimeSavedBytes), forKey: Self.lifetimeBytesKey)
        UserDefaults.standard.set(lifetimeFiles, forKey: Self.lifetimeFilesKey)
    }

    /// Cancels the batch, background estimates and their ffmpeg runs.
    func cancelBackgroundWork() {
        runTask?.cancel()
        estimateTask?.cancel()
        thumbnailTask?.cancel()
        for process in processes.values { process.cancel() }
        estimateProcess?.cancel()
        thumbnailProcess?.cancel()
    }

    /// Moves a file above `target`, or to the end when `target` is nil.
    func move(_ id: UUID, before target: UUID?) {
        guard id != target, let from = jobs.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy(duration: 0.25)) {
            let job = jobs.remove(at: from)
            if let target, let to = jobs.firstIndex(where: { $0.id == target }) {
                jobs.insert(job, at: to)
            } else {
                jobs.append(job)
            }
        }
        saveQueue()
    }

    // MARK: Per-file settings

    /// Freezes the panel's current settings onto one file.
    func pinSettings(to job: EncodeJob) {
        withAnimation(.snappy) { job.customSettings = settings }
        saveQueue()
        scheduleEstimates(force: true)
    }

    func unpinSettings(from job: EncodeJob) {
        withAnimation(.snappy) { job.customSettings = nil }
        saveQueue()
        scheduleEstimates(force: true)
    }

    /// Takes the next file in queue order, so dragging the queue changes what runs next.
    private func claimNextJob() -> EncodeJob? {
        guard let job = jobs.first(where: { $0.status == .queued }) else { return nil }
        job.status = .encoding
        return job
    }

    func stop() {
        runTask?.cancel()
        for process in processes.values { process.cancel() }
        for job in jobs where job.status == .queued { job.status = .ready }
    }

    /// Stops one file without touching the rest of the batch.
    func cancel(_ job: EncodeJob) {
        switch job.status {
        case .encoding: processes[job.id]?.cancel()
        case .queued: job.status = .ready
        default: break
        }
    }

    /// Runs a failed, stopped or finished file again, joining the current batch if one is running.
    func retry(_ job: EncodeJob) {
        guard job.canRunAgain else { return }
        if isRunning {
            if queue(job) { batch.append(job) }
            updateDockProgress()
        } else {
            start(only: [job])
        }
    }

    func retryFailed() {
        let failed = jobs.filter { $0.status == .failed || $0.status == .cancelled }
        guard !failed.isEmpty else { return }
        if isRunning { failed.forEach(retry) } else { start(only: failed) }
    }

    private func encode(_ job: EncodeJob, settings: EncodeSettings, ffmpeg: URL) async {
        if job.media == nil, let ffprobe = environment.ffprobe {
            job.media = try? await MediaProbe.probe(job.input, ffprobe: ffprobe)
        }
        let output = outputURL(for: job.input, settings: settings)
        reservedOutputs.insert(output.path)
        defer { reservedOutputs.remove(output.path) }
        let plan = CommandBuilder(settings: settings, input: job.input, output: output,
                                  media: job.media, encoders: environment.encoders,
                                  filters: environment.filters).plan()
        job.command = plan.commandLine(binary: ffmpeg.path)
        job.warnings = plan.warnings
        job.output = output
        job.passCount = plan.passes.count
        job.status = .encoding
        // Saved now so a crash mid-encode is recognized next launch and its partial file removed.
        saveQueue()
        job.startedAt = Date()
        job.eta = nil
        job.encodeSpeed = nil

        let fm = FileManager.default
        if settings.container == .pngSequence {
            try? fm.createDirectory(at: output, withIntermediateDirectories: true)
        }

        let runner = FFmpegProcess()
        processes[job.id] = runner
        defer { processes[job.id] = nil }
        let expected = plan.expectedDuration
        do {
            for (index, args) in plan.passes.enumerated() {
                job.pass = index + 1
                let passCount = plan.passes.count
                try await runner.run(binary: ffmpeg, arguments: args) { seconds, speed in
                    Task { @MainActor in
                        guard job.status == .encoding else { return }
                        let passProgress = expected > 0 ? min(seconds / expected, 1) : 0
                        job.progress = (Double(index) + passProgress) / Double(passCount)
                        job.encodeSpeed = speed
                        if let started = job.startedAt, job.progress > 0.02 {
                            let elapsed = Date().timeIntervalSince(started)
                            job.eta = elapsed / job.progress * (1 - job.progress)
                        }
                        self.updateDockProgress()
                    }
                }
            }
            job.outputSize = Self.size(of: output)
            job.progress = 1
            job.status = .done
            recordLifetimeSavings(job)
        } catch is CancellationError {
            job.status = .cancelled
            try? fm.removeItem(at: output)
        } catch {
            job.status = .failed
            job.message = error.localizedDescription
            try? fm.removeItem(at: output)
        }
        if let prefix = plan.passLogPrefix {
            for suffix in ["-0.log", "-0.log.mbtree", "-0.log.temp", "-0.log.mbtree.temp"] {
                try? fm.removeItem(atPath: prefix + suffix)
            }
        }
    }

    func outputURL(for input: URL, settings s: EncodeSettings) -> URL {
        let folder: URL = (s.outputLocation == .folder && !s.outputFolderPath.isEmpty)
            ? URL(fileURLWithPath: s.outputFolderPath, isDirectory: true)
            : input.deletingLastPathComponent()
        var base = input.deletingPathExtension().lastPathComponent + s.filenameSuffix
        func candidate(_ name: String) -> URL {
            s.container == .pngSequence
                ? folder.appendingPathComponent(name + "-frames", isDirectory: true)
                : folder.appendingPathComponent(name).appendingPathExtension(s.container.fileExtension)
        }
        if candidate(base).standardizedFileURL == input.standardizedFileURL { base += "-squished" }
        var url = candidate(base)
        if !s.overwrite {
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) || reservedOutputs.contains(url.path) {
                url = candidate("\(base) \(n)")
                n += 1
            }
        }
        return url
    }

    private static func size(of url: URL) -> Int64? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        let files = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    // MARK: Panels

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputFolderPath = url.path
            settings.outputLocation = .folder
        }
    }

    func locateFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.message = "Choose an ffmpeg binary. ffprobe should sit next to it."
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await environment.useCustomBinary(url)
                reprobeAll()
            }
        }
    }
}

/// The app's look: follow macOS, or force light or dark.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil follows the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Live-thumbnail frames: the same moment rendered without compression and encoded.
struct PreviewThumbnail {
    let before: NSImage
    let after: NSImage
    let settings: EncodeSettings
}
