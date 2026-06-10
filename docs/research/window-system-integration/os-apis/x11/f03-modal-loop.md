# X11 F03 — modal-loop survival

Does interactive resize steal your event loop? On Win32 it does: the moment the
user grabs a border, `DefWindowProc` enters the system's moving/sizing **modal
loop** — per [Microsoft Learn][entersizemove], `WM_ENTERSIZEMOVE` is "sent one
time to a window after it enters the moving or sizing modal loop", and until
`WM_EXITSIZEMOVE` the thread's message pump is no longer the application's own.
The [F03 spec][f03] asks every platform to prove a ~2 Hz animation survives
that. The X11 demo, [`./examples/f03-modal-loop/app.d`](./examples/f03-modal-loop/app.d),
exists to demonstrate the opposite shape: **X11 has no modal loop at all** —
resize, from any source, is just more events in the same queue — and to make
that absence measurable. A timerfd-driven color cycle ticks at 62.5 Hz through
the [F02-style](./f02-resize.md) resize storms (self, external-connection, and
WM-mediated under `icewm`), logging the inter-tick gap on every frame; a modal
loop would show up as an unbounded gap. Both Tier-A runs under `xvfb-run`:
**0 protocol errors, exit 0**.

**Last reviewed:** June 10, 2026

## The verdict lines

```text
# bare Xvfb (no WM) — 25 self-resizes, 25 external resizes, realloc per notify
2496794 f03_x11 gap_summary phase=calm ticks=31 resizes=0 max_gap_us=16071
2496808 f03_x11 gap_summary phase=self ticks=50 resizes=25 max_gap_us=17835
2496822 f03_x11 gap_summary phase=ext ticks=50 resizes=25 max_gap_us=16842
2496836 f03_x11 gap_summary phase=drain ticks=25 resizes=0 max_gap_us=16036
2496849 f03_x11 finding modal_loop=absent max_gap_storm_us=17835 errors=0

# same binary, icewm running (every resize WM-mediated via ConfigureRequest)
2496546 f03_x11 gap_summary phase=calm ticks=31 resizes=0 max_gap_us=16092
2496564 f03_x11 gap_summary phase=self ticks=50 resizes=25 max_gap_us=17270
2496582 f03_x11 gap_summary phase=ext ticks=50 resizes=25 max_gap_us=17294
2496599 f03_x11 gap_summary phase=drain ticks=25 resizes=0 max_gap_us=16071
2496617 f03_x11 finding modal_loop=absent max_gap_storm_us=17294 errors=0
```

The tick clock runs at 16 ms. The worst inter-frame gap across **100 storm
ticks and 50 resizes per run** — each resize triggering the deliberately
worst-case full MIT-SHM segment realloc from [F02](./f02-resize.md) — was
**17.8 ms** (bare) / **17.3 ms** (icewm): about 1.5 ms over one period, i.e.
ordinary scheduling jitter plus realloc cost, not a stall. Animation never
missed a beat (`presented=0` count: zero in both runs).

## The loop nothing can take away

The demo's architecture is the one a framework owns on X11 — a single
`poll(2)` over two file descriptors:

| fd                       | role                                                                                                              |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| `XConnectionNumber(dpy)` | the X socket: `ConfigureNotify`, `Expose`, SHM completions                                                        |
| [`timerfd`][timerfd]     | the app's own animation clock, 16 ms interval (the ~2 Hz color cycle advances 8/256 of a hue revolution per tick) |

Every tick fills the window with the next color and presents via
`XShmPutImage`; every X event is drained between ticks. The structural reason
no modal loop can exist: X11 is a **wire protocol on a socket**, and the
server has no mechanism to call back into the client or re-enter its stack.
There is no X equivalent of `DefWindowProc` — nothing that can run a nested
`GetMessage` loop on the app's thread, which is exactly what Win32's
moving/sizing loop does. The only thing a resize can do to an X client is make
its fd readable.

One storm step from the bare run — request, tick, notify, realloc, tick — all
gaps nominal:

```text
512651 f03_x11 step name=XResizeWindow conn=self n=1 size=640x400
512813 f03_x11 tick t=512813 n=32 phase=self presented=1 gap_us=16075
512836 f03_x11 resize size=640x400 scale=1
513100 f03_x11 buffer_realloc size=640x400 shm=1
529246 f03_x11 tick t=529246 n=33 phase=self presented=1 gap_us=16433
```

