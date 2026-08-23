# Vello — the seam is a buffer layout, not a call

**Category:** encoding, not commands. **Last reviewed:** August 23, 2026.
Pinned at [`3fabef93`][rev].

The one subject whose renderer seam is neither virtual methods nor command
values: a [`Scene`][scene] is a group of parallel, append-only `Vec`s consumed
by a chain of compute shaders. It is the strongest available test of whether "a
drawing command" is the right unit for a backend boundary at all — and it is the
one subject that shipped a fixed-width element record, wrote down why it stopped,
and replaced it with something that is neither a record nor a sum. Section
numbers below (§1-§8) refer to [`canvas-seam-friction.md`][friction]; F1-F12
refer to the findings in [`comparison.md`][comparison].

| Field                | Value                                                                                                                                  |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**         | Rust (edition 2024, MSRV 1.88)                                                                                                         |
| **License**          | Apache-2.0 OR MIT                                                                                                                      |
| **Repository**       | [`linebender/vello`][repo]                                                                                                             |
| **Documentation**    | [`docs.rs/vello`][docs], plus in-tree [`doc/ARCHITECTURE.md`][arch] and [`doc/pathseg.md`][pathseg]                                    |
| **Category**         | encoding, not commands                                                                                                                 |
| **Pinned revision**  | `3fabef9315914fc2fa32eed12afac8922785396b` (workspace version `0.10.0`)                                                                |
| **Seam under study** | [`vello_encoding::Encoding`][encoding] — six parallel streams plus late-bound `Resources`                                              |
| **Backends shipped** | one compute pipeline over `wgpu` ([`WgpuEngine`][recording]); the separate `sparse_strips/` family adds `vello_cpu` and `vello_hybrid` |
| **Target range**     | GPUs with compute-shader support; `vello_cpu` is `no_std`-capable CPU rasterization                                                    |

## Overview

### What it solves

Vello renders the same imaging model as Skia and Cairo — filled and stroked
Bézier paths, gradients, images, clips, blends, text — but moves the sequential
parts of that pipeline onto the GPU:

> Vello's selling point is that it gets better performance than other renderers
> by better leveraging the GPU. In traditional PostScript-style renderers, some
> steps of the render process like sorting and clipping either need to be
> handled in the CPU or done through the use of intermediary textures. Vello
> avoids this by using prefix-sum algorithms to parallelize work that usually
> needs to happen in sequence
>
> — [`README.md`][repo]

That sentence is the whole seam argument. A prefix sum is defined over a flat
array of monoid elements, so the scene must _be_ a flat array of monoid
elements. [`vello_encoding::Monoid`][monoid] is a real trait in the crate:

```rust
pub trait Monoid: Default {
    type SourceValue;
    fn new(value: Self::SourceValue) -> Self;
    #[must_use]
    fn combine(&self, other: &Self) -> Self;
}
```

Two types implement it: `PathMonoid`, whose `SourceValue` is a packed `u32`
holding **four** path tags at once and whose fields are `trans_ix`,
`pathseg_ix`, `pathseg_offset`, `style_ix` and `path_ix`; and `DrawMonoid`,
whose `SourceValue` is a `DrawTag`. Scanning the tag stream is therefore how a
consumer learns where every element's data lives. The seam's shape is dictated
by the algorithm that consumes it, not by what reads nicely at a call site.

### Design philosophy

[`doc/pathseg.md`][pathseg] records the move away from a fixed-size command
record, in terms that bear directly on the width half of `DrawOp`'s budget:

> By way of motivation, in the old scene encoding, all elements take a fixed
> amount of space, currently 36 bytes, but that's at risk of expanding if a new
> element type requires even more space. The new design is based on stream
> compaction. The input is separated into multiple streams, so in particular
> path segment data gets its own stream. Further, that stream can be packed.

Vello hit the second half of friction §4 — an element whose width is set by its
greediest member — and answered it not with a closed sum but by splitting the
record into per-field streams, each entry's payload variable-width and
recoverable by prefix sum over the tag byte alone.

