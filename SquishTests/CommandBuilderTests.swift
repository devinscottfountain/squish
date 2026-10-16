import Foundation
import Testing
@testable import Squish

// MARK: - Fixtures

private func media(width: Int = 1280, height: Int = 720, duration: Double = 10, alpha: Bool = false,
                   hdr: String? = nil, audio: Bool = true) -> MediaInfo {
    MediaInfo(duration: duration, sizeBytes: 10_000_000, bitRate: 8_000_000, width: width, height: height,
              frameRate: 30, videoCodec: "h264", pixelFormat: alpha ? "yuva444p10le" : "yuv420p",
              hasAlpha: alpha, needsLibvpxDecoder: false,
              colorTransfer: hdr == nil ? "bt709" : "arib-std-b67", colorPrimaries: hdr == nil ? "bt709" : "bt2020",
              hdrFormat: hdr, hasAudio: audio, audioCodec: audio ? "aac" : nil, audioChannels: 2, sampleRate: 48000)
}

private func plan(_ tweak: (inout EncodeSettings) -> Void = { _ in }, media info: MediaInfo? = media(),
                  filters: Set<String> = []) -> EncodePlan {
    var s = EncodeSettings()
    tweak(&s)
    return CommandBuilder(settings: s, input: URL(fileURLWithPath: "/in/clip.mov"),
                          output: URL(fileURLWithPath: "/out/clip.\(s.container.fileExtension)"),
                          media: info, filters: filters).plan()
}

private extension Array where Element == String {
    func value(after flag: String) -> String? {
        guard let i = firstIndex(of: flag), i + 1 < count else { return nil }
        return self[i + 1]
    }
}

// MARK: - Argument-level tests

@Suite("Command builder")
struct CommandBuilderTests {
    @Test func defaultIsMediaEngineH264WithAAC() {
        let args = plan().passes[0]
        #expect(args.value(after: "-c:v") == "h264_videotoolbox")
        #expect(args.value(after: "-q:v") == "68")
        #expect(args.value(after: "-c:a") == "aac")
        #expect(args.contains("+faststart"))
    }

    @Test func softwareH264UsesCRF() {
        let args = plan { $0.useHardwareEncoder = false }.passes[0]
        #expect(args.value(after: "-c:v") == "libx264")
        #expect(args.value(after: "-crf") == "23")
        #expect(args.value(after: "-c:a") == "aac")
        #expect(args.last == "/out/clip.mp4")
        #expect(args.contains("+faststart"))
    }

    @Test(arguments: [0.0, 50, 100])
    func qualityMapsMonotonically(_ q: Double) {
        var s = EncodeSettings()
        s.useHardwareEncoder = false
        s.quality = q
        let crf = CommandBuilder.qualityParameter(for: s)!.value
        #expect((14...36).contains(crf))
        s.quality = min(q + 10, 100)
        #expect(CommandBuilder.qualityParameter(for: s)!.value <= crf, "higher quality must not raise CRF")
    }

    @Test func targetSizeUsesTwoPassAndBudgetsAudio() {
        let p = plan { $0.useHardwareEncoder = false; $0.rateControl = .targetSize; $0.targetSizeMB = 10; $0.audioBitrateKbps = 128 }
        #expect(p.passes.count == 2)
        #expect(p.passes[0].contains("/dev/null"))
        #expect(p.passes[0].value(after: "-pass") == "1")
        // 10 MB over 10 s = 8000 kbps × 0.95 − 128 audio.
        #expect(p.passes[1].value(after: "-b:v") == "\(7600 - 128)k")
    }

    @Test func sizeLimitNeverInflatesASmallFile() {
        // 10 s at 8 Mbps total is ~10 MB; a 50 MB limit must not raise the bitrate above the source's.
        let args = plan { $0.useHardwareEncoder = false; $0.rateControl = .targetSize; $0.targetSizeMB = 50; $0.audioBitrateKbps = 128 }.passes[1]
        #expect(args.value(after: "-b:v") == "\(8000 - 128)k")
    }

