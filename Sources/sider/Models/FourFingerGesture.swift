import CoreGraphics
import Foundation

/// The four-finger "peek and pick" gesture as a pure state machine.
///
/// Put four fingers on the trackpad and the panel opens. Without lifting them, slide up or
/// down to walk through the cards; lift, and the highlighted window comes back.
///
/// It consumes one trackpad frame at a time — how many fingers are down, where their centroid
/// is, and what time it is — and answers with events. Nothing here touches AppKit or the
/// trackpad, so every rule below can be tested by feeding it frames.
///
/// Coordinates are the trackpad's own, normalised to 0…1 with the origin at the bottom left:
/// moving the fingers *up* increases `y`, which is also the direction the highlight travels
/// on screen.
struct FourFingerGesture {

    enum Event: Equatable {
        /// Four fingers have been down long enough to mean it. Open the panel.
        case began
        /// The highlighted card changed. `nil` means nothing is highlighted.
        case selected(Int?)
        /// The fingers lifted. Bring back the card at this index, if any.
        case ended(Int?)
        /// Not ours after all (a sideways swipe, a stalled device). Put the panel away.
        case cancelled
    }

    /// Fingers needed to start. Five or more still count: a thumb resting on the pad while
    /// four fingers swipe is the normal way to hold a hand.
    static let fingersRequired = 4

    /// Fingers needed to *keep going* once the panel is open. One fewer than it takes to
    /// start, because a hand sliding four fingers along a trackpad does not keep all four on
    /// it: the little finger lifts, or the leading one runs off the edge of the pad. Treating
    /// that as a release brought back whichever window happened to be highlighted, halfway
    /// through choosing.
    static let fingersToContinue = 3

    /// Four fingers must stay down this long before the panel opens. Fingers rarely land in
    /// the same millisecond, and a four-finger swipe sideways (between Spaces) is over almost
    /// as fast — opening on the very first frame would flash the panel for both.
    static let dwell: TimeInterval = 0.08

    /// Dropping below `fingersToContinue` for less than this is a glitch, not a release. A
    /// hand that actually comes off the pad does not wait for it: the frame with no fingers
    /// on it ends the gesture on the spot.
    static let releaseGrace: TimeInterval = 0.05

    /// After a finger leaves, movement is ignored for this long. A hand lifting off peels its
    /// fingers away one after another, and the ones still down slide a little as it goes —
    /// that slide must not carry the highlight to the next card at the last moment.
    static let liftFreeze: TimeInterval = 0.06

    /// A frame stream that goes quiet for this long means the device went away mid-gesture.
    static let staleAfter: TimeInterval = 0.5

    /// Vertical travel before the first card is highlighted, as a fraction of the pad's
    /// height. Without it, the fingers settling after landing would pick a card by accident
    /// and a plain four-finger tap could never be a peek.
    static let deadZone: CGFloat = 0.04

    /// Vertical travel per card, as a fraction of the pad's height. Roughly ten cards fit
    /// across the whole pad, so a comfortable stroke covers a typical strip.
    static let stepSize: CGFloat = 0.1

    /// Extra travel, in cards, before the highlight leaves the card it is on. Without it a
    /// hand resting exactly between two cards flickers between them.
    static let hysteresis: CGFloat = 0.1

    /// Horizontal travel that turns the gesture into someone else's (Space switching).
    static let sidewaysLimit: CGFloat = 0.12

    private enum Phase {
        case idle
        /// Four fingers are down but have not stayed long enough to count.
        case pending(since: TimeInterval, origin: CGPoint)
        case active
        /// Cancelled: ignored until the fingers come off, so the rest of a swipe that was
        /// not ours cannot start a new gesture.
        case suppressed
    }

    private var phase: Phase = .idle

    // Active-phase bookkeeping.
    private var origin = CGPoint.zero
    private var lastY: CGFloat = 0
    private var lastFingers = 0
    private var travel: CGFloat = 0
    /// Continuous position in card units; the highlighted card is its rounding.
    private var position: CGFloat = 0
    private(set) var selected: Int?
    private var belowSince: TimeInterval?
    private var frozenUntil: TimeInterval = 0
    private var lastFrameAt: TimeInterval = 0

    var isActive: Bool {
        if case .active = phase { return true }
        return false
    }

