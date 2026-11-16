# Go `image` and `x/image` (Go)

The Go standard library's image packages and their `golang.org/x/image` extension: a deliberately small model in which one three-method interface carries every image, concrete in-memory types expose `Pix`, `Stride` and `Rect`, and performance comes from type-switch fast paths over a closed list of concrete types.

| Field         | Value                                                                                                                                                         |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Go                                                                                                                                                            |
| License       | BSD 3-Clause, both repositories ([Go `LICENSE`][go-license], [x/image `LICENSE`][x-license])                                                                  |
| Repository    | [golang/go][go-repo] (`src/image/...`) and [golang/image][x-repo]                                                                                             |
| Revision read | Go `015343854b5d9e2829481df30dbcae2ca6682d25` (June 1, 2026); x/image `b06f1de3f4900ff828b8f114c37eb9ea10dfed90` (September 8, 2026)                          |
| Documentation | [pkg.go.dev/image][pkg-image] · [The Go image package][blog-image] · [The Go image/draw package][blog-draw] · [pkg.go.dev/golang.org/x/image/draw][pkg-xdraw] |
| Category      | Generic libraries: run-time interface over pixels, concrete planar and interleaved buffers, a format registry for codecs                                      |
| Tier          | B                                                                                                                                                             |
| Last reviewed | November 7, 2026                                                                                                                                              |

> [!NOTE]
> Claims marked **verified** were rerun on November 15, 2026 in
> `/tmp/go-image-verifier/` with Go 1.25.9 on linux/amd64. A Go build overlay
> (`overlay.json`) substituted the pinned revision's entire `src/image` tree (and
> mapped Go 1.25.9's removed `src/image/jpeg/{fdct,idct}.go` to empty paths); the
> compiler and remaining standard library came from nixpkgs. Commands:
> `go run -overlay=overlay.json .`, `go test -overlay=overlay.json -v -count=1`, and
> upstream package tests for `image/...` and `golang.org/x/image/{draw,webp,tiff,bmp}`
> at their pinned revisions. Allocation counts and bytes were measured; execution speed
> was not.

---

## Overview

### What it solves

`image` describes itself in its first line as a package that "implements a basic 2-D
image library" ([`image.go`][go-pkgdoc]). The package doc states the whole design in a
few sentences: an `Image` contains colours from `image/color`, values are made by
constructors or by `Decode`, and decoders arrive by registration
([`image.go`][go-pkgdoc]):

> _"Decoding any particular image format requires the prior registration of a decoder
> function. Registration is typically automatic as a side effect of initializing that
> format's package so that, to decode a PNG image, it suffices to have
> `import _ "image/png"` in a program's main package."_

### Design philosophy

Three ideas carry the library:

1. **One small interface for every image.** `Image` has `ColorModel`, `Bounds` and
   `At`; every algorithm in `image/draw` accepts it. Generality is run-time
   (interface dispatch and a `color.Color` interface value per pixel), not compile-time.
2. **Concrete types are open structs.** `RGBA`, `NRGBA`, `Gray16`, `Paletted`,
   `YCbCr` and the rest expose their pixel slices and strides as public fields, so a
   caller that knows the type can bypass `At` entirely.
3. **Fast paths are a type switch.** `draw.DrawMask` and `x/image/draw`'s scalers
   recognise a fixed set of (destination, source, mask, operator) combinations and
   fall back to the generic interface loop otherwise.

The package doc also contains an explicit hostile-input contract, which is the most
transferable single paragraph in the subject ([`image.go`][go-pkgdoc]):

> _"When operating on arbitrary images, [`DecodeConfig`][go-decode] should be called before
> [`Decode`][go-decode], so that the program can decide whether the image, as defined in the
> returned header, can be safely decoded with the available resources. A call to
> [`Decode`][go-decode] which produces an extremely large image, as defined in the header returned
> by [`DecodeConfig`][go-decode], is not considered a security issue, regardless of whether the
> image is itself malformed or not."_

