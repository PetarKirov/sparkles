# Ghostty font stack (Zig / terminal)

A terminal's font subsystem built as a ladder of plain Zig structs —
`Face` → `Collection` (styles × priority list, deferred faces) →
`CodepointResolver` (overrides, sprites, discovery fallback) → `SharedGrid`
(atlases, glyph cache, one `RwLock`) → `SharedGridSet` (one grid per font
configuration) — with the face, shaper and discovery backends chosen at
compile time.

| Field            | Value                                                                                            |
| ---------------- | ------------------------------------------------------------------------------------------------ |
| Language         | Zig                                                                                              |
| License          | MIT ([`LICENSE`][license])                                                                       |
| Repository       | [`ghostty-org/ghostty`][repo]                                                                    |
| Documentation    | Doc comments in `src/font/*.zig`; [`src/font/sprite/draw/README.md`][sprite-readme]              |
| Category         | terminal font stack                                                                              |
| Layer(s) covered | discover · match/fallback · shape · raster · (parse: partial, own `opentype/` readers) · metrics |
| Pinned revision  | `0c2a290d3a3e2a599be3a43435d778a5896667ee` (2026-09-14)                                          |

## Overview

### What it solves

Ghostty renders a cell grid on several surfaces (windows, tabs, splits) that
usually share one font configuration. Its font stack must answer, per cell:
which face renders this grapheme in this style and presentation, what glyph ids
does shaping produce for the run, and where in a GPU atlas is each rasterized
glyph — while multiple renderer threads read concurrently and fallback faces
are discovered lazily. It covers Linux (fontconfig + FreeType + HarfBuzz),
macOS (CoreText for discovery, rendering and shaping), Windows (a FreeType
directory scanner) and the browser (`web_canvas`).

It is the closest existing design to what `sparkles:font` must deliver for the
terminal and `hue`, and the current `sparkles:raylib-text` stack already
mirrors several of its ideas (`--font-codepoint-map`, synthetic bold/italic,
emoji presentation; see the contrast at the end of "What it teaches").

### Design philosophy

Backends are a compile-time enum, not a runtime vtable. Each combination names
exactly which subsystem does discovery, rasterization and shaping:

```zig
    /// Fontconfig for font discovery and FreeType for font rendering.
    fontconfig_freetype,

    /// CoreText for font discovery, rendering, and shaping (macOS).
    coretext,

    /// CoreText for font discovery, FreeType for rendering, and
    /// HarfBuzz for shaping (macOS).
    coretext_freetype,
```

— [`src/font/backend.zig`][backend]

`Face`, `Shaper` and `Discover` are then `switch (options.backend)` type
aliases ([`src/font/face.zig`][face-zig], [`src/font/shape.zig`][shape-zig],
[`src/font/discovery.zig`][discovery]); `Discover` is `void` for backends
with no discovery, and callers test `font.Discover != void` at comptime. The
second principle is _separation of storage from search_:

```zig
//! The purpose of a collection is to store a list of fonts by style
//! and priority order. A collection does not handle searching for font
//! callbacks, rasterization, etc. For this, see CodepointResolver.
```

— [`src/font/Collection.zig`][collection]

## How it works

- **`Face`** wraps one backend face at one size. The FreeType face holds the
  `FT_Face`, a paired `hb_font_t`, load flags, a `synthetic` bit-pair
  (`italic`, `bold`), the `DesiredSize { points, xdpi, ydpi }`, and a heap
  `ft_mutex` that "MUST be held while doing anything with the glyph slot"
  ([`src/font/face/freetype.zig`][ft-face]). Its duck-typed surface is
  `initFile(lib, path, index, opts)`, `setSize`, `setVariations`, `glyphIndex`,
  `hasColor`, `isColorGlyph`, `renderGlyph(alloc, atlas, glyph, opts)`,
  `getMetrics`, `copyTable(alloc, tag)`, `syntheticBold`, `syntheticItalic`.
