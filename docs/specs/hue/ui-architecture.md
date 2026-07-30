# `hue` UI architecture — building on `sparkles:ui`

_**Status:** partial · **Date:** 2026-07-29 · **Scope:** how hue consumes the
canvas-first UI toolkit — which of hue's visuals are widgets, which are still
hand-written per backend, and the port that closes the gap._

> [!IMPORTANT]
> **The library-level architecture has moved.** This page originally proposed a
> reusable component library; that library now exists as
> [`sparkles:ui`](../ui/index.md) and is specified in its own tree. The
> requirement areas that used to live here are now:
>
> | Was here | Now specified in                                |
> | -------- | ----------------------------------------------- |
> | `STM*`   | [ui/state-machines.md](../ui/state-machines.md) |
> | `LAY*`   | [ui/layout.md](../ui/layout.md)                 |
> | `WGT*`   | [ui/widgets.md](../ui/widgets.md)               |
> | `TGT*`   | [ui/backends.md](../ui/backends.md)             |
>
> Area mnemonics and numbering are preserved, so existing cross-references read
> the same. **This page keeps only hue's own consumption requirements (`UIA`).**

## Design & rationale

hue needs the same interactive visuals — scrollbars, headers, gutters, popups,
selection, code-block chrome, trees — across the raylib [GUI](./gui.md), the
[TUI](./tui.md), and [HTML](./feature-requirements.md). It currently implements
about thirty distinct visual components, of which **six** go through the toolkit;
the rest are written once per backend, and have measurably diverged: two
scrollbars with different thumb formulas scroll the same document differently,
and the copy affordance confirms success two different ways.

The resolution is not more shared helpers but the toolkit's contract: **hue
builds a widget tree and owns no rendering.** What remains in hue is argument
parsing, document loading, the syntax pipeline, input handling, and its views.

Two decisions shape the port beyond a mechanical rewrite:

- **hue has no rendering modes.** One behavior, three backend _flavors_. Content
  kinds compose the way tree-sitter injections compose grammars — a markdown
  document may embed a richer code block, and that block's documentation popups
  render through the same markdown view. That requires views to be re-entrant,
  which a flat line list cannot be. See [Transformer pipeline](./pipeline.md) and
  [`WGT2`](../ui/widgets.md).
- **A directory opens the [file explorer](./tree-view.md)**, not a bespoke index
  view; the static gallery becomes its HTML flavor.

## hue's consumption (`UIA`)

| ID   | Requirement                                                                                                                                                                                                  | Status                                                                                                                                                     | Traces to                                                                     |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| UIA1 | hue's interactive UI must be built on the **canvas-first toolkit** [`sparkles:ui`](../ui/index.md), across the GUI, TUI and HTML targets.                                                                    | partial                                                                                                                                                    | `sparkles:ui`; twoslash overlay in `gui.d`/`twoslash_tui.d`                   |
| UIA2 | hue must contain **no rendering code of its own** — no per-backend painters, no backend-specific chrome. Anything hue draws that the toolkit lacks is a missing widget, to be added there and consumed here. | full (`28ff3dfe`) — the markdown/twoslash/raw-source/explorer views and all chrome are toolkit trees; the popup signature is resolved spans (no overpaint) | [ui/widgets.md](../ui/widgets.md) `WGT7`+                                     |
| UIA3 | hue must not reach for native OS or HTML toolkit widgets on any target; every visual comes from toolkit primitives.                                                                                          | full                                                                                                                                                       | canvas-first contract                                                         |
| UIA4 | hue's existing **per-backend widgets must be ported** onto the toolkit — one definition, three targets — and their predecessors deleted in the same change, so no third copy is created.                     | partial — see the inventory (each swap deleted its predecessor); raw view + gutters pending                                                                | see the port inventory below                                                  |
| UIA5 | hue's frame-loop state must be a **single owned view-state value** driving the toolkit's state machines, replacing peer locals and mutating closures.                                                        | partial — the shared STMs replaced ad-hoc state; the `ViewerModel` Whole is open                                                                           | [ui/principles.md](../ui/principles.md) `PRN1`, `PRN7`                        |
| UIA6 | hue's views must be **re-entrant**, so any content kind can embed another at any depth and the same view serves both the top-level document and a nested one.                                                | full (`bc3e1f17`) — `viewMarkdownInto` / `viewTwoslashDocument` / fence sub-views / popup JSDoc, all re-entrant with a depth budget                        | [ui/widgets.md](../ui/widgets.md) `WGT2`; [pipeline.md](./pipeline.md) `XFM3` |

## Port inventory

The components hue implements per backend today, and the toolkit widget each
becomes. "Copies" counts the independent implementations being collapsed.

