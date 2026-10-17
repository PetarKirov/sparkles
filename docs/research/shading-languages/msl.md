# MSL (Apple / Metal)

The Metal Shading Language: a C++17 dialect compiled by Clang/LLVM to Apple's AIR, with real pointers in typed address spaces, templates, and hardware features no other mainstream shading language exposes in source — argument buffers, tile shaders and imageblocks, visible function tables, `simdgroup_matrix` and, since Metal 4, tensors.

| Field          | Value                                                                                                                                                     |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | Metal Shading Language (MSL); C++17-based from Metal 4, C++14-based before                                                                                |
| License        | Proprietary specification (© Apple Inc.); the compiler ships with Xcode and the Metal Developer Tools for Windows                                         |
| Repository     | None public — the compiler is closed source                                                                                                               |
| Documentation  | [Metal Shading Language Specification, Version 4.1][msl-pdf] (PDF, 383 pages, dated 2026-06-04) · [Metal documentation][metal-docs]                       |
| Category       | Language (source); the only shader source language Metal accepts (besides prebuilt `metallib` from other front ends)                                      |
| Latest version | MSL 4.1 (specification dated 2026-06-04); Metal 4 introduced C++17, tensors and Metal Performance Primitives                                              |
| Targets        | AIR → `metallib` for Apple GPUs (macOS, iOS, iPadOS, visionOS); reached from SPIR-V via SPIRV-Cross and from DXIL via [Metal shader converter][converter] |

> [!NOTE]
> Apple publishes the specification only as a PDF without stable anchors. Citations below give the PDF's own section numbers (e.g. "§2.13") and were checked against the 4.1 edition text.

---

## Overview

### What it solves

MSL is one language for every programmable stage of Apple's GPUs — vertex, fragment, kernel (compute), tile, object and mesh, plus intersection and visible functions — designed alongside a tile-based deferred-rendering (TBDR) architecture whose on-chip tile memory the language exposes directly. The specification's purpose statement ([§1.1][msl-pdf]):

> _"MSL is a single, unified language that allows tighter integration between the graphics and compute programs. Since MSL is C++-based, you will find it familiar and easy to use. […] Metal uses clang and LLVM so you get a compiler that delivers optimized performance on the GPU."_

For `sparkles:shaders`, MSL is the target for every Apple platform (OpenGL is deprecated there and Vulkan exists only through MoltenVK, which itself translates SPIR-V to MSL with SPIRV-Cross). It is also the most instructive peer: a general-purpose systems language (C++) restricted to a GPU subset, with pointers that carry their address space in the type — the closest existing shape to "single-source D".

### Design philosophy

MSL starts from C++ and subtracts. §1.5 frames the whole language that way:

> _"In Metal 4 and later, the Metal programming language is a C++17-based specification with extensions and restrictions. […] Prior language versions of Metal are a C++14-based specification with extensions and restrictions."_

The restrictions (§1.5.4) are the set any GPU subset of a systems language arrives at: no `dynamic_cast` or RTTI, no `new`/`delete` (placement `new` from Metal 4.1), no `noexcept`, _"goto statement"_, `thread_local`, _"virtual function attribute"_, _"derived classes"_ or exceptions, and _"Do not use the C++ standard library in Metal code. Instead, Metal has its own standard library."_ Pointers stay, but are disciplined: _"You must declare arguments to Metal graphics and kernel functions that are pointers with the Metal device, constant, threadgroup, threadgroup_imageblock, object_data, or ray_data address space attribute."_ Two subtractions were later relaxed — _"Metal 2.3 and later support function pointers"_ and _"Metal supports recursive function calls […] in compute (kernel) context starting with Metal 2.4"_ — so MSL is the one mainstream shading language with indirect calls and (kernel-only) recursion.

## How it works

Entry points are qualified functions (§5.1): `[[vertex]]`, `[[fragment]]`, `[[kernel]]`, `[[visible]]`, `[[stitchable]]`, `[[intersection(…)]]`, `[[object]]`, `[[mesh]]`, and tile functions (§5.1.9). Arguments carry binding and built-in attributes in C++11 attribute syntax:

