import Foundation
import Testing
@testable import Squish

// MARK: - Fixtures

private func media(width: Int = 1280, height: Int = 720, duration: Double = 10, alpha: Bool = false,
                   hdr: String? = nil, audio: Bool = true) -> MediaInfo {
    MediaInfo(duration: duration, bitRate: 8_000_000, width: width, height: height,
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
        #expect(args.value(after: "-vf")?.contains("scale='trunc(min(iw,720)/2)*2':-2") == true)
    }

    @Test func resolutionCapKeepsOddSmallSourcesEven() {
        // 641×361 under a 720p cap passes through the cap, so the height must still be rounded to even.
        let vf = plan({ $0.resolution = .p720 }, media: media(width: 641, height: 361)).passes[0].value(after: "-vf") ?? ""
        #expect(vf.contains("scale=-2:'trunc(min(ih,720)/2)*2'"))
    }

    @Test func errorsLeadWithTheCause() {
        let log = """
        [libx264 @ 0xa0] height not divisible by 2 (642x361)
        [vf#0:0 @ 0xa1] Task finished with error code: -542398533 (Generic error in an external library)
        [out#0/null @ 0xa2] Nothing was written into output file, because at least one of its streams received no packets.
        """
        let text = FFmpegError.exited(code: 187, message: log).errorDescription ?? ""
        #expect(text.hasPrefix("Height not divisible by 2 (642x361)"))
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

    @Test func oddTransparentClipUnderTenMegabytes() async throws {
        // The exact case that failed in a release build: 641×361 ProRes 4444 with alpha, "Under 10 MB" (720p cap, two-pass x264).
        let out = try await encode(try await alphaClip(), ext: "mp4") {
            $0.useHardwareEncoder = false; $0.rateControl = .targetSize; $0.targetSizeMB = 10; $0.resolution = .p720
        }
        #expect(out.width == 640 && out.height == 360)
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

    @Test func finishedFilesCanBeSquishedAgain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squish-tests-again-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("again.mp4")
        try await clip(input)

        let store = await makeStore()
        store.add(urls: [input])
        try await waitUntil { store.jobs.first?.status == .ready }
        let job = store.jobs[0]
        store.start(only: nil)
        try await waitUntil { !store.isRunning }
        let first = try #require(job.output)
        #expect(job.status == .done)

        // Nothing is waiting, so Squish offers the finished file again, with new settings.
        #expect(store.startRunsAgain)
        #expect(store.startableCount == 1)
        store.settings.container = .webm
        store.settings.normalize()
        store.start(only: nil)
        try await waitUntil { !store.isRunning }
        #expect(job.status == .done, "\(job.message ?? "")")
        #expect(job.output?.pathExtension == "webm")
        #expect(FileManager.default.fileExists(atPath: first.path), "the first pass's file is kept")

        // Dropping a finished file in again readies it instead of being ignored.
        store.add(urls: [input])
        #expect(store.jobs.count == 1)
        #expect(job.status == .ready)
        #expect(!store.startRunsAgain)
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

// MARK: - Hardware decode

@Suite("Automatic hardware decode")
struct HardwareDecodeTests {
    @Test func onForTheMediaEngineAtFullResolution() {
        let args = plan().passes[0]
        #expect(args.value(after: "-hwaccel") == "videotoolbox")
        // The decoder's NV12 goes straight to the encoder.
        #expect(args.value(after: "-vf") == "format=nv12")
    }

    @Test func untaggedColorIsStillTaggedWithHardwareDecode() {
        var info = media()
        info.colorPrimaries = ""
        info.colorTransfer = ""
        let args = plan(media: info).passes[0]
        #expect(args.contains("-hwaccel"))
        #expect(args.value(after: "-vf") == "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,format=nv12")
    }

    @Test func offWhenScaling() {
        let args = plan { $0.resolution = .p480 }.passes[0]
        #expect(!args.contains("-hwaccel"))
        #expect(args.value(after: "-vf")?.hasSuffix("format=yuv420p") == true)
        #expect(!plan(media: media(width: 641, height: 361)).passes[0].contains("-hwaccel"), "odd sizes are scaled to even")
    }

    @Test func offWithASoftwareEncoder() {
        let args = plan { $0.useHardwareEncoder = false }.passes[0]
        #expect(!args.contains("-hwaccel"))
        #expect(args.value(after: "-vf") == "format=yuv420p")
    }

    @Test func offForSourcesItWasntMeasuredOn() {
        var info = media()
        info.videoCodec = "mpeg4"
        #expect(!plan(media: info).passes[0].contains("-hwaccel"))
        #expect(!plan(media: nil).passes[0].contains("-hwaccel"))
    }

    @Test func offWithAnAlphaSource() {
        #expect(!plan(media: media(alpha: true)).passes[0].contains("-hwaccel"))
    }

    @Test func offWhenToneMappingOrTenBit() {
        #expect(!plan({ _ in }, media: media(hdr: "HLG"), filters: ["zscale", "tonemap"]).passes[0].contains("-hwaccel"))
        #expect(!plan { $0.videoCodec = .hevc; $0.pixelFormat = .yuv420p10le }.passes[0].contains("-hwaccel"))
    }

    @Test func theToggleStillForcesItOn() {
        let args = plan { $0.useHardwareEncoder = false; $0.resolution = .p480; $0.useHardwareDecoder = true }.passes[0]
        #expect(args.value(after: "-hwaccel") == "videotoolbox")
        #expect(args.value(after: "-vf")?.hasSuffix("format=yuv420p") == true, "software encoders keep yuv420p")
    }
}

// MARK: - Samples

@Suite("Samples")
struct SampleTests {
    private let encoder = SampleEncoder(ffmpeg: URL(fileURLWithPath: "/usr/bin/false"), encoders: [], filters: [])
    private let input = URL(fileURLWithPath: "/in/clip.mov")

    @Test func targetSizeSampleUsesTheFullClipsBitrateInOnePass() {
        var s = EncodeSettings()
        s.useHardwareEncoder = false
        s.rateControl = .targetSize
        s.targetSizeMB = 5
        let info = media(duration: 60)
        let full = CommandBuilder(settings: s, input: input, output: input, media: info).plan()
        let sample = encoder.plan(input: input, media: info, settings: s, start: 20, length: 2,
                                  output: URL(fileURLWithPath: "/tmp/sample.mp4"))
        #expect(full.passes.count == 2)
        #expect(sample.passes.count == 1)
        #expect(sample.passLogPrefix == nil)
        #expect(sample.videoKbps == full.videoKbps)
        #expect(sample.passes[0].value(after: "-b:v") == full.passes[1].value(after: "-b:v"))
        #expect(sample.passes[0].value(after: "-maxrate") == full.passes[1].value(after: "-maxrate"))
    }

    @Test func samplesSkipFastStartAndTwoPass() {
        var s = EncodeSettings()
        s.useHardwareEncoder = false
        s.rateControl = .bitrate
        s.twoPass = true
        let sample = encoder.plan(input: input, media: media(), settings: s, start: 0, length: 2,
                                  output: URL(fileURLWithPath: "/tmp/sample.mp4"))
        #expect(sample.passes.count == 1)
        #expect(!sample.passes[0].contains("+faststart"))
    }

    @Test func sampleKeyIgnoresWhereAndHowTheFileIsTagged() {
        let base = EncodeSettings()
        var moved = base
        moved.outputLocation = .folder
        moved.outputFolderPath = "/Exports"
        moved.filenameSuffix = "-small"
        moved.metaTitle = "Holiday"
        moved.overwrite = true
        moved.fastStart = false
        #expect(moved.sampleKey == base.sampleKey)
        #expect(moved != base)
    }

    @Test(arguments: [
        { (s: inout EncodeSettings) in s.quality = 30 },
        { (s: inout EncodeSettings) in s.videoCodec = .hevc },
        { (s: inout EncodeSettings) in s.resolution = .p720 },
    ])
    func sampleKeyFollowsWhatChangesThePicture(_ change: (inout EncodeSettings) -> Void) {
        var changed = EncodeSettings()
        change(&changed)
        #expect(changed.sampleKey != EncodeSettings().sampleKey)
    }
}

// MARK: - Process plumbing

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

@Suite("Process runner")
struct ProcessRunnerTests {
    @Test func manyAtOnceAllFinish() async throws {
        // More runs than GCD has threads: blocking reads used to exhaust the pool and hang at ~65.
        let finished = Flag()
        let runs = Task {
            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for i in 0..<150 {
                    group.addTask {
                        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/echo"), ["run-\(i)"])
                        return (i, String(decoding: r.stdout, as: UTF8.self))
                    }
                }
                var outputs: [Int: String] = [:]
                for try await (i, text) in group { outputs[i] = text }
                finished.set()
                return outputs
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while !finished.isSet && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try #require(finished.isSet, "150 concurrent runs didn't finish in 30 s")
        let outputs = try await runs.value
        #expect(outputs.count == 150)
        #expect((0..<150).allSatisfy { outputs[$0] == "run-\($0)\n" })
    }

    @Test func collectsStderrAndStatus() async throws {
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo err >&2; exit 3"])
        #expect(r.status == 3)
        #expect(String(decoding: r.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: r.stderr, as: UTF8.self) == "err\n")
    }

    @Test func missingBinaryThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), [])
        }
    }
}

