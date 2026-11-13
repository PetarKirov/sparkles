# mir-algorithm and mir-core (D)

The D ecosystem's N-dimensional array library: `mir.ndslice`'s `Slice!(Iterator, N, kind)` is a strided view over any random-access iterator, with contiguity encoded in the type, lazy topology selectors, and allocation kept apart from views; it is the existing D candidate for the memory model under a Sparkles `Image` type.

| Field         | Value                                                                                                                                                    |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | D (DMD and LDC; LDC-specific `@fmamath` and SIMD paths)                                                                                                  |
| License       | Apache-2.0 (both repositories) ([`LICENSE`][license], [`dub.sdl`][dub-sdl])                                                                              |
| Repository    | [libmir/mir-algorithm][repo], with its dependency [libmir/mir-core][core-repo]                                                                           |
| Revision read | mir-algorithm `2da212382e434ef86e93f7b028bc2309205ae00e` (`v3.22.4-5`, February 4, 2026); mir-core `4397b03a804b0368100e99252016c7b32aa562d1` (`v1.7.4`) |
| Documentation | [mir-algorithm.libmir.org][docs] (generated DDoc, including [`mir.ndslice.slice`][docs-slice])                                                           |
| Category      | D landscape: N-D arrays, views and iteration                                                                                                             |
| Tier          | A                                                                                                                                                        |
| Last reviewed | November 7, 2026                                                                                                                                         |

> [!NOTE]
> The project is maintained, not archived. The GitHub API on November 7, 2026 reported
> `archived: false` for both repositories and a mir-algorithm push on November 6, 2026;
> `git ls-remote` lists a tag `v3.22.5` (`ba6d483`). The pin read here is nine months
> older than that tag. The documentation site's title, "mir-algorithm API Reference ·
> Libmir Archive", is the site's name, not a statement about the repositories; the
> [generic-image-programming thread][p-generic-mir] now says so too.

> [!IMPORTANT]
> Claims marked **verified** were demonstrated by compiling and running programs against
> the pinned sources (extracted with `git archive`, compiled with LDC 1.43.0 and DMD
> 2.112.1 from the Sparkles dev shell, in a scratch directory outside the repository).
> Everything else was read in the source and is **documented**. No performance numbers
> are stated; only struct sizes, which were printed.

---

## Overview

### What it solves

D's built-in slice `T[]` is a pointer and a length. It has no shape, no strides and no
notion of rows, so every image library in D has either hand-rolled a `(data, width,
height, pitch)` struct or flattened images into one dimension and computed indices by
hand. The Sparkles baseline records exactly this: pixels travel as `const(ubyte)[]` plus
a `Size`, as `ColourRegion` (data plus stride) or as `ImagePixels` (no padding), and no
package carries a strided view type ([existing code, G2][bl-existing-g2]).

`mir.ndslice` supplies the missing type. A `Slice` is lengths, strides and an iterator;
every view operation (sub-rectangle, transpose, reversal, striding, windows, tiles,
element-wise maps, zipping) rewrites those three fields or wraps the iterator, and never
touches the data. `mir.algorithm.iteration` then supplies the loops (`each`, `reduce`,
`all`, `equal`, `count`, ...) that walk any slice kind, and `mir.ndslice.allocation`
supplies the few functions that allocate, from the GC, a `std.experimental.allocator`
allocator, `malloc`, or a reference-counted heap block.

### Design philosophy

The `Slice` documentation states the separation of views from storage outright
([`slice.d`][slice-repr]):

> _"Multidimensional Slice is a structure that consists of lengths, strides, and a
> iterator (pointer). … With the exception of $(MREF mir,ndslice,allocation) module, no
> functions in this package move or copy data. The operations are only carried out on
> lengths, strides, and pointers."_

The `$(MREF …)` is the DDoc macro for `mir.ndslice.allocation`.

and the topology module opens with the same promise ([`topology.d`][topo-header]):

> _"Selectors create new views and iteration patterns over the same data, without
> copying."_

Three further commitments shape the design:

1. **Contiguity is a type parameter, not a run-time flag.** `SliceKind` has three
   members, and a slice of each kind stores a different number of strides
   ([`slice.d`][slice-kind]). Algorithms dispatch on it with `static if`.
2. **Everything is an iterator or a field.** A `Slice` is generic over any type that
   passes `isIterator` (pointer-like arithmetic and indexing,
   [`traits.d`][traits-iterator]); a "field" is anything with `opIndex(ptrdiff_t)`
   ([`field.d`][field]). Lazy views are new iterator types (`MapIterator`,
   `ZipIterator`, `StrideIterator`, `SliceIterator`, ...), listed in
   [`iterator.d`][iterator].
3. **No runtime dependency where possible.** mir-core's README states the constraint
   for the base layer ([`README.md`][core-readme]):

   > _"no runtime dependency : betterC compatible when compiled with LDC in release
   > mode. Exceptions: `@nogc` `mir.exception`."_

   mir-algorithm inherits the stance without stating it as a rule; its
   `mir.algorithm.iteration` header credits a "Mir & BetterC rework" of Phobos code
   ([`iteration.d`][iter-header]).

The safety contract is stated at the top of `slice.d` ([`slice.d`][slice-note]):

> _"User-defined iterators should care about their safety except bounds checks. Bounds
> are checked in ndslice code."_

How those bounds checks are made, and what they miss, is the subject of
[dimension 5][dim5].

---

## How it works

### The `Slice` struct and its three kinds

`Slice` is an alias for `mir_slice` ([`slice.d`][slice-alias]), declared with a fixed
shape constraint ([`slice.d`][slice-struct]):

