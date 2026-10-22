import AppKit
import SwiftUI

/// The floating pill toolbar along the bottom of the window.
struct BottomToolbar: View {
    @Environment(QueueStore.self) private var store
    @Binding var showCommand: Bool

    var body: some View {
        HStack(spacing: 10) {
            PillGroup {
                ToolButton(symbol: "plus", help: "Add videos (⌘O)") { store.presentOpenPanel() }
                ToolButton(symbol: "folder", help: "Choose output folder") { store.chooseOutputFolder() }
                Rectangle().fill(Theme.divider).frame(width: 1, height: 22)
                ToolButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Show the ffmpeg command", active: showCommand) {
                    showCommand.toggle()
                }
            }
            StatsPill()
            StartButton()
        }
    }
}

struct PillGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) { content }
            .padding(6)
            .glass(in: Capsule())
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }
}

struct ToolButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Theme.text : Theme.secondary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(active || hovering ? Theme.field : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
        .onHover { hovering = $0 }
    }
}

/// "4 files  1.2 GB → 240 MB  −80%", after the "4 files +232 −17" pill.
struct StatsPill: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        let jobs = store.jobs
        let done = jobs.filter { $0.status == .done }
        let inputTotal = jobs.reduce(Int64(0)) { $0 + $1.inputSize }
        let doneIn = done.reduce(Int64(0)) { $0 + $1.inputSize }
        let doneOut = done.reduce(Int64(0)) { $0 + ($1.outputSize ?? 0) }

        HStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.indigo)
            Text(jobs.count == 1 ? "1 file" : "\(jobs.count) files")
                .foregroundStyle(Theme.text)
            if doneIn > 0 {
                Text(Format.bytes(doneIn)).foregroundStyle(Theme.secondary)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                CountUpText(value: Double(doneOut)) { Format.bytes(Int64($0)) }
                    .foregroundStyle(Theme.green)
                let saved = 1 - Double(doneOut) / Double(doneIn)
                CountUpText(value: saved * 100) { $0 >= 0 ? "−\(Int($0.rounded()))%" : "+\(Int((-$0).rounded()))%" }
                    .foregroundStyle(saved >= 0 ? Theme.green : Theme.red)
            } else if inputTotal > 0 {
                Text(Format.bytes(inputTotal)).foregroundStyle(Theme.secondary)
                let pending = jobs.filter { $0.status == .ready }
                if !pending.isEmpty, pending.allSatisfy({ $0.estimate != nil && !$0.isEstimating }) {
                    let estimate = pending.reduce(Int64(0)) { $0 + ($1.estimate ?? 0) }
                    let pendingIn = pending.reduce(Int64(0)) { $0 + $1.inputSize }
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.tertiary)
                    Text("≈ \(Format.bytes(estimate))").foregroundStyle(Theme.green.opacity(0.75))
                        .help("Estimated from a short sample encode with the current settings")
                    if pendingIn > 0 {
                        let saved = 1 - Double(estimate) / Double(pendingIn)
                        Text(saved >= 0 ? "−\(Int((saved * 100).rounded()))%" : "+\(Int((-saved * 100).rounded()))%")
                            .foregroundStyle((saved >= 0 ? Theme.green : Theme.red).opacity(0.75))
                    }
                }
            }
        }
        .font(.system(size: 14, weight: .medium).monospacedDigit())
        .accessibilityElement(children: .combine)
        .help(store.lifetimeFiles > 0
              ? "You've saved \(Format.bytes(store.lifetimeSavedBytes)) across \(store.lifetimeFiles) \(store.lifetimeFiles == 1 ? "file" : "files") with Squish"
              : "Savings show up here as files finish")
        .padding(.horizontal, 18)
        .frame(height: 50)
        .glass(in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
    }
}

struct StartButton: View {
    @Environment(QueueStore.self) private var store
    @State private var hovering = false

