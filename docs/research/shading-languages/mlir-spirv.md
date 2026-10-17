# MLIR `spirv` Dialect (MLIR / C++)

MLIR's one-to-one model of SPIR-V as a compiler IR — structured selection and loop regions, availability-driven capability inference and binary (de)serialization — together with the revived effort to give LDC an MLIR path, the one route by which D statements could reach SPIR-V without a heuristic structurizer.

| Field          | Value                                                                                                                                                                  |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | C++ with ODS/TableGen op definitions                                                                                                                                   |
| License        | Apache-2.0 WITH LLVM-exception                                                                                                                                         |
| Repository     | [llvm/llvm-project][repo] — `mlir/include/mlir/Dialect/SPIRV/`, `mlir/lib/Dialect/SPIRV/`, `mlir/lib/Target/SPIRV/`, `mlir/lib/Conversion/*ToSPIRV/`                   |
| Documentation  | [`mlir/docs/Dialects/SPIR-V.md`][design-doc] · [mlir.llvm.org SPIR-V dialect][mlir-site]                                                                               |
| Category       | Toolchain — compiler IR and SPIR-V serializer                                                                                                                          |
| Latest version | LLVM `main` at [`27ba493781`][tree] (2026-09-19); MLIR has no separate releases                                                                                        |
| Targets        | SPIR-V binary only (Vulkan "Shader" and OpenCL "Kernel" environments); `convert-spirv-to-llvm` lowers per-invocation SPIR-V back to the LLVM dialect                   |
| Main users     | IREE (Vulkan compute), Arm ML/graph extensions; graphics support driven by Imagination's research tooling (no production graphics user visible)                        |
| D connection   | LDC MLIR revival [ldc-developers/ldc#5300][ldc5300] (merged 2026-10-16), inline MLIR [#5307][ldc5307] (open), SAoC 2026 "MLIR Support for LDC" ([proposal][saoc-prop]) |

> [!NOTE]
> MLIR paths are relative to `mlir/` in `llvm-project` at upstream `27ba493781`, the same
> revision as the [LLVM SPIR-V backend][llvm-spirv] deep-dive. The LDC side is read from PR
> metadata, LDC upstream at `ac0e420a` and the SAoC repository
> [asindarov/mlir-support-for-D][saoc-repo] at `79cec3a1`.

---

## Overview

### What it solves

LLVM IR cannot carry SPIR-V's structured control flow, typed pointers or capability
requirements, so the [LLVM backend][llvm-spirv] reconstructs all three after the fact. The
`spirv` dialect keeps them in the IR from the start: a `spirv.module` declares its
version/capabilities/extensions (VCE) triple, selections and loops are regions with
explicit merge and continue blocks, every op carries availability metadata, and the
serializer writes the binary almost one instruction per op. Producers lower into it from
higher dialects (`scf`, `arith`, `math`, `memref`, `vector`, `gpu`), and a front end that
emits `scf` from source statements gets structured SPIR-V without ever building a CFG.

### Design philosophy

The design document ([`docs/Dialects/SPIR-V.md`][design-doc]) states the dialect's level
precisely:

> _"The main objective of the SPIR-V dialect is to be a proper intermediate representation
> (IR) to facilitate compiler transformations. While we still aim to support serializing to
> and deserializing from the binary format for various good reasons, the binary format and
> its concerns play less a role in the design of the SPIR-V dialect: when there is a
> trade-off to be made between favoring IR and supporting binary format, we lean towards the
> former."_

and, in its principles, _"Stay as the same semantic level as the SPIR-V specification by
having one-to-one mapping for most concepts and entities."_ The dialect is therefore not a
shading language and not a higher abstraction: anything above SPIR-V (layout, resource
binding, stages-as-functions) belongs to other dialects or the producer.

---

## How it works

### Structured control flow as regions

`spirv.mlir.selection` and `spirv.mlir.loop` ([`SPIRVControlFlowOps.td`][cf-ops]) replace
`OpSelectionMerge`/`OpLoopMerge` with regions:

> _"Instead of having a `spirv.SelectionMerge` op to directly model selection merge
> instruction for indicating the merge target, we use regions to delimit the boundary of the
> selection: the merge target is the next op following the `spirv.mlir.selection` op."_

```text
spirv.mlir.selection {
  spirv.BranchConditional %cond, ^then, ^merge
^then:
  spirv.Return                      // early return: legal, Return is InFunctionScope
^merge:
  spirv.mlir.merge
}
```

The serializer ([`SerializeOps.cpp`][serialize-ops]) emits the merge instructions from the
region boundaries; the deserializer ([`Deserializer.cpp`][deserializer]) has its own
`ControlFlowStructurizer` to rebuild regions from a binary's merge annotations. Construct
nesting is a property of the IR's shape, so a well-formed `spirv.module` cannot express the
"construct escapes its parent" failure that the LLVM backend's heuristic produces.

### Capabilities derived from availability

Each op, type and enum case carries `min_version`/`max_version`, extension and capability
requirements (`SPIRVAvailability.td`, generated into `QueryMinVersionInterface`,
`QueryCapabilityInterface`, …). The `spirv-update-vce` pass ([`Passes.td`][passes],
[`UpdateVCEPass.cpp`][update-vce]):

> _"For each spirv.module op, this pass requires a `spirv.target_env` attribute on it or an
> enclosing module-like op to drive the deduction. … `spirv.target_env` gives the hard limit
> as for what the target environment can support; this pass deduces what are actually needed
> for a specific spirv.module op."_

This inverts the LLVM backend's model: a target is a **declared environment** (version,
capabilities, extensions, client API, device limits), and the module's requirements are the
minimal set its ops need within it. A target that cannot provide an op is a conversion
failure for that op, with a location, not a whole-module abort.