```cpp
#include <metal_stdlib>
using namespace metal;

struct VertexOut { float4 pos [[position]]; float2 uv; };

struct Material {                       // an argument buffer (§2.13)
    texture2d<float> albedo [[id(0)]];
    sampler          smp    [[id(1)]];
    constant float4 *tint   [[id(2)]];
};

constant bool kUseTint [[function_constant(0)]];   // specialization (§5.8)

fragment float4 fs(VertexOut in [[stage_in]],
                   constant Material &mat [[buffer(0)]],
                   uint prim [[primitive_id]])
{
    float4 c = mat.albedo.sample(mat.smp, in.uv);
    if (kUseTint) c *= *mat.tint;
    return c;
}

kernel void reduce(device const float *src [[buffer(0)]],
                   device atomic_float *dst [[buffer(1)]],
                   uint gid [[thread_position_in_grid]])
{
    float s = simd_sum(src[gid]);                  // SIMD-group reduction (§6.10.2)
    if (simd_is_first()) atomic_fetch_add_explicit(dst, s, memory_order_relaxed);
}
```

Bindings are flat per-kind slots (`[[buffer(n)]]`, `[[texture(n)]]`, `[[sampler(n)]]`) or members of argument buffers; vertex input arrives as a `[[stage_in]]` struct whose members carry `[[attribute(n)]]`. Since Metal 3.1 built-ins and bindings may also be program-scope globals (§5.9) _"in a kernel (including tile), mesh, or object context"_, so they need not be threaded through parameters.

## Execution model and stages

| Stage / function kind    | Attribute                               | Since                        | Notes                                                                                                      |
| ------------------------ | --------------------------------------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Vertex, fragment, kernel | `vertex`, `fragment`, `kernel`          | Metal 1                      | fragment inputs may include `[[color(m)]]` — programmable blending (framebuffer fetch)                     |
| Post-tessellation vertex | `[[patch(triangle \| quad, N)]] vertex` | Metal 1.2                    | tessellation factors come from a compute kernel; there is no hull/TCS stage in the language                |
| Tile                     | tile kernel/fragment (§5.1.9)           | iOS Metal 2, macOS Metal 2.3 | _"a special type of compute kernel or fragment function that can execute inline with graphics operations"_ |
| Object, mesh             | `[[object]]`, `[[mesh]]`                | Metal 3                      | `mesh<V, P, NV, NP, topology>`, `object_data` payload, `mesh_grid_properties` (§2.20)                      |
| Visible / intersection   | `[[visible]]`, `[[intersection(…)]]`    | Metal 2.3                    | called through `visible_function_table` or `intersect()`; ray tracing is inline (`intersector<>`)          |
| Geometry                 | —                                       | —                            | **no geometry stage**                                                                                      |

Kernel, vertex and fragment functions _"can't call one another without triggering a compilation error, but they may call other functions that use the [[visible]] attribute"_ (§5.1). Ray tracing has no pipeline of separate stages as in Vulkan or DXR: a kernel, vertex, fragment or tile function builds an `intersector<>` or `intersection_query` and traverses an `acceleration_structure` inline, calling intersection functions through tables (§2.17, §6.19).

Execution scopes are thread, SIMD-group, quad-group and threadgroup. **Uniformity is declared, not inferred**: `uniform<T>` (§2.14) marks a value the author promises is the same across the draw or dispatch — _"If a variable is of the uniform type, and the variable does not have the same value for all threads executing the kernel or graphics function, then the behavior is undefined"_ — and the compiler enforces only the direction of conversion: _"assigning a nonuniform variable to a uniform variable results in a compile-time error."_ SIMD-group matrices likewise require that _"all operations must be executed only under uniform control-flow within the SIMD-group or the behavior is undefined"_ (§2.4). WGSL's mandatory analysis (see [`wgsl.md`][wgsl]) and MSL's opt-in type are the two ends of the design space.

## Type system and generic programming

