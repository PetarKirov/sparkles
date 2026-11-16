# stb_image, stb_image_write and stb_image_resize2 (C)

Sean Barrett's single-header image loader, its writer and Jeff Roberts's resizer: long embedded in games and small tools (raylib among them), designed for ease of integration over completeness or hostile-input safety, and in Sparkles the reference decoder that the D PNG codec is held to byte for byte.

| Field         | Value                                                                                                                                                         |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C (C89-compatible, compiles as C++)                                                                                                                           |
| License       | Dual: MIT or public domain (Unlicense), at the user's choice ([`LICENSE`][stb-license])                                                                       |
| Repository    | [nothings/stb][stb-repo] (`stb_image.h` v2.30, `stb_image_write.h` v1.16, `deprecated/stb_image_resize2.h` v2.18)                                             |
| Revision read | `003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5` (October 22, 2026); raylib `dbc56a87da87d973a9c5baa4e7438a9d20121d28` for its vendored copy                        |
| Documentation | In-header documentation ([`stb_image.h`][stb-doc-usage], [`stb_image_write.h`][stbw-about]); [`README.md`][stb-readme-faq]; [`docs/stb_howto.txt`][stb-howto] |
| Category      | Formats: single-file decoders and encoders, pull decoding into one malloc'd interleaved buffer                                                                |
| Tier          | B                                                                                                                                                             |
| Last reviewed | November 15, 2026                                                                                                                                             |

> [!NOTE]
> Claims marked **verified** were rerun in `/tmp/stb-image-verify/`
> (`probe.c`, `gif.c`), compiled with GCC 16.2.0 from the Sparkles dev shell under
> `-fsanitize=address,undefined` against the headers at the pinned revision. The
> clone is shallow (one commit), so the history of individual fixes could not be
> read from it. No performance number in this page was measured.

---

## Overview

### What it solves

`stb_image.h` decodes JPEG (baseline and progressive), PNG at 1 to 16 bits, BMP, TGA,
PSD (composited view), GIF, Radiance HDR, Softimage PIC and binary PNM into one
contiguous, interleaved, top-left-first buffer. Its header states its audience
plainly ([`stb_image.h`][stb-quicknotes]):

> _"Primarily of interest to game developers and other people who can avoid
> problematic images and only need the trivial interface"_

### Design philosophy

The design philosophy is a ranked list ([`stb_image.h`][stb-philosophy]):

> _"stb libraries are designed with the following priorities: 1. easy to use 2. easy
> to maintain 3. good performance"_

with portability, a small source footprint and no dependencies as derived goals. The
repository's FAQ explains the single file as a deployment choice, chiefly for Windows,
where "the difference between 2 files and 1 file is a big deal"
([`README.md`][stb-readme-why]), and freezes the format list on security grounds
([`README.md`][stb-readme-formats]):

> _"As stb_image use has grown, it has become more important for us to focus on
> security of the codebase. Adding new image formats increases the amount of code we
> need to secure, so it is no longer worth adding new formats."_

The security posture is stated just as plainly, at the top of the README and in
[`SECURITY.md`][stb-security]:

> _"This project discusses security-relevant bugs in public in Github Issues and Pull
> Requests, and it may take significant time for security fixes to be implemented or
> merged. If this poses an unreasonable risk to your project, do not use stb
> libraries."_

`stb_image_write.h` writes PNG, BMP, TGA, JPEG and HDR "for source code compactness and
simplicity, not optimal image file size or run-time performance"
([`stb_image_write.h`][stbw-about]). `stb_image_resize2.h` is a separable resampler with
SIMD kernels and a split API for threading; at the pinned revision it lives under
`deprecated/`, with a notice that newer versions moved to the separate
`nothings/stb_image_resize` repository ([`deprecated/stb_image_resize2.h`][stbir-deprecated]).

## How it works

### The single-header model