private final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Double, Double?)] = []
    var all: [(Double, Double?)] { lock.withLock { items } }
    func add(_ seconds: Double, _ speed: Double?) { lock.withLock { items.append((seconds, speed)) } }
}

@Suite("Progress parsing")
struct ProgressParserTests {
    private func parse(_ chunks: [String]) -> [(Double, Double?)] {
        let updates = Updates()
        let parser = ProgressParser { updates.add($0, $1) }
        for chunk in chunks { parser.feed(Data(chunk.utf8)) }
        return updates.all
    }

    @Test func linesSplitAcrossChunks() {
        let u = parse(["out_time_us=150", "0000\nspeed=2.", "5x\nprogr", "ess=continue\n"])
        #expect(u.count == 1)
        #expect(u.first?.0 == 1.5 && u.first?.1 == 2.5)
    }

    @Test func outTimeMsIsMicrosecondsToo() {
        // ffmpeg's out_time_ms is misnamed: it carries microseconds, like out_time_us.
        let u = parse(["out_time_ms=3000000\nspeed=1.2x\nprogress=continue\n"])
        #expect(u.first?.0 == 3 && u.first?.1 == 1.2)
    }

    @Test func notAvailableValuesAreSkipped() {
        let u = parse(["out_time_us=2000000\nspeed=1x\nprogress=continue\n",
                       "out_time_us=N/A\nspeed=N/A\nprogress=continue\n",
                       "out_time_us=-5\nprogress=end\n"])
        #expect(u.count == 3)
        #expect(u[1].0 == 2, "N/A keeps the last time")
        #expect(u[1].1 == nil)
        #expect(u[2].0 == 0, "negative times clamp to zero")
    }
}

