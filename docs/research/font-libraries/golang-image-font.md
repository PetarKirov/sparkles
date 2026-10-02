# golang.org/x/image/font (Go)

Go's semi-standard font layer: a five-method rasterized-face interface, a lazy concurrent-safe SFNT decoder that returns outlines as data, and a small signed-area scanline rasterizer — with no shaping, no variations, no hinting and no discovery.

| Field            | Value                                                                                 |
| ---------------- | ------------------------------------------------------------------------------------- |
| Language         | Go                                                                                    |
| License          | BSD-3-Clause ([`LICENSE`][license])                                                   |
| Repository       | [`golang/image`][repo] (`font`, `font/sfnt`, `font/opentype`, `vector`, `math/fixed`) |
| Documentation    | [pkg.go.dev/golang.org/x/image/font][docs]; package doc comments                      |
| Category         | parser                                                                                |
| Layer(s) covered | parse · outline · raster (no shaping, no discovery)                                   |
| Pinned revision  | `b06f1de3f4900ff828b8f114c37eb9ea10dfed90` (2026-09-08)                               |

## Overview

### What it solves

Drawing a string of runes into a Go `image.Image`. `font.Face` is the abstraction, `font.Drawer` walks a string through it, `sfnt.Font` decodes TrueType and CFF outlines, `opentype.NewFace` joins the decoder to the `vector.Rasterizer`. Bitmap faces (`plan9font`, `basicfont`) implement the same interface. Higher-level Go stacks — [go-text/typesetting](./go-text-typesetting.md) included — reuse its `fixed.Int26_6` and segment vocabulary.

### Design philosophy

> This package provides a low-level API and does not depend on vector rasterization packages. Glyphs are represented as vectors, not pixels.
> …
> Unlike the image.Image decoder functions (gif.Decode, jpeg.Decode and png.Decode) in Go's standard library, an sfnt.Font needs ongoing access to the TTF data (as a []byte or io.ReaderAt) after the sfnt.ParseXxx functions return.

— [`font/sfnt/sfnt.go`][sfnt]

The interface package is candid about what it leaves out. The last lines of `font.Face` are `// TODO: ColoredGlyph for various emoji?` and `// TODO: Ligatures? Shaping?`, and the file opens with `// TODO: who is responsible for caches (glyph images, glyph indices, kerns)? The Drawer or the Face?` ([`font/font.go`][fontgo]).

## How it works

```go
type Face interface {
	io.Closer
	Glyph(dot fixed.Point26_6, r rune) (
		dr image.Rectangle, mask image.Image, maskp image.Point, advance fixed.Int26_6, ok bool)
	GlyphBounds(r rune) (bounds fixed.Rectangle26_6, advance fixed.Int26_6, ok bool)
	GlyphAdvance(r rune) (advance fixed.Int26_6, ok bool)
	Kern(r0, r1 rune) fixed.Int26_6
	Metrics() Metrics
}
```

— [`font/font.go`][fontgo] (doc comments elided)

Every method is keyed by **`rune`, not glyph ID**: the interface assumes one rune is one glyph. `Glyph` returns `draw.DrawMask` arguments, so the face rasterizes at the sub-pixel `dot`; "The contents of the mask image returned by one Glyph call may change after the next Glyph call. Callers that want to cache the mask must make a copy." `Drawer{Dst, Src, Face, Dot}` loops runes: `Kern(prev, r)` → `Glyph` → `draw.DrawMask` → advance. Units are `fixed.Int26_6` pixels throughout — a signed `int32` with 6 fractional bits ([`math/fixed/fixed.go`][fixed]).

## Analysis spine

### 1. Layering and ownership

Three layers: `sfnt.Font` (unscaled, shareable) → `opentype.Face` (size × DPI × hinting, plus a private `sfnt.Buffer`, `vector.Rasterizer` and `image.Alpha` mask) → `font.Drawer` (string loop) ([`font/opentype/opentype.go`][opentype]). The concurrency contract is stated precisely: "All of the Font methods are safe to call concurrently, as long as each call has a different \*Buffer (or nil)"; a `Face` "is not safe for concurrent use". `sfnt.Buffer` is the scratch arena — byte view buffer, segment slice, compound-glyph stack, CFF interpreter — and `LoadGlyph`'s result "become[s] invalid to use once b is re-used" ([`font/sfnt/sfnt.go`][sfnt]). That is a borrow model expressed in comments: caller-owned scratch, results aliasing it. Bytes are borrowed too: a `[]byte` source is "assumed immutable while the sfnt.Font remains in use". Errors are sentinel `error` values (`ErrNotFound`, `ErrColoredGlyph`, ~40 private `errInvalid*`/`errUnsupported*`); the package declares itself "not hardened against malicious inputs" and caps sizes with constants (`maxCmapSegments = 20000`, `maxCompoundRecursionDepth = 8`, `maxGlyphDataLength = 64 * 1024`).

### 2. Face loading and table access

