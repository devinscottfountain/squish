import Sparkle
import SwiftUI

/// In-app updates through Sparkle. Squish reads appcast.xml from the GitHub repo, and only installs
/// a download whose EdDSA signature matches `SUPublicEDKey` in Info.plist.
@MainActor @Observable
final class AppUpdater {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    /// False while a check is already running (Sparkle's own rule for enabling the menu item).
    private(set) var canCheck = false
    private(set) var lastChecked: Date?

    var checksAutomatically: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = checksAutomatically }
    }
    var installsAutomatically: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = installsAutomatically }
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        checksAutomatically = updater.automaticallyChecksForUpdates
        installsAutomatically = updater.automaticallyDownloadsUpdates
        lastChecked = updater.lastUpdateCheckDate
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheck = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                let value = updater.lastUpdateCheckDate
                Task { @MainActor in self?.lastChecked = value }
            },
        ]
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
