# Parley and Xilem / Masonry — text is a service, painting is a sink

**Category:** greenfield split of text from scene. **Last reviewed:** August 23, 2026.
Parley pinned at [`1aba7cac`][parley-rev], Xilem at [`ce7b04d2`][xilem-rev].

Linebender's answer to the same two problems `sparkles:ui` has, written by the
people who wrote [Vello][vello] and read best immediately after that deep-dive:
**shaping is a context you borrow during layout, and painting is a ten-method
sink you stream into.** Section numbers below (§1-§8) refer to
[`canvas-seam-friction.md`][friction]; F1-F7 refer to the findings in
[`comparison.md`][comparison].

| Field                 | Value                                                                                                                                                                     |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**          | Rust (edition 2024; Parley MSRV 1.88, Xilem MSRV 1.96)                                                                                                                    |
| **License**           | Parley: Apache-2.0 OR MIT. Xilem/Masonry: Apache-2.0. `imaging`: Apache-2.0 OR MIT                                                                                        |
| **Repositories**      | [`linebender/parley`][parley-repo] (v0.11.0), [`linebender/xilem`][xilem-repo] (workspace v0.4.0)                                                                         |
| **Documentation**     | [`docs.rs/parley`][parley-docs], [`docs.rs/masonry`][masonry-docs], [`docs.rs/imaging/0.0.1`][imaging-docs], in-tree [`pass_system.md`][pass-system]                      |
| **Category**          | greenfield split of text from scene                                                                                                                                       |
| **Pinned revisions**  | Parley `1aba7cacb2030dea204efa87ba55317c0a59964a`; Xilem `ce7b04d2ba2d9d7a8c364f2ab109e2083121e144`; `imaging` crate `0.0.1`, sha256 `39a5e8c7…` per [`Cargo.lock`][lock] |
| **Seams under study** | Parley's [`Layout<B: Brush>`][parley-layout] and `LayoutContext`; Masonry's [`Widget::paint`][widget] over [`imaging::PaintSink`][paintsink]                              |
| **Backends shipped**  | Four, behind one sink trait: `imaging_vello`, `imaging_vello_hybrid`, `imaging_vello_cpu`, `imaging_skia` ([`masonry_imaging`][mi-lib])                                   |
| **Target range**      | Desktop and web GPU surfaces plus CPU rasterization and headless image output; no cell target                                                                             |

> [!IMPORTANT]
> This subject moved under the survey's feet. Masonry's own documentation still
> says "the paint pass gets a Vello Scene description from each widget"
> ([`pass_system.md`][pass-system]), and that was true until recently. At this
> revision a widget is handed an [`imaging::Painter`][painter] over a
> [`PaintSink`][paintsink] trait object, and Vello is one of four
> interchangeable backends behind it. The prose is stale; the code is the
> citation. That drift is itself the finding: the project that owns Vello
> chose **not** to make Vello's `Scene` its widget-facing seam.

## Overview

### What it solves

Two separable problems, deliberately kept in separate repositories.

**Parley** turns styled text into positioned glyphs, and nothing else. Its
[`README.md`][parley-repo] describes a four-crate stack underneath it —
Fontique for enumeration and fallback, HarfRust for shaping, Skrifa for outlines
and metrics, ICU4X for analysis — and defines Parley's own share as: "**Text
layout** means computing x/y coordinates for each glyph in a string of text."
No renderer appears anywhere in that sentence.

**Masonry** is the widget engine: tree, pass system, properties, accessibility,
and a paint pass producing backend-neutral commands. `masonry_core`'s crate docs
list "Compositing of widget's content (to be rendered using [Imaging])" as one
bullet among event handling and accessibility ([`lib.rs`][mc-lib]) — rendering
is explicitly downstream of the engine.

### Design philosophy

Parley's [`doc/design.md`][parley-design] states the motivation for a
renderer-independent text layer:

> While modern text layout engines have grown quite sophisticated, they are
> unfortunately limited to platform specific applications, requiring
> cross-platform code (or even cross-platform toolkits) to specialize their text
> rendering implementations for each supported operating system. […] Given the
> platform specific nature of current text engines, and the unsafe
> implementation language, the obvious course of action is to build a new,
> cross-platform, open source text layout engine in Rust.

> [!NOTE]
> `doc/design.md` predates the shipped crate: it proposes building on `swash`
> and exposing "the piet text API". Neither survives — [`README.md`][parley-repo]
> names HarfRust, Skrifa, Fontique and ICU4X, and the API is Parley's own. The
> _motivation_ is current; the implementation plan is not.

