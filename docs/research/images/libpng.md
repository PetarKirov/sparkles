# libpng (C)

The reference PNG implementation: a row-oriented C library with a pull reader, a push
reader, a fixed pipeline of in-place row transformations and `setjmp`/`longjmp` error
handling. Its test suite and security fixes provide evidence for the design of a PNG
decoder and its oracle tests.

| Field         | Value                                                                                                                                                                                                                         |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C (C89 style, ISO C90 headers; optional `setjmp`); depends on zlib                                                                                                                                                            |
| License       | libpng license (PNG Reference Library License version 2; zlib-style permissive); `ci/**` under MIT, `.github/workflows/**` under MIT-0 (`REUSE.toml`)                                                                         |
| Repository    | [glennrp/libpng][repo] (now [pnggroup/libpng][repo-pnggroup]; the old URL redirects)                                                                                                                                          |
| Revision read | `890812a28da480f84f3b0198d31ac611c864ed98` (October 26, 2026, branch `libpng18`, version `1.8.0.git`); comparisons against `libpng16` at `e88e1735a26788df76a570c59d1183c883e71401` (November 11, 2026, version `1.6.60.git`) |
| Documentation | [`libpng-manual.txt`][manual] · [`png.h`][png-h] (the API reference in comments) · [libpng home page][home] · [PNG Third Edition (W3C)][png3]                                                                                 |
| Category      | Formats: still-image codec (PNG and, on the 1.8 line, APNG)                                                                                                                                                                   |
| Tier          | A                                                                                                                                                                                                                             |
| Last reviewed | November 15, 2026                                                                                                                                                                                                             |

> [!IMPORTANT]
> **Two lines, one name.** The default branch, `libpng18`, is the development line
> ("a development version, not intended to be a public release", [`ANNOUNCE.md`][announce]).
> The shipping line is 1.6, maintained on `libpng16`, which is also the repository's
> `master` (both resolve to `e88e1735a` on November 14 and 15, 2026). This page reads 1.8 and
> marks every statement that differs on 1.6; unmarked statements were checked to hold
> on both. The clone of 1.8 is shallow, so history claims come from [`CHANGES`][changes].

> [!NOTE]
> **What was run.** Both lines were built from `git archive` exports under `/tmp`
> (CMake, GCC, zlib from nixpkgs, x86_64 Linux). The 1.8 test suite (`ctest`, 38 tests)
> passed. Two scratch programs, outside this repository, crafted PNGs in memory and
> decoded them with both lines, counting allocations through `png_create_read_struct_2`;
> their results are marked **verified** below. A verifier rebuilt both pinned revisions
> on November 15, 2026 with GCC 16.2.0 and zlib 1.3.2, reran both programs and the 38
> CMake tests, and corrected the 1.6 allocation counts. The probes' empty-chunk CRC
> calculation was also corrected before rerunning. A second verifier rebuilt both
> revisions with GCC 14.3.0 and zlib 1.3.2, reran the 38 CMake tests, and wrote its
> own probe; every figure marked **verified** matched. Allocation counts exclude the
> probes' input buffers, allocator overhead and stack memory; no throughput was measured.

---

## Overview

### What it solves

libpng parses and writes the PNG datastream: chunk framing and CRCs, the zlib-compressed
`IDAT` stream, per-row filter reversal, Adam7 de-interlacing, and ancillary
chunks (colour, text, time, physical size, palettes, and since 1.6.45 the PNG Third
Edition chunks `cICP`, `mDCV` and `cLLI`). On top of decoding it offers an optional
pipeline of row transformations (palette expansion, bit-depth scaling, gamma
correction, alpha compositing, channel reordering) so that an application receives
rows in the layout it wants rather than the one the file has.

Three read interfaces sit over one core:

- the **sequential (pull) reader**, which calls a user `png_rw_ptr` for bytes and hands
  back rows on demand (`png_read_info`, `png_read_row`, `png_read_image`, `png_read_end`);
- the **progressive (push) reader**, which takes bytes as they arrive
  (`png_process_data`) and calls the application back with header info, rows and the end;
- the **simplified API** (`png_image`), added in 1.6, which decodes a whole image into one
  of a handful of in-memory formats in two calls and hides `setjmp`.

### Design philosophy

The library treats its own structures as private and the file as untrusted, and pays
for both with a large surface of configuration. Since 1.5 the structures are opaque;
[`pnginfo.h`][pnginfo] states the split between the two objects:

> png_info is a modifiable description of a PNG datastream. The fields inside
> this structure are accessed through `png_get_<CHUNK>()` functions and modified
> using `png_set_<CHUNK>()` functions.
>
> […] png_struct objects contain members which hold
> caches, sometimes optimised, of the values from png_info objects, and
> png_info is not passed to the functions which read and write image data.

Errors are non-local. The manual is explicit that the application owns the recovery
point ([`libpng-manual.txt`][manual-errors]):

> When libpng encounters an error, it expects to longjmp back to your routine.
> Therefore, you will need to call setjmp and pass your `png_jmpbuf(png_ptr)`. If you
> read the file from different routines, you will need to update the longjmp buffer
> every time you enter a new routine that will call a `png_*()` function.

Compatibility dominates. The CRC policy comment in [`pngrutil.c`][rutil-crc] says of its
own flag scheme: "This arose because of original mis-implementation and has persisted
for compatibility reasons." The APNG comment in the chunk table says APNG chunks are
routed to the unknown-chunk list so that applications that already handle APNG "not get
hosed" ([`pngrutil.c`][rutil-table]). Features are compiled in or out through a
configuration language (`pngusr.dfa`, [`pnglibconf.dfa`][dfa-limits]) that generates
`pnglibconf.h`, so "libpng" names a family of builds, and the `contrib/conftest/*.dfa`
files (`nolimits.dfa`, `noapng.dfa`, `read.dfa`, …) exist to keep the minimal ones
compiling.

## How it works

**Objects.** `png_create_read_struct` (or `_2`, which adds `png_malloc_ptr`/`png_free_ptr`
hooks) returns a `png_struct`; `png_create_info_struct` returns a `png_info` for the
chunks before `IDAT` and, optionally, a second one for the chunks after it. The
`png_struct` is first built on the stack in `png_create_png_struct` so that the user
allocator and error handler exist before the first allocation; that is also where the
limits are defaulted ([`png.c`][png-c-create]):

```c
#  ifdef PNG_USER_LIMITS_SUPPORTED
      create_struct.user_width_max = PNG_USER_WIDTH_MAX;
      create_struct.user_height_max = PNG_USER_HEIGHT_MAX;
#     ifdef PNG_USER_CHUNK_CACHE_MAX
      create_struct.user_chunk_cache_max = PNG_USER_CHUNK_CACHE_MAX;
#     endif
#     if PNG_USER_CHUNK_MALLOC_MAX > 0 /* default to compile-time limit */
      create_struct.user_chunk_malloc_max = PNG_USER_CHUNK_MALLOC_MAX;
```

**Chunk framing.** `png_read_chunk_header` reads eight bytes, rejects a length with the
top bit set, validates the four-letter type with a branch-free bit test
(`check_chunk_name`), and starts the CRC over the type ([`pngrutil.c`][rutil-header]).
Since 1.6.47 normal known-chunk dispatch uses one table, `read_chunks[]`, built from the
`PNG_KNOWN_CHUNKS` X-macro; each entry packs the handler with the chunk's length bounds,
ordering constraints and whether it may repeat ([`pngrutil.c`][rutil-table]; selected
rows):

