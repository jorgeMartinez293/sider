import AppKit
import ApplicationServices
import Combine

/// The list of windows the panel shows, kept current.
///
/// Two sources feed it, on purpose:
///
///  * **Events** — `NSWorkspace` notifications for apps coming and going, and a per-app
///    `AXObserver` for windows being minimized, restored, created or destroyed. This is what
///    makes the panel react the instant you minimize something.
///  * **A slow poll** — a full rescan on a timer. Every AX event source has holes: some apps
///    (Electron shells, anything drawing its own title bar) post nothing when a window is
///    miniaturized, an observer silently stops delivering when its app is relaunched under
///    the same PID, and a window that changes title never announces it. A registry that only
///    listened to events would drift and quietly show stale cards, which is worse than a
///    little idle CPU.
///
/// Scans run off the main thread: `AXUIElementCopyAttributeValue` is a synchronous IPC round
/// trip into another process, and a beachballing app would otherwise stall the UI. The
/// messaging timeout in `AccessibilityBridge.application(pid:)` caps how bad that can get.
final class WindowRegistry: ObservableObject {
    static let shared = WindowRegistry()

    /// Sorted for display: most recently minimized first, so the window you just put away is
    /// the one nearest the top of the panel.
    @Published private(set) var windows: [ManagedWindow] = []

    /// Set when a scan found nothing because Accessibility is not granted. The panel shows a
    /// "grant permission" card instead of an empty state, which would look broken.
    @Published private(set) var needsAccessibility = false

    private let scanQueue = DispatchQueue(label: "com.jorge.sider.scan", qos: .userInitiated)
    private var observers: [pid_t: AXObserver] = [:]
    private var pollTimer: Timer?
    private var refreshWorkItem: DispatchWorkItem?
    private var started = false

    /// When each window was last seen minimized, so the ordering is "most recently put away"
    /// rather than whatever order the Accessibility API happens to return. Keyed the same way
    /// as `ManagedWindow.id`.
    private var minimizedAt: [String: Date] = [:]

