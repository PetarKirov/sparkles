# Vcc and Shady (C/C++ → Vulkan SPIR-V)

A research compiler from Saarland University that takes unmodified Clang's LLVM IR for ordinary C and C++, lowers it through its own GPU IR (Shady), and emits Vulkan-legal SPIR-V — emulating physical pointers, generic pointers, function pointers and recursion that the SPIR-V `Shader` dialect forbids. It is the closest architectural peer to an LLVM-IR-based D frontend.

| Field              | Value                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| Language           | Input: C11 / C++ (via Clang). Compiler: C11 (Shady) + Python code generators                                                           |
| License            | MIT ([`license.md`][license], "Copyright 2022 Hugo Devillers et al")                                                                   |
| Repository         | [shady-gang/shady][repo] (pinned `dd2787a7`, 2025-10-17; 2,829 commits since 2022-02-24) · NASL submodule [shady-gang/nasl][nasl]      |
| Documentation      | [`readme.md`][readme] · [Vcc website][vcc-site] · HPG 2025 paper ["No More Shading Languages: Compiling C++ to Vulkan Shaders"][paper] |
| Key authors        | Hugo Devillers, M. Kurtenacker, R. Membarth, S. Lemme, M. Kenzel, Ö. Yazici, P. Slusallek (UdS / THI / DFKI)                           |
| Category           | Single-source peer: general-purpose language → shader SPIR-V through LLVM IR                                                           |
| Latest version     | No tagged releases; pinned at commit `dd2787a7ebf7` ("update dependencies", 2025-10-17)                                                |
| Targets            | SPIR-V (Vulkan, `Shader` + `Logical`/`PhysicalStorageBuffer64`); C-family backend dialects C11, GLSL, ISPC, CUDA                       |
| Stages             | Vertex, fragment, compute, ray generation (+ callable shaders as a call-lowering strategy)                                             |
| Frontends          | LLVM IR (Vcc, via LLVM-C), SPIR-V, and Shady's own textual "slim" language                                                             |
| Runtimes (testing) | `shd_rn_*` runner over Vulkan and CUDA ([`runner.h`][runner])                                                                          |

> [!NOTE]
> The pinned [`readme.md`][readme] says Vcc lives "inside `src/frontends/llvm` and `src/driver/vcc.c`". At `dd2787a7` the LLVM frontend is `src/frontend/llvm/` and the Vcc driver is [`vcc/vcc.c`][vcc-main] + [`vcc/vcc_lib.c`][vcc-lib]; the README's paths are stale. All citations below use the real paths.

---

## Overview

### What it solves

Shading languages (GLSL, HLSL) and the SPIR-V `Shader` dialect they compile to forbid what every general-purpose systems language assumes: pointers with an observable bit pattern, a generic address space, recursion, and indirect calls. Compute platforms (CUDA, SYCL) have those features but no access to the graphics pipeline. Vcc asks whether Vulkan itself can become the "best of both worlds" API by compiling **unrestricted** C++ to Vulkan shaders, so that host and device share code. From the paper's abstract ([HPG 2025][paper]):

> _"We propose reframing shading languages as embedded domain-specific languages, layered on top of a more general language like C++, doing away with traditional limitations on pointers, functions, and recursion, to the benefit of programmability. This represents a significant compilation challenge because the limitations of shaders are reflected in their lower-level representations."_

The approach uses an **unmodified Clang** as the frontend; the shading-language features become a header library (NASL, "Not A Shading Language") plus Clang `annotate` attributes. Everything else is the job of Shady: re-deriving what LLVM IR lost (structure, logical addressing) and emulating what Vulkan lacks.

### Design philosophy

Two theses run through the paper and the tree.

1. **A shading language is a library plus a handful of annotations.** The paper (§4.3) concludes: _"shading languages just do not have a lot of shading functionality, and what they have does not require them to be separate languages."_ Its procedural-terrain port shows the corollary (§6.3): _"C++ shaders that do not rely on the features we covered in Section 5 simply compile down to something equivalent to their GLSL counterparts. Yet the benefits of code sharing and compile-time C++ features like templates remain."_
2. **The input language should not be restricted; the compiler emulates.** Shady's README states the goal: _"Shady was built for emulating a better programming model on top of Vulkan shaders, and this remains the primary use-case."_ It lists as working: _"True function calls (thanks to a CPS transformation)"_, _"Arbitrary control flow inside functions: `goto`, including non-uniform is allowed"_, _"Physical pointers (cast-able pointers where the layout of objects in memory is observable)"_ for private and shared memory, and _"Generic (tagged) pointers"_ ([`readme.md`][readme]).

Because the frontend is unmodified Clang, the paper notes (Appendix A) that _"the limitations are actually entirely dictated by the subset of LLVM IR we support."_ That sentence is exactly the position LDC's dcompute is in — see [Lessons](#lessons-for-sparklesshaders).

---

## How it works

### The driver: Clang to textual LLVM IR

[`vcc_run_clang`][vcc-lib] shells out to Clang with a fixed command line and reads back textual IR:

