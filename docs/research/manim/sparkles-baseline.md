# The Sparkles Baseline

Where the `sparkles` monorepo stands today as a starting point for a
mathematical-animation engine. Unlike the other synthesis pages, this one audits
**this** repository, not the surveyed field: there is **no animation engine in
`sparkles` yet**, so the baseline is a greenfield inventory of the primitives a
Manim-class engine would build on and an honest list of the gaps. It is the
"you are here" that the [delta table](./comparison.md#the-delta-table) and the
[milestoned proposal](./animation-engine-proposal.md) build from.

**Last reviewed:** July 11, 2026

> [!NOTE]
> Everything below is present in the repo **today**. Nothing here draws frames or
> plays animations; the value is that the hard, cross-cutting infrastructure a
> native+web engine needs — a C-library binding recipe, a wired GPU surface with
> frame capture, a wasm compute path, `@nogc` numeric primitives, and the
> Design-by-Introspection idiom — already exists and is exercised by shipping
> code.

## What exists today (the reuse surface)

### Math primitives — `libs/math`

`libs/math` is embryonic: a single generic value type
`Vector(T, size_t N, string[] fieldNames)` in `libs/math/src/sparkles/math/vector.d`.
It has union storage with named fields (`x`/`y`/`z`/`w`), component-wise
arithmetic, scalar multiply/divide (both sides), `dot`, swizzling via
`opDispatch` (`v.xzy`, `v.xy = …`), `toString`, and the aliases `Vec2f`/`Vec3f`/
`Vec4f` and `ScreenSize`. Crucially, the `Vector` + `fieldNames` mechanism
expresses an RGBA colour directly as `Vector!(float, 4, ["r","g","b","a"])` — so
the [colour model](./concepts.md#color-model-and-gamma) falls out of the existing
type, and only gamma conversion is new code. The manifest already puts the
`test-runner-impl` attribute module on the import path so primitives can be
tagged `@ctfe`/`@betterC`/`@wasm`, signalling the intent to keep this layer
wasm-clean.

**Everything else in the math layer must be built:** no `Matrix`/`Mat3`/`Mat4`,
no [affine transform](./concepts.md#affine-transform-and-coordinate-space), no
quaternion, no [Bézier](./concepts.md#bezier-basis-quadratic-vs-cubic) evaluate/
subdivide/align, no [easing/lerp](./concepts.md#rate-function-and-easing), no
gamma-correct colour. The catalog's probes
([`bezier-eval.d`](./examples/bezier-eval.d),
[`affine-transform.d`](./examples/affine-transform.d),
[`rate-functions.d`](./examples/rate-functions.d)) already prototype exactly this
missing math in self-contained form.

### A native GPU surface — raylib, via `apps/terminal`

`apps/terminal` binds and exercises **raylib** (`raylib-d ~>6.0.1`, `libs
"raylib"`, `pkgs.raylib` in the dev shell): window/draw lifecycle
(`BeginDrawing`/`EndDrawing`), GPU textures (`LoadTextureFromImage`,
`DrawTexturePro`, `SetTextureFilter`), `BeginScissorMode`, and — decisively —
`TakeScreenshot` for [frame capture](./concepts.md#frame-capture-and-readback).
That is a working, already-integrated GPU backend + readback template; the
[`gpu-vector`](./rendering-backends/gpu-vector.md) survey notes raylib is
immediate-mode (you tessellate vector fills yourself) rather than a true vector
rasteriser, but it is a proven capture surface.

### The C-library binding recipe — ImportC + pkg-config + Nix

`libs/ghostty` is the template for pulling in a C library: a `c.c` shim
(`#pragma attribute(push, nogc, nothrow)` + `#include <…>`), a manifest whose
`configuration "library"` is `targetType "sourceLibrary"` (mandatory — a plain
`library` clears `libs` and skips pkg-config, so ImportC cannot find the header),
`libs "<linkname>"`, and a dev-shell `pkgs.<lib>` + `.dev`. This is the proven
path to every C dependency the survey's backends need —
[Cairo](./rendering-backends/cpu-vector.md) (the deterministic oracle),
[Blend2D](./rendering-backends/cpu-vector.md),
[libav](./video-encoding.md), [HarfBuzz + FreeType](./math-typesetting.md). Two
gotchas from the guideline are load-bearing here: a **unique `c.c` stem per
library** (else `module 'c' conflicts` when Cairo + libav + HarfBuzz co-link),
and function-like macros / `static inline` are not importable (redeclare as D
`enum`). The [`rendering-backends/sample/`](./rendering-backends/) fixture shows
the recipe applied to Cairo.

### A wasm compute path — `buildDWasmModule`

`nix/packages/build-d-wasm-module.nix` compiles a single entry D module with the
LDC WASI fork (`wasm32-wasip1`, `-i=sparkles`), exports `extern(C) export`
functions, and shrinks with `wasm-opt`; existing consumers back docs widgets, and
the GC works after `__wasm_call_ctors`. The constraint is sharp and shapes the
web story: **single module, no linked C libraries, and WASI has no GPU or
canvas.** So wasm fits the _scene-graph / geometry / easing computation_ exported
to JS, with drawing done by Canvas2D/WebGL on the JS side — not a pixel renderer,
and not a home for native text shaping.

### The test runner and `@nogc` primitives

`sparkles:test-runner` (the `@("name") unittest {}` convention with explicit
`@safe pure nothrow @nogc` attributes), `SmallBuffer` (an `@nogc` output-range
container), the `sparkles.base.text` `@nogc` formatters, and `Expected!(T, E)`
error handling are all available and are what a hot per-frame interpolation loop
would use to stay allocation-free.

### D idioms that shape the design

The repo's **Design-by-Introspection** idiom — a required-surface trait plus an
optional-capability vocabulary that generic code `static if`s over, exemplified by
`libs/versions/src/sparkles/versions/traits.d` — is the exact mechanism the
proposal reuses for its [renderer abstraction](./animation-engine-proposal.md).
UFCS range pipelines, named-argument struct init, expression-based contracts, and
the `-preview=in -preview=dip1000` flags are the ambient style.

## The gaps — what must be built

| Engine subsystem                                         | In `sparkles` today               | Nearest reuse                                  |
| -------------------------------------------------------- | --------------------------------- | ---------------------------------------------- |
| Matrix / affine / quaternion                             | ✗ none                            | extend `libs/math` `Vector`                    |
| Bézier eval / subdivide / align                          | ✗ none                            | probes prototype it; new `libs/math` module    |
| Easing / lerp / gamma colour                             | ✗ none                            | `Color = Vector!(float,4,…)` + a gamma module  |
| Scene graph (`Mobject`/`VMobject`)                       | ✗ none                            | new; GC tree + SoA payload                     |
| Animation & timing (`Transform`, groups, `ValueTracker`) | ✗ none                            | new; `libs/math` easing feeds it               |
| Renderer abstraction                                     | ✗ none                            | DbI idiom (`versions/traits.d`)                |
| CPU-vector backend (Cairo/Blend2D)                       | ✗ none                            | ImportC recipe (`libs/ghostty`)                |
| GPU backend + capture                                    | ◐ raylib wired in `apps/terminal` | reuse the `apps/terminal` surface              |
| Video encoder                                            | ✗ none                            | ffmpeg subprocess, then libav via ImportC      |
| Math typesetting                                         | ✗ none                            | LaTeX→dvisvgm (Nix-pinned) + HarfBuzz/FreeType |
| Web/wasm preview                                         | ◐ `buildDWasmModule` path exists  | export scene/geometry to JS + Canvas2D         |

## Where each survey capability stands

The field-wide capability picture and the per-capability mapping onto this
baseline live in the [comparison delta table](./comparison.md#the-delta-table);
the sequenced plan to close the gaps — which milestone delivers each subsystem,
what it reuses, and its risk — is the
[animation-engine proposal](./animation-engine-proposal.md). The short version:
the _infrastructure_ (C bindings, GPU capture, wasm, `@nogc` numerics, DbI) is in
place; the _engine_ (math, scene graph, timing, backends, typesetting, encoding)
is greenfield.

## Sources

Primary sources are files in this repository (paths in backticks above):
`libs/math/src/sparkles/math/vector.d`, `apps/terminal/dub.sdl`,
`apps/terminal/src/app.d`, `libs/ghostty/{dub.sdl,src/sparkles/ghostty/c.c}`,
`docs/guidelines/importc-c-libraries.md`,
`nix/packages/build-d-wasm-module.nix`,
`libs/versions/src/sparkles/versions/traits.d`, and this catalog's
[`examples/`](./examples/bezier-eval.d) probes.

<!-- References -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md
[proposal]: ./animation-engine-proposal.md
[rendering-backends]: ./rendering-backends/
[gpu-vector]: ./rendering-backends/gpu-vector.md
[cpu-vector]: ./rendering-backends/cpu-vector.md
[math-typesetting]: ./math-typesetting.md
[video-encoding]: ./video-encoding.md
