import CoreGraphics
import Foundation

/// Recognises a five-finger tap: the whole hand touching the trackpad and coming straight
/// back off.
///
/// Pure, like `FourFingerGesture` — it is fed the same trackpad frames and answers yes or no
/// on the frame where the hand leaves.
struct FiveFingerTap {

    static let fingersRequired = 5

    /// The hand has to arrive together. Five fingers that took longer than this to gather —
    /// counted from the third — are a hand settling onto the pad, not tapping it.
    static let landingWindow: TimeInterval = 0.2

    /// How long all five may stay down and still be a tap rather than a rest.
    static let maxHold: TimeInterval = 0.3

    /// Travel, as a fraction of the pad, past which the touch was a swipe or a pinch.
    static let maxTravel: CGFloat = 0.06

    private var gatheringSince: TimeInterval?
    private var fiveSince: TimeInterval?
    private var anchor: CGPoint?
    private var lastFingers = 0
    private var spoiled = false

    /// True while a hand that could still turn out to be a tap is on the pad. The four-finger
    /// gesture holds off opening the panel for as long as this lasts, so a tap does not
    /// flash it.
    var isCandidate: Bool { fiveSince != nil && !spoiled }

    /// Feeds one frame. Returns true on the frame that completes a tap.
    mutating func update(fingers: Int, centroid: CGPoint, time: TimeInterval) -> Bool {
        defer { lastFingers = fingers }

        guard fingers > 0 else {
            let tapped = isCandidate && time - (fiveSince ?? time) <= Self.maxHold
            self = FiveFingerTap()
            return tapped
        }

        if fingers >= 3, gatheringSince == nil { gatheringSince = time }

        guard fingers >= Self.fingersRequired else {
            // Fingers peeling off at the end are part of the tap; nothing to measure.
            return false
        }

        if fiveSince == nil {
            fiveSince = time
            if time - (gatheringSince ?? time) > Self.landingWindow { spoiled = true }
        }
        // The centroid jumps when a finger joins or leaves; only compare like with like.
        if anchor == nil || fingers != lastFingers {
            anchor = centroid
        } else if let anchor, hypot(centroid.x - anchor.x, centroid.y - anchor.y) > Self.maxTravel {
            spoiled = true
        }
        if time - (fiveSince ?? time) > Self.maxHold { spoiled = true }
        return false
    }
}
