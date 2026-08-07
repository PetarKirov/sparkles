# `apps/diagram` — Feature Requirements

_**Status:** proposed — every row is **not started** · **Date:** 2026-08-08 ·
**Scope:** `apps/diagram` — architecture (`DIA`), camera (`CAM`), world (`WLD`),
interaction (`IXN`), rendering (`RND`)._

## Architecture (`DIA`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                              | Status      | Traces to                        |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | -------------------------------- |
| DIA1 | The application depends on `sparkles:ui`, `sparkles:ui-app`, `sparkles:input`, `sparkles:base`, `sparkles:core-cli` and **nothing else** — no `sparkles:ui-tui`, `sparkles:ui-raylib`, `raylib` or `sparkles.tui` import anywhere under `apps/diagram/` ([`APP2`](../ui-app/feature-requirements.md#architecture-app)). | not started | `apps/diagram/dub.sdl`           |
| DIA2 | The isolation check is a **manual grep**, run at every phase gate and recorded in the PR: `rg -n "ui_tui\|ui_raylib\|sparkles\.tui\|import raylib" apps/diagram/` must find nothing. Deliberately not automated — the decision is recorded in the ui-app plan.                                                            | not started | PR checklists                    |
| DIA3 | The app enters through **`runApp`** (`HST10`): a component whose `view` supplies the (empty) page tree, whose `handle` feeds `systemInput`, and whose `paint` (`HST13`) replays the frame's op buffer onto `host.canvas` through the toolkit's immediate interpreter — so the board renders identically on both arms.    | not started | `src/app.d`                      |
| DIA4 | Two configurations: the default carries the host's `full` closure; a `no-gui` configuration carries `tui` only — proving the app builds and runs where no GPU stack exists.                                                                                                                                              | not started | `apps/diagram/dub.sdl`           |
| DIA5 | The world's columns and the frame's op buffer are `SmallBuffer`/fixed arrays; labels live in fixed `char[labelCap]` slots — the steady-state frame is `@nogc`, asserted by compiling a frame path under the attribute.                                                                                                    | not started | `src/world.d`; `src/systems/`    |
| DIA6 | Every system is a **free function over `World`** — `Event → World` mutations and `World → ops` renders — so every behavior is a scripted-event or pure-function test against the recording target (`TST1`), and `main` is the only untested line.                                                                        | not started | `src/systems/`                   |

## Camera (`CAM`)

| ID   | Requirement                                                                                                                                                                                          | Status      | Traces to      |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------- |
| CAM1 | The camera is `origin` (world cell at the viewport's top-left) plus a **discrete** `zoom` level (powers of two, clamped) — integer cell geometry on both targets, so GUI and TUI agree on every mapping ([P3 constraints](../ui-app/PLAN.md#phase-3)). | not started | `src/camera.d` |
| CAM2 | `worldToScreen`/`screenToWorld` round-trip within a cell at every zoom; `zoomAt(pivot)` keeps the world cell under the pointer stationary; `panBy` is unbounded (an infinite canvas has no edge).                                                     | not started | `src/camera.d` |
| CAM3 | `visibleWorldRect` bounds render culling; `contentBounds` over live entities backs fit-all (`f`) and the minimap's content fit.                                                                                                                       | not started | `src/camera.d` |
| CAM4 | Minimap math — content→panel fit, panel local↔world, camera frustum in panel space — is pure and lives with the camera, tested without any render.                                                                                                    | not started | `src/camera.d` |
| CAM5 | Camera math is `@safe pure nothrow @nogc`, tested at **runtime** (union-backed vectors have no CTFE field reads — the recorded `sparkles:math` limitation).                                                                                           | not started | `src/camera.d` |

## World (`WLD`)

| ID   | Requirement                                                                                                                                                                                     | Status      | Traces to     |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | ------------- |
| WLD1 | Entities are dense `uint` indices with a free list; components are SoA columns (`bounds`, `zOrder`, `group`, label slot + length) sized by compile-time caps.                                     | not started | `src/world.d` |
| WLD2 | Groups are a `group` column (0 = none): grouping stamps a fresh group id on the selection, ungrouping clears it, and a move applies to every member — no nested hierarchy in the MVP.             | not started | `src/world.d` |
| WLD3 | Edges are `(from, to)` entity pairs in their own columns; deleting an entity deletes its edges.                                                                                                   | not started | `src/world.d` |
| WLD4 | Selection is a capped entity list plus the marquee in progress; all interaction state (tool, drag, menu, label edit, capture/press/hover) lives in `World` so a scripted test inspects one value. | not started | `src/world.d` |

## Interaction (`IXN`)

| ID   | Requirement                                                                                                                                                                                                                                                       | Status      | Traces to            |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | -------------------- |
| IXN1 | Pointer routing is layered, topmost first: context menu → toolbar → minimap → board (`screenToWorld`); a capture owner (create, marquee, move, pan, minimap scrub) holds the drag through the toolkit's `CaptureState`.                                            | not started | `src/systems/input.d` |
| IXN2 | Tools: select (`v`), rect-create (`r`), connect (`c`). Create drags a new box; select clicks/Shift-toggles/marquees; connect completes an edge on the second entity click; Esc cancels the pending half.                                                            | not started | `src/systems/input.d` |
| IXN3 | Pan is **middle-drag, Space+LMB, and arrows/WASD** — never a held-key-only binding, because a terminal cannot report key releases (`INP16`); every binding works identically on both targets.                                                                       | not started | `src/systems/input.d` |
| IXN4 | Wheel zooms toward the pointer via `zoomAt`; `+`/`-`/`0` zoom from the keyboard; `m` toggles the minimap; `f` fits content.                                                                                                                                        | not started | `src/systems/input.d` |
| IXN5 | The context menu (RMB) offers Group, Ungroup, Label…, Connect, Delete; label editing is the toolkit's `LineEditState` over the fixed edit buffer, committed to the entity's label slot on Enter and dismissed on Esc.                                              | not started | `src/systems/input.d` |
| IXN6 | Dismissal is a chain: Esc closes the menu, then cancels the pending interaction, then clears the selection, and only then quits; `q` quits directly.                                                                                                               | not started | `src/systems/input.d` |

## Rendering (`RND`)

| ID   | Requirement                                                                                                                                                                                                                          | Status      | Traces to                       |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------- |
| RND1 | Three op streams appended in order — board, minimap, chrome — into one reused `SmallBuffer!(DrawOp, N)`; z-order is append order.                                                                                                     | not started | `src/systems/render.d`          |
| RND2 | The board culls with `visibleWorldRect`: an off-camera entity emits nothing to the board stream and still appears on the minimap — asserted as a test, not an optimization note.                                                       | not started | `src/systems/render.d`          |
| RND3 | Connectors are **orthogonal routes drawn with box-drawing glyphs on both axes** (`─ │ ╭ ╮ ╰ ╯` + arrowheads) — they route through the GPU backend's procedural box drawing, so arms connect across cells on both targets; the canvas `line` primitive is not used for them ([P3 constraints](../ui-app/PLAN.md#phase-3)). | not started | `src/systems/render.d`          |
| RND4 | The grid is zoom-aware and faint; groups outline their members; the marquee and the create preview render from the in-progress drag state.                                                                                             | not started | `src/systems/render.d`          |
| RND5 | Colors come from the theme's slots — the app names `Slot`s, never RGB, except where the theme's page colors are the explicit page (`CLI`'s `--theme` works unmodified).                                                                | not started | `src/systems/render.d`          |

## Non-goals (MVP)

Save/load, undo, freehand drawing, diagonal connectors, continuous zoom,
multi-select handles/resize, edge labels, nested groups.
