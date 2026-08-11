# `sparkles:ui` — Feature Specification

_**Status:** living inventory · **Date:** 2026-08-05 · **Scope:** `libs/ui`
(`libs/ui/src/sparkles/ui/*.d`), the sibling backend adapters
(`sparkles:ui-raylib`, `sparkles:ui-tui`), and `sparkles:input` — the shared
visual language behind every sparkles UI._

`sparkles:ui` is a **canvas-first UI toolkit**: one widget tree, laid out once,
painted by pluggable backends. A widget names a semantic
[`Slot`](./theme.md), never a concrete color; a backend supplies only draw
primitives and input events. The pipeline is
`view() → layout() → buildDisplayList() → paint(canvas)`, and every stage before
`paint` is `@safe` and GL-free, so the whole toolkit is unit-testable through a
`RecordingCanvas` with no window and no terminal.

This spec is the **source of truth** for the toolkit and the **decision record**
for the choices behind it — in particular the layout model
([`LAY2`](./layout.md)), which requirement pre-narrowed to a survey of
[`docs/research/ui-layout/`](../../research/ui-layout/index.md) and which is
settled here.

It supersedes [`docs/specs/hue/ui-architecture.md`](../hue/ui-architecture.md),
which proposed the library before it existed; that page now holds only hue's
own consumption requirements.

## Design sources

The toolkit's design is grounded in four research catalogs in this repository.
Where a requirement below cites one, the catalog is the _evidence_, this spec is
the _decision_.

| Source                                                                       | What it grounds                                                                                                                                           |
| ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [UI layout catalog](../../research/ui-layout/index.md)                       | the layout model — 24 engines surveyed across box-flow, flexbox, constraints-down, solver, retained, immediate and tiling families ([`LAY`](./layout.md)) |
| [Sean Parent catalog](../../research/sean-parent/index.md)                   | the architectural rules — Whole/Part ownership, value semantics, explicit relationships, illegal states unrepresentable ([`PRN`](./principles.md))        |
| [Tree-view case study](../../research/tui-libraries/tree-view-case-study.md) | the view-model/view split, exemplified by the tree widget ([`WGT`](./widgets.md), [`VMD`](./widgets.md))                                                  |
| [Anchored-overlay catalog](../../research/anchored-overlays/index.md)        | the anchored-overlay primitive — 38 subjects on anchors, placement, layering, triggers, dismissal and modality ([`POP`](./popup.md))                      |

## Documentation map

| Page                                                | What it covers                                                                                                                                                                                                                                                                    |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Overview** (this page)                            | what the toolkit is · the three levels · the package graph · the status/ID/traceability scheme · module coverage                                                                                                                                                                  |
| [Feature requirements](./feature-requirements.md)   | library-wide requirements: the three levels, the canvas-first contract, the package graph and its dependency-cycle constraints, build/`@nogc` posture                                                                                                                             |
| [Architectural principles](./principles.md)         | the binding rules the toolkit is held to, each traced to its source in the Sean Parent catalog — no incidental data structures, value semantics, explicit relationships, narrow contracts                                                                                         |
| [Layout](./layout.md)                               | **the `LAY2` decision record** — the surveyed families, the verdict (box-flow + orientation-aware measure + clip), the integer-unit rule, and the explicit list of what is _not_ implemented                                                                                      |
| [Theme](./theme.md)                                 | the unified runtime-swappable design language — syntax rules, semantic slots, glyph sets and metrics in one value, gated by terminal capabilities                                                                                                                                 |
| [Widgets](./widgets.md)                             | the view-model/view split, the widget catalog, `Props` vs handlers, keys and element identity                                                                                                                                                                                     |
| [Input](./input.md)                                 | the abstract event vocabulary, the tier-0/1/2 capability ladder, and the backend adapter contracts                                                                                                                                                                                |
| [State machines](./state-machines.md)               | presentation-free behavior: scrollbar, selection, hover, focus, disclosure, timeline                                                                                                                                                                                              |
| [Containers](./containers.md)                       | the container tier: `ScrollView` (owned scrolling) and the single-window docking layout (splits, tabbed groups, drag-to-redock, focus/capture ownership) — `SCV`/`DCK`                                                                                                            |
| [Inspector](./inspector.md)                         | the generic **inspector component** — a tree over a subject + details pane + the adapter-defined selection/extent contract, with the widget-tree adapter (toolkit self-inspection) — `INS`                                                                                        |
| [Anchored overlays](./popup.md) _(proposed)_        | the one anchored-overlay primitive behind every floating surface: the anchor value, the placement solve, the ordered top-layer arena that fills `DCK13`'s rung, triggers, dismissal, layering and modality — `POP`/`ANC`/`PLC`/`TRG`/`DSM`/`LYR`/`MDL`                            |
| [Editor](./editor.md) _(planned)_                   | the **editable-text component** — the `EditorState` machine (`EDT`), per-backend text input incl. IME/soft-keyboard phasing (`EDI`), the editor widget (`EDR`), and its consumers (`EDU`) — the capability behind hue's diff **write wave** ([`UIA9`](../hue/ui-architecture.md)) |
| [Backends](./backends.md)                           | the `isCanvas` seam, the shipped targets, per-backend declared capabilities, and forward-compatibility rules for additional GPU backends                                                                                                                                          |
| [Open implementation issues](./open-issues.md)      | concrete deferred gaps: Whole/copy semantics, the closed widget sum, and the native pointer grab                                                                                                                                                                                  |
| [Interaction review](./interaction-review.md)       | the 2026-07-31 audit of every pointer/keyboard behavior: where it lives (toolkit vs `apps/hue`), the GUI/TUI divergences, and the Phase B redesign scope (`IXR`/`IXB`)                                                                                                            |
| [Migration](./migration.md)                         | absorbing `core-cli`'s UI components and porting `apps/hue` onto the toolkit — the milestone plan                                                                                                                                                                                 |
| [Application host](../ui-app/index.md) _(proposed)_ | the sibling `sparkles:ui-app` package: backend selection, the shared window/font CLI, and the frame/event loop — the layer **above** the canvases, so an application never names one                                                                                              |

