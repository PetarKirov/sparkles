# Julia GPU stack (Julia / JuliaGPU)

Julia compiles ordinary, generic Julia functions to GPU code by reusing its own
type inference and LLVM code generation, then retargeting the LLVM module: the
closest existing analogue to a single-source D design built on LDC, and, through
Lava.jl, the only surveyed project that writes Vulkan graphics stages in a
general-purpose language through LLVM IR.

| Field          | Value                                                                                                                                                                                                         |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | Julia (≥ 1.10 for GPUCompiler.jl; Lava.jl needs ≥ 1.12 through its `Raycore` dependency)                                                                                                                      |
| License        | MIT ("Expat") for every package below                                                                                                                                                                         |
| Repositories   | [JuliaGPU/GPUCompiler.jl][gpc-repo], [JuliaGPU/KernelAbstractions.jl][ka-repo], [SimonDanisch/Lava.jl][lava-repo], [JuliaGPU/OpenCL.jl][ocl-repo], [JuliaGPU/Vulkan.jl][vk-repo]                              |
| Documentation  | [KernelAbstractions docs][ka-docs], [Lava architecture][lava-arch], [GPUCompiler `interface.jl`][gpc-interface]                                                                                               |
| Category       | Single-source GPU compute (and, in Lava, graphics and ray tracing) via a JIT over the host compiler's own IR                                                                                                  |
| Latest version | GPUCompiler `2.15.1`, KernelAbstractions `0.10.1` (`v0.10.0` tagged 2026-10-12), OpenCL.jl `0.10.12`, Vulkan.jl `0.6.30`; Lava.jl `0.1.0`, unregistered, last commit 2026-08-06 (all read at the pinned SHAs) |
| Targets        | PTX (CUDA.jl), AMDGCN (AMDGPU.jl), Metal AIR (Metal.jl), SPIR-V kernel flavour (oneAPI.jl, OpenCL.jl, KA's CPU backend), Vulkan SPIR-V (Lava.jl, own emitter), host CPU (native target)                       |
| SPIR-V path    | GPUCompiler: LLVM's SPIR-V backend in-process (`:llvm`, default) or the Khronos SPIRV-LLVM-Translator (`:khronos`); Lava: a hand-written LLVM-IR → SPIR-V emitter                                             |
| CPU execution  | KernelAbstractions' `CPU()` is an alias for `POCLBackend`: kernels are compiled to SPIR-V and run by PoCL on the host                                                                                         |

---

## Overview

### What it solves

The JuliaGPU ecosystem lets a scientist write `C[i] = A[i] + B[i]` once and run
it on NVIDIA, AMD, Intel, Apple and CPU back-ends, with the same generic
functions, the same multiple dispatch, and the same packages (`StaticArrays`,
`LinearAlgebra`) as host code. There is no device dialect: a kernel is a Julia
method, compiled on first call for the concrete argument types, exactly as the
host JIT compiles it, but through a retargeted pipeline.

The stack has three layers:

1. **[GPUCompiler.jl][gpc-repo]** — the shared compiler. Its README is
   explicit: _"This package offers reusable compiler infrastructure and tooling
   for implementing GPU compilers in Julia. **It is not intended for end
   users!**"_ ([`README.md`][gpc-readme]). Each vendor package (CUDA.jl,
   AMDGPU.jl, Metal.jl, oneAPI.jl, OpenCL.jl) is a thin specialisation.
2. **[KernelAbstractions.jl][ka-repo]** (KA) — a vendor-neutral kernel
   language: `@kernel`, `@index`, `@localmem`, `@synchronize`, plus the
   lower-level `KernelInterface` (`KI`) contract that back-ends implement.
3. **Back-ends.** Of interest here are OpenCL.jl and KA's own PoCL CPU backend
   (both SPIR-V, kernel flavour) and **[Lava.jl][lava-repo]**, which targets
   Vulkan, adds graphics and ray-tracing stages, and implements the KA and
   `GPUArrays` interfaces so existing KA code runs on Vulkan unchanged.

### Design philosophy

GPUCompiler's design rests on reusing the host compiler wholesale and
customising it at named seams. [`src/interface.jl`][gpc-interface] states the
split:

> _"the definition of a new GPU compiler is typically split in two: a generic
> compiler that lives in GPUCompiler.jl (e.g., emitting PTX, SPIR-V, etc) [and]
> a more specific version in a package that targets an environment (e.g. CUDA,
> ROCm, etc)"_

KernelAbstractions frames itself as an experiment in portability rather than a
new language: _"KA is intended to be a minimal and performant library that
explores ways to write heterogeneous code"_ ([`README.md`][ka-readme]).

Lava's philosophy is pragmatic and, unusually, written down as an engineering
rule. Its intrinsics audit opens with _"Rule 0 — the driver is not the
suspect"_ and lists, in order, `spirv-val`, GPU-assisted validation, and
_"Write the same kernel in GLSL, compile it with `glslangValidator`, and run
that module through the same Lava dispatch"_ as the instruments to use before
blaming a driver ([`spirv-intrinsics.md`][lava-intr]).