    /// True from the first frame with enough fingers until the gesture is over, including the
    /// moments before the panel has been asked to open.
    var isEngaged: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// Feeds one frame.
    ///
    /// - Parameters:
    ///   - itemCount: How many cards there are right now.
    ///   - startIndex: The card the highlight lands on first, wherever the strip has put it.
    ///   - holdOff: The hand on the pad may still be a five-finger tap. The panel waits: a
    ///     tap is over long before anyone could have wanted to see it.
    mutating func update(fingers: Int, centroid: CGPoint, time: TimeInterval,
                         itemCount: Int, startIndex: Int, holdOff: Bool = false) -> [Event] {
        lastFrameAt = time
        let down = fingers >= Self.fingersRequired

        switch phase {
        case .idle:
            if down { phase = .pending(since: time, origin: centroid) }
            return []

        case .suppressed:
            if !down { phase = .idle }
            return []

        case .pending(let since, let start):
            guard down else { phase = .idle; return [] }
            if isSideways(centroid, from: start) { phase = .suppressed; return [] }
            guard time - since >= Self.dwell, !holdOff else { return [] }
            phase = .active
            origin = start
            lastY = centroid.y
            lastFingers = fingers
            travel = 0
            selected = nil
            belowSince = nil
            frozenUntil = 0
            return [.began]

        case .active:
            // The hand is off the pad. No grace period: the trackpad reports nothing further
            // once the last finger is gone, so there is no later frame to end on.
            if fingers == 0 { return finish(.ended(selected)) }

            if fingers < Self.fingersToContinue {
                let since = belowSince ?? time
                belowSince = since
                guard time - since >= Self.releaseGrace else { return [] }
                return finish(.ended(selected))
            }

            let wasBelow = belowSince != nil
            belowSince = nil
            // A finger joining or leaving moves the centroid without the hand moving.
            // Re-baseline, or that shift is read as travel.
            if wasBelow || fingers != lastFingers {
                if fingers < lastFingers { frozenUntil = time + Self.liftFreeze }
                lastFingers = fingers
                lastY = centroid.y
                return []
            }

            let deltaY = centroid.y - lastY
            lastY = centroid.y
            guard time >= frozenUntil else { return [] }
            return move(by: deltaY, centroid: centroid, itemCount: itemCount, startIndex: startIndex)
        }
    }

    /// Call periodically while engaged. Frames only arrive while something is touching the
    /// pad, so anything that has to happen *after* a wait needs this: a release that has
    /// outlasted its grace period, and a device that stopped talking mid-gesture — the panel
    /// must not stay held open by a release that was never reported.
    mutating func tick(time: TimeInterval) -> [Event] {
        if isActive, let since = belowSince, time - since >= Self.releaseGrace {
            return finish(.ended(selected))
        }
        guard isEngaged, time - lastFrameAt >= Self.staleAfter else { return [] }
        let wasActive = isActive
        phase = .idle
        return wasActive ? [.cancelled] : []
    }

    // MARK: - Private

    private mutating func move(by deltaY: CGFloat, centroid: CGPoint,
                               itemCount: Int, startIndex: Int) -> [Event] {
        guard itemCount > 0 else { return [] }

        guard selected != nil else {
            if isSideways(centroid, from: origin) { return finish(.cancelled) }
            travel += deltaY
            guard abs(travel) >= Self.deadZone else { return [] }
            position = CGFloat(min(max(startIndex, 0), itemCount - 1))
            selected = Int(position)
            return [.selected(selected)]
        }

        // Fingers moving down the pad (y falling) walk toward higher indices, which is down
        // the strip. Clamped every frame rather than at the end, so pushing past the last
        // card builds up no slack to be worked off on the way back.
        position -= deltaY / Self.stepSize
        position = min(max(position, 0), CGFloat(itemCount - 1))
        let index = Int(position.rounded())
        guard let current = selected, index != current,
              abs(position - CGFloat(current)) >= 0.5 + Self.hysteresis
        else { return [] }
        selected = index
        return [.selected(index)]
    }

    private mutating func finish(_ event: Event) -> [Event] {
        // A cancel waits for the fingers to come off; an end already has.
        if case .cancelled = event { phase = .suppressed } else { phase = .idle }
        selected = nil
        belowSince = nil
        return [event]
    }

    private func isSideways(_ point: CGPoint, from start: CGPoint) -> Bool {
        let dx = abs(point.x - start.x)
        return dx > Self.sidewaysLimit && dx > abs(point.y - start.y)
    }
}
