# AppKit F02 — resize correctness

How macOS notifies an app of a new window size, and what correct Retina buffer math
looks like, per the [F02 feature spec][f02]: a continuously refreshed, corner-anchored
gradient survives a **three-phase programmatic resize storm** —
[`setFrame:display:`][setframe], [`setContentSize:`][setcontentsize], and
[`zoom:`][zoom] (a maximize-like state transition) — with every geometry event logged
in **both points and pixels** and the invariant `pixels == points × scale` asserted on
each one. The program is [`./examples/f02-resize/app.d`][demo-app] (with the shared
[`instrument.d`][instrument] logger), built on the [scaffold][scaffold] recipe.

**Last reviewed:** June 10, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn` (aarch64-darwin,
macOS 26.3.1, LDC 1.41.0, Retina display at `backingScaleFactor` **2.0**) over SSH with
the console session **locked** (windows register with the WindowServer but are not
composited — the scaffold's [sidecar evidence][sidecar]).

| Measurement                        | Value                                                                                |
| ---------------------------------- | ------------------------------------------------------------------------------------ |
| Resizes survived                   | **13** (8 × `setFrame:display:` incl. odd sizes, 3 × `setContentSize:`, 2 × `zoom:`) |
| Point/pixel assertion              | `pixels == points × scale` held on **all 13 + first configure** (`mismatches=0`)     |
| Buffer (re)allocations             | **14** (initial + one per pixel-size change; per-resize `free`+`malloc`, no pooling) |
| `live_resize_start` / `end` events | **0** — programmatic resize never enters live-resize (incl. `zoom:`)                 |
| Who picks the size                 | **The app.** Every request honoured exactly and synchronously; nothing negotiated    |
| Resize → redraw latency            | ~0.6 ms to `setFrameSize:`; ~6 ms to `drawRect:` return (`display:YES`)              |
| Exit                               | clean `0` (`loop_exit frames=115 ticks=135 resizes=13 buffers=14 mismatches=0`)      |

---

## What the demo does

The scaffold's window + D-defined `GradientView` subclass, with the resize machinery
fully instrumented:

- the overridden [`setFrameSize:`][setframesize] logs every geometry change as
  `resize points=WxH pixels=WxH scale=S match=1|0`, where the pixel size comes from
  [`convertRectToBacking:`][convertrecttobacking] and `match` asserts it equals the
  naive `points × scale`;
- bodied `@selector` methods for [`viewWillStartLiveResize`][viewwillstartliveresize]/
  `viewDidEndLiveResize` and
  [`viewDidChangeBackingProperties`][viewdidchangebackingproperties] prove by
  _absence_ which callbacks programmatic resizes do **not** trigger;
- the view doubles as `NSWindowDelegate`, logging `windowDidResize:` (with the frame
  size and [`isZoomed`][iszoomed]) to pin the delegate-vs-view callback order;
- a ~16 ms `NSTimer` drives `setNeedsDisplay:` (continuous refresh) and the storm
  schedule; `drawRect:` reallocates the CPU buffer whenever the **pixel** size changed
  and logs `frame_callback … points=WxH pixels=WxH`.

Phase schedule (`WSI_AUTO_EXIT=1`): ticks 30–51 — eight `setFrame:display:YES` content
sizes (`640x400`, `320x240`, `800x520`, **`333x217`**, `1024x640`, **`415x289`**,
`560x352`, `480x320`; the odd sizes exercise point→pixel rounding); ticks 60–66 — three
`setContentSize:` calls; tick 75 — `zoom:` (maximize); tick 95 — `zoom:` again
(restore); tick 135 — `[NSApp stop:]`. Without the env var there is no storm — the
window waits for a human border-drag (the Tier-C interactive path, see
[below](#live-resize-never-entered--the-interactive-path-is-tier-c)).

---

## Annotated sequences `A[ssh]`

### `setFrame:display:YES` — grow (480×320 → 640×400)

```text
604561 APPKIT_F02 step name=setFrame_display size=640x400        <- app requests a 640x400 content rect
605239 APPKIT_F02 resize points=640x400 pixels=1280x800 scale=2.0 match=1
                                                                 <- setFrameSize: on the content view, +0.7 ms