```d
// source/mir/ndslice/slice.d (abridged)
enum mir_slice_kind
{
    /// A slice has strides for all dimensions.
    universal,
    /// A slice has >=2 dimensions and row dimension is contiguous.
    canonical,
    /// A slice is a flat contiguous data without strides.
    contiguous,
}

struct mir_slice(Iterator_, size_t N_ = 1, SliceKind kind_ = Contiguous, Labels_...)
    if (0 < N_ && N_ < 255 && !(kind_ == Canonical && N_ == 1) && Labels_.length <= N_ && isIterator!Iterator_)
{
@fmamath:
    enum size_t S = kind == Universal ? N : kind == Canonical ? N - 1 : 0;
    // ...
    public alias _Structure = AliasSeq!(size_t[N], ptrdiff_t[S]);
    public _Structure _structure;
    public alias _lengths = _structure[0];
    public alias _strides = _structure[1];
    public Iterator _iterator;
    public Labels _labels;
```

Lengths are `size_t[N]`; strides are signed `ptrdiff_t[S]`, counted **in elements of the
iterator**, not in bytes; a negative stride is how `reversed` works without moving the
iterator past the data. The `Labels` parameter carries per-dimension label iterators
(the `mir.series` data-frame use) and is empty for plain arrays.

What the kinds store, and what they promise:

| Kind         | Strides stored | Promise                                                      | Typical source                                          |
| ------------ | -------------- | ------------------------------------------------------------ | ------------------------------------------------------- |
| `Contiguous` | 0              | the whole N-D block is one run of elements, row-major        | `slice!T(h, w)`, `sliced` over an array                 |
| `Canonical`  | N - 1          | the last dimension is contiguous (stride 1); others are free | a sub-rectangle `img[y0 .. y1, x0 .. x1]`, padded rows  |
| `Universal`  | N              | none; every dimension has its own stride                     | `transposed`, `reversed`, `strided`, a column of pixels |

The documentation compares the kinds with established layouts: "BLAS/LAPACK matrices
are Canonical" and "NumPy strides are Universal" ([`slice.d`][slice-repr]).

**Verified on x86_64:** the struct sizes for a pointer iterator are
`Slice!(ubyte*, 2)` 24 bytes, `Slice!(ubyte*, 2, Canonical)` 32,
`Slice!(ubyte*, 2, Universal)` 40, `Slice!(ubyte*, 3, Canonical)` 48 and
`Slice!(ubyte*, 3, Universal)` 56. The cost of a kind is one word per stored stride, plus
whatever the inner loop loses when it cannot assume stride 1 (not measured).

Kinds only weaken through views: `universal` and `canonical` convert up the chain, and
`assumeCanonical`/`assumeContiguous` convert down; the module index says each "Does
only `assert` checks" ([`topology.d`][topo-header]). Element access goes through `indexStride`, which sums
`index * stride` per dimension after an `assert(index < length)`
([`slice.d`][index-stride]), and the `opIndex` overloads apply it to the iterator
([`slice.d`][opindex]).

### Construction

`sliced` builds a `Contiguous` slice over an array, pointer or iterator
([`slice.d`][sliced]). For arrays it checks the size once:

```d
// source/mir/ndslice/slice.d, sliced
static if (isDynamicArray!Iterator)
{
    assert(lengthsProduct(_lengths) <= iterator.length,
        "array length should be greater or equal to the product of constructed ndslice lengths");
    auto ptr = iterator.length ? &iterator[0] : null;
    return Slice!(typeof(C.init[0])*, N)(_lengths, ptr);
}
```

For any other kind, construction is the struct's literal constructor:
`Slice!(uint*, 2, Universal)([2, 2], [4, 1], array.ptr)` is the module's own test
([`slice.d`][slice-ctor-test]). No function validates explicit strides against a backing
extent; the fields are public.

### Topology: views without copies

The selectors that matter for images, all in `mir.ndslice.topology` unless noted:

| Selector                                                                             | Result kind                          | Image use                                                                 |
| ------------------------------------------------------------------------------------ | ------------------------------------ | ------------------------------------------------------------------------- |
| `img[y0 .. y1, x0 .. x1]`                                                            | `Canonical` (from `Contiguous`)      | region of interest, crop                                                  |
| `transposed` ([`dynamic.d`][transposed])                                             | `Universal`                          | rotate by 90 degrees with `reversed`; interleaved to planar (`[c, y, x]`) |
| `reversed` ([`dynamic.d`][reversed])                                                 | `Universal`                          | flips; bottom-up BMP rows                                                 |
| `stride` ([`topology.d`][stride])                                                    | 1-D only, `StrideIterator`           | subsampling one row; `strided` (in `dynamic`) for N-D                     |
| `pack!P`, `ipack!P`, `unpack` ([`pack`][pack], [`ipack`][ipack], [`unpack`][unpack]) | outer `Universal`, inner by kind     | a 2-D slice of pixels (`[h, w, 4].pack!1`), or of rows                    |
| `windows` ([`topology.d`][windows])                                                  | packed, outer `Universal`            | overlapping neighbourhoods: convolution, morphology                       |
| `blocks` ([`topology.d`][blocks])                                                    | packed, outer `Universal`            | tiles; "residual blocks are ignored"                                      |
| `map`, `vmap` ([`topology.d`][map])                                                  | same kind, `MapIterator`             | per-pixel functions, lazily                                               |
| `as!T` ([`topology.d`][as])                                                          | same kind, `map!(to!T)`              | `ubyte` to `float` promotion                                              |
| `zip` ([`topology.d`][zip])                                                          | `ZipIterator`, same strides required | planes or images in lock-step                                             |
| `bitwise`, `bitpack!k` ([`topology.d`][bitwise])                                     | `FieldIterator!BitField`             | 1-bit masks, sub-byte samples                                             |
| `bytegroup!(g, T)` ([`topology.d`][bytegroup])                                       | `BytegroupIterator`                  | 24-bit RGB as packed groups, endian-correct                               |

