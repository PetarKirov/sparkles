# Images: comparison

The capstone of the images catalog. It reads the 58 deep-dives side by side along the
ten dimensions of the [analysis spine][spine], states what nearly every mature
subject does, names the real forks and who took which side, collects the evidence for
each of the [nine questions][questions], and maps every capability the field has to
where Sparkles stands in its [baseline][bl-index]. The design decision this catalog
feeds (one `sparkles:image` package or a split into image-core, image-formats and
image-algorithms; mir's `Slice` or an own view type) is **not made here**: this page
presents evidence and trade-offs only.

**Last reviewed:** November 7, 2026

> [!NOTE]
> Every row and claim cites the deep-dive section that supports it. "Verified" means
> the deep-dive compiled or ran something and reports the result; "documented" means
> it read the claim in source or official documentation. Where this page counts
> subjects ("most", "nearly every"), the count is over the 30 Tier A subjects in
> [At a glance](#at-a-glance) unless it says otherwise. Terms such as
> [stride][c-stride], [view][c-view] and [suspendable decoding][c-suspend] are
> defined once in [Concepts][concepts].

## At a glance

One row per Tier A subject, in the order of the [master catalog][catalog]. The labels
are normalised so that a column can be scanned: "auto" is compiler auto-vectorisation
with no dispatch layer; "per-ISA + runtime" is hand-written intrinsics per instruction
set chosen at run time; "portable + runtime" is one vector source compiled per target
and chosen at run time; "delegated" means the SIMD lives in a wrapped dependency;
"caller-set" limits are values a caller can change per decode, "fixed caps" are
compiled in, "process-global" are set once per process.

| Subject                  | Ecosystem | Pixel model                                 | Genericity                         | Decode shape                    | Limits                   | SIMD                       | GPU               | Colour                           |
| ------------------------ | --------- | ------------------------------------------- | ---------------------------------- | ------------------------------- | ------------------------ | -------------------------- | ----------------- | -------------------------------- |
| [mir-algorithm][mir]     | D         | N-D strided, element strides, kind in type  | templates + structural constraints | n/a                             | none                     | auto                       | none              | none                             |
| [dcv][dcv]               | D         | N-D `Slice`, channel as trailing axis       | templates over `Slice`             | pull, whole (delegated)         | none (inherited)         | auto (LDC only)            | none              | none                             |
| [color][color]           | D         | one element, no image                       | templates + string mixins          | n/a                             | n/a                      | none                       | none              | closed RGB enum + CIE spaces     |
| [ae.utils.graphics][ae]  | D         | interleaved 2-D lazy view                   | design by introspection            | push (libpng), whole            | none                     | auto                       | none              | none                             |
| [Boost.GIL][gil]         | C++       | interleaved/planar/packed 2-D, byte strides | templates + opt-in concepts        | pull, whole                     | none                     | none                       | none              | tags only                        |
| [VIGRA][vigra]           | C++       | N-D strided, element strides                | templates + trait classes          | pull, whole                     | none                     | auto                       | none              | element type                     |
| [Halide][halide]         | C++ DSL   | N-D strided, per-axis min/extent/stride     | DSL; runtime tag at ABI            | n/a                             | generated checks, 2^31 B | compiler, runtime-selected | multiple          | none                             |
| [JuliaImages][julia]     | Julia     | N-D array of colour structs                 | multiple dispatch                  | pull, whole                     | none                     | auto                       | none              | element type                     |
| [ITK][itk]               | C++       | N-D dense, no strides, physical geometry    | templates inside, virtual outside  | pull, region                    | none                     | auto                       | OpenCL (optional) | none                             |
| [OpenCV][opencv]         | C++       | runtime-typed N-D, byte steps               | runtime type codes                 | pull, whole                     | process-global           | portable + runtime         | multiple          | none (convention)                |
| [ImageSharp][isharp]     | C#        | interleaved 2-D, row-aligned buffer groups  | constrained generics               | pull, whole                     | allocator caps           | per-ISA + portable tier    | none              | CICP + ICC metadata, typed alpha |
| [libvips][vips]          | C         | strided regions, runtime band format        | GObject introspection              | demand-driven region pull       | block lists + per-loader | portable + runtime         | none              | ICC (lcms2) + CICP               |
| [OpenImageIO][oiio]      | C++       | runtime-typed interleaved, byte strides     | runtime `TypeDesc` + plugins       | pull, random access             | process-global           | compile-time wrapper       | none              | OCIO + CICP + ICC bytes          |
| [image-rs][imagers]      | Rust      | interleaved packed 2-D, no stride           | sealed traits + closed enum        | pull, whole                     | caller-set               | delegated                  | none              | CICP                             |
| [zune-image][zune]       | Rust      | planar dense (image), interleaved (codecs)  | traits + runtime depth tag         | pull, retry (JPEG only)         | per-axis + per-format    | per-ISA + runtime          | none              | CICP vocabulary, CMS delegated   |
| [Skia][skia]             | C++       | interleaved 2-D descriptor + `rowBytes`     | runtime enum + virtual codecs      | pull, incremental (some codecs) | memory budget (partial)  | portable + runtime         | upload only       | ICC + CICP + PQ/HLG + gain maps  |
| [Wuffs][wuffs]           | Wuffs, C  | up to 4 planes, byte strides, format word   | interfaces + vtables               | coroutine, suspendable          | structural caps          | in-language, runtime       | none              | reported, never converted        |
| [libpng][libpng]         | C         | row sink, caller row pointers               | runtime tables + build macros      | pull, or push suspendable       | caller-set per field     | per-ISA, compile-time      | none              | chunks carried, gamma only       |
| [libspng][libspng]       | C         | packed caller buffer, no stride             | runtime enum                       | pull, not suspendable           | caller-set, open default | per-ISA, compile-time      | none              | chunks carried, none applied     |
| [libjpeg-turbo][ljt]     | C         | row pointers or raw planes                  | function tables + per-width build  | pull, suspendable by retry      | opt-in (TurboJPEG)       | per-ISA + runtime          | none              | none (ICC bytes)                 |
| [libwebp][libwebp]       | C         | interleaved or YUVA planes, signed strides  | runtime enum + tables              | push, suspendable by replay     | fixed caps               | per-ISA + runtime          | none              | none (ICC passed through)        |
| [libjxl][libjxl]         | C++       | planar internal, interleaved at API         | runtime composition                | push, suspendable               | built-in, scaled         | portable + runtime         | none              | codestream encoding + ICC        |
| [libavif][libavif]       | C         | planar YUV, per-plane strides               | runtime enum + tables              | pull, suspendable               | caller-set               | delegated                  | none              | CICP (ICC bytes) + gain maps     |
| [OpenEXR][openexr]       | C, C++    | struct of named planes, chunked, deep       | runtime enum + function pointers   | pull, chunk, random access      | caller-set (off)         | per-ISA, mixed             | none              | chromaticities                   |
| [Little CMS 2][lcms2]    | C         | runtime descriptor, strides as arguments    | runtime tables + plug-ins          | n/a (profile parse)             | fixed caps               | plug-in only               | none              | ICC (full CMS)                   |
| [Simd][simd]             | C++       | 2-D byte-strided view + format tag          | per-ISA copies                     | pull, whole                     | fixed caps               | per-ISA + runtime          | none              | YUV matrix only                  |
| [Highway][highway]       | C++       | lanes; planar padded rows in `contrib`      | templates on a tag type            | n/a                             | none                     | portable + runtime         | none              | none                             |
| [KTX-Software][ktx]      | C, C++    | contiguous mip/layer block buffer           | C vtables + DFD data               | pull, whole                     | bounds only              | none                       | Vulkan            | DFD                              |
| [basis_universal][basis] | C++       | block grid                                  | runtime enum + switch              | whole, sync                     | fixed caps               | encoder only               | encoder OpenCL    | sRGB flag + DFD                  |
| [Vulkan transfer][vk]    | spec      | N-D texels or blocks per plane aspect       | runtime query + `pNext`            | n/a                             | valid usage only         | n/a                        | Vulkan            | `_SRGB` suffix + YCbCr sampler   |

The 28 Tier B subjects and the [Tier C digest][tierc] enter the comparison below where
they teach something a Tier A subject does not.

## By dimension

### 1. Pixel and memory model

The field splits into four shapes. **N-D strided views** carry one stride per axis:
[mir-algorithm][mir-1], [VIGRA][vigra-1], [Halide][halide-1], [OpenCV][opencv-1],
[NumPy][numpy-1] and [DLPack][dlpack-1]. **2-D descriptors with a row stride** are the
codec and graphics norm: [Skia][skia-1], [Simd][simd-1], [Go `image`][go-1],
[Gamut][gamut-1], [Dplug][dplug-1] and [OpenImageIO][oiio-1]. **Multi-plane images**
give each [plane][c-plane] its own stride and extent: [Wuffs][wuffs-1],
[libavif][libavif-1], [libheif][libheif-1], [OpenEXR][openexr-1] and
[nvImageCodec][nvimgcodec-1]. **No stride at all**, the image as a pointer plus
extents: [stb_image][stb-1], [image-rs][imagers-1], [zune-image][zune-1],
[CImg][cimg-1], [ITK][itk-1] and the [arsd modules][arsd-1].

The strongest designs:

- [Halide][halide-1]'s `halide_buffer_t` gives every dimension a `min`, `extent` and
  signed element `stride`, so interleaved versus [planar][c-interleave] is a stride
  permutation, a crop keeps the parent's coordinates through `min`, and negative
  strides flip without a copy (verified). Its limit is planes: YUV 4:2:0 is three
  buffers.
- [Wuffs][wuffs-1] pairs a `pixel_config` (one `uint32` format word, subsampling,
  extents) with up to four planes, each with its own byte stride, which covers
  interleaved RGBA, planar YCbCr with [chroma subsampling][c-chroma] and a palette in
  one struct. It is 2-D only, with dimensions capped at `0xFF_FFFF`.
- [libavif][libavif-1]'s `avifImage` carries per-plane strides, a subsampling enum, a
  chroma sample position and per-plane-group ownership flags, so codec planes can be
  borrowed and shallow view rectangles taken without copying.

The [Slice experiment][slice-exp] tested mir against the image cases. Planar 4:2:0
with independent pitches is three `Canonical` slices over one owner (verified,
[Planar YUV and padded strides][slice-planar]); a byte pitch that is not a multiple of
the pixel size has no pixel-typed `Slice` and needs a hand-built 3-D byte slice in
`@trusted` code (verified).

Three failures recur:

- **No stride means no views.** Crops copy, padded rows cannot be described, and
  4:2:0 is unrepresentable: [zune-image][zune-1] discards the `PlaneInfo` its own JPEG
  decoder produces, [image-rs][imagers-1] keeps strides only in the separate FFI
  `FlatSamples`, and [dcv][dcv-1]'s `Image` class has no row stride, with views always
  `ubyte*` (verified: a 32-bit image viewed wrong).
- **Element strides cannot express every byte pitch.** [mir-algorithm][mir-1],
  [VIGRA][vigra-1] and [DLPack][dlpack-1] count strides in elements; [Vulkan
  transfer][vk-1] counts `bufferRowLength` in texels or blocks, so a byte pitch that is
  not a multiple of the texel size needs a repack. [Boost.GIL][gil-1] uses byte strides
  but shares one row stride across planes, so 4:2:0 does not fit.
- **32-bit size arithmetic.** [Skia][skia-1] caps a raster at 2^31−1 bytes,
  [Halide][halide-1] at 2^31−1 unless `LargeBuffers`, [Gamut][gamut-1]'s row
  arithmetic wraps at 2 GiB (verified), and [Dplug][dplug-1]'s `int` product for
  `allocationSize` is 0 for a 32768² RGBA image (verified).

GPU-bound data has its own model. [KTX-Software][ktx-1] stores all levels, layers,
faces and depth slices of tightly packed [texel blocks][c-block] in one buffer
addressed by byte offset, and prohibits multi-planar YCbCr. [basis_universal][basis-1]
describes a block grid (original and padded size, footprint, blocks per row, pitch in
blocks), the minimum a compressed texture needs beside a pixel view. [io_uring
storage][iouring-1] adds placement constraints rather than layout ones: page-aligned
start, `stx_dio_offset_align` sizing and `minImportedHostPointerAlignment` for Vulkan
import.

### 2. Genericity mechanism

Compile-time genericity is the choice of the generic-programming libraries:
[Boost.GIL][gil-2] (concepts as documentation, traits, tag dispatch, capability
concepts that decide view types), [VIGRA][vigra-2] (trait classes and tag dispatch),
[mir-algorithm][mir-2] (structural constraints, `SliceKind` as a value parameter
branched with `static if`), [JuliaImages][julia-2] (multiple dispatch with Holy traits)
and [ImageSharp][isharp-2] (C# 11 static abstract members). Run-time genericity is the
choice of nearly every codec and production library: [Skia][skia-2],
[OpenImageIO][oiio-2], [OpenCV][opencv-2], [libvips][vips-2], [Little CMS 2][lcms2-2],
[Wuffs][wuffs-2], [libjxl][libjxl-2] and every C codec.

The strongest designs:

- [ae.utils.graphics][ae-2] is design by introspection in D: `isView`,
  `isWritableView` and `isDirectView` predicates, optional primitives (`opIndexAssign`,
  `scanline`) propagated by `static if` through adapters and proven with
  `static assert`. [Dplug][dplug-2] reuses the same trait triple at its template edges.
- [zune-image][zune-2] keeps a run-time depth tag at the image boundary and
  monomorphises each kernel for `u8`, `u16` and `f32`, with capabilities as static data
  checked by a provided `execute`. [OpenImageIO][oiio-2] does the same with a macro
  type switch inside its algorithms.
- [Wuffs][wuffs-2] and [Skia][skia-2] resolve the pixel format at run time into one
  function pointer per conversion, keeping one compiled decoder. [libjxl][libjxl-2]'s
  authors record why: "dynamic polymorphism produces more compact executables than
  template reification did".

The common failures are on both sides. Run-time type codes go unchecked:
[OpenCV][opencv-2]'s `Mat::at` checks only in debug builds and does not compare the
full type code (verified reinterpretation), and the type-code values changed between
4.x and 5.x (verified). Compile-time genericity pays in build cost and dead branches:
[VIGRA][vigra-2] names instantiation count, compile time and object size;
[ImageSharp][isharp-2] needs explicit instantiation inventories for AOT;
[ae.utils.graphics][ae-10] tests many branches only by instantiation, and three are
broken at the pinned revision. Closed variants of run-time types appear on both sides:
[Boost.GIL][gil-2]'s `any_image`, [image-rs][imagers-2]'s `DynamicImage` and the
SumType analogues the [JuliaImages][julia-l] and [image-rs][imagers-l] lessons propose
for D.

### 3. Colour and metadata

Most decoders store [colour metadata][c-icc] faithfully and apply almost none of it.
[libpng][libpng-3] validates `iCCP` in three stages but applies only a power-law gamma;
[libjpeg-turbo][ljt-3] reassembles ICC from `APP2` chunks and leaves it opaque;
[libavif][libavif-3] carries ICC as bytes and fills [CICP][c-cicp] by a stated
precedence (container `colr`, then sequence header, then decoded frame);
[libwebp][libwebp-3] skips `ICCP`, EXIF and XMP in the core decoder. Colour
management sits outside the codec, in [Little CMS 2][lcms2-3], skcms (inside
[Skia][skia-3]) or [OpenColorIO][ocio-3]; the [ICC page][icc-3] records that no
decoder it read applies ICC itself.

The strongest designs:

- [Skia][skia-3]'s `SkColorSpace` is a [transfer function][c-transfer] plus a 3x3
  matrix to XYZ D50, built from CICP or from ICC through skcms, with PQ and HLG as
  tagged transfer functions with a reference white (verified), `SkGainmapInfo` and a
  gain-map codec.
- [Wuffs][wuffs-3] reports and never converts: parsed values (gamma, chromaticities,
  the four CICP bytes), raw passthrough byte ranges (`eXIf`) and raw transforms (an
  inflated `iCCP`), with alpha state part of the pixel format.
- [ImageSharp][isharp-3] types [alpha][c-alpha] (`P`-suffixed premultiplied types and
  automatic conversion) and keeps CICP, ICC, EXIF, XMP and IPTC as metadata with a
  `Preserve`/`Compact`/`Convert` profile policy; [image-rs][imagers-3] is CICP-first,
  accepting ICC only by mapping it to CICP.

The [CICP page][cicp-5] adds a rule from crafted inputs: every carrier admits any
byte, so a reader stores the integer, never a closed enum. [libheif][libheif-3] shows
the cost of a single-answer API: an image may carry both `nclx` and ICC, and the query
returns ICC, with a `TODO` in the header. HDR [gain maps][c-gain] are a metadata
record with three unit conventions across specifications ([gain maps][gainmaps-3]).

Common failures: colour dropped at decode ([stb_image][stb-3], [Go][go-3],
[Godot][godot-3], [dcv][dcv-3]); luma computed on gamma-encoded values with fixed
weights ([Boost.GIL][gil-3], [ITK][itk-3], [stb_image][stb-3]); 16-bit reduced to
8 bits ([stb_image][stb-3] keeps the high byte, verified; [Godot][godot-3] loads a
16-bit PNG as `RGB8`, verified); defects in the one
D colour library ([color][color-3]: no chromatic adaptation applied, BT.709 using the
camera OETF, alpha dropped through XYZ). Metadata models live apart from codecs:
[ExifTool][exiftool-3] (the widest catalogue, interpreted but never applied) and
[Exiv2][exiv2-3] (typed keys, a cross-standard mapping table, ICC as an opaque buffer).

### 4. I/O and codec architecture

Whole-image pull is the default: [image-rs][imagers-4] (incremental decoding removed
in 0.25.0), [ImageSharp][isharp-4] (its async API copies the stream into memory, then
decodes synchronously), [OpenCV][opencv-4], [Boost.GIL][gil-4], [VIGRA][vigra-4],
[Go][go-4], [stb_image][stb-4] and every D library read. Random-access pull by region
serves tiled and pyramidal files: [OpenEXR][openexr-4] (offset table, chunk reads),
[libtiff][libtiff-4] (striles with deferred array loading), [GDAL][gdal-4] (Cloud
Optimized GeoTIFF), [OpenImageIO][oiio-4] and [libvips][vips-4] (demand-driven
regions).

[Suspendable decoders][c-suspend] are rarer and take four forms:

| Form                          | Subjects                                                                | Resumes by                                                    |
| ----------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------- |
| Coroutine over caller buffers | [Wuffs][wuffs-4]                                                        | re-calling; state saved at any byte                           |
| Push state machine            | [libjxl][libjxl-4], [libpng][libpng-4] push reader                      | feeding more bytes; libjxl copies partial sections internally |
| Pull with "would block"       | [libavif][libavif-4] (`AVIF_RESULT_WAITING_ON_IO`)                      | repeating the call                                            |
| Checkpoint and replay         | [libwebp][libwebp-4], [libjpeg-turbo][ljt-4], [zune-image][zune-4] JPEG | re-decoding from the last checkpoint or restart point         |

The forms differ in what a byte-at-a-time feed costs, and the deep-dives measured it.
[Wuffs][wuffs-4] produced the same pixel hash fed one byte at a time through a 16-byte
buffer as from the whole buffer (verified); [libjxl][libjxl-4] decoded a 3,540-byte
file with 3,539 `JXL_DEC_NEED_MORE_INPUT` returns (verified); [libwebp][libwebp-4]
returned `SUSPENDED` 136,296 times on one lossless file and still matched the one-shot
output byte for byte (verified), but lossless suspension re-parses the header on every
replay.

Nearly every subject separates header from pixels: [Wuffs][wuffs-4]'s three phases
(`decode_image_config`, `decode_frame_config`, `decode_frame`), [image-rs][imagers-4]'s
`prepare_image` and `read_image`, [Go][go-4]'s `DecodeConfig`, [ITK][itk-4]'s
`ReadImageInformation`, [ImageSharp][isharp-4]'s `Identify`. Container and bitstream
are separate in [libavif][libavif-4] (in-house ISOBMFF, AV1 behind `avifCodec`),
[libheif][libheif-4] (a narrow push interface to codec plugins), [libwebp][libwebp-4]
(RIFF walk apart from VP8 and VP8L) and [OpenEXR][openexr-4] (`exr_read_chunk` and
`exr_uncompress_buffer` callable alone).

Common failures: two readers in one library that disagree ([libpng][libpng-4]: a
corrupt Adler-32 fails the sequential reader and yields 63 of 64 rows in push mode,
verified; [libspng][libspng-4]: a truncated file yields 127 of 256 rows by stream and
none by buffer, verified); a synchronous source that contradicts an asynchronous one
(a [Skia][skia-4] source comment says so); and probing that decodes
([SAIL][sail-4]: the QOI describe step decodes fully, about 386 MiB resident to
probe a 1.6 MB file, demonstrated).

### 5. Hostile input and safety

The defences, from strongest to weakest:

- **Proof.** [Wuffs][wuffs-5] proves bounds, overflow and null safety at compile time
  and forbids allocation, syscalls and globals; what stays unproved is the hand-written
  base, swizzler and `wuffs_aux` C. It has no work or time budget.
- **A limits record.** [libheif][libheif-5] has a versioned `heif_security_limits`
  struct copied per context (pixels, tiles, memory block and total, items, children,
  extents, colour profile size), decode-count and decoded-pixel budgets against
  amplification, and cycle detection. [libavif][libavif-5] passes caller-set limits
  (pixel count, per-axis dimension, image count) on to dav1d and libaom.
- **Process-global limits plus ratio guards.** [OpenImageIO][oiio-5] checks channels,
  resolution and image size in 29 of 30 reader plugins and rejects a claimed size above
  10000 times the file size when it reaches 1 GiB; [libtiff][libtiff-5] 4.7.2 added a
  compression-ratio plausibility check (verified).
- **Fixed caps and caller hooks.** [libpng][libpng-5], [stb_image][stb-5],
  [libwebp][libwebp-5] and [Simd][simd-5] compile their caps in.

The failure every deep-dive with a fuzzable parser found is **allocation from declared
sizes before validation**: a 45-byte PNG makes [libspng][libspng-5] request 2 GiB
(verified); a 72-byte PNG makes [Go][go-5] allocate 1526 MiB (verified); a 69-byte PNG
makes [Godot][godot-5] `mmap` 4 GiB (verified); [KTX-Software][ktx-5] turns an
`uncompressedByteLength` of 2^40 into a 1 TiB request (verified); a 68-byte KTX1 makes
[Filament][filament-5] allocate 64 MiB (demonstrated); a 35-byte GIF makes
[SAIL][sail-5] reserve about 16.3 GiB of address space (demonstrated); [libavif][libavif-5] allocates a
declared item size in full (verified). The second is **limits that bound declared size
but not work**: [libjpeg-turbo][ljt-5]'s 10,000 empty scans add about 10 s (verified),
and [OpenImageIO][oiio-5], [Gamut][gamut-5] and [zune-image][zune-5] bound only size.
The third is **checks that vanish in release builds**: [mir-algorithm][mir-5] and the
[Slice experiment][slice-safety] (bounds checks are `assert`s inside `@trusted`
indexing, and public fields let `@safe` code widen a view, verified),
[Boost.GIL][gil-5] (`BOOST_ASSERT`), [Gamut][gamut-5] and [Simd][simd-5]. The fourth is
**unchecked size products**: [ITK][itk-5] and [VIGRA][vigra-5] wrap to zero elements
(verified), as do [DLPack][dlpack-5]'s `GetDataSize` and [ROS][ros-5] `cv_bridge`
(demonstrated).

[libwebp][libwebp-5]'s CVE-2023-4863 is the case study: Huffman tables were built
before their completeness was validated, and the fix is validate-then-grow segments.
Lenient defaults recur too: [zune-image][zune-5] turns checksums off by default and
fuzzes that configuration; [libjpeg-turbo][ljt-5] inserts a fake EOI and fills grey.
Fuzzing on OSS-Fuzz is standard for the mature C codecs ([libpng][libpng-5],
[libjpeg-turbo][ljt-5], [libwebp][libwebp-5], [libjxl][libjxl-5],
[libavif][libavif-5], [OpenEXR][openexr-5], [libvips][vips-5], [Wuffs][wuffs-5]); none
of the D libraries read has a harness.

### 6. Allocation and ownership

Three ownership patterns cover the field. **Caller owns everything**:
[Wuffs][wuffs-6] cannot allocate, so the caller sizes the decoder with `sizeof__`
(44,648 bytes for PNG, verified), the work buffer from `workbuf_len` and the pixel
buffer; [libspng][libspng-6] and [OpenEXR][openexr-6] write into caller memory and
route internal allocation through a context hook. **Owner and view as separate
types**: [VIGRA][vigra-6] (`MultiArray` owns, views borrow by value),
[Halide][halide-6] (the raw ABI owns nothing, `Runtime::Buffer` adds refcounting),
[Skia][skia-6] (`SkPixmap` borrows, `SkBitmap` shares a refcounted `SkPixelRef`,
`SkImage` is immutable or lazy). **Library-owned results**: [stb_image][stb-6] and
[Go][go-6] allocate every output, [JuliaImages][julia-6] leaves lifetime to the GC.

The strongest designs are [Wuffs][wuffs-6] for codecs and [Skia][skia-6] for an image
library: the first makes allocation impossible inside the decoder, the second names
three ownership levels and uses release callbacks for external memory.
[ImageSharp][isharp-6] adds pooling (`ArrayPool` up to 1 MiB, 4 MiB unmanaged blocks,
a ceiling at an eighth of available memory) and compares `Span` versus `Memory` to
dip1000 `scope`.

Common failures: allocator hooks that internal containers bypass
([libjxl][libjxl-6]'s `std::vector` members skip `JxlMemoryManager`;
[libheif][libheif-6] and [libvips][vips-6] leave codec-internal buffers outside their
budgets); views with no tie to their owner ([mir-algorithm][mir-6], where the [Slice
experiment][slice-exp-c] caught a stack-use-after-return under ASan in `@safe` code
over a `UniqueBuffer`; [ae.utils.graphics][ae-6], whose gamma view returns a dangling
pointer that dip1000 accepts, verified); implicit sharing that detaches silently
([OpenCV][opencv-6] `create()`, verified); and a conversion step per allocation
([stb_image][stb-6] holds two full images at peak when converting channels).
[libjxl][libjxl-6]'s working set grows with threads (about 11.3 MB on one thread,
15.5 MB on four, verified).

### 7. CPU parallelism and SIMD

SIMD dispatch takes five forms in the field:

| Form                                      | Subjects                                                                                                                                           |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Portable vector library, runtime dispatch | [Highway][highway-7], [OpenCV][opencv-7] universal intrinsics, [libjxl][libjxl-7] and [libvips][vips-7] on Highway, [Skia][skia-7] raster pipeline |
| Per-ISA hand intrinsics, runtime dispatch | [libjpeg-turbo][ljt-7], [libwebp][libwebp-7], [Simd][simd-7], [zune-image][zune-7], [libyuv][libyuv-7], [ImageSharp][isharp-7]                     |
| Per-ISA code in the language              | [Wuffs][wuffs-7] (`choose cpu_arch`, resolved once per object)                                                                                     |
| Compile-time only                         | [libpng][libpng-7] 1.8, [libspng][libspng-7], [OpenImageIO][oiio-7], [intel-intrinsics][intel-7], [Dplug][dplug-7]                                 |
| Auto-vectorisation, no dispatch           | [mir-algorithm][mir-7], [VIGRA][vigra-7], [ITK][itk-7], [JuliaImages][julia-7], [dcv][dcv-7], [ae.utils.graphics][ae-7]                            |

[Highway][highway-7] is the strongest dispatch design: 28 targets (the README says 27) as one-bit feature clusters, CPUID plus XCR0 detection, a lazy first-call export
table, and tests that run every compiled target in one binary. The deep-dive
reproduced its shape in D with `@target`, `static foreach` and a CTFE table. Its cost is measured: about 6.8 times the
compile time for eight x86 targets. [libyuv][libyuv-7] shows the plane-loop over a
row-kernel split, with each function tested against its C path.

The measured gains are uneven. [zune-image][zune-7]'s JPEG intrinsics are about 1%
faster than none on the project's own machine; [Simd][simd-7]'s bicubic resize is slower
in AVX-512BW, the variant its dispatcher picks, than in AVX2, and memory-bound
operations are flat after SSE4.1 (Zen 4). The failures are dispatcher duplication
([Skia][skia-7] has three, [OpenEXR][openexr-7] three inconsistent mechanisms),
detection without the OS state check ([Simd][simd-7] never reads `XCR0`), a dispatcher
compiled with the widest flags ([Simd][simd-7] executes VEX instructions on an SSE4.2
CPU and gets `SIGILL`, verified), mutable global function pointers
([libwebp][libwebp-7], [libyuv][libyuv-7]'s `MaskCpuFlags`, not thread-safe), and in
D, [intel-intrinsics][intel-7]'s `static if` ladder that `@target` does not reach
(verified) and that fails to build on LDC 1.43.0 (verified, also reported by
[Dplug][dplug-7] and [dcv][dcv-10]).

Threading follows one rule across the codecs: the library creates no threads.
[libjxl][libjxl-7] takes a caller `JxlParallelRunner` over an integer range;
[libtiff][libtiff-7] and [libjpeg-turbo][ljt-7] expect one object per thread. Engines
that own threads pay in memory: a [libvips][vips-7] pipeline peaked at 50.4 MiB on one
thread and about 215 MiB on 32 (verified); [Little CMS 2][lcms2-7]'s threaded plug-in
spawns a thread per slice per call (69 Mpixel/s default, 761 on 32 threads). The
schedule as a separate object is [Halide][halide-7]'s contribution: `parallel`,
`vectorize` and tail strategies attach to an unchanged algorithm ([algorithm and
schedule][c-schedule]).

### 8. GPU offload and interop

Most still-image libraries have no GPU path (23 of the 30 Tier A rows). The subjects
that do fall into upload, decode and compute:

- **Upload.** [Skia][skia-8] Graphite fuses colour and format conversion into the
  staging write (`TextureFormatXferFn`) and Ganesh walks a lazy-image ladder (cache,
  native texture, YUV planes converted on the GPU, CPU upload). [KTX-Software][ktx-8]
  uploads with a staging buffer, one `VkBufferImageCopy` per level and a blocking
  `vkWaitForFences` with a 100-second timeout. [Vulkan transfer][vk-8] tabulates, per
  device, transfer-only queues, host image copy, resizable BAR, host-pointer import
  alignment, dma-buf and GDeflate decompression (NVIDIA only on the matrix).
- **Storage to GPU.** [DirectStorage][dstorage-8] is the only subject where read,
  decompression and copy into a sampled resource are one call with one fence.
  [io_uring storage][iouring-8] found that host-pointer import of a page-aligned,
  registered slab (route 2) is the simplest zero-copy path that worked on every
  device measured, and that neither route reaches device-local memory.
  [GPUDirect Storage][tc-gds] and [Metal][tc-metal] are the closed counterparts.
- **Compute.** [Halide][halide-8] makes offload a schedule property with two dirty
  bits as the coherence protocol; its Vulkan runtime calls `vkQueueWaitIdle` per
  dispatch. [nvImageCodec][nvimgcodec-8] splits JPEG into host entropy decode, transfer
  and device reconstruction with double-buffered pinned staging. [OpenColorIO][ocio-8]
  emits shader text plus LUT textures and validates every GPU op against its CPU path.

Common failures: implicit offload with a silent fallback ([OpenCV][opencv-8]'s T-API
swallows exceptions; [bgfx][filament-8] falls back to CPU-decoded BGRA8, 32 bits per
pixel against 0.89 to 8 for the compressed formats); synchronous waits inside an
otherwise asynchronous pipeline ([Halide][halide-8], [KTX-Software][ktx-8]); and GPU
decompression treated as safe ([nvCOMP][tc-nvcomp] declares corrupt input undefined
behaviour; the [DirectStorage][dstorage-5] reference GDeflate CPU decoder overflows
under ASan, verified). The seam the codecs offer is caller-owned strided output:
[libpng][libpng-8] rows, [Wuffs][wuffs-8] planes and [libwebp][libwebp-8] `MODE_YUVA`
planes can point at mapped staging memory. In D, [dcompute][dcompute-8] has no Vulkan
target in the library at its pin, and its OpenCL image path produces invalid SPIR-V or
crashes the backend on this toolchain.

### 9. Temporal, animation and containers

Animation is a codec property in the strongest designs. [Wuffs][wuffs-9]'s
`frame_config` carries a rectangle, duration, disposal, blend and I/O position, with
`restart_frame` for random access; [Skia][skia-9]'s `FrameInfo` adds a required prior
frame so a client can skip re-decoding; [libjxl][libjxl-9] has a native tick rate,
blending onto up to four reference frames and raw layers when coalescing is off.
[libavif][libavif-9] reads image sequences as ISOBMFF tracks with per-frame `pts`,
keyframe seeking and alpha as a second track; [libheif][libheif-9] applies edit lists
by default, so an infinite-loop file never ends unless the caller opts out.

The common failure is **composited full canvases**: [image-rs][imagers-9],
[ImageSharp][isharp-9], [SAIL][sail-9] and [zune-image][zune-9] return every frame at
canvas size, losing frame rectangles, disposal and blend, so lossless delta re-encoding
is impossible and a GPU path uploads the whole canvas per frame ([SAIL][sail-l]).
Libraries without a frame model use an axis: [ITK][itk-9], [JuliaImages][julia-9],
[VIGRA][vigra-9] and [mir-algorithm][mir-9] treat time as one more dimension with no
timestamps. [KTX-Software][ktx-9] stores animation as array layers with `KTXanimData`,
a sprite-sheet model; [ROS][ros-9] puts a stamp on every frame and pairs image with
calibration by exact timestamp. Video belongs to the video catalog; this dimension
records only what a still-image library must hold so that the video work can reuse it.

### 10. Testing and conformance

Four kinds of oracle appear:

- **External conformance corpora.** [libjxl][libjxl-10] runs a pinned conformance
  corpus per codestream level and per SIMD target (11 targets, AVX3 under Intel SDE),
  comparing with per-test RMSE and peak-error limits; [libwebp][libwebp-10] uses
  external VP8 and lossless vectors; PngSuite backs [libpng][libpng-10],
  [libspng][libspng-10], [stb_image][stb-10] and [Go][go-10].
- **Differential tests against another implementation.** [libspng][libspng-10]
  against libpng over 175 PngSuite images in every output format;
  [Wuffs][wuffs-10] mimic tests plus a committed CRC-32 of every decodable file's
  output; [zune-image][zune-10]'s HEIC decoder byte-identical to libheif;
  [ImageSharp][isharp-10] against Magick.NET and System.Drawing with a tolerant
  comparer; [KTX-Software][ktx-10]'s `ktx validate` as an independent reader.
- **Path equivalence.** [Highway][highway-10] runs every test per compiled target in
  one binary and fails tests that bypass dispatch; [libyuv][libyuv-10] runs each
  function with C and SIMD; [Simd][simd-10] compares every variant against its base
  path on odd sizes; [libwebp][libwebp-10] has a fuzzer asserting incremental equals
  one-shot; [Skia][skia-10] runs each image through seven decode modes.
- **Tolerant image comparison.** [OpenImageIO][oiio-10]'s `idiff` (threshold,
  failure percentage, hard ceiling), [ITK][itk-10]'s baselines with intensity and
  radius tolerances, [libvips][vips-10]'s pixel-against-scalar oracle.

The common failures: round-trip tests cannot catch a consistently wrong decoder
([Boost.GIL][gil-10]'s Adam7 read defect passes them); untested template branches break
unseen ([ae.utils.graphics][ae-10] tests some only by instantiation, and in
[dcompute][dcompute-10] defects survive because no test instantiates them); fuzz targets built but not run in
CI ([image-rs][imagers-10]); CI that silently narrows coverage ([Simd][simd-10]: a Nix
wrapper stripping `-march=native` gave a green run of the base path only, verified);
and a D CI removed with nothing replacing it ([dcv][dcv-10], whose `dub test :core`
fails on both current compilers, verified).

## Consensus

What nearly every mature subject does, with the evidence.

1. **Read the header before the pixels, and size from it.** A header-only call
   precedes pixel decode in [Wuffs][wuffs-4], [image-rs][imagers-4], [Go][go-4],
   [ITK][itk-4], [ImageSharp][isharp-4], [OpenCV][opencv-4], [libavif][libavif-4] and
   [OpenImageIO][oiio-4]. Its purpose is that the caller can refuse or allocate.
2. **Decode into caller memory with a caller stride.** [libpng][libpng-1] row
   pointers, [libjpeg-turbo][ljt-1] row arrays, [Wuffs][wuffs-6] pixel buffers,
   [OpenEXR][openexr-6] channel slices, [Skia][skia-6] codecs, [libspng][libspng-6] and
   `decode_into` in [image-rs][imagers-6] and [zune-image][zune-6]. The library
   allocates scratch, not results.
3. **Check declared dimensions before allocating.** The subjects with a limits record,
   global limits or structural caps check them ahead of allocation
   ([libheif][libheif-5], [libavif][libavif-5], [OpenImageIO][oiio-5],
   [stb_image][stb-5], [Wuffs][wuffs-5]); the deep-dives reproduced allocation bombs in
   the subjects that check after allocating or not at all
   ([Hostile input](#_5-hostile-input-and-safety)). This is consensus as practice, not
   as universal implementation.
4. **Carry colour metadata, apply it elsewhere.** Codecs store ICC and CICP and leave
   transforms to a colour engine ([libpng][libpng-3], [libavif][libavif-3],
   [libjpeg-turbo][ljt-3], [libwebp][libwebp-3], [Wuffs][wuffs-3], [ICC][icc-3]).
5. **Keep container and bitstream apart.** [libavif][libavif-4],
   [libheif][libheif-4], [libwebp][libwebp-4], [OpenEXR][openexr-4],
   [libtiff][libtiff-4] and [KTX-Software][ktx-4] separate the box, chunk or IFD walk
   from the codec.
6. **Let the caller own threads.** Codecs create none ([libjxl][libjxl-7],
   [libjpeg-turbo][ljt-7], [libtiff][libtiff-7], [Wuffs][wuffs-7], [libyuv][libyuv-7],
   [OpenColorIO][ocio-7]); only engines ([libvips][vips-7], [OpenImageIO][oiio-7],
   [ImageSharp][isharp-7]) own a pool.
7. **Choose SIMD at run time against a scalar reference that tests can force.**
   [libjpeg-turbo][ljt-7] (environment overrides), [libwebp][libwebp-7] (set the CPU
   info pointer to `NULL`), [zune-image][zune-7] (`set_use_unsafe(false)`),
   [libyuv][libyuv-10], [Highway][highway-10], [ImageSharp][isharp-10] (rerun with
   intrinsics disabled).
8. **Fuzz continuously.** OSS-Fuzz or an in-tree harness run in CI for
   [libpng][libpng-5], [libspng][libspng-10], [libjpeg-turbo][ljt-10],
   [libwebp][libwebp-10], [libjxl][libjxl-5], [libavif][libavif-5],
   [libheif][libheif-10], [OpenEXR][openexr-5], [Wuffs][wuffs-10] and
   [libvips][vips-5].
9. **Register formats by content, not name alone.** Magic-byte sniffing with a
   registry: [Go][go-4] (wildcard patterns, first match), [Skia][skia-4]
   (`isFormat` records), [SAIL][sail-4] (`.codec.info` files read without loading the
   codec), [nvImageCodec][nvimgcodec-4] (priority-ordered with per-sample fallback),
   [OpenCV][opencv-4] (content signature).

## Trade-offs

The forks where mature subjects chose opposite sides, and what each side cost.

### Element strides versus byte strides

- **Element strides:** [mir-algorithm][mir-1], [VIGRA][vigra-1], [Halide][halide-1],
  [DLPack][dlpack-1], [Vulkan transfer][vk-1] (texels). Indexing stays typed and
  arithmetic stays simple; a pitch that is not a whole number of elements (padded RGB8,
  odd-aligned rows) cannot be expressed, and the [Slice experiment][slice-exp-c]
  needed a hand-built byte slice in `@trusted` code for it.
- **Byte strides:** [Boost.GIL][gil-1], [OpenCV][opencv-1], [NumPy][numpy-1],
  [Skia][skia-1], [Wuffs][wuffs-1], [libavif][libavif-1], [OpenImageIO][oiio-1]. Any
  pitch works; element access needs a cast, and [OpenCV][opencv-1] forbids negative
  steps (a flip copies) while [Boost.GIL][gil-1] and [libwebp][libwebp-1] allow them.

### Compile-time pixel types versus runtime type codes

- **Compile-time:** [Boost.GIL][gil-2], [VIGRA][vigra-2], [JuliaImages][julia-2],
  [ImageSharp][isharp-2], [ae.utils.graphics][ae-2]. Kernels specialise with nothing
  virtual in loops; the price is compile time, object size, AOT inventories and a
  closed run-time variant wherever a file decides the type.
- **Runtime:** [Skia][skia-2], [OpenCV][opencv-2], [OpenImageIO][oiio-2],
  [Wuffs][wuffs-2], [libjxl][libjxl-2], [Little CMS 2][lcms2-2]. One binary, smaller
  code and a stable ABI; checks move to run time and are skipped in release builds
  ([OpenCV][opencv-2]), and a format product is handled by function-pointer tables or
  stage lists.
- **Hybrid:** [zune-image][zune-2] and [OpenImageIO][oiio-2] tag at the boundary and
  monomorphise inside; [Skia][skia-2] makes the ISA the one compile-time axis. The
  [Slice experiment][slice-exp-c] adds that `Slice` carries no pixel format, alpha
  state or colour, so a runtime descriptor beside the view is needed whichever view
  type is chosen.

### Pull versus push versus suspendable decode

- **Blocking pull:** [image-rs][imagers-4], [OpenCV][opencv-4], [libspng][libspng-4],
  [Skia][skia-4]. Simplest code; an asynchronous caller must buffer the whole file
  first ([ImageSharp][isharp-4] does exactly that).
- **Push:** [libjxl][libjxl-4], [libwebp][libwebp-4], [libpng][libpng-4]. Fits a
  completion loop; the library keeps partial input or replays from a checkpoint, and
  [libpng][libpng-4]'s two readers disagree on corrupt input.
- **Suspendable over caller buffers:** [Wuffs][wuffs-4]. Exact resumption at any byte
  with no hidden copy; the cost is a language and compiler of its own and a slow
  coroutine path beside the fast one.
- **Pull with "would block":** [libavif][libavif-4]. Keeps a pull-shaped API and still
  suspends; the call is repeated, so work done before the stall must be idempotent.

### Caller-set limits versus fixed caps

- **Caller-set:** [libheif][libheif-5], [libavif][libavif-5], [image-rs][imagers-5],
  [libspng][libspng-5], [OpenEXR][openexr-5]. Policy belongs to the application; the
  defaults decide real safety, and [libspng][libspng-5] and [OpenEXR][openexr-5]
  default to open (verified 2 GiB request; OpenEXR limits default to 0, disabled).
- **Fixed caps:** [libwebp][libwebp-5], [stb_image][stb-5], [Simd][simd-5],
  [Wuffs][wuffs-5] (structural). Always on; cannot be tightened for a server or loosened
  for a gigapixel scan.
- **Process-global:** [OpenCV][opencv-5] (environment variables read at static
  initialisation), [OpenImageIO][oiio-5]. One setting for every decode in the process,
  which a library inside another library cannot own.

### Per-ISA kernels versus portable SIMD

- **Per-ISA hand intrinsics:** [libjpeg-turbo][ljt-7], [libwebp][libwebp-7],
  [Simd][simd-7], [libyuv][libyuv-7]. Peak control per instruction set; bodies drift
  ([libpng][libpng-l]: dead LoongArch and RISC-V code and a Neon tail bug;
  [Dplug][dplug-7]: the L16 blend without a twin is off by one) and the build matrix
  grows.
- **Portable library:** [Highway][highway-7], [OpenCV][opencv-7], [libjxl][libjxl-7],
  [libvips][vips-7]. One source; compile time multiplies by the target count and some
  operations (shuffles, narrowing) still need per-target code ([Highway][highway-l]).
- **Auto-vectorisation:** [mir-algorithm][mir-7] and the D libraries. No dispatch at
  all; the result depends on the compiler and the build mode. The [Slice
  experiment][slice-exp-c] found the idiomatic `windows` blur scalar under the shipping
  `checked` build while the hand loop vectorised (verified), and `@fmamath` permits
  FMA contraction against an exact oracle (documented, not tested).

### One library versus format plugins

- **One library with build switches:** [CImg][cimg-l] (a 71,779-line header),
  [VIGRA][vigra-l], [stb_image][stb-4], [libjxl][libjxl-l], [ImageSharp][isharp-l].
  One dependency to pin; every consumer takes every format's attack surface and compile
  time, and trimming is not evidence that unused codecs disappear.
- **Core plus per-format packages:** [zune-image][zune-l] (one crate per codec over a
  tiny core), [Go][go-l] (codecs register into a codec-free core), [arsd][arsd-l],
  [SAIL][sail-l], [Boost.GIL][gil-l]. Consumers take one codec, fuzzed alone; the price
  is a shape convention rather than a shared trait, re-wrapping, and cross-package
  version pinning ([JuliaImages][julia-l]).
- **Runtime plugins:** [GDAL][gdal-l], [OpenImageIO][oiio-2], [libheif][libheif-4],
  [nvImageCodec][nvimgcodec-l]. New formats without rebuilding; dynamic loading and
  global registries conflict with `-betterC`, wasm and Android builds ([Skia][skia-l],
  [ITK][itk-l]).

### Owner type versus bare view

- **Owner and view distinct:** [VIGRA][vigra-6], [Skia][skia-6], [Halide][halide-6],
  [ImageSharp][isharp-6]. Lifetimes are explicit; two types to learn and convert.
- **Bare view, ownership in the iterator:** [mir-algorithm][mir-6]. One type for both;
  a view can outlive the buffer it borrows, and dip1000 did not stop it in the
  [Slice experiment][slice-exp-c].
- **One type with a shared flag:** [CImg][cimg-l], [Gamut][gamut-6]. Simple; the
  owner/view distinction is lost and dangling views are the cost.

## Answers to the nine questions

Each answer gives the evidence the catalog gathered, the choices it leaves open, and
the deep-dives that carry it.

### Q1. Pixel and memory model

**Evidence.** Three designs cover the image cases between them: an N-D view with
per-axis strides ([Halide][halide-1], [mir-algorithm][mir-1], [VIGRA][vigra-1]), a
multi-plane 2-D buffer with per-plane strides and subsampling ([Wuffs][wuffs-1],
[libavif][libavif-1]) and a block grid for GPU textures ([KTX-Software][ktx-1],
[basis_universal][basis-1]). The [Slice experiment][slice-exp-c] verified that mir's
three `SliceKind`s map onto tight images, padded rows and crops, and transposes or
single channels, and that 4:2:0 with independent pitches is three `Canonical` slices
over one owner. It also verified the three counterpoints: no pixel-typed view for a
byte pitch that is not a multiple of the pixel size, no owner, and bounds checks that
vanish in release builds. [CICP][cicp-1] adds that a YCbCr view needs matrix, range
and chroma location, which a bare strided view does not carry.

**Open.** Element or byte strides; one N-D view with planes as separate views, or a
plane-group type; whether the block grid shares the pixel view's type; where the
runtime descriptor (format, alpha, colour) lives beside the view.

**Carried by** [mir-algorithm][mir-l], the [Slice experiment][slice-exp],
[Halide][halide-l], [Wuffs][wuffs-l], [libavif][libavif-l], [Boost.GIL][gil-l],
[VIGRA][vigra-l], [KTX-Software][ktx-l], [basis_universal][basis-l], [DLPack][dlpack-1].

### Q2. Generic interfaces in D

**Evidence.** Design by introspection already works for image views in D:
[ae.utils.graphics][ae-2] propagates optional primitives through adapters and proves
them with `static assert`, and [Dplug][dplug-2] reuses the trait triple. The [Slice
experiment][slice-exp-c] compiled non-template `@safe pure nothrow @nogc` kernels over
`Slice` parameters with dip1000 on DMD and LDC, and found that lambdas reading other
planes allocate closures, so `@nogc` code needs functors. [Boost.GIL][gil-l] shows D
avoids most of GIL's proxy machinery with `opIndex` and `opIndexAssign` (verified
planar view `@safe pure nothrow @nogc`). Cross-language ideas that transfer:
capability-as-data checked before and after an operation ([zune-image][zune-2]),
closed run-time variants over a small canonical set ([image-rs][imagers-l],
[JuliaImages][julia-l]), and run-time capability queries for device features
([Vulkan transfer][vk-2]).

**Open.** Which capabilities are traits; whether the codec boundary returns a SumType
or a runtime descriptor; how much instantiation the build tolerates (no deep-dive
measured D object size).

**Carried by** [ae.utils.graphics][ae-l], [Dplug][dplug-l], [Boost.GIL][gil-l],
[zune-image][zune-l], [image-rs][imagers-l], [JuliaImages][julia-l],
[ImageSharp][isharp-l], [mir-algorithm][mir-2].

### Q3. Generic algorithms that stay fast

**Evidence.** Lazy composition is free when it inlines: [ae.utils.graphics][ae-7]
compiles a double `hflip` to the same code as direct indexing (verified), and the [Slice
experiment][slice-exp-c] matched hand loops byte for byte with `map`, `vmap` and
`windows`. Vectorisation is not free: the idiomatic `windows` blur stays scalar under
`checked` (verified). Algorithm/schedule separation is [Halide][halide-7]'s answer; the
row-kernel-over-plane-loop split is [libyuv][libyuv-7]'s and [ImageSharp][isharp-7]'s;
[Skia][skia-7]'s raster pipeline handles the format product with runtime stage lists
over portable per-ISA source. One dispatch facility for all kernels is the lesson of
[OpenEXR][openexr-l], [Skia][skia-l], [Wuffs][wuffs-l] and [Simd][simd-l]; batch
conversion has to be designed in ([color][color-l]).

**Open.** Whether a schedule is an explicit object or a template parameter; whether
kernels are row functions or whole-view functions; how far `@target` plus a scalar
reference goes before a portable vector layer is needed.

**Carried by** [Halide][halide-l], [Highway][highway-l], [libyuv][libyuv-l],
[Skia][skia-l], [ImageSharp][isharp-l], [ae.utils.graphics][ae-l], the [Slice
experiment][slice-exp].

### Q4. Codec architecture

**Evidence.** Suspendable decoding over caller buffers is [Wuffs][wuffs-4]'s design,
verified byte-at-a-time equal to whole-buffer decode; push state machines
([libjxl][libjxl-4], [libwebp][libwebp-4]) and pull with "would block"
([libavif][libavif-4]) are the alternatives, with measured replay costs. Hostile-input
safety comes from checking before allocating, a limits record ([libheif][libheif-5])
and continuous fuzzing ([Hostile input](#_5-hostile-input-and-safety)). For
`sparkles:wired`, the deep-dives name what a binary description must express: the
RIFF chunk grammar ([libwebp][libwebp-l]), the ISOBMFF item graph ([libavif][libavif-l]),
KTX2 and `.basis` containers with DFD and key-value data ([basis_universal][basis-l]),
PNG chunk ordering and multiplicity as a table ([libpng][libpng-4]), TIFF's runtime
byte order and offset width ([libtiff][libtiff-l]), Exif maker notes with nested base
offsets ([Exiv2][exiv2-l]), compile-time packed bit layouts ([color][color-4]) and
zero-copy layout views ([ae.utils.graphics][ae-l]). The [wired baseline][bl-wired-g]
records that Flat as drafted has no bit reader (G2), no short-read status (G3), no
range checksums (G4) and no runtime byte order or 64-bit offsets (G5). The [wired
experiment][wired-fit] put PNG, QOI and ISOBMFF framing against Flat and shipped wired:
the shipped schema covers fixed records with checks, Flat would add length-prefixed
members and per-tag dispatch, and neither covers range checksums, references by ID,
suspension or caller budgets on derived values; its [requirements][wired-req] are
`IMW1` to `IMW25`.

**Open.** Which suspension form; whether bit-level reading belongs to `sparkles:wired`
or to the codec layer; whether container parsing is shared between metadata and pixel
codecs ([Exiv2][exiv2-l] argues it must be).

**Carried by** [Wuffs][wuffs-l], [libjxl][libjxl-l], [libwebp][libwebp-l],
[libavif][libavif-l], [libpng][libpng-l], [libspng][libspng-l], [libheif][libheif-l],
[OpenEXR][openexr-l], [libtiff][libtiff-l], [basis_universal][basis-l], the [wired
experiment][wired-fit].

### Q5. Colour, HDR and metadata

**Evidence.** The minimum the field carries is CICP as four stored integers
([CICP][cicp-5]), ICC as bytes with a parsed summary ([ICC][icc-3], skcms inside
[Skia][skia-3]), an alpha state ([Wuffs][wuffs-3], [ImageSharp][isharp-3]), an EXIF
orientation ([image-rs][imagers-3], [Skia][skia-3]) and opaque EXIF and XMP ranges.
HDR adds PQ and HLG transfer functions with a reference white ([Skia][skia-3]),
mastering-display and content-light-level values that travel beside CICP
([CICP][cicp-3]), and a gain-map record ([gain maps][gainmaps-3], applied in linear
light). Full colour management is separable ([Little CMS 2][lcms2-l],
[OpenColorIO][ocio-l]); a separate metadata model is [ExifTool][exiftool-l]'s and
[Exiv2][exiv2-l]'s.

**Open.** Whether colour lives in the pixel type ([JuliaImages][julia-3],
[VIGRA][vigra-3]) or in a descriptor ([Skia][skia-3], [Wuffs][wuffs-3]); whether a CMS
is bound (lcms2) or written; how much of EXIF and XMP is parsed.

**Carried by** [Skia][skia-l], [Wuffs][wuffs-l], [CICP][cicp-l], [ICC][icc-l],
[gain maps][gainmaps-l], [Little CMS 2][lcms2-l], [ImageSharp][isharp-l],
[image-rs][imagers-l], [ExifTool][exiftool-l], [Exiv2][exiv2-l], [color][color-l].

### Q6. File to GPU

**Evidence.** On Linux, a page-aligned slab registered with `io_uring` and imported
with `VK_EXT_external_memory_host` gives file reads straight into Vulkan-copyable
memory on RADV and llvmpipe ([io_uring storage][iouring-l]); `vkMapMemory` memory
cannot be registered on RADV; and the binding's multi-buffer `registerBuffers`
registers only the first slot, so registered-buffer measurements need that fix first.
[Vulkan transfer][vk-l] shows no single path covers the device matrix, so the path is
chosen from queried facts. GPU decompression replaces CPU inflate, not upload, runs
only on graphics or compute queues, and is NVIDIA-only on the matrix ([Vulkan
transfer][vk-8]). [DirectStorage][dstorage-l] argues that the unit is a request sized to
a staging buffer and decodable alone, which monolithic PNG `IDAT` does not give;
[KTX-Software][ktx-l]'s level index is already such a request list. Format negotiation
at load ([Filament][filament-l], [basis_universal][basis-l]) decides between BC7,
ASTC, ETC2 and RGBA8.

**Open.** Whether the read-into-importable-slab logic sits with event-horizon or the
Vulkan layer; whether a separate external-memory type is introduced; how a GPU
completion reaches the loop (timeline semaphore or pollable fence).

**Carried by** [io_uring storage][iouring-l], [Vulkan transfer][vk-l],
[DirectStorage][dstorage-l], [KTX-Software][ktx-l], [Skia][skia-l],
[nvImageCodec][nvimgcodec-l], the [Tier C digest][tc-gds].

### Q7. SIMD versus GPU compute

**Evidence.** No deep-dive measured a break-even. The evidence is indirect: measured
SIMD gains are uneven ([zune-image][zune-7], [Simd][simd-7]); [libjpeg-turbo][ljt-l]
names IDCT, upsampling and colour conversion as GPU candidates and Huffman as not;
[GDeflate][dstorage-7] reshapes an entropy bitstream into coarse tiles for threads and
32-way interleave for lanes; [nvImageCodec][nvimgcodec-7] balances GPU and CPU by
measured idle time instead of a cost model. What the two kernel forms share:
[OpenColorIO][ocio-l] validates every GPU op against its CPU path with one kernel
signature over packed RGBA float rows, and the [gain-map apply][gainmaps-l] is a
natural first kernel with both forms.

**Open.** Where break-even lies for each kernel class; whether kernels share one source
between host SIMD and SPIR-V; how a test harness times both.

**Carried by** [Highway][highway-l], [Simd][simd-l], [zune-image][zune-l],
[libjpeg-turbo][ljt-l], [OpenColorIO][ocio-l], [Halide][halide-l],
[DirectStorage][dstorage-l], [nvImageCodec][nvimgcodec-l], [dcompute][dcompute-l].

### Q8. Correctness

**Evidence.** The strongest oracles are external corpora with tolerances
([libjxl][libjxl-10]), differential tests against another decoder
([libspng][libspng-10], [Wuffs][wuffs-10], [zune-image][zune-10]), path-equivalence
tests across SIMD targets and decode modes ([Highway][highway-10],
[libyuv][libyuv-10], [Skia][skia-10], [libwebp][libwebp-10]) and tolerant image
comparison ([OpenImageIO][oiio-10]). Free oracles named by the deep-dives: CICP tables
checked exhaustively against libavif, dav1d and FFmpeg ([CICP][cicp-10]); ExifTool's
expected outputs as a metadata corpus ([ExifTool][exiftool-10]); two QOI decoders as
independent oracles ([QOI][tc-qoi]); Wuffs' ETC2 decoder for texture blocks
([Wuffs][wuffs-8]). Allocation-bomb and truncation corpora are what the field's
failures argue for ([Hostile input](#_5-hostile-input-and-safety)).

**Open.** Which corpora are pinned as flake inputs; exactness or a stated tolerance per
kernel; where the image oracle package sits.

**Carried by** [libjxl][libjxl-l], [libspng][libspng-l], [Wuffs][wuffs-l],
[Highway][highway-l], [libyuv][libyuv-l], [OpenImageIO][oiio-l], [CICP][cicp-l],
[ExifTool][exiftool-l], [Simd][simd-l], [Boost.GIL][gil-l].

### Q9. Package boundaries

Evidence only; the decision is not made here.

**For a split along dependency lines.** [ae.utils.graphics][ae-l], [dcv][dcv-l],
[Dplug][dplug-l] and the [arsd modules][arsd-l] (the D precedents) all split core from
codecs by external dependency. [zune-image][zune-l] publishes one crate per codec over a
tiny core; [Go][go-l] registers codecs into a codec-free core; [SAIL][sail-l],
[OpenCV][opencv-l], [ITK][itk-l] and [ROS][ros-l] separate types, codecs and
operations. [libyuv][libyuv-l] and [Simd][simd-l] show pixel operations standing apart
from formats; [libspng][libspng-l] shows a PNG codec needs only a row sink, not an
image-core package. Colour management is separable ([Little CMS 2][lcms2-l],
[ICC][icc-l], [OpenColorIO][ocio-l]); a dependency-free CICP type belongs in the
smallest shared package ([CICP][cicp-l]); the gain-map record goes with colour metadata
([gain maps][gainmaps-l]).

**Against a split, or for fewer pieces.** [libvips][vips-l] does not demonstrate an
independent engine package, and [OpenImageIO][oiio-l]'s algorithms cannot be separated
from I/O because its buffer reads lazily. [Boost.GIL][gil-l]'s algorithms migrated into
core over time. [JuliaImages][julia-l]'s fine-grained split costs compatibility pinning.
[Gamut][gamut-l] keeps one package and selects codecs by build configuration.

**What the unsplit option grows into.** [CImg][cimg-l] (one 71,779-line header with
container, algorithms, codecs, display and an expression language) and
[VIGRA][vigra-l] (container, codecs, colour, algorithms, graph and ML in one library).

**Build-mode constraints.** Static initialisers and dynamic loading conflict with
`-betterC`, wasm and Android ([Skia][skia-l], [ITK][itk-l], [Simd][simd-l],
[Highway][highway-l]); the [Slice experiment][slice-exp-c] verified mir kernels under
`-betterC` (LDC; DMD without `Vector`) and as wasm32 modules, the latter only when
mir's own modules are not compiled, so not through dub, and records that
mir is in neither Nix dub lock. SIMD dispatch is a base-layer concern below any image
package ([Highway][highway-l], [intel-intrinsics][intel-l]); the importable-slab logic
belongs with I/O and GPU packages, not image core ([io_uring storage][iouring-l]);
dma-buf belongs in a Linux-only module ([Vulkan transfer][vk-l]); DLPack is a thin
optional module over the view ([DLPack][dlpack-l], [NumPy][numpy-l]).

**Carried by** every deep-dive's Q9 lesson; the densest are [zune-image][zune-l],
[Skia][skia-l], [OpenCV][opencv-l], [Go][go-l], [CImg][cimg-l] and the [Slice
experiment][slice-exp].

## Delta against the baseline

Each capability the field has, mapped to where Sparkles stands. Status values follow
the baseline documents: **shipped** (code on this branch), **specified** (accepted
spec text), **draft** (unmerged branch or draft spec), **planned** (named in a plan
only), **absent** (nothing found). Gap IDs are the "Gaps and tensions" entries of the
baseline document named in the same row.

| Capability                                       | Field evidence                                                           | Sparkles status                                                        | Baseline and gap                                                 |
| ------------------------------------------------ | ------------------------------------------------------------------------ | ---------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Strided 2-D pixel view                           | [Skia][skia-1], [Wuffs][wuffs-1], [Simd][simd-1]                         | absent (flat `ImageData.rgba`, `ColourRegion` data plus stride)        | [existing code][bl-existing-g] G2                                |
| N-D strided view                                 | [mir-algorithm][mir-1], [VIGRA][vigra-1], [Halide][halide-1]             | absent (guideline recommends `mir.ndslice`; no `mir` dependency)       | [existing code][bl-existing-g] G2; [shaders][bl-shaders-g] G10   |
| Planar and subsampled YCbCr planes               | [libavif][libavif-1], [Wuffs][wuffs-1], [libwebp][libwebp-1]             | absent                                                                 | [existing code][bl-existing-g] G2; [Vulkan][bl-vk-g] G1          |
| Sample types beyond 8-bit                        | [OpenImageIO][oiio-1], [OpenEXR][openexr-1], [libjxl][libjxl-1]          | absent (`ui.png` drops 16-bit to the high byte)                        | [existing code][bl-existing-g] G4; [shaders][bl-shaders-g] G3    |
| Declared alpha state                             | [Wuffs][wuffs-3], [ImageSharp][isharp-3]                                 | shipped, split convention (premultiplied glyphs, straight registry)    | [existing code][bl-existing-g] G3                                |
| Header-only probe before decode                  | [Wuffs][wuffs-4], [image-rs][imagers-4], [Go][go-4]                      | draft (`pngHeader` in `sparkles:image` on `refactor/image-png`)        | [existing code][bl-existing] DRAFT; G1                           |
| Decode into caller storage                       | [libspng][libspng-6], [Wuffs][wuffs-6], [OpenEXR][openexr-6]             | shipped (`font.png`, limited forms); draft (`sparkles:image`)          | [existing code][bl-existing-g] G1, G6                            |
| Suspendable or incremental decode                | [Wuffs][wuffs-4], [libjxl][libjxl-4], [libavif][libavif-4]               | absent (both decoders whole-file, single-shot)                         | [existing code][bl-existing-g] G7; [wired][bl-wired-g] G3        |
| Decoder as a resumable state machine             | [Wuffs][wuffs-6]                                                         | absent; started fibers are pinned, so a plain struct is required       | [event-horizon][bl-eh-g] G6                                      |
| Bit-granular reader                              | [Wuffs][wuffs-4], [libjxl][libjxl-4]                                     | absent; Flat excludes it                                               | [wired][bl-wired-g] G2                                           |
| Binary description of container formats          | [libwebp][libwebp-l], [libavif][libavif-l], [basis_universal][basis-l]   | draft (Flat `WFL1`-`WFL56`, OpenType acceptance set only)              | [wired][bl-wired-g] G1, G5, G6, G15                              |
| Chunk CRC and checksum verification              | [Wuffs][wuffs-5], [libpng][libpng-5]                                     | absent (both PNG decoders skip CRCs)                                   | [wired][bl-wired-g] G4                                           |
| Caller-set limits record                         | [libheif][libheif-5], [libavif][libavif-5]                               | shipped, narrow (`maxPngPixels`; font `FTB3` fixed limits)             | [wired][bl-wired-g] G8; [existing code][bl-existing-g] G7        |
| Work budget against amplification                | [libheif][libheif-5], [libjpeg-turbo][ljt-5]                             | draft (Flat `traversalBytes`, font-shaped)                             | [wired][bl-wired-g] G8, G17                                      |
| Fuzz harnesses in CI                             | [libwebp][libwebp-10], [libspng][libspng-10], [libheif][libheif-10]      | absent; sanitizer and fuzzer runtimes `planned`                        | [existing code][bl-existing] PLANNED; G11                        |
| Crash isolation of hostile decodes               | [GDAL][gdal-5] (deployer sandboxing)                                     | shipped (`ForkServer`, serial, single-threaded start)                  | [event-horizon][bl-eh-g] G9                                      |
| Unified error type for codecs                    | [Wuffs][wuffs-4] (status strings), [libheif][libheif-5]                  | absent; error types fragment across packages                           | [wired][bl-wired-g] G9                                           |
| CICP and ICC carried                             | [libavif][libavif-3], [Skia][skia-3], [image-rs][imagers-3]              | absent (ancillary chunks skipped)                                      | [existing code][bl-existing-g] G4, G5; [wired][bl-wired-g] G15   |
| Colour management (ICC transforms)               | [Little CMS 2][lcms2-3], [Skia][skia-3]                                  | absent                                                                 | [existing code][bl-existing] PLANNED; [Vulkan][bl-vk-g] G10      |
| HDR transfer functions and gain maps             | [Skia][skia-3], [libavif][libavif-3], [gain maps][gainmaps-3]            | planned only for linear light (`UVX6`); HDR absent                     | [Vulkan][bl-vk-g] G10                                            |
| EXIF orientation and metadata report             | [image-rs][imagers-3], [ExifTool][exiftool-3]                            | specified as a template only (font-explorer `inspect`, not started)    | [existing code][bl-existing-g] G5                                |
| Animation frames with rectangle and disposal     | [Wuffs][wuffs-9], [Skia][skia-9], [libjxl][libjxl-9]                     | absent                                                                 | [existing code][bl-existing-g] G9, G14                           |
| Runtime SIMD dispatch, public                    | [Highway][highway-7], [OpenCV][opencv-7], [Wuffs][wuffs-7]               | shipped for text and BLAKE3 only, `package` visibility, x86 LDC        | [shaders][bl-shaders-g] G5; [existing code][bl-existing-g] G13   |
| Scalar reference forced by tests                 | [libyuv][libyuv-10], [Highway][highway-10], [zune-image][zune-7]         | shipped for BLAKE3 (every backend against `portable`)                  | [shaders][bl-shaders] capability table                           |
| Shared resampling and filter layer               | [libyuv][libyuv-l], [Simd][simd-7], [ImageSharp][isharp-7]               | shipped as two private copies (`sampleArea`, `rasterizeBitmapGlyph`)   | [existing code][bl-existing-g] G10                               |
| CPU offload pool for decode slices               | [libjxl][libjxl-7] (`JxlParallelRunner`)                                 | shipped three ways with different contracts                            | [event-horizon][bl-eh-g] G5, G7, G12                             |
| Ranged reads with bounded reads in flight        | [OpenImageIO][oiio-l] (`IOProxy`), [GDAL][gdal-4]                        | absent (offset `OpRead` only)                                          | [event-horizon][bl-eh-g] G1                                      |
| Registered buffers                               | [io_uring storage][iouring-6]                                            | shipped (`BufferPool`); multi-slot registration registers one slot     | [event-horizon][bl-eh] capability table                          |
| `O_DIRECT` and mapped files                      | [io_uring storage][iouring-l], [libtiff][libtiff-4]                      | absent; mapped-file byte source planned (Flat O1)                      | [event-horizon][bl-eh-g] G3; [wired][bl-wired-g] G14             |
| Host-pointer import into Vulkan                  | [io_uring storage][iouring-8], [Vulkan transfer][vk-6]                   | absent; allocator cannot hold imported regions (`VKM3`)                | [Vulkan][bl-vk-g] G6; [event-horizon][bl-eh-g] G4                |
| dma-buf and DRM modifiers                        | [Vulkan transfer][vk-8]                                                  | absent (extensions present locally, not bound)                         | [Vulkan][bl-vk] capability table                                 |
| Strided, sub-image, layered and mip upload       | [Vulkan transfer][vk-1], [KTX-Software][ktx-8]                           | shipped for tight RGBA8 and R8 only                                    | [Vulkan][bl-vk-g] G1; [existing code][bl-existing-g] G8          |
| Transfer queue and timeline semaphores           | [Vulkan transfer][vk-l], [nvImageCodec][nvimgcodec-l]                    | absent (one graphics queue, binary semaphores)                         | [Vulkan][bl-vk-g] G3, G4                                         |
| GPU completion to event loop                     | [DirectStorage][dstorage-8], [Metal][tc-metal]                           | planned (a `dispatch.d` comment on a pollable `sync_fd`)               | [Vulkan][bl-vk-g] G5                                             |
| YCbCr sampler conversion                         | [Vulkan transfer][vk-3], [CICP][cicp-8]                                  | absent (core 1.1, not bound)                                           | [Vulkan][bl-vk] capability table; G10                            |
| Block-compressed textures (KTX2, Basis)          | [KTX-Software][ktx-1], [basis_universal][basis-8], [glTF][gltf-8]        | absent                                                                 | [existing code][bl-existing] capability table                    |
| GPU decompression                                | [Vulkan transfer][vk-8], [DirectStorage][dstorage-8]                     | absent (declared in the header, advertised by no local device)         | [Vulkan][bl-vk] capability table                                 |
| Compute pipelines and storage images             | [Halide][halide-8], [OpenColorIO][ocio-8]                                | specified (shaders M10), not started; commands not bound               | [shaders][bl-shaders-g] G1, G9; [Vulkan][bl-vk-g] G7             |
| Device format and limit queries                  | [Vulkan transfer][vk-2], [KTX-Software][ktx-l]                           | shipped partly (`GetPhysicalDeviceFormatProperties`, `maxImageExtent`) | [Vulkan][bl-vk-g] G13                                            |
| GPU timing for break-even                        | none measured in the field                                               | absent                                                                 | [shaders][bl-shaders-g] G7                                       |
| Decoder differential oracle                      | [libspng][libspng-10], [Wuffs][wuffs-10]                                 | shipped for PNG only (`png_oracle.d`, stb_image over PngSuite)         | [existing code][bl-existing-g] G11                               |
| Tolerant image comparison                        | [OpenImageIO][oiio-10], [ImageSharp][isharp-10]                          | absent (golden screenshots compare bytes)                              | [existing code][bl-existing-g] G11                               |
| Exact oracle for 8-bit GPU kernels               | [OpenColorIO][ocio-10] (tolerance), [libyuv][libyuv-3]                   | absent (agreement oracle calibrated for float shading)                 | [shaders][bl-shaders-g] G8                                       |
| DLPack export                                    | [DLPack][dlpack-l], [nvImageCodec][nvimgcodec-6]                         | absent                                                                 | [existing code][bl-existing-g] G14                               |
| `-betterC`, wasm and Android reach of codec core | [Wuffs][wuffs-6], [zune-image][zune-10], [Slice experiment][slice-exp-c] | unverified for image code; event-horizon tier A betterC planned (O3)   | [existing code][bl-existing-g] G12; [event-horizon][bl-eh-g] G13 |

## Sources

- The 58 deep-dives linked above, each citing the source files and documents it read
  at the revision in [`sources.tsv`][sources-tsv]; this page reads them, and where a
  claim carries weight it was re-read in the deep-dive's own analysis section.
- The [Slice experiment][slice-exp], whose verified results this page quotes for Q1,
  Q2, Q3, Q7 and Q9, and the [wired experiment][wired-fit] with its
  [requirements][wired-req], which it quotes for Q4.
- The five baseline documents: [wired][bl-wired], [event-horizon][bl-eh],
  [Vulkan][bl-vk], [shaders and SIMD][bl-shaders] and [existing code][bl-existing].
- The [Concepts][concepts] page for every term, the [umbrella][catalog] for the
  questions and the spine, and the [hardware matrix][hw] for per-device facts.

<!-- References -->

[ae]: ./ae-graphics.md
[ae-10]: ./ae-graphics.md#_10-testing-and-conformance
[ae-2]: ./ae-graphics.md#_2-genericity-mechanism
[ae-6]: ./ae-graphics.md#_6-allocation-and-ownership
[ae-7]: ./ae-graphics.md#_7-cpu-parallelism-and-simd
[ae-l]: ./ae-graphics.md#lessons-for-sparkles
[arsd-1]: ./arsd-image.md#_1-pixel-and-memory-model
[arsd-l]: ./arsd-image.md#lessons-for-sparkles
[basis]: ./basis-universal.md
[basis-1]: ./basis-universal.md#_1-pixel-and-memory-model
[basis-8]: ./basis-universal.md#_8-gpu-offload-and-interop
[basis-l]: ./basis-universal.md#lessons-for-sparkles
[bl-eh]: ./baseline/event-horizon.md
[bl-eh-g]: ./baseline/event-horizon.md#gaps-and-tensions
[bl-existing]: ./baseline/existing-code.md
[bl-existing-g]: ./baseline/existing-code.md#gaps-and-tensions
[bl-index]: ./index.md#sparkles-baseline
[bl-shaders]: ./baseline/shaders-simd.md
[bl-shaders-g]: ./baseline/shaders-simd.md#gaps-and-tensions
[bl-vk]: ./baseline/vulkan.md
[bl-vk-g]: ./baseline/vulkan.md#gaps-and-tensions
[bl-wired]: ./baseline/wired.md
[bl-wired-g]: ./baseline/wired.md#gaps-and-tensions
[c-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[catalog]: ./index.md#master-catalog
[c-block]: ./concepts.md#block-compressed-formats-and-supercompression
[c-chroma]: ./concepts.md#chroma-subsampling
[c-cicp]: ./concepts.md#cicp
[c-gain]: ./concepts.md#hdr-gain-map
[c-icc]: ./concepts.md#icc-profile
[cicp-1]: ./cicp.md#_1-pixel-and-memory-model
[cicp-10]: ./cicp.md#_10-testing-and-conformance
[cicp-3]: ./cicp.md#_3-colour-and-metadata
[cicp-5]: ./cicp.md#_5-hostile-input-and-safety
[cicp-8]: ./cicp.md#_8-gpu-offload-and-interop
[cicp-l]: ./cicp.md#lessons-for-sparkles
[cimg-1]: ./cimg.md#_1-pixel-and-memory-model
[cimg-l]: ./cimg.md#lessons-for-sparkles
[c-interleave]: ./concepts.md#interleaved-planar-and-semi-planar
[color]: ./color.md
[color-3]: ./color.md#_3-colour-and-metadata
[color-4]: ./color.md#_4-i-o-and-codec-architecture
[color-l]: ./color.md#lessons-for-sparkles
[c-plane]: ./concepts.md#plane
[c-schedule]: ./concepts.md#algorithm-and-schedule
[c-stride]: ./concepts.md#stride
[c-suspend]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[c-transfer]: ./concepts.md#transfer-function
[c-view]: ./concepts.md#image-and-view
[dcompute-10]: ./dcompute.md#_10-testing-and-conformance
[dcompute-8]: ./dcompute.md#_8-gpu-offload-and-interop
[dcompute-l]: ./dcompute.md#lessons-for-sparkles
[dcv]: ./dcv.md
[dcv-1]: ./dcv.md#_1-pixel-and-memory-model
[dcv-10]: ./dcv.md#_10-testing-and-conformance
[dcv-3]: ./dcv.md#_3-colour-and-metadata
[dcv-7]: ./dcv.md#_7-cpu-parallelism-and-simd
[dcv-l]: ./dcv.md#lessons-for-sparkles
[dlpack-1]: ./dlpack.md#_1-pixel-and-memory-model
[dlpack-5]: ./dlpack.md#_5-hostile-input-and-safety
[dlpack-l]: ./dlpack.md#lessons-for-sparkles
[dplug-1]: ./dplug-graphics.md#_1-pixel-and-memory-model
[dplug-2]: ./dplug-graphics.md#_2-genericity-mechanism
[dplug-7]: ./dplug-graphics.md#_7-cpu-parallelism-and-simd
[dplug-l]: ./dplug-graphics.md#lessons-for-sparkles
[dstorage-5]: ./directstorage-ioring.md#_5-hostile-input-and-safety
[dstorage-7]: ./directstorage-ioring.md#_7-cpu-parallelism-and-simd
[dstorage-8]: ./directstorage-ioring.md#_8-gpu-offload-and-interop
[dstorage-l]: ./directstorage-ioring.md#lessons-for-sparkles
[exiftool-10]: ./exiftool.md#_10-testing-and-conformance
[exiftool-3]: ./exiftool.md#_3-colour-and-metadata
[exiftool-l]: ./exiftool.md#lessons-for-sparkles
[exiv2-3]: ./exiv2.md#_3-colour-and-metadata
[exiv2-l]: ./exiv2.md#lessons-for-sparkles
[filament-5]: ./filament-bgfx-textures.md#_5-hostile-input-and-safety
[filament-8]: ./filament-bgfx-textures.md#_8-gpu-offload-and-interop
[filament-l]: ./filament-bgfx-textures.md#lessons-for-sparkles
[gainmaps-3]: ./gain-maps.md#_3-colour-and-metadata
[gainmaps-l]: ./gain-maps.md#lessons-for-sparkles
[gamut-1]: ./gamut.md#_1-pixel-and-memory-model
[gamut-5]: ./gamut.md#_5-hostile-input-and-safety
[gamut-6]: ./gamut.md#_6-allocation-and-ownership
[gamut-l]: ./gamut.md#lessons-for-sparkles
[gdal-4]: ./gdal.md#_4-i-o-and-codec-architecture
[gdal-5]: ./gdal.md#_5-hostile-input-and-safety
[gdal-l]: ./gdal.md#lessons-for-sparkles
[gil]: ./boost-gil.md
[gil-1]: ./boost-gil.md#_1-pixel-and-memory-model
[gil-10]: ./boost-gil.md#_10-testing-and-conformance
[gil-2]: ./boost-gil.md#_2-genericity-mechanism
[gil-3]: ./boost-gil.md#_3-colour-and-metadata
[gil-4]: ./boost-gil.md#_4-i-o-and-codec-architecture
[gil-5]: ./boost-gil.md#_5-hostile-input-and-safety
[gil-l]: ./boost-gil.md#lessons-for-sparkles
[gltf-8]: ./gltf-textures.md#_8-gpu-offload-and-interop
[go-1]: ./go-image.md#_1-pixel-and-memory-model
[go-10]: ./go-image.md#_10-testing-and-conformance
[go-3]: ./go-image.md#_3-colour-and-metadata
[go-4]: ./go-image.md#_4-i-o-and-codec-architecture
[go-5]: ./go-image.md#_5-hostile-input-and-safety
[go-6]: ./go-image.md#_6-allocation-and-ownership
[godot-3]: ./godot-texture-import.md#_3-colour-and-metadata
[godot-5]: ./godot-texture-import.md#_5-hostile-input-and-safety
[go-l]: ./go-image.md#lessons-for-sparkles
[halide]: ./halide.md
[halide-1]: ./halide.md#_1-pixel-and-memory-model
[halide-6]: ./halide.md#_6-allocation-and-ownership
[halide-7]: ./halide.md#_7-cpu-parallelism-and-simd
[halide-8]: ./halide.md#_8-gpu-offload-and-interop
[halide-l]: ./halide.md#lessons-for-sparkles
[highway]: ./highway.md
[highway-10]: ./highway.md#_10-testing-and-conformance
[highway-7]: ./highway.md#_7-cpu-parallelism-and-simd
[highway-l]: ./highway.md#lessons-for-sparkles
[hw]: ./hardware/index.md
[icc-3]: ./icc.md#_3-colour-and-metadata
[icc-l]: ./icc.md#lessons-for-sparkles
[imagers]: ./image-rs.md
[imagers-1]: ./image-rs.md#_1-pixel-and-memory-model
[imagers-10]: ./image-rs.md#_10-testing-and-conformance
[imagers-2]: ./image-rs.md#_2-genericity-mechanism
[imagers-3]: ./image-rs.md#_3-colour-and-metadata
[imagers-4]: ./image-rs.md#_4-i-o-and-codec-architecture
[imagers-5]: ./image-rs.md#_5-hostile-input-and-safety
[imagers-6]: ./image-rs.md#_6-allocation-and-ownership
[imagers-9]: ./image-rs.md#_9-temporal-animation-and-containers
[imagers-l]: ./image-rs.md#lessons-for-sparkles
[intel-7]: ./intel-intrinsics.md#_7-cpu-parallelism-and-simd
[intel-l]: ./intel-intrinsics.md#lessons-for-sparkles
[iouring-1]: ./io-uring-storage.md#_1-pixel-and-memory-model
[iouring-6]: ./io-uring-storage.md#_6-allocation-and-ownership
[iouring-8]: ./io-uring-storage.md#_8-gpu-offload-and-interop
[iouring-l]: ./io-uring-storage.md#lessons-for-sparkles
[isharp]: ./imagesharp.md
[isharp-10]: ./imagesharp.md#_10-testing-and-conformance
[isharp-2]: ./imagesharp.md#_2-genericity-mechanism
[isharp-3]: ./imagesharp.md#_3-colour-and-metadata
[isharp-4]: ./imagesharp.md#_4-i-o-and-codec-architecture
[isharp-6]: ./imagesharp.md#_6-allocation-and-ownership
[isharp-7]: ./imagesharp.md#_7-cpu-parallelism-and-simd
[isharp-9]: ./imagesharp.md#_9-temporal-animation-and-containers
[isharp-l]: ./imagesharp.md#lessons-for-sparkles
[itk]: ./itk.md
[itk-1]: ./itk.md#_1-pixel-and-memory-model
[itk-10]: ./itk.md#_10-testing-and-conformance
[itk-3]: ./itk.md#_3-colour-and-metadata
[itk-4]: ./itk.md#_4-i-o-and-codec-architecture
[itk-5]: ./itk.md#_5-hostile-input-and-safety
[itk-7]: ./itk.md#_7-cpu-parallelism-and-simd
[itk-9]: ./itk.md#_9-temporal-animation-and-containers
[itk-l]: ./itk.md#lessons-for-sparkles
[julia]: ./juliaimages.md
[julia-2]: ./juliaimages.md#_2-genericity-mechanism
[julia-3]: ./juliaimages.md#_3-colour-and-metadata
[julia-6]: ./juliaimages.md#_6-allocation-and-ownership
[julia-7]: ./juliaimages.md#_7-cpu-parallelism-and-simd
[julia-9]: ./juliaimages.md#_9-temporal-animation-and-containers
[julia-l]: ./juliaimages.md#lessons-for-sparkles
[ktx]: ./ktx-software.md
[ktx-1]: ./ktx-software.md#_1-pixel-and-memory-model
[ktx-10]: ./ktx-software.md#_10-testing-and-conformance
[ktx-4]: ./ktx-software.md#_4-i-o-and-codec-architecture
[ktx-5]: ./ktx-software.md#_5-hostile-input-and-safety
[ktx-8]: ./ktx-software.md#_8-gpu-offload-and-interop
[ktx-9]: ./ktx-software.md#_9-temporal-animation-and-containers
[ktx-l]: ./ktx-software.md#lessons-for-sparkles
[lcms2]: ./lcms2.md
[lcms2-2]: ./lcms2.md#_2-genericity-mechanism
[lcms2-3]: ./lcms2.md#_3-colour-and-metadata
[lcms2-7]: ./lcms2.md#_7-cpu-parallelism-and-simd
[lcms2-l]: ./lcms2.md#lessons-for-sparkles
[libavif]: ./libavif.md
[libavif-1]: ./libavif.md#_1-pixel-and-memory-model
[libavif-3]: ./libavif.md#_3-colour-and-metadata
[libavif-4]: ./libavif.md#_4-i-o-and-codec-architecture
[libavif-5]: ./libavif.md#_5-hostile-input-and-safety
[libavif-9]: ./libavif.md#_9-temporal-animation-and-containers
[libavif-l]: ./libavif.md#lessons-for-sparkles
[libheif-1]: ./libheif.md#_1-pixel-and-memory-model
[libheif-10]: ./libheif.md#_10-testing-and-conformance
[libheif-3]: ./libheif.md#_3-colour-and-metadata
[libheif-4]: ./libheif.md#_4-i-o-and-codec-architecture
[libheif-5]: ./libheif.md#_5-hostile-input-and-safety
[libheif-6]: ./libheif.md#_6-allocation-and-ownership
[libheif-9]: ./libheif.md#_9-temporal-animation-and-containers
[libheif-l]: ./libheif.md#lessons-for-sparkles
[libjxl]: ./libjxl.md
[libjxl-1]: ./libjxl.md#_1-pixel-and-memory-model
[libjxl-10]: ./libjxl.md#_10-testing-and-conformance
[libjxl-2]: ./libjxl.md#_2-genericity-mechanism
[libjxl-4]: ./libjxl.md#_4-i-o-and-codec-architecture
[libjxl-5]: ./libjxl.md#_5-hostile-input-and-safety
[libjxl-6]: ./libjxl.md#_6-allocation-and-ownership
[libjxl-7]: ./libjxl.md#_7-cpu-parallelism-and-simd
[libjxl-9]: ./libjxl.md#_9-temporal-animation-and-containers
[libjxl-l]: ./libjxl.md#lessons-for-sparkles
[libpng]: ./libpng.md
[libpng-1]: ./libpng.md#_1-pixel-and-memory-model
[libpng-10]: ./libpng.md#_10-testing-and-conformance
[libpng-3]: ./libpng.md#_3-colour-and-metadata
[libpng-4]: ./libpng.md#_4-i-o-and-codec-architecture
[libpng-5]: ./libpng.md#_5-hostile-input-and-safety
[libpng-7]: ./libpng.md#_7-cpu-parallelism-and-simd
[libpng-8]: ./libpng.md#_8-gpu-offload-and-interop
[libpng-l]: ./libpng.md#lessons-for-sparkles
[libspng]: ./libspng.md
[libspng-10]: ./libspng.md#_10-testing-and-conformance
[libspng-4]: ./libspng.md#_4-i-o-and-codec-architecture
[libspng-5]: ./libspng.md#_5-hostile-input-and-safety
[libspng-6]: ./libspng.md#_6-allocation-and-ownership
[libspng-7]: ./libspng.md#_7-cpu-parallelism-and-simd
[libspng-l]: ./libspng.md#lessons-for-sparkles
[libtiff-4]: ./libtiff.md#_4-i-o-and-codec-architecture
[libtiff-5]: ./libtiff.md#_5-hostile-input-and-safety
[libtiff-7]: ./libtiff.md#_7-cpu-parallelism-and-simd
[libtiff-l]: ./libtiff.md#lessons-for-sparkles
[libwebp]: ./libwebp.md
[libwebp-1]: ./libwebp.md#_1-pixel-and-memory-model
[libwebp-10]: ./libwebp.md#_10-testing-and-conformance
[libwebp-3]: ./libwebp.md#_3-colour-and-metadata
[libwebp-4]: ./libwebp.md#_4-i-o-and-codec-architecture
[libwebp-5]: ./libwebp.md#_5-hostile-input-and-safety
[libwebp-7]: ./libwebp.md#_7-cpu-parallelism-and-simd
[libwebp-8]: ./libwebp.md#_8-gpu-offload-and-interop
[libwebp-l]: ./libwebp.md#lessons-for-sparkles
[libyuv-10]: ./libyuv.md#_10-testing-and-conformance
[libyuv-3]: ./libyuv.md#_3-colour-and-metadata
[libyuv-7]: ./libyuv.md#_7-cpu-parallelism-and-simd
[libyuv-l]: ./libyuv.md#lessons-for-sparkles
[ljt]: ./libjpeg-turbo.md
[ljt-1]: ./libjpeg-turbo.md#_1-pixel-and-memory-model
[ljt-10]: ./libjpeg-turbo.md#_10-testing-and-conformance
[ljt-3]: ./libjpeg-turbo.md#_3-colour-and-metadata
[ljt-4]: ./libjpeg-turbo.md#_4-i-o-and-codec-architecture
[ljt-5]: ./libjpeg-turbo.md#_5-hostile-input-and-safety
[ljt-7]: ./libjpeg-turbo.md#_7-cpu-parallelism-and-simd
[ljt-l]: ./libjpeg-turbo.md#lessons-for-sparkles
[mir]: ./mir-algorithm/
[mir-1]: ./mir-algorithm/#_1-pixel-and-memory-model
[mir-2]: ./mir-algorithm/#_2-genericity-mechanism
[mir-5]: ./mir-algorithm/#_5-hostile-input-and-safety
[mir-6]: ./mir-algorithm/#_6-allocation-and-ownership
[mir-7]: ./mir-algorithm/#_7-cpu-parallelism-and-simd
[mir-9]: ./mir-algorithm/#_9-temporal-animation-and-containers
[mir-l]: ./mir-algorithm/#lessons-for-sparkles
[numpy-1]: ./numpy-buffer-protocol.md#_1-pixel-and-memory-model
[numpy-l]: ./numpy-buffer-protocol.md#lessons-for-sparkles
[nvimgcodec-1]: ./nvimagecodec.md#_1-pixel-and-memory-model
[nvimgcodec-4]: ./nvimagecodec.md#_4-i-o-and-codec-architecture
[nvimgcodec-6]: ./nvimagecodec.md#_6-allocation-and-ownership
[nvimgcodec-7]: ./nvimagecodec.md#_7-cpu-parallelism-and-simd
[nvimgcodec-8]: ./nvimagecodec.md#_8-gpu-offload-and-interop
[nvimgcodec-l]: ./nvimagecodec.md#lessons-for-sparkles
[ocio-10]: ./opencolorio.md#_10-testing-and-conformance
[ocio-3]: ./opencolorio.md#_3-colour-and-metadata
[ocio-7]: ./opencolorio.md#_7-cpu-parallelism-and-simd
[ocio-8]: ./opencolorio.md#_8-gpu-offload-and-interop
[ocio-l]: ./opencolorio.md#lessons-for-sparkles
[oiio]: ./openimageio.md
[oiio-1]: ./openimageio.md#_1-pixel-and-memory-model
[oiio-10]: ./openimageio.md#_10-testing-and-conformance
[oiio-2]: ./openimageio.md#_2-genericity-mechanism
[oiio-4]: ./openimageio.md#_4-i-o-and-codec-architecture
[oiio-5]: ./openimageio.md#_5-hostile-input-and-safety
[oiio-7]: ./openimageio.md#_7-cpu-parallelism-and-simd
[oiio-l]: ./openimageio.md#lessons-for-sparkles
[opencv]: ./opencv.md
[opencv-1]: ./opencv.md#_1-pixel-and-memory-model
[opencv-2]: ./opencv.md#_2-genericity-mechanism
[opencv-4]: ./opencv.md#_4-i-o-and-codec-architecture
[opencv-5]: ./opencv.md#_5-hostile-input-and-safety
[opencv-6]: ./opencv.md#_6-allocation-and-ownership
[opencv-7]: ./opencv.md#_7-cpu-parallelism-and-simd
[opencv-8]: ./opencv.md#_8-gpu-offload-and-interop
[opencv-l]: ./opencv.md#lessons-for-sparkles
[openexr]: ./openexr.md
[openexr-1]: ./openexr.md#_1-pixel-and-memory-model
[openexr-4]: ./openexr.md#_4-i-o-and-codec-architecture
[openexr-5]: ./openexr.md#_5-hostile-input-and-safety
[openexr-6]: ./openexr.md#_6-allocation-and-ownership
[openexr-7]: ./openexr.md#_7-cpu-parallelism-and-simd
[openexr-l]: ./openexr.md#lessons-for-sparkles
[questions]: ./index.md#questions-this-survey-answers
[ros-5]: ./ros-image-transport.md#_5-hostile-input-and-safety
[ros-9]: ./ros-image-transport.md#_9-temporal-animation-and-containers
[ros-l]: ./ros-image-transport.md#lessons-for-sparkles
[sail-4]: ./sail.md#_4-i-o-and-codec-architecture
[sail-5]: ./sail.md#_5-hostile-input-and-safety
[sail-9]: ./sail.md#_9-temporal-animation-and-containers
[sail-l]: ./sail.md#lessons-for-sparkles
[simd]: ./simd.md
[simd-1]: ./simd.md#_1-pixel-and-memory-model
[simd-10]: ./simd.md#_10-testing-and-conformance
[simd-5]: ./simd.md#_5-hostile-input-and-safety
[simd-7]: ./simd.md#_7-cpu-parallelism-and-simd
[simd-l]: ./simd.md#lessons-for-sparkles
[skia]: ./skia.md
[skia-1]: ./skia.md#_1-pixel-and-memory-model
[skia-10]: ./skia.md#_10-testing-and-conformance
[skia-2]: ./skia.md#_2-genericity-mechanism
[skia-3]: ./skia.md#_3-colour-and-metadata
[skia-4]: ./skia.md#_4-i-o-and-codec-architecture
[skia-6]: ./skia.md#_6-allocation-and-ownership
[skia-7]: ./skia.md#_7-cpu-parallelism-and-simd
[skia-8]: ./skia.md#_8-gpu-offload-and-interop
[skia-9]: ./skia.md#_9-temporal-animation-and-containers
[skia-l]: ./skia.md#lessons-for-sparkles
[slice-exp]: ./mir-algorithm/slice-experiment.md
[slice-exp-c]: ./mir-algorithm/slice-experiment.md#conclusion-the-evidence
[slice-planar]: ./mir-algorithm/slice-experiment.md#planar-yuv-and-padded-strides
[slice-safety]: ./mir-algorithm/slice-experiment.md#safety-of-the-view
[spine]: ./index.md#analysis-spine
[stb-1]: ./stb-image.md#_1-pixel-and-memory-model
[stb-10]: ./stb-image.md#_10-testing-and-conformance
[stb-3]: ./stb-image.md#_3-colour-and-metadata
[stb-4]: ./stb-image.md#_4-i-o-and-codec-architecture
[stb-5]: ./stb-image.md#_5-hostile-input-and-safety
[stb-6]: ./stb-image.md#_6-allocation-and-ownership
[tc-gds]: ./tier-c-digest.md#nvidia-gpudirect-storage
[tc-metal]: ./tier-c-digest.md#metal-fast-resource-loading
[tc-nvcomp]: ./tier-c-digest.md#nvcomp-and-gdeflate
[tc-qoi]: ./tier-c-digest.md#qoi
[tierc]: ./tier-c-digest.md
[vigra]: ./vigra.md
[vigra-1]: ./vigra.md#_1-pixel-and-memory-model
[vigra-2]: ./vigra.md#_2-genericity-mechanism
[vigra-3]: ./vigra.md#_3-colour-and-metadata
[vigra-4]: ./vigra.md#_4-i-o-and-codec-architecture
[vigra-5]: ./vigra.md#_5-hostile-input-and-safety
[vigra-6]: ./vigra.md#_6-allocation-and-ownership
[vigra-7]: ./vigra.md#_7-cpu-parallelism-and-simd
[vigra-9]: ./vigra.md#_9-temporal-animation-and-containers
[vigra-l]: ./vigra.md#lessons-for-sparkles
[vips]: ./libvips.md
[vips-10]: ./libvips.md#_10-testing-and-conformance
[vips-2]: ./libvips.md#_2-genericity-mechanism
[vips-4]: ./libvips.md#_4-i-o-and-codec-architecture
[vips-5]: ./libvips.md#_5-hostile-input-and-safety
[vips-6]: ./libvips.md#_6-allocation-and-ownership
[vips-7]: ./libvips.md#_7-cpu-parallelism-and-simd
[vips-l]: ./libvips.md#lessons-for-sparkles
[vk]: ./vulkan-transfer.md
[vk-1]: ./vulkan-transfer.md#_1-pixel-and-memory-model
[vk-2]: ./vulkan-transfer.md#_2-genericity-mechanism
[vk-3]: ./vulkan-transfer.md#_3-colour-and-metadata
[vk-6]: ./vulkan-transfer.md#_6-allocation-and-ownership
[vk-8]: ./vulkan-transfer.md#_8-gpu-offload-and-interop
[vk-l]: ./vulkan-transfer.md#lessons-for-sparkles
[wired-fit]: ./wired-flat-fit/index.md
[wired-req]: ./wired-requirements.md
[wuffs]: ./wuffs.md
[wuffs-1]: ./wuffs.md#_1-pixel-and-memory-model
[wuffs-10]: ./wuffs.md#_10-testing-and-conformance
[wuffs-2]: ./wuffs.md#_2-genericity-mechanism
[wuffs-3]: ./wuffs.md#_3-colour-and-metadata
[wuffs-4]: ./wuffs.md#_4-i-o-and-codec-architecture
[wuffs-5]: ./wuffs.md#_5-hostile-input-and-safety
[wuffs-6]: ./wuffs.md#_6-allocation-and-ownership
[wuffs-7]: ./wuffs.md#_7-cpu-parallelism-and-simd
[wuffs-8]: ./wuffs.md#_8-gpu-offload-and-interop
[wuffs-9]: ./wuffs.md#_9-temporal-animation-and-containers
[wuffs-l]: ./wuffs.md#lessons-for-sparkles
[zune]: ./zune-image.md
[zune-1]: ./zune-image.md#_1-pixel-and-memory-model
[zune-10]: ./zune-image.md#_10-testing-and-conformance
[zune-2]: ./zune-image.md#_2-genericity-mechanism
[zune-4]: ./zune-image.md#_4-i-o-and-codec-architecture
[zune-5]: ./zune-image.md#_5-hostile-input-and-safety
[zune-6]: ./zune-image.md#_6-allocation-and-ownership
[zune-7]: ./zune-image.md#_7-cpu-parallelism-and-simd
[zune-9]: ./zune-image.md#_9-temporal-animation-and-containers
[zune-l]: ./zune-image.md#lessons-for-sparkles
[concepts]: ./concepts.md
[sources-tsv]: ./sources.tsv
