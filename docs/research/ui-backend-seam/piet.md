# Piet — the one-2D-API-many-backends seam, with a signed post-mortem

**Category:** abandoned multi-backend 2D seam. **Last reviewed:** August 23, 2026.
Pinned at [`22210f03`][rev].

Piet is the only subject in this survey whose authors declared the design
insufficient in writing and then built the replacement. It is a `RenderContext`
trait with four associated types (`Brush`, `Text`, `TextLayout`, `Image`) over
five shipped backends — Cairo, Direct2D, Core Graphics, HTML Canvas and SVG —
and its own maintainers wrote down, at the moment they walked away, exactly
which property of that shape failed. That makes it worth more to
[`canvas-seam-friction.md`][friction] than a seam that merely works.

| Field                | Value                                                                                                            |
| -------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **Language**         | Rust (edition 2024, MSRV 1.92)                                                                                   |
| **License**          | `Apache-2.0 OR MIT`                                                                                              |
| **Repository**       | [`linebender/piet`][repo]                                                                                        |
| **Documentation**    | [`docs.rs/piet`][docsrs]                                                                                         |
| **Category**         | abandoned multi-backend 2D seam                                                                                  |
| **Pinned revision**  | [`22210f03b8a2b203e2ad5ba9b600ed17f4a9407a`][rev] (2026-05-02), workspace version `0.8.0`                        |
| **Target range**     | desktop / web only — every backend is a full 2D vector renderer with real font shaping                           |
| **Backends shipped** | `piet-cairo`, `piet-direct2d`, `piet-coregraphics`, `piet-web`, `piet-svg`, plus an in-crate `NullRenderContext` |
| **Status**           | maintenance mode; superseded by [Vello](./vello.md) + [Parley](./parley-xilem.md)                                |

## Overview

### What it solves

Piet is the "buy, don't build" answer to cross-platform 2D: rather than ship a
renderer, wrap the one each platform already has. The [`README.md`][readme]
states the bargain:

> The Piet project consists of a core crate (`piet`) which describes a 2D
> graphics API, and a number of "backends", which implement that API on top of
> the built-in 2D graphics system of a given platform. This allows the same
> drawing code to be used on different platforms, without having to bundle a
> full 2D renderer.

The originating design note is Raph Levien's 2018 post [_A crate I want: 2d
graphics_][blog2018], which frames it as an instance of a Rust-ecosystem
pattern — "platform-specific wrappers as a bottom layer … and then a
cross-platform abstraction" — and weighs build against buy explicitly: "An
advantage of 'build' is that rendering is more likely to be consistent across
multiple platforms; similarly, the testing burden is reduced."

### Design philosophy

Two commitments shape everything below.

**The seam is the platform's intersection, not a designed vocabulary.** Piet's
text-API author, Colin Rofls, states it without hedging:

> The text API exposed by Piet was not chosen because it is the best API we can
> imagine, but because it is an API that we can reasonably implement in both
> CoreText and DirectWrite. It has several slightly strange elements; these are
> generally an attempt to find the common ground between these two different
> APIs. — [_Piet text layout API_][cmyr]

**A new operation must be implementable everywhere before it may exist.** The
[`README.md`][readme] makes this a contribution gate:

> For a new feature to be considered, there must be a plan for how it would be
> implemented in at least the coregraphics, direct2d, and cairo backends, and
> the actual implementation should include support for at least two of these.

That is the lowest-common-denominator ratchet made procedural. It is also, on
the authors' own account, the thing that killed the project.

### The post-mortem

The retrospective this subject is on the list for is in the Vello repository, in
the archived [`doc/vision.md`][vision] (Raph Levien, 2020-12-10, preserved
behind an "as of the end of 2020" notice):

> The Piet of today is primarily an abstraction layer over platform 2D graphics
> libraries, and that's equally true of text. … I think we want to move away
> from abstracting over platform capabilities, for several reasons. One is that
> it's harder to ensure consistent results. Another is that it's hard to add new
> features, such as hz-style justification. Thus, we follow a similar trajectory
> as Web browsers.

