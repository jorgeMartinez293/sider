import SwiftUI
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

    /// Same for the style: a value this build does not know draws the original cards.
    func testUnknownStyleFallsBack() {
        let original = UserDefaults.standard.string(forKey: "panelStyle")
        defer { UserDefaults.standard.set(original, forKey: "panelStyle") }
        UserDefaults.standard.set("nonsense", forKey: "panelStyle")
        XCTAssertEqual(Preferences.shared.style, .floating)
    }

    /// A border style never chosen follows what the old "glow" toggle said, so an upgrade
    /// keeps the border it already had; a chosen one wins, and junk falls back the same way.
    func testBorderStyleFallsBackToLegacyGlowToggle() {
        let defaults = UserDefaults.standard
        let originalStyle = defaults.object(forKey: "borderStyle")
        let originalGlow = defaults.object(forKey: "borderGlow")
        defer {
            defaults.set(originalStyle, forKey: "borderStyle")
            defaults.set(originalGlow, forKey: "borderGlow")
        }
        defaults.removeObject(forKey: "borderStyle")
        defaults.set(true, forKey: "borderGlow")
        XCTAssertEqual(Preferences.shared.borderStyle, .glow)
        defaults.set(false, forKey: "borderGlow")
        XCTAssertEqual(Preferences.shared.borderStyle, .line)
        defaults.set("nonsense", forKey: "borderStyle")
        XCTAssertEqual(Preferences.shared.borderStyle, .line)
        Preferences.shared.borderStyle = .sheen
        XCTAssertEqual(Preferences.shared.borderStyle, .sheen)
    }

    func testBorderLightAngleIsClamped() {
        let prefs = Preferences.shared
        let original = prefs.borderLightAngle
        defer { prefs.borderLightAngle = original }
        prefs.borderLightAngle = 999
        XCTAssertEqual(prefs.borderLightAngle, 360)
    }

    /// The sheen's gradient runs from the edge the light comes from to the opposite one;
    /// diagonal light lands exactly on the corners.
    func testSheenEndpointsFollowLightAngle() {
        func assertPoint(_ p: UnitPoint, _ x: CGFloat, _ y: CGFloat, line: UInt = #line) {
            XCTAssertEqual(p.x, x, accuracy: 1e-9, line: line)
            XCTAssertEqual(p.y, y, accuracy: 1e-9, line: line)
        }
        let top = BorderSheen<Rectangle>.endpoints(forAngle: 90)
        assertPoint(top.lit, 0.5, 0)
        assertPoint(top.far, 0.5, 1)
        let topLeft = BorderSheen<Rectangle>.endpoints(forAngle: 135)
        assertPoint(topLeft.lit, 0, 0)
        assertPoint(topLeft.far, 1, 1)
        let right = BorderSheen<Rectangle>.endpoints(forAngle: 0)
        assertPoint(right.lit, 1, 0.5)
        assertPoint(right.far, 0, 0.5)
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

final class WindowPlacementTests: XCTestCase {

    /// A 1512×982 display with the menu bar taken off the top and the Dock off the bottom.
    private let screen = CGRect(x: 0, y: 61, width: 1512, height: 888)

    func testCenteredPutsTheWindowInTheMiddle() {
        let size = CGSize(width: 800, height: 600)
        let origin = WindowRegistry.topLeft(for: .centered(in: screen), size: size)
        XCTAssertNotNil(origin)
        // Cocoa origin is the window's TOP edge, so the centre of the window sits half its
        // height below it.
        XCTAssertEqual(origin!.x + size.width / 2, screen.midX, accuracy: 0.5)
        XCTAssertEqual(origin!.y - size.height / 2, screen.midY, accuracy: 0.5)
    }

    /// The clamp has to survive a window bigger than the screen. Pinned to the top-left beats
    /// centred-and-unreachable: at least the title bar and the close button are on screen.
    func testOversizeWindowStaysReachable() {
        let size = CGSize(width: 2400, height: 1600)
        let origin = WindowRegistry.topLeft(for: .centered(in: screen), size: size)!
        XCTAssertEqual(origin.x, screen.minX, accuracy: 0.5)
        XCTAssertEqual(origin.y, screen.maxY, accuracy: 0.5)
    }

    /// A drop near a corner must not leave the window half off the display.
    func testDropIsHeldInsideTheScreen() {
        let size = CGSize(width: 900, height: 700)
        let corner = CGPoint(x: screen.maxX - 4, y: screen.minY + 4)
        let origin = WindowRegistry.topLeft(for: .dropped(at: corner, in: screen), size: size)!
        XCTAssertLessThanOrEqual(origin.x + size.width, screen.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(origin.x, screen.minX - 0.5)
        XCTAssertLessThanOrEqual(origin.y, screen.maxY + 0.5)
        XCTAssertGreaterThanOrEqual(origin.y - size.height, screen.minY - 0.5)
    }

    func testUnchangedMovesNothing() {
        XCTAssertNil(WindowRegistry.topLeft(for: .unchanged, size: CGSize(width: 10, height: 10)))
    }
}

final class SpacesFilterTests: XCTestCase {

    /// A window on another desktop is what the filter exists to drop, minimized or not.
    func testWindowOnAnotherDesktopIsHidden() {
        XCTAssertFalse(SpacesBridge.isShown(windowSpaces: [188], on: [229]))
    }

    /// With "Displays have separate Spaces" every screen has its own current desktop, and a
    /// window on any of them is in front of the user.
    func testWindowOnAnyDisplaysDesktopIsShown() {
        XCTAssertTrue(SpacesBridge.isShown(windowSpaces: [102], on: [229, 102]))
    }

    /// A window shown on all desktops reports every Space it is on.
    func testWindowOnAllDesktopsIsShown() {
        XCTAssertTrue(SpacesBridge.isShown(windowSpaces: [188, 189, 229], on: [189]))
    }

    /// When the WindowServer cannot say where a window is, keeping it is the safer mistake:
    /// a card that vanishes for no visible reason reads as sider losing windows.
    func testUnknownSpaceIsKept() {
        XCTAssertTrue(SpacesBridge.isShown(windowSpaces: [], on: [229]))
        XCTAssertTrue(SpacesBridge.isShown(windowSpaces: [188], on: []))
    }
}
