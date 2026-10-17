# Shading Languages — Comparison

The synthesis of the catalog: what the five shading languages require of a complete
replacement, how the single-source systems meet it, where the toolchain sets the
ceiling, and where [`sparkles:shaders`][shaders-spec] stands. It closes with a delta
table and the recommendations the next specification work should start from. Terms
are defined in [Concepts](./concepts.md); each claim here is grounded in the
deep-dive it links to.

**Last reviewed:** October 17, 2026

---

## The capability matrix

What each shading language can express, at the versions surveyed. "Ext." marks a
feature reached only through an extension; "—" a feature the language does not have.
The last column is `sparkles:shaders` with the toolchain of #659.

| Capability                         | GLSL 4.60 / Vulkan GLSL                | HLSL SM 6.9                        | Slang                             | WGSL                          | MSL 4.1                              | sparkles today                     |
| ---------------------------------- | -------------------------------------- | ---------------------------------- | --------------------------------- | ----------------------------- | ------------------------------------ | ---------------------------------- |
| Vertex, fragment, compute          | yes                                    | yes                                | yes                               | yes                           | yes                                  | fragment only                      |
| Geometry, tessellation             | yes                                    | yes                                | yes                               | —                             | tessellation (post-tess vertex)      | —                                  |
| Mesh, task                         | ext. (`GL_EXT_mesh_shader`)            | yes (SM 6.5)                       | yes                               | —                             | yes (object, mesh)                   | —                                  |
| Ray tracing pipelines, ray query   | ext.                                   | yes (DXR 1.1/1.2)                  | yes                               | —                             | intersection functions, ray query    | —                                  |
| Work graphs                        | —                                      | yes (SM 6.8, D3D12 only)           | via HLSL/DXIL                     | —                             | —                                    | —                                  |
| Scalar types beyond 32-bit float   | int/uint/bool/double; 8/16/64-bit ext. | 16/64-bit (mandatory 6.9)          | all                               | `f16` ext.; no 64-bit         | `half`, `bfloat`, no `double`        | `float`; `int` as uniform only     |
| Vectors, matrices                  | yes                                    | yes; long vectors (6.9)            | yes, generic                      | yes                           | yes, plus `simdgroup_matrix`         | `vec2`–`vec4` `float`; no matrices |
| User generics                      | — (`coopmat`, `vector` built-ins only) | templates (2021)                   | interfaces + associated types     | —                             | C++ templates                        | D templates (host and device)      |
| Swizzles                           | read and write                         | read and write                     | read and write                    | read (write: `requires` ext.) | read and write                       | read via UFCS functions            |
| Uniform blocks, storage buffers    | std140, std430, scalar (ext.)          | `cbuffer`, structured/byte buffers | `ParameterBlock`, all             | `uniform`, `storage`          | argument buffers                     | loose uniforms only                |
| Push constants                     | Vulkan GLSL                            | `[[vk::push_constant]]`            | yes                               | —                             | `setBytes` equivalent                | —                                  |
| Bindless / descriptor indexing     | ext. + `nonuniformEXT`                 | `ResourceDescriptorHeap`           | yes                               | binding arrays (ext.)         | argument buffers                     | —                                  |
| Device addresses                   | `buffer_reference` ext.                | `vk::RawBufferLoad`                | pointers                          | —                             | `device T*`                          | `GlobalPointer` (compute kernels)  |
| Images: sample, load/store, gather | yes                                    | yes                                | yes                               | yes                           | yes                                  | `Sampler2D.sample` only            |
| Subgroup / wave operations         | `GL_KHR_shader_subgroup_*`             | wave + quad (SM 6.0)               | yes                               | `subgroups` ext.              | SIMD-group functions                 | via raw `llvm.spv.*` intrinsics    |
| Derivatives                        | yes (coarse/fine)                      | yes; in compute (6.6)              | yes                               | yes (uniformity-checked)      | yes                                  | via raw intrinsics                 |
| Discard                            | terminate (`demote` ext.)              | demote semantics                   | target-dependent                  | demote                        | terminate (pre-2.3)                  | via raw intrinsics                 |
| Specialization constants           | `constant_id`                          | `[[vk::constant_id]]`              | link-time constants               | `override`                    | `function_constant`                  | —                                  |
| Automatic differentiation          | —                                      | —                                  | forward and backward              | —                             | —                                    | —                                  |
| Modules, separate compilation      | —                                      | DXIL libraries                     | modules, link-time specialisation | —                             | dynamic libraries, visible functions | D modules, one unit per package    |

