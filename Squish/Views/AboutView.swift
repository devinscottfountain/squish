import AppKit
import SwiftUI

/// Credits, shown from Squish › About Squish and in Settings › About.
struct AboutView: View {
    /// Release builds ship license texts and source links in Contents/Resources/Licenses.
    static var licensesFolder: URL? {
        Bundle.main.url(forResource: "Licenses", withExtension: nil)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 116, height: 116)
                .shadow(color: Theme.orange.opacity(0.35), radius: 18, y: 8)
                .accessibilityHidden(true)

            Text("Squish")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.top, 10)
            Text(version)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .padding(.top, 2)
                .textSelection(.enabled)
            Text("Compress, convert and tidy up video, with ffmpeg doing the heavy lifting.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            VStack(spacing: 3) {
                Text("Designed & built by")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text("Devin Fountain")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 18)
            .accessibilityElement(children: .combine)

            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Text("Video engine:")
                    Link("FFmpeg", destination: URL(string: "https://ffmpeg.org")!)
                        .foregroundStyle(Theme.orange)
                }
                Text(Self.licensesFolder != nil
                     ? "Squish includes ffmpeg and its libraries under the GNU GPL v3, and is itself GPL v3. FFmpeg is a trademark of Fabrice Bellard."
                     : "Squish runs the copy of ffmpeg installed on this Mac. FFmpeg is a trademark of Fabrice Bellard.")
                Text("Symbols: SF Symbols by Apple.")
                if let licenses = Self.licensesFolder {
                    Button("Licenses") { NSWorkspace.shared.open(licenses) }
                        .buttonStyle(MiniChipStyle(selected: false))
                        .help("Squish's license, ffmpeg's and every bundled library's, with source links")
                        .padding(.top, 4)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)

            Text("© 2026 Devin Fountain")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 14)
        }
    }
}

/// Replaces the standard About menu item so it opens Squish's own About window.
struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Squish") { openWindow(id: "about") }
    }
}
