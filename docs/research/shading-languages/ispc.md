# ISPC (C dialect / Intel)

The Intel Implicit SPMD Program Compiler: a C-based SPMD language whose program instances are mapped onto the lanes of CPU SIMD units, with an execution mask, `uniform`/`varying` types and maximal convergence defined in the language, which makes it the reference design for running shader-shaped code on a CPU.

| Field          | Value                                                                                                                                                                                                     |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | ISPC: C99 plus `uniform`/`varying`, `foreach`, `cif`, `launch`/`sync`, `soa<N>`, references, templates, operator overloading                                                                              |
| License        | BSD-3-Clause ([`README.md`][readme])                                                                                                                                                                      |
| Repository     | [ispc/ispc][repo] (pinned `553b773f`, 2026-10-16)                                                                                                                                                         |
| Documentation  | [User's Guide `docs/ispc.rst`][guide] (8,096 lines); [Performance Guide `docs/perfguide.rst`][perfguide]; [ISPC for Xe][xe]; Pharr and Mark, [InPar 2012 paper][paper]; Pharr, [The Story of ISPC][story] |
| Key authors    | Matt Pharr and William R. Mark (original design, Intel, 2010–2011); Intel compiler team since                                                                                                             |
| Category       | Single-source peer: SPMD-on-SIMD for CPUs (and Intel GPUs), C-ABI-linked with the host program                                                                                                            |
| Latest version | `v1.32.0`, 13 October 2026, "Based on a patched LLVM 23.1.2" ([`docs/ReleaseNotes.txt`][relnotes])                                                                                                        |
| Targets        | x86 SSE2–AVX10.2, ARM NEON, Intel Xe GPUs (SPIR-V or zebin); off by default: RISC-V RVV, ppc64le, WebAssembly, a `generic` target ([`CMakeLists.txt`][cmake], [`src/target_enums.h`][enums])              |
| Gang sizes     | 4, 8, 16, 32, 64 (target-dependent): `avx2-i32x8` is AVX2 with a 32-bit mask and 8 instances; `avx512skx-x16` uses AVX-512 hardware masks                                                                 |
| Graphics       | None: no stages, no textures, no derivatives, no interface variables                                                                                                                                      |

> [!NOTE]
> ISPC is not a shading language and does not try to be one. It is in this catalog
> because sparkles plans an SPMD-on-SIMD CPU executor for shaders (after the scalar
> reference simulator), and ISPC is the most complete, longest-lived, production
> implementation of exactly that lowering. Everything below that concerns graphics is a
> gap analysis, not a feature description.

---

## Overview

### What it solves

Compilers do not reliably auto-vectorize serial code into SIMD, and intrinsics are
unreadable and non-portable across vector widths. GPU programmers had a model that
worked: write the program for one element and let the hardware run many in lockstep.
ISPC brings that model to the CPU. A function is written for one _program instance_;
a _gang_ of instances (4–64) executes it together on the SIMD lanes of one core, with no
threads created. The compiler, not the hardware, is responsible for divergence: it
keeps an _execution mask_ and emits both sides of a varying branch under it. Cores are
used through a separate task model (`launch`/`sync`).

The original motivation is stated in Pharr's account of the project: the auto-vectorizer
of the time would "fail unpredictably", and "as long as vectorization can fail (and it
will) … you must come to deeply understand the auto-vectorizer" ([The Story of ISPC][story]).
ISPC makes vectorization a property of the language rather than of an optimizer's
heuristics: every `varying` operation is a vector operation by construction.

### Design philosophy

From [`README.md`][readme]:

> _"To provide a thin abstraction layer between the programmer and the hardware--in
> particular, to have an execution and data model where the programmer can cleanly
> reason about the mapping of their source program to compiled assembly language and
> the underlying hardware."_