`pack!P` "Packs the last `P` dimensions" ([`topology.d`][pack]) by calling `ipack`, which
moves the iterator into a `SliceIterator` that carries the inner lengths and strides
([`topology.d`][ipack]):

```d
// source/mir/ndslice/topology.d, ipack (abridged)
auto sl = slice.move.universal;
return Ret(
    cast(   size_t[P]) sl._lengths[0 .. P],
    cast(ptrdiff_t[P]) sl._strides[0 .. P],
    It(
        cast(   size_t[EN]) sl._lengths[P .. $],
        cast(ptrdiff_t[ES]) sl._strides[P .. $ - (It.Element.kind == Canonical)],
        sl._iterator.move));
```

The outer slice always becomes `Universal`: a packed slice stores every outer stride.

### Iteration

`each` has one fast path. If every argument is `Contiguous`, it flattens all of them to
one dimension and loops once; otherwise it recurses one dimension at a time with
`front`/`popFront` ([`iteration.d`][each]):

```d
// source/mir/algorithm/iteration.d, each
static if (Slices.length > 1)
    slices.checkShapesMatch;
static if (areAllContiguousSlices!Slices)
{
    import mir.ndslice.topology: flattened;
    .each!fun(allFlattened!(allLightScope!slices));
}
else
{
    if (slices[0].anyEmpty)
        return;
    eachImpl!fun(allLightScope!slices);
}
```

`eachImpl` ([`iteration.d`][each-impl]) and `reduceImpl` ([`iteration.d`][reduce-impl])
are the same nested `do ... while` over dimensions. A `Canonical` image therefore runs
as one loop per row with a unit-stride inner loop, which is the shape LLVM can
vectorise; `checkShapesMatch` asserts that zipped arguments agree in shape
([`iteration.d`][check-shapes]).

### Allocation

[`allocation.d`][alloc-header] groups the allocating functions by source:

| Family             | Functions                                                           | Failure behaviour                                                   |
| ------------------ | ------------------------------------------------------------------- | ------------------------------------------------------------------- |
| GC                 | `slice`, `uninitSlice`, `bitSlice`, `ndarray`, `uninitAlignedSlice` | no check in mir (left to the GC); `uninitAlignedSlice` is `@system` |
| Allocator          | `makeSlice`, `makeUninitSlice`, `makeNdarray`                       | `if (mem.length == 0) assert(0);`                                   |
| C runtime          | `stdcSlice`, `stdcUninitSlice`, `stdcFreeSlice`, aligned variants   | `if (p is null) assert(0);`                                         |
| Reference counting | `rcslice`, `mininitRcslice`, `bitRcslice`                           | throws a preallocated `OutOfMemoryError`                            |

Every one returns a `Contiguous` slice; none takes a row pitch or alignment per row.
`rcslice` stores a `mir_rc_context` header (deallocator, type info, a `shared size_t`
counter and the length) in front of the payload in one `malloc` block
([`rc/context.d`][rc-context], [`rc/context.d`][rc-create]); the iterator is `mir_rci!T`,
and the module states "The implementation never adds roots into the GC." ([`rc/array.d`][rc-array]).

---

## Analysis

### 1. Pixel and memory model

`Slice` is an N-D strided view, so the three image layouts the focus names all map onto
it, each with a different cost. **Verified** with a 5 x 3 RGBA image whose rows are 24
bytes (20 bytes of pixels, 4 of padding):

```d
// scratch experiment, layouts.d
auto il = Slice!(ubyte*, 3, Canonical)([size_t(H), W, 4], [ptrdiff_t(pitchBytes), 4], &buf[0]);
auto px = Slice!(RGBA*, 2, Canonical)([size_t(H), W], [ptrdiff_t(pitchBytes / RGBA.sizeof)], cast(RGBA*) &buf[0]);
auto planar = il.transposed!2;   // [4, H, W], Universal, strides 1, 24, 4
auto packed = il.pack!1;         // 2-D slice of 1-D pixel slices
```

- **Interleaved RGBA** has two spellings. As `Slice!(ubyte*, 3, Canonical)` with lengths
  `[h, w, 4]`, channels are a dimension, the row pitch is any number of bytes, and
  `reduce` over it sums only the pixels (verified: 2010, the padding excluded). As
  `Slice!(RGBA*, 2, Canonical)` the pixel is the element, which reads better but forces
  the pitch to be a multiple of `RGBA.sizeof`, because strides count elements.
- **Planar** is `[c, h, w]`: either `transposed!2` of the interleaved view (a `Universal`
  slice whose channel stride is 1, verified) or, for genuinely separate plane storage,
  one slice per plane.
- **Planar YUV 4:2:0 with independent per-plane pitches** does not fit one `Slice`. The
  planes differ in lengths (chroma is half size in both axes) and in strides, and `Slice`
  has one iterator and one stride per dimension. It is three `Slice!(ubyte*, 2,
Canonical)` values, one per plane. A luma-resolution chroma view is a lazy index map
  (`ndiota(h, w).map!(ij => U[ij[0] / 2, ij[1] / 2])`, verified to compile and produce a
  `Contiguous` 2-D view); a semi-planar NV12 chroma plane is `[h / 2, w / 2, 2]`.

**Limits, all consequences of element strides:**