| hue component                         | Copies | Becomes                                                            | Status                                                                                                                  |
| ------------------------------------- | ------ | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| Popup / hover card / below-line block | 1      | shipped — the toolkit's popup and panel containers                 | full                                                                                                                    |
| Diagnostic squiggle, highlight tint   | 1      | shipped — stroked line, filled rect                                | full                                                                                                                    |
| Preview line painter                  | 3      | the document view over rich text                                   | full (`155ce512`) — the composable markdown view, all three sinks; the flattener deleted                                |
| Header / status bar                   | 6      | [`WGT17`](../ui/widgets.md)                                        | full — `headerBar` on every backend                                                                                     |
| Scrollbar                             | 2      | [`WGT10`](../ui/widgets.md) over [`STM2`](../ui/state-machines.md) | full — one `scrollbarThumb`/`draggedTo` formula                                                                         |
| Line-number gutter                    | 4      | [`WGT18`](../ui/widgets.md)                                        | partial — one derivation per view (`srcLineOf` over the identity channel in the GUI preview); the raw views keep theirs |
| Selection highlight                   | 3      | [`STM3`](../ui/state-machines.md)                                  | full (`23fab77e`) — `Selection`/`selectionRects` over the identity channel                                              |
| Table                                 | 1      | [`WGT11`](../ui/widgets.md) over the track sizer                   | full — the track sizer + source-anchored cell keys (2-D selection preserved)                                            |
| Code-block chrome ([`COD`](./gui.md)) | 1      | panel + gutter + button                                            | full — the fence panel + header band through the markdown view; in-panel line numbers are a recorded fidelity gap       |
| Copy button ([`COD3`](./gui.md))      | 2      | [`WGT15`](../ui/widgets.md) + [`STM6`](../ui/state-machines.md)    | full (`8b5949a8`) — the fence header band, source-anchored ids, one feedback behavior                                   |
| Text-input bar (search / goto)        | 2      | [`WGT14`](../ui/widgets.md)                                        | partial — TUI status-bar input is a widget bar; the GUI input line is still drawn directly                              |
| Toast                                 | 1      | [`WGT16`](../ui/widgets.md)                                        | partial — `Timeline`-driven, still painted directly in the GUI                                                          |
| Document index view                   | 2      | the [explorer](./tree-view.md) — [`WGT12`](../ui/widgets.md)       | partial (`d47a0d01`) — the TUI explorer; the GUI keeps its list                                                         |
| Theme picker list                     | 1      | [`WGT13`](../ui/widgets.md)                                        | full — live ←/→ theme cycling in both interactive backends (previewer.d deleted)                                        |
| Box / frame drawing                   | 3      | panel decoration, per-backend degradation                          | full — panel decorations through each canvas                                                                            |

> [!NOTE]
> The copy counts are the argument. A header bar written six times, twice within
> the same file, is not a styling problem — it is the absence of a shared
> definition, and every divergence between the copies is the interface reporting
> the same state two different ways.

## Milestones

| Milestone | Scope                                                                           | Status                      | Requirements                                            |
| --------- | ------------------------------------------------------------------------------- | --------------------------- | ------------------------------------------------------- |
| U0        | Research grounding (UI-layout catalog; the `sparkles:tui` render-core decision) | done (research)             | [`LAY2`](../ui/layout.md), [`TGT2`](../ui/backends.md)  |
| U1        | Level 1 — presentation-free state machines                                      | partial                     | [`STM*`](../ui/state-machines.md)                       |
| U2        | Level 2 — the layout model, decided and implemented                             | partial                     | [`LAY*`](../ui/layout.md)                               |
| U3        | Level 3 — the widget model + immediate / retained / SSG interpreters            | partial                     | [`WGT*`](../ui/widgets.md), [`TGT*`](../ui/backends.md) |
| U4        | Port hue's GUI/TUI/HTML widgets onto the toolkit                                | partial — see the inventory | `UIA4`                                                  |

The partial statuses are honest about what shipped: the layout model is decided
and a subset implemented; all three interpreters exist; but only the twoslash
overlay is expressed as widgets, one state machine exists and has no consumers,
and hue's own chrome is untouched. `U4` is the work this page tracks.

## Relationship to existing specs

| Piece                                                       | Role                                                                 |
| ----------------------------------------------------------- | -------------------------------------------------------------------- |
| [`sparkles:ui` spec tree](../ui/index.md)                   | the toolkit's own requirements — `STM`/`LAY`/`WGT`/`TGT`/`THM`/`INP` |
| [ui/migration.md](../ui/migration.md) `MIG6`–`MIG10`        | the sequencing of hue's port                                         |
| [gui.md](./gui.md) · [tui.md](./tui.md)                     | the per-backend requirements the port consolidates                   |
| [tree-view.md](./tree-view.md) · [folding.md](./folding.md) | components whose first implementation is the ported one              |
| [pipeline.md](./pipeline.md) `XFM3`                         | the re-entrancy `UIA6` requires                                      |

→ [GUI requirements](./gui.md) · [TUI requirements](./tui.md) · [`sparkles:ui`](../ui/index.md) · [Overview](./index.md)
