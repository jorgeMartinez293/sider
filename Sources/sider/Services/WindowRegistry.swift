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
    /// Where AX observers are registered, and the only queue that touches `observers`. Not
    /// the main thread: see `attachObserver(pid:)`.
    private let observerQueue = DispatchQueue(label: "com.jorge.sider.observers", qos: .utility)
    private var observers: [pid_t: AXObserver] = [:]
    private var pollTimer: Timer?
    private var refreshWorkItem: DispatchWorkItem?
    private var started = false

    /// When each window was last seen minimized, so the ordering is "most recently put away"
    /// rather than whatever order the Accessibility API happens to return. Keyed the same way
    /// as `ManagedWindow.id`.
    private var minimizedAt: [String: Date] = [:]

    /// Accessibility handles for windows the owning app left out of `kAXWindowsAttribute`,
    /// found the slow way (`AccessibilityBridge.windows(pid:matching:)`) and kept so that it
    /// is done once per window rather than once per scan. Touched only on `scanQueue`.
    private var discovered: [CGWindowID: AXUIElement] = [:]

    /// Windows the WindowServer lists that turned out to have no Accessibility element at all
    /// — invisible host windows, offscreen buffers — and when that was found out. Retried
    /// after `notWindowRetry`, in case the search simply ran out of time. `scanQueue` only.
    private var notWindows: [CGWindowID: Date] = [:]
    private let notWindowRetry: TimeInterval = 120

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
        center.addObserver(self, selector: #selector(activeSpaceChanged(_:)),
                           name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // The first scan before the observers: it no longer waits on them, and it is what
        // the panel shows.
        refresh()
        schedulePoll(interval: idleInterval)
        attachObserversToRunningApps()
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

        let started = Date()
        let scope = Preferences.shared.scope
        let hideMinimized = Preferences.shared.hideMinimized && scope != .minimizedOnly
        let myPID = ProcessInfo.processInfo.processIdentifier
        // Only needed to vet windows without a minimize button, which only the widest scope
        // collects; one WindowServer call per scan rather than per window.
        let visibleIDs = scope == .allWindows ? Self.visibleWindowIDs() : []

        // Which desktop a window is on comes from the WindowServer, never from the
        // Accessibility list — that list answers a different question. Measured on macOS 27,
        // an app's `kAXWindowsAttribute` holds its open windows *on the desktop it believes is
        // on screen* plus its minimized windows *from every desktop*. So taken at face value
        // it shows the minimized windows of other desktops, and for a moment after a Space
        // switch (until each app catches up) it holds the old desktop's windows and misses
        // the new one's.
        let spaces = SpacesBridge.shared
        let thisDesktopOnly = Preferences.shared.currentDesktopOnly && spaces.canReadSpaces
        let currentSpaces = thisDesktopOnly ? spaces.currentSpaces() : []
        let server = Self.serverWindows(currentSpaces: thisDesktopOnly ? currentSpaces : nil)
        discovered = discovered.filter { server.spaces[$0.key] != nil }
        notWindows = notWindows.filter { server.spaces[$0.key] != nil }
        var found: [ManagedWindow] = []
        var unlistedIDs = Set<CGWindowID>()

        for app in NSWorkspace.shared.runningApplications {
            // .regular only in the narrow scopes: accessory apps are menu-bar items, and the
            // windows they own (status item panels, hidden host windows) are never minimized
            // or hidden in the ⌘H sense. "Every window" takes them too, because their settings
            // windows are real windows — those are vetted by `visibleIDs` below.
            // .prohibited apps are background helpers with no UI to speak of.
            let policyOK = app.activationPolicy == .regular
                || (scope == .allWindows && app.activationPolicy == .accessory)
            guard policyOK, app.processIdentifier != myPID else { continue }
            guard !app.isTerminated else { continue }
            // An app the WindowServer has no window for, here or anywhere, is not worth an
            // Accessibility round trip — and those round trips are the scan. In "every
            // window" there are dozens of such processes (agents, Safari's web content
            // processes, several of which run out the full timeout), and asking each of them
            // took a scan to about four seconds: longer than the poll interval, so the panel
            // was always showing a list from a desktop or two ago.
            if server.isComplete, !server.owners.contains(app.processIdentifier) { continue }
            // Includes the accessory apps left out at launch, now that one has a window.
            attachObserver(pid: app.processIdentifier)

            let appElement = AccessibilityBridge.application(pid: app.processIdentifier)
            let appName = app.localizedName ?? "App"

            let listed = AccessibilityBridge.elements(appElement, kAXWindowsAttribute)
                .map { (element: $0, id: AccessibilityBridge.windowID(of: $0)) }
            let unlisted = unlistedWindows(
                pid: app.processIdentifier,
                listed: Set(listed.compactMap(\.id)),
                candidates: server.candidates[app.processIdentifier] ?? [])
            unlistedIDs.formUnion(unlisted.compactMap(\.id))
            var seen = Set<CGWindowID>()

            for (window, windowID) in listed + unlisted {
                if let windowID {
                    // An app can list the same window twice while it is being re-created.
                    guard seen.insert(windowID).inserted else { continue }
                    if thisDesktopOnly,
                       !SpacesBridge.isShown(windowSpaces: server.spaces[windowID] ?? spaces.spaces(of: windowID),
                                             on: currentSpaces) {
                        continue
                    }
                }
                guard AccessibilityBridge.string(window, kAXRoleAttribute) == kAXWindowRole as String
                else { continue }

                // In the narrow scopes, real windows only — not sheets, palettes or system
                // dialogs, none of which can be put away independently. See
                // `isMinimizableWindow` for why this is not simply a subrole check.
                let canMinimize = AccessibilityBridge.isMinimizableWindow(window)
                if !canMinimize {
                    // "Every window" means every window: settings windows, inspectors and
                    // the like have no minimize button but are exactly what the user is
                    // looking for. Accepted only while actually drawn at an ordinary level,
                    // which is what keeps out the invisible host windows and status-item
                    // popovers that apps also list as windows.
                    guard scope == .allWindows, let windowID, visibleIDs.contains(windowID)
                    else { continue }
                }

                let isMinimized = AccessibilityBridge.bool(window, kAXMinimizedAttribute) ?? false
                if isMinimized && hideMinimized { continue }
                let include: Bool
                switch scope {
                case .minimizedOnly:      include = isMinimized
                case .minimizedAndHidden: include = isMinimized || app.isHidden
                case .allWindows:         include = true
                }
                guard include else { continue }

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
                    canMinimize: canMinimize,
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
            // The desktop changed while this scan ran, so it describes the one just left. A
            // newer scan is already queued by `activeSpaceChanged`; publishing this one would
            // flash the previous desktop's windows until it lands.
            if thisDesktopOnly, spaces.currentSpaces() != currentSpaces { return }
            self.minimizedAt = stamps
            self.needsAccessibility = false
            if self.windows.map(\.id) != ordered.map(\.id) {
                // Counts only, never titles. Enough to tell from a user's log whether the
                // desktop filter or the apps' own lists are behind a card that is missing or
                // should not be there.
                let recovered = ordered.filter { $0.windowID.map(unlistedIDs.contains) ?? false }.count
                Logger.log("WindowRegistry: \(ordered.count) windows"
                    + (thisDesktopOnly ? " on desktop \(currentSpaces.sorted())" : " on every desktop")
                    + (recovered > 0 ? ", \(recovered) not listed by their app" : "")
                    + ", scanned in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
            if self.windows != ordered { self.windows = ordered }
        }
    }

    /// Windows of `pid` among `candidates` (already narrowed to the desktops being shown) that
    /// the app itself did not list — with an Accessibility element for each one that has one.
    ///
    /// This is what fills the gap right after a Space switch, when an app's own list still
    /// describes the previous desktop, and what makes "every window" with the desktop filter
    /// off include the open windows of other desktops, which no app ever lists. Found the
    /// slow way once, then remembered; see `discovered` and `notWindows`.
    private func unlistedWindows(pid: pid_t, listed: Set<CGWindowID>,
                                 candidates: [CGWindowID]) -> [(element: AXUIElement, id: CGWindowID?)] {
        let now = Date()
        let missing = candidates.filter { id in
            !listed.contains(id)
                && notWindows[id].map { now.timeIntervalSince($0) > notWindowRetry } ?? true
        }
        let unknown = Set(missing.filter { discovered[$0] == nil })
        if !unknown.isEmpty {
            let found = AccessibilityBridge.windows(pid: pid, matching: unknown)
            for id in unknown {
                if let element = found[id] { discovered[id] = element } else { notWindows[id] = now }
            }
        }
        return missing.compactMap { id in discovered[id].map { (element: $0, id: id) } }
    }

    /// What the WindowServer knows about the windows sider could show, read once per scan.
    private struct ServerWindows {
        /// False when the WindowServer could not be asked. Then nothing here can be trusted
        /// to rule an app out, and every app is asked the old way.
        var isComplete = false
        /// The Spaces of every window below the status-bar level, on any desktop.
        var spaces: [CGWindowID: Set<Int>] = [:]
        /// Apps with at least one such window placed on a desktop the panel is showing —
        /// minimized and hidden windows keep their Space, so they count. Nobody else is asked.
        var owners = Set<pid_t>()
        /// Ordinary-level windows big enough to be worked in, by owner: what
        /// `unlistedWindows` checks the apps' own answers against. Slivers (tab-bar and
        /// title-bar helpers) are left out up front so they never cost a search.
        var candidates: [pid_t: [CGWindowID]] = [:]
    }

    /// Reads `ServerWindows`. `currentSpaces` nil means every desktop counts.
    ///
    /// One window list and one Space query per window — a few milliseconds for the whole Mac,
    /// against tens of milliseconds for a single Accessibility call to a single app.
    private static func serverWindows(currentSpaces: Set<Int>?) -> ServerWindows {
        var result = ServerWindows()
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return result
        }
        result.isComplete = SpacesBridge.shared.canReadSpaces
        let ceiling = Int(CGWindowLevelForKey(.statusWindow))
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < ceiling,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let id = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            let windowSpaces = SpacesBridge.shared.spaces(of: id)
            result.spaces[id] = windowSpaces
            // On no Space at all: never drawn anywhere, an offscreen buffer rather than
            // something the user could have lost.
            guard !windowSpaces.isEmpty else { continue }
            if let currentSpaces,
               !SpacesBridge.isShown(windowSpaces: windowSpaces, on: currentSpaces) { continue }
            result.owners.insert(pid)

            guard layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width > 40, height > 40
            else { continue }
            result.candidates[pid, default: []].append(id)
        }
        return result
    }

    /// Windows the WindowServer is drawing right now below the status-bar level — ordinary
    /// windows, floating panels and modal dialogs, but not menus, popovers or the menu bar.
    private static func visibleWindowIDs() -> Set<CGWindowID> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ceiling = Int(CGWindowLevelForKey(.statusWindow))
        var ids = Set<CGWindowID>()
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < ceiling,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { continue }
            ids.insert(id)
        }
        return ids
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

            // Activation has to wait until the window has really left the Dock. The
            // un-minimize animation takes a few hundred milliseconds, and an app that is
            // activated while all of its windows still count as minimized takes that as "no
            // visible windows" and handles a reopen — which un-minimizes *every* window it
            // has, not just the one the user picked.
            Self.waitUntilRestored(window.element)

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

    /// Blocks the calling (scan) queue until `element` reports itself as no longer minimized,
    /// or a second has passed — an app that never updates the attribute must not hang a restore.
    private static func waitUntilRestored(_ element: AXUIElement) {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if AccessibilityBridge.bool(element, kAXMinimizedAttribute) != true { return }
            Thread.sleep(forTimeInterval: 0.02)
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

    /// The `ManagedWindow.id` of the window that has the keyboard right now, or nil when there
    /// is none worth naming (sider itself in front, no focused window, no CGWindowID).
    ///
    /// Asked of the frontmost app, like `minimizeFocusedWindow`; the answer arrives on the
    /// main queue. Only ids built from a CGWindowID are returned — they are the ones a scan
    /// produces for the same window, so they match a card.
    func focusedWindowID(completion: @escaping (String?) -> Void) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier
        else { return completion(nil) }
        scanQueue.async {
            let app = AccessibilityBridge.application(pid: pid)
            var id: String?
            if let focused = AccessibilityBridge.copyAttribute(app, kAXFocusedWindowAttribute),
               CFGetTypeID(focused) == AXUIElementGetTypeID() {
                id = AccessibilityBridge.windowID(of: focused as! AXUIElement).map { "w\($0)" }
            }
            DispatchQueue.main.async { completion(id) }
        }
    }

    /// Minimizes whichever window has the keyboard — the five-finger tap.
    ///
    /// Asked of the frontmost app rather than taken from the registry: in the default scope
    /// the registry only knows windows that are *already* minimized.
    func minimizeFocusedWindow() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier
        else { return }
        scanQueue.async {
            let app = AccessibilityBridge.application(pid: pid)
            guard let focused = AccessibilityBridge.copyAttribute(app, kAXFocusedWindowAttribute),
                  CFGetTypeID(focused) == AXUIElementGetTypeID()
            else { return }
            let window = focused as! AXUIElement
            // A sheet or a palette cannot go to the Dock; asking would fail silently.
            guard AccessibilityBridge.isMinimizableWindow(window) else { return }
            AccessibilityBridge.setMinimized(window, true)
            self.refresh()
        }
    }

    // MARK: - Observers

    private func attachObserversToRunningApps() {
        // Regular apps only. Accessory apps get one once the WindowServer shows them owning a
        // window (see `scan()`): most of them never do, and asking costs — see below.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attachObserver(pid: app.processIdentifier)
        }
    }

    /// Window notifications are registered on the *application* element, not per window:
    /// windows come and go constantly and re-registering each one is both slower and racy
    /// (the element can be dead before the call lands).
    ///
    /// Registered on `observerQueue`, never on the main thread. Each
    /// `AXObserverAddNotification` is a synchronous round trip into the app, and processes
    /// that never answer Accessibility — every one of Safari's web content processes, which
    /// come and go with its tabs — make each of the eight calls wait out the timeout: two
    /// seconds per process, measured. Done on the main thread over a dozen of them, that froze
    /// sider for over twenty seconds at launch, and for two more each time Safari spawned one.
    private func attachObserver(pid: pid_t) {
        observerQueue.async { [self] in
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
                // An app that does not answer the first will not answer the other seven.
                // Left unregistered, so the next scan that finds it owning a window tries again.
                if AXObserverAddNotification(observer, element, name as CFString, refcon) == .cannotComplete {
                    return
                }
            }
            // CFRunLoopAddSource is thread-safe; the callback still runs on the main thread.
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               AXObserverGetRunLoopSource(observer),
                               .defaultMode)
            observers[pid] = observer
        }
    }

    private func detachObserver(pid: pid_t) {
        observerQueue.async { [self] in
            guard let observer = observers.removeValue(forKey: pid) else { return }
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer),
                                  .defaultMode)
        }
    }

    /// The user moved to another desktop (or a display's desktop changed under them).
    ///
    /// Until now nothing listened for this, so the panel kept the previous desktop's list
    /// until the next poll — up to four seconds of the wrong windows, or of "nothing here"
    /// with the hover refusing to open.
    @objc private func activeSpaceChanged(_ note: Notification) {
        // The cards on hand belong to the desktop just left. Dropping the ones that are not
        // on this desktop right away — one WindowServer query per card, no Accessibility —
        // means a panel opened before the next scan lands never shows the old desktop.
        let spaces = SpacesBridge.shared
        if Preferences.shared.currentDesktopOnly, spaces.canReadSpaces {
            let current = spaces.currentSpaces()
            let kept = windows.filter { window in
                window.windowID.map {
                    SpacesBridge.isShown(windowSpaces: spaces.spaces(of: $0), on: current)
                } ?? true
            }
            if kept != windows { windows = kept }
        }
        refresh()
        // Apps catch up with the switch on their own schedule, and a scan that lands before
        // they have still has to go the slow way for each window they left out. A second
        // look once they have settled is cheap and costs nothing if nothing changed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
    }

    @objc private func workspaceChanged(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        switch note.name {
        case NSWorkspace.didLaunchApplicationNotification:
            // Regular apps only, as at launch; an accessory app is picked up by the scan once it
            // owns a window. Safari alone launches a web content process for every few tabs.
            if let app, app.activationPolicy == .regular {
                let pid = app.processIdentifier
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
