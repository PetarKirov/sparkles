# HLSL (Microsoft / DirectX)

The C++-derived shading language of Direct3D, versioned twice over — by language edition (HLSL 2021, 202x, 202y) and by Shader Model (6.0 through 6.10) — and, through DXC's and Clang's SPIR-V paths, the most widely used source language for Vulkan as well.

| Field          | Value                                                                                                                                                                                                                        |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | HLSL; reference implementations FXC (D3D9–D3D11, DXBC) and [DXC][dxc-doc] (D3D12, DXIL and SPIR-V); [upstream Clang][clang-doc] in progress                                                                                  |
| License        | Specifications: [`microsoft/hlsl-specs`][specs-repo] (MIT); DXC: University of Illinois/NCSA (LLVM release licence)                                                                                                          |
| Repository     | [microsoft/hlsl-specs][specs-repo] (proposals + draft spec) · [microsoft/DirectX-Specs][dxspecs-repo] (shader-model and API specs)                                                                                           |
| Documentation  | [Draft language specification][spec-html] · [proposal index][proposals] · [Shader Model 6.9 spec][sm69]                                                                                                                      |
| Category       | Language (source); the reference language for DXIL, a major source language for SPIR-V                                                                                                                                       |
| Latest version | Shader Model 6.9 retail (DXC [`v1.9.2602`][dxc-notes], 2026-02-20); SM 6.10 preview in DXC `v1.10.2605` (2026-04-21), retail on DXC `main` [unreleased at the pin][dxc-notes]; language default HLSL 2021, `-HV 202x` opt-in |
| Targets        | DXIL (D3D12), DXBC (FXC), SPIR-V (Vulkan, via DXC `-spirv` or Clang); MSL via Metal Shader Converter or spirv-cross                                                                                                          |
| Governance     | Proposal process in `hlsl-specs` ([`docs/Process.md`][process]); language versions bridged between DXC and Clang by [proposal 0020][p0020]                                                                                   |

> **Pins.** `microsoft/hlsl-specs` at `5c1aae7e` (2026-09-24), `microsoft/DirectX-Specs` at `71e431fa` (2026-10-15), `microsoft/DirectXShaderCompiler` at `194bb75b` (2026-10-16). Every proposal status below is the front-matter `status:` at that pin.

---

## Overview

### What it solves

HLSL is the language Direct3D compiles: a per-thread SPMD program, written in a C/C++ dialect, with one entry function per pipeline stage, typed resource objects (`Texture2D`, `RWStructuredBuffer`, `ConstantBuffer`) bound through registers or descriptor heaps, and a growing library of cross-lane (_wave_) operations. Its reach is wider than Windows: DXC's SPIR-V back end made it the dominant way to write Vulkan shaders in engines that also ship on D3D12, and Slang (see [`slang.md`][slang]) starts from HLSL's syntax and library.

Two axes version it. The **Shader Model** (SM) is the capability contract with the driver: each SM adds stages, intrinsics and DXIL operations, and an application targets an SM with a profile such as `cs_6_6`. The **language version** (`-HV 2018`, `2021`, `202x`) controls the front-end dialect — templates, overload rules, deprecations. A feature is usable only when both allow it.

### Design philosophy

The working group's goal statement, from [`docs/DesignConsiderations.md`][design]:

> _"HLSL seeks to be a powerful portable GPU programming language that enables high performance applications to target GPUs across a wide variety of end user devices. HLSL is explicitly not limited to Microsoft hardware and software environments."_

and, on its relationship to C++:

> _"Most HLSL users are C++ users. Acknowledging that certain aspects of C++ don't map efficiently to GPUs (such as `virtual`, RTTI, and exceptions), we should strive for alignment with C++ wherever possible and follow the principle of least astonishment."_

The language has never been specified; the draft specification opens by saying so ([`specs/language/introduction.tex`][spec-intro]):

> _"Despite its popularity and long history HLSL has never had a formal language specification. This document seeks to change that."_

Three consequences shape everything below. First, **the implementation is the definition**: the spec says "bias is leaned toward the language behavior of DXC", and the [memory-model proposal 0050][p0050] admits that the memory and execution model "have never been fully defined", forcing "reliance on Windows device certification for behavior conformance". Second, **non-portable features live in namespaces** — `vk::` for Vulkan-only constructs, `dx::` for D3D-only ones (SER, linear algebra) — so portability is visible in source. Third, **the compiler is migrating**: DXC is a fork of LLVM/Clang 3.7, and [proposal 0020][p0020] defines HLSL 202x as "a bridge between DXC's implementation and Clang's implementation" and 202y as a Clang-only release; 0050 adds that "DirectX moves to SPIRV". See [`dxc.md`][dxc] and [`clang-hlsl.md`][clang-hlsl] for the two compilers.

---

## How it works

### Language versions

| Version   | Compiler      | What it changed                                                                                                                                                                                                                                                                                        |
| --------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 2015–2018 | FXC, DXC      | C-like core; namespaces (2018); `interface`, effects syntax and `uniform` kept for compatibility                                                                                                                                                                                                       |
| **2021**  | DXC (default) | Templates, member operator overloading, bitfields, strict casting of user types, C++ `for` scoping, non-short-circuiting vector logic replaced by `and()`/`or()`/`select()` ([announcement][hlsl2021]); `HLSLVersion.h` keeps `vLatest = v2021` ([source][hlslversion])                                |
| **202x**  | DXC and Clang | Bridge release ([0020][p0020]): conforming literals (0017), loop unroll factor (0022), refined `cbuffer` contexts (0037), restricted unbounded arrays (0042), `groupshared` arguments (0043); removes effects syntax, `interface`, `shared`/`uniform`, `cbuffer` initialisers ([DXC notes][dxc-notes]) |
| **202y**  | Clang only    | C++ overload resolution and object initialisation: `const` member functions (0007), non-member operators (0008), strict initialiser lists (0005), constructors (0032), references (0006, under review), unions (0004), C++11 base (0023)                                                               |

