import AppKit
import SwiftUI

/// The contents of the edge panel: a vertical strip of window cards, drawn in one of the two
/// `PanelStyle`s.
struct SiderPanelView: View {
    @ObservedObject var registry: WindowRegistry
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: PanelModel
    @ObservedObject var thumbnails = ThumbnailService.shared

    let onRestore: (ManagedWindow) -> Void
    let onDragChanged: (ManagedWindow, CGPoint) -> Void
    let onDragEnded: (ManagedWindow, CGPoint) -> Void

    @Environment(\.colorScheme) private var systemScheme

    private var cardWidth: CGFloat { CGFloat(prefs.cardWidth) }
    private var isSidebar: Bool { prefs.style == .sidebar }
    private var isNotch: Bool { prefs.style == .notch }

    /// Height of whatever the panel is showing — the stack of cards, or a notice — as laid
    /// out. The notch is sized around it.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if prefs.showPanelBackground && !prefs.style.isSolid { backdrop }
            if model.isDropTarget {
                if isNotch {
                    inNotch(inset: NotchBackdrop.flareRadius) { dropTargetOverlay }
                } else {
                    dropTargetOverlay
                }
            }

            content
                // Small, because each card carries its own horizontal slack for the hover
                // state (`WindowCardView.hoverHeadroom`). Padding the container instead
                // would put the gap *outside* the ScrollView's clip, where it does the
                // hovered card no good.
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        // The notch's window does not slide (see `SiderPanelController.slidesWindow`); its
        // contents ride out with the notch's leading edge instead, clipped by the mask below.
        .offset(x: isNotch && !model.isOpen ? -(cardWidth + 12 + WindowCardView.hoverHeadroom * 2) : 0)
        .animation(notchReveal, value: model.isOpen)
        // A strip too tall for the screen scrolls, and must not scroll out of the notch.
        .mask {
            if isNotch { notchSilhouette } else { Rectangle() }
        }
        // The window is wider than the bar by its flares; everything else stays on the bar.
        .padding(.trailing, isSidebar ? SidebarBackdrop.flareRadius : 0)
        .overlay { border }
        .background {
            if isSidebar { SidebarBackdrop().fill(.black) }
            if isNotch { notchSilhouette }
        }
        // On black regardless of the system appearance, or the captions are black on black.
        .environment(\.colorScheme, prefs.style.isSolid ? .dark : systemScheme)
    }

    // MARK: - The border

    /// The coloured edge along the sidebar's or the notch's free sides. Drawn on top of the
    /// cards' container but inside the 6pt strip margin, so it never touches a preview.
    @ViewBuilder
    private var border: some View {
        if prefs.borderEnabled && prefs.style.isSolid {
            let color = Color(nsColor: prefs.borderColor)
            let width = CGFloat(prefs.borderWidth)
            if isNotch {
                inNotch {
                    PanelEdgeBorder(shape: NotchBackdrop(reveal: model.isOpen ? 1 : 0),
                                    color: color, width: width, style: prefs.borderStyle,
                                    lightAngle: prefs.borderLightAngle)
                        .animation(notchReveal, value: model.isOpen)
                }
            } else {
                PanelEdgeBorder(shape: SidebarBackdrop(), color: color, width: width,
                                style: prefs.borderStyle, lightAngle: prefs.borderLightAngle)
            }
        }
    }

    // MARK: - The notch

    /// Black above and below the content, inside the notch. With the stack's own 2pt this
    /// comes to what a card has beside it — the strip's 6pt plus `hoverHeadroom` — so the
    /// margin is the same on all three free sides.
    private static let notchPadding: CGFloat = 6 + WindowCardView.hoverHeadroom - 2

    private var notchSilhouette: some View {
        inNotch {
            NotchBackdrop(reveal: model.isOpen ? 1 : 0)
                .fill(.black)
                .animation(notchReveal, value: model.isOpen)
        }
    }

    /// The durations the controller slides the other styles' windows with, and its ease-out
    /// on the way in — but not its ease-in on the way out.
    ///
    /// A window leaving the screen can accelerate: its fastest frames are the ones where it
    /// is already mostly gone. The notch never leaves — it ends *at* the edge, in full view,
    /// so an ease-in spends its last three frames covering half the travel and reads as the
    /// notch being snatched away. This one moves most in the middle and settles into the
    /// edge, which is also when the flares fold back in.
    private var notchReveal: Animation {
        model.isOpen ? .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.32)
                     : .timingCurve(0.4, 0, 0.2, 1, duration: 0.24)
    }

    /// Places `content` where the notch is: as tall as what the panel is showing (never
    /// taller than the room between the menu bar and the Dock), and centred on the same
    /// line the stack is centred on. `inset` trims the top and bottom, for content that
    /// belongs on the notch's body and not on its flares.
    private func inNotch<Content: View>(inset: CGFloat = 0,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        let content = content()
        return GeometryReader { geo in
            let room = max(0, geo.size.height - model.topInset - model.bottomInset)
            let height = min(contentHeight + (Self.notchPadding + NotchBackdrop.flareRadius) * 2, room)
            content
                .frame(width: geo.size.width, height: max(0, height - inset * 2))
                .offset(y: model.topInset + (room - height) / 2 + inset)
                // Grows and shrinks from its middle as windows come and go.
                .animation(.spring(response: 0.36, dampingFraction: 0.82), value: contentHeight)
        }
    }

    /// Optional backing panel. Off by default: the cards already read as objects in front of
    /// the desktop, and a second rectangle behind them competes with whatever the user was
    /// actually looking at.
    private var backdrop: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .opacity(model.isOpen ? 0.92 : 0)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    .opacity(model.isOpen ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.22), value: model.isOpen)
    }

    /// Shown while a window is being dragged at the edge. The panel opening on its own
    /// mid-drag needs an explanation, or it reads as a glitch instead of an invitation.
    /// Drawn whether or not the backdrop is on — it is the one moment the strip's *bounds*
    /// are the message.
    private var dropTargetOverlay: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .foregroundStyle(.tint)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(0.13))
            )
            .overlay(alignment: .bottom) {
                Label("Drop to minimize", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 18)
            }
            .transition(.opacity)
            .zIndex(1)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.16), value: model.isDropTarget)
    }

    @ViewBuilder
    private var content: some View {
        if registry.needsAccessibility {
            notice(icon: "hand.raised.fill",
                   title: "Accessibility needed",
                   body: "sider reads and restores your windows through the Accessibility API. Turn sider on in System Settings → Privacy & Security → Accessibility.",
                   action: "Open System Settings") {
                AccessibilityBridge.requestTrust()
                openPrivacyPane("Privacy_Accessibility")
            }
        } else if !thumbnails.hasPermission {
            notice(icon: "rectangle.dashed.badge.record",
                   title: "Screen Recording needed",
                   body: "Previews are pictures of your windows, so macOS asks for Screen Recording. The images stay in memory and are never saved.",
                   action: thumbnails.wasEverRequested ? "Open System Settings" : "Allow…") {
                if thumbnails.wasEverRequested {
                    openPrivacyPane("Privacy_ScreenCapture")
                } else {
                    thumbnails.requestPermission()
                }
            }
        } else if registry.windows.isEmpty {
            // Only reachable when the panel was opened deliberately (menu bar, ⌥⌘S, or with
            // "open when empty" turned on) — a hover over the edge with nothing put away does
            // not open it at all.
            notice(icon: "rectangle.on.rectangle.slash",
                   title: "Nothing put away",
                   body: prefs.scope == .minimizedOnly
                        ? "Minimize a window and it shows up here."
                        : "No windows match what sider is set to collect.")
        } else {
            strip
        }
    }

    // MARK: - The strip

    private var strip: some View {
        GeometryReader { geo in
            ScrollViewReader { scroll in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(laidOut, id: \.window.id) { entry in
                            WindowCardView(
                                window: entry.window,
                                // The *recency* index, not the position in the layout, so the
                                // entrance staggers outward from the newest card rather than
                                // top-down across a stack whose middle arrived first.
                                index: entry.index,
                                width: cardWidth,
                                showTitle: prefs.showTitles,
                                style: prefs.style,
                                model: model,
                                onRestore: { onRestore(entry.window) },
                                onMinimize: { registry.minimize(entry.window) },
                                onDragChanged: { onDragChanged(entry.window, $0) },
                                onDragEnded: { onDragEnded(entry.window, $0) }
                            )
                        }
                    }
                    // The frame that marks the card being chosen is one shape that travels
                    // between cards, not a highlight per card switching on and off, so
                    // moving the selection reads as moving. Drawn over the cards, in the
                    // strip's own space, so it scrolls with them.
                    .coordinateSpace(name: CardFramesKey.space)
                    .overlayPreferenceValue(CardFramesKey.self) { frames in
                        if prefs.style.isSolid { selectionLens(frames) }
                    }
                    .padding(.vertical, 2)
                    .reportingContentHeight()
                    // Centred vertically when it fits, scrolling normally when it does not.
                    // `minHeight` rather than `height`: forcing the height would stop a long
                    // stack from growing past the screen and quietly clip the ends off it.
                    // The notch is always centred, whichever way the cards are ordered.
                    .frame(minHeight: prefs.centeredStack || isNotch ? max(0, geo.size.height - restingInsets) : 0,
                           alignment: .center)
                    // Inside the ScrollView, not around it: the panel is as tall as the
                    // display, so the stack rests clear of the menu bar and the Dock but
                    // scrolls under them to the very edge of the screen.
                    .padding(.top, model.topInset + 12)
                    .padding(.bottom, model.bottomInset + 12)
                }
                // A strip taller than the screen scrolls, and the four-finger gesture can walk
                // the highlight off the end of what is showing.
                .onChange(of: model.selected) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.18)) { scroll.scrollTo(id) }
                }
            }
        }
    }

    /// The card the frame is on: the one the fingers chose, or else the one under the pointer,
    /// or else the window that had focus when the panel opened.
    private func selectionLens(_ frames: [String: CGRect]) -> some View {
        let ids = laidOut.map { $0.window.id }
        let target = model.selected ?? model.hovered ?? model.focused
        return SelectionLens(rects: ids.map { frames[$0] },
                             index: target.flatMap { ids.firstIndex(of: $0) },
                             lean: model.lean,
                             committed: model.committed)
    }

    private var restingInsets: CGFloat { model.topInset + model.bottomInset + 24 }

    /// The cards in the order they are drawn, top to bottom, each paired with its recency
    /// index (0 = most recently put away).
    ///
    /// With `centeredStack` on the order comes from `CenteredStackLayout`.
    private var laidOut: [(index: Int, window: ManagedWindow)] {
        let windows = registry.windows
        guard prefs.centeredStack else {
            return windows.enumerated().map { (index: $0.offset, window: $0.element) }
        }
        return CenteredStackLayout.order(count: windows.count)
            .map { (index: $0, window: windows[$0]) }
    }

    // MARK: - Notices

    private func notice(icon: String, title: String, body: String,
                        action: String? = nil, perform: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(body)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action, let perform {
                Button(action, action: perform)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(width: cardWidth, alignment: .leading)
        // Matches the cards' own padding so a notice lines up with where a card would be.
        .padding(.horizontal, WindowCardView.hoverHeadroom)
        .padding(14)
        // A notice is words, not a picture, so it needs a surface of its own — with the
        // backdrop off it would otherwise be small grey text lying on the wallpaper.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .reportingContentHeight()
        .padding(.top, model.topInset + 12)
        .padding(.bottom, model.bottomInset + 12)
        .frame(maxHeight: .infinity, alignment: prefs.centeredStack || isNotch ? .center : .top)
        .opacity(model.isOpen || prefs.style.isSolid ? 1 : 0)
        .offset(x: model.isOpen ? 0 : -40)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.isOpen)
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The sidebar's black bar: a rectangle whose two trailing corners flare *outward* instead
/// of being cut inward, so the bar's edge sweeps into the top and bottom of the screen the
/// way the display's own bezel turns its corners.
///
/// The bar proper is `rect` less `flareRadius` on the trailing side; the flares fill the
/// corners of that last column.
struct SidebarBackdrop: Shape {
    static let flareRadius: CGFloat = 30

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        addFreeEdge(to: &path, in: rect)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    /// Only the sides that are not against the screen: flare, bar edge, flare.
    func outline(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        addFreeEdge(to: &path, in: rect)
        return path
    }

    /// Continues from the top trailing corner, `(maxX, minY)`, down to `(maxX, maxY)`.
    private func addFreeEdge(to path: inout Path, in rect: CGRect) {
        let r = Self.flareRadius
        let edge = rect.maxX - r
        path.addArc(center: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r,
                    startAngle: .degrees(-90), endAngle: .degrees(-180), clockwise: true)
        path.addLine(to: CGPoint(x: edge, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
    }
}

/// The notch style's black surface: the sidebar cut down to the height of its contents, in
/// the outline of a display notch turned on its side. Flat against the screen edge, flaring
/// outward along that edge where it meets it, and rounded at the two free corners.
///
/// The body is `rect` less `flareRadius` at the top and bottom; the flares fill the leading
/// corners of those two bands.
///
/// `reveal` is how far out of the edge it has come, 0…1 of `rect`'s width. The flares stay
/// on the screen edge the whole time and the body grows out from between them, so opening
/// reads as the notch peeling away from the display rather than a finished shape sliding in
/// with its flares arriving last.
struct NotchBackdrop: Shape {
    static let flareRadius: CGFloat = 30
    static let cornerRadius: CGFloat = 30

    var reveal: CGFloat = 1

    var animatableData: CGFloat {
        get { reveal }
        set { reveal = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = outline(in: rect)
        path.closeSubpath()
        return path
    }

    /// The silhouette without the side against the screen edge, which `path` closes.
    func outline(in rect: CGRect) -> Path {
        let width = rect.width * reveal
        guard width > 0 else { return Path() }
        let rect = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        let f = min(Self.flareRadius, rect.height / 2, rect.width)
        let c = max(0, min(Self.cornerRadius, rect.height / 2 - f, rect.width - f))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.minX + f, y: rect.minY), radius: f,
                    startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY + f))
        path.addArc(center: CGPoint(x: rect.maxX - c, y: rect.minY + f + c), radius: c,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - f - c))
        path.addArc(center: CGPoint(x: rect.maxX - c, y: rect.maxY - f - c), radius: c,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - f))
        path.addArc(center: CGPoint(x: rect.minX + f, y: rect.maxY), radius: f,
                    startAngle: .degrees(-90), endAngle: .degrees(-180), clockwise: true)
        return path
    }
}

