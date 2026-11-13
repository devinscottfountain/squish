import AppKit
import SwiftUI

// MARK: - Queue card

struct QueueCard: View {
    @Environment(QueueStore.self) private var store
    // Drag-to-reorder: which row is lifted, how far it has moved, and where it would land
    // (.some(nil) means after the last row).
    @State private var dragged: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var dropBefore: UUID??
    @State private var rowFrames: [UUID: CGRect] = [:]
    private static let space = "queue"

    var body: some View {
        Card {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.isRunning ? "Squishing" : "Queue")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    if store.hasFinished && !store.isRunning {
                        Button("Clear finished") { store.clearFinished() }
                            .buttonStyle(MiniChipStyle(selected: false))
                    }
                    Text(store.jobs.count == 1 ? "1 file" : "\(store.jobs.count) files")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
                // Fixed height, so the rows don't shift when "Clear finished" appears.
                .frame(height: 22)
                // Lines up with the rows below (16 pt in from the card edge).
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)

                if !store.environment.isAvailable && !store.environment.isChecking {
                    InstallBanner().padding(.horizontal, 16).padding(.bottom, 8)
                } else if store.environment.isTranslated {
                    Note(text: "Your ffmpeg is an Intel build running under Rosetta, so encodes are much slower. Install the Apple silicon one with: brew install ffmpeg (Homebrew in /opt/homebrew).")
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                if store.jobs.isEmpty {
                    // Concentric with the card: card radius 22 = zone radius 12 + 10 inset.
                    DropZone().padding(10)
                        // Leaves fast so it never sits under the first rows as they arrive.
                        .transition(.asymmetric(insertion: .opacity.animation(Motion.out(0.25)),
                                                removal: .opacity.animation(Motion.out(0.08))))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.jobs) { job in
                                let isDragged = dragged == job.id
                                JobRow(job: job)
                                    .overlay(alignment: .bottom) {
                                        if job.id != store.jobs.last?.id && !isDragged {
                                            // Starts under the name: glyph 26 + spacing 10.
                                            Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 36)
                                        }
                                    }
                                    .overlay(alignment: .top) { insertionLine(visible: dropBefore == .some(job.id)) }
                                    .background {
                                        if isDragged {
                                            // Solid, so the lifted row doesn't show the one beneath it.
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(Theme.lifted)
                                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.glassEdge, lineWidth: 1))
                                                .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                                                .padding(.horizontal, -8)
                                        }
                                    }
                                    .scaleEffect(isDragged ? 1.02 : 1)
                                    .offset(y: isDragged ? dragOffset : 0)
                                    .zIndex(isDragged ? 1 : 0)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                                        rowFrames[job.id] = $0
                                    }
                                    .gesture(reorderGesture(for: job))
                                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)),
                                                            removal: .opacity))
                            }
                            Color.clear
                                .frame(height: 40)
                                .overlay(alignment: .top) { insertionLine(visible: dragged != nil && dropBefore == .some(nil)) }
                        }
                        .padding(.horizontal, 16)
                        .coordinateSpace(.named(Self.space))
                    }
                    .scrollIndicators(.never)
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 48)
                        }
                    }
                }
            }
        }
    }

    /// Press and drag a row to move it. A few points of movement are needed first, so clicks still expand rows.
    private func reorderGesture(for job: EncodeJob) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragged == nil {
                    withAnimation(.snappy(duration: 0.15)) { dragged = job.id }
                }
                dragOffset = value.translation.height
                let target = store.jobs
                    .filter { $0.id != job.id }
                    .first { (rowFrames[$0.id]?.midY ?? .infinity) > value.location.y }?.id
                // Hide the line when dropping would leave the row where it is.
                let index = store.jobs.firstIndex { $0.id == job.id } ?? 0
                let next = index + 1 < store.jobs.count ? store.jobs[index + 1].id : nil
                let newTarget: UUID?? = target == next ? nil : .some(target)
                if newTarget != dropBefore {
                    withAnimation(.easeOut(duration: 0.12)) { dropBefore = newTarget }
                    if newTarget != nil { Delight.tick() }
                }
            }
            .onEnded { _ in
                if let target = dropBefore { store.move(job.id, before: target) }
                withAnimation(.snappy(duration: 0.25)) {
                    dragged = nil
                    dragOffset = 0
                    dropBefore = nil
                }
            }
    }

    @ViewBuilder
    private func insertionLine(visible: Bool) -> some View {
        if visible {
            Capsule()
                .fill(Theme.orange)
                .frame(height: 3)
                .shadow(color: Theme.orange.opacity(0.6), radius: 4)
                .offset(y: -2)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}

struct InstallBanner: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text("Squish needs ffmpeg")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("Install it with Homebrew, then hit Check again. Or point Squish at a binary you already have.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                HStack(spacing: 6) {
                    Text("brew install ffmpeg")
                        .font(Theme.mono)
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.field))
                        .textSelection(.enabled)
                    Button("Check again") { Task { await store.environment.refresh(); store.reprobeAll() } }
                        .buttonStyle(MiniChipStyle(selected: false))
                    Button("Locate…") { store.locateFFmpeg() }
                        .buttonStyle(MiniChipStyle(selected: false))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.yellow.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.yellow.opacity(0.25)))
    }
}