DXC has also taken C++ features that [0020][p0020] and [0023][p0023] assigned to Clang-only 202y: `auto`, `[[nodiscard]]` and `>>` in template arguments (1.9.2607, no version gate stated), and, gated on 202x, variadic templates, `static_assert` and `const` instance methods ("Upcoming Release"); 1.9.2607 also disallows `volatile` ([`docs/ReleaseNotes.md`][dxc-notes]). The release notes also add a `-Whlsl-2026-compat` warning group "for identifying issues with language changes introduced in HLSL 2026", the first public hint at 202x's final name (not otherwise verified).

### Shader models as the capability axis

| SM      | Headline features                                                                                                                                                             | Source                   |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ |
| 6.0     | DXIL; wave intrinsics; quad ops; 64-bit integers                                                                                                                              | [Learn][learn-sm] ¹      |
| 6.1–6.4 | `SV_ViewID`, `SV_Barycentrics` (6.1); native 16-bit types (6.2); DXR 1.0 libraries (6.3); `dot4add_*8packed`, VRS `SV_ShadingRate` (6.4)                                      | [Learn][learn-sm] ¹      |
| 6.5     | DXR 1.1 inline `RayQuery`; sampler feedback; mesh and amplification shaders; `WaveMatch`, `WaveMultiPrefix*`                                                                  | [SM 6.5][sm65]           |
| 6.6     | 64-bit and bitwise-float atomics; `ResourceDescriptorHeap`; `IsHelperLane`; derivatives in compute/mesh/amplification; pack/unpack; `[WaveSize]`; payload access qualifiers   | [SM 6.6][sm66]           |
| 6.7     | Raw gather, `SampleCmpLevel`, programmable offsets, writable MSAA textures; `QuadAny`/`QuadAll`; `[WaveOpsIncludeHelperLanes]`                                                | [SM 6.7][sm67]           |
| 6.8     | Work graphs; expanded comparison sampling; `SV_StartVertexLocation`; `[WaveSize(min,max,pref)]`                                                                               | [SM 6.8][sm68]           |
| 6.9     | Opacity micromaps; SER (`HitObject`, `MaybeReorderThread`); 16-bit `isinf`/`isnan`/`isfinite`, `isnormal`; long vectors; DXIL vectors; 16-bit, wave and int64 become required | [SM 6.9][sm69]           |
| 6.10    | `linalg::Matrix`; `GetGroupWaveIndex`/`Count`; `DebugBreak`; clustered geometry (`ClusterID`); `TriangleObjectPositions`; `[GroupSharedLimit]`                                | [DXC notes][dxc-notes] ² |

¹ SM 6.0–6.4 rows summarise Microsoft Learn; not verified against a pinned source. ² `DirectX-Specs` has no SM 6.10 page at the pin; the row comes from DXC's release notes and proposals [0035][p0035], [0041][p0041], [0045][p0045], [0048][p0048], [0049][p0049]. The same notes say "Removed work graph support from Shader Model 6.10, and DXIL 1.10" — whether that withdraws a planned 6.10 work-graph addition or something broader was not verified.

### A compute shader, end to end

```hlsl
// HLSL 2021, cs_6_6 (DXIL) or -spirv -fspv-target-env=vulkan1.3
struct Params { float scale; uint count; };
ConstantBuffer<Params>        g        : register(b0);
StructuredBuffer<float4>      src      : register(t0);
[[vk::binding(2, 0)]] RWStructuredBuffer<float4> dst : register(u0);
groupshared float4            tile[64];

template <typename T> T sq(T x) { return x * x; }       // HLSL 2021 template

[numthreads(64, 1, 1)]
void main(uint3 tid : SV_DispatchThreadID, uint gi : SV_GroupIndex)
{
    tile[gi] = tid.x < g.count ? src[tid.x] : 0;
    GroupMemoryBarrierWithGroupSync();
    float4 sum = WaveActiveSum(tile[gi]);              // wave reduction
    if (WaveIsFirstLane() && tid.x < g.count)
        dst[tid.x / WaveGetLaneCount()] = sq(sum) * g.scale;
}
```

Everything a single-source D design must reproduce is visible here: an entry attribute with execution-mode arguments (`[numthreads]`), system values bound by semantic (`SV_DispatchThreadID`), resources whose binding lives in an annotation rather than in the type, a per-target override (`[[vk::binding]]` beats `register` on SPIR-V), workgroup memory as a storage qualifier, a barrier, and a convergent cross-lane operation whose result depends on which lanes are active.

---

## Execution model and stages

The draft spec defines the model bottom-up ([`introduction.tex`][spec-intro]): a **lane** is one SPMD element; a **wave** is the group of lanes the hardware executes together, a power of two whose size "var[ies] by hardware architecture"; a **quad** is four adjacent lanes ("Quad operations require four active lanes"); a **threadgroup** is the `[numthreads]` grid; a **dispatch** is the whole launch. Lanes are in one of four states — _active_, _helper_ ("will execute all computations but will not perform writes to buffers"), _inactive_ (unfilled wave slots), and _predicated off_ (diverged) — with `discard` moving a lane to inactive or helper. That four-state machine is exactly what a CPU simulator of wave operations has to model.

Stages, by entry attribute `[shader("…")]` or profile:

