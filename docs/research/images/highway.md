# Highway (C++)

A C++17 library of length-agnostic SIMD operations that compiles one kernel source
once per instruction set and picks the best compiled variant at run time; the SIMD
layer under libjxl and libvips, and the main candidate model for SIMD dispatch in a
D image library.

| Field         | Value                                                                                                            |
| ------------- | ---------------------------------------------------------------------------------------------------------------- |
| Language      | C++17, header-mostly, plus a small runtime library (`targets.cc`, `per_target.cc`, `abort.cc`)                   |
| License       | Apache-2.0 or BSD-3-Clause, at the user's choice ([`LICENSE`][license])                                          |
| Repository    | [google/highway][repo]                                                                                           |
| Revision read | `872f22991f11a09c4a3633935cb26bdd1977541a` (October 27, 2026; [`CMakeLists.txt`][cmake] project version `1.4.0`) |
| Documentation | [google.github.io/highway][docs]; [`g3doc/quick_reference.md`][qref], [`g3doc/design_philosophy.md`][philosophy] |
| Category      | GPU and SIMD                                                                                                     |
| Tier          | A                                                                                                                |
| Last reviewed | November 7, 2026                                                                                                 |

> [!NOTE]
> Highway is not an image library. It is here because [libjxl][libjxl-simd],
> [libvips][libvips-simd] and (disabled by default) [OpenImageIO][oiio-simd] build on
> it, and because it answers the question the [SIMD baseline][bl-shaders-gaps] leaves
> open: how one kernel source becomes per-target kernels selected at run time.
> **Verified** means run under `/tmp`: a Highway program (Clang 21.1.7, pinned source)
> on every supported target of an AMD Ryzen 9 7940HX (Zen 4), and the same shape in D
> (LDC 1.41.0, LLVM 18.1.8). Everything else is read from source or documentation.

---

## Overview

### What it solves

Explicit SIMD has three costs: each instruction set has its own intrinsics; a binary
built for the best ISA crashes on older CPUs, while one built for the oldest wastes
the hardware; and scalable ISAs (Arm SVE, RISC-V V) have no compile-time vector
length. Highway answers with one API of free functions ("ops") overloaded on a
zero-sized type tag, a preprocessor driver that compiles a translation unit once per
target in distinct namespaces, and a dispatch table indexed by a CPU-detection
bitmask. The README states the deployment goal
([`README.md`][readme-deploy]):

> _"Applications using Highway can run on heterogeneous clouds or client devices,
> choosing the best available instruction set at runtime. Alternatively, developers
> may choose to target a single instruction set without any runtime overhead. In
> both cases, the application code is the same except for swapping
> `HWY_STATIC_DISPATCH` with `HWY_DYNAMIC_DISPATCH` plus one line of code."_

### Design philosophy

The design document names image and video codecs as the reason dynamic dispatch is
required ([`design_philosophy.md`][philosophy-dispatch]):

> _"Modules such as image or video codecs are typically embedded into larger
> applications such as browsers, so they cannot require separate binaries for each
> CPU. Libraries also cannot predict whether the application already uses AVX2 (and
> pays the frequency throttling cost), so this decision must be left to the
> application. … To reduce overhead, dispatch should be hoisted to higher layers
> instead of checking inside every low-level function. … We generate all code paths
> from the same source to reduce implementation- and debugging cost."_

Three further principles shape the API. Operations are free functions, not methods,
because "the Arm SVE vector type is sizeless and cannot be wrapped in a class"
([`design_philosophy.md`][philosophy-overload]). The op set omits "inefficient or
non-performance-portable operations such as `hmax`, `operator[]`"
([`design_philosophy.md`][philosophy-omit]), so that "operation costs are visible,
predictable and minimal" ([`design_philosophy.md`][philosophy-width]).
And width-agnostic code is preferred because it "will result in better code when
vector sizes increase". The stated target is "performance within 10-20% of a
hand-written assembly implementation"; that figure is the authors', not measured here.

---

## How it works

### Descriptors: `Simd`, `ScalableTag`, `CappedTag`, `FixedTag`

Every op that creates or loads a vector takes a descriptor `d`, a zero-sized value
of type `Simd<T, N, kPow2>` ([`shared-inl.h`][shared-simd]):

```cpp
// hwy/ops/shared-inl.h (excerpt)
// Highway operations are implemented as overloaded functions selected using a
// zero-sized tag type D := Simd<T, N, kPow2>. T denotes the lane type.
// ...
// Instead of referring to Simd<> directly, users create D via aliases:
// - ScalableTag<T> for a full vector;
// - ScalableTag<T, kPow2>() for a fraction/group, ...
// - CappedTag<T, kLimit> for a vector with up to kLimit lanes; or
// - FixedTag<T, kNumLanes> for a vector with exactly kNumLanes lanes.
//
// Instead of N, use Lanes(D()) for the actual number of lanes at runtime and
// D().MaxLanes() for a constexpr upper bound. Both are powers of two.
```

`CappedTag` and `FixedTag` serve narrow data such as an 8x8 block
([`shared-inl.h`][shared-tags]); `kPow2` selects the register-group multiplier `LMUL`
on RVV. Type-changing ops take a rebound tag: `Rebind<uint8_t, decltype(df)>` has the
lane count of `df` with `uint8_t` lanes, so a `u8` to `f32` conversion stays
width-agnostic.

On fixed-width targets `Lanes(d)` is a constant. On SVE it reads the hardware
([`arm_sve-inl.h`][sve-lanes]):