struct DropZone: View {
    @Environment(QueueStore.self) private var store
    @State private var hovering = false
    @State private var ringTurning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            let allDone = store.showAllSquished
            ZStack {
                // Slow, constant spin (one turn every 24 s), with round-capped dashes like the status rings.
                // A repeating rotation, not a clock, so the ring doesn't re-render every frame. The scoped
                // animation keeps the repeat off the color change on hover.
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [3, 6.5]))
                    .foregroundStyle(allDone ? Theme.yellow : (hovering ? Theme.secondary : Theme.tertiary))
                    .animation(reduceMotion ? nil : .linear(duration: 24).repeatForever(autoreverses: false)) {
                        $0.rotationEffect(.degrees(ringTurning && !reduceMotion ? 360 : 0))
                    }
                    .onAppear { ringTurning = true }
                // Both icons stay mounted and cross-fade with the icon swap values.
                Image(systemName: "arrow.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                    .offset(y: hovering && !allDone ? 2 : 0)
                    .modifier(IconSwapEffect(shown: !allDone))
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.yellow)
                    .modifier(IconSwapEffect(shown: allDone))
            }
            .animation(Motion.icon, value: allDone)
            .frame(width: 64, height: 64)
            // A short staged entrance: title, then the line under it, ~100 ms apart. The old copy fades
            // out first, and each line sits in a ZStack so old and new overlap in place.
            ZStack {
                Text(allDone ? "All squished." : "Drop videos here")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .id("title-\(allDone)")
                    .transition(.stagedEnter(delay: 0.1, reduceMotion: reduceMotion))
            }
            ZStack {
                Text(allDone ? "Drop more whenever you're ready." : "MP4, MOV, MKV, WebM, GIF, ProRes. Anything ffmpeg can read. Folders too.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .id("line-\(allDone)")
                    .transition(.stagedEnter(delay: 0.2, reduceMotion: reduceMotion))
            }
            Button("Browse…") { store.presentOpenPanel() }
                .buttonStyle(MiniChipStyle(selected: false))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                .foregroundStyle(hovering ? Theme.secondary : Theme.faint)
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
        .onTapGesture { store.presentOpenPanel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Add videos")
        .accessibilityHint("Opens a file browser. You can also drop files or folders on the window.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.presentOpenPanel() }
    }
}

// MARK: - Job row

struct JobRow: View {
    @Environment(QueueStore.self) private var store
    let job: EncodeJob
    @State private var hovering = false
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                JobStatusGlyph(job: job)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        Text(job.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let custom = job.customSettings {
                            Text("Own settings")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Theme.lilac)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.lilac.opacity(0.16)))
                                .help(custom.summaryText)
                        }
                    }
                    JobStatusLine(job: job)
                }
                Spacer(minLength: 8)
                // Always in the layout so the name doesn't re-truncate on hover; they fade in instead.
                // Keyboard and VoiceOver users get the same actions from the row's accessibility actions.
                rowButtons
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                store.selectedJobID = job.id
                store.scheduleThumbnail()
                withAnimation(Motion.out(0.22)) { expanded.toggle() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(job.name)
            // In its own modifier so progress ticks re-evaluate only the value, not the whole row.
            .modifier(JobStatusAccessibilityValue(job: job))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(expanded ? "Hides details" : "Shows details")
            .accessibilityAction {
                store.selectedJobID = job.id
                store.scheduleThumbnail()
                withAnimation(Motion.out(0.22)) { expanded.toggle() }
            }
            .accessibilityAction(named: "Remove from queue") { store.remove(job) }
            .accessibilityAction(named: job.status == .done ? "Squish again" : "Try again") { store.retry(job) }
            .accessibilityAction(named: "Stop this file") { store.cancel(job) }
            .accessibilityAction(named: "Move to top") { store.move(job.id, before: store.jobs.first?.id) }
            .accessibilityAction(named: "Move to bottom") { store.move(job.id, before: nil) }
            .contextMenu { JobMenu(job: job) }

            if expanded {
                JobDetail(job: job)
                    .padding(.leading, 36)
                    .padding(.bottom, 10)
                    .transition(.reveal(reduceMotion: reduceMotion))
            }
        }
        .background {
            // Selection: what the live thumbnail and Space-to-preview follow.
            if store.selectedJobID == job.id && store.jobs.count > 1 {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.field)
                    .padding(.horizontal, -8)
            }
        }
        .onHover { h in withAnimation(Motion.hover) { hovering = h } }
    }

    private var rowButtons: some View {
        HStack(spacing: 6) {
            if job.canRunAgain && job.status != .ready {
                RowButton(symbol: "arrow.clockwise", help: retryHelp) { store.retry(job) }
            }
            if job.status == .encoding || job.status == .queued {
                RowButton(symbol: "stop.fill", help: "Stop this file") { store.cancel(job) }
            } else {
                RowButton(symbol: "xmark", help: "Remove from queue") { store.remove(job) }
            }
        }
    }

    private var retryHelp: String {
        job.status == .done ? "Squish again with the current settings" : "Try again"
    }
}