- **`DeferredFace`** is a discovered-but-unloaded face: the fontconfig pattern
  with its `charset`/`langset`, a CoreText descriptor, or a Windows path plus
  `face_index` "for .ttc collections" and a cheap peek face
  ([`src/font/DeferredFace.zig`][deferred]). `hasCodepoint` answers coverage
  and presentation from that metadata without loading.
- **`Collection`** is an `EnumArray(Style, SegmentedList(Entry))` where
  `Entry` is `deferred | loaded` (or an `alias` to another style's entry). A
  face is addressed by `Collection.Index`, a 16-bit packed `{ style, idx }`
  whose top `idx` value is reserved for `Special.sprite`
  ([`src/font/Collection.zig`][collection]).
- **`CodepointResolver`** owns the collection plus an optional `Discover`, a
  user `CodepointMap`, a descriptor→face cache, and the `SpriteFace`
  ([`src/font/CodepointResolver.zig`][resolver]).
- **`SharedGrid`** owns the resolver, two `Atlas`es (`grayscale`, `bgra`),
  a `(style, codepoint, presentation) → ?Index` cache, a
  `(Index, glyph, RenderOptions) → Render` cache, the grid `Metrics`, and one
  `std.Io.RwLock` ([`src/font/SharedGrid.zig`][grid]).
- **`SharedGridSet`** maps a `Key` — the ordered discovery descriptors per
  style, the codepoint map, metric modifiers and font size, all in an arena —
  to a refcounted `SharedGrid` ([`src/font/SharedGridSet.zig`][gridset]).
- **Shaping** walks one terminal row through `RunIterator`, which splits runs
  and picks a `Collection.Index` per run, then calls the backend `Shaper.shape`
  ([`src/font/shaper/run.zig`][run], [`src/font/shaper/harfbuzz.zig`][hb-shaper]);
  results are memoized by run hash in `shaper/Cache.zig` ([`Cache.zig`][cache]).

## Analysis spine

### 1. Layering and ownership

| Layer          | Type                | Owns                                                    | Concurrency                                     |
| -------------- | ------------------- | ------------------------------------------------------- | ----------------------------------------------- |
| library        | `Library`           | `FT_Library` + a mutex for face creation                | mutex in `initFile`/`init`                      |
| face           | `Face`              | backend face, `hb_font_t`, size, synthetic flags        | per-face `ft_mutex` around glyph slot           |
| unloaded face  | `DeferredFace`      | discovery record (pattern / descriptor / path + index)  | immutable until `load`                          |
| font list      | `Collection`        | `Entry` per style × priority; `metrics`, `load_options` | none (guarded by grid lock)                     |
| resolution     | `CodepointResolver` | collection, `Discover`, `CodepointMap`, `SpriteFace`    | none (guarded by grid lock)                     |
| render cache   | `SharedGrid`        | resolver, two atlases, two hash maps, `Metrics`         | `RwLock`: shared read fast path, exclusive miss |
| config sharing | `SharedGridSet`     | `Key` → refcounted `SharedGrid`                         | own mutex; documented thread-safe operations    |
| shaping        | `Shaper` + `Cache`  | `hb_buffer_t`, feature array, cell buffer               | one per renderer thread                         |

Ownership is explicit: `Collection.add` "takes ownership of the face" on
success, every `init` takes an `Allocator`, and errors are Zig error unions
(`AddError = Allocator.Error || error{ CollectionFull, SetSizeFailed }`).
Lookups follow a double-checked pattern: read lock, probe the hash map, drop it,
take the write lock, `getOrPut`, then resolve or render
([`SharedGrid.zig`][grid] `renderGlyph`). `SharedGrid` deliberately cannot
resize or change families; a config change builds a new grid and surfaces
switch over. The CoreText shaper relies on Apple's documented split (font
objects thread-safe, layout objects per thread) and holds only the read lock
while setting up a face ([`shaper/coretext.zig`][ct-shaper]).

### 2. Face loading and table access

