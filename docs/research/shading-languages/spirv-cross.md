# SPIRV-Cross (Khronos)

The SPIR-V decompiler that turns a Vulkan-flavoured SPIR-V module back into GLSL, GLSL ES, HLSL or MSL source — MoltenVK's engine, and the translator `sparkles:shaders` already depends on for its GLSL 3.30 and GLSL ES 1.00 output.

| Field          | Value                                                                                                                                                                                                                              |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | C++11 library with a C89 wrapper (`spirv_cross_c.h`, C API 0.68) and a CLI (`spirv-cross`)                                                                                                                                         |
| License        | Apache-2.0 ([`LICENSE`][license])                                                                                                                                                                                                  |
| Repository     | [KhronosGroup/SPIRV-Cross][repo]                                                                                                                                                                                                   |
| Documentation  | [`README.md`][readme]; the CLI's `--help` ([`main.cpp`][main-help]); the headers                                                                                                                                                   |
| Category       | Toolchain: SPIR-V → source translator (decompiler) and reflection library                                                                                                                                                          |
| Latest version | Releases are tagged with the Vulkan SDK (`vulkan-sdk-1.4.363.0`, 2026-09-16); the pin is 25 commits past it                                                                                                                        |
| Targets        | GLSL 1.10–4.60, GLSL ES 1.00–3.20, Vulkan GLSL; HLSL SM 3.0–6.8; MSL 1.1–4.0 (macOS, iOS); reflection JSON; C++ (deprecated)                                                                                                       |
| Pins           | `KhronosGroup/SPIRV-Cross` at `300681bb` (2026-10-14). The `sparkles:shaders` toolchain pins **1.4.357.0** (`6c09849f`, 2026-07-06; [`SHT2`][sparkles-spec]), an ancestor 64 commits earlier; line numbers below are at `300681bb` |

---

## Overview

### What it solves

Vulkan made SPIR-V the one binary every shader compiler emits, but OpenGL, OpenGL ES, WebGL, Direct3D and Metal consume source languages. SPIRV-Cross closes that gap by decompiling SPIR-V into each of them, and by reflecting resources, so one compiled module can feed every API. Its feature list ([`README.md`][readme-features]):

> _"Convert SPIR-V to readable, usable and efficient GLSL · … Metal Shading Language (MSL) · … HLSL · Convert SPIR-V to a JSON reflection format · Convert SPIR-V to debuggable C++ [DEPRECATED] · Reflection API to simplify the creation of Vulkan pipeline layouts · Reflection API to modify and tweak OpDecorations"_

For `sparkles:shaders` it is the last compiler before the driver: LDC emits SPIR-V, `spirv-opt -O` cleans it, and `spirv-cross` produces the GLSL a consumer loads ([`app.d`][app-d], [`SHP5`][sparkles-spec]). Every target the project adds beyond GLSL — HLSL for D3D, MSL for Apple — runs through the same library unless WGSL (which SPIRV-Cross does not emit) or DXIL requires another tool.

### Design philosophy

Readable output is the goal, not an accident ([`README.md`][readme-features]):

> _"SPIRV-Cross tries hard to emit readable and clean output from the SPIR-V. The goal is to emit GLSL or MSL that looks like it was written by a human and not awkward IR/assembly-like code."_

That goal has a structural consequence. Human-written GLSL has `if`, `for` and `switch`, never `goto`, so SPIRV-Cross reconstructs high-level control flow from SPIR-V's structured-control-flow annotations (`OpSelectionMerge`, `OpLoopMerge`) and fails or duplicates code when they are missing. It also treats the names in the module as the names in the output: _"When emitting shaders with older versions, these layout statements will be removed, so it is important that the API user ensures that the names of I/O variables are sanitized so that linking will work properly"_ ([`README.md`][readme-linking]). A producer that wants usable output must therefore emit structured control flow and `OpName`s that survive.

The C wrapper is the stability boundary: _"Unlike the C++ API, the goal of this wrapper is to be fully stable, both API and ABI-wise. This is the only interface which is supported when building SPIRV-Cross as a shared library"_ ([`README.md`][readme-capi]).

## How it works

The library is a parser plus one `Compiler` subclass per target:

