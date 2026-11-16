# SAIL (C)

The Squirrel Abstract Imaging Library: a C11 decoding and encoding front end over third-party codec libraries, where one flat `sail_image` struct, one closed `SailPixelFormat` enum and an eight-function codec plugin contract carry every format from GIF to camera RAW; it is the survey's clearest example of a codec registry driven by text metadata files and of a frame-by-frame pull loop as the only decoding protocol.

| Field         | Value                                                                                             |
| ------------- | ------------------------------------------------------------------------------------------------- |
| Language      | C11; C++11 and Python 3.10+ bindings ([`README.md`][readme-lang])                                 |
| License       | MIT ([`LICENSE.txt`][license])                                                                    |
| Repository    | [HappySeaFox/sail][repo]                                                                          |
| Revision read | `dccd2ebd500c203a014a9822fe84da98fb829784` (October 24, 2026; codec layout version 8)             |
| Documentation | [`README.md`][readme] · [`FAQ.md`][faq] · [`FORMATS.md`][formats] · header comments in the source |
| Category      | Codec front ends: plugin registry, closed pixel-format enum, pull-based frame loop                |
| Tier          | B                                                                                                 |
| Last reviewed | November 15, 2026                                                                                 |

> [!NOTE]
> Claims marked **demonstrated** come from a scratch build of this revision (static libraries,
> codecs limited to GIF and QOI, `-DCMAKE_BUILD_TYPE=Release`) in `/tmp/sail-demo`
> (GCC 14.3.0) and independently rerun in `/tmp/sail-verify` (GCC 16.2.0), driven by a
> small C program against crafted inputs. The rerun's resident and virtual peaks are from
> `/proc/self/status` (`VmHWM`, `VmPeak`, reported in KiB) on one
> x86_64 Linux host and are given only to show orders of magnitude, not as performance figures.

---

## Overview

### What it solves

An image viewer or game needs to open "any image" without linking every codec library into its
own build or learning each library's API. SAIL wraps libjpeg-turbo, libpng, giflib, libtiff,
libwebp, libavif, libjxl, libheif, OpenJPEG, OpenEXR and others behind one API, and adds in-tree
decoders for simpler formats (BMP, PCX, TGA, QOI, PSD, XWD and more). The README states the
scope ([`README.md`][readme-intro]):

> _"SAIL is a high-quality cross-platform image decoding library providing rich APIs, from one-liners
> to complex use cases with custom I/O sources. It supports loading and saving static,
> animated, and multi-paged images along with metadata and ICC profiles."_

The target audience is named as "Image viewers", "Game developers" and anyone who needs to load
or save images "with a clean and comprehensive API" ([`README.md`][readme-intro]). The library is
the successor of ksquirrel-libs, the C++ codec set of the KSquirrel image viewer, "founded in 2003" ([`FAQ.md`][faq-age]).

### Design philosophy

1. **Codecs are separate, discoverable units.** "SAIL codecs represent the lowest level. This is a
   set of standalone, dynamically loaded codecs (SO on Linux and DLL on Windows)", and "Every codec
   is accompanied by a codec info (description) file, which is a plain text file"
   ([`README.md`][readme-arch]). The philosophy section states: "SAIL's philosophy is
   modularization and simplicity" ([`README.md`][readme-philo]).
2. **Decode to the source format, convert separately.** "SAIL attempts to output a pixel format as
   close to the source format as possible. Ideally, it outputs the same pixel format as stored in
   the image" ([`FAQ.md`][faq-pixfmt]). Conversion lives in a separate library, `libsail-manip`.
3. **Write as-is.** "SAIL does not convert pixel formats during save operations. Images are always
   written as-is" ([`FAQ.md`][faq-write]); a codec's writable set is deliberately larger than what
   `sail_convert_image()` can produce.
4. **Four API depths over one engine.** `junior` (one call), `advanced` (frame loop), `deep diver`
   (codec choice and options), `technical diver` (custom I/O) ([`FAQ.md`][faq-apis]).

## How it works

### `sail_image`: one struct for every frame

Every decoded frame is a `struct sail_image` ([`image.h`][image-h]). Its header comment marks each
field `LOAD` (set by SAIL) or `SAVE` (set by the caller):