---

## How it works

### GPUCompiler: target, params, config, job

A compilation is a `CompilerJob` over a `CompilerConfig{T,P}`, where `T <:
AbstractCompilerTarget` is defined inside GPUCompiler (PTX, GCN, Metal,
SPIR-V, native) and `P <: AbstractCompilerParams` is the back-end's own state
([`src/interface.jl`][gpc-interface]). `CompilerConfig` carries the knobs that
change codegen — `kernel`, `entry_abi` (`:specfunc` or `:func`),
`always_inline`, `opt_level`, `debug_level`, `libraries`, `validate`, `strip`.
Target hooks are plain methods on the target type: `llvm_triple`,
`llvm_datalayout`, `have_fma`, `llvm_syncscope`, `finish_module!`,
`validate_ir`, `mcgen`. The SPIR-V target is a keyword struct:

```julia
# GPUCompiler.jl src/spirv.jl (abridged)
Base.@kwdef struct SPIRVCompilerTarget <: AbstractCompilerTarget
    version::Union{Nothing,VersionNumber} = nothing
    extensions::String = ""          # "+SPV_EXT_shader_atomic_float_add,..."
    atomics::SPIRVAtomics = SPIRVAtomics()
    supports_fp16::Bool = true
    supports_fp64::Bool = true
    backend::Symbol = isavailable(SPIRV_LLVM_Backend_jll) ? :llvm : :khronos
    driver::Symbol = :generic        # :intel, :pocl, :nvidia — for workarounds
end
```

Inference results are cached per `GPUCompilerCacheToken(target, params,
always_inline)`; the docstring requires every inference input
(`method_tables`, `inference_params`, `optimization_params`) to be _"pure
functions of those values"_ so the cache partitions correctly
([`src/interface.jl`][gpc-interface]).

### Method overlays: device semantics without forking the library

Device behaviour is substituted at the method-table level. A back-end declares
a `Base.Experimental.@MethodTable` and returns it from `method_tables(job)`;
inference looks a call up in those tables first, then in
`SHARED_METHOD_TABLE` (overlays for every device back-end), then in Base
([`src/interface.jl`][gpc-interface], [`src/jlgen.jl`][gpc-jlgen]). The
user-facing spelling is `@device_override`, defined in OpenCL.jl's
`SPIRVIntrinsics`:

```julia
# OpenCL.jl lib/intrinsics/src/utils.jl (abridged)
Base.Experimental.@MethodTable(method_table)
macro device_override(ex)
    esc(quote Base.Experimental.@consistent_overlay(method_table, $ex) end)
end
```

`@consistent_overlay` carries a stated contract: _"if f(x) returns a value,
f′(x) must return the identical value"_ and must throw where `f` throws
([`lib/intrinsics/src/utils.jl`][ocl-utils]). KA's PoCL back-end uses it to
replace every Base error path with a `printf` plus trap
([`src/pocl/device/quirks.jl`][ka-quirks]); Lava's `@lava_device_override`
does the same on `lava_method_table` ([`src/compiler/target.jl`][lava-target]).
A small `Runtime` module supplies the functions Julia's code generator assumes
exist (`report_exception`, `malloc`, boxing); Lava stubs them all to no-ops
and `malloc` to a null pointer ([`src/compiler/target.jl`][lava-target],
[`src/runtime.jl`][gpc-runtime]).

### Deferred codegen

`deferred_codegen(Val(f), Val(tt))` is a `@generated` function that records a
`(f, tt)` pair and emits `ccall("extern deferred_codegen", llvmcall, ...)`
with an integer id; the driver later finds those markers in the module,
compiles the referenced job, and links it in. The comment calls it the
_"primitive mechanism for deferred compilation, for implementing CUDA dynamic
parallelism"_ ([`src/driver.jl`][gpc-driver]). It is how a device function
obtains a pointer to another kernel without the front-end knowing about
kernels.

### KernelAbstractions: one macro, two lowerings of a barrier

`@kernel` rewrites a function into `gpu_<name>` with a hidden `__ctx__`
argument and constructors `name(backend, workgroupsize, ndrange)`
([`src/macros.jl`][ka-macros]). Indices come from `@index(Global|Group|Local,
Linear|Cartesian|NTuple)`; scratch memory from `@localmem T dims` and
`@private`; barriers from `@synchronize`.

```julia
@kernel function saxpy!(a, @Const(X), Y)
    I = @index(Global)
    @inbounds Y[I] = a * X[I] + Y[I]
end
saxpy!(CPU(), 8, size(Y))(a, X, Y)   # backend, workgroup size, then ndrange
```

