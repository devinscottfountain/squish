import Foundation

struct EncodePlan {
    /// One argument list per ffmpeg run (two for two-pass encodes). Binary not included.
    var passes: [[String]]
    var output: URL
    var expectedDuration: Double
    var warnings: [String]
    var passLogPrefix: String?

    func commandLine(binary: String = "ffmpeg") -> String {
        passes
            .map { ([binary] + $0).map(shellQuote).joined(separator: " ") }
            .joined(separator: " && \\\n")
    }
}

/// Turns `EncodeSettings` into ffmpeg arguments.
struct CommandBuilder {
    var settings: EncodeSettings
    var input: URL
    var output: URL
    var media: MediaInfo?
    /// Encoders the local ffmpeg reports. Empty means "unknown, assume everything".
    var encoders: Set<String> = []

    private struct VideoEncoder {
        var name: String
        var args: [String]
        var pixelFormat: String?
    }

    private struct AudioPlan {
        var enabled: Bool
        var args: [String]
        var kbps: Int
    }

    func plan() -> EncodePlan {
        var s = settings
        s.normalize()
        var warnings: [String] = []

        let isImage = s.container.isAnimatedImage
        let copyVideo = !isImage && s.videoCodec == .copy
        let speed = min(max(s.playbackSpeed, 0.25), 4)
        let sourceAlpha = media?.hasAlpha ?? false
        let alphaOut = s.producesAlpha(sourceHasAlpha: sourceAlpha)
        let alphaInGraph = sourceAlpha || s.alphaMode == .chromaKey

        // Timing
        let sourceDuration = media?.duration ?? 0
        let start = max(0, s.trimStart)
        var end = s.trimEnd > start ? s.trimEnd : sourceDuration
        if sourceDuration > 0 { end = min(end, sourceDuration) }
        let trimmed = max(0, end - start)
        let outDuration = copyVideo ? trimmed : trimmed / speed

        // Input
        var head = ["-hide_banner", "-y"]
        let forceVPX = (media?.needsLibvpxDecoder ?? false) && has("libvpx-vp9")
        if s.useHardwareDecoder && !forceVPX && !copyVideo { head += ["-hwaccel", "videotoolbox"] }
        if start > 0 { head += ["-ss", num(start)] }
        if s.trimEnd > start { head += ["-t", num(s.trimEnd - start)] }
        if forceVPX { head += ["-c:v", "libvpx-vp9"] }
        head += ["-i", input.path]

        // Video
        let encoder = videoEncoder(s, alphaOut: alphaOut, warnings: &warnings)
        if encoder.name != "copy" && encoder.name != "gif" && !has(encoder.name) {
            warnings.append("This ffmpeg build doesn't include \(encoder.name).")
        }
        let audioPlan = audio(s, speed: copyVideo ? 1 : speed, outDuration: outDuration, warnings: &warnings)

        var videoArgs = encoder.args
        var twoPass = false
        if !isImage && !copyVideo && s.videoCodec != .prores {
            let rate = rateControl(s, encoder: encoder.name, outDuration: outDuration, audioKbps: audioPlan.kbps, warnings: &warnings)
            videoArgs += rate.args
            twoPass = rate.twoPass

            if s.keyframeIntervalSeconds > 0 {
                if let fps = s.targetFrameRate ?? media?.frameRate, fps > 0 {
                    videoArgs += ["-g", "\(max(1, Int((fps * s.keyframeIntervalSeconds).rounded())))"]
                } else {
                    videoArgs += ["-force_key_frames", "expr:gte(t,n_forced*\(num(s.keyframeIntervalSeconds)))"]
                }
            }
            if s.bFrames >= 0 && !encoder.name.hasPrefix("libvpx") { videoArgs += ["-bf", "\(s.bFrames)"] }
        }

        var filters: [String] = []
        if copyVideo {
            if s.resolution != .original || s.targetFrameRate != nil || speed != 1 || s.rotation != .none {
                warnings.append("Passthrough copies the video stream as-is, so frame and speed changes are ignored.")
            }
        } else {
            filters = videoFilters(s, alphaInGraph: alphaInGraph, alphaOut: alphaOut, speed: speed,
                                   outDuration: outDuration, pixelFormat: encoder.pixelFormat)
        }
        let filterArgs = filters.isEmpty ? [] : ["-vf", filters.joined(separator: ",")]

        var maps = ["-map", "0:v:0"]
        if audioPlan.enabled { maps += ["-map", "0:a:0?"] }

        // Container, metadata, misc
        var tail: [String] = []
        if s.stripMetadata { tail += ["-map_metadata", "-1"] }
        if s.stripMetadata || !s.keepChapters { tail += ["-map_chapters", "-1"] }
        if s.stripLocation && !s.stripMetadata { tail += ["-metadata", "location=", "-metadata", "location-eng="] }
        for (key, value) in [("title", s.metaTitle), ("artist", s.metaArtist), ("comment", s.metaComment), ("copyright", s.metaCopyright)]
            where !value.isEmpty {
            tail += ["-metadata", "\(key)=\(value)"]
        }
        if s.container.supportsFastStart && s.fastStart { tail += ["-movflags", "+faststart"] }
        if s.threads > 0 { tail += ["-threads", "\(s.threads)"] }
        tail += splitArguments(s.extraArguments)

        let outputPath = s.container == .pngSequence
            ? output.appendingPathComponent("frame_%05d.png").path
            : output.path

        var passes: [[String]] = []
        var logPrefix: String?
        if twoPass {
            let prefix = FileManager.default.temporaryDirectory
                .appendingPathComponent("squish-\(UUID().uuidString.prefix(8))").path
            logPrefix = prefix
            var first: [String] = head
            first += ["-map", "0:v:0"]
            first += filterArgs
            first += videoArgs
            first += ["-pass", "1", "-passlogfile", prefix, "-an", "-f", "null", "/dev/null"]
            var second: [String] = head
            second += maps
            second += filterArgs
            second += videoArgs
            second += ["-pass", "2", "-passlogfile", prefix]
            second += audioPlan.args
            second += tail
            second.append(outputPath)
            passes = [first, second]
        } else {
            var single: [String] = head
            single += maps
            single += filterArgs
            single += videoArgs
            single += audioPlan.args
            single += tail
            single.append(outputPath)
            passes = [single]
        }

        return EncodePlan(passes: passes, output: output, expectedDuration: outDuration,
                          warnings: warnings, passLogPrefix: logPrefix)
    }