```c
   /*       cHNK  max_len,   min, before, after, multiple */
#  define CDIHDR      13U,   13U,  hIHDR,     0,        0
#  define CDiCCP  NoCheck, LKMin,   hCOL, hIHDR,        0
#  define CDcICP       4U,    4U,   hCOL, hIHDR,        0
#  define CDmDCV      24U,   24U,   hCOL, hIHDR,        0
#  define CDeXIf    Limit,    4U,      0, hIHDR,        0
#  define CDzTXt    Limit, LKMin,      0, hIHDR,        1
```

`png_handle_chunk` checks position, duplicates and length against the entry before
calling the handler. A violation in a critical chunk is fatal; in an ancillary chunk
the data is skipped and a "benign" error is raised ([`pngrutil.c`][rutil-handle]).
On read, benign errors are warnings by default: `png_create_read_struct_2` sets
`PNG_FLAG_BENIGN_ERRORS_WARN` ([`pngread.c`][read-create]), and an application opts into
strictness with `png_set_benign_errors(png_ptr, 0)`.

**Inflate ownership.** One `z_stream` lives in `png_struct`. A chunk "claims" it with
`png_inflate_claim(png_ptr, owner)`, which records the chunk name in `zowner`
([`pngrutil.c`][rutil-claim]); compressed text and `iCCP` use it outside image-data
decompression. `png_decompress_chunk` inflates compressed text **twice**: once
with no output buffer to learn the size (bounded by `png_chunk_max`), then into an
exactly sized allocation, and it refuses the result if the second pass produces a
different length ([`pngrutil.c`][rutil-decompress]).

**Rows.** `png_read_start_row` runs `png_init_read_transformations`, computes the widest
pixel the selected transformations can produce (`max_pixel_depth`), and allocates two
row buffers for a width rounded up to eight pixels, plus a filter byte, an extra pixel
and 48 bytes of slack, aligned to 16 bytes past the filter
byte when a SIMD target asks for it ([`pngrutil.c`][rutil-startrow]). `png_read_row` then
inflates exactly `rowbytes + 1` bytes, reverses the filter in place through a
per-`png_struct` function table, keeps the result as `prev_row`, runs the
transformations, and copies or interlace-combines into the caller's row
([`pngread.c`][read-row]):

```c
   png_ptr->row_buf[0]=255; /* to force error if no data was found */
   png_read_IDAT_data(png_ptr, png_ptr->row_buf, row_info.rowbytes + 1);

   if (png_ptr->row_buf[0] > PNG_FILTER_VALUE_NONE)
   {
      if (png_ptr->row_buf[0] < PNG_FILTER_VALUE_LAST)
         png_read_filter_row(png_ptr, &row_info, png_ptr->row_buf + 1,
             png_ptr->prev_row + 1, png_ptr->row_buf[0]);
      else
         png_error(png_ptr, "bad adaptive filter value");
   }
```

After the transformations it checks that the first transformed row's pixel depth does
not exceed the maximum `png_read_start_row` allowed, and raises `"sequential row overflow"`
otherwise. Subsequent rows must match the first transformed row's depth. These checks
run after transformation, so they cannot prevent an overwrite inside a faulty transform.

**Transformations.** `png_set_expand`, `png_set_palette_to_rgb`, `png_set_tRNS_to_alpha`,
`png_set_strip_16`, `png_set_scale_16`, `png_set_gamma`, `png_set_alpha_mode`,
`png_set_background`, `png_set_rgb_to_gray`, `png_set_quantize`, `png_set_filler` and
others each set a bit in `png_ptr->transformations`. The order in which they run is
fixed by `png_do_read_transformations`, not by the order of the calls: expand, strip
alpha, RGB to grey, grey to RGB, compose, gamma, encode alpha, scale or chop 16 to 8,
quantize, expand 16, invert, … ([`pngrtran.c`][rtran-order]). Every step works in place
on `row_buf`, which is why the buffer is sized for the widest intermediate pixel.
`png_read_png` is the convenience entry that maps a `PNG_TRANSFORM_*` mask onto these
setters and reads the whole image into `row_pointers` ([`pngread.c`][read-png]).

**The push reader.** `png_process_data` restores the caller's buffer and loops over a
small state machine (`PNG_READ_SIG_MODE`, `PNG_READ_CHUNK_MODE`, `PNG_READ_IDAT_MODE`)
([`pngpread.c`][pread-process]). A metadata chunk is handled only once all of it and
its CRC are buffered; until then the bytes are appended to `save_buffer`
([`pngpread.c`][pread-modes]):

```c
#define PNG_PUSH_SAVE_BUFFER_IF_FULL \
if (png_ptr->push_length + 4 > png_ptr->buffer_size) \
   { png_push_save_buffer(png_ptr); return; }
```

`IDAT` bytes are fed straight to `inflate` with `Z_SYNC_FLUSH`, and each completed row
goes to the application's `png_progressive_row_ptr` with its row number and Adam7 pass.
The commit this page pins documents why the stream survives a chunk boundary
([`pngpread.c`][pread-idat-end]): "The next chunk may continue the zstream, with a
partial row still pending in 'next_out' and 'avail_out'."

**The simplified API.** `png_image_begin_read_from_memory` (or `_file`, `_stdio`) reads
the header into a `png_image`; the caller sets `format` and calls `png_image_finish_read`
with a buffer and a signed `row_stride` ([`png.h`][png-h-simplified]). Each stage runs
under `png_safe_execute`, which installs a local `jmp_buf` and turns a `png_error` into a
`0` return with the message copied into `image->message[64]` ([`pngerror.c`][error-safe]).

## Analysis

### 1. Pixel and memory model

The unit is the **row**. In the low-level row API, the
application supplies each destination row (`png_read_row(png_ptr, row, display_row)`) or
an array of row pointers (`png_read_image`), so the image may live
anywhere, with any [stride][c-stride], even non-contiguous. The decoder has two main
row buffers, `row_buf` and `prev_row`, each sized for the widest transformed pixel; their
first byte is the PNG filter type. Pixels are interleaved, 1 to 4 channels, 1 to 16 bits
per sample, packed below 8 bits; the PNG model has no planes, tiles or N-D extents.
The convenience `png_read_png` instead allocates the row-pointer array and all rows
itself ([`pngread.c`][read-png]).

The simplified API is the one place libpng describes a whole buffer: `format` flags
(`PNG_FORMAT_FLAG_ALPHA`, `_COLOR`, `_LINEAR`, `_COLORMAP`, `_BGR`, `_AFIRST`, and
`PNG_FORMAT_FLAG_ASSOCIATED_ALPHA` at `0x40`) plus a signed 32-bit `row_stride`, where a
negative stride stores the image bottom-up ([`pngread.c`][read-control] keeps a
`ptrdiff_t row_step`). `png_image_finish_read` caps the buffer at 32-bit byte counts,
because the public `PNG_IMAGE_BUFFER_SIZE` macro is 32-bit; its comment promises a
`png_alloc_size_t` version "in 1.7", which neither 1.6 nor 1.8 has delivered
([`pngread.c`][read-finish]).

### 2. Genericity mechanism

There is none at the type level. Pixel formats are run-time integers (`color_type`,
`bit_depth`, `pixel_depth`) carried in `png_row_info`; flags select specialised
transformation routines. Variation is achieved three other ways:

- **Build-time feature selection.** `pnglibconf.dfa` options (`READ_EXPAND`,
  `READ_GAMMA`, `USER_LIMITS`, `APNG`, …) compile code in or out. Per-feature guards
  such as `#ifdef PNG_READ_cICP_SUPPORTED` wrap handlers; disabled entries fall back to
  `NULL` ([`pngrutil.c`][rutil-cicp]).
- **Run-time function tables.** `read_filter[4]` is filled per image by
  `png_init_filter_functions` and then overwritten by a SIMD target
  ([`pngrutil.c`][rutil-filters]); the chunk table is an array of handler pointers.