```c
// vcc/vcc_lib.c (vcc_run_clang)
shd_growy_append_formatted(g, " -c -emit-llvm -S -g -O0 -ffreestanding -Wno-main-return-type -isystem\"%s\" -D__SHADY__=1", ...);
if (shd_get_linked_major_llvm_version() < 20) {
    shd_growy_append_string(g, " --target=spir64-unknown-unknown");
    shd_growy_append_string(g, " -Xclang -fpreserve-vec3-type");
} else {
    shd_growy_append_string(g, " --target=spirv64-unknown-unknown");
}
```

Three details matter for a D port: the IR is produced at **`-O0`** (Shady runs its own folding and `mem2reg`-style cleanup); the triple is the **OpenCL-flavoured `spir64`/`spirv64`**, so Clang's address-space numbering is the SPIR one (generic 0, global 1, shared 3, private 5); and `-fpreserve-vec3-type` keeps `vec3` from being widened to `vec4`. [`shd_parse_llvm`][l2s] then parses the text with `LLVMParseIRInContext` (LLVM-C, linked as a library) and converts functions and globals into a "dirty" Shady module.

### Annotations as the language extension

[`vcc/include/shady.h`][shady-h] is the whole "language": macros over `__attribute__((annotate(...)))` and `address_space(N)`:

```c
// vcc/include/shady.h
#define fragment_shader __attribute__((annotate("shady::entry_point::Fragment")))
#define location(i)            __attribute__((annotate("shady::location::"#i)))
#define descriptor_set(i)      __attribute__((annotate("shady::descriptor_set::"#i)))
#define descriptor_binding(i)  __attribute__((annotate("shady::descriptor_binding::"#i)))
#define local_size(x, y, z)    __attribute__((annotate("shady::workgroup_size::"#x"::"#y"::"#z)))
#define input                  __attribute__((annotate("shady::io::389")))
#define push_constant          __attribute__((annotate("shady::io::392")))
#define global                 __attribute__((address_space(1)))
#define shared                 __attribute__((address_space(3)))
#define private                __attribute__((address_space(5)))

float sqrtf(float f) __asm__("shady::prim_op::sqrt");
```

The `shady::io::NNN` numbers are Shady address-space ids (389 = `Input`, 390 = `Output`, 392 = `PushConstant`), the same `llvm-id` values that [`grammar.json`][grammar] assigns, and `l2s_convert_llvm_address_space` (generated by [`generator_l2s.py`][l2s-gen]) maps any unknown number to `AsGeneric` with a warning. Intrinsics are bound by **symbol name** (`__asm__("shady::prim_op::sqrt")`). Opaque SPIR-V types and instructions (images, samplers, `OpImageSampleImplicitLod`) are declared through a meta-encoding in [`shady_sample.h`][sample-h], where macros emit globals that the frontend decodes into SPIR-V opcodes (`__shady_declare_ext_type(sampler2D, 27, ...)`, `__shady_declare_ext_inst(spv_texture_sample, 87, ...)`). A complete fragment shader from the test suite ([`textured.frag.cpp`][textured]):

```cpp
// test/vcc/cpp/textured.frag.cpp
descriptor_set(0) descriptor_binding(1) uniform_constant sampler2D texSampler;
location(0) input native_vec3 fragColor;
location(1) input native_vec2 fragTexCoord;
location(0) output native_vec4 outColor;

extern "C" {
fragment_shader void main() {
    outColor = texture(texSampler, fragTexCoord) * (native_vec4) { fragColor.x * 2.5f, fragColor.y * 2.5f, fragColor.z * 2.5f, 1.0f };
}
}
```

Interface variables are **globals** with annotations (Circle's model, not rust-gpu's entry-parameter model — compare [Circle][circle] and [rust-gpu][rust-gpu]).

### The Shady IR

Shady is _"composed of mostly immutable structural nodes, with a sprinkling of nominal mutable nodes for things like functions and global variables"_; most optimisations are build-time folding in [`fold.c`][fold], and the grammar lives in [`grammar.json`][grammar], from which Python generators emit node hashing, rewriters and visitors ([`readme.md`][readme]). Two properties make it a good lowering target:

- **Hybrid CFG / structured.** Per the paper (Appendix A): _"We support the typical jump, branch, and return terminators found in SPIR-V or LLVM and we also have a structured flavor using if and loop terminators that correspond to SPIR-V's structured control flow primitives."_ Lowering can therefore move from unstructured to structured within one IR.
- **Uniformity in the type.** Every value carries a `QualifiedType` with a scope (`ShdScopeCrossDevice`, `Device`, `Workgroup`, `Subgroup`, `Invocation` in [`enum.h`][enum-h]); the scheduler source spells this `uniform`/`varying` (see below). This is the README's _"local uniformity analysis"_.

### The pipeline

[`shd_pipeline_add_shader_target_lowering`][pipeline] specialises the module to a target, an execution model and an entry point, then runs function-call emulation followed by feature lowering:

```c
// src/shader-pipeline/shader_pipeline.c
void shd_pipeline_add_feature_lowering(ShdPipeline pipeline, TargetConfig tgt) {
    shd_pipeline_add_memory_lowering(pipeline, tgt);
    shd_pipeline_add_polyfills(pipeline, tgt);
    shd_pipeline_add_restructure_cf(pipeline);
}
```

