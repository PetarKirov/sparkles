# Javis.jl (Julia)

A frame-function animation layer on top of [`Luxor.jl`][luxor-repo]'s
Cairo-backed 2D vector drawing — you build a `Video`, attach `Object`s that each
run a Luxor drawing function over a frame range, apply `Action`s eased by
[`Animations.jl`][anim-repo], and `render` the result to a gif or mp4.

| Field                 | Value                                                                                                                                         |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | Julia                                                                                                                                         |
| License               | MIT — _"MIT License … Copyright (c) 2020 Ole Kröger `<o.kroeger@opensourc.es>` and contributors"_ ([`LICENSE`][javis-license])                |
| Repository            | [`JuliaAnimators/Javis.jl`][javis-repo]                                                                                                       |
| Documentation         | [`juliaanimators.github.io/Javis.jl`][javis-docs]                                                                                             |
| Category              | Frame-function **2D animation layer** over Luxor/Cairo — _"just an animation layer on top of it"_ ([tutorial 1][t1])                          |
| First release         | 2020 (`LICENSE` copyright `2020`); latest release **`v0.9.0`** (May 26 2022); reviewed Jul 11 2026                                            |
| Drawing layer (Luxor) | [`Luxor.jl`][luxor-repo] → [`Cairo.jl`][cairo-jl] → the [Cairo graphics library][cairo] — a **CPU vector** rasterizer                         |
| Luxor version pin     | `Luxor = "2.12, 3"` in [`Project.toml`][javis-toml] — will **not** resolve against today's Luxor `v4`                                         |
| Video output          | gif (via [`FFMPEG.jl`][ffmpeg-jl] `palettegen`/`paletteuse`) or mp4 (via [`VideoIO.jl`][videoio] `libx264`, `crf=23`); default framerate `30` |
| Maintenance           | **Dormant.** Last release May 2022; last commit to `master` Aug 2022 (see the warning below)                                                  |

> [!WARNING]
> **Javis is effectively dormant.** Its most recent registered release is
> `v0.9.0` (May 26 2022) and the last commit to `master` is dated August 2022 —
> roughly four years stale as of this review (July 2026). Its
> [`Project.toml`][javis-toml] pins `julia = "1.5"` and `Luxor = "2.12, 3"`, so
> it does not resolve against the currently-maintained Luxor `v4.x`. The drawing
> layer it sits on, [`Luxor.jl`][luxor-repo], is by contrast **actively
> maintained** (`v4.5.0`, April 9 2026). Treat Javis as a well-documented but
> frozen design study, and Luxor as the live substrate underneath it.

---

## Overview

### What it solves

Javis is a Julia package for scripting mathematical animations and
visualizations. Its own tagline is deliberately modest —
_"`Javis` makes generating simple animations a breeze!"_ ([`README.md`][javis-repo],
where the name expands to _"**J**ulia **A**nimations and **Vis**ualizations"_) —
and the first tutorial states the architecture plainly:

> _"`Javis.jl` is an abstraction on top of powerful graphics tools to make
> animations and visualizations easy to create. It is built on top of the
> fantastic Julia drawing packages, `Luxor.jl` and `Cairo.jl`."_ — [tutorial 1][t1]

The division of labour is the whole point: **Luxor does the drawing, Javis does
the timing.** Javis contributes the `Video` canvas, the frame-range object model,
the `Action`/easing timeline, and the encode step; every actual mark on the
canvas is a Luxor call (`circle`, `line`, `poly`, `sethue`, `background`). The
tutorial is explicit about this seam:

> _"In general you can use all `Luxor` functions inside `Javis`. `Javis` is just
> an animation layer on top of it."_ — [tutorial 1][t1]

For this survey Javis is the exemplar of a **frame-function drawing engine**: it
has no retained [`Mobject`][mobject] scene graph of vector geometry the way Manim
does. Each frame is produced by _re-running_ every active object's drawing
function from scratch, so an "object" is a frame-scoped Luxor script, not a
persistent [`VMobject`][vmobject] whose control points are interpolated.

### Design philosophy

Javis calls its authoring model the **Object–Action paradigm**:

> _"We use Object-Action paradigm for creating visualizations."_ —
> [`README.md` § Design Philosophy][javis-repo]

The [project mission][mission] frames the scope, and is candid about what Javis
is _not_:

> _"`Javis.jl` is a tool focused on providing an easy to use interface for making
> animations and developing visualizations quickly - while having fun! 😃"_ —
> [mission][mission]

> _"**Javis is not a plotting library.** … **Javis focuses on freedom for the
> user.** We approach Javis in the same way an artist approaches an empty canvas.
> We provide the basic tools but it is up to the user to create most of the
> functionality they wish to see."_ — [mission][mission]

