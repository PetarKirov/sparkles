# DXC (DirectXShaderCompiler)

Microsoft's reference HLSL compiler: a heavily modified LLVM/Clang 3.7 fork that emits validated, hashed DXIL for Direct3D 12 and, through a separate AST-to-SPIR-V emitter contributed by Google, SPIR-V for Vulkan.

| Field             | Value                                                                                                                                          |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | C++ (LLVM/Clang 3.7-era fork); Python generators (`utils/hct/hctdb.py`)                                                                        |
| License           | University of Illinois/NCSA (LLVM release license, [`LICENSE.TXT`][license]); `d3d12shader.h` MIT                                              |
| Repository        | [microsoft/DirectXShaderCompiler][repo] (pinned at `194bb75b`, 2026-10-16)                                                                     |
| Documentation     | [`docs/SPIR-V.rst`][spirv-rst] (HLSL→SPIR-V mapping manual), [`docs/DXIL.rst`][dxil-rst], [`docs/ReleaseNotes.md`][relnotes]                   |
| Category          | Toolchain: HLSL front end with two independent back ends (DXIL, SPIR-V)                                                                        |
| Latest version    | `v1.9.2609` (2026-09-16, retail); `v1.10.2605.37` (2026-08-06, SM 6.10 line); SM 6.10 retail and an experimental SM 6.11 are on `main`         |
| Targets           | DXIL (`vs/ps/gs/hs/ds/cs/ms/as_6_0`–`6_10`, `lib_6_x`), SPIR-V for Vulkan 1.0–1.3 (`-spirv`), Metal libraries via Apple's converter (`-metal`) |
| Language versions | HLSL 2016, 2018, 2021 (default), 202x; 202y is declared Clang-only                                                                             |
| Successor         | Upstream Clang/LLVM HLSL ([`clang-hlsl.md`][clang-hlsl])                                                                                       |

> **Status:** DXC is still the shipping compiler and the [Clang project calls it "the reference implementation"][clang-support] for modern HLSL, but the language's future is being built in upstream Clang; new C++-base work (HLSL 202y) is explicitly not back-ported. See [Status relative to Clang HLSL](#status-relative-to-clang-hlsl).

---

## Overview

### What it solves

DXC replaced `fxc` (DXBC, SM ≤ 5.1) when Direct3D 12 moved to Shader Model 6. It accepts HLSL and produces a **DXIL container**: LLVM 3.7 bitcode wrapped in a FourCC-chunked container with signatures, a root signature, pipeline-state validation data, reflection and a validator hash. The README sums up the deliverables — `dxc.exe`, `dxcompiler.[dll|so]` "providing a componentized compiler, assembler, disassembler, and validator", and `dxil.[dll|so]` "providing the DXIL validation and hashing support" ([`README.md`][readme]).

The second job is Vulkan. Google contributed a **SPIR-V code generator** that shares DXC's parser and semantic analysis but not its LLVM back end: `-spirv` swaps the code-generation action for an `ASTConsumer` that writes SPIR-V words directly. For years this was the only production path from HLSL to Vulkan, and it remains what the Vulkan SDK ships and what most HLSL-on-Vulkan engines depend on.

### Design philosophy

The DXIL design document states the bet on LLVM directly ([`docs/DXIL.rst`][dxil-rst]):

> _"DXIL is intended to support a direct mapping of the HLSL programming language into Low-Level Virtual Machine Intermediate Representation (LLVM IR), suitable for consumption in GPU drivers. This version of the specification is based on LLVM 3.7 in the use of metadata syntax."_

and its extension rule:

> _"No modifications to the core LLVM IR; i.e., no new instructions or fundamental types. Additional information is conveyed via metadata, LLVM intrinsics or external functions."_

The SPIR-V manual states the opposite emphasis — one front end, two APIs ([`docs/SPIR-V.rst`][spirv-rst]):

> _"DirectXShaderCompiler is the reference compiler for HLSL. Adding SPIR-V codegen in DirectXShaderCompiler will enable the usage of HLSL as a frontend language for Vulkan shader programming. Sharing the same code base also means we can track the evolution of HLSL more closely and always deliver the best of HLSL to developers."_

and closes the semantic gap by preferring "native language constructs when possible", then `[[vk::…]]` attributes, then new syntax. That ordering — native construct, then attribute, then new syntax — is the same one a D design faces between plain D, UDAs and compiler intrinsics.

---

## How it works

### The DXIL path

