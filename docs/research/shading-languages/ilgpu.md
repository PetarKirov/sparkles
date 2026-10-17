# ILGPU (.NET IL → PTX / OpenCL C / CUDA C / MSL / HIP, plus a CPU simulator)

A GPU compiler that reads ordinary .NET IL rather than source, lowers it through its own SSA IR to vendor kernel languages, and ships **two generations of CPU accelerator** — a thread-per-lane emulator with real barriers (v1.x) and a vectorized SPMD-on-SIMD code generator (v2.0 beta) — making it the closest precedent for the CPU simulator `sparkles:shaders` plans.

| Field             | Value                                                                                                                                                               |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | C# (compiler and runtime); kernels in any .NET language (C#, F#, VB) via IL                                                                                         |
| License           | University of Illinois/NCSA Open Source License ([`LICENSE.txt`][license])                                                                                          |
| Repository        | [m4rs-mt/ILGPU][repo], pinned at `7be765730944ab3ec4f2adb90ff6723751d0446a` (master, 2026-10-15) and tag `v1.5.3` (`2efd942cf020da83c32278a6666d57c1d8505077`)      |
| Documentation     | [`Docs/`][docs] in the repository; [ilgpu.net][site]                                                                                                                |
| Category          | Single-source GPGPU compiler; bytecode-level frontend; CPU emulation                                                                                                |
| Latest version    | Release `v1.5.3` (tag commit dated 2025-07-11); master declares `2.0.0-beta1` ([`Src/Directory.Build.props`][props]). NuGet publication dates not verified.         |
| Targets (v1.5.3)  | PTX (CUDA), OpenCL C, CPU (runs the original IL on emulated warps/groups)                                                                                           |
| Targets (master)  | CUDA C++, HIP (ROCm), OpenCL C (generic, AMD, Intel), Metal Shading Language, vectorized C# for the CPU; optional native compile via `nvcc`/`hipcc`/`ocloc`/`xcrun` |
| Graphics stages   | None — compute kernels only                                                                                                                                         |
| Compilation model | v1.x: JIT at kernel load. master: AOT `ILGPUC` MSBuild step that rewrites launch sites before `csc` ([`Src/ILGPUC/PACKAGE.md`][pkg])                                |

> [!NOTE]
> This deep-dive cites **two revisions** of one repository on purpose. The released
> `v1.5.3` CPU accelerator (OS thread per lane, `System.Threading.Barrier`) and the
> master `2.0.0-beta1` CPU backend (one thread per group, SIMD lanes, masked
> execution, barriers compiled away) are two complete, opposite answers to the
> question the sparkles CPU simulator must answer. Paths are cited at the revision
> they were read from; `[v15-…]` links are the tag, the rest are master.

---

## Overview

### What it solves

ILGPU lets a .NET program write a kernel as a plain `static` method over value types
and run it on NVIDIA, AMD, Intel or Apple GPUs — or on the CPU, under a debugger —
with no native toolchain and no source-level DSL. The README states the pitch and the
CPU promise in one paragraph ([`README.md`][readme]):

> "Functions in the scope of kernels do not have to be annotated (default C# functions)
> and are allowed to work on value types. All kernels (including all hardware features
> like shared memory and atomics) can be executed and debugged on the CPU using the
> integrated multi-threaded CPU accelerator."

That second sentence is the reason this subject is in the catalog: ILGPU treats "the
kernel also runs on the CPU, including barriers, shuffles, shared memory and atomics"
as a product feature, not a test hack, and has iterated on how to deliver it for a
decade.

### Design philosophy

1. **The frontend is the bytecode, not the language.** ILGPU disassembles IL
   (`Src/ILGPU/Frontend/Disassembler.cs`, [`ILFrontend.cs`][v15-ilfrontend]) and
   builds SSA from it; the README cites Braun et al.'s _Simple and Efficient
   Construction of SSA Form_ and Leißa/Köster/Hack's _graph-based higher-order IR_
   (Köster is ILGPU's original author). Any .NET language works; no attribute is
   needed on helper functions.
2. **Intrinsics are ordinary methods with a CPU body.** In v1.x every device
   intrinsic is a C# method tagged with an intrinsic attribute (`[GroupIntrinsic]`,
   `[WarpIntrinsic]`, `[SharedMemoryIntrinsic]`, `[AtomicIntrinsic]`) whose _body_ is
   the CPU implementation. The GPU frontend recognises the attribute and emits IR;
   the CPU simply calls the body. One declaration, two semantics.
3. **Explicit vs implicit grouping is a type-level choice.** A kernel whose first
   parameter is `Index1D`/`Index2D`/`Index3D` is "implicitly grouped" and _may not_
   touch shared memory, group or warp intrinsics; a kernel without one is "explicitly
   grouped" and gets the full CUDA model ([`02_Kernels.md`][doc-kernels]).
