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
