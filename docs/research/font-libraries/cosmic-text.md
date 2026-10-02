# cosmic-text (Rust)

System76's pure-Rust text stack for the COSMIC desktop: one mutable
`FontSystem` context that owns the font database, the locale, every cache and
the shaping scratch, wrapped around HarfRust for shaping, skrifa for metrics
and swash for rasterization.

| Field            | Value                                                                                                 |
| ---------------- | ----------------------------------------------------------------------------------------------------- |
| Language         | Rust (2021; `no_std` + `alloc` behind the `no_std` feature)                                           |
| License          | MIT OR Apache-2.0 ([`Cargo.toml`][cargo])                                                             |
| Repository       | [`pop-os/cosmic-text`][repo]                                                                          |
| Documentation    | Crate docs in [`src/lib.rs`][lib]; [`README.md`][readme] roadmap; docs.rs                             |
| Category         | layout engine                                                                                         |
| Layer(s) covered | discover · match/fallback · shape · raster · outline · layout                                         |
| Version at pin   | 0.19.0; deps `fontdb` 0.24, `harfrust` 0.5.0, `skrifa` 0.40.0, `swash` 0.2.6                          |
| Size             | 12 379 lines of `.rs` under `src/` (`shape.rs` 3 084, `buffer.rs` 1 830, the vi/editor modules 2 074) |
| Pinned revision  | `f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6` (2026-09-30)                                               |

## Overview

### What it solves

Multi-line, multi-style, bidirectional text for GUI toolkits (iced, COSMIC
apps, glyphon users): `String` plus attribute spans in, positioned glyphs with
cache keys out, with editing, cursor hit-testing, wrapping and ellipsizing on
top. It is the closest Rust analogue to Pango ([`pango`](./pango.md)) with the
font database replaced by [`fontdb`](./fontdb.md) and the shaper by HarfRust
(the Rust HarfBuzz port that succeeded [`rustybuzz`](./rustybuzz.md) here).
It does not parse fonts itself: all table reading is delegated to `skrifa`
([`fontations`](./fontations.md)) and `swash` ([`swash`](./swash.md)).

### Design philosophy

The crate doc names the division of labour and the object model — one
`FontSystem` per application, one `SwashCache` per application, one `Buffer`
per widget:

```rust
//! This library provides advanced text handling in a generic way. It provides abstractions for
//! shaping, font discovery, font fallback, layout, rasterization, and editing. Shaping utilizes
//! harfrust, font discovery utilizes fontdb, and the rasterization is optional and utilizes
//! swash. The other features are developed internal to this library.
...
//! // A FontSystem provides access to detected system fonts, create one per application
//! let mut font_system = FontSystem::new();
//!
//! // A SwashCache stores rasterized glyphs, create one per application
//! let mut swash_cache = SwashCache::new();
```

— [`src/lib.rs`][lib], lines 3–22

The README adds the fallback stance: _"Font fallback is also a custom
implementation, reusing some of the static fallback lists in browsers such as
Chromium and Firefox."_ ([`README.md`][readme]).

## How it works

`Buffer` holds `Vec<BufferLine>`, the `Metrics { font_size, line_height }`
(both pixels, [`src/buffer.rs`][buffer] line 295), the wrap width, scroll and
`Hinting`. A `BufferLine` ([`src/buffer_line.rs`][bufline]) owns its text, an
`AttrsList` (default `Attrs` plus byte-range spans), a `Shaping` mode, and two
lazily-filled caches: `shape_opt: Cached<ShapeLine>` and
`layout_opt: Cached<Vec<LayoutLine>>`. `Buffer::shape_until_scroll` shapes
and lays out only the lines visible in the scroll window.

Shaping is hierarchical. `ShapeLine` runs `unicode_bidi` and produces
`ShapeSpan`s (one bidi level each); `ShapeSpan::build` splits the span at
`unicode_linebreak` opportunities into `ShapeWord`s — with a probe that
refuses to split between two ASCII punctuation characters if the font would
ligate them (`|>`, `!=`); each `ShapeWord` is shaped separately into
`ShapeGlyph`s ([`src/shape.rs`][shape], lines 777–1010). Layout then wraps
words into `LayoutLine { w, max_ascent, max_descent, glyphs: Vec<LayoutGlyph> }`
([`src/layout.rs`][layout], line 111). `LayoutGlyph::physical(offset, scale)`
yields a `PhysicalGlyph { cache_key, x, y }` — integer pixel origin plus a
`CacheKey` carrying the fractional part — and that key is what `SwashCache`
rasterizes.

