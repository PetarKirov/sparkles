# Wayland F04 — vsync / frame pacing

How steady is Wayland's native frame clock, what does its timestamp actually
mean, and what happens to it when the window disappears? The demo,
[`./examples/f04-frame-pacing/app.d`](./examples/f04-frame-pacing/app.d),
extends the [scaffold](./scaffold.md) to the [F04 spec][f04]: a trivially
cheap frame (full-window solid color flip) is redrawn **only** when a
[`wl_surface.frame`][p-wayland] callback fires — no sleep, no timer, no busy
loop — for 600 measured inter-frame deltas, followed by an occlusion probe:
[`xdg_toplevel.set_minimized`][p-xdgshell] with a frame callback kept
requested throughout, timed against an independent `poll(2)`-timeout clock so
a callback that never comes cannot deadlock the run. Tier A under
`weston --backend=headless`, run twice (default 60 Hz and `--refresh-rate=30000`),
both exit `0`.

**Last reviewed:** June 11, 2026

> [!WARNING]
> **Headless caveat — these numbers characterize the protocol, not hardware
> vsync.** Weston's headless backend repaints on a synthetic software timer:
> 60 Hz by default, overridable via `--refresh-rate=RATE` (in mHz). The demo
> was run at both 60 Hz and 30 Hz to prove the clock under measurement is the
> compositor's configurable repaint loop, not a display. The _delivery
> machinery_ (one callback per repaint cycle, ms-resolution timestamp,
> hard stop when invisible) is what transfers to real compositors; the
> absolute jitter figures do not.

## The jitter numbers

Stdout of the 60 Hz run (600 deltas, measured on the client's own
`MonoTime` µs clock between consecutive callback arrivals):

```text
stats source=monotonic_us n=600 min_us=16523 median_us=16668 p99_us=16751 max_us=16868
stats source=callback_arg_ms first=477981183 last=477991183 span_ms=10000 mean_period_ms=16.667
hist bucket_ms=16-17 count=600 #############################################################
```

And the same binary against `--refresh-rate=30000`:

```text
stats source=monotonic_us n=600 min_us=33138 median_us=33334 p99_us=33399 max_us=33736
stats source=callback_arg_ms first=477997623 last=478017623 span_ms=20000 mean_period_ms=33.333
hist bucket_ms=33-34 count=600 #############################################################
```

| Repaint clock                  | min      | median   | p99      | max      | nominal  |
| ------------------------------ | -------- | -------- | -------- | -------- | -------- |
| 60 Hz (default)                | 16.52 ms | 16.67 ms | 16.75 ms | 16.87 ms | 16.67 ms |
| 30 Hz (`--refresh-rate=30000`) | 33.14 ms | 33.33 ms | 33.40 ms | 33.74 ms | 33.33 ms |

Readings:

- **The pacing is metronomic**: all 600 deltas land in a single 1 ms histogram
  bucket in both runs; total spread is ±0.35 ms around the nominal period at
  60 Hz (±2 %), and the p99 is within 0.5 % of the median. For a software
  timer relayed over a Unix socket to a `poll`-based client, that is the
  entire jitter budget — the callback _delivery_ adds essentially nothing on
  top of the repaint clock itself.
- **The 600-callback span is exactly 10 000 ms / 20 000 ms** on the callback's
  own time argument — the synthetic clock does not drift, it quantizes.
- The two runs differing _only_ in the weston flag proves the measured clock
  is the compositor's repaint loop — the headless caveat above, demonstrated
  rather than assumed.

## What the callback's timestamp is (and is not)

The frame callback's only payload is `callback_data`, which the
[core protocol][p-wayland] specifies as:

> "The callback_data passed in the callback is the current time, in
> milliseconds, with an undefined base."

Two findings about its identity:

- **Millisecond resolution, unspecified epoch.** Consecutive ticks carry
  `t=477670441, 477670457, 477670474, …` — useful for animation deltas, too
  coarse for pacing analysis (hence the demo measures deltas on its own
  `MonoTime` µs clock and uses `t=` only as a cross-check).