The painting half states its philosophy as a two-workflow split
([`imaging` crate docs][imaging-docs]):

> `imaging` has two primary workflows:
>
> - Painting: stream borrowed commands into any `PaintSink` with `Painter`.
> - Recording: retain an owned command stream in `record::Scene` for validation
>   and replay.

## How it works

### Parley: a scratch context, an owned layout, and a caller-chosen brush

Text layout is a two-resource protocol. `FontContext` is the font database;
`LayoutContext` is "shared scratch space used when constructing text layouts …
designed to be a global resource with only one per-application (or per-thread)"
([`context.rs`][parley-context]), holding the reusable `Analyzer`, `Shaper` and
style builders so a layout amortizes allocations instead of building a pipeline
per string. A builder consumes both and produces an owned
[`Layout<B>`][parley-layout], line-broken and aligned as separate steps —
`break_all_lines(max_advance)`, `align(alignment, options)` — and re-breakable
many times, though a content or style change requires a new build
([`lib.rs`][parley-lib]).

The type parameter is the interesting part:

```rust
/// Trait for types that represent the color of glyphs or decorations.
pub trait Brush: Clone + PartialEq + Default + core::fmt::Debug {}

impl<T: Clone + PartialEq + Default + core::fmt::Debug> Brush for T {}
```

That is the whole declaration ([`style/brush.rs`][brush]). Parley never
interprets a brush; it stores one per `Style` and per `Decoration` and hands it
back on the far side. The blanket impl means _any_ owned, comparable, defaultable
type qualifies, and `LayoutContext<B: Brush = [u8; 4]>` defaults to four bytes
of anything. A `Layout` therefore carries no colour semantics and no lifetime.

Querying a built layout is ordinary accessor work: `width()`, `full_width()`,
`height()`, `first_baseline()`, `calculate_content_widths()` returning a
`ContentWidths { min, max }`, and `lines()` yielding `Line`s whose `items()` are
`PositionedLayoutItem::GlyphRun` or `::InlineBox`. Hit-testing is the same data
read backwards: `Cluster::from_point(layout, x, y)` returns the cluster and
which side of it a point fell on, and `Cursor::from_point` layers bidi-aware
affinity on top ([`cluster.rs`][cluster], [`cursor.rs`][cursor]);
`Selection::geometry_with` yields the rectangles a caller fills for a highlight.

### Masonry: the sink is the seam, the painter is sugar

A Masonry widget's drawing methods take a painter, not a scene
([`widget.rs`][widget]):

```rust
fn pre_paint(&mut self, ctx: &mut PaintCtx<'_>, props: &PropertiesRef<'_>, painter: &mut Painter<'_>) { … }
fn paint(&mut self, ctx: &mut PaintCtx<'_>, props: &PropertiesRef<'_>, painter: &mut Painter<'_>);
fn post_paint(&mut self, ctx: &mut PaintCtx<'_>, props: &PropertiesRef<'_>, painter: &mut Painter<'_>) { }
```

`Painter` is a thin authoring wrapper — `pub struct Painter<'a, S: PaintSink + ?Sized = dyn PaintSink + 'a>`
— with roughly forty convenience methods (`fill_rect`, `with_fill_clip`,
`with_group`, `push_context`, builder-style `fill(…).transform(…).draw()`).
The **contract** underneath it is ten methods, two of them defaulted
([`paint.rs`, `PaintSink`][paintsink]):

```rust
pub trait PaintSink {
    fn push_context(&mut self, _context: ContextRef<'_>) {}
    fn pop_context(&mut self) {}
    fn push_clip(&mut self, clip: ClipRef<'_>);
    fn pop_clip(&mut self);
    fn push_group(&mut self, group: GroupRef<'_>);
    fn pop_group(&mut self);
    fn fill(&mut self, draw: FillRef<'_>);
    fn stroke(&mut self, draw: StrokeRef<'_>);
    fn glyph_run(&mut self, draw: GlyphRunRef<'_>, glyphs: &mut dyn Iterator<Item = Glyph>);
    fn blurred_rounded_rect(&mut self, draw: BlurredRoundedRect);
}
```