/// The status glyph for a row. Reads the job itself, so a progress tick redraws only this.
private struct JobStatusGlyph: View {
    let job: EncodeJob

    var body: some View {
        StatusGlyph(status: job.status, progress: job.progress).equatable()
    }
}

/// "Encoding…  42% · 1.8× · 0:31 left". The one line of a row that changes on every progress tick,
/// so it's its own view.
private struct JobStatusLine: View {
    let job: EncodeJob

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.verb(for: job))
                .foregroundStyle(Self.tint(for: job))
                .fontWeight(.medium)
            Text(Self.detail(for: job))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .modifier(ShimmerOnce(active: isBigWin && !job.hasCelebrated) { job.hasCelebrated = true })
        }
        .font(.system(size: 11.5).monospacedDigit())
    }

    /// Rare on purpose: only files that shrank by 90% or more.
    private var isBigWin: Bool { job.status == .done && (job.savings ?? 0) >= 0.9 }

    static func verb(for job: EncodeJob) -> String {
        switch job.status {
        case .probing: "Reading…"
        case .ready: "Ready"
        case .queued: "Queued"
        case .encoding: job.passCount > 1 ? "Pass \(job.pass) of \(job.passCount)…" : "Encoding…"
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        }
    }

    static func tint(for job: EncodeJob) -> Color {
        switch job.status {
        case .probing, .queued: Theme.orange
        case .ready: Theme.lilac
        case .encoding: Theme.yellowText
        case .done: Theme.green
        case .failed: Theme.red
        case .cancelled: Theme.secondary
        }
    }

    static func detail(for job: EncodeJob) -> String {
        switch job.status {
        case .probing:
            return "Taking a look at your file"
        case .ready, .queued, .cancelled:
            var parts: [String] = []
            if let media = job.media {
                parts.append("\(media.width)×\(media.height)")
                if let hdr = media.hdrFormat { parts.append(hdr) }
                if media.duration > 0 { parts.append(Format.duration(media.duration)) }
            }
            var size = Format.bytes(job.inputSize)
            if job.status == .ready {
                if let estimate = job.estimate, !job.isEstimating {
                    size += " → ≈ \(Format.bytes(estimate))"
                } else if job.isEstimating {
                    size += " → estimating…"
                }
            }
            parts.append(size)
            return parts.joined(separator: " · ")
        case .encoding:
            var parts = ["\(Int(job.progress * 100))%"]
            if let speed = job.encodeSpeed { parts.append(String(format: "%.1f×", speed)) }
            if let eta = job.eta { parts.append("\(Format.duration(eta)) left") }
            return parts.joined(separator: " · ")
        case .done:
            guard let out = job.outputSize else { return "" }
            var text = "\(Format.bytes(job.inputSize)) → \(Format.bytes(out))"
            if let saved = job.savings {
                text += saved >= 0 ? "  −\(Int((saved * 100).rounded()))%" : "  +\(Int((-saved * 100).rounded()))%"
            }
            return text
        case .failed:
            // The first line is the cause (FFmpegError puts it there).
            return job.message?.split(separator: "\n").first.map(String.init) ?? "Something went wrong"
        }
    }
}

