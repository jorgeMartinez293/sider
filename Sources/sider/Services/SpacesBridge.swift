import AppKit
import CoreGraphics

/// Moves a window to the Space (desktop) the user is looking at right now.
///
/// macOS remembers which Space a window belonged to and sends it back there when it is
/// un-minimized — which for sider is the wrong behaviour outright. The panel follows you
/// across Spaces (`.canJoinAllSpaces`), so you can be on desktop 3, click a card, and be
/// yanked to desktop 1 where that window happened to live. The window you asked for should
/// come to you, not the other way round.
///
/// There is **no public API** for this. The Space APIs are private SkyLight/CoreGraphics
/// symbols — the same ones yabai, Amethyst and Hammerspoon use — resolved here with `dlsym`
/// rather than `@_silgen_name` on purpose: an undefined symbol bound at link time would stop
/// the whole app launching if Apple ever drops one, while a nil lookup here simply turns this
/// feature off and leaves macOS's own "go back to the original Space" behaviour in place.
///
/// Everything is best-effort and silent on failure.
enum SpacesBridge {

    private typealias ConnectionID = Int32
    private typealias SpaceID = UInt64

    private typealias MainConnectionFn = @convention(c) () -> ConnectionID
    private typealias ActiveSpaceFn = @convention(c) (ConnectionID) -> SpaceID
    private typealias MoveWindowsFn = @convention(c) (ConnectionID, CFArray, SpaceID) -> Void

    /// RTLD_DEFAULT — searches every image already loaded into the process, which includes
    /// CoreGraphics/SkyLight.
    private static let allImages = UnsafeMutableRawPointer(bitPattern: -2)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let sym = dlsym(allImages, name) else {
            Logger.log("SpacesBridge: \(name) unavailable — windows will reopen on their original desktop")
            return nil
        }
        return unsafeBitCast(sym, to: type)
    }

    private static let mainConnectionID = symbol("CGSMainConnectionID", as: MainConnectionFn.self)
    private static let getActiveSpace = symbol("CGSGetActiveSpace", as: ActiveSpaceFn.self)
    private static let moveWindows = symbol("CGSMoveWindowsToManagedSpace", as: MoveWindowsFn.self)

    /// Whether the private symbols this needs are all present on this system.
    static var isAvailable: Bool {
        mainConnectionID != nil && getActiveSpace != nil && moveWindows != nil
    }

    /// Moves `windowID` onto the Space that is on screen right now.
    ///
    /// Safe to call while the window is still minimized: a minimized window keeps its
    /// `CGWindowID` and its Space assignment, so re-assigning it *before* un-minimizing is
    /// what avoids the visible Space-switch-and-switch-back that doing it afterwards causes.
    @discardableResult
    static func moveToActiveSpace(_ windowID: CGWindowID) -> Bool {
        guard let mainConnectionID, let getActiveSpace, let moveWindows else { return false }
        let cid = mainConnectionID()
        let space = getActiveSpace(cid)
        guard space != 0 else { return false }
        moveWindows(cid, [NSNumber(value: windowID)] as CFArray, space)
        return true
    }
}
