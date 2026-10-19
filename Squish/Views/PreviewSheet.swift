import AppKit
import SwiftUI

/// Split-screen compare of one frame: lossless through the same filters vs. actually encoded.
struct PreviewSheet: View {
    @Environment(QueueStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let job: EncodeJob

    @State private var position: Double = 0
    @State private var split: CGFloat = 0.5
    @State private var before: NSImage?
    @State private var after: NSImage?
    @State private var sampleURL: URL?
    @State private var sampleBytes: Int64 = 0
    @State private var sampleDuration: Double = 0
    @State private var isWorking = false
    @State private var errorText: String?
    @State private var zoom: Zoom = .fit
    @State private var task: Task<Void, Never>?
    @State private var process: FFmpegProcess?
    @State private var temporaryFiles: [URL] = []

    private enum Zoom: String { case fit = "Fit", actual = "100%" }
    private let sampleLength = 3.0

    var body: some View {
        let settings = store.effectiveSettings(for: job)
        VStack(alignment: .leading, spacing: 16) {
            header

            compareArea(showsAlpha: settings.producesAlpha(sourceHasAlpha: job.media?.hasAlpha ?? false))
                .frame(maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
                .background(Color.black.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.glassEdge, lineWidth: 1))

            scrubber
            footer(settings)
        }
        .padding(22)
        .frame(width: 940, height: 680)
        .presentationBackground(.thinMaterial)
        .preferredColorScheme(store.appearance.colorScheme)
        .task {
            if let media = job.media {
                let kept = SampleEncoder.keptRange(settings, media: media)
                position = max(kept.lowerBound, (kept.lowerBound + kept.upperBound) / 2 - sampleLength / 2)
            }
            regenerate()
        }
        .onChange(of: store.effectiveSettings(for: job)) { regenerate() }
        .onDisappear {
            task?.cancel()
            process?.cancel()
            for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Before & after")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(job.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            PillSegmented(selection: $zoom, options: [.fit, .actual], compact: true) { $0.rawValue }
            Button("Done") { dismiss() }
                .buttonStyle(MiniChipStyle(selected: true))
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func compareArea(showsAlpha: Bool) -> some View {
        ZStack {
            if showsAlpha { Checkerboard() }

            if let before, let after {
                if zoom == .fit {
                    GeometryReader { geo in
                        comparison(before: before, after: after, size: fitted(after.size, in: geo.size))
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        comparison(before: before, after: after, size: after.size)
                    }
                    .defaultScrollAnchor(.center)
                }
            } else if !isWorking {
                Text(errorText == nil ? "No preview yet" : "Couldn't make a preview")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }

            if isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Encoding a \(Int(sampleLength))-second sample…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glass(in: Capsule())
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let errorText {
                Note(text: errorText).padding(14)
            }
        }
    }

    /// Both frames stacked at the same size; "before" is revealed left of the divider.
    private func comparison(before: NSImage, after: NSImage, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            image(after, size: size)
            image(before, size: size)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: size.width * split)
                }
            divider(height: size.height).offset(x: size.width * split - 14)
            HStack {
                tag("Original")
                Spacer()
                tag("Squished")
            }
            .padding(10)
            .frame(width: size.width)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            var next = min(max(value.location.x / max(size.width, 1), 0), 1)
            // Snap to the middle with a faint trackpad tick, so a fair 50/50 is easy to find.
            let snapped = abs(next - 0.5) < 0.025
            if snapped { next = 0.5 }
            if snapped && split != 0.5 { Delight.tick() }
            split = next
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Before and after comparison")
        .accessibilityValue("Showing \(Int(split * 100)) percent original")
        .accessibilityAdjustableAction { direction in
            split = min(max(split + (direction == .increment ? 0.1 : -0.1), 0), 1)
        }
    }

    private func image(_ image: NSImage, size: CGSize) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(zoom == .actual ? .none : .high)
            .frame(width: size.width, height: size.height)
            // Neutral inset hairline (pure white at 10% on this dark UI) for consistent depth.
            .overlay(Rectangle().strokeBorder(Theme.imageOutline, lineWidth: 1))
    }