## Analysis spine

### 1. Layering and ownership

Four layers, all funnelled through one `&mut FontSystem`:

| Layer        | Type                         | Owns                                                                                          |
| ------------ | ---------------------------- | --------------------------------------------------------------------------------------------- |
| Font manager | `FontSystem`                 | `fontdb::Database`, locale `String`, `font_cache`, match cache, shape scratch, fallback lists |
| Face         | `Font` (handed out as `Arc`) | `Arc` of the bytes, a `harfrust::Shaper` + `ShaperInstance`, skrifa `Metrics`, swash key      |
| Layout       | `Buffer` / `BufferLine`      | text, attributes, cached `ShapeLine` and `LayoutLine`s                                        |
| Raster cache | `SwashCache`                 | swash `ScaleContext`, `HashMap<CacheKey, Option<SwashImage>>`, outline-command cache          |

`FontSystem` ([`src/font/system.rs`][system], line 132) is the single
mutable context: `get_font(&mut self, id, weight)` memoizes
`Option<Arc<Font>>` per `(fontdb::ID, Weight)` (line 380), and even reading
font matches mutates (`get_font_matches(&mut self, attrs)`, line 437, behind a
256-entry cache that is cleared wholesale when full). Every shaping call takes
`&mut FontSystem`, so the crate is thread-confined by construction; the
borrow-pairing helper `BorrowedWithFontSystem` exists only to make that
ergonomic. `Font` is `Send + Sync` and shared by `Arc`; it is self-referential
via `self_cell!` because `harfrust::Shaper<'a>` borrows the bytes it lives
beside ([`src/font/mod.rs`][fontmod], lines 30–62). The face is keyed by
**weight**, not just ID: a variable font becomes one `Font` per requested
`wght`. Errors are `Option` throughout with `log::warn!` on the side; a run
with no default font panics (`expect("no default font found")`).

`FontSystem::new` is documented as slow — _"it can take up to a second, while
debug builds can take up to ten times longer"_ ([`src/font/system.rs`][system],
lines 184–190) — which is why `new_cached` adds a persistent on-disk index
(`$XDG_CACHE_HOME/cosmic-text/fonts.cache`), described in
[`src/font/cache.rs`][cache] as _"a pure-Rust, dependency-free
reimplementation of what fontconfig's `fc-cache` does"_, invalidated by
directory and file mtime/size fingerprints.

### 2. Face loading and table access

Loading is two-stage. `fontdb` enumerates and records `FaceInfo` (family,
weight, stretch, style, `monospaced`, `post_script_name`, `Source`, face
`index`); bytes are only attached on first use (`make_shared_face_data` memory
maps the file). `Font::new(db, id, weight)` then parses the same bytes **three
times** — a skrifa `FontRef` for metrics and the `wght` location, a second
skrifa `FontRef` inside the `self_cell` for the HarfRust shaper, and a
`swash::FontRef` whose `(offset, key)` is stored for later — the source
comments on the duplication: _"It's a bit unfortunate but we need to parse the
data into a `FontRef` twice"_ ([`src/font/mod.rs`][fontmod], lines 138–141).
A `fontdb::Source::File` without shared data is refused with a warning.
Collections are supported through `info.index`. Raw tables are reachable only
by re-exporting `skrifa` (`Font::data()` plus `skrifa::FontRef`); cosmic-text
itself reads `GSUB`/`GPOS` script lists and the full cmap only to build its
monospace-fallback index.

### 3. Shaping

