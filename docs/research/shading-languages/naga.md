# naga (Rust / wgpu)

The shader translator and validator inside `wgpu`: a structured, statement-tree IR with SPIR-V, WGSL and GLSL front ends and SPIR-V, WGSL, MSL, HLSL and GLSL back ends — the WGSL route for SPIR-V that SPIRV-Cross does not provide, and the gatekeeper every SPIR-V module handed to `wgpu` (Firefox's WebGPU) must pass.

| Field          | Value                                                                                                                                                          |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | Rust (`#![no_std]`, `#![forbid(unsafe_code)]`; crate MSRV 1.87, workspace 1.95)                                                                                |
| License        | MIT OR Apache-2.0                                                                                                                                              |
| Repository     | [gfx-rs/wgpu][repo] — `naga/` (with `naga-types/`, `naga-cli/`), cited at [`efcf4457`][tree] (2026-10-17)                                                      |
| Documentation  | [`naga/README.md`][readme] · [docs.rs/naga][docsrs] · IR docs in [`naga/src/ir/mod.rs`][ir]                                                                    |
| Category       | Toolchain — source-to-source shader translator and validator                                                                                                   |
| Latest version | Released with wgpu: `v30.0.1` (2026-08-21); workspace version `30.0.0` at the pin ([`CHANGELOG.md`][changelog])                                                |
| Front ends     | SPIR-V binary (`spv-in`, primary), WGSL (`wgsl-in`, primary, _"Fully validated"_), GLSL (`glsl-in`, secondary, _"GLSL 440+ and Vulkan semantics only"_)        |
| Back ends      | SPIR-V, Metal (MSL), HLSL (SM 5.0–6.9) primary; WGSL, GLSL (330–450, ES 300/310) secondary; DOT; **no DXIL, DXBC or AIR**                                      |
| Consumers      | `wgpu` — _"the core of the WebGPU integration in Firefox, Servo, and Deno"_ ([`README.md`][wgpu-readme]); `naga-cli`; rust-gpu users targeting non-Vulkan APIs |

---

## Overview

### What it solves

`wgpu` runs one shader on Vulkan, Metal, D3D12, OpenGL/GLES and WebGPU, and accepts it as
WGSL, SPIR-V or GLSL. naga is the hub: every front end lowers into one `naga::Module`, the
validator proves it well-formed and annotates it (types, uniformity, reference counts), and
each back end writes a target language from the same module. Because it is the shader
compiler of a browser engine, it is built for untrusted input — no `unsafe`, no panics on
malformed modules, bounds-check policies for every memory access.

For `sparkles:shaders`, naga matters twice. It is a second SPIR-V → WGSL/MSL/HLSL/GLSL
translator beside [SPIRV-Cross][spirv-cross] (and the only well-maintained Rust one), and its
IR is the closest existing design to the "one D-native vocabulary, many targets" goal: a
deliberately small, structured IR that every target can express.

### Design philosophy

The README's one line ([`naga/README.md`][readme]): _"The shader translation library for the
needs of [wgpu]."_ The IR documentation ([`naga/src/ir/mod.rs`][ir]) gives the core
discipline:

> _"`Statement`s form a tree, with pointers into the DAG of `Expression`s. Restricting side
> effects to statements simplifies analysis and code generation. A Naga backend can generate
> code to evaluate an `Expression` however and whenever it pleases, as long as it is certain
> to observe the side effects of all previously executed `Statement`s."_

Everything else — no CFG, no PHIs, no pointers to pointers, function calls as statements,
expressions scoped to their block — follows from wanting high-level text back ends to be
simple.

---

## How it works

### The IR

A `Module` ([`ir/mod.rs`][ir]) holds `types` (a `UniqueArena` of `Type`), `constants`,
`overrides`, `global_variables`, `global_expressions`, `functions` and `entry_points`; all
references are typed `Handle`s into arenas. Function bodies are a `Block` (`Vec<Statement>`)
plus an `Arena<Expression>`:

- **`Expression`** — pure values: `Literal`, `Constant`, `Compose`, `Access`/`AccessIndex`,
  `Splat`, `Swizzle`, `Load`, `ImageSample`, `ImageLoad`, `ImageQuery`, `Unary`, `Binary`,
  `Select`, `Derivative`, `Relational`, `Math`, `As`, `CallResult`, `AtomicResult`,
  `SubgroupBallotResult`, ….
- **`Statement`** — effects and structured control: `Emit(range)` (marks when a run of
  expressions is evaluated), `Block`, `If`, `Switch`, `Loop { body, continuing, break_if }`,
  `Break`, `Continue`, `Return`, `Kill`, `ControlBarrier`, `MemoryBarrier`, `Store`,
  `ImageStore`, `Atomic`, `ImageAtomic`, `WorkGroupUniformLoad`, `Call`, `RayQuery`,
  `SubgroupBallot`, `SubgroupGather`, `SubgroupCollectiveOperation`, `CooperativeStore`,
  `DebugPrintf`.

`Loop` is WGSL's shape (body, a `continuing` block, an optional `break_if`); there is no
`for`, `while` or `goto`. Calls are statements so that ordering is explicit.

### The pipeline

```rust
// naga/src/lib.rs doc example (abridged)
let module: naga::Module = naga::front::wgsl::parse_str(wgsl_source)?;
let module_info = naga::valid::Validator::new(
        naga::valid::ValidationFlags::all(),
        naga::valid::Capabilities::all(),
    ).validate(&module)?;
naga::back::glsl::Writer::new(&mut glsl_source, &module, &module_info,
    &glsl::Options::default(), &pipeline_options,
    naga::proc::BoundsCheckPolicies::default())?.write()?;
```

The `Validator` is mandatory: back ends consume its `ModuleInfo` (per-expression types,
reference counts that decide which expressions are "baked" into temporaries, uniformity) and
assume a validated module. `naga::compact` drops unused items; `proc::Layouter` computes size
and alignment; `proc::Namer` produces target-safe identifiers.

---

## Execution model and stages

`ShaderStage` ([`naga-types/src/lib.rs`][naga-types]) has `Vertex`, `Task`, `Mesh`,
`Fragment`, `Compute`, `RayGeneration`, `Miss`, `AnyHit`, `ClosestHit` — no geometry or
tessellation, matching WebGPU and Metal. An `EntryPoint` is a `Function` plus `stage`,
`early_depth_test`, `workgroup_size` (and `workgroup_size_overrides`), `mesh_info` and
payload globals; entry
inputs and outputs are function arguments and results with `Binding::BuiltIn` or
`Binding::Location` (with `Interpolation` and `Sampling`), WGSL style.

The SPIR-V front end maps `Vertex`, `Fragment`, `GLCompute`, `TaskEXT`, `MeshEXT` and rejects
other execution models with `UnsupportedExecutionModel`; it understands the execution modes
`EarlyFragmentTests`, `DepthUnchanged`/`Greater`/`Less`/`Replacing`, `OriginUpperLeft` and
`LocalSize` ([`front/spv/mod.rs`][spv-in]). Input/Output variables become private globals
filled at entry and copied out at return: _"The function associated with an entry point is
wrapped in another function, such that we can handle any `Return` statements without
problems."_ By default the front end also flips `Position.y` (`adjust_coordinate_space`),
because naga's coordinate space follows the non-Vulkan APIs.

## Type system and generic programming

`TypeInner` ([`ir/mod.rs`][ir]) is: `Scalar`, `Vector` (2–4), `Matrix` (column-major only),
`CooperativeMatrix`, `Atomic`, `Pointer { base, space }`, `ValuePointer`,
`Array { base, size, stride }`, `Struct { members, span }` (members with explicit `offset`), `Image`,
`Sampler { comparison }`, `AccelerationStructure`, `RayQuery`, `BindingArray`. Scalars carry
kind and width; abstract integer/float literals exist for WGSL's constant evaluation
(`proc::constant_evaluator`) and are concretised before back ends see them.

There are no generics in the IR. WGSL's built-in overloads are resolved by
`proc::overloads`; GLSL's preprocessor and overloads are handled in `front/glsl`. Row-major
SPIR-V matrices are not representable: the front end detects them in `OpAccessChain` and
generates a transposed load instead. `Override`s carry WGSL `override` / SPIR-V spec
constants to pipeline-creation time, and `back::pipeline_constants` substitutes them.

## Resources, interfaces and memory layout

`AddressSpace` is `Function`, `Private`, `WorkGroup`, `Uniform`, `Storage { access }`,
`Handle` (images, samplers, acceleration structures — globals of this space are values, not
pointers), `Immediate` (push constants), `TaskPayload`, `RayPayload`, `IncomingRayPayload`.
`GlobalVariable` carries an optional `ResourceBinding { group, binding }`.

The SPIR-V front end's storage-class map ([`front/spv/convert.rs`][spv-convert]) accepts
`Function`, `Input`, `Output`, `Private`, `UniformConstant` (⇒ `Handle`), `StorageBuffer`,
`Uniform`, `Workgroup` and `PushConstant` (⇒ `Immediate`); **anything else —
`PhysicalStorageBuffer` included — is `UnsupportedStorageClass`**. Because
`UniformConstant` maps to `Handle`, a non-opaque `UniformConstant` variable (legal for
OpenGL SPIR-V, used for "plain uniforms") has no valid naga representation.

Layout is validated, not inferred: `valid::type` computes each type's uniform and storage
layout and rejects a `Uniform` struct whose offsets violate WGSL's rules (minimum uniform
alignment `Alignment::MIN_UNIFORM = 16`, [`proc/layouter.rs`][layouter]). The HLSL back end's
module comment explains the mismatch it absorbs: _"WGSL's "Internal Layout of Values" rules
specify how each WGSL type should be stored in `uniform` and `storage` buffers. The HLSL we
generate must access values in that form, even when it is not what HLSL would use
normally."_ Storage buffers become `ByteAddressBuffer`s with explicit byte offsets, and
uniform matrices are declared `row_major` with transposed dimensions ([`back/hlsl/mod.rs`][hlsl-out]).