    // MARK: - Quality mapping

    /// The encoder-native quality flag for the 0…100 quality slider.
    static func qualityParameter(for s: EncodeSettings) -> (flag: String, value: Int)? {
        let q = min(max(s.quality, 0), 100)
        func crf(_ best: Double, _ worst: Double) -> Int { Int((worst - (worst - best) * q / 100).rounded()) }
        let vt = Int((35 + q * 0.55).rounded())
        if s.container == .webp { return ("-quality", Int(q)) }
        if s.container.isAnimatedImage { return nil }
        switch s.videoCodec {
        case .h264: return s.hardwareEncoding ? ("-q:v", vt) : ("-crf", crf(14, 36))
        case .hevc: return s.hardwareEncoding ? ("-q:v", vt) : ("-crf", crf(16, 38))
        case .av1: return ("-crf", crf(18, 55))
        case .vp9: return ("-crf", crf(15, 50))
        case .prores, .copy: return nil
        }
    }

    // MARK: - Video encoder

    private func videoEncoder(_ s: EncodeSettings, alphaOut: Bool, warnings: inout [String]) -> VideoEncoder {
        switch s.container {
        case .gif:
            return VideoEncoder(name: "gif", args: ["-loop", "\(s.loopCount)"], pixelFormat: nil)
        case .webp:
            let name = has("libwebp_anim") ? "libwebp_anim" : "libwebp"
            let level = [0, 2, 4, 5, 6][s.speed.index]
            var args = ["-c:v", name, "-loop", "\(s.loopCount)", "-compression_level", "\(level)"]
            args += s.webpLossless ? ["-lossless", "1"] : ["-quality", "\(Int(s.quality))"]
            return VideoEncoder(name: name, args: args, pixelFormat: alphaOut ? "yuva420p" : "yuv420p")
        case .apng:
            return VideoEncoder(name: "apng", args: ["-c:v", "apng", "-plays", "\(s.loopCount)", "-f", "apng"],
                                pixelFormat: alphaOut ? "rgba" : "rgb24")
        case .pngSequence:
            return VideoEncoder(name: "png", args: ["-c:v", "png"], pixelFormat: alphaOut ? "rgba" : "rgb24")
        default:
            break
        }

        let i = s.speed.index
        let x26xPresets = ["veryfast", "faster", "medium", "slow", "veryslow"]
        let chosen: String? = s.pixelFormat == .auto ? nil : s.pixelFormat.rawValue

        switch s.videoCodec {
        case .copy:
            return VideoEncoder(name: "copy", args: ["-c:v", "copy"], pixelFormat: nil)

        case .h264:
            if s.hardwareEncoding {
                var args = ["-c:v", "h264_videotoolbox", "-allow_sw", "1"]
                if s.h264Profile != .auto { args += ["-profile:v", s.h264Profile.rawValue] }
                var pf = chosen ?? "yuv420p"
                if pf != "yuv420p" {
                    warnings.append("VideoToolbox H.264 only does 4:2:0 8-bit, so that's what you'll get.")
                    pf = "yuv420p"
                }
                return VideoEncoder(name: "h264_videotoolbox", args: args, pixelFormat: pf)
            }
            var args = ["-c:v", "libx264", "-preset", x26xPresets[i]]
            if s.tune != .none { args += ["-tune", s.tune.rawValue] }
            if s.h264Profile != .auto {
                if chosen == nil || chosen == "yuv420p" {
                    args += ["-profile:v", s.h264Profile.rawValue]
                } else {
                    warnings.append("H.264 profile ignored: \(s.h264Profile.label) doesn't support \(s.pixelFormat.label).")
                }
            }
            return VideoEncoder(name: "libx264", args: args, pixelFormat: chosen ?? "yuv420p")

        case .hevc:
            if s.hardwareEncoding {
                var args = ["-c:v", "hevc_videotoolbox", "-allow_sw", "1", "-tag:v", "hvc1"]
                if alphaOut {
                    args += ["-alpha_quality", num(s.hevcAlphaQuality)]
                    return VideoEncoder(name: "hevc_videotoolbox", args: args, pixelFormat: "bgra")
                }
                if chosen == "yuv420p10le" {
                    args += ["-profile:v", "main10"]
                    return VideoEncoder(name: "hevc_videotoolbox", args: args, pixelFormat: "p010le")
                }
                return VideoEncoder(name: "hevc_videotoolbox", args: args, pixelFormat: chosen ?? "yuv420p")
            }
            var args = ["-c:v", "libx265", "-preset", x26xPresets[i], "-tag:v", "hvc1", "-x265-params", "log-level=error"]
            if [.animation, .grain, .fastdecode, .zerolatency].contains(s.tune) { args += ["-tune", s.tune.rawValue] }
            return VideoEncoder(name: "libx265", args: args, pixelFormat: chosen ?? "yuv420p")

        case .av1:
            if !has("libsvtav1") && has("libaom-av1") {
                let cpu = ["8", "6", "4", "3", "2"][i]
                return VideoEncoder(name: "libaom-av1", args: ["-c:v", "libaom-av1", "-cpu-used", cpu, "-row-mt", "1"],
                                    pixelFormat: chosen ?? "yuv420p")
            }
            let preset = ["12", "10", "8", "6", "4"][i]
            return VideoEncoder(name: "libsvtav1", args: ["-c:v", "libsvtav1", "-preset", preset],
                                pixelFormat: chosen ?? "yuv420p")

        case .vp9:
            var args = ["-c:v", "libvpx-vp9", "-deadline", "good", "-cpu-used", ["5", "4", "2", "1", "0"][i], "-row-mt", "1"]
            if alphaOut { args += ["-auto-alt-ref", "0"] }
            return VideoEncoder(name: "libvpx-vp9", args: args, pixelFormat: alphaOut ? "yuva420p" : (chosen ?? "yuv420p"))

        case .prores:
            var profile = s.proresProfile.rawValue
            if alphaOut && profile < ProResProfile.p4444.rawValue { profile = ProResProfile.p4444.rawValue }
            var args = ["-c:v", "prores_ks", "-profile:v", "\(profile)", "-vendor", "apl0"]
            if alphaOut { args += ["-alpha_bits", "16"] }
            let pf = alphaOut ? "yuva444p10le" : (profile >= 4 ? "yuv444p10le" : "yuv422p10le")
            return VideoEncoder(name: "prores_ks", args: args, pixelFormat: pf)
        }
    }

