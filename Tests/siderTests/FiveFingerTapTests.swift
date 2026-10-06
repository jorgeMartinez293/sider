import XCTest
@testable import sider

final class FiveFingerTapTests: XCTestCase {

    private var tap = FiveFingerTap()
    private var now: TimeInterval = 100

    private func frame(_ fingers: Int, x: CGFloat = 0.5, y: CGFloat = 0.5,
                       dt: TimeInterval = 0.01) -> Bool {
        now += dt
        return tap.update(fingers: fingers, centroid: CGPoint(x: x, y: y), time: now)
    }

    /// Fingers land one after another, rest a moment, and peel off the same way.
    func testAHandTouchingAndLeavingIsATap() {
        for count in 1...5 { XCTAssertFalse(frame(count)) }
        XCTAssertFalse(frame(5, dt: 0.08))
        XCTAssertFalse(frame(3))
        XCTAssertFalse(frame(1))
        XCTAssertTrue(frame(0))
    }

    func testFourFingersAreNotATap() {
        for count in 1...4 { _ = frame(count) }
        _ = frame(4, dt: 0.08)
        XCTAssertFalse(frame(0))
    }

    func testRestingTheHandIsNotATap() {
        for count in 1...5 { _ = frame(count) }
        _ = frame(5, dt: FiveFingerTap.maxHold + 0.05)
        XCTAssertFalse(tap.isCandidate)
        XCTAssertFalse(frame(0))
    }

    func testAFiveFingerSwipeIsNotATap() {
        for count in 1...5 { _ = frame(count) }
        _ = frame(5, y: 0.5 + FiveFingerTap.maxTravel + 0.02)
        XCTAssertFalse(frame(0))
    }

    /// Four fingers already walking the cards, then the thumb touches down: not a tap.
    func testAThumbJoiningLateIsNotATap() {
        for count in 1...4 { _ = frame(count) }
        _ = frame(4, dt: FiveFingerTap.landingWindow + 0.1)
        _ = frame(5)
        XCTAssertFalse(tap.isCandidate)
        XCTAssertFalse(frame(0))
    }

    /// One finger moving the pointer beforehand does not count against the landing.
    func testAFingerAlreadyDownDoesNotSpoilTheTap() {
        _ = frame(1)
        _ = frame(1, dt: 2)
        for count in 2...5 { _ = frame(count) }
        XCTAssertTrue(tap.isCandidate)
        _ = frame(2, dt: 0.05)
        XCTAssertTrue(frame(0))
    }

    func testEachTapStartsClean() {
        for count in 1...5 { _ = frame(count) }
        _ = frame(5, dt: FiveFingerTap.maxHold + 0.05)
        XCTAssertFalse(frame(0))
        for count in 1...5 { _ = frame(count) }
        XCTAssertTrue(frame(0, dt: 0.05))
    }
}