Faces load from a path plus collection index (`Face.initFile(lib, path, index,
opts)`) or from memory (`Face.init`, index 0) ([`face/freetype.zig`][ft-face]).
Discovery supplies the index: fontconfig's `FC_INDEX` via
`fc.pattern.get(.index, 0)`, the Windows scanner's `face_index`
([`DeferredFace.zig`][deferred]). Loading is lazy at the face level — a
fallback lives as a `DeferredFace` until `Collection.getFace` promotes it.

Raw tables: `Face.copyTable(alloc, tag)` returns an owned copy on both
backends. Ghostty also carries its own minimal readers under `src/font/opentype/`
(`head`, `hhea`, `os2`, `post`, `sfnt`, `svg`, `glyf`); `Glyf` keeps "a
pointer (slice) to the underlying data" and decodes on demand
([`opentype/glyf.zig`][glyf]) — the borrowed-buffer shape `sparkles:font`
plans.

### 3. Shaping

The `RunIterator` is the terminal-specific half. A run never crosses a row and
breaks at: style changes other than background (so `>=` is not one ligature in
two colors), the cursor (before, at, after), selection bounds, and known bad
ligatures (`fl`, `fi`, `st`). Per cell it resolves a font for the _entire_
grapheme, so combining marks pick a face that covers all of them, else the
replacement character ([`shaper/run.zig`][run]). Presentation comes from the
first grapheme codepoint after the base: `U+FE0E` forces text, `U+FE0F` emoji.

The run's `hash` is position-independent (relative clusters), so identical runs
anywhere in the viewport share one `shaper.Cache` entry; the cache comment
records that shaping was once "96% of frame time"
([`Cache.zig`][cache]). The HarfBuzz shaper prepends `default_features`
(`liga = 1`) to user `font-feature` strings parsed by
`Feature.fromString` (CSS-like `+kern`, `kern on`, `"kern" = 1`), all
global-range ([`shaper/feature.zig`][feature], [`shaper/harfbuzz.zig`][hb-shaper]).
Output is `shape.Cell { x, x_offset, y_offset, glyph_index }` — positions in
_cells_, not font units, with cluster→cell mapping done in the shaper's
cluster loop ([`shape.zig`][shape-zig]). The CoreText shaper forces embedding
level 0 via `kCTTypesetterOptionForcedEmbeddingLevel`: no BiDi. The `noop`
shaper maps codepoint→glyph one to one ([`shaper/noop.zig`][noop]).

### 4. Variation and instances