    // MARK: - Rate control

    private func rateControl(_ s: EncodeSettings, encoder: String, outDuration: Double, audioKbps: Int,
                             warnings: inout [String]) -> (args: [String], twoPass: Bool) {
        let twoPassCapable = ["libx264", "libvpx-vp9", "libaom-av1"].contains(encoder)
        let isHardware = encoder.hasSuffix("_videotoolbox")

        switch s.rateControl {
        case .quality:
            guard let q = Self.qualityParameter(for: s) else { return ([], false) }
            var args = [q.flag, "\(q.value)"]
            if encoder == "libvpx-vp9" || encoder == "libaom-av1" { args += ["-b:v", "0"] }
            return (args, false)

        case .bitrate:
            var args = ["-b:v", "\(s.videoBitrateKbps)k"]
            if s.maxBitrateKbps > 0 { args += ["-maxrate", "\(s.maxBitrateKbps)k"] }
            if s.bufferSizeKbps > 0 {
                args += ["-bufsize", "\(s.bufferSizeKbps)k"]
            } else if s.maxBitrateKbps > 0 {
                args += ["-bufsize", "\(s.maxBitrateKbps * 2)k"]
            }
            return (args, s.twoPass && twoPassCapable)

        case .constant:
            let k = "\(s.videoBitrateKbps)k"
            var args = ["-b:v", k, "-maxrate", k, "-bufsize", "\(s.videoBitrateKbps * 2)k"]
            if !isHardware { args += ["-minrate", k] }
            if encoder == "libx264" { args += ["-x264-params", "nal-hrd=cbr"] }
            return (args, false)

        case .targetSize:
            guard outDuration > 0 else {
                warnings.append("Couldn't read the duration, so the size target can't be worked out. Using 2,500 kbps.")
                return (["-b:v", "2500k"], false)
            }
            // MB here is 1,000,000 bytes, matching how upload limits are usually stated. 5% headroom for the container.
            let totalKbps = s.targetSizeMB * 8000 / outDuration * 0.95
            let video = Int(totalKbps) - audioKbps
            if video < 150 { warnings.append("That size is tight for this length. Expect heavy artifacts, or drop the resolution.") }
            if isHardware { warnings.append("Hardware encoders can overshoot a size target; software is more precise.") }
            let k = max(video, 50)
            return (["-b:v", "\(k)k", "-maxrate", "\(k * 3 / 2)k", "-bufsize", "\(k * 2)k"], twoPassCapable)
        }
    }

