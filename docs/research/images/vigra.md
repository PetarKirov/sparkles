# VIGRA (C++)

Ullrich Köthe's generic image-analysis library: an N-dimensional strided array
view, STL-style iterators and accessors, and functor-based algorithms, built on
compile-time numeric promotion traits rather than a fixed pixel type.

| Field         | Value                                                                 |
| ------------- | --------------------------------------------------------------------- |
| Language      | C++ (C++11, header-only core; a compiled `impex` I/O library)         |
| License       | MIT/X11 ([`LICENSE.txt`][license])                                    |
| Repository    | [ukoethe/vigra][repo]                                                 |
| Revision read | `de98f930b66d461360a2d5dc8f9adfa84bb01058` (version 1.12.4)           |
| Documentation | [ukoethe.github.io/vigra][docs]; Doxygen `/** ... */` header comments |
| Category      | Generic libraries                                                     |
| Tier          | A                                                                     |
| Last reviewed | November 7, 2026                                                      |

> [!NOTE]
> VIGRA is the first-hand record of the iterator-versus-view question the
> [generic-image-programming paper thread][p-generic] opens: its author built a
> 2-D `ImageIterator`/accessor design in the late 1990s, then added
> `MultiArrayView` and reported that implementers preferred views. Both designs
> are still in the tree at this revision, so the deprecated one can be read
> beside its replacement. The relevance to Sparkles is the N-D scientific image
> model, not the algorithms: VIGRA is C++03-era in spirit and GC-free but not
> `@nogc`-shaped, and its generic machinery is template specialisation, which D
> expresses differently.

---

## Overview

### What it solves

VIGRA ("Vision with Generic Algorithms") applies the STL's separation of
containers, iterators and algorithms to image and volume processing. One
algorithm — a convolution, a distance transform, a connected-component
labelling — is written once against an iterator pair and an accessor, and then
runs on a grey `unsigned char` image, an interleaved `RGBValue<float>` image, a
single band of a multi-band array, or an arbitrary N-dimensional view, without
copying and without a virtual call per pixel. The accumulation type (what a sum
of `unsigned char` samples is stored in) is deduced at compile time from
`NumericTraits` and `PromoteTraits`, so a blur over 8-bit pixels accumulates in
`int` or `double`; a floating result is rounded and clamped back on write,
rather than silently wrapping (an integer result is not; see
[How it works](#how-it-works)).

The library spans far more than a pixel container: separable and recursive
convolution, morphology, watersheds, random forests, graph algorithms, FFT
wrappers and a NumPy binding (`vigranumpy`). This deep-dive reads only the parts
that bear on an N-D image model in D — the array types, the pixel types, the
trait system, the functor-algorithm shape, the `impex` codec seam, the
`vigranumpy` `axistags` idea, and the threading layer.

### Design philosophy

The core abstraction is the strided view, and the memory-layout tag is pushed to
the margins of the user's attention. From the `MultiArrayView` class header
([`multi_array.hxx`][ma-view]):

> _"By default, MultiArrayViews are tagged as strided (using
> `StridedArrayTag` as third template parameter). This means that the array
> elements need not be consecutive in memory, making the view flexible to
> represent all kinds of subarrays and slices."_

The memory-layout tags themselves carry a note that they are an optimisation
detail, not a user concern ([`metaprogramming.hxx`][meta]):

> _"These tags are used to specialize algorithms for different memory layouts.
> Older compilers can generate faster code for unstrided arrays. Normally, users
> don't have to worry about these tags."_

This is the retrospective position of [Köthe 2012][vigra-ipol] made concrete:
multidimensional arrays expose two interfaces, hierarchical iterators and array
views, and "the latter turned out to be much more convenient for algorithm
implementers". The older 2-D `ImageIterator` design (navigate with `++i.x`,
`i.y += 5`) is still present. The 2-D container it walks, `BasicImage`, is
documented as "deprecated, use `vigra::MultiArray` instead"
([`basicimage.hxx`][basicimage]), and the N-D hierarchical iterators
`MultiIterator` and `StridedMultiIterator` carry `// DEPRECATED!` comments in
`multi_fwd.hxx`, which makes VIGRA a direct exhibit for the design question in
the paper thread.

---

## How it works

VIGRA layers three ideas: an N-D view with element-unit strides, a trait kernel
for element algebra, and a functor-algorithm facade.

**The view.** `MultiArrayView<N, T, StrideTag>` holds three members — a shape, a
stride vector, and a pointer ([`multi_array.hxx`][ma-view]):

```cpp
difference_type m_shape;   // extents, a TinyVector<MultiArrayIndex, N>
difference_type m_stride;  // offset to the next sample, PER DIMENSION
pointer         m_ptr;     // first element
```

