# Gamut (D)

Auburn Sounds' image I/O library: one runtime-typed `Image` struct in the FreeImage tradition, with
caller-selected layout guarantees (alignment, borders, trailing pixels, gapless rows), eleven
format plugins backed by D codecs, and an exception-free `nothrow @nogc` API.

| Field         | Value                                                                                                                   |
| ------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Language      | D (DMD and LDC; no compiler floor stated)                                                                               |
| License       | BSL-1.0 for the library; per-codec MIT, BSD-2 (LZ4), BSD-3 (WebP) and public-domain parts ([codec headers][codec-tree]) |
| Repository    | [AuburnSounds/gamut][repo]                                                                                              |
| Revision read | `7f07b8ca3602a03f367312186901f9f96d7c512b` (October 27, 2026; `v3.5.1` plus 13 commits)                                 |
| Documentation | the [`README.md`][readme-api] API guide; [`ARCHITECTURE.md`][arch]; the `examples/` directory                           |
| Category      | D landscape: image I/O library                                                                                          |
| Tier          | B                                                                                                                       |
| Last reviewed | November 14, 2026                                                                                                       |

> [!NOTE]
> Claims marked **verified** were run in a scratch program outside the repository, built in debug
> mode with DMD 2.112.1 against the pinned clone (`dub run --single`, default configuration
> `boost+mit+bsd3`). LDC 1.43.0 from the dev shell did not build the dependency dub resolved,
> `intel-intrinsics` 1.14.11: `undefined identifier __builtin_ia32_pmulhw128` (**verified**).
> These behaviours and the LDC failure were independently rerun on November 14, 2026, using an
> archive of the pinned revision under `/tmp`; the overflow probe reserved 4 GiB with `mmap`
> and never dereferenced it. Everything else was read in the source.

## Overview

### What it solves

Gamut decodes and encodes still images (and GIF animations) into one in-memory type. It exposes
caller-selected row alignment, padding, borders and vertical direction through
[`LayoutConstraints`][types-layout].

### Design philosophy

The [README][readme-intro] states the design:

> Inspired by the FreeImage design, the Image concept is monomorphic and can do it all.
>
> Gamut tries to have the fastest and most memory-conscious image decoders available in pure D code.
> It is `nothrow @nogc @safe` for usage in -betterC and in disabled-runtime D.

"Monomorphic" is the decision everything else follows from. There is one `Image` struct; the pixel
format is a runtime `PixelType` value, not a type parameter; scanlines are `void*`; and every
operation uses runtime format information. The library has no colour
model: "Nothing is specified about the color space though" ([README L112][readme-pixeltype]).
Errors are a state of the image, not exceptions ([README L206-L208][readme-errors]):

> **There is no exceptions in Gamut.** Instead the Image itself has an error API:

The library's own pitch is layout control: "One of the most interesting feature of Gamut!"
([README L413-L418][readme-layout]). A caller states the minimum guarantees it needs (row
alignment, pixel multiplicity, readable trailing pixels, a border, vertical direction, or no gaps).
Loads and conversions honour the constraints passed to that call; `convertTo` defaults to
`LAYOUT_DEFAULT`, so a later conversion can reset the guarantees ([`image.d`][img-convert]).

Gamut is the I/O backend of [dcv][dcv-io], which copies its rows into mir
`Slice` images. The contrast between Gamut's runtime-typed buffer and mir's compile-time typed
view is the main thing this page records for [Q1][q] and [Q2][q].

## How it works

### The `Image` struct

`Image` holds a type, three extents, two signed byte strides, an owning pointer and an error
pointer ([`image.d` L1573-L1613][img-fields]):

```d
// source/gamut/image.d (excerpt)
LayoutConstraints _layoutConstraints = LAYOUT_DEFAULT;
ubyte* _data = null;      // first pixel of row 0, layer 0
ubyte* _allocArea = null; // non-null only when the image owns its malloc block
int _width = 0;
int _height = 0;
int _layerCount = 0;
int _pitch = 0;           // can be negative (upside-down storage)
int _layerOffset = 0;     // always >= 0
const(char)* _error = kStrImageNotInitialized;
```

