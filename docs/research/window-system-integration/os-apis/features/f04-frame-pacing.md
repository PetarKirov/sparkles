# F04 — Vsync / frame pacing

Every platform offers a different "draw now, in sync with the display" primitive. This demo
drives redraw from the platform's native frame clock and measures how steady it actually is.

## Requirements

1. Redraw a trivially cheap frame (solid color flip) driven **only** by the platform frame
   clock — no `sleep`, no busy loop:
   - Wayland: `wl_surface.frame` callbacks.
   - X11: the Present extension (`xcb_present_notify_msc` / `PresentCompleteNotify`); if
     Present is unavailable, fall back to `XSyncWaitCondition`-free timed redraw and record
     the absence as the finding.
   - Win32: a DXGI waitable swapchain if feasible in plain D, else `DwmFlush` pacing —
     document which was chosen and why.
   - macOS: `CADisplayLink` (via `NSView.displayLink(target:selector:)`), noting
     `CVDisplayLink`'s deprecation.
2. Log `frame_callback t=…` for 600 consecutive frames; compute and print min/median/p99/max
   inter-frame delta and a coarse jitter histogram to stdout at exit.
3. Record what happens when the window is occluded/minimized/hidden: does the clock stop,
   throttle, or free-run? (Wayland: frame callbacks simply stop — log the gap.)

## Instrumentation

`frame_callback t=<presentation-or-callback-time>` per frame; `vis_change state=…` on
occlusion events; final `histogram …` summary lines.

## Findings to record

- The jitter statistics per platform and what clock the timestamps come from.
- Whether the primitive conveys _presentation time_ or merely "draw now".
- Throttling behavior when hidden — the contract a framework's `requestRedraw` must absorb.
- Headless caveat: under headless weston/Xvfb the refresh is synthetic; record the configured
  rate and mark the numbers as headless-only.

## Verification

Wayland/X11: Tier A (with the headless caveat). Win32: `A[wine]` numbers are Wine's DWM
emulation — collect them, but queue a Tier C run for real numbers. macOS: `A[ssh]` if windows
work over SSH; the display-link cadence on a real display is Tier C.
