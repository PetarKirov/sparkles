# intel-intrinsics (D)

The x86 intrinsics API (`_mm_*`, `_mm256_*`) as a D library: every intrinsic from MMX to AVX2 has
one fixed meaning, and the library chooses at compile time how to produce it on DMD, LDC or GDC,
for x86, AArch64, 32-bit ARM or WebAssembly.

| Field         | Value                                                                                                    |
| ------------- | -------------------------------------------------------------------------------------------------------- |
| Language      | D (DMD, LDC and GDC 12 or later)                                                                         |
| License       | BSL-1.0 ([`dub.json`][dub])                                                                              |
| Repository    | [AuburnSounds/intel-intrinsics][repo]                                                                    |
| Revision read | `2141185c60cb166c79970d624b22d61fc980a96d` (September 6, 2026; tagged `v1.14.10`)                        |
| Documentation | the [`README.md`][readme-intro]; [`CONTRIBUTING.md`][contrib]; the [Intel Intrinsics Guide][intel-guide] |
| Category      | D landscape: portable SIMD                                                                               |
| Tier          | B                                                                                                        |
| Last reviewed | November 7, 2026                                                                                         |

> [!NOTE]
> Claims marked **verified** were run in a scratch directory outside the repository against a
> `git archive` of the pinned revision, with the compilers of this repository's dev shell: LDC
> 1.43.0 (DMD frontend 2.113.0, LLVM 24.0.0git) and DMD 2.112.1. AArch64 and x86-64 code was
> compiled to assembly with `ldc2 -O2 -release -enable-cross-module-inlining -output-s`; AArch64
> code was compiled, not run. Everything else was read in the source. The weight-bearing
> **verified** claims were rerun independently on November 15, 2026 with the same compilers.

## Overview

### What it solves

D has two compiler-specific SIMD vocabularies (DMD's `__simd` operations in `core.simd`, and LDC's
`ldc.simd`, `ldc.gccbuiltins_*` and inline LLVM IR) and GDC's GCC builtins. `core.simd`'s vector
types are shared, but none of the operation sets is portable across compilers, and none reaches
every instruction. intel-intrinsics puts one API in
front of all three, borrowing the names C, C++ and Rust programmers already use. The
[README][readme-intro] positions it:

> `intel-intrinsics` is the SIMD library for D.
>
> `intel-intrinsics` lets you use SIMD in D with support for LDC / DMD / GDC with a single syntax and
> API: the x86 Intel Intrinsics API that is also used within the C, C++, and Rust communities.
>
> `intel-intrinsics` is most similar to simd-everywhere, it can target AArch64 for full-speed
> with Apple Silicon without code change.

The reason given for not exposing compiler intrinsics directly is image- and video-shaped
([README L117][readme-why]):

> Some instructions just aren't accessible using `core.simd` and `ldc.simd` capabilities. For
> example: `pmaddwd` which is so important in digital video. Some instructions need an almost exact
> sequence of LLVM IR to get generated. `ldc.intrinsics` is a moving target and you need a layer on
> top of it.

### Design philosophy

Semantics first, instruction selection second ([README L46-L49][readme-philo]):

> - `intel-intrinsics` generates optimal code else it's a bug.
> - **No promise that the exact instruction is generated**, because it's often not the fastest
>   thing to do.
> - Guarantee that the **semantics** of the intrinsic is preserved, above all other consideration
>   (even at the cost of speed).

The scope is closed at AVX2 by policy: "Do not add AVX-512 or AVX-10 intrinsics, they are out of
scope" ([`CONTRIBUTING.md` L17][contrib]). Every intrinsic must have "a slow path that works on all
compilers" and "one unittest per intrinsic" ([`CONTRIBUTING.md` L35-L39][contrib-merge]). The
library is a dependency of Auburn Sounds' own [Gamut](./gamut.md) and
[Dplug graphics](./dplug-graphics.md).

## How it works

