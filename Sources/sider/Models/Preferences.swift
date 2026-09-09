import AppKit
import Combine
import SwiftUI

/// Which windows the panel collects.
enum PanelScope: String, CaseIterable, Identifiable {
    /// Only windows the user actually minimized. The default, and what sider is for.
    case minimizedOnly
    /// Minimized windows plus the windows of apps hidden with ⌘H — those are just as
    /// invisible and just as hard to get back to.
    case minimizedAndHidden
    /// Every standard window on the Mac, Stage Manager style. Useful on one big screen,
    /// noisy on several.
    case allWindows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimizedOnly:      return "Minimized windows"
        case .minimizedAndHidden: return "Minimized + hidden apps"
        case .allWindows:         return "Every window"
        }
    }

    var detail: String {
        switch self {
        case .minimizedOnly:      return "Only what you sent to the Dock."
        case .minimizedAndHidden: return "Also the windows of apps hidden with ⌘H."
        case .allWindows:         return "Every standard window, including the one in front."
        }
    }
}

/// Which screen the panel opens on when several are connected.
enum PanelScreen: String, CaseIterable, Identifiable {
    case underCursor
    case main

    var id: String { rawValue }

    var title: String {
        switch self {
        case .underCursor: return "Screen under the pointer"
        case .main:        return "Main screen only"
        }
    }
}

