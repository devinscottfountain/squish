import AppKit
import SwiftUI

/// Squish › Settings… (⌘,): app-wide preferences, ffmpeg, and credits.
struct SettingsWindow: View {
    private enum Tab: Hashable { case general, ffmpeg, about }
    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            FFmpegSettings()
                .tabItem { Label("ffmpeg", systemImage: "terminal") }
                .tag(Tab.ffmpeg)
            AboutView()
                .padding(28)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 500)
        .tint(Theme.orange)
        .preferredColorScheme(.dark)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(QueueStore.self) private var store
    @State private var confirmingReset = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Play the finish sound", isOn: $store.playSounds)
                HStack {
                    Text("Plays once per batch and follows your Mac's \u{201C}Play user interface sound effects\u{201D} setting.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Preview") { Delight.playFinishSound(enabled: true) }
                }
            } header: {
                Text("When a batch finishes")
            }

            Section {
                Picker("Files at once", selection: $store.concurrentJobs) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                Text("One at a time is fastest overall: each encode already uses every core. More can help with lots of very short clips.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Encoding")
            }

            Section {
                LabeledContent("Space saved", value: Format.bytes(store.lifetimeSavedBytes))
                LabeledContent("Files squished", value: "\(store.lifetimeFiles)")
                HStack {
                    Spacer()
                    Button("Reset Totals…") { confirmingReset = true }
                        .disabled(store.lifetimeFiles == 0)
                }
            } header: {
                Text("Lifetime")
            }

            Section {
                Text("Your queue is saved when you quit and comes back next time. Files that were moved or deleted are skipped.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Queue")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset lifetime totals?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { store.resetLifetimeTotals() }
        } message: {
            Text("This only clears the counters. Your files aren't touched.")
        }
    }
}

// MARK: - ffmpeg

private struct FFmpegSettings: View {
    @Environment(QueueStore.self) private var store

    private struct Capability: Identifiable {
        let name: String
        let detail: String
        let available: Bool
        var id: String { name }
    }

    var body: some View {
        let env = store.environment
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(env.isAvailable ? Theme.green : Theme.red).frame(width: 8, height: 8)
                        Text(env.isChecking ? "Checking…" : (env.isAvailable ? "ffmpeg \(env.version ?? "") · \(env.source)\(env.isTranslated ? " · Intel (Rosetta)" : "")" : "Not found"))
                    }
                }
                LabeledContent("Location") {
                    Text(env.ffmpeg.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "—")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Choose…") { store.locateFFmpeg() }
                    Button("Use Default") {
                        Task {
                            await env.useDefaultBinary()
                            store.reprobeAll()
                        }
                    }
                    .disabled(!env.hasCustomBinary)
                    Spacer()
                    if let url = env.ffmpeg {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Button("Check Again") {
                        Task {
                            await env.refresh()
                            store.reprobeAll()
                        }
                    }
                }
            } header: {
                Text("ffmpeg")
            } footer: {
                if env.isTranslated {
                    Text("This ffmpeg is an Intel build running under Rosetta, so it's several times slower. Install the Apple silicon version with Homebrew in /opt/homebrew: brew install ffmpeg")
                        .foregroundStyle(Theme.yellow)
                        .textSelection(.enabled)
                } else if !env.isAvailable {
                    Text("Install it with Homebrew: brew install ffmpeg")
                        .textSelection(.enabled)
                }
            }

            Section {
                ForEach(capabilities(env)) { item in
                    LabeledContent {
                        Image(systemName: item.available ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(item.available ? Theme.green : Theme.tertiary)
                            .accessibilityLabel(item.available ? "Available" : "Not available")
                    } label: {
                        Text(item.name)
                        Text(item.detail)
                    }
                }
            } header: {
                Text("What this build can make")
            } footer: {
                Text("Squish dims any format that needs something this ffmpeg is missing.")
            }
        }
        .formStyle(.grouped)
    }

    private func capabilities(_ env: FFmpegEnvironment) -> [Capability] {
        let hdr = env.supports(filter: "zscale") ? "zscale + tonemap" : (env.supports(filter: "scale_vt") ? "VideoToolbox" : "not available")
        return [
            Capability(name: "H.264", detail: "libx264", available: env.supports("libx264")),
            Capability(name: "HEVC", detail: "libx265", available: env.supports("libx265")),
            Capability(name: "AV1", detail: "SVT-AV1 or libaom", available: env.supports("libsvtav1") || env.supports("libaom-av1")),
            Capability(name: "VP9 and WebM", detail: "libvpx", available: env.supports("libvpx-vp9")),
            Capability(name: "WebP", detail: "libwebp", available: env.supports("libwebp_anim") || env.supports("libwebp")),
            Capability(name: "Opus audio", detail: "libopus", available: env.supports("libopus")),
            Capability(name: "MP3 audio", detail: "LAME", available: env.supports("libmp3lame")),
            Capability(name: "Hardware encoding", detail: "VideoToolbox", available: env.supports("h264_videotoolbox")),
            Capability(name: "HDR to SDR", detail: hdr, available: env.supports(filter: "zscale") || env.supports(filter: "scale_vt")),
        ]
    }
}