    // MARK: - Filters

    private func videoFilters(_ s: EncodeSettings, alphaInGraph: Bool, alphaOut: Bool, speed: Double,
                              outDuration: Double, pixelFormat: String?) -> [String] {
        var f: [String] = []
        if s.deinterlace { f.append("yadif=deint=interlaced") }

        let cropX = s.cropLeft + s.cropRight
        let cropY = s.cropTop + s.cropBottom
        if cropX > 0 || cropY > 0 { f.append("crop=iw-\(cropX):ih-\(cropY):\(s.cropLeft):\(s.cropTop)") }

        if s.alphaMode == .chromaKey {
            f.append("format=rgba")
            f.append("colorkey=\(ffColor(s.keyColorHex)):\(num(s.keySimilarity)):\(num(s.keyBlend))")
        }

        switch s.rotation {
        case .none: break
        case .cw90: f.append("transpose=clock")
        case .ccw90: f.append("transpose=cclock")
        case .r180: f.append("hflip,vflip")
        }
        if s.flipHorizontal { f.append("hflip") }
        if s.flipVertical { f.append("vflip") }

        if let scale = scaleFilter(s) { f.append(scale) }

        switch s.denoise {
        case .off: break
        case .light: f.append("hqdn3d=2:1.5:3:2.25")
        case .medium: f.append("hqdn3d=4:3:6:4.5")
        case .strong: f.append("hqdn3d=8:6:12:9")
        }
        switch s.sharpen {
        case .off: break
        case .light: f.append("unsharp=5:5:0.4")
        case .medium: f.append("unsharp=5:5:0.8")
        case .strong: f.append("unsharp=5:5:1.4")
        }
        if s.hasColorAdjustments {
            f.append("eq=brightness=\(num(s.brightness)):contrast=\(num(s.contrast)):saturation=\(num(s.saturation)):gamma=\(num(s.gamma))")
        }

        if speed != 1 { f.append("setpts=PTS/\(num(speed))") }
        if s.reverse { f.append("reverse") }

        if let fps = s.targetFrameRate {
            switch s.frameRateMethod {
            case .drop: f.append("fps=\(num(fps))")
            case .blend: f.append("framerate=fps=\(num(fps))")
            case .interpolate: f.append("minterpolate=fps=\(num(fps)):mi_mode=mci:mc_mode=aobmc:vsbmc=1")
            }
        }

        let fadeAlpha = alphaOut ? ":alpha=1" : ""
        if s.fadeIn > 0 { f.append("fade=t=in:st=0:d=\(num(s.fadeIn))\(fadeAlpha)") }
        if s.fadeOut > 0 && outDuration > s.fadeOut {
            f.append("fade=t=out:st=\(num(outDuration - s.fadeOut)):d=\(num(s.fadeOut))\(fadeAlpha)")
        }

        // Dropping alpha without flattening leaves whatever color was hiding under it. Paint a background first.
        if alphaInGraph && !alphaOut {
            f.append("format=rgba,split[sq_fg][sq_bg];[sq_bg]drawbox=x=0:y=0:w=iw:h=ih:color=\(ffColor(s.backgroundHex))@1:t=fill[sq_base];[sq_base][sq_fg]overlay=format=auto")
        }

        if s.container == .gif {
            let colors = min(max(s.gifMaxColors, 2), 256)
            let reserve = alphaOut ? 1 : 0
            let threshold = alphaOut ? ":alpha_threshold=128" : ""
            f.append("split[sq_p0][sq_p1];[sq_p0]palettegen=max_colors=\(colors):stats_mode=full:reserve_transparent=\(reserve)[sq_pal];[sq_p1][sq_pal]paletteuse=dither=\(s.gifDither.rawValue)\(threshold)")
        } else if let pixelFormat {
            f.append("format=\(pixelFormat)")
        }
        return f
    }

