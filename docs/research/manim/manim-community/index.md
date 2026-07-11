# Manim Community Edition (Python)

The community-maintained fork of 3Blue1Brown's `manim`: a retained-mode,
CPU-vector 2D animation engine that turns a `Scene.construct` method into an
MP4 by rasterizing a [cubic-Bézier scene graph][scene-graph] with Cairo and
muxing the frames through [PyAV][pyav].

**Last reviewed:** July 11, 2026

| Field            | Value                                                                                                          |
| ---------------- | -------------------------------------------------------------------------------------------------------------- |
| Language         | Python (`requires-python >=3.11`, [`pyproject.toml:23`][pyproject])                                            |
| License          | MIT (`Copyright (c) 2024, the Manim Community Developers`, [`LICENSE.community`][license])                     |
| Repository       | [`ManimCommunity/manim`][repo] (reviewed at `4d25c031`, `v0.20.1`)                                             |
| Documentation    | [docs.manim.community][docs]                                                                                   |
| Category         | Retained-mode 2D vector animation engine (imperative scene-graph → video)                                      |
| First release    | `v0.1.0` — October 21, 2020, forked from `3b1b/manim` ([`0.1.0-changelog.rst`][changelog])                     |
| Default renderer | **Cairo** (CPU vector, `config.renderer == RendererType.CAIRO`); optional **OpenGL**/`moderngl`                |
| Bézier basis     | **Cubic** (Cairo `VMobject`, `n_points_per_cubic_curve = 4`); **quadratic** (`OpenGLVMobject`, `= 3`)          |
| Video encoder    | **PyAV** (`import av` → libav/FFmpeg): `libx264`/`yuv420p` default; `libvpx-vp9`, `qtrle` for webm/transparent |

> [!NOTE]
> Every `file:line` on this page is against the local clone at `4d25c031`
> (`v0.20.1`). The `manim` project ships **two** renderers with **two**
> geometry models in one tree; unqualified statements below describe the
> **default Cairo** path, and the OpenGL divergences are called out explicitly.
> The sibling deep-dive [`manimgl`][manimgl] covers 3Blue1Brown's upstream,
> which is quadratic-and-GPU throughout.

---

## Overview

### What it solves

`manim` is a library for **programmatic** explanatory-math animation: you
subclass `Scene`, build mathematical objects (`Mobject`s) in a `construct`
method, and call `self.play(Animation(...))` to advance time. The README states
the scope plainly:

> _"Manim is an animation engine for explanatory math videos. It's used to
> create precise animations programmatically, as demonstrated in the videos of
> 3Blue1Brown."_ — [`README.md`][readme]

The engine's job is the whole path from that Python description to an encoded
video: a [retained scene graph][retained] of vector objects, a
[time-sampled][deterministic] interpolation loop, a [CPU vector
rasterizer][raster], a [LaTeX/Pango typesetting][text] front-end, and a
[content-hash cache][caching] that skips re-rendering unchanged `play()` calls.

### Design philosophy

Manim CE began as a cleanup fork rather than a rewrite — the first changelog is
explicit:

> _"This is the first release of manimce after forking from 3b1b/manim. As
> such, developers have focused on cleaning up and refactoring the codebase
> while still maintaining backwards compatibility wherever possible."_ —
> [`0.1.0-changelog.rst`][changelog]

Three architectural commitments follow from that lineage and are load-bearing
for anything that reimplements the engine:

1. **Everything on screen is a `Mobject`.** The base class
   ([`mobject.py:72`][mobject]) is described as _"Mathematical Object: base
   class for objects that can be displayed on screen"_ — a tree of
   `submobjects` with a `points` array. Geometry, text, and groups are all the
   same node type.
2. **Vector-first, cubic-Bézier geometry.** A displayable shape is a
   `VMobject`: a flat `points` array grouped into 4-point cubic Bézier curves,
   rasterized by Cairo. Nothing is a bitmap until the final frame.
3. **A dual-backend metaclass, chosen at import.** `ConvertToOpenGL`
   ([`opengl_compatibility.py:17`][ogl-compat]) is a _"Metaclass for swapping
   (V)Mobject with its OpenGL counterpart at runtime depending on
   config.renderer"_ — so the same user class name resolves to a Cairo (cubic)
   or an OpenGL (quadratic) base class depending on `config`.

---

## How it works