`difference_type` is `TinyVector<MultiArrayIndex, N>` and `MultiArrayIndex` is
`std::ptrdiff_t` ([`multi_fwd.hxx`][fwd]), so shapes and strides are signed. The
default stride for a gapless array is computed in `defaultStride`
([`multi_shape.hxx`][shape]): `ret[0] = 1; ret[i] = ret[i-1] * shape[i-1]`, i.e.
dimension 0 is the fastest-varying, counted **in elements, not bytes**. A probe
built against this revision (see [Testing](#_10-testing-and-conformance)) printed
`shape (4,3,2) stride (1,4,12)` for a `MultiArray<3, float>`, confirming the
column-major element-stride convention.

**The stride tag.** The third parameter is `StridedArrayTag` (default) or
`UnstridedArrayTag`; the latter asserts the innermost dimension is contiguous.
`checkInnerStride` returns `m_stride[0] <= 1` for the unstrided case, and a
constructor that narrows a strided view to an unstrided one calls
`vigra_precondition` and throws if it is not actually contiguous. The probe
confirmed this: converting a `stridearray` view to `UnstridedArrayTag` raised a
`PreconditionViolation`. The tag selects an iterator at compile time through
`MultiIteratorChooser`, which for `UnstridedArrayTag` resolves the linear
iterator to a bare `POINTER`.

**The owner.** `MultiArray<N, T, A>` derives from its own `view_type` and adds a
`std::allocator`-based buffer. Its header states the ownership contract
([`multi_array.hxx`][ma-own]):

> _"MultiArray's are always unstrided, striding them creates a MultiArrayView."_

**The trait kernel.** `NumericTraits<T>` names, for each arithmetic `T`, a
`Promote` (integer accumulation type), a `RealPromote` (floating accumulation
type), `min`/`max`, and `fromPromote`/`fromRealPromote` converters that round and
clamp. `PromoteTraits<A, B>::Promote` names the result of mixing two types. The
binary table is generated by a Python script, `promote_traits.hxx.py`, over the
fourteen built-in arithmetic types — the one place VIGRA admits a code generator
rather than pure templates.

**The algorithm facade.** A point operator such as `transformMultiArray` takes
source and destination views and a functor, checks shape compatibility with
`vigra_precondition`, and dispatches on `FunctorTraits` to one of three modes —
standard (equal shapes), expand (a source axis of length 1 is broadcast), or
reduce (a destination axis of length 1 collects with an accumulating functor).
The recursion peels one dimension per `MetaInt<N>` level down to a scanline loop.

```cpp
// transformimage.hxx, transformLine: the scanline loop the N-D facade reaches
for(; s != send; ++s, ++d)
    dest.set(f(src(s)), d);          // read via accessor, write via accessor
```

`dest.set(...)` routes through the accessor, so the conversion `f(src(s)) -> T`
runs `RequiresExplicitCast<T>::cast` ([`numerictraits.hxx`][cast]). For an
integral `T` its `float` and `double` overloads call `fromRealPromote` and
therefore round and clamp a floating result into range; every other argument
type, `int` included, goes through a plain `static_cast` and wraps.

---

## Analysis

### 1. Pixel and memory model

The model is a shape-plus-strides N-D view over a flat buffer, with the element
type `T` free: scalar (`unsigned char`, `float`), compound (`RGBValue<T>`,
`TinyVector<T, K>`), or the layout markers `Singleband<T>`, `Multiband<T>` and
`ChunkedMemory<T>`. Strides are per-dimension and measured in elements; shapes
and strides are signed `ptrdiff_t`. Views are cheap value types that do not own
their buffer; `MultiArray` owns and is always unstrided.

Slicing is a first-class vocabulary, all returning strided views: `subarray(p,
q)` (a box), `bind<k>(i)` and `bindInner`/`bindOuter` (drop an axis),
`bindElementChannel(i)` (one channel of a compound-element image, as a scalar
view with a wider stride), `expandElements(d)` (turn a compound-element image
into an array with an explicit channel axis), `transpose`, `diagonal`,
`stridearray` (sub-sample), and `insertSingletonDimension`. The probe confirmed
`bindElementChannel(1)` on an `RGBValue<float>` image gives stride `(3, 15)` —
the channel is read in place with element stride 3 — and `expandElements(2)`
gives a 3-D view of shape `(5, 4, 3)` with the channel axis innermost (stride 1).

The `Multiband<T>` marker is a layout annotation rather than a distinct type: a
`MultiArrayView<N, Multiband<T>>` tells multiband-aware algorithms to treat the
last axis as a channel axis and iterate the data as a set of `(N-1)`-D arrays.
`defaultMultibandStride` ([`multi_shape.hxx`][shape]) gives the channel axis
stride 1 and the spatial axes the larger strides, so a
`MultiArray<3, Multiband<float>>` of shape `(5, 4, 3)` is laid out interleaved,
with strides `(3, 15, 1)` (rerun probe), the same strides `expandElements(2)`
produces. The planar, band-separated layout is the ordinary `defaultStride`
layout of a scalar array whose last axis is the channel axis. VIGRA therefore expresses both
planar and interleaved multi-channel images with one view type and two stride
conventions, not two container types.

Interlace, sub-byte packing and tiling are not in the view: the `impex` codecs
unpack to whole samples before any view is constructed, and tiling lives in the
separate `ChunkedArray` hierarchy (see §9).

### 2. Genericity mechanism

Compile-time template specialisation and trait classes — the C++ analogue of D's
design by introspection, but without `static if` or `__traits`. There are three
layers:

- **Tag dispatch.** `StridedArrayTag`/`UnstridedArrayTag` select an iterator via
  an explicit `MultiIteratorChooser` specialisation; `MetaInt<N>` peels array
  dimensions by recursive overload; `VigraTrueType`/`VigraFalseType` steer
  reduce-versus-expand mode.
- **Trait classes.** `NumericTraits<T>`, `PromoteTraits<A, B>`, `NormTraits<T>`,
  `AccessorTraits<T>` and `FunctorTraits<F>` are open for specialisation and are
  how the library asks "what does `T` accumulate into", "what is the default
  accessor for `T`", "is this functor an initialiser or an analyser".
- **Accessors.** An accessor is the "how to read/write" half, separated from the
  iterator's "where". `StandardAccessor` returns by reference; `RGBToGrayAccessor`
  computes a luminance on read; `VectorComponentAccessor` picks one component.

The cost is the classic C++ one: every `(element type × stride tag × dimension ×
functor)` combination is a fresh instantiation, which is instantiation count,
compile time and object size. The benefit is that, inside the instantiated loop,
nothing is virtual. VIGRA does not use C++20 concepts at this revision (it
targets C++11), so a trait check verifies syntax, not Stepanov's semantic axioms
— exactly the limitation the [paper thread synthesis][p-generic] records for
pre-concept C++ and for D template constraints.

### 3. Colour and metadata

Colour is carried by the element type and converted by functors, never by a
tagged colour space on the image. `RGBValue<T, R, G, B>` derives from
`TinyVector<T, 3>` with compile-time channel-index remapping (so `BGRValue` is
`RGBValue<unsigned char, 2, 1, 0>`), component accessors, arithmetic, and a
`luminance()` that computes `0.3*r + 0.59*g + 0.11*b`. `colorconversions.hxx`
supplies a large family of unary functors — `RGB2sRGBFunctor`, `sRGB2RGBFunctor`,
`RGB2XYZFunctor`, `XYZ2LabFunctor`, `RGB2LuvFunctor` and their inverses — each
with a documented transfer formula and a specialisation that builds a 256-entry
look-up table when both source and destination are `unsigned char`. The sRGB
functor encodes the IEC 61966-2.1 piecewise curve with a constructor-overridable
maximum. A conversion is therefore `transformImage(src, dest, RGB2sRGBFunctor())`
— colour conversion is "a generic copy between pixel types applying a functor",
the shape the [paper thread][p-generic] recommends.

Metadata is thin and lives only at the I/O seam, not on the array.
`ImageImportInfo`/`ImageExportInfo` ([`imageinfo.hxx`][info]) carry a pixel-type
enum (`UINT8, INT16, UINT16, INT32, UINT32, FLOAT, DOUBLE`), X/Y resolution, a
canvas position, and an ICC profile — handled as an opaque
`ArrayVector<unsigned char>`, with the header noting ICC is "handled as raw data so far". There is no
CICP, no HDR transfer metadata, no EXIF or XMP model; the profile bytes are
passed through from PNG/TIFF/JPEG and never interpreted.

### 4. I/O and codec architecture

I/O is a separate compiled library (`src/impex`) behind a scanline-pull virtual
interface. The header states the role plainly ([`codec.hxx`][codec]):

> _"Decoder and Encoder are virtual types that define a common interface for all
> image file formats impex supports."_

A `Decoder` exposes `getWidth`/`getHeight`/`getNumBands`/`getPixelType`, an
optional image index for multi-image files (`getNumImages`, `setImageIndex`), and
a two-call scanline pull:

```cpp
virtual const void * currentScanlineOfBand(unsigned int) const = 0;
virtual void nextScanline() = 0;
```

`getDecoder` selects a codec by an explicit file type or else the file's
four-byte magic string; `getEncoder` uses an explicit file type or else the
extension ([`codecmanager.cxx`][codecmgr]). `CodecFactory` registers formats with a
`codecmanager`. Bundled codecs are PNG, TIFF, JPEG, GIF, BMP, PNM, SUN, VIFF,
EXR and HDR, with a side `sifImport` and HDF5. This is a pull interface over a
`std::ifstream` opened by filename — not a push/suspendable decoder, not fed from
a caller-owned byte range, and not incremental in the sense a file-to-GPU
pipeline wants. The `impex` codecs are also thin wrappers: `png.cxx` drives
`libpng` through `setjmp`/`longjmp`, `jpeg.cxx` drives `libjpeg`, `tiff.cxx`
drives `libtiff`. VIGRA owns only `bmp`, `pnm`, `sun`, `viff`, `gif` and the HDR
`rgbe` reader as from-scratch C++.

### 5. Hostile input and safety

This is VIGRA's weakest dimension by a wide margin, and the gap is a finding, not
an omission to paper over. Three concrete observations at this revision:

- **Element indexing is unchecked by default.** `operator[](difference_type)`
  expands `VIGRA_ASSERT_INSIDE`, which is a bounds check only when
  `VIGRA_CHECK_BOUNDS` is defined and otherwise empty ([`multi_array.hxx`][ma-bounds]).
- **View construction trusts its arguments.** `subarray(p, q)` computes a pointer
  offset and a new shape with no check that the box lies inside the parent. The
  probe constructed `vol.subarray(Shape3(2,2,1), Shape3(10,10,10))` on a `4×3×2`
  array and got a `8×8×9` view pointing past the buffer, with no error. A codec
  that fed attacker-controlled extents into a view would get an out-of-bounds view
  for free.
- **Size arithmetic is unchecked.** `elementCount()` multiplies the shape
  components in `ptrdiff_t` with no overflow guard ([`multi_array.hxx`][ma-count]).
  Compiled against this revision under `-fsanitize=undefined`, a
  `MultiArrayView<3, unsigned char>` of extents `2^22` cubed reports a signed
  integer overflow at `multi_array.hxx:1636` (the rerun with `g++ 16.2.0`
  printed `4194304 * 17592186044416 cannot be represented in type 'long int'`,
  and needed `-fno-wrapv`, because the Nix compiler wrapper's
  `-fno-strict-overflow` defines signed overflow and silences the check), and
  `elementCount()` returned `0` — a wrap, demonstrated, not inferred.

The `impex` codecs are of their era too. The BMP header reader checks the
info-header size, `width > 0`, `height > 0`, `planes == 1`, a bit-count
whitelist and the colour-table counts, but sets no upper bound on the
dimensions ([`bmp.cxx`][bmp]). Each loader then computes
`const unsigned int line_size = info_header.width * ncomp` and
`const unsigned int image_size = info_header.height * line_size` in 32 bits and
calls `pixels.resize(image_size)` ([`bmp.cxx`][bmp-load]) — a width × height product that
overflows `unsigned int` under-allocates the buffer that the subsequent scanline
loop then fills, a textbook integer-overflow-to-heap-overflow of exactly the
class the [hostile-input paper thread][p-hostile] catalogues. (This review reads
the overflow in source and from the view-level sanitizer run; it does not build a
crafted file to drive the codec.) The `vigra_precondition` machinery throws a
C++ exception, which is a usable error channel but is whole-image abort, not
bounded recovery, and there is no fuzzing harness, no resource budget and no
`libFuzzer`/sanitizer target in the tree.

### 6. Allocation and ownership

`MultiArray` owns its buffer through a `std::allocator<T>` (a template parameter,
default `std::allocator`), constructing and destroying each element and offering
the strong exception guarantee on a failed `allocate`: a throw during
construction destroys the already-built prefix and deallocates before rethrowing.
Views never own; copying a view copies three small members. Copy-assignment
between views (`copyImpl`) checks `arraysOverlap` and, on overlap, copies through
a temporary `MultiArray` to avoid clobbering still-needed source elements — an
aliasing-correctness step worth noting.

The ownership vocabulary is therefore: `MultiArray` owns, `MultiArrayView`
borrows, and the borrow is a value, not a handle. There is no reference count, no
copy-on-write and no generational handle. The allocator parameter is the only
customisation point; there is no arena, no caller-storage decode (the `impex`
path always allocates), and no sub-allocator composition. For Sparkles this is
the plain-ownership baseline that `sparkles.base.buffer`'s `UniqueBuffer`
(move-only owner) and `ImageRegistry`'s borrowed-bytes bargain already improve
on; the transferable idea is the view-borrows-value discipline, not the
allocator model.

### 7. CPU parallelism and SIMD

Multi-threading is a block-decomposition `ThreadPool` plus a `parallel_foreach`,
not SIMD. `ParallelOptions` chooses a thread count with the sentinels `Auto`
(`std::thread::hardware_concurrency()`), `Nice` (half of auto) and `NoThreads`
(`0`, sequential); a `VIGRA_SINGLE_THREADED` build define forces sequential.
`parallel_foreach` over a random-access range splits the work and, per the
header, "will split the work into about three times as many parallel tasks"
([`threadpool.hxx`][pool]) — a 3× over-subscription for load balance via a
work-queue of `std::function<void(int)>` guarded by a `std::mutex` and
`condition_variable`. The blockwise layer (`multi_blockwise.hxx`,
`BlockwiseOptions`) decomposes an N-D array into blocks with a border halo
(`blockWithBorderBegin`), runs the per-block filter under `parallel_foreach`,
allocates a fresh output block per task, and writes the core back — the
interior/border split the [paper synthesis][p-generic] recommends for stencils,
done at block rather than scanline granularity. Default chunk/block shapes are
powers of two (`512²` for 2-D, `64³` for 3-D).

There is no explicit vectorisation: a repository grep for `__m128`, `_mm_`,
`immintrin`, `arm_neon` or `#pragma omp` across `include` and `src` finds only
two commented-out OpenMP lines in `graph_rag_project_back.hxx`. VIGRA relies
entirely on the compiler auto-vectorising its inlined scanline loops. This is the
opposite end of the spectrum from Highway or hand-written intrinsics
and is a deliberate "let the optimiser do it" stance consistent with the library's
age.

### 8. GPU offload and interop

Effectively none. `multi_opencl.hxx` exists but only defines `NumericTraits`
specialisations for OpenCL vector types (`float4`, `int4`, …) so that VIGRA's
trait-driven algorithms can name them as element types; it includes
`<CL/opencl.h>` (or `<OpenCL/opencl.h>` on Apple) and contains no kernels, no
device buffers and no dispatch. There is no CUDA, no SPIR-V, no texture-format
awareness and no host/device type distinction. The library is a pure-CPU design.
For the file-to-GPU and SIMD-versus-GPU questions this is a negative data point:
VIGRA shows that a rich, generic, N-D CPU image library can be built with no GPU
model at all, which is useful evidence for keeping the host image core and any
GPU path in separate packages rather than one abstraction.

### 9. Temporal, animation and containers

No video, no timestamps, no animation. The temporal dimension, where it appears,
is just another axis — `vigranumpy`'s `axistags` has a `Time` flag
([`axistags.hxx`][axistags]) alongside `Space`, `Angle`, `Frequency` and
`Channels`, used to order axes canonically, not to drive playback.

The relevant container story is out-of-core tiling. `ChunkedArray<N, T>`
([`multi_array_chunked.hxx`][chunked]) stores an array in power-of-two chunks with
a thread-safe per-chunk state machine (reference counts plus `chunk_asleep`,
`chunk_uninitialized` and locked/failed sentinels) and an LRU-style cache. The
header advises sizing the cache to hold "all chunks forming a row of the full
array"; the default, `defaultCacheSize`, is one more than the largest
single-axis extent or two-axis product of the chunk-grid shape. Backends are
`ChunkedArrayFull` (one block), `ChunkedArrayLazy` (allocate on first touch),
`ChunkedArrayCompressed` (LZ4/zlib in RAM), `ChunkedArrayTmpFile` (memory-mapped)
and `ChunkedArrayHDF5`. Access is via `checkoutSubarray`/`commitSubarray` into a
plain `MultiArrayView`, a scan-order iterator that amortises chunk activation, or
a `MultiArrayView<N, T, ChunkedArrayTag>` over an arbitrary ROI. This is the
nearest thing in the corpus to the chunk-view-over-a-stream model the
storage-to-GPU work needs, done for terabyte microscopy volumes rather than for
transfer pipelines.

### 10. Testing and conformance

VIGRA ships a large `test/` tree (one directory per module: `multiarray`,
`imgproc`, `impex`, `pixeltypes`, `colorspaces`, `threadpool`, …) driven by its
own `unittest.hxx` with `shouldEqual`/`shouldEqualTolerance` macros, plus the
`vigranumpy` Python tests run on CPython 3.10–3.14 under Azure Pipelines
(`azure-pipelines.yml`) on Linux, macOS and Windows. The `impex` tests compare
against reference images (`test/impex/lenna*.xv`, `lenna_*.tif`). There is no fuzzing, no sanitizer CI
job, and no conformance corpus for the codecs beyond the bundled samples; the
tolerance machinery (`shouldEqualTolerance`) exists for the float algorithms.

For this review the behavioural claims above were **verified** by compiling a
small probe against the pinned tree (`g++ 14.3.0`, `-std=c++17`,
`-fsanitize=address,undefined`, headers only) in a scratch directory outside the
repository, and reading its output: the element-stride layout, the slicing stride
results, the `UnstridedArrayTag` precondition throw, the unchecked out-of-bounds
`subarray`, the promote-trait identities (`Promote<unsigned char> == int`,
`RealPromote == double`, `PromoteTraits<unsigned char, float> == float`), the
rounding/clamping of `fromRealPromote` (`-3.2 → 0`, `300.7 → 255`, `127.5 → 128`),
`transformMultiArray` expand and reduce modes, the `unsigned char` write path of
`combineTwoMultiArrays`, and the `elementCount` overflow. A verification rerun
with `g++ 16.2.0` reproduced the strides, the slicing, the precondition throw,
the out-of-bounds `subarray`, the promote traits, `fromRealPromote`, the
overflow and the write path, and added the `Multiband` strides. The write path
does not saturate: into an `unsigned char` destination, `Arg1() + Arg2()` and a
functor returning `int` both give `200 + 100 → 44`, while a functor returning
`double` (or `Arg1() + Param(0.0) + Arg2()`) gives `255`, because
`RequiresExplicitCast<unsigned char>` clamps only `float` and `double`
arguments. Everything else here is read from source and so is **documented**,
not verified.

---

## Lessons for Sparkles

- **Q1** — A shape-plus-element-strides N-D view with a free element type and
  signed indices is exactly the model the [paper thread][p-generic] and
  [`baseline/existing-code.md` gap G2][bl-existing] call for, and VIGRA is the
  first-hand testimony ([Köthe 2012][vigra-ipol]) that views beat 2-D iterators
  for implementers — its own `ImageIterator` is still in-tree beside a
  `BasicImage` documented as deprecated in favour of `MultiArray`. A D version
  would use `size_t`/`ptrdiff_t` indices and could wrap `mir.ndslice.Slice`
  rather than reinvent the view. VIGRA, like Mir, counts strides in elements;
  the paper thread (after NumPy) argues for **byte** strides to express
  row-padded buffers, `BGRX` planes and driver-chosen row pitches, so this is a
  point where Sparkles should diverge.
- **Q1/Q3** — The planar-versus-interleaved split handled by one view type plus
  a `Multiband<T>` marker and `expandElements`/`bindElementChannel` is a clean
  answer to the two-conventions problem `existing-code.md` records (glyph regions
  premultiplied, registry images straight): a channel is a zero-copy strided
  view, not a new type. Transfers to D as a `channelView`/`expandElements` pair
  over the same slice.
- **Q2** — VIGRA's trait specialisation is C++'s version of design by
  introspection, and it confirms the DbI guidance in the paper synthesis:
  capability facts (`StridedArrayTag`, `FunctorTraits::isInitializer`) belong in
  the type, dispatched at compile time, with the loop body virtual-call-free. In
  D this is `static if`/`__traits(compiles, …)` and `isImageView`-style traits.
  What does **not** transfer is the hand-written `MultiIteratorChooser` and
  `MetaInt<N>` recursion — D folds the first into `static if` and the second into
  `static foreach` or `Slice`'s own machinery.
- **Q2/Q3** — `NumericTraits`/`PromoteTraits` are the accumulation-type
  vocabulary that the 8-bit and 16-bit pixel types missing from `sparkles:math`
  ([shaders-SIMD baseline gap G3][bl-shaders]) would need: a `Promote!T`
  (integer), `RealPromote!T` (float) and `Promote!(A, B)` in D, with
  `fromRealPromote` as the rounding-and-clamping write hook, would stop a
  convolution over `ubyte` from wrapping. The verified caveat is a sharp one:
  VIGRA's write path clamps only a **floating** result. A functor returning
  `int` (or `Arg1() + Arg2()`) into an `unsigned char` destination still wraps
  (`200 + 100 → 44`), although `fromPromote` would clamp it, because
  `RequiresExplicitCast` sends integers through `static_cast`. A D design must
  decide where the clamping boundary is, not assume the trait alone prevents
  overflow.
- **Q4** — The scanline-pull `Decoder`/`Encoder` virtual seam
  (`currentScanlineOfBand`/`nextScanline`) is the opposite of what `wired`-era
  Sparkles wants: it is file-path-driven over `std::ifstream`, whole-image, and
  not suspendable. It is a useful negative baseline for [`baseline/existing-code.md`
  gap G7][bl-existing] (whole-file, single-shot decode) — VIGRA shows the pull
  shape without the incrementality, so a Sparkles codec should take a caller
  byte range and be resumable, which VIGRA is not.
- **Q5** — Colour-as-element-type with conversion functors
  (`RGB2sRGBFunctor` with its documented IEC curve and `unsigned char` LUT
  specialisation) is the "generic copy between pixel types is a colour
  conversion" model, and it transfers directly to D pixel types carrying their
  space. But VIGRA's metadata is an opaque ICC byte blob at the I/O seam only —
  it confirms [gap G4/G5][bl-existing] rather than solving it: there is no CICP,
  HDR or EXIF model to borrow.
- **Q5/Q8** — `fromRealPromote`'s clamp-and-round is the single auditable
  value-conversion hook the paper thread wants; pairing a D equivalent with
  negative tests (types that must round, values that must clamp) matches the
  standing testing rules. Verified behaviour gives the exact oracle values.
- **Q6** — There is no GPU model: `multi_opencl.hxx` is trait glue, not kernels.
  This is evidence **for** the [existing-code consumer split][bl-existing]
  keeping a host image core separate from any `sparkles:ui-vulkan` GPU path,
  since VIGRA is a complete generic image library with zero GPU surface.
- **Q6/Q9** — `ChunkedArray` is the corpus's clearest chunk-view-over-backing-store
  design (active/asleep state machine, LRU cache, `checkoutSubarray` into a plain
  view, memory-mapped and compressed backends). The transferable shape for a
  storage-to-GPU or out-of-core path is "a view type whose element access first
  resolves a chunk, with the cache and the plain-view checkout as the two access
  modes"; the lock-per-chunk `std::mutex` model would become `sparkles.base.sync`
  primitives in D.
- **Q7** — Parallelism is block decomposition over a `std::function` thread pool
  with ~3× task over-subscription and an interior/border halo per block, and SIMD
  is left entirely to the auto-vectoriser. For Sparkles, whose
  [shaders-SIMD baseline][bl-shaders] already has `hwParallelism` and a BLAKE3
  `@target` precedent, VIGRA contributes the block-with-border decomposition and
  the `Auto`/`Nice`/`NoThreads` policy enum, not a SIMD mechanism.
- **Q8** — Testing is golden-image and tolerance macros with no fuzzing or
  sanitizer CI, and the demonstrated `subarray`/`elementCount`/BMP overflows show
  why that is insufficient for a hostile-input codec. This is direct support for
  [`baseline/existing-code.md` gap G11][bl-existing] (oracles are single-purpose,
  no fuzz harness): a Sparkles image-oracle package should do what VIGRA does not.
- **Q9** — VIGRA is one library spanning container, codecs, colour, algorithms,
  graph and ML. The parts most worth isolating in D are the N-D view
  (`image-core`), the codec seam (`formats`), and the functor algorithms
  (`algorithms`) — the very split the [package-boundary question][bl-existing]
  (Q9) weighs. VIGRA's monolith is a counter-example whose compile-time cost and
  all-or-nothing dependency argue for the split.

---

## Strengths

- One strided N-D view type serves scalar, compound and multi-band images, with
  a rich zero-copy slicing vocabulary (`subarray`, `bind`, `bindElementChannel`,
  `expandElements`, `transpose`, `diagonal`, `stridearray`).
- First-hand, battle-tested evidence that array views beat 2-D iterators for
  implementers, with both designs preserved in the tree.
- A principled accumulation-type system (`NumericTraits`/`PromoteTraits`) with a
  rounding-and-clamping write path for floating results — a genuine correctness
  feature for integer pixel arithmetic, though integer results still wrap.
- Colour as element type plus conversion functors, with documented transfer
  formulae and `unsigned char` look-up-table fast paths.
- `ChunkedArray`: a mature out-of-core tiled store with multiple backends and a
  thread-safe cache, rare in general image libraries.
- Clean container/iterator/accessor/algorithm separation that genuinely lets one
  algorithm run on many image kinds without per-pixel virtual calls.
- Permissive MIT/X11 licence; header-only core.

## Weaknesses

- No memory safety for untrusted input: unchecked indexing (opt-in only), no
  bounds check on `subarray`, and unchecked size arithmetic that overflows
  silently (all demonstrated), plus era-typical integer-overflow risk in the
  from-scratch `impex` codecs.
- Whole-image, file-path-driven, non-suspendable I/O over `std::ifstream`; no
  incremental, push, or caller-byte-range decode.
- No SIMD and no GPU: relies on the auto-vectoriser; `multi_opencl.hxx` is trait
  glue with no kernels.
- Metadata is an opaque ICC byte blob at the I/O seam; no CICP, HDR, EXIF or XMP
  model.
- Template-specialisation genericity pays in compile time, instantiation count
  and object size; no concepts, so trait checks are syntactic only.
- A monolithic library: using the N-D view drags in a large header closure.
- C++03-era idioms in most of the core (the build targets C++11, which the
  newer threading and blockwise code uses); the design predates move semantics,
  `std::span`, designated initialisers and concepts that a modern port would use.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                 | Trade-off                                                                                      |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Strided N-D view as the base (`MultiArrayView`), iterators derived | One type expresses every subarray, slice and transpose; views are cheap   | The deprecated 2-D `BasicImage`/`ImageIterator` API lingers; strides count elements, not bytes |
| `StridedArrayTag`/`UnstridedArrayTag` compile-time tag             | Lets algorithms specialise for contiguous inner loops on older compilers  | A second template axis; the note admits it matters less on modern optimisers                   |
| Element type is free (`RGBValue`, `TinyVector`, `Multiband`)       | One algorithm covers scalar, RGB, N-band and N-D without rewriting        | Combinatorial instantiation; compile time and code size grow with the matrix                   |
| `NumericTraits`/`PromoteTraits` for accumulation + clamp-round     | Correct integer-pixel arithmetic without the caller choosing a wider type | The write path clamps only floating results; an integer result wraps                           |
| Accessors separate "where" from "how to read/write"                | Read red-as-grey or one channel with no proxy-reference type              | An extra template parameter threaded through every algorithm signature                         |
| Functor + three-mode facade (standard/expand/reduce)               | Broadcast and reduction fall out of one call; STL-style composability     | Mode is inferred from shape and `FunctorTraits`, which is implicit and subtle                  |
| Codecs behind a scanline-pull virtual `Decoder`/`Encoder`          | Uniform interface over libpng/libjpeg/libtiff and from-scratch readers    | File-path, whole-image, not suspendable; trusts header-supplied dimensions                     |
| `std::allocator` owner, borrow-by-value views                      | Simple, exception-safe ownership; aliasing copy goes through a temporary  | No arena, CoW, generational handle or caller-storage decode                                    |
| Block-decomposition `ThreadPool`, no SIMD                          | Portable coarse parallelism with border halos; optimiser handles the loop | No vectorisation control; `std::function` queue overhead per chunk                             |
| Out-of-core `ChunkedArray` with cache + backends                   | Terabyte volumes via tiles, memory-map, compression, HDF5                 | Per-chunk `std::mutex`; chunked-view access is two-step and slower than a view                 |

---

## Sources

- [ukoethe/vigra — GitHub repository][repo] (read at `de98f930b`, version 1.12.4)
- [`include/vigra/multi_array.hxx` — `MultiArrayView`, `MultiArray`, slicing, `elementCount`][ma-view]
- [`include/vigra/multi_array.hxx` — the `VIGRA_ASSERT_INSIDE` bounds macro][ma-bounds] and [`elementCount`][ma-count]
- [`include/vigra/basicimage.hxx` — the deprecated 2-D `BasicImage`][basicimage]
- [`include/vigra/multi_shape.hxx` — `defaultStride`, `defaultMultibandStride`][shape]
- [`include/vigra/multi_fwd.hxx` — `MultiArrayIndex`, `Multiband`, forward decls][fwd]
- [`include/vigra/metaprogramming.hxx` — the stride tags][meta]
- [`include/vigra/numerictraits.hxx` — `NumericTraits`, `PromoteTraits`][numtraits] and [`RequiresExplicitCast`][cast]
- [`include/vigra/rgbvalue.hxx` — `RGBValue`, `RGBToGrayAccessor`, `luminance`][rgb]
- [`include/vigra/accessor.hxx` — `StandardAccessor`, `AccessorTraits`][accessor]
- [`include/vigra/colorconversions.hxx` — `RGB2sRGBFunctor` and the colour functors][colorconv]
- [`include/vigra/codec.hxx` — the `Decoder`/`Encoder`/`CodecFactory` seam][codec]
- [`src/impex/codecmanager.cxx` — `getDecoder`/`getEncoder` codec selection][codecmgr]
- [`include/vigra/imageinfo.hxx` — `ImageImportInfo`/`ImageExportInfo`, ICC profile][info]
- [`include/vigra/multi_pointoperators.hxx` — `transformMultiArray`, `combineTwoMultiArrays`][pointops]
- [`include/vigra/imageiterator.hxx` — the 2-D `ImageIterator`][iterator]
- [`include/vigra/multi_array_chunked.hxx` — `ChunkedArray` and its backends][chunked]
- [`include/vigra/multi_blockwise.hxx` — block decomposition with border halos][blockwise]
- [`include/vigra/threadpool.hxx` — `ParallelOptions`, `ThreadPool`, `parallel_foreach`][pool]
- [`include/vigra/multi_opencl.hxx` — OpenCL-type trait glue (no kernels)][opencl]
- [`include/vigra/axistags.hxx` — `AxisType`/`AxisInfo`][axistags]
- [`include/vigra/numpy_array.hxx` — `NumpyArray`/`NumpyAnyArray` stride setup][numpy]
- [`vigranumpy/lib/arraytypes.py` — `VigraArray`, default `'V'` order][vigraarray]
- [`vigranumpy/docsrc/index.rst` — the C/F/V/A order definitions][orderdoc]
- [`src/impex/bmp.cxx` — the BMP decoder's header validation][bmp] and [buffer sizing][bmp-load]
- [Köthe, "The VIGRA image analysis library" (IPOL 2012)][vigra-ipol]
- Related Sparkles research: [generic-image-programming paper thread][p-generic] ·
  [hostile-input paper thread][p-hostile] ·
  [existing-code baseline][bl-existing] · [shaders-SIMD baseline][bl-shaders]

<!-- References -->

[repo]: https://github.com/ukoethe/vigra
[docs]: https://ukoethe.github.io/vigra/
[license]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/LICENSE.txt
[ma-view]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/multi_array.hxx#L668-L704
[ma-bounds]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/multi_array.hxx#L54-L60
[ma-count]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/multi_array.hxx#L1630-L1638
[basicimage]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/basicimage.hxx#L463-L466
[cast]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/numerictraits.hxx#L1225-L1246
[codecmgr]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/src/impex/codecmanager.cxx#L184-L290
[bmp-load]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/src/impex/bmp.cxx#L332-L360
[ma-own]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/multi_array.hxx#L2458-L2480
[shape]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/multi_shape.hxx#L142-L175
[fwd]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/multi_fwd.hxx#L55-L130
[meta]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/metaprogramming.hxx#L95-L130
[numtraits]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/numerictraits.hxx#L616-L652
[rgb]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/rgbvalue.hxx#L125-L303
[accessor]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/accessor.hxx#L197-L245
[colorconv]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/colorconversions.hxx#L405-L460
[codec]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/codec.hxx#L139-L247
[info]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/imageinfo.hxx#L390-L557
[pointops]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/multi_pointoperators.hxx#L1026-L1045
[iterator]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/imageiterator.hxx#L563-L680
[chunked]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/multi_array_chunked.hxx#L1386-L1523
[blockwise]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/multi_blockwise.hxx#L180-L222
[pool]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/threadpool.hxx#L61-L575
[opencl]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/multi_opencl.hxx#L36-L80
[axistags]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/axistags.hxx#L50-L96
[numpy]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/include/vigra/numpy_array.hxx#L1239-L1290
[vigraarray]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/vigranumpy/lib/arraytypes.py#L342-L400
[orderdoc]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/vigranumpy/docsrc/index.rst#L134-L175
[bmp]: https://github.com/ukoethe/vigra/blob/de98f930b66d461360a2d5dc8f9adfa84bb01058/src/impex/bmp.cxx#L168-L200
[vigra-ipol]: https://www.ipol.im/event/2012_imlib/docs/vigra.pdf
[p-generic]: ./papers/generic-image-programming.md
[p-hostile]: ./papers/hostile-input-safety.md
[bl-existing]: ./baseline/existing-code.md
[bl-shaders]: ./baseline/shaders-simd.md
