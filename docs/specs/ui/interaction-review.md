# `sparkles:ui` interaction architecture review (`IXR`)

_**Status:** review complete; Android addendum 2026-08-02 · **Date:**
2026-07-31 · **Scope:** every pointer/keyboard interaction behavior hue
implements, audited for where it lives (toolkit vs `apps/hue`) and where the
GUI and TUI diverge._

## Why this review exists

The PR #143 UAT rounds fixed a dozen interaction bugs — pointer capture
leaking across the pane divider, scrollbar presses acting as row clicks,
thumb clicks jumping, hover pointer shapes reverting mid-drag, invisible
focus, wheel routing swallowed by the focused pane — and **every one was
fixed per pane, per backend, in `apps/hue`**. The GUI had grown its own
(differently-behaved) versions of the same affordances earlier. The pattern
is the one [`state-machines.md`](./state-machines.md) already names: where
behavior is written per backend, it diverges. This review is the inventory
that scopes the redesign: what exists where, what disagrees, and what the
toolkit must own so the next affordance is written once.

The stack levels referenced below: **STM** (level 1, pure state machines in
`libs/ui/src/sparkles/ui/state.d`), **components** (level 3,
`libs/ui/src/sparkles/ui/components/`), and the **hosts** (`apps/hue`'s
`gui.d` / `tui.d` / `explorer.d` / `workspace.d`, one per backend surface).

## Findings