- **On weston the "undefined base" is empirically `CLOCK_MONOTONIC`**: the run
  logged `t=477981183` ms while the host's `/proc/uptime` read 478 070 s
  moments later. That is an implementation detail a client must _not_ rely on
  — the spec promises no clock domain at all.

And the contract it does **not** offer: `wl_surface.frame` means "it is a good
time to start drawing", not "your frame was shown at time T". It carries no
presentation timestamp, no refresh prediction, and no this-frame-was-dropped
signal. The protocol that adds real presentation feedback is
[`wp_presentation`][p-presentation] (`presentation-time`): its `feedback`
event reports the actual presentation time as `tv_sec`/`tv_nsec` of a
declared clock (`wp_presentation.clock_id`), the output's `refresh` cycle
length, and flags (`vsync`, `hw_clock`, …). **Headless weston advertises it**
— the demo's registry dump (which fires one `global iface=… version=…` line
per advertised global) contains:

```text
247 f04_wayland global iface=wp_presentation version=2
```

so even the synthetic backend exposes the full two-tier model: `frame` for
"draw now" pacing, `wp_presentation` for "was presented at T" measurement. (The
dump also shows the newer pacing protocols `wp_fifo_manager_v1` and
`wp_commit_timing_manager_v1` — weston 15 is a complete frame-timing testbed.)
A framework's `requestRedraw` should be built on `frame` and treat
presentation timestamps as the separate, optional capability they are.

## Occlusion: the clock simply stops — and the client cannot restart it

After the 600th measured delta the demo requests `set_minimized`, keeps a
frame callback requested (re-committing so the request stays current), and
lets the `poll`-timeout clock count the silence:

```text
[2605694.614] {Default Queue} wl_callback#11.done(477991183)
10012246 f04_wayland frame_callback t=477991183
[2605694.655] {Default Queue}  -> xdg_toplevel#8.set_minimized()
[2605694.664] {Default Queue}  -> wl_surface#3.frame(new id wl_callback#11)
[2605694.673] {Default Queue}  -> wl_surface#3.commit()
10012304 f04_wayland vis_change state=minimized_requested
13016346 f04_wayland vis_change state=restore_requested minimized_for_us=3004101 cb_while_minimized=0
```

```text
occlusion: minimized_for_us=3004101 frame_callbacks_while_minimized=0 resume=NEVER
```

- **Frame callbacks stop dead: zero callbacks in 3.004 s of minimization**
  (≈ 180 would have fired at 60 Hz). No throttling, no free-run — a hard
  stop, exactly as the [core protocol][p-wayland] recommends:

  > "A server should avoid signaling the frame callbacks if the surface is
  > not visible in any way, e.g. the surface is off-screen, or completely
  > obscured by other opaque surfaces."

