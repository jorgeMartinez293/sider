import AppKit
import SwiftUI

/// The whole settings surface. Small on purpose — sider does one thing, and every knob here
/// exists because the right value genuinely differs between people (how fast they move a
/// pointer, how many screens they have) rather than because it was easy to expose.
struct SettingsView: View {
    @ObservedObject var prefs = Preferences.shared
    @ObservedObject var updater = UpdaterService.shared
    @ObservedObject var thumbnails = ThumbnailService.shared
    @ObservedObject var registry = WindowRegistry.shared

    @State private var automaticUpdates = UpdaterService.shared.automaticChecks

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            feel.tabItem { Label("Feel", systemImage: "hand.point.up.left") }
            permissions.tabItem { Label("Permissions", systemImage: "lock.shield") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 430, height: 380)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Picker("Show", selection: Binding(get: { prefs.scope }, set: { prefs.scope = $0 })) {
                ForEach(PanelScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            Text(prefs.scope.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Open on", selection: Binding(get: { prefs.screen }, set: { prefs.screen = $0 })) {
                ForEach(PanelScreen.allCases) { screen in
                    Text(screen.title).tag(screen)
                }
            }

            Divider().padding(.vertical, 4)

            Toggle("Show window titles", isOn: Binding(get: { prefs.showTitles },
                                                        set: { prefs.showTitles = $0 }))
            Toggle("Close when you click elsewhere",
                   isOn: Binding(get: { prefs.clickOutsideDismisses },
                                 set: { prefs.clickOutsideDismisses = $0 }))

            Divider().padding(.vertical, 4)

            Toggle("Drag a window to the left edge to put it away",
                   isOn: Binding(get: { prefs.dropToMinimize },
                                 set: { prefs.dropToMinimize = $0 }))
            Toggle("Open windows on the desktop you are on",
                   isOn: Binding(get: { prefs.openOnCurrentSpace },
                                 set: { prefs.openOnCurrentSpace = $0 }))
                .disabled(!SpacesBridge.isAvailable)
            if !SpacesBridge.isAvailable {
                Text("Unavailable on this version of macOS — restored windows will reopen on the desktop they were minimized from.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Toggle with ⌥⌘S",
                   isOn: Binding(get: { prefs.hotKeyEnabled },
                                 set: { prefs.hotKeyEnabled = $0; HotKeyManager.shared.apply(enabled: $0) }))
            Toggle("Start sider at login",
                   isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
        }
        .formStyle(.grouped)
    }

    // MARK: - Feel

    private var feel: some View {
        Form {
            Section {
                slider("Preview size", value: Binding(get: { prefs.cardWidth },
                                                       set: { prefs.cardWidth = $0 }),
                       range: 120...340, unit: "pt")
            } footer: {
                Text("How wide each window preview is.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                slider("Edge sensitivity", value: Binding(get: { prefs.hotZoneWidth },
                                                           set: { prefs.hotZoneWidth = $0 }),
                       range: 1...12, unit: "pt")
                slider("Open after", value: Binding(get: { prefs.hoverDelay },
                                                     set: { prefs.hoverDelay = $0 }),
                       range: 0...1.2, unit: "s", decimals: 2)
                slider("Close after", value: Binding(get: { prefs.hideDelay },
                                                      set: { prefs.hideDelay = $0 }),
                       range: 0...2, unit: "s", decimals: 2)
            } footer: {
                Text("A longer open delay keeps the panel from appearing when you sweep past the edge on your way somewhere else. A longer close delay gives you time to cross the gap back to it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, unit: String, decimals: Int = 0) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(String(format: "%.\(decimals)f\(unit)", value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    // MARK: - Permissions

    private var permissions: some View {
        Form {
            permissionRow(
                title: "Accessibility",
                granted: registry.needsAccessibility == false && AccessibilityBridge.isTrusted,
                detail: "Lets sider see which windows are minimized and put them back. Without it the panel is empty.",
                action: {
                    AccessibilityBridge.requestTrust()
                    open("Privacy_Accessibility")
                })
            permissionRow(
                title: "Screen Recording",
                granted: thumbnails.hasPermission,
                detail: "Lets sider take the preview pictures. They are held in memory only — never written to disk, never sent anywhere.",
                action: {
                    if thumbnails.wasEverRequested { open("Privacy_ScreenCapture") }
                    else { thumbnails.requestPermission() }
                })
            Section {
                Text("macOS only applies a new grant to a process that started after it. If a switch is on here but sider still says it is missing, quit and reopen sider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(title: String, granted: Bool,
                               detail: String, action: @escaping () -> Void) -> some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !granted {
                    Button("Fix…", action: action).controlSize(.small)
                }
            }
        }
    }

    private func open(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - About

    private var about: some View {
        VStack(spacing: 14) {
            Spacer()
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 76, height: 76)
            }
            Text("sider").font(.system(size: 20, weight: .semibold))
            Text("Version \(updater.currentVersion) (build \(updater.currentBuild))")
                .font(.caption).foregroundStyle(.secondary)

            if UpdaterService.isConfigured {
                Toggle("Check for updates automatically", isOn: $automaticUpdates)
                    .onChange(of: automaticUpdates) { updater.automaticChecks = $0 }
                    .toggleStyle(.checkbox)

                Button("Check for Updates…") { updater.checkForUpdates() }
            } else {
                Text("This build has no update signing key, so it cannot install updates.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