```cpp
// hwy/ops/arm_sve-inl.h
template <typename T, size_t N, int kPow2>
HWY_API size_t Lanes(Simd<T, N, kPow2> d) {
  const size_t actual = detail::AllHardwareLanes<T>();
  constexpr size_t kMaxLanes = MaxLanes(d);
  constexpr int kClampedPow2 = HWY_MIN(kPow2, 0);
  // Common case of full vectors: avoid any extra instructions.
  if (detail::IsFull(d)) return actual;
  return HWY_MIN(detail::ScaleByPower(actual, kClampedPow2), kMaxLanes);
}
```

The vector type is unspecified (`Vec<D>`, or `auto`). On x86 it is a class wrapping
the intrinsic type (`Vec256<float>` holds a `__m256`, [`x86_256-inl.h`][vec256]); on
SVE and RVV it is the compiler's sizeless built-in, and the reference lists the
consequences ([`quick_reference.md`][qref-sizeless]): vectors must not be used in
"arrays/STL containers …, class members, static/thread_local variables,
new-expressions … and sizeof/pointer arithmetic". The lane count is guaranteed to be
a power of two even on SVE, so remainders are `count & (Lanes(d) - 1)`
([`quick_reference.md`][qref-lanes]).

### The op set

The quick reference ([`quick_reference.md`][qref], 3,364 lines) covers arithmetic
(masked, saturating, widening), shifts, rounding, logic, masks (`Compress`,
`Expand`), comparisons, memory (`Load`/`Store`, bounded `LoadN`/`StoreN`,
`LoadInterleaved3`, gather, scatter), conversions, permutes, reductions and crypto.
Each ISA family implements the primitives in one header (`x86_128-inl.h` 15,830
lines, `x86_256-inl.h` 10,236, `arm_neon-inl.h` 11,828, `arm_sve-inl.h` 7,533,
`rvv-inl.h` 7,663, `wasm_128-inl.h` 5,468), and `generic_ops-inl.h` (9,978 lines)
derives the rest.

Two conventions recur. Costs are explicit: `ConvertTo`, `PromoteTo`, `DemoteTo`
(saturating) and `MulAdd` are named ops, never implicit. And the tag decides the
memory footprint: a store must use the tag that created the vector, because on SVE
and RVV `DFromV<V>` "may lack the limit on `N` established by the original `D`"
([`quick_reference.md`][qref-sizeless]).

### Targets are feature clusters

