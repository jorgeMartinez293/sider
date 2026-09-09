import AppKit
import SwiftUI

/// Hosts `SettingsView` in a normal window.
///
/// sider is an `LSUIElement` app, so it has no Dock tile and no menu bar of its own, and an
/// app in that state cannot bring a window forward on its own — `NSApp.activate` is required
/// or the settings window opens *behind* whatever the user was looking at. That is the whole
/// reason this is a controller rather than a `Settings` scene.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "sider Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
