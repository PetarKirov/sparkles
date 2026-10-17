# Clang HLSL (LLVM)

HLSL as a language mode of upstream Clang, lowering one front end to both of LLVM's GPU graphics backends — DirectX (DXIL) and SPIR-V — through a shared, documented IR contract that any other LLVM front end, including LDC, can emit.

| Field          | Value                                                                                                                                                                                          |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | C++ (the compiler); HLSL 202x as the accepted source language                                                                                                                                  |
| License        | Apache-2.0 WITH LLVM-exception                                                                                                                                                                 |
| Repository     | [llvm/llvm-project][repo], surveyed at upstream `27ba493781215910f560b36cd5b3b2f6c93ec5a3` (2026-09-19, `LLVM_VERSION_MAJOR 24`)                                                               |
| Documentation  | [`clang/docs/HLSL/`][docs-dir]: [`HLSLSupport.md`][support], [`EntryFunctions.md`][entry-doc], [`ResourceTypes.md`][res-doc], [`HLSLIRReference.md`][irref], [`ExpectedDifferences.md`][diffs] |
| Category       | Toolchain: front end + two backends (`llvm/lib/Target/DirectX`, `llvm/lib/Target/SPIRV`)                                                                                                       |
| Latest version | No release carries it complete; LLVM main (24.0.0git) at the pin. Both `DirectX` and `SPIRV` are in `LLVM_ALL_TARGETS` ([`llvm/CMakeLists.txt`][cmake])                                        |
| Targets        | `dxil-pc-shadermodel6.x-<stage>` → DXIL in a DXContainer; `spirv1.x-unknown-vulkan1.x-<stage>` → logical SPIR-V                                                                                |
| Stages (E2E)   | SPIR-V: compute, vertex, pixel only. DXIL: entry metadata for ps/vs/gs/hs/ds/cs/ms/as/lib; system values only for cs/vs/ps                                                                     |
| Relation       | Intended successor to [DXC][dxc]; feeds the same SPIR-V backend as the sparkles LDC fork ([`llvm-spirv-backend.md`][llvm-spirv])                                                               |

> [!NOTE]
> Every path below is cited at the upstream commit `27ba493781`. The local clone at
> `$REPOS/llvm-project` carries three sparkles patches on top (see
> [`llvm-spirv-backend.md`][llvm-spirv]); nothing here depends on them. Line anchors
> were re-verified against `27ba493781`.

---

## Overview

### What it solves

HLSL has had two reference compilers, FXC (DXBC) and [DXC][dxc] (DXIL and SPIR-V), and DXC is a fork of LLVM 3.7 whose SPIR-V path is a separate code generator beside its DXIL one. The Clang effort moves HLSL into upstream LLVM so that **one AST, one CodeGen and modern LLVM optimisation** serve DirectX and Vulkan alike. The language becomes "C++ minus unsupported features" rather than an additive dialect, and the backends live in LLVM proper, where other front ends can reach them.

For sparkles the important consequence is the second half: Clang HLSL defines, in ordinary LLVM IR, **what a graphics shader looks like to the DirectX and SPIR-V backends** — the resource handle types, the entry-point function attributes, the interface-variable shapes and the intrinsics. The LDC fork already emits a subset of that contract (`hlsl.shader`, `hlsl.numthreads`, `!spirv.Decorations`); Clang is the reference for the rest.

### Design philosophy

From [`clang/docs/HLSL/HLSLSupport.md`][support]:

> _"The long term goal of this project is to enable Clang to function as a replacement for the DirectXShaderCompiler (DXC) in all its supported use cases."_

and, on CodeGen:

> _"As a design principle here we want our IR to be idiomatic Clang IR as much as possible. We will use IR attributes wherever we can, and use metadata as sparingly as possible. … Our HLSL CodeGen implementation should also have an eye toward generating IR that will map directly to targets other than DXIL."_

Two further commitments shape everything below. Clang implements the draft specification, not DXC's behaviour: [`ExpectedDifferences.md`][diffs] says HLSL in Clang _"is instead being written to match the draft language specification"_ while DXC stays _"the reference implementation"_ for modern HLSL ([`HLSLSupport.md`][support]). And built-in types that HLSL cannot express are synthesised by Sema rather than written in a header ([`ResourceTypes.md`][res-doc]: _"these types are forward declared by the `HLSLExternalSemaSource` on initialization. They are then lazily completed"_).

---

## How it works

### Layers