`Shaping::Advanced` runs HarfRust with fallback; `Shaping::Basic` maps chars
through the cmap with `hmtx` advances, no GSUB/GPOS, and only falls back to a
generic family when a named family misses ([`src/shape.rs`][shape], lines
28–44, 501–590). In `shape_fallback` the buffer is filled per run,
`guess_segment_properties()` derives script and language, `Attrs::font_features`
become `harfrust::Feature`s spanning the whole run, and a
`ShapePlanKey(script, direction).features(..).instance(..).language(..)`
looks up a small FIFO of `harfrust::ShapePlan`s per font:

```rust
    let key = harfrust::ShapePlanKey::new(Some(buffer.script()), buffer.direction())
        .features(&rb_font_features)
        .instance(Some(font.shaper_instance()))
        .language(language.as_ref());
```

— [`src/shape.rs`][shape], lines 192–195

Shaping is size-independent: HarfRust output is divided by `units_per_em`, so
`ShapeGlyph` advances and offsets are **em fractions**, multiplied by
`font_size` only at layout ([`src/shape.rs`][shape], lines 250–262, 705).
Clusters map back to UTF-8 byte ranges `start..end` of the line; the end is
reconstructed by walking neighbouring clusters (reversed for RTL). The cost of
per-word shaping is that contextual features cannot cross a line-break
opportunity — kerning against a space and ligatures across words are lost,
which the ASCII-punctuation probe patches for code ligatures. An optional
`shape-run-cache` feature memoizes `Vec<ShapeGlyph>` by
`(text, AttrsOwned, spans)` with age-based trimming
([`src/shape_run_cache.rs`][runcache]).

### 4. Variation and instances

Only `wght`. `Attrs` has `weight`, `stretch`, `style` and `font_features`, but
no axis-coordinate field. `Font::new` builds a skrifa location from
`[("wght", weight)]` and feeds its normalized coordinates to
`harfrust::ShaperInstance::from_coords`; `SwashCache` separately recomputes
`normalized_coords([("wght", weight.clamp(min, max))])` for the swash scaler
([`src/swash.rs`][swash], lines 28–44). Both sides take user-space `wght` and
normalize through each library's own `avar` handling, so the two coordinate
vectors are derived independently from the same scalar rather than shared.
`FontMatchKey::variable_weight_match` lets a variable face whose `wght` range
covers the request win matching. `wdth`, `opsz`, `slnt`, named instances and
`STAT` are not reachable; italic is synthesized (`CacheKeyFlags::FAKE_ITALIC`,
a 14° skew) when the matched face is not italic. A test in `swash.rs` (lines
254–301) documents a fixed bug in which swash's `variations()` leaked stale
coordinates across fonts in a shared `ScaleContext`.

### 5. Rasterization and outlines

**Cache key (RQ2).** `CacheKey { font_id, glyph_id, font_size_bits,
x_bin, y_bin, font_weight, flags }` ([`src/glyph_cache.rs`][gcache], lines
19–34). `SubpixelBin` quantizes fractional position to quarters on **both**
axes (`0, .25, .5, .75`, ties at `.125` boundaries); layout already truncates
Y (`// Hinting in Y axis`, [`src/layout.rs`][layout] line 95), so in practice
4 horizontal variants per glyph per size. `font_size_bits` is the raw `f32`
bit pattern, so every distinct fractional size is a distinct cache entry.

**Raster.** `SwashCache::get_image` renders with source priority
`ColorOutline(0)` (COLR, palette 0) → `ColorBitmap(BestFit)` (CBDT/sbix) →
`Outline`, `Format::Alpha` (grayscale; swash's `SubpixelMask` content is
handled when drawing but never requested), swash TrueType hinting unless
`DISABLE_HINTING`, and the fractional offset applied by the rasterizer
([`src/swash.rs`][swash], lines 18–80). `CacheKeyFlags::PIXEL_FONT` rounds the
offset. Layout-level `Hinting::Enabled` additionally snaps X positions to
integers. No gamma handling, no LCD filtering, no atlas: `SwashCache` is an
unbounded `HashMap` of CPU images; [`glyphon`](./glyphon.md) supplies the GPU
atlas.

**Outlines (RQ6).** `get_outline_commands(key)` returns
`Box<[swash::zeno::Command]>` — `MoveTo`/`LineTo`/`QuadTo`/`CurveTo`/`Close`
in **pixels at `font_size`**, Y-up, hinted unless disabled, fake-italic
skewed, falling back to the color outline (lines 82–127). An array, cached per
`CacheKey`.

