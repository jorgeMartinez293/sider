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
    /// Every window on the Mac, Stage Manager style — settings windows, utility panels and
    /// the windows of menu-bar apps included. Useful on one big screen, noisy on several.
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
        case .allWindows:         return "Every window, including settings windows and the one in front."
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

/// How the sidebar's and the notch's border is drawn.
enum BorderStyle: String, CaseIterable, Identifiable {
    /// Crisp, uniform stroke.
    case line
    /// Uniform stroke with a blurred halo around it.
    case glow
    /// Specular rim light, like the edge of a native macOS widget: brightest where the light
    /// hits (`Preferences.borderLightAngle`), fading out along the outline, with a fainter
    /// bounce on the far side, so the panel reads as a lit slab.
    case sheen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line:  return "Line"
        case .glow:  return "Glow"
        case .sheen: return "Sheen"
        }
    }
}

/// How the panel draws the windows it holds.
enum PanelStyle: String, CaseIterable, Identifiable {
    /// Tilted cards floating straight on the desktop, Stage Manager style. The default.
    case floating
    /// An opaque black bar against the screen edge with the previews flat inside it, and a
    /// bright frame around the one that is selected.
    case sidebar
    /// The sidebar's black surface and flat previews, but only as tall as the windows it
    /// holds: a notch growing sideways out of the middle of the screen edge.
    case notch

    var id: String { rawValue }

    /// Whether the style draws its own opaque black surface with flat previews on it, as
    /// opposed to cards floating on the desktop.
    var isSolid: Bool { self != .floating }

    var title: String {
        switch self {
        case .floating: return "Floating cards"
        case .sidebar:  return "Sidebar"
        case .notch:    return "Notch"
        }
    }

    var detail: String {
        switch self {
        case .floating: return "Tilted previews floating over your desktop."
        case .sidebar:  return "Flat previews in a black bar that runs the height of the screen."
        case .notch:    return "Flat previews in a black notch that grows out of the middle of the edge, as tall as the windows in it."
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
        static let style = "panelStyle"
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
        static let currentDesktopOnly = "currentDesktopOnly"
        static let dropToMinimize = "dropToMinimize"
        static let hideMinimized = "hideMinimized"
        static let centeredStack = "centeredStack"
        static let showPanelBackground = "showPanelBackground"
        static let openWhenEmpty = "openWhenEmpty"
        static let centerOnOpen = "centerOnOpen"
        static let fourFingerSwitch = "fourFingerSwitch"
        static let fiveFingerMinimize = "fiveFingerMinimize"
        static let hapticsEnabled = "hapticsEnabled"
        static let borderEnabled = "borderEnabled"
        static let borderGlow = "borderGlow"
        static let borderStyle = "borderStyle"
        static let borderLightAngle = "borderLightAngle"
        static let borderColor = "borderColor"
        static let borderWidth = "borderWidth"
    }

    /// The border's colour until the user picks one: a faint cool white, so it reads as an
    /// edge of light on the black bar rather than a coloured outline.
    private static let defaultBorderColor: [Double] = [0.956, 0.942, 0.980, 1.0]

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.scope: PanelScope.minimizedOnly.rawValue,
            Key.screen: PanelScreen.underCursor.rawValue,
            Key.style: PanelStyle.floating.rawValue,
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
            Key.currentDesktopOnly: true,
            Key.dropToMinimize: true,
            Key.hideMinimized: false,
            Key.centeredStack: true,
            // Off: the cards are the interface. A backing panel behind them is a second,
            // competing rectangle over whatever you were looking at.
            Key.showPanelBackground: false,
            Key.openWhenEmpty: false,
            Key.centerOnOpen: true,
            Key.fourFingerSwitch: true,
            Key.fiveFingerMinimize: true,
            Key.hapticsEnabled: true,
            // Off: the black bar and notch are already a clear shape against the desktop.
            Key.borderEnabled: false,
            Key.borderGlow: false,
            Key.borderColor: Self.defaultBorderColor,
            Key.borderWidth: 3.0,
            Key.borderLightAngle: 135.0,
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

    var style: PanelStyle {
        get { PanelStyle(rawValue: defaults.string(forKey: Key.style) ?? "") ?? .floating }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Key.style) }
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