And on the relation to shaders, from the [User's Guide][guide] (§ Basic Concepts):

> _"An `ispc` program instance is thus similar to a CUDA\* "thread" or an OpenCL\*
> "work-item", and an `ispc` gang is similar to a CUDA\* "warp". … This implicit model
> is the same as that used for shaders in programmable graphics pipelines, OpenCL\*
> kernels, and CUDA\*."_

Three choices follow and run through every section below: variability is a **type
qualifier** checked by the front end, not a property inferred by analysis; control flow
is **maximally converged** by definition; and the host ABI is **C**, so data is shared
by pointer with no copies.

---

## How it works

### Program instances, gangs and the mask

```c
// ispc — each instance computes one element; the gang computes programCount of them
export void scale(uniform float vin[], uniform float vout[], uniform int count) {
    foreach (index = 0 ... count) {
        float v = vin[index];          // varying: one value per lane
        if (v < 3.)                    // varying test: both arms may run, masked
            v = v * v;
        else
            v = sqrt(v);
        vout[index] = v;               // masked (or blended) store
    }
}
```

`programCount` is `static const uniform int32 programCount = TARGET_WIDTH;` and
`programIndex` is a varying constant initialised to `{0, 1, …}`
([`stdlib/include/core.isph`][core]). Everything not marked `uniform` is `varying`
and lowers to an LLVM vector `<WIDTH x T>`. The mask is a vector of `MASK`-sized
integers on targets without hardware predication (the m4 macros `WIDTH` = 8 and
`MASK` = `i32` in [`builtins/target-avx2-i32x8.ll`][avx2]) and `i1` lanes
(k-registers) on AVX-512 and Xe.

The guide defines the semantics with a single gang-wide program counter and a
per-instance mask ([`docs/ispc.rst`][guide], § Control Flow Within A Gang):

> _"1. The program counter will have a sequence of values corresponding to a
> conservative execution path through the function, wherein if any program instance
> wants to execute a statement, the program counter will pass through that statement. 2. At each statement the program counter passes through, the execution mask will be
> set such that its value for a particular program instance is "on" if and only if the
> program instance wants to execute that statement."_

### The masking is done in the front end

ISPC does **not** emit scalar LLVM IR and ask a vectorizer to widen it. Its front end
(`FunctionEmitContext`, [`src/ctx.h`][ctxh]) emits vector IR directly from the AST and
keeps the mask as explicit state:

| State (`src/ctx.h`)        | Meaning                                                                             |
| -------------------------- | ----------------------------------------------------------------------------------- |
| `functionMaskValue`        | mask at function entry; arrives as a hidden trailing `__mask` parameter             |
| `internalMaskAddressInfo`  | mask contributed by varying control flow inside the function                        |
| `fullMaskAddressInfo`      | `function & internal`, the mask side effects obey (`GetFullMask`)                   |
| `breakLanesAddressInfo`    | lanes that executed `break` in the current loop iteration                           |
| `continueLanesAddressInfo` | lanes that executed `continue`; restored at the loop step (`RestoreContinuedLanes`) |
| `returnedLanesAddressInfo` | lanes that have executed `return`                                                   |
| `blockEntryMask`           | mask at the top of the loop body, compared against finished lanes                   |

Every non-`unmasked`, non-`export` function takes the mask as its last LLVM argument
(`llvmArgTypes.push_back(LLVMTypes::MaskType)` in `FunctionType::LLVMArgumentTypes`,
[`src/type.cpp`][typecpp]); an `export` function called from C starts with
`SetFunctionMask(LLVMMaskAllOn)` ([`src/func.cpp`][funccpp]).

---

## Execution model and stages

There is one execution model: a gang running an SPMD function, called from C/C++. No
pipeline stages exist; the nearest analogue of a compute dispatch is
`launch[n] f(...)`, which queues `n` tasks to a user-replaceable task system
(`ISPCLaunch`/`ISPCSync`/`ISPCAlloc`), each running a whole gang. `taskIndex` and
`taskCount` play the role of workgroup IDs.

The defining guarantee is **maximal convergence** ([`docs/ispc.rst`][guide], § Gang
Convergence Guarantees):

> _"Maximal convergence means that if two program instances follow the same control
> path, they are guaranteed to execute each program statement concurrently. If two
> program instances follow diverging control paths, it is guaranteed that they will
> reconverge as soon as possible in the function (if they do later reconverge)."_

The guide spells out the consequences: an 8-wide gang may not be run as two 4-wide
halves; `if (programIndex == 0) while (true);` hangs the whole gang; a varying function
pointer call groups lanes by pointer value and calls each target once. The paper adds
that "this property also can introduce a dependency on SIMD width; by definition,
ordering changes if the gang size changes" ([Pharr and Mark][paper], §3).

What ISPC lacks, measured against [the shader execution model][concepts-exec]:

| Shader concept                        | ISPC                                                                                     |
| ------------------------------------- | ---------------------------------------------------------------------------------------- |
| Invocation / subgroup                 | program instance / gang (gang size fixed at compile time per target)                     |
| Workgroup + `barrier()`               | **absent**; no shared-memory barrier across gangs; tasks only `sync` at the launch level |
| Quad, helper invocations, derivatives | **absent**                                                                               |
| `discard` / `demote`                  | **absent**; a masked `return` is the nearest thing                                       |
| Graphics stages, interface variables  | **absent**                                                                               |

A CPU executor for fragment shaders therefore has to add, on top of ISPC's model,
quad-aligned lane groups, helper lanes that keep computing after `demote`, and
derivative operations over them (see [Derivative][concepts-deriv] and
[Helper invocation][concepts-helper]).

## Type system and generic programming

- **Variability is a qualifier on every type.** `uniform int` is a scalar shared by the
  gang; `int` (`varying`) is a vector. `uniform` converts implicitly to `varying`;
  the reverse is a compile-time error. Arrays carry the variability of their elements
  (`uniform float bar[10]` is 10 floats; `float foo[10]` is 10 gang-wide vectors).
- **Pointers have two variabilities.** _"pointers are `varying` by default … However,
  the default variability of the pointed-to type is `uniform`"_ ([guide][guide],
  § Pointer Types). `float *p` is a vector of pointers to scalars (a gather/scatter);
  `varying float * uniform pf` is one pointer to a gang-wide vector (a vector
  load/store). Casting a varying pointer to a uniform one is forbidden.
