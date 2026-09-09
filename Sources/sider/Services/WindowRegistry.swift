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

    /// Brings a window back and gives it the keyboard.
    ///
    /// `dropPoint` (Cocoa screen coordinates) places the window there — that is the drag-out
    /// path. Passing nil leaves it wherever it was, which is the click path.
    ///
    /// The order of the steps is not interchangeable: un-minimizing does not activate the app,
    /// activating does not choose *which* of its windows comes forward, and raising alone
    /// leaves the app in the background.
    func restore(_ window: ManagedWindow, at dropPoint: CGPoint? = nil) {
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

            if let dropPoint {
                self.place(window.element, atCocoa: dropPoint)
            }

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

    /// Positions a window so it sits under `point`, held inside the visible area of whichever
    /// screen that point is on.
    ///
    /// The window is centred horizontally on the drop and its title bar put just below it, so
    /// it lands where the card was let go and the pointer is already on the part you grab —
    /// dropping a window with its title bar under the menu bar, or half off the right edge,
    /// is the failure mode worth spending these few lines on.
    private func place(_ element: AXUIElement, atCocoa point: CGPoint) {
        guard let size = AccessibilityBridge.size(element, kAXSizeAttribute) else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }

        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - 18)   // Cocoa: y is the TOP here
        origin.x = min(max(origin.x, area.minX), area.maxX - min(size.width, area.width))
        origin.y = min(max(origin.y, area.minY + min(size.height, area.height)), area.maxY)

        // AXPosition is the top-left corner in top-left-origin coordinates.
        AccessibilityBridge.setPosition(element, AccessibilityBridge.axPoint(fromCocoa: origin))
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

    /// Closes the window by pressing its own close button, rather than sending the app ⌘W.
    /// Pressing the button is what the app itself hooks, so unsaved-changes sheets and
    /// "close means hide" behaviours keep working.
    func close(_ window: ManagedWindow) {
        scanQueue.async {
            // A minimized window's close button cannot be pressed while it is in the Dock,
            // so bring it back first.
            AccessibilityBridge.setMinimized(window.element, false)
            if let button = AccessibilityBridge.copyAttribute(window.element, kAXCloseButtonAttribute) {
                AXUIElementPerformAction((button as! AXUIElement), kAXPressAction as CFString)
            }
            self.refresh()
        }
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