The file is both header and implementation. Every translation unit sees the
declarations; exactly one defines `STB_IMAGE_IMPLEMENTATION` before the include and
gets the code ([`stb_image.h`][stb-quicknotes]). Everything else is configured by the
preprocessor in that one unit: `STBI_MALLOC`/`STBI_REALLOC`/`STBI_FREE` (all or none,
with `STBI_REALLOC_SIZED` accepted instead of `STBI_REALLOC`, enforced by `#error`
([allocation macros][stb-alloc-config])), `STBI_ASSERT`, `STBI_NO_<FORMAT>` or `STBI_ONLY_<FORMAT>` to trim
decoders, `STBI_NO_SIMD`, `STBI_NEON`, `STBI_NO_STDIO`, `STBI_NO_THREAD_LOCALS` and
`STBI_MAX_DIMENSIONS` ([`stb_image.h`][stb-config]). raylib is a typical consumer: it
redirects allocation to `RL_MALLOC`, disables thread-locals and trims formats by its own
`SUPPORT_FILEFORMAT_*` switches ([raylib `rtextures.c`][ray-stbi-config]).

### `stbi_load` and its family

The main loading API combines source (filename, `FILE*`, memory, callbacks) with
sample type (8-bit `stbi_load*`, 16-bit `stbi_load_16*`, float `stbi_loadf*`)
([`stb_image.h`][stb-api]):

```c
// stb_image.h, the 8-bit memory and callback entry points
STBIDEF stbi_uc *stbi_load_from_memory   (stbi_uc           const *buffer, int len   , int *x, int *y, int *channels_in_file, int desired_channels);
STBIDEF stbi_uc *stbi_load_from_callbacks(stbi_io_callbacks const *clbk  , void *user, int *x, int *y, int *channels_in_file, int desired_channels);
```

The 8-bit loaders return `NULL` on failure, with a static string behind
`stbi_failure_reason()` ("an extremely brief, end-user unfriendly explanation"),
and otherwise a buffer the caller frees with `stbi_image_free`, "N interleaved 8-bit
components" per pixel and "no padding between image scanlines or between pixels"
([`stb_image.h`][stb-doc-usage]).
`stbi_info*` and `stbi_is_16_bit*` read only the header.

Dispatch is format sniffing in a fixed order: formats with a distinctive signature
first (PNG, BMP, GIF, PSD, PIC), then those that match on one or two bytes (JPEG, PNM),
then HDR, and TGA last "because it's a crappy test!" ([`stbi__load_main`][stb-loadmain]).
Each loader returns its native depth in a `stbi__result_info`; the post-processing step
narrows 16 to 8 bits (or widens 8 to 16) and applies the vertical-flip flag
([`stbi__load_and_postprocess_8bit`][stb-postprocess]).

### The callback I/O interface

`stbi_io_callbacks` is three function pointers: `read` (fill a buffer, return bytes
read), `skip` (advance, or "unget" with a negative count) and `eof`
([`stb_image.h`][stb-callbacks]). The `FILE*` entry points are themselves implemented as
these callbacks over `fread`/`fseek`/`feof` ([`stbi__context`][stb-context]). Callback
data passes through a 128-byte buffer inside `stbi__context`
([`stb_image.h`][stb-doc-io]); `stbi__get8` refills it on demand and, at the end of the
stream, points it at a single zero byte so later reads see zeros instead of failing
([`stbi__refill_buffer`][stb-refill]). Format sniffing relies on rewinding to the start
of that first buffer, which works only because "'test' ... only ever looks at at most 92
bytes" ([`stbi__rewind`][stb-context]).

The interface is a pull model: the decoder calls `read` until it has what it wants and
blocks the caller for the whole decode. There is no way to suspend mid-image and resume
when more bytes arrive. PNG makes this explicit: it accumulates every `IDAT` in one
growing buffer, then inflates the whole stream into one more
([PNG `IDAT`/`IEND`][stb-png-idat]), as its own header comment admits: "allocates lots of
intermediate memory" ([PNG decoder notes][stb-png-notes]).

### Desired channels