| Family      | Types                                                                                                                                                               |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scalars     | `bool`, `char`/`uchar`, `short`/`ushort`, `int`/`uint`, `long`/`ulong`, `half`, `bfloat` (Metal 3.1), `float`; no `double`                                          |
| Vectors     | `vec<T, n>` and aliases `float3`, `half4`, …; `packed_float3` etc. (§2.2.3); lvalue swizzles (`v.xz = …`)                                                           |
| Matrices    | `matrix<T, c, r>` / `float4x4`, column-major                                                                                                                        |
| Cooperative | `simdgroup_matrix<T, 8, 8>` with `half`, `bfloat`, `float` (§2.4); `tensor<…>`, inline tensors, `cooperative_tensor` (§2.22, Metal 4)                               |
| Resources   | `texture2d<T, access>`, `depth2d`, `texture_buffer`, `sampler`, `array<T, N>` of textures, `acceleration_structure`, `visible_function_table<Sig>`, `imageblock<T>` |
| Packed      | packed block-scaling numeric types (§2.21, Metal 4.1)                                                                                                               |

**Generic programming is C++'s**: function and class templates, overloading (extended to overload on address space, §1.5.1), `constexpr`, lambdas from Metal 3.2, the preprocessor. Graphics and kernel entry functions themselves cannot be overloaded. Templates are monomorphised by Clang before AIR, so generics cost nothing at run time — the same model D templates give.

**Size and alignment differ from GLSL and WGSL in the place that matters most.** Table 2.3 gives `float3` size **16** and alignment 16, while `packed_float3` has size 12 and alignment 4. This is exactly the host `vec3` that `sparkles:shaders` chose — a 16-byte, 16-aligned struct with a packed 12-byte variant ([`decisions.md`][sparkles-decisions] D9) — whereas WGSL's `vec3<f32>` is size 12, alignment 16, and GLSL `std140`/`std430` let a scalar occupy the padding. A D struct holding `vec3` therefore matches MSL's natural layout and neither of the others.

## Resources, interfaces and memory layout

**Address spaces** (§4) are part of every pointer and reference type: `device` (read-write buffers), `constant` (read-only, cacheable), `thread`, `threadgroup`, `threadgroup_imageblock` (tile memory), `ray_data` (intersection payload, Metal 2.3) and `object_data` (mesh payload, Metal 3). §4 calls them _"disjoint address spaces that can also specify access restrictions"_. Pointers support arithmetic, casts within a space, and storage in structs — physical addressing in source, unlike WGSL and logical Vulkan SPIR-V.

**Argument buffers** (§2.13, Metal 2) are Metal's bindless model:

> _"Argument buffers extend the basic buffer types to include pointers (buffers), textures, texture buffers, and samplers. However, argument buffers cannot contain unions."_

Members are numbered with `[[id(n)]]` (_"Manually assigned indices do not need to be contiguous, but they must be monotonically increasing"_); arrays of textures consume one id per element. Tier 2 hardware (§2.13.1) adds pointer indexing over arrays of argument buffers and copying resources between structures inside a function — what GPU-driven pipelines need. A Vulkan descriptor set maps onto one argument buffer, which is how SPIRV-Cross (`--msl-argument-buffers`) and Apple's Metal shader converter (which requires Tier 2) translate.