4. **Value types only.** No classes, exceptions, boxing or recursion in kernels
   ([`02_Kernels.md`][doc-kernels]): the same subset every shading language enforces.

---

## How it works

A kernel is a static method; buffers are host objects whose `ArrayView<T>` (a
`Span`-like struct) is passed by value:

```csharp
// Docs/03_Advanced/02_Kernels.md — implicitly grouped
static void MyKernel(Index1D index, ArrayView<int> data, int c)
{
    data[index] = index + c;
}

var buffer = accelerator.Allocate1D<int>(1024);
var kernel = accelerator.LoadAutoGroupedStreamKernel<
    Index1D, ArrayView<int>, int>(MyKernel);
kernel(buffer.Extent, buffer.View, 1);
```

An explicitly grouped kernel instead reads `Grid.GlobalIndex.X`, or
`Group.IdxX + Grid.IdxX * Group.DimX`, and may call `Group.Barrier()`,
`Warp.Shuffle(…)` and `SharedMemory.Allocate<T>(n)`
([`02_Kernels.md`][doc-kernels]). Dynamic shared memory is requested per launch with
`SharedMemoryConfig.RequestDynamic<T>(n)` and read with `SharedMemory.GetDynamic<T>()`
([`03_Shared-Memory.md`][doc-shared]).

**v1.5.3 pipeline.** IL → `Disassembler` → CFG (`Block.CFGBuilder.cs`) → SSA IR →
transformations in [`Src/ILGPU/IR/Transformations/`][v15-ssa] (`SSAConstruction`,
`Inliner`, `InferAddressSpaces`, `LowerViews`, `LowerStructures`, `LowerThreadIntrinsics`,
`IfConversion`, `LoopUnrolling`, …) → [`PTXBackend`][v15-ptx] (PTX text) or
[`CLBackend`][v15-cl] (OpenCL C). The CPU path compiles nothing: the
[`DefaultILBackend`][v15-ilbackend] is "the default IL backend that uses the original
kernel method"; it emits a small launcher (`System.Reflection.Emit`) that unpacks the
argument struct and `call`s the user's method.

**master pipeline.** `ILGPUC` runs at MSBuild time ([`PACKAGE.md`][pkg]):

> "1. Scans `@(Compile)` for `stream.Launch(...)` call sites 2. Compiles each kernel through ILGPUC's IL frontend → IR → optimizer → backend 3. Rewrites the launch site to call the compiled kernel directly 4. Hands `csc` the rewritten sources"

Every backend now emits **source** — CUDA C++ ([`CUDALanguageConfiguration.cs`][cuda-lang]:
`KernelAttribute => "__global__"`, shared memory as `__shared__`), Metal
(`#include <metal_stdlib>`, `threadgroup`; [`MetalLanguageConfiguration.cs`][metal-lang]),
OpenCL C, HIP, and C# for the CPU — from a common
[`ControlFlowReconstructor`][cfr] that rebuilds loops and `if`s "from basic blocks in
SSA form using dominator analysis" and falls back to an `UnstructuredRegion` state
machine for irreducible loops and orphaned blocks.

---

## Execution model and stages

Compute only; there are no vertex, fragment or other graphics stages anywhere in the
tree. The model is CUDA's: grid → group (block) → warp → lane.

| Concept      | API (static classes)                                                                                     | Notes                                                         |
| ------------ | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| Global index | `Index1D`/`2D`/`3D` first parameter, or `Grid.GlobalIndex`                                               | Implicit kernels get it as a parameter; explicit ones read it |
| Grid         | `Grid.IdxX/Y/Z`, `Grid.DimX/Y/Z`                                                                         | Group position and grid size                                  |
| Group        | `Group.IdxX/Y/Z`, `Group.DimX/Y/Z`, `Group.Barrier()`, `Group.BarrierPopCount/And/Or`, `Group.Broadcast` | Explicit kernels only                                         |
| Warp         | `Warp.LaneIdx`, `Warp.WarpSize`, `Warp.Barrier()`, `Warp.Shuffle/ShuffleDown/Up/Xor`, `Warp.Broadcast`   | Explicit kernels only                                         |
| Launch       | `LoadAutoGroupedStreamKernel`, `LoadImplicitlyGroupedKernel`, `LoadKernel`, `Accelerator.Launch`         | Typed launcher delegates; no boxing                           |

The implicit/explicit split is a useful guard rail: a kernel that cannot see its group
size cannot accidentally depend on it. The docs say implicitly grouped kernels "**must
not use shared memory, group or warp functionality** since there is no guaranteed group
size or thread participation inside a warp/group" ([`02_Kernels.md`][doc-kernels]).
Note that this is documented, not type-checked: `Group.Barrier()` is a static method
callable from either kind.

