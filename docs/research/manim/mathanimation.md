# MathAnimation (C++)

A from-scratch, single-binary, native OpenGL Manim-like engine with a Dear ImGui
timeline editor and real-time GUI+audio preview — the closest existing analog to
what a native D animation engine would be, and therefore the most
decision-relevant reference in this survey.

| Field           | Value                                                                                                                                                       |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language        | C++17 (`set(CMAKE_CXX_STANDARD 17)`), C11 for vendored C ([`CMakeLists.txt`][cmake-root])                                                                   |
| License         | **Custom restrictive EULA** ([`EULA.txt`][eula], adapted from Aseprite's) — repo has **no OSI license** (`gh api … license` → `null`)                       |
| Repository      | [`github.com/ambrosiogabe/MathAnimation`][repo] (created 2021-07-24; 1016★, 51 forks; author `GamesWithGabe`)                                               |
| Documentation   | None beyond [`README.md`][readme]; the author's YouTube channel is the only tutorial surface                                                                |
| Category        | Native offline math-animation renderer + real-time [GUI-timeline][execution-models] editor; [retained][retained-vs-immediate] scene                         |
| Renderer        | **Custom OpenGL** (glad + GLFW) — hybrid: CPU [`plutovg`][pluto] path fills → GPU texture atlas; GL miter-tessellated strokes for write-on                  |
| Editor          | **Dear ImGui** ([`imgui`][imgui]) docked panels: `Timeline`, `Scene`, `Inspector`, `Animations`, `Export Video`, gizmos, wireframe/filled                   |
| Video output    | **Linked [`SVT-AV1`][svtav1]** encoder → AV1 in an **IVF** container (`DKIF`/`AV01`); default filename `.mov`; **not** ffmpeg, **not** mp4                  |
| Typesetting     | **FreeType** glyph-outline extraction; **LaTeX** by shelling out to MiKTeX `latex` + `dvisvgm` → SVG (same pipeline as Manim's [`latex→svg`][latex-to-svg]) |
| Platform        | Windows-first (README lists only Windows); Linux paths exist in-tree (`PlatformLinux.cpp`, `find_package(OpenSSL)`) but are secondary                       |
| Latest activity | `master` HEAD `4b2bace5`, 2024-02-03 ("add syntax highlighting"); repo last pushed 2024-09-08; **no tags, no releases**                                     |

> [!NOTE]
> **Every claim on this page is source-verified against
> [`ambrosiogabe/MathAnimation@4b2bace5`][repo]** (the current `master` HEAD),
> read file-by-file — not from the README's feature list, which is partly
> aspirational (it advertises "mp4" export and animations marked
> `NOT IMPLEMENTED`/`BROKEN`/`STATUS UNKNOWN`). Where the running code and the
> README disagree, the code wins and the discrepancy is flagged.

---

## Overview

### What it solves

MathAnimation is a bespoke tool one developer (`GamesWithGabe`) built to make the
explanatory-math animations in his YouTube videos — a native, self-contained
desktop application that produces Manim-style vector animations but adds the one
thing Manim's batch renderer lacks: a **real-time, scrub-able GUI with audio
preview**. You build a scene of animation objects (text, LaTeX, SVG imports,
shapes, code blocks), drag animations onto a multi-track [timeline][execution-models],
scrub/play the result live, and export a video file. It is a single C++
executable — no Python, no interpreter, no external render server — which is
exactly the shape a native D engine would take.

### Design philosophy

The README states the goal directly ([`README.md`][readme]):

> _"My goal is to have nearly identical animations to those produced by
> [Manim](https://www.manim.community), except in realtime with a GUI+audio
> preview to enhance the editing process."_

That single sentence sets the whole design: **match Manim's output, invert
Manim's workflow.** Manim is code-first and batch-rendered; MathAnimation is
GUI-first and interactively previewed, with the same underlying primitives —
[`VMobject`][vmobject]-style piecewise-Bézier SVG paths, `Create`/`Transform`/
`FadeIn`-style animations, LaTeX via `dvisvgm`. The trade the author accepts for
real-time preview is a **GPU rasteriser** (not bit-reproducible) plus a CPU
[`plutovg`][pluto] fill cache — a pragmatic hybrid rather than Manim-community's
deterministic Cairo oracle. The licensing philosophy is equally deliberate: the
source is open to read and compile, but redistribution is forbidden
([`README.md`][readme]):

> _"This library is free for you to compile and modify for your own personal
> use, but it is not free for you to distribute any binary copies (paid or
> free)."_

---

## How it works

### Language, build & dependencies

MathAnimation is **C++17**, built with **CMake** (`cmake_minimum_required(VERSION
3.21)`, README says 3.16+) into one executable target, `MathAnimations`
([`Animations/CMakeLists.txt`][cmake-anim]). There is no package manager: **every
dependency is a git submodule** vendored under `Animations/vendor/` and compiled
from source into the binary ([`.gitmodules`][gitmodules]). The full third-party set:

| Submodule                 | Role                                                                  |
| ------------------------- | --------------------------------------------------------------------- |
| [`GLFW`][repo], `glad`    | Window/context creation and OpenGL function loading                   |
| [`dearimgui`][imgui]      | The entire editor UI (docking branch, custom `InternalImGuiConfig.h`) |
| [`freetype`][freetype]    | Font loading and [glyph-outline extraction][glyph-outline]            |
| [`plutovg`][pluto]        | CPU 2D vector [rasteriser][rasterization] — fills SVG paths to pixels |
| [`tinyxml2`][repo]        | XML parsing for `.svg` file import                                    |
| `onigurama` (oniguruma)   | Regex engine backing TextMate-grammar syntax highlighting             |
| [`luau`][luau]            | Roblox's typed Lua — the scripting/extensibility layer                |
| `nlohmann/json`           | Project-file (`.json`) serialization                                  |
| [`av1`][svtav1] (SVT-AV1) | The video encoder                                                     |
| `openal` (OpenAL-soft)    | Audio playback for the timeline's waveform preview                    |
| `nativeFileDialog`        | Native open/save dialogs                                              |
| `glm`, `cppUtils`, `stb`  | Math, the author's own utilities, image load/save                     |
| `optick`                  | Optional profiler (only in the `RelWithProfiler` config)              |
| `themes/*`, `grammars/*`  | VSCode `.tmLanguage`/theme JSON copied in as assets at build time     |

The only non-vendored system dependency is OpenSSL on Linux
(`find_package(OpenSSL REQUIRED)` → `OpenSSL::Crypto`, for MD5 hashing)
([`Animations/CMakeLists.txt`][cmake-anim]). The build is warnings-as-errors
(`/W4 /WX` on MSVC, `-Wall -Wextra -Wpedantic -Werror` elsewhere). This
**"vendor everything, compile once"** model is precisely the single-binary
discipline a D engine would inherit — dub would pull each of these as a git
dependency or ImportC shim rather than a submodule.

### The animation/timeline model

The runtime is a **[retained scene][mobject]** of `AnimObject`s keyed by ID
(`AnimObjId`), plus a list of `Animation`s that reference objects by ID and are
laid out on a multi-track timeline. An `Animation` is a plain struct
([`Animation.h`][animation-h]):

```cpp
struct Animation {
    AnimTypeV1 type;
    int32 frameStart;          // timeline position, in integer FRAMES
    int32 duration;            // length, in integer FRAMES
    int32 timelineTrack;
    EaseType easeType;         // Linear/Sine/Quad/…/Elastic/Bounce
    EaseDirection easeDirection;
    PlaybackType playbackType; // Synchronous | LaggedStart
    float lagRatio;
    std::unordered_set<AnimObjId> animObjectIds;
    union { /* per-type payload */ } as;
    void applyAnimation(AnimationManagerData* am, float t = 1.0f) const;
};
```

Time is measured in **integer frames**, not seconds — the timeline is a grid of
frames and `applyAnimation(am, t)` drives object state from an interpolation
`t ∈ [0,1]`. The animation catalog (`AnimTypeV1`) is a direct Manim echo:
`MoveTo`, `Create`, `UnCreate`, `FadeIn`, `FadeOut`, `Transform` (labelled
"Replacement Transform"), `Circumscribe`, `AnimateScale`, plus stubs
(`RotateTo`, `AnimateStrokeColor/FillColor/StrokeWidth`, `Shift`) the README
marks `NOT IMPLEMENTED`/`BROKEN`. Object types (`AnimObjectTypeV1`) are
`TextObject`, `LaTexObject`, `Square`, `Circle`, `Cube`, `Axis`, `SvgObject`,
`SvgFileObject`, `Camera`, `ScriptObject`, `CodeBlock`, `Arrow`, `Image`. The
whole scene serializes to a versioned `nlohmann::json` project file (current
version 3), each object carrying a `serialize`/`deserialize` pair plus a
`[[deprecated]] legacy_deserialize` for upgrading beta projects.

### The renderer

The renderer is a **custom OpenGL** module with a NanoVG-style immediate path API
layered over retained draw-list batching ([`Renderer.h`][renderer-h]): a
push/pop style stack (`pushColor`, `pushStrokeWidth`, `pushLineEnding`,
`pushCamera2D/3D`, `pushFont`) feeds `beginPath`/`lineTo`/`quadTo`/`cubicTo`/
`endPath`/`renderOutline` calls that build geometry into 2D/3D/line/font draw
lists, flushed to a `Framebuffer` (FBO). Everything renders in 3D space even for
2D scenes — a design choice the source annotates with characteristic candour
([`SvgCache.cpp`][svgcache]):

> _"// Everything is 3D now... Good or bad? Who knows?"_

The load-bearing subtlety is that **fill and stroke take different paths** (detailed
under [Rendering backend](#rendering-backend--rasterization)): fills are
rasterised on the **CPU** by [`plutovg`][pluto] into a GPU-resident texture atlas,
while the animated write-on **outline** is tessellated to GL triangles.

---

## Object & scene model

MathAnimation is squarely a [retained-mode][retained-vs-immediate] engine, and its
object model maps cleanly onto the survey's [Mobject][mobject] vocabulary — with
concrete C++ names. An `AnimObject` is the retained node
([`Animation.h`][animation-h]); parent/child structure is expressed through
`AnimObjId` links and a `_isInternalObjectOnly` flag that hides generated
children (e.g. the per-object `SvgObject` a `TextObject` expands into). The
[vector-geometry][vmobject] workhorse is `SvgObject` ([`Svg.h`][svg-h]): an array
of `Path`s, each an array of `Curve`s, each a tagged union over
`Line`/`Bezier2`/`Bezier3`:

```cpp
enum class CurveType : uint8 { None, Line, Bezier2, Bezier3 };
struct Curve { CurveType type; Vec2 p0; union { Line; Bezier2; Bezier3; } as; };
struct Path  { Curve* curves; int numCurves; bool isHole; };
struct SvgObject { Path* paths; int numPaths; Vec4 fillColor; FillType fillType; uint8* md5; /*…*/ };
```

Two facts matter for a D port. First, MathAnimation stores **both quadratic
(`Bezier2`) and cubic (`Bezier3`)** curves natively in one path, rather than
normalising to a single [Bézier basis][bezier-basis] the way the Manim forks do —
so its curve type is a per-segment tagged union, and its `plutovg`/FreeType/SVG
importers each emit whichever degree the source provides (the
[`bezier-eval.d`][ex-bezier] probe evaluates both bases directly). Second, holes are an
explicit `isHole` boolean on `Path` and fill obeys a `FillType`
(`NonZeroFillType`/`EvenOddFillType`), so overlap is resolved by the
[winding rule][fill-triangulation], not by boolean path pre-processing. Each
`SvgObject` carries an `md5` of its binary path data — the key its render cache
is [content-hashed][content-hash] on. Affine placement is a per-object
`globalTransform` (`glm::mat4`), the [affine-transform][affine] model the
[`affine-transform.d`][ex-affine] probe verifies.

---

## Animation & timing model

On the [execution-model][execution-models] axis MathAnimation is the
**GUI-timeline/keyframe** pole: there is no `self.play` script and no reactive
graph — you drag clips onto tracks and the engine samples the scene at a frame.
Each `Animation` owns a `[frameStart, frameStart+duration]` window on a
`timelineTrack`, an `easeType`+`easeDirection`, a `playbackType`
(`Synchronous` or `LaggedStart`), and a `lagRatio` ([`Animation.h`][animation-h]).
`applyAnimation(am, t)` maps global time to a per-animation `t ∈ [0,1]`, applies
the [easing][rate-function] via `CMath::ease(t, type, direction)`, then
[interpolates][interpolation] object state.

The **easing** catalog (`EaseType` in [`CMath.h`][cmath]) is the Penner family —
`Linear`, `Sine`, `Quad`, `Cubic`, `Quart`, `Quint`, `Exponential`, `Back`,
`Elastic`, `Bounce` — each combinable with an `EaseDirection` (In/Out/InOut),
the same easing space the [`rate-functions.d`][ex-rate] probe tabulates (though
MathAnimation uses the Penner curves, not Manim's `smootherstep` default).
**Composition** is expressed through `PlaybackType`: `Synchronous` runs an
animation's target objects together, `LaggedStart` staggers them by `lagRatio` —
the [`lag_ratio`][animation-composition] mechanism, realised as a per-animation
enum + float rather than Manim's `AnimationGroup`/`LaggedStart` combinator tree.
`_isAnimationGroupData`/`_appliesToChildrenData` tables mark which animation types
(`Create`, `UnCreate`, `FadeIn`, `FadeOut`) recurse into a target's children.

The **`Transform`** ("Replacement Transform") morphs one `SvgObject` into another
by interpolating control points, and `Svg::interpolate(src, dst, t)` is where the
hard [point-count alignment][transform-align] problem lives
([`Svg.cpp`][svg-cpp]): the code splits and pads paths (`Curve::split(t0, t1)` —
[de Casteljau][de-casteljau] subdivision — and `Svg::beginPath` on modified
copies) so the source and destination have matching
curve counts before a point-wise lerp — the single subtlest part of the engine,
exactly as the concepts page warns.

---

## Rendering backend & rasterization

This axis is MathAnimation's most instructive finding, because it does **not**
pick a single side of the [CPU-vector vs GPU-vector][cpu-vs-gpu] split — it runs
a **hybrid** keyed on whether a shape is being _filled_ or _drawn on_.

**Fills go through [`plutovg`][pluto] on the CPU.** `SvgObject::render` creates a
`plutovg_surface_t`, and `fillWithPluto` replays the object's curves as plutovg
path commands — `plutovg_move_to`, `plutovg_cubic_to`, `plutovg_quad_to`,
`plutovg_line_to` — sets the [fill rule][fill-triangulation]
(`plutovg_fill_rule_even_odd` / `plutovg_fill_rule_non_zero`) from `FillType`,
and calls `plutovg_fill_preserve` ([`Svg.cpp`][svg-cpp]). plutovg is an
**analytic CPU rasteriser**, so this is coverage-based [anti-aliasing][aa], not
MSAA. The resulting pixels are then **uploaded to an OpenGL texture** via
`texture.uploadSubImage`. The shape is rasterised white and tinted at draw time:

> _"// Draw the SVG with full alpha since we apply alpha changes at the
> compositing level / Render the SVG in white then color it when blitting the
> texture to a quad"_ ([`Svg.cpp`][svg-cpp])

**Strokes/outlines go through the GL renderer.** The `Create` write-on effect
(`renderOutline2D`) does _not_ use plutovg — it emits the outline into the custom
GL path API (`Renderer::beginPath`/`lineTo`/`quadTo`/`cubicTo`) up to a partial
arc length `t * approximatePerimeter`, so the stroke grows as the animation plays
([`Svg.cpp`][svg-cpp]). Those paths are tessellated to triangles on the CPU by a
**miter-join generator** (`generateMiter3D`, which computes a miter normal from
the previous/current/next points and expands the polyline by `strokeWidth`) and
drawn as GL triangles ([`Renderer.cpp`][renderer-cpp]).

The fill results are held in an **SVG texture-atlas cache**
([`SvgCache.cpp`][svgcache]): a 4096×4096 FBO with **four color attachments**,
into which each rasterised SVG is packed shelf-style (`cacheCurrentPos`,
`cacheLineHeight`) and drawn back as a `drawTexturedQuad3D`. When the atlas fills,
an **LRU cache** (`cachedSvgs`) evicts the oldest entries that fit — or scissors
and re-rasterises in place, or "grows" onto the next color attachment. This is a
glyph-atlas pattern applied to whole vector objects. There is also a
**jump-flood** shader pass (`jumpFloodShader`, `renderStencilOutlineToFramebuffer`)
used for the editor's selection-glow outline. On the [color/gamma][color-gamma]
axis, compositing/tinting happens at the quad-blit stage (fills stored as white
RGBA), and the export path converts to YUV in a shader (below).

> [!NOTE]
> **A D engine gets a real decision here.** MathAnimation demonstrates that a
> credible native engine can _avoid writing a fill rasteriser at all_ —
> vendoring a small CPU vector library ([`plutovg`][pluto] is a single-purpose
> ~few-KLOC library) for fills, uploading to a GPU atlas, and reserving custom GL
> only for the animated stroke. That is a far smaller surface than a
> stencil-and-cover or analytic-SDF GPU fill, at the cost of a CPU→GPU upload per
> uncached shape.

---

## Typesetting & text

Text and math are two separate in-process pipelines, both ending in
[`SvgObject`][vmobject] paths.

**Fonts / [glyph outlines][glyph-outline].** `TextObject`s are rendered by
pulling **vector outlines** from **FreeType**, not by blitting a bitmap atlas for
the scene. `Fonts.cpp` includes `<freetype/ftoutln.h>`, loads each glyph with
`FT_Load_Glyph(…, FT_LOAD_NO_SCALE)`, takes the `FT_OutlineGlyph`, and walks its
contours into a `GlyphOutline`, classifying each point as on-curve vs off-curve
(quadratic vs "third-order Bézier") via `FT_getPointType`
([`Fonts.cpp`][fonts-cpp]). Kerning comes from `FT_Get_Kerning`. (A parallel
`SizedFont`/`GlyphTexture` path exists for rasterised UI text, but scene text is
outline-based.) There is **no HarfBuzz/Pango [shaping][text-shaping]** — glyphs
are advanced by their `advanceX` plus pairwise kerning, so complex-script
shaping (Arabic, Indic, bidi) is out of scope, unlike Manim's `manimpango`.

**LaTeX → SVG.** MathAnimation reproduces Manim's classic pipeline exactly, by
**shelling out to a system LaTeX install** ([`LaTexLayer.cpp`][latex]). It looks
for **MiKTeX** on `PATH` (`miktex/bin/x64/latex.exe`, `…/dvisvgm.exe` on Windows;
`miktex` / `miktex-dvisvgm` elsewhere), wraps the user's markup in a
`\documentclass[preview]{standalone}` preamble loading `amsmath`, `amssymb`,
`physics`, etc. (MathTex additionally wraps it in `\begin{align*}…\end{align*}`),
writes a `.tex` file, and runs two subprocesses:

```cpp
// latex/<md5>.tex  →  latex.exe -halt-on-error  →  <md5>.dvi
Platform::executeProgram(latexProgram, (latexFilename + " -halt-on-error").c_str(), "./latex/", …);
// <md5>.dvi        →  dvisvgm -n                →  <md5>.svg
Platform::executeProgram(dvisvgmProgram, (dviFilename + " -n").c_str(), "./latex/", …);
```

The output `.svg` is [content-hash cached][content-hash] on the **MD5 of the
LaTeX string** (`Platform::md5FromString`), so identical equations are compiled
once and reused across runs — the same disk cache Manim keeps, and the reason
LaTeX objects need the `miktex`+`dvisvgm` toolchain present. Generation runs on a
background thread, serialised one-at-a-time so the app doesn't fork a process
storm.

**SVG parsing.** Imported `.svg` files are parsed with **tinyxml2**
(`parseSvgDoc` requires a `<svg>` element with a `viewBox`, walks
`<defs>`/`<g>`/`<style>`, parses `<path>` and `<polygon>`, applies a small CSS
`Stylesheet`) plus a hand-written `d`-attribute parser (`parseSvgPath`) covering
M/L/H/V/C/Q/S/T/A and their relative forms ([`SvgParser.cpp`][svgparser-cpp]).

---

## Output & encoding

The output path is a purpose-built **[readback][frame-capture] → YUV → AV1**
pipeline, and it is _not_ what the README ("Export the final animation as an mp4
file") advertises. The real mechanics ([`ExportPanel.cpp`][export],
[`Encoder.cpp`][encoder]):

1. **Fixed-timestep render.** Export sets the play state to
   `PlayForwardFixedFrameTime` at a hard-coded **60 fps**
   (`getExportSecondsPerFrame() = 1/60`), resets to frame 0, and steps
   frame-by-frame — the [deterministic frame sampling][deterministic] discipline.
2. **GPU RGB→YUV pass.** `renderTextureToYuvFramebuffer` converts the main
   framebuffer to planar **YUV 4:2:0** across two FBOs — a full-resolution Y
   target and a half-resolution UV target ([`Renderer.h`][renderer-h] declares
   the `RgbToYuvShader`).
3. **Async [readback][frame-capture].** A `PixelBufferDownload` (OpenGL PBO)
   queues an asynchronous download of the Y/UV framebuffers, then hands the
   packed planar buffer to `encoder->pushYuvFrame(...)` — the readback-to-buffer
   step the [`frame-capture.d`][ex-capture] probe stands in for.
4. **[Encode][codec-muxing].** `VideoEncoder::startEncodingFile` drives
   **SVT-AV1** directly through its C API (`svt_av1_enc_init_handle`,
   `svt_av1_enc_send_picture`, `svt_av1_enc_get_packet`), configured `crf 28`,
   `preset 12`, `color-format 420`, `input-depth 8`. Frames are staged in a
   memory-mapped file, encoded on a worker thread, and muxed into an **IVF**
   container written by hand — the header literally begins `DKIF … AV01`:

```cpp
unsigned char header[32] = { 'D','K','I','F', 0,0,32,0, 'A','V','0','1' };  // IVF, not MP4
```

Two honest caveats. **The container is IVF/AV1, but the export dialog defaults
the filename to `.mov`** (`filepath.replace_extension(".mov")`,
`NFD_SaveDialog("mov", …)`) — so a file with a `.mov` (or README-promised
`.mp4`) name actually holds an IVF AV1 stream. And the alternative hardware path
is **unimplemented**: `NvidiaEncoder.cpp` is a **0-byte empty file**, and the
export loop carries the TODO:

> _"// TODO: Add a hardware accelerated version that usee CUDA and NVENC"_
> ([`ExportPanel.cpp`][export])

During export, [`plutovg`][pluto] fills are forced **synchronous**
(`if (ExportPanel::isExportingVideo()) svg->render(...)` vs `renderAsync`
otherwise) at **Ultra** SVG fidelity, so no frame ships a half-rasterised cache
entry ([`SvgCache.cpp`][svgcache]).

---

## Interactivity, preview & authoring

This is the axis MathAnimation exists for and where it most differs from Manim.
The entire editor is **Dear ImGui** — a docking layout of panels
([`README.md`][readme] enumerates them; source under
`Animations/src/editor/panels/` and `…/timeline/`):

- **`Timeline`** — multi-track, zoomable; drag/drop animation clips, resize by
  dragging clip edges, magnet-toggle snapping, a draggable playhead on a frame
  ruler, and per-track **audio waveform preview** (OpenAL) for syncing to a
  voiceover.
- **`Animation Editor View`** — the scrubbing viewport with **gizmos** to drag
  objects, scroll-to-zoom, middle-click-pan; **`Animation View`** is the clean
  final-render preview (space bar toggles play/stop).
- **`Scene`** hierarchy (color-coded active/animating/inactive), **`Inspector`**
  (per-object and per-animation properties), **`Animations`** palette,
  **`Asset Manager`** (scripts), **`Console`** (script logs/errors, click-to-open),
  **`Export Video`**, **`App Metrics`** (FPS), **`Editor Settings`**
  (wireframe/filled, camera sensitivity).

There is an **`UndoSystem`** and clipboard, a `CodeEditorPanel` with TextMate-
grammar syntax highlighting (oniguruma regex + VSCode `.tmLanguage`/theme JSON),
and a project/scene splash screen. In other words, MathAnimation is a small IDE,
not a library — the polar opposite of Manim's "write Python, run, watch the file"
loop, and the strongest evidence in this survey that a native, [ImGui][imgui]-based
timeline editor over a retained scene is a tractable single-developer build.

---

## Extensibility & API surface

Extensibility is a **[Luau][luau] scripting** layer, not a plugin ABI or a
scene-description DSL. A `ScriptObject` runs a user script (authored in the
`Asset Manager`, stored as a project asset) that **procedurally generates**
objects through a C API registered on the Lua state. `LuauLayer` compiles scripts
to bytecode with `luau_compile` and loads them with `luau_load`, gated by a
`ScriptAnalyzer` that **statically type-checks** the source first
(`analyzer->analyze(...)` before compile) — leaning on Luau's gradual type system
([`LuauLayer.cpp`][luau-cpp]). The exposed surface (`extern "C"` functions in
[`GlobalApi.h`][globalapi]) is deliberately small and SVG-centric:

```cpp
int global_createAnimObjectFn(lua_State* L);      // spawn an AnimObject
int global_setAnimObjPosVec3(lua_State* L);        // …position/color/name
int global_svgBeginPath(lua_State* L);             // build an SvgObject procedurally
int global_svgMoveTo(lua_State* L);   int global_svgLineTo(lua_State* L);
int global_svgQuadTo(lua_State* L);   int global_svgCubicTo(lua_State* L);
int global_svgArcTo(lua_State* L);    /* + *Rel relative-command variants */
int global_require(lua_State* L);     int global_loadMathAnimLib(lua_State* L);
```

So a script's power is exactly "construct SVG paths and animation objects from
code" — a scripting _escape hatch_ bolted onto a GUI-first tool, rather than the
code-first primary interface Manim exposes. There is **no C plugin API, no
network/IPC surface, and no stable versioned SDK**; the "API" is these Lua
globals plus the JSON project schema. For a D reimplementation the lesson is that
a typed embeddable scripting VM (Luau here; a D-native or WASM equivalent there)
can cover procedural generation without committing to a plugin ABI.

---

## Determinism, caching & performance

MathAnimation caches aggressively and samples deterministically for export, but —
being GPU-backed — is **not bit-reproducible**, so it makes no oracle guarantee.

**[Content-hash caching][content-hash] at two levels.** LaTeX is cached on disk by
the **MD5 of the equation string** (`latex/<md5>.svg`), compiled once ever
([`LaTexLayer.cpp`][latex]). SVG fills are cached in the GPU atlas keyed by a
composite hash of **`md5(path) + svgScale + percentReplacementTransformed`**,
rounded to fixed precision so tiny float wobble doesn't thrash the cache
([`SvgCache.cpp`][svgcache]):

```cpp
uint64 hash(const uint8* svgMd5, size_t len, float svgScale, float replacementTransform) {
    int roundedSvgScale = (int)(svgScale * 1000.0f);        // 3 decimal places
    int roundedTransform = (int)(replacementTransform * 100.0f);
    /* combineHash(md5) ⊕ combineHash(scale) ⊕ combineHash(transform) */
}
```

That the `Transform` progress is _in the key_ is notable: a morphing object
re-rasterises each distinct frame but re-uses the atlas entry whenever the same
intermediate recurs. The **project's binary SVG format** is itself a
determinism/compactness decision — paths serialise to absolute-only
`MoveTo/LineTo/CurveTo/QuadTo` commands with coordinates normalised to
`(int)(val * 1e6)` int32s, base64-encoded into the JSON ([`SvgParser.h`][svgparser]):

> _"Any numbers that follow a command are the coordinate pairs … The normalized
> value is calculated by doing: (int)(val \* 1e6) to truncate the value at 6
> decimal places as an integer."_

**[Deterministic frame sampling][deterministic]** holds only for export
(`PlayForwardFixedFrameTime` at 60 fps, synchronous rasterisation, Ultra
fidelity). But the pixels come from an OpenGL rasteriser plus a CPU `plutovg`
fill, so output is **not guaranteed bit-identical across GPUs/drivers** the way
Manim-community's Cairo path is — MathAnimation is a real-time-preview engine that
happens to also write a file, not a regression-tested [CPU oracle][cpu-vs-gpu].
Performance levers on show: async PBO readback, a worker-thread encoder over a
memory-mapped frame cache, the four-attachment LRU atlas, and an optional Optick
profiler build.

---

## Strengths

- **Genuinely single-binary and native.** One C++17 executable, every dependency
  vendored as a submodule and compiled in — no runtime, no interpreter, no
  external render server. The exact shape a D engine would target.
- **Real-time GUI + audio preview.** A dockable [ImGui][imgui] timeline with
  scrubbing, gizmos, snapping, and waveform sync — the workflow Manim lacks.
- **Pragmatic hybrid renderer.** Vendors a CPU vector library ([`plutovg`][pluto])
  for fills → GPU atlas, and writes custom GL only for the animated stroke —
  a small, buildable rendering surface for one developer.
- **Faithful Manim primitives.** Piecewise-Bézier `SvgObject`s, `Create`/
  `Transform`/`FadeIn` animations, LaTeX via `dvisvgm`, FreeType glyph outlines —
  the same conceptual model, natively.
- **Two-level content-hash caching** (LaTeX-by-MD5, SVG-atlas-by-hash) and a
  compact binary project format.
- **Embeddable typed scripting** ([Luau][luau]) with static analysis for
  procedural object generation.

## Weaknesses

- **Restrictive custom EULA, no OSI license** — the code is readable and
  compilable for personal use but **binary redistribution is forbidden**
  ([`EULA.txt`][eula]); a D engine cannot copy code from it, only ideas.
- **Windows-first, effectively unmaintained.** `master` HEAD is 2024-02-03, no
  tags/releases ever, a single primary author; Linux support is partial.
- **README oversells the state.** "mp4" export is really AV1/IVF named `.mov`;
  several animations are `NOT IMPLEMENTED`/`BROKEN`; the NVENC encoder is a
  0-byte stub.
- **Not reproducible.** GPU + CPU-fill output is not bit-identical across
  drivers; no [oracle][cpu-vs-gpu] guarantee, no perceptual-diff test harness.
- **Heavy LaTeX dependency.** Math objects need a full **MiKTeX** + `dvisvgm`
  install on `PATH`, shelled out as subprocesses (same friction as Manim).
- **No complex-script [shaping][text-shaping]** (no HarfBuzz), no plugin ABI, and
  the docking-ImGui codebase carries a lot of editor surface area for one person.

---

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                             | Trade-off                                                                                |
| ----------------------------------------------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Single C++ binary, all deps vendored as git submodules            | Self-contained native app; no runtime/interpreter; reproducible build | ~24 submodules compiled from source; heavy first build; Windows-first toolchain          |
| Hybrid renderer: [`plutovg`][pluto] CPU fills → GPU atlas         | Avoids writing a GPU fill rasteriser; analytic-coverage AA for free   | CPU→GPU upload per uncached shape; not bit-reproducible; two code paths (fill/stroke)    |
| GL miter-tessellated strokes with partial-perimeter draw          | Enables the animated `Create` write-on effect natively                | CPU tessellation; join quality is miter-only; separate from the fill path                |
| [GUI timeline][execution-models] over a [retained][mobject] scene | Real-time scrub/preview + audio sync — the whole point vs Manim       | A whole IDE to build/maintain (panels, undo, gizmos, asset mgr) for one developer        |
| Time in **integer frames**; export at fixed 60 fps                | Simple deterministic sampling; clean timeline grid                    | Frame rate effectively hard-coded; sub-frame timing not expressible                      |
| LaTeX by shelling out to MiKTeX `latex` + `dvisvgm`               | Reuses the real TeX stack; identical output to Manim; MD5 disk cache  | Requires a full LaTeX install on `PATH`; subprocess latency; Windows path assumptions    |
| FreeType glyph **outlines** (not a bitmap atlas) for scene text   | Resolution-independent, animatable, `SvgObject`-uniform with shapes   | No HarfBuzz [shaping][text-shaping]; complex scripts unsupported                         |
| Linked **SVT-AV1** → hand-muxed **IVF**                           | In-process encode, no ffmpeg dependency, modern codec                 | Output is IVF/AV1 mislabelled `.mov`/`.mp4`; no broad container/codec choice; NVENC stub |
| Custom **EULA**, source-available but no redistribution           | Author keeps control of a personal tool                               | Not open-source; code is reference-only for other projects                               |
| [Luau][luau] scripting escape hatch with static analysis          | Procedural generation without a plugin ABI; typed, embeddable         | Small fixed API surface; scripting is secondary to the GUI, not a primary interface      |

---

## Sources

- [`README.md`][readme] — positioning ("_nearly identical animations to those
  produced by Manim, except in realtime with a GUI+audio preview_"), licensing
  ("_not free for you to distribute any binary copies_"), the full feature list
  (panels, animation types with `NOT IMPLEMENTED`/`BROKEN` markers).
- [`EULA.txt`][eula] — the custom (Aseprite-derived) license: "_You may not
  distribute copies of the SOFTWARE PRODUCT to third parties_", source may be
  compiled/modified "_for your own personal purpose or to propose a contribution_".
- [`CMakeLists.txt`][cmake-root] · [`Animations/CMakeLists.txt`][cmake-anim] ·
  [`.gitmodules`][gitmodules] — C++17/CMake build, single `MathAnimations` target,
  the vendored-submodule dependency graph and `target_link_libraries` list.
- [`Animation.h`][animation-h] — `AnimObject`/`Animation` structs, `AnimTypeV1`/
  `AnimObjectTypeV1`/`PlaybackType` enums, frame-based timing, `applyAnimation`.
- [`CMath.h`][cmath] — `EaseType`/`EaseDirection` (Penner easing) + `ease(...)`.
- [`Svg.h`][svg-h] · [`Svg.cpp`][svg-cpp] — `SvgObject`/`Path`/`Curve` geometry,
  `fillWithPluto` (CPU fill, fill rules, "_Render the SVG in white then color it_"),
  `renderOutline2D` (GL write-on stroke), `Svg::interpolate` (Transform alignment).
- [`SvgCache.cpp`][svgcache] — 4096×4096 four-attachment atlas, LRU eviction,
  content-hash key, sync-vs-async rasterisation, "_Everything is 3D now…_".
- [`SvgParser.h`][svgparser] · [`SvgParser.cpp`][svgparser-cpp] — tinyxml2 `.svg`
  import; the base64 binary path format (`(int)(val * 1e6)` normalisation).
- [`Renderer.h`][renderer-h] · [`Renderer.cpp`][renderer-cpp] — the custom GL
  path API, push/pop style stacks, draw-list batching, `generateMiter3D`,
  `RgbToYuvShader`, jump-flood outline.
- [`Fonts.cpp`][fonts-cpp] — FreeType outline extraction (`FT_LOAD_NO_SCALE`,
  `FT_OutlineGlyph`, on/off-curve point classification, kerning).
- [`LaTexLayer.cpp`][latex] — MiKTeX `latex` + `dvisvgm` subprocess pipeline,
  standalone preamble, MathTex `align*` wrap, MD5-keyed SVG disk cache.
- [`ExportPanel.cpp`][export] · [`Encoder.cpp`][encoder] — fixed-60 fps
  `PlayForwardFixedFrameTime` stepping, GPU RGB→YUV pass, PBO readback, SVT-AV1 C
  API, hand-written IVF (`DKIF`/`AV01`) muxer, `.mov` default, NVENC TODO;
  [`NvidiaEncoder.cpp`][nvenc] is a 0-byte stub.
- [`GlobalApi.h`][globalapi] · [`LuauLayer.cpp`][luau-cpp] — the Luau scripting
  surface (`global_svg*`/`global_createAnimObjectFn`), `luau_compile`/`luau_load`,
  `ScriptAnalyzer` static type-checking.
- External libraries: [`plutovg`][pluto], [`SVT-AV1`][svtav1], [`Luau`][luau],
  [`Dear ImGui`][imgui], [`FreeType`][freetype], [Manim][manim].

<!-- References -->

<!-- concepts.md anchors -->

[mobject]: ./concepts.md#mobject-and-the-scene-graph
[vmobject]: ./concepts.md#vmobject-and-vector-geometry
[bezier-basis]: ./concepts.md#bezier-basis-quadratic-vs-cubic
[de-casteljau]: ./concepts.md#de-casteljau-evaluation
[fill-triangulation]: ./concepts.md#fill-triangulation-and-winding
[affine]: ./concepts.md#affine-transform-and-coordinate-space
[interpolation]: ./concepts.md#interpolation-and-lerp
[rate-function]: ./concepts.md#rate-function-and-easing
[animation-composition]: ./concepts.md#animation-composition
[transform-align]: ./concepts.md#transform-and-point-count-alignment
[execution-models]: ./concepts.md#execution-models
[retained-vs-immediate]: ./concepts.md#retained-vs-immediate-mode
[rasterization]: ./concepts.md#rasterization
[cpu-vs-gpu]: ./concepts.md#cpu-vector-vs-gpu-vector-rendering
[aa]: ./concepts.md#anti-aliasing
[color-gamma]: ./concepts.md#color-model-and-gamma
[glyph-outline]: ./concepts.md#glyph-outline-extraction
[latex-to-svg]: ./concepts.md#latex-to-svg
[text-shaping]: ./concepts.md#text-shaping
[frame-capture]: ./concepts.md#frame-capture-and-readback
[codec-muxing]: ./concepts.md#codec-muxing-and-pixel-format
[deterministic]: ./concepts.md#deterministic-frame-sampling
[content-hash]: ./concepts.md#content-hash-caching

<!-- Runnable probes (checked via the ignoreDeadLinks /\.d$/ rule) -->

[ex-bezier]: ./examples/bezier-eval.d
[ex-rate]: ./examples/rate-functions.d
[ex-affine]: ./examples/affine-transform.d
[ex-capture]: ./examples/frame-capture.d

<!-- External primary sources (pinned to master HEAD 4b2bace5) -->

[repo]: https://github.com/ambrosiogabe/MathAnimation
[readme]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/README.md
[eula]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/EULA.txt
[cmake-root]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/CMakeLists.txt
[cmake-anim]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/CMakeLists.txt
[gitmodules]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/.gitmodules
[animation-h]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/include/animation/Animation.h
[cmath]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/include/math/CMath.h
[svg-h]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/include/svg/Svg.h
[svg-cpp]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/src/svg/Svg.cpp
[svgcache]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/src/svg/SvgCache.cpp
[svgparser]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/include/svg/SvgParser.h
[svgparser-cpp]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/src/svg/SvgParser.cpp
[renderer-h]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/include/renderer/Renderer.h
[renderer-cpp]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/src/renderer/Renderer.cpp
[fonts-cpp]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/src/renderer/Fonts.cpp
[latex]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/src/latex/LaTexLayer.cpp
[export]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/src/editor/panels/ExportPanel.cpp
[encoder]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/src/video/Encoder.cpp
[nvenc]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/src/video/NvidiaEncoder.cpp
[globalapi]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/include/scripting/GlobalApi.h
[luau-cpp]: https://github.com/ambrosiogabe/MathAnimation/blob/4b2bace5e5d43ecccfd9cd5374d3eb9760ace4ef/Animations/src/scripting/LuauLayer.cpp
[pluto]: https://github.com/sammycage/plutovg
[svtav1]: https://gitlab.com/AOMediaCodec/SVT-AV1
[luau]: https://github.com/Roblox/luau
[imgui]: https://github.com/ocornut/imgui
[freetype]: https://gitlab.freedesktop.org/freetype/freetype
[manim]: https://www.manim.community