- **User hooks.** `png_set_read_fn`, `png_set_mem_fn`, `png_set_error_fn`,
  `png_set_read_user_chunk_fn` and `png_set_read_user_transform_fn` (a callback given
  `png_row_info` and the row) are the extension points.

Design by introspection has no analogue; the closest thing is the `PNG_*_SUPPORTED`
macros an application tests at compile time.

### 3. Colour and metadata

libpng stores colour chunks faithfully and applies almost none of them.

| Chunk  | Stored as                                   | Used by the read transforms                                          |
| ------ | ------------------------------------------- | -------------------------------------------------------------------- |
| `gAMA` | fixed point, `png_set_gAMA_fixed`           | yes: lowest precedence source of `chunk_gamma`                       |
| `sRGB` | rendering intent                            | yes: sets `chunk_gamma` to the sRGB inverse unless `cICP` set it     |
| `cHRM` | `png_xy` / XYZ                              | only as RGB-to-grey coefficients                                     |
| `iCCP` | name plus raw profile bytes                 | no: "iCCP is not supported by libpng" (comment in `png_handle_sRGB`) |
| `cICP` | four bytes (primaries, transfer, matrix, …) | no: "TODO: set png_struct::chunk_gamma when possible"                |
| `mDCV` | chromaticities and luminances (fixed point) | chromaticities only, for RGB-to-grey                                 |
| `cLLI` | MaxCLL and MaxFALL                          | no                                                                   |
| `eXIf` | raw bytes                                   | no; only the first four bytes are checked against `II*\0` / `MM\0*`  |
| XMP    | an `iTXt` chunk                             | no; the source never mentions XMP, so it is ordinary text to libpng  |

The intended chunk gamma precedence is `cICP`, then `iCCP`, then `sRGB`, then `gAMA`,
but the first two never set a value ([`pngrutil.c`][rutil-cicp], [`sRGB`][rutil-srgb],
[`gAMA`][rutil-gama]). An explicit application gamma overrides chunk gamma
([`png_resolve_file_gamma`][rtran-gamma]). Gamma is
a pure power law in fixed point (`png_fixed_point`, scale 100000); [`TODO.md`][todo] still
lists "Complete sRGB transformation. (Currently it simply uses gamma=0.45455.)", while
the simplified API alone uses the real sRGB curve (its comment in [`png.h`][png-h-alpha]).
No HDR transfer function (PQ, HLG), no [gain map][c-gainmap], no tone mapping and no
ICC-based gamut conversion exist; `mDCV` and `cLLI` are carried for the application, and
the `mDCV` handler documents that its coordinates are scaled by 50000 in two bytes while
`cHRM` uses 100000 in four ([`pngrutil.c`][rutil-mdcv]).

Alpha is [straight][c-alpha] in the core API (PNG stores straight alpha).
`png_set_alpha_mode` can request premultiplied output with a chosen output gamma; the
simplified API returns straight 8-bit sRGB but **associated (premultiplied) linear**
16-bit, per [`png.h`][png-h-alpha]: "When an alpha channel is present it is expected to
denote pixel coverage of the color or luminance channels and is returned as an
associated alpha channel".

The `iCCP` handler is the instructive part for a reimplementation: it inflates the
profile in three steps, the 132-byte header first, then the tag table, then the rest,
validating length and header (`png_icc_check_length`, `png_icc_check_header`) before
allocating the full profile. It then reads and validates the tag table
(`png_icc_check_tag_table`) before inflating the remaining body into that allocation
([`pngrutil.c`][rutil-iccp]). It validates structure; it does not apply the profile.

### 4. I/O and codec architecture

Against [the push and pull taxonomy][c-pushpull]:

| Property                                     | libpng                                                                                                                                                   |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pull                                         | yes: `png_set_read_fn` callback; the callback must deliver every byte asked for or `png_error`                                                           |
| Push                                         | yes: `png_process_data(png_ptr, info_ptr, buffer, size)` with info, row and end callbacks ([`png.h`][png-h-push])                                        |
| [Incremental and suspendable][c-incremental] | push only: the state machine returns whenever input runs out; `png_process_data_pause` stops from inside a callback and reports unconsumed bytes         |
| Progressive display                          | Adam7 only: rows arrive per pass; `png_progressive_combine_row` and the `display_row` argument of `png_read_row` replicate pixels for a "chunky" preview |
| Row callback                                 | yes (push `png_progressive_row_ptr`; pull `png_set_read_status_fn`)                                                                                      |
| Tile or region decode                        | no: rows are decoded in order and the zlib stream cannot be entered mid-way; an application may stop after the first N rows of a non-interlaced image    |
| Downscaled decode                            | no; the first Adam7 pass is a 1/8 by 1/8 subsample only if the file is interlaced                                                                        |
| Cancellation                                 | `png_error` from a callback (a `longjmp`), or `png_process_data_pause`                                                                                   |

`png_process_data_skip` is declared but its body only warns that it "is not implemented in
any current version of libpng" ([`pngpread.c`][pread-process]).

The two readers are separate code paths over shared chunk handlers, and they **do not
accept the same inputs**. A verified example: a 64 by 64 image whose stored deflate
block has one corrupted byte (chunk CRC valid, Adler-32 wrong) fails in the sequential
reader with `IDAT: incorrect data check`, while the push reader treats a
`Z_DATA_ERROR` before the last row as the benign `"IDAT: ADLER32 checksum mismatch"`, which is a warning by
default, delivers 63 of the 64 rows (the damaged row among them) and returns normally
([`pngpread.c`][pread-inflate]). The same file yields an error or an image depending on
which API the caller chose; 1.6 behaves identically.

On top of PNG, libpng's own framing is a fixed hand-written parser: there is no
description of the chunk grammar beyond the `read_chunks[]` table, and the table holds
only length bounds, ordering bits and multiplicity, with special cases (`PLTE`, `tRNS`,
`bKGD`) left to the handlers ([`pngrutil.c`][rutil-table]).

### 5. Hostile input and safety

**Limits and their defaults.** From [`pnglibconf.dfa`][dfa-limits], identical on 1.6
([`pnglibconf.h.prebuilt`][l16-prebuilt]), confirmed at run time (**verified**:
`png_get_user_width_max` and friends return these values on both lines):

| Limit                     | Default   | Setter                     | Scope                                                                              |
| ------------------------- | --------- | -------------------------- | ---------------------------------------------------------------------------------- |
| `USER_WIDTH_MAX`          | 1,000,000 | `png_set_user_limits`      | `IHDR` width; also an architectural row-size check in `png_check_IHDR`             |
| `USER_HEIGHT_MAX`         | 1,000,000 | `png_set_user_limits`      | `IHDR` height                                                                      |
| `USER_CHUNK_CACHE_MAX`    | 1000      | `png_set_chunk_cache_max`  | stored `sPLT`, `tEXt`, `iTXt`, `zTXt` and unknown chunks; `0` means unlimited      |
| `USER_CHUNK_MALLOC_MAX`   | 8,000,000 | `png_set_chunk_malloc_max` | handler allocation/decompression checks (`png_chunk_max`); excludes push buffering |
| pixel count, memory total | none      | none                       | width and height are checked separately; there is no product limit                 |
| frames (APNG, 1.8)        | 2^31 - 1  | none                       | `png_set_acTL` rejects only zero and values above 2^31 - 1                         |

A 1,000,000 by 1,000,000 RGBA16 image passes `png_check_IHDR` ([`png.c`][png-c-ihdr]);
the low-level row reader does not allocate the whole image, but `png_read_png`
allocates every row itself (`height` calls of `png_malloc(rowbytes)`, [`pngread.c`][read-png]) and
the simplified API asks the caller for one buffer of up to 4 GiB. The manual says `0x7fffffff` means "unlimited" for the chunk
cache while the configuration file and the code use `0` ([`libpng-manual.txt`][manual-limits],
[`pngrutil.c`][rutil-text]). The cache counter is decremented and the chunk dropped when
it reaches 1, so 1500 `tEXt` chunks keep **998** texts (verified), not the 1000 the manual
promises.