A render is a straight-line pipeline. The CLI (`manim render scene.py Scene`,
built on `click`/`cloup`, [`__main__.py:3`][main]) instantiates the `Scene`,
runs `construct`, and each `self.play(...)` drives one iteration of the loop
below.

```python
# scene.py — the per-play() loop (CairoRenderer.play, cairo_renderer.py:64)
scene.compile_animation_data(*args, **kwargs)          # build Animation list, split moving/static
hash_current_animation = get_hash_from_play_call(      # content hash of this call
    scene, self.camera, scene.animations, scene.mobjects)
if self.file_writer.is_already_cached(hash_current_animation):
    self.skip_animations = True                        # cache hit → skip rendering
...
scene.play_internal()                                  # sample time, render, encode
self.num_plays += 1
```

`play_internal` ([`scene.py:1351`][scene]) samples wall-clock time into frames,
and for each frame sets every animation's progress and repaints:

```python
# scene.py:1364 — deterministic frame sampling + interpolate + render
self.time_progression = self._get_animation_time_progression(self.animations, self.duration)
for t in self.time_progression:                        # times = np.arange(0, run_time, 1/frame_rate)
    self.update_to_time(t)                             # alpha = t/run_time; animation.interpolate(alpha)
    self.renderer.render(self, t, self.moving_mobjects)
```

`update_to_time` ([`scene.py:1687`][scene]) computes `alpha = t / animation.run_time`
and calls `animation.interpolate(alpha)`, which reshapes `alpha` through the
`rate_func`, lerps each submobject's `points` and colors, and mutates the scene
graph in place. `renderer.render` then calls `camera.capture_mobjects`
([`camera.py:528`][camera]), which walks each `VMobject` into a Cairo path and
fills/strokes it, and `SceneFileWriter` encodes the resulting RGBA framebuffer
into a **partial movie file** — one per `play()` — through PyAV. `finish()`
concatenates the partials into the final MP4.

---

## Object & scene model

Manim is a **retained-mode scene graph** ([`../concepts.md`][retained]): the
`Scene` keeps a persistent list of `Mobject`s, animations _mutate_ those objects
between frames, and the renderer re-reads the whole graph each frame. `Mobject`
([`mobject.py:72`][mobject]) is a node holding `self.submobjects: list[Mobject]`
([`mobject.py:120`][mobject]) plus a `points` NumPy array and a `color`; its
`__init__` calls `reset_points()` / `generate_points()` / `init_colors()`
([`mobject.py:125-127`][mobject]) as empty template hooks subclasses fill in.

The submobject list is **one-directional**: `add` appends via
`self.submobjects = list_update(self.submobjects, unique_mobjects)`
([`mobject.py:560`][mobject]) with no parent back-reference, so the "family" of
a node is recomputed on demand by `get_family` ([`mobject.py:2518`][mobject]),
which chains children recursively and de-duplicates
(`extract_mobject_family_members`, [`family.py:12`][family]). New subclasses are
wired through `__init_subclass__` ([`mobject.py:100`][mobject]), which resets
`animation_overrides` and captures `_original__init__` per class — the hook that
lets `mob.animate.shift(...)` dispatch to a per-type override.

The renderer choice is baked into the _type_ via the `ConvertToOpenGL` metaclass
([`opengl_compatibility.py:28`][ogl-compat]): when `config.renderer ==
RendererType.OPENGL`, it rewrites a class's bases through a name map
(`"Mobject": OpenGLMobject, "VMobject": OpenGLVMobject`) so the same
`class Square(...)` inherits the quadratic-GPU or cubic-Cairo lineage. The full
object model, the cubic `points` layout, and the fill/stroke split are the
subject of [`scene-graph.md`][scene-graph].

---

## Animation & timing model

An `Animation` ([`animation.py:30`][animation]) is _"An animation. Animations
have a fixed time span."_ — a function of a scalar `alpha ∈ [0,1]` that mutates
its `mobject`. Its `__init__` ([`animation.py:128`][animation]) carries the four
timing knobs: `run_time`, `rate_func` (default `smooth`), `reverse_rate_function`,
and `lag_ratio`. Each frame, `interpolate_mobject` ([`animation.py:339`][animation])
zips the object's family members and applies a **staggered** sub-progress per
member via `get_sub_alpha` ([`animation.py:364`][animation]):