**Capability enums, not version blocks.** [`internals.d`][int-gdc] computes one `bool` per
compiler, ISA and feature, and every intrinsic branches on them with `static if`. LDC reads the
compilation target through `__traits(targetHasFeature, …)` ([L283-L327][int-ldc-x86]); AArch64
sets `LDC_with_ARM64 = true; // implies "has Neon"` ([L260-L281][int-ldc-arm]); GDC probes builtin
availability with `__traits(compiles, __builtin_ia32_haddps)` and similar ([L102-L110][int-gdc-probe]);
WebAssembly checks `simd128` ([L231][int-wasm]). DMD can only detect SSE4.1 indirectly, by whether
`int4(0) * int4(0)` compiles, and "pessimize[s]" SSE3 and SSSE3 to that answer
([L401-L430][int-dmd]).

**One intrinsic, up to six bodies.** `_mm_avg_epu8` shows the ladder
([`emmintrin.d` L411-L459][avg]):

```d
__m128i _mm_avg_epu8 (__m128i a, __m128i b) pure @trusted
{
    static if (DMD_with_DSIMD)
        return cast(__m128i) __simd(XMM.PAVGB, a, b);
    else static if (GDC_with_SSE2)
        return cast(__m128i) __builtin_ia32_pavgb128(cast(ubyte16)a, cast(ubyte16)b);
    else static if (LDC_with_SSE2 && __VERSION__ >= 2094)
        return cast(__m128i) __builtin_ia32_pavgb128(cast(byte16)a, cast(byte16)b);
    else static if (LDC_with_ARM64)
        return cast(__m128i) vrhadd_u8(cast(byte16)a, cast(byte16)b);
    else static if (LDC_with_WASM_SIMD)
        return cast(__m128i) __builtin_wasm_avgr_u_i8x16(cast(byte16)a, cast(byte16)b);
    else static if (LDC_with_optimizations)
    {   /* inline LLVM IR: zext, add, add 1, lshr 1, trunc */ }
    else
    {   /* scalar loop over 16 lanes */ }
}
```

(Excerpt, braces condensed.) The NEON helpers such as `vrhadd_u8` and `vqtbl1q_s8` are not a
separate library: [`internals.d`][int-neon] declares them as `pragma(LDC_intrinsic,
"llvm.aarch64.neon.…")` or writes them as lane loops that LLVM pattern-matches.

**Inline IR as the portable middle tier.** Where no builtin exists on the target, LDC gets a
hand-written LLVM IR sequence that LLVM lowers well on every backend. `_mm_madd_epi16` (the
`pmaddwd` of the README) sign-extends, multiplies, and adds even and odd lanes through two
`shufflevector`s ([`emmintrin.d` L2351-L2393][madd]):

```d
else static if (LDC_with_optimizations)
{
    // 5 inst with arm64 + LDC 1.32 + -O1
    enum ir = `
        %ia = sext <8 x i16> %0 to <8 x i32>
        %ib = sext <8 x i16> %1 to <8 x i32>
        %p = mul <8 x i32> %ia, %ib
        %p_even = shufflevector <8 x i32> %p, <8 x i32> undef, <4 x i32> <i32 0, i32 2,i32 4, i32 6>
        %p_odd  = shufflevector <8 x i32> %p, <8 x i32> undef, <4 x i32> <i32 1, i32 3,i32 5, i32 7>
        %p_sum = add <4 x i32> %p_even, %p_odd
        ret <4 x i32> %p_sum`;
    return cast(__m128i) LDCInlineIR!(ir, int4, short8, short8)(cast(short8)a, cast(short8)b);
}
```

**Verified:** on AArch64, `_mm_madd_epi16` compiles to `smull2`, `smull`, `addp`;
`_mm_mulhi_epi16` to `smull2`, `smull`, `uzp2`; `_mm_avg_epu8` to one `urhadd`. On x86-64 with
`-mattr=+sse4.2`, `_mm_madd_epi16` is one `pmaddwd` and `_mm_avg_epu8` one `pavgb`. Without
`-enable-cross-module-inlining` (or `-i`), every one of these became a call into the library on
AArch64: the intrinsics are ordinary non-template functions, and the source has 88
`pragma(inline, true)` annotations for roughly 950 of them.

