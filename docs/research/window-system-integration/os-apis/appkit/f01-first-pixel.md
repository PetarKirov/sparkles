# AppKit F01 — first pixel & init cost

How much machinery sits between `exec` and a software-drawn frame on macOS, per the
[F01 feature spec][f01]: one gradient frame, a `step name=…` event for **every**
initialization API call, and a clean exit right after presentation is confirmed. The
program is [`./examples/f01-first-pixel/app.d`][demo-app] (with the shared
[`instrument.d`][instrument] logger) — the [scaffold][scaffold] minus its resize storm,
plus finer-grained init steps and an exit-on-first-pixel schedule.

**Last reviewed:** June 10, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn` (aarch64-darwin,
macOS 26.3.1, LDC 1.41.0) over SSH with the console session **locked** — windows
register with the WindowServer but are not composited (see the scaffold's
[sidecar evidence][sidecar]). The demo was run three times back-to-back to split
**cold** (first run) from **warm** (immediate re-runs).

| Measurement                            | Value                                                                                               |
| -------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `init_start` → `first_pixel_presented` | **130.4 ms cold**, **100.2 / 104.6 ms warm** `A[ssh]`                                               |
| Cold − warm delta                      | ~26–30 ms, all of it in the three WindowServer-heavy steps (see [below](#cold-vs-warm))             |
| Concepts to first pixel                | **11** distinct platform object/handle types (same set as the [scaffold][concepts])                 |
| LOC (`app.d`, excl. `instrument.d`)    | **402**                                                                                             |
| "Presented" means                      | return of the first [`drawRect:`][drawrect] — CoreAnimation may still defer compositing             |
| Exit                                   | clean `0` via `[NSApp stop:]` + synthetic event post, on the first timer tick after the first frame |

---

## The step sequence `A[ssh]`

The cold run (`WSI_AUTO_EXIT=1`, run 1), verbatim — timestamps are µs since
`init_start`:

```text
0      APPKIT_F01 init_start auto_exit=1
88     APPKIT_F01 step name=CGMainDisplayID
19312  APPKIT_F01 step name=CGMainDisplayID_returned id=1
19332  APPKIT_F01 step name=NSApplication_sharedApplication
46593  APPKIT_F01 step name=setActivationPolicy policy=regular
48141  APPKIT_F01 step name=NSWindow_alloc
48160  APPKIT_F01 step name=NSWindow_initWithContentRect size=480x320
86335  APPKIT_F01 step name=setTitle
87546  APPKIT_F01 window_created scale=2.0
87566  APPKIT_F01 step name=GradientView_alloc
87578  APPKIT_F01 step name=GradientView_initWithFrame
87595  APPKIT_F01 step name=setContentView
87659  APPKIT_F01 first_configure size=480x320 scale=2.0
87707  APPKIT_F01 step name=setDelegate
87784  APPKIT_F01 step name=makeKeyAndOrderFront
101369 APPKIT_F01 step name=activateIgnoringOtherApps
102090 APPKIT_F01 step name=NSTimer_scheduledTimerWithTimeInterval interval_ms=16
102110 APPKIT_F01 step name=NSApp_run
128395 APPKIT_F01 step name=first_drawRect_entered size=480x320
128423 APPKIT_F01 buffer_alloc size=960x640 bytes=2457600
130436 APPKIT_F01 first_pixel_presented t=1
130447 APPKIT_F01 frame_callback t=1
165553 APPKIT_F01 step name=NSApp_stop tick=1
165712 APPKIT_F01 loop_exit frames=1 ticks=1 first_pixel_us=130436
```

The demo confirms the [scaffold][scaffold]'s shape and adds the per-call split. Notable
orderings, all reproduced in every run:

- **`first_configure` is synchronous inside `setContentView:`** — the content view's
  first [`setFrameSize:`][setframesize] fires 64 µs into the setter, while it is still
  on the stack. There is no asynchronous configure phase on this platform.
- **`makeKeyAndOrderFront:` paints nothing.** The first [`drawRect:`][drawrect]
  arrives only inside `[NSApp run]`, ~26 ms after run-loop entry (the loop's first
  drawing pass).
- **The exit machinery is post-pixel**: the first `NSTimer` tick lands ~35 ms after the
  first frame (the run loop's first pass is busy), sees `first_pixel_presented`, and
  issues [`stop:`][nsapp-stop] + the synthetic-event post. Total process lifetime
  ≈ 166 ms for one frame.

## Cold vs warm

Per-step deltas across the three consecutive runs (ms; run 1 = cold process + cold
caches, runs 2–3 immediately after):

| Step (`step name=…`)                              | Cold (run 1) | Warm (run 2) | Warm (run 3) | Round-trip?                                  |
| ------------------------------------------------- | -----------: | -----------: | -----------: | -------------------------------------------- |
| `CGMainDisplayID` (headless guard)                |     **19.2** |         13.8 |         10.4 | **yes** — first WindowServer connection      |
| `NSApplication_sharedApplication`                 |     **27.3** |         17.6 |         20.8 | **yes** — app registration with the server   |
| `setActivationPolicy`                             |          1.5 |          1.5 |          1.5 | yes (small, constant)                        |
| `NSWindow_alloc`                                  |         0.02 |         0.03 |         0.02 | no — plain ObjC allocation                   |
| `NSWindow_initWithContentRect` (window device)    |     **38.2** |         27.8 |         29.9 | **yes** — server-side window creation        |
| `setTitle`                                        |          1.2 |          1.1 |          1.1 | yes (small)                                  |
| view alloc + `initWithFrame:` + `setContentView:` |         0.14 |         0.12 |         0.15 | no — `first_configure` fires locally         |
| `setDelegate`                                     |         0.08 |         0.08 |         0.08 | no                                           |
| `makeKeyAndOrderFront`                            |         13.6 |         14.7 |         14.1 | yes — ordering/mapping, **cold-insensitive** |
| `activateIgnoringOtherApps`                       |          0.7 |          0.6 |          0.7 | yes (small)                                  |
| `NSTimer` scheduling + `run` entry                |         0.04 |         0.05 |         0.05 | no                                           |
| `NSApp_run` → `first_drawRect_entered`            |         26.3 |         20.6 |         23.5 | run-loop first drawing pass                  |
| `drawRect:` body (render + blit 2.4 MB)           |          2.0 |          2.1 |          2.1 | no — CPU-bound                               |
| **Total `init_start` → `first_pixel_presented`**  |    **130.4** |    **100.2** |    **104.6** |                                              |

The cold−warm delta (~26–30 ms) is concentrated **entirely** in the three steps that
talk to the WindowServer for the first time: `CGMainDisplayID` (−5…−9 ms),
`sharedApplication` (−7…−10 ms), and `initWithContentRect:` (−8…−10 ms). Everything
purely local is identical across runs, and `makeKeyAndOrderFront:` (~14 ms) plus the
run-loop-to-first-draw gap (~20–26 ms) are warm-insensitive constants — they are the
floor AppKit imposes per window, not per process start.

> [!NOTE]
> The headless guard **is** the first round-trip (a scaffold finding the per-call split
> confirms): `CGMainDisplayID()` bootstraps the process's CoreGraphics WindowServer
> connection before `NSApplication` even exists, so "check for a display, then connect"
> is really "connect twice". A demo that skipped the guard would simply pay the same
> bootstrap inside `sharedApplication`.

## What "presented" means under CoreAnimation

`first_pixel_presented` is logged at the **return of the first `drawRect:`** — after
`CGContextDrawImage` has blitted the CPU gradient into the view's backing store. Per
the [F01 spec][f01]'s caveat, this is the strongest confirmation AppKit gives a
software renderer, and it is **not** proof of composited pixels:

- Views are layer-backed; `drawRect:` fills the layer's backing store, and the actual
  composite happens at the end-of-cycle `CATransaction` commit, after `drawRect:`
  returns. AppKit exposes no per-frame "presented" acknowledgement at this API level —
  nothing like Wayland's `frame` callback or a swapchain present fence.
- The platform's real frame clock is [`CADisplayLink`][cadisplaylink] (the
  [`CVDisplayLink`][cvdisplaylink] successor — `CVDisplayLink` was deprecated in
  macOS 15), whose callback timestamps are the closest AppKit gets to presentation
  feedback. That is deliberately out of scope here and is the [F04 frame-pacing
  demo][f04]'s territory.
- Under `A[ssh]` with the console locked, nothing is composited at all — the window is
  registered but `onscreen=false` (the scaffold's [sidecar evidence][sidecar]). On-screen
  confirmation of actual pixels is Tier C.

## Concepts and LOC

**11** distinct platform object/handle types are touched before `first_pixel_presented`
— the same set as the scaffold's [concepts table][concepts]: `NSApplication`,
`NSString`, `NSWindow`, `NSView` (the D-defined `GradientView` subclass), `SEL`,
`NSTimer`, `NSGraphicsContext`, `CGContextRef`, `CGColorSpaceRef`, `CGDataProviderRef`,
`CGImageRef`. (`NSEvent` is touched only _after_ the first pixel, by the exit
machinery; the autorelease-pool token and the `CGDirectDisplayID` are bookkeeping.)

LOC of [`app.d`][demo-app]: **402** (excluding `instrument.d`). Both numbers feed the
AppKit row of the [feature matrix][matrix].

---

## Sources

- **This demo** — [`./examples/f01-first-pixel/app.d`][demo-app],
  [`./examples/f01-first-pixel/instrument.d`][instrument]; the
  [AppKit scaffold findings][scaffold] (subclassing recipe, build command, baseline
  timings) and the [AppKit survey][survey].
- **Feature specs** — [F01 first pixel][f01]; the follow-ups [F02 resize][f02-doc]
  (this tree) and [F04 frame pacing][f04].
- **Apple Developer documentation** (Wayback-pinned, bot-hostile host):
  [`NSApplication`][nsapplication], [`NSWindow`][nswindow], [`NSView`][nsview],
  [`drawRect:`][drawrect], [`setFrameSize:`][setframesize],
  [`backingScaleFactor`][backingscalefactor], [`stop:`][nsapp-stop],
  [`NSTimer`][nstimer], [`CGImage`][cgimage], [`CADisplayLink`][cadisplaylink],
  [`CVDisplayLink`][cvdisplaylink].

<!-- References -->

<!-- This tree -->

[survey]: ./index.md
[scaffold]: ./scaffold.md
[concepts]: ./scaffold.md#concepts-to-first-pixel
[sidecar]: ./scaffold.md#windowserver-sidecar-evidence-assh
[demo-app]: ./examples/f01-first-pixel/app.d
[instrument]: ./examples/f01-first-pixel/instrument.d
[f01]: ../features/f01-first-pixel.md
[f04]: ../features/f04-frame-pacing.md
[f02-doc]: ./f02-resize.md
[matrix]: ../feature-matrix.md

<!-- Apple developer docs (Wayback-pinned, bot-hostile host) -->

[nsapplication]: https://web.archive.org/web/20260426230241/https://developer.apple.com/documentation/appkit/nsapplication
[nswindow]: https://web.archive.org/web/20260503224546/https://developer.apple.com/documentation/appkit/nswindow
[nsview]: https://web.archive.org/web/20260417192253/https://developer.apple.com/documentation/appkit/nsview
[drawrect]: https://web.archive.org/web/20250406152307/https://developer.apple.com/documentation/appkit/nsview/draw(_:)?language=objc
[setframesize]: https://web.archive.org/web/20250609073524/https://developer.apple.com/documentation/appkit/nsview/setframesize(_:)
[backingscalefactor]: https://web.archive.org/web/20251102044301/https://developer.apple.com/documentation/appkit/nswindow/backingscalefactor
[nsapp-stop]: https://web.archive.org/web/20250609072014/https://developer.apple.com/documentation/appkit/nsapplication/stop(_:)
[nstimer]: https://web.archive.org/web/20250318115719/https://developer.apple.com/documentation/foundation/nstimer
[cgimage]: https://web.archive.org/web/20260311104830/https://developer.apple.com/documentation/coregraphics/cgimage
[cadisplaylink]: https://web.archive.org/web/20190614134451/https://developer.apple.com/documentation/quartzcore/cadisplaylink
[cvdisplaylink]: https://web.archive.org/web/20250609094433/https://developer.apple.com/documentation/corevideo/cvdisplaylink