`x/image` adds codecs (BMP, TIFF, WebP, VP8, VP8L, CCITT), a resampling and affine
transform layer (`x/image/draw`) that is a "superset of and a drop-in replacement for
the image/draw package in the standard library" ([`draw/draw.go`][x-draw-doc]), and a
vector rasterizer (`x/image/vector`) whose design follows the font-rs accumulation
approach ([`vector/vector.go`][x-vector-doc]).

## How it works

### `Image`, `RGBA64Image` and `PalettedImage`

The core interface ([`image.go`][go-image-iface]):

```go
type Image interface {
    ColorModel() color.Model
    Bounds() Rectangle // does not necessarily contain (0, 0)
    At(x, y int) color.Color
}
```

`At` returns `color.Color`, an interface whose only method `RGBA()` yields
alpha-premultiplied 16-bit components in `uint32`s "so that multiplying by a blend
factor up to 0xffff will not overflow" ([`color.go`][go-color]). Returning a concrete
colour as an interface can make it escape to the heap. Go 1.17 added
`RGBA64Image` with `RGBA64At(x, y) color.RGBA64`, documented as able to "avoid
allocations from converting concrete color types to the color.Color interface type"
([`image.go`][go-rgba64image]); `draw.RGBA64Image` adds `SetRGBA64`
([`draw.go`][go-draw-iface]). **Verified:** scanning a 64×64 image through a
non-inlined function taking `image.Image` costs 4096 allocations with `At` and zero
with `RGBA64At`, for `*image.NRGBA`, `*image.RGBA64` and `*image.YCbCr` alike.
The same probe's concrete, inlined `*image.NRGBA.At` loop allocates zero times;
allocation depends on the implementation and compiler optimisation.

`PalettedImage` adds `ColorIndexAt` for palette-indexed images; `draw.Image` is
`Image` plus `Set(x, y, color.Color)`.

### Concrete buffers: `Pix`, `Stride`, `Rect`

Every interleaved type has the same shape ([`image.go`][go-rgba]):

```go
type RGBA struct {
    // The pixel at (x, y) starts at Pix[(y-Rect.Min.Y)*Stride + (x-Rect.Min.X)*4].
    Pix    []uint8
    Stride int
    Rect   Rectangle
}
```

`Rect` is in absolute coordinates, so a sub-image keeps the parent's coordinate frame.
`SubImage` intersects, re-slices `Pix` from the first pixel's offset and keeps the
parent's `Stride`; the result shares pixels ([`image.go`][go-subimage]). Accessors are
bounds-checked against `Rect`; for `RGBA`, they return the zero colour outside it, and `Set` outside is a
silent no-op ([`image.go`][go-rgba-at]). **Verified:** `At(0, 0)` on an image with
`Rect(10, 10, 12, 12)` is `{0 0 0 0}`, and a write through a `SubImage` is visible in
the parent.

The type list is a closed matrix of channel kind and depth: `RGBA`, `RGBA64`, `NRGBA`,
`NRGBA64`, `Alpha`, `Alpha16`, `Gray`, `Gray16`, `CMYK` and `Paletted` in `image.go`,
and `YCbCr` and `NYCbCrA` in `ycbcr.go`. The `N` prefix marks straight
("non-alpha-premultiplied") alpha; unprefixed types are premultiplied. 16-bit types
store big-endian bytes in a `[]uint8`.

`YCbCr` is planar with three slices, two strides and an enumerated
`YCbCrSubsampleRatio` (4:4:4, 4:2:2, 4:2:0, 4:4:0, 4:1:1, 4:1:0)
([`ycbcr.go`][go-ycbcr]); `COffset` maps a luma coordinate to its chroma sample with a
switch over that ratio ([`ycbcr.go`][go-coffset]). `NewYCbCr` allocates one backing
array and slices it into three capacity-limited planes ([`ycbcr.go`][go-newycbcr]).
`NYCbCrA` embeds a `YCbCr` and adds `A` and `AStride` ([`ycbcr.go`][go-nycbcra]); the
WebP decoder returns it for lossy images with an alpha chunk, without copying the
decoded planes ([`webp/decode.go`][x-webp-nycbcra]). See
[chroma subsampling][c-chroma] and
[stride][c-stride] in the concepts page.

