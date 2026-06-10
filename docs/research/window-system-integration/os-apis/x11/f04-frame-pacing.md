# X11 F04 — vsync / frame pacing (the Present extension)

Core X11 has **no frame clock**: nothing in the core protocol says "draw now"
or "your frame is on glass" (the [F01 finding](./f01-first-pixel.md#what-presented-means-on-x11)).
The platform primitive the [F04 spec][f04] names is the **[Present
extension][present]** — "a way for applications to update their window
contents from a pixmap in a well defined fashion, synchronizing with the
display refresh" ([presentproto][present], §1). The demo,
[`./examples/f04-frame-pacing/app.d`](./examples/f04-frame-pacing/app.d),
drives a trivially cheap solid-color flip from Present's completion events
only — no sleeps, no busy loop — logging `frame_callback t=<ust> msc=<msc>`
for 600 frames, printing min/median/p99/max + a jitter histogram, probing what
the clock does while the window is unmapped, and falling back to a plain
timerfd redraw when Present is absent (forced with `WSI_NO_PRESENT=1`). All
runs Tier A under `xvfb-run` (plus an `Xephyr` cross-check), exit 0 — with the
spec-mandated caveat that a headless server's refresh is synthetic, which
turns out to be the most instructive finding of the run.

**Last reviewed:** June 10, 2026

## The verdict lines

```text
# Present path (Xvfb): 600 frames driven by PresentCompleteNotify
stats path=present frames=600 deltas=599 min_us=15131 median_us=17107 p99_us=17271 max_us=22088
histogram bucket=12-16ms count=3
histogram bucket=16-20ms count=595
histogram bucket=20-33ms count=1

# fallback path (WSI_NO_PRESENT=1): 600 frames from a 16.67 ms timerfd
stats path=timer frames=600 deltas=599 min_us=15865 median_us=16667 p99_us=16682 max_us=17528
histogram bucket=12-16ms count=1
histogram bucket=16-20ms count=598
```

Median 17.1 ms / p99 17.3 ms / worst 22.1 ms on the Present path; long-run
average **16 675.5 µs per frame = 59.97 Hz** with `msc` advancing exactly +1
per frame. Note the fallback timerfd is _steadier_ than Xvfb's Present clock
(p99 16 682 µs vs 17 271 µs) — see the synthetic-clock caveat below.

## Why xcb — and the interop tax

Present has **no Xlib binding**; the API exists only in xcb
([`xcb/present.h`][xcb-present]). The [scaffold's](./scaffold.md) choice of
Xlib as this tree's default binding therefore forces a decision for this one
demo: rewrite everything in pure xcb, or use the documented
[Xlib/XCB interop][mixing] layer. The demo chooses interop — window creation,
atoms, and drawing stay Xlib (identical lineage to the other demos), while
`XGetXCBConnection` (from `X11/Xlib-xcb.h`) exposes the shared
`xcb_connection_t` for the Present calls. That requires
`XSetEventQueueOwner(dpy, XCBOwnsEventQueue)` **immediately after
`XOpenDisplay`**, after which _all_ events must be read with
`xcb_poll_for_event` — Present's completions arrive as XGE generic events that
Xlib's queue would otherwise swallow. Two real costs surfaced:

- **The silent-flush trap.** `XPending` flushes Xlib's output buffer;
  `xcb_poll_for_event` does **not**. On the fallback path (no xcb requests at
  all) the demo's `XMapWindow` sat unsent in the client forever — a clean
  deadlock waiting for an `Expose` the server never knew to send. The Present
  path was rescued _by accident_: the first `xcb_present_*` call makes xcb
  take the socket back from libX11, forcing the flush. The fix is one
  explicit `XFlush` after setup; the lesson is that the interop layer splits
  "queue a request" from "send it" across two libraries.
- **An ImportC layout trap.** xcb declares
  `xcb_present_complete_notify_event_t` `XCB_PACKED`
  (`__attribute__((__packed__))`): on the wire `msc` sits at byte offset 36,
  unaligned for a `uint64_t`. ImportC (ldc 1.41) silently ignores the packed
  attribute — the imported struct is 48 bytes with `msc` at offset 40, so
  reading it yields garbage. The demo re-declares the 44-byte wire layout in D
  with `align(1)` and `static assert`s both sizes (the same re-declaration
  discipline as the [scaffold's macro constants](./scaffold.md#surprises),
  now applied to a struct).

## The Present contract

What the demo exercises, per [presentproto][present] (v1.4):

- **Subscription:** `xcb_present_select_input(eid, window, COMPLETE_NOTIFY)` —
  Present events are delivered to an explicitly allocated event context
  (`PRESENTEVENTID`), not to the window's event mask.
- **Scheduling:** [`PresentNotifyMSC`][present] "delivers a
  `PresentCompleteNotifyEvent` with kind `PresentCompleteKindNotifyMSC` after
  the time specified by 'target-msc', 'divisor' and 'remainder'", where "if
  'target-msc' is greater than the current msc for 'window', the event will be
  delivered at (or after) the 'target-msc' field". The demo seeds the chain
  with `target_msc=0` (completes at the current msc, establishing the
  baseline) and then requests `msc+1` after each completion — one wakeup per
  display frame, the X11 equivalent of a Wayland `wl_surface.frame` callback.
- **The completion event:** `PresentCompleteNotify` carries `kind` (a pixmap
  presentation vs an msc notification), `mode`, and the two clocks — "'msc'
  and 'ust' indicate the frame count and system time when the presentation
  actually occurred". For _pixmap_ completions, `mode` discloses how the
  frame reached the screen: `PresentCompleteModeCopy` ("the source pixmap
  contents are taken from the pixmap and the pixmap is idle immediately"),
  `PresentCompleteModeFlip` ("the pixmap remains in-use even after the
  presentation completes"), or `PresentCompleteModeSkip` ("the presentation
  operation was skipped because some later operation made it irrelevant").
- So Present conveys **actual presentation time** (`ust`, microseconds on the
  server's monotonic clock; `msc`, the frame counter) — not merely "draw now".
  That answers the [F04][f04] "presentation time or draw-now?" question for
  X11: _with_ Present it is the strongest contract in this survey tree;
  _without_ it there is nothing at all.

> [!NOTE]
> The demo paces with `PresentNotifyMSC` and draws with core requests,
> isolating the _clock_ from the _transport_. A production renderer would
> instead submit frames with `PresentPixmap` and pace on its
> `kind=PresentCompleteKindPixmap` completions (getting the Copy/Flip/Skip
> `mode` per real frame) — same event machinery, one extra concept (the
> pixmap).

## The instrumented run

```text
234 f04_x11 step name=XGetXCBConnection fd=3 queue_owner=xcb
260 f04_x11 step name=xcb_get_extension_data ext=Present present=1 major_opcode=147 first_event=0
283 f04_x11 step name=xcb_present_query_version version=1.2
354 f04_x11 step name=xcb_present_select_input eid=0x200003 mask=COMPLETE_NOTIFY
536 f04_x11 first_pixel_presented method=XFillRectangle note=no_confirmation_without_Present
547 f04_x11 step name=xcb_present_notify_msc target=current note=chain_seed
554 f04_x11 frame_callback t=478390540870 msc=28704581 mode=0 frame=1
22648 f04_x11 frame_callback t=478390562958 msc=28704582 mode=0 frame=2
39798 f04_x11 frame_callback t=478390580088 msc=28704583 mode=0 frame=3
55952 f04_x11 frame_callback t=478390596243 msc=28704584 mode=0 frame=4
```

### Xvfb advertises Present — but its clock is a software timer

**Xvfb does advertise Present** (version 1.2, major opcode 147 here), and the
notify chain runs at a clean 60 Hz. But Xvfb has no display and no vblank
interrupt: the X server's Present core falls back to its software vblank
emulation ([`present/present_fake.c`][present-fake] — "fake" is the in-tree
name), which schedules msc ticks off OS timers at the screen's nominal rate.
The numbers betray the emulation twice over:

- `msc × 16 666.67 µs ≈ ust` to within seconds-of-uptime — the counter is
  CLOCK_MONOTONIC divided by a hardcoded 60 Hz interval, not a count of
  anything that happened on a screen;
- per-frame jitter (min 15.1 / p99 17.3 / max 22.1 ms) is _worse_ than the
  demo's own naive timerfd (p99 16.68 ms) — a hardware vblank would beat
  both, but a timer-fed msc inherits server scheduling noise.

The `Xephyr` cross-check (nested inside Xvfb, 60 frames) confirms the same
shape: Present 1.2, msc +1 per frame, average 60.2 Hz — Xephyr presents into
a parent X window and has no vblank of its own either. **All numbers in this
doc are headless-only** per the [F04 spec][f04]'s caveat; the same binary on a
real display (where `ust`/`msc` come from the DRM page-flip path) is the
pending Tier-C cross-check.

### Occlusion: the clock does not stop

After frame 600 the demo unmaps the window for 3 s and keeps the
`PresentNotifyMSC` chain running:

```text
9989215 f04_x11 step name=XUnmapWindow note=occlusion_probe_3s
10005329 f04_x11 frame_callback t=478400545630 msc=28705181 mode=0 occluded=1
13005758 f04_x11 occlusion frames_while_unmapped=181 duration_ms=3000 clock=present
```

**181 completions in 3 000 ms — full 60 Hz, zero throttling.** An unmapped
window's msc keeps ticking and `PresentNotifyMSC` keeps completing (at least
on the fake-vblank path; nothing in [presentproto][present] promises
throttling on any path). This is the exact inverse of Wayland, where
`wl_surface.frame` callbacks for an occluded surface simply stop arriving. A
framework's `requestRedraw` cannot rely on X11 to pace a hidden window down —
visibility-based throttling is the framework's own job (core X11 doesn't even
deliver `VisibilityNotify` unless asked). The fallback path free-runs while
unmapped too (180/3 000 ms), trivially: it is the app's own timer.

## The fallback path — and what X11 lacks vs Wayland

When Present is absent (`xcb_get_extension_data` reports no extension — or
`WSI_NO_PRESENT=1` forces it), the demo degrades to a 16.67 ms
[`timerfd`][timerfd] driving unconfirmed `XFillRectangle` + `XFlush` redraws:
steady (p99 16 682 µs) but **open-loop** — the [F04 spec][f04]'s
"record the absence as the finding" clause:

- nothing ties the timer to the display's actual rate (a 60 Hz timer on a
  144 Hz panel renders 60; on a 30 Hz panel it wastes half its frames);
- nothing confirms presentation (the F01 caveat in full: `XSync` proves
  processing, not pixels);
- nothing slows down when the window is invisible.

The structural comparison the survey needs: **Wayland's frame callback is a
core-protocol, per-surface throttling hint — X11 has no equivalent outside
Present.** A `wl_surface.frame` request costs one protocol object and the
compositor answers "now is a good time to draw your next frame", per surface,
automatically paused while occluded. On X11 the _only_ refresh-coupled,
per-window signal is the Present extension's event machinery (an extension
a server may lack, with an xcb-only API, an event-context concept, and —
headless — a synthetic clock); absent that, a toolkit is back to its own
timers. This is why every cross-platform framework's X11 backend either talks
Present/DRI3 (via GL/Vulkan swapchains) or simply free-runs on a timer.

## Findings

- **Jitter (Xvfb, headless-only):** Present path min 15 131 / median 17 107 /
  p99 17 271 / max 22 088 µs over 599 deltas, long-run 59.97 Hz; timer
  fallback min 15 865 / median 16 667 / p99 16 682 / max 17 528 µs.
  Timestamps: `ust` is server CLOCK_MONOTONIC microseconds; fallback uses the
  demo's own monotonic clock.
- **The primitive conveys presentation time, not "draw now"** — `ust`/`msc`
  are "when the presentation actually occurred" ([presentproto][present]) —
  but only when the extension is present; core X11 conveys nothing.
- **Hidden windows are not throttled** (181 completions / 3 s unmapped) —
  `requestRedraw` policy must come from the framework, unlike Wayland where
  the compositor enforces it.
- **Xvfb/Xephyr advertise Present 1.2 with a synthetic 60.0 Hz msc**
  (`present_fake.c` timer; msc ≈ ust / 16 666.67 µs) — headless CI can
  exercise the full Present code path but proves nothing about real vblank
  cadence.
- **Toolchain traps:** ImportC drops `XCB_PACKED` (re-declare the event
  struct with `align(1)` + `static assert` the size), and mixed Xlib/xcb
  event ownership drops `XPending`'s implicit flush (one `XFlush` after
  setup, or deadlock).

## Build and run

```bash
nix develop -c dub build --root=docs/research/window-system-integration/os-apis/x11/examples/f04-frame-pacing
nix develop -c xvfb-run -a \
    dub run --root=docs/research/window-system-integration/os-apis/x11/examples/f04-frame-pacing
```

The run is self-bounded: 600 frames (override with `WSI_FRAMES=n`), the 3 s
occlusion probe, stats on stdout, exit. `WSI_NO_PRESENT=1` selects the
timer-fallback path at runtime. The Xephyr variant nests a real windowed
server inside Xvfb:

```bash
nix develop -c nix shell nixpkgs#xorg.xorgserver -c xvfb-run -a bash -c \
    'Xephyr :55 -screen 800x600 & sleep 3; \
     DISPLAY=:55 WSI_FRAMES=60 docs/research/window-system-integration/os-apis/x11/examples/f04-frame-pacing/build/f04_frame_pacing_x11'
```

No reachable display prints `SKIP: no X11 display` and exits 0.

## Sources

- **[The Present Extension protocol specification][present]** (v1.4, Keith
  Packard) — all verbatim quotes above: the §1 purpose sentence,
  `PresentNotifyMSC` delivery semantics, `PresentCompleteNotify`'s
  `kind`/`mode`/`ust`/`msc` field contracts.
- **[`xcb/present.h`][xcb-present]** — the generated xcb API the demo calls
  (`xcb_present_query_version`, `xcb_present_select_input`,
  `xcb_present_notify_msc`) and the `XCB_PACKED` event struct.
- **[Mixing Calls to Xlib and XCB][mixing]** — `XGetXCBConnection`,
  `XSetEventQueueOwner`, and the event-queue-ownership rule the interop
  section describes.
- **[`present/present_fake.c`][present-fake]** (xorg-server) — the software
  vblank emulation behind Xvfb's synthetic msc.
- **[F04 spec][f04]** — requirements 1–3 (Present-driven redraw, 600-frame
  stats, occlusion behavior) and the headless caveat.
- **[X11 F01 findings](./f01-first-pixel.md)** — why core X11 cannot confirm
  presentation; **[X11 scaffold findings](./scaffold.md)** — the Xlib base
  and the ImportC re-declaration discipline.
- **[`timerfd_create(2)`][timerfd]** — the fallback clock.
- Demo sources: [`app.d`](./examples/f04-frame-pacing/app.d),
  [`instrument.d`](./examples/f04-frame-pacing/instrument.d), and the `c.c`
  ImportC shim alongside them.

<!-- References -->

[f04]: ../features/f04-frame-pacing.md
[present]: https://gitlab.freedesktop.org/xorg/proto/xorgproto/-/blob/master/presentproto.txt
[xcb-present]: https://gitlab.freedesktop.org/xorg/lib/libxcb/-/blob/master/src/present.xml
[mixing]: https://xcb.freedesktop.org/MixingCalls/
[present-fake]: https://gitlab.freedesktop.org/xorg/xserver/-/blob/master/present/present_fake.c
[timerfd]: https://man7.org/linux/man-pages/man2/timerfd_create.2.html
