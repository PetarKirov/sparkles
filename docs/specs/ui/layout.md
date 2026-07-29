# `sparkles:ui` layout — Feature Requirements (`LAY`)

_**Status:** decided · **Date:** 2026-07-29 · **Scope:** the layout level of
`sparkles:ui` — the model, its units, the measure protocol, the sizing
vocabulary, clipping and scroll, alignment, track sizing and text wrapping.
This page is the **decision record** the [UI-layout research
catalog](../../research/ui-layout/index.md) was gathered to settle._

> [!IMPORTANT]
> The catalog deliberately states no verdict — its index notes that a
> comparison page "may be added here as the catalog matures". **This page is
> that verdict.** Requirements below cite the catalog as evidence; the choices
> are made here.

## Design & rationale

### The verdict

**Keep the box-flow engine; add an orientation-aware measure protocol and a clip
primitive; keep every unit an integer.**

The existing two-pass engine (bottom-up intrinsic _measure_, top-down _place_)
is already the family the survey recommends. What it lacks is not a different
algorithm but three specific capabilities: a measure pass that knows the
available width, flexible sizing that distributes leftover space, and clipping.

### The surveyed families

| Family                          | Representatives              | Verdict                                                                                                                                                                     |
| ------------------------------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Box-flow, two-pass per axis** | Clay                         | **Adopted.** Already our shape; O(n); allocation-free; its `fit`/`grow`/`fixed`/`percent` + min/max vocabulary is the catalog's first taxonomy row verbatim.                |
| Flexbox                         | Yoga, Taffy, Stretch, CSS    | **Vocabulary adopted, algorithm rejected.** A faithful implementation is 5–10 KLoC, and float coordinates are a documented terminal bug class (off-by-one cells on resize). |
| Constraints down, sizes up      | Flutter, Compose, SwiftUI    | **Measure protocol adopted, engine rejected.** Its intrinsics idea is what we need; adopting it wholesale would delete the bottom-up pass that `grow` sizing requires.      |
| Constraint solvers              | Cassowary, Kiwi, Auto Layout | **Rejected.** Thousands of lines of meticulous code, notoriously poor debuggability; the catalog's own conclusion is that for tree-shaped terminal UIs box-flow is right.   |
| Classic retained two-pass       | WPF, Qt, GTK, Swing/MiG, Tk  | **One idea adopted:** GTK's orientation-aware `measure(orientation, for_size)`, which the catalog calls rare among widget toolkits. Star sizing informs the track sizer.    |
| Immediate-mode                  | Dear ImGui, egui             | **Rejected as a model** (cursor-based layout fights responsive design), but egui's orthogonal alignment toggles inform `LAY8`.                                              |
| Tiling window managers          | i3/sway, xmonad              | **Two ideas adopted:** proportional sizing as the default for content areas, and an introspectable serialized tree as a debugging tool (`LAY12`).                           |
| Line breaking                   | Knuth–Plass                  | **Optional strategy, not architecture** — see `LAY10`.                                                                                                                      |

### Why the measure signature is the crux

Today's `measure` takes no width, so a node cannot size against the space it
will actually get. That single gap is why text wrapping was hoisted _out_ of
layout and into the view, against a hardcoded column limit. The width↔layout
cycle ("wrapping needs a width; the width comes from layout") must be broken by
**ordering**, not iteration: measure the main axis, allocate a width, then
measure the cross axis _parameterised by that width_, at which point a text node
runs its line breaker. That is GTK's protocol, and Flutter's `minIntrinsicHeight(width)`
is the same idea under another name.

### Why integers, everywhere

Two independent catalog entries report float-derived off-by-one cell errors as a
recurring, shipped bug class in terminal backends. Because we hand-write the
engine, the whole class is avoidable by never admitting a float: leftover space
is distributed with `divmod` plus explicit remainder assignment, so the parts sum
exactly to the whole at every width. Sub-pixel positioning remains available to
pixel backends, which own the cells→device mapping (`LAY3`).

## Layout model & units (`LAY1`–`LAY3`)

