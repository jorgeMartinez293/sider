import AppKit
import CoreGraphics
import QuartzCore

/// Keeps macOS's own vertical swipes (Mission Control, App Exposé) from firing while the
/// four-finger gesture has the trackpad.
///
/// With Mission Control set to "swipe up with three fingers", macOS answers to four fingers
/// as well — there is no setting for "three only". So four fingers sliding up would walk the
/// cards *and* throw Mission Control over them, and sliding down would open App Exposé.
///
/// The trackpad driver recognises those swipes itself and hands them to the Dock as events
/// of their own. They pass through the session event stream on the way, which is where this
/// sits: an event tap that lets every such swipe through unless it began with sider's
/// fingers down, in which case the whole swipe — start to finish — is dropped before the
/// Dock sees it. A three-finger swipe is never touched.
///
/// The event layout is not public. The field numbers below are the ones every tool that
/// synthesises these swipes uses, and each decision is logged, so if a future macOS changes
/// them the log says what it saw instead of the feature silently doing nothing.
final class SystemSwipeBlocker {

    /// Asked once, at the start of each system swipe: does this one belong to sider?
    var shouldBlock: () -> Bool = { false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?

    /// Whether the swipe in progress is being dropped. Decided at its first event and held to
    /// its last: dropping the start but delivering the end would leave the Dock finishing a
    /// gesture it never saw begin.
    private var dropping = false
    private var lastSwipeEventAt: CFTimeInterval = 0
    /// How many Dock events have been described in the log so far. The first few are written
    /// out in full: if their layout is ever not what this file expects, that is the only
    /// place it shows.
    private var described = 0

    // MARK: - Event layout

    /// Gesture events, and the Dock's own swipe events.
    private static let gestureType: UInt32 = 29
    private static let dockControlType: UInt32 = 30

    private static let subtypeField = field(110)
    private static let axisField = field(123)
    private static let phaseField = field(132)

    /// The subtype that marks a Dock swipe (IOKit's `kIOHIDEventTypeDockSwipe`).
    private static let dockSwipeSubtype: Int64 = 23
    /// 1 is horizontal (between Spaces), 2 is vertical (Mission Control / App Exposé), 3 is a
    /// pinch (Launchpad / Show Desktop). Only the vertical one collides with the cards.
    private static let verticalAxis: Int64 = 2

    private static let phaseBegan: Int64 = 1
    private static let phaseEnded: Int64 = 4
    private static let phaseCancelled: Int64 = 8

    private static func field(_ raw: UInt32) -> CGEventField {
        CGEventField(rawValue: raw) ?? unsafeBitCast(raw, to: CGEventField.self)
    }

    // MARK: - Lifecycle

    func start() {
        guard tap == nil, retry == nil, !install() else { return }
        // An active tap needs Accessibility, which a fresh install does not have yet. Keep
        // asking; the grant can land at any time.
        Logger.log("system swipe blocker: no event tap yet (Accessibility?), retrying")
        retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.install() else { return }
            self.retry?.invalidate()
            self.retry = nil
        }
    }

    func stop() {
        retry?.invalidate()
        retry = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        dropping = false
    }

    private func install() -> Bool {
        let mask = CGEventMask(1) << Self.gestureType | CGEventMask(1) << Self.dockControlType
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: Self.callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // .commonModes so the tap keeps answering while a menu is open or a scroll is
        // tracking — a tap that stops answering stalls the events it is holding.
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        Logger.log("system swipe blocker: event tap installed")
        return true
    }

    // MARK: - Events

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        let pass = Unmanaged.passUnretained(event)
        guard let userInfo else { return pass }
        let blocker = Unmanaged<SystemSwipeBlocker>.fromOpaque(userInfo).takeUnretainedValue()

        // macOS switches a tap off if it is ever slow to answer, and says so here. Left
        // alone the tap stays off for good and the system swipes quietly come back.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = blocker.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        return blocker.shouldDrop(event, type: type) ? nil : pass
    }

    private func shouldDrop(_ event: CGEvent, type: CGEventType) -> Bool {
        let subtype = event.getIntegerValueField(Self.subtypeField)
        let phase = event.getIntegerValueField(Self.phaseField)
        let axis = event.getIntegerValueField(Self.axisField)

        if type.rawValue == Self.dockControlType, described < 8 {
            described += 1
            Logger.log("system swipe: saw dock event subtype=\(subtype) axis=\(axis) phase=\(phase)")
        }
        guard subtype == Self.dockSwipeSubtype else { return false }

        let now = CACurrentMediaTime()

        // A new swipe: either it says so, or the last one went quiet long enough ago that
        // this cannot be more of it. The second test is what keeps a missed "began" from
        // leaving the previous swipe's verdict in force.
        if phase == Self.phaseBegan || now - lastSwipeEventAt > 0.3 {
            dropping = axis == Self.verticalAxis && shouldBlock()
            Logger.log("system swipe: type=\(type.rawValue) axis=\(axis) phase=\(phase) → \(dropping ? "blocked" : "passed")")
        }
        lastSwipeEventAt = now

        let drop = dropping
        if phase == Self.phaseEnded || phase == Self.phaseCancelled { dropping = false }
        return drop
    }
}
