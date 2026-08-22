# `isCanvas` under load: friction found implementing a Skia backend

**Status:** evidence, not a proposal. **Date:** 2026-08-22.
**Collected by:** writing `SkiaCanvas` (M7/T4) against the seam as it stands.

A stated reason for adding a Skia backend was to pressure-test `isCanvas`, on the
suspicion that it is far from ideal. This is what the pressure actually found —
recorded while implementing, so the proposal that follows argues from friction
rather than from taste.

Each entry says what happened, not what should replace it. Ordered by how much
it constrains the design, not by how annoying it was.

---

## 1. `measure` is denominated in cells, so the best measurer in the system must lie

`Size measure(scope const(char)[] text)` returns cells. `SkiaCanvas.measure`
therefore **ignores Skia entirely** and returns `cellsOf(text)` — the Unicode
width — because layout has already committed to a grid and an honest pixel
answer would disagree with it.

This is the deepest one. The backend with real shaping, kerning and fallback is
structurally forbidden from using any of it, and a proportional font is not
merely unsupported but inexpressible: there is no unit in the seam that could
carry the answer. `RND6` records the monospace constraint as a rendering
decision; it is in fact a _vocabulary_ decision, and it is made here.

## 2. The concept describes five methods; the real contract is eight

`isCanvas` checks `fillRect`, `textRun`, `glyph`, `line`, `measure`. But `OpKind`
has eight members, and `rule`, `scrollbar`, `pushClip`/`popClip` are discovered
by `__traits(compiles)` at each interpreter call site instead.

So the concept does not describe the contract — the interpreter does, by
introspection, in several places. A backend author cannot learn the real surface
from `isCanvas`, and `static assert(isCanvas!T)` passing says much less than it
appears to.

## 3. `scrollbar` is a widget concept living in the drawing seam

A canvas is handed `barContent`, `barViewport`, `barOffset`, `expandPercent`,
`barTrackLit`, `barTrackColor`, `barTrackGlyph`, `barThumbGlyph` — and is
expected to know what a scrollbar is and how to degrade one.

Eight of `DrawOp`'s eighteen fields exist for this single op kind. The reason is
sound (a cell backend degrades a scrollbar differently from a pixel backend, so
the _semantics_ have to survive) but the consequence is that "draw" and "what a
scrollbar is" are now the same layer.

## 4. `DrawOp` is the shape `sparkles:input` explicitly rejected

`DrawOp` is a `kind` tag plus eighteen fields, most dead for any given kind.

The repository already argued the other side of this. `sparkles.input.events`
opens by saying its `Event` is "a sum type rather than a `kind` + dead fields
record, so an illegal combination … is unrepresentable and `==` compares only
what is live." Two seams, one repository, opposite conclusions — and the drawing
one is the seam with more kinds and more dead fields.

## 5. Sub-cell placement is spelled as a compass direction

The toolkit has no unit below one cell, so `rule` names an _edge_
(`RuleEdge.top`, `centerX`, …) and each backend decides what a band along that
edge means. `SkiaCanvas` draws one device pixel; `GridCanvas` fills a whole
cell.

It works, and it is honest about the degradation. But it covers exactly six
predefined positions, and anything else sub-cell — a two-pixel focus ring, a
badge inset, an underline offset — has no spelling at all. The same pressure
that produced `RuleEdge` will keep producing more enumerators.

## 6. Every op carries both resolved and semantic colour

`DrawOp` has `visual` (already resolved) _and_ `slot` (the semantic role), because
pixel backends want the first and re-resolving backends — the HTML interpreter's
class names — want the second.

The seam hedges rather than deciding, and every op pays for both.

## 7. `DrawOp.text` is a borrowed slice that must outlive the op

Documented on the field. It cannot cross a thread, cannot be retained past the
frame, and makes the sum-type assignment `@system` under `dip1000`. Tracked as
`UI-O4`; noted here because a GPU backend that wants to record on one thread and
submit on another meets it immediately, which is precisely what M7/T5 does next.

## 8. A backend cannot ask the display list how big it is

`skia-canvas-render.d` had to derive the extent by scanning every op's rect,
because nothing carries it. A backend that allocates its own surface — which is
every offscreen and every golden test — needs that number before it can paint.

The first version of that example guessed instead, and silently cropped its own
text; the golden then pinned the crop. The scan works only because a `textRun`'s
`rect.width` happens to be its advance in cells.

---

## What did _not_ cause friction

Worth recording, so the proposal does not "fix" things that are working:

- **Structural typing over an interface.** Attribute inference genuinely works:
  a `@system` GPU canvas and a `@safe @nogc` recorder satisfy one seam with
  neither lying. Keep it.
- **The optional-primitive pattern itself.** Probing for `pushClip` and painting
  unclipped without it is a good bargain — the problem in §2 is that the concept
  does not _say_ so, not that the mechanism is wrong.
- **Cell-space geometry for layout.** For a terminal-first toolkit this is
  right; §1 is about `measure`'s return type, not about laying out in cells.
- **`RecordingCanvas` as the reference implementation.** Having a canonical
  conforming backend that is also the test seam caught real mistakes.
