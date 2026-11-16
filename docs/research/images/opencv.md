# OpenCV (C++)

A computer-vision library built around a run-time-typed, reference-counted, strided N-D array (`cv::Mat`), with an OpenCL twin (`UMat`), a replaceable kernel layer (HAL), portable SIMD wrappers (universal intrinsics) and a codec front door (`imgcodecs`) layered on third-party decoders.

| Field         | Value                                                                                                                                                                                                         |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++17 core with C-style HAL signatures; Python, Java, JavaScript (Emscripten) and Objective-C bindings generated from the headers                                                                             |
| License       | Apache License 2.0 ([`LICENSE`][license])                                                                                                                                                                     |
| Repository    | [opencv/opencv][repo] (algorithms outside the core in [opencv/opencv_contrib][contrib])                                                                                                                       |
| Revision read | `96f8c0761e75c98de6d1dba06a102377e6e29497` (`5.x`, October 27, 2026; [`version.hpp`][version] says `5.1.0-pre`); comparisons with the 4.x line read tag `4.13.0` (`fe38fc608f6acb8b68953438a62305d8318f4fcd`) |
| Documentation | [docs.opencv.org/5.x][docs] · Doxygen comments in the public headers, quoted below                                                                                                                            |
| Category      | Generic libraries: run-time-typed dense array, transparent GPU offload, hand-vectorised kernels, codec adapters                                                                                               |
| Tier          | A                                                                                                                                                                                                             |
| Last reviewed | November 15, 2026                                                                                                                                                                                             |

> [!NOTE]
> Claims marked **verified** were demonstrated by compiling and running probes in a
> scratch directory. Verification reran the type-code probe against the pinned `5.x`
> `hal/interface.h` and the `4.13.0` one with GCC 16.2.0. The behaviour probes linked OpenCV 4.13.0 from
> nixpkgs, because the pinned `5.x` tree was not built; where `5.x` source differs
> from what 4.13.0 does, the text says so. A separate header-only probe confirmed
> the pinned `5.x` `CV_DbgAssert` macro is inactive without `_DEBUG` and active
> with it. An independent D probe used LDC 1.43.0 with
> `-betterC -preview=dip1000`. These are scratch probes, not CI-maintained examples.
> No performance number in this page was measured.

---

## Overview

### What it solves

Computer-vision code mixes images, matrices, point sets, tensors and histograms.
OpenCV supplies one container for these dense arrays. A `cv::Mat` is a header
(dimensions, a type code, per-dimension byte steps, a data pointer) plus a
reference-counted buffer, so the same object is a 640x480 BGR image, a 3x3 `double`
matrix or a 4-D network blob. The class comment states the model and its
address formula ([`mat.hpp`][mat-doc]):

> _"The class Mat represents an n-dimensional dense numerical single-channel or multi-channel array."_

Around that container sit four layers that are each a design data point for Sparkles:
a function-argument proxy (`InputArray`/`OutputArray`) that accepts several array
types; a device-resident twin (`UMat`) that routes supported calls to OpenCL; a
replaceable kernel interface (the HAL) with CPU-feature dispatch of
hand-vectorised kernels underneath; and `imgcodecs`, a registry of decoders behind
`imread` and `imdecode`.

### Design philosophy

Three choices recur through the tree.

1. **Types are run-time values.** Element depth and channel count are packed into an
   `int` (`CV_8UC3`), so one compiled `cv::GaussianBlur` serves its supported types, every
   binding language and every caller that learns the type only after decoding a file.
   Templates (`Mat_<T>`, `Vec3b`) exist as thin typed veneers over the same header.
2. **Copies are cheap and shared by default.** The documentation is explicit that
   _"the array assignment is an O(1) operation because it only copies the header and
   increases the reference counter"_ ([`mat.hpp`][mat-doc-assign]); a deep copy is
   `clone()`. Sub-regions, rows and columns are new headers over the same buffer.
3. **Arguments are proxies, outputs are allocated by the callee.** A function declares
   `InputArray`/`OutputArray` parameters and calls `_dst.create(size, type)`, which
   reallocates only when shape or type differs. The proxy documentation warns that
   "The class is designed solely for passing parameters. That is, normally you
   _should not_ declare class members, local and global variables of this type."
   ([`mat.hpp`][inputarray-doc])

Errors include C++ exceptions
(`cv::Exception` from `CV_Assert`) and empty decode results; colour order defaults to BGR,
and the codec layer delegates parsing to libpng, libjpeg-turbo, libtiff, libwebp,
libavif, libjxl, OpenEXR and others.

---

## How it works

### The `Mat` header

The public fields are a flat struct ([`mat.hpp`][mat-fields]):

```cpp
// modules/core/include/opencv2/core/mat.hpp (cv::Mat, abridged)
int flags;              // magic, continuity flag, submatrix flag, depth, channels
int dims;               // >= 2 for classic matrices
int rows, cols;         // -1 when dims > 2
uchar* data;            // first element of this view
const uchar* datastart; // start of the shared buffer (for locateROI/adjustROI)
const uchar* dataend;
const uchar* datalimit;
MatAllocator* allocator;
UMatData* u;            // the shared, reference-counted buffer record
MatSize size;           // MatShape: dims, layout, int p[MAX_DIMS]
MatStep step;           // size_t p[MatShape::MAX_DIMS], bytes per dimension
```

Element `(i0, …, i_{d-1})` lives at `data + step[0]*i0 + … + step[d-1]*i_{d-1}`, with
`step[d-1]` equal to the element size. The steps are bytes, not elements, which is the
[stride][concepts-stride] convention NumPy and GIL share. Channels are not a
dimension: a 3-channel 8-bit image is a 2-D array of 3-byte elements.

The buffer record is `UMatData` ([`mat.hpp`][umatdata]): two counters (`refcount` for
host `Mat` headers, `urefcount` for `UMat` headers), `data`/`origdata`/`size`, the
`MatAllocator` that owns it, a device `handle`, and coherence flags
(`HOST_COPY_OBSOLETE`, `DEVICE_COPY_OBSOLETE`, `COPY_ON_MAP`). Copy construction copies
the header state and then runs `CV_XADD(&u->refcount, 1)`, an atomic add
([`matrix.cpp`][mat-copy]); `release()` decrements and calls the allocator's
`unmap` when the host count reaches zero; the default `unmap` deallocates only when
both counters are zero ([`release`][mat-release], [`Mat::deallocate`][mat-deallocate],
[default `unmap`][mat-unmap]). A header built over caller memory
(`Mat(rows, cols, type, void* data, size_t step)`) has `u == 0` and is not counted
([`matrix.cpp`][mat-userdata]).

### Type codes

`CV_MAKETYPE(depth, cn)` is `CV_MAT_DEPTH(depth) + ((cn - 1) << CV_CN_SHIFT)`
([`interface.h`][interface-types]). The `5.x` branch widened the depth field from three
bits to five and added depths: `CV_16BF`, `CV_Bool`, `CV_64U`, `CV_64S`, `CV_32U` and
two 8-bit float formats (`CV_8F_E4M3FN`, `CV_8F_E4M3FNUZ`), with `CV_DEPTH_CURR_MAX 15`.
The channel limit fell from 512 to 128 as a result:

```c
// modules/core/include/opencv2/core/hal/interface.h (5.x)
#define CV_CN_MAX     128
#define CV_CN_SHIFT   5
#define CV_DEPTH_MAX  (1 << CV_CN_SHIFT)
```

Tag `4.13.0` has `CV_CN_MAX 512` and `CV_CN_SHIFT 3` ([`interface.h` at
4.13.0][interface-413]). **Verified:** the same program compiled against each header
prints `CV_8UC3=64 CV_32FC3=69` for `5.x` and `CV_8UC3=16 CV_32FC3=21` for `4.13.0`; the
numeric value of every multi-channel type code changed. `Mat::type()` returns the low 12
bits of `flags`; bit 14 is `CV_MAT_CONT_FLAG` and bit 15 `CV_SUBMAT_FLAG`
([`cvdef.h`][cvdef-flags]). The class-local `Mat::DEPTH_MASK = 7` enumerator still has
the 4.x width ([`mat.hpp`][mat-fields]);
`Mat::depth()` uses `CV_MAT_DEPTH` instead ([`mat.inl.hpp`][mat-depth]).

`MatShape` replaced `std::vector<int>` as the shape type in `5.x`. Its comment lists
the reasons ([`mat.hpp`][mat-shape]): _"avoids any heap operations, since the shape is
stored in a plain array"_, carries a `DataLayout` (`NCHW`, `NHWC`, a blocked
`NC1HWC0`), and distinguishes an empty shape from a 0-D scalar. `MAX_DIMS` is 10.

### Continuity and sub-matrices

A view is continuous when its rows abut, so an element-wise kernel can treat it as one
long row. `updateContinuityFlag` walks the dimensions from the innermost outward,
breaks at the first `step[j]*size[j] < step[j-1]`, and also refuses continuity unless
the scalar-component count (including channels) survives `t == (uint64)(int)t`,
with unchecked multiplication into `t`; arrays of rank at most one bypass this count test
([`matrix.cpp`][mat-continuity]). `Mat(m, Rect)` moves `data`, keeps
`datastart`/`dataend`, copies `step[0]`, sets `SUBMATRIX_FLAG` for a reduced region
and bumps the count ([`matrix.cpp`][mat-roi]); `locateROI` recovers the parent size
and offset from `datastart`. **Verified** on 4.13.0: a 2x2 ROI of a 4x4
`CV_8UC3` image reports `continuous=0 step0=12 step1=3 submatrix=1` and offset `(1,1)`,
a single row reports `continuous=1`, and writing through a header copy changes the
original (`refcount=2`, same `data`).

### `InputArray` and `OutputArray`

`_InputArray` stores `flags`, a `void* obj` and a `Size` ([`mat.hpp`][inputarray-storage]).
The kind in `flags` (`MAT`, `MATX`, `STD_VECTOR`, `STD_VECTOR_MAT`, `UMAT`,
`CUDA_GPU_MAT`, `OPENGL_BUFFER`, …) selects how the proxy accesses the object
([kinds][inputarray-kinds]).
`getMat()` wraps many host inputs without copying; `std::vector<bool>` instead
allocates and copies ([`matrix_wrap.cpp`][inputarray-getmat]). `_OutputArray` adds `create()`, `needed()` for
optional outputs, and a `DepthMask` enumeration that lists which depths an output may take
([`mat.hpp`][outputarray-depth], [output operations][outputarray-ops]). The proxy is the reason one C++ signature serves
`std::vector<Point2f>`, `Matx23f`, `Mat` and `UMat`. Type checking happens inside the callee:

```cpp
// mat.hpp, documentation example for a user function taking InputArray (abridged)
Mat src = _src.getMat(), m = _m.getMat();
CV_Assert( src.type() == CV_32FC2 && m.type() == CV_32F && m.size() == Size(3, 2) );
_dst.create(src.size(), src.type());
```

### `UMat` and the transparent API

`UMat` repeats the `Mat` interface without a `data` pointer. Its comment, rewritten on
`5.x`, describes the routing rule precisely ([`mat.hpp`][umat-doc]):

> _"Passing UMat instead of Mat to a cv:: function is the basis of the Transparent API
> (T-API). The dispatch is not keyed on the allocator: a cv:: call takes its OpenCL
> branch when OpenCL is active and the arguments are UMat objects, and otherwise maps
> the data back to host memory and runs the CPU implementation."_

Each accelerated function opens with `CV_OCL_RUN(condition, ocl_impl(...))`. In the
default build the macro runs the OpenCL implementation inside `try`, returns if it
reports success, and otherwise swallows the `cv::Exception` and falls through to the
CPU path ([`ocl_defs.hpp`][ocl-run]):

```cpp
// Schematic expansion of the default CV_OCL_RUN_ variant, not a verbatim excerpt.
if (condition) {
    try {
        if (cv::ocl::isOpenCLActivated() && func) { return __VA_ARGS__; }
    }
    catch (const cv::Exception& e) {
        CV_UNUSED(e); /* TODO: Add some logging here */
    }
}
```

`cvtColor` shows the condition shape: `_src.dims() <= 2 && _dst.isUMat() && …`
([`color.cpp`][cvtcolor]). Host access goes through `UMat::getMat(ACCESS_*)`, which
maps the buffer when the host count goes from zero to one
([`umatrix.cpp`][umat-getmat]); `UMat::handle()` asserts `u->refcount == 0`, that is, no
host mapping may be alive while the device handle is taken
([`umatrix.cpp`][umat-handle]). A dead parent with a live derived object is reported
only by a warning compiled under `#ifndef NDEBUG` ([`umatrix.cpp`][umat-warn]).

### The HAL and CPU dispatch

Below the `InputArray` API many image operations have a HAL entry over raw pointers and
byte steps, for example `hal::cvtBGRtoGray(const uchar* src_data, size_t src_step,
uchar* dst_data, size_t dst_step, int width, int height, int depth, int scn, bool
swapBlue)`. After instrumentation it calls two macros ([`color_rgb.dispatch.cpp`][rgb-dispatch]):

```cpp
// modules/imgproc/src/color_rgb.dispatch.cpp
CALL_HAL(cvtBGRtoGray, cv_hal_cvtBGRtoGray, src_data, src_step, dst_data, dst_step, width, height, depth, scn, swapBlue);

CV_CPU_DISPATCH(cvtBGRtoGray, (src_data, src_step, dst_data, dst_step, width, height, depth, scn, swapBlue),
    CV_CPU_DISPATCH_MODES_ALL);
```