    @Test func portraitScalesTheShortEdge() {
        let args = plan({ $0.resolution = .p720 }, media: media(width: 1080, height: 1920)).passes[0]
        #expect(args.value(after: "-vf")?.contains("scale='min(iw,720)':-2") == true)
    }

    @Test func oddSourceDimensionsAreEvened() {
        let args = plan(media: media(width: 641, height: 361)).passes[0]
        #expect(args.value(after: "-vf")?.contains("trunc(iw/2)*2") == true)
    }

    @Test func speedChangesVideoAndAudioTogether() {
        let args = plan { $0.playbackSpeed = 3 }.passes[0]
        #expect(args.value(after: "-vf")?.contains("setpts=PTS/3") == true)
        #expect(args.value(after: "-af") == "atempo=2,atempo=1.5")
    }

    @Test func alphaIsFlattenedWhenTheOutputCantCarryIt() {
        let vf = plan({ $0.backgroundHex = "#FF3366" }, media: media(alpha: true)).passes[0].value(after: "-vf") ?? ""
        #expect(vf.contains("drawbox") && vf.contains("0xFF3366"))
    }

    @Test func proresKeepsAlpha() {
        let args = plan({ $0.container = .mov; $0.videoCodec = .prores }, media: media(alpha: true)).passes[0]
        #expect(args.value(after: "-profile:v") == "4")
        #expect(args.value(after: "-vf")?.hasSuffix("format=yuva444p10le") == true)
    }

    @Test func gifUsesAPaletteAndDropsAudio() {
        let args = plan { $0.container = .gif }.passes[0]
        #expect(args.value(after: "-vf")?.contains("palettegen") == true)
        #expect(args.contains("-an"))
    }

    @Test func stripMetadataRemovesGlobalTagsAndChapters() {
        let args = plan { $0.stripMetadata = true }.passes[0]
        #expect(args.value(after: "-map_metadata") == "-1")
        #expect(args.value(after: "-map_chapters") == "-1")
    }

    @Test func extraArgumentsRespectQuotes() {
        #expect(splitArguments(#"-metadata "title=Big Day" -tag:v avc1"#) == ["-metadata", "title=Big Day", "-tag:v", "avc1"])
    }

    @Test func shellQuoting() {
        #expect(shellQuote("plain-name.mp4") == "plain-name.mp4")
        #expect(shellQuote("it's here.mov") == #"'it'\''s here.mov'"#)
    }

    // MARK: HDR

    @Test func hdrIsToneMappedWithVideoToolboxWhenZscaleIsMissing() {
        let p = plan({ _ in }, media: media(hdr: "HLG"), filters: ["scale_vt", "tonemap"])
        let args = p.passes[0]
        #expect(args.contains("-init_hw_device"))
        #expect(args.value(after: "-vf")?.contains("scale_vt=color_matrix=bt709") == true)
        #expect(p.warnings.isEmpty)
    }

    @Test func hdrPrefersZscaleWhenAvailable() {
        let vf = plan({ _ in }, media: media(hdr: "HDR10"), filters: ["zscale", "tonemap", "scale_vt"]).passes[0].value(after: "-vf") ?? ""
        #expect(vf.contains("tonemap=tonemap=hable"))
        #expect(!vf.contains("scale_vt"))
    }

    @Test func keepHDRWithHEVCStaysTenBitAndSkipsToneMapping() {
        let vf = plan({ $0.videoCodec = .hevc; $0.useHardwareEncoder = false; $0.hdr = .keep }, media: media(hdr: "HLG"), filters: ["scale_vt"])
            .passes[0].value(after: "-vf") ?? ""
        #expect(!vf.contains("scale_vt"))
        #expect(vf.hasSuffix("format=yuv420p10le"))
    }

