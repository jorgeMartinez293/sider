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
    private let model = PanelModel()
    private let registry = WindowRegistry.shared
    private let prefs = Preferences.shared

    private(set) var isVisible = false
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
            onRestore: { [weak self] window in self?.restore(window) }
        )
        let hosting = NSHostingView(rootView: root)
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

    func toggle(on screen: NSScreen? = nil) {
        if isVisible { hide() } else { show(on: screen ?? screenUnderPointer()) }
    }

    func show(on screen: NSScreen) {
        let target = frame(on: screen)

        if isVisible {
            // Already up, but the pointer moved to a different display: glide across rather
            // than blink out and back in.
            guard panel.frame != target else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
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

        NSAnimationContext.runAnimationGroup { context in
            context.duration = openDuration
            // easeOut: fast off the edge, settling at the end. The cards' spring picks up
            // where this leaves off.
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }

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

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = closeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(gone, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Only actually order out if nothing re-opened us in the meantime — a fast
            // out-and-back-in would otherwise leave an invisible panel on screen.
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
        })
    }

    /// Current frame, or nil when the panel is not showing. Handed to `EdgeHoverMonitor` so
    /// the pointer resting on a card counts as "still here".
    var visibleFrame: CGRect? { isVisible ? panel.frame : nil }

    // MARK: - Actions

    private func restore(_ window: ManagedWindow) {
        registry.restore(window)
        hide()
        onDismissAfterAction?()
    }

    // MARK: - Dismissal

    private func installDismissMonitors() {
        if prefs.clickOutsideDismisses, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                // Global monitors only see events destined for *other* apps, so a click on a
                // card never reaches here — no need to test the location.
                self?.hide()
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
