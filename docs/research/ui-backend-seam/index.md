# The UI backend seam

**Status:** complete — 38 of 38 subjects surveyed. The synthesis in
[`comparison.md`](./comparison.md) is written against all of them and reports
findings `F1`–`F12`; the shared vocabulary is [`concepts.md`](./concepts.md).
**Last reviewed:** August 23, 2026

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
few that span a comparable range are the ones to read closely — and the survey's
sharpest negative result is that **no surveyed subject spans what `sparkles:ui`
spans**. [Slint](./slint.md) comes closest and its range is small-GPU to
large-GPU; [imtui](./imtui.md) is the one project that retargeted a geometry seam
to character cells, and it paid with a permanent fork of the widget layer.

## What each subject must answer

Eight questions, one per friction entry, so that every subject is read for the
same thing and the synthesis can compare like with like. A subject that does
not have an answer to a question is a finding, not a gap in the notes.

Every question is answered across all 38 subjects in
[`comparison.md`](./comparison.md), which groups the subjects by **distinct
answer** rather than listing them — the size of each group is itself evidence.

| #   | Question                                                                                                             | Friction entry it tests                                          | Verdict in `comparison.md`                                |
| --- | -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | --------------------------------------------------------- |
| Q1  | What unit does text measurement return, and can a backend answer in its own unit?                                    | §1 `measure` is denominated in cells                             | Confirmed, and enlarged (`F1`, `F2`)                      |
| Q2  | Is the backend contract stated in one place, or discovered by the caller probing for optional methods?               | §2 five methods, eight kinds                                     | Confirmed, reframed (`F5`, `F11`)                         |
| Q3  | Do semantic widgets (a scrollbar, a focus ring) reach the backend as themselves, or as primitives?                   | §3 `scrollbar` is a widget concept in the drawing seam           | Half-refuted, half-confirmed (`F4`)                       |
| Q4  | How is a draw command encoded, and what does the encoding charge the operations that do not need the widest payload? | §4 the encoding is neither `@safe` nor variable-width            | Reification affirmed; the encoding is a live trade (`F3`) |
| Q5  | How is sub-unit placement expressed when the toolkit's unit is coarser than the device's?                            | §5 sub-cell placement as a compass direction                     | Reframed, not refuted (`F6`)                              |
| Q6  | Does a command carry resolved appearance, semantic role, or both — and who re-resolves?                              | §6 a resolved appearance and a semantic role on every drawing op | Confirmed, with a fork (`F9`)                             |
| Q7  | Who owns a command's payload (text, images), and can a command outlive the frame that made it?                       | §7 `DrawOp.text` is borrowed, and the borrow is not expressible  | Confirmed, unanimous 38/38 (`F8`)                         |
| Q8  | Can a backend ask the scene its extent before allocating a surface?                                                  | §8 no extent query                                               | Confirmed, and split three ways (`F7`)                    |

> [!NOTE]
> The verdict column summarises; it does not substitute. Each verdict turns on a
> distinction the one-word label cannot carry — §1 is confirmed but relocation
> alone fixes nothing, §3 is right about the layering smell and wrong about which
> half is the smell. Read [`comparison.md`](./comparison.md) before acting on any
> row.

---

## Master catalog

Thirty-eight subjects. The four that opened the survey (Slint, Qt
`QPaintEngine`, Notcurses, egui) plus 34 added in the completing pass. Ordered
as a curriculum rather than alphabetically: the ones that bound the space first,
then the retained trees and reified streams, then capability, measurement, cell
targets, and finally the functional-programming end that shows what the
questions look like when they dissolve.

**Target class** is the coarse fact that decides whether a subject's answer
transfers: `terminal` (character cells), `GPU` (device pixels, shaders),
`vector device` (a resolution-independent 2-D imaging model — printers, PDF,
SVG, CPU raster), `cross-target` (more than one class behind one design), and
`none` for the subjects that name no device at all.

