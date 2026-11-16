# libwebp (C)

Google's reference codec for WebP: a RIFF container around either a VP8 intra
frame (lossy) or the VP8L lossless bitstream, with a one-shot and an
incremental decoder, a demuxer and an animation compositor, a hand-written
SIMD layer behind runtime dispatch, and the Huffman table builder whose heap
overflow (CVE-2023-4863) was exploited in the wild.

| Field         | Value                                                                                                                                                                   |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C (C99 subset; the fuzz targets are C++ on Google `fuzztest`)                                                                                                           |
| License       | BSD-3-Clause plus a patent grant ([`COPYING`][copying], [`PATENTS`][patents])                                                                                           |
| Repository    | [webmproject/libwebp][repo] (GitHub mirror of `chromium.googlesource.com/webm/libwebp`)                                                                                 |
| Revision read | `1844042d1ca751e62e61df7617dba19c98588339` (October 19, 2026, "Fix invalid bitstream handling when start[0]==255"; `README.md` banner and [`NEWS`][news] say 1.6.0)     |
| Documentation | [developers.google.com/speed/webp][docs] · in-tree [container spec][spec-container] and [lossless spec][spec-lossless] · [RFC 9649][rfc9649] · VP8: [RFC 6386][rfc6386] |
| Category      | Formats: still and animated image codec (decoder, encoder, mux and demux)                                                                                               |
| Tier          | A                                                                                                                                                                       |
| Last reviewed | November 7, 2026                                                                                                                                                        |

> [!IMPORTANT]
> **What was run.** Claims marked **verified** come from a probe program
> compiled with GCC 14.3.0 against `libwebp.a` built with CMake from the pinned
> sources (exported with `git archive` into a scratch directory under `/tmp`,
> outside this repository). The probe encoded a 300x200 test image with the
> library's own encoder, then decoded it one-shot and incrementally, fed crafted
> `VP8X` headers to `WebPGetInfo`, called the internal `VP8LBuildHuffmanTable`
> on valid and invalid code-length sets, and decoded with cropping and scaling.
> Everything else was read in the source at the pinned revision or in the cited
> advisories. No performance number in this page was measured. A second probe
> (GCC 16.2.0, the same sources compiled directly into a static archive, other
> test images) reproduced every verified result in kind; the `SUSPENDED` counts
> depend on the file and were not expected to match.

---

## Overview

### What it solves

WebP is two unrelated codecs in one container. Lossy WebP is a single VP8 key
frame (the intra subset of the VP8 video codec, [RFC 6386][rfc6386]): 4:2:0
`Y'CbCr`, 16x16 macroblocks, intra prediction, a 4x4 integer transform, a
boolean arithmetic coder and an in-loop deblocking filter. Lossless WebP (VP8L)
is a separate ARGB format built on spatial transforms, LZ77 with 2-D distance
codes, a hashed colour cache and spatially varying prefix codes. The RIFF
container adds alpha for lossy images (`ALPH`), animation (`ANIM`, `ANMF`), an
ICC profile (`ICCP`) and `EXIF`/`XMP ` metadata, all announced by a `VP8X`
header. The container spec states the goal ([`webp-container-spec.txt`][spec-container-intro]):

> _"It is optimized for fast image transfer over the network (for example, for
> websites). The WebP format has feature parity (color profile, metadata,
> animation, etc.) with other formats as well."_

libwebp is the reference implementation of all of it: `libwebpdecoder` (decode
only), `libwebp` (decode and encode), `libwebpdemux` (container parsing and the
animation compositor), `libwebpmux` (container editing) and `libsharpyuv`
(encoder-side RGB to YUV). Browsers, Android, Skia ([Skia deep-dive][skia]) and
most image stacks link it, which is why one bug in its lossless entropy decoder
had to be patched in Chrome, Android and every application that bundles
libwebp in 2023. Hawkes links it, from the timing of the reports rather than
any confirmation from Apple, to the ImageIO bug (CVE-2023-41064) used against
iPhones in the same month ([Hawkes 2023][hawkes]).

### Design philosophy

The lossless spec describes the format in terms of the reference decoder
([`webp-lossless-bitstream-spec.txt`][spec-lossless-intro]):

> _"WebP lossless is an image format for lossless compression of ARGB images.
> The lossless format stores and restores the pixel values exactly, including
> the color values for fully transparent pixels."_

Four choices shape the code:

1. **Speed first, in plain C with hand-written kernels.** Every hot loop is a
   function pointer filled by an `Init` function per module, with C, SSE2,
   SSE4.1, AVX2, NEON, MSA and MIPS variants ([§7](#_7-cpu-parallelism-and-simd)).
2. **A frozen C ABI with versioned structs.** `WebPDecBuffer`,
   `WebPBitstreamFeatures` and `WebPDecoderOptions` carry `pad` words, and each
   decoder `Init` (and `WebPGetFeatures`) is a static inline wrapper around a
   `...Internal(…, WEBP_DECODER_ABI_VERSION)` entry point
   ([`decode.h`][h-buffer]).
3. **Validation in the parser, not in a separate pass.** Chunk sizes are checked
   against the RIFF size and `MAX_CHUNK_PAYLOAD` as they are walked
   ([`webp_dec.c`][dec-optional]); Huffman codes are validated as tables are
   built. CVE-2023-4863 was the moment that second rule failed.
4. **Hardening after the fact.** Since 2025 the decoder and utilities carry
   Clang `-fbounds-safety` annotations (`WEBP_COUNTED_BY`,
   `WEBP_BIDI_INDEXABLE`), enabled by the opt-in CMake option
   `WEBP_ENABLE_FBOUNDS_SAFETY`, which "expects an experimental toolchain"
   ([`CMakeLists.txt`][cmake-bounds-opt]).

---

## How it works

### The container walk

Each RIFF chunk is a four-byte tag, a little-endian `uint32` size and a payload
padded to an even length ([`format_constants.h`][fc-limits]). The decoder's
header parser walks three shapes ([`webp_dec.c`][dec-riff]):

```c
// src/dec/webp_dec.c (comment above ParseRIFF, abridged)
//   0...3   "RIFF" 4-byte tag
//   4...7   size of image data (including metadata) starting at offset 8
//   8...11  "WEBP"   our form-type signature
// The RIFF container (12 bytes) is followed by appropriate chunks:
//   12..15  "VP8 ": 4-bytes tags, signaling the use of VP8 video format
// Or,
//   12..15  "VP8L": 4-bytes tags, signaling the use of VP8L lossless format
// Or,
//   12..15  "VP8X": 4-bytes tags, describing the extended-VP8 chunk.
```

`ParseRIFF` rejects a RIFF size below 12 or above `MAX_CHUNK_PAYLOAD`
(`~0U - CHUNK_HEADER_SIZE - 1`, so header plus padding cannot overflow a
`uint32_t`). `ParseVP8X` requires a chunk size of exactly 10, reads a 24-bit
`width - 1` and `height - 1`, and rejects `width * (uint64_t)height >= MAX_IMAGE_AREA`
(`1ULL << 32`) ([`webp_dec.c`][dec-vp8x]). `ParseOptionalChunks` then skips every
chunk up to the first `VP8 ` or `VP8L`, remembering only `ALPH`, and checks the
running total against the RIFF size ([`webp_dec.c`][dec-optional]). The core
decoder never looks at `ICCP`, `EXIF` or `XMP `: they are skipped as opaque
bytes. An animated file is refused by the still decoder with
`VP8_STATUS_UNSUPPORTED_FEATURE` and a comment pointing to the demux API
([`webp_dec.c`][dec-anim]).

### The two bitstreams

**VP8 (lossy).** `VP8GetHeaders` reads a 14-bit width and height plus a 2-bit
upscaling hint per axis ([`vp8_dec.c`][vp8-dims]); the hint is stored in
`xscale`/`yscale` and never used elsewhere in `src/dec`. Non-key frames are
rejected ("Not a key frame.", [`vp8_dec.c`][vp8-keyframe]). Partition 0 holds
modes; one, two, four or eight token partitions hold coefficients, their sizes
in a 3-byte table that `ParsePartitions` clamps to the bytes left
([`vp8_dec.c`][vp8-parts]). `ParseFrame` runs one macroblock row at a time:
parse intra modes, decode each macroblock's coefficients, then
`VP8ProcessRow` reconstructs, deblocks and emits the row
([`vp8_dec.c`][vp8-parseframe], [`frame_dec.c`][frame-process]). Alpha for a
lossy image lives in `ALPH`, whose one-byte header selects raw or
VP8L-compressed data, a spatial filter and an optional quantisation
pre-processing step, rejecting any reserved bit ([`alpha_dec.c`][alpha-header]).

**VP8L (lossless).** `DecodeImageStream` reads, in order: up to four
transforms (each type at most once), an optional colour cache of 2 to 2048
entries, the prefix codes, then the entropy-coded ARGB data
([`vp8l_dec.c`][vp8l-stream], [`vp8l_dec.c`][vp8l-transform]). Transforms that
carry data (predictor, cross-colour, colour indexing) store it as sub-sampled
images decoded by a recursive call of the same routine, so a transform image
is itself a VP8L stream without transforms or an entropy image. Each "Huffman
group" has five codes (green plus length prefixes plus cache indices, red,
blue, alpha, distance); an optional entropy image picks the group per square
tile of `2^huffman_bits` pixels on a side ([`vp8l_dec.c`][vp8l-groups]). The colour cache is a
direct-mapped hash with no collision handling
([`color_cache_utils.h`][colour-cache]):

```c
// src/utils/color_cache_utils.h
static const uint32_t kHashMul = 0x1e35a7bdu;
static WEBP_UBSAN_IGNORE_UNSIGNED_OVERFLOW WEBP_INLINE int VP8LHashPix(
    uint32_t argb, int shift) {
  return (int)((argb * kHashMul) >> shift);
}
```

The main loop in `DecodeImageData` reads a green symbol and dispatches on its
range: literal (read red, blue, alpha), backward reference (length and
distance prefix codes, distance mapped through the 120-entry `kCodeToPlane`
neighbourhood table), or cache index. A backward reference is bounds-checked
against both ends of the buffer before the copy
([`vp8l_dec.c`][vp8l-loop]):

```c
// src/dec/vp8l_dec.c, DecodeImageData
if (src - data < (ptrdiff_t)dist || src_end - src < (ptrdiff_t)length) {
  goto Error;
} else {
  CopyBlock32b(src, dist, length);
}
```

At this revision the ARGB buffer is a **sliding window** when a row callback is
active: `VP8LGetWindowRows` takes the rows needed for the maximum backward
distance (`LZ77_WINDOW_SIZE`, about one million pixels, or seven rows plus eight
pixels, whichever is larger), adds the 16 queued cache rows, the rows a
`MAX_LENGTH` copy can span and two margin rows, doubles the sum to amortise the
shifts and caps it at the image height; `ShiftWindow` then `memmove`s processed
rows out ([`vp8l_dec.c`][vp8l-window]).

### Huffman tables, and CVE-2023-4863

A VP8L prefix code arrives as code lengths. `BuildHuffmanTable` turns them into
a two-level lookup table: an 8-bit root table (`HUFFMAN_TABLE_BITS`) whose
entries are either a symbol or a pointer to a second-level table for longer
codes. It counts codes per length, rejects any length above 15 and any level
with more codes than it can hold, replicates each code through the table with
`ReplicateValue`, and only at the end checks that the tree is complete
([`huffman_utils.c`][huff-build]):

```c
// src/utils/huffman_utils.c, BuildHuffmanTable
// Check if tree is full.
if (num_nodes != 2 * offset[MAX_ALLOWED_CODE_LENGTH] - 1) {
  return 0;
}
```

Before September 2023, `ReadHuffmanCodes` allocated one buffer of
`num_htree_groups * kTableSize[color_cache_bits]` entries and built every table
straight into it. `kTableSize` is the worst case for a **valid** code, computed
with zlib's `enough` tool ([`vp8l_dec.c`][vp8l-tablesize]):

```c
// src/dec/vp8l_dec.c
// All values computed for 8-bit first level lookup with Mark Adler's tool:
// https://github.com/madler/zlib/blob/9712272c78b9d9c93746d9c8e156a3728c65ca72/examples/enough.c
#define FIXED_TABLE_SIZE (630 * 3 + 410)
```

An **incomplete** code can need more second-level entries than any complete
one, and the completeness check ran after the writes. Ben Hawkes' analysis
([Hawkes 2023][hawkes], summarised in the [hostile-input thread][p-hostile])
reconstructs the exploit: four maximal valid codes fill a group's allocation,
then an invalid fifth code makes `ReplicateValue` write past the end before
`BuildHuffmanTable` returns 0. NVD records it as a heap overflow "in libwebp in
Google Chrome prior to 116.0.5845.187 and libwebp 1.3.2" allowing "an out of
bounds memory write via a crafted HTML page" ([NVD CVE-2023-4863][nvd-4863]); a
second CVE assigned to libwebp itself was rejected as a duplicate
([NVD CVE-2023-5129][nvd-5129]).

The fix, [`902bc91`][fix-commit] ("Fix OOB write in BuildHuffmanTable"),
changed the shape of table construction rather than the bound:

> _"First, BuildHuffmanTable is called to check if the data is valid. If it is
> and the table is not big enough, more memory is allocated."_

At the pinned revision `VP8LBuildHuffmanTable` always runs a validation pass
with a `NULL` table, which returns the exact size or 0, then calls
`VP8LHuffmanTablesEnsureCapacity` to chain a new `HuffmanTablesSegment` if the
current one is too small, and only then fills it ([`huffman_utils.c`][huff-twopass]).
`kTableSize` survives only as the segment granularity: up to 16 groups' worth
per segment, or 52 when there are more than 256 groups
([`vp8l_dec.c`][vp8l-helper]). **Verified:** with a 1,024-entry segment filled
with a sentinel byte, over-subscribed lengths `{1, 1, 1}`, incomplete lengths
`{1, 2}` and a nine-symbol code with lengths 1 to 8 and 15 (deep enough for a
second-level table, but incomplete) all returned 0 and left every sentinel
byte intact; `{1, 2, 2}` returned 256.

### The public decode API

There are three layers ([`decode.h`][h-simple]):

- **Simple:** `WebPDecodeRGBA(data, size, &w, &h)` and friends return a
  library-allocated buffer; the `...Into` variants write into a caller buffer
  with a caller stride, which may be negative to flip
  ([`decode.h`][h-into]). `WebPDecodeYUV` returns separate 4:2:0 planes.
- **Advanced:** `WebPDecoderConfig` bundles `WebPBitstreamFeatures` (from
  `WebPGetFeatures`), an output `WebPDecBuffer` (library or external memory)
  and `WebPDecoderOptions` ([`decode.h`][h-options]):

```c
// src/webp/decode.h
struct WebPDecoderOptions {
  int bypass_filtering;             // if true, skip the in-loop filtering
  int no_fancy_upsampling;          // if true, use faster pointwise upsampler
  int use_cropping;                 // if true, cropping is applied _first_
  int crop_left, crop_top;          // top-left position for cropping.
                                    // Will be snapped to even values.
  int crop_width, crop_height;      // dimension of the cropping area
  int use_scaling;                  // if true, scaling is applied _afterward_
  int scaled_width, scaled_height;  // final resolution. if one is 0, it is
                                    // guessed from the other one to keep the
                                    // original ratio.
  int use_threads;                  // if true, use multi-threaded decoding
  int dithering_strength;           // dithering strength (0=Off, 100=full)
  int flip;                         // if true, flip output vertically
  int alpha_dithering_strength;     // alpha dithering strength in [0..100]

  uint32_t pad[5];  // padding for later use
};
```

- **Incremental:** `WebPINewDecoder`/`WebPIDecode` create a `WebPIDecoder`;
  `WebPIAppend` copies each new piece into an internal buffer, `WebPIUpdate`
  maps a caller buffer that always holds the stream from its start; both
  return `VP8_STATUS_SUSPENDED` until the image is complete
  ([`decode.h`][h-append]). `WebPIDecGetRGB` and `WebPIDecGetYUVA` expose the
  rows decoded so far through `last_y`, and `WebPIDecodedArea` the visible
  rectangle ([`decode.h`][h-getrgb]).

Status is a `VP8StatusCode` with eight values, including `SUSPENDED`,
`USER_ABORT` and `NOT_ENOUGH_DATA` ([`decode.h`][h-status]). Output colour
spaces are an enum of byte orders: `RGB`, `RGBA`, `BGR`, `BGRA`, `ARGB`,
`RGBA_4444`, `RGB_565`, the premultiplied `rgbA`, `bgrA`, `Argb`, `rgbA_4444`,
and the planar `YUV`/`YUVA` ([`decode.h`][h-csp]).

### The incremental state machine

`WebPIDecoder` is an explicit state machine
(`STATE_WEBP_HEADER → STATE_VP8_HEADER → STATE_VP8_PARTS0 → STATE_VP8_DATA` or
`STATE_WEBP_HEADER → STATE_VP8L_HEADER → STATE_VP8L_DATA`, then `DONE` or
`ERROR`) over a `MemBuffer` in append or map mode ([`idec_dec.c`][idec-states]).
Suspension is **checkpoint and replay**, not resumable parsing:

- **Lossy:** before each macroblock, `SaveContext` copies the two `VP8MB`
  context entries and the token bit reader; if `VP8DecodeMB` runs out of data,
  `RestoreContext` rewinds and the call returns `SUSPENDED`. Running out is an
  error unless the macroblock is in the last token partition and, when that
  is the only token partition, no more than `MAX_MB_SIZE` (4,096) bytes are
  buffered ([`idec_dec.c`][idec-remaining],
  [`idec_dec.c`][idec-context]). Partition 0 must be complete before any
  macroblock is decoded.
- **Lossless:** `DecodeVP8LHeader` waits for an eighth of the chunk, then
  re-parses the whole header from scratch on each attempt until it succeeds
  ([`idec_dec.c`][idec-lossless]). In the data, `SaveState` snapshots the bit
  reader and copies the whole colour cache every `SYNC_EVERY_N_ROWS` (8) rows;
  on end of input `RestoreState` rewinds to the last checkpoint
  ([`vp8l_dec.c`][vp8l-state]).

**Verified:** feeding the probe's 136,298-byte lossless file one byte at a time
returned `SUSPENDED` 136,296 times and produced output byte-identical to
`WebPDecodeRGBA`; the 36,280-byte lossy file returned `SUSPENDED` 36,277 times,
also identical.

---

## Analysis

### 1. Pixel and memory model

Pixels leave the decoder in one of two shapes, both with explicit strides
([concepts: stride][c-stride]). `WebPRGBABuffer` is one interleaved plane
(`rgba`, `stride`, `size`); `WebPYUVABuffer` is four planes (`y`, `u`, `v`, `a`)
with separate strides and sizes, chroma at `(w + 1) / 2` by `(h + 1) / 2`
([`decode.h`][h-buffer], [concepts: chroma subsampling][c-chroma]). Strides are
`int` and may be negative. Sample type is always 8-bit: there is no 16-bit,
float or 10-bit path, which the formats do not need (VP8 is 8-bit 4:2:0, VP8L
is 8-bit ARGB). Packed `RGBA_4444` and `RGB_565` outputs also exist,
byte-swappable at build time with `WEBP_SWAP_16BIT_CSP`. Internally VP8L works
in `uint32_t` ARGB (alpha in the high byte) and VP8 in macroblock-aligned YUV
caches with extra filter rows; neither internal layout is exposed.

### 2. Genericity mechanism

None in the type sense. Variation is runtime data: the `WEBP_CSP_MODE` enum
selects an emitter, and function-pointer tables select kernels (`VP8Transform`,
`VP8LPredictors`, `WebPUpsamplers`). The internal `VP8Io` carries `setup`,
`put` and `teardown` hooks that `io_dec.c` fills per output mode
([`vp8_dec.h`][vp8io]); this is the decoder's only extension point and it is not
installed as a public header. Compared with the compile-time pixel types of
[Boost.GIL][gil] or the trait-based decoders of [image-rs][image-rs], libwebp
pays an indirect call per row or block and gains one binary for every output.

### 3. Colour and metadata

The decoders apply no colour management. The core decoder skips `ICCP`, `EXIF`
and `XMP ` without reading them ([`webp_dec.c`][dec-optional]); a caller who
wants them uses `WebPDemuxGetChunk`, which returns pointers into the caller's
data, and stores a chunk only when the matching `VP8X` flag is set
([`demux.c`][demux-meta], [`mux_types.h`][mux-flags]). The container spec says
"If this chunk is not present, sRGB SHOULD be assumed" and that readers "MAY
ignore all except the first" `ICCP`, `EXIF` or `XMP ` chunk
([spec][spec-iccp], [spec][spec-meta]). There is no `cICP`
([concepts: CICP][c-cicp]), no gamma chunk, no HDR transfer, no
[gain map][c-gainmap] and no bit depth above 8: the format has no field for
any of them. Lossy `Y'CbCr` to RGB uses fixed BT.601 limited-range
coefficients in fixed-point arithmetic ([`yuv.h`][yuv]); a file cannot signal
another matrix or full range, and the VP8 header's colour-space and clamping
bits are read into `colorspace` and `clamp_type` and never used
([`vp8_dec.c`][vp8-colorspace]). Alpha is straight in the bitstream; the decoder
premultiplies on request (`MODE_rgbA` and the other lower-case modes,
[concepts: alpha][c-alpha]).

### 4. I/O and codec architecture

The decoder is **push**: the caller supplies bytes, never a read callback
([concepts: push and pull][c-pushpull]). Against the
[incremental decoding vocabulary][c-incremental]:

| Property                   | libwebp at the pinned revision                                                                                      |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Incremental                | yes: `WebPIAppend` (copy) or `WebPIUpdate` (map), any split of the input                                            |
| Suspendable                | yes, by checkpoint and replay: per macroblock (lossy), every 8 rows plus full header re-parse (lossless)            |
| Progressive (refinement)   | no: neither bitstream has passes; partial output is a prefix of rows                                                |
| Row callback               | internal only (`VP8Io::put`); public callers poll `WebPIDecGetRGB`'s `last_y`                                       |
| Region decode              | yes: `use_cropping`; lossy stops after the last macroblock row in the crop, but still decodes every row above it    |
| Downscaled decode          | yes: `use_scaling`, an area-averaging rescaler applied after cropping; large downscales also bypass the loop filter |
| Cancellation               | only by returning 0 from the internal `put` hook (`VP8_STATUS_USER_ABORT`)                                          |
| Output into caller storage | yes: `...Into`, `WebPINewRGB`/`WebPINewYUVA`, or `is_external_memory` on `WebPDecBuffer`                            |

Cropping is applied first and scaling second ([`webp_dec.c`][dec-io],
[`buffer_dec.c`][buffer-alloc]). For lossy images, any scaling turns off fancy
upsampling, and a large downscale also turns off the loop filter:
`bypass_filtering` is set when both scaled dimensions are below three quarters
of the source. VP8L must decode
every pixel up to the bottom of the crop, since backward references reach
anywhere in the preceding megapixel. **Verified:** a 100x50 crop at (11, 7)
scaled to width 40 returned `VP8_STATUS_OK` and a 40x20 buffer; a crop wider
than the frame returned `VP8_STATUS_INVALID_PARAM`.

### 5. Hostile input and safety

**Limits.** None are runtime-configurable; all are format constants or build
macros:

| Limit                        | Value                                                                  | Where                             |
| ---------------------------- | ---------------------------------------------------------------------- | --------------------------------- |
| VP8 dimensions               | 14 bits each (at most 16,383)                                          | [`vp8_dec.c`][vp8-dims]           |
| VP8L dimensions              | `VP8L_IMAGE_SIZE_BITS` = 14 bits each (at most 16,384)                 | [`format_constants.h`][fc-vp8]    |
| `VP8X` canvas                | `MAX_CANVAS_SIZE` = 2^24 per side, area below `MAX_IMAGE_AREA` = 2^32  | [`format_constants.h`][fc-limits] |
| Chunk payload                | `MAX_CHUNK_PAYLOAD` = 2^32 - 10; sum of chunks within the RIFF size    | [`webp_dec.c`][dec-optional]      |
| One allocation               | `WEBP_MAX_ALLOCABLE_MEMORY`: 2^34 bytes on 64-bit, ~2 GiB on 32-bit    | [`utils.h`][utils-max]            |
| Huffman groups               | 2^16; remapped above 200 or the entropy-image size; 20 input bits each | [`vp8l_dec.c`][vp8l-groups]       |
| Frames, chunks, `EXIF` bytes | no limit beyond the input size                                         | [`demux.c`][demux-anmf]           |

`WebPSafeMalloc` and `WebPSafeCalloc` reject `nmemb * size` above the cap or
above `size_t` ([`utils.c`][utils-check]); there is no total memory budget,
no pixel budget and no time budget. A caller who wants one reads
`WebPGetFeatures` first and decides. **Verified:** a 30-byte file whose `VP8X`
declares a 16,777,216-square canvas fails `WebPGetInfo`
(`VP8_STATUS_BITSTREAM_ERROR` from `WebPGetFeatures`), but a 65,536 by 65,535
canvas (area just below 2^32) passes both header calls with no image data
behind it, so header acceptance says nothing about what a decode will allocate.

**Defences in the code.** Size fields are checked against what remains before
use; backward references are checked against both ends of the window; the
lossless header refuses a second transform of the same type; `ReadHuffmanCodesHelper`
rejects a group count the remaining bits cannot encode before allocating for it
([`vp8l_dec.c`][vp8l-helper]). Since 2025 the decoder, `webputils` and
`webpdecoder` can be compiled with Clang `-fbounds-safety`
([`CMakeLists.txt`][cmake-bounds]); the annotations widen pointers into
bounds-carrying pairs ([`bounds_safety.h`][bounds-h], [Clang docs][clang-bounds]).
Forty-nine source and header files still declare
`WEBP_ASSUME_UNSAFE_INDEXABLE_ABI`, and the Huffman builder receives its table
through `WEBP_UNSAFE_FORGE_BIDI_INDEXABLE` sized from the validated
`total_size`, so the checked bound is the computed one, not the allocation's
([`huffman_utils.c`][huff-twopass]).

**History.** The three most instructive advisories:

- **CVE-2023-4863** (heap write, exploited): table sized from a worst case for
  valid input, filled before validation. Fixed by validating first and growing
  storage on demand ([§ How it works](#huffman-tables-and-cve-2023-4863)).
  Hawkes argues coverage-guided fuzzing was very unlikely to find it; the
  trigger is four maximal valid codes followed by a precisely invalid one
  ([Hawkes 2023][hawkes]).
- **CVE-2020-36328** (heap overflow): "A heap-based buffer overflow in function
  WebPDecodeRGBInto is possible due to an invalid check for buffer size"
  ([NVD][nvd-36328]); the caller-buffer API is itself attack surface.
- **CVE-2020-36331** (read): "An out-of-bounds read was found in function
  ChunkAssignData" in the mux reader ([NVD][nvd-36331]); container code, not
  only entropy decoding, needs the same care.

### 6. Allocation and ownership

Allocation goes through `WebPSafeMalloc`/`WebPSafeCalloc`/`WebPSafeFree`
([`utils.c`][utils-check]); there is no allocator parameter, only build macros
for test-time failure injection (`MALLOC_FAIL_AT`, `MALLOC_LIMIT`). Ownership is
explicit in each struct: `WebPDecBuffer::is_external_memory` says whether
`private_memory` is the library's, and a value of 2 or more marks external
memory as "slow" so the incremental decoder decodes into its own buffer and
copies once at the end ([`decode.h`][h-buffer]). `WebPIDecoder` keeps a pointer
to the caller's output buffer and `WebPDecoderConfig`, which must outlive it
([`decode.h`][h-idecode]). The demuxer copies nothing: frames and chunks are
offsets into the caller's `WebPData`, and `WebPDemuxPartial` must be called
again if that data moves ([`demux.h`][demux-h-partial]). VP8L's sliding window
bounds lossless working memory to a few million pixels when rows are emitted as
they finish ([`vp8l_dec.c`][vp8l-window]); `WebPAnimDecoder` holds two full
canvases (`curr_frame`, `prev_frame_disposed`) of `canvas_width * 4 *
canvas_height` bytes each ([`anim_decode.c`][anim-canvas]).

### 7. CPU parallelism and SIMD

**Threads.** Only lossy decoding is threaded, and only as a two-stage pipeline:
the main thread parses and (with `mt_method == 2`) hands reconstruction plus
deblocking of row `n` to one worker while it parses row `n + 1`, over three
16-row cache lines so the lagging deblocker never writes the rows being decoded
([`frame_dec.c`][frame-cache], [`frame_dec.c`][frame-process]). It switches on
only when `use_threads` is set and the width is at least
`MIN_WIDTH_FOR_THREADS` (512) ([`frame_dec.c`][frame-thread]). The worker is
`WebPWorker`, a thin pthread or Win32 wrapper the caller can replace through
`WebPSetWorkerInterface`, which is exported but declared only in the
uninstalled `src/utils/thread_utils.h`. VP8L decoding is single-threaded (the thread-method
function asserts `!headers->is_lossless`).

**SIMD.** Every DSP module defines its function pointers, then an `Init`
wrapped in `WEBP_DSP_INIT_FUNC`, which runs once per value of the global
`VP8GetCPUInfo` under a mutex ([`cpu.h`][cpu-init]). The init fills C versions,
then overwrites them by ISA ([`dec.c`][dsp-dec-init], [`lossless.c`][dsp-lossless-init]):

```c
// src/dsp/lossless.c, VP8LDspInit
if (VP8GetCPUInfo != NULL) {
#if defined(WEBP_HAVE_SSE2)
  if (VP8GetCPUInfo(kSSE2)) {
    VP8LDspInitSSE2();
#if defined(WEBP_HAVE_SSE41)
    if (VP8GetCPUInfo(kSSE4_1)) {
      VP8LDspInitSSE41();
#if defined(WEBP_HAVE_AVX2)
      if (VP8GetCPUInfo(kAVX2)) {
        VP8LDspInitAVX2();
```

Two gates combine: `WEBP_HAVE_*` says the build compiled that ISA's file (each
`_sse41.c`, `_avx2.c` file is built with its own flags), and `VP8GetCPUInfo`
says the running CPU has it ([`cpu.h`][cpu-gates]). The x86 probe uses `cpuid`
and `xgetbv`; the ARM probe returns 1 for NEON unless `WEBP_HAVE_NEON_RTCD`
reads `/proc/cpuinfo`, and when NEON is enabled at compile time (the default on
AArch64) the C versions of NEON-covered kernels are compiled out
(`WEBP_NEON_OMIT_C_CODE`); the WebAssembly probe follows the comment "Use
compile flags as an indicator of SIMD support instead of a runtime check"
([`cpu.c`][cpu-wasm]). `VP8GetCPUInfo` is a mutable global, so a test can set it
to `NULL` to force the C path, except for NEON kernels whose C versions were
compiled out, which are installed regardless
([`lossless.c`][dsp-lossless-init]). The `CPUFeature` enum lists `kVSX` but no
VSX kernels exist at this revision ([`cpu.h`][cpu-features]). Decoder
kernels exist for SSE2, SSE4.1, NEON, MSA and MIPS32/DSPr2; AVX2 covers only
the lossless module. Even scalar code paths are tuned by CPU: `GetCoeffs`
picks `GetCoeffsAlt` on CPUs flagged `kSlowSSSE3` ([`vp8_dec.c`][vp8-coeffs]).

### 8. GPU offload and interop

None. libwebp has no GPU code and no hook for one. The interop it offers is
the planar `MODE_YUV`/`MODE_YUVA` output, which skips the CPU colour conversion
and upsampling and hands three 8-bit planes plus alpha to whoever uploads them
([concepts: staging and upload][c-upload]). VP8's sequential boolean coder and
the per-row dependency of intra prediction and VP8L's LZ77 leave nothing
obvious to move to a GPU except colour conversion and the loop filter.

### 9. Temporal, animation and containers

Animation lives outside the decoder, in `libwebpdemux`. `WebPDemux` parses
`ANIM` (background colour, loop count) and each `ANMF` (offset in units of two
pixels, 24-bit size and duration, dispose and blend bits), rejects a frame
whose area reaches 2^32, and checks frame bounds against the canvas
([`demux.c`][demux-anmf], [`demux.c`][demux-valid]). `WebPDemuxPartial` works
on a prefix and reports `WEBP_DEMUX_PARSING_HEADER`, `PARSED_HEADER` or `DONE`
([`demux.h`][demux-h-partial]). Each frame is then an ordinary still decoded
with `WebPDecode`.

`WebPAnimDecoder` composites frames into RGBA, BGRA or their premultiplied
forms ([`demux.h`][demux-h-animopts]). It takes the permissive reading of the
spec in one place and departs from a SHOULD in another. Dispose-to-background
clears the frame rectangle to transparent zero rather than the `ANIM` colour
([`anim_decode.c`][anim-dispose]),
which the spec permits since the colour is "a hint" ([spec][spec-bg]). Blending
is integer arithmetic on encoded 8-bit values ([`anim_decode.c`][anim-blend]),
while the spec says blending "SHOULD be done in linear color space"
([spec][spec-blend]). Playback is forward only (`WebPAnimDecoderReset` restarts
it); `IsKeyFrame` lets a frame that covers the canvas start from a zeroed
canvas instead of a copy of the previous one.

### 10. Testing and conformance

The in-tree tests are fuzz targets ([`tests/README.md`][tests-readme]): 14
`fuzztest` binaries under `tests/fuzzer/` declaring 19 `FUZZ_TEST` entry points
(simple, advanced and animation APIs, demux and mux, the animation encoder,
encode-decode round trip, `imageio`, `webpinfo`, `sharpyuv`), one of them aimed
at the Huffman builder alone, which
calls `ReadHuffmanCodesHelper` with fuzzed group counts and cache sizes
([`huffman_fuzzer.cc`][fuzz-huffman]). The advanced fuzzer reads crop, scale
and dithering options from the input, feeds the file incrementally in doubling
chunks through either `WebPIUpdate` or `WebPIAppend`, and asserts the result
equals a one-shot `WebPDecode` whenever both succeed: a differential oracle
inside the library's own suite ([`advanced_api_fuzzer.cc`][fuzz-advanced]).
Fuzzers cap decoded pixels at about a megapixel, or a tenth to an eighteenth of
that under sanitisers ([`fuzz_utils.h`][fuzz-limits]).

OSS-Fuzz builds the targets with the project's own script
([`build.sh`][fuzz-build]): `-DWEBP_MAX_IMAGE_SIZE=838860800` "to reduce
spurious OOMs" (a macro only `imageio` reads, not the decoder),
`allocator_may_return_null=1`, a seed corpus of every `.webp` under 32 KiB from
the external test-data repository, and, for each binary that links
`nalloc_init`, a second `_nalloc` wrapper run with `NALLOC_FREQ=32` to inject
allocation failures ([`nalloc.h`][nalloc]). Conformance data lives outside the
tree in [`libwebp-test-data`][test-data]: the VP8 test vectors
(`vp80-00-comprehensive-*` to `vp80-05-sharpness-*`) and alpha and lossy-alpha
files, checked against an MD5 list (`libwebp_tests.md5`) by `test_dwebp.sh`,
and the lossless vectors (`lossless_vec_1_*`, `lossless_vec_2_*`, described in
`lossless_vec_list.txt`), which `test_lossless.sh` decodes and compares byte for
byte with reference `grid` and `peak` images, once normally and once with
`dwebp -noasm`.

---

## Lessons for Sparkles

- **Q4, Q8.** CVE-2023-4863 is a precise rule for a D Huffman or prefix-code
  builder: **validate the whole code (Kraft completeness and per-level
  counts) before writing any entry, then size storage from the validated
  result.** libwebp's fix keeps a single builder function and calls it twice
  (`NULL` table to validate and size, real table to fill); in D the two passes
  can be one `@safe pure nothrow @nogc` validator returning the exact size and a
  filler over a slice of that size, so the bounds check that dip1000 and slice
  indexing give for free is against the real allocation, not a forged one. The
  [entropy-codecs thread][p-entropy] already recommends one canonical
  table builder shared by DEFLATE, JPEG and WebP; libwebp shows the builder is
  the place where a single defect becomes remote code execution. Where Sparkles
  stands: two PNG decoders without a shared builder
  ([existing-code baseline, G1][bl-existing]).
- **Q4.** libwebp's suspension model is **checkpoint and replay**: per
  macroblock for lossy, every eight rows plus a full colour-cache copy for
  lossless, and complete header re-parse until it fits. It works on any byte
  split (verified) but it re-does work and copies cache state proportional to
  `2^cache_bits`. A D decoder written as an explicit state machine in the
  [Wuffs style][c-incremental] would suspend at any byte without replay; a
  checkpoint design is simpler and is evidence of what is good enough for
  browsers. Either way, the `G7` gap in the
  [existing-code baseline][bl-existing] (whole-file, single-shot decoders) is
  what this decides.
- **Q4, Q9.** The container and the two bitstreams are three separable layers in
  the code itself: the RIFF walk is about 300 lines of C (lines 32 to 458 of
  `webp_dec.c`, comments and blank lines excluded), VP8 and VP8L share only the
  output stage (`VP8Io`, `WebPDecBuffer`) apart from lossy alpha reusing the
  VP8L decoder, and animation compositing is another library
  over the still decoder. That is evidence for splitting a RIFF reader, each
  bitstream and the compositor along the same seams. The chunk grammar (tag,
  `uint32` size, even padding, sizes bounded by the parent) is what the
  [`sparkles:wired` baseline][bl-wired] asks a binary description to express.
- **Q5.** WebP's colour model is small: sRGB by default, an optional ICC blob,
  fixed BT.601 limited-range YUV, 8-bit straight alpha, opaque `EXIF`/`XMP `
  blobs. A model that covers it needs "ICC bytes, not applied" and "matrix and
  range fixed by the format"; and a compositor that blends encoded sRGB, like
  libwebp's, will not match one that linearises as the spec recommends. Where
  colour is untyped today: [existing-code baseline, G4 and G5][bl-existing].
- **Q4, Q8.** Limits are the weakest part of libwebp's API to copy: no pixel,
  memory, frame-count or metadata-size budget exists in `WebPDecoderConfig`, and
  a 30-byte header can promise a four-gigapixel canvas (verified). The ABI's
  padding words leave no natural place to add one. Sparkles' existing
  precedent is a declared-size bound (`maxPngPixels`), not a work bound
  ([existing-code baseline, G7][bl-existing]).
- **Q3, Q7.** `WEBP_DSP_INIT_FUNC` is runtime dispatch through mutable global
  function pointers, a mutex and a re-init when the CPU-info pointer changes,
  with two gates (the build compiled the ISA's file, the CPU reports it). The
  idea (choose kernels once, let a test force the scalar path) matches LDC's
  `@target` plus a probe; the mechanism conflicts with the standing rule against
  `__gshared` state. The [shaders and SIMD baseline][bl-shaders] (G5, G6)
  records that Sparkles already repeats this dispatch by hand.
- **Q1.** The output buffer model (one interleaved plane or four planes, each
  with a signed `int` stride and a byte size) is a minimal view type that
  covers every WebP consumer. Its flip is a negative stride, which the one
  strided type Sparkles has (`ColourRegion`, with a `size_t` stride) cannot
  express; a flip would have to be a view
  property instead ([existing-code baseline, G2][bl-existing]).
- **Q6.** `MODE_YUVA` output skips colour conversion and upsampling, so a GPU
  path can upload three planes and convert in a shader. The obstacle is the
  RGBA8-only upload path ([existing-code baseline, G8][bl-existing];
  [Vulkan baseline][bl-vk]), not the decoder.
- **Q8.** The advanced fuzzer's incremental-equals-one-shot assertion is the
  cheapest differential oracle a suspendable D decoder can adopt, and
  libwebp itself is the natural oracle for both bitstreams, with
  `libwebp-test-data` (VP8 vectors, lossless vectors, MD5 list) as the
  conformance corpus. The `NALLOC_FREQ` allocation-failure variant maps onto
  testing every `Expected` error path of a `@nogc` decoder. Hawkes' argument
  that coverage fuzzing would not have found CVE-2023-4863 means a structured
  generator of near-valid prefix codes is worth its own target
  ([hostile-input thread][p-hostile]).

## Strengths

- One reference implementation of both bitstreams and the container, used by
  every major platform; its behaviour is the de facto specification
  ([RFC 9649][rfc9649] documents it).
- The incremental decoder accepts any split of the input in copy or map mode,
  and its equivalence with one-shot decoding is fuzzed.
- Region and downscaled decode are first-class options, applied in the decoder
  rather than after a full decode.
- Output into caller storage with caller strides, planar or interleaved,
  straight or premultiplied, without a separate conversion pass.
- Broad, maintained SIMD coverage (x86, ARM, MIPS) with a runtime override
  for testing.
- Post-2023 hardening: validate-then-allocate Huffman tables, a dedicated
  Huffman fuzzer, allocation-failure fuzzing and optional `-fbounds-safety`.

## Weaknesses

- No configurable limits for pixels, memory, frames or metadata; the only cap
  is a per-allocation compile-time constant.
- Suspension replays work: whole lossless header re-parse and colour-cache
  copies at every checkpoint.
- No public row callback and no cancellation in the public API; the `VP8Io`
  hooks are internal.
- Colour metadata is passed through, never interpreted; YUV matrix and range
  are fixed; the animation compositor ignores the background colour and blends
  in encoded space.
- Lossless decoding is single-threaded; lossy threading is a two-stage
  pipeline on one worker.
- Memory safety rests on C discipline; the bounds-safety build is opt-in and
  needs an experimental Clang.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                  | Trade-off                                                                                    |
| ------------------------------------------------------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Lossy is a VP8 key frame                                      | Reuse the intra coding of a shipped video codec                            | 8-bit 4:2:0 only, BT.601 limited range, no HDR, no 4:4:4                                     |
| Lossless is a separate format in the same container           | Compression tuned for ARGB graphics without VP8's constraints              | Two unrelated decoders to implement, fuzz and harden                                         |
| Spatially varying prefix codes (up to 2^16 groups)            | Better compression on mixed-content images                                 | Many table builds per image; table construction became the exploited attack surface          |
| Huffman storage sized by worst case, built before validation  | One allocation, fast decoding (pre-2023)                                   | CVE-2023-4863; replaced by validate, then grow segments                                      |
| Incremental decoding by checkpoint and replay                 | Small change to the one-shot decoder; one code path for both               | Repeated work and state copies; header must be fully re-parsed                               |
| Global function-pointer DSP tables with lazy `Init`           | One binary runs everywhere; per-ISA files compiled with their own flags    | Mutable global state behind a mutex; dispatch cost per call; C path compiled out on AArch64  |
| Fixed C ABI with padded, version-checked structs              | Binary compatibility since the early releases, across Android and browsers | Options grow only into padding words; a limits object would need a new entry point           |
| Animation in a separate library, compositing to full canvases | Keeps the still decoder small; most consumers want stills                  | Two canvas-sized buffers per animation; compositing semantics differ from the spec's SHOULDs |

## Sources

- libwebp source at `1844042d1ca751e62e61df7617dba19c98588339`: [`src/webp/decode.h`][h-simple],
  [`src/dec/webp_dec.c`][dec-riff], [`src/dec/vp8l_dec.c`][vp8l-loop],
  [`src/utils/huffman_utils.c`][huff-build], [`src/dec/idec_dec.c`][idec-states],
  [`src/dec/frame_dec.c`][frame-process], [`src/demux/demux.c`][demux-anmf],
  [`src/demux/anim_decode.c`][anim-blend], [`src/dsp/cpu.h`][cpu-init],
  [`tests/fuzzer/`][fuzz-advanced].
- In-tree specifications: [`doc/webp-container-spec.txt`][spec-container],
  [`doc/webp-lossless-bitstream-spec.txt`][spec-lossless].
- Zern, Massimino and Alakuijala, [RFC 9649: WebP Image Format][rfc9649] (2024);
  Bankoski et al., [RFC 6386: VP8 Data Format and Decoding Guide][rfc6386] (2011).
- The CVE-2023-4863 fix, [`902bc91`][fix-commit] ("Fix OOB write in BuildHuffmanTable",
  September 7, 2023).
- NVD: [CVE-2023-4863][nvd-4863], [CVE-2023-5129][nvd-5129] (rejected duplicate),
  [CVE-2020-36328][nvd-36328], [CVE-2020-36331][nvd-36331].
- Ben Hawkes, [The WebP 0day][hawkes] (Isosceles, September 21, 2023).
- [`libwebp-test-data`][test-data] at `06ddd96e276c2c638a72d39d3c0f340afd61978c`.
- Clang, [`-fbounds-safety`][clang-bounds].
- Within this catalog: [concepts][concepts], [hostile-input papers][p-hostile],
  [entropy-codec papers][p-entropy], [Skia][skia], [image-rs][image-rs],
  [Go `image`][go-image], [zune-image][zune], and the baselines
  ([existing code][bl-existing], [shaders and SIMD][bl-shaders],
  [wired][bl-wired], [Vulkan][bl-vk]).

<!-- References -->

[repo]: https://github.com/webmproject/libwebp
[docs]: https://developers.google.com/speed/webp
[copying]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/COPYING
[patents]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/PATENTS
[news]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/NEWS#L1-L13
[spec-container]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/doc/webp-container-spec.txt
[spec-container-intro]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/doc/webp-container-spec.txt#L23-L29
[spec-bg]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/doc/webp-container-spec.txt#L397-L413
[spec-blend]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/doc/webp-container-spec.txt#L515-L526
[spec-iccp]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/doc/webp-container-spec.txt#L676-L686
[spec-meta]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/doc/webp-container-spec.txt#L690-L693
[spec-lossless]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/doc/webp-lossless-bitstream-spec.txt
[spec-lossless-intro]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/doc/webp-lossless-bitstream-spec.txt#L20-L26
[h-simple]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/decode.h#L59-L102
[h-into]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/decode.h#L104-L118
[h-csp]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/decode.h#L160-L205
[h-buffer]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/decode.h#L208-L256
[h-status]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/decode.h#L261-L270
[h-append]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/decode.h#L272-L373
[h-getrgb]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/decode.h#L375-L412
[h-options]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/decode.h#L481-L506
[h-idecode]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/decode.h#L525-L546
[fc-vp8]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/format_constants.h#L20-L37
[fc-limits]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/format_constants.h#L79-L96
[mux-flags]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/mux_types.h#L32-L41
[dec-riff]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/webp_dec.c#L32-L96
[dec-vp8x]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/webp_dec.c#L98-L151
[dec-optional]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/webp_dec.c#L153-L225
[dec-anim]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/webp_dec.c#L436-L458
[dec-io]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/webp_dec.c#L913-L968
[buffer-alloc]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/buffer_dec.c#L179-L226
[vp8io]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8_dec.h#L28-L75
[vp8-parts]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8_dec.c#L223-L259
[vp8-dims]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8_dec.c#L333-L350
[vp8-keyframe]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8_dec.c#L408-L412
[vp8-colorspace]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8_dec.c#L388-L391
[vp8-coeffs]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8_dec.c#L526-L534
[vp8-parseframe]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8_dec.c#L671-L701
[frame-process]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/frame_dec.c#L527-L570
[frame-cache]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/frame_dec.c#L641-L686
[frame-thread]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/frame_dec.c#L688-L702
[alpha-header]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/alpha_dec.c#L76-L89
[vp8l-tablesize]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8l_dec.c#L76-L90
[vp8l-groups]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8l_dec.c#L379-L474
[vp8l-helper]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8l_dec.c#L476-L600
[vp8l-window]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8l_dec.c#L1195-L1300
[vp8l-state]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8l_dec.c#L1398-L1417
[vp8l-loop]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8l_dec.c#L1418-L1581
[vp8l-transform]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8l_dec.c#L1619-L1675
[vp8l-stream]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/vp8l_dec.c#L1762-L1800
[colour-cache]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/utils/color_cache_utils.h#L31-L61
[huff-build]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/utils/huffman_utils.c#L57-L227
[huff-twopass]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/utils/huffman_utils.c#L229-L303
[idec-states]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/idec_dec.c#L32-L85
[idec-context]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/idec_dec.c#L307-L322
[idec-remaining]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/idec_dec.c#L489-L552
[idec-lossless]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dec/idec_dec.c#L554-L610
[demux-anmf]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/demux/demux.c#L314-L362
[demux-meta]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/demux/demux.c#L503-L540
[demux-valid]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/demux/demux.c#L613-L662
[demux-h-partial]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/demux.h#L80-L112
[demux-h-animopts]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/webp/demux.h#L255-L262
[anim-canvas]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/demux/anim_decode.c#L136-L145
[anim-blend]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/demux/anim_decode.c#L222-L300
[anim-dispose]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/demux/anim_decode.c#L429-L439
[utils-max]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/utils/utils.h#L37-L45
[utils-check]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/utils/utils.c#L182-L203
[bounds-h]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/utils/bounds_safety.h#L41-L58
[cmake-bounds-opt]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/CMakeLists.txt#L49-L53
[cmake-bounds]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/CMakeLists.txt#L424-L430
[yuv]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dsp/yuv.h#L10-L31
[cpu-gates]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dsp/cpu.h#L66-L92
[cpu-init]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dsp/cpu.h#L213-L276
[cpu-features]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dsp/cpu.h#L315-L330
[cpu-wasm]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dsp/cpu.c#L184-L240
[dsp-dec-init]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dsp/dec.c#L819-L851
[dsp-lossless-init]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/src/dsp/lossless.c#L680-L714
[tests-readme]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/tests/README.md#L1-L19
[fuzz-advanced]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/tests/fuzzer/advanced_api_fuzzer.cc#L96-L196
[fuzz-huffman]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/tests/fuzzer/huffman_fuzzer.cc#L31-L78
[fuzz-limits]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/tests/fuzzer/fuzz_utils.h#L46-L60
[fuzz-build]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/tests/fuzzer/oss-fuzz/build.sh#L40-L90
[nalloc]: https://github.com/webmproject/libwebp/blob/1844042d1ca751e62e61df7617dba19c98588339/tests/fuzzer/nalloc.h
[fix-commit]: https://github.com/webmproject/libwebp/commit/902bc9190331343b2017211debcec8d2ab87e17a
[nvd-4863]: https://nvd.nist.gov/vuln/detail/CVE-2023-4863
[nvd-5129]: https://nvd.nist.gov/vuln/detail/CVE-2023-5129
[nvd-36328]: https://nvd.nist.gov/vuln/detail/CVE-2020-36328
[nvd-36331]: https://nvd.nist.gov/vuln/detail/CVE-2020-36331
[hawkes]: https://blog.isosceles.com/the-webp-0day/
[rfc9649]: https://doi.org/10.17487/RFC9649
[rfc6386]: https://www.rfc-editor.org/rfc/rfc6386
[test-data]: https://chromium.googlesource.com/webm/libwebp-test-data/+/06ddd96e276c2c638a72d39d3c0f340afd61978c
[clang-bounds]: https://clang.llvm.org/docs/BoundsSafety.html
[concepts]: ./concepts.md
[c-stride]: ./concepts.md#stride
[c-chroma]: ./concepts.md#chroma-subsampling
[c-cicp]: ./concepts.md#cicp
[c-gainmap]: ./concepts.md#hdr-gain-map
[c-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[c-incremental]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[c-upload]: ./concepts.md#staging-and-upload
[p-hostile]: ./papers/hostile-input-safety.md
[p-entropy]: ./papers/entropy-codecs.md
[skia]: ./skia.md
[image-rs]: ./image-rs.md
[go-image]: ./go-image.md
[zune]: ./zune-image.md
[gil]: ./boost-gil.md
[bl-existing]: ./baseline/existing-code.md#gaps-and-tensions
[bl-shaders]: ./baseline/shaders-simd.md#gaps-and-tensions
[bl-wired]: ./baseline/wired.md#gaps-and-tensions
[bl-vk]: ./baseline/vulkan.md
