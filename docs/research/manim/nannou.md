# nannou (Rust)

A creative-coding framework in the [Processing][processing] / openFrameworks
lineage — a real-time, GPU-backed drawing loop for Rust in which the program
re-issues every draw call each frame, the opposite pole from Manim's retained
scene graph.

| Field             | Value                                                                                                               |
| ----------------- | ------------------------------------------------------------------------------------------------------------------- |
| Language          | Rust (workspace `edition = "2024"`)                                                                                 |
| License           | `MIT OR Apache-2.0`                                                                                                 |
| Repository        | [`github.com/nannou-org/nannou`][repo]                                                                              |
| Documentation     | [`guide.nannou.cc`][guide] (guide) · [`docs.rs/nannou`][docs-modules] (API)                                         |
| Category          | Creative-coding framework; [immediate-mode][retained-vs-immediate] real-time render loop                            |
| First release     | `0.1.0`, October 16 2017; latest `0.20.0`, June 22 2026 ([lib.rs][librs])                                           |
| Rendering backend | [`wgpu`][wgpu-readme] (Vulkan / Metal / D3D12 / OpenGL; WebGL2/WebGPU on wasm) — routed through Bevy since `0.20.0` |
| App model         | Immediate-mode `model` / `update` / `view` builder loop; **no retained scene graph**                                |

> [!WARNING]
> **`0.20.0` is a ground-up rewrite onto Bevy.** Through `0.19` nannou was a
> direct-`wgpu` engine (`winit` windowing, `lyon` tessellation, `rusttype`
> text). The changelog for `0.20.0` opens: _"This is a ground-up overhaul of
> nannou: it is now built on top of the Bevy game engine"_ ([guide
> changelog][guide-changelog]). The `model`/`update`/`view` and `Draw` APIs this
> page documents survive the rewrite, but the rendering foundation, egui
> integration, and text rasteriser all changed. Where a mechanism differs
> between the two eras it is flagged inline; API signatures are cited against
> `0.19.0` (the last direct-`wgpu` release).

---

## Overview

### What it solves

nannou is a toolkit for **making pictures and sound in real time from code** —
generative art, audiovisual installations, sketches, live visuals — with Rust's
performance and memory safety underneath. It is not an offline math-animation
renderer; there is no timeline, no `self.play`, no video file waiting at the
end. The primary artifact is a **live window** you watch and interact with while
the program runs, and the code is a Rust `cargo` project you edit and re-run. The
crate docs state its aim plainly ([`docs.rs/nannou`][docs-crate]):

> _"Nannou is a collection of code aimed at making it easy for artists to
> express themselves with simple, fast, reliable, portable code."_

### Design philosophy

nannou belongs to the [Processing][processing] / openFrameworks / Cinder family
of **creative-coding** environments — a canvas, a per-frame draw callback, and a
small vocabulary of shapes — reimagined for Rust. The [guide][guide] frames it as:

> _"Nannou is an open-source, creative-coding toolkit for Rust."_

and the `nannou` crate's own manifest describes it as _"A Creative Coding
Framework for Rust."_ ([`nannou/Cargo.toml`][nannou-crate-toml]). The design
commitments that follow from that lineage — and that shape every axis below — are
**immediate-mode drawing** (state lives in your `Model`, not an engine-owned
graph), **real-time-first** output (the GPU window is the product), and a
**modular, Rust-native surface** (audio, OSC, MIDI, laser, and raw `wgpu` are
separate crates you opt into). Reproducible, deterministic, cached offline
rendering — Manim's whole reason to exist — is explicitly _not_ a nannou goal.

---

## How it works

A nannou program is three functions and a builder. `nannou::app(model)` seeds
state with a `model` function, `.update(update)` registers a per-tick mutator,
`.simple_window(view)` opens a window bound to a `view` renderer, and `.run()`
drives the loop ([guide — Anatomy of a nannou app][guide-anatomy]):

```rust
// The canonical nannou app. `model` builds state once; `update` mutates it on a
// timer (default 60/s); `view` renders it. There is no scene graph — `Model` is
// an arbitrary Rust struct that YOU own.
fn main() {
    nannou::app(model)
        .update(update)
        .simple_window(view)
        .run();
}
```

