# OpenEXR (C and C++)

The Academy Software Foundation's reference implementation of the EXR format: named
`half`, `float` and `uint` channels, scanline, tiled, multi-part and deep storage, a
dozen chunk compressors, and two APIs, a C++ frame-buffer interface over a C core
(`OpenEXRCore`) that was rewritten for thread safety and hostile input.

| Field         | Value                                                                                                                                       |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C (`OpenEXRCore`, plus two C++ files that wrap OpenJPH), C++ (`OpenEXR`, `OpenEXRUtil`, `IlmThread`, `Iex`); Python bindings                |
| License       | BSD-3-Clause ([`LICENSE.md`][license])                                                                                                      |
| Repository    | [AcademySoftwareFoundation/openexr][repo]                                                                                                   |
| Revision read | `b0460b224e4c877c2aee6d6e2c2ab048514c872f` (October 26, 2026; `openexr_version.h` says `4.0.0`, the release notes stop at `3.5.2`)          |
| Documentation | [openexr.com][docs]; the in-tree sources under `website/` ([Technical Introduction][techintro], [File Layout][layout], [Core API][coreapi]) |
| Category      | Formats                                                                                                                                     |
| Tier          | A                                                                                                                                           |
| Last reviewed | November 15, 2026                                                                                                                           |