/// The row's VoiceOver value ("Encoding…, 42% · 1.8×"), kept out of the row's own body.
private struct JobStatusAccessibilityValue: ViewModifier {
    let job: EncodeJob

    func body(content: Content) -> some View {
        content.accessibilityValue("\(JobStatusLine.verb(for: job)), \(JobStatusLine.detail(for: job))")
    }
}

struct JobDetail: View {
    @Environment(QueueStore.self) private var store
    let job: EncodeJob

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let media = job.media {
                DetailLine(label: "Source", value: media.summary)
                if media.hasAudio {
                    DetailLine(label: "Audio", value: "\(media.audioCodec?.uppercased() ?? "?") · \(media.audioChannels) ch · \(media.sampleRate / 1000) kHz")
                }
            }
            if let output = job.output {
                DetailLine(label: "Output", value: (output.path as NSString).abbreviatingWithTildeInPath)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                DetailLine(label: "Settings", value: job.customSettings.map { "Own · \($0.summaryText)" }
                           ?? "Shared · \(store.settings.summaryText)")
                Spacer(minLength: 4)
                if job.customSettings == nil {
                    Button("Pin to this file") { store.pinSettings(to: job) }
                        .buttonStyle(MiniChipStyle(selected: false))
                        .help("Freeze the current panel settings for this file, so later changes don't affect it")
                } else {
                    Button("Update") { store.pinSettings(to: job) }
                        .buttonStyle(MiniChipStyle(selected: false))
                        .help("Replace this file's settings with what's in the panel now")
                    Button("Use shared") { store.unpinSettings(from: job) }
                        .buttonStyle(MiniChipStyle(selected: false))
                        .help("Go back to following the settings panel")
                }
            }
            if job.status == .failed, let message = job.message {
                Text(message)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(job.warnings, id: \.self) { Note(text: $0) }
            HStack(spacing: 6) {
                if job.status == .failed || job.status == .cancelled {
                    Button("Try again") { store.retry(job) }
                        .buttonStyle(MiniChipStyle(selected: true))
                } else if job.status == .done {
                    Button("Squish again") { store.retry(job) }
                        .buttonStyle(MiniChipStyle(selected: true))
                        .help("Encode this file again with the current settings. The earlier file is kept.")
                }
                if job.media != nil && !store.isRunning && !store.effectiveSettings(for: job).container.isAudioOnly {
                    Button("Preview") { store.previewJob = job }
                        .buttonStyle(MiniChipStyle(selected: false))
                        .help("Compare a frame before and after with the current settings")
                }
                if job.status == .done, let output = job.output {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                        .buttonStyle(MiniChipStyle(selected: false))
                    Button("Open") { NSWorkspace.shared.open(output) }
                        .buttonStyle(MiniChipStyle(selected: false))
                }
                Button("Copy command") {
                    let command = job.command ?? store.plan(for: job).commandLine(binary: store.environment.ffmpeg?.path ?? "ffmpeg")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .buttonStyle(MiniChipStyle(selected: false))
            }
        }
    }
}

