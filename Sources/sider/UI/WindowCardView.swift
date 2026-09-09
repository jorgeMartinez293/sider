import AppKit
import SwiftUI

/// One window in the panel: its last picture, tilted in 3D the way Stage Manager tilts the
/// cards in its strip.
///
/// The tilt is a `rotation3DEffect` about the vertical axis anchored at the card's trailing
/// edge, so the edge nearest the screen border swings *away* from the viewer and the edge
/// nearest the content swings toward it. That is the direction Stage Manager uses on the
/// left, and it is what makes a flat rectangle read as a card standing in space rather than
/// a screenshot pasted on the desktop.
///
/// Hovering flattens the card (tilt → 0) and lifts it slightly. Flattening is the important
/// half: a tilted card is decoration, and the moment the pointer is on it, it becomes a
/// target, so it should square up to be read and clicked.
struct WindowCardView: View {
    let window: ManagedWindow
    let index: Int
    let width: CGFloat
    let showTitle: Bool

    @ObservedObject private var thumbnails = ThumbnailService.shared
    @ObservedObject var model: PanelModel

    let onRestore: () -> Void
    let onClose: () -> Void
    let onMinimize: () -> Void
    /// Called with the pointer's screen position while the card is being dragged out, and
    /// once more when it is released.
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void

    /// Resting angle. Small on purpose — Stage Manager's own strip is around 8–12°, and past
    /// roughly 15° the near edge of a wide card starts to clip through the screen border.
    private let restingTilt: Double = 11

    /// Slack reserved around the card inside the scrolling strip.
    ///
    /// A tilted card is *narrower* than its layout frame — perspective pulls the receding
    /// edge inward. Flattening it on hover gives that width back and then scales it up, and
    /// `scaleEffect` does not participate in layout, so the extra pixels land outside the
    /// frame. The enclosing `ScrollView` clips to its bounds, so without this padding the
    /// hovered card is sliced down its leading edge — the exact thing that looks broken,
    /// because it only happens to the card you are pointing at.
    ///
    /// Sized for the worst case: 4% of the widest card growing leftward from the trailing
    /// anchor, and the hover shadow (radius 16, x-offset 6) reaching right.
    static let hoverHeadroom: CGFloat = 16

    /// How far the pointer must travel before a press counts as dragging the card out rather
    /// than clicking it. Below this a click still just restores the window where it was.
    private static let dragThreshold: CGFloat = 8