### `color.Model` conversion

A `Model` is one method, `Convert(c Color) Color`; the standard models are
`ModelFunc` wrappers kept as pointers so that `m == color.RGBAModel` comparisons work
([`color.go`][go-model]). Standard models first preserve colours already of the
target type; other conversions generally route through premultiplied 16-bit RGBA.
`NRGBA.RGBA()` premultiplies with integer division ([`color.go`][go-nrgba-rgba]), and
`nrgbaModel` divides back out ([`color.go`][go-nrgbamodel]):

```go
r, g, b, a := c.RGBA()
...
// Since Color.RGBA returns an alpha-premultiplied color, we should have r <= a && g <= a && b <= a.
r = (r * 0xffff) / a
```

A colour model is therefore a pixel encoding, not a colour space: there are no
primaries, transfer functions or profiles. `RGBToYCbCr` hard-codes the JFIF
(BT.601 full-range) matrix ([`color/ycbcr.go`][go-rgb2ycc]). `Palette` is a
`[]Color` that is itself a `Model`; `Index` is a linear nearest-colour search by
squared distance in premultiplied space ([`color.go`][go-palette]).

### `draw.DrawMask` and its fast paths

`draw` offers two Porter-Duff operators, `Over` and `Src` ([`draw.go`][go-draw-op]),
and `DrawMask(dst, r, src, sp, mask, mp, op)`; `Draw` calls it with a nil mask. After clipping, it
switches on the concrete destination type, then the concrete source and mask types
([`draw.go`][go-drawmask]):

```go
// For NRGBA and NRGBA64 image types, the code paths aren't just faster.
// They also avoid the information loss that would otherwise occur from
// converting non-alpha-premultiplied color to and from alpha-premultiplied
// color. See TestDrawSrcNonpremultiplied.
switch dst0 := dst.(type) {
case *image.RGBA:
    if op == Over {
        if mask == nil {
            switch src0 := src.(type) {
            case *image.Uniform: ...
```

`*image.RGBA` destinations get fast paths for uniform, RGBA, NRGBA, YCbCr, Gray and
CMYK sources, and an `*image.Alpha` mask for glyphs (`drawGlyphOver`); `Paletted`,
`NRGBA` and `NRGBA64` destinations get a few `Src` copies. Everything else falls to a
loop over `RGBA64Image` (the "FALLBACK1.17" path), then over `At`/`Set`
([`draw.go`][go-drawmask-fallback]). The YCbCr-to-RGBA converter lives in
`image/internal/imageutil` because both `draw` and `jpeg` need it
([`imageutil/impl.go`][go-imageutil]).

**Verified:** `NRGBA{200, 100, 50, 3}` converted through `color.RGBAModel` and back
through `color.NRGBAModel` becomes `{170, 85, 0, 3}`. `draw.Src` from an `*image.NRGBA`
into an `*image.NRGBA` preserves `{200, 100, 50, 3}` (the fast path copies bytes),
while routing the same pixel through an intermediate `*image.RGBA` produces
`{170, 85, 0, 3}`. Whether colour survives depends on which concrete pair the switch
recognises.

### The format registry, `Decode` and `DecodeConfig`

`RegisterFormat(name, magic, decode, decodeConfig)` appends under a mutex and publishes
the slice through an `atomic.Value` ([`format.go`][go-format]). The magic string may contain `?`
wildcards; `sniff` wraps the reader in a `bufio.Reader` when it cannot `Peek` and tries
each format in registration order ([`format.go`][go-sniff]). Each codec registers from
its `init` function: PNG with `pngHeader` ([`png/reader.go`][go-png-register]), JPEG
with `"\xff\xd8"` ([`jpeg/reader.go`][go-jpeg-register]), GIF with `"GIF8?a"`
([`gif/reader.go`][go-gif-register]), BMP
with `"BM????\x00\x00\x00\x00"` ([`bmp/reader.go`][x-bmp-register]), TIFF twice for
both byte orders ([`tiff/reader.go`][x-tiff-register]) and WebP with
`"RIFF????WEBPVP8"` ([`webp/decode.go`][x-webp-register]).

