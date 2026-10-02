# Vello (Rust)

A 2D vector renderer with no font layer of its own: text enters as positioned
glyph ids plus a font blob, becomes cached `skrifa` outlines, and is
rasterized as ordinary paths, either by a GPU compute pipeline or by the
CPU-side "sparse strips" pipeline that has since become the main line.

| Field            | Value                                                                                                                                 |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | Rust (WGSL compute shaders; WESL for the sparse-strips GPU backend)                                                                   |
| License          | Apache-2.0 OR MIT; compute shaders additionally Unlicense ([`README.md`][readme])                                                     |
| Repository       | [`linebender/vello`][repo]                                                                                                            |
| Documentation    | [`README.md`][readme], [`ARCHITECTURE.md`][arch], [`research/doc/pathseg.md`][pathseg], crate docs in [`glifo/src/lib.rs`][glifo-lib] |
| Category         | rasterizer                                                                                                                            |
| Layer(s) covered | outline · raster                                                                                                                      |
| Pinned revision  | `8cc000b685f522ca9edce6124bc8cbb83955aa67` (2026-10-02)                                                                               |

## Overview

### What it solves

A Skia/Cairo-class imaging model (fills, strokes, gradients, images, clips,
blends, text) for GUI toolkits, chiefly the Linebender stack whose layout
engine is [`parley`](./parley.md). The repository now holds three renderers:
`vello_cpu` (SIMD and multithreaded), `vello_gpu` (CPU preprocessing, GPU
raster through vertex/fragment shaders, WebGL2 or wgpu), and the original
compute-shader renderer, published as `vello` but moved under `research/`
([`README.md`][readme]). Glyph-run support for the first two is a separate
crate, `glifo`; the compute renderer keeps its own copy in `vello_encoding`.

### Design philosophy

The project's own summary of the compute design, and of why it was demoted:

> A scene is encoded into compact path, draw, transform, and resource buffers.
> Those buffers are resolved into a `Recording` of GPU operations, and
> `WgpuEngine` uploads resources and dispatches the compute pipeline.
> Prefix-scan algorithms parallelize work that traditional renderers often
> perform sequentially.
>
> This approach can perform very well on dynamic, vector-heavy scenes, but it
> requires compute shader support and has different compatibility and memory
> trade-offs from the Sparse Strips renderers.

— [`ARCHITECTURE.md`][arch]

`glifo` states the text-side intent: _"Provide an API surface that accepts
glyphs and their positions and renders them to a surface"_ and _"Share
expensive structs and data between the shaper and renderer like the hinting
instance and hinted advance"_ ([`glifo/src/lib.rs`][glifo-lib]). Text is
glyph runs in, pixels out; shaping, metrics and fonts belong to someone else.

## How it works

**Compute path.** `Scene::draw_glyphs(&FontData)` returns a `DrawGlyphs`
builder (`font_size`, `transform`, `glyph_transform`, `hint`,
`normalized_coords`, `brush`, `font_embolden`); `draw(style, glyphs)` takes
an iterator of `Glyph { id, x, y }`. For a font with no `COLR`/`CPAL` and no
bitmap strikes it does not touch outlines at all: it appends the glyphs and a
`GlyphRun` to `resources` and records a `Patch::GlyphRun`
([`scene.rs`][scene], lines 435–647). Outlines are produced later, at
_resolve_ time, by `GlyphCache::session(...).get_or_insert(glyph_id)`, which
draws the `skrifa` outline through an `OutlinePen` straight into an encoder
and caches the result as an `Arc<Encoding>` — a path-tag stream plus packed
segment data, not a bitmap ([`glyph_cache.rs`][enc-cache]). The resolver then
splices each glyph's cached streams into the scene and adds one transform per
glyph:

```rust
                    let glyph_end = self.glyphs.len();
                    run_sizes.path_tags += glyphs.len() + 2;
                    run_sizes.transforms += glyphs.len() + 1;
                    sizes.add(&run_sizes);
```

— [`resolve.rs`][resolve], lines 477–480