Every step is conditional on a `TargetConfig` capability. [`targets.c`][targets] sets the Vulkan defaults: `add_default_shading_language_limitations` turns off `native_fncalls`, `native_tailcalls`, `native_memcpy`, `native_stack`, `linkage`, makes every address space logical and disallows `AsGeneric`; SPIR-V then re-enables physical `AsGlobal` (_"default to assuming BDA support on Vulkan"_) and assumes a 64-wide subgroup _"to support GCN cards"_. The same pipeline with different capabilities serves CUDA (which has real calls and pointers).

---

## Execution model and stages

Entry points are functions annotated `vertex_shader`, `fragment_shader`, `compute_shader` or `ray_generation_shader` ([`shady.h`][shady-h]); `local_size(x, y, z)` gives the compute workgroup size. Built-in variables are globals pre-declared in the header with `shady::builtin::*` annotations: `gl_FragCoord`, `gl_Position`, `gl_WorkGroupID`, `gl_VertexIndex`, `gl_GlobalInvocationID`, `gl_LaunchIDEXT`, plus `subgroup_id` and `subgroup_local_id`. The pass `specialize_execution_model` / `specialize_entry_point` ([`passes/abi/`][spec-ep]) prunes a module down to one entry point, because `linkage` is off for shader targets ([`shader_pipeline.c`][pipeline] asserts both are set when linkage is unavailable).

The paper evaluates compute (micro-benchmarks, a path tracer) and one graphics pipeline (a procedural-terrain demo with vertex and fragment shaders). It states (§7.2) that graphics stages work but _"we did not evaluate it formally for such."_ No geometry, tessellation, mesh or task stage appears in `shady.h` at the pin.

A distinctive stage use: **callable shaders as a call mechanism.** With `use_rt_pipelines_for_calls`, the SPIR-V target sets `native_fncalls = true` and `rt_pipelines = true` ([`targets.c`][targets]); [`spirv_callable_shaders.c`][callable] turns the entry point into a ray-generation shader and every callee into a callable shader, mapping each function type to a global ray payload. The paper lists the costs (§5.3.3): two parallel stacks, and _"Ray tracing pipelines do not have workgroups or shared memory"_, with subgroup composition that the implementation may change.

## Type system and generic programming

The type system is **C++'s, unchanged**: templates, overloading, classes with non-virtual members, lambdas, unions and bitfields all arrive as LLVM IR. Shady's own types ([`grammar.json`][grammar]) are `Int`, `Float`, `Bool`, `StructType`, `ArrType`, `VectorType`, `MatrixType`, `PtrType` (with an address space), `FnType`, `JoinPointType` and `QualifiedType` (uniformity scope).

Vectors come in two forms. NASL provides `vec4`/`mat4` as C++ templates, and its swizzles are, per the paper (§4.1), _"a combination of macros and smart union members to offer arbitrary swizzles for up to 4 components."_ Where the interface needs a real SPIR-V vector (I/O variables), code uses Clang's `ext_vector_type` (`native_vec4` etc. in [`shady.h`][shady-h]), which has built-in swizzles. The paper notes Clang's OpenCL-mode swizzles were unavailable because Vcc uses the standard C++ frontend, and that _"More invasive modifications of Clang were avoided."_ D's `__vector` and `opDispatch` swizzles map onto the same split (see [GLSL][glsl] for the vocabulary they must match).

Generic programming needs nothing from Shady: templates are monomorphised by Clang before the IR exists. The only generic-programming feature Vcc declines is dynamic dispatch — **virtual functions are not implemented**, because _"sharing C++ objects from host and device would not result in portable vtables, which would make the feature a liability"_ (Appendix A). Function pointers, by contrast, are supported and are 64-bit integers that _"can be converted to integers, for example to implement sorting to combat divergence."_

## Resources, interfaces and memory layout

Resources are annotated globals: `uniform_constant` (images and samplers), `uniform_block`, `push_constant`, plus `descriptor_set(i)`/`descriptor_binding(i)` and `location(i)`. Storage buffers are reached as **physical pointers into global memory**: the aobench host passes a buffer device address as a kernel argument (`shd_rn_get_buffer_device_pointer`, then `shd_rn_launch_kernel(..., (void* []) { &buf_addr }, ...)` in [`ao_main.c`][ao-main]). When a `PtrType` targets `AsGlobal`, [`emit_spv_type.c`][emit-spv-type] switches the module to `SpvAddressingModelPhysicalStorageBuffer64` and emits `PhysicalStorageBufferAddresses`. The paper (§5.1.2): _"Recent versions of Vulkan do support physical pointers into global memory by enabling the PhysicalStorageBuffer feature, so we only apply this solution to Private and Shared memory."_

Layout is computed by Shady, not taken from a GLSL rule set. [`memory_layout.c`][mem-layout] lays structs out C-style (member offset rounded up to member alignment, size rounded up to the maximum alignment), with an open `TODO Vulkan vec3 -> vec4 alignment rules ?` on vectors. [`spirv_specialize_explicit_layout.c`][explicit-layout] decides which storage classes need `Offset`/`ArrayStride` decorations: SSBO, `Uniform` and `PushConstant` _"despite not being physical, they require explicit layout"_, plus any physical space. In other words Vcc relies on Vulkan's scalar-block-layout behaviour for buffers; there is no std140 mode at the pin (not verified against a std140 test — none found under `test/vcc/`).