    @Test func keepHDRWithH264FallsBackWithAWarning() {
        let p = plan({ $0.hdr = .keep }, media: media(hdr: "HLG"), filters: ["scale_vt"])
        #expect(p.passes[0].value(after: "-vf")?.contains("scale_vt") == true)
        #expect(p.warnings.contains { $0.contains("can't carry HDR") })
    }

    @Test func sdrSourcesAreNotTouched() {
        let args = plan({ _ in }, filters: ["scale_vt"]).passes[0]
        #expect(!args.contains("-init_hw_device"))
    }

    // MARK: Settings persistence

    @Test func oldSavedSettingsStillDecode() throws {
        var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EncodeSettings())) as! [String: Any]
        dict.removeValue(forKey: "hdr")
        dict["quality"] = 77
        let decoded = EncodeSettings.decodeLenient(try JSONSerialization.data(withJSONObject: dict))
        #expect(decoded?.quality == 77)
        #expect(decoded?.hdr == .toSDR)
    }

    @Test func savedPresetsRoundTripAndKeepOutputFolder() throws {
        var s = EncodeSettings()
        s.videoCodec = .hevc
        s.quality = 70
        let data = try JSONEncoder().encode([SavedPreset(name: "Mine", settings: s)])
        let loaded = try JSONDecoder().decode([SavedPreset].self, from: data)
        #expect(loaded.first?.name == "Mine")
        #expect(loaded.first?.settings.videoCodec == .hevc)

        var current = EncodeSettings()
        current.outputLocation = .folder
        current.outputFolderPath = "/Exports"
        var applied = loaded[0].settings
        applied.adoptOutput(from: current)
        #expect(applied.outputFolderPath == "/Exports" && applied.quality == 70)
    }
}

// MARK: - Integration tests against the real ffmpeg

private let ffmpegURL = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    .map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
private let ffprobeURL = ffmpegURL.map { $0.deletingLastPathComponent().appendingPathComponent("ffprobe") }