The interesting part is `split`. The `ndrange` need not be a multiple of the
workgroup size, so padding work-items exist; they must still reach every
barrier. `transform_gpu!` therefore cuts the body at each `@synchronize` (and
each collective such as `@groupreduce`) into `WorkgroupLoop` regions, hoists
`@localmem`/`@uniform`/`@private` allocations out of them, and wraps each
region in `if __active_lane__` so only in-range lanes run user code while all
lanes hit the barrier ([`src/macros.jl`][ka-macros]):

```julia
# KernelAbstractions src/macros.jl — emit(loop) (abridged)
append!(stmts, loop.allocations)
push!(stmts, Expr(:if, :__active_lane__, Expr(:block, loop.stmts...)))
loop.terminated_in_sync && push!(stmts, :($__synchronize()))
```

Hence the documented rule that `@synchronize` _"has to appear directly in the
kernel body, and not in a function called by the kernel"_ and that control
flow containing it _"must be uniform across the workgroup"_
([`src/KernelAbstractions.jl`][ka-main]). The same `split` used to drive the
old CPU back-end, where each region became a loop over the workgroup's items
and `@private` values became per-item scratchpads (loop fission at barriers),
in [`src/cpu.jl`][ka-cpu-old] — removed on 2025-10-06 by "Unified memory
allocations (#630)".

---

## Execution model and stages

GPUCompiler knows two entry kinds: a kernel (`kernel=true`, which on SPIR-V
sets the `SPIR_KERNEL` calling convention in `finish_module!`) and a plain
function ([`src/spirv.jl`][gpc-spirv]). There are no graphics stages anywhere
in GPUCompiler or KA: the model is OpenCL/CUDA's NDRange of workgroups and
work-items, with sub-groups exposed through `KI.get_sub_group_size`,
`get_sub_group_local_id` and friends ([`lib/KernelInterface/src/device.jl`][ki-device]).

Lava adds the stages. `GFX_STAGE_INFO` maps `:vertex`, `:fragment`,
`:geometry`, `:tess_control`, `:tess_eval` to SPIR-V execution models, and
`raytracing.jl` adds raygen, closest-hit, any-hit, miss and intersection
([`src/compiler/spirv/graphics.jl`][lava-gfx]). Stages are selected by the
pipeline object, not by an attribute on the function: `Rasterizer(vertex = f,
fragment = g, geometry = ..., tess_control = ..., tess_eval = ...)`
([`docs/src/graphics.md`][lava-gfx-doc]). Workgroup size is a compile-time
`LavaCompilerParams.workgroup_size` (default `(64, 1, 1)`), so a different
size is a different compilation ([`src/compiler/target.jl`][lava-target]).

## Type system and generic programming

This is where Julia is strongest and most relevant. A kernel is compiled per
concrete argument-type tuple; every generic call inside it is devirtualised by
inference, and anything that cannot be (dynamic dispatch, boxing, `Any`
returns) is rejected by `validate_ir` with a `KernelError` naming the cause.
Multiple dispatch, parametric structs, `StaticArrays` vectors and closures all
work on device provided they are `isbits`. KA even turns a failed `@generated`
kernel's error into a return type (`GeneratedKernelError{Msg}`) because
_"Inference swallows any error thrown while generating"_ and the return type is
the only channel GPUCompiler reports on every back-end ([`src/macros.jl`][ka-macros]).

There is no shading-language vector or matrix type in the core: user code uses
`StaticArrays`/`GeometryBasics` (`Vec4f`), which lower to LLVM aggregates.
Lava's graphics intrinsics are typed to those (`set_position!(v::Vec4f)`,
`gfx_output(loc, v::Vec3f)`, `dFdx(v::Vec2f)` decomposed per component)
([`src/device/gfx_intrinsics.jl`][lava-gfxi]).

## Resources, interfaces and memory layout

GPUCompiler and KA pass arrays as device-array structs (pointer + dims) in the
kernel argument list, using address spaces for global (`1`) and local (`3`)
memory; on SPIR-V that is the kernel environment's `CrossWorkgroup` and
`Workgroup`.

Lava replaces the whole interface with **buffer device addresses**. Every
entry is wrapped so that it takes one `i64` push constant, the address of an
argument buffer, and unpacks the original arguments from it:

> _"Push constant layout: `{ i64 bda_address }` · Argument buffer layout:
> `[ arg1_bytes | arg2_bytes | ... ]` (natural alignment)"_
> ([`src/compiler/entry_wrapper.jl`][lava-wrapper])

The architecture page justifies it as the way _"to avoid the 256-byte
push-constant limit and per-buffer descriptor sets"_ ([`architecture.md`][lava-arch]);
textures and samplers _"participate in the same BDA arg-packing as buffer
arguments; descriptor set management is hidden from the user"_
([`docs/src/graphics.md`][lava-gfx-doc]). Stage inputs and outputs are not
struct members but intrinsic calls with an explicit location:
`gfx_output_vec4(location, ...)`, `gfx_input(Vec3f, loc)`,
`gfx_output_flat(...)`; the emitter creates the `Location`-decorated
`OpVariable`s as it meets the calls ([`src/compiler/spirv/graphics.jl`][lava-gfx]).