| Family        | Stages                                                                                      | Entry-point attributes                                                                                                                                                         |
| ------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Raster        | `vertex`, `hull` + patch-constant function, `domain`, `geometry`, `pixel`                   | `[domain]`, `[partitioning]`, `[outputtopology]`, `[outputcontrolpoints]`, `[patchconstantfunc]`, `[maxvertexcount]`, `[earlydepthstencil]`                                    |
| Compute       | `compute`                                                                                   | `[numthreads(x,y,z)]`, `[WaveSize(n)]` / `[WaveSize(min,max,pref)]` ([0013][p0013]), `[GroupSharedLimit]`                                                                      |
| Mesh pipeline | `amplification`, `mesh` ([spec][mesh])                                                      | `[outputtopology]`, `[numthreads]`; `SetMeshOutputCounts`, `DispatchMesh(x,y,z,payload)`                                                                                       |
| Ray tracing   | `raygeneration`, `intersection`, `anyhit`, `closesthit`, `miss`, `callable` ([DXR][dxr])    | compiled as a library (`lib_6_x`) with subobjects; payload access qualifiers (6.6)                                                                                             |
| Work graphs   | `node` ([spec][workgraphs], [0018][p0018]); mesh nodes ([0019][p0019], under consideration) | `[NodeLaunch("broadcasting"\|"coalescing"\|"thread")]`, `[NodeDispatchGrid]`, `[NodeMaxDispatchGrid]`, `[NodeIsProgramEntry]`, `[NodeMaxRecursionDepth]`, `[NodeShareInputOf]` |

Stage I/O is the **signature**: entry parameters and return values carry semantics — system values (`SV_Position`, `SV_Target[n]`, `SV_DispatchThreadID`, `SV_IsFrontFace`, `SV_Barycentrics`, `SV_ViewID`, …) and user semantics (`TEXCOORD0`) with interpolation modifiers (`linear`, `centroid`, `nointerpolation`, `noperspective`, `sample`). DXIL records the signature for linkage by semantic name; on SPIR-V, DXC and Clang assign `Location`s **sequentially in declaration order**, ignoring the semantic's name and index, unless `[[vk::location(n)]]` says otherwise (Clang behaviour per [`clang-hlsl.md`][clang-hlsl]).

Work graphs (SM 6.8) are the newest model: "a system for GPU based work creation in D3D12" ([`WorkGraphs.md`][workgraphs]) in which node shaders consume typed input records (`DispatchNodeInputRecord<T>`, `GroupNodeInputRecords<T>`, `ThreadNodeInputRecord<T>`) and emit records to other nodes through `NodeOutput<T>`/`NodeOutputArray<T>`, `GetGroupNodeOutputRecords`, `OutputComplete`. They exist only on D3D12; no SPIR-V lowering exists in DXC or Clang.

---

## Type system and generic programming

**Scalars** are `bool`, `int`/`uint` (32-bit), `float`, `double`, `half`, the minimum-precision hints `min16float`/`min16int`/`min16uint`, and, with `-enable-16bit-types` (SM 6.2), `int16_t`/`uint16_t`/`float16_t`; `int64_t`/`uint64_t` since SM 6.0. SM 6.9 makes 16-bit, wave and int64 support mandatory ([0044][p0044]) — but not `double`: "most GPU programmer models are 'fast math' by default". 8-bit integers are [proposal 0055][p0055] (under consideration).

**Vectors and matrices** are templates with shorthand aliases: `vector<T, N>` (`float4`) and `matrix<T, R, C>` (`float4x4`), with swizzles (`.xyzw`, `.rgba`, matrix `._m00_m11`), splats and implicit truncation. **Long vectors** ([0026][p0026], SM 6.9) lift `N` from 4 to 1024, but only through the template spelling and with a restricted footprint:

> _"Long vectors are not permitted in: Resource types other than ByteAddressBuffer or StructuredBuffer. Any part of the shader's signature … Cbuffers or Tbuffers. A ray tracing `Parameter`, `Attributes`, or `Payload` parameter structures. A work graph record."_

Matrices default to `column_major` packing in memory and multiply with `mul(a, b)` (`*` is element-wise); `row_major`/`column_major` qualifiers and `#pragma pack_matrix` change storage, not arithmetic.

**Generic programming** arrived late and is C++-shaped. HLSL 2021 added function and struct templates and member operator overloading; DXC now accepts variadic templates and parameter packs in 202x. There are no concepts: [proposal 0035][p0035] writes its API with C++20 concepts as pseudo-code "to avoid needing SFINAE complications", while the shipping header [`dx/linalg.h`][linalg-h] uses `hlsl::enable_if` and `type_traits` — SFINAE, the very thing the proposal wanted to avoid. HLSL's old `interface` keyword (no dynamic dispatch, rarely used) is **removed** in 202x. There are no pointers outside `vk::BufferPointer`, no references until 202y, no unions, no recursion, no virtual functions and no exceptions.

The `linalg::Matrix` type is the best example of what the type system can now carry — five template parameters, three of them enums that pick hardware behaviour:

```hlsl
// proposals/0035-linalg-matrix.md (abridged)
template <ComponentEnum ComponentTy, SIZE_TYPE M, SIZE_TYPE N,
          MatrixUseEnum Use, MatrixScopeEnum Scope>   // Use: A | B | Accumulator
class Matrix;                                        // Scope: Thread | Wave | ThreadGroup
```

---

## Resources, interfaces and memory layout