private struct DetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Status glyph

/// The dashed-ring status icons from the task list. Equatable on what it draws, so a row
/// redrawing for some other reason leaves it alone.
struct StatusGlyph: View, Equatable {
    let status: EncodeJob.Status
    let progress: Double
    @State private var squash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (a: StatusGlyph, b: StatusGlyph) -> Bool {
        a.status == b.status && a.progress == b.progress
    }

    /// Waiting states share one glyph, so Ready → Queued doesn't swap icons.
    private enum Kind { case waiting, encoding, done, failed, cancelled }

    private var kind: Kind {
        switch status {
        case .probing, .queued, .ready: .waiting
        case .encoding: .encoding
        case .done: .done
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    var body: some View {
        ZStack {
            glyph
                .id(kind)
                .transition(.iconSwap(reduceMotion: reduceMotion))
        }
        .frame(width: 26, height: 26)
        .scaleEffect(x: squash ? 1.2 : 1, y: squash ? 0.76 : 1, anchor: .bottom)
        .onChange(of: status) { _, new in
            // The name made literal: a quick squash as the check lands, then a springy recovery.
            guard new == .done, !reduceMotion else { return }
            withAnimation(Motion.out(0.09)) { squash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.6)) { squash = false }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .waiting:
            ZStack {
                WaitingRing(spinning: status != .ready && !reduceMotion)
                WaitingDots(animating: status != .ready && !reduceMotion)
            }
        case .encoding:
            ZStack {
                Circle().stroke(Theme.track, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Theme.yellow, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // ffmpeg reports about every half second; a linear glide that long reads as continuous.
                    .animation(reduceMotion ? Motion.out(0.3) : .linear(duration: 0.5), value: progress)
                PulseDot(animating: !reduceMotion)
            }
        case .done:
            ZStack {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 2.25, lineCap: .round, dash: [3, 4]))
                    .foregroundStyle(Theme.yellow)
                Circle().fill(Theme.yellow).padding(5)
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(.black)
            }
        case .failed:
            ZStack {
                Circle().fill(Theme.red.opacity(0.18))
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Theme.red)
            }
        case .cancelled:
            ZStack {
                Circle().fill(Theme.field)
                RoundedRectangle(cornerRadius: 2).fill(Theme.secondary).frame(width: 7.5, height: 7.5)
            }
        }
    }
}

/// Dashed ring that turns slowly (one turn every 5 s) while a file waits. A repeating rotation
/// rather than a clock, so nothing re-renders per frame; it starts whenever `spinning` does.
private struct WaitingRing: View {
    var spinning: Bool
    @State private var appeared = false

    var body: some View {
        Circle()
            .strokeBorder(style: StrokeStyle(lineWidth: 2.25, lineCap: .round, dash: [3, 4]))
            .foregroundStyle(Theme.secondary)
            .animation(spinning ? .linear(duration: 5).repeatForever(autoreverses: false) : nil) {
                $0.rotationEffect(.degrees(spinning && appeared ? 360 : 0))
            }
            .onAppear { appeared = true }
    }
}