```python
# animation.py:384 — lag_ratio staggering of submobject i of n
full_length = (num_submobjects - 1) * lag_ratio + 1
value = alpha * full_length
lower = index * lag_ratio
return self.rate_func(value - lower)          # rate_func saturates outside [0,1]
```

The [rate function][rate] reshapes time (easing); it is _not_ clamped here
because every exported rate function is wrapped by the `unit_interval` decorator
([`rate_functions.py:124`][rate-fns]), which returns `0` for `t < 0` and `1` for
`t > 1`.

> [!WARNING]
> The default `rate_func` is **`smooth`** ([`rate_functions.py:156`][rate-fns]),
> a _normalized logistic sigmoid_ — `min(max((sigmoid(inflection·(t-0.5)) -
error) / (1 - 2·error), 0), 1)` with `inflection = 10.0` — **not** the
> smootherstep polynomial `6t⁵ − 15t⁴ + 10t³`. That polynomial is a _separate_
> function, `smootherstep` ([`rate_functions.py:174`][rate-fns]). The
> [`rate-functions.d`][ex-rate] probe reimplements `smootherstep` as a
> self-contained stand-in for the sigmoid; both are monotone `[0,1]→[0,1]`
> S-curves, but the exact default is the sigmoid.

Composition lives in [`composition.py`][composition]. `AnimationGroup`
([`composition.py:30`][composition]) lays its children on a timeline via
`build_animations_with_timings` ([`composition.py:146`][composition]) —
`start[1:] = cumsum(run_times[:-1] * lag_ratio)`, `end = start + run_times` — so
`lag_ratio = 0` plays all together, `1` is strict succession (`Succession`,
[`composition.py:198`][composition]), and fractional values overlap
(`LaggedStart`, [`composition.py:297`][composition]). `Transform`
([`transform.py:58`][transform]) is the workhorse morph: `begin`
([`transform.py:200`][transform]) calls `self.mobject.align_data(self.target_copy)`
to make point counts match, then `interpolate_submobject`
([`transform.py:249`][transform]) lerps `points` along a `path_func` and blends
color. See [`../concepts.md`][interp] and the [`rate-functions.d`][ex-rate] /
[`affine-transform.d`][ex-affine] probes.

---

## Rendering backend & rasterization

The default backend is **Cairo**, a CPU vector rasterizer
([`../concepts.md`][cpu-gpu]). `Camera` imports it directly
(`import cairo`, [`camera.py:15`][camera]) and binds a Cairo surface straight
onto the NumPy pixel buffer:

```python
# camera.py:591 — a Cairo context over the RGBA framebuffer
surface = cairo.ImageSurface.create_for_data(pixel_array.data, cairo.FORMAT_ARGB32, pw, ph)
ctx = cairo.Context(surface)
ctx.set_matrix(cairo.Matrix(pw/fw, 0, 0, -(ph/fh), ...))   # world → pixel affine
```