The README says Highway "supports 27 targets" but lists 28 on seven architectures
(the `HWY_*` bits in `detect_targets.h` also number 28): `EMU128` and `SCALAR` anywhere;
`NEON_WITHOUT_AES`, `NEON`, `NEON_BF16`, `SVE`, `SVE2`, `SVE_256`, `SVE2_128` on
Arm; `Z14`, `Z15`; `LSX`, `LASX`; `PPC8`, `PPC9`, `PPC10`; `RVV`; `WASM`,
`WASM_EMU256`; and `SSE2`, `SSSE3`, `SSE4`, `AVX2`, `AVX3`, `AVX3_DL`, `AVX3_ZEN4`,
`AVX3_SPR`, `AVX10_2` on x86 ([`README.md`][readme-targets]). Each target is one bit,
and "a lower value is 'better'" ([`detect_targets.h`][detect-bits]), so
`#if HWY_TARGET <= HWY_AVX3` means "AVX-512 or better". A target is a bundle of CPU
features: `kGroupAVX2` requires AVX, AVX2, LZCNT, BMI, BMI2, FMA, F16C and the SSE4
group ([`detect_targets_impl.h`][detect-groups]). The compiler string is built the
same way, each one extending the previous ("Include previous targets, which are the
half-vectors of the next target"): `HWY_TARGET_STR_AVX2` is `HWY_TARGET_STR_SSE4`
plus `",avx,avx2"` plus the BMI2, FMA and F16C strings ([`set_macros-inl.h`][target-str]).

Detection reads CPUID into a 64-bit feature mask, sets a target bit when the whole
group is present, then clears the AVX2 and AVX-512 targets unless `XSAVE` and
`OSXSAVE` are set and `XCR0` shows the OS saves YMM and ZMM state, with a separate
check for a macOS kernel bug that loses AVX-512 state
([`detect_targets_impl.h`][detect-xsave]). Arm, PPC, s390x, RISC-V and LoongArch use
`getauxval` on Linux (Arm on Apple uses `sysctlbyname`); WebAssembly has no run-time
detection ("TODO(janwas): detect support for WASM", [`targets.cc`][targets-wasm]) and
no run-time dispatch, "because browsers reject a binary containing any SIMD
instructions when the browser does not support them"
([`detect_targets.h`][runtime-dispatch]).

Which targets get compiled is a policy in `detect_targets.h`. By default `HWY_TARGETS`
is every attainable target at least as good as the static baseline, which "reduces
code size by excluding superseded targets, in particular scalar"; `HWY_IS_TEST`
compiles all attainable targets including scalar; `HWY_COMPILE_ONLY_STATIC`
collapses to one ([`detect_targets.h`][detect-policy]).

### Static dispatch: one target per namespace

Code that calls ops sits between `HWY_BEFORE_NAMESPACE()` and `HWY_AFTER_NAMESPACE()`
inside `namespace HWY_NAMESPACE` (`N_AVX2` for the AVX2 pass). The first pushes the
target string onto every following function, through `#pragma clang attribute push`
on Clang and `#pragma GCC target` on GCC ([`base.h`][push-attrs]); functions outside
the region use `HWY_ATTR`, `__attribute__((target(HWY_TARGET_STR)))`
([`set_macros-inl.h`][hwy-attr]). Each per-target copy is a distinct symbol, and
`HWY_STATIC_DISPATCH(F)` is simply `HWY_STATIC_NAMESPACE::F` ([`highway.h`][static-dispatch]).

### Dynamic dispatch: re-including the translation unit

Dynamic dispatch adds two lines before `highway.h` and a `HWY_ONCE` section after the
kernels ([`skeleton.cc`][skeleton-include], [`skeleton.cc`][skeleton-export]):

```cpp
// hwy/examples/skeleton.cc (excerpt)
#undef HWY_TARGET_INCLUDE
#define HWY_TARGET_INCLUDE "hwy/examples/skeleton.cc"
#include "hwy/foreach_target.h"  // re-includes this file once per target
#include "hwy/highway.h"
HWY_BEFORE_NAMESPACE();
namespace skeleton { namespace HWY_NAMESPACE {
void FloorLog2(const uint8_t* HWY_RESTRICT values, size_t count,
               uint8_t* HWY_RESTRICT log2) { /* ops on ScalableTag<float> */ }
}}  HWY_AFTER_NAMESPACE();
#if HWY_ONCE
namespace skeleton { HWY_EXPORT(FloorLog2);
void CallFloorLog2(const uint8_t* in, size_t count, uint8_t* out) {
  return HWY_DYNAMIC_DISPATCH(FloorLog2)(in, count, out);
} }
#endif
```

`foreach_target.h` "Re-includes the translation unit zero or more times to compile
for any targets except `HWY_STATIC_TARGET`" ([`foreach_target.h`][foreach-head]). For
each enabled target it redefines `HWY_TARGET`, does `#include HWY_TARGET_INCLUDE`,
then flips `HWY_TARGET_TOGGLE` so that `-inl.h` headers guarded on that toggle are
visible again on the next pass ([`foreach_target.h`][foreach-avx2]). `HWY_ONCE` is 0
during the re-includes and 1 when compilation resumes with the static target, so the
export section is compiled exactly once ([`foreach_target.h`][foreach-once]). A shared
kernel header therefore needs a toggle-aware include guard rather than `#pragma once`.

`HWY_EXPORT(F)` defines a static array of `HWY_MAX_DYNAMIC_TARGETS + 2` function
pointers: entry 0 is a trampoline, then one slot per possible target (`nullptr` when
not compiled), then the scalar or baseline fallback ([`highway.h`][export]).
`HWY_DYNAMIC_DISPATCH(F)` indexes that table with `ChosenTarget::GetIndex`, a count
of trailing zeros over a relaxed atomic mask ([`highway.h`][dyn-dispatch],
[`targets.h`][chosen-target]). The mask starts as 1, so the first call lands in the
trampoline, which runs CPU detection, stores the mask and calls the chosen entry;
later calls are a load, an AND, a trailing-zero count and an indirect call. The
`Caller` object marks that indirect call `[[clang::noinline]]`, so an AVX-512 body is
not inlined into a baseline caller after profile-guided indirect-call promotion
([`highway.h`][caller]). `ChosenTarget` is constant-initialised and trivially
destructible because "dispatch reads it before any dynamic initialization may have
run" ([`targets.h`][chosen-target]). The quick reference also recommends that the
dispatched function take arrays, not vectors: "Due to differing ABIs, we recommend
only passing vector arguments to functions that are inlined"
([`quick_reference.md`][qref-dispatch]).

**Verified.** A `u8` to `f32` scale-and-round kernel (`LoadU`, `PromoteTo`,
`ConvertTo`, `Mul`, `NearestInt`, `DemoteTo`, with `LoadN`/`StoreN` for the tail),
written once in a 68-line file and built with Clang 21.1.7 `-O2`, produced eight
symbols, `demo::N_SSE2::Scale` through `demo::N_AVX3_SPR::Scale`. The program
iterates `SupportedAndGeneratedTargets()` and calls `SetSupportedTargetsForTest`
before each dispatch:

```text
compiled targets (HWY_TARGETS): AVX3_SPR AVX3_ZEN4 AVX3_DL AVX3 AVX2 SSE4 SSSE3 SSE2
static target: SSE2
table entries: 17
AVX3_ZEN4  f32 lanes=16  out[999]= 40  equal-to-first=yes
AVX3_DL    f32 lanes=16  out[999]= 40  equal-to-first=yes
AVX3       f32 lanes=16  out[999]= 40  equal-to-first=yes
AVX2       f32 lanes= 8  out[999]= 40  equal-to-first=yes
SSE4       f32 lanes= 4  out[999]= 40  equal-to-first=yes
SSSE3      f32 lanes= 4  out[999]= 40  equal-to-first=yes
SSE2       f32 lanes= 4  out[999]= 40  equal-to-first=yes
unmocked dispatch -> lanes=16
```

`AVX3_SPR` was compiled but not offered on a CPU without AVX-512 FP16, and `EMU128`
is absent because the default policy drops superseded targets. Compiling that file
(`-c -O2`, two sessions of three runs each) took 4.0 to 4.4 s with the eight targets
and 0.60 to 0.64 s with `HWY_COMPILE_ONLY_STATIC`, about 6.8 times longer in both
sessions. The same build exposed a macro trap:
`HWY_DYNAMIC_DISPATCH(demo::Scale)` compiled with eight targets but failed with one
("no member named 'demo' in namespace 'demo::N_SSE2'"), because the single-target
form is `HWY_STATIC_DISPATCH(FUNC_NAME)`, a name inside the static namespace
([`highway.h`][single-target]); dispatch must be written unqualified inside the
exporting namespace.

### Testing every target in one binary

Because the dispatch decision is a mask, tests can override it.
`SetSupportedTargetsForTest(t)` makes `SupportedTargets()` return `t` and resets the
chosen target so the next dispatch re-reads it; `DisableTargets` does the same for
production opt-outs ([`targets.cc`][targets-mock]). The GoogleTest glue instantiates
each test once per compiled and supported target: `HWY_EXPORT_AND_TEST_P(suite, f)`
expands to `HWY_EXPORT(f)` plus a `TEST_P` whose body is
`HWY_DYNAMIC_DISPATCH(f)()`, and, when more than one target is compiled, the
fixture's `TearDown` fails a test that never went through dynamic dispatch
([`hwy_gtest.h`][gtest-param]). Inside a target, `ForAllTypes(ForPartialVectors<TestMulAdd>())` runs the body for
every lane type and every power-of-two lane count up to `Lanes(d)`, so partial
vectors are covered too; the visitor aborts with "Test is incorrect, ensure
operator() is called" if the body never ran ([`test_util-inl.h`][for-partial],
[`fma_test.cc`][fma-test]). The tree has 116 `*_test.cc` files, 63 of them in
`hwy/tests`, and 192 `.cc` files include `foreach_target.h`.

