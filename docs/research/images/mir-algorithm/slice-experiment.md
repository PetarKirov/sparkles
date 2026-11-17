# mir `Slice` as an image view: the experiment

A throwaway experiment that puts mir-algorithm's `Slice!(Rgba8*, 2)` and its siblings under the image algorithms Sparkles will need, to collect evidence on whether `Slice` plus [`sparkles:math`][math-docs] fits, or whether Sparkles needs its own N-D view type.

| Field          | Value                                                                                                                            |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Subject        | `mir.ndslice` (`mir-algorithm`) with `mir-core`, against `sparkles.math.Vector` and `sparkles.base.buffer`                       |
| Questions      | [Q1, Q2, Q3, Q7, Q8, Q9][umbrella-q] of the umbrella                                                                             |
| License        | Apache-2.0 (`mir-algorithm` [`dub.sdl`][mir-dub])                                                                                |
| Repository     | [libmir/mir-algorithm][mir-repo], [libmir/mir-core][core-repo]                                                                   |
| Revision read  | `mir-algorithm` `2da212382e434ef86e93f7b028bc2309205ae00e`; `mir-core` `4397b03a804b0368100e99252016c7b32aa562d1` (tag `v1.7.4`) |
| Revision built | `mir-algorithm` `3.22.4` and `mir-core` `1.7.4` from the dub registry (see [Setup](#setup))                                      |
| Compilers      | DMD 2.112.1; LDC 1.43.0 (frontend 2.113.0, LLVM 24); `ldc-android` 1.43.0 from `nix develop .#android`                           |
| Programs       | [`slice-views.d`][ex-views], [`slice-algorithms.d`][ex-algos], [`slice-planar.d`][ex-planar]                                     |
| Category       | Experiment (wave 1), D landscape                                                                                                 |
| Last reviewed  | November 7, 2026                                                                                                                 |

> [!IMPORTANT]
> This page records evidence; it makes no design decision. Every claim is marked
> as **verified** (compiled and run, in a scratch directory under `/tmp`, with the
> command and the result given) or **documented** (read in source or docs at the
> pinned revision). No performance number appears: none was measured.

## Overview

### What it solves

The [existing-code baseline][bl-existing] records the gap this experiment probes:
"No pixel view type" (G2), with pixels travelling as `const(ubyte)[]` plus a
`Size`, and a guideline that says the opposite of the code. The
[functional-programming guideline][fp-guide] tells authors:

> **Use `mir.ndslice` for any multidimensional data.** Don't flatten 2D/3D data into 1D arrays and manually compute indices.

The [shaders and SIMD baseline][bl-shaders] leaves the matching question open
(G10): "Whether `Vector` can be the element type of a larger view, and whether an
external N-D slice type fits, is untested." This page tests it.

### Design philosophy

`Slice` is a borrowed view. Its own documentation says so:

> With the exception of $(MREF mir,ndslice,allocation) module, no functions in this
> package move or copy data. The operations are only carried out on lengths, strides,
> and pointers.
>
> — [`mir/ndslice/slice.d`, lines 546-548][src-nocopy]

Contiguity is encoded in the type as a three-way `SliceKind`:

> ```d
> /// A slice has strides for all dimensions.
> universal,
> /// A slice has >=2 dimensions and row dimension is contiguous.
> canonical,
> /// A slice is a flat contiguous data without strides.
> contiguous,
> ```
>
> — [`mir/ndslice/slice.d`, lines 176-184][src-kind]

Safety is delegated to iterators, with bounds left to the library:

> Safety_note:
> User-defined iterators should care about their safety except bounds checks.
> Bounds are checked in ndslice code.
>
> — [`mir/ndslice/slice.d`, lines 4-6][src-safety]

## How it works

A `Slice!(Iterator, N, kind)` is lengths, strides and an iterator, all public
fields ([lines 747-771][src-structure]). A `Contiguous` slice stores no strides,
`Canonical` stores `N - 1` (the last is 1) and `Universal` stores `N`. Strides are
`ptrdiff_t` counts of **elements**, not bytes: the iterator is advanced by
`stride` positions. The struct begins with `@fmamath:` ([line 672][src-struct]),
so floating-point code in its members may be contracted to fused multiply-add.

Construction from a D array goes through `sliced`, which checks the product of the
lengths against the array with an `assert` and accepts an array **longer** than
the view:

```d
// mir/ndslice/slice.d, lines 242-256 (pinned revision)
auto sliced(size_t N, Iterator)(return scope Iterator iterator, size_t[N] lengths...)
    ...
        assert(lengthsProduct(_lengths) <= iterator.length,
            "array length should be greater or equal to the product of constructed ndslice lengths");
        auto ptr = iterator.length ? &iterator[0] : null;
        return Slice!(typeof(C.init[0])*, N)(_lengths, ptr);
```

Indexing is `@trusted`, and the bounds check is an `assert` in `indexStride`
([lines 781-800][src-indexstride], [lines 2173-2176][src-opindex]):

```d
// mir/ndslice/slice.d, lines 2173-2176
auto ref opIndex()(size_t[N] _indices...) return scope @trusted
{
    return _iterator[indexStride(_indices)];
}
```

The operations the experiment uses are all views: subslicing (`img[1 .. 3, 2 .. 5]`
turns `Contiguous` into `Canonical`), `transposed` ([`dynamic.d` line 555][src-transposed],
which returns `Universal`), `member!"r"` (field projection), `flattened`, lazy
`map!fun`, `vmap(callable)` ([`topology.d` line 3048][src-vmap]), `ndiota` (an index
grid) and `windows(3, 3)` ([`topology.d` lines 1237-1241][src-windows]), a slice of
overlapping 3x3 sub-slices. Assigning a lazy slice to `dst[]` evaluates it.
Ownership lives elsewhere, in [`mir.ndslice.allocation`][src-alloc]: GC (`slice`),
reference counting (`rcslice`), an allocator (`makeSlice`) or `malloc`
(`stdcUninitSlice`).

## Setup

- **Registry fetch.** `dub fetch mir-algorithm@3.22.4` reported "Existing package
  mir-algorithm@3.22.4 found locally": the user's dub cache already held both
  packages, so no network fetch happened in this session. `mir-core` resolved to
  `1.7.4` (the `mir-algorithm` recipe asks for `>=1.6.0`).
- **Registry versus pinned revision.** `cmp` shows `slice.d`, `topology.d` and
  `dynamic.d` in the cached `3.22.4` identical to tag `v3.22.4`
  (`ecde2eb4ff41dc9d9dc6f71234d0838dccce22b4`); `mir-core`'s `common.d` is identical
  to `v1.7.4`. The pinned revision is five commits past the tag; under `source/`
  they touch `bignum/fixed.d`, `parse.d` and, in `slice.d`, only the `immutable`
  overload of `lightScope` for labelled slices and its tests, which no example uses.
- **Runs.** Each program ran with
  `nix develop <repo> -c dub run --temp-build --compiler=<dmd|ldc2> [-b checked] --single <file>`
  and `TMPDIR` under `/tmp/slice-exp`. Scratch compile checks used the compilers
  directly with `-I` paths to the cached `mir-algorithm` and `mir-core` sources and
  to `libs/{base,math,metadata,reflection,test-runner}/src`.
- **Noise.** Every LDC build of `mir-core` prints, at `mir/math/common.d(129,12)` and
  `(144,16)` ([source][src-core-llvm]):

  ```text
  Deprecation: variable `ldc.intrinsics.LLVM_version` is deprecated - please use LLVM_major
  ```

## Results

### Views over one buffer

**Verified** by [`slice-views.d`][ex-views] under DMD and LDC, `debug` and
`checked`, identical output. One 96-byte buffer is a `Slice!(Rgba8*, 2)` (via
`cast(Rgba8[]) bytes`, which is `@safe` because neither type has indirections) and a
`Slice!(ubyte*, 3)` at once. The crop is `Canonical`, the transpose `Universal`, a
channel `img3[0 .. $, 0 .. $, 3]` is a `Universal` 2-D slice with a 4-byte column
stride, and `static assert`s pin each type. One generic `redSum` runs on all three
kinds. Writing `crop[] = Rgba8(1, 2, 3, 4)` changes the owner's bytes:

```text
img   lengths [4, 6], img3 lengths [4, 6, 4]
img[2, 3]  = Rgba8(120, 120, 15, 195)
img3[2, 3] = [120, 120, 15, 195]
fnv1a(img3) = 0f340315
crop  lengths [2, 3] strides [6, 1]
tr    lengths [6, 4] strides [1, 6]
tr[3, 2] == img[2, 3]: true
redSum img 2400 crop 720 tr 2400
after crop[] = (1,2,3,4): bytes[32 .. 36] = [1, 2, 3, 4]
fnv1a(img3) = 45f4e90f
crop3 lengths [2, 3, 4] strides [24, 4, 1] fnv1a 68970295
alpha lengths [4, 6] strides [24, 4] row 0 [255, 235, 215, 195, 175, 155]
```

A crop of the pixel view cannot be re-viewed as bytes by an array cast (it is not one
array); the byte crop comes from slicing the 3-D view the same way.

### Borrowing a `UniqueBuffer`

**Verified.** The storage in [`slice-views.d`][ex-views] is a
`UniqueBuffer!(ubyte, 64)`; `storage[]` is `return scope`
([`buffer.d`][src-buffer]) and the slice of it feeds `sliced`. `fill`, a
non-template `Slice!(Rgba8*, 2) -> void` function, is `@safe pure nothrow @nogc`
and compiles under both compilers. The borrow, however, is not checked by dip1000:

- Returning `a[].sliced(4, 4)` over a local `int[16]` is rejected by both compilers
  under `-preview=dip1000`, so `sliced` (both overloads, the 1-D one included)
  propagates `scope`:

  ```text
  escape.d(16): Error: escaping a reference to local variable `a` by returning `sliced(a[], [4LU, 4LU])`  is not allowed in a `@safe` function
  ```

- Returning `storage[].sliced(4, 4)` over a local `UniqueBuffer!(ubyte, 64)`, or
  `storage[]` itself, compiles in `@safe` code under `-preview=dip1000` on both
  compilers. The same over `InlineBuffer!(ubyte, 64)` is rejected ("returning
  `storage.opSlice()` escapes a reference to local variable `storage`"), and over
  `HeapBuffer!(ubyte, Storage.unique)` it compiles. With 16 bytes the
  `UniqueBuffer` is inline-resident, so the escaped view points into a dead stack
  frame. Built with `ldc2 -fsanitize=address` and run with
  `ASAN_OPTIONS=detect_stack_use_after_return=1`:

  ```text
  ==320732==ERROR: AddressSanitizer: stack-use-after-return on address 0x7bfff5cf0037 at pc 0x55555557bc85 bp 0x7ffffffe52f0 sp 0x7ffffffe52e8
  READ of size 1 at 0x7bfff5cf0037 thread T0
  ```

- Declaring the owner `scope UniqueBuffer!(ubyte, 64) storage;` makes the escape an
  error, but then the owner cannot grow:

  ```text
  escape3.d(7): Error: scope variable `storage` calling non-scope member function `Buffer.length()` is not allowed in a `@safe` function
  ```

The hole is in how dip1000 treats a non-`scope` local whose type has indirections,
not in mir: a plain `ubyte[]` escapes the same way. `UniqueBuffer!(ubyte, 0)` is
rejected outright ("N must be greater than 0 for a policy with Storage.inline",
[`buffer.d` line 359][src-buffer]), so [`slice-planar.d`][ex-planar] owns its frame
with `HeapBuffer!(ubyte, Storage.unique)`.

### Per-pixel map

**Verified** by [`slice-algorithms.d`][ex-algos]. `premultiplyInto` is the whole
straight-to-premultiplied conversion, a non-template `@safe pure nothrow @nogc`
function:

```d
void premultiplyInto(Slice!(const(Rgba8)*, 2) src, Slice!(Rgba8*, 2) dst) @safe pure nothrow @nogc
{
    dst[] = src.map!premultiply;
}
```

A mutable `Slice!(Rgba8*, 2)` converts implicitly to the `const(Rgba8)*` parameter.
The result (`(v * a + 127) / 255` per channel) matches the `Vector` form below byte
for byte.

### Box blur over windows

**Verified.** `src.windows(3, 3).map!(w => boxMean(w))` assigned to
`dst[1 .. $ - 1, 1 .. $ - 1]` writes the interior; the border is copied first. A
second form over one 8-bit plane, hand-written loops over `src[y].field` rows,
agrees with the `windows` form, and the plane blur of the red channel agrees with
the red channel of the RGBA blur:

```text
source         fnv1a 3682d025  img[1, 2] Rgba8(201, 4, 63, 122)  imgV[1, 2] [201, 4, 63, 122]
premultiplied  fnv1a 0ae40454  struct == Vector: true  pm[1, 2] Rgba8(96, 2, 30, 122)
box blur       fnv1a a3ef49b0  struct == Vector: true  bl[2, 3] Rgba8(135, 80, 139, 141)
plane blur     fnv1a 8e845479  windows == loop: true  red-channel of RGBA blur agrees: true
```

The output is identical under DMD and LDC, `debug` and `checked`.

### `sparkles.math` `Vector` as the pixel

**Verified.** `Vector!(ubyte, 4)` (packed layout, 4 bytes) is a valid `Slice`
element type: `cast(Px[]) bytes` is `@safe`, `map`, `windows` and `flattened` work,
and the `rgb` swizzle and `+=` operate on the elements. Two frictions, both in
`sparkles.math`, not in mir:

- `Vector` has no converting constructor between component types (only
  `this(V)(const V head, T last)`, [`vector.d` line 262][src-vector]), so widening a
  pixel to `Vector!(uint, 4)` for a premultiply or a blur accumulator is spelled per
  component: `Px32(p.x, p.y, p.z, p.w)`, and narrowing back likewise.
- The non-template `toHash` member ([`vector.d` lines 425-433][src-vector]) calls
  druntime's `hashOf`, so a DMD `-betterC` link of any program instantiating a
  `Vector` fails (see [Compile checks](#compile-checks)). LDC's link does not fail.

### Planar YUV and padded strides

**Verified** by [`slice-planar.d`][ex-planar]. A 9 x 5 frame has 5 x 3 chroma
planes, so the three planes have different extents; luma has a 16-byte row stride,
chroma 8. Each plane is `bytes.sliced(rows, stride)[0 .. $, 0 .. cols]`, a
`Canonical` slice, and the padding (`0xEE`) is never visited:

```text
Y lengths [5, 9] strides [16, 1]  U lengths [3, 5] strides [8, 1]  V lengths [3, 5] strides [8, 1]
fnv1a Y 4809210f U 1a0dbe07 V a1c41ff7  (padding not visited)
rgb[0, 0] Rgb8(106, 0, 0)  rgb[4, 8] Rgb8(35, 81, 194)
fnv1a rgb 722210be
rgbStride % Rgb8.sizeof = 2, so no Slice!(Rgb8*, 2) has this stride
packed 3-D lengths [5, 9, 3] strides [32, 3, 1]  px[4, 8] [35, 81, 194]
fnv1a packed 722210be == fnv1a rgb: true  row bytes fnv1a 722210be
padding byte packed[27] = 0xEE (untouched)
```

Three findings came out of writing it:

- **A lambda over the planes allocates.** `ndiota(h, w).map!((i) => ...yp[...]...)`
  inside a `@nogc` function is rejected by both compilers:

  ```text
  closure.d(4): Error: function `closure.convert` is `@nogc` yet allocates closure for `convert()` with the GC
  closure.d(7):        delegate `(ulong[2] i) => cast(ubyte)(cast(int)yp.opIndex([i[0], i[1]]) + cast(int)up.o...` closes over variable `yp`
  ```

  The program carries the planes in a struct with `opCall` and passes it to `vmap`
  instead, which is `@nogc`.

- **DMD and LDC disagree on that struct.** With an `opCall` member, `Yuv420(yp, up, vp)`
  compiles under LDC 1.43 but DMD 2.112.1 resolves it to `opCall`:

  ```text
  slice-planar.d(94,57): Error: function `opCall` is not callable using argument types `(Slice!(ubyte*, 2LU, mir_slice_kind.canonical), Slice!(ubyte*, 2LU, mir_slice_kind.canonical), Slice!(ubyte*, 2LU, mir_slice_kind.canonical))`
  ```

  A struct initialiser (`Yuv420 f = {yp: yp, up: up, vp: vp};`) compiles on both. The
  difference is in the frontends, not mir: a two-field struct with a one-argument
  non-static `opCall`, constructed as `S(1, 2)`, fails the same way under DMD 2.112.1
  ("expected 1 argument(s), not 2") and compiles under LDC 1.43. Whether the 2.113
  frontend changed this on purpose was not checked.

- **A byte pitch that is not a whole number of pixels has no pixel-typed `Slice`.**
  Packed RGB, 9 pixels (27 bytes) a row padded to 32, would need a stride of 10 2/3
  `Rgb8`s. The bytes are a `Canonical` 2-D slice; a pixel-shaped 3-D byte view
  `[5, 9, 3]` with strides `[32, 3, 1]` is a `Universal` slice built from a struct
  literal of the public fields, which the program wraps in `@trusted` only because it
  passes `packed.ptr`.

### Safety of the view

**Verified** with a scratch program in `@safe` code under `-preview=dip1000`, a
64-byte GC array `big` and a 4-byte borrow `small = big[0 .. 4]`:

| Construct                                                         | `debug` (asserts live)         | `-release`                     |
| ----------------------------------------------------------------- | ------------------------------ | ------------------------------ |
| `Slice!(ubyte*, 2, Universal)([8, 8], [8, 1], &small[0])[7, 7]`   | returns `63`, byte 63 of `big` | same                           |
| `auto s = small.sliced(2, 2); s._lengths[] = 8; s[7, 7]`          | returns `63`                   | same                           |
| `small.sliced(2, 2)[i - 2, 1]` with run-time `i = 4` (row 2 of 2) | `AssertError` (message below)  | returns `5`, past the 2x2 view |

```text
core.exception.AssertError@.../mir/ndslice/slice.d(794): 2D slice of ubyte: bounds check failed at 0 + 1 dimension
```

The first two rows compile in `@safe` code because the fields are public and the
struct literal takes `&small[0]`, which dip1000 allows. The third shows the bounds
check is an `assert` behind a `@trusted` `opIndex`: it follows the assertion
setting, not `-boundscheck`. Sparkles' `checked` build type keeps assertions, so the
check survives there; `-checkaction=halt` turns it into a trap.

## Compile checks

All three programs and the scratch kernels. "Pass" means compiled and, where a
binary or module was produced, ran with the expected output.

| Check                                                                                                             | DMD 2.112.1                                          | LDC 1.43.0                                                |
| ----------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- | --------------------------------------------------------- |
| Default flags (`-o-`, no previews), three programs                                                                | pass                                                 | pass                                                      |
| `-preview=in -preview=dip1000` (the recipes' `dflags`), `dub run`, `debug` and `checked`                          | pass, identical output                               | pass, identical output (plus the `mir-core` deprecations) |
| Sparkles unittest flags (`-unittest -checkaction=context -allinst` with the previews), `-o-`                      | pass                                                 | pass                                                      |
| Non-template `@safe pure nothrow @nogc` kernels (`fill`, `premultiplyInto`, `boxBlurInto`, `convert`…)            | pass                                                 | pass                                                      |
| `-betterC`, kernels plus `transposed`, `windows`, `vmap` over static arrays, run natively                         | link fails with `Vector`; pass (exit 106) without it | pass (exit 9)                                             |
| `-mtriple=wasm32-unknown-unknown-wasm -betterC`, only the kernel module compiled (`-I` to mir), run under Node.js | not applicable                                       | pass after two workarounds; `run()` returns 9 and 106     |
| The same target with mir's modules compiled too (`ldc2 -i`, or `dub build`)                                       | not applicable                                       | fails: `mir/internal/memory.d(154)` static assert (below) |
| Android `aarch64--linux-android`, `.#android` shell, the repo's raw `ldc2 -i` recipe                              | not applicable                                       | pass: three PIE executables; not run (no device attached) |
| Android through `dub build --arch=aarch64--linux-android`                                                         | not applicable                                       | compiles every module; link fails (below)                 |

Failures, verbatim:

- **DMD `-betterC` with `Vector`.** The unresolved symbols come from `Vector.toHash`:

  ```text
  Error: undefined reference to `core.internal.hash._bytesHashUnaligned(scope const(ubyte)[], ulong)`
         referenced from `const pure nothrow @nogc @safe ulong sparkles.math.vector.Vector!(ubyte, 4uL, 0, ["x", "y", "z", "w"]).Vector.toHash()`
  Error: undefined reference to `core.internal.convert.ctfe_alloc(ulong)`
         the `-betterC` flag prevents linking with druntime
  ```

- **wasm32, first attempt.** The import chain fails on druntime's
  `core/stdc/time.d(23)`: `Error: static assert:  "unsupported system"`. Bisection
  traced it to the array cast `cast(Rgba8[]) bytes[]`, whose druntime hook
  (`core.internal.array.casting`) imports `core.memory`, which reaches `core.time`
  and `core.stdc.time`. The cast alone, with no mir import, fails the same way;
  `sliced`, `map`, `windows`, `flattened`, `vmap`, `ndiota` and `transposed` compile
  for wasm32 on their own. The workaround is a `@trusted` pointer-cast `reinterpret!T`.
- **wasm32, link.** `-link-internally -L--no-entry -L--export-dynamic` (the
  Sparkles test runner's `--wasm` flags) then reports `lld: error: bc.o: undefined
symbol: __assert`; a trapping `extern (C) void __assert(...)`, as the
  test runner's generated program defines, resolves it. The modules (57 113 bytes
  with `Vector`, 27 396 without) have no imports.
- **wasm32, mir's own modules.** All of the above compiles only the kernel module, with
  `-I` paths to mir's sources, so mir's templates are instantiated there and nothing
  else of mir is analysed. Compiling mir's modules too fails on `mir-core`'s
  module-level `else static assert(0);`, which accepts only `Posix` and `Windows`
  ([`memory.d`][src-core-memory]): `mir.ndslice.slice` imports `mir.rc.array`, whose
  `mir.rc.context` imports `mir.internal.memory` inside `mir_rc_create`. A rerun with
  `sliced` plus `reduce` over a `Canonical` view showed both sides: `ldc2 -c` with `-I`
  compiles, links and runs (no imports), while `ldc2 -i` and
  `dub build --arch=wasm32-unknown-unknown-wasm` (which builds `mir-core` as a library
  first) stop at the static assert on `memory.d` line 154. The
  [deep-dive][deep-dive] records the same.
- **Android through dub.** The link step of the cross build:

  ```text
  ld.lld: error: undefined symbol: __tls_get_addr
  >>> referenced by sections_elf_shared.d
  ```

  The repository's own recipes do not use dub for this ("dub cannot drive a cross
  build", [`build-d-android-lib.nix`][nix-android-lib]) and link with
  `-link-defaultlib-shared=false -L-pie ... -L-Wl,--warn-unresolved-symbols`
  ([`build-d-android-tests.nix`][nix-android-tests]); bionic exports
  `__tls_get_addr` from API 29 ([`min-sdk.nix`][nix-min-sdk]). With that recipe all
  three programs link to `ELF 64-bit LSB pie executable, ARM aarch64`.

## Generated code

**Verified** by reading `ldc2 -O3 -output-s` for three forms of the one-plane 3x3
blur, x86-64 baseline CPU unless stated, under `-preview=in -preview=dip1000`. dub's
`checked` build type passes `-O3 -enable-inlining` to LDC with assertions live, so
`-O3` alone is the `checked` configuration. `blurPlaneMir` and `blurPlaneLoop` are copied verbatim from
[`slice-algorithms.d`][ex-algos] into a scratch module; `blurPlaneMirIndexed` exists
only there. "Vectorised" means a loop over 8-bit
pixels widened to 16-bit lanes (`punpcklbw`/`vpmovzxbw`, `paddw`, `pmulhuw` for the
divide by 9, `packuswb`).

| Kernel                                                         | `-O3` (= `checked`)                                       | `-O3 -checkaction=halt` | `-O3 --enable-asserts=false` | `-O3 -release` | `-O3 -boundscheck=off` | `-O3 -mcpu=x86-64-v3 -release -boundscheck=off` |
| -------------------------------------------------------------- | --------------------------------------------------------- | ----------------------- | ---------------------------- | -------------- | ---------------------- | ----------------------------------------------- |
| `blurPlaneLoop` (rows as `src[y].field`, hand-indexed)         | vectorised (SSE2)                                         | vectorised              | vectorised                   | vectorised     | vectorised             | vectorised (AVX2, `ymm`)                        |
| `blurPlaneMir` (`windows(3, 3).map!` with `flattened` sum)     | **not vectorised**: scalar, out-of-line assignment helper | vectorised              | vectorised                   | vectorised     | not vectorised         | vectorised (AVX2, 27 `vpmovzxbw`)               |
| `blurPlaneMirIndexed` (`windows` with `w[0, 0] + … + w[2, 2]`) | not vectorised                                            | **not vectorised**      | vectorised                   | vectorised     | not vectorised         | vectorised (AVX2)                               |

In the `checked` configuration the `windows` assignment is an out-of-line
`opIndexOpAssignImplSlice` instance with calls to `_d_assert_msg` and `_d_assert`,
and its inner loop walks the 9 window elements one byte at a time (`movzbl`, `addl`,
`cmovbq` for the `flattened` iterator), then divides by 9 with `imulq $954437177`.
The hand loop keeps its `_d_arraybounds_index` and `_d_assert_msg` calls on failure
branches and still vectorises. With assertions compiled out (`--enable-asserts=false`
or `-release`) all three forms compile to the same widened loop. `-checkaction=halt`
is not enough on its own: the `flattened` form vectorises, but the indexed form stays
an out-of-line scalar helper (nine `movzbl` loads per pixel), so the outcome there
depends on inlining. Turning off array bounds checks alone does not help either: the
blocking checks are mir's `assert`s, not D array bounds.

The `Vector!(ubyte, 4)` RGBA blur (`boxBlurVecInto`, `-O3 -checkaction=halt`) holds one
pixel's four channels in one `xmm` register and adds window elements with `paddd`;
it is vectorised across channels, not across pixels.

## Conclusion: the evidence

### For "`Slice` fits"

- The three `SliceKind`s are the image cases: `Contiguous` for a tight image,
  `Canonical` for padded rows and crops, `Universal` for transposes and single
  channels. Crops, transposes, channel views and planes are views, with the kind
  checked by `static assert` (verified, [Views](#views-over-one-buffer)). **Q1**
- Pixel structs and `sparkles.math` `Vector` both work as element types, and kernels
  written as non-template `@safe pure nothrow @nogc` functions over `Slice`
  parameters compile on DMD and LDC with dip1000 and Sparkles' unittest flags
  (verified). **Q2**
- `map`, `vmap`, `windows`, `ndiota` and `flattened` compose lazily into
  `dst[] = ...` assignments that agree with hand loops byte for byte (verified). **Q3**
- Planar 4:2:0 with different plane extents and padded strides is three
  `Canonical` slices over one owner (verified, [Planar](#planar-yuv-and-padded-strides)). **Q1**
- The kernels build for `-betterC` (LDC; DMD without `Vector`), run as wasm32
  modules with no imports when only the kernel module is compiled against mir's
  sources, and link for Android aarch64 with the repository's recipe (verified,
  [Compile checks](#compile-checks)). **Q9**
- With assertions compiled out the `windows` blur vectorises like the hand loop,
  including AVX2 under `-mcpu=x86-64-v3`, and with `-checkaction=halt` the
  `flattened` form does too (verified). AGENTS.md already names
  `-checkaction=halt` as the per-package remedy "for a hot path where assertions
  really cost". **Q7**
- The repository is active: GitHub reports `archived: false` for both
  repositories, and the pinned revision is from February 4, 2026. The docs site
  title "Libmir Archive" is the site's name, not an archival state; the
  [paper thread][p-generic] has been corrected to say so. **Q9**

### For "own view type"

- Strides count elements, so a byte pitch that is not a multiple of the pixel size
  has no pixel-typed `Slice`; packed RGB with padded rows becomes a 3-D byte slice
  built by hand in `@trusted` code (verified). **Q1**
- `@safe` code can construct or widen a `Slice` past the memory it borrows, because
  lengths, strides and the iterator are public fields; and bounds checks are
  `assert`s inside `@trusted` indexing, gone in a `-release` build (verified,
  [Safety](#safety-of-the-view)). A view fed by hostile headers depends on the
  constructor checking the extents. **Q8**
- `Slice` has no owner. Over a `UniqueBuffer`, dip1000 does not stop a view
  outliving its owner, and ASan caught the resulting stack-use-after-return in
  `@safe` code (verified). A Sparkles-owned type could tie view lifetime to the
  owner; mir's `rcslice` is a different, reference-counted answer. **Q1**, **Q9**
- In the shipping `checked` configuration (assertions live), the idiomatic
  `windows` blur is scalar while the hand-written row loop vectorises; under
  `-checkaction=halt` one of the two `windows` forms is still scalar (verified).
  **Q3**, **Q7**
- Lambdas that read other planes allocate closures, so `@nogc` code must use
  `vmap` with a functor (verified); and that functor exposed a DMD/LDC difference
  in struct construction syntax (verified). **Q2**
- `Slice` carries no pixel format, alpha state, transfer function or primaries;
  the [existing-code baseline][bl-existing]'s open decisions 2 and 3 need a runtime
  descriptor beside the view whichever view type is chosen (documented). **Q5**
- `@fmamath` on the `Slice` struct permits FMA contraction in its members'
  floating-point code (documented, [line 672][src-struct]), against the exactness the
  [shaders baseline][bl-shaders] (G8) asks of an 8-bit conformance oracle. Not tested
  here. **Q8**
- Dependency cost: `mir-core 1.7.4` emits deprecations under LDC 1.43; the registry
  tag lags the pinned revision; neither package is in `nix/dub-lock.json` or
  `nix/ci-dub-lock.json`; and wasm32 needed workarounds for druntime's array cast and
  `__assert`, and builds only when mir's own modules are not compiled, so not through
  dub (verified). **Q9**

## What CI needs to run the examples

Nothing below was changed; this is the list for whoever wires the examples in.

1. Add `docs/research/images/mir-algorithm/examples/*.d` to the `ci examples standalone`
   defaults in `apps/ci/src/app.d` (the list near line 1300, the option help text and
   the module DDoc).
2. Add `mir-algorithm` `3.22.4` and `mir-core` `1.7.4` to `nix/ci-dub-lock.json`
   (example-only dependencies), so `ci examples standalone` resolves them offline.
3. `git add --chmod=+x` the three programs (shebang files).
4. Register this page in `docs/.vitepress/sidebar.json`; the `.d` links already pass
   through the `/\.d$/` `ignoreDeadLinks` rule.
5. Decide whether the LDC `LLVM_version` deprecations from `mir-core` are acceptable
   in example output (`ci` runs with `--quiet`, so a successful build does not print
   them).

## Sources

- `mir-algorithm` at `2da212382e434ef86e93f7b028bc2309205ae00e`:
  [`source/mir/ndslice/slice.d`][src-slice], [`topology.d`][src-topology],
  [`dynamic.d`][src-transposed], [`allocation.d`][src-alloc], [`dub.sdl`][mir-dub].
- `mir-core` at `4397b03a804b0368100e99252016c7b32aa562d1`:
  [`source/mir/math/common.d`][src-core-llvm].
- Sparkles: [`sparkles.math` docs][math-docs] and [specification][math-spec],
  [`vector.d`][src-vector], [`buffer.d`][src-buffer] and the
  [buffer specification][buffer-spec]; the [Android cross-build notes][android-wsi]
  and the [`nix/packages/android`][nix-android-lib] recipes.
- Baselines: [existing code][bl-existing], [shaders and SIMD][bl-shaders]; paper
  thread: [generic image programming][p-generic].
- The three programs: [`slice-views.d`][ex-views], [`slice-algorithms.d`][ex-algos],
  [`slice-planar.d`][ex-planar].

<!-- References -->

[umbrella-q]: ../index.md#questions-this-survey-answers
[bl-existing]: ../baseline/existing-code.md
[bl-shaders]: ../baseline/shaders-simd.md
[p-generic]: ../papers/generic-image-programming.md
[fp-guide]: ../../../guidelines/functional-declarative-programming-guidelines.md
[math-docs]: ../../../libs/math/index.md
[math-spec]: ../../../specs/math/SPEC.md
[buffer-spec]: ../../../specs/base/buffer.md
[android-wsi]: ../../window-system-integration/os-apis/android/index.md#building-and-cross-compiling
[ex-views]: ./examples/slice-views.d
[ex-algos]: ./examples/slice-algorithms.d
[ex-planar]: ./examples/slice-planar.d
[src-vector]: ../../../../libs/math/src/sparkles/math/vector.d
[src-buffer]: ../../../../libs/base/src/sparkles/base/buffer.d
[nix-android-lib]: ../../../../nix/packages/android/build-d-android-lib.nix
[nix-android-tests]: ../../../../nix/packages/android/build-d-android-tests.nix
[nix-min-sdk]: ../../../../nix/packages/android/min-sdk.nix
[mir-repo]: https://github.com/libmir/mir-algorithm
[core-repo]: https://github.com/libmir/mir-core
[mir-dub]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/dub.sdl#L1-L10
[src-slice]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d
[src-safety]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L4-L6
[src-kind]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L176-L186
[src-nocopy]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L540-L549
[src-struct]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L669-L672
[src-structure]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L747-L771
[src-indexstride]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L781-L800
[src-opindex]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/slice.d#L2173-L2176
[src-topology]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d
[src-windows]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L1237-L1241
[src-vmap]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/topology.d#L3048-L3058
[src-transposed]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/dynamic.d#L555-L558
[src-alloc]: https://github.com/libmir/mir-algorithm/blob/2da212382e434ef86e93f7b028bc2309205ae00e/source/mir/ndslice/allocation.d#L1-L45
[src-core-llvm]: https://github.com/libmir/mir-core/blob/4397b03a804b0368100e99252016c7b32aa562d1/source/mir/math/common.d#L127-L146
[src-core-memory]: https://github.com/libmir/mir-core/blob/4397b03a804b0368100e99252016c7b32aa562d1/source/mir/internal/memory.d#L128-L154
[deep-dive]: ./index.md#_10-testing-and-conformance