/// Encodes small synthetic clips with real ffmpeg and checks what comes out.
@Suite("Real encodes", .enabled(if: ffmpegURL != nil, "ffmpeg isn't installed"), .serialized)
struct EncodeIntegrationTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("squish-tests-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func make(_ name: String, _ args: [String]) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        let r = try await ProcessRunner.run(ffmpegURL!, ["-v", "error", "-y"] + args + [url.path])
        try #require(r.status == 0, "fixture failed: \(String(decoding: r.stderr, as: UTF8.self))")
        return url
    }

    private func encode(_ input: URL, ext: String, _ tweak: (inout EncodeSettings) -> Void) async throws -> MediaInfo {
        let env = await MainActor.run { FFmpegEnvironment() }
        await env.refresh()
        let (encoders, filters) = await MainActor.run { (env.encoders, env.filters) }
        var s = EncodeSettings()
        tweak(&s)
        let inInfo = try await MediaProbe.probe(input, ffprobe: ffprobeURL!)
        let out = dir.appendingPathComponent("\(input.deletingPathExtension().lastPathComponent)-out.\(ext)")
        let p = CommandBuilder(settings: s, input: input, output: out, media: inInfo,
                               encoders: encoders, filters: filters).plan()
        for pass in p.passes {
            try await FFmpegProcess().run(binary: ffmpegURL!, arguments: pass) { _, _ in }
        }
        return try await MediaProbe.probe(out, ffprobe: ffprobeURL!)
    }

    private func opaqueClip() async throws -> URL {
        try await make("opaque.mp4", ["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=3",
                                      "-f", "lavfi", "-i", "sine=f=440:d=3", "-c:v", "libx264", "-c:a", "aac", "-shortest"])
    }

    private func alphaClip() async throws -> URL {
        try await make("alpha.mov", ["-f", "lavfi", "-i",
            "testsrc2=s=641x361:r=24:d=2,format=yuva444p10le,geq=lum='lum(X,Y)':cb='cb(X,Y)':cr='cr(X,Y)':a='if(gt(X,W/2),1020,0)'",
            "-c:v", "prores_ks", "-profile:v", "4"])
    }

    private func hlgClip() async throws -> URL {
        try await make("hlg.mov", ["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=2",
            "-vf", "format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=arib-std-b67:colorspace=bt2020nc",
            "-c:v", "libx265", "-x265-params", "log-level=error", "-tag:v", "hvc1"])
    }

    @Test func h264Default() async throws {
        let out = try await encode(try await opaqueClip(), ext: "mp4") { _ in }
        #expect(out.videoCodec == "h264")
        #expect(out.hasAudio)
    }

    @Test func targetSizeLandsUnderTheLimit() async throws {
        let input = try await opaqueClip()
        _ = try await encode(input, ext: "mp4") { $0.useHardwareEncoder = false; $0.rateControl = .targetSize; $0.targetSizeMB = 0.5 }
        let size = try dir.appendingPathComponent("opaque-out.mp4").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size <= 500_000 && size > 250_000, "got \(size) bytes")
    }

    @Test func vp9KeepsAlpha() async throws {
        let out = try await encode(try await alphaClip(), ext: "webm") { $0.container = .webm; $0.speed = .fastest }
        #expect(out.hasAlpha)
        #expect(out.width == 640 && out.height == 360)
    }

    @Test func gifKeepsAlpha() async throws {
        let out = try await encode(try await alphaClip(), ext: "gif") { $0.container = .gif; $0.frameRate = .fps15 }
        #expect(out.hasAlpha)
    }

    @Test func hlgBecomesTaggedSDR() async throws {
        let out = try await encode(try await hlgClip(), ext: "mp4") { _ in }
        #expect(!out.isHDR)
        #expect(out.colorTransfer == "bt709")
        #expect(out.pixelFormat == "yuv420p")
    }

    @Test func hlgKeptWithHEVC() async throws {
        let out = try await encode(try await hlgClip(), ext: "mp4") { $0.videoCodec = .hevc; $0.hdr = .keep; $0.speed = .fastest }
        #expect(out.hdrFormat == "HLG")
        #expect(out.pixelFormat == "yuv420p10le")
    }

    @Test func sampleEstimateIsCloseToTheRealSize() async throws {
        let input = try await make("long.mp4", ["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=12",
                                                "-f", "lavfi", "-i", "sine=f=440:d=12", "-c:v", "libx264", "-c:a", "aac", "-shortest"])
        let info = try await MediaProbe.probe(input, ffprobe: ffprobeURL!)
        let encoder = SampleEncoder(ffmpeg: ffmpegURL!, encoders: [], filters: [])
        let s = EncodeSettings()
        let sample = try await encoder.encode(input: input, media: info, settings: s, start: 4, length: 4, process: FFmpegProcess())
        let estimate = Double(sample.bytes) * 12 / sample.outDuration
        _ = try await encode(input, ext: "mp4") { _ in }
        let real = Double(try dir.appendingPathComponent("long-out.mp4").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        #expect(abs(estimate - real) / real < 0.35, "estimate \(Int(estimate)) vs real \(Int(real))")
    }

    @Test func previewFramesMatchInSize() async throws {
        let input = try await alphaClip()
        let info = try await MediaProbe.probe(input, ffprobe: ffprobeURL!)
        let encoder = SampleEncoder(ffmpeg: ffmpegURL!, encoders: [], filters: [])
        var s = EncodeSettings()
        s.container = .webm
        s.resolution = .p360
        let proc = FFmpegProcess()
        let sample = try await encoder.encode(input: input, media: info, settings: s, start: 0, length: 1.5, process: proc)
        let after = try await encoder.frame(from: sample.output, at: 0.5, settings: s, process: proc)
        let before = try await encoder.referenceFrame(input: input, media: info, settings: s, sourceTime: 0.5, process: proc)
        let a = try await MediaProbe.probe(after, ffprobe: ffprobeURL!)
        let b = try await MediaProbe.probe(before, ffprobe: ffprobeURL!)
        #expect(a.width == b.width && a.height == b.height)
        #expect(a.hasAlpha && b.hasAlpha)
    }

    @Test func kitchenSink() async throws {
        let out = try await encode(try await opaqueClip(), ext: "mp4") {
            $0.playbackSpeed = 2; $0.trimStart = 0.5; $0.rotation = .cw90; $0.cropLeft = 11
            $0.denoise = .light; $0.saturation = 1.3; $0.fadeIn = 0.2; $0.fadeOut = 0.2
            $0.normalizeLoudness = true; $0.stripMetadata = true; $0.resolution = .p480
        }
        #expect(out.width == 480)
        #expect(abs(out.duration - 1.25) < 0.2)
    }
}

