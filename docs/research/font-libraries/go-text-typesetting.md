# go-text/typesetting (Go)

The most complete from-scratch managed font stack surveyed: a generated OpenType parser, a line-for-line HarfBuzz port, bidi and script segmentation, and a pure-Go font index with fontconfig-style substitution — everything except the rasterizer.

| Field            | Value                                                                                                                                           |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | Go (`go 1.19` in [`go.mod`][gomod])                                                                                                             |
| License          | Unlicense OR BSD-3-Clause ([`LICENSE`][license]); the `harfbuzz` package is MIT, inheriting HarfBuzz's notice ([`harfbuzz/LICENSE`][hblicense]) |
| Repository       | [`go-text/typesetting`][repo]                                                                                                                   |
| Documentation    | [pkg.go.dev][docs]; package READMEs ([`font/README.md`][fontreadme], [`fontscan/readme.md`][scanreadme])                                        |
| Category         | layout engine (managed, pure Go)                                                                                                                |
| Layer(s) covered | parse · discover · match/fallback · shape · outline · layout (no raster)                                                                        |
| Pinned revision  | `64922d2b48df3ea2ebae4733781b7c0d0c00d91b` (2026-10-01)                                                                                         |

## Overview

### What it solves

`go-text/typesetting` is the shared text engine of three Go GUI toolkits — the README names [Fyne](https://fyne.io), Gio and Ebitengine ([`README.md`][readme]). It parses TrueType, CFF, CFF2, WOFF and dfont; shapes with a HarfBuzz port that includes AAT `morx`/`kerx`/`trak`; segments text by bidi level, script, vertical orientation and face; wraps lines; and finds fonts on disk with a cached index and a 4,369-line substitution table lifted from fontconfig ([`fontscan/substitutions_table.go`][substable]). It emits glyph data (outlines, bitmaps, SVG documents, COLR paint graphs) and stops: rasterization lives in consumers (Gio's GPU path renderer) or the separate `go-text/render` repository.

### Design philosophy

> The entry point of the library is the `FontMap` type. It should be created for each text shaping task and be filled either with system fonts (by calling `UseSystemFonts`) or with user-provided font files (using `AddFont`, `AddFace`), or both.
> To leverage all the system fonts, the first usage of `UseSystemFonts` triggers a scan which builds a font index. Its content is saved on disk so that subsequent usage by the same app are not slowed down by this step.

— [`fontscan/readme.md`][scanreadme]

The governance is unusual and API-shaping: core changes need "sign-off from at least 2 of these 3 maintainers", one each from Fyne, Gio and an independent developer ([`README.md`][readme]). The result is a conservative, toolkit-neutral surface: plain structs, `fixed.Int26_6` from `golang.org/x/image`, no rendering opinions.

## How it works

Four packages form the spine:

- **`font/opentype`** — `Loader` reads only the table directory ("header only, contents is processed on demand") and serves `RawTable(tag)`/`RawTableTo(tag, dst)`/`HasTable`/`Tables` ([`font/opentype/reader.go`][reader]). Under it, `font/opentype/tables` declares every table as a Go struct (`*_src.go`) from which a generator, `binarygen`, emits the bounds-checked decoders (`*_gen.go`) — 10,535 generated lines.
- **`font`** — `Font` ("one Opentype font file … safe for concurrent use") and `Face` ("a font with user-provided settings … NOT safe for concurrent use") ([`font/font.go`][font]).
- **`shaping`** — `Input` → `HarfbuzzShaper.Shape` → `Output`; `Segmenter.Split(Input, Fontmap) []Input`; line wrapping ([`shaping/input.go`][input], [`shaping/shaping.go`][shaping], [`shaping/output.go`][output]).
- **`fontscan`** — `FontMap`, implementing `shaping.Fontmap` by `ResolveFace(rune) *font.Face` ([`fontscan/fontmap.go`][fontmap]).

The `harfbuzz` package is "a direct port of the C/C++ library … based on upstream commit 5a31dd02f0b32de12336f72db9297bfe94cf0da1 (v12.3.0)" ([`harfbuzz/harfbuzz.go`][hbgo]).

## Analysis spine

### 1. Layering and ownership

Three layers with a clean concurrency split. `ot.Loader` (bytes, lazy) → `font.Font` (decoded tables, immutable, shareable) → `font.Face` (`*Font` + variation `coords` + `xPpem`/`yPpem` + four caches: glyph extents, H/V advances for variable fonts without `HVAR`/`VVAR`, and a two-sided cmap cache) ([`font/font.go`][font]). Shaping adds `harfbuzz.Font`, a wrapper holding lookup accelerators and `XScale`/`YScale`, documented as depending only on the `*font.Font` "so a Font object is suitable for caching" ([`harfbuzz/font.go`][hbfont]). There is no scaled-font object at the `font` layer: `Face` metrics are in font units; scale is an `Input.Size` applied by the shaper.

Ownership is the GC's. `NewFont` decodes every table into Go values and keeps no reference to the loader or file — `fontscan` opens a file, builds the `Font`, and `defer file.Close()`s ([`fontscan/footprint.go`][footprint]). Errors are Go `error`s, but only `cmap`, `head` and `maxp` are fatal: "We considerer all the following tables as optional … Ignoring the errors on `RawTable` is OK" ([`font/font.go`][font]). That tolerance is a deliberate production choice for UI toolkits that cannot reject a user's font.

One sharp edge, as read at the pinned revision: `HarfbuzzShaper` caches `harfbuzz.Font` in an LRU keyed by `*font.Font` ([`shaping/lru.go`][lru]), but `harfbuzz.NewFont(input.Face)` stores the `*font.Face` it was built from, and a cache hit does not rebind it ([`shaping/shaping.go`][shaping]). Variation coordinates are read through that stored face (`font.face.Coords()`), so two `Face`s with different coordinates over one `Font` share whichever face populated the cache.

### 2. Face loading and table access

`font.ParseTTF(Resource)` and `font.ParseTTC(Resource) ([]*Face, error)` are the convenience doors; `Resource` is `Read`+`ReadAt`+`Seek` ([`font/font.go`][font]). WOFF tables are inflated on read (`zLength` in `tableSection`). Raw access survives at the `Loader` (`RawTable`), not at `Font`. For enumeration, `font.Describe(ld, buffer)` reads only the tables needed for family and `Aspect`, with a reusable buffer — "loading only the mininum tables required" ([`font/metadata.go`][metadata]). `Font` exposes the parsed layout tables as public fields (`GSUB`, `GPOS`, `GDEF`, `Morx`, `Kern`, `Kerx`, `Trak`, `Feat`, `STAT`, `COLR`, `CPAL`, `Cmap`), which is an inspector's dream: the parsed model is the API.

### 3. Shaping

`Input{Text []rune, RunStart, RunEnd, Direction, Face, FontFeatures, Size fixed.Int26_6, Script, Language, Level}`; the full `Text` is context, only `[RunStart:RunEnd]` is shaped ([`shaping/input.go`][input]). Features are `FontFeature{Tag, Value}`, applied globally to the run. `HarfbuzzShaper.Shape` fills a reused `harfbuzz.Buffer`, sets `XScale = Size.Ceil() << 6` — **integer pixel sizes only**; fractional sizes are rounded up before shaping — and returns `Output{Advance, Size, Glyphs, LineBounds, GlyphBounds, Direction, Runes, Face, VisualIndex, Level}` ([`shaping/shaping.go`][shaping]). Per glyph: `GlyphID`, `Advance`, `XOffset`/`YOffset`, ink `XBearing`/`YBearing`/`Width`/`Height`, and cluster mapping `TextIndex()`/`RunesCount()`/`GlyphsCount()` — all in `fixed.Int26_6` pixels ([`shaping/output.go`][output]). `ShapeNoExtents` skips ink bounds for wrapping passes.

Size of the port, as evidence for a D shaper:

```text
$ find harfbuzz -name '*.go' ! -name '*_test.go' | xargs wc -l | tail -1
 22798 total
```

Of those, 6,836 lines are Ragel-generated machines and Unicode tables (`*_machine.go`, `*_table.go`). A complete OpenType+AAT shaper, tracking HarfBuzz v12.3.0, is therefore ~16,000 lines of hand-ported logic in a GC language.

### 4. Variation and instances

`Face.SetVariations([]Variation{Tag, Value})` takes **user (design) coordinates**, fills unspecified axes from `fvar` defaults, normalizes to `[-1, 1]` with clamping, applies `avar` segment maps, and stores F2Dot14 `[]VarCoord` via `SetCoords`, which resets the extents and advance caches ([`font/variations.go`][variations]):

```go
func (f *Font) NormalizeVariations(coords []float32) []VarCoord {
	// Axis normalization is a two-stage process.  First we normalize
	// based on the [min,def,max] values for the axis to be [-1,0,1].
	// Then, if there's an `avar' table, we renormalize this range.
	normalized := f.fvar.normalizeCoordinates(coords)
	// now applying 'avar'
	for i, av := range f.avar.AxisSegmentMaps {
		normalized[i] = av.Map(normalized[i])
	}
	return normalized
}
```

The same `Face.coords` reach every consumer: `gvar` deltas on `glyf` points, CFF2 blends, `HVAR`/`VVAR` advances, `MVAR` font metrics (`getPositionCommon(tag, f.coords)`), and GPOS/GDEF variation stores in the shaper (`font.face.Coords()` in `harfbuzz/font.go`). Named instances exist only as an identifier: `FontID.Instance` is "1 + the instance index", serialized in the index, but no scan expands instances and no API selects one ([`font/font.go`][font]). `STAT` is parsed into `Font.STAT` and not used for matching.

### 5. Rasterization and outlines

**No rasterizer, no hinter** (`fpgm`/`prep` are never read). Glyph content is a closed sum type, `GlyphData`, implemented by `GlyphOutline`, `GlyphBitmap`, `GlyphSVG`, `GlyphColor` ([`font/renderer.go`][renderer]). `Face.GlyphData(gid)` tries COLR first, then `sbix`/`CBDT`/`EBDT`/`BDAT`, then `SVG `, then outlines; the typed `GlyphDataOutline` etc. pick one source.

`GlyphOutline` is `Segments []Segment`, each `{Op MoveTo|LineTo|QuadTo|CubeTo, Args [3]SegmentPoint}` with `float32` coordinates "expressed in fonts units" and "The Y axis increases up" ([`font/opentype/opentype.go`][otgo]) — the `x/image/font/sfnt` shape, minus scaling (see [golang/image font](./golang-image-font.md)). `GlyphBitmap` carries undecoded `Data` plus a `Format` (`BlackAndWhite`, `PNG`, `JPG`, `TIFF`, `BlackAndWhiteByteAligned`); bitmap strike selection uses `Face.SetPpem`. `GlyphSVG` hands back the decompressed shared document, a resolved `ViewBox`, and the mandatory fallback outline. `GlyphColor` is the raw COLRv1 `PaintTable` graph; interpreting it is the caller's job. `GlyphOutline.Sideways(yOffset)` rotates for vertical text.

Gio is the reference consumer: it scales `Segments` by `ppem / Upem()`, flips Y, and emits relative path commands for its GPU stroker/filler; it decodes `PNG`/`JPG`/`TIFF` bitmaps into an image cache keyed by a packed `(ppem, faceIdx, gid)` glyph ID, and silently skips `GlyphColor` and `BlackAndWhite` ([Gio `text/gotext.go`][gio]).

### 6. Metrics and measurement

All font-level values are `float32` font units. `Face.FontHExtents()` returns `FontExtents{Ascender, Descender, LineGap}` with a two-step ladder: `OS/2` `sTypo*` when `USE_TYPO_METRICS` is set, else `hhea` — no `usWin*` fallback — each plus its `MVAR` delta (`hasc`, `hdsc`, `hlgp`) ([`font/metrics.go`][metrics]). `Face.LineMetric(UnderlinePosition|…|CapHeight|XHeight)` covers `post`/`OS/2` values, with `MVAR` applied. Per glyph: `HorizontalAdvance(gid)` (with `HVAR`, or outline phantom points when `HVAR` is absent), `GlyphExtents` in font units, `GetGlyphContourPoint`, `GlyphName`. `Font.IsMonospace()` ports fontconfig's heuristic — `post.isFixedPitch`, else all non-zero `hmtx` advances within ~3% ([`font/metadata.go`][metadata]).

### 7. Discovery, matching and fallback

`DefaultFontDirectories` lists per-OS roots (Windows, macOS including `MobileAsset` font dirs, Linux/BSD XDG paths plus directories parsed from fontconfig's XML config **in pure Go**, Android `/system/fonts`, iOS) ([`fontscan/scan.go`][scan], [`fontscan/fontconfig.go`][fcgo]). The scan builds one `Footprint{Location, Family, Runes, Scripts, Langs, Aspect}` per face — coverage from `cmap`, scripts and fontconfig-style language sets derived from coverage, `Aspect{Style, Weight, Stretch}` from `OS/2`/`head`/`name`, refined by parsing style strings ([`fontscan/footprint.go`][footprint], [`font/metadata.go`][metadata]). The index is serialized to `os.UserCacheDir()` and revalidated per file by modification time; the readme measures the cold scan at "between 0.2 and 0.5 sec on a laptop".

Matching is CSS-shaped. `SetQuery(Query{Families, Aspect})` expands families through substitution rules (`familyEquals`, `familyContains`, insert-before/after/replace, strong vs weak) ([`fontscan/substitutions.go`][subs]), sorts candidates — strong before weak; among weak, faces covering the current script first; ties broken user-provided, then non-mono, then TrueType over CFF ([`fontscan/match.go`][match]) — and prunes by CSS stretch → style → weight rules. `ResolveFace(r)` then walks four tiers documented in its comment: exact families; substituted families plus script-covering faces; user-added faces; every face covering `SetScript`'s script ignoring aspect; finally an arbitrary face, never `nil` ([`fontscan/fontmap.go`][fontmap]). Results are memoized in a 4,096-entry rune LRU keyed by `(query, script, rune)`. `Segmenter.Split` runs bidi → script (with a paired-delimiter stack for `Common`) → language enforcement → vertical orientation → face, calling `SetScript` before `ResolveFace` when the map implements `FontmapScript` ([`shaping/input.go`][input]).

## What it teaches `sparkles:font`

- **Generate the table decoders from declared layouts.** `hhea_vhea_src.go` is a 20-line struct; `binarygen` writes the bounds-checked reader. D does this at compile time with `static foreach` over struct fields — no generator, same safety.
- **Split `Font` (immutable, shared) from `Face` (coords + ppem + caches, single-thread).** That is the right concurrency seam for a terminal with a render thread. Key any shaper cache on the `Face` state, not the `Font` pointer — the LRU above shows why.
- **A `Footprint` is the font browser's row.** Family, `Aspect`, rune set, script set, language set and location, serialized with mtime validation, is exactly what the explorer lists and filters on before loading anything.
- **Glyph data as a sum type.** `GlyphOutline | GlyphBitmap | GlyphSVG | GlyphColor` maps directly to a D `SumType`; outline segments in font units leave scaling and hinting policy to the rasterizer.
- **Fallback = ordered tiers + per-rune memo, driven by a segmenter.** `ResolveFace(rune)` behind a `(query, script, rune)` LRU, fed by script-segmented runs, is a complete fallback design in under 700 lines.
- **A D HarfBuzz port is ~16k hand-written lines.** Feasible, but ImportC HarfBuzz remains cheaper unless managed debuggability is a goal.

## Strengths

- One language end-to-end; production-proven in three toolkits.
- Shaper tracks a named HarfBuzz release, including AAT.
- Parsed layout tables are public, inspector-friendly fields.
- Font discovery needs no native library on any OS, including fontconfig config parsing.

## Weaknesses

- No rasterizer, no hinting, no COLRv1 renderer — every consumer re-solves pixels.
- Shaping sizes are rounded up to whole pixels.
- Eager table decode per `Font`; raw table bytes only via the `Loader`.
- No named-instance selection; `STAT` unused; `usWin*` metrics ignored.
- Shaper font cache keyed by `*font.Font` while coordinates live on `*font.Face`.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                                   | Trade-off                                                      |
| ------------------------------------------- | ----------------------------------------------------------- | -------------------------------------------------------------- |
| Port HarfBuzz rather than bind it           | `CGO_ENABLED=0` builds, cross-compilation, one toolchain    | ~23k lines to keep in sync with upstream releases              |
| Generated decoders from struct declarations | Uniform bounds checks, low per-table effort                 | Extra build step; decoded copies instead of offsets over bytes |
| `Font` immutable, `Face` mutable            | Share parsed tables across goroutines; cache per user state | Callers must not share a `Face`; cache keys must include it    |
| Only `cmap`/`head`/`maxp` fatal             | UI toolkits must render whatever the user installed         | Silent zero-value tables hide corrupt fonts from an inspector  |
| On-disk footprint index                     | Sub-second cold scan becomes near-free warm start           | Cache invalidation by mtime; own serialization format          |
| fontconfig substitution table compiled in   | Same fallback behaviour on every OS without libfontconfig   | 4,369 lines of static data, frozen at extraction time          |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- Project — [`README.md`][readme], [`LICENSE`][license], [`go.mod`][gomod], [`font/README.md`][fontreadme].
- Parsing and faces — [`font/opentype/reader.go`][reader], [`font/opentype/opentype.go`][otgo], [`font/opentype/tables/hhea_vhea_src.go`][hheasrc], [`font/font.go`][font], [`font/metadata.go`][metadata], [`font/metrics.go`][metrics], [`font/variations.go`][variations], [`font/renderer.go`][renderer].
- Shaping — [`harfbuzz/harfbuzz.go`][hbgo], [`harfbuzz/font.go`][hbfont], [`harfbuzz/LICENSE`][hblicense], [`shaping/input.go`][input], [`shaping/shaping.go`][shaping], [`shaping/output.go`][output], [`shaping/lru.go`][lru].
- Discovery — [`fontscan/readme.md`][scanreadme], [`fontscan/fontmap.go`][fontmap], [`fontscan/match.go`][match], [`fontscan/footprint.go`][footprint], [`fontscan/scan.go`][scan], [`fontscan/fontconfig.go`][fcgo], [`fontscan/substitutions.go`][subs], [`fontscan/substitutions_table.go`][substable].
- Consumer — Gio [`text/gotext.go`][gio] at `3397eb8f4df4d59eab121f64975173ea0d3fdb38` (2026-09-29).
<!-- References -->

[repo]: https://github.com/go-text/typesetting
[docs]: https://pkg.go.dev/github.com/go-text/typesetting
[readme]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/README.md
[license]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/LICENSE
[gomod]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/go.mod
[fontreadme]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/font/README.md
[reader]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/font/opentype/reader.go
[otgo]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/font/opentype/opentype.go
[hheasrc]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/font/opentype/tables/hhea_vhea_src.go
[font]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/font/font.go
[metadata]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/font/metadata.go
[metrics]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/font/metrics.go
[variations]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/font/variations.go
[renderer]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/font/renderer.go
[hbgo]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/harfbuzz/harfbuzz.go
[hbfont]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/harfbuzz/font.go
[hblicense]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/harfbuzz/LICENSE
[input]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/shaping/input.go
[shaping]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/shaping/shaping.go
[output]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/shaping/output.go
[lru]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/shaping/lru.go
[scanreadme]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/fontscan/readme.md
[fontmap]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/fontscan/fontmap.go
[match]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/fontscan/match.go
[footprint]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/fontscan/footprint.go
[scan]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/fontscan/scan.go
[fcgo]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/fontscan/fontconfig.go
[subs]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/fontscan/substitutions.go
[substable]: https://github.com/go-text/typesetting/blob/64922d2b48df3ea2ebae4733781b7c0d0c00d91b/fontscan/substitutions_table.go
[gio]: https://git.sr.ht/~eliasnaur/gio/tree/3397eb8f4df4d59eab121f64975173ea0d3fdb38/item/text/gotext.go