1. **Front end.** The 3.7-era Clang, modified for HLSL (`docs/HLSLChanges.rst`), parses and type-checks. HLSL built-in types and templates come from an `ExternalSemaSource`, a design Clang HLSL later copied ([`HLSLSupport.md`][clang-support]).
2. **High-level IR.** CodeGen emits an HLSL-flavoured LLVM IR (`HL*` operations, matrices as opaque calls). Passes in `lib/HLSL/` lower it: [`HLMatrixLowerPass.cpp`][hlmatrix] removes matrices, [`DxilGenerationPass.cpp`][dxilgen] builds DXIL operations and signatures.
3. **DXIL.** The document lists the lowering duties: "inline functions", "allocate and transform shader signatures", "lower matrices", "linearize multi-dimensional arrays and user-defined type accesses", and "scalarize vectors". DXIL "has level of abstraction similar to a 'scalarized' DXBC" ([`DXIL.rst`][dxil-rst]); SM 6.9 added native vector operations for long vectors.
4. **Operations as external functions.** Anything outside core LLVM IR is a call to `dx.op.*` whose first argument is a dense `i32` opcode. The core table runs to opcode `344` (`IsDebuggingEnabled`), generated from one Python database, [`utils/hct/hctdb.py`][hctdb], into the C++ headers and the RST tables.
5. **Container and validation.** [`DxilContainer.h`][container] defines the parts: `DXIL` (bitcode), `ISG1`/`OSG1`/`PSG1` (signatures), `RTS0` (root signature), `PSV0` (pipeline state validation), `RDAT` (runtime data), `HASH`, `ILDB`/`ILDN` (debug), `STAT` (shader statistics, used for reflection). The validator (`lib/DxilValidation/`) checks the module against the shader model's rules and embeds the hash that the D3D runtime checks.

Signature access is scalar and goes through intrinsics, not variables:

```llvm
; docs/DXIL.rst — "Accessing signature value in operations"
declare float @dx.op.loadInput.f32(
    i32,   ; opcode
    i32,   ; input ID
    i32,   ; row (relative to start row of input ID)
    i8,    ; column, constant in [0,3]
    i32)   ; vertex index
```

The validator-hash scheme is acknowledged as weak: the hash "acts as a weak form of tamper verification", the algorithm "has been published by other entities", and users bypass validation to link DXC statically or to compile on non-Windows hosts, where "DXC still has no official release for macOS" ([INF-0004][inf-0004]).

### The SPIR-V path

`EmitSpirvAction` returns a `spirv::SpirvEmitter`, which is a Clang `ASTConsumer` ([`EmitSpirvAction.cpp`][emitaction], [`SpirvEmitter.h`][emitter-h]). No LLVM IR is involved:

1. **AST walk.** `SpirvEmitter` ([`SpirvEmitter.cpp`][emitter], ~18,000 lines) visits the AST and builds an in-memory SPIR-V module of `SpirvInstruction` objects through `SpirvBuilder`. `DeclResultIdMapper` ([`DeclResultIdMapper.cpp`][declmapper]) owns stage variables, resources, bindings and locations.
2. **Visitor passes.** `SpirvBuilder::takeModule` runs a fixed visitor sequence over that module ([`SpirvBuilder.cpp`][builder]): `LiteralTypeVisitor`, `NonUniformVisitor`, `LowerTypeVisitor` (AST types to SPIR-V types, layout via [`AlignmentSizeCalculator.cpp`][align]), debug-type visitors, `CapabilityVisitor`, `RelaxedPrecisionVisitor`, `PreciseVisitor`, `RemoveBufferBlockVisitor`, then `EmitVisitor` (binary words).
3. **SPIRV-Tools.** The emitter then calls `spirvToolsLegalize` (`RegisterLegalizationPasses`), `spirvToolsOptimize` (`RegisterPerformancePasses`, the `spirv-opt -O` recipe), a trim-capabilities pass, and `spirvToolsValidate`; a validation failure is a fatal "generated SPIR-V is invalid" error ([`SpirvEmitter.cpp`][emitter]).

The legalization step is the architectural keystone. The manual explains why ([`SPIR-V.rst` § Legalization][spirv-rst]):

> _"HLSL is a fairly permissive language considering the flexibility it provides for manipulating resource objects. The developer can create local copies, pass them around as function parameters and return values … if we translate into SPIR-V for Vulkan literally from the input HLSL source code, we will sometimes generate illegal SPIR-V. … Performing such transformations at the frontend AST level is cumbersome or impossible (e.g., function inlining). They are better to be conducted at SPIR-V level. Therefore, legalization is delegated to SPIRV-Tools."_

The patterns that trigger it are resources inside structs, aliases of global resources, and control flow over either; `-fspv-flatten-resource-arrays`, combined image samplers and signature packing also force it. [`SPIRV-Cookbook.rst`][cookbook] catalogues which aliasing patterns legalize.

---

## Execution model and stages

`SpirvEmitter::getSpirvShaderStage` maps every HLSL stage ([`SpirvEmitter.cpp`][emitter]):