> [!NOTE]
> OpenEXR is the survey's reference for a **scene-linear, floating-point, multi-channel**
> format and for a codec library whose core was **rewritten** to be thread-safe and
> fail-closed, then hardened by years of OSS-Fuzz and an audit that produced dozens of
> CVEs. Where this page says **verified**, a program was compiled and run in a scratch
> directory under `/tmp` against the nixpkgs build of release `3.3.8` and run again
> against release `3.5.1` (the nixpkgs build the repository's flake resolves), not the
> pinned `4.0.0` development revision; both predate fixes listed in
> [`SECURITY.md`][security-known], which did not matter for the well-formed and
> truncated files used. Everything else was read in the pinned tree with `git show`.

---

## Overview

### What it solves

Film and visual-effects pipelines need pixels that keep their physical meaning:
scene-referred, linear light, with values far above 1.0, many named channels per pixel
(colour, alpha, depth, motion vectors, object IDs, per-light passes), several views
(left and right eye) and, for deep compositing, a variable number of samples per pixel.
The README states the purpose:

> _"The purpose of EXR format is to accurately and efficiently represent
> high-dynamic-range scene-linear image data and associated metadata, with strong
> support for multi-part, multi-channel use cases."_ ([`README.md`][readme])

and the scope limit:

> _"OpenEXR is intended solely for 2D data. It is not appropriate for storage of
> volumetric data, cached or lit 3D scenes, or more complex 3D data such as light
> fields."_ ([`README.md`][readme])

An EXR image has two rectangles: the **display window** (the frame) and the **data
window** (where pixels exist), which may be larger (overscan for blurs and camera
shake), smaller (a re-rendered region of interest) or offset into negative coordinates
([Technical Introduction][techintro-windows]). Pixels are stored in **chunks**: 1, 16,
32 or 256 scanlines depending on the compressor, or one tile; a part has an offset table
with one 64-bit file offset per chunk ([File Layout][layout-offsets]).

### Design philosophy

The project lists its priorities in order, with security first:

> _"Robustness, reliability, security · Backwards compatibility, data longevity ·
> Performance - read/write/compression/decompression time · Simplicity, ease of use,
> maintainability"_ ([`README.md`][readme-prio], list items joined)

The C core was introduced in 3.1.0 (July 22, 2021) to fix a structural problem of the
C++ API, the coupling of a mutable frame buffer to every read:

> _"The OpenEXRCore library provides thread-safe, non-blocking access to files, which
> was not possible with the current API, where the framebuffer management is separate
> from read requests. It is written entirely in C and provides a new C-language API
> alongside the existing C++ API. This new low-level API allows applications to do
> custom unpacking of EXR data, such as on the GPU, while still benefiting from
> efficient I/O, file validation, and other semantics."_
> ([`CHANGES.md`, 3.1.0][changes-31])

Its documentation names the two rules that shaped the API, a per-file context with no
hidden globals and a result code from every call:

> _"Every routine returns a result code (success or an error code). [...] This rule of
> every function returning a result code means that in some scenarios, the code may be
> slightly more verbose, but it should be a safer library in the long run."_
> ([`OpenEXRCoreAPI.rst`][coreapi])

Since 3.3.0 (September 30, 2024) the C++ API reads and writes through the core, and
"all compression routines are implemented by the C Core layer underneath and no longer
duplicated" ([`CHANGES.md`, 3.3.0][changes-33]). The rewrite's stated motive was
throughput (lock-free concurrent chunk reads) and reuse (GPU unpack, bindings for other
languages); the safety benefit came from the same design (one validation layer, result
codes, explicit size fields) and from the fuzzing that followed. "Non-blocking" in the
3.1.0 note means "not serialised behind a per-file lock": the core's read callback is a
blocking `pread` ([`openexr_context.h`][ctx-read]).

---

## How it works

### File structure

A file is a magic number (`20000630`), a version word whose flag bits mark single-part
tiled (bit 9), long names (bit 10), deep data (bit 11) and multi-part (bit 12), one or
more headers of typed attributes, one chunk offset table per part, then the chunks
([`OpenEXRFileLayout.rst`][layout-version]). A chunk in a multi-part file starts with its
part number; scanline chunks then carry `y` and a packed size, tiles carry tile and level
coordinates, deep chunks add a packed sample-count table size and an unpacked size
([`OpenEXRFileLayout.rst`][layout-chunk]). The core models the four storage kinds and the
three sample types as small enums:

```c
// src/lib/OpenEXRCore/openexr_attr.h (abridged)
typedef enum { EXR_STORAGE_SCANLINE = 0, EXR_STORAGE_TILED,
               EXR_STORAGE_DEEP_SCANLINE, EXR_STORAGE_DEEP_TILED, ... } exr_storage_t;
typedef enum { EXR_PIXEL_UINT = 0, EXR_PIXEL_HALF = 1, EXR_PIXEL_FLOAT = 2, ... } exr_pixel_type_t;
```

([`openexr_attr.h`][attr-enums]). A channel is a name, a pixel type, a perceptual
linearity flag (used by lossy compressors) and integer `x_sampling`/`y_sampling` factors,
which is how EXR stores chroma-subsampled luminance/chroma images
([`openexr_attr.h`][attr-chlist]; [concepts: chroma subsampling][concepts-chroma]). Channel
names are free strings; layers and views are naming conventions (`left.R`, `diffuse.G`)
plus the `multiView` attribute, not structure.

### Compression methods

Every method works on one chunk at a time, which is what makes chunks independently
decodable ([`compression.c`][comp-lines]; descriptions from
[`TechnicalIntroduction.rst`][techintro-comp]):

| Method                | Lines per chunk | Lossy | Deep | Mechanism                                                                    |
| --------------------- | --------------- | ----- | ---- | ---------------------------------------------------------------------------- |
| `NONE`, `RLE`, `ZIPS` | 1               | no    | yes  | none; byte RLE of differences; deflate per scanline                          |
| `ZIP`                 | 16              | no    | no   | byte split + horizontal differences, deflate (via `libdeflate` since 3.2)    |
| `PIZ`                 | 32              | no    | no   | Haar wavelet over 16-bit values, LUT of used values, Huffman                 |
| `PXR24`               | 16              | yes   | no   | `float` rounded to 24 bits, differences, deflate; `half`/`uint` exact        |
| `B44`, `B44A`         | 32              | yes   | no   | fixed-rate 4x4 blocks of `half` into 14 bytes (3 for flat blocks in `B44A`)  |
| `DWAA`, `DWAB`        | 32, 256         | yes   | no   | 8x8 DCT with quantisation on RGB in a perceptual domain                      |
| `HTJ2K32`, `HTJ2K256` | 32, 256         | no    | no   | High-Throughput JPEG 2000 (ITU-T T.814) via the vendored OpenJPH (since 3.4) |
| `LJ2K`                | 256             | yes   | no   | HTJ2K, lossy on RGB only (since 3.5)                                         |
| `ZSTD`                | 1               | no    | yes  | byte shuffle, optional delta, Zstandard (since 3.5)                          |

The deep column is `exr_compression_is_valid_for_deep` ([`compression.c`][comp-lossy]).
The enum values are the on-disk byte, and the release notes say an HTJ2K file is not
readable by software built before 3.4 ([`CHANGES.md`, 3.4.0][changes-34]). How it fails
depends on the mode: the core rejects a byte at or above its own `EXR_COMPRESSION_LAST_TYPE`
([`parse_header.c`][comp-parse]), which fails `exr_start_read` only under
`EXR_CONTEXT_FLAG_STRICT_HEADER`; by default the attribute error is swallowed
([`parse_header.c`][parse-loop]) and the missing compression is replaced by `ZIP` ([`validation.c`][validate-req]). **Verified** on
3.5.1 with a `PIZ` file whose compression byte was set to 14: strict mode returns
`EXR_ERR_INVALID_ATTR`, default mode opens the file as `ZIP` with 16 lines per chunk and
then fails the chunk reads with `EXR_ERR_BAD_CHUNK_LEADER`.

### The C++ API: `FrameBuffer` and `Slice`

The C++ reader describes the caller's memory, one `Slice` per channel, and the library
writes each decoded sample to the address the slice computes:

```cpp
// src/lib/OpenEXR/ImfFrameBuffer.h (abridged)
struct Slice {
    PixelType type;
    //  base + (xp / xSampling) * xStride + (yp / ySampling) * yStride
    char*  base;
    size_t xStride;
    size_t yStride;
    int    xSampling, ySampling;
    double fillValue;              // written when the file lacks this channel
    bool   xTileCoords, yTileCoords;
};
```

([`ImfFrameBuffer.h`][slice]). This is a byte-[stride][concepts-stride] view per channel
with absolute pixel coordinates: `base` is the address of pixel `(0, 0)`, which for a data
window starting at `(1000, 400)` lies before the allocation. The documentation's own
example builds it that way:

```cpp
// website/src/readGZ1.cpp
frameBuffer.insert ("R",
    Slice (HALF,
           (char *) (&rPixels[0][0] - dw.min.x - dw.min.y * width),  // base
           sizeof (rPixels[0][0]) * 1,                               // xStride
           sizeof (rPixels[0][0]) * width,                           // yStride
           1, 1, 0.0));
file.setFrameBuffer (frameBuffer);
file.readPixels (dw.min.y, dw.max.y);
```

([`readGZ1.cpp`][readgz1]). Forming that pointer is undefined behaviour in C and C++, and
it overflowed in practice: `ImfRgbaFile.h` added `ComputeBasePointer` because "with large
offsets for the data window, the naive code can wrap around, especially on 32-bit
machines" ([`ImfRgbaFile.h`][computebase]), and `Slice::Make` does the same for the
general API ([`ImfFrameBuffer.h`][slice]). The data-window origin also produced 3.4.14
CVEs in `OpenEXRUtil` and `exrmetrics`, whose row addressing "assumed a data window
originating at (0, 0)" ([`CHANGES.md`, 3.4.14][changes-3414]); three of them are
`OpenEXRUtil` "row nonzero dataWindow" bugs ([`CHANGES.md`, 3.4.14 list][changes-3414-list]).
`RgbaInputFile` is the simple interface on top: it
maps any channel set (including luminance/chroma and a named layer) to an `Rgba` array of
`half` ([`ImfRgbaFile.h`][rgbafile]).

Interleaved RGBA, planar buffers and a mix of the two are all expressed by the strides; a
slice with no file channel is filled with `fillValue`
([`ReadingAndWritingImageFiles.rst`][rw-general]), and a file channel with no slice is
skipped: the C++ layer gives it a `NULL` decode pointer ([`ImfScanLineInputFile.cpp`][update-ptrs]).

### The C core: context, chunks and the decode pipeline

A read starts with `exr_start_read`, which parses and validates every header before it
returns, "such that it is easier to provide a safe context for multiple threads to request
data from the same context concurrently" ([`openexr_context.h`][ctx-start]). The
initializer carries the I/O, memory and error callbacks and the limits:

```c
// src/lib/OpenEXRCore/openexr_context.h (abridged)
typedef struct _exr_context_initializer_v4 {
    size_t size;                              /* version tag */
    exr_error_handler_cb_t     error_handler_fn;
    exr_memory_allocation_func_t alloc_fn;    exr_memory_free_func_t free_fn;
    void* user_data;
    exr_read_func_ptr_t        read_fn;       /* pread-like, must be thread-safe */
    exr_query_size_func_ptr_t  size_fn;       /* enables size-based validation */
    exr_write_func_ptr_t       write_fn;      exr_destroy_stream_func_ptr_t destroy_fn;
    int max_image_width, max_image_height, max_tile_width, max_tile_height;
    int zip_level; float dwa_quality; int flags; float lossy_htj2k_quality; int zstd_level;
} exr_context_initializer_t;
```

([`openexr_context.h`][ctx-init]). All pixel I/O is in chunk units. `exr_read_scanline_chunk_info`
or `exr_read_tile_chunk_info` fill an `exr_chunk_info_t` (index, position, size, level,
compression, file offset, packed and unpacked sizes, deep sample-table offset and size),
reading the chunk leader to do so ([`openexr_chunkio.h`][chunkio]). The chunk can then be
read raw with `exr_read_chunk`, or decoded by a **pipeline**:

```c
// the decode loop, as in src/lib/OpenEXRUtil/ImfCheckFile.cpp (abridged)
exr_decode_pipeline_t decoder = EXR_DECODE_PIPELINE_INITIALIZER;
for (each chunk y) {
    exr_read_scanline_chunk_info (f, part, y, &cinfo);
    if (first) {
        exr_decoding_initialize (f, part, &cinfo, &decoder);
        for (c in decoder.channels) {           /* caller describes output memory */
            outc.decode_to_ptr     = dst;
            outc.user_pixel_stride = outc.user_bytes_per_element;
            outc.user_line_stride  = outc.user_pixel_stride * width;
        }
        exr_decoding_choose_default_routines (f, part, &decoder);
    } else
        exr_decoding_update (f, part, &cinfo, &decoder);
    exr_decoding_run (f, part, &decoder);       /* read, decompress, unpack */
}
exr_decoding_destroy (f, &decoder);
```

([`ImfCheckFile.cpp`][checkfile-core]). The pipeline struct is per thread and holds
everything that varies per chunk: the channel descriptors, the `packed_buffer`,
`unpacked_buffer` and two scratch buffers with their allocation sizes (reused across
chunks), an optional per-buffer allocator tagged by buffer kind "if decoding on a GPU",
and four replaceable stage functions, `read_fn`, `decompress_fn`,
`realloc_nonimage_data_fn` and `unpack_and_convert_fn` ([`openexr_decode.h`][decode]).
The output side of each channel is a byte pointer plus `int32_t` pixel and line strides
relative to the chunk's first pixel, with an output type that may differ from the file's
(`half` to `float`, for instance) ([`openexr_coding.h`][coding]).

`exr_decoding_choose_default_routines` inspects the requested layout at run time and picks
a specialised unpacker: for uncompressed data whose output is planar, same-typed and
complete it installs `read_uncompressed_direct` and no decompress or unpack stage at all;
otherwise it selects among routines such as `unpack_16bit_4chan_interleave`,
`unpack_half_to_float_3chan_planar` and `generic_unpack` from the channel count, types,
strides and interleave pattern ([`decoding.c`][choose]; [`unpack.c`][unpack-list]).
`exr_decoding_initialize` does not install a reader: **verified** on 3.3.8 and 3.5.1, calling
`exr_decoding_run` without `choose_default_routines` fails with "Decode pipeline has no
read_fn declared", although the `read_fn` field's comment says it is "Initialized to a
default generic read routine" ([`openexr_decode.h`][decode-readfn]); at the pin only
`exr_decoding_choose_default_routines` assigns `read_fn`, and [`decoding.c`][decoding-run]
has the same check.

**Verified** on 3.3.8 and 3.5.1 with a 64 by 64 `ZIP` file whose data window is `(-8, -8)-(55, 55)`:
the chunk containing `y = 8` reports `start_y = 8`, 16 lines, 189 packed and 8192 unpacked
bytes; a pipeline with only the `R` channel pointed at a `float` buffer (stride 4, line
stride 256) and the other three channels `NULL` decodes that one chunk, writing 1024
values and converting `half` to `float`.

---

## Analysis

### 1. Pixel and memory model

On disk, a chunk is planar per scanline: each line stores all of channel 1, then all of
channel 2, in alphabetical channel order, with subsampled channels contributing fewer
samples (`compute_sampled_width` in [`chunk.c`][chunk-unpack-size]). In memory, the
caller chooses: the C++ `Slice` is a 2-D byte-strided view per channel addressed in
absolute image coordinates (or tile-relative coordinates for tiled reads), and the core's
`exr_coding_channel_info_t` is a 2-D byte-strided view per channel addressed relative to
the chunk. There is no image object; the library never owns the decoded pixels. Element
types are three (`half`, `float`, `uint`); there is no 8-bit sample and no signed integer.

Two width choices stand out. The C++ strides are `size_t`, so a negative stride (bottom-up
rows) is expressed by unsigned wrap-around; the core's are `int32_t`, and the C++ layer
narrows one into the other with an implicit conversion
(`curchan.user_line_stride = fbslice->yStride;` in [`ImfScanLineInputFile.cpp`][update-ptrs]).
A row stride of 2 GiB or more therefore cannot be described to the core. **Verified** on
3.5.1: reading a 1 by 2 `ZIP` `float` file through `InputFile` with `yStride = 2^32 + 4`
(into a `MAP_NORESERVE` mapping) writes row 1 at byte offset 4, not at `2^32 + 4`, with no
error. Coordinates are `int32_t` throughout, and windows are rejected beyond
`INT32_MAX / 2` in either direction ([`validation.c`][validate-dims]).

Tiles support single level, MIP-map and RIP-map (independent x and y reduction) pyramids
with round-down or round-up level sizes ([`openexr_attr.h`][attr-enums];
[concepts: tiling][concepts-tiling]). Deep parts store, per chunk, a cumulative
sample-count table and then each channel's samples for every pixel; the decode flag
`EXR_DECODE_SAMPLE_COUNTS_AS_INDIVIDUAL` converts the on-disk prefix sums into
per-pixel counts ([`openexr_decode.h`][decode-flags]).

Compared with the [concepts: image and view][concepts-view] taxonomy, EXR's model is a
named set of 2-D planes sharing one data window, each with its own type and sampling,
which is closer to a struct of planes than to an interleaved pixel array.

### 2. Genericity mechanism

None at the type level: the C++ API is runtime-typed (`PixelType` in each `Slice`) and the
core is C with enum tags. Specialisation is done at run time by **inspecting the requested
layout** and selecting a function pointer (`choose_default_routines`, above), which is the
run-time counterpart of design by introspection. The four pipeline stages are the
extension points ("customize the stages that make the most sense", for example a GPU
unpack ([`OpenEXRCoreAPI.rst`][coreapi-pipeline])); attribute types are extensible
through custom handlers registered on the context. Versioning of the C structs is by a
leading `size` field (`exr_context_initializer_t`, `exr_decode_pipeline_t`), so new fields
can be appended without breaking callers ([`openexr_context.h`][ctx-init]).

### 3. Colour and metadata

EXR pixels are scene-linear by convention; there is no transfer-function tag because the
format assumes linear light. Colour identity is carried by attributes:

- `chromaticities`: CIE xy of the primaries and white point, defaulting to Rec. ITU-R
  BT.709 when absent ([`ImfChromaticities.h`][chroma]); "for most purposes, this attribute
  has now been superseded by the colorInteropID" ([`StandardAttributes.rst`][stdattr-colour]).
- `colorInteropID` (since 3.4): a string from the Color Interop Forum vocabulary such as
  `lin_ap0_scene`. Since 3.5 the core maps the six linear scene-referred IDs to
  chromaticities and back, and `exr_check_color_metadata` reports inconsistencies as
  warning flags (an ID of `data` with chromaticities present, a multi-part file whose parts
  disagree, an ACES container flag with non-AP0 primaries) rather than errors
  ([`openexr_color_metadata.h`][colormeta]).
- `whiteLuminance` (nits of RGB 1.0) and `adoptedNeutral` ([`StandardAttributes.rst`][stdattr-colour]).

There is **no ICC profile, no [CICP][concepts-cicp], no [gain map][concepts-gainmap], no
EXIF and no XMP** attribute in the standard set: a search of `src/lib` and `website/` for
`ICC`, `EXIF` and `XMP` finds only Intel-compiler macros. Camera and lens metadata are
native typed attributes: `cameraMake`, `lensModel` and their siblings were added for SMPTE
on-set workflows in 3.2 ([`CHANGES.md`, 3.2.0][changes-32]), beside the older `timeCode`
and `keyCode` ([`StandardAttributes.rst`][stdattr-time]). Arbitrary metadata is an
open attribute list with 31 attribute types (`box2i`, `m44d`, `string_vector`, `preview`,
`opaque` for unknown types, and so on) ([`openexr_attr.h`][attr-types]).

Alpha is premultiplied by convention: _"By convention, all color channels are
premultiplied by alpha, so that composite = foreground + (1-alpha) × background performs a
correct "over" operation"_ ([`TechnicalIntroduction.rst`][techintro-premult]; see
[concepts: straight and premultiplied alpha][concepts-alpha]). The convention is not
recorded per file. Luminance/chroma storage (`Y`, `RY`, `BY`) derives its weights from the
file's chromaticities ([`TechnicalIntroduction.rst`][techintro-comp]).