- **Structs are AoS in memory, SoA by lane in registers.** A `varying struct Node` has
  each member widened, and the generated C header shows it as
  `struct Node { int count[8]; float pos[3][8]; };` for an 8-wide target
  ([guide][guide], § Data Layout).
- **`soa<N>`** rewrites a struct array into hybrid SoA (`soa<8> Point pts[...]` is
  `struct { uniform float x[8], y[8], z[8]; }` per element block) while indexing stays
  AoS-shaped.
- **Short vectors `float<3>`** are explicitly _not_ a vectorization device: _"`ispc`
  does not use these short vectors to facilitate program vectorization; they are purely
  a syntactic convenience"_ ([guide][guide], § Short Vector Types). A `varying float<3>`
  is three gang-wide vectors. `uniform` short vectors are stored at the natural vector
  alignment, so their layout differs between targets and the guide warns against
  sharing them with C.
- **Generics:** function templates with type and non-type parameters (the length of
  `float<N>` may be a template parameter), operator overloading, and overload
  resolution whose cost ladder includes _"promotions from uniform to varying types"_ as
  explicit ranks ([guide][guide], § Function Overloading).

## Resources, interfaces and memory layout

There are no descriptors, bindings or buffer blocks: an `export` function takes C
pointers and C structs, and `ispc -h` writes the matching C header. Varying values may
cross the boundary only behind a pointer (`varying float * uniform`), and with
multi-target compilation such pointers become `void *` in the general header because
the gang width is chosen at run time. Layout is C layout by design: _"`ispc` tries to
ensure that `struct` types and other complex data types are laid out in the same way in
memory as they are in C/C++"_ ([guide][guide], § Data Layout). There is no std140 or
std430.

Memory operations are where the vector model costs. A varying index or pointer
produces a gather or scatter, emitted first as a pseudo-op
(`__pseudo_gather32_float`, `__pseudo_masked_store_i32`; [`src/ctx.cpp`][ctxcpp]) and
then improved by late passes:

| Pass ([`src/opt.cpp`][optcpp] order) | Job                                                                                                                         |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| `ImproveMemoryOpsPass`               | turn an array of pointers into base + offsets; detect uniform or consecutive addresses → plain vector loads ([header][imo]) |
| `ReplacePseudoMemoryOpsPass`         | remaining pseudo-ops → native gather/scatter or per-lane scalar code; masked stores to stack allocas → load-blend-store     |
| `IntrinsicsOpt`                      | fold `movmsk` of constants; `blendv`/masked load-store with all-on or all-off masks → plain ops ([header][iopt])            |
| `GatherCoalescePass`                 | split all-on 32-bit gathers into wide loads + shuffles; coalesce across gathers (helps AoS) ([header][gcp])                 |
| `ReplaceMaskedMemOpsPass`            | shorten masked loads/stores when only part of the vector is used                                                            |

The blend choice is explicit in [`ReplacePseudoMemoryOps.cpp`][rpmo]: _"We need to
choose between doing the load + blend + store trick, or serializing the masked store.
Even on targets with a native masked store instruction, this is preferable since it lets
us keep values in registers rather than going out to the stack."_ It is only legal for
memory the gang owns (a stack `alloca` of at least the stored width); a store through
a user pointer stays a true masked store, because a blend would write lanes that are off.

## Built-in library and intrinsics

The standard library ([`stdlib/stdlib.ispc`][stdlib]) is written in ISPC over a
target-specific builtin layer in m4-templated LLVM IR (`builtins/target-*.ll`); the
[target redesign document][redesign] describes the split into dispatcher,
target-independent and target-dependent parts, shipped as bitcode. The cross-lane
vocabulary, which is what a shader's subgroup operations lower to on a CPU:

