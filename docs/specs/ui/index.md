---
status: accepted
owner: sparkles:ui
reviewed: 2026-08-05
---

# `sparkles:ui` — Feature Specification

## Abstract

`sparkles:ui` is the user-interface toolkit Sparkles applications share,
whether they appear in a terminal, a desktop window, or a static HTML page. An
application describes its interface once, as a tree of widgets derived from its
state. The toolkit lays that tree out and reduces it to a flat list of drawing
operations, which a small backend paints for its target. Widgets name the role
each part plays rather than its color, so one theme restyles every target at
once. No step before painting needs a window or a terminal, so an entire
interface can be tested as data.

## Introduction

Sparkles applications must look and behave alike in very different places. The
hue file viewer runs both in a terminal and in a GPU-accelerated window, a
documentation gallery renders the same views to HTML, and a terminal emulator
embeds as one pane of a larger interface. Each place measures space in its own
unit: character cells, pixels, or CSS lengths. Each delivers input differently,
from escape sequences to polled device state, while static HTML offers only
what pure CSS can express. And each can draw a different subset of what a
design asks for.

Writing every widget once per target multiplies the code, and worse, lets
behavior drift. Selection, scrolling and focus end up modeled several times,
the models disagree, and a fix on one target never reaches the others. Native
widget toolkits do not close the gap, because a terminal has none and the
browser's behave differently from a desktop's. A floating-point layout engine
borrowed from the web brings its own defect: rounding produces off-by-one cells
on a terminal grid.

