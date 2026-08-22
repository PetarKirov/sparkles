# Comparison — what four seams did, and what it means for `isCanvas`

**Last reviewed:** August 22, 2026.
**Coverage:** 4 of 11 planned subjects surveyed — Slint, Qt, Notcurses, egui.
The remaining seven are listed in the [umbrella](./index.md) and are **not**
represented below; where this document says "every subject", it means every subject
_surveyed_.

The four were chosen to bound the space rather than to be representative:
Slint spans the widest target range, Qt is the declared-capability model,
Notcurses is a cell target that addresses below the cell, and egui is the
geometry extreme. Conclusions that hold across all four are reported as
findings; where they disagree, the disagreement is the finding.

## The matrix

| Question                            | Slint                                             | Qt `QPaintEngine`                        | Notcurses                            | egui / epaint                         |
| ----------------------------------- | ------------------------------------------------- | ---------------------------------------- | ------------------------------------ | ------------------------------------- |
| **Q1** unit / who measures          | separate `TextShaper`; `Font::Length` assoc. type | `QFontMetrics`, not the engine           | grapheme width, above the blitter    | none — backend gets a shaped `Galley` |
| **Q2** contract stated?             | trait + defaults; no query                        | **`PaintEngineFeature` + `hasFeature`**  | runtime terminfo query; auto-degrade | nothing to negotiate                  |
| **Q3** semantic or primitive        | **semantic** (8 ops incl. `draw_box_shadow`)      | primitive (rects, paths, `drawTextItem`) | primitive over planes                | primitive (12 `Shape` variants)       |
| **Q4** command shape                | virtual dispatch, no reified command              | virtual dispatch, no reified command     | direct plane calls                   | **sum type** (`enum Shape`)           |
| **Q5** sub-unit placement           | continuous floats                                 | continuous floats                        | **blitter = a fidelity ladder**      | continuous floats                     |
| **Q6** resolved or semantic styling | resolved; role in the method name                 | resolved (`QPainterState`)               | resolved per cell                    | resolved by tessellation              |
| **Q7** payload ownership            | borrowed + backend-owned `ItemCache`              | borrowed; `QPixmap` implicitly shared    | plane owns its cells                 | **`Arc`-shared** `Mesh` / `Galley`    |
| **Q8** extent query                 | clip bounds only                                  | the **device** declares extent           | the **plane** declares extent        | falls out of primitives               |

## Findings

### F1. Text measurement does not belong on the painter — unanimous

All four put it elsewhere, by four different routes: a separate shaping trait
with a backend-chosen length type (Slint), a parallel metrics class (Qt), a
property resolved above the blitter (Notcurses), and total pre-resolution into
a `Galley` before a backend exists (egui).

Two of them are not GPU toolkits, so this is not an artifact of our unusual
terminal/GPU spread. It is simply the ordinary answer, and
[friction §1](../../specs/ui-skia/canvas-seam-friction.md) is not a close call:
`measure` on `isCanvas` is the design error, and it is why `SkiaCanvas.measure`
has to ignore Skia and return `cellsOf(text)`.

### F2. Reifying the command stream is ours to keep — but not as a tagged struct

Slint, Qt and Notcurses all dispatch through methods and have no command
values. egui alone reifies, as a **sum type**, and gets exactly the properties
we depend on: shapes are values, so they can be collected, culled, replayed and
compared.

That is the whole justification for `RecordingCanvas` and the op-stream parity
harness, so the reification is right. What egui does not do is our tag-plus-
eighteen-fields encoding — which is also the encoding `sparkles.input.events`
opens by rejecting for its own `Event`. Friction §4 stands, and the fix is a
`SumType`, not the removal of `DrawOp`.

### F3. Semantic operations are legitimate — the axis is _where degradation lives_

Friction §3 called `scrollbar` in the drawing seam a layering violation. Slint
disproves the general claim: it ships eight semantic operations including
`draw_box_shadow` and `draw_text_input`, for exactly our reason — a backend
that cannot render the real thing must know what was intended in order to
degrade it.

The useful axis is not semantic-vs-primitive but **who degrades**:

- **In the backend** — Slint. The seam is semantic, and each backend decides.
- **In the framework** — Qt. `QPainter` _emulates_ a missing feature and hands
  the engine an image of the result. The fallback exists once.

`sparkles:ui` is currently in the first camp without having chosen it, and pays
Qt's price anyway: `DrawOp` carries eight scrollbar fields so that every
backend can re-derive the same rail geometry, when `scrollbarThumb` already
computes it once.

### F4. Optional capabilities need a stated floor and a refusable degrade

Qt separates capabilities the framework can emulate from two (`AlphaBlend`,
`PorterDuff`) that it cannot — a floor. Notcurses degrades automatically **and**
lets a caller pass `NCVISUAL_OPTION_NODEGRADE` to get a failure instead.

`sparkles:ui` has neither. `rule`, `scrollbar` and the clip pair are one
undifferentiated "optional" bucket, discovered by `__traits(compiles)` at call
sites, and there is no way to ask for a hairline and be told no — which is
precisely what a golden test wants. Friction §2 is confirmed, and the fix has
two halves rather than one.

### F5. Continuous coordinates dissolve §5 — and Notcurses shows the alternative

Three of four have no sub-unit problem because their coordinates are floats.
`RuleEdge` is a symptom of integer cell coordinates, not of a missing
enumerator, and enumerating positions will keep costing enumerators.

Notcurses is the one subject that faces our constraint, and its answer
generalises: **name a fidelity, not a position.** A seam that says "hairline
fidelity within this rect" lets a pixel backend spend one device pixel, a cell
backend fill a cell, and a sextant-capable terminal land in between — with the
toolkit naming no positions at all.

### F6. Payload ownership: share it, do not borrow it

Nobody borrows a payload that must outlive the frame. Qt's `QPixmap` and egui's
`Mesh`/`Galley` are reference-counted; Slint adds a **backend-owned cache**
(`draw_cached_pixmap`) so the party that knows a payload's lifetime owns it.

Friction §7 stands, and there are two cheaper answers than the interning the
pre-pivot plan assumed: reference-counting, or a backend-owned cache keyed by
identity.

### F7. Extent belongs to the surface, not the scene

Qt's paint _device_ declares width and height; a Notcurses plane declares its
own. Only egui derives extent from primitives, which is what
`skia-canvas-render.d` had to do.

This inverts friction §8: a backend allocating a surface generally knows the
size because it chose it. The real gap is narrower — an _offscreen_ consumer
that wants to size a surface to content — and is better served by a layout
query than by making the display list self-describing.

## What this does not settle

The umbrella's open question stands: **whether the terminal and GPU targets
should share one seam at all.** Nothing here decides it. Slint is the
encouraging data point — one `ItemRenderer` really does span an MCU software
renderer and Skia — but its range is "small GPU to large GPU", not "character
cells to shaped glyphs". No surveyed subject spans what we span, and egui shows
what happens when a design optimises for one end: it becomes structurally
unable to reach the other.

The seven unsurveyed subjects most likely to move this are **GTK4/GSK**
(semantic retained nodes across Vulkan/GL/Cairo renderers) and **Flutter**
(a deliberately narrow `dart:ui` under a very wide widget layer).

## Recommended shape, on this evidence

Stated as input to a proposal in `docs/specs/ui/`, not as a decision:

1. **Move `measure` off the canvas** into a font/metrics abstraction with a
   backend-chosen unit (F1). Highest confidence; unanimous.
2. **Re-encode `DrawOp` as a sum type**, keeping the reified stream (F2).
3. **Decide where degradation lives** and say so, rather than inheriting
   Slint's answer by accident while paying Qt's cost (F3).
4. **Split optional capabilities into a floor and a negotiable set, and make
   degradation refusable** (F4).
5. **Replace `RuleEdge` with a fidelity** rather than more positions (F5).
6. **Share payloads by reference count or a backend-owned cache** rather than
   borrowing or interning (F6).
7. **Leave extent to the surface**; add a layout query for the offscreen case
   (F7).

Every one of these keeps the four properties the friction log recorded as
working — structural typing with attribute inference, cell-space layout,
`RecordingCanvas` as reference and test seam, and the optional-primitive
bargain.