The struct is non-copyable (`@disable this(this)`, [L1540][img-dtor]) and frees its block in
`~this`. `Image.init` is in the error state ("Uninitialized image", [error strings][errors]). A block comment
([L38-L85][img-doc]) lays out the state tree (`isError` or `isValid`, then `hasData`, then
`isOwned`) and tags each method `#valid`, `#data`, `#plain` or `#own`; calling a method whose tag
does not hold "is a programming error ... (will assert)". Its claim that "there is no constness in
Image" overstates the implementation: `scanptr` and `scanline` use `inout`, so a `const(Image)`
returns const-qualified pixels ([L235-L270][img-scan]). Owners and borrowed views still share
the same struct; views have `_allocArea` null:
`createView` borrows a caller pointer ([L697-L752][img-view]), and `layer(i)`, `layerRange` and
`toRef` return non-owning `Image` values.

Pixels are reached through `scanptr(y)` and `scanline(y)`, which return `void*` and `void[]`
([L235-L270][img-scan]); the caller casts according to `type()`. `allPixelsAtOnce()` returns one
`ubyte[]` only when the image carries both `LAYOUT_GAPLESS` and `LAYOUT_VERT_STRAIGHT`
([L278-L300][img-scan]).

### `PixelType`

Eighteen concrete formats plus the `unknown` sentinel: L, LA, RGB and RGBA, each in `ubyte`,
`ushort` or `float`, with premultiplied
variants for the alpha-bearing ones (`lap8`, `rgbap16`, `rgbapf32`, …) ([`types.d`
L31-L60][types-pt]). Integers are "stored normalized (255 or 65535 being the maximum of
intensity)", floats nominally 0 to 1. There is no planar, packed, sub-byte, signed, half-float or
YCbCr type; the `isPlanar` and `isCompressed` predicates exist but always describe "plain pixels"
([`image.d` L60-L62][img-doc]). Conversion goes through an intermediate type, `rgba8` when both ends
fit in it and `rgbaf32` otherwise ([`scanline.d` L23-L31][scan-inter]), with hand-written loops
to and from the intermediate representations (`scanline_convert_rgba8_to_l8`, …).

### Layout constraints

`LayoutConstraints` is a 16-bit flag word ([`types.d` L268-L350][types-layout]); load flags occupy
bits 16 to 25 so one `int` carries both ([L140-L198][types-load]). The groups:

| Group        | Values                                        | Guarantee                                                       | On sub-image       |
| ------------ | --------------------------------------------- | --------------------------------------------------------------- | ------------------ |
| Multiplicity | `LAYOUT_MULTIPLICITY_1/2/4/8`                 | pixels can be READ n at a time from the row start               | removed            |
| Trailing     | `LAYOUT_TRAILING_0/1/3/7`                     | at least n readable pixels after each row                       | kept, not writable |
| Alignment    | `LAYOUT_SCANLINE_ALIGNED_1` … `_128`          | row addresses and pitch aligned                                 | removed            |
| Border       | `LAYOUT_BORDER_0/1/2/3`                       | n addressable pixels on every side                              | kept, not writable |
| Direction    | `LAYOUT_VERT_FLIPPED`, `LAYOUT_VERT_STRAIGHT` | pitch is kept negative or non-negative                          | n/a                |
| Gapless      | `LAYOUT_GAPLESS`                              | no gaps between rows or layers; compatible with direction flags | lost               |

The source comment names the intended use: "if you want to process 4x RGBA8 pixels at once, with
aligned SSE, use: `LAYOUT_MULTIPLICITY_4 | LAYOUT_SCANLINE_ALIGNED_16`". Constraints are a floor:
"Your image may be _more_ constrained than that in practice, but you can't rely on that."
([README L440-L442][readme-layout]). `allocatePixelStorage` turns them into a pitch and a first-pixel
offset inside one `realloc` block ([`internals/types.d` L411-L521][alloc]), and `convertTo` skips
reallocation when the existing buffer already satisfies the request, using "ad-hoc" constraints
measured from the actual pointer and pitch ([`image.d` L1200-L1216][img-convert]). The open
[`TODO.txt`][todo] lists the known gap: most operations reset the layout to `LAYOUT_DEFAULT` unless
the caller passes it again.

