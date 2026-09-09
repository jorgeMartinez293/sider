import AppKit
import SwiftUI

/// Owns the edge panel window: where it sits, and how it comes and goes.
///
/// The window is a non-activating `NSPanel`, which is what lets you click a card without the
/// app you are looking at losing focus first — the point of the panel is to *get somewhere
/// else*, and a two-step "focus sider, then focus the window you wanted" would undo that.
///
/// Opening is two animations running together, and both matter:
///
///  * the window itself slides in from behind the screen edge and fades up, so the panel
///    reads as coming *out of* the edge rather than being drawn on top of it;
///  * the cards inside fly in from the same direction on a spring, staggered top to bottom
///    (see `WindowCardView`), so the strip assembles instead of appearing.
///
/// Closing reverses only the first: everything leaves together, because a staggered exit
/// reads as the panel struggling to get out of the way.
final class SiderPanelController {

    private let panel: SiderPanel
    private let dragProxy = DragProxyWindow()
    private let model = PanelModel()
    private let registry = WindowRegistry.shared
    private let prefs = Preferences.shared

    private(set) var isVisible = false
    private var slideTimer: Timer?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?

    /// Set by AppDelegate so a click on a card can also stand the hover monitor down for a
    /// moment — the pointer is left sitting where the card was, which on a narrow panel can
    /// be inside the hot zone, and the panel would bounce straight back open.
    var onDismissAfterAction: (() -> Void)?

    private let openDuration: TimeInterval = 0.32
    private let closeDuration: TimeInterval = 0.24

    /// Where the window sits when it is "away": entirely past the left edge of `frame`'s
    /// screen, not merely nudged toward it.
    ///
    /// A short nudge plus a fade reads as the panel materialising in place. Travelling its
    /// own full width means the last thing you see on close is the panel's trailing edge
    /// disappearing into the side of the screen, and the first thing you see on open is that
    /// same edge coming back out of it — which is the whole illusion the panel trades on.
    private func offscreenFrame(for target: NSRect) -> NSRect {
        var away = target
        away.origin.x = target.minX - target.width - 16
        return away
    }

    init() {
        panel = SiderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false          // the cards cast their own; a window shadow doubles them
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        // .canJoinAllSpaces + .fullScreenAuxiliary: the panel follows you between Spaces and
        // is available over another app's full-screen window, which is exactly where hunting
        // for a minimized window is most annoying without it.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none  // all motion is driven explicitly below

        let root = SiderPanelView(
            registry: registry,
            prefs: prefs,
            model: model,
            onRestore: { [weak self] window in self?.restore(window) },
            onDragChanged: { [weak self] window, point in self?.cardDragChanged(window, at: point) },
            onDragEnded: { [weak self] window, point in self?.cardDragEnded(window, at: point) }
        )
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.alphaValue = 0
    }

    // MARK: - Geometry

    /// Panel frame for `screen`, in screen coordinates.
    ///
    /// `visibleFrame`, not `frame`: it already excludes the menu bar and a pinned Dock, so a
    /// Dock on the left pushes the panel clear of it instead of hiding behind it.
    private func frame(on screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame
        // Card + the strip's 6pt container padding on each side + the per-card slack the
        // hover state needs on each side (`WindowCardView.hoverHeadroom`), plus a little
        // over so the hover shadow has somewhere to fall.
        let width = CGFloat(prefs.cardWidth) + 12 + WindowCardView.hoverHeadroom * 2 + 8
        return NSRect(x: area.minX + 8,
                      y: area.minY + 12,
                      width: width,
                      height: area.height - 24)
    }

    // MARK: - Show / hide

    /// Menu bar and ⌥⌘S. `force` because these are asked for outright, and "nothing there"
    /// is a legitimate answer to an explicit request — unlike to a pointer that brushed the
    /// screen edge on its way somewhere else.
    func toggle(on screen: NSScreen? = nil) {
        if isVisible { hide() } else { show(on: screen ?? screenUnderPointer(), force: true) }
    }

    /// Whether there is anything worth sliding out for.
    ///
    /// A missing permission counts: the panel is the only place that explains why sider looks
    /// dead, and suppressing it would leave a freshly installed app that does nothing at all
    /// with no way to find out why.
    private var hasSomethingToShow: Bool {
        !registry.windows.isEmpty
            || registry.needsAccessibility
            || !ThumbnailService.shared.hasPermission
    }

