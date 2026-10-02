# msdfgen (C++ / standalone library)

A dependency-free C++ core that turns a closed-contour vector `Shape` into a
multi-channel signed distance field, with FreeType reduced to an optional
importer in `ext/` — the reference implementation of the technique every
MSDF-based GPU text renderer (Godot, msdf-atlas-gen, many game engines) uses.

| Field            | Value                                                                                                     |
| ---------------- | --------------------------------------------------------------------------------------------------------- |
| Language         | C++ (C++98-compatible core; C++11 move paths behind `MSDFGEN_USE_CPP11`), optional OpenMP                 |
| License          | MIT ([`LICENSE.txt`][license])                                                                            |
| Repository       | [`Chlumsky/msdfgen`][repo]                                                                                |
| Documentation    | [`README.md`][readme] (library API, shader recipe, shape-description syntax), [`CHANGELOG.md`][changelog] |
| Category         | rasterizer                                                                                                |
| Layer(s) covered | outline · raster                                                                                          |
| Version at pin   | 1.13.0 ([`vcpkg.json`][vcpkg])                                                                            |
| Pinned revision  | `1c106ed8117893bf943e577f62eb0665fb271e46` (2026-08-29)                                                   |

## Overview

### What it solves

A conventional signed distance field (Valve, 2007) stores one distance per
texel and thresholds it in the fragment shader: resolution-independent, but
every corner rounds because one bilinearly interpolated channel cannot hold a
discontinuous gradient. msdfgen stores **three** signed distances per texel,
each measured against a differently coloured subset of the outline's edges, and
the shader takes their **median**. Where edges of different colour meet the
median reproduces the corner exactly; elsewhere the channels agree and degrade
to an ordinary SDF. A 32 × 32 texel bitmap then renders a glyph with sharp
corners at any magnification, which is why GPU text pipelines reach for it.

### Design philosophy

The core states its one algorithmic idea at the top of the public header:

```cpp
/*
 * MULTI-CHANNEL SIGNED DISTANCE FIELD GENERATOR
 * ---------------------------------------------
 * A utility by Viktor Chlumsky, (c) 2014 - 2025
 *
 * The technique used to generate multi-channel distance fields in this code
 * has been developed by Viktor Chlumsky in 2014 for his master's thesis,
 * "Shape Decomposition for Multi-Channel Distance Fields". It provides improved
 * quality of sharp corners in glyphs and other 2D shapes compared to monochrome
 * distance fields. To reconstruct an image of the shape, apply the median of three
 * operation on the triplet of sampled signed distance values.
 *
 */
```

— [`msdfgen.h`][h]

The second principle is the split the README names: _"It is divided into two
parts, core and extensions. The core module has no dependencies and only uses
bare C++."_ ([`README.md`][readme]). Fonts, SVG, PNG and Skia live behind
[`msdfgen-ext.h`][ext-h]; the core never sees a font file.

## How it works

The pipeline is four calls. `loadGlyph` (or `loadSvgShape`, or a hand-built
`Shape`) produces geometry; `Shape::normalize` fixes degenerate and convergent
edges; `edgeColoringSimple` assigns an `EdgeColor` to every edge; `generateMSDF`
writes floats into a `BitmapSection<float, 3>` and runs error correction
([`README.md`][readme] "Library API").

The generator is a per-texel nearest-distance search, not a scanline
rasterizer. `generateDistanceField<ContourCombiner>` walks the output in
serpentine row order, unprojects each texel centre into shape space, and asks a
`ShapeDistanceFinder` for the distance ([`core/msdfgen.cpp`][gen-cpp]). The
finder caches per-edge results and is documented as _"Not thread-safe! Is
fastest when subsequent queries are close together"_
([`core/ShapeDistanceFinder.h`][sdf-h]); under `MSDFGEN_USE_OPENMP` each thread
owns one. Two policy templates pick the metric: the `EdgeSelector`
(`TrueDistanceSelector`, `PerpendicularDistanceSelector`,
`MultiDistanceSelector`, `MultiAndTrueDistanceSelector`) and the
`ContourCombiner` (`SimpleContourCombiner` takes the nearest contour;
`OverlappingContourCombiner` tracks per-contour windings so overlapping
contours keep a correct sign) ([`core/edge-selectors.h`][sel-h],
[`core/contour-combiners.h`][comb-h]). `GeneratorConfig::overlapSupport`
toggles the combiner.

