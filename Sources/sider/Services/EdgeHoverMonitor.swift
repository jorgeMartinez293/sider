import AppKit
import ApplicationServices

/// Watches the pointer and decides three things: when the panel should open, when it should
/// close, and when the user is dragging a window at the left edge in order to put it away.
///
/// Implemented as a poll of `NSEvent.mouseLocation` / `NSEvent.pressedMouseButtons` rather
/// than an invisible trigger window or a global event monitor, both of which were tried first
/// and both of which have a hole that matters here:
///
///  * A 1–2pt transparent window at the screen edge does receive `mouseEntered`, but it also
///    swallows clicks meant for whatever is underneath, and it does not exist inside another
///    app's full-screen space.
///  * `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` stops delivering while
///    another app runs a modal drag or a menu tracking loop — which, for the drag-to-minimize
///    gesture, is *precisely* the situation being detected.
///
/// Both properties are permission-free WindowServer queries and work in every one of those
/// cases. At 20 Hz they cost a rounding error and stay well under the ~80 ms where a delay
/// starts to feel like lag.
final class EdgeHoverMonitor {

    /// Fires when the pointer has dwelt in the hot zone long enough, with the screen it is on.
    var onTrigger: ((NSScreen) -> Void)?
    /// Fires when the pointer has been away from the panel long enough.
    var onLeave: (() -> Void)?

    /// A window is being dragged and has reached the edge: open the panel as a drop target.
    var onWindowDragEnteredEdge: ((NSScreen) -> Void)?
    /// The drag moved back out of the edge without being dropped.
    var onWindowDragLeftEdge: (() -> Void)?
    /// A dragged window was released over the edge or the panel. Put it away.
    var onWindowDropped: ((AXUIElement) -> Void)?

    /// Supplied by the panel controller: the panel's current frame in screen coordinates, or
    /// nil when it is not showing. The pointer being inside it is what keeps it open.
    var panelFrame: (() -> CGRect?)?

    /// The pointer has come inside the open panel, so the user is about to interact with it.
    /// Fires once per visit, not once per tick.
    var onPointerEnteredPanel: (() -> Void)?

    /// While this returns true the panel is never auto-closed. Set by the controller during a
    /// card drag-out, where the pointer is deliberately far outside the panel and closing it
    /// would cancel the gesture halfway.
    var holdOpen: (() -> Bool)?

    private var timer: Timer?
    private let interval: TimeInterval = 0.05

    /// When the pointer entered the hot zone, or nil if it is not in it. Compared against the
    /// hover delay so a pointer sweeping across the edge on its way elsewhere is ignored.
    private var dwellStarted: Date?
    /// When the pointer left the panel, or nil while it is inside.
    private var leftPanelAt: Date?

    private var suspendedUntil: Date?
    private var pointerWasInsidePanel = false

    // MARK: - Drag state

    private var buttonWasDown = false
    private var pressLocation: CGPoint?
    /// The window under the point where the press started. Resolved once per drag, off the
    /// main thread — a hit test reaches into another process and can take a while.
    private var dragElement: AXUIElement?
    private var dragStartOrigin: CGPoint?
    private var dragLookupStarted = false
    /// Only true once the window has actually *moved*. A press-and-drag inside a window is
    /// text selection, not a window drag, and must not arm the drop target.
    private var isDraggingWindow = false
    private var dropTargetActive = false
    private var tickCount = 0

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Ignores the edge for a moment. Used right after the panel closes from a click: the
    /// pointer is still sitting on the card it just used, which for a narrow panel can be
    /// inside the hot zone, and the panel would immediately reopen.
    func suspend(for seconds: TimeInterval) {
        suspendedUntil = Date().addingTimeInterval(seconds)
        dwellStarted = nil
    }

    private func tick() {
        tickCount &+= 1
        let prefs = Preferences.shared
        let point = NSEvent.mouseLocation
        let buttonDown = NSEvent.pressedMouseButtons & 1 != 0

        updateDragState(point: point, buttonDown: buttonDown, prefs: prefs)

        if let until = suspendedUntil {
            if Date() < until { return }
            suspendedUntil = nil
        }

        // A window drag drives the panel itself (see `updateDragState`); the hover rules below
        // would fight it — the pointer is at the edge with the button down, which the dwell
        // logic would read as an ordinary hover.
        guard !isDraggingWindow else { return }

        if let frame = panelFrame?() {
            // Tracked against the exact frame, not the forgiving one below: this arms the
            // panel for clicks, and doing that while the pointer is merely near it would take
            // the keyboard from the app in front for no reason.
            let inside = frame.contains(point)
            if inside && !pointerWasInsidePanel { onPointerEnteredPanel?() }
            pointerWasInsidePanel = inside

            if holdOpen?() == true { leftPanelAt = nil; return }
            // A margin around the panel, so crossing the few points between the screen edge
            // and the panel — or overshooting slightly to the right of a card — does not
            // count as leaving.
            let forgiving = frame.insetBy(dx: -24, dy: -8)
            let stillInside = forgiving.contains(point) || isInHotZone(point, prefs: prefs) != nil
            if stillInside {
                leftPanelAt = nil
            } else if let since = leftPanelAt {
                if Date().timeIntervalSince(since) >= prefs.hideDelay {
                    leftPanelAt = nil
                    onLeave?()
                }
            } else {
                leftPanelAt = Date()
            }
            return
        }

        pointerWasInsidePanel = false

        // Panel down: look for a deliberate dwell at the edge. Not while a button is held —
        // dragging a text selection or a Finder item to the edge is not a request to open it.
        guard !buttonDown, let screen = isInHotZone(point, prefs: prefs) else {
            dwellStarted = nil
            return
        }
        guard let since = dwellStarted else {
            dwellStarted = Date()
            return
        }
        if Date().timeIntervalSince(since) >= prefs.hoverDelay {
            dwellStarted = nil
            onTrigger?(screen)
        }
    }