| Group                | Functions ([guide][guide], § Cross-Program Instance Operations, § Reductions)                          | Shader counterpart                                          |
| -------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| Mask queries         | `lanemask()`, `any`, `all`, `none`, `popcnt(bool)`, `packmask`                                         | `subgroupBallot`, `subgroupAny/All`, `WaveActiveCountBits`  |
| Lane movement        | `broadcast(v, uniform i)`, `rotate`, `shift`, `shuffle(v, perm)`, two-source `shuffle`                 | `subgroupBroadcast`, `subgroupShuffle*`                     |
| Extract / insert     | `extract(x, uniform i)`, `insert`                                                                      | `subgroupBroadcast` with a constant lane                    |
| Reductions and scans | `reduce_add/min/max`, `reduce_equal`, `exclusive_scan_add/and/or`                                      | `subgroupAdd`, `subgroupExclusiveAdd`, `WaveActiveAllEqual` |
| Compaction           | `packed_store_active`, `packed_load_active`                                                            | none (stream compaction is done with ballot + prefix)       |
| Atomics              | `atomic_*_global` and `atomic_*_local` (atomic across the gang only), `memory_barrier`                 | `atomicAdd` at device / subgroup scope                      |
| Math                 | full libm surface, SVML or ISPC implementations, `--math-lib`, half and sRGB8 conversions, `pdep/pext` | GLSL.std.450                                                |

All reductions act on the **active** lanes, which is the same contract as SPIR-V's
non-uniform group operations. There is no texture sampling, no image type and no
derivative function.

## Control flow, memory model and restrictions

This is the part sparkles must reproduce, so it is given in full.

**`if`.** A `uniform` test emits an ordinary branch. A `varying` test goes through
`IfStmt::emitVaryingIf` ([`src/stmt.cpp`][stmt]), which picks one of three shapes:

1. _Straight-line, both arms under the mask_ (`emitMaskedTrueAndFalse`) when both arms
   are cheap (`EstimateCost` below `PREDICATE_SAFE_IF_STATEMENT_COST`) **and**
   `SafeToRunWithMaskAllOff`, so that an all-off arm has no observable effect. The
   comment gives the counter-example: `if (index < count) array[index] = 0;` must not
   be run unguarded.
2. _Mixed_ (`emitMaskMixed`): set `mask = old & test`, branch on `any(mask)` around the
   true arm, set `mask = old & ~test`, branch on `any(mask)` around the false arm,
   restore.
3. _Coherent_ (`cif`): first branch on `all(fullMask)`; if all lanes are on,
   `emitMaskAllOn` tests `all(test)` → true arm only with the mask _known_ all-on,
   `!any(test)` → false arm only, otherwise both arms masked. Setting the mask to the
   constant `LLVMMaskAllOn` inside the specialised path is what lets later passes turn
   masked memory operations into plain ones.

**Loops.** `for`/`while`/`do` with a uniform test and no varying `break`/`continue`
inside (`lHasVaryingBreakOrContinue`) are scalar loops. Otherwise the test is folded into
the mask (`SetInternalMaskAnd(mask, test)`) and the loop runs while `BranchIfMaskAny`
holds. `break` and `continue` under varying control flow do not jump: they OR the
current mask into `breakLanes`/`continueLanes` and set the mask to all-off
(`FunctionEmitContext::Break`/`Continue`, [`src/ctx.cpp`][ctxcpp]). At the loop step,
`RestoreContinuedLanes` re-enables continued lanes and `ClearBreakLanes` resets the
per-iteration record. The coherent forms (`cfor`, `cwhile`, `cdo`, and a coherent
`break`) add `jumpIfAllLoopLanesAreDone`, which compares
`returned | breaked | continued` against `blockEntryMask` and jumps out early when every
lane is finished. A loop whose test is varying is the case that costs most: the guide's
example runs 1000 iterations with one lane on.