`SDFTransformation` is a `Projection` (shape → pixel `scale`/`translate`)
plus a `DistanceMapping` (a `Range` of representable distances onto 0..1)
([`core/SDFTransformation.h`][sdft-h], [`core/Projection.h`][proj-h],
[`core/Range.hpp`][range-h]).

## Analysis spine

### 1. Layering and ownership

Three layers, each with a different ownership model:

| Layer      | Types                                                              | Ownership                                                                                                                                                                                 |
| ---------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| geometry   | `Shape` → `std::vector<Contour>` → `std::vector<EdgeHolder>`       | `EdgeHolder` is a hand-written owning smart pointer to a heap `EdgeSegment` (virtual base; `clone()` on copy) ([`core/EdgeHolder.h`][holder-h])                                           |
| transform  | `Projection`, `DistanceMapping`, `SDFTransformation`, `Range`      | plain values                                                                                                                                                                              |
| pixels     | `Bitmap<T, N>` (owning) vs `BitmapRef`/`BitmapSection` (borrowing) | `BitmapSection` carries `pixels`, `width`, `height`, a signed `rowStride` and a `YAxisOrientation`; _"Pixel storage not owned or managed by the object"_ ([`core/BitmapRef.hpp`][bref-h]) |
| font (ext) | `FreetypeHandle`, `FontHandle`                                     | opaque classes wrapping `FT_Library` / `FT_Face`; `FontHandle::ownership` records whether `destroyFont` may call `FT_Done_Face` ([`ext/import-font.cpp`][imp-cpp])                        |