Layout is where Lava paid. `prepare_vulkan.jl` has six sub-passes for
`PhysicalStorageBuffer` (PSB) memory — `flatten_bda_array_geps!`,
`lower_psb_memops!`, `decompose_composite_psb_accesses!` among them — because
Vulkan requires explicit layout and alignment on PSB accesses
([`src/compiler/passes/prepare_vulkan.jl`][lava-prep]). A struct with `Bool`
fields followed by `i32`s was mis-offset by two bytes because the emitter summed
field sizes without padding; the fix was to ask LLVM
(`LLVMOffsetOfElement`), and the bug was invisible to GPU-assisted validation
because that _"does NOT instrument `PhysicalStorageBuffer` (BDA) access"_
([`KNOWN_ISSUES.md`][lava-issues]).

## Built-in library and intrinsics

- **Math.** Back-ends overlay `Base` math with device calls; Lava's
  `device/math.jl` maps `Float32` to `GLSL.std.450` and supplies `Float64`
  fallbacks ([`architecture.md`][lava-arch]).
- **Sub-groups.** `KI.shfl`, `shfl_down`, `shfl_up`, `shfl_xor`,
  `sub_group_any/all/ballot`, `sub_group_reduce`, `sub_group_scan`,
  `sub_group_exclusive_scan`, with a generic word-splitting fallback that
  shuffles any `isbits` struct whose fields are 1–16 bytes
  ([`lib/KernelInterface/src/device.jl`][ki-device]).
- **Atomics.** `SPIRVAtomics` records which atomic operations _"the device, its
  driver and the SPIR-V toolchain run correctly (not: that are native in
  hardware)"_; everything else becomes a compare-exchange loop, and float
  min/max always does, because SPIR-V's may return either zero for `-0.0` vs
  `+0.0` while LLVM's `atomicrmw fmin` orders them ([`src/spirv.jl`][gpc-spirv]).
- **Graphics.** `vertex_index`, `instance_index`, `frag_coord`,
  `front_facing`, `set_position!`, `set_point_size!`, `dFdx`/`dFdy`,
  `emit_vertex!`, `end_primitive!`, `invocation_id`, `primitive_id_in`
  ([`src/device/gfx_intrinsics.jl`][lava-gfxi]). They are `llvmcall`s to
  `_lava_gfx_*` declarations the emitter intercepts by name.
- **Coverage audit.** Lava's own audit (2026-08-02) counts _"`229` opcodes and
  `36` capabilities declared ... of which `172` and `30` are reachable"_, and
  warns that a capability the device reports and one Lava can emit are
  different things ([`spirv-intrinsics.md`][lava-intr]).

> [!NOTE]
> No `discard`/`OpKill`/`OpTerminateInvocation`/`OpDemoteToHelperInvocation`
> emission was found in `src/` at the pinned SHA (only a device-feature
> query). Lava's fragment stage, as read, has no fragment-kill primitive.

## Control flow, memory model and restrictions

Julia's code generator produces unstructured, exception-laden LLVM IR, so
Vulkan's structured control flow is the hard problem. Lava runs, in order,
`SimplifyCFG → fixup_structured_cfg! → LowerSwitch → UnifyFunctionExitNodes →
FixIrreducible → StructurizeCFG → InstCombine`, where the custom
`fixup_structured_cfg!` inserts trampoline blocks _"analogous to clspv's
`FixupStructuredCFGPass`"_ because otherwise _"StructurizeCFG can produce
incorrect back-edge conditions causing loops to exit after a single
iteration"_ ([`src/compiler/passes/structurize_cfg.jl`][lava-struct]). A
second fix-up, `merge_equivalent_loop_phis!`, removes duplicate loop phis that
StructurizeCFG creates around `continue`. The emitter then recomputes
immediate post-dominators to place `OpSelectionMerge`/`OpLoopMerge`
([`src/compiler/spirv/emit.jl`][lava-emit]).

Even valid output miscompiled. Lava drops LLVM's `SimpleLoopUnswitchPass`
from GPUCompiler's loop pipeline because the resulting structured SPIR-V,
though it passes `spirv-val`, is miscompiled by NVIDIA's shader compiler —
_"a comparison inside one of the unswitched loop bodies silently returns the
wrong result"_ — which corrupted every `isless`-based merge sort
([`src/compiler/target.jl`][lava-target]).

