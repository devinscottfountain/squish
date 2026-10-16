# Squish

A native macOS front end for ffmpeg. Compress, convert and handle transparent video. Simple mode gets out of your way, and Advanced mode exposes nearly every ffmpeg setting worth using.

## Run it

```bash
brew install ffmpeg xcodegen   # once
xcodegen generate              # regenerate Squish.xcodeproj after adding files
open Squish.xcodeproj          # ⌘R
```

Squish finds `ffmpeg`/`ffprobe` in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, a bundled copy, or any binary you pick with **Locate…**. It runs ffmpeg as a child process, so the App Sandbox is off.

## How it's built

| Path | What it does |
| --- | --- |
| `Models/EncodeSettings.swift` | Every option as one `Codable` struct, plus enums, derived rules (alpha support, codec/container validity) |
| `Models/QuickPreset.swift` | One-tap Simple-mode presets |
| `Models/MediaInfo.swift` | `ffprobe` JSON → duration, size, fps, rotation-aware dimensions, alpha detection |
| `Engine/CommandBuilder.swift` | Settings + media info → ffmpeg argument lists (1 or 2 passes), plus warnings. Pure, so it's testable |
| `Engine/FFmpegProcess.swift` | Runs ffmpeg with `-progress pipe:1`, parses progress, supports cancel |
| `Engine/FFmpegEnvironment.swift` | Locates binaries, reads version, lists available encoders |
| `Store/QueueStore.swift` | Queue, jobs, persistence, output naming, the encode loop |
| `Views/` | SwiftUI: dark cards, pill controls, dashed-ring status glyphs, floating toolbar |

## What's in v0.1

**Simple mode:** 8 presets (Smaller, Under 10 MB, Web ready, Modern/HEVC, ProRes 4444, Web alpha, GIF, Archive), format chips, quality slider *or* target file size, resolution, audio on/off, transparency, strip metadata.

**Advanced mode:**
- **Format**: MP4, MOV, MKV, WebM, GIF, WebP, APNG, PNG frames; H.264, HEVC, AV1, VP9, ProRes, passthrough; VideoToolbox hardware encode and decode
- **Video**: quality (CRF mapped per encoder), bitrate with max rate and buffer, two-pass, target file size, CBR; encoder speed, tune, H.264 profile, pixel format/bit depth, ProRes profile, keyframe interval, B-frames, fast start
- **Frame**: resolution by short edge (portrait-aware, no upscaling unless allowed), custom size, scaler, frame rate with drop/blend/motion-interpolate, rotate, flip, crop, deinterlace, denoise, sharpen, brightness/contrast/saturation/gamma
- **Time**: trim, 0.25×–4× speed (video and pitch-preserving audio), reverse, fade in/out
- **Audio**: AAC/Opus/MP3/FLAC/PCM/passthrough, bitrate, sample rate, channels, gain, EBU R128 loudness normalize
- **Transparency**: Auto / Keep / Flatten onto a color / Chroma key; ProRes 4444, VP9 alpha (decoded with libvpx so alpha survives), HEVC alpha via VideoToolbox, GIF/APNG/PNG alpha; HEVC alpha quality
- **Metadata**: strip all, strip location, chapters, title/artist/comment/copyright
- **Output**: next to source or a folder, suffix, overwrite or auto-number, threads, raw extra ffmpeg args

Plus: drag-and-drop (files or folders), Dock/`open -a` support, live progress/speed/ETA, per-file savings, "Copy command", and a sheet showing the exact ffmpeg command.

## Performance (Apple silicon only)

Squish is Swift and SwiftUI, built for arm64 only. ffmpeg does the encoding, so speed depends on the encoder it uses. These were measured on an M4 Pro (10 performance and 4 efficiency cores) with 1080p30 footage.