**AVX2 without AVX2.** The 256-bit types exist everywhere ([`types.d` L451-L457][types-alias]:
`__m256i` is `long4`). When the target lacks AVX2, many `_mm256_*` intrinsics split into two
128-bit halves; `_mm256_madd_epi16` says "split is beneficial for ARM64, LDC and GDC without AVX2"
([`avx2intrin.d` L2783-L2804][madd256]). DMD emulates every AVX-sized vector as a struct with
operator overloads, because DMD bugs 24283 and 24284 block native 256-bit vectors
([`types.d` L84-L125][types-dmd]). The same struct emulation supplies vector operators to
compilers that lack them (`VectorOps`, [`types.d` L131-L200][types-ops]).

**MXCSR on ARM.** `_mm_setcsr` maps the SSE rounding mode and flush-to-zero bits onto AArch64's
FPCR, "_partially_ and only support rounding mode changes" ([`xmmintrin.d` L2428-L2452][setcsr]);
the README lists exception status, exception masks and separate denormals-are-zero as absent
([README L148-L160][readme-arm]).

## Analysis

### 2. Genericity mechanism

There is none above the vector: genericity is across compilers and targets, not across element
types. Each intrinsic is a concrete function over erased vector types, as in Intel's API: "This
type erasure of integers vectors is a defining point of the Intel API" ([README L70][readme-types]).
A pixel kernel written with it is therefore written per element width and per vector width
(`_mm_madd_epi16`, `_mm256_madd_epi16`), and genericity over pixel types has to be built above it,
as [Dplug graphics](./dplug-graphics.md) does with hand-specialised bodies. The capability enums
are the reusable idea: a `static if` ladder keyed on target features is design by introspection
over the compiler.

### 5. Hostile input and safety