    private func scaleFilter(_ s: EncodeSettings) -> String? {
        let flags = "flags=\(s.scaleAlgorithm.rawValue)"
        switch s.resolution {
        case .original:
            // 4:2:0 encoders reject odd dimensions.
            let oddSource = media.map { $0.width % 2 == 1 || $0.height % 2 == 1 } ?? false
            let oddCrop = (s.cropLeft + s.cropRight) % 2 == 1 || (s.cropTop + s.cropBottom) % 2 == 1
            if !s.container.isAnimatedImage && (oddSource || oddCrop) { return "scale=trunc(iw/2)*2:trunc(ih/2)*2" }
            return nil
        case .custom:
            if s.customWidth <= 0 && s.customHeight <= 0 { return nil }
            let w = s.customWidth > 0 ? "\(s.customWidth)" : "-2"
            let h = s.customHeight > 0 ? "\(s.customHeight)" : "-2"
            return "scale=\(w):\(h):\(flags)"
        default:
            let target = s.resolution.shortSide ?? 1080
            let quarterTurn = s.rotation == .cw90 || s.rotation == .ccw90
            let portrait = media.map { quarterTurn ? $0.width > $0.height : $0.height > $0.width } ?? false
            if portrait {
                return s.allowUpscale ? "scale=\(target):-2:\(flags)" : "scale='min(iw,\(target))':-2:\(flags)"
            }
            return s.allowUpscale ? "scale=-2:\(target):\(flags)" : "scale=-2:'min(ih,\(target))':\(flags)"
        }
    }