`font.face.Variation { id: Id (packed 4-byte tag), value: f64 }` in design
(user) units, modeled on CSS `font-variation-settings`
([`face.zig`][face-zig]). Variations sit on the discovery `Descriptor` (they
"impact searching … fonts with the ability to set these variations will be
preferred") and are applied after load with `Face.setVariations`. FreeType
needs all axes at once, so it reads current design coordinates into a
fixed 32-slot stack array, patches the matching tags, and calls
`setVarDesignCoordinates`; CoreText rebuilds the descriptor with
`createCopyWithVariation` and `copyWithAttributes`
([`face/freetype.zig`][ft-face], [`face/coretext.zig`][ct-face]). Because the
HarfBuzz font is created from the `FT_Face`, shaping sees the same
coordinates. Named instances, `avar` and `STAT` are not surfaced; axes are
only logged in debug builds.

### 5. Rasterization and outlines

Rasterization goes through the backend (`FT_Load_Glyph` + render, or a
CoreGraphics bitmap context with `setAllowsAntialiasing`/`setShouldSmoothFonts`
for `thicken`) into an `Atlas` — a square skyline bin-packer after Jylänki and
freetype-gl ([`Atlas.zig`][atlas]). Two atlases split by presentation;
`AtlasFull` doubles the atlas and retries. `RenderOptions` carries the grid
`Metrics`, `cell_width`, `constraint_width` and a `Constraint` (size `cover`,
alignment, padding) used to fit emoji and Nerd Font icons, whose per-codepoint
constraints are generated from the Nerd Fonts patcher into
[`nerd_font_attributes.zig`][nerd] ([`Glyph.zig`][glyph]).

Color: FreeType loads with color and sets `NO_SVG` ("we don't currently
support rendering SVG glyphs under FreeType"), so `CBDT`/`sbix`/`COLR` go
through FreeType and SVG does not; CoreText treats any `sbix` table as color
([`face/coretext.zig`][ct-face]). Synthetic bold is `FT_Outline_Embolden`
scaled by font height; synthetic italic is a skew (CoreText `italic_skew`
matrix).

Procedural glyphs: the `SpriteFace` draws box drawing, blocks, braille,
Powerline, legacy-computing symbols and underline/cursor sprites with `z2d`,
dispatching by `draw<CODEPOINT>`/`draw<MIN>_<MAX>` function names discovered at
comptime ([`sprite/Face.zig`][sprite-face], [`sprite/draw/README.md`][sprite-readme])
— the same idea as `sparkles:raylib-text`'s `drawBox`, but fed through the
same atlas and `Index` (`Special.sprite`) as real fonts.

From-scratch evidence (RQ2): [`glyf_rasterize.zig`][glyf-raster] rasterizes a
decoded `glyf` outline to a full-cell alpha8 bitmap via `z2d`, reusing the
`Constraint` machinery; at the pin it is exported from `font/main.zig` but has
no caller (its "exact glyph protocol constraints" consumer was reverted).

Outlines are **not exposed** as an API; they exist only inside the backends
and the `Glyf.Outline { contours, points }` decoder.

### 6. Metrics and measurement

`Face.getMetrics` returns `FaceMetrics` in pixels (+Y up): `px_per_em`,
`cell_width`, `ascent`, `descent`, `line_gap`, optional underline,
strikethrough, `cap_height`, `ex_height`, `ic_width`
([`Metrics.zig`][metrics]). The FreeType path picks vertical metrics as:
`OS/2` `sTypo*` if `fsSelection` bit 7 is set; else `hhea` if non-zero; else
`sTypo*` if non-zero; else `usWin*`. Underline comes from `post`, strikeout
from `OS/2`, each treated as missing when thickness is 0
([`face/freetype.zig`][ft-face]). `cell_width` is _measured_ as the max advance
over printable ASCII, falling back to `max_advance`.

`Metrics.calc` rounds width and height to integers and splits the line gap
half above, half below; a user `ModifierSet` (`adjust-cell-height`, …)
applies afterwards. Fallback faces are resized to match the primary through
`SizeAdjustment` (`ic_width` → `ex_height` → `cap_height` → `line_height`
fallthrough), described as working "very much like the `font-size-adjust` CSS
property" ([`Collection.zig`][collection]).

### 7. Discovery, matching and fallback

`discovery.Descriptor` is the query: `family` (on fontconfig a full pattern
such as `"Fira Code-14:bold"`), `style` string, `codepoint`, `size`, `bold`,
`italic`, `monospace`, `variations`; it hashes for cache keys
([`discovery.zig`][discovery]). Backends: fontconfig `fontSort`; CoreText
enumerates descriptors and sorts by a packed `Score` whose field order _is_ the
precedence — `codepoint` > `monospace` > `exact_style` > `italic` > `bold` >
`fuzzy_style` > `glyph_count`. CoreText fallback special-cases CJK Unified
Ideographs (`U+4E00`–`U+9FFF`) and the empty-result case through
`CTFontCreateForString`, since that respects system locale.

The resolution order in `CodepointResolver.getIndex` is the cleanest
statement of fallback policy in this catalog:

```zig
    // Codepoint overrides.
    if (self.getIndexCodepointOverride(alloc, cp)) |idx_| {
        if (idx_) |idx| return idx;
    } ...
    // If we have sprite drawing enabled, check if our sprite face can
    // handle this.
    if (self.sprite) |sprite| {
        if (sprite.hasCodepoint(cp, p)) {
            return .initSpecial(.sprite);
        }
    }
```

— [`src/font/CodepointResolver.zig`][resolver]

Then: default presentation from the UCD `is_emoji_presentation` property;
the style's own list; for non-regular styles, the regular list (not a
styled fallback — "ugly rendering"); for regular, `discoverFallback` with
the codepoint, adding the first deferred face whose coverage _and_
presentation match; last, any-presentation regular. `CodepointMap` is a
linear-scanned `MultiArrayList` of `{ range: [2]u21, descriptor }`
([`CodepointMap.zig`][cpmap]). Missing bold/italic styles are synthesized by
`Collection.completeStyles`, gated per style by config.

## What it teaches `sparkles:font`

- **Separate storage (`Collection`), policy (`CodepointResolver`) and cache
  (`SharedGrid`).** Each is a plain struct with one owner; the D port maps to a
  `FaceList`, a `Resolver` with a documented resolution order, and a
  `GlyphCache` keyed by `(FaceIndex, glyph, RenderOptions)`.
- **A 16-bit face handle with a reserved "sprite" slot** lets procedural box
  drawing share shaping, cache and atlas paths with real fonts — `drawBox`
  should become a face, not a renderer special case.
- **Deferred faces are the fallback scaling trick.** Coverage and
  presentation answered from discovery metadata (fontconfig charset/langset,
  CoreText descriptor) keeps the fallback list long and loading rare.
- **Grid metrics are measured and rounded once, then passed into rendering**
  as `RenderOptions`; fallback faces are size-adjusted to the primary by an
  explicit metric ladder.
- **Shape per run with a position-independent hash cache**; break runs at
  style, cursor and selection boundaries, and resolve fonts per grapheme.
- **Encode match precedence as a packed integer** (`Score`) rather than
  weighted sums: comparison is one integer compare and the priority is
  readable from the field order.

**Contrast with the current `sparkles:raylib-text`.** [`font_set.d`][sp-fontset] already copies Ghostty's vocabulary (a primary face,
real bold/italic variants, a regular and a Nerd-Font fallback, up to 8
`--font-codepoint-map` faces), but as fixed named fields over raylib
`LoadFontEx` atlases plus a separate FreeType/HarfBuzz `ClusterCache` for
clusters and fallbacks, so there are two raster paths. [`shaping_c.c`][sp-shaping]
pairs one `FT_Face` with one `hb_font_t` and `hb_buffer_t` per face behind an
ImportC seam. Ghostty's model replaces both with one `Collection`, one
`Index`, one glyph cache and one atlas pair, with fallback discovered lazily
instead of preconfigured.