`view` is re-invoked every frame. `app.draw()` hands back a `Draw` whose state is
**reset on each call**, and every primitive is re-issued from scratch — the
definition of an [immediate-mode][retained-vs-immediate] API. `App::draw`'s doc
comment ([`docs.rs`][docs-app]): _"the **App** stores the **Draw** instance for
you and automatically resets the state on each call."_ The [guide's drawing
tutorial][guide-draw] gives the shape of a `view`:

```rust
fn view(app: &App, frame: Frame) {
    let draw = app.draw();               // fresh, state reset each frame
    draw.background().color(PLUM);        // clear
    draw.ellipse().color(STEELBLUE);      // an immediate draw command
    draw.to_frame(app, &frame).unwrap();  // tessellate + submit to the GPU
}
```

Between them, `model`/`update`/`view` are a real-time render loop, not Manim's
imperative play-loop: no animation is ever "played", time simply advances and you
redraw. Where nannou needs to drop below the `Draw` abstraction, `nannou_wgpu`
_"re-exports the entire `wgpu` crate"_ ([`docs.rs/nannou_wgpu`][nannou-wgpu]), so
custom render pipelines, shaders, and (since `0.20`) compute passes are available.

---

## Object & scene model

**The central finding: nannou has no retained
[Mobject tree][mobject].** There is no persistent, mutable, engine-owned graph of
drawable objects the way a Manim `Scene` holds `Mobject`s. `Draw` is the
[immediate-mode][retained-vs-immediate] pole of the object-model axis: each
`view` call issues a flat stream of commands (`draw.ellipse()`, `draw.path()`,
`draw.text()`) that are tessellated and discarded; nothing is retained between
frames. Persistent state — positions, phases, particle arrays — lives in the
user's `Model` struct, which is **arbitrary Rust**, not a scene-graph node type.

`Draw` exposes a primitive vocabulary — `ellipse`, `rect`, `line`, `tri`, `quad`,
`polygon`, `path`, `polyline`, `arrow`, `mesh`, `texture`, `text`, `background`
([`Draw`][docs-draw]) — and each returns a `Drawing` builder that chains
attributes (`.color()`, `.w_h()`, `.xy()`) and **affine transforms** (`.rotate()`,
`.scale()`, `.translate()`). The geometry primitives nannou shares with Manim are
grounded by the catalog probes: paths are piecewise-Bézier ([`bezier-eval.d`][ex-bezier])
and every per-primitive transform is an affine map on control points
([`affine-transform.d`][ex-affine]). What is **absent** is the machinery those
probes exist to feed on the Manim side: there is no `Transform`/morph, no
point-count-alignment, no submobject `family` traversal — because there are no
persistent objects to interpolate _between_. Filled paths are tessellated to
triangle meshes by `lyon` (not the ear-clip + winding split Manim uses), and
`0.20` extends the model into 3D.

---

## Animation & timing model

**The finding: nannou gives you a clock and pure easing _functions_, but no
animation orchestration.** Time is a raw value, not a timeline. `App::time` is a
bare `f32`, documented as _"The time in seconds since the `App` started
running… the same type as the scalar value used for describing space in
animations, making it very easy to animate graphics and create changes over
time"_ ([`docs.rs`][docs-app]). The per-tick `Update` event carries
`since_last: Duration` and `since_start: Duration` ([`Update`][docs-update]) — a
frame delta and an elapsed total. `update` fires on a timer (default 60/s).

```rust
// Animation is hand-written per-frame math. There is no tween object, no
// AnimationGroup, no ValueTracker — you read the clock and recompute state.
fn update(_app: &App, model: &mut Model, update: Update) {
    model.phase += update.since_last.secs();   // advance a user-owned parameter
}
```

nannou _does_ ship an [easing][rate-function] library: the `ease` module is _"A
suite of common interpolation functions often referred to as 'easing' and
'tweening' functions. This API is provided by the `pennereq` crate"_
([`docs.rs`][docs-ease]) — the Penner equations (`quad`, `cubic`, `quart`,
`quint`, `sine`, `circ`, `expo`, `elastic`, `back`, `bounce`), plus `map` /
`map_clamp` range remaps. These are **pure functions of a time parameter**; the
same smootherstep/Penner family the [`rate-functions.d`][ex-rate] probe tabulates.
But there the resemblance to Manim's timing model stops: nannou has **no**
`AnimationGroup` / `Succession` / `LaggedStart`, no `lag_ratio` staggering, no
`Transform`/[interpolation][interpolation] over retained objects, no
`ValueTracker`/updater graph. On the [execution-model][execution-models] axis it
is a real-time update/view loop — closer to hand-coding a "pure frame function"
than to Manim's `play`-loop, because there is no `play` primitive at all: time
advances and you redraw.

