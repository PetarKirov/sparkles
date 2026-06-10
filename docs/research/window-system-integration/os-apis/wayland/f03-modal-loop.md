# Wayland F03 — modal-loop survival

There is no modal loop on Wayland — and proving a negative takes a positive
demo. [`./examples/f03-modal-loop/app.d`](./examples/f03-modal-loop/app.d)
extends the [scaffold](./scaffold.md) into the [F03 spec][f03]'s
Wayland/X11 half: a full-window ~2 Hz color-cycle animation driven purely by
[`wl_surface.frame`][p-wayland] callbacks, logging one
`tick t=<cb-ms> dt_us=<inter-tick delta>` per frame, runs **through** a storm
of twelve window-state transitions — maximize → unmaximize → fullscreen →
unfullscreen, three full cycles, one transition every 10 frames — and the
inter-tick deltas never leave the one-frame ballpark. On Win32 the same
experiment is the headline fight of the whole feature: `WM_ENTERSIZEMOVE`
traps the pumping thread in a system modal loop and a naive animation freezes
([the F03 spec][f03] lists the four known counter-techniques). On Wayland
there is nothing to defeat, and the demo's `modal_enter=0 modal_exit=0`
counters are zero **by construction**: no protocol event exists that could
increment them. Tier A under `weston --backend=headless`, exit `0`.

**Last reviewed:** June 11, 2026

## The verdict line

```text
3328158 f03_wayland summary ticks=200 transitions=12 configures=13 max_gap_us=16798 storm_max_gap_us=17063 modal_enter=0 modal_exit=0
```

200 animation ticks, 12 state transitions absorbed mid-run, and the **max
inter-tick gap during the storm — 17.06 ms — is within 1.6 % of the calm
baseline's 16.80 ms** (nominal frame period: 16.67 ms at the headless
backend's 60 Hz repaint clock). A state transition costs the animation
_nothing_: not one frame was skipped, stretched, or delayed beyond normal
frame-clock jitter.

## Why there is nothing to survive

On Win32, interactive resize/move runs inside `DefWindowProc`: the thread that
owns the window blocks in a system-owned message loop between
[`WM_ENTERSIZEMOVE`][wm-entersizemove] and `WM_EXITSIZEMOVE`, and the
application's own pump — and anything paced by it — stops being scheduled.
The [F03 spec][f03] exists because every framework must pick a workaround
(`SetTimer` ticks, a render thread, …).

Wayland's architecture has no slot for that failure mode:

- **The client owns its only event loop, always.** The compositor can never
  execute the client's code or block the client's dispatch; everything it has
  to say arrives as events on the socket, drained by the same
  `wl_display_dispatch` loop that drives the animation. The demo's loop
  (step 5 in [`app.d`](./examples/f03-modal-loop/app.d)) is the entire
  scheduling story.
- **Window-state changes are just more configure events.** Each storm request
  (`set_maximized`, [`set_fullscreen`][p-xdgshell], …) is answered by an
  ordinary `xdg_toplevel.configure` + `xdg_surface.configure` pair on that
  loop, acked and re-rendered between two ticks — exactly the
  [F02](../features/f02-resize.md) machinery, exercised harder.
- **Even _interactive_ resize/move is compositor-driven, not loop-stealing.**
  A client starts a title-bar drag by sending [`xdg_toplevel.move`][p-xdgshell]
  (or `xdg_toplevel.resize`) and then simply _returns to its loop_; the
  compositor tracks the pointer itself and, for a resize, streams configure
  events with the [`resizing` state bit][p-xdgshell] set. The demo logs that
  bit on every `xdg_toplevel.configure` (`resizing=0` throughout the headless
  run — no seat, nothing to drag with). There is no request, event, or error
  in the [core protocol][p-wayland] or [`xdg-shell`][p-xdgshell] that
  transfers loop ownership — which is why `modal_enter`/`modal_exit` cannot
  fire.

The asymmetry **is** the finding: what Win32 frameworks need four documented
techniques to fake (a frame clock that keeps ticking during interaction),
Wayland provides by construction, because the design never lets the
compositor borrow the client's thread.

## One storm transition, under the microscope

Instrument log of transition `n=2` (floating 640×480 → fullscreen 1024×640),
with the `WAYLAND_DEBUG=1` wire trace interleaved — note the tick → request →
configure → ack → realloc → commit sequence completing in **under 1 ms**,
entirely between two 16.7 ms ticks:

```text
[2284946.833] {Default Queue} wl_callback#12.done(477670457)
828049 f03_wayland tick t=477670457 dt_us=16773
[2284946.875] {Default Queue}  -> xdg_toplevel#8.set_fullscreen(nil)
828087 f03_wayland storm n=2 request=set_fullscreen
[2284947.339] {Default Queue} xdg_toplevel#8.configure(1024, 640, array[4])
828550 f03_wayland xdg_toplevel_configure size=1024x640 maximized=0 fullscreen=1 resizing=0
[2284947.363] {Default Queue} xdg_surface#7.configure(4)
828573 f03_wayland configure serial=4 size=1024x640
[2284947.386] {Default Queue}  -> xdg_surface#7.ack_configure(4)
828595 f03_wayland resize size=1024x640 scale=1
828760 f03_wayland buffer_alloc size=1024x640 bytes=2621440
[2284949.399] {Default Queue}  -> wl_surface#3.attach(wl_buffer#9, 0, 0)
[2284949.413] {Default Queue}  -> wl_surface#3.commit()
```