`cv_hal_cvtBGRtoGray` is defined as `hal_ni_cvtBGRtoGray`
([`hal_replacement.hpp`][imgproc-hal-define]), an inline stub returning
`CV_HAL_ERROR_NOT_IMPLEMENTED` ([`hal_replacement.hpp`][imgproc-hal-ni]); a vendor HAL
(`hal/` holds `ipp`, `carotene` for NEON, `fastcv`, `kleidicv`, `armpl`, `riscv-rvv`,
`ndsrvp`) redefines the macro through `custom_hal.hpp`
([`hal_replacement.hpp`][imgproc-hal-custom]). `CALL_HAL` returns on `OK`, continues on
`NOT_IMPLEMENTED`, and raises `StsInternal` on any other code
([`hal_replacement.hpp`][core-call-hal]). The replacement is a compile-time macro
substitution, so the HAL is chosen when OpenCV is built.

`CV_CPU_DISPATCH` is the run-time half. CMake compiles a `*.simd.hpp` file for the
baseline and each enabled dispatch target from the module's list
(`ocv_add_dispatched_file(color_rgb SSE2 SSE4_1 AVX2 AVX512_SKX AVX512_ICL)`,
[`imgproc/CMakeLists.txt`][imgproc-cmake], [target filtering][dispatch-cmake]), each
copy inside a namespace named by `CV_CPU_OPTIMIZATION_NAMESPACE_BEGIN` (`opt_AVX2`, `cpu_baseline`,
[`cv_cpu_dispatch.h`][cpu-dispatch-h]). The macro expands into a chain of guarded
returns, one per mode, ending in the baseline ([`cv_cpu_helper.h`][cpu-helper-avx2]):

```cpp
// modules/core/include/opencv2/core/cv_cpu_helper.h (target dispatched, not baseline)
#  define CV_CPU_HAS_SUPPORT_AVX2 (cv::checkHardwareSupport(CV_CPU_AVX2))
#  define CV_CPU_CALL_AVX2(fn, args) if (CV_CPU_HAS_SUPPORT_AVX2) return (opt_AVX2::fn args)
```

When the baseline already includes a target, its macro becomes an unconditional
call to `cpu_baseline`. That branch needs no run-time check; wider dispatched targets
may still be tested first.

### Universal intrinsics

The kernels in `*.simd.hpp` are written once against wrapper types: fixed-width
`v_uint8x16`, `v_float32x4`, … and width-agnostic `v_uint8`, `v_float32`, whose lane
count is `VTraits<T>::vlanes()` ([`RGB2RGB` usage][rgb2rgb]). The documentation
lists SSE, NEON, VSX, MSA, LSX, RVV 0.7.1 and WASM at 128 bits, AVX2 and LASX at 256,
and AVX-512 at 512, with a scalar C++ fallback
_"when there is no SIMD extension available during compilation"_ ([`intrin_cpp.hpp`][intrin-doc]).
Its _"Vector Length Agnostic (VLA)"_ list includes RVV 1.0 and SVE, but describes
SVE as powered by KleidiCV. The actual header selection includes a scalable RVV
wrapper and no SVE wrapper ([`intrin.hpp`][intrin-select]); KleidiCV is integrated
through its external OpenCV HAL adapter ([`hal/kleidicv/CMakeLists.txt`][kleidicv-hal]). The
`RGB2RGB` kernel ([`color_rgb.simd.hpp`][rgb2rgb]) shows the idioms: deinterleaving
loads, a lane swap for BGR/RGB, and a tail handled by stepping back so the last vector
overlaps the previous one, unless the call is in place or shorter than one vector:

```cpp
// modules/imgproc/src/color_rgb.simd.hpp, tail handling inside the vector loop
if ( i > n - vsize ) {
    if (i == 0 || src == dst) {
        break;
    }
    int backup = i - (n - vsize);
    i = n - vsize;
    src -= backup * scn;
    dst -= backup * dcn;
}
```

### `parallel_for_`

`parallel_for_(Range, ParallelLoopBody, nstripes)` (and a `std::function` overload,
[`utility.hpp`][parallel-api]) splits a range into stripes and hands them to whichever
framework the build selected: TBB, HPX, OpenMP, GCD, the Windows concurrency runtime or
a built-in pthreads pool ([`parallel.cpp`][parallel-impl]); a
`ParallelForAPI` object can be installed at run time with `setParallelForBackend`
([`parallel_backend.hpp`][parallel-backend]). Nesting is detected with one
function-local `static std::atomic<bool> flagNestedParallelFor`, and a call that finds
it set runs `body(range)` serially ([`parallel.cpp`][parallel-nested]). Because the
flag is shared by threads, an overlapping call from an unrelated thread also runs
its range unsplit; it does not wait for the first call. **Verified** on 4.13.0:
holding one call open makes a second call over `[0,100)` invoke its body once with
the full range; after the first finishes, the same request produces 100 body calls.
The pinned `5.x` behavior was checked in source, not run.

### `imgcodecs`

The normal `imread`/`imdecode` registry selects a decoder by content signature, not by extension: every
registered `BaseImageDecoder` reports `signatureLength()` and answers
`checkSignature()` on the longest prefix ([`loadsave.cpp`][find-decoder]).
`imread` can instead select GDAL explicitly with `IMREAD_LOAD_GDAL`
([`loadsave.cpp`][imread-select]). The decoder
interface is two calls plus options ([`grfmt_base.hpp`][decoder-iface]):

```cpp
// modules/imgcodecs/src/grfmt_base.hpp (BaseImageDecoder, abridged)
virtual bool setSource(const String& filename);
virtual bool setSource(const Mat& buf);   // false: this codec cannot read memory
int setScale(const int& scale_denom);
int setReadOptions(int read_options);     // metadata extraction
virtual bool readHeader() = 0;            // fills m_width, m_height, m_type
virtual bool readData(Mat& img) = 0;      // decodes into a preallocated Mat
virtual void setRGB(bool useRGB);
virtual bool nextPage() { return false; }
const Animation& animation() const;
```

`imread_` runs `readHeader`, validates the size, computes the output type from the
`IMREAD_*` flags, allocates, then `readData`, then optionally downsamples
(`IMREAD_REDUCED_*`) and applies the EXIF orientation ([`loadsave.cpp`][imread-core]).
The common decoded-size limits are `static const size_t` values read
by `utils::getConfigurationParameterSizeT` from `OPENCV_IO_MAX_IMAGE_WIDTH` and
`OPENCV_IO_MAX_IMAGE_HEIGHT` (default `1 << 20` each) and `OPENCV_IO_MAX_IMAGE_PIXELS`
(default `1 << 30`) at static-initialisation time, checked by `validateInputImageSize`
with a 64-bit product ([`loadsave.cpp`][io-limits]).

When a decoder's `setSource(const Mat&)` returns false, `imdecode_` writes the buffer to
a temporary file and decodes that ([`loadsave.cpp`][imdecode-tempfile]). At this revision
`IMREAD_COLOR_RGB` asks the decoder for RGB order ([`imgcodecs.hpp`][imread-modes]),
and `imreadWithMetadata`/`imdecodeWithMetadata` return EXIF, XMP, ICC and CICP blocks
as raw bytes where the codec supports them ([metadata types][metadata-types],
[`imreadWithMetadata`][imread-metadata], [`imdecodeWithMetadata`][imdecode-metadata]).

---

## Analysis

### 1. Pixel and memory model