### 4. I/O and codec architecture

**API shape.** Decoding is **pull**: the core calls `read_fn(ctxt, userdata, buffer, sz,
offset, error_cb)`, which "Expects similar semantics to pread"; "It is required that this
provides thread-safe concurrent access to the same file" ([`openexr_context.h`][ctx-read]). There is no push
or feed interface and no suspension: a `read_fn` cannot return "would block"
([concepts: push and pull][concepts-pushpull]). Decoding is **incremental by chunk** and
**random access**: any chunk of any part can be requested in any order once the header is
parsed, and the offset table is loaded lazily on the first chunk request. It is **not
progressive** within a chunk ([concepts: incremental, progressive and suspendable][concepts-incr]).

**Region and scale.** A region is read by requesting only the chunks that intersect it
(`readPixels(y1, y2)`, `readTiles(dx1, dx2, dy1, dy2, lx, ly)`, or the core chunk calls);
inside a chunk the whole chunk is decompressed and the core can skip lines at either end
(`user_line_begin_skip`, `user_line_end_ignore`) ([`openexr_decode.h`][decode]).
A downscaled image is a lower MIP or RIP level of a tiled file; scanline files have no
reduced-resolution decode beyond the embedded 8-bit `preview` attribute.
`EXR_DECODE_NON_IMAGE_DATA_AS_POINTERS` lets a caller scatter samples through per-pixel
pointers, for example to read every other pixel, "although all the pixels must be
initially decompressed" ([`openexr_decode.h`][decode-flags]).