### Conversions into `spirv`

| Pass / pattern set                                                                           | What it does                                                                                                                                                   |
| -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SCFToSPIRV` ([`SCFToSPIRV.cpp`][scf-to-spirv])                                              | `scf.for`, `scf.if`, `scf.index_switch`, `scf.while` → `spirv.mlir.loop`/`selection`; _"we explicitly create a selection header block … and a merge block"_    |
| `ControlFlowToSPIRV` ([`ControlFlowToSPIRV.cpp`][cf-to-spirv])                               | `cf.cond_br` → plain `spirv.BranchConditional`, no merge — valid only for Kernel                                                                               |
| `lift-cf-to-scf` ([`CFGToSCF.cpp`][cfg-to-scf])                                              | Lifts any single-entry CFG, irreducible ones included, to `scf.while` + `scf.index_switch` (Bahmann et al. 2015, _Perfect Reconstructability of Control Flow_) |
| `ArithToSPIRV`, `MathToSPIRV`, `VectorToSPIRV`, `MemRefToSPIRV`, `FuncToSPIRV`, `GPUToSPIRV` | Scalar/vector arithmetic, `GLSL.std.450`/`OpenCL.std` math, memory, functions, kernel launch ABI                                                               |
| `spirv-lower-abi-attrs` ([`LowerABIAttributesPass.cpp`][lower-abi])                          | Turns ABI attributes into interface variables and `LocalSize` — compute only                                                                                   |
| `convert-spirv-to-llvm` ([`SPIRVToLLVM.cpp`][spirv-to-llvm])                                 | SPIR-V → LLVM dialect, per invocation; group ops become OpenCL builtin calls (`_Z27__spirv_GroupNonUniformIAddii`)                                             |

---

## Execution model and stages

The dialect knows every stage: `SPIRV_ExecutionModelAttr` ([`SPIRVBase.td`][base-td]) lists
`Vertex`, `TessellationControl`, `TessellationEvaluation`, `Geometry`, `Fragment`,
`GLCompute`, `Kernel`, the six `…KHR` ray-tracing stages and `TaskEXT`/`MeshEXT`;
`spirv.EntryPoint` and `spirv.ExecutionMode` ([`SPIRVStructureOps.td`][structure-ops]) take
any of them and every execution mode (`OriginUpperLeft`, `EarlyFragmentTests`,
`DepthReplacing`, primitive and output-vertex modes, …). Geometry primitives
(`spirv.EmitVertex`, `spirv.EndPrimitive`, [`SPIRVPrimitiveOps.td`][primitive-ops]) and
`SPV_EXT_mesh_shader` ops ([`SPIRVMeshOps.td`][mesh-ops]) exist.

The **conversion layer is compute-only**. `spirv::getExecutionModel`
([`TargetAndABI.cpp`][target-abi]) maps a `Shader` capability to `GLCompute` and nothing
else, and the ABI pass emits only `LocalSize`. A graphics producer builds Input/Output
`spirv.GlobalVariable`s, `spirv.EntryPoint` and `spirv.ExecutionMode` itself — exactly the
work `ldc-vulkan` already does in LLVM IR attributes and metadata.

## Type system and generic programming

The type system is SPIR-V's: scalars, `vector`, **`matrix`** (with `MatrixTimesVector`,
`Transpose`, … in [`SPIRVMatrixOps.td`][matrix-ops] — which the LLVM backend never emits),
arrays with stride, runtime arrays, structs with member offsets and decorations, typed
`!spirv.ptr` with a storage class, images, samplers, sampled images, cooperative matrices.
Integers carry signedness in the type, so the "every `int` is `uint`" problem of the LLVM
backend does not arise. There are no generics; MLIR's genericity lives in the producer
dialects (`vector` of any width before `VectorToSPIRV` legalises to four components).

## Resources, interfaces and memory layout

Descriptor bindings are `spirv.GlobalVariable`s with `bind(set, binding)`; push constants,
storage/uniform buffers and `PhysicalStorageBuffer` pointers are storage classes on
`!spirv.ptr`. Layout is explicit in the type (`Offset`, `ArrayStride`), so a producer states
std140/std430/scalar offsets rather than inheriting a DataLayout's. The
`decorate-spirv-composite-type-layout` pass ([`Passes.td`][passes], `Utils/LayoutUtils.cpp`)
attaches layout to composites in `StorageBuffer`, `PhysicalStorageBuffer`, `Uniform` and
`PushConstant` — _"Right now this pass only supports Vulkan layout rules."_ A separate
`spirv-webgpu-prepare` pass expands ops WebGPU cannot take.

The serializer's decoration support is the binding constraint for fragment interfaces
([`Serializer.cpp`][serializer]): `Binding`, `DescriptorSet`, `Location`, `Index`, `Offset`,
`XfbBuffer`/`XfbStride`, `BuiltIn`, `Flat`, `NoPerspective`, `NonReadable`/`NonWritable`,
`RelaxedPrecision`, `Restrict`, `Block`, `Invariant`, `Patch`, `Coherent`, `Volatile` and a
few others are handled; any other decoration reaches the `"unhandled decoration "` error.
**`Centroid`, `Sample` and `Component` are not in the list**, so centroid or per-sample
interpolation and packed varyings fail to serialize.

## Built-in library and intrinsics

About 405 `SPIRV_*Op` definitions span the IR files at this revision: arithmetic, bit,
logical, composite, atomics, barriers, `GLSL.std.450` (`SPIRVGLOps.td`), `OpenCL.std`,
group/non-uniform ops (ballot, elect, shuffle, arithmetic, `QuadSwap`), integer dot product,
cooperative matrix and Arm graph/TOSA extensions. Image ops are partial
([`SPIRVImageOps.td`][image-ops]): `SampledImage`, `ImageDrefGather`, `ImageQuerySize`,
`ImageRead`, `ImageWrite`, `Image`, `ImageSampleExplicitLod`, `ImageSampleImplicitLod`,
`ImageSampleProjDrefImplicitLod`, `ImageFetch`.

Missing at `27ba493781`, each of which a fragment shader uses:

- **Derivatives** — no `OpDPdx`/`OpDPdy`/`OpFwidth` or Fine/Coarse ops anywhere under
  `mlir/include` or `mlir/lib`.
- **Discard** — `spirv.Kill` exists, described as _"Deprecated (use OpTerminateInvocation or
  OpDemoteToHelperInvocation)"_, but neither replacement is an op; `DemoteToHelperInvocation`
  exists only as a capability enum case.
- **Sampling** — no `ImageGather`, no Dref implicit/explicit-LOD sampling, no non-Dref
  projective sampling, no `ImageQueryLod`/`QuerySizeLod`/`QueryLevels`.
- **Subgroups / ray tracing** — no `GroupNonUniformQuadBroadcast`; no `OpTraceRayKHR`, ray
  query or hit-reporting ops, although the stages exist.

## Control flow, memory model and restrictions

Structured control flow is enforced by construction (see [How it works](#structured-control-flow-as-regions)).
The cost moves to the producer: `func.return` is `HasParent<"FuncOp">`
([`FuncOps.td`][func-ops]) and `scf` has no `break`/`continue`, so a front end lowering D's
early `return`, `break` and `continue` into `scf` must turn them into flags or yielded values,
or emit `cf` locally and run `lift-cf-to-scf`. Either way **the lowering defines where
invocations reconverge** — a choice the LLVM path leaves to SimplifyCFG and the structurizer,
and one that matters to derivatives and subgroup operations. `ControlFlowToSPIRV` is not an
alternative for shaders: unstructured branches are only valid in Kernel modules.

The memory model, addressing model and pointer storage classes are explicit on
`spirv.module` and `!spirv.ptr`; `spirv-update-vce` adds `VulkanMemoryModel` or
`PhysicalStorageBufferAddresses` when ops need them. Validation is MLIR's op verifiers plus
availability; it is not `spirv-val`, so Vulkan-environment rules (non-opaque
`UniformConstant`, recursion) still need the external validator.

## Compilation pipeline and targets

```text
producer dialects (scf, arith, math, vector, memref, gpu)
  → *-to-spirv conversions (SPIRVConversionTarget built from spirv.target_env)
  → spirv.module → spirv-update-vce → canonicalisation, spirv-unify-aliased-resource, …
  → mlir-translate --serialize-spirv → SPIR-V binary