/// A backdrop shape that can also give its outline minus the side flush with the screen.
protocol EdgeShape: Shape {
    func outline(in rect: CGRect) -> Path
}

extension SidebarBackdrop: EdgeShape {}
extension NotchBackdrop: EdgeShape {}

/// The backdrop's open outline as a shape of its own, animating along with it.
private struct EdgeOutline<Base: EdgeShape>: Shape {
    var base: Base

    var animatableData: Base.AnimatableData {
        get { base.animatableData }
        set { base.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path { base.outline(in: rect) }
}

/// Border along the inside of a backdrop's free edges, drawn as a crisp line, a line with a
/// blurred halo under it, or a directional sheen. Clipped to the silhouette so nothing bleeds onto the desktop, and so the
/// stroke is `width` thick on the inside only.
private struct PanelEdgeBorder<Base: EdgeShape>: View {
    let shape: Base
    let color: Color
    let width: CGFloat
    let style: BorderStyle
    let lightAngle: Double

    var body: some View {
        let outline = EdgeOutline(base: shape)
        ZStack {
            switch style {
            case .line:
                // Doubled: the outer half falls outside the clip.
                outline.stroke(color.opacity(0.9), lineWidth: width * 2)
            case .glow:
                outline.stroke(color, lineWidth: width).blur(radius: width)
                outline.stroke(color.opacity(0.9), lineWidth: width * 2)
            case .sheen:
                BorderSheen(path: outline, color: color, width: width, lightAngle: lightAngle)
            }
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}

/// Glass rim for `BorderStyle.sheen`, modeled on the edge of a native macOS widget: a thin,
/// softly glowing rim runs around the whole outline, and the light hitting it from
/// `lightAngle` makes it flare (with a whitish hot spot) on that side, easing back to the
/// base rim along the edges and picking up again as a dimmer bounce highlight on the
/// opposite corner. That light/bounce pair is what makes the panel read as a 3D slab.
/// The caller clips to the panel silhouette, so only the inner half of each stroke shows.
struct BorderSheen<P: Shape>: View {
    var path: P
    var color: Color
    var width: CGFloat
    /// Degrees counterclockwise from the right edge (0 = right, 90 = top).
    var lightAngle: Double

    var body: some View {
        let (lit, far) = Self.endpoints(forAngle: lightAngle)
        let w = width
        ZStack {
            // Bloom: light spilling inward. Strong on the lit side, a faint halo all the way
            // around, and a softer one where the light bounces back on the far side.
            path.stroke(LinearGradient(stops: [
                        .init(color: color.opacity(0.8), location: 0),
                        .init(color: color.opacity(0.25), location: 0.22),
                        .init(color: color.opacity(0.1), location: 0.45),
                        .init(color: color.opacity(0.1), location: 0.65),
                        .init(color: color.opacity(0.35), location: 1)],
                                       startPoint: lit, endPoint: far),
                        lineWidth: w * 2)
                .blur(radius: w * 1.2)
            // Rim: never fades out completely, so the outline stays readable everywhere.
            path.stroke(LinearGradient(stops: [
                        .init(color: color, location: 0),
                        .init(color: color.opacity(0.7), location: 0.12),
                        .init(color: color.opacity(0.42), location: 0.3),
                        .init(color: color.opacity(0.32), location: 0.45),
                        .init(color: color.opacity(0.32), location: 0.65),
                        .init(color: color.opacity(0.55), location: 0.88),
                        .init(color: color.opacity(0.7), location: 1)],
                                       startPoint: lit, endPoint: far),
                        lineWidth: max(1, w * 0.5))
            // Hot spots: a thin near-white core where the light lands, weaker on the bounce.
            path.stroke(LinearGradient(stops: [
                        .init(color: .white.opacity(0.85), location: 0),
                        .init(color: .white.opacity(0), location: 0.18),
                        .init(color: .white.opacity(0), location: 0.85),
                        .init(color: .white.opacity(0.35), location: 1)],
                                       startPoint: lit, endPoint: far),
                        lineWidth: max(0.75, w * 0.25))
        }
    }

    /// Gradient endpoints for a light coming from `degrees`: the point on the unit square's
    /// edge in that direction (so diagonals land on the corners) and its mirror opposite.
    static func endpoints(forAngle degrees: Double) -> (lit: UnitPoint, far: UnitPoint) {
        let radians = degrees * .pi / 180
        let dx = cos(radians)
        let dy = -sin(radians)  // view space: y grows downward
        let k = 0.5 / max(abs(dx), abs(dy))
        return (UnitPoint(x: 0.5 + dx * k, y: 0.5 + dy * k),
                UnitPoint(x: 0.5 - dx * k, y: 0.5 - dy * k))
    }
}

/// The frame around the card being chosen, and everything about how it moves.
///
/// Its place is a single number — which card, in cards, fractions included — and the spring
/// runs on that number, so a jump of three cards and a nudge of one both travel the way the
/// desktop switcher's frame does in vaho: under the fingers while they lean, with a little
/// weight when it lands. The rectangle is worked out from the number on every frame, which
/// is what lets it cross cards of different heights.
private struct SelectionLens: View {
    /// Each card's picture, in the order they are drawn. `nil` for one not laid out yet.
    let rects: [CGRect?]
    /// The card it is on. `nil`: nothing is chosen, and it fades where it was.
    let index: Int?
    /// How far the fingers lean toward a neighbour, -1…1 cards.
    let lean: CGFloat
    /// The choice was taken.
    let committed: Bool

    /// How much of the fingers' lean the frame follows. Enough that the strip is seen to
    /// answer before the selection changes, not so much that it looks like it already left.
    private static let leanShare: CGFloat = 0.3

    /// Where it last was, so it can fade out in place.
    @State private var rest: CGFloat = 0
    /// Whether it was showing on the previous frame. One that was not appears where it is
    /// going instead of sliding in from wherever it last was.
    @State private var live = false

    private var position: CGFloat? {
        guard let index else { return nil }
        let last = CGFloat(max(rects.count - 1, 0))
        return (CGFloat(index) + lean * Self.leanShare).clamped(0, last)
    }

    var body: some View {
        let shown = position
        let at = shown ?? rest
        SelectionRing(position: at, rects: rects, committed: committed)
            // Tight enough to stay under the fingers while they lean, loose enough that the
            // jump to the next card lands with a little weight.
            .animation(live ? .interactiveSpring(response: 0.22, dampingFraction: 0.78) : nil,
                       value: at)
            .opacity(shown != nil ? 1 : 0)
            .animation(.easeOut(duration: 0.18), value: shown != nil)
            .allowsHitTesting(false)
            .onChange(of: position) { new in
                if let new { rest = new }
                live = new != nil
            }
    }
}

/// The ring itself at one point of its travel. Animatable in `position`, so the spring drives
/// the number and the rectangle follows.
private struct SelectionRing: View, Animatable {
    var position: CGFloat
    let rects: [CGRect?]
    let committed: Bool

    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        if let rect = rect(at: position) {
            // Outside the picture, with a hairline of black between the two, and glowing a
            // little so it reads as lit rather than outlined.
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(.white, lineWidth: 3)
                .shadow(color: .white.opacity(0.75), radius: 6)
                .frame(width: rect.width + 8, height: rect.height + 8)
                // The frame swelling once is what says the choice was taken.
                .scaleEffect(committed ? 1.07 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.55), value: committed)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    /// The rectangle `position` cards down the strip: between the two cards it is between,
    /// and past the first or last by the same step when the spring overshoots.
    private func rect(at position: CGFloat) -> CGRect? {
        guard let first = rects.indices.first else { return nil }
        guard rects.count > 1 else { return rects[first] }
        let low = min(max(Int(position.rounded(.down)), 0), rects.count - 2)
        let t = position - CGFloat(low)
        switch (rects[low], rects[low + 1]) {
        case let (a?, b?):
            return CGRect(x: a.minX + (b.minX - a.minX) * t,
                          y: a.minY + (b.minY - a.minY) * t,
                          width: a.width + (b.width - a.width) * t,
                          height: a.height + (b.height - a.height) * t)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    func reportingContentHeight() -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
        })
    }
}