| Layer                | Files (all at `27ba493781`)                                                                                                                                                   | Role                                                                                                     |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Parser               | [`ParseHLSL.cpp`][parse], [`ParseHLSLRootSignature.cpp`][parse-rs]                                                                                                            | semantics (`: SV_Target`), `register(...)`, `packoffset`, root-signature grammar                         |
| Sema                 | [`SemaHLSL.cpp`][sema] (6,688 lines), [`SemaSPIRV.cpp`][sema-spirv]                                                                                                           | entry-point checks, stage/attribute compatibility, address spaces, bindings, intrinsic type rules        |
| Built-in types       | [`HLSLExternalSemaSource.cpp`][ext-sema], [`HLSLBuiltinTypeDeclBuilder.cpp`][decl-builder]                                                                                    | `RWBuffer`, `StructuredBuffer`, `Texture2D`, `SamplerState`, … built as classes around a handle          |
| Library headers      | [`hlsl.h`][hlsl-h], [`hlsl_intrinsics.h`][hlsl-intr-h], [`hlsl_intrinsic_helpers.h`][hlsl-helpers], [`hlsl_spirv.h`][hlsl-spirv]                                              | free functions, many expanded inline to generic IR; `vk::SpirvType`                                      |
| Intrinsic table      | [`HLSLIntrinsics.td`][intr-td], [`Builtins.td`][builtins-td] (94 `__builtin_hlsl_*`)                                                                                          | HLSL name → Clang builtin or `__builtin_elementwise_*`                                                   |
| CodeGen              | [`CGHLSLRuntime.cpp`][cgr] (2,455 lines), [`CGHLSLBuiltins.cpp`][cgb], [`HLSLBufferLayoutBuilder.cpp`][layout]                                                                | entry wrappers, semantics, resource globals, cbuffer layout, builtin → intrinsic                         |
| Target hooks         | [`Targets/DirectX.cpp`][tgt-dx], [`Targets/SPIR.cpp`][tgt-spir]                                                                                                               | handle type per backend (`target("dx.*")` vs `target("spirv.*")`)                                        |
| Shared LLVM frontend | [`llvm/lib/Frontend/HLSL/`][fe-hlsl]: `CBuffer.cpp`, `HLSLBinding.cpp`, `HLSLResource.cpp`, `HLSLRootSignature.cpp`, `SemanticSignatures.cpp`, `SemanticSignaturePacking.cpp` | binding-range analysis, cbuffer offsets, root signatures, signature elements — reusable by any front end |
| Backends             | [`llvm/lib/Target/DirectX`][dx-dir], [`llvm/lib/Target/SPIRV`][spv-dir]                                                                                                       | DXIL bitcode + DXContainer; SPIR-V binary                                                                |

### Twinned intrinsic vocabularies

The central trick is that Clang emits the **same IR shape** for both backends and swaps only the intrinsic prefix and the handle type. [`CGHLSLRuntime.h`][cgr-h-macro] defines 76 generators with one macro:

```cpp
// clang/lib/CodeGen/CGHLSLRuntime.h
#define GENERATE_HLSL_INTRINSIC_FUNCTION(FunctionName, IntrinsicPostfix)       \
  llvm::Intrinsic::ID get##FunctionName##Intrinsic() {                         \
    llvm::Triple::ArchType Arch = getArch();                                   \
    switch (Arch) {                                                            \
    case llvm::Triple::dxil:                                                   \
      return llvm::Intrinsic::dx_##IntrinsicPostfix;                           \
    case llvm::Triple::spirv:                                                  \
      return llvm::Intrinsic::spv_##IntrinsicPostfix;                          \
```

So `WaveActiveSum` is `llvm.dx.wave.reduce.sum` or `llvm.spv.wave.reduce.sum`, `SV_DispatchThreadID` is `llvm.dx.thread.id` or `llvm.spv.thread.id`, and resource creation is `llvm.dx.resource.handlefrombinding` or `llvm.spv.resource.handlefrombinding` — both taking `(i32 space, i32 lowerBound/binding, i32 range, i32 index, ptr name)` ([`IntrinsicsDirectX.td`][intr-dx], 112 `int_dx_*`; [`IntrinsicsSPIRV.td`][intr-spv], 161 `int_spv_*`). Only `arch == spirv` (logical) is wired; `spirv32`/`spirv64` (OpenCL-style) take the `llvm_unreachable` branch.

### Entry-point synthesis

[`EntryFunctions.md`][entry-doc] states the model and [`CGHLSLRuntime::emitEntryFunction`][cgr-entry] implements it: the user function stays a mangled internal function, and Clang adds an unmangled `void()` wrapper that (1) opens with `llvm.experimental.convergence.entry`, (2) materialises each parameter from its semantic, (3) calls the user function with a `convergencectrl` bundle, (4) stores the result through output semantics. [`setHLSLEntryAttributes`][cgr-attrs] tags the wrapper:

```llvm
define void @main() #0 { … }
attributes #0 = { noinline "hlsl.shader"="compute" "hlsl.numthreads"="8,8,1"
                  "hlsl.wavesize"="32,64,32" ; DXIL only; Sema warns on SPIR-V
                  "enable-maximal-reconvergence"="true" } ; -fspv-enable-maximal-reconvergence
```

Semantics then diverge by target:

| Semantic                                                                 | DXIL                                                                                                                                | SPIR-V                                                                                                                                               |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| user (`TEXCOORD0`), `SV_Target`                                          | `llvm.dx.load.input(sigId, row, col, gsIdx)` / `llvm.dx.store.output(...)` per row, plus a `SemanticSignatureElement` for ISG1/OSG1 | `external hidden thread_local` global per leaf, AS 7 in / AS 8 out, with a `!spirv.Decorations` `Location` (30) node; locations in declaration order |
| `SV_Position` in pixel                                                   | user-semantic path                                                                                                                  | AS-7 global, `BuiltIn FragCoord` (15)                                                                                                                |
| `SV_VertexID` / `SV_Position` out (vertex)                               | user-semantic path                                                                                                                  | `BuiltIn VertexIndex` (42) / `BuiltIn Position` (0)                                                                                                  |
| `SV_DispatchThreadID`, `SV_GroupID`, `SV_GroupThreadID`, `SV_GroupIndex` | `llvm.dx.thread.id` etc.                                                                                                            | `llvm.spv.thread.id.i32` etc.                                                                                                                        |
| everything else                                                          | `llvm_unreachable("Load hasn't been implemented yet for this system semantic. FIXME")`                                              | same                                                                                                                                                 |

`inout`/`out` entry parameters hit `llvm_unreachable("Not handled yet")` ([`CGHLSLRuntime.cpp`][cgr-inout]).

### Resources as intangible handles

A resource class is a record holding a `__hlsl_resource_t` member annotated with `hlsl::resource_class(SRV|UAV|CBuffer|Sampler)`, `hlsl::contained_type(T)`, `hlsl::dimension(...)`, `hlsl::is_array`, `hlsl::raw_buffer`, `hlsl::is_ms`, `hlsl::is_rov`, `hlsl::is_counter` ([`ResourceTypes.md`][res-doc]). CodeGen maps the attributed handle type per target:

| HLSL                                     | DXIL handle ([`Targets/DirectX.cpp`][tgt-dx]) | SPIR-V handle ([`Targets/SPIR.cpp`][tgt-spir-hlsl])                                |
| ---------------------------------------- | --------------------------------------------- | ---------------------------------------------------------------------------------- |
| `Texture2D`, `RWTexture2D`               | `target("dx.Texture", …)`                     | `target("spirv.Image", T, dim, 2, arrayed, ms, sampled, fmt)`                      |
| `Texture2DMS`                            | `target("dx.MSTexture", …)`                   | `spirv.Image` with `MS=1`                                                          |
| `Buffer`, `RWBuffer`                     | `target("dx.TypedBuffer", …)`                 | `spirv.Image` with `Dim=5` (texel buffer); `spirv.SignedImage` for signed elements |
| `StructuredBuffer`, `ByteAddressBuffer`  | `target("dx.RawBuffer", …)`                   | `target("spirv.VulkanBuffer", [0 x T], 12, writable)`                              |
| `cbuffer`, `ConstantBuffer`              | `target("dx.CBuffer", layout)`                | `target("spirv.VulkanBuffer", layout, 2, 0)`                                       |
| `SamplerState`                           | `target("dx.Sampler", …)`                     | `target("spirv.Sampler")`                                                          |
| cbuffer padding                          | `target("dx.Padding", N)`                     | `target("spirv.Padding", N)`                                                       |
| `vk::SpirvType<Op, Size, Align, Ops...>` | —                                             | `target("spirv.Type", operands…, opcode, size, align)`                             |

Rasterizer-ordered views assert _"Rasterizer order views not implemented for SPIR-V yet"_ ([`Targets/SPIR.cpp`][tgt-spir-hlsl]). Element access is `llvm.{dx,spv}.resource.getpointer(handle, i32 idx)` followed by plain `load`/`store`/`atomicrmw`; each backend then rewrites those pointer accesses (DirectX: `DXILResourceAccess` into `dx.resource.load.typedbuffer`/`load.rawbuffer`; SPIR-V: instruction selection into `OpImageRead`/`OpImageWrite` or an `OpAccessChain` into the buffer block).

---

## Execution model and stages

Sema knows every stage: [`SemaHLSL::CheckEntryPoint`][sema-entry] switches over pixel, vertex, geometry, hull, domain, the six ray-tracing stages, compute, amplification and mesh, requiring `[numthreads]` for compute/amplification/mesh and diagnosing `[WaveSize]` as unsupported on SPIR-V. The SPIR-V target accepts any environment from `Pixel` to `Amplification` ([`Targets/SPIR.h`][spir-h-stage]).

The backends are far narrower than Sema:

| Stage                  | Sema | CodeGen system values            | DirectX backend                                                              | SPIR-V backend                                                                                                        |
| ---------------------- | ---- | -------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| compute                | yes  | 4 compute IDs                    | yes                                                                          | `GLCompute`                                                                                                           |
| vertex                 | yes  | `SV_VertexID`, `SV_Position` out | yes                                                                          | `Vertex`                                                                                                              |
| pixel                  | yes  | `SV_Position` in, `SV_Target`    | yes                                                                          | `Fragment` (+ `OriginUpperLeft`)                                                                                      |
| geometry, hull, domain | yes  | asserts "FIXME"                  | `gs`/`hs`/`ds` entry metadata ([`DXILTranslateMetadata.cpp`][dx-meta-stage]) | `report_fatal_error("This HLSL entry point is not supported by this backend.")` ([`SPIRVCallLowering.cpp`][spv-exec]) |
| mesh, amplification    | yes  | asserts "FIXME"                  | `ms`/`as` entry metadata                                                     | fatal error                                                                                                           |
| ray tracing, node      | yes  | none                             | only via `lib`                                                               | fatal error                                                                                                           |