And the same step under icewm, where the `XResizeWindow` is no longer a
command but a `ConfigureRequest` the WM grants (the
[F02 finding](./f02-resize.md#wm-mediated-resize--xresizewindow-becomes-a-request-to-the-wm)) —
the grant takes longer, the ticks don't care:

```text
512435 f03_x11 step name=XResizeWindow conn=self n=1 size=640x400
512543 f03_x11 tick t=512543 n=32 phase=self presented=1 gap_us=16019
512824 f03_x11 resize size=640x400 scale=1
513186 f03_x11 buffer_realloc size=640x400 shm=1
529090 f03_x11 tick t=529090 n=33 phase=self presented=1 gap_us=16547
```

## Findings

- **Max inter-frame gap during interaction (the [F03][f03] headline number):**

  | Variant                                     | Max gap (storm) | Baseline (calm) | Tier |
  | ------------------------------------------- | --------------- | --------------- | ---- |
  | Self-resize storm, bare Xvfb                | 17 835 µs       | 16 071 µs       | A    |
  | External-connection storm, bare Xvfb        | 16 842 µs       | 16 071 µs       | A    |
  | Self + external storms, WM-mediated (icewm) | 17 294 µs       | 16 092 µs       | A    |
  | Interactive border/title drag, real session | — pending       | —               | C    |

- **There is nothing to instrument.** The spec's `modal_enter`/`modal_exit`
  events have no X11 source to hook: no protocol event, no Xlib callback, no
  state transition marks "interactive resize began". The demo logs
  `finding modal_loop=absent` because the platform offers literally no signal
  to log — the asymmetry the [F03 spec][f03] (requirement 5) predicts. Even
  _detecting_ a user-driven resize on X11 requires heuristics (the
  [F02](./f02-resize.md) finding that `ConfigureNotify` carries no attribution
  applies in full).
- **No thread is ever captured.** On Win32 the modal loop runs on the window's
  thread inside `DefWindowProc`, so a framework must either inject timers into
  the loop it no longer controls (`SetTimer`/`WM_TIMER`), or move rendering to
  another thread — the techniques the [F03 spec][f03] enumerates. On X11 the
  question dissolves: the framework's `poll` loop _is_ the only loop, so a
  timer-driven render path needs no platform cooperation at all. For a
  framework's loop-ownership design this makes X11 the easy column: own loop,
  own clock, no re-entrancy.
- **The WM does not change the answer, only the latency.** Under icewm every
  resize becomes WM-mediated (`ReparentNotify` at startup, grants batched and
  delayed up to ~5 ms per [F02](./f02-resize.md)) — yet the WM is _another
  client_, racing requests on its own connection, not a controller of ours.
  Max gap under icewm was within 0.5 ms of the bare run.
- **The structural caveat from F02 still applies:** ticks during a resize
  present at the authoritative-so-far size, so a few frames per storm are
  stale-sized (X11's notify-not-negotiate artifact, harmless to cadence).
- **Interactive drag is Tier C by honesty.** `xdotool`-style synthesis or a
  second connection (the `ext` phase) reproduces the _protocol_ traffic of a
  WM resize, but a human dragging an `icewm` border continuously is a
  different input pattern (opaque-resize storms throttled by the WM's own
  pointer-event rate). The manual run is queued in the
  [manual-run queue](../manual-run-queue.md); expectation (Tier C,
  `[expected, unverified]`): gaps stay ~16 ms because nothing in the protocol
  changes.

## Build and run

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f03-modal-loop
nix develop -c xvfb-run -a env WSI_AUTO_EXIT=1 \
    dub run --root=docs/research/window-system-integration/os-apis/x11/examples/f03-modal-loop
```

For the WM-mediated variant, run the built binary inside Xvfb with `icewm`
started first (Xvfb itself ships no WM):

```bash
nix develop -c nix shell nixpkgs#icewm -c xvfb-run -a bash -c \
    'icewm & sleep 2; WSI_AUTO_EXIT=1 docs/research/window-system-integration/os-apis/x11/examples/f03-modal-loop/build/f03_modal_loop_x11'
```

Without `WSI_AUTO_EXIT` the demo ticks until `WM_DELETE_WINDOW` or a key press
(the interactive Tier-C mode: drag the window and watch the `tick … gap_us=`
stream). `WSI_NO_SHM=1` forces the `XPutImage` presentation path; no reachable
display prints `SKIP: no X11 display` and exits 0. The demo exits non-zero if
any X protocol error was reported.

## Sources

- **[F03 spec][f03]** — requirements 1, 2 and 5 (the color cycle, bounded
  inter-frame deltas, and the "no modal loop is itself the finding" clause);
  the Win32 techniques contrasted above are its requirement 3.
- **[`WM_ENTERSIZEMOVE`][entersizemove] (Microsoft Learn)** — the Win32 modal
  loop this demo proves X11 does not have ("sent one time to a window after it
  enters the moving or sizing modal loop").
- **[X11 F02 findings](./f02-resize.md)** — the resize-storm machinery this
  demo reuses: WM-mediated `ConfigureRequest` redirection, external-connection
  resizes, per-notify SHM realloc, stale frames.
- **[X11 scaffold findings](./scaffold.md)** — the `poll(2)` loop base, the
  MIT-SHM completion contract gating each present, ImportC macro
  re-declaration discipline.
- **[`timerfd_create(2)`][timerfd]** — the animation clock (a timer as a file
  descriptor, so one `poll` multiplexes time and protocol).
- Demo sources: [`app.d`](./examples/f03-modal-loop/app.d),
  [`instrument.d`](./examples/f03-modal-loop/instrument.d), and the `c.c`
  ImportC shim alongside them.

<!-- References -->

[f03]: ../features/f03-modal-loop.md
[entersizemove]: https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-entersizemove
[timerfd]: https://man7.org/linux/man-pages/man2/timerfd_create.2.html