The lineage is stated outright — _"Our project mission was inspired by the
mission, philosophy, and interface of projects such as manim, Fedora, Zotero…"_
([mission][mission]) — and the acknowledgements thank _"Grant Sanderson of
3blue1brown … for inspiring us to create something like this in Julia"_ and
_"Cormullion the inventor of `Luxor.jl`"_ ([`README.md`][javis-repo]). So Javis
is a Manim-inspired _idea_ re-expressed on a Cairo scripting stack, not a
re-implementation of Manim's retained-geometry engine.

---

## How it works

A Javis program is four moves: declare a `Video`, register `Object`s over frame
ranges, attach `Action`s, then `render`. Everything drawn inside an object is
Luxor.

**The `Video` canvas.** `Video(width, height)` allocates the pixel canvas and
becomes the implicit target of every subsequent object — _"Defines the video
canvas for an animation"_ ([`Video.jl`][video-src]):

```julia
using Javis
myvideo = Video(500, 500)   # width × height in pixels; sets CURRENT_VIDEO
```

**`Object` = a frame range + a Luxor drawing function.** An
[`Object`][object-src] is _"what is drawn in a defined frame range"_; its function
_"gets called with the arguments `video, object, frame`"_. The body is ordinary
Luxor:

```julia
function ground(args...)
    background("white")   # Luxor: fill the canvas
    sethue("black")       # Luxor: set the pen colour
end

Background(1:70, ground)                              # applied to all later objects
red_ball = Object(1:70, (args...) -> object(O, "red"), Point(100, 0))
```

`Background` is a special object that _"specif[ies] that the ground function is
applied to all objects afterwards"_ ([tutorial 1][t1]); `O` is Luxor's shorthand
for the origin `Point(0, 0)`, which Luxor places at the **centre** of the canvas
with the y-axis pointing down.