So the **usable end-to-end set is compute, vertex and pixel on both backends**, and pixel/vertex are limited further by the four implemented system values. The DXIL op table encodes per-op stage legality (`Stages<DXIL1_0, [pixel]>` for `discard`, `[compute, mesh, amplification, node]` for thread IDs, [`DXIL.td`][dxil-td]), so the DirectX backend can diagnose a wrong-stage op; the SPIR-V backend has no equivalent table.

Shader models: the triple parser maps `shadermodel6.0`–`6.9` to DXIL 1.0–1.9 ([`Triple.cpp`][triple-sm]), but `DXIL.td` declares versions only up to `DXIL1_8`, so no SM 6.9 operation (long vectors, SER) has an op record at the pin.

## Type system and generic programming

The type system is Clang's C++ type system with HLSL restrictions: templates, operator overloading, namespaces and bit-fields come free from C++, which is why the effort describes HLSL as _"C++ minus unsupported C and C++ features"_ ([`HLSLSupport.md`][support]). HLSL vectors are Clang `ext_vector_type`; matrices are `ConstantMatrixType`, lowered to flat `<R*C x T>` values with `[[hlsl::row_major]]`/`column_major` choosing the in-memory array-of-vectors layout. `mul` becomes `llvm.matrix.multiply` and `transpose` `llvm.matrix.transpose`; on SPIR-V the pre-legalizer combiner expands both into per-element dot products ([`SPIRVCombine.td`][spv-combine]) — no `OpTypeMatrix` is produced. 16-bit types follow `-enable-16bit-types` (test `enable-16bit-types.hlsl`).

What a D front end gains here is nothing to copy: D's templates, CTFE and `static if` already exceed HLSL 2021 templates. The useful lesson is negative — Clang emits **no generic-type metadata** to the backends; all genericity is resolved in the front end, exactly as an LDC instantiation would be.

## Resources, interfaces and memory layout

**Address spaces.** Sema assigns, and the SPIR-V target maps 1:1 to storage classes: default `0` → `Function`, `hlsl_groupshared` `3` → `Workgroup`, `hlsl_input` `7` → `Input`, `hlsl_output` `8` → `Output`, `hlsl_private` `10` → `Private`, `hlsl_device` `11` → `StorageBuffer`, `hlsl_constant` `12` → `Uniform`, `hlsl_push_constant` `13` → `PushConstant` ([`Targets/SPIR.h`][spir-h]). Non-static non-resource globals collect into the implicit `$Globals` cbuffer.

**Bindings.** `register(t0, space1)` gives `(space, slot)`; on SPIR-V `[[vk::binding(b, s)]]` overrides it ([`HLSLResource.h`][hlsl-resource-h]). Unbound resources use the `handlefromimplicitbinding` form with an order ID, and the backend allocates (`DXILResourceImplicitBinding` on DirectX, `SPIRVLegalizeResourceBinding` on SPIR-V) using [`HLSLBinding.h`][binding-h]'s `BindingInfo`, which _"can be used for analysis of overlapping or missing bindings as well as for finding space for implicit bindings."_ The handle is created once in a global constructor that Clang inlines into each entry.

**cbuffers.** Every member becomes its own `addrspace(12)` global tied to the buffer by `!hlsl.cbs`; [`HLSLBufferLayoutBuilder.cpp`][layout] builds a packed struct with explicit padding elements under **D3D legacy cbuffer rules** (16-byte rows, no straddling), and `SPIRVCBufferAccess` / `DXILCBufferAccess` rewrite member accesses using offsets from [`Frontend/HLSL/CBuffer.cpp`][fe-cbuffer]. That is the only layout implemented: `-fvk-use-dx-layout` is a no-op and `-fvk-use-gl-layout` / `-fvk-use-scalar-layout` are rejected as unsupported ([`ToolChains/HLSL.cpp`][drv-layout]).

**Vulkan attributes.** Only six `vk::` attributes exist: `binding`, `ext_builtin_input`, `ext_builtin_output`, `push_constant`, `constant_id`, `location` ([`Attr.td`][attr-td]). `vk::constant_id` lowers to a call to the Itanium-mangled `__spirv_SpecConstant(int, T)` which the backend turns into `OpSpecConstant`. DXC's `vk::ext_instruction`, `ext_decorate`, `ext_capability` and `ext_execution_mode` are absent; the only inline-SPIR-V hooks are `vk::SpirvType`/`SpirvOpaqueType` ([`hlsl_spirv.h`][hlsl-spirv]).

**Not present at the pin:** `ResourceDescriptorHeap` (no hit in `clang/lib` or `clang/include`, although the DirectX backend already lowers `llvm.dx.resource.handlefromheap`), `vk::BufferPointer`, `tbuffer`, ROVs on SPIR-V, push-constant matrix members.

## Built-in library and intrinsics

