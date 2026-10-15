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

    init(input: URL) {
        self.input = input
        inputSize = Int64((try? input.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    var name: String { input.lastPathComponent }
    var isRunnable: Bool { status == .ready || status == .failed || status == .cancelled }

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
    var isRunning = false
    let environment = FFmpegEnvironment()

    @ObservationIgnored private var process: FFmpegProcess?
    @ObservationIgnored private var runTask: Task<Void, Never>?

    private static let settingsKey = "settings.v1"
    private static let modeKey = "mode"
    private static let presetKey = "preset"

    static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "gif", "webp", "apng", "mxf", "mts", "m2ts", "ts",
        "flv", "wmv", "mpg", "mpeg", "3gp", "ogv", "y4m", "hevc", "h264",
    ]

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(EncodeSettings.self, from: data) {
            settings = saved
        } else {
            settings = EncodeSettings()
        }
        mode = Mode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .simple
        selectedPresetID = defaults.string(forKey: Self.presetKey) ?? "smaller"
    }

    func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(selectedPresetID, forKey: Self.presetKey)
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
        for url in expand(urls) where !jobs.contains(where: { $0.input == url }) {
            let job = EncodeJob(input: url)
            withAnimation(.snappy) { jobs.append(job) }
            Task { await probe(job) }
        }
    }

    func remove(_ job: EncodeJob) {
        if job.status == .encoding { return }
        withAnimation(.snappy) { jobs.removeAll { $0.id == job.id } }
    }

    func clearFinished() {
        withAnimation(.snappy) { jobs.removeAll { $0.status == .done } }
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
        job.status = .probing
        do {
            job.media = try await MediaProbe.probe(job.input, ffprobe: ffprobe)
            job.status = .ready
        } catch {
            job.status = .failed
            job.message = "Couldn't read this file. \(error.localizedDescription)"
        }
    }

    // MARK: Encoding

    func plan(for job: EncodeJob?) -> EncodePlan {
        let input = job?.input ?? URL(fileURLWithPath: "/path/to/input.mov")
        return CommandBuilder(settings: settings, input: input, output: outputURL(for: input, settings: settings),
                              media: job?.media, encoders: environment.encoders).plan()
    }

    func start() {
        guard !isRunning, let ffmpeg = environment.ffmpeg, runnableCount > 0 else { return }
        persist()
        let snapshot = settings
        for job in jobs where job.isRunnable {
            job.status = .queued
            job.progress = 0
            job.message = nil
            job.outputSize = nil
        }
        isRunning = true
        runTask = Task {
            while let job = jobs.first(where: { $0.status == .queued }), !Task.isCancelled {
                await encode(job, settings: snapshot, ffmpeg: ffmpeg)
            }
            isRunning = false
            process = nil
            if jobs.contains(where: { $0.status == .done }) { NSSound(named: "Glass")?.play() }
        }
    }

    func stop() {
        runTask?.cancel()
        process?.cancel()
        for job in jobs where job.status == .queued { job.status = .ready }
    }

    private func encode(_ job: EncodeJob, settings: EncodeSettings, ffmpeg: URL) async {
        if job.media == nil, let ffprobe = environment.ffprobe {
            job.media = try? await MediaProbe.probe(job.input, ffprobe: ffprobe)
        }
        let output = outputURL(for: job.input, settings: settings)
        let plan = CommandBuilder(settings: settings, input: job.input, output: output,
                                  media: job.media, encoders: environment.encoders).plan()
        job.command = plan.commandLine(binary: ffmpeg.path)
        job.warnings = plan.warnings
        job.output = output
        job.passCount = plan.passes.count
        job.status = .encoding
        job.startedAt = Date()
        job.eta = nil
        job.encodeSpeed = nil

        let fm = FileManager.default
        if settings.container == .pngSequence {
            try? fm.createDirectory(at: output, withIntermediateDirectories: true)
        }

        let runner = FFmpegProcess()
        process = runner
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
                    }
                }
            }
            job.status = .done
            job.progress = 1
            job.outputSize = Self.size(of: output)
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
            while FileManager.default.fileExists(atPath: url.path) {
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