## Type system and generic programming

Kernels use the CLR type system restricted to **unmanaged value types**: primitives,
`struct`s of them, fixed buffers, `ArrayView<T> where T : unmanaged`. Generics are
full CLR generics, specialised per instantiation by the IR (the frontend sees closed
generic IL). ILGPU's own algorithm library is built on that: reductions and scans are
parameterised by a `struct` implementing `IScanReduceOperation<T>`, so the operator is
a type argument that inlines, not a delegate ([`ILWarpExtensions.cs`][v15-ilwarp]).

There is no first-class vector or matrix type in the kernel language (the CLR
`System.Numerics.Vector2/3/4` structs are usable as plain structs); `XMath` and
`IntrinsicMath` supply scalar math. Lambdas are allowed only when non-capturing, as the
IL launcher's `IsNotCapturingLambda()` check shows ([`DefaultILBackend.cs`][v15-ilbackend]);
master adds a `ClosureElimination` pass.

## Resources, interfaces and memory layout

There is no binding model: everything is a by-value kernel parameter. Parameters are
"uniform constants that are passed from the CPU to the GPU via constant memory (in the
parameter address space)" and must not be `ref`/`out` ([`02_Kernels.md`][doc-kernels]).
Buffers enter as `ArrayView<T>` — a (buffer, offset, length) triple that the
`LowerViews` pass turns into a pointer + length on GPU targets.

| Memory   | API                                               | v1.5.3 CPU realisation                                                          |
| -------- | ------------------------------------------------- | ------------------------------------------------------------------------------- |
| Global   | `MemoryBuffer` → `ArrayView<T>`                   | `Marshal.AllocHGlobal` native block ([`CPUMemoryBuffer.cs`][v15-membuf])        |
| Shared   | `SharedMemory.Allocate<T>(n)` / `GetDynamic<T>()` | One buffer per allocation site per group, created by the first lane to reach it |
| Local    | `LocalMemory.Allocate<T>(n)`                      | A fresh `CPUMemoryBuffer` per call, per lane ([`LocalMemory.cs`][v15-localmem]) |
| Constant | kernel parameters                                 | The launcher's argument struct, copied into locals                              |

Layout is the CLR's `StructLayout` (sequential, natural alignment); there is no
std140/std430 notion because nothing crosses a graphics API. Address spaces are
inferred (`InferAddressSpaces`), not spelled by the user.

## Built-in library and intrinsics

Intrinsics are attribute-tagged C# methods; the v1.5.3 source makes the dual
declaration visible ([`Group.cs`][v15-group]):

```csharp
// Src/ILGPU/Group.cs @ v1.5.3
[GroupIntrinsic(GroupIntrinsicKind.Barrier)]
public static void Barrier() =>
    CPURuntimeGroupContext.Current.Barrier();
```

The same pattern covers `Warp.Shuffle` (`[WarpIntrinsic(WarpIntrinsicKind.Shuffle)]`
→ `CPURuntimeWarpContext.Current.Shuffle(…)`, [`Warp.cs`][v15-warp]),
`SharedMemory.Allocate` ([`SharedMemory.cs`][v15-sharedmem]), atomics (`Atomic.Add`
on `int` → `Interlocked.Add(ref target, value) - value`; other types through a
generic compare-exchange loop `MakeAtomic`, [`Atomic.cs`][v15-atomic],
[`AtomicFunctions.tt`][v15-atomicfns]) and fences (`MemoryFence.GroupLevel()` →
`Interlocked.MemoryBarrier()`).

On master the CPU bodies are gone — `Group.Barrier()` is now
`=> throw new InvalidKernelOperationException()` ([`Group.cs`][group]) because the AOT
compiler always generates code, the CPU included. Warp reductions and scans become IR
nodes (`WarpReduce`, `WarpScan`) that `LowerWarpCollectives` "lowers … into unrolled
shuffle-based sequences for backends without native warp collective support"
([`LowerWarpCollectives.cs`][lowerwarp]).

## Control flow, memory model and restrictions

- **Rejected constructs:** "exception handling, boxing and recursive programs are also
  **not supported** and will be rejected by the ILGPU compiler"; reference types are
  not supported ([`02_Kernels.md`][doc-kernels]).
- **Control flow:** arbitrary IL control flow is accepted. v1.x targets tolerate
  unstructured CFGs: PTX has plain branches and the OpenCL C emitter writes `goto`
  (`GotoStatement = "goto"` in [`CLInstructions.Data.cs`][v15-clinstr]); master's
  source backends need structure and get it from `ControlFlowReconstructor`, which
  degrades to a labelled state machine (`LanguageFeature.LabeledStatements`) rather
  than failing ([`ControlFlowReconstructor.cs`][cfr]).