The toolkit is _canvas-first_. It owns all semantic behavior and composition,
and a backend contributes only primitive drawing, text measurement and the
translation of native input. The toolkit is built in three levels, each usable
without the ones above it. State machines hold behavior that has no
appearance, such as scrolling, selection, hover and focus. Layout places every
widget in whole [cells](../../glossary.md#cell), the abstract grid unit that is
one character position on a terminal and whose device size a pixel or HTML
backend chooses. Widgets compose the two, and each names a semantic
[slot](../../glossary.md#slot), such as "error text" or "selected row", never a
concrete color.

The laid-out tree then becomes a
[display list](../../glossary.md#display-list): a flat sequence of drawing
operations whose slots are already resolved against the theme, so a backend
never consults the theme or the tree. Layout obtains text measurement through
the canvas rather than a device, so a test substitutes a recording canvas,
which measures and records without any window, and inspects the list directly.
A target that cannot honour a
feature declares the limitation, and the toolkit degrades visibly rather than
silently.

This specification, spread across the pages listed below, covers the toolkit,
the abstract input vocabulary `sparkles:input`, and the contract each backend
adapter package must meet. It uses no native OS widgets on any target.
Choosing a backend, opening a window, loading fonts and running the frame loop
belong to the [application host](../ui-app/index.md), `sparkles:ui-app`, which
has its own specification. Decoding terminal escape sequences belongs to
`sparkles:tui`, and rasterizing glyphs to `sparkles:raylib-text`. The layout
model is deliberately smaller than CSS: no constraint solver, no full grid, no
wrapping of boxes; the [layout page](./layout.md) records each exclusion and
its reason. [hue's UI architecture](../hue/ui-architecture.md) holds only the
requirements hue places on the toolkit as a consumer; what the library is and
does is defined here.

This page is the source of truth for the toolkit and the record of the
decisions behind it, the layout model ([`LAY2`](./layout.md)) above all. It
defines the [three levels](#the-three-levels), the
[render targets](#render-targets), and the [status](#status-scheme),
[ID](#id-scheme) and [traceability](#traceability) schemes every sibling page
follows. Each sibling page below holds the requirements for one area under its
own ID prefix, and [Design sources](#design-sources) lists the research catalogs
the decisions rest on.

## Documentation map

| Page                                              | What it covers                                                                                                                                                                                                                                                                    |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Overview** (this page)                          | what the toolkit is · the three levels · the package graph · the status/ID/traceability scheme · module coverage                                                                                                                                                                  |
| [Feature requirements](./feature-requirements.md) | library-wide requirements: the three levels, the canvas-first contract, the package graph and its dependency-cycle constraints, build/`@nogc` posture                                                                                                                             |
| [Architectural principles](./principles.md)       | the binding rules the toolkit is held to, each traced to its source in the Sean Parent catalog — no incidental data structures, value semantics, explicit relationships, narrow contracts                                                                                         |
| [Layout](./layout.md)                             | **the `LAY2` decision record** — the surveyed families, the verdict (box-flow + orientation-aware measure + clip), the integer-unit rule, and the explicit list of what is _not_ implemented                                                                                      |
| [Theme](./theme.md)                               | the unified runtime-swappable design language — syntax rules, semantic slots, glyph sets and metrics in one value, gated by terminal capabilities                                                                                                                                 |
| [Widgets](./widgets.md)                           | the view-model/view split, the widget catalog, `Props` vs handlers, keys and element identity                                                                                                                                                                                     |
| [Input](./input.md)                               | the abstract event vocabulary, the tier-0/1/2 capability ladder, and the backend adapter contracts                                                                                                                                                                                |
| [State machines](./state-machines.md)             | presentation-free behavior: scrollbar, selection, hover, focus, disclosure, timeline                                                                                                                                                                                              |
| [Keymap & lantern](./keymap.md)                   | keyboard policy as data — `Binding!(Cmd, Scope)` tables over app-supplied enums, scope-order precedence with marker UDAs, two-direction resolution (`resolve`/`bindingsAt`), and the which-key-style guide machine + panel — `KEY`/`LTN`                                          |
| [Gutter channels](./gutter.md)                    | the per-line chrome model — line numbers, coverage counts, fold arrows, diff markers and blame as one set of layout channels beside the content, composed after layout, width-reserved, priority-merged and budgeted — `GUT`                                                      |
| [Containers](./containers.md)                     | the container tier: `ScrollView` (owned scrolling) and the single-window docking layout (splits, tabbed groups, drag-to-redock, focus/capture ownership) — `SCV`/`DCK`                                                                                                            |
| [Inspector](./inspector.md)                       | the generic **inspector component** — a tree over a subject + details pane + the adapter-defined selection/extent contract, with the widget-tree adapter (toolkit self-inspection) — `INS`                                                                                        |
| [Property tree](./property-tree.md)               | the reflective **property-tree component** — `PropertyTree!T` as an adapter over the tree widget: the type-only walk, metadata UDAs, path addressing, ranked fuzzy filtering, value-semantic edits with host-stored undo/redo, and the read-only script-free HTML posture — `PRT` |
| [Anchored overlays](./popup.md) _(proposed)_      | the one anchored-overlay primitive behind every floating surface: the anchor value, the placement solve, the ordered top-layer arena that fills `DCK13`'s rung, triggers, dismissal, layering and modality — `POP`/`ANC`/`PLC`/`TRG`/`DSM`/`LYR`/`MDL`                            |
| [Editor](./editor.md) _(planned)_                 | the **editable-text component** — the `EditorState` machine (`EDT`), per-backend text input incl. IME/soft-keyboard phasing (`EDI`), the editor widget (`EDR`), and its consumers (`EDU`) — the capability behind hue's diff **write wave** ([`UIA9`](../hue/ui-architecture.md)) |
| [Effects & images](./effects.md)                  | raster images in the widget tree and subtree effects: the effect bracket, the tier model that decides what survives to a cell grid, the effect registry, and built-in effects written once in D for both the terminal and the GPU — `EFX`/`IMG`                                   |
| [Effects demos](./effects-demos.md)               | the acceptance demos for `EFX`/`IMG`: one runnable command per visible feature, and what it should show                                                                                                                                                                           |
| [Backends](./backends.md)                         | the `isCanvas` seam, the shipped targets, per-backend declared capabilities, and forward-compatibility rules for additional GPU backends                                                                                                                                          |
| [Open implementation issues](./open-issues.md)    | concrete deferred gaps: Whole/copy semantics, the closed widget sum, and the native pointer grab                                                                                                                                                                                  |
| [Interaction review](./interaction-review.md)     | the dated audit of every pointer/keyboard behavior: where it lives (toolkit vs `apps/hue`), the GUI/TUI divergences, and the redesign it scoped (`IXR`/`IXB`)                                                                                                                     |
| [Migration](./migration.md)                       | absorbing `core-cli`'s UI components and porting `apps/hue` onto the toolkit — the milestone plan                                                                                                                                                                                 |
| [Application host](../ui-app/index.md)            | the sibling `sparkles:ui-app` package: backend selection, the shared window/font CLI, and the frame/event loop — the layer **above** the canvases, so an application never names one                                                                                              |

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
(inspector), `GUT` (gutter channels), `PRT` (property tree), `TGT` (backends),
`MIG` (migration),
and — for
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

| Source file                                             | Primary spec + areas                                                                                                                                             |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `libs/ui/src/sparkles/ui/geometry.d`                    | [layout](./layout.md) — `LAY3`, `LAY6`                                                                                                                           |
| `libs/ui/src/sparkles/ui/layout.d`                      | [layout](./layout.md) — `LAY1`–`LAY8`, `LAY11`, `LAY12`                                                                                                          |
| `libs/ui/src/sparkles/ui/wrap.d`                        | [layout](./layout.md) — `LAY10`                                                                                                                                  |
| `libs/ui/src/sparkles/ui/tracks.d`                      | [layout](./layout.md) — `LAY9`                                                                                                                                   |
| `libs/ui/src/sparkles/ui/style.d`                       | [theme](./theme.md) — `THM1`–`THM5`                                                                                                                              |
| `libs/ui/src/sparkles/ui/theme.d`                       | [theme](./theme.md) — `THM6`–`THM9`                                                                                                                              |
| `libs/ui/src/sparkles/ui/canvas.d`                      | [backends](./backends.md) — `TGT1`, `TGT5`                                                                                                                       |
| `libs/ui/src/sparkles/ui/widget.d`                      | [widgets](./widgets.md) — `WGT1`–`WGT6`                                                                                                                          |
| `libs/ui/src/sparkles/ui/display_list.d`                | [backends](./backends.md) — `TGT2`                                                                                                                               |
| `libs/ui/src/sparkles/ui/state.d`                       | [state machines](./state-machines.md) — `STM1`–`STM13`; [input](./input.md) — `INP10` (the hit-list consumers); [anchored overlays](./popup.md) — `ANC3`, `ANC7` |
| `libs/ui/src/sparkles/ui/keymap.d`                      | [keymap & lantern](./keymap.md) — `KEY2`–`KEY10`, `KEY13`                                                                                                        |
| `libs/ui/src/sparkles/ui/lantern.d`                     | [keymap & lantern](./keymap.md) — `LTN1`–`LTN4`, `LTN9`–`LTN12`                                                                                                  |
| `libs/ui/src/sparkles/ui/components/lantern_view.d`     | [keymap & lantern](./keymap.md) — `LTN5`–`LTN8`, `LTN14`                                                                                                         |
| `libs/ui/src/sparkles/ui/interp/immediate.d`            | [backends](./backends.md) — `TGT3`                                                                                                                               |
| `libs/ui/src/sparkles/ui/interp/cells.d`                | [backends](./backends.md) — `TGT6`; superseded by the cell adapter and retired with it                                                                           |
| `libs/ui/src/sparkles/ui/interp/html.d`                 | [backends](./backends.md) — `TGT4`, `TGT7`                                                                                                                       |
| `libs/ui/src/sparkles/ui/components/`                   | [widgets](./widgets.md) — `VMD*`, `WGT7`+                                                                                                                        |
| `libs/ui/src/sparkles/ui/components/inspector.d`        | [inspector](./inspector.md) — `INS1`–`INS5`                                                                                                                      |
| `libs/ui/src/sparkles/ui/components/gutter.d`           | [gutter channels](./gutter.md) — `GUT1`–`GUT9`                                                                                                                   |
| `libs/ui/src/sparkles/ui/property_tree.d` _(planned)_   | [property tree](./property-tree.md) — `PRT1`–`PRT11`, `PRT14`–`PRT35`                                                                                            |
| `libs/ui/src/sparkles/ui/components/property_view.d`    | [property tree](./property-tree.md) — `PRT12`–`PRT13`, `PRT21`, `PRT23`, `PRT25`–`PRT28`, `PRT32`–`PRT35`                                                        |
| `libs/input/src/sparkles/input/`                        | [input](./input.md) — `INP1`–`INP9`                                                                                                                              |
| `libs/ui-tui/src/`                                      | [backends](./backends.md) — `TGT6`                                                                                                                               |
| `libs/ui-raylib/src/`                                   | [backends](./backends.md) — `TGT6`                                                                                                                               |
| `libs/ui/src/sparkles/ui/overlay/anchor.d` _(planned)_  | [anchored overlays](./popup.md) — `ANC1`–`ANC9`                                                                                                                  |
| `libs/ui/src/sparkles/ui/overlay/place.d` _(planned)_   | [anchored overlays](./popup.md) — `PLC1`–`PLC15`                                                                                                                 |
| `libs/ui/src/sparkles/ui/overlay/arena.d` _(planned)_   | [anchored overlays](./popup.md) — `POP4`, `POP7`, `LYR1`–`LYR4`, `LYR9`, `LYR10`, `LYR12`                                                                        |
| `libs/ui/src/sparkles/ui/overlay/policy.d` _(planned)_  | [anchored overlays](./popup.md) — `TRG1`–`TRG5`, `DSM1`–`DSM6`, `DSM11`, `MDL2`, `MDL3`                                                                          |
| `libs/ui/src/sparkles/ui/overlay/package.d` _(planned)_ | [anchored overlays](./popup.md) — re-exports only                                                                                                                |

→ [Feature requirements](./feature-requirements.md) · [Principles](./principles.md) · [Layout](./layout.md) · [Widgets](./widgets.md)
