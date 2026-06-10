# F11 — Scroll fidelity

A notched wheel click, a trackpad fling with momentum, and a high-resolution wheel are three
different signals that frameworks routinely flatten into one lossy number. This demo logs the
raw scroll stream per device class.

## Requirements

1. Log every scroll event with its full native payload, from both a notched wheel and a
   trackpad (where present):
   - Wayland: `wl_pointer.axis` value + `axis_v120` (120ths) + `axis_source`
     (wheel/finger/continuous) + `axis_stop` + frame grouping (`wl_pointer.frame`).
   - X11: legacy buttons 4/5/6/7 AND XInput2 smooth scrolling (`XI_Motion` valuators with
     `XIScrollClass`) — log both representations of the same physical scroll.
   - Win32: `WM_MOUSEWHEEL`/`WM_MOUSEHWHEEL` raw `wheelDelta`, demonstrating correct
     **accumulation of sub-120 deltas** (precision touchpads send fractions of `WHEEL_DELTA`)
     until a line-scroll threshold; log `SPI_GETWHEELSCROLLLINES`.
   - macOS: `scrollWheel:` with `scrollingDeltaX/Y`, `hasPreciseScrollingDeltas`, **phases**
     (`phase`/`momentumPhase` began/changed/ended) through a full fling.
2. Render a scrollable ruler so over/under-scroll bugs are visible; print per-gesture totals.
3. Capture one identical physical gesture on both device classes and diff the event streams.

## Instrumentation

`scroll axis=v|h value=… v120=… source=… phase=…` (fields as available per platform),
`scroll_stop`, gesture summary lines.

## Findings to record

- Per platform: the smallest representable scroll step, how device class is distinguished,
  and how momentum is delivered (events vs app-synthesized).
- The Win32 accumulation contract (what breaks if you truncate instead of accumulate).
- The X11 dual representation and its double-event trap (core + XI2 for one scroll).
- What a lossless framework scroll event must carry.

## Verification

Wheel halves: Wayland/X11 Tier A with synthetic wheel input (`xdotool click 4/5`; weston
test clients). Trackpad halves (momentum, phases, fractional deltas) need real hardware:
Tier C on the Mac trackpad and a Windows precision touchpad. `A[wine]` covers Win32 message
plumbing only.