| Subject                                               | Category                             | Language / ecosystem             | Target class            | What it teaches                                                                                                           |
| ----------------------------------------------------- | ------------------------------------ | -------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| [Slint](./slint.md)                                   | spans the range                      | Rust (C++/JS/Python APIs)        | cross-target            | One semantic `ItemRenderer` does span an MCU software renderer and Skia — and it is semantic _because_ it has to.         |
| [Qt `QPaintEngine`](./qt-qpaintengine.md)             | virtual paint device                 | C++                              | vector device           | The declared feature set, and framework emulation only when the engine declines. Measurement was never on the painter.    |
| [Qt Quick scene graph](./qt-quick-scenegraph.md)      | retained render tree                 | C++                              | GPU                     | Qt's own replacement deleted `PaintEngineFeature`; geometry-plus-shader is portable only among like backends.             |
| [Notcurses](./notcurses.md)                           | cell-only, sub-cell                  | C                                | terminal                | Name a _fidelity ladder_ that auto-degrades, not a sub-cell position — and width is a free function, not a method.        |
| [egui / epaint](./egui.md)                            | backend gets geometry                | Rust                             | GPU                     | The far end: the backend receives triangles. Nothing left to negotiate, and no cell target reachable.                     |
| [GTK4 / GSK](./gtk4-gsk.md)                           | retained render tree                 | C (GObject)                      | GPU + CPU + browser     | The seam can be a data structure, not a painter: 37 node kinds, each shipping its own Cairo fallback.                     |
| [Flutter engine](./flutter-engine.md)                 | retained scene                       | C++ engine, Dart API             | GPU                     | 68 exactly-sized op structs in a byte arena — reified and comparable without being a tagged record; no string crosses.    |
| [Zed GPUI](./gpui.md)                                 | primitive scene                      | Rust                             | GPU                     | When every target shares a rendering model you can pick primitives that never need degrading — and own every payload.     |
| [WebRender](./webrender.md)                           | display list → batching              | Rust                             | GPU                     | The only seam that is a _serialized value_, and the only one that writes down what its vocabulary refuses to carry.       |
| [Vello](./vello.md)                                   | encoding, not commands               | Rust                             | GPU (+ CPU raster)      | The consumer dictates the encoding: parallel streams for the shader, a plain enum for the sequential renderer.            |
| [Ratatui](./ratatui.md)                               | cell-only                            | Rust                             | terminal                | A seam that is the _result_ buys diffing, read-back composition and value goldens — and cannot reach a GPU.               |
| [Cairo and Direct2D](./cairo-direct2d.md)             | device abstraction                   | C · C++/COM                      | vector device           | The prior generation, and where it leaked: every GPU backend Cairo ever had is now deprecated or removed.                 |
| [Skia `SkPicture`](./skia-skpicture.md)               | reified command stream               | C++                              | GPU + vector device     | Three seams of decreasing width, and the whole optional-capability contract in language constructs the compiler checks.   |
| [Chromium `cc::PaintOpBuffer`](./chromium-paintop.md) | reified command stream               | C++20                            | GPU (across a process)  | What a reified stream converges on once it must survive serialization: tag plus per-op struct, tiered payload ownership.  |
| [Avalonia](./avalonia.md)                             | multi-backend toolkit seam           | C# (.NET)                        | cross-target            | Optionality is not one bucket: capability is declared at four distinct scopes, and every node carries `Bounds`.           |
| [Iced](./iced.md)                                     | capability by trait decomposition    | Rust                             | GPU                     | Capabilities as sub-traits a widget demands by name — and the price of a backend-chosen measurement _type_.               |
| [wgpu](./wgpu.md)                                     | formal capability negotiation        | Rust                             | GPU                     | Refusability is a type, not a value; and a grant closed _above_ turns cross-backend parity into a consequence.            |
| [SDL_Renderer](./sdl-renderer.md)                     | minimal device abstraction           | C99                              | GPU                     | A written mandatory floor plus one universal lowering primitive — and fidelity exposed as named user policy.              |
| [Java2D](./java2d.md)                                 | framework-side emulation             | Java (+ C/Objective-C loops)     | vector device           | Make the floor the _superclass_ and a backend cannot forget it. Appearance lives in pipeline state, not on the command.   |
| [Godot `TextServer`](./godot-textserver.md)           | measurement as a service             | C++17                            | GPU                     | `F1` in its strongest form: measurement is a named, swappable, capability-declaring peer; the drawing seam has no text.   |
| [Parley and Xilem](./parley-xilem.md)                 | greenfield split of text from scene  | Rust                             | GPU                     | Shaping as a borrowed context, a ten-method sink, and appearance as a late-bound index into a per-frame palette.          |
| [piet](./piet.md)                                     | abandoned multi-backend 2D seam      | Rust                             | vector device           | The survey's signed post-mortem: a seam defined as the intersection of its backends can be neither consistent nor grown.  |
| [Pango and HarfBuzz](./pango-harfbuzz.md)             | measurement as a separate layer      | C (GObject) · C++ with a C ABI   | vector device           | Measurement is device-_parameterised_: hinting and resolution are declared inputs that change the numbers.                |
| [imtui](./imtui.md)                                   | cross-target natural experiment      | C++                              | cross-target            | Retargeting a geometry seam to cells fails _upward_: with no semantics, degradation has nowhere to live but the widget.   |
| [Mosaic](./mosaic.md)                                 | cross-target, shared layer above     | Kotlin (Multiplatform)           | terminal                | The portable artifact is the retained node tree, reused verbatim through a four-method `Applier`. The painter is two ops. |
| [Textual](./textual.md)                               | cell toolkit with a second target    | Python                           | terminal (+ web, pixel) | Extra targets were cheap _because there is no drawing seam_ — only a reified, immutable, self-measuring result.           |
| [libvaxis](./libvaxis.md)                             | cell-only with sub-cell escapes      | Zig                              | terminal                | Publish the pixel size of a cell and negotiate the rest; `Widget.draw` returns a size — the cheapest extent mechanism.    |
| [Haskell diagrams](./haskell-diagrams.md)             | typed backend seam                   | Haskell                          | vector device           | Capability as a type-class instance makes omission a compile error — and leaves the silent degrade one line away.         |
| [OCaml Vg](./ocaml-vg.md)                             | documented renderer contract         | OCaml                            | vector device           | The renderer contract as a written artifact, per backend, in the seam's own vocabulary — and entirely unchecked.          |
| [Monomer](./monomer.md)                               | record-of-functions seam             | Haskell (+ a C shim)             | GPU                     | A value seam is perfectly self-describing and perfectly inflexible: 45 mandatory fields, no optional primitive.           |
| [Doodle](./scala-doodle.md)                           | tagless-final algebra                | Scala 3                          | cross-target            | The placement rule the friction log was groping for: semantic _and_ unserviceable by some backends ⇒ its own capability.  |
| [Vty `Image`](./vty-image.md)                         | image algebra (cell)                 | Haskell (+ a C width table)      | terminal                | Extent for free, cached by every constructor — and one process-global width table so two consumers cannot disagree.       |
| [Notty](./notty.md)                                   | image algebra with stated laws       | OCaml                            | terminal                | Invariants maintained at construction remove the need for backend queries entirely; twelve total closures suffice.        |
| [Gloss `Picture`](./gloss-picture.md)                 | pure sum-type scene                  | Haskell                          | GPU (OpenGL)            | Sum-type encoding and tree-vs-flat are independent axes; a tree keeps the scale factor a flat list has thrown away.       |
| [Functional images](./functional-images.md)           | the theoretical extreme              | Henderson 1982 · Elliott's `Pan` | none                    | Six of the eight questions dissolve — and _why_ they dissolve is the boundary marker, not a route.                        |
| [elm-ui](./elm-ui.md)                                 | purity as a forcing function         | Elm 0.19                         | browser DOM             | Exactly which layout decisions you lose when nothing can measure text: ellipsis, conditional wrap, content-sized things.  |
| [Racket `dc<%>` and pict](./racket-dc.md)             | device abstraction under an FP layer | Racket                           | vector device           | Measurement on the painter, priced honestly — plus a recorder generated from the seam, and three distinct extent queries. |
| [elm-canvas](./elm-canvas.md)                         | commands as pure data                | Elm 0.19 (+ ~90 lines of JS)     | browser canvas          | Reifying commands buys nothing on its own if the actual seam is still a stringly-typed `{type, name, args}`.              |