Intrinsics lower in three tiers ([`HLSLIntrinsics.td`][intr-td], [`CGHLSLBuiltins.cpp`][cgb], [`hlsl_intrinsic_helpers.h`][hlsl-helpers]):

1. **Generic LLVM** where an elementwise intrinsic exists — `sin`, `exp2`, `fma`, `sqrt`, `bitreverse`, `ctpop`, `llvm.fmuladd` for `mad`, `__builtin_bit_cast` for `asuint`.
2. **Twinned `dx.*`/`spv.*`** for shader-only operations — `frac`, `rsqrt`, `saturate`, `sign`, `dot` (`fdot`/`sdot`/`udot`), `dot4add_*8packed`, `firstbit*`, `clamp`, `length`, `reflect`, `refract`, `smoothstep`, derivatives (`ddx`/`ddy` coarse and fine, `fwidth`), all `Wave*` reductions/prefixes/ballot/readlane, `QuadReadAcross*`, the six memory barriers, `discard`.
3. **Header expansion to generic IR**, re-matched by the backend — `normalize` as `x / length(x)`, `distance`, `faceforward`, `lerp`, `cross`, `degrees`; the SPIR-V combiner folds them back into `GLSL.std.450` `Normalize`, `Distance`, `FaceForward` ([`SPIRVCombine.td`][spv-combine]).

Sampling is resource-method-shaped: `sample`, `samplebias`, `samplegrad`, `samplelevel`, `samplecmp`, `samplecmplevelzero`, `gather`, `gather_cmp`, `load_level`, `load_ms`, `calculate_lod`, `getdimensions_*`, all taking image and sampler handles separately with an explicit offset operand ([`IntrinsicsSPIRV.td`][intr-spv]). Clang never forms a combined `spirv.SampledImage`; the backend builds `OpSampledImage`. Atomics are plain `atomicrmw` with `syncscope("workgroup")` for groupshared and `syncscope("device")` otherwise.

## Control flow, memory model and restrictions

**Convergence tokens are mandatory.** [`CodeGenModule.h`][cgm-conv] gates emission on `getTriple().isSPIRVLogical() || getTriple().isDXIL()`, and HLSL turns on `-fconvergent-functions`. Every function begins with `llvm.experimental.convergence.entry`, every loop header has `llvm.experimental.convergence.loop`, and every convergent call — user functions, wave ops, implicit-LOD sampling, barriers — carries a `convergencectrl` bundle. The DirectX backend strips them first ([`DirectXTargetMachine.cpp`][dx-tm]); the SPIR-V backend uses them in `SPIRVConvergenceRegionAnalysis` to decide which blocks belong to a loop's convergence region before structurizing, then strips them ([`SPIRVTargetMachine.cpp`][spv-tm]).

**Structured control flow is the backend's job.** Front ends emit unstructured LLVM CFG; on SPIR-V the pipeline runs `LoopSimplify` → `RegToMem` → `SPIRVMergeRegionExitTargets` → `SPIRVStructurizer` → `mem2reg` and the structurizer itself emits `llvm.spv.loop.merge`/`selection.merge`. Hints travel as standard metadata: `[unroll(n)]`/`[loop]` as `llvm.loop.unroll.*`, `[branch]`/`[flatten]` as `!hlsl.controlflow.hint` (1 = DontFlatten, 2 = Flatten).

**Restrictions.** HLSL forbids recursion, function pointers, exceptions and dynamic allocation; Clang marks functions `norecurse` (test `implicit-norecurse-attrib.hlsl`) and rejects the rest in Sema — the complete list of checks was not verified against the pin. The memory model is HLSL's informal one; Clang emits `monotonic` atomics and leaves scope selection to the two `syncscope` strings above.

## Compilation pipeline and targets

Driver: `clang --driver-mode=dxc` (`clang-dxc`) accepts DXC flags (`-T cs_6_6`, `-E`, `-spirv`, `-fvk-*`) and builds an `HLSLToolchain` ([`HLSLSupport.md`][support]). The triple carries the shader model and stage, e.g. `dxil-pc-shadermodel6.6-compute`, `spirv1.6-unknown-vulkan1.3-compute`.

DirectX backend pipeline ([`DirectXTargetMachine.cpp`][dx-tm]):

```text
StripConvergenceIntrinsics → DXILFinalizeLinkage → DXILMemIntrinsics
→ DXILCBufferAccess → DXILRemoveUnusedResources → DXILResourceAccess
→ DXILIntrinsicExpansion → DXILDataScalarization → Scalarizer
→ DXILFlattenArrays → DXILForwardHandleAccesses → DXILLegalize
→ DXILResourceImplicitBinding → DXILTranslateMetadata
→ DXILPostOptimizationValidation → DXILOpLowering → DXILPrepare
→ DXILWriter (LLVM 3.7-compatible bitcode) → DXContainerGlobals
```

