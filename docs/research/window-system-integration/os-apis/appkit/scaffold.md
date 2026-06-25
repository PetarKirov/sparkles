# AppKit scaffold — findings

What it takes to go from "process starts" to "a CPU-rendered gradient is on screen, surviving
a resize storm, exiting cleanly" on macOS/AppKit — the [minimal window example][example]
evolved into the instrumented scaffold the [F01 first-pixel][f01] and [F02 resize][f02]
demos build on. The program is [`./examples/scaffold/app.d`][scaffold-app] (with
[`instrument.d`][instrument], the stderr event logger every other demo copies).

**Last reviewed:** June 10, 2026

All run findings below are **`A[ssh]`**: built and executed on `mac-bsn`
(aarch64-darwin, macOS 26.3.1, LDC 1.41.0 / DMD v2.111.0) over SSH with the
console session **locked** — the WindowServer accepts and registers windows in this
state, but does not composite them (see the [sidecar evidence](#windowserver-sidecar-evidence-assh)).

| Measurement                                 | Value                                                                                |
| ------------------------------------------- | ------------------------------------------------------------------------------------ |
| Concepts to first pixel                     | **11** distinct platform object/handle types (see [table](#concepts-to-first-pixel)) |
| LOC (`app.d`, excl. `instrument.d`)         | **391**                                                                              |
| `init_start` → `first_pixel_presented`      | **123.2 ms** `A[ssh]` (cold AppKit + WindowServer connection)                        |
| First geometry callback ("first configure") | first [`setFrameSize:`][setframesize], **synchronous inside `setContentView:`**      |
| Resize → redraw latency in the storm        | ~0.7 ms to `setFrameSize:`, ~4 ms to `drawRect:` return                              |
| Exit                                        | clean `0` via `[NSApp stop:nil]` + synthetic event post                              |

---

## What the scaffold adds over the example

[`./example/app.d`][example] proves the irreducible window-open sequence
(`sharedApplication` → `initWithContentRect:…` → `makeKeyAndOrderFront:`) and then
deliberately returns without running the loop. The scaffold,
[`./examples/scaffold/app.d`][scaffold-app], turns that into a real (still
nib-less, code-only) app:

- a **custom `NSView` subclass defined in D** (`GradientView`) whose
  [`drawRect:`][drawrect] blits a CPU-rendered 32-bit gradient via
  `CGDataProviderCreateWithData` → [`CGImageCreate`][cgimage] →
  `CGContextDrawImage` into the view's current `CGContext`;
- `[NSApp run]` as the loop, with a ~16 ms repeating [`NSTimer`][nstimer] driving
  `setNeedsDisplay:` (and the bounded-run schedule);
- a programmatic **`setFrame:display:` resize storm** (six content-size changes,
  per [F02][f02]) with per-resize buffer reallocation;
- clean termination both ways: `WSI_AUTO_EXIT=1` → [`stop:`][nsapp-stop] plus a
  synthetic `NSEventTypeApplicationDefined` post (without which `run` keeps
  blocking — `stop:` is only checked after an event dispatch); interactive close →
  `windowWillClose:` → `terminate:`;
- full [F01][f01]-style instrumentation (`<monotonic_us> <DEMO> <EVENT_KIND> k=v…`
  on stderr, via [`instrument.d`][instrument]).

The example is 117 LOC; the scaffold is 391 — the delta (~270 LOC) is the price of a
real draw path, a subclass, a loop, and instrumentation on AppKit.

---

## Concepts to first pixel

Distinct platform object/handle types touched before `first_pixel_presented` (the
[F01][f01] metric): **11**.

| #   | Handle type         | Touched by                                             |
| --- | ------------------- | ------------------------------------------------------ |
| 1   | `NSApplication`     | `sharedApplication`, `setActivationPolicy:` (Regular)  |
| 2   | `NSString`          | `setTitle:` ("wsi-scaffold")                           |
| 3   | `NSWindow`          | `initWithContentRect:styleMask:backing:defer:`         |
| 4   | `NSView` (subclass) | `GradientView` — `initWithFrame:`, `setContentView:`   |
| 5   | `SEL`               | `sel_registerName("tick:")` for the timer target       |
| 6   | `NSTimer`           | `scheduledTimerWithTimeInterval:…` (~16 ms, repeating) |
| 7   | `NSGraphicsContext` | `currentContext` inside `drawRect:`                    |
| 8   | `CGContextRef`      | the view's backing Quartz context                      |
| 9   | `CGColorSpaceRef`   | `CGColorSpaceCreateDeviceRGB`                          |
| 10  | `CGDataProviderRef` | wraps the malloc'd pixel buffer                        |
| 11  | `CGImageRef`        | `CGImageCreate` → `CGContextDrawImage`                 |

(Counting the autorelease-pool token and the `CGDirectDisplayID` returned by the
`CGMainDisplayID()` headless guard would make 13; they are bookkeeping, not part of
the draw path.)

---

## Init step sequence and timing `A[ssh]`

The `WSI_AUTO_EXIT=1` run, verbatim (timestamps are µs since `init_start`):

```text
0      APPKIT init_start auto_exit=1 hold=0
136    APPKIT step name=CGMainDisplayID
18961  APPKIT step name=NSApplication_sharedApplication
41767  APPKIT step name=setActivationPolicy policy=regular
43281  APPKIT step name=NSWindow_initWithContentRect size=480x320
79874  APPKIT window_created scale=2.0
79897  APPKIT step name=GradientView_initWithFrame
79917  APPKIT step name=setContentView
79983  APPKIT first_configure size=480x320 scale=2.0
80097  APPKIT step name=makeKeyAndOrderFront
95012  APPKIT step name=NSTimer_scheduledTimerWithTimeInterval interval_ms=16
95034  APPKIT step name=NSApp_run
```

Step deltas: `CGMainDisplayID` ≈ **18.8 ms** (the first call into CoreGraphics — it
bootstraps the WindowServer connection, so the "headless guard" is itself the first
round-trip); `sharedApplication` ≈ **22.8 ms**; `setActivationPolicy:` ≈ 1.5 ms;
`initWithContentRect:` ≈ **36.6 ms** (window device creation —
`NSBackingStoreBuffered`, `defer:false`); creating + installing the D-side view
≈ 0.2 ms; `makeKeyAndOrderFront:` ≈ **14.9 ms**. Everything is synchronous — there
is no Wayland-style configure/ack negotiation; the window exists, sized, the moment
the initializer returns ([`backingScaleFactor`][backingscalefactor] already reads
`2.0` there).

**"First configure".** AppKit has no configure event; the first geometry callback
this scaffold could find is the content view's first [`setFrameSize:`][setframesize],
which fires **synchronously inside `setContentView:`** (66 µs after the step, when
the window sizes the view to fit its content area). That is what the scaffold logs
as `first_configure`; every later `setFrameSize:` is logged as `resize`.

---

## First draw `A[ssh]`

```text
95034  APPKIT step name=NSApp_run
121183 APPKIT buffer_alloc size=960x640 bytes=2457600
123212 APPKIT first_pixel_presented t=1
123224 APPKIT frame_callback t=1
```

- `makeKeyAndOrderFront:` does **not** draw. No `drawRect:` arrives until
  `[NSApp run]` starts pumping; the first one lands ~26 ms into the loop's first
  drawing pass. A program that never runs the loop (like the original example)
  never draws.
- The buffer is allocated at **960×640 pixels** for a 480×320-**point** view —
  `backingScaleFactor` is 2.0, and the scaffold renders at backing resolution and
  lets Quartz's CTM map the points rect 1:1 onto pixels.
- `first_pixel_presented` is the **return of the first `drawRect:`** (cumulative
  **123.2 ms** from `init_start`; render + blit of the 2.4 MB buffer is ~2 ms).
  Per [F01][f01]'s caveat: this is the strongest confirmation AppKit gives a
  software renderer — CoreAnimation may still defer actual compositing to the
  end-of-cycle `CATransaction` commit, and with the screen locked nothing is
  composited at all.
- Steady state: 120 timer ticks produced **106** `frame_callback`s ≈ 15–20 ms apart
  — AppKit coalesces `setNeedsDisplay:` dirty marks into the run loop's drawing
  pass, so ticks ≠ draws.

---

## Resize storm `A[ssh]`

Six programmatic `setFrame:display:YES` changes (frame computed with
`frameRectForContentRect:`), one every 3 ticks. One cycle, verbatim:

```text
607374 APPKIT step name=setFrame_display size=640x400
608069 APPKIT resize size=640x400 scale=2.0
608623 APPKIT buffer_alloc size=1280x800 bytes=4096000
612108 APPKIT frame_callback t=28
```

The sequence is strictly **synchronous and app-paced**: `setFrame:display:YES` →
`setFrameSize:` on the content view (~0.7 ms) → buffer realloc → `drawRect:`
returning ~4 ms after the request — ahead of the next timer tick, i.e. the
`display:YES` flag forces the redraw rather than waiting for the loop's normal
pass. The window always has exactly the size the app asked for (the app picks the
size; nothing is negotiated or denied), every `resize` logs `scale=2.0`, and all
six reallocations (4 MB worst case at 1600×1040) completed with no artifacts, no
mismatches, and a clean exit:

```text
2051196 APPKIT step name=NSApp_stop tick=120
2051630 APPKIT loop_exit frames=106 ticks=120 resizes=6
```

> [!NOTE]
> A programmatic `setFrame:` does **not** enter AppKit's live-resize mode —
> `viewWillStartLiveResize`/`…End` never fire (they wrap interactive border-drags
> only, a Tier-C test per [F02][f02]). The buffer strategy here is per-resize
> `free`+`malloc`; pooling is unnecessary at these rates.

---

## The D-side `NSView` subclass: `extern (Objective-C)` worked, no fallback needed

The plan was to try a **pure-D Objective-C subclass** and fall back to the runtime
C API (`objc_allocateClassPair` + `class_addMethod`) if the compiler couldn't emit
one. The fallback was **not needed**: LDC compiles `GradientView` — a _non-extern_
`extern (Objective-C) class GradientView : NSView` — into real Objective-C class
metadata that the runtime registers at load, and AppKit happily dispatches
`drawRect:`, `setFrameSize:`, `tick:`, and `windowWillClose:` (delegate method —
selector lookup, no protocol declaration needed) to the D method bodies. Defining
Objective-C classes landed in DMD 2.085 and reached LDC in 1.40.0; the [LDC 1.40.0
release notes][ldc-1-40] state:

> Objective-C: The compiler now properly supports Objective-C classes and
> protocols, as well as swift stub classes (via the `@swift` UDA). (#4777)

The recipe (see [`app.d`][scaffold-app]), for the F-demo agents:

- **Bodied methods are the subclass implementation; bodyless `@selector` methods
  bind to the inherited implementation.** `GradientView` declares bodyless
  `static GradientView alloc()` and `GradientView initWithFrame(NSRect)` (typed
  covariantly — declared on the leaf to avoid the covariant-return clash on a base
  declaration, same idiom as the example) and bodied `drawRect:`/`setFrameSize:`/
  `tick:`/`windowWillClose:`.
- **`override` + `super` calls work.** `setFrameSize:` is declared on the extern
  `NSView` declaration and overridden with `override … { super.setFrameSize(s); … }`
  — the compiler emits the `objc_msgSendSuper` path. Forgetting the `super` call
  leaves the view permanently unsized.
- **Methods AppKit only ever calls by selector (`drawRect:`, `tick:`,
  `windowWillClose:`) need no base declaration at all** — defining a method with
  the right `@selector` is enough; Objective-C dispatch is by selector, so it
  shadows `NSView`'s implementation without D-level `override`.
- **Do not redeclare `sel_registerName` as `extern (C) void*`** — objective-d's
  `objc.rt` already declares it returning its `SEL` struct, and LDC rejects the
  duplicate with a _mangled-name/IR-type mismatch_ error. Import `objc.rt : SEL`
  and use `SEL.register("tick:")`.
- D-side state lives in `__gshared` module globals; instance variables in the
  Objective-C class were not needed for a single-window demo (and not exercised
  here).

---

## WindowServer sidecar evidence `A[ssh]`

While a `WSI_HOLD=1` run (no storm, ~10 s) held the window open, a Swift sidecar on
the same machine queried [`CGWindowListCopyWindowInfo`][cgwindowlist] with
`.optionAll`. Verbatim hit:

```text
["kCGWindowSharingState": 0, "kCGWindowOwnerName": scaffold, "kCGWindowOwnerPID": 90674,
 "kCGWindowLayer": 0, "kCGWindowStoreType": 1, "kCGWindowAlpha": 1,
 "kCGWindowBounds": { Height = 315; Width = 433; X = 194; Y = 639; },
 "kCGWindowMemoryUsage": 2368, "kCGWindowNumber": 27963]
```

- `kCGWindowOwnerName = scaffold` with the matching PID and a real
  `kCGWindowNumber` **proves WindowServer registration** from an SSH-launched,
  non-bundled binary.
- The `kCGWindowIsOnscreen` key is **absent** (the sidecar had to use `.optionAll`,
  not `.optionOnScreenOnly`): the window is registered but **not composited**
  because the console session is locked. This is the expected `A[ssh]` shape —
  on-screen verification of actual pixels is Tier C (logged-in console).
- `kCGWindowBounds` is in the **top-left-origin global display space** (unlike
  AppKit's y-up screen coordinates) and reads 433×315 at (194, 639) — a uniform
  ~0.9 down-scale of the requested 480×348 frame (480×320 content + 28 pt
  titlebar). The window _application-side_ geometry is exactly as requested
  (`first_configure size=480x320 scale=2.0`); the WindowServer-side bounds appear
  re-mapped to the lock-screen display configuration, so treat sidecar bounds as
  registration evidence only, not geometry ground truth, while the screen is
  locked.

---

## Surprises

1. **The headless guard is the first round-trip.** `CGMainDisplayID()` took
   ~18.8 ms — it bootstraps the WindowServer connection before
   `sharedApplication` even runs. "Check then connect" is really "connect twice".
2. **`first_configure` is synchronous inside `setContentView:`** (66 µs later) —
   AppKit sizes the content view via `setFrameSize:` while the setter is still on
   the stack. There is no asynchronous configure phase anywhere on this platform.
3. **`makeKeyAndOrderFront:` paints nothing.** The first `drawRect:` only arrives
   ~26 ms into `[NSApp run]` — ordering a window front and getting pixels into it
   are separated by the run loop's first drawing pass.
4. **120 ticks → 106 draws**: `setNeedsDisplay:` dirty marks are coalesced per
   run-loop pass, so an `NSTimer` is a refresh _requester_, not a frame clock
   (the real frame clock is `CADisplayLink`, out of scope for the scaffold).
5. **`stop:` without an event post hangs.** `-[NSApplication stop:]` only sets a
   flag that the loop checks _after dispatching an event_; the scaffold must post
   a synthetic `NSEventTypeApplicationDefined` event to unblock `nextEventMatchingMask:`.
6. **The locked-screen WindowServer rescales registered windows** (~0.9× here) —
   sidecar bounds disagree with app-side geometry while no one is logged in.
7. **The D/Objective-C toolchain surprise was pleasant**: a real Objective-C
   subclass, `override`, and `super` calls all worked first try on LDC 1.41 —
   the only friction was the `sel_registerName` redeclaration clash with
   objective-d's typed `SEL`.

---

## Sources

- **This scaffold** — [`./examples/scaffold/app.d`][scaffold-app],
  [`./examples/scaffold/instrument.d`][instrument]; the predecessor
  [`./example/app.d`][example]; the [AppKit survey][survey].
- **Feature specs** — [F01 first pixel][f01], [F02 resize][f02].
- **Apple Developer documentation** (Wayback-pinned, bot-hostile host):
  [`NSApplication`][nsapplication], [`NSWindow`][nswindow], [`NSView`][nsview],
  [`drawRect:`][drawrect], [`setFrameSize:`][setframesize],
  [`backingScaleFactor`][backingscalefactor], [`stop:`][nsapp-stop],
  [`NSTimer`][nstimer], [`CGImage`][cgimage],
  [`CGWindowListCopyWindowInfo`][cgwindowlist].
- **D ↔ Objective-C** — the D specification's [_Interfacing to
  Objective-C_][dlang-objc], the [DMD 2.085.0 changelog][dmd-2-085] (defining
  Objective-C classes), the [LDC 1.40.0 release notes][ldc-1-40] (quoted above),
  and the [`objective-d`][objd] package (`objc.autorelease`, `objc.rt`).

<!-- References -->

<!-- This tree -->

[survey]: ./index.md
[example]: ./example/app.d
[scaffold-app]: ./examples/scaffold/app.d
[instrument]: ./examples/scaffold/instrument.d
[f01]: ../features/f01-first-pixel.md
[f02]: ../features/f02-resize.md

<!-- D / objective-d primary sources -->

[dlang-objc]: https://dlang.org/spec/objc_interface.html
[dmd-2-085]: https://dlang.org/changelog/2.085.0.html
[ldc-1-40]: https://github.com/ldc-developers/ldc/releases/tag/v1.40.0
[objd]: https://github.com/KitsunebiGames/objective-d

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
[cgwindowlist]: https://web.archive.org/web/20250429071735/https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)
