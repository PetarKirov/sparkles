# Concepts — the shared vocabulary of this survey

The thirty-four subjects surveyed here do not agree on what their words mean.
"Display list", "scene", "render node" and "command buffer" each name at least
three different artifacts across the catalog; "backend", "device", "renderer",
"painter" and "canvas" are used interchangeably by some projects and as a
careful hierarchy by others; and "degrade", "emulate", "lower" and "fall back"
name the same act performed in four different places. This page pins each term
to one meaning **for the rest of this tree**, grounded in at least two subjects
that use it that way, and says what each is not.

Where a subject's own name for a thing disagrees with the definition here, the
subject file keeps the subject's spelling and this page supplies the
translation. Nothing here overrides a deep-dive: **if the digest and a subject
file disagree, the subject file wins.**

**Last reviewed:** August 23, 2026

> [!NOTE]
> This is a vocabulary page, not a synthesis. The cross-subject conclusions live
> in [`comparison.md`][comparison]; the questions Q1–Q8 that every subject
> answers are defined in the [umbrella][index].

---

## 1. The reified-work cluster

This is where the disagreement is worst, and it is worst because the field uses
one set of words for two independent choices. Separate them and the mess
resolves.

| Axis                       | The question it asks                                                  | Poles                                                |
| -------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------- |
| **Instructions vs result** | Does the artifact say _what to do_, or hold _what was produced_?      | instruction stream ⟷ produced raster/grid            |
| **Tree vs flat**           | Does the artifact nest, so a node's meaning depends on its ancestors? | recursive tree ⟷ flat, position-independent sequence |

Two axes, four quadrants, and every reifying subject in this survey sits in one
of them:

| Artifact                                                 | Instructions or result | Tree or flat                        |
| -------------------------------------------------------- | ---------------------- | ----------------------------------- |
| WebRender `BuiltDisplayList` ([webrender][webrender-md]) | instructions           | flat (byte stream)                  |
| Chromium `PaintOpBuffer` ([chromium][chromium-md])       | instructions           | flat (variable-stride arena)        |
| Flutter `DisplayList` ([flutter][flutter-md])            | instructions           | flat (byte arena + offset table)    |
| Skia `SkRecord` ([skia][skia-md])                        | instructions           | flat (tag array + arena)            |
| Cairo recording surface ([cairo/D2D][cairo-md])          | instructions           | flat (union of six payload structs) |
| SDL `SDL_RenderCommand` queue ([SDL][sdl-md])            | instructions           | flat (11 tags over 4 union arms)    |
| Vello `Encoding` ([vello][vello-md])                     | instructions           | flat (six parallel streams)         |
| `sparkles:ui` `DrawOp[]` ([canvas.d][canvas])            | instructions           | flat                                |
| GSK `GskRenderNode` ([GTK4/GSK][gsk-md])                 | instructions           | **tree**                            |
| Qt Quick `QSGNode` ([Qt Quick][qtquick-md])              | instructions           | **tree**                            |
| Avalonia `IRenderDataItem` ([Avalonia][avalonia-md])     | instructions           | **tree** (`RenderDataPushNode`)     |
| Vg `Data.image` ([OCaml Vg][vg-md])                      | instructions           | **tree**                            |
| Gloss `Picture` ([Gloss][gloss-md])                      | instructions           | **tree**                            |
| notty `I.t` ([Notty][notty-md])                          | instructions           | **tree**                            |
| diagrams `RNode` ([diagrams][diagrams-md])               | instructions           | **tree**                            |
| Ratatui `Buffer` ([Ratatui][ratatui-md])                 | **result**             | flat (cell grid)                    |
| Textual `Strip`/`Segment` ([Textual][textual-md])        | **result**             | flat (row of segments)              |
| Mosaic `TextSurface` ([Mosaic][mosaic-md])               | **result**             | flat (cell grid)                    |
| libvaxis `Screen` ([libvaxis][libvaxis-md])              | **result**             | flat (cell grid)                    |
| Vty `DisplayOps` ([Vty][vty-md])                         | **result**             | flat (row-major span ops)           |

### display list

**Definition used here:** a _flat, ordered sequence of drawing instructions_
whose elements are values — inspectable, comparable and replayable without
running a painter.

Grounded in [WebRender][webrender-md], where `BuiltDisplayList` is a
variable-width tagged byte stream of `DisplayItem`s written by
[`peek_poke`][wr-peekpoke]-style serialization ([`display_item.rs`][wr-ditem],
[`display_list.rs`][wr-dlist]), and in [Chromium][chromium-md], where a
`PaintOpBuffer` is a variable-stride arena of `PaintOp` subclasses
([`paint_op_buffer.h`][cr-pob]) and a `DisplayItemList` wraps one with
producer-declared visual rects ([`display_item_list.h`][cr-dil]).
[Flutter][flutter-md] and [Skia][skia-md] use the same shape by different
storage ([`display_list.h`][fl-dl], [`SkRecord.h`][sk-record]).