## The three levels

Each lower level is usable independently and free of presentation:

| Level              | Content                                                                      | Spec                         |
| ------------------ | ---------------------------------------------------------------------------- | ---------------------------- |
| 1 — state machines | pure logic over abstract input → state + derived geometry, in abstract units | [`STM`](./state-machines.md) |
| 2 — layout         | renderer-agnostic containers and sizing, producing rectangles                | [`LAY`](./layout.md)         |
| 3 — widgets        | `view(state) → WidgetTree`, composing levels 1 and 2 with draw primitives    | [`WGT`](./widgets.md)        |

Beneath them sit two cross-cutting concerns — the [theme](./theme.md) (`THM`),
which resolves a widget's semantic slot to concrete appearance, and
[input](./input.md) (`INP`), which feeds the state machines.

## Render targets

The toolkit itself is backend-agnostic; a target is a type satisfying
`isCanvas!T` plus, for interactive targets, an input adapter.

| Target      | Package              | Canvas            | Notes                                                                      |
| ----------- | -------------------- | ----------------- | -------------------------------------------------------------------------- |
| **TUI**     | `sparkles:ui-tui`    | `GridCanvas`      | cell grid over `sparkles:tui`; retained via the cell-diff compositor       |
| **GUI**     | `sparkles:ui-raylib` | `RaylibCanvas`    | GPU quads over `sparkles:raylib-text`; immediate mode                      |
| **HTML**    | `sparkles:ui`        | `interp/html`     | serializes the tree to markup + CSS; pure-CSS interactivity where possible |
| **testing** | `sparkles:ui`        | `RecordingCanvas` | captures a `DrawOp[]`; the GL-free seam every unit test renders through    |

## Status scheme

Every requirement row carries one **Status**:

| Status             | Meaning                                                                                                                                                                                                 |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **not started**    | no implementation yet.                                                                                                                                                                                  |
| **researched**     | design/notes exist (in code comments or a sibling doc), but no implementation.                                                                                                                          |
| **partial**        | implemented with a documented limitation or missing sub-case (the row's notes say what is missing).                                                                                                     |
| **full (`<sha>`)** | fully implemented; `<sha>` is the primary commit (the "commit hash evidence"). Where several commits contributed, the earliest feature commit is cited and later refinements are noted.                 |
| **decided**        | a _decision_ requirement rather than an implementation one — the choice is settled and recorded on the page itself. Used only where there is nothing to implement, e.g. "the layout model is box-flow". |

This matches the [hue spec's scheme](../hue/index.md#status-scheme) so the two
trees can cross-reference status without translation.

## ID scheme

Requirement IDs are `<AREA><n>` — a short area mnemonic plus a number, unique
within a document (e.g. `LAY4`, `WGT2`, `TGT1`). Areas: `UIA`/`PKG`/`NFR`
(library-wide), `PRN` (principles), `LAY` (layout), `THM` (theme), `WGT`/`VMD`
(widgets and view models), `INP` (input), `STM` (state machines), `INS`
(inspector), `TGT` (backends), `MIG` (migration), and — for
[anchored overlays](./popup.md) — `POP` (the primitive), `ANC` (anchors),
`PLC` (placement), `TRG` (triggers), `DSM` (dismissal), `LYR` (layering) and
`MDL` (modality and focus). Each area's mnemonic is expanded at its section
heading.

## Traceability

Every source file under `libs/ui/src/`, `libs/input/src/` and the backend
adapter packages is covered by at least one requirement. The **Module coverage**
table at the foot of each spec lists each file against the requirement IDs that
own it, so coverage is auditable in both directions: requirement → code (the
"Traces to" column of every row) and code → requirement (the coverage tables).

| Source file                                             | Primary spec + areas                                                                      |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `libs/ui/src/sparkles/ui/geometry.d`                    | [layout](./layout.md) — `LAY3`, `LAY6`                                                    |
| `libs/ui/src/sparkles/ui/layout.d`                      | [layout](./layout.md) — `LAY1`–`LAY8`, `LAY11`, `LAY12`                                   |
| `libs/ui/src/sparkles/ui/wrap.d`                        | [layout](./layout.md) — `LAY10`                                                           |
| `libs/ui/src/sparkles/ui/tracks.d`                      | [layout](./layout.md) — `LAY9`                                                            |
| `libs/ui/src/sparkles/ui/style.d`                       | [theme](./theme.md) — `THM1`–`THM5`                                                       |
| `libs/ui/src/sparkles/ui/theme.d`                       | [theme](./theme.md) — `THM6`–`THM9`                                                       |
| `libs/ui/src/sparkles/ui/canvas.d`                      | [backends](./backends.md) — `TGT1`, `TGT5`                                                |
| `libs/ui/src/sparkles/ui/widget.d`                      | [widgets](./widgets.md) — `WGT1`–`WGT6`                                                   |
| `libs/ui/src/sparkles/ui/display_list.d`                | [backends](./backends.md) — `TGT2`                                                        |
| `libs/ui/src/sparkles/ui/state.d`                       | [state machines](./state-machines.md) — `STM1`–`STM7`                                     |
| `libs/ui/src/sparkles/ui/interp/immediate.d`            | [backends](./backends.md) — `TGT3`                                                        |
| `libs/ui/src/sparkles/ui/interp/cells.d`                | [backends](./backends.md) — `TGT6`; superseded by the cell adapter and retired with it    |
| `libs/ui/src/sparkles/ui/interp/html.d`                 | [backends](./backends.md) — `TGT4`, `TGT7`                                                |
| `libs/ui/src/sparkles/ui/components/`                   | [widgets](./widgets.md) — `VMD*`, `WGT7`+                                                 |
| `libs/ui/src/sparkles/ui/components/inspector.d`        | [inspector](./inspector.md) — `INS1`–`INS5`                                               |
| `libs/input/src/sparkles/input/`                        | [input](./input.md) — `INP1`–`INP9`                                                       |
| `libs/ui-tui/src/`                                      | [backends](./backends.md) — `TGT6`                                                        |
| `libs/ui-raylib/src/`                                   | [backends](./backends.md) — `TGT6`                                                        |
| `libs/ui/src/sparkles/ui/overlay/anchor.d` _(planned)_  | [anchored overlays](./popup.md) — `ANC1`–`ANC9`                                           |
| `libs/ui/src/sparkles/ui/overlay/place.d` _(planned)_   | [anchored overlays](./popup.md) — `PLC1`–`PLC15`                                          |
| `libs/ui/src/sparkles/ui/overlay/arena.d` _(planned)_   | [anchored overlays](./popup.md) — `POP4`, `POP7`, `LYR1`–`LYR4`, `LYR9`, `LYR10`, `LYR12` |
| `libs/ui/src/sparkles/ui/overlay/policy.d` _(planned)_  | [anchored overlays](./popup.md) — `TRG1`–`TRG5`, `DSM1`–`DSM6`, `DSM11`, `MDL2`, `MDL3`   |
| `libs/ui/src/sparkles/ui/overlay/package.d` _(planned)_ | [anchored overlays](./popup.md) — re-exports only                                         |

→ [Feature requirements](./feature-requirements.md) · [Principles](./principles.md) · [Layout](./layout.md) · [Widgets](./widgets.md)
