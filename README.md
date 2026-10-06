# sider

Your minimized windows, on the left edge of the screen.

Push the pointer against the left edge and every window you have put away slides out as a
tilted preview, the way Stage Manager's strip does. Click one and it comes straight back.
No Dock hunting, no ⌘Tab-then-guess.

macOS 13 or later. Universal (Apple Silicon + Intel).

## What it does

- **Edge hover.** A dwell at the left edge opens the panel; moving away closes it. Both
  delays are adjustable, because how fast people move a pointer differs more than any other
  setting in the app. With nothing put away, the hover does nothing at all — an empty panel
  sliding out to announce that it is empty is a charge for brushing the edge.
- **Stacked from the middle.** The window you just put away sits at the vertical centre of
  the screen and the rest spread out above and below it, so the newest card is always in the
  same place. Switch it off in Settings for a plain list from the top.
- **No panel, just windows.** The previews float straight on the desktop. A backing panel is
  available in Settings for anyone who wants the edge drawn in.
- **Real previews.** Each card is a picture of that window, tilted in 3D and flattening under
  the pointer. Cards fly in staggered from the edge and leave together.
- **One click back.** Clicking a card un-minimizes the window, activates its app and raises
  that specific window — all three, in that order, or you end up somewhere you did not ask for.
  The window lands in the middle of the screen you are on, rather than wherever it happened to
  be when you put it away. Switchable in Settings.
- **Drag a window to the left edge** to put it away. Hold it against the edge, the panel opens
  as a drop target, let go.
- **Drag a card out** to take a window back and place it where you drop it, instead of where
  it happened to be before.
- **Four fingers on the trackpad** open the panel. Without lifting them, slide up or down to
  walk through the cards; lift, and the highlighted window comes back. Lifting without
  sliding just closes the panel again. Reads the trackpad through the private
  `MultitouchSupport` framework. macOS answers four-finger vertical swipes too (Mission
  Control, App Exposé) even when those are set to three fingers, so while sider's fingers are
  down an event tap drops that swipe before the Dock sees it; three-finger swipes are left
  alone.
- **A five-finger tap** minimizes the window in front.
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

## One thing sider cannot do

**Bring a window to the desktop you are on.** If you minimized it on desktop 1 and click its
card from desktop 3, macOS takes you to desktop 1.

This is not an oversight. macOS 26 accepts every private call that asks to move a window to
another Space and then ignores it — `CGSMoveWindowsToManagedSpace`, the
`CGSAddWindowsToSpaces`/`CGSRemoveWindowsFromSpaces` pair, and the all-Spaces window tag all
return success and change nothing, from an unprivileged process and from the signed app alike.
It is the same restriction that makes yabai require SIP to be partially disabled for this one
feature. Turning off *"When switching to an application, switch to a Space with open windows
for the application"* does not help: it stops the jump, but the window still reappears on its
own desktop, so you end up with neither.

sider tests this at runtime rather than assuming, so the setting disappears from Settings on
the Macs where it cannot work and comes back by itself if it ever can.

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
    FourFingerGesture.swift  the four-finger peek-and-pick state machine (pure, tested)
    FiveFingerTap.swift      the five-finger tap recogniser (pure, tested)
    ManagedWindow.swift      a window, joined from its AX element and its CGWindowID
    Preferences.swift        every setting, persisted and observable
  Services/
    MultitouchBridge.swift     raw trackpad fingers (private MultitouchSupport, looked up at runtime)
    FourFingerSwitcher.swift   trackpad frames → the four-finger gesture's events
    SystemSwipeBlocker.swift   keeps Mission Control / App Exposé off sider's four fingers
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