```c
struct sail_image {
    void* pixels;              /* interleaved, row by row, top to bottom */
    unsigned width, height;
    unsigned bytes_per_line;   /* may be padded */
    struct sail_resolution* resolution;
    enum SailPixelFormat pixel_format;
    double gamma;              /* 0 = not set */
    int delay;                 /* ms for animation frames, -1 otherwise */
    struct sail_palette* palette;
    struct sail_meta_data_node* meta_data_node;
    struct sail_iccp* iccp;
    struct sail_source_image* source_image;
};
```

(Abridged from [`image.h`][image-h]; one field per line in the source.) The pixel comment is
explicit: "The channels are interleaved per pixel. The pixels are organized row by row, left to
right, top to bottom." There is no planar layout, no view type and no origin other than top-left.
`struct sail_source_image` records what decoding normalised away: the source pixel format,
`SailChromaSubsampling`, `SailOrientation`, `SailCompression`, interlacing, and a
`special_properties` hash map whose keys "start with the codec name to avoid confusion. For
example, "cur-hotspot-x"" ([`source_image.h`][source-image-h]).

### `SailPixelFormat`: a closed, bit-count-named enum

`enum SailPixelFormat` ([`common.h`][pixfmt]) names every layout by total bits per pixel plus a
channel order: `SAIL_PIXEL_FORMAT_BPP24_RGB`, `BPP32_BGRA`, `BPP64_RGBA`, `BPP16_RGB565`,
`BPP32_RGBA_1010102`, `BPP40_CIE_LAB` ("8/16/16"), `BPP30_YUV` ("10-bit"), `BPP128_RGBA_FLOAT`,
`BPP96_RGB_UINT`, plus anonymous `BPP1` to `BPP128` "Formats with unknown pixel
representation/model", indexed formats (`BPP1_INDEXED` to `BPP16_INDEXED`) and grayscale with
and without alpha. Members added for 1.0.0 are appended after a `/* Since 1.0.0 */` marker, so the
earlier members keep their numeric values. The name encodes size and order but not sample type except where a
suffix says so (`_HALF`, `_FLOAT`, `_UINT`); `BPP48_RGB` means three 16-bit unsigned samples,
`BPP48_RGB_HALF` three half floats. Nothing in the enum says whether alpha is premultiplied; a grep
of `src/sail`, `sail-common` and `sail-manip` for "premultipl" finds no match.

Helpers derive geometry from the enum. `sail_bytes_per_line()` computes the minimum row length in
floating point and returns 0 when it would not fit an `unsigned` ([`utils.c`][bpl]):

```c
unsigned sail_bytes_per_line(unsigned width, enum SailPixelFormat pixel_format)
{
    const unsigned bits_per_pixel = sail_bits_per_pixel(pixel_format);
    const double bytes_per_line   = ((double)width * bits_per_pixel + 7) / 8;
    return (bytes_per_line < UINT_MAX) ? (unsigned)bytes_per_line : 0;
}
```

**Demonstrated:** `sail_bytes_per_line(3, SAIL_PIXEL_FORMAT_BPP1)` is `1`;
`sail_bytes_per_line(UINT_MAX, SAIL_PIXEL_FORMAT_BPP128_RGBA_FLOAT)` is `0`, the overflow sentinel
that `sail_check_image_skeleton_valid()` then rejects ([`image.c`][skeleton]).

### Codec info files and plugin discovery

Each codec ships a `.codec.info` INI file. The GIF codec's, apart from comments and compression-level defaults
([`gif.codec.info.in`][gif-info]):

```ini
[codec]
layout=8
version=1.4.3
priority=@GIF_CODEC_PRIORITY@
name=GIF
description=Graphics Interchange Format
magic-numbers=47 49 46 38 37 61;47 49 46 38 39 61
extensions=gif
mime-types=image/gif

[load-features]
features=STATIC;ANIMATED;META-DATA;SOURCE-IMAGE
tuning=

[save-features]
features=STATIC;ANIMATED;META-DATA
pixel-formats=BPP8-INDEXED
compressions=LZW
...
tuning=gif-transparency-index;gif-loop-count;gif-background-color
```

