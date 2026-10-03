# Font libraries

**Status:** complete — 34 subjects surveyed across C, C++, Zig, Rust, C#, Go,
JavaScript and Python. The synthesis in [`comparison.md`](./comparison.md)
closes each research question with a verdict; the shared vocabulary is
[`concepts.md`](./concepts.md).
**Last reviewed:** October 3, 2026

`sparkles` is about to replace its font stack. Today a terminal, a code viewer
and their Android builds draw text through `sparkles:raylib-text`: a raylib
(stb_truetype) atlas for single codepoints beside a FreeType and HarfBuzz C shim
for clusters and fallbacks, added as a spike for notcurses features. A new
programmer-font explorer app needs everything that stack lacks: variable fonts,
feature control, every metric set, outlines, inspection and real font
discovery. The decision is to write `sparkles:font` from scratch, in D wherever
D is the better place for the code. This survey is the evidence base for that
library's API.

## The questions this survey answers

Every subject was read for the same six questions, under a fixed seven-part
analysis spine, so the [comparison](./comparison.md) can set like against like.

| #   | Question                                                                                                     | Verdict                                                                                                |
| --- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ |
| RQ1 | What layering do mature libraries converge on, and where do they put allocation, lifetime and thread-safety? | [Five objects, caches beside them](./comparison.md#rq1-layering-and-ownership)                         |
| RQ2 | Is a from-scratch rasterizer feasible on the CPU or in GPU compute, and what does quality cost?              | [Go for a D CPU rasterizer; no-go for D shaping; defer GPU](./comparison.md#rq2-rasterization-and-gpu) |
| RQ3 | How do variation coordinates flow through shaping and rasterization?                                         | [One normalized vector per instance, everywhere](./comparison.md#rq3-variation-and-shaping)            |
| RQ4 | How are discovery, matching and fallback done?                                                               | [Cached index, coverage-pruned fallback list](./comparison.md#rq4-discovery-matching-and-fallback)     |
| RQ5 | What must a font inspector expose?                                                                           | [Reflectable tables plus enumerations](./comparison.md#rq5-what-an-inspector-must-expose)              |
| RQ6 | How are glyph outlines exposed, and in what units?                                                           | [Sink and segment array over one decoder, font units](./comparison.md#rq6-outline-access)              |

## How this survey was scoped

The app this library serves was scoped first, in a structured interview whose
product research covered the font managers, inspectors and comparison tools
designers use today. Their features fell into three groups, and that grouping
decided which libraries to read:

- **Inspection** — tables, metadata, `OpenType` features with toggles, glyph
  maps, variation axes, language coverage, metrics reports, CSS export. Every
  browser inspector does this client-side on a JavaScript parser, which is why
  [opentype.js](./opentype-js.md), [fontkit](./fontkit.md) and
  [lib-font](./lib-font.md) are here.
- **Preview and comparison** — custom text at any size, waterfalls, synced
  multi-font cards, metric overlays. This needs shaping, variation and
  rasterization: the C cores, the Rust stacks and the platform stacks.
- **Management** — folders, tags, activation, cloud catalogs. Discovery and
  matching are in scope ([fontconfig](./fontconfig.md), [fontdb](./fontdb.md),
  [font-kit](./font-kit.md)); activation and catalogs are not.

The explorer's own identity is programming and terminal fonts, which is why
the two terminal stacks, [Ghostty](./ghostty.md) and [crossfont](./crossfont.md),
are read as closely as the general-purpose libraries.

## Master catalog

| Subject                                         | Ecosystem   | Category                     | What it teaches                                                                                                |
| ----------------------------------------------- | ----------- | ---------------------------- | -------------------------------------------------------------------------------------------------------------- |
| [FreeType](./freetype.md)                       | C           | C core                       | Face, size and slot as layers; a shared mutable slot is why a face is single-threaded.                         |
| [HarfBuzz](./harfbuzz.md)                       | C++ / C ABI | C core, shaper               | The face as a `tag → bytes` function; variation on the sized font; callback sinks for outlines and paint.      |
| [Fontconfig](./fontconfig.md)                   | C           | font database                | The fallback list as the primary API, pruned by coverage; lexicographic scoring over a priority table.         |
| [Pango](./pango.md)                             | C / GLib    | layout engine                | A fontset is the unit of fallback; scale the shaper so its output is the layout unit.                          |
| [stb_truetype](./stb-truetype.md)               | C           | parser, rasterizer           | Offsets over a borrowed buffer, ~700-line rasterizer, and the source of every raylib text limit in `sparkles`. |
| [msdfgen](./msdfgen.md)                         | C++         | rasterizer                   | Owning bitmap versus borrowed section; a path object for random access; units as an explicit enum.             |
| [Slug](./slug.md)                               | C++ / GPU   | rasterizer                   | Exact per-pixel outline evaluation on the GPU, and why it costs too much at terminal sizes.                    |
| [Skia](./skia.md)                               | C++         | platform text stack          | One canonical glyph-cache key; the rasterizer as a private seam; metric validity flags.                        |
| [Core Text](./coretext.md)                      | C / Apple   | platform text stack          | One descriptor type for query and result; per-string fallback from the OS.                                     |
| [DirectWrite](./directwrite.md)                 | C++ COM     | platform text stack          | A variation instance is a new face; fallback returns a run length and a scale.                                 |
| [Ghostty](./ghostty.md)                         | Zig         | terminal font stack          | Storage, resolution policy and cache as three owners; deferred faces; box drawing as a synthetic face.         |
| [crossfont](./crossfont.md)                     | Rust        | terminal font stack          | A terminal's metric set is seven numbers; charset-pruned, lazily opened fallback.                              |
| [Fontations](./fontations.md)                   | Rust        | parser                       | Generated zero-copy table readers; coordinates passed, never stored; differential testing against FreeType.    |
| [ttf-parser](./ttf-parser.md)                   | Rust        | parser                       | A zero-allocation face on the stack, and the regret of mutable variation state.                                |
| [rustybuzz](./rustybuzz.md)                     | Rust        | shaper                       | A HarfBuzz port is ~17 KLOC, and tracking upstream is what ended it.                                           |
| [Allsorts](./allsorts.md)                       | Rust        | parser, shaper               | An independent shaper lands at the same ~17 KLOC; partial results with the first error.                        |
| [swash](./swash.md)                             | Rust        | shaper, rasterizer           | Cluster-shaped shaping output and a raster source order for colour versus outline glyphs.                      |
| [fontdb](./fontdb.md)                           | Rust        | font database                | A CSS-matching in-memory database with no per-codepoint fallback.                                              |
| [cosmic-text](./cosmic-text.md)                 | Rust        | layout engine                | One `&mut` context is simple and thread-confining; the raster cache key to copy.                               |
| [Parley + Fontique](./parley.md)                | Rust        | layout engine, font database | Two contexts, long-lived and scratch; `Synthesis` as data; fallback probed by script sample.                   |
| [fontdue](./fontdue.md)                         | Rust        | rasterizer                   | The fill core is ~200 lines; cached geometry is where the speed is.                                            |
| [ab_glyph](./ab-glyph.md)                       | Rust        | rasterizer                   | A by-value scaled-font wrapper; outlines as data; px-per-em as the only honest size unit.                      |
| [Vello](./vello.md)                             | Rust / WGSL | rasterizer (GPU compute)     | The renderer contract is `(blob, index, size, coords, hint) + [glyph, x, y]`; 5.4 KLOC of shaders.             |
| [glyphon](./glyphon.md)                         | Rust / wgpu | rasterizer (GPU atlas)       | Mask and colour atlases, generation-stamped eviction, one instanced draw.                                      |
| [font-kit](./font-kit.md)                       | Rust        | platform adapter, database   | A serializable `{path or bytes, index}` handle between discovery and loading; CSS §5.2 in ~130 lines.          |
| [SixLabors.Fonts](./sixlabors-fonts.md)         | C#          | layout engine                | Two-level loading for listing versus rendering; an outline sink that can refuse.                               |
| [Typography](./typography.md)                   | C#          | parser, shaper               | A managed TrueType interpreter is ~2,100 lines and incomplete.                                                 |
| [SharpFont](./sharpfont.md)                     | C#          | managed binding              | Hand-mirrored structs are a silent-corruption contract; ImportC removes that class of bug.                     |
| [go-text/typesetting](./go-text-typesetting.md) | Go          | layout engine                | The most complete from-scratch managed stack; `Footprint` is the explorer's list row.                          |
| [x/image/font](./golang-image-font.md)          | Go          | parser, rasterizer           | Caller-owned scratch per call; outlines as a flat segment array.                                               |
| [opentype.js](./opentype-js.md)                 | JavaScript  | parser                       | Reflective table objects make an inspector free; enumerable `GSUB` records.                                    |
| [fontkit](./fontkit.md)                         | JavaScript  | parser, shaper               | Declarative table schemas; WOFF2 behind the same font interface.                                               |
| [lib-font](./lib-font.md)                       | JavaScript  | parser                       | The enumeration API an inspector wants: scripts, language systems, features.                                   |
| [fontTools](./fonttools.md)                     | Python      | parser, toolkit              | The table schema as data; the canonical pen protocol for outlines.                                             |

## Taxonomy: layers covered

Which of the six layers each subject implements itself. A blank cell means the
subject delegates the layer or does without it; the deep-dive's spine says
which.

| Subject                                         | Parse | Discover | Match / fallback | Shape | Outline | Raster |
| ----------------------------------------------- | :---: | :------: | :--------------: | :---: | :-----: | :----: |
| [FreeType](./freetype.md)                       |   ✓   |          |                  |       |    ✓    |   ✓    |
| [HarfBuzz](./harfbuzz.md)                       |   ✓   |          |                  |   ✓   |    ✓    |        |
| [Fontconfig](./fontconfig.md)                   |       |    ✓     |        ✓         |       |         |        |
| [Pango](./pango.md)                             |       |          |        ✓         |   ✓   |         |        |
| [stb_truetype](./stb-truetype.md)               |   ✓   |          |                  |       |    ✓    |   ✓    |
| [msdfgen](./msdfgen.md)                         |       |          |                  |       |    ✓    |   ✓    |
| [Slug](./slug.md)                               |       |          |                  |       |    ✓    |   ✓    |
| [Skia](./skia.md)                               |   ✓   |    ✓     |        ✓         |   ✓   |    ✓    |   ✓    |
| [Core Text](./coretext.md)                      |   ✓   |    ✓     |        ✓         |   ✓   |    ✓    |   ✓    |
| [DirectWrite](./directwrite.md)                 |   ✓   |    ✓     |        ✓         |   ✓   |    ✓    |   ✓    |
| [Ghostty](./ghostty.md)                         | part  |    ✓     |        ✓         |   ✓   |         |   ✓    |
| [crossfont](./crossfont.md)                     |       |    ✓     |        ✓         |       |         |   ✓    |
| [Fontations](./fontations.md)                   |   ✓   |          |                  |       |    ✓    |        |
| [ttf-parser](./ttf-parser.md)                   |   ✓   |          |                  |       |    ✓    |        |
| [rustybuzz](./rustybuzz.md)                     |       |          |                  |   ✓   |         |        |
| [Allsorts](./allsorts.md)                       |   ✓   |          |                  |   ✓   |    ✓    |        |
| [swash](./swash.md)                             |   ✓   |          |                  |   ✓   |    ✓    |   ✓    |
| [fontdb](./fontdb.md)                           |       |    ✓     |      match       |       |         |        |
| [cosmic-text](./cosmic-text.md)                 |       |    ✓     |        ✓         |   ✓   |    ✓    |   ✓    |
| [Parley + Fontique](./parley.md)                |       |    ✓     |        ✓         |   ✓   |         |        |
| [fontdue](./fontdue.md)                         |       |          |                  |       |         |   ✓    |
| [ab_glyph](./ab-glyph.md)                       |       |          |                  |       |    ✓    |   ✓    |
| [Vello](./vello.md)                             |       |          |                  |       |    ✓    |   ✓    |
| [glyphon](./glyphon.md)                         |       |          |                  |       |         | atlas  |
| [font-kit](./font-kit.md)                       |       |    ✓     |        ✓         |       |    ✓    |   ✓    |
| [SixLabors.Fonts](./sixlabors-fonts.md)         |   ✓   |    ✓     |        ✓         |   ✓   |    ✓    |        |
| [Typography](./typography.md)                   |   ✓   |    ✓     |        ✓         |   ✓   |    ✓    |        |
| [SharpFont](./sharpfont.md)                     | bind  |          |                  |       |  bind   |  bind  |
| [go-text/typesetting](./go-text-typesetting.md) |   ✓   |    ✓     |        ✓         |   ✓   |    ✓    |        |
| [x/image/font](./golang-image-font.md)          |   ✓   |          |                  |       |    ✓    |   ✓    |
| [opentype.js](./opentype-js.md)                 |   ✓   |          |                  | part  |    ✓    |        |
| [fontkit](./fontkit.md)                         |   ✓   |          |                  |   ✓   |    ✓    |        |
| [lib-font](./lib-font.md)                       |   ✓   |          |                  |       |         |        |
| [fontTools](./fonttools.md)                     |   ✓   |          |                  |       |    ✓    |        |

Only the three platform stacks cover all six. Every from-scratch stack outside
them stops before one layer, and the layer most often skipped is rasterization
(managed layout engines) or shaping (rasterizers and parsers).

## Taxonomy: where variation coordinates live

The decision RQ3 turns on, re-cut across the subjects that support variation.

| Placement                                | Subjects                                                                                                                                               |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| mutable state on the face                | [ttf-parser](./ttf-parser.md), [ab_glyph](./ab-glyph.md), [FreeType](./freetype.md) (`FT_Set_Var_Design_Coordinates`)                                  |
| on the sized font / instance object      | [HarfBuzz](./harfbuzz.md), [Core Text](./coretext.md), [Pango](./pango.md), [Skia](./skia.md) (`SkFontArguments`), [go-text](./go-text-typesetting.md) |
| instance is a new face                   | [DirectWrite](./directwrite.md), [SixLabors.Fonts](./sixlabors-fonts.md) (`CreateVariationInstance`)                                                   |
| passed per call as a borrowed location   | [Fontations](./fontations.md), [Vello](./vello.md), [Parley](./parley.md)                                                                              |
| applied by rewriting tables              | [fontTools](./fonttools.md) (`varLib.instancer`)                                                                                                       |
| parsed but not applied, or not supported | [Typography](./typography.md), [fontdue](./fontdue.md), [stb_truetype](./stb-truetype.md), [crossfont](./crossfont.md)                                 |

## Milestones

Dates as given in the deep-dives and their cited sources; the two OpenType
specification releases are from the [OpenType version history][ot-changes].

| Year | Milestone                                                                                                                                                 |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2005 | Loop and Blinn publish resolution-independent curve rendering on the GPU, the ancestor of [Slug](./slug.md).                                              |
| 2007 | Valve's single-channel signed distance fields for text.                                                                                                   |
| 2014 | [msdfgen](./msdfgen.md) begins as Viktor Chlumský's master's thesis: multi-channel fields keep corners.                                                   |
| 2016 | Variable fonts arrive in OpenType 1.8 (September); [crossfont](./crossfont.md) starts as Alacritty's font stack.                                          |
| 2017 | Lengyel's [Slug](./slug.md) paper in JCGT.                                                                                                                |
| 2019 | [Allsorts](./allsorts.md) ships inside the Prince typesetter; [SharpFont](./sharpfont.md)'s last commit.                                                  |
| 2021 | `COLR` version 1 colour fonts are specified in OpenType 1.9 (December).                                                                                   |
| 2023 | [Typography](./typography.md)'s last commit.                                                                                                              |
| 2026 | At this survey's pins, [rustybuzz](./rustybuzz.md) is archived in favour of HarfRust, and [Fontations](./fontations.md) backs Skia's font path in Chrome. |

## Runnable examples

Two programs back the comparison's measured claims. Both talk to HarfBuzz
through hand-declared `extern(C)` prototypes with no C shim, and both skip
cleanly when no font can be found.

- [`harfbuzz-shape-features.d`](./examples/harfbuzz-shape-features.d) —
  HarfBuzz's object layers, the feature inventory an inspector lists, `fvar`
  axes, and the same text shaped with `calt` and `liga` on and off.
- [`outline-sink-raster.d`](./examples/outline-sink-raster.d) — the outline
  sink, a variation reaching both advances and outlines, and a 71-line
  signed-area rasterizer rendering the result.
- [`ligature-cells.d`](./examples/ligature-cells.d) — 160 programming
  ligatures shaped on and off: whether glyph count or advances leave the cell
  grid, and how far ligature ink reaches past its own cell.

```bash
dub run --single docs/research/font-libraries/examples/outline-sink-raster.d -- /path/to/font.ttf g
```

## Suggested reading paths

- **Designing `sparkles:font`.** [`comparison.md`](./comparison.md) top to
  bottom, then [HarfBuzz](./harfbuzz.md), [Fontations](./fontations.md),
  [Ghostty](./ghostty.md) and [fontconfig](./fontconfig.md) in that order.
- **The terminal path.** [Ghostty](./ghostty.md), [crossfont](./crossfont.md),
  [glyphon](./glyphon.md), then [`concepts.md` § units](./concepts.md#units-and-coordinate-spaces).
- **Writing a rasterizer.** [stb_truetype](./stb-truetype.md),
  [fontdue](./fontdue.md), [ab_glyph](./ab-glyph.md), the
  [outline example](./examples/outline-sink-raster.d), then [Vello](./vello.md)
  and [Slug](./slug.md) for the GPU side.
- **Building the inspector.** [lib-font](./lib-font.md),
  [opentype.js](./opentype-js.md), [fontTools](./fonttools.md), then
  [comparison § RQ5](./comparison.md#rq5-what-an-inspector-must-expose).
- **Deciding whether to own shaping.** [rustybuzz](./rustybuzz.md),
  [Allsorts](./allsorts.md), [go-text/typesetting](./go-text-typesetting.md),
  [SixLabors.Fonts](./sixlabors-fonts.md).

## Sources

Every deep-dive cites its subject at a pinned commit, or for the three
closed-source subjects ([Core Text](./coretext.md),
[DirectWrite](./directwrite.md), [Slug](./slug.md)) the vendor documentation
and paper with retrieval dates. Shared references:

- [OpenType specification][ot-spec].
- [CSS Fonts Module Level 4][css-fonts].
- [OpenType version history][ot-changes] — release dates of 1.8 and 1.9.

<!-- References -->

[ot-spec]: https://learn.microsoft.com/en-us/typography/opentype/spec/
[css-fonts]: https://www.w3.org/TR/css-fonts-4/
[ot-changes]: https://learn.microsoft.com/en-us/typography/opentype/spec/changes
