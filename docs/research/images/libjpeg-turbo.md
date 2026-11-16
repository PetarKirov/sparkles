# libjpeg-turbo (C)

The SIMD-accelerated descendant of the Independent JPEG Group's libjpeg, and the
reference JPEG codec that browsers, operating systems and image libraries link:
the oracle and the benchmark any JPEG decoder written in D is measured against.

| Field         | Value                                                                                                                                                      |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C (C89-style, with hand-written assembly and intrinsics under `simd/`)                                                                                     |
| License       | IJG License, Modified (3-clause) BSD and zlib licenses (roll-up in [`LICENSE.md`][license])                                                                |
| Repository    | [libjpeg-turbo/libjpeg-turbo][repo]                                                                                                                        |
| Revision read | `7b4993786d856cbccabfc0ed2f923ba000e326cc` (October 26, 2026, `main`; `CMakeLists.txt` says version 3.2.1)                                                 |
| Documentation | [`doc/libjpeg.txt`][libjpeg-txt] (libjpeg API) · [`doc/structure.txt`][structure] (internals) · [`turbojpeg.h`][tjh] and the [TurboJPEG API docs][tj-docs] |
| Category      | Formats: reference codec                                                                                                                                   |
| Tier          | A                                                                                                                                                          |
| Last reviewed | November 7, 2026                                                                                                                                           |

> [!IMPORTANT]
> **What was run.** Claims marked **verified** come from a static `Release` build of
> the pinned tree (exported with `git archive`, built outside this repository with
> GCC 14.3.0, NASM 2.16.03 and CMake 4.1.2 from `nix-shell`) and its own `djpeg`,
> `cjpeg` and `jpegtran`, run on an AMD Ryzen 9 7940HX. The hostile files were made
> by a small C program that rewrites a progressive JPEG. The timings are single
> runs of `/usr/bin/time` and show orders of magnitude only; they are not
> benchmarks. Everything else was read in the source at the pinned revision.

---

## Overview

### What it solves

libjpeg-turbo encodes and decodes JPEG (ITU-T T.81 / ISO/IEC 10918-1) fast, on
every common CPU, without changing the output of the libjpeg v6b code it grew from.
The README states the scope and the claim ([`README.md`][readme-bg]):

> "libjpeg-turbo is a JPEG image codec that uses SIMD instructions to accelerate
> baseline and progressive JPEG compression and decompression on systems with
> common CPU architectures. On such systems, libjpeg-turbo is generally 2-6x as
> fast as libjpeg, all else being equal."

and its standing ([`README.md`][readme-bg]): "libjpeg-turbo is an ISO/IEC and ITU-T
reference implementation of the JPEG standard."

It ships two APIs over one engine. The **libjpeg API** (`jpeglib.h`) is the
de facto industry interface: a state machine driven one scanline group at a time,
with replaceable source, destination, error, memory and progress objects. The
**TurboJPEG API** (`turbojpeg.h`, version 3 functions prefixed `tj3`) wraps it in
whole-image, in-memory calls on an opaque `tjhandle`, adding planar YUV output,
lossless transforms of many crops at once, and the security limits the libjpeg API
leaves to the caller. The coding processes covered are baseline and
extended-sequential DCT (8- and 12-bit), progressive DCT, lossless predictive
coding with 2 to 16 bits per sample, and both Huffman and arithmetic entropy
coding; hierarchical JPEG is not supported ([`doc/libjpeg.txt`][libjpeg-scope]).

### Design philosophy

Three commitments shape the code.

1. **Compatibility first.** The libjpeg API is "both API/ABI-compatible and
   mathematically compatible with libjpeg v6b" ([`README.md`][readme-apis]); the
   README lists the two cases in which output can differ from v6b (fancy 4:4:0
   upsampling, the floating-point DCT) ([`README.md`][readme-math]). Speed is added
   underneath an interface that cannot move.