// MARK: - Capability checks and quitting

@Suite("ffmpeg capabilities")
@MainActor
struct CapabilityTests {
    private func environment(_ encoders: Set<String>) -> FFmpegEnvironment {
        let env = FFmpegEnvironment()
        env.encoders = encoders
        return env
    }

    @Test func webpWithoutLibwebpIsFlagged() {
        let env = environment(["libx264", "aac", "gif"])
        var s = EncodeSettings()
        s.container = .webp
        #expect(env.missingLibrary(for: .webp) == "libwebp")
        #expect(env.problem(with: s)?.contains("libwebp") == true)
    }

    @Test func softwareHEVCMissingButHardwarePresent() {
        let env = environment(["libx264", "hevc_videotoolbox", "aac"])
        #expect(env.missingLibrary(for: .hevc, hardware: false) == "libx265")
        #expect(env.missingLibrary(for: .hevc, hardware: true) == nil)
    }

    @Test func defaultSettingsWorkOnATypicalBuild() {
        let env = environment(["libx264", "aac"])
        #expect(env.problem(with: EncodeSettings()) == nil)
    }

    @Test func unknownBuildAssumesEverythingWorks() {
        var s = EncodeSettings()
        s.container = .webp
        #expect(environment([]).problem(with: s) == nil)
    }
}

@Suite("Quitting", .enabled(if: ffmpegURL != nil, "ffmpeg isn't installed"))
struct QuitTests {
    @Test func terminateAllStopsARunningEncode() async throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("squish-test-quit.mp4")
        let process = FFmpegProcess()
        let started = Date()
        let encode = Task {
            try await process.run(binary: ffmpegURL!, arguments: [
                "-y", "-f", "lavfi", "-i", "testsrc2=s=1920x1080:r=60:d=600",
                "-c:v", "libx264", "-preset", "veryslow", out.path,
            ]) { _, _ in }
        }
        try await Task.sleep(for: .milliseconds(600))
        FFmpegProcess.terminateAll()
        await #expect(throws: (any Error).self) { try await encode.value }
        #expect(Date().timeIntervalSince(started) < 5, "ffmpeg should stop within a couple of seconds")
        try? FileManager.default.removeItem(at: out)
    }
}

// MARK: - Audio only

@Suite("Audio-only export")
struct AudioOnlyTests {
    @Test func m4aDropsVideoAndMapsOnlyAudio() {
        let args = plan { $0.container = .m4a; $0.normalize() }.passes[0]
        #expect(args.contains("-vn"))
        #expect(args.value(after: "-map") == "0:a:0")
        #expect(args.value(after: "-c:a") == "aac")
        #expect(!args.contains("-vf"))
        #expect(!args.contains("-c:v"))
    }

    @Test func staleVideoSettingsDontLeakIntoAudioExports() {
        let args = plan({ $0.videoCodec = .copy; $0.container = .flac; $0.normalize(); $0.useHardwareDecoder = true },
                        media: media(hdr: "HLG"), filters: ["scale_vt"]).passes[0]
        #expect(args.value(after: "-c:a") == "flac")
        #expect(!args.contains("-hwaccel") && !args.contains("-init_hw_device"))
    }