    func show(on screen: NSScreen, force: Bool = false) {
        // An empty panel sliding out to announce that it is empty is an interruption charged
        // for touching the edge. With nothing put away there is nothing to come back to, so
        // the hover does nothing at all.
        guard force || prefs.openWhenEmpty || hasSomethingToShow else { return }

        let target = frame(on: screen)

        if isVisible {
            // Already up, but the pointer moved to a different display: glide across rather
            // than blink out and back in.
            guard panel.frame != target else { return }
            slide(to: target, alpha: 1, duration: 0.2, curve: .easeInOut)
            return
        }

        isVisible = true
        registry.setPanelVisible(true)
        ThumbnailService.shared.refreshVisible()

        // Start fully off the side of the screen and transparent, so the first frame the
        // user sees is the panel already on its way out rather than sitting at its
        // destination.
        panel.setFrame(offscreenFrame(for: target), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        // easeOut: fast off the edge, settling at the end. The cards' spring picks up where
        // this leaves off.
        slide(to: target, alpha: 1, duration: openDuration, curve: .easeOut)

        // Flipping this after the window is on screen is what gives the cards real frames to
        // spring in from; set before `orderFrontRegardless` they would animate off-screen and
        // simply appear finished.
        DispatchQueue.main.async { self.model.isOpen = true }

        installDismissMonitors()
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        registry.setPanelVisible(false)
        removeDismissMonitors()

        model.isOpen = false
        model.hovered = nil

        let gone = offscreenFrame(for: panel.frame)

        slide(to: gone, alpha: 0, duration: closeDuration, curve: .easeIn) { [weak self] in
            // Only actually order out if nothing re-opened us in the meantime — a fast
            // out-and-back-in would otherwise leave an invisible panel on screen.
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Takes key status so clicks and drags reach the cards.
    ///
    /// Called when the pointer actually enters the panel, **not** when the panel opens. Both
    /// halves of that matter:
    ///
    ///  * It has to happen. In a window that is not key, every click is a "first click", which
    ///    AppKit spends on focusing the window unless the view under it accepts first mouse —
    ///    and the views under it are ones SwiftUI builds internally, which do not. Clicking a
    ///    card would need two clicks, and a drag-out would never start.
    ///  * It must not happen on open. The panel opens from a hover, so tying key status to
    ///    that would take the keyboard away from whatever you were typing in every time you
    ///    brushed the left edge. Waiting for the pointer to come inside costs nothing — you
    ///    cannot click a card without going there first — and leaves a glance at the strip
    ///    completely non-disruptive.
    ///
    /// `.nonactivatingPanel` is what makes this safe: the panel takes key status without
    /// making sider the active app, so the app in front stays in the foreground and gets the
    /// keyboard straight back when the panel closes.
    func focusForInteraction() {
        guard isVisible, !panel.isKeyWindow else { return }
        panel.makeKey()
    }

    /// Current frame, or nil when the panel is not showing. Handed to `EdgeHoverMonitor` so
    /// the pointer resting on a card counts as "still here".
    var visibleFrame: CGRect? { isVisible ? panel.frame : nil }

    // MARK: - Drop target (a window dragged to the edge)

    /// Opens the panel as a place to drop the window currently being dragged. No dwell, no
    /// delay: the user is already holding something and pointing at the edge, which is as
    /// deliberate as an intent gets.
    func showAsDropTarget(on screen: NSScreen) {
        model.isDropTarget = true
        // Forced: an empty strip is exactly the case where the user most needs to see where
        // the window they are holding is about to go.
        show(on: screen, force: true)
    }

    /// The drag moved away, or ended. The panel itself is left alone — the pointer is still at
    /// the edge, so the ordinary hover rules should decide when it closes, not this.
    func endDropTarget() {
        model.isDropTarget = false
    }

    // MARK: - Actions

    private func restore(_ window: ManagedWindow) {
        registry.restore(window)
        hide()
        onDismissAfterAction?()
    }

    // MARK: - Dragging a card out

    /// True while a card is being dragged out. The hover monitor consults this and refuses to
    /// auto-close the panel: the pointer is deliberately far outside it, which every other
    /// rule in this app reads as "leave".
    var isDraggingCard: Bool { model.dragging != nil }

    private func cardDragChanged(_ window: ManagedWindow, at point: CGPoint) {
        if model.dragging != window.id {
            model.dragging = window.id
            // The card's own picture, at the card's own width, so picking it up is continuous
            // rather than a swap to some other representation.
            dragProxy.show(ThumbnailService.shared.image(for: window.windowID) ?? window.appIcon,
                           width: CGFloat(prefs.cardWidth),
                           at: point)
        }
        dragProxy.move(to: point)
    }

    private func cardDragEnded(_ window: ManagedWindow, at point: CGPoint) {
        model.dragging = nil
        model.hovered = nil
        dragProxy.hide()

        // Released back over the panel: treat it as a cancel and leave the window where it is.
        // The margin matches the one the hover monitor forgives, so "still on the strip" means
        // the same thing to both.
        let overPanel = panel.frame.insetBy(dx: -24, dy: -8).contains(point)
        guard !overPanel else { return }

        registry.restore(window, at: point)
        hide()
        onDismissAfterAction?()
    }

    // MARK: - Dismissal

    private func installDismissMonitors() {
        if prefs.clickOutsideDismisses, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self else { return }
                // "Global monitors only see other apps' events" is not something to rely on
                // for a non-activating panel in an accessory app: a press on the panel itself
                // arrives here too, and closing on it made every click and every drag-out
                // die the instant it began. Test the location instead.
                let point = NSEvent.mouseLocation
                guard !self.panel.frame.insetBy(dx: -6, dy: -6).contains(point) else { return }
                self.hide()
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }   // Escape
                self?.hide()
                return nil
            }
        }
    }