| Encoder | Speed (× realtime) | Notes |
|---|---|---|
| H.264, media engine (default) | 6.8–7.5× | Size and quality about even with x264 medium on detailed or grainy footage; files can be larger on flat graphics |
| H.264, x264 medium (Smallest) | 2.3–3.1× | |
| HEVC, media engine | 6.6–6.8× | Quality scale calibrated so q≈48 matches x265 medium |
| HEVC, x265 medium | 1.5–1.9× | |
| AV1, SVT preset 8 | 5.5–7.1× | Smallest files on grainy footage |
| ProRes 422 HQ, media engine | 18.7× | About 4× faster than software; used for 422 profiles |
| ProRes 422 HQ, prores_ks | 4.5× | Still used for 4444 and transparency |

What this means for the defaults:
- **Encoder:** Simple mode's Encoder switch defaults to Fastest, the media engine. "Under 10 MB" and "Archive" stay in software, which hits exact sizes and makes the smallest files.
- **Files at once:** defaults to 1. Two x264 encodes side by side took as long as running them one after another, because each already uses every core.
- **Hardware decoding:** left off. It made no difference when encoding with x264.
- **Untagged video:** gets BT.709 (HD) or BT.601 (SD) color tags before the media engine sees it. Untagged sources otherwise came out color-shifted from ProRes.
- **Rosetta check:** Squish warns if your ffmpeg is an Intel build, which would run under Rosetta several times slower. Install the Apple silicon build with Homebrew in `/opt/homebrew`.

## Small delights

Kept quiet on purpose. Each one fires on a real event and respects Reduce Motion and the Mac's UI sound setting.

- **Finish sound:** a 0.5 s stereo "squish-pop-chime", played once per batch. It's built in `Tools/render_sound.py` from seven layers: a low thump, a detuned squish tone, a squelch of filtered noise, a transient click, a bubble pop, a soft bell fifth and a short room. To change it, tweak the per-layer gains in `render()` and re-run the script. You can turn the sound off in Output › Sound when done or Queue › Play Sound When Done.
- **Row squish:** the status ring squashes and springs back as a file's check lands.
- **Count-up:** saved bytes and percentages roll up in the stats pill.
- **Dock:** a progress bar on the icon during a batch, and one bounce at the end only if Squish is in the background.
- **Lifetime savings:** hover the stats pill.
- **Haptics:** a tick when the preview divider snaps to center, and a soft thud when files are dropped.
- **"All squished.":** shown briefly in the empty state after clearing a finished batch.
- **Big-win shimmer:** one pass of light across the result line, only for files that shrank 90% or more.

## Ideas for next

**Workflow**
- Save custom presets; import/export them as JSON
- Per-file settings overrides (right now one settings snapshot applies to the whole queue)
- Run 2–4 jobs in parallel; pause/resume
- Watch folders: auto-squish anything dropped into a folder
- Menu bar extra and Finder Quick Action / Share extension
- Notifications and a Dock progress bar

**Seeing results**
- Before/after split-view preview (AVPlayer) with a scrubber
- Fast 5-second preview encode to judge settings
- Size estimate before encoding (sample-encode a few seconds)
- VMAF/SSIM quality score after encoding

**More encoding**
- HDR → SDR tone mapping (`zscale` + `tonemap`) and HDR passthrough metadata
- Audio track and subtitle selection, burn-in subtitles
- Watermark/overlay image, text overlays, letterbox/pad to aspect ratio
- Visual crop tool on a frame grab
- Thumbnail, contact sheet and poster-frame export
- Concatenate clips; split by size or duration
- Stabilization (`vidstab`), auto-crop black bars (`cropdetect`)
- Lossless trim (keyframe-aligned stream copy)
- Bundle a static ffmpeg in the app so users don't need Homebrew

## Notes

- Target size uses 1 MB = 1,000,000 bytes with 5% headroom, matching how upload limits are usually stated.
- Two-pass applies to libx264, libvpx-vp9 and libaom-av1. libx265, SVT-AV1 and VideoToolbox run single-pass.
- This Homebrew ffmpeg build has no `libwebp`, so WebP output warns until you install a build that has it.