605303 APPKIT_F02 window_did_resize frame=640x428 zoomed=0       <- delegate, +64 µs (frame = content + 28 pt titlebar)
607384 APPKIT_F02 buffer_alloc size=1280x800 bytes=4096000 n=2   <- per-resize realloc inside drawRect:
610850 APPKIT_F02 frame_callback t=29 points=640x400 pixels=1280x800
                                                                 <- drawRect: return, +6.3 ms — forced by display:YES
```

### `setFrame:display:YES` — shrink (640×400 → 320×240)

```text
652797 APPKIT_F02 step name=setFrame_display size=320x240
653430 APPKIT_F02 resize points=320x240 pixels=640x480 scale=2.0 match=1
653477 APPKIT_F02 window_did_resize frame=320x268 zoomed=0
657516 APPKIT_F02 buffer_alloc size=640x480 bytes=1228800 n=3
658677 APPKIT_F02 frame_callback t=32 points=320x240 pixels=640x480
```

Grow and shrink are symmetric: **callback order is always
`setFrameSize:` → `windowDidResize:` → `drawRect:`**, strictly synchronous and
app-paced. The `display:YES` flag forces the redraw ahead of the run loop's normal
drawing pass (~6 ms after the request, well inside the 16 ms tick cadence). The window
always has exactly the requested size — nothing is negotiated, denied, or resized
behind the app's back, the opposite of Wayland's configure/ack/commit.

### `setContentSize:` (480×320 → 600×380)

```text
1082286 APPKIT_F02 step name=setContentSize size=600x380
1082666 APPKIT_F02 resize points=600x380 pixels=1200x760 scale=2.0 match=1   <- +0.4 ms, same path
1082709 APPKIT_F02 window_did_resize frame=600x408 zoomed=0
1090766 APPKIT_F02 buffer_alloc size=1200x760 bytes=3648000 n=10
1093920 APPKIT_F02 frame_callback t=54 points=600x380 pixels=1200x760        <- +11.6 ms
```

`setContentSize:` resizes through the **same** `setFrameSize:` → `windowDidResize:`
pipeline — the only observable difference is that it has **no display flag**, so the
redraw is not forced: the dirty mark waits for the run loop's next drawing pass
(~11.6 ms here vs ~6 ms with `display:YES`). The content rect is specified directly
(no [`frameRectForContentRect:`][nswindow] arithmetic needed), and in AppKit's y-up
coordinates the top-left is kept — the _bottom_ edge moves.

### `zoom:` — the maximize-like transition, and its restore

```text
1324551 APPKIT_F02 step name=zoom pre_zoomed=0
1324972 APPKIT_F02 resize points=1728x1056 pixels=3456x2112 scale=2.0 match=1
1325022 APPKIT_F02 window_did_resize frame=1728x1084 zoomed=1
1325046 APPKIT_F02 step name=zoom_returned zoomed=1              <- whole transition inside zoom:, 0.5 ms
1325381 APPKIT_F02 buffer_alloc size=3456x2112 bytes=29196288 n=13
1349416 APPKIT_F02 frame_callback t=68 points=1728x1056 pixels=3456x2112
                                                                 <- 24 ms render+blit of the 29 MB buffer