**`return`.** A varying `return` writes the return value with a masked store into the
return slot (_"this preserves the return values from other lanes that may have executed
return statements previously"_, `CurrentLanesReturned`), records the lanes in
`returnedLanes`, and continues execution with them off. Only when there is no varying
control flow between the statement and the function entry does it emit a real `ret`.

**`foreach`.** `foreach (j = 0 ... h, i = 0 ... w)` maps a domain onto the gang. The
emitter ([`ForeachStmt::EmitCode`][stmt]) treats the inner dimension specially: it
runs from `start` to `alignedEnd` with the mask **all on** for that dimension (and
with a separate code path depending on whether any outer dimension is in its ragged
tail), then runs one masked iteration for the "ragged extra bits". `foreach_tiled`
picks spans across dimensions (`lGetSpans`) for coherence over locality. `break`,
`return` and nested `foreach` are illegal; `continue` is allowed.

**Serialising constructs.** `foreach_active (i)` runs the body once per active lane
with only that lane on (`continue` legal, order undefined); `foreach_unique (v in x)`
runs it once per distinct value with the matching lanes on; `unmasked { }` and the
`unmasked` function qualifier restore all lanes, used to "change the axis of
parallelism". `goto` is legal only where no varying control flow encloses it.

**Memory model inside a gang.** There are no barriers: _"any side effect from one
program instance is visible to other program instances in the gang after the next
sequence point in the program"_ ([guide][guide], § Data Races Within a Gang). Two lanes
storing to one address without an intervening sequence point is undefined; `local`
atomics serialise it. A `uniform` variable assigned under varying control flow is
**not** masked, so its value depends on whether _any_ lane took the path. Loops with
non-constant conditions are assumed to terminate; `for (;;)` and `while (1)` are not.

**What the dynamic checks buy.** The paper measures each optimisation by disabling it
(geomean over the shipped workloads, [Pharr and Mark][paper], Table 1):

| Disabled optimisation         | Performance when disabled |
| ----------------------------- | ------------------------- |
| Uniform data and control flow | 0.45x                     |
| Uniform control flow          | 0.91x                     |
| Gather/scatter improvements   | 0.79x                     |
| Coherent control flow         | 0.85x (aobench 0.33x)     |
| "All on" mask improvements    | 0.73x                     |

## Compilation pipeline and targets

```text
.ispc ─► preprocessor ─► parser (parse.yy) ─► AST + type check
      ─► FunctionEmitContext: vector LLVM IR with explicit masks and __pseudo_* memory ops
      ─► link builtins bitcode (target-*.ll, stdlib.ispc) for the chosen target/width
      ─► ISPC passes interleaved with LLVM's (opt.cpp): ImproveMemoryOps,
         ReplacePseudoMemoryOps, IntrinsicsOpt, GatherCoalesce, ReplaceMaskedMemOps, …
      ─► LLVM CodeGen ─► .o / .s / .bc   (Xe: SPIR-V via SPIRV-LLVM-Translator, or zebin)
      + C header (-h) describing exported functions and structs
```

A target string is `[ISA]-i[mask bits]x[gang size]` without hardware masks
(`avx2-i32x8`, `sse4.2-i8x16`) and `[ISA]-x[gang size]` with them (`avx512skx-x16`,
`xehpg-x16`). The guide recommends _"a mask size equal to the size of the most common
data type in your programs"_. Several targets can be built into one object with a CPUID
dispatcher (`builtins/dispatch.c`). ISPC carries LLVM patches in `llvm_patches/` and
builds against a pinned LLVM. For Xe, the default output is SPIR-V for the Intel VC
backend: _"The output from `ispc` for Xe targets is SPIR-V file by default"_
([`docs/ispc_for_xe.rst`][xe]), produced with `LLVMSPIRVLib` ([`src/module.cpp`][modulecpp]);
there, `emitXeHardwareMask()` replaces software masking with the hardware execution
mask through CM `simdcf` intrinsics. That SPIR-V is OpenCL-flavoured kernel SPIR-V, not
Vulkan shader SPIR-V.

## Host integration and CPU execution

CPU execution is ISPC's whole purpose, so the interesting question is the integration.
An `export` function is an ordinary C symbol: _"Functions that are intended to be called
from C/C++ application code must have the `export` qualifier. This causes them to have
regular C linkage"_ ([guide][guide], § Functions and Function Calls). Calls are direct,
data is shared by pointer, and the application owns threading. `extern "C"` goes the
other way (ISPC calling C, once per active lane via `foreach_active` or with uniform
arguments). `ispcrt` adds a runtime that hides CPU vs Level Zero devices, and
`extern "SYCL"` gives a SYCL-ABI-compatible entry ([guide][guide], § Interoperability
Overview). There is also a JIT library interface (`ISPCEngine`).

Debugging is native: the program is a CPU binary, `gdb` steps it, and `print` prints
per-lane values with inactive lanes shown "inside double parenthesis" ([guide][guide], § Output Functions).

## What an LLVM-level whole-function vectorizer would need to reproduce

sparkles' D shaders reach LLVM as **scalar per-invocation IR** from LDC. An
SPMD-on-SIMD CPU executor therefore cannot use ISPC's approach (masking in the front
end); it has to recover what ISPC knows from types by analysis over the IR, as a
whole-function vectorizer (WFV) does. Upstream LLVM has no such pass: its loop and SLP
vectorizers do not widen a function body over an implicit lane dimension, although
`VFABIDemangler.cpp` lets the loop vectorizer _call_ vector variants that something else
produced ([`llvm/lib/IR/VFABIDemangler.cpp`][vfabi]). The research vectorizer
[RV][rv-readme] (Saarland, LLVM-based, PLDI 2018 partial linearization) is the closest
open implementation, and it maps onto ISPC piece by piece:

| ISPC mechanism                                       | WFV equivalent over scalar IR                                                                                                                                        | Prior art                                                                                                |
| ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `uniform` / `varying` qualifiers                     | divergence analysis from the thread-ID builtins outward, plus a stride lattice (uniform, contiguous, strided, varying) per value                                     | RV `VectorShape` ([`vectorShape.h`][rv-shape]); LLVM [`UniformityAnalysis`][uniformity]                  |
| varying pointer → gather, uniform base → vector load | address shape analysis: `strided(1)` addresses become one vector load; others gather                                                                                 | RV shapes; ISPC `ImproveMemoryOpsPass` after the fact                                                    |
| execution mask state per block                       | block and edge predicates materialised as `i1` vectors                                                                                                               | RV `maskExpander`                                                                                        |
| `emitMaskMixed` / `emitMaskedTrueAndFalse`           | **partial linearization**: keep uniform branches, linearize divergent ones into a schedule with selects for φ-nodes                                                  | RV `Linearizer` ([header][rv-lin], "Convertes divergent branches to data flow")                          |
| `breakLanes` / `continueLanes`, loop until `any`     | divergent-loop transform: a live mask φ, per-exit trackers that tunnel live-out values through "tracker PHI nodes", one uniform exit                                 | RV `guardedDivLoopTrans.h` ([header][rv-loop])                                                           |
| `returnedLanes` + masked store to return slot        | merge all returns into one block before linearizing                                                                                                                  | RV `singleReturnTrans.h` ("needed for linearization in case there is control divergence around returns") |
| `SafeToRunWithMaskAllOff`, `any(mask)` guards        | proof that a block has at least one live lane, else guard it                                                                                                         | RV `UndeadMaskAnalysis` ([header][rv-undead])                                                            |
| `cif` / `cfor`: all-on fast path                     | BOSCC-style dynamic checks that branch to an all-on clone; a constant all-on mask in the clone                                                                       | ISPC only; RV leaves it to the client                                                                    |
| masked store vs load-blend-store                     | the same choice, keyed on whether the target memory is lane-private (`alloca`) or shared                                                                             | ISPC `ReplacePseudoMemoryOpsPass`                                                                        |
| hidden `__mask` parameter, `unmasked` functions      | vector function variants with a mask argument (VFABI `M` variants) and uniform-argument specialisation; inlining by default                                          | VFABI, RV's former WFV mode                                                                              |
| varying function pointer → once per unique target    | a `foreach_unique`-style loop over distinct callees                                                                                                                  | ISPC                                                                                                     |
| maximal convergence                                  | a reconvergence point per divergent region equal to its immediate post-dominator; convergent operations (subgroup ops) placed by **convergence tokens** when present | LLVM [`ConvergenceAndUniformity.rst`][convergence], [`ConvergentOperations.rst`][convergent]             |
| cross-lane library (`broadcast`, `reduce_add`, …)    | `llvm.spv.*` / druntime subgroup intrinsics lowered to shuffles and reductions over the **active** lanes                                                             | RV `rv_ballot`, `rv_shuffle`, `rv_compact` ([`intrinsics.def`][rv-intr])                                 |

Three things neither ISPC nor RV provides, and a shader executor needs:

1. **Quads and helper lanes.** Fragment derivatives (`dFdx`, implicit-LOD sampling) are
   differences across a 2×2 quad. Lanes must be quad-aligned, helper lanes outside the
   primitive must execute (with stores suppressed), and `discard` must behave like
   `demote` so neighbours still have values. The mask therefore splits into
   _active-for-side-effects_ and _alive-for-derivatives_.
2. **Workgroup barriers.** A compute workgroup larger than one gang with
   `barrier()` needs region splitting around the barrier (continuation-based
   synchronization, loop fission) or fibers. ISPC has no such construct; SYCL CPU
   implementations do (see [SYCL][sycl]).
3. **Defined subgroup width.** ISPC fixes the gang at compile time and lets results
   depend on it. Shaders that query `gl_SubgroupSize` must see the executor's width, and
   a conformance corpus must run at several widths to catch width-dependent code.

Structured input makes items 1–3 easier: if the D front end emits structured control
flow (the recommendation in [MLIR SPIR-V][mlir-spirv]), the linearization is a walk
over regions, as in ISPC, instead of a CFG analysis, as in RV.

## Lessons for sparkles:shaders

- **Adopt ISPC's semantics as the CPU executor's contract**: one program counter per
  gang, an execution mask, maximal convergence, reconvergence at the immediate
  post-dominator. State it in the spec so the scalar reference simulator and the SIMD
  executor are tested against the same rule, and so subgroup results match Vulkan's
  `SPV_KHR_maximal_reconvergence` behaviour.
- **Adopt the all-on fast path as a first-class design point, not a later optimization.**
  ISPC loses 27% (all-on) and 15% (coherent control flow) without it. For a fragment
  shader the common case is a fully covered quad set, so clone each divergent region with
  a constant all-on mask and branch to it on `all(mask)`.
- **Match the memory-op rules exactly**: blend only for lane-private storage; masked
  stores for buffers and images; gather only when the address shape analysis says
  `varying`. A test should compile a shader that writes `buf[i]` under `if (i < n)` and
  prove the out-of-range lanes are never written (ISPC's `SafeToRunWithMaskAllOff`
  counter-example).