    /// Poll cadence. The fast one only runs while the panel is on screen — that is the only
    /// time a stale card is visible to anyone.
    private var idleInterval: TimeInterval = 4.0
    private var activeInterval: TimeInterval = 1.0

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }

        attachObserversToRunningApps()
        schedulePoll(interval: idleInterval)
        refresh()
    }

    /// Speeds the poll up while the panel is visible and slows it back down when it closes.
    func setPanelVisible(_ visible: Bool) {
        schedulePoll(interval: visible ? activeInterval : idleInterval)
        if visible { refresh() }
    }

    private func schedulePoll(interval: TimeInterval) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        // .common so the poll keeps running while a menu is open or the panel is being
        // scrolled — both put the run loop in a tracking mode that would starve .default.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Refresh

    /// Coalesced rescan. A single user action (minimizing a window) can produce an AX
    /// notification, a workspace notification and a poll tick within a few milliseconds;
    /// without this they would be three full scans of every app on the Mac.
    func refresh() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scan() }
        refreshWorkItem = item
        scanQueue.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    private func scan() {
        guard AccessibilityBridge.isTrusted else {
            DispatchQueue.main.async {
                self.needsAccessibility = true
                self.windows = []
            }
            return
        }

        let scope = Preferences.shared.scope
        let myPID = ProcessInfo.processInfo.processIdentifier
        var found: [ManagedWindow] = []

        for app in NSWorkspace.shared.runningApplications {
            // .regular only: accessory and prohibited apps are menu-bar items and helpers.
            // They own windows (status item panels, hidden host windows) that the user never
            // thinks of as windows and would only clutter the panel.
            guard app.activationPolicy == .regular, app.processIdentifier != myPID else { continue }
            guard !app.isTerminated else { continue }

            let appElement = AccessibilityBridge.application(pid: app.processIdentifier)
            let appName = app.localizedName ?? "App"

            for window in AccessibilityBridge.elements(appElement, kAXWindowsAttribute) {
                // Real windows only — not sheets, palettes or system dialogs, none of which
                // can be put away independently. See `isMinimizableWindow` for why this is
                // not simply a subrole check.
                guard AccessibilityBridge.isMinimizableWindow(window) else { continue }

                let isMinimized = AccessibilityBridge.bool(window, kAXMinimizedAttribute) ?? false
                let include: Bool
                switch scope {
                case .minimizedOnly:      include = isMinimized
                case .minimizedAndHidden: include = isMinimized || app.isHidden
                case .allWindows:         include = true
                }
                guard include else { continue }

                let windowID = AccessibilityBridge.windowID(of: window)
                let origin = AccessibilityBridge.point(window, kAXPositionAttribute) ?? .zero
                let size = AccessibilityBridge.size(window, kAXSizeAttribute) ?? CGSize(width: 800, height: 600)

                // A minimized window keeps its last size but its position can be garbage
                // (some apps park it off-screen). Only the aspect ratio is ever read, so a
                // degenerate size is the one thing worth rejecting.
                guard size.width > 40, size.height > 40 else { continue }

                let id = windowID.map { "w\($0)" }
                    ?? "p\(app.processIdentifier)-\(AccessibilityBridge.string(window, kAXTitleAttribute) ?? "")"

                found.append(ManagedWindow(
                    id: id,
                    element: window,
                    windowID: windowID,
                    pid: app.processIdentifier,
                    title: AccessibilityBridge.string(window, kAXTitleAttribute) ?? "",
                    appName: appName,
                    bundleIdentifier: app.bundleIdentifier,
                    isMinimized: isMinimized,
                    frame: CGRect(origin: origin, size: size)
                ))
            }
        }

        let now = Date()
        var stamps = minimizedAt
        let liveIDs = Set(found.map(\.id))
        stamps = stamps.filter { liveIDs.contains($0.key) }
        for window in found where window.isMinimized && stamps[window.id] == nil {
            stamps[window.id] = now
        }
        // A window that came back out of the Dock loses its stamp, so if it is minimized
        // again it sorts to the top rather than back to where it was hours ago.
        for window in found where !window.isMinimized { stamps[window.id] = nil }

        let ordered = found.sorted { a, b in
            switch (stamps[a.id], stamps[b.id]) {
            case let (x?, y?): return x > y
            case (_?, nil):    return true       // minimized before still-visible
            case (nil, _?):    return false
            case (nil, nil):
                // Neither is minimized (only reachable in .allWindows): group by app so a
                // browser's twelve windows do not interleave with everything else.
                return (a.appName, a.displayTitle) < (b.appName, b.displayTitle)
            }
        }

        DispatchQueue.main.async {
            self.minimizedAt = stamps
            self.needsAccessibility = false
            if self.windows != ordered { self.windows = ordered }
        }
    }

    // MARK: - Actions

    /// Where a restored window should land.
    ///
    /// Areas are passed in as rectangles rather than `NSScreen`s because the work happens off
    /// the main thread; the caller resolves the screen while it still knows which one the
    /// user was pointing at.
    enum Placement {
        /// Leave it exactly where it was.
        case unchanged
        /// Middle of `area` — a screen's `visibleFrame` in Cocoa coordinates.
        case centered(in: CGRect)
        /// Under `point`, held inside `area`. The drag-out path.
        case dropped(at: CGPoint, in: CGRect)
    }

    /// Brings a window back and gives it the keyboard.
    ///
    /// The order of the steps is not interchangeable: un-minimizing does not activate the app,
    /// activating does not choose *which* of its windows comes forward, and raising alone
    /// leaves the app in the background.
    func restore(_ window: ManagedWindow, placement: Placement = .unchanged) {
        let moveToCurrentSpace = Preferences.shared.openOnCurrentSpace
        scanQueue.async {
            // Before un-minimizing, not after. A minimized window keeps its CGWindowID and its
            // Space assignment, so re-assigning it here means it simply comes back where you
            // are. Doing it afterwards makes macOS switch you to its old desktop first and
            // then switch back — the visible flick this exists to avoid.
            if moveToCurrentSpace, let id = window.windowID {
                SpacesBridge.shared.moveToActiveSpace(id)
            }

            AccessibilityBridge.setMinimized(window.element, false)

            self.place(window.element, placement)

            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: window.pid)?
                    .activate(options: [.activateIgnoringOtherApps])
            }
            // A beat after activation: several apps (Safari, Finder) re-order their windows
            // as they come forward and would otherwise put a different one on top.
            self.scanQueue.asyncAfter(deadline: .now() + 0.12) {
                // Again, because some apps re-assign their own Space as the window comes back.
                if moveToCurrentSpace, let id = window.windowID {
                    SpacesBridge.shared.moveToActiveSpace(id)
                }
                AccessibilityBridge.focus(window.element)
                AccessibilityBridge.raise(window.element)
                self.refresh()
            }
        }
    }

    /// Moves a window to where the placement says, held inside the visible area.
    ///
    /// Everything here works in Cocoa coordinates where `origin` is the window's **top-left**
    /// corner — that is what `AXPosition` wants once flipped, and mixing it up puts windows
    /// off the bottom of the screen.
    ///
    /// The clamp is the part worth keeping: a window dropped with its title bar under the menu
    /// bar, or centred while taller than the screen, cannot be grabbed again.
    private func place(_ element: AXUIElement, _ placement: Placement) {
        guard let size = AccessibilityBridge.size(element, kAXSizeAttribute),
              let origin = Self.topLeft(for: placement, size: size) else { return }
        // AXPosition is the top-left corner in top-left-origin coordinates.
        AccessibilityBridge.setPosition(element, AccessibilityBridge.axPoint(fromCocoa: origin))
    }

    /// Where a window of `size` should have its top-left corner, in Cocoa coordinates, or nil
    /// to leave it alone.
    ///
    /// Pure so the arithmetic can be tested: this is geometry across a flipped axis — Cocoa's
    /// y grows upward while a window's origin is its *top* edge — and getting it wrong sends
    /// windows off the bottom of the screen, which is exactly the kind of thing that only
    /// shows up on the one display you did not try.
    static func topLeft(for placement: Placement, size: CGSize) -> CGPoint? {
        let area: CGRect
        var origin: CGPoint

        switch placement {
        case .unchanged:
            return nil
        case .centered(let visible):
            area = visible
            origin = CGPoint(x: visible.midX - size.width / 2,
                             y: visible.midY + size.height / 2)
        case .dropped(let point, let visible):
            area = visible
            // Centred horizontally on the drop, title bar just under the pointer: the window
            // lands where the card was let go, already held by the part you grab.
            origin = CGPoint(x: point.x - size.width / 2, y: point.y - 18)
        }

        // Held inside the visible area. A window whose title bar ends up under the menu bar,
        // or off the right edge, cannot be grabbed again — and a window larger than the screen
        // is pinned to the top-left rather than centred, so at least its controls are reachable.
        origin.x = min(max(origin.x, area.minX), area.maxX - min(size.width, area.width))
        origin.y = min(max(origin.y, area.minY + min(size.height, area.height)), area.maxY)
        return origin
    }

    func minimize(_ window: ManagedWindow) {
        minimizeElement(window.element)
    }

    /// Minimizes a window sider only has an Accessibility handle for — the drag-to-the-edge
    /// path, where the window is one the user is dragging and has never been in the registry
    /// (it was not minimized, so nothing scanned it).
    func minimizeElement(_ element: AXUIElement) {
        scanQueue.async {
            AccessibilityBridge.setMinimized(element, true)
            self.refresh()
        }
    }

    /// Closes the window with ⌘W.
    ///
    /// Not by pressing the window's own `AXCloseButton`, which is what this did first and is
    /// the tidier idea: an app that draws its own title bar exposes the button and then
    /// ignores `AXPress`. Discord does exactly that — the button is there, the press does
    /// nothing, and the window stays. ⌘W is a menu item rather than a control, so every app
    /// handles it.
    ///
    /// The cost is that ⌘W goes to whichever window has focus, so the target has to be given
    /// focus first — which means bringing it out of the Dock. That is unavoidable: there is no
    /// way to send a keystroke to a specific window, only to an app. The window is put back
    /// afterwards if it did not close, so a shortcut the app ignores leaves things exactly as
    /// they were rather than half-restored.
    func close(_ window: ManagedWindow) {
        let wasMinimized = window.isMinimized
        scanQueue.async {
            AccessibilityBridge.setMinimized(window.element, false)
            AccessibilityBridge.focus(window.element)
            AccessibilityBridge.raise(window.element)
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: window.pid)?
                    .activate(options: [.activateIgnoringOtherApps])
            }

            // Long enough for the window to actually be frontmost. Sent too early, the app
            // routes ⌘W to whichever of its windows still holds focus — closing the wrong one,
            // which is worse than not closing anything.
            self.scanQueue.asyncAfter(deadline: .now() + 0.25) {
                AccessibilityBridge.focus(window.element)
                KeyStroke.commandW(to: window.pid)
                self.scanQueue.asyncAfter(deadline: .now() + 0.45) {
                    self.settleAfterClose(window, wasMinimized: wasMinimized)
                }
            }
        }
    }

    /// Leaves the window in a sane state when ⌘W did not close it.
    private func settleAfterClose(_ window: ManagedWindow, wasMinimized: Bool) {
        guard AccessibilityBridge.isAlive(window.element) else { self.refresh(); return }

        // Something is asking a question — an unsaved-changes sheet. Leave the window out and
        // in front so it can be answered; putting it back would hide a modal dialog.
        if AccessibilityBridge.hasSheet(window.element) {
            AccessibilityBridge.raise(window.element)
            self.refresh()
            return
        }

        // The app ignored ⌘W. Put the window back where it was, so a close that does nothing
        // is not silently a restore — which is exactly how this looked before.
        if wasMinimized {
            AccessibilityBridge.setMinimized(window.element, true)
        }
        self.refresh()
    }

    // MARK: - Observers

    private func attachObserversToRunningApps() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attachObserver(pid: app.processIdentifier)
        }
    }

    /// Window notifications are registered on the *application* element, not per window:
    /// windows come and go constantly and re-registering each one is both slower and racy
    /// (the element can be dead before the call lands).
    private func attachObserver(pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier, observers[pid] == nil else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let registry = Unmanaged<WindowRegistry>.fromOpaque(refcon).takeUnretainedValue()
            registry.refresh()
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let element = AccessibilityBridge.application(pid: pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowMiniaturizedNotification,
                     kAXWindowDeminiaturizedNotification,
                     kAXWindowCreatedNotification,
                     kAXFocusedWindowChangedNotification,
                     kAXApplicationHiddenNotification,
                     kAXApplicationShownNotification,
                     kAXTitleChangedNotification,
                     kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(observer),
                           .defaultMode)
        observers[pid] = observer
    }

    private func detachObserver(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              AXObserverGetRunLoopSource(observer),
                              .defaultMode)
    }

    @objc private func workspaceChanged(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        switch note.name {
        case NSWorkspace.didLaunchApplicationNotification:
            if let pid = app?.processIdentifier {
                // A just-launched app has no AX element for a moment; registering too early
                // silently fails and that app then never reports anything.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.attachObserver(pid: pid) }
            }
        case NSWorkspace.didTerminateApplicationNotification:
            if let pid = app?.processIdentifier { detachObserver(pid: pid) }
        default:
            break
        }
        refresh()
    }
}