**What the limits do not cover (verified).** `png_chunk_max` is applied by the chunk
handlers, which the push reader calls only after it has buffered the whole chunk. A file
with a 32 MiB `tEXt` chunk fed to the sequential reader is rejected at a peak of 1,632
bytes of live allocation (`tEXt: out of memory`, a misleading message for a limit hit).
The same file fed to `png_process_data` in 64 KiB pieces makes `png_push_save_buffer`
allocate a 33,554,647-byte save buffer and peak at 67,045,390 live bytes, across 514
allocations, before the handler refuses the chunk: the buffer grows by
`current_buffer_size + 256` per call and copies the old contents each time
([`pngpread.c`][pread-save]). The manual's statement that the 8 MB limit bounds "the
amount of memory that any chunk other than IDAT can occupy" holds for the handler's
buffer, and so for the sequential reader, but not for the push reader's `save_buffer`. On 1.6 the save-buffer size
and 514 allocations match, but the live peaks are 1,584 bytes (pull) and 67,045,342
bytes (push), because its structures differ in size. The pull probe stops after
`png_read_info`; these figures measure metadata processing, not a complete image decode.

**CRCs and checksums.** `png_set_crc_action` chooses, separately for critical and
ancillary chunks, among supported policies: error, warn-and-discard (ancillary only),
warn-and-use and quiet-use
([`png.h`][png-h-crc]). The default errors on a critical chunk and warns and discards an
ancillary one (verified: a bad `tEXt` CRC drops the text with a warning, a bad `IDAT`
CRC is `IDAT: CRC error`). `PNG_IGNORE_ADLER32` (`png_set_option`) skips the zlib
checksum through `inflateValidate`; `PNG_MAXIMUM_INFLATE_WINDOW` forces a 32 KiB window
because "some zlib versions skip validation of the CINFO field" ([`pngrutil.c`][rutil-claim]).
Both exist mainly so fuzzers and repair tools can get past the checks.

**Error model.** `png_error` calls the user error function if supplied, then falls back
to the default handler if it returns ([`pngerror.c`][error-dispatch]). The default
`longjmp`s to `png_jmpbuf`, and without `setjmp` support it calls
`PNG_ABORT()` ([`pngerror.c`][error-longjmp]). After a `longjmp` the only valid
operation is to destroy the structures. Benign errors give the library a second tier
that the application can promote to fatal, and `png_set_check_for_invalid_index`
reports palette indices beyond `PLTE`.

**Fuzzing.** OSS-Fuzz builds libpng from `master`, which is the 1.6 line
([`projects/libpng/Dockerfile`][ossfuzz-docker]; ASan, MSan and UBSan; libFuzzer,
AFL and honggfuzz, [`project.yaml`][ossfuzz-project]). The harnesses live in
`contrib/oss-fuzz/` on `libpng16` only: `libpng_read_fuzzer.cc`,
`libpng_readapi_fuzzer.cc`, `libpng_transformations_fuzzer.cc` and
`libpng_colormap_fuzzer.cc`, with a dictionary and `nalloc.h` allocation-failure
injection added in 1.6.52 ([`CHANGES`][changes]). The main harness's low-level read path
turns integrity checks off and adds allocation and pixel-count checks
([`libpng_read_fuzzer.cc`][l16-fuzz]):

```cpp
  png_set_crc_action(png_handler.png_ptr, PNG_CRC_QUIET_USE, PNG_CRC_QUIET_USE);
#ifdef PNG_IGNORE_ADLER32
  png_set_option(png_handler.png_ptr, PNG_IGNORE_ADLER32, PNG_OPTION_ON);
#endif
```

and rejects images above 100,000,000 pixels (a comment calls them "too slow"); allocations above 8,000,000
bytes fail in its `limited_malloc`. After a successful low-level read, that harness
also calls the simplified API with a fresh context; the allocator and checksum
overrides are not installed on that context. The fuzzers exercise sequential and
simplified APIs, and the
`README.txt` still says "To do: exercise the progressive reader and the png encoder"
([`README.txt`][l16-fuzz-readme]), which matches where the verified save-buffer growth
above lives. The 1.8 branch carries no fuzz harness at the pinned revision.

**CVE history.** The record is long and recent; [`CHANGES`][changes] lists twelve CVEs
fixed between 1.6.51 (November 21, 2025) and 1.6.59 (September 28, 2026) alone. Four are
instructive for a reimplementation:

- [CVE-2015-8126][nvd-2015-8126]: buffer overflows in `png_set_PLTE` and `png_get_PLTE`
  "via a small bit-depth value in an IHDR". The palette length was checked against 256,
  not against `1 << bit_depth`: an invariant between two chunks, held in two places.
- [CVE-2017-12652][nvd-2017-12652]: "libpng before 1.6.32 does not properly check the
  length of chunks against the user limit". The limit existed and was not on every path;
  the push-reader buffering above is the same class of gap, one level up.
- [CVE-2025-65018][nvd-2025-65018] ([advisory][ghsa-65018]): a heap overflow in
  `png_image_finish_read` "when processing 16-bit interlaced PNGs with 8-bit output
  format", present from 1.6.0 to 1.6.50. The simplified API composes the transform
  pipeline, interlacing and a caller buffer, and the size arithmetic of that composition
  was wrong for one combination.
- [CVE-2026-33636][nvd-2026-33636] ([advisory][ghsa-33636]): an out-of-bounds read and
  write in the ARM Neon palette expansion, 1.6.36 to 1.6.55, where "the Neon loop
  processes a final partial chunk without verifying that enough input pixels remain"
  and, working backward, underflows the row buffer. The SIMD kernel duplicated a scalar
  routine's bounds logic and got the tail wrong.

The 2026 entries in `CHANGES` add two use-after-free bugs from pointer aliasing in the
setters (`png_set_tRNS`, `png_set_PLTE`, `png_set_hIST`; CVE-2026-33416, CVE-2026-34757)
and one from stale `zstream` input after an incomplete `zTXt`, `iTXt` or `iCCP`
(CVE-2026-46675): bugs in ownership, not in parsing.

### 6. Allocation and ownership

All allocation goes through `png_malloc`, `png_malloc_warn` and `png_malloc_base`, which
call the user `png_malloc_ptr` if one was given to `png_create_read_struct_2`. The
`_warn` and `_base` variants return `NULL` instead of calling `png_error`, which is what
lets the simplified API set up without a `jmp_buf` ([`pngread.c`][read-control]).
Per-image working memory is small and reused: two row buffers, one `read_buffer` that
grows to the largest chunk handled (`png_read_buffer`, freed before `IDAT` and
reallocated per `IDAT_read_size` slice; [`pngrutil.c`][rutil-readbuf]), the push
`save_buffer`, and gamma tables built on demand.

Ownership of chunk data is a bit mask. `png_info::free_me` records which members the
library allocated (`PNG_FREE_PLTE`, `PNG_FREE_ICCP`, `PNG_FREE_TEXT`, …), and
`png_data_freer` lets the application take or give responsibility; the `iCCP` handler
"steals" the decompressed profile from `read_buffer` into `info_ptr` by pointer
transfer. The setter use-after-free fixes sit at this seam. In CVE-2026-33416,
`png_set_tRNS` and `png_set_PLTE` shared one buffer between `png_struct` and
`png_info`, so freeing it through `info_ptr` left `png_ptr` dangling
([GHSA-m4pc-p4q3-4c7j][ghsa-33416]). In CVE-2026-34757, a setter freed the old array
before copying from a caller argument that pointed into it
([GHSA-6fr7-g8h7-v645][ghsa-34757]). The stale-zlib-input bug is a separate ownership
failure.

