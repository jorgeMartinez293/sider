import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController!
    private var panel: SiderPanelController!
    private let hover = EdgeHoverMonitor()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Touching `.shared` starts Sparkle's scheduled checks; nothing else is needed for
        // updates to be managed.
        _ = UpdaterService.shared
        LoginItemService.shared.apply(enabled: Preferences.shared.launchAtLogin)

        panel = SiderPanelController()
        menuBar = MenuBarController()
        menuBar.onTogglePanel = { [weak self] in self?.panel.toggle() }

        // After a click on a card the pointer is left sitting exactly where that card was,
        // which on a narrow panel is inside the hot zone — without this the panel reopens the
        // moment it finishes closing.
        panel.onDismissAfterAction = { [weak self] in self?.hover.suspend(for: 0.6) }

        hover.panelFrame = { [weak self] in self?.panel.visibleFrame }
        hover.onTrigger = { [weak self] screen in self?.panel.show(on: screen) }
        hover.onLeave = { [weak self] in self?.panel.hide() }
        hover.start()

        WindowRegistry.shared.start()
        ThumbnailService.shared.start()
        HotKeyManager.shared.onTrigger = { [weak self] in self?.panel.toggle() }
        HotKeyManager.shared.apply(enabled: Preferences.shared.hotKeyEnabled)

        // Changing what the panel collects, or how wide a card is, changes the scan result
        // and the window geometry — recompute rather than wait for the next poll.
        Preferences.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { WindowRegistry.shared.refresh() }
            .store(in: &cancellables)

        // Thumbnails for windows that no longer exist are dead weight. Pruning against the
        // live set every so often is far simpler than trying to catch every close.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            let live = Set(WindowRegistry.shared.windows.compactMap(\.windowID))
            guard !live.isEmpty else { return }
            ThumbnailService.shared.prune(keeping: live)
        }

        if !Preferences.shared.hasCompletedWelcome {
            WelcomeWindowController.shared.show()
        } else if !AccessibilityBridge.isTrusted {
            // A permission the user revoked, or a fresh install of a new build that macOS
            // treats as a different binary. Same window, same explanation.
            WelcomeWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hover.stop()
        HotKeyManager.shared.unregister()
    }

    /// Reopening from Finder while sider is already running (its only visible surface is the
    /// menu bar, so this is the obvious thing for a user to try when they want to find it).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }
}