`sfnt.Parse([]byte)`, `ParseReaderAt(io.ReaderAt)`, `ParseCollection`/`ParseCollectionReaderAt` (TTC and Mac dfont) ([`font/sfnt/sfnt.go`][sfnt]). Initialization reads the directory and records `table{offset, length}` for a fixed set — `cmap head hhea hmtx maxp name OS/2 post glyf loca CFF CBLC GPOS kern` — caching scalars (ascent, descent, line gap, x-height, cap-height, slope, `unitsPerEm`) and the chosen `cmap` lookup function (formats 0, 4, 6, 12). Glyph data is read lazily per call. `cvt`, `fpgm`, `prep` and `gasp` are never read ("This implementation does not support hinting"); `CFF2`, `GSUB`, `GDEF`, `vmtx`, `fvar` are TODOs. There is **no raw table accessor**; only `Name(b, NameID)`, `PostTable()`, `GlyphName`, `NumGlyphs`, `UnitsPerEm`, `Bounds` and `WriteSourceTo`.

### 3. Shaping

**None.** `GPOS` is parsed only for pair kerning (`parseGPOSKern`, lookup type 2) with `kern` format 0 as fallback, exposed as `Font.Kern(b, x0, x1, ppem, hinting)` on glyph pairs ([`font/sfnt/gpos.go`][gpos]). No `GSUB`, ligatures, marks, cluster mapping or direction. At the face level `opentype.Face.Kern` passes `fixed.Int26_6(f.f.UnitsPerEm())` as `ppem` rather than the face scale, so at the pinned revision it returns the kern in design units reinterpreted as 26.6; the only test uses Go Regular, which "FIXME … there is no kerning", and expects 0 everywhere ([`font/opentype/opentype_test.go`][otest]).

### 4. Variation and instances

**Absent.** No `fvar`, `avar`, `gvar`, `HVAR` or CFF2 support; `LoadGlyphOptions` is an empty struct with `// TODO: transform / hinting.`. The `font` package's `Weight`, `Style` and `Stretch` enums are selection hints for face implementations, not axes.

### 5. Rasterization and outlines

`LoadGlyph(b, x GlyphIndex, ppem, opts) (Segments, error)` returns **outline as data**: `Segment{Op SegmentOpMoveTo|LineTo|QuadTo|CubeTo, Args [3]fixed.Point26_6}`, **scaled to `ppem` pixels with Y flipped down**. Font units are recovered by passing `ppem = fixed.Int26_6(f.UnitsPerEm())` with `HintingNone`. The scale is post-processing:

```go
	// Scale the segments. If we want to support hinting, we'll have to push
	// the scaling computation into the PostScript / TrueType specific glyph
	// loading code, such as the appendGlyfSegments body, since TrueType
	// hinting bytecode works on the scaled glyph vectors. For now, though,
	// it's simpler to scale as a post-processing step.
```

— [`font/sfnt/sfnt.go`][sfnt]

`glyf` (with compound transforms, [`truetype.go`][truetype]) and CFF Type 2 charstrings (a 1,426-line interpreter, [`postscript.go`][postscript]) are supported. Colour glyphs are refused: a font with `CBLC` and no `glyf`/`CFF` gets empty locations and `LoadGlyph` returns `ErrColoredGlyph`; `COLR`, `sbix`, `SVG ` are not recognized.

`font.Hinting` has three values (`HintingNone`, `HintingVertical`, `HintingFull`), but `HintingFull` only rounds advances, kerns and metrics to whole pixels (`(adv + 32) &^ 63`); outlines are never grid-fitted.

`vector.Rasterizer` is a signed-area accumulation rasterizer whose "design follows" Raph Levien's font-rs ([`vector/vector.go`][vector]). Curves are flattened into evenly spaced line segments, counted from a curvature estimate rather than by recursive subdivision; lines accumulate signed area into a float or fixed-point buffer; a prefix-sum pass produces coverage, with SSE4.1 assembly on amd64. Fixed-point is "roughly 1.25x faster" but overflows at scale, so faces wider or taller than `floatingPointMathThreshold = 512` px switch to floats. Size:

```text
$ find vector -name '*.go' ! -name '*_test.go' | xargs wc -l | tail -1
 1475 total
```

That is 1,475 lines of Go (436 of them the `gen.go` assembly generator) plus 1,019 lines of generated `acc_amd64.s`. Output is 8-bit grayscale coverage only: no LCD subpixel, no gamma, no stem darkening. `opentype.Face.Glyph` biases the outline by the fractional `dot` so sub-pixel positioning is exact, rasterizes into a reused `image.Alpha`, and caches nothing across glyphs.

### 6. Metrics and measurement