KA's restrictions are explicit: barriers only at top level of the kernel body
under uniform control flow; the deprecated `@synchronize(cond)` is lowered to
an unconditional barrier. Exceptions become traps, dynamic allocation is
unsupported (Lava's `malloc` returns null), recursion and dynamic dispatch are
rejected by IR validation.

## Compilation pipeline and targets

```text
Julia method + arg types
  │  GPUInterpreter (inference with overlay method tables)
LLVM IR (Julia codegen, Julia address spaces)
  │  GPUCompiler optimisation + target finish_module!/finish_ir!
  ├─ PTX / AMDGCN / Metal AIR       (CUDA.jl, AMDGPU.jl, Metal.jl)
  ├─ SPIR-V (kernel)  :llvm  → in-process libspirv (LLVM SPIR-V backend)
  │                   :khronos → in-process libllvm_spirv (translator)
  │                   → spirv-val / spirv-opt (optional)
  └─ Lava: LLVM IR → lift_geps → structurize → prepare_vulkan
           → lower_intrinsics → custom emitter → spirv-val → VkShaderModule
```

For SPIR-V, `mcgen` strips debug info (the tools reject `DW_LANG_Julia`),
removes `freeze` for the translator, and calls either back-end in-process
([`src/spirv.jl`][gpc-spirv]). OpenCL.jl defaults to the LLVM backend; the
translator is opt-in via the `llvm_to_spirv_backend` preference
([`src/compiler/compilation.jl`][ocl-comp]). This corrects the earlier
survey's statement that OpenCL.jl goes through the translator.

**Lava does not use LLVM's SPIR-V backend for codegen**, only GPUCompiler's
triple. Its architecture page, verbatim:

> _"Empirically (as of LLVM 21): **Geometry shaders crash `llc`** during
> instruction selection. No upstream fix is planned. **Ray tracing extensions
> are rejected** ... **Key Vulkan extensions are missing** patterns:
> `SPV_KHR_physical_storage_buffer` (BDA) and `SPV_KHR_variable_pointers` are
> both incomplete."_ ([`architecture.md`][lava-arch])

Checked against upstream LLVM at `27ba493781` (2026-09-19), the substance
holds, with one wording correction:

| Lava's claim                | Upstream LLVM at `27ba493781`                                                                                                                                                                                                                                                                                 |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Geometry shaders crash      | Entry points map only `"compute"`, `"vertex"`, `"pixel"`; anything else hits `report_fatal_error("This HLSL entry point is not supported by this backend.")` ([`SPIRVCallLowering.cpp`][llvm-calllow]). A hard error, not a selector crash — but no geometry, tessellation, mesh or ray-tracing stage either. |
| RT rejected                 | `SPV_KHR_ray_tracing` is only an extension name in `SPIRVCommandLine.cpp`; no RT execution model, storage class or type is lowered ([`SPIRVCommandLine.cpp`][llvm-cmdline]).                                                                                                                                  |
| BDA incomplete              | Address space `1` maps to `CrossWorkgroup` ([`SPIRVUtils.cpp`][llvm-utils]); the shader addressing model is always `Logical` with _"TODO: Add support for PhysicalStorageBufferAddress"_ ([`SPIRVModuleAnalysis.cpp`][llvm-modan]).                                                                           |
| `SPV_KHR_variable_pointers` | No lowering references it under `llvm/lib/Target/SPIRV/*.cpp`.                                                                                                                                                                                                                                                |

The PSB gap is the one sparkles' own LLVM branch closes with a local patch
(the GSoC DCompute PR); see [LLVM SPIR-V backend][llvm-spirv]. Two size facts
need correcting too: `src/compiler/spirv/` is about 13,500 lines at the pinned
SHA (`emit.jl` alone is 8,102), not the _"roughly 6,000 lines"_ the page
states; and `llc` is used as a test oracle only in the OpenCL flavour, because,
per the test header, _"the Vulkan triple crashes on BDA kernels"_
([`test/spirv/test_llc_reference.jl`][lava-llc-test]).

## Host integration and CPU execution

**Host API.** Vulkan.jl is _"a lightweight wrapper around the Vulkan graphics
and compute library"_ whose wrapper _"is generated directly from the Vulkan
Specification"_, in the manner of Vulkan-Hpp ([`README.md`][vk-readme]); Lava
builds its device, memory, command-batch and pipeline layers on it, with
timeline semaphores for retirement and a two-level kernel cache (in memory by
`MethodInstance`, on disk keyed by _"IR hash × Vulkan device fingerprint"_)
([`architecture.md`][lava-arch]). Launch is a call: `vadd!(backend)(c, a, b;
ndrange = 1024)`.

**CPU execution.** Julia's answer has changed. Until 2025-10-06 KA's `CPU`
backend was its own: `split` regions became loops over work-items run on
Julia threads ([`src/cpu.jl`][ka-cpu-old]). Today `const CPU = POCLBackend`:
the kernel goes through the same SPIR-V path as GPU back-ends
(`SPIRVCompilerTarget`, [`src/pocl/compiler/compilation.jl`][ka-pocl-comp])
and runs on PoCL, whose kernel compiler generates work-group functions by
looping over work-items between barriers. The documented price:

> _"PoCL implements sub-group operations (shuffles, votes, and the collectives
> built on them) with barriers across the whole work-group, so it doesn't
> support independent sub-groups ... Otherwise, results are wrong."_
> ([`src/KernelAbstractions.jl`][ka-main])