## Built-in library and intrinsics

There is deliberately little. NASL supplies _"a sizable subset of the built-in types and functions found in GLSL"_ on a per-need basis: small vectors and swizzles, `mat4` with transposition and vector multiplication, normalisation, cross and dot product (paper §4.1). Math functions bind to Shady primops by symbol name — the aobench kernel declares `sqrtf`, `sinf`, `cosf`, `fmodf`, `fabsf`, `floorf` as `__asm__("shady::prim_op::...")` ([`ao.comp.cpp`][ao-comp]). Texture sampling is `texture1D/2D/3D/Cube` bound to `OpImageSampleImplicitLod` (opcode 87) through the meta-encoding in [`shady_sample.h`][sample-h].

The C and C++ standard libraries are **not** provided: _"Some of their functionality would require some sort of remote procedure call into the host"_ (Appendix A). There is `printf` debugging (README) and a `printf_trace.memory_accesses` mode that logs every emulated load and store ([`lower_physical_memory.c`][physical]). Subgroup operations are partly emulated: README marks wide ballots done and shuffles not; [`polyfill.c`][polyfill] runs `lower_subgroup_ops` (_"Emulates unsupported subgroup operations using subgroup memory"_) and `lower_int` (_"Emulates unsupported integer datatypes"_), while README leaves "Int8, Int16 and Int64 support everywhere" and "FP 64 emulation" unchecked. The paper's renderer _"currently does not use any subgroup intrinsics"_ (§7.2).

## Control flow, memory model and restrictions

This is the heart of the project. Each restriction of the `Shader` dialect has a dedicated emulation.

**Logical pointers → normalisation, then memory emulation.** SPIR-V logical pointers _"work similarly to C++ references: they cannot be offset or reinterpreted and while it is possible to select a sub-object, it is not possible to go back "up" from a sub-object to the parent object"_, and cannot be stored to memory (paper §5.1). Vcc's first line is **normalisation**: folding rules move casts and offsets to the end of a pointer computation, rewrite a load through a cast pointer as a load of the original type followed by a value cast, and _"if they only have logical pointer uses, we demote them to logical pointers that we can safely leave alone"_ (§5.1.1). What survives is **emulated**: [`lower_physical_memory.c`][physical] replaces every private, shared or subgroup allocation with one word array per space (`fake_private_memory`, `fake_shared_memory`, `fake_subgroup_memory`; `u32` words by default) and turns pointers into 32-bit indices, decomposing aggregates into words and bitcasting. The paper is candid: _"This approach gives us correct results for arbitrary pointer usage but is quite heavy-handed. Doing so obscures the original semantics of the program, notably because they remove explicit local allocations"_ (§5.1.2).

**Generic pointers → tagged integers.** Vulkan has no `OpPtrCastToGeneric`. [`lower_generic_ptrs.c`][generic] reserves the top 3 bits of a 64-bit pointer as an address-space tag:

```c
// src/shady/passes/ptr/lower_generic_ptrs.c
static AddressSpace generic_ptr_tags[8] = {
    [0x0] = AsGlobal,
    [0x1] = AsShared,
    [0x2] = AsSubgroup,
    [0x3] = AsPrivate,
    [0x7] = AsGlobal
};
static size_t generic_ptr_tag_bitwidth = 3;
```

Every generic load and store becomes a call to a generated `generated_load_Generic_<type>_<scope>` / `generated_store_...` leaf function that switches on the tag, strips it and sign-extends (tags 0 and 7 both mean global, so canonical high-half addresses survive). The paper flags the assumption: _"This tagging is well-defined on host architectures such as x86_64 because only the lower bits can be used in practice. Vulkan currently offers no such guarantees. However, we have experimentally found this to work across all the hardware we tested."_ (§5.2).

**Recursion and function pointers → CPS + software dispatcher.** The key observation (§5.3.1): _"SPIR-V is Effectively Stackless … It is perfectly possible for the implementation of a SPIR-V compiler to have no runtime function call support at all."_ [`cf.c`][cf] orders the passes:

```c
// src/shader-pipeline/cf.c (remove_indirect_calls)
if (!target_config->capabilities.native_stack)
    RUN_PASS(shd_pass_setup_stack_frames, config)
RUN_PASS(shd_pass_mark_leaf_functions, config)
if (!target_config->capabilities.native_fncalls) {
    RUN_PASS(shd_pass_lower_callf, config)
    RUN_PASS(shd_pass_inline, config)
    RUN_PASS(shd_pass_lift_indirect_targets, config)
    if (config->dynamic_scheduling)
        shd_add_scheduler_source(config, *pmod);
    RUN_PASS(shd_pass_mark_leaf_functions, config)
    RUN_PASS(shd_pass_lower_dynamic_control, config)
    RUN_PASS(shd_pass_lower_tailcalls, config)
}
```

