import AppKit

/// The menu bar item. sider has no Dock tile (`LSUIElement`), so this is the only place a
/// user can reach Settings, force the panel open, or quit — it is not optional chrome.
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    var onTogglePanel: (() -> Void)?

    override init() {
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.leadinghalf.inset.filled",
                                   accessibilityDescription: "sider")
            button.image?.isTemplate = true
            button.toolTip = "sider — your minimized windows, on the left edge"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Show Panel", action: #selector(togglePanel), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit sider", action: #selector(quit), keyEquivalent: "q")
            .target = self
        statusItem.menu = menu
    }

    @objc private func togglePanel() { onTogglePanel?() }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func checkForUpdates() { UpdaterService.shared.checkForUpdates() }

    /// `NSApp.terminate` exits with status 0, which is what tells the keep-alive LaunchAgent
    /// (`SuccessfulExit=false`) *not* to bring sider back. Quitting any other way — or
    /// crashing — is exactly the case the agent exists for.
    @objc private func quit() { NSApp.terminate(nil) }
}