    private func isDragFar(_ translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) > Self.dragThreshold
    }

    private var isHovered: Bool { model.hovered == window.id }
    private var isDragging: Bool { model.dragging == window.id }

    /// 20% of the card's width, held to a sane range for very small and very large cards.
    private var badgeSize: CGFloat { (width * 0.20).clamped(30, 56) }

    private var height: CGFloat {
        let ratio = window.frame.height / max(window.frame.width, 1)
        return (width * ratio).clamped(90, 190)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The tilt is on the preview alone, not on the whole card. Rotating the caption
            // with it magnifies the near end of the text (perspective does that to anything
            // it touches) and pushes the first characters off the left of the panel, which
            // is exactly what it looked like the first time: "Claude" rendered as "aude".
            // Stage Manager does the same thing — the picture is in space, the label is flat.
            preview
                .rotation3DEffect(
                    // NEGATIVE: rotating the other way brings the leading edge *toward* the
                    // viewer, which magnifies it and pushes it past the window's left edge.
                    // This sign pushes the edge nearest the screen border away instead,
                    // which is the direction Stage Manager tilts its strip.
                    .degrees(isHovered ? 0 : -restingTilt),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .trailing,
                    // Shallow. A stronger perspective (larger value) exaggerates the near
                    // edge until the card looks like it is falling out of the screen.
                    perspective: 0.4
                )
                .scaleEffect(isHovered ? 1.04 : 1.0, anchor: .trailing)
                .shadow(color: .black.opacity(isHovered ? 0.34 : 0.22),
                        radius: isHovered ? 16 : 9, x: isHovered ? 6 : 3, y: 5)
                .animation(.spring(response: 0.34, dampingFraction: 0.72), value: isHovered)
            if showTitle { caption }
        }
        .frame(width: width, alignment: .leading)
        // Reserves the slack the hover state needs; see `hoverHeadroom`.
        .padding(.horizontal, Self.hoverHeadroom)
        .contentShape(Rectangle())
        // Entrance: cards fly in from the screen edge, each a beat after the one above it,
        // so the strip assembles top-down instead of appearing all at once.
        // Short, because the window itself now travels its whole width. This is the
        // second-order motion on top of that — enough to read as a stagger, not enough to
        // look like the cards are racing the panel they live in.
        .offset(x: model.isOpen ? 0 : -26)
        .opacity(model.isOpen ? 1 : 0)
        .animation(
            .spring(response: 0.42, dampingFraction: 0.8)
                // Only the entrance is staggered. On the way out everything leaves together —
                // a staggered exit reads as the panel struggling to close.
                .delay(model.isOpen ? Double(index) * 0.035 : 0),
            value: model.isOpen
        )
        // Dimmed while the DragProxyWindow carries its picture under the pointer, so the
        // strip shows where the card came from without two copies of it on screen.
        .opacity(isDragging ? 0.25 : 1)
        .onHover { model.hovered = $0 ? window.id : (model.hovered == window.id ? nil : model.hovered) }
        // Click and drag-out are ONE gesture, decided at the end by how far the pointer
        // travelled. A separate `.onTapGesture` alongside a `DragGesture` looks equivalent and
        // is not: SwiftUI resolves the two against each other and the tap wins, so the
        // drag-out silently never starts. One gesture has no such contest.
        //
        // Positions come from `NSEvent.mouseLocation`, not from the gesture value: SwiftUI's
        // `.global` space is global to the *window*, and the point that matters here is on the
        // screen, usually well outside this one.
        //
        // The close button is a child view, and child gestures outrank a parent's, so it still
        // gets its own clicks.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard isDragFar(value.translation) else { return }
                    onDragChanged(NSEvent.mouseLocation)
                }
                .onEnded { value in
                    if isDragFar(value.translation) {
                        onDragEnded(NSEvent.mouseLocation)
                    } else {
                        onRestore()
                    }
                }
        )
        .contextMenu {
            Button(window.isMinimized ? "Bring Back" : "Bring to Front", action: onRestore)
            if !window.isMinimized {
                Button("Minimize", action: onMinimize)
            }
            Divider()
            Button("Close Window", action: onClose)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.appName): \(window.displayTitle)")
        .accessibilityHint("Brings this window back to the front")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)

            if let image = thumbnails.image(for: window.windowID) {
                Image(nsImage: image)
                    .resizable()
                    // .fill, cropped to the card: window aspect ratios vary wildly (a
                    // terminal strip next to a full-screen browser) and letterboxing every
                    // one of them makes the strip look like a broken table.
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                fallbackArt
            }

            // App icon badge, so a window is identifiable at a glance even when its picture
            // is a wall of text or was never captured.
            //
            // Sized against the card, not fixed: at a 200pt card this is 40pt, and it stays
            // in proportion when the card is made bigger or smaller from Settings. The badge
            // is often the *only* thing read at a glance — a shrunken window screenshot is
            // rarely legible — so it earns the space.
            if let icon = window.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: badgeSize, height: badgeSize)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                    .padding(8)
            }

            if isHovered {
                closeButton
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(isHovered ? 0.35 : 0.14), lineWidth: 1)
        )
    }

    /// Shown until the first capture lands, and for any window that was already minimized
    /// when sider started — sider never saw it on screen, so there is nothing to show.
    private var fallbackArt: some View {
        ZStack {
            LinearGradient(colors: [.gray.opacity(0.28), .gray.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let icon = window.appIcon {
                // Bigger than the badge: with no screenshot this *is* the card, and it is
                // all there is to recognise the window by.
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: badgeSize * 1.9, height: badgeSize * 1.9)
                    .opacity(0.6)
            }
        }
        .frame(width: width, height: height)
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help("Close this window")
                .padding(6)
            }
            Spacer()
        }
        .frame(width: width, height: height)
    }

    // MARK: - Caption

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(window.displayTitle)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(window.appName)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // With the panel background off, these labels sit directly on the desktop, which can
        // be any colour at all. A soft dark halo keeps them readable on a light wallpaper
        // without turning into a visible outline on a dark one.
        .shadow(color: .black.opacity(0.55), radius: 3)
        .padding(.horizontal, 2)
        // Hard width limit. Without it a long window title lays itself out wider than the
        // card and is clipped by the panel's edge rather than truncated with an ellipsis.
        .frame(width: width, alignment: .leading)
    }
}

extension CGFloat {
    func clamped(_ low: CGFloat, _ high: CGFloat) -> CGFloat { Swift.min(Swift.max(self, low), high) }
}