Independent decoder instances may run concurrently: "Libpng is thread safe, provided the
threads are using different instances of the structures" ([`libpng-manual.txt`][manual-threads]).
The one process-wide cache found is the 1.6 ARM run-time Neon probe, a
`static volatile sig_atomic_t no_neon` ([`arm_init.c` on 1.6][l16-arm-init]).

### 7. CPU parallelism and SIMD

**Parallelism:** none. One `png_struct` decodes one stream on the caller's thread;
filter reversal is a serial dependency from row to row, and zlib inflate is serial.

**SIMD scope:** only filter reversal (Sub, Avg, Paeth, and Up on some targets) and, on
ARM, palette expansion to RGB or RGBA. Gamma, compositing, scaling and de-interlacing
are scalar C. The x86 comment explains the limit ([`intel_init.c`][intel-init]): the
kernels "operate on one pixel at a time. So they generally speed up 3bpp images about
3x, 4bpp images about 4x", and only `bpp == 3` and `bpp == 4` get SIMD versions; "No
need optimize PNG_FILTER_VALUE_UP. The compiler should autovectorize."

**Dispatch on 1.8:** compile-time only. `pngtarget.h` includes `arm/check.h`,
`intel/check.h`, `mips/check.h` and `powerpc/check.h` ([`pngtarget.h`][target-h]); each
checks compiler macros (`__ARM_NEON`, `__SSE4_1__`/`__SSSE3__`/`__SSE2__`, MSA or MMI,
`__VSX__`) and names one implementation file that `pngsimd.c` includes
([`intel/check.h`][intel-check], [`arm/check.h`][arm-check]). At run time the only switch
is the `PNG_TARGET_SPECIFIC_CODE` option, defaulted on when a target is compiled in
([`pngread.c`][read-create], [`pngsimd.c`][simd-c]); there is no CPU probe. The
`loongarch/` and `riscv/` directories are present but are referenced by no build file,
by `pngtarget.h` or by any `check.h`, and their code is guarded by
`PNG_LOONGARCH_LSX_IMPLEMENTATION` and `PNG_RISCV_RVV_IMPLEMENTATION`, which nothing
defines ([`loongarch_lsx_init.c`][loongarch-init], [`riscv_init.c`][riscv-init]). Source
inspection finds no integration of those targets in the supplied 1.8 build, although
`manuals/libpng-install.txt` still documents `--enable-riscv-rvv`; neither
architecture was built in this investigation.

**Dispatch on 1.6:** a `PNG_FILTER_OPTIMIZATIONS` macro names one init function per
target, with LoongArch LSX and RISC-V RVV (off by default in CMake) wired in through CMake and `pngpriv.h`
([`pngpriv.h`][l16-priv-simd], [`CMakeLists.txt`][l16-cmake]), and 32-bit ARM can probe
for Neon at run time (`PNG_ARM_NEON_CHECK_SUPPORTED`, `png_have_neon`, cached in
`no_neon`; [`arm_init.c`][l16-arm-init]).

**Alignment:** a target may require `PNG_TARGET_ROW_ALIGNMENT` (16 for Intel, ARM and
MIPS); `png_read_start_row` aligns the first pixel, one byte past the filter byte, and
the comment records that before 1.5.6 "the filter byte was aligned, which had the exact
opposite effect of that intended" ([`pngrutil.c`][rutil-startrow]).

### 8. GPU offload and interop

Not applicable. libpng produces rows in host memory through caller-owned pointers and
has no notion of a device, a staging buffer or a texture format. The only interop
surface is that the caller chooses where rows land, which is enough to decode straight
into a mapped staging buffer one row at a time. Wuffs and the GPU decompression papers
([entropy and codec thread][p-entropy], [storage-to-GPU thread][p-gpu]) are the places
in this catalog where PNG meets the GPU.

### 9. Temporal, animation and containers

**On 1.6** there is no APNG support: `acTL`, `fcTL` and `fdAT` are stored as unknown
chunks, and `png.h` defines `PNG_INFO_acTL`, `_fcTL`, `_fdAT` only "as a convenience
for implementors of APNG" ([`png.h` on 1.6][l16-apng], [`pngrutil.c` on 1.6][l16-rutil-apng]).
Applications that wanted APNG used the out-of-tree APNG patch or parsed the unknown
chunks themselves.

**On 1.8** APNG read and write are compiled in by default (`PNG_APNG_SUPPORTED`,
`PNG_READ_APNG_SUPPORTED`, `PNG_WRITE_APNG_SUPPORTED`), with `png_get_acTL`,
`png_get_next_frame_fcTL`, `png_read_frame_head` (pull), `png_set_progressive_frame_fn`
(push), and `png_write_frame_head`/`png_write_frame_tail` ([`png.h`][png-h-apng]). The
integration is visibly grafted on: the table still maps the three chunks to `NULL`
under the 1.6 comment, while `png_read_info` and the push reader special-case them
before the table is consulted ([`pngread.c`][read-info], [`pngrutil.c`][rutil-actl]); the
handlers report problems with `png_warning` and `png_error` rather than the table's
benign-error path. Frame validation checks that each frame fits the first frame and that
`dispose_op` and `blend_op` are in range ([`pngset.c`][set-fctl]). libpng then hands the
application each frame's region: it does not compose frames, apply `DISPOSE_OP_PREVIOUS`
or `BLEND_OP_OVER`, or own a canvas. A non-APNG-aware push application gets the first
frame only (`PNG_APNG_APP` unset, [`pngpread.c`][pread-inflate]). The manual does not
mention APNG.

PNG is its own container; libpng has no complete MNG container decoder. It exposes
`png_permit_mng_features` for the empty-`PLTE` and filter-64 allowances
([`png.h`][png-h-mng]).

### 10. Testing and conformance

The test suite is self-generating as much as corpus-driven. `make check` uses shell
wrappers in [`tests/`][tests-dir]; CMake registers tests separately in
[`CMakeLists.txt`][cmake-tests]:

- **`pngvalid`** constructs images for every colour type, depth and interlace, writes
  them, reads them back and checks the result, including transform and gamma cases
  (`pngvalid-gamma-*`, `pngvalid-transform`) and the progressive reader
  (`pngvalid-progressive-*`); its header: "It generates bitmaps internally, stores them
  as PNG files (using the sequential write code) then reads them back (using the
  sequential read code) and validates that the result has the correct data"
  ([`pngvalid.c`][pngvalid]).
- **`pngstest`** checks the simplified API over `contrib/testpngs` in sRGB, linear,
  negative-stride and large-stride variants; **`pngimage --exhaustive`** reads the PNG
  Suite (the 51 top-level `contrib/pngsuite/*.png` files at this revision) with every transform
  combination.
- **`pngtest`** round-trips `pngtest.png` and the PNG Third Edition samples, and
  [`pngtest-all`][tests-pngtest-all] runs selected `contrib/testpngs/crashers/` inputs
  (`huge_*_chunk.png`, `badadler.png`, `bad_iCCP.png`, …) with `--xfail`, plus
  `badpal/` files that must produce the "palette index exceeding num_palette" warning.
- **`pngunknown`**, **`pnggetset`** and **`pngreadend`** cover unknown-chunk policy, the
  get/set API and end-chunk reading. CMake's `pngreadend` test explicitly takes
  `stale_zTXt_input.png` and `stale_iCCP_input.png` ([`CMakeLists.txt`][cmake-tests]).

All 38 tests passed on the 1.8 CMake build (verified). CI defines builds for the
targets in `ci/targets/` (Linux on ARM, MIPS, PowerPC, RISC-V and x86; FreeBSD, macOS,
Windows, Cygwin, Android, MS-DOS). There is no differential test against another decoder and
no fuzz harness in the tree on 1.8; fuzzing happens on 1.6 through OSS-Fuzz.