| Class                 | File                                                                   | Output                                                  |
| --------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------- |
| `Parser` → `ParsedIR` | [`spirv_parser.cpp`][parser], [`spirv_cross_parsed_ir.cpp`][parsed-ir] | typed IR, names, decorations, CFG                       |
| `Compiler`            | [`spirv_cross.cpp`][cross]                                             | reflection, active-variable analysis, combined samplers |
| `CompilerGLSL`        | [`spirv_glsl.cpp`][glsl-cpp] (~21 k lines)                             | GLSL, ESSL, Vulkan GLSL; base of the others             |
| `CompilerHLSL`        | [`spirv_hlsl.cpp`][hlsl-cpp]                                           | HLSL source (needs FXC or DXC afterwards)               |
| `CompilerMSL`         | [`spirv_msl.cpp`][msl-cpp] (~21 k lines)                               | MSL source                                              |
| `CompilerReflection`  | `spirv_reflect.cpp`                                                    | JSON reflection                                         |

A translation runs in three steps: parse (which de-SSAs `OpPhi` into function-scope variables, [`spirv_parser.cpp` L1060][parser-phi]), analyse (which variables are active, which images pair with which samplers, which blocks are loop headers), and emit — repeatedly, because some decisions (`_N_ladder_break` flags for breaks out of a loop from inside a `switch`, [`spirv_glsl.cpp` L18489–L18495][glsl-ladder]) are discovered during emission and force a recompile, up to a bound that ends in _"Maximum compilation loops detected and no forward progress was made. Must be a SPIRV-Cross bug!"_ ([L355][glsl-maxloops]).

Through the C API the whole sparkles step is a handful of calls:

```c
spvc_context_create(&ctx);
spvc_context_parse_spirv(ctx, words, count, &ir);
spvc_context_create_compiler(ctx, SPVC_BACKEND_GLSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &comp);
spvc_compiler_set_entry_point(comp, "scanlines", SpvExecutionModelFragment);
spvc_compiler_get_active_interface_variables(comp, &active);   // --remove-unused-variables
spvc_compiler_set_enabled_interface_variables(comp, active);
spvc_compiler_build_combined_image_samplers(comp);             // GLSL needs sampler2D
/* for each combined sampler: spvc_compiler_set_name(comp, combined_id, image_name) */
spvc_compiler_create_compiler_options(comp, &opts);
spvc_compiler_options_set_uint(opts, SPVC_COMPILER_OPTION_GLSL_VERSION, 100);
spvc_compiler_options_set_bool(opts, SPVC_COMPILER_OPTION_GLSL_ES, SPVC_TRUE);
spvc_compiler_install_compiler_options(comp, opts);
spvc_compiler_compile(comp, &glsl);
```

(Function names from [`spirv_cross_c.h`][c-api]: `spvc_compiler_get_active_interface_variables` and `spvc_compiler_set_enabled_interface_variables` at L911–L912, `spvc_compiler_set_name` at L934, `spvc_compiler_build_combined_image_samplers` at L1039.)

## Execution model and stages

Per-backend stage support, from each backend's entry-point code:

| Stage                    | GLSL / Vulkan GLSL                         | ESSL                                       | HLSL                                                                    | MSL                                                                                                  |
| ------------------------ | ------------------------------------------ | ------------------------------------------ | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Vertex, fragment         | all versions                               | all versions                               | yes                                                                     | yes                                                                                                  |
| Compute                  | < 430 requests `GL_ARB_compute_shader`     | **≥ 3.10 or throw** ([L488][glsl-compute]) | yes                                                                     | `kernel`                                                                                             |
| Geometry                 | < 150 requests ARB extension               | < 3.20 requests `GL_EXT_geometry_shader`   | yes (`geom_main`)                                                       | **no** (no `ExecutionModelGeometry` in `spirv_msl.cpp`)                                              |
| Tessellation             | < 400 requests ARB extension               | < 3.20 requests EXT extension              | **no** — throws _"Unsupported execution model."_ ([L3098][hlsl-stages]) | emulated: vertex/TCS as `kernel`, TES as `[[patch]] vertex`; no isolines ([L14686–L14693][msl-tess]) |
| Mesh, task               | Vulkan GLSL ≥ 450 only ([L550][glsl-mesh]) | never                                      | yes (`mesh_main`, `task_main`)                                          | `[[mesh]]`, `[[object]]`                                                                             |
| Ray-tracing pipeline (6) | Vulkan GLSL ≥ 460 only ([L521][glsl-rt])   | never                                      | **no**                                                                  | **no**                                                                                               |
| Ray query (any stage)    | Vulkan GLSL 460                            | never                                      | `RayQuery<RAY_FLAG_NONE>`                                               | yes                                                                                                  |

The **HLSL backend names entry points** `vert_main`, `frag_main`, `comp_main`, `geom_main`, `mesh_main`, `task_main` unless `use_entry_point_name` is set ([`spirv_hlsl.cpp` L3075–L3098][hlsl-stages]). One SPIR-V module may hold several entry points; SPIRV-Cross translates one per run, chosen by `--entry`/`set_entry_point`, which is why the sparkles build step lists `OpEntryPoint Fragment` lines and loops over them ([`app.d`][app-d]).