## Built-in library and intrinsics

Built-ins are IR variants, not library calls: `MathFunction` (WGSL/GLSL math including
`Fma`, `Mix`, `SmoothStep`, `Pack4x8snorm`, `Dot4I8Packed`, …), `RelationalFunction`,
`Derivative { axis, ctrl }`, `ImageSample { level: SampleLevel, depth_ref, gather, offset }`,
`ImageQuery`, `AtomicFunction`, `SubgroupOperation`/`CollectiveOperation`,
`RayQueryFunction`. `BuiltIn` covers WGSL's set plus `PrimitiveIndex`, `ViewIndex`,
`BaseInstance`/`BaseVertex`/`DrawIndex`, `ClipDistances`, `CullDistance`, `PointSize`,
`Barycentric`, `SampleIndex`, subgroup ids, mesh and ray-tracing built-ins.

The SPIR-V front end accepts only the capabilities in `SUPPORTED_CAPABILITIES`
([`front/spv/mod.rs`][spv-in]) when `strict_capabilities` is set (the default, and what
`wgpu` uses): `Shader`, `VulkanMemoryModel`, `ClipDistance`, `CullDistance`,
`SampleRateShading`, `DerivativeControl`, `Matrix`, `ImageQuery`, `Sampled1D`/`Image1D`,
`SampledCubeArray`/`ImageCubeArray`, `StorageImageExtendedFormats`, `Int8`, `Int16`,
`Int64`, `Int64Atomics`, `Float16`, `AtomicFloat32AddEXT`, `Float64`, `Geometry`,
`MultiView`, 16-bit storage, `GroupNonUniform{,Vote,Arithmetic,Ballot,Shuffle,ShuffleRelative}`,
`RuntimeDescriptorArray`, `StorageImageMultisample`, `FragmentBarycentricKHR` and two
dynamic-indexing capabilities. Extensions are a closed list of eight
(`SPV_KHR_storage_buffer_storage_class`, `SPV_KHR_vulkan_memory_model`, `SPV_KHR_multiview`,
`SPV_EXT_descriptor_indexing`, `SPV_EXT_shader_atomic_float_add`, `SPV_KHR_16bit_storage`,
`SPV_KHR_non_semantic_info`, `SPV_KHR_fragment_shader_barycentric`); any other is a hard
`UnsupportedExtension`, regardless of `strict_capabilities`.