/// Every user-facing setting, persisted in `UserDefaults` and observable from SwiftUI.
///
/// `@AppStorage` is deliberately not used: the panel, the hover monitor and the capture loop
/// are AppKit objects that need to react to a change too, and they can subscribe to this
/// one `ObservableObject` instead of each re-reading defaults on a timer.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let scope = "panelScope"
        static let screen = "panelScreen"
        static let hotZoneWidth = "hotZoneWidth"
        static let hoverDelay = "hoverDelay"
        static let hideDelay = "hideDelay"
        static let cardWidth = "cardWidth"
        static let launchAtLogin = "launchAtLogin"
        static let hotKeyEnabled = "hotKeyEnabled"
        static let showTitles = "showTitles"
        static let hasCompletedWelcome = "hasCompletedWelcome"
        static let clickOutsideDismisses = "clickOutsideDismisses"
        static let openOnCurrentSpace = "openOnCurrentSpace"
        static let dropToMinimize = "dropToMinimize"
        static let centeredStack = "centeredStack"
        static let showPanelBackground = "showPanelBackground"
        static let openWhenEmpty = "openWhenEmpty"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.scope: PanelScope.minimizedOnly.rawValue,
            Key.screen: PanelScreen.underCursor.rawValue,
            // 2pt, not 1: a single point is genuinely hard to hit on a trackpad, and macOS
            // itself parks the pointer at x=0 only when you overshoot.
            Key.hotZoneWidth: 2.0,
            // Long enough that dragging past the edge on the way somewhere else does not
            // open the panel, short enough that a deliberate move feels instant.
            Key.hoverDelay: 0.28,
            Key.hideDelay: 0.45,
            Key.cardWidth: 200.0,
            Key.launchAtLogin: true,
            Key.hotKeyEnabled: true,
            Key.showTitles: true,
            Key.clickOutsideDismisses: true,
            Key.openOnCurrentSpace: true,
            Key.dropToMinimize: true,
            Key.centeredStack: true,
            // Off: the cards are the interface. A backing panel behind them is a second,
            // competing rectangle over whatever you were looking at.
            Key.showPanelBackground: false,
            Key.openWhenEmpty: false,
            Key.hasCompletedWelcome: false,
        ])
    }

    // MARK: - Behaviour

    var scope: PanelScope {
        get { PanelScope(rawValue: defaults.string(forKey: Key.scope) ?? "") ?? .minimizedOnly }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Key.scope) }
    }

    var screen: PanelScreen {
        get { PanelScreen(rawValue: defaults.string(forKey: Key.screen) ?? "") ?? .underCursor }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Key.screen) }
    }

    /// How many points from the left edge count as "at the edge".
    var hotZoneWidth: Double {
        get { defaults.double(forKey: Key.hotZoneWidth) }
        set { objectWillChange.send(); defaults.set(newValue.clamped(1, 12), forKey: Key.hotZoneWidth) }
    }

    /// How long the pointer must sit in the hot zone before the panel opens.
    var hoverDelay: Double {
        get { defaults.double(forKey: Key.hoverDelay) }
        set { objectWillChange.send(); defaults.set(newValue.clamped(0, 1.5), forKey: Key.hoverDelay) }
    }

    /// Grace period after the pointer leaves the panel, so crossing a gap does not close it.
    var hideDelay: Double {
        get { defaults.double(forKey: Key.hideDelay) }
        set { objectWillChange.send(); defaults.set(newValue.clamped(0, 2), forKey: Key.hideDelay) }
    }

    var cardWidth: Double {
        get { defaults.double(forKey: Key.cardWidth) }
        set { objectWillChange.send(); defaults.set(newValue.clamped(120, 340), forKey: Key.cardWidth) }
    }

    var showTitles: Bool {
        get { defaults.bool(forKey: Key.showTitles) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.showTitles) }
    }

    var clickOutsideDismisses: Bool {
        get { defaults.bool(forKey: Key.clickOutsideDismisses) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.clickOutsideDismisses) }
    }

    /// Whether a restored window is pulled onto the desktop you are on, instead of macOS
    /// sending you to the one it was minimized from.
    ///
    /// Depends on private Space APIs that macOS 26 accepts and then ignores — see
    /// `SpacesBridge`, which measures whether they actually work. The toggle is disabled in
    /// Settings once they are known not to, rather than sitting there quietly lying.
    var openOnCurrentSpace: Bool {
        get { defaults.bool(forKey: Key.openOnCurrentSpace) && SpacesBridge.shared.isUsable }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.openOnCurrentSpace) }
    }

    /// Whether dragging a window against the left edge minimizes it into the panel.
    var dropToMinimize: Bool {
        get { defaults.bool(forKey: Key.dropToMinimize) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.dropToMinimize) }
    }

    /// Where the strip grows from.
    ///
    /// On: the most recently minimized window sits at the vertical middle of the screen and
    /// the rest alternate outward from it, so the newest card is always in the same place —
    /// under the pointer, at eye level — however many there are. Off: a plain list from the
    /// top, which is easier to scan when there are many.
    var centeredStack: Bool {
        get { defaults.bool(forKey: Key.centeredStack) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.centeredStack) }
    }

    /// Whether to draw a panel behind the cards. Off by default — see the registered value.
    var showPanelBackground: Bool {
        get { defaults.bool(forKey: Key.showPanelBackground) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.showPanelBackground) }
    }

    /// Whether hovering the edge opens an empty panel.
    ///
    /// Off by default: with nothing put away there is nothing to come back to, and a panel
    /// sliding out to say so is an interruption charged for brushing the edge on the way
    /// somewhere else. The menu bar item and ⌥⌘S still open it regardless — those are asked
    /// for, and their answer may well be "nothing there".
    var openWhenEmpty: Bool {
        get { defaults.bool(forKey: Key.openWhenEmpty) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.openWhenEmpty) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.launchAtLogin)
            LoginItemService.shared.apply(enabled: newValue)
        }
    }

    /// ⌥⌘S toggles the panel. One fixed combination rather than a recorder: a rebindable
    /// shortcut needs a whole capture UI and a conflict story, and this one is free on a
    /// stock macOS.
    var hotKeyEnabled: Bool {
        get { defaults.bool(forKey: Key.hotKeyEnabled) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.hotKeyEnabled) }
    }

    var hasCompletedWelcome: Bool {
        get { defaults.bool(forKey: Key.hasCompletedWelcome) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.hasCompletedWelcome) }
    }
}

private extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(Swift.max(self, low), high) }
}