## Type system and generic programming

SPIRV-Cross translates types, it does not add any: generics must be monomorphised before SPIR-V. Type support per backend is gated by version and throws when the target cannot express a type ([`find_static_extensions`, `spirv_glsl.cpp` L445–L478][glsl-types]):

| Type               | GLSL                                                                            | ESSL                                                                                       | HLSL                 | MSL                         |
| ------------------ | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | -------------------- | --------------------------- |
| `double`           | < 400 requests `GL_ARB_gpu_shader_fp64`                                         | _"FP64 not supported in ES profile."_ ([L451][glsl-types])                                 | yes                  | no (MSL has none)           |
| 64-bit integers    | `GL_ARB_gpu_shader_int64`                                                       | ≥ 3.10 only                                                                                | SM 6.0               | MSL 2.2                     |
| 8/16-bit types     | `GL_EXT_shader_explicit_arithmetic_types_*` (+ storage extensions under Vulkan) | same                                                                                       | 16-bit native SM 6.2 | yes                         |
| `uint`             | yes                                                                             | ESSL 1.00: _"Unsigned integers are not supported on legacy targets."_ ([L6138][glsl-uint]) | yes                  | yes                         |
| Long vectors (> 4) | `GL_EXT_long_vector`, Vulkan only                                               | —                                                                                          | —                    | —                           |
| Cooperative matrix | Vulkan GLSL                                                                     | —                                                                                          | —                    | `simdgroup_matrix`, MSL 3.1 |

The int8 row matters to `sparkles:shaders` in practice: leftover `i8` arrays from D string literals make SPIRV-Cross request `GL_EXT_shader_explicit_arithmetic_types_int8` (L466–L471), which is invalid for GLSL 3.30 and ESSL 1.00 — the reason the build step runs `spirv-opt -O` first, and the reason `@compute` modules hold no string literals (AGENTS pitfall list).

"Legacy" is a precise predicate — `(options.es && options.version < 300) || (!options.es && options.version < 130)` ([`spirv_glsl.hpp` L958–L961][glsl-legacy]) — so the project's two outputs differ in kind: GLSL 3.30 is modern, ESSL 1.00 is legacy.

## Resources, interfaces and memory layout

| Concern                    | GLSL / ESSL                                                                                                                  | HLSL                                                                                                      | MSL                                                                                                                                                   |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Separate texture + sampler | must call `build_combined_image_samplers()` first, _"or you will get an exception"_ ([README][readme-combined])              | native (SM ≥ 4.0); forced combined on SM 3.0                                                              | native; a combined sampler needs two ids                                                                                                              |
| Descriptor set + binding   | flatten to set 0 with `set_decoration` ([README][readme-sets]); bindings dropped below GLSL 4.20/ESSL 3.10 without `420pack` | SM 5.1+: sets become register spaces; `add_hlsl_resource_binding` ([`spirv_hlsl.hpp` L222][hlsl-binding]) | flat `[[buffer/texture/sampler(n)]]` or argument buffers (`--msl-argument-buffers`); `add_msl_resource_binding` ([`spirv_msl.hpp` L699][msl-binding]) |
| Arrays of resources        | one binding                                                                                                                  | consume several registers — overlap risk                                                                  | consume several `[[id]]`s                                                                                                                             |
| Push constants             | Vulkan GLSL: `push_constant`; otherwise a plain `uniform` struct, set/binding stripped                                       | a `cbuffer`, or root constants                                                                            | a `constant` buffer argument                                                                                                                          |
| UBO                        | legacy: emitted as plain uniform structs; `--glsl-emit-ubo-as-plain-uniforms`, `--flatten-ubo` (`vec4[]`)                    | `cbuffer`                                                                                                 | `constant` buffer                                                                                                                                     |
| SSBO                       | _"SSBOs not supported in legacy targets."_ ([L2574][glsl-ssbo])                                                              | `RWByteAddressBuffer` / structured                                                                        | `device` buffer                                                                                                                                       |
| Specialization constants   | Vulkan GLSL: `layout(constant_id)`; otherwise `SPIRV_CROSS_CONSTANT_ID_N` macros ([L3206][glsl-specmacro])                   | same macros                                                                                               | `[[function_constant(N)]]`                                                                                                                            |
| Stage I/O linking          | modern: `layout(location)`; legacy: **by name** ([README][readme-linking])                                                   | semantics (`add_vertex_attribute_remap`)                                                                  | `[[user(locnN)]]` / `[[attribute(n)]]`                                                                                                                |

