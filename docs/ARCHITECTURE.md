# Architecture

Six services and a panel. Everything interesting is a consequence of two facts about macOS.

## Fact one: a minimized window cannot be captured

It has no surface on any display. ScreenCaptureKit will not return it; the old
`CGWindowListCreateImage` returns a blank. The Dock's genie thumbnail exists because the
WindowServer kept the last frame for itself, and there is no API to ask for it.

`ThumbnailService` therefore works backwards: it captures windows *while they are visible* and
keeps the latest frame per `CGWindowID`, on three triggers —

| Trigger | Cadence | Why |
|---|---|---|
| Frontmost window | 2.5 s | The one most likely to be minimized next. |
| Every visible window | 12 s | So an untouched window is not hours stale. |
| An app losing focus | immediate | Best available predictor of "about to be put away". |

The visible consequence, documented in the README, is that a window already minimized at
launch has no picture and falls back to its app icon.

### Resolution, and a units bug worth remembering

`SCStreamConfiguration.width`/`height` are in **pixels**. `SCWindow.frame` is in **points**.
The original code computed `min(1, 600 / frame.width)` and applied it to the point size, which
silently conflated the two: a 1512×888pt window — 3024×1776 real pixels on a 2× display — was
captured at 600×352, a fifth of its resolution. The card draws at 200pt, which is 400 backing
pixels, so there was barely any detail left to draw with. That is what "blurry previews" was.

The budget now comes from what the card needs: its width in real pixels, doubled. The doubling
is not slack — cropping to fill discards one axis entirely, and the hovered card scales up on
top of that. It is never taken above the window's native resolution, since upsampling past
that costs bytes and adds nothing.

Two smaller things matter as much as the number:

- `captureResolution = .best`. `.automatic` is free to hand back a downscaled frame.
- `ignoreShadowsSingleWindow = true`. A window's drop shadow is a wide band of near-transparent
  grey; captured, it eats pixels out of the budget and leaves a dirty edge once the card crops.

And on the way out, `NSImage` is built with its size in **points** (pixels ÷ scale). An
`NSImage` whose size equals its pixel count declares itself 1×, and AppKit then throws the
extra resolution away on the way to the screen instead of using it.

The cache is bounded in **bytes**, not entries: an entry runs from 0.4 MB to 6 MB depending on
window and card size, so a fixed count either wastes the budget or overshoots it fourfold.

Capture goes through **ScreenCaptureKit** on macOS 14+ and `CGWindowListCreateImage` only on
13. That is not about deprecation warnings: since macOS 15 an app capturing through the old
CoreGraphics call earns the recurring "…has been recording your screen" reminder, and
ScreenCaptureKit does not.

## Fact two: only the Accessibility API can act on windows

`CGWindowListCopyWindowInfo` is fast and lists minimized windows, but gives no handle you can
*do* anything with. The Accessibility API gives you an `AXUIElement` you can un-minimize and
raise, but knows nothing about `CGWindowID`s — and the capture APIs speak only `CGWindowID`.

`AccessibilityBridge` joins the two with `_AXUIElementGetWindow`, a private symbol with no
public equivalent, resolved through `dlsym` rather than declared `extern`. If Apple ever
removes it, a nil lookup degrades sider to "no thumbnails"; an undefined symbol at link time
would stop the binary launching at all.

Classifying what counts as a window is its own trap. Subrole alone is not enough: **TextEdit
reports ordinary document windows as `AXDialog`**, not `AXStandardWindow`, so a filter that
only accepted the latter dropped them from the panel with no error anywhere. The reliable test
is whether the window has a **minimize button**, because that is the same question restated —
a window with one is a window macOS itself will put in the Dock.

`AccessibilityBridge.application(pid:)` sets a 0.25 s messaging timeout. The default is six
seconds, and every attribute read is a synchronous IPC round trip into another process — one
beachballing app would otherwise stall a scan for six seconds *per window*.

## WindowRegistry: events *and* a poll