| ID    | Behavior              | Toolkit today                                       | TUI host                                                                    | GUI host                                                                                                                           | Verdict                                                                                                            |
| ----- | --------------------- | --------------------------------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| IXR1  | Scrollbar geometry    | `scrollbarThumb` (STM2) — shared, property-tested   | uses it                                                                     | RESOLVED (B-1): `thumbGeometry` deleted; px layout via `ui_raylib.scrollbarLayout` over STM2                                       | resolved — one formula; the hover-expand easing is the reusable `ScrollbarAnim`                                    |
| IXR2  | Scrollbar interaction | `ScrollState.pressedAt`/`draggedTo` (grab-relative) | `sbDragging`+`sbGrab` duplicated in `tui.d` AND `explorer.d`                | RESOLVED (B-1): all four bars run `ScrollbarState.pressed/dragged/released` (px track units; 24 px thumb minimum threaded through) | resolved — one machine, one click semantics (thumb grabs in place, track jumps the leading edge)                   |
| IXR3  | Scrollbar painting    | none                                                | RESOLVED (B-1): both panes paint the WGT10 component                        | RESOLVED (B-1): all four bars draw via `ui_raylib.drawScrollbar`                                                                   | resolved — the cell component + its px twin; palette `track`/`thumb` entries are the one color authority           |
| IXR4  | Horizontal scrolling  | none                                                | none — wide content clips (explorer labels, fence panels, tables)           | none — same clipping                                                                                                               | **feature gap on every target**                                                                                    |
| IXR5  | Pane split            | `SplitState` (STM8) — shared                        | divider = exact column; `│` glyph paint                                     | divider = ±4 px zone; 1 px `DrawRectangle`                                                                                         | STM shared ✓; grab zone, paint, and hit metrics per host                                                           |
| IXR6  | Pointer capture       | none                                                | `pointerDown`/`pointerOnTree` in `workspace.d` (press owns drags)           | per-affordance boolean gates (`!split.dragging && !sb.isDragging && …`)                                                            | **two capture models**; the GUI's is allow-list gating that each new affordance must remember to extend            |
| IXR7  | Click-to-focus        | none                                                | on press, via the capture block                                             | two branches inside the selection click block                                                                                      | same intent, two code paths, historically inconsistent (the TUI's arrived in a bug fix)                            |
| IXR8  | Wheel routing         | none                                                | pane-under-cursor, 3 rows/notch, `workspace.d` block                        | pane-under-cursor by `mp.x`, fractional accumulation host-side                                                                     | policy duplicated; the GUI's fractional accumulation belongs in `RaylibEvents` (M14)                               |
| IXR9  | Pointer shape         | `PointerShape` + OSC 22 writers (`term_control`)    | grab-state decision + re-assertion in `workspace.d`; loop writes OSC 22     | the mirrored decision maps to raylib `MOUSE_CURSOR_*` in `gui.d`                                                                   | the decision logic is **copy-pasted**; only the vocabulary is shared                                               |
| IXR10 | Focus chrome          | `Slot.chromeFocused` + `headerBar(focused)`         | panes stamp `focused` in `workspace.paint`                                  | headers built inline per frame with `focused:` args                                                                                | component shared ✓ (PR #143/#144); stamping still per host                                                         |
| IXR11 | Document-pane state   | `ViewerModel` (`viewer_model.d`, raylib-free)       | **not used** — `PreviewTui` re-implements top/selection/search/folds/fences | uses it                                                                                                                            | **the biggest split**: the C1 Whole exists but only one backend consumes it                                        |
| IXR12 | Selection             | `Selection!T` (STM3) — shared                       | line-granular                                                               | char-precise + table regime + ANSI/strip copy modes                                                                                | STM shared ✓; the feature gap (TUI char-precision) is a consequence of IXR11                                       |
| IXR13 | Search/goto input     | none                                                | `searchKey` editing in `tui.d`                                              | `Mode.search/goto` + `GetCharPressed` editing in `gui.d`                                                                           | two line-editor implementations (the tree filter already shows the fix: shared `filter*` methods on `ExplorerTui`) |
| IXR14 | Key vocabulary        | `sparkles:input` events; `RaylibEvents` adapter     | `PosixEvents` decodes to it                                                 | ~35 raw raylib polls; `RaylibEvents` written but **unwired** (INP8)                                                                | the M17 milestone; blocks sharing every keyboard behavior above                                                    |
| IXR15 | Fold interaction      | `DisclosureState` (STM5) + `ViewerModel.foldAt`     | own fold state in `PreviewTui` (IXR11 again)                                | via `ViewerModel`                                                                                                                  | converges automatically when IXR11 is resolved                                                                     |

## Addendum: the Android surface (IXR16–IXR27)

This review was written on 2026-07-31. The Android port landed in parallel and
its interaction surface was never fed in — so a review whose entire thesis is
"behavior written per backend diverges" acquired a **third** backend without a
row. Worse, it acquired a whole new _modality_: touch has no hover, no precise
pointer, and more than one contact.

The cost showed up immediately, and is the thesis in miniature: the bottom
toolbar and the horizontal scrollbar were given overlapping hit zones by two
independent ad-hoc implementations, evaluated in one order and painted in the
other, so a single tap fired both. That was found by review, not by use.

| ID    | Behavior                     | Toolkit today                                | TUI host                              | GUI host (Android)                                                                               | Verdict                                                                                                                            |
| ----- | ---------------------------- | -------------------------------------------- | ------------------------------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| IXR16 | Gesture classification       | none — `sparkles:input` has no gesture layer | n/a                                   | `apps/hue/src/gui_touch.d` — `TouchScroller`: tap / drag / fling / long-press, pure, host-tested | **library code filed under `apps/`**: zero platform imports, `@safe pure nothrow @nogc`, coupled to raylib only through its caller |
| IXR17 | Fling integration            | none                                         | n/a                                   | the idle branch of `TouchScroller.update`                                                        | needs advancing by **time alone** — the input stack's first genuinely tier-2 (time-based) component                                |
| IXR18 | Pinch-zoom detection         | none                                         | n/a                                   | inline in the frame body (`GetTouchPointCount`/`GetTouchPosition`, 1.15/0.87 ratios)             | pure adapter work written in the app, and untested _because_ it is welded to raylib                                                |
| IXR19 | Mouse-as-first-touch mapping | none                                         | n/a                                   | `IsMouseButtonDown` + `GetMousePosition` fed as the finger                                       | the app should never learn that raylib aliases touch 0 onto the mouse                                                              |
| IXR20 | Pixel→row accumulation       | none                                         | n/a                                   | `touchAccumPx`, beside the wheel's own `wheelAccum`                                              | **two fractional-scroll accumulators in one loop**, same job, different units                                                      |
| IXR21 | Scroll routing               | none                                         | wheel: `wv.pos.x` (`workspace.d`)     | touch: the gesture **anchor**; wheel: the **live cursor**                                        | three spellings of "route to the pane under the pointer"; converges under IXB3                                                     |
| IXR22 | Wheel-step magnitude         | none                                         | ×3 consumer-side (3 files)            | ×3 consumer-side                                                                                 | **blocks touch reusing `WheelEvent`**: a drag already resolves to whole rows, so ×3 triples it                                     |
| IXR23 | Modality aliasing            | none                                         | n/a                                   | `clickPressed()`/`selectStartPressed()` `version (Android)` aliases, read at 8 sites             | half framework (a tap IS a click), half app policy (a long-press starts _a selection_)                                             |
| IXR24 | Tap consumption              | none                                         | `bool handle(Event)` returns consumed | a hand-rolled `touchFrame.tap = false` flag                                                      | a second consumption protocol, needed only because the tap is frame-level state read at 8 places                                   |
| IXR25 | Back / dismiss               | `Key` has `escape`, no `back`                | Esc clears popup, else quits          | raw `IsKeyPressed(KEY_BACK)`; `namedKey` maps neither `KEY_BACK` nor `KEY_MENU`                  | the platform _equivalence_ is the framework's; the dismiss _chain_ is hue's                                                        |
| IXR26 | Hover on a hoverless target  | components assume hover exists               | hover served                          | scrollbar hover-expand and the twoslash popup are driven by the **stale last-touch position**    | silent degradation of exactly the kind `backends.md` `TGT5` exists to declare                                                      |
| IXR27 | Action-bar hit test vs paint | none                                         | n/a                                   | five-segment toolbar: geometry written twice, ~1200 lines apart                                  | already produced three defects (invisible-but-live, overlap with the h-scrollbar, byte-length centring)                            |

Two further gaps the same audit surfaced, outside the pointer story:

| ID    | Behavior           | Where it lives now                                                                  | Verdict                                                                                        |
| ----- | ------------------ | ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| IXR28 | DPI / cell metrics | `apps/terminal` (pt→px, no DPI) and `gui.d` (pt→px, plus an Android-only DPI scale) | two apps, two policies, zero libraries — while `FontSet` already owns `cellW`/`cellH`          |
| IXR29 | Font discovery     | `libs/raylib-text/…/font_set.d`, a module whose first import is `raylib`            | right library, wrong module: the discovery half is raylib-free and is the only half under test |

## The inconsistency list (user-visible today)

- Track click: GUI **centers** the viewport on the click; TUI jumps the
  thumb's **leading edge** to the pointer (IXR2).
- The GUI scrollbar hover-expands with an animated width; the TUI's is a
  fixed column (IXR1/IXR3 — acceptable divergence, but it should be a
  component parameter, not two programs).
- TUI selection is line-granular; GUI is char-precise with table and
  ANSI-copy regimes (IXR11/IXR12).
- The divider grab zone is one cell in the TUI, ±4 px in the GUI (IXR5).
- Wide content (explorer labels, fence panels, tables) silently clips on
  both targets with no way to reach it (IXR4).

## What the redesign must produce (Phase B scope)

| ID   | Requirement                                                                                                                                                                                                                                                                                                        |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| IXB1 | **`ScrollbarState`** (STM): axis (vertical/horizontal), geometry (STM2), grab (`pressedAt`/`draggedTo`/`released`), hover + hover-expand width as a `Timeline`-driven parameter, and the wanted `PointerShape` (`ns-resize`/`ew-resize` by axis). One paint component consumed by `GridCanvas` and `RaylibCanvas`. |
| IXB2 | **Horizontal scrollbars**: layout reports per-pane content overflow; the scrollbar component appears on the clipped axis, scrolls the pane's x-offset, and shares IXB1's machine. Explorer labels, fence panels and tables become reachable on every target.                                                       |
| IXB3 | **Workspace shell component**: pane composition, pointer capture (press-owns-drags), click-to-focus, wheel-under-cursor routing, divider (SplitState + paint + grab zone in the backend's hit metric), focus stamping — one implementation fed events by both hosts.                                               |
| IXB4 | **Pointer-shape seam**: the shell/components report one wanted `PointerShape` per event/frame; the TUI host writes OSC 22 (with the mid-grab re-assertion), the GUI host maps to raylib `MOUSE_CURSOR_*`. Hosts never compute shapes.                                                                              |
| IXB5 | **`PreviewTui` adopts `ViewerModel`** — the document pane's Whole becomes the one state for both backends; the TUI gains char-precise selection/search parity as a consequence, and fold/search/scroll fixes stop needing two patches.                                                                             |
| IXB6 | **One line-editor** for search/goto/filter input (the `filter*` methods generalized), consumed by both hosts.                                                                                                                                                                                                      |
| IXB7 | `RaylibEvents` wired (M14/M17): the GUI consumes `sparkles:input` events, so IXB3/IXB6 receive the same vocabulary from both hosts.                                                                                                                                                                                |

| IXB8 | **Gesture layer in `sparkles:input`**: `TouchScroller` moves to `sparkles.input.gesture` as a stream transducer, and `RaylibEvents` grows the touch arm that drives it. Recognized gestures are emitted in the vocabulary that already exists — a tap as `PointerEvent(press)`+`(release)`, a drag/fling as `WheelEvent` — so no consumer branches on modality; only long-press and pinch need a new `GestureEvent` case. Discharges IXR16–IXR20, IXR23, IXR24. |
| IXB9 | **Action-bar component + `PressState` STM**: a segmented band whose hit test is derived from the same laid-out frames as its paint, with press-arms/release-activates semantics. Partially discharges `WGT15` (Button), the toolkit's oldest unstarted tier-1 row. Closes IXR27, and makes its three defects unrepresentable rather than fixed. |
| IXB10 | **Declared input capabilities (`TGT5`)**: hover, precise pointer and multi-pointer become target capabilities the toolkit can inspect, so a component seeing `hover: false` offers a non-hover route instead of animating one that never occurs. Closes IXR26. Note this is a capability _axis_, not a rung on the `InteractionTier` ladder — touch serves tier 1 and 2 while lacking hover, which is tier 0. |
| IXB11 | **`DisplayMetrics` in `sparkles:raylib-text`** (the pure pt→px conversion, next to the cell metrics it feeds) with the panel-scale _query_ in `sparkles:ui-raylib`. Closes IXR28; `apps/terminal` gains HiDPI it cannot express today. |
| IXB12 | **`sparkles.raylib_text.font_discovery`**: the raylib-free half of `font_set.d` as its own module, restoring that package's stated "only pure code carries unittests" invariant. Closes IXR29. Promotion to its own library waits for a consumer outside `raylib-text`. |

Sequencing note: **IXR22 must lead everything touch** — while the ×3 wheel
multiplier is applied consumer-side, a touch drag (already whole rows) cannot
reuse `WheelEvent` without scrolling triple; moving it producer-side with a
`precise` flag is a small independent commit across three files. After that,
IXB8 is mostly pure-library work reviewable in isolation, and it makes
`IXB7`/M17 _smaller_ rather than larger: `gui.d`'s touch block gets deleted,
not converted. IXB9 wants IXB1 first, so the toolbar's bottom-row ownership is
settled by the shared scrollbar rather than by a second hardcoded zone.
IXB11/IXB12 are independent of all of it.

The Android port also **raises IXB3's priority**. Before it, pointer capture
was justified by a divider and two scrollbars in a windowed app. Now there is a
third bottom-edge affordance on a device where the pointer is a fingertip
several cells wide — and IXR27 is the proof that two ad-hoc owners of one press
is not a hypothetical. Order: IXB1 → IXB9 → IXB3.

Original sequencing note: IXB1/IXB4 are independent and small; IXB3 wants IXB7 for
the GUI side but its TUI half can land first (the TUI workspace already
consumes `Event`s); IXB5 is the largest single move and unlocks IXR12/IXR15
convergence; IXB2 builds on IXB1 plus a layout-overflow report. The M14–M20
MVU/RPC plan then lands on top of a hue that is mostly shell + model.