**Layout is read from decorations, not recomputed.** Block members need `Offset`, arrays `ArrayStride`, matrices `MatrixStride` and row/column-major, or the translation throws; a block that fits neither `std140` nor `std430` throws on ES targets. The producer — LDC — is therefore the one place layout is decided, and `sparkles:shaders` must emit decorations that match the layout its D structs promise.

**Names and renaming** are the contract `sparkles:shaders` builds on (`SHF2`, `SHP5`):

| Rule                                          | Effect                                                                                                                 | Source                                                                 |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| No `OpName`                                   | an id prints as `_<id>` ([`spirv_cross.cpp` L349][cross-name]); a struct member as `_m<index>` ([L16853][glsl-member]) | —                                                                      |
| Reserved patterns                             | `_` + digits; `_` + digits + `_` + anything; members `_m` + digits; prefixes `gl_`, `spv`; any `__`                    | [`README.md` "Reserved identifiers"][readme-reserved]                  |
| Reserved name in the module                   | rewritten to `_RESERVED_IDENTIFIER_FIXUP_<name>` (prefixed names) or `_RESERVED_IDENTIFIER_FIXUP<name>`                | [`spirv_cross_parsed_ir.cpp` L195–L258][parsed-ir-reserved]            |
| `SPIRV_Cross` prefix                          | _"This identifier will not be rewritten, but be aware of potential collisions"_                                        | README                                                                 |
| Collides with a GLSL keyword or built-in name | prefixed with `_` (`texture` → `_texture`, `length` → `_length`, `sample` → `_sample`)                                 | [`replace_illegal_names`, `spirv_glsl.cpp` L3306–L3400][glsl-keywords] |
| Combined image-sampler (CLI)                  | named `SPIRV_Cross_Combined<image><sampler>`                                                                           | [`main.cpp` L1585–L1599][main-combined]                                |
| Reflection JSON                               | _"will follow the exact name specified in the SPIR-V module"_, valid identifier or not                                 | README                                                                 |

The keyword list is broad: it includes every GLSL built-in function name (`abs`, `mix`, `dot`, `texture`, `length`, `min`, `max`…), every type name, and C++ words (`class`, `template`, `this`, `namespace`). A D `@uniform float length` or `@input vec2 sample` would therefore arrive in the GLSL as `_length`/`_sample` and break a host that binds by name. The sparkles fork already rejects such names: its `unreservedRefusal` ([`targetVulkan.cpp`][fork-reserved]) carries a copy of the `replace_illegal_names` table beside the README patterns, so the diagnostic names the parameter in D. What it does not carry yet are the HLSL and MSL backends' own reserved lists, which matter once those become targets. The combined-sampler name is a CLI convenience, not library behaviour; the build step's regex `SPIRV_Cross_Combined(\w+?)sampler\b` → `$1` ([`app.d`][app-d]) undoes it and would become one `spvc_compiler_set_name` call through the C API.

## Built-in library and intrinsics

SPIRV-Cross maps `GLSL.std.450` extended instructions and core opcodes to each target's built-ins, and **polyfills** where a target lacks one: GLSL keeps `Polyfill*` flags for 2×2–4×4 `transpose`, `determinant` and `inverse` ([`spirv_glsl.hpp` L973ff][glsl-legacy]); legacy ESSL emulates `round` as `floor(x + 0.5)` and `trunc` through integer casts; MSL emits `spv*` helper functions for operations Metal lacks. Where no polyfill exists it throws, and the throw sites are the authoritative list of what a target cannot express:

| Not expressible                                                         | Target and site                                                           |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `textureSize`, `texelFetch`, `textureQueryLod`, shadow-compare variants | legacy ES ([L8022][glsl-texsize], L8029, L15182)                          |
| float↔int bitcasts (`floatBitsToInt`)                                   | legacy ES (L10404–L10428)                                                 |
| Sample variables (`gl_SampleID`, …)                                     | legacy GLSL (L10715–L10737)                                               |
| Non-square matrix transpose                                             | legacy GLSL (L16991)                                                      |
| Wave ops                                                                | HLSL below SM 6.0 (_"Need SM 6.0 for Wave ops."_, `spirv_hlsl.cpp` L1374) |
| InverseBallot, BallotBitExtract, FindLSB/MSB, clustered reductions      | HLSL (no Wave equivalents)                                                |
| Floating-point atomics, 64-bit atomics                                  | HLSL; MSL 64-bit atomics                                                  |