`desired_channels` (0 to 4, named by `STBI_grey` … `STBI_rgb_alpha`) asks for a fixed
component count; `*channels_in_file` still reports what the file had, so a caller asking
for RGBA can see that the source was opaque RGB ([`stb_image.h`][stb-doc-usage]). The
generic fallback is `stbi__convert_format`, with a switch per scanline over
`STBI__COMBO(img_n, req_comp)` and a fixed body per pair
([`stbi__convert_format`][stb-convert]):

```c
// stb_image.h, stbi__convert_format: two of the twelve cases, and the luma weights
STBI__CASE(1,4) { dest[0]=dest[1]=dest[2]=src[0]; dest[3]=255;                     } break;
STBI__CASE(3,1) { dest[0]=stbi__compute_y(src[0],src[1],src[2]);                   } break;
// stbi__compute_y:  (((r*77) + (g*150) +  (29*b)) >> 8)
```

Colour to grey is a fixed-point BT.601-style weighting of the encoded (non-linear)
values; alpha is added as 255 and dropped silently. **Verified:** one RGB pixel
(200, 100, 50) requested with `desired_channels = 1` returns 124 with
`channels_in_file = 3`, and requested as RGBA returns (200, 100, 50, 255).

### `stb_image_write` and `stb_image_resize2`

The writer mirrors the loader: `stbi_write_<fmt>(filename, …)` and
`stbi_write_<fmt>_to_func(func, context, …)` with `stbi_write_func` as a single
`(context, data, size)` sink, plus global knobs `stbi_write_png_compression_level`,
`stbi_write_force_png_filter` and `stbi_write_tga_with_rle`
([`stb_image_write.h`][stbw-usage]). Only PNG takes a row stride, which lets it write
"sub-rectangles of a larger image" ([`stb_image_write.h`][stbw-stride]). The PNG "to func"
path is not streaming: it builds the whole file with `stbi_write_png_to_mem` and calls
the sink once ([`stbi_write_png_to_func`][stbw-png-func]). A user zlib can replace the
built-in deflate through `STBIW_ZLIB_COMPRESS`, since the built-in one is documented as
"20-50% larger" than an optimizing encoder ([`stb_image_write.h`][stbw-about]).

`stb_image_resize2.h` offers three API levels. The easy API downsamples with a Mitchell
filter, upsamples with cubic interpolation and clamps to the edge ([`stb_image_resize2.h`][stbir-head]).
Pixel layouts encode the alpha convention: `STBIR_RGBA` is straight alpha that the
resizer weights before filtering and divides back after, `STBIR_RGBA_PM` is premultiplied
and filtered directly, and `STBIR_4CHANNEL` is "no channel that represents transparency"
([alpha layouts][stbir-alpha]). It commits to determinism "from x64 to ARM to scalar to
SIMD" with fast-math and floating-point contraction off; 32-bit x86 needs SSE/SSE2,
NaNs are excluded, and FMA builds need not match non-FMA builds
([determinism][stbir-determinism]). It supports threads by building
samplers once and then calling `stbir_resize_extended_split` per output slice on each
thread ([split API][stbir-split]).

## Analysis

### 1. Pixel and memory model

One model only: a packed, interleaved, top-left-first, row-major buffer of 1 to 4
channels, 8-bit, 16-bit or float, with no stride and no padding
([`stb_image.h`][stb-doc-usage]). There is no image type; the tuple `(pointer, x, y,
n)` is the image. Animated GIF frames come back as one buffer of `z` stacked frames
([`stbi_load_gif_from_memory`][stb-gif-mem]). Compared with the [stride][c-stride] and
[view][c-view] model of the other subjects, stb_image is the degenerate case: everything
a [Go `image.RGBA`][go-image] carries in `Stride` and `Rect` is implicit here. The writer
and resizer do accept strides, so the asymmetry is between reading and writing.

### 2. Genericity mechanism

Not applicable to generic image algorithms: these are C functions over pointers,
dimensions, channel counts and layout enums. Preprocessor switches configure the
implementation at compile time ([configuration][stb-config]; [resizer API][stbir-head]).