Every payload is one struct per command kind, borrowed for the call, with a
`new()` carrying documented defaults and `#[must_use]` builder setters —
`FillRef` has six fields, `GlyphRunRef` eleven, and nothing is dead in either.
`Scene` implements the same trait, so **recording is not a separate concept**:
`record::replay(&scene, sink)` and `replay_transformed(…, transform)` push a
retained scene back through any other sink. The paint pass exploits that — each
widget owns three cached scenes and re-records only the ones it invalidated
([`passes/paint.rs`][paint-pass]):

```rust
let (pre_scene, scene, post_scene) = scene_cache.entry(id).or_default();
if ctx.widget_state.request_paint {
    scene.clear();
    let sink_dyn: &mut dyn PaintSink = scene;
    let mut painter = Painter::new(sink_dyn);
    widget.paint(&mut ctx, &props, &mut painter);
}
```

The result is flattened into a `VisualLayerPlan` — layers in painter order, each
with a transform and an owning `WidgetId` — whose `replay_into(sink)` streams
the frame into whichever backend is selected ([`visual_layers.rs`][layers]). One
`VisualLayerKind::External { bounds }` variant reserves space for
compositor-realized content that Masonry does not draw.

## Q1 — measurement units, and who answers

**A context service borrowed during the layout pass; the unit is logical
pixels; the painter is never asked.** `MeasureCtx`, `LayoutCtx`, `PaintCtx` and
six other context types all expose the same accessor
([`contexts.rs`][contexts]):

```rust
pub fn text_contexts(&mut self) -> (&mut FontContext, &mut LayoutContext<BrushIndex>) { … }
```