- **Keep variability out of the D vocabulary.** ISPC needs `uniform` because its front
  end does the masking; sparkles' front end emits scalar IR that the GPU consumes as
  is. Recover uniformity by analysis (shape lattice from the thread-ID and
  `FragCoord` builtins) and allow at most an optional `@uniform` hint that is checked,
  never trusted.
- **Make `Vector!(T, N)` lane-agnostic and widen it SoA**: a varying `vec4` is four
  gang-wide registers, as ISPC's `varying float<3>` is three. The project-wide
  `Vector` type should never be reinterpreted as a SIMD register by the CPU executor.
- **Test at several gang widths** (4, 8, 16) and with an adversarial lane order.
  ISPC documents that cross-lane code can change with the gang size; a corpus run at
  one width hides that.
- **Avoid ISPC's in-gang memory model** (visibility at sequence points, unmasked
  `uniform` stores). Shaders have none of this; the executor must model SPIR-V's
  invocation-private values and explicit scopes instead.

## Strengths

- Fifteen years of production use (Embree, OSPRay, Unreal Engine's Chaos/Niagara via
  the `Intel ISPC` plugin are commonly cited users; not verified against a pinned source).
- A precise, documented execution model: program counter, mask, maximal convergence and
  in-gang visibility are all specified in the User's Guide.
- Predictable vectorization: every `varying` operation is a vector operation; no
  heuristic can silently fall back to scalar code.
- Zero-cost C interop: C linkage, shared pointers, generated headers, CPUID dispatch
  across ISAs in one object.
- Measured design: the paper quantifies each optimization's contribution.

## Weaknesses

- No graphics: no stages, quads, derivatives, textures or interface model.
- Variability is in the user's face: `uniform` placement in pointer declarations is a
  known source of confusion, and missed `uniform` qualifiers cost up to 2.2x (0.45x).
- No workgroup barrier and no shared memory between gangs; task parallelism is fork-join
  only.
- Results can depend on gang size by design; `foreach` cannot nest; `goto` is restricted.
- The masking lives in an AST-to-IR emitter tied to ISPC's language; none of it is a
  reusable LLVM pass that another front end could call.
- Tracks a patched, pinned LLVM.

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                             | Trade-off                                                                               |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Mask management in the front end, vector IR from the AST | Vectorization cannot fail; the front end knows the structure of every branch and loop | Not reusable by other languages; every statement kind needs hand-written mask logic     |
| `uniform`/`varying` as type qualifiers                   | Uniform control flow and memory are known without analysis (0.45x without them)       | Annotation burden; two pointer variabilities; overload ranks for variability conversion |
| Maximal convergence, single program counter              | Cross-lane communication without barriers; deterministic reconvergence                | Gang may not be split; results may depend on gang width                                 |
| `cif`/`cfor` coherence hints with all-on clones          | Skip all-off arms; specialise all-on paths (0.85x and 0.73x without)                  | Code-size growth; a programmer-supplied hint                                            |
| Load-blend-store for lane-private memory                 | Keeps values in registers, cheaper than native masked stores                          | Legal only for gang-owned storage; needs alias reasoning                                |
| Gang size and mask width fixed per target string         | Lets the mask element match the dominant data type (`i8x16`, `i32x8`)                 | One binary per target; multi-target dispatch needed for portability                     |
| C ABI and C layout for exported functions                | Shares data with the application without copies                                       | Varying values cross only behind pointers; `uniform` short vectors are target-dependent |
| No barriers; visibility at sequence points               | Simple, cheap in-gang communication                                                   | Data races are possible inside a gang; no workgroup model                               |

## Sources