    var body: some View {
        let running = store.isRunning
        let count = store.startableCount
        let problem = store.startProblem
        let enabled = running || (count > 0 && store.environment.isAvailable)

        Button {
            running ? store.stop() : store.start(only: nil)
        } label: {
            HStack(spacing: 8) {
                // Play ⇄ stop is a contextual icon swap; the label crossfades with a short blur.
                ZStack {
                    Image(systemName: running ? "stop.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .id(running)
                        .transition(.iconSwap)
                }
                ZStack {
                    Text(running ? "Stop" : (store.startRunsAgain ? "Squish again" : "Squish"))
                        .font(.system(size: 14, weight: .semibold))
                        .id("\(running)-\(store.startRunsAgain)")
                        .transition(.blurFade)
                }
                if !running && count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.2)))
                }
            }
            .foregroundStyle(running ? Theme.red : .white)
            // Optical balance: the icon side gets 2 pt less padding than the text side.
            .padding(.leading, 18)
            .padding(.trailing, 20)
            .frame(height: 50)
            .contentShape(Capsule())
            // The main action is solid orange in both modes (a glass tint washes out in light mode);
            // while running it becomes plain glass so Stop reads as secondary.
            .background {
                if !running {
                    Capsule().fill(LinearGradient(colors: [Theme.orange.opacity(0.92), Theme.orange],
                                                  startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay { if !running { Capsule().strokeBorder(Theme.glassEdge, lineWidth: 1) } }
            .modifier(GlassWhenRunning(running: running))
            .brightness(hovering && enabled ? 0.05 : 0)
            .shadow(color: (running ? Color.black : Theme.orange).opacity(0.35), radius: 16, y: 8)
            .animation(Motion.icon, value: running)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .keyboardShortcut(.return, modifiers: .command)
        .help(running ? "Stop encoding" : (problem ?? (store.startRunsAgain
            ? "Encode the finished files again with the current settings. Earlier files are kept (⌘↩)"
            : "Start encoding (⌘↩)")))
    }
}

// MARK: - Command sheet

struct CommandSheet: View {
    @Environment(QueueStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var copied = false

    var body: some View {
        let job = store.jobs.first { $0.id == selectedID } ?? store.jobs.first
        let plan = store.plan(for: job)
        let command = plan.commandLine(binary: store.environment.ffmpeg?.path ?? "ffmpeg")

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ffmpeg command")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(plan.passes.count > 1 ? "Two-pass encode, run in order" : "Exactly what Squish will run")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                if store.jobs.count > 1 {
                    PillMenu(selection: Binding(get: { job?.id ?? UUID() }, set: { selectedID = $0 }),
                             options: store.jobs.map(\.id)) { id in store.jobs.first { $0.id == id }?.name ?? "" }
                }
            }

            ScrollView {
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(minHeight: 140, maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))

            if job == nil {
                Note(text: "No files in the queue, so this uses a placeholder path and can't account for the source's duration, size or alpha.",
                     tint: Theme.lilac, symbol: "info.circle.fill")
            }
            ForEach(plan.warnings, id: \.self) { Note(text: $0) }

            HStack {
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                }
                .buttonStyle(MiniChipStyle(selected: copied))
                Button("Done") { dismiss() }
                    .buttonStyle(MiniChipStyle(selected: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 640)
        .presentationBackground(.thinMaterial)
        .preferredColorScheme(store.appearance.colorScheme)
    }
}

// MARK: - Count-up

/// A number that rolls up to its new value instead of jumping.
struct CountUpText: View {
    let value: Double
    let format: (Double) -> String
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CountingText(value: shown, format: format)
            // No count-up when the window first opens; only real changes roll.
            .onAppear { shown = value }
            .onChange(of: value) { roll(to: value) }
            .accessibilityLabel(format(value))
    }

    private func roll(to target: Double) {
        if reduceMotion {
            shown = target
        } else {
            withAnimation(.easeOut(duration: 0.9)) { shown = target }
        }
    }
}

private struct CountingText: View, Animatable {
    var value: Double
    let format: (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(format(value)) }
}

// MARK: - Blur crossfade

private struct BlurFade: ViewModifier {
    var amount: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: amount).opacity(amount == 0 ? 1 : 0)
    }
}

extension AnyTransition {
    /// Crossfade with a slight blur, so a label change reads as one thing morphing.
    static let blurFade = AnyTransition.modifier(active: BlurFade(amount: 4), identity: BlurFade(amount: 0))
}

/// Plain glass behind the Start button only while it shows Stop.
private struct GlassWhenRunning: ViewModifier {
    var running: Bool

    func body(content: Content) -> some View {
        if running {
            content.glass(in: Capsule(), interactive: true)
        } else {
            content
        }
    }
}