### `contrib`: image, sort, math and the rest

`hwy/contrib` holds libraries built on the ops: `algo` (`Transform1`, `Find`,
`Copy`), `math` (27 documented entries from `Acos` to `Lgamma`, each with lane types
and all but `Atan2` with maximum ULP error and valid range, [`math-inl.h`][math-exp]),
`sort` (VQSort, a vectorised quicksort, [paper][vqsort-paper]), `image`, `thread_pool`, `dot`,
`matvec`, `bit_pack`, `crc`, `hash` and others.

**`contrib/image`** is a planar, single-channel image with padded aligned rows
([`image.h`][image-h]): "'Single channel' (one 2D array per channel) simplifies
vectorization … 'Aligned' means each row is aligned to the L1 cache line size. … By
rounding up row sizes to the vector size, we allow reading/writing ALIGNED vectors
whose first lane is a valid sample." `BytesPerRow` rounds up to the larger of the
vector size and `HWY_ALIGNMENT` (128) and then, to avoid "a false dependency between
writes to consecutive rows", adds one more alignment unit; its comment says this keeps
row sizes off multiples of 2 KiB, but the test is `bytes_per_row % HWY_ALIGNMENT == 0`,
which always holds after the rounding, so the unit is always added and a row can still
land on a 2 KiB multiple (1,889 one-byte samples on AVX2 give 2,048 bytes)
([`image.cc`][image-cc]). `Image3<T>` bundles three same-sized
planes; libjxl's image classes follow the same design ([libjxl §1][libjxl-pixel]).

**`contrib/sort`** shows how a large dispatched library is packaged: one translation
unit per key type and order (`vqsort_f32a.cc`, `vqsort_f32d.cc`, …), each re-included
per target behind a public `VQSort` overload ([`vqsort_f32a.cc`][vqsort-f32a]),
"Split into separate files to reduce MSVC build time" ([`BUILD`][sort-build]).

### How libjxl and libvips use it

[libjxl][libjxl-simd] uses the pattern in 53 files under `lib/jxl`; its kernels loop
`x += Lanes(d)` with no tail, relying on padded rows, and some paths are deliberately
target-specific (`FastXYBTosRGB8` only `#if HWY_TARGET == HWY_NEON`). Eight of its test
files use `HWY_EXPORT_AND_TEST_P`. [libvips][libvips-simd] has six Highway kernel files
over `ScalableTag` (`convi`, `morph`, `reduceh`, `reducev`, `shrinkh`, `shrinkv`); the
shrink path takes them only for `uchar`, `HWY_EMU128` and `HWY_SCALAR` are excluded
from its supported targets, and the `VIPS_VECTOR` environment variable masks targets
for testing. Both hoist dispatch to the row or region, as the design document asks.
[OpenImageIO][oiio-simd] uses only the static target, and the path is off by default.

### The same shape in D (verified with LDC 1.41)

A single-file D program reproduced the mechanism for three x86 targets:

```d
// /tmp scratch, not committed (excerpt)
enum Tgt { sse2, sse4, avx2 }
immutable string[] tgtStr = ["sse2", "sse4.1,sse4.2", "avx,avx2,fma"];
pragma(inline, true) V madd(V)(V a, V b, V c) { return a * b + c; }
template axpy(Tgt t) {
    @target(tgtStr[t]) void axpy(float k, const(float)* x, float* y, size_t n) { /* ... */ }
}
alias Fn = void function(float, const(float)*, float*, size_t);
immutable Fn[Tgt.max + 1] table = () {
    Fn[Tgt.max + 1] r;
    static foreach (t; __traits(allMembers, Tgt))
        r[__traits(getMember, Tgt, t)] = &axpy!(__traits(getMember, Tgt, t));
    return r;
}();
```

- **Per-target instantiation.** A prefix `@target(tgtStr[t])` on a function template
  fails ("undefined identifier `t`"), because the attribute is evaluated outside the
  template's scope. It works inside an eponymous template, as above, and in the
  postfix position `blake3_simd.d` uses. Each instantiation is a separately mangled
  symbol, so D needs no `HWY_NAMESPACE`.
- **Inlined generic ops take the caller's target.** `madd` has no `@target`; in the
  AVX2 instantiation it compiled to `vmulps`/`vaddps` on `ymm`, in the SSE2 one to
  `mulps`/`addps` on `xmm`. It was not contracted into `vfmadd` although `fma` was in
  the target string: fused multiply-add needs an explicit intrinsic, as Highway's
  `MulAdd` is an explicit op.
- **The dispatch table is CTFE.** `static foreach` filled the `immutable` table at
  compile time, `core.cpuid` chose the index, and all three entries agreed.