### 6. Metrics and measurement

Font metrics come from skrifa's `Metrics` at `Size::unscaled()` and the
`wght` location — skrifa chooses typo vs hhea per `USE_TYPO_METRICS`.
Per-glyph `ascent`/`descent` are stored as em fractions on each `ShapeGlyph`;
`LayoutLine` tracks `max_ascent`/`max_descent`, but line height is the
caller's `Metrics::line_height` (or a per-span `metrics_opt` override), not a
font-derived value. Underline/strikeout offsets come from `post`/`OS/2` via
skrifa, with hard-coded fallbacks (`-0.125` em offset, `1/14` em thickness;
[`src/shape.rs`][shape], lines 720–730). `Font::monospace_em_width()` is the
space advance over `upem` for faces fontdb flags as monospaced. x-height and
cap-height are not surfaced (reachable via `Font::metrics()`).

### 7. Discovery, matching and fallback

Discovery is fontdb (`load_system_fonts`, or the cached index). Default
generics are hard-coded in `finish_with_db`: monospace `Noto Sans Mono`,
sans `Open Sans`, serif `DejaVu Serif` (`//TODO: configurable default fonts`).
Matching (`get_font_matches`) scores **every face in the database** into a
`FontMatchKey` sorted lexicographically by `(not_emoji, weight_diff,
stretch_diff, style_diff, weight, stretch, id)`, then moves fontdb's CSS-style
`query` winner to the front ([`src/font/system.rs`][system], lines 20–80,
437–490). Emoji detection is `post_script_name.contains("Emoji")`.

Fallback is script-driven and static. `shape_run` collects the run's scripts
(ignoring Common/Inherited/Latin/Unknown), then `FontFallbackIter` yields: the
requested family; for monospace requests, monospace faces that declare the
script in `GSUB`/`GPOS` (ranked by codepoint coverage of the current word);
per-script families from the `Fallback` trait; then `common_fallback`
([`src/font/fallback/mod.rs`][fallback], lines 68–77, 289+). The run is
reshaped whole with each candidate and only clusters that were `.notdef` and
are not `.notdef` in the candidate are spliced in. `PlatformFallback` is a
compile-time table per OS ([`unix.rs`][fb-unix], [`macos.rs`][fb-mac],
[`windows.rs`][fb-win]); Han is resolved by locale (`ja` → `Noto Sans CJK JP`,
etc., `unix.rs` line 56). On Linux the fontconfig feature is used only to find
font directories — no `FcFontSort`, no per-codepoint charset query.

## What it teaches `sparkles:font`

- **A single `&mut` context is the simplest correct ownership model** — and
  its cost is global thread-confinement. `sparkles:font` should split it: an
  immutable, shareable face database plus per-thread scratch/caches, so `hue`
  can shape on worker threads.
- **Shape at `upem`, scale at layout.** Storing em-fraction advances makes
  shaping results size-independent and cacheable across zoom; only the raster
  key carries pixel size.
- **The raster cache key is the API seam to copy**: `(face, glyph, size bits,
x_bin, y_bin, variation, flags)` with 4 horizontal subpixel bins. Fold the
  full normalized coordinate vector into it, not just `wght`.
- **Keying faces by weight does not generalize to variations**; a
  `ScaledFont`/instance object that owns one coordinate vector shared by
  shaper and rasterizer avoids cosmic-text's two independently-derived
  coordinate sets.
- **Per-word shaping breaks programming ligatures across spaces and
  punctuation** — cosmic-text needed a ligature probe; a terminal/code viewer
  should shape per run (or per cell cluster) and break lines afterwards.
- **A persistent face-index cache keyed by directory mtimes** is cheap and
  removes the dominant start-up cost; worth having even when fontconfig is
  available.

## Strengths

- Complete pipeline in one crate: discovery, matching, script fallback, bidi,
  shaping, wrapping, ellipsizing, editing, raster.
- Size-independent shaping output and lazy, scroll-bounded shaping.
- Pluggable `Fallback` trait; CJK locale handling built into the default tables.
- Color glyphs (COLR outlines, CBDT/sbix bitmaps) via swash with explicit
  source priority.