    @Test func noAudioTrackWarns() {
        let p = plan({ $0.container = .mp3; $0.normalize() }, media: media(audio: false))
        #expect(p.warnings.contains { $0.contains("no audio") })
    }

    @MainActor @Test func mp3NeedsLame() {
        let env = FFmpegEnvironment()
        env.encoders = ["libx264", "aac"]
        var s = EncodeSettings()
        s.container = .mp3
        #expect(env.problem(with: s)?.contains("libmp3lame") == true)
    }
}

@Suite("Real audio exports", .enabled(if: ffmpegURL != nil, "ffmpeg isn't installed"), .serialized)
struct AudioExportIntegrationTests {
    @Test(arguments: [(Container.m4a, "aac"), (.mp3, "mp3"), (.wav, "pcm_s16le"), (.flac, "flac")])
    func exportsOnlyTheSoundtrack(_ format: Container, _ expectedCodec: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squish-tests-audio-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("clip.mp4")
        let made = try await ProcessRunner.run(ffmpegURL!, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=640x360:r=30:d=2",
                                                            "-f", "lavfi", "-i", "sine=f=440:d=2", "-c:v", "libx264", "-c:a", "aac",
                                                            "-shortest", input.path])
        try #require(made.status == 0)
        let info = try await MediaProbe.probe(input, ffprobe: ffprobeURL!)

        var s = EncodeSettings()
        s.container = format
        s.normalize()
        let out = dir.appendingPathComponent("clip-out.\(format.fileExtension)")
        let p = CommandBuilder(settings: s, input: input, output: out, media: info).plan()
        for pass in p.passes { try await FFmpegProcess().run(binary: ffmpegURL!, arguments: pass) { _, _ in } }

        let probe = try await ProcessRunner.run(ffprobeURL!, ["-v", "error", "-show_entries", "stream=codec_type,codec_name",
                                                             "-of", "csv=p=0", out.path])
        let streams = String(decoding: probe.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(streams == ["\(expectedCodec),audio"], "got \(streams)")
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - Queue handling

@Suite("Queue order")
@MainActor
struct QueueOrderTests {
    @Test func moveReordersAndAppends() {
        let store = QueueStore(persistsState: false)
        let jobs = ["a", "b", "c"].map { EncodeJob(input: URL(fileURLWithPath: "/tmp/\($0).mp4")) }
        store.jobs = jobs
        store.move(jobs[2].id, before: jobs[0].id)
        #expect(store.jobs.map(\.name) == ["c.mp4", "a.mp4", "b.mp4"])
        store.move(jobs[2].id, before: nil)
        #expect(store.jobs.map(\.name) == ["a.mp4", "b.mp4", "c.mp4"])
    }
}

@Suite("Real batches", .enabled(if: ffmpegURL != nil, "ffmpeg isn't installed"), .serialized)
@MainActor
struct BatchIntegrationTests {
    private func clip(_ url: URL, seconds: Int = 2, size: String = "640x360") async throws {
        let r = try await ProcessRunner.run(ffmpegURL!, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=\(size):r=30:d=\(seconds)",
                                                         "-f", "lavfi", "-i", "sine=f=440:d=\(seconds)", "-c:v", "libx264",
                                                         "-preset", "ultrafast", "-c:a", "aac", "-shortest", url.path])
        try #require(r.status == 0)
    }

    private func makeStore() async -> QueueStore {
        let store = QueueStore(persistsState: false)
        store.playSounds = false
        store.settings.speed = .fastest
        await store.environment.refresh()
        return store
    }

    private func waitUntil(_ timeout: TimeInterval = 90, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            try #require(Date() < deadline, "timed out")
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func parallelBatchWithSameNamesAndPinnedSettings() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squish-tests-batch-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = ["clip.mp4", "clip.mov", "other.mp4"].map { dir.appendingPathComponent($0) }
        for url in inputs { try await clip(url) }

        let store = await makeStore()
        store.concurrentJobs = 2
        store.add(urls: inputs)
        try await waitUntil { store.jobs.count == 3 && store.jobs.allSatisfy { $0.status == .ready } }

        // The third file gets its own settings: audio only.
        var audio = store.settings
        audio.container = .m4a
        audio.normalize()
        store.jobs[2].customSettings = audio

        store.start(only: nil)
        try await waitUntil { !store.isRunning }

        #expect(store.jobs.allSatisfy { $0.status == .done }, "\(store.jobs.map { "\($0.name): \($0.status) \($0.message ?? "")" })")
        let outputs = store.jobs.compactMap(\.output?.lastPathComponent)
        #expect(Set(outputs).count == 3, "outputs must not collide: \(outputs)")
        #expect(outputs.contains("other-squished.m4a"))
        #expect(outputs.filter { $0.hasPrefix("clip-squished") && $0.hasSuffix(".mp4") }.count == 2)
    }

    @Test func stoppingOneFileThenRetrying() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squish-tests-retry-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("long.mp4")
        try await clip(input, seconds: 20, size: "1920x1080")

        let store = await makeStore()
        store.settings.speed = .slowest
        store.add(urls: [input])
        try await waitUntil { store.jobs.first?.status == .ready }
        let job = store.jobs[0]

        store.start(only: nil)
        try await waitUntil { job.status == .encoding && job.progress > 0 }
        store.cancel(job)
        try await waitUntil { !store.isRunning }
        #expect(job.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: job.output!.path), "partial output should be removed")

        store.settings.speed = .fastest
        store.retry(job)
        try await waitUntil { !store.isRunning }
        #expect(job.status == .done)
    }
}