`Decode` returns `(Image, string, error)`, the format name being the registered one.
`DecodeConfig` returns `image.Config` (a `ColorModel` and `Width`, `Height`) and its doc
says it "reads only format headers and does not allocate a full-size pixel buffer"
([`format.go`][go-decode]). Both are pull decoders over `io.Reader`, whole-image and
synchronous: there is no progressive callback, no suspension and no row output.

### Decoder limits

The standard decoders have no configurable resource budget. They enforce
format-specific validity and arithmetic checks:

- PNG rejects non-positive dimensions, then checks `int64(w) * int64(h)` fits `int` and
  that `nPixels*8` does not overflow ([`png/reader.go`][go-png-ihdr]); the row buffer
  size is checked the same way ([`png/reader.go`][go-png-rowsize]). Unknown chunks up to
  `0x7fffffff` bytes are read and discarded ([`png/reader.go`][go-png-chunks]).
- GIF checks each frame against the logical screen, with a comment explaining why
  `Rectangle.In` is too lax for empty rectangles ([`gif/reader.go`][go-gif-bounds]).
- `x/image/tiff` conservatively assumes 8 bytes per pixel and rejects width × height ×
  8 overflow, rejects tiles under 8×8 "to limit the amount of work a malicious input
  can force us to perform", and rejects oversized tiles
  ([`tiff/reader.go`][x-tiff-limit], [`tiff/reader.go`][x-tiff-tile]).
- `x/image/webp` caps the `VP8X` canvas at `1<<31-1` pixels
  ([`webp/decode.go`][x-webp-limit]).
- The `New*` constructors compute the buffer length with overflow-checked
  multiplication and panic, not error, "because of backwards compatibility"
  ([`image.go`][go-pixbuflen]).

**Verified:** a 45-byte PNG whose `IHDR` claims 100000×100000 RGBA8 returns that
`Config` from `DecodeConfig` without error. A 72-byte PNG claiming 20000×20000 with a
zlib stream containing five uncompressed bytes makes `image.Decode` allocate 1526 MiB before it fails with
`png: invalid format: not enough pixel data`. `image.NewRGBA` on a 2⁴⁰×2⁴⁰ rectangle
panics with `image: NewRGBA Rectangle has huge or negative dimensions`. This is the
documented contract working as designed: the caller owns the limit.

### `x/image/draw`: scalers and transformers

`x/image/draw` adds `Scaler` (`Scale(dst, dr, src, sr, op, opts)`) and `Transformer`
(an `f64.Aff3` affine map), both documented as "safe to use concurrently"
([`draw/scale.go`][x-scaler]). `Options` carries a destination clip mask and a source
mask ([`draw/scale.go`][x-options]). Four interpolators ship
([`draw/scale.go`][x-kernels]): `NearestNeighbor`, `ApproxBiLinear` (bilinear when
upscaling, a blend of four nearest neighbours when downscaling, so its cost is
independent of source size), and two `Kernel` values, `BiLinear` (tent) and
`CatmullRom`. A `Kernel` is a `Support` and an `At func(float64) float64`; a
user-defined kernel is a value, not a type.

Kernel scaling is separable. `newDistrib` precomputes per-column and per-row source
ranges and weights, widening support by the scale factor when shrinking
([`draw/scale.go`][x-newdistrib]). `Scale` then
runs `scaleX_*` into a `[][4]float64` temporary of `dw*sh` entries and `scaleY_*` from
it into the destination ([`draw/scale.go`][x-tmpbuf], [`draw/impl.go`][x-scale-dispatch]).
`Kernel.NewScaler(dw, dh, sw, sh)` fixes the sizes and keeps the temporary in a
`sync.Pool` for reuse ([`draw/scale.go`][x-newscaler]). The 8426-line `impl.go` is
generated: `gen.go` lists the (destination, source) type pairs to specialise and the
four subsampling ratios ([`draw/gen.go`][x-gen]), so the type-switch fast paths are
produced by a code generator rather than by generics.