| ID   | Requirement                                                                                                                                                                                                                                                            | Status            | Traces to                                                                 |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------------- |
| LAY1 | Layout must turn a widget tree into one **`Frame` per node** — an absolute rectangle — via alternating bottom-up _measure_ and top-down _allocate_ passes (per axis, so four in total under `LAY4`), all `@safe pure nothrow`, in `O(n)` over the node count.          | full (`aa35bc26`) | `layout.d` `layout` — `naturalWidth`/`allocWidth`/`naturalHeight`/`place` |
| LAY2 | The layout model must be **box-flow** (the Clay family), selected from the [UI-layout catalog](../../research/ui-layout/index.md); the flexbox _vocabulary_ is adopted without the flexbox _algorithm_, and no constraint solver is used.                              | full (this page)  | catalog verdict above; `layout.d` header                                  |
| LAY3 | Every coordinate and extent in the engine must be an **integer in abstract cells**. No floating-point value may enter layout. Mapping cells to device units (pixels, CSS lengths) is the **canvas's** responsibility, so a pixel backend may still position sub-pixel. | full (`aa35bc26`) | `geometry.d` `Point`/`Size`; canvas `cellW`/`cellH`                       |

## Measure protocol (`LAY4`–`LAY5`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                      | Status            | Traces to                                                                                                                                        |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| LAY4 | `measure` must be **orientation-aware and parameterised by the other axis** — `measure(axis, forSize)` — so a node's extent on one axis may depend on its allocated extent on the other. The root receives the viewport. This is what resolves content-dependent sizing (text wrapping, height-for-width) **by ordering rather than iteration**. | full (`aa35bc26`) | `layout.d` — four passes: natural width → width allocation → height-for-width → height allocation + place                                        |
| LAY5 | Text measurement must be **injected through the canvas**, not hardcoded in the engine, and must be grapheme-correct (wide and combining characters counted properly). The measurer receives a candidate width so it can report wrapped extent; it must be assumed hot and cached.                                                                | partial           | `layout.d` `isTextMeasure`/`CellMeasure` (the seam, `aa35bc26`); wiring each backend's grapheme-aware measurer through it is the M7 backend work |

> [!NOTE]
> The engine now measures through an injected `isTextMeasure` value (defaulting
> to `CellMeasure`, one column per codepoint), so the seam exists — but no
> backend passes its grapheme-aware measurer yet, and `canvas.measure` still has
> no caller. Until M7 wires it, wide characters overflow their boxes on the TUI.

## Sizing (`LAY6`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                         | Status            | Traces to                                            |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ---------------------------------------------------- |
| LAY6 | The sizing vocabulary is **`fit` / `grow` / `fixed` / `percent`** with `min`/`max` clamps. `percent` is a fraction of the parent's **content** size. `grow` siblings share leftover space by weight; distribution must be **integer-exact** — `q = leftover / weight; r = leftover % weight`, with the `r` extra cells handed to the first `r` growers in order — so the parts sum exactly to the whole. On overflow, children shrink toward `min`. | full (`aa35bc26`) | `geometry.d` `SizeSpec`; `layout.d` `distributeMain` |

> [!NOTE]
> Overflow reclaim is proportional to each child's slack above `min` (integer
> divmod again) and is **skipped on a clipped axis** — a viewport's content is
> meant to overflow (`LAY7`), so it scrolls instead of being crushed.

## Clipping, scroll & viewport (`LAY7`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                           | Status            | Traces to                                                                                                                                              |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| LAY7 | A container must be able to **clip and scroll** its subtree: a per-node clip (per axis) plus a child offset, which `place` subtracts from child origins and which emits scissor push/pop operations around the subtree in the display list. Scroll _offset_ is interaction state and lives in a state machine, not in the widget arena. It must map to `overflow` on the HTML target. | full (`9952b61c`) | `Widget.clipX`/`clipY`/`childOffset`; `display_list` `pushClip`/`popClip` + culling; `CellGrid`/hue `GridCanvas` clip stacks; `interp/html` `overflow` |

## Alignment (`LAY8`)

| ID   | Requirement                                                                                                                                                                                                                                                                            | Status            | Traces to                                                                             |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------------------------- |
| LAY8 | Containers must support **one alignment value per axis**, offsetting each child within its allocated band. Distribution effects (`space-between` and friends) are produced by inserting `grow` spacer children, not by a separate property. Cross-axis stretch stays a per-child flag. | full (`cf0131e4`) | `Widget.alignX`/`alignY` (`Alignment`); `interp/html` `align-items`/`justify-content` |