// MARK: - Probe parsing

@Suite("Probe parsing")
struct ProbeParseTests {
    private func parse(_ streams: String, format: String = #"{"duration": "10.0", "bit_rate": "4000000"}"#) throws -> MediaInfo {
        try MediaProbe.parse(Data(#"{"streams": [\#(streams)], "format": \#(format)}"#.utf8))
    }

    private let audio = #"{"codec_type": "audio", "codec_name": "aac", "channels": 2, "sample_rate": "48000"}"#

    @Test func basicFields() throws {
        let info = try parse(#"{"codec_type": "video", "codec_name": "h264", "width": 1920, "height": 1080, "pix_fmt": "yuv420p", "avg_frame_rate": "30000/1001", "color_transfer": "bt709"}, "# + audio)
        #expect(info.width == 1920 && info.height == 1080)
        #expect(abs(info.frameRate - 29.97) < 0.01)
        #expect(info.duration == 10 && info.bitRate == 4_000_000)
        #expect(info.hasAudio && info.audioChannels == 2 && info.sampleRate == 48000)
        #expect(!info.hasAlpha && !info.isHDR)
    }

    @Test func rotationSwapsTheDisplaySize() throws {
        let side = try parse(#"{"codec_type": "video", "width": 1920, "height": 1080, "side_data_list": [{"side_data_type": "Display Matrix", "rotation": -90}]}"#)
        #expect(side.width == 1080 && side.height == 1920)
        let tag = try parse(#"{"codec_type": "video", "width": 1920, "height": 1080, "tags": {"rotate": "270"}}"#)
        #expect(tag.width == 1080 && tag.height == 1920)
        let flipped = try parse(#"{"codec_type": "video", "width": 1920, "height": 1080, "tags": {"rotate": "180"}}"#)
        #expect(flipped.width == 1920)
    }

    @Test func hdrFormats() throws {
        #expect(try parse(#"{"codec_type": "video", "color_transfer": "arib-std-b67"}"#).hdrFormat == "HLG")
        #expect(try parse(#"{"codec_type": "video", "color_transfer": "smpte2084"}"#).hdrFormat == "HDR10")
        let dovi = try parse(#"{"codec_type": "video", "color_transfer": "smpte2084", "side_data_list": [{"side_data_type": "DOVI configuration record"}]}"#)
        #expect(dovi.hdrFormat == "Dolby Vision")
    }

    @Test func alphaDetection() throws {
        #expect(try parse(#"{"codec_type": "video", "codec_name": "prores", "pix_fmt": "yuva444p10le"}"#).hasAlpha)
        let vp9 = try parse(#"{"codec_type": "video", "codec_name": "vp9", "pix_fmt": "yuv420p", "tags": {"alpha_mode": "1"}}"#)
        #expect(vp9.hasAlpha && vp9.needsLibvpxDecoder)
        #expect(try !parse(#"{"codec_type": "video", "codec_name": "vp9", "pix_fmt": "yuv420p"}"#).hasAlpha)
    }

    @Test func coverArtIsSkipped() throws {
        let info = try parse(#"{"codec_type": "video", "codec_name": "mjpeg", "width": 600, "height": 600, "disposition": {"attached_pic": 1}}, {"codec_type": "video", "codec_name": "hevc", "width": 3840, "height": 2160}"#)
        #expect(info.videoCodec == "hevc" && info.width == 3840)
    }

    @Test func noVideoStreamThrows() {
        #expect(throws: MediaProbe.ProbeError.self) { try parse(audio) }
        #expect(throws: MediaProbe.ProbeError.self) {
            try parse(#"{"codec_type": "video", "disposition": {"attached_pic": 1}}"#)
        }
    }
}
