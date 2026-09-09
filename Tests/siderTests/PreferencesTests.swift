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