### 3. Colour and metadata

Colour metadata is discarded. PNG ancillary chunks (`gAMA`, `cHRM`, `sRGB`, `iCCP`, `eXIf`,
`cICP`) fall through the `default:` case and are skipped
([PNG chunk loop][stb-png-default]); JPEG ICC and EXIF segments are not exposed. Samples
are returned as encoded. The only transfer-function handling is the LDR-HDR bridge: an
HDR file loaded through the 8-bit API is tone-mapped with configurable defaults of gamma
2.2 and scale 1, and LDR loaded as float uses separately configurable gamma and scale
([HDR support][stb-doc-hdr]),
which is a gamma approximation, not the sRGB curve (see
[transfer function][c-transfer]). 16-bit to 8-bit keeps the high byte, "sufficient
approx of 16->8 bit scaling" ([`stbi__convert_16_to_8`][stb-16to8]). **Verified:** a
16-bit grey sample `0x80FF` loads through `stbi_load` as `0x80`; `0x00FF` loads as
`0x00`, whereas rounding full-range scaling (`sample * 255 / 65535`) gives `0x01`.
Alpha is straight except for Apple's `CgBI` PNGs, which are premultiplied
BGR and converted only on request ([`stb_image.h`][stb-doc-iphone]). Compare
[color][color] for a full model.

### 4. I/O and codec architecture

A closed set of decoders behind one function, picked by sniffing, with a pull-callback
source and whole-image output. It is the opposite end of the spectrum from the
[push and pull][c-pushpull] and [suspendable][c-incremental] designs:
no streaming, no row callback, no progressive display, no region decode, no
cancellation, and the 92-byte rewind restriction ties sniffing to a buffered prefix.
The format list is frozen by policy ([`README.md`][stb-readme-formats]). Where
[image-rs][image-rs] and [zune-image][zune-image] give each format a decoder object with
options and limits, stb_image's options are preprocessor macros and process-wide globals
(`stbi_set_flip_vertically_on_load`, the HDR gamma setters), with `_thread` variants added
for some flags when the compiler has thread-locals
([flip globals][stb-flip-globals]).

### 5. Hostile input and safety

What stb_image does:

- **Checked size arithmetic.** `stbi__mad2sizes_valid` … `stbi__mad4sizes_valid` and
  `stbi__malloc_mad*` refuse any product or sum that overflows `int`; the API is `int`
  throughout, so decoded images are capped at "either just under 2GB or just under 1GB"
  ([size helpers][stb-mad]; [limits][stb-doc-limits]).
- **Dimension limit.** Every loader rejects a width or height over `STBI_MAX_DIMENSIONS`,
  default `1 << 24`, "to prevent denial-of-service attacks on untrusted data"
  ([`STBI_MAX_DIMENSIONS`][stb-doc-maxdim]; PNG [`IHDR`][stb-png-ihdr]). PNG adds a
  header limit of `width * height * channels <= 2^30` (four channels for paletted
  images), independent of bit depth, and refuses an `IDAT` chunk over `2^30` bytes
  ([`IDAT`][stb-png-idat]).
  **Verified:** a PNG declaring width `2^24 + 1` fails with "too large"; one declaring
  20000 × 20000 RGB (inside the dimension limit, outside the `2^30` sample budget) also fails
  with "too large"; 16384 × 16384 RGB passes the header checks and fails only at
  "not enough pixels".
- **No integrity checks.** PNG chunk CRCs are read and skipped; the code says so
  ("no CRC checking", [PNG decoder notes][stb-png-notes]). **Verified:** a PNG whose
  `IHDR` and `IEND` CRCs are both corrupted decodes.