**Resource classes.** SRVs (read-only: `Texture1D/2D/3D/Cube[Array]`, `Texture2DMS[Array]`, `Buffer<T>`, `StructuredBuffer<T>`, `ByteAddressBuffer`), UAVs (read-write: `RW…` variants, `AppendStructuredBuffer<T>`/`ConsumeStructuredBuffer<T>` with a hidden counter, `RasterizerOrdered…` views), CBVs (`cbuffer`, `ConstantBuffer<T>`), samplers (`SamplerState`, `SamplerComparisonState`), `RaytracingAccelerationStructure`, and `FeedbackTexture2D[Array]<SAMPLER_FEEDBACK_MIN_MIP | SAMPLER_FEEDBACK_MIP_REGION_USED>` written by `WriteSamplerFeedback*` ([sampler feedback][feedback], D3D-only). Texture and sampler are **separate objects**; Vulkan's combined image-sampler needs either the `[[vk::combinedImageSampler]]` annotation or the newer `vk::SampledTexture*` types ([0034][p0034]), whose motivation notes the annotation "requires a backend pass to pair up textures and samplers which is prone to subtle errors".

**Binding.** Classic binding is `register(t3, space1)` — a register class (`t`/`u`/`b`/`s`), slot and space — resolved against a **root signature** that maps spaces and ranges to descriptor tables, root descriptors or root constants. SM 6.6 added **dynamic resources** ([`HLSL_SM_6_6_DynamicResources.md`][dynres]): any resource can be materialised from a heap index,

```hlsl
Texture2D<float4>   shadow = ResourceDescriptorHeap[texIdx + 1];
RWByteAddressBuffer buf    = ResourceDescriptorHeap[NonUniformResourceIndex(i)];
SamplerState        samp   = SamplerDescriptorHeap[sampIdx];
```

with `NonUniformResourceIndex` required when the index diverges across the wave. On SPIR-V, DXC emulates each heap with descriptor-indexing runtime arrays, one per loaded type, aliased at one binding via `VK_EXT_mutable_descriptor_type` ([`docs/SPIR-V.rst`][dxc-spirv]); `-fspv-use-descriptor-heap` targets `SPV_EXT_descriptor_heap` instead ([notes][dxc-notes]). Vulkan-specific binding is a family of attributes: `[[vk::binding(b, s)]]`, `[[vk::counter_binding]]`, `[[vk::location]]`, `[[vk::push_constant]]`, `[[vk::constant_id]]` (specialisation constants), `[[vk::input_attachment_index]]`, `[[vk::image_format]]`, `[[vk::offset]]`, `[[vk::shader_record_ext]]`, `[[vk::builtin]]`. GPU pointers exist only as `vk::RawBufferLoad/Store` and `vk::BufferPointer<T>` ([0010][p0010], completed), motivated by the observation that raw loads make "the HLSL programmer … compute the physical offsets of the members of a buffer which is error prone".

**Layout.** Constant buffers use the D3D legacy rules, normatively described in [`resources.tex`][spec-res]:

> _"A constant buffer is arranged like an array of 16-byte rows, or 4-component vectors of 32-bit elements. … Aggregate types like arrays and structures are always 16-byte row-aligned. … Individual array elements are always 16-byte row aligned."_

A scalar or vector packs into the current row if it fits without straddling it; `packoffset(c#.x)` places members explicitly. Structured buffers use C-like tight packing. These rules are neither std140 nor std430, so a Vulkan backend must choose: DXC offers `-fvk-use-dx-layout`, `-fvk-use-gl-layout` and `-fvk-use-scalar-layout`; Clang implements only the DX rule (see [`clang-hlsl.md`][clang-hlsl]).

---

## Built-in library and intrinsics

The intrinsic library is large (well over a hundred functions) and flat — free functions overloaded on scalar, vector and matrix types, plus methods on resource objects.

| Group                | Representative members                                                                                                                                                                                                                        |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Math                 | `abs`, `saturate`, `lerp`, `frac`, `rsqrt`, `rcp`, `mad`, `fma`, `sincos`, `frexp`/`ldexp`, `modf`, `smoothstep`, `step`, `isinf`/`isnan`/`isfinite`/`isnormal` (6.9)                                                                         |
| Geometry/matrix      | `dot`, `cross`, `length`, `normalize`, `reflect`, `refract`, `faceforward`, `mul`, `transpose`, `determinant`                                                                                                                                 |
| Bits and packing     | `countbits`, `firstbithigh`/`firstbitlow`, `reversebits`, `asuint`/`asfloat`/`asdouble`, `f32tof16`/`f16tof32`, `pack_u8`/`unpack_s8s16` (6.6), `dot4add_i8packed` (6.4), `msad4`                                                             |
| Sampling (methods)   | `Sample`, `SampleBias`, `SampleLevel`, `SampleGrad`, `SampleCmp`, `SampleCmpLevelZero`, `SampleCmpLevel`/`Bias`/`Grad` (6.7/6.8, [0014][p0014]), `Gather*`, `GatherRaw` (6.7), `Load`, `CalculateLevelOfDetail`, `GetDimensions`              |
| Derivatives          | `ddx`, `ddy`, `ddx_coarse`/`_fine`, `ddy_coarse`/`_fine`, `fwidth`                                                                                                                                                                            |
| Wave                 | `WaveGetLaneCount`/`Index`, `WaveIsFirstLane`, `WaveActiveAnyTrue`/`AllTrue`/`AllEqual`/`Ballot`, `WaveReadLaneAt`/`First`, `WaveActiveSum`/`Product`/`Min`/`Max`/`Bit*`/`CountBits`, `WavePrefix*`, `WaveMatch` and `WaveMultiPrefix*` (6.5) |
| Quad                 | `QuadReadAcrossX`/`Y`/`Diagonal`, `QuadReadLaneAt`, `QuadAny`/`QuadAll` (6.7)                                                                                                                                                                 |
| Atomics and barriers | `Interlocked{Add,And,Or,Xor,Min,Max,Exchange,CompareExchange,CompareStore}` (64-bit in 6.6), `GroupMemoryBarrier[WithGroupSync]`, `DeviceMemoryBarrier…`, `AllMemoryBarrier…`, generalised `Barrier(memoryFlags, semanticFlags)` (6.8)        |
| Pixel/misc           | `clip`, `discard`, `IsHelperLane` (6.6), `EvaluateAttributeAt*`, `GetAttributeAtVertex` (6.1), `DebugBreak`, `dx::IsDebuggingEnabled` (6.10)                                                                                                  |