There is no CPU path for graphics: Lava's fragment and vertex stages run only
on a Vulkan device (lavapipe in CI), and derivatives exist only as `OpDPdx`.
The host can of course call the same Julia functions directly, which is how
GPUArrays' test suite compares results, but that is scalar host code, not a
simulation of a stage.

---

## Lessons for sparkles:shaders

- **Adopt: overlays as the device-substitution mechanism.** GPUCompiler's
  method tables let device semantics replace library functions without forking
  them. D has no overlay table, but the same effect is a device-only
  implementation selected at compile time behind one host-and-device
  declaration; keep the rule `@consistent_overlay` states — the device
  version returns the identical value or throws where the host does — as a
  testable contract in the conformance corpus.
- **Match: barriers need an "active lane" lowering.** KA's `split` exists
  because padding work-items must reach every barrier. A D compute model with
  non-multiple dispatch sizes, and the planned SPMD-on-SIMD CPU executor, need
  the same rule: barrier only under uniform control flow, inactive lanes
  masked rather than returned. Enforce it at compile time, as KA does by
  syntax, rather than discover it on PoCL.
- **Avoid: hiding stage I/O behind intrinsic calls with integer locations.**
  Lava's `gfx_output_vec4(location, ...)` gives no type for the interface,
  so pipeline matching and reflection are impossible statically. sparkles'
  typed `@fragment` parameters marked `@input`/`@uniform` (`SHF2` in the
  [spec][spec]), one variable per interface name across the unit, are the
  better design; keep them.
- **Avoid: a private SPIR-V emitter.** Lava's ~13,500-line emitter is
  forced by gaps (stages, PSB, structurization) that are fixable upstream;
  its own known-issues file shows the cost — layout, phi-duplication and
  cache-collision bugs that `spirv-val` did not see. Fix LLVM's SPIR-V backend
  instead (geometry/tessellation execution models, PSB) and upstream it.
- **Adopt: Lava's debugging order as test strategy.** `spirv-val` then
  GPU-assisted validation, then a GLSL twin compiled by `glslangValidator`
  dispatched through the same harness, then a disassembly diff. A sparkles
  conformance case can carry its GLSL twin and check both.
- **Match: keep `SimpleLoopUnswitch`-class risks in view.** Valid structured
  SPIR-V still miscompiled on NVIDIA. Make the optimisation pipeline for the
  shader target an explicit list, and pin regressions with on-device tests,
  not `spirv-val` alone.
- **Adopt: per-target atomics capability records.** `SPIRVAtomics` encodes
  "runs correctly", not "is native", and derives the extension list from it;
  the D vocabulary's atomics should be gated the same way.

## Strengths

- One language, one compiler, true generics: dispatch, parametric types and
  closures compile to every target with no device dialect.
- Clean compiler seams (`AbstractCompilerTarget`/`AbstractCompilerParams`,
  method tables, `cache_owner`) shared by five vendor back-ends.
- Both SPIR-V producers in-process, selectable per target, with `spirv-val`
  and `spirv-opt` wired in.
- Lava shows a general-purpose language can drive all five rasterisation
  stages and the ray-tracing stages through LLVM IR.
- KA gives a vendor-neutral kernel API plus a CPU backend with the same
  programming model.

## Weaknesses

- No graphics stages outside Lava; KA and GPUCompiler are compute-only.
- Unstructured Julia IR forces heavy CFG repair before Vulkan (trampolines,
  phi merging, StructurizeCFG), each a source of miscompiles.
- Lava is young (first commit 2026-03-01, unregistered, depends on
  GPUCompiler internals per its `Project.toml`), its graphics API untyped and
  evolving, and it has no fragment kill primitive as read.
- CPU execution delegates to PoCL: no independent sub-groups, no graphics
  stages, and a C toolchain dependency (`pocl_standalone_jll`).
- BDA-only resource access defeats GPU-assisted validation and pushes
  layout correctness onto the emitter.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                                        | Trade-off                                                              |
| ------------------------------------------- | ---------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Reuse Julia inference + codegen for devices | Full language on device; no second front-end                     | Must reject dynamic features after the fact (`KernelError`)            |
| Method-table overlays for device semantics  | Replace library behaviour without forking packages               | Overlay consistency is a contract the compiler cannot fully check      |
| Target vs params split in GPUCompiler       | Generic codegen shared; vendor state stays in vendor packages    | Back-ends still reach into internals (Lava pins GPUCompiler)           |
| `@synchronize` split syntactically in KA    | Padding lanes reach every barrier; same code on all back-ends    | Barriers only at kernel top level, never in helper functions           |
| KA CPU backend → PoCL over SPIR-V           | One compilation path for CPU and GPU; less code to maintain      | Sub-groups serialised by barriers; external runtime dependency         |
| Lava: custom LLVM-IR → SPIR-V emitter       | Graphics, RT, PSB available now despite LLVM gaps                | ~13.5 k lines to own; bugs `spirv-val` does not catch                  |
| Lava: one BDA push constant per dispatch    | No descriptor sets, no 256-byte push limit, uniform buffer model | Invisible to GPU-AV; layout and alignment become the emitter's problem |
| Lava: stage I/O as located intrinsic calls  | Simple to emit; no interface type system needed                  | No static interface checking or reflection                             |