## Track sizing (`LAY9`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                      | Status  | Traces to                                                                                                              |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------- | ---------------------------------------------------------------------------------------------------------------------- |
| LAY9 | Tabular layout must be served by a **one-dimensional track sizer** — per track `auto` / `fixed(n)` / `fr(w)` / `minmax(a,b)`, resolved as "measure `auto` tracks, subtract fixed and gaps, divide the remainder among `fr` by weight with remainder distribution" — with cell spans. It must emit `grid-template-columns` on the HTML target. Row extents come from `LAY4`'s cross-axis measure. | partial | the sizer + spans + `grid-template-columns` emission shipped (`a9f7698e`, `tracks.d`); the table view adopts it in M3c |

## Text wrapping (`LAY10`)

| ID    | Requirement                                                                                                                                                                                                                                                                                        | Status            | Traces to                                                                                                                                                                                                                                                             |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| LAY10 | Line breaking must sit behind a **strategy seam** — greedy by default, with a balanced (rigid-glue Knuth–Plass) variant selectable — invoked from the cross-axis measure with the allocated width. Hang indent is expressed as a first-line width delta. No wrap width may be hardcoded in a view. | full (`407bce58`) | `sparkles.ui.wrap` (`TextWrap` greedy/balanced + `wrapSpans` for styled runs, hang indent), invoked from the height-for-width pass. The twoslash docs packer is deleted — its 56 columns survive only as a `Widget.width.max` style metric the _engine_ wraps against |

> [!NOTE]
> Knuth–Plass is deliberately _not_ architecture. The catalog notes it degenerates
> to greedy at table-cell widths and that a monospace grid has no stretchable
> glue, so ragged-right greedy is the natural default; the balanced variant is a
> quality upgrade for full-width prose, selectable per call.

## Ergonomics (`LAY11`–`LAY13`)

| ID    | Requirement                                                                                                                                                                                                       | Status            | Traces to                                                                                 |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ----------------------------------------------------------------------------------------- |
| LAY11 | Nodes must support **tri-state visibility** — visible / hidden (occupies space) / collapsed (removed from flow) — so chrome can toggle without a layout jump. It maps to `visibility` and `display:none` on HTML. | full (`cf0131e4`) | `Widget.visibility` (`Visibility`); `layout.d` collapsed-skip; `display_list` hidden-skip |
| LAY12 | The laid-out tree must be **introspectable** — serializable to a readable form (nodes, kinds, slots, resolved rects) for debugging, via the existing pretty-printing machinery.                                   | full (`cf0131e4`) | `layout.d` `dumpTree`                                                                     |
| LAY13 | Measured extents should be **cached** keyed on `(node, axis, forSize)`, before any dirty-tracking or incremental-relayout mechanism is considered.                                                                | not started       | proposed measure cache                                                                    |

## Explicitly out of scope

Each exclusion is a decision with evidence, recorded so it is not silently
revisited:

| Not implemented                        | Why                                                                                                                                                                                                                                                                          |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`margin`**                           | Clay has shipped for years without it; Flutter deliberately replaced it with gutter widgets; CSS margin collapsing is the most surprising part of normal flow. `gap` + `padding` cover our cases. The currently-inert `Widget.margin` field is **deleted**, not left unread. |
| **Constraint solvers**                 | Implementation cost and debuggability; the catalog concludes box-flow is the right tool where layout maps onto a tree, which ours does.                                                                                                                                      |
| **Full CSS Grid**                      | The auto-placement and staged track-resolution algorithms run to pages of normative prose; essentially only browser-grade engines implement it. `LAY9` ships the useful subset and _emits_ grid CSS.                                                                         |
| **`flex-wrap` / box wrapping**         | Absent from Clay, Tk and ConstraintLayout alike. Our _text_ wraps; our _boxes_ do not need to. Text wrapping is not flex wrapping.                                                                                                                                           |
| **The full flexbox alignment matrix**  | `justify-content` × `align-items` × `align-content` × `flex-wrap` produces surprising combinations; one value per axis plus spacers covers the same ground.                                                                                                                  |
| **Baseline alignment on cell targets** | Irrelevant on a fixed grid — all cell text shares a baseline. Revisit only if a pixel backend grows mixed font sizes.                                                                                                                                                        |
| **Eager intrinsic-width queries**      | Documented as expensive by the toolkits that offer them, and catastrophic inside large columns. `LAY4`'s `forSize` obtains the same answers within the normal pass.                                                                                                          |
| **Floating-point coordinates**         | Two independent catalog entries report float-derived off-by-one cell drift as a shipped bug class in terminal backends.                                                                                                                                                      |
| **Lazy off-screen materialisation**    | Genuinely valuable at very large item counts, but a second-order optimisation on top of `LAY7`. Measure before building it.                                                                                                                                                  |