- **Compile-time feature probes do not see `@target`.** `__traits(targetHasFeature, "avx2")`
  was `false` inside every instantiation, the AVX2 one included, without
  `-mattr=+avx2`. `intel-intrinsics` chooses builtin or emulation with that probe
  ([`internals.d`][ii-internals]): compiled into the same unit (`-i=inteli`),
  `_mm256_shuffle_epi8` ([`avx2intrin.d`][ii-shuffle]) under `@target("avx,avx2")`
  became 53 instructions of byte lookups through the stack, and under `-mattr=+avx2`
  one `vpshufb %ymm1, %ymm0, %ymm0`. The [intel-intrinsics deep-dive][ii-simd] reports
  the same for gathers and permutes. Nothing here is CI-verified.

---

## Analysis

### 1. Pixel and memory model

Highway has no pixel model; its unit is the lane, and a vector is `Lanes(d)` lanes of
`u8` to `u64`, `i8` to `i64`, `f16`, `bf16`, `f32` or `f64`. Pixel structure enters
only through ops: `LoadInterleaved3`/`StoreInterleaved4` split RGB and RGBA into
planes, and `PromoteTo`/`DemoteTo` with `Rebind` tags widen `u8` samples to `f32` and
back. The README's advice is to change the data, not the kernel: "the biggest gains
are unlocked by designing algorithms and data structures for scalable vectors.
Helpful techniques include batching, structure-of-array layouts, and aligned/padded
allocations" ([`README.md`][readme-design]).

`contrib/image` turns that advice into a type: a [planar][c-planar] `Image<T>` with a
byte [stride][c-stride] (`bytes_per_row`) that is a multiple of the vector size and
cache line, `uint32_t` dimensions, and two padding modes: `kRoundUp` (aligned `Load`
up to the rounded width) and `kUnaligned` (`LoadU` at any valid `x`, after
`InitializePaddingForUnalignedAccesses`) ([`image.h`][image-padding]). There are no
views or sub-rectangles, no N-D extents and no interleaved storage.

### 2. Genericity mechanism

Two mechanisms, one per axis. **Lane type and width** are C++ templates: kernels
take `class D`, ops overload on `Simd<T, N, kPow2>`, and constraints are `HWY_IF_*`
SFINAE macros (`HWY_IF_T_SIZE(T, 1)`). **Instruction set** is the preprocessor: the
same text compiles under each `HWY_TARGET`, branching on `#if HWY_TARGET == HWY_NEON`
or per-target capability macros (`HWY_HAVE_FLOAT64`, `HWY_HAVE_SCALABLE`,
`HWY_NATIVE_FMA`, `HWY_MEM_OPS_MIGHT_FAULT`) from `set_macros-inl.h`. C++ cannot
attach a target attribute chosen by a template argument; D can (verified above),
which removes the driver but not the capability vocabulary. Highway is an op library
with no scheduling layer ([generic programming][p-generic], [Halide][halide],
[algorithm and schedule][c-schedule]): loops, tiling and fusion stay in user code.

### 3. Colour and metadata