The GPU then runs the whole vector pipeline every frame: `pathtag_reduce`/
`pathtag_scan` (prefix sum over tag bytes, [`pathseg.md`][pathseg]),
`bbox_clear`, `flatten` (curves to lines), `draw_reduce`/`draw_leaf`,
`clip_*`, `binning`, `tile_alloc`, `path_count`, `backdrop`, `coarse`,
`path_tiling`, `fine` — sixteen-plus dispatches recorded in
[`render.rs`][render] (lines 250–491).

**Sparse-strips path.** `glifo::GlyphRunBuilder` has the same builder shape
and resolves each glyph through a cascade — _"COLR > bitmap > outline"_ —
emitting `fill_path`/`fill_rect`/`push_clip_layer` calls into a `DrawSink`
trait the backend implements ([`glyph.rs`][glifo-glyph], line 427;
[`interface.rs`][glifo-iface]). Paths are flattened and binned into 4×4
tiles ([`tile.rs`][tile], lines 263–266), kept as sparse strips with alpha
only at edges, and composited by `vello_cpu` or `vello_gpu`. Optionally
(_"currently highly experimental"_), rasterized glyphs are cached in a paged
atlas (`GlyphAtlas`, LRU by frame serial).

## Analysis spine

### 1. Layering and ownership

Two layers, neither a font layer. The font is `peniko::FontData { data: Blob,
index }` — a refcounted, id-carrying byte blob plus collection index; a fresh
`skrifa::FontRef::from_index` is built over it on every run, so there is no
face object. The scaled-font layer is the per-run `GlyphCacheSession` keyed by
`(font_id, index, size bits, coords, hint, style, embolden)`, borrowing
`&mut` the long-lived `GlyphCache`/`OutlineCache` and a `HintCache` of
`skrifa::HintingInstance`s split by `glyf`/`CFF`/`VARC` format
([`glyph.rs`][glifo-glyph], lines 1932–2207). Caches are single-owner,
`&mut`-threaded, never locked; eviction is generational (`maintain()` drops
entries unused for `MAX_ENTRY_AGE = 64` frames). Errors are soft: `glifo`
returns `GlyphRenderError` listing `SkippedGlyph`s with a `GlyphSkipReason`
but renders the rest; the compute resolver substitutes an empty encoding
(`// HACK: We pretend that the encoding was empty.`).

### 2. Face loading and table access

Delegated to [`skrifa`](./fontations.md). Vello reads `COLR`, `CPAL`, bitmap
strikes and outlines through `MetadataProvider`/`TableProvider`, and only to
decide how to draw. No raw table API, no path loading, no validation beyond
what `skrifa` does.

### 3. Shaping

None. Input is already-shaped `Glyph { id: u32, x: f32, y: f32 }`; ids are
font-specific, positions relative to the run transform. Clusters, script,
direction and features never appear. Shaping lives in [`parley`](./parley.md)
(or [`cosmic-text`](./cosmic-text.md)); `glifo`'s stated goal of sharing the
hinting instance and _hinted advance_ with the shaper is the one place the
renderer reaches upward, and it is not yet implemented.

### 4. Variation and instances

Coordinates are passed per run as `normalized_coords(&[NormalizedCoord])` —
normalized F2Dot14 values, i.e. after `avar`; the user-space → normalized
mapping is the caller's job (`skrifa`/`parley`). They reach rasterization
through `DrawSettings::unhinted(size, coords)` or a `HintingInstance` built
for those coords, and they partition every cache: `GlyphCache` keeps a static
`map` plus a `var_map: HashMap<VarKey, GlyphMap>` with `VarKey =
SmallVec<[NormalizedCoord; 8]>`, and `GlyphCacheKey.var_coords` is excluded
from `Hash`/`Eq` _because_ of that two-level partition
([`key.rs`][key]). Named instances and `STAT` are not consulted.

### 5. Rasterization and outlines

**Outlines (RQ6).** Callback sink: `skrifa`'s `OutlinePen`
(`move_to`/`line_to`/`quad_to`/`curve_to`/`close`, `f32`), already scaled to
pixels at `font_size` (`DrawSettings` carries the size), with y up — the
compute path then applies a `font_size/upem`, `-font_size/upem` flip for
color glyphs. Vello adapts the pen either to a `kurbo::BezPath` or directly
to its encoder, so the cached form is _encoded path streams_, never a public
outline object. Synthetic bold is `kurbo::expand_path` over the outline.