1. [`mark_leaf_functions`][leaf] tags functions that make no indirect or recursive calls, transitively; they are simply inlined and pay nothing.
2. [`lower_callf`][callf] turns each non-leaf call into a CPS tail call inside a `control` construct: `f(...)` becomes `control(jp => f(..., jp))`, the join point carrying the return.
3. [`lift_indirect_targets`][lift] lambda-lifts the code after each call site into a top-level function, spilling live values to the stack (_"Extracts unstructured basic blocks into separate functions (including spilling)"_).
4. `lower_tailcalls` ([`software_dispatcher.c`][dispatcher]) assigns each function an integer and wraps the whole program in **one loop around one `switch`**: each iteration dispatches the next function id. The paper explains why it is a single top-level dispatcher (§5.3.2): _"if we instead used a switch at each indirect call-site there would be a recursive path in the function call graph, which SPIR-V shaders disallow."_

The stack is emulated memory: allocas are collected into a frame struct pushed on function entry ([`memory.c`][memory]: `lower_alloca`, `lower_stack_access`), sized at run time. In Private memory this _"tends to blow up register pressure"_, so Vcc also supports a stack in global memory divided between subgroups (§5.3.1). Divergent calls are handled by an optional **dynamic scheduler** written in Shady's slim language ([`scheduler.slim`][scheduler]): per-subgroup `resume_at` and `scheduler_vector` arrays, `builtin_fork` partitions the active mask by destination using `OpGroupNonUniformBallot`/`BroadcastFirst`, and `builtin_join`/`builtin_yield` pick the next schedulable leaf of a mask-and-depth tree. This is SIMT reconvergence re-implemented in software.

**Unstructured control flow → restructuring.** _"LLVM is an unstructured representation which lacks structured control-flow information"_ (§5.4), so Shady must rebuild `if`/`loop`. The LLVM frontend, by default `restructure_with_heuristics` ([`vcc_lib.c`][vcc-lib]), runs `remove_critical_edges`, `lcssa` and [`reconvergence_heuristics`][reconv] (loop-tree driven) at parse time ([`l2s.c`][l2s]); a `has_scope_annotations` path (scope → `control`) exists but is commented out in Vcc. The final [`restructure.c`][restructure] pass is a DFS structuriser: branches become `if`, back edges become `loop` with an exit "ladder", and `control`/`join` becomes a `level` variable plus guarded tails (its comment: `var phi = undef; level = N+1; structurize[body, if (level == N+1, _ => tail(load(phi))); structured_exit_terminator]`, the level held in a `cf_depth` local). It **bails** via `longjmp` on what it cannot handle — notably `IndirectTailCall` — and then copies the function body unlowered, which is why call lowering must run first.

**Memory model and reconvergence.** SPIR-V output uses `SpvMemoryModelGLSL450` ([`spirv_builder.c`][spv-builder]). The paper identifies maximal reconvergence as the semantics that needs structure (§5.4) and concludes (§7.2) that subgroup intrinsics were not used _"partly due to how LLVM does not provide us with the structured control flow we would need to implement Maximal Reconvergence."_

**What remains unsupported** (Appendix A): the C/C++ standard libraries, exceptions, virtual functions, and a unified host/device address space. `std::function` fails _"due to STL issues"_.

## Compilation pipeline and targets

```text
program.cpp ──clang -O0 --target=spirv64──▶ LLVM IR (text)
   ──l2s (LLVM-C)──▶ Shady (dirty) ──postprocess, restructure heuristics──▶ Shady
   ──target specialisation (exec model, entry point, subgroup size)──▶
   ──fncall emulation: setup_stack_frames, mark_leaf, lower_callf, lift, dispatcher──▶
   ──memory: promote_io, lower_logical_pointers, memcpy, alloca/stack, lea,
             generic_ptrs, physical_memory, subgroup_vars, memory_layout──▶
   ──polyfills: int, mask, fill, nullptr, subgroup_ops──▶
   ──restructurize──▶ backend: SPIR-V │ C11 │ GLSL │ ISPC │ CUDA
```

The paper's broad pass order is CPS transformation, closure conversion (lambda lifting), tail-call lowering, generic-pointer lowering, physical-pointer lowering, restructuring, with a cleanup phase (SSA construction after Braun et al., single-use block inlining, demotion of physical allocations to logical) iterated to a fixed point after each pass (Appendix A). The source matches that order ([`cf.c`][cf], [`memory.c`][memory], [`polyfill.c`][polyfill]).

Backends:

| Backend | Where                                         | Notes at the pin                                                                                                           |
| ------- | --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| SPIR-V  | [`src/backend/spirv/`][emit-spv]              | `Logical` addressing, upgraded to `PhysicalStorageBuffer64` on demand; `Shader` capability; `Linkage` only when allowed    |
| C11     | [`include/shady/be/c.h`][be-c] `CDialect_C11` | Host C; no shading-language limitations applied                                                                            |
| GLSL    | `CDialect_GLSL`, `glsl_version`               | Same logical limitations as SPIR-V; a GLSL 1.20 runtime prelude ([`runtime_120.glsl`][runtime-glsl]); README: _"untested"_ |
| ISPC    | `CDialect_ISPC`                               | [`runtime.ispc`][runtime-ispc] maps `uniform`/`varying`; README: _"useful for debugging on the host"_                      |
| CUDA    | `CDialect_CUDA`                               | Used by the paper's CUDA comparison path and the CUDA runner ([`cuda_runner.c`][cuda-runner])                              |

