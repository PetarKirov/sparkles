# AppKit F12 — Cursors

The WindowServer composites the cursor on macOS; per the [F12 feature spec][f12] the
app's whole job is to _say which one_ — and this demo maps every way of saying it:
the [`NSCursor`][nscursor] standard-cursor vocabulary (probed getter-by-getter,
including the macOS 15 additions and the public-diagonal gap before them), a 3×3
hover-zone grid of [`NSTrackingArea`][nstrackingarea]s driving
[`cursorUpdate:`][cursorupdate], the legacy [`addCursorRect:cursor:`][addcursorrect]
path, a custom CPU-drawn bullseye via [`initWithImage:hotSpot:`][initwithimage], the
push/pop-vs-set cursor stack, and [`hide`][hide]/`unhide` pairing. The program is
[`./examples/f12-cursors/app.d`][demo-app] (with the shared
[`instrument.d`][instrument] logger), built on the [scaffold][scaffold] recipe.

**Last reviewed:** June 11, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn` (aarch64-darwin,
macOS 26.3.1, LDC 1.41.0, built-in Retina at scale 2.0) over SSH with the console
session **locked**. The lock removes exactly one thing: **pointer motion**. No real
`cursorUpdate:`/`mouseEntered:` can arrive (even a synthetic `CGEventPost` move
reached nothing — [probe below](#the-synthetic-motion-probe-a-ssh)), so the demo
drives `cursorUpdate:` directly per zone; every `set` call, image fact, and stack
transition is app-side state that works fully headless. On-screen cursor pixels are
Tier C ([script](#tier-c-script-hover-pass)).

| Measurement                        | Value                                                                                      |
| ---------------------------------- | ------------------------------------------------------------------------------------------ |
| Public standard-cursor getters     | **22 of 22 probed available** on macOS 26 (12 classic, 6 soft-deprecated resize, 4× 15.0)  |
| Public diagonal resize, pre-15     | **none** (`resizeNorthWestSouthEastCursor` absent; private `_windowResize…` exists)        |
| The 8 resize directions, macOS 15  | all 8 via `frameResizeCursorFromPosition:inDirections:` (edges 18×28/24×18, corners 22×22) |
| Tracking areas                     | 9 installed (`options=0x25`); `updateTrackingAreas` fired ×1 headless                      |
| Legacy `resetCursorRects`          | fired ×1 headless (first display pass) — both mechanisms coexist                           |
| Custom cursor                      | 24×24 pt `NSImage`, reps `2:24,48` px (1x+2x), hotspot (12,12) read back exactly           |
| HiDPI mechanism                    | multi-rep `NSImage` — system cursors ship rep pairs; arrow/iBeam ship **4** (28…280 px)    |
| `set` under a 2-deep stack         | replaces the **top** (pop then revealed the element beneath, not the replaced one)         |
| Synthetic `CGEventPost` mouse-move | posts fine, **0** tracking events delivered (locked session)                               |
| Exit                               | clean `0` (`loop_exit ticks=45 cursor_updates=9 … update_tracking=1 reset_rects=1`)        |

---

## The standard-cursor vocabulary — and its history `A[ssh]`

Every public `NSCursor` class getter, probed via `class_getClassMethod` (verbatim
excerpt):

```text
41332 APPKIT_F12 vocab sel=resizeLeftCursor available=1 note=10.0_soft_deprecated_15.0
41391 APPKIT_F12 vocab sel=columnResizeCursor available=1 note=15.0
41421 APPKIT_F12 vocab sel=frameResizeCursorFromPosition:inDirections: available=1 note=15.0
41446 APPKIT_F12 vocab sel=resizeNorthWestSouthEastCursor available=0 note=never_public
41462 APPKIT_F12 vocab sel=_windowResizeNorthWestSouthEastCursor available=1 note=private
```

The full map (all `available=1` on macOS 26 unless noted):

| Group                | Getters                                                                                                                                           | Since                             |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- |
| Core                 | `arrow`, `IBeam`, `crosshair`, `pointingHand`, `closedHand`, `openHand`, `disappearingItem`                                                       | 10.0                              |
| Later classics       | `operationNotAllowed` (10.5); `dragLink`, `dragCopy`, `contextualMenu` (10.6); `IBeamCursorForVerticalLayout` (10.7)                              | 10.5–10.7                         |
| Axis resize (legacy) | `resizeLeft`, `resizeRight`, `resizeLeftRight`, `resizeUp`, `resizeDown`, `resizeUpDown`                                                          | 10.0; **soft-deprecated in 15.0** |
| macOS 15 additions   | `zoomIn`, `zoomOut`, `columnResize(InDirections:)`, `rowResize(InDirections:)`, [`frameResizeCursorFromPosition:inDirections:`][frameresize]      | 15.0                              |
| Diagonal resize      | `resizeNorthWestSouthEastCursor` & co — **`available=0`, never existed publicly**; the private `_windowResizeNorthWestSouthEastCursor` does exist | —                                 |

This is the **vocabulary-gap deliverable**: for ~24 years AppKit publicly offered
only _axis-aligned_ resize cursors — the diagonal window-edge cursors every Mac user
sees were private API, and apps (browsers included) shipped their own diagonal-arrow
images. macOS 15 closed the gap with a _parameterized_ API instead of more getters:
[`frameResizeCursorFromPosition:inDirections:`][frameresize] takes a position
(4 edges + 4 corners, bitmask: `Top=1<<0, Left=1<<1, Bottom=1<<2, Right=1<<3`,
corners ORed) × directions (`Inward`/`Outward`/`All` — per the macOS 26 SDK header,
typo and all: "can be resized inwards or wards"), and simultaneously slapped
`API_DEPRECATED("Use either +[NSCursor columnResizeCursorInDirections:] or
+[NSCursor frameResizeCursorFromPosition:inDirections:] …", macos(10.0,
API_TO_BE_DEPRECATED))` on the legacy six. All eight directions, exercised:

```text
431182 APPKIT_F12 cursor_set name=frameResize.top path=macos15_frame_resize size_pt=18x28 hotspot=(9,14) reps=2:18,36
432083 APPKIT_F12 cursor_set name=frameResize.topLeft path=macos15_frame_resize size_pt=22x22 hotspot=(11,11) reps=2:22,44
432532 APPKIT_F12 cursor_set name=frameResize.bottomRight path=macos15_frame_resize size_pt=22x22 hotspot=(11,11) reps=2:22,44
```

Contrast in one line each: Win32's `IDC_*` set has had all four resize axes
(including both diagonals, `IDC_SIZENWSE`/`IDC_SIZENESW`) since Windows 3.x, and
X11's `cursor-font`/CSS-name themes carry all eight compass points (`nw-resize` …) —
AppKit was the outlier until 15.0, and remains the only one whose cursor vocabulary
is _typed API per shape_ rather than an ID/name table.

---

## Tracking areas, `cursorUpdate:`, and the legacy rects `A[ssh]`

The modern mechanism: register an [`NSTrackingArea`][nstrackingarea] with the
[`NSTrackingCursorUpdate`][trackingoptions] option and AppKit sends the owner
`cursorUpdate:` when the pointer enters; the handler calls `set` on the right cursor.
Nine zone areas install cleanly headless:

```text
77058 APPKIT_F12 tracking_install zone=0 rect=(0,0 160x107) options=0x25
77156 APPKIT_F12 tracking_areas count=9 note=cursor_update_incompatible_with_active_always
115727 APPKIT_F12 update_tracking_areas n=1 count=9
115762 APPKIT_F12 reset_cursor_rects n=1 mechanism=addCursorRect_cursor legacy=1
```

- `options=0x25` = `MouseEnteredAndExited | CursorUpdate | ActiveInKeyWindow`. The
  SDK header is explicit that the lazy-sounding alternative is off the table:
  `NSTrackingActiveAlways` is "Not supported for NSTrackingCursorUpdate"
  (`NSTrackingArea.h`) — cursor updates are tied to key-window status.
- [`updateTrackingAreas`][updatetrackingareas] (AppKit's "recompute your areas" hook)
  fired once during the first display pass, even headless.
- The **legacy mechanism rode along**: the view's [`resetCursorRects`][resetcursorrects]
  override (one [`addCursorRect:cursor:`][addcursorrect] over the bounds) was invoked
  once by the same first display pass — `areCursorRectsEnabled=1`, both generations
  of API active in one window. (A later explicit `invalidateCursorRectsForView:` did
  _not_ re-fire it headless — with no compositing pass, the re-build is deferred.)
  One-line contrast: cursor rects are the pre-10.5 push model AppKit itself now
  implements _on top of_ tracking areas; new code has no reason to touch them.

With no pointer, the 3×3 grid is driven by calling `cursorUpdate:` directly, one
zone per tick — same code path a real entry would take, minus the `NSEvent`:

```text
209638 APPKIT_F12 cursor_update n=1 zone=0 source=driven
209988 APPKIT_F12 cursor_set name=arrow path=standard size_pt=28x40 hotspot=(5,5) reps=4:28,56,140,280
222890 APPKIT_F12 cursor_set name=iBeam path=standard size_pt=23x22 hotspot=(12,11) reps=4:23,46,115,230
241951 APPKIT_F12 cursor_set name=pointingHand path=standard size_pt=32x32 hotspot=(13,8) reps=2:32,64
290977 APPKIT_F12 cursor_set name=resizeLeftRight path=standard_soft_deprecated size_pt=30x24 hotspot=(15,12) reps=2:30,60
321269 APPKIT_F12 cursor_set name=columnResize path=macos15 size_pt=30x24 hotspot=(15,12) reps=2:30,60
337853 APPKIT_F12 cursor_set name=customBullseye path=initWithImage_hotSpot size_pt=24x24 hotspot=(12,12) reps=2:24,48
```

---

## HiDPI: cursors are multi-rep `NSImage`s `A[ssh]`

There is no "cursor size" API to get right under HiDPI — an `NSCursor` wraps an
[`NSImage`][addrepresentation] whose _representations_ carry the densities, and
AppKit/WindowServer pick the rep matching the screen scale at display time. The
`reps=` field above is the evidence:

- Every system cursor ships at least a **1x+2x pair** (`crosshair 2:24,48`,
  `openHand 2:32,64`, frame-resize `2:18,36`).
- `arrow` and `iBeam` ship **four** reps — `28,56,140,280` px and `23,46,115,230` px:
  1x, 2x, and 5x/10x masters for the pointer-zoom accessibility feature.
- The custom cursor does the same by hand: one 24×24 pt `NSImage`, a 24 px 1x rep
  plus a 48 px rep with [`setSize:`][initwithimage] 24 pt (= 2x), `reps=2:24,48` —
  on this 2.0-scale screen the 48 px rep is the one that would composite (Tier C for
  the eyes; the selection rule is the documented multi-rep matching).

```text
90846 APPKIT_F12 custom_cursor image_pt=24x24 reps=2:24,48 hotspot=(12,12) note=hotspot_in_flipped_image_coords
```

The bullseye pixels are CPU-drawn RGBA into an
[`NSBitmapImageRep`][addrepresentation] (`initWithBitmapDataPlanes:` …
`bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES`), the [hot spot][hotspot] (12,12) —
the bullseye center — is in the image's **flipped** (top-left-origin) coordinate
space, and it reads back exactly.

---

## The cursor stack: `push`/`pop` vs `set` `A[ssh]`

[`push`][push] maintains an app-side stack; `set` does not — and what `set` does _to_
an existing stack is the probe:

```text
90932 APPKIT_F12 cursor_stack after=arrow.set current=arrow
91090 APPKIT_F12 cursor_stack after=iBeam.push current=iBeam
91176 APPKIT_F12 cursor_stack after=crosshair.push current=crosshair
91263 APPKIT_F12 cursor_stack after=pointingHand.set_under_stack current=pointingHand
91281 APPKIT_F12 cursor_stack after=pop_1 current=iBeam
91299 APPKIT_F12 cursor_stack after=pop_2 current=arrow
```

`set` while a 2-deep stack is outstanding **replaces the top element**: the first
`pop` after `pointingHand.set` revealed `iBeam` (the element _beneath_ the replaced
`crosshair`), and the second `pop` restored `arrow`. So `set` and the stack are one
mechanism — `set` = "replace top", `push` = "duplicate-then-replace top" (per its
docs, it "puts the receiver on top of the cursor stack and makes it the current
cursor"), [`pop`][pop] = "discard top" — which is why `set` works as the undo for an
unmatched [`push`][push]. The stack is per-app state and fully
functional headless ([`currentCursor`][nscursor] tracks every transition); none of it
requires a visible pointer.

And the [F10][f10] connection in one line: [`hide`][hide]/`unhide` is a separate
balanced _visibility counter_ on top of all this — a pointer-lock mode that hides
must unhide exactly once or the cursor stays invisible after release
(`cursor_visibility hide_unhide=balanced note=f10_lock_pairing`).

---

## The synthetic-motion probe `A[ssh]`

Could anything fire the tracking machinery without a console? A `CGEventPost`
mouse-move (session event tap, in-process, no accessibility prompt) aimed at the
window's global midpoint:

```text
528841 APPKIT_F12 step name=cg_event_probe target_global=(360,823) tap=session
542202 APPKIT_F12 cg_event_posted moves=2
765862 APPKIT_F12 synthetic_result cursor_updates_from_events=0 mouse_entered=0 mouse_exited=0 reset_cursor_rects=1 note=locked_session
```

The post succeeds (no error, no permission dialog), but **zero** `cursorUpdate:`/
`mouseEntered:`/`mouseExited:` events arrived: a locked session has no live pointer
pipeline to route the move back through the WindowServer's tracking-area machinery.
Honest static answer: tracking-area _registration_ is fully verifiable headless,
tracking-area _delivery_ is not — even synthetically.

---

## Tier C script: hover pass

Run on `mac-bsn` in an **unlocked** GUI session (results → this doc):

1. Build per the [scaffold][scaffold] (binary staged at `/tmp/wsi-m5/f12-cursors/demo`),
   run `./demo` with **no** env vars; the window shows a 3×3 gray checkerboard.
2. Hover each zone (bottom-left = zone 0, row-major upward). Expect a real
   `cursor_update … source=event` + `cursor_set` per crossing and the matching glyph:
   arrow, I-beam, pointing hand, crosshair, open hand, ↔ resize, ↕ resize, column
   resize, row resize — and in the top-right zone the **red/black bullseye** with its
   tip at the center (hotspot check: click precision).
3. Verify HiDPI crispness of the bullseye on the Retina panel (the 48 px rep — any
   blur means the 1x rep was picked) and, if an external 1x display is at hand, drag
   over and re-hover (the 24 px rep should serve there).
4. Confirm `mouse_entered`/`mouse_exited` pair per zone crossing and that the cursor
   reverts (per the `NSTrackingCursorUpdate` contract) when leaving the window.
5. While there: re-run the `CGEventPost` probe (tick 24) and record whether the
   synthetic move _does_ generate tracking events in an unlocked session.

---

## Findings summary (for `event-sequences.md`)

- **The server composites; the client only names a cursor.** No theme loading, no
  animation timers, no per-frame work (the Wayland contrast); cost on macOS is one
  `set` per zone crossing, delivered via `cursorUpdate:` from a registered
  `NSTrackingArea` (which cannot use `ActiveAlways`).
- **The vocabulary is typed getters, historically incomplete**: no public diagonal
  resize cursor for ~24 years (private API + app-shipped images filled the hole);
  macOS 15 added a parameterized 8-direction `frameResizeCursorFromPosition:` API
  and soft-deprecated the legacy axis getters. Win32/X11 have had the full compass
  set forever — a portability layer must ship diagonal fallbacks for macOS < 15.
- **HiDPI = multi-rep images, not a size parameter**: system cursors carry 1x+2x
  (arrow/iBeam up to 10x) reps; a custom cursor supplies its own reps and AppKit
  picks by screen scale. Hotspot is in flipped image coordinates, rep-independent.
- **Two generations of region mechanism coexist** (`resetCursorRects`/
  `addCursorRect:cursor:` still fires alongside tracking areas) — but only one is
  worth using.
- **`set` rewrites the top of the push/pop stack** (verified by pop-reveal), and
  `hide`/`unhide` is an independent balanced counter — the two leak classes (stuck
  cursor, invisible cursor) have different APIs behind them.
- **Registration is headless-verifiable; delivery is not** — even an in-process
  `CGEventPost` move produces zero tracking events in a locked session.

---

## Sources

- **This demo** — [`./examples/f12-cursors/app.d`][demo-app],
  [`./examples/f12-cursors/instrument.d`][instrument]; the
  [AppKit scaffold findings][scaffold] (recipe, locked-session evidence), and the
  [AppKit survey][survey].
- **Feature specs** — [F12 cursors][f12], [F10 pointer capture][f10]; the Tier-C
  entry in the [manual-run-queue][queue].
- **macOS 26 SDK headers** (primary source for availability/enums):
  `AppKit.framework/Headers/NSCursor.h` (the `NSCursorFrameResizePosition` bitmask,
  the `API_DEPRECATED` messages on the legacy resize getters, quoted above) and
  `NSTrackingArea.h` (option values; the `ActiveAlways`-vs-`CursorUpdate` note).
- **Apple Developer documentation** (Wayback-pinned where a verified snapshot exists;
  this host is bot-hostile): [`NSCursor`][nscursor],
  [`cursorUpdate:`][cursorupdate], [`NSTrackingArea`][nstrackingarea],
  [`NSTrackingArea.Options`][trackingoptions],
  [`updateTrackingAreas`][updatetrackingareas],
  [`addCursorRect:cursor:`][addcursorrect], [`resetCursorRects`][resetcursorrects],
  [`init(image:hotSpot:)`][initwithimage], [`hotSpot`][hotspot],
  [`frameResize(position:directions:)`][frameresize], [`push()`][push],
  [`pop()`][pop], [`hide()`][hide],
  [`NSImage.addRepresentation(_:)`][addrepresentation].

<!-- References -->

<!-- This tree -->

[survey]: ./index.md
[scaffold]: ./scaffold.md
[demo-app]: ./examples/f12-cursors/app.d
[instrument]: ./examples/f12-cursors/instrument.d
[f12]: ../features/f12-cursors.md
[f10]: ../features/f10-pointer-capture.md
[queue]: ../manual-run-queue.md

<!-- Apple developer docs (Wayback-pinned where a verified snapshot exists) -->

[nscursor]: https://web.archive.org/web/20260213230722/https://developer.apple.com/documentation/appkit/nscursor
[cursorupdate]: https://web.archive.org/web/20250609072928/https://developer.apple.com/documentation/appkit/nsresponder/cursorupdate(with:)
[nstrackingarea]: https://web.archive.org/web/20260309133336/https://developer.apple.com/documentation/appkit/nstrackingarea
[trackingoptions]: https://web.archive.org/web/20250609073435/https://developer.apple.com/documentation/appkit/nstrackingarea/options-swift.struct
[updatetrackingareas]: https://developer.apple.com/documentation/appkit/nsview/updatetrackingareas()
[addcursorrect]: https://web.archive.org/web/20260218182445/https://developer.apple.com/documentation/appkit/nsview/addcursorrect(_:cursor:)
[resetcursorrects]: https://web.archive.org/web/20260115174216/https://developer.apple.com/documentation/appkit/nsview/resetcursorrects()
[initwithimage]: https://web.archive.org/web/20251121061540/https://developer.apple.com/documentation/appkit/nscursor/init(image:hotspot:)
[hotspot]: https://web.archive.org/web/20250609072326/https://developer.apple.com/documentation/appkit/nscursor/hotspot
[frameresize]: https://developer.apple.com/documentation/appkit/nscursor/frameresize(position:directions:)
[push]: https://web.archive.org/web/20250609072328/https://developer.apple.com/documentation/appkit/nscursor/push()
[pop]: https://developer.apple.com/documentation/appkit/nscursor/pop()-swift.type.method
[hide]: https://web.archive.org/web/20251115150841/https://developer.apple.com/documentation/appkit/nscursor/hide()
[addrepresentation]: https://web.archive.org/web/20250609072600/https://developer.apple.com/documentation/appkit/nsimage/addrepresentation(_:)