## Lessons for Sparkles

- **Q4.** The [push reader's buffering][pread-save] is the counterexample for a
  suspendable decoder: it copies incomplete metadata chunks
  into a growing heap buffer, so that buffer is bounded by the largest chunk, not by the
  configured limit (verified above). A D decoder that resumes from caller-provided bytes
  needs to stream non-`IDAT` chunk payloads through the handler, or apply the per-chunk
  limit at the header, before buffering. That is the shape Wuffs adopts and the
  [concepts page][c-incremental] defines; the baseline's `G7` records that Sparkles'
  PNG decoding is whole-file and single-shot ([existing code][bl-existing-gaps]), and
  `sparkles.image.png`, which now backs `sparkles.font.png` too, still takes the
  entire file.
- **Q4, Q8.** One library with two readers that disagree on the same file (sequential
  error, push warning plus pixels, verified) argues for a single decoding core in
  Sparkles with pull and push as thin adapters over it, and for a differential test
  that runs every corpus file through both adapters. It also means "agree with libpng"
  is not one oracle but two, plus whatever `png_set_crc_action` and benign-error policy
  the harness chose. `sparkles.image.png`'s lack of chunk-CRC checks (its module
  header: "chunk checksums are not checked"; [baseline G1][bl-existing-gaps]) is a
  separate policy difference: both libpng readers check chunk CRCs by default.
- **Q4.** The `read_chunks[]` table (length bounds, ordering bits, multiplicity, handler)
  is a compact, checkable chunk grammar that 1.6.47 introduced after decades of
  per-handler checks. It is close to what `sparkles:wired` would have to express for
  PNG, and it shows what a table alone cannot: `PLTE`/`tRNS`/`bKGD` ordering depends on
  `color_type`, and those stay in code ([wired baseline][bl-wired]).
- **Q5.** libpng stores ICC and EXIF payload bytes and typed `cICP`, `mDCV` and `cLLI`
  fields. Its core applies power-law gamma and uses chromaticities for RGB-to-grey,
  but leaves ICC and HDR conversion to applications. A Sparkles PNG decoder that returns the same chunks typed
  (CICP code points, ICC bytes, HDR metadata) and leaves conversion to a colour package
  matches what the reference library actually does; the three-stage `iCCP` read
  (header validated before full allocation, tags checked before reading the body) is worth
  copying. Sparkles today drops these chunks entirely ([baseline G4][bl-existing-gaps]).
- **Q4, Q9.** The fixed in-place transformation pipeline requires libpng to size
  its row buffer for the widest intermediate pixel. Several 2025–2026 memory bugs
  (CVE-2025-65018, CVE-2026-33636, the `png_set_quantize` overflow CVE-2026-25646)
  concern transforms and the simplified API ([`CHANGES`][changes]). `sparkles.image.png`'s `decodePng` already decodes into one caller-chosen layout
  (straight or premultiplied RGBA). Keeping conversion out of the codec, as separate
  range-style row operations over a decoded view, removes the "max pixel depth"
  arithmetic from the decoding path. These bugs support separating and independently
  testing conversion; they do not establish a comparative defect rate for the codec core.
- **Q4.** A `longjmp` over a D frame skips its `scope(exit)` and struct destructors;
  `@system` and `nothrow` do not provide cleanup for such a jump. The
  existing D decoders return `FontResult` or `PngResult` (`Expected`) with an offset,
  which is the [`Expected` idiom][expected] the repository already prescribes; libpng's
  benign-error tier maps naturally onto a policy struct (strict or lenient per check)
  rather than onto a global flag. An oracle harness that links libpng through ImportC
  needs a C wrapper with a live `setjmp` recovery point and callbacks that cannot jump
  across D frames requiring cleanup.
- **Q3, Q7.** libpng's SIMD covers filter reversal (with target-dependent pixel sizes) and
  Neon palette expansion, with compile-time dispatch on 1.8 and two architectures'
  kernels absent from the supplied build integration. Per-target hand kernels can drift
  (unwired LoongArch and RISC-V code, a Neon tail bug affecting 1.6.36–1.6.55). Sparkles'
  [SIMD baseline][bl-shaders-gaps] (`G4`, `G5`) has the same per-target, hand-dispatched
  pattern; a PNG unfilter is a good first candidate for one generic-vector kernel
  instantiated per `@target`, checked against the scalar version on every corpus.
- **Q8.** For a conformance corpus, libpng contributes more than the PNG Suite
  (already used by `png_oracle.d` through the `libpng-src` flake input): the
  `contrib/testpngs/crashers/` files are named regression inputs for limits and stale
  state, `badpal/` for out-of-range palette indices, and `pngvalid`'s generate-and-check
  method covers every colour type, depth and interlace without checked-in files. The
  flake input pins `v1.6.44`, before the PNG Third Edition chunk support and the
  2025–2026 fixes ([baseline][bl-existing]).
- **Q8.** The low-level path of the main OSS-Fuzz harness turns off CRC and Adler-32
  checks and caps images at 100 million pixels and allocations at 8 MB; its later
  simplified-API call uses a fresh default context. A Sparkles fuzz target needs explicit
  fuzz-only switches (the [hostile-input thread][p-hostile] reaches the same
  conclusion), a work budget as well as a byte budget, and, unlike libpng's harness,
  coverage of the incremental path from the start.
- **Q2, Q9.** libpng's variation lives in build-time feature macros and run-time
  function tables, never in types. In D the build-time half is design by introspection
  and `static if`, which can drop unsupported chunks without a configuration language,
  and the run-time half (filter tables) is unnecessary when the pixel format of the
  unfilter step is a template parameter. Neither transfers as a mechanism; both
  transfer as a list of what users wanted to switch off (`contrib/conftest/*.dfa`).

## Strengths

- Support for PNG Third Edition chunks, every PNG colour type and depth,
  Adam7, and (1.8) APNG read and write.
- Hardened by decades of real-world input: per-chunk length bounds, an ordering table,
  per-chunk handler limits, and an `iCCP` read that checks its header before full allocation.
- Caller-owned rows in the low-level API, with caller-chosen layout and stride.
- Both pull and push readers, with Adam7 progressive display and pause support.
- A configurable leniency model (`png_set_crc_action`, benign errors,
  `PNG_IGNORE_ADLER32`) that makes repair tools and fuzzing practical.
- A generative test suite (`pngvalid`) that exercises PNG formats and transform
  cases without a large corpus, plus named crasher and bad-palette regressions.
- CI configurations for 16-bit DOS, Windows, Android and multiple CPU architectures.

## Weaknesses

- Errors by `longjmp` bypass destructors in crossed frames. An unconfigured recovery
  point calls `PNG_ABORT()`; a registered but uninitialised jump buffer is invalid.
- The push reader buffers whole ancillary chunks before limits apply (verified), and it
  accepts deflate data errors as warnings where the sequential reader fails (verified).
- No configurable pixel-count, total-memory, time or frame-count budget; only
  per-dimension, per-chunk and format limits.
- No ICC or HDR conversion. Gamma is a power-law approximation outside the simplified
  API; `mDCV` chromaticities are used only for RGB-to-grey.
- The transform and simplified-read layers are the largest source of recent
  memory-safety bugs: seven of the twelve CVEs fixed in 1.6.51–1.6.59 are in quantize,
  composite, scaled-read, combine-row and Neon palette-expansion paths ([`CHANGES`][changes]).
- SIMD limited to unfiltering and Neon palette expansion; 1.8 drops run-time detection
  and has no supplied build integration for the LoongArch and RISC-V kernels.
- No multithreading, no region or downscaled decode.
- APNG on 1.8 is bolted on beside the chunk table, undocumented in the manual, and does
  no frame composition; 1.6 has no APNG at all.