@Suite("Media engine")
struct MediaEngineTests {
    @Test func untaggedSourcesGetTaggedForTheMediaEngine() {
        var info = media()
        info.colorPrimaries = ""
        info.colorTransfer = ""
        let vf = plan({ _ in }, media: info).passes[0].value(after: "-vf") ?? ""
        #expect(vf.contains("setparams=color_primaries=bt709"))
        let software = plan({ $0.useHardwareEncoder = false }, media: info).passes[0].value(after: "-vf") ?? ""
        #expect(!software.contains("setparams"))
    }

    @Test func taggedSourcesAreLeftAlone() {
        let vf = plan().passes[0].value(after: "-vf") ?? ""
        #expect(!vf.contains("setparams"))
    }

    @Test func prores422UsesTheMediaEngineButAlphaStaysSoftware() {
        let hq = plan { $0.container = .mov; $0.videoCodec = .prores; $0.proresProfile = .hq }.passes[0]
        #expect(hq.value(after: "-c:v") == "prores_videotoolbox")
        let alpha = plan({ $0.container = .mov; $0.videoCodec = .prores }, media: media(alpha: true)).passes[0]
        #expect(alpha.value(after: "-c:v") == "prores_ks")
    }

    @Test func hevcMediaEngineScaleIsCalibrated() {
        var s = EncodeSettings()
        s.videoCodec = .hevc
        s.quality = 62
        #expect(CommandBuilder.qualityParameter(for: s)?.value == 48)
    }
}

@Suite("Media engine fallback")
struct MediaEngineFallbackTests {
    @Test func missingVideoToolboxFallsBackToSoftware() {
        var s = EncodeSettings()
        s.normalize()
        let args = CommandBuilder(settings: s, input: URL(fileURLWithPath: "/in/a.mov"), output: URL(fileURLWithPath: "/out/a.mp4"),
                                  media: nil, encoders: ["libx264", "aac"]).plan().passes[0]
        #expect(args.value(after: "-c:v") == "libx264")
    }
}
