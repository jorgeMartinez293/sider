import AppKit

/// The thumbnail that follows the pointer while a card is dragged out of the panel.
///
/// It has to be its own window. The card itself lives inside a `ScrollView` inside the panel,
/// which clips to its bounds, so a card dragged past the panel's edge would simply be cut off
/// — and the whole gesture is about taking the window *out* of the strip. A separate
/// borderless window has no such bounds, and being `ignoresMouseEvents` it never interrupts
/// the drag it is illustrating.
final class DragProxyWindow {

    private let window: NSWindow
    private let imageView = NSImageView()
    /// Where the pointer sits inside the proxy, so the image does not jump under the cursor
    /// on the first frame.
    private var grabOffset = CGSize(width: 0.5, height: 0.5)

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 120),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        // Above the panel and above any window being dragged past it.
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.animationBehavior = .none

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.cornerCurve = .continuous
        imageView.layer?.masksToBounds = true
        window.contentView = imageView
    }

    var isVisible: Bool { window.isVisible }

    func show(_ image: NSImage?, width: CGFloat, at point: CGPoint) {
        imageView.image = image
        let ratio = (image?.size.height ?? 120) / max(image?.size.width ?? 180, 1)
        let size = NSSize(width: width, height: max(width * ratio, 60))
        window.setContentSize(size)
        // Slightly smaller than the card it came from, so it reads as "picked up".
        window.alphaValue = 0
        move(to: point)
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 0.92
        }
    }

    func move(to point: CGPoint) {
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: point.x - size.width * grabOffset.width,
                                      y: point.y - size.height * grabOffset.height))
    }

    func hide() {
        guard window.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window.orderOut(nil)
        })
    }
}