Two findings matter for code that sizes buffers from untrusted headers
([concepts: hostile input](./concepts.md#hostile-input)):

- **Unchecked sizes in `_mm_malloc`.** `requestedSize` returns `askedSize + alignment - 1 +
pointerSize * 3` with no overflow check ([`xmmintrin.d` L3142-L3146][malloc-size];
  [`_mm_malloc` L1474-L1482][malloc]). **Verified:** under DMD,
  `_mm_malloc(size_t.max - 20, 64)` returns a non-null pointer to a small block instead of
  reporting out-of-memory.
- **`@trusted` pointer loads.** `_mm_loadu_ps(const(float)* mem_addr)` is `pure @trusted`
  ([`xmmintrin.d` L1420][loadu-ps]), so `@safe` code can read 16 bytes through a pointer to a
  single `float` (**verified**: a `@safe` function calling `_mm_loadu_ps(&x)` on a `ref float`
  compiles under DMD with `-preview=dip1000`). `_mm_loadu_si128(const(__m128i)* mem_addr)` is
  `@trusted` too ([`emmintrin.d` L2242][loadu]), though `@safe` code cannot cast an `int*` to
  `__m128i*` to reach it; the store's own comment says "signature is wrong, mem_addr is not aligned. Make it
  @system" ([L5004][storeu]). Masked loads, by contrast, are `@system`, and the README warns that
  they "MUST address fully addressable memory, even if their mask is zero. Pad your buffers"
  ([README L164][readme-diff]).

### 6. Allocation and ownership

The library allocates only in `_mm_malloc` (and its non-Intel companion `_mm_realloc`), which
over-allocates from `malloc` and stores the raw
pointer, size and alignment in the three words below the aligned address
([`xmmintrin.d` L3149-L3161][malloc-store]). Everything else is `nothrow @nogc` and value-typed;
the `USE_NURT` version swaps `malloc`, `free` and `memcpy` for numem hooks
([`internals.d` L19-L33][int-nurt]). An image library keeps ownership of its planes; this layer
never sees a buffer longer than one vector.

### 7. CPU parallelism and SIMD

This is the subject's whole contribution, and its central property is that **all selection
happens at compile time, against the global target**. There is no `cpuid` call in the library.
That has a consequence for runtime dispatch that the README does not state:

- **`@target` does not reach the `static if` ladder.** `LDC_with_AVX2` is evaluated once, from the
  command-line `-mattr`. **Verified:** in a module compiled for baseline x86-64, a function marked
  `@target("avx2")` that calls `_mm256_i32gather_epi32!4` compiled to 24 instructions of
  `vpinsrd`/`movslq` lane inserts instead of `vpgatherdd`, and `_mm256_permutevar8x32_epi32` to
  36 instructions instead of `vpermps`. Compiled with `-mattr=+avx2`, the same bodies were 7 and 5
  instructions. Simple splits can be re-fused by LLVM: `_mm256_madd_epi16` under `@target("avx2")`
  became one `vpmaddwd ymm` even in the baseline module. Whether a given intrinsic survives
  `@target` depends on its fallback body, not on the intrinsic.
- **The vector ABI changes with the target.** In the same experiment, the baseline `__m256i`
  function took its arguments in `xmm0`–`xmm3` and the `@target("avx2")` one in `ymm0`–`ymm1`. A
  dispatch boundary that passes 256-bit vectors by value is therefore unsafe; one that passes
  pointers or slices is not affected.
- **So per-ISA kernels need per-ISA compilation units.** Runtime dispatch with this library means
  building the kernel module several times with different `-mattr` (separate object files or dub
  configurations, with mangled names kept apart) and choosing a function pointer at start-up. That
  is the job [Highway](./highway.md) and [Simd](./simd.md) do inside the library; here it is the
  caller's. The Sparkles BLAKE3 precedent uses `@target` over LLVM's generic vectors instead
  ([baseline: host SIMD](./baseline/shaders-simd.md)), which is exactly the combination the first
  bullet shows not composing with intel-intrinsics' ladders.
- **The ISA floor is a product decision.** The README recommends SSE3 for consumer software, since
  "it's reach-limiting for consumer target to target above SSE4.2" ([README L129-L136][readme-reach]),
  and the AVX2 header notes it "will work whether you have AVX2 enabled or not"
  ([`avx2intrin.d` L12-L21][avx2-head]).
- **Coverage ends at AVX2 and NEON.** No AVX-512, no AVX10 (out of scope by policy), no SVE (one
  comment mentions SVE2 as a possibility, [`avxintrin.d` L2681][sve]), and no RISC-V V. WebAssembly
  SIMD is partial: [`wasm-progress.md`][wasm] counts "934 intrinsics" and 351 done. AArch64 lanes
  are fixed at 128 bits, so `_mm256_*` on Apple silicon is always two NEON operations.
- **Toolchain fragility.** The library calls LLVM's `__builtin_ia32_*` names directly, and those
  names come and go with LLVM. **Verified:** LDC 1.43.0 does not build the library for x86-64:
  `__builtin_ia32_pmulhw128` and `__builtin_ia32_pmulhuw128` are undefined at baseline, the four
  `__builtin_ia32_round{ps,pd,ss,sd}` add to them with `-mattr=+sse4.2`, and
  `__builtin_ia32_{pmulhw,pmulhuw,roundps,roundpd}256` with `-mattr=+avx2` (ten in all). The AArch64 build and DMD are unaffected; DMD ran all 14 modules'
  unittests. The CI matrix stops at `ldc-1.41.0` and `ldc-latest`
  ([`x86_64.yml` L8-L22][ci]). The same failure stopped LDC builds of
  [Gamut](./gamut.md) and [Dplug graphics](./dplug-graphics.md) in this catalog. LDC 1.32.0 had the
  opposite problem, "NO builtins at all", which the library detects and warns about
  ([`internals.d` L286-L295][int-ldc132]).
- **DMD is the slow path for image-shaped integer work.** **Verified:** with `dmd -O -inline
-release`, `_mm_mulhi_epi16` is eight scalar `imul`s (it has no `DMD_with_DSIMD` branch) and
  `_mm_madd_epi16` stays an out-of-line call to its scalar loop. `DMD_with_DSIMD` appears only in
  the SSE to SSSE3 modules and `internals.d`, never in the SSE4.1, SSE4.2, AVX or AVX2 modules.

### 10. Testing and conformance

Every intrinsic has a unittest beside it (866 `unittest` blocks across the modules), written
against the Intel guide's semantics, and the oracle rule is explicit: "When the guide and the
instruction disagree, we look at what C++ compilers do" ([`CONTRIBUTING.md` L7-L10][contrib-sem]).
The build types multiply each test run across instruction-set floors (`unittest-below-avx`,
`unittest-inst` with `-mcpu=native`) and targets (`unittest-arm64` via `-mtriple`)
([`dub.json`][dub]); [`test.sh`][test-sh] runs eight LDC combinations of build type and
architecture, its AArch64 runs through `-a arm64-apple-macos`. What the tests do not do is compare
the paths of one intrinsic against each other: each build exercises only the path its flags select,
and most tests check a handful of hand-picked lanes. The repository's own audit lists the gaps
this leaves ([`TODO.txt`][todo]):

- `_mm256_extract_epi8` "sign-extends instead of zero-extending" ([`TODO.txt` L87-L92][todo-ext]).
  **Verified** under DMD: a lane holding 200 reads back as `-56` from `_mm256_extract_epi8` and as
  `200` from `_mm_extract_epi8`. Its unittest stores `-44`, which hides the bug.
- `_mm_round_ps` and friends in the non-SSE4.1 fallback lose NaN and integral values above 2^31
  ([`TODO.txt` L16-L22][todo-round]). **Verified** under DMD: `_mm_round_ps!0x08` of
  `[3e9, NaN, 2.5, -2.5]` gives `[-2.14748e+09, -2.14748e+09, 2, -2]`.
- The AArch64 `_mm_ceil_*`/`_mm_floor_*` paths "round-trip through saturating int conversion"
  ([`TODO.txt` L7-L14][todo-ceil]); not run here (no AArch64 execution).

A smaller trap: `import inteli;` makes `_MM_FROUND_TO_NEAREST_INT` and `_MM_FROUND_NO_EXC`
ambiguous, because both [`smmintrin.d`][round-sse] and `avxintrin.d` define them (**verified**,
DMD).

Not covered: 1, 3, 4, 8, 9.

## Lessons for Sparkles

- **Q3** One API that is the same on x86 and AArch64 is achievable in D from a single source, and
  the per-intrinsic `static if` ladder with an inline-IR middle tier is how this library gets
  three-instruction NEON sequences for `pmaddwd`-style work. It transfers as a technique; adopting
  the library itself ties a kernel to Intel's 128/256-bit lane shapes.
- **Q3, Q7** Compile-time selection does not compose with `@target`. If image kernels need runtime
  dispatch in a `checked` build with no native CPU requirement, either the kernel module is compiled
  once per ISA (and the dispatch boundary passes memory, never vectors by value), or kernels are
  written over LLVM generic vectors as the BLAKE3 backend is. [Highway](./highway.md) and
  [Simd](./simd.md) are the per-target-with-dispatch alternatives to compare against.
- **Q3** The baseline's shared SIMD capability gap (G5 in the
  [host-SIMD baseline](./baseline/shaders-simd.md)) is not filled by this library: it has no runtime
  probe and no backend enum, only compile-time booleans.
- **Q8** Each code path of an intrinsic is a separate implementation and needs a differential test
  against the others, run on full input ranges (all 256 values of a byte lane, NaN and large
  floats). Hand-picked lanes let `_mm256_extract_epi8` ship sign-extended.
- **Q4, Q8** Allocation helpers that take sizes from headers need checked arithmetic;
  `_mm_malloc` shows the unchecked form.
- **Q9** Direct use of `__builtin_ia32_*` names makes a dependency break on compiler upgrades; with
  this repository's own LDC fork, a library depending on intel-intrinsics would currently not build
  for x86-64. Owning the SIMD layer (or a thin one over generic vectors) avoids that external pin.
- **Q7** No AVX-512 and no SVE by policy: a Sparkles path that wants AVX-512 for image work (the
  text code already uses it) cannot get it here.

## Strengths

- One source for DMD, LDC and GDC, and for x86, AArch64, 32-bit ARM and (partly) WebAssembly.
- Semantics fixed by a public reference (the Intel guide), so kernels port from C and C++ directly.
- Good AArch64 code for the integer operations image kernels use (verified for `pmaddwd`,
  `pmulhw`, `pavgb` equivalents).
- `nothrow @nogc` throughout, with a `USE_NURT` version that takes `malloc`, `free` and `memcpy`
  from numem.
- An explicit contributor process: Godbolt every commit, one unittest per intrinsic, a slow path
  for every compiler.

## Weaknesses

- Selection is compile-time only; `@target`-based runtime dispatch silently gets fallback bodies.
- Does not build with LDC 1.43.0 for x86-64 at this revision (removed LLVM builtins).
- Scope ends at AVX2 and 128-bit NEON: no AVX-512, AVX10, SVE or RVV.
- DMD codegen is scalar for much integer SIMD, and non-template functions need cross-module
  inlining to be fast on LDC.
- Known semantic bugs listed in the repository's own audit, some unexercised by its tests.
- `@trusted` pointer loads and an unchecked `_mm_malloc` size.

## Sources

- intel-intrinsics source at `2141185c60cb166c79970d624b22d61fc980a96d`:
  [`README.md`][readme-intro], [`CONTRIBUTING.md`][contrib], [`dub.json`][dub],
  [`test.sh`][test-sh], [`TODO.txt`][todo], [`wasm-progress.md`][wasm],
  `source/inteli/{internals,types,emmintrin,xmmintrin,smmintrin,tmmintrin,avxintrin,avx2intrin}.d`.
- [Intel Intrinsics Guide][intel-guide].
- Scratch experiments (not in the repository): unittest builds with DMD and LDC, LDC assembly for
  `aarch64-linux-gnu` and `x86_64-linux-gnu` with and without `-mattr=+avx2` and `@target("avx2")`,
  and DMD runs of `_mm256_extract_epi8`, `_mm_round_ps` and `_mm_malloc`.
- Related deep-dives: [Gamut](./gamut.md), [Dplug graphics](./dplug-graphics.md),
  [Highway](./highway.md), [Simd](./simd.md), [baseline: shaders, math and host SIMD](./baseline/shaders-simd.md).

<!-- References -->

[repo]: https://github.com/AuburnSounds/intel-intrinsics/tree/2141185c60cb166c79970d624b22d61fc980a96d
[intel-guide]: https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html
[dub]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/dub.json#L1-L50
[readme-intro]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/README.md#L9-L13
[readme-philo]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/README.md#L46-L49
[readme-types]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/README.md#L70
[readme-why]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/README.md#L117
[readme-reach]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/README.md#L129-L136
[readme-arm]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/README.md#L148-L160
[readme-diff]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/README.md#L162-L166
[contrib]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/CONTRIBUTING.md#L17
[contrib-sem]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/CONTRIBUTING.md#L7-L10
[contrib-merge]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/CONTRIBUTING.md#L35-L39
[test-sh]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/test.sh#L1-L10
[ci]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/.github/workflows/x86_64.yml#L8-L22
[todo]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/TODO.txt#L1-L185
[todo-ceil]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/TODO.txt#L7-L14
[todo-round]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/TODO.txt#L16-L22
[todo-ext]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/TODO.txt#L87-L92
[wasm]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/wasm-progress.md#L1-L13
[int-nurt]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/internals.d#L19-L33
[int-gdc]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/internals.d#L55-L161
[int-gdc-probe]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/internals.d#L102-L110
[int-wasm]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/internals.d#L231
[int-ldc-arm]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/internals.d#L260-L281
[int-ldc-x86]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/internals.d#L283-L327
[int-ldc132]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/internals.d#L286-L295
[int-dmd]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/internals.d#L401-L430
[int-neon]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/internals.d#L2007-L2080
[types-dmd]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/types.d#L84-L125
[types-ops]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/types.d#L131-L200
[types-alias]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/types.d#L451-L457
[avg]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/emmintrin.d#L411-L459
[madd]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/emmintrin.d#L2351-L2393
[loadu]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/emmintrin.d#L2242
[loadu-ps]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/xmmintrin.d#L1420
[storeu]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/emmintrin.d#L5004
[malloc]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/xmmintrin.d#L1474-L1482
[setcsr]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/xmmintrin.d#L2428-L2452
[malloc-size]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/xmmintrin.d#L3142-L3146
[malloc-store]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/xmmintrin.d#L3149-L3161
[round-sse]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/smmintrin.d#L27-L33
[sve]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/avxintrin.d#L2681
[avx2-head]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/avx2intrin.d#L12-L21
[madd256]: https://github.com/AuburnSounds/intel-intrinsics/blob/2141185c60cb166c79970d624b22d61fc980a96d/source/inteli/avx2intrin.d#L2783-L2804
