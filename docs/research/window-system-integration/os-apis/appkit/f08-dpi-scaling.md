# AppKit F08 — DPI / `backingScaleFactor`

AppKit's unit story is points everywhere, pixels nowhere — the scale factor lives in
the **backing store**, and per the [F08 feature spec][f08] this demo enumerates every
place it can be read ([`NSScreen`][nsscreen-screens], [`NSWindow`][backingscalefactor-win],
[`convertRectToBacking:`][convertrecttobacking], `CALayer`
[`contentsScale`][contentsscale]), pins the created-at-what-scale timeline with µs
timestamps, reads the `drawRect:` CGContext [CTM][cgcontext-ctm] as the ground truth of
what AppKit pre-scales, runs a deliberate wrong-scale buffer probe, and registers the
two runtime-rescale notifications a monitor drag would fire (Tier C). The program is
[`./examples/f08-dpi-scaling/app.d`][demo-app] (with the shared
[`instrument.d`][instrument] logger), built on the [scaffold][scaffold] recipe; the
buffer math extends the `pixels == points × scale` invariant [F02][f02-doc] asserted.

**Last reviewed:** June 11, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn` (aarch64-darwin,
macOS 26.3.1, LDC 1.41.0, single built-in Retina display at scale **2.0**) over SSH
with the console session **locked**. The lock distorts one load-bearing thing:
**rasterization**. Every geometry API (scale factors, conversions, notifications,
resize math) is unaffected — but the `drawRect:` context of a window that is never
actually composited came back with an **identity CTM** (the
[CTM finding](#the-drawrect-ctm-the-ground-truth-dissents-a-ssh) below), so the
canonical "AppKit pre-scales the context ×2" claim could **not** be confirmed headless
and is queued for Tier C together with the [monitor drag](#tier-c-script-monitor-drag).

| Measurement                              | Value                                                                                      |
| ---------------------------------------- | ------------------------------------------------------------------------------------------ |
| Scale sources (screen/window/view/layer) | **all agree: 2.0** (one screen, `Built-in Retina Display`, 1728×1117 pt)                   |
| Scale first learnable                    | at `initWithContentRect:` **return**; even a window-less view already converts at 2.0      |
| `viewDidChangeBackingProperties`         | **exactly once**, synchronously inside `setContentView:`; never again headless             |
| `NSWindowDidChangeBackingProperties…`    | registered, **never fired** — the window's scale never actually changed                    |
| `convertRectToBacking:` round-trips      | exact at ×2 for 480×320, 333×217, **100.5×50.25**, 1×1 (`exact=1` all four)                |
| Resize invariant                         | `pixels == points × scale` held on every resize incl. odd 333×217 → 666×434 (`match=1`)    |
| `drawRect:` CGContext CTM                | **identity** (`a=1 d=1`, no flip) while every geometry API says 2.0 — locked-session run   |
| Mismatch probe (points-sized buffer)     | app-observable as `CGImageGetWidth ≠ rect × CTM`; resample factor = `ctm_scale` (1.0 here) |
| Off-screen `setFrameOrigin:(5000,100)`   | **clamped** to `(1688,100)` — AppKit keeps the window on the only screen; no backing event |
| Exit                                     | clean `0` (`loop_exit frames=76 ticks=85 backing_changes=1 mismatches=0`)                  |

---

## Where the scale lives — five sources, one answer `A[ssh]`

The demo reads every documented home of the scale factor:

```text
43092 APPKIT_F08 screen idx=0 scale=2.0 frame=(0,0 1728x1117) name="Built-in Retina Display"
43111 APPKIT_F08 screen idx=main scale=2.0
75892 APPKIT_F08 timeline t=window_init_return window_scale=2.0 screen_scale=2.0
86788 APPKIT_F08 round_trip window_converts_100pt_to=200px
86854 APPKIT_F08 layer_probe stage=wants_layer layer=non-nil contents_scale=2.0
```

| Source                                                                                                | Granularity | Value |
| ----------------------------------------------------------------------------------------------------- | ----------- | ----- |
| [`NSScreen.screens`][nsscreen-screens] `backingScaleFactor` ([per screen][backingscalefactor-screen]) | per display | 2.0   |
| [`-[NSWindow backingScaleFactor]`][backingscalefactor-win]                                            | per window  | 2.0   |
| `-[NSView convertRectToBacking:]`                                                                     | per view    | 2.0   |
| `-[NSWindow convertRectToBacking:]`                                                                   | per window  | 2.0   |
| `CALayer` [`contentsScale`][contentsscale] (wantsLayer probe)                                         | per layer   | 2.0   |

Notes from the probes: screen frames are in **points** (1728×1117 is the 2× logical
size of the 3456×2234 panel); the per-window value is the one to use for buffer sizing
(it follows the window across screens — the screen value is only a startup hint); and a
plain programmatic `NSView` is **not layer-backed by default** even on macOS 26
(`layer_probe stage=before layer=nil`) — but the moment [`wantsLayer`][wantslayer] is
set, AppKit hands the backing layer the correct `contentsScale=2.0` with no work from
the app (the layer is destroyed again on revert, `stage=after_revert layer=nil`).

---

## The created-at-what-scale timeline `A[ssh]`

The "created at the wrong scale, then rescaled" problem the [spec][f08] asks about —
timestamps are the µs column:

```text
43118 APPKIT_F08 timeline t=window_init_call size=480x320
75892 APPKIT_F08 timeline t=window_init_return window_scale=2.0 screen_scale=2.0
76999 APPKIT_F08 timeline t=view_pre_install view_converts_100pt_to=200px window=nil
77024 APPKIT_F08 timeline t=setContentView_call
77089 APPKIT_F08 first_configure points=480x320 pixels=960x640 window=nil
77128 APPKIT_F08 backing_changed n=1 window_scale=2.0 view_converts_100pt_to=200px phase=setup
77213 APPKIT_F08 timeline t=setContentView_return backing_changes=1
86743 APPKIT_F08 timeline t=after_order_front backing_changes=1
```

- **The window is born knowing its scale**: `backingScaleFactor` reads 2.0 the moment
  `initWithContentRect:` returns (33 ms in, long before `makeKeyAndOrderFront:`),
  agreeing with its assigned screen. There is no 1.0-scale embryo window observable
  from the API.
- **Even the window-less view converts at 2.0.** `convertRectToBacking:` on the
  freshly-`initWithFrame:`-ed view (window still `nil`) answers 100 pt → 200 px. This
  _refines_ the [F02][f02-doc] note that "a windowless view defaults to scale 1.0":
  that was an inference from the install-time callback, and the conversion API does
  not corroborate it — window-less, the view already falls back to a 2.0 conversion
  on this single-Retina machine. The real created-at-1.0-then-migrated timeline needs
  a mixed-scale setup (Tier C).
- **[`viewDidChangeBackingProperties`][viewdidchangebackingproperties] fires exactly
  once, synchronously inside `setContentView:`** (call 77024 → fire 77128 → return 77213) — it is the "(re)learn your environment" signal on window installation.
  Ordering nuance: the view's first `setFrameSize:` (77089) also runs inside
  `setContentView:` and **before** the view's `window` link exists (`window=nil`) —
  a renderer keying buffer allocation off the first resize cannot ask the window for
  the scale at that moment; `convertRectToBacking:` (which already answers 960×640)
  is the reliable source.
- **Nothing else fires it headless.** Through `makeKeyAndOrderFront:`, a three-step
  resize storm, the off-screen move and back, `backing_changes` stays at **1**
  (`loop_exit … backing_changes=1`). And the window-level
  [`NSWindowDidChangeBackingPropertiesNotification`][windowbackingnotif] (whose
  `userInfo` carries the **old** scale under `NSBackingPropertyOldScaleFactorKey`)
  never fired at all — consistent: the _window's_ scale never changed; only the view
  got installed. Per-view callback = environment changes; per-window notification =
  actual scale flips.

---

## The `drawRect:` CTM: the ground truth dissents `A[ssh]`

The CTM of the context AppKit hands `drawRect:` is **the** authoritative statement of
what it pre-scales for a software renderer — and in this run it dissents from every
geometry API:

```text
111936 APPKIT_F08 ctm when=drawRect a=1.00 b=0.00 c=0.00 d=1.00 tx=0.00 ty=0.00
111954 APPKIT_F08 ctm_vs_backing ctm_a=1.0 backing_scale=2.0 note=context_scale_disagrees_with_geometry_scale
114003 APPKIT_F08 hairline thickness_pt=0.50 device_px=0.5
```

On a composited Retina window the expected CTM is `a=2 d=-2 ty=2×height` — the ×2
pre-scale that makes points-rect drawing land on device pixels (the contract the
[High Resolution Guidelines][highres] describe and that [F02][f02-doc]/the
[scaffold][scaffold] _assumed_ when blitting a 2×-sized image into the points-sized
bounds), plus the flip for a non-flipped view. What arrived is a bare **identity** —
not even the y-flip is present. Combined with the scaffold's earlier sidecar finding
that the locked-session WindowServer treats these windows specially, the reading is
that a never-composited window does not get a real backing surface, and the context
handed out headless is synthetic. Two practical findings survive the artifact:

- **Never assume `CTM == backingScaleFactor`.** They are reported by different
  subsystems and demonstrably disagree; a renderer that derives device-pixel geometry
  must read `CGContextGetCTM` per frame (the demo's `hairline` line computes
  `0.5 pt × ctm.a` — 1 device px on a real 2× context, 0.5 here).
- The canonical ×2-CTM claim is **unverified headless** — re-checking the `ctm
when=drawRect` line in an unlocked session is step 0 of the
  [Tier-C script](#tier-c-script-monitor-drag).

---

## The deliberate scale mismatch: a 1.0 buffer into the 2.0 view `A[ssh]`

Every normal frame allocates `points × scale` pixels (per
`convertRectToBacking:`) and lets the context map the points-sized `bounds` onto them.
At tick 50 the demo deliberately allocates a **points-sized** (1.0-scale) buffer and
draws it into the same rect — the classic wrong-scale bug:

```text
921340 APPKIT_F08 step name=mismatch_probe note=next_frame_draws_points_sized_buffer
925200 APPKIT_F08 buffer_alloc size=480x320 bytes=614400
926982 APPKIT_F08 mismatch_probe img_px=480x320 rect_pt=480x320 ctm_scale=1.0 device_px=480x320 note=resampled_x1.0_blurry
940906 APPKIT_F08 buffer_alloc size=960x640 bytes=2457600
```

`CGContextDrawImage` raises no error and clips nothing — the API contract is that the
image is **stretched to the rect**, whatever the pixel density. The app-observable
evidence of the bug is therefore pure arithmetic, and the probe logs exactly that:
`CGImageGetWidth` (480) vs `rect × CTM` device pixels. On a real 2× context the device
size is 960×640, so Quartz resamples the 480-px image ×2 — on screen: the blurry
stretch. In this locked-session run the synthetic identity CTM makes the resample
factor 1.0 (no visual consequence to capture headless), which is itself instructive:
**the mismatch is invisible to every API** — nothing warns; only comparing the buffer
size against `rect × CTM` (or your eyes) catches it. The next frame reallocates at
backing size (`960x640`), and the run still exits `mismatches=0` because the probe is
excluded from the invariant check.

---

## Conversion round-trips and the resize invariant `A[ssh]`

[`convertRectToBacking:`][convertrecttobacking] / `convertRectFromBacking:` at scale
2.0 are exact multiplication — lossless both ways, including odd and fractional point
sizes:

```text
86760 APPKIT_F08 round_trip points=480.00x320.00 -> pixels=960.00x640.00 -> points=480.00x320.00 exact=1
86769 APPKIT_F08 round_trip points=333.00x217.00 -> pixels=666.00x434.00 -> points=333.00x217.00 exact=1
86775 APPKIT_F08 round_trip points=100.50x50.25 -> pixels=201.00x100.50 -> points=100.50x50.25 exact=1
86782 APPKIT_F08 round_trip points=1.00x1.00 -> pixels=2.00x2.00 -> points=1.00x1.00 exact=1
```

Fractional **points** are legal and produce fractional-but-exact pixel rects
(100.5 pt → 201 px, 50.25 pt → 100.5 px — note a half-pixel is representable in the
rect, it is the renderer's problem to land on whole device pixels). Because macOS
scales are integral per backing store (fractional "looks like" modes are realized as
integral-scale buffers downsampled by the WindowServer), there is none of Wayland's
fractional-scale rounding: no `exact=0` case exists at ×2. The [F02][f02-doc]
invariant re-held through the resize storm, including the odd size:

```text
440259 APPKIT_F08 resize points=640x400 pixels=1280x800 scale=2.0 match=1
571891 APPKIT_F08 resize points=333x217 pixels=666x434 scale=2.0 match=1
699353 APPKIT_F08 resize points=480x320 pixels=960x640 scale=2.0 match=1
```

with `buffer_alloc` reallocating to the new pixel size after each (the demo's
gradient is regenerated at backing resolution every frame; 1-physical-px hairlines
are drawn as `1/scale`-point rects at the window edges — crisp on a real 2× context,
and the visual check for the Tier-C drag).

---

## Runtime rescale: registration provable, firing is Tier C `A[ssh]`

A live scale change (monitor drag, display-settings flip, plug/unplug) is exactly what
a locked single-screen session cannot produce. The demo pins everything short of it:

- Both observers are registered **before** `setContentView:`:
  [`NSApplicationDidChangeScreenParametersNotification`][screenparamsnotif]
  (app-level: display configuration changed — re-enumerate screens) and
  [`NSWindowDidChangeBackingPropertiesNotification`][windowbackingnotif]
  (window-level: scale/color-space flipped; old scale in `userInfo`).
- The wiring is proven by a hand-posted self-test — the handler runs and re-enumerates
  (unchanged) screens:

```text
1372494 APPKIT_F08 step name=post_didChangeScreenParameters note=selftest
1372517 APPKIT_F08 screen_params_changed phase=observer_selftest
1372526 APPKIT_F08 screens when=notification count=1
```

- A second screen cannot even be faked geometrically: `setFrameOrigin:(5000,100)` is
  **clamped** — AppKit constrains the frame to the only screen and no screen/backing
  event fires:

```text
1081021 APPKIT_F08 step name=setFrameOrigin origin=(5000,100) note=no_second_screen
1081235 APPKIT_F08 offscreen_result frame=(1688,100 480x348) screen=non-nil scale=2.0 backing_changes=1
```

(1688 = 1728 − 40 pt of window width kept on-screen by the constraint logic;
the 348 pt height is content + 28 pt title bar.) So there is no headless
approximation of the scale migration — hence the script below.

---

## Tier C script: monitor drag

Run on `mac-bsn` in an **unlocked** GUI session with an external **1×** (non-Retina)
display attached — or any display whose scale differs from the built-in 2× panel
(results → this doc):

1. Build per the [scaffold][scaffold] (`nix develop … ldc2 …`; binary staged at
   `/tmp/wsi-m4/f08-dpi-scaling/demo`), run `./demo` with **no** env vars (interactive
   mode keeps the window up).
2. First, before touching anything: read the `ctm when=drawRect` line — expect
   `a=2.00 d=-2.00` (scale + flip) on the Retina screen, falsifying-or-confirming the
   identity-CTM-is-a-lock-artifact reading above.
3. Drag the window from the built-in display to the 1× display, slowly, watching
   stderr. Expect, in order: `screen_params_changed` only if the arrangement changes;
   then at some crossing point (record **where** — majority-area? title-bar?) a
   `window_backing_changed old_scale=2.0 new_scale=1.0` +
   `backing_changed n=2 window_scale=1.0` pair, a `ctm` re-log (the demo logs the CTM
   only when it changes) at `a=1.00`, and `buffer_alloc` dropping to the points size.
4. Drag back; expect the mirror sequence (`old_scale=1.0 new_scale=2.0`, `n=3`,
   `buffer_alloc` ×4 larger) and the edge hairlines staying 1 physical px crisp on
   both screens — any blur or double-thick line means a missed reallocation.
5. While there: System Settings → Displays → change the built-in panel's "looks like"
   resolution and log whether that alone fires the backing notification (scale stays
   2.0, points size changes) vs the screen-params notification.

---

## Findings summary (for `event-sequences.md`)

- **Points everywhere; the scale lives per backing store** and reads 2.0 identically
  from screen, window, view conversion, and (on demand) layer `contentsScale`. Buffer
  sizing must use the **window/view** value, not the screen's.
- **No created-at-wrong-scale window observed**: scale correct at
  `initWithContentRect:` return; a window-less view already converts at 2.0;
  `viewDidChangeBackingProperties` fires **once, synchronously inside
  `setContentView:`** (install ≠ scale change: the window-level notification stays
  silent), and never again without a real display change. The view's first
  `setFrameSize:` precedes its `window` link — use `convertRectToBacking:` there.
- **The context CTM is the rasterization ground truth and can disagree with the
  geometry APIs**: identity CTM (no scale, no flip) against `backingScaleFactor` 2.0
  under the locked session. Read it per frame; never derive it.
- **A wrong-scale buffer fails silently**: `CGContextDrawImage` stretches to the rect
  with no error — detectable only as `image px ≠ rect × CTM` (and as blur on screen).
- **Conversions are exact** at integral scales (fractional points round-trip
  losslessly; `pixels == points × scale` held on every resize incl. 333×217), and
  macOS never hands the client a fractional scale.
- **Runtime rescale is two notifications** — app-level screen-params + window-level
  backing-change (old scale in `userInfo`) — registration and handler wiring proven
  headless; an actual firing needs the Tier-C drag. Windows cannot be positioned onto
  a non-existent screen to fake it (`setFrameOrigin:` clamps).

---

## Sources

- **This demo** — [`./examples/f08-dpi-scaling/app.d`][demo-app],
  [`./examples/f08-dpi-scaling/instrument.d`][instrument]; the
  [AppKit scaffold findings][scaffold] (recipe, locked-session WindowServer sidecar),
  the [F02 resize findings][f02-doc] (the buffer-math invariant this extends), and the
  [AppKit survey][survey].
- **Feature specs** — [F08 DPI / runtime rescale][f08]; the Tier-C entry in the
  [manual-run-queue][queue].
- **Apple Developer documentation** (Wayback-pinned where a verified snapshot exists;
  this host is bot-hostile): [`NSScreen.screens`][nsscreen-screens],
  [`NSScreen.backingScaleFactor`][backingscalefactor-screen],
  [`NSWindow.backingScaleFactor`][backingscalefactor-win],
  [`convertRectToBacking:`][convertrecttobacking],
  [`viewDidChangeBackingProperties`][viewdidchangebackingproperties],
  [`NSWindowDidChangeBackingPropertiesNotification`][windowbackingnotif],
  [`NSApplicationDidChangeScreenParametersNotification`][screenparamsnotif],
  [`wantsLayer`][wantslayer], [`contentsScale`][contentsscale],
  [`CGContext.ctm`][cgcontext-ctm], and the archived
  [High Resolution Guidelines for OS X][highres].

<!-- References -->

<!-- This tree -->

[survey]: ./index.md
[scaffold]: ./scaffold.md
[demo-app]: ./examples/f08-dpi-scaling/app.d
[instrument]: ./examples/f08-dpi-scaling/instrument.d
[f02-doc]: ./f02-resize.md
[f08]: ../features/f08-dpi-scaling.md
[queue]: ../manual-run-queue.md

<!-- Apple developer docs (Wayback-pinned where a verified snapshot exists) -->

[nsscreen-screens]: https://developer.apple.com/documentation/appkit/nsscreen/screens
[backingscalefactor-screen]: https://web.archive.org/web/20251101185149/https://developer.apple.com/documentation/appkit/nsscreen/backingscalefactor
[backingscalefactor-win]: https://web.archive.org/web/20251102044301/https://developer.apple.com/documentation/appkit/nswindow/backingscalefactor
[convertrecttobacking]: https://web.archive.org/web/20200823150514/https://developer.apple.com/documentation/appkit/nsview/1483648-convertrecttobacking
[viewdidchangebackingproperties]: https://web.archive.org/web/20250609073527/https://developer.apple.com/documentation/appkit/nsview/viewdidchangebackingproperties()
[windowbackingnotif]: https://developer.apple.com/documentation/appkit/nswindow/didchangebackingpropertiesnotification
[screenparamsnotif]: https://web.archive.org/web/20260308081550/https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification
[wantslayer]: https://developer.apple.com/documentation/appkit/nsview/wantslayer
[contentsscale]: https://web.archive.org/web/20251016195055/https://developer.apple.com/documentation/quartzcore/calayer/contentsscale
[cgcontext-ctm]: https://developer.apple.com/documentation/coregraphics/cgcontext/ctm
[highres]: https://web.archive.org/web/20260609034428/https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Explained/Explained.html