The parsed form is `struct sail_codec_info` ([`codec_info.h`][codec-info-h]): name, description,
`SailCodecPriority` (`HIGHEST` for JPEG-class formats down to `LOWEST` for "ancient" ones; [`codec_priority.h`][codec-priority]), linked
lists of magic numbers, extensions and MIME types, and `sail_load_features` /
`sail_save_features` with the `SailCodecFeature` bit set (`STATIC`, `ANIMATED`, `MULTI_PAGED`,
`META_DATA`, `INTERLACED`, `ICCP`, `SOURCE_IMAGE`) ([`common.h`][codec-feature]). Magic numbers are
matched against the first `SAIL_MAGIC_BUFFER_SIZE` bytes, 16 by default ([`CMakeLists.txt`][magic-size]);
the header warns that "Some formats share the same magic numbers (for example TIFF and DNG), so
the selected codec may be incorrect" ([`codec_info.h`][codec-info-magic]).

Discovery has two build modes. With `SAIL_COMBINE_CODECS=OFF`, the context scans a directory
(the `SAIL_CODECS_PATH` environment variable, else a compiled-in path, on Windows a path relative
to `sail.dll`) for `*.codec.info` files, derives `jpeg.so` from `jpeg.codec.info`, parses only the
text, and sorts codecs by priority ([`context_private.c`][ctx-scan], [`context.h`][ctx-h]). The shared object is opened
only when first needed, with `dlopen(path, RTLD_LAZY | RTLD_LOCAL)`, and the eight entry points are
resolved by name, `sail_codec_load_init_v8_` plus the lower-cased codec name
([`codec.c`][codec-dlopen]). With `SAIL_COMBINE_CODECS=ON` (forced for static builds, used by the
Conan and vcpkg packages), the codec info strings and function tables are compiled into arrays
`sail_enabled_codecs_info[]` and `sail_enabled_codecs_layouts[]`; built-in codec discovery needs no file system access
([`context_private.c`][ctx-combined], [`codec.c`][codec-dlopen]). An opt-in `SAIL_THIRD_PARTY_CODECS_PATH` adds
semicolon-separated directories for out-of-tree codecs in either mode.

### The codec contract: eight functions, two state machines

`struct sail_codec_layout_v8` is the whole plugin ABI ([`codec_layout.h`][layout]):
`load_init`, `load_seek_next_frame`, `load_frame`, `load_finish` and the four `save_*`
counterparts. The contract header documents the call order ([`layout/v8.h`][v8-contract]):

```text
Full load, repeated per frame:
  load_init -> load_seek_next_frame -> load_frame -> load_seek_next_frame -> ... -> load_finish
Probing, metadata only, no pixels:
  load_init -> load_seek_next_frame -> load_finish
  load_frame is not called during probing.
```

The split of work is the interesting part. `load_seek_next_frame` allocates the `sail_image`,
fills its dimensions, pixel format, `bytes_per_line` and (when the matching `SailOption` bit is
set) metadata, ICC profile and source image, and must not allocate the image pixels
([`layout/v8.h`][v8-seek]). libsail then validates the skeleton, computes the buffer size with an
overflow-checked multiply and allocates the pixels; `load_frame` only fills them
([`sail_advanced.c`][load-next]):

```c
SAIL_TRY(state_of_mind->codec->v8->load_seek_next_frame(state_of_mind->state, &image_local));
SAIL_TRY_OR_CLEANUP(sail_check_image_skeleton_valid(image_local), ...);
if (image_local->pixels != NULL) { /* "codecs must not allocate pixels" */ ... }
SAIL_TRY_OR_CLEANUP(sail_alloc_pixels(image_local->height, image_local->bytes_per_line,
                                      &image_local->pixels), ...);
SAIL_TRY_OR_CLEANUP(state_of_mind->codec->v8->load_frame(state_of_mind->state, image_local), ...);
```

End of stream is a status, `SAIL_ERROR_NO_MORE_FRAMES`. Error handling is part of the contract:
"On any error after load_init or save_init, libsail calls the matching finish function", and
"After an error in load_seek_next_frame, load_frame, save_seek_next_frame, or save_frame, the
result of calling them again before finish is unspecified" ([`layout/v8.h`][v8-contract]). On the
save side, `sail_write_next_frame()` checks the frame's format against the codec's declared
`save_features->pixel_formats` before calling the codec ([`sail_advanced.c`][write-next]).