**Imageblocks** (§2.11) are _"a 2D data structure (represented by width, height, and number of samples) allocated in threadgroup memory"_ with an opaque layout, read and written per pixel by fragment and tile functions — explicit control of TBDR tile memory with no GLSL or HLSL equivalent (Vulkan's closest analogues are subpass inputs and `GL_EXT_shader_tile_image`; WebGPU's is Chromium's experimental pixel-local storage).

**Function constants** (§5.8, `[[function_constant(i)]]`, index 0–65535) are specialization constants that can also remove arguments, set binding indices and mark struct members optional, moving variant generation _"to the creation of the pipeline state, so you don't have to compile the variants offline."_

**Coherency** (§4.8, Metal 3.2): thread, threadgroup and device coherence scopes, with `coherent(device)` buffers and `memory_coherence_device` textures on Apple silicon.

## Built-in library and intrinsics

The Metal standard library (§6) covers common, integer, relational, math (`precise::` and `fast::` variants), matrix, SIMD-group matrix (`simdgroup_load`, `simdgroup_multiply_accumulate`, §6.8), geometric, synchronisation (`threadgroup_barrier(mem_flags::mem_threadgroup)`), SIMD-group functions (`simd_sum`, `simd_prefix_exclusive_sum`, `simd_shuffle_xor`, `simd_ballot`, `simd_is_first`, §6.10.2), quad-group functions (§6.10.3), graphics (`discard_fragment`), pull-model interpolation (`interpolant<T, P>` with `interpolate_at_centroid/sample/offset`, §6.12), texture member functions (`sample`, `read`, `write`, `gather`, `get_width`), imageblock functions (§6.14), packing, atomics (§6.16), indirect command buffer encoding from the GPU (§6.17), variable rasterization rate (§6.18), ray tracing (§6.19) and `os_log` logging (§6.20, Metal 3.2). Metal Performance Primitives (§7) add `mpp::tensor_ops::matmul2d` and `convolution2d` at thread, SIMD-group or threadgroup execution scope.

Metal 4.1 added (§1.3) placement new, a round-toward-zero default for float-to-float conversion, `function_id` in intersection results, packed block-scaling types, multiplane tensors, `interleave`/`deinterleave`, **memory order** — _"Support for memory order (including acquire and release) to barriers and atomics"_ — and clamp-to-edge and multi-pixel texture reads.

**Precision is a compiler mode, and fast is the default.** §1.6.3: `-fmetal-math-fp32-functions=<fast|precise>` — _"The default is fast"_ — and `-fmetal-math-mode=<fast, relaxed, safe>`, where fast assumes _"no NaNs, no INFs, no signed zeros, allow reciprocal, allow reassociation, and FP contract to be fast."_ Chapter 8 gives two tables: Table 8.1 (precise; `sin`, `cos` ≤ 4 ULP, `atan` ≤ 5 ULP, `x / y` correctly rounded) and Table 8.2 (fast; `sin(x)`/`cos(x)` absolute error ≤ 2⁻¹³ on [−π, π], `x / y` ≤ 2.5 ULP). Both are tighter than the Vulkan bounds `sparkles:shaders` judges agreement by ([`D12`][sparkles-d12]), so a D12-conformant CPU reference stays conformant on Metal.

## Control flow, memory model and restrictions

| Rule                                       | MSL                                                                                                     |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| `goto`                                     | not available (§1.5.4)                                                                                  |
| Recursion                                  | kernels only, Metal 2.4+ (§1.5.4)                                                                       |
| Function pointers / indirect calls         | Metal 2.3+, through `[[visible]]` functions and `visible_function_table<Sig>` (§2.15)                   |
| Virtual functions, inheritance, exceptions | not available (§1.5.4)                                                                                  |
| Atomics                                    | `memory_order_relaxed` historically; acquire/release/acq_rel from Metal 4.1 (§6.16)                     |
| Uniformity                                 | undefined behaviour if a `uniform<T>` diverges or a SIMD-group matrix op runs in divergent control flow |
| Vertex-to-fragment buffer writes           | _"not guaranteed to be visible"_ (§5.11)                                                                |

Because `goto` is absent, MSL source is structured; translators from SPIR-V (SPIRV-Cross) and from DXIL (Metal shader converter) must structurise before emitting it, as they must for GLSL.

## Compilation pipeline and targets

```text
.metal (MSL) ── metal (Clang) ──► .air (LLVM-based AIR) ── metallib ──► .metallib ──► MTLLibrary
SPIR-V ── SPIRV-Cross --msl ──► .metal               (MoltenVK; a sparkles:shaders route)
DXIL   ── Metal shader converter ──► .metallib       (SM 6.0–6.6; Argument Buffers Tier 2)
```

MSL may be compiled at run time from source (`newLibraryWithSource`) or offline to a `metallib`; §1.6.15 adds options for compiling to GPU binaries. Because AIR is LLVM-based and undocumented, no third-party compiler emits it directly; every non-Apple language reaches Metal through MSL source or through DXIL and the shader converter, which supports _"SM6.0 … SM6.6"_ (wave intrinsics through dynamic resources and compute derivatives) and requires _"a device supporting Argument Buffers Tier 2"_ running macOS 14 / iOS 17 ([converter page][converter]).

For a SPIR-V producer the practical route is SPIRV-Cross's MSL backend (see [`spirv-cross.md`][spirv-cross]): it emits vertex, fragment, kernel, emulated tessellation and mesh/object functions, maps `PhysicalStorageBuffer` to `device` pointers (the only backend where `OpPtrAccessChain` works), descriptor sets to argument buffers, specialization constants to `[[function_constant(N)]]`, and gates features from MSL 1.1 to 4.0 — but has no geometry-shader or ray-tracing-pipeline support.

## Host integration and CPU execution

MSL has no host-language integration beyond C++ syntax: Swift or Objective-C host code creates `MTLLibrary`/`MTLFunction` objects by name, sets function-constant values in an `MTLFunctionConstantValues`, and binds by slot index or by encoding argument buffers; reflection comes from `MTLFunction`/pipeline reflection objects. Metal 4 adds tensors as shared host/GPU resources, but there is **no CPU execution path**: MSL headers are not usable as ordinary C++ on the CPU (address-space attributes, `[[…]]` built-ins and the Metal standard library are GPU-only). Sharing a struct between Swift/C and MSL is done through a common C header and `simd` types, whose `simd_float3` is likewise 16 bytes — the same layout bargain `sparkles:shaders` makes with its host `vec3`.

## Lessons for sparkles:shaders

- **Adopt address spaces in the pointer type.** MSL proves a C-family language can keep real pointers on the GPU if each carries its space (`device`, `constant`, `threadgroup`, `thread`); D can express the same with dcompute-style `GlobalPointer!T`/`SharedPointer!T` or a `Ptr!(T, AddressSpace.device)` template, with overloading per space done by templates rather than C++'s address-space overloads.
- **Keep `vec3` at 16 bytes; it is MSL's natural layout.** The existing D9 choice matches `float3`/`simd_float3` exactly, so host structs can be shared with Metal unchanged; offer `Vec3Packed` for `packed_float3`. Add a layout test in the conformance corpus that checks `sizeof`/`offsetof` of a `vec3`-containing struct against MSL Table 2.3, WGSL's table and `std430`.
- **Model argument buffers as structs of resources, not descriptor-set numbers.** A D `struct Material { Texture2D!float albedo; Sampler smp; const(float4)* tint; }` passed as one parameter maps to an argument buffer on Metal, a descriptor set on Vulkan and a parameter block on Slang; the emitter assigns `[[id(n)]]` and accounts for arrays consuming several ids.
- **Offer `Uniform!T` as an explicit uniformity type.** MSL's `uniform<T>` (convertible to non-uniform, never the reverse) is a cheap, checkable annotation that also documents intent for WGSL's analysis and lets the backend emit `uniform<T>` or scalar loads.
- **Match MSL by refusing what it refuses, and gate what it alone allows.** Reject `goto`, classes with virtuals, exceptions and recursion in portable device code; treat function pointers, kernel recursion, imageblocks, tile functions and tensors as Metal-tier features behind a capability check, since SPIR-V→GLSL/WGSL paths cannot carry them.
- **Specify the precision mode the emitter requests.** Metal compiles fast math by default; the MSL emitter should pass `-fmetal-math-mode=safe` (or `relaxed`) when the D source relies on NaN/Inf, and the CPU simulator should document which mode its agreement tests assume.
- **Avoid depending on a geometry stage** in the vocabulary's core: Metal has none and SPIRV-Cross cannot emulate it, so geometry belongs in a desktop-only tier next to mesh shading as the portable replacement.

## Strengths

- **A real systems language on the GPU**: templates, overloading, lambdas, real pointers, function pointers, kernel recursion, placement new.
- **Hardware exposed in source**: tile memory (imageblocks, tile functions), programmable blending, raster order groups, argument buffers, SIMD-group matrices, tensors and Metal Performance Primitives.
- **Clear numerical tables**, both precise and fast, tighter than Vulkan's.
- **Clang/LLVM front end**, so C++ tooling, diagnostics and optimisation apply.

## Weaknesses

- **Apple-only and closed**: no public compiler, no documented IR, specification as a PDF without anchors.
- **Fast math by default**: NaN/Inf and signed-zero behaviour depend on compiler flags, not source.
- **No geometry stage, tessellation only via compute plus post-tessellation vertex functions**; ray tracing only inline.
- **Uniformity unchecked**: `uniform<T>` and SIMD-group matrix rules are promises with undefined behaviour on violation.
- **Binding model differs from Vulkan's** (flat slots or argument-buffer ids, arrays consuming several ids), so every translator needs a remapping layer.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                        | Trade-off                                                                 |
| ------------------------------------------------ | ---------------------------------------------------------------- | ------------------------------------------------------------------------- |
| C++ (14, then 17) minus a fixed list of features | familiar language, Clang/LLVM reuse, templates for free          | the GPU subset is defined by exclusion; C++ standard library unusable     |
| Address space in every pointer type              | real pointers without a generic address space                    | overloads and templates multiply per space                                |
| Argument buffers as the bindless model           | resources are data; GPU-driven rendering                         | translation from descriptor sets needs id remapping; Tier 1/Tier 2 split  |
| Inline ray tracing with function tables          | one programming model across stages; no separate pipeline stages | no direct mapping from Vulkan/DXR ray-tracing pipelines in SPIRV-Cross    |
| Tile functions and imageblocks in the language   | exploit TBDR on-chip memory                                      | no counterpart on immediate-mode GPUs or in other languages               |
| `uniform<T>` declared, not inferred              | simple compiler; author states intent                            | violations are undefined behaviour                                        |
| Fast math as the default                         | performance on Apple GPUs                                        | portability of IEEE edge cases depends on build flags                     |
| `float3` sized 16                                | registers and loads stay 16-byte aligned                         | differs from WGSL (12) and GLSL `std430` packing; host structs must match |

## Sources

- [Metal Shading Language Specification, Version 4.1 (PDF, 2026-06-04)][msl-pdf] — §1.1 purpose, §1.3 new in 4.1, §1.5 and §1.5.4 C++17 and restrictions, §1.6.3 math options, §2.3–2.5 vectors, `simdgroup_matrix` and alignment (Table 2.3), §2.11 imageblocks, §2.13 argument buffers, §2.14 uniform type, §2.15 visible function table, §2.17 ray tracing, §2.20 mesh types, §2.22 tensors, §4 address spaces, §4.8 coherency, §5.1 functions and §5.1.9 tile functions, §5.8 function constants, §5.9 global built-ins, §5.11 restrictions, §6 standard library, §7 Metal Performance Primitives, §8.4 Tables 8.1–8.2
- [Metal documentation][metal-docs] · [Metal shader converter][converter] · [WWDC25 "Combine Metal 4 machine learning and graphics"][wwdc25]
- sparkles: [`decisions.md`][sparkles-decisions] (D9, D12)
- Related: [GLSL][glsl] · [HLSL][hlsl] · [WGSL][wgsl] · [Slang][slang] · [SPIRV-Cross][spirv-cross] · [concepts][concepts] · [comparison][comparison] · [index][index]

<!-- References -->

[msl-pdf]: https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf
[metal-docs]: https://developer.apple.com/documentation/metal
[converter]: https://developer.apple.com/metal/shader-converter/
[wwdc25]: https://developer.apple.com/videos/play/wwdc2025/262/
[sparkles-decisions]: ../../specs/shaders/decisions.md
[sparkles-d12]: ../../specs/shaders/decisions.md#d12-agreement-is-judged-by-the-vulkan-precision-table
[glsl]: ./glsl.md
[hlsl]: ./hlsl.md
[wgsl]: ./wgsl.md
[slang]: ./slang.md
[spirv-cross]: ./spirv-cross.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