Two outputs are emitted **unchecked** for legacy ES: integer `%`, `<<`, `>>`, `&`, `|`, `^` are printed verbatim through `GLSL_BOP_CAST` regardless of target ([`spirv_glsl.cpp` L14405–L14453][glsl-bitops]), although GLSL ES 1.00 reserves those operators; and the ES 1.00 Appendix A loop and indexing limits are not checked at all. glslang catches the first only, and only the operators, because its default resource limits leave Appendix A off (see [`glsl.md`][glsl]).

## Control flow, memory model and restrictions

The limits a producer must respect, in the order a D/LDC module meets them:

| Limit                                         | Behaviour                                                                                                                                                                                                        | Site                                                                               |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `Kernel` capability                           | _"Kernel capability not supported."_ — OpenCL-flavoured SPIR-V is rejected at parse time                                                                                                                         | [`spirv_parser.cpp` L293–L294][parser-kernel]                                      |
| Addressing model                              | GLSL: _"Only Logical and PhysicalStorageBuffer64 addressing models are supported."_; `PhysicalStorageBuffer64` only in Vulkan GLSL ≥ 450 / ESSL ≥ 320 (`GL_EXT_buffer_reference2`); HLSL: Logical only           | [`spirv_glsl.cpp` L594–L607][glsl-addr], [`spirv_hlsl.cpp` L7139–L7140][hlsl-addr] |
| `VariablePointers`                            | _"VariablePointers capability is not supported in GLSL."_ (HLSL likewise)                                                                                                                                        | [L635–L637][glsl-varptr]                                                           |
| `OpPtrAccessChain`                            | _"Backend does not support native pointers and does not support OpPtrAccessChain."_ — works only where `backend.native_pointers` is set: MSL ([`spirv_msl.cpp` L1705][msl-native]) and buffer-reference pointers | [L11023–L11026][glsl-ptrac]                                                        |
| Untyped pointers (`SPV_KHR_untyped_pointers`) | the parser accepts `OpTypeUntypedPointerKHR` ([L884][parser-untyped]), but `OpUntypedPtrAccessChainKHR` throws and untyped access chains are _"currently only supported for descriptor heap access"_             | [L13243–L13272][glsl-untyped]                                                      |
| `OpSwitch` without `OpSelectionMerge`         | _"Switch statement is not structured"_; 64-bit selectors throw except on MSL                                                                                                                                     | [L19254–L19259][glsl-switch]                                                       |
| Unstructured branch                           | a branch to a block that is not a merge or continue target is emitted by **inlining the target block chain** — code duplication; irreducible CFGs cannot be expressed                                            | [L18523][glsl-inline]                                                              |
| `OpPhi`                                       | accepted; lowered to a variable plus copies on each edge                                                                                                                                                         | [`spirv_parser.cpp` L1060][parser-phi]                                             |
| Legacy ES `switch`                            | becomes `for (int spvDummyN = 0; spvDummyN < 1; spvDummyN++)` around an `if` chain, because _"ESSL 1.0 is not guaranteed to support do/while"_                                                                   | [L19435–L19450][glsl-spvdummy]                                                     |

The pointer rows are the ones an LLVM-based producer hits. A GEP whose leading index is non-zero is a pointer offset, which SPIR-V spells `OpPtrAccessChain`; LLVM's SPIR-V backend enables `SPV_KHR_untyped_pointers` only for OpenCL today; and it emits OpenCL `Kernel` SPIR-V unless targeted at a Vulkan environment. Each of these yields a module that can validate but that SPIRV-Cross cannot translate to GLSL or HLSL (see [`llvm-spirv-backend.md`][llvm-spirv]). The sparkles fork's 32-bit access-chain-index patch and the `vulkan-100`…`vulkan-140` dcompute targets (`SHP1`) are what keep LDC on the translatable side today ([`SPEC.md`][sparkles-spec] `SHT1`).

Memory-model translation follows the target: Vulkan memory-model scopes become GLSL `GL_KHR_memory_scope_semantics` calls, HLSL `Interlocked*` functions and barriers, and MSL barriers and atomics. The MSL backend tracks Metal's own semantics — before MSL 3.2 _"memory barriers are also control barriers"_, so it drops a control barrier that directly follows one ([`spirv_msl.cpp` L10488–L10493][msl-barrier]).

## Compilation pipeline and targets

```bash
# What sparkles:shaders runs per fragment entry point (apps/shader-compile)
spirv-val --target-env spv1.6 shader.spv
spirv-opt -O shader.spv -o shader.opt.spv
spirv-cross --entry scanlines --stage frag --remove-unused-variables --version 330      shader.opt.spv
spirv-cross --entry scanlines --stage frag --remove-unused-variables --es --version 100 shader.opt.spv
glslangValidator scanlines.frag      # and scanlines.es.frag
```

