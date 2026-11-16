# Simd (C++)

A C and C++ library of image-processing and neural-network kernels in which every
function is written once per instruction set, in a file of its own, and chosen at run
time; a large public example of hand-written per-ISA kernels checked against a scalar
reference by one equivalence harness.

| Field         | Value                                                                                                  |
| ------------- | ------------------------------------------------------------------------------------------------------ |
| Language      | C++ (built as `-std=c++11`), with a C API in `SimdLib.h` and header-only C++ wrappers in `SimdLib.hpp` |
| License       | MIT ([`LICENSE`][license])                                                                             |
| Repository    | [ermig1979/Simd][repo]                                                                                 |
| Revision read | `37dd13062b5b2a37b70fd23b232d66d594402369` (October 26, 2026, the merge of pull request `#1124`)       |
| Documentation | [ermig1979.github.io/Simd][docs] (Doxygen generated from `SimdLib.h`); [`README.md`][readme]           |
| Category      | GPU and SIMD                                                                                           |
| Tier          | A                                                                                                      |
| Last reviewed | November 7, 2026                                                                                       |

> [!NOTE]
> Four things were **verified** by running code in a scratch directory outside the
> repository: the pinned revision built with GCC 14.3.0 and CMake 4.1.2 on an AMD
> Ryzen 9 7940HX (Zen 4, AVX-512BW and VNNI, no AMX); its test harness ran with every
> x86 variant; a small C++ program linked against the static library ran natively and
> under `qemu-x86_64` 10.1.5 with the `Haswell` and `Nehalem` CPU models; and a D
> rewrite of one kernel family compiled and ran with LDC 1.43.0. The timings quoted are
> single runs of the library's own harness on that one machine (the bicubic and area
> resize figures compare several runs), and are evidence of shape, not benchmarks. Everything else is read from source or documentation.

---

## Overview

### What it solves

Simd is a catalogue of fixed-function image operations over raw pointers and byte
strides: pixel-format conversion (BGR, BGRA, RGB, YUV 4:2:0, 4:2:2 and 4:4:4, NV12,
UYVY, Bayer, HSV, HSL, CIELAB), resizing (nearest, bilinear, bicubic, area), filters
(Gaussian, Sobel, median, recursive bilateral), statistics and histograms, background
and motion detection, warp affine, image I/O for PGM/PPM, PNG, JPEG and BMP, and the inference
kernels behind the author's Synet framework (the `SIMD_SYNET` option is described as
"Enable optimizations for Synet framework", [`README.md`][readme-options]): convolution, inner product, pooling and
quantised layers in FP32, BF16 and INT8. `SimdLib.cpp` exports 385
`SIMD_API` functions.

The library's size is dominated by the per-ISA copies. Counted with `wc -l` over
`git show` at the pinned revision:

| Prefix of `src/Simd/` file | Files | Lines   | Instruction set (cluster checked at run time)  |
| -------------------------- | ----- | ------- | ---------------------------------------------- |
| `SimdBase*`                | 163   | 40,374  | scalar C++, the reference and the fallback     |
| `SimdSse41*`               | 162   | 49,347  | SSE, SSE2, SSE3, SSSE3, SSE4.1, SSE4.2         |
| `SimdAvx2*`                | 159   | 56,581  | AVX, AVX2, FMA, F16C, BMI1, BMI2               |
| `SimdAvx512bw*`            | 163   | 59,132  | AVX-512 F, CD, DQ, BW, VL                      |
| `SimdAvx512vnni*`          | 18    | 6,160   | AVX-512 VNNI (INT8 dot products only)          |
| `SimdAmxBf16*`             | 35    | 14,128  | AMX-TILE, AMX-INT8, AMX-BF16, AVX-512 BF16     |
| `SimdNeon*`                | 158   | 52,551  | Arm NEON (assumed present on AArch64)          |
| `SimdSve2*`                | 164   | 50,297  | Arm SVE and SVE2 (off by default, `SIMD_SVE2`) |
| everything in `src/Simd/`  | 1,144 | 408,596 |                                                |

The Synet files alone are 465 files and 173,320 lines, 42% of the tree, and 165 of the
413 `@ingroup` documentation blocks in `SimdLib.h` belong to a `synet_*` group:
inference, not image processing, is the larger half of the library.

### Design philosophy

The project states its approach in two sentences of the [`README.md`][readme]:

> _"The algorithms are optimized with using of different SIMD CPU extensions. In
> particular the library supports following CPU extensions: SSE, AVX, AVX-512 and AMX
> for x86/x64, NEON, SVE, SVE2 for ARM."_
>
> _"The Simd Library has C API and also contains useful C++ classes and functions to
> facilitate access to C API."_

The repository's agent guide adds the rule by which a new back end is judged
([`AGENTS.md`][agents]):

> _"If code optimized with using of SVE/SVE2 is slower then code optimized with using of
> NEON then it is something wrong and you need to search another way."_