Both, on purpose. Per-app `AXObserver`s make the panel react the instant something is
minimized. But every AX event source has holes — apps that draw their own title bars post
nothing on miniaturize, an observer stops delivering when its app is relaunched under the same
PID, a window that changes title never says so. A registry that only listened would drift and
show stale cards, which is worse than a little idle CPU. So a full rescan also runs on a
timer: 1 s while the panel is visible (the only time a stale card is on screen), 4 s otherwise.

Scans run off the main thread and are coalesced with an 80 ms debounce, because one user
action produces an AX notification, a workspace notification and a poll tick within
milliseconds.

`restore()` does three things in order — un-minimize, activate the app, then focus and raise
that specific window — with a beat before the last step. Each is necessary: un-minimizing does
not bring the app forward, activating does not choose *which* of its windows lands on top, and
several apps (Safari, Finder) re-order their windows as they come forward and would otherwise
put a different one in front of you.

## Spaces: what macOS will not let an app do

macOS remembers which Space a window belonged to and sends you back there when it is
un-minimized. For sider that is wrong outright: the panel follows you across Spaces
(`.canJoinAllSpaces`), so you can be on desktop 3, click a card, and be thrown to desktop 1.
The window you asked for should come to you.

**It cannot.** There is no public API, and as of macOS 26 the private ones do not work either.
Measured on a Developer ID-signed build with Accessibility granted, against two windows that
really were on other Spaces:

| Call | Result |
|---|---|
| `CGSMoveWindowsToManagedSpace` | returns cleanly, window stays put |
| `CGSAddWindowsToSpaces` / `CGSRemoveWindowsFromSpaces` | same |
| `CGSSetWindowTags` with the all-Spaces tag | `rc == 0`, no effect |

The symbols are all still there — `dlsym` finds every one and they report success. The
WindowServer accepts the write and ignores it. This is the same wall yabai hits, and why it
needs SIP partially disabled for exactly this feature. Permissions are not the missing piece:
the results are identical from an unprivileged process and from the signed app.

Turning off *Desktop & Dock → "When switching to an application, switch to a Space with open
windows for the application"* does not help either. It stops the Space switch, but the window
still comes back on its own Space — so instead of being moved to the window, you get neither.
Measured: un-minimizing without activating the app leaves the active Space alone and the
window on its original one.

So `SpacesBridge` **measures rather than assumes**. It still attempts the move (before
un-minimizing, which is the right order if it ever works: a minimized window keeps its
`CGWindowID` and Space assignment, and doing it afterwards would make macOS switch there and
back). The first attempt on a window genuinely on another Space is checked a moment later,
asynchronously so nothing waits on a diagnostic, and `availability` settles on `.working` or
`.blocked`. Settings then stops offering a switch that cannot do anything — a checkbox that
quietly lies is worse than an absent feature. If a future macOS reopens this, or the user runs
with SIP off, it starts working on its own with nothing to change.

## Two drags

**Into the panel.** `EdgeHoverMonitor` watches `NSEvent.pressedMouseButtons` alongside the
pointer. On a press it records where; once the pointer has moved, it resolves the window under
the press point (off the main thread — a hit test is IPC into another process) and then polls
*that window's own position* at 5 Hz. Only when the window itself moves does this count as a
window drag, which is what separates it from dragging a text selection to the edge. From
there, reaching the edge opens the panel as a drop target and releasing minimizes.

**Out of the panel.** A card's click and its drag-out are **one** `DragGesture`, resolved at
the end by distance travelled. A separate `.onTapGesture` next to a `DragGesture` looks
equivalent and is not: SwiftUI resolves the two against each other, the tap wins, and the
drag-out silently never starts.

The dragged thumbnail rides in its own borderless window (`DragProxyWindow`) because the card
lives inside a `ScrollView` that clips to its bounds — and the entire gesture is about taking
the window *out* of the strip.

## Clicks in a panel that never activates