**Layering.** Container parsing (header, offset tables, chunk leaders) is separate from
the bitstream codecs, which are separate from unpacking. `exr_read_chunk` returns packed
bytes for copy or split tools; `exr_uncompress_chunk` and the public
`exr_uncompress_buffer` and `exr_rle_uncompress_buffer` work on buffers with no file at all
([`openexr_compression.h`][compression-h]). An asynchronous caller could do its own I/O by
replacing `read_fn` in the pipeline and filling `packed_buffer` itself, but
`exr_read_*_chunk_info` still reads the chunk leader and the offset table through the
context's blocking callback. `exr_chunk_default_initialize` fills a chunk info without
I/O, but only with "indicative" values: no file offset or packed size
([`openexr_chunkio.h`][chunkio]).

### 5. Hostile input and safety

**Limits and defaults.** The configurable limits are maximum image width and height and
maximum tile width and height, per context or as process-wide defaults combined by fixed
rules (negative ignored, a positive value beats 0, two positives take the minimum)
([`openexr_base.h`][base-limits]). **All four defaults are 0, which disables the checks**
([`base.c`][base-defaults]). The project's position is explicit:

> _"Attempting to read a very large image may result in an "out-of-memory failure. This
> is not considered a security vulnerability. [...] Applications processing untrusted EXR
> files should set these limits to values appropriate for their deployment environment."_
> ([`ImageSizeLimit.rst`][sizelimit])

**Verified** on 3.3.8 and 3.5.1: opening the 64 by 64 file with `max_image_width = 32` fails in
`exr_start_read` with `EXR_ERR_INVALID_ATTR` and "Invalid width (64) too large (max 32)".

Fixed, non-configurable limits are spread through the parser: windows within
`INT32_MAX / 2` ([`validation.c`][validate-dims]); at most `INT16_MAX` channels, because
pipeline channel counts are `int16_t` and a larger list "silently truncates downstream (e.g.
73,728 channels wraps to 8,192)" ([`validation.c`][validate-chans]); tile sizes at most
`INT_MAX / 4`; at most 2^20 chunk-table entries, a cap inherited from the C++ layer for
streams whose size cannot be checked; attribute and chunk sizes checked against the file
size when `size_fn` provides one ([`chunk.c`][chunk-table]; [`parse_header.c`][attr-too-big]).
There is no pixel-count, total-memory, deep-sample or time budget in the library; the fuzz
harness imposes its own (`gMaxBytesPerScanline = 8000000`, `gMaxTileBytes`, a target of
2^28 pixels read) ([`ImfCheckFile.cpp`][checkfile-limits]).