`display_vectorized` ([`camera.py:677`][camera]) draws each object as
**stroke(background) → fill → stroke**, and `set_cairo_context_path`
([`camera.py:698`][camera]) feeds Manim's cubic tuples to Cairo's cubic path API
one curve at a time: `ctx.curve_to(*p1[:2], *p2[:2], *p3[:2])`
([`camera.py:727`][camera]). Fill is `ctx.fill_preserve()`
([`camera.py:781`][camera]) — Cairo does its own scan-conversion and winding, so
Manim never triangulates for the Cairo path. [Anti-aliasing][aa] is Cairo's, not
Manim's. The framebuffer is 4-channel RGBA (`image_mode = "RGBA"`, `n_channels =
4`, [`camera.py:87`][camera]), and `renderer.get_frame` returns
`np.array(self.camera.pixel_array)` ([`cairo_renderer.py:181`][cairo-r]).

The optional **OpenGL** backend (`OpenGLRenderer`, `moderngl`) is a
[GPU vector renderer][cpu-gpu]: its `OpenGLVMobject` is quadratic
(`n_points_per_curve = 3`, [`opengl_vectorized_mobject.py:112`][ogl-vmob]) with
`quadratic_bezier_fill`/`quadratic_bezier_stroke` shaders, and fill is
GPU-triangulated by `earclip_triangulation`
([`space_ops.py:718`][space-ops], `mapbox_earcut`, [`space_ops.py:10`][space-ops]).
That earcut path is **only** reached from the OpenGL renderer
([`vectorized_mobject_rendering.py:162`][vmob-render]); the Cairo path never
calls it. The two rasterization models — and why cubic-vs-quadratic is
load-bearing — are detailed in [`scene-graph.md`][scene-graph] and the
[`bezier-eval.d`][ex-bezier] / [`frame-capture.d`][ex-frame] probes.

---

## Typesetting & text

Text is _also_ vector geometry — every glyph becomes `VMobject` outlines. Three
front-ends feed one SVG-to-`VMobject` importer:

- **LaTeX** — `SingleStringMathTex(SVGMobject)` ([`tex_mobject.py:46`][tex-mob])
  and its subclasses `MathTex` / `Tex` call `tex_to_svg_file`
  ([`tex_file_writing.py:35`][tex-write]), a multi-step **subprocess** pipeline:
  write `.tex` → `compile_tex` (a `subprocess.run` of `latex`/`pdflatex`/
  `lualatex`/`xelatex`, [`tex_file_writing.py:214`][tex-write]) → `.dvi`/`.xdv`/
  `.pdf` → `convert_to_svg` via `dvisvgm --no-fonts`
  ([`tex_file_writing.py:249`][tex-write], which turns glyphs into _paths_, not
  embedded fonts).
- **Pango** — `Text` / `MarkupText` (both `SVGMobject`,
  [`text_mobject.py:302`][text-mob]) shape non-math text through
  **`manimpango`** (`import manimpango`, [`text_mobject.py:66`][text-mob]):
  `manimpango.text2svg(...)` ([`text_mobject.py:818`][text-mob]) and
  `MarkupUtils.text2svg(...)` for markup ([`text_mobject.py:1367`][text-mob]).
- **Typst** — `typst_to_svg_file` ([`typst_file_writing.py:35`][typst-write])
  compiles Typst markup **in-process** to SVG (`typst_compiler.compile(...,
format="svg")`, [`typst_file_writing.py:100`][typst-write]) — no `dvisvgm`
  intermediate — behind the optional `typst>=0.14` extra.

All three land in `SVGMobject` ([`svg_mobject.py`][svg-mob], `svgelements` parser
at [`svg_mobject.py:11`][svg-mob]), whose `handle_commands`
([`svg_mobject.py:561`][svg-mob]) walks each path segment and _elevates_ lines
and quadratics into the cubic `points` array (or lowers cubics to quads under
OpenGL). The full LaTeX/Pango/Typst mechanics and glyph-outline extraction are
in [`text-pipeline.md`][text-pipeline].

---

## Output & encoding

Encoding is **PyAV** (`import av`, [`scene_file_writer.py:17`][writer]) — the
libav/FFmpeg Python bindings — with a distinctive **one-partial-movie-file-per-`play()`**
scheme that is the physical substrate of the cache. `open_partial_movie_stream`
([`scene_file_writer.py:540`][writer]) opens a container per call and picks the
codec/pixel-format:

| Output              | Codec        | Pixel format | Source                               |
| ------------------- | ------------ | ------------ | ------------------------------------ |
| default `.mp4`      | `libx264`    | `yuv420p`    | [`scene_file_writer.py:552`][writer] |
| `.webm`             | `libvpx-vp9` | `yuv420p`    | [`scene_file_writer.py:560`][writer] |
| `.webm` transparent | `libvpx-vp9` | `yuva420p`   | [`scene_file_writer.py:562`][writer] |
| transparent `.mov`  | `qtrle`      | `argb`       | [`scene_file_writer.py:566`][writer] |

Frames are pushed as `av.VideoFrame.from_ndarray(frame, format="rgba")`
([`scene_file_writer.py:449`][writer]) and muxed on a writer thread. In
`finish()`, `combine_files` writes an FFmpeg concat list and re-opens it with
`av.open(str(file_list), format="concat")`
([`scene_file_writer.py:652`][writer]) to produce the final video, stamped
`Rendered with Manim Community v{__version__}`. Subtitles use `srt`
(`srt.compose`, [`scene_file_writer.py:898`][writer]); PNG/GIF are alternate
`finish()` branches. See [`../concepts.md`][codec] and [`frame-capture.d`][ex-frame].

---

## Interactivity, preview & authoring

Manim is fundamentally a **batch renderer**, not a live tool. The default flow
renders to disk and then opens the file: `--preview`/`-p` triggers
`open_media_file` ([`file_ops.py:220`][file-ops]) _after_ the render completes.
There is no live Cairo window.

**Live interaction is OpenGL-only.** `Scene.interactive_embed`
([`scene.py:1412`][scene]) asserts `isinstance(self.renderer, OpenGLRenderer)`
([`scene.py:1415`][scene]) and drops into an IPython embedded shell over the
`moderngl` window; the Cairo backend has no equivalent. Authoring surfaces:
a `%%manim` Jupyter magic ([`ipython_magic.py`][ipy]), `Scene.next_section`
([`scene.py:340`][scene]) for chaptered output ([`section.py`][section]), and a
`checkhealth` CLI subcommand that verifies the LaTeX/FFmpeg toolchain. The CLI
subcommand set is `cfg`, `checkhealth`, `init`, `plugins`, `render`
([`manim/cli/`][cli]).

---

## Extensibility & API surface

The user-facing API is **subclassing + method chaining**: subclass `Scene`,
override `construct`, and compose `Mobject` subclasses whose methods return
`self`. Extension points:

- **`config`** — `ManimConfig` ([`_config/utils.py:145`][config]) is a
  `MutableMapping` described as _"a single source of truth for all of the
  library's customizable behavior"_, layering `default.cfg` (`configparser`) <
  CLI < programmatic assignment; `tempconfig` ([`_config/__init__.py:46`][config-init])
  scopes overrides. `RendererType` ([`constants.py:258`][constants]) is the
  `cairo`/`opengl` switch.
- **Animation overrides** — `Mobject.__init_subclass__` +
  `animation_override_for` let a `Mobject` subclass supply a custom animation
  for `mob.animate`.
- **Plugins** — a `manim plugins` subcommand and a `manim.plugins` package
  discover third-party `Mobject`/`Scene` extensions.
- **Custom `Mobject`s** — override `generate_points` to fill the `points` array;
  the base hooks are deliberately empty ([`mobject.py:468`][mobject]).

Dependencies (from [`pyproject.toml`][pyproject]) name the whole backend:
`pycairo`, `av`, `manimpango`, `svgelements`, `skia-pathops` (boolean path ops,
[`boolean_ops.py:8`][boolean]), `mapbox-earcut`, `numpy>=2.1`, `scipy`,
`networkx`, `pillow`, `pygments`, and `moderngl`/`moderngl-window` (all required,
though `moderngl` is only exercised by the OpenGL renderer). Only `typst`, `gui`
(`dearpygui`), and `jupyterlab` are `[project.optional-dependencies]` extras.

---

## Determinism, caching & performance

Two orthogonal determinism mechanisms make caching correct.

**Deterministic frame sampling.** `get_time_progression`
([`scene.py:1087`][scene]) samples `times = np.arange(0, run_time, 1 /
config["frame_rate"])` — a fixed grid independent of wall-clock speed
([`../concepts.md`][deterministic]), so a given animation always produces the
same frames at the same `t`.

**Per-`play()` content-hash caching.** Before rendering, `CairoRenderer.play`
computes `get_hash_from_play_call` ([`hashing.py:333`][hashing]) over the camera,
the animations, and the current mobjects. The docstring defines the key exactly:

> _"A string concatenation of the respective hashes of `camera_object`,
> `animations_list` and `current_mobjects_list`, separated by `_`."_ —
[`hashing.py:358`][hashing]

Each component is a `zlib.crc32` of a custom JSON serialization
([`hashing.py:366`][hashing]); run-dependent fields are stripped via
`KEYS_TO_FILTER_OUT = {"original_id", "background", "pixel_array",
"pixel_array_to_cairo_context"}` ([`hashing.py:29`][hashing]) — flagged in-source
as elements _"not suitable for hashing (too long or run-dependent)"_
([`hashing.py:27`][hashing]). The hash _is_ the partial-movie filename
(`f"{hash_animation}{movie_file_extension}"`, [`scene_file_writer.py:270`][writer]),
so `is_already_cached` ([`scene_file_writer.py:606`][writer]) is a single
`path.exists()`, and eviction is LRU by `st_atime` capped at `max_files_cached`
(default `100`, [`scene_file_writer.py:864`][writer]). The full mechanism,
including the circular-reference `_Memoizer` and the determinism it depends on,
is in [`caching.md`][caching].

**Performance profile.** The Cairo path is single-threaded per frame; the
encoder runs on a background writer thread. The static/moving split
(`begin_animations`, [`scene.py:1334`][scene]) paints non-moving objects once
into a static image, so only `moving_mobjects` are re-rasterized per frame.

---

## Strengths

- **Uniform object model.** Everything is a `Mobject` with a `points` array;
  geometry, text, and groups compose through one tree and one `interpolate`.
- **Cubic-Bézier vector geometry** feeds Cairo directly (`ctx.curve_to`) with no
  approximation — the on-screen curve is exactly the stored curve.
- **Correct, cheap caching.** Deterministic sampling + a content hash that _is_
  the filename makes cache hits a `path.exists()` check; unchanged `play()`
  calls cost nothing.
- **Rich typesetting.** LaTeX, Pango markup, and Typst all reduce to vector
  outlines, so math and text animate identically to shapes.
- **Batteries-included encoding.** PyAV covers MP4/WebM/GIF/PNG and transparent
  output without shelling out to a separate `ffmpeg` binary.

## Weaknesses

- **Two geometry models in one tree.** Cubic (Cairo) vs quadratic (OpenGL) means
  a curve is stored differently per backend, and the cubic→quadratic lowering is
  lossy ([`opengl_vectorized_mobject.py:499`][ogl-vmob]).
- **CPU-bound default renderer.** Cairo rasterizes one frame at a time on one
  thread; complex scenes are slow, and the OpenGL alternative is less mature.
- **Heavy external toolchain.** LaTeX text needs a full TeX install + `dvisvgm`
  as _subprocesses_; a missing binary fails at render time.
- **No live editing on the default backend.** Interactivity requires the OpenGL
  renderer; Cairo is render-then-open.
- **Fork drift.** API-compatible with `3b1b/manim` only "wherever possible";
  ManimGL and Manim CE have diverged substantially (see [`manimgl`][manimgl]).

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                             | Trade-off                                                                   |
| ------------------------------------------------ | --------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Retained scene graph of `Mobject`s               | One uniform node type; animations mutate persistent objects           | Whole graph re-read per frame; no immediate-mode escape hatch               |
| **Cubic** Bézier basis on the Cairo default      | Maps 1:1 to Cairo's `curve_to`; exact on-screen curves                | Diverges from the quadratic OpenGL/ManimGL basis; lossy interchange         |
| Dual backend via `ConvertToOpenGL` metaclass     | Same user code targets CPU-vector or GPU-vector by config             | Two geometry models, two rasterizers, two fill strategies to maintain       |
| Cairo (CPU) as default rasterizer                | Deterministic, dependency-light, high-quality AA out of the box       | Single-threaded per frame; GPU speed only via the less-mature OpenGL path   |
| Text = vector outlines (LaTeX/Pango/Typst → SVG) | Math and text animate exactly like shapes; resolution-independent     | Needs external TeX/`dvisvgm` subprocesses; slow first compile per string    |
| PyAV per-`play()` partial movie files            | Each call is an independent, cacheable, concatenatable clip           | Many small files; a concat pass and cache eviction to manage                |
| Content-hash cache keyed by the filename         | Cache hit is a `path.exists()`; deterministic sampling makes it sound | Hashing must strip run-dependent state; a missed field silently over-caches |

---

## Sources

Primary (local clone `ManimCommunity/manim@4d25c031`, `v0.20.1`):

- [`manim/mobject/mobject.py`][mobject] — `Mobject` base class, family tree,
  `interpolate`, `ConvertToOpenGL` wiring.
- [`manim/mobject/types/vectorized_mobject.py`][vmob] — cubic `VMobject`
  (`n_points_per_cubic_curve = 4`), fill/stroke arrays, `align_points`.
- [`manim/mobject/opengl/opengl_compatibility.py`][ogl-compat] ·
  [`opengl_vectorized_mobject.py`][ogl-vmob] — the quadratic OpenGL lineage.
- [`manim/animation/animation.py`][animation] · [`composition.py`][composition]
  · [`transform.py`][transform] — timing, `lag_ratio`, composition, morphs.
- [`manim/utils/rate_functions.py`][rate-fns] — `smooth` (sigmoid) and friends.
- [`manim/renderer/cairo_renderer.py`][cairo-r] · [`manim/camera/camera.py`][camera]
  — the Cairo render loop and vector rasterization.
- [`manim/scene/scene.py`][scene] · [`scene_file_writer.py`][writer] — the play
  loop, time sampling, PyAV encoding, partial-movie caching.
- [`manim/utils/hashing.py`][hashing] — `get_hash_from_play_call`, `_Memoizer`.
- [`manim/utils/tex_file_writing.py`][tex-write] · [`typst_file_writing.py`][typst-write]
  · [`manim/mobject/text/`][tex-mob] · [`manim/mobject/svg/svg_mobject.py`][svg-mob]
  — the typesetting front-ends and SVG-to-`VMobject` importer.
- [`manim/_config/utils.py`][config] · [`manim/constants.py`][constants] ·
  [`default.cfg`][default-cfg] · [`pyproject.toml`][pyproject] — config, renderer
  enum, dependencies.

Official docs: [docs.manim.community][docs] · reference [repository][repo].

Deep sub-topics: [scene graph & geometry][scene-graph] · [text
pipeline][text-pipeline] · [caching & determinism][caching]. Shared
vocabulary: [`../concepts.md`][concepts]. Sibling engine: [`manimgl`][manimgl].
Runnable probes: [`bezier-eval.d`][ex-bezier] · [`rate-functions.d`][ex-rate] ·
[`affine-transform.d`][ex-affine] · [`frame-capture.d`][ex-frame].

<!-- References -->

[scene-graph]: ./scene-graph.md
[text-pipeline]: ./text-pipeline.md
[caching]: ./caching.md
[concepts]: ../concepts.md
[manimgl]: ../manimgl.md
[retained]: ../concepts.md#retained-vs-immediate-mode
[interp]: ../concepts.md#interpolation-and-lerp
[rate]: ../concepts.md#rate-function-and-easing
[cpu-gpu]: ../concepts.md#cpu-vector-vs-gpu-vector-rendering
[raster]: ../concepts.md#rasterization
[aa]: ../concepts.md#anti-aliasing
[text]: ../concepts.md#latex-to-svg
[codec]: ../concepts.md#codec-muxing-and-pixel-format
[deterministic]: ../concepts.md#deterministic-frame-sampling
[ex-bezier]: ../examples/bezier-eval.d
[ex-rate]: ../examples/rate-functions.d
[ex-affine]: ../examples/affine-transform.d
[ex-frame]: ../examples/frame-capture.d
[repo]: https://github.com/ManimCommunity/manim
[docs]: https://docs.manim.community/en/stable/
[readme]: https://github.com/ManimCommunity/manim/blob/4d25c031/README.md
[changelog]: https://github.com/ManimCommunity/manim/blob/4d25c031/docs/source/changelog/0.1.0-changelog.rst
[license]: https://github.com/ManimCommunity/manim/blob/4d25c031/LICENSE.community
[pyproject]: https://github.com/ManimCommunity/manim/blob/4d25c031/pyproject.toml
[mobject]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/mobject.py
[vmob]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/types/vectorized_mobject.py
[ogl-compat]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/opengl/opengl_compatibility.py
[ogl-vmob]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/opengl/opengl_vectorized_mobject.py
[family]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/utils/family.py
[animation]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/animation/animation.py
[composition]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/animation/composition.py
[transform]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/animation/transform.py
[rate-fns]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/utils/rate_functions.py
[cairo-r]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/renderer/cairo_renderer.py
[camera]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/camera/camera.py
[scene]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/scene/scene.py
[writer]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/scene/scene_file_writer.py
[hashing]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/utils/hashing.py
[tex-write]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/utils/tex_file_writing.py
[typst-write]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/utils/typst_file_writing.py
[tex-mob]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/text/tex_mobject.py
[text-mob]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/text/text_mobject.py
[svg-mob]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/svg/svg_mobject.py
[boolean]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/geometry/boolean_ops.py
[space-ops]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/utils/space_ops.py
[vmob-render]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/renderer/vectorized_mobject_rendering.py
[config]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/_config/utils.py
[config-init]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/_config/__init__.py
[constants]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/constants.py
[default-cfg]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/_config/default.cfg
[main]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/__main__.py
[cli]: https://github.com/ManimCommunity/manim/tree/4d25c031/manim/cli
[file-ops]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/utils/file_ops.py
[ipy]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/utils/ipython_magic.py
[section]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/scene/section.py
[pyav]: https://pyav.org/docs/stable/