The tests run `spirv-val` with Vulkan arguments on Vcc output (`VALSPV SPV_VAL_ARGS ${SHADY_SPV_VAL_VK_ARGS}` in [`test/vcc/CMakeLists.txt`][vcc-tests]), the same validation gate `sparkles:shaders` uses.

Driver status from the README: radv, amdvlk, anv, Intel Windows and NVIDIA (with a hack) work; _"MoltenVK does not work properly due to issues with SPIRV-Cross"_; the Imagination driver on VisionFive 2 crashes. The MoltenVK failure is the telling one: SPIR-V carrying emulated physical memory, tagged pointers and a dispatcher loop is valid Vulkan SPIR-V but not something [SPIRV-Cross][spirv-cross] translates. The same applies to [naga][naga] and [Tint][tint], which reject `PhysicalStorageBuffer64` outright for WGSL (see their deep-dives).

## Host integration and CPU execution

Vcc is a **separate compiler invocation** (`vcc file.c -o file.spv`), not a single-source compiler in the CUDA sense: the paper lists a single-source programming model under "not planned", needing _"A tightly-integrated host language / runtime component"_ (Appendix A). Sharing happens at the **source** level instead. aobench is the clearest example: one [`ao.c`][ao-c] is compiled three ways —

- for the host, by [`ao_host.c`][ao-host], which does `#define private` (empty) and `#include "ao.c"`;
- for ISPC, guarded by `ENABLE_ISPC`, as `render_ispc` in [`ao_main.c`][ao-main];
- for the device, by [`ao.comp.cpp`][ao-comp], which defines the annotations and binds `sqrtf` and friends to Shady primops before `#include "ao.c"`.

The `shd_rn_*` runner ([`runner.h`][runner]) loads a program on Vulkan or CUDA, allocates or imports host memory as a device buffer, and launches a kernel with its device address — a test harness, not a product API. The paper's path tracer likewise shares one C++ rendering code base between CPU, CUDA and Vulkan (§6.2).

CPU execution of the _Shady output_ is possible through the C11 and ISPC backends, the latter giving a SPMD-on-SIMD reading of `uniform`/`varying` values, but neither is a defined reference simulator with GPU semantics; it is a debugging aid. Bindings for scripting languages exist under `zhady/` (SWIG interface files).

---

## Lessons for sparkles:shaders