- **Memory model:** CUDA-style: `Group.Barrier()` is a block-level barrier plus fence;
  `MemoryFence.GroupLevel/DeviceLevel/SystemLevel` are explicit fences; atomics are
  relaxed RMWs. No formal model is specified in the docs.
- **Participation rules** are documentation-only: "all threads in a warp should
  participate in the shuffle operation" ([`Warp.cs`][v15-warp]). The v1.5.3 CPU
  emulator _enforces_ it by deadlocking (see below); the GPU does not.

## Compilation pipeline and targets

| Stage      | v1.5.3 (JIT)                                                      | master `2.0.0-beta1` (AOT)                                                  |
| ---------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Trigger    | First `Load*Kernel` call; cached (`KernelCache`)                  | MSBuild target before `CoreCompile`; launch sites rewritten                 |
| Frontend   | IL disassembler → SSA IR                                          | Same lineage, moved to `Src/ILGPUC/Frontend`                                |
| Optimiser  | `OptimizationLevel.O0/O1/O2` ([`07_Inside-ILGPU.md`][doc-inside]) | `-opt O2` via `ILGPUCompilationOptions`                                     |
| GPU output | PTX text; OpenCL C                                                | CUDA C++, HIP, OpenCL C, MSL; optional native compile (`ILGPUCompile=true`) |
| CPU output | none — original IL called by an emitted launcher                  | C# with `Tensor<T>`-style per-lane arrays and masks, `--simd-width N`       |
| Debug info | portable PDB line info on GPU (`DebugSymbols()`)                  | `#line` directives map generated C# back to the original source             |

The master package README makes `CPU` the **default** backend (`ILGPUBackend` default
`CPU`, [`PACKAGE.md`][pkg]) — the CPU path is the baseline, GPUs are opt-in.

A third CPU design existed between the two: an experimental **Velocity** SIMD
accelerator lived on master from early 2023 (commits such as `57f1b749`, 2023-01-26)
and was removed in January 2025 (`5b67611f`, "Removed Velocity capabilities …"). It
never shipped in a tagged release (no `Velocity` path exists at `v1.5.0` or `v1.5.3`);
the v2 vectorized backend replaces it.

## Host integration and CPU execution

This is the section that matters most for sparkles. ILGPU has shipped two CPU
simulators with opposite architectures.

### v1.5.3: one OS thread per lane, real barriers

**Topology.** A `CPUDevice` is a virtual GPU: `numThreadsPerWarp`,
`numWarpsPerMultiprocessor`, `numMultiprocessors`, with
`MaxNumThreadsPerGroup = numThreadsPerWarp * numWarpsPerMultiprocessor`
([`CPUDevice.cs`][v15-device]). Presets emulate real hardware shapes:

| `CPUDeviceKind` | Warp size | Warps / MP | Threads per group | MPs |
| --------------- | --------- | ---------- | ----------------- | --- |
| `Default`       | 4         | 4          | 16                | 1   |
| `Nvidia`        | 32        | 32         | 1024              | 1   |
| `AMD`           | 32        | 8          | 256               | 1   |
| `LegacyAMD`     | 64        | 4          | 256               | 1   |
| `Intel`         | 16        | 8          | 128               | 1   |

**Threads.** Each `CPUMultiprocessor` allocates `MaxNumThreadsPerMultiprocessor`
dedicated background `Thread`s, named `ILGPU_{id}_CPU_{mp}_{i}`, started lazily up to
the largest group size seen ([`CPUMultiprocessor.cs`][v15-mp]). Thread `i` is
permanently lane `i % WarpSize` of warp `i / WarpSize`; its
`CPURuntimeThreadContext`, `CPURuntimeWarpContext` and `CPURuntimeGroupContext` are
stored in `[ThreadStatic]` fields, which is how the intrinsic bodies find "the current
lane" with no parameter. So the `Nvidia` preset runs **1024 OS threads** for one
group. The grid is split into contiguous chunks, one per multiprocessor; each
multiprocessor walks its chunk of groups sequentially, every lane thread executing
`launcher(task, i * groupSize + threadIdx)` for group `i`. Launch hand-off uses a
`Monitor`-guarded `currentTask` and a `Barrier(NumMultiprocessors + 1)` for completion
([`CPUAccelerator.cs`][v15-accel]).

**Barriers.** Two execution policies, chosen by `CPUAcceleratorMode`
([`CPUAccelerator.cs`][v15-accel]):

> "The automatic mode uses `Sequential` if a debugger is attached. It uses `Parallel`
> if no debugger is attached to the application."