| HLSL profile / kind                                             | SPIR-V execution model                                                                                    |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `vs`, `ps`, `cs`                                                | `Vertex`, `Fragment`, `GLCompute`                                                                         |
| `hs`, `ds`                                                      | `TessellationControl`, `TessellationEvaluation`                                                           |
| `gs`                                                            | `Geometry`                                                                                                |
| `ms`, `as`                                                      | `MeshEXT`/`TaskEXT` (or `MeshNV`/`TaskNV` without `SPV_EXT_mesh_shader`)                                  |
| raygeneration, intersection, anyhit, closesthit, miss, callable | `RayGenerationNV` … `CallableNV` (numerically equal to the KHR enumerants)                                |
| `node` (work graphs)                                            | `GLCompute` plus `*AMDX` execution modes (`CoalescingAMDX`, `ShaderIndexAMDX`, `MaxNodeRecursionAMDX`, …) |

So the SPIR-V path covers **every stage DXIL covers**, including work graphs via AMD's provisional `SPV_AMDX_shader_enqueue` ("AMD work graphs extension", `v1.9.2602` notes). That is the gap against LLVM's SPIR-V back end, which lowers only `compute`, `vertex` and `pixel` ([`clang-hlsl.md`][clang-hlsl]).

Stage-specific attributes become execution modes: hull `domain`/`partitioning`/`outputtopology`/`outputcontrolpoints` → `Triangles`/`SpacingEqual`/`VertexOrderCw`/`OutputVertices`; `partitioning("pow2")` is rejected; geometry `maxvertexcount` → `OutputVertices`, `instance` → `Invocations`, `PointStream`/`LineStream`/`TriangleStream` → `OutputPoints`/`OutputLineStrip`/`OutputTriangleStrip`. The hull wrapper calls the control-point function, issues an `OpControlBarrier`, and then only the invocation with `InvocationID` 0 calls the patch-constant function, whose `SV_TessFactor`/`SV_InsideTessFactor` outputs become `TessLevelOuter`/`TessLevelInner`. `[WaveOpsIncludeHelperLanes]` adds `SPV_KHR_maximal_reconvergence` and `SPV_KHR_quad_control` with the `MaximallyReconvergesKHR` and `RequireFullQuadsKHR` modes ([`SPIR-V.rst`][spirv-rst]).

### The entry-function wrapper

Vulkan entry points are `void(void)`; HLSL entry points take and return values. DXC renames the source function `src.main` and synthesises a wrapper `main` that loads `Input` variables, composes the parameter structs, calls `src.main`, and decomposes the return into `Output` variables:

```text
; docs/SPIR-V.rst — entry function wrapper (abridged)
%main     = OpFunction %void None ...
%inA      = OpLoad %bool %in_var_A
%inS      = OpCompositeConstruct %S %inA %inB %inC
%inT      = OpCompositeConstruct %T %inS %inD
            OpStore %param_var_input %inT
%ret      = OpFunctionCall %T %src_main %param_var_input
%outA     = OpCompositeExtract %bool %outS 0
            OpStore %out_var_A %outA
```

Flattening is "infective": a struct split into several `Location`s in one stage must be split identically in the next, and because hull/domain/geometry are optional, DXC flattens **every** stage interface. Ordinary function parameters are passed as `Function`-storage pointers to caller-allocated copies, giving "unified handling of function parameters and local variables" at the cost of load/store noise that `spirv-opt` must clean up.

## Type system and generic programming

DXC implements HLSL 2021 (templates, operator overloading, bitfields, strict casts) and much of 202x. The `v1.9.2609`-line `main` adds variadic templates, `auto` return types, `static_assert`, `const` methods, removal of `interface`, `shared`/`uniform` and effects syntax ([`ReleaseNotes.md`][relnotes]). Templates are instantiated before code generation; neither back end sees generics.

SPIR-V type mapping ([`SPIR-V.rst` § HLSL Types][spirv-rst]):

- Scalars map directly; `min16float`/`min16int` become 32-bit types with `RelaxedPrecision`, or true 16-bit types under `-enable-16bit-types` (`Float16`/`Int16` capabilities).
- `TN` → `OpTypeVector`; `T1` → scalar.
- **Matrices are transposed.** "Conceptually HLSL matrices are row-major while SPIR-V matrices are column-major, thus all HLSL matrices are represented by their transposes": `float2x3` becomes `OpTypeMatrix %v3float 2`, so `m[i][j]` indexes naturally, `mul(a, b)` swaps operands, and `row_major`/`column_major` become the **opposite** `ColMajor`/`RowMajor` decorations. Non-float matrices become arrays of vectors because the `Shader` capability forbids integer matrices.
- `row_major` on a stand-alone matrix is ignored with a warning: SPIR-V allows `RowMajor`/`ColMajor` only on struct members.

## Resources, interfaces and memory layout

### Buffers and layouts