**Hinting.** `.hint(true)` performs _"vertical hinting only"_ and only when
the combined transform is a uniform scale with no skew or rotation; the
resolver otherwise silently drops it ([`resolve.rs`][resolve], lines
437–452). Options are fixed constants: `Engine::AutoFallback`,
`Target::Smooth { mode: SmoothMode::Lcd, preserve_linear_metrics: true }`
([`glyph_cache.rs`][enc-cache], lines 342–350).

**AA and quality (RQ2).** Compute: `AaConfig::Area` (exact winding-number
area integration, with documented _"conflation artifacts"_ where winding is
not 0/1), `Msaa8`, `Msaa16` ([`lib.rs`][lib], lines 177–194). Grayscale
only — no LCD subpixel output, no gamma or stem darkening. Subpixel
_positioning_ is free in the compute path: glyphs are cached as vectors in
size space and placed by a per-glyph transform, so the cache key has no
fractional offset. The sparse-strips atlas is the opposite: it caches
bitmaps, so `GlyphCacheKey` carries `subpixel_x` quantized into
`SUBPIXEL_BUCKETS = 4`, exact `size_bits` (no size quantization), and caps
caching at `max_cached_font_size: 128.0` ([`key.rs`][key];
[`cache.rs`][atlas-cache]).

**Color.** `COLRv0/v1` through `skrifa`'s `ColorPainter`, adapted to the
scene (`DrawColorGlyphs` in [`scene.rs`][scene]; `ColrPainter` in
[`colr.rs`][colr], line 314); `CBDT`/`sbix` bitmaps decoded (PNG, BGRA,
1/2/4/8-bpp masks in the compute path; PNG only in `glifo`), scaled from the
strike's ppem, with an `sbix` Apple Color Emoji offset hack. No `SVG `.

**Cost data (the GPU-compute data point).** Per glyph per frame the compute
renderer uploads the cached path tags and packed segments (i16 or f32 points,
one tag byte per segment, [`pathseg.md`][pathseg]) plus one transform and
re-runs flatten → binning → coarse → fine; nothing is retained between frames
on the GPU. The minimum pipeline is large: 5 407 lines of WGSL in `research/vello_shaders/shader`
(`flatten.wgsl` 923, `coarse.wgsl` 471, `fine.wgsl` 1 402), plus
4 905 lines of CPU encoding and 3 161 of CPU reference kernels. The project's
retreat from it is itself evidence: the sparse-strips CPU path is
`vello_common` 15 763 + `vello_cpu` 13 954 lines, and `glifo` 5 575.

### 6. Metrics and measurement

None. No ascender, line gap, advance or bounds API; positions come in
pre-computed. `glifo` uses `upem` and bitmap-strike bearings internally only
to place glyphs; underline geometry (`render_decoration`, with skip-ink) takes
offset and thickness from the caller.

### 7. Discovery, matching and fallback

None — absence by design. A run has exactly one `FontData`; fallback is
[`fontique`](./parley.md)'s job upstream.

## What it teaches `sparkles:font`