---

## Rendering backend & rasterization

nannou is a [GPU-vector][cpu-vs-gpu] engine built on **`wgpu`**, the Rust WebGPU
implementation. `nannou_wgpu` states nannou's target directly: _"WebGPU is the
portable graphics specification that nannou targets… wgpu is the name of the
crate we use that implements this specification"_ ([`docs.rs/nannou_wgpu`][nannou-wgpu]),
and it _"re-exports the entire `wgpu` crate."_ `wgpu`'s own backend set is
inherited wholesale — _"It runs natively on Vulkan, Metal, D3D12, and OpenGL; and
on top of WebGL2 and WebGPU on wasm"_ ([wgpu README][wgpu-readme]) — with the
WebGL/wasm path added in `0.19` (changelog: GL backend for WASM support). The
`0.18` crate docs already list `wgpu ^0.11` as the graphics foundation and expose
a `wgpu` module, _"Items related to wgpu and its integration in nannou"_
([`docs.rs/nannou 0.18`][docs-crate]).

The [rasterization][rasterization] path is **GPU tessellate-and-draw**, not CPU
analytic coverage: `Draw` primitives are converted to triangle meshes by `lyon`,
uploaded, and drawn by `wgpu`. [Anti-aliasing][anti-aliasing] is therefore GPU
multisampling (MSAA) rather than the exact per-pixel coverage a CPU rasteriser
(Cairo, the Manim-community default) computes — fast and real-time, but **not
bit-reproducible** across drivers, the defining trade of the
[CPU-vector vs GPU-vector][cpu-vs-gpu] split. Color is exposed through named
constants (`PLUM`, `STEELBLUE`, …) and RGBA/HSV types; the [gamma/blend-space
question][color-gamma] is handled inside the color and shader layers rather than
surfaced to the user. Since `0.20.0` the `Draw` API is _"rendered through Bevy's
renderer"_ ([guide changelog][guide-changelog]) — `wgpu` is still underneath
(Bevy renders via `wgpu`), but the pipeline, resource management, and frame
scheduling are now Bevy's.

---

## Typesetting & text

Text is a first-class but **basic** citizen: `Draw::text` has the signature
`pub fn text(&self, s: &str) -> Drawing<'_, Text>` with the doc comment _"Begin
drawing a **Text**"_ ([`docs.rs`][docs-draw-text]). The `text` module is _"Text
layout logic… used primarily by the `draw.text()` API"_ and is built on
**RustType** — it exposes _"The RustType `Font` type used by nannou"_ and _"The
RustType `PositionedGlyph` type"_, plus `Align`, `Justify`, and `Wrap`
([`docs.rs/nannou::text`][docs-text]). Rendering a string means pulling each
glyph's TrueType [outline][glyph-outline] from the font — the in-process,
LaTeX-free alternative to Manim's `dvisvgm` pipeline.

Two limitations are the finding here. First, **no math typesetting**: the `text`
module documentation carries _"no mention of LaTeX or mathematical typesetting
support"_ — there is no equation layout, no TeX, nothing like Manim's
`MathTex`/`Tex`. Second, **no complex-script [shaping][text-shaping]**: RustType
does positioning and kerning-level layout, not full HarfBuzz/Pango shaping, so
ligatures, bidi, and Indic/Arabic scripts are out of scope (Manim routes text
through `manimpango` → HarfBuzz for exactly this). `0.20` reworked the raster
model — _"glyphs are rasterised at their font size… dense or small text is far
cheaper and pixel-crisp"_ ([guide changelog][guide-changelog]) — trading the old
outline-tessellation approach for a glyph atlas (crisper raster text, but raster,
not resolution-independent vector).

---

## Output & encoding

**The primary output is the real-time window; file output is per-frame images,
and there is no built-in video encoder.** The offline path is
`Window::capture_frame`, `pub fn capture_frame<P>(&self, path: P) where P: AsRef<Path>`,
documented as _"Capture the next frame right before it is drawn to this window and
write it to an image file at the given path… The destination image file type will
be inferred from the extension given in the path"_ ([`docs.rs`][docs-window-capture]).

```rust
// One image file per frame. Repeat every frame to get a PNG sequence; there is
// no codec/muxer in core nannou, so a movie is an external post-step (ffmpeg).
app.main_window().capture_frame(frame_path);   // e.g. "frames/0001.png"
```

