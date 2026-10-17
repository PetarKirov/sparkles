# LLVM SPIR-V Backend (LLVM / C++)

LLVM's in-tree code generator from LLVM IR to SPIR-V — the stage that turns `sparkles:shaders`' D device modules into a Vulkan-flavoured shader module today, and the component whose whitelists and structurizer bound what a single-source D design can express.

| Field                | Value                                                                                                                                                                 |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language             | C++ (GlobalISel-based LLVM target, TableGen-described operands)                                                                                                       |
| License              | Apache-2.0 WITH LLVM-exception                                                                                                                                        |
| Repository           | [llvm/llvm-project][repo] — `llvm/lib/Target/SPIRV/` (cited at upstream [`27ba493781`][tree])                                                                         |
| Documentation        | [`llvm/docs/SPIRVUsage.md`][usage] · [SPIR-V specification][spirv-spec]                                                                                               |
| Category             | Toolchain — compiler back end (LLVM IR → SPIR-V binary)                                                                                                               |
| Latest version       | LLVM `main` (24.0.0git) at `27ba493781`, 2026-09-19 — the revision sparkles builds; no LLVM release has shipped the shader-side changes surveyed here                 |
| Targets              | `spirv32`/`spirv64` (OpenCL "Kernel" environment, physical addressing), `spirv` (logical addressing; with OS `vulkan` the "Shader" environment); SPIR-V 1.0–1.6       |
| Front ends           | Clang (OpenCL C, HLSL → SPIR-V; see [Clang HLSL][clang-hlsl]), LDC's dcompute (OpenCL, Vulkan), any LLVM IR producer                                                  |
| sparkles patch stack | [PetarKirov/dlang.nix `pkgs/llvm-spirv/`][nix-pkg] at `d4063afb` — seven patches on `27ba493781`, consumed by `ldc-vulkan` ([PetarKirov/ldc][ldc-fork] at `64104a9a`) |

> [!NOTE]
> Paths below are relative to `llvm/lib/Target/SPIRV/` unless they start with `llvm/` or
> `clang/`. Every claim is read at upstream `27ba493781`; claims about the sparkles patches
> are read from the patch files at dlang.nix `d4063afb` and the LDC fork at `64104a9a`.

---

## Overview

### What it solves

Before this backend, the only LLVM-to-SPIR-V route was Khronos' out-of-tree
SPIRV-LLVM-Translator, which targets the OpenCL "Kernel" dialect (physical pointers, no
structured control flow). The in-tree backend started on the same Kernel side and has, since
Clang began lowering HLSL to SPIR-V, grown a second personality: the Vulkan "Shader"
environment with logical addressing, `OpEntryPoint`s for graphics stages, descriptor
resources, `GLSL.std.450` math and a structurizer that inserts `OpSelectionMerge` /
`OpLoopMerge`. That second personality is what makes it usable for D: LDC already emits LLVM
IR, so a D shader reaches SPIR-V without a bespoke code generator — the route
[Vcc][vcc] takes from Clang and the route [Zig][zig] takes from its own LLVM back end.

The backend does not translate to any shading language; GLSL, HLSL, MSL and WGSL come from
[SPIRV-Cross][spirv-cross], [naga][naga] or [Tint][tint] downstream. It is the
_producer_ of the module every translator in this catalog consumes.

### Design philosophy

The backend's user guide frames it as a generic LLVM target driven by triple and command line
([`llvm/docs/SPIRVUsage.md`][usage]):

> _"The SPIR-V backend can be invoked either from LLVM's Static Compiler (llc) or Clang,
> allowing developers to compile LLVM intermediate language (IL) files or OpenCL kernel
> sources directly to SPIR-V."_

Three choices follow and run through every section below:

1. **The IR contract is HLSL-shaped.** Shader entry points are recognised by Clang-HLSL's
   function attributes (`"hlsl.shader"`, `"hlsl.numthreads"`), resources by Clang-HLSL's
   intrinsics (`llvm.spv.resource.*`) and target-extension types (`spirv.VulkanBuffer`,
   `spirv.Image`). Any other front end — LDC included — speaks HLSL's dialect of LLVM IR.
2. **Requirements are checked against a whitelist, not derived for a target.** Each emitted
   instruction, type and decoration adds a capability requirement; a requirement outside the
   environment's fixed available set aborts code generation.
3. **Structure is recovered, not preserved.** LLVM IR has no merge blocks, so the backend
   rebuilds structured control flow heuristically after the optimiser has reshaped the CFG.

---

## How it works

### Environment, version and data layout

`SPIRVSubtarget`'s constructor ([`SPIRVSubtarget.cpp`][subtarget]) fixes three things from the
triple:

- **Environment.** OS `vulkan` ⇒ `Env = Shader`; OS `opencl`, vendor `amd` or OS `chipstar` ⇒
  `Kernel`; anything else is `Unknown` and `resolveEnvFromModule` decides per module (any
  function with `"hlsl.shader"`, or a `spirv.MemoryModel` named metadata of `Simple`,
  `GLSL450` or `VulkanKHR`, makes it `Shader`).
