import XCTest
@testable import sider

final class PreferencesTests: XCTestCase {

    /// The sliders in Settings are bounded, but a value can also arrive from a stale
    /// `UserDefaults` written by an older build. Clamping is what keeps a 0pt-wide card or a
    /// 30-second open delay from making the app look broken with no way back.
    func testValuesAreClamped() {
        let prefs = Preferences.shared
        let originalWidth = prefs.cardWidth
        let originalDelay = prefs.hoverDelay
        defer { prefs.cardWidth = originalWidth; prefs.hoverDelay = originalDelay }

        prefs.cardWidth = 5_000
        XCTAssertLessThanOrEqual(prefs.cardWidth, 340)
        prefs.cardWidth = -10
        XCTAssertGreaterThanOrEqual(prefs.cardWidth, 120)

        prefs.hoverDelay = 99
        XCTAssertLessThanOrEqual(prefs.hoverDelay, 1.5)
    }

    /// An unrecognised stored value (a scope removed in a later version, a hand-edited
    /// plist) must fall back to the default rather than leaving the panel collecting nothing.
    func testUnknownScopeFallsBack() {
        UserDefaults.standard.set("nonsense", forKey: "panelScope")
        XCTAssertEqual(Preferences.shared.scope, .minimizedOnly)
        UserDefaults.standard.removeObject(forKey: "panelScope")
    }
}

final class ManagedWindowTests: XCTestCase {

    /// Plenty of windows have an empty AXTitle — an untitled document, a browser window
    /// before its tab settles. A blank caption reads as a bug, so the app name stands in.
    func testDisplayTitleFallsBackToAppName() {
        let window = ManagedWindow(
            id: "w1",
            element: AXUIElementCreateSystemWide(),
            windowID: 1,
            pid: 1,
            title: "   ",
            appName: "Finder",
            bundleIdentifier: "com.apple.finder",
            isMinimized: true,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertEqual(window.displayTitle, "Finder")
    }
}

final class CenteredStackLayoutTests: XCTestCase {

    /// The whole point of the layout: whatever the count, the most recent window (index 0)
    /// lands in the middle of the strip, so the card you are most likely to want back is
    /// always in the same place on screen.
    func testMostRecentSitsInTheMiddle() {
        for count in 1...12 {
            let order = CenteredStackLayout.order(count: count)
            let middle = order.firstIndex(of: 0)
            XCTAssertNotNil(middle, "count \(count)")
            // With an even count one side carries the extra card, so the anchor is allowed to
            // be half a slot off centre — but never further.
            let distanceFromCentre = abs(Double(middle!) - Double(count - 1) / 2)
            XCTAssertLessThanOrEqual(distanceFromCentre, 0.5, "count \(count) → \(order)")
        }
    }

    func testAlternatesOutwardFromTheAnchor() {
        XCTAssertEqual(CenteredStackLayout.order(count: 5), [4, 2, 0, 1, 3])
        XCTAssertEqual(CenteredStackLayout.order(count: 4), [2, 0, 1, 3])
        XCTAssertEqual(CenteredStackLayout.order(count: 1), [0])
    }

    /// Every window must be drawn exactly once — a layout that dropped or duplicated an index
    /// would lose a card, or crash the view when it subscripts the array twice.
    func testIsAPermutation() {
        for count in 0...20 {
            XCTAssertEqual(CenteredStackLayout.order(count: count).sorted(), Array(0..<count))
        }
    }
}
