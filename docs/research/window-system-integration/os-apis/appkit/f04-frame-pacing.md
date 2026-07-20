# AppKit F04 — vsync / frame pacing

How macOS hands an app its native frame clock, per the [F04 feature spec][f04]:
redraw of a trivially cheap frame (solid color flip) paced by a
[`CADisplayLink`][cadisplaylink] obtained from the view via the macOS 14+
[`displayLinkWithTarget:selector:`][nsview-displaylink] API (the old
[`CVDisplayLink`][cvdisplaylink] C API being deprecated since macOS 15 — verbatim
SDK quote [below](#cvdisplaylink-is-deprecated--the-replacement-is-this-demos-api)),
with 600 `frame_callback` events logged, jitter statistics and a histogram printed
at exit, an `NSTimer` fallback path so the demo always completes headless, and an
`orderOut:` occlusion probe mid-run. The program is
[`./examples/f04-frame-pacing/app.d`][demo-app] (with the shared
[`instrument.d`][instrument] logger), built on the [scaffold][scaffold] recipe.

**Last reviewed:** June 10, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn` (aarch64-darwin,
macOS 26.3.1, LDC 1.41.0) over SSH with the console session **locked** (windows
register with the WindowServer but are not composited — the scaffold's
[sidecar evidence][sidecar]). For this demo the locked screen is not a footnote but
the **headline finding**: the display link never fires in that state, so every
number below the fold is the _fallback timer's_ jitter, not display-link cadence —
see [the caveat](#what-the-locked-screen-distorts).

| Measurement                           | Value                                                                                |
| ------------------------------------- | ------------------------------------------------------------------------------------ |
| `NSScreen.maximumFramesPerSecond`     | **120** (ProMotion panel; the nominal cadence reference)                             |
| `CADisplayLink` fires, locked console | **0** — silent despite `isPaused=0` and `occlusionState` reporting _visible_         |
| Watchdog → `NSTimer` fallback         | after **3.09 s** of silence; the 16 ms timer then paced all 600 frames               |
| Timer-path jitter (n=597)             | min **1.4** / median **16.1** / p99 **36.1** / max **44.7** ms                       |
| Histogram mode                        | **485/597** deltas in the 13–18 ms bucket (run 2; run 1: 507/597)                    |
| Occlusion probe (`orderOut:` 3 s)     | timer path unaffected: **186 frames while hidden**, resume gap **17.8 ms**           |
| `occlusionState` while console locked | `0x2002` (**visible bit set**) — AppKit-side visibility ≠ WindowServer compositing   |
| Exit                                  | clean `0` both runs (`frames=600 frames_displaylink=0 frames_timer=600 fell_back=1`) |

---

## What the demo does

The scaffold's window + a D-defined `FlipView` whose `drawRect:` fills the window
with a solid color alternating per paced frame — the cheapest possible "render".
Nothing sleeps and nothing busy-loops; every redraw is requested by a clock callback:

1. **Path selection.** If `NSView` responds to
   [`displayLinkWithTarget:selector:`][nsview-displaylink] (macOS 14+; checked via
   `respondsToSelector:`), the view creates a [`CADisplayLink`][cadisplaylink] —

   > A timer object that allows your app to synchronize its drawing to the refresh
   > rate of the display.

   — and adds it to the main run loop in `NSRunLoopCommonModes` (the link is
   created _unscheduled_; and common modes so the clock also survives tracking
   loops, per [F03][f03-doc]). Otherwise → the timer path directly
   (`path_select path=timer reason=no_displaylink_api`).

2. **Per fire:** `frame_callback t=… target=… path=displaylink|timer` (the values
   of `link.timestamp` and `link.targetTimestamp`) —
   `timestamp`/[`targetTimestamp`][targettimestamp] are
   `CFTimeInterval` seconds on the `CACurrentMediaTime`/`mach_absolute_time`
   timebase, i.e. the link conveys both "now" and the _intended presentation
   deadline_, not merely "draw now". 600 frames are collected.
3. **Watchdog fallback.** A 100 ms scheduler timer (common modes) watches the
   clock: >3 s without a fire (outside the deliberate hidden phase) → log
   `watchdog … action=fallback_timer`, invalidate the link, and start a repeating
   ~16 ms `NSTimer` that drives the same accounting with `path=timer`. The demo
   therefore always completes, headless or not; the two paths are never conflated
   in the stats line's provenance (`frames_displaylink`/`frames_timer` counters).
4. **Occlusion probe.** At ~6 s (or frame 300) the window is sent
   [`orderOut:`][orderout] for ~3 s, then `makeKeyAndOrderFront:` again; the demo
   logs `vis_change`, frames observed while hidden, the resume gap, and every
   [`windowDidChangeOcclusionState:`][occlusionstate] delegate callback.
5. **At exit:** min/median/p99/max inter-frame delta plus a coarse histogram
   (the resume gap after the probe is logged separately as `resume_gap`, not mixed
   into the jitter stats), and a hard 30 s deadline guarantees termination.

---

## The headline `A[ssh]` finding: a locked console silences CADisplayLink

Two runs, identical shape. The opening of run 2, verbatim:

```text
0       APPKIT_F04 init_start target_frames=600 deadline_ms=30000
43966   APPKIT_F04 screen_info max_fps=120
78671   APPKIT_F04 window_created scale=2.0 occlusion_state=8192
90450   APPKIT_F04 path_select path=displaylink api=NSView_displayLinkWithTarget paused=0
90483   APPKIT_F04 step name=NSApp_run
171742  APPKIT_F04 vis_change state=occlusion occlusion_state=8194 visible=1
3093869 APPKIT_F04 watchdog displaylink_silent_ms=3093 frames_so_far=0 link_paused=0 occlusion_state=8194 action=fallback_timer
3094002 APPKIT_F04 path_select path=timer interval_ms=16
3110501 APPKIT_F04 frame_callback t=3.110500 target=3.126500 path=timer
```

- The link is created successfully, reports **`paused=0`**, and AppKit even flips
  the window's [`occlusionState`][occlusionstate] to `0x2002` (the
  `NSWindowOcclusionStateVisible` bit) — every API-visible signal says "you will
  get frames". **Zero fires arrive in 3 s** (nor at any later point; both runs,
  `frames_displaylink=0`). With the console locked the WindowServer is not
  compositing, and a display link is driven by the display refresh pipeline, not by
  the run loop — no composited frames, no callbacks. The starvation is invisible to
  the app except as silence: no error, no pause flag, no occlusion change.
- **For a framework this is the contract:** `CADisplayLink` is a _conditional_
  clock. A `requestRedraw` built on it must carry its own liveness watchdog (as
  this demo does) or animations will silently hang in exactly the states — locked
  screen, fully occluded window, display asleep — a daemon-launched or
  backgrounded app actually encounters. The same is documented for Wayland frame
  callbacks ([spec point 3][f04]); macOS merely adds that the _visibility signals
  can all still look green_, as measured above.
- The fallback fired 16.5 ms after `path_select` and paced the rest of the run.

### Timer-path pacing (the numbers the locked screen leaves us)

```text
12838915 APPKIT_F04 step name=finish reason=frames
12839077 APPKIT_F04 stats n=597 min_ms=1.361 median_ms=16.139 p99_ms=36.067 max_ms=44.664
12839159 APPKIT_F04 histogram bucket_ms=<2 count=1
12839185 APPKIT_F04 histogram bucket_ms=2-4 count=2
12839209 APPKIT_F04 histogram bucket_ms=9-13 count=31
12839232 APPKIT_F04 histogram bucket_ms=13-18 count=485
12839255 APPKIT_F04 histogram bucket_ms=18-25 count=71
12839326 APPKIT_F04 histogram bucket_ms=25-40 count=3
12839349 APPKIT_F04 histogram bucket_ms=40-100 count=4
12839372 APPKIT_F04 loop_exit frames=600 frames_displaylink=0 frames_timer=600 draws=598 hidden_frames=186 fell_back=1
```

A 16 ms repeating `NSTimer` on a quiet machine: median dead-on (16.1 ms), but a
~36 ms p99 and ~45 ms max — `NSTimer` makes no scheduling promises and run-loop
load shows up directly as multi-period jitter (the [scaffold][scaffold] reached the
same "an `NSTimer` is a refresh _requester_, not a frame clock" conclusion from the
coalescing side). 598 draws for 600 ticks: two dirty marks coalesced into one
drawing pass. Run 1 reproduced everything within noise
(median 16.4 / p99 35.6 / max 42.4 ms; 507/597 in 13–18 ms).

### Occlusion probe: an NSTimer doesn't care, and AppKit's occlusion tracks `orderOut:` even on a locked console

```text
6095782 APPKIT_F04 vis_change state=hidden api=orderOut frames=186 link_paused=0
6403118 APPKIT_F04 vis_change state=occlusion occlusion_state=8192 visible=0
9197032 APPKIT_F04 vis_change state=visible api=makeKeyAndOrderFront hidden_frames=186 link_paused=0
9208219 APPKIT_F04 resume_gap gap_ms=17.8
9243446 APPKIT_F04 vis_change state=occlusion occlusion_state=8194 visible=1
```

- On the **timer path** the probe answers as expected: the clock free-runs —
  exactly **186 frames** during the 3 s hidden window (3 s / 16.1 ms), and the
  first post-show delta (17.8 ms) is one ordinary period. An `NSTimer`-paced
  renderer burns CPU drawing a window nobody can see; throttling-when-hidden is
  entirely the app's job on this path.
- The `windowDidChangeOcclusionState:` callbacks show AppKit's occlusion machinery
  _does_ respond to `orderOut:`/`makeKeyAndOrderFront:` (visible bit cleared ~0.3 s
  after hide, restored after show) even while the console is locked — so
  `occlusionState` distinguishes _window-level_ visibility but evidently not
  _session-level_ compositing (it claimed visible during the whole link silence
  above). A framework needs both signals.
- The probe's real target — "does **CADisplayLink** pause on `orderOut:`?"
  ([Apple's API][nsview-displaylink] ties the view link to the view's
  window/display) — could not be measured: the link was already silent. Queued
  Tier C ([below](#tier-c-the-display-link-on-a-real-unlocked-display)).

---

## CVDisplayLink is deprecated — the replacement is this demo's API

The pre-macOS-14 way to get a frame clock was CoreVideo's
[`CVDisplayLink`][cvdisplaylink] (a callback on a dedicated high-priority thread —

> A high-priority thread that notifies your app when a given display will need
> each frame.

— with all the cross-thread hand-off that implies). The macOS 26.3 SDK wraps the
entire C API in a deprecation bracket, `CVDisplayLink.h` verbatim:

```c
API_DEPRECATED_BEGIN("use NSView.displayLink(target:selector:), NSWindow.displayLink(target:selector:), or NSScreen.displayLink(target:selector:) ", macos(10.4, 15.0))
```

i.e. deprecated as of **macOS 15.0** in favor of the view/window/screen
[`displayLinkWithTarget:selector:`][nsview-displaylink] family used here, which
returns a [`CADisplayLink`][cadisplaylink] (long the iOS/UIKit frame clock)
delivered **on the run loop you choose** instead of a foreign thread, and which
automatically tracks the display the view actually sits on. For a new framework
there is no reason to touch `CVDisplayLink` on macOS 14+; for older deployment
targets it remains the only native clock (with its thread-safety tax).

---

## What the locked screen distorts

Explicitly, per the [F04 spec][f04]'s headless caveat:

- **All jitter numbers above are `NSTimer` numbers.** Real `CADisplayLink` cadence
  (expected: ~8.33 ms deltas at `max_fps=120`, `targetTimestamp − timestamp` ≈ one
  refresh period, ProMotion possibly varying the rate) is unmeasured — Tier C.
- **The 0-fires result is a true finding but a _session_ property**, not proof the
  link can't fire over SSH per se: the WindowServer accepted the window and
  AppKit's occlusion bit even reads visible; what is missing is compositing of the
  locked session. An unlocked-console SSH run may behave differently (the Tier-C
  run will tell).
- The occlusion probe exercised the timer path only; `CADisplayLink`'s documented
  pause-on-invisibility is unverified here.

## Tier C: the display link on a real, unlocked display

Queued in the [manual-run queue][queue]: run `./demo` in an unlocked GUI session.
Expected/record: `path=displaylink` frames at ~8.33 ms cadence (120 Hz panel, or
ProMotion-variable), `target−t` ≈ one period, the stats/histogram block, whether
fires pause during the 3 s `orderOut:` window (`hidden_frames=0` + a ~3 s
`resume_gap` would confirm the documented view-visibility tracking), and whether
the watchdog stays silent (`fell_back=0`).

---

## Findings summary (for `event-sequences.md`)

- **The modern macOS frame clock is `CADisplayLink` via
  `displayLinkWithTarget:selector:`** (macOS 14+), run-loop-delivered; add it in
  `NSRunLoopCommonModes` or it freezes during live-resize ([F03][f03-doc]).
  `CVDisplayLink` is deprecated (macOS 15.0, SDK quote above).
- **The clock conveys timing, not just "draw now"**: `timestamp` (now) and
  `targetTimestamp` (presentation deadline) per fire, on the
  `mach_absolute_time` timebase.
- **It is a conditional clock with no failure signal**: under a locked console it
  delivers nothing while `isPaused=0` and `occlusionState=visible` — a framework's
  `requestRedraw` needs a liveness watchdog + degraded-mode timer (implemented
  here; it kept the demo green).
- **`NSTimer` as a fallback paces at median-exact but p99 ≈ 2 periods** (36 ms) —
  usable for liveness, not for smooth animation.
- **Visibility instrumentation:** `windowDidChangeOcclusionState:` tracks
  `orderOut:` within ~0.3 s even on a locked console; session compositing state is
  not exposed by any API this demo touched.

---

## Sources

- **This demo** — [`./examples/f04-frame-pacing/app.d`][demo-app],
  [`./examples/f04-frame-pacing/instrument.d`][instrument]; the
  [AppKit scaffold findings][scaffold] (recipe, build command — plus
  `-framework QuartzCore` for `CADisplayLink`) and the [AppKit survey][survey].
- **Feature specs** — [F04 frame pacing][f04]; the related [F03 modal
  loop][f03-doc] (run-loop modes) and [F01 first pixel][f01-doc]; the Tier-C entry
  in the [manual-run queue][queue].
- **Apple SDK** — `CVDisplayLink.h`, macOS 26.3 SDK (Xcode), quoted verbatim above.
- **Apple Developer documentation** (Wayback-pinned, bot-hostile host):
  [`CADisplayLink`][cadisplaylink] (quoted),
  [`displayLinkWithTarget:selector:`][nsview-displaylink],
  [`targetTimestamp`][targettimestamp], [`CVDisplayLink`][cvdisplaylink] (quoted),
  [`maximumFramesPerSecond`][maxfps], [`occlusionState`][occlusionstate],
  [`orderOut:`][orderout], [`NSTimer`][nstimer].

<!-- References -->

<!-- This tree -->

[survey]: ./index.md
[scaffold]: ./scaffold.md
[sidecar]: ./scaffold.md#windowserver-sidecar-evidence-assh
[demo-app]: ./examples/f04-frame-pacing/app.d
[instrument]: ./examples/f04-frame-pacing/instrument.d
[f04]: ../features/f04-frame-pacing.md
[f01-doc]: ./f01-first-pixel.md
[f03-doc]: ./f03-modal-loop.md
[queue]: ../manual-run-queue.md

<!-- Apple developer docs (Wayback-pinned, bot-hostile host) -->

[cadisplaylink]: https://web.archive.org/web/20260130203417/https://developer.apple.com/documentation/quartzcore/cadisplaylink
[nsview-displaylink]: https://web.archive.org/web/20250609073506/https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)
[targettimestamp]: https://web.archive.org/web/20250729175101/https://developer.apple.com/documentation/quartzcore/cadisplaylink/targettimestamp
[cvdisplaylink]: https://web.archive.org/web/20260317181110/https://developer.apple.com/documentation/corevideo/cvdisplaylink-k0k
[maxfps]: https://web.archive.org/web/20250609072956/https://developer.apple.com/documentation/appkit/nsscreen/maximumframespersecond
[occlusionstate]: https://web.archive.org/web/20191017131348/https://developer.apple.com/documentation/appkit/nswindow/occlusionstate
[orderout]: https://web.archive.org/web/20250609073606/https://developer.apple.com/documentation/appkit/nswindow/orderout(_:)
[nstimer]: https://web.archive.org/web/20250318115719/https://developer.apple.com/documentation/foundation/nstimer