**CLI versus library.** The CLI decides several things the library leaves to the caller ([`main.cpp`][main-glsl-setup] L1336–L1342): without `--vulkan-semantics` it sets `combined_image_samplers = true` and `build_dummy_sampler = true` (so `texelFetch` on an image without a sampler still compiles), and names every combined sampler `SPIRV_Cross_Combined<image><sampler>`. For HLSL at SM ≤ 3.0 it forces combined samplers too (L1500–L1504). `--remove-unused-variables` is `get_active_interface_variables()` + `set_enabled_interface_variables()` (L1535–L1541) — the mechanism behind `SHP5`'s "Unused interface variables are removed". The library also exposes what the CLI cannot: per-resource remapping (`set_decoration`, `add_hlsl_resource_binding`, `add_msl_resource_binding`), direct naming, several targets from one parse, and errors as return codes instead of process exits.

**Defaults the build inherits silently** — each a change of output if altered:

| Option                             | Default                                                 | Where                                        |
| ---------------------------------- | ------------------------------------------------------- | -------------------------------------------- |
| GLSL `version`                     | 450                                                     | [`spirv_glsl.hpp` L84][glsl-opts]            |
| ES default precision               | `mediump float`, `highp int`                            | [`spirv_glsl.hpp` L196–L197][glsl-precision] |
| HLSL `shader_model`                | 30 (SM 3.0)                                             | [`spirv_hlsl.hpp` L112][hlsl-sm]             |
| MSL version / platform             | 1.2, macOS                                              | [`spirv_msl.hpp` L305–L306][msl-opts]        |
| MSL argument-buffer tier           | Tier 1                                                  | `spirv_msl.hpp` L365                         |
| `emit_line_directives`             | off (`--emit-line-directives` maps `OpLine` to `#line`) | `spirv_glsl.hpp` L128                        |
| `force_zero_initialized_variables` | off                                                     | `spirv_glsl.hpp` L140                        |

`sparkles:shaders` requests `highp` explicitly for ES ([`decisions.md`][sparkles-decisions] D15); `--emit-line-directives` together with `NonSemantic.Shader.DebugInfo.100` is the route to D source lines in GLSL compiler errors.

Changes between the toolchain's 1.4.357.0 and the pin include `GL_EXT_long_vector` support, `GL_EXT_abort`, subgroup reconvergence and function-control hints, conservative-depth fixes and a row-major push-constant fix for OpenGL semantics (`git log 6c09849f..300681bb`); `SHT2` makes any such bump an output change to review.

## Host integration and CPU execution

SPIRV-Cross runs on the host at build time (or at load time, as in MoltenVK); it does not execute shaders. Its CPU output — the C++ backend — is _"[DEPRECATED]"_ ([`README.md`][readme-features]), so it offers no CPU execution path; in `sparkles:shaders` the host D compilation already is the CPU path. Its host-facing value is **reflection**: `get_shader_resources()` and `--reflect` JSON list inputs, outputs, uniform buffers, storage buffers, images, samplers, push constants and specialization constants with set, binding and location, and `get_declared_struct_member_size`/offsets give block layout — what a D host loader needs to bind generated GLSL or MSL by name without hand-written tables.

The C API (`spirv_cross_c.h`, C89, all allocations owned by an `spvc_context`) binds cleanly from D with ImportC or a hand-written `extern(C)` module, and is available through `pkg-config spirv-cross-c-shared` in the Nix shell.

```d
// The shape of a D wrapper over the C API (sketch, not current code).
extern (C) nothrow @nogc
{
    spvc_result spvc_compiler_build_combined_image_samplers(spvc_compiler);
    void spvc_compiler_set_name(spvc_compiler, SpvId id, const(char)* name);
}

void nameCombinedAfterImages(spvc_compiler c)
{
    foreach (ref s; combinedImageSamplers(c))          // spvc_compiler_get_combined_image_samplers
        spvc_compiler_set_name(c, s.combined_id, nameOf(c, s.image_id).toTempStringz.ptr);
}
```

## Lessons for sparkles:shaders