## Analysis

### 1. Pixel and memory model

The `Pix`/`Stride`/`Rect` triple is a compact 2-D strided view: an element offset
from a slice start, one row pitch, absolute bounds. Sub-images avoid pixel copies and share
storage; there is no column stride, so transposes, flips and planar channel views are
not views. Planar layout exists only as the special-cased `YCbCr` family with its
enumerated subsampling. Compare the fully general strides of
[mir `Slice`][mir-model] and GIL's locators
([Boost.GIL][gil-model]). Go shows how far one stride
per plane goes for the supplied buffer types; the `Image` interface also permits
custom layouts and computed pixels.

### 2. Genericity mechanism

Run-time interfaces with per-pixel dynamic dispatch, plus hand-written or generated
type switches for fast paths. The 2021 `RGBA64Image` addition is a retrofit to remove a
per-pixel heap allocation the original interface forced. The type switch is closed:
a user type that is byte-for-byte an RGBA buffer gets the slow path unless it is
`*image.RGBA`. This is the opposite pole from GIL's concepts and from
[design by introspection][dbi];
x/image's `gen.go` is what static specialisation looks like when the language cannot
express it.

### 3. Colour and metadata

Colour is a pixel encoding (`color.Model`), with no colour space, transfer function or
profile. PNG ignores `iCCP`, `gAMA`, `cHRM` and `sRGB` (all fall into the
skip-unknown-chunk branch); JPEG parses `APP0` and the Adobe `APP14` transform flag
only and skips other application markers including ICC and EXIF
([`jpeg/reader.go`][go-jpeg-markers]); WebP skips `ICCP`, `EXIF` and `XMP`
([`webp/decode.go`][x-webp-chunks], [`riff/riff.go`][x-riff-next]).
Straight versus premultiplied alpha is in the type name (`NRGBA` versus `RGBA`), which
is the clearest part of the model, but the universal interchange (`Color.RGBA()`) is
premultiplied 16-bit, so straight-alpha colour is lost on any generic path (verified
above). See [straight and premultiplied alpha][c-alpha]
and the [colour deep-dive][color].

### 4. I/O and codec architecture

A global, init-time registry keyed on magic bytes with `?` wildcards; pull decoding
from `io.Reader`; whole-image results; a header-only `DecodeConfig` beside every
`Decode`. TIFF needs random access and buffers a non-`ReaderAt` input in 10 MB steps
([`tiff/buffer.go`][x-tiff-buffer]). Encoders take an optional `EncoderBufferPool`
(PNG) to reuse scratch across calls ([`png/writer.go`][go-png-encoder]). There is no
incremental, row-streaming or suspendable mode; see
[push and pull decoding][c-pushpull].

### 5. Hostile input and safety

Memory safety comes from the language (bounds-checked slices). Resource safety is
delegated by contract: `DecodeConfig` must agree with `Decode`, a mismatch is a
reportable security bug, and an image that is merely huge is not. Per-format checks
guard integer overflow only. The probe shows a 72-byte file reaching a 1.5 GiB
allocation, which is documented, not a defect. Compare image-rs's
[`Limits`][image-rs-limits], which puts the cap inside the decoder.

### 6. Allocation and ownership

Every decode allocates its result; there is no caller-owned destination. Images are
garbage-collected values; sub-images alias. `NewYCbCr` uses one allocation for all
planes. Scratch reuse is opt-in through `sync.Pool` (`Kernel.NewScaler`,
`EncoderBufferPool`). The per-pixel `color.Color` boxing is the library's main
allocation hazard (verified above).

### 7. CPU parallelism and SIMD

