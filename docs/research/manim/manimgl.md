# ManimGL (Python)

3Blue1Brown's original engine: an OpenGL-only, GPU-first animation library whose
defining bet is a real-time preview window and a live IPython `embed()`, in
deliberate contrast to Manim Community's Cairo-by-default renderer.

| Field               | Value                                                                                                 |
| ------------------- | ----------------------------------------------------------------------------------------------------- |
| Language            | Python (3.7+; `setup.cfg` classifies 3.7–3.10)                                                        |
| License             | MIT (`setup.cfg` `license = MIT`)                                                                     |
| Repository          | [`3b1b/manim`][repo] (pinned `e61ad5c3` for every citation below)                                     |
| Documentation       | [`3b1b.github.io/manim`][docs]                                                                        |
| Category            | GPU-first programmatic animation engine for explanatory math video                                    |
| Import name / CLI   | `import manimlib` → console scripts `manimgl` / `manim-render` (`setup.cfg` `[options.entry_points]`) |
| Version             | `1.7.2` (`setup.cfg`); `manimlib.__version__` reads `importlib.metadata.version("manimgl")`           |
| Default renderer    | OpenGL only, via `moderngl` (`create_standalone_context()` headless, or the live `window.ctx`)        |
| Bézier basis        | **Quadratic** (3-point `anchor, handle, anchor` triples)                                              |
| Video encoder       | `ffmpeg` subprocess fed raw `rgba` frames over a stdin pipe                                           |
| Text / TeX          | `latex`/`xelatex` + `dvisvgm` → SVG (`svgelements`); non-TeX via `manimpango` + `pygments`            |
| No pycairo, no PyAV | Confirmed absent from `setup.cfg` / `requirements.txt` — the sharpest contrast with Community         |

> [!NOTE]
> This page is grounded entirely in a local clone at commit
> [`e61ad5c3`][repo] (`manimgl 1.7.2`). Every `file:line` locator and quotation
> refers to that tree. Where a prior survey pass carried a fact that no longer
> matches the source (notably the fill path), the discrepancy is called out
> inline and in the closing ledger. This is the GPU-first counterpart to the
> [Manim Community hub][mc]; the shared vocabulary lives in [`concepts.md`][concepts].

---

## Overview

### What it solves

ManimGL is the animation engine 3Blue1Brown uses to render its videos. The
problem statement is narrow and unchanged since the project began: turn Python
that describes mathematical objects and their transformations into a frame
sequence, precisely and reproducibly, with a tight authoring feedback loop. The
architectural consequence that separates it from every other manim variant is
that **OpenGL is not one renderer among several — it is the only one**. A
`Mobject` is not an abstract shape that a backend later rasterizes; it _is_ a GPU
vertex buffer. `Mobject.data` is a NumPy [structured array][concepts-vmob] whose
dtype names (`point`, `rgba`, …) are literally the vertex-shader `in` attributes
([`mobject.py:70-76`][mobject]):

```python
# manimlib/mobject/mobject.py:70
render_primitive: int = moderngl.TRIANGLE_STRIP
# Must match in attributes of vert shader
data_dtype: np.dtype = np.dtype([
    ('point', np.float32, (3,)),
    ('rgba', np.float32, (4,)),
])
```

Everything downstream — animation, the preview window, video output — is built on
the premise that shipping vertices to the GPU each frame is cheap enough to do in
real time, which is what makes the live `embed()` REPL viable.

### Design philosophy

The project is explicit that it is a personal tool first and a general library
second. The `README.md` frames the fork history that produced today's two manims
([`README.md:14`][readme], verbatim):

