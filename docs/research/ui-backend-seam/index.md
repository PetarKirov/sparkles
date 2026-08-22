# The UI backend seam — survey plan

**Status:** planned. No subject surveyed yet; this document is the brief.
**Last reviewed:** August 22, 2026

`sparkles:ui` draws through one seam, the Design-by-Introspection concept
`isCanvas!T` in [`libs/ui/src/sparkles/ui/canvas.d`][canvas]. Three backends
implement it today — a terminal cell grid, raylib, and now Skia — and writing
the third one produced a list of places where the seam forces a backend to lie.
That list is [`canvas-seam-friction.md`][friction]: eight entries, each recorded
while implementing rather than reasoned about afterwards.

This survey exists to answer whether those eight are a design that can be
repaired in place or a design that should be replaced, and to do it against
evidence from systems that solved the same problem rather than against taste.

## The question this survey answers

**How should a UI toolkit define its renderer seam when the targets genuinely
disagree about what a pixel is?**

That qualifier is the whole difficulty, and it is worth stating plainly because
it makes most of the obvious prior art inapplicable. `sparkles:ui` must serve:

- a **terminal**, where the smallest addressable unit is a character cell, text
  advance is a Unicode property, and there is no such thing as a hairline; and
- a **GPU surface**, where the unit is a device pixel, text advance is a
  property of a shaped font, and a hairline is ordinary.

Almost every toolkit surveyed below picks one of those and designs freely. The
few that span a comparable range are the ones to read closely.

## What each subject must answer

Eight questions, one per friction entry, so that every subject is read for the
same thing and the synthesis can compare like with like. A subject that does
not have an answer to a question is a finding, not a gap in the notes.

| #   | Question                                                                                               | Friction entry it tests              |
| --- | ------------------------------------------------------------------------------------------------------ | ------------------------------------ |
| Q1  | What unit does text measurement return, and can a backend answer in its own unit?                      | §1 `measure` is denominated in cells |
| Q2  | Is the backend contract stated in one place, or discovered by the caller probing for optional methods? | §2 five methods, eight kinds         |
| Q3  | Do semantic widgets (a scrollbar, a focus ring) reach the backend as themselves, or as primitives?     | §3 `scrollbar` in the drawing seam   |
| Q4  | Is a draw command a sum type, or a tag plus fields that are dead for most tags?                        | §4 `DrawOp`'s eighteen fields        |
| Q5  | How is sub-unit placement expressed when the toolkit's unit is coarser than the device's?              | §5 `RuleEdge` as a compass           |
| Q6  | Does a command carry resolved appearance, semantic role, or both — and who re-resolves?                | §6 `visual` _and_ `slot`             |
| Q7  | Who owns a command's payload (text, images), and can a command outlive the frame that made it?         | §7 borrowed `DrawOp.text`            |
| Q8  | Can a backend ask the scene its extent before allocating a surface?                                    | §8 no extent query                   |

## Subjects

Grouped by what they can teach, not by popularity. **Category** is the axis the
synthesis will re-cut on.

| Subject          | Category                | Why it is on the list                                                                                          | Status  |
| ---------------- | ----------------------- | -------------------------------------------------------------------------------------------------------------- | ------- |
| Slint            | spans the range         | Software renderer for MCUs _and_ Skia/femtovg GPU backends behind one `ItemRenderer` trait — the closest peer  | planned |
| GTK4 / GSK       | retained render tree    | `GskRenderNode` tree with Vulkan, GL and Cairo renderers; node kinds are semantic (`GskBorderNode`)            | planned |
| Flutter engine   | retained scene          | `SceneBuilder` / `Picture`; the layer tree is the seam and `dart:ui` is deliberately narrow                    | planned |
| egui             | backend gets geometry   | Emits `ClippedPrimitive` meshes — the backend receives triangles, not commands. The opposite extreme           | planned |
| Zed GPUI         | primitive scene         | A `Scene` of quads, shadows, glyphs and paths; text measurement is a first-class service                       | planned |
| Qt QPaintEngine  | virtual paint device    | The classic answer: an abstract paint engine with an explicitly declared feature set                           | planned |
| WebRender        | display list → batching | Browser display lists; how a semantic list is lowered to GPU work, and what it refuses to carry                | planned |
| Vello            | encoding, not commands  | The scene is an encoded buffer consumed by compute shaders — asks whether "commands" is the right shape at all | planned |
| Ratatui          | cell-only               | The terminal end done well; what a cell backend genuinely needs, so the seam does not over-serve it            | planned |
| Notcurses        | cell-only, sub-cell     | Sextants, quadrants and pixel protocols — a cell target that _does_ address below the cell (tests Q5)          | planned |
| Cairo / Direct2D | device abstraction      | The prior generation of "one drawing API, many devices"; where it leaks                                        | planned |

**Deliberately not surveyed**: React/DOM-style retained trees where the
"backend" is a browser, and game engines whose text story is a texture atlas
with no shaping. Both answer a different question.

## What the survey must produce

1. **`comparison.md`** — the capstone. One row per subject against Q1–Q8, plus
   the taxonomy re-cuts (by unit model, by command shape, by who owns payloads).
2. **`concepts.md`** — shared vocabulary, because the field does not agree on
   terms. "Display list", "scene", "render node" and "command buffer" are used
   for at least three different things across these subjects, and the synthesis
   is unreadable until they are pinned.
3. **A proposal** in `docs/specs/ui/`, not here — research states what others
   did; the proposal states what `sparkles:ui` will do, with requirement IDs.

## Constraints the proposal must respect

Recorded now, from [`canvas-seam-friction.md`][friction]'s "what did not cause
friction" section, so the proposal does not spend its budget re-litigating
things that work:

- **Structural typing over an interface.** Attribute inference is load-bearing:
  a `@system` GPU canvas and a `@safe @nogc` recorder satisfy one seam with
  neither lying. Any replacement keeps this.
- **Cell-space layout.** The toolkit is terminal-first; Q1 is about what
  `measure` returns, not about laying out in pixels.
- **A canonical conforming backend that is also the test seam.**
  `RecordingCanvas` caught real mistakes and pays for itself.
- **The optional-primitive bargain.** Probing for `pushClip` and degrading
  without it is right; Q2 is that the _contract_ is unstated, not that
  optionality is wrong.

## Open question the survey may not settle

Whether the terminal and GPU targets should share one seam at all. The
alternative — two seams with a shared _layout_ vocabulary above them — is not
obviously worse, and no amount of surveying will decide it without knowing what
`sparkles:ui`'s widgets actually need. The survey should gather the evidence and
say so if it cannot conclude.

## Sources

Populated as subjects are surveyed. Every citation pins a commit SHA per
[Writing Research Docs](../../guidelines/research-docs.md).

[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