## Milestones

| Milestone | Scope                                                                  | Status                                                    | Requirements             |
| --------- | ---------------------------------------------------------------------- | --------------------------------------------------------- | ------------------------ |
| L0        | Decision record (this page) — model, units, exclusions                 | decided                                                   | `LAY2`, `LAY3`           |
| L1        | Orientation-aware measure + injected grapheme-correct text measurement | partial (`aa35bc26`; M7 wires the backend measurers)      | `LAY4`, `LAY5`           |
| L2        | Integer-exact `grow`/`percent` distribution                            | full (`aa35bc26`)                                         | `LAY6`                   |
| L3        | Clip, child offset and scissor emission                                | full (`9952b61c`)                                         | `LAY7`                   |
| L4        | Alignment, tri-state visibility, tree dump; delete `margin`            | full (`cf0131e4`; margin deleted in `aa35bc26`)           | `LAY8`, `LAY11`, `LAY12` |
| L5        | Track sizer + wrapping strategy seam                                   | partial (`fcd2464a`, `a9f7698e`; view adoption in M3c/M6) | `LAY9`, `LAY10`          |
| L6        | Measure caching (and dirty relayout only if measurement demands it)    | not started                                               | `LAY13`                  |

## Module coverage

| Source file                              | Requirements                                                                                                                                                           |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `libs/ui/src/sparkles/ui/layout.d`       | `LAY1`, `LAY2`, `LAY4`–`LAY8`, `LAY11`, `LAY12`, `LAY13`                                                                                                               |
| `libs/ui/src/sparkles/ui/geometry.d`     | `LAY3`, `LAY6` (`SizeSpec`); `Rect.intersection` behind `LAY7`                                                                                                         |
| `libs/ui/src/sparkles/ui/wrap.d`         | `LAY10` (`TextWrap`, greedy + balanced; landed here rather than the once-proposed `base.text.wrap` — the measurer is caller-supplied, so the breaker is the toolkit's) |
| `libs/ui/src/sparkles/ui/tracks.d`       | `LAY9` (`TrackSpec`, `resolveTracks`, `applySpans`, `writeGridTemplate`)                                                                                               |
| `libs/ui/src/sparkles/ui/canvas.d`       | `LAY5` (the `measure` primitive); `pushClip`/`popClip` ops (`LAY7`)                                                                                                    |
| `libs/ui/src/sparkles/ui/display_list.d` | `LAY7` (scissor emission + culling)                                                                                                                                    |

## Relationship to existing specs

| Piece                                                  | Role in layout                                                           |
| ------------------------------------------------------ | ------------------------------------------------------------------------ |
| [UI-layout catalog](../../research/ui-layout/index.md) | the evidence base this page decides from (`LAY2`)                        |
| [backends.md](./backends.md) `TGT`                     | the cells→device mapping (`LAY3`) and the `measure` primitive (`LAY5`)   |
| [widgets.md](./widgets.md) `WGT`                       | the tree layout consumes; the table/scroll widgets driving `LAY7`/`LAY9` |
| [state-machines.md](./state-machines.md) `STM`         | scroll offset, which `LAY7` reads but does not own                       |
| `sparkles.base.text` (`wrap`, `grapheme`)              | the wrapping and width primitives behind `LAY5`/`LAY10`                  |

→ [Overview](./index.md) · [Widgets](./widgets.md) · [Backends](./backends.md) · [Principles](./principles.md)