- **Fuzzing.** `tests/stbi_read_fuzzer.c` is the OSS-Fuzz harness; it calls `stbi_info`
  first and skips images over roughly 80 MB ([fuzzer][stb-fuzzer]), and
  `tests/ossfuzz.sh` builds a PNG-only and an all-formats target with PngSuite and
  JPEG/GIF/BMP/TGA seed corpora ([OSS-Fuzz script][stb-ossfuzz]). This harness does
  not exercise the animated-GIF entry point or enable vertical flipping.

CVE history. GitHub Security Lab's 2023 advisory reports "several memory access
violations of different severity" in `stb_image.h` (and separately in `stb_vorbis`): a
wild read in `stbi__gif_load_next` (CVE-2023-45661), a heap over-read in
`stbi__vertical_flip` (CVE-2023-45662), uninitialized memory disclosure in the TGA and
HDR loaders (CVE-2023-45663), a double-free on the GIF out-of-memory path
(CVE-2023-45664), a `NULL` dereference in `stbi__convert_format` (GHSL-2023-149), a
possible double-free or leak when `*delays` is not reset (CVE-2023-45666), and a `NULL`
dereference in `stbi_load_gif_from_memory` (CVE-2023-45667). The researchers reported
privately in July 2023, received no reply to three follow-ups, and published with
public pull requests in October ([GHSL-2023-145 to 151][ghsl]). The in-header changelog
records 2.28 (January 2023) as "many error fixes, security errors"
([revision history][stb-history]); 2.30 (May 2024) is the latest version line.

The presence of `*delays = 0` does not establish that GHSL-2023-150 was fixed:
the advisory already shows it, and at the pinned revision it still runs only after
GIF recognition; the out-of-memory helper frees `*delays` without resetting it
([GIF main and cleanup][stb-gif-main]). Two other reported failure shapes reproduce:

- `stbi_load_gif_from_memory` flips the result unconditionally, so a decode failure
  passes `NULL` to `stbi__vertical_flip_slices` ([`stbi_load_gif_from_memory`][stb-gif-mem]).
  **Verified:** with flipping on and outputs initialized to `x = 1`, `y = 2`, `z = 1`,
  `comp = 4`, non-GIF bytes crash with a `SEGV` reading address 0.
- The same flip uses `*comp` (always 4 for GIF) as the bytes per pixel, not
  `req_comp`. **Verified:** a hand-built 1 × 2 GIF loaded with `req_comp = 1` and
  flipping on is an AddressSanitizer heap-buffer-overflow (4-byte read) in
  `stbi__vertical_flip`.

The project's own stance is consistent with this: the header aims the library at
people "who can avoid problematic images", and `SECURITY.md` tells projects for which
slow public fixes are an unreasonable risk not to use it. See [hostile input][c-hostile]
and the [hostile-input papers][p-hostile].

### 6. Allocation and ownership

The library allocates the output and the caller owns it; there is no caller-provided
destination for image decoding (the separate zlib buffer APIs accept a destination).
Allocation is replaceable only at compile time and globally. Conversions that
allocate a new buffer before freeing the old, such as 16-to-8 and the generic channel
converter, hold both images at their peak. Setting `desired_channels` alone does not
imply this: JPEG converts internally, PNG can add alpha directly, and equal channel
counts return the original buffer ([`stbi__convert_format`][stb-convert];
[16-to-8][stb-16to8]). `stb_image_resize2` documents one internal allocation per resize,
reusable with the extended API; sanitizer builds split allocations, and the easy API
can also allocate the output
([`stb_image_resize2.h`][stbir-head]).

### 7. CPU parallelism and SIMD

stb_image vectorizes only JPEG (IDCT, colour conversion, upsampling). On GCC and Clang it
uses SSE2 when the target enables it (normally already true on x86-64), without
runtime CPU detection, because "the
way architecture extensions are exposed in GCC/Clang is, sadly, not really suited for
one-file libs" ([SIMD selection][stb-simd]); NEON needs `STBI_NEON`
([`stb_image.h`][stb-doc-simd]). Decoding is single-threaded; the failure-reason
string is thread-local where the compiler allows. `stb_image_resize2` carries SSE2, AVX,
NEON and WASM kernels and an explicit split API for threads, left to the caller to
schedule ([split API][stbir-split]).