- A row pitch that is not a multiple of the element size cannot be represented. An RGBA
  struct over a 22-byte pitch has no element stride; the `ubyte` view must be used, or
  the decoder must realign. The Python-buffer bridge makes the same rule explicit with
  `assert(view.strides[i] % T.sizeof == 0)` ([`connect/cpython.d`][cpython]).
- Sub-byte formats (1-bit masks, 4-bit palette indices, 10-bit packed video) are not
  pointer-strided at all; `bitwise` and `bitpack!k` give them a `BitField` iterator, and
  `bitwise` requires a non-`Universal` slice for N greater than 1
  ([`topology.d`][bitwise]).
- Tiles and N-D extents are views (`blocks`, `windows`, any N up to 254), not storage
  layouts: a tiled TIFF or a GPU-swizzled texture needs a custom iterator or field. An
  iterator can do this (`slicedField`, `slicedNdField` exist for exactly that), but
  nothing in mir provides one.
- `blocks` drops edge tiles: a 3 x 5 image in 2 x 2 blocks gives 1 x 2 tiles (verified).
  `mir.ndslice.chunks` handles residuals ([`chunks.d`][chunks]).

### 2. Genericity mechanism

The mechanism is D templates with structural constraints, the
[design-by-introspection][dbi] style in all but name:

- `Slice` is generic over `Iterator`, gated by `isIterator`, a `__traits(compiles, ...)`
  test for difference, increment, decrement and indexing ([`traits.d`][traits-iterator]).
  Any pointer, any field wrapped in `FieldIterator`, and every lazy iterator in
  [`iterator.d`][iterator] qualifies.
- `SliceKind` is a non-type template parameter, so kind-specific code is `static if
(kind == Contiguous)`; `zip`, `each`, `bitwise` and `bytegroup` all branch this way.
- Qualifiers propagate through mir-core's `lightConst`, `lightImmutable` and
  `lightScope` protocol ([`mir.qualifier`][core-qualifier]): a `const` slice of a
  reference-counted iterator becomes a slice of a `const` iterator, and `lightScope`
  strips the reference count for the duration of a loop.