### Plugins, codecs and I/O

[`ARCHITECTURE.md`][arch] splits the tree in two: `codecs/` holds the raw codecs and `plugins/`
"bridges the Image abstraction and the codecs themselves" (the name is FreeImage's). A plugin is a
record of three function pointers ([`plugin.d` L28-L54][plugin]), and all eleven sit in one
`static immutable __gshared` table indexed by `ImageFormat` ([L111-L125][plugin-table]):

```d
// source/gamut/plugin.d
alias LoadImageProc = void function(ref Image image, IOStream *io, IOHandle handle, int page, int flags, void *data);
alias SaveImageProc = bool function(ref const(Image) image, IOStream *io, IOHandle handle, int page, int flags, void *data);
alias DetectImageFormatProc = bool function(IOStream *io, IOHandle handle);
```

`IOStream` is five callbacks "binary compatible with ftell/fseek/fwrite/fread/feof", so a `FILE*`,
a `MemoryFile` or user callbacks all fit ([`io.d` L26-L103][io]). Loading is pull-style and
whole-image: detection reads a signature, then `loadProc` reads until it has the full raster and
fills the `Image` in one call ([`image.d` L1751-L1772][img-load]). Where each codec comes from:

| Format  | Decode                                                              | Encode                                  | Built in `boost` config |
| ------- | ------------------------------------------------------------------- | --------------------------------------- | ----------------------- |
| PNG     | `stbdec.d`, D translation of stb_image 2.27                         | `stb_image_write.d` (v1.16)             | yes                     |
| JPEG    | `jpegload.d`, jpgd by Rich Geldreich, D port by Ketmar              | `stb_image_write.d` (jo_jpeg, baseline) | yes                     |
| BMP     | `stbdec.d` (stb_image 2.27)                                         | `bmpenc.d`, from `imageformats`         | yes                     |
| TGA     | `tga.d`, from stb_image                                             | `tga.d`                                 | yes                     |
| GIF     | `gif.d`, Gamut's own ("to replace gifdec.d")                        | `msf_gif.d`, translated msf_gif         | yes                     |
| JPEG XL | `j40.d`, D translation of J40 (2022-09)                             | none                                    | yes                     |
| DDS     | none                                                                | `bc7enc16.d`, BC7 only                  | yes                     |
| QOI     | `qoi.d`, translation of the reference codec                         | `qoi.d`                                 | no (MIT)                |
| QOIX    | `qoi2avg.d`, `qoiplane.d`, `qoiplane10.d`, `qoi10b.d`, then `lz4.d` | same                                    | no (MIT)                |
| SQZ     | `sqz.d`, translation of SQZ                                         | `sqz.d`                                 | no (MIT)                |
| WebP    | `tiny_webp.d`, lossless and lossy, no animation                     | none                                    | no (BSD-3)              |

The PNG and BMP plugins share [`stbdec.d`][stb-header]; the other origins above are identified by
the [codec headers][codec-tree] and each plugin's imports. Each codec is behind a
`version (decodeX)` or `version (encodeX)` identifier, and the
[`dub.json` configurations][dub] select sets of them by licence (`boost`, `boost+mit`,
`boost+mit+bsd3`) or by client (`audio-plugin`, `hipreme`, `just-decode`, `no-codecs`). QOIX is
explicitly not a storage format: "This format may change between major Gamut tags"
([README L22][readme-intro]).

## Analysis

### 1. Pixel and memory model

The model is a 3-D array (layers, rows, pixels) of interleaved pixels with a signed row
[stride][concept-stride] in bytes and a non-negative layer stride. Negative pitch is first
class: `flipVertical` can flip "logically" by negating the pitch instead of moving rows, and a
view over bottom-up caller data needs no copy ([`image.d` L1907-L1921][img-flip]). Layers are "secretly similar to 2D Array
Texture in OpenGL" ([README L594][readme-layers]); a GIF decodes into one layer per frame.

What the model lacks is any type for the pixel. Every consumer recasts `void*` itself, and a wrong
cast is silent. Two behaviours show how thin that layer is. `castTo`, the documented
reinterpretation, computes `destBytes` from the source type ([L1369-L1370][img-cast]), so the width
never changes: casting a 4 x 1 `rgba8` image to `l8` succeeds and reports width 4 and 4 bytes per
row over 16 bytes of data (**verified**). And row addressing is `_data + _pitch * y` in 32-bit
arithmetic ([L240][img-scan]): on a 16384 x 16384 `rgbaf32` view (pitch 262144 bytes, 4 GiB, below
the 32 GiB cap) `scanptr(8191)` is 2147221504 bytes past row 0 but `scanptr(8192)` is
-2147483648 bytes (**verified**, pointer arithmetic only, no dereference).

Against the [mir direction][mir-model]: `Slice` gives the
same strided-rows shape with the element type and dimension count in the type, `size_t` lengths
and `ptrdiff_t` strides, N dimensions instead of exactly three, and views (`blocks`, `windows`,
transposes) that Gamut has no counterpart for. What `Slice` does not have is Gamut's allocation
contract: a request for aligned rows, readable padding and a border. In Gamut that request must
be passed again to conversions whose default is `LAYOUT_DEFAULT`.
dcv shows the seam between the two: it copies Gamut's rows into a fresh `Slice` scanline by
scanline ([dcv: Image I/O through Gamut][dcv-io]).

### 2. Genericity mechanism

None in the template sense. Formats are an enum, pixel types are an enum, codecs are function
pointers in a table. The nine `convertPixelTypeTo*` functions in
[`types.d` L353-L604][types-conv] map enum values through 19-case `final switch` statements
(18 pixel types plus `unknown`); pixel conversion uses loops to and from the intermediate
representations in [`scanline.d`][scan-convert]. This gives plugins a uniform runtime signature.
Algorithms over `Image` must inspect or normalize the runtime pixel type: the README's own
processing example asserts `rgba8` and indexes bytes by
hand ([README L364-L397][readme-process]). [Boost.GIL][boost-gil],
[`ae.utils.graphics`][ae-graphics] and mir sit at the other end, with the pixel type known at
compile time. The question for Sparkles ([Q2][q]) is where the runtime enum stops and the
compile-time type starts, not which one to pick.

### 3. Colour and metadata

`Image` carries a pixel aspect ratio and a vertical resolution ([fields][img-fields]); no
transfer function, primaries, ICC profile, CICP, EXIF, XMP or orientation. Decoders that read
such data do not expose it through `Image`: J40 has colour-encoding and ICC fields
(`icc`, `gamma_or_tf` in [`j40.d`][j40]), but its ICC routine consumes the encoded commands
without interpreting them ([`j40__icc`][j40-icc]). The JXL plugin copies only RGBA8 pixels
([`plugins/jxl.d`][jxl-load]), and the GIF plugin notes "TODO: store
decoder.FPS() somewhere, need metadata" ([`plugins/gif.d` L73][gif-load]). [`TODO.txt`][todo]
lists "GAMUT: metadata" as unstarted.

Conversions are formulas on encoded values. RGB to greyscale keeps the red channel
(`outScan[x] = inScan[4*x]`, [`scanline.d` L200-L207][scan-grey]): pure green `rgba8(0, 255, 0,
255)` becomes `la8` with luminance 0 (**verified**). Premultiplied alpha is represented
in the runtime enum, as separate `PixelType` values with `premultiply` and `unpremultiply`
([concepts: alpha][concept-alpha]); v3 made it a breaking change
because decoders may now return either form unless `LOAD_PREMUL` or `LOAD_NO_PREMUL` is given
([README L44-L48][readme-intro]). Compare [color][color], which models colour spaces in the
type and is silent on files.

### 4. I/O and codec architecture

The plugin record (detect, load, save) over a five-callback stream is the whole architecture. It
is small and portable, and needs nothing from the D runtime (one configuration is named
`audio-plugin`). It is also strictly [pull and whole-image][concept-pull]: there is
no incremental or suspendable decode, no "header only" path (`LOAD_NO_PIXELS` is "NOT SUPPORTED
YET!", [`types.d` L187-L189][types-load]), no tiled or region decode, and no cancellation. Several
plugins are whole-file in practice: QOIX seeks to the end, `malloc`s the file length and reads it
all ("This is temporary.", [`plugins/qoix.d` L66-L90][qoix-load]); the PNG plugin first probes
whether the file is 16-bit, then rewinds and performs the pixel decode ([`plugins/png.d` L50-L90][png-load]).
PNG and GIF encoding build the output in memory before writing it
("This is rather bad, could be done progressively", [`png.d` L215-L218][png-save],
[`gif.d` L139-L145][gif-save]). The I/O contract declares a maximum offset of `0x7fff_fffe`
because some C callback types may be 32-bit ([`io.d` L18-L24][io]); this is not a universal
file-size check. `MemoryFile` rejects oversized tell offsets and asserts on oversized seeks
([L385-L425][io-memory]), while file loading opens the stream without a size preflight
([`image.d` L1733-L1749][img-file-internal]).

The per-codec `version` identifiers grouped into licence-named configurations are a practical
answer to [Q9][q]: one package, with the format set chosen at build time rather than split into
packages.

### 5. Hostile input and safety

Gamut bounds the output, not the work. `imageIsValidSize` caps width and height at
`GAMUT_MAX_IMAGE_WIDTH = 16777216` and layers at 4194303 ([`internals/types.d`
L150-L162][valid-size]); `allocatePixelStorage` computes the size in `long` and rejects anything
above `GAMUT_MAX_IMAGE_BYTES` (32 GiB), commented "such a large allocation is indicative of forged
images / attacks anyway" ([`types.d` L103-L118][types-limits], [`internals/types.d`
L434-L451][alloc]). Creating a 16777217 x 1 image fails with "Can't have an image that exceeds
Gamut size limitations", and 12 bytes of text fail with "Unidentified image format" (both
**verified**). The stb-derived decoders add stb's own `STBI_MAX_DIMENSIONS = (1 << 24)` and its
`int`-overflow checks (`stbi__mad3sizes_valid`, [`stbdec.d` L556-L581][stb-mad]); stb's comment
says its limits "generally boil down to either just under 2GB or just under 1GB"
([L231-L237][stb-limits]).