The panel is non-activating, which means it is not the key window, which means every click on
it is a "first click" — and AppKit spends a first click on focusing the window unless the view
under the pointer returns true from `acceptsFirstMouse`. The views under the pointer are ones
SwiftUI builds internally, and they do not.

So the panel takes key status — but only when the pointer actually comes **inside** it, not
when it opens. Tying it to opening would take the keyboard away from whatever you were typing
every time you brushed the left edge. Waiting costs nothing: you cannot click a card without
going there first.

## The panel's own animation is hand-rolled

`SiderPanelController.slide` interpolates the frame and alpha on a 60 Hz timer instead of using
`NSAnimationContext` with `window.animator()`.

That is not a preference. On this panel the animator proxy's `setFrame` and `alphaValue` were
dropped outright — not animated *and* not applied — so the window sat parked off-screen at
alpha 0 while every other part of the app believed it was open. Nothing in the API reports
that; it silently does nothing, and the symptom (a panel that never appears, with correct
geometry logged everywhere) points nowhere near the cause. Driving the interpolation directly
is a dozen lines, always lands on the final value, and puts the easing curve in plain sight.

## EdgeHoverMonitor: a poll, not a trigger window

Two more obvious designs were tried first and both have a hole:

- A 1–2 pt transparent window at the edge does receive `mouseEntered`, but swallows clicks
  meant for what is underneath, and does not exist inside another app's full-screen space.
- A global `mouseMoved` monitor stops being delivered while another app runs a modal drag or a
  menu tracking loop — exactly when someone flicks to the edge to go find a window.

Reading `NSEvent.mouseLocation` at 20 Hz is permission-free, works in both cases, and costs a
rounding error. The hot zone is measured from `visibleFrame.minX`, not `frame.minX`, so a Dock
pinned to the left edge pushes the zone to the Dock's right side instead of burying it
underneath.

## The panel

A borderless, non-activating `NSPanel` — clicking a card must not make *sider* the front app
first, since the entire point is to get somewhere else.

`collectionBehavior` is `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`
so it follows you between Spaces and is reachable over another app's full-screen window, which
is where hunting for a minimized window hurts most.

Opening is two animations at once: the window travels **its own full width** in from off the
side of the screen and fades up, while the cards spring in from the same direction, staggered
top to bottom, so the strip assembles as it arrives. The full-width travel is the point — a
short nudge plus a fade reads as the panel materialising in place, whereas this way the last
thing you see on close is the panel's trailing edge disappearing into the side of the screen.
It needs `SiderPanel.constrainFrameRect` to return its argument untouched: AppKit's default
keeps windows on screen and would quietly clamp the off-screen resting frame back, leaving a
fade with nothing in the code to explain the missing slide.

Closing reverses only the window's half — a staggered exit reads as the panel struggling to
get out of the way.

`PanelModel.isOpen` is flipped *after* the window is ordered in and *before* it is ordered
out, so SwiftUI has real frames to animate between rather than the content appearing already
finished.

Cards carry a `rotation3DEffect` about the vertical axis anchored at their trailing edge, so
the edge nearest the screen border leans away and the inner edge leans toward you — the
direction Stage Manager uses on the left. Hovering flattens the card to 0°, because a tilted
card is decoration and a card under the pointer is a target.

Two things about that tilt are easy to get backwards, and both look like rendering bugs:

- **The sign.** Rotating the other way brings the leading edge *toward* the viewer, which
  perspective magnifies — the card and its label spill past the window's left edge.
- **What it is applied to.** The tilt is on the preview alone. Rotating the caption with it
  magnifies the near end of the text and clips the first characters ("Claude" rendered as
  "aude"). Stage Manager does the same: the picture is in space, the label is flat.

And the flattened, hovered card is *wider* than the tilted one — perspective pulls the
receding edge inward, and `scaleEffect` does not participate in layout, so the extra pixels
land outside the frame the `ScrollView` clips to. `WindowCardView.hoverHeadroom` reserves that
slack around each card. It has to be padding on the card, not on the strip: padding the
container puts the gap outside the clip, where it does the hovered card no good.
