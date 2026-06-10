# F10 — Pointer: relative motion, lock & confine

The mouselook problem: games and 3D tools need raw deltas with the cursor pinned, and
editors need confine-to-region. Each platform splits "hide cursor", "stop cursor", and "raw
motion" differently.

## Requirements

1. A "mouselook" mode toggled by click/keypress: while active, the cursor is locked (hidden
   and pinned) and the demo logs raw deltas (`pointer rel dx=… dy=…`) driving a visible
   crosshair/angle readout; toggling off restores the cursor exactly where it was locked
   (or documents that the platform restores it elsewhere).
   - Wayland: `zwp_pointer_constraints_v1.lock_pointer` +
     `zwp_relative_pointer_v1` for deltas (note `wl_pointer.motion` stops/continues?).
   - X11: `XIGrabDevice` + XInput2 raw motion events (`XI_RawMotion`), or warp-to-center
     fallback — implement XI2, document the fallback frameworks still use.
   - Win32: `RegisterRawInputDevices` (WM_INPUT) for deltas + `ClipCursor` to a 1×1 rect +
     `ShowCursor(FALSE)`.
   - macOS: `CGAssociateMouseAndMouseCursorPosition(false)` + `NSEvent.deltaX/Y` + hide via
     `NSCursor.hide`/`CGDisplayHideCursor`.
2. A confine-to-region variant (center half of the window): Wayland
   `confine_pointer`; X11 pointer barriers (XFixes) or grab-with-confine-to; Win32
   `ClipCursor(rect)`; macOS — no public confine API: demonstrate the absence and the
   event-warp workaround, recording its visible artifacts.
3. Log accel state: are deltas accelerated or raw per platform/mechanism?

## Instrumentation

`pointer rel dx=… dy=… raw=0|1`, `lock state=on|off`, `confine rect=…`, plus regular
`pointer abs x=… y=…` while unlocked.

## Findings to record

- The lock/confine/raw capability matrix and which combinations are atomic vs assembled.
- Whether lock can be denied (Wayland: compositor may refuse; log the `locked`/`unlocked`
  events) — a framework API must be async-failable because of this.
- Cursor-position restoration semantics on unlock.
- macOS's missing confine and the workaround cost.

## Verification

Tier C interactive at heart, but: Wayland under headless weston can verify the
protocol handshake (constraint granted/denied) — Tier A for that slice; X11 XI2 raw events
can be exercised with `xdotool` under Xvfb (synthetic deltas; mark them). Win32/macOS:
`A[wine]`/`A[ssh]` for API plumbing, manual queue for feel and edge cases (multi-monitor
edges, focus loss while locked).