- **Match the problem statement, not the solution.** LDC → LLVM IR → SPIR-V is the same pipeline shape as Clang → LLVM IR → Shady → SPIR-V, and Appendix A's sentence applies verbatim: the supported language _"is entirely dictated by the subset of LLVM IR we support."_ The D design must therefore state its subset in terms of IR the backend can lower (logical pointers, structured CFG, no indirect calls, no recursion) and **reject the rest in the D frontend**, extending the device rules of [`SHM3`][spec] — which today forbids function pointers and delegates but does not name recursion (the LLVM SPIR-V backend has no recursion diagnostic; only `spirv-val` catches it, per the [LLVM SPIR-V backend][llvm-spirv] deep-dive).
- **Avoid emulation in the portable core.** Emulated physical memory, tagged generic pointers, an emulated stack and a dispatcher loop all produce SPIR-V that SPIRV-Cross, naga and Tint cannot translate (the README's own MoltenVK failure). Since `sparkles:shaders` reaches GLSL, MSL, HLSL and WGSL through translators, every emulation Vcc performs must be a compile-time error in the portable tier, or an explicit opt-in tier (`@requires(Feature.physicalPointers)`-style) that removes translator columns.
- **Adopt Vcc's "normalise, then demote" pointer discipline as the legality bar.** Vcc's cleanup folds casts and GEPs to the end of a pointer chain and demotes allocas whose uses are all logical. The D device rules should be phrased so that every accepted program normalises to logical pointers without emulation: `ref` and address-space-typed pointers (`GlobalPointer!T`, `SharedPointer!T` from [dcompute][dcompute]) monomorphised per space, no pointer stored to memory, no pointer arithmetic outside BDA.
- **Match structured control flow at the source.** Shady needs a structuriser that can bail, and LLVM's SPIR-V backend has its own; both exist because LLVM drops structure. D has `goto` and labelled `break`/`continue` across `switch` — banning non-structured `goto` in device modules keeps the structuriser on its trivial path and makes maximal-reconvergence semantics achievable later.
- **Adopt the capability-flag target model.** Shady's `TargetConfig` (`native_fncalls`, `native_stack`, per-space `physical`/`allowed`) lets one pipeline serve SPIR-V, GLSL, CUDA and C. A sparkles target table (SPIR-V/Vulkan, GLSL via SPIRV-Cross, WGSL via naga, CPU simulator) with the same boolean columns gives the build step a mechanical "does this module fit this target" check.
- **Avoid C-style layout by default.** Shady's layout is C-like with an open `vec3` TODO and leans on scalar block layout. The D vocabulary should derive std140/std430/scalar layouts by introspection and `static assert` them (decision [`D9`][decisions] already fixes the host `vec3` representation), not inherit whatever LLVM's data layout says.
- **Test strategy: compile one source three ways.** aobench's `ao.c` compiled for host, ISPC and Vulkan is the cheapest agreement test there is. A sparkles conformance corpus should do the same per kernel — D host build, CPU simulator, SPIR-V via `spirv-val` and a GPU run — and diff results within the `D12` precision table.

## Strengths

- Proves that full C++ (pointers, `goto`, recursion, function pointers, unions) can run on stock Vulkan drivers, and quantifies the cost (paper Table 3).
- Unmodified Clang frontend: all of C++'s type system and templates for free; the shading language is a header.
- A real GPU IR with structure and uniformity in the type, and a pass pipeline parameterised by target capabilities.
- When the emulated features are unused, output performance matches GLSL (terrain demo: 0.66 ms vs 0.66 ms on a Radeon 7900 XTX, Table 2).
- Multiple backends (SPIR-V, C11, GLSL, ISPC, CUDA) from one IR; `spirv-val`-gated tests.
- Honest documentation of driver failures and of each emulation's cost.

## Weaknesses

- Emulated calls are expensive: the `fn_ptr` micro-benchmark takes 14,620 µs on an RTX 2080 Super against a 644 µs CUDA reference, and `fib` 776,337 µs against 311,612 µs (Table 3), because _"we had to pass all arguments and return values through the stack, every time"_ (§6.4.4).
- Emulated private memory hides allocations from the driver optimiser and inflates register pressure.
- Tagged generic pointers rely on an unspecified property of GPU addresses.
- Emulated SPIR-V is untranslatable by SPIRV-Cross (MoltenVK broken), naga and Tint; Vulkan-only in practice.
- No subgroup operations in the evaluated programs; maximal reconvergence unreachable from LLVM IR.
- Research-grade: no releases, stale README paths, GLSL backend untested, layout `TODO`s, no standard library.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                   | Trade-off                                                                                         |
| ---------------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Unmodified Clang, consume LLVM IR                          | Whole C/C++ language for free; no compiler fork to maintain                 | Structure and logical addressing are lost and must be re-derived; swizzles need library tricks    |
| Language extensions as `annotate` strings + address spaces | Zero frontend changes; one header defines the "language"                    | Errors surface late (in Shady), not at the C++ source; stringly-typed attributes                  |
| Emulate physical private/shared memory as word arrays      | Correct for arbitrary pointer use, unions, `memcpy`                         | Hides allocations from the driver, register pressure, slower int8 paths on AMD (Table 3 `unions`) |
| Physical global memory via BDA                             | Vulkan provides it natively; no emulation needed                            | Requires `PhysicalStorageBuffer64`; not translatable to WGSL                                      |
| Generic pointers as 3-bit tagged 64-bit integers           | Simple, cheap per access                                                    | Assumes unused high address bits — unspecified by Vulkan                                          |
| CPS + lambda lifting + one top-level dispatcher            | Only way to express recursion/indirect calls without a recursive call graph | Every call goes through an emulated stack; large slowdowns on call-heavy code                     |
| Leaf-function analysis                                     | Code without indirect/recursive calls pays nothing                          | Any non-leaf call poisons its callers into the slow path                                          |
| Software scheduler for divergent calls                     | Reconverges divergent lanes without hardware support                        | Runtime state in subgroup memory; complex, semantics-defining code in a library                   |
| DFS restructuriser that may bail                           | Handles arbitrary `goto` reducible CFGs                                     | Irreducible or indirect cases are left unstructured; must run after call lowering                 |
| Capability-flagged `TargetConfig`                          | One pipeline for SPIR-V, GLSL, C, ISPC, CUDA                                | Each target sees a different effective language; no single portable contract                      |

## Sources

- Repository and README: [shady-gang/shady at `dd2787a7`][repo], [`readme.md`][readme], [`license.md`][license]
- Vcc driver and headers: [`vcc/vcc.c`][vcc-main], [`vcc/vcc_lib.c`][vcc-lib], [`vcc/include/shady.h`][shady-h], [`vcc/include/shady_sample.h`][sample-h]
- LLVM frontend: [`src/frontend/llvm/l2s.c`][l2s], [`generator_l2s.py`][l2s-gen]; IR grammar [`include/shady/grammar.json`][grammar], scopes [`include/shady/ir/enum.h`][enum-h], folding [`src/shady/fold.c`][fold]
- Shader pipeline: [`shader_pipeline.c`][pipeline], [`cf.c`][cf], [`memory.c`][memory], [`polyfill.c`][polyfill], [`scheduler.slim`][scheduler], [`targets.c`][targets]
- Passes: [`lower_generic_ptrs.c`][generic], [`lower_physical_memory.c`][physical], [`lower_callf.c`][callf], [`lift_indirect_targets.c`][lift], [`mark_leaf_functions.c`][leaf], [`software_dispatcher.c`][dispatcher], [`restructure.c`][restructure], [`reconvergence_heuristics.c`][reconv], [`specialize_entry_point.c`][spec-ep]
- Backends: [`emit_spv.c`][emit-spv], [`emit_spv_type.c`][emit-spv-type], [`spirv_builder.c`][spv-builder], [`spirv_callable_shaders.c`][callable], [`spirv_specialize_explicit_layout.c`][explicit-layout], [`memory_layout.c`][mem-layout], [`be/c.h`][be-c], [`runtime.ispc`][runtime-ispc], [`runtime_120.glsl`][runtime-glsl]
- Tests and samples: [`test/vcc/CMakeLists.txt`][vcc-tests], [`textured.frag.cpp`][textured], [`ao.c`][ao-c], [`ao_host.c`][ao-host], [`ao.comp.cpp`][ao-comp], [`ao_main.c`][ao-main]; runner [`runner.h`][runner], [`cuda_runner.c`][cuda-runner]
- Paper: H. Devillers et al., ["No More Shading Languages: Compiling C++ to Vulkan Shaders"][paper], High-Performance Graphics 2025 (CC BY); [Vcc website][vcc-site]; NASL [shady-gang/nasl at `8fa0a677`][nasl]
- Related in this catalog: [Concepts][concepts] ([logical and physical addressing][c-addr], [structured control flow][c-cf], [uniformity][c-uni]) · [LLVM SPIR-V backend][llvm-spirv] · [dcompute][dcompute] · [rust-gpu][rust-gpu] · [Circle][circle] · [Zig SPIR-V][zig] · [CUDA/HIP][cuda-hip] · [SYCL][sycl] · [ISPC][ispc] · [SPIRV-Cross][spirv-cross] · [naga][naga] · [Tint][tint] · [Comparison][comparison] · [Index][index]
- sparkles: [`sparkles:shaders` SPEC][spec] · [decisions][decisions]

<!-- References -->

[repo]: https://github.com/shady-gang/shady/tree/dd2787a7ebf78f8b51192bb23322057cfa8636c3
[readme]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/readme.md
[license]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/license.md
[vcc-main]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/vcc/vcc.c
[vcc-lib]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/vcc/vcc_lib.c
[shady-h]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/vcc/include/shady.h
[sample-h]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/vcc/include/shady_sample.h
[l2s]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/frontend/llvm/l2s.c
[l2s-gen]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/frontend/llvm/generator_l2s.py
[grammar]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/include/shady/grammar.json
[enum-h]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/include/shady/ir/enum.h
[fold]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shady/fold.c
[pipeline]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shader-pipeline/shader_pipeline.c
[cf]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shader-pipeline/cf.c
[memory]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shader-pipeline/memory.c
[polyfill]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shader-pipeline/polyfill.c
[scheduler]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shader-pipeline/scheduler.slim
[targets]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/driver/targets.c
[generic]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shady/passes/ptr/lower_generic_ptrs.c
[physical]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shady/passes/mem/lower_physical_memory.c
[callf]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shady/passes/fncalls/lower_callf.c
[lift]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shady/passes/fncalls/lift_indirect_targets.c
[leaf]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shady/passes/fncalls/mark_leaf_functions.c
[dispatcher]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shady/passes/fncalls/software_dispatcher.c
[restructure]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shady/passes/structure/restructure.c
[reconv]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shady/passes/structure/reconvergence_heuristics.c
[spec-ep]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shady/passes/abi/specialize_entry_point.c
[emit-spv]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/backend/spirv/emit_spv.c
[emit-spv-type]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/backend/spirv/emit_spv_type.c
[spv-builder]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/backend/spirv/spirv_builder.c
[callable]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/backend/spirv/spirv_callable_shaders.c
[explicit-layout]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/backend/spirv/spirv_specialize_explicit_layout.c
[mem-layout]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/shady/ir/memory_layout.c
[be-c]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/include/shady/be/c.h
[runtime-ispc]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/backend/c/runtime.ispc
[runtime-glsl]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/backend/c/runtime_120.glsl
[vcc-tests]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/test/vcc/CMakeLists.txt
[textured]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/test/vcc/cpp/textured.frag.cpp
[ao-c]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/samples/aobench/ao.c
[ao-host]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/samples/aobench/ao_host.c
[ao-comp]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/samples/aobench/ao.comp.cpp
[ao-main]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/samples/aobench/ao_main.c
[runner]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/include/shady/runner/runner.h
[cuda-runner]: https://github.com/shady-gang/shady/blob/dd2787a7ebf78f8b51192bb23322057cfa8636c3/src/runner/cuda/cuda_runner.c
[nasl]: https://github.com/shady-gang/nasl/tree/8fa0a67740b9362259c93841615853ba0d00fd16
[paper]: https://graphics.cg.uni-saarland.de/papers/devillers-2025-hpg-vcc.pdf
[vcc-site]: https://shady-gang.github.io/vcc
[concepts]: ./concepts.md
[c-addr]: ./concepts.md#logical-and-physical-addressing
[c-cf]: ./concepts.md#structured-control-flow-merge-and-continue-blocks
[c-uni]: ./concepts.md#uniformity-and-convergence
[llvm-spirv]: ./llvm-spirv-backend.md
[dcompute]: ./dcompute.md
[rust-gpu]: ./rust-gpu.md
[circle]: ./circle.md
[zig]: ./zig-spirv.md
[cuda-hip]: ./cuda-hip.md
[sycl]: ./sycl.md
[ispc]: ./ispc.md
[glsl]: ./glsl.md
[spirv-cross]: ./spirv-cross.md
[naga]: ./naga.md
[tint]: ./tint.md
[comparison]: ./comparison.md
[index]: ./index.md
[spec]: ../../specs/shaders/SPEC.md
[decisions]: ../../specs/shaders/decisions.md