The gaps are elsewhere. The PNG plugin checks `imageIsValidSize` after stb has already allocated
the decoded buffer ([`plugins/png.d` L95-L106][png-load]). A GIF's frame count comes from scanning
the whole file and sizes one allocation for all layers, up to the 32 GiB cap
([`plugins/gif.d` L60-L81][gif-load]). The 32-bit `scanptr` overflow above occurs when
`pitch * y` exceeds the signed 32-bit range; total image size alone does not determine it.
Misuse is caught by `assert`, so a release build removes the check: dcv found
that calling `width()` on a failed load ends in `AssertError` in a debug build
([dcv: Hostile input][dcv-safety]). The pointer-facing API relies on `@trusted` methods
(`scanptr`, `loadFromFile` and `loadFromMemory`
are `@trusted`; `createView` and `loadFromStream` are `@system`,
[view API][img-view], [loading API][img-load-api]).
No fuzzing harness or fuzz corpus is in the tree. See [concepts: hostile input][concept-hostile].

### 6. Allocation and ownership

Owned pixel storage is one allocation per image; the image allocator uses `realloc` to reuse
an existing block. Views borrow storage instead. The comment
records Windows measurements of reuse against `free` plus `malloc` ([`internals/types.d`
L456-L478][alloc]). Codec output is adopted without a copy when it is already acceptable: the PNG
plugin assigns stb's buffer to `_allocArea` because "codec.pngload and gamut both use malloc/free"
([`plugins/png.d` L108][png-load]). Ownership is a single nullable pointer, so views and owners
share one type and the type system cannot tell them apart; `disownData` hands the block to the
caller, who must call `freeImageData` later. `malloc`, `realloc` and `free` are redeclared `pure`
through `pragma(mangle)` ([L555-L561][alloc-pure]) so `pure` methods can allocate. There is no
allocator parameter.