> [!NOTE]
> `doc/pathseg.md` is dated November 2021 and has drifted in one detail: it
> describes tag bit 6 as "a line width setting", whereas
> [`PathTag::STYLE`][path] (`0x40`) now carries a whole `Style` (fill rule, or
> stroke width plus caps, join and miter limit). The stream architecture it
> describes is current; the field list is not.

## How it works

`Scene` is a thin wrapper over [`Encoding`][encoding], which is the seam:

```rust
pub struct Encoding {
    /// The path tag stream.
    pub path_tags: Vec<PathTag>,
    /// The path data stream.
    pub path_data: Vec<u32>,
    /// The draw tag stream.
    pub draw_tags: Vec<DrawTag>,
    /// The draw data stream.
    pub draw_data: Vec<u32>,
    /// The transform stream.
    pub transforms: Vec<Transform>,
    /// The style stream
    pub styles: Vec<Style>,
    /// Late bound resource data.
    pub resources: Resources,
    // … plus n_paths, n_path_segments, n_clips, n_open_clips, flags
}
```

Three properties follow from that declaration.

**Tags are indices, not payloads.** [`PathTag`][path] is a single `u8`: low
three bits the segment type, bit 2 end-of-subpath, bit 3 `i16`-vs-`f32`
coordinates, bits 4-6 one-hot for the `PATH` (`0x10`), `TRANSFORM` (`0x20`)
and `STYLE` (`0x40`) markers. A prefix sum over that stream yields, for every
element at once, its offset into `path_data` and its index into `transforms`
and `styles`. [`DrawTag`][draw] is a `u32` whose value _encodes its own payload
size_ — `info_size()` is `(self.0 >> 6) & 0xf`, so `DrawTag::COLOR` is one word
and `DrawTag::BLUR_RECT` is five. An entry occupies exactly the words it uses.

**Redundant state is elided at encode time.** `encode_transform` and
`encode_style` compare against the stream's last entry and push nothing when it
matches, unless the caller has set `FORCE_NEXT_TRANSFORM`/`FORCE_NEXT_STYLE`.
The seam therefore performs a small compression pass that a per-op record
cannot: identical consecutive state is simply absent from the stream.

**The vocabulary is smaller than a display list's.** [`Scene`][scene]'s whole
drawing surface is `fill`, `stroke`, `draw_image`, `draw_glyphs`,
`draw_blurred_rounded_rect`(`_in`), `push_layer`, `push_clip_layer`,
`push_luminance_mask_layer`, `pop_layer` — and `draw_image` is a `fill` of the
image's natural rect with an image brush, while `stroke` normally encodes the
path unexpanded so expansion happens on the GPU. There is no rectangle, line or
rule primitive: `kurbo` shapes flatten into the same path stream.

Below the encoding sits a **second seam** that _is_ a reified command list —
[`vello::recording::Command`][recording], a Rust enum of `Upload`, `Dispatch`,
`Download`, `FreeBuffer` and friends, which
[`doc/ARCHITECTURE.md`][arch] describes as the layer "other backends could
consume". One repository, two boundaries, two different shapes, each chosen by
what the consumer does with it. That is the single most transferable
observation in this deep-dive.

## Q1 — measurement units, and who answers

**Vello has no text measurement API and no text layout at all.** The unit
question does not arise because the seam never sees a string.
[`Glyph`][glyph] is the entire text vocabulary:

```rust
pub struct Glyph {
    /// Glyph identifier.
    pub id: u32,
    /// X-offset in run, relative to transform.
    pub x: f32,
    /// Y-offset in run, relative to transform.
    pub y: f32,
}
```

Shaping and layout are somebody else's job, stated explicitly in-tree — the
minimal helper in `examples/scenes` opens with "A minimal text infrastructure,
which SHOULD not be used for production use cases. Most users should prefer to
use [Parley], which is a full text layout library"
([`simple_text.rs`][simple-text]; the link in the original points at
[`linebender/parley`][parley]). The real example scenes do exactly
that: `parley::Layout` produces `PositionedLayoutItem`s, and only positioned
glyph ids cross into the renderer ([`text.rs`][scenes-text]).