    private func divider(height: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(.white).frame(width: 2, height: height).shadow(color: .black.opacity(0.5), radius: 3)
            Image(systemName: "chevron.left.chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        }
        .frame(width: 28, height: height)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            // Glass would take on the frame's colors; a dark scrim reads over anything.
            .background(Capsule().fill(.black.opacity(0.55)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }

    private var scrubber: some View {
        let duration = job.media?.duration ?? 0
        let upper = max(0, duration - 0.5)
        return HStack(spacing: 12) {
            Text(Format.duration(position))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(width: 44, alignment: .leading)
            Slider(value: $position, in: 0...max(upper, 0.01)) { editing in
                if !editing { regenerate() }
            }
            .controlSize(.small)
            .tint(Theme.orange)
            .disabled(upper <= 0)
            .accessibilityLabel("Preview position")
            .accessibilityValue(Format.duration(position))
            Text(Format.duration(duration))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func footer(_ settings: EncodeSettings) -> some View {
        HStack(spacing: 10) {
            if sampleBytes > 0 {
                Text("\(num((sampleDuration * 10).rounded() / 10))s sample → \(Format.bytes(sampleBytes))")
                    .foregroundStyle(Theme.secondary)
                if let full = fullEstimate(settings) {
                    Text("·").foregroundStyle(Theme.tertiary)
                    Text("Whole clip ≈ \(Format.bytes(full))").foregroundStyle(Theme.green)
                }
            }
            Text(settings.summaryText)
                .font(Theme.mono)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Spacer()
            if let sampleURL {
                Button("Play sample") { NSWorkspace.shared.open(sampleURL) }
                    .buttonStyle(MiniChipStyle(selected: false))
                    .help("Opens the encoded sample in your default player")
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
    }

    // MARK: Work

    private func fullEstimate(_ settings: EncodeSettings) -> Int64? {
        guard let media = job.media, sampleDuration > 0 else { return nil }
        let full = CommandBuilder(settings: settings, input: job.input, output: job.input, media: media).plan()
        return Int64(Double(sampleBytes) * full.expectedDuration / sampleDuration)
    }

    private func fitted(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return box }
        let scale = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private func regenerate() {
        task?.cancel()
        process?.cancel()
        guard let media = job.media, let encoder = store.sampleEncoder else {
            errorText = "Squish needs ffmpeg and a readable file to preview."
            return
        }
        let settings = store.effectiveSettings(for: job)
        let start = position
        let proc = FFmpegProcess()
        process = proc
        isWorking = true
        errorText = nil

        task = Task {
            do {
                let kept = SampleEncoder.keptRange(settings, media: media)
                let length = max(0.3, min(sampleLength, max(kept.upperBound, media.duration) - start))
                let sample = try await encoder.encode(input: job.input, media: media, settings: settings,
                                                      start: start, length: length, process: proc)
                temporaryFiles.append(sample.output)
                let speed = min(max(settings.playbackSpeed, 0.25), 4)
                let outTime = min(1, sample.outDuration / 2)
                let afterURL = try await encoder.frame(from: sample.output, at: outTime, settings: settings, process: proc)
                temporaryFiles.append(afterURL)
                let beforeURL = try await encoder.referenceFrame(input: job.input, media: media, settings: settings,
                                                                 sourceTime: start + outTime * speed, process: proc)
                temporaryFiles.append(beforeURL.deletingLastPathComponent())
                guard !Task.isCancelled else { return }
                before = NSImage(contentsOf: beforeURL)
                after = NSImage(contentsOf: afterURL)
                sampleURL = sample.output
                sampleBytes = sample.bytes
                sampleDuration = sample.outDuration
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorText = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// Transparency grid shown behind frames that keep alpha.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 12
            for row in 0..<Int(size.height / cell) + 1 {
                for col in 0..<Int(size.width / cell) + 1 where (row + col).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(.white.opacity(0.06)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