2. **Poor man's object orientation.** Every processing step is a struct of function
   pointers chosen at start-up. [`doc/structure.txt`][structure-oo] explains why:

   > "An "object" is just a struct containing one or more function pointer fields,
   > each of which corresponds to a method name in real object-oriented languages.
   > During initialization we fill in the function pointers with references to
   > whichever module we have determined we need to use in this run."

   This is also how SIMD enters: a dispatcher overwrites the pointer with an
   assembly routine (see [SIMD dispatch](#simd-dispatch)).

3. **Strips, not images.** The decoder holds buffers "as wide as the image but just
   a few rows high" ([`doc/libjpeg.txt`][libjpeg-mem]); only multi-scan files,
   buffered-image mode and two-pass quantization need full-image arrays, which the
   memory manager treats as "virtual arrays".

The project's definition of a vulnerability is narrow and explicit
([`.github/SECURITY.md`][security]): a bug "whereby an otherwise well-behaved
calling program can trigger a potentially exploitable failure (such as a buffer
overrun, an uninitialized read, or undefined behavior) in one of the libraries by
passing malformed image data to a public API function." Resource exhaustion by a
legal file is not in that set; it is handled by opt-in limits (see
[Hostile input](#_5-hostile-input-and-safety)).

---

## How it works

### The decompression pipeline

[`doc/structure.txt`][structure-overview] splits the decoder into "JPEG proper"
(entropy decoding, dequantization and IDCT, or for lossless JPEG prediction and
undifferencing) and postprocessing (upsampling, colour conversion, quantization).
Control modules own the buffers between steps: the main controller, the
coefficient controller (`jdcoefct.c`), the post-processing controller and the
input controller that reads markers. Merged steps replace a controller and its two
leaves with one leaf; `jdmerge.c` fuses chroma upsampling and YCbCr-to-RGB, and is
the code path behind several CVEs (below).

A decode through the libjpeg API is a fixed call sequence
([`jpeglib.h`][jpeglib-entry]):

```c
/* src/jpeglib.h (abridged) */
EXTERN(int) jpeg_read_header(j_decompress_ptr cinfo, boolean require_image);
#define JPEG_SUSPENDED           0 /* Suspended due to lack of input data */
#define JPEG_HEADER_OK           1 /* Found valid image datastream */
EXTERN(boolean) jpeg_start_decompress(j_decompress_ptr cinfo);
EXTERN(JDIMENSION) jpeg_read_scanlines(j_decompress_ptr cinfo,
                                       JSAMPARRAY scanlines, JDIMENSION max_lines);
EXTERN(JDIMENSION) jpeg_skip_scanlines(j_decompress_ptr cinfo, JDIMENSION num_lines);
EXTERN(void) jpeg_crop_scanline(j_decompress_ptr cinfo, JDIMENSION *xoffset,
                                JDIMENSION *width);
EXTERN(boolean) jpeg_finish_decompress(j_decompress_ptr cinfo);
EXTERN(JDIMENSION) jpeg_read_raw_data(j_decompress_ptr cinfo, JSAMPIMAGE data,
                                      JDIMENSION max_lines);
```

Between `jpeg_read_header` and `jpeg_start_decompress` the caller sets the output
parameters on `jpeg_decompress_struct` ([`jpeglib.h`][jpeglib-dstruct]):
`out_color_space`, `scale_num`/`scale_denom`, `dct_method`,
`do_fancy_upsampling`, `do_block_smoothing`, `raw_data_out`, `buffered_image` and
the colour-quantization fields. `jpeg_start_decompress` builds the module graph,
and for a multi-scan file outside buffered-image mode it reads the whole input
into the coefficient buffer before returning ([`jdapistd.c`][start-decomp]), since
no output row exists until every scan has arrived.

### Data source managers and suspension

Input arrives through `jpeg_source_mgr` ([`jpeglib.h`][jpeglib-src]):

```c
/* src/jpeglib.h */
struct jpeg_source_mgr {
  const JOCTET *next_input_byte; /* => next byte to read from buffer */
  size_t bytes_in_buffer;       /* # of bytes remaining in buffer */

  void (*init_source) (j_decompress_ptr cinfo);
  boolean (*fill_input_buffer) (j_decompress_ptr cinfo);
  void (*skip_input_data) (j_decompress_ptr cinfo, long num_bytes);
  boolean (*resync_to_restart) (j_decompress_ptr cinfo, int desired);
  void (*term_source) (j_decompress_ptr cinfo);
};
```

The decoder pulls: when the window is empty it calls `fill_input_buffer`. A
blocking source refills and returns `TRUE`; a **suspending** source returns
`FALSE`, and the library unwinds to its caller. [`doc/libjpeg.txt`][libjpeg-susp]
lists where that can surface ("`jpeg_read_header()`: will return
`JPEG_SUSPENDED`", "`jpeg*_read_scanlines()`: will return the number of scanlines
already completed (possibly 0)") and states the contract that makes it work:

> "Just as with compression, the decompressor will typically backtrack to a
> convenient restart point before suspending. When fill_input_buffer() is called,
> next_input_byte/bytes_in_buffer point to the current restart point, which is
> where the decompressor will backtrack to if FALSE is returned. The data beyond
> that position must NOT be discarded if you suspend; it needs to be re-read upon
> resumption."

The restart point is the start of the current MCU (or marker), so suspension is a
retry protocol, not a saved continuation: the library re-decodes the partial MCU.
The same page warns that suspension "will not eliminate response-time problems",
because nothing bounds the work done in one call, and that `skip_input_data` may
not itself suspend. The in-memory source `jpeg_mem_src` never suspends: on
exhaustion it warns and feeds a synthetic end-of-image marker
([`jdatasrc.c`][jdatasrc-eoi]):

```c
/* src/jdatasrc.c, fill_mem_input_buffer */
  WARNMS(cinfo, JWRN_JPEG_EOF);

  /* Insert a fake EOI marker */

  cinfo->src->next_input_byte = mybuffer;
  cinfo->src->bytes_in_buffer = 2;
```

### Huffman decoding

The sequential Huffman decoder (`jdhuff.c`) keeps a 64-bit bit buffer on 64-bit
targets and decodes with an 8-bit lookahead table (`HUFF_LOOKAHEAD`, `lookup[256]`)
that yields code length and symbol in one load, falling back to canonical
`maxcode`/`valoffset` arrays for longer codes ([`jdhuff.h`][jdhuff-h]). Two MCU
decoders exist; `decode_mcu` picks the fast one only when it cannot run off the
buffer ([`jdhuff.c`][jdhuff-dispatch]):

```c
/* src/jdhuff.c, decode_mcu (abridged) */
#define BUFSIZE  (DCTSIZE2 * 8)
  if (cinfo->restart_interval) {
    if (entropy->restarts_to_go == 0)
      if (!process_restart(cinfo))
        return FALSE;
    usefast = 0;
  }

  if (cinfo->src->bytes_in_buffer < BUFSIZE * (size_t)cinfo->blocks_in_MCU ||
      cinfo->unread_marker != 0)
    usefast = 0;
```

`decode_mcu_fast` therefore omits per-byte bounds checks: 512 bytes per block of
slack are proven present before it starts, and the fast refill
(`FILL_BIT_BUFFER_FAST`) fetches six bytes at a time on 64-bit targets. It does not
handle markers: a marker met mid-MCU is recorded in `unread_marker`, the fast
routine returns `FALSE`, and `decode_mcu` decodes the whole MCU again with
`decode_mcu_slow` ([`jdhuff.c`][jdhuff-fast]). Any file with restart
markers takes the slow path, a cost the README quantifies as "as much as 20%"
([`README.md`][readme-restart]). When the slow reader meets a marker before the
bits it needs, it warns once (`JWRN_HIT_MARKER`) and shifts zeros in "so that we
can produce some kind of image" ([`jdhuff.c`][jdhuff-zero]); the remainder of the
segment decodes as flat grey.

### Progressive and arithmetic decoding

`jdphuff.c` decodes the four progressive scan kinds (DC first, DC refine, AC first,
AC refine), each with its own `decode_mcu_*` routine, into the full-image
coefficient buffer. `start_pass_phuff_decoder` rejects impossible scan headers
with `JERR_BAD_PROGRESSION` but, by design, only warns on an inconsistent
progression ([`jdphuff.c`][jdphuff-validate]):

> "Note that inter-scan inconsistencies are treated as warnings not fatal errors
> ... not clear if this is right way to behave."

The arithmetic decoder (`jdarith.c`) shares the same coefficient-buffer design.
Neither arithmetic coding nor SIMD exists outside 8-bit lossy mode
([`doc/libjpeg.txt`][libjpeg-precision]): "Arithmetic coding and SIMD acceleration
are currently only implemented for lossy mode with 8-bit data precision."

### One source file, three sample widths

12-bit lossy and 16-bit lossless decoding come from compiling the same sources
again with a different `BITS_IN_JSAMPLE`. Each wrapper is a comment header and two
directives ([`src/wrapper/jdapistd-12.c`][wrapper-12]):

```c
#define BITS_IN_JSAMPLE  12

#include "../jdapistd.c"
```

and [`jsamplecomp.h`][jsamplecomp] maps generic names (`_JSAMPLE`,
`_jpeg_read_scanlines`, `_jinit_d_main_controller`) onto `J12SAMPLE`,
`jpeg12_read_scanlines` and so on. The public API is therefore triplicated:
`jpeg_read_scanlines`, `jpeg12_read_scanlines`, `jpeg16_read_scanlines`, with
`J12SAMPARRAY` and `J16SAMPARRAY` row types ([`doc/libjpeg.txt`][libjpeg-precision]).
Lossless decoding (`jdlossls.c`) undoes the seven T.81 predictors with macros
(`UNDIFFERENCE_1D`, `UNDIFFERENCE_2D`) over a difference buffer
([`jdlossls.c`][jdlossls]).

### Partial decode: scaling, row skipping, column cropping, raw planes

- **DCT scaling.** `scale_num/scale_denom` may be "M/8 with all M from 1 to 16, or
  any reduced fraction thereof" ([`doc/libjpeg.txt`][libjpeg-scale]); the IDCT
  produces fewer (or more) samples per block, so a 1/8 decode never computes the
  full image. Only 1/4 and 1/2 are SIMD-accelerated ([`README.md`][readme-scaling]).
  **Verified**: a 4096x4096 baseline JPEG decodes at `-scale 1/2` to 2048x2048 and at
  `-scale 1/8` to 512x512.
- **`jpeg_skip_scanlines`** skips whole iMCU rows of a single-scan file by calling
  `decode_mcu` with a `NULL` output, which entropy-decodes and discards the
  coefficients without IDCT or colour work; for a multi-scan file, whose entropy
  decoding already happened in `jpeg_start_decompress`, it only advances the row
  counters. Partial rows at the edges are decoded and discarded
  (`read_and_discard_scanlines`, [`jdapistd.c`][skip-impl]). It is not
  supported with suspending sources ("will result in undefined behavior") or with
  two-pass quantization ([`doc/libjpeg.txt`][libjpeg-partial]).
- **`jpeg_crop_scanline`** restricts output columns. The left edge snaps to an iMCU
  boundary, for a reason the code states ([`jdapistd.c`][crop-align]): the IDCT
  cannot transform partial blocks, and SIMD upsampling and colour conversion need
  input "aligned to the SIMD word size". **Verified**: `djpeg -crop
100x100+1003+2000` on a 4:2:0 image produced a 111x100 image, the offset moved
  left from 1003 to 992 (a 16-pixel iMCU) and the width grown to keep the right
  edge.
- **Raw data** (`raw_data_out = TRUE`, `jpeg_read_raw_data`) returns the
  downsampled YCbCr planes before upsampling and colour conversion, one iMCU row per
  call; a buffer shorter than `max_v_samp_factor * min_DCT_scaled_size` rows is an
  error (`JERR_BUFFER_SIZE`, [`jdapistd.c`][raw-data]).
- **Coefficients** (`jpeg_read_coefficients`) return the quantized DCT blocks as
  virtual arrays; `jpegtran` and `tj3Transform` use them for lossless rotation,
  cropping and re-encoding.

### TurboJPEG 3

`tj3Init(TJINIT_DECOMPRESS)` returns a `tjhandle`; parameters are integers set and
read with `tj3Set`/`tj3Get` against `enum TJPARAM`; a decode is one call into a
caller buffer with a row `pitch` ([`turbojpeg.h`][tj-decompress]):

```c
DLLEXPORT int tj3Decompress8(tjhandle handle, const unsigned char *jpegBuf,
                             size_t jpegSize, unsigned char *dstBuf, int pitch,
                             int pixelFormat);
```

with `tj3Decompress12` and `tj3Decompress16` beside it, `tj3DecompressToYUVPlanes8`
for planar output with per-plane strides, `tj3SetScalingFactor` and
`tj3SetCroppingRegion` for the partial-decode features above, and
`tj3GetICCProfile` for colour. The caller runs `tj3DecompressHeader` first and
sizes its buffer from `TJPARAM_JPEGWIDTH` and `TJPARAM_JPEGHEIGHT`. Compression
sizes its output from `tj3JPEGBufSize`, a worst case derived from the MCU grid
([`turbojpeg.c`][tj-bufsize]):

```c
  retval = (unsigned long long)PAD(width, mcuw) * PAD(height, mcuh) *
           (2ULL + chromasf) + 2048ULL;
```

because "the JPEG format uses 16-bit coefficients, so it is possible for a very
high-quality source image with very high-frequency content to expand rather than
compress" ([`turbojpeg.h`][tj-bufsize-doc]).

Errors use `setjmp`/`longjmp`: the libjpeg `error_exit` hook jumps back into the
TurboJPEG function, and a warning jumps too when `TJPARAM_STOPONWARNING` is set
([`turbojpeg.c`][tj-error]). The last error string lives in a `THREAD_LOCAL`
buffer and in the handle.

### SIMD dispatch

The SIMD layer covers the per-pixel and per-block stages, not the entropy decoder.
[`simd/README.md`][simd-readme] lists, for decompression, the inverse DCTs
(accurate, fast, float, 2x2 and 4x4 scaled), fancy and plain upsampling, merged
upsampling and colour conversion, and YCbCr-to-RGB; for compression it also covers
Huffman _encoding_. Huffman _decoding_ is scalar C on every architecture.

Kernels exist for x86 (MMX, 3DNow!, SSE, SSE2, AVX2 in NASM), Arm (Neon
intrinsics, with AArch32 and AArch64 Huffman-encoding variants), PowerPC (AltiVec), MIPS64
(Loongson MMI) and RISC-V (RVV). Each `jsimd_set_*` function checks a few static
preconditions, probes the CPU once per decompression object, and installs the best
kernel ([`simd/jsimd.c`][jsimd-idct]):

```c
/* simd/jsimd.c, jsimd_set_idct_islow (abridged) */
  init_simd((j_common_ptr)cinfo);

  if (sizeof(JCOEF) != 2)
    return JSIMD_NONE;
  if (BITS_IN_JSAMPLE != 8)
    return JSIMD_NONE;
#if SIMD_ARCHITECTURE == X86_64 || SIMD_ARCHITECTURE == I386
  if ((cinfo->master->simd_support & JSIMD_AVX2) &&
      IS_ALIGNED_AVX(jconst_idct_islow_avx2)) {
    cinfo->idct->idct_simd = jsimd_idct_islow_avx2;
    return JSIMD_AVX2;
  }
```

The CPU probe is `jpeg_simd_cpu_support`. On x86-64 it assumes SSE2, then checks
CPUID leaf 7 for AVX2 and `xgetbv` for OS-saved YMM state
([`x86_64/jsimdcpu.asm`][jsimdcpu-x64]); on AArch64 it returns `JSIMD_NEON`
unconditionally, since "Armv8 architectures support Neon instructions by default"
([`aarch64/jsimdcpu.c`][jsimdcpu-a64]). The result is cached in
`cinfo->master->simd_support`, per object rather than in a global, and
environment variables (`JSIMD_FORCENONE`, `JSIMD_FORCESSE2`, `JSIMD_NOHUFFENC`,
`JSIMD_FORCENEON`, ...) can override it: most narrow the set, while
`JSIMD_FORCENEON` (AArch32), `JSIMD_FORCERVV` and `JSIMD_FORCEMMI` force a module
on ([`simd/jsimd.c`][jsimd-init],
[`simd/README.md`][simd-env]).

---

## Analysis

### 1. Pixel and memory model

Output is rows. `JSAMPARRAY` is an array of row pointers (`JSAMPROW *`), so the
caller chooses the layout of each row and its stride by where each pointer points.
Samples are `JSAMPLE` (`unsigned char`), `J12SAMPLE` (`short`) or `J16SAMPLE`
(`unsigned short`), interleaved in the order of `out_color_space`; the
`JCS_EXT_*` extensions add RGBX, BGRA, ARGB and the other 32-bit orders, with the
filler byte "guaranteed to be 0xFF" for the alpha variants and undefined for the
X variants ([`README.md`][readme-colorspace]). Raw output is planar and
subsampled (`JSAMPIMAGE`, one row-pointer array per component), the
[planar and semi-planar][c-planar] form that [chroma subsampling][c-chroma]
produces. TurboJPEG exposes a single contiguous buffer with a `pitch`
(`TJPARAM_BOTTOMUP` flips row order) or YUV planes with per-plane `strides`.

The internal model is block-oriented: `JBLOCK` is 64 `JCOEF` (`short`),
`JBLOCKARRAY` a row-pointer array of blocks, and a multi-scan decode keeps one
"virtual array" of blocks per component for the whole image
([`jdcoefct.c`][coef-full]). There is no image or view type: an image is a set of
row-pointer arrays plus the dimensions in `cinfo`.

**Verified**, the cost of that design difference: a 4096x4096 4:2:0 baseline file
decoded with a peak resident set of about 2 MB, the same image encoded
progressively with about 50 MB, which is the full-image coefficient buffer.

### 2. Genericity mechanism

Two mechanisms, both C. Run-time variation (colour space, upsampler, IDCT, SIMD
kernel, entropy coder) is function-pointer "objects" filled in at
`jpeg_start_decompress` ([`structure.txt`][structure-oo]). Sample width is
compile-time monomorphisation by the preprocessor: each precision-dependent file is
compiled up to three times via the `src/wrapper/*-8.c`, `-12.c`, `-16.c` shims and
`jsamplecomp.h` name mapping. The cost is visible in the API (three spellings of
every row function, `_12`/`_16` method slots in internal structs such as
`decompress_data_12`) and in the SIMD dispatch, which simply returns
`JSIMD_NONE` when `BITS_IN_JSAMPLE != 8`. There are no type-level pixel concepts;
the caller casts.

### 3. Colour and metadata

- **Colour space inference.** JPEG carries no colour space field, so
  `default_decompress_parms` guesses it from the JFIF APP0 marker, the Adobe APP14
  transform flag and, failing those, the component IDs (1,2,3 means YCbCr; ASCII
  `R`,`G`,`B` means RGB; lossless defaults to RGB). The comment is candid: "Wish
  JPEG committee had provided a real way to specify this..."
  ([`jdapimin.c`][jdapimin-cs]). Four components are CMYK or YCCK by the Adobe flag.
- **ICC.** `jpeg_read_icc_profile` reassembles the profile from APP2 chunks tagged
  `ICC_PROFILE\0`, checking sequence numbers for range, duplicates, gaps and a
  consistent count, and returns a `malloc`ed copy the caller must `free`
  ([`jdicc.c`][jdicc]). The caller must first ask for APP2 to be kept with
  `jpeg_save_markers(cinfo, JPEG_APP0 + 2, 0xFFFF)` ([`doc/libjpeg.txt`][libjpeg-icc]).
  The library does not interpret the profile. TurboJPEG extracts it during
  `tj3DecompressHeader` when `TJPARAM_SAVEMARKERS` is 2 or 4 and hands it out with
  `tj3GetICCProfile` ([`turbojpeg.h`][tj-limits]). See [ICC profile][c-icc].
- **Gamma.** `output_gamma` exists in the struct and is set to 1.0
  ([`jdapimin.c`][jdapimin-cs]); no code path applies it.
- **CICP, HDR, gain maps.** Absent. JPEG has no [CICP][c-cicp] field, and the
  Ultra HDR / ISO 21496-1 [gain map][c-gainmap] lives in APP markers (and MPF
  secondary images) that libjpeg-turbo stores as opaque bytes without
  interpretation; a grep for gain-map or MPF handling in `src/` finds none.
- **EXIF and XMP.** Not parsed by the decoder. They are APP1 markers that
  `jpeg_save_markers` keeps verbatim on `cinfo->marker_list`; the only EXIF code is
  `adjust_exif_parameters` in `transupp.c`, which rewrites `ExifImageWidth` and
  `ExifImageHeight` after a lossless crop ([`transupp.c`][transupp-exif]).

### 4. I/O and codec architecture

The decoder is **pull with suspension** in the sense of
[push and pull decoding][c-pushpull]: it pulls bytes through `fill_input_buffer`,
and a source that has none returns `FALSE` and the caller re-enters later
(see [Data source managers and suspension](#data-source-managers-and-suspension)).
Against the [incremental, progressive and suspendable][c-incremental] vocabulary:

| Capability                  | libjpeg API                                                                   | TurboJPEG 3                 |
| --------------------------- | ----------------------------------------------------------------------------- | --------------------------- |
| Incremental input           | yes, suspending source; retry from MCU start                                  | no, whole buffer            |
| Row-granular output         | yes, `jpeg_read_scanlines` (one row group at a time)                          | no, whole image             |
| Progressive display         | yes, buffered-image mode (`jpeg_start_output` per scan, `jpeg_consume_input`) | no                          |
| Region decode               | rows: `jpeg_skip_scanlines`; columns: `jpeg_crop_scanline` (iMCU-aligned)     | `tj3SetCroppingRegion`      |
| Downscaled decode           | `scale_num/scale_denom`, M/8 for M in 1..16                                   | `tj3SetScalingFactor`       |
| Planar YCbCr output         | `jpeg_read_raw_data`                                                          | `tj3DecompressToYUVPlanes8` |
| Coefficient access          | `jpeg_read_coefficients`                                                      | `tj3Transform` (internally) |
| Cancellation or time budget | only by `longjmp` from the progress monitor                                   | `TJPARAM_SCANLIMIT` only    |

There is no tile callback and no random access by restart interval: restart markers
are used only for resynchronisation after corruption (`resync_to_restart`). The
container (JFIF, Adobe, EXIF APP1) and the bitstream are not separated; marker
parsing in `jdmarker.c` is itself suspendable, macro-driven
(`INPUT_BYTE(cinfo, c, return FALSE)`), and every marker reader can return
`FALSE` mid-segment.

### 5. Hostile input and safety

**Limits and their defaults.**

| Limit                | Where                                                           | Default                                                                      |
| -------------------- | --------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Width, height        | `JPEG_MAX_DIMENSION`, checked in `jdinput.c`                    | 65500 each, "a tad under 64K to prevent overflows" ([`jmorecfg.h`][max-dim]) |
| Components           | `MAX_COMPONENTS`                                                | 10                                                                           |
| Blocks per MCU       | `D_MAX_BLOCKS_IN_MCU`                                           | 10                                                                           |
| One allocation       | `MAX_ALLOC_CHUNK`                                               | 1,000,000,000 bytes ([`jmemsys.h`][alloc-chunk])                             |
| Virtual-array memory | `cinfo->mem->max_memory_to_use`, or env var `JPEGMEM`           | 0, meaning no limit ([`jmemnobs.c`][jmemnobs])                               |
| Progressive scans    | none in the libjpeg API; `djpeg -maxscans`; `TJPARAM_SCANLIMIT` | 0, no limit ([`turbojpeg.h`][tj-scanlimit])                                  |
| Pixels               | `TJPARAM_MAXPIXELS` (TurboJPEG only)                            | 0, no limit ([`turbojpeg.h`][tj-limits])                                     |
| Intermediate memory  | `TJPARAM_MAXMEMORY`, in MB (TurboJPEG only)                     | 0, no limit                                                                  |
| Saved marker length  | `jpeg_save_markers(..., length_limit)`                          | caller-chosen, at most 65533 bytes per marker; count unbounded               |
| ICC profile          | 255 APP2 chunks                                                 | about 16 MB, bounded by the chunk sequence byte                              |

`max_memory_to_use` is "merely advisory, not a guaranteed maximum; it only affects
the space used for virtual-array buffers" ([`jpeglib.h`][jpeglib-mem]): strip
buffers, saved markers and small allocations are not counted. With the shipped
`jmemnobs.c` back end, a virtual array that does not fit fails with
`JERR_NO_BACKING_STORE`, whose message is "Memory limit exceeded"
([`jerror.h`][jerror-nobs]).

**The two format-level attacks.** The project co-authored the report that defines
them ([Commander and Markham 2016][two-issues]): "two scenarios under which they
could make the JPEG library consume resources significantly out of proportion to
the size of the data being processed", which "stem from the design of the JPEG
format itself." Its recommendations are to "Limit the number of progressive scans
permissible before the JPEG decoder exits with an error" (suggesting 1000) and to
"Limit the size of image that the decoder may decode, and check that size before
starting the decoding process." Both were reproduced here.

- **Scan flood, verified.** A 4096x4096 progressive JPEG (135,767 bytes) decoded in
  0.06 s. Appending copies of a 10-byte AC-first SOS header with no entropy data
  before the EOI, each of which the decoder accepts with a warning and then walks
  every block of the component for, gave: 100 copies, 0.18 s; 1,000 copies,
  1.18 s; 10,000 copies (235,767 bytes), 10.71 s. Time grows linearly with
  scans at roughly a millisecond per 10 bytes. `djpeg -maxscans 50` stopped the
  1,000-scan file in 0.09 s with "Scan number 51 exceeds maximum scans (50)".
- **Header bomb, verified.** Patching the SOF2 of a 5,655-byte progressive file to
  65500x65500 makes `jpeg_start_decompress` request a coefficient buffer of many
  gigabytes. With `djpeg -maxmemory 64M`, or `JPEGMEM=64M`, it failed at once with
  "Memory limit exceeded"; under `ulimit -v` of 4 GB with no library limit it failed
  with "Insufficient memory (case 4)", meaning the allocation was attempted. The
  unlimited case was not run.

`TJPARAM_SCANLIMIT` is implemented as a progress-monitor callback that `longjmp`s
out when `input_scan_number` exceeds the limit ([`turbojpeg.c`][tj-progress]), and
`TJPARAM_MAXPIXELS` as a width-times-height check after the header
([`turbojpeg.c`][tj-decomp-setup]). Both are opt-in; the deprecated `TJFLAG_LIMITSCANS`
flag set the limit to 500.

**Leniency is the default.** Truncation becomes a fake EOI plus grey fill;
corrupt Huffman codes are warnings (`JWRN_HUFF_BAD_CODE`); progression errors are
warnings. Strictness is the caller's: `djpeg -strict` and `TJPARAM_STOPONWARNING`
turn warnings into errors.

**CVE history.** The [`ChangeLog.md`][changelog] names twenty distinct CVEs. Their
distribution is the finding: the core entropy and IDCT paths rarely appear; the
flaws cluster in the combinatorial edges of the option space and in the sample
programs' file loaders.

- [CVE-2013-6629][nvd-2013-6629]: `get_sos` "does not check for certain
  duplications of component data during the reading of segments that follow Start
  Of Scan (SOS) JPEG markers, which allows remote attackers to obtain sensitive
  information from uninitialized memory" (NVD). The fix is the "This CSi (cc)
  should differ from the previous CSi" loop now in [`jdmarker.c`][get-sos]: a
  per-scan uniqueness invariant that a schema for markers must express.
- [CVE-2020-35538][nvd-2020-35538]: a null dereference in `jcopy_sample_rows` via
  `jpeg_skip_scanlines` with merged (non-fancy) 4:2:2 or 4:2:0 upsampling
  ([`ChangeLog.md`][changelog-skip]). With CVE-2017-15232 (skip plus colour
  quantization) and item 9 of 3.2.1 (wrong rows skipped with merged upsampling),
  row skipping is the most repeatedly broken feature.
- [CVE-2023-2804][nvd-2023-2804]: a heap overflow in
  `h2v2_merged_upsample_internal` from "out-of-range 12-bit samples" in a lossless
  image decoded with merged upsampling (NVD). The ChangeLog's diagnosis: the
  quantization and merged-upsampling algorithms "were not designed with lossless
  decompression in mind" ([`ChangeLog.md`][changelog-2804]). A 12- or 16-bit
  sample type wider than the sample range lets a decoder emit values that later
  stages index tables with.

The 3.2.1 entries continue the pattern: a crop of a 4:2:0 image that leaves a
component plane 1 or 2 samples wide, with merged upsampling and SIMD disabled, and
a division by zero (CVE-2026-75466) in the PNG loader of `tj3LoadImage*`
([`ChangeLog.md`][changelog-321]; the [NVD record][nvd-2026-75466] names
`tj3LoadImage12()` and `tj3LoadImage16()`).

### 6. Allocation and ownership

All library memory comes from the per-object memory manager in pools
(`JPOOL_PERMANENT`, `JPOOL_IMAGE`) that are freed whole, never piecewise:
"The memory manager does not allow individual objects to be freed; rather, each
created object is assigned to a pool, and whole pools can be freed at once"
([`jpeglib.h`][jpeglib-mem]). `alloc_small` and `alloc_large` never return NULL;
they exit through `error_exit`. The caller owns output rows; the library owns
everything between steps. The two exceptions to pool ownership are the ICC profile
(`malloc`, caller `free`s) and TurboJPEG's `tj3Alloc`/`tj3Free` buffers, which the
library may reallocate unless `TJPARAM_NOREALLOC` is set.

Error recovery is `longjmp` out of arbitrarily deep C frames, after which the only
safe operations are `jpeg_abort` or `jpeg_destroy`; pool ownership is what makes
that leak-free. A comment in `tj3DecompressHeader` shows the hazard of a caller
that ignores the error and reuses the handle: the stale dimensions "might cause the
misbehaved application to allocate too small of a buffer"
([`turbojpeg.c`][tj-hardening]).

### 7. CPU parallelism and SIMD

There is no threading in the codec (a grep of `src/` and `simd/` for `pthread` and
OpenMP finds only the vendored `src/spng/spng.c`, behind `SPNG_MULTITHREADING`,
which nothing in the tree defines). One object decodes on one thread; parallelism
is the application's, across images. A single baseline JPEG without restart markers is
a serial Huffman stream, which is why no decoder can split it without speculation
(see the [GPU decode papers][p-gpu-decode]).

SIMD is per-stage, hand-written per instruction set, and selected at run time per
decompression object (see [SIMD dispatch](#simd-dispatch)). The test suite runs
the same bit-exact MD5 expectations with `JSIMD_FORCESSE2=1` and
`JSIMD_FORCENONE=1` in CI ([`build.yml`][ci-simd]), so the integer SIMD kernels
must match the C code bit for bit; only the floating-point DCT has separate
expected outputs per platform (`FLOATTEST8`, [`CMakeLists.txt`][cmake-float]).
The crop alignment rule and the "X byte is undefined" output convention are both
SIMD constraints leaking into the API. MSan and Valgrind report false positives on
SIMD paths, worked around with `JSIMD_FORCENONE` or `-DZERO_BUFFERS=1`
([`README.md`][readme-memdbg]).

### 8. GPU offload and interop

None. libjpeg-turbo has no GPU path and no hook for one. The parts a GPU decoder
would take (IDCT, upsampling, colour conversion) are exactly the SIMD-covered
stages, and `jpeg_read_raw_data` or `jpeg_read_coefficients` are the seams where a
host decoder could hand YCbCr planes or coefficients to a compute or Vulkan Video
stage; nothing in the tree does so.

### 9. Temporal, animation and containers

Not applicable: JPEG is a still-image format and the library decodes one image per
datastream. Motion-JPEG frames, MPF multi-picture files and the secondary image of
an Ultra HDR file are separate JPEG datastreams that an outer container parser must
locate and feed individually. Abbreviated datastreams (tables-only and image-only,
`JPEG_HEADER_TABLES_ONLY`) are supported for formats such as TIFF that store tables
once ([`doc/libjpeg.txt`][libjpeg-scope]).

### 10. Testing and conformance

- **Bit-exact regression.** `add_bittest` runs a tool and compares the output's MD5
  with a constant in `CMakeLists.txt` ([`CMakeLists.txt`][cmake-bittest]), across
  `cjpeg`, `djpeg` and `jpegtran` for every subsampling, DCT, precision, scaling,
  crop and skip combination, plus `tjunittest` and `tjbench` tile tests. The corpus
  is small and in-tree (`testimages/`, for example `testorig.jpg`,
  `testimgari.jpg`, `monkey12.jpg` and two ICC profiles). There is no ISO/IEC
  10918-2 compliance bitstream suite in the tree; "reference implementation" standing is asserted in
  the README, not exercised by a test.
- **Sanitizers in CI.** One job builds with
  `-fsanitize=address,undefined -fno-sanitize-recover=all` and another with
  `-fsanitize=memory -DZERO_BUFFERS=1`; the ASan job runs `ctest` at three SIMD
  levels (default, `JSIMD_FORCESSE2=1`, `JSIMD_FORCENONE=1`), the MSan job once
  ([`build.yml`][ci-simd]).
- **Fuzzing.** In-tree libFuzzer targets for OSS-Fuzz
  ([`fuzz/build.sh`][fuzz-build]): `libjpeg_turbo` (named so "to preserve the
  corpora from Google's OSS-Fuzz target", [`fuzz/CMakeLists.txt`][fuzz-cmake]),
  `decompress_libjpeg`, `decompress_yuv`, `transform`, `cjpeg` and six compress
  targets, with a shared `jpeg.dict`. The decompress target iterates five pixel
  formats and exercises bottom-up output, fast upsampling and DCT, 1/2 and 1/8
  scaling and cropping on chosen iterations ([`fuzz/decompress.cc`][fuzz-decompress]).
  It also caps itself: images over one megapixel are skipped and
  `TJPARAM_SCANLIMIT` is 100 (50 for lossless). So the fuzzer cannot reach the
  resource attacks above, or behaviour that only appears past 1 MP.
- **Fuzz-shaped production code.** `tj3DecompressHeader` behaves differently under
  `FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION` so that malformed headers still reach
  the decoder ([`turbojpeg.c`][tj-hardening]).

---

## Lessons for Sparkles

- **Q4.** The `jpeg_source_mgr` contract is a working model of suspendable
  decoding without coroutines: the decoder keeps a resumable position (the start
  of the current MCU or marker), the source returns "no data", and the caller
  retries with the unconsumed bytes intact. It transfers to a D decoder as a
  `@nogc nothrow` step function returning a `needMoreInput` result instead of a
  `FALSE` sentinel, with the retry window explicit in the type. What does not
  transfer is `setjmp`/`longjmp` errors and `skip_input_data`'s side-channel
  bookkeeping, which the IJG authors themselves call "rather baroque". The
  [event-horizon baseline][bl-eh] says what the I/O side offers.
- **Q4.** The fast/slow Huffman split is the part a D reimplementation must copy
  deliberately: prove a slack window (`BUFSIZE * blocks_in_MCU` bytes, no pending
  marker) once per MCU, run an unchecked inner loop, and fall back to a checked
  reader near markers and the end of input. In `@safe` D the fast loop can index a
  slice whose length was checked before the loop, so the bounds checks the
  compiler cannot hoist are the ones to measure. The relevant entropy decoding
  literature is in the [entropy-coding papers][p-entropy].
- **Q4, Q8.** Resource limits must be on by default and enforced before
  allocation. libjpeg-turbo's are all zero (unlimited) by default, split between
  two APIs, and the memory limit covers only virtual arrays. The verified scan
  flood (10 KB of headers adding about a second of work, 100 KB about ten) and
  header bomb argue for a Sparkles `DecodeLimits` value with non-zero defaults for
  pixels, scans, coefficient-buffer bytes, saved-marker bytes and count, checked at
  `readHeader` and at each SOS. [`zune-jpeg`][zune] defaults `max_scans` to 100;
  [Wuffs][wuffs] makes its memory bounds structural (a 24-bit dimension cap, exact
  work-buffer sizes) but has no work budget; the [hostile-input papers][p-hostile]
  cover the attack classes. Where Sparkles stands (`maxPngPixels` only) is in the
  [existing-code baseline][bl-existing] (G7).
- **Q4.** The CVE record says where a JPEG decoder breaks: not the Huffman core but
  option combinations (skip plus merged upsampling, a crop that leaves a 1- or
  2-sample component plane, lossless plus colour quantization or merged
  upsampling) and value ranges wider than the sample range. A D decoder that does
  not offer merged upsampling or colour quantization removes whole classes; one
  that clamps or types samples by precision removes CVE-2023-2804's class. Uniqueness constraints such as `get_sos`'s distinct
  component IDs belong in the `sparkles:wired` marker description; the
  [wired baseline][bl-wired] records that wired cannot yet describe binary data at
  all (G1), and that its shipped `@WireCheck` cross-field checks run only in the
  JSON and SDL codecs.
- **Q1.** Row-pointer arrays let the caller place every row anywhere, which serves
  bottom-up buffers and strided views without a view type, but do not state a
  single byte [stride][c-stride] that SIMD or a GPU upload can rely on. A Sparkles
  pixel view with an explicit stride covers both; the raw-planes and
  coefficient-array outputs show which non-RGB results a decoder must be able to
  return (subsampled YCbCr planes, quantized blocks).
- **Q2, Q3.** Compiling one source three times for 8, 12 and 16 bits is what D
  templates do natively: `decode!(ubyte)`, `decode!(ushort)` instantiated by
  design by introspection, with no triplicated public API. The SIMD half does not
  transfer as written: libjpeg-turbo maintains hand-written NASM per ISA (SSE2 and
  AVX2 twice over), and simply has no SIMD for 12-bit. The BLAKE3 pattern in the
  [shaders and SIMD baseline][bl-shaders] (one generic-vector kernel, instantiated
  per `@target`) is the D counterpart; its gap G5 (no shared dispatch API) is what
  `jsimd_set_*` illustrates per stage.
- **Q3, Q8.** Requiring SIMD kernels to be bit-exact with the scalar code, and
  running the same MD5 expectations under `JSIMD_FORCENONE` and `JSIMD_FORCESSE2`,
  gives a cheap and strong oracle. A Sparkles decoder can adopt the same rule (the
  integer IDCT is specified exactly enough) and test the scalar, `sse4.1` and
  `avx2` instantiations against one expected output, and against libjpeg-turbo
  itself as the differential oracle.
- **Q5.** JPEG gives the minimum colour model a decoder must report even when the
  file states nothing: an inferred encoding (YCbCr, RGB, CMYK, YCCK) with its
  provenance (JFIF, Adobe flag, component IDs), an optional ICC profile
  reassembled from chunks with validated sequencing, and the raw APP1 bytes for
  EXIF and XMP. Gain maps and MPF need a container layer above the codec. The
  [ICC][c-icc] and [gain map][c-gainmap] concepts define the terms.
- **Q6, Q7.** The SIMD-covered stages (IDCT, upsampling, colour conversion) are the
  GPU candidates; the Huffman stream is not, unless restart intervals exist. A D
  decoder that exposes coefficient or raw-plane output, as `jpeg_read_coefficients`
  and `jpeg_read_raw_data` do, has the seam a compute stage needs.
- **Q8.** The fuzz harness's own caps (1 MP, 100 scans) are a reminder that fuzzing
  and resource limits interact: a Sparkles fuzz target should run with the
  production default limits, and a separate test should assert that the limits
  fire, as the scan-flood and header-bomb inputs here do. These two crafted files
  are small enough to keep as regression inputs.
- **Q9.** libjpeg-turbo bundles the codec with sample-program loaders (BMP, PPM,
  Targa, GIF, PNG via an in-tree `spng` and zlib) and a whole-image convenience API,
  and several CVEs sit in that periphery (CVE-2018-11813, CVE-2020-13790,
  CVE-2026-75466). That is evidence for keeping each codec package free of other
  formats' readers, with conversion tools in a separate layer.
- **Q4 (betterC, wasm, Android).** The library's portability comes from C89-style
  code over a small slice of the C runtime (allocation, `memcpy`/`memset`, `getenv`
  and `sscanf` for `JPEGMEM`, `snprintf` and `fprintf` for error messages, and
  `fread`/`fwrite` only in the `stdio` source and destination managers), with
  every SIMD path optional at build time (`WITH_SIMD=0`). The analogue for a D
  codec is a core that needs no GC, no exceptions and no `std.stdio`, so the same module builds under
  `-betterC` and for wasm; `getenv`-based tuning (`JPEGMEM`, `JSIMD_*`) has no
  place there and conflicts with Sparkles' preference for explicit options.

## Strengths

- Mature, widely deployed, and the standard's reference implementation; its output
  is the de facto expectation for "correct" JPEG decoding.
- Every useful partial decode: DCT scaling, row skipping, column cropping, raw
  planes, coefficient access, buffered progressive display.
- A real suspension protocol that lets one decoder serve blocking files, memory
  buffers and network streams.
- SIMD on seven target architectures in five families (x86, Arm, PowerPC, MIPS64,
  RISC-V), chosen at run time per object, with bit-exact integer kernels tested against the scalar code in CI.
- ASan and UBSan CI at three SIMD levels, MSan CI, and in-tree OSS-Fuzz targets covering decode,
  YUV decode, transform and encode.
- Clear documentation of internals (`structure.txt`), of mathematical differences
  from libjpeg, and of what counts as a vulnerability.

## Weaknesses

- All resource limits are off by default; scan and pixel limits exist only in
  TurboJPEG, and the libjpeg memory limit counts only virtual arrays.
- Lenient by default: truncated and corrupt data decode to grey with a warning,
  so a caller that ignores warnings cannot tell a damaged image from a good one.
- `setjmp`/`longjmp` error handling and function-pointer objects make the control
  flow hard to verify and impossible to express in a type-safe API directly.
- The option space multiplies code paths (merged upsampling, quantization, skip,
  crop, precisions), and most CVEs live in those combinations.
- No SIMD for Huffman decoding, 12-bit or lossless; restart markers force the slow
  entropy path.
- No metadata parsing beyond ICC reassembly; no CICP, HDR or gain-map awareness;
  `output_gamma` is vestigial.
- Fuzz targets cap image size and scan count, leaving large-image behaviour
  unexplored by fuzzing.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                         | Trade-off                                                                                |
| ---------------------------------------------------------------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Keep libjpeg v6b API, ABI and output                             | Drop-in replacement for the installed base                        | Exposed structs cannot grow; v7/v8/v9 features are emulated or refused                   |
| Function-pointer "objects" chosen at start-up                    | Portable C, no switch clutter, cheap SIMD substitution            | Indirect calls everywhere; behaviour depends on run-time combination of modules          |
| Suspension by "return FALSE and retry from MCU start"            | Incremental input without threads or saved stacks                 | Re-decoding on resume; no bound on work per call; `skip_input_data` side channel         |
| Strip buffers, full-image coefficient buffer only for multi-scan | Memory proportional to width for baseline files                   | Progressive files need memory proportional to area (verified 2 MB vs 50 MB at 4096x4096) |
| Fast Huffman path gated on 512 bytes per block of slack          | No bounds checks in the hot loop                                  | Restart markers and buffer tails take the slow path (up to 20% slower per the README)    |
| Lenient decoding with warnings                                   | Show something for damaged files, as viewers want                 | Callers must opt into strictness; grey fill hides corruption                             |
| Resource limits opt-in, mostly in TurboJPEG                      | Legal files can be large; the right limit is application-specific | The default decoder is exploitable for CPU and memory exhaustion by conforming files     |
| Precision by recompiling sources with `BITS_IN_JSAMPLE`          | Reuse one implementation for 8/12/16 bits in C                    | Triplicated API surface; SIMD and arithmetic coding left 8-bit only                      |
| Hand-written SIMD per ISA, bit-exact with C                      | Peak speed and a simple, strong test oracle                       | Large per-ISA code base (NASM, intrinsics); new ISAs mean new kernels                    |

## Sources

- [libjpeg-turbo/libjpeg-turbo repository][repo], read at
  `7b4993786d856cbccabfc0ed2f923ba000e326cc`
- [`README.md` — background][readme-bg]; [two APIs][readme-apis];
  [colour-space extensions][readme-colorspace]; [IDCT scaling][readme-scaling];
  [restart markers][readme-restart]; [memory debuggers][readme-memdbg];
  [mathematical compatibility][readme-math]
- [`doc/libjpeg.txt` — scope][libjpeg-scope]; [data precision][libjpeg-precision];
  [partial decompression][libjpeg-partial]; [`scale_num`][libjpeg-scale];
  [I/O suspension][libjpeg-susp]; [ICC profiles][libjpeg-icc]; [memory][libjpeg-mem]
- [`doc/structure.txt` — system overview][structure-overview];
  [object-style programming][structure-oo]
- [`src/jpeglib.h` — decompression struct][jpeglib-dstruct]; [source manager][jpeglib-src];
  [memory manager][jpeglib-mem]; [entry points][jpeglib-entry]
- [`src/jdatasrc.c` — fake EOI][jdatasrc-eoi]; [`src/jdhuff.h`][jdhuff-h];
  [`src/jdhuff.c` — zero fill][jdhuff-zero]; [fast/slow dispatch][jdhuff-dispatch];
  [`decode_mcu_fast`][jdhuff-fast]
- [`src/jdphuff.c` — scan validation][jdphuff-validate]; [`src/jdlossls.c`][jdlossls];
  [`src/jdcoefct.c` — full-image buffer][coef-full]
- [`src/wrapper/jdapistd-12.c`][wrapper-12]; [`src/jsamplecomp.h`][jsamplecomp]
- [`src/jdapistd.c` — `jpeg_start_decompress`][start-decomp]; [row skipping][skip-impl];
  [crop alignment][crop-align]; [raw data][raw-data]
- [`src/jdapimin.c` — colour-space inference][jdapimin-cs]; [`src/jdicc.c`][jdicc];
  [`src/jdmarker.c` — `get_sos`][get-sos]; [`src/transupp.c` — EXIF][transupp-exif]
- [`src/jmorecfg.h` — `JPEG_MAX_DIMENSION`][max-dim]; [`src/jmemsys.h`][alloc-chunk];
  [`src/jmemnobs.c`][jmemnobs]; [`src/jmemmgr.c` — `JPEGMEM`][jpegmem];
  [`src/jerror.h`][jerror-nobs]
- [`src/turbojpeg.h` — `TJPARAM_SCANLIMIT`][tj-scanlimit]; [memory, pixel and marker
  parameters][tj-limits]; [`tj3JPEGBufSize`][tj-bufsize-doc]; [`tj3Decompress8`][tj-decompress]
- [`src/turbojpeg.c` — error manager][tj-error]; [scan-limit monitor][tj-progress];
  [`tj3JPEGBufSize`][tj-bufsize]; [header hardening][tj-hardening];
  [decompression set-up][tj-decomp-setup]
- [`simd/README.md` — coverage][simd-readme]; [dispatcher and overrides][simd-env];
  [`simd/jsimd.c` — `init_simd`][jsimd-init]; [`jsimd_set_idct_islow`][jsimd-idct];
  [`simd/x86_64/jsimdcpu.asm`][jsimdcpu-x64]; [`simd/arm/aarch64/jsimdcpu.c`][jsimdcpu-a64]
- [`fuzz/build.sh`][fuzz-build]; [`fuzz/CMakeLists.txt`][fuzz-cmake];
  [`fuzz/decompress.cc`][fuzz-decompress]
- [`CMakeLists.txt` — `add_bittest`][cmake-bittest]; [`FLOATTEST8`][cmake-float];
  [`.github/workflows/build.yml` — sanitizer jobs][ci-simd]; [`.github/SECURITY.md`][security]
- [`ChangeLog.md`][changelog]; [3.2.1 entries][changelog-321]; [CVE-2023-2804][changelog-2804];
  [CVE-2020-35538][changelog-skip]
- D. R. Commander and G. Markham, [Two Issues with the JPEG Standard][two-issues] (2016)
- NVD: [CVE-2013-6629][nvd-2013-6629], [CVE-2020-35538][nvd-2020-35538],
  [CVE-2023-2804][nvd-2023-2804], [CVE-2026-75466][nvd-2026-75466]
- [TurboJPEG API documentation][tj-docs]
- Related deep-dives: [zune-image][zune], [stb_image][stb], [image-rs][image-rs],
  [Wuffs][wuffs];
  concepts: [push and pull decoding][c-pushpull], [hostile input][c-hostile]

<!-- References -->

[repo]: https://github.com/libjpeg-turbo/libjpeg-turbo/tree/7b4993786d856cbccabfc0ed2f923ba000e326cc
[license]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/LICENSE.md
[tj-docs]: https://libjpeg-turbo.org/Documentation/Documentation
[readme-bg]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/README.md#L1-L23
[readme-apis]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/README.md#L57-L88
[readme-colorspace]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/README.md#L89-L136
[readme-scaling]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/README.md#L171-L175
[readme-restart]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/README.md#L343-L354
[readme-memdbg]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/README.md#L369-L381
[readme-math]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/README.md#L286-L318
[libjpeg-txt]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/doc/libjpeg.txt
[libjpeg-scope]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/doc/libjpeg.txt#L97-L112
[libjpeg-precision]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/doc/libjpeg.txt#L114-L169
[libjpeg-partial]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/doc/libjpeg.txt#L811-L905
[libjpeg-scale]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/doc/libjpeg.txt#L1380-L1385
[libjpeg-susp]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/doc/libjpeg.txt#L1874-L1990
[libjpeg-icc]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/doc/libjpeg.txt#L2825-L2858
[libjpeg-mem]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/doc/libjpeg.txt#L3166-L3190
[structure]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/doc/structure.txt
[structure-overview]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/doc/structure.txt#L83-L132
[structure-oo]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/doc/structure.txt#L166-L200
[tjh]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/turbojpeg.h
[jpeglib-dstruct]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jpeglib.h#L522-L560
[jpeglib-src]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jpeglib.h#L863-L874
[jpeglib-mem]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jpeglib.h#L877-L939
[jpeglib-entry]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jpeglib.h#L1062-L1112
[jdatasrc-eoi]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdatasrc.c#L124-L143
[jdhuff-h]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdhuff.h#L25-L51
[jdhuff-zero]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdhuff.c#L355-L375
[jdhuff-dispatch]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdhuff.c#L767-L806
[jdhuff-fast]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdhuff.c#L663-L749
[jdphuff-validate]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdphuff.c#L82-L146
[jdlossls]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdlossls.c#L35-L95
[coef-full]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdcoefct.c#L885-L911
[wrapper-12]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/wrapper/jdapistd-12.c
[jsamplecomp]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jsamplecomp.h
[start-decomp]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdapistd.c#L54-L97
[skip-impl]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdapistd.c#L495-L710
[crop-align]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdapistd.c#L222-L252
[raw-data]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdapistd.c#L717-L756
[jdapimin-cs]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdapimin.c#L140-L226
[jdicc]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdicc.c#L22-L167
[get-sos]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jdmarker.c#L336-L364
[transupp-exif]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/transupp.c#L2018-L2030
[max-dim]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jmorecfg.h#L158
[alloc-chunk]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jmemsys.h#L51-L63
[jmemnobs]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jmemnobs.c#L65-L104
[jpegmem]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jmemmgr.c#L1264-L1286
[jerror-nobs]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/jerror.h#L114
[tj-scanlimit]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/turbojpeg.h#L773-L790
[tj-limits]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/turbojpeg.h#L992-L1053
[tj-bufsize-doc]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/turbojpeg.h#L1437-L1464
[tj-decompress]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/turbojpeg.h#L2101-L2103
[tj-error]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/turbojpeg.c#L60-L97
[tj-progress]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/turbojpeg.c#L162-L188
[tj-bufsize]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/turbojpeg.c#L990-L1021
[tj-hardening]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/turbojpeg.c#L1993-L2023
[tj-decomp-setup]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/src/turbojpeg.c#L2310-L2330
[simd-readme]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/simd/README.md#L1-L70
[simd-env]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/simd/README.md#L72-L110
[jsimd-init]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/simd/jsimd.c#L50-L112
[jsimd-idct]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/simd/jsimd.c#L1151-L1192
[jsimdcpu-x64]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/simd/x86_64/jsimdcpu.asm#L20-L80
[jsimdcpu-a64]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/simd/arm/aarch64/jsimdcpu.c#L27-L34
[fuzz-build]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/fuzz/build.sh
[fuzz-cmake]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/fuzz/CMakeLists.txt#L66-L69
[fuzz-decompress]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/fuzz/decompress.cc#L40-L135
[cmake-bittest]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/CMakeLists.txt#L1356-L1377
[cmake-float]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/CMakeLists.txt#L1081-L1142
[ci-simd]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/.github/workflows/build.yml#L189-L291
[security]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/.github/SECURITY.md#L9-L16
[changelog]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/ChangeLog.md
[changelog-321]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/ChangeLog.md#L33-L60
[changelog-2804]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/ChangeLog.md#L716-L726
[changelog-skip]: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/7b4993786d856cbccabfc0ed2f923ba000e326cc/ChangeLog.md#L1305-L1316
[two-issues]: https://libjpeg-turbo.org/pmwiki/uploads/About/TwoIssueswiththeJPEGStandard.pdf
[nvd-2013-6629]: https://nvd.nist.gov/vuln/detail/CVE-2013-6629
[nvd-2020-35538]: https://nvd.nist.gov/vuln/detail/CVE-2020-35538
[nvd-2023-2804]: https://nvd.nist.gov/vuln/detail/CVE-2023-2804
[nvd-2026-75466]: https://nvd.nist.gov/vuln/detail/CVE-2026-75466
[zune]: ./zune-image.md
[stb]: ./stb-image.md
[image-rs]: ./image-rs.md
[wuffs]: ./wuffs.md#_5-hostile-input-and-safety
[c-planar]: ./concepts.md#interleaved-planar-and-semi-planar
[c-chroma]: ./concepts.md#chroma-subsampling
[c-stride]: ./concepts.md#stride
[c-cicp]: ./concepts.md#cicp
[c-icc]: ./concepts.md#icc-profile
[c-gainmap]: ./concepts.md#hdr-gain-map
[c-pushpull]: ./concepts.md#push-and-pull-decoding
[c-incremental]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[c-hostile]: ./concepts.md#hostile-input
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-wired]: ./baseline/wired.md
[bl-eh]: ./baseline/event-horizon.md
[p-hostile]: ./papers/hostile-input-safety.md
[p-entropy]: ./papers/entropy-codecs.md
[p-gpu-decode]: ./papers/gpu-decode-streaming.md