Two reasons, both structural, neither about performance: **consistency** and
**extensibility**. Levien restated the outcome in his 2022 year-end post — "
'Piet' refers to a trait/method abstraction for the traditional 2D graphics
API, and we're moving away from that" ([_Raph's 2023_][raph2023]) — and the
rename of `piet-gpu` to Vello was justified as "it is no longer based on the
Piet render context abstraction" ([_Requiem for piet-gpu-hal_][requiem]).
Linebender's own project index records the disposition: "Our goal is for Piet to
be superseded by Vello" ([`content/_index.md`][lbindex]), and the
[`README.md`][readme] says plainly: "Piet is in maintenance mode."

> [!NOTE]
> There is no `CHANGELOG.md` in the repository at the pinned revision, and no
> in-repo retrospective document. Every statement above is quoted from a source
> outside the piet tree except the maintenance-mode and contribution-gate lines,
> which are in its `README.md`.

## How it works

The seam is one trait with four associated types, in
[`piet/src/render_context.rs`][rc]:

```rust
pub trait RenderContext
where
    Self::Brush: IntoBrush<Self>,
{
    /// The type of a "brush".
    type Brush: Clone;
    /// An associated factory for creating text layouts and related resources.
    type Text: Text<TextLayout = Self::TextLayout>;
    /// The type use to represent text layout objects.
    type TextLayout: TextLayout;
    /// The associated type of an image.
    type Image: Image;
    // …
}
```

The associated types are the same capability device as [Slint](./slint.md)'s `Font::Length`
and [Iced](./iced.md)'s associated renderer types — but applied to the **whole payload vocabulary**
rather than to one unit. A brush, a text layout and an image are all whatever
the backend says they are; the caller only ever holds handles.

The operation set is small and strictly primitive:

| Group | Methods                                                                                       |
| ----- | --------------------------------------------------------------------------------------------- |
| Paint | `fill`, `fill_even_odd`, `stroke`, `stroke_styled`, `clear`                                   |
| State | `save`, `restore`, `with_save`, `clip`, `transform`, `current_transform`                      |
| Text  | `text() -> &mut Self::Text`, `draw_text`                                                      |
| Image | `make_image`, `make_image_with_stride`, `draw_image`, `draw_image_area`, `capture_image_area` |
| Other | `blurred_rect`, `status`, `finish`                                                            |

Geometry never enters as a concrete type: `fill(&mut self, shape: impl Shape, …)`
takes anything implementing kurbo's `Shape`, so a backend that can fast-path a
rectangle does so by downcasting (`shape.as_rect()` in
[`piet-direct2d/src/lib.rs`][d2d]) rather than by the seam having a `fillRect`.

Colour reaches the backend through a hidden bridge trait in the same file:

```rust
pub trait IntoBrush<P: RenderContext>
where
    P: ?Sized,
{
    #[doc(hidden)]
    fn make_brush<'a>(&'a self, piet: &mut P, bbox: impl FnOnce() -> Rect) -> Cow<'a, P::Brush>;
}
```

The `bbox` closure is the interesting part: a `LinearGradient` is specified in
`UnitPoint` coordinates "relative to the `Rect` of the item being drawn"
([`piet/src/gradient.rs`][grad]), and is resolved to image space **lazily, at
draw time, by the backend**, using a bounding box the backend computes. A
device-independent description and a device-resolved handle share one parameter
slot, and the resolution point is the call.

`piet-common` selects a backend by `cfg_if` and re-exports it under fixed type
aliases — `pub type Piet<'a> = CairoRenderContext<'a>;` in
[`cairo_back.rs`][cairo-back] — with `compile_error!("could not select an
appropriate backend")` as the fallthrough ([`piet-common/src/lib.rs`][common]).
There is no `dyn RenderContext`, no enum of backends: the choice is monomorphic
and compile-time, exactly the bargain `isCanvas!T` makes.

## Q1 — measurement units, and who answers

**Measurement is off the painter, but not off the seam.** `RenderContext` has no
`measure`. It has `fn text(&mut self) -> &mut Self::Text`, and `Text` is a
factory trait ([`piet/src/text.rs`][text]) with its own two associated types:

```rust
pub trait Text: Clone {
    type TextLayoutBuilder: TextLayoutBuilder<Out = Self::TextLayout>;
    type TextLayout: TextLayout;

    fn font_family(&mut self, family_name: &str) -> Option<FontFamily>;
    fn load_font(&mut self, data: &[u8]) -> Result<FontFamily, Error>;
    fn new_text_layout(&mut self, text: impl TextStorage) -> Self::TextLayoutBuilder;
}
```

The answer comes from a built `TextLayout`, not from a string: `fn size(&self) -> Size`,
`fn trailing_whitespace_width(&self) -> f64`, `fn image_bounds(&self) -> Rect`,
plus per-line `LineMetric` and two hit-test directions
(`hit_test_point`, `hit_test_text_position`). Measurement is a **property of a
laid-out object the backend built**, which is the strongest form of F1's answer
in the survey — stronger than Slint's, because you cannot even ask the width of
a string without first committing to a font, a size, a wrap width and an
alignment.

The unit, however, is **fixed**: `f64` display points everywhere. Piet does not
take Slint's associated-`Length` step. So the associated types cover the
_objects_ but not the _units_, and every backend must agree that a display point
is a display point. Device scaling lives outside the seam entirely — a caller
passes `pix_scale` to `Device::bitmap_target`, which applies
`cr.scale(pix_scale, pix_scale)` before the render context exists
([`cairo_back.rs`][cairo-back]).

The seam is candid that backends still disagree. `TextLayout::size`'s own doc:

> This is not currently defined very rigorously; in particular we do not specify
> whether this should include half-leading or paragraph spacing above or below
> the text. We would ultimately like to review and attempt to standardize this
> behaviour, but it is out of scope for the time being.

The shared cross-backend suite, [`piet-common/tests/text.rs`][ttest], is written
in tolerances rather than equalities, with the reason recorded in the source:
`empty_layout_size` carries "NOTE: This was made more lenient to accommodate the
values Pango produces with some fonts / FIXME: Investigate more and revert to a
tolerance of 1.0", and `emergency_break_selections` is `#[cfg(not(target_os = "linux"))]`
with "FIXME: disabled on linux until pango lands, and wasm until we have proper
text there." **This is the "harder to ensure consistent results" clause of the
post-mortem, visible as `cfg` attributes.**

## Q2 — is the contract stated in one place?

**Stated in one place, and enforced by social process rather than by types.**
The trait is the whole contract: there is no `hasFeature`, no capability
bitmask, no optional sub-trait. Every method is required; a backend that cannot
do something must still compile.

That leaves three degradation channels, none declared:

1. **Runtime error.** `Error::NotSupported` ("Something is impossible on the
   current platform") and `Error::Unimplemented` ("Something is possible, but
   not yet implemented") in [`piet/src/error.rs`][err]. But only the methods
   returning `Result` can use them — `capture_image_area` does
   (`Err(Error::Unimplemented)` in [`piet-svg/src/lib.rs`][svg]); `fill`,
   `stroke`, `clip`, `draw_text`, `draw_image` and `blurred_rect` cannot.
2. **Silent substitution.** `piet-svg`'s `blurred_rect` is
   `// TODO blur (perhaps using SVG filters)` followed by `self.fill(rect, brush)` —
   a blur request becomes a hard-edged rect with no signal. `piet-web`'s brush
   conversion is worse: `Brush::Gradient(_) => "#f0f".into()` with the comment
   `// Gradients not yet implemented.` ([`piet-web/src/lib.rs`][web]) — an
   unsupported gradient renders magenta.
3. **Documented in prose.** `StrokeStyle::dash_pattern` says "On platforms that
   do not support an odd number of lengths in the array, the implementation may
   concatenate two copies of the array to reach an even count"
   ([`piet/src/shapes.rs`][shapes]); `clear` says "It does not have a good
   cross-platform implementation, and eventually should be deprecated when
   support is added for blend modes" ([`render_context.rs`][rc]).

So Piet lands where `sparkles:ui` does — an unstated contract — by the opposite
route. Ours is understated because the concept checks five of eight kinds;
Piet's is overstated, because every method is mandatory and some of them are
lies. **This sharpens F4:** the failure is not "optional capabilities are
undeclared", it is that _a seam with no capability vocabulary at all forces
every gap into either a runtime error, a silent wrong render, or a doc comment._
Piet has all three, and the caller can distinguish none of them.

The gate quoted above is the substitute mechanism: new operations are admitted
only if three named backends can implement them. That keeps the trait honest and
guarantees the trait can never grow past the intersection — which is the
post-mortem's second clause, "it's hard to add new features", stated as policy.

## Q3 — semantic operations, or primitives?

**Primitives, with exactly one semantic exception, and the exception is
instructive.** There is no scrollbar, no border, no text input, no shadow node.
There is `blurred_rect(rect, blur_radius, brush)`, which exists because a blur
cannot be composed from the primitives on the seam and is "very widely used in
UI" ([`vision.md`][vision]).

Every backend answers it differently:

| Backend             | `blurred_rect` implementation                                                                                                                               |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `piet-cairo`        | CPU blur via `piet::util::size_for_blurred_rect` + `compute_blurred_rect` into an A8 `ImageSurface`, then `mask_surface` ([`piet-cairo/src/lib.rs`][cairo]) |
| `piet-coregraphics` | the **same** `piet::util` CPU blur, into a `CGImage` used as `clip_to_mask` ([`piet-coregraphics/src/lib.rs`][cg])                                          |
| `piet-direct2d`     | native: a compatible render target and a D2D effect ([`piet-direct2d/src/lib.rs`][d2d])                                                                     |
| `piet-web`          | `ctx.set_shadow_blur` + `fill_rect`, i.e. the Canvas shadow machinery ([`piet-web/src/lib.rs`][web])                                                        |
| `piet-svg`          | none — falls back to `self.fill` ([`piet-svg/src/lib.rs`][svg])                                                                                             |

Two of the five share a **framework-side software fallback** exposed as public
helpers in [`piet/src/util.rs`][util] ("Code useful for multiple backends"). That
is Qt's answer — the framework emulates once — offered as a library rather than
imposed by the painter, so a backend with something better ignores it. F3's
"who degrades" axis gains a third position: **the framework supplies the
fallback, the backend chooses whether to use it.**

## Q4 — command shape

**Not answered here, and the absence is a finding.** `RenderContext` is
generic-method dispatch; nothing is reified. There is no `DrawOp` analogue, no
enum of operations, nothing to collect or replay. The trait doc holds out the
possibility —

> In basic usage, it wraps a surface of some kind, so that drawing commands
> paint onto the surface. It can also be a recording context, creating a display
> list for playback later.

— but no recording implementation ships in the workspace at the pinned revision.
The only non-drawing implementation is `NullRenderContext`, documented as "A
render context that doesn't render. This is useful largely for doc tests", and
marked `#[doc(hidden)]` ([`piet/src/null_renderer.rs`][null]). It discards
rather than records.

Piet does reach for sum types elsewhere, twice, where the alternative would have
been dead fields: `PaintBrush` (`Color | Linear | Radial | Fixed`) and
`TextAttribute` (`FontFamily | FontSize | Weight | TextColor | Style |
Underline | Strikethrough`), the latter applied over byte ranges via
`range_attribute`. So the repository that most resembles our tag-plus-fields
problem solved its own many-optional-properties question the way F2 recommends —
a sum type — and simply never faced the command-shape question, because it has
no commands.

## Q5 — sub-unit placement

Does not arise. Coordinates are kurbo `f64` throughout, resolution scaling is a
constructor argument, and hairlines are `stroke(shape, brush, width)` with any
positive `width`. Piet is a third confirmation of F5's negative half: **a
toolkit with continuous coordinates never invents a `RuleEdge`.** It contributes
nothing to the positive half — it has no target that cannot address below the
unit, so it never had to name a fidelity.

## Q6 — resolved appearance, semantic role, or both?

**Both, in one slot, resolved at the call site by the backend.** This is the
question Piet answers most originally.

The parameter type is `&impl IntoBrush<Self>`, and three kinds of thing satisfy
it: a device-independent `Color`, a device-independent-but-shape-relative
`LinearGradient`/`RadialGradient`, and the backend's own `Self::Brush`. The
backend's `make_brush` receives a `bbox` thunk and returns `Cow<'a, P::Brush>` —
`Cow::Borrowed` when the caller already handed over a native brush,
`Cow::Owned` when one had to be minted. A caller that will paint the same colour
a thousand times can call `solid_brush` once and pass the handle; a caller that
does not care passes `Color::BLACK` and pays a mint per call. **The seam does not
choose between resolved and semantic; it makes both inhabit one parameter and
lets the caller pick per call site.**

Compare friction §6, where `DrawOp` carries `visual` _and_ `slot` on every op so
that the HTML backend can re-resolve. Piet's arrangement costs nothing per
operation: the polymorphism is in the parameter type, and monomorphisation
erases it. `IntoBrush` is marked "an internal trait that you should not have to
implement or think about", which is the ergonomic price — the mechanism is
invisible until it appears in a compiler error.

Everything else is resolved: `StrokeStyle` holds joins, caps, dashes;
`TextAttribute` holds concrete font families, sizes, weights and colours. No
semantic role names survive to the backend.

## Q7 — payload ownership

**Owned by the backend, minted through the seam, handed back as a handle.**
Nothing is borrowed across a frame boundary anywhere in the API.

- **Images.** `make_image(width, height, buf, format) -> Result<Self::Image, Error>`
  copies the pixels into whatever the platform wants; the caller keeps
  `Self::Image`, which is documented "This is cheaply cloneable"
  ([`piet/src/image.rs`][img]) and whose only method is `size()`. The seam's own
  doc says why: "The generated image can be cached and reused. This is a good
  idea for images that are used frequently, because creating the image type may
  be expensive."
- **Text.** `new_text_layout(text: impl TextStorage)` where `TextStorage: 'static`,
  and the doc states the storage discipline outright: "Internally, the `text`
  argument will be stored in an `Rc` or `Arc`, so that the layout can be cheaply
  cloned. To avoid duplicating the storage of text … you can pass a type such as
  `Rc<str>` or `Rc<String>`." Implementations ship for `String`, `Arc<str>`,
  `Rc<str>`, `Arc<String>`, `Rc<String>` and `&'static str`. The caller chooses
  the sharing strategy; the seam requires only that it be shareable.
- **Brushes.** `Cow<'a, P::Brush>`, borrowed when possible.

This is F6 confirmed a fourth time, with a refinement: piet does not merely
reference-count, it makes the **conversion into backend-owned form an explicit
API call whose result the caller retains**. `DrawOp.text` as a borrowed slice
that "must outlive the op" (friction §7) has no analogue here, and could not:
`TextStorage`'s `'static` bound forbids it structurally.

> [!IMPORTANT]
> The cost is that no payload is a value. A `Self::TextLayout` cannot be built
> before a `RenderContext` exists, cannot move to another backend, and cannot be
> compared across backends. Piet's cross-backend testing is therefore
> pixel-diffing PNGs after the fact — [`piet/src/samples/mod.rs`][samples] with
> an out-of-tree snapshot submodule ([`.gitmodules`][gitmod] →
> `linebender/piet-snapshots`) — and even that compares tolerantly
> (`avg_diff_pct`) against a base directory stamped with an OS fingerprint
> (`GENERATED_BY`), not across backends. The op-stream parity harness
> `RecordingCanvas` gives us is unavailable to a seam with no reified commands.

## Q8 — extent query

**Not answered here.** `RenderContext` has no width, height or bounds method.
Extent is supplied _to_ the surface: `Device::bitmap_target(width, height, pix_scale)`
constructs the `ImageSurface` and only then yields a context. In the sample
harness, each picture module exports a `SIZE` constant that travels beside its
`draw` function (`SamplePicture::new(picture_0::SIZE, picture_0::draw)`), and the
backend CLIs create a target of that size before drawing — extent is metadata on
the _scene author_, not a query on either scene or context.

F7 stands: the surface knows its size because it was told. Piet adds that when
the size must come from content, the practical answer is a constant maintained
next to the drawing code — which is what `skia-canvas-render.d` was trying to
avoid computing (friction §8), and is no better than the scan it replaced.

## Strengths

- **Associated types over the entire payload vocabulary** let each backend keep
  its native brush, layout and image objects with zero conversion at the seam.
  No `dyn`, no vtable, monomorphic backend selection by `cfg` — structurally the
  same bargain as `isCanvas!T`, in a language with the same inference.
- **Measurement is a property of a built layout**, not a function of a string,
  so a caller cannot accidentally measure without committing to the font, size
  and wrap width that will actually be used.
- **Payload ownership is unambiguous and explicit**: the backend mints, the
  caller retains, `TextStorage: 'static` makes borrowing impossible.
- **`IntoBrush` unifies semantic and resolved paint in one parameter** without
  paying for both on every operation.
- **Framework-side fallbacks as public helpers** (`piet::util::compute_blurred_rect`)
  let a shared degradation exist without being mandatory.

## Weaknesses

- **No capability vocabulary.** Every method is mandatory, so a backend that
  cannot comply lies — silently (`piet-svg`'s blur, `piet-web`'s magenta
  gradient) or via a `Result` variant only some methods can return.
- **The trait cannot grow past the intersection of its backends**, by explicit
  policy. New features must be plannable on Core Graphics, Direct2D and Cairo
  first.
- **The abstraction does not supply shared machinery**, only a shape. Line
  breaking was copy-pasted between backends: `piet-web/src/text/lines.rs` and
  `grapheme.rs` both open "currently … copied and pasted from cairo backend …
  putting this code in `piet` core doesn't really make sense as it's
  implementation specific."
- **Nothing is reified**, so there is no recording context, no replay, no
  op-stream comparison, and cross-backend testing degrades to tolerant pixel
  diffs stamped per OS.
- **Consistency is out of reach**, and the test suite admits it in tolerances
  and `cfg` exclusions rather than in the API.

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                                             | Trade-off                                                                                                |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Wrap platform 2D engines instead of shipping a renderer              | "without having to bundle a full 2D renderer" ([`README.md`][readme]); Skia is a 349 MB clone ([2018 post][blog2018]) | Output differs per platform; the authors' stated reason for abandonment ([`vision.md`][vision])          |
| Associated `Brush`/`Text`/`TextLayout`/`Image`                       | Backends keep native objects; no conversion, no `dyn`                                                                 | No payload is a value: nothing can be built before a context exists, moved between backends, or compared |
| Text as a separate `Text` → `TextLayoutBuilder` → `TextLayout` chain | Matches how CoreText and DirectWrite actually work                                                                    | Chosen as "common ground between these two different APIs", not as the best API ([Rofls][cmyr])          |
| Every trait method mandatory; no feature query                       | One contract, no negotiation, no probing                                                                              | Degradation is invisible: silent substitution, or an error only some signatures can return               |
| Contribution gate: three named backends                              | Keeps the trait implementable everywhere                                                                              | Freezes the vocabulary at the intersection — "it's hard to add new features" ([`vision.md`][vision])     |
| `IntoBrush` with a lazy `bbox` thunk                                 | Shape-relative gradients resolve at draw time, in the backend                                                         | A hidden trait users "should not have to … think about" until it surfaces in an error                    |
| `TextStorage: 'static`, `Rc`/`Arc` interior                          | Layouts clone cheaply; no lifetime plumbing                                                                           | Callers must own or share text; `&str` of local lifetime is inexpressible                                |
| Extent supplied at target construction                               | The surface chose its size, so it knows it                                                                            | Content-sized surfaces need a hand-maintained constant beside the drawing code                           |

## Bearing on the proposal

1. **The post-mortem is about vocabulary growth, not about mechanism.**
   Linebender did not abandon `RenderContext` because trait dispatch was slow or
   because associated types were awkward; they abandoned it because a seam
   defined as the intersection of its backends cannot be made consistent and
   cannot be extended ([`vision.md`][vision]). `isCanvas` is defined by our own
   `OpKind`, not by an intersection — the vocabulary is ours to choose. That is
   a material difference, and it means friction §2's fix must preserve it: state
   the contract, but do not derive it from what all three current backends
   happen to support.

2. **A seam with no capability vocabulary at all is worse than ours, in a way
   that refines F4.** Piet's five backends degrade silently — a blur becomes a
   rect, a gradient becomes magenta — because there is nowhere to say "no". F4
   already asks for a floor plus a refusable degrade; Piet shows the third
   requirement: **the caller must be able to tell the three outcomes apart**
   (honoured / degraded / refused). `piet::Error` cannot, because the drawing
   methods return `()`.

3. **Measurement-off-the-painter is now unanimous across five subjects, and
   Piet's variant is the strictest** (F1). Adopt the shape: a factory that
   builds a laid-out object, with size, per-line metrics and hit-testing on the
   object. Do **not** adopt piet's fixed `f64` unit — Slint's associated
   `Font::Length` is the part that lets a cell backend and a shaping backend
   both answer honestly, and it is the part friction §1 needs.

4. **Piet contradicts F3's framing in a useful direction.** F3 poses "who
   degrades" as backend-vs-framework. Piet does both at once: `piet::util`
   publishes the software blur, and each backend decides whether to call it.
   A `sparkles.ui.degrade` module exporting `scrollbarCell`, `ruleEndpoints` and
   friends as _callable helpers a backend may use_ — which
   [`canvas.d`][canvas] already half does — is a better target than choosing a
   camp. The `DrawOp` scrollbar fields (friction §3) exist so each backend can
   re-derive geometry; publishing the derivation and passing the semantic
   parameters once is the same fix Piet arrived at.

5. **`IntoBrush` is a live alternative to carrying `visual` _and_ `slot`
   (friction §6).** A canvas primitive taking a paint _parameter_ that may be a
   resolved `Visual`, a semantic `Slot`, or a backend-native handle — resolved by
   the backend at the call, with the op's rect available as the bbox — costs
   nothing per op and lets the HTML interpreter keep class names while
   `SkiaCanvas` keeps `SkPaint`s. This is the single most transferable mechanism
   in the subject.

6. **Reject the contribution gate.** "Implementable on three named backends
   before it may exist" is exactly the ratchet the authors identify as fatal. If
   `sparkles:ui` wants a fidelity vocabulary (F5) or a new semantic op, the test
   should be "can every backend _degrade_ it honestly", not "can every backend
   _implement_ it".

7. **Reification is worth more than Piet knew.** Piet's trait doc anticipates a
   recording context and no one ever wrote one, so cross-backend verification
   fell back to tolerant, per-OS pixel diffs. `RecordingCanvas` plus the
   op-stream parity harness is a capability piet structurally cannot have, and
   F2's recommendation — keep the reified stream, re-encode it as a sum type —
   is reinforced rather than challenged here.

8. **Nothing in this subject bears on the survey's open question.** Every piet
   backend is a full 2D vector renderer with real shaping; the widest gap it
   spans is Cairo-to-SVG. It cannot say whether a terminal and a GPU surface
   belong behind one seam. What it _can_ say is that when the targets disagree
   even mildly — Pango's line height versus DirectWrite's — a seam defined as
   their intersection stops being extensible long before it stops being
   consistent.

## Sources

Piet, pinned at [`22210f03b8a2b203e2ad5ba9b600ed17f4a9407a`][rev]: the
[`README.md`][readme] (the bargain, the maintenance-mode notice, the
three-backend contribution gate); [`piet/src/render_context.rs`][rc] (the trait,
its associated types, `IntoBrush`, `PaintBrush`, the `clear` note);
[`piet/src/text.rs`][text] (`Text`, `TextLayoutBuilder`, `TextLayout`,
`TextStorage`, `TextAttribute`, `LineMetric`); [`piet/src/error.rs`][err];
[`piet/src/image.rs`][img]; [`piet/src/shapes.rs`][shapes];
[`piet/src/gradient.rs`][grad]; [`piet/src/util.rs`][util];
[`piet/src/null_renderer.rs`][null]; [`piet/src/samples/mod.rs`][samples];
[`.gitmodules`][gitmod]; [`Cargo.toml`][cargo]. Backends:
[`piet-cairo`][cairo], [`piet-coregraphics`][cg], [`piet-direct2d`][d2d]
(+ [`text/lines.rs`][d2dlines]), [`piet-web`][web] (+ [`text/lines.rs`][weblines],
[`text/grapheme.rs`][webgraph]), [`piet-svg`][svg]. Host crate:
[`piet-common/src/lib.rs`][common], [`cairo_back.rs`][cairo-back],
[`tests/text.rs`][ttest].

Retrospective and disposition:

- [Vello `doc/vision.md`][vision] (Raph Levien, 2020-12-10), pinned at
  [`3fabef93`][vellorev] — "I think we want to move away from abstracting over
  platform capabilities".
- [Vello `README.md`][velloreadme] — Piet named as Vello's "predecessor project".
- [Linebender `content/_index.md`][lbindex], pinned at [`18232b13`][lbrev] —
  "Our goal is for Piet to be superseded by Vello."
- [_A crate I want: 2d graphics_][blog2018] (2018-10-11) — the originating design
  note, linked from the piet `README.md`.
- [_Requiem for piet-gpu-hal_][requiem] (2023-01-07) — the rename rationale, plus
  "resolve the need to find common-denominator abstractions" (said of GPU HALs,
  not of the 2D seam).
- [_Raph's 2023_][raph2023] (2022-12-31) — "we're moving away from that".
- [_Piet text layout API_][cmyr] (Colin Rofls) — the text seam as "common ground
  between these two different APIs"; the "rich text API" reference cited from
  [`vision.md`][vision].

Related subjects in this survey: [Vello](./vello.md) (the replacement),
[Parley / Xilem](./parley-xilem.md) (the text half of the replacement),
[Cairo / Direct2D](./cairo-direct2d.md) (two of the wrapped devices),
[Slint](./slint.md) (associated types applied to units rather than objects),
[Qt `QPaintEngine`](./qt-qpaintengine.md) (the declared-capability alternative).

<!-- References -->

[rev]: https://github.com/linebender/piet/tree/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a
[repo]: https://github.com/linebender/piet
[docsrs]: https://docs.rs/piet
[readme]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/README.md
[rc]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet/src/render_context.rs
[text]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet/src/text.rs
[err]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet/src/error.rs
[img]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet/src/image.rs
[shapes]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet/src/shapes.rs
[grad]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet/src/gradient.rs
[util]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet/src/util.rs
[null]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet/src/null_renderer.rs
[samples]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet/src/samples/mod.rs
[gitmod]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/.gitmodules
[cargo]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/Cargo.toml
[cairo]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet-cairo/src/lib.rs
[cg]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet-coregraphics/src/lib.rs
[d2d]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet-direct2d/src/lib.rs
[d2dlines]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet-direct2d/src/text/lines.rs
[web]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet-web/src/lib.rs
[weblines]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet-web/src/text/lines.rs
[webgraph]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet-web/src/text/grapheme.rs
[svg]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet-svg/src/lib.rs
[common]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet-common/src/lib.rs
[cairo-back]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet-common/src/cairo_back.rs
[ttest]: https://github.com/linebender/piet/blob/22210f03b8a2b203e2ad5ba9b600ed17f4a9407a/piet-common/tests/text.rs
[vellorev]: https://github.com/linebender/vello/tree/3fabef9315914fc2fa32eed12afac8922785396b
[vision]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/doc/vision.md
[velloreadme]: https://github.com/linebender/vello/blob/3fabef9315914fc2fa32eed12afac8922785396b/README.md
[lbrev]: https://github.com/linebender/linebender.github.io/tree/18232b134f3964ba266bbc906bb8f73f9f4e3249
[lbindex]: https://github.com/linebender/linebender.github.io/blob/18232b134f3964ba266bbc906bb8f73f9f4e3249/content/_index.md
[blog2018]: https://raphlinus.github.io/rust/graphics/2018/10/11/2d-graphics.html
[requiem]: https://raphlinus.github.io/rust/gpu/2023/01/07/requiem-piet-gpu-hal.html
[raph2023]: https://raphlinus.github.io/personal/2022/12/31/raph-2023.html
[cmyr]: https://www.cmyr.net/blog/piet-text-work.html
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