| HLSL type                                     | Vulkan descriptor | Default layout          | SPIR-V (SPIR-V 1.0 form)                      |
| --------------------------------------------- | ----------------- | ----------------------- | --------------------------------------------- |
| `cbuffer`, `ConstantBuffer<T>`                | uniform buffer    | vector-relaxed `std140` | `Uniform` + `Block`                           |
| `tbuffer`, `TextureBuffer<T>`                 | storage buffer    | vector-relaxed `std430` | `Uniform` + `BufferBlock` + `NonWritable`     |
| `[RW]StructuredBuffer<T>`, `Append`/`Consume` | storage buffer    | vector-relaxed `std430` | struct of `OpTypeRuntimeArray`, `BufferBlock` |
| `[RW]ByteAddressBuffer`                       | storage buffer    | vector-relaxed `std430` | runtime array of `uint`                       |
| `Buffer<T>` / `RWBuffer<T>`                   | texel buffers     | n/a                     | `OpTypeImage` `Dim Buffer`, Sampled 1 / 2     |

`RemoveBufferBlockVisitor` removes `BufferBlock`, which "requires SPIR-V version 1.3 or earlier", moving such buffers to `StorageBuffer` + `Block` on newer targets ([`RemoveBufferBlockVisitor.cpp`][rmbb]). Four layout rule sets exist ([`SPIR-V.rst` § Memory layout rules][spirv-rst]): **vector-relaxed `std140`/`std430`** (default; a vector aligns to its element unless that causes an improper straddle), **DX layout** (`-fvk-use-dx-layout`), **strict GL** (`-fvk-use-gl-layout`) and **scalar** (`-fvk-use-scalar-layout`); DX and scalar need `VK_EXT_scalar_block_layout`. The manual's worked struct places `e_float2x3` at offset 80 / 80 / 96 / 52 in uniform buffers under the four rules — the clearest single demonstration that "layout" is a per-target parameter, not a property of the type. `[[vk::offset(X)]]` overrides `packoffset` and applies to every resource kind, with "no error checking".

Global non-resource variables go into the implicit `$Globals` cbuffer, "no matter whether they are statically referenced by the entry point or not"; its binding is the next free one in set 0 unless `-fvk-bind-globals` places it.

### Bindings: `register` versus `vk::binding`

Binding assignment runs in three passes ([`SPIR-V.rst` § Summary][spirv-rst]):

1. Declarations with `[[vk::binding(X[, Y])]]` take binding `X` in set `Y` (set defaults to 0, or to `-auto-binding-space N`).
2. Declarations with `: register(xX, spaceY)` take binding `X` in set `Y` **regardless of the register class `x`**, shifted per class by `-fvk-{b,s,t,u}-shift N M`. `-fvk-bind-register xX Y N M` replaces the whole scheme with an explicit table.
3. Everything else takes the next free binding in declaration order.

```hlsl
// docs/SPIR-V.rst — compiled with -fvk-t-shift 10 0 -fvk-t-shift 20 1
ConstantBuffer<S> cbuffer1 : register(b0);          // set 0, binding 0
Texture2D<float4> texture1 : register(t0);          // set 0, binding 10
Texture2D<float4> texture2 : register(t1, space1);  // set 1, binding 21
SamplerState      sampler1;                         // set 0, binding 1 (next free)
[[vk::binding(3)]]
RWBuffer<float4> rwbuffer1 : register(u5, space2);  // set 0, binding 3
```

**Counter buffers.** Every `RWStructuredBuffer`/`AppendStructuredBuffer`/`ConsumeStructuredBuffer` that uses its counter gets a second descriptor: a struct holding one 32-bit integer with its own binding (`[[vk::counter_binding(Z)]]`, same set). The pairing is only visible to reflection through `HLSLCounterBufferGOOGLE` under `-fspv-reflect`.

**Bindless.** SM 6.6 `ResourceDescriptorHeap`/`SamplerDescriptorHeap` are emulated by default with one unbounded runtime array per loaded type, all aliased on one binding (requiring `VK_EXT_mutable_descriptor_type`), plus a counter array: "at most 3 bindings", lazily allocated. `-fspv-use-descriptor-heap` instead lowers to `SPV_EXT_descriptor_heap` with `OpUntypedVariableKHR` heaps decorated `ResourceHeapEXT`/`SamplerHeapEXT`, requiring `vulkan1.3`; the unreleased notes extend this to buffer-like resources via `SPV_KHR_untyped_pointers` ([`ReleaseNotes.md`][relnotes]).

### Stage I/O: semantics to `Location` and `BuiltIn`