---

## Taxonomies

The same 38 subjects, re-cut one axis at a time. These tables are the umbrella's
real payload: they are where you look to find the subjects that answered a
question the way you are considering answering it. Membership follows
[`comparison.md`](./comparison.md)'s per-question tables; a subject that gives
two answers appears twice, and where that happens it is called out.

### By who measures text (`Q1`)

| Who answers                                       | Subjects                                                                                                                                                                                                                                                                        |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Nobody — unshaped text cannot cross the seam**  | [Flutter](./flutter-engine.md), [WebRender](./webrender.md), [Chromium](./chromium-paintop.md), [Qt Quick](./qt-quick-scenegraph.md), [GSK](./gtk4-gsk.md), [Avalonia](./avalonia.md), [Vello](./vello.md), [egui](./egui.md)                                                   |
| **A free function or fixed table above the seam** | [Ratatui](./ratatui.md), [Textual](./textual.md), [Mosaic](./mosaic.md), [Vty](./vty-image.md), [Notty](./notty.md), [Notcurses](./notcurses.md)                                                                                                                                |
| **A peer service with its own contract**          | [Godot `TextServer`](./godot-textserver.md), [Pango](./pango-harfbuzz.md), [Parley](./parley-xilem.md), [Qt `QPaintEngine`](./qt-qpaintengine.md), [Java2D](./java2d.md), [Skia](./skia-skpicture.md), [Cairo](./cairo-direct2d.md), [GPUI](./gpui.md), [Monomer](./monomer.md) |
| **A type the backend chooses**                    | [Slint](./slint.md), [Doodle](./scala-doodle.md), [Iced](./iced.md), [piet](./piet.md)                                                                                                                                                                                          |
| **Removed from the library entirely**             | [Vg](./ocaml-vg.md), [Gloss](./gloss-picture.md), [diagrams](./haskell-diagrams.md), [elm-ui](./elm-ui.md), [elm-canvas](./elm-canvas.md), [SDL](./sdl-renderer.md)                                                                                                             |
| **The painter — the only dissent**                | [Racket `dc<%>`](./racket-dc.md), [libvaxis](./libvaxis.md) (wrapped extent only), [imtui](./imtui.md) (by redefining the unit)                                                                                                                                                 |
| **Does not arise — no text in the seam**          | [wgpu](./wgpu.md), [functional images](./functional-images.md)                                                                                                                                                                                                                  |

