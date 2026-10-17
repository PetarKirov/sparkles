# Shading Languages — Concepts

The shared vocabulary the deep-dives of this catalog use. Each term is defined once
here, against the specification that owns it; the deep-dives link back instead of
redefining it. Terms are grouped by the layer they belong to: the execution model,
the interface between a shader and its host, memory, control flow, and toolchains.

> [!NOTE]
> SPIR-V terms follow the [SPIR-V specification][spirv-spec] (unified, up to version
> 1.6) and the Vulkan environment it is used in, the
> [Vulkan specification's appendix on SPIR-V][vk-spirv-env]. GLSL, HLSL, WGSL and MSL
> spell many of the same ideas differently; the table at the end maps the spellings.

**Last reviewed:** October 17, 2026

---

## Execution model

### Invocation, workgroup, subgroup and quad

An **invocation** is one execution of a shader for one item of work: a vertex, a
fragment, a compute work item. Invocations are grouped three ways:

| Group         | What it is                                                                                        | Spellings                                                           |
| ------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| **Workgroup** | The compute invocations that share workgroup memory and can synchronise with a barrier            | GLSL work group, HLSL thread group, WGSL workgroup, MSL threadgroup |
| **Subgroup**  | The invocations an implementation runs together in lock-step (one SIMD unit), with cross-lane ops | GLSL/Vulkan subgroup, HLSL wave, MSL SIMD-group, CUDA warp          |
| **Quad**      | A 2×2 block of neighbouring fragment invocations, the unit derivatives are computed over          | GLSL/HLSL quad, MSL quad-group                                      |

A [subgroup operation](#subgroup-and-wave-operations) reads values from other
invocations of the same subgroup; a [derivative](#derivative) reads them from the
other invocations of the same quad. Neither has a meaning for a single invocation
running alone, which is why a CPU twin of such code needs an executor that runs a
whole subgroup or quad together (see [SPMD and SIMT](#spmd-simt-and-simd)).

### Subgroup and wave operations

Operations that read or combine a value across the active invocations of a
subgroup: votes (`subgroupAll`, HLSL `WaveActiveAllTrue`), ballots (a bit mask of
the invocations where a condition holds), broadcasts and shuffles (one invocation's
value to others), reductions and prefix scans (`subgroupAdd`,
`WavePrefixSum`), and quad operations (`subgroupQuadSwapHorizontal`,
`QuadReadAcrossX`). SPIR-V spells them `OpGroupNonUniform*` under the
`GroupNonUniform*` capabilities, available in Vulkan 1.1 and later. Their results
depend on which invocations are active at the call, so they are defined by where
control flow [reconverges](#uniformity-and-convergence).

### Execution model and stage

A SPIR-V **execution model** is the pipeline stage an entry point implements
(`Vertex`, `Fragment`, `GLCompute`, `TaskEXT`, `MeshEXT`, the six ray-tracing
models, …), declared by `OpEntryPoint` ([SPIR-V §3.3][spirv-exec-model]). An
**execution mode** (`OpExecutionMode`) configures it: `LocalSize` for a compute
workgroup's size, `OriginUpperLeft` and `DepthReplacing` for a fragment shader,
`OutputVertices` for a mesh shader. Source languages spell the stage as an
attribute (`[shader("pixel")]` in HLSL, `@fragment` in WGSL, `fragment` in MSL) or
choose it per compilation (GLSL's `-S frag`).

### Helper invocation

A fragment invocation that runs only so that its quad can compute
[derivatives](#derivative), and whose writes have no effect. Invocations outside a
primitive's coverage are helpers from the start; with
[demote](#discard-demote-and-terminate), a live invocation can become one.

### Derivative

The rate of change of a value across a [quad](#invocation-workgroup-subgroup-and-quad)
in screen x and y (`dFdx`/`dFdy` in GLSL, `ddx`/`ddy` in HLSL, `dpdx` in WGSL,
`dfdx` in MSL; `OpDPdx` and its `Coarse`/`Fine` variants in SPIR-V). Implicit-LOD
texture sampling uses derivatives to choose a mip level, so it, too, needs the whole
quad to be executing — the root of WGSL's [uniformity](#uniformity-and-convergence)
rules.

### Discard, demote and terminate

Three ways a fragment invocation stops contributing, which source languages
confusingly share one keyword for:

| SPIR-V                       | Meaning                                                                     | Source spelling                                                                                                                                                        |
| ---------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `OpTerminateInvocation`      | The invocation ends; nothing after it runs (core in 1.6)                    | GLSL `discard`, MSL `discard_fragment()` (pre-2.3)                                                                                                                     |
| `OpDemoteToHelperInvocation` | It becomes a [helper](#helper-invocation): it keeps running, writes nothing | GLSL `demote` (`GL_EXT_demote_to_helper_invocation`), WGSL `discard`; D3D's `discard`/`clip` semantics (Clang emits it from SPIR-V 1.6; DXC emits `OpKill` by default) |
| `OpKill`                     | Deprecated predecessor of `OpTerminateInvocation`                           | —                                                                                                                                                                      |

Translating one into another is not always possible: demote cannot be expressed in
GLSL 3.30 or MSL before 2.3. See the [LLVM SPIR-V backend](./llvm-spirv-backend.md)
for how a frontend chooses between them.

### SPMD, SIMT and SIMD

**SIMD** hardware executes one instruction over many data lanes. **SIMT** (CUDA's
term) and **SPMD** (_single program, multiple data_) are the programming models that
hide it: the programmer writes the code of one invocation, and the implementation
runs many invocations at once, one per lane, masking off lanes whose control flow
diverges. Every GPU shading language is SPMD. [ISPC](./ispc.md) brings the same model
to CPU SIMD units; it is the precedent for running shaders on a CPU with their
subgroup semantics intact.

### Uniformity and convergence

A value is **uniform** when every invocation of a group (a subgroup, a quad, a draw)
holds the same value; control flow is uniform when every invocation takes the same
path. Invocations that took different paths are **divergent**; the point where they
run together again is where they **reconverge**. Derivatives, implicit-LOD sampling
and barriers are only defined in uniform control flow. WGSL rejects programs whose
uniformity it cannot prove ([uniformity analysis][wgsl-uniformity]); GLSL and HLSL
leave such programs undefined. Vulkan's `VK_KHR_shader_maximal_reconvergence` and
`VK_KHR_shader_quad_control` (required by the [Roadmap 2024][vk-roadmap] profile) pin
down where reconvergence happens, which constrains how a compiler may restructure
control flow around subgroup operations.

---

## The interface between shader and host

### Interface variable

A module-scope variable through which a shader exchanges data with the stages around
it: `Input` and `Output` storage class variables, decorated with a `Location` (or
`BuiltIn`) ([SPIR-V §2.16][spirv-validation]). A vertex shader's outputs and a
fragment shader's inputs are linked by location in Vulkan and modern GLSL, and by
name in GLSL ES 1.00 and OpenGL without explicit locations.

### Built-in variable

An interface variable whose meaning the pipeline defines, decorated `BuiltIn`
instead of `Location`: `FragCoord`, `Position`, `VertexIndex`, `GlobalInvocationId`,
`SubgroupLocalInvocationId`, … (GLSL `gl_FragCoord`, HLSL `SV_Position`, WGSL
`@builtin(position)`, MSL `[[position]]`).

### Interpolation qualifiers

How a fragment input is computed from the vertices of its primitive: perspective
correct by default, `flat` (taken from one vertex; required for integers),
`noperspective` (linear in screen space), `centroid` and `sample` (where in the pixel
it is evaluated). SPIR-V decorations `Flat`, `NoPerspective`, `Centroid`, `Sample`.

### Descriptor, descriptor set and binding

A **descriptor** is the host's handle to a resource (a buffer, an image, a sampler)
that a shader reads through a variable. Vulkan groups descriptors into **descriptor
sets** and addresses each by `(set, binding)`, decorated `DescriptorSet` and `Binding`
on the variable. HLSL spells the same thing `register(t0, space1)` plus a root
signature on D3D12; MSL uses argument buffers; WGSL `@group(g) @binding(b)`;
OpenGL has texture units and uniform locations instead. **Bindless** (descriptor
indexing, `ResourceDescriptorHeap`) indexes a large array of descriptors at run time,
with `NonUniform` decorating an index that may differ per invocation.

### Uniform, uniform block and push constant

A **uniform** is a value constant over one draw. OpenGL allows loose uniforms (one
per name, set with `glUniform*`); Vulkan does not — SPIR-V for Vulkan forbids a
non-opaque `UniformConstant` variable (VUID-StandaloneSpirv-UniformConstant-04655),
so every value sits in a **uniform block** (a `Block`-decorated struct in the
`Uniform` storage class; a UBO; an HLSL `cbuffer`) or in a **push constant** block
(`PushConstant` storage class: a small block written into the command buffer).
This difference is why a single-source design that serves both OpenGL and Vulkan
consumers needs two uniform shapes.

### Specialization constant

A constant whose value the host chooses when it creates the pipeline, after the
shader is compiled (`OpSpecConstant`, decorated `SpecId`; GLSL
`layout(constant_id = N)`, HLSL `[[vk::constant_id(N)]]`, WGSL `override`, MSL
`function_constant`). Translators to languages without them lower them to macros.

---

## Memory

### Storage class (address space)

Where a pointer points ([SPIR-V §3.7][spirv-storage]): `Function` (private to an
invocation), `Private` (module-scope, per invocation), `Workgroup` (shared by a
workgroup), `Uniform` and `StorageBuffer` (descriptors' memory), `PushConstant`,
`Input`/`Output`, `PhysicalStorageBuffer` (raw device addresses), `CrossWorkgroup`
(OpenCL's global memory). LLVM IR spells storage classes as numbered address spaces;
each frontend and the [LLVM SPIR-V backend](./llvm-spirv-backend.md) agree on a
mapping.

### Logical and physical addressing

SPIR-V for Vulkan uses the `Logical` addressing model: pointers cannot be stored,
compared or computed from integers, only derived by access chains from a variable.
`PhysicalStorageBuffer64` (from `SPV_KHR_physical_storage_buffer`, Vulkan's
**buffer device address**) adds real 64-bit pointers into buffer memory, which a
shader may load from a buffer, offset with `OpPtrAccessChain`, and dereference with
an `Aligned` memory operand. OpenCL-flavoured SPIR-V uses `Physical64` throughout.

### Access chain

`OpAccessChain` derives a pointer to a member or element of a composite from a
pointer to the composite; its first index steps _into_ it. `OpPtrAccessChain` adds a
leading **element** index that steps the pointer itself, as C's `p[i]` does; in a
logical module it is valid only on physical pointers whose type carries an
`ArrayStride`.

### Buffer layout: std140, std430, scalar

The byte offsets of a block's members. **std140** (uniform blocks in GLSL) rounds
arrays and structs up to 16 bytes and places a `vec3` on a 16-byte boundary;
**std430** (storage blocks) drops the 16-byte rounding of arrays of scalars;
**scalar** (`VK_EXT_scalar_block_layout`, core but optional in Vulkan 1.2) aligns
every member to its scalar component — the C layout. A host-and-device struct means
the same bytes on both sides only under a layout both agree on; D's natural layout
is scalar's except for vector alignment.

### Memory model, scopes and semantics

The Vulkan memory model (`VulkanMemoryModel` capability) defines what one
invocation's writes mean to another: atomics and barriers carry a **scope**
(invocation, subgroup, workgroup, queue family, device) and **semantics** (acquire,
release, the storage classes they order). GLSL's `memoryBarrier*`, HLSL's
`*MemoryBarrierWithGroupSync` and MSL's `threadgroup_barrier(mem_flags)` are
spellings of fixed combinations.

---

## Control flow

### Structured control flow, merge and continue blocks

Shader SPIR-V must be **structured** ([SPIR-V §2.11][spirv-structured]): every
conditional branch or switch is preceded by `OpSelectionMerge`, naming the **merge
block** where its paths rejoin, and every loop header by `OpLoopMerge`, naming its
merge block and **continue target**. A **construct** — the blocks between a header
and its merge — may be left only through its merge (or as a `break` to the
innermost loop or switch, or a `continue`). The rule is what lets drivers and
translators rebuild `if`/`for`/`switch` from SPIR-V. Compilers whose IR has
unstructured branches (LLVM IR among them) need a **structurizer** to recover this
shape; see [LLVM SPIR-V backend](./llvm-spirv-backend.md),
[MLIR's SPIR-V dialect](./mlir-spirv.md) and [rust-gpu](./rust-gpu.md) for three
different answers.

### Reducible control flow

A control-flow graph is **reducible** when every loop has a single entry block.
Structured control flow requires it; LLVM's `FixIrreducible` pass makes a CFG
reducible by duplicating code or adding dispatch blocks.

---

## Toolchains

### SPIR-V, capability and extension

**SPIR-V** is the Khronos binary intermediate language for shaders and kernels,
consumed by Vulkan, OpenCL and (from Shader Model 7, announced) Direct3D 12. A module
declares the **capabilities** it uses (`OpCapability Shader`, `Int64`,
`GroupNonUniformBallot`, …) and the **extensions** that define them
(`OpExtension "SPV_KHR_…"`); a consumer rejects a module that declares what its
environment does not grant. `spirv-val --target-env vulkan1.3` checks a module
against Vulkan 1.3's rules, `--target-env spv1.6` against the universal rules only.

### DXIL

The intermediate language of Direct3D 12 (Shader Model 6.x): LLVM 3.7-era bitcode
plus a DirectX container, produced by [DXC](./dxc.md) and, in progress, by Clang's
DirectX backend ([Clang HLSL](./clang-hlsl.md)).

### Translator

A tool that turns one shader IR or language into another: [SPIRV-Cross](./spirv-cross.md)
(SPIR-V to GLSL, ESSL, HLSL, MSL), [naga](./naga.md) and [Tint](./tint.md) (WGSL
to and from SPIR-V and the platform languages). A translator's per-target limits are
the ceiling of every design that generates one IR and translates it.

### Single-source

A program whose host code and device code are written in one language, in one
source tree, and share types and functions: CUDA's `__host__ __device__` functions,
SYCL kernels, rust-gpu's shared crates, sparkles' host-and-device D modules
([dcompute](./dcompute.md)). The opposite is a separate shading language compiled on
its own, with layouts and constants kept in sync by hand.

---

## Spellings across languages

| Concept                 | SPIR-V                      | GLSL                       | HLSL                           | WGSL                    | MSL                               |
| ----------------------- | --------------------------- | -------------------------- | ------------------------------ | ----------------------- | --------------------------------- |
| Fragment stage          | `Fragment`                  | `.frag`                    | `[shader("pixel")]`            | `@fragment`             | `fragment`                        |
| Workgroup size          | `LocalSize`                 | `layout(local_size_x = N)` | `[numthreads(x, y, z)]`        | `@workgroup_size(x)`    | dispatch-time                     |
| Fragment position       | `BuiltIn FragCoord`         | `gl_FragCoord`             | `SV_Position`                  | `@builtin(position)`    | `[[position]]`                    |
| Subgroup                | `GroupNonUniform*`          | `subgroup*`                | `Wave*`                        | `subgroup*` (extension) | `simd_*`                          |
| Resource binding        | `DescriptorSet` + `Binding` | `layout(set, binding)`     | `register` + `[[vk::binding]]` | `@group` + `@binding`   | `[[buffer(n)]]`, argument buffers |
| Workgroup memory        | `Workgroup`                 | `shared`                   | `groupshared`                  | `var<workgroup>`        | `threadgroup`                     |
| Specialization constant | `OpSpecConstant`            | `constant_id`              | `[[vk::constant_id]]`          | `override`              | `function_constant`               |
| Device address          | `PhysicalStorageBuffer`     | `buffer_reference`         | `vk::RawBufferLoad`            | —                       | `device T*`                       |

## Sources

- [SPIR-V specification, unified][spirv-spec] — §2.11 structured control flow, §2.16
  validation rules, §3.3 execution models, §3.7 storage classes.
- [Vulkan specification — SPIR-V environment][vk-spirv-env] — the Vulkan rules for
  SPIR-V modules, including the `VUID-StandaloneSpirv-*` checks `spirv-val` reports.
- [WGSL — uniformity analysis][wgsl-uniformity].
- [Vulkan Roadmap profiles][vk-roadmap] — Roadmap 2022 and 2024 requirements.

<!-- References -->

[spirv-spec]: https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html
[spirv-exec-model]: https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html#Execution_Model
[spirv-storage]: https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html#Storage_Class
[spirv-structured]: https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html#_structured_control_flow
[spirv-validation]: https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html#_validation_rules
[vk-spirv-env]: https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html#spirvenv
[wgsl-uniformity]: https://www.w3.org/TR/WGSL/#uniformity
[vk-roadmap]: https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html#roadmap