The standard image packages contain no goroutines and no assembly. `x/image/vector`
has SSE4.1 accumulation kernels selected at run time with `cpu.X86.HasSSE41`
([`vector/acc_amd64.go`][x-vector-simd]) and switches from fixed-point to
floating-point arithmetic above 512 pixels, justified by a quality test rather than a
benchmark in the comment ([`vector/vector.go`][x-vector-threshold]). Scalers are
concurrency-safe but not internally parallel.

### 8. GPU offload and interop

Not applicable: `image` and `x/image` are CPU-only and expose no GPU device buffers,
textures or compute shaders. The public `Pix` slice and byte `Stride` on concrete
types allow callers to hand CPU pixel memory directly to an external upload API without
an intermediate copy ([`image.go`][go-rgba]).

### 9. Temporal, animation and containers

Animation is GIF only: `gif.DecodeAll` returns a `GIF` with parallel `Image`, `Delay`
and `Disposal` slices, `LoopCount` and a `Config` ([`gif/reader.go`][go-gif-struct]),
and its doc says it "retains every decoded frame in memory"
([`gif/reader.go`][go-gif-decodeall]). Frames are not composited. Animated WebP is not
decoded ([`webp/decode.go`][x-webp-chunks]).

### 10. Testing and conformance

`image/decode_test.go` compares each codec against a PNG golden with a per-file
tolerance in 16-bit units (0 for PNG, `8 << 8` for JPEG, `64 << 8` for GIF)
([`decode_test.go`][go-decode-test]). PNG is checked against PngSuite, comparing each
decode to a textual `.sng` dump ([`png/reader_test.go`][go-pngsuite]). PNG, JPEG and GIF
have native `FuzzDecode` targets that gate on `DecodeConfig` dimensions (skip above
one million pixels) and round-trip decode, encode, decode
([`png/fuzz_test.go`][go-png-fuzz], [`jpeg/fuzz_test.go`][go-jpeg-fuzz],
[`gif/fuzz_test.go`][go-gif-fuzz]); x/image's TIFF has the same shape under the older
`gofuzz` build tag ([`tiff/fuzz.go`][x-tiff-fuzz]).

## Lessons for Sparkles

- **Q1** The `Pix`/`Stride`/`Rect` triple with absolute bounds is enough for every
  codec and compositing routine Go ships; a Sparkles view needs at least this, and the
  open question is only how much more (column strides, N-D) is worth carrying.
- **Q1, Q5** Encoding straight versus premultiplied alpha in the type name works and
  matches the [G3 split in the baseline][bl-gaps];
  routing every generic conversion through a premultiplied interchange does not, since
  it silently loses straight-alpha colour at low alpha.
- **Q2** A run-time interface returning a boxed colour per pixel cost Go a retrofit
  (`RGBA64Image`) to remove the allocation. A D design can use introspection to reach
  the concrete path for any conforming type, rather than a closed type switch.
- **Q3** `x/image/draw` shows that a separable kernel scaler with precomputed weights,
  a fixed-size reusable variant (`NewScaler`) and kernels as values (`Support`, `At`)
  is a small, complete resampling API; D templates replace `gen.go`.
- **Q4** `DecodeConfig` beside `Decode` for every format, and magic-byte sniffing with
  wildcards, transfer directly. A global init-time registry does not fit `@nogc` D or
  explicit package boundaries; a compile-time list of codec types is the D analogue.