One dense, strided N-D array with interleaved channels inside the element. Steps are
`size_t` bytes per dimension, with `step[d-1] == elemSize()`; outer steps may pad.
The 2-D caller-buffer constructor also checks row-step size and divisibility
([`matrix.cpp`][mat-userdata]). There is no per-plane image descriptor: a YUV 4:2:0 frame can be a
single-channel `Mat` of height `h * 3 / 2` whose layout the colour-conversion code
knows ([concepts: interleaved, planar and semi-planar][concepts-planar]). Extents are
`int` and `MAX_DIMS` is 10. Negative steps (flips as views) are not representable;
`flip` copies. Sub-views are zero-copy and share the buffer record. The continuity flag
is a cached property of the header that kernels test to collapse loops. Compared with
[mir's `Slice`][mir], which carries contiguity in the type, and
[GIL][boost-gil], which carries the pixel layout in the type, ordinary multi-channel
`Mat` fixes interleaved storage, puts depth and channel count in `flags`, and caches
continuity there.

### 2. Genericity mechanism

Run-time type codes plus internal template instantiation. A public function takes
`InputArray`, reads `type()`, and switches to a table of function pointers or template
instances per depth; `Mat_<T>` and `DataType<T>` map C++ types to codes for the typed
veneer. Unsupported formats can fail run-time assertions. The bounds and
scalar-size checks in `Mat::at<T>(row, col)` are debug-only; they do not compare the
full type code, so equal-size types can pass even with checks enabled
([`mat.inl.hpp`][mat-at]). The `5.x` branch moved `CV_DbgAssert` to
`exception.hpp` and conditions it on `_DEBUG` or `CV_STATIC_ANALYSIS`
([`exception.hpp`][dbgassert-5]), where 4.13.0 tested `!defined(NDEBUG)` or
`CV_STATIC_ANALYSIS` ([`base.hpp` at 4.13.0][dbgassert-413]). On GCC and
Clang, which do not define `_DEBUG` themselves, an unoptimised caller can therefore
omit these checks; OpenCV's own CMake Debug flags explicitly add `-D_DEBUG`
([compiler options][debug-flags]). **Verified** on 4.13.0: without `NDEBUG`,
`at<float>(0,0)` on a `CV_8UC1` image throws `-215`; with `-DNDEBUG` it returns the
reinterpreted bytes `0x07070707` without error. Even without `NDEBUG`,
`at<int>(0,0)` on `CV_32FC1` containing `1.0f` returns `0x3f800000` without error.
The `5.x` accessor was checked in source, not run; its assertion macro was separately
tested against the pinned header with and without `_DEBUG`.

### 3. Colour and metadata

Colour is a convention, not a type. `imread` documents that _"the decoded images will
have the channels stored in **B G R** order"_ ([`imgcodecs.hpp`][imread-bgr]), and
nothing in a `Mat` records whether its three channels are BGR, RGB, YCrCb or Lab; the
`cvtColor` code names the interpretation at each call. The XYZ transform uses
the sRGB/D65 matrix without transfer-function decoding ([`color_lab.cpp`][color-xyz]);
Lab defaults to the same primaries and white point ([Lab coefficients][color-lab]),
with sRGB or linear input selected by the conversion code ([`is_sRGB`][color-srgb]). There
is no colour-space, transfer-function or alpha-state tag in `Mat`
([concepts][concepts-alpha]); codec behavior is separate, and the `imread`
documentation notes colour management in native macOS loaders. At this revision the
codecs can surface metadata as opaque byte blocks (`IMAGE_METADATA_EXIF`, `XMP`,
`ICCP`, `CICP`), which leaves interpretation to the caller. **Verified** on 4.13.0: a
red pixel written from `Scalar(0, 0, 255)` decodes as `(0,0,255)` with
`IMREAD_COLOR` and `(255,0,0)` with `IMREAD_COLOR_RGB`. Compare the typed colour spaces
in [color][color] and [JuliaImages][juliaimages].

### 4. I/O and codec architecture

Pull, whole-image, synchronous. A decoder is a stateful object that reads a header
and then decodes the whole image into a preallocated `Mat`; there is no incremental
feed, no suspension and no row callback in the public interface
([concepts: incremental and suspendable decoding][concepts-suspendable]). Formats are
mostly thin adapters over C libraries, selected at build time; a decoder that cannot
read memory forces a temporary file. Multi-page and animated input use
`imreadmulti`, `ImageCollection` (lazy page iteration) and `Animation` with
`imreadanimation`/`imwriteanimation`. The output type is decided before decoding from
the flags (`IMREAD_ANYDEPTH`, `IMREAD_ANYCOLOR`, `IMREAD_GRAYSCALE`), which lets a
codec convert during decode (JPEG's DCT-domain downscale for `IMREAD_REDUCED_*`).

### 5. Hostile input and safety

Bounds come from three places: the third-party codec's own checks, OpenCV's size
validation after `readHeader`, and `CV_Assert` on the `Mat` constructors. The size
limits are by declared dimension, not by work or memory, and are process-wide
environment settings read once. Errors travel on two channels: a failing `readHeader`
or `readData` makes the returning overloads yield an empty `Mat` (caught exceptions
are logged), but a supplied `imdecode` destination can remain allocated
([`loadsave.cpp`][imdecode-result]). `validateInputImageSize` runs
outside the `try` and its `CV_Assert` escapes as an exception
([`loadsave.cpp`][imread-core]). **Verified** on 4.13.0 with PPM inputs (no codec-side
limit): a valid 2x2 image decodes; truncated pixel data logs `Unexpected end of input
stream` and returns an empty `Mat`; a header declaring width 2^21 throws
`cv::Exception` code `-215`; with `OPENCV_IO_MAX_IMAGE_PIXELS=3` the valid 2x2 image
throws too. For PNG, libpng's own width limit fired first and `imdecode` returned empty.

The `Mat` layer trusts its arithmetic more on `5.x` than on 4.x. The 4.13.0 `setSize`
asserted `s >= 0` for each extent and checked whether a `uint64` product narrowed
when converted to `size_t` (not a full multiplication-overflow check on 64-bit
platforms, [`matrix.cpp` at 4.13.0][setsize-413]); the `5.x` `setSize`, rewritten
around `MatShape`, computes `m.size[i+1]*m.step[i+1]` with neither check
([`matrix.cpp`][setsize-5]), and `MatShape` admits negative entries on purpose
([`hasSymbols()`][mat-symbols] for symbolic shapes). Whether a negative extent now reaches the
allocator was not tested. The `Mat(m, Rect)` check `roi.x + roi.width <= m.cols` adds
two `int` values, which can overflow before the comparison ([`matrix.cpp`][mat-roi]).
The [hostile-input papers][p-hostile] and [concepts: hostile input][concepts-hostile]
treat these as the classic failure shapes. External OSS-Fuzz recipes list
`imdecode_fuzzer`, `imread_fuzzer`, `core_fuzzer` and others, and clone the OpenCV
default branch at depth 1 ([`build.sh`][ossfuzz-build], [`Dockerfile`][ossfuzz-docker]). This is
evidence of fuzz targets, not a verified working `5.x` build: the recipe hard-codes
`include/opencv4` and 4.x module libraries, while the pinned Unix install uses
`include/opencv5` ([install layout][install-layout]). The full OSS-Fuzz build was
not run. `SECURITY.md` supplies reporting instructions and a PGP key ([`SECURITY.md`][security]).

### 6. Allocation and ownership

Intrusive atomic reference counting on a heap record, with a pluggable `MatAllocator`
interface (`allocate`, `deallocate`, `map`, `unmap`, `upload`, `download`, `copy`,
[`mat.hpp`][mat-allocator]) and a global default settable by `Mat::setDefaultAllocator`.
`StdMatAllocator` uses `fastMalloc` (aligned) and marks caller memory
`USER_ALLOCATED` ([`matrix.cpp`][std-allocator]). Owned buffers are implicitly shared:
each header copy or ROI is a co-owner, and mutation through any of them is
visible to all. `create()` releases and reallocates when the shape or type differs
([`matrix.cpp`][mat-create]), which silently detaches the object from its former
sharers. **Verified** on 4.13.0: after `Mat c = a; a.create(8, 8, CV_8UC3)`, `c` keeps
the old buffer with its remaining count and `a.data != c.data`. This is the classic
in-place hazard: `f(src, dst)` with `dst` aliasing `src` and a different output shape
leaves other headers over the old buffer unchanged. `create()` does not copy the old
pixels into the new allocation. The proxy rule (never store an
`InputArray`) is a convention, not something the type system enforces.

### 7. CPU parallelism and SIMD

Universal intrinsics give one source per kernel
across x86, Arm, POWER, MIPS, LoongArch, RISC-V and WASM, with width-agnostic types for
scalable RVV; SVE acceleration is through KleidiCV's HAL adapter.
The build compiles each `*.simd.hpp` for the baseline and enabled dispatch targets;
`CV_CPU_DISPATCH` picks at run time by `checkHardwareSupport`; vendor HALs can
replace whole functions below that.
The order inside a typical function is OpenCL (if `UMat`), then HAL, then the
dispatched kernel, then scalar code ([`color.cpp`][cvtcolor],
[`color_rgb.dispatch.cpp`][rgb-dispatch]). Threading is `parallel_for_` over row
stripes with a build-time or run-time backend; one global flag makes nested and
overlapping calls run their ranges unsplit. Compare [Halide][halide], which derives the loop
nest from a schedule instead of hand-writing it per kernel, and
[concepts: algorithm and schedule][concepts-schedule].

### 8. GPU offload and interop

OpenCL through `UMat` supplies transparent acceleration for supported image
operations. CUDA algorithm modules (`cudaarithm`, `cudaimgproc`, …) live in
`opencv_contrib`, but `core` implements `cuda::GpuMat`
([header operations][gpumat-cpp], [device allocation][gpumat-cu]); `dnn` also has
CUDA and Vulkan backends ([`dnn.hpp`][dnn-backends], [Vulkan implementation][dnn-vulkan]).
Interop headers in `core` cover OpenGL buffers and
textures (`opengl.hpp`), Direct3D (`directx.hpp`) and VA-API (`va_intel.hpp`)
([`core/include`][core-include]). The T-API's silent fallback has two faces: the same
call works with or without a device, and an OpenCL implementation returning false
or throwing `cv::Exception` falls back to CPU; the catch has only a `TODO` where
the log line would be ([`ocl_defs.hpp`][ocl-run]). There is
no Vulkan compute path in `core` or `imgproc`, and no GPU decode in `imgcodecs`;
`videoio` reaches hardware decoders through FFmpeg and Media SDK backends
(`cap_ffmpeg_hw.hpp`, `cap_mfx_reader.cpp`, [`videoio/src`][videoio-src]).

### 9. Temporal, animation and containers

Two separate models. `videoio` is a capture abstraction (`VideoCapture`/`VideoWriter`)
over per-platform backends that returns `Mat` frames with properties queried by
integer id. `imgcodecs` has `Animation` ([`imgcodecs.hpp`][animation]): a loop count, a
background colour, `std::vector<int> durations` in milliseconds and
`std::vector<Mat> frames`, fully decoded into memory. The `durations` comment records
format limits rather than abstracting them (GIF rounds down to 10 ms). There is no
timestamp type, no frame-level colour metadata, and no streaming frame iterator in
`imgcodecs` beyond `ImageCollection` for pages.

### 10. Testing and conformance

GoogleTest-based `opencv_test_*` and `opencv_perf_*` binaries per module, with images
from the separate `opencv_extra` repository located through `OPENCV_TEST_DATA_PATH`;
missing optional data skips unless `OPENCV_TEST_REQUIRE_DATA` is set, while missing
required data fails ([configuration][ts-data], [`ts.cpp` lookup][ts-lookup]).
Comparisons are norms with tolerances (`cvtest::norm(..., NORM_L1)`, `EXPECT_MAT_NEAR`)
and bit-exactness where promised: the round-trip test asserts _"imread() and
imdecode() calls must provide the same result (bit-exact)"_
([`test_read_write.cpp`][test-rw]). A concrete OpenCL test runs `cvtColor` with
`OCL_OFF` on `Mat` and `OCL_ON` on `UMat`, then compares the outputs
([`test_color.cpp`][test-ocl-color]). `OCL_ON` requests OpenCL but does not itself
prove that the kernel ran on a device ([test macros][test-ocl-macros]). These tests establish self-consistency and
agreement within tolerances for selected inputs; they do not by themselves prove
format conformance. The external fuzz recipes are described above.

---

## Lessons for Sparkles

- **Q1.** The `Mat` header is the minimal general layout: byte steps per dimension,
  innermost step equal to element size, sub-views as pointer offsets. It matches what
  the [existing-code baseline][bl-existing-gaps] lacks (G2, "No pixel view type") and
  what [GIL][boost-gil] and NumPy also use, so it is a useful interop shape. What
  does not transfer: `int` extents (Sparkles uses `size_t` indices), no negative steps,
  and no planes; YUV needs per-plane extents and steps, while tiles need a further
  addressing model. `Mat` delegates these interpretations to convention.
- **Q2.** Run-time type codes are what let one binary serve every caller and every
  binding, and an image decoder in Sparkles meets the same problem: the pixel format is
  known only after `readHeader`. Operations validate supported formats at run time;
  `Mat::at<T>(row, col)` checks bounds and scalar size only in debug configurations.
  A D design can keep a
  run-time-tagged header at the codec boundary and convert it once into a typed view.
  **Verified:** a D probe under `-betterC -preview=dip1000` converts a tagged header
  into a `View!(ubyte, 3)`, rejects the same header as `View!(float, 1)`, rejects a
  header whose `rows * rowStride` overflows (`core.checkedint`), and writes through a
  sub-view into the parent buffer. The independent verification probe's `main` is
  `@safe nothrow @nogc`, with `@trusted` lambdas for the byte-to-element cast and
  `printf`; its element accessor is `@safe`. This demonstrates these operations, not
  a complete lifetime or alignment contract ([attribute rules][agents-safety]).
  After the conversion the algorithm code is typed, so
  the per-call switch disappears ([DbI guidelines][dbi]).
- **Q2, Q9.** The 4.x to 5.x renumbering (`CV_8UC3` 16 to 64) shows the cost of type
  codes as wire values: a stored multi-channel code needs a versioned interpretation.
  Sparkles' `wired` supports names or underlying values by per-format policy
  ([enum representation][wired-enums]). If an image header is serialised
  (the [wired baseline][bl-wired]), the format should define stable pixel identifiers
  independently of the in-memory bit layout.
- **Q1, Q8.** Implicit sharing makes every assignment an alias, and `create()` turns an
  alias into a separate allocation when shape or type changes, without copying its
  old pixels. Sparkles' `UniqueBuffer`/`SharedBuffer`
  split ([AGENTS: `@nogc` primitives][agents-buffer]) already forces the choice into
  the type; under dip1000 a borrowed `scope` view of a uniquely owned buffer covers
  OpenCV's ROI use case without a reference count. The `ImageRegistry` handle
  ([existing-code baseline][bl-existing-gaps], G14) is closer to `UMatData` than to
  `Mat`.
- **Q3, Q7.** The `*.simd.hpp` plus `CV_CPU_DISPATCH` pattern (compile one source per
  enabled target in a target-named namespace, chain guarded returns, collapse to a
  direct call for a target included in the baseline) is the same pattern as Sparkles' BLAKE3 kernel
  under `@target`, generalised and centralised. Where Sparkles stands: the
  [shaders and SIMD baseline][bl-shaders-gaps] (G5: dispatch "repeated by hand, with
  visibility that stops at `sparkles:base`"). OpenCV is evidence for a single shared
  dispatch facility, owned by one package, that image kernels call. Its overlapping
  tail (step the last vector back unless in place) is a portable idiom for D
  `__vector` loops.
- **Q3.** Universal intrinsics are a portable vector vocabulary with width-agnostic
  types; D's `core.simd` and the planned `sparkles:math` vectors play that role. The
  baseline notes that `sparkles:math` has no 8- or 16-bit SIMD storage
  ([shaders-simd][bl-shaders-gaps], G3); OpenCV's RGB kernel demonstrates byte and
  16-bit deinterleave and interleave operations that such storage must support.
- **Q6, Q7.** The T-API is evidence against implicit offload. Routing by argument type
  hides transfers, a false return or `cv::Exception` from the OpenCL implementation
  silently becomes a CPU run, and the
  coherence state (`HOST_COPY_OBSOLETE`, `DEVICE_COPY_OBSOLETE`) lives in a shared
  record. Taking a device handle while a host mapping lives hits `CV_Assert`;
  some derived-object lifetime problems produce only a debug warning. The useful part is the
  allocator interface (`map`, `unmap`, `upload`, `download`, `copy` over steps), which
  is the operation set a Sparkles host/device buffer needs; compare
  [Halide's two dirty bits][halide]. Baselines: [Vulkan][bl-vk] and
  [event-horizon][bl-eh].
- **Q4.** `readHeader`/`readData` into a caller-sized buffer is a sound two-phase
  shape: dimensions and type first, allocation by the caller, decode second. It fits
  `@nogc` with caller storage, as `font.png` already does ([existing-code][bl-existing-gaps],
  G6). What does not transfer: whole-image `readData`, the temporary-file fallback,
  exceptions for some failures and empty results for others. Sparkles' `Expected`
  ([AGENTS: error handling][agents-expected]) gives one channel; a suspendable decoder
  ([wired baseline][bl-wired]) needs a state machine below `readData`.
- **Q4, Q8.** Limits by environment variable read at static initialisation are global
  and cannot vary between calls in one process. A Sparkles decoder should take its
  limits (width, height, pixels, bytes, work) as a parameter value, checked with checked arithmetic, as the
  existing `maxPngPixels` partly does ([existing-code][bl-existing-gaps], G7).
- **Q5.** BGR-by-default and undeclared channel meaning are the cautionary case for
  untyped colour; `IMREAD_COLOR_RGB` and raw ICC/CICP blocks leave interpretation to the caller.
  Sparkles' colour gap ([existing-code][bl-existing-gaps], G4, G5) is better closed by
  putting channel order, transfer function and alpha state in the pixel type, as the
  [colour papers][p-colour] and [color][color] argue.
- **Q8.** The cited OpenCV tests demonstrate self-consistency of `imread` and
  `imdecode`, `UMat` against `Mat`, and tolerance norms. This does not establish a
  reference-decoder oracle for each format; Sparkles' `png_oracle.d` against stb_image
  supplies one such comparison for PNG
  ([existing-code][bl-existing-gaps], G11).
- **Q9.** OpenCV is one library with modules (`core`, `imgproc`, `imgcodecs`,
  `videoio`) rather than one package, and the boundaries fall where Sparkles' candidate
  split does: array core, algorithms, codecs. `imgcodecs` declares a dependency on
  `imgproc` ([`imgcodecs/CMakeLists.txt`][imgcodecs-cmake]; `resize` in the
  reduced-read path is one use), and `core` depends on neither. The module list at
  this revision has `calib`, `geometry`, `stereo`, `features` and `ptcloud` and no
  `calib3d` or `features2d`, which 4.13.0 has ([5.x modules][modules-5],
  [4.13.0 modules][modules-413]): module lines move between major versions,
  and the shared array type is what lets them move without changing every signature.

## Strengths

- A shared array vocabulary across algorithms, including foreign buffers wrapped
  without copying when their layouts and types meet the operation's requirements.
- Byte-stride N-D layout compatible with common positive-stride NumPy and C image layouts.
- Zero-copy ROIs, rows, columns and reshapes, with `locateROI`/`adjustROI` for halos.
- A portable SIMD layer with one source across seven
  architecture families, width-agnostic types for scalable RVV, run-time dispatch per
  file.
- A replaceable kernel layer (HAL) that lets vendors (IPP, KleidiCV, FastCV, Carotene)
  substitute implementations without forking the library.
- Transparent OpenCL acceleration that degrades to CPU when no device exists.
- Broad codec coverage behind one call, with content sniffing, EXIF orientation,
  reduced-size decode, metadata blocks and animation.

## Weaknesses

- Element type is a run-time value; channel meaning and colour order are caller
  conventions. `Mat::at<T>` can silently reinterpret equal-size scalar types even
  with debug checks enabled.
- On `5.x`, typed-accessor bounds and scalar-size checks depend on `_DEBUG` or
  `CV_STATIC_ANALYSIS`; unoptimised callers must arrange those defines themselves.
  OpenCV's own CMake Debug build supplies `_DEBUG`.
- Type code values changed between 4.x and 5.x; persisted codes are not portable.
- Implicit sharing makes aliasing the default; `create()` detaches silently;
  `UMat` host/device access checks rely on assertions, and some derived-object lifetime
  problems produce only a debug warning.
- BGR default, no colour-space or transfer-function tag, no alpha-state tag.
- Codecs are pull, whole-image, synchronous; some cannot read memory and fall back to
  a temporary file.
- Two error channels in `imread`/`imdecode` (empty result versus exception), and
  global, environment-driven limits.
- The default OpenCL fallback swallows `cv::Exception` without logging.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                            | Trade-off                                                                                     |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| Run-time type code packed in `flags`                           | one compiled function per algorithm; bindings and decoders produce types at run time | type errors at run time; per-call switches; code values become an ABI that `5.x` broke        |
| Channels inside the element, not a dimension                   | interleaved images are 2-D; kernels see `Vec3b` rows                                 | no planar or subsampled image type; YUV handled by convention                                 |
| Byte steps per dimension, innermost equals element size        | NumPy and C interop; zero-copy ROIs and reshapes                                     | no negative steps; `int` extents; padding only on outer dimensions                            |
| Intrusive atomic reference count for owned buffers             | O(1) copies, cheap returns, simple bindings                                          | aliasing by default; silent detach on `create()`; atomic count updates on owned-header copies |
| `InputArray`/`OutputArray` proxies                             | one signature for `Mat`, `vector`, `Matx`, `UMat`, GPU types                         | no static checking; the proxy must not be stored, by convention only                          |
| T-API keyed on `UMat` arguments with CPU fallback              | the same code runs with or without OpenCL                                            | hidden transfers; false returns and `cv::Exception` trigger silent CPU fallback               |
| HAL as compile-time macro replacement with C-style signatures  | vendors replace kernels without forking                                              | HAL is fixed at build time; raw pointer and `int` width interfaces                            |
| `*.simd.hpp` compiled per target with `CV_CPU_DISPATCH`        | baseline binaries that still use AVX2 or AVX-512 when present                        | build-system machinery (`ocv_add_dispatched_file`); one dispatch per call, not per loop       |
| Universal intrinsics with width-agnostic types                 | one kernel source for fixed-width and scalable vector ISAs                           | lowest-common-denominator operations; tails and deinterleaves still written by hand           |
| Codecs as `readHeader` then `readData` into preallocated `Mat` | caller can reuse buffers; output type known before decode                            | whole-image only; no suspension; temporary-file fallback for some formats                     |
| Size limits from environment variables                         | operators can tighten limits without recompiling                                     | process-wide, read once, cannot vary per call; limits by dimension, not by work               |
| BGR default order                                              | established default documented by `imread` ([header][imread-bgr])                    | RGB decoding needs `IMREAD_COLOR_RGB` or a swap; channel meaning untyped                      |

## Sources

- [opencv/opencv repository][repo] at `96f8c0761e75c98de6d1dba06a102377e6e29497`; [opencv/opencv_contrib][contrib]
- [`mat.hpp` — `Mat`, `UMat`, `UMatData`, `MatShape`, `MatStep`, `InputArray`, `OutputArray`, `MatAllocator`][mat-doc]
- [`mat.inl.hpp` — `Mat::at` debug assertions][mat-at]
- [`matrix.cpp` — copy, release, `create`, `setSize`, continuity, ROI, `StdMatAllocator`][mat-copy]
- [`umatrix.cpp` — `UMat::getMat`, `handle`, lifetime warning][umat-getmat]
- [`hal/interface.h` — type codes][interface-types] · [`cvdef.h` — flag bits][cvdef-flags] · [`exception.hpp` — `CV_DbgAssert`][dbgassert-5] · [`version.hpp`][version]
- [`ocl_defs.hpp` — `CV_OCL_RUN`][ocl-run] · [`color.cpp` — `cvtColor`][cvtcolor]
- [`color_rgb.dispatch.cpp`][rgb-dispatch] · [`color_rgb.simd.hpp`][rgb2rgb] · [`imgproc/CMakeLists.txt`][imgproc-cmake]
- [`core/src/hal_replacement.hpp` — `CALL_HAL`][core-call-hal] · [`imgproc/src/hal_replacement.hpp` — `hal_ni_*`][imgproc-hal-ni]
- [`cv_cpu_dispatch.h`][cpu-dispatch-h] · [`cv_cpu_helper.h`][cpu-helper-avx2] · [`intrin_cpp.hpp` — universal intrinsics documentation][intrin-doc]
- [`utility.hpp` — `parallel_for_`][parallel-api] · [`parallel.cpp`][parallel-impl] · [`parallel_backend.hpp`][parallel-backend]
- [`imgcodecs.hpp` — `ImreadModes`, metadata, `Animation`][imread-modes] · [`loadsave.cpp` — `imread_`, `imdecode_`, limits][io-limits] · [`grfmt_base.hpp` — `BaseImageDecoder`][decoder-iface]
- [`ts.cpp` — test data path][ts-data] · [`test_read_write.cpp`][test-rw] · [`SECURITY.md`][security]
- Tag `4.13.0`: [`interface.h`][interface-413] · [`base.hpp`][dbgassert-413] · [`matrix.cpp`][setsize-413]
- OSS-Fuzz OpenCV project: [`build.sh`][ossfuzz-build] · [`Dockerfile`][ossfuzz-docker]
- [OpenCV 5.x documentation][docs]
- Related: [Boost.GIL][boost-gil] · [mir-algorithm][mir] · [Halide][halide] · [dcv][dcv] · [Concepts][concepts] · [umbrella][umbrella]

<!-- References -->

[repo]: https://github.com/opencv/opencv
[contrib]: https://github.com/opencv/opencv_contrib
[docs]: https://docs.opencv.org/5.x/
[license]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/LICENSE
[version]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/version.hpp#L8-L11
[mat-shape]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.hpp#L75-L110
[inputarray-doc]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.hpp#L199-L282
[inputarray-kinds]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.hpp#L283-L345
[inputarray-storage]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.hpp#L387-L390
[inputarray-getmat]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/matrix_wrap.cpp#L59-L99
[outputarray-depth]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.hpp#L407-L452
[outputarray-ops]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.hpp#L504-L522
[mat-allocator]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.hpp#L666-L694
[umatdata]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.hpp#L703-L743
[mat-doc]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.hpp#L764-L780
[mat-doc-assign]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.hpp#L810-L814
[mat-fields]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.hpp#L2483-L2520
[umat-doc]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.hpp#L2793-L2814
[mat-at]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.inl.hpp#L1154-L1167
[mat-continuity]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/matrix.cpp#L807-L829
[setsize-5]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/matrix.cpp#L779-L805
[std-allocator]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/matrix.cpp#L702-L750
[mat-copy]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/matrix.cpp#L958-L965
[mat-userdata]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/matrix.cpp#L967-L995
[mat-release]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/matrix.cpp#L1157-L1168
[mat-deallocate]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/matrix.cpp#L1330-L1338
[mat-unmap]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/matrix.cpp#L590-L596
[mat-symbols]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/matrix.cpp#L329-L336
[mat-create]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/matrix.cpp#L1232-L1290
[mat-roi]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/matrix.cpp#L1396-L1417
[umat-warn]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/umatrix.cpp#L110-L124
[umat-getmat]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/umatrix.cpp#L1167-L1198
[umat-handle]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/umatrix.cpp#L1199-L1205
[interface-types]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/hal/interface.h#L50-L78
[cvdef-flags]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/cvdef.h#L480-L489
[dbgassert-5]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/exception.hpp#L228-L233
[debug-flags]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/cmake/OpenCVCompilerOptions.cmake#L276-L280
[ocl-run]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/opencl/ocl_defs.hpp#L60-L77
[cvtcolor]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgproc/src/color.cpp#L192-L206
[color-lab]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgproc/src/color_lab.cpp#L1555-L1579
[rgb-dispatch]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgproc/src/color_rgb.dispatch.cpp#L64-L75
[rgb2rgb]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgproc/src/color_rgb.simd.hpp#L105-L178
[imgproc-cmake]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgproc/CMakeLists.txt#L3-L12
[imgproc-hal-ni]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgproc/src/hal_replacement.hpp#L625
[imgproc-hal-define]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgproc/src/hal_replacement.hpp#L1096
[imgproc-hal-custom]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgproc/src/hal_replacement.hpp#L1669
[core-call-hal]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/hal_replacement.hpp#L1320-L1334
[cpu-dispatch-h]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/cv_cpu_dispatch.h#L10-L25
[cpu-helper-avx2]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/cv_cpu_helper.h#L192-L211
[intrin-doc]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/hal/intrin_cpp.hpp#L83-L134
[parallel-api]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/utility.hpp#L687-L724
[parallel-impl]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/parallel.cpp#L558-L626
[parallel-nested]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/parallel.cpp#L526-L547
[parallel-backend]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/parallel/parallel_backend.hpp#L54-L80
[core-include]: https://github.com/opencv/opencv/tree/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core
[videoio-src]: https://github.com/opencv/opencv/tree/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/videoio/src
[gpumat-cpp]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/cuda_gpu_mat.cpp#L49-L101
[gpumat-cu]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/src/cuda/gpu_mat.cu#L105-L175
[dnn-backends]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/dnn/include/opencv2/dnn/dnn.hpp#L70-L81
[dnn-vulkan]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/dnn/src/op_vkcom.cpp#L17-L46
[modules-5]: https://github.com/opencv/opencv/tree/96f8c0761e75c98de6d1dba06a102377e6e29497/modules
[modules-413]: https://github.com/opencv/opencv/tree/fe38fc608f6acb8b68953438a62305d8318f4fcd/modules
[install-layout]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/cmake/OpenCVInstallLayout.cmake#L77-L88
[imgcodecs-cmake]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/CMakeLists.txt#L2
[imread-modes]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/include/opencv2/imgcodecs.hpp#L69-L85
[metadata-types]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/include/opencv2/imgcodecs.hpp#L278-L288
[animation]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/include/opencv2/imgcodecs.hpp#L292-L331
[imread-bgr]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/include/opencv2/imgcodecs.hpp#L359-L381
[io-limits]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/src/loadsave.cpp#L68-L81
[find-decoder]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/src/loadsave.cpp#L262-L337
[imread-core]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/src/loadsave.cpp#L571-L645
[imdecode-tempfile]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/src/loadsave.cpp#L1343-L1361
[imdecode-result]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/src/loadsave.cpp#L1447-L1467
[decoder-iface]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/src/grfmt_base.hpp#L93-L178
[ts-data]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/ts/src/ts.cpp#L720
[ts-lookup]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/ts/src/ts.cpp#L948-L1010
[test-rw]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/test/test_read_write.cpp#L195-L216
[test-ocl-color]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgproc/test/ocl/test_color.cpp#L62-L124
[security]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/SECURITY.md#L1-L20
[interface-413]: https://github.com/opencv/opencv/blob/fe38fc608f6acb8b68953438a62305d8318f4fcd/modules/core/include/opencv2/core/hal/interface.h#L69-L71
[dbgassert-413]: https://github.com/opencv/opencv/blob/fe38fc608f6acb8b68953438a62305d8318f4fcd/modules/core/include/opencv2/core/base.hpp#L453-L457
[setsize-413]: https://github.com/opencv/opencv/blob/fe38fc608f6acb8b68953438a62305d8318f4fcd/modules/core/src/matrix.cpp#L240-L272
[ossfuzz-build]: https://github.com/google/oss-fuzz/blob/156f862e5976b3d23828230a0a5b4fef54074d32/projects/opencv/build.sh#L23-L45
[ossfuzz-docker]: https://github.com/google/oss-fuzz/blob/156f862e5976b3d23828230a0a5b4fef54074d32/projects/opencv/Dockerfile#L20
[umbrella]: ./index.md
[concepts-planar]: ./concepts.md#interleaved-planar-and-semi-planar
[concepts-alpha]: ./concepts.md#straight-and-premultiplied-alpha
[concepts-suspendable]: ./concepts.md#incremental-progressive-and-suspendable-decoding
[concepts-hostile]: ./concepts.md#hostile-input
[p-hostile]: ./papers/hostile-input-safety.md
[p-colour]: ./papers/resampling-colour.md
[bl-existing-gaps]: ./baseline/existing-code.md#gaps-and-tensions
[bl-shaders-gaps]: ./baseline/shaders-simd.md#gaps-and-tensions
[bl-wired]: ./baseline/wired.md
[bl-vk]: ./baseline/vulkan.md
[bl-eh]: ./baseline/event-horizon.md
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
[agents-expected]: ../../guidelines/idioms/expected/index.md
[agents-safety]: ../../guidelines/AGENTS.md#safety-attributes--annotate-non-templates-infer-on-templates
[agents-buffer]: ../../guidelines/AGENTS.md#nogc-primitives-and-what-breaks-nogcnothrow
[mat-depth]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/mat.inl.hpp#L921-L931
[imread-select]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/src/loadsave.cpp#L517-L535
[imread-metadata]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/include/opencv2/imgcodecs.hpp#L399-L414
[imdecode-metadata]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgcodecs/include/opencv2/imgcodecs.hpp#L617-L633
[color-xyz]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgproc/src/color_lab.cpp#L160-L185
[color-srgb]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/imgproc/src/color.hpp#L42-L52
[wired-enums]: ../../specs/wired/SPEC.md#_7-enum-representation
[concepts-stride]: ./concepts.md#stride
[mir]: ./mir-algorithm/index.md
[boost-gil]: ./boost-gil.md
[color]: ./color.md
[juliaimages]: ./juliaimages.md
[halide]: ./halide.md
[concepts-schedule]: ./concepts.md#algorithm-and-schedule
[dcv]: ./dcv.md
[concepts]: ./concepts.md
[test-ocl-macros]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/ts/include/opencv2/ts/ocl_test.hpp#L382-L383
[intrin-select]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/modules/core/include/opencv2/core/hal/intrin.hpp#L226-L266
[kleidicv-hal]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/hal/kleidicv/CMakeLists.txt#L1-L12
[dispatch-cmake]: https://github.com/opencv/opencv/blob/96f8c0761e75c98de6d1dba06a102377e6e29497/cmake/OpenCVCompilerOptimizations.cmake#L923-L964
