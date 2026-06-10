# F01 — First pixel & init cost

How much machinery sits between "process starts" and "a software-drawn frame is on screen"?
This demo formalizes the measurement the scaffolds already make possible: every platform object
touched, every round-trip required, and the wall-clock cost of each step. The per-platform
counts and event orders are the baseline every other feature demo builds on.

## Requirements

1. Present one software-drawn frame (the scaffold gradient is fine) and exit cleanly shortly
   after presentation is confirmed (auto-exit keeps the demo Tier-A runnable).
2. Log a timestamped instrumentation event for **every** initialization step from `init_start`
   to `first_pixel_presented` — connection/registration, window/surface creation, buffer
   allocation, the first configure/paint request, and the present itself.
3. "Presented" must mean what the platform can actually confirm: Wayland — the first
   `wl_buffer` committed after `xdg_surface.configure` was acked (plus the first `frame`
   callback); X11 — first `XPutImage`/`XShmPutImage` after `Expose` (note: no true present
   confirmation without the Present extension — record that); Win32 — return of the first
   `BitBlt` inside `WM_PAINT`; macOS — return of the first `drawRect:` (note what
   CoreAnimation may still defer).
4. Count **concepts**: distinct platform object/handle types touched before first pixel
   (e.g. `wl_display`, `wl_registry`, `wl_compositor`, `wl_surface`, `xdg_wm_base`, …).
5. Record LOC of the demo (excluding `instrument.d` and the `c.c` shim).

## Instrumentation

The mandatory event set, plus one `step name=<api-call>` event per initialization API call.
This demo defines `instrument.d` (monotonic microsecond timestamps, the
`<monotonic_us> <DEMO> <EVENT_KIND> k=v…` line format) that all other demos copy.

## Findings to record

- The ordered step list with deltas; total `init_start` → `first_pixel_presented` time.
- Concept count and LOC, copied into the matrix header row.
- Which steps are round-trips (block on the server/compositor) vs purely local.
- What "first pixel" even means per platform — where confirmation is impossible, say so.

## Verification

Wayland/X11: Tier A (headless weston / Xvfb). Win32: Tier A on CI, `A[wine]` locally.
macOS: `A[ssh]` if the Phase 0 probe verified SSH-launched windows, else Tier C.