**Decoder discipline.** Every compressor checks the produced size against the declared one:
`undo_zip_impl` returns `EXR_ERR_CORRUPT_CHUNK` unless deflate produced exactly
`uncompressed_size` bytes ([`internal_zip.c`][zip-undo]); PIZ checks its bitmap bounds and
each read against `packsz` ([`internal_piz.c`][piz-bounds]). The ZIP check closes
[CVE-2025-48071][ghsa-48071], a heap overflow in the core that trusted the unpacked size
from a deep scanline chunk header ("The OpenEXRCore code is vulnerable to a heap-based
buffer overflow during a write operation", affecting 3.3.0 to 3.3.2); the advisory names
`undo_zip_impl` as lacking the comparison of `actual_out_bytes` with `uncompressed_size`.

**Damaged files.** If the offset table is incomplete the core scans the file to rebuild it
unless `EXR_CONTEXT_FLAG_DISABLE_CHUNK_RECONSTRUCTION` is set; in
`EXR_CONTEXT_FLAG_STRICT_HEADER` mode a failed rebuild is an error
([`chunk.c`][chunk-table]; [`openexr_context.h`][ctx-flags]). **Verified** on 3.3.8 and
3.5.1: zeroing the first offset-table entry still decodes chunk 0 with correct values (the
rebuilt entry gives data offset 371, after the 8-byte leader of the chunk at 363) in
both default and strict mode; truncating the last 100 bytes decodes the first three chunks
and fails the fourth with `EXR_ERR_BAD_CHUNK_LEADER` ("found corrupt leader: packed size
199, file offset 982, size 1081"), the same with reconstruction disabled.

**Fuzzing.** The project runs in OSS-Fuzz with seven libFuzzer targets in `src/test/oss-fuzz`:
`exrcheck` (C++ read paths), `exrcorecheck` (core read paths through
`checkOpenEXRFile(data, size, true, true, true)`), `exrgaps` (adversarial tile coordinate
order), `attribute`, `encoding`, `htj2k` round trips and a C++-to-core `roundtrip`
([`openexr_exrcorecheck_fuzzer.cc`][fuzz-core]). Every push and pull request that touches
code builds them with AddressSanitizer through OSS-Fuzz's helper and fuzzes for 300
seconds in total, split evenly across the targets (at least 10 seconds each), with
`-rss_limit_mb=2560` ([`ossfuzz_workflow.yml`][fuzz-ci]; triggers in [the same file][fuzz-ci-on]). An older in-tree
`OpenEXRFuzzTest` damages sample files with random bytes ([`fuzzFile.cpp`][fuzzfile]).

**CVE history.** `CHANGES.md` cites 87 distinct CVE identifiers from 2006 to 2026, 38 of
them from 2026. Three are instructive for a reimplementation:

- [CVE-2025-48071][ghsa-48071] (above): a size field from the file was used to size an
  output buffer without checking the decoder's actual output.
- The ILP32 group of 3.4.14 (for example [CVE-2026-59985][cve-59985], "ILP32 OpenEXRCore RLE
  decode heap OOB read DoS" ([`CHANGES.md`, 3.4.14 list][changes-3414-list])): "On
  platforms where `size_t`/`int` are 32 bits, buffer sizes computed from
  attacker-controlled header fields [...] could overflow before an allocation or bounds
  check" ([`CHANGES.md`, 3.4.14][changes-3414]). `SECURITY.md` says the project does not
  request CVEs for 32-bit-only bugs ([`SECURITY.md`][security-policy]), yet the release's
  summary files seven CVEs under the ILP32 group, and five of the per-CVE titles name ILP32.
- [CVE-2021-3474][cve-3474], "Undefined-shift in Imf_2_5::FastHufDecoder::FastHufDecoder"
  (fixed in 2.5.4; the CVE record says versions before 3.0.0-beta), from the 2020–2021
  OSS-Fuzz wave that preceded the core rewrite ([`CHANGES.md`][changes-3474]).

### 6. Allocation and ownership

The caller owns every output buffer. The core allocates only its own state (context,
parsed attributes, the offset table, pipeline buffers) through `alloc_fn`/`free_fn` from the
initializer, or per buffer kind through the pipeline's own allocator
(`EXR_TRANSCODE_BUFFER_PACKED`, `_UNPACKED`, `_SCRATCH1`, and so on) ([`openexr_coding.h`][coding]).
Pipeline buffers are kept between chunks and grown only when a chunk needs more; a caller
may adopt any buffer by taking the pointer and setting the field to `NULL`
([`openexr_decode.h`][decode]). For deep data, `realloc_nonimage_data_fn` is called after
the sample counts are known so the caller can size sample storage. Version 3.3.0's notes
attribute faster C++ reads to "fewer memory allocations / frees" from this reuse
([`CHANGES.md`, 3.3.0][changes-33]). The offset table is published with an atomic
compare-and-swap so concurrent first readers race safely and the loser frees its copy
([`chunk.c`][chunk-table]).

### 7. CPU parallelism and SIMD

**Parallelism.** In the core, parallelism is the caller's: a context is safe for
concurrent reads once open, each thread owns an `exr_decode_pipeline_t`, and the read path
takes no lock (the mutex in the context guards writes and custom attribute handlers)
([`internal_structs.h`][structs-mutex]). The C++ layer adds a global `IlmThread` pool whose
default size is zero; with more than one thread for the file and more than one chunk to
read, `ScanLineInputFile::readPixels` reads each chunk's leader in the calling thread, then
submits one `LineBufferTask` per chunk to a `TaskGroup`, and each task runs a complete core
pipeline, including the read of the chunk's data ([`ImfScanLineInputFile.cpp`][readpixels-mt]).
The header comment in `ImfThreading.h` still says "The thread that calls the library
always performs the actual file IO" ([`ImfThreading.h`][threading-h]), which no longer
matches that code. Chunk size
sets the grain: the 3.4.0 notes report `htj2k32` "offers significantly faster encoding and
decoding (4-6x in some cases) than `htj2k256`" because it suits multi-threading
([`CHANGES.md`, 3.4.0][changes-34]) (not measured here).

**SIMD and dispatch.** Three mechanisms coexist:

| Kernel                                  | Targets                     | Dispatch                                                             |
| --------------------------------------- | --------------------------- | -------------------------------------------------------------------- |
| `half` to `float` unpack                | F16C + AVX on x86-64        | compile time if `__F16C__`, else a `constructor` function picks once |
| DWA inverse DCT, zig-zag, float to half | AVX, SSE2, F16C; NEON arm64 | `initializeFuncs` sets function pointers from `cpuid` on first use   |
| ZIP predictor reconstruction            | SSE4.1, NEON arm64          | compile time only (`__SSE4_1__`, `__aarch64__`)                      |

([`unpack.c`][unpack-f16c]; [`internal_dwa_simd.h`][dwa-dispatch]; [`internal_zip.c`][zip-simd]).
The `cpuid` probe checks `OSXSAVE` and `XGETBV` before trusting AVX
([`internal_cpuid.h`][cpuid]). On a default GCC or Clang x86-64 build without `-msse4.1`,
the ZIP predictor therefore takes the scalar path (MSVC on x86 defines `IMF_HAVE_SSE4_1`
unconditionally). `initializeFuncs` guards itself with a plain `static int done` flag, not
an atomic, and is called from `DwaCompressor_construct` on every DWA chunk
([`internal_dwa_compressor.h`][dwa-construct]). A second thread can see `done` set before
the pointers are and run the scalar defaults; formally that is a data race (read, not
demonstrated). The unpacker has "TODO: learn arm neon intrinsics"
for `half` conversion ([`unpack.c`][unpack-f16c]).

### 8. GPU offload and interop

There is no GPU code. The core was designed to permit it: the pipeline's
`unpack_and_convert_fn` can be replaced so that reading and decompression stay on the CPU
and interleaving happens on the GPU, and the buffer-kind tag on the allocator exists so a
caller can place the unpacked buffer in device-visible memory
([`OpenEXRCoreAPI.rst`][coreapi-pipeline]; [`openexr_coding.h`][coding]). The read callback's
own comment notes "This does not handle the ability to mmap a file and get to zero copy"
([`openexr_context.h`][ctx-read]). `B44` exists for real-time playback: fixed-size blocks
that decode fast and give every frame of a resolution the same file size
([`TechnicalIntroduction.rst`][techintro-comp]). None of the codecs is a GPU texture format
([concepts: GPU decompression][concepts-gpudecomp]).

### 9. Temporal, animation and containers

A file holds one frame. Sequences are numbered files; time is metadata (`timeCode`,
`keyCode`, `framesPerSecond` as a rational) ([`StandardAttributes.rst`][stdattr-time]).
What EXR does contain is spatial and semantic multiplicity: **multi-part** files (several
images, possibly of different storage kinds, each with its own header and offset table,
chunks tagged with part numbers), **multi-view** naming, and MIP/RIP levels. The core treats
every file as multi-part ("the API assumes you are always dealing with a multi-part file")
([`CHANGES.md`, 3.1.0][changes-31-design]). This makes EXR a small
[container][concepts-container] around independent chunk bitstreams, with random access
by offset table instead of sequential parsing.

### 10. Testing and conformance

The format has no separate conformance suite: the specification is the documentation plus
this implementation. The test tree builds `IexTest`, `OpenEXRCoreTest` (core reads,
writes, deep data, compression, colour metadata), `OpenEXRTest` (C++ API, compressors,
attributes, malformed images), `OpenEXRUtilTest` and `OpenEXRFuzzTest`, plus Python tests
of the command-line tools in `src/test/bin` ([`src/test/CMakeLists.txt`][test-cmake]). They
read 48 small `.exr` files kept in `src/test` (37 in `OpenEXRTest`, 11 in
`bin/test_images`), including crafted damage cases (`comp_bad_bounds_piz.exr`,
`comp_early_eof_piz.exr`, `comp_short_decode_piz.exr`, `invalid_shared_attrs_multipart.exr`,
mismatched storage-type files) and legacy-version files (`v1.7.test.*.exr`)
([`src/test/OpenEXRTest`][test-dir]). The larger sample corpus is the separate
`openexr-images` repository, which the README lists as the reference images
([`README.md`][readme-images]) and whose images the Python bindings' tests download and
round-trip ([`test_images.py`][py-test-images]). Cross-API agreement is fuzzed (`roundtrip` writes with the C++
API and reads with the core). `exrcheck`/`checkOpenEXRFile` doubles as a validator for users
and the fuzz entry point ([`ImfCheckFile.cpp`][checkfile-core]). Lossy codecs are compared
with tolerances in `compareDwa.cpp`, `compareB44.cpp` and `compareLJ2K.cpp`.

---

## Lessons for Sparkles

- **Q1** — EXR's model is a struct of named 2-D planes sharing one data window, each with
  its own sample type and subsampling, plus a display window. That covers overscan, crops,
  AOVs and chroma-subsampled planes without an interleaved pixel type, and it is the case
  the [existing-code baseline][bl-existing] G2 lacks (no planes, no strides in the
  registry, no sample type beyond 8-bit). What does not transfer is the
  absolute-coordinate base pointer: in D, `ptr - dw.min.x * xStride` is pointer arithmetic
  that `@safe` code rejects, and code that assumed a `(0, 0)` origin is behind three 2026
  `OpenEXRUtil` CVEs. A D view would carry the origin as a field and keep the base at the
  first stored pixel (the core's chunk-relative form), with `size_t` extents and
  `ptrdiff_t` byte strides; see the [mir-algorithm](./mir-algorithm/) deep-dive for a
  `Slice` with that extent and stride typing.
- **Q1/Q8** — Narrowing is where EXR failed: `size_t` strides into `int32_t` (a silent
  wrong write, verified above), channel counts into `int16_t`, and size products on 32-bit
  `size_t`. D on wasm32 and 32-bit Android has the same 32-bit `size_t`, so an EXR decoder
  in D needs checked multiplication (`core.checkedint`) on every header-derived size, and
  the ILP32 CVEs are ready-made regression tests. The [shaders-simd baseline][bl-shaders]
  G6 notes that the existing SIMD dispatch was not verified in wasm or Android builds either.
- **Q2/Q3** — Run-time layout inspection that picks a specialised unpacker
  (`choose_default_routines`) is what D's design by introspection does at compile time.
  With the output layout as a template parameter, `static if` selects the planar,
  interleaved or converting loop and the selection logic disappears; the run-time form is
  still needed where the layout comes from a caller at run time (a registry or plugin).
- **Q3/Q7** — EXR's SIMD is three mechanisms (compile-time macros, a `constructor`
  function, lazy function pointers with a non-atomic guard), and the ZIP predictor is
  scalar on default x86-64 builds. That is evidence for the single, shared dispatch facility
  the [shaders-simd baseline][bl-shaders] G5 asks for, chosen once at startup and visible to
  callers, rather than per-codec copies.
- **Q4** — The core separates container parsing, chunk bitstream codecs and unpacking, and
  each stage is callable alone (`exr_read_chunk`, `exr_uncompress_buffer`). That split is
  what a D codec needs to sit on [event-horizon][bl-eh]: the chunk table gives offsets and
  sizes, the loop issues the reads, and decompression runs on completed buffers. EXR's own
  API stops short of this because chunk-info calls still read the leader through a blocking
  callback; a D design would expose leader parsing as a pure function of bytes. Chunk
  independence also gives free parallelism and region decode, unlike PNG's single stream
  ([wired baseline][bl-wired] G3 on suspendable decode).
- **Q4/Q6** — The per-thread pipeline that owns reusable packed, unpacked and scratch
  buffers maps to `sparkles.base.buffer`: a `UniqueBuffer` per stage held by a per-worker
  decoder state, grown with `reserve`, with output written into caller storage. A
  buffer-kind tag on allocation is the hook for staging into Vulkan-visible memory
  ([Vulkan baseline][bl-vk]).
- **Q5** — EXR is the counter-example for a minimum colour model built around ICC and
  CICP: it has neither, assumes linear light, and identifies colour by primaries or a
  `colorInteropID` string. A Sparkles model needs "scene-linear with named primaries" as a
  first-class state beside transfer-function-tagged display images, plus a per-image alpha
  convention, since EXR's premultiplication is a convention and not a stored flag
  ([existing-code][bl-existing] G3, G4). `exr_check_color_metadata`'s warnings-not-errors
  approach fits a typed inspection report (G5).
- **Q5/Q8** — Defaults of 0 ("no limit") with the project declaring OOM out of scope put
  the whole resource policy on the caller. A D decoder can take a limits value with
  non-zero defaults (pixels, bytes, chunks, deep samples) and report `Expected` errors,
  which also suits `@safe pure` code that cannot read mutable globals; the fuzz harness's
  limits (8 MB per scanline, 2^28 pixels) are a starting point. See the
  [hostile-input thread][p-hostile].
- **Q8** — As oracles, the core's C API (result codes, custom read callback, no globals
  needed) is easier to call from D via ImportC than the C++ API, and `checkOpenEXRFile`
  with its memory and time limits is a ready differential target. The in-tree damaged files
  and the `openexr-images` reference images serve as a seed corpus; the `roundtrip` fuzzer is the
  pattern for checking a D decoder against the C core
  ([existing-code][bl-existing] G11).
- **Q9** — OpenEXR ships the format as two libraries: a C core (container, codecs, unpack,
  with HTJ2K pulling in C++ OpenJPH, plus `libdeflate` and `zstd`) and a C++ convenience
  layer (frame buffers, threads, RGBA, utilities). The layer most of its CVEs came from in
  2026 (`OpenEXRUtil`, tools, Python bindings) is outside the core, which is evidence for a
  small format core with consumers layered above it.

## Strengths

- Chunk-independent storage with an offset table: random access, region reads, MIP levels
  and parallel decode fall out of the format.
- A core API that is thread-safe for reads without locks, with per-file allocators,
  error callbacks and I/O, and replaceable pipeline stages.
- Caller-owned output described by strides and types, including on-the-fly `half` to
  `float` conversion and subsampled channels.
- Every decompressor checks produced size against the declared size; damaged files decode
  up to the damage (verified on 3.3.8 and 3.5.1) and offset tables can be rebuilt.
- Continuous fuzzing on every pull request with seven targets that cover both APIs, and a
  public CVE table with affected and patched versions.
- A wide, well-documented compressor set with explicit lossy/lossless and deep-support
  properties.

## Weaknesses

- Resource limits default to off and cover only dimensions; no pixel, memory, sample or time
  budget in the library.
- Two coordinate conventions (absolute base pointers in C++, chunk-relative in the core)
  and silent stride narrowing between them; absolute base pointers rely on undefined
  pointer arithmetic, and code that mishandled non-zero origins has caused CVEs.
- An unknown compression byte is not fatal by default: the core substitutes `ZIP` and
  fails later, at the chunk reads.
- Pull-only, blocking I/O; no suspension or push feed, and the chunk-info calls perform I/O.
- No ICC, CICP, EXIF or XMP; alpha premultiplication is a convention, not data.
- SIMD dispatch is inconsistent across kernels, partly compile-time only, and thin on ARM.
- A large and still-growing CVE count, concentrated in C++ utilities, tools and 32-bit
  size arithmetic.
- Some documentation lags the code (the `read_fn` initialisation comment; the threading
  header's I/O claim).

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                            | Trade-off                                                                                      |
| ---------------------------------------------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Chunks of 1 to 256 lines or one tile, indexed by an offset table | Random access, region reads, parallel decode, crash-tolerant writing | Chunk size fixed by the compressor; a region still decompresses whole chunks                   |
| Named channels with per-channel type and subsampling             | Arbitrary AOVs, layers and views without schema changes              | Layers and views are naming conventions; no interleaved pixel type                             |
| Data window distinct from display window                         | Overscan and regions of interest without padding                     | Large origins drove base-pointer arithmetic that overflowed                                    |
| Caller-owned memory described by `Slice` strides                 | No copies, any layout                                                | Absolute addressing forms invalid pointers; `size_t` vs `int32_t` strides                      |
| C core with contexts and result codes (3.1), C++ on top (3.3)    | Lock-free concurrent reads, one validation layer, easier bindings    | Two APIs to maintain; C++ users still see exceptions and global thread pools                   |
| Replaceable pipeline stages                                      | Custom decompression, GPU unpack, raw-chunk tools                    | Defaults must be chosen explicitly; easy to misuse (no reader until `choose_default_routines`) |
| Dimension limits default to 0 (off); OOM not a vulnerability     | Same file works on a large machine; policy belongs to the deployment | Untrusted-input callers must configure limits or rely on the OS                                |
| Scene-linear by convention; colour by primaries or interop ID    | Physical pixel values; compositing maths works directly              | No ICC or CICP; display-referred interchange needs outside conventions                         |
| Premultiplied alpha by convention                                | Correct "over" without extra multiplies                              | Not recorded per file; straight-alpha writers produce silently wrong files                     |
| Vendored compressors (`libdeflate`, `zstd`, OpenJPH)             | Reproducible builds, fewer system dependencies                       | The core links C++; dependency flaws are inherited and fixed upstream                          |

## Sources

- [AcademySoftwareFoundation/openexr][repo] at `b0460b224`, [`LICENSE.md`][license],
  [`README.md`][readme], [`SECURITY.md`][security-policy] and [`CHANGES.md`][changes-31].
- Documentation in `website/`: [Technical Introduction][techintro], [File Layout][layout],
  [Core API][coreapi], [Reading and Writing Image Files][rw-general],
  [Image Size Limit][sizelimit], [Standard Attributes][stdattr-colour] and the
  [`readGZ1.cpp`][readgz1] example; the published site at [openexr.com][docs].
- Core headers in `src/lib/OpenEXRCore/`: [`openexr_context.h`][ctx-init],
  [`openexr_base.h`][base-limits], [`openexr_decode.h`][decode], [`openexr_coding.h`][coding],
  [`openexr_chunkio.h`][chunkio], [`openexr_attr.h`][attr-enums],
  [`openexr_compression.h`][compression-h], [`openexr_color_metadata.h`][colormeta].
- Core implementation: [`base.c`][base-defaults], [`validation.c`][validate-dims],
  [`chunk.c`][chunk-table], [`parse_header.c`][attr-too-big], [`decoding.c`][choose],
  [`unpack.c`][unpack-f16c], [`compression.c`][comp-lines], [`internal_zip.c`][zip-undo],
  [`internal_piz.c`][piz-bounds], [`internal_dwa_simd.h`][dwa-dispatch],
  [`internal_cpuid.h`][cpuid], [`internal_structs.h`][structs-mutex].
- C++ layer: [`ImfFrameBuffer.h`][slice], [`ImfRgbaFile.h`][computebase],
  [`ImfScanLineInputFile.cpp`][readpixels-mt], [`ImfThreading.h`][threading-h],
  [`ImfChromaticities.h`][chroma], [`ImfCheckFile.cpp`][checkfile-core].
- Fuzzing and tests: [`openexr_exrcorecheck_fuzzer.cc`][fuzz-core],
  [`ossfuzz_workflow.yml`][fuzz-ci], [`fuzzFile.cpp`][fuzzfile], [`src/test/OpenEXRTest`][test-dir].
- Advisories: [GHSA-h45x-qhg2-q375 (CVE-2025-48071)][ghsa-48071], [CVE-2026-59985][cve-59985],
  [CVE-2021-3474][cve-3474].
- Sparkles context: the [existing-code][bl-existing], [shaders-simd][bl-shaders],
  [event-horizon][bl-eh], [wired][bl-wired] and [Vulkan][bl-vk] baselines; the
  [hostile-input papers][p-hostile]; [concepts](./concepts.md); the
  [OpenImageIO](./openimageio.md) deep-dive, whose `ImageSpec` mirrors EXR's windows and deep data.

<!-- References -->

[repo]: https://github.com/AcademySoftwareFoundation/openexr
[docs]: https://openexr.com/en/latest/
[license]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/LICENSE.md
[readme]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/README.md#L15-L45
[readme-prio]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/README.md#L33-L41
[security-policy]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/SECURITY.md#L19-L47
[security-known]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/SECURITY.md#L49-L80
[changes-31]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/CHANGES.md#L4209-L4226
[changes-31-design]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/CHANGES.md#L4241-L4260
[changes-32]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/CHANGES.md#L3216-L3260
[changes-33]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/CHANGES.md#L2434-L2460
[changes-34]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/CHANGES.md#L1627-L1680
[changes-3414]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/CHANGES.md#L561-L640
[changes-3414-list]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/CHANGES.md#L663-L694
[readme-images]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/README.md#L169
[changes-3474]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/CHANGES.md#L4660
[techintro]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/TechnicalIntroduction.rst
[techintro-windows]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/TechnicalIntroduction.rst#L26-L70
[techintro-comp]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/TechnicalIntroduction.rst#L609-L790
[techintro-premult]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/TechnicalIntroduction.rst#L1234-L1244
[layout]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/OpenEXRFileLayout.rst
[layout-version]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/OpenEXRFileLayout.rst#L233-L300
[layout-chunk]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/OpenEXRFileLayout.rst#L628-L648
[layout-offsets]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/OpenEXRFileLayout.rst#L580-L600
[coreapi]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/OpenEXRCoreAPI.rst#L8-L41
[coreapi-pipeline]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/OpenEXRCoreAPI.rst#L128-L173
[rw-general]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/ReadingAndWritingImageFiles.rst#L640-L680
[sizelimit]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/ImageSizeLimit.rst#L10-L31
[stdattr-colour]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/StandardAttributes.rst#L1214-L1270
[stdattr-time]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/StandardAttributes.rst#L1096-L1140
[readgz1]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/website/src/readGZ1.cpp#L25-L68
[ctx-read]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_context.h#L104-L138
[ctx-init]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_context.h#L172-L337
[ctx-flags]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_context.h#L339-L366
[ctx-start]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_context.h#L393-L418
[base-limits]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_base.h#L38-L67
[base-defaults]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/base.c#L132-L176
[decode-flags]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_decode.h#L18-L55
[decode]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_decode.h#L57-L312
[decode-readfn]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_decode.h#L209-L223
[coding]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_coding.h#L17-L140
[chunkio]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_chunkio.h#L24-L116
[attr-enums]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_attr.h#L36-L107
[attr-chlist]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_attr.h#L309-L329
[attr-types]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_attr.h#L405-L441
[compression-h]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_compression.h#L22-L67
[colormeta]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/openexr_color_metadata.h#L31-L129
[validate-dims]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/validation.c#L297-L353
[validate-chans]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/validation.c#L414-L433
[validate-req]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/validation.c#L21-L49
[comp-parse]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/parse_header.c#L423-L456
[parse-loop]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/parse_header.c#L2848-L2854
[chunk-table]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/chunk.c#L526-L635
[chunk-unpack-size]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/chunk.c#L676-L702
[attr-too-big]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/parse_header.c#L66-L80
[choose]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/decoding.c#L361-L520
[decoding-run]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/decoding.c#L564-L592
[unpack-list]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/unpack.c#L209-L1240
[unpack-f16c]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/unpack.c#L16-L155
[comp-lines]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/compression.c#L322-L345
[comp-lossy]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/compression.c#L481-L515
[zip-simd]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/internal_zip.c#L18-L94
[zip-undo]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/internal_zip.c#L290-L324
[piz-bounds]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/internal_piz.c#L676-L700
[dwa-dispatch]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/internal_dwa_simd.h#L2310-L2400
[dwa-construct]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/internal_dwa_compressor.h#L93-L103
[cpuid]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/internal_cpuid.h#L26-L123
[structs-mutex]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRCore/internal_structs.h#L218-L250
[slice]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXR/ImfFrameBuffer.h#L38-L136
[computebase]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXR/ImfRgbaFile.h#L35-L57
[rgbafile]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXR/ImfRgbaFile.h#L270-L390
[readpixels-mt]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXR/ImfScanLineInputFile.cpp#L414-L541
[update-ptrs]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXR/ImfScanLineInputFile.cpp#L621-L657
[threading-h]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXR/ImfThreading.h#L14-L44
[chroma]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXR/ImfChromaticities.h#L26-L52
[checkfile-limits]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRUtil/ImfCheckFile.cpp#L43-L55
[checkfile-core]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/lib/OpenEXRUtil/ImfCheckFile.cpp#L1367-L1493
[fuzz-core]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/test/oss-fuzz/openexr_exrcorecheck_fuzzer.cc#L7-L22
[fuzz-ci]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/.github/workflows/ossfuzz_workflow.yml#L66-L115
[fuzz-ci-on]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/.github/workflows/ossfuzz_workflow.yml#L9-L45
[fuzzfile]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/test/OpenEXRFuzzTest/fuzzFile.cpp#L44-L80
[test-dir]: https://github.com/AcademySoftwareFoundation/openexr/tree/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/test/OpenEXRTest
[test-cmake]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/test/CMakeLists.txt#L7-L22
[py-test-images]: https://github.com/AcademySoftwareFoundation/openexr/blob/b0460b224e4c877c2aee6d6e2c2ab048514c872f/src/wrappers/python/tests/test_images.py#L8-L13
[ghsa-48071]: https://github.com/AcademySoftwareFoundation/openexr/security/advisories/GHSA-h45x-qhg2-q375
[cve-59985]: https://www.cve.org/CVERecord?id=CVE-2026-59985
[cve-3474]: https://nvd.nist.gov/vuln/detail/CVE-2021-3474
[concepts-stride]: ./concepts.md#stride
[concepts-view]: ./concepts.md#image-and-view
[concepts-tiling]: ./concepts.md#tiling
[concepts-chroma]: ./concepts.md#chroma-subsampling
[concepts-cicp]: ./concepts.md#cicp
[concepts-gainmap]: ./concepts.md#hdr-gain-map
[concepts-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[concepts-pushpull]: ./concepts.md#push-and-pull-decoding
[concepts-incr]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[concepts-container]: ./concepts.md#container-and-bitstream
[concepts-gpudecomp]: ./concepts.md#gpu-decompression
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-eh]: ./baseline/event-horizon.md
[bl-wired]: ./baseline/wired.md
[bl-vk]: ./baseline/vulkan.md
[p-hostile]: ./papers/hostile-input-safety.md