`DXILOpLowering` turns each `llvm.dx.*` intrinsic into a `dx.op` call through the 126 `DXILOp` records of [`DXIL.td`][dxil-td]; `DXILPrepare` _"convert[s] a modern LLVM module into a module compatible with the LLVM 3.7-based DirectX Intermediate Language"_ ([`DXILPrepare.cpp`][dx-prepare]); `DXContainerGlobals` adds `SFI0` feature flags, `HASH` (an MD5 of the DXIL part), `ISG1`/`OSG1` signatures, `PSV0` and `RTS0` root signatures ([`DXContainerGlobals.cpp`][dx-container]). Validator-version metadata gates some flags, but signing by Microsoft's validator is outside LLVM (not verified against a pinned source what a D3D12 runtime accepts unsigned).

SPIR-V backend pipeline ([`SPIRVTargetMachine.cpp`][spv-tm]): shader-specific IR passes (structurizer as above, `StripConvergenceIntrinsics`, `SPIRVLegalizeResourceBinding`, `SPIRVCBufferAccess`, `SPIRVPushConstantAccess`, `SPIRVEmitIntrinsics`), then GlobalISel. [`llvm-spirv-backend.md`][llvm-spirv] covers it in depth.

## Host integration and CPU execution

None. Clang HLSL produces device binaries only; there is no host-side reflection API (unlike DXC's `IDxcContainerReflection` or Slang's), no CPU target and no single-source host/device model. Reflection data exists only as the DXContainer `PSV0`/signature parts on DirectX. The `llvm/lib/Frontend/HLSL` libraries (bindings, root signatures, cbuffer layout) are C++ libraries a host tool could link, but nothing in tree does so.

---

## Lessons for sparkles:shaders

- **Adopt the Clang IR contract verbatim as the LDC fork's device ABI.** Entry wrapper with `hlsl.shader`/`hlsl.numthreads`, interface globals in AS 7/8 with one `!spirv.Decorations` node, resources as `target("spirv.Image" | "spirv.VulkanBuffer" | "spirv.Sampler")` created by `llvm.spv.resource.handlefrombinding`, access via `getpointer`. The fork already emits the first three ([`targetVulkan.cpp`][ldc-fork]); every remaining SHF requirement in [SPEC § 6][spec-frag] maps onto a shape Clang has tests for. Divergence means owning backend bugs alone.
- **Emit convergence tokens.** The fork emits none today (no `convergence` hit in [`targetVulkan.cpp`][ldc-fork]), so the structurizer runs on the "region = loop blocks only" fallback that Clang never exercises. Entry/loop tokens plus `convergencectrl` bundles on calls are a mechanical LDC codegen change and the cheapest structurizer-risk reduction available.
- **Keep the front end target-neutral and switch only prefix and handle type.** Mirror `GENERATE_HLSL_INTRINSIC_FUNCTION`: one D intrinsic declaration table keyed by `dx_`/`spv_` suffix. Then the DXIL path in the plan is a triple change plus a `dx.*` handle mapping, using a backend already built in the same LLVM (`DirectX` is a default target).
- **Give every Clang address space a D spelling.** The fork's Vulkan table is now `{0, 1, 3, 2, 4}`, so dcompute `Shared` lands in AS 3 like `hlsl_groupshared` ([`targetVulkan.cpp`][ldc-fork]). Input 7, Output 8, Private 10, StorageBuffer 11, Uniform 12 and PushConstant 13 have no dcompute qualifier; add them as new pointer kinds rather than overloading `Constant` (AS 2, `UniformConstant`, legal in Vulkan only for opaque handles) or `Generic` (AS 4, illegal in Vulkan), with one codegen test per space.
- **Layout is the front end's to choose; prove it in D.** The backends derive `Offset` from a packed struct with `spirv.Padding`. Clang only does D3D cbuffer layout; D can compute std140/std430/scalar by CTFE, emit explicit padding, and `static assert` the host struct identical — a strength Clang lacks.
- **Match the stage reality, not the Sema list.** Plan vertex and compute next (backend-ready); treat geometry, tessellation, mesh and ray tracing as LLVM-backend work shared with Clang, and contribute it upstream rather than in the fork.
- **Avoid features Clang cannot lower yet as first targets:** `inout` entry parameters, `SV_IsFrontFace`/`SV_Depth`/`SV_InstanceID`, GL layouts, ROVs. Each is an unimplemented path a D front end would be first to walk.
- **Test strategy:** reuse Clang's `clang/test/CodeGenHLSL/` RUN-line shapes as golden IR for the fork's FileCheck tests, and `spirv-val` every output; a passing Clang test is evidence the backend accepts that IR.

## Strengths

- One front end, one CodeGen, two backends; the twinned `dx.*`/`spv.*` intrinsics make target choice a triple.
- Upstream LLVM, modern optimiser, Apache-2.0, both backends enabled by default.
- The IR contract is documented ([`HLSLIRReference.md`][irref]) and pinned by the 455 test files under `clang/test/CodeGenHLSL/`.
- Reusable LLVM-side libraries (`llvm/lib/Frontend/HLSL`) for bindings, cbuffer offsets, signatures and root signatures.
- Convergence semantics expressed with LLVM's own convergence-control tokens rather than ad-hoc metadata.
- Better diagnostics and spec conformance than DXC by design ([`ExpectedDifferences.md`][diffs]).

## Weaknesses