Sources: [GLSL][glsl], [HLSL][hlsl], [Slang][slang], [WGSL][wgsl], [MSL][msl],
[dcompute][dcompute].

Two observations follow. **First, the union is large but the core is shared:** every
language has vertex, fragment and compute stages, 32-bit scalar and vector types,
uniform and storage buffers, sampled and storage images, barriers and derivatives; the
remaining capabilities are reached by one or two languages, usually through an
extension. **Second, the languages are converging on generic programming** — HLSL's
templates, Slang's interfaces, GLSL's own `coopmat` and `vector` types, MSL's C++ —
which D has had longest of all of them.

---

## The single-source spectrum

How a host language reaches the GPU decides what of the host language survives:

| Approach                                     | Example                                                                                        | What survives of the host language                                            | Cost                                                                                    |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Separate shading language                    | GLSL, HLSL, WGSL, MSL                                                                          | Nothing; layouts and constants duplicated by hand                             | Two implementations that drift — the problem `sparkles:shaders` exists to solve         |
| Host subset translated to a shading language | [TypeGPU][typegpu], [ComputeSharp][computesharp]                                               | Expressions and plain functions; the subset is what the generator understands | Each target's language becomes the ceiling; debugging is in generated code              |
| Host compiler with a GPU back end            | [rust-gpu][rust-gpu], [Zig][zig-spirv], [dcompute][dcompute], [Circle][circle], [Julia][julia] | Types, generics, modules, compile-time code; one source tree                  | The back end must structure control flow and reject what shaders cannot do              |
| Full host language, emulated on the GPU      | [Vcc and Shady][vcc-shady]                                                                     | Pointers, recursion, function pointers                                        | Slow (function pointers 20× CUDA's cost in the paper) and untranslatable by SPIRV-Cross |
| Offload model                                | [CUDA and HIP][cuda-hip], [SYCL][sycl]                                                         | All of C++ in kernels' callees, within device restrictions                    | Compute only; no graphics stages                                                        |

The precedents that matter most for a D design sit in the third row. Each uses its
host language's own type system for the shader's types and its attributes for the
interface; each restricts the device subset; none of them owns the memory layout of
host-and-device data ([rust-gpu][rust-gpu], [Circle][circle] and [Zig][zig-spirv]
reuse the host struct layout and leave padding to the user), and none of them runs
GPU-only built-ins on the CPU. Vcc shows the cost of not restricting: emulating C++
on Vulkan works, but the output reaches no translator and runs at a fraction of
native speed, so the restriction belongs in the front end, reported at the source
line.

---

## Structured control flow

Every shading language is structured by construction; every host language is not.
The four strategies seen in the catalog:

| Strategy                                    | Used by                                                                                     | Outcome                                                                                                      |
| ------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Structurizer in the SPIR-V back end         | [LLVM SPIR-V backend][llvm-spirv], [Zig][zig-spirv], [rust-gpu][rust-gpu], [Lava.jl][julia] | Heuristic; the LLVM one picks the first eligible successor as a merge block and fails ordinary early returns |
| Generic structurization before the back end | sparkles (LLVM `StructurizeCFG`, from #659), AMDGPU                                         | Nested single-entry, single-exit regions with flow blocks; every probe shape validates                       |
| Structured IR from the front end            | [MLIR][mlir] `scf` → `spirv`, [naga][naga], [Tint][tint]                                    | Correct by construction; MLIR's SPIR-V dialect lacks graphics ops (derivatives, demote)                      |
| Emulation                                   | [Vcc and Shady][vcc-shady]                                                                  | Any control flow, at a performance and translator cost                                                       |

Structure matters beyond validity: subgroup operations and derivatives are defined by
where control flow reconverges, and Vulkan's maximal-reconvergence and quad-control
features (Roadmap 2024) let a shader rely on it. A design that serves subgroup code
must therefore say where its reconvergence points are and keep the optimiser from
moving them — Clang emits convergence tokens for this, and LDC's dcompute does not
yet ([Clang HLSL][clang-hlsl], [LLVM SPIR-V backend][llvm-spirv]).

---

## CPU execution

Running a shader on the CPU with its GPU semantics intact is rare:

| System                                                                 | Model                                                    | Barriers                     | Subgroups / quads                       | Derivatives |
| ---------------------------------------------------------------------- | -------------------------------------------------------- | ---------------------------- | --------------------------------------- | ----------- |
| [ISPC][ispc]                                                           | SPMD on SIMD: a gang of lanes in vector registers, masks | none inside a gang           | the gang is the subgroup                | —           |
| [ILGPU][ilgpu] `v1.5.3`                                                | One OS thread per lane                                   | real barriers                | warps emulated over threads             | —           |
| [ILGPU][ilgpu] master                                                  | A group as SIMD lanes under an active mask               | group size ≤ SIMD width      | lanes of one vector                     | —           |
| HIP-CPU ([CUDA and HIP][cuda-hip])                                     | One fiber per thread                                     | fiber switch per thread      | emulated                                | —           |
| [SYCL][sycl] CPU backends                                              | Kernel compiled for CPU, work items as loop iterations   | kernel split at each barrier | sub-groups mapped to vector lanes       | —           |
| [rust-gpu][rust-gpu], [TypeGPU][typegpu], [ComputeSharp][computesharp] | Shared pure functions only                               | —                            | GPU built-ins panic or return `default` | —           |

No surveyed system executes fragment shaders on the CPU with quads, helper lanes and
derivatives. Two further lessons bear directly on the plan. **SYCL removed its host
device** because no one could agree whether it was an emulator for testing or a fast
CPU target ([SYCL][sycl]); a scalar reference executor and an SPMD executor are two
products with two contracts. **ISPC's masking is done in its front end** from its
`uniform`/`varying` types ([ISPC][ispc]); an LLVM-level executor for D needs a
whole-function vectorizer (the RV vectorizer and DPC++'s Vecz are the precedents)
with uniformity analysis, linearised divergent control flow and an all-lanes-active
fast path — ISPC's own measurements put that path at a 0.73× slowdown when missing.
ILGPU's two accelerators disagree on edge cases (an out-of-range shuffle source, a
lane that returns before a barrier), which is the case for pinning those semantics in
a conformance corpus run at several SIMD widths.

---

## The translation ceiling

One SPIR-V module reaches only the targets its translators accept:

| Feature in the SPIR-V module                 | SPIRV-Cross → GLSL 3.30 / ES 3.00 | → Vulkan GLSL | → HLSL         | → MSL                   | naga → WGSL | Tint → WGSL        |
| -------------------------------------------- | --------------------------------- | ------------- | -------------- | ----------------------- | ----------- | ------------------ |
| Vertex, fragment, compute                    | yes                               | yes           | yes            | yes                     | yes         | yes                |
| Geometry, tessellation                       | yes                               | yes           | geometry only  | tessellation (emulated) | —           | —                  |
| Mesh, task                                   | —                                 | yes           | yes            | yes                     | parsed      | —                  |
| Ray tracing                                  | —                                 | yes           | ray query only | ray query only          | —           | —                  |
| `OpTerminateInvocation`                      | yes                               | yes           | yes            | yes                     | —           | yes                |
| `OpDemoteToHelperInvocation`                 | —                                 | yes           | yes (SM 6.0)   | MSL 2.3+                | —           | — (emulated)       |
| Buffer device addresses (`OpPtrAccessChain`) | —                                 | —             | —              | yes                     | —           | —                  |
| `Int64`, `Float64`                           | 4.0+ / —                          | yes           | yes            | 64-bit int only         | yes         | —                  |
| SPIR-V version accepted                      | any                               | any           | any            | any                     | any         | ≤ 1.3 (Vulkan 1.1) |
| Linkage, `Kernel`, untyped pointers          | —                                 | —             | —              | —                       | —           | —                  |

Sources: [SPIRV-Cross][spirv-cross], [naga][naga], [Tint][tint]; the demote and
terminate rows are checked by the runnable
[`translator_ceiling.d`](./examples/translator_ceiling.d).

The table makes the case for **target profiles**: a set of capabilities a module may
use, chosen per output and checked in the D front end before any SPIR-V is emitted. A
"Vulkan" profile, a "GLSL ES 3.00" profile and a "WGSL through Tint" profile admit
different features; buffer device addresses, for example, reach only Vulkan and MSL,
and Tint takes nothing newer than SPIR-V 1.3. A design that emits one module and hopes
fails late, in a translator, far from the source line.

---

## The consensus standard

Across the catalog, the practices that recur in every mature system:

1. **Stages and interface as attributes** on functions and parameters
   (`[shader("pixel")]`, `@fragment`, `#[spirv(fragment)]`, `[[vk::binding]]`).
2. **Resources as opaque typed handles** (`Texture2D<float4>`, `texture_2d<f32>`,
   `Image!(…)`) whose methods are the texture operations.
3. **A portable core plus extensions or profiles**, never one flat feature set:
   GLSL's extensions, HLSL's shader models, WGSL's `enable`/`requires`, Slang's
   capabilities and `__target_switch`.
4. **Structured control flow** at the IR the driver sees, and an explicit uniformity
   or convergence story wherever derivatives and subgroups exist.
5. **Layout computed, not assumed**, wherever data crosses to the host: std140/std430
   rules in GLSL, `cbuffer` packing in HLSL, TypeGPU's schemas, ComputeSharp's
   generated packing.
6. **Reflection** of the compiled interface to the host (Slang's reflection API,
   SPIRV-Reflect, naga's module info) rather than hand-kept binding tables.

---

## Architectural trade-offs

| Choice                                                     | For                                                                         | Against                                                                     |
| ---------------------------------------------------------- | --------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| LLVM IR → SPIR-V (today)                                   | One front end for host and device; LLVM's optimiser; shared with Clang HLSL | Unstructured IR; a young back end with a fixed stage and capability list    |
| MLIR `scf` → `spirv`                                       | Structure kept from the source; capability inference                        | Missing graphics ops; a second code generator in LDC; MLIR in the toolchain |
| Own SPIR-V emitter (Lava.jl, Zig, rust-gpu)                | Full control of output and stages                                           | A large codebase to own (Lava's is ~13,500 lines)                           |
| One SPIR-V, many translators                               | One compiler; mature translators                                            | The intersection of translators is the ceiling                              |
| Generate source languages directly (TypeGPU, ComputeSharp) | Readable output; no translator                                              | One generator per target                                                    |
| DXIL via LLVM's DirectX back end                           | Reaches D3D-only features (work graphs, SER)                                | A second device back end; validator signing on D3D12 unverified             |
| CPU twin: shared pure functions                            | Free; exact agreement on math                                               | Nothing GPU-specific is testable on the CPU                                 |
| CPU twin: lock-step executor                               | Subgroups, quads, barriers and derivatives testable on the CPU              | A new subsystem; two executors if SPMD speed is wanted                      |

---

## Delta table

What the field offers, against `sparkles:shaders` with the toolchain of #659
([dcompute][dcompute] is the detailed account):

| Capability                 | Field                                                       | `sparkles:shaders` today                                    | Gap                                                                            |
| -------------------------- | ----------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Stages                     | all 14 (GLSL, HLSL, Slang)                                  | fragment; compute kernels via dcompute                      | vertex in the fork; the rest need LLVM back-end work                           |
| Types                      | scalars to 64 bits, matrices, generic vectors               | `float` vectors of 2–4; `int` uniforms                      | integer, bool, double, half vectors; matrices                                  |
| One project vector type    | —                                                           | shader `vec*` and `sparkles.math.Vector` differ             | unify (decided)                                                                |
| Swizzles                   | read and write                                              | read, through UFCS                                          | write swizzles need a struct vector                                            |
| Resources                  | blocks, buffers, images, samplers, push constants, bindless | loose uniforms, one `Sampler2D` kind, one shared sampler    | the whole resource model                                                       |
| Layout                     | std140, std430, scalar                                      | one layout (`vec3` 16 bytes) matching neither               | CTFE-computed layouts                                                          |
| Built-ins                  | ~170 GLSL functions, subgroups, atomics, derivatives        | ~15 math functions; `sample`                                | the library                                                                    |
| Control flow               | structured by construction                                  | structured since #659 (`StructurizeCFG` + structurizer fix) | convergence tokens for subgroup code                                           |
| Rejected device constructs | per language                                                | recursion (since #659), module-scope variables, GC, strings | `immutable` tables and workgroup memory are blocked by the module-variable ban |
| Targets                    | SPIR-V, DXIL, GLSL, HLSL, MSL, WGSL                         | GLSL 3.30, ES 1.00 via SPIRV-Cross                          | Vulkan SPIR-V, ES 3.x, HLSL, MSL, WGSL; per-target profiles                    |
| Validation                 | `spirv-val` per environment                                 | universal SPIR-V 1.6 rules                                  | Vulkan validation once a Vulkan output exists                                  |
| CPU execution              | ISPC, ILGPU, HIP-CPU executors                              | host build of pure functions                                | scalar reference executor, then SPMD                                           |
| Reflection                 | Slang, SPIRV-Reflect, naga                                  | names checked by the compiler; no reflection data           | binding tables for Vulkan hosts                                                |
| Precision contract         | Vulkan's table; most peers silent                           | `D12`, checked by a GPU readback                            | extend to each new built-in                                                    |

---

## Recommendations

For the specification work that follows; each names the deep-dives it rests on.

1. **Define target profiles first.** A profile is a set of SPIR-V capabilities and a
   SPIR-V version, checked in the D front end with the source line of the offending
   construct, and the delta of each translator ([SPIRV-Cross][spirv-cross],
   [naga][naga], [Tint][tint]) becomes data instead of a late failure.
2. **Build the resource model and the Vulkan output together.** Loose uniforms are
   valid only for OpenGL ([`uniform_shapes.d`](./examples/uniform_shapes.d)); a uniform
   block, push constants and descriptor bindings derived from D declarations are the
   prerequisite of every Vulkan feature ([GLSL][glsl], [HLSL][hlsl],
   [LLVM SPIR-V backend][llvm-spirv]).
3. **Compute layouts at compile time.** std140, std430 and scalar layouts from D
   structs, checked with `static assert` on both sides, are what no peer offers and
   what D's CTFE makes cheap ([TypeGPU][typegpu], [ComputeSharp][computesharp],
   [rust-gpu][rust-gpu]).
4. **Name the three kinds of `discard`.** Terminate and demote are different programs;
   a D vocabulary should spell both and lower demote by flag and masked writes where a
   target lacks it, as Tint does ([Concepts][concepts-discard], [Tint][tint]).
5. **Emit convergence information.** Before subgroup operations enter the vocabulary,
   the fork should emit the convergence tokens Clang emits, so reconvergence points
   survive optimisation ([Clang HLSL][clang-hlsl], [LLVM SPIR-V backend][llvm-spirv]).
6. **Specify the scalar reference executor and the SPMD executor separately**, with one
   semantics both are tested against, and pin the edge cases the precedents disagree on
   in the conformance corpus ([ISPC][ispc], [ILGPU][ilgpu], [SYCL][sycl],
   [CUDA and HIP][cuda-hip]).
7. **Treat MLIR as a contribution, not a migration.** The SAoC milestone that lowers
   D to `scf` is the structure-preserving path shaders need; offering the corpus of
   control-flow shapes as its acceptance tests is worth more now than a second code
   generator ([MLIR SPIR-V][mlir]).
8. **Use Slang as the reference for generics over resources and for autodiff** — the
   two areas where it leads the field and D has the mechanisms (templates, CTFE) but
   no design yet ([Slang][slang]).

## Sources

The deep-dives of this catalog; each carries its own pinned sources.

<!-- References -->

[shaders-spec]: ../../specs/shaders/SPEC.md
[concepts-discard]: ./concepts.md#discard-demote-and-terminate
[glsl]: ./glsl.md
[hlsl]: ./hlsl.md
[slang]: ./slang.md
[wgsl]: ./wgsl.md
[msl]: ./msl.md
[dcompute]: ./dcompute.md
[rust-gpu]: ./rust-gpu.md
[cuda-hip]: ./cuda-hip.md
[sycl]: ./sycl.md
[circle]: ./circle.md
[vcc-shady]: ./vcc-shady.md
[typegpu]: ./typegpu.md
[computesharp]: ./computesharp.md
[ilgpu]: ./ilgpu.md
[ispc]: ./ispc.md
[julia]: ./julia.md
[zig-spirv]: ./zig-spirv.md
[llvm-spirv]: ./llvm-spirv-backend.md
[clang-hlsl]: ./clang-hlsl.md
[mlir]: ./mlir-spirv.md
[spirv-cross]: ./spirv-cross.md
[naga]: ./naga.md
[tint]: ./tint.md
