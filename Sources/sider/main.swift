import Cocoa

let app = NSApplication.shared

// Bail out before any UI exists if an identical copy is already running. The keep-alive
// LaunchAgent starts sider outside LaunchServices, so nothing else stops a second panel
// from stacking on the first — see SingleInstanceGuard.
if SingleInstanceGuard.shouldYieldToRunningInstance() { exit(0) }

// .accessory, not .regular: no Dock tile, no app menu. Info.plist's LSUIElement already says
// so for a launch through LaunchServices, but launchd `exec`s the binary directly for the
// keep-alive agent and that path does not read it.
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
