import ApplicationServices
import AppKit

/// Everything sider needs from the Accessibility API, in one typed layer.
///
/// The Accessibility API is the only public way to (a) see a window that is minimized —
/// `CGWindowListCopyWindowInfo` lists it but gives no handle you can act on — and (b) put it
/// back. Nothing here works until the user grants Accessibility in System Settings; every
/// call is written to fail quietly (returning nil / false) rather than trap, because an
/// un-granted or half-granted state is normal on first launch and after every reinstall.
enum AccessibilityBridge {

    // MARK: - Trust

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Registers sider in System Settings → Privacy → Accessibility and opens the system
    /// alert that links there. macOS only creates the list entry when an app first asks, so
    /// without this call there is no toggle for the user to flip.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - CGWindowID lookup

    /// `_AXUIElementGetWindow` maps an AXUIElement to the CGWindowID that
    /// `CGWindowListCopyWindowInfo` and ScreenCaptureKit speak. It is the only way to join
    /// the two worlds, and there is no public equivalent — every window manager on macOS
    /// (yabai, Amethyst, Rectangle) relies on it.
    ///
    /// Resolved with `dlsym` instead of being declared `extern`: an undefined private symbol
    /// at link time makes the binary fail to launch outright if Apple ever removes it,
    /// whereas a nil lookup here just degrades sider to "no thumbnails" and keeps the rest
    /// working.
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindow: GetWindowFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */,
                              "_AXUIElementGetWindow") else {
            Logger.log("AccessibilityBridge: _AXUIElementGetWindow unavailable — thumbnails disabled")
            return nil
        }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = getWindow else { return nil }
        var id: CGWindowID = 0
        return fn(element, &id) == .success && id != 0 ? id : nil
    }

    // MARK: - Attributes

    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue((value as! AXValue), .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue((value as! AXValue), .cgSize, &size) else { return nil }
        return size
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        copyAttribute(element, attribute) as? [AXUIElement] ?? []
    }

    // MARK: - Actions

    @discardableResult
    static func setMinimized(_ element: AXUIElement, _ minimized: Bool) -> Bool {
        AXUIElementSetAttributeValue(element,
                                     kAXMinimizedAttribute as CFString,
                                     minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    @discardableResult
    static func raise(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
    }

    /// Makes `element` the app's focused window. Raising alone leaves the previous window
    /// key inside the app, so a restored window can come forward without taking keystrokes.
    @discardableResult
    static func focus(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element,
                                     kAXMainAttribute as CFString,
                                     kCFBooleanTrue) == .success
    }

    @discardableResult
    static func setPosition(_ element: AXUIElement, _ origin: CGPoint) -> Bool {
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    // MARK: - Classification

    /// Whether a window is one the user thinks of as a window — something they can put away
    /// and come back to — as opposed to a sheet, a palette or a system dialog.
    ///
    /// Subrole alone is not enough, and assuming it was is a real bug this cost: **TextEdit
    /// reports its ordinary document windows as `AXDialog`**, not `AXStandardWindow`, so a
    /// filter that only accepted the latter silently dropped them from the panel. Plenty of
    /// apps are loose with subrole in the same way.
    ///
    /// The presence of a **minimize button** is the reliable test, because it is the same
    /// question restated: a window with one is a window macOS itself is willing to put in the
    /// Dock. Sheets, palettes and popovers do not have one. Subrole is kept as a fast path
    /// for the apps that do get it right.
    static func isMinimizableWindow(_ window: AXUIElement) -> Bool {
        guard string(window, kAXRoleAttribute) == kAXWindowRole as String else { return false }
        if string(window, kAXSubroleAttribute) == kAXStandardWindowSubrole as String { return true }
        return copyAttribute(window, kAXMinimizeButtonAttribute) != nil
    }

    // MARK: - Hit testing

    /// The window under a screen point, or nil.
    ///
    /// `point` is in **Accessibility coordinates**: origin at the top-left of the primary
    /// display, y growing downward. That is not what `NSEvent.mouseLocation` returns — use
    /// `axPoint(fromCocoa:)` to convert, or a hit test silently lands on the wrong half of
    /// the screen.
    static func window(at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }

        // The hit is usually a control inside the window (a title-bar button, a toolbar item),
        // not the window itself. Most elements expose their window directly.
        if let window = copyAttribute(hit, kAXWindowAttribute) {
            return (window as! AXUIElement)
        }
        // Otherwise walk up. Bounded, because a malformed hierarchy can contain a cycle and
        // an unbounded walk would hang the caller.
        var current = hit
        for _ in 0..<12 {
            if string(current, kAXRoleAttribute) == kAXWindowRole as String { return current }
            guard let parent = copyAttribute(current, kAXParentAttribute) else { return nil }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    /// System-wide element, kept alive and given the same short timeout as the per-app ones:
    /// a hit test reaches into whatever process owns the pixel under the pointer, and that
    /// process may be busy.
    private static let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }()

    /// Converts a Cocoa screen point (origin bottom-left of the primary display) to the
    /// top-left-origin coordinates the Accessibility and CoreGraphics APIs use.
    ///
    /// The flip is around the **primary** display's height, not the display the point is on —
    /// which is why a point on a screen positioned above the primary one correctly comes out
    /// with a negative y.
    static func axPoint(fromCocoa point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// The inverse of `axPoint(fromCocoa:)`.
    static func cocoaPoint(fromAX point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// The PID that owns `element`, or nil.
    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    // MARK: - Applications

    /// An app-level element with a short messaging timeout. The default is 6 seconds, and a
    /// beachballing app would otherwise freeze sider's scan (and, since the scan feeds the
    /// panel, the panel itself) for that long — once per window.
    static func application(pid: pid_t, timeout: Float = 0.25) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }
}
