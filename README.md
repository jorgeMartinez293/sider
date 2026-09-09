# sider

Your minimized windows, on the left edge of the screen.

Push the pointer against the left edge and every window you have put away slides out as a
tilted preview, the way Stage Manager's strip does. Click one and it comes straight back.
No Dock hunting, no ⌘Tab-then-guess.

macOS 13 or later. Universal (Apple Silicon + Intel).

## What it does

- **Edge hover.** A dwell at the left edge opens the panel; moving away closes it. Both
  delays are adjustable, because how fast people move a pointer differs more than any other
  setting in the app.
- **Real previews.** Each card is a picture of that window, tilted in 3D and flattening under
  the pointer. Cards fly in staggered from the edge and leave together.
- **One click back.** Clicking a card un-minimizes the window, activates its app and raises
  that specific window — all three, in that order, or you end up somewhere you did not ask for.
- **Drag a window to the left edge** to put it away. Hold it against the edge, the panel opens
  as a drop target, let go.
- **Drag a card out** to take a window back and place it where you drop it, instead of where
  it happened to be before.
- **It comes to you.** A restored window opens on the desktop (Space) you are on, not the one
  it was minimized from — macOS's own behaviour would drag you across Spaces to fetch it.
- **⌥⌘S** toggles the panel from anywhere.
- **Scope.** Minimized windows only (the default), minimized plus apps hidden with ⌘H, or
  every window on the Mac.

## The one real constraint

**A minimized window cannot be captured.** It has no surface on any display, so no API —
ScreenCaptureKit or otherwise — will hand you its picture. The Dock shows one only because
the WindowServer kept the last frame for itself, and does not share it.

So sider photographs windows *while they are still visible* and keeps the most recent frame:
the frontmost window every few seconds, every visible window on a slow sweep, and an
immediate capture of an app's windows the moment it stops being frontmost — which is the best
available predictor of "about to be put away".

The practical consequence: a window that was **already minimized when sider started** shows
its app icon instead of a preview, because sider never saw it. Un-minimize it once and it
gets a real picture from then on.

Nothing is ever written to disk. The cache lives in memory and dies with the process.

## Permissions

| Permission | Why | Without it |
|---|---|---|
| Accessibility | The only API that can see a minimized window, put it back, move it, and tell that you are dragging one. | The panel is empty. |
| Screen Recording | Taking the preview pictures. | Cards fall back to app icons. |

macOS applies a new grant only to a process that starts *afterwards*. If a toggle is on in
System Settings but sider still says it is missing, quit sider from the menu bar and reopen it.

## Build

```bash
make            # dev build: universal, signed with whatever identity is available
make release    # distribution build (no get-task-allow entitlement)
make test
make icon       # regenerate Resources/AppIcon.icns from scripts/make-icon.swift
```

`make` refuses to fall back to ad-hoc signing without being asked (`make SIGN_IDENTITY=-`).
That is deliberate: an ad-hoc bundle is a different TCC identity on every rebuild, so
Accessibility and Screen Recording silently reset and the app comes up looking broken while
System Settings still shows both switches on.

## Releasing

One command:

```bash
scripts/ship.sh 1.1
```

It builds, notarizes, signs the appcast, tags, uploads and publishes — and is safe to re-run
if any step fails. See [docs/RELEASING.md](docs/RELEASING.md) for the first-time setup
(Sparkle keys, notarytool profile, the two repos) and
[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) for how updates reach users.

## Layout

```
Sources/sider/
  main.swift                 process entry, single-instance guard, activation policy
  AppDelegate.swift          wires the services together
  Models/
    ManagedWindow.swift      a window, joined from its AX element and its CGWindowID
    Preferences.swift        every setting, persisted and observable
  Services/
    AccessibilityBridge.swift  typed AX layer, incl. the AXUIElement → CGWindowID join
    SpacesBridge.swift         pulls a window onto the desktop you are on (private CGS API)
    WindowRegistry.swift       the live window list: AX observers + a safety poll
    ThumbnailService.swift     the rolling capture cache described above
    EdgeHoverMonitor.swift     when the panel opens, closes, and when a window is dragged to it
    HotKeyManager.swift        ⌥⌘S
    LoginItemService.swift     launch at login + crash restart
    UpdaterService.swift       Sparkle
    SingleInstanceGuard.swift  never two panels
  UI/
    SiderPanelController.swift the panel window, its slide animation, and card drag-out
    DragProxyWindow.swift      the thumbnail that follows the pointer during a drag-out
    SiderPanelView.swift       the strip
    WindowCardView.swift       one card, including the Stage Manager tilt
    MenuBarController.swift    the menu bar item
    SettingsView.swift         settings
    WelcomeWindowController.swift  first run
```