### 8. GPU offload and interop

Not applicable: the cited loading and resizing APIs operate on CPU memory and expose
no GPU resource or upload interface ([loader API][stb-api]; [resizer API][stbir-head]).

### 9. Temporal, animation and containers

The ordinary GIF loader returns the first frame; `stbi_load_gif_from_memory` collects
frames in one buffer and optionally allocates per-frame delays, with a final requested
channel conversion. This is whole-animation loading, not a frame iterator
([GIF implementation][stb-gif-animation]). The writer exposes no animation API
([writer API][stbw-usage]).

### 10. Testing and conformance

The repository vendors PngSuite and a regression test that writes width, height,
component count, error and an FNV-1a hash of the pixels for every file to
`tests/pngsuite/ref_results.csv`, to be diffed after loader changes
([`test_png_regress.c`][stb-regress]). OSS-Fuzz supplies crash-oriented coverage,
not a conformance oracle ([fuzzer][stb-fuzzer]).

## Lessons for Sparkles

- **Q8.** stb_image is already Sparkles' PNG oracle:
  [`png_oracle.d`][sp-png-oracle] decodes PngSuite and libpng's `contrib/testpngs`
  through raylib's `LoadImageFromMemory` and compares with `sparkles.image.png` byte for
  byte, and the D codec's module comment says it "decodes as stb_image does … chunk
  checksums are not checked … 16-bit samples keep their high byte"
  ([`png.d`][sp-png]). Both behaviours were reproduced here, so the oracle is
  consistent with its documentation. The cited raylib clone is an integration example;
  Sparkles links Nix's raylib, whose vendored stb revision was not established here.
  Two further caveats: the cited raylib loads
  with `desired_channels = 0` ([raylib `rtextures.c`][ray-stbi-load]), and the oracle
  converts to RGBA with raylib's `ImageFormat` ([`png_oracle.d`][sp-png-oracle]).
  It tests stb_image's decode plus raylib's expansion rather than requesting RGBA
  through `stbi__convert_format`; and parity with stb_image inherits its
  lossy 16-to-8 narrowing and its absent CRC check, which is a statement of
  compatibility, not of correctness. A second oracle (libpng or Wuffs) would separate
  the two.
- **Q8.** The GIF findings above show that stb_image is unsafe as an oracle on corrupt or
  fuzzed input: a differential fuzzer that feeds the same bytes to both decoders must
  isolate the C side in a separate process; a sanitizer helps detect the failure but
  does not contain it. Callers must avoid
  `stbi_load_gif_from_memory` with flipping on.
- **Q4.** The callback interface is the minimal pull source (`read`, `skip`, `eof`) and
  the clearest counter-example for suspendable decoding: a decoder that owns the call
  stack cannot yield to an event loop, and PNG buffering every `IDAT` before inflating
  requires overlapping compressed and inflated buffers, followed by inflated and pixel
  buffers. An `event-horizon` integration would need synchronous callbacks, prior
  buffering, or a blocking worker; the callback API can start before the whole file arrives.
- **Q4, Q9.** The single-header model trades link-time configuration for build
  simplicity. dub and Nix already solve distribution, so the transferable part is the
  narrow surface (one function per source per sample type, `info` without decode), not
  the macro configuration or the process-wide globals.
- **Q1.** A packed `(pointer, x, y, n)` result is what a GPU upload or a terminal image
  protocol wants directly, but the absence of stride on the read side forces a copy for
  decoding into a sub-rectangle or padded destination. The writer and resizer already take strides, which
  suggests a design where stride is present but zero means packed, as
  `stb_image_resize2` does.
- **Q5.** stb_image's colour model is the one a Sparkles image type must not stop at:
  ancillary colour chunks are dropped, HDR/LDR gamma defaults to 2.2, and grey conversion
  weights encoded values. It is a baseline for decoded samples without colour
  management; an oracle comparison must specify the output representation.