- [ispc/ispc — GitHub repository][repo]
- [`README.md` — goals and design principles][readme]
- [`docs/ispc.rst` — User's Guide: execution model, types, control flow, stdlib, interop][guide]
- [`docs/perfguide.rst` — Performance Guide][perfguide]
- [`docs/ispc_for_xe.rst` — Xe targets, SPIR-V output][xe]
- [`docs/ReleaseNotes.txt` — `v1.32.0` release notes][relnotes]
- [`docs/design/TargetRedesign.md` — stdlib and builtins structure][redesign]
- [`src/ctx.h`][ctxh], [`src/ctx.cpp`][ctxcpp] — `FunctionEmitContext`, mask state, `Break`/`Continue`/`CurrentLanesReturned`
- [`src/stmt.cpp`][stmt] — `IfStmt::emitVaryingIf`, `ForStmt`, `ForeachStmt`
- [`src/func.cpp`][funccpp], [`src/type.cpp`][typecpp] — hidden `__mask` parameter
- [`src/opt.cpp`][optcpp], [`ImproveMemoryOps.h`][imo], [`ReplacePseudoMemoryOps.cpp`][rpmo], [`GatherCoalescePass.h`][gcp], [`IntrinsicsOptPass.h`][iopt]
- [`builtins/target-avx2-i32x8.ll`][avx2], [`stdlib/include/core.isph`][core], [`stdlib/stdlib.ispc`][stdlib]
- [`CMakeLists.txt`][cmake], [`src/target_enums.h`][enums], [`src/module.cpp`][modulecpp]
- M. Pharr and W. R. Mark, [ispc: A SPMD Compiler for High-Performance CPU Programming][paper], InPar 2012
- M. Pharr, [The Story of ISPC: Origins (Part 1)][story], 2018-04-18
- RV, the Region Vectorizer: [`README.md`][rv-readme], [`vectorShape.h`][rv-shape], [`Linearizer.h`][rv-lin], [`guardedDivLoopTrans.h`][rv-loop], [`UndeadMaskAnalysis.h`][rv-undead], [`singleReturnTrans.h`][rv-single], [`intrinsics.def`][rv-intr]
- LLVM: [`ConvergenceAndUniformity.rst`][convergence], [`ConvergentOperations.rst`][convergent], [`UniformityAnalysis.cpp`][uniformity], [`VFABIDemangler.cpp`][vfabi]
- Related: [SYCL][sycl] · [CUDA and HIP][cuda-hip] · [VCC and Shady][vcc-shady] · [MLIR SPIR-V][mlir-spirv] · [Concepts][concepts] · [Comparison][comparison] · [Index][index] · [sparkles:shaders spec][spec]

<!-- References -->

[repo]: https://github.com/ispc/ispc
[readme]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/README.md
[guide]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/docs/ispc.rst
[perfguide]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/docs/perfguide.rst
[xe]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/docs/ispc_for_xe.rst
[relnotes]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/docs/ReleaseNotes.txt
[redesign]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/docs/design/TargetRedesign.md
[ctxh]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/src/ctx.h
[ctxcpp]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/src/ctx.cpp
[stmt]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/src/stmt.cpp
[funccpp]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/src/func.cpp
[typecpp]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/src/type.cpp
[optcpp]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/src/opt.cpp
[imo]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/src/opt/ImproveMemoryOps.h
[rpmo]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/src/opt/ReplacePseudoMemoryOps.cpp
[gcp]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/src/opt/GatherCoalescePass.h
[iopt]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/src/opt/IntrinsicsOptPass.h
[avx2]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/builtins/target-avx2-i32x8.ll
[core]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/stdlib/include/core.isph
[stdlib]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/stdlib/stdlib.ispc
[cmake]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/CMakeLists.txt
[enums]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/src/target_enums.h
[modulecpp]: https://github.com/ispc/ispc/blob/553b773f6c34e0d98fe7510b76096217af0bf160/src/module.cpp
[paper]: https://pharr.org/matt/assets/ispc.pdf
[story]: https://pharr.org/matt/blog/2018/04/18/ispc-origins
[rv-readme]: https://github.com/cdl-saarland/rv/blob/3ad50a480adafe2eef9f94b30d66f7ad2878abbf/README.md
[rv-shape]: https://github.com/cdl-saarland/rv/blob/3ad50a480adafe2eef9f94b30d66f7ad2878abbf/include/rv/shape/vectorShape.h
[rv-lin]: https://github.com/cdl-saarland/rv/blob/3ad50a480adafe2eef9f94b30d66f7ad2878abbf/include/rv/transform/Linearizer.h
[rv-loop]: https://github.com/cdl-saarland/rv/blob/3ad50a480adafe2eef9f94b30d66f7ad2878abbf/include/rv/transform/guardedDivLoopTrans.h
[rv-undead]: https://github.com/cdl-saarland/rv/blob/3ad50a480adafe2eef9f94b30d66f7ad2878abbf/include/rv/analysis/UndeadMaskAnalysis.h
[rv-single]: https://github.com/cdl-saarland/rv/blob/3ad50a480adafe2eef9f94b30d66f7ad2878abbf/include/rv/transform/singleReturnTrans.h
[rv-intr]: https://github.com/cdl-saarland/rv/blob/3ad50a480adafe2eef9f94b30d66f7ad2878abbf/include/rv/intrinsics.def
[convergence]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/docs/ConvergenceAndUniformity.rst
[convergent]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/docs/ConvergentOperations.rst
[uniformity]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Analysis/UniformityAnalysis.cpp
[vfabi]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/IR/VFABIDemangler.cpp
[concepts-exec]: ./concepts.md#execution-model
[concepts-deriv]: ./concepts.md#derivative
[concepts-helper]: ./concepts.md#helper-invocation
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[sycl]: ./sycl.md
[cuda-hip]: ./cuda-hip.md
[vcc-shady]: ./vcc-shady.md
[mlir-spirv]: ./mlir-spirv.md
[spec]: ../../specs/shaders/SPEC.md