### I/O

`struct sail_io` is a table of blocking callbacks over an opaque `stream`: `tolerant_read`
(short reads allowed), `strict_read` (short read is an error), the two write forms, `seek` with C
`whence` values, `tell`, `flush`, `close`, `eof` and `size`, plus one feature bit,
`SAIL_IO_FEATURE_SEEKABLE` ([`io_common.h`][io-h]). Files, memory and a growable memory writer
are built in; a custom source fills the same table. Every read either returns data or fails:
there is no "would block" status in `status.h` ([`status.h`][status-h]).

### C++ binding

`sail::image_input` wraps the state handle with RAII: constructors from a path, a buffer or an
`abstract_io`, `with(codec_info)` and `with(load_options)` overrides, `next_frame()` and `probe()`,
which restores the I/O position afterwards so it "must be seekable" ([`image_input.h`][cxx-input]).
`sail::image` deep-copies on copy construction ([`image.h` (C++)][cxx-copy]); when it adopts a C image it takes ownership of the
pixel pointer: "The pixels are transferred. The caller must set the pixels in the sail_image
object to NULL afterwards" ([`image.h` (C++)][cxx-image]).

## Analysis

### 1. Pixel and memory model

One interleaved, top-left-origin plane per frame with a padded `bytes_per_line`, as in most
viewer-oriented libraries ([concepts: stride][c-stride]). The model has no planes, no
subsampled chroma buffers (YUV is exposed only as interleaved `BPP24_YUV` and kin, and chroma
subsampling only as a `source_image` annotation), no tiles and no views. `SailPixelFormat` is
closer to a DRM fourcc list than to a type system ([concepts: pixel format names][c-pixfmt]): every
consumer must handle the layout at run time. Contrast the compile-time pixel types of [image-rs][image-rs] and
[Boost.GIL][gil], and the N-D `Slice` of [mir-algorithm][mir].

### 2. Genericity mechanism

The image and pixel abstractions have no compile-time genericity: SAIL is C11 and its C++ image wrapper uses the C pixel-format enum.
Format dispatch goes through the eight-function `sail_codec_layout_v8` table
([`codec_layout.h`][layout]), and pixel-format dispatch switches on `enum SailPixelFormat` at run
time ([`common.h`][pixfmt], [`convert.h`][convert-h]).

### 3. Colour and metadata

Colour is an ICC blob (`struct sail_iccp`: `data` and `size`, "only the first image in an
animated/multi-paged sequence might have an ICC profile") plus a `double gamma`
([`image.h`][image-h]). There is no CICP, transfer-function or primaries field, so an AVIF or
JPEG XL decoded through SAIL loses its [CICP][c-cicp] signalling unless the codec bakes it into an
ICC profile; `sail_convert_image()` states "The image ICC profile is not involved in the
conversion procedure" ([`convert.h`][convert-h]). Codec-specific HDR facts can survive in
`source_image.special_properties`: JPEG XL stores intensity target, minimum nits,
relative-to-maximum-display and linear-below values ([`helpers.c`][jxl-properties]). Metadata is a linked list keyed by
`enum SailMetaData`: text keys such as `ARTIST`, `COMMENT` and `SOFTWARE` beside `EXIF`, `XMP`, `IPTC`, `JUMBF` and `THUMBNAIL` blobs, with
the note that EXIF "may or may not start with "Exif\0\0"" ([`common.h`][meta-enum]). Orientation
has a field in `source_image`; this field alone does not specify whether a codec applies source orientation. See [concepts: ICC profile][c-icc] and
[concepts: image metadata][c-meta].

### 4. I/O and codec architecture

SAIL's distinctive contribution is the **capability-declaring registry**: a codec is selected by
extension, magic number or MIME type, and the caller can ask before decoding which pixel formats a
codec writes, which compressions and compression-level range it supports, and which tuning keys it
accepts, because all of that is in a text file parsed without loading the codec. Codecs are
loaded lazily and can be unloaded (`sail_unload_codecs()`) while their info stays valid
([`context.h`][ctx-h]). Two consequences of the design:

- **Pull only, not suspendable.** The I/O table is blocking, so a decoder cannot return "need more
  bytes" and be resumed ([concepts: push and pull][c-pushpull],
  [concepts: suspendable decoding][c-suspend]). Wrapped libraries that need the whole file do the
  buffering themselves: the QOI codec's `load_init` calls `sail_alloc_data_from_io_contents()`
  "as the QOI API requires" ([`qoi.c`][qoi-init]).