- **Q5, Q3.** `stb_image_resize2`'s layout enum shows a compact way to carry the alpha
  convention into an algorithm (straight, premultiplied, not-alpha) and documents the
  cost asymmetry between them. Its determinism commitment across scalar and SIMD is a
  property a Sparkles resampler could test directly.
- **Q8.** `ref_results.csv` (dimensions, error string and pixel hash per corpus file) is
  a cheap regression artefact that complements byte-exact comparison: it records
  per-file refusal reasons as well as decodes. The Sparkles oracle counts mutual
  refusals and reports one-sided refusals, but does not persist those reasons.
- **Q5.** `STBI_MAX_DIMENSIONS` plus an `int`-sized budget is a coarse limit set at
  compile time. The D codec's `maxPngPixels` (`2^26`) is already tighter
  ([`png.d`][sp-png]); the lesson is the per-call limits that stb lacks, not the global.

## Strengths

- Trivial integration: one file, one define, no dependencies, dual MIT/public-domain
  licence.
- A small, uniform API across formats and sample types, with header-only `info` queries.
- Checked size arithmetic and a dimension limit on every loader.
- Broad real-world exposure and OSS-Fuzz coverage; behaviour matches what many tools
  (raylib among them) actually ship.
- `stb_image_resize2` is careful about alpha conventions, sRGB and determinism, and
  exposes threading without owning threads.

## Weaknesses

- Not designed for hostile input; security bugs are discussed in public and fixes can
  be slow, by the project's own statement. Two GIF memory errors reproduce at the pinned
  revision.
- Whole-image, blocking pull decoding; no suspension, regions or cancellation;
  PNG buffers all compressed `IDAT` before inflation and retains the inflated image
  while reconstructing pixels ([PNG implementation][stb-png-idat]).
- No colour management or metadata; lossy 16-to-8 narrowing; no CRC checks.
- Configuration by macros and process-wide globals; `int` sizes cap images below 2 GB.
- SIMD only for JPEG; on GCC/Clang it requires an SSE2-enabled target or explicit NEON
  configuration, with no runtime SSE2 fallback.
- The writer's PNG output is documented as 20 to 50 percent larger than an optimizing
  encoder's, and its callback path buffers the whole file.

## Key design decisions and trade-offs

| Decision                     | Rationale                                                                | Trade-off                                       |
| ---------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------- |
| Single-header implementation | Ease of integration ([FAQ][stb-readme-why])                              | Compile-time configuration is shared by callers |
| Packed whole-image output    | Trivial loading interface ([usage][stb-doc-usage])                       | No destination stride or suspension             |
| Fixed decoder set            | Limit code needing security review ([format policy][stb-readme-formats]) | Additional formats need another library         |

## Sources

- nothings/stb at `003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5`: [`stb_image.h`][stb-quicknotes],
  [`stb_image_write.h`][stbw-about], [`deprecated/stb_image_resize2.h`][stbir-head],
  [`README.md`][stb-readme-faq], [`SECURITY.md`][stb-security], [`LICENSE`][stb-license],
  [`tests/stbi_read_fuzzer.c`][stb-fuzzer], [`tests/ossfuzz.sh`][stb-ossfuzz],
  [`tests/test_png_regress.c`][stb-regress], [`docs/stb_howto.txt`][stb-howto].
- raysan5/raylib at `dbc56a87da87d973a9c5baa4e7438a9d20121d28`:
  [`src/rtextures.c`][ray-stbi-config], [`src/external/stb_image.h`][ray-stbi-vendored].
- GitHub Security Lab, [GHSL-2023-145 to GHSL-2023-151][ghsl] (stb_image.h and
  stb_vorbis advisory).
- Sparkles: [`png_oracle.d`][sp-png-oracle], [`png.d`][sp-png],
  [existing image code baseline][bl-existing].
- Catalog: [umbrella][umbrella], [concepts][concepts].

<!-- References -->