- **Q4, Q8** The security contract ("a header that disagrees with the decode is a
  bug; a huge image is not") is a falsifiable property Sparkles can test by
  differential fuzzing of header and full decode.
- **Q5** Go's model has no colour space at all and drops ICC, gamma and EXIF; it is a
  baseline of what a minimal model omits, not a template.
- **Q8** Per-format golden tolerances, PngSuite with text dumps, and fuzz targets that
  bound size through the header and round-trip through the encoder are cheap oracles
  to copy.
- **Q9** Codecs as separate packages that register into a core with no codec
  dependency (`image`, `image/png`, `x/image/webp`) is evidence for an image-core and
  formats split; `imageutil` shows the cost, a shared internal package that neither
  side can own.

## Strengths

- Very small, stable surface: three-method interface, uniform concrete types, two
  compositing operators.
- Header-only `DecodeConfig` for every format and a written resource-safety contract.
- Explicit straight versus premultiplied types; sub-images are zero-copy.
- Format registration decouples codecs from the core.
- Good test practice: golden tolerances, PngSuite, native fuzz targets with round trips.

## Weaknesses

- Per-pixel interface dispatch and, through `At`, per-pixel allocation.
- Fast paths are a closed set of concrete pairs; the generic path is lossy for
  straight alpha.
- No colour management, no metadata, 8- and 16-bit integer only, no float pixels.
- No decode limits, no caller-owned output, no incremental or suspendable decoding.
- Animation limited to GIF frames held in memory; no animated WebP.
- Process-global registry with silent first-match on overlapping magic.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                                                       | Trade-off                                                                                                         |
| -------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| Three-method `Image` interface returning boxed `color.Color`   | Every image and algorithm shares one minimal run-time contract ([`image.go`][go-image-iface])                   | Per-pixel dynamic dispatch and heap allocation until `RGBA64Image` was retrofitted ([`image.go`][go-rgba64image]) |
| Concrete structs expose `Pix`, `Stride` and absolute `Rect`    | Callers and sub-images slice and index pixel memory directly without copies ([`image.go`][go-rgba])             | One row stride per plane only; no column stride, transpose view or arbitrary channel view                         |
| Premultiplied 16-bit RGBA as the universal colour interchange  | Blending (`Over`) multiplies without overflow or an extra alpha premultiplication step ([`color.go`][go-color]) | Generic conversions lose straight-alpha RGB precision at low alpha ([`color.go`][go-nrgbamodel])                  |
| Type-switch fast paths and code generation (`gen.go`)          | Avoids interface overhead for common concrete `(dst, src, mask, op)` pairs ([`draw.go`][go-drawmask])           | Closed set of concrete types; user buffers with identical layout fall back to the slow path                       |
| Caller-enforced resource limits via header-only `DecodeConfig` | Decoders stay stateless and avoid policy knobs while bounding header cost ([`image.go`][go-pkgdoc])             | Calling `Decode` directly on untrusted input can allocate gigabytes from a tiny header                            |

## Sources

- Go standard library at `015343854b5d9e2829481df30dbcae2ca6682d25`: `src/image`,
  `src/image/color`, `src/image/draw`, `src/image/png`, `src/image/jpeg`,
  `src/image/gif`, `src/image/internal/imageutil`.
- `golang.org/x/image` at `b06f1de3f4900ff828b8f114c37eb9ea10dfed90`: `draw`, `tiff`,
  `webp`, `bmp`, `vector`.
- [The Go image package][blog-image] and [The Go image/draw package][blog-draw], linked
  from the package docs.
- Probe: `/tmp/go-image-verifier/` (`main.go`, `alloc_test.go`, `audit.d`,
  `overlay.json`; scratch, not committed).
- Catalog: [umbrella][umbrella], [concepts][concepts],
  [baseline: existing code][bl-existing].

<!-- References -->

[go-repo]: https://github.com/golang/go
[x-repo]: https://github.com/golang/image
[go-license]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/LICENSE
[x-license]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/LICENSE
[pkg-image]: https://pkg.go.dev/image
[pkg-xdraw]: https://pkg.go.dev/golang.org/x/image/draw
[blog-image]: https://go.dev/blog/image
[blog-draw]: https://go.dev/blog/image-draw
[go-pkgdoc]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/image.go#L5-L39
[go-image-iface]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/image.go#L52-L64
[go-rgba64image]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/image.go#L66-L86
[go-pixbuflen]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/image.go#L88-L101
[go-rgba]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/image.go#L103-L112
[go-rgba-at]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/image.go#L118-L166
[go-subimage]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/image.go#L192-L208
[go-ycbcr]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/ycbcr.go#L11-L61
[go-coffset]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/ycbcr.go#L101-L116
[go-newycbcr]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/ycbcr.go#L173-L200
[go-nycbcra]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/ycbcr.go#L202-L209
[go-color]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/color/color.go#L8-L19
[go-nrgba-rgba]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/color/color.go#L60-L76
[go-model]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/color/color.go#L140-L174
[go-nrgbamodel]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/color/color.go#L192-L208
[go-palette]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/color/color.go#L279-L308
[go-rgb2ycc]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/color/ycbcr.go#L7-L55
[go-draw-iface]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/draw/draw.go#L20-L34
[go-draw-op]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/draw/draw.go#L43-L51
[go-drawmask]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/draw/draw.go#L116-L253
[go-drawmask-fallback]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/draw/draw.go#L255-L387
[go-imageutil]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/internal/imageutil/impl.go#L9-L19
[go-format]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/format.go#L18-L42
[go-sniff]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/format.go#L44-L81
[go-decode]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/format.go#L83-L118
[go-png-ihdr]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/png/reader.go#L158-L171
[go-png-rowsize]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/png/reader.go#L498-L506
[go-png-chunks]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/png/reader.go#L880-L944
[go-png-register]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/png/reader.go#L1052-L1054
[go-png-encoder]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/png/writer.go#L19-L36
[go-png-fuzz]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/png/fuzz_test.go#L36-L73
[go-pngsuite]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/png/reader_test.go#L335-L407
[go-jpeg-markers]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/jpeg/reader.go#L636-L648
[go-jpeg-register]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/jpeg/reader.go#L835-L837
[go-jpeg-fuzz]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/jpeg/fuzz_test.go#L36-L66
[go-gif-bounds]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/gif/reader.go#L500-L518
[go-gif-struct]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/gif/reader.go#L583-L610
[go-gif-decodeall]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/gif/reader.go#L612-L619
[go-gif-register]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/gif/reader.go#L657-L659
[go-gif-fuzz]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/gif/fuzz_test.go#L36-L64
[go-decode-test]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/image/decode_test.go#L26-L43
[x-draw-doc]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/draw/draw.go#L5-L12
[x-scaler]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/draw/scale.go#L34-L58
[x-options]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/draw/scale.go#L60-L95
[x-kernels]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/draw/scale.go#L113-L188
[x-newscaler]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/draw/scale.go#L129-L152
[x-tmpbuf]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/draw/scale.go#L197-L206
[x-newdistrib]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/draw/scale.go#L231-L289
[x-scale-dispatch]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/draw/impl.go#L5573-L5649
[x-gen]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/draw/gen.go#L51-L75
[x-tiff-limit]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/tiff/reader.go#L578-L583
[x-tiff-tile]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/tiff/reader.go#L731-L739
[x-tiff-buffer]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/tiff/buffer.go#L14-L20
[x-tiff-register]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/tiff/reader.go#L907-L910
[x-tiff-fuzz]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/tiff/fuzz.go#L5-L29
[x-riff-next]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/riff/riff.go#L102-L113
[x-webp-chunks]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/webp/decode.go#L48-L196
[x-webp-limit]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/webp/decode.go#L171-L180
[x-webp-nycbcra]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/webp/decode.go#L96-L105
[x-webp-register]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/webp/decode.go#L318-L320
[x-bmp-register]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/bmp/reader.go#L277-L279
[x-vector-doc]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/vector/vector.go#L10-L22
[x-vector-threshold]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/vector/vector.go#L31-L49
[x-vector-simd]: https://github.com/golang/image/blob/b06f1de3f4900ff828b8f114c37eb9ea10dfed90/vector/acc_amd64.go#L5-L11
[umbrella]: ./index.md
[concepts]: ./concepts.md
[c-stride]: ./concepts.md#stride
[c-chroma]: ./concepts.md#chroma-subsampling
[c-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[mir-model]: ./mir-algorithm/index.md#_1-pixel-and-memory-model
[gil-model]: ./boost-gil.md#_1-pixel-and-memory-model
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
[color]: ./color.md
[image-rs-limits]: ./image-rs.md#limits
[bl-existing]: ./baseline/existing-code.md
[bl-gaps]: ./baseline/existing-code.md#gaps-and-tensions
