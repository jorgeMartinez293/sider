import AppKit
import Carbon.HIToolbox

/// Sends a keyboard shortcut to one application.
///
/// Used for ⌘W, because pressing a window's `AXCloseButton` is not universal: apps that draw
/// their own title bar — Electron shells like Discord among them — expose the button and then
/// do nothing when it is pressed. Every app handles ⌘W, because it is a menu item rather than
/// a control.
enum KeyStroke {

    /// Sends ⌘W to `pid`.
    ///
    /// `postToPid` rather than posting to the HID tap: a tap event goes wherever the keyboard
    /// focus happens to be at that instant, so a mistimed one closes a window in a completely
    /// different application. Addressed to a process, the worst case is that nothing happens.
    ///
    /// Requires Accessibility, which sider already needs for everything else.
    static func commandW(to pid: pid_t) {
        // A dedicated event source, not .hidSystemState: the latter merges in the real
        // keyboard's modifier state, so a Command still physically held down from the click
        // that started this would arrive doubled.
        let source = CGEventSource(stateID: .privateState)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_W), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_W), keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }
}