System-value semantics map to `BuiltIn` decorations per **SigPoint** (the semantic's stage and direction, a DXIL concept): `SV_Position` is `Position` in `VSOut` but `FragCoord` in `PSIn`; `SV_Coverage` is `SampleMask`; `SV_ViewID` is `ViewIndex`; `SV_ShadingRate` is `PrimitiveShadingRateKHR` on output and `ShadingRateKHR` on input. Other semantics get `Location`s, assigned sequentially in declaration order (or alphabetically with `-fvk-stage-io-order=alpha`) after flattening, except that `SV_Target[N]` is always `Location N`. `[[vk::location(X)]]` assigns explicitly; mixing explicit and implicit within one SigPoint is an error. Semantic strings themselves are dropped unless `-fspv-reflect` emits them through `SPV_GOOGLE_hlsl_functionality1`. `-pack-optimized` packs variables into `Component` slots to fit device location limits.

### Vulkan-only constructs

Push constants (`[[vk::push_constant]]`, at most one per entry), specialization constants (`[[vk::constant_id(X)]]` on `bool`/integer/float globals), subpass inputs (`SubpassInput<T>`, `[[vk::input_attachment_index(i)]]`), shader-record buffers (`[[vk::shader_record_ext]]`), combined image samplers (`[[vk::combinedImageSampler]]`, and since `v1.10.2605` a real `vk::SampledTexture` type — "GLSL's `samplerND` equivalent"), buffer device addresses (`vk::RawBufferLoad`/`RawBufferStore`, and the typed `vk::BufferPointer<T>` of [proposal 0010][p0010]) and extra builtins via `[[vk::builtin("PointSize")]]` etc.

## Built-in library and intrinsics

Intrinsics map in three ways ([`SPIR-V.rst` § Intrinsic functions][spirv-rst]): straight to an opcode (`countbits` → `OpBitCount`, `CheckAccessFullyMapped` → `OpImageSparseTexelsResident`), to a `GLSL.std.450` extended instruction (`trunc` → `Trunc`, `lerp` → `FMix`), or by expansion (`dot` on integers as `OpIMul`+`OpIAdd`, `isfinite` from `OpIsNan`/`OpIsInf` because `OpIsFinite` is `Kernel`-only, `lit`, `dst`, `D3DCOLORtoUBYTE4`). Wave intrinsics become `OpGroupNonUniform*` with `Reduce`/`ExclusiveScan` group operations; `WaveMultiPrefix*` uses `PartitionedExclusiveScanNV`. All 39 `RayQuery` methods map one-to-one to `OpRayQuery*KHR`.

**Vulkan extensions without compiler changes.** Inline SPIR-V attributes — `[[vk::ext_instruction(op, set)]]`, `vk::ext_type_def`, `vk::ext_decorate`, `vk::ext_capability`, `vk::ext_extension`, `vk::ext_execution_mode`, `vk::ext_storage_class`, `vk::ext_literal`, `vk::ext_reference` (`VKInstructionExt` … `VKReferenceExt` in [`Attr.td`][attr]) — let a header declare a new instruction. DXC ships one: [`vk/khr/cooperative_matrix.h`][coopmat] implements `vk::khr::CooperativeMatrix<ComponentType, Scope, rows, columns, Use>` as a template whose methods are inline-SPIR-V declarations over [`vk/spirv.h`][vk-spirv]. [Proposal 0011][p0011] gives the motivation: "If those extensions could be defined as a header file that DXC consumes, then a vendor would not have to modify the compiler."

**Unsupported on SPIR-V**: `abort()`, `GetRenderTargetSampleCount/Position()`, `GatherCmpGreen/Blue/Alpha` (`OpImageDrefGather` takes no component), `Load` with a `status` out-argument on structured/byte-address buffers, `tex*()` legacy intrinsics, and cbuffer member initializers.

## Control flow, memory model and restrictions

DXIL and SPIR-V take **opposite positions on structure**. DXIL requires only a reducible CFG: "DXIL does not preserve structured control flow of DXBC. Preserving structured control-flow property would impose significant burden on third-party tools optimizing to DXIL via LLVM" ([`DXIL.rst`][dxil-rst]). DXIL also forbids recursion (validator-enforced), uses 32-bit pointers, and keeps DXBC's resource out-of-bounds rule ("Loads return 0 for OOB accesses; OOB stores are silently dropped") while ordinary pointer OOB is undefined.

The SPIR-V emitter never has to recover structure: it walks the AST, so every `for`/`while`/`do` becomes an `OpLoopMerge` construct and `if`/`switch` a selection construct at emission time. `[unroll(x)]` → `Unroll`, `[loop]`/`[fastopt]` → `DontUnroll`; `switch` becomes `OpSwitch` only for integer-literal cases without `flatten`/`branch`/`call`, else an `if` chain. `clip`/`discard` lower to `OpKill`, or `OpDemoteToHelperInvocation` where available.

Memory model: barriers map to `OpControlBarrier`/`OpMemoryBarrier` with scope and semantics per intrinsic (`GroupMemoryBarrier` = `Workgroup` scope, `Workgroup` + `AcquireRelease` semantics). `UpgradeToVulkanMemoryModelIfNeeded` switches modules to `SPV_KHR_vulkan_memory_model` when a feature requires it. Floating-point control: `-Gis` adds `SignedZeroInfNanPreserve`; a denormal option adds `DenormPreserve` or `DenormFlushToZero` ([`SpirvEmitter.cpp`][emitter]).

## Compilation pipeline and targets

```text
HLSL ─► Clang 3.7 fork (Parse/Sema, HLSL ExternalSemaSource)
         ├─ CodeGen ─► HL IR ─► lib/HLSL passes ─► DXIL ─► validator + hash ─► DXIL container
         └─ -spirv: SpirvEmitter (ASTConsumer) ─► visitors ─► SPIRV-Tools legalize/opt/val ─► .spv
                   └─ -metal: DXIL ─► Metal Shader Converter ─► metallib (source builds only)
```

- **Target environments**: `FeatureManager.cpp` accepts `vulkan1.0`, `vulkan1.1`, `vulkan1.1spirv1.4`, `vulkan1.2`, `vulkan1.3` and `universal1.5`; default `vulkan1.0` ([`FeatureManager.cpp`][featuremgr]). There is no `vulkan1.4`. The manual's option list still says "The current valid options are `vulkan1.0` and `vulkan1.1`" — stale documentation.
- **Extensions**: chosen automatically, or restricted by `-fspv-extension=` (with `KHR` allowing all KHR); 35 listed, from `SPV_KHR_16bit_storage` to `SPV_EXT_descriptor_heap`. `__spirv__`, `__SPIRV_MAJOR_VERSION__` and `__SPIRV_MINOR_VERSION__` let source branch per target.
- **Optimization**: `-O1`..`-O3` all run `spirv-opt -O`; `-Oconfig=` takes an arbitrary pass list; `-fcgl` skips legalization and optimization.
- **Debug info**: `-Zi` embeds preprocessed source and `OpLine` (compiling twice); `-fspv-debug=vulkan-with-source` emits `NonSemantic.Shader.DebugInfo.100` for RenderDoc.
- **Coordinate fix-ups**: `-fvk-invert-y` negates `SV_Position.y`; `-fvk-use-dx-position-w` reciprocates `SV_Position.w` in pixel shaders.

### Status relative to Clang HLSL

Clang's stated goal is "to enable Clang to function as a replacement for the DirectXShaderCompiler (DXC) in all its supported use cases", with explicit non-goals: "HLSL ASTs do not need to be compatible between DXC and Clang. We do not expect identical code generation" ([`HLSLSupport.md`][clang-support]). Clang targets "language compatibility for HLSL 2021 as implemented by DXC" and is written against the draft specification rather than DXC ([`ExpectedDifferences.md`][clang-diff]). HLSL 202y's C++11 base is "proposed as a Clang-only HLSL 202y feature" because restoring C++11 in DXC's modified Clang 3.7 "would be non-trivial" ([proposal 0023][p0023]). DXC still receives new shader models (SM 6.10 retail and SM 6.11 experimental on `main`) and active SPIR-V work (descriptor heaps on 2026-10-15). It is not frozen.

> [!NOTE]
> No in-tree statement fixes a date when DXC stops taking features; the "DXC for maintenance, Clang for the future" framing is inferred from Clang-only proposals such as 0023, not quoted from a policy document.

## Host integration and CPU execution

Host integration is a COM-style library API (`IDxcCompiler3`, `IDxcUtils`, `IDxcValidator`, the `dxcapi.h` family) plus reflection: `ID3D12ShaderReflection` reads reflection data that DXC stores in the DXIL container's parts (the exact part layout was not verified for this survey). For SPIR-V there is no reflection object — the manual tells users to reflect on decorations, warns that `OpName`/`OpMemberName` "are subject to changes without notice", and offers `-fspv-reflect` (`UserTypeGOOGLE`, `HLSLSemanticGOOGLE`, `HLSLCounterBufferGOOGLE`) so that tools such as SPIRV-Reflect can recover HLSL types, semantics and counter pairings.

DXC has **no CPU execution path**: no host target, no interpreter, no reference implementation of intrinsics. Testing is by FileCheck on emitted DXIL/SPIR-V (`tools/clang/test/CodeGenSPIRV/` and friends), `spirv-val`, and the DXIL validator; behavioural testing needs a GPU or WARP (the D3D12 software rasterizer). That absence is a finding: an HLSL author cannot unit-test a shader on the CPU without re-implementing it.

---

## Lessons for sparkles:shaders

- **Adopt: decide structure at emission, not after.** DXC's SPIR-V path never runs a structurizer because it emits `OpLoopMerge`/`OpSelectionMerge` from the AST. LLVM's SPIR-V back end must recover structure from optimized IR, the top risk recorded for `sparkles:shaders`. A golden-SPIR-V corpus should include loops with `break`, `continue` and early `return`, checked by `spirv-val` and by `spirv-cross` round-trip, because that is where the two designs differ.
- **Match: layout is a per-target parameter.** Offer `std140`, `std430`, scalar and DX layouts as CTFE layout policies on one `Vector`/struct vocabulary, and `static assert` the offsets of DXC's worked `T` struct (80 / 80 / 96 / 52 for `e_float2x3`) as conformance fixtures.
- **Match: binding precedence.** Explicit UDA (`@binding(b, set)`) wins over any derived assignment, which wins over next-free-in-declaration-order. Make the fallback deterministic and documented (DXC's depends on declaration order, so moving a global moves `$Globals`). Report collisions at compile time instead of copying DXC's silent register-class overlap.
- **Avoid: an implicit `$Globals` block.** DXC gathers every module-level non-resource variable into a uniform buffer, referenced or not. `sparkles:shaders` already bans module globals (`SHF2` uses explicit `@uniform` parameters); keep uniform data explicit and typed.
- **Adopt: vendor extensions as library code.** DXC's `vk::khr::CooperativeMatrix` is a header over `vk::ext_instruction`. A D equivalent (a `@spirvInstruction(opcode)` UDA or `pragma` lowered to an inline-SPIR-V intrinsic) would let new SPIR-V extensions land in `libs/shaders` without forking LDC again.
- **Match: the wrapper-entry convention.** Synthesising a `void()` wrapper that loads inputs, calls the user function and stores outputs keeps the user function an ordinary callable — exactly what `SHF1` requires ("The D function itself remains callable from other device code"). Flatten struct parameters to one `Location` per leaf, identically in every stage.
- **Avoid: transposed matrix semantics leaking into the API.** DXC's row-major-over-column-major transposition and inverted `RowMajor`/`ColMajor` decorations are a lasting source of bugs. Pick one storage convention for the D `Matrix` and make host and device agree on it by construction.
- **Adopt: validate every artifact.** DXC treats a `spirv-val` failure as a fatal compiler bug; `sparkles:shaders` should keep validation mandatory (the build step's validation run, [`SPEC.md` § 7][spec]) and add the opposite fixture: a test that a known-invalid module is rejected.

## Strengths

- **Complete stage coverage on SPIR-V**: every HLSL stage including tessellation, geometry, mesh/task, ray tracing and AMDX work-graph nodes — ahead of every LLVM-based HLSL path.
- **Best-documented HLSL→SPIR-V mapping in existence**: `SPIR-V.rst` (4,540 lines) specifies types, layouts, bindings, builtins, intrinsics and unsupported features.
- **Mature binding controls**: `vk::binding`, register shifts, explicit register tables, heap bindings, counter bindings.
- **Extensibility without compiler changes** via inline-SPIR-V attributes and header libraries.
- **Validation everywhere**: DXIL validator and `spirv-val` both gate output.
- **Single-database opcodes** (`hctdb.py`) keep headers, docs and validator in sync.

## Weaknesses

- **Frozen on LLVM/Clang 3.7**: no modern C++ base, a growing gap with upstream, and the language's future moving to Clang.
- **Two back ends with divergent semantics**: DXIL and SPIR-V lower the same AST through unrelated code; behaviour (layouts, matrices, `$Globals` bindings) differs by flag.
- **SPIR-V legality depends on SPIRV-Tools legalization**: what compiles depends on optimizer power; `-fcgl` output can be invalid.
- **Weak tamper check and painful portability**: unpublished-MD5 hash, no official macOS release ([INF-0004][inf-0004]).
- **Stale SPIR-V documentation in places** (target environment list), no Vulkan 1.4 environment.
- **No CPU execution or reference semantics**.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                         | Trade-off                                                                         |
| --------------------------------------------------------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| DXIL = LLVM 3.7 bitcode subset, no new IR constructs      | Reuse LLVM tools; lower entry cost for other front ends           | Driver compilers pinned to 3.7 bitcode; DXC stuck on a 3.7 fork                   |
| Operations as `dx.op.*` calls with a dense opcode         | Fewer overloads, array-indexed property lookup                    | Opaque to generic LLVM passes; every new op needs validator and driver support    |
| Unstructured, reducible CFG in DXIL                       | Let LLVM optimize freely                                          | Drivers re-derive structure; contrasts with SPIR-V's requirement                  |
| SPIR-V from the AST, not from LLVM IR                     | Structured control flow and Vulkan types are natural at AST level | A second back end that must re-implement every HLSL feature                       |
| Delegate legalization to SPIRV-Tools                      | Inlining and copy elimination are impractical on the AST          | Legality depends on optimizer success; failures are "file a bug" errors           |
| Transpose matrices into SPIR-V                            | Natural `m[i][j]` indexing                                        | Operand swaps and inverted majorness decorations                                  |
| `register` → binding ignoring register class, with shifts | Compile unmodified D3D HLSL for Vulkan                            | Silent collisions unless shifts are configured                                    |
| Inline-SPIR-V attributes and header libraries             | Vendors add extensions without compiler changes                   | Type checking and diagnostics only as good as the header author's declarations    |
| Validator-embedded hash checked by the runtime            | Tamper evidence for validated DXIL                                | Weak security, bypassed in practice; blocks static linking and cross-platform use |

---

## Sources

- [microsoft/DirectXShaderCompiler — repository][repo] (pinned `194bb75bea2becb42810d72a16195089c1908e10`)
- [`README.md` — components, goals, SPIR-V and Metal codegen][readme]
- [`docs/SPIR-V.rst` — HLSL to SPIR-V feature mapping manual][spirv-rst]
- [`docs/SPIRV-Cookbook.rst` — legalizable resource patterns][cookbook]
- [`docs/DXIL.rst` — DXIL design and opcode tables][dxil-rst]
- [`docs/ReleaseNotes.md` — release history to `v1.9.2609` and `main`][relnotes]
- [`include/dxc/DxilContainer/DxilContainer.h` — container parts][container]
- [`utils/hct/hctdb.py` — DXIL instruction database][hctdb]
- [`lib/HLSL/HLMatrixLowerPass.cpp`][hlmatrix] · [`lib/HLSL/DxilGenerationPass.cpp`][dxilgen]
- [`tools/clang/lib/SPIRV/EmitSpirvAction.cpp`][emitaction] · [`SpirvEmitter.h`][emitter-h] · [`SpirvEmitter.cpp`][emitter] · [`SpirvBuilder.cpp`][builder] · [`DeclResultIdMapper.cpp`][declmapper] · [`AlignmentSizeCalculator.cpp`][align] · [`RemoveBufferBlockVisitor.cpp`][rmbb] · [`FeatureManager.cpp`][featuremgr]
- [`tools/clang/include/clang/Basic/Attr.td` — `vk::` attributes][attr]
- [`tools/clang/lib/Headers/hlsl/vk/spirv.h`][vk-spirv] · [`vk/khr/cooperative_matrix.h`][coopmat]
- [hlsl-specs INF-0004 — validator hashing][inf-0004] · [0010 — `vk::BufferPointer`][p0010] · [0011 — inline SPIR-V][p0011] · [0023 — C++11 base][p0023]
- [Clang `HLSLSupport.md`][clang-support] · [Clang `ExpectedDifferences.md`][clang-diff]
- Related: [HLSL][hlsl] · [Clang HLSL][clang-hlsl] · [LLVM SPIR-V back end][llvm-spirv] · [SPIRV-Cross][spirv-cross] · [Slang][slang] · [Concepts][concepts] · [Comparison][comparison] · [`sparkles:shaders` SPEC][spec]

<!-- References -->

[repo]: https://github.com/microsoft/DirectXShaderCompiler/tree/194bb75bea2becb42810d72a16195089c1908e10
[license]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/LICENSE.TXT
[readme]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/README.md
[spirv-rst]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/docs/SPIR-V.rst
[cookbook]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/docs/SPIRV-Cookbook.rst
[dxil-rst]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/docs/DXIL.rst
[relnotes]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/docs/ReleaseNotes.md
[container]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/include/dxc/DxilContainer/DxilContainer.h
[hctdb]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/utils/hct/hctdb.py
[hlmatrix]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/lib/HLSL/HLMatrixLowerPass.cpp
[dxilgen]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/lib/HLSL/DxilGenerationPass.cpp
[emitaction]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/tools/clang/lib/SPIRV/EmitSpirvAction.cpp
[emitter-h]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/tools/clang/lib/SPIRV/SpirvEmitter.h
[emitter]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/tools/clang/lib/SPIRV/SpirvEmitter.cpp
[builder]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/tools/clang/lib/SPIRV/SpirvBuilder.cpp
[declmapper]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/tools/clang/lib/SPIRV/DeclResultIdMapper.cpp
[align]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/tools/clang/lib/SPIRV/AlignmentSizeCalculator.cpp
[rmbb]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/tools/clang/lib/SPIRV/RemoveBufferBlockVisitor.cpp
[featuremgr]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/tools/clang/lib/SPIRV/FeatureManager.cpp
[attr]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/tools/clang/include/clang/Basic/Attr.td
[vk-spirv]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/tools/clang/lib/Headers/hlsl/vk/spirv.h
[coopmat]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/tools/clang/lib/Headers/hlsl/vk/khr/cooperative_matrix.h
[inf-0004]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/infra/INF-0004-validator-hashing.md
[p0010]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0010-vk-buffer-ref.md
[p0011]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0011-inline-spirv.md
[p0023]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0023-cxx11-base.md
[clang-support]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/docs/HLSL/HLSLSupport.md
[clang-diff]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/docs/HLSL/ExpectedDifferences.md
[hlsl]: ./hlsl.md
[clang-hlsl]: ./clang-hlsl.md
[llvm-spirv]: ./llvm-spirv-backend.md
[spirv-cross]: ./spirv-cross.md
[slang]: ./slang.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[spec]: ../../specs/shaders/SPEC.md