## Strengths

- A clear, documented fallback order including presentation and style
  demotion; per-codepoint overrides are first-class.
- Read-mostly concurrency with one `RwLock` and double-checked caches, shared
  across surfaces by `SharedGridSet`.
- Terminal-grade metrics: measured cell width, defensive table selection,
  rounding policy written down with its rationale.
- Procedural sprites and Nerd Font constraints integrated into the face model.

## Weaknesses

- Compile-time backend choice: one binary cannot mix CoreText discovery with
  FreeType rendering at runtime.
- No outline, inspector or table-enumeration API; `copyTable` copies.
- Variations are design-coordinate overrides only; no named instances, no
  `avar`/`STAT`, axis count capped at 32 on FreeType.
- Features are global; per-face or per-range features are a noted TODO in
  `shape.Options`.
- No BiDi on CoreText (forced level 0), and run splitting embeds
  terminal-specific policy (`fi`/`fl`/`st`).

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                          | Trade-off                                                |
| ------------------------------------------------ | ------------------------------------------------------------------ | -------------------------------------------------------- |
| Backend as comptime enum                         | Zero dispatch cost; dead code removed per platform                 | No runtime choice; combinatorial build matrix            |
| `DeferredFace` in the collection                 | Many fallbacks searchable without loading                          | Coverage checks per backend; presentation is approximate |
| 16-bit `Collection.Index` with special slot      | Compact cache keys; sprites flow through the same pipeline         | 8192-ish faces per style ceiling                         |
| One `RwLock` per `SharedGrid`                    | Reads dominate; simple reasoning                                   | Callers may take the lock directly; review burden        |
| Immutable grid; config change = new grid         | Font size change in one surface does not disturb others            | Rebuild cost on every font config change                 |
| Shaping cache keyed by relative-cluster run hash | Shaping was the dominant frame cost                                | Hash collisions render wrong glyphs silently             |
| `SizeAdjustment` ladder for fallbacks            | Fallback glyphs visually match primary x-height or ideograph width | Requires measurable metrics in every fallback face       |
| Packed-struct `Score` for matching               | Precedence by field order, one integer compare                     | No weighted trade-offs between criteria                  |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- **Core ladder** — [`backend.zig`][backend], [`face.zig`][face-zig],
  [`Collection.zig`][collection], [`DeferredFace.zig`][deferred],
  [`CodepointResolver.zig`][resolver], [`CodepointMap.zig`][cpmap],
  [`SharedGrid.zig`][grid], [`SharedGridSet.zig`][gridset],
  [`discovery.zig`][discovery].
