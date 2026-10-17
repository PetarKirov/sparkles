# WGSL (W3C / WebGPU)

The shading language of WebGPU: a small, Rust-flavoured, fully specified language whose defining features — a mandatory static uniformity analysis, defined behaviour for out-of-bounds and integer edge cases, and a two-tier `enable`/`requires` extension model — are exactly the portability guarantees GLSL and HLSL leave to the programmer.

| Field          | Value                                                                                                                                                             |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | WGSL (WebGPU Shading Language)                                                                                                                                    |
| License        | W3C Software and Document license; source contributions under the GPU for the Web 3-Clause BSD license ([`LICENSE.md`][license])                                  |
| Repository     | [gpuweb/gpuweb][repo] — the spec source is [`wgsl/index.bs`][spec-src]                                                                                            |
| Documentation  | [W3C Candidate Recommendation Draft][tr] · [Editor's Draft][ed] · [WebGPU CTS `shader/`][cts]                                                                     |
| Category       | Language (source); the only shader language a WebGPU implementation must accept                                                                                   |
| Latest version | W3C Candidate Recommendation Draft, 21 September 2026 ([TR][tr]); Editor's Draft at the pin dated 2026-10-16. WGSL has no version number — growth is by extension |
| Targets        | WebGPU implementations: Tint (Chrome/Dawn), naga (Firefox/wgpu), WebKit's WGSL compiler; each lowers to SPIR-V, HLSL/DXIL, MSL and (Tint, naga) GLSL              |
| Pins           | `gpuweb/gpuweb` at `3c1276a4` (2026-10-16); `google/dawn` at `67d4d6e6`; `gfx-rs/wgpu` (naga) at `efcf4457`                                                       |

---

## Overview

### What it solves

WebGPU must run untrusted shaders from the web on Vulkan, D3D12 and Metal drivers, so its shading language had to be (a) translatable to all three backends' languages, (b) safe — no shader may read memory outside its bindings — and (c) portable — the same program must behave the same on every GPU, or fail to compile everywhere. The introduction states its scope plainly ([`index.bs`][spec-intro]):

> _"WebGPU Shading Language (WGSL) is the shader language for [WebGPU]. That is, an application using the WebGPU API uses WGSL to express the programs, known as shaders, that run on the GPU."_

For `sparkles:shaders`, WGSL is both a **target** (the web, and wgpu-based native applications) and the **strictest validator** in the catalog: a D shader whose SPIR-V passes Tint's or naga's WGSL lowering satisfies a stronger set of rules than GLSL or MSL impose.

### Design philosophy

WGSL is designed to minimise implementation-defined behaviour, and says so ([`index.bs`][spec-overview]):

> _"WGSL sometimes permits several possible behaviors for a given feature. This is a portability hazard, as different implementations may exhibit the different behaviors. The design of WGSL aims to minimize such cases, but is constrained by feasibility, and goals for achieving high performance across a broad range of devices."_

It also makes the author, not the hardware, responsible for convergence — and then checks the author:

> _"The shader author is responsible for ensuring the dynamic behavior of the invocations in a shader stage: Meet the uniformity requirements of certain primitive operations, including texture sampling and control barriers. Coordinate potentially conflicting accesses to shared variables, to avoid data races."_

Three consequences run through the language: errors are moved as early as possible (_shader-creation error_ at module creation, _pipeline-creation error_ when overrides are known); conversions are explicit (_"WGSL has very limited implicit conversions and promotions"_); and the language grows only by named extensions, never by version.

## How it works

A WGSL module is a set of declarations — `const`, `override`, `var`, `struct`, `fn`, `alias` — preceded by directives. Entry points are attributed functions whose parameters and return values carry the stage interface:

```wgsl
enable f16;
requires pointer_composite_access;

struct Globals { scale : f32, offset : vec2f }

@group(0) @binding(0) var<uniform> g : Globals;
@group(0) @binding(1) var tex : texture_2d<f32>;
@group(0) @binding(2) var smp : sampler;

override WORKGROUP : u32 = 64;                // pipeline-overridable constant

@fragment
fn fs(@location(0) uv : vec2f, @builtin(position) pos : vec4f) -> @location(0) vec4f {
    let c = textureSample(tex, smp, uv * g.scale + g.offset);   // must be in uniform control flow
    return vec4f(c.rgb, 1.0);
}

@compute @workgroup_size(WORKGROUP)
fn cs(@builtin(global_invocation_id) id : vec3u) { /* … */ }
```

The value/reference split is explicit: `let` names an immutable value, `var` names memory (a _reference_), `&` makes a `ptr<function, f32>` from it and `*` dereferences. `const` is evaluated at shader creation with **abstract numeric types** (`AbstractInt`, `AbstractFloat`) that adapt to the concrete type at use, so `1` and `1.0` need no suffixes. `override` is WebGPU's specialization constant and may size a `workgroup` array or the workgroup itself.

## Execution model and stages

WGSL defines exactly three stages ([`index.bs` §13.1][spec-stages]): _"WGSL defines three shader stages, corresponding to the programmable parts of pipelines"_ — compute, vertex and fragment. There is no geometry, tessellation, mesh, task or ray-tracing stage in the specification or in any standard extension at the pin.

| Stage    | Attribute                           | Interface                                                                                       |
| -------- | ----------------------------------- | ----------------------------------------------------------------------------------------------- |
| Vertex   | `@vertex`                           | must return `@builtin(position)`; inputs `@location(n)`, `vertex_index`, `instance_index`       |
| Fragment | `@fragment`                         | `position`, `front_facing`, `sample_index`, `sample_mask`; outputs `@location(n)`, `frag_depth` |
| Compute  | `@compute @workgroup_size(x, y, z)` | `local_invocation_id/index`, `global_invocation_id`, `workgroup_id`, `num_workgroups`           |

Interface values are parameters, return values and struct members tagged `@location(n)` or `@builtin(name)`, with `@interpolate(perspective | linear | flat, center | centroid | sample | first | either)` and `@invariant`. An entry point _"must never be the target of a function call"_ ([`index.bs` §11.4][spec-restrict]). Several entry points may share one module.

**Uniformity analysis** is the defining execution-model rule ([`index.bs` §15.2][spec-uniformity]):

> _"To ensure correct and portable behavior, a WGSL implementation will perform a static uniformity analysis, attempting to prove that each collective operation executes in uniform control flow."_

Collective operations are barriers (`workgroupBarrier`, `storageBarrier`, `textureBarrier`, `workgroupUniformLoad`), derivatives (`dpdx`, `fwidth`) and implicit-LOD texture sampling, plus subgroup and quad operations under `subgroups`. The analysis builds a graph per function whose nodes include `RequiredToBeUniform.error`, `RequiredToBeUniform.warning`, `RequiredToBeUniform.info` and `MayBeNonUniform`; a path from a `RequiredToBeUniform` node to `MayBeNonUniform` is a failure. Each function is summarised by tags (`CallSiteRequiredToBeUniform.S`, `ParameterRequiredToBeUniform.S`, `ReturnValueMayBeNonUniform`) so the analysis is modular. Failure severity differs by operation: a derivative failure raises the `derivative_uniformity` diagnostic (an error by default, downgradable with `diagnostic(off, derivative_uniformity)`), a barrier failure is always an error, and a subgroup failure raises `subgroup_uniformity`. Sources of non-uniformity include _"Mutable module-scope variables"_, _"Most built-in values"_, _"User-defined inputs"_ and certain built-in functions.

Subgroups are specified with a fixed range ([`index.bs` §15.5][spec-subgroups]): _"All subgroup sizes are powers of two within the range [4, 128]"_, and the subgroup size _"is a uniform value within a dispatch command […] but it may not be a uniform value within a draw command."_

## Type system and generic programming

| Family       | Types                                                                                                                                                         |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scalars      | `bool`, `i32`, `u32`, `f32`; `f16` with `enable f16`; abstract `AbstractInt`/`AbstractFloat` for const-expressions only                                       |
| Vectors      | `vecN<T>` (N = 2–4) with aliases `vec3f`, `vec4u`, `vec2h`, …                                                                                                 |
| Matrices     | `matCxR<f32 \| f16>`, column-major only                                                                                                                       |
| Aggregates   | `array<T, N>` (N may be an `override`), runtime-sized `array<T>` as the last member of a storage buffer, `struct`                                             |
| Atomics      | `atomic<i32>`, `atomic<u32>`; `atomic<vec2<u32>>` min/max with `atomic_vec2u_min_max`                                                                         |
| Memory views | `ptr<AS, T, AM>` and references; `buffer` with the `buffer_view` language extension                                                                           |
| Handles      | `sampler`, `sampler_comparison`, `texture_2d<T>` etc., `texture_depth_*`, `texture_multisampled_2d`, `texture_storage_2d<format, access>`, `texture_external` |

**Absent by design:** 64-bit integers and floats, 8- and 16-bit integers, unions, pointers stored in memory, pointer arithmetic, physical addresses, row-major matrices, user generics, user overloading, function pointers and recursion. Built-in functions are generic over their documented type sets; user functions are monomorphic. A D vocabulary therefore targets WGSL only through its 32-bit subset (plus `f16`), and the absence of `i64`/`f64` is a target check, not something to emulate.

## Resources, interfaces and memory layout

The address-space table is the core of WGSL's memory model ([`index.bs` §14.3][spec-as]):

| Address space | Sharing                | Default access | Use                                                                                        |
| ------------- | ---------------------- | -------------- | ------------------------------------------------------------------------------------------ |
| `function`    | same invocation        | `read_write`   | locals                                                                                     |
| `private`     | same invocation        | `read_write`   | module-scope per-invocation globals                                                        |
| `workgroup`   | same compute workgroup | `read_write`   | shared memory; outermost array count may be an `override`                                  |
| `uniform`     | same shader stage      | `read`         | uniform buffers                                                                            |
| `storage`     | same shader stage      | `read`         | storage buffers (`read` or `read_write`; vertex stage `read` only)                         |
| `immediate`   | same shader stage      | `read`         | push-constant-style data, at most one variable per entry point (`immediate_address_space`) |
| `handle`      | same shader stage      | `read`         | textures and samplers (not nameable)                                                       |

Resources bind with `@group(g) @binding(b)`, mapping directly onto Vulkan descriptor sets, D3D12 register spaces and Metal argument buffers in the implementations. Textures and samplers are **always separate**; there is no combined image-sampler type, which is the opposite of the GLSL model `sparkles:shaders` uses today (`SHF6`).

**Layout** follows the storage rules everywhere except `uniform`, which keeps the `std140`-like 16-byte rounding of array and struct alignment unless the `uniform_buffer_standard_layout` language extension is supported ([`index.bs` §14.4][spec-layout]). `vec3<f32>` has alignment 16 and size 12 — so a following `f32` occupies offset 12, as under GLSL `std430`, and unlike `sparkles:shaders`' 16-byte host `vec3`. Layout is enforced: _"Violations of an address space constraint results in a shader-creation error."_ `@align(n)` and `@size(n)` on members are the only layout controls.

**Pointer parameters** are restricted by default ([`index.bs` §11.4][spec-restrict]): a pointer parameter must point into `function` or `private`, and each pointer argument must have _"the same memory view as its root identifier"_ — no pointer to `a[i]` or `s.m`. The `unrestricted_pointer_parameters` language extension lifts both rules. A D helper that takes `ref` to a storage-buffer element is therefore not portable to all WGSL implementations unless inlined.

**Limits** are part of the language ([`index.bs` §2.4][spec-limits]): at most 8192 bytes of `private` variables per shader and 8192 bytes of `function` variables per function, 16384 bytes of `workgroup` storage, 64 bytes of immediate data, composite nesting depth 15, 255 parameters, 1023 struct members.

## Built-in library and intrinsics

The library ([`index.bs` §17][spec-builtins]) covers constructors and conversions, `bitcast`, logical (`all`, `any`, `select`), numeric (the GLSL.std.450 set with WGSL names: `fract`, `mix`, `smoothstep`, `inverseSqrt`, `countOneBits`, `extractBits`, `firstLeadingBit`, `dot4U8Packed`), derivatives (`dpdx`, `dpdxCoarse`, `dpdxFine`, `fwidth`), textures (`textureSample`, `textureSampleLevel`, `textureSampleGrad`, `textureSampleCompare`, `textureGather`, `textureLoad`, `textureStore`, `textureDimensions`), atomics (`atomicAdd` … `atomicCompareExchangeWeak`), packing (`pack4x8unorm`, `pack2x16float`), synchronisation (`workgroupBarrier`, `storageBarrier`, `textureBarrier`, `workgroupUniformLoad`), subgroup (`subgroupAdd`, `subgroupBallot`, `subgroupShuffleXor`, inclusive/exclusive scans) and quad (`quadBroadcast`, `quadSwapX/Y/Diagonal`) operations.

Extensions are two-tier ([`index.bs` §4.1][spec-ext]):

> _"Enable-extensions are intended to expose hardware functionality that is not universally supported."_ — _"A requires-directive is a directive that **documents** the program's use of one or more language extensions. It does not change the functionality exposed by the implementation."_

| `enable` (hardware, needs a `GPUFeatureName`)                                                                                    | `requires` (language extensions, listed in `wgslLanguageFeatures`)                                                                                                                                                                                                                                                                                                                                  |
| -------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `f16`, `clip_distances`, `dual_source_blending`, `subgroups`, `primitive_index`, `subgroup_size_control`, `atomic_vec2u_min_max` | `readonly_and_readwrite_storage_textures`, `packed_4x8_integer_dot_product`, `unrestricted_pointer_parameters`, `pointer_composite_access`, `uniform_buffer_standard_layout`, `subgroup_id`, `subgroup_uniformity`, `texture_and_sampler_let`, `texture_formats_tier1`, `linear_indexing`, `immediate_address_space`, `fragment_depth`, `buffer_view`, `swizzle_assignment`, `atomic_vec2u_min_max` |

The spec notes language extensions are cumulative and _"can be thought of as language versions, of a sort."_ Implementations run ahead of the spec: Dawn's [`wgsl.def`][dawn-def] also lists `chromium_experimental_pixel_local`, `chromium_experimental_framebuffer_fetch`, `chromium_experimental_subgroup_matrix`, `chromium_experimental_barycentric_coord`, `chromium_experimental_resource_table` (bindless), `view_instancing`, and language features `sized_binding_array`, `texel_buffers` and `multisampled_array_textures` not yet in the specification table. Swizzle **assignment** (`v.xz = vec2(1, 2);`) arrived only with `swizzle_assignment`; before it, WGSL had no lvalue swizzles.

Floating-point accuracy uses the Vulkan numbers (`atan` 4096 ULP for `f32`, 5 ULP for `f16`; [`index.bs` §15.7][spec-fp]) and a **Finite Math Assumption**: _"Implementations may assume that overflow, infinities, and NaNs are not present during shader execution."_ Overflow or NaN in a `const`-expression is a shader-creation error.

## Control flow, memory model and restrictions

WGSL's control flow is structured by grammar: `if`/`else`, `switch`, `loop` with `continuing { … break if cond; }`, `for`, `while`, `break`, `continue`, `return`, `discard`. Recursion is excluded by the declaration rules — _"Recursion is disallowed because cycles are not permitted among any kinds of declarations"_ ([`index.bs` §11.4][spec-restrict]).

**Defined behaviour where GLSL has none:**

| Case                    | WGSL rule                                                                                                                                                                                                                 |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Signed integer `e1 / 0` | evaluates to `e1` at run time; shader- or pipeline-creation error when constant ([`index.bs` §8.8][spec-div])                                                                                                             |
| `INT_MIN / -1`          | evaluates to `e1`                                                                                                                                                                                                         |
| Out-of-bounds access    | a _dynamic error_ the implementation will not perform as written: trap, an invalid load (a value from the binding, zero, or `(0, 0, 0, x)`) or a dropped/redirected store ([`index.bs` "Out-of-Bounds Access"][spec-oob]) |
| `discard`               | _"converts the invocation into a helper invocation and throws away the fragment output"_ — demote semantics, so derivatives stay valid                                                                                    |
| Atomics                 | _"All Atomic built-in functions use `Relaxed` memory semantics"_ ([`index.bs` §14.5][spec-memsem])                                                                                                                        |

The memory model is the Vulkan one: _"In general, WGSL follows the Vulkan Memory Model"_ ([`index.bs` §14.5][spec-memmodel]), restricted to relaxed atomics and barrier-implied acquire/release; WGSL exposes no scopes or orderings to the author (MSL 4.1 and Vulkan GLSL do).

## Compilation pipeline and targets

```text
WGSL ──► Tint (Dawn/Chrome) ──► SPIR-V · HLSL→DXIL · MSL · GLSL
     ──► naga (wgpu/Firefox) ──► SPIR-V · HLSL · MSL · GLSL · WGSL
     ──► WebKit WGSL compiler ──► MSL
SPIR-V ─► Tint SPIR-V reader / naga spv-in ─► WGSL   (the route a D shader takes)
```

WGSL has no binary form; it is shipped as text and compiled by the browser or by wgpu. A SPIR-V producer reaches it only through a SPIR-V→WGSL translator, and both available ones are narrow:

- **Tint's SPIR-V reader** first validates the module _"against rules for Vulkan 1.1"_ and may then reject it because _"it uses features unavailable in WGSL"_ or because _"the translated program tries to do something rejected by WGSL's rules (which are checked by Tint's Resolver)"_ ([`spirv-reader-overview.md`][tint-reader]) — the resolver being where the uniformity analysis lives ([`uniformity.cc`][tint-uniformity]).
- **naga `spv-in`** accepts a closed list of capabilities (`Shader`, `VulkanMemoryModel`, `Int8/16/64`, `Float16/64`, `Geometry`, `GroupNonUniform*`, `RuntimeDescriptorArray`, `FragmentBarycentricKHR`, …) and eight SPIR-V extensions ([`front/spv/mod.rs`][naga-caps], lines 54–101); `PhysicalStorageBufferAddresses`, `VariablePointers`, `Kernel`, ray tracing and mesh capabilities are absent. Its README rates WGSL input _"Fully validated"_ and WGSL output secondary ([`naga/README.md`][naga-readme]).

SPIRV-Cross has **no WGSL backend** (see [`spirv-cross.md`][spirv-cross]); a `sparkles:shaders` WGSL target means adding Tint or naga to the build step, alongside spirv-cross for GLSL.

## Host integration and CPU execution

WGSL has no host-language binding. The WebGPU API reflects bindings from `@group`/`@binding` and creates pipelines from text (`GPUDevice.createShaderModule`), with `override` values supplied at pipeline creation. There is no CPU execution path in the specification; implementations run on the GPU, or on a software Vulkan (SwiftShader) underneath. TypeGPU (see [`typegpu.md`][typegpu]) is the closest single-source precedent: it generates WGSL from TypeScript at run time and runs the same functions as JavaScript on the CPU. The WebGPU CTS's [`shader/`][cts] suite is the conformance corpus — execution tests per built-in with expected results — and is the model a D conformance corpus can copy for its WGSL column.

## Lessons for sparkles:shaders

- **Make uniformity a checked property, and check it in the build.** Every SPIR-V module destined for WGSL must pass a WGSL uniformity analysis; run Tint or naga on it in `shader-compile` (as `glslangValidator` already runs on GLSL), and offer a D-side `Uniform!T` wrapper or a `@uniformControlFlow` contract so the failure points at the D source rather than at translated WGSL.
- **Adopt the `enable`/`requires` split as the capability model.** A module-level UDA such as `@requires(Feature.subgroups, Feature.f16)` distinguishes hardware features (fail on devices without them) from language features (fail on implementations without them), and the build checks each against the chosen target's column — naga's closed capability list is the WGSL column's ground truth.
- **Match WGSL's defined semantics in the CPU reference.** Signed division by zero returns the dividend, `INT_MIN / -1` returns `INT_MIN`, shifts mask their count, `discard` demotes: implement these in the scalar CPU simulator and test them in the conformance corpus, so that "agrees with the GPU" means the WGSL answer, not D's `DivisionByZero` trap.
- **Treat pointer parameters as non-portable unless inlined.** Default WGSL forbids pointers into `storage`/`uniform`/`workgroup` and to sub-objects as parameters; either force-inline device helpers that take `ref` (as `SHF6` already does for `Sampler2D`) or require `unrestricted_pointer_parameters`.
- **Keep the 32-bit portable core explicit.** No `long`, `double`, `byte`, `short` in a module that targets WGSL; `half` only with `f16`. The D type checker, not the translator, should report these.
- **Design separate textures and samplers into the vocabulary now.** WGSL (like Vulkan, HLSL and MSL) has no combined image-sampler; the combined `Sampler2D` of `SHF6` is GLSL's model only and should become a lowering, not the D type.
- **Copy abstract literals' ergonomics.** D's `1.0` is `double`; a vocabulary that makes `vec3(1.0, 0, 0)` produce `f32` components without suffixes (template constructors over integral and floating literals) avoids WGSL's need for abstract types while matching its behaviour.

## Strengths

- **A real specification with a conformance suite**: every built-in, layout and error is defined, and the CTS tests them across three independent implementations.
- **Portability by construction**: uniformity analysis, defined OOB and integer behaviour, and required diagnostics remove most of GLSL's undefined behaviour.
- **Safe by default**: no pointers escape bindings, no physical addresses, no recursion, bounded private memory.
- **A clean extension model** that separates hardware gaps from implementation lag.
- **Readable translation target**: Tint and naga emit structured, human-readable SPIR-V, HLSL and MSL from it.

## Weaknesses

- **Lowest-common-denominator feature set**: no 64-bit or 8/16-bit integer types, no geometry, tessellation, mesh or ray tracing, no bindless in the standard, no buffer device addresses, relaxed atomics only.
- **Uniformity analysis is conservative**: code that is uniform at run time but not provably so (a loop bound read from a `read_write` buffer) must be restructured or the diagnostic disabled.
- **No generics or user overloading**, and swizzle assignment only since 2026; reuse means code generation.
- **SPIR-V→WGSL translation is narrow**: only Tint and naga, each with a closed list of accepted SPIR-V features, so producers must stay inside their subsets.
- **Text-only distribution**: every load recompiles in the browser.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                            | Trade-off                                                                                            |
| --------------------------------------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Mandatory static uniformity analysis                      | collective operations behave the same on every GPU                   | rejects some correct programs; analysis must be specified precisely enough for three implementations |
| Defined results for OOB, division by zero, `INT_MIN / -1` | safety on the web; portability                                       | extra instructions (clamps, selects) on every backend                                                |
| Logical pointers only, restricted pointer parameters      | translatable to MSL, HLSL and logical SPIR-V; no aliasing surprises  | no pointer-based data structures; helpers taking references need an extension                        |
| No language versions; `enable` + `requires`               | features ship independently; portability is documented in the source | feature availability is a set, not a number; implementations diverge before standardisation          |
| Abstract numeric literals                                 | literals need no suffixes and convert exactly                        | two type systems (abstract at const time, concrete at run time) to specify                           |
| Separate textures and samplers, no combined type          | matches Vulkan, D3D12 and Metal                                      | GLSL ES/GL targets need combination in the translator                                                |
| Finite Math Assumption                                    | lets backends use fast math                                          | `isnan`-style code is unreliable; `min`/`max` may misbehave on NaN                                   |

## Sources

- [gpuweb/gpuweb at `3c1276a4`][repo] — [`wgsl/index.bs`][spec-src]: [introduction][spec-intro], [overview][spec-overview], [limits][spec-limits], [extensions][spec-ext], [out-of-bounds access][spec-oob], [division][spec-div], [restrictions on functions][spec-restrict], [shader stages][spec-stages], [address spaces][spec-as], [layout constraints][spec-layout], [memory model][spec-memmodel], [memory semantics][spec-memsem], [uniformity][spec-uniformity], [subgroups][spec-subgroups], [floating point][spec-fp], [built-in functions][spec-builtins]; [`LICENSE.md`][license]
- W3C: [WGSL Candidate Recommendation Draft (2026-09-21)][tr] · [Editor's Draft][ed] · [WebGPU CTS][cts]
- Dawn/Tint at `67d4d6e6`: [`wgsl.def`][dawn-def], [`spirv-reader-overview.md`][tint-reader], [`resolver/uniformity.cc`][tint-uniformity]
- naga (wgpu at `efcf4457`): [`naga/README.md`][naga-readme], [`front/spv/mod.rs`][naga-caps]
- sparkles: [`SPEC.md`][sparkles-spec]
- Related: [GLSL][glsl] · [HLSL][hlsl] · [MSL][msl] · [SPIRV-Cross][spirv-cross] · [naga][naga] · [Tint][tint] · [TypeGPU][typegpu] · [concepts][concepts] · [comparison][comparison] · [index][index]

<!-- References -->

[repo]: https://github.com/gpuweb/gpuweb/tree/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd
[license]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/LICENSE.md
[spec-src]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs
[spec-intro]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L298-L302
[spec-overview]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L355-L472
[spec-limits]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L914-L962
[spec-ext]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L1812-L2088
[spec-oob]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L4151-L4211
[spec-div]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L7059-L7090
[spec-restrict]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L9604-L9620
[spec-stages]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L10293-L10340
[spec-as]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L11654-L11727
[spec-layout]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L12176-L12260
[spec-memmodel]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L12315-L12320
[spec-memsem]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L12429-L12433
[spec-uniformity]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L12504-L12700
[spec-subgroups]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L14101-L14125
[spec-fp]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L14231-L14600
[spec-builtins]: https://github.com/gpuweb/gpuweb/blob/3c1276a4a148a0a3c790112b5a4d37b9f20f0acd/wgsl/index.bs#L14975
[tr]: https://www.w3.org/TR/WGSL/
[ed]: https://gpuweb.github.io/gpuweb/wgsl/
[cts]: https://github.com/gpuweb/cts/tree/e325d0bcc2cb785c4eab1d908339019215bd9462/src/webgpu/shader
[dawn-def]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/src/tint/lang/wgsl/wgsl.def
[tint-reader]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/docs/tint/spirv-reader-overview.md
[tint-uniformity]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/src/tint/lang/wgsl/resolver/uniformity.cc
[naga-readme]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga/README.md
[naga-caps]: https://github.com/gfx-rs/wgpu/blob/efcf445784dd31537f09bc61bad27431de713fce/naga/src/front/spv/mod.rs#L54-L101
[sparkles-spec]: ../../specs/shaders/SPEC.md
[glsl]: ./glsl.md
[hlsl]: ./hlsl.md
[msl]: ./msl.md
[spirv-cross]: ./spirv-cross.md
[naga]: ./naga.md
[tint]: ./tint.md
[typegpu]: ./typegpu.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
