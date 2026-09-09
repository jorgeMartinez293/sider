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