**35 of 38 keep measurement off the painter, and the one outright dissenter
prices it.** Only Slint and Doodle make the returned _unit_ backend-chosen.

### By command shape (`Q4`)

The five families the friction log cares about — no reified command, an
instruction stream, a reified _result_, geometry, an encoding — split into
eight distinct answers once the survey is read.

| Shape                                               | Subjects                                                                                                                                                                                                                                                                                                               |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Sum type / tagged union, per-variant payload**    | [egui](./egui.md), [GPUI](./gpui.md), [WebRender](./webrender.md), [SDL](./sdl-renderer.md), [Cairo](./cairo-direct2d.md), [Vg](./ocaml-vg.md), [Gloss](./gloss-picture.md), [Vty](./vty-image.md), [Notty](./notty.md), [Doodle](./scala-doodle.md), [elm-canvas](./elm-canvas.md), [diagrams](./haskell-diagrams.md) |
| **Per-op struct in variable-stride storage**        | [Flutter](./flutter-engine.md), [Chromium](./chromium-paintop.md), [Skia](./skia-skpicture.md), [Godot](./godot-textserver.md)                                                                                                                                                                                         |
| **Open class hierarchy**                            | [GSK](./gtk4-gsk.md), [Avalonia](./avalonia.md), [Qt Quick](./qt-quick-scenegraph.md)                                                                                                                                                                                                                                  |
| **Parallel streams, or tag plus index into arenas** | [Vello](./vello.md), [Masonry/imaging](./parley-xilem.md)                                                                                                                                                                                                                                                              |
| **The result, not the instructions**                | [Ratatui](./ratatui.md), [Textual](./textual.md), [Mosaic](./mosaic.md), [Notcurses](./notcurses.md), [imtui](./imtui.md), [Vty](./vty-image.md)                                                                                                                                                                       |
| **Generated from the method set**                   | [Racket `record-dc%`](./racket-dc.md)                                                                                                                                                                                                                                                                                  |
| **Nothing reified**                                 | [Slint](./slint.md), [Qt `QPaintEngine`](./qt-qpaintengine.md), [Java2D](./java2d.md), [Pango](./pango-harfbuzz.md), [piet](./piet.md), [Iced](./iced.md), [elm-ui](./elm-ui.md), [functional images](./functional-images.md)                                                                                          |
| **Reified but unusable**                            | [Monomer](./monomer.md), [imtui](./imtui.md), [elm-canvas](./elm-canvas.md)                                                                                                                                                                                                                                            |

Three subjects appear twice by design: [Vty](./vty-image.md) is a sum-type image
algebra that lowers to `SpanOp` rows, and [imtui](./imtui.md) and
[elm-canvas](./elm-canvas.md) each reify and then cash nothing.
[wgpu](./wgpu.md) has no 2-D command vocabulary and is not placed here.

`sparkles:ui` sits in the first row: `DrawOp` is a closed sum over eight
per-kind payloads, and its size budget is governed by the widest of them.
**The three largest reifying subjects sit in the second** — Flutter, Chromium
and Skia each encode a per-op struct at variable stride, so an operation is
charged for its own fields and nothing else.