**Ray tracing.** DXR 1.0 has `TraceRay`, `ReportHit`, `IgnoreHit`, `AcceptHitAndEndSearch`, `CallShader` and system-value functions (`DispatchRaysIndex`, `WorldRayOrigin`, `ObjectToWorld3x4`, …). DXR 1.1 adds `RayQuery<FLAGS>` for inline tracing from any stage. **DXR 1.2** (SM 6.9) adds **Shader Execution Reordering** ([0027][p0027]) — `dx::HitObject` with `HitObject::TraceRay`, `FromRayQuery`, `MakeMiss`, `MakeNop`, `Invoke`, `GetAttributes`, `GetShaderTableIndex`, and `dx::MaybeReorderThread`, whose "minimal allowed implementation is simply a no-op" — and **opacity micromaps** ([0024][p0024]): `RAYTRACING_PIPELINE_FLAG_ALLOW_OPACITY_MICROMAPS`, `RAY_FLAG_FORCE_OMM_2_STATE`, and the `RAYQUERY_FLAG_ALLOW_OPACITY_MICROMAPS` template flag. SM 6.10 adds `ClusterID()` and `TriangleObjectPositions()` on hits, `RayQuery` and `HitObject`.

**Machine learning: wave matrix → cooperative vectors → linear algebra.** The SM 6.8 _wave matrix_ preview ([`HLSL_SM_6_x_WaveMatrix.md`][wavematrix]) never shipped. _Cooperative vectors_ ([0029][p0029], `dx::linalg::MatrixVectorMul` over long vectors and byte-address-buffer matrices) previewed for SM 6.9 and is now `status: Rejected` — "superceded by 0035-linalg-matrix.md"; DXC 1.10.2605 "Removed experimental Cooperative Vector, this has been replaced by LinAlg matrix". [0035][p0035] reframes the whole area: wave, quad and "cooperative" all describe "the way the underlying instructions execute, not necessarily what they do. One big part of this proposal is to take 5 steps back and talk about what they do: linear algebra." Its `dx::linalg::Matrix` (header [`dx/linalg.h`][linalg-h], component types up to FP8 and `BFloat16`) lowers to DXIL on D3D and to `SPV_KHR_cooperative_matrix` where Vulkan can express it; Vulkan users also have `vk::khr::CooperativeMatrix` ([0021][p0021]), implemented **entirely as a header over inline SPIR-V** ([`vk/khr/cooperative_matrix.h`][coopmat-h]).

**Inline SPIR-V.** `vk::ext_instruction`, `vk::ext_type`/`vk::SpirvType`, `vk::ext_decorate`, `vk::ext_capability`, `vk::ext_extension`, `vk::ext_execution_mode`, `vk::ext_builtin_input`/`output` let a header define a new extension's intrinsics without a compiler change. [Proposal 0011][p0011] states the goal: "vendors should be able to write a self-contained header file that users can use without knowing about inline SPIR-V" — because otherwise every vendor extension "generally requires a code change to the compiler that must be maintained".

---

## Control flow, memory model and restrictions

HLSL forbids recursion, function pointers, dynamic allocation and (since 202x) `volatile`; `out`/`inout` parameters are **copy-in/copy-out**, not references, which is why [`groupshared` arguments][p0043] needed a proposal "to allow passing `groupshared` arguments by address". Control flow takes hints: `[unroll(n)]` (a partial-unroll hint in 202x, no longer an iteration cap), `[loop]`, `[branch]`, `[flatten]`, `[fastopt]`, `[allow_uav_condition]`. Numeric control is `precise` (no contraction or reassociation on that value) and a compiler-wide `-Gis`; [proposal 0009][p0009] (under review) wants "a higher level concept of math modes" because `precise` is too coarse.

**The memory and execution model is unspecified.** [0050][p0050] (under consideration) proposes one, starting from `SPV_KHR_maximal_reconvergence` plus DXIL's `switch` behaviour ("tangles are formed by branch target (not selector value)"), and lays out alternatives from "Full Lockstep" downward. Until it lands, wave-op behaviour in divergent code — which lanes participate after a `break`, whether a reduction sees helper lanes (`[WaveOpsIncludeHelperLanes]`, 6.7) — is defined by DXC's codegen and by WHQL conformance tests. Memory scopes are implicit in the barrier name (group / device / all) or explicit in SM 6.8's `Barrier(UAV_MEMORY | GROUP_SHARED_MEMORY | NODE_INPUT_MEMORY, GROUP_SYNC | DEVICE_SCOPE)`; coherence is a resource qualifier (`globallycoherent`, and `reordercoherent` for SER).

Structured control flow is the compiler's problem, not the language's: HLSL source is unstructured C++ (`break`, `continue`, early `return`, `switch` fall-through), and both DXIL and SPIR-V consumers rely on the compiler to keep convergent operations in the right region — Clang does this with LLVM convergence tokens ([`clang-hlsl.md`][clang-hlsl]).

