import AppKit
import SwiftUI

/// First-run window. It exists because sider is completely inert until two permissions are
/// granted, and neither can be granted from a prompt alone — Accessibility always sends the
/// user to System Settings, and a Screen Recording grant only takes effect after a relaunch.
/// Without this, a new install looks like an app that does nothing.
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to sider"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.contentView = NSHostingView(rootView: WelcomeView { [weak self] in
            Preferences.shared.hasCompletedWelcome = true
            self?.close()
        })
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct WelcomeView: View {
    let onDone: () -> Void

    @ObservedObject private var thumbnails = ThumbnailService.shared
    /// AX trust has no notification and no publisher, so the only way to reflect a grant the
    /// user just made in System Settings is to re-read it. Once a second is imperceptible
    /// and costs a single boolean check.
    @State private var trusted = AccessibilityBridge.isTrusted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("sider").font(.system(size: 26, weight: .semibold))
                Text("Push your pointer against the left edge of the screen and every window you have minimized slides out as a preview. Click one to bring it back.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            step(number: 1,
                 title: "Accessibility",
                 body: "Lets sider see which windows are minimized and put them back.",
                 granted: trusted) {
                AccessibilityBridge.requestTrust()
                open("Privacy_Accessibility")
            }

            step(number: 2,
                 title: "Screen Recording",
                 body: "Lets sider take the preview pictures. They stay in memory on this Mac — never saved, never uploaded.",
                 granted: thumbnails.hasPermission) {
                if thumbnails.wasEverRequested { open("Privacy_ScreenCapture") }
                else { thumbnails.requestPermission() }
            }

            Text("A permission you switch on only reaches an app that starts afterwards. If sider still says one is missing after you grant it, quit sider from the menu bar and open it again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Spacer()
                Button("Start Using sider", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460, height: 470, alignment: .topLeading)
        .onReceive(poll) { _ in trusted = AccessibilityBridge.isTrusted }
    }

    private func step(number: Int, title: String, body: String,
                      granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(granted ? Color.green : Color.secondary.opacity(0.25))
                    .frame(width: 24, height: 24)
                if granted {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 12, weight: .semibold))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(body).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !granted {
                    Button("Grant…", action: action)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            Spacer()
        }
    }

    private func open(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