[`comparison.md`](./comparison.md)'s `F3` holds the two halves of the question
apart. Reifying the stream at all is what buys recording, replay, culling and
comparison, and every subject in the first four rows is evidence for it; the
survey affirms that much. How the stream is encoded is the part that stays
open: a closed sum eliminates illegal field combinations and leaves each
operation an independently comparable value, while variable stride prices each
operation at its own width. Four subjects — [diagrams](./haskell-diagrams.md),
[SDL](./sdl-renderer.md), [Masonry/imaging](./parley-xilem.md) and
[elm-canvas](./elm-canvas.md) — press a third axis under the same heading: how
many arms a sum should carry, and what a sum guarantees when an illegal state
can still be spelled inside one of them.

### By how capability is declared (`Q2`)

| Declaration                                                  | Subjects                                                                                                                                                                                                                                                                                                                  |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Nothing to declare — the contract is total**               | [Flutter](./flutter-engine.md) (49 pure virtuals), [Chromium](./chromium-paintop.md) (45), [Avalonia](./avalonia.md) (27), [Monomer](./monomer.md) (45 record fields), [Notty](./notty.md) (12 closures), [GPUI](./gpui.md), [Gloss](./gloss-picture.md), [Godot](./godot-textserver.md) (render seam), [egui](./egui.md) |
| **A declared feature set, as data**                          | [Qt `QPaintEngine`](./qt-qpaintengine.md), [wgpu](./wgpu.md), [SDL](./sdl-renderer.md), [WebRender](./webrender.md), [libvaxis](./libvaxis.md), [Mosaic](./mosaic.md), [Vty](./vty-image.md), [Avalonia](./avalonia.md)                                                                                                   |
| **Type-level — encoded in the language, no capability data** | [Skia](./skia-skpicture.md), [Java2D](./java2d.md), [Ratatui](./ratatui.md), [Masonry/imaging](./parley-xilem.md), [Doodle](./scala-doodle.md), [diagrams](./haskell-diagrams.md), [Iced](./iced.md), [Slint](./slint.md), [Pango](./pango-harfbuzz.md), [Racket](./racket-dc.md)                                         |
| **A request that fails, per call and argument-dependent**    | [Cairo](./cairo-direct2d.md), [SDL](./sdl-renderer.md), [Vg](./ocaml-vg.md), [libvaxis](./libvaxis.md), [Ratatui](./ratatui.md) (typed `Result` per method), [Masonry/imaging](./parley-xilem.md) (deferred, stream-scoped)                                                                                               |
| **A runtime probe of the live target**                       | [Notcurses](./notcurses.md) (blitter ladder), [libvaxis](./libvaxis.md) (negotiated `Capabilities` + override env vars), [Vty](./vty-image.md) (width table built by interrogating the terminal), [Mosaic](./mosaic.md), [Godot `TextServer`](./godot-textserver.md) (`has_feature`)                                      |
| **Prose only**                                               | [Vg](./ocaml-vg.md), [piet](./piet.md), [Qt Quick](./qt-quick-scenegraph.md)                                                                                                                                                                                                                                              |
| **Nothing stated**                                           | [imtui](./imtui.md), [elm-ui](./elm-ui.md), [Textual](./textual.md), [functional images](./functional-images.md), [Vello](./vello.md), [elm-canvas](./elm-canvas.md)                                                                                                                                                      |

> [!IMPORTANT]
> Subjects appear in more than one row on purpose. Qt declares a feature set
> _and_ probes it; libvaxis and Vty both probe the target and publish the result
> as data; SDL splits a hard-coded floor from a per-domain query and refuses
> per call. The rows are mechanisms, not camps. [GSK](./gtk4-gsk.md) belongs to
> none of them: it substitutes **observability** (a pink checkerboard under
> `GSK_DEBUG=cairo`) for refusal.

### By who degrades (`Q3`, and `F4`)

Seven camps, plus one project where degradation escaped the seam altogether.

