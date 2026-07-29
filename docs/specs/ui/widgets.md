# `sparkles:ui` widgets — Feature Requirements (`WGT`, `VMD`)

_**Status:** partial · **Date:** 2026-07-29 · **Scope:** the widget level — the
tree representation, props and identity, and the component catalog, split into
backend-independent **view models** (`VMD`) and **views** (`WGT`)._

## Design & rationale

### View model + view

The toolkit's components are split in two, and the split is the point:

- A **view model** is presentation-free. It owns the component's data and
  interaction state and answers questions about it. It has no idea how it is
  drawn, contains no colors or glyphs, and is testable with no canvas at all.
- A **view** is a pure function from a view model to a widget subtree. It owns
  the visual decisions — slots, glyphs, spacing — and nothing else.

This is what makes "same model, different UIs" true rather than aspirational, and
it is the pattern the [tree-view case
study](../../research/tui-libraries/tree-view-case-study.md) singles out as the
central design insight worth copying. That study also names the failure mode
precisely: mixing expand state, git status and diagnostic severity onto the data
node means the tree can only ever have one visual state, and the whole structure
becomes uncopyable.

The tree component is therefore the **exemplar** every other component follows:

| Layer       | Content                                                                         |
| ----------- | ------------------------------------------------------------------------------- |
| data        | flat node arena with index links — copy is one array duplication                |
| interaction | opened set, selection, scroll offset — keyed by identity, _not_ stored on nodes |
| view        | borrows both, owns glyphs and slots only                                        |

with the flatten step — hierarchy to a linear list of visible rows — as a **pure
free function**, not a method that also lazily loads children and applies
filters.

### Why the tree is not recursive

A recursive node type makes the structure an incidental one: ownership is
unclear, copying is a deep traversal, and every consumer writes its own walk. A
flat arena with index links is copyable as a value, cache-friendly, `@nogc`-able,
and lets a single traversal serve every algorithm.

## Widget tree (`WGT1`–`WGT6`)

| ID   | Requirement                                                                                                                                                                                                                               | Status      | Traces to                               |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------- |
| WGT1 | A widget tree must be a **flat arena** — one relocatable buffer of nodes, containers referencing children by explicit index list — not a class hierarchy or a recursive value.                                                            | full        | `widget.d` `Widget`, `WidgetTree`       |
| WGT2 | A view must be a **pure function** `view(model, ctx) → WidgetTree`, with no dependence on frame state, so it is **re-entrant**: any view may embed the output of another view at any depth.                                               | partial     | `widget.d` `Builder`                    |
| WGT3 | A widget's payload must be a **sum type** over the widget kinds, so only the fields meaningful for a kind exist, the compiler enforces exhaustive handling, and adding a kind cannot silently skip a backend.                             | not started | proposed `Widget` payload sum type      |
| WGT4 | Widget **props must be Regular** with total structural equality; handlers and other non-comparable payloads must be excluded from the compared value.                                                                                     | not started | [principles.md](./principles.md) `PRN6` |
| WGT5 | A widget may carry a **key**, and the renderer must maintain a store of per-element state addressed by key, so scroll offsets, focus and animation phase survive a rebuild. Element state lives in that store, never in the widget value. | not started | proposed key + element-state store      |
| WGT6 | Text must support **styled runs within a single node** — a sequence of (text, slot) spans — so syntax-highlighted content is expressible directly, without a backend overpainting the toolkit's own output to re-colour it.               | not started | proposed rich-text widget               |

> [!NOTE]
> `WGT5` deliberately separates two different relationships. **Equality** decides
> "may I skip repainting"; **identity** decides "is this the same element, so its
> state carries over". Conflating them is the classic reconciliation bug, and
> keeping element state out of the widget value is what keeps `WGT4`'s equality
> total.

## Component catalog (`WGT7`+)

Each row is a view model plus its view. Status reflects the toolkit, not any one
consumer.

| ID    | Component                                                                         | Status      | Notes                                                          |
| ----- | --------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------------- |
| WGT7  | **Containers** — row, column, stack, panel, popup                                 | full        | shipped                                                        |
| WGT8  | **Primitives** — box, text, glyph, line                                           | full        | shipped                                                        |
| WGT9  | **Scroll view** — clipped viewport with an offset                                 | not started | needs [`LAY7`](./layout.md)                                    |
| WGT10 | **Scrollbar** — track and thumb, hover/drag affordance                            | not started | view over [`STM2`](./state-machines.md)                        |
| WGT11 | **Table** — columns with alignment and spans, header, optional borders            | not started | view model over [`LAY9`](./layout.md)'s track sizer            |
| WGT12 | **Tree** — the exemplar; flat arena, opened set, guides, lazy children            | not started | see below                                                      |
| WGT13 | **List** — selectable rows, optional virtualization                               | not started | degenerate tree; shares the selection machine                  |
| WGT14 | **Text input** — caret, editing, submission                                       | not started | tier 1                                                         |
| WGT15 | **Button** — label, press state, activation                                       | not started | tier 1                                                         |
| WGT16 | **Toast / notification** — transient, timed or event-scoped                       | not started | view over [`STM6`](./state-machines.md)                        |
| WGT17 | **Header / status bar** — leading, centre and trailing segment groups             | not started | replaces per-backend chrome                                    |
| WGT18 | **Gutter** — line numbers, markers, fold indicators                               | not started | consumed by the document view                                  |
| WGT19 | **Meter / progress** — determinate and indeterminate                              | not started | indeterminate is a mode, not a sentinel value                  |
| WGT20 | **Divider / spacer**                                                              | not started | spacer is a `grow` box, per [`LAY8`](./layout.md)              |
| WGT21 | **Link** — activatable reference; hyperlink escape on capable terminals           | not started | needs a link concept in the visual vocabulary                  |
| WGT22 | **Image / media** — sized placeholder with per-target realisation                 | not started | degrades to alt text                                           |
| WGT23 | **Tabs** — tab bar plus one visible panel                                         | not started | tier 0 on HTML via checked-radio idiom                         |
| WGT24 | **Disclosure** — collapsible region with a placeholder                            | not started | tier 0 on HTML; shares [`STM5`](./state-machines.md)           |
| WGT25 | **Task list** — ordered items with status marks and a running/blocked distinction | not started | view model is presentation-free; its driver is not — see below |

