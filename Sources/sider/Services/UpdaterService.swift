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

    /// nil in a build with no `SUPublicEDKey` — see `isConfigured`.
    let controller: SPUStandardUpdaterController?

    /// Whether this build can actually receive updates.
    ///
    /// A build with an empty `SUPublicEDKey` cannot verify a signature, so Sparkle refuses
    /// every update — correctly — and puts a **modal error alert** on screen saying so. On a
    /// released build that never happens (`scripts/release.sh` refuses to build without the
    /// key). On a local build it happens every launch, and that alert is not cosmetic: it is
    /// an app-modal window, so the panel stops opening and the whole app looks broken for a
    /// reason nothing on screen connects to the updater.
    static var isConfigured: Bool {
        let key = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private override init() {
        if Self.isConfigured {
            // startingUpdater: true → begins scheduled background checks immediately, per the
            // SUEnableAutomaticChecks / SUScheduledCheckInterval keys in Info.plist.
            controller = SPUStandardUpdaterController(startingUpdater: true,
                                                      updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        } else {
            controller = nil
            Logger.log("UpdaterService: no SUPublicEDKey — updates disabled for this build")
        }
        super.init()
    }

    /// User-initiated check ("Check for Updates…"). Shows Sparkle's UI even when already
    /// up to date, which a scheduled check deliberately does not.
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    var automaticChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
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