- **Faces and raster** — [`face/freetype.zig`][ft-face],
  [`face/coretext.zig`][ct-face], [`Atlas.zig`][atlas], [`Glyph.zig`][glyph],
  [`Metrics.zig`][metrics], [`glyf_rasterize.zig`][glyf-raster],
  [`opentype/glyf.zig`][glyf], [`nerd_font_attributes.zig`][nerd].
- **Shaping** — [`shape.zig`][shape-zig], [`shaper/run.zig`][run],
  [`shaper/harfbuzz.zig`][hb-shaper], [`shaper/coretext.zig`][ct-shaper],
  [`shaper/noop.zig`][noop], [`shaper/feature.zig`][feature],
  [`shaper/Cache.zig`][cache].
- **Sprites** — [`sprite/Face.zig`][sprite-face],
  [`sprite/draw/README.md`][sprite-readme], [`sprite/draw/box.zig`][sprite-box],
  [`sprite/draw/powerline.zig`][sprite-powerline].
- **sparkles today** — [`font_set.d`][sp-fontset], [`shaping_c.c`][sp-shaping].
- Siblings: [`./crossfont.md`](./crossfont.md),
  [`./harfbuzz.md`](./harfbuzz.md), [`./freetype.md`](./freetype.md),
  [`./fontconfig.md`](./fontconfig.md), [`./coretext.md`](./coretext.md).

<!-- References -->

[repo]: https://github.com/ghostty-org/ghostty
[license]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/LICENSE
[backend]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/backend.zig
[face-zig]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/face.zig
[collection]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/Collection.zig
[deferred]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/DeferredFace.zig
[resolver]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/CodepointResolver.zig
[cpmap]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/CodepointMap.zig
[grid]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/SharedGrid.zig
[gridset]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/SharedGridSet.zig
[discovery]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/discovery.zig
[ft-face]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/face/freetype.zig
[ct-face]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/face/coretext.zig
[atlas]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/Atlas.zig
[glyph]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/Glyph.zig
[metrics]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/Metrics.zig
[glyf-raster]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/glyf_rasterize.zig
[glyf]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/opentype/glyf.zig
[nerd]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/nerd_font_attributes.zig
[shape-zig]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/shape.zig
[run]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/shaper/run.zig
[hb-shaper]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/shaper/harfbuzz.zig
[ct-shaper]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/shaper/coretext.zig
[noop]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/shaper/noop.zig
[feature]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/shaper/feature.zig
[cache]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/shaper/Cache.zig
[sprite-face]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/sprite/Face.zig
[sprite-readme]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/sprite/draw/README.md
[sprite-box]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/sprite/draw/box.zig
[sprite-powerline]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/font/sprite/draw/powerline.zig
[sp-fontset]: ../../../libs/raylib-text/src/sparkles/raylib_text/font_set.d
[sp-shaping]: ../../../libs/raylib-text/src/sparkles/raylib_text/shaping_c.c
