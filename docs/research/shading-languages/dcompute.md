# dcompute and `sparkles:shaders` (D / LDC)

The baseline this catalog exists to improve: LDC's dcompute compiles marked D modules to GPU code through LLVM, a pending upstream pull request adds a Vulkan target that emits SPIR-V, a sparkles fork of LDC adds a fragment stage on top, and `sparkles:shaders` turns that fork's output into GLSL for OpenGL consumers.

| Field          | Value                                                                                                                                                                                                                                                                                       |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | D (device subset), compiled by LDC; the fork's code generator is C++                                                                                                                                                                                                                        |
| License        | LDC: BSD-style LDC license, with the Vulkan target file under the LLVM license (it adapts Clang code); druntime `ldc.dcompute`: Boost 1.0; `libmir/dcompute`: Boost 1.0; `sparkles:shaders`: BSL-1.0                                                                                        |
| Repository     | Upstream [ldc-developers/ldc][ldc-dcompute-d] at `ac0e420a` (2026-09-11); Vulkan target [ldc-developers/ldc#5132][pr5132] (unmerged at that pin); sparkles fork [PetarKirov/ldc][fork-target] `sparkles/vulkan-shaders` at `64104a9a` (2026-10-17); library [`libmir/dcompute`][lib-readme] |
| Documentation  | In-source DDoc ([`ldc/dcompute.d`][ldc-dcompute-d]); the [`libmir/dcompute` README][lib-readme]; for sparkles, [`SPEC.md`][spec], [`decisions.md`][decisions], [`PLAN.md`][plan], [`testing.md`][testing]                                                                                   |
| Category       | Single-source GPU compilation inside a general-purpose systems-language compiler                                                                                                                                                                                                            |
| Latest version | LDC `v1.43.0` (2026-08-30); `libmir/dcompute` `v0.1.1` (2025-06-12); the fork reports "LDC 1.43.0, DMD v2.113.0, LLVM 24.0.0git"                                                                                                                                                            |
| Targets        | Upstream: OpenCL SPIR-V (`ocl-100`…`ocl-220`), CUDA PTX (`cuda-*`). PR #5132: Vulkan SPIR-V compute (`vulkan-100`…`vulkan-140`). Fork: + Vulkan-flavoured fragment shaders. `sparkles:shaders`: GLSL 3.30 and GLSL ES 1.00 via `spirv-cross`                                                |
| Stages         | Upstream/PR: compute kernels only. Fork: compute + fragment; every other stage value is a compile error                                                                                                                                                                                     |
| LLVM           | Upstream main `27ba4937` (2026-09-19) plus seven local SPIR-V patches, vendored by `PetarKirov/dlang.nix` `d4063afb` ([`#647`][issue647] tracks upstreaming)                                                                                                                                |
| Host languages | D only; host launch API in `libmir/dcompute` for OpenCL and CUDA; no Vulkan host API anywhere                                                                                                                                                                                               |

---

## Overview

### What it solves

dcompute's premise is that the GPU dialect should be D itself: the same frontend, templates, CTFE, `static foreach` and UFCS, with a semantic pass that bans what a GPU cannot do. A module opts in with a UDA, and LDC compiles it a second time per `-mdcompute-targets=` entry with a target-specific LLVM backend. The druntime module states the model in one sentence ([`ldc/dcompute.d`][ldc-dcompute-d]):

> "When applied to a module, specifies that the module should be compiled for dcompute (`-mdcompute-targets=<...>`) using the NVPTX and/or SPIRV backends of LLVM."

`sparkles:shaders` applies that machinery to a problem dcompute never targeted: visual effects that must behave identically as a fragment shader and as a CPU function called once per terminal cell. Its specification frames it as ([`SPEC.md`][spec], Abstract):

> "`sparkles:shaders` lets a D program write a per-pixel effect's computation once, as an ordinary D function, and run it in two places: on the CPU, where any D compiler calls it directly, and on the GPU, where the same source is compiled into a fragment shader, behind a thin entry point that reads its inputs and uniforms, samples its textures and calls it."

### Design philosophy

Three layers, each with its own stance:

1. **dcompute (upstream) is a restriction pass plus address spaces.** It adds no GPU-specific types beyond `Pointer!(AddrSpace, T)`, a handful of UDAs and a codegen-time conditional (`__dcompute_reflect`). Everything else — indices, barriers, atomics — lives in the separate `libmir/dcompute` library as `pragma(LDC_intrinsic)` declarations selected per target.
2. **The fork synthesises the shader interface from the D signature.** Decision [`D2`][decisions] records why it is a compiler change and not a library: "A fragment entry point needs interface variables with locations, a uniform per parameter, images with bindings and an output variable — SPIR-V module-level declarations a D library cannot emit."
3. **`sparkles:shaders` is a vocabulary with a CPU twin and an agreement oracle.** GLSL names and definitions (`mod` with the sign of the divisor, `smoothstep`'s polynomial) are implemented once in D; the device build reaches them through LLVM intrinsics that lower to `GLSL.std.450`, and the host build calls the very same functions. Agreement is judged against the Vulkan precision table ([`D12`][decisions]).

This is the [single-source][concepts] model in its narrowest form: one function, two compilations, no runtime reflection, and a scope that the specification deliberately confines to the fragment stage.

---

## How it works

### Upstream dcompute

- **Module marking.** `@compute(CompileFor.deviceOnly)` (the default) compiles a module only for the device; `CompileFor.hostAndDevice` compiles it for both ([`ldc/dcompute.d`][ldc-dcompute-d]). Each device target gets its own `IRState` and LLVM module (`DComputeTarget` in [`gen/dcompute/target.h`][fork-target-h]).
- **Kernels.** `@kernel([x, y, z])` marks an entry point (CUDA `__global__`, OpenCL `__kernel`). The bounds became the Vulkan `numthreads` in PR #5132.
- **Address spaces.** `Pointer!(AddrSpace as, T)` is a struct wrapping `T*` with `alias ptr this`; the compiler recognises it and gives the pointer the target's address space through a per-target five-entry table. `AddrSpace` is `Private = 0, Global = 1, Shared = 2, Constant = 3, Generic = 4`; the CUDA target maps it to `{5, 1, 3, 4, 0}` and OpenCL to the identity ([`targetCUDA.cpp`][up-cuda], [`targetOCL.cpp`][up-ocl]).
- **Codegen-time conditionals.** `__dcompute_reflect(ReflectTarget.CUDA, 0)` folds to a constant per target, so one generic function picks an intrinsic per backend; `ReflectTarget` already reserves `Vulkan = 3` upstream.
- **Device rules.** [`gen/semantic-dcompute.cpp`][up-sema] bans classes, interfaces, global variables, associative arrays, dynamic array literals, string literals, `new`/`delete`, `~`, `typeid`, inline asm, exceptions, string `switch`, function pointers and delegates, `synchronized`, and calls into non-`@compute` modules. Its header comment: "enforce: @nogc, nothrow, all function calls are to modules that are also @compute."
- **Embedding.** By default the device binary is embedded into the host object as a `__dcompute_<suffix>_…` global (`-fembed-dcompute`, default true, [`driver/cl_options.cpp`][up-clopts]).

### The library: `libmir/dcompute`

`dcompute.std.index` exposes `GlobalIndex.x`, `SharedIndex.linear` and friends, each a `__dcompute_reflect` chain over OpenCL and CUDA intrinsics, and `assert(0)` otherwise ([`std/index.d`][lib-index]). `dcompute.std.sync.barrier()` does the same for OpenCL `barrier` and CUDA `barrier_n`. `dcompute.std.warp` is a 19-line comment listing the intended vote/shuffle/reduce API — **no warp operation is implemented** ([`std/warp.d`][lib-warp]). The host driver launches a kernel type-safely through reflection: `q.enqueue!(saxpy)([N,1,1],[1,1,1])(b_res, alpha, b_x, b_y, N)`, where `HostArgsOf!(typeof(k))` rewrites each `Pointer` parameter to a host `Buffer` ([`driver/util.d`][lib-util]). There is no Vulkan branch in the library.

### The Vulkan target (ldc-developers/ldc#5132)

`TargetVulkan` ([`targetVulkan.cpp`][fork-target]) uses the triple `spirv1.6-unknown-vulkan1.3-compute` and "fakes being HLSL": for each `@kernel` it creates a `void()` wrapper named `<mangle>_kernel` with `"hlsl.shader"="compute"` and `"hlsl.numthreads"`, packs **all** kernel parameters into one struct in one read-only StorageBuffer (`spirv.VulkanBuffer(args, 12, 0)`, set 0 binding 0), loads each field through `llvm.spv.resource.getpointer`, and `inttoptr`s pointer parameters back to their dcompute address space. The Vulkan compute ABI is therefore "one SSBO of 64-bit buffer device addresses", not one descriptor per buffer. The version suffix (`vulkan-130`) is accepted but does not change the triple.

### The fork's fragment stage

The fork adds `@fragment`, `@input`, `@uniform`, `Sampler2D` and `SamplerState` to druntime and an `addShaderEntry` hook to every target (non-Vulkan targets reject it). A sparkles effect entry point ([`libs/ui/shaders/effects.d`][effects]):

```d
@compute(CompileFor.deviceOnly)
module effects;

import sparkles.shaders;

@fragment vec4 curvature(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, @uniform float uAmount)
{
    const uv = sparkles.ui.effect_shaders.curvature(fragTexCoord, uAmount);
    if (uv.x < 0.0f || uv.x > 1.0f || uv.y < 0.0f || uv.y > 1.0f)
        return v4(0.0f);
    return texture0.sample(uv) * fragColor;
}
```

`addShaderEntry` builds a new `void()` function named after the D identifier with `"hlsl.shader"="pixel"`, makes the D function internal and `alwaysinline`, and for each parameter emits (abridged from [`targetVulkan.cpp`][fork-target]):

- `@input` → an addrspace-7 (`Input`) global, `thread_local externally_initialized`, `spirv.Decorations` `Location n` in parameter order;
- `@uniform` → an addrspace-2 (`UniformConstant`) global **outside any block**; structs and static arrays get a separate LLVM struct with members in declaration order, named through `spirv.MemberNames`, converted back to the D layout with `insertvalue`;
- `Sampler2D` → `llvm.spv.resource.handlefrombinding` of `spirv.Image(float, 2D, depth=2, arrayed=0, ms=0, sampled=1, Unknown)` at binding 1, 2, … of set 0; every image is sampled through one `spirv.Sampler` at binding 0 (`__spirv_shared_sampler()`, lowered by `DtoLowerMagicIntrinsic`);
- the return value → an addrspace-8 `Output` global named `finalColor` at location 0.

```llvm
; the shape addrspace-7/8 interface variables take (abridged)
@fragTexCoord = external hidden thread_local addrspace(7) externally_initialized constant <2 x float>, !spirv.Decorations !0
@finalColor   = external hidden thread_local addrspace(8) externally_initialized global <4 x float>, !spirv.Decorations !1
define void @curvature() #0 { ... }   ; attributes #0 = { "hlsl.shader"="pixel" }
```

`sample(S : Sampler2D)` is a druntime template over a `pragma(LDC_intrinsic, "llvm.spv.resource.sample.v4f32.tspirv.Image_f32_1_2_0_0_1_0t.tspirv.Samplert.v2f32.v2i32")` declaration — the image type is spelled inside the intrinsic's mangled name ([`ldc/dcompute.d` in the fork][fork-dcompute-d]).

### The build step

`shader-compile` ([`apps/shader-compile/src/app.d`][app]) asks `dub describe` for the package's device configuration, classifies modules lexically by their `@compute` attribute ([`compute_mode.d`][compute-mode]), compiles the whole unit in one `ldc2-vulkan -O2 -c -m64 -mdcompute-targets=vulkan-130` call, then runs `spirv-val --target-env spv1.6` → `spirv-opt -O` → `spirv-cross --entry <e> --stage frag --remove-unused-variables` for `--version 330` and `--es --version 100` → a regex that renames `SPIRV_Cross_Combined<image>sampler` back to the D parameter name → `glslangValidator`. Output is atomic, provenance-stamped and never committed ([`SPEC.md`][spec] `SHP1`–`SHP10`).

---

## Execution model and stages

| Stage                 | Upstream dcompute     | PR #5132                | Fork (`64104a9a`)                            | LLVM SPIR-V backend at `27ba4937`                              |
| --------------------- | --------------------- | ----------------------- | -------------------------------------------- | -------------------------------------------------------------- |
| Compute               | `@kernel` (CUDA, OCL) | `@kernel` → `GLCompute` | same                                         | `hlsl.shader="compute"`                                        |
| Fragment              | —                     | —                       | `@fragment` → `Fragment` (`OriginUpperLeft`) | `"pixel"`                                                      |
| Vertex                | —                     | —                       | `ShaderStage` has only `fragment = 0`        | `"vertex"` is mapped, unused by any frontend in D              |
| Geometry/tess/mesh/RT | —                     | —                       | "unsupported shader stage %d"                | `report_fatal_error` ([`SPIRVCallLowering.cpp`][llvm-calllow]) |

The fork's `ShaderStage` enum has one member; any other value fails with "unsupported shader stage" (`SHF7`). Compute thread IDs are not in druntime; tests and probes declare `pragma(LDC_intrinsic, "llvm.spv.thread.id.i32")` themselves ([`vulkan_global_pointer_index.d`][fork-test-gpi]). There are no builtins (`gl_FragCoord`, `gl_Position`, `FrontFacing`, `FragDepth`), no interpolation qualifiers, no execution-mode UDAs, and no per-stage I/O struct: inputs are parameters and the single output is the return value. A fragment-only design with one implicit colour output is the defining gap against every language subject in this catalog — compare [GLSL][glsl]'s per-stage built-in variables, [HLSL][hlsl]'s semantics, and [Slang][slang]'s and [rust-gpu][rust-gpu]'s per-stage entry attributes.

## Type system and generic programming

Device code gets all of D's compile-time machinery: templates, CTFE, `static foreach`, UFCS, structs with operator overloading, `alias` parameters. The effects module uses an `alias transform` template parameter to wrap every effect in one bracket (`tier0!(…scanlines)`), which neither GLSL nor WGSL can express and HLSL only with templates. What the type system lacks for shaders:

- **Vectors.** `__vector` element types are void, (u)byte, (u)short, (u)int, (u)long, float, double — no `bool`, no `half`. Vector `==` yields a mask under LDC and a `bool` on the struct fallback, so the vocabulary forbids `==` and provides `allEqual` (`SHV1`). A `__vector` has no members, so swizzles are UFCS functions (`c.xyz`, `p.x`) and writable swizzles do not exist; `ldc.simd.shufflevector` is rejected in device code because the fork's call whitelist names only `ldc.intrinsics` and `ldc.dcompute` ([`semantic-dcompute.cpp` in the fork][fork-sema]).
- **`vec3`.** A released host LDC sizes `__vector(float[3])` at 12 bytes while LLVM allocates 16; the fork patches the frontend (`dmd/typesem.d`, `version (IN_LLVM)`) and the vocabulary keeps `vec3` a 16-byte-aligned struct on the host (`SHV2`, [`D9`][decisions], [`types.d`][types]).
- **No matrices, no integer or double vectors** in the vocabulary (an explicit exclusion in [`decisions.md`][decisions]); the LLVM backend has no matrix type either.
- **No interfaces or generics over shader resources.** There is no equivalent of Slang `interface`/`associatedtype` or HLSL resource templates: `Sampler2D` is a hard-coded struct recognised by name (`Id::dcSampler2D`) in [`gen/dcompute/druntime.cpp`][fork-druntime-cpp], and a templated `Image!(T, Dim, …)` would need the type map to read template arguments.
- **Inert stand-ins.** Without `LDC_DCompute`, [`attributes.d`][attributes] defines `compute`, `fragment`, `input`, `uniform`, `Sampler2D` as plain D declarations, so host-and-device modules compile under DMD and stock LDC (`SHV8`).

## Resources, interfaces and memory layout

| Resource kind     | Today                                                                                        | Gap                                                                                                            |
| ----------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Varyings          | `@input` float/vec2–4, positional `Location`                                                 | no `@location(n)`, no `flat`/`noperspective`/`centroid`, no integer varyings (ES 1.00 limit)                   |
| Uniforms          | `@uniform` plain `UniformConstant` globals, int/float/vectors/structs/arrays; `uint` refused | invalid for Vulkan (VUID-04655); no UBO, no push constants, no std140/std430 layout                            |
| Textures          | `Sampler2D` only, binding 1…; one shared sampler at binding 0                                | no 3D/cube/array/depth/MS/integer images, no storage images, no per-image samplers, no resource arrays         |
| Buffers (compute) | `GlobalPointer!T` = PhysicalStorageBuffer address in an args SSBO                            | no descriptor-bound SSBO; HLSL via `spirv-cross` impossible (Logical addressing only)                          |
| Workgroup memory  | address space mapped correctly since `488d5239`                                              | **no way to declare it**: module-scope variables are banned (`semantic-dcompute.cpp`), so no `Shared!T` arrays |
| Constants         | static-array literals in function scope                                                      | no module-scope `immutable` tables; no spec constants                                                          |

Interface names are a contract with the host, which binds by name, so the fork rejects names `spirv-cross` would rewrite: its reserved-word list, `gl_`/`spv` prefixes, non-ASCII, `__` runs, `_<digits>`, `_m<digits>` (`unreservedRefusal`). One interface name is one variable across the module: kind, D type and location/binding must agree across entry points, or the error names both (`recordInterfaceUse`). These diagnostics are D-level, pointing at the parameter — the [`D13`][decisions] rationale. Layout is the device's scalar DataLayout; `vec3` is 16 bytes on both sides, which is **neither** scalar nor `std140` (std140 packs a following scalar at offset 12), so any future block needs a layout the frontend computes — the problem [TypeGPU][typegpu] and [ComputeSharp][computesharp] solve with schemas and generated packing.

## Built-in library and intrinsics

The vocabulary ([`math.d`][math]) provides `floor`, `abs`, `min`, `max`, `sqrt`, `sin`, `cos`, `exp`, `pow`, `mod`, `fract`, `clamp`, `mix`, `step`, `smoothstep`, `dot`, `length` and `luma`. Primitives call `ldc.intrinsics` (`llvm_floor`, `llvm_sin`, …), which the SPIR-V backend lowers to `GLSL.std.450` and x86 to instructions; compound functions are written once from the primitives per the GLSL definitions. Deliberately avoided: `llvm.minnum`/`maxnum`, which lower to `NMin`/`NMax` and come back from `spirv-cross` as `isnan` logic. Texture access is `sample(Sampler2D, vec2)` only.

Everything else exists in LLVM as `llvm.spv.*` intrinsics ([`IntrinsicsSPIRV.td`][llvm-intr]) and is reachable today only by hand-written `pragma(LDC_intrinsic)` declarations, which the fork's whitelist does not even need: discard, `ddx`/`ddy`/`fwidth` (coarse/fine), wave/quad operations, barriers, thread/group IDs, `length`/`normalize`/`reflect`/`refract`/`faceforward`, `firstbit*`, `pack/unpackhalf2x16`, `sample{bias,grad,level,cmp}`, `gather`, `getdimensions`. A session probe (scratchpad `research-toolchain.md` §5) compiled discard, `ddx.coarse`, `fwidth` and `wave.reduce.sum` this way into valid SPIR-V. `libmir/dcompute` covers OpenCL/CUDA indices, barriers, atomics and some math; none of it has a Vulkan branch. There is no `cross`, no matrix built-ins, no atomics on Vulkan in any D library.

## Control flow, memory model and restrictions

- **Structured control flow.** The SPIR-V backend structurizes in-tree (`SPIRVStructurizer`), but optimised, convergence-token-free IR from LDC broke it on everyday D (`else if (a && b)` nested in an `if`; early returns among `||` masks — sparkles issue `#618`). Commit `64104a9a` runs LLVM's own `FixIrreducible`, `UnifyLoopExits` and `StructurizeCFG` on every Vulkan function after optimisation ([`gen/optimizer.cpp`][fork-opt]), "as the GPU targets that need structured control flow do" (AMDGPU's pipeline); the new test validates loops that return, break and continue at `-O0` and `-O2` under `vulkan1.3` ([`vulkan_structured_control_flow.d`][fork-test-scf]). LDC still emits no convergence tokens, so wave operations after divergent exits have no tested semantics.
- **Recursion** is an error since `7016b47427`: an SCC walk over LLVM's call graph reports "device code may not recurse: `…` calls itself / call each other" at the first D function ([`dcompute_vulkan_recursion.d`][fork-test-rec]). Before, it compiled and crashed `spirv-cross`.
- **Everything inlines.** `addMetadata` makes every non-entry function internal and `alwaysinline`, because "a resource handle can only be consumed in the function that obtained it". The SPIR-V therefore never has real functions; `SHF6` makes this a contract.
- **Device rules** are upstream's ban list plus the global-variable ban, which is what blocks workgroup memory and lookup tables.
- **Memory model.** No D-level vocabulary: no memory scopes, no `atomicrmw syncscope` mapping, no `coherent`/`volatile` image qualifiers. D's own `shared`/`core.atomic` semantics are not connected to SPIR-V scopes. Upstream D has no formal memory model either.
- **Integer semantics.** D integers are signed and LLVM's are signless; the module flag `spirv.signed-integers` (a local LLVM patch) makes the backend emit signed types so `int` reaches GLSL as `int`. Integer bit operations, shifts and `%` produce valid SPIR-V that `glslang` rejects for GLSL ES 1.00 — nothing in the fork or the build step checks the ES subset.
- **Helper lanes / discard.** With SPIR-V 1.6 (fixed in `8a79405e28`; before it the backend silently emitted 1.4), `llvm.spv.discard` lowers to `OpDemoteToHelperInvocation`, which does not terminate; a local LLVM patch adds `llvm.spv.terminate.invocation`. Neither is in druntime.

## Compilation pipeline and targets

```text
D source (@compute modules)
  └─ DMD frontend + LDC semantic-dcompute (device rules)
      └─ LLVM IR per target (triple spirv1.6-unknown-vulkan1.3-compute)
          ├─ addMetadata: rejectRecursion, internalise + alwaysinline
          ├─ -O2 default pipeline (or AlwaysInliner+SROA+mem2reg at -O0)
          ├─ FixIrreducible → UnifyLoopExits → StructurizeCFG
          └─ LLVM SPIR-V backend (+7 local patches) → .spv
              └─ spirv-opt -O, in place, if on PATH (silent dependency)
shader-compile: spirv-val spv1.6 → spirv-opt -O → spirv-cross {330, ES 100} → rename → glslangValidator
```

Facts that bound what the pipeline can become:

- **Patch stack.** Seven commits on LLVM `27ba4937` (local branch `sparkles/spirv-shader-ints`): PhysicalStorageBuffer addressing and block wrapping (llvm/llvm-project#216919, someone else's PR), signed integers + `OpMemberName` for shader interfaces, 32-bit access-chain literals, buffer device addresses on request indexed by `OpPtrAccessChain` (module flag `spirv.physical-storage-buffer`), no materialised resource-name string, `llvm.spv.terminate.invocation`, and merge blocks for nested conditions sharing an exit. Twenty-six fork commits sit on LDC `ac0e420a`, including PR #5132's two and an LLVM-24 compatibility fix. No released LLVM can build the toolchain; each LLVM bump is a three-platform rebuild.
- **The backend's horizon.** Only `compute`, `vertex` and `pixel` execution models; Geometry, Tessellation, SampleRateShading, ClipDistance, cube arrays, InputAttachment and MultiViewport capabilities are never available in the shader environment ([`SPIRVModuleAnalysis.cpp`][llvm-modan]); no matrix type; address spaces stop at 13 (`PushConstant`), with none for ray-tracing or task payload storage classes ([`SPIRVUtils.cpp`][llvm-utils]). Upstream, address space 1 is `CrossWorkgroup`; PSB is a local patch.
- **One translator.** `spirv-cross` is the only route to GLSL/HLSL/MSL; WGSL needs [Tint][tint] or [naga][naga]. Compute kernels (PSB) cannot reach HLSL at all. See [`spirv-cross.md`][spirv-cross] and [`llvm-spirv-backend.md`][llvm-spirv].
- **No DXIL path.** LDC does not configure LLVM's DirectX backend; the plan's DXIL route (see [`clang-hlsl.md`][clang-hlsl], [`dxc.md`][dxc]) has no D frontend work yet.
- **Spec drift.** `SPEC.md` `SHT1` still pins the fork at `8ba52d40`, while `flake.lock` (dlang.nix `d4063afb`, commit `4000736a4`) already builds `64104a9a`.

## Host integration and CPU execution

The **CPU half is real for the vocabulary, absent for everything else.** A `hostAndDevice` module is ordinary D: `sparkles:ui` calls `sparkles.ui.effect_shaders.scanlines(at, extent, rgb)` once per terminal cell, and the device entry point calls the same function per fragment. The oracle is a GPU readback test (`ui_raylib.shader_readback`) that renders the generated GLSL on CI's software rasterizer and compares against the host within the [`D12`][decisions] bounds; tests live in host-only modules because a test name is a string literal ([`testing.d`][testing-d], `SHM4`).

What has no CPU meaning today: the entry point itself (`Sampler2D.sample` names a SPIR-V intrinsic, so a device-only module "need not compile" on the host), derivatives, wave operations, barriers, workgroup memory, texture filtering. `libmir/dcompute`'s index functions end in `assert(0)` on the host. Nothing resembles [ILGPU][ilgpu]'s CPU accelerator, [CUDA][cuda]'s host/device split, [ISPC][ispc]'s SPMD-on-SIMD or [rust-gpu][rust-gpu]'s practice of running `spirv-std` shader crates on the CPU — the "full CPU simulator" of the owner's plan starts from zero beyond pure math.

Host-side binding is by name and by D type: OpenGL consumers look up `fragTexCoord`, `uExtentCells`, `texture0`. There is no reflection output (no descriptor-set layout, no push-constant range, no JSON), no generated host struct for a uniform block, and no Vulkan, Metal or D3D host API. dcompute's own type-safe launch (`HostArgsOf`) exists only for OpenCL and CUDA.

---

## Lessons for sparkles:shaders

- **Adopt: interface synthesis from the D signature, with D-level diagnostics.** The fork's best property is that every refusal names the D parameter, its type and the reason, and every clash names both entry points. Keep this as the house rule for every new stage, builtin and resource kind.
- **Match: the HLSL-shaped IR Clang emits.** The fork works because it copies what the backend is tested against (`hlsl.shader`, `handlefrombinding`, addrspace-7/8 globals with `spirv.Decorations`). Vertex, builtins, UBO/SSBO/push constants and storage images should follow the same recipe ([`clang-hlsl.md`][clang-hlsl]) before any LLVM change is considered.
- **Replace: the global-variable ban.** Workgroup memory (`Shared!T` at module scope), `immutable` lookup tables (Private with an initializer) and spec constants all need a device-aware rule in `semantic-dcompute.cpp`, not the blanket `isDataseg()` error.
- **Replace: hard-coded handle types.** `Sampler2D` recognised by identifier, with its image type spelled in an intrinsic's mangled name, does not scale to the dozens of image/buffer kinds HLSL and Slang have. One templated `Image!(T, dim, arrayed, ms, sampled, format)` read by the type map, and intrinsic declarations generated from it, is the minimum.
- **Avoid: plain-uniform and shared-sampler conventions as the core model.** `D7` serves OpenGL and is invalid Vulkan; make blocks (with an explicit `std140`/`std430`/scalar layout computed in D, as [TypeGPU][typegpu] does) the core model and let `spirv-cross --glsl-emit-ubo-as-plain-uniforms` recover GL-style uniforms.
- **Adopt: the agreement oracle as the CPU simulator's acceptance test.** `SHV7`/`D12` (host vs. GPU readback within the Vulkan precision table) is exactly the harness a scalar CPU simulator needs; extend it from pure math to sampling, derivatives (quad emulation) and subgroups ([ILGPU][ilgpu]'s CPU accelerator is the precedent).
- **Avoid: silent environment dependencies.** The fork runs `spirv-opt -O` in place when it happens to be on `PATH`, and once emitted SPIR-V 1.4 under a 1.6 triple; both were invisible. Every toolchain behaviour should be explicit and tested (`vulkan_spirv_version.d` is the model).
- **Match: SPIR-V capability floors per target.** The vocabulary must know what each output dialect can take (ES 1.00 has no bit operations; HLSL has no PSB): a per-target subset checker belongs in the compiler or the build step, not in reviewers' heads.

## Strengths

- Full D at compile time on the device: templates, CTFE, `static foreach`, UFCS, alias parameters — more metaprogramming than any shading language except Slang and Circle.
- One function genuinely runs on both sides, tested by GPU readback within a cited precision table.
- Interface contract enforced by the compiler with precise, D-level diagnostics; names survive translation by construction.
- Rides LLVM's in-tree SPIR-V backend, the same one Clang's HLSL uses, so upstream improvements flow in.
- Reproducible, pinned toolchain (Nix), atomic and provenance-stamped outputs, never-committed generated code.

## Weaknesses

- Fragment stage only, one implicit `vec4` output, no builtins; compute exists but with a CUDA-style BDA ABI that does not translate to HLSL.
- Resource model is OpenGL-shaped (plain uniforms, one shared sampler, `Sampler2D` only) and invalid for Vulkan consumption.
- No workgroup memory, no module-scope constants, no spec constants, no atomics, no subgroup or derivative vocabulary in D.
- Depends on an unmerged LDC PR, an unmerged third-party LLVM PR and six more local LLVM patches against LLVM main; no released compiler works.
- `libmir/dcompute` stalled at `v0.1.1` (2025-06-12) with no warp operations and no Vulkan support; dcompute's ecosystem is effectively this project.
- No CPU execution model for anything beyond pure math; no reflection output for hosts.

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                          | Trade-off                                                                                        |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Device code is a restricted D, chosen per module         | Reuse the D frontend whole; one UDA opts in; ban list is small and auditable       | No device-only types or qualifiers in the language; every GPU concept is a library struct or UDA |
| `Pointer!(AddrSpace, T)` instead of qualifiers           | No language change; per-target mapping table                                       | Address spaces are invisible to D's type system beyond the struct; easy to misuse on Vulkan      |
| `__dcompute_reflect` for per-target code                 | Codegen-time folding; one generic function serves many backends                    | Host path is `assert(0)`; no CPU semantics fall out                                              |
| Vulkan compute ABI = one SSBO of BDA pointers (#5132)    | Maps CUDA-style pointer kernels directly                                           | Needs PSB; cannot reach HLSL via `spirv-cross`; not how GLSL/HLSL compute binds buffers          |
| Fragment interface synthesised in the compiler (`D2`)    | Module-level SPIR-V declarations are out of a library's reach; D-level diagnostics | A compiler fork to maintain; every contract change is a toolchain rebuild (`D13`)                |
| Everything `alwaysinline`                                | Handles may not cross calls; recursion is rejected anyway                          | No real SPIR-V functions; code size scales with call count                                       |
| Plain uniforms + one shared sampler (`D7`)               | Exactly what OpenGL consumers bind by name                                         | Invalid Vulkan; no per-image sampler state                                                       |
| `StructurizeCFG` before the backend (`64104a9a`)         | Robust structured CFG for optimised D; the AMDGPU-proven path                      | Can introduce extra flow variables; still no convergence tokens for wave ops                     |
| GLSL via `spirv-cross`, not SPIR-V, for consumers (`D3`) | One translator, mature, validated by `glslang`                                     | Per-target ceilings of `spirv-cross`; no WGSL; regex post-processing for sampler names           |

---

## Sources

- [`ldc/dcompute.d` — upstream druntime: `@compute`, `@kernel`, `Pointer`, `AddrSpace`, `__dcompute_reflect`][ldc-dcompute-d]
- [`gen/semantic-dcompute.cpp` — upstream device rules][up-sema]
- [`gen/dcompute/targetOCL.cpp`][up-ocl] · [`gen/dcompute/targetCUDA.cpp`][up-cuda] · [`driver/cl_options.cpp` (`-fembed-dcompute`)][up-clopts]
- [ldc-developers/ldc#5132 — dcompute Vulkan target][pr5132]
- [Fork `gen/dcompute/targetVulkan.cpp` — kernel ABI, fragment stage, interface checks, recursion check][fork-target]
- [Fork `gen/dcompute/target.h`][fork-target-h] · [fork `gen/optimizer.cpp` (StructurizeCFG)][fork-opt] · [fork `gen/semantic-dcompute.cpp` (whitelist)][fork-sema] · [fork `gen/dcompute/druntime.cpp` (handle types)][fork-druntime-cpp] · [fork `ldc/dcompute.d` (`@fragment`, `Sampler2D`, `sample`)][fork-dcompute-d]
- [Fork tests: `vulkan_structured_control_flow.d`][fork-test-scf] · [`vulkan_global_pointer_index.d`][fork-test-gpi] · [`dcompute_vulkan_recursion.d`][fork-test-rec]
- [`libmir/dcompute` README][lib-readme] · [`std/index.d`][lib-index] · [`std/warp.d`][lib-warp] · [`driver/util.d`][lib-util]
- LLVM at `27ba4937`: [`SPIRVCallLowering.cpp`][llvm-calllow] · [`SPIRVUtils.cpp`][llvm-utils] · [`SPIRVModuleAnalysis.cpp`][llvm-modan] · [`IntrinsicsSPIRV.td`][llvm-intr]
- sparkles: [`SPEC.md`][spec] · [`decisions.md`][decisions] · [`PLAN.md`][plan] · [`testing.md`][testing] · [`libs/shaders`][types] ([`attributes.d`][attributes], [`math.d`][math], [`compute_mode.d`][compute-mode], [`testing.d`][testing-d]) · [`apps/shader-compile/src/app.d`][app] · [`libs/ui/shaders/effects.d`][effects] · [`#647` upstreaming tracker][issue647]
- The local LLVM patches (`sparkles/spirv-shader-ints`) and dlang.nix `d4063afb` are not on a public pinned blob; they are cited by commit subject only.
- Related: [Concepts][concepts] · [Comparison][comparison] · [Index][index] · [rust-gpu][rust-gpu] · [Slang][slang] · [ILGPU][ilgpu] · [TypeGPU][typegpu] · [ComputeSharp][computesharp]

<!-- References -->

[ldc-dcompute-d]: https://github.com/ldc-developers/ldc/blob/ac0e420af3fe74de50ff2138f9ffcb464c29873a/runtime/druntime/src/ldc/dcompute.d
[up-sema]: https://github.com/ldc-developers/ldc/blob/ac0e420af3fe74de50ff2138f9ffcb464c29873a/gen/semantic-dcompute.cpp
[up-ocl]: https://github.com/ldc-developers/ldc/blob/ac0e420af3fe74de50ff2138f9ffcb464c29873a/gen/dcompute/targetOCL.cpp
[up-cuda]: https://github.com/ldc-developers/ldc/blob/ac0e420af3fe74de50ff2138f9ffcb464c29873a/gen/dcompute/targetCUDA.cpp
[up-clopts]: https://github.com/ldc-developers/ldc/blob/ac0e420af3fe74de50ff2138f9ffcb464c29873a/driver/cl_options.cpp
[pr5132]: https://github.com/ldc-developers/ldc/pull/5132
[fork-target]: https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/gen/dcompute/targetVulkan.cpp
[fork-target-h]: https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/gen/dcompute/target.h
[fork-opt]: https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/gen/optimizer.cpp
[fork-sema]: https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/gen/semantic-dcompute.cpp
[fork-druntime-cpp]: https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/gen/dcompute/druntime.cpp
[fork-dcompute-d]: https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/runtime/druntime/src/ldc/dcompute.d
[fork-test-scf]: https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/tests/codegen/vulkan_structured_control_flow.d
[fork-test-gpi]: https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/tests/codegen/vulkan_global_pointer_index.d
[fork-test-rec]: https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/tests/fail_compilation/dcompute_vulkan_recursion.d
[lib-readme]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/README.md
[lib-index]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/std/index.d
[lib-warp]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/std/warp.d
[lib-util]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/util.d
[llvm-calllow]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVCallLowering.cpp
[llvm-utils]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVUtils.cpp
[llvm-modan]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVModuleAnalysis.cpp
[llvm-intr]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/include/llvm/IR/IntrinsicsSPIRV.td
[issue647]: https://github.com/PetarKirov/sparkles/issues/647
[spec]: ../../specs/shaders/SPEC.md
[decisions]: ../../specs/shaders/decisions.md
[plan]: ../../specs/shaders/PLAN.md
[testing]: ../../specs/shaders/testing.md
[types]: ../../../libs/shaders/src/sparkles/shaders/types.d
[attributes]: ../../../libs/shaders/src/sparkles/shaders/attributes.d
[math]: ../../../libs/shaders/src/sparkles/shaders/math.d
[compute-mode]: ../../../libs/shaders/src/sparkles/shaders/compute_mode.d
[testing-d]: ../../../libs/shaders/src/sparkles/shaders/testing.d
[app]: ../../../apps/shader-compile/src/app.d
[effects]: ../../../libs/ui/shaders/effects.d
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[glsl]: ./glsl.md
[hlsl]: ./hlsl.md
[slang]: ./slang.md
[rust-gpu]: ./rust-gpu.md
[cuda]: ./cuda-hip.md
[ispc]: ./ispc.md
[ilgpu]: ./ilgpu.md
[typegpu]: ./typegpu.md
[computesharp]: ./computesharp.md
[tint]: ./tint.md
[naga]: ./naga.md
[spirv-cross]: ./spirv-cross.md
[llvm-spirv]: ./llvm-spirv-backend.md
[clang-hlsl]: ./clang-hlsl.md
[dxc]: ./dxc.md