- `ParallelProcessor`: a `System.Threading.Barrier` for the group and one per warp,
  resized per launch with `AddParticipants`/`RemoveParticipants` (the last warp may be
  partial). `GroupBarrier()` is `Thread.MemoryBarrier(); n = ParticipantCount;
barrier.SignalAndWait()`. A lane whose work is done calls
  `barrier.RemoveParticipant()` — so a lane that _returns early_ no longer counts, which
  is more forgiving than hardware.
- `SequentialProcessor`: exactly one lane runs at a time. A `BitArray` activity set
  and a `Monitor` pass a token; at a barrier the running lane calls
  `ScheduleNextThread` (pick the next active lane, `Monitor.PulseAll`) and then waits
  until the token returns. This is a cooperative scheduler built from OS threads —
  deterministic interleaving so breakpoints and stepping behave, at the cost of
  context switches on every barrier.

`Group.Barrier()` itself is _two_ block barriers plus an allocation-index exchange
([`CPURuntimeGroupContext.cs`][v15-group-ctx]): after the plain barrier,
`GroupAllocationSynchronizedBarrier` takes `Atomic.Max` of every lane's shared-memory
allocation counter, barriers, reads the maximum back, and barriers again. Predicated
barriers (`BarrierPopCount/And/Or`) reset a shared counter, barrier, `Interlocked.Increment`
per true predicate, barrier, read.

**Shared memory.** Static shared allocations are emulated by _allocation order_, not
by address: each lane keeps a counter `groupAllocationIndices[lane]`; its `n`-th
`SharedMemory.Allocate<T>(extent)` call takes slot `n`, and under a lock the first lane
to arrive creates `CPUMemoryBuffer` slot `n`, the others reuse it. The source explains
why it cannot simply hoist allocations:

> "Note that these buffers are only required for debug CPU builds. In these cases, we
> cannot move nested `SharedMemory.Allocate{T}(int)` instructions out of nested loops
> to provide the best debugging experience."

Dynamic shared memory is the same call with the launch's
`SharedMemoryConfig.NumElements`. All slots are disposed at the end of each launch.

