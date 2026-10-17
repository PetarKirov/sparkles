# GLSL (Khronos / OpenGL, OpenGL ES, Vulkan)

The C-shaped shading language of OpenGL, OpenGL ES and WebGL, and — through `GL_KHR_vulkan_glsl` and glslang — still the most common way to write Vulkan SPIR-V; the language `sparkles:shaders` generates today and the first one its D vocabulary has to replace.

| Field          | Value                                                                                                                                                                        |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | GLSL 4.60 (OpenGL 4.6), GLSL ES 1.00 / 3.00 / 3.10 / 3.20 (OpenGL ES 2.0–3.2, WebGL 1/2), Vulkan GLSL (`GL_KHR_vulkan_glsl` + `GL_EXT_*` / `GL_KHR_*` extensions)            |
| License        | Specification and extension sources: CC-BY-4.0 ([`KhronosGroup/GLSL`][glsl-repo]); glslang: BSD-3-Clause and others ([`LICENSE.txt`][glslang-license])                       |
| Repository     | [KhronosGroup/GLSL][glsl-repo] (spec source + Vulkan-era extensions) · [KhronosGroup/glslang][glslang-repo] (reference front end and SPIR-V generator)                       |
| Documentation  | [GLSL 4.60 spec][glsl460] · [GLSL ES 3.20 spec][essl320] · [GLSL ES 1.00 spec][essl100] · [OpenGL 4.6 core spec][gl46] (block layouts) · [Vulkan SPIR-V environment][vk-env] |
| Category       | Language (source); the reference input to glslang, the reference output of SPIRV-Cross                                                                                       |
| Latest version | GLSL 4.60 revision 9 and GLSL ES 3.20 revision 9 ([`core.adoc`][core-adoc] at the pin); new features land only as extensions (e.g. `GL_EXT_long_vector`, 2025-12-08)         |
| Targets        | OpenGL/ES drivers (source); SPIR-V for Vulkan or OpenGL 4.6 (`ARB_gl_spirv`) via glslang                                                                                     |
| Pins           | `KhronosGroup/GLSL` at `0099bf83` (2026-09-11); `KhronosGroup/glslang` at `5cf91e73` (2026-10-16, after 16.6.0 of 2026-09-10)                                                |

---

## Overview

### What it solves

GLSL is the per-invocation program the OpenGL pipeline runs at each programmable stage: a `main()` per stage, global `in`/`out` variables for the stage interface, `uniform` variables and blocks for host data, and a large set of built-in functions and variables (`texture`, `dFdx`, `gl_FragCoord`). The same source text serves three dialects that are **not** subsets of one another:

| Dialect      | Spelled                                                | Consumer                 | What distinguishes it                                                                                    |
| ------------ | ------------------------------------------------------ | ------------------------ | -------------------------------------------------------------------------------------------------------- |
| Desktop GLSL | `#version 330` … `#version 460`                        | OpenGL driver            | loose uniforms, `atomic_uint`, subroutines, `double`, implicit conversions                               |
| GLSL ES      | `#version 100`, `300 es`, `310 es`, `320 es`           | OpenGL ES / WebGL driver | precision qualifiers are semantic; no implicit conversions; ES 1.00 is a much smaller language           |
| Vulkan GLSL  | `#version 140`+ or `310 es`+, compiled by glslang `-V` | SPIR-V for Vulkan        | descriptor sets, push constants, separate textures/samplers, specialization constants; no loose uniforms |

`sparkles:shaders` emits the first two today — `<entry>.frag` in GLSL 3.30 and `<entry>.es.frag` in GLSL ES 1.00 ([`SPEC.md` `SHP5`][sparkles-spec]) — by translating SPIR-V with SPIRV-Cross (see [`spirv-cross.md`][spirv-cross]). To replace "the latest GLSL" it must reach the third as well, and cover the extension surface Vulkan GLSL has grown since 2016.

### Design philosophy

The core specification is deliberately small and stable; the Vulkan mapping is an overlay. Its own introduction makes SPIR-V, not GLSL, normative for the bytes ([`chapters/introduction.adoc`][intro]):

> _"While this specification and the {apispec} are normative for {slname}, for SPIR-V generation it is still the SPIR-V specification and the SPIR-V client API specification that are normative for the generated SPIR-V."_

and makes the front end, not the driver, the capability gate:

> _"{slabbrev} -> SPIR-V compilers must be directed as to what SPIR-V *Capabilities* are legal at run-time and give errors for {slabbrev} feature use outside those capabilities."_

`GL_KHR_vulkan_glsl` ([`extensions/khr/GL_KHR_vulkan_glsl.txt`][vk-glsl], revision 49, 2023-12-12) is explicit that it is not a language version but a compilation mode:

> _"This extension is not enabled with a #extension as other extensions are. It is also not enabled through use of a profile or #version. […] Instead, use of this extension is an effect of using a GLSL front-end in a mode that has it generate SPIR-V for Vulkan."_

