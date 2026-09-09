import AppKit

/// Watches the pointer and decides when the panel should open and close.
///
/// Implemented as a poll of `NSEvent.mouseLocation` rather than an invisible trigger window
/// or a global `mouseMoved` monitor, both of which were tried first and both of which have a
/// hole that matters here:
///
///  * A 1–2pt transparent window at the screen edge does receive `mouseEntered`, but it also
///    swallows clicks meant for whatever is underneath, and it does not exist inside another
///    app's full-screen space.
///  * `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` stops delivering while
///    another app has a modal drag or a menu tracking loop up, which is exactly when someone
///    flicks to the edge to go find another window.
///
/// Reading the pointer position is a cheap, permission-free WindowServer query and works in
/// every one of those cases. At 20 Hz it costs a rounding error of CPU and is still well
/// under the ~80 ms where a delay starts to feel like lag.
final class EdgeHoverMonitor {

    /// Fires when the pointer has dwelt in the hot zone long enough, with the screen it is on.
    var onTrigger: ((NSScreen) -> Void)?
    /// Fires when the pointer has been away from the panel long enough.
    var onLeave: (() -> Void)?

    /// Supplied by the panel controller: the panel's current frame in screen coordinates, or
    /// nil when it is not showing. The pointer being inside it is what keeps it open.
    var panelFrame: (() -> CGRect?)?

    private var timer: Timer?
    private let interval: TimeInterval = 0.05

    /// When the pointer entered the hot zone, or nil if it is not in it. Compared against the
    /// hover delay so a pointer sweeping across the edge on its way elsewhere is ignored.
    private var dwellStarted: Date?
    /// When the pointer left the panel, or nil while it is inside.
    private var leftPanelAt: Date?

    private var suspendedUntil: Date?

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
        if let until = suspendedUntil {
            if Date() < until { return }
            suspendedUntil = nil
        }

        let prefs = Preferences.shared
        let point = NSEvent.mouseLocation

        // Panel already up: the only question is whether the pointer has wandered off.
        if let frame = panelFrame?() {
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

        // Panel down: look for a deliberate dwell at the edge.
        guard let screen = isInHotZone(point, prefs: prefs) else {
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

    /// The screen whose left edge the pointer is against, or nil.
    private func isInHotZone(_ point: CGPoint, prefs: Preferences) -> NSScreen? {
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
                && point.x <= edge + prefs.hotZoneWidth
        }
    }
}
