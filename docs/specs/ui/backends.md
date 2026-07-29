# `sparkles:ui` backends — Feature Requirements (`TGT`)

_**Status:** partial · **Date:** 2026-07-29 · **Scope:** the `isCanvas` seam, the
shipped render targets, per-target declared capabilities, and the rules that keep
additional backends droppable-in._

## Design & rationale

A backend supplies **draw primitives and input events, and nothing else.** Every
decision above that — what to draw, where, in what colour — belongs to the
toolkit. The contract is a capability concept checked structurally, not an
interface: attributes infer correctly, there is no dispatch cost, and a backend
need not inherit anything to qualify.

Backends genuinely differ in what they can render, and the honest response is to
**declare** those differences rather than document them in prose and hope. A
cell grid cannot draw a corner radius; a fixed-size bitmap font cannot honour a
font scale; static HTML cannot express a drag. Each of those is a capability, and
a target that cannot serve one should say so where the toolkit can act on it.

## The canvas seam (`TGT1`–`TGT2`)

| ID   | Requirement                                                                                                                                                                                                                                 | Status  | Traces to                             |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ------------------------------------- |
| TGT1 | A canvas must satisfy a **structural capability concept** providing exactly: filled rectangle, text run, single glyph, stroked line, and text measurement. Attributes must be left to infer so a backend needing `@system` still qualifies. | full    | `canvas.d` `isCanvas`                 |
| TGT2 | The display list must carry, per operation, both the **semantic slot** and the **resolved appearance**, plus the clip state, so a backend never needs to consult the theme or the widget tree.                                              | partial | `canvas.d` `DrawOp`; `display_list.d` |

## Shipped targets (`TGT3`–`TGT6`)

| ID   | Requirement                                                                                                                                                                                         | Status                        | Traces to                                                                        |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------- | -------------------------------------------------------------------------------- |
| TGT3 | An **immediate** interpreter must walk the display list and issue draw calls per frame.                                                                                                             | full                          | `interp/immediate.d`                                                             |
| TGT4 | An **HTML** target must serialize the tree to markup and CSS, with semantic class names and an external stylesheet, and must express tier-0 interactivity in **pure CSS** with no script.           | partial                       | `interp/html.d`                                                                  |
| TGT5 | Every target must **declare its capabilities** — which chrome features it honours and which input tiers it serves — as data the toolkit can inspect, so degradation is reported rather than silent. | not started                   | proposed capability declaration                                                  |
| TGT6 | Concrete canvases must live in **sibling packages** (`sparkles:ui-tui`, `sparkles:ui-raylib`), so the toolkit stays backend-free and a consumer links only what it uses.                            | full (`2c8356e1`, `6b0c9714`) | `libs/ui-tui` (`GridCanvas`), `libs/ui-raylib` (`RaylibCanvas` + `RaylibEvents`) |

## Current degradations

Honest inventory, to become `TGT5` declarations:

| Feature                   | Cell target                     | GPU target                     | HTML target                 |
| ------------------------- | ------------------------------- | ------------------------------ | --------------------------- |
| corner radius             | dropped (box-drawing corners)   | approximated                   | native                      |
| drop shadow               | dropped                         | approximated                   | native                      |
| single-side accent border | dropped                         | native                         | native                      |
| dashed / dotted stroke    | approximated by underline style | approximated                   | native                      |
| wavy underline            | curly underline where supported | drawn                          | native                      |
| font role / scale         | n/a (single cell metric)        | **dropped** (single-size font) | native                      |
| sub-cell positioning      | n/a                             | available                      | native                      |
| tier-1 input              | served                          | served                         | **unavailable** (no script) |

## Forward compatibility (`TGT7`–`TGT9`)

An additional GPU backend (for example a Skia-class renderer) must drop in beside
the existing ones **without editing `sparkles:ui`**. That holds only if:

| ID   | Requirement                                                                                                                                                                                                                                    | Status  | Traces to                        |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | -------------------------------- |
| TGT7 | No backend-specific concept — atlas management, a font-set type, a backend's own style bit layout — may appear in the toolkit's vocabulary.                                                                                                    | full    | `canvas.d`; `style.d`            |
| TGT8 | The visual vocabulary must express **intent**, not any one backend's workarounds. Radius, shadow and dash style stay first-class even while a backend fakes them by hand; a richer backend renders them natively.                              | full    | `style.d` `Decoration`, `Shadow` |
| TGT9 | The **cells→device mapping belongs to the canvas**. Layout stays integer-cell ([`LAY3`](./layout.md)); a pixel backend may position sub-pixel. Font role and scale must be retained in the vocabulary even where a current backend drops them. | partial | canvas scale factors; `style.d`  |

## Parity harness

| ID    | Requirement                                                                                                                                                                                    | Status  | Traces to                          |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ---------------------------------- |
| TGT10 | The same widget tree must be renderable through **every** target in a test, with the HTML target usable as a browser ground-truth oracle and a recording canvas as the GL-free assertion seam. | partial | `RecordingCanvas`; `interp/html.d` |
| TGT11 | Where a target's appearance mirrors a stylesheet, the values must be asserted **in lockstep** so drift fails the build.                                                                        | full    | twoslash CSS lockstep tests        |

## Milestones

| Milestone | Scope                                                      | Status                        | Requirements |
| --------- | ---------------------------------------------------------- | ----------------------------- | ------------ |
| B0        | Adapter packages extracted from their current consumer     | full (`2c8356e1`, `6b0c9714`) | `TGT6`       |
| B1        | Clip state carried through the display list                | not started                   | `TGT2`       |
| B2        | HTML target: semantic classes, stylesheet, pure-CSS tier 0 | not started                   | `TGT4`       |
| B3        | Declared capabilities, with reported degradation           | not started                   | `TGT5`       |
| B4        | Parity harness across every target                         | partial                       | `TGT10`      |

## Module coverage

| Source file                                  | Requirements           |
| -------------------------------------------- | ---------------------- |
| `libs/ui/src/sparkles/ui/canvas.d`           | `TGT1`, `TGT2`, `TGT7` |
| `libs/ui/src/sparkles/ui/display_list.d`     | `TGT2`                 |
| `libs/ui/src/sparkles/ui/interp/immediate.d` | `TGT3`                 |
| `libs/ui/src/sparkles/ui/interp/html.d`      | `TGT4`, `TGT10`        |
| `libs/ui-tui/src/`                           | `TGT5`, `TGT6`         |
| `libs/ui-raylib/src/`                        | `TGT5`, `TGT6`, `TGT9` |

## Relationship to existing specs

| Piece                                   | Role                                                         |
| --------------------------------------- | ------------------------------------------------------------ |
| [layout.md](./layout.md) `LAY3`, `LAY5` | the integer-unit rule and the injected measurement primitive |
| [input.md](./input.md) `INP6`–`INP9`    | the input half of a target's capabilities and its adapters   |
| [theme.md](./theme.md) `THM3`           | the resolved appearance a canvas consumes                    |
| `sparkles:tui`, `sparkles:raylib-text`  | the drawing substrates the adapters wrap                     |

→ [Overview](./index.md) · [Layout](./layout.md) · [Input](./input.md)