    /// Whether the panel only holds windows that belong to the desktop on screen, minimized
    /// ones included. On by default: a window cannot be brought to you from another desktop
    /// (see `SpacesBridge`), so its card would only be a way to get thrown over there.
    ///
    /// Off, the panel collects from every desktop — "every window" then really means every
    /// window, including the open ones on desktops you are not looking at.
    var currentDesktopOnly: Bool {
        get { defaults.bool(forKey: Key.currentDesktopOnly) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.currentDesktopOnly) }
    }

    /// Whether minimized windows are left out of the panel. Only meaningful in the wider
    /// scopes — with `.minimizedOnly` it would leave nothing — so it is ignored there, and
    /// Settings disables the toggle rather than letting it empty the panel.
    var hideMinimized: Bool {
        get { defaults.bool(forKey: Key.hideMinimized) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.hideMinimized) }
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

    /// Whether clicking a minimized window's card puts it in the middle of the screen you are
    /// on. A window that is already open is only raised, never moved.
    ///
    /// On by default. A window that was minimized from the far corner of another display, or
    /// left half off-screen, comes back somewhere you have to go looking for it — which is
    /// the opposite of what a click on its preview asked for. Dragging a card out is
    /// unaffected: there the drop point is the instruction.
    var centerOnOpen: Bool {
        get { defaults.bool(forKey: Key.centerOnOpen) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.centerOnOpen) }
    }

    /// Whether four fingers on the trackpad open the panel and sliding them picks a window.
    ///
    /// Reads the trackpad through a private framework (see `MultitouchBridge`), and clashes
    /// with the system's own four-finger gestures, so it can be turned off.
    var fourFingerSwitch: Bool {
        get { defaults.bool(forKey: Key.fourFingerSwitch) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.fourFingerSwitch) }
    }

    /// Whether tapping the trackpad with five fingers minimizes the window in front.
    var fiveFingerMinimize: Bool {
        get { defaults.bool(forKey: Key.fiveFingerMinimize) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.fiveFingerMinimize) }
    }

    /// Whether the trackpad ticks when the panel opens and when the selection moves between
    /// cards.
    var hapticsEnabled: Bool {
        get { defaults.bool(forKey: Key.hapticsEnabled) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.hapticsEnabled) }
    }

    // MARK: - Border (sidebar and notch styles)

    /// Whether the sidebar and the notch get a coloured border along their free edges.
    var borderEnabled: Bool {
        get { defaults.bool(forKey: Key.borderEnabled) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.borderEnabled) }
    }

    /// How the border is drawn. Before styles existed this was a "glow" toggle, so a value
    /// never chosen falls back to what that toggle said.
    var borderStyle: BorderStyle {
        get {
            if let raw = defaults.string(forKey: Key.borderStyle), let style = BorderStyle(rawValue: raw) {
                return style
            }
            return defaults.bool(forKey: Key.borderGlow) ? .glow : .line
        }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: Key.borderStyle) }
    }

    /// Direction the sheen's light comes FROM, in degrees counterclockwise from the right
    /// (0 = right, 90 = top, 135 = top-left). Only used by `BorderStyle.sheen`.
    var borderLightAngle: Double {
        get { defaults.double(forKey: Key.borderLightAngle) }
        set { objectWillChange.send(); defaults.set(newValue.clamped(0, 360), forKey: Key.borderLightAngle) }
    }

    /// Stored as four sRGB components, since `UserDefaults` has no colour type.
    var borderColor: NSColor {
        get {
            let c = defaults.array(forKey: Key.borderColor) as? [Double] ?? Self.defaultBorderColor
            guard c.count == 4 else { return NSColor(srgbRed: 0.956, green: 0.942, blue: 0.980, alpha: 1) }
            return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
        }
        set {
            // Reading components off a non-RGB colour traps, so convert first.
            let c = newValue.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            objectWillChange.send()
            defaults.set([Double(c.redComponent), Double(c.greenComponent),
                          Double(c.blueComponent), Double(c.alphaComponent)], forKey: Key.borderColor)
        }
    }

    /// Thickness of the border, in points.
    var borderWidth: Double {
        get { defaults.double(forKey: Key.borderWidth) }
        set { objectWillChange.send(); defaults.set(newValue.clamped(1, 12), forKey: Key.borderWidth) }
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
