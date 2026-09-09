import Foundation
import Sparkle

/// Thin wrapper over Sparkle's `SPUStandardUpdaterController`. Reads its whole configuration
/// (feed URL, public EdDSA key, automatic-check cadence) from Info.plist, so having updates
/// managed needs nothing beyond touching `.shared` once at launch.
///
/// Updates are hosted as GitHub Release assets (.zip + .delta) with the appcast on GitHub
/// Pages; Sparkle verifies every download against `SUPublicEDKey` before installing anything.
/// See docs/DISTRIBUTION.md.
final class UpdaterService: NSObject, ObservableObject {
    static let shared = UpdaterService()

    let controller: SPUStandardUpdaterController

    private override init() {
        // startingUpdater: true → begins scheduled background checks immediately, per the
        // SUEnableAutomaticChecks / SUScheduledCheckInterval keys in Info.plist.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        super.init()
    }

    /// User-initiated check ("Check for Updates…"). Shows Sparkle's UI even when already
    /// up to date, which a scheduled check deliberately does not.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// User-facing version (CFBundleShortVersionString), shown in Settings.
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Build number (CFBundleVersion) — what Sparkle actually compares between releases.
    var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}
