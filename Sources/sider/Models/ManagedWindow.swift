import AppKit
import ApplicationServices

/// One window sider knows about, joined from its two representations: the Accessibility
/// element (what can be minimized, restored and raised) and the CGWindowID (what can be
/// captured as an image). A window with no CGWindowID still works — it just never gets a
/// thumbnail and falls back to its app icon.
struct ManagedWindow: Identifiable, Equatable {

    /// Stable across a scan even when the CGWindowID is unavailable, so SwiftUI does not
    /// recycle a card onto a different window mid-animation.
    let id: String

    let element: AXUIElement
    let windowID: CGWindowID?
    let pid: pid_t

    var title: String
    var appName: String
    var bundleIdentifier: String?
    var isMinimized: Bool

    /// Screen frame in Cocoa coordinates while the window is on screen. Used only to keep a
    /// card's aspect ratio right when there is no thumbnail yet.
    var frame: CGRect

    /// The window's app icon, used as the card's badge and as the fallback art.
    var appIcon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    /// What the card shows as its caption. Plenty of windows have an empty AXTitle (an
    /// untitled document, a browser tab that has not settled), and a blank line reads as a
    /// bug — fall back to the app.
    var displayTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? appName : title
    }

    static func == (lhs: ManagedWindow, rhs: ManagedWindow) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.isMinimized == rhs.isMinimized
            && lhs.frame == rhs.frame
    }
}