- **The renderer's contract is `(font blob id, index, size, coords, hint) +
[glyph id, x, y]`** — nothing else. That tuple is the right seam between a
  `sparkles:font` shaper and any `sparkles:ui` canvas backend, and the same
  tuple is the cache key.
- **Variation coords belong in the cache key as a first-level partition**, not
  hashed per glyph: Vello's two-level map avoids hashing a coords slice for
  every lookup.
- **Cache what the backend consumes.** A vector backend caches encoded paths
  (free subpixel positioning, re-raster every frame); a bitmap backend caches
  coverage and must quantize subpixel x (4 buckets) and cap size (128 px).
- **Hinting must be dropped under non-uniform transforms** and should be
  vertical-only for a smooth target — a rule `hue`'s zoomable views need.
- **GPU compute for text is real but heavy**: ~5.4 kLOC of shaders for a full
  vector pipeline before any atlas. For `sparkles:shader`'s D→SPIR-V compute,
  a glyph-only pipeline (no clips/blends/gradients) is the plausible subset —
  flatten, bin, fine — not the whole of `vello_shaders`.
- **Soft errors per glyph** (`SkippedGlyph` with a reason) are the right
  inspector-friendly failure model.

## Strengths

- Clean glyph-run seam; renderer independent of shaping and font choice.
- Variable fonts, `COLRv1`, bitmap emoji, hinting and synthetic bold in one
  path, all through `skrifa`.
- Exact-area AA plus MSAA options; arbitrary transforms on text.
- Generational caches with free-list reuse; `no_std` `glifo`.

## Weaknesses

- No metrics, shaping, discovery or outline API — useless alone.
- Grayscale only; no LCD, gamma or stem darkening; hinting options hard-coded.
- Compute renderer demoted to `research/` at the pinned revision; text code is
  duplicated between `vello_encoding` and `glifo`.
- Atlas caching marked _"highly experimental"_; no `SVG ` glyphs.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                        | Trade-off                                           |
| ----------------------------------------------- | ------------------------------------------------ | --------------------------------------------------- |
| Text is paths; no glyph bitmaps in compute path | One imaging model; transforms and subpixel free  | Every glyph re-rasterized every frame on the GPU    |
| Outline cache stores encoded streams            | Splice into scene with a memcpy at resolve time  | Not reusable as a general outline object            |
| Coords as normalized slice per run              | Matches `skrifa`; cheap to key                   | Caller must map user coords and named instances     |
| Hinting vertical-only, uniform scale only       | Keeps outlines transform-safe                    | Silent fallback to unhinted under rotation/skew     |
| Sparse-strips atlas with 4 subpixel buckets     | Bitmap reuse on CPU/WebGL2 backends              | 4× entries per glyph; no caching above 128 px       |
| Compute renderer moved to `research/`           | Compatibility and memory of vertex/fragment path | The GPU-compute text path is no longer the mainline |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- [`README.md`][readme], [`ARCHITECTURE.md`][arch] — renderer families.
- [`research/vello_research/src/scene.rs`][scene] — `DrawGlyphs`, color glyphs.
- [`research/vello_research/src/lib.rs`][lib] — `AaConfig`.
- [`research/vello_research/src/render.rs`][render] — compute dispatch list.
- [`research/vello_encoding/src/glyph_cache.rs`][enc-cache],
  [`resolve.rs`][resolve] — outline cache and glyph-run resolve.
- [`research/doc/pathseg.md`][pathseg] — path segment encoding.
- [`research/vello_shaders/shader/flatten.wgsl`][flatten],
  [`coarse.wgsl`][coarse], [`fine.wgsl`][fine] — compute stages.
- [`glifo/src/lib.rs`][glifo-lib], [`glyph.rs`][glifo-glyph],
  [`interface.rs`][glifo-iface], [`colr.rs`][colr],
  [`atlas/key.rs`][key], [`atlas/cache.rs`][atlas-cache] — sparse-strips text.
- [`vello_common/src/tile.rs`][tile] — 4×4 tiles.

<!-- References -->

[repo]: https://github.com/linebender/vello
[readme]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/README.md
[arch]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/ARCHITECTURE.md
[pathseg]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/research/doc/pathseg.md
[scene]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/research/vello_research/src/scene.rs
[lib]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/research/vello_research/src/lib.rs
[render]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/research/vello_research/src/render.rs
[enc-cache]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/research/vello_encoding/src/glyph_cache.rs
[resolve]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/research/vello_encoding/src/resolve.rs
[flatten]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/research/vello_shaders/shader/flatten.wgsl
[coarse]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/research/vello_shaders/shader/coarse.wgsl
[fine]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/research/vello_shaders/shader/fine.wgsl
[glifo-lib]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/glifo/src/lib.rs
[glifo-glyph]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/glifo/src/glyph.rs
[glifo-iface]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/glifo/src/interface.rs
[colr]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/glifo/src/colr.rs
[key]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/glifo/src/atlas/key.rs
[atlas-cache]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/glifo/src/atlas/cache.rs
[tile]: https://github.com/linebender/vello/blob/8cc000b685f522ca9edce6124bc8cbb83955aa67/vello_common/src/tile.rs