And the ticks bracketing it never notice (`dt_us` stays ~16.5–17.1 ms across
the whole run; the global maximum of 17.06 ms landed elsewhere in the storm):

```text
811275 f03_wayland tick t=477670441 dt_us=16610
828049 f03_wayland tick t=477670457 dt_us=16773
844969 f03_wayland tick t=477670474 dt_us=16920
```

Headless-weston specifics inherited from the [scaffold](./scaffold.md):
maximize configures 1024×608 (the desktop-shell panel eats 32 px of the
1024×640 output), unmaximize/unfullscreen configure `0x0` ("you pick", the
demo restores 640×480), and each size change reallocates both `wl_shm`
buffers over the following two frames — visible as paired `buffer_alloc`
lines, all without disturbing the tick cadence.

## Findings

- **Max inter-tick gap through the interaction storm: 17.06 ms** vs 16.80 ms
  calm, at a 16.67 ms nominal period — the [F03][f03] "bounded deltas"
  requirement holds with margin, with zero platform-specific
  countermeasures. The equivalent Win32 number without countermeasures is
  unbounded (the animation stops for the duration of the drag).
- **`modal_enter`/`modal_exit` never fire because they cannot exist.** The
  closest protocol concept is the `resizing` bit inside
  `xdg_toplevel.configure`'s state array — which is _information_ ("the user
  is dragging an edge"), not a _transfer of control_. A framework's Wayland
  backend needs no `WM_ENTERSIZEMOVE` bracketing, no timer fallback, no
  render thread to keep `requestAnimationFrame`-style clients alive during
  resize.
- **Which thread the "modal loop" captures: none.** The loop-ownership
  question the [F03 spec][f03] asks per platform answers itself here: the
  client's loop is never captured because no compositor code ever runs on a
  client thread. The cost shows up elsewhere — _the client_ must implement
  window movement requests (`xdg_toplevel.move`) instead of getting them for
  free from `DefWindowProc`, and must keep acking configures promptly or be
  judged unresponsive.
- **Animation clock choice matters for the proof.** The demo derives the hue
  from elapsed wall-clock time, not the frame counter, so a hypothetical
  stalled loop would resume with a visible color _jump_ rather than a
  slowed-down cycle — the log and the pixels make the same claim.

## Build and run

```bash
nix develop -c dub build --compiler=ldc2 \
    --root=docs/research/window-system-integration/os-apis/wayland/examples/f03-modal-loop

# Tier A: against a private headless weston
export XDG_RUNTIME_DIR=$(mktemp -d)
nix develop -c weston --backend=headless --socket=wsi-w2 --idle-time=0 &
sleep 2
nix develop -c env WAYLAND_DISPLAY=wsi-w2 WSI_AUTO_EXIT=1 WAYLAND_DEBUG=1 \
    dub run --compiler=ldc2 \
    --root=docs/research/window-system-integration/os-apis/wayland/examples/f03-modal-loop
```

No reachable compositor prints `SKIP:` and exits `0`. Without `WSI_AUTO_EXIT`
the demo runs (and animates) until the compositor sends `xdg_toplevel.close`.

> [!NOTE]
> **Tier C — the interactive half.** Headless weston advertises no `wl_seat`,
> so real interactive resize/title-bar drag is queued for a manual run on
> mutter, KWin, and sway: run the demo without `WSI_AUTO_EXIT`, drag the
> window by its title bar (and by an edge) for several seconds, and verify
> the color cycling never stutters and the `tick … dt_us=…` stream stays
> bounded — expect configure events carrying `resizing=1` during an edge
> drag, and _no_ tick gap on either compositor family.

## Sources

- **[F03 spec][f03]** — requirements 1, 2, 5 (the ~2 Hz animation, bounded
  deltas during interaction, "confirm and log that no modal loop exists —
  that asymmetry is itself the finding"); the Win32/macOS halves it contrasts
  with.
- **[Wayland scaffold findings](./scaffold.md)** — the base implementation,
  the headless-weston maximize/unmaximize sizes, the no-`wl_seat` surprise.
- **[`xdg-shell`][p-xdgshell]** — `xdg_toplevel.set_maximized` /
  `set_fullscreen` / `move` / `resize`, the `resizing` state, and the
  configure/ack contract the storm exercises.
- **[Core protocol][p-wayland]** — `wl_surface.frame`, the animation's only
  clock.
- **[`WM_ENTERSIZEMOVE`][wm-entersizemove]** (Microsoft Learn) — the Win32
  modal loop this demo proves Wayland does not have.
- Demo sources: [`app.d`](./examples/f03-modal-loop/app.d),
  [`instrument.d`](./examples/f03-modal-loop/instrument.d), and the `c.c`
  ImportC shim alongside them; pacing statistics for the same frame clock in
  [F04](./f04-frame-pacing.md).

<!-- References -->

[f03]: ../features/f03-modal-loop.md
[p-wayland]: https://wayland.app/protocols/wayland
[p-xdgshell]: https://wayland.app/protocols/xdg-shell
[wm-entersizemove]: https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-entersizemove
