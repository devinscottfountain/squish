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