- Two maintained lines with diverging internals (`png_structrp` versus `png_struct *`,
  SIMD dispatch, APNG); the cited OSS-Fuzz configuration covers only 1.6.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                                   | Trade-off                                                                                         |
| --------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Row-at-a-time API with caller-owned rows            | Row working memory independent of height; caller chooses destination stride | No region, tile or parallel decode; metadata and caller output need separate budgets              |
| Separate pull and push readers over shared handlers | Pull suits files, push suits network streams and browsers                   | Two state machines that drift: different buffering, different acceptance of corrupt data          |
| Push reader buffers metadata chunks whole           | Handlers stay written for contiguous input; one handler serves both readers | Save buffer exceeds `chunk_malloc_max`; repeated copying is quadratic for fixed-size input pieces |
| `setjmp`/`longjmp` errors                           | C89 has no exceptions; keeps every call site free of error checks           | Unsafe across foreign frames and destructors; recovery means destroying the objects               |
| Benign errors as warnings by default on read        | Real-world files are often slightly broken; browsers want an image          | Default behaviour accepts more than the specification; strictness is opt-in                       |
| Fixed in-place transform pipeline selected by flags | Applications get their layout without a separate image-wide conversion pass | Order is fixed by the library; widest-intermediate sizing adds a source of buffer-overflow bugs   |
| Table-driven chunk checks (1.6.47)                  | One place for length, order and multiplicity rules                          | Colour-type-dependent rules and APNG stay outside the table                                       |
| Two-pass decompression of compressed text           | Exact allocation after a size-bounded dry run                               | Inflates the text twice; `iCCP` instead uses staged validation                                    |
| Compile-time SIMD selection (1.8)                   | Simpler build; no CPU-detection code to maintain                            | Distribution builds get only the baseline ISA; unwired targets rot                                |
| Store colour chunks, apply gamma and RGB-to-grey    | Leaves ICC and HDR conversion to a CMS                                      | Applications must implement `iCCP`, `cICP` and HDR handling themselves                            |

## Sources

- [glennrp/libpng][repo], read at `890812a28da480f84f3b0198d31ac611c864ed98` (`libpng18`)
  and, for 1.6 comparisons, `e88e1735a26788df76a570c59d1183c883e71401` (`libpng16`)
- [`png.h`][png-h]: [CRC actions][png-h-crc]; [progressive reader][png-h-push];
  [user limits][png-h-limits]; [implementation options][png-h-options];
  [APNG API][png-h-apng]; [simplified API][png-h-simplified]; [simplified formats and alpha][png-h-alpha]
- [`scripts/pnglibconf/pnglibconf.dfa` — limits][dfa-limits]; [`ANNOUNCE.md`][announce];
  [`TODO.md`][todo]; [`CHANGES`][changes]
- [`png.c` — struct creation and default limits][png-c-create]; [`png_check_IHDR`][png-c-ihdr]
- [`pnginfo.h`][pnginfo]; [`pngpriv.h` — `png_chunk_max`][priv-chunkmax]
- [`pngrutil.c`][rutil]: [chunk header][rutil-header]; [CRC handling][rutil-crc];
  [`png_read_buffer`][rutil-readbuf]; [`png_inflate_claim`][rutil-claim];
  [`png_decompress_chunk`][rutil-decompress]; [`gAMA`][rutil-gama]; [`sRGB`][rutil-srgb];
  [`iCCP`][rutil-iccp]; [`cICP`][rutil-cicp]; [`mDCV`][rutil-mdcv]; [`eXIf`][rutil-exif];
  [`tEXt` cache limit][rutil-text]; [`acTL`][rutil-actl]; [chunk table][rutil-table];
  [`png_handle_chunk`][rutil-handle]; [filters and dispatch][rutil-filters];
  [`png_read_IDAT_data`][rutil-idat]; [`png_read_start_row`][rutil-startrow]
- [`pngpread.c`][pread]: [modes][pread-modes]; [`png_process_data`, pause, skip][pread-process];
  [`png_push_save_buffer`][pread-save]; [end of `IDAT`][pread-idat-end]; [inflate loop][pread-inflate]
- [`pngread.c`][pread-seq]: [read struct creation][read-create]; [`png_read_info`][read-info];
  [`png_read_frame_head`][read-frame]; [`png_read_row`][read-row]; [`png_read_png`][read-png];
  [simplified read control][read-control]; [`png_image_finish_read`][read-finish]
- [`pngrtran.c` — transformation order][rtran-order]; [file gamma precedence][rtran-gamma];
  [`pngset.c` — `fcTL` validation][set-fctl]; [`pngerror.c` — `png_longjmp`][error-longjmp];
  [`png_safe_execute`][error-safe]
- [`pngsimd.c`][simd-c]; [`pngtarget.h`][target-h]; [`intel/check.h`][intel-check];
  [`intel/intel_init.c`][intel-init]; [`arm/check.h`][arm-check]; [`arm/arm_init.c`][arm-init];
  [`loongarch/loongarch_lsx_init.c`][loongarch-init]; [`riscv/riscv_init.c`][riscv-init]
- [`libpng-manual.txt`][manual]: [error handling][manual-errors]; [threads][manual-threads];
  [user limits][manual-limits]
- [`tests/`][tests-dir]; [`tests/pngtest-all`][tests-pngtest-all]; [`contrib/libtests/pngvalid.c`][pngvalid];
  [`contrib/testpngs/crashers/`][crashers]; [`contrib/pngsuite/`][pngsuite]
- 1.6 line: [`png.h` APNG flags][l16-apng]; [`pngrutil.c` APNG as unknown][l16-rutil-apng];
  [`arm/arm_init.c` run-time Neon check][l16-arm-init]; [`pngpriv.h` filter optimizations][l16-priv-simd];
  [`CMakeLists.txt` LoongArch][l16-cmake]; [`pnglibconf.h.prebuilt` limits][l16-prebuilt];
  [`contrib/oss-fuzz/libpng_read_fuzzer.cc`][l16-fuzz]; [`contrib/oss-fuzz/README.txt`][l16-fuzz-readme]
- OSS-Fuzz: [`projects/libpng/Dockerfile`][ossfuzz-docker]; [`projects/libpng/project.yaml`][ossfuzz-project]
- NVD: [CVE-2015-8126][nvd-2015-8126]; [CVE-2017-12652][nvd-2017-12652];
  [CVE-2025-65018][nvd-2025-65018]; [CVE-2026-33636][nvd-2026-33636]; advisories
  [GHSA-7wv6-48j4-hj3g][ghsa-65018], [GHSA-wjr5-c57x-95m2][ghsa-33636],
  [GHSA-m4pc-p4q3-4c7j][ghsa-33416] and [GHSA-6fr7-g8h7-v645][ghsa-34757]
- [PNG Specification, Third Edition (W3C)][png3]; [libpng home page][home]
- In this catalog: [concepts][concepts]; [existing-code baseline][bl-existing];
  [SIMD baseline][bl-shaders]; [wired baseline][bl-wired]; [hostile-input papers][p-hostile];
  [entropy-codec papers][p-entropy]; [storage-to-GPU papers][p-gpu]; sibling deep-dives
  [stb_image][stb-image] (the current Sparkles PNG oracle), [Skia][skia] (`SkPngCodec`
  wraps libpng), [libvips][libvips] (drives libpng a scanline at a time),
  [zune-image][zune-image] and [image-rs][image-rs] (memory-safe PNG decoders)

<!-- References -->

