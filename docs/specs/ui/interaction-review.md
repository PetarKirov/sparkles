# `sparkles:ui` interaction architecture review (`IXR`)

_**Status:** review complete · **Date:** 2026-07-31 · **Scope:** every
pointer/keyboard interaction behavior hue implements, audited for where it
lives (toolkit vs `apps/hue`) and where the GUI and TUI diverge._

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

Sequencing note: IXB1/IXB4 are independent and small; IXB3 wants IXB7 for
the GUI side but its TUI half can land first (the TUI workspace already
consumes `Event`s); IXB5 is the largest single move and unlocks IXR12/IXR15
convergence; IXB2 builds on IXB1 plus a layout-overflow report. The M14–M20
MVU/RPC plan then lands on top of a hue that is mostly shell + model.
