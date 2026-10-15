import AppKit
import SwiftUI

struct HeaderBar: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            AppGlyph(size: 30)
            Text(store.isRunning ? "Squish is working…" : "Squish is idle..")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .contentTransition(.opacity)
            Spacer()
            FFmpegStatusPill()
        }
        .padding(.leading, 4)
    }
}

struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [Theme.orange, Color(hex: "#E8402A")], startPoint: .top, endPoint: .bottom))
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(Theme.yellow)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.orange.opacity(0.35), radius: 8, y: 3)
    }
}

struct FFmpegStatusPill: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        let env = store.environment
        HStack(spacing: 7) {
            Circle()
                .fill(env.isAvailable ? Theme.green : Theme.red)
                .frame(width: 7, height: 7)
            if env.isChecking {
                Text("Looking for ffmpeg…")
            } else if env.isAvailable {
                Text("ffmpeg \(env.version ?? "")")
            } else {
                Text("ffmpeg not found")
                Button("Locate…") { store.locateFFmpeg() }
                    .buttonStyle(MiniChipStyle(selected: false))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.stroke))
        .help(env.ffmpeg?.path ?? "Install with: brew install ffmpeg")
    }
}

// MARK: - Queue card

struct QueueCard: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        Card {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(store.isRunning ? "Squishing" : "Queue")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    if store.hasFinished && !store.isRunning {
                        Button("Clear done") { store.clearFinished() }
                            .buttonStyle(MiniChipStyle(selected: false))
                    }
                    Text(store.jobs.count == 1 ? "1 task" : "\(store.jobs.count) tasks")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)

                if !store.environment.isAvailable && !store.environment.isChecking {
                    InstallBanner().padding(.horizontal, 16).padding(.bottom, 8)
                }

                if store.jobs.isEmpty {
                    DropZone().padding(16)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.jobs) { job in
                                JobRow(job: job)
                                if job.id != store.jobs.last?.id {
                                    Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 56)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 40)
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

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [4, 5]))
                    .foregroundStyle(Theme.tertiary)
                    .rotationEffect(.degrees(hovering ? 45 : 0))
                Image(systemName: "arrow.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                    .offset(y: hovering ? 2 : 0)
            }
            .frame(width: 64, height: 64)
            Text("Drop videos here")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("MP4, MOV, MKV, WebM, GIF, ProRes. Anything ffmpeg can read. Folders too.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button("Browse…") { store.presentOpenPanel() }
                .buttonStyle(MiniChipStyle(selected: false))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                .foregroundStyle(hovering ? Theme.secondary : Color.white.opacity(0.12))
        )
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.snappy) { hovering = h } }
        .onTapGesture { store.presentOpenPanel() }
    }
}

// MARK: - Job row

struct JobRow: View {
    @Environment(QueueStore.self) private var store
    let job: EncodeJob
    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                StatusGlyph(status: job.status, progress: job.progress)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text(verb)
                            .foregroundStyle(tint)
                            .fontWeight(.medium)
                        Text(detail)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: 13).monospacedDigit())
                }
                Spacer(minLength: 8)
                if hovering && job.status != .encoding {
                    Button { store.remove(job) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Theme.field))
                    }
                    .buttonStyle(.plain)
                    .help("Remove from queue")
                    .transition(.opacity)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } }

            if expanded {
                JobDetail(job: job)
                    .padding(.leading, 46)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    private var verb: String {
        switch job.status {
        case .probing: "Reading.."
        case .ready: "Ready"
        case .queued: "Queued.."
        case .encoding: job.passCount > 1 ? "Pass \(job.pass)/\(job.passCount).." : "Encoding.."
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        }
    }

    private var tint: Color {
        switch job.status {
        case .probing, .queued: Theme.orange
        case .ready: Theme.lilac
        case .encoding: Theme.yellow
        case .done: Theme.green
        case .failed: Theme.red
        case .cancelled: Theme.secondary
        }
    }

    private var detail: String {
        switch job.status {
        case .probing:
            return "Taking a look at your file"
        case .ready, .queued, .cancelled:
            var parts: [String] = []
            if let media = job.media {
                parts.append("\(media.width)×\(media.height)")
                if media.duration > 0 { parts.append(Format.duration(media.duration)) }
            }
            parts.append(Format.bytes(job.inputSize))
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
            return job.message?.split(separator: "\n").last.map(String.init) ?? "Something went wrong"
        }
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
            if job.status == .failed, let message = job.message {
                Text(message)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(job.warnings, id: \.self) { Note(text: $0) }
            HStack(spacing: 6) {
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

/// The dashed-ring status icons from the task list.
struct StatusGlyph: View {
    let status: EncodeJob.Status
    let progress: Double
    @State private var spin = false

    var body: some View {
        ZStack {
            switch status {
            case .probing, .queued, .ready:
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [3.5, 5]))
                    .foregroundStyle(Theme.secondary)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(status == .ready ? .default : .linear(duration: 5).repeatForever(autoreverses: false), value: spin)
                HStack(spacing: 2.5) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(i == 2 ? Theme.text : Theme.secondary)
                            .frame(width: 4, height: 4)
                    }
                }
            case .encoding:
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Theme.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: progress)
                Circle()
                    .fill(Theme.yellow)
                    .frame(width: 8, height: 8)
                    .scaleEffect(spin ? 1 : 0.6)
                    .animation(.easeInOut(duration: 0.8).repeatForever(), value: spin)
            case .done:
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [3.5, 5]))
                    .foregroundStyle(Theme.yellow)
                Circle()
                    .fill(Theme.yellow)
                    .padding(6)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.black)
            case .failed:
                Circle().fill(Theme.red.opacity(0.18))
                Image(systemName: "exclamationmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Theme.red)
            case .cancelled:
                Circle().fill(Theme.field)
                RoundedRectangle(cornerRadius: 2).fill(Theme.secondary).frame(width: 9, height: 9)
            }
        }
        .frame(width: 32, height: 32)
        .onAppear { spin = true }
    }
}