- **Move from the CLI to the C API before adding a second target.** One parse per module, per-target options in-process, `spvc_compiler_set_name` for combined samplers instead of the `SPIRV_Cross_Combined` regex, `spvc_compiler_set_decoration`, `spvc_compiler_hlsl_add_resource_binding` and `spvc_compiler_msl_add_resource_binding_2` for binding remapping, and error codes instead of parsing stderr.
- **Keep the forbidden-name rule in step with every backend in use.** The fork's check mirrors the README patterns (`_\d+`, `_\d+_.*`, `_m\d+`, `gl_`, `spv`, `__`) and `CompilerGLSL::replace_illegal_names`'s GLSL keyword table ([`targetVulkan.cpp`][fork-reserved]); an HLSL or MSL target adds those backends' own lists, and a SPIRV-Cross bump must re-sync the copy — a test that generates a uniform with each reserved name and asserts the diagnostic catches a drift.
- **Keep LDC's SPIR-V inside the translatable subset, and check it before translation.** `Shader` capability, Logical addressing (or `PhysicalStorageBuffer64` only for Vulkan GLSL and MSL), no `VariablePointers`, no `OpPtrAccessChain` outside buffer references, typed pointers only, every `OpSwitch` and loop structured. A `spirv-dis`-level lint in `shader-compile` that names the offending D function beats a SPIRV-Cross exception string.
- **Treat legacy ES as a front-end subset, not a translator mode.** SPIRV-Cross throws for `uint`, bitcasts, `textureSize` and `texelFetch`, but prints `%`, shifts and bit operators verbatim and never checks Appendix A; the D front end must reject those for the `gles100` target, and glslang must run with Appendix A limits set to `0`.
- **Decide layout in the producer.** SPIRV-Cross reads `Offset`/`ArrayStride`/`MatrixStride` and never recomputes them; the CTFE layout engine that validates D structs must also be what decorates the SPIR-V, so host and generated GLSL/HLSL/MSL cannot disagree.
- **Plan WGSL and DXIL around it, not through it.** SPIRV-Cross has no WGSL backend and HLSL output still needs DXC; ray-tracing pipelines reach only Vulkan GLSL, geometry shaders not MSL, tessellation not HLSL. The capability matrix above is the per-target tier table the specification needs.
- **Pin it and review bumps as output changes** (`SHT2`): 64 commits between the toolchain pin and the clone include long-vector and reconvergence support and control-flow fixes, any of which can change generated text.

## Strengths