- **SPIR-V version — from the sub-architecture only.** `spirv1.0` … `spirv1.6` select the
  version; with no sub-architecture the default is **1.4** (1.6 for vendor `amd`). The
  Vulkan OS version is never consulted: `Triple::getVulkanVersion()`
  ([`llvm/lib/TargetParser/Triple.cpp`][triple]) has callers only in Clang
  (`clang/lib/Basic/Targets/SPIR.h`, `clang/lib/Frontend/CompilerInvocation.cpp`), none under
  `llvm/lib/Target/SPIRV/`.
- **Data layout.** The logical `spirv` arch gets `"e-ve-i64:64-n8:16:32:64-G10"`
  ([`TargetDataLayout.cpp`][datalayout]): element-aligned vectors (`ve`), globals in address
  space 10 (`Private`), no pointer size — the file's own comment says _"Logical SPIR-V has no
  pointer size, so any fixed pointer size would be wrong."_

> [!WARNING]
> The user guide's OS table says `vulkan1.3` is the _"Vulkan 1.3 runtime, corresponding to
> SPIR-V 1.6"_ ([`SPIRVUsage.md`][usage]), but the backend ignores the OS version. Clang's
> driver derives the sub-architecture from the Vulkan version before LLVM sees the triple;
> another front end must spell `spirv1.6-…` itself. sparkles hit exactly this: LDC created its
> target machine with an explicit arch name `spirv`, which replaced the triple's arch and its
> `1.6` sub-architecture, and every module said SPIR-V 1.4 until fork commit `8a79405e`
> ("dcompute: Vulkan modules are SPIR-V 1.6").

### The pass pipeline

`SPIRVPassConfig` ([`SPIRVTargetMachine.cpp`][targetmachine]) runs, for shader modules, an IR
prelude before GlobalISel:

```text
InferAddressSpaces → LoopSimplify → RegToMem            (every PHI and cross-block value to an alloca)
  → SPIRVMergeRegionExitTargets → SPIRVStructurizer     (merge/continue intrinsics inserted)
  → PromoteMemoryToRegister → LoopSimplify
  → StripConvergenceIntrinsics → SPIRVLegalizeResourceBinding → SPIRVLegalizeZeroSizeArrays
  → SPIRVCBufferAccess → SPIRVPushConstantAccess → SPIRVEmitIntrinsics → SPIRVLegalizePointerCast
  → IRTranslator → PreLegalizerCombiner → PreLegalizer → Legalizer → PostLegalizer
  → InstructionSelect → … → SPIRVModuleAnalysis (requirements) → SPIRVAsmPrinter
```

`SPIRVEmitIntrinsics` ([`SPIRVEmitIntrinsics.cpp`][emitintr]) is the heart of the
opaque-pointer problem: SPIR-V needs typed pointers, so the pass deduces pointee types and
records them in `spv_assign_ptr_type` / `spv_assign_type` intrinsics, and rewrites
byte-offset GEPs back into logical access chains (`buildLogicalAccessChainFromGEP`).
`SPIRVFinalizeShaderLinkage` internalises non-entry helpers and erases dead ones — only above
`-O0`, and never a function with external linkage and default visibility.

### What a front end emits

An entry point is an ordinary function with HLSL attributes; resources are handles from
intrinsics. What `ldc-vulkan` produces for a compute kernel has this shape (illustrative,
reconstructed from [`gen/dcompute/targetVulkan.cpp`][ldc-target]):

```llvm
target triple = "spirv1.6-unknown-vulkan1.3-compute"

define void @main() #0 { … }
attributes #0 = { "hlsl.shader"="compute" "hlsl.numthreads"="64,1,1" }

!llvm.module.flags = !{!0, !1}
!0 = !{i32 1, !"spirv.signed-integers", i32 1}          ; sparkles patch
!1 = !{i32 1, !"spirv.physical-storage-buffer", i32 1}  ; sparkles patch
```

---

## Execution model and stages

`getExecutionModel` ([`SPIRVCallLowering.cpp`][calllowering]) maps exactly three
`"hlsl.shader"` values — `"compute"` ⇒ `GLCompute`, `"vertex"` ⇒ `Vertex`, `"pixel"` ⇒
`Fragment` — and anything else to a fatal error,
_"This HLSL entry point is not supported by this backend."_ Geometry, tessellation, mesh/task and all ray-tracing stages have
`ExecutionModel` enum entries in `SPIRVSymbolicOperands.td` but no path to them.

