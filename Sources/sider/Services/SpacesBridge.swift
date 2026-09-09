import AppKit
import Combine
import CoreGraphics

/// Tries to move a window to the Space (desktop) the user is looking at right now — and
/// notices when macOS refuses.
///
/// **The problem.** macOS remembers which Space a window belonged to and sends you back there
/// when it is un-minimized. The panel follows you across Spaces (`.canJoinAllSpaces`), so you
/// can be on desktop 3, click a card, and be thrown to desktop 1. The window you asked for
/// should come to you.
///
/// **The catch.** There is no public API, and as of macOS 26 the private ones do not work
/// either. Measured on a signed build with Accessibility granted:
///
/// | Call | Result |
/// |---|---|
/// | `CGSMoveWindowsToManagedSpace` | returns cleanly, window stays on its Space |
/// | `CGSAddWindowsToSpaces` / `CGSRemoveWindowsFromSpaces` | same |
/// | `CGSSetWindowTags` with the all-Spaces tag | `rc == 0`, no effect |
///
/// They are not gone — `dlsym` finds every one of them and they report success. The
/// WindowServer simply ignores the write. This is the same wall yabai hits, and why it needs
/// SIP partially disabled for exactly this feature.
///
/// **So this measures instead of assuming.** The first time a move is attempted on a window
/// that is genuinely on another Space, the result is checked a moment later and
/// `availability` settles on `.working` or `.blocked`. Settings reads it and stops offering a
/// switch that cannot do anything, rather than leaving a checkbox that quietly lies. If a
/// future macOS reopens this, or the user runs with SIP off, it starts working on its own
/// with nothing to change.
final class SpacesBridge: ObservableObject {
    static let shared = SpacesBridge()

    enum Availability {
        /// No conclusive attempt yet — a window already on the current Space proves nothing.
        case untested
        /// A window really did move.
        case working
        /// The call was accepted and the window did not move.
        case blocked
        /// The private symbols are not present at all.
        case unavailable
    }

    @Published private(set) var availability: Availability

    private typealias ConnectionID = Int32
    private typealias SpaceID = UInt64

    private typealias MainConnectionFn = @convention(c) () -> ConnectionID
    private typealias ActiveSpaceFn = @convention(c) (ConnectionID) -> SpaceID
    private typealias MoveWindowsFn = @convention(c) (ConnectionID, CFArray, SpaceID) -> Void
    private typealias SpacesForWindowsFn = @convention(c) (ConnectionID, UInt32, CFArray) -> CFArray

    /// RTLD_DEFAULT — searches every image already loaded into the process, which includes
    /// CoreGraphics/SkyLight.
    private static let allImages = UnsafeMutableRawPointer(bitPattern: -2)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let sym = dlsym(allImages, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    private let mainConnectionID = symbol("CGSMainConnectionID", as: MainConnectionFn.self)
    private let getActiveSpace = symbol("CGSGetActiveSpace", as: ActiveSpaceFn.self)
    private let moveWindows = symbol("CGSMoveWindowsToManagedSpace", as: MoveWindowsFn.self)
    private let spacesForWindows = symbol("CGSCopySpacesForWindows", as: SpacesForWindowsFn.self)

    private init() {
        let present = mainConnectionID != nil && getActiveSpace != nil
            && moveWindows != nil && spacesForWindows != nil
        availability = present ? .untested : .unavailable
        if !present {
            Logger.log("SpacesBridge: private Space symbols unavailable")
        }
    }

    /// Whether it is worth offering the feature at all.
    var isUsable: Bool {
        switch availability {
        case .untested, .working: return true
        case .blocked, .unavailable: return false
        }
    }

    /// Asks the WindowServer to put `windowID` on the Space that is on screen right now.
    ///
    /// Safe to call while the window is still minimized — a minimized window keeps its
    /// `CGWindowID` and its Space assignment — and worth doing *before* un-minimizing, since
    /// doing it afterwards is what would make macOS switch you there and back.
    func moveToActiveSpace(_ windowID: CGWindowID) {
        guard isUsable,
              let mainConnectionID, let getActiveSpace, let moveWindows else { return }

        let cid = mainConnectionID()
        let space = getActiveSpace(cid)
        guard space != 0 else { return }

        let before = spaces(of: windowID, cid: cid)
        moveWindows(cid, [NSNumber(value: windowID)] as CFArray, space)

        // Only a window that was somewhere else can tell us anything, and the WindowServer
        // needs a moment to apply the change. Checked asynchronously so the restore this is
        // part of never waits on a diagnostic.
        guard !before.isEmpty, !before.contains(Int(space)) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.availability == .untested else { return }
            let moved = self.spaces(of: windowID, cid: cid).contains(Int(space))
            self.availability = moved ? .working : .blocked
            if !moved {
                Logger.log("SpacesBridge: the WindowServer accepted the move and ignored it — "
                    + "this macOS does not let apps move windows between Spaces")
            }
        }
    }

    private func spaces(of windowID: CGWindowID, cid: ConnectionID) -> [Int] {
        guard let spacesForWindows else { return [] }
        // 7 = all Space types.
        return spacesForWindows(cid, 7, [NSNumber(value: windowID)] as CFArray) as? [Int] ?? []
    }
}