This covers the [frame-capture / readback][frame-capture] step — the GPU frame is
read back and encoded to a still image, the shape the [`frame-capture.d`][ex-capture]
probe stands in for — but it **stops there**. nannou ships no
[codec/muxing/pixel-format][codec-muxing] machinery for its own draw output: no
`ffmpeg` subprocess pipe (ManimGL's `-f rawvideo -pix_fmt rgba`), no in-process
`libav` (Manim-community's PyAV). To turn a nannou capture into an `.mp4` you run
an external tool over the PNG sequence yourself. The consequence for the survey:
nannou is a **real-time-first** engine where video is a manual export, the inverse
of Manim's render-to-file-first design.

---

## Interactivity, preview & authoring

This is nannou's strongest axis and the mirror image of Manim's. **The window is
the preview** — live, GPU-rendered, running at frame rate, and interactive:
mouse, keyboard, and window events are delivered to handler functions on the app
builder, and state mutates in `update` while you watch. There is no
render-then-open-a-file gap; authoring is edit-Rust-and-`cargo run`, with the
running sketch as the feedback loop. `App` conveniences reflect this real-time
stance — `elapsed_frames()` is _"The number of times the focused window's view
function has been called"_ and `fps()` reports the live rate ([`docs.rs`][docs-app]).

For control surfaces and installations nannou leans on its sibling crates: egui
GUI panels (`nannou_egui` through `0.19`, replaced by `bevy_egui` in `0.20`), and
`nannou_osc` / `nannou_midi` / `nannou_laser` / `nannou_audio` for the
audiovisual and hardware wiring that live performance and gallery work need. A
`sketch` entry point (no `Model`, single window) exists for the quickest possible
start; `app` is the full builder.

---

## Extensibility & API surface

nannou is a **Rust-native, statically-typed, modular** surface — a Cargo
workspace of opt-in crates rather than one monolith ([repo][repo]):

| Crate                                           | Role                                                       |
| ----------------------------------------------- | ---------------------------------------------------------- |
| `nannou_core`                                   | headless / embedded / `rust-gpu` core (geom, color, math)  |
| `nannou_draw`                                   | the immediate-mode `Draw` API                              |
| `nannou_wgpu`                                   | re-exports all of `wgpu` + helpers (raw pipelines/shaders) |
| `nannou_audio`                                  | audio I/O via CPAL                                         |
| `nannou_osc` / `nannou_midi`                    | OSC / MIDI messaging                                       |
| `nannou_laser`                                  | ILDA laser DAC output                                      |
| `nannou_isf` / `nannou_video` / `nannou_webcam` | ISF shaders, video, webcam input                           |

Extension happens at two levels: **stay in `Draw`** for the high-level shape API,
or **drop to raw `wgpu`** (the full crate is re-exported) for custom render
pipelines and — since `0.20` — compute shaders. The `0.20` rewrite reframes the
whole surface as **Bevy plugins**: nannou's features are exposed as a
`NannouPlugin`, so the `Draw` API can be dropped into any Bevy app, or Bevy's ECS
pulled into a nannou sketch ([guide changelog][guide-changelog]). The API is
plain Rust throughout — no scene-description DSL, no scripting layer; extensibility
is "write more Rust", with the type system as the contract.

---

## Determinism, caching & performance

**The finding: nannou optimises for real-time throughput, not reproducibility —
the exact opposite of Manim-community's caching model.** There is **no
content-hash caching**: nannou has no `play()`-sized unit of work to hash, no
partial-movie-file store, nothing analogous to Manim's per-call cache keyed on a
[deterministic render][deterministic]. And because rendering is
[GPU-vector][cpu-vs-gpu], output is **not bit-reproducible** across drivers, GPUs,
or MSAA settings — nannou cannot serve as the reproducible "oracle" a
regression-tested video pipeline needs. (The [`frame-capture.d`][ex-capture]
probe's deterministic FNV checksum illustrates precisely the property a CPU
backend gives you and a GPU backend does not.)

What nannou gives instead is **predictable real-time performance**: GPU
acceleration, Rust's zero-cost abstractions and absence of a garbage collector,
and a fixed-rate `update`/`view` loop (default 60/s) yield stable frame times
suitable for live visuals. The cost is paid on the offline side —
`capture_frame` at high resolution is bounded by GPU→CPU readback and disk I/O,
and a long "video" is thousands of individually-written PNGs. Determinism, when a
project needs it, must be engineered by the author (seed all RNG, avoid
frame-rate-dependent math); the engine makes no such guarantee.

---

## Strengths

- **Real-time, interactive, GPU-fast by default** — the live window _is_ the
  workflow; no render-then-watch gap. The natural fit for generative art,
  live-coded visuals, and installations.
- **Rust all the way down** — memory safety, no GC pauses, `cargo` tooling, and a
  statically-typed API; raw `wgpu` (and, since `0.20`, Bevy's ECS + compute
  shaders) available when the high-level API runs out.
- **Batteries for audiovisual/installation work** — first-party audio, OSC, MIDI,
  and laser crates that Manim-class tools don't attempt.
- **Immediate mode is simple to reason about** — no retained graph, no
  cache-invalidation; state is a plain struct you own.
- **Permissive dual license** (`MIT OR Apache-2.0`) and a warm, well-written
  [guide][guide].

## Weaknesses

- **No animation model** — no `Transform`/morph, timeline, `AnimationGroup`,
  `lag_ratio`, or `ValueTracker`; every motion is hand-written per-frame math over
  a raw clock (easing _functions_ exist; orchestration does not).
- **No math typesetting** — RustType text only; no LaTeX/`MathTex`, no HarfBuzz
  complex-script [shaping][text-shaping]. A dealbreaker for equation-heavy work.
- **No built-in video export** — `capture_frame` writes single images; muxing to
  a codec is a manual external step.
- **Not reproducible or cached** — GPU output varies across drivers; no
  content-hash caching; unsuitable as a regression-tested video oracle.
- **Volatile foundation / sporadic cadence** — a ~2-year gap (`0.18.1` Dec 2021 →
  `0.19.0` Jan 2024) then ~2.5 years to the `0.20.0` Bevy rewrite (Jun 2026),
  which churns the rendering, GUI, and text internals.

---

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                          | Trade-off                                                                         |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| [Immediate-mode][retained-vs-immediate] `Draw`, no scene graph | Simple mental model; per-frame procedural drawing; no cache-invalidation           | No object-level diffing/morph; animation state is entirely the author's problem   |
| Real-time window as the primary output                         | Instant feedback; live/interactive/installation use                                | Offline video is a manual, non-reproducible export path                           |
| GPU-vector via [`wgpu`][wgpu-readme]                           | Portable (Vulkan/Metal/D3D12/GL + web), fast, real-time preview                    | Not bit-reproducible ([CPU-vs-GPU][cpu-vs-gpu]); MSAA not analytic coverage       |
| Easing as pure functions, no animation objects                 | Tiny, composable; author keeps full control of time                                | No `Transform`/`AnimationGroup`/timeline; every motion hand-coded                 |
| RustType text, no LaTeX/HarfBuzz                               | In-process, dependency-light glyph [outlines][glyph-outline]                       | No math typesetting, no complex-script [shaping][text-shaping]                    |
| `capture_frame` writes one image per frame                     | Zero codec dependencies in core; simplest possible readback                        | User assembles the movie externally ([no codec/muxing][codec-muxing])             |
| Modular sibling crates (audio/OSC/MIDI/laser/`wgpu`)           | Opt-in weight; core stays lean; installation/AV support first-party                | Feature discovery spread across crates; version churn across the workspace        |
| `0.20` rebuild onto **Bevy**                                   | Inherits a maintained renderer, ECS, 3D, compute shaders; Draw usable in Bevy apps | Large breaking rewrite; foundation now tracks Bevy's release pace and API surface |

---

## Sources

- [nannou guide][guide] — _"Nannou is an open-source, creative-coding toolkit for
  Rust."_; [Anatomy of a nannou app][guide-anatomy] (`model`/`update`/`view`,
  the `nannou::app(model).update(update).simple_window(view).run()` builder);
  [Drawing 2D shapes][guide-draw] (the `view` + `Draw` excerpt); [changelog][guide-changelog]
  (the `0.20.0` Bevy overhaul, per-version dates, `0.19` as the last pre-Bevy release).
- [`docs.rs/nannou 0.19.0`][docs-modules] — module list (incl. `ease`, `wgpu`,
  `text`); [`App`][docs-app] (`time` field, `draw`, `main_window`,
  `elapsed_frames`, `fps`); [`Update`][docs-update] (`since_last`/`since_start`);
  [`Window::capture_frame`][docs-window-capture]; [`Draw`][docs-draw] +
  [`Draw::text`][docs-draw-text]; [`text` module][docs-text] (RustType, no LaTeX);
  [`ease` module][docs-ease] (Penner functions via `pennereq`).
- [`docs.rs/nannou 0.18.0`][docs-crate] — the direct-`wgpu` crate description and
  `wgpu ^0.11` dependency (no Bevy).
- [`docs.rs/nannou_wgpu`][nannou-wgpu] — _"re-exports the entire `wgpu` crate"_;
  WebGPU as nannou's target spec.
- [gfx-rs/wgpu README][wgpu-readme] — _"It runs natively on Vulkan, Metal, D3D12,
  and OpenGL; and on top of WebGL2 and WebGPU on wasm."_
- [nannou repository][repo] — workspace layout (`nannou_core`, `nannou_draw`,
  `nannou_wgpu`, `nannou_audio`, `nannou_osc`, `nannou_midi`, `nannou_laser`, …);
  root `Cargo.toml` `license = "MIT OR Apache-2.0"`, `edition = "2024"`;
  [`nannou/Cargo.toml`][nannou-crate-toml] _"A Creative Coding Framework for
  Rust."_
- [lib.rs/crates/nannou][librs] — first release `0.1.0` (Oct 16 2017), latest
  `0.20.0` (Jun 22 2026).

<!-- References -->

<!-- concepts.md anchors -->

[retained-vs-immediate]: ./concepts.md#retained-vs-immediate-mode
[mobject]: ./concepts.md#mobject-and-the-scene-graph
[interpolation]: ./concepts.md#interpolation-and-lerp
[rate-function]: ./concepts.md#rate-function-and-easing
[execution-models]: ./concepts.md#execution-models
[rasterization]: ./concepts.md#rasterization
[cpu-vs-gpu]: ./concepts.md#cpu-vector-vs-gpu-vector-rendering
[anti-aliasing]: ./concepts.md#anti-aliasing
[color-gamma]: ./concepts.md#color-model-and-gamma
[glyph-outline]: ./concepts.md#glyph-outline-extraction
[text-shaping]: ./concepts.md#text-shaping
[frame-capture]: ./concepts.md#frame-capture-and-readback
[codec-muxing]: ./concepts.md#codec-muxing-and-pixel-format
[deterministic]: ./concepts.md#deterministic-frame-sampling

<!-- Runnable probes (checked via the ignoreDeadLinks /\.d$/ rule) -->

[ex-bezier]: ./examples/bezier-eval.d
[ex-rate]: ./examples/rate-functions.d
[ex-affine]: ./examples/affine-transform.d
[ex-capture]: ./examples/frame-capture.d

<!-- External primary sources -->

[repo]: https://github.com/nannou-org/nannou
[nannou-crate-toml]: https://github.com/nannou-org/nannou/blob/b699dc67d3670090d46531e9380676ddbac6dcfb/nannou/Cargo.toml
[guide]: https://guide.nannou.cc/
[guide-anatomy]: https://guide.nannou.cc/tutorials/basics/anatomy-of-a-nannou-app
[guide-draw]: https://guide.nannou.cc/tutorials/basics/drawing-2d-shapes
[guide-changelog]: https://guide.nannou.cc/changelog.html
[docs-modules]: https://docs.rs/nannou/0.19.0/nannou/index.html
[docs-app]: https://docs.rs/nannou/0.19.0/nannou/app/struct.App.html
[docs-update]: https://docs.rs/nannou/0.19.0/nannou/event/struct.Update.html
[docs-window-capture]: https://docs.rs/nannou/0.19.0/nannou/window/struct.Window.html#method.capture_frame
[docs-draw]: https://docs.rs/nannou/0.19.0/nannou/draw/struct.Draw.html
[docs-draw-text]: https://docs.rs/nannou/0.19.0/nannou/draw/struct.Draw.html#method.text
[docs-text]: https://docs.rs/nannou/0.19.0/nannou/text/index.html
[docs-ease]: https://docs.rs/nannou/0.19.0/nannou/ease/index.html
[docs-crate]: https://docs.rs/nannou/0.18.0/nannou/index.html
[nannou-wgpu]: https://docs.rs/nannou_wgpu/0.19.0/nannou_wgpu/index.html
[wgpu-readme]: https://github.com/gfx-rs/wgpu
[librs]: https://lib.rs/crates/nannou
[processing]: https://processing.org/