    // MARK: - Audio

    private func audio(_ s: EncodeSettings, speed: Double, outDuration: Double, warnings: inout [String]) -> AudioPlan {
        let hasAudio = media?.hasAudio ?? true
        guard !s.container.isAnimatedImage, s.audioCodec != .none, hasAudio else {
            return AudioPlan(enabled: false, args: ["-an"], kbps: 0)
        }
        if s.audioCodec == .copy {
            if speed != 1 || s.reverse || s.volumeDB != 0 || s.normalizeLoudness || s.fadeIn > 0 || s.fadeOut > 0 {
                warnings.append("Audio passthrough ignores speed, volume, fades and loudness changes.")
            }
            return AudioPlan(enabled: true, args: ["-c:a", "copy"], kbps: 192)
        }

        var args = ["-c:a", s.audioCodec.encoderName]
        var kbps = 1411
        if s.audioCodec.isLossy {
            kbps = s.audioBitrateKbps
            args += ["-b:a", "\(kbps)k"]
        }
        if var rate = s.sampleRate.value {
            if s.audioCodec == .opus && rate != 48000 {
                rate = 48000
                warnings.append("Opus only runs at 48 kHz, so that's what it'll use.")
            }
            args += ["-ar", "\(rate)"]
        }
        if let ch = s.channels.value {
            args += ["-ac", "\(ch)"]
        } else if s.audioCodec == .opus && (media?.audioChannels ?? 2) > 2 {
            args += ["-ac", "2"]
            warnings.append("Downmixing surround audio to stereo for Opus.")
        }

        var af: [String] = []
        if speed != 1 { af += atempoChain(speed) }
        if s.reverse { af.append("areverse") }
        if s.volumeDB != 0 { af.append("volume=\(num(s.volumeDB))dB") }
        if s.normalizeLoudness { af.append("loudnorm=I=-16:TP=-1.5:LRA=11") }
        if s.fadeIn > 0 { af.append("afade=t=in:st=0:d=\(num(s.fadeIn))") }
        if s.fadeOut > 0 && outDuration > s.fadeOut {
            af.append("afade=t=out:st=\(num(outDuration - s.fadeOut)):d=\(num(s.fadeOut))")
        }
        if !af.isEmpty { args += ["-af", af.joined(separator: ",")] }
        return AudioPlan(enabled: true, args: args, kbps: kbps)
    }

    /// atempo only accepts 0.5…2 per instance, so chain it.
    private func atempoChain(_ speed: Double) -> [String] {
        var remaining = speed
        var chain: [String] = []
        while remaining > 2 { chain.append("atempo=2"); remaining /= 2 }
        while remaining < 0.5 { chain.append("atempo=0.5"); remaining /= 0.5 }
        chain.append("atempo=\(num(remaining))")
        return chain
    }

    // MARK: - Helpers

    private func has(_ encoder: String) -> Bool { encoders.isEmpty || encoders.contains(encoder) }
}

func num(_ value: Double) -> String {
    if value == value.rounded() && abs(value) < 1e9 { return String(Int(value)) }
    var text = String(format: "%.4f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}

func ffColor(_ hex: String) -> String {
    "0x" + hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
}

func shellQuote(_ value: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./=:,+@%")
    if !value.isEmpty && value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Splits user-typed extra arguments, honoring single and double quotes.
func splitArguments(_ text: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quote: Character?
    var inToken = false
    for ch in text {
        if let q = quote {
            if ch == q { quote = nil } else { current.append(ch) }
        } else if ch == "\"" || ch == "'" {
            quote = ch
            inToken = true
        } else if ch.isWhitespace {
            if inToken { result.append(current); current = ""; inToken = false }
        } else {
            current.append(ch)
            inToken = true
        }
    }
    if inToken { result.append(current) }
    return result
}