- End-to-end stages limited to compute, vertex, pixel; SPIR-V backend fatal-errors on all others.
- Only four system values per direction implemented; `inout`/`out` entry parameters unreachable.
- SPIR-V layout restricted to D3D cbuffer rules; no GL/scalar layout.
- No `ResourceDescriptorHeap`, ray tracing, mesh, work graphs, SER, long vectors or linalg codegen at the pin; DXIL op records stop at DXIL 1.8.
- No matrix types in SPIR-V output; no `RowMajor`/`MatrixStride` decorations.
- No host integration, no CPU execution, no reflection API.
- Not shipped in any LLVM release in usable form; consumers pin main.

## Key design decisions and trade-offs

| Decision                                                                   | Rationale                                                                      | Trade-off                                                                   |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | --------------------------------------------------------------------------- |
| HLSL as "C++ minus features" inside Clang                                  | Reuse C++ templates, overloading, Sema; minimal divergence from Clang paths    | DXC-specific quirks and source compatibility must be re-earned case by case |
| Resource types synthesised by `HLSLExternalSemaSource`                     | Types need constructors and attributes HLSL source cannot express; lazy = fast | Resource semantics live in C++ code, not a readable header                  |
| Target extension types for handles (`target("dx.*")`, `target("spirv.*")`) | Opaque, typed, survive optimisation; no pointer games                          | Each new resource kind needs front-end and backend type-mapping work        |
| Twinned `dx.*`/`spv.*` intrinsics with matching signatures                 | One CodeGen path; a macro selects the target                                   | Intrinsic sets must be kept in lock-step across two backends                |
| Unmangled `void()` entry wrapper around a mangled user function            | Entry ABI independent of user signature; user function stays callable          | Semantics, `inout` and struct flattening all concentrated in the wrapper    |
| Convergence-control tokens for DXIL and logical SPIR-V                     | Correct wave-op placement under structurization                                | Every front end must emit tokens everywhere or lose those guarantees        |
| Structurization in the SPIR-V backend, not the front end                   | Front ends stay CFG-agnostic                                                   | Backend structurizer is a single, complex point of failure                  |
| D3D cbuffer layout only                                                    | DXC parity first                                                               | Vulkan-native std140/std430/scalar users must lay out by hand or wait       |
| DXIL emitted via `DXILPrepare` + a 3.7-compatible bitcode writer           | Driver stacks consume LLVM 3.7 bitcode                                         | A permanent downgrade layer between modern LLVM and DXIL                    |

---

## Sources

- [`clang/docs/HLSL/HLSLSupport.md` — goals, architecture][support]
- [`clang/docs/HLSL/EntryFunctions.md` — entry wrapper model][entry-doc]
- [`clang/docs/HLSL/ResourceTypes.md` — intangible handle attributes][res-doc]
- [`clang/docs/HLSL/HLSLIRReference.md` — IR attributes and metadata][irref]
- [`clang/docs/HLSL/ExpectedDifferences.md` — divergence from DXC/FXC][diffs]
- [`clang/lib/Sema/SemaHLSL.cpp`][sema] · [`HLSLExternalSemaSource.cpp`][ext-sema] · [`HLSLBuiltinTypeDeclBuilder.cpp`][decl-builder]
- [`clang/lib/CodeGen/CGHLSLRuntime.cpp`][cgr] · [`CGHLSLRuntime.h`][cgr-h] · [`CGHLSLBuiltins.cpp`][cgb] · [`HLSLBufferLayoutBuilder.cpp`][layout]
- [`clang/lib/CodeGen/Targets/SPIR.cpp`][tgt-spir] · [`Targets/DirectX.cpp`][tgt-dx] · [`clang/lib/Basic/Targets/SPIR.h`][spir-h]
- [`clang/include/clang/Basic/HLSLIntrinsics.td`][intr-td] · [`Attr.td`][attr-td] · [`clang/lib/Headers/hlsl/hlsl_spirv.h`][hlsl-spirv]
- [`llvm/include/llvm/IR/IntrinsicsSPIRV.td`][intr-spv] · [`IntrinsicsDirectX.td`][intr-dx]
- [`llvm/lib/Frontend/HLSL/`][fe-hlsl] · [`llvm/include/llvm/Frontend/HLSL/HLSLBinding.h`][binding-h]
- [`llvm/lib/Target/DirectX/DirectXTargetMachine.cpp`][dx-tm] · [`DXIL.td`][dxil-td] · [`DXILPrepare.cpp`][dx-prepare] · [`DXContainerGlobals.cpp`][dx-container] · [`DXILTranslateMetadata.cpp`][dx-meta-stage]
- [`llvm/lib/Target/SPIRV/SPIRVTargetMachine.cpp`][spv-tm] · [`SPIRVCallLowering.cpp`][spv-exec] · [`SPIRVCombine.td`][spv-combine] · [`SPIRVStructurizer.cpp`][spv-struct] · [`SPIRVCBufferAccess.cpp`][spv-cbuf]
- [PetarKirov/ldc `gen/dcompute/targetVulkan.cpp` at the sparkles pin][ldc-fork]
- Related: [HLSL][hlsl] · [DXC][dxc] · [Slang][slang] · [LLVM SPIR-V backend][llvm-spirv] · [DCompute][dcompute] · [SPIRV-Cross][spirv-cross] · [Concepts][concepts] · [Comparison][comparison] · [Catalog][index]
- sparkles: [`sparkles:shaders` SPEC][spec] · [decisions][decisions]