/// The breathing dot in the middle of the encoding ring.
private struct PulseDot: View {
    var animating: Bool

    var body: some View {
        let dot = Circle().fill(Theme.yellow).frame(width: 6.5, height: 6.5)
        if animating {
            dot.phaseAnimator([0.6, 1]) { content, scale in
                content.scaleEffect(scale)
            } animation: { _ in .easeInOut(duration: 0.8) }
        } else {
            dot.scaleEffect(0.6)
        }
    }
}

// MARK: - Shimmer

/// One pass of light across the content, then it reports back so it never repeats.
struct ShimmerOnce: ViewModifier {
    var active: Bool
    var onFinish: () -> Void
    @State private var phase: CGFloat = -0.7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if active && !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Theme.yellow.opacity(0.9), .white, Theme.yellow.opacity(0.9), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(geo.size.width * 0.45, 40))
                            .offset(x: phase * geo.size.width)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.2).delay(0.35)) { phase = 1.1 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { onFinish() }
                    }
                }
            }
            .onAppear { if active && reduceMotion { onFinish() } }
    }
}

// MARK: - Row helpers

private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.field))
                // 30 × 40 pt hit area without changing layout; 3 pt sideways so neighbors (6 pt apart) never overlap.
                .padding(.horizontal, 3).padding(.vertical, 8)
                .contentShape(Rectangle())
                .padding(.horizontal, -3).padding(.vertical, -8)
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Right-click menu for a queue row.
private struct JobMenu: View {
    @Environment(QueueStore.self) private var store
    let job: EncodeJob

    var body: some View {
        if job.status == .failed || job.status == .cancelled {
            Button("Try Again") { store.retry(job) }
        } else if job.status == .done {
            Button("Squish Again") { store.retry(job) }
        }
        if job.status == .encoding || job.status == .queued {
            Button("Stop This File") { store.cancel(job) }
        }
        if job.status == .done, let output = job.output {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
        }
        Divider()
        if job.customSettings == nil {
            Button("Pin Current Settings to This File") { store.pinSettings(to: job) }
        } else {
            Button("Update Pinned Settings") { store.pinSettings(to: job) }
            Button("Use Shared Settings") { store.unpinSettings(from: job) }
            Button("Load Its Settings into the Panel") { store.settings = job.customSettings ?? store.settings }
        }
        Divider()
        Button("Move to Top") { store.move(job.id, before: store.jobs.first?.id) }
            .disabled(store.jobs.first?.id == job.id)
        Button("Move to Bottom") { store.move(job.id, before: nil) }
            .disabled(store.jobs.last?.id == job.id)
        Divider()
        Button("Remove from Queue", role: .destructive) { store.remove(job) }
            .disabled(job.status == .encoding)
    }
}

/// Three dots: all the same when a file is just sitting in the queue, a left-to-right
/// pulse while it's waiting on something (being read, or queued behind other files).
/// The row's one clock-driven view; the ring around it turns on a repeating animation.
private struct WaitingDots: View {
    var animating: Bool

    var body: some View {
        if animating {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                dots(phase: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            dots(phase: nil)
        }
    }

    private func dots(phase: Double?) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.text)
                    .opacity(brightness(dot: i, phase: phase))
                    .frame(width: 3.5, height: 3.5)
            }
        }
    }

    /// A soft bump that travels across the dots about once a second.
    private func brightness(dot: Int, phase: Double?) -> Double {
        guard let phase else { return 0.55 }
        let position = (phase * 2.4).truncatingRemainder(dividingBy: 3.6)
        let distance = abs(position - Double(dot) - 0.5)
        return 0.35 + 0.65 * max(0, 1 - distance)
    }
}
