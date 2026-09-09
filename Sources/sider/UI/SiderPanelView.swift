import AppKit
import SwiftUI

/// The contents of the edge panel: a vertical strip of tilted window cards.
struct SiderPanelView: View {
    @ObservedObject var registry: WindowRegistry
    @ObservedObject var prefs: Preferences
    @ObservedObject var model: PanelModel
    @ObservedObject var thumbnails = ThumbnailService.shared

    let onRestore: (ManagedWindow) -> Void
    let onDragChanged: (ManagedWindow, CGPoint) -> Void
    let onDragEnded: (ManagedWindow, CGPoint) -> Void

    private var cardWidth: CGFloat { CGFloat(prefs.cardWidth) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The strip's own backdrop. Faint on purpose: the cards carry the visual weight,
            // and a solid panel edge-to-edge would read as a sidebar the user has to close
            // rather than something that came out to meet them.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(model.isOpen ? 0.92 : 0)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                        .opacity(model.isOpen ? 1 : 0)
                )
                .animation(.easeOut(duration: 0.22), value: model.isOpen)

            if model.isDropTarget { dropTargetOverlay }

            content
                .padding(.vertical, 12)
                // Small, because each card carries its own horizontal slack for the hover
                // state (`WindowCardView.hoverHeadroom`). Padding the container instead
                // would put the gap *outside* the ScrollView's clip, where it does the
                // hovered card no good.
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Shown while a window is being dragged at the edge. The panel opening on its own
    /// mid-drag needs an explanation, or it reads as a glitch instead of an invitation.
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
            notice(icon: "rectangle.on.rectangle.slash",
                   title: "Nothing put away",
                   body: prefs.scope == .minimizedOnly
                        ? "Minimize a window and it shows up here."
                        : "No windows match what sider is set to collect.")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(registry.windows.enumerated()), id: \.element.id) { index, window in
                        WindowCardView(
                            window: window,
                            index: index,
                            width: cardWidth,
                            showTitle: prefs.showTitles,
                            model: model,
                            onRestore: { onRestore(window) },
                            onClose: { registry.close(window) },
                            onMinimize: { registry.minimize(window) },
                            onDragChanged: { onDragChanged(window, $0) },
                            onDragEnded: { onDragEnded(window, $0) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
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
        .padding(.top, 6)
        .opacity(model.isOpen ? 1 : 0)
        .offset(x: model.isOpen ? 0 : -40)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.isOpen)
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