### 7. CPU parallelism and SIMD

Gamut has no internal worker scheduler. SIMD comes through `intel-intrinsics` inside individual
codecs (including WebP, JPEG, QOIX, the GIF encoder and SQZ), not in the pixel layer; the scanline
converters are scalar loops. The layout constraints are the library's real SIMD contribution: a
kernel can ask for 16-byte-aligned rows with 4-pixel multiplicity and then process every row
without a scalar tail. The README benchmark table for QOI, QOIX and stb PNG is documented, not
measured here ([README L58-L66][readme-qoix]).

### 8. GPU offload and interop

Not applicable to execution: Gamut exposes CPU pointers and strides and has no GPU API or
device-memory ownership. Its DDS plugin encodes CPU pixels into BC7 blocks for a texture file
([`plugins/dds.d`][dds-save]); it does not upload the result or dispatch GPU work. Layers can
represent array-texture data, but a caller must handle upload and synchronization.

### 9. Temporal, animation and containers

Animation is layers: GIF decodes to an `rgba8` image with one layer per frame, and the encoder
writes every layer with a fixed `centiSecondsPerFame = 7` because there is nowhere to store a
duration ([`plugins/gif.d` L126-L138][gif-save]). Disposal, per-frame offsets, loop count and
timestamps do not survive. WebP animation is unsupported. The layer model suits array textures and
fixed-rate sequences and nothing with variable timing.

