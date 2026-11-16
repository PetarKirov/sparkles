# libyuv (C++)

Chromium's YUV and RGB conversion, scaling and rotation library: a FourCC-named
format vocabulary over raw plane pointers and strides, a handful of fixed-point
matrix tables, and one row function per format pair and SIMD level, picked at run
time; the optional colour-conversion back end of libavif and a pinned dependency
of Chromium ([`DEPS`][chromium-deps]) and Skia ([`DEPS`][skia-deps]).

| Field         | Value                                                                                                                                                          |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++ compiled as a C API (`extern "C"`, `namespace libyuv`); x86 kernels are GCC inline assembly (MSVC intrinsics in `row_win.cc`), Arm kernels inline assembly |
| License       | BSD-3-Clause ([`LICENSE`][license]) plus a patent grant ([`PATENTS`][patents])                                                                                 |
| Repository    | [chromium.googlesource.com/libyuv/libyuv][upstream], read through the GitHub mirror [lemenkov/libyuv][repo]                                                    |
| Revision read | `205022c08c96da668cf0ed919f42e147dddd0bd0` (October 26, 2026; [`version.h`][version] `LIBYUV_VERSION 1975`)                                                    |
| Documentation | [`docs/`][docs]: [`formats.md`][formats], [`filtering.md`][filtering], [`rotation.md`][rotation-doc], [`environment_variables.md`][env-doc]                    |
| Category      | GPU and SIMD                                                                                                                                                   |
| Tier          | B                                                                                                                                                              |
| Last reviewed | November 7, 2026                                                                                                                                               |

> [!NOTE]
> Four behaviours were **verified** by building the pinned `include/` and `source/`
> trees (x86 and portable files only) with Clang 21.1.7 and AddressSanitizer in a
> scratch directory and running small programs on an AMD Ryzen 9 7940HX: the byte
> order of "ARGB", the accuracy of the BT.601 matrix over all 16,777,216 YUV triples
> on the SIMD and C paths, the `ScalePlane` dimension ceiling, and an over-read in
> `ConvertToI420` on a truncated frame. All four were re-run on the same machine with
> GCC 16.2.0 and AddressSanitizer from a fresh export of the pinned tree, with the same
> results. Everything else is read from source.

---

## Overview

### What it solves

Capture devices, codecs and displays disagree about pixel layout. A webcam hands out
`YUY2` or `MJPG`, a video encoder wants `I420`, a renderer wants 32-bit RGB, and
a phone held upright needs a 90-degree rotation. libyuv converts between these
layouts, scales planes, and rotates, fast enough to run per frame in a video call.
It reduces the conversion matrix of _n_ formats to two hubs ([`formats.md`][formats-core]):

> _"There are 2 core formats supported by libyuv - I420 and ARGB.
> All YUV formats can be converted to/from I420.
> All RGB formats can be converted to/from ARGB."_

The library is not a codec (MJPEG decoding is delegated to libjpeg when built with
`HAVE_JPEG`), has no image type, and knows nothing of files, metadata or transfer
functions. It is a set of about 480 `LIBYUV_API` free functions over pointers
(529 `LIBYUV_API` tokens in `include/`, less the macro's own definitions and 38
exported constant tables).

### Design philosophy

Speed first, with safety stated as avoiding faults rather than validating input
([`filtering.md`][filtering]):

> _"An emphasis on maximum performance while avoiding memory exceptions, and minimal
> amount of code/complexity."_

Every public function has the same shape: per-plane `const uint8_t*` plus `int`
stride for the source, the same for the destination, then `width` and `height`,
and a negative `height` meaning "flip vertically". The function validates only that
pointers are non-null, `width` is positive and `height` is non-zero (and not
`INT_MIN`); it never receives a buffer length.

---

## How it works

### The FourCC vocabulary

A FourCC is four characters packed into a `uint32_t` with the first character in
the **low** byte ([`video_common.h`][fourcc-macro]):

```c
// include/libyuv/video_common.h
#define FOURCC(a, b, c, d)                                     \
  (((uint32_t)(a)) | ((uint32_t)(b) << 8) |       /* NOLINT */ \
   ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24)) /* NOLINT */
```