<!-- References -->

[repo]: https://github.com/llvm/llvm-project
[cmake]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/CMakeLists.txt#L606-L627
[docs-dir]: https://github.com/llvm/llvm-project/tree/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/docs/HLSL
[support]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/docs/HLSL/HLSLSupport.md
[entry-doc]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/docs/HLSL/EntryFunctions.md
[res-doc]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/docs/HLSL/ResourceTypes.md
[irref]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/docs/HLSL/HLSLIRReference.md
[diffs]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/docs/HLSL/ExpectedDifferences.md
[parse]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Parse/ParseHLSL.cpp
[parse-rs]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Parse/ParseHLSLRootSignature.cpp
[sema]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Sema/SemaHLSL.cpp
[sema-entry]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Sema/SemaHLSL.cpp#L985-L1035
[sema-spirv]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Sema/SemaSPIRV.cpp
[ext-sema]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Sema/HLSLExternalSemaSource.cpp
[decl-builder]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Sema/HLSLBuiltinTypeDeclBuilder.cpp
[hlsl-h]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Headers/hlsl.h
[hlsl-intr-h]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Headers/hlsl/hlsl_intrinsics.h
[hlsl-helpers]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Headers/hlsl/hlsl_intrinsic_helpers.h
[hlsl-spirv]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Headers/hlsl/hlsl_spirv.h
[intr-td]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/include/clang/Basic/HLSLIntrinsics.td
[builtins-td]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/include/clang/Basic/Builtins.td
[attr-td]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/include/clang/Basic/Attr.td#L5109-L5379
[cgr]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/CodeGen/CGHLSLRuntime.cpp
[cgr-attrs]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/CodeGen/CGHLSLRuntime.cpp#L1030-L1061
[cgr-entry]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/CodeGen/CGHLSLRuntime.cpp#L1740
[cgr-inout]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/CodeGen/CGHLSLRuntime.cpp#L1792-L1795
[cgr-h]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/CodeGen/CGHLSLRuntime.h
[cgr-h-macro]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/CodeGen/CGHLSLRuntime.h#L36-L50
[cgb]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/CodeGen/CGHLSLBuiltins.cpp
[cgm-conv]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/CodeGen/CodeGenModule.h#L1911-L1915
[layout]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/CodeGen/HLSLBufferLayoutBuilder.cpp
[tgt-dx]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/CodeGen/Targets/DirectX.cpp
[tgt-spir]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/CodeGen/Targets/SPIR.cpp
[tgt-spir-hlsl]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/CodeGen/Targets/SPIR.cpp#L761-L821
[spir-h]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Basic/Targets/SPIR.h
[spir-h-stage]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Basic/Targets/SPIR.h#L353-L360
[hlsl-resource-h]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/include/clang/AST/HLSLResource.h
[drv-layout]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Driver/ToolChains/HLSL.cpp#L518-L534
[intr-spv]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/include/llvm/IR/IntrinsicsSPIRV.td
[intr-dx]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/include/llvm/IR/IntrinsicsDirectX.td
[fe-hlsl]: https://github.com/llvm/llvm-project/tree/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Frontend/HLSL
[fe-cbuffer]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Frontend/HLSL/CBuffer.cpp
[binding-h]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/include/llvm/Frontend/HLSL/HLSLBinding.h
[triple-sm]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/TargetParser/Triple.cpp#L1143-L1185
[dx-dir]: https://github.com/llvm/llvm-project/tree/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/DirectX
[dx-tm]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/DirectX/DirectXTargetMachine.cpp#L124-L152
[dxil-td]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/DirectX/DXIL.td
[dx-prepare]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/DirectX/DXILPrepare.cpp
[dx-container]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/DirectX/DXContainerGlobals.cpp
[dx-meta-stage]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/DirectX/DXILTranslateMetadata.cpp#L127-L154
[spv-dir]: https://github.com/llvm/llvm-project/tree/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV
[spv-tm]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVTargetMachine.cpp#L170-L273
[spv-exec]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVCallLowering.cpp#L215-L237
[spv-combine]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVCombine.td
[spv-struct]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVStructurizer.cpp
[spv-cbuf]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVCBufferAccess.cpp
[ldc-fork]: https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/gen/dcompute/targetVulkan.cpp
[spec]: ../../specs/shaders/SPEC.md
[spec-frag]: ../../specs/shaders/SPEC.md#_6-fragment-entry-points
[decisions]: ../../specs/shaders/decisions.md
[hlsl]: ./hlsl.md
[dxc]: ./dxc.md
[slang]: ./slang.md
[llvm-spirv]: ./llvm-spirv-backend.md
[dcompute]: ./dcompute.md
[spirv-cross]: ./spirv-cross.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