There is no pixel concept. A pixel is whatever `DeepElement` is: `ubyte`, a user struct,
a `refTuple` from `zip`, or the result of a `map`. Channel order, alpha mode, transfer
function and bit depth are not part of the type. A Sparkles image type would add them as
a layer above (`isImageView`, `hasScanlines`, `isPlanar`, as the
[paper thread's synthesis][p-generic-synth] proposes) or encode them in the element type.

### 3. Colour and metadata

Not applicable: mir-algorithm has no colour, colour-space, transfer-function, ICC, CICP,
EXIF or XMP model, and does not claim one. Its numeric support (`mir.math`,
`mir.interpolate`) can implement colour conversions as `map` functions, but the
semantics live in the caller. The `Labels` template parameter attaches per-axis label
arrays (for `mir.series`), not per-image metadata.

### 4. I/O and codec architecture

Not applicable: mir-algorithm reads and writes no image or file format. Its serialisation
neighbour, mir-ion, is out of scope here. The relevant property for a codec is that a
decoder can write into a `Slice` it did not allocate: `sliced` over caller storage, or a
`Canonical` sub-view of a padded buffer, is a valid destination for `dst[] = src` and
`each`. **Verified:** a `float` destination slice over a caller's stack array filled by
`dst[] = row.as!float.map!(a => a / 255.0f)` with no allocation, under `-betterC`.

### 5. Hostile input and safety

This is where mir is weakest as a foundation for decoders. The library's bounds checks
are `assert`s in `indexStride` and `sliced`, the size arithmetic is unchecked, and the
`@trusted` boundary is wide. Four behaviours were **verified** in functions explicitly
annotated `@safe pure nothrow @nogc`, compiled with `-preview=dip1000`:

```d
// scratch experiment, safety.d
@safe pure nothrow @nogc ubyte wrapRead(ubyte[] backing)
{
    auto s = backing[0 .. 16].sliced((size_t(1) << 62) + 1, 4); // product wraps to 4
    return s[4, 0];                                              // byte 16: outside the slice's array
}
@safe pure nothrow @nogc int reversedContiguous(int[] backing)
{
    auto r = backing[0 .. 4].sliced.reversed;  // iterator at element 3, stride -1
    return r.assumeContiguous[3];              // reads element 6
}
```

| Case                                                         | Debug build                              | `-release`              |
| ------------------------------------------------------------ | ---------------------------------------- | ----------------------- |
| `sliced` with lengths whose product overflows `size_t`       | reads outside the source array, no error | same                    |
| `reversed` then `assumeContiguous`, index within the length  | reads outside the source array, no error | same                    |
| struct literal with strides that exceed the described extent | reads beyond the 2 x 2 extent, no error  | same                    |
| index past a length (`[3, 0]` on a 2 x 2 slice)              | `AssertError` "bounds check failed"      | reads outside, no error |
| `zip!true` on planes of different pitch                      | `AssertError`                            | no error                |

The causes, in the source:

- `lengthsProduct` multiplies `size_t` lengths with no overflow check
  ([`internal.d`][lengths-product]), although mir-core ships `mir.checkedint`
  ([`checkedint.d`][core-checkedint]). `sliced`'s only guard is `assert(lengthsProduct(...)
<= iterator.length)`, which a wrapped product passes. The allocators have the same
  shape: `makeUninitSlice` computes `len * T.sizeof` unchecked ([`allocation.d`][make-uninit]),
  `stdcUninitSlice` likewise ([`allocation.d`][stdc-uninit]), and `mir_rc_create`
  computes `length * typeInfo.size` unchecked ([`rc/context.d`][rc-create]). A decoder
  that passes header dimensions straight to these functions gets a small buffer and a
  huge slice.
- `assumeContiguous` is documented as "(unsafe)" but is an unannotated template whose
  body only copies fields, so it infers `@safe` ([`topology.d`][assume-contiguous]).
- The element `opIndex` overloads are templates marked `@trusted` as a whole
  ([`slice.d`][opindex]). Their soundness depends on the invariant that lengths and
  strides describe memory the iterator may reach, and that invariant is held only by
  convention: the fields and the literal constructor are public.
- Index checks are `assert`, not D array bounds checks, so `-boundscheck=on` does not
  restore them under `-release` (verified). Sparkles ships `checked` builds, in which
  asserts stay live ([build types][agents-build]), so the index check would survive
  there; the three overflow and invariant cases above do not depend on build mode.

The Sparkles guidelines reach the opposite conclusion on two of these points: `@trusted`
"wraps only the unavoidable operation ... never a whole function, never a template", and
the generic-programming synthesis asks to "Validate stride × extent against the backing
buffer once, at construction, so a hostile decoder header cannot create an out-of-bounds
view" ([paper synthesis][p-generic-synth]). mir has no fuzzing harness in the repository.

`dip1000` does work through `Slice` (verified): returning `a[].sliced(4, 4)` over a local
static array, or a `transposed` view of it, from an `@safe` function is rejected with
"escaping a reference to local variable" and "returning scope variable".

### 6. Allocation and ownership

Views own nothing; ownership is the iterator's. A `T*` slice borrows; an `RCI!T` slice
shares ownership by atomic reference count; a `T[]` from `slice!T` is GC-owned.
`makeSlice` accepts any `std.experimental.allocator` allocator ([`allocation.d`][make-uninit]),
which matches Sparkles' allocator guidance, but the result is a borrowed `T*` slice and
the caller must remember the allocator and the original length to free it (the
`stdcFreeSlice` pair makes the same demand).

Gaps for an image library:

- Every allocator returns a `Contiguous` block. There is no "allocate `h` rows of `w`
  pixels with each row aligned to 64 bytes" function, so a padded, aligned image (the
  usual layout for SIMD row loops and GPU staging) is a 1-D allocation sliced into a
  `Canonical` view by hand.
- Allocation failure is `assert(0)` in the allocator and C-runtime families and an
  `Error` in the reference-counted one. None returns an `Expected`; a decoder that wants
  to report "image too large" as a value must check sizes before calling.
- `rcslice` uses `malloc` through `mir.internal.memory` only; it takes no allocator, and
  its header is not aligned beyond `malloc`'s guarantee.
- There is no move-only owning slice. Sparkles' default, [`UniqueBuffer`][buffer-spec],
  has no counterpart; `rcslice` corresponds to `SharedBuffer`.

### 7. CPU parallelism and SIMD

mir-algorithm has no parallel loops: no `std.parallelism`, no thread pool, no tiling
scheduler in `ndslice` or `algorithm`. Parallelism is the caller's, typically by
splitting the outer dimension (`blocks`, `chopped`, or row ranges) across workers.

It has no explicit SIMD in `ndslice` either. `mir.internal.ldc_simd` is used by
`mir.string` and `mir.interpolate`, not by the slice loops. Vectorisation is left to
LLVM, helped by two choices: the unit-stride inner loop of `Canonical` and `Contiguous`
slices, and `@fmamath`, which the whole `Slice` struct is marked with and which is
`llvmFastMathFlag("contract")` on LDC ([`math/common.d`][core-fmamath]). **Verified only
coarsely:** at `-O3 -mcpu=x86-64-v3`, the object code for `each` over `Contiguous`,
`Canonical` and `Universal` views of a byte image contains AVX `ymm` instructions in all
three functions; which loops are vectorised, and how fast, was not measured.

`contract` permits fused multiply-add. A `float` kernel compiled through `Slice` may
therefore round differently from a scalar reference, which matters to exact-output
oracles (the [shaders baseline, G8][bl-shaders-g8], already sees ULP-scale differences
between host and device).

### 8. GPU offload and interop

mir-algorithm has no GPU support. Its interop surfaces are:

- **The Python buffer protocol** ([`connect/cpython.d`][cpython]): `fromPythonBuffer`
  and `toPythonBuffer`, `nothrow @nogc @trusted`, convert byte strides to element strides
  and back, and reject format, item-size and dimension mismatches with error codes. They
  copy shape and strides from the buffer without checking them against any extent.
- **C++ headers** under `include/mir/` mirror `mir_slice`, `mir_rcarray` and friends for
  `extern(C++)` calls. Read, not compiled: the primary C++ template, used for the
  `universal` and `canonical` kinds, declares `mir_size_t _lengths[0]` where the D
  struct has `size_t[N]`, while the `contiguous` specialisations declare `_lengths[N]`
  ([`ndslice.h`][cpp-header]).
- **DLPack** is not supported; nothing in either repository mentions it. The mapping is
  close: a `DLTensor` carries `int64_t` shape, `int64_t` strides "in number of elements,
  not bytes", and a `byte_offset` ([`dlpack.h`][dlpack-h]), which is a `Universal`
  `Slice` plus a device tag and a dtype. Element strides on both sides avoid the
  byte-to-element division; the 64-bit fields narrow on 32-bit targets such as wasm32.

The neighbours: [dcompute][dcompute-research] compiles D kernels for OpenCL and CUDA and
has no `ndslice` dependency (a search of its tree finds none); [lubeck][lubeck] is a
BLAS/LAPACK front end that takes and returns `Slice`.

### 9. Temporal, animation and containers

Not applicable as a feature. Time is one more dimension: a video clip or an animation
is a 4-D `[t, h, w, c]` slice, and `pack!3` iterates frames, but there is no frame
timing, disposal mode, container or streaming model.

### 10. Testing and conformance

Tests are DDoc'd unittests in the modules, gated by version identifiers
(`mir_ndslice_test`, `mir_test`) that `dub.sdl`'s `unittest` build type sets
([`dub.sdl`][dub-sdl]); the pinned `slice.d`, `topology.d` and `iteration.d` contain
118, 152 and 114 lines containing `unittest`. CI runs `dub test` on Ubuntu for `x86` and
`x86_64`, on macOS `x86_64` and on Windows `x86_64`, against DMD and LDC master, latest
and beta
([`ci.yml`][ci], [`compilers.json`][compilers]). Read in that configuration: no
`-betterC`, no wasm and no Android job, no `-preview=dip1000` job (a `unittest-dip1000`
build type exists but CI does not select it), no sanitizer and no fuzzing.

What this survey ran, all **verified**:

| Build                                                                                                | Result                                                                                                                          |
| ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| LDC, DMD; `-preview=dip1000 -preview=in`                                                             | `@safe pure nothrow @nogc` functions using `sliced`, sub-views, `windows`, `reduce`, `each`, `all`, `map`, `as` compile and run |
| LDC `-betterC`, with and without `-release`                                                          | the same program runs; `rcslice` also runs under `-betterC`                                                                     |
| DMD `-betterC`                                                                                       | the same program runs                                                                                                           |
| LDC `-betterC`, `wasm32-unknown-unknown`, only the program's module compiled (`-I` to mir's sources) | compiles, links (with a trapping `__assert`) and runs under Node.js with no imports, for `Contiguous` and `Canonical` views     |
| LDC `-betterC`, `wasm32-unknown-unknown`, mir's modules compiled too (`ldc2 -i`, `dub build`)        | fails: `mir/internal/memory.d(154): static assert` (only `Posix` and `Windows` are handled)                                     |

The wasm outcome depends on what is compiled, not on what the program uses.
`mir.internal.memory` ends in a module-level `else static assert(0);`
([`memory.d`][core-memory]), so it fails whenever that module is compiled for a target
that is neither `Posix` nor `Windows`. `Slice` reaches it through imports: for a
non-pointer or non-contiguous slice it imports `mir.rc.array` to declare `ptr`
([`slice.d`][slice-ptr-rc]), which imports `mir.rc.context`, whose `mir_rc_create`
imports `mir.internal.memory` inside its body ([`rc/context.d`][rc-create]). Compiling
only the program's module, with mir's templates instantiated there, never analyses that
body: `sliced` plus `reduce` over a `Contiguous` and over a `Canonical` view compiled,
linked with `-link-internally -L--no-entry -L--export-dynamic` and a trapping `__assert`,
and returned the expected sums under Node.js (verified). `ldc2 -i` compiles every
imported module and fails on both views, and so does a `dub build
--arch=wasm32-unknown-unknown-wasm`, which compiles `mir-core` as a library first
(verified). The [experiment][slice-experiment] reaches the same result for its kernels
and adds a druntime-side failure (an array cast). Android is a `Posix` target and was
not tried here; the experiment links for it.

---

## Lessons for Sparkles

The [`Slice` experiment][slice-experiment] tests these points on Sparkles' own build;
this section gives the evidence from reading and from the scratch runs above.

- **Q1: the three-kind classification transfers; the element-stride unit is a choice
  with a cost.** `Contiguous`/`Canonical`/`Universal` encode exactly the properties an
  image loop specialises on, and `Canonical` is the ordinary padded image. Element
  strides make `RGBA`-typed views fail on odd pitches; byte strides (NumPy, the
  [paper synthesis][p-generic-synth]) make every access a cast. mir answers this by
  making `ubyte` with a channel dimension the universal fallback. Where Sparkles stands:
  no view type at all ([existing code, G2][bl-existing-g2]; [shaders, G10][bl-shaders-g10]).
- **Q1: planar YUV is a tuple of slices, not a slice.** Independent per-plane lengths and
  pitches need one `Slice` per plane, and `zip` refuses multi-dimensional slices of
  different strides (a `static assert` without `sameStrides`, an `assert` with it). A
  Sparkles image type for video formats is therefore a struct of planes over slices, with
  the plane relationship (subsampling, siting) in that struct. This holds whether or not
  the planes are mir slices.
- **Q2, Q3: lazy topology composes cheaply and stays `@nogc`.** `map`, `as`, `windows`,
  `blocks`, `pack`, sub-views and `each`/`reduce` all compiled in `@safe pure nothrow
@nogc` code over caller storage, with `-preview=dip1000`, and `dip1000` caught escapes
  through the view types. This matches the [functional guideline][fp-guideline], which
  already tells authors to "use `mir.ndslice` for any multidimensional data" while no
  package does ([existing code, capability table][bl-existing-cap]).
- **Q3, Q7: no parallel or SIMD layer to inherit.** The unit-stride row loop is the only
  vectorisation aid; dispatch to AVX2/AVX-512/NEON kernels would remain Sparkles' own,
  as in the BLAKE3 pattern ([shaders baseline, G4 and G5][bl-shaders-g4]). `@fmamath`
  on `Slice` changes float rounding, which an exact-output oracle must account for.
- **Q4, Q8: the safety model does not meet a hostile-input bar.** Unchecked
  `lengthsProduct`, unvalidated public fields, an `assumeContiguous` that infers `@safe`
  and whole-template `@trusted` indexing mean that mir cannot be the layer that validates
  a decoder's header. Whichever type a decoder constructs must check
  `stride * (length - 1)` against the buffer with checked arithmetic and return an
  `Expected`, and must not expose `assumeContiguous`-style escapes to `@safe` callers.
  Wrapping a mir `Slice` in such a type is possible; using it bare is not.
- **Q6, Q9: interop is easier than it looks, but not provided.** A `Universal` slice is
  one step from a `DLTensor` (element strides on both sides), and `connect/cpython`
  shows the error-code style for such a bridge. Neither DLPack nor a GPU staging layout
  exists in mir; both would be Sparkles code ([vulkan baseline][bl-vulkan]).
- **Q9: the dependency has a build-mode cost.** mir-core's betterC claim held under LDC
  and DMD for the tested pipeline. For `wasm32-unknown-unknown`, `Slice` code builds only
  when mir's own modules are not compiled: `dub build` and `ldc2 -i` fail on
  `mir.internal.memory`'s static assert, so a browser build must compile the program's
  modules alone against mir's sources, as the experiment did. mir-algorithm's CI tests
  neither betterC nor wasm nor Android. A Sparkles image core that must build for the
  browser through dub would need an upstream fix to `mir.internal.memory`, a fork, or its
  own view type. The
  dependency also brings `mir-core` and Apache-2.0 licensing, and the pin lags upstream
  by nine months: the dub and Nix locks would need to follow upstream releases.
- **Q2: no pixel or colour vocabulary to adopt.** mir supplies the array, not the image:
  channel order, alpha state and colour encoding must come from Sparkles, as a runtime
  descriptor or as element types ([existing code, open question 3][bl-existing-q]).

## Strengths

- One mature, documented type covers 1-D rows, 2-D images, 3-D channel stacks and 4-D
  clips, with contiguity in the type and every view operation free of copies.
- A large, composable selector library (`windows`, `blocks`, `pack`, `zip`, `map`,
  `bitwise`, `bytegroup`, `transposed`, `reversed`) that already covers neighbourhood
  and tiled image access.
- Allocation is separated from views and offers GC, allocator, C runtime and
  reference-counted storage.
- The core works in `@safe pure nothrow @nogc` code with `dip1000`, and under `-betterC`
  on LDC and DMD (verified).
- `size_t` lengths, signed `ptrdiff_t` element strides and C/C++ and Python-buffer
  interop are already worked out.
- Maintained: a push on November 6, 2026, and a newer tag (`v3.22.5`) than the pin.

## Weaknesses

- Bounds and size checks are `assert`s; length products and byte sizes overflow
  silently; strides are never validated against storage; `assumeContiguous` infers
  `@safe` (all verified).
- `@trusted` covers whole templated indexing functions, against Sparkles' rule.
- Element strides cannot express pitches that are not a multiple of the element size.
- No per-row alignment in allocation, no `Expected` errors, no move-only owner.
- No parallel loops, no explicit SIMD, no GPU path, no DLPack.
- A `wasm32-unknown-unknown` build fails whenever mir-core's modules are compiled, as
  `dub build` always does; only a compile of the program's own modules against mir's
  sources works (verified). CI covers none of betterC, wasm, Android or `dip1000`.
- Multi-plane formats with independent pitches need a type above `Slice`.
- The C++ header's strided `mir_slice` declares zero-length `_lengths` (read, not
  compiled).

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                                        | Trade-off                                                                                      |
| ------------------------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Contiguity (`SliceKind`) as a template parameter  | loops specialise at compile time; `Contiguous` stores no strides                 | three instantiations of every algorithm; views silently weaken the kind to `Universal`         |
| Strides in elements, signed                       | indexing is `iterator[sum(i * s)]`; negative strides give free reversal          | pitches that are not a multiple of the element size are unrepresentable                        |
| Generic over any `isIterator` type                | lazy views (`map`, `zip`, `bitwise`) are just iterators; sub-byte data fits      | invariants live in each iterator; a slice over a custom iterator is as safe as that iterator   |
| Views never allocate; allocation in one module    | ownership is the iterator's; the same view code serves GC, malloc and RC storage | a borrowed `T*` slice carries no ownership, so freeing is the caller's bookkeeping             |
| Public fields and literal constructor             | zero-cost construction from any source (Python buffers, C++)                     | no constructor can enforce stride against extent; `@safe` code can build an out-of-bounds view |
| Bounds checks by `assert`                         | free in `-release`, informative in debug                                         | gone in `-release` even with `-boundscheck=on`; no recoverable error for hostile input         |
| `@fmamath` (`contract`) on `Slice`                | lets LDC fuse multiply-adds in element-wise maths                                | float results differ from a non-contracted reference                                           |
| `zip` requires equal strides for N greater than 1 | one stride set serves every zipped iterator                                      | planes of different pitch cannot be zipped; multi-plane images need a separate type            |
| Reference counting through a `malloc`ed header    | GC-free shared ownership, usable from C++ and betterC                            | no allocator parameter, no alignment control, allocation failure is an `Error`                 |

## Sources

- [libmir/mir-algorithm][repo] at `2da212382e434ef86e93f7b028bc2309205ae00e`; [libmir/mir-core][core-repo] at `4397b03a804b0368100e99252016c7b32aa562d1`
- [mir-algorithm API documentation][docs]; [`mir.ndslice.slice`][docs-slice]
- [`source/mir/ndslice/slice.d`: kinds, representation, `sliced`, indexing][slice-repr]
- [`source/mir/ndslice/topology.d`: selectors][topo-header]
- [`source/mir/ndslice/dynamic.d`: `transposed`, `reversed`][transposed]
- [`source/mir/ndslice/allocation.d`][alloc-header]
- [`source/mir/algorithm/iteration.d`][iter-header]
- [`source/mir/rc/context.d`][rc-context], [`source/mir/rc/array.d`][rc-array]
- [`source/mir/ndslice/connect/cpython.d`][cpython], [`include/mir/ndslice.h`][cpp-header]
- [mir-core `README.md`][core-readme], [`source/mir/internal/memory.d`][core-memory], [`source/mir/math/common.d`][core-fmamath]
- [DLPack `dlpack.h` at `94485e23519bc30e22a18397a9c8ff1ea6b2b81e`][dlpack-h]
- Neighbours: [lubeck][lubeck]; [dcompute][dcompute-repo] and its [research page][dcompute-research]
- Sparkles: [existing-code baseline][bl-existing], [shaders and SIMD baseline][bl-shaders], [Vulkan baseline][bl-vulkan], [generic image programming papers][p-generic], [the `Slice` experiment][slice-experiment], [catalog umbrella][umbrella]

<!-- References -->

[repo]: https://github.com/libmir/mir-algorithm
[core-repo]: https://github.com/libmir/mir-core
[docs]: http://mir-algorithm.libmir.org/
[docs-slice]: http://mir-algorithm.libmir.org/mir_ndslice_slice.html
[license]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/LICENSE
[dub-sdl]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/dub.sdl#L1-L60
[ci]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/.github/workflows/ci.yml
[compilers]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/.github/workflows/compilers.json
[slice-note]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L1-L6
[slice-kind]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L176-L208
[sliced]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L242-L271
[slice-repr]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L538-L667
[slice-struct]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L669-L772
[index-stride]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L781-L830
[slice-ctor-test]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L923-L941
[slice-ptr-rc]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L1210-L1223
[opindex]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L2173-L2194
[slice-alias]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L3412
[lengths-product]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/internal.d#L330-L336
[topo-header]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L1-L101
[assume-contiguous]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L428-L455
[pack]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L549-L567
[ipack]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L586-L620
[unpack]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L640-L673
[blocks]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L1093-L1140
[windows]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L1225-L1265
[stride]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L2196-L2222
[bitwise]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L2459-L2475
[bytegroup]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L2640-L2664
[map]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L2721-L2760
[as]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L3651-L3680
[zip]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L3916-L3967
[transposed]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/dynamic.d#L489-L560
[reversed]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/dynamic.d#L662-L720
[chunks]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/chunks.d#L1-L20
[alloc-header]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/allocation.d#L1-L45
[make-uninit]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/allocation.d#L640-L664
[stdc-uninit]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/allocation.d#L855-L876
[iter-header]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/algorithm/iteration.d#L1-L52
[check-shapes]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/algorithm/iteration.d#L595-L615
[reduce-impl]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/algorithm/iteration.d#L720-L732
[each-impl]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/algorithm/iteration.d#L975-L988
[each]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/algorithm/iteration.d#L1130-L1158
[rc-context]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/rc/context.d#L10-L19
[rc-create]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/rc/context.d#L105-L135
[rc-array]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/rc/array.d#L19-L25
[traits-iterator]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/traits.d#L225-L240
[field]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/field.d#L1-L20
[iterator]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/iterator.d#L1-L25
[cpython]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/connect/cpython.d#L44-L75
[cpp-header]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/include/mir/ndslice.h#L57-L92
[core-readme]: https://github.com/libmir/mir-core/blob/4397b03a804b0368100e99252016c7b32aa562d1/README.md#L8-L12
[core-memory]: https://github.com/libmir/mir-core/blob/4397b03a804b0368100e99252016c7b32aa562d1/source/mir/internal/memory.d#L128-L154
[core-fmamath]: https://github.com/libmir/mir-core/blob/4397b03a804b0368100e99252016c7b32aa562d1/source/mir/math/common.d#L28
[core-checkedint]: https://github.com/libmir/mir-core/blob/4397b03a804b0368100e99252016c7b32aa562d1/source/mir/checkedint.d#L1-L20
[core-qualifier]: https://github.com/libmir/mir-core/blob/4397b03a804b0368100e99252016c7b32aa562d1/source/mir/qualifier.d
[dlpack-h]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L266-L290
[lubeck]: https://github.com/kaleidicassociates/lubeck/blob/c226b9f6161f223cc573ec92ba22760382ffb95c/README.md
[dcompute-repo]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/README.md
[dcompute-research]: ../../shading-languages/dcompute.md
[dbi]: ../../../guidelines/design-by-introspection-01-guidelines.md
[fp-guideline]: ../../../guidelines/functional-declarative-programming-guidelines.md
[buffer-spec]: ../../../specs/base/buffer.md
[bl-existing]: ../baseline/existing-code.md
[bl-existing-g2]: ../baseline/existing-code.md#gaps-and-tensions
[bl-existing-cap]: ../baseline/existing-code.md#capability-table
[bl-existing-q]: ../baseline/existing-code.md#questions-for-the-design-grill
[bl-shaders]: ../baseline/shaders-simd.md
[bl-shaders-g4]: ../baseline/shaders-simd.md#gaps-and-tensions
[bl-shaders-g8]: ../baseline/shaders-simd.md#gaps-and-tensions
[bl-shaders-g10]: ../baseline/shaders-simd.md#gaps-and-tensions
[bl-vulkan]: ../baseline/vulkan.md
[p-generic]: ../papers/generic-image-programming.md
[p-generic-mir]: ../papers/generic-image-programming.md#mir-ndslice-documentation-slicekind
[p-generic-synth]: ../papers/generic-image-programming.md#thread-synthesis
[slice-experiment]: ./slice-experiment.md
[dim5]: #_5-hostile-input-and-safety
[agents-build]: ../../../guidelines/AGENTS.md#build-types-debug-to-test-checked-to-ship-never-release
[umbrella]: ../index.md