Measurement is a first-class step of the layout protocol rather than a call on
a drawing object. `Widget::measure(ctx, props, axis, len_req, cross_length)`
answers one axis at a time against a CSS-shaped request —
`LenReq::MinContent | MaxContent | FitContent(Length)` ([`len_req.rs`][lenreq]) —
and `Label::measure` maps those three cases onto Parley directly: `MinContent`
becomes `max_advance = Some(0)` ("Zero space will get us the length of longest
unbreakable word"), `MaxContent` becomes `None`, `FitContent(space)` becomes
that space; the answer is `layout.width()` or `layout.height()`
([`label.rs`][label]). `Widget::layout`'s doc fixes the unit: "The `size` given
to this method must be finite, non-negative, and in logical pixels."

This confirms **F1** from a fourth direction, and adds a mechanism the survey
has not seen: the label keeps an **LRU cache of built layouts keyed by the
constraint they were built under**, with `satisfies(max_advance)` deciding
whether an existing entry answers a new query, and re-uses the same cache in
`layout()` and again in `paint()` (`self.layouts[self.active_layout]`). So
measure and paint agree not because they share a formula but because they share
a _value_. That is the concrete form of the caveat Vello's `glifo` raised — a
measurer that only returns a number cannot guarantee the painter draws the same
thing.

## Q2 — where the contract is stated

**In one trait, exhaustively, with defaults marking the optional part** — and
this is the sharpest contrast with `isCanvas` in the survey. `PaintSink`'s ten
methods are the complete surface; a backend author reads one declaration.
The two context methods carry `{}` bodies documented "Default implementation:
ignored", so the optional-primitive bargain is expressed as a default rather
than as a caller-side probe.

Two further separations do work `isCanvas` does not:

- **Contract versus convenience.** `Painter`'s forty helpers all lower to the
  same ten calls. Widget authors get an ergonomic surface; backend authors do
  not have to implement it. `isCanvas` fuses both roles into one concept,
  which is why §2's five-versus-eight mismatch could arise at all.
- **Sink versus renderer.** The sink cannot refuse anything — every method
  returns `()`. Refusal happens one level up, at
  [`ImageRenderer::render_source_into`][imagerenderer], which returns
  `Result<(), ImageRendererError>` over an enumerated
  [`RenderUnsupportedError`][unsupported]: `ImageBrush`, `Filter`, `Mask`,
  `Glyph`, `BlurredRoundedRect`, `UnbalancedLayerStack`. The Skia backend does
  exactly that — `state.set_error_once(Error::UnsupportedFilter)` during
  painting, surfaced by a `finish() -> Result<(), Error>` at the end of the
  stream ([`imaging_skia` 0.0.1 `sinks.rs`][skia-sinks]).

That is **F4 implemented, with a twist F4 did not anticipate**: the degrade is
refusable, but refusal is _deferred and stream-scoped_ rather than per-call,
because making every draw call fallible would poison the authoring API.

## Q3 — semantic operations or primitives

**Purely primitive for rendering — and the semantic channel exists anyway, as
an explicitly non-rendering annotation stream.** There is no `draw_scrollbar`,
no `draw_text_input`, no `draw_border`; a scrollbar is fills and strokes, and
the only shortcut in the vocabulary is `blurred_rounded_rect`, the same
analytic-blur exception Vello makes for the same reason.

But `PaintSink` also carries `push_context` / `pop_context`, and the payload is
semantic role data ([`paint.rs`][paintsink]):

```rust
pub enum ContextKindRef<'a> {
    Label,
    Widget,
    ChildIndex,
    Slot,
    Named(&'a str),
}
```

`ContextRef` pairs one of those with a `ContextValueRef` (`Str`, `U64`, `I64`,
`Usize`, `Bool`) and an optional `SourceLocationRef { file, line, column }`.
Scenes "intern context strings and file names only when contexts are actually
emitted, so structured context values like widget IDs or child indices do not
require eager string formatting on the hot path" ([crate docs][imaging-docs]),
and `ValidateError` variants report the enclosing context stack when a scene is
unbalanced.

So the design splits what `DrawOp` fuses: a **rendering** channel that is
resolved and primitive, and a **semantic** channel that is optional, ignorable
by default, and used for diagnostics and validation rather than for painting
decisions. Note the vocabulary collision — `imaging`'s `Slot` and
`sparkles:ui`'s `Slot` are the same word for the same idea, in the channel that
explicitly does not affect pixels.

## Q4 — command shape

**Three shapes for three consumers, all in the same vocabulary.**

| Layer                               | Shape                                                        | Why                                     |
| ----------------------------------- | ------------------------------------------------------------ | --------------------------------------- |
| Authoring (`Painter`)               | method calls with builder structs                            | ergonomics for widget authors           |
| Streaming (`PaintSink`)             | one borrowed `*Ref<'_>` struct per kind + `DrawRef` sum type | a backend dispatches once per command   |
| Retained ([`record::Scene`][scene]) | `Command` enum of ids into typed side arenas                 | comparison, validation, replay, caching |

The retained form is the one to look at ([`record.rs`][record]):

```rust
pub enum Command {
    PushContext(ContextId), PopContext,
    PushClip(ClipId),       PopClip,
    PushGroup(GroupId),     PopGroup,
    Draw(DrawId),
}

pub struct Scene {
    commands: Vec<Command>,
    labels: Vec<Box<str>>, files: Vec<Box<str>>, contexts: Vec<Context>,
    clips: Vec<Clip>, masks: Vec<Mask>, groups: Vec<Group>, draws: Vec<Draw>,
}
```

A command is a tag plus one index; every payload lives in a typed vector sized
for its own kind; strings are interned once. This lands between [egui][egui]'s
sum type and [Vello][vello]'s parallel streams and keeps both wanted properties
— no dead fields, and no prefix sum needed to read entry _n_. `Scene` derives
`PartialEq`, so two frames compare directly.

**This complicates F2** in a useful direction. F2 says reify as a sum type. Here
the _seam_ is a trait and the _reification_ is one implementation of it, so
`RecordingCanvas`'s role is not a testing affordance bolted on beside the
contract — it is the contract's canonical implementor, and every consumer that
wants a value (goldens, caches, layer plans) goes through it. `sparkles:ui` has
both halves the wrong way round: `DrawOp[]` is the seam's _output type_ rather
than one conforming backend.

## Q5 — sub-unit placement

**Not a problem either project has** — `kurbo` is `f64`, `Length` wraps an
`f64`, glyph positions are `f32`. Three of the four surveyed float-coordinate
subjects said the same; **F5** is unaffected.

The one transferable fragment is Parley's `quantize` flag, passed when creating
a builder ([`context.rs`][parley-context]):

> Set `quantize` as `true` to have the layout coordinates aligned to pixel
> boundaries. That is the easiest way to avoid blurry text and to receive
> ready-to-paint layout metrics. For advanced rendering use cases you can set
> `quantize` as `false` and receive fractional coordinates. […] To avoid blurry
> text you will still need to quantize the coordinates just before painting.

Grid alignment is a documented, opt-in property of the _text layout_, chosen
per layout and per consumer, with an explicit list of what must be rounded
(glyph run baseline, inline box baseline, selection geometry `y0`/`y1`). That is
the closest any surveyed subject comes to `sparkles:ui`'s cell quantization, and
it argues the decision belongs to the measurement layer rather than to the
drawing vocabulary — the same conclusion §1 reaches from the other end.

## Q6 — resolved or semantic styling

**Neither: an index, late-bound at paint time.** This is the strongest new
result in this deep-dive. Masonry instantiates Parley's brush parameter with
([`core/text.rs`][mc-text]):

```rust
/// The Parley [`Brush`] used within Masonry.
///
/// This enables updating of brush details without performing relayouts;
/// the inner values are indexes into the `brushes` argument to [`render_text()`].
#[derive(Clone, PartialEq, Default, Debug)]
pub struct BrushIndex(pub usize);
```

`render_text(painter, transform, layout, brushes: &[Brush], hint)` walks the
layout and resolves `style.brush.0` and `underline.brush.0` against the
caller-supplied table. `Label::paint` builds that table from properties on the
spot — `&[text_color.color.into()]` — so a theme change repaints without
touching the shaped layout, while the layout itself stays comparable and cheap
to cache (`BrushIndex: PartialEq`).

Below that, the drawing seam is **fully resolved**: `FillRef.brush` is a
`peniko::BrushRef`, `GlyphRunRef` carries `font`, `font_size`,
`normalized_coords`, `hint`, `style`. No role travels on a draw; the role
travels on the _context_ channel (Q3), which no backend has to read.

Friction §6 says the seam "hedges rather than deciding, and every op pays for
both". The answer here is that the two things belong to different layers: an
**index into a palette** on the retained artifact, resolved to concrete
appearance at the moment of painting, plus a separate annotation stream for
anything that is not appearance at all. `sparkles:ui`'s `Slot` and `Visual` are
that same pair collapsed into one struct and paid for on every op.

## Q7 — payload ownership and lifetime

**Borrowed at the seam, owned in the recording, with a documented conversion
between them.** Every sink payload is a `*Ref<'a>`; every one has a `to_owned()`
that materializes the `record` form (`GeometryRef::Path(&BezPath)` becomes
`Geometry::Path(BezPath)`, and `GeometryRef::OwnedPath` exists so a caller that
already owns a path does not clone it twice). Text never appears: `glyph_run`
takes `&mut dyn Iterator<Item = Glyph>`, so a caller can stream positioned
glyphs from a `SmallVec` without allocating a run
([`core/text.rs`][mc-text] collects into `SmallVec<[Glyph; 16]>`).

Retention is opt-in and total: a `Scene` owns its commands, its interned label
and file strings, and all payload arenas, and Masonry keeps three per widget
across frames. Parley's side is the same shape — a `Layout<B>` owns its data and
`B` carries no lifetime, so a shaped layout is retainable by construction.
`ArcStr = std::sync::Arc<str>` is Masonry's answer for widget-held text: "a
data-friendly way to represent strings in Masonry … it can be cheaply cloned".

Friction §7 stands, and this is the cheapest of the three answers the survey has
now collected (interning, reference-counting, backend-owned caches): keep the
borrowed form for the streaming call, define the owned form as a _sink that
copies_, and let the retention decision be the caller's per-widget.

## Q8 — can the scene report its extent?

**No, in either project, and nothing tries.** `imaging` has no bounding-box API
at all — the word `bounds` appears in the crate only as
`BlurredRoundedRect`'s own "Unblurred rectangle bounds" field and in a
validation error about invalid rectangles. `ImageRenderer::render_source` takes
`width` and `height` as arguments; Masonry's test harness computes them from
`window_size` plus a `root_padding` before calling the renderer
([`harness.rs`][harness]). Extent is an input, never an output.

The single exception points the same way as Vello's `Drawable::bbox`:
`VisualLayerKind::External { bounds }` carries a rect precisely because that
layer's content is realized by somebody else and its size cannot be recovered
from commands Masonry never recorded. **F7 holds**, and the case that needs a
content-bounds query remains the offscreen/intermediate one.

## Strengths

- **The contract is one trait declaration**, ten methods, optionality expressed
  as defaults — legible in a single screen, with four real backends behind it.
- **Authoring surface and backend surface are different types**, so ergonomics
  can grow without growing what a backend implements.
- **Recording is an implementation of the seam**, not a parallel mechanism —
  one vocabulary serves streaming, retention, replay-with-transform, validation
  and equality comparison.
- **Late-bound brushes decouple appearance from shaping**: a colour change is a
  different index table, not a relayout.
- **Refusal is enumerated and typed** (`RenderUnsupportedError`), so a golden
  test can demand a feature and be told no.
- **Semantics travel out-of-band**, interned lazily, and carry source locations
  — the display list is debuggable without any of it reaching the rasterizer.
- **Text layout is a shared value, not a shared formula**: the same cached
  `Layout` answers `measure`, `layout` and `paint`.

## Weaknesses

- **Three layers to learn** (`Painter`, `PaintSink`, `record::Scene`) where a
  smaller project would have one, plus a fourth in `ImageRenderer`.
- **`&mut dyn PaintSink` is the shipped path**, so the seam pays virtual
  dispatch per command; `sparkles:ui`'s structural typing keeps the static one.
- **Errors are deferred and coarse.** A sink that cannot draw something records
  it and keeps going; the caller learns at `finish()`, without knowing which
  command failed except through the context stack.
- **No cell target, and no unit vocabulary that could reach one.** Logical
  pixels are assumed everywhere; nothing here answers the survey's open question
  about spanning terminals and GPUs.
- **The documentation lags the seam** — the pass-system article still describes
  a Vello `Scene`.
- **`imaging` is 0.0.1**, published from a repository outside the Linebender
  organization; the survey is reading a design in motion.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                                 | Trade-off                                                                        |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Text layout in a separate crate with no renderer dependency | Shaping, fallback and bidi are their own discipline; every renderer needs the same answer | Consumers must own the `FontContext`/`LayoutContext` lifetime and pass it down   |
| `Layout<B: Brush>` with a blanket impl over owned types     | The layout stores appearance without interpreting it; no lifetime rides along             | Nothing constrains `B` to be meaningful — it is a bag the caller must decode     |
| Masonry sets `B = BrushIndex`                               | Colour changes repaint without relayout, and layouts stay comparable/cacheable            | Painting needs a matching table; an index/table mismatch is a runtime concern    |
| Ten-method `PaintSink` with two defaulted                   | One legible contract; optionality without probing                                         | Any new primitive is a breaking change to every backend                          |
| `Painter` as a separate generic authoring wrapper           | Widget ergonomics decoupled from backend obligations                                      | Two APIs to document; `as_dyn` bridges needed in generic code                    |
| `record::Scene` implements `PaintSink`                      | Retention, replay, goldens and caching need no second vocabulary                          | The retained form must mirror every borrowed payload (`*Ref` ↔ owned pairs)      |
| Commands are tag + id into typed arenas                     | No dead fields, random access preserved, strings interned once                            | Ids are only meaningful relative to their scene; composing scenes means rebasing |
| Sink methods return `()`; renderers return `Result`         | Draw calls stay ergonomic and infallible; failure is reported once per stream             | Failure loses per-command locality, recovered only via the context stack         |
| Semantic role as an ignorable context annotation            | Diagnostics and validation without burdening the rasterizer                               | Backends that _could_ use the role (an HTML emitter) must opt in themselves      |
| Extent supplied to the renderer                             | The surface knows its own size                                                            | Offscreen/content-sized consumers get no help, exactly as in Vello               |

## Bearing on the proposal

1. **Split the authoring API from the backend contract** (friction §2). The
   `PaintSink` / `Painter` pair is the cleanest available answer to "the concept
   describes five methods; the real contract is eight": make the _sink_ the
   enumerated concept and let helper functions supply everything else. This is
   compatible with keeping `isCanvas` structural — the point is that the concept
   should name the whole obligation and nothing more.
2. **Make `RecordingCanvas` the display list, not a debug affordance**
   (friction §4, F2). Masonry's `record::Scene` is a conforming backend that
   happens to retain, and every consumer that needs a value goes through it.
   Inverting `sparkles:ui`'s arrangement — seam first, `DrawOp[]` as one
   implementation — dissolves the "who defines the vocabulary" question that
   §2 and §4 are both symptoms of.
3. **Adopt a tag-plus-id command with typed side arenas** if the reified stream
   survives. It keeps random access (which Vello gives up) and eliminates dead
   fields (which the current `DrawOp` cannot), and it makes interning strings a
   property of the recorder rather than of the op.
4. **Replace `visual` + `slot` with an index into a palette, resolved at paint**
   (friction §6). `BrushIndex` is the design `sparkles:ui` is groping toward:
   the op carries a small, comparable handle; the painter is handed the table
   for this frame. A re-resolving backend gets the table it wants and a pixel
   backend gets a resolved colour, without every op carrying both.
5. **Move anything that is not appearance into an ignorable annotation channel**
   (friction §3). `ContextKindRef::{Widget, ChildIndex, Slot}` with default no-op
   handlers shows that a seam can carry semantics for diagnostics without those
   semantics becoming rendering instructions. Applied to `scrollbar`: the
   degradation decision may justify a semantic op, but widget identity and role
   do not belong on a draw.
6. **Make degradation refusable at the stream boundary, not per call** (F4).
   `RenderUnsupportedError`'s six variants plus a `finish() -> Result` is a
   working shape: keep the draw calls infallible, accumulate the first refusal,
   and let a golden test ask for a hairline and be told no.
7. **Give measurement a context, not a method — and cache the value, not the
   formula** (friction §1, F1). `text_contexts()` on every context type, plus a
   per-widget layout cache keyed by constraint that `measure`, `layout` and
   `paint` all read, is a stronger form of F1 than "move `measure` off the
   canvas": the point is that the measured artifact must be the painted one.
8. **`Layout<B: Brush>`'s blanket impl is the pattern for a backend-chosen
   payload** — an owned, `PartialEq`, `Default` type parameter with no lifetime.
   It is what lets Parley serve a GPU renderer and a terminal alike, and it is
   the shape any `sparkles:ui` text-measurement abstraction should copy if it
   must carry a backend payload at all.

## Sources

Read from shallow clones of [`linebender/parley`][parley-repo] at
`1aba7cacb2030dea204efa87ba55317c0a59964a` and [`linebender/xilem`][xilem-repo]
at `ce7b04d2ba2d9d7a8c364f2ab109e2083121e144` (`git rev-parse HEAD`); every path
below was verified at those SHAs with `git cat-file -e`. The `imaging` and
`imaging_skia` crates are not in either tree — they were read from the crates.io
source archives for version `0.0.1`, whose sha256 digests match the entries in
Xilem's [`Cargo.lock`][lock]; their API is cited against
[`docs.rs/imaging/0.0.1`][imaging-docs], which is version-pinned.

- **Parley** — [`README.md`][parley-repo] (the four-crate stack), [`doc/design.md`][parley-design] (motivation), [`parley/src/lib.rs`][parley-lib] (the usage protocol), [`context.rs`][parley-context] (`LayoutContext` as scratch space, the `quantize` contract), [`style/brush.rs`][brush], [`layout/layout.rs`][parley-layout] (`width`, `height`, `calculate_content_widths`, `break_all_lines`, `align`), [`layout/mod.rs`][parley-mod] (`Style`, `Decoration`, `ContentWidths`), [`layout/line.rs`][line] (`GlyphRun`), [`layout/cluster.rs`][cluster] and [`editing/cursor.rs`][cursor] (hit-testing), [`editing/selection.rs`][selection]
- **Masonry's seam** — [`core/widget.rs`][widget] (`pre_paint`/`paint`/`post_paint`, the logical-pixel `layout` contract), [`core/contexts.rs`][contexts] (`text_contexts`), [`core/text.rs`][mc-text] (`BrushIndex`, `render_text`, `ArcStr`), [`passes/paint.rs`][paint-pass] (per-widget scene cache), [`app/visual_layers.rs`][layers], [`core/paint_layer.rs`][paint-layer], [`layout/len_req.rs`][lenreq], [`masonry_core/src/lib.rs`][mc-lib], [`doc/pass_system.md`][pass-system] (the stale Vello-`Scene` description)
- **Widgets** — [`widgets/label.rs`][label] (measure/layout/paint over one cached `Layout`), [`widgets/text_area.rs`][textarea] (`selection_geometry`), [`doc/implementing_widget.md`][implw]
- **Backends** — [`masonry_imaging/src/lib.rs`][mi-lib] (the four feature-gated backends), [`skia.rs`][mi-skia], [`vello.rs`][mi-vello], [`masonry_testing/src/harness.rs`][harness] (extent supplied to `render_source`)
- **The `imaging` crate (v0.0.1)** — [`PaintSink`][paintsink], [`Painter`][painter], [`FillRef`][fillref], [`GlyphRunRef`][glyphrunref], [`record::Command`][record], [`record::Scene`][scene], [`render::RenderSource`][rendersource], [`render::ImageRenderer`][imagerenderer], [`render::RenderUnsupportedError`][unsupported]; `imaging_skia` v0.0.1 `src/sinks.rs` for the deferred-error backend pattern
- **Siblings in this tree** — [`vello.md`][vello] (the encoding seam by the same authors), [`slint.md`][slint], [`egui.md`][egui], [`comparison.md`][comparison]

<!-- References -->

[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[comparison]: ./comparison.md
[vello]: ./vello.md
[slint]: ./slint.md
[egui]: ./egui.md
[parley-rev]: https://github.com/linebender/parley/tree/1aba7cacb2030dea204efa87ba55317c0a59964a
[xilem-rev]: https://github.com/linebender/xilem/tree/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144
[parley-repo]: https://github.com/linebender/parley/blob/1aba7cacb2030dea204efa87ba55317c0a59964a/README.md
[parley-design]: https://github.com/linebender/parley/blob/1aba7cacb2030dea204efa87ba55317c0a59964a/doc/design.md
[parley-lib]: https://github.com/linebender/parley/blob/1aba7cacb2030dea204efa87ba55317c0a59964a/parley/src/lib.rs
[parley-context]: https://github.com/linebender/parley/blob/1aba7cacb2030dea204efa87ba55317c0a59964a/parley/src/context.rs
[brush]: https://github.com/linebender/parley/blob/1aba7cacb2030dea204efa87ba55317c0a59964a/parley/src/style/brush.rs
[parley-layout]: https://github.com/linebender/parley/blob/1aba7cacb2030dea204efa87ba55317c0a59964a/parley/src/layout/layout.rs
[parley-mod]: https://github.com/linebender/parley/blob/1aba7cacb2030dea204efa87ba55317c0a59964a/parley/src/layout/mod.rs
[line]: https://github.com/linebender/parley/blob/1aba7cacb2030dea204efa87ba55317c0a59964a/parley/src/layout/line.rs
[cluster]: https://github.com/linebender/parley/blob/1aba7cacb2030dea204efa87ba55317c0a59964a/parley/src/layout/cluster.rs
[cursor]: https://github.com/linebender/parley/blob/1aba7cacb2030dea204efa87ba55317c0a59964a/parley/src/editing/cursor.rs
[selection]: https://github.com/linebender/parley/blob/1aba7cacb2030dea204efa87ba55317c0a59964a/parley/src/editing/selection.rs
[xilem-repo]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/ARCHITECTURE.md
[lock]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/Cargo.lock
[widget]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry_core/src/core/widget.rs
[contexts]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry_core/src/core/contexts.rs
[mc-text]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry_core/src/core/text.rs
[paint-pass]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry_core/src/passes/paint.rs
[layers]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry_core/src/app/visual_layers.rs
[paint-layer]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry_core/src/core/paint_layer.rs
[lenreq]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry_core/src/layout/len_req.rs
[mc-lib]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry_core/src/lib.rs
[pass-system]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry_core/src/doc/pass_system.md
[label]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry/src/widgets/label.rs
[textarea]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry/src/widgets/text_area.rs
[implw]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry/src/doc/implementing_widget.md
[mi-lib]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry_imaging/src/lib.rs
[mi-skia]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry_imaging/src/skia.rs
[mi-vello]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry_imaging/src/vello.rs
[harness]: https://github.com/linebender/xilem/blob/ce7b04d2ba2d9d7a8c364f2ab109e2083121e144/masonry_testing/src/harness.rs
[imaging-docs]: https://docs.rs/imaging/0.0.1/imaging/
[paintsink]: https://docs.rs/imaging/0.0.1/imaging/trait.PaintSink.html
[painter]: https://docs.rs/imaging/0.0.1/imaging/struct.Painter.html
[fillref]: https://docs.rs/imaging/0.0.1/imaging/struct.FillRef.html
[glyphrunref]: https://docs.rs/imaging/0.0.1/imaging/struct.GlyphRunRef.html
[record]: https://docs.rs/imaging/0.0.1/imaging/record/enum.Command.html
[scene]: https://docs.rs/imaging/0.0.1/imaging/record/struct.Scene.html
[rendersource]: https://docs.rs/imaging/0.0.1/imaging/render/trait.RenderSource.html
[imagerenderer]: https://docs.rs/imaging/0.0.1/imaging/render/trait.ImageRenderer.html
[unsupported]: https://docs.rs/imaging/0.0.1/imaging/render/enum.RenderUnsupportedError.html
[skia-sinks]: https://docs.rs/imaging_skia/0.0.1/imaging_skia/
[parley-docs]: https://docs.rs/parley
[masonry-docs]: https://docs.rs/masonry