**`Action`/`act!` animate the object over its frames.** An
[`Action`][action-src] _"gives an `Object` … the opportunity to move, change
color or much more"_; its function takes `video, object, action, rel_frame`, and
its frames are **relative to the parent object** (`1:10` = the object's first ten
frames, _not_ the video's). `act!` attaches actions:

```julia
obj = Object((args...) -> circle(O, 50, :fill))
act!(obj, Action(1:20, appear(:fade)))          # fade in over the object's frames 1–20
act!(obj, Action(21:50, Translation(50, 50)))   # then translate
act!(obj, Action(81:100, disappear(:fade)))     # then fade out
```

Predefined actions include [`appear`/`disappear`][action-anim-src],
`translate`/`anim_translate`, `rotate`/`rotate_around`/`anim_rotate_around`,
`scale`/`anim_scale`, `follow_path`, and `morph_to`.

**Easing via `Animations.jl`.** The `Action`'s optional animation argument is an
easing function or a full [`Animations.jl`][anim-repo] `Animation`; _"The default
is `linear()`"_ and _"Possible simple easing functions is `sineio()`"_
([`Action.jl`][action-src]). Either supply a keyframed `Animation`, or pass an
easing per action:

```julia
using Javis, Animations
# keyframed animation: times 0→1, values, per-segment easings
circle_anim = Animation([0.0, 0.3, 0.6, 1.0],
                        [O, Point(150, 0), Point(150, 150), O],
                        [sineio(), polyin(5), expin(8)])
act!(obj, Action(1:150, circle_anim, translate()))
# …or the simpler per-action easing form:
act!(obj, Action(1:50,  sineio(), anim_translate(150, 0)))
act!(obj, Action(51:100, polyin(2), anim_translate(0, 150)))
```

**Frame specifications.** Frames are a `UnitRange` (`1:70`), the symbols `:same`
(reuse the previous element's frames) or `:all`, an [`RFrames`][rframes-src]
(_"define frames in a relative fashion"_ — `RFrames(10)` = the next ten frames
after the previous object), or, inside an `Action`, a [`GFrames`][gframes-src]
(_"define frames in a global fashion"_ — a video-absolute range translated into
each object's local timeline). A [`Frames`][frames-src] value _"stores the actual
computed frames and the user input … The `frames` are computed in `render`"_.

**`render` produces the file.** `render(video; pathname="out.gif")` _"Renders all
previously defined `Object` drawings to the user-defined `Video` as a gif or
mp4"_ ([`render`][render-src]):

```julia
render(myvideo; pathname="tutorial_1.gif")   # framerate defaults to 30
```

### How Luxor works (the drawing substrate)

Because Javis is inseparable from it, the drawing layer deserves its own note.
[`Luxor.jl`][luxor-repo] is _"a Julia package for drawing simple static 2D vector
graphics"_ whose _"aim … is to provide an easy to use 'scripting-like' interface
to Cairo.jl"_ ([`luxorcairo.md`][luxorcairo]):

> _"The focus of Luxor is on simplicity and ease of use: it should be easier to
> use than plain `Cairo.jl`, with shorter names, fewer underscores, default
> contexts, and simplified functions."_ — [`index.md`][luxor-index]

It is **procedural and CPU-vector**: _"Luxor is thoroughly procedural and static:
your code issues a sequence of simple graphics 'commands' until you've completed a
drawing, then the results are saved into a PDF, PNG, SVG, or EPS file"_
([`index.md`][luxor-index]). A drawing function issues commands like
`background`, `sethue`, `setline`, `circle`, `line`, `poly`, `rect`, `text` — the
exact vocabulary a Javis object body uses. Luxor even points _back_ at Javis for
motion: _"If you want to build complex or elaborate animations, use `Javis.jl` and
`Makie`"_ ([`index.md`][luxor-index]).

The rest of this page walks the survey's [eight axes][concepts] against this
Javis-over-Luxor machinery.

---

## Object & scene model

Javis is best described as **retained object list, immediate-mode drawing**. The
`Video` keeps a list (`video.objects`) of every `Object` you register, so in that
weak sense the object _set_ is retained. But an `Object` holds a **function**, not
geometry: its field is _"`func::Function`: The drawing function which draws
something on the canvas"_ ([`Object.jl`][object-src]). There is no persistent
tree of vector paths — no [`Mobject`][mobject] family, no submobject list of
[`VMobject`][vmobject] control points. Each frame, `render` calls every active
object's `func(video, object, frame)`, and the function _redraws from scratch_
with Luxor. That is the [immediate-mode][immediate] half of the survey's
[retained-vs-immediate][immediate] axis, wrapped in a retained registry.

What a Javis "object" _does_ carry is a small state record —
`start_pos::Union{Object,Point}` (its origin, _"It gets translated to this
point"_), a `current_setting::ObjectSetting`, an `actions` vector, and a
`result::Vector` (whatever the drawing function returned). The `result` is how one
object reads another's live state: `pos(object)` (short for `get_position`) reads
a moving object's current point so a later object can draw a trail or a connector
to it ([tutorial 1][t1] threads `pos(red_ball)` into a `path!`/`connector`
function). This is Javis's answer to Manim's [updater/`ValueTracker`][mobject]
reactivity — a pull of the previous frame's returned value, not a dependency
graph.

**Grouping** is provided by _layers_ (`@JLayer`), a sub-canvas of objects that an
`Action` transforms as a unit — _"an action is applied to a layer as a whole and
not on the objects inside it"_ ([`act!`][object-src]). There is no deeper
scene-graph nesting or parent/child dirty-flag propagation; the model is
intentionally flat.

---

## Animation & timing model

This is Javis's defining axis. Its [execution model][exec] is an **imperative
construction phase followed by a frame-function sampling phase**: `Object`,
`Background`, `Action`, and `act!` calls build up `video.objects`; then `render`
iterates the frame indices and, for each, replays the active objects and their
actions. Contrast Manim, whose `self.play(...)` steps a play-loop that
_interpolates the control points of a retained VMobject_; Javis instead re-executes
draw functions and lets each `Action` mutate the Luxor coordinate system (a
`translate`/`rotate`/`scale`) or the object's drawing parameters for that frame.

- **Frames are relative and composable by construction.** An action's frames are
  _"defined in a relative fashion so `1:10` means the first ten frames of the
  object and **not** the first ten frames of the `Video`"_
  ([`Action.jl`][action-src]). Sequencing is expressed by adjacent ranges
  (`1:20`, `21:50`, `81:100`) or relatively with [`RFrames`][rframes-src]; this is
  Javis's flavour of [animation composition][compose] — a hand-laid timeline of
  ranges rather than an `AnimationGroup`/`LaggedStart` combinator algebra.
- **Interpolation and easing come from `Animations.jl`.** The `Action`'s
  `anim::Animation` reshapes the relative time parameter before the action runs —
  the survey's [rate-function/easing][easing] step. `get_interpolation(action,
rel_frame)` evaluates the eased value that `_translate`/`_rotate`/`_scale` then
  apply. Javis ships the raw easing names of `Animations.jl` (`linear`, `sineio`,
  `polyin`, `expin`, …) rather than Manim's named `smooth`/`rush_into` set; the
  underlying idea (an eased `[0,1]→[0,1]` remap before the base
  [lerp][interp]) is identical, and is what the
  [`rate-functions.d`](./examples/rate-functions.d) probe tabulates.
- **`morph_to` is Javis's `Transform`.** It tweens one shape into another and
  faces the same [point-count alignment][align] problem Manim's `Transform` does —
  but solved over **Luxor polygons** (`Vector{Point}`), not Bézier control nets.
  `match_num_points` _"points are added to the polygon with less points until both
  polygons have the same number of points"_ ([`morphs.jl`][morphs-src]);
  `add_points!` distributes the new nodes by arc-length (`polydistances`);
  `compute_shortest_morphing_dist` _"Rotates `from_poly` internally to check which
  mapping produces the smallest morphing distance"_ (a cyclic-offset search for a
  natural point correspondence); and `reorder_match` uses the Hungarian algorithm
  (`Hungarian.jl`) to pair up multiple sub-shapes. It is explicitly limited:

  > _"Currently morphing is quite simple and only works for basic shapes. It
  > especially does not work with functions which produce more than one polygon or
  > which produce filled polygons."_ — [`morph_to`][morphs-src]

  Because Javis flattens to polylines and equalises by _inserting points along
  arc length_ (not by [de Casteljau][debasis] curve subdivision on a shared Bézier
  [basis][debasis]), its morph is a coarser cousin of the alignment the
  [`bezier-eval.d`](./examples/bezier-eval.d) probe demonstrates.

---

## Rendering backend & rasterization

Javis has **exactly one backend: Luxor over Cairo — a [CPU-vector][cpuvsgpu]
rasterizer**, with no GPU path at all. This is the opposite pole from ManimGL or
GLMakie, and it makes Javis' output deterministic by construction (the
[CPU-vector oracle][cpuvsgpu] the survey prizes). Every frame is
[rasterized][raster] by Cairo: Javis draws each object into a Cairo surface via
Luxor, then reads the surface back as an image matrix (`get_javis_frame` →
`Matrix{RGB{N0f8}}`) for encoding.

- **[Anti-aliasing][aa]** is Cairo's analytic coverage AA on vector edges —
  inherited wholesale from the drawing layer, not something Javis configures. The
  [`frame-capture.d`](./examples/frame-capture.d) probe's 1px analytic disc-edge
  coverage stands in for this CPU path.
- **[Color model / gamma][color]** is delegated: Luxor takes colours through
  `Colors.jl` (`sethue("red")`, RGB/HSV/named CSS colours) and Cairo does the
  compositing. Javis adds no colour-space policy of its own; it lerps colour
  channels through `Animations.jl` where an action animates a colour, and leaves
  blending/premultiplication to Cairo.
- **Resolution** is the `Video`'s pixel `width`/`height`; `render` also exposes a
  `rescale_factor` to downscale frames _"for faster rendering"_
  ([`render`][render-src]).

There is no `WGLMakie`-style browser target and no signed-distance-field glyph
path — the reproducibility/quality trade-off the survey draws between CPU and GPU
backends is resolved entirely on the CPU side here.

---

## Typesetting & text

Text has two routes, both ultimately Luxor/Cairo.

- **Plain text via Luxor.** Luxor offers _"two ways to draw text … the so-called
  'toy' API or the 'pro' API"_ ([`text.md`][luxor-text]). The **Toy API**
  (`text`, `fontface`, `fontsize`) is Cairo's toy text interface; the **Pro API**
  (`setfont`, `settext`) adds alignment, rotation, and _"the presence of any
  pseudo-Pango-flavored markup"_ ([`text.md`][luxor-text]) — i.e. Pango/HarfBuzz
  [shaping][shaping] through Cairo. A Javis object simply calls these inside its
  drawing function. Rendering glyphs as _animatable vector outlines_ (Manim's
  [glyph-outline extraction][glyph]) is not Javis's default path — text is drawn
  by Cairo like any other mark.
- **LaTeX via MathJax → SVG → Luxor paths.** Javis renders `LaTeXString`s
  (`L"9\frac{3}{4}"`, from [`LaTeXStrings.jl`][latexstrings]) through its own
  [`latex()`][latex-src] function. Crucially, it does **not** shell out to a TeX
  distribution and `dvisvgm` the way both Manim forks do; it uses **MathJax's
  Node CLI** to produce SVG, which `svg2luxor` then parses into Luxor paths. The
  dependency is explicit:

  > _"**This only works if `tex2svg` is installed.** It can be installed using the
  > following command … `npm install -g mathjax-node-cli`"_ — [`latex.jl`][latex-src]

  So Javis's math pipeline is a _variant_ of the survey's [LaTeX-to-SVG][latex2svg]
  route — MathJax instead of `latex`+`dvisvgm`, but the same "typeset to SVG, then
  ingest the SVG paths as vector geometry" shape, disk-independent of a full TeX
  install (only Node + `mathjax-node-cli`).

> [!NOTE]
> The _modern_ Luxor (`v4`) gained native LaTeX/Typst typesetting via weak-dep
> extensions ([`MathTeXEngine.jl`][mathtex] + [`LaTeXStrings.jl`][latexstrings],
> and `Typstry` for [Typst][typst], per Luxor's [`Project.toml`][luxor-toml]).
> Javis cannot use them: it is pinned to Luxor `2.12, 3`, predating those
> extensions, so its LaTeX story remains the MathJax/`tex2svg` path above.

---

## Output & encoding

`render` performs the survey's [frame-capture-and-readback][readback] then
[codec/muxing/pixel-format][codec] steps, choosing the pipeline by file
extension.

- **Readback.** For each frame, Javis composites the objects into a Cairo surface
  and reads it back as a `Matrix{RGB{N0f8}}` image (the
  [`frame-capture.d`](./examples/frame-capture.d) probe models this
  render→framebuffer step).
- **gif** (default): each frame is written as a zero-padded PNG into a temp
  directory, then [`FFMPEG.jl`][ffmpeg-jl] builds the gif in two passes — a
  `palettegen` pass to derive an optimal palette, then a `paletteuse` pass —
  straight from the source ([`render`][render-src]):

  ```julia
  ffmpeg_exe(`-loglevel $(ffmpeg_loglevel) -i $(tempdirectory)/%10d.png -vf
              palettegen $(tempdirectory)/palette.png`)
  ffmpeg_exe(`-loglevel $(ffmpeg_loglevel) -framerate $framerate -i $(tempdirectory)/%10d.png
              -i $(tempdirectory)/palette.png -lavfi paletteuse -y $pathname`)
  ```

- **mp4**: frames stream to [`VideoIO.jl`][videoio] via
  `open_video_out(pathname, frame_image, framerate=…, encoder_options=(crf=23,
preset="medium"))` and `write(video_io, frame_image)` — an in-process libav
  H.264 (`libx264`) encode ([`render`][render-src]). Any other extension errors:
  _"Currently, only gif and mp4 creation is supported."_
- **framerate** defaults to `30`; `render` also exposes `postprocess_frame` and
  `postprocess_frames_flow` hooks (e.g. `postprocess_frames_flow=reverse` to
  reverse a clip) and a `streamconfig` for experimental livestreaming.

So Javis straddles both integration styles the survey names: an **ffmpeg
subprocess** for gif and **in-process libav** (through `VideoIO`) for mp4.

---

## Interactivity, preview & authoring

Authoring is a plain Julia script (or REPL/notebook), and preview is a
first-class feature rather than an afterthought. `render(video; liveview=true)`
opens an interactive frame viewer — a `Gtk`/`GtkReactive` window
([`javis_viewer.jl`][javis-repo], deps `Gtk`, `GtkReactive`, `Interact`) with a
slider to scrub frames while developing. Inside notebooks the same call returns
the frames for **Jupyter** and **Pluto** viewers (the `render` body special-cases
`IJulia` and `PlutoRunner`), so an author can preview interactively and then flip
to a file render from one script.

This is a genuinely different authoring loop from a play-loop engine: because
each frame is an independent function of its index, `liveview` can jump to any
frame directly (no need to replay a timeline up to it) — an ergonomic dividend of
the [frame-function execution model][exec]. What Javis does _not_ offer is a live,
in-window scene-graph editor or GPU real-time playback; preview is a scrubber over
CPU-rendered frames.

---

## Extensibility & API surface

The API surface is deliberately thin because **Luxor is the extension point**.

- **Pass-through to Luxor.** _"you can use all `Luxor` functions inside `Javis`"_
  ([tutorial 1][t1]); Javis re-exports the Luxor names it needs, so custom drawing
  is just writing a Julia function of `(video, object, frame)` that calls Luxor.
  (Javis even warns _against_ `using Luxor` alongside it, to avoid method-ambiguity
  from the re-exports.)
- **Shorthand objects.** Convenience constructors wrap common Luxor shapes as
  ready-made objects — [`JCircle`, `JBox`, `JLine`, `JRect`, `JEllipse`, `JPoly`,
  `JStar`][javis-repo] — and `JShape` lets you register a custom shorthand.
- **Custom actions.** An `Action`'s function is an arbitrary
  `(video, object, action, rel_frame)` closure, so new animation behaviours are
  ordinary closures over `get_interpolation`; `change` animates arbitrary drawing
  keywords, and `follow_path` drives an object along a point list.
- **Layers.** `@JLayer` groups objects into a transformable, cacheable sub-canvas.

The trade-off is that the _animation_ vocabulary (`appear`, `disappear`,
`translate`, `rotate`, `scale`, `morph_to`, `follow_path`) is small and fixed;
richness comes from composing Luxor drawing with `Animations.jl` easings, not from
a deep built-in animation library.

---

## Determinism, caching & performance

- **[Deterministic frame sampling][determinism].** Strong. The sole backend is
  Cairo CPU-vector rendering, which is bit-reproducible for a fixed Cairo build —
  Javis inherits the survey's [CPU-oracle][cpuvsgpu] reproducibility for free, and
  a frame is a pure function of its index, so re-rendering yields identical output.
  The [`frame-capture.d`](./examples/frame-capture.d) probe's FNV-1a checksum
  illustrates the determinism a Cairo render provides.
- **[Content-hash caching][cache] — N/A.** This is a real finding: Javis has **no
  partial-movie / per-`play()` render cache** of the kind Manim community relies
  on. `render` unconditionally re-draws **every** frame from scratch (a
  `@showprogress … for frame in frames` loop that recomputes each object's
  drawing), writes each to a temp PNG (gif) or streams it to the encoder (mp4),
  and there is no input-hash short-circuit for unchanged segments. The caching
  lever that makes Manim's iterate-render loop fast has no analog here.
- **Performance.** Rendering cost is linear in `frames × drawing-complexity` and
  CPU-bound in Cairo; there is no GPU acceleration and no incremental recompute
  between frames. `rescale_factor` (render smaller, upscale) is the main built-in
  speed knob, plus Julia's usual first-call ("time-to-first-plot") compilation
  cost. For long or heavy animations this is the weakest axis — every frame pays
  full price, every run.

---

## Strengths

- **Clean separation of concerns.** Luxor draws, Javis times — _"just an animation
  layer on top of it"_ ([tutorial 1][t1]) — so the full power of a mature 2D
  vector library is available inside every frame with no wrapper API to learn.
- **Deterministic CPU-vector output.** One Cairo backend means bit-reproducible
  frames and a pure frame-of-index model — ideal for regression-testable video.
- **`Animations.jl` easing is expressive.** Keyframed `Animation`s with
  per-segment easings (`sineio`, `polyin`, `expin`, …) give fine-grained,
  composable motion control.
- **Preview is first-class.** `liveview`, Jupyter, and Pluto viewers scrub any
  frame directly — a dividend of the frame-function model.
- **Both encode styles.** gif via an ffmpeg palette pipeline and mp4 via
  in-process `VideoIO` H.264, from one `render` call.
- **Well-documented.** Eight tutorials, a mission statement, and a worked LaTeX
  path make it an unusually legible design study.

## Weaknesses

- **Dormant.** No release since May 2022, no commits since Aug 2022; pinned to
  `julia 1.5` and `Luxor 2.12/3`, so it will not co-install with today's Luxor
  `v4`.
- **No render cache.** Every frame re-renders on every run; no
  [content-hash][cache] partial-movie reuse.
- **CPU-only, no GPU.** No real-time GPU playback or WebGL target; performance is
  Cairo-bound.
- **Morphing is limited.** _"only works for basic shapes … does not work with
  functions which produce more than one polygon or which produce filled polygons"_
  ([`morphs.jl`][morphs-src]); polygon-arc-length alignment, not Bézier
  subdivision.
- **No retained vector scene graph.** Objects are frame-scoped draw functions, not
  a persistent [`Mobject`][mobject]/[`VMobject`][vmobject] tree — cross-object
  relations are read back through `pos()`/`result`, not a dependency graph.
- **LaTeX needs an external Node toolchain** (`mathjax-node-cli`/`tex2svg`), and
  can't use modern Luxor's native math extensions because of the version pin.

---

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                  | Trade-off                                                                         |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Be an animation _layer_ over Luxor, not a drawing engine         | Reuse a mature 2D vector library; _"just an animation layer on top of it"_ | Inherits Luxor's model wholesale — CPU-only, no retained vector geometry          |
| Objects are frame-scoped _draw functions_, not retained geometry | Any Luxor code works per frame; frames are pure functions of their index   | No `Transform`-of-control-points; cross-object state pulled via `pos()`/`result`  |
| Frame-relative `Action`s eased by `Animations.jl`                | Timeline = adjacent ranges + external easing library; fine-grained motion  | No `AnimationGroup`/`LaggedStart` combinators; timing is hand-laid ranges         |
| `morph_to` over Luxor polygons (arc-length point matching)       | Simple, dependency-light shape tween using existing polygon tools          | Basic shapes only; no filled/multi-polygon morph; coarser than Bézier subdivision |
| Single Cairo CPU-vector backend                                  | Deterministic, bit-reproducible frames; the [CPU oracle][cpuvsgpu]         | No GPU/WebGL, no real-time playback; render cost is fully CPU-bound               |
| LaTeX via MathJax `tex2svg` → SVG → Luxor paths                  | Avoids a full TeX install; only Node's `mathjax-node-cli` needed           | External Node dependency; can't use modern Luxor's native `MathTeXEngine`/Typst   |
| No per-frame content-hash cache                                  | Simplicity; every frame is independently reproducible                      | Every `render` re-draws every frame — slow iterate loop on long/heavy animations  |
| First-class `liveview`/Jupyter/Pluto preview                     | Frame-of-index model lets any frame be viewed directly, no timeline replay | Preview is a CPU-frame scrubber, not a live GPU scene editor                      |

---

## Sources

- [`JuliaAnimators/Javis.jl`][javis-repo] `README.md` — tagline (_"makes
  generating simple animations a breeze!"_), _"Object-Action paradigm"_,
  acknowledgements crediting Luxor/Cairo and 3blue1brown, shorthand/viewer
  contributions.
- [`LICENSE`][javis-license] — _"MIT License … Copyright (c) 2020 Ole Kröger …"_.
- [`Project.toml`][javis-toml] — deps (`Animations`, `Cairo`, `Luxor`, `FFMPEG`,
  `VideoIO`, `LaTeXStrings`, `Hungarian`, `Gtk`/`GtkReactive`), `version = "0.8.0"`,
  compat `julia = "1.5"`, `Luxor = "2.12, 3"`.
- [project mission][mission] — scope statement, _"not a plotting library"_,
  inspiration from _"manim, Fedora, Zotero…"_.
- [tutorial 1][t1] — _"abstraction on top of … `Luxor.jl` and `Cairo.jl`"_, _"just
  an animation layer on top of it"_, the full `Video`/`Background`/`Object`/`act!`/
  `render` worked example, origin-at-centre note.
- [`src/structs/Video.jl`][video-src] · [`Object.jl`][object-src] ·
  [`Action.jl`][action-src] · [`Frames.jl`][frames-src] · [`RFrames.jl`][rframes-src]
  · [`GFrames.jl`][gframes-src] — the `Video`/`Object`/`Action`/`act!` data model
  and frame-spec docstrings.
- [`src/Javis.jl` `render`][render-src] — gif (`palettegen`/`paletteuse`) vs mp4
  (`open_video_out`, `crf=23`) pipelines, framerate `30`, postprocess/liveview
  hooks.
- [`src/action_animations.jl`][action-anim-src] — `appear`/`disappear`/`translate`/
  `rotate`/`scale`/`follow_path`, the `Animations.jl` `Animation`/`sineio`/`polyin`/
  `expin` easing examples, `get_interpolation`.
- [`src/morphs.jl`][morphs-src] — `morph_to` limitations, `match_num_points` /
  `add_points!` / `compute_shortest_morphing_dist` / `reorder_match` alignment.
- [`src/latex.jl`][latex-src] — `latex(LaTeXString, …)`, _"only works if `tex2svg`
  is installed"_, `mathjax-node-cli`.
- Luxor: [`JuliaGraphics/Luxor.jl`][luxor-repo] · [`LICENSE.md`][luxor-license]
  (MIT "Expat", _"Copyright (c) 2017-2022: cormullion and contributors"_) ·
  [`index.md`][luxor-index] (_"drawing simple static 2D vector graphics"_,
  procedural/static, PDF/PNG/SVG/EPS) · [`luxorcairo.md`][luxorcairo]
  (_"scripting-like interface to Cairo.jl"_) · [`text.md`][luxor-text] (Toy vs Pro
  text APIs, pseudo-Pango markup) · [`Project.toml`][luxor-toml] (`v4.6`,
  `julia = "1.9"`, `MathTeXEngine`/`LaTeXStrings`/`Typstry` extensions).
- [`Animations.jl`][anim-repo] · [`Animations.jl` docs][anim-docs] — the easing /
  keyframe-animation library Javis's `Action` uses.
- [`LaTeXStrings.jl`][latexstrings] · [`MathTeXEngine.jl`][mathtex] ·
  [`Cairo.jl`][cairo-jl] · [Cairo graphics library][cairo] · [`FFMPEG.jl`][ffmpeg-jl]
  · [`VideoIO.jl`][videoio] — the referenced dependencies.

<!-- References -->

[concepts]: ./concepts.md
[mobject]: ./concepts.md#mobject-and-the-scene-graph
[vmobject]: ./concepts.md#vmobject-and-vector-geometry
[debasis]: ./concepts.md#bezier-basis-quadratic-vs-cubic
[interp]: ./concepts.md#interpolation-and-lerp
[easing]: ./concepts.md#rate-function-and-easing
[compose]: ./concepts.md#animation-composition
[align]: ./concepts.md#transform-and-point-count-alignment
[exec]: ./concepts.md#execution-models
[immediate]: ./concepts.md#retained-vs-immediate-mode
[raster]: ./concepts.md#rasterization
[cpuvsgpu]: ./concepts.md#cpu-vector-vs-gpu-vector-rendering
[aa]: ./concepts.md#anti-aliasing
[color]: ./concepts.md#color-model-and-gamma
[glyph]: ./concepts.md#glyph-outline-extraction
[latex2svg]: ./concepts.md#latex-to-svg
[shaping]: ./concepts.md#text-shaping
[readback]: ./concepts.md#frame-capture-and-readback
[codec]: ./concepts.md#codec-muxing-and-pixel-format
[determinism]: ./concepts.md#deterministic-frame-sampling
[cache]: ./concepts.md#content-hash-caching
[javis-repo]: https://github.com/JuliaAnimators/Javis.jl
[javis-license]: https://github.com/JuliaAnimators/Javis.jl/blob/799b3bd6b12292976129c66def0505c056d31526/LICENSE
[javis-toml]: https://github.com/JuliaAnimators/Javis.jl/blob/799b3bd6b12292976129c66def0505c056d31526/Project.toml
[javis-docs]: https://juliaanimators.github.io/Javis.jl/stable/
[mission]: https://juliaanimators.github.io/Javis.jl/stable/mission/
[t1]: https://juliaanimators.github.io/Javis.jl/stable/tutorials/tutorial_1/
[video-src]: https://github.com/JuliaAnimators/Javis.jl/blob/799b3bd6b12292976129c66def0505c056d31526/src/structs/Video.jl
[object-src]: https://github.com/JuliaAnimators/Javis.jl/blob/799b3bd6b12292976129c66def0505c056d31526/src/structs/Object.jl
[action-src]: https://github.com/JuliaAnimators/Javis.jl/blob/799b3bd6b12292976129c66def0505c056d31526/src/structs/Action.jl
[frames-src]: https://github.com/JuliaAnimators/Javis.jl/blob/799b3bd6b12292976129c66def0505c056d31526/src/structs/Frames.jl
[rframes-src]: https://github.com/JuliaAnimators/Javis.jl/blob/799b3bd6b12292976129c66def0505c056d31526/src/structs/RFrames.jl
[gframes-src]: https://github.com/JuliaAnimators/Javis.jl/blob/799b3bd6b12292976129c66def0505c056d31526/src/structs/GFrames.jl
[render-src]: https://github.com/JuliaAnimators/Javis.jl/blob/799b3bd6b12292976129c66def0505c056d31526/src/Javis.jl
[action-anim-src]: https://github.com/JuliaAnimators/Javis.jl/blob/799b3bd6b12292976129c66def0505c056d31526/src/action_animations.jl
[morphs-src]: https://github.com/JuliaAnimators/Javis.jl/blob/799b3bd6b12292976129c66def0505c056d31526/src/morphs.jl
[latex-src]: https://github.com/JuliaAnimators/Javis.jl/blob/799b3bd6b12292976129c66def0505c056d31526/src/latex.jl
[luxor-repo]: https://github.com/JuliaGraphics/Luxor.jl
[luxor-license]: https://github.com/JuliaGraphics/Luxor.jl/blob/56d28c7f4fa3bc5d63a82a5abaadc30a7030e190/LICENSE.md
[luxor-index]: https://github.com/JuliaGraphics/Luxor.jl/blob/56d28c7f4fa3bc5d63a82a5abaadc30a7030e190/docs/src/index.md
[luxorcairo]: https://github.com/JuliaGraphics/Luxor.jl/blob/56d28c7f4fa3bc5d63a82a5abaadc30a7030e190/docs/src/explanation/luxorcairo.md
[luxor-text]: https://github.com/JuliaGraphics/Luxor.jl/blob/56d28c7f4fa3bc5d63a82a5abaadc30a7030e190/docs/src/howto/text.md
[luxor-toml]: https://github.com/JuliaGraphics/Luxor.jl/blob/56d28c7f4fa3bc5d63a82a5abaadc30a7030e190/Project.toml
[anim-repo]: https://github.com/jkrumbiegel/Animations.jl
[anim-docs]: https://jkrumbiegel.github.io/Animations.jl/stable/
[latexstrings]: https://github.com/stevengj/LaTeXStrings.jl
[mathtex]: https://github.com/Kolaru/MathTeXEngine.jl
[cairo-jl]: https://github.com/JuliaGraphics/Cairo.jl
[cairo]: https://www.cairographics.org/
[ffmpeg-jl]: https://github.com/JuliaIO/FFMPEG.jl
[videoio]: https://github.com/JuliaIO/VideoIO.jl
[typst]: https://typst.app/
