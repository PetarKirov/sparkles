# AppKit F11 — Scroll fidelity

Per the [F11 feature spec][f11], one physical scroll reaches a macOS app as **one
[`scrollWheel:`][scrollwheel] event carrying three representations**: the modern
[`scrollingDeltaX/Y`][scrollingdeltax] (pixel-precise when
[`hasPreciseScrollingDeltas`][precise] says so), the legacy
[`deltaX/deltaY`][deltay-f10] line-ish units, and the
[`phase`][phase]/[`momentumPhase`][momentumphase] pair that turns an event stream
into trackpad gestures. This demo logs every field of every event, drives the
stream from both `CGEventCreateScrollWheelEvent` unit modes, probes the
CG→`NSEventPhase` mapping, and keys per-gesture summaries on the phase
transitions over a scrollable ruler. The program is
[`./examples/f11-scroll/app.d`][demo-app] (with the shared
[`instrument.d`][instrument] logger), built on the [scaffold][scaffold] recipe.

**Last reviewed:** June 11, 2026

All run findings are **`A[ssh]`**: built and executed on `mac-bsn` (aarch64-darwin,
macOS 26.3.1, LDC 1.41.0) over SSH with the console session **locked** — no real
wheel or trackpad, so events are built with `CGEventCreateScrollWheelEvent2`
(line- and pixel-unit) and delivered **in-process** via
[`+[NSEvent eventWithCGEvent:]`][eventwithcgevent] + `[window sendEvent:]` (the
[F07][f07-doc] route-1 workhorse). The synthetic stream exercises the full anatomy
and the phase machinery; a real trackpad fling's exact choreography is Tier C
([script](#tier-c-script-real-wheel-and-trackpad-fling)).

| Measurement                           | Value                                                                                         |
| ------------------------------------- | --------------------------------------------------------------------------------------------- |
| Line-unit notch at the CG layer       | 1 notch → `DeltaAxis1=1`, `FixedPtDeltaAxis1=1.000`, `PointDeltaAxis1=10`, `IsContinuous=0`   |
| The line↔pixel ratio CG bakes in     | **1 line = 10 px** (`point1 = 10 × lines`, both unit modes)                                   |
| Line-unit event at the NSEvent layer  | `precise=0`, **`scrollingDeltaY == deltaY == 1.0`** (line units, _not_ ×10)                   |
| Pixel-unit event at the NSEvent layer | `precise=1`, `scrollingDeltaY = px` (10 → 10.00), `deltaY = px/10` (10 → 1.000)               |
| Smallest representable step           | fractional via 16.16 `FixedPtDeltaAxis1` (0.4 → `sdy=0.40`, `legacy_dy=0.400`)                |
| Device-class signal                   | `kCGScrollWheelEventIsContinuous` ↔ `hasPreciseScrollingDeltas`, 1:1 both ways               |
| CG phase → `NSEventPhase`             | re-encoded, not passed through: `1→0x1, 2→0x4, 4→0x8, 8→0x10` (began/changed/ended/cancelled) |
| CG momentum → `momentumPhase`         | `1→0x1(began), 2→0x4(changed), 3→0x8(ended)` — sequential in, bitmask out                     |
| `sendEvent:` vs momentum events       | **dropped** (`momentumPhase≠0` never reached the view; direct call fallback used)             |
| `isDirectionInvertedFromDevice`       | 0 on every synthetic event (natural-scroll flip is a real-device property; Tier C)            |
| Exit                                  | clean `0` (`loop_exit steps=18 arrivals=16`; `totals … gestures=2 final_offset_y=-217.4`)     |

---

## The unit duality: one CG constructor, two meanings `A[ssh]`

[`CGEventCreateScrollWheelEvent`][cgscroll] takes a
[`CGScrollEventUnit`][cgscrollunit] — and whichever unit you pick, Quartz
synthesizes **all three delta fields** ([`CGEventField`][cgeventfield] read-backs),
converting at a fixed **10 px per line**:

```text
244902 APPKIT_F11 inject label=line_1_notch units=line wheel1=1 cg_phase=-1 cg_momentum=-1
244936 APPKIT_F11 cg_fields label=line_1_notch delta1=1 fixedpt1=1.000 point1=10 continuous=0 phase=0 momentum=0
245042 APPKIT_F11 scroll sdx=0.00 sdy=1.00 legacy_dx=0.000 legacy_dy=1.000 precise=0 phase=0x0(none) momentum=0x0(none) inverted=0
694428 APPKIT_F11 inject label=pixel_10 units=pixel wheel1=10 cg_phase=-1 cg_momentum=-1
694537 APPKIT_F11 cg_fields label=pixel_10 delta1=1 fixedpt1=1.000 point1=10 continuous=1 phase=0 momentum=0
694706 APPKIT_F11 scroll sdx=0.00 sdy=10.00 legacy_dx=0.000 legacy_dy=1.000 precise=1 phase=0x0(none) momentum=0x0(none) inverted=0
```

Two events with **identical CG delta fields** (`delta1=1 fixedpt1=1.000 point1=10`)
— the only difference is `IsContinuous`, set by the constructor's unit — and the
wrapped `NSEvent` reads completely differently:

- **Line unit** (`IsContinuous=0`) → [`hasPreciseScrollingDeltas`][precise]` = NO`,
  and `scrollingDeltaY` reports the **line** count (`1.00`), equal to legacy
  `deltaY`. The "1 notch = `scrollingDeltaY` ~10" folklore is **not** what the
  event carries: for imprecise events the documented contract is that
  `scrollingDeltaX/Y` is line-based and the _app_ multiplies by its own line
  height. (CG's `PointDeltaAxis1=10` is where a default ~10 px line lives, but
  AppKit does not pre-multiply it into the event.)
- **Pixel unit** (`IsContinuous=1`) → `precise=1`, `scrollingDeltaY` is the pixel
  value (`10.00`, and `120 → 120.00`), and legacy `deltaY` becomes **px/10**
  (`1.000`, `12.000`) — the same ×10 constant, applied in the other direction.

So device class is a **1:1 wire signal** (`IsContinuous` ↔
`hasPreciseScrollingDeltas`), and the two delta families are unit-coherent only
through the 10 px/line constant. Multi-tick and negative values scale linearly
(`line_3_notches → sdy=3.00`, `line_minus2 → sdy=-2.00`).

**The smallest representable step** is far below one notch: forcing the 16.16
fixed-point field ([`FixedPtDeltaAxis1`][cgeventfield] `= 0.4`) yields
`sdy=0.40 legacy_dy=0.400 precise=0` — fractional _line_ deltas exist in the
event model (this is where sub-notch high-resolution wheels live), independent of
the pixel-precise flag.

```text
998693 APPKIT_F11 cg_fields label=line_fractional_0.4 delta1=0 fixedpt1=0.400 point1=0 continuous=0 phase=0 momentum=0
998795 APPKIT_F11 scroll sdx=0.00 sdy=0.40 legacy_dx=0.000 legacy_dy=0.400 precise=0 phase=0x0(none) momentum=0x0(none) inverted=0
```

One-line contrasts: Win32 quantizes the wire to `WHEEL_DELTA` 120ths the app must
accumulate ([Win32 F11][win32-f11]); Wayland sends value + `v120` + source
explicitly ([Wayland F11][wayland-f11]); X11 sends the same scroll twice in two
encodings ([X11 F11][x11-f11]). AppKit is the only one that ships **both
resolutions plus the device class in every event** — pre-converted, no
accumulation contract.

---

## The phase probe: CG values are re-encoded into `NSEventPhase` `A[ssh]`

Does a phase set on the CGEvent
([`kCGScrollWheelEventScrollPhase`][cgphasefield]) surface in the wrapped
`NSEvent`? Yes — **translated, not passed through**:

```text
1145134 APPKIT_F11 cg_fields label=phase_began_probe ... phase=1 momentum=0
1145251 APPKIT_F11 scroll ... phase=0x1(began) momentum=0x0(none) ...
1295495 APPKIT_F11 cg_fields label=fling_changed_30 ... phase=2 ...
1295642 APPKIT_F11 scroll ... phase=0x4(changed) ...
1598663 APPKIT_F11 cg_fields label=fling_ended ... phase=4 ...
1598757 APPKIT_F11 scroll ... phase=0x8(ended) ...
2498697 APPKIT_F11 cg_fields label=cancel_cancelled ... phase=8 ...
2498811 APPKIT_F11 scroll ... phase=0x10(cancelled) ...
```

| CG `ScrollPhase` in           | [`NSEventPhase`][nseventphase] out | CG `MomentumPhase` in | `momentumPhase` out |
| ----------------------------- | ---------------------------------- | --------------------- | ------------------- |
| `kCGScrollPhaseBegan = 1`     | `Began = 0x1`                      | `Begin = 1`           | `Began = 0x1`       |
| `kCGScrollPhaseChanged = 2`   | `Changed = 0x4`                    | `Continue = 2`        | `Changed = 0x4`     |
| `kCGScrollPhaseEnded = 4`     | `Ended = 0x8`                      | `End = 3`             | `Ended = 0x8`       |
| `kCGScrollPhaseCancelled = 8` | `Cancelled = 0x10`                 | —                     | —                   |

The momentum mapping is the telltale: CG's `CGMomentumScrollPhase` is a
**sequential** enum (`0,1,2,3`) while `NSEventPhase` is a **bitmask** — `2 → 0x4`
and `3 → 0x8` cannot be a bit-copy. `eventWithCGEvent:` performs a semantic
re-encode, and both gesture dimensions ride one event type (a momentum event is
just a scroll with `phase=none, momentumPhase≠none`).

One routing asymmetry fell out of the same probe: `[window sendEvent:]` delivered
every phase-bearing _drag_ event to the view, but **dropped every
momentum-phase event** (`route … sendEvent=not_delivered fallback=direct`, 4 of 4).
AppKit routes momentum scrolls to the view that owned the gesture's begin — state
that a wrapped, window-less synthetic event never established. Real momentum events
(delivered by the WindowServer through `NSApplication`) carry that association;
synthetic ones need the direct-call fallback. A reminder that **momentum is
delivered as events on macOS, not app-synthesized** — but their routing is
stateful.

---

## Gestures over the ruler: summaries keyed on transitions `A[ssh]`

The scripted fling — `began → changed ×2 → ended`, then momentum
`began → changed ×2 → ended`, then a `began → cancelled` pair — drives the
per-gesture accumulators:

```text
1145405 APPKIT_F11 gesture n=1 state=begin
1598838 APPKIT_F11 gesture_summary n=1 kind=drag end=ended events=4 total_sdy=55.00 total_legacy_dy=5.500
1748923 APPKIT_F11 gesture n=1 state=momentum_begin
2198935 APPKIT_F11 gesture_summary n=1 kind=momentum events=4 total_sdy=26.00
2348827 APPKIT_F11 gesture n=2 state=begin
2498953 APPKIT_F11 gesture_summary n=2 kind=drag end=cancelled events=2 total_sdy=4.00 total_legacy_dy=0.400
2648634 APPKIT_F11 totals arrivals=16 gestures=2 final_offset_y=-217.4
```

- The drag and momentum halves of one fling arrive as **two phase streams on one
  event type**; `ended`/`cancelled` events carry zero deltas (terminators, not
  motion).
- The 10:1 ratio holds across a whole gesture (`total_sdy=55.00` vs
  `total_legacy_dy=5.500`).
- The **cancelled** shape is exactly a gesture summary with `end=cancelled` and
  whatever deltas arrived before the cancel (`4.00` here) — the documented cue for
  scroll views to snap back rather than commit; per-event `gesture_summary
kind=discrete` lines cover phase-less wheel events (every `phase=none,
momentum=none` event is its own "gesture").
- The ruler offset (`final_offset_y=-217.4`) integrates `scrollingDeltaY` across
  all 16 events — mixed line- and pixel-unit streams integrate without special
  casing only because the demo treats them uniformly; a real scroll view must
  branch on `hasPreciseScrollingDeltas` (multiply lines by line height) or
  under-scroll wheel input by ~10×.

[`isDirectionInvertedFromDevice`][inverted] read **0 on all 16 events**: the
natural-scrolling flip is recorded at event _creation_ from a real device's
preference context, not synthesized by the wrap — whether it reads 1 with "natural
scrolling" enabled is part of the Tier-C pass.

---

## Tier C script: real wheel and trackpad fling

Run on `mac-bsn` in an **unlocked** GUI session (results → this doc):

1. Build per the [scaffold][scaffold] (binary staged at `/tmp/wsi-m6/f11-scroll/demo`),
   run `./demo` with **no** env vars; the window shows a horizontal-tick ruler.
2. **Wheel (external mouse):** one slow notch at a time. Expect
   `precise=0 phase=0x0 momentum=0x0`, integer-ish `sdy` — record whether macOS
   reports plain `1.0` lines per notch or accelerated multi-line values on faster
   spins, and each notch as a `kind=discrete` summary.
3. **Trackpad two-finger drag (no fling):** expect `precise=1`, a
   `phase=mayBegin (0x20)` event first (the resting-fingers probe — the one phase
   the synthetic run cannot produce), then `began → changed ×N` with fractional
   pixel deltas, and `ended` with zero delta on lift. Confirm
   `isDirectionInvertedFromDevice=1` with natural scrolling on, and the legacy
   `deltaY ≈ sdy/10` relationship on real events.
4. **Fling:** flick and lift. Expect the drag trio, then immediately
   `momentum=0x1(began)` followed by `changed` events with **decaying** deltas at a
   steady event rate (events, not app timers), closing with `momentum=0x8(ended)`;
   record the decay duration and per-gesture totals.
5. **Interrupted fling:** flick, then tap the trackpad mid-momentum. Record the
   exact terminator (`momentum ended` vs `cancelled`) and whether a new `mayBegin`
   opens immediately — the cancelled-shape ground truth.
6. **Ruler feel:** confirm over/under-scroll is visible (wheel notches should move
   the ruler noticeably less than a comparable trackpad drag unless the app
   multiplies lines by line height — the deliberate bug this demo leaves in).

---

## Findings summary (for `event-sequences.md`)

- **One event, three representations**: pixel-precise `scrollingDeltaX/Y`
  (trackpad), line-based `scrollingDeltaX/Y` (wheel — same property, different
  unit!), and legacy `deltaX/Y` always in lines. `hasPreciseScrollingDeltas` is the
  unit switch and the device-class signal, wired 1:1 from CG's `IsContinuous`.
  Quartz's internal line↔pixel constant is **10 px/line**.
- **A lossless framework scroll event** on macOS must carry: both delta values,
  the precise flag, both phase fields, and the inversion flag — drop any one and a
  device class or gesture boundary becomes unrecoverable. Fractional line deltas
  (16.16 fixed-point) are representable and must not be truncated.
- **Phases are a re-encoded layer**: CG's sequential/bit values map onto the
  `NSEventPhase` bitmask (`changed=0x4`, `ended=0x8`) via `eventWithCGEvent:`;
  momentum is **delivered as events** tagged `momentumPhase`, routed statefully to
  the gesture's origin view (which is why `sendEvent:` drops synthetic momentum
  events lacking that association).
- **Gesture boundaries are explicit**: `began`/`ended`/`cancelled` (+ `mayBegin`
  on real trackpads) — terminators carry zero delta; `cancelled` means snap back.
  Phase-less events are self-contained discrete scrolls.
- **The portability trap is the unit fork**: integrating `scrollingDeltaY`
  uniformly under-scrolls wheels by ~10× (or over-scrolls trackpads); every
  consumer must branch on the precise flag — the macOS analog of Win32's
  accumulate-120ths contract.

---

## Sources

- **This demo** — [`./examples/f11-scroll/app.d`][demo-app],
  [`./examples/f11-scroll/instrument.d`][instrument]; the
  [AppKit scaffold findings][scaffold] (recipe, locked-session evidence), the
  [F07 text-input findings][f07-doc] (the in-process `sendEvent:` route), and the
  [AppKit survey][survey].
- **Feature spec** — [F11 scroll fidelity][f11]; sibling columns:
  [Wayland][wayland-f11], [Win32][win32-f11], [X11][x11-f11]; the Tier-C entry in
  the [manual-run-queue][queue].
- **Apple Developer documentation** (Wayback-pinned where a verified snapshot
  exists; this host is bot-hostile): [`scrollWheel(with:)`][scrollwheel],
  [`scrollingDeltaX`][scrollingdeltax] / [`scrollingDeltaY`][scrollingdeltay]
  (the line-vs-pixel unit contract quoted above lives here),
  [`hasPreciseScrollingDeltas`][precise], [`phase`][phase],
  [`momentumPhase`][momentumphase], [`NSEvent.Phase`][nseventphase],
  [`isDirectionInvertedFromDevice`][inverted],
  [`NSEvent init(cgEvent:)`][eventwithcgevent],
  [`CGEventCreateScrollWheelEvent`][cgscroll],
  [`CGScrollEventUnit`][cgscrollunit], [`CGEventField`][cgeventfield],
  [`scrollWheelEventScrollPhase`][cgphasefield].

<!-- References -->

<!-- This tree -->

[survey]: ./index.md
[scaffold]: ./scaffold.md
[demo-app]: ./examples/f11-scroll/app.d
[instrument]: ./examples/f11-scroll/instrument.d
[f11]: ../features/f11-scroll.md
[f07-doc]: ./f07-text-input.md
[deltay-f10]: ./f10-pointer-capture.md
[wayland-f11]: ../wayland/f11-scroll.md
[win32-f11]: ../win32/f11-scroll.md
[x11-f11]: ../x11/f11-scroll.md
[queue]: ../manual-run-queue.md

<!-- Apple developer docs (Wayback-pinned where a verified snapshot exists) -->

[scrollwheel]: https://web.archive.org/web/20250609072932/https://developer.apple.com/documentation/appkit/nsresponder/scrollwheel(with:)
[scrollingdeltax]: https://web.archive.org/web/20251101094851/https://developer.apple.com/documentation/appkit/nsevent/scrollingdeltax
[scrollingdeltay]: https://developer.apple.com/documentation/appkit/nsevent/scrollingdeltay
[precise]: https://developer.apple.com/documentation/appkit/nsevent/hasprecisescrollingdeltas
[phase]: https://developer.apple.com/documentation/appkit/nsevent/phase-swift.property
[momentumphase]: https://developer.apple.com/documentation/appkit/nsevent/momentumphase
[nseventphase]: https://developer.apple.com/documentation/appkit/nsevent/phase-swift.struct
[inverted]: https://developer.apple.com/documentation/appkit/nsevent/isdirectioninvertedfromdevice
[eventwithcgevent]: https://web.archive.org/web/20250609072434/https://developer.apple.com/documentation/appkit/nsevent/init(cgevent:)
[cgscroll]: https://developer.apple.com/documentation/coregraphics/cgevent/init(scrollwheelevent2source:units:wheelcount:wheel1:wheel2:wheel3:)
[cgscrollunit]: https://developer.apple.com/documentation/coregraphics/cgscrolleventunit
[cgeventfield]: https://developer.apple.com/documentation/coregraphics/cgeventfield
[cgphasefield]: https://developer.apple.com/documentation/coregraphics/cgeventfield/scrollwheeleventscrollphase