Execution modes are emitted by [`SPIRVAsmPrinter.cpp`][asmprinter]: `"pixel"` always gets
`OriginUpperLeft`; `"hlsl.numthreads"="x,y,z"` gives `LocalSize`;
`"enable-maximal-reconvergence"` gives `MaximallyReconvergesKHR`. Everything else —
`DepthReplacing`, `EarlyFragmentTests`, `DepthGreater`, `PixelCenterInteger` — goes through
the generic escape hatch, a `!spirv.ExecutionMode` named metadata whose nodes are emitted
verbatim. `hlsl.wavesize` is not handled (no match for `wavesize` in the target), nor is
`LocalSizeId`.

Every global `OpVariable` (Input/Output only before 1.4; all storage classes from 1.4) is
appended to **every** `OpEntryPoint`'s interface list, not per call tree — harmless with one
entry point per module, which is how `sparkles:shaders` builds them.

## Type system and generic programming

Not applicable as a language: the backend has no generics, only LLVM's types plus
target-extension types. What it reads matters:

- **Integers are signless** in LLVM, and upstream emits every one as `OpTypeInt N 0`
  (unsigned). A GLSL translation then declares a D `int` uniform as `uint`, and a GLSL ES
  1.00 translation (no unsigned types) breaks. Signedness is a module-level policy the front
  end must request (see [sparkles patches](#what-sparkles-patch-stack-changes)).
- **Vectors** are capped at four components in shader env and split above that
  (`SPIRVLegalizerInfo.cpp`). **Matrices are never emitted**: `OpTypeMatrix` has a TableGen
  definition and a `Matrix` requirement, but nothing builds it; `llvm.matrix.*` intrinsics are
  lowered to shuffles and dots on flat vectors (`SPIRVCombinerHelper.cpp`). A matrix in a
  buffer is an array of vectors, with no `ColMajor`/`MatrixStride` decoration.
- **Target-extension types** carry everything LLVM has no type for ([`SPIRVBuiltins.td`][builtins-td],
  dispatched in `SPIRVBuiltins.cpp`): `spirv.Image(T, dim, depth, arrayed, ms, sampled, format[, access])`,
  `spirv.SignedImage`, `spirv.SampledImage`, `spirv.Sampler`,
  `spirv.VulkanBuffer(T, storageClass, isWritable)`, `spirv.PushConstant(T)`,
  `spirv.Layout(%S, size, offsets…)`, `spirv.Padding(N)`, `spirv.CooperativeMatrixKHR`, and
  the inline-SPIR-V escape `spirv.Type(opcode, size, align; params…)` that builds an arbitrary
  `OpType*`.
- **Spec constants**: only booleans — `llvm.spv.named.boolean.spec.constant`, with the
  `.td`'s own _"TODO: possibly add intrinsics for other types of Spec Constants"_
  ([`IntrinsicsSPIRV.td`][intrinsics-td]).

## Resources, interfaces and memory layout

**Address space ↔ storage class** (`addressSpaceToStorageClass`, [`SPIRVUtils.cpp`][utils]):

| Address space | Storage class (upstream)                     | Notes for a D front end                                                      |
| ------------- | -------------------------------------------- | ---------------------------------------------------------------------------- |
| 0             | `Function`                                   | locals                                                                       |
| 1             | `CrossWorkgroup`                             | sparkles' opt-in patch: `PhysicalStorageBuffer` when the module asks         |
| 2             | `UniformConstant`                            | images/samplers; a non-opaque variable here is invalid for Vulkan            |
| 3             | `Workgroup`                                  | dcompute `Shared` (fork `488d5239`)                                          |
| 4             | `Generic`                                    | Kernel only                                                                  |
| 5 / 6         | `DeviceOnlyINTEL` / `HostOnlyINTEL`          | else `CrossWorkgroup`                                                        |
| 7 / 8         | `Input` / `Output`                           | stage interface; `BuiltIn` by name `__spirv_BuiltIn…` or `spirv.Decorations` |
| 9             | `CodeSectionINTEL`                           | —                                                                            |
| 10            | `Private`                                    | the logical DataLayout's default global space (`G10`)                        |
| 11 / 12 / 13  | `StorageBuffer` / `Uniform` / `PushConstant` | 13 is rewritten by `SPIRVPushConstantAccess` into `spirv.PushConstant`       |

There is no address space for `Image`, `AtomicCounter`, the ray-tracing payload classes,
`TaskPayloadWorkgroupEXT` or `TileImageEXT` — `report_fatal_error("Unknown address space")`.

**Descriptors.** `llvm.spv.resource.handlefrombinding(set, binding, arraySize, index, name)`
returns a `spirv.VulkanBuffer`/`spirv.Image` handle and becomes an `OpVariable` decorated
`DescriptorSet`/`Binding`; `llvm.spv.resource.getpointer` becomes `OpAccessChain %var 0 idx`.
`getOrCreateVulkanBufferType` ([`SPIRVGlobalRegistry.cpp`][globalregistry]) wraps the element
in a fresh `StructType::create(ElemType)` decorated `Block`. `arraySize > 1` declares a
descriptor array, `arraySize == 0` an `OpTypeRuntimeArray` (bindless);
`llvm.spv.resource.nonuniformindex` propagates `NonUniform`.

**Layout from the DataLayout.** For explicitly laid-out storage classes the backend writes
`Offset` from LLVM's struct layout and `ArrayStride` from `getTypeAllocSize`. With the logical
`e-ve-…` layout that is **scalar/C layout, not std140 or std430**: `<3 x float>` is 12 bytes
aligned 4, and a uniform array's stride is not rounded to 16. A front end pre-pads, or uses
`spirv.Layout` (explicit per-member offsets) and `spirv.Padding` (lowered as an `i8`
placeholder). Clang-HLSL does the latter for `cbuffer`s via `SPIRVCBufferAccess.cpp`.

**Decorations from metadata.** `!spirv.Decorations` on a global or an instruction emits any
literal- or string-operand decoration (`Location`, `Flat`, `NoPerspective`, `Binding`,
`BuiltIn`, `NonWritable`, …), deliberately ignoring `NoContraction` and `FPFastMathMode`.
There is **no member-decoration metadata**: `OpMemberDecorate` is produced only for `Offset`
and the read-only buffer's `NonWritable`, so a `Flat` or `Location` on an I/O-block member is
inexpressible.

## Built-in library and intrinsics

[`IntrinsicsSPIRV.td`][intrinsics-td] defines 161 `int_spv_*` intrinsics at this revision. Two
families:

- **Backend plumbing** inserted by `SPIRVEmitIntrinsics` — `assign_type`, `assign_ptr_type`,
  `gep`, `load`, `store`, `ptrcast`, `loop_merge`, `selection_merge`, … — never written by a
  front end.
- **HLSL-facing operations.** Compute builtins (`thread_id` ⇒ `GlobalInvocationId`,
  `thread_id_in_group`, `group_id`, `flattened_thread_id_in_group`, subgroup ids); math that
  becomes `GLSL.std.450` in shader env (`lerp` ⇒ `FMix`, `frac` ⇒ `Fract`, `rsqrt` ⇒
  `InverseSqrt`, `smoothstep`, `reflect`, `refract`, `faceforward`, `nclamp`/`uclamp`/`sclamp`,
  `packhalf2x16`, `firstbit*`); derivatives `ddx`/`ddy`/`fwidth` and their `_coarse`/`_fine`
  forms (core `OpDPdx`…, `DerivativeControl` for the variants); barriers; wave/subgroup ops
  (`OpGroupNonUniform*`, from SPIR-V 1.3); texture sampling, gather, fetch and queries
  (`resource_sample`, `samplelevel`, `samplegrad`, `samplecmp`, `resource_gather`,
  `resource_getdimensions_*`, …); `discard`.

LLVM's own intrinsics map onto `GLSL.std.450` too — `llvm.fma` ⇒ `Fma`, `llvm.pow` ⇒ `Pow`,
`llvm.minnum`/`maxnum` ⇒ **`NMin`/`NMax`** (NaN-aware, not GLSL's `min`), `llvm.roundeven` ⇒
`RoundEven`, `llvm.exp10`/`log10` expanded through `exp2`/`log2`. There is no `cross`
intrinsic and no `step`; `frem` becomes `OpFRem` (C semantics, not GLSL `mod`).
`smul.hi`, the saturating adds and `ctlz`/`cttz` have no shader mapping. Vendor
`GLSL.std.450` coverage is therefore whatever HLSL needed, which is why the `sparkles:shaders`
vocabulary implements GLSL's compound built-ins as D formulas rather than leaning on
intrinsics.

`discard` is the instructive case. `llvm.spv.discard` selects
`OpDemoteToHelperInvocation` from SPIR-V 1.6 (or with `SPV_EXT_demote_to_helper_invocation`)
and `OpKill` before that ([`SPIRVInstructionSelector.cpp`][isel]) — HLSL `clip` semantics.
Demote does not end the invocation, and GLSL ES, MSL and SM 5 cannot express it, so a GLSL
`discard` needs a separate intrinsic (sparkles' `terminate-invocation` patch).

## Control flow, memory model and restrictions

**Structurizer.** `SPIRVMergeRegionExitTargets` funnels any convergence region (one per
natural loop, from [`SPIRVConvergenceRegionAnalysis.cpp`][convergence]) with several exit
targets through a `new.exit` block and an `i32` dispatch switch. `SPIRVStructurizer::run`
([`SPIRVStructurizer.cpp`][structurizer]) then performs nine steps, quoted from its comments:
loop merges, `OpSelectionMerge` for _"each node with an in-degree >= 2"_ placed at its
immediate dominator, sorting, splitting multi-header blocks, merges for _"conditions with an
exiting branch (return, unreachable)"_, critical-edge splitting, removal of proxy blocks, a
fix-up for _"simple conditional branches with 1 or 2 returning edges"_, and RPO block order.

The weak step is step 5, `addMergeForDivergentBlocks`. It computes a post-dominator tree and
then does not use it:

```cpp
// llvm/lib/Target/SPIRV/SPIRVStructurizer.cpp (upstream 27ba493781)
      if (Candidates.size() <= 1)
        continue;

      Modified = true;
      BasicBlock *Merge = Candidates[0];
```

The merge of a two-way branch whose arms do not reconverge — an early `return` inside a
nested condition, an `else if (a && b)` chain sharing the function's exit — is simply the
first successor that is not already a merge or continue block. Nested headers can then get
merges outside their parents' constructs and `spirv-val` rejects the module ("exits the
selection … but not via a structured exit"). Step 8 skips a branch whose region contains
another construct's blocks (`HasBadBlock`), leaving a header with no merge. Irreducible CFGs
are not handled at all (no `irreducible` anywhere in the target). Coverage is lopsided: 48 of
the 51 files in `llvm/test/CodeGen/SPIRV/structurizer/` use `convergence.entry`/`loop`
tokens, mostly at `llc -O0` — the token-free, optimised IR that LDC produces is barely
exercised.

**Memory model.** Shader modules get `GLSL450` + `Logical` unless `spirv.MemoryModel`
metadata says otherwise; the code carries _"TODO: Add support for VulkanMemoryModel"_ and
_"TODO: Add support for PhysicalStorageBufferAddress"_ ([`SPIRVModuleAnalysis.cpp`][moduleanalysis]).

**Restrictions the backend does not check** (each passes code generation and fails
`spirv-val --target-env vulkan1.x`): `LinkageAttributes` on any non-internal function or
global (needs `Linkage`, forbidden by Vulkan); `MaxByteOffset` from a `dereferenceable`
pointer parameter (needs `Addresses`, also forbidden); non-opaque `UniformConstant`
variables; recursion; pointer arguments that are not memory-object declarations; `memset` of
anything but an `i8` array (lowered via a bitcast `OpCopyMemory` that cannot type-check).
The fork's `TargetVulkan::addMetadata` answers the first and fourth: every non-entry function
becomes `internal` and `alwaysinline`, and a call-graph cycle is a D compile error
(`"device code may not recurse"`, fork commit `7016b474`).

## Compilation pipeline and targets

**Capabilities are a whitelist.** `RequirementHandler::initAvailableCapabilitiesForVulkan`
([`SPIRVModuleAnalysis.cpp`][moduleanalysis]) declares the shader environment's available set:
`Shader`, `Linkage`, `Int8`, `Int16`, `Int64`, `Float16`, `Float64`, `GroupNonUniform*` (from
1.3), image and descriptor-array caps, `DerivativeControl`, `MinLod`, `ImageQuery`,
**`Addresses`**, descriptor-indexing caps from 1.5, `DotProduct*`, `DemoteToHelperInvocation`
and `StorageImage{Read,Write}WithoutFormat` from 1.6. A requirement outside the set aborts
with `"Unable to meet SPIR-V requirements for this target."`. Never available in shader env,
with no extension that enables them: `Geometry`, `Tessellation`, `SampleRateShading` (so
`BuiltIn SampleId`, `SamplePosition` and the `Sample` decoration abort), `InputAttachment`
(subpass inputs), `ClipDistance`/`CullDistance`, cube-array and rect images,
`InterpolationFunction` (`interpolateAt*`), `MultiViewport` (so `Layer`, `ViewportIndex`),
`StencilExportEXT`.

**Extensions are opt-in.** A plain Vulkan triple starts with an empty extension set;
`-spirv-ext=+SPV_…` (or `all`, `khr`) adds those whose TableGen record lists `EnvVulkan`
(86 records do; 72 are `[EnvOpenCL]` only). Being accepted is not being used: nothing emits
mesh, ray-tracing, interlock or draw-parameter instructions. The extensions that do change
code generation in shader env are demote, integer dot product, expect/assume, maximal
reconvergence, `non_semantic_info` (debug info), float controls, `SPV_KHR_fma` and AMD
trinary min/max.

**Debug info.** `SPIRVNonSemanticDebugHandler` emits `NonSemantic.Shader.DebugInfo.100` under
`-g` _and_ `-spirv-ext=+SPV_KHR_non_semantic_info`, even at SPIR-V 1.6 where the extension is
core ([`SPIRVUsage.md`][usage]).

**Output.** Binary SPIR-V (`-filetype=obj`) or textual assembly. There is no validator in the
backend; `spirv-val` is the only gate, and `sparkles:shaders`' build step runs it (SPIR-V 1.6,
spec item `SHP4`) before [SPIRV-Cross][spirv-cross].

### What sparkles' patch stack changes

The `llvm-spirv-vulkan` derivation ([`default.nix`][nix-default]) builds `27ba493781` with
assertions on — _"an assertion that fires in a shader build is a bug report, not a slowdown"_
— and these patches, applied in order:

| Patch                                                      | Change                                                                                                                                                                                                                                                                                                                     |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`vulkan-physical-storage-buffer.patch`][p-psb]            | Vendored [llvm/llvm-project#216919][pr216919] (Pham Quang Ha, GSoC 2026 DCompute Vulkan; open since 2026-08-18): address space 1 ⇒ `PhysicalStorageBuffer` for shaders, addressing model `PhysicalStorageBuffer64`, `Aligned` memory operands, non-zero leading GEP index on PSB pointers                                  |
| [`spirv-signed-ints-member-names.patch`][p-signed]         | Module flag `spirv.signed-integers` ⇒ `OpTypeInt N 1` for widths ≥ 32 (narrower stay unsigned: their literals are zero-extended); a zero-extension into a signed type is no longer an invalid `OpUConvert`; `spirv.MemberNames` metadata ⇒ `OpMemberName`, so uniform struct fields keep their names instead of `_m0`      |
| [`spirv-access-chain-i32-indices.patch`][p-i32]            | `buildLogicalAccessChainFromGEP` builds literal indices as `i32`, not `i64` — an optimised struct-field read no longer drags in `Int64`, which a GLSL ES cross-compile rejects                                                                                                                                             |
| [`vulkan-physical-storage-buffer-opt-in.patch`][p-optin]   | On top of #216919: PSB only when the module sets `spirv.physical-storage-buffer` (the PR as vendored broke 35 upstream tests); `p[i]` becomes `OpPtrAccessChain` with the `ArrayStride` Vulkan requires (also for an optimiser's byte-offset form, which dropped the index); upstream capability rules restored, no `Int8` |
| [`spirv-resource-name-no-int8.patch`][p-name]              | The resource-name string operand of `handlefrombinding` is not materialised as an `i8` array, so a named resource no longer declares `Int8`                                                                                                                                                                                |
| [`spirv-terminate-invocation.patch`][p-term]               | New `llvm.spv.terminate.invocation` (`IntrNoReturn`) ⇒ `OpTerminateInvocation` at 1.6 or with `SPV_KHR_terminate_invocation`, `OpKill` before — GLSL `discard`, distinct from HLSL-style demote                                                                                                                            |
| [`spirv-structurizer-nested-shared-exits.patch`][p-struct] | A first structurizer step that, innermost first, routes edges from a nested header's region into the post-dominator it shares with an enclosing header through a new block that becomes its merge                                                                                                                          |

The fork additionally runs `FixIrreducible` → `UnifyLoopExits` → `StructurizeCFG` on every
Vulkan device function before the backend ([`gen/optimizer.cpp`][ldc-optimizer], commit
`64104a9a`) — _"as the GPU targets that need structured control flow do"_ — so the
backend's structurizer receives nested single-entry, single-exit regions rather than
whatever SimplifyCFG made of D's control flow. With both, loops that return, break and
continue validate at every optimisation level (dlang.nix `d4063afb` message).

## Host integration and CPU execution

None. The backend is a code generator with no runtime, reflection output or CPU execution
path: binding information is whatever the front end put in decorations, and reflection is
recovered downstream (SPIRV-Cross's reflection, or the D side's own CTFE view of the
interface). For a CPU simulator the relevant observation is negative: the same LLVM IR that
feeds this backend is per-invocation scalar code; nothing here vectorises across invocations
(see [MLIR SPIR-V][mlir-spirv] and [ISPC][ispc] for that axis).

---

## Lessons for sparkles:shaders

- **Adopt: one shader-capability profile, validated per target.** Encode the whitelist as data
  in D (`enum ShaderCapability`, per-target sets for Vulkan 1.x, GLSL ES 1.00, WGSL-via-naga),
  and reject a device module's use of `SampleId`, cube arrays or `interpolateAt` at D compile
  time — before the backend's opaque `"Unable to meet SPIR-V requirements"` abort.
- **Match: spell the version in the triple.** Keep `spirv1.6-unknown-vulkan1.3-…` and a test
  that reads the module header's version word; the backend silently defaults to 1.4 and the
  documentation says otherwise.
- **Match: own layout in D.** Compute std140/std430/scalar offsets from D's introspection and
  emit `spirv.Layout`/explicit padding; never rely on the `e-ve` DataLayout, which is scalar
  layout. A `static assert` per uniform struct against a reference table keeps CPU and GPU
  layouts identical.
- **Avoid: optimised CFGs reaching the structurizer raw.** Keep the fork's
  `StructurizeCFG` prelude and a structurizer corpus (early return in nested `if`,
  `else if (a && b)`, `break`/`continue` in nested loops, `switch`) that runs at `-O0`…`-O3` through
  `spirv-val` in CI; upstream's tests are almost all token-annotated `-O0` IR.
- **Adopt: two discards.** Expose `discard` (terminate, GLSL/MSL/SM5 semantics) and `demote`
  as separate vocabulary items mapped to `llvm.spv.terminate.invocation` and
  `llvm.spv.discard`, so the 1.6 change of `llvm.spv.discard`'s meaning cannot leak.
- **Avoid: anything Vulkan forbids that the backend emits.** Internal linkage and
  `alwaysinline` for helpers, no `dereferenceable` on helper parameters, no `memset`/`memcpy`
  in device code, no `i8` in memory unless `Int8` is in the target profile — each enforced by
  a fork-side check plus a `spirv-val --target-env vulkan1.3` gate.
- **Adopt: upstream the patches.** Every sparkles patch is target-generic (signedness,
  member names, i32 indices, terminate, structurizer); carrying seven patches against a moving
  `main` is the dominant maintenance cost of the GPU half.

## Strengths

- In-tree, maintained with LLVM; any LLVM IR producer (LDC) gets SPIR-V without a bespoke
  emitter, with LLVM's optimiser in front.
- Real shader-environment support: descriptor resources, push constants, bindless arrays,
  texture sampling, derivatives, subgroups, `GLSL.std.450`, NonSemantic debug info.
- Escape hatches cover a lot: `!spirv.ExecutionMode`, `!spirv.Decorations`, inline
  `spirv.Type`, `spirv.Layout`.
- The capability machinery at least fails loudly rather than emitting invalid modules for
  missing capabilities.

## Weaknesses

- Three execution models only; no geometry, tessellation, mesh or ray-tracing stages.
- Whitelisted capabilities with large permanent holes (sample-rate shading, input
  attachments, clip/cull distance, cube arrays, interpolation functions).
- Heuristic structurizer that picks an arbitrary merge (`Candidates[0]`) and is tested mostly
  on `-O0`, convergence-token IR.
- No matrix types, no member decorations beyond `Offset`/`NonWritable`, boolean-only spec
  constants, scalar layout from the DataLayout.
- Emits Vulkan-invalid constructs (`Linkage`, `Addresses`, non-opaque `UniformConstant`,
  stray `Int8`/`Int64`) without diagnosing them.
- Version selection ignores the Vulkan OS version despite the documentation.

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                     | Trade-off                                                                                        |
| -------------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Reuse Clang-HLSL's IR conventions as the shader contract | One producer drove the shader work; attributes and intrinsics already existed | Non-HLSL front ends inherit HLSL semantics (demote-style `discard`, HLSL names, `cbuffer` paths) |
| Fixed per-environment capability whitelist               | Simple, deterministic, fails loudly                                           | Cannot target a profile below or beside "Vulkan"; holes abort instead of degrading               |
| Structurize after LLVM optimisation, heuristically       | LLVM IR has no structure to preserve; the optimiser stays unchanged           | Merge choice is a heuristic; optimised CFG shapes break validation; front ends pre-structurize   |
| `RegToMem` round-trip around the structurizer            | Lets the structurizer move edges without PHI bookkeeping                      | Relies on mem2reg to recover SSA; every cross-block value transits an alloca                     |
| Layout from the module DataLayout                        | Reuses LLVM's struct layout machinery                                         | Logical layout is scalar; std140/std430 needs explicit `spirv.Layout`/padding from the front end |
| SPIR-V version from the triple sub-architecture only     | One knob, independent of the client API                                       | `vulkan1.3` without `spirv1.6` silently yields 1.4                                               |
| Extensions opt-in via `-spirv-ext`                       | Output never assumes a device feature                                         | Every consumer must thread flags through its driver; accepted extensions may still emit nothing  |

## Sources

- [llvm/llvm-project at `27ba493781`][tree] — `llvm/lib/Target/SPIRV/`
- [`llvm/docs/SPIRVUsage.md` — triples, extensions, debug info][usage]
- [`SPIRVSubtarget.cpp` — environment, version, extensions][subtarget]
- [`SPIRVModuleAnalysis.cpp` — capability whitelist, memory model][moduleanalysis]
- [`SPIRVStructurizer.cpp` — the nine-step structurizer][structurizer] ·
  [`SPIRVConvergenceRegionAnalysis.cpp`][convergence]
- [`SPIRVTargetMachine.cpp` — pass pipeline][targetmachine]
- [`SPIRVCallLowering.cpp` — execution models][calllowering] ·
  [`SPIRVAsmPrinter.cpp` — execution modes, interfaces][asmprinter]
- [`SPIRVGlobalRegistry.cpp` — types, layout, Block wrapping][globalregistry] ·
  [`SPIRVUtils.cpp` — address spaces][utils]
- [`SPIRVEmitIntrinsics.cpp`][emitintr] · [`SPIRVInstructionSelector.cpp`][isel] ·
  [`SPIRVBuiltins.td`][builtins-td] · [`IntrinsicsSPIRV.td`][intrinsics-td]
- [`llvm/lib/TargetParser/TargetDataLayout.cpp`][datalayout] ·
  [`llvm/lib/TargetParser/Triple.cpp`][triple]
- [PetarKirov/dlang.nix `pkgs/llvm-spirv/` at `d4063afb`][nix-pkg] — the patch stack
- [PetarKirov/ldc `gen/dcompute/targetVulkan.cpp`][ldc-target] ·
  [`gen/optimizer.cpp`][ldc-optimizer] at `64104a9a`
- [llvm/llvm-project#216919 — PhysicalStorageBuffer addressing (GSoC 2026)][pr216919]
- [SPIR-V specification (Khronos)][spirv-spec]
- Related: [Clang HLSL][clang-hlsl] · [MLIR SPIR-V][mlir-spirv] · [SPIRV-Cross][spirv-cross] ·
  [naga][naga] · [Tint][tint] · [dcompute][dcompute] · [Vcc/Shady][vcc] ·
  [Zig SPIR-V][zig] · [Concepts][concepts] · [Comparison][comparison] · [Index][index] ·
  [`sparkles:shaders` SPEC][spec] · [decisions][decisions]

<!-- References -->

[repo]: https://github.com/llvm/llvm-project
[tree]: https://github.com/llvm/llvm-project/tree/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV
[usage]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/docs/SPIRVUsage.md
[subtarget]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVSubtarget.cpp
[moduleanalysis]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVModuleAnalysis.cpp
[structurizer]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVStructurizer.cpp
[convergence]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/Analysis/SPIRVConvergenceRegionAnalysis.cpp
[targetmachine]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVTargetMachine.cpp
[calllowering]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVCallLowering.cpp
[asmprinter]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVAsmPrinter.cpp
[globalregistry]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVGlobalRegistry.cpp
[utils]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVUtils.cpp
[emitintr]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVEmitIntrinsics.cpp
[isel]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVInstructionSelector.cpp
[builtins-td]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVBuiltins.td
[intrinsics-td]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/include/llvm/IR/IntrinsicsSPIRV.td
[datalayout]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/TargetParser/TargetDataLayout.cpp
[triple]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/TargetParser/Triple.cpp
[pr216919]: https://github.com/llvm/llvm-project/pull/216919
[spirv-spec]: https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html
[nix-pkg]: https://github.com/PetarKirov/dlang.nix/tree/d4063afb347d524a632095c57c845facb6a4d3e5/pkgs/llvm-spirv
[nix-default]: https://github.com/PetarKirov/dlang.nix/blob/d4063afb347d524a632095c57c845facb6a4d3e5/pkgs/llvm-spirv/default.nix
[p-psb]: https://github.com/PetarKirov/dlang.nix/blob/d4063afb347d524a632095c57c845facb6a4d3e5/pkgs/llvm-spirv/vulkan-physical-storage-buffer.patch
[p-signed]: https://github.com/PetarKirov/dlang.nix/blob/d4063afb347d524a632095c57c845facb6a4d3e5/pkgs/llvm-spirv/spirv-signed-ints-member-names.patch
[p-i32]: https://github.com/PetarKirov/dlang.nix/blob/d4063afb347d524a632095c57c845facb6a4d3e5/pkgs/llvm-spirv/spirv-access-chain-i32-indices.patch
[p-optin]: https://github.com/PetarKirov/dlang.nix/blob/d4063afb347d524a632095c57c845facb6a4d3e5/pkgs/llvm-spirv/vulkan-physical-storage-buffer-opt-in.patch
[p-name]: https://github.com/PetarKirov/dlang.nix/blob/d4063afb347d524a632095c57c845facb6a4d3e5/pkgs/llvm-spirv/spirv-resource-name-no-int8.patch
[p-term]: https://github.com/PetarKirov/dlang.nix/blob/d4063afb347d524a632095c57c845facb6a4d3e5/pkgs/llvm-spirv/spirv-terminate-invocation.patch
[p-struct]: https://github.com/PetarKirov/dlang.nix/blob/d4063afb347d524a632095c57c845facb6a4d3e5/pkgs/llvm-spirv/spirv-structurizer-nested-shared-exits.patch
[ldc-fork]: https://github.com/PetarKirov/ldc/tree/64104a9a6da522730d6b661b85adfdfd2e7e25e7
[ldc-target]: https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/gen/dcompute/targetVulkan.cpp
[ldc-optimizer]: https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/gen/optimizer.cpp
[clang-hlsl]: ./clang-hlsl.md
[mlir-spirv]: ./mlir-spirv.md
[spirv-cross]: ./spirv-cross.md
[naga]: ./naga.md
[tint]: ./tint.md
[dcompute]: ./dcompute.md
[vcc]: ./vcc-shady.md
[zig]: ./zig-spirv.md
[ispc]: ./ispc.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[spec]: ../../specs/shaders/SPEC.md
[decisions]: ../../specs/shaders/decisions.md
