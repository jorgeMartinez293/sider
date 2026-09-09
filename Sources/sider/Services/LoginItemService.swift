import AppKit
import Foundation
import ServiceManagement

/// Keeps sider running: at login, after a reboot, and after a crash.
///
/// Two mechanisms, in order of preference:
///
///  1. The bundled LaunchAgent (`Contents/Library/LaunchAgents/com.jorge.sider.keepalive.plist`,
///     registered with `SMAppService.agent`). It starts sider at login AND, thanks to
///     `KeepAlive/SuccessfulExit=false`, restarts it whenever the process dies from a crash
///     or any non-zero exit — while leaving a clean exit alone, so "Quit sider" still quits.
///  2. `SMAppService.mainApp` (a plain login item) as a fallback, for builds where the agent
///     cannot be registered — an ad-hoc/unsigned dev build, or a bundle missing the plist.
///     That one relaunches at login only; a crash leaves the app down until the next login.
///
/// Never both: at login each would start its own copy.
final class LoginItemService {
    static let shared = LoginItemService()

    /// Must match the plist's `Label` and its filename inside `Contents/Library/LaunchAgents`.
    private static let agentPlistName = "com.jorge.sider.keepalive.plist"

    private init() {}

    /// Reconciles both registrations with `enabled`, and is a no-op when they already match.
    /// Call once at launch so the persisted setting survives the user removing sider by hand
    /// in System Settings → General → Login Items (which `SMAppService.status` reflects).
    func apply(enabled: Bool) {
        let agent = SMAppService.agent(plistName: Self.agentPlistName)
        let loginItem = SMAppService.mainApp

        guard enabled else {
            unregister(agent, label: "keep-alive agent")
            unregister(loginItem, label: "login item")
            return
        }

        let agentWasRegistered = agent.status == .enabled
        if register(agent, label: "keep-alive agent") {
            // The agent now owns launch-at-login; a login item on top of it would open a
            // second sider at every login. Drop it (no-op if it was never registered).
            unregister(loginItem, label: "login item")
            if !agentWasRegistered { handOverToManagedInstance() }
        } else {
            // No agent (unsigned build, plist missing from the bundle…): at least come back
            // at the next login.
            _ = register(loginItem, label: "login item")
        }
    }

    /// Registering the agent LOADS it, and `RunAtLoad` immediately starts a second,
    /// launchd-owned sider next to this one. That happens exactly once per install (the
    /// first launch of a build that has the agent, e.g. right after an update), and the copy
    /// that should survive is launchd's, because that is the one it will restart after a
    /// crash. So this one steps aside. `SingleInstanceGuard` covers the mirror case, a manual
    /// launch arriving while the managed copy is already up.
    private func handOverToManagedInstance() {
        guard !SingleInstanceGuard.isManagedByLaunchd else { return }
        Logger.log("LoginItemService: keep-alive agent registered — handing over to the managed instance")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSApp.terminate(nil)
        }
    }

    /// Whether launch-at-login is currently in effect, by either mechanism. Read back from
    /// the system rather than from the stored preference so the Settings toggle reflects what
    /// the user may have changed in System Settings.
    var isEnabled: Bool {
        let agent = SMAppService.agent(plistName: Self.agentPlistName)
        return agent.status == .enabled || SMAppService.mainApp.status == .enabled
    }

    /// Registers `service` unless it already is, returning whether it ended up registered.
    /// `.requiresApproval` counts as success: the registration exists, the user just has to
    /// flip it on in System Settings, and re-registering would not help.
    @discardableResult
    private func register(_ service: SMAppService, label: String) -> Bool {
        switch service.status {
        case .enabled:
            return true
        case .requiresApproval:
            Logger.log("LoginItemService: \(label) awaits approval in System Settings")
            return true
        default:
            do {
                try service.register()
                return true
            } catch {
                Logger.log("LoginItemService: failed to register \(label): \(error)")
                return false
            }
        }
    }

    private func unregister(_ service: SMAppService, label: String) {
        guard service.status == .enabled || service.status == .requiresApproval else { return }
        do {
            try service.unregister()
        } catch {
            Logger.log("LoginItemService: failed to unregister \(label): \(error)")
        }
    }
}