> _"Note, there are two versions of manim. This repository began as a personal
> project by the author of [3Blue1Brown](https://www.3blue1brown.com/) for the
> purpose of animating those videos... In 2020 a group of developers forked it
> into what is now the [community edition](https://github.com/ManimCommunity/manim/),
> with a goal of being more stable, better tested, quicker to respond to community
> contributions, and all around friendlier to get started with."_

That "personal project" stance shows up as pragmatism in the code: methods are
kept alive purely so old scenes do not break (`ThreeDCamera` exists "Mostly just
defined so old scenes don't break", [`camera.py:258`][camera]; `Animation.update`
"shouldn't exist, but it's here to keep many old scenes from breaking",
[`animation.py:141-146`][animation]), and rendering tricks are described in the
first person (see the winding-fill quote under
[Rendering](#rendering-backend-rasterization)). The design center is _iteration
speed for one author_, not API stability for a community — the mirror image of the
Community project's stated goals above.

---

## How it works

A run is a short pipeline from CLI to GPU ([`__main__.py`][main] →
[`config.py`][config] → [`extract_scene.py`][extract] → `Scene.run`):

1. **CLI + config merge.** `manimlib/__main__.py:main` calls
   `config.parse_cli()` (an `argparse` parser, [`config.py:54`][config]) then
   `run_scenes()`. `initialize_manim_config()` deep-merges three YAML layers into
   an `addict.Dict` — `default_config.yml`, a CWD `custom_config.yml`, and an
   optional `--config_file` — via `merge_dicts_recursively`, then overlays CLI
   flags ([`config.py:23-51`][config]).
2. **Scene discovery.** `extract_scene.main` imports the user's module and finds
   `Scene` subclasses with `inspect.getmembers(module, is_child_scene)`
   ([`extract_scene.py:112-125`][extract]); with no match it prompts. `-e <line>`
   rewrites the module to inject `self.embed()` at that line
   ([`extract_scene.py:146-158`][extract]).
3. **The scene loop.** `Scene.run` ([`scene.py:149`][scene]) does
   `file_writer.begin()` → `setup()` → `construct()` (the user's code,
   [`scene.py:174`][scene]) → `interact()` → `tear_down()`.
4. **Playing an animation.** `Scene.play` ([`scene.py:577`][scene]) runs
   `pre_play` → `begin_animations` → `progress_through_animations` →
   `finish_animations` → `post_play`. The inner loop steps a deterministic
   time-grid, interpolating and emitting one frame per tick
   ([`scene.py:555-565`][scene]):

```python
# manimlib/scene/scene.py:555
def progress_through_animations(self, animations):
    last_t = 0
    for t in self.get_animation_time_progression(animations):
        dt = t - last_t
        last_t = t
        for animation in animations:
            animation.update_mobjects(dt)
            alpha = t / animation.run_time
            animation.interpolate(alpha)
        self.update_frame(dt)   # → camera.capture → GPU draw
        self.emit_frame()       # → file_writer.write_frame → ffmpeg stdin
```

5. **Draw + capture.** `update_frame` calls `camera.capture(*render_groups)`,
   which clears the FBO and calls `mobject.render(ctx, uniforms)` for each top
   group ([`camera.py:225-230`][camera]); `render` rebuilds `ShaderWrapper`s only
   when the mobject's dirty flag is set ([`mobject.py:2081-2088`][mobject]).
6. **Encode.** `emit_frame` → `file_writer.write_frame` reads the framebuffer back
   and writes raw `rgba` bytes to the `ffmpeg` subprocess's stdin
   ([`scene_file_writer.py:284-289`][sfw]).

The rest of this page walks the [eight-axis spine][concepts] shared with the other
engine deep-dives; the pushed [execution model][concepts-exec] (Python `construct`
imperatively driving a frame loop) is the same as Community's, so the interesting
deltas are all in the layers below it.

---

## Object & scene model

The base class is `class Mobject(object)` ([`mobject.py:64`][mobject]), a plain
object (no ABC), with `dim: int = 3` — points are always 3D even for 2D scenes.
See [Mobject and the scene graph][concepts-mob] for the shared model.

**One structured array, not parallel arrays.** `init_data` allocates a _single_
NumPy structured array `self.data` plus a `self.uniforms` dict
([`mobject.py:137-149`][mobject]). For the base `Mobject` the record is
`(point:f4[3], rgba:f4[4])`; every subclass widens the dtype rather than adding
side arrays. This is the deepest structural contrast with [Manim Community's scene
graph][mc-sg], which keeps `points` and per-attribute color arrays as separate
NumPy arrays. Here color travels _inside_ the same interleaved vertex record that
gets uploaded to the GPU.

**Doubly-linked tree with a memoized family.** Children live in
`self.submobjects`; each child also records its parents in `self.parents`
([`mobject.py:99-101`][mobject]). `add` appends to both lists
([`mobject.py:459-468`][mobject]). `get_family` flattens self + descendants and
memoizes the result in `self.family` ([`mobject.py:426-433`][mobject]).

**Dirty-flag propagation.** Two invalidation signals bubble _up_ the parent
chain. `note_changed_data` sets `self._data_has_changed = True` and recurses into
`self.parents` ([`mobject.py:208-213`][mobject]); `note_changed_family` nulls the
`self.family` cache and recurses up ([`mobject.py:417-424`][mobject]). Mutating
methods are wrapped by the `@affects_data` / `@affects_family_data` decorators,
which call the notifier after the wrapped call ([`mobject.py:215-232`][mobject]).
`render` consults the resulting `_data_has_changed` flag to decide whether to
rebuild shader wrappers ([`mobject.py:2081-2088`][mobject]) — a retained-mode
cache keyed on mutation, evaluated in an [immediate-mode][concepts-retained] draw.

**Fluent animation & always-on updaters.** `Mobject.animate` returns an
`_AnimationBuilder` ([`mobject.py:165-174`][mobject]) that records method calls
against a generated `target` and builds a `_MethodAnimation` (a `MoveToTarget`
`Transform`) at `play` time ([`mobject.py:2250-2328`][mobject]). `Mobject.always`
and `Mobject.f_always` return updater-builders that register a per-frame updater
running the named method every frame ([`mobject.py:176-206`][mobject],
[`mobject_update_utils.py:26-52`][muu]). `.animate` is explicitly credited in a
comment as "Borrowed from https://github.com/ManimCommunity/manim/"
([`mobject.py:172`][mobject]) — cross-pollination flows both ways.

`Group`/`Point` are the generic containers ([`mobject.py:2196-2247`][mobject]);
the vector subclass `VMobject` and its `VGroup` are below.

---

## Animation & timing model

`class Animation(object)` ([`animation.py:23`][animation]) is again a plain
object. Its lifecycle is `begin` → repeated `interpolate(alpha)` → `finish`
([`animation.py:63-83`][animation]). `begin` snapshots the mobject with
`create_starting_mobject` (a `.copy()`), zips the start/target families, and calls
`interpolate(0)`. The parameters match the shared
[rate-function][concepts-rate] and [lag][concepts-lag] vocabulary: `mobject`,
`run_time=1.0`, `rate_func=smooth`, `lag_ratio=0`, and an optional
`time_span=(start, end)` ([`animation.py:24-54`][animation]).

**Interpolation is per-family-member.** `interpolate_mobject` walks the zipped
families and, for each, computes a `sub_alpha` and calls `interpolate_submobject`
([`animation.py:154-166`][animation]). The staggering math lives in
`get_sub_alpha` ([`animation.py:168-182`][animation]):

```python
# manimlib/animation/animation.py:168
def get_sub_alpha(self, alpha, index, num_submobjects):
    lag_ratio = self.lag_ratio
    full_length = (num_submobjects - 1) * lag_ratio + 1
    value = alpha * full_length
    lower = index * lag_ratio
    raw_sub_alpha = clip((value - lower), 0, 1)
    return self.rate_func(raw_sub_alpha)
```

`lag_ratio=0` starts every submobject together; `1` runs them strictly in sequence;
fractions overlap — the [lag-ratio][concepts-lag] semantics exactly.

**`Transform` aligns point counts.** The workhorse `Transform`
([`transform.py:24`][transform]) copies the target, calls
`self.mobject.align_data_and_family(self.target_copy)` so both have matching
structure, then locks the data keys that do not change to skip them
([`transform.py:54-72`][transform]). Interpolation defers to
`submob.interpolate(start, target_copy, alpha, self.path_func)`
([`transform.py:121-129`][transform]); `Mobject.interpolate`
([`mobject.py:1810-1838`][mobject]) [lerps][concepts-lerp] each non-locked dtype
field — `pointlike_data_keys` through the `path_func` (default `straight_path`),
everything else with a plain `(1-alpha)*a + alpha*b`, including the `uniforms` and
bounding box. See [transform and point-count alignment][concepts-transform]; the
`about_point`-relative `apply_points_function`
([`mobject.py:281-308`][mobject]) is the [affine-transform][concepts-affine]
primitive underneath `shift`/`scale`/`rotate`.

**Composition.** `AnimationGroup` ([`composition.py:27`][composition]) precomputes
`(anim, start, end)` triples in `build_animations_with_timings` using
`interpolate(start, end, lag_ratio)` to offset each successor
([`composition.py:90-106`][composition]), then in its own `interpolate` maps the
group alpha onto each child's clipped sub-alpha ([`composition.py:108-121`][composition]).
`Succession` is `AnimationGroup` with `lag_ratio=1.0` and single-active-animation
stepping ([`composition.py:124-153`][composition]); `LaggedStart` defaults
`lag_ratio=0.05` ([`composition.py:156-163`][composition]). See
[animation composition][concepts-comp].

**Rate functions.** `manimlib/utils/rate_functions.py` defines the easing library;
the default `smooth` is a quintic with zero first/second derivatives at both ends,
noted as "Equivalent to `bezier([0, 0, 0, 1, 1, 1])`" ([`rate_functions.py:17-21`][rate]).
Others include `rush_into`, `rush_from`, `there_and_back`, `running_start`,
`overshoot`, and the `squish_rate_func` combinator ([`rate_functions.py`][rate]).
The runnable probe [`examples/rate-functions.d`][ex-rate] reimplements `smooth`
and friends to pin these formulas.

---

## Rendering backend & rasterization

This axis is where ManimGL and Manim Community fundamentally diverge:
[CPU-vector vs GPU-vector rendering][concepts-cpugpu]. Community [rasterizes][concepts-raster] vector
paths on the CPU with Cairo by default; ManimGL has **no CPU rasterizer at all**.

**Camera == GL context owner.** `class Camera(object)` ([`camera.py:25`][camera])
creates the moderngl context: `moderngl.create_standalone_context()` when there is
no window (offline render), or `self.window.ctx` when previewing
([`camera.py:72-76`][camera]). It builds two framebuffers — `fbo_for_files` at
`self.samples` MSAA samples and a `samples=0` `draw_fbo` used for readback
([`camera.py:81-122`][camera]). `capture` clears, refreshes uniforms (view matrix,
`frame_scale`, `pixel_size`, light position), and calls `mobject.render(ctx, uniforms)`
for each group ([`camera.py:225-255`][camera]).

**MSAA is off for 2D, on for 3D.** The default `samples: int = 0`
([`camera.py:46`][camera]) — vector mobjects "handle antialiasing fine without
multisampling" per the inline comment ([`camera.py:43-46`][camera]) because stroke
and fill shaders compute an analytic `anti_alias_width` coverage. `ThreeDCamera`
bumps `samples=4` ([`camera.py:259-261`][camera]). See
[anti-aliasing][concepts-aa].

**The `CameraFrame` is itself a `Mobject`.** `class CameraFrame(Mobject)`
([`camera_frame.py:23`][cframe]) stores camera orientation as a quaternion in
`uniforms["orientation"]` and its `fovy` as a uniform
([`camera_frame.py:35-49`][cframe]) — so panning/zooming the camera is literally
animating a mobject, and 3D uses the same interpolation machinery as everything else.

**`ShaderWrapper` owns the GL program/VBO/VAO.** `class ShaderWrapper(object)`
([`shader_wrapper.py:34`][sw]) holds the compiled program, vertex buffer and vertex
array. `Mobject.get_shader_wrapper_list` batches family members sharing a shader
id, calls `get_shader_data` per member (indexing `self.data` by
`get_shader_vert_indices`), and hands the concatenated vertex data to the wrapper's
`read_in` ([`mobject.py:2056-2079`][mobject]). GLSL lives under
`manimlib/shaders/` — `quadratic_bezier/{stroke,fill,depth}`, `surface/`,
`true_dot/`, `image/`, the fractal shaders. `Mobject` subclasses select geometry:
`Surface` uses `render_primitive = moderngl.TRIANGLES`, `shader_folder = "surface"`
([`surface.py:35-36`][surface]); `DotCloud` uses `moderngl.POINTS` +
`true_dot` ([`dot_cloud.py:27-28`][dotcloud]).

**Fill is a GPU winding-number computation** — and here is the largest correction
to the earlier survey pass. `use_winding_fill()` is now a no-op kept only for
backward source-compat ([`vectorized_mobject.py:466-468`][vmob], verbatim):

> _"Only keeping this here because some old scene call it"_

There is no live `winding` vs. `triangulation` toggle. VMobjects always render fill
through the [winding-number][concepts-fill] method: `VShaderWrapper.render_fill`
([`shader_wrapper.py:384-431`][sw]) draws fill triangles into a separate
floating-point texture with a blend function chosen so positively- and
negatively-oriented triangles cancel, then composites that texture onto the frame.
The rationale is documented on `get_fill_canvas` ([`shader_wrapper.py:437-441`][sw],
verbatim):

> _"Because VMobjects with fill are rendered in a funny way, using alpha blending
> to effectively compute the winding number around each pixel, they need to be
> rendered to a separate texture, which is then composited onto the ordinary frame
> buffer."_

The fill fragment shader gives negatively-oriented triangles alpha
`-a / (1 - a)` and discards the outside of each quadratic via the implicit
`Fxy = (y - x*x); if (Fxy < 0) discard;` test (Loop-Blinn-style)
([`quadratic_bezier/fill/frag.glsl`][fillfrag]). Vertices for fill come from
`get_shader_vert_indices → get_outer_vert_indices`, the per-curve fan pattern
`(0,1,2,2,3,4,…)` ([`vectorized_mobject.py:1098-1106,1334-1335`][vmob]) — _not_ from
a triangulation.

> [!WARNING]
> **`get_triangulation` → `earclip_triangulation` is now vestigial.** The CPU
> ear-clipping fill (`get_triangulation`, [`vectorized_mobject.py:1110-1157`][vmob],
> which calls `earclip_triangulation` → `mapbox_earcut.triangulate_float32`,
> [`space_ops.py:8,423,506`][spaceops]) still exists in the module, but nothing in
> the render path calls it: `get_shader_vert_indices` returns the outer-vertex fan,
> and the only reference to a `refresh_triangulation` method
> ([`indication.py:404`][indication]) targets a method that is no longer defined.
> A prior pass framed fill as "GPU winding OR CPU `get_triangulation`"; in this tree
> it is GPU winding only, with the earclip path a dormant remnant.

---

## Typesetting & text

Two independent pipelines, both ending in an `SVGMobject`.

**TeX → SVG (disk-cached subprocess chain).** `Tex(StringMobject)`
([`tex_mobject.py:35`][texmob]) and `TexText(Tex)` ([`tex_mobject.py:276`][texmob])
build LaTeX source and call `latex_to_svg` ([`tex_file_writing.py:51`][texfw],
`@lru_cache(maxsize=128)`). That wraps `full_tex_to_svg`
([`tex_file_writing.py:85`][texfw], `@cache_on_disk`), which runs the compiler as a
subprocess — `latex` producing `.dvi`, or `xelatex -no-pdf` producing `.xdv`
([`tex_file_writing.py:89-119`][texfw]) — then pipes the result through `dvisvgm`
with `-n --stdout` and decodes the SVG from stdout
([`tex_file_writing.py:132-150`][texfw]). See [LaTeX to SVG][concepts-latex].

**Non-TeX text (Pango + Pygments).** `text_mobject.py` imports `manimpango` and
`pygments` ([`text_mobject.py:10-13`][textmob]); `MarkupText(StringMobject)`
renders Pango markup to SVG via `manimpango.MarkupUtils.text2svg`
([`text_mobject.py:79,115`][textmob]). `Text(MarkupText)`
([`text_mobject.py:400`][textmob]) is the plain-text front door; `Code(MarkupText)`
syntax-highlights source with `pygments.formatters.PangoMarkupFormatter`
([`text_mobject.py:438-456`][textmob]) — [text shaping][concepts-shape] delegated to
Pango, not hand-rolled.

**SVG → VMobject.** `SVGMobject(VMobject)` ([`svg_mobject.py:53`][svgmob]) parses
with `svgelements as se` ([`svg_mobject.py:6`][svgmob]) and turns each `se.Path`
into a `VMobjectFromSVGPath` ([`svg_mobject.py:261-283,336`][svgmob]) whose bezier
segments become quadratic anchor/handle triples — [glyph-outline
extraction][concepts-glyph] into the same quadratic vertex model as every other
VMobject.

---

## Output & encoding

`SceneFileWriter` ([`scene_file_writer.py:28`][sfw]) drives the encoder. Its
constructor defaults are `ffmpeg_bin = "ffmpeg"`, `video_codec = "libx264"`,
`pixel_format = "yuv420p"`, extension `.mp4` ([`scene_file_writer.py:44-50`][sfw]).

**ffmpeg is a subprocess fed a raw pipe** — the concrete contrast with Community's
in-process PyAV. `open_movie_pipe` assembles an `ffmpeg` argv reading raw
`rawvideo` `rgba` from stdin and launches it with `sp.Popen(..., stdin=sp.PIPE)`
([`scene_file_writer.py:202-230`][sfw]):

```python
# manimlib/scene/scene_file_writer.py:213
command = [
    self.ffmpeg_bin, '-y',
    '-f', 'rawvideo',
    '-s', f'{width}x{height}',
    '-pix_fmt', 'rgba',
    '-r', str(fps),
    '-i', '-',                # input from the pipe
    '-vf', vf_arg,            # 'vflip' + saturation/gamma eq
    '-an', '-loglevel', 'error',
]
# ... + ['-vcodec', self.video_codec] + ['-pix_fmt', self.pixel_format]
self.writing_process = sp.Popen(command, stdin=sp.PIPE)
```

Each frame, `write_frame` calls `camera.get_raw_fbo_data()` and writes the bytes to
`self.writing_process.stdin` ([`scene_file_writer.py:284-289`][sfw]);
`close_movie_pipe` closes stdin and `wait()`s
([`scene_file_writer.py:291-299`][sfw]). `use_fast_encoding()` swaps in the lossless
RGB path — `video_codec = "libx264rgb"`, `pixel_format = "rgb32"`
([`scene_file_writer.py:241-243`][sfw]). See [codec, muxing and pixel
format][concepts-codec]. The `-vf` filter also folds in a
`eq=saturation={s}:gamma={g}` pass ([`scene_file_writer.py:210-211`][sfw]), the one
[color/gamma][concepts-color] adjustment applied at encode time rather than in-shader.

**Readback.** `camera.get_raw_fbo_data` blits the (possibly multisampled) render
FBO into the `samples=0` `draw_fbo` then `read()`s it back to CPU bytes
([`camera.py:129-147`][camera]) — the [frame-capture-and-readback][concepts-capture]
step, exercised by the [`examples/frame-capture.d`][ex-capture] probe. Note the
vertical flip is deferred to ffmpeg's `-vf vflip`, and `get_pixel_array`
re-flips + rescales for still-image paths ([`camera.py:157-163`][camera]).

---

## Interactivity, preview & authoring

This is ManimGL's signature axis and its clearest philosophical departure: a live
window and REPL are _first-class_, not an opt-in mode. When
`run.show_in_window` is set, `run_scenes` constructs one reusable `Window` and
passes it into every scene ([`__main__.py:29-39`][main]).

**The window.** `class Window(PygletWindow)` ([`window.py:23`][window]) subclasses
moderngl_window's pyglet window (`gl_version = (3, 3)`, `vsync = True`,
[`window.py:5-6,26-27`][window]). `Scene.interact` ([`scene.py:186-201`][scene])
loops `update_frame(1/fps)` until the window closes; `update_frame` sleeps to keep
real time in sync when a window is open ([`scene.py:236-256`][scene]):

```python
# manimlib/scene/scene.py:253
if self.window and not self.skip_animations:
    vt = self.time - self.virtual_animation_start_time
    rt = time.time() - self.real_animation_start_time
    time.sleep(max(vt - rt, 0))
```

**`embed()` — the live IPython REPL.** `Scene.embed`
([`scene.py:203-219`][scene]) — a no-op without a window — hands control to
`InteractiveSceneEmbed(self).launch()`. That class ([`scene_embed.py:24`][embed])
builds an `IPython` `InteractiveShellEmbed` seeded with the caller's locals plus
shortcuts (`play`, `wait`, `add`, `checkpoint_paste`, `reload`, `undo`/`redo`,
[`scene_embed.py:60-81`][embed]). It registers a Prompt Toolkit input hook named
`"manim"` that keeps rendering while the shell waits for input, so the window stays
live during the REPL ([`scene_embed.py:83-93`][embed]), and forces a redraw after
every cell ([`scene_embed.py:95-101`][embed]).

**`checkpoint_paste` and `reload`.** `checkpoint_paste`
([`scene_embed.py:187-216`][embed]) reads the clipboard with `pyperclip.paste()`,
and if the pasted block starts with a `#` comment it uses that comment as a
checkpoint key — re-running the block reverts scene state to the checkpoint first
([`scene_embed.py:225-238`][embed]), giving idempotent block re-execution.
`reload_scene` ([`scene_embed.py:139-177`][embed]) validates syntax, sets
`run_config.is_reload`, and triggers IPython's `exit_raise` magic; `run_scenes`
catches the resulting `KillEmbedded` and re-runs from a clean slate while keeping
the same window ([`__main__.py:34-44`][main], [`window.py:52-60`][window]).

**Selection editor + event bus.** `class InteractiveScene(Scene)`
([`interactive_scene.py:66`][iscene]) adds a mouse-driven selection/grab/resize
editor (keys `g`, `t`, `s`, `command+c/z`). Events flow through
`manimlib/event_handler/` — an `EVENT_DISPATCHER`, `EventListener`, and
`EventType` — with DOM-style bubbling; `Mobject.add_event_listner` registers
callbacks on the global dispatcher ([`mobject.py:2090-2136`][mobject]).

**Reactive values.** `ValueTracker(Mobject)` ([`value_tracker.py:13`][vt]) is a
non-drawn mobject whose scalar lives in `uniforms["value"]`
([`value_tracker.py:30-45`][vt]) — so it animates and interpolates like any other
mobject. Combined with the updater helpers `always`, `f_always`, `always_redraw`,
`always_shift`, `always_rotate`, and `turn_animation_into_updater`
([`mobject_update_utils.py`][muu]), it is ManimGL's [updater/ValueTracker][concepts-updaters]
reactivity layer.

---

## Extensibility & API surface

**Subclass the dtype, get a renderer.** Extending the object model means widening
`data_dtype` and pointing `shader_folder` at GLSL; the vertex attributes bind by
name. `VMobject` demonstrates the pattern at full width
([`vectorized_mobject.py:58-67`][vmob]) — its record packs _seven_ fields into one
array:

```python
# manimlib/mobject/types/vectorized_mobject.py:59
data_dtype: np.dtype = np.dtype([
    ('point', np.float32, (3,)),
    ('stroke_rgba', np.float32, (4,)),
    ('stroke_width', np.float32, (1,)),
    ('joint_angle', np.float32, (1,)),
    ('fill_rgba', np.float32, (4,)),
    ('base_normal', np.float32, (3,)),   # base points & unit normals interleaved
    ('fill_border_width', np.float32, (1,)),
])
```

Stroke color, stroke width, and fill color are _columns of one structured array_,
never separate objects — contrast Community's separate `stroke`/`fill` color arrays.

**Quadratic bezier API.** VMobject's curve builders speak triples: curves are
enumerated by `get_bezier_tuples` (each `points[2i:2i+3]`,
[`vectorized_mobject.py:767-772`][vmob]) and evaluated by the shared `bezier()`
helper ([de Casteljau][concepts-decast], via `get_nth_curve_function`,
[`vectorized_mobject.py:805-806`][vmob]); `add_quadratic_bezier_curve_to(handle,
anchor)` appends a `[handle, anchor]` pair ([`vectorized_mobject.py:536-545`][vmob]);
`set_points_as_corners` ([`vectorized_mobject.py:675`][vmob]),
`point_from_proportion` ([`vectorized_mobject.py:850`][vmob]), `align_points`
([`vectorized_mobject.py:964`][vmob]), `insert_n_curves`
([`vectorized_mobject.py:1016`][vmob]), and `pointwise_become_partial`
([`vectorized_mobject.py:1050`][vmob]) all operate on the 3-point structure. Even
`add_cubic_bezier_curve_to` immediately reduces a cubic to a quadratic approximation
(`get_quadratic_approximation_of_cubic`, [`vectorized_mobject.py:506-534`][vmob]) —
there is no native cubic path storage, the crux of [quadratic vs
cubic][concepts-basis]. Probe: [`examples/bezier-eval.d`][ex-bezier].

**No public plugin system.** ManimGL has no entry-point plugin registry or renderer
abstraction — the extension surface _is_ Python subclassing plus GLSL. This is an
absence relative to Manim Community's plugin ecosystem, and a direct consequence of
the single-author philosophy.

---

## Determinism, caching & performance

**Deterministic frame sampling.** Frame times are a fixed grid independent of wall
clock: `get_time_progression` returns
`np.arange(0, run_time, 1/fps) + 1/fps` ([`scene.py:467-491`][scene]). Offline
renders therefore produce a byte-reproducible frame count regardless of machine
speed; the real-time `time.sleep` only throttles the _preview_. See
[deterministic frame sampling][concepts-detsample]. The [`examples/affine-transform.d`][ex-affine]
and [`examples/rate-functions.d`][ex-rate] probes reproduce the per-frame alpha math.

**Content-hash disk cache for TeX.** `cache_on_disk`
([`cache.py:20-30`][cache]) keys a `diskcache.Cache` (1 GB limit) on
`hash_string(f"{func.__name__}{args}{kwargs}")`, so identical LaTeX compiles once
across runs — [content-hash caching][concepts-hashcache]. `latex_to_svg` adds an
in-process `lru_cache` on top ([`tex_file_writing.py:50`][texfw]).

**Per-mobject render cache.** As covered under [Object & scene
model](#object-scene-model), `render` rebuilds `ShaderWrapper`s only when
`_data_has_changed` ([`mobject.py:2081-2088`][mobject]); `lock_data` /
`lock_matching_data` freeze unchanging dtype fields during a `Transform` so
interpolation skips them and they are not re-uploaded
([`mobject.py:1852-1868`][mobject], [`transform.py:68-72`][transform]).

**Performance posture.** The whole design optimizes for GPU throughput and
authoring latency: geometry is uploaded as interleaved vertex records, fill/stroke
antialiasing is analytic (no MSAA for 2D), and the dirty-flag cache avoids
re-uploading static mobjects. The cost is a hard dependency on a working OpenGL 3.3
context — there is no software-render fallback, so headless/CI environments must
supply one (e.g. a virtual GL).

> [!NOTE]
> No CI-run `[Output]` example ships _in this page_; the demonstrable claims are
> backed by the shared probes under [`examples/`][ex-bezier] (bezier evaluation,
> quadratic rate functions, affine transforms, frame readback), which the `ci`
> helper compiles and runs. They reimplement the load-bearing math in D so a
> regression in the documented formulas turns CI red.

---

## Strengths

- **One renderer, fully committed.** OpenGL-only means the object model, camera,
  and animation machinery are all designed around GPU vertex buffers — no
  backend-abstraction tax, and 3D is "free" because `CameraFrame` is a mobject.
- **First-class live authoring.** The `embed()` REPL, `checkpoint_paste`, and
  `reload` give a genuinely interactive edit loop that Community's optional OpenGL
  mode does not match.
- **Compact, cache-friendly data layout.** One structured vertex array per mobject
  (point + colors + widths interleaved) maps straight onto GL attributes and the
  dirty-flag upload cache.
- **Analytic vector antialiasing.** Stroke/fill shaders anti-alias without MSAA, so
  2D renders stay cheap.
- **Deterministic offline output** via fixed `1/fps` frame sampling, decoupled from
  the real-time preview clock.

## Weaknesses

- **Hard OpenGL 3.3 dependency, no fallback.** No CPU rasterizer; headless/CI needs
  a real or virtual GL context. Contrast Community's Cairo default.
- **Single-author stability posture.** Compatibility shims ("here to keep many old
  scenes from breaking") accrete; there is no plugin system, no renderer
  abstraction, and thinner test coverage than Community.
- **Vestigial code paths.** `use_winding_fill` is a no-op and `get_triangulation`
  is dead — the source carries archaeology a reader must navigate.
- **Quadratic-only storage.** Cubic curves from SVG/TeX are approximated to
  quadratics on import; no native cubic path retention.
- **External-tool coupling.** TeX and text depend on out-of-process `latex`/
  `xelatex`/`dvisvgm`/Pango and the `ffmpeg` binary — failures surface as subprocess
  errors, not Python exceptions from a library.

---

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                               | Trade-off                                                                                       |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| OpenGL-only renderer (`moderngl`), no Cairo                | Real-time preview + one code path; GPU does the rasterization                           | No software fallback; OpenGL 3.3 required even for offline/CI renders                           |
| One structured `data` array (point + colors interleaved)   | Maps 1:1 onto GL vertex attributes; single upload; cache-friendly                       | Widening behavior means editing a dtype; less obvious than Community's named color arrays       |
| Quadratic (3-point) bezier basis                           | Simplest curve the winding-fill + stroke shaders need; half the control points of cubic | SVG/TeX cubics are approximated on import; some fidelity lost vs native cubic                   |
| GPU winding-number fill into a scratch texture             | Correct even-odd/nonzero fill without CPU triangulation; robust to self-intersection    | Extra offscreen texture + custom blend funcs; the `earclip` CPU path left dead in the tree      |
| Analytic AA in shaders, MSAA off for 2D (on for 3D)        | Vector edges anti-alias cheaply without multisample buffers                             | 3D still needs `samples=4`; two AA regimes to reason about                                      |
| ffmpeg as a stdin-piped subprocess (not in-process PyAV)   | Zero Python encoder dependency; stream raw `rgba` frames straight out                   | Coupling to an external `ffmpeg` binary + pipe lifecycle; errors are subprocess-shaped          |
| TeX via `latex`/`xelatex` + `dvisvgm`, disk-cached         | Reuse the real TeX toolchain; content-hash cache amortizes recompiles                   | Three external binaries on `PATH`; first render is slow                                         |
| `embed()` / `reload` / `checkpoint_paste` as core features | Optimizes the single author's iteration latency                                         | Interactive machinery (IPython, pyperclip, input hooks) is load-bearing, not optional           |
| Dirty-flag retained cache over an immediate-mode draw      | Skip re-uploading unchanged mobjects each frame                                         | Correctness depends on every mutator calling `note_changed_*` (via the `@affects_*` decorators) |

---

## Sources

- Object & scene model — [`manimlib/mobject/mobject.py`][mobject] (`Mobject:64`,
  `data_dtype:70-76`, family/dirty-flags `208-232,417-433`, `interpolate:1810`,
  `render:2081`, `_AnimationBuilder:2250`).
- Vector geometry & fill — [`manimlib/mobject/types/vectorized_mobject.py`][vmob]
  (`VMobject.data_dtype:59`, quadratic API `536-772`, `get_triangulation:1110`,
  `use_winding_fill:466`, `get_shader_vert_indices:1334`);
  [`manimlib/shaders/quadratic_bezier/fill/frag.glsl`][fillfrag];
  [`manimlib/utils/space_ops.py`][spaceops] (`earclip_triangulation:423`,
  `mapbox_earcut:8`).
- Animation & timing — [`animation.py`][animation] (`Animation:23`,
  `get_sub_alpha:168`), [`composition.py`][composition] (`AnimationGroup:27`,
  `build_animations_with_timings:90`), [`transform.py`][transform] (`Transform:24`,
  `align_data_and_family:66`), [`rate_functions.py`][rate] (`smooth:17`).
- Rendering — [`camera.py`][camera] (`Camera:25`, `get_fbo:108`,
  `get_raw_fbo_data:141`, `capture:225`), [`camera_frame.py`][cframe]
  (`CameraFrame:23`), [`shader_wrapper.py`][sw] (`ShaderWrapper:34`,
  `render_fill:384`, `get_fill_canvas:436`), [`surface.py`][surface],
  [`dot_cloud.py`][dotcloud].
- Text/TeX — [`tex_file_writing.py`][texfw] (`latex_to_svg:51`,
  `full_tex_to_svg:85`), [`tex_mobject.py`][texmob] (`Tex:35`),
  [`svg_mobject.py`][svgmob] (`SVGMobject:53`), [`text_mobject.py`][textmob]
  (`MarkupText:115`, `Code:438`).
- Output — [`scene_file_writer.py`][sfw] (`SceneFileWriter:28`,
  `open_movie_pipe:202`, `write_frame:284`, `use_fast_encoding:241`).
- Scene loop & interactivity — [`scene.py`][scene] (`run:149`, `play:577`,
  `progress_through_animations:555`, `update_frame:236`, `get_time_progression:467`),
  [`scene_embed.py`][embed] (`InteractiveSceneEmbed:24`), [`interactive_scene.py`][iscene],
  [`window.py`][window], [`value_tracker.py`][vt], [`mobject_update_utils.py`][muu].
- Config/CLI — [`__main__.py`][main], [`config.py`][config] (`initialize_manim_config:23`,
  `parse_cli:54`), [`extract_scene.py`][extract], [`cache.py`][cache].
- Packaging — `setup.cfg` (`manimgl 1.7.2`, MIT, `install_requires`, entry points),
  `requirements.txt`, [`README.md`][readme].

<!-- References -->

[repo]: https://github.com/3b1b/manim/tree/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea
[docs]: https://3b1b.github.io/manim/
[readme]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/README.md
[mobject]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/mobject/mobject.py
[vmob]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/mobject/types/vectorized_mobject.py
[animation]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/animation/animation.py
[composition]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/animation/composition.py
[transform]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/animation/transform.py
[rate]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/utils/rate_functions.py
[camera]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/camera/camera.py
[cframe]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/camera/camera_frame.py
[sw]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/shader_wrapper.py
[fillfrag]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/shaders/quadratic_bezier/fill/frag.glsl
[spaceops]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/utils/space_ops.py
[surface]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/mobject/types/surface.py
[dotcloud]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/mobject/types/dot_cloud.py
[sfw]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/scene/scene_file_writer.py
[scene]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/scene/scene.py
[embed]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/scene/scene_embed.py
[iscene]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/scene/interactive_scene.py
[window]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/window.py
[vt]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/mobject/value_tracker.py
[muu]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/mobject/mobject_update_utils.py
[texfw]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/utils/tex_file_writing.py
[texmob]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/mobject/svg/tex_mobject.py
[svgmob]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/mobject/svg/svg_mobject.py
[textmob]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/mobject/svg/text_mobject.py
[main]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/__main__.py
[config]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/config.py
[extract]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/extract_scene.py
[cache]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/utils/cache.py
[indication]: https://github.com/3b1b/manim/blob/e61ad5c3f9c9ac96cba7a46dffc665c0ec13beea/manimlib/animation/indication.py
[mc]: ./manim-community/
[mc-sg]: ./manim-community/scene-graph.md
[concepts]: ./concepts.md
[concepts-mob]: ./concepts.md#mobject-and-the-scene-graph
[concepts-vmob]: ./concepts.md#vmobject-and-vector-geometry
[concepts-basis]: ./concepts.md#bezier-basis-quadratic-vs-cubic
[concepts-decast]: ./concepts.md#de-casteljau-evaluation
[concepts-fill]: ./concepts.md#fill-triangulation-and-winding
[concepts-affine]: ./concepts.md#affine-transform-and-coordinate-space
[concepts-lerp]: ./concepts.md#interpolation-and-lerp
[concepts-rate]: ./concepts.md#rate-function-and-easing
[concepts-lag]: ./concepts.md#lag-ratio-and-staggering
[concepts-comp]: ./concepts.md#animation-composition
[concepts-transform]: ./concepts.md#transform-and-point-count-alignment
[concepts-exec]: ./concepts.md#execution-models
[concepts-retained]: ./concepts.md#retained-vs-immediate-mode
[concepts-updaters]: ./concepts.md#updaters-and-valuetracker
[concepts-raster]: ./concepts.md#rasterization
[concepts-cpugpu]: ./concepts.md#cpu-vector-vs-gpu-vector-rendering
[concepts-aa]: ./concepts.md#anti-aliasing
[concepts-color]: ./concepts.md#color-model-and-gamma
[concepts-glyph]: ./concepts.md#glyph-outline-extraction
[concepts-latex]: ./concepts.md#latex-to-svg
[concepts-shape]: ./concepts.md#text-shaping
[concepts-capture]: ./concepts.md#frame-capture-and-readback
[concepts-codec]: ./concepts.md#codec-muxing-and-pixel-format
[concepts-detsample]: ./concepts.md#deterministic-frame-sampling
[concepts-hashcache]: ./concepts.md#content-hash-caching
[ex-bezier]: ./examples/bezier-eval.d
[ex-rate]: ./examples/rate-functions.d
[ex-affine]: ./examples/affine-transform.d
[ex-capture]: ./examples/frame-capture.d
