# Skia (C++)

Google's 2-D graphics library, used by Chrome, Android and Flutter. It is the survey's main example of a production viewer pixel model: a runtime descriptor (`SkImageInfo`) kept apart from storage at three ownership levels, a pull-based codec layer with incremental and animated decoding, and colour handled by `skcms` at decode time.

| Field         | Value                                                                                                                                                                          |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language      | C++17; `skcms` is C-compatible C++; Rust decoders behind `cxx` bridges (`rust/`)                                                                                               |
| License       | BSD 3-Clause ([`LICENSE`][license]); third-party codecs under their own terms ([`third_party/README`][tp-readme])                                                              |
| Repository    | [google/skia][repo] (GitHub mirror of `skia.googlesource.com/skia`)                                                                                                            |
| Revision read | `3ad790ab4d6d596efae0d70e4b8bf7d339121984` (August 13, 2026, "Roll ANGLE"); vendored `skcms` at `6010f3583977f651726b24228f7e6a377e47c58d` ([`README.chromium`][skcms-readme]) |
| Documentation | [skia.org/docs][docs] · [api.skia.org][api] · header comments under `include/core/` and `include/codec/`                                                                       |
| Category      | Generic libraries: runtime pixel descriptor, codec abstraction over C and Rust decoders, colour management, CPU raster pipeline, GPU backends (Ganesh, Graphite)               |
| Tier          | A                                                                                                                                                                              |
| Last reviewed | November 7, 2026                                                                                                                                                               |

> [!NOTE]
> Claims marked **verified** were shown by building the vendored `skcms` (from
> `git archive` of the pinned revision) with clang 21.1.7 (and re-verified with GCC
> 16.2.0 and LDC 1.43.0) and running a probe on an AMD Ryzen 9 7940HX (where
> `cpu_type()` selects the `SKX` AVX-512 back end, and forcing `Baseline` or `HSW`
> gives identical results), in a scratch directory outside the repository. Nothing else
> in Skia was built. Everything else is read from the source at the pinned revision.
> No performance number on this page was measured.

---

## Overview

### What it solves

A browser or an OS image view decodes untrusted files of many formats into a few
pixel layouts. It draws them through a CPU rasteriser or a GPU, converts each image
from its embedded colour space to the display's, and does all of this lazily, since
most decoded images are never drawn at full size, or never drawn at all. Skia's image
stack covers the whole route. `SkCodec` turns encoded bytes into rows in a
caller-chosen `SkImageInfo`. `skcms` converts colour during the decode. `SkImage` is
the immutable, possibly lazy, possibly GPU-resident handle that a canvas draws, and
`SkSurface` is what a canvas draws into.

The library writes the four storage forms down in one header comment, the one on
`SkImage` ([`SkImage.h`][image-class]):

> _"SkImage describes a two dimensional array of pixels to draw. The pixels may be
> decoded in a raster bitmap, encoded in a SkPicture or compressed data stream, or
> located in GPU memory as a GPU texture. SkImage cannot be modified after it is
> created. SkImage may allocate additional storage as needed; for instance, an encoded
> SkImage may decode when drawn."_

### Design philosophy

Three commitments recur through the tree.

1. **Pixel format is runtime data, not a type.** Every surface, bitmap, pixmap and
   codec destination is described by the same value, `SkImageInfo`. It holds
   dimensions, an `SkColorType`, an `SkAlphaType` and a ref-counted `SkColorSpace`.
   Code that has to handle many formats does not get a template parameter. It
   chains small stages chosen at run time, which the raster pipeline's header
   justifies ([`SkRasterPipeline.h`][rp-doc]):

   > _"It's particularly designed for situations where the potential pipeline is
   > extremely combinatoric: {N dst formats} x {M source formats} x {K mask formats} x
   > {C transfer modes} ... No one wants to write specialized routines for all those
   > combinations, and if we did, we'd end up bloating our code size dramatically.
   > SkRasterPipeline stages can be chained together at runtime, so we can scale this
   > problem linearly rather than combinatorically."_

2. **Ownership is a type, not a flag.** `SkPixmap` borrows, `SkBitmap` shares a
   ref-counted `SkPixelRef`, and `SkImage` is immutable and may be lazy. Each says
   in its header what it does not manage.
3. **Decoders are replaceable, and they are being replaced by memory-safe ones.**
   Formats register as `SkCodecs::Decoder` records. GIF goes through Wuffs, and the
   build can choose Rust decoders for PNG and BMP, with JPEG and ICO ones under
   `experimental/`.