[stb-repo]: https://github.com/nothings/stb/tree/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5
[stb-license]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/LICENSE
[stb-quicknotes]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L1-L41
[stb-history]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L48-L55
[stb-doc-usage]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L132-L191
[stb-doc-limits]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L193-L209
[stb-philosophy]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L223-L242
[stb-doc-io]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L246-L255
[stb-doc-simd]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L258-L275
[stb-doc-hdr]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L279-L312
[stb-doc-iphone]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L314-L326
[stb-config]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L328-L368
[stb-alloc-config]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L673-L689
[stb-doc-maxdim]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L361-L368
[stb-callbacks]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L411-L416
[stb-api]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L419-L475
[stb-flip-globals]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L1114-L1135
[stb-simd]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L691-L776
[stb-context]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L799-L893
[stb-mad]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L990-L1067
[stb-loadmain]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L1137-L1188
[stb-16to8]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L1190-L1204
[stb-postprocess]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L1260-L1283
[stb-gif-mem]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L1444-L1456
[stb-refill]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L1597-L1623
[stb-convert]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L1736-L1798
[stb-png-notes]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L4596-L4604
[stb-png-ihdr]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L5102-L5128
[stb-png-idat]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L5173-L5239
[stb-png-default]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L5241-L5261
[stb-gif-main]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L6952-L6982
[stb-gif-animation]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image.h#L6963-L7070
[stb-readme-faq]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/README.md#L1-L23
[stb-readme-why]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/README.md#L128-L150
[stb-readme-formats]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/README.md#L157-L162
[stb-security]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/SECURITY.md
[stb-fuzzer]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/tests/stbi_read_fuzzer.c
[stb-ossfuzz]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/tests/ossfuzz.sh
[stb-regress]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/tests/test_png_regress.c#L17-L75
[stb-howto]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/docs/stb_howto.txt
[stbw-about]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image_write.h#L1-L33
[stbw-usage]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image_write.h#L43-L75
[stbw-stride]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image_write.h#L77-L101
[stbw-png-func]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/stb_image_write.h#L1231-L1239
[stbir-deprecated]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/deprecated/stb_image_resize2.h#L1-L7
[stbir-head]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/deprecated/stb_image_resize2.h#L108-L160
[stbir-alpha]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/deprecated/stb_image_resize2.h#L246-L267
[stbir-determinism]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/deprecated/stb_image_resize2.h#L298-L318
[stbir-split]: https://github.com/nothings/stb/blob/003501f6d7a8668ce8b6d875e34dd97ad0d5d5b5/deprecated/stb_image_resize2.h#L770-L796
[ray-stbi-config]: https://github.com/raysan5/raylib/blob/dbc56a87da87d973a9c5baa4e7438a9d20121d28/src/rtextures.c#L73-L146
[ray-stbi-load]: https://github.com/raysan5/raylib/blob/dbc56a87da87d973a9c5baa4e7438a9d20121d28/src/rtextures.c#L456-L474
[ray-stbi-vendored]: https://github.com/raysan5/raylib/blob/dbc56a87da87d973a9c5baa4e7438a9d20121d28/src/external/stb_image.h#L1
[ghsl]: https://securitylab.github.com/advisories/GHSL-2023-145_GHSL-2023-151_stb_image_h/
[sp-png-oracle]: ../../../libs/ui-raylib/src/sparkles/ui_raylib/png_oracle.d
[sp-png]: ../../../libs/image/src/sparkles/image/png.d
[bl-existing]: ./baseline/existing-code.md
[umbrella]: ./index.md
[concepts]: ./concepts.md
[c-stride]: ./concepts.md#stride
[c-view]: ./concepts.md#image-and-view
[c-transfer]: ./concepts.md#transfer-function
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[c-incremental]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[c-hostile]: ./concepts.md#hostile-input
[p-hostile]: ./papers/hostile-input-safety.md
[color]: ./color.md
[go-image]: ./go-image.md
[image-rs]: ./image-rs.md
[zune-image]: ./zune-image.md