    private func removeDismissMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
    }

    // MARK: - Sliding

    private enum Curve {
        case easeOut, easeIn, easeInOut

        /// Standard cubic easings on a 0…1 progress.
        func apply(_ t: Double) -> Double {
            switch self {
            case .easeOut:   return 1 - pow(1 - t, 3)
            case .easeIn:    return t * t * t
            case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            }
        }
    }

    /// Moves and fades the panel, interpolated frame by frame on a timer.
    ///
    /// This is deliberately not `NSAnimationContext` + `window.animator()`, which is the
    /// obvious way to write it and does not work here: on this panel the proxy's `setFrame`
    /// and `alphaValue` were dropped outright — not animated *and* not applied, so the panel
    /// stayed parked off-screen at alpha 0 while every other part of the app believed it was
    /// open. Nothing in the API reports that; it just silently does nothing.
    ///
    /// Driving the interpolation directly is a dozen lines, always applies the final value,
    /// and puts the easing curve in plain sight instead of behind a `CAMediaTimingFunction`
    /// name.
    private func slide(to target: NSRect, alpha: CGFloat, duration: TimeInterval,
                       curve: Curve, completion: (() -> Void)? = nil) {
        slideTimer?.invalidate()

        let startFrame = panel.frame
        let startAlpha = panel.alphaValue
        let began = CACurrentMediaTime()

        let step = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let raw = min((CACurrentMediaTime() - began) / duration, 1)
            let t = curve.apply(raw)

            var frame = startFrame
            frame.origin.x = startFrame.minX + (target.minX - startFrame.minX) * t
            frame.origin.y = startFrame.minY + (target.minY - startFrame.minY) * t
            frame.size.width = startFrame.width + (target.width - startFrame.width) * t
            frame.size.height = startFrame.height + (target.height - startFrame.height) * t
            self.panel.setFrame(frame, display: false)
            self.panel.alphaValue = startAlpha + (alpha - startAlpha) * t

            guard raw >= 1 else { return }
            timer.invalidate()
            self.slideTimer = nil
            // Land exactly on the target: 60 interpolated steps accumulate enough rounding to
            // leave the panel a fraction of a point off, which shows up as a soft edge.
            self.panel.setFrame(target, display: true)
            self.panel.alphaValue = alpha
            completion?()
        }
        // .common so the slide keeps running while a menu is open or a scroll is tracking.
        RunLoop.main.add(step, forMode: .common)
        slideTimer = step
    }

    private func screenUnderPointer() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}

/// A borderless panel has to opt back into being able to take the keyboard, or Escape and
/// scrolling with the arrow keys do nothing. `.nonactivatingPanel` keeps that from pulling
/// the app you were using out of the foreground.
/// A view in a window that is not key does not receive the first click — AppKit spends it on
/// bringing the window forward instead. For an ordinary window that is right; for this panel
/// it is fatal, since the panel deliberately never becomes the active app's key window and
/// *every* interaction is a first click. Without this, clicking a card did nothing and a
/// drag-out never started.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

final class SiderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit's default implementation keeps a window on screen. The open and close
    /// animations deliberately park this one entirely past the screen's left edge, and
    /// without this override AppKit quietly clamps it back — the panel then fades in place
    /// instead of sliding in from the side, with nothing in the code to explain why.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