Everything since — subgroups, ray tracing, mesh shading, buffer references, cooperative matrices — arrived the same way: as an extension text file in `KhronosGroup/GLSL` that describes a GLSL spelling for an existing SPIR-V capability. The repository README says as much: it holds the extensions "notably for Vulkan" that "do not live in the Khronos registries for OpenGL or OpenGL ES" ([`README.adoc`][glsl-readme]). GLSL in 2026 is therefore **GLSL 4.60 plus a catalogue of SPIR-V spellings**, with glslang as the reference implementation whose README rates its GLSL/ESSL front end _"Virtually complete, with results carrying similar weight as the specifications"_ ([`README.md`][glslang-readme]).

## How it works

A shader is one stage per compilation unit, its interface declared at global scope and its execution modes as `layout` qualifiers on `in`/`out`:

```glsl
#version 460
#extension GL_EXT_nonuniform_qualifier : require

layout(local_size_x = 64) in;                       // execution mode
layout(constant_id = 0) const uint STRIDE = 4;      // specialization constant
layout(set = 0, binding = 0, std430) readonly buffer In  { vec4 src[]; };
layout(set = 0, binding = 1, std430) writeonly buffer Out { vec4 dst[]; };
layout(set = 1, binding = 0) uniform texture2D textures[];   // bindless
layout(set = 1, binding = 1) uniform sampler smp;
layout(push_constant) uniform Push { uint texIndex; } pc;

void main() {
    uint i = gl_GlobalInvocationID.x;
    vec4 t = textureLod(sampler2D(textures[nonuniformEXT(pc.texIndex)], smp), vec2(0.5), 0.0);
    dst[i] = src[i * STRIDE] * t;
}
```

Every identifier above maps to one SPIR-V construct, and the spec's non-normative mapping chapter ([`chapters/spirvmappings.adoc`][spirvmap]) lists them: `layout(constant_id)` → `OpSpecConstant` + `SpecId`; `push_constant` → `PushConstant` storage class; `texture2D` → `OpTypeImage`, `sampler` → `OpTypeSampler`, `sampler2D(t, s)` → `OpSampledImage`; `mediump`/`lowp` → `RelaxedPrecision`; `precise` → `NoContraction`.

The pipeline from source to driver has two shapes:

1. **OpenGL / ES source path.** The application hands GLSL text to the driver, which compiles it; uniforms and attributes are bound **by name** (`glGetUniformLocation`), or by `layout(location)`/`layout(binding)` from GLSL 3.30/4.20 (ES 3.00/3.10).
2. **SPIR-V path.** glslang parses to an AST, checks it against the target's capabilities and resource limits, and emits SPIR-V (`glslangValidator -V` for Vulkan, `-G` for OpenGL 4.6). The README records that glslang's HLSL front end is _"Deprecated as of April 2026"_ ([`README.md`][glslang-readme]), leaving glslang a GLSL-only tool.

Function calls are **copy-in/copy-out**, not by reference ([`chapters/statements.adoc`][statements-call]):

> _"Functions are called by value-return. This means input arguments are copied into the function at call time, and output arguments are copied back to the caller before function exit. Because the function works with local copies of parameters, there are no issues regarding aliasing of variables within a function."_

That rule matters for a D vocabulary: D `ref` aliases, GLSL `inout` does not, so `f(a, a)` can differ between the CPU and the GPU unless the D side copies.

## Execution model and stages

| Stage                       | Desktop GLSL | GLSL ES | Vulkan GLSL                                 | Execution-mode syntax                                                              |
| --------------------------- | ------------ | ------- | ------------------------------------------- | ---------------------------------------------------------------------------------- |
| Vertex, fragment            | 1.10         | 1.00    | core                                        | `layout(early_fragment_tests) in`, `layout(depth_greater) out float gl_FragDepth;` |
| Geometry                    | 1.50         | 3.20    | `geometryShader` feature                    | `layout(triangles) in; layout(triangle_strip, max_vertices = 3) out;`              |
| Tessellation control / eval | 4.00         | 3.20    | `tessellationShader` feature                | `layout(vertices = 3) out;`, `layout(triangles, fractional_odd_spacing) in;`       |
| Compute                     | 4.30         | 3.10    | core                                        | `layout(local_size_x = 8, local_size_y = 8) in;`, `local_size_x_id`                |
| Task / mesh                 | —            | —       | [`GLSL_EXT_mesh_shader`][ext-mesh]          | `layout(max_vertices = 64, max_primitives = 126, triangles) out;`                  |
| Ray generation … callable   | —            | —       | [`GLSL_EXT_ray_tracing`][ext-rt] (6 stages) | payloads: `layout(location = 0) rayPayloadEXT T p;`                                |