[repo]: https://github.com/glennrp/libpng
[repo-pnggroup]: https://github.com/pnggroup/libpng
[home]: https://www.libpng.org/pub/png/libpng.html
[png3]: https://www.w3.org/TR/png-3/
[manual]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/manuals/libpng-manual.txt
[manual-errors]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/manuals/libpng-manual.txt#L407-L436
[manual-threads]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/manuals/libpng-manual.txt#L111-L115
[manual-limits]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/manuals/libpng-manual.txt#L653-L699
[announce]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/ANNOUNCE.md
[todo]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/TODO.md#L10
[changes]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/CHANGES#L6281-L6400
[png-h]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/png.h
[png-h-crc]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/png.h#L1411-L1429
[png-h-push]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/png.h#L1674-L1719
[png-h-limits]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/png.h#L2508-L2527
[png-h-options]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/png.h#L3348-L3417
[png-h-mng]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/png.h#L796-L811
[png-h-apng]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/png.h#L3423-L3496
[png-h-simplified]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/png.h#L2778-L2870
[png-h-alpha]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/png.h#L2880-L2953
[dfa-limits]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/scripts/pnglibconf/pnglibconf.dfa#L356-L380
[png-c-create]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/png.c#L255-L290
[png-c-ihdr]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/png.c#L1933-L2015
[pnginfo]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pnginfo.h#L17-L26
[priv-chunkmax]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngpriv.h#L885-L910
[rutil]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c
[rutil-header]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L183-L222
[rutil-crc]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L238-L305
[rutil-readbuf]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L375-L405
[rutil-claim]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L426-L530
[rutil-decompress]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L668-L805
[rutil-gama]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L1095-L1128
[rutil-srgb]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L1275-L1316
[rutil-iccp]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L1320-L1541
[rutil-cicp]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L1876-L1914
[rutil-mdcv]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L1940-L1990
[rutil-exif]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L1994-L2034
[rutil-text]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L2381-L2395
[rutil-actl]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L2704-L2745
[rutil-table]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L3135-L3256
[rutil-handle]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L3280-L3393
[rutil-filters]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L4126-L4329
[rutil-idat]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L4333-L4460
[rutil-startrow]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrutil.c#L4599-L4870
[pread]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngpread.c
[pread-modes]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngpread.c#L17-L32
[pread-process]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngpread.c#L49-L102
[pread-save]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngpread.c#L463-L512
[pread-idat-end]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngpread.c#L667-L681
[pread-inflate]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngpread.c#L684-L770
[pread-seq]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngread.c
[read-create]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngread.c#L40-L80
[read-info]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngread.c#L102-L181
[read-frame]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngread.c#L194-L257
[read-row]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngread.c#L534-L638
[read-png]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngread.c#L957-L1152
[read-control]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngread.c#L1170-L1263
[read-finish]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngread.c#L4177-L4290
[rtran-order]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrtran.c#L4840-L5131
[rtran-gamma]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngrtran.c#L1333-L1366
[set-fctl]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngset.c#L1470-L1495
[error-longjmp]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngerror.c#L664-L683
[error-dispatch]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngerror.c#L45-L72
[error-safe]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngerror.c#L797-L829
[simd-c]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngsimd.c#L81-L143
[target-h]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/pngtarget.h#L80-L88
[intel-check]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/intel/check.h#L14-L34
[intel-init]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/intel/intel_init.c#L16-L46
[arm-check]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/arm/check.h#L11-L19
[arm-init]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/arm/arm_init.c#L23-L227
[loongarch-init]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/loongarch/loongarch_lsx_init.c#L15
[riscv-init]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/riscv/riscv_init.c#L15
[tests-dir]: https://github.com/glennrp/libpng/tree/890812a28da480f84f3b0198d31ac611c864ed98/tests
[tests-pngtest-all]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/tests/pngtest-all
[pngvalid]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/contrib/libtests/pngvalid.c#L10-L17
[crashers]: https://github.com/glennrp/libpng/tree/890812a28da480f84f3b0198d31ac611c864ed98/contrib/testpngs/crashers
[pngsuite]: https://github.com/glennrp/libpng/tree/890812a28da480f84f3b0198d31ac611c864ed98/contrib/pngsuite
[l16-apng]: https://github.com/glennrp/libpng/blob/e88e1735a26788df76a570c59d1183c883e71401/png.h#L750-L761
[l16-rutil-apng]: https://github.com/glennrp/libpng/blob/e88e1735a26788df76a570c59d1183c883e71401/pngrutil.c#L2971-L2982
[l16-arm-init]: https://github.com/glennrp/libpng/blob/e88e1735a26788df76a570c59d1183c883e71401/arm/arm_init.c#L20-L96
[l16-priv-simd]: https://github.com/glennrp/libpng/blob/e88e1735a26788df76a570c59d1183c883e71401/pngpriv.h#L160-L310
[l16-cmake]: https://github.com/glennrp/libpng/blob/e88e1735a26788df76a570c59d1183c883e71401/CMakeLists.txt#L290-L360
[cmake-tests]: https://github.com/glennrp/libpng/blob/890812a28da480f84f3b0198d31ac611c864ed98/CMakeLists.txt#L530-L780
[l16-prebuilt]: https://github.com/glennrp/libpng/blob/e88e1735a26788df76a570c59d1183c883e71401/scripts/pnglibconf.h.prebuilt#L221-L224
[l16-fuzz]: https://github.com/glennrp/libpng/blob/e88e1735a26788df76a570c59d1183c883e71401/contrib/oss-fuzz/libpng_read_fuzzer.cc#L80-L225
[l16-fuzz-readme]: https://github.com/glennrp/libpng/blob/e88e1735a26788df76a570c59d1183c883e71401/contrib/oss-fuzz/README.txt#L36
[ossfuzz-docker]: https://github.com/google/oss-fuzz/blob/fe1478d57b3b5e66acdff48abbab6adcb6e7ff37/projects/libpng/Dockerfile
[ossfuzz-project]: https://github.com/google/oss-fuzz/blob/fe1478d57b3b5e66acdff48abbab6adcb6e7ff37/projects/libpng/project.yaml
[nvd-2015-8126]: https://nvd.nist.gov/vuln/detail/CVE-2015-8126
[nvd-2017-12652]: https://nvd.nist.gov/vuln/detail/CVE-2017-12652
[nvd-2025-65018]: https://nvd.nist.gov/vuln/detail/CVE-2025-65018
[nvd-2026-33636]: https://nvd.nist.gov/vuln/detail/CVE-2026-33636
[ghsa-65018]: https://github.com/pnggroup/libpng/security/advisories/GHSA-7wv6-48j4-hj3g
[ghsa-33636]: https://github.com/pnggroup/libpng/security/advisories/GHSA-wjr5-c57x-95m2
[ghsa-33416]: https://github.com/pnggroup/libpng/security/advisories/GHSA-m4pc-p4q3-4c7j
[ghsa-34757]: https://github.com/pnggroup/libpng/security/advisories/GHSA-6fr7-g8h7-v645
[concepts]: ./concepts.md
[c-stride]: ./concepts.md#stride
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[c-incremental]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[c-gainmap]: ./concepts.md#hdr-gain-map
[c-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[bl-existing]: ./baseline/existing-code.md
[bl-existing-gaps]: ./baseline/existing-code.md#gaps-and-tensions
[bl-shaders]: ./baseline/shaders-simd.md
[bl-shaders-gaps]: ./baseline/shaders-simd.md#gaps-and-tensions
[bl-wired]: ./baseline/wired.md
[p-hostile]: ./papers/hostile-input-safety.md
[p-entropy]: ./papers/entropy-codecs.md
[p-gpu]: ./papers/gpu-decode-streaming.md
[expected]: ../../guidelines/idioms/expected/index.md
[stb-image]: ./stb-image.md
[skia]: ./skia.md
[libvips]: ./libvips.md
[zune-image]: ./zune-image.md
[image-rs]: ./image-rs.md