**Warp shuffles.** Each warp context owns a small scratch buffer. `Shuffle<T>`
([`CPURuntimeWarpContext.cs`][v15-warp-ctx]) is a lock-step exchange: one lane (the
winner of an `Interlocked.CompareExchange` "main thread" election in
`PerformLockStep`, [`CPURuntimeContext.cs`][v15-ctx]) resizes the scratch to
`WarpSize * sizeof(T)`, warp barrier, every lane writes `view[CurrentLane] = variable`,
warp barrier, every lane reads `view[AbsoluteSourceLane]` (or keeps its own value when
the source lane is out of range — CUDA's rule), warp barrier. A single shuffle costs
**four or five warp barriers**. Sub-warp widths are handled by an offset/width
`ShuffleConfig` with an assertion that the width is a power of two.
`Broadcast` reuses the same election. Warp reductions and scans in the algorithms
library are _not_ special-cased: "the CPU runtime is fully compatible with the PTX
runtime", so `ILWarpExtensions` forwards to the PTX shuffle-tree implementations
([`ILWarpExtensions.cs`][v15-ilwarp]) — the CPU executes the same butterfly as the GPU.

**Atomics** run on real shared memory with real `Interlocked` operations, so data races
and atomic contention are genuine (and nondeterministic in `Parallel` mode).

### master 2.0.0-beta1: one thread per group, lanes as SIMD

The rewrite inverts every choice. `CPUBackend` is a "CPU backend for generating
vectorized C# code that simulates GPU execution" ([`CPUBackend.cs`][cpu-backend]):
every SSA value becomes a per-lane array unless `VectorizationAnalysis`
([`VectorizationAnalysis.cs`][vecanalysis]) proves it uniform (constants, grid indices; group/lane
indices are per-lane). `CPUMethodEmitter` emits "predicated (masked) execution: both
branches of conditionals execute, guarded by an activeMask" with saved/restored masks
around every `if`, loop and `switch` ([`CPUMethodEmitter.cs`][cpu-method]).

The device fixes **group = warp = SIMD batch**: `WarpSize = MaxNumThreadsPerGroup =
vectorWidth`, defaulting to `Vector<int>.Count`, and `CPUDevice.Emulated(warpSize)`
"emulates a specific warp size … (e.g., 32 for CUDA, 64 for AMD)" with scalar arrays
([`CPUDevice.cs`][device]). Given that, barriers vanish
([`CPUIntrinsicEmitter.cs`][cpu-intrin]):

```csharp
// Src/ILGPUC/Backends/CPU/CPUIntrinsicEmitter.cs @ master
/// Barriers are no-ops in single-threaded vectorized execution.
/// All lanes execute in lockstep.
public override string EmitBarrier() =>
    "/* barrier - vectorized execution, no synchronization needed */";
```

Shuffles are array permutations (`CPUVectorIntrinsics.ShuffleDown<T>(source, delta)`),
reductions fold the active lanes and broadcast (`WarpReduceAdd(values, mask)`), atomics
are "serialized across lanes to maintain correctness" with the mask suppressing
inactive lanes ([`CPUVectorIntrinsics.cs`][vec-intrin],
[`CPUAtomicIntrinsics.tt`][cpu-atomic]). The launcher is a flat loop over the user
extent in steps of `simdWidth`, masking the tail ([`CPULauncherEmitter.cs`][cpu-launch]).

> [!WARNING]
> The two CPU implementations disagree on edge semantics. v1.5.3's shuffle returns the
> caller's own value for an out-of-range source lane; master's `ShuffleDown` writes
> `default` (`srcIndex < source.Length ? source[srcIndex] : default`). And because the
> master group size is capped at the SIMD width, the 1024-thread-group, multi-warp,
> barrier-heavy kernels v1.5.3 emulated faithfully are outside what the master CPU
> device accepts. Neither is wrong for its goal; both are silent about it.

---

## Lessons for sparkles:shaders

- **Adopt the dual-body intrinsic pattern.** v1.5.3's `[GroupIntrinsic] static void
Barrier() => CPURuntimeGroupContext.Current.Barrier();` is exactly sparkles'
  "one function, two places" ([`SPEC.md`][spec]): in D, each vocabulary intrinsic is
  one declaration whose `@compute` path is a `pragma(LDC_intrinsic, "llvm.spv.…")` and
  whose host path is a D body over a simulator context. Keep the context in a
  `static` (thread-local) variable, as ILGPU's `[ThreadStatic]` does, so intrinsic
  signatures stay identical on both sides.
- **Build the scalar reference simulator on cooperative scheduling, not OS threads.**
  v1.5.3 needs `SequentialProcessor` precisely because one-thread-per-lane plus
  `Barrier` is undebuggable and nondeterministic. A D scalar reference should run each
  lane as a fiber (or a re-entrant state machine) with a deterministic round-robin
  switch at every barrier and collective: the determinism ILGPU gets only under a
  debugger becomes the default, and a 1024-lane group costs 1024 fibers, not 1024
  threads.
- **Treat "group = SIMD batch, barriers are no-ops" as the SPMD-on-SIMD tier, with its
  limit stated.** master shows the fast tier works when the group fits one vector; the
  sparkles spec should say so explicitly and fall back to the scalar reference (or
  split at barriers) for larger groups, instead of capping group size silently.
- **Match one shuffle/reduction semantics across every executor, and test it.** ILGPU's
  two CPU backends disagree on out-of-range shuffle sources. The sparkles conformance
  corpus should pin each subgroup operation's edge cases (out-of-range lane, inactive
  lanes, partial last subgroup) to the SPIR-V/Vulkan definition and run the same cases
  on the scalar simulator, the SIMD simulator and a GPU.
- **Make participation rules errors in the reference simulator.** v1.5.3 lets a lane
  that returned early leave the barrier (`RemoveParticipant`), masking a bug that hangs
  real hardware; the sequential scheduler instead deadlocks without explanation. The
  sparkles scalar simulator knows exactly which lanes are live and should diagnose a
  barrier reached in divergent control flow, naming the lanes.
- **Emulate shared memory per allocation site, not per call.** ILGPU's per-lane
  allocation counter is a workaround for not hoisting allocations; sparkles' planned
  module-scope `Shared!T` variables (blocked today by the fork's global-variable ban,
  see [`dcompute.md`][dcompute]) give each one a static identity, so the simulator can
  allocate one block per variable per group up front.
- **Copy the irreducible-CFG fallback idea.** master's `ControlFlowReconstructor`
  never fails: unstructurable regions become a labelled state machine. LLVM's SPIR-V
  structurizer instead errors on everyday D (`#618`); a frontend-side "lower to a
  `switch` in a loop" fallback is the same move.
- **Expose hardware shapes as named simulator presets.** `CPUDeviceKind.Nvidia/AMD/
LegacyAMD/Intel` make "does this kernel assume warp size 32?" a one-line test.
  sparkles' simulator should take the subgroup size as a parameter (4, 8, 16, 32, 64, 128) and the corpus should sweep it.

## Strengths

- **The CPU accelerator is a first-class target**, with all GPU features including
  shared memory, warp shuffles and atomics, and with a debugger-friendly sequential mode
  selected automatically.
- **Language-agnostic frontend**: IL in, so C#, F# and VB kernels share one compiler;
  no annotation on helper functions.
- **Explicit/implicit kernel split** keeps simple data-parallel kernels free of group
  assumptions.
- **Hardware-shape presets** (`Nvidia`, `AMD`, `LegacyAMD`, `Intel`) and
  `CPUDevice.Emulated(warpSize)` make warp-size portability testable without the
  hardware.
- **Pure managed code**, no native dependencies in v1.x; master's AOT step removes the
  JIT cost and lets the CPU path be real compiled C#.
- **Never-fail control-flow reconstruction** for source backends.

## Weaknesses

- **No graphics** at all: no stages, interfaces, textures or samplers; nothing maps to
  a shading language's I/O model.
- **v1.5.3 CPU cost is extreme**: one OS thread per lane (1024 for the `Nvidia`
  preset), four to five barriers per shuffle, a heap allocation per `LocalMemory`
  call.
- **master's CPU tier caps group size at the SIMD width**, so it cannot run the
  multi-warp, shared-memory kernels v1.5.3 could.
- **Semantics drift between executors** (shuffle out-of-range results; early-exit
  barrier participation) with no conformance suite pinning them.
- **Participation and implicit-kernel rules are documentation, not checks.**
- **Release cadence**: the last tag is `v1.5.3` (2025-07-11); the v2 rewrite is a beta
  on master with removed APIs (CPU intrinsic bodies now throw).

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                           | Trade-off                                                                       |
| ---------------------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Read IL, not source                                        | Every .NET language for free; no parser                             | Source intent (structure, names) must be reconstructed from bytecode            |
| Intrinsics as attributed methods with CPU bodies (v1.x)    | One declaration, GPU and CPU semantics side by side                 | CPU path is "whatever the body does"; drifts from GPU semantics without tests   |
| One OS thread per lane + `System.Threading.Barrier` (v1.x) | Runs the unmodified kernel; barriers are real                       | Thousands of threads; slow; nondeterministic unless `Sequential`                |
| Token-passing `Sequential` mode under a debugger           | Deterministic interleaving; breakpoints work                        | Context switch per barrier; only enabled when a debugger is attached            |
| Shared memory by per-lane allocation order                 | Works without hoisting allocations out of loops in debug builds     | Extra barrier phases on every `Group.Barrier()`; relies on uniform call order   |
| Group = warp = SIMD width, barriers compiled away (v2)     | Single-threaded, vectorizable, deterministic, fast                  | Group size capped; multi-warp barrier kernels not expressible on the CPU device |
| Masked execution of both branches (v2)                     | Faithful SIMT divergence on SIMD hardware                           | Both sides always run; side effects must all be mask-aware                      |
| Source backends + `ControlFlowReconstructor` (v2)          | Vendor compilers (nvcc, Metal) do the hard codegen; readable output | Needs structured CF; irreducible regions become state machines                  |
| CPU as the default backend (v2)                            | Kernels are testable everywhere by default                          | GPU paths are opt-in and exercised less in casual builds                        |

---

## Sources

- [m4rs-mt/ILGPU — repository][repo] · [ilgpu.net][site] · [`README.md`][readme] · [`LICENSE.txt`][license] · [`Src/Directory.Build.props`][props]
- Docs: [`02_Kernels.md`][doc-kernels] · [`03_Shared-Memory.md`][doc-shared] · [`06_Debugging-and-Profiling.md`][doc-debug] · [`07_Inside-ILGPU.md`][doc-inside]
- v1.5.3 CPU accelerator: [`CPUAccelerator.cs`][v15-accel] · [`CPUDevice.cs`][v15-device] · [`CPUMultiprocessor.cs`][v15-mp] · [`CPURuntimeContext.cs`][v15-ctx] · [`CPURuntimeGroupContext.cs`][v15-group-ctx] · [`CPURuntimeWarpContext.cs`][v15-warp-ctx] · [`CPURuntimeThreadContext.cs`][v15-thread-ctx] · [`CPUMemoryBuffer.cs`][v15-membuf]
- v1.5.3 intrinsics and backends: [`Group.cs`][v15-group] · [`Warp.cs`][v15-warp] · [`SharedMemory.cs`][v15-sharedmem] · [`LocalMemory.cs`][v15-localmem] · [`Atomic.cs`][v15-atomic] · [`AtomicFunctions.tt`][v15-atomicfns] · [`DefaultILBackend.cs`][v15-ilbackend] · [`PTXBackend.cs`][v15-ptx] · [`CLBackend.cs`][v15-cl] · [`ILFrontend.cs`][v15-ilfrontend] · [`SSAConstruction.cs`][v15-ssa] · [`ILWarpExtensions.cs`][v15-ilwarp]
- master `ILGPUC`: [`PACKAGE.md`][pkg] · [`CPUBackend.cs`][cpu-backend] · [`VectorizationAnalysis.cs`][vecanalysis] · [`CPUMethodEmitter.cs`][cpu-method] · [`CPUIntrinsicEmitter.cs`][cpu-intrin] · [`CPULauncherEmitter.cs`][cpu-launch] · [`ControlFlowReconstructor.cs`][cfr] · [`LowerWarpCollectives.cs`][lowerwarp] · [`CUDALanguageConfiguration.cs`][cuda-lang] · [`MetalLanguageConfiguration.cs`][metal-lang]
- master runtime: [`CPUDevice.cs`][device] · [`CPUAccelerator.cs`][accel] · [`CPUVectorIntrinsics.cs`][vec-intrin] · [`CPUAtomicIntrinsics.tt`][cpu-atomic] · [`Group.cs`][group]
- Related: [CUDA / HIP][cuda-hip] · [SYCL][sycl] · [ISPC][ispc] · [ComputeSharp][computesharp] · [Julia][julia] · [dcompute baseline][dcompute] · [Concepts][concepts] · [Comparison][comparison] · [Catalog index][index] · [`sparkles:shaders` SPEC][spec] · [PLAN][plan]

<!-- References -->

[repo]: https://github.com/m4rs-mt/ILGPU
[site]: https://www.ilgpu.net/
[readme]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/README.md
[license]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/LICENSE.txt
[props]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/Directory.Build.props
[docs]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Docs/README.md
[doc-kernels]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Docs/03_Advanced/02_Kernels.md
[doc-shared]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Docs/03_Advanced/03_Shared-Memory.md
[doc-debug]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Docs/03_Advanced/06_Debugging-and-Profiling.md
[doc-inside]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Docs/03_Advanced/07_Inside-ILGPU.md
[pkg]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPUC/PACKAGE.md
[cpu-backend]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPUC/Backends/CPU/CPUBackend.cs
[vecanalysis]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPUC/Backends/CPU/VectorizationAnalysis.cs
[cpu-method]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPUC/Backends/CPU/CPUMethodEmitter.cs
[cpu-intrin]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPUC/Backends/CPU/CPUIntrinsicEmitter.cs
[cpu-launch]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPUC/Backends/CPU/CPULauncherEmitter.cs
[cfr]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPUC/Backends/ControlFlowReconstructor.cs
[lowerwarp]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPUC/IR/Transformations/LowerWarpCollectives.cs
[cuda-lang]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPUC/Backends/CUDA/CUDALanguageConfiguration.cs
[metal-lang]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPUC/Backends/Metal/MetalLanguageConfiguration.cs
[device]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPU/Runtime/CPU/CPUDevice.cs
[accel]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPU/Runtime/CPU/CPUAccelerator.cs
[vec-intrin]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPU/Runtime/CPU/CPUVectorIntrinsics.cs
[cpu-atomic]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPU/Runtime/CPU/CPUAtomicIntrinsics.tt
[group]: https://github.com/m4rs-mt/ILGPU/blob/7be765730944ab3ec4f2adb90ff6723751d0446a/Src/ILGPU/Group.cs
[v15-accel]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Runtime/CPU/CPUAccelerator.cs
[v15-device]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Runtime/CPU/CPUDevice.cs
[v15-mp]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Runtime/CPU/CPUMultiprocessor.cs
[v15-ctx]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Runtime/CPU/CPURuntimeContext.cs
[v15-group-ctx]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Runtime/CPU/CPURuntimeGroupContext.cs
[v15-warp-ctx]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Runtime/CPU/CPURuntimeWarpContext.cs
[v15-thread-ctx]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Runtime/CPU/CPURuntimeThreadContext.cs
[v15-membuf]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Runtime/CPU/CPUMemoryBuffer.cs
[v15-group]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Group.cs
[v15-warp]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Warp.cs
[v15-sharedmem]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/SharedMemory.cs
[v15-localmem]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/LocalMemory.cs
[v15-atomic]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Atomic.cs
[v15-atomicfns]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/AtomicFunctions.tt
[v15-ilbackend]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Backends/IL/DefaultILBackend.cs
[v15-ptx]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Backends/PTX/PTXBackend.cs
[v15-clinstr]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Backends/OpenCL/CLInstructions.Data.cs
[v15-cl]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Backends/OpenCL/CLBackend.cs
[v15-ilfrontend]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/Frontend/ILFrontend.cs
[v15-ssa]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU/IR/Transformations/SSAConstruction.cs
[v15-ilwarp]: https://github.com/m4rs-mt/ILGPU/blob/2efd942cf020da83c32278a6666d57c1d8505077/Src/ILGPU.Algorithms/IL/ILWarpExtensions.cs
[cuda-hip]: ./cuda-hip.md
[sycl]: ./sycl.md
[ispc]: ./ispc.md
[computesharp]: ./computesharp.md
[julia]: ./julia.md
[dcompute]: ./dcompute.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[spec]: ../../specs/shaders/SPEC.md
[plan]: ../../specs/shaders/PLAN.md
