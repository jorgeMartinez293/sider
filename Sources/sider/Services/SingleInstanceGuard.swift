import AppKit

/// Stops sider from running twice. Two copies mean two edge panels fighting over the same
/// strip of screen, two global hot-key registrations (the second silently fails) and two
/// thumbnail capture loops paying the CPU cost.
///
/// This is possible at all because of the keep-alive LaunchAgent (see `LoginItemService`):
/// launchd `exec`s the binary directly instead of going through LaunchServices, so it does
/// NOT get the usual "already running, just activate it" behaviour.
enum SingleInstanceGuard {
    /// Label of the keep-alive job — launchd exports it as `XPC_SERVICE_NAME` in the
    /// environment of the process it starts, which is how a copy knows it is the managed one.
    static let agentLabel = "com.jorge.sider.keepalive"

    /// True when launchd started this process from the keep-alive agent. That copy is the
    /// durable one (it is the one restarted after a crash), so it never yields.
    static var isManagedByLaunchd: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == agentLabel
    }

    /// Whether this process should quit immediately because an equivalent copy is already up.
    ///
    /// Deliberately narrow: only another instance of the *same bundle on disk* counts, so a
    /// dev build run from the project folder can still start while the installed
    /// /Applications copy runs — that is the normal way to test a change.
    static func shouldYieldToRunningInstance() -> Bool {
        guard !isManagedByLaunchd else { return false }
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains {
            $0.processIdentifier != me
                && $0.bundleURL?.resolvingSymlinksInPath().path == path
        }
    }
}