### 10. Testing and conformance

Fifteen `unittest` blocks in `source/` cover image state, layout and bit helpers, filename
detection and LZ4. The regression suite is `examples/test-suite`, a program that covers regression
files (truncated CRC, missing `IEND`, Apple CgBI PNGs, an empty JPEG, a buggy miniz chunk),
layout/conversion checks and compatibility wrappers. It asserts success or a clean error
([`main.d`][testsuite]). The compatibility test exercises Gamut's own `imagefmt`-style wrappers,
not a second decoder ([`package.d`][compat]). No CI workflow, fuzzing harness or reference-decoder
comparison is in the pinned tree. Independent verification ran `dub test --compiler=dmd` at the
scratch archive root and `dub run --compiler=dmd` in `examples/test-suite`; both passed.

## Lessons for Sparkles

- **Q1.** Gamut's layout constraints offer an allocation
  request for alignment, multiplicity, readable trailing pixels and a border, kept as a floor
  and checked against the actual buffer before reallocating. It is independent of the view type
  and could sit beside a `Slice`-style view as an allocation policy.
- **Q1.** Byte strides and row-address products should use pointer-sized signed arithmetic;
  Gamut's `int` products wrap at 2 GiB even on a 64-bit host (verified). mir's typed strides
  use `ptrdiff_t` but cannot express a
  pitch that is not a multiple of the element size ([mir][mir-model]).
- **Q1, Q2.** One struct for owner and view, with ownership as a nullable pointer,
  does not distinguish borrowed and owned values by type.
  Sparkles should express borrowing and read-only access explicitly.
- **Q2.** A runtime pixel-type enum is the right shape at the codec boundary (a file's format is
  known only at run time). For algorithms, Gamut's examples show the need to inspect or normalize
  that enum. Sparkles can keep the enum at the edge and offer typed adapters to algorithms.
- **Q4.** The detect/load/save function-pointer plugin over a callback stream is a minimal codec
  registry. It does not transfer as is: it is pull-only and whole-image, with no header-only,
  incremental or suspendable path, which [Q4][q] requires.
- **Q5.** The plugins already receive `ref Image`, so metadata fields could be added without
  changing every function-pointer signature. The current model has no colour-metadata contract,
  and the TODO lists metadata. Sparkles should define that contract early.
- **Q5.** The observed red-channel greyscale conversion shows why Sparkles needs an explicit
  colour-conversion contract, including transfer functions and greyscale weighting.