- **The restore attempt fails — by protocol design.** After 3 s the demo
  sends `set_maximized` plus a fresh attach/damage/commit. Weston answers
  with a real configure (1024×608, serial 17), the demo acks and commits a
  matching buffer — and the frame clock _still_ never resumes; the run ends
  via the independent 3 s restore timeout (`resume=NEVER`, total silence
  6.01 s). This is not a weston quirk: [`xdg-shell`][p-xdgshell] says of
  `set_minimized`:

  > "There is no way to know if the surface is currently minimized, nor is
  > there any way to unset minimization on this surface."

  Un-minimizing belongs to the user via the shell (taskbar, dock) — which
  headless weston does not have. `set_minimized` is a one-way door the client
  can open but not close. (The same spec passage even points throttling
  clients at exactly the mechanism this demo measures: "If you are looking to
  throttle redrawing when minimized, please instead use the
  wl_surface.frame event.")

- **The deadlock hazard is real.** A redraw loop driven purely by
  `wl_display_dispatch` + frame callbacks blocks forever once minimized. The
  demo survives because its event pump is the libwayland
  `wl_display_prepare_read`/`poll`/`wl_display_read_events`/`wl_display_dispatch_pending`
  pattern with a 50 ms `poll` timeout — the timeout is the independent clock
  that keeps wall-clock logic (the 3 s probe, the restore, the hard cap)
  running while the protocol is silent.

The contract a framework's `requestRedraw` must absorb: **frame callbacks are
demand-gated by visibility, may stop for an unbounded time, and never expire
or error** — pending callbacks fire only when the surface becomes visible
again. Timers, network events, and user-initiated work need their own wakeup
path; and "minimize" must be modeled as irreversible from the client's side.

## Findings

- **Jitter (headless, synthetic 60 Hz): min 16.52 / median 16.67 / p99 16.75 /
  max 16.87 ms** over 600 frames — single-bucket histogram; the protocol's
  delivery overhead is negligible against the repaint period.
- **Timestamps come from an unspecified ms clock** (`CLOCK_MONOTONIC` on
  weston, but that is unspecified); the primitive conveys _"draw now"_, never
  presentation time — [`wp_presentation`][p-presentation] (advertised by
  headless weston, v2) is the upgrade path.
- **Hidden ⇒ stopped, not throttled**: 0 callbacks during 3 s minimized, and
  no client-side un-minimize exists — resumption is the compositor's/user's
  prerogative.
- **600 measured frames cost 603 commits**: the two extra are the
  initial-configure commit and the minimize-phase keep-alive commit; steady
  state is exactly one commit per callback, double-buffered, with weston
  releasing each `wl_shm` buffer at repaint (the
  [scaffold finding](./scaffold.md#what-surprised-us)).

## Build and run

```bash
nix develop -c dub build --compiler=ldc2 \
    --root=docs/research/window-system-integration/os-apis/wayland/examples/f04-frame-pacing

export XDG_RUNTIME_DIR=$(mktemp -d)
nix develop -c weston --backend=headless --socket=wsi-w2 --idle-time=0 &
sleep 2
nix develop -c env WAYLAND_DISPLAY=wsi-w2 WAYLAND_DEBUG=1 \
    dub run --compiler=ldc2 \
    --root=docs/research/window-system-integration/os-apis/wayland/examples/f04-frame-pacing
```

For the 30 Hz cross-check, start weston with `--refresh-rate=30000` (the value
is in mHz). The demo always auto-terminates (601 callbacks + ~6 s of probe,
~16 s wall clock at 60 Hz); no reachable compositor prints `SKIP:` and exits
`0`; exit is non-zero if the 600 deltas could not be collected.

## Sources

- **[F04 spec][f04]** — requirements 1–3 (frame-clock-only redraw, the
  600-frame statistics + histogram, the occlusion probe) and the headless
  caveat it mandates recording.
- **[Wayland scaffold findings](./scaffold.md)** — the base implementation
  and the buffer-release behavior the commit accounting relies on.
- **[Core protocol][p-wayland]** — `wl_surface.frame` (both verbatim quotes:
  the "undefined base" timestamp and the don't-signal-when-invisible
  recommendation).
- **[`xdg-shell`][p-xdgshell]** — `set_minimized` (verbatim quote: no unset,
  no state feedback) and `set_maximized` used in the restore attempt.
- **[`presentation-time`][p-presentation]** — the `wp_presentation` protocol
  that adds real presentation timestamps; confirmed advertised (v2) in the
  demo's registry dump.
- Demo sources: [`app.d`](./examples/f04-frame-pacing/app.d),
  [`instrument.d`](./examples/f04-frame-pacing/instrument.d), and the `c.c`
  ImportC shim alongside them; the same frame clock driving an animation
  through a state storm in [F03](./f03-modal-loop.md).

<!-- References -->

[f04]: ../features/f04-frame-pacing.md
[p-wayland]: https://wayland.app/protocols/wayland
[p-xdgshell]: https://wayland.app/protocols/xdg-shell
[p-presentation]: https://wayland.app/protocols/presentation-time
