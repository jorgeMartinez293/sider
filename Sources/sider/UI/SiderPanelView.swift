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
        .background {
            if isSidebar { SidebarBackdrop().fill(.black) }
            if isNotch { notchSilhouette }
        }
        // On black regardless of the system appearance, or the captions are black on black.
        .environment(\.colorScheme, prefs.style.isSolid ? .dark : systemScheme)
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
        let r = Self.flareRadius
        let edge = rect.maxX - r
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r,
                    startAngle: .degrees(-90), endAngle: .degrees(-180), clockwise: true)
        path.addLine(to: CGPoint(x: edge, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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
        path.closeSubpath()
        return path
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