| Where the lowering lives                                           | Subjects                                                                                                                                                                                                                                                  |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **In the backend**                                                 | [Slint](./slint.md), [Doodle](./scala-doodle.md), [Skia](./skia-skpicture.md), [Flutter](./flutter-engine.md), [Vello](./vello.md), [diagrams](./haskell-diagrams.md), [Vg](./ocaml-vg.md)                                                                |
| **In the framework, once**                                         | [Qt](./qt-qpaintengine.md), [Avalonia](./avalonia.md), [Godot](./godot-textserver.md), [SDL](./sdl-renderer.md), [Java2D](./java2d.md), [Cairo](./cairo-direct2d.md), [Pango](./pango-harfbuzz.md), [Racket](./racket-dc.md), [Notcurses](./notcurses.md) |
| **In the node kind — the fallback travels with it**                | [GSK](./gtk4-gsk.md)                                                                                                                                                                                                                                      |
| **Published by the framework, called at the backend's discretion** | [piet](./piet.md)                                                                                                                                                                                                                                         |
| **In the producer, before the stream exists**                      | [WebRender](./webrender.md)                                                                                                                                                                                                                               |
| **In the widget, before any target exists**                        | [Ratatui](./ratatui.md), [Textual](./textual.md), [libvaxis](./libvaxis.md), [Monomer](./monomer.md), [Gloss](./gloss-picture.md), [Mosaic](./mosaic.md), [Iced](./iced.md), [egui](./egui.md)                                                            |
| **Nobody — nothing needs to**                                      | [GPUI](./gpui.md), [Notty](./notty.md), [Vty](./vty-image.md), [functional images](./functional-images.md), [elm-canvas](./elm-canvas.md)                                                                                                                 |
| **Nowhere — unsupported content is silently dropped**              | [Qt Quick](./qt-quick-scenegraph.md) (the software adaptation's `// We dont know, so skip`), [elm-ui](./elm-ui.md) (the browser sizes the thumb)                                                                                                          |
| **Upward, into a permanent fork of the widget layer**              | [imtui](./imtui.md)                                                                                                                                                                                                                                       |

Refusal is a separate axis from lowering: [Ratatui](./ratatui.md),
[Masonry/imaging](./parley-xilem.md) and [Vg](./ocaml-vg.md) _report_ rather than
degrade, each at a different granularity (per call, per stream, per offending
value). [Chromium](./chromium-paintop.md) inverts the direction entirely — the
stream declares its own needs and nobody probes anybody — and
[wgpu](./wgpu.md) has no widgets, so the question does not arise for it.

### By whether the scene knows its own extent (`Q8`)

| Answer                                                     | Subjects                                                                                                                                                                                                                                                  |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Yes — cached on every node, maintained at construction** | [GSK](./gtk4-gsk.md), [Vty](./vty-image.md), [Notty](./notty.md), [Racket pict](./racket-dc.md), [Avalonia](./avalonia.md), [diagrams](./haskell-diagrams.md)                                                                                             |
| **Yes — accumulated during recording**                     | [Flutter](./flutter-engine.md), [Cairo](./cairo-direct2d.md), [Godot](./godot-textserver.md), [Chromium](./chromium-paintop.md)                                                                                                                           |
| **Yes — layout already knew it**                           | [Doodle](./scala-doodle.md), [Mosaic](./mosaic.md), [libvaxis](./libvaxis.md), [Textual](./textual.md), [Ratatui](./ratatui.md), [Monomer](./monomer.md), [Pango](./pango-harfbuzz.md) (per layout)                                                       |
| **Deliberately refused**                                   | [Skia](./skia-skpicture.md), [GPUI](./gpui.md), [WebRender](./webrender.md), [Vello](./vello.md), [Vg](./ocaml-vg.md), [Masonry/imaging](./parley-xilem.md)                                                                                               |
| **The extent is an _input_ to the scene**                  | [Vg](./ocaml-vg.md), [functional images](./functional-images.md), [elm-canvas](./elm-canvas.md)                                                                                                                                                           |
| **Only the surface declares it**                           | [Qt `QPaintEngine`](./qt-qpaintengine.md), [Notcurses](./notcurses.md), [SDL](./sdl-renderer.md), [Java2D](./java2d.md), [Iced](./iced.md), [Gloss](./gloss-picture.md), [imtui](./imtui.md), [egui](./egui.md), [elm-ui](./elm-ui.md), [piet](./piet.md) |

[Slint](./slint.md), [Qt Quick](./qt-quick-scenegraph.md) and [wgpu](./wgpu.md)
give no clear answer and are not placed. **Twelve subjects publish scene extent**, and
the live axis is maintained-at-construction versus derived-by-scan: nobody who
publishes it derives it by scanning.

---

## Quick navigation

**I want the conclusions.** [`comparison.md`](./comparison.md) — findings
`F1`–`F12`, then the verdict table on the eight friction entries, then ten
ordered recommendations. Read the verdict table first; it is the index into the
rest.

**A word in a subject file does not mean what I expect.**
[`concepts.md`](./concepts.md) — six clusters pinning "display list", "scene",
"render node", "command buffer", "backend", "device", "lowering", "degradation",
"advance", "cell width", "feature", "limit" and the rest, each grounded in at
least two subjects, with a closing section on what these words mean in
`sparkles:ui` today.

**I am writing the `sparkles:ui` proposal this informs.** Ten subjects move a
decision; the rest are corroboration. Read them in this order, against
[`comparison.md`](./comparison.md)'s recommendations:

1. [elm-ui](./elm-ui.md) — why `measure` can be relocated but not deleted, stated
   as the exact list of layout decisions that need an answer.
2. [Godot `TextServer`](./godot-textserver.md) and
   [Pango and HarfBuzz](./pango-harfbuzz.md) — what replaces it: a named,
   capability-declaring measurement peer, and the fact that its answers are
   device-parameterised.
3. [Ratatui](./ratatui.md) — the failure to avoid (two width functions that
   disagree) and [Vty](./vty-image.md)'s remedy (one authoritative table).
4. [Skia `SkPicture`](./skia-skpicture.md) and [Java2D](./java2d.md) — the whole
   optional-capability contract expressed in language constructs, and the
   unforgettable floor.
5. [Chromium `cc::PaintOpBuffer`](./chromium-paintop.md) and
   [Flutter](./flutter-engine.md) — how a reified stream stays comparable and
   replayable while each operation pays only for its own fields, read at the two
   scales where that trade bites hardest.
6. [GSK](./gtk4-gsk.md) — the admission test for a semantic operation, and the
   node kind that carries its own fallback.
7. [libvaxis](./libvaxis.md) — the cheapest answers in the survey to both §5
   (publish the cell's pixel size) and §8 (make paint return a size).
8. [imtui](./imtui.md) — the counterfactual: what happens if the semantics are
   removed instead of the derived geometry.
9. [piet](./piet.md) and [Cairo](./cairo-direct2d.md) — the two failure
   post-mortems, and the reason neither failure was about mechanism.
10. [Textual](./textual.md) — the accumulator that lets two ops touching one cell
    agree, which `RuleEdge`'s edge-per-op cannot.

**I work on the terminal arm.** [Ratatui](./ratatui.md),
[Textual](./textual.md), [libvaxis](./libvaxis.md), [Vty](./vty-image.md),
[Notty](./notty.md), [Notcurses](./notcurses.md), [Mosaic](./mosaic.md) — then
[imtui](./imtui.md) for what a GPU-shaped seam does to a cell target.

**I work on the GPU arm.** [Flutter](./flutter-engine.md),
[Chromium](./chromium-paintop.md), [Skia](./skia-skpicture.md),
[WebRender](./webrender.md), [Vello](./vello.md), [GPUI](./gpui.md) — then
[wgpu](./wgpu.md) for the capability model none of them have.

**I want the theory, not the engineering.**
[Functional images](./functional-images.md), [Notty](./notty.md),
[Gloss](./gloss-picture.md), [Doodle](./scala-doodle.md),
[diagrams](./haskell-diagrams.md), [Vg](./ocaml-vg.md) — the questions dissolve
in order, and the order is informative.

---

## Deliberately not surveyed

The exclusions are as load-bearing as the inclusions, so they are recorded with
their reasons.

- **React/DOM-style retained trees where the "backend" is a browser.** The DOM
  answers `Q2`, `Q5` and `Q8` on the toolkit's behalf, so a survey entry would
  report the browser's design, not the toolkit's. Two representatives were kept
  anyway, and only because each _prices_ the exclusion:
  [elm-ui](./elm-ui.md) shows exactly which layout decisions are lost when
  nothing can measure text, and [elm-canvas](./elm-canvas.md) shows a reified
  command list dissolving into a stringly-typed record at the actual seam.
- **Reflex and the FRP web libraries.** Considered, and dismissed for the same
  reason: the seam is the DOM. An FRP layer changes how the _tree_ is built over
  time, which is a question above this survey's; below it, every one of these
  libraries hands a browser the same nodes elm-ui does. The two Elm subjects
  already carry whatever this family had to teach about purity as a constraint.
- **Game engines whose text story is a texture atlas with no shaping.** They have
  no `Q1` to answer and their `Q5` is "render at a higher resolution".
  [Godot](./godot-textserver.md) is the deliberate exception and was admitted for
  its `TextServer` — a measurement seam with a live capability query — not for
  its renderer.
- **GPU APIs below the 2-D level.** [wgpu](./wgpu.md) is in the catalog solely as
  the field's most careful capability model; Vulkan, Metal and D3D were not
  surveyed, because "what a pixel is" is settled before their seam begins.
- **Immediate-mode GPU toolkits beyond egui and Dear ImGui.** The design is
  well-represented by [egui](./egui.md) at the geometry extreme, and the one
  question worth asking of the family — what happens when it is retargeted to
  cells — is answered by [imtui](./imtui.md), which forks Dear ImGui itself.

## What the survey must produce

1. **[`comparison.md`](./comparison.md)** — **done.** The capstone, rewritten
   against all 38 subjects. Findings `F1`–`F12`, a verdict per friction entry, a
   partial answer to the open question below, and ten ordered recommendations.
2. **[`concepts.md`](./concepts.md)** — **done.** The shared vocabulary, because
   the field does not agree on terms: "display list", "scene", "render node" and
   "command buffer" name at least three different artifacts each across this
   catalog, and the synthesis is unreadable until they are pinned.
3. **A proposal** in `docs/specs/ui/` — **outstanding.** Research states what
   others did; the proposal states what `sparkles:ui` will do, with requirement
   IDs. [`comparison.md`](./comparison.md)'s recommendations are input to it, not
   a substitute for it: they are ordered so that each is cheap and each unblocks
   the next, but none of them is a decision until the proposal makes it one.

## Constraints the proposal must respect

Recorded from [`canvas-seam-friction.md`][friction]'s "what did not cause
friction" section so the proposal does not spend its budget re-litigating things
that work. All four are carried by the evidence across the 38 subjects.

- **Structural typing over an interface.** Attribute inference is load-bearing:
  a `@system` GPU canvas and a `@safe @nogc` recorder satisfy one seam with
  neither lying. Any replacement keeps this. _Strengthened:_ `F5` finds that
  optional capability needs no capability data at all — Skia encodes floor,
  negotiable and refusal in ordinary language constructs, and D has all three.
  _Sharpened by `F11`:_ the concept, the op kinds, the payloads and the
  interpreter's probes should be **generated from one declaration**, so the
  four artifacts cannot drift again.
- **Cell-space layout.** The toolkit is terminal-first; `Q1` is about what
  `measure` returns, not about laying out in pixels. _Sharpened:_ `F2` finds
  relocating `measure` necessary and nowhere near sufficient — unit, oracle,
  return shape, device parameters and the identity of the measured artifact are
  five further decisions — and [elm-ui](./elm-ui.md) proves it can be relocated
  but not deleted, because neither backend contains a line breaker.
- **A canonical conforming backend that is also the test seam.**
  `RecordingCanvas` caught real mistakes and pays for itself. _Strengthened by
  `F12`:_ the op stream's value is as the cross-target **parity oracle** — the
  artifact that proves the cell grid and the image agree — rather than as the
  golden itself. Two further refinements from the survey:
  [Avalonia](./avalonia.md)'s headless backend deliberately declines optional
  capabilities Skia grants, so the fallback path is exercised on every run; and
  [Vg](./ocaml-vg.md) argues for generating the written contract from a
  conformance run rather than writing prose that rots.
- **The optional-primitive bargain.** Probing for `pushClip` and degrading
  without it is right; `Q2` is that the _contract_ is unstated, not that
  optionality is wrong. _Strengthened:_ `F5` upgrades this from acceptable to
  the field's ordinary answer — it is simply usually written down, scoped to a
  domain rather than a global probe, and consumed at the lowering step rather
  than at each call site.

## The open question

**Whether the terminal and GPU targets should share one seam at all.** The
alternative — two seams with a shared _layout_ vocabulary above them — was
recorded here as something the survey might not settle.

[`comparison.md`](./comparison.md) settles the part that matters, and its verdict
is: **one shared vocabulary above the painters, per-target painters below, and
the reified op stream retained as the cross-target parity artifact rather than as
the portability abstraction.** The evidence against one _drawing_ seam spanning
both classes includes failures rather than only designs — imtui's upward fork,
Cairo's deprecated GPU backends, piet's signed post-mortem, Qt Quick's silently
skipped custom nodes — while the evidence for a shared layer (Mosaic, Textual,
Ratatui, Doodle) is consistently about a layer _above_ drawing. That is not a
rejection of `isCanvas`; it is a statement about what the seam should be allowed
to grow into, and every friction entry that is a genuine defect is fixable
without answering it.

What remains open is a measurement rather than more reading: enumerate every use
of every `OpKind` in `sparkles:ui`'s widget set and ask whether the widget could
emit cells and rects instead. Read
[`comparison.md`](./comparison.md)'s closing section for the two cases that stay
open under that test.

## Sources

Every subject file in this directory carries its own citations, each pinned to a
40-character commit SHA per [Writing Research Docs][research-docs]; the
[comparison](./comparison.md) and [concepts](./concepts.md) pages cite the
subject files rather than restating the primary sources. The friction entries
under test are [`canvas-seam-friction.md`][friction], and the seam itself is
[`libs/ui/src/sparkles/ui/canvas.d`][canvas].

<!-- References -->

[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[research-docs]: ../../guidelines/research-docs.md