Compare it with [Boost.GIL](./boost-gil.md), the survey's other end: GIL turns
every format axis into a compile-time type. Skia turns every axis into an enum and
an [`SkColorSpace`](#_3-colour-and-metadata) beside the pixels, the runtime-descriptor
position that [color](./color.md) contrasts with its colour-in-the-element-type
design.

---

## How it works

### The descriptor: `SkImageInfo`, `SkColorType`, `SkAlphaType`

`SkImageInfo` is an `SkColorInfo` plus an `SkISize` of two `int`s
([`SkImageInfo.h`][ii-fields]). `SkColorInfo` holds an `sk_sp<SkColorSpace>`, an
`SkColorType` and an `SkAlphaType` ([`SkImageInfo.h`][color-info]). The colour type
names a little-endian bit layout, and each enumerator's comment draws it
([`SkColorType.h`][ct-doc]):

```cpp
// include/core/SkColorType.h (abridged)
    // Four channel RGBA data (8 bits per channel) packed into a LE 32-bit word.
    //   Bits: [A:31..24 B:23..16 G:15..8 R:7..0]
    kRGBA_8888_SkColorType,
    // Four channel RGBA data (16-bit half-float per channel) packed into a LE 64-bit word.
    //   Bits: [A:63..48 B:47..32 G:31..16 R:15..0]
    kRGBA_F16_SkColorType,
```

The enum has 29 enumerators, counting `kUnknown_SkColorType`. They run from
`kAlpha_8` and `kRGB_565` through 10-bit (`kRGBA_1010102`, the extended-range
`kBGR_101010x_XR` for Apple displays), 16-bit unorm and half-float types to
`kRGBA_F32`. Every one is interleaved, and `kSRGBA_8888` is the only one that puts
a transfer function in the type. `kN32_SkColorType` is an alias whose target depends
on the build's byte order, and the header warns that it "can lead to inconsistent
results across platforms" ([`SkColorType.h`][ct-doc], [`SkColorType.h`][ct-n32]).

`SkAlphaType` is `kUnknown`, `kOpaque`, `kPremul` or `kUnpremul`
([`SkAlphaType.h`][alpha-type]). Colour type and alpha type are validated together.
`SkColorTypeValidateAlphaType` forces every colour type without alpha to `kOpaque`,
turns `kUnpremul` into `kPremul` for alpha-only types, and rejects `kUnknown` for
types that carry alpha ([`SkImageInfo.cpp`][validate-at]).

Row stride is not part of `SkImageInfo`. It travels beside the descriptor as
`size_t rowBytes`. `validRowBytes` requires at least `minRowBytes64()` and a whole
number of pixels per row ([`SkImageInfo.h`][ii-validrb]). `computeByteSize` is
checked arithmetic with a hard cap ([`SkImageInfo.cpp`][byte-size]):

```cpp
// src/core/SkImageInfo.cpp — SkImageInfo::computeByteSize
    SkSafeMath safe;
    size_t bytes = safe.add(safe.mul(safe.addInt(this->height(), -1), rowBytes),
                            safe.mul(this->width(), this->bytesPerPixel()));

    // The CPU backend implements some memory operations on images using instructions that take a
    // signed 32-bit offset from the base. If we ever make an image larger than that, overflow can
    // cause us to read/write memory that starts 2GB *before* the buffer. (crbug.com/1264705)
    constexpr size_t kMaxSigned32BitSize = SK_MaxS32;
    return (safe.ok() && (bytes <= kMaxSigned32BitSize)) ? bytes : SIZE_MAX;
```

### Storage: three ownership levels and a destination

| Type        | Owns pixels?                                     | Mutable?                                           | Source                     |
| ----------- | ------------------------------------------------ | -------------------------------------------------- | -------------------------- |
| `SkPixmap`  | no: "does not try to manage the lifetime"        | yes, through `writable_addr()`                     | [`SkPixmap.h`][pixmap]     |
| `SkBitmap`  | shares an `sk_sp<SkPixelRef>`                    | yes; `setImmutable()` is one-way                   | [`SkBitmap.h`][bitmap]     |
| `SkImage`   | ref-counted; raster, lazy, picture or texture    | never                                              | [`SkImage.h`][image-class] |
| `SkSurface` | owns or wraps a destination; `SkCanvas` draws in | yes; `makeImageSnapshot()` captures current pixels | [`SkSurface.h`][surface]   |

`SkPixmap` is three fields, `fPixels`, `fRowBytes` and `fInfo`, and its constructor
does "No parameter checking" ([`SkPixmap.h`][pixmap-ctor]). `SkBitmap` holds an
`sk_sp<SkPixelRef>` and a cached `SkPixmap` ([`SkBitmap.h`][bitmap-fields]).
`SkPixelRef` is "the smart container for pixel memory" and "can be shared/accessed
between multiple threads", and it carries a generation ID that changes on
`notifyPixelsChanged()` ([`SkPixelRef.h`][pixelref]). External memory comes in
through `installPixels(info, pixels, rowBytes, releaseProc, context)`
([`SkBitmap.h`][install-pixels]) and `SkImages::RasterFromPixmap(pixmap,
rasterReleaseProc, releaseContext)` ([`SkImage.h`][raster-from]). Neither copies;
both call the release procedure when the last reference goes.

### Lazy images

`SkImages::DeferredFromEncodedData` returns an image that "attempts to defer
decoding until the image is actually used/drawn", with a cache that "may be
purged, causing the next draw of the image to have to re-decode"
([`SkImage.h`][deferred]). The newer `SkCodecs::DeferredImage(std::unique_ptr<SkCodec>)`
does the same for a codec the caller has already chosen ([`SkCodec.h`][skcodecs]).
When a CPU draw needs the pixels, `SkImage_Lazy::getROPixels` looks up
`SkBitmapCache`. On a miss it allocates a cache record, runs the generator into
it, and adds it to the purgeable `SkResourceCache` ([`SkImage_Lazy.cpp`][lazy-ro]).
`kDisallow_CachingHint` decodes into a private bitmap instead.

### `SkCodec`: three ways to pull pixels

A codec is made from a stream. `MakeFromStream` peeks or reads
`MinBufferedBytesNeeded()` (32) bytes, asks each registered decoder's `isFormat`
callback, and gives the stream to the first match ([`SkCodec.h`][min-bytes],
[`SkCodec.cpp`][registry]). The caller then picks a destination `SkImageInfo` and
one of three modes:

| Mode        | Entry points                                                          | Progress report                                      |
| ----------- | --------------------------------------------------------------------- | ---------------------------------------------------- |
| Whole image | `getPixels(info, pixels, rowBytes, options)`                          | `Result`; unfilled rows are filled                   |
| Incremental | `startIncrementalDecode(...)`, then `incrementalDecode(&rowsDecoded)` | `kIncompleteInput` and a row count; no filling       |
| Scanline    | `startScanlineDecode`, `getScanlines`, `skipScanlines`                | rows returned; `getScanlineOrder()` may be bottom-up |

The incremental contract is stated on `incrementalDecode` ([`SkCodec.h`][incremental]):

> _"If kIncompleteInput is returned, may be called again after more data has been
> provided to the source SkStream. Unlike getPixels and getScanlines, this does not
> do any filling. This is left up to the caller, since they may be skipping lines or
> continuing the decode later."_

`Result` tells apart a recoverable stall (`kIncompleteInput`, "A partial image was
generated") and a fatal one (`kErrorInInput`, after which "decoding cannot continue,
even with more data"). It also has `kInvalidConversion`, `kInvalidScale`,
`kCouldNotRewind`, `kUnimplemented` and `kOutOfMemory` ([`SkCodec.h`][result]).
`Options` carries `fZeroInitialized`, `fSubset`, `fFrameIndex`, `fPriorFrame` and
`fMaxDecodeMemory`, a cumulative allocation budget ([`SkCodec.h`][options]). After
a short whole-image decode, `SkCodec::getPixels` fills the remaining rows unless the
caller said the memory is already zero ([`SkCodec.cpp`][fill-incomplete],
[`SkCodec.cpp`][fill-impl]).

### Registration and the codec catalogue

```cpp
// include/codec/SkCodec.h — namespace SkCodecs
struct SK_API Decoder {
    // By convention, we use all lowercase letters and go with the primary filename extension.
    // For example "png", "jpg", "ico", "webp", etc
    std::string_view id;
    IsFormatCallback isFormat;
    MakeFromStreamCallback makeFromStream;
};

// ... This is not thread-safe, so make sure all
// initialization is done before the first call.
void SK_API Register(Decoder d);
```

`Register` replaces an entry with the same `id` in place, or appends one
([`SkCodec.cpp`][registry]). The default list is built inside a function-local
static, "A static variable inside a function avoids a static initializer", from
`SK_CODEC_DECODES_*` build flags. `SK_DISABLE_LEGACY_INIT_DECODERS` leaves it empty,
so a client registers only what it links ([`SkCodec.cpp`][registry]). At the pinned
revision the formats map to these back ends:

| Format    | Back end(s)                                                        | Incremental                   | Scanline                 | Animation          |
| --------- | ------------------------------------------------------------------ | ----------------------------- | ------------------------ | ------------------ |
| PNG       | libpng (`SkPngCodec`) or the Rust `png` crate (`SkPngRustCodec`)   | both                          | no                       | Rust only (APNG)   |
| JPEG      | libjpeg-turbo (`SkJpegCodec`); Rust under `experimental/rust_jpeg` | Rust only                     | libjpeg-turbo only       | no                 |
| GIF       | Wuffs (`SkWuffsCodec`)                                             | yes                           | no                       | yes                |
| WebP      | libwebp demux and decode (`SkWebpCodec`)                           | no                            | no                       | yes                |
| AVIF      | libavif, or CrabbyAvif on the Android framework                    | no                            | no                       | yes (frame timing) |
| JPEG XL   | libjxl (`SkJpegxlCodec`)                                           | no; "TODO(eustas): implement" | no                       | yes (frame events) |
| BMP, ICO  | Skia's own; Rust BMP (`rust/bmp/`), Rust ICO (`experimental/`)     | ICO (both), Rust BMP          | BMP (both), `SkIcoCodec` | no                 |
| WBMP, RAW | Skia's own; RAW through `dng_sdk` and `piex`                       | no                            | WBMP                     | no                 |

The table is read from which `src/codec/*.{h,cpp}` and `experimental/rust_*/` files
override `onStartIncrementalDecode`, `onStartScanlineDecode` and `onGetFrameInfo`,
and from the registration order ([`SkCodec.cpp`][registry],
[`SkWuffsCodec.cpp`][wuffs-modes], [`SkJpegxlCodec.cpp`][jxl-todo],
[`SkJpegRustCodec.h`][jpeg-rust-modes], [`SkIcoRustCodec.h`][ico-rust-modes];
`SkIcoRustCodec` exposes each embedded icon as a static frame with `fDuration = 0`).
The Rust PNG README records that the libpng codec has "No APNG support" and "No CICP
support" ([`rust/png/README.md`][rust-png]). External pins live in [`DEPS`][deps].

### Wuffs inside an `SkCodec`

`SkWuffsCodec` shows how a coroutine decoder fits behind a pull API. It holds a
4,096-byte inline `fBuffer` as the Wuffs `io_buffer`, refills it from the
`SkStream`, and records whether the Wuffs decoder is suspended, because a suspended
Wuffs object can only be resumed or reset ([`SkWuffsCodec.cpp`][wuffs-state]). The
refill function explains why it never marks the input closed
([`SkWuffsCodec.cpp`][wuffs-fill]):

> _"SkStream is designed around synchronous I/O. The SkStream::read method does not
> take a callback and, per its documentation comments, a read request for N bytes
> should block until a full N bytes are available. In practice, Blink's SkStream
> subclass builds on top of async I/O and cannot afford to block."_

GIF output is forced from 1-byte palette indices to 4-byte `BGRA_NONPREMUL` or
`RGBA_NONPREMUL` ([`SkWuffsCodec.cpp`][wuffs-pixfmt]). The codec decodes in one pass
straight into the destination when it can. Otherwise, for "color correction,
scaling, RGB565", it decodes into a lazily allocated intermediate and composites
from there ([`SkWuffsCodec.cpp`][wuffs-twopass]).

### Colour: `SkColorSpace` versus the decode-time ICC profile

`SkColorSpace` is a transfer function plus a 3x3 matrix to XYZ D50. Its factories are
`MakeSRGB`, `MakeSRGBLinear`, `MakeRGB(transferFn, toXYZ)`, `MakeCICP(primaries,
transfer)` and `Make(const skcms_ICCProfile&)` ([`SkColorSpace.h`][cs-api]).
`Make` from a profile prefers the profile's CICP tag (only when
`matrix_coefficients == 0` and full range), then the `toXYZD50` matrix, then three
identical parametric curves, or curves "close enough to sRGB". Otherwise it returns
`nullptr` ([`SkColorSpace.cpp`][cs-make]). A LUT-based (`A2B`) profile therefore has
no `SkColorSpace`. The codec keeps the full `skcms_ICCProfile` in `SkEncodedInfo`,
reports it through `getICCProfile()` ([`SkCodec.h`][get-icc]), and transforms rows
with `skcms_Transform` during the decode ([`SkCodec.cpp`][xform]).

`skcms` stores a transfer function as seven floats, `g, a, b, c, d, e, f`, for the
ICC piecewise form ([`skcms_public.h`][skcms-tf]). PQ and HLG are not that form: they
are flagged by negative sentinels in `g` (`-5` for PQ, `-6` for HLG). The HDR
reference white goes in `a`, and HLG's peak luminance and system gamma in `b` and `c`
([`skcms_public.h`][skcms-pqhlg]):

```cpp
// modules/skcms/src/skcms_public.h — skcms_TransferFunction_makePQ (comment)
// When this is used as an SkColorSpace, the transformation to XYZD50 will be as follows:
//   1. Apply the unit PQ EOTF to each channel
//   2. Multiply by 10,000 nits
//   3. Divide by hdr_reference_white_luminance nits (default is 203)
//   4. Transform primaries to XYZD50
```

**Verified:** `skcms_TransferFunction_makePQ(&tf, 203)` gives a function that
`skcms_TransferFunction_getType` classifies as `skcms_TFType_PQ`, with `g = -5` and
`a = 203`. `eval(0.58)` returns `0.020151` (about 201.5 nits on the unit EOTF) and
`eval(1.0)` returns `1.0`. `makeHLG(&tf, 203, 1000, 1.2)` classifies as
`skcms_TFType_HLG`, and `eval(0.5)` returns `0.083333`, the HLG inverse OETF of
one half (1/12).

### Alpha: premultiplied by default, premultiplied "as encoded"

The skcms comment on `skcms_AlphaFormat` states the convention ([`skcms_public.h`][skcms-alpha]):

> _"We always store any alpha channel linearly. ... We used to offer multiple types of
> premultiplication, but now just one, PremulAsEncoded. This is the premul you're
> probably used to working with."_

`PremulAsEncoded` is `tf-1(r)*a`: colour is multiplied by alpha after it has been
encoded for the destination. A decode that asks for `kPremul_SkAlphaType` from an
unpremultiplied source selects `skcms_AlphaFormat_PremulAsEncoded`
([`SkCodec.cpp`][xform]). The lazy-image factories pick premultiplied for any
non-opaque image and refuse a forced opaque ([`SkImage.h`][deferred]). **Verified:**
the unpremultiplied sRGB pixel `(255, 128, 0, 128)` converted to sRGB with
`PremulAsEncoded` gives `(128, 64, 0, 128)`, so the premultiplication happens on the
encoded values. The same pixel converted to a linear-sRGB `RGBA_ffff` destination
gives `(0.50196, 0.10833, 0, 0.50196)`, so there it happens on linear values. The
alpha state of a result therefore depends on the destination's transfer function.

### The raster pipeline

When colour type, alpha type or colour space differ, conversion goes through
`SkColorSpaceXformSteps`. It reduces any pair of (space, alpha) descriptors to at
most seven flagged steps ([`SkColorSpaceXformSteps.h`][xform-steps]) and appends
them to an `SkRasterPipeline` ([`SkColorSpaceXformSteps.cpp`][xform-apply]):

```cpp
// src/core/SkColorSpaceXformSteps.cpp — apply(SkRasterPipeline*)
    if (this->fFlags.unpremul)        { p->append(SkRasterPipelineOp::unpremul); }
    if (this->fFlags.linearize)       { p->appendTransferFunction(fSrcTF); }
    if (this->fFlags.src_ootf)        { p->append(SkRasterPipelineOp::ootf, fSrcOotf); }
    if (this->fFlags.gamut_transform) { p->append(SkRasterPipelineOp::matrix_3x3, &fSrcToDstMatrix); }
    if (this->fFlags.dst_ootf)        { p->append(SkRasterPipelineOp::ootf, fDstOotf); }
    if (this->fFlags.encode)          { p->appendTransferFunction(fDstTFInv); }
    if (this->fFlags.premul)          { p->append(SkRasterPipelineOp::premul); }
```

A pipeline is an array of `SkRasterPipelineStage { void (*fn)(); void* ctx; }`
([`SkRasterPipeline.h`][rp-stage]). The ops are X-macro lists:
`SK_RASTER_PIPELINE_OPS_LOWP` for ops with both a 16-bit fixed-point and a float
version, and `SK_RASTER_PIPELINE_OPS_HIGHP_ONLY` for float-only ones such as
`unpremul`, `load_f16`, `parametric`, `PQish` and `HLGish`
([`SkRasterPipelineOpList.h`][rp-ops-lowp], [`SkRasterPipelineOpList.h`][rp-ops-highp]).
`buildPipeline` tries lowp first and falls back to highp when any stage has no
lowp version ([`SkRasterPipeline.cpp`][rp-build]). Each stage takes the pixel
registers as arguments, "Our fundamental vector depth is our pixel stride", and on
x86-64, ARM64 and LoongArch (except under MSVC) it passes `r, g, b, a` and
`dr, dg, db, da` as eight vector arguments; elsewhere it uses narrower stages with a
`Params` struct ([`SkRasterPipeline_opts.h`][rp-abi]). Ordinary raster stages
(`HIGHP_STAGE`, `LOWP_STAGE`) call the next stage in tail position without
`[[clang::musttail]]` so the optimizer decides when to inline or tail-call, whereas
SkSL stages (`HIGHP_TAIL_STAGE`, `HIGHP_BRANCH_STAGE`, which can be thousands of ops
long) enforce `SKRP_MUSTTAIL` (`[[clang::musttail]]`) where available and fall back to
`stack_checkpoint`/`stack_rewind` otherwise ([`SkRasterPipeline.h`][rp-musttail],
[`SkRasterPipeline_opts.h`][rp-abi]).

### GPU textures

**Ganesh.** `LockTextureProxyView` turns a lazy image into a texture in four steps
([`GrImageUtils.cpp`][lock-tex]). It looks up the unique-key cache, keyed by
`uniqueID()`. It asks the generator to make a texture natively. It asks for YUV
planes "which the GPU can convert", skipped when mipmaps are needed. Last, it decodes
a CPU bitmap through `getROPixels` and uploads that. `SkImages::TextureFromImage`,
`TextureFromYUVAPixmaps`, `TextureFromCompressedTextureData` (taking
`SkTextureCompressionType`: `kETC2_RGB8_UNORM` / `kETC1_RGB8`, `kBC1_RGB8_UNORM`,
`kBC1_RGBA8_UNORM`), `BorrowTextureFrom` and `AdoptTextureFrom` are the public doors
([`SkImageGanesh.h`][ganesh-api], [`SkTextureCompressionType.h`][tex-comp]).

**Graphite.** Graphite does no image caching by default. The client gives it an
`ImageProvider` whose `findOrCreate` must return a texture-backed image that keeps
"the dimensions and alpha type of the original image", while bit depth may grow
(`4444` to `8888`) ([`ImageProvider.h`][img-provider]). An upload builds
`SkColorSpaceXformSteps` from the source and destination `SkColorInfo` and a
`TextureFormatXferFn` for the texture format and swizzle, so conversion happens while
writing the staging buffer ([`UploadTask.cpp`][upload-src]). Staging offsets are
aligned to `max(bytesPerBlock, caps->requiredTransferBufferAlignment())`
([`UploadTask.cpp`][upload-align]).

---

## Analysis

### 1. Pixel and memory model

Interleaved 2-D rasters only. A descriptor (`SkImageInfo`) and a byte stride
(`rowBytes`) are carried apart and joined in `SkPixmap`. Dimensions are signed
`int`. `SkImageInfoIsValid` rejects anything over `SK_MaxS32 >> 2` per side
([`SkImageInfoPriv.h`][ii-valid]); the `SkImage` raster factories document a 29-bit
limit ([`SkImage.h`][raster-from]); total size is capped at 2^31 − 1 bytes
([`SkImageInfo.cpp`][byte-size]). Stride must be a whole number of pixels and cannot
be negative, so a bottom-up BMP is reported through `kBottomUp_SkScanlineOrder`
rather than through a negative [stride](./concepts.md#stride)
([`SkCodec.h`][scanline-order]). A sub-image is `SkPixmap::extractSubset`, a view on
the same memory ([`SkPixmap.h`][pixmap-subset]). Planar data exists only as a
separate family, `SkYUVAPixmapInfo` and `SkYUVAPixmaps`, which codecs fill through
`queryYUVAInfo` and `getYUVAPlanes` ([`SkCodec.h`][yuva]). There are no tiles, no
N-D extents and no channel-count abstraction. A colour type is a closed list of
[pixel format names](./concepts.md#pixel-format-names-and-byte-order).

### 2. Genericity mechanism

Runtime, at every layer. Formats are enums handled by `switch`. Conversions are
runtime stage lists. Codecs are virtual subclasses of `SkCodec` (`onGetPixels`,
`onStartIncrementalDecode`, `onGetFrameInfo`, ...) found through a vector of
function-pointer records. The one compile-time axis is the instruction set: the same
`SkRasterPipeline_opts.h` is compiled once per target namespace and chosen at
start-up ([`SkOpts.cpp`][opts]). The pipeline header gives the reason, code size
against a combinatorial product ([`SkRasterPipeline.h`][rp-doc]). That is the
opposite trade from [Boost.GIL](./boost-gil.md), which pays the product in
instantiations, and [Halide](./halide.md), which compiles a schedule per pipeline.

### 3. Colour and metadata

Colour is a runtime descriptor beside the pixels (`sk_sp<SkColorSpace>` in
`SkColorInfo`), and a null colour space means "sRGB" when the image is drawn
([`SkImageInfo.h`][color-info]). `SkColorSpace` is deliberately small: one
[transfer function](./concepts.md#transfer-function) and a matrix. The full
[ICC profile](./concepts.md#icc-profile) lives only on the codec, so LUT profiles
are handled once, at decode, by `skcms` (see
[How it works](#colour-skcolorspace-versus-the-decode-time-icc-profile)).
[CICP](./concepts.md#cicp) wins over ICC data when both are present, but
`MakeCICP` takes no matrix coefficients or range flag. Its comment says "Narrow
range images are extremely rare" and leaves YCbCr matrices to the caller
([`SkColorSpace.h`][cs-cicp]). HDR has three parts: PQ and HLG as tagged transfer
functions with a reference white, an `ootf` pipeline step, and `skhdr::Metadata` on
`SkEncodedInfo` ([`SkEncodedInfo.h`][encoded-info-fields]). Gain maps come as an
`SkGainmapInfo`, whose header documents the
[gain-map](./concepts.md#hdr-gain-map) application formula
([`SkGainmapInfo.h`][gainmap]), and a second codec from `onGetGainmapCodec`
([`SkCodec.h`][gainmap-hooks]). EXIF orientation becomes `SkEncodedOrigin`;
`getImage` rotates for it ([`SkCodec.h`][get-image]). XMP is parsed for JPEG gain maps
(`SkJpegXmp.cpp`). Skia has no general EXIF or XMP model and keeps only what drawing
needs. For alpha, the default is
[premultiplied](./concepts.md#straight-and-premultiplied-alpha) "as encoded". The
destination's transfer function decides whether the premultiplied values are linear
(verified above).

### 4. I/O and codec architecture

[Pull](./concepts.md#push-and-pull-decoding): the codec reads an `SkStream` it owns.
Incremental decoding works by returning `kIncompleteInput` and being called again
after the stream has more bytes. The codec does not own a coroutine across calls,
except Wuffs, which owns one internally. Suspension is therefore at row granularity,
and only for the codecs in the table above. JPEG (`SkJpegCodec`), WebP, AVIF and
JPEG XL offer either scanlines over a complete stream or nothing (`SkJpegRustCodec`
adds incremental JPEG under `experimental/rust_jpeg/`). The header lists
`kCouldNotRewind` because several paths rewind the stream to restart
([`SkCodec.h`][result]); WebP gives the demuxer "the optimal amount of the stream as
SkData" (`SkWebpCodec.cpp`). The Wuffs comment records the friction between a
synchronous `SkStream` and an asynchronous network source
([`SkWuffsCodec.cpp`][wuffs-fill]). Scaling is part of the request: a destination
size other than `getInfo()` "implies a request to scale", and a codec that cannot
answers `kInvalidScale` ([`SkCodec.h`][getpixels-doc]). See
[suspendable decoding](./concepts.md#incremental-progressive-and-suspendable-decoding).

### 5. Hostile input and safety

Defences are layered rather than uniform. Wuffs decodes GIF, and the file notes that
even with `SK_WUFFS_FAVORS_PERFORMANCE_OVER_ADDITIONAL_MEMORY_SAFETY` "The Wuffs
library is still memory-safe either way" ([`SkWuffsCodec.cpp`][wuffs-safety]). The
build can switch PNG and BMP to Rust decoders, and JPEG and ICO to experimental ones
([`SkCodec.cpp`][registry]). The C codecs recover from errors with `setjmp`/`longjmp`
(`SkPngCodec.cpp`, `SkJpegCodec.cpp`). Size arithmetic goes through `SkSafeMath` with
the 2 GiB cap from crbug.com/1264705. `skcms` bounds-checks each tag against its
declared size and limits CLUTs to `SKCMS_MAX_GRID_POINTS` (350 million) so that
gather indices cannot overflow ([`skcms.cc`][skcms-grid]). `skcms_Parse` requires
"1-2 bytes" of padding past the profile ([`skcms_public.h`][skcms-parse]).
**Verified:** `skcms_Parse` rejects 200 zero bytes and a 3-byte buffer. The memory
budget `Options::fMaxDecodeMemory` is real but partial: a search of `src/` and
`experimental/` finds `allocateFromBudget` called only by `SkCodec::getImage` and
`SkJpegCodec` ([`SkCodec.cpp`][budget], [`SkJpegCodec.cpp`][jpeg-budget]); individual
codecs and Rust bridges enforce fixed caps of their own (`SkPngRustCodec` caps width
and height at 1,000,000, `SkRawCodec` caps its stream buffer at 100 MiB, `rust/exif/`
caps EXIF payloads at 4 MiB, and `experimental/rust_jpeg/` caps decoded image bytes at
512 MiB and progressive scans at 100). The [hostile-input thread][p-hostile] covers
the WebP `VP8L` exploit (CVE-2023-4863) that reached Chrome through `libwebp`. At
this revision WebP is still decoded by `libwebp`.

### 6. Allocation and ownership

Codecs write into memory the caller provides. Skia's decode API never allocates the
destination, though `getImage` and the lazy cache do it for the caller. Internal
scratch varies: Wuffs embeds 4 KiB in the codec object and allocates its work buffer
and two-pass intermediate on the heap with `sk_free` deleters
([`SkWuffsCodec.cpp`][wuffs-state]). Pipelines are built in an `SkArenaAlloc`
([`SkRasterPipeline.h`][rp-stage]). Shared ownership uses intrusive reference
counting (`SkRefCnt`, `SkNVRefCnt` for `SkColorSpace`). External memory crosses the
boundary with a C release callback. `SkBitmap` is explicitly not thread-safe, while
the `SkPixelRef` it points to is ([`SkBitmap.h`][bitmap]). Decoded pixels of lazy
images live in a purgeable global cache, and a re-decode after a purge is part of the
contract ([`SkImage.h`][deferred]).

### 7. CPU parallelism and SIMD

SIMD: yes, in three places with three separate dispatchers. (a) The raster pipeline:
one portable source over vector types `F`, `U32` and others, compiled for SSE2,
SSE4.1, AVX, AVX2 ("ML3"), AVX-512 ("ML4", opt-in through `SK_ENABLE_AVX512_OPTS`),
NEON and LoongArch, chosen once in `SkOpts::Init` ([`SkRasterPipeline_opts.h`][rp-targets],
[`SkOpts.cpp`][opts]). Scalar and SSE2 builds use `rcp_precise` "so we can have
more predictable results" ([`SkRasterPipeline_opts.h`][rp-abi]). (b) `skcms` has
its own `Baseline`, `HSW` and `SKX` back ends, picked by `cpuid`/`xgetbv`
([`skcms.cc`][skcms-cpu]); the build compiles them with per-file `-mavx2` or
`-mavx512*` flags ([`BUILD.gn`][skcms-gn]). (c) The codec swizzlers (`RGBA_to_rgbA`
and others) have NEON, SSE and LASX versions in `SkSwizzler_opts.inc`. Threads: no
codec decodes in parallel. Parallelism belongs to the client, for example one
Graphite `Recorder` per thread ([`ImageProvider.h`][img-provider]).

### 8. GPU offload and interop

Skia uploads; it does not decode on the GPU. The GPU-side work is colour conversion
during the YUV-to-RGB draw (Ganesh step 3) and format and colour conversion while
writing the [staging buffer](./concepts.md#staging-and-upload) (Graphite). Interop
goes both ways: wrap, borrow or adopt a backend texture, or export one with
`GetBackendTextureFromImage` ([`SkImageGanesh.h`][ganesh-api]). Graphite asks the
client to own the texture cache through `ImageProvider`, a choice
the header says it makes "by default". Pre-compressed texture data has its own
factory (`TextureFromCompressedTextureData`). The decode-then-upload path stays
RGBA-shaped.

### 9. Temporal, animation and containers

Animation is a codec property ([`SkCodec.h`][frameinfo]). `getFrameCount`,
`getFrameInfo` and `getRepetitionCount` (`kRepetitionCountInfinite = -1`) describe
the sequence. Each `FrameInfo` has `fRequiredFrame`, `fDuration` in milliseconds,
`fFullyReceived`, `fAlphaType`, `fHasAlphaWithinBounds`, `fDisposalMethod`, `fBlend`
and `fFrameRect`. `Options::fPriorFrame` lets a client that keeps the previous canvas
skip re-decoding earlier frames. The disposal and blend vocabulary follows GIF 89a
(`kKeep`, `kRestoreBGColor`, `kRestorePrevious`; `kSrcOver`, `kSrc`)
([`SkCodecAnimation.h`][anim]). Frame counts can grow as data arrives, and
`isAnimated()` answers `kUnknown` until it knows. For multi-image containers
(AVIF, HEIF), `SelectionPolicy` picks still or sequence ([`SkCodec.h`][selection]).
There is no timeline, no audio and no general container layer. Video belongs to
the video catalogue.

### 10. Testing and conformance

The test tool `dm` runs each image in seven `CodecSrc` modes: whole image,
zero-initialised, scanline, stripe (scanline skipping), cropped scanline, subset and
animated ([`DMSrcSink.h`][dm-modes]). Unit tests cover codecs (`CodecTest.cpp`,
`CodecPartialTest.cpp`, `CodecAnimTest.cpp`, `GifTest.cpp`, `WebpTest.cpp`,
`AvifTest.cpp`, gain-map tests and Rust codec tests) over 234 files in
`resources/images` (172 top-level files plus `orientation/` and `pngsuite/`).
OSS-Fuzz targets drive each entry point separately.
`FuzzIncrementalImage.cpp` leaves `rowsDecoded` "Deliberately uninitialized to verify
that incrementalDecode initializes it" ([`FuzzIncrementalImage.cpp`][fuzz-incr]), and
`FuzzImage.cpp` decodes through `DeferredFromEncodedData` and draws
([`FuzzImage.cpp`][fuzz-image]). Both cap inputs at 10,240 bytes. The vendored
`skcms` carries no tests in this tree; they live upstream at the revision in
[`README.chromium`][skcms-readme].

---

## Lessons for Sparkles

- **Q1.** A small descriptor value apart from storage, at three ownership levels,
  fits D directly. `ImageInfo` would be a `@safe pure nothrow @nogc` struct. A
  borrowed `Pixmap` view would be a `scope` slice plus stride, which dip1000 can
  check where Skia's raw `const void*` cannot. Owned storage would be a
  `UniqueBuffer`, with shared storage as an explicit second type. What does not
  transfer is the `int` dimensions, the 2 GiB cap and the stride that cannot be
  negative: they suit Skia's CPU blitters, while Sparkles indexes with `size_t`. The
  repository has no pixel view type today ([existing code G2][bl-existing]).
- **Q1, Q5.** Skia keeps alpha state in the runtime descriptor (`kUnknown`, `kOpaque`,
  `kPremul`, `kUnpremul`), validated against the colour type, and makes premultiplied
  the default for anything drawn. This is evidence for option B of the baseline's
  "Where is the alpha and colour state recorded?" question, and the case for
  documenting `ImageData`'s convention ([existing code G3][bl-existing]). The verified
  `PremulAsEncoded` result is an extra caution: a model that records only "premul"
  has not said whether the premultiplied values are linear.
- **Q5.** The smallest colour model that ships at Chrome scale is a transfer
  function plus a 3x3 matrix to D50, with PQ and HLG as tagged forms. Full ICC
  appears only at decode. CICP is preferred over ICC when present. That splits the
  work between an image-core type (small, `@nogc`) and a codec-side profile (large:
  `skcms_ICCProfile` is 976 bytes, verified with `sizeof`). The colour gaps are in
  the [existing code baseline][bl-existing] (G4, G5) and in [wired G15][bl-wired].
- **Q4.** The three decode entry points are a usable minimum, with each codec stating
  which it supports: whole image, incremental with a row count, and scanline with
  skip. So is the split between a recoverable `kIncompleteInput` and a fatal
  `kErrorInInput`. In D that pair maps onto an `Expected` error kind, not an
  exception. The Wuffs comment is the warning: a synchronous stream contract does
  not fit an asynchronous source, which is the seam `sparkles:event-horizon` has to
  provide ([event-horizon G6][bl-eh], [wired G3][bl-wired]).
- **Q4, Q8.** Skia's hostile-input record is a migration in progress: Wuffs for GIF,
  Rust options for two formats and experimental ones for two more, C for the rest, and
  a memory budget honoured by only two callers. A D codec layer can make the budget a
  parameter of every entry point from the start and prove it with per-mode fuzzers in
  the shape of `FuzzIncrementalImage` ([hostile-input thread][p-hostile]).
- **Q3, Q7.** The raster pipeline handles the format product with runtime stage
  lists over a portable vector source compiled per ISA. D can express both this and
  the compile-time alternative (a static stage tuple, design by introspection).
  Whether LDC can guarantee the tail calls that make Skia's stage ABI cheap was not
  tested here. Skia also runs three independent CPU dispatchers (pipeline, `skcms`,
  swizzler), the duplication the [shaders and SIMD baseline][bl-shaders] (G5) warns
  against for Sparkles.
- **Q6.** Two upload patterns are worth comparing with the one Sparkles path. One is
  conversion fused into the staging write (Graphite `TextureFormatXferFn`). The
  other is a ladder for a lazy image: cache, native texture, YUV planes with GPU
  conversion, CPU bitmap (Ganesh). Graphite's client-owned `ImageProvider` is one
  answer to the duplicated texture caches in [vulkan G12][bl-vk]. The RGBA8-only
  upload is [existing code G8][bl-existing].
- **Q9.** Skia's package lines are evidence for a split with a registration seam. The
  image model lives in `core`. Codecs are build-flag-selected modules behind
  `SkCodecs::Register`, with `SK_DISABLE_LEGACY_INIT_DECODERS` for clients that link
  only what they register. `skcms` is a separate module with no Skia dependency. The
  registry avoids static initialisers by design, which matters for betterC, wasm and
  Android, where `shared static this()` is unverified
  ([shaders and SIMD G6][bl-shaders]).
- **Q8.** The `dm` mode matrix (every image through every decode mode) is a cheap
  conformance oracle once a codec has several entry points: each mode must agree
  with the whole-image decode. The existing oracles are single-purpose and
  byte-exact ([existing code G11][bl-existing]).
- **Q2.** Skia's genericity is virtual dispatch plus function-pointer records, chosen
  for code size and ABI stability across Chrome, Android and Flutter. Sparkles has no
  ABI to keep, so this is evidence about the cost of the runtime design, not a model
  to copy. See [Boost.GIL](./boost-gil.md) for the opposite trade.

## Strengths

- One descriptor (`SkImageInfo`) used by every producer and consumer, with alpha and
  colour space required parts of it, not side channels.
- Ownership levels documented in each header; borrowing (`SkPixmap`,
  `RasterFromPixmap` with a release procedure) is first-class.
- A codec API that covers incremental, scanline, subset, scaled, YUV-planar and
  animated decoding, with per-frame dependency data a viewer can use to skip work.
- Colour management at decode through `skcms`: ICC v2 and v4, CICP preference, PQ and
  HLG with an explicit reference white, gain maps.
- Memory-safe decoders adopted one format at a time behind an unchanged API (Wuffs,
  Rust).
- Fuzzers per entry point, and a test tool that runs every image through every
  decode mode.

## Weaknesses

- Incremental decoding is missing for the default JPEG codec (`SkJpegCodec`), WebP,
  AVIF and JPEG XL, and the synchronous `SkStream` contract is stretched by
  asynchronous sources (the Wuffs comment).
- `fMaxDecodeMemory` is honoured by only `getImage` and the JPEG codec at this
  revision.
- `int` dimensions and a 2^31 − 1 byte cap per image; stride cannot be negative; no
  tiles or N-D extents.
- `SkColorSpace` cannot represent LUT profiles, so colour fidelity for them depends
  on converting at decode, and is lost if the caller requests a null destination
  colour space.
- `kN32_SkColorType` changes meaning by platform; `PremulAsEncoded` makes the
  linearity of premultiplied data depend on the destination transfer function.
- Three separate CPU-feature dispatchers; `Register` is not thread-safe.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                              | Trade-off                                                                                   |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Pixel format as a runtime enum in `SkImageInfo`            | One ABI-stable descriptor for CPU, GPU and codecs; code size                           | No compile-time specialisation; every kernel dispatches or goes through the pipeline        |
| `rowBytes` beside, not inside, the descriptor              | The same `SkImageInfo` describes a request, a surface and a buffer                     | Every API takes the pair; mismatches checked only by `validRowBytes` and factory validation |
| Borrowed, shared and immutable storage as distinct types   | Lifetime explicit at each call site; immutable images cacheable by `uniqueID()`        | Conversions between levels (snapshot, `asImage`, `peekPixels`) are a large API surface      |
| Lazy `SkImage` with a purgeable decode cache               | Most images are drawn small, late or never; memory pressure handled centrally          | Re-decode after purge; decode latency appears at draw time                                  |
| Pull codec over `SkStream`, incremental by re-call         | Fits synchronous embedders; the codec keeps no I/O state except inside Wuffs           | Rewinds; asynchronous sources need workarounds; row-granular suspension only                |
| Premultiplied default, `PremulAsEncoded` only              | Compositing and filtering need premultiplied data; one convention in `skcms`           | Linearity of premultiplied data follows the destination's encoding                          |
| `SkColorSpace` = transfer function + matrix; ICC at decode | Small, hashable, cheap equality; LUT profiles handled once                             | LUT profiles cannot be carried on an image or a surface                                     |
| Runtime stage pipeline, lowp first, highp fallback         | Linear rather than combinatorial code; 16-bit speed when every stage allows it         | Indirect calls per stage per pixel batch; relies on compiler tail calls for its ABI         |
| Decoder registry of function-pointer records               | Clients link only the codecs they need; Rust and Wuffs replacements without API change | Not thread-safe; first `isFormat` match wins, so order matters                              |
| Client-owned GPU image cache (Graphite `ImageProvider`)    | Embedders already have cache policy; Graphite stays stateless across `Recorder`s       | Every client writes a cache; a draw is dropped when the requirements are not met            |

## Sources

- Skia source at `3ad790ab4d6d596efae0d70e4b8bf7d339121984`: `include/core/` (`SkImageInfo.h`,
  `SkColorType.h`, `SkAlphaType.h`, `SkPixmap.h`, `SkBitmap.h`, `SkPixelRef.h`, `SkImage.h`,
  `SkSurface.h`, `SkColorSpace.h`, `SkTextureCompressionType.h`), `include/codec/` (`SkCodec.h`,
  `SkCodecAnimation.h`), `include/private/` (`SkEncodedInfo.h`, `SkGainmapInfo.h`), `src/codec/`,
  `experimental/rust_jpeg/`, `experimental/rust_ico/`, `src/core/` (raster pipeline, colour-space
  steps, `SkOpts.cpp`), `src/opts/`, `src/image/`, `src/gpu/ganesh/image/`,
  `src/gpu/graphite/task/`, `include/gpu/`, `rust/png/`, `fuzz/oss_fuzz/`, `dm/`, `DEPS`.
- Vendored `skcms` under `modules/skcms/` (`skcms.cc`, `src/skcms_public.h`, `BUILD.gn`).
- [skia.org documentation][docs] and the [API reference][api].
- The survey's [concepts][concepts], [hostile-input][p-hostile] and
  [resampling and colour][p-colour] threads; baselines for
  [existing code][bl-existing], [shaders and SIMD][bl-shaders], [Vulkan][bl-vk],
  [event-horizon][bl-eh] and [wired][bl-wired].

<!-- References -->

[repo]: https://github.com/google/skia
[docs]: https://skia.org/docs/
[api]: https://api.skia.org/
[license]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/LICENSE
[tp-readme]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/third_party/README
[deps]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/DEPS#L60-L87
[skcms-readme]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/README.chromium
[skcms-gn]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/BUILD.gn#L32-L80
[alpha-type]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkAlphaType.h#L11-L32
[ct-doc]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkColorType.h#L13-L145
[ct-n32]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkColorType.h#L145-L157
[color-info]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkImageInfo.h#L110-L202
[ii-fields]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkImageInfo.h#L622-L626
[ii-validrb]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkImageInfo.h#L598-L611
[validate-at]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkImageInfo.cpp#L239-L288
[byte-size]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkImageInfo.cpp#L149-L162
[ii-valid]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkImageInfoPriv.h#L220-L234
[pixmap]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkPixmap.h#L28-L39
[pixmap-ctor]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkPixmap.h#L54-L74
[pixmap-subset]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkPixmap.h#L129
[bitmap]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkBitmap.h#L36-L56
[bitmap-fields]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkBitmap.h#L1243-L1244
[install-pixels]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkBitmap.h#L596-L608
[pixelref]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkPixelRef.h#L24-L60
[image-class]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkImage.h#L249-L270
[deferred]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkImage.h#L86-L107
[raster-from]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkImage.h#L176-L217
[surface]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkSurface.h#L151-L162
[lazy-ro]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/image/SkImage_Lazy.cpp#L112-L156
[min-bytes]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodec.h#L61-L72
[result]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodec.h#L74-L129
[selection]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodec.h#L136-L154
[get-icc]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodec.h#L241-L245
[options]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodec.h#L315-L390
[getpixels-doc]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodec.h#L392-L430
[get-image]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodec.h#L443-L449
[yuva]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodec.h#L451-L473
[incremental]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodec.h#L475-L526
[scanline-order]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodec.h#L598-L628
[frameinfo]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodec.h#L660-L836
[gainmap-hooks]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodec.h#L847-L852
[skcodecs]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodec.h#L1138-L1176
[anim]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/codec/SkCodecAnimation.h#L12-L58
[registry]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkCodec.cpp#L86-L157
[budget]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkCodec.cpp#L483-L576
[jpeg-budget]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkJpegCodec.cpp#L530-L621
[fill-incomplete]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkCodec.cpp#L540-L562
[fill-impl]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkCodec.cpp#L781-L798
[xform]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkCodec.cpp#L840-L898
[encoded-info-fields]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/private/SkEncodedInfo.h#L239-L247
[gainmap]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/private/SkGainmapInfo.h#L16-L43
[jxl-todo]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkJpegxlCodec.cpp#L455-L466
[rust-png]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/rust/png/README.md#L54-L60
[jpeg-rust-modes]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/experimental/rust_jpeg/decoder/impl/SkJpegRustCodec.h#L47-L74
[ico-rust-modes]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/experimental/rust_ico/decoder/impl/SkIcoRustCodec.h#L60-L85
[wuffs-safety]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkWuffsCodec.cpp#L70-L79
[wuffs-fill]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkWuffsCodec.cpp#L86-L113
[wuffs-pixfmt]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkWuffsCodec.cpp#L177-L197
[wuffs-modes]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkWuffsCodec.cpp#L254-L267
[wuffs-twopass]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkWuffsCodec.cpp#L269-L289
[wuffs-state]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/codec/SkWuffsCodec.cpp#L296-L340
[cs-api]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkColorSpace.h#L274-L345
[cs-cicp]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkColorSpace.h#L292-L313
[cs-make]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkColorSpace.cpp#L331-L407
[skcms-tf]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/src/skcms_public.h#L64-L90
[skcms-pqhlg]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/src/skcms_public.h#L116-L157
[skcms-parse]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/src/skcms_public.h#L296-L311
[skcms-alpha]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/src/skcms_public.h#L415-L445
[skcms-grid]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc#L37-L41
[skcms-cpu]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/modules/skcms/skcms.cc#L2475-L2531
[xform-steps]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkColorSpaceXformSteps.h#L21-L64
[xform-apply]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkColorSpaceXformSteps.cpp#L267-L275
[rp-musttail]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkRasterPipeline.h#L29-L37
[rp-doc]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkRasterPipeline.h#L39-L52
[rp-stage]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkRasterPipeline.h#L54-L73
[rp-ops-lowp]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkRasterPipelineOpList.h#L11-L16
[rp-ops-highp]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkRasterPipelineOpList.h#L162-L186
[rp-build]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkRasterPipeline.cpp#L590-L632
[rp-targets]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/opts/SkRasterPipeline_opts.h#L76-L100
[rp-abi]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/opts/SkRasterPipeline_opts.h#L1737-L1879
[opts]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/core/SkOpts.cpp#L20-L77
[lock-tex]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/gpu/ganesh/image/GrImageUtils.cpp#L284-L400
[ganesh-api]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/gpu/ganesh/SkImageGanesh.h#L59-L284
[tex-comp]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/core/SkTextureCompressionType.h#L10-L28
[img-provider]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/include/gpu/graphite/ImageProvider.h#L18-L64
[upload-src]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/gpu/graphite/task/UploadTask.cpp#L109-L160
[upload-align]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/src/gpu/graphite/task/UploadTask.cpp#L69-L101
[dm-modes]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/dm/DMSrcSink.h#L173-L186
[fuzz-incr]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/fuzz/oss_fuzz/FuzzIncrementalImage.cpp#L13-L56
[fuzz-image]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/fuzz/oss_fuzz/FuzzImage.cpp#L14-L37
[concepts]: ./concepts.md
[p-hostile]: ./papers/hostile-input-safety.md
[p-colour]: ./papers/resampling-colour.md
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-vk]: ./baseline/vulkan.md
[bl-eh]: ./baseline/event-horizon.md
[bl-wired]: ./baseline/wired.md