- **The only translator that reaches GLSL ES 1.00 and desktop GLSL 1.x** from SPIR-V, plus every modern GLSL, HLSL and MSL.
- **Readable output** with original names, structured control flow and human-style declarations.
- **Broad, maintained MSL backend** (MoltenVK's production path): argument buffers, emulated tessellation, mesh, ray queries, native pointers.
- **Reflection and remapping APIs** that let one SPIR-V module serve several binding models.
- **A stable C API**, easy to bind from D, and an Apache-2.0 licence.

## Weaknesses

- **Structured, logical SPIR-V only**: no `Kernel`, `VariablePointers`, general `OpPtrAccessChain` or untyped pointers; unstructured branches duplicate code.
- **Uneven checking for legacy targets**: some unsupported constructs throw, others are emitted verbatim and fail later in the driver or glslang.
- **No WGSL or DXIL output**; HLSL output needs another compiler, and HLSL lacks tessellation and ray-tracing stages.
- **Silent renaming** of reserved and keyword-colliding names breaks hosts that bind by name.
- **CLI conveniences differ from library behaviour** (combined-sampler naming, dummy sampler), so moving between them changes output.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                  | Trade-off                                                                                  |
| ----------------------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Decompile to readable high-level source               | output can be debugged, reviewed and hand-tuned; drivers see familiar code | needs structured control flow; irreducible or unstructured CFGs are duplicated or rejected |
| Use SPIR-V names verbatim, rewrite only reserved ones | legacy GLSL links by name; reflection stays faithful                       | the producer must emit valid, unreserved `OpName`s or bindings silently break              |
| One `CompilerGLSL` base for HLSL and MSL              | shared expression and control-flow emission                                | target-specific gaps surface as scattered throws rather than a declared feature table      |
| Combined image-samplers built on request              | GLSL needs `sampler2D`; Vulkan/HLSL/MSL keep separate objects              | the caller must call `build_combined_image_samplers()` and name the results                |
| Layout read from decorations                          | exact reproduction of the producer's layout                                | missing or non-`std140`/`std430` decorations throw on some targets                         |
| C89 wrapper as the stable ABI                         | usable from any language, shared-library safe                              | C++ API features arrive in C later; option plumbing is verbose                             |
| Multi-pass emission with forced recompiles            | discovers needs (ladder breaks, temporaries) without a full pre-analysis   | slower; non-convergence is a hard error                                                    |

## Sources

- [KhronosGroup/SPIRV-Cross at `300681bb`][repo] — [`README.md`][readme] ([features][readme-features], [C API][readme-capi], [separate image samplers][readme-combined], [descriptor sets][readme-sets], [linking by name][readme-linking], [reserved identifiers][readme-reserved]); [`LICENSE`][license]
- Source: [`spirv_parser.cpp`][parser], [`spirv_cross_parsed_ir.cpp`][parsed-ir], [`spirv_cross.cpp`][cross], [`spirv_glsl.cpp`][glsl-cpp], [`spirv_glsl.hpp`][glsl-opts], [`spirv_hlsl.cpp`][hlsl-cpp], [`spirv_hlsl.hpp`][hlsl-sm], [`spirv_msl.cpp`][msl-cpp], [`spirv_msl.hpp`][msl-opts], [`spirv_cross_c.h`][c-api], [`main.cpp`][main-help]
- sparkles: [`SPEC.md`][sparkles-spec] (`SHF2`, `SHP4`–`SHP6`, `SHT2`), [`decisions.md`][sparkles-decisions] (D7, D15), [`apps/shader-compile/src/app.d`][app-d]
- Related: [GLSL][glsl] · [HLSL][hlsl] · [MSL][msl] · [WGSL][wgsl] · [naga][naga] · [Tint][tint] · [LLVM SPIR-V backend][llvm-spirv] · [DXC][dxc] · [concepts][concepts] · [comparison][comparison] · [index][index]

<!-- References -->

[repo]: https://github.com/KhronosGroup/SPIRV-Cross/tree/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1
[license]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/LICENSE
[readme]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/README.md
[readme-features]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/README.md#L13-L28
[readme-capi]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/README.md#L132-L140
[readme-combined]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/README.md#L385-L404
[readme-sets]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/README.md#L406-L427
[readme-linking]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/README.md#L429-L434
[readme-reserved]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/README.md#L450-L471
[parser]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_parser.cpp
[parser-kernel]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_parser.cpp#L293-L294
[parser-untyped]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_parser.cpp#L884
[parser-phi]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_parser.cpp#L1060
[parsed-ir]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_cross_parsed_ir.cpp
[parsed-ir-reserved]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_cross_parsed_ir.cpp#L195-L258
[cross]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_cross.cpp
[cross-name]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_cross.cpp#L346-L351
[glsl-cpp]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp
[glsl-maxloops]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L355
[glsl-types]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L445-L478
[glsl-compute]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L484-L489
[glsl-rt]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L513-L523
[glsl-mesh]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L546-L553
[glsl-addr]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L594-L607
[glsl-varptr]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L635-L637
[glsl-ssbo]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L2574
[glsl-specmacro]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L3206
[glsl-keywords]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L3306-L3400
[fork-reserved]: https://github.com/PetarKirov/ldc/blob/64104a9a6da522730d6b661b85adfdfd2e7e25e7/gen/dcompute/targetVulkan.cpp#L545-L622
[glsl-uint]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L6138
[glsl-texsize]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L8022
[glsl-ptrac]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L11023-L11026
[glsl-untyped]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L13243-L13272
[glsl-bitops]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L14405-L14453
[glsl-member]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L16853
[glsl-ladder]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L18489-L18495
[glsl-inline]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L18523-L18524
[glsl-switch]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L19254-L19259
[glsl-spvdummy]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.cpp#L19435-L19450
[glsl-opts]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.hpp#L84
[glsl-precision]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.hpp#L196-L197
[glsl-legacy]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_glsl.hpp#L958-L980
[hlsl-cpp]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_hlsl.cpp
[hlsl-stages]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_hlsl.cpp#L3075-L3098
[hlsl-addr]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_hlsl.cpp#L7139-L7140
[hlsl-sm]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_hlsl.hpp#L112
[hlsl-binding]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_hlsl.hpp#L222
[msl-cpp]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_msl.cpp
[msl-native]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_msl.cpp#L1705
[msl-barrier]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_msl.cpp#L10488-L10493
[msl-tess]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_msl.cpp#L14684-L14705
[msl-opts]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_msl.hpp#L305-L306
[msl-binding]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_msl.hpp#L699
[c-api]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/spirv_cross_c.h
[main-help]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/main.cpp
[main-glsl-setup]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/main.cpp#L1336-L1342
[main-combined]: https://github.com/KhronosGroup/SPIRV-Cross/blob/300681bbcb8365a8d1eacdacdbdd0249bbf1d6b1/main.cpp#L1585-L1599
[sparkles-spec]: ../../specs/shaders/SPEC.md
[sparkles-decisions]: ../../specs/shaders/decisions.md
[app-d]: ../../../apps/shader-compile/src/app.d
[glsl]: ./glsl.md
[hlsl]: ./hlsl.md
[msl]: ./msl.md
[wgsl]: ./wgsl.md
[naga]: ./naga.md
[tint]: ./tint.md
[llvm-spirv]: ./llvm-spirv-backend.md
[dxc]: ./dxc.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