The `FourCC` enum ([`video_common.h`][fourcc-enum]) groups its entries by role:
15 primary YUV formats (planar `I420`, `I422`, `I444`, `I400`; biplanar `NV12`,
`NV21`, `NV16`, `NV24`, `P010`, `P210`, `P410`; packed `YUY2`, `UYVY`; 10-bit
`I010`, `I210`), 13 primary RGB formats (`ARGB`, `BGRA`, `ABGR`, `RGBA`, the 10-bit
`AR30`/`AB30`, 16-bit `AR64`/`AB64`, `24BG`, `raw `, and 16-bit `RGBP`, `RGBO`,
`R444`), `MJPG`, then "auxiliary" variants and aliases. `CanonicalFourCC` folds
aliases (`IYUV`, `YU12`, Apple's `2vuy` and `yuvs`, the V4L2 `RGB3`) onto the
canonical code.

The first letter of a YUV name encodes the matrix and range, which FourCC
registries do not ([`formats.md`][formats-colour]):

| Letter | Meaning (libyuv's convention)       | Example        |
| ------ | ----------------------------------- | -------------- |
| `I`    | BT.601 limited range                | `I420ToARGB`   |
| `J`    | BT.601 full range ("J = JPEG")      | `J420ToARGB`   |
| `H`    | BT.709 limited range ("H for HD")   | `H420ToARGB`   |
| `F`    | BT.709 full range                   | `F420`         |
| `U`    | BT.2020 limited range ("U for UHD") | `U420ToARGB`   |
| `V`    | BT.2020 full range                  | `kYuvV2020...` |

`formats.md` marks `J420`, `H420`, `U420` and their siblings as "unofficial fourcc".
The trailing digits are the subsampling ([concepts: chroma subsampling][c-chroma]);
for high-bit-depth formats `I010` keeps samples in the **low** 10 bits of a
`uint16_t` while `P010` keeps them in the **high** bits ([`formats.md`][formats-hdr]).

### "ARGB" is B, G, R, A in memory

RGB names describe a **register**, not memory ([`formats.md`][formats-argb]):

> _"If you were to read ARGB pixels as uint32_t's, the alpha would be in the high
> byte, and the blue in the lowest byte. In memory, these are stored little endian,
> so 'B' is first, then 'G', 'R' and 'A' last."_

So libyuv `ARGB` is Vulkan `VK_FORMAT_B8G8R8A8_UNORM` and DRM `DRM_FORMAT_ARGB8888`,
and libyuv `ABGR` is `VK_FORMAT_R8G8B8A8_UNORM`. `RGB24` stores B, G, R and `RAW`
stores R, G, B, so the 24-bit names follow the same word-order rule even though no
24-bit register exists. This is the word-order convention of
[concepts: pixel format names and byte order][c-names]; the scratch program printed
`FOURCC_ARGB = 0x42475241` and, for a full-range red pixel through `J444ToARGB`, the
bytes `0 0 255 255`.

### Conversion matrices: `YuvConstants`

A matrix is a pointer to an opaque, architecture-shaped table. On x86 it holds
32-byte broadcast vectors ready for `pmaddubsw`; on Arm and RISC-V a compact
coefficient vector plus pre-folded biases ([`row.h`][yuvconstants-struct]):

```c
// include/libyuv/row.h (x86 branch)
struct YuvConstants {
  uint8_t kUVToB[32];
  uint8_t kUVToG[32];
  uint8_t kUVToR[32];
  int16_t kYToRgb[16];
  int16_t kYBiasToRgb[16];
};
```

Twelve tables are exported ([`convert_argb.h`][yuvconstants-decl]):
`kYuvI601Constants`, `kYuvJPEGConstants`, `kYuvH709Constants`, `kYuvF709Constants`,
`kYuv2020Constants`, `kYuvV2020Constants`, and a `kYvu...` mirror of each. All are
generated by one macro from six integers in 6-bit fixed point
([`row_common.cc`][make-constants], [`row_common.cc`][bt601-constants]):

```c
// source/row_common.cc
// BT.601 limited range YUV to RGB reference
#if defined(LIBYUV_UNLIMITED_DATA) || defined(LIBYUV_UNLIMITED_BT601)
#define UB 129 /* round(2.018 * 64) */
#else
#define UB 128 /* max(128, round(2.018 * 64)) */
#endif
#define UG 25  /* round(0.391 * 64) */
#define VG 52  /* round(0.813 * 64) */
#define VR 102 /* round(1.596 * 64) */
#define YG 18997 /* round(1.164 * 64 * 256 * 256 / 257) */
#define YB -1160 /* 1.164 * 64 * -16 + 64 / 2 */
MAKEYUVCONSTANTS(I601, YG, YB, UB, UG, VG, VR)
```

The `kYvu` mirror swaps the U and V coefficients, so one row function serves both
channel orders: `I420ToABGR` is `I420ToARGBMatrix` with the U and V plane pointers
swapped and `&kYvuI601Constants` ([`convert_argb.cc`][i420toabgr]). By default the
blue coefficient is clamped to 128, which is 2.0 in 6-bit fixed point (the comment
says `max(128, …)` but the effect is a minimum), because the default signed maths
limits coefficients to 0 to 2; `LIBYUV_UNLIMITED_DATA` switches to unsigned maths with "range of YUV to RGB coefficients to 0 to 4 instead of 0 to 2 for more
accuracy on B" ([`row_common.cc`][unlimited]). Custom matrices are possible only by
filling the per-architecture struct; [`util/yuvconstants.c`][yuvconstants-util]
computes the six integers.

### Plane functions, row functions and dispatch

Each public function is a plane loop around a function pointer to a **row
function**. `I420ToARGBMatrix` starts with the C row and overwrites the pointer once
per `HAS_` macro and `TestCpuFlag` hit, from SSSE3 through AVX-512, Neon, SVE2, SME,
LoongArch LSX/LASX, RVV, WebAssembly SIMD and Hexagon HVX
([`convert_argb.cc`][i420toargb]):

```c
// source/convert_argb.cc, I420ToARGBMatrix (abridged)
#if defined(HAS_I422TOARGBROW_AVX2)
  if (TestCpuFlag(kCpuHasAVX2)) {
    I422ToARGBRow = I422ToARGBRow_Any_AVX2;
    if (IS_ALIGNED(width, 16)) {
      I422ToARGBRow = I422ToARGBRow_AVX2;
    }
  }
#endif
  ...
  for (y = 0; y < height; ++y) {
    I422ToARGBRow(src_y, src_u, src_v, dst_argb, yuvconstants, width);
    dst_argb += dst_stride_argb;
    src_y += src_stride_y;
    if (y & 1) {
      src_u += src_stride_u;
      src_v += src_stride_v;
    }
  }
```

Two things follow. I420 is an I422 row run twice per chroma row: vertical chroma is
replicated, not interpolated. And the selection is repeated in every public function;
there is no table built once. `row.h` has 991 `#define HAS_` lines (many repeated
across architecture blocks), and
[`row_gcc.cc`][row-gcc] alone is 14,502 lines of inline-assembly rows such as
`I422ToARGBRow_SSSE3`, assembled from shared macro fragments (`READYUV422`,
`YUVTORGB`, `STOREARGB`).

The `_Any_` wrappers make a fixed-width kernel safe for any width
([`row_any.cc`][any31]). They run the kernel on `width & ~MASK` pixels, copy the
remainder into a zeroed 64-byte stack buffer, run the kernel once more on a full
vector there, and copy back only the valid bytes:

```c
// source/row_any.cc, ANY31 (abridged)
    int r = width & MASK;
    int n = width & ~MASK;
    if (n > 0) {
      ANY_SIMD(y_buf, u_buf, v_buf, dst_ptr, n);
    }
    memcpy(vin, y_buf + np, r);
    ...
    ANY_SIMD(vin, vin + 64, vin + 128, vout, MASK + 1);
    memcpy(dst_ptr + (np >> DUVSHIFT) * BPP, vout, SS(r, DUVSHIFT) * BPP);
```

### CPU detection

`TestCpuFlag` reads a global `cpu_info_` with a relaxed atomic load and calls
`InitCpuFlags` when it is zero ([`cpu_id.h`][testcpuflag]). On x86, `GetCpuFlags`
queries CPUID leaves 1, 7 (sub-leaves 0 and 1), `0x21`, `0x24` and `0x80000021`,
and gates AVX on `XGETBV` showing the OS saves YMM state and AVX-512 on the ZMM bits
([`cpu_id.cc`][getcpuflags]). Flag values are reused across architectures
(`kCpuHasSSE2`, `kCpuHasNEON`, `kCpuHasRVV`, `kCpuHasLSX` are all `0x100`), with a
separate architecture bit (`kCpuHasX86`, `kCpuHasARM`, …) to tell them apart.
`MaskCpuFlags(1)` forces C rows; `SetCpuFlags` lets a sandboxed process receive flags
detected elsewhere, because detection "might access /proc/cpuinfo"
([`cpu_id.h`][setcpuflags]).

### Scaling and rotation

`ScalePlane` has four filters, `kFilterNone` (point), `kFilterLinear` (horizontal
only), `kFilterBilinear` and `kFilterBox` ([`scale.h`][filtermode]), and tries
specialised paths before the general ones: exact copy, vertical-only, 3/4, 1/2, 3/8
and 1/4 downscales, box when shrinking by more than 2, 2x linear or bilinear upscales,
then general bilinear up, bilinear down, and point sampling
([`scale.cc`][scaleplane]). Positions are 16.16 fixed point (`FixedDiv_C` is
`(num << 16) / div` in 64-bit, [`scale_common.cc`][fixeddiv]); [`filtering.md`][filtering]
documents the centring: point downsampling takes the middle pixel, bilinear starts at
`dx / 2 - 0.5`, box starts at 0. Biplanar chroma has no box filter: for `NV12Scale`
"kFilterBox is not supported for the UV channel and will be treated as bilinear"
([`scale.h`][nv12scale]).

Rotation is transposition. `RotatePlane90` points the source at its last row,
negates the stride and calls `TransposePlane` ([`rotate.cc`][rotate90]), which
works in 8- or 16-row strips (`TransposeWx8`, `TransposeWx16`).
`ConvertToI420` composes crop, conversion and rotation in that order, using a
temporary I420 buffer unless the source format can be rotated in one pass
([`convert_to_i420.cc`][converttoi420], [`rotation.md`][rotation-doc]).

### Planar functions

[`planar_functions.h`][planar] holds 92 operations on whole planes: `CopyPlane`,
`SplitUVPlane`/`MergeUVPlane`, `ARGBAttenuate`/`ARGBUnattenuate` (premultiply and
back), `ARGBBlend`, `ARGBColorMatrix`, `ARGBPolynomial`, `ARGBGray`, `ARGBShade`,
`ARGBSobel` and more. `ARGBBlend` expects premultiplied input
([`planar_functions.h`][argbblend]); most others "don't care" ([`formats.md`][formats-argb]).

---

## Analysis

### 1. Pixel and memory model

An image is never an object: it is one to three `(pointer, int stride)` pairs plus
`width` and `height`, with the layout implied by the function name. Strides are in
bytes for 8-bit formats and in `uint16_t` elements for 16-bit ones: `P010Scale`'s
comment says so ([`scale.h`][p010scale]), and the 16-bit plane loops add the stride
to a `uint16_t*` (`I010ToAR30Matrix`, [`convert_argb.cc`][i010-stride]). A negative `height` flips by moving the pointer to the last row and
negating the stride, the same trick rotation uses, so every row loop must accept a
negative stride ([concepts: stride][c-stride]). Planar, biplanar and packed layouts
([concepts][c-planar]) are separate function families, not parameters. Odd widths
round chroma up (`(width + 1) / 2`). Most `NV12` functions accept a null destination
Y pointer to skip luma ([`formats.md`][formats-nv12]).

### 2. Genericity mechanism

None in the language sense. Genericity is the C preprocessor: `MAKEYUVCONSTANTS`
stamps out matrices, `ANY31`, `ANY31C` and siblings stamp out remainder wrappers,
`HAS_` macros gate each row, and the 172 `LIBYUV_API` functions of `convert_argb.h`
(184 `LIBYUV_API` lines, 12 of them the constant tables) are spelled out one per
format pair. The two-hub design (via I420 and ARGB) keeps the matrix of
conversions closer to linear in the number of formats, at the price of a second pass
for pairs not written directly. Compare [Highway's re-included translation
units][hwy-dispatch], which generate per-target kernels from one source.

### 3. Colour and metadata

libyuv models exactly two of the four [CICP][c-cicp] fields: the
[matrix coefficients][c-ycbcr] (BT.601, BT.709, BT.2020 non-constant luminance) and
[range][c-range]. Primaries and transfer function are absent: converting `U420` to
`ARGB` gives BT.2020-primaried, PQ- or HLG-encoded RGB with no hint that it is not
sRGB. Callers carrying CICP map it themselves, as [libavif's YUV to RGB][avif-yuv]
does, falling back to its own code where no table matches. No [ICC][c-icc] or
[metadata][c-meta] handling exists. Alpha is straight except for `ARGBBlend`
([concepts: alpha][c-alpha]).

Accuracy is measurable. The scratch program compared `I444ToARGB` (BT.601 limited)
against the float formula of [`color_test.cc`][color-ref] for all 2^24 inputs. Red
and green were within 1; blue was within 3, worst at `Y=239 U=0 V=0`, consistent
with the clamped `UB`. The SIMD output (the AVX2 row on this machine) and the C output hashed
identically. The test suite tolerates more: `ERROR_B` is 18 without
`LIBYUV_UNLIMITED_DATA` and 1 with it ([`color_test.cc`][color-error]).

### 4. I/O and codec architecture

Not applicable: libyuv has no I/O and no codec. Every call converts whole planes that
are already in memory, with no incremental or suspendable mode. The one compressed
format, `MJPG`, is decoded through libjpeg only when the library is built with
`HAVE_JPEG` ([`convert_to_i420.cc`][converttoi420-mjpg]); otherwise `ConvertToI420`
returns -1 for it.

### 5. Hostile input and safety

Parameter checks reject null pointers, non-positive widths, `height == INT_MIN`,
crops outside the frame, and (in `ScalePlane`) source dimensions above 32768 to keep
`FixedDiv` from overflowing ([`scale.cc`][scaleplane-limit]); the scratch program saw
`ScalePlane` return 0 for width 32768 and -1 for 32769. Buffer sizes are never
checked because they are never passed. `ConvertToI420` takes `sample_size` but uses
it only for MJPEG ([`convert_to_i420.cc`][converttoi420]): a 16-byte buffer described
as a 64x64 `YUY2` frame returned 0 on the SIMD path, and with `MaskCpuFlags(1)` ASan
reported a heap-buffer-overflow read in `YUY2ToUVRow_C` 113 bytes past the
allocation. The SIMD rows receive the same out-of-bounds pointers; ASan does not
instrument inline assembly, so only the C path shows it. Hostile-input safety therefore belongs to
the caller ([concepts: hostile input][c-hostile]); contrast
[Wuffs][wuffs], whose generated code proves its own bounds.

### 6. Allocation and ownership

Callers own every buffer. The library allocates only temporaries through
`align_buffer_64` (a `malloc` aligned to 64 bytes, with a `SIZE_MAX - 63` guard,
[`row.h`][align-buffer]): row buffers in box scaling, the rotate buffer in
`ConvertToI420`, and intermediate rows in two-pass conversions (18 sites in
`convert_argb.cc`). Allocation failure returns a non-zero code. Stack buffers in the
`_Any_` wrappers are fixed at 64 bytes per plane with a `static_assert`.

### 7. CPU parallelism and SIMD

Conversion, scaling and rotation are single-threaded; parallelism is the caller's
job (libavif splits an image into horizontal bands). The only threading in the tree
is OpenMP in the `compare.cc` metrics (Hamming distance, sum of squared error, SSIM),
compiled in only under `_OPENMP` ([`compare.cc`][compare-omp]). The SIMD story is breadth: x86 from SSE2 to AVX-512 VNNI and
AVX10, Arm Neon with dot-product and I8MM, SVE2 and SME, LoongArch, RVV, Wasm and
Hexagon. The README still claims "Optimized for MSA on Mips" ([`README.md`][readme]),
but no MSA source file exists at this revision. Dispatch is a flag test per call and
per function, cheap next to a frame but repeated everywhere; contrast
[libjpeg-turbo's per-object `jsimd_set_*`][ljt-simd] and [Highway][highway].
`MaskCpuFlags` is documented as not thread-safe ([`cpu_id.cc`][maskcpuflags]).

### 8. GPU offload and interop

None. No Vulkan, OpenGL, CUDA or Metal code exists in `source/` or `include/`. Its
relevance to GPU work is the naming bridge: libyuv `ARGB` is
`VK_FORMAT_B8G8R8A8_UNORM` (see [above](#argb-is-b-g-r-a-in-memory)), so a converted
buffer can be uploaded as-is once the mapping is known.

### 9. Temporal, animation and containers

Not applicable: libyuv converts one frame per call and keeps no state between calls
apart from the CPU flags. Frame timing, sequences and containers belong to the
caller (a capture pipeline or a codec library).

### 10. Testing and conformance

The unit tests run each function twice, once after `MaskCpuFlags(disable_cpu_flags_)`
for the C result and once with SIMD, then compare
([`convert_argb_test.cc`][test-pattern]); buffers come from
`align_buffer_page_end`, which places the data at the end of a page-rounded
allocation so over-reads leave the block ([`unit_test.h`][page-end]). Colour tests
check round trips and float references within tolerances. The
`LIBYUV_DISABLE_*` variables in [`environment_variables.md`][env-doc] are read by
the test harness's `TestCpuEnv`, not by the library ([`unit_test.cc`][testcpuenv]);
the harness spells the LoongArch guard `__longarch__` while the library uses
`__loongarch__`, so the LoongArch variables are never consulted. No fuzz target
exists in the tree.

---

## Lessons for Sparkles

- **Q1.** "Plane pointer + stride + negative height flips" is the minimum viable
  view, and libyuv shows it suffices for every layout. It also shows the cost of
  passing no lengths: a D view should carry slices (bounds) and derive strides,
  so the `ConvertToI420` over-read cannot be expressed.
- **Q1, Q5.** Names need one declared byte-order rule. libyuv picks word order and
  documents it once; a Sparkles pixel-format enum interoperating with libyuv,
  Vulkan and DRM needs a mapping table, not a reinterpretation of names
  ([concepts][c-names]).
- **Q5.** Encoding matrix and range in the format name (`I`, `J`, `H`, `F`, `U`, `V`)
  conflates layout with colorimetry and still omits primaries and transfer. A D
  design can keep layout and CICP as separate values and select a matrix table from
  them.
- **Q3, Q7.** The row-function split (plane loop calling one row pointer) maps
  directly onto a D template over a row kernel, with `@target`-specialised kernels
  ([intel-intrinsics][intel-intrinsics]); the `_Any_` tail-by-copy wrapper is a
  reusable pattern for fixed-width kernels without masked loads.
- **Q7.** Opaque per-architecture constant structs bake the ISA into the public data
  type; a D library can compute such tables at compile time from the six
  coefficients instead of shipping twelve hand-rounded ones.
- **Q8.** Bit-exact C versus SIMD comparison over all inputs is cheap (2^24 triples;
  both sweeps together took 0.65 s wall time in an ASan build on the machine above)
  and libyuv's harness shows how to make it the default test shape. libyuv itself is
  a practical differential oracle for YUV conversion and scaling, with its documented
  tolerances (blue error up to 3 measured, 18 allowed) taken into account.
- **Q9.** libyuv's split (conversion, scaling, rotation, planar operations, no codecs,
  no metadata) is evidence that a pixel-operations package can stand apart from
  format packages.

## Strengths

- One consistent function shape across about 520 entry points; trivially bindable
  from D through ImportC or `extern (C)`.
- Very wide SIMD coverage with a C reference for every row, and SIMD output that
  matched C bit for bit in the measured case.
- Odd widths and negative heights handled everywhere, through `_Any_` wrappers (or
  rows that take any width themselves, such as the AVX-512, SVE2 and RVV ones) and
  stride negation.
- Explicit, documented centring rules for each scaling filter.
- Little allocation; callers control memory.

## Weaknesses

- No buffer lengths in the API; `sample_size` is ignored for raw formats, so a
  truncated frame over-reads silently on the SIMD path.
- Only matrix and range of colour are modelled; primaries and transfer are left to
  the caller, and the default BT.601 blue coefficient is clamped.
- Format-pair explosion (184 `LIBYUV_API` declarations in `convert_argb.h` alone) maintained by
  hand and macro.
- No threading outside the optional OpenMP metrics, no fuzzing in tree, and
  documentation that has drifted (MSA in the
  README; environment variables that only the tests read).
- `YuvConstants` layout differs per architecture, so custom matrices are not portable.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                       | Trade-off                                                                |
| ------------------------------------------------------- | --------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Raw plane pointers and strides, no image type           | Zero-cost interop with any caller's buffers                     | No lengths, so no bounds checks: truncated input over-reads              |
| Two hub formats (I420 and ARGB)                         | Conversions grow roughly linearly with the number of formats    | Pairs not written directly pay a second pass and a temporary buffer      |
| Matrix and range in the function name and constants     | One row function per layout serves every matrix                 | Primaries and transfer are not modelled; colorimetry is mixed into names |
| Run-time dispatch repeated in every public function     | No global state beyond the CPU flags; any function stands alone | Selection code is duplicated across hundreds of functions                |
| Hand-written row kernels per ISA, with a C reference    | Best instruction sequence per target; C rows are the oracle     | Code grows with the ISA count; inline assembly is invisible to ASan      |
| `_Any_` wrappers that copy the tail into a stack buffer | Fixed-width kernels work for any width without masked loads     | An extra kernel call and two copies per row tail                         |

## Sources

- [`docs/formats.md`][formats], [`docs/filtering.md`][filtering],
  [`docs/rotation.md`][rotation-doc], [`docs/environment_variables.md`][env-doc]
- [`include/libyuv/video_common.h`][fourcc-enum], [`include/libyuv/row.h`][yuvconstants-struct],
  [`include/libyuv/convert_argb.h`][yuvconstants-decl], [`include/libyuv/cpu_id.h`][testcpuflag],
  [`include/libyuv/scale.h`][filtermode], [`include/libyuv/planar_functions.h`][planar]
- [`source/row_common.cc`][make-constants], [`source/convert_argb.cc`][i420toargb],
  [`source/row_any.cc`][any31], [`source/row_gcc.cc`][row-gcc], [`source/cpu_id.cc`][getcpuflags],
  [`source/scale.cc`][scaleplane], [`source/rotate.cc`][rotate90],
  [`source/convert_to_i420.cc`][converttoi420]
- [`unit_test/color_test.cc`][color-error], [`unit_test/unit_test.h`][page-end],
  [`unit_test/unit_test.cc`][testcpuenv]
- Related deep-dives: [libavif][avif-yuv], [libjpeg-turbo][ljt-simd], [Highway][highway],
  [Wuffs][wuffs], [intel-intrinsics][intel-intrinsics]; [CICP][cicp]; [concepts][concepts]

<!-- References -->

[upstream]: https://chromium.googlesource.com/libyuv/libyuv/
[repo]: https://github.com/lemenkov/libyuv
[license]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/LICENSE
[patents]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/PATENTS
[version]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/include/libyuv/version.h#L14
[readme]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/README.md#L1-L11
[docs]: https://github.com/lemenkov/libyuv/tree/205022c08c96da668cf0ed919f42e147dddd0bd0/docs
[formats]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/docs/formats.md
[formats-core]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/docs/formats.md#L5-L11
[formats-colour]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/docs/formats.md#L137-L145
[formats-hdr]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/docs/formats.md#L147-L156
[formats-argb]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/docs/formats.md#L158-L194
[formats-nv12]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/docs/formats.md#L213-L222
[filtering]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/docs/filtering.md#L1-L50
[rotation-doc]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/docs/rotation.md
[env-doc]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/docs/environment_variables.md#L1-L60
[fourcc-macro]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/include/libyuv/video_common.h#L30-L42
[fourcc-enum]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/include/libyuv/video_common.h#L55-L153
[yuvconstants-struct]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/include/libyuv/row.h#L1233-L1268
[align-buffer]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/include/libyuv/row.h#L1274-L1292
[yuvconstants-decl]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/include/libyuv/convert_argb.h#L27-L41
[unlimited]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/row_common.cc#L30-L37
[make-constants]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/row_common.cc#L1437-L1484
[bt601-constants]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/row_common.cc#L1586-L1606
[yuvconstants-util]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/util/yuvconstants.c
[i420toargb]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/convert_argb.cc#L54-L168
[i420toabgr]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/convert_argb.cc#L187-L204
[row-gcc]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/row_gcc.cc#L3599-L3626
[any31]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/row_any.cc#L275-L296
[testcpuflag]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/include/libyuv/cpu_id.h#L85-L96
[setcpuflags]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/include/libyuv/cpu_id.h#L113-L146
[getcpuflags]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/cpu_id.cc#L399-L470
[maskcpuflags]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/cpu_id.cc#L521-L533
[filtermode]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/include/libyuv/scale.h#L24-L29
[nv12scale]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/include/libyuv/scale.h#L267-L275
[scaleplane]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/scale.cc#L2153-L2271
[scaleplane-limit]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/scale.cc#L2162-L2169
[fixeddiv]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/scale_common.cc#L1645-L1650
[rotate90]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/rotate.cc#L166-L180
[converttoi420]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/convert_to_i420.cc#L278-L313
[planar]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/include/libyuv/planar_functions.h
[argbblend]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/include/libyuv/planar_functions.h#L845-L849
[color-error]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/unit_test/color_test.cc#L22-L32
[color-ref]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/unit_test/color_test.cc#L433-L439
[test-pattern]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/unit_test/convert_argb_test.cc#L246-L261
[page-end]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/unit_test/unit_test.h#L73-L92
[testcpuenv]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/unit_test/unit_test.cc#L79-L131
[concepts]: ./concepts.md
[c-names]: ./concepts.md#pixel-format-names-and-byte-order
[c-chroma]: ./concepts.md#chroma-subsampling
[c-stride]: ./concepts.md#stride
[c-planar]: ./concepts.md#interleaved-planar-and-semi-planar
[c-cicp]: ./concepts.md#cicp
[c-ycbcr]: ./concepts.md#ycbcr-and-matrix-coefficients
[c-range]: ./concepts.md#full-and-limited-range
[c-icc]: ./concepts.md#icc-profile
[c-meta]: ./concepts.md#image-metadata
[c-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[c-hostile]: ./concepts.md#hostile-input
[cicp]: ./cicp.md
[avif-yuv]: ./libavif.md#yuv-to-rgb
[ljt-simd]: ./libjpeg-turbo.md#simd-dispatch
[highway]: ./highway.md
[hwy-dispatch]: ./highway.md#dynamic-dispatch-re-including-the-translation-unit
[wuffs]: ./wuffs.md
[intel-intrinsics]: ./intel-intrinsics.md
[p010scale]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/include/libyuv/scale.h#L322-L329
[i010-stride]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/convert_argb.cc#L973-L1037
[compare-omp]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/compare.cc#L16-L18
[converttoi420-mjpg]: https://github.com/lemenkov/libyuv/blob/205022c08c96da668cf0ed919f42e147dddd0bd0/source/convert_to_i420.cc#L592-L601
[chromium-deps]: https://chromium.googlesource.com/chromium/src/+/b0e30a9973232cee28901ea5d6cd4de6ea9428aa/DEPS#2619
[skia-deps]: https://github.com/google/skia/blob/3ad790ab4d6d596efae0d70e4b8bf7d339121984/DEPS#L67