Not accepted: `PhysicalStorageBufferAddresses`, `VariablePointers`, `Addresses`, `Linkage`,
`Kernel`, `DemoteToHelperInvocation`, `GroupNonUniformQuad`, ray tracing. Of the discard
instructions only `OpKill` is parsed (to `Statement::Kill`); `OpTerminateInvocation` and
`OpDemoteToHelperInvocation` fall through to `UnsupportedInstruction`.

## Control flow, memory model and restrictions

Control flow is structured by construction: `If`, `Switch`, `Loop`, `Break`, `Continue`,
`Return`, `Kill`. The SPIR-V front end rebuilds this tree from merge annotations. Its
`BlockContext` comment ([`front/spv/mod.rs`][spv-in]) explains why it cannot do so in one
pass — SPIR-V blocks may appear in any order consistent with dominance, a SPIR-V value may be
used in any dominated block while naga expressions are block-scoped, and `OpPhi`s become
local variables stored before each branch — so it collects control-flow-free fragments and a
skeleton of bodies, then stitches them after the whole function is read. Unstructured
SPIR-V is rejected (`UnsupportedControlFlow`), and a recursive call is an error
(`"recursive function call"`).

The **uniformity analysis** ([`valid/analyzer.rs`][analyzer]) tracks, per expression, a
`non_uniform_result` and `UniformityRequirements`, and per statement exit flags
(`MAY_RETURN`, `MAY_KILL`: _"Anything after `Statement::Kill` is considered inside
non-uniform context"_). It enforces uniform control flow for workgroup barriers and
cooperative-matrix ops. For derivatives and implicit-LOD sampling it does not:

```rust
// naga/src/valid/analyzer.rs
const DISABLE_UNIFORMITY_REQ_FOR_FRAGMENT_STAGE: bool = true;
// …
        const DERIVATIVE = if DISABLE_UNIFORMITY_REQ_FOR_FRAGMENT_STAGE { 0 } else { 0x2 };
        const IMPLICIT_LEVEL = if DISABLE_UNIFORMITY_REQ_FOR_FRAGMENT_STAGE { 0 } else { 0x4 };
```

So naga accepts WGSL that Tint rejects (a `textureSample` under a non-uniform branch), and
passing naga is not evidence of WGSL-spec uniformity.

**Bounds checks** are a translation policy, `BoundsCheckPolicy` ([`proc/index.rs`][index-rs]):
`Restrict` (clamp to an in-bounds index), `ReadZeroSkipWrite`, or `Unchecked` — _"the default
for Naga, as a translator, but consumers should consider defaulting to a safer behavior"_;
`wgpu` chooses the safe policies. Target workarounds live in the back ends, e.g.
`back::continue_forward` rewrites `continue` inside `switch` for FXC, which rejects it.

## Compilation pipeline and targets

| Back end   | Versions / notes                                                                                                                                 |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `spv-out`  | `lang_version` default `(1, 0)`; writer flags for coordinate adjustment, debug info, `binding_map`; output for Vulkan                            |
| `msl-out`  | MSL with a per-entry resource-binding map (_"Metal's bindings are flat per resource"_); no `SHADER_INT64_ATOMIC_ALL_OPS` ([`back/msl`][msl-out]) |
| `hlsl-out` | `ShaderModel::V5_0` … `V6_9`; WGSL layout reproduced through `ByteAddressBuffer` and `row_major` uniform matrices                                |
| `glsl-out` | Core 330, 400, 410, 420, 430, 450; ES 300, 310 ([`back/glsl/mod.rs`][glsl-out]) — **no GLSL ES 1.00**                                            |
| `wgsl-out` | WGSL text, secondary support                                                                                                                     |
| `dot-out`  | GraphViz of the IR, for debugging                                                                                                                |

There is no DXIL/DXBC/AIR output: D3D12 consumers run the HLSL through DXC or FXC, Metal
compiles MSL at runtime. The xtask validates every snapshot with the target's real tool
(`spirv-val`, `xcrun metal`, `glslang`, DXC, FXC) — naga's own conformance strategy.

## Host integration and CPU execution

naga is a library with a validator, not a runtime. `wgpu` calls it at
`create_shader_module`: WGSL goes through `front::wgsl`, and **SPIR-V goes through
`front::spv` even on the Vulkan backend** ([`wgpu-core/src/device/resource.rs`][wgpu-resource]),
after which `back::spv` re-emits it — so every SPIR-V module given to `wgpu` must fit naga's
capability list. The `PASSTHROUGH_SHADERS` feature ([`wgpu-types/src/features.rs`][features])
skips naga entirely: _"Shader code isn't parsed or interpreted in any way."_ On the web,
`wgpu`'s WebGPU backend parses SPIR-V with `adjust_coordinate_space: false` and
`strict_capabilities: true` and hands the browser `back::wgsl::write_string`'s output
([`wgpu/src/backend/webgpu.rs`][wgpu-webgpu]). There is no CPU execution of naga IR.

---

## Lessons for sparkles:shaders

- **Adopt: statements for effects, expressions for values.** A D-native shader IR (or the
  vocabulary's own semantic model) should follow naga's split — pure expression DAG, a
  statement tree with explicit `Emit` points, calls as statements — because it is what makes
  five text back ends tractable and what a CPU interpreter wants too.
- **Match: naga's SPIR-V subset if `wgpu` is a target.** Treat
  `SUPPORTED_CAPABILITIES`/`SUPPORTED_EXTENSIONS` as a target profile in D: no
  `PhysicalStorageBufferAddresses` (the fork's `spirv.physical-storage-buffer` must stay off
  for such a module), no `OpTerminateInvocation` (emit `OpKill` below 1.6 or avoid
  `discard`), no demote, no non-opaque `UniformConstant`, no `Linkage`.
- **Adopt: a mandatory validator before every back end**, producing reference counts and
  uniformity facts; in sparkles' build step, run `naga` (CLI) over the SPIR-V as a second
  validator beside `spirv-val` when WGSL/MSL output is requested.
- **Avoid: trusting naga for uniformity.** It disables derivative and implicit-LOD
  uniformity requirements; if the vocabulary promises WGSL-valid output, check uniformity on
  the D side (a `Uniform!T` wrapper or an analysis) or validate with Tint.
- **Match: bounds-check policy as an explicit, per-address-space option**, with
  `ReadZeroSkipWrite` semantics reproduced by the CPU simulator, so CPU and GPU agree on
  out-of-bounds behaviour.
- **Adopt: snapshot tests validated by the real downstream tool** (naga's
  `cargo xtask validate`), the pattern sparkles' conformance corpus should use for each target language.

## Strengths

- One small structured IR feeding five text back ends, with no CFG to restructure.
- Memory-safe, panic-averse Rust built for untrusted (browser) input.
- Explicit, documented layout handling for WGSL ↔ HLSL/MSL mismatches.
- Mesh, ray-query, ray-tracing pipeline, subgroup and cooperative-matrix support in the IR.
- Every back end's output is validated by the platform's own compiler in CI.

## Weaknesses

- SPIR-V input is a closed subset: no buffer device addresses, no variable pointers, no
  terminate/demote, a fixed extension list.
- No geometry or tessellation stages; no row-major matrices in the IR.
- GLSL output starts at 330 / ES 300 — no GLSL ES 1.00 (WebGL 1, oldest GLES).
- Derivative uniformity is not enforced, diverging from the WGSL specification.
- No DXIL/AIR; WGSL and GLSL back ends are "secondary support".

## Key design decisions and trade-offs

| Decision                                    | Rationale                                                  | Trade-off                                                                       |
| ------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Statement tree over an expression DAG       | Text back ends emit structured code directly               | SPIR-V input must be re-structured and PHIs spilled to locals                   |
| Arena + typed `Handle` everywhere           | Cheap, `unsafe`-free graph representation; easy compaction | Handle validation is a pass of its own (`valid::handles`)                       |
| Mandatory validation producing `ModuleInfo` | Back ends can assume well-formed input and reuse analyses  | Every consumer pays validation; flags must match the device's real capabilities |
| Closed SPIR-V capability/extension lists    | Only accept what every back end can express                | Valid Vulkan SPIR-V (BDA, demote, 1.6 terminate) is rejected                    |
| Derivative uniformity disabled              | Avoids rejecting real-world shaders                        | Accepts WGSL the spec and Tint reject                                           |
| Bounds checks as a translation-time policy  | One IR, different safety per consumer                      | `Unchecked` default for the library; safety is the embedder's choice            |

## Sources

- [gfx-rs/wgpu at `efcf4457`][tree] — `naga/`
- [`naga/README.md` — supported end-points][readme] · [docs.rs/naga][docsrs] ·
  [`CHANGELOG.md`][changelog] · [wgpu `README.md`][wgpu-readme]
- [`naga/src/lib.rs` — crate docs and pipeline example][lib] · [`naga/src/ir/mod.rs` — the IR][ir] ·
  [`naga-types/src/lib.rs` — `ShaderStage`][naga-types]
- [`naga/src/front/spv/mod.rs` — SPIR-V front end, capability list][spv-in] ·
  [`front/spv/convert.rs` — storage classes][spv-convert]
- [`naga/src/valid/analyzer.rs` — uniformity][analyzer] · [`proc/layouter.rs`][layouter] ·
  [`proc/index.rs` — bounds-check policies][index-rs]
- [`back/hlsl/mod.rs`][hlsl-out] · [`back/msl/mod.rs`][msl-out] · [`back/glsl/mod.rs`][glsl-out]
- [`wgpu-core/src/device/resource.rs` — SPIR-V ingestion][wgpu-resource] ·
  [`wgpu-types/src/features.rs` — passthrough shaders][features]
- Related: [Tint][tint] · [SPIRV-Cross][spirv-cross] · [WGSL][wgsl] · [LLVM SPIR-V backend][llvm-spirv] ·
  [rust-gpu][rust-gpu] · [TypeGPU][typegpu] · [Concepts][concepts] · [Comparison][comparison] ·
  [Index][index] · [`sparkles:shaders` SPEC][spec]

<!-- References -->

[repo]: https://github.com/gfx-rs/wgpu
[tree]: https://github.com/gfx-rs/wgpu/tree/efcf445784dd31537f09bc61bad27431de713fce/naga
[readme]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga/README.md
[docsrs]: https://docs.rs/naga/latest/naga/
[changelog]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/CHANGELOG.md
[wgpu-readme]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/README.md
[lib]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga/src/lib.rs
[ir]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga/src/ir/mod.rs
[naga-types]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga-types/src/lib.rs
[spv-in]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga/src/front/spv/mod.rs
[spv-convert]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga/src/front/spv/convert.rs
[analyzer]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga/src/valid/analyzer.rs
[layouter]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga/src/proc/layouter.rs
[index-rs]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga/src/proc/index.rs
[hlsl-out]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga/src/back/hlsl/mod.rs
[msl-out]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga/src/back/msl/mod.rs
[glsl-out]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga/src/back/glsl/mod.rs
[wgpu-resource]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/wgpu-core/src/device/resource.rs
[features]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/wgpu-types/src/features.rs
[wgpu-webgpu]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/wgpu/src/backend/webgpu.rs
[tint]: ./tint.md
[spirv-cross]: ./spirv-cross.md
[wgsl]: ./wgsl.md
[llvm-spirv]: ./llvm-spirv-backend.md
[rust-gpu]: ./rust-gpu.md
[typegpu]: ./typegpu.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[spec]: ../../specs/shaders/SPEC.md