Not applicable: Highway has no colour or metadata model. What it supplies to colour
code is arithmetic: `contrib/math` provides `Exp`, `Exp2`, `Log`, `Log2`, `Pow`,
`Cbrt` and others with documented bounds (for `Exp`, "Max Error: ULP = 1", "Valid
Range: float32[-FLT_MAX, +104]", [`math-inl.h`][math-exp]), which is what a
vectorised transfer function needs.

### 4. I/O and codec architecture

Not applicable: no I/O and no codecs. Inside codecs Highway is the kernel layer
(colour transforms, DCTs and filters in libjxl; convolution and resampling in
libvips), and the layering lesson is that dispatch happens once per row, group or
region, never per pixel. `contrib/sort` shows the packaging of a dispatched library:
per-type translation units behind ordinary non-template public functions, so callers
never include Highway headers.

### 5. Hostile input and safety

Highway's safety concern is memory faults from vector-width access, not input
validation. Ops state their fault behaviour: `Load` "May fault if the pointer is not
aligned to the vector size", `MaskedLoadOr` (and so `MaskedLoad`) "May fault even
where `mask` is false `#if HWY_MEM_OPS_MIGHT_FAULT`", and "LoadN does not fault if all of the elements in
`[p, p + max_lanes_to_load)` are accessible" ([`quick_reference.md`][qref-load]). The
README's loop strategies reflect this: padded buffers are "the preferred option",
overlapping last vectors "the second preferred option", and a masked tail "is only
safe `#if !HWY_MEM_OPS_MIGHT_FAULT`!" ([`README.md`][readme-strip]); ASan and MSan builds force that macro to 1
([`set_macros-inl.h`][asan-fault]). `contrib/image` checks `xsize * sizeof_t`, the
padding add and `bytes_per_row * ysize` for `size_t` overflow and aborts
([`image.cc`][image-cc]), and bounds-checks rows only under sanitizers
([`image.h`][image-padding]). There are no exceptions; failures go through
`HWY_ABORT` and `HWY_ASSERT`. The README forbids "namespace-scope nor `static`
initializers for SIMD vectors because this can cause SIGILL" before dispatch runs
([`README.md`][readme-sigill]). There is no fuzz harness; consumers such as libjxl fuzz.

### 6. Allocation and ownership

Ops never allocate. `AllocateAligned<T>(n)` returns an `AlignedPtr` (a unique pointer
with a custom deleter) aligned for `Load`; lane-count-sized scratch must come from it
because `Lanes(d)` "might not be constexpr, it must also not be used as array
dimensions" ([`quick_reference.md`][qref-lanes]). `ImageBase` owns its rows through
an aligned pointer, forbids copies ("Copy construction/assignment is forbidden to
avoid inadvertent copies, which can be very expensive"), and has a constructor that
"References but does not take ownership of external memory" when the caller meets the
alignment rules ([`image.h`][image-own]).

### 7. CPU parallelism and SIMD

This is the subject's whole content ([How it works](#how-it-works)). Three points
remain: dispatch is hoisted to rows or regions, with arrays, not vectors, crossing
the boundary (`blake3_simd.d` likewise moves vectors through memory); target choice
belongs to the application (`DisableTargets` can refuse AVX-512 for frequency
reasons); and on Linux `prctl(PR_SVE_SET_VL)` can change the SVE length, so `Lanes(d)`
is not cached across such a change ([`quick_reference.md`][qref-lanes]). Threads are
separate: `contrib/thread_pool` has a pool; libjxl and libvips bring their own.

### 8. GPU offload and interop

Not applicable: Highway targets CPUs only. Its kernel model (descriptors, masks,
`Lanes(d)`) has no mapping to SPIR-V or a compute dispatch, and there is no GPU backend
or interop hook. For **Q7** this means a Highway-style kernel and a compute-shader
kernel remain two sources.

### 9. Temporal, animation and containers

Not applicable: Highway has no notion of frames, time or containers.

### 10. Testing and conformance

Per-target testing in one binary is the strongest transferable practice
([Testing every target](#testing-every-target-in-one-binary)). Releases are also
tested with Clang and GCC on x86 and GCC cross-compiles for Armv7/8
([`README.md`][readme-testing]); CI runs foreign architectures under QEMU (RISC-V with
`qemu-riscv64;-cpu;max,v=true,vlen=256`), several with `HWY_COMPILE_ONLY_STATIC`
([`multiarch.yml`][multiarch]). Targets stay supported "as long as they can be
(cross-)compiled with currently supported Clang or GCC, and tested using QEMU"
([`README.md`][readme-policy]). Op tests compare exactly (`HWY_ASSERT_VEC_EQ`) for
integers and within ULP bounds in `contrib/math`. There is no cross-target
bit-exactness check; the verified demo's integer output was identical on all seven
offered targets.

---

## Lessons for Sparkles

- **Q3 — The dispatch mechanism maps onto D with less machinery.** `foreach_target.h`
  exists because C++ cannot vary a target attribute by template argument. LDC can: an
  eponymous template with `@target(tgtStr[t])`, a `static foreach` over a target enum
  and an `immutable` CTFE table reproduce `HWY_NAMESPACE`, `HWY_ATTR` and `HWY_EXPORT`
  (verified above). D would still have to build target clusters (`kGroup*` sets with
  their `@target` strings), OS-state detection (`XCR0`), a first-call or start-up
  choice, a test override and a capability vocabulary. The
  [SIMD baseline][bl-shaders-gaps] (G4, G5) has the first half only in the BLAKE3
  kernels, with detection repeated by hand (`blake3.d` and `grapheme.d` each call
  `core.cpuid`) behind `package` visibility.
- **Q3 — Scalable vectors do not map.** D's `__vector(T[N])` requires a static length
  ([D vector extensions][d-simd]), so `ScalableTag` and a run-time `Lanes(d)` have no D
  counterpart, and a D kernel would be instantiated per fixed width. Highway itself
  offers fixed-width Arm targets (`SVE_256`, `SVE2_128`) beside the scalable ones,
  which is the shape LLVM fixed-length SVE would give a D port. Whether LDC emits SVE
  for a fixed-width `__vector` under `@target("+sve")` was not tested; the
  [hardware inventory][hw-matrix] records no SVE on any of its arm64 machines (M4 Max,
  Snapdragon 888, Snapdragon 8 Elite), so a run needs QEMU or new hardware.
- **Q3, Q7 — The op catalogue is the reusable asset, not the C++ API.** Highway's op
  names and semantics (saturating `DemoteTo`, non-faulting `LoadN`, explicit `MulAdd`,
  interleaved loads, `Compress`) are a tested specification of what pixel kernels need
  across seven architectures. In D the arithmetic subset comes free, since generic
  vector operators lower per target (verified), while shuffles, saturating narrowing,
  compress and table lookups need per-target LLVM intrinsics; that is where most of
  Highway's per-target headers (over 58,000 lines for the six listed) go. A D layer
  would pick a subset; the evidence says nothing about which.
- **Q3 — `intel-intrinsics` and `@target` do not compose** (verified above; see the
  [intel-intrinsics deep-dive][ii-simd]). It suits code compiled whole for one ISA
  with `-mattr`, or porting x86 intrinsics to arm64; it is not a dispatch model. A
  kernel over generic vectors plus LLVM intrinsics keeps `@target` working, as
  `blake3_simd.d` shows.
- **Q2 — Descriptors fit design by introspection.** A Highway tag is a type carrying
  lane type, maximum lanes and scale, and capability macros answer "does this target
  have native FMA, 64-bit lanes, scalable vectors". In D both become a descriptor
  struct with `enum` members and `static if` over them, the
  [design-by-introspection][dbi] shape the repository prescribes. Kernels stay
  templates, so `@safe pure nothrow @nogc` is inferred, with `size_t` indices and
  slices at the dispatched boundary; vector loads and stores through casts still need
  the narrow `@trusted` lambdas `blake3_simd.d` uses.
- **Q1 — Padding is part of the pixel contract.** libjxl's tail-free loops and
  Highway's preferred strip-mining strategy assume rows padded to the vector size, and
  `contrib/image` encodes it in `BytesPerRow`, with an extra alignment unit whose
  stated 2 KiB-avoidance the code does not achieve (above). Sparkles
  has no pixel view type yet ([existing code][bl-existing-gaps], G2). If one promises
  vector-padded rows, kernels lose their remainder loops; if not, every kernel needs
  `LoadN`-style bounded tails. Compare mir's `Slice` ([experiment][mir-slice]).
- **Q8 — Test every backend in one binary, with a guard that dispatch happened.**
  `SetSupportedTargetsForTest` plus `HWY_EXPORT_AND_TEST_P` run each test once per
  supported target and fail a test that bypassed dispatch. Sparkles' `blake3_test.d`
  already loops over backends with `static foreach` and calls `skipTest` for backends
  the CPU lacks; a shared test-runner facility with a per-target lane-count sweep like
  `ForPartialVectors` would generalise it. Targets the host lacks need QEMU or real
  devices, the route Highway's CI takes.
- **Q7 — Build cost is real.** One small kernel compiled about 6.8 times slower with
  eight targets than with one (verified). Highway mitigates with a default that drops
  superseded targets, `HWY_COMPILE_ONLY_STATIC` and per-type translation units; a D
  design faces the same multiplier, and the baseline's G7 adds that `-mcpu=native`
  benchmark builds bypass the shipped dispatch.
- **Q9 — Dispatch infrastructure is a base-layer concern.** Highway keeps ops, targets
  and dispatch in `hwy` and puts image, sort and math in `contrib`, each a separate
  library (`libhwy`, `libhwy-contrib`, `libhwy-test`). That is evidence for placing
  target detection and the dispatch table below any image package, in line with the
  standing rule against package-local copies of shared infrastructure.
- **Q9 — Portability modes need the one-entry case.** WebAssembly in Highway is
  static-only and arm64 has NEON as baseline, yet the call site is unchanged. A D layer
  for betterC, wasm and the Android APK must work with a one-entry table; whether
  `core.cpuid` and `shared static this` run under `--better-c` is the baseline's G6.

---

## Strengths

- One kernel source for the 28 targets the README lists on seven architectures,
  including scalable SVE and RVV; the README lists Chromium and Firefox among its users ([`README.md`][readme-users]).
- Dispatch is cheap after the first call and careful: OS register-state checks,
  constant-initialised state, no inlining of wider code into baseline callers.
- Costs are visible in the API; escape hatches (per-target `#if`, raw intrinsics,
  fixed-width tags) stay available.
- Every compiled target is tested in one process, and tests that skip dispatch fail.
- `contrib` supplies vetted building blocks (VQSort, ULP-bounded math, an aligned
  planar image) on the same dispatch scheme.

## Weaknesses

- The preprocessor driver is intricate: re-included translation units, toggle-aware
  include guards, `HWY_ONCE` sections, and dispatch macros whose behaviour differs
  between one and many targets (the qualified-name failure above).
- Sizeless vectors cannot be stored in arrays, structs or statics, which constrains
  portable data-structure design on every target, not only on SVE and RVV.
- Compile time and code size grow with the number of targets; WebAssembly has no
  run-time detection.
- Run-time `Lanes(d)` on SVE and RVV blocks constant folding and lane-sized stack arrays.
- No GPU path and no scheduling layer: tiling, fusion and threading remain the caller's
  work.

---

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                                     | Trade-off                                                                       |
| ------------------------------------------------------ | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Free functions overloaded on a zero-sized tag `d`      | Sizeless SVE/RVV vectors cannot be class members or default-constructed       | Verbose call sites (`hn::Mul`, `Set(d, k)`); stores must reuse the creating tag |
| Width-agnostic `ScalableTag` and run-time `Lanes(d)`   | Code improves as vectors widen; matches SVE and RVV                           | No constant lane count on scalable targets; no stack arrays sized by lanes      |
| Targets are feature clusters, one bit each             | Bounds the number of compiled variants; `HWY_TARGET <= X` reads as "at least" | CPUs with partial feature sets fall to a lower cluster                          |
| Re-include the translation unit per target             | C++ cannot vary target attributes per instantiation; no ODR clashes           | Macro-heavy; special include guards; compile time multiplies                    |
| Dispatch table with lazy detection on first call       | No static-initialisation order issue; zero cost with one target               | First call pays detection; the mask is a process-wide global                    |
| Default compiles only targets better than the baseline | Smaller binaries and builds                                                   | The scalar reference is absent unless tests ask for it                          |
| Test override of the supported-target mask             | Every compiled target is testable on one machine                              | Targets the host CPU lacks need emulation (QEMU, SDE)                           |
| No allocation in ops; `AllocateAligned` for buffers    | Predictable kernels, explicit alignment                                       | Callers manage padding and scratch                                              |
| `contrib` as separate libraries on the same ops        | Keeps the core small; domain code reuses dispatch                             | Image support is minimal (planar planes, no views)                              |

---

## Sources

- Highway at the pinned revision ([repository][repo]): the README, `g3doc`, `hwy/`
  core headers and runtime, `hwy/tests`, `hwy/contrib/{image,sort,math}` and
  `.github/workflows/multiarch.yml`, each cited inline with line anchors.
- Documentation: [Highway documentation][docs]; the VQSort [paper][vqsort-paper].
- intel-intrinsics at `2141185c60cb166c79970d624b22d61fc980a96d`:
  [`internals.d`][ii-internals], [`avx2intrin.d`][ii-shuffle]. D and LDC:
  [D vector extensions][d-simd]; [LDC-specific language changes][ldc-attrs].
- Repository code read for comparison: `libs/base/src/sparkles/base/hash/blake3_simd.d`
  and `blake3_test.d` beside it.
- Demonstrations (under `/tmp`, not committed): a Highway dispatch program (Clang
  21.1.7, `git archive` of the pinned source) and a D dispatch program plus an
  `intel-intrinsics` probe (LDC 1.41.0; the D results also hold on LDC 1.43.0), and a
  `BytesPerRow` probe linked against `contrib/image`, run on an AMD Ryzen 9 7940HX,
  Linux 6.18.
- Related: [libjxl][libjxl-simd], [libvips][libvips-simd], [OpenImageIO][oiio-simd],
  [Halide][halide], [intel-intrinsics][ii-simd], [shaders and SIMD baseline][bl-shaders-gaps],
  [existing image code][bl-existing-gaps], [concepts][concepts].

<!-- References -->

[repo]: https://github.com/google/highway/tree/872f22991f11a09c4a3633935cb26bdd1977541a
[docs]: https://google.github.io/highway/en/master/
[license]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/LICENSE#L1-L5
[cmake]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/CMakeLists.txt#L39
[qref]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/g3doc/quick_reference.md
[qref-dispatch]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/g3doc/quick_reference.md#L24-L66
[qref-lanes]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/g3doc/quick_reference.md#L183-L218
[qref-sizeless]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/g3doc/quick_reference.md#L276-L311
[qref-load]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/g3doc/quick_reference.md#L1871-L1912
[philosophy]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/g3doc/design_philosophy.md
[philosophy-dispatch]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/g3doc/design_philosophy.md#L54-L65
[philosophy-width]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/g3doc/design_philosophy.md#L1-L44
[philosophy-overload]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/g3doc/design_philosophy.md#L91-L100
[philosophy-omit]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/g3doc/design_philosophy.md#L151-L153
[readme-deploy]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/README.md#L38-L46
[readme-design]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/README.md#L53-L57
[readme-users]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/README.md#L98-L125
[readme-targets]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/README.md#L211-L240
[readme-policy]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/README.md#L242-L248
[readme-testing]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/README.md#L262-L269
[readme-sigill]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/README.md#L396-L399
[readme-strip]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/README.md#L505-L580
[foreach-head]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/foreach_target.h#L19-L46
[foreach-avx2]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/foreach_target.h#L91-L100
[foreach-once]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/foreach_target.h#L383-L392
[static-dispatch]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/highway.h#L134-L136
[single-target]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/highway.h#L534-L551
[caller]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/highway.h#L393-L426
[export]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/highway.h#L642-L658
[dyn-dispatch]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/highway.h#L664-L674
[chosen-target]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/targets.h#L336-L389
[targets-mock]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/targets.cc#L163-L201
[targets-wasm]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/targets.cc#L141-L147
[detect-bits]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/detect_targets.h#L50-L51
[detect-policy]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/detect_targets.h#L995-L1012
[runtime-dispatch]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/detect_targets.h#L866-L878
[detect-groups]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/detect_targets_impl.h#L304-L363
[detect-xsave]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/detect_targets_impl.h#L427-L470
[shared-simd]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/ops/shared-inl.h#L184-L218
[shared-tags]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/ops/shared-inl.h#L386-L428
[target-str]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/ops/set_macros-inl.h#L181-L189
[asan-fault]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/ops/set_macros-inl.h#L980-L984
[hwy-attr]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/ops/set_macros-inl.h#L986-L1016
[push-attrs]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/base.h#L218-L232
[sve-lanes]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/ops/arm_sve-inl.h#L290-L338
[vec256]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/ops/x86_256-inl.h#L100-L148
[skeleton-include]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/examples/skeleton.cc#L20-L46
[skeleton-export]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/examples/skeleton.cc#L97-L125
[gtest-param]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/tests/hwy_gtest.h#L89-L190
[for-partial]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/tests/test_util-inl.h#L622-L645
[fma-test]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/tests/fma_test.cc#L135-L137
[image-own]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/contrib/image/image.h#L33-L56
[image-h]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/contrib/image/image.h#L128-L188
[image-padding]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/contrib/image/image.h#L93-L126
[image-cc]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/contrib/image/image.cc#L35-L106
[vqsort-f32a]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/contrib/sort/vqsort_f32a.cc#L16-L77
[sort-build]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/contrib/sort/BUILD#L88-L89
[math-exp]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/hwy/contrib/math/math-inl.h#L2191-L2200
[multiarch]: https://github.com/google/highway/blob/872f22991f11a09c4a3633935cb26bdd1977541a/.github/workflows/multiarch.yml#L12-L61
[vqsort-paper]: https://arxiv.org/abs/2205.05982
[ii-internals]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/internals.d#L283-L320
[ii-shuffle]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/avx2intrin.d#L4235-L4247
[d-simd]: https://dlang.org/spec/simd.html
[ldc-attrs]: https://wiki.dlang.org/LDC-specific_language_changes
[libjxl-simd]: ./libjxl.md#_7-cpu-parallelism-and-simd
[libjxl-pixel]: ./libjxl.md#_1-pixel-and-memory-model
[libvips-simd]: ./libvips.md#_7-cpu-parallelism-and-simd
[oiio-simd]: ./openimageio.md#_7-cpu-parallelism-and-simd
[halide]: ./halide.md
[ii-simd]: ./intel-intrinsics.md#_7-cpu-parallelism-and-simd
[mir-slice]: ./mir-algorithm/slice-experiment.md
[concepts]: ./concepts.md
[c-planar]: ./concepts.md#interleaved-planar-and-semi-planar
[c-stride]: ./concepts.md#stride
[c-schedule]: ./concepts.md#algorithm-and-schedule
[p-generic]: ./papers/generic-image-programming.md
[bl-shaders-gaps]: ./baseline/shaders-simd.md#gaps-and-tensions
[bl-existing-gaps]: ./baseline/existing-code.md#gaps-and-tensions
[hw-matrix]: ./hardware/index.md
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