GLSL has exactly one entry point, `main()`, per compilation unit; SPIR-V permits many `OpEntryPoint`s per module, which is the shape LDC emits. The stage interface is **global**: `in`/`out` variables, built-in blocks (`gl_PerVertex`), and stage-specific arrays (`in vec3 n[]` in geometry and tessellation). A D design that models stage inputs as function parameters — the WGSL and HLSL shape `sparkles:shaders` already uses (`SHF2`) — must therefore generate the globals; it cannot take GLSL's interface shape as its own.

The **invocation group** and uniform control flow are defined once, in [`chapters/basics.adoc`][basics-uniform]: _"Uniform control flow is the initial state at the entry into main(), and lasts until a conditional branch takes different control paths for different invocations"_. Unlike WGSL, GLSL defines the term but does not require a front end to prove anything: `barrier()` and implicit-LOD sampling outside uniform control flow are simply undefined. Subgroups (`GL_KHR_shader_subgroup`, ratified 2017-10-27, [`GL_KHR_shader_subgroup.txt`][ext-subgroup]) add a second scope, and [`GL_EXT_maximal_reconvergence`][ext-maxrec] adds `void main() [[maximally_reconverges]]`, which "maps to the MaximallyReconvergesKHR execution mode" — a promise about reconvergence after divergent branches that an LLVM-based producer must not break by tail-merging or jump-threading across subgroup operations.

## Type system and generic programming

| Family     | Core                                                                                                    | Extension types                                                                                                                                   |
| ---------- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scalars    | `bool`, `int`, `uint` (1.30 / ES 3.00), `float`, `double` (4.00, desktop only)                          | `int8_t`…`uint64_t`, `float16_t`, `float64_t` ([`GL_EXT_shader_explicit_arithmetic_types`][ext-arith]); `bfloat16_t`, `floate4m3_t`/`floate5m2_t` |
| Vectors    | `vecN`, `ivecN`, `uvecN`, `bvecN`, `dvecN`, N = 2–4                                                     | `f16vecN`, `i8vecN`, …; `vector<T, N>` with N > 4 ([`GLSL_EXT_long_vector`][ext-longvec], 2025-12-08)                                             |
| Matrices   | `matN`, `matCxR` (column-major values; `row_major` affects only memory)                                 | `f16matCxR`, `f64matCxR`                                                                                                                          |
| Aggregates | structs (no member functions), fixed arrays, arrays of arrays (4.30 / ES 3.10), runtime-sized SSBO tail | unsized descriptor arrays ([`GL_EXT_nonuniform_qualifier`][ext-nonuniform])                                                                       |
| Opaque     | `sampler2D` family, `image2D` family, `atomic_uint`                                                     | Vulkan: `texture2D`, `sampler`, `subpassInput`; `accelerationStructureEXT`, `rayQueryEXT`, `hitObjectEXT`, `coopmat<…>`                           |
| References | —                                                                                                       | `layout(buffer_reference) buffer Node { … };` — a 64-bit pointer type ([`GLSL_EXT_buffer_reference`][ext-bufref])                                 |

**There is no user-level generic programming.** Built-ins are overloaded over `genFType`/`genIType`/… families; user functions overload by parameter type; there are no templates, no interfaces, no operator overloading, and no function pointers (desktop `subroutine` uniforms are the one dispatch mechanism, removed in Vulkan GLSL). The only parameterised types are recent extension types — `coopmat<float16_t, gl_ScopeSubgroup, 16, 8, gl_MatrixUseA>` in [`GLSL_KHR_cooperative_matrix`][ext-coopmat] (2023-07-21) and `vector<T, N>` in `GL_EXT_long_vector` — whose parameters must be constant expressions or specialization constants. GLSL is converging on what D's templates already express; the D side's job is to keep the GLSL **spelling** (`vec3`, `mix`, `fract`) while replacing the preprocessor and copy-paste overloads with templates and CTFE.