---

## Sources

- [GPUCompiler.jl — `README.md`][gpc-readme]
- [GPUCompiler.jl — `src/interface.jl` (target/params/config, method tables, cache owner)][gpc-interface]
- [GPUCompiler.jl — `src/spirv.jl` (SPIR-V target, `mcgen`, atomics)][gpc-spirv]
- [GPUCompiler.jl — `src/driver.jl` (deferred codegen)][gpc-driver]
- [GPUCompiler.jl — `src/jlgen.jl` (`SHARED_METHOD_TABLE`)][gpc-jlgen]
- [GPUCompiler.jl — `src/runtime.jl` (device runtime library)][gpc-runtime]
- [KernelAbstractions.jl — `README.md`][ka-readme] · [`src/macros.jl`][ka-macros] · [`src/KernelAbstractions.jl`][ka-main] · [`lib/KernelInterface/src/device.jl`][ki-device]
- [KernelAbstractions.jl — `src/pocl/compiler/compilation.jl`][ka-pocl-comp] · [`src/pocl/device/quirks.jl`][ka-quirks] · [removed `src/cpu.jl` (parent of #630)][ka-cpu-old]
- [KernelAbstractions documentation][ka-docs]
- [Lava.jl — `README.md`][lava-readme] · [`docs/src/architecture.md`][lava-arch] · [`docs/src/graphics.md`][lava-gfx-doc] · [`spirv-intrinsics.md`][lava-intr] · [`KNOWN_ISSUES.md`][lava-issues]
- [Lava.jl — `src/compiler/target.jl`][lava-target] · [`src/compiler/entry_wrapper.jl`][lava-wrapper] · [`src/compiler/passes/structurize_cfg.jl`][lava-struct] · [`src/compiler/passes/prepare_vulkan.jl`][lava-prep] · [`src/compiler/spirv/emit.jl`][lava-emit] · [`src/compiler/spirv/graphics.jl`][lava-gfx] · [`src/device/gfx_intrinsics.jl`][lava-gfxi] · [`test/spirv/test_llc_reference.jl`][lava-llc-test]
- [OpenCL.jl — `lib/intrinsics/src/utils.jl` (`@device_override`)][ocl-utils] · [`src/compiler/compilation.jl` (back-end preference)][ocl-comp]
- [Vulkan.jl — `README.md`][vk-readme]
- LLVM upstream `27ba493781`: [`SPIRVCallLowering.cpp`][llvm-calllow] · [`SPIRVUtils.cpp`][llvm-utils] · [`SPIRVModuleAnalysis.cpp`][llvm-modan] · [`SPIRVCommandLine.cpp`][llvm-cmdline]
- Related: [LLVM SPIR-V backend][llvm-spirv] · [rust-gpu][rust-gpu] · [ILGPU][ilgpu] · [SYCL][sycl] · [ISPC][ispc] · [dcompute][dcompute] · [concepts][concepts] · [comparison][comparison] · [umbrella][index] · [sparkles:shaders spec][spec]

<!-- References -->

[gpc-repo]: https://github.com/JuliaGPU/GPUCompiler.jl
[gpc-readme]: https://github.com/JuliaGPU/GPUCompiler.jl/blob/8cef0389e1aa9146150eb707b97eb4e3ab421ecf/README.md
[gpc-interface]: https://github.com/JuliaGPU/GPUCompiler.jl/blob/8cef0389e1aa9146150eb707b97eb4e3ab421ecf/src/interface.jl
[gpc-spirv]: https://github.com/JuliaGPU/GPUCompiler.jl/blob/8cef0389e1aa9146150eb707b97eb4e3ab421ecf/src/spirv.jl
[gpc-driver]: https://github.com/JuliaGPU/GPUCompiler.jl/blob/8cef0389e1aa9146150eb707b97eb4e3ab421ecf/src/driver.jl
[gpc-jlgen]: https://github.com/JuliaGPU/GPUCompiler.jl/blob/8cef0389e1aa9146150eb707b97eb4e3ab421ecf/src/jlgen.jl
[gpc-runtime]: https://github.com/JuliaGPU/GPUCompiler.jl/blob/8cef0389e1aa9146150eb707b97eb4e3ab421ecf/src/runtime.jl
[ka-repo]: https://github.com/JuliaGPU/KernelAbstractions.jl
[ka-docs]: https://juliagpu.github.io/KernelAbstractions.jl/stable
[ka-readme]: https://github.com/JuliaGPU/KernelAbstractions.jl/blob/4279ce1ef3b61bbf08fb733dd8dfa9e97e2395f0/README.md
[ka-macros]: https://github.com/JuliaGPU/KernelAbstractions.jl/blob/4279ce1ef3b61bbf08fb733dd8dfa9e97e2395f0/src/macros.jl
[ka-main]: https://github.com/JuliaGPU/KernelAbstractions.jl/blob/4279ce1ef3b61bbf08fb733dd8dfa9e97e2395f0/src/KernelAbstractions.jl
[ki-device]: https://github.com/JuliaGPU/KernelAbstractions.jl/blob/4279ce1ef3b61bbf08fb733dd8dfa9e97e2395f0/lib/KernelInterface/src/device.jl
[ka-pocl-comp]: https://github.com/JuliaGPU/KernelAbstractions.jl/blob/4279ce1ef3b61bbf08fb733dd8dfa9e97e2395f0/src/pocl/compiler/compilation.jl
[ka-quirks]: https://github.com/JuliaGPU/KernelAbstractions.jl/blob/4279ce1ef3b61bbf08fb733dd8dfa9e97e2395f0/src/pocl/device/quirks.jl
[ka-cpu-old]: https://github.com/JuliaGPU/KernelAbstractions.jl/blob/1ac546fc59cc611d749fa7a50e4a1efa3393851b/src/cpu.jl
[lava-repo]: https://github.com/SimonDanisch/Lava.jl
[lava-readme]: https://github.com/SimonDanisch/Lava.jl/blob/11c7e31bdf62408d22bf379e9e59510f69d2103e/README.md
[lava-arch]: https://github.com/SimonDanisch/Lava.jl/blob/11c7e31bdf62408d22bf379e9e59510f69d2103e/docs/src/architecture.md
[lava-gfx-doc]: https://github.com/SimonDanisch/Lava.jl/blob/11c7e31bdf62408d22bf379e9e59510f69d2103e/docs/src/graphics.md
[lava-intr]: https://github.com/SimonDanisch/Lava.jl/blob/11c7e31bdf62408d22bf379e9e59510f69d2103e/spirv-intrinsics.md
[lava-issues]: https://github.com/SimonDanisch/Lava.jl/blob/11c7e31bdf62408d22bf379e9e59510f69d2103e/KNOWN_ISSUES.md
[lava-target]: https://github.com/SimonDanisch/Lava.jl/blob/11c7e31bdf62408d22bf379e9e59510f69d2103e/src/compiler/target.jl
[lava-wrapper]: https://github.com/SimonDanisch/Lava.jl/blob/11c7e31bdf62408d22bf379e9e59510f69d2103e/src/compiler/entry_wrapper.jl
[lava-struct]: https://github.com/SimonDanisch/Lava.jl/blob/11c7e31bdf62408d22bf379e9e59510f69d2103e/src/compiler/passes/structurize_cfg.jl
[lava-prep]: https://github.com/SimonDanisch/Lava.jl/blob/11c7e31bdf62408d22bf379e9e59510f69d2103e/src/compiler/passes/prepare_vulkan.jl
[lava-emit]: https://github.com/SimonDanisch/Lava.jl/blob/11c7e31bdf62408d22bf379e9e59510f69d2103e/src/compiler/spirv/emit.jl
[lava-gfx]: https://github.com/SimonDanisch/Lava.jl/blob/11c7e31bdf62408d22bf379e9e59510f69d2103e/src/compiler/spirv/graphics.jl
[lava-gfxi]: https://github.com/SimonDanisch/Lava.jl/blob/11c7e31bdf62408d22bf379e9e59510f69d2103e/src/device/gfx_intrinsics.jl
[lava-llc-test]: https://github.com/SimonDanisch/Lava.jl/blob/11c7e31bdf62408d22bf379e9e59510f69d2103e/test/spirv/test_llc_reference.jl
[ocl-repo]: https://github.com/JuliaGPU/OpenCL.jl
[ocl-utils]: https://github.com/JuliaGPU/OpenCL.jl/blob/7011fe155bb0721ddb05baae4cd76550d566e313/lib/intrinsics/src/utils.jl
[ocl-comp]: https://github.com/JuliaGPU/OpenCL.jl/blob/7011fe155bb0721ddb05baae4cd76550d566e313/src/compiler/compilation.jl
[vk-repo]: https://github.com/JuliaGPU/Vulkan.jl
[vk-readme]: https://github.com/JuliaGPU/Vulkan.jl/blob/ce3eaccfa4b56f94e40a150dfc54f1564d3a339a/README.md
[llvm-calllow]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVCallLowering.cpp
[llvm-utils]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVUtils.cpp
[llvm-modan]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVModuleAnalysis.cpp
[llvm-cmdline]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVCommandLine.cpp
[llvm-spirv]: ./llvm-spirv-backend.md
[rust-gpu]: ./rust-gpu.md
[ilgpu]: ./ilgpu.md
[sycl]: ./sycl.md
[ispc]: ./ispc.md
[dcompute]: ./dcompute.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[spec]: ../../specs/shaders/SPEC.md