- On-disk face-index cache; `no_std` build.

## Weaknesses

- One `&mut FontSystem` serializes all text work in a process.
- Fonts parsed three times (two skrifa, one swash); three font libraries in the
  dependency graph.
- Only `wght` is a variation input; faces cached per weight.
- Per-word shaping loses cross-word context; fallback reshapes entire runs per
  candidate (`//TODO: improve performance!`).
- Matching scans every face per new `Attrs`; emoji detected by name substring.
- No LCD, gamma, or atlas; raster cache is unbounded.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                | Trade-off                                                      |
| --------------------------------------------------------- | ---------------------------------------- | -------------------------------------------------------------- |
| One mutable `FontSystem` owning db, caches and scratch    | No locks, simple borrow story            | No concurrent shaping; every query is `&mut`                   |
| `Font` = `Arc` + `self_cell` HarfRust shaper over bytes   | Shaper built once per face and shared    | Self-referential type; re-parse per weight                     |
| Shaping output in em units                                | Reuse across sizes; cheap zoom           | Multiplication at layout for every glyph                       |
| Shape per line-break word                                 | Incremental relayout, easy wrapping      | Cross-word kerning/ligatures lost; needs the punctuation probe |
| Static per-script fallback tables + locale for Han        | Predictable; mirrors browsers            | Misses system configuration; tables are code                   |
| `CacheKey` with 4×4 subpixel bins and raw `f32` size bits | Exact reuse, sub-pixel placement         | Cache explosion at fractional sizes; no eviction               |
| swash for raster, `Format::Alpha` only                    | Hinting + color glyphs without FreeType  | No LCD/gamma; GPU atlas left to consumers                      |
| On-disk `FaceInfo` cache                                  | Start-up cost dominated by font scanning | Another cache format to invalidate                             |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- [`src/lib.rs`][lib] — crate overview and object model.
- [`src/font/mod.rs`][fontmod] — `Font`, `self_cell` HarfRust face, `wght` location.
- [`src/font/system.rs`][system] — `FontSystem`, `FontMatchKey`, `get_font`, `get_font_matches`.
- [`src/font/cache.rs`][cache] — persistent face-index cache.
- [`src/font/fallback/mod.rs`][fallback] — `Fallback` trait, `FontFallbackIter`.
- [`src/font/fallback/unix.rs`][fb-unix], [`macos.rs`][fb-mac], [`windows.rs`][fb-win] — platform tables.
- [`src/shape.rs`][shape] — `Shaping`, `shape_fallback`, `shape_run`, `ShapeGlyph`/`ShapeWord`/`ShapeSpan`/`ShapeLine`.
- [`src/shape_run_cache.rs`][runcache] — optional run cache.
- [`src/layout.rs`][layout], [`src/buffer.rs`][buffer], [`src/buffer_line.rs`][bufline], [`src/attrs.rs`][attrs] — layout types, `Metrics`, `Attrs`.
- [`src/glyph_cache.rs`][gcache], [`src/swash.rs`][swash] — `CacheKey`, `SubpixelBin`, `SwashCache`.
- [`README.md`][readme], [`Cargo.toml`][cargo].

<!-- References -->

[repo]: https://github.com/pop-os/cosmic-text
[lib]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/lib.rs
[readme]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/README.md
[cargo]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/Cargo.toml
[fontmod]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/font/mod.rs
[system]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/font/system.rs
[cache]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/font/cache.rs
[fallback]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/font/fallback/mod.rs
[fb-unix]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/font/fallback/unix.rs
[fb-mac]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/font/fallback/macos.rs
[fb-win]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/font/fallback/windows.rs
[shape]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/shape.rs
[runcache]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/shape_run_cache.rs
[layout]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/layout.rs
[buffer]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/buffer.rs
[bufline]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/buffer_line.rs
[attrs]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/attrs.rs
[gcache]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/glyph_cache.rs
[swash]: https://github.com/pop-os/cosmic-text/blob/f1a3461f3e8df67d2bbcfafb8bc61dc7aee5b2a6/src/swash.rs