This is the most extreme version of the survey's F1. [Slint][slint] splits
measurement onto a separate `TextShaper` trait; egui pre-resolves into a `Galley`; Vello
deletes the concern from the renderer entirely and accepts that a caller
without a shaper cannot draw text.

The nuance worth carrying: measurement and rendering still need to _share_
state, and the new [`glifo`][glifo] crate says so in its goals — "Share
expensive structs and data between the shaper and renderer like the hinting
instance and hinted advance". Splitting measurement off the painter is not the
same as putting a wall between them; the hinting instance that produces the
advance is the one that must produce the outline, or the two disagree.

## Q2 — where the contract is stated

**In a struct definition, and it is fully public.** `Encoding`'s fields are all
`pub`; `Scene::encoding_mut` hands out `&mut Encoding` with the warning that it
"can be used to more easily create invalid scenes, and so should be used with
care"; and `impl From<Encoding> for Scene` lets a producer build the buffers
directly. The contract is the buffer layout plus the doc-comment invariant on
`Encoding` — "At least one transform and style must be encoded before any path
data or draw object" — and that invariant is not enforced by any type.

There is no capability query and nothing to probe. The nearest thing is
[`AaSupport`][lib] (`area` / `msaa8` / `msaa16`), and it inverts Qt's model: it
is the _application_ declaring at `Renderer` construction which anti-aliasing
methods to compile shaders for, with `RenderParams::antialiasing_method`
required to name one that was enabled. It is a build-time opt-in, not a runtime
"can you do this?".

The cost of an implicit contract is documented as felt. `doc/ARCHITECTURE.md`
on the CPU fallback: "Every single WGSL shader needs a CPU equivalent, which is
pretty cumbersome." When the seam is a buffer layout consumed by one specific
algorithm, a second backend does not implement a painter — it reimplements the
pipeline. That is why the `sparse_strips/` renderers are a **parallel
architecture** rather than a second backend behind the same seam:
`vello_common`'s crate docs note that "Vello CPU is being developed as part of
work to address shortcomings in Vello" and that "Vello does not use this crate"
([`vello_common/src/lib.rs`][common]).

## Q3 — semantic operations or primitives

Overwhelmingly primitive — everything is a path — with **two deliberate
exceptions that are exactly the cases a backend must own**:

- **`draw_blurred_rounded_rect`** does not build a blurred shape. It encodes an
  ordinary path (the rect inflated by `2.5 * std_dev`, the point at which "the
  response is close to zero") and attaches `DrawTag::BLUR_RECT` carrying
  `width`, `height`, `radius` and `std_dev`, so the analytic approximation runs
  in the fine-rasterization shader. The semantics survive into the encoding
  because the alternative — a rasterized blur — is a different and worse
  algorithm.
- **`glifo`'s `GlyphRunBackend::render_decoration`** takes a glyph iterator, an
  `x_range`, a `baseline_y`, an `offset`, a `size` and a `buffer`, and is
  documented as rendering "a decoration (e.g. underline) with skip-ink
  behavior". An underline is geometrically a rectangle; it reaches the seam as
  an _underline_ because computing the ink gaps requires the glyph outlines the
  backend already has.

The rule this suggests is sharper than "semantic or primitive": an operation
stays semantic precisely when lowering it would require the caller to know
something only the backend knows — the fine-rasterizer's analytic blur, the
outlines behind skip-ink. That is [F4][comparison]'s axis — where the lowering
lives — argued from the backend's side. `sparkles:ui`'s `scrollbar` op sits on
both sides of the test at once: the rail geometry comes from `scrollbarThumb` in
`sparkles.ui.state`, the one formula every backend renders, while the
cell-vs-pixel degradation is genuinely backend knowledge. Friction §3's defect is
that the op carries both, so `trackGlyph` and `thumbGlyph` — a cell backend's
answer — ride past every backend that will never read them.

## Q4 — command shape

**Neither a sum type nor a tagged record — a struct-of-streams**, and
[`doc/pathseg.md`][pathseg] states the tagged record was the thing being
escaped. The comparison is worth making precisely:

| Property       | `sparkles:ui` `DrawOp`                        | Vello `Encoding`                            | Vello `Command`                                |
| -------------- | --------------------------------------------- | ------------------------------------------- | ---------------------------------------------- |
| Shape          | closed sum over eight payloads                | 6 parallel streams + late-bound `Resources` | Rust `enum`, 10 variants (+1 behind a feature) |
| Per-entry cost | one width for all eight arms, budget 64 bytes | tag byte + exactly the words used           | per-variant                                    |
| Dead fields    | none inside an arm; padding to the widest     | none                                        | none                                           |
| Consumer       | a painter `match!`ing over a slice            | a prefix sum over a tag stream              | a GPU engine                                   |
| Random access  | yes                                           | only after the prefix sum                   | yes                                            |

The same repository chose the enum where the consumer walks sequentially and
dispatches, and the streams where the consumer is data-parallel. That is
[F3][comparison]'s trade seen from both sides in one project: `sparkles:ui`'s
`DrawOp` and Vello's `Command` are the same shape for the same reason — a
consumer that walks once and dispatches — while `Encoding` is the variable-stride
alternative F3 names, and Vello picks it only where the consumer is a prefix sum.
The evidence does not decide the encoding question; it says the consumer decides
it, and `sparkles:ui`'s consumers are `RecordingCanvas`, the op-stream parity
harness, and a painter walking a slice once. Two `Encoding` properties are worth
wanting regardless of shape: an entry costs what it uses
(`DrawTag::info_size`), and identical consecutive state is written once rather
than per operation.

## Q5 — sub-unit placement

Not a problem Vello has; coordinates are `f64` in `kurbo` at the API and `f32`
in the encoding, and the anti-aliased rasterizer is the answer to "thinner than
a unit". The interesting move is that the encoding nonetheless makes precision
a **per-entry** property rather than a property of the vocabulary: bit 3 of a
[`PathTag`][path] selects whether a segment's coordinates are `f32` or 16-bit
integral (`LINE_TO_I16`, `QUAD_TO_I16`, `CUBIC_TO_I16`), and the word-count
arithmetic in `PathMonoid::new` — and in the WGSL that mirrors it — already
accounts for that bit.

> [!NOTE]
> The `I16` variants are declared and budgeted for but appear unused at this
> revision: no in-tree encoder constructs them, and `PathTag::is_f32` has no
> caller in the Rust tree. Read this as reserved capacity in the format, not as
> a shipping optimization.

The transferable point for friction §5 is that a seam whose only spelling for
"thinner than a cell" is a six-valued compass has made precision a property of
the _vocabulary_; a format that budgets a precision bit per entry can add
resolution later without adding enumerators.

## Q6 — resolved or semantic styling

**Fully resolved, and resolved early.** `encode_color` reduces any colour to
one premultiplied sRGB `u32`; a gradient becomes a ramp handle plus geometry,
with degenerate cases collapsed at encode time (one stop becomes
`DrawTag::COLOR`; a zero-extent radial or sweep gradient becomes transparent).
`Style` packs fill rule or stroke caps/join/miter into one `u32` plus an `f32`
width. No semantic role travels, and nothing downstream could re-resolve
because nothing is left to re-resolve from.

That is [F9][comparison]'s majority position, and it prices friction §6 exactly.
`sparkles:ui` stores the resolved half too — an `Ink` on the four content
primitives, `FillRect`'s own colour fields beside a `BoxChrome` pointer that is
null unless the box has a border, shadow, radius or arrow — and stores a `Slot`
alongside it on six of the eight payloads, because the HTML interpreter resolves
from the role to emit class names while the pixel backends read the colours.
Vello shows what the resolved half alone buys: a colour reduced to one
premultiplied word at encode time, and a downstream that needs no theme to paint.
It also shows the boundary of that bargain — a scene with no role in it can only
ever be painted, never restyled, which is the trade a second, role-reading
consumer makes unavailable. Deriving `Visual` on demand from what each payload
keeps makes carrying both cheaper; only dropping one of the two halves makes it a
decision.

The wider repository shows both sides of a second axis, though. `Scene` is
**stateless** — `fill(style, transform, brush, brush_transform, shape)` passes
everything per call — while the sparse-strips `RenderContext` is a
**stateful, PostScript-style** context with `set_paint`, `set_transform`,
`set_stroke`, `set_fill_rule`, `set_paint_transform`, `set_blend_mode` and
`save_current_state` / `restore_state` ([`render.rs`][cpu-render]). Two APIs in
one workspace over the same imaging model. Statelessness is what makes
`Scene::append` sound; the state machine is what makes a `RenderingContext`
trait implementable across two dissimilar renderers.

## Q7 — payload ownership and lifetime

**The strongest answer in the survey so far: the scene owns everything and is
`Send + Sync`**, asserted in the type system —
`static_assertions::assert_impl_all!(Scene: Send, Sync);` at
[`scene.rs`][scene] line 50. There are no borrowed slices in an `Encoding`;
`Resources` owns its `patches`, `color_stops`, `glyphs`, `glyph_runs` and
`normalized_coords` outright, and font data arrives as a `peniko::Blob`, which
is `Arc`-backed.

Two mechanisms make that affordable. **Late binding via patches:** a gradient,
image or glyph run pushes a `Patch` recording a `draw_data_offset` (or a
`Range<usize>` into a resource vector) instead of expanding the payload inline,
and at render time the [`Resolver`][resolve] walks the patches, consults its
`RampCache`, `ImageCache` and `GlyphCache`, and packs the final byte buffer —
ownership sitting with the long-lived resolver, which is [Slint][slint]'s
`draw_cached_pixmap` bargain in another idiom. **A cached glyph is itself an
`Encoding`:** `GlyphCache` stores `Arc<Encoding>` per glyph key and resolution
splices those sub-encodings into the parent stream at the recorded
`StreamOffsets`, so the seam is compositional — an encoding is a value that can
be built once, shared, and embedded in another.

Replay is first-class. `Scene::append(&other, transform)` — "Appends a child
scene. The given transform is applied to every transform in the child. This is
an O(N) operation" — concatenates every stream and rebases the offsets in each
copied `Patch` and `GlyphRun`. A subtree can be encoded once and stamped many
times. Rendering does not consume a scene, either: "Rendering from a `Scene`
will _not_ clear it, which should be done in a separate step, by calling
`Scene::reset`", with an explicit warning that a retained scene which is never
reset "will likely quickly increase the complexity of the render result,
leading to crashes or potential host system instability".

This is the answer friction §7 is missing. `sparkles:ui` is on the same side of
[F8][comparison] as every other subject — [`DrawOp.text`][canvas] is a
`const(char)[]` that `CmdBuffer.textRun` **copies** into a frame arena, so a
`scope` source is safe and no caller's buffer is captured. What the arena does not
supply is a boundary: the rule is that an operation is valid while the buffer
that built it is alive and unreset, so the op cannot cross a thread and cannot
outlive the reset, and `dip1000` has to be talked out of confining it further
still. An `Encoding` is owned, `Send + Sync`, appendable, transformable and
replayable, and the price it pays for that is one copy of the text's _positioned
glyph ids_ — the same copy, with none of the constraint. `UI-O4` is open on
exactly this boundary.

## Q8 — can the scene report its extent?

**No, and the encoding cannot even in principle.** `RenderParams` carries
`width` and `height` as caller-supplied fields; `RenderConfig::new(layout,
width, height, base_color)` takes the resolved scene layout and the target
dimensions as separate arguments. Nothing in `vello_encoding` computes a scene
bounding box on the CPU — `DrawBbox` is filled in by a GPU stage.

[`estimate.rs`][estimate] says why, in a comment about what the scene cannot
know while it is being built:

> Accounting for viewport clipping (for the right and bottom edges of the
> viewport) is simply impossible at insertion time as the render target
> dimensions are unknown.

What the scene _can_ answer is a different question: `Scene::bump_estimate`
returns a `BumpAllocatorMemory`, a conservative estimate of the GPU bump
buffers this content needs. The scene is asked "how much will you cost", never
"how big are you".

The sparse-strips family separates [F7][comparison]'s three questions cleanly,
inside one repository. Its recording layer defines

```rust
pub trait Drawable {
    /// Return the **tile-aligned** bounding box of the given object, if it
    /// has one.
    fn bbox(&self, strips: &[Strip]) -> Option<RectU16>;
}
```

and gives every `RecordedLayer` a tile-aligned `bbox`, because — per
[`record.rs`][record] — "Vello Hybrid needs to render _every_ layer separately.
Its scheduler therefore needs the complete layer hierarchy and bounds before it
can allocate intermediate textures", and "filter layers might have different
dimensions than the main viewport". So extent-from-content is not a nicety a
scene can decline; it is mandatory the moment anything renders to an
**intermediate** surface rather than to the window. Surface extent is an input
here and ink extent is derived by a scan — F7's maintained-versus-derived axis,
with the root window on one side and every offscreen layer on the other. That
second case is precisely the one `skia-canvas-render.d` hit.

Note also that the sparse-strips context is _constructed_ with its extent
(`RenderContext::new(width, height)`, with `width()`/`height()` on the shared
`RenderingContext` trait). Extent is an input to the scene there, not an output
of it.

## Strengths

- **Nothing is dead.** A payload size derived from the tag means the encoding
  grows by exactly what a new draw kind needs, not by widening every entry.
- **Owned, `Send + Sync`, appendable, replayable.** A scene is a value: build
  once, transform, stamp repeatedly, render without consuming, reset
  explicitly. No lifetime rides along with a payload.
- **Compositional at the seam's own level** — a cached glyph is an `Encoding`
  spliced into an `Encoding`, so reuse needs no second concept.
- **State deduplication is free and invisible**, because transforms and styles
  are compared against the stream tail at encode time.
- **Late binding separates construction from residency** — the `Resolver` owns
  the caches, the scene owns only offsets.
- **The seam's shape is derived, not chosen by taste**: prefix-sum consumption
  forces the stream layout, and the repository says so.

## Weaknesses

- **A second backend is a second pipeline.** There is no painter interface to
  implement; "every single WGSL shader needs a CPU equivalent, which is pretty
  cumbersome", and the CPU/hybrid renderers were built as a separate
  architecture rather than as backends.
- **The contract is a public struct with an unenforced invariant** — all fields
  `pub`, `encoding_mut` documented as a way to "create invalid scenes", the
  ordering rule living only in a doc comment.
- **No random access and no editing.** Reading entry _n_ requires the prefix
  sum; there is `reset`-and-build-again or `append`, and nothing else.
- **Debuggability is bytes** — six buffers of packed `u32`, with no `serde`
  support in `vello_encoding` at this revision.
- **Text is entirely the caller's problem**, including which shaper's advances
  the renderer's hinting must agree with.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                                          | Trade-off                                                                               |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Parallel streams instead of a fixed-size element record       | Fixed records waste space and widen as kinds are added; streams compact and prefix-sum in parallel | No random access, no in-place edit, hostile to inspection                               |
| Tag byte encodes its own payload size (`DrawTag::info_size`)  | Unpacking needs only the tag, so it is data-parallel                                               | Sizes are magic constants (`COLOR = 0x44`, `BLUR_RECT = 0x2d4`) that must stay in sync  |
| Late-bound `Patch` + `Resolver` caches                        | Scene construction stays cheap and thread-safe; residency is the renderer's problem                | Two-phase build; a scene alone is not renderable                                        |
| Owned scene, `Send + Sync`, non-consuming render              | Enables `append`, retained scenes, cross-thread submission                                         | A retained scene that is never `reset` grows without bound — documented as a crash risk |
| No text layout, only positioned `Glyph`s                      | Shaping is a separate discipline; keeps the renderer font-policy-free                              | Callers must supply a shaper whose advances agree with the renderer's hinting           |
| Almost-pure path vocabulary, two semantic exceptions          | Blur and skip-ink underline need backend knowledge to be correct or fast                           | The line between primitive and semantic is a judgement, not a rule                      |
| Extent supplied to the renderer, never derived from the scene | Viewport is unknowable at insertion time                                                           | Any offscreen/intermediate consumer must recompute bounds — which `sparse_strips` does  |
| A second, enum-shaped seam below the encoding                 | Its consumer dispatches sequentially, so an enum fits                                              | Two boundary vocabularies to learn in one project                                       |

## Bearing on the proposal

1. **The fixed-width element record has a documented obituary.** Cite
   [`doc/pathseg.md`][pathseg] against the second half of friction §4: the
   objection is not aesthetic but budgetary — every entry pays for the widest
   kind, and each new kind widens it, which is why a `popClip` that carries
   nothing costs what a `TextRun` costs. `sparkles:ui` feels the same pressure
   from the same direction: `Scrollbar` carries fourteen fields, and the budget
   holds only because `TextRun` is still the widest arm. **But do not read Vello
   as endorsing variable stride for us**: it chose streams because its consumer
   is a prefix sum, so [F3][comparison] stays a consumer-driven choice rather
   than a ranking. Adopt the two properties that _are_ universal — an entry
   costs what it uses, and identical consecutive state is written once.
2. **Ownership: `Encoding` is the shape `UI-O4` is looking for.** The frame
   arena already supplies the copy [F8][comparison] says every subject makes;
   what it does not supply is a stream that outlives the buffer that built it.
   An owned, `Send + Sync` op stream with `append(other, transform)` and an
   explicit `reset` answers friction §7 without either interning or
   reference-counting a payload, and it is what makes M7/T5's
   record-on-one-thread, submit-on-another a matter of moving a value rather
   than of arguing about a lifetime.
3. **Adopt sub-scene composition.** `Arc<Encoding>` per cached glyph, spliced
   into the parent stream, shows that the display list should be able to embed
   another display list. `DrawOp.translate(dx, dy)` is already the stamping
   half of that — a recorded op-slice replayed at an offset would serve repeated
   chrome and cached subtrees without a second concept, once the ops may outlive
   their builder.
4. **[F7][comparison] holds, and Vello supplies both of its halves.** Surface
   extent is an input the scene cannot derive (`RenderParams` carries it; the
   viewport is unknowable at insertion time); ink extent is derived by scan and
   is mandatory for offscreen work (`Drawable::bbox`, `RecordedLayer::bbox`
   exist because a scheduler must size intermediate textures). Friction §8's
   requirement is the second one: a **content-bounds query for offscreen
   consumers**. Folding `op.rect` over a built stream is the derived-by-scan
   answer and is available to any caller; the open question is whether
   `CmdBuffer` should maintain the bounds as it builds instead.
5. **Semantic ops: keep the two that only a backend can lower.** The test
   `draw_blurred_rounded_rect` and `render_decoration` pass — the caller cannot
   compute the result without backend-private data — is a usable rule for
   friction §3, and it is [F4][comparison]'s "where does the lowering live"
   stated as a decision procedure. Applied to `scrollbar`, it says: keep the op
   for the degradation decision, and let a backend reach the geometry through
   the lowerings `canvas.d` re-exports — `scrollbarCellCount`, `scrollbarCell`,
   `ruleEndpoints` — rather than carrying rail extents and two cell-backend
   glyphs on every operation.
6. **Q1 gains a caveat.** F1 (measurement does not belong on the painter) is
   confirmed in its strongest form — Vello has no `measure` at all. But
   [`glifo`][glifo]'s stated goal of sharing "the hinting instance and hinted
   advance" between shaper and renderer warns that a font abstraction which
   only _returns a number_ is not enough; the measurer and the painter must be
   able to share resolved font state, or they will disagree at hinted sizes.
7. **The cost of an implicit contract is a whole pipeline.** Vello is the case
   where leaving the contract implicit made a second backend a second
   architecture. Friction §2 is the milder form of the same bill: `isCanvas`
   names five methods, while `rule`, `scrollbar` and the clip pair are probed
   with `__traits(compiles)` at each interpreter call site, so a backend author
   cannot read the real surface off the concept. The mechanism is not the
   problem — [F5][comparison] finds optional capability cheap everywhere, and
   the probe-and-degrade bargain works. [F11][comparison] is: state the surface,
   floor and optional together in one place, and let the call sites derive from
   it.

## Sources

Read from a clone of [`linebender/vello`][repo] pinned at
`3fabef9315914fc2fa32eed12afac8922785396b` (`git rev-parse HEAD` after
`git clone --depth 1`); every path below was verified to exist at that SHA with
`git cat-file -e`.

- **The seam** — [`vello_encoding/src/encoding.rs`][encoding] (the `Encoding` struct, `append`, transform/style deduplication, brush and clip encoding, `Resources`, `StreamOffsets`), [`path.rs`][path] (`PathTag` bits, `Style` packing), [`draw.rs`][draw] (`DrawTag`, `info_size`), [`monoid.rs`][monoid], [`glyph.rs`][glyph]
- **Resolution and configuration** — [`resolve.rs`][resolve] (`Layout`, `Resolver`, patch resolution, `Arc<Encoding>` glyph splicing), [`config.rs`][config], [`estimate.rs`][estimate] (the viewport-unknowable comment)
- **The public API** — [`vello/src/scene.rs`][scene] (`Scene`, the `Send + Sync` assertion, `append`, `draw_blurred_rounded_rect`, `DrawGlyphs`), [`vello/src/lib.rs`][lib] (`RenderParams`, `AaSupport`), [`vello/src/recording.rs`][recording] (the `Command` enum)
- **Design documents** — [`doc/ARCHITECTURE.md`][arch] (intermediary layers, CPU-rendering cost), [`doc/pathseg.md`][pathseg] (the stream-compaction rationale), [`README.md`][repo]
- **Text** — [`glifo/src/lib.rs`][glifo] and [`glifo/src/glyph.rs`][glifo-glyph] (`GlyphRunBackend`, `render_decoration`, shaper/renderer shared state), [`examples/scenes/src/simple_text.rs`][simple-text] and [`sparse_strips/vello_example_scenes/src/text.rs`][scenes-text] (Parley as the layout layer)
- **The sparse-strips family** — [`vello_common/src/record.rs`][record] (`Drawable::bbox`, `RecordedLayer`), [`vello_common/src/lib.rs`][common], [`vello_cpu/src/render.rs`][cpu-render] (the stateful `RenderContext`), [`vello_example_scenes/src/lib.rs`][scenes-lib] (the `RenderingContext` trait)

<!-- References -->

[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[comparison]: ./comparison.md
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
[slint]: ./slint.md
[rev]: https://github.com/linebender/vello/tree/3fabef9315914fc2fa32eed12afac8922785396b
[repo]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/README.md
[docs]: https://docs.rs/vello
[arch]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/doc/ARCHITECTURE.md
[pathseg]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/doc/pathseg.md
[encoding]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/vello_encoding/src/encoding.rs
[path]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/vello_encoding/src/path.rs
[draw]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/vello_encoding/src/draw.rs
[monoid]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/vello_encoding/src/monoid.rs
[resolve]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/vello_encoding/src/resolve.rs
[glyph]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/vello_encoding/src/glyph.rs
[estimate]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/vello_encoding/src/estimate.rs
[config]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/vello_encoding/src/config.rs
[scene]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/vello/src/scene.rs
[lib]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/vello/src/lib.rs
[recording]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/vello/src/recording.rs
[glifo]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/glifo/src/lib.rs
[glifo-glyph]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/glifo/src/glyph.rs
[record]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/sparse_strips/vello_common/src/record.rs
[common]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/sparse_strips/vello_common/src/lib.rs
[cpu-render]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/sparse_strips/vello_cpu/src/render.rs
[scenes-lib]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/sparse_strips/vello_example_scenes/src/lib.rs
[scenes-text]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/sparse_strips/vello_example_scenes/src/text.rs
[simple-text]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/examples/scenes/src/simple_text.rs
[parley]: https://docs.rs/parley