Implicit conversions are a dialect difference: desktop GLSL 4.x converts `int`→`uint`→`float`→`double`; GLSL ES converts nothing (_"WGSL has very limited implicit conversions"_ is WGSL's answer to the same problem, see [`wgsl.md`][wgsl]). The D vocabulary should mirror GLSL's **result types** exactly and emit every conversion explicitly, which serves both dialects.

## Resources, interfaces and memory layout

| Resource                 | Desktop GLSL                           | GLSL ES 1.00         | Vulkan GLSL                                                                                                          |
| ------------------------ | -------------------------------------- | -------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Loose `uniform float t;` | yes, bound by name or `location`       | yes, by name only    | **removed** (opaque types excepted)                                                                                  |
| Uniform block (UBO)      | 1.40, `std140`/`shared`/`packed`       | —                    | `std140` default; `std430` with `uniformBufferStandardLayout`; `scalar` ([`GL_EXT_scalar_block_layout`][ext-scalar]) |
| Storage block (SSBO)     | 4.30, `std430`                         | —                    | `std430`, `scalar`; runtime-sized last member                                                                        |
| Push constants           | —                                      | —                    | `layout(push_constant) uniform`                                                                                      |
| Binding                  | `layout(binding = N)` (4.20)           | none                 | `layout(set = S, binding = N)`                                                                                       |
| Textures                 | combined `sampler2D`                   | combined `sampler2D` | combined **or** separate `texture2D` + `sampler`                                                                     |
| Specialization constants | via `glSpecializeShader` (SPIR-V only) | —                    | `layout(constant_id = N) const …`                                                                                    |
| Device addresses         | —                                      | —                    | `buffer_reference` (Vulkan 1.3 requires BDA)                                                                         |
| Bindless                 | —                                      | —                    | `textures[nonuniformEXT(i)]` (descriptor indexing)                                                                   |

`GL_KHR_vulkan_glsl` lists what it removes — _"default uniforms (uniform variables not inside a uniform block), except for opaque types"_, _"atomic-counters"_, _"subroutines"_, _"shared and packed block layouts"_, _"gl_VertexID and gl_InstanceID"_ — and what changes: _"arrays of uniforms and buffer blocks take only one binding number for the entire object, not one per array element"_ and _"the default origin is origin_upper_left instead of origin_lower_left"_ ([`GL_KHR_vulkan_glsl.txt`][vk-glsl]). The GL and Vulkan dialects thus need a translation layer even for basic shaders; `gl_VertexIndex` includes the base vertex where `gl_VertexID` did not.

**Block layouts** are defined by the OpenGL specification ([`glspec46.core.pdf`][gl46] §7.6.2.2), not the GLSL one:

| Layout   | Scalar | `vec2` | `vec3`       | `vec4` | Array stride / struct alignment | Matches D natural layout? |
| -------- | ------ | ------ | ------------ | ------ | ------------------------------- | ------------------------- |
| `std140` | 4      | 8      | 16 (size 12) | 16     | rounded up to 16                | no                        |
| `std430` | 4      | 8      | 16 (size 12) | 16     | element alignment               | only without `vec3`       |
| `scalar` | 4      | 4      | 4 (size 12)  | 4      | component alignment             | yes (with `align(4)`)     |

A scalar may occupy the padding after a `vec3` under `std140` and `std430` (offset 12), which no C or D struct reproduces; `sparkles:shaders` already records this as the reason its host `vec3` is a 16-byte struct but not `std140` ([`decisions.md`][sparkles-decisions] D9). Only `scalar` equals natural layout, and it is an optional Vulkan 1.2 feature with no GL or ES counterpart.

**GLSL ES 1.00** — the floor `sparkles:shaders` targets for GLES 2 — is a different language. Its [Appendix A][essl100] (revision 17, 2009-05-12) restricts loops to _"constant iteration loops"_: _"There is one loop index"_, the condition _"has the form loop_index relational_operator constant_expression"_, and _"Support for while and do-while is not mandated."_ Uniform arrays in the fragment shader may be indexed only by _constant-index-expressions_ (constants and loop indices), the remainder operator `%` and the shift operators are _"reserved"_ (illegal), and there is no `uint`. Fragment outputs are `gl_FragColor`/`gl_FragData[]`, and linking between stages is by name.

## Built-in library and intrinsics

The core library (GLSL 4.60 §8, [`chapters/builtinfunctions.adoc`][builtins]) has roughly 170 function names across angle/trigonometry, exponential, common (`mix`, `step`, `smoothstep`, `fract`, `mod`, `fma`, `frexp`), packing (`packUnorm4x8`, `packHalf2x16`), geometric, matrix, vector-relational (`lessThan`, `any`, `all` — because `<` on vectors is illegal and `==` reduces to one `bool`), integer (`bitfieldExtract`, `findMSB`, `uaddCarry`), texture (`texture`, `textureLod`, `textureGrad`, `texelFetch`, `textureGather`, `textureSize`), image (`imageLoad`, `imageStore`, `imageAtomic*`), atomics, derivatives (`dFdx`, `dFdxFine`, `fwidth`), interpolation (`interpolateAtSample`), geometry (`EmitVertex`), and barriers (`barrier`, `memoryBarrier*`).

| Extension                                                                                             | Adds                                                                                                                    | Vulkan status                                |
| ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| [`GL_KHR_shader_subgroup`][ext-subgroup] (+ `_rotate`)                                                | `subgroupAdd`, `subgroupBallot`, `subgroupShuffle`, `subgroupQuadBroadcast`, clustered/inclusive/exclusive scans        | 1.1 core (basic in compute); rotate 1.4      |
| [`GL_KHR_memory_scope_semantics`][ext-memscope]                                                       | `atomicAdd(x, v, gl_ScopeDevice, gl_StorageSemanticsBuffer, gl_SemanticsRelease)`, `atomicLoad/Store`, `controlBarrier` | Vulkan memory model, 1.3 required            |
| [`GLSL_EXT_ray_tracing`][ext-rt] / [`GLSL_EXT_ray_query`][ext-rq]                                     | `traceRayEXT`, `reportIntersectionEXT`, `ignoreIntersectionEXT;`, `rayQueryInitializeEXT` + ~20 getters                 | `VK_KHR_ray_tracing_pipeline` / `_ray_query` |
| [`GLSL_EXT_mesh_shader`][ext-mesh]                                                                    | `SetMeshOutputsEXT`, `EmitMeshTasksEXT`, `gl_MeshVerticesEXT[]`, `perprimitiveEXT`, `taskPayloadSharedEXT`              | `VK_EXT_mesh_shader`                         |
| [`GLSL_KHR_cooperative_matrix`][ext-coopmat]                                                          | `coopMatLoad`, `coopMatStore`, `coopMatMulAdd`                                                                          | `VK_KHR_cooperative_matrix`                  |
| [`GLSL_EXT_demote_to_helper_invocation`][ext-demote] / [`GL_EXT_terminate_invocation`][ext-terminate] | `demote;`, `helperInvocationEXT()`; `terminateInvocation;`                                                              | both required by Vulkan 1.3                  |
| [`GLSL_EXT_debug_printf`][ext-printf]                                                                 | `debugPrintfEXT("%d", x)` through `NonSemantic.DebugPrintf`                                                             | validation layer                             |
| [`GLSL_EXT_spirv_intrinsics`][ext-spvintr]                                                            | `spirv_instruction(set, id)`, `spirv_decorate`, `spirv_execution_mode` — a raw SPIR-V escape hatch                      | —                                            |

Two library facts constrain the D vocabulary directly. First, **constant-expression arguments**: texel offsets (`textureOffset`), the gather component, cluster sizes and ray payload locations must be compile-time constants — exactly what a D template value parameter expresses and a runtime argument cannot. Second, **by-reference built-ins**: `atomicAdd`, `interpolateAtSample` and `imageAtomic*` take a _variable_ (an lvalue in a particular storage class), not a value, so their D signatures need `ref` plus a storage-class check.

Precision is the third. The GLSL spec defines `highp` as IEEE binary32 but leaves most functions unspecified (_"The rounding mode cannot be set and is undefined but must not affect the result by more than 1 ULP"_, [`chapters/variables.adoc`][precision]); the Vulkan environment's table ([`spirvenv.html`][vk-precision]) fills the gap (`sin`/`cos` absolute 2⁻¹¹ on [−π, π], `atan` 4096 ULP). `sparkles:shaders` already judges CPU/GPU agreement by that table ([`D12`][sparkles-d12]).

## Control flow, memory model and restrictions

| Rule                                                      | Source                                                                                                                     |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| No recursion, static or dynamic                           | _"Static, and hence dynamic, recursion is not allowed."_ ([`statements.adoc`][statements-recursion])                       |
| No `goto`, no function pointers                           | the grammar has neither; `subroutine` is desktop-only and absent from Vulkan                                               |
| Out-of-bounds access is undefined unless robustness is on | _"any out-of-bounds access produced undefined behavior"_ ([`operators.adoc`][operators-oob])                               |
| Barriers and implicit derivatives in uniform control flow | defined in [`basics.adoc`][basics-uniform], not checked                                                                    |
| ES 1.00 loops and indexing                                | Appendix A, above                                                                                                          |
| `discard` meaning                                         | under SPIR-V 1.6 `OpKill` is deprecated; GLSL `discard` maps to terminate, HLSL's to demote — the names differ by language |

The memory model comes in two layers: the legacy `coherent`/`volatile`/`restrict`/`readonly`/`writeonly` qualifiers plus `memoryBarrier*()`, and the Vulkan memory model of `GL_KHR_memory_scope_semantics`, which adds scopes (`gl_ScopeWorkgroup`, `gl_ScopeDevice`, `gl_ScopeQueueFamily`), storage classes and acquire/release semantics to every atomic and barrier. A D API built like `core.atomic` — `atomicOp!"+="(ref x, v)` with a `MemoryOrder` — maps onto the second layer once a `Scope` template parameter is added.

Control flow in GLSL source is always structured, which is why SPIRV-Cross can reconstruct it from SPIR-V merge instructions; LLVM IR is not, which is why LDC's SPIR-V must be structurised before any translation (see [`concepts.md`][concepts-structured]).

## Compilation pipeline and targets

```text
                    ┌──────────── OpenGL / ES driver (compiles source at run time)
GLSL source ────────┤
                    └── glslang ── SPIR-V ── Vulkan driver
                                     │
D (sparkles) ── LDC ── SPIR-V ── spirv-opt ── SPIRV-Cross ── GLSL 3.30 / ESSL 1.00 ── glslangValidator
```

`sparkles:shaders` uses GLSL as an **output** language. Its build step (`apps/shader-compile`, [`app.d`][app-d]) validates the LDC module with `spirv-val --target-env spv1.6`, optimises with `spirv-opt -O`, translates each fragment entry with `spirv-cross --version 330` and `--es --version 100`, renames the combined sampler back to the D parameter's name, and validates every file with `glslangValidator` (`SHP4`–`SHP6`). Two gaps in that chain are GLSL facts rather than tool bugs:

- glslang's default resource limits are permissive for ES 1.00: `nonInductiveForLoops`, `whileLoops`, `generalUniformIndexing`, `generalSamplerIndexing` and `generalVariableIndexing` are all `1` in [`ResourceLimits.cpp`][glslang-limits] (lines 149–157), so the validation step does **not** enforce Appendix A unless a configuration file sets them to `0`.
- SPIRV-Cross emits `%`, `<<` and `&` verbatim for ES 1.00 although ES 1.00 reserves them (see [`spirv-cross.md`][spirv-cross]); the D front end must reject them for that target.

To target Vulkan GLSL the build would add `--vulkan-semantics`, keep descriptor sets and push constants, and drop the combined-sampler rewrite; to target OpenGL 4.6 SPIR-V directly it could skip translation altogether.

## Host integration and CPU execution

GLSL has **no host-language integration**: the host sees strings (source) or words (SPIR-V) and binds by name, location or set/binding, all of it reflected separately (glslang's reflector, SPIRV-Cross `--reflect`, SPIRV-Reflect). There is no CPU execution path in the language or its reference tooling — glslang compiles, it does not run — so CPU fallbacks are re-implementations, which is the drift `sparkles:shaders` exists to remove ([`SPEC.md` §1][sparkles-spec]). The closest CPU stories are software rasterisers (SwiftShader, Mesa's llvmpipe/lavapipe) that run the shader at the API level, not as a callable function.

The `#define VULKAN 100` predefine and `#ifdef` dialect switching shown in `GL_KHR_vulkan_glsl` is the GLSL idiom for one source, several targets; in D it becomes `version`/`static if`, and the generated text carries only the resolved `#version` and `#extension` lines.

## Lessons for sparkles:shaders

- **Adopt GLSL's names and result types, not its interface shape.** Keep `vec3`, `mix`, `fract`, `smoothstep` and GLSL's overload result types (the current `SHV1` vocabulary), but keep stage I/O as D function parameters (`SHF2`) and let the emitter generate `in`/`out` globals, `gl_FragData`, and Vulkan's `gl_VertexIndex` versus GL's `gl_VertexID`.
- **Express constant-expression arguments as template value parameters**: `tex.sampleOffset!(ivec2(1, 0))(uv)`, `gather!(Component.g)`, `subgroupClusteredAdd!4(x)`. A runtime parameter cannot carry GLSL's "must be a constant expression" rule; a template does, and lowers to the SPIR-V constant operand directly.
- **Match `inout` semantics with copies, not `ref`.** A D helper taking `ref` aliases where GLSL copies in and out; either forbid passing the same lvalue twice in device code or lower `ref` to a copy-in/copy-out temporary, and test `f(a, a)` on both sides in the conformance corpus.
- **Make the block layout a declared property with a CTFE checker.** A `@layout(Layout.std140 | std430 | scalar)` UDA on a block struct, an `offsetOf!(S, Layout, field)` computed at compile time, and a `static assert` that the D struct's natural layout matches — or a generated padded mirror. `vec3` followed by a scalar is the test case that separates the three.
- **Model each GLSL feature as a capability record and check it per target.** Every construct carries the SPIR-V capability, Vulkan feature, and GLSL `#version`/`#extension` it needs; a target profile (`gles100`, `gl330`, `gl460`, `vulkan13`) rejects code that needs more. ES 1.00's Appendix A becomes a front-end rule set (one `int`/`float` loop index, constant bounds, no `%`/shift/`uint`, constant indexing of fragment uniform arrays), plus a glslang configuration with the Appendix A limits set to `0` as a second check.
- **Name `discard`, `demote` and `terminate` separately** (`discard()` typed `noreturn` as terminate, `demote()` returning normally), because SPIR-V 1.6 deprecated `OpKill` and GLSL and HLSL now mean different things by `discard`.
- **Avoid a preprocessor and avoid copying GLSL's missing generics.** `version (Vulkan)`, `static if` and mixins replace `#ifdef VULKAN`; templates replace `genFType` overload sets; only the emitted text needs `#version`/`#extension`.

## Strengths

- **Ubiquity**: the only source language every OpenGL, OpenGL ES and WebGL driver accepts; GLSL ES 1.00 still reaches GLES 2 devices nothing else reaches.
- **A precise SPIR-V mapping**: every Vulkan GLSL construct is a documented spelling of a SPIR-V capability, so GLSL is the most faithful human-readable view of SPIR-V — which is why SPIRV-Cross targets it.
- **A reference implementation with specification weight** (glslang) and an extension repository that tracks new hardware within months (descriptor heap, long vectors, float8 in 2025–2026).
- **Simple, stable core**: GLSL 4.60's language delta from 4.50 is small (draw parameters, group votes, atomic-counter operations, SPIR-V); code written in 2017 still compiles.

## Weaknesses

- **Three dialects, no common subset by construction**: loose uniforms, `atomic_uint`, subroutines and `gl_VertexID` exist in one and not another; ES has no implicit conversions; ES 1.00 is a separate language.
- **No generic programming**: no templates, interfaces or operator overloading; reuse is the preprocessor and `#include` (`GL_GOOGLE_include_directive`, a glslang extension).
- **Global interface state**: stage inputs, outputs and resources are globals, which makes a shader impossible to call as a function and hard to test.
- **Undefined behaviour without diagnostics**: out-of-bounds access, non-uniform barriers and derivatives, shift counts and signed `%` are undefined, and nothing requires a front end to report them.
- **Layout rules that match no host language** (`std140`'s 16-byte array stride, scalars packed into `vec3` padding).
- **No CPU execution story.**

## Key design decisions and trade-offs

| Decision                                                                      | Rationale                                                                    | Trade-off                                                                                             |
| ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Vulkan support as a compilation mode (`GL_KHR_vulkan_glsl`), not a `#version` | one language serves GL, ES and Vulkan; the front end selects semantics       | the same text means different things (`gl_VertexIndex`, origin, binding of arrays) per mode           |
| New features only as SPIR-V-shaped extensions                                 | features ship as fast as SPIR-V capabilities do; no language revision needed | ~100 extension texts to read; feature availability is a matrix, not a version                         |
| Copy-in/copy-out parameters                                                   | no aliasing inside functions; simple compilers                               | `inout` differs from C/D references; large arguments are copied unless the compiler elides it         |
| Global stage interface                                                        | maps one-to-one onto the fixed-function pipeline                             | shaders are not functions; no host-side reuse                                                         |
| `std140`/`std430` block layouts                                               | portable across 2008-era hardware with vec4 registers                        | host structs need manual padding; only optional `scalar` matches C                                    |
| ES precision qualifiers (`mediump`, `lowp`)                                   | let mobile GPUs run fp16 ALUs                                                | output differs by device; `sparkles:shaders` had to force `highp` after a visible Adreno defect (D15) |
| No recursion, no function pointers                                            | stackless hardware; every call inlines                                       | no dynamic dispatch; generic code must be resolved at compile time                                    |

## Sources

- [`KhronosGroup/GLSL` repository at `0099bf83`][glsl-repo] — [`README.adoc`][glsl-readme], [`core.adoc`][core-adoc]
- GLSL spec source: [`chapters/introduction.adoc`][intro], [`chapters/basics.adoc` (uniform control flow)][basics-uniform], [`chapters/statements.adoc` (calling conventions)][statements-call], [recursion][statements-recursion], [`chapters/operators.adoc` (out-of-bounds)][operators-oob], [`chapters/variables.adoc` (precision)][precision], [`chapters/builtinfunctions.adoc`][builtins], [`chapters/spirvmappings.adoc`][spirvmap]
- Extensions: [`GL_KHR_vulkan_glsl`][vk-glsl], [`GL_KHR_shader_subgroup`][ext-subgroup], [`GL_KHR_memory_scope_semantics`][ext-memscope], [`GLSL_KHR_cooperative_matrix`][ext-coopmat], [`GLSL_EXT_ray_tracing`][ext-rt], [`GLSL_EXT_ray_query`][ext-rq], [`GLSL_EXT_mesh_shader`][ext-mesh], [`GLSL_EXT_buffer_reference`][ext-bufref], [`GL_EXT_nonuniform_qualifier`][ext-nonuniform], [`GL_EXT_scalar_block_layout`][ext-scalar], [`GL_EXT_shader_explicit_arithmetic_types`][ext-arith], [`GLSL_EXT_demote_to_helper_invocation`][ext-demote], [`GL_EXT_terminate_invocation`][ext-terminate], [`GL_EXT_maximal_reconvergence`][ext-maxrec], [`GLSL_EXT_long_vector`][ext-longvec], [`GLSL_EXT_debug_printf`][ext-printf], [`GLSL_EXT_spirv_intrinsics`][ext-spvintr]
- Khronos registry: [GLSL 4.60][glsl460], [GLSL ES 3.20][essl320], [GLSL ES 1.00 (Appendix A)][essl100], [OpenGL 4.6 core profile (§7.6.2.2 block layout)][gl46], [Vulkan SPIR-V environment][vk-env] and [precision table][vk-precision]
- glslang at `5cf91e73`: [`README.md`][glslang-readme], [`ResourceLimits.cpp`][glslang-limits], [`CHANGES.md`][glslang-changes]
- sparkles: [`SPEC.md`][sparkles-spec], [`decisions.md`][sparkles-decisions], [`apps/shader-compile/src/app.d`][app-d]
- Related: [HLSL][hlsl] · [WGSL][wgsl] · [MSL][msl] · [SPIRV-Cross][spirv-cross] · [concepts][concepts] · [comparison][comparison] · [index][index]

<!-- References -->

[glsl-repo]: https://github.com/KhronosGroup/GLSL/tree/0099bf83b0288469917fc2e2972cb0a2b74d6711
[glsl-readme]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/README.adoc
[core-adoc]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/core.adoc
[intro]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/chapters/introduction.adoc
[basics-uniform]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/chapters/basics.adoc#L946-L1018
[statements-call]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/chapters/statements.adoc#L325-L331
[statements-recursion]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/chapters/statements.adoc#L424-L436
[operators-oob]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/chapters/operators.adoc#L1104-L1119
[precision]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/chapters/variables.adoc#L5680-L5700
[builtins]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/chapters/builtinfunctions.adoc
[spirvmap]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/chapters/spirvmappings.adoc
[vk-glsl]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/khr/GL_KHR_vulkan_glsl.txt
[ext-subgroup]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/khr/GL_KHR_shader_subgroup.txt
[ext-memscope]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/khr/GL_KHR_memory_scope_semantics.txt
[ext-coopmat]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/khr/GLSL_KHR_cooperative_matrix.txt
[ext-rt]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/ext/GLSL_EXT_ray_tracing.txt
[ext-rq]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/ext/GLSL_EXT_ray_query.txt
[ext-mesh]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/ext/GLSL_EXT_mesh_shader.txt
[ext-bufref]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/ext/GLSL_EXT_buffer_reference.txt
[ext-nonuniform]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/ext/GL_EXT_nonuniform_qualifier.txt
[ext-scalar]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/ext/GL_EXT_scalar_block_layout.txt
[ext-arith]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/ext/GL_EXT_shader_explicit_arithmetic_types.txt
[ext-demote]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/ext/GLSL_EXT_demote_to_helper_invocation.txt
[ext-terminate]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/ext/GL_EXT_terminate_invocation.txt
[ext-maxrec]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/ext/GL_EXT_maximal_reconvergence.txt
[ext-longvec]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/ext/GLSL_EXT_long_vector.txt
[ext-printf]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/ext/GLSL_EXT_debug_printf.txt
[ext-spvintr]: https://github.com/KhronosGroup/GLSL/blob/0099bf83b0288469917fc2e2972cb0a2b74d6711/extensions/ext/GLSL_EXT_spirv_intrinsics.txt
[glslang-repo]: https://github.com/KhronosGroup/glslang/tree/5cf91e73b01ce835d281a9c3b3d9158f7f74ff86
[glslang-readme]: https://github.com/KhronosGroup/glslang/blob/5cf91e73b01ce835d281a9c3b3d9158f7f74ff86/README.md
[glslang-license]: https://github.com/KhronosGroup/glslang/blob/5cf91e73b01ce835d281a9c3b3d9158f7f74ff86/LICENSE.txt
[glslang-limits]: https://github.com/KhronosGroup/glslang/blob/5cf91e73b01ce835d281a9c3b3d9158f7f74ff86/glslang/ResourceLimits/ResourceLimits.cpp#L149-L157
[glslang-changes]: https://github.com/KhronosGroup/glslang/blob/5cf91e73b01ce835d281a9c3b3d9158f7f74ff86/CHANGES.md
[glsl460]: https://registry.khronos.org/OpenGL/specs/gl/GLSLangSpec.4.60.html
[essl320]: https://registry.khronos.org/OpenGL/specs/es/3.2/GLSL_ES_Specification_3.20.html
[essl100]: https://registry.khronos.org/OpenGL/specs/es/2.0/GLSL_ES_Specification_1.00.pdf
[gl46]: https://registry.khronos.org/OpenGL/specs/gl/glspec46.core.pdf
[vk-env]: https://docs.vulkan.org/spec/latest/appendices/spirvenv.html
[vk-precision]: https://docs.vulkan.org/spec/latest/appendices/spirvenv.html#spirvenv-precision-operation
[sparkles-spec]: ../../specs/shaders/SPEC.md
[sparkles-decisions]: ../../specs/shaders/decisions.md
[sparkles-d12]: ../../specs/shaders/decisions.md#d12-agreement-is-judged-by-the-vulkan-precision-table
[app-d]: ../../../apps/shader-compile/src/app.d
[hlsl]: ./hlsl.md
[wgsl]: ./wgsl.md
[msl]: ./msl.md
[spirv-cross]: ./spirv-cross.md
[concepts]: ./concepts.md
[concepts-structured]: ./concepts.md#structured-control-flow-merge-and-continue-blocks
[comparison]: ./comparison.md
[index]: ./index.md
