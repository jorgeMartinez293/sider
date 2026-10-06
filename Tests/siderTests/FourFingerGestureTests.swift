import XCTest
@testable import sider

final class FourFingerGestureTests: XCTestCase {

    private var gesture = FourFingerGesture()
    private var now: TimeInterval = 100

    /// Feeds a frame `dt` seconds after the previous one.
    private func frame(_ fingers: Int, x: CGFloat = 0.5, y: CGFloat = 0.5, dt: TimeInterval = 0.01,
                       count: Int = 5, start: Int = 2) -> [FourFingerGesture.Event] {
        now += dt
        return gesture.update(fingers: fingers, centroid: CGPoint(x: x, y: y), time: now,
                              itemCount: count, startIndex: start)
    }

    /// Four fingers down and held past the dwell, ready to be moved.
    private func engage(y: CGFloat = 0.5) {
        _ = frame(4, y: y)
        let events = frame(4, y: y, dt: FourFingerGesture.dwell + 0.01)
        XCTAssertEqual(events, [.began])
    }

    func testOpensOnlyAfterTheDwell() {
        XCTAssertEqual(frame(4), [])
        XCTAssertEqual(frame(4, dt: 0.02), [])
        XCTAssertEqual(frame(4, dt: FourFingerGesture.dwell + 0.01), [.began])
    }

    /// Three fingers is the system's own gesture, and fingers landing one by one pass through
    /// it on the way to four.
    func testThreeFingersDoNothing() {
        for _ in 0..<30 { XCTAssertEqual(frame(3, dt: 0.01), []) }
        XCTAssertFalse(gesture.isEngaged)
    }

    func testTapShorterThanTheDwellIsIgnored() {
        _ = frame(4)
        XCTAssertEqual(frame(0, dt: 0.03), [])
        XCTAssertFalse(gesture.isEngaged)
    }

    func testLiftingWithoutMovingEndsWithNothingSelected() {
        engage()
        XCTAssertEqual(frame(4, dt: 0.1), [])
        XCTAssertEqual(frame(0), [.ended(nil)])
    }

    /// Settling after the landing must not pick a card.
    func testMovementInsideTheDeadZoneSelectsNothing() {
        engage()
        XCTAssertEqual(frame(4, y: 0.5 + FourFingerGesture.deadZone / 2), [])
    }

    func testFirstMovementHighlightsTheStartCard() {
        engage()
        XCTAssertEqual(frame(4, y: 0.5 + FourFingerGesture.deadZone * 1.5), [.selected(2)])
    }

    func testSlidingUpMovesTowardTheTopAndDownTowardTheBottom() {
        engage()
        _ = frame(4, y: 0.6)                                   // dead zone crossed → card 2
        XCTAssertEqual(frame(4, y: 0.6 + FourFingerGesture.stepSize), [.selected(1)])
        XCTAssertEqual(frame(4, y: 0.6), [.selected(2)])        // back down a step
        XCTAssertEqual(frame(4, y: 0.6 - FourFingerGesture.stepSize), [.selected(3)])
    }

    /// A hand resting between two cards must not flicker between them.
    func testHighlightDoesNotFlickerAtTheBoundary() {
        engage()
        _ = frame(4, y: 0.6)                                   // card 2
        let boundary = 0.6 + FourFingerGesture.stepSize / 2    // exactly between 2 and 1
        for wobble in [0.004, -0.004, 0.004, -0.004] as [CGFloat] {
            XCTAssertEqual(frame(4, y: boundary + wobble), [])
        }
        XCTAssertEqual(gesture.selected, 2)
    }

    /// Pushing past the last card must not store slack that has to be worked off before the
    /// highlight starts coming back.
    func testClampingBuildsNoSlack() {
        engage()
        _ = frame(4, y: 0.6)                                   // card 2 of 0…4
        _ = frame(4, y: 0.6 - 0.5)                             // far past the bottom → card 4
        XCTAssertEqual(gesture.selected, 4)
        XCTAssertEqual(frame(4, y: 0.1 + FourFingerGesture.stepSize), [.selected(3)])
    }

    /// What a real release looks like: the fingers peel off within a few frames and then the
    /// trackpad says nothing more. The window must come back on that last frame — there is no
    /// later one to wait for.
    func testQuickReleaseCommitsOnTheEmptyFrame() {
        engage()
        _ = frame(4, y: 0.6)
        XCTAssertEqual(frame(3, y: 0.62), [])
        XCTAssertEqual(frame(1, y: 0.9), [])
        XCTAssertEqual(frame(0), [.ended(2)])
        XCTAssertFalse(gesture.isEngaged)
    }

    /// Fingers leaving shift the centroid and drag the remaining ones a little; neither is a
    /// swipe.
    func testLiftingDoesNotMoveTheHighlight() {
        engage()
        _ = frame(4, y: 0.6)
        XCTAssertEqual(frame(3, y: 0.9), [])
        XCTAssertEqual(frame(3, y: 0.9 + FourFingerGesture.stepSize), [])   // inside the freeze
        XCTAssertEqual(frame(2, y: 0.95), [])
        XCTAssertEqual(frame(0), [.ended(2)])
    }