```

Output is SPIR-V only. GLSL, MSL, HLSL and WGSL still need [SPIRV-Cross][spirv-cross],
[naga][naga] or [Tint][tint]; **MLIR has no DXIL path** (no `dxil` or `directx` under
`mlir/include` or `mlir/lib`), so DirectX would go MLIR → LLVM dialect → LLVM IR → LLVM's
DirectX backend, the LLVM-IR route again ([Clang HLSL][clang-hlsl]).

### The D/LDC MLIR effort

| When       | What                                                                                                                                                                                                                                                                                                                                                                 |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2019–2020  | SAoC 2019, Roberto Rosmaninho: a custom "D" dialect and `MLIRGen` in an LDC fork ([D-Dialect-for-MLIR][rr-dialect], 2019-08-26 to 2020-01-23; [Robertorosmaninho/ldc][rr-ldc]). Only scaffolding was upstreamed — `FindMLIR` and [`-output-mlir` (#3313)][ldc3313], merged 2020-05-22. The emitted samples were flat `std.cond_br` CFGs, i.e. unstructured.          |
| 2022-03-31 | LDC `acc306a4` "Hack: Disable MLIR support with LLVM 14+ for now" (Martin Kinkelin); LDC upstream `ac0e420a` still gates MLIR on `LLVM_VERSION_MAJOR LESS 14` in [`CMakeLists.txt`][ldc-cmake].                                                                                                                                                                      |
| 2026-09    | SAoC 2026 "MLIR Support for LDC", Asadbek Sindarov, mentor Nicholas Wilson (dcompute's author). Milestones ([`saoc-mislestones.md`][saoc-ms]): M1 MLIR build + `LDC_inline_mlir`; M2 an AST visitor emitting `func`/`arith` for the BetterC subset; **M3 `if`/`else` → `scf.if`, loops → `scf.for`/`scf.while`, then `scf`→`cf`→`llvm`**; stretch: DCompute kernels. |
| 2026-10-16 | [#5300][ldc5300] merged ("Revive MLIR support in the build"): `LDC_WITH_MLIR` AUTO/ON/OFF, `find_package(MLIR CONFIG)`, `OwningOpRef<ModuleOp>`; _"there's still no MLIR codegen, so `-output-mlir` writes an empty module"_.                                                                                                                                        |
| 2026-10-16 | [#5307][ldc5307] opened: `__mlir!(code, R, P...)` in `ldc.llvmasm`, wrapped in `func.func`, lowered `scf → cf`, `arith`/`cf`/`func → llvm`, linked in `alwaysinline`; dialects `func`, `arith`, `cf`, `scf`, `llvm`.                                                                                                                                                 |

The proposal ([`saoc-proposal.md`][saoc-prop]) is explicit about direction: _"I intend to keep
extending MLIR support in LDC, including a DCompute target, beyond SAOC"_, names `memref` as
_"a good fit for DCompute's global/local/private address spaces"_, and puts a D dialect out
of scope.

> [!IMPORTANT]
> As planned, M3 lowers `scf` to `cf` and on to LLVM IR — which discards the structure
> before any SPIR-V back end sees it. For shaders, the useful artifact is the D-statement →
> `scf` visitor itself, with an `scf → spirv` exit kept open alongside `scf → cf → llvm`.

## Host integration and CPU execution

MLIR offers no host runtime for SPIR-V at this revision (`mlir/tools/` has `mlir-runner`;
the former Vulkan and SPIR-V CPU runners are gone). `convert-spirv-to-llvm` gives a
per-invocation CPU lowering, not SPMD: group operations become calls to OpenCL builtins, and
nothing models quads, helper invocations or derivatives. The `vector` dialect has masking,
shuffles and reductions, but no pass takes a scalar per-invocation function and lanes it out.
Structured `scf` input is nevertheless the natural substrate for an ISPC-style masking pass
(`scf.if` → both arms under a mask; `scf.while` → loop while `any(mask)`), because it is
already the linearised form whole-function vectorisers such as [ISPC][ispc] have to
reconstruct.

---

## Lessons for sparkles:shaders

- **Adopt: declared target environments.** Model a target as a D value — SPIR-V version,
  capabilities, extensions, client API — and derive a module's requirements from what the
  vocabulary used, as `spirv-update-vce` does, instead of a backend's fixed whitelist. Each
  vocabulary item then carries its availability (a UDA such as `@requires(Capability.DerivativeControl)`).
- **Match: structure from statements.** If `sparkles:shaders` ever owns its SPIR-V
  emission, emit structure from D's `if`/`while`/`switch` directly; early `return`, `break`
  and `continue` lower to explicit flags whose placement _defines_ reconvergence, and the
  CPU simulator must use the same lowering.
- **Adopt: one structured IR for GPU and CPU.** The scalar CPU reference and a later
  SPMD-on-SIMD simulator both want structured regions; MLIR's `scf` is the evidence that the
  same form serves SPIR-V serialization and lane masking.
- **Avoid: migrating now.** Derivatives, terminate/demote, gather and Dref sampling and the
  `Centroid`/`Sample`/`Component` decorations are missing; a fragment shader cannot ship
  without them, and LDC builds with MLIR do not exist outside a source build yet.
- **Adopt: contribute requirements to SAoC M3.** Offer the shader control-flow corpus
  (early return in nested `if`, `else if (a && b)`, `break`/`continue` in nested loops,
  `switch`) as M3 acceptance tests with a `--convert-scf-to-spirv` + `spirv-val` check, and
  ask that the `scf` stage stay exposed rather than lowered straight to `cf`.
- **Match: explicit layout in types.** The dialect has no DataLayout; offsets and strides
  are in the types. `sparkles:shaders` should compute them in D the same way, whichever
  back end serializes them.

## Strengths

- Structured control flow by construction; early return inside a selection is legal, and
  construct nesting cannot be violated.
- Capability, extension and version requirements are derived per op against a declared
  target environment.
- Full stage and execution-mode enumeration, matrix types, signed integer types, explicit
  layout.
- `lift-cf-to-scf` is a correct-by-construction structurizer for arbitrary (even
  irreducible) CFGs.
- Upstream is receptive to graphics additions (geometry and mesh ops landed in 2025).

## Weaknesses

- Graphics op coverage is thin: no derivatives, no terminate/demote, partial image sampling,
  no ray-tracing instructions.
- The serializer rejects common interpolation decorations (`Centroid`, `Sample`,
  `Component`).
- All conversion layers above the dialect target compute only.
- SPIR-V binary is the only output; no DXIL, no shading-language emitters.
- No visible production graphics user; LDC's MLIR support is days old and BetterC-scoped.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                | Trade-off                                                                                      |
| ------------------------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| One-to-one with the SPIR-V spec                         | Straightforward (de)serialization; no invented semantics | Every graphics instruction must be added op by op; no higher-level shader abstraction          |
| Merge/continue as regions, not instructions             | Nesting is structural; region-based transforms are easy  | Producers must lower unstructured exits themselves; deserializing needs its own structurizer   |
| Availability on every op + `spirv-update-vce`           | Minimal requirements per module; precise errors per op   | Every op definition carries availability metadata to maintain                                  |
| Target environment as an attribute (`spirv.target_env`) | Conversions can legalise per device/API                  | The producer must know and state the target; there is no default "Vulkan" profile to fall into |
| `cf → spirv` without merges                             | Kernel modules need no structure                         | Unusable for shaders; a shader producer must go through `scf` or `lift-cf-to-scf`              |
| Compute-first conversions (`gpu`, ABI lowering)         | IREE and ML workloads drove the work                     | Graphics producers write entry points, interfaces and execution modes by hand                  |

## Sources

- [llvm/llvm-project at `27ba493781`][tree] — `mlir/`
- [`mlir/docs/Dialects/SPIR-V.md` — design document][design-doc] · [published version][mlir-site]
- [`SPIRVBase.td` — execution models, modes, capabilities][base-td] ·
  [`SPIRVControlFlowOps.td`][cf-ops] · [`SPIRVStructureOps.td`][structure-ops] ·
  [`SPIRVImageOps.td`][image-ops] · [`SPIRVMatrixOps.td`][matrix-ops] ·
  [`SPIRVPrimitiveOps.td`][primitive-ops] · [`SPIRVMeshOps.td`][mesh-ops]
- [`Passes.td`][passes] · [`UpdateVCEPass.cpp`][update-vce] · [`TargetAndABI.cpp`][target-abi] ·
  [`LowerABIAttributesPass.cpp`][lower-abi]
- [`SCFToSPIRV.cpp`][scf-to-spirv] · [`ControlFlowToSPIRV.cpp`][cf-to-spirv] ·
  [`CFGToSCF.cpp`][cfg-to-scf] · [`SPIRVToLLVM.cpp`][spirv-to-llvm]
- [`Serializer.cpp`][serializer] · [`SerializeOps.cpp`][serialize-ops] ·
  [`Deserializer.cpp`][deserializer] · [`FuncOps.td`][func-ops]
- [ldc-developers/ldc#5300 — Revive MLIR support in the build][ldc5300] ·
  [#5307 — `LDC_inline_mlir`][ldc5307] · [#3313 — `-output-mlir`][ldc3313] ·
  [LDC `CMakeLists.txt` at `ac0e420a`][ldc-cmake]
- [asindarov/mlir-support-for-D — SAoC 2026 proposal][saoc-prop] and [milestones][saoc-ms]
- [Robertorosmaninho/D-Dialect-for-MLIR (SAoC 2019)][rr-dialect] · [Robertorosmaninho/ldc][rr-ldc]
- Related: [LLVM SPIR-V backend][llvm-spirv] · [Clang HLSL][clang-hlsl] ·
  [SPIRV-Cross][spirv-cross] · [naga][naga] · [Tint][tint] · [dcompute][dcompute] ·
  [Vcc/Shady][vcc] · [ISPC][ispc] · [Concepts][concepts] · [Comparison][comparison] ·
  [Index][index] · [`sparkles:shaders` SPEC][spec]

<!-- References -->

[repo]: https://github.com/llvm/llvm-project
[tree]: https://github.com/llvm/llvm-project/tree/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir
[design-doc]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/docs/Dialects/SPIR-V.md
[mlir-site]: https://mlir.llvm.org/docs/Dialects/SPIR-V/
[base-td]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/include/mlir/Dialect/SPIRV/IR/SPIRVBase.td
[cf-ops]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/include/mlir/Dialect/SPIRV/IR/SPIRVControlFlowOps.td
[structure-ops]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/include/mlir/Dialect/SPIRV/IR/SPIRVStructureOps.td
[image-ops]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/include/mlir/Dialect/SPIRV/IR/SPIRVImageOps.td
[matrix-ops]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/include/mlir/Dialect/SPIRV/IR/SPIRVMatrixOps.td
[primitive-ops]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/include/mlir/Dialect/SPIRV/IR/SPIRVPrimitiveOps.td
[mesh-ops]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/include/mlir/Dialect/SPIRV/IR/SPIRVMeshOps.td
[passes]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/include/mlir/Dialect/SPIRV/Transforms/Passes.td
[update-vce]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/lib/Dialect/SPIRV/Transforms/UpdateVCEPass.cpp
[target-abi]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/lib/Dialect/SPIRV/IR/TargetAndABI.cpp
[lower-abi]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/lib/Dialect/SPIRV/Transforms/LowerABIAttributesPass.cpp
[scf-to-spirv]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/lib/Conversion/SCFToSPIRV/SCFToSPIRV.cpp
[cf-to-spirv]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/lib/Conversion/ControlFlowToSPIRV/ControlFlowToSPIRV.cpp
[cfg-to-scf]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/lib/Transforms/Utils/CFGToSCF.cpp
[spirv-to-llvm]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/lib/Conversion/SPIRVToLLVM/SPIRVToLLVM.cpp
[serializer]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/lib/Target/SPIRV/Serialization/Serializer.cpp
[serialize-ops]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/lib/Target/SPIRV/Serialization/SerializeOps.cpp
[deserializer]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/lib/Target/SPIRV/Deserialization/Deserializer.cpp
[func-ops]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/mlir/include/mlir/Dialect/Func/IR/FuncOps.td
[ldc5300]: https://github.com/ldc-developers/ldc/pull/5300
[ldc5307]: https://github.com/ldc-developers/ldc/pull/5307
[ldc3313]: https://github.com/ldc-developers/ldc/pull/3313
[ldc-cmake]: https://github.com/ldc-developers/ldc/blob/ac0e420af3fe74de50ff2138f9ffcb464c29873a/CMakeLists.txt
[saoc-repo]: https://github.com/asindarov/mlir-support-for-D
[saoc-prop]: https://github.com/asindarov/mlir-support-for-D/blob/79cec3a185de60a6cdc05007201ec78b3248ea16/saoc-proposal.md
[saoc-ms]: https://github.com/asindarov/mlir-support-for-D/blob/79cec3a185de60a6cdc05007201ec78b3248ea16/saoc-mislestones.md
[rr-dialect]: https://github.com/Robertorosmaninho/D-Dialect-for-MLIR
[rr-ldc]: https://github.com/Robertorosmaninho/ldc
[llvm-spirv]: ./llvm-spirv-backend.md
[clang-hlsl]: ./clang-hlsl.md
[spirv-cross]: ./spirv-cross.md
[naga]: ./naga.md
[tint]: ./tint.md
[dcompute]: ./dcompute.md
[vcc]: ./vcc-shady.md
[ispc]: ./ispc.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[spec]: ../../specs/shaders/SPEC.md
