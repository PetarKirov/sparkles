# dcv (D)

A computer-vision library for D that represents every image as a mir `Slice`, wraps
Gamut and FFmpeg for I/O, and shows what a `Slice`-based image model looks like after
eight years of use and two API rewrites.

| Field         | Value                                                                                                   |
| ------------- | ------------------------------------------------------------------------------------------------------- |
| Language      | D (DMD and LDC; no compiler floor stated)                                                               |
| License       | BSL-1.0 (per-module exceptions allowed by the [README][readme-license])                                 |
| Repository    | [libmir/dcv][repo]                                                                                      |
| Revision read | `c777e2aa990548e0784a9c854ff9576f149364bb` (May 28, 2024, the tip of `master`; package version `0.4.0`) |
| Documentation | [dcv.dlang.io][site] (the README calls it "outdated"); the [`examples/`][examples] directory            |
| Category      | D landscape: algorithm library on an N-D array                                                          |
| Tier          | A                                                                                                       |
| Last reviewed | November 7, 2026                                                                                        |

> [!IMPORTANT]
> **Build health.** At the pinned revision `dcv:core` does not build with the
> compilers in this repository's dev shell: LDC 1.43.0 fails inside a dependency
> and DMD 2.112.1 fails inside `dcv.imgproc.convolution`. Both failures, and the test
> results after a minimal patch, are in [Testing and conformance](#_10-testing-and-conformance).
> Every claim marked **verified** was run in a scratch directory outside the
> repository; every other claim was read in the source.

---

## Overview

### What it solves

dcv offers the toolbox a Matlab or OpenCV user expects, written in D: image I/O,
convolution and the standard kernels, colour conversion, thresholding, morphology,
resizing and warping, Harris/Shi-Tomasi/FAST corners, SIFT, the Hough transform,
Lucas-Kanade and Horn-Schunck optical flow (sparse and pyramidal), block-matching
stereo, contours and moments, homography estimation, an on-screen figure window and
video input and output. The source tree holds about 40,000 lines of D, a large share
of it the generated FAST detectors (`fast_9.d` to `fast_12.d`, about 17,700 lines)
and `core/ttf.d`, a 4,774-line D port of `stb_truetype` used for figure text.

It was started in January 2016 by Relja Ljubobratovic. Of its 798 commits, 546
landed in 2016 and 67 in 2017; five landed in 2018 and none from 2019 to 2021.
Ferhat Kurtulmuş revived it in January 2022 (commit `e83caf3`, "dcv revision 2022"),
rewrote the memory model to be `@nogc`, and made the last commit on May 28, 2024.

### Design philosophy

The [README][readme-api] states the model in one paragraph:

> DCV's API heavily utilizes Mir library, and it's
> `mir.ndslice` package. N-dimensional range view structure
> Slice is used
> for any form of image manipulation and processing. But overall shape of the API is
> adopted from well known computer vision toolkits such as Matlab Image Processing
> Toolbox, and OpenCV library

The 2022 rewrite added a calling convention, also from the [README][readme-new-api]:

> In the new API, all functions accept slice shells as Slice!(T\*, N) as input. On the
> other hand, API functions return RC-allocated Slice!(RCI!T, N). In this way,
> ref-counted slices can be passed to API functions like input.lightScope.

A scope note added on March 1, 2017 (commit `ad867e2`) still heads the README
([README][readme-note]):

> Library's **API** is currently under [heavy reconstruction](https://github.com/libmir/dcv/issues/87).
> Until the API is considered properly designed, **implementation of new features will
> be put on hold**.

Three positions follow. The image is not a type of its own: `Image` is an I/O
container and every algorithm sees a `Slice`. The API copies OpenCV's names and
argument order (`conv`, `canny`, `erode`, `imshow`, `waitKey`) instead of designing
around ranges. And allocation is the caller's problem only optionally: each function
takes a `prealloc` argument and allocates a reference-counted result when the
argument is empty or the wrong shape.

---

## How it works

### Package layout

`dub.json` declares five sub-packages, split by external dependency
([`dub.json`][dubjson]):

| Sub-package | Sources                                                                         | External dependencies                                                                                       |
| ----------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `core`      | `core`, `features`, `imgproc`, `tracking`, `measure`, `morphology`, `multiview` | `mir-algorithm ~>3.22.0`, `mir-core ~>1.7.0`, `mir-random 2.2.19`, `dplug:core ~>13.4.9`, `bcaa`, `dvector` |
| `imageio`   | `imageio`                                                                       | `gamut ~>2.6.0`                                                                                             |
| `videoio`   | `videoio`                                                                       | `ffmpeg-d ~>4.4.1`                                                                                          |
| `plot`      | `plot`                                                                          | `bindbc-opengl`, `bindbc-glfw` or `glfw-d` (three configurations)                                           |
| `linalg`    | `linalg`                                                                        | a fork of `lubeck` pinned to commit `455dd4d`; BLAS/LAPACK linkage left to the user                         |

`core` holds every algorithm. It depends on `dplug:core`, an audio-plugin
framework's utility package, for `mallocNew`, `destroyFree`, `ThreadPool` and
`CString`.

### The `Image` class and its two views

`Image` is a class with a format enum, a bit-depth enum, a width, a height and a
`ubyte[]` ([`core/image.d`][image-class]):

```d
// source/dcv/core/image.d (abridged)
enum ImageFormat { IF_UNASSIGNED = 0, IF_MONO = 1, IF_RGB = 2, IF_BGR = 3, IF_YUV = 4 }
enum BitDepth : size_t { BD_UNASSIGNED = 0, BD_8 = 8, BD_16 = 16, BD_32 = 32 }

class Image
{
private:
    ImageFormat _format = ImageFormat.IF_UNASSIGNED;
    BitDepth _depth = BitDepth.BD_UNASSIGNED;
    size_t _width = 0;
    size_t _height = 0;
    ubyte[] _data = null;
public:
    bool borrower = false;
    ...
}
```

The alpha formats are commented out of the enum. `borrower` records whether
`_data` was passed in (borrowed) or `mallocSlice`d (owned and freed by the
destructor). The image becomes a `Slice` through two methods
([`core/image.d`][image-sliced]):

```d
// source/dcv/core/image.d#L288-L298
Slice!(ubyte*, 3) sliced()
{
    assert(channels > 1);
    return data.sliced(height, width, channels);
}

Slice!(ubyte*, 2) sliced2D()
{
    assert(channels == 1);
    return data.sliced(height, width);
}
```

Both views are typed `ubyte*` whatever `_depth` says, and the colour view is
row-major interleaved: dimension 0 is the row, 1 the column, 2 the channel. The
reverse conversion, `asImage`, accepts any `Slice!(Iterator, N, kind)`, works out
the element type by testing whether the iterator is `RCI!T` or `T*`, and copies
element by element into a fresh `mallocNew!Image` ([`core/image.d`][image-asimage]).

### The calling convention: pointer slices in, RC slices out

A representative signature is `rgb2gray` ([`imgproc/color.d`][color-rgb2gray]):

```d
// source/dcv/imgproc/color.d#L69-L70
@nogc nothrow
Slice!(RCI!V, 2, SliceKind.contiguous) rgb2gray(V)(Slice!(V*, 3, SliceKind.contiguous) input,
    Slice!(RCI!V, 2, SliceKind.contiguous) prealloc = emptyRCSlice!(2, V), ...)
```

Input is a contiguous pointer slice; the result is a reference-counted slice
(`mir.rc.RCI`, a pointer plus an `RCArray` that owns the buffer). A caller holding
an RC slice passes `rc.lightScope`, which strips the counter and yields the `T*`
view. `prealloc` is reused only when its shape matches; otherwise the function
calls `uninitRCslice` and the caller's buffer is silently ignored
([`imgproc/color.d`][color-impl]).

Generic entry points such as `conv` accept any slice type and branch on the
iterator, a pattern repeated 12 times across `core/image.d`, `core/utils.d`,
`imageio/image.d` and `imgproc/convolution.d` ([`imgproc/convolution.d`][conv-rcdetect]):

```d
// source/dcv/imgproc/convolution.d#L199-L203
static if (__traits(isSame, TemplateOf!(IteratorOf!(InputTensor)), RCI)){
    auto input_ls = input.lightScope;
}else{
    alias input_ls = input;
}
```

### A kernel: 2-D convolution

The body of 2-D `conv` builds a zipped, windowed view and reduces each window
against the kernel, one row of windows per thread-pool task
([`imgproc/convolution.d`][conv-2d]):

```d
// source/dcv/imgproc/convolution.d#L287-L295
if (mask.empty)
{
    auto packedWindows = zip!true(prealloc_ls, input_ls).windows(krs, kcs);
    void worker(int i, int threadIndex) nothrow @nogc {
        auto prow = packedWindows[i];
        foreach (p; prow)
            p[krh, kch].a = reduce!kapply(0.0f, p.unzip!'b', kernel_ls);
    }
    pool.parallelFor(cast(int)packedWindows.length, &worker);
}
```

`kapply` is `r + i * k` under `@fastmath` ([`imgproc/convolution.d`][conv-kapply]).
The accumulator seed is the literal `0.0f`, so every element type accumulates in
`float`. `windows` covers only the interior; four calls to `handleEdgeConv2d` then
redo the border strips with the boundary-condition function `bc` (`neumann`,
`periodic` or `symmetric`, defined in [`core/utils.d`][utils-bc]). A 3-D input is
convolved one channel plane at a time through `input[0 .. $, 0 .. $, i]`, a
universal-kind view.

`pool` is a module-level `ThreadPool` from `dplug:core`, created in a thread-local
module constructor ([`core/utils.d`][utils-pool]):

```d
// source/dcv/core/utils.d#L84-L96
static ThreadPool pool;

static this() @nogc nothrow {
    if(pool is null)
        pool = mallocNew!ThreadPool;
}

static ~this() @nogc nothrow {
    if(pool !is null){
        destroyFree(pool);
        pool = null;
    }
}
```

Because `static this` is thread-local, druntime runs it in every D thread of a
program that links `dcv.core.utils`, so each such thread creates its own pool.

### Image I/O through Gamut

`imread` maps the requested format to Gamut load flags, decodes with
`GamutImage.loadFromFile`, then copies scanline by scanline into a new `Image`
([`imageio/image.d`][io-read]). Only 8-bit mono and 8-bit RGB come out; 16-bit and
32-bit requests end in `enforce` failures that are converted to assertions. Alpha
is always dropped (`LOAD_NO_ALPHA`). `imwrite` accepts 8-bit mono and RGB and
infers the channel count from `data.length` ([`imageio/image.d`][io-write]).

### Video, plotting and the rest

- **Video.** `InputStream` and `OutputStream` wrap `libavformat`, `libavcodec` and
  `libswscale` through `ffmpeg-d` 4.4 bindings; `readFrame` returns a newly
  `mallocNew`ed `Image` per frame, optionally converted to RGB24 with `sws_scale`
  ([`videoio/input.d`][video-input]).
- **Plotting.** `Figure` opens a GLFW window and draws the image with
  `glDrawPixels` in the `legacygl` configuration ([`plot/figure.d`][figure-gl]) or as
  a `GL_RGB`/`GL_UNSIGNED_BYTE` texture in the OpenGL 3.1 ones
  ([`plot/drawprimitives.d`][draw-texture]). `imshow` accepts an `Image` or a `Slice`.
- **Stereo.** The pipeline is four delegates (cost, aggregation, disparity,
  refinement) over a `CostVolume` alias, `Slice!(CostType*, 3, contiguous)`
  ([`multiview/stereo/matching.d`][stereo]).
- **SIFT** keeps its pyramid in `std.container.array.Array` of RC slices and
  parallelises per octave and per keypoint ([`features/sift.d`][sift]).

---

## Analysis

### 1. Pixel and memory model

The image is a dense row-major array, `[row, column]` for mono and
`[row, column, channel]` for colour, with channels interleaved. A pixel is not an
element type: it is the innermost dimension. Where a kernel needs pixel values as a
unit it repacks with `staticPack!3`, which reinterprets `Slice!(T*, 3)` as
`Slice!(T[3]*, 2)` ([`imgproc/color.d`][color-impl]). There is no planar layout:
YUV images are documented as "organized in the same buffer plane where quantity of
luma and chroma values are the same (as in YUV444 format)"
([`imgproc/color.d`][color-yuv-doc]), and the video module converts every decoded
frame into that interleaved layout or RGB24 rather than keeping FFmpeg's `YUV420P`
planes ([`videoio/common.d`][video-common], [`adoptYUV`][video-adopt]). The
upsampling copies are ad hoc: `adoptYUV411P` writes the second, third and fourth
pixel of each group to the same three bytes (offsets 3 to 5), leaving the rest of
the group unwritten (read, not run).

The `SliceKind` in the signatures is the real contract. Most entry points take
`SliceKind.contiguous` input, so a sub-window `img[10 .. 50, 10 .. 50]` (canonical)
or a channel view `img[0 .. $, 0 .. $, 1]` (universal) does not match them;
the README's own example works around this by copying with `.rcslice` before
calling `conv`. Where kinds are generic, functions assert that input, mask and
output have equal strides instead of handling differing ones
([`imgproc/convolution.d`][conv-entry]).

The `Image` class carries no row stride: `rowStride` is computed as
`pixelSize * _width` ([`core/image.d`][image-class]), so padded rows from a decoder
are copied into a tight buffer on load. The bit depth is a runtime enum but both
views are statically `ubyte*`, so a 32-bit image viewed through `sliced2D` is a
`ubyte` matrix of the wrong width. **Verified** on DMD 2.112.1: a 2x2 `float` image
built with `asImage` reports `sliced2D` shape `[2, 2]` over its 16 bytes.

### 2. Genericity mechanism

Compile-time templates over `Slice!(Iterator, N, kind)` and the element type, with
`static if` on `N` (1, 2 or 3) and on the iterator. There are no capability traits
in the design-by-introspection sense: `isBoundaryCondition` is defined as
`enum bool isBoundaryCondition = true` ([`core/utils.d`][utils-bc]), and
`isInterpolationFunc` checks only that a symbol is callable with a 1-D `double`
slice and an index ([`imgproc/interpolate.d`][interp-check]). The ownership policy
lives in the iterator type, so each function is instantiated once for `T*` and
once for `RCI!T` and must branch on which it received.

That branch is written as template identity, `__traits(isSame, TemplateOf!(IteratorOf!S), RCI)`.
**Verified** on DMD 2.112.1 and LDC 1.43.0 with `mir-algorithm` 3.22.5: the test
evaluates `false` for `Slice!(RCI!float, 2)`, although
`__traits(isSame, mir_rci, RCI)` is `true` and `is(RCI!float == mir_rci!X, X)` is
`true`. In the dcv build the RC branch is not taken, and the RC slice reaches
helpers typed `Slice!(T*, ...)`, which is the build failure below. The cause is
narrower than the alias itself: `TemplateOf` returns its fallback `void` for an
instance of `mir_rci` that was first created through the alias spelling `RCI!T`.
**Verified** on both compilers: in one module, `TemplateOf!(RCI!float)` is `void`, so
is `TemplateOf!(mir_rci!float)` afterwards (the same instance), and
`TemplateOf!(RCI!int)` is `void`, while a fresh `TemplateOf!(mir_rci!double)` is
`mir_rci`; a module that names `mir_rci!float` first gets `mir_rci` for it. The test
therefore depends on which spelling instantiated the type first. Whether that held
differently on the compilers dcv was last built with was not established.

A second limit is in `conv` itself: with a contiguous pointer slice as `prealloc`,
`static if (prealloc._strides.length == 0)` is true (contiguous slices store no
strides), and the body then assigns an RC slice to the pointer-typed parameter.
**Verified**: `conv!neumann(input, kernel, result, mask)` with four
`Slice!(T*, 2)` arguments does not compile. Only an RC result buffer can be passed.

### 3. Colour and metadata

None in the colour-management sense. There is no colour space, transfer function,
ICC profile, CICP tag, EXIF or XMP anywhere in `Image`, and `imread` discards
whatever Gamut parsed. Colour conversions are fixed formulas on encoded values:

- `rgb2gray` uses BT.709 luma weights, "0.2126R + 0.715G + 0.0722B", applied to the
  gamma-encoded samples ([`imgproc/color.d`][color-enum]).
- The integer paths of `rgb2yuv` and `yuv2rgb` hard-code BT.601 limited-range
  coefficients. **Verified**: pure red `ubyte` gives `Y=82 U=90 V=240`. The
  floating-point `rgb2yuv` does not compile: it calls `clip!float`, which uses
  `float.min`, and DMD 2.112.1 rejects that property (**verified**). Read but not
  run: its `U` slot gets `(r * .439) + (g * .368) + (b * .071) + 128`, Cr's
  coefficient magnitudes with every sign positive, and its `V` slot gets the Cb
  formula, so the chroma channels are also swapped; the floating-point `yuv2rgb`
  uses full-range-style factors (1.4075, 0.3455, 0.7169, 1.7790) after subtracting
  the limited-range offset 16, without the 1.164 luma scale
  ([`imgproc/color.d`][color-yuv]).
- HSV conversion treats integer input as scaled by `T.max` and float input as
  already in 0 to 1.

`IF_BGR` exists as a format but the still-image I/O layer never produces it; the
video module maps FFmpeg's BGR formats to it.

### 4. I/O and codec architecture

dcv writes no codec. `dcv:imageio` is a 513-line adapter over Gamut 2.6 (which,
per its [README][gamut-readme] and its `plugins/` directory, decodes PNG, JPEG,
JPEG XL, TGA, GIF, BMP, QOI and QOIX); `dcv:videoio` is an
adapter over FFmpeg. Both are pull-based and whole-object: `imread(path)` returns a
fully decoded `Image`, `readFrame` returns one decoded frame. There is no memory or
stream input for stills (paths only), no incremental or suspendable decode, no
progressive display, no format registry of dcv's own and no plug-in point. The
`ImageFormat`-to-Gamut mapping covers `IF_MONO` and `IF_RGB` only; every other
format is `PixelType.unknown` with the comment `TODO: 16 bit formats`
([`imageio/image.d`][io-gamut-map]).

`InputStream` reads `AVStream.codec` for its frame-rate fallback
([`videoio/input.d`][video-fps]), and `readFrameImpl` decodes with
`avcodec_decode_video2(stream.codec, ...)`, then frees with `av_free_packet`
([`videoio/input.d`][video-decode]). None of `AVStream.codec`,
`avcodec_decode_video2` or `av_free_packet` is declared in FFmpeg's headers at
`a23e09448` (the [`AVStream`][ff-avstream] struct has only `codecpar`), so the
video module is tied to the 4.x bindings it names. Its `av_init_packet` call is
deprecated but still declared there ([`packet.h`][ff-init-packet]), scheduled for
removal with libavcodec 64 (`FF_API_INIT_PACKET`).

### 5. Hostile input and safety

dcv itself parses no bytes, so its exposure is whatever Gamut and FFmpeg accept,
plus how it reacts to their failures. Gamut 2.6 caps dimensions
(`GAMUT_MAX_IMAGE_WIDTH = 16777216`, `GAMUT_MAX_IMAGE_BYTES = 34359738368`;
[`gamut/types.d`][gamut-limits]); dcv adds no limit of its own.

The error path is the weak point. `imreadImpl_imageformats` reads `gimage.width`
and `gimage.height` and allocates the `Image` before it checks `gimage.isError`
([`imageio/image.d`][io-read]), and Gamut's `width()` begins with
`assert(isValid())` ([`gamut/image.d`][gamut-width]). **Verified** (debug build,
DMD 2.112.1, Gamut 2.6.1): `imread` on a 12-byte text file named `garbage.png`
terminates with `AssertError` in `gamut.image.Image.width()` instead of returning
`null`. In a build without assertions the same call would read the fields of an
invalid image.

More generally, recoverable conditions become assertions throughout. The idiom is
`try enforce!"msg"(cond); catch(Exception e) assert(false, e.msg);`, used for
unsupported depths, wrong channel counts and slice-shape mismatches
([`core/image.d`][image-asimage]). This keeps signatures `nothrow` but makes every
bad input fatal. Memory safety is not claimed: 24 `@safe` annotations against 224
`@nogc`, raw pointer arithmetic in the copy loops, and `asImage` writes into
`ret.data[i .. i + T.sizeof]` using the element index `i` as a byte offset
([`core/image.d`][image-asimage-loop]). **Verified**: `asImage` on a 2x2 `float`
slice holding 1, 2, 3, 4 reads back as `0, 5.92339e-39, 0, 0`. No fuzzing harness
exists.

### 6. Allocation and ownership

Three ownership systems coexist:

| Object                 | Allocation                                                  | Release                                         |
| ---------------------- | ----------------------------------------------------------- | ----------------------------------------------- |
| `Image`, `Figure`      | `mallocNew` (class instances off the GC heap)               | `destroyFree` by the caller; `destroyFigures()` |
| Algorithm results      | `uninitRCslice` / `rcslice` (`mir.rc`)                      | reference count                                 |
| Contours, accumulators | `dvector.Dvector`, `bcaa.Bcaa`, `std.container.array.Array` | RAII of each container                          |

Borrowing is a runtime flag (`Image.borrower`), not a type. The `prealloc`
parameter is an optimisation hint, not a contract: a wrong shape reallocates
without reporting it. Some algorithms reallocate inside their hot path regardless.
`LucasKanadeFlow.evaluate` allocates four `float` and two `ubyte` scratch images on
every call, with the pooled version left in comments
([`tracking/opticalflow/lucaskanade.d`][lk-scratch]), and `HornSchunckFlow` copies
both input frames into member RC slices on every call, allocating new ones whenever
the shape changes ([`tracking/opticalflow/hornschunck.d`][hs-copy]). `uninitRCslice` returns
uninitialised memory, so a kernel that leaves a border unwritten returns garbage
there.

`dcv.core.memory` still offers `alignedAlloc` (16-byte `AlignedMallocator`
allocations, [`core/memory.d`][memory]) from the 2016 design; nothing in the
current algorithms relies on it.

### 7. CPU parallelism and SIMD

Parallelism is coarse-grained data parallelism: `pool.parallelFor` over rows of
windows (`conv`, Harris), over columns (SIFT's input conversion), over octaves and
over keypoints. The worker is a nested `nothrow @nogc` delegate capturing the
enclosing frame. There is no tiling, no fusion between stages and no control of
the pool size from the API.

There is no explicit SIMD. `core.simd` is imported only by `dcv.core.memory` for a
`float4` alias; no module uses `ldc.simd`, `intel-intrinsics` (which `dplug:core`
pulls in) or `@target`. Vectorisation is left to LLVM, encouraged by 38 `@fastmath`
annotations on inner kernels (interpolation, SIFT histograms, `kapply`). A DMD
build gets no LLVM auto-vectorisation of these loops.
`tests/performance-tests` builds with `-mcpu=native` and compares two git revisions
of dcv against each other; no result is committed. No performance numbers were
measured for this page.

### 8. GPU offload and interop

Not applicable as compute: there is no GPU code path. The only GPU contact is
display. `Figure` uploads `GL_RGB`/`GL_UNSIGNED_BYTE` pixels to OpenGL 3.1
([`plot/drawprimitives.d`][draw-texture]) or draws them with `glDrawPixels` under
the `legacygl` configuration ([`plot/figure.d`][figure-gl]), and reads the frame
back from a framebuffer object with `glReadPixels` when the figure is turned into an
`Image` ([`plot/figure.d`][figure-readback]). A non-8-bit image is converted for display with
`as!ubyte`, a cast without rescaling ([`plot/figure.d`][figure-depth]).

### 9. Temporal, animation and containers

Video is a sequence of independent `Image` objects pulled from FFmpeg, with frame
seeking by index or time (`seekFrame`, `seekTime`) and live capture through `v4l2`,
`dshow`, `vfwcap` or `avfoundation` ([`videoio/input.d`][video-input]). There is no
frame-sequence type, no timestamps on frames, no animated still formats (Gamut's
multi-layer images are not exposed) and no container handling beyond what
`libavformat` does. Optical flow and tracking take two frames as two `Slice`
arguments; `DenseFlow` is `Slice!(RCI!float, 3, Contiguous)` with the last
dimension holding the `(u, v)` pair ([`tracking/opticalflow/base.d`][flow-base]).

### 10. Testing and conformance

Tests are 68 D `unittest` blocks next to the code, plus 11 PNG files under
`tests/pngsuite` (ten PngSuite images and `pngtest16rgba.png`) and BMP/TGA
conversions of the ten PngSuite images. Most tests check shapes and a handful of
hand-computed values; there is no oracle comparison against OpenCV or scikit-image.
CI was Travis, testing LDC 1.5 and 1.6 and DMD 2.076 and 2.077 under `xvfb`; the
2022 revision deleted `.travis.yml` and nothing replaced it, although the README
still shows the Travis badge.

Build and test results at the pinned revision, all **verified** in a scratch copy:

| Step                                                                                          | Result                                                                                                                                                                                                                                                                       |
| --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `dub test :core`, LDC 1.43.0                                                                  | fails in `intel-intrinsics` 1.14.11 (pulled by `dplug:core` 13.4.9): `undefined identifier __builtin_ia32_pmulhw128`                                                                                                                                                         |
| `dub test :core`, DMD 2.112.1                                                                 | 24 errors with `-verrors=0` (the default stops at 20): 23 in `dcv.imgproc.convolution`, where `handleEdgeConv1d`/`handleEdgeConv2d` receive RC slices because the `RCI` test is `false`, and one in `mir.algorithm.iteration.reduceImpl`, reached from `conv` with RC slices |
| same, after replacing the 12 `RCI` tests with `__traits(hasMember, IteratorOf!(S), "_array")` | builds; `threshold.d(189)` asserts "Test case 1 failed." (Otsu on a bimodal histogram); the Lucas-Kanade unittest dies with `SIGSEGV` in `mir_rc_increase_counter` inside `conv`                                                                                             |
| `dub test :imageio`, patched, DMD                                                             | the first test asserts at `core/image.d(290)`: it calls `sliced` on a mono image, which requires `channels > 1`                                                                                                                                                              |
| `imwrite` on a canonical sub-window                                                           | does not compile: `no property ptr` for a non-contiguous slice                                                                                                                                                                                                               |

A commit of May 18, 2024 says of the unittests "They pass.
but needs more tests" (`bc4599d`), so the failures above are
either toolchain drift since then (dependency resolution picked `mir-algorithm`
3.22.5, `gamut` 2.6.1) or tests that were not run in that configuration; this page
does not decide which. The 16-bit read test in `imageio/image.d` expects success
from a path that unconditionally asserts ([`imageio/image.d`][io-test16]).

---

## Lessons for Sparkles

- **Q1.** dcv is the largest piece of evidence that mir `Slice` can carry a
  working image library: N = 2 for mono, N = 3 with a trailing channel dimension
  for colour, `windows` and `zip` for neighbourhood kernels. It also shows the
  cost of that model in practice. Interleaved channels as a dimension leave no
  room for planar or subsampled YUV, and contiguity in the type turns every
  sub-window into a copy because entry points demand `contiguous`. The `canonical`
  kind that would fit a padded image row is barely used. The current Sparkles
  pixel carriers (`ImageData`, `ColourRegion`, `ImagePixels`) and their missing
  strides are in [the existing-code baseline][bl-existing].
- **Q1, Q2.** Keeping the runtime format (`ImageFormat`, `BitDepth`) in a container
  class and the static type (`ubyte*`) in the view let the two disagree: a 32-bit
  image is a `ubyte` slice of the wrong width, and `asImage` corrupts floats. Any
  erased-plus-typed split of the kind the baseline's design question 2 recommends
  (option C) needs one conversion point that checks depth against element type,
  with a test per depth ([existing-code baseline][bl-existing]).
- **Q2.** Putting ownership in the iterator (`T*` versus `RCI!T`) doubled every
  instantiation and needed a type-identity test that silently fails to match,
  depending on which spelling first instantiated the iterator type. Under the
  repository's design-by-introspection guidelines the test would be a
  capability ("has `lightScope`", "is borrowable") rather than template identity,
  and borrowed views would be the only type algorithms see. dip1000 `scope` views
  over an owning buffer (`sparkles.base.buffer`) give the same borrow without a
  second iterator kind; dcv's `lightScope` has no lifetime checking at all.
- **Q3.** The `zip`/`windows`/`reduce` formulation is short and readable but fixes
  the accumulator to `float`, re-walks borders with a separate boundary-condition
  pass, and parallelises only across rows. Nothing in dcv separates algorithm from
  schedule, so it gives no evidence on fusion or tiling; the
  [DSL and scheduling papers][p-dsl] do.
- **Q3, Q7.** dcv has no SIMD or GPU path, so it says nothing about the break-even
  question, except that relying on `@fastmath` and LDC auto-vectorisation leaves
  DMD builds scalar. The Sparkles precedent for runtime dispatch is in
  [the shaders and SIMD baseline][bl-shaders].
- **Q4.** The I/O split (algorithms in `core`, decoding delegated to Gamut and
  FFmpeg in their own sub-packages) is the right shape for dependencies, but the
  adapter is whole-file, path-only and 8-bit-only, and checks the decoder's error
  after using its result. A Sparkles codec seam needs memory and stream input and
  an error channel the caller must inspect before touching pixels; the
  `Expected` idiom in the repository guidelines provides the latter. Where
  `sparkles:wired` stands on describing formats is in [the wired baseline][bl-wired].
- **Q5.** dcv carries no colour state, and its conversions mix BT.709 luma weights
  with BT.601 chroma on gamma-encoded data. It is a counter-example, not a model:
  it confirms that the runtime descriptor of the baseline's design question 3
  (option B) has to exist before conversions are written ([existing-code baseline][bl-existing];
  [resampling and colour papers][p-colour]).
- **Q5, Q8.** The `try enforce ... catch assert(false)` idiom makes `nothrow`
  signatures by turning hostile input into process termination. Sparkles' standing
  rule for `@nogc nothrow` code is `Expected`, which keeps the signature and the
  recovery. dcv is direct evidence that the shortcut leaks: `imread` on a
  non-image aborts ([hostile-input papers][p-hostile]).
- **Q6.** Not informed beyond display: dcv's GPU contact is an OpenGL texture of
  8-bit RGB. Sparkles' upload path is in [the Vulkan baseline][bl-vk] and the I/O
  side in [the event-horizon baseline][bl-eh].
- **Q8.** Toolchain drift broke dcv within two and a half years of its last commit,
  through a transitive pin (`intel-intrinsics` via `dplug:core`) and a
  compiler/library interaction in a type test. Without CI the breakage was
  invisible. Sparkles' pinned `dub.selections.json` and `nix/dub-lock.json`, and
  `ci --test` on every PR, address exactly this; any mir dependency would join the
  lock. Separately, dcv's tests compare against hand values only; an oracle (the
  baseline's stb_image parity for PNG) is what dcv lacks.
- **Q9.** dcv's five sub-packages are split by external dependency (Gamut, FFmpeg,
  OpenGL, LAPACK), which kept `core` free of C libraries. It did not keep `core`
  small: it still pulls `dplug:core`, `bcaa`, `dvector` and `mir-random`, and
  `core` holds everything from colour conversion to stereo. That is evidence for a
  split along dependency lines and against a single algorithms package.
- **Build modes.** The thread pool lives in a module constructor (`static this`),
  and `Image`, `Figure` and the flow classes are D classes allocated with
  `mallocNew`; `--better-c` supports neither module constructors nor D classes,
  and wasm and Android builds were never targeted. The `@nogc` annotations are wide (224) but are not the same as
  betterC compatibility.

---

## Strengths

- One array abstraction across mono, colour, flow fields, cost volumes and kernels;
  an algorithm written for `Slice!(T*, 2)` applies to any of them.
- Broad algorithm coverage for its size: filters, morphology, corners, SIFT, Hough,
  optical flow, stereo, contours and homography.
- The 2022 rewrite made most of `core` `@nogc nothrow`, with results owned by
  reference counts instead of the GC.
- Sub-packages isolate the C dependencies, so `dcv:core` alone needs no system
  library.
- `prealloc` arguments allow buffer reuse across frames where the shape is stable.
- Boundary conditions are a template parameter (`neumann`, `periodic`,
  `symmetric`), not a runtime flag.

## Weaknesses

- Does not build at the pinned revision with LDC 1.43.0 or DMD 2.112.1; no CI since
  January 2022; the README has announced an API freeze since March 2017 (commit `ad867e2`).
- Runtime format and static element type disagree (`sliced` is always `ubyte*`);
  `asImage` corrupts non-`ubyte` data.
- Contiguity demanded by most entry points; non-contiguous views fail to compile or
  are copied first.
- Ownership split across the iterator type, a `borrower` flag and three container
  libraries; `lightScope` borrows are unchecked.
- I/O: paths only, 8-bit only, alpha dropped, decoder errors checked too late;
  video tied to FFmpeg 4.x APIs.
- No colour model; fixed BT.601/BT.709 formulas on encoded values; the float YUV
  path does not compile.
- Errors become assertions, so bad input terminates the process.
- No SIMD, no GPU compute, no conformance oracle.

## Key design decisions and trade-offs

| Decision                                                                       | Rationale                                                                        | Trade-off                                                                                                  |
| ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Every image is a mir `Slice`; `Image` is only an I/O container                 | reuse mir's N-D views, ranges and `ndslice` algorithms; one type for all tensors | runtime format and static element type drift apart; the image has no stride, colour or metadata of its own |
| Channels as the trailing dimension, interleaved                                | matches Gamut, OpenCV and FFmpeg RGB24 output; channel views are free slices     | no planar or chroma-subsampled layout; YUV is forced to 4:4:4                                              |
| `SliceKind.contiguous` in most signatures                                      | lets kernels assume flat iteration and equal strides                             | sub-windows and channel views need a copy; generic `kind` parameters assert equal strides instead          |
| Pointer slices in, RC slices out, `lightScope` to borrow                       | `@nogc` results without a GC; callers keep their own buffers                     | two instantiations per function; a fragile type-identity test; unchecked borrows                           |
| Optional `prealloc`, reallocate on shape mismatch                              | OpenCV-style output arguments with a safe default                                | buffer reuse is not guaranteed and failures to reuse are silent                                            |
| `nothrow` via `enforce` caught into `assert(false)`                            | keeps `@nogc nothrow` signatures with `mir.exception`'s `@nogc` `enforce`        | every recoverable error is fatal; behaviour differs between assertion-enabled and release builds           |
| Decoding delegated to Gamut and FFmpeg in separate sub-packages                | no codec code to maintain; `core` stays free of C libraries                      | dcv inherits their formats and limits but not their metadata; whole-file, path-only, 8-bit adapter         |
| Parallelism through `dplug:core`'s `ThreadPool`, per-thread module constructor | a `@nogc` pool without Phobos' GC-based `std.parallelism`                        | a pool per importing thread; no size control; incompatible with betterC; a large unrelated dependency      |
| Vectorisation left to LLVM via `@fastmath`                                     | no intrinsics or per-target code                                                 | performance depends on LDC; DMD output scalar; no measured baseline committed                              |

## Sources

- [libmir/dcv][repo] at `c777e2aa990548e0784a9c854ff9576f149364bb`: [`README.md`][readme-api],
  [`dub.json`][dubjson], [`source/dcv/core/image.d`][image-class],
  [`source/dcv/core/utils.d`][utils-pool], [`source/dcv/core/memory.d`][memory],
  [`source/dcv/imageio/image.d`][io-read], [`source/dcv/imgproc/convolution.d`][conv-2d],
  [`source/dcv/imgproc/color.d`][color-impl], [`source/dcv/imgproc/filter.d`][filter-erode],
  [`source/dcv/imgproc/threshold.d`][threshold-test],
  [`source/dcv/tracking/opticalflow/lucaskanade.d`][lk-scratch],
  [`source/dcv/tracking/opticalflow/hornschunck.d`][hs-copy],
  [`source/dcv/tracking/opticalflow/base.d`][flow-base], [`source/dcv/features/sift.d`][sift],
  [`source/dcv/multiview/stereo/matching.d`][stereo], [`source/dcv/plot/figure.d`][figure-gl],
  [`source/dcv/plot/drawprimitives.d`][draw-texture],
  [`source/dcv/imgproc/interpolate.d`][interp-check],
  [`source/dcv/videoio/input.d`][video-input], [`source/dcv/videoio/common.d`][video-common].
- Git history of the clone: commit counts by year, `e83caf3` (removal of `.travis.yml`),
  `bc4599d` (May 18, 2024 test commit).
- [AuburnSounds/gamut][gamut] at `v2.6.1` (`7220b7bf598af7ddd4845ff9f3470455f7ae9c58`), the
  version dub resolved: [`README.md`][gamut-readme], [`source/gamut/types.d`][gamut-limits],
  [`source/gamut/image.d`][gamut-width].
- FFmpeg at `a23e094488f139522c0e175e9766212a1213e486` (the catalog's pinned clone):
  [`libavformat/avformat.h`][ff-avstream], [`libavcodec/packet.h`][ff-init-packet].
- Experiments (scratch directory, not in the repository): `dub test :core` with LDC 1.43.0
  and DMD 2.112.1 from this repository's dev shell; the same with the `RCI` test replaced;
  `dub test :imageio`; probes of `TemplateOf`/`RCI` identity, `asImage` on `float`,
  `rgb2yuv` on `ubyte` and `float`, `conv` with pointer buffers, `imwrite` on a sub-window
  and `imread` on a non-image file. The verifier reran the `dub test :core` builds,
  the `TemplateOf` probes (extended to instantiation order), `asImage`, `rgb2yuv`,
  `imwrite` on a sub-window and `imread` on a non-image file. Dependencies resolved to `mir-algorithm` 3.22.5,
  `mir-core` 1.7.4, `dplug` 13.4.9, `intel-intrinsics` 1.14.11, `gamut` 2.6.1.
- Catalog context: [umbrella][umbrella], [existing-code baseline][bl-existing],
  [shaders and SIMD baseline][bl-shaders], [generic image programming papers][p-generic]
  (the Mir `SliceKind` entry), [hostile-input papers][p-hostile].

<!-- References -->

[repo]: https://github.com/libmir/dcv/tree/c777e2aa990548e0784a9c854ff9576f149364bb
[site]: http://dcv.dlang.io/
[examples]: https://github.com/libmir/dcv/tree/c777e2aa990548e0784a9c854ff9576f149364bb/examples
[readme-api]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/README.md#L24-L27
[readme-note]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/README.md#L10-L12
[readme-new-api]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/README.md#L45
[readme-license]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/README.md#L62-L63
[dubjson]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/dub.json#L26-L149
[image-class]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/core/image.d#L37-L243
[image-sliced]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/core/image.d#L288-L298
[image-asimage]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/core/image.d#L304-L359
[image-asimage-loop]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/core/image.d#L352-L356
[memory]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/core/memory.d#L37-L41
[utils-pool]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/core/utils.d#L84-L96
[utils-bc]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/core/utils.d#L212-L240
[io-read]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imageio/image.d#L348-L432
[io-write]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imageio/image.d#L113-L243
[io-test16]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imageio/image.d#L469-L482
[io-gamut-map]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imageio/image.d#L507-L513
[conv-entry]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imgproc/convolution.d#L79-L131
[conv-kapply]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imgproc/convolution.d#L182-L185
[conv-rcdetect]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imgproc/convolution.d#L199-L221
[conv-2d]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imgproc/convolution.d#L252-L315
[color-enum]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imgproc/color.d#L45-L52
[color-rgb2gray]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imgproc/color.d#L69-L70
[color-impl]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imgproc/color.d#L122-L152
[color-yuv]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imgproc/color.d#L698-L737
[color-yuv-doc]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imgproc/color.d#L377-L380
[interp-check]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imgproc/interpolate.d#L20-L27
[filter-erode]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imgproc/filter.d#L1124-L1134
[threshold-test]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/imgproc/threshold.d#L177-L189
[lk-scratch]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/tracking/opticalflow/lucaskanade.d#L123-L128
[hs-copy]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/tracking/opticalflow/hornschunck.d#L97-L106
[flow-base]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/tracking/opticalflow/base.d#L37-L43
[sift]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/features/sift.d#L55-L131
[stereo]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/multiview/stereo/matching.d#L49-L102
[figure-gl]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/plot/figure.d#L869-L897
[figure-readback]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/plot/figure.d#L1037-L1062
[draw-texture]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/plot/drawprimitives.d#L161-L182
[figure-depth]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/plot/figure.d#L1326-L1330
[video-input]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/videoio/input.d#L83-L345
[video-fps]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/videoio/input.d#L176-L186
[video-decode]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/videoio/input.d#L380-L447
[video-common]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/videoio/common.d#L111-L139
[video-adopt]: https://github.com/libmir/dcv/blob/c777e2aa990548e0784a9c854ff9576f149364bb/source/dcv/videoio/common.d#L278-L382
[ff-avstream]: https://github.com/FFmpeg/FFmpeg/blob/a23e094488f139522c0e175e9766212a1213e486/libavformat/avformat.h#L770-L914
[ff-init-packet]: https://github.com/FFmpeg/FFmpeg/blob/a23e094488f139522c0e175e9766212a1213e486/libavcodec/packet.h#L717-L734
[gamut]: https://github.com/AuburnSounds/gamut/tree/7220b7bf598af7ddd4845ff9f3470455f7ae9c58
[gamut-limits]: https://github.com/AuburnSounds/gamut/blob/7220b7bf598af7ddd4845ff9f3470455f7ae9c58/source/gamut/types.d#L65-L79
[gamut-width]: https://github.com/AuburnSounds/gamut/blob/7220b7bf598af7ddd4845ff9f3470455f7ae9c58/source/gamut/image.d#L104-L108
[gamut-readme]: https://github.com/AuburnSounds/gamut/blob/7220b7bf598af7ddd4845ff9f3470455f7ae9c58/README.md#L11-L20
[umbrella]: ./index.md
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-wired]: ./baseline/wired.md
[bl-vk]: ./baseline/vulkan.md
[bl-eh]: ./baseline/event-horizon.md
[p-dsl]: ./papers/dsl-scheduling.md
[p-generic]: ./papers/generic-image-programming.md
[p-colour]: ./papers/resampling-colour.md
[p-hostile]: ./papers/hostile-input-safety.md