    // MARK: - Drag to the edge

    /// Tracks a press through to its release, deciding along the way whether it is a window
    /// being dragged and whether it ended over the edge.
    private func updateDragState(point: CGPoint, buttonDown: Bool, prefs: Preferences) {
        guard prefs.dropToMinimize else {
            if isDraggingWindow || dropTargetActive { resetDrag() }
            buttonWasDown = buttonDown
            return
        }

        // Release.
        if buttonWasDown && !buttonDown {
            if isDraggingWindow, dropTargetActive, let element = dragElement {
                onWindowDropped?(element)
            } else if dropTargetActive {
                onWindowDragLeftEdge?()
            }
            resetDrag()
            buttonWasDown = false
            return
        }

        // Press.
        if !buttonWasDown && buttonDown {
            resetDrag()
            pressLocation = point
            buttonWasDown = true
            return
        }

        buttonWasDown = buttonDown
        guard buttonDown, let press = pressLocation else { return }

        // Resolve the window under the press once, and only after the pointer has actually
        // moved — a plain click never needs a cross-process hit test.
        if !dragLookupStarted, hypot(point.x - press.x, point.y - press.y) > 6 {
            dragLookupStarted = true
            resolveDraggedWindow(pressedAt: press)
        }

        guard let element = dragElement else { return }

        // Poll the window's own position at 5 Hz. This is what separates a window drag from a
        // selection drag inside a window: only the former moves the window.
        if !isDraggingWindow, tickCount % 4 == 0 {
            if let origin = AccessibilityBridge.point(element, kAXPositionAttribute) {
                if let start = dragStartOrigin {
                    if hypot(origin.x - start.x, origin.y - start.y) > 4 { isDraggingWindow = true }
                } else {
                    dragStartOrigin = origin
                }
            }
        }

        guard isDraggingWindow else { return }

        let overEdge = isInHotZone(point, prefs: prefs, tolerance: 8)
            ?? (panelFrame?()?.insetBy(dx: -16, dy: 0).contains(point) == true ? screenFor(point) : nil)

        if let screen = overEdge {
            if !dropTargetActive {
                dropTargetActive = true
                onWindowDragEnteredEdge?(screen)
            }
        } else if dropTargetActive {
            dropTargetActive = false
            onWindowDragLeftEdge?()
        }
    }

    /// The hit test is a synchronous IPC call into whichever app owns the pixel under the
    /// pointer, so it runs off the main thread — doing it inline would stall the run loop
    /// (and every animation on it) for up to the AX messaging timeout, mid-gesture.
    private func resolveDraggedWindow(pressedAt press: CGPoint) {
        let axPoint = AccessibilityBridge.axPoint(fromCocoa: press)
        let myPID = ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            guard let window = AccessibilityBridge.window(at: axPoint),
                  AccessibilityBridge.pid(of: window) != myPID,
                  // A palette or a sheet cannot be minimized on its own, and offering to put
                  // one away would just fail silently.
                  AccessibilityBridge.isMinimizableWindow(window)
            else { return }
            let origin = AccessibilityBridge.point(window, kAXPositionAttribute)
            DispatchQueue.main.async {
                // The press may already be over by the time this lands.
                guard self.buttonWasDown else { return }
                self.dragElement = window
                self.dragStartOrigin = origin
            }
        }
    }

    private func resetDrag() {
        pressLocation = nil
        dragElement = nil
        dragStartOrigin = nil
        dragLookupStarted = false
        isDraggingWindow = false
        dropTargetActive = false
    }

    // MARK: - Geometry

    /// The screen whose left edge the pointer is against, or nil.
    ///
    /// `tolerance` widens the zone; a drag gets a more generous target than a hover, because
    /// the user is holding a window and cannot place the pointer as precisely.
    private func isInHotZone(_ point: CGPoint, prefs: Preferences, tolerance: CGFloat = 0) -> NSScreen? {
        let candidates: [NSScreen]
        switch prefs.screen {
        case .main:         candidates = NSScreen.main.map { [$0] } ?? []
        case .underCursor:  candidates = NSScreen.screens
        }
        return candidates.first { screen in
            // The pointer must be on this screen vertically as well: on a stacked or
            // side-by-side arrangement, x can be within a few points of one screen's left
            // edge while the pointer is physically on another.
            guard screen.frame.minY...screen.frame.maxY ~= point.y else { return false }
            // visibleFrame, not frame: with the Dock pinned to the left edge, the "edge" the
            // user can actually reach is the Dock's right side. Measuring from frame.minX
            // there would put the hot zone underneath the Dock, where the pointer never
            // stops.
            let edge = screen.visibleFrame.minX
            return point.x >= edge - 1
                && point.x <= edge + prefs.hotZoneWidth + tolerance
        }
    }

    private func screenFor(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }
}