`font.Metrics{Height, Ascent, Descent, XHeight, CapHeight, CaretSlope}`, in 26.6 pixels at the requested `ppem` ([`font/font.go`][fontgo]). Sources: ascent, descent and line gap **from `hhea` only** — `OS/2` typo metrics, `USE_TYPO_METRICS` and `usWin*` are ignored; `Height = ascent − descent + lineGap`. `XHeight`/`CapHeight` come from `OS/2` v2+, and for older tables are measured from the bounds of `x` and `H` (`initOS2VersionBelow2`). `CaretSlope` is `hhea` rise/run. Per glyph: `GlyphBounds` (ink box plus advance) and `GlyphAdvance` from `hmtx`, honouring the short `numHMetrics` rule. `Drawer.BoundString`/`MeasureString` sum these per rune with pair kerning.

### 7. Discovery, matching and fallback

**Absent.** No enumeration, matching or fallback. The bundled `gofont` family (Go Regular, Mono, Bold, Italic, Medium, Smallcaps …) is shipped as `[]byte` constants for applications that need a font without discovery. Missing glyphs return `ok == false` from `Glyph`/`GlyphBounds`/`GlyphAdvance` — "This includes returning !ok for a fallback glyph (such as substituting a U+FFFD glyph or OpenType's .notdef glyph)" — which is the hook a caller would use to try another `Face`.

## What it teaches `sparkles:font`

- **Caller-owned scratch per call is a clean concurrency contract.** `Font` methods taking `*Buffer` make the parsed face lock-free and shareable; in D the same seam is a `scope ref` workspace argument, with `-preview=dip1000` enforcing what Go can only document.
- **Outlines as a flat segment array.** `Segments` (`[]{Op, [3]Point}`) is trivially cacheable, serializable and testable; offer it beside, or instead of, a callback sink.
- **Return outlines in font units and scale elsewhere.** `sfnt` bakes `ppem` and Y-flip into `LoadGlyph`, and its own comment concedes this blocks hinting. Keep design units at the parser boundary.
- **A ~1.5k-line signed-area rasterizer is the floor.** It produces good grayscale AA; LCD, gamma and hinting are where the remaining cost lives.
- **Do not key a face by rune.** `Face.Glyph(dot, rune)` cannot express ligatures or fallback; key by glyph ID.

## Strengths

- Small, readable, BSD-licensed, pure Go with optional assembly.
- Lazy table reads over a borrowed `[]byte` or `io.ReaderAt`; concurrent-safe `Font`.
- Precise sub-pixel positioning in `opentype.Face.Glyph`.
- Sanity limits are explicit constants.

## Weaknesses

- No shaping, no `GSUB`, no variations, no hinting, no colour glyphs, no CFF2.
- Rune-keyed `Face` API; masks valid only until the next call.
- `hhea`-only vertical metrics.
- `opentype.Face.Kern` scales with the wrong `ppem` at the pinned revision.
- "Not hardened against malicious inputs."

## Key design decisions and trade-offs

| Decision                               | Rationale                                                | Trade-off                                            |
| -------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------- |
| `Face` keyed by rune, returning a mask | Simplest possible `image/draw` integration               | No shaping or ligatures; one rune = one glyph        |
| `*Buffer` scratch per call             | Concurrent `Font`, low allocation                        | Results alias the buffer; lifetimes in comments only |
| Keep source bytes, read tables lazily  | Cheap open; no copy of glyph data                        | Source must stay immutable and open                  |
| Scale outlines inside `LoadGlyph`      | One call gives device-space segments                     | Hinting cannot be added without restructuring        |
| Signed-area accumulation raster        | Fast, simple, SIMD-friendly; float fallback above 512 px | Grayscale only; no LCD, gamma or hinting             |
| `fixed.Int26_6` everywhere             | Matches FreeType conventions; exact sub-pixel math       | Range ±33M px; conversion noise at API edges         |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- Interface — [`font/font.go`][fontgo], [`math/fixed/fixed.go`][fixed].
- Decoder — [`font/sfnt/sfnt.go`][sfnt], [`font/sfnt/cmap.go`][cmap], [`font/sfnt/gpos.go`][gpos], [`font/sfnt/truetype.go`][truetype], [`font/sfnt/postscript.go`][postscript].
- Face and rasterizer — [`font/opentype/opentype.go`][opentype], [`font/opentype/opentype_test.go`][otest], [`vector/vector.go`][vector], [`vector/raster_fixed.go`][rfixed], [`vector/raster_floating.go`][rfloat], [`vector/acc_amd64.s`][acc].
- Project — [`LICENSE`][license].
<!-- References -->

[repo]: https://github.com/golang/image
[docs]: https://pkg.go.dev/golang.org/x/image/font
[license]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/LICENSE
[fontgo]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/font/font.go
[fixed]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/math/fixed/fixed.go
[sfnt]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/font/sfnt/sfnt.go
[cmap]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/font/sfnt/cmap.go
[gpos]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/font/sfnt/gpos.go
[truetype]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/font/sfnt/truetype.go
[postscript]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/font/sfnt/postscript.go
[opentype]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/font/opentype/opentype.go
[otest]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/font/opentype/opentype_test.go
[vector]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/vector/vector.go
[rfixed]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/vector/raster_fixed.go
[rfloat]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/vector/raster_floating.go
[acc]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/vector/acc_amd64.s