---

## Compilation pipeline and targets

```text
HLSL ─► DXC (Clang 3.7 fork) ─► HL module ─► DXIL (LLVM 3.7 bitcode in a DXBC container) ─► dxil.dll validation/signing ─► D3D12
   │                        └─► SPIR-V emitter (tools/clang/lib/SPIRV) ─► spirv-opt legalisation ─► Vulkan      (see dxc.md)
   └─► Clang (upstream) ─► LLVM IR ─┬─► DirectX backend ─► DXIL                                           (see clang-hlsl.md)
                                     └─► SPIR-V backend  ─► SPIR-V (compute, vertex, pixel only today)
```

- **DXIL** is LLVM 3.7 bitcode with a fixed set of `dx.op.*` calls, carried in a container with signature, root-signature and PSV parts and validated by `dxil.dll`; DXIL 1.9 (SM 6.9) is the first to allow native LLVM vectors in operations ([0030][p0030]).
- **DXC's SPIR-V path** is a separate AST-to-SPIR-V emitter, not an LLVM backend; it reaches every stage including mesh and ray tracing, with layout and binding flags (`-fvk-*`, `-fspv-*`). Details in [`dxc.md`][dxc].
- **Clang** parses all fourteen stage names (`HLSLShader` in [`Attr.td`][attr-td]) but its SPIR-V backend maps only three: `getExecutionModel` returns `GLCompute`, `Vertex` or `Fragment` and otherwise reports "This HLSL entry point is not supported by this backend." ([`SPIRVCallLowering.cpp`][spv-calllowering]). That is the same backend the sparkles LDC fork uses ([`llvm-spirv-backend.md`][llvm-spirv]).
- **Other targets** are reached by translation: Metal Shader Converter consumes DXIL (DXC can emit its reflection JSON with `-Fre`), spirv-cross consumes SPIR-V ([`spirv-cross.md`][spirv-cross]). DirectX itself is looking past shader bytecode: the [MLIR Programs spec][mlir-programs] (v0.12, 2026-07-29) introduces "compute work at a higher level than shader bytecode" for ML graphs.

---

## Host integration and CPU execution