Every `generate*` entry point takes a `const BitmapSection<float, N> &output`,
so the caller owns the destination and may hand in a sub-rectangle of a larger
atlas or a negatively-strided flipped image (the 1.13 change: _"The library now
operates on bitmap section references"_, [`CHANGELOG.md`][changelog]).
Error handling is `bool` returns and `NULL` handles; the core never throws.
Thread-safety is per-object: a `Shape` is read-only during generation, the
finder is explicitly single-threaded, and parallelism is OpenMP over rows.

### 2. Face loading and table access

Only through FreeType, and only to the outline. `loadFont` calls
`FT_New_Face(…, 0, …)` and `loadFontData` calls `FT_New_Memory_Face(…, 0, …)`
— **face index is hard-coded to 0**, so a TTC member beyond the first is
unreachable; `adoptFreetypeFont(FT_Face)` is the escape hatch for a caller
that opened the face itself ([`ext/import-font.cpp`][imp-cpp],
[`ext/import-font.h`][imp-h]). There is no table access: `getGlyphCount`,
`getGlyphIndex` (`FT_Get_Char_Index`), `getFontMetrics` and `getKerning`
(`FT_Get_Kerning`, `FT_KERNING_UNSCALED`, so the legacy `kern` table only) are
the entire inspection surface.

### 3. Shaping

Does not apply. msdfgen is addressed by `GlyphIndex` or a single `unicode_t`
and has no notion of a string, cluster or feature; consumers (msdf-atlas-gen,
Godot's `TextServerAdvanced`) layer HarfBuzz above it. The core is a per-glyph
geometry-to-texture function by design.

### 4. Variation and instances

Present, thin, and FreeType-mediated. `listFontVariationAxes` fills
`FontVariationAxis { Tag tag; const char *name; minValue; maxValue; defaultValue }`
from `FT_Get_MM_Var`, converting 16.16 fixed with `F16DOT16_TO_DOUBLE`;
`setFontVariationAxis` (by 4-char tag or by name) reads the current design
coordinates with `FT_Get_Var_Design_Coordinates`, replaces one, and writes the
whole vector back with `FT_Set_Var_Design_Coordinates`
([`ext/import-font.cpp`][imp-cpp]). Coordinates are **user/design**, never
normalized; `avar` and `STAT` are FreeType's business; named instances are not
exposed. Because `loadGlyph` reads `face->glyph->outline` after
`FT_Load_Glyph(…, FT_LOAD_NO_SCALE)`, the varied outline flows into the
`Shape` automatically: variation reaches rasterization purely as changed input
geometry. All of it compiles out under `MSDFGEN_DISABLE_VARIABLE_FONTS`.

### 5. Rasterization and outlines

**Outline API.** The `Shape` is a concrete path object: contours of
`LinearSegment` (`Point2 p[2]`), `QuadraticSegment` (`p[3]`) and
`CubicSegment` (`p[4]`), each exposing `point(t)`, `direction(t)`,
`signedDistance(origin, param)`, `scanlineIntersections`, `bound`, `reverse`,
`splitInThirds` ([`core/edge-segments.h`][seg-h]). Import from FreeType is a
callback sink: `readFreetypeOutline` installs `FT_Outline_Funcs`
(`move_to`/`line_to`/`conic_to`/`cubic_to`) and the `ftLineTo`/`ftConicTo`
callbacks append an `EdgeHolder` per segment, dropping zero-length edges
([`ext/import-font.cpp`][imp-cpp]). `writeShapeDescription` serialises a shape
back to the README's text syntax ([`core/shape-description.h`][desc-h]).

**Units.** `FontCoordinateScaling` selects `FONT_SCALING_NONE` (raw font
units), `FONT_SCALING_EM_NORMALIZED` (`1/units_per_EM`, so 1.0 = 1 em) or
`FONT_SCALING_LEGACY` (`/64`, _"the incorrect legacy version … DO NOT USE"_,
[`ext/import-font.h`][imp-h]) — a 26.6 misreading of `FT_LOAD_NO_SCALE` output
that is still the default for compatibility. `Shape` tracks `YAxisOrientation`
(`Y_UPWARD` from fonts, `Y_DOWNWARD` from SVG) and `BitmapSection::reorient`
flips `rowStride` to match ([`core/YAxisOrientation.h`][yaxis-h]).

**Modes.** `generateSDF` (true distance), `generatePSDF` (perpendicular
distance, extends edges past corners), `generateMSDF` (3-channel), and
`generateMTSDF` (MSDF + true distance in alpha, for effects such as outlines
and soft shadows) ([`msdfgen.h`][h]). `rasterize` is a separate exact scanline
fill with `FillRule` (`FILL_NONZERO`/`FILL_ODD`/`FILL_POSITIVE`/`FILL_NEGATIVE`),
used by `distanceSignCorrection` to fix the sign of a field whose contours had
inconsistent winding ([`core/rasterization.h`][rast-h],
[`core/Scanline.h`][scan-h]).

**Edge colouring** is what makes the three channels disagree at corners.
`edgeColoringSimple` walks each contour, detects corners by
`dotProduct(aDir, bDir) <= 0 || fabs(crossProduct(aDir, bDir)) > sin(angleThreshold)`,
and cycles colours so adjacent edges across a corner share only one channel
([`core/edge-coloring.cpp`][col-cpp]). `edgeColoringInkTrap` and
`edgeColoringByDistance` are alternatives; the latter solves a graph problem
over all edge pairs and is _"much slower than the rest"_
([`core/edge-coloring.h`][col-h]).

**Error correction.** Bilinear interpolation of three channels can produce
spurious median crossings between texels. `MSDFErrorCorrection` keeps a
per-texel stencil (`ERROR`, `PROTECTED`), `protectCorners`/`protectEdges`,
then `findErrors` either from the SDF alone or by comparing with the exact
shape distance, and `apply` converts flagged texels to single-channel
([`core/MSDFErrorCorrection.h`][ec-h]). `ErrorCorrectionConfig` chooses
`DISABLED`/`INDISCRIMINATE`/`EDGE_PRIORITY`/`EDGE_ONLY` and
`DO_NOT_CHECK_DISTANCE`/`CHECK_DISTANCE_AT_EDGE`/`ALWAYS_CHECK_DISTANCE`, and
accepts a caller-supplied `byte *buffer` to avoid allocation
([`core/generator-config.h`][cfg-h]). `estimateSDFError` quantifies the
remaining misfilled area by comparing analytic scanlines of the shape against
scanlines reconstructed from the field ([`core/sdf-error-estimation.h`][est-h]).

**GPU side.** The README's shader is the contract: `median(r, g, b)`, then
`screenPxRange() * (sd - 0.5)` clamped to opacity, with the rule
_"`screenPxRange()` must never be lower than 1. If it is lower than 2, there is
a high probability that the anti-aliasing will fail"_ ([`README.md`][readme]).
Channels are sampled as linear, not sRGB. There is no hinting, LCD filtering or
gamma model: anti-aliasing is one ramp over a distance. Colour glyphs are out
of scope. No atlas or cache lives here; `BitmapSection` exists so msdf-atlas-gen
can target a sub-rectangle directly.

### 6. Metrics and measurement

`FontMetrics { emSize, ascenderY, descenderY, lineHeight, underlineY, underlineThickness }`
is filled straight from `face->units_per_EM`, `->ascender`, `->descender`,
`->height`, `->underline_position`, `->underline_thickness`, scaled by the same
`FontCoordinateScaling` ([`ext/import-font.cpp`][imp-cpp]) — i.e. FreeType's
already-resolved `hhea`/`OS/2` choice, with no x-height or cap-height.
Per-glyph advance comes out of `loadGlyph`'s `outAdvance`; bounds come from
`Shape::getBounds(border, miterLimit, polarity)`, which can grow the box by a
mitered border so the distance range fits ([`core/Shape.h`][shape-h]).

### 7. Discovery, matching and fallback

Does not apply. The library opens one file or one byte buffer; there is no
enumeration, matching or fallback, and no classification data is read.

## What it teaches `sparkles:font`

- **Separate the owning bitmap from the borrowed section.** `Bitmap<T, N>` vs
  `BitmapSection<T, N>` with a signed `rowStride` and an orientation flag is
  the shape a D `@nogc` raster target should take: the generator writes into a
  slice of the caller's atlas and never allocates pixels.
- **A path object, not only a sink.** msdfgen needs random access to edges
  (neighbours for colouring, `splitInThirds`, `reverse`), which a pure callback
  sink cannot give. `sparkles:font` should offer both: a `@nogc` decompose sink
  for rasterizers and a flat segment array for analysis.
- **Make the unit scaling an explicit enum.** `FontCoordinateScaling` exists
  because an implicit `/64` shipped for a decade. Font units vs em-normalized
  vs pixels must be a type or a named parameter, never a default.
- **Error correction and edge colouring are first-class passes with config
  structs**, not flags on the generator — and the config accepts a
  caller-owned scratch buffer. Same pattern as our `Buffer` policies.
- **Variation is just geometry.** For a distance-field or outline rasterizer,
  variation needs no special path: set design coordinates on the face, decompose
  again. The shaper is where coordinates need separate plumbing.
- **Face index 0 is a bug waiting to happen.** Any `loadFontData` wrapper must
  carry the collection index.

## Strengths

- Dependency-free core, four-call API, documented shader contract.
- `EdgeSelector` × `ContourCombiner` policies yield SDF, PSDF, MSDF and MTSDF
  from one generator loop.
- Survives real outline defects: overlapping contours, inconsistent winding
  (`orientContours`, `distanceSignCorrection`), convergent edges (`normalize`),
  self-intersections via optional Skia preprocessing
  ([`ext/resolve-shape-geometry.h`][skia-h]).
- Three colouring heuristics plus analytic `estimateSDFError` make quality
  measurable.

## Weaknesses

- Per-texel nearest-edge search: an offline atlas-build cost, not a per-frame
  rasterizer.
- Face index hard-coded to 0; `kern`-table kerning only; no colour glyphs,
  hinting, LCD or gamma treatment.
- Edge colouring is heuristic and seed-dependent; dense corners still need the
  slow distance-checked correction.
- The wrong legacy `/64` scaling remains the default.
- `EdgeHolder` is a bespoke owning pointer over a virtual hierarchy: one heap
  allocation per edge.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                               | Trade-off                                                                         |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Three distances per texel, median in the shader                   | Reproduces sharp corners from a tiny bitmap                             | 3× texture memory vs SDF; interpolation artifacts need an error-correction pass   |
| Dependency-free core, FreeType only in `ext/`                     | Embeddable anywhere; geometry may come from SVG or hand-built shapes    | Core knows nothing about fonts: no `cmap`, tables, collections or shaping         |
| Generator writes into a borrowed `BitmapSection`                  | Atlas packers target sub-rectangles; flipped images via negative stride | Caller owns allocation and lifetime                                               |
| `EdgeSelector` × `ContourCombiner` policy templates               | One loop serves SDF/PSDF/MSDF/MTSDF and overlap-aware variants          | Template-heavy C++ surface; `ShapeDistanceFinder` is single-threaded per instance |
| Explicit `FontCoordinateScaling` with the wrong legacy value kept | Backward compatibility for a decade of callers                          | Correct behaviour is opt-in                                                       |
| Error correction as a configurable stencil pass                   | Fast modes for batch builds, exact modes for quality                    | Flagged texels lose corner sharpness locally                                      |
| Variation through FreeType design coordinates only                | No duplicate `fvar`/`avar` logic                                        | No named instances, no normalized coordinates, no STAT                            |

## Sources

All paths verified at the pinned revision with `git cat-file -e`.

- **Public surface** — [`msdfgen.h`][h], [`msdfgen-ext.h`][ext-h],
  [`README.md`][readme], [`CHANGELOG.md`][changelog], [`vcpkg.json`][vcpkg],
  [`LICENSE.txt`][license].
- **Geometry** — [`core/Shape.h`][shape-h], [`core/Contour.h`][contour-h],
  [`core/EdgeHolder.h`][holder-h], [`core/edge-segments.h`][seg-h],
  [`core/EdgeColor.h`][ecolor-h], [`core/YAxisOrientation.h`][yaxis-h],
  [`core/shape-description.h`][desc-h].
- **Generator** — [`core/msdfgen.cpp`][gen-cpp],
  [`core/ShapeDistanceFinder.h`][sdf-h], [`core/edge-selectors.h`][sel-h],
  [`core/contour-combiners.h`][comb-h], [`core/generator-config.h`][cfg-h],
  [`core/SDFTransformation.h`][sdft-h], [`core/Projection.h`][proj-h],
  [`core/Range.hpp`][range-h], [`core/DistanceMapping.h`][dm-h].
- **Colouring, correction, raster** — [`core/edge-coloring.h`][col-h],
  [`core/edge-coloring.cpp`][col-cpp], [`core/msdf-error-correction.h`][mec-h],
  [`core/MSDFErrorCorrection.h`][ec-h], [`core/sdf-error-estimation.h`][est-h],
  [`core/rasterization.h`][rast-h], [`core/Scanline.h`][scan-h],
  [`core/render-sdf.h`][render-h], [`core/Bitmap.h`][bitmap-h],
  [`core/BitmapRef.hpp`][bref-h].
- **Extensions** — [`ext/import-font.h`][imp-h], [`ext/import-font.cpp`][imp-cpp],
  [`ext/import-svg.h`][svg-h], [`ext/resolve-shape-geometry.h`][skia-h].

<!-- References -->

[repo]: https://github.com/Chlumsky/msdfgen
[license]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/LICENSE.txt
[readme]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/README.md
[changelog]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/CHANGELOG.md
[vcpkg]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/vcpkg.json
[h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/msdfgen.h
[ext-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/msdfgen-ext.h
[shape-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/Shape.h
[contour-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/Contour.h
[holder-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/EdgeHolder.h
[seg-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/edge-segments.h
[ecolor-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/EdgeColor.h
[yaxis-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/YAxisOrientation.h
[desc-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/shape-description.h
[gen-cpp]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/msdfgen.cpp
[sdf-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/ShapeDistanceFinder.h
[sel-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/edge-selectors.h
[comb-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/contour-combiners.h
[cfg-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/generator-config.h
[sdft-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/SDFTransformation.h
[proj-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/Projection.h
[range-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/Range.hpp
[dm-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/DistanceMapping.h
[col-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/edge-coloring.h
[col-cpp]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/edge-coloring.cpp
[mec-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/msdf-error-correction.h
[ec-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/MSDFErrorCorrection.h
[est-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/sdf-error-estimation.h
[rast-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/rasterization.h
[scan-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/Scanline.h
[render-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/render-sdf.h
[bitmap-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/Bitmap.h
[bref-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/core/BitmapRef.hpp
[imp-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/ext/import-font.h
[imp-cpp]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/ext/import-font.cpp
[svg-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/ext/import-svg.h
[skia-h]: https://github.com/Chlumsky/msdfgen/blob/1c106ed8117893bf943e577f62eb0665fb271e46/ext/resolve-shape-geometry.h