```

```text
2232322 APPKIT_F02 step name=zoom pre_zoomed=1
2232729 APPKIT_F02 resize points=480x320 pixels=960x640 scale=2.0 match=1
2232765 APPKIT_F02 window_did_resize frame=480x348 zoomed=0      <- exactly the saved user frame
2232789 APPKIT_F02 step name=zoom_returned zoomed=0
2243670 APPKIT_F02 buffer_alloc size=960x640 bytes=2457600 n=14
2245828 APPKIT_F02 frame_callback t=79 points=480x320 pixels=960x640
```

- **`zoom:` is a single synchronous frame change**, not a state machine: exactly one
  `setFrameSize:` + one `windowDidResize:` (already reporting `zoomed=1`) fire _inside_
  the call, which returns in 0.5 ms. No intermediate animation frames were observed
  app-side in this `A[ssh]` session, and no live-resize bracket fires.
- The zoomed frame is the screen's **visible frame**, not the full screen: 1728×1084
  points (the 1728×1117-point Retina panel minus the 33-point menu bar), giving a
  1728×1056-point content area — `zoom:` is "maximize", not "fullscreen"
  (`toggleFullScreen:` is a different, spaces-based path, out of scope per the
  [F14 window-state spec][f14]).
- The second `zoom:` restores **exactly** the saved user frame (`480x348`) — AppKit
  remembers the pre-zoom geometry; the app does not have to.
- At the zoomed size the CPU renderer becomes the bottleneck: the 3456×2112 buffer is
  29 MB and render+blit takes ~24 ms, stretching the frame cadence from ~16 ms to
  ~82 ms. Resize correctness is unaffected — a measured cost of software rendering at
  Retina resolution, and more motivation for the [F04 frame-pacing demo][f04].

---

## Points vs pixels — the Retina buffer math

The mac runs at `backingScaleFactor` **2.0**, so every logical (point) size maps to a
physical (pixel) buffer of exactly twice the extent. The demo logs both per resize and
asserts `pixels == points × scale` against [`convertRectToBacking:`][convertrecttobacking]
— **all 14 geometry events matched** (`mismatches=0`), including the deliberately odd
point sizes:

| Phase           | Points        | Pixels (buffer) | Bytes (XRGB32) |
| --------------- | ------------- | --------------- | -------------: |
| initial         | `480 × 320`   | `960 × 640`     |      2 457 600 |
| `setFrame:`     | `333 × 217`   | `666 × 434`     |      1 156 176 |
| `setFrame:`     | `415 × 289`   | `830 × 578`     |      1 918 960 |
| `setFrame:` max | `1024 × 640`  | `2048 × 1280`   |     10 485 760 |
| `zoom:`         | `1728 × 1056` | `3456 × 2112`   |     29 196 288 |

Because the scale is integral (1.0 or 2.0 — never fractional client-side on macOS),
odd point sizes still produce exact even pixel sizes; there is no rounding hazard of
the kind Wayland's fractional scaling introduces. The gradient is rendered at backing
resolution and blitted into the **points**-sized bounds rect — Quartz's CTM maps the
two 1:1, so the image is never stretched (the [scaffold][scaffold]'s draw path,
unchanged).

**Buffer strategy (an [F02][f02] deliverable):** per-resize `free`+`malloc`, keyed on
the _pixel_ size, reallocating only when it actually changed — 14 allocations for 13
resizes + the first frame, worst case 29 MB. At programmatic-storm rates (a resize
every ~50 ms) allocation cost is invisible next to the render; pooling would only pay
off under interactive live-resize, where `setFrameSize:` can arrive every frame.

> [!NOTE]
> **`viewDidChangeBackingProperties` fired exactly once — at setup, not during the
> storm.** The verbatim start of the run:
>
> ```text
> 72994 APPKIT_F02 first_configure points=480x320 pixels=960x640 scale=2.0 match=1
> 73042 APPKIT_F02 backing_changed scale=2.0
> ```
>
> A windowless view defaults to scale 1.0; installing it into the Retina window via
> `setContentView:` changes its backing properties to 2.0, and AppKit delivers the
> callback synchronously right after the first `setFrameSize:`. During the 13-resize
> storm it never fired again — it signals **scale** changes (e.g. dragging to a 1×
> display), not size changes.

---

## Live-resize: never entered — the interactive path is Tier C

The demo defines bodied [`viewWillStartLiveResize`][viewwillstartliveresize] /
`viewDidEndLiveResize` overrides that log `live_resize_start` / `live_resize_end`.
**Neither appeared anywhere in the run** — not for `setFrame:display:`, not for
`setContentSize:`, and notably not for `zoom:` either. This confirms and extends the
scaffold's finding: AppKit's live-resize mode brackets **interactive border-drags
only**; every programmatic path bypasses it. A real drag also throttles `drawRect:`
to the drag's event cadence and is exactly where a buffer pool would matter — that
sequence cannot be captured over SSH and is queued as a manual Tier-C run in the
[manual-run queue][queue] (run `./demo` with no env vars in an unlocked GUI session
and drag the border).

## Findings summary (for `event-sequences.md`)

- **Sequence per programmatic resize:** request (`setFrame:display:` /
  `setContentSize:` / `zoom:`) → `setFrameSize:` on the content view (+0.4–0.7 ms) →
  `windowDidResize:` delegate (+~60 µs) → `drawRect:` (forced at +~6 ms by
  `display:YES`; otherwise on the next run-loop drawing pass, +~12 ms). All
  synchronous, all on the main thread.
- **Who picks the size:** the app, unconditionally — every one of the 13 requests was
  honoured bit-exact, `zoom:` follows AppKit's own visible-frame computation, and the
  un-zoom restores AppKit's saved user frame. No deny/negotiate path exists at this
  API level.
- **Scale handling:** `backingScaleFactor` constant at 2.0 throughout;
  `pixels == points × scale` held on every event; `viewDidChangeBackingProperties` is
  the scale-migration signal and fired only at view installation.
- **No artifacts observable:** no protocol errors, no size mismatches, clean exit `0`.
  (True tearing/stretching inspection needs composited pixels — locked-console `A[ssh]`
  cannot see them; covered by the Tier-C queue entry.)

---

## Sources

- **This demo** — [`./examples/f02-resize/app.d`][demo-app],
  [`./examples/f02-resize/instrument.d`][instrument]; the
  [AppKit scaffold findings][scaffold] (recipe, build command, the 6-resize baseline
  storm) and the [AppKit survey][survey].
- **Feature specs** — [F02 resize][f02]; the related [F01 first pixel][f01-doc] (this
  tree), [F04 frame pacing][f04], [F14 window state][f14]; the Tier-C entry in the
  [manual-run queue][queue].
- **Apple Developer documentation** (Wayback-pinned, bot-hostile host):
  [`NSWindow`][nswindow], [`setFrame:display:`][setframe],
  [`setContentSize:`][setcontentsize], [`zoom:`][zoom], [`isZoomed`][iszoomed],
  [`setFrameSize:`][setframesize], [`drawRect:`][drawrect],
  [`convertRectToBacking:`][convertrecttobacking],
  [`viewWillStartLiveResize`][viewwillstartliveresize],
  [`viewDidChangeBackingProperties`][viewdidchangebackingproperties],
  [`backingScaleFactor`][backingscalefactor].

<!-- References -->

<!-- This tree -->

[survey]: ./index.md
[scaffold]: ./scaffold.md
[sidecar]: ./scaffold.md#windowserver-sidecar-evidence-assh
[demo-app]: ./examples/f02-resize/app.d
[instrument]: ./examples/f02-resize/instrument.d
[f02]: ../features/f02-resize.md
[f04]: ../features/f04-frame-pacing.md
[f14]: ../features/f14-window-state.md
[f01-doc]: ./f01-first-pixel.md
[queue]: ../manual-run-queue.md

<!-- Apple developer docs (Wayback-pinned, bot-hostile host) -->

[nswindow]: https://web.archive.org/web/20260503224546/https://developer.apple.com/documentation/appkit/nswindow
[setframe]: https://web.archive.org/web/20250114235144/https://developer.apple.com/documentation/appkit/nswindow/setframe(_:display:)
[setcontentsize]: https://web.archive.org/web/20250115010233/https://developer.apple.com/documentation/appkit/nswindow/setcontentsize(_:)
[zoom]: https://web.archive.org/web/20250609073620/https://developer.apple.com/documentation/appkit/nswindow/zoom(_:)
[iszoomed]: https://web.archive.org/web/20251119075532/https://developer.apple.com/documentation/appkit/nswindow/iszoomed
[setframesize]: https://web.archive.org/web/20250609073524/https://developer.apple.com/documentation/appkit/nsview/setframesize(_:)
[drawrect]: https://web.archive.org/web/20250406152307/https://developer.apple.com/documentation/appkit/nsview/draw(_:)?language=objc
[convertrecttobacking]: https://web.archive.org/web/20200823150514/https://developer.apple.com/documentation/appkit/nsview/1483648-convertrecttobacking
[viewwillstartliveresize]: https://web.archive.org/web/20250609073528/https://developer.apple.com/documentation/appkit/nsview/viewwillstartliveresize()
[viewdidchangebackingproperties]: https://web.archive.org/web/20250609073527/https://developer.apple.com/documentation/appkit/nsview/viewdidchangebackingproperties()
[backingscalefactor]: https://web.archive.org/web/20251102044301/https://developer.apple.com/documentation/appkit/nswindow/backingscalefactor