    /// The little finger coming off mid-slide is not a release: the gesture carries on with
    /// the three that are left.
    func testThreeFingersCarryOn() {
        engage()
        _ = frame(4, y: 0.6)
        XCTAssertEqual(frame(3, y: 0.3), [])                                  // centroid jumps
        XCTAssertEqual(frame(3, y: 0.3, dt: FourFingerGesture.liftFreeze + 0.01), [])
        XCTAssertEqual(frame(3, y: 0.3 + FourFingerGesture.stepSize), [.selected(1)])
        XCTAssertEqual(frame(4, y: 0.7), [])                                  // and back to four
        XCTAssertEqual(frame(4, y: 0.7 - FourFingerGesture.stepSize), [.selected(2)])
        XCTAssertTrue(gesture.isActive)
    }

    /// Two fingers left resting on the pad: the hand has let go even though it is not empty.
    func testFewerThanThreeEndsAfterTheGrace() {
        engage()
        _ = frame(4, y: 0.6)
        XCTAssertEqual(frame(2, y: 0.6), [])
        XCTAssertEqual(frame(2, y: 0.6, dt: FourFingerGesture.releaseGrace + 0.01), [.ended(2)])
    }

    /// Same release, but the trackpad goes quiet before the grace runs out.
    func testTickEndsAReleaseThatNoFrameFinished() {
        engage()
        _ = frame(4, y: 0.6)
        XCTAssertEqual(frame(2, y: 0.6), [])
        XCTAssertEqual(gesture.tick(time: now + 0.01), [])
        XCTAssertEqual(gesture.tick(time: now + FourFingerGesture.releaseGrace + 0.01), [.ended(2)])
        XCTAssertFalse(gesture.isEngaged)
    }

    func testAShortDropoutIsNotARelease() {
        engage()
        _ = frame(4, y: 0.6)
        XCTAssertEqual(frame(2, y: 0.9), [])
        // Back within the grace period, at a shifted centroid: no movement, no end.
        XCTAssertEqual(frame(4, y: 0.3, dt: 0.02), [])
        XCTAssertEqual(frame(4, y: 0.3 + FourFingerGesture.stepSize), [.selected(1)])
        XCTAssertTrue(gesture.isActive)
    }

    func testSidewaysSwipeBeforeTheDwellNeverOpens() {
        XCTAssertEqual(frame(4, x: 0.3), [])
        XCTAssertEqual(frame(4, x: 0.3 + FourFingerGesture.sidewaysLimit + 0.05, dt: 0.01), [])
        XCTAssertEqual(frame(4, x: 0.8, dt: 0.2), [])
        XCTAssertFalse(gesture.isActive)
    }

    func testSidewaysSwipeAfterOpeningCancels() {
        engage()
        XCTAssertEqual(frame(4, x: 0.5 + FourFingerGesture.sidewaysLimit + 0.05), [.cancelled])
        // Still down: not allowed to restart until the fingers come off.
        XCTAssertEqual(frame(4, dt: 0.3), [])
        XCTAssertEqual(frame(0), [])
        XCTAssertFalse(gesture.isEngaged)
    }

    /// Once something is highlighted, sideways drift in the hand is just a hand.
    func testSidewaysDriftAfterSelectingDoesNotCancel() {
        engage()
        _ = frame(4, y: 0.6)
        XCTAssertEqual(frame(4, x: 0.9, y: 0.6), [])
        XCTAssertTrue(gesture.isActive)
    }

    func testNoCardsMeansNoSelection() {
        engage()
        XCTAssertEqual(frame(4, y: 0.9, count: 0), [])
        XCTAssertEqual(frame(0, count: 0), [.ended(nil)])
    }

    func testSilenceMidGestureCancels() {
        engage()
        XCTAssertEqual(gesture.tick(time: now + 0.1), [])
        XCTAssertEqual(gesture.tick(time: now + FourFingerGesture.staleAfter), [.cancelled])
        XCTAssertFalse(gesture.isEngaged)
    }
}

extension FourFingerGestureTests {

    /// While the hand might still be a five-finger tap the panel stays shut; once it clearly
    /// is not, the gesture opens as usual.
    func testHoldOffDelaysTheOpening() {
        var gesture = FourFingerGesture()
        func feed(_ t: TimeInterval, holdOff: Bool) -> [FourFingerGesture.Event] {
            gesture.update(fingers: 5, centroid: CGPoint(x: 0.5, y: 0.5), time: t,
                           itemCount: 3, startIndex: 0, holdOff: holdOff)
        }
        XCTAssertEqual(feed(0, holdOff: true), [])
        XCTAssertEqual(feed(0.2, holdOff: true), [])
        XCTAssertEqual(feed(0.35, holdOff: false), [.began])
    }
}