HLSL is not single-source. Host code (C++, C#, Rust) and shader code are separate files; the contract between them is carried by **reflection**: `ID3D12ShaderReflection` over the DXIL container, SPIRV-Reflect over SPIR-V, or hand-mirrored C++ structs whose layout must reproduce the 16-byte-row cbuffer rules. Root signatures can be written in HLSL source (`[RootSignature("…")]`) or built in C++; nothing type-checks one against the other at compile time.

There is **no CPU execution path** in the HLSL toolchain. DXC has no host target; WARP (the D3D software rasteriser) runs DXIL but is a driver, not a way to call a shader function from host code. Testing is end to end through the runtime — the HLK conformance tests that [0044][p0044] extends — and host-side reference implementations, where they exist, are rewrites. This absence is the gap a single-source design fills; Slang's C++ target ([`slang.md`][slang]) and ISPC ([`ispc.md`][ispc]) are the nearest prior art.

---

## Lessons for sparkles:shaders

- **Adopt HLSL's namespace rule for portability.** Non-portable vocabulary goes in a target-named module (`sparkles.shaders.vk`, `sparkles.shaders.dx`) so a portable shader cannot import it by accident; HLSL's `vk::`/`dx::` split is the precedent, and [`DesignConsiderations.md`][design] makes it a core priority.
- **Match the binding model as data, not as types.** A resource's type (`Texture2D!float4`) stays separate from its binding (a UDA such as `@binding(2, set: 0)`), with a per-target override like `[[vk::binding]]` beating `register`. The `ResourceDescriptorHeap` form should map onto a typed heap accessor (`heap.get!(Texture2D!float4)(i)`), with `nonUniform(i)` required for divergent indices — something a D type can make mandatory, where HLSL only warns.
- **Compute layouts at compile time and `static assert` them.** HLSL's cbuffer rules live in prose and in the compiler; host mirrors are hand-written. Sparkles can implement the D3D-legacy, std140, std430 and scalar rules as CTFE functions shared by host and device, and test each against DXC's output for the same struct (`-fvk-use-dx-layout` vs `-fvk-use-gl-layout`) in a conformance corpus.
- **Model the four lane states in the CPU simulator.** The spec's _active / helper / inactive / predicated off_ machine ([`introduction.tex`][spec-intro]) is the specification a scalar-reference wave simulator must implement: helper lanes compute but do not write, inactive lanes contribute nothing to `WaveActiveSum`, quad ops need four active lanes. Test it against `[WaveOpsIncludeHelperLanes]` semantics.
- **Copy the inline-SPIR-V escape hatch.** `vk::ext_instruction`/`vk::SpirvType` let a header define cooperative matrices without compiler work ([`cooperative_matrix.h`][coopmat-h]); an LDC equivalent (a `pragma` or UDA that emits one SPIR-V opcode, plus `target("spirv.Type", …)`) keeps extension coverage a library task.
- **Track linear algebra, not its names.** Wave matrix and cooperative vectors were both withdrawn within two shader models; 0035's `Matrix(ComponentType, M, N, Use, Scope)` is the surviving shape. A D template over the same five parameters, lowered to `SPV_KHR_cooperative_matrix`, is the durable target — keep it out of the stable vocabulary until a second vendor implements it.
- **Avoid copy-in/copy-out ambiguity.** HLSL's `inout` copies; D's `ref` aliases. Sparkles should define entry-point and helper parameter semantics explicitly (D `ref` means aliasing, and is illegal for interface variables) rather than inherit HLSL's surprise.
- **Treat stage reach as an LLVM backend question.** Mesh, ray tracing and tessellation are blocked for Clang-HLSL and for D at the same function; work on `getExecutionModel` is shared upstream work, and DXC's SPIR-V output for those stages is the oracle to test against.

## Strengths

- **The widest feature surface of any shading language**: every D3D12 stage plus mesh, ray tracing with SER and OMM, work graphs, sampler feedback, long vectors and linear algebra.
- **One source for two APIs**: DXC's SPIR-V back end makes HLSL a first-class Vulkan language, with `vk::` attributes and inline SPIR-V covering the gaps.
- **Open, proposal-driven evolution** with recorded status, and an explicit portability rule (namespaced non-portable features).
- **C++ familiarity**: templates, operator overloading and (in 202x/202y) C++ overload and initialisation rules.
- **Bindless done in-language**: `ResourceDescriptorHeap` needs no host-declared layout per resource.

## Weaknesses

- **No formal specification or memory model**; DXC's behaviour and WHQL tests are the definition, and three compilers (FXC, DXC, Clang) disagree.
- **Two version axes** (language and shader model), each with preview, experimental and retail states; features have been previewed and withdrawn (wave matrix, cooperative vectors, the old `interface`).
- **Generic programming without constraints**: templates with SFINAE, no concepts, late-arriving variadics.
- **Layout rules that match no other API**; Vulkan users pick among three layout modes per compile.
- **Not single-source**: host/shader agreement depends on reflection or hand mirroring, and there is no CPU execution path.
- **The successor compiler is incomplete**: Clang's SPIR-V route lowers three stages today.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                       | Trade-off                                                                                       |
| --------------------------------------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Versioned by Shader Model as well as language       | Driver capability contract evolves independently of syntax      | Two axes to target; profiles (`cs_6_6`) multiply build variants                                 |
| Texture and sampler as separate objects             | Matches D3D descriptor model; samplers reusable across textures | Vulkan/GL combined samplers need annotation or new `vk::SampledTexture*` types                  |
| Bindings in annotations (`register`, `vk::binding`) | Same type works under different root signatures and APIs        | Binding errors surface at pipeline creation, not compile time                                   |
| `ResourceDescriptorHeap` bindless (SM 6.6)          | No per-resource layout declaration; scales to large scenes      | Types are unchecked against the heap's contents; SPIR-V needs emulation via mutable descriptors |
| D3D-legacy 16-byte-row cbuffer packing              | Hardware heritage of constant registers                         | Diverges from std140/std430; host mirrors are error-prone                                       |
| Non-portable features in `vk::`/`dx::`              | Portability visible in source                                   | Duplicate APIs (`vk::khr::CooperativeMatrix` vs `dx::linalg::Matrix`)                           |
| Inline SPIR-V attributes and types                  | Vendors ship extensions as headers, no compiler change          | Escapes the type system; validity checked only by `spirv-val`                                   |
| Migrate the compiler to upstream Clang              | Shared LLVM backends for DXIL and SPIR-V; shed the 3.7 fork     | Three implementations during transition; 202x exists to paper over the differences              |

---

## Sources

- [microsoft/hlsl-specs — proposals and draft specification][specs-repo]
- [`specs/language/introduction.tex` — lanes, waves, quads, lane states][spec-intro] · [`specs/language/resources.tex` — cbuffer layout][spec-res]
- [`docs/DesignConsiderations.md` — goal statement and priorities][design] · [`docs/Process.md`][process]
- Proposals: [0009][p0009] · [0010][p0010] · [0011][p0011] · [0013][p0013] · [0014][p0014] · [0018][p0018] · [0019][p0019] · [0020][p0020] · [0021][p0021] · [0023][p0023] · [0024][p0024] · [0026][p0026] · [0027][p0027] · [0029][p0029] · [0030][p0030] · [0034][p0034] · [0035][p0035] · [0041][p0041] · [0043][p0043] · [0044][p0044] · [0045][p0045] · [0048][p0048] · [0049][p0049] · [0050][p0050] · [0055][p0055]
- DirectX-Specs: [SM 6.5][sm65] · [SM 6.6][sm66] · [dynamic resources][dynres] · [SM 6.7][sm67] · [SM 6.8][sm68] · [SM 6.9][sm69] · [wave matrix][wavematrix] · [mesh shaders][mesh] · [DXR][dxr] · [work graphs][workgraphs] · [sampler feedback][feedback] · [MLIR programs][mlir-programs]
- DXC: [`docs/ReleaseNotes.md`][dxc-notes] · [`docs/SPIR-V.rst`][dxc-spirv] · [`HLSLVersion.h`][hlslversion] · [`dx/linalg.h`][linalg-h] · [`vk/khr/cooperative_matrix.h`][coopmat-h]
- LLVM (upstream `27ba4937`): [`clang/include/clang/Basic/Attr.td`][attr-td] · [`SPIRVCallLowering.cpp`][spv-calllowering]
- [Announcing HLSL 2021 (DirectX blog)][hlsl2021] · [Shader models (Microsoft Learn)][learn-sm]
- Related: [DXC][dxc] · [Clang HLSL][clang-hlsl] · [Slang][slang] · [GLSL][glsl] · [LLVM SPIR-V backend][llvm-spirv] · [spirv-cross][spirv-cross] · [ISPC][ispc] · [Concepts][concepts] · [Comparison][comparison] · [Catalog][index] · [`sparkles:shaders` spec][sparkles-spec]

<!-- References -->

[specs-repo]: https://github.com/microsoft/hlsl-specs/tree/5c1aae7ef249efba8a993ca50d69430c379ac1a1
[dxspecs-repo]: https://github.com/microsoft/DirectX-Specs/tree/71e431fa0f713818c6a3a66f49ab0e6732712d15
[spec-html]: https://microsoft.github.io/hlsl-specs/specs/index.html
[proposals]: https://github.com/microsoft/hlsl-specs/tree/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals
[process]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/docs/Process.md
[design]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/docs/DesignConsiderations.md
[spec-intro]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/specs/language/introduction.tex
[spec-res]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/specs/language/resources.tex
[p0009]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0009-math-modes.md
[p0010]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0010-vk-buffer-ref.md
[p0011]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0011-inline-spirv.md
[p0013]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0013-wave-size-range.md
[p0014]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0014-expanded-comparison-sampling.md
[p0018]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0018-work-graphs.md
[p0019]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0019-mesh-nodes.md
[p0020]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0020-hlsl-202x-202y.md
[p0021]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0021-vk-coop-matrix.md
[p0023]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0023-cxx11-base.md
[p0024]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0024-opacity-micromaps.md
[p0026]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0026-hlsl-long-vector-type.md
[p0027]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0027-shader-execution-reordering.md
[p0029]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0029-cooperative-vector.md
[p0030]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0030-dxil-vectors.md
[p0034]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0034-vk-sampled-texture.md
[p0035]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0035-linalg-matrix.md
[p0041]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0041-triangle-object-positions.md
[p0043]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0043-groupshared-arguments.md
[p0044]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0044-sm69-required-features.md
[p0045]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0045-clustered-geometry.md
[p0048]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0048-group-wave-index.md
[p0049]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0049-variable-groupshared-memory.md
[p0050]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0050-mem-and-exec-model.md
[p0055]: https://github.com/microsoft/hlsl-specs/blob/5c1aae7ef249efba8a993ca50d69430c379ac1a1/proposals/0055-8-bit-integers.md
[sm65]: https://github.com/microsoft/DirectX-Specs/blob/71e431fa0f713818c6a3a66f49ab0e6732712d15/d3d/HLSL_ShaderModel6_5.md
[sm66]: https://github.com/microsoft/DirectX-Specs/blob/71e431fa0f713818c6a3a66f49ab0e6732712d15/d3d/HLSL_ShaderModel6_6.md
[dynres]: https://github.com/microsoft/DirectX-Specs/blob/71e431fa0f713818c6a3a66f49ab0e6732712d15/d3d/HLSL_SM_6_6_DynamicResources.md
[sm67]: https://github.com/microsoft/DirectX-Specs/blob/71e431fa0f713818c6a3a66f49ab0e6732712d15/d3d/HLSL_ShaderModel6_7.md
[sm68]: https://github.com/microsoft/DirectX-Specs/blob/71e431fa0f713818c6a3a66f49ab0e6732712d15/d3d/HLSL_ShaderModel6_8.md
[sm69]: https://github.com/microsoft/DirectX-Specs/blob/71e431fa0f713818c6a3a66f49ab0e6732712d15/d3d/HLSL_ShaderModel6_9.md
[wavematrix]: https://github.com/microsoft/DirectX-Specs/blob/71e431fa0f713818c6a3a66f49ab0e6732712d15/d3d/HLSL_SM_6_x_WaveMatrix.md
[mesh]: https://github.com/microsoft/DirectX-Specs/blob/71e431fa0f713818c6a3a66f49ab0e6732712d15/d3d/MeshShader.md
[dxr]: https://github.com/microsoft/DirectX-Specs/blob/71e431fa0f713818c6a3a66f49ab0e6732712d15/d3d/Raytracing.md
[workgraphs]: https://github.com/microsoft/DirectX-Specs/blob/71e431fa0f713818c6a3a66f49ab0e6732712d15/d3d/WorkGraphs.md
[feedback]: https://github.com/microsoft/DirectX-Specs/blob/71e431fa0f713818c6a3a66f49ab0e6732712d15/d3d/SamplerFeedback.md
[mlir-programs]: https://github.com/microsoft/DirectX-Specs/blob/71e431fa0f713818c6a3a66f49ab0e6732712d15/d3d/MlirPrograms.md
[dxc-doc]: https://github.com/microsoft/DirectXShaderCompiler/tree/194bb75bea2becb42810d72a16195089c1908e10
[dxc-notes]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/docs/ReleaseNotes.md
[dxc-spirv]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/docs/SPIR-V.rst
[hlslversion]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/include/dxc/Support/HLSLVersion.h
[linalg-h]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/tools/clang/lib/Headers/hlsl/dx/linalg.h
[coopmat-h]: https://github.com/microsoft/DirectXShaderCompiler/blob/194bb75bea2becb42810d72a16195089c1908e10/tools/clang/lib/Headers/hlsl/vk/khr/cooperative_matrix.h
[clang-doc]: https://clang.llvm.org/docs/HLSL/HLSLSupport.html
[attr-td]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/include/clang/Basic/Attr.td#L5231-L5251
[spv-calllowering]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVCallLowering.cpp#L214-L237
[hlsl2021]: https://devblogs.microsoft.com/directx/announcing-hlsl-2021/
[learn-sm]: https://learn.microsoft.com/en-us/windows/win32/direct3dhlsl/dx-graphics-hlsl-models
[dxc]: ./dxc.md
[clang-hlsl]: ./clang-hlsl.md
[slang]: ./slang.md
[glsl]: ./glsl.md
[llvm-spirv]: ./llvm-spirv-backend.md
[spirv-cross]: ./spirv-cross.md
[ispc]: ./ispc.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[sparkles-spec]: ../../specs/shaders/SPEC.md