- **Q8.** An issue-file regression suite is useful, but Gamut's has no fuzzing or independent
  decoder oracle. Sparkles should add both rather than rely on regression fixtures alone.
- **Q8.** Gamut returns errors for failed loads but asserts if callers query dimensions before
  checking success. Those misuse checks vanish under `-release`; Sparkles should document the
  caller contract and return errors for malformed input.
- **Q9.** Codec selection by `version` identifiers grouped into licence-named configurations
  keeps one package while letting users choose codec sets: evidence that format
  granularity can be a build option rather than a package split.

## Strengths

- `nothrow @nogc` throughout, usable without the D runtime; errors are a value on the image.
- Layout constraints give SIMD kernels aligned, padded rows and borders on request.
- Negative pitch and layers allow views over bottom-up rows and layered caller storage.
- Wide format coverage in pure D, including JPEG XL, WebP, BC7 encoding and the QOIX family.
- Licence-aware build configurations and a documented FreeImage-style API.

## Weaknesses

- No pixel type in the type system: `void*` rows, unchecked casts, and a `castTo` that does not
  change the width (verified).
- Row-address products use 32-bit `int` arithmetic and wrap at 2 GiB, well under the 32 GiB
  allocation cap (verified).
- No colour space, transfer function, ICC, EXIF or frame timing; RGB to grey takes the red channel
  (verified).
- Pull-only, whole-image decoding; no header-only, region, incremental or cancellable path.
- Hostile-input bounds are on output size; some checks run after the codec allocated, and misuse
  checks are asserts.
- The dependency dub resolves, `intel-intrinsics` 1.14.11, did not build with LDC 1.43.0
  (verified).

## Key design decisions and trade-offs

| Decision                                     | Rationale                                                                  | Trade-off                                                               |
| -------------------------------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| One runtime-typed `Image`                    | The README explicitly chooses a monomorphic model ([source][readme-intro]) | Consumers must inspect or normalize `PixelType`                         |
| Layout flags at allocation and conversion    | Callers request alignment, padding and borders ([source][types-layout])    | Conversions default to resetting the guarantees ([source][img-convert]) |
| Owners and views share one struct            | `_allocArea` records ownership ([source][img-fields])                      | The type does not encode a borrow                                       |
| Codec sets selected by `version` identifiers | Configurations group enabled codecs by licence or client ([source][dub])   | Format availability depends on the selected build                       |
| Callback I/O with one load call              | The plugin fills `Image` synchronously ([source][plugin])                  | No public suspended decode state                                        |

## Sources

- [AuburnSounds/gamut][repo] at `7f07b8ca3602a03f367312186901f9f96d7c512b`:
  [`README.md`][readme-api], [`ARCHITECTURE.md`][arch], [`TODO.txt`][todo], [`dub.json`][dub],
  [`source/gamut/image.d`][img-fields], [`source/gamut/types.d`][types-pt],
  [`source/gamut/plugin.d`][plugin], [`source/gamut/io.d`][io],
  [`source/gamut/internals/types.d`][alloc], [`source/gamut/scanline.d`][scan-grey],
  [`source/gamut/plugins/png.d`][png-load], [`source/gamut/plugins/gif.d`][gif-load],
  [`source/gamut/plugins/qoix.d`][qoix-load], [`source/gamut/codecs/stbdec.d`][stb-limits],
  [`source/gamut/codecs/j40.d`][j40], [`examples/test-suite/source/main.d`][testsuite].
- Verified behaviours: a scratch `dub run --single` program depending on the clone by path, DMD
  2.112.1 debug build, `intel-intrinsics` 1.14.11 and `miniz` 0.0.4 as resolved by dub.
  Independent rerun: `nix develop /home/petar/code/repos/mine/sparkles-images -c dub run
--single probe.d --compiler=dmd --skip-registry=all` from a `/tmp` archive of the pinned tree.
  It reproduced the cast, greyscale, row-overflow and invalid-input results; it also confirmed
  default layout reset, explicit alignment/border constraints and negative-pitch flipping.
  Compile-time assertions confirmed that const image access returns const-qualified row pixels.
  The same command with `--compiler=ldc2` reproduced the dependency build failure.