Three commitments follow from these. **Every ISA variant is hand-written with that ISA's
intrinsics**: there is no portable vector layer, so an AVX2 kernel and an AVX-512 kernel
of the same function are separate source files that resemble each other. **The scalar
`Base` implementation is both the reference and the fallback**, and every variant is
tested against it. **The ABI is C**: images cross it as `(data, stride, width, height)`
and, where a format matters, a `SimdPixelFormatType`; the C++ layer is thin inline
wrappers over the C functions. Compare [OpenCV](./opencv.md#the-hal-and-cpu-dispatch),
which compiles one source per target, and [Highway](./highway.md), which builds the
targets from one source with a portable op set; Simd is the opposite pole of that
spectrum.

---

## How it works

### One namespace per instruction set, one file per function

Each kernel lives in `namespace Simd::<Isa>` in a file named `Simd<Isa><Function>.cpp`.
`AbsDifference`, the per-pixel `|a - b|` of two 8-bit images, exists five times on x86
and Arm plus once for SVE2. The scalar version is the specification
([`SimdBaseAbsDifference.cpp`][base-absdiff]):

```cpp
// src/Simd/SimdBaseAbsDifference.cpp
for (size_t row = 0; row < height; ++row)
{
    int rowSum = 0;
    for (size_t col = 0; col < width; ++col)
        c[col] = AbsDifferenceU8(a[col], b[col]);
    a += aStride; b += bStride; c += cStride;
}
```

The SSE4.1, AVX2 and NEON versions share one structure: a body loop of whole vectors,
then one more vector stored at `width - A`, **overlapping** the body, for the tail
([`SimdAvx2AbsDifference.cpp`][avx2-absdiff]):

```cpp
// src/Simd/SimdAvx2AbsDifference.cpp
assert(width >= A);
size_t bodyWidth = AlignLo(width, A);
for (size_t col = 0; col < bodyWidth; col += A)
{
    const __m256i a_ = Load<align>((__m256i*)(a + col));
    const __m256i b_ = Load<align>((__m256i*)(b + col));
    Store<align>((__m256i*)(c + col), _mm256_sub_epi8(_mm256_max_epu8(a_, b_), _mm256_min_epu8(a_, b_)));
}
if (width - bodyWidth)
{
    const __m256i a_ = Load<false>((__m256i*)(a + width - A));
    // ... same computation, stored at c + width - A
}
```

The AVX-512BW version instead masks the tail with a `__mmask64` from `TailMask64`, so
it has no minimum width ([`SimdAvx512bwAbsDifference.cpp`][avx512-absdiff]); the NEON
version replaces max, min and subtract with one `vabdq_u8`
([`SimdNeonAbsDifference.cpp`][neon-absdiff]). The AVX2, AVX-512BW and NEON variants
are each a `template <bool align>` instantiated twice, and a non-template entry point
picks the aligned instantiation when all three pointers and strides are aligned; the
SSE4.1 variant is a plain function that uses unaligned loads and stores throughout
([`SimdSse41AbsDifference.cpp`][sse41-absdiff]).

What the variants share is vocabulary, not code. `SimdConst.h` defines the same names
in every namespace: `A` is the vector size in bytes (`sizeof(__m128i)` in `Sse41`,
`sizeof(__m256i)` in `Avx2`), `F` the number of floats, `DA`, `QA` and `HA` its
multiples and half ([`SimdConst.h`][const-sse41], [`Avx2`][const-avx2]). `SimdLoad.h`,
`SimdStore.h`, `SimdMath.h` and eight `*Common.h` headers each repeat a block per
namespace with same-named helpers (`Load<align>`, `Store<align>`). A kernel body
therefore reads almost identically across ISAs, and is copied, not instantiated. The
two narrow ISAs reuse the AVX-512BW vocabulary wholesale: both `namespace Avx512vnni`
and `namespace AmxBf16` contain `using namespace Avx512bw;`
([`SimdConst.h`][const-vnni]), and they implement only the functions where their
instructions help, in 18 and 35 files.

### Stateful operations: a class chain per ISA

Operations with set-up (resizers, Gaussian blur, image loaders, every Synet layer) are
objects behind an opaque `void*`. The abstract `Resizer` has one virtual
`Run(src, srcStride, dst, dstStride)` ([`SimdResizer.h`][resizer-h]). Each ISA's class
derives from the one below it: `Avx512bw::ResizerByteBilinear` from
`Avx2::ResizerByteBilinear` from `Sse41::ResizerByteBilinear` from
`Base::ResizerByteBilinear` ([`SimdResizer.h`][resizer-chain]), so index and weight
tables computed by a parent are reused and only `Run` and the vector-specific tables are
overridden. Each namespace has a factory that recognises the cases it accelerates and
delegates the rest down the chain: `Avx2::ResizerInit` returns
`new ResizerByteBilinear(param)` when `param.IsByteBilinear() && dstX >= A`, tests
eight more cases, and otherwise ends in
`return Sse41::ResizerInit(srcX, srcY, dstX, dstY, channels, type, method);`
([`SimdAvx2Resizer.cpp`][avx2-resizer]). Image loaders follow the same chain (`Avx2::ImagePngLoader` derives from
`Base::ImagePngLoader`, the AVX2 JPEG and BMP loaders from the SSE4.1 ones,
[`SimdImageLoad.h`][imageload-chain]): a codec's parsing is written once in `Base` and
only its pixel-conversion inner loops are specialised.

### Build: one flag set per file group

The ISA a file targets is decided by the build, not by attributes in the source. The
x86 CMake script globs each prefix and gives it its own flags
([`x86.cmake`][x86-cmake]): `SimdSse41*.cpp` gets `-msse -msse2 -msse3 -mssse3
-msse4.1 -msse4.2`, `SimdAvx2*.cpp` gets `-mavx -mavx2 -mfma -mf16c -mbmi -mbmi2
-mlzcnt`, and `SimdAvx512bw*.cpp` the AVX-512 set. Inside the source, the enable macros
are derived from the compiler's predefined macros ([`SimdDefs.h`][defs-enable]):

```cpp
// src/Simd/SimdDefs.h
#if !defined(SIMD_AVX2_DISABLE) && defined(__AVX__) && defined(__AVX2__)
#define SIMD_AVX2_ENABLE
#endif
```

So a translation unit sees `SIMD_AVX2_ENABLE` only if it was compiled with AVX2 enabled.
The dispatcher `SimdLib.cpp` must see every enable macro, and the script therefore
compiles it with the union, `SIMD_LIB_FLAGS` (`-mavx2 -mfma`, plus `-mavx512bw` and
`-mavx512vnni` when those groups are built). The consequence is in
[Hostile input and safety](#_5-hostile-input-and-safety).

### Detection

Each ISA declares `const bool Enable = GetEnable();` at namespace scope in
`SimdEnable.h` ([`SimdEnable.h`][enable-h]), so detection runs during static
initialisation. `GetEnable` returns `SupportedByCPU() && SupportedByOS()`
([`SimdAvx2Cpu.cpp`][avx2-cpu]). On MSVC, `SupportedByOS` executes
`_mm256_abs_epi8` inside `__try` and returns `false` from the `__except` handler;
elsewhere it is `return true;`. The CPUID check includes `OSXSAVE`, but `xgetbv` does
not occur anywhere in the repository (`git grep -i xgetbv` at the pinned revision finds
nothing), so on GCC and Clang an OS that has not enabled the YMM or ZMM state is not
detected. The AVX-512BW check has the same shape and does not test `OSXSAVE` either
([`SimdAvx512bwCpu.cpp`][avx512-cpu]). NEON reads `AT_HWCAP` on 32-bit Arm and returns
`true` on AArch64 ([`SimdNeonCpu.cpp`][neon-cpu]). `GetSlowGather` is a second,
non-ISA flag: it reports AMD and unknown vendors as having slow `vpgather`.

### Dispatch: two forms in `SimdLib.cpp`

Stateless functions use an `if` chain evaluated **on every call**, which can also depend
on the arguments ([`SimdLib.cpp`][lib-absdiff]):

```cpp
// src/Simd/SimdLib.cpp — SimdAbsDifference
SIMD_EMPTY();
#ifdef SIMD_AVX512BW_ENABLE
    if (Avx512bw::Enable)
        Avx512bw::AbsDifference(a, aStride, b, bStride, c, cStride, width, height);
    else
#endif
#ifdef SIMD_AVX2_ENABLE
    if (Avx2::Enable && width >= Avx2::A)
        Avx2::AbsDifference(a, aStride, b, bStride, c, cStride, width, height);
    else
#endif
// ... Sse41 (width >= 16), Sve2, Neon (width >= 16) ...
        Base::AbsDifference(a, aStride, b, bStride, c, cStride, width, height);
```

The `width >= A` guard exists because the overlapping-tail kernels assert it: an image
narrower than one AVX2 vector falls through to SSE4.1, and one narrower than 16 bytes to
`Base`. Newer functions use a function-local static pointer, initialised once by the
`SIMD_FUNCn` macros, which expand to a chain of conditional expressions
([`SimdEnable.h`][enable-h], [`SimdLib.cpp`][lib-resizer]):

```cpp
// src/Simd/SimdEnable.h
#define SIMD_AVX2_FUNC(func) Simd::Avx2::Enable ? Simd::Avx2::func :
#define SIMD_FUNC5(func, EXT1, EXT2, EXT3, EXT4, EXT5) EXT1(func) EXT2(func) EXT3(func) EXT4(func) EXT5(func) SIMD_BASE_FUNC(func)

// src/Simd/SimdLib.cpp — SimdResizerInit
const static SimdResizerInitPtr simdResizerInit = SIMD_FUNC5(ResizerInit, SIMD_AVX512BW_FUNC,
    SIMD_AVX2_FUNC, SIMD_SSE41_FUNC, SIMD_SVE2_FUNC, SIMD_NEON_FUNC);
```

The list of extensions is per function: `SimdGemm32fNN` lists five, `SimdDescrIntInit`
seven (adding `Avx512vnni` and `AmxBf16`), `SimdRecursiveBilateralFilterInit` four, with
AVX-512BW commented out ([`SimdLib.cpp`][lib-gemm], [`DescrIntInit`][lib-descr],
[`RecursiveBilateralFilterInit`][lib-rbf]). An ISA that lacks a function is
simply not listed. `SIMD_EMPTY()` places an `EmptyCaller` on the stack whose destructor
executes `_mm_empty()` (`emms`, which clears the MMX state) when SSE4.1 is enabled
([`SimdEmpty.h`][empty-h]).

A third mechanism exists inside one ISA. `Runtime<Func, Args>` holds several candidate
implementations (two GEMM micro-kernel strategies, for example), times each one
`TEST_COUNT = 3 + 2` times on real calls with a trimmed mean, then fixes the fastest for
that object ([`SimdRuntime.h`][runtime-h]). It is used only by the FP32 convolution and
deconvolution layers, and is switched off by `SIMD_RUNTIME_DISABLE`.

### The C API and `View<A>`

The C API passes images as separate `(data, stride)` pairs and one shared
`(width, height)`, as the dispatch excerpt above shows. The documentation of
`SimdAbsDifference` states the formula and "All three images must have the same width
and height", and nothing about aliasing ([`SimdLib.h`][libh-absdiff]). The C++ image type is `View<A>`, templated on an
allocator template ([`SimdView.hpp`][view-struct]):

```cpp
// src/Simd/SimdView.hpp
template <template<class> class A>
struct View
{
    const size_t width;
    const size_t height;
    const ptrdiff_t stride;
    const Format format;
    uint8_t * const data;
    // ...
};
```

`Format` is a runtime enum with the same values as `SimdPixelFormatType`: `Gray8`,
`Uv16`, `Bgr24`, `Bgra32`, `Int16`, `Int32`, `Int64`, `Float`, `Double`, four Bayer
mosaics, `Hsv24`, `Hsl24`, `Rgb24`, `Rgba32`, `Uyvy16`, `Argb32` and `Lab24`
([`SimdLib.h`][libh-format]). A view either owns its buffer or references one;
`Region` returns a clipped referencing sub-view with the parent stride, and `Flipped`
returns a view with a negative stride whose `data` points at the last row
([`SimdView.hpp`][view-flipped]). The class documentation is unusually candid about the
ownership rules: copy construction shares the buffer and leaves the copy non-owning, and
"Copy assignment over a view that already owns its buffer frees that buffer and then
executes `assert(0)`" ([`SimdView.hpp`][view-doc]). Multi-plane images are
`Frame<A>`, at most four `View<A>` planes plus `flipped` and `timestamp`, for `Nv12`,
`Yuv420p`, `Yuv444p` and the packed formats ([`SimdFrame.hpp`][frame]). The wrappers in
`SimdLib.hpp` check compatibility with `assert` only, then forward fields to the C
function ([`SimdLib.hpp`][libhpp-absdiff]).

Compared with [the concepts page's image and view](./concepts.md#image-and-view),
`View<A>` is a 2-D view with a byte stride and a runtime format tag, without a pixel
type parameter, channel-order type or N-D extent; it is closest to
[OpenCV's `Mat` header](./opencv.md#the-mat-header) restricted to 2-D, and far from
the typed views of [Boost.GIL](./boost-gil.md) or mir's [`Slice`](./mir-algorithm/).

### Test and benchmark harness

`src/Test` (112 files, 38,070 lines) is one executable with a test group per function.
In auto mode (`-m=a`) each test compares **every compiled variant, `Base` included,
against the public dispatched function** on random images, and times both
([`TestAbsDifference.cpp`][test-absdiff]):

```cpp
// src/Test/TestAbsDifference.cpp
if (TestBase(options))
    result = result && AbsDifferenceAutoTest(FUNC1(Simd::Base::AbsDifference), FUNC1(SimdAbsDifference), 1);
#ifdef SIMD_AVX2_ENABLE
if (Simd::Avx2::Enable && TestAvx2(options) && W >= Simd::Avx2::A)
    result = result && AbsDifferenceAutoTest(FUNC1(Simd::Avx2::AbsDifference), FUNC1(SimdAbsDifference), 1);
#endif
```

Because the dispatched function is the best variant, comparing all of them against it
makes all of them equal to `Base` transitively. Each case runs at `W` by `H` and at
`W + O` by `H - O` with `O = 9`, so the overlapping tail and odd heights are exercised
([`TestConfig.h`][test-config]); the defaults are 1920 by 1080 in a release build and 128
by 96 otherwise ([`Test.cpp`][test-sizes]). Tolerance is per output type: 8-bit outputs
must match exactly, 16-bit within 1, `float` within `EPS = 0.001`, BF16 within
`8 * EPS` ([`TestResize.cpp`][test-resize]). `-de=` disables ISAs by bit mask
([`TestOptions.h`][test-options]); `-m=s` runs special tests, such as resizing against
OpenCV within a stated maximum difference. The performance report has a column per ISA
and ratio columns (`Bs/A2` is Base time over AVX2 time).

On the test machine, one run of `-m=a -tt=1` gave, in milliseconds per call as the
report averages them over the cases each test runs (the bicubic row is from a later
verification run, one of three that agreed):

| Function (case)                                           | API   | Base  | SSE4.1 | AVX2  | AVX-512BW |
| --------------------------------------------------------- | ----- | ----- | ------ | ----- | --------- |
| `AbsDifference` (`Gray8`, default sizes)                  | 0.053 | 0.152 | 0.061  | 0.052 | 0.054     |
| `BgrToGray` (default sizes)                               | 0.183 | 1.779 | 0.486  | 0.255 | 0.179     |
| `ResizerInit` bilinear, 1 channel, 1999x1499 to 1919x1081 | 0.225 | 3.063 | 0.455  | 0.251 | 0.183     |
| `ResizerInit` bicubic, 1 channel, same sizes              | 1.152 | 5.288 | 1.202  | 0.926 | 1.164     |

The shape is the finding: a memory-bound point operation stops gaining after SSE4.1;
a conversion with arithmetic per pixel gains through AVX-512; and in at least one case
a wider variant is slower than a narrower one. In three runs the bicubic AVX-512BW
variant took 1.16 to 1.59 ms against 0.92 to 0.93 ms for AVX2, and the API time
followed AVX-512BW, the variant the dispatcher chose. The area resize at the same sizes
is not a usable example: across four runs its SSE4.1 time ranged from 2.74 to 5.59 ms
against 3.86 to 4.49 ms for `Base`, so the order of its variants changed from run to
run. The harness reports such inversions in its ratio columns; it does not act on them.

### The same family in D (verified with LDC 1.43)

A single-file D program wrote `AbsDifference` once, as the scalar loop of `Base`, in an
eponymous template over a target enum with LDC's `@target(tgtStr[t])`, `@safe pure
nothrow @nogc` and bounds-checked slices, and filled an `immutable` function-pointer
table with `static foreach` (the shape the [Highway deep-dive](./highway.md) verified).
Built with `-O3 -preview=dip1000`, the four instantiations compiled to
`pmaxub`/`pminub`/`psubb` on `xmm` (baseline and `sse4.1`), to the VEX forms on `ymm`
(`avx2`) and on `zmm` (`avx512bw,avx512vl`): the max-minus-min idiom Simd writes by
hand in four files, produced by LLVM from one source. All three vector instantiations
matched the baseline on a 70-by-3 image with an 80-byte stride. This is what the
auto-vectoriser reaches; shuffles, saturating packs and horizontal sums (`BgrToGray`,
the resizers) need per-target intrinsics, the case the
[intel-intrinsics deep-dive](./intel-intrinsics.md) examines. The program lives outside
the repository and is not CI-verified.

---

## Analysis

### 1. Pixel and memory model

The model is a 2-D, row-major, byte-strided buffer with a runtime format tag. Strides are
in bytes and may be larger than `width * PixelSize()` because owned rows are aligned to
`SimdAlignment()`, which is itself a run-time value: 64 with AVX-512, 32 with AVX2, 16
with SSE4.1 ([`SimdAlignment.h`][alignment-h]), verified as 64, 32 and 16 under native,
`Haswell` and `Nehalem`. Planar images are a `Frame` of separate views, chroma
subsampling is implied by the frame format ([concepts: chroma subsampling](./concepts.md#chroma-subsampling)),
and there is no tile, N-D extent or batch dimension in the image types (the Synet
tensors carry their own `NCHW`/`NHWC` shapes). `View::stride` is `ptrdiff_t` and
`Flipped` makes it negative, while every C function takes `size_t` strides; the negative
value wraps and the pointer arithmetic `a += aStride` wraps back. Verified: a flipped
view with stride −64 passed through `Simd::AbsDifference` produced the correct rows.
It works because of two's-complement wraparound, not because the API admits negative
strides.

### 2. Genericity mechanism

There is almost none in the kernel layer. Variation by ISA is by **copy**: a namespace
per ISA, a file per function, and same-named helpers per namespace that make copies look
alike. Variation by alignment is a `template <bool align>`. Variation by pixel format is a
runtime enum switched in the C function or a separate function per pair
(`SimdBgrToGray`, `SimdBgraToGray`, `SimdRgbToGray`). Code reuse across ISAs exists only
for stateful operations, through class inheritance with virtual `Run`, and inside a
namespace through templates on channel count (`template<size_t N> void Run(...)` in
`Avx2::ResizerByteBilinear`). This is the opposite of the [design-by-introspection
guidelines][dbi] and of the [generic image papers][p-generic]: the generic programming
happens in the author's head.

### 3. Colour and metadata

Colour is limited to YUV matrices and ranges. `SimdYuvType` selects BT.601, BT.709 and
BT.2020 limited range or T-REC-T.871 full range, each with its `Kr` and `Kb`
([`SimdLib.h`][libh-yuv]; compare
[concepts: YCbCr and matrix coefficients](./concepts.md#ycbcr-and-matrix-coefficients)
and [full and limited range](./concepts.md#full-and-limited-range)). `BgrToLab` writes
8-bit CIELAB; `AlphaPremultiply` and `AlphaUnpremultiply` convert alpha conventions.
There is no transfer function, primaries, ICC profile or CICP in any type, and the PNG
and JPEG loaders return pixels without metadata. The library assumes 8-bit sRGB-like
data whose meaning the caller knows.

### 4. I/O and codec architecture

`SimdImageLoadFromMemory` sniffs PGM/PPM, PNG, JPEG and BMP signatures and decodes the
whole buffer to a newly allocated image in a requested format
([`SimdLib.h`][libh-load]). It is pull-only and one-shot: an `ImageLoader` wraps an
`InputMemoryStream` over the full input and `FromStream()` returns success or failure
([`SimdImageLoad.h`][imageload-h]); there is no incremental, progressive or suspendable
decoding (see [concepts](./concepts.md#incremental-progressive-and-suspendable-decoding)).
The encoders (`SimdImageSaveToMemory`, `SimdNv12SaveAsJpegToMemory`,
`SimdYuv420pSaveAsJpegToMemory`) are dispatched by ISA like any kernel. The codecs exist to make the library self-contained for
tests and examples; they are not a format library, and [libjpeg-turbo](./libjpeg-turbo.md)
and [libspng](./libspng.md) are the better references for codec structure.

### 5. Hostile input and safety

Kernels trust their arguments. The C functions check nothing; the C++ wrappers and the
vector kernels use `assert`, which a release build removes. Three hazards were
demonstrated.

**In-place calls give ISA-dependent results.** The overlapping tail re-reads input that
the body already overwrote when the destination aliases a source. Calling
`SimdAbsDifference(a, w, b, w, a, w, 70, 1)` and comparing with `Base::AbsDifference`
into a separate buffer: under AVX-512BW (masked tail) 0 of 70 bytes differed, under
`qemu -cpu Haswell` (AVX2) 26 differed, under `qemu -cpu Nehalem` (SSE4.1) 10 differed.
The documentation neither permits nor forbids aliasing.

**The dispatcher contains instructions that its fallback CPUs lack.** Because
`SimdLib.cpp` is compiled with `-mavx2 -mfma -mavx512bw -mavx512vnni`, GCC emitted VEX
encodings in it: `objdump` of `SimdLib.cpp.o` showed 452 VEX instructions, including
382 `vzeroupper` on exception-cleanup paths (375 in the `.cold` blocks of the dispatch
functions, 7 in landing pads inside function bodies),
`vmovdqu` in the `Synet*Info` string builders, and `vstmxcsr`/`vldmxcsr` in
`SimdGetFastMode` and `SimdSetFastMode`, which inline `_mm_getcsr` behind an
`if (Sse41::Enable)` guard. Under `qemu-x86_64 -cpu Nehalem` (SSE4.2, no AVX) the
dispatch, alignment and SSE4.1 kernels worked, and `SimdGetFastMode()` terminated with
`SIGILL`: the guard passed, and the instruction behind it was VEX-encoded.

**OS state is not checked** on GCC and Clang (see [Detection](#detection)). The Sparkles
SIMD research recorded the opposite rule: "Runtime dispatch must include OS support, not
only CPU capability bits" ([baseline](./baseline/shaders-simd.md#contracts-that-constrain-image-and-video-work)).

The decoders do carry limits. The BMP loader rejects
dimensions above `1 << 24` before any size arithmetic and explains why in a comment
("computing \_size and the image allocation (height \* stride) from unbounded
dimensions overflows size_t on 32-bit builds", [`SimdBaseImageLoadBmp.cpp`][bmp-limits]);
the PNG loader rejects zero and over-`1 << 24` dimensions
([`SimdBaseImageLoadPng.cpp`][png-limits]) and images whose output exceeds `INT_MAX`
bytes ([`CreateImage`][png-intmax]). There are seven
libFuzzer targets in `src/Fuzz` (load, save, resizer, YUV, Gaussian blur, GEMM, pooling)
with seed corpora; the README says the load harness "is shared with OSS-Fuzz"
([`README.md`][readme-fuzz]). The load fuzzer
skips PNGs larger than 4096 pixels on a side or one megapixel in total
([`simd_load_fuzzer.cpp`][fuzz-load]), so the budget lives in the harness, not in a
library option a caller could set. See the [hostile-input papers][p-hostile] for why
caller-set limits matter.

### 6. Allocation and ownership

All memory goes through `Simd::Allocate`, `posix_memalign` (or `_aligned_malloc`) with
the size rounded up to the alignment ([`SimdMemory.h`][memory-h]), and is freed with
`SimdFree`; decoders and encoders return buffers the caller must `SimdFree`. Stateful
objects are `new`-allocated C++ objects deriving from `Deletable`, returned as `void*`
and destroyed by `SimdRelease`. `View<A>` owns or references; the allocator template
parameter only chooses how owned rows are allocated. Kernels do not allocate, but
`Init` functions and the Synet layers allocate internal buffers (`Array32i` index
tables, packed GEMM panels). There is no arena or caller-supplied scratch interface in
the C API.

### 7. CPU parallelism and SIMD

SIMD is the library's subject: see [How it works](#how-it-works). Threads are secondary
and opt-in. `SimdSetThreadNumber` sets a global count, default 1, clamped to
`hardware_concurrency()` ([`SimdBaseThread.cpp`][thread]). `Simd::Parallel` splits a
half-open range into contiguous blocks and runs each with `std::async(std::launch::async,
...)`, creating fresh threads per call and waiting on the futures
([`SimdParallel.hpp`][parallel]). Its documentation lists the users: nearest resize and
warp affine split destination rows, GEMM splits `N` by micro-kernel width and stays
single-threaded below `256 * 256 * 256 * 2` multiply-adds. There is no persistent
pool, no work stealing and no tiling of a pipeline across operations; each call is one
pass over memory, which is the cost that [Halide](./halide.md) and
[libvips](./libvips.md) exist to avoid.

### 8. GPU offload and interop

None. No OpenCL, CUDA, Vulkan or Metal code was found in `src/`. The AMX back end is
the library's accelerator story: tile matrix multiplication for BF16 and INT8 inference
on Intel server CPUs, still a CPU instruction set. The absence matters for
[Q7](./index.md#questions-this-survey-answers): Simd offers no evidence on the
CPU-GPU break-even, only on how much the CPU side gains per ISA step.

### 9. Temporal, animation and containers

Temporal processing exists only as computer vision. `Simd::Motion::Detector` consumes a
sequence of `Frame` objects through `NextFrame(input, metadata, output)` and maintains a
background model updated on timestamps (`BackgroundGrowTime`, `BackgroundStatUpdateTime`
and related options, [`SimdMotion.hpp`][motion]); the `Background*` C functions are the
per-frame kernels. There is no animation, no container parsing and no video I/O; the
motion test reads video through OpenCV when it is enabled.

### 10. Testing and conformance

The equivalence harness described [above](#test-and-benchmark-harness) is the strongest
part of the project; special tests add OpenCV as an external oracle, and fuzzing covers
the decoders and several kernels. Two limits were found. **The variants a test exercises are fixed by the test binary's
compile flags**, because `src/Test` is guarded by the same `SIMD_*_ENABLE` macros. The
project's CI therefore configures `-DSIMD_TEST_FLAGS="-march=native"`
([`cmake.yml`][ci-cmake]). `SIMD_TEST_FLAGS` is empty by default, and the test sources
then get no ISA flags ([`x86.cmake`][x86-cmake]). The first scratch build left it at
that default, and the harness compared only `Base` with the API and printed "ALL TESTS
ARE FINISHED SUCCESSFULLY!". Passing `-DSIMD_TEST_FLAGS="-march=native"` in the Nix
development shell gave the same result, because the Nix C compiler wrapper drops
`-march=native` while `NIX_ENFORCE_NO_NATIVE` is set; the per-ISA columns appeared only
after the test objects were rebuilt with the flag kept. A passing run does not state
which variants it ran, except through the report's columns. **Coverage of
each ISA depends on the CI runner's CPU**: the x86 jobs run on GitHub-hosted runners
with `-march=native`, so whether AVX-512 or AMX variants are exercised depends on the
machine assigned, and one x86 job runs only `-fi=QuantizedConvolution`
([`test.yml`][ci-test]). The arm64 job runs the full suite with SVE2 enabled.

---

## Lessons for Sparkles

- **Q3 — A per-ISA kernel organisation in D costs far less than in C++, because one
  template can carry every target.** Simd's seven per-ISA trees (288,196 lines
  against 40,374 for `Base`) exist because C++ cannot vary the target ISA by template
  argument and the build assigns ISAs by file. LDC's `@target` on an instantiated
  template, a target enum and a CTFE table did that for one kernel family here
  (verified above). The [baseline](./baseline/shaders-simd.md#gaps-and-tensions) (G4)
  records that `blake3_simd.d` already uses this shape for one algorithm. What does not
  transfer for free is the hand-tuned intrinsic body: shuffles, saturating packs and
  masked tails need per-target code whatever the language.
- **Q3 — Argument-dependent dispatch should be declared, not copied.** Simd's per-call
  `width >= A` guards route narrow images to narrower ISAs, and the same threshold is
  repeated in the dispatcher and in the tests. In D a kernel could declare its minimum
  width as a member that a CTFE-built dispatcher and the test harness read by
  introspection.
- **Q3, Q9 — Detection belongs in one shared, public module with OS-state checks.**
  Simd's detection is centralised (`Enable` flags, `SimdCpuInfo`) but skips `XCR0` on
  GCC and Clang. Sparkles' [baseline](./baseline/shaders-simd.md#gaps-and-tensions) (G5)
  has the opposite profile: `simd_caps.d` reads `xgetbv`, but its flags are `package`
  visibility and each package repeats detection. Simd's `const bool Enable =
GetEnable();` runs in static initialisation; the D equivalent is a module constructor,
  which `--better-c` and wasm builds may not run (G6), so a lazily-initialised query is
  the portable form.
- **Q3 — Compile only the kernel with the wide target, never the dispatcher.** Simd's
  union flags on `SimdLib.cpp` produced AVX instructions on the fallback path and a
  `SIGILL` on an SSE4.2 CPU (verified). In D, `@target` scopes the ISA to one function
  and leaves the module at the shipping baseline that [build settings][build-settings]
  require (`checked` has no native CPU requirement). The pitfall that remains is the one
  Highway's D experiment found: `intel-intrinsics` chooses implementations by module
  flags, not by `@target`.
- **Q8 — Adopt the equivalence harness, and make it say what it ran.** Every variant
  against the reference, at an aligned and an odd size, with a tolerance per output
  type, is directly the [baseline's](./baseline/shaders-simd.md#questions-for-the-design-grill)
  option A for kernel conformance and matches `blake3_test.d`. Simd's silent narrowing
  (a green run that tested only `Base`, verified here) argues for the test-runner rule
  that a degraded environment calls `skipTest(reason)` per unavailable backend rather
  than passing, and for a backend list in the output.
- **Q8 — State the aliasing contract per kernel.** The in-place result of
  `AbsDifference` differs between AVX-512BW, AVX2 and SSE4.1 (verified). D's dip1000
  `scope` does not express non-aliasing between two slices, so a Sparkles kernel either
  documents and asserts `!overlap(src, dst)`, or is written to be safe in place (a
  masked or scalar tail, as AVX-512BW is), and the equivalence harness should include an
  in-place case for every kernel that admits one.
- **Q1 — `View<A>` is a useful lower bound, not a model.** A byte stride, a runtime
  format enum, owned-or-referenced storage, `Region` and a negative-stride `Flipped` is
  what a C ABI can carry; it lacks a typed pixel, N-D extents and a signed stride in the
  C API. Sparkles' [existing code](./baseline/existing-code.md#gaps-and-tensions) has no
  view type yet; mir's `Slice` has signed `ptrdiff_t` strides, counted in elements
  ([mir-algorithm](./mir-algorithm/index.md)), and Simd shows what wrapping a signed
  byte stride into `size_t` relies on; it also shows a byte stride carrying a padded
  pitch that an element stride cannot.
- **Q7 — The per-ISA gains are uneven and sometimes negative.** One run on Zen 4 showed
  `AbsDifference` flat after SSE4.1 (memory-bound), `BgrToGray` improving through
  AVX-512, and a bicubic resize slower in AVX-512BW than in AVX2 while the dispatcher
  still chose AVX-512BW; an area resize varied so much between runs that its variant
  order was not stable. A Sparkles kernel set
  needs per-kernel measurement before it carries a wide variant, and the
  [baseline's](./baseline/shaders-simd.md#gaps-and-tensions) G7 notes that the `bench`
  build's `-mcpu=native` would hide dispatch entirely. Simd gives no GPU evidence.
- **Q9 — Evidence for keeping kernels, formats and inference apart.** Simd is one
  library and one C ABI for image kernels, four codecs and an inference engine that is
  now 42% of the source. Its codecs reuse kernel code by inheriting per-ISA classes, so
  the coupling is real; but nothing in the kernel layer depends on the codecs, which is
  the dependency direction a split into image-core and image-algorithms would keep.
- **Q4, Q5 — Do not take the codec or colour design from here.** One-shot whole-buffer
  decoding, no metadata, and dimension limits fixed in the library are the patterns
  [Wuffs](./wuffs.md) and the codec deep-dives improve on.

## Strengths

- One reference (`Base`) for every function, and a harness that checks every compiled
  variant against it with per-type tolerances and odd sizes.
- Broad ISA coverage, including AVX-512 VNNI, AMX and SVE2, each detected, dispatched and
  timed separately.
- Stable C ABI over raw pointers and strides; easy to bind (there is a Python wrapper).
- Stateful operations reuse set-up across ISAs through class inheritance and factory
  fallback.
- Function lists of the `SIMD_FUNCn` macros make the supported ISAs of each function
  explicit at the dispatch site.
- Thorough reference documentation of `View`, `Frame` and `Parallel`, with ownership
  rules and in-tree usage spelled out.
- Fuzz targets with seed corpora for decoders and kernels; the load harness is shared
  with OSS-Fuzz.

## Weaknesses

- About seven times the code of the scalar implementation, written and maintained by
  hand; a fix to one variant does not reach the others.
- The dispatcher is compiled with the union of ISA flags and executes VEX instructions on
  CPUs without AVX (verified `SIGILL` in `SimdGetFastMode`).
- No `XCR0` check on GCC or Clang.
- No argument validation in release builds; aliasing behaviour differs by ISA (verified).
- Negative strides work only by `size_t` wraparound.
- Test coverage per ISA depends on compile flags and the CI runner, and a run can pass
  while testing only `Base` (verified).
- Threading creates threads per call; no pool and no cross-operation tiling.
- No colour management or metadata; codecs are one-shot.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                               | Trade-off                                                                                     |
| ------------------------------------------------------------ | ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| One file per function per ISA, hand-written intrinsics       | Full control of each ISA's best instruction sequence                    | Code multiplies by ISA count; variants drift; no shared source to fix once                    |
| ISA chosen by per-file compiler flags and predefined macros  | Works with every compiler and build system, including MSVC              | The dispatcher needs the union of flags, which leaks wide instructions into fallback paths    |
| Detection at static initialisation into `const bool Enable`  | Zero-cost checks in the dispatcher                                      | No lazy or overridable selection; OS-state check only on MSVC                                 |
| Per-call `if` chain with width guards (older functions)      | Lets narrow images fall back to narrower kernels with overlapping tails | Branches per call; minimum widths copied by hand into dispatcher and tests                    |
| Static function pointer via `SIMD_FUNCn` (newer functions)   | One selection per process; per-function ISA list                        | No argument-dependent choice; still requires the union flags                                  |
| Class inheritance chain for stateful operations              | Set-up written once; only `Run` specialised                             | Virtual dispatch per call; layout and tables shared across ISAs by convention                 |
| C ABI with separate pointer, stride and size arguments       | Stable binary interface and easy bindings                               | No type safety, signed strides wrapped through `size_t`, contracts only in prose and `assert` |
| Every variant tested against the public function             | Transitive equivalence with `Base`, plus per-ISA timing in one run      | Which variants run depends on test compile flags and the host CPU                             |
| `Runtime` autotuning inside one ISA (Synet convolution only) | Picks between kernel strategies on real data                            | First calls are slower and timing-dependent; nondeterministic choice                          |

## Sources

- [ermig1979/Simd][repo], [documentation][docs], [`README.md`][readme], [`AGENTS.md`][agents], [`LICENSE`][license]
- Dispatch and detection: [`SimdLib.cpp`][lib-absdiff] ([resizer][lib-resizer], [GEMM][lib-gemm]), [`SimdEnable.h`][enable-h], [`SimdAvx2Cpu.cpp`][avx2-cpu], [`SimdAvx512bwCpu.cpp`][avx512-cpu], [`SimdNeonCpu.cpp`][neon-cpu], [`SimdDefs.h`][defs-enable], [`SimdEmpty.h`][empty-h], [`SimdRuntime.h`][runtime-h]
- Build: [`x86.cmake`][x86-cmake], [`CMakeLists.txt`][cmake-options]
- Kernels: `AbsDifference` in [Base][base-absdiff], [SSE4.1][sse41-absdiff], [AVX2][avx2-absdiff], [AVX-512BW][avx512-absdiff], [NEON][neon-absdiff]; [`SimdConst.h`][const-sse41]; [`SimdResizer.h`][resizer-h]; [`SimdAvx2Resizer.cpp`][avx2-resizer]
- Types and API: [`SimdView.hpp`][view-struct], [`SimdFrame.hpp`][frame], [`SimdLib.h`][libh-absdiff], [`SimdLib.hpp`][libhpp-absdiff], [`SimdAlignment.h`][alignment-h], [`SimdMemory.h`][memory-h], [`SimdParallel.hpp`][parallel], [`SimdBaseThread.cpp`][thread]
- Codecs, hostile input and video: [`SimdImageLoad.h`][imageload-h], [`SimdBaseImageLoadBmp.cpp`][bmp-limits], [`SimdBaseImageLoadPng.cpp`][png-limits], [`simd_load_fuzzer.cpp`][fuzz-load], [`SimdMotion.hpp`][motion]
- Testing: [`TestAbsDifference.cpp`][test-absdiff], [`TestResize.cpp`][test-resize], [`TestOptions.h`][test-options], [`TestConfig.h`][test-config], [`Test.cpp`][test-sizes], [`test.yml`][ci-test], [`cmake.yml`][ci-cmake]
- Related: [Highway](./highway.md), [OpenCV](./opencv.md), [intel-intrinsics](./intel-intrinsics.md), [libjpeg-turbo](./libjpeg-turbo.md), [concepts](./concepts.md), [baseline: shaders and host SIMD](./baseline/shaders-simd.md), [baseline: existing code](./baseline/existing-code.md)

<!-- References -->

[repo]: https://github.com/ermig1979/Simd
[docs]: https://ermig1979.github.io/Simd/
[license]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/LICENSE
[readme]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/README.md#L9-L14
[readme-options]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/README.md#L100
[readme-fuzz]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/README.md#L109-L133
[agents]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/AGENTS.md#L71-L74
[lib-absdiff]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdLib.cpp#L285-L315
[lib-resizer]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdLib.cpp#L3927-L3940
[lib-gemm]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdLib.cpp#L2653-L2660
[lib-descr]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdLib.cpp#L2030-L2037
[lib-rbf]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdLib.cpp#L3659-L3667
[enable-h]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdEnable.h#L30-L157
[avx2-cpu]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdAvx2Cpu.cpp#L36-L85
[avx512-cpu]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdAvx512bwCpu.cpp#L36-L66
[neon-cpu]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdNeonCpu.cpp#L44-L62
[defs-enable]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdDefs.h#L187-L232
[empty-h]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdEmpty.h#L28-L58
[runtime-h]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdRuntime.h#L44-L196
[x86-cmake]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/prj/cmake/x86.cmake#L7-L82
[cmake-options]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/prj/cmake/CMakeLists.txt#L4-L21
[base-absdiff]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdBaseAbsDifference.cpp#L31-L43
[sse41-absdiff]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdSse41AbsDifference.cpp#L33-L55
[avx2-absdiff]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdAvx2AbsDifference.cpp#L37-L73
[avx512-absdiff]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdAvx512bwAbsDifference.cpp#L34-L70
[neon-absdiff]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdNeonAbsDifference.cpp#L33-L69
[const-sse41]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdConst.h#L81-L92
[const-avx2]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdConst.h#L188-L199
[const-vnni]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdConst.h#L571-L581
[resizer-h]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdResizer.h#L117-L131
[resizer-chain]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdResizer.h#L476-L512
[avx2-resizer]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdAvx2Resizer.cpp#L36-L63
[imageload-h]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdImageLoad.h#L57-L89
[imageload-chain]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdImageLoad.h#L249-L372
[view-doc]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdView.hpp#L42-L147
[view-struct]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdView.hpp#L198-L284
[view-flipped]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdView.hpp#L1582-L1585
[frame]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdFrame.hpp#L94-L135
[libh-absdiff]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdLib.h#L1266-L1289
[libh-load]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdLib.h#L4171-L4194
[libh-format]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdLib.h#L419-L472
[libh-yuv]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdLib.h#L746-L760
[libhpp-absdiff]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdLib.hpp#L94-L99
[alignment-h]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdAlignment.h#L32-L76
[memory-h]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdMemory.h#L130-L152
[parallel]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdParallel.hpp#L35-L147
[thread]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdBaseThread.cpp#L33-L44
[bmp-limits]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdBaseImageLoadBmp.cpp#L174-L186
[png-limits]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdBaseImageLoadPng.cpp#L954-L966
[png-intmax]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdBaseImageLoadPng.cpp#L1075-L1081
[fuzz-load]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Fuzz/simd_load_fuzzer.cpp#L25-L70
[motion]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Simd/SimdMotion.hpp#L711-L786
[test-absdiff]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Test/TestAbsDifference.cpp#L35-L123
[test-resize]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Test/TestResize.cpp#L177-L199
[test-options]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Test/TestOptions.h#L353-L370
[test-config]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Test/TestConfig.h#L100-L101
[test-sizes]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/src/Test/Test.cpp#L881-L889
[ci-test]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/.github/workflows/test.yml#L10-L82
[ci-cmake]: https://github.com/ermig1979/Simd/blob/37dd13062b5b2a37b70fd23b232d66d594402369/.github/workflows/cmake.yml#L145-L175
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
[build-settings]: ../../guidelines/build-settings.md
[p-generic]: ./papers/generic-image-programming.md
[p-hostile]: ./papers/hostile-input-safety.md