> [!IMPORTANT]
> **The live region is not a widget, and must not become one.** It repaints the
> bottom of a scrolling terminal in place: it writes cursor-control escapes to a
> stream and owns output sequencing. That is a _line-oriented incremental output
> sink_, not a canvas — it has no rectangle, no clip and no frame. Putting it
> behind `isCanvas` would violate the canvas-first posture
> ([`UIA1`](./feature-requirements.md)) and force every backend to pretend it has
> a cursor.
>
> The split: a **task list's view model** (items, statuses, ordering) is
> presentation-free and belongs here as `WGT25`; the **live region and the
> reporter that drives it** stay a terminal concern owned by the cell backend's
> package. Spinner and progress _glyphs_ are theme data
> ([`THM`](./theme.md)); the meter/progress **view** is `WGT19`.

## Tree component (`VMD1`–`VMD6`)

The exemplar of the view-model/view split.

| ID   | Requirement                                                                                                                                                                                              | Status      | Traces to                                                                   |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------------------------------------------- |
| VMD1 | Tree **data** must be a flat node arena with parent/child/sibling indices, copyable as a value, holding no interaction state and no decoration.                                                          | not started | proposed tree data model                                                    |
| VMD2 | Tree **interaction state** — opened set, selection, scroll offset — must live in a separate value keyed by node **identity** (a path of identifiers), so one tree can back several independent views.    | not started | proposed tree state                                                         |
| VMD3 | **Flatten** must be a pure free function `(data, state) → range of (depth, node, isLastChild)`, with no lazy loading and no filtering mixed in. It must be testable in isolation.                        | not started | proposed `flatten`                                                          |
| VMD4 | Guide characters must follow the **four-state model** — space, continue, fork, end — accumulated per depth level, with the per-depth state precomputed during flatten rather than recomputed per render. | not started | proposed guide computation                                                  |
| VMD5 | Lazy children must separate **user intent** ("this should be open") from **loaded state** ("children have been read"), so the tree knows what should be expanded before it has read it.                  | not started | proposed lazy provider                                                      |
| VMD6 | Node capabilities — has children, has an icon, has a status badge — must be detected by **introspection**, so a filesystem tree and a syntax-tree share one renderer without a type hierarchy.           | not started | [DbI guidelines](../../guidelines/design-by-introspection-01-guidelines.md) |

> [!NOTE]
> An alternative traversal mode, where the visible tree is rebuilt as a function
> of `(source, filter, depth limit)` with no persistent expand state, is the
> natural fit for live filtering and **coexists** with `VMD2` rather than
> replacing it. Flat storage is what makes rebuilding per keystroke viable.

## Milestones

| Milestone | Scope                                                             | Status      | Requirements                     |
| --------- | ----------------------------------------------------------------- | ----------- | -------------------------------- |
| W0        | Sum-typed payload, Regular props, keys and element state          | not started | `WGT3`–`WGT5`                    |
| W1        | Styled-run text; hit identity through the pipeline                | not started | `WGT6`                           |
| W2        | Chrome components — scroll view, scrollbar, header/status, gutter | not started | `WGT9`–`WGT10`, `WGT17`–`WGT18`  |
| W3        | Content components — table, list, rich text                       | not started | `WGT11`, `WGT13`                 |
| W4        | Tree component per the case study                                 | not started | `WGT12`, `VMD1`–`VMD6`           |
| W5        | Interactive components — input, button, tabs, disclosure, toast   | not started | `WGT14`–`WGT16`, `WGT23`–`WGT24` |
| W6        | Media and links                                                   | not started | `WGT21`, `WGT22`                 |

## Module coverage

| Source file                           | Requirements                  |
| ------------------------------------- | ----------------------------- |
| `libs/ui/src/sparkles/ui/widget.d`    | `WGT1`–`WGT8`                 |
| `libs/ui/src/sparkles/ui/components/` | `WGT9`–`WGT24`, `VMD1`–`VMD6` |
| `libs/ui/src/sparkles/ui/state.d`     | `WGT5` (element-state store)  |

## Relationship to existing specs

| Piece                                                                        | Role                                                      |
| ---------------------------------------------------------------------------- | --------------------------------------------------------- |
| [Tree-view case study](../../research/tui-libraries/tree-view-case-study.md) | the design record behind `VMD1`–`VMD6`                    |
| [layout.md](./layout.md) `LAY`                                               | the sizing, clipping and track facilities components need |
| [state-machines.md](./state-machines.md) `STM`                               | the behavior half of every interactive component          |
| [theme.md](./theme.md) `THM2`                                                | the widened slot vocabulary the catalog requires          |
| [input.md](./input.md) `INP5`                                                | the tier a component declares                             |

→ [Overview](./index.md) · [Layout](./layout.md) · [State machines](./state-machines.md) · [Theme](./theme.md)