- **Probe cost depends on the codec.** The contract asks `load_seek_next_frame` to describe the
  frame, and "The frame is NOT immediately loaded or decoded by most SAIL codecs"
  ([`layout/v8.h`][v8-seek]). The QOI codec decodes the whole image there, then `load_frame`
  `memcpy`s it into the libsail buffer ([`qoi.c`][qoi-frame]). **Demonstrated:** probing a
  1,612,931-byte QOI file declaring 10000x10000 RGBA (`sail_probe_memory`) peaked at about 386 MiB
  resident; a full `sail_load_from_memory` peaked at about 767 MiB, two full copies of the 400 MB
  frame.

### 5. Hostile input and safety

What libsail guarantees centrally: `width` and `height` non-zero, `bytes_per_line` at least the
minimum for the width and format ([`image.c`][skeleton]), `height * bytes_per_line` checked for
`size_t` overflow by `sail_size_mul()`, and room for the 64-byte tail ([`utils.c`][alloc-pixels]).
What it does not have is a framework resource limit: `struct sail_load_options` holds only an option bit
set and a tuning hash map ([`load_options.h`][load-options]), so there is no equivalent of
[image-rs's `Limits`][image-rs-limits]. Each codec bounds or fails to bound its own allocations.
The GIF codec allocates a full-canvas RGBA compositing buffer, one `calloc` per row, from the
logical-screen size in `load_init`, before any frame is read ([`gif.c`][gif-alloc]).
**Demonstrated:** a 35-byte GIF declaring a 65535x65535 logical screen probes successfully as
`65535x65535 BPP32-RGBA` with `bytes_per_line=262140`, peaking at about 258 MiB resident and
reserving about 16.3 GiB of address space; under `ulimit -v 8000000` both probe and load return
status 2, `SAIL_ERROR_MEMORY_ALLOCATION`. The in-tree QOI decoder does cap the canvas at
`QOI_PIXELS_MAX` (400,000,000 pixels) ([`qoi.h`][qoi-max]). Codec code carries hardening comments
("Validate palette index to prevent buffer overflow", "Skip truncated blocks to avoid reading
disposal, delay and transparency fields from adjacent data") ([`gif.c`][gif-gce], [`gif.c`][gif-dispose]).
A search of the pinned tree found no in-tree fuzz harness; external fuzzing coverage is unverified.
CI runs ASan builds of the test suite ([`build-and-test.yml`][ci-asan]). See [concepts: hostile input][c-hostile].

### 6. Allocation and ownership

The library owns allocation of the output pixel buffer, which gives one place to validate sizes and one
allocator (`sail_malloc`) for every format. Every `sail_alloc_pixels()` buffer gets a `SAIL_PIXELS_TAIL_SIZE` (64)
byte tail because libswscale "reads and writes up to 32 bytes past the pixels of the last scan
line" ([`utils.h`][tail]); caller-built images need this tail for conversion or scaling when
SAIL is built with swscale support; without swscale it is unnecessary ([`image.h`][image-h]).
The C API is handle-based (`void* state`, passed by address at start) with documented cleanup rules: "External
pointers that are allocated or modified by SAIL functions stay untouched on error", and the caller
must call `sail_stop_loading()` after an error ([`FAQ.md`][faq-memory]). Codec info pointers are
borrowed from a global context that lives until `sail_finish()`; calling `sail_finish()` or
`sail_unload_codecs()` during a load "may crash" ([`context.h`][ctx-h]). The context is a
process-wide singleton guarded by a mutex (`SAIL_THREAD_SAFE`, on by default).

### 7. CPU parallelism and SIMD

Decoding parallelism is whatever the wrapped library does (the video codec exposes a
`video-threads` tuning key ([`video.codec.info.in`][video-info])). `libsail-manip` conversion loops
are annotated `SAIL_OMP_PARALLEL_FOR` and built with OpenMP when available; the generic path
"converts every pixel into the BPP32-RGBA or BPP64-RGBA formats first, and only then to the
requested output format. No platform-specific instructions (like AVX or SSE) are used"
([`convert.h`][convert-h]). Optional libswscale provides a SIMD-capable conversion path.

### 8. GPU offload and interop

Not applicable, because SAIL is CPU-only: it exposes no GPU device buffers, textures or compute
paths, and returns a host `void* pixels` buffer with `bytes_per_line` ([`image.h`][image-h]).

### 9. Temporal, animation and containers

Animation is the same frame loop as a still image: call `sail_load_next_frame()` until
`SAIL_ERROR_NO_MORE_FRAMES`. Each frame carries `delay` in milliseconds, with the invariant "For
animations, it's guaranteed that all the frames have non-negative delays. For multi-paged
sequences, it's guaranteed that all the pages have delays equal to -1" ([`image.h`][image-h]); the
`multi-frame` test asserts it ([`multi-frame.c`][test-multi]). The GIF codec delivers frames fully
composited at canvas size: it applies the previous frame's disposal into its retained
canvas and emits `BPP32_RGBA` even though the source is indexed, and substitutes 100 ms for a zero
delay ("this makes the frame almost invisible on modern CPUs") ([`gif.c`][gif-delay],
[`gif.c`][gif-dispose]). There is no random access to frame N, no frame rectangle in the public
model, and no loop-count field on `sail_image` (APNG and WebP record `"apng-plays"` and
`"webp-loop-count"` in `special_properties`; GIF and JPEG XL discard theirs on load). The `VIDEO`
codec registers MP4, MKV, WebM and other containers as a
`STATIC` single-frame source, selected with the `video-seek-time` tuning key
([`video.codec.info.in`][video-info]).

### 10. Testing and conformance

Tests use munit. The acceptance corpus under `tests/images/acceptance/` holds a few files per codec
named by pixel format and feature (`bpp8-indexed.disposal.gif`, `bpp8-indexed.interlaced.gif`);
`edge-cases/` and `bugs/` hold regressions. The oracles are self-consistency checks rather than
reference pixels: `io-produce-same-images` loads each acceptance file from a path and from memory
and compares the two images ([`io-produce-same-images.c`][test-same]), and the multi-frame test
checks delay invariants. A `sail-dump` text dumper with `sail_read_dump()` exists, but no `.dump`
reference files are committed at this revision. Several edge-case tests assert only that a call
returns without crashing, leaving detection of leaks and overruns to the ASan CI matrix
([`edge-cases.c`][test-edge]).

## Lessons for Sparkles

- **Q4** The registry pattern transfers well: format metadata (magic bytes, extensions, MIME,
  load and save capabilities, writable pixel formats, tuning keys) as data that can be queried
  without instantiating a decoder. In D this need not be a parsed INI file; a UDA-annotated codec
  type enumerated at compile time gives the same queryable table and keeps the
  `sparkles:metadata` vocabulary in one place.
- **Q4** Splitting "describe the frame" from "fill the pixels", with the framework allocating
  between them, is a good seam for caller-owned or GPU-staging destinations: the framework sees the
  size before any byte is written. SAIL shows the seam is only as good as each codec's honesty;
  the QOI codec fully decodes in the describe step, so probe cost is not a property of the API.
- **Q4** SAIL's blocking `sail_io` is the counter-example for `sparkles:event-horizon`: a
  pull-only callback table cannot express "suspend until more bytes arrive". A Sparkles codec
  protocol that must run on a completion-based loop needs the describe and fill steps themselves to
  be resumable, not just an I/O adapter.
- **Q8** The **demonstrated** 35-byte GIF that reserves 16.3 GiB argues for limits as a framework
  concern checked between describe and fill (where SAIL already checks overflow), plus a per-codec
  budget for internal scratch such as compositing canvases. SAIL has neither framework budgets nor an in-tree fuzzer.
- **Q5** A single ICC blob plus `gamma` cannot separately express CICP, primaries and
  transfer; codec-specific HDR special properties do not provide common fields. The `source_image` idea (keep the pre-normalisation facts: source pixel
  format, subsampling, orientation, compression) does transfer and costs little.
- **Q1** A closed enum of interleaved formats is easy to carry across a C ABI and into bindings,
  but layout-dependent algorithms need run-time dispatch, and it has no representation for planar YUV or premultiplied
  alpha. It is a reasonable wire or interchange vocabulary, not a substitute for typed pixels.
- **Q9** SAIL's package split (`sail-common` types, `sail` engine and registry, `sail-codecs`
  plugins, `sail-manip` conversion) is evidence that codecs and conversion can be separate
  libraries over a shared type package; the global singleton context and dynamic loading are the
  parts Sparkles would not want, since its codecs would be D modules chosen at build time
  (SAIL's own `SAIL_COMBINE_CODECS=ON` mode).
- **Q6** Delivering every GIF frame composited at canvas size in `BPP32_RGBA` is simple for
  a viewer and wasteful for a GPU path: each GIF frame becomes a full upload even when only a small
  rectangle changed.

## Strengths

- One small plugin ABI (eight functions, versioned as layout 8) with a written contract for
  call order, state ownership and error cleanup.
- Capabilities are data: what a codec can load, save and tune is queryable before it is loaded.
- Central pixel allocation with overflow-checked sizing and a minimum-stride check for every codec.
- Wide format coverage through mature libraries, plus in-tree decoders for simple formats.
- Source-image facts (original format, subsampling, orientation, compression) survive decoding.
- Four API depths, from `sail_load_from_file()` to custom I/O, over one engine; RAII C++ binding.

## Weaknesses

- No framework resource limits; a tiny input can drive a multi-gigabyte allocation (demonstrated).
- Blocking pull I/O only; no incremental or suspendable decoding.
- Probe cost varies by codec, up to a full decode (demonstrated with QOI).
- Interleaved-only pixel model; no planar YUV, views, tiles, or premultiplied-alpha flag.
- Colour model is an ICC blob and a gamma value; no common CICP or HDR metadata fields, although JPEG XL retains some HDR facts in special properties.
- Process-global context with documented crash conditions around `sail_finish()`.
- The cited test oracles are self-consistency and no-crash checks; no in-tree fuzz harness or committed reference dumps was found.
- Little-endian only ([`FAQ.md`][faq-endian]).

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                                                                 | Trade-off                                                                             |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Text `.codec.info` metadata alongside each plugin   | Format capabilities and magic bytes can be queried before loading code ([`codec_info.h`][codec-info-h])   | An extra parser and file-discovery step unless `SAIL_COMBINE_CODECS=ON` is used       |
| Split `load_seek_next_frame` from `load_frame`      | The framework validates skeleton geometry and allocates pixels centrally ([`sail_advanced.c`][load-next]) | Codecs that cannot header-probe (such as QOI) decode the whole image during probing   |
| Closed `SailPixelFormat` enum of interleaved pixels | Simple C ABI and direct pass-through of source formats ([`common.h`][pixfmt])                             | No planar YUV, no views or tiles, no premultiplied-alpha flag, switch-based consumers |
| Blocking `sail_io` callback table                   | Uniform wrapper over files, memory and custom streams ([`io_common.h`][io-h])                             | Cannot suspend and resume on non-blocking or completion-driven I/O                    |

## Sources

- [`README.md`][readme], [`FAQ.md`][faq], [`FORMATS.md`][formats] at the pinned revision.
- Core types: [`src/sail-common/image.h`][image-h], [`common.h`][pixfmt],
  [`source_image.h`][source-image-h], [`io_common.h`][io-h], [`utils.c`][bpl], [`utils.h`][tail].
- Engine: [`src/sail/codec_layout.h`][layout], [`layout/v8.h`][v8-contract],
  [`sail_advanced.c`][load-next], [`context_private.c`][ctx-scan], [`codec.c`][codec-dlopen],
  [`context.h`][ctx-h].
- Codecs: [`gif.c`][gif-alloc], [`gif.codec.info.in`][gif-info], [`qoi.c`][qoi-init],
  [`video.codec.info.in`][video-info].
- Tests and CI: [`io-produce-same-images.c`][test-same], [`multi-frame.c`][test-multi],
  [`edge-cases.c`][test-edge], [`build-and-test.yml`][ci-asan].
- Related deep-dives: [image-rs][image-rs], [zune-image][zune], [Go `image`][go-image],
  [Boost.GIL][gil], [mir-algorithm][mir]; [concepts][concepts]; the
  [existing-code baseline][bl-existing].

<!-- References -->

[repo]: https://github.com/HappySeaFox/sail
[license]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/LICENSE.txt
[readme]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/README.md
[readme-intro]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/README.md#L19-L32
[readme-arch]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/README.md#L193-L201
[readme-philo]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/README.md#L229-L235
[readme-lang]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/README.md#L159-L160
[faq]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/FAQ.md
[faq-age]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/FAQ.md#L51-L56
[faq-apis]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/FAQ.md#L87-L94
[faq-pixfmt]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/FAQ.md#L100-L107
[faq-write]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/FAQ.md#L109-L126
[faq-memory]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/FAQ.md#L229-L330
[faq-endian]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/FAQ.md#L599-L601
[formats]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/FORMATS.md
[image-h]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-common/image.h#L45-L168
[source-image-h]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-common/source_image.h#L41-L102
[pixfmt]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-common/common.h#L35-L209
[meta-enum]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-common/common.h#L313-L349
[codec-feature]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-common/common.h#L361-L387
[bpl]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-common/utils.c#L696-L701
[alloc-pixels]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-common/utils.c#L53-L101
[tail]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-common/utils.h#L168-L177
[skeleton]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-common/image.c#L148-L179
[io-h]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-common/io_common.h#L41-L202
[status-h]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-common/status.h#L38-L107
[load-options]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-common/load_options.h#L39-L62
[codec-info-h]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail/codec_info.h#L45-L97
[codec-priority]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail/codec_priority.h#L28-L41
[codec-info-magic]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail/codec_info.h#L122-L140
[magic-size]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/CMakeLists.txt#L142
[layout]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail/codec_layout.h#L30-L51
[v8-contract]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail/layout/v8.h#L26-L75
[v8-seek]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail/layout/v8.h#L125-L157
[ctx-scan]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail/context_private.c#L273-L549
[ctx-combined]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail/context_private.c#L551-L604
[codec-dlopen]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail/codec.c#L58-L161
[ctx-h]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail/context.h#L36-L140
[load-next]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail/sail_advanced.c#L81-L120
[write-next]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail/sail_advanced.c#L164-L185
[cxx-input]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/bindings/sail-c%2B%2B/image_input.h#L46-L148
[cxx-image]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/bindings/sail-c%2B%2B/image.h#L841-L863
[cxx-copy]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/bindings/sail-c%2B%2B/image.h#L110-L118
[convert-h]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-manip/convert.h#L45-L55
[gif-info]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-codecs/gif/gif.codec.info.in
[gif-alloc]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-codecs/gif/gif.c#L185-L209
[gif-gce]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-codecs/gif/gif.c#L300-L322
[gif-delay]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-codecs/gif/gif.c#L314-L322
[gif-dispose]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-codecs/gif/gif.c#L400-L508
[qoi-init]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-codecs/qoi/qoi.c#L103-L118
[qoi-frame]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-codecs/qoi/qoi.c#L120-L193
[qoi-max]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-codecs/qoi/qoi.h#L332
[video-info]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-codecs/video/video.codec.info.in
[jxl-properties]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/src/sail-codecs/jpegxl/helpers.c#L238-L262
[test-same]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/tests/sail/io-produce-same-images.c#L36-L71
[test-multi]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/tests/sail/multi-frame.c#L95-L149
[test-edge]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/tests/sail/edge-cases.c#L60-L92
[ci-asan]: https://github.com/HappySeaFox/sail/blob/dccd2ebd500c203a014a9822fe84da98fb829784/.github/workflows/build-and-test.yml#L17-L25
[image-rs]: ./image-rs.md
[image-rs-limits]: ./image-rs.md#limits
[zune]: ./zune-image.md
[go-image]: ./go-image.md
[gil]: ./boost-gil.md
[mir]: ./mir-algorithm/index.md
[concepts]: ./concepts.md
[c-stride]: ./concepts.md#stride
[c-pixfmt]: ./concepts.md#pixel-format-names-and-byte-order
[c-cicp]: ./concepts.md#cicp
[c-icc]: ./concepts.md#icc-profile
[c-meta]: ./concepts.md#image-metadata
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[c-suspend]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[c-hostile]: ./concepts.md#hostile-input
[bl-existing]: ./baseline/existing-code.md