- Related pages: [mir-algorithm][mir], [dcv][dcv],
  [`ae.utils.graphics`][ae-graphics], [Boost.GIL][boost-gil], [color][color],
  [Concepts][concepts], the [survey questions][q].

<!-- References -->

[q]: ./index.md#questions-this-survey-answers
[repo]: https://github.com/AuburnSounds/gamut/tree/7f07b8ca3602a03f367312186901f9f96d7c512b
[readme-intro]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/README.md#L1-L56
[readme-qoix]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/README.md#L58-L77
[readme-api]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/README.md#L90-L180
[readme-pixeltype]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/README.md#L112
[readme-errors]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/README.md#L206-L208
[readme-process]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/README.md#L364-L397
[readme-layout]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/README.md#L413-L524
[readme-layers]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/README.md#L594
[arch]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/ARCHITECTURE.md#L1-L6
[todo]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/TODO.txt#L1-L3
[dub]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/dub.json#L1-L50
[img-doc]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/image.d#L38-L85
[img-scan]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/image.d#L235-L300
[img-view]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/image.d#L697-L752
[img-convert]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/image.d#L1180-L1240
[img-cast]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/image.d#L1344-L1390
[img-dtor]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/image.d#L1540-L1547
[img-fields]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/image.d#L1573-L1620
[img-load]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/image.d#L1751-L1772
[img-flip]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/image.d#L1907-L1956
[types-pt]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/types.d#L31-L89
[types-limits]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/types.d#L103-L118
[types-load]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/types.d#L140-L198
[types-layout]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/types.d#L268-L350
[types-conv]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/types.d#L353-L604
[plugin]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/plugin.d#L28-L54
[plugin-table]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/plugin.d#L111-L125
[io]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/io.d#L18-L103
[valid-size]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/internals/types.d#L150-L162
[alloc]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/internals/types.d#L411-L521
[alloc-pure]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/internals/types.d#L555-L561
[scan-inter]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/scanline.d#L23-L31
[scan-grey]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/scanline.d#L200-L218
[png-load]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/plugins/png.d#L43-L163
[png-save]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/plugins/png.d#L171-L221
[gif-load]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/plugins/gif.d#L56-L103
[gif-save]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/plugins/gif.d#L105-L146
[qoix-load]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/plugins/qoix.d#L63-L100
[stb-limits]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/codecs/stbdec.d#L229-L248
[stb-mad]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/codecs/stbdec.d#L556-L581
[j40]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/codecs/j40.d#L2940-L2970
[testsuite]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/examples/test-suite/source/main.d#L11-L253
[stb-header]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/codecs/stbdec.d#L1-L10
[codec-tree]: https://github.com/AuburnSounds/gamut/tree/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/codecs
[j40-icc]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/codecs/j40.d#L3348-L3390
[jxl-load]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/plugins/jxl.d#L80-L140
[io-memory]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/io.d#L385-L425
[img-file-internal]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/image.d#L1733-L1749
[dds-save]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/plugins/dds.d#L53-L223
[compat]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/package.d#L17-L201
[scan-convert]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/scanline.d#L57-L130
[errors]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/internals/errors.d#L12-L32
[img-load-api]: https://github.com/AuburnSounds/gamut/blob/7f07b8ca3602a03f367312186901f9f96d7c512b/source/gamut/image.d#L859-L927
[concepts]: ./concepts.md
[dcv-safety]: ./dcv.md#_5-hostile-input-and-safety
[concept-stride]: ./concepts.md#stride
[color]: ./color.md
[mir]: ./mir-algorithm/index.md
[dcv]: ./dcv.md
[concept-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[mir-model]: ./mir-algorithm/index.md#_1-pixel-and-memory-model
[boost-gil]: ./boost-gil.md
[concept-pull]: ./concepts.md#push-and-pull-decoding
[dcv-io]: ./dcv.md#image-io-through-gamut
[ae-graphics]: ./ae-graphics.md
[concept-hostile]: ./concepts.md#hostile-input