**Do not confuse with:** a _render tree_ (§ [render tree](#render-tree--render-node)) —
a display list here is flat by definition, so `pushClip`/`popClip` is a bracket
convention rather than a structural parent. Nor with a _result_ buffer: a
Ratatui `Buffer` is not a display list, even though both are flat arrays.

> [!IMPORTANT]
> "Display list" in a browser context sometimes means the whole retained scene
> including its clip and spatial trees. WebRender explicitly does not: every item
> carries a `clip_chain_id` and `spatial_id` into out-of-band trees, and
> [`CLIPPING_AND_POSITIONING.md`][wr-clipdoc] records that hierarchical clipping
> was abandoned. This tree follows WebRender: the display list is the flat part.

### scene

**Definition used here:** the _whole reified drawing work for one frame_,
irrespective of shape — the noun for "everything to be painted", used when the
distinction between tree, stream and encoding is not the point.

Every project that ships a type literally called `Scene` means something
different by it, which is exactly why this tree treats the word as a role
rather than a structure: [GPUI][gpui-md]'s `Scene` is struct-of-arrays over
eight `Primitive` variants ([`scene.rs`][gpui-scene]); [Vello][vello-md]'s
`Scene` wraps an `Encoding` of six parallel byte streams
([`encoding.rs`][vello-encoding]); [Masonry][parley-md]'s `record::Scene` is a
`Command` tag plus an id into typed side arenas; and Flutter's `SceneBuilder`
builds a _layer tree_, one tier above its display list
([`compositing.dart`][fl-compositing]).

**Do not confuse with:** "scene graph" (§ [terms this tree avoids](#terms-this-tree-avoids-and-why)).

### render tree / render node

**Definition used here:** a _recursive tree of instruction nodes_, where a node's
effect depends on its ancestors (transform, clip, opacity, style scope) and the
backend walks rather than iterates.

Grounded in [GSK][gsk-md], where `GskRenderNode` is an open GType hierarchy of
37 `GskRenderNodeType` kinds ([`gskenums.h`][gsk-enums],
[`gskrendernode.h`][gsk-rendernode]) each carrying a `graphene_rect_t bounds`
on the shared base struct; and in [Qt Quick][qtquick-md], whose `QSGNode` tree
carries a seven-value `NodeType` and is retained across frames for batching.
[Vg][vg-md], [Gloss][gloss-md], [Notty][notty-md] and [diagrams][diagrams-md]
are the same shape expressed as an algebraic data type instead of a class
hierarchy.

A **render node** is one element of such a tree. The distinguishing property is
not "it is semantic" — GSK's nodes are semantic and Gloss's are not — it is that
scope is structural: `Color c p` in Gloss colours a whole subtree, and a flat
list must repeat that value per element.

**Do not confuse with:** a _widget tree_. GSK's node tree sits **below** GTK's
widgets; `gtk_css_style_snapshot_border` resolves widget → CSS → node above the
seam. Mosaic's `MosaicNode` tree is the opposite: a widget tree above a painter
with no reified drawing artifact at all.

### command buffer

**Definition used here:** a _mutable, short-lived queue of instructions
accumulated and then submitted_, whose lifetime is a frame or a flush and which
is not intended to be retained, diffed or compared.

Grounded in [SDL_Renderer][sdl-md], whose `SDL_RenderCommand` queue is drained
by `RunCommandQueue` several times per frame and whose vertex arena is reset on
every flush ([`SDL_sysrender.h`][sdl-sysrender]); and in
[Direct2D][cairo-md]'s `ID2D1CommandList`, which is deliberately opaque — there
is no public value type, and it is read only by streaming into an
`ID2D1CommandSink` ([`ID2D1CommandList`][d2d-cl], [`ID2D1CommandSink`][d2d-sink]).

**Do not confuse with:** a _display list_. The difference is retention and
inspectability, not encoding: SDL's queue and WebRender's list are both flat
tagged sequences, but only one is a value you can keep. `sparkles:ui`'s
`DrawOp[]` is a display list by this definition, not a command buffer.

### recording

**Definition used here:** _capturing a call sequence made against a normal
drawing API into a replayable artifact_, where the recorder is itself a
conforming implementation of the drawing seam.

Grounded in [Skia][skia-md]'s `SkPictureRecorder`/`SkPicture` — a canvas that
appends to an `SkRecord` and hands back an immutable picture
([`SkPicture.h`][sk-picture]) — and in [Cairo][cairo-md]'s recording surface,
a `cairo_surface_t` that stores each call as a `cairo_command_t`, copying
payloads at record time ([`cairo-recording-surface.c`][cairo-rec]). Racket's
`record-dc%` is the mechanised version: a macro generates the recorder from the
`dc<%>` method list, yielding both a replay closure and a `write`-able datum
([Racket][racket-md]).

The load-bearing property is that a recording is produced by the _same seam_
the real backends implement. `RecordingCanvas` in [`canvas.d`][canvas] is a
recording in exactly this sense.

**Do not confuse with:** _encoding_ — a recording preserves the call vocabulary;
an encoding does not have to.

### encoding

**Definition used here:** a _buffer layout designed for one consumer's access
pattern_, where entries are variable-width, positionally recovered, and not
individually addressable by kind.

Grounded in [Vello][vello-md]: `Encoding` is six parallel append-only streams
(`path_tags`, `path_data`, `draw_tags`, `draw_data`, `transforms`, `styles`)
whose entries are recovered by prefix sum over a tag byte, because the consumer
is a data-parallel GPU pipeline ([`encoding.rs`][vello-encoding]); the same
repository chose a plain Rust enum for `vello::recording::Command` because
_that_ consumer dispatches sequentially. [WebRender][webrender-md]'s byte stream
is an encoding by the same logic — the shape follows the IPC boundary.

Vello's [`pathseg.md`][vello-pathseg] records abandoning a fixed 36-byte element
record for exactly the reason [friction §4][friction] gives about `DrawOp`.

**Do not confuse with:** _serialization_. Chromium serializes its
`PaintOpBuffer` across a process boundary and the op vocabulary changes on the
way (`DrawTextBlobOp` becomes `DrawSlugOp`; two ops refuse to serialize at all)
— so the encoding and the recording are different artifacts there.

### result buffer

**Definition used here:** the _produced pixels or cells_ reified as a
comparable value, rather than the instructions that produced them.

Grounded in [Ratatui][ratatui-md] (`Buffer { area, content: Vec<Cell> }`, whose
diff against the previous frame _is_ the rendering algorithm —
[`buffer.rs`][rat-buffer]) and [Textual][textual-md] (`Strip`, "like an
immutable list of `Segment`s", [`strip.py`][tx-strip]). [Mosaic][mosaic-md],
[libvaxis][libvaxis-md] and [Vty][vty-md] all reify results too.

This is the quadrant `sparkles:ui` does not occupy, and the reason its cell
backend and its GPU backend can share a seam at all: a result buffer buys
diffing, read-back composition and value-comparable goldens, and cannot reach
Skia.

---

## 2. The who-draws cluster

Ten words, roughly three roles. The roles are what this tree names; the words
are what the subjects call them.

| Role                                                                                     | This tree's word | Subjects' words                                                                                                                                   |
| ---------------------------------------------------------------------------------------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| The **framework-side** object an application draws against, which lowers before dispatch | **painter**      | Qt `QPainter`, Java2D `Graphics2D`, imaging `Painter`, Skia `SkCanvas`, Cairo `cairo_t`, Racket `dc<%>`                                           |
| The **implementation** a toolkit swaps to change targets                                 | **backend**      | Qt `QPaintEngine`, Skia `SkDevice`, Slint `ItemRenderer`, Ratatui `Backend`, iced `Renderer`, imaging `PaintSink`, Avalonia `IDrawingContextImpl` |
| The **thing drawn into**, which owns pixels/cells and declares its own size              | **surface**      | Cairo `cairo_surface_t`, Skia `SkSurface`, wgpu `Surface`, SDL render target, Ratatui `Buffer`, libvaxis `Screen`                                 |

### backend

**Definition used here:** the swappable implementation of the drawing seam —
the party that turns instructions into a target's native effect, and the party a
survey question like Q2 is asking about.

Grounded in [Ratatui][ratatui-md] (`Backend`, one trait, ten methods of which
one draws — [`backend.rs`][rat-backend]) and [Slint][slint-md] (`ItemRenderer`,
whose implementations span a software MCU renderer and Skia —
[`item_rendering.rs`][slint-renderer]).

**Do not confuse with:** _device_. Several subjects' "backend" is not the party
that owns pixels: Cairo's `cairo_surface_backend_t` is a private vtable
([`cairo-surface-backend-private.h`][cairo-backend]) on an object that is also
the surface, while Skia separates `SkDevice` (backend) from `SkSurface`
(surface) explicitly.

### device

**Definition used here:** the _physical or logical output_ whose properties
(resolution, colour depth, unit, hinting regime) parameterise what drawing and
measurement mean — as distinct from the code that draws.

Grounded in [Qt][qt-md] (`QPaintDevice`, which declares extent while
`QPaintEngine` does the drawing) and in [Java2D][java2d-md] (`SurfaceData`
declares `getBounds()` and `getDeviceConfiguration()`, and the `FontRenderContext`
is what makes measurement device-parameterised).

**Do not confuse with:** _backend_. The distinction earns its keep in
§ [measurement](#4-measurement-vocabulary): Pango's metrics depend on the device
(`hint_metrics`) while its `PangoRenderer` — the backend — never measures.

### renderer

**Definition used here:** the object that _consumes a whole reified scene_ and
produces output, as opposed to one that receives calls.

Grounded in [GSK][gsk-md] (`GskRenderer` is four methods with **no drawing
primitives** — the entire vocabulary lives in the node tree it is handed) and
[Vello][vello-md] (`Renderer` takes a `Scene` plus `RenderParams`). Pango's
`PangoRenderer` is a counter-example naming: it is call-driven, so this tree
calls it a backend.

### painter

**Definition used here:** the _framework-side_ drawing facade an application
calls, which lowers, brackets, defaults and emulates before anything reaches a
backend.

Grounded in [Qt][qt-md] (`QPainter` emulates a feature the engine declines and
hands the engine an image of the result) and in
[imaging/Masonry][parley-md] (`Painter`'s ~40 convenience methods all lower to
`PaintSink`'s ten, so backends never implement them). [SDL][sdl-md] is the same
split with the seam moved: nineteen public draw calls collapse into six queue
functions, and `SDL_RenderTexture9Grid` — a nine-patch — never reaches a driver.

**Do not confuse with:** _paint engine_ (below) or _canvas_. A painter is the
half a backend author does **not** implement.

### paint engine

**Definition used here:** Qt's specific name for its backend
(`QPaintEngine`), retained because it is the survey's canonical
declared-capability model — `PaintEngineFeature` plus `hasFeature`
([Qt][qt-md], [`QPaintEngine`][qpe]).

Used in this tree only when talking about Qt. Note that Qt itself abandoned it:
[Qt Quick's scene graph][qtquick-md] deleted `PaintEngineFeature` and did not
replace it.

### canvas

**Definition used here:** an object that is _both_ painter and dispatcher — it
accepts drawing calls and either records them or forwards them to a backend.

Grounded in [Skia][skia-md] (`SkCanvas`: 33 public `draw*`, 26 `onDraw*`
virtuals, forwarding to a 10-pure-virtual `SkDevice` — [`SkCanvas.h`][sk-canvas],
[`SkDevice.h`][sk-device]) and in [Chromium][chromium-md] (`PaintCanvas`, 45
pure virtuals, with `RecordPaintCanvas` as the recording implementation
— [`paint_canvas.h`][cr-paintcanvas]).

This is the word `sparkles:ui` uses, and it uses it in the _narrower_ sense —
see § [what these words mean in `sparkles:ui` today](#what-these-words-mean-in-sparklesui-today).

### surface / target

**Definition used here:** the artifact that _owns the output storage and
declares its own extent_. "Target" is used when the emphasis is on selection
(which surface a painter is currently aimed at).

Grounded in [Cairo][cairo-md] (`cairo_surface_t`, with `get_extents`; a surface
whose slot is `NULL` or returns `FALSE` "is considered to be boundless") and in
[wgpu][wgpu-md] (`Surface` plus `SurfaceCapabilities`, a preference-ordered list
with a guaranteed floor element — [`surface.rs`][wgpu-surface]).

Q8 in this survey is precisely the question of whether extent belongs here or to
the scene; the subjects disagree, so the word must not smuggle the answer.

A **sink** is the narrow variant of a backend that _cannot refuse_: every method
returns nothing and failure surfaces later, out of band. imaging's `PaintSink`
records `set_error_once` and reports from `finish() -> Result`
([Parley and Xilem][parley-md]); Direct2D's `ID2D1CommandSink` does the same and
additionally accepts a _narrower_ vocabulary than the drawing API
([`ID2D1CommandSink`][d2d-sink], [Cairo and Direct2D][cairo-md]).

---

## 3. Primitive, semantic, and the four words for degrading

### primitive operation

An operation whose meaning is fully determined by its geometry and appearance:
every backend that can draw it at all draws the same thing. Rects, paths,
positioned glyph runs. [egui][egui-md] is the limit case — the backend receives
triangles — and [Notty][notty-md] is the other limit, three constructors with no
geometry at all.

### semantic operation

An operation that names an _intent_ the backend must interpret, because
different targets legitimately realise it differently. Slint's
`draw_box_shadow`, GSK's `GskBorderNode`, Skia's `DrawShadowRec` (a lighting
model, not a blurred rect), Vello's `draw_blurred_rounded_rect`, Flutter's
`drawShadow`, and `sparkles:ui`'s `scrollbar` ([friction §3][friction]).

Three subjects state an _admission test_ for the seam, and they agree:

- **GSK** — do the backends disagree about how to draw it? ([GTK4/GSK][gsk-md])
- **Vello** — would lowering it require the caller to know something only the
  backend knows? ([Vello][vello-md])
- **Skia** — could a backend do something genuinely different with it, _and_
  does the default lowering ship in the framework? ([Skia][skia-md])

**Do not confuse with:** a _widget_ operation. GSK stops hard at the CSS box
model; no surveyed subject has a scrollbar node.

### lowering

Rewriting a higher-level operation into lower-level ones **before** the backend
sees it, unconditionally and for every target. SDL's `SDL_RenderRect` becomes
`SDL_RenderLines` over five points; Godot's `RendererCanvasCull` turns
`canvas_item_add_line` into a feathered quad ([SDL][sdl-md],
[Godot][godot-md]). Lowering is not degradation: nothing is lost, and no target
was consulted.

### emulation

The **framework** implements a capability the backend declined, then hands the
backend the result. Qt's `QPainter` is the canonical case: it rasterises the
missing feature and passes an image ([Qt][qt-md]). Java2D reaches the same place
structurally — `MTLSurfaceData.validatePipe` calls `super.validatePipe` for
every state it cannot accelerate, so the floor is the superclass
([Java2D][java2d-md]).

### degradation

The **backend** substitutes a lower-fidelity realisation of a semantic
operation, on its own authority. Slint's backends decide;
`GridCanvas` fills a cell where `SkiaCanvas` draws one device pixel.
GSK adds a third location the axis did not have: degradation lives in the _node
kind_, because every `GskRenderNodeClass` ships a Cairo `draw` vmethod, so the
fallback travels with the kind rather than with the framework or the backend
([GTK4/GSK][gsk-md]).

> [!WARNING]
> Qt "emulates" in the framework and Slint "degrades" in the backend, and both
> projects would call the other's act by their own word. This tree uses
> **emulation** for framework-side and **degradation** for backend-side, always,
> regardless of what the subject calls it.

### fallback

A named alternative realisation _published_ for whoever wants it — neither
automatically applied nor owned by one party. [piet][piet-md] is the clean case:
`piet::util` exports `size_for_blurred_rect` and `compute_blurred_rect`, and each
backend chooses whether to call them. `ruleEndpoints` and `scrollbarCell` in
[`canvas.d`][canvas] are fallbacks in exactly this sense — published helpers that
every backend is currently _required_ to call.

### refusal

Declining an operation and saying so, rather than approximating it. SDL's
`SDL_SetRenderDrawBlendMode` returns `SDL_Unsupported()` rather than
approximating ([SDL][sdl-md]); Notcurses' `NCVISUAL_OPTION_NODEGRADE` asks for
failure instead of a lower blitter ([Notcurses][notcurses-md]); wgpu refuses
device creation and names whose fault it is ([wgpu][wgpu-md]).

---

## 4. Measurement vocabulary

Pango is the anchor for this cluster because it is the only surveyed subject
that keeps every distinction separate and names all of them.

### shaping

Turning a run of characters plus a resolved font into _positioned glyph ids_.
HarfBuzz's `hb_shape` takes a `hb_buffer_t` in with Unicode and out with glyphs
([`hb-shape.cc`][hb-shape]); Avalonia's `ITextShaperImpl.ShapeText` returns a
`ShapedBuffer` ([`ITextShaperImpl.cs`][av-shaper]).

Several seams accept **only** shaped text: Flutter's `drawText` takes a
`std::shared_ptr<DlText>`, WebRender's text item carries an array of
`GlyphInstance { index, point }`, and Vello's `Glyph` is `{ id, x, y }`
([Flutter][flutter-md], [WebRender][webrender-md], [Vello][vello-md]).

### layout

Breaking shaped runs into lines against a constraint, and the object that
result lives in. Flutter's `Paragraph` must be `layout(ParagraphConstraints)`-ed
before it may be measured or drawn; Parley's `Layout` is built by a
`ranged_builder` and read for width/height ([Flutter][flutter-md],
[Parley/Xilem][parley-md]).

The transferable rule from both: **the measured artifact must be the painted
artifact.** Masonry caches built `Layout`s keyed by the constraint and has
`measure`, `layout` and `paint` all read the same cached value.

### extents — ink vs logical

The **ink extent** is the rectangle the marks actually cover; the **logical
extent** is the box the text nominally occupies, including leading and
whitespace advance. Pango returns both from every extents call, at four nested
levels, and accumulates them by deliberately different rules — a zero-ink glyph
contributes nothing to the ink rect and still reserves advance width
([`glyphstring.c`][pango-glyphstring], [`pango-layout.c`][pango-layout]).

Cairo's `cairo_text_extents_t` makes the same split as an ink rect beside
`x_advance`/`y_advance` ([`cairo-scaled-font.c`][cairo-extents]), and
DirectWrite's `DWRITE_TEXT_METRICS` carries `width` beside
`widthIncludingTrailingWhitespace` ([`DWRITE_TEXT_METRICS`][dw-metrics]).

> [!IMPORTANT]
> A single `Size` cannot express this in **any** unit. That is a separate defect
> from [friction §1][friction]'s complaint about the unit, and it is why
> [`buildDisplayList`][canvas]'s reliance on a `textRun`'s `rect.width` bounding
> its ink is a coincidence rather than an invariant.

### advance

How far the pen moves — a property of the run, not of its marks. Vg makes it the
caller's input outright (`I.cut_glyphs` takes `?advances:v2 list`,
[OCaml Vg][vg-md]); WebRender and Vello carry positions rather than advances
because the caller already applied them.

### cell width

The number of terminal columns a string occupies. Distinguished from advance
because it is a Unicode property resolved above any font, and because the
**oracle is contested**:

- Ratatui ships one unit and _two_ disagreeing width functions —
  `Line::width` uses raw `UnicodeWidthStr::width` while `Buffer::set_stringn`
  goes through `CellWidth::cell_width`, which adds back the halfwidth katakana
  sound marks ([`cell_width.rs`][rat-cellwidth]).
- libvaxis makes the oracle a negotiated capability:
  `gwidth(str, Method)` with `Method = { unicode, wcwidth, no_zwj }`, and its own
  tests pin a ZWJ sequence at 2 under one and 4 under the others
  ([`gwidth.zig`][vx-gwidth]).
- Vty puts the oracle in a process-global C table generated by interrogating the
  actual terminal, precisely so toolkit and device cannot disagree
  ([Vty][vty-md]).

`cellsOf` in [`canvas.d`][canvas] is a cell-width oracle in this sense.

### grapheme

The user-perceived character a cell holds. Notty computes it once, at
construction, by running a segmenter inside `Text.of_string` and caching the sum
([Notty][notty-md]); libvaxis's `Cell.Character` carries the cluster plus a
caller-supplied `width` override it explicitly declines to verify
([`Cell.zig`][vx-cell]).

### measuring regime

The named device-dependent mode under which a measurement was taken. Microsoft
names it (`DWRITE_MEASURING_MODE` = `NATURAL`/`GDI_CLASSIC`/`GDI_NATURAL`,
[`DWRITE_MEASURING_MODE`][dw-measuring]); Java2D bundles it into an immutable
`FontRenderContext` used as a cache key ([Java2D][java2d-md]); Racket assigns it
a small integer, `get-font-metrics-key`, where `0` means "not cacheable"
([Racket][racket-md]); Cairo passes it one-way to the font layer via
`get_font_options` and `CAIRO_HINT_METRICS_ON` ([Cairo/D2D][cairo-md]).

`sparkles:ui` has exactly one regime — cells — and no name for it.

---

## 5. Capability vocabulary

wgpu is the anchor here because it is the only surveyed subject that types the
kinds apart instead of flattening them into one bitmask
([`features.rs`][wgpu-features], [`limits.rs`][wgpu-limits],
[`device.rs`][wgpu-device]).

| Term           | Definition used here                                                                                 | Grounded in                                                                                                                                     |
| -------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| **feature**    | A discrete capability a caller may _request_, and whose absence is a typed refusal                   | wgpu `Features`; Qt `PaintEngineFeature` + `hasFeature`; SDL `SupportsBlendMode`                                                                |
| **limit**      | A continuous quantity a caller may request up to, refused with the requested and allowed values      | wgpu `Limits` (~60 fields, tagless); SDL `max-texture-size`                                                                                     |
| **capability** | An _observable_ fact about the target that cannot be requested at all                                | wgpu `DownlevelFlags` (no `required_downlevel_flags` field exists); libvaxis `Capabilities`; Mosaic `Terminal.Capabilities`                     |
| **floor**      | The set every conforming implementation must supply, stated as a named value or a language construct | wgpu `DownlevelFlags::compliant()`; Skia's ten pure-virtual `SkDevice` draws; SDL's seven guaranteed blend modes; Java2D's `super.validatePipe` |
| **profile**    | A named, ordered tier that quantises the space so the set of behaviours to test stays finite         | wgpu `ShaderModel::{Sm2,Sm4,Sm5}` (`Ord`) and its ten limit buckets; Direct2D `D2D1_FEATURE_LEVEL`; Notcurses' blitter ladder                   |
| **downlevel**  | A target that is below the floor and says so, without pretending otherwise                           | wgpu `DownlevelFlags`; Notcurses' auto-degrade                                                                                                  |

Two properties of wgpu's arrangement have no counterpart elsewhere in the
survey and are worth naming:

- **The grant is closed above as well as below.** `DeviceDescriptor::required_features`
  documents that "Exactly the specified set of features, and no more or less,
  will be allowed" — not requesting a capability _forbids_ it on hardware that
  has it.
- **Refusable and observable capabilities are different types**, so demanding
  something unrequestable is unrepresentable rather than an error case.

`sparkles:ui` today has only the third row (capability), and has it implicitly,
via `__traits(compiles)` at each interpreter call site — which is
[friction §2][friction].

---

## 6. Payload ownership

Six answers, all shipped somewhere, to "who owns a command's text, image or
vertex data, and may the command outlive the frame".

| Term              | Definition used here                                                                   | Grounded in                                                                                                                                                                            |
| ----------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **borrowed**      | The command holds a slice into memory it does not own; validity ends with the frame    | `DrawOp.text` ([`canvas.d`][canvas]); ImGui's `ImDrawData::Valid` ([imtui][imtui-md]); libvaxis `Cell.grapheme`; imaging's `*Ref<'a>` payloads                                         |
| **owned**         | The command copies the payload into storage it controls                                | Skia `SkRecord::alloc<T>` and `SkPath` by value; Cairo's recording surface `memcpy`s glyphs and clusters; Ratatui's `CompactString` per cell                                           |
| **arena**         | Payloads are copied into one contiguous per-artifact allocation; commands hold offsets | Flutter `DisplayListStorage`; Chromium `PaintOpBuffer`; Godot's 4 KiB `CommandBlock`s; SDL's `SDL_AllocateRenderVertices` with `(first, count)`                                        |
| **refcounted**    | The payload is shared by an atomic or non-atomic count and may outlive any one holder  | GSK's `gatomicrefcount` (which is what makes the deferred Cairo fallback legal); Flutter's `sk_sp`/`shared_ptr`; egui's `Arc`; Avalonia's `IRef` ([`Ref.cs`][av-ref])                  |
| **interned**      | Repeated payloads are stored once in a side table and referenced by a small id         | Masonry's `record::Scene` (labels and file names interned once); Chromium's mirrored `ClientPaintCache`/`ServicePaintCache` keyed by `PaintCacheId` ([`paint_cache.h`][cr-paintcache]) |
| **shared handle** | The command carries a key; the payload lives in a store owned by the consumer          | WebRender's `ImageKey`/`FontInstanceKey` with bytes on a separate `ResourceUpdate` channel; Slint's `draw_cached_pixmap`; GPUI's `AtlasTile` into a `PlatformAtlas`                    |

Two refinements the survey adds that the six labels do not capture:

- **Weak plus inline geometry.** iced's recorded layer stores a
  `paragraph::Weak` carrying `min_bounds`, `align_x` and `align_y` _beside_ the
  weak pointer, so a dropped payload degrades to "nothing drawn" while damage
  tracking still has the rectangle ([iced][iced-md]).
- **A declared sharing property.** Flutter's `DisplayList::isUIThreadSafe()` is
  conjoined from each payload's own answer as ops are recorded, so the finished
  list answers "may this cross a thread" for itself ([Flutter][flutter-md]).

---

## Terms this tree avoids, and why

| Term                               | Why it is avoided                                                                                                                                                                                         |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **scene graph**                    | Qt Quick means a retained node tree with batching and a thread rendezvous; most other uses mean any hierarchy at all. Say _render tree_ (structure) or _scene_ (role).                                    |
| **immediate mode / retained mode** | Cuts across the axes that matter. egui is "immediate mode" and reifies a sum type; Qt's `QPaintEngine` is "retained"-adjacent and reifies nothing. Say what is reified and whether it survives the frame. |
| **context**                        | Means a painter (`cairo_t`), a device selector (`ID2D1DeviceContext`), a measurement service (`FontContext`, `LayoutContext`), and a measuring regime (`FontRenderContext`). Always qualify it.           |
| **draw call**                      | Means a seam method invocation to a toolkit author and a GPU submission to a graphics programmer. Say _operation_, _instruction_ or _submission_.                                                         |
| **layer**                          | Flutter's layer tree, GPUI's `StartLayer`/`EndLayer`, iced's `Layer` struct-of-arrays and imaging's `VisualLayerKind` are four different things. Qualify or name the type.                                |
| **2D API**                         | [piet][piet-md]'s post-mortem is precisely that "one 2D API over many backends" defines a vocabulary as the intersection of its backends. The phrase smuggles the design piet abandoned.                  |

---

## What these words mean in `sparkles:ui` today

The toolkit already uses three of the contested words. Fixing their meaning here
is half the point of the page.

- **`DrawOp`** — one element of `sparkles:ui`'s display list: a `kind` tag plus
  eighteen fields, most dead for any given kind ([`canvas.d`][canvas]). It is an
  _instruction_, not a result; _flat_, not a tree; and — by the definitions
  above — the elements of a **display list**, not of a command buffer, because
  `RecordingCanvas` keeps them.
- **display list** — the `DrawOp[]` that `buildDisplayList` emits and a painter
  walks once. Flat and position-independent except for the `pushClip`/`popClip`
  bracket convention, which is a stream convention rather than structure —
  precisely the property [Vg][vg-md] and [WebRender][webrender-md] give up in
  opposite directions.
- **canvas** — an `isCanvas!T`: a _backend_ in this page's vocabulary, not a
  painter and not a canvas in Skia's sense. It receives already-lowered
  instructions, owns no framework-side emulation, and is discovered structurally
  rather than declared.
- **`RecordingCanvas`** — a **recording** in the Skia/Cairo/Racket sense: a
  conforming backend that captures instead of drawing.
- **`Slot` and `Visual`** — the semantic role and the resolved appearance,
  carried on every op ([friction §6][friction]). Note the vocabulary collision:
  imaging's `ContextKindRef::Slot` is also called `Slot`, and is in the channel
  explicitly documented as _not_ reaching the rasterizer ([Parley/Xilem][parley-md]).
- **`RuleEdge`** — a _position enumeration_, which is what this survey's
  §5 subjects consistently replace with either a named **fidelity**
  ([Notcurses][notcurses-md], Flutter's hairline `strokeWidth = 0`), a **snapping
  policy** (GTK's `GskSnapDirection`, Pango's `pango_quantize_line_geometry`,
  GPUI's `snap_stroke`), or a **query** for the smallest addressable unit
  (iced's `1.0 / hint_factor()`).

---

## Sources

Every term above is grounded in the subject deep-dives of this tree, which carry
the pinned-SHA citations; the external links below are the specific declarations
quoted on this page, at the same revisions the subject files pin.

| Cluster                      | Subjects it is grounded in                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Reified work (§1)            | [WebRender][webrender-md], [Chromium][chromium-md], [Flutter][flutter-md], [Skia][skia-md], [Vello][vello-md], [GTK4/GSK][gsk-md], [Qt Quick][qtquick-md], [Cairo and Direct2D][cairo-md], [SDL][sdl-md], [Avalonia][avalonia-md], [Ratatui][ratatui-md], [Textual][textual-md], [Mosaic][mosaic-md], [libvaxis][libvaxis-md], [Vty][vty-md], [Notty][notty-md], [OCaml Vg][vg-md], [Gloss][gloss-md], [diagrams][diagrams-md], [Racket][racket-md], [Parley and Xilem][parley-md], [Monomer][monomer-md], [elm-canvas][elmcanvas-md] |
| Who draws (§2)               | [Qt][qt-md], [Slint][slint-md], [Java2D][java2d-md], [iced][iced-md], [Doodle][doodle-md], [piet][piet-md], [wgpu][wgpu-md], [egui][egui-md]                                                                                                                                                                                                                                                                                                                                                                                          |
| Semantics and degrading (§3) | [GTK4/GSK][gsk-md], [Vello][vello-md], [Skia][skia-md], [Qt][qt-md], [Java2D][java2d-md], [SDL][sdl-md], [Godot][godot-md], [piet][piet-md], [Notcurses][notcurses-md], [Notty][notty-md]                                                                                                                                                                                                                                                                                                                                             |
| Measurement (§4)             | [Pango and HarfBuzz][pango-md], [Flutter][flutter-md], [Parley and Xilem][parley-md], [Cairo and Direct2D][cairo-md], [Ratatui][ratatui-md], [libvaxis][libvaxis-md], [Vty][vty-md], [Notty][notty-md], [Godot TextServer][godot-md], [GPUI][gpui-md], [Racket][racket-md], [OCaml Vg][vg-md], [elm-ui][elmui-md], [functional images][fi-md]                                                                                                                                                                                         |
| Capability (§5)              | [wgpu][wgpu-md], [Qt][qt-md], [SDL][sdl-md], [Notcurses][notcurses-md], [libvaxis][libvaxis-md], [Mosaic][mosaic-md], [Skia][skia-md], [Java2D][java2d-md], [imtui][imtui-md], [Scala Doodle][doodle-md], [Haskell diagrams][diagrams-md]                                                                                                                                                                                                                                                                                             |
| Ownership (§6)               | [Skia][skia-md], [Cairo and Direct2D][cairo-md], [Flutter][flutter-md], [Chromium][chromium-md], [GTK4/GSK][gsk-md], [Avalonia][avalonia-md], [egui][egui-md], [iced][iced-md], [Slint][slint-md], [GPUI][gpui-md], [WebRender][webrender-md], [Godot][godot-md], [SDL][sdl-md], [imtui][imtui-md]                                                                                                                                                                                                                                    |

The `sparkles:ui` side of every entry is [`libs/ui/src/sparkles/ui/canvas.d`][canvas]
and [`canvas-seam-friction.md`][friction].

<!-- References -->

[index]: ./index.md
[comparison]: ./comparison.md
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
[avalonia-md]: ./avalonia.md
[cairo-md]: ./cairo-direct2d.md
[chromium-md]: ./chromium-paintop.md
[diagrams-md]: ./haskell-diagrams.md
[doodle-md]: ./scala-doodle.md
[egui-md]: ./egui.md
[elmcanvas-md]: ./elm-canvas.md
[elmui-md]: ./elm-ui.md
[fi-md]: ./functional-images.md
[flutter-md]: ./flutter-engine.md
[gloss-md]: ./gloss-picture.md
[godot-md]: ./godot-textserver.md
[gpui-md]: ./gpui.md
[gsk-md]: ./gtk4-gsk.md
[iced-md]: ./iced.md
[imtui-md]: ./imtui.md
[java2d-md]: ./java2d.md
[libvaxis-md]: ./libvaxis.md
[monomer-md]: ./monomer.md
[mosaic-md]: ./mosaic.md
[notcurses-md]: ./notcurses.md
[notty-md]: ./notty.md
[pango-md]: ./pango-harfbuzz.md
[parley-md]: ./parley-xilem.md
[piet-md]: ./piet.md
[qt-md]: ./qt-qpaintengine.md
[qtquick-md]: ./qt-quick-scenegraph.md
[racket-md]: ./racket-dc.md
[ratatui-md]: ./ratatui.md
[sdl-md]: ./sdl-renderer.md
[skia-md]: ./skia-skpicture.md
[slint-md]: ./slint.md
[textual-md]: ./textual.md
[vello-md]: ./vello.md
[vg-md]: ./ocaml-vg.md
[vty-md]: ./vty-image.md
[webrender-md]: ./webrender.md
[wgpu-md]: ./wgpu.md
[av-ref]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Utilities/Ref.cs
[av-shaper]: https://github.com/AvaloniaUI/Avalonia/blob/aee3f68551b0ac4417e32996a6627f34462edbc3/src/Avalonia.Base/Platform/ITextShaperImpl.cs
[cairo-backend]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-surface-backend-private.h
[cairo-extents]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-scaled-font.c#L1521
[cairo-rec]: https://gitlab.freedesktop.org/cairo/cairo/-/blob/bd04e43e201ef9beddcacdf379b610a0e199112e/src/cairo-recording-surface.c
[cr-dil]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/display_item_list.h
[cr-paintcache]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_cache.h
[cr-paintcanvas]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_canvas.h
[cr-pob]: https://github.com/chromium/chromium/blob/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/cc/paint/paint_op_buffer.h
[d2d-cl]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/d2d1_1/nn-d2d1_1-id2d1commandlist.md
[d2d-sink]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/d2d1_1/nn-d2d1_1-id2d1commandsink.md
[dw-measuring]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/dcommon/ne-dcommon-dwrite_measuring_mode.md
[dw-metrics]: https://github.com/MicrosoftDocs/sdk-api/blob/4502fff176b3b56beddb6a63c9f980377b11ba9b/sdk-api-src/content/dwrite/ns-dwrite-dwrite_text_metrics.md
[fl-compositing]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/lib/ui/compositing.dart
[fl-dl]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/engine/src/flutter/display_list/display_list.h
[gsk-enums]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskenums.h
[gsk-rendernode]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gsk/gskrendernode.h
[gpui-scene]: https://github.com/zed-industries/zed/blob/d71f1461045c098dc6ca6b1b5adcf1b8949722e8/crates/gpui/src/scene.rs
[hb-shape]: https://github.com/harfbuzz/harfbuzz/blob/29c1b91df168a8f6056fc8ef3dd4d08ffe6a7000/src/hb-shape.cc
[pango-glyphstring]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/glyphstring.c
[pango-layout]: https://github.com/GNOME/pango/blob/0b96e86efec3706601d7dc02b21c9bf19817c9de/pango/pango-layout.c
[qpe]: https://doc.qt.io/qt-6/qpaintengine.html
[rat-backend]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/backend.rs
[rat-buffer]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/buffer.rs
[rat-cellwidth]: https://github.com/ratatui/ratatui/blob/a2ca2df5688772baffb743b494761f4ec82b3174/ratatui-core/src/buffer/cell_width.rs
[sdl-sysrender]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/render/SDL_sysrender.h
[sk-canvas]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkCanvas.h
[sk-device]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkDevice.h
[sk-picture]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkPicture.h
[sk-record]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkRecord.h
[slint-renderer]: https://github.com/slint-ui/slint/blob/12d762c53b6d2022145dcb0cbf58eb91e31d76b9/internal/core/item_rendering.rs
[tx-strip]: https://github.com/Textualize/textual/blob/06dbeef4bb70fb718236aa418ed658ef4667a126/src/textual/strip.py
[vello-encoding]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/vello_encoding/src/encoding.rs
[vello-pathseg]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/doc/pathseg.md
[vx-cell]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/Cell.zig
[vx-gwidth]: https://github.com/rockorager/libvaxis/blob/c060d314930c5552b99a89278a6a695baf0352da/src/gwidth.zig
[wgpu-device]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-types/src/device.rs
[wgpu-features]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-types/src/features.rs
[wgpu-limits]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-types/src/limits.rs
[wgpu-surface]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-types/src/surface.rs
[wr-clipdoc]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender/doc/CLIPPING_AND_POSITIONING.md
[wr-ditem]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender_api/src/display_item.rs
[wr-dlist]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/webrender_api/src/display_list.rs
[wr-peekpoke]: https://github.com/mozilla-firefox/firefox/blob/44e151427db27db6b789e3be5439f0edbcf446de/gfx/wr/peek-poke/src/lib.rs
