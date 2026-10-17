# Tint (C++ / Dawn)

Google's WGSL compiler inside Dawn, Chromium's WebGPU implementation: a WGSL front end with the reference implementation of WGSL's uniformity analysis, a SPIR-V reader that turns Vulkan-1.1 SPIR-V into WGSL, and SPIR-V, HLSL, MSL and GLSL writers over a shared structured IR — the strictest WGSL gate a `sparkles:shaders` module could be held to.

| Field          | Value                                                                                                                                                |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | C++ (Dawn and Tint share one build: CMake, GN, Bazel)                                                                                                |
| License        | BSD-3-Clause (_"Copyright 2017-2026 The Dawn & Tint Authors"_, [`LICENSE`][license])                                                                 |
| Repository     | [google/dawn][repo] — `src/tint/`, `docs/tint/`; cited at [`67d4d6e6`][tree] (2026-10-16). Canonical host: [dawn.googlesource.com][googlesource]     |
| Documentation  | [`docs/tint/`][docs-dir]: [`arch.md`][arch], [`ir.md`][ir-doc], [`spirv-reader-overview.md`][reader-doc], [`uniformity_analysis.md`][uniformity-doc] |
| Category       | Toolchain — WGSL compiler and shader translator                                                                                                      |
| Latest version | Unversioned; ships continuously with Dawn and Chromium. This survey reads Dawn `main` at `67d4d6e6`                                                  |
| Readers        | WGSL (always), SPIR-V (`TINT_BUILD_SPV_READER`, on with Dawn's Vulkan backend)                                                                       |
| Writers        | SPIR-V (1.3, 1.4; 1.5 for testing), HLSL (for FXC or DXC), MSL, GLSL (desktop or ES, default ES 3.1), WGSL, null                                     |
| Consumers      | Dawn — _"the underlying implementation of WebGPU in Chromium"_ ([`README.md`][dawn-readme]); the standalone `tint` CLI (`src/tint/cmd/tint`)         |

---

## Overview

### What it solves

A browser cannot hand web content's shaders to a driver. WebGPU therefore specifies its own
language, WGSL, with defined behaviour where SPIR-V, HLSL and MSL leave things undefined
(out-of-bounds accesses, integer division by zero, uniformity of barriers and derivatives).
Tint is Chromium's compiler for it: it parses and fully validates WGSL, then rewrites it into
whatever the platform API accepts — SPIR-V for Vulkan, HLSL for D3D, MSL for Metal, GLSL for
OpenGL ES/desktop GL — injecting robustness checks and polyfills on the way. The Dawn
README describes it as _"a compiler for the WebGPU Shader Language (WGSL) that can be used in
standalone to convert shaders from and to WGSL"_ ([`README.md`][dawn-readme]).

Its SPIR-V reader is the other direction: SPIR-V produced by glslang, DXC or another
compiler is converted to WGSL so that native Dawn users (and WebGPU tooling) can bring
existing shaders. For `sparkles:shaders` this is the second SPIR-V → WGSL route beside
[naga][naga], and the one that enforces the WGSL specification most faithfully.

### Design philosophy

Tint's documents frame two commitments. Safety first, from
[`uniformity_analysis.md`][uniformity-doc]:

> _"WebGPU is designed to execute untrusted web content, so additional hardening against
> these negative outcomes is strictly necessary because that execution happens in a shared
> GPU context with less process isolation than other tightly sandboxed web APIs typically
> have."_

and conservatism over completeness: the analysis _"will produce false negatives by rejecting
WGSL that would actually be uniform at runtime, but it errs on the side of caution"_. The
second commitment is a small, mutable IR for every transform; [`ir.md`][ir-doc] records why
it replaced AST rewriting: _"Transforms rebuild the AST and SEM which causes slowness"_ and
_"instead of `for`, `while` and `loop` constructs there is a single `loop` construct."_

---

## How it works

### Layers

```text
WGSL text ─► wgsl::reader (recursive descent, AST) ─► Resolver (types, sem, uniformity) ─► Program
                                                                       │ ProgramToIR
SPIR-V ─► spirv::reader::ReadIR (validate Vulkan 1.1, parse) ─► core::ir::Module ◄─┘
                                                   │ transforms (robustness, polyfills, …)
                         ┌─────────────┬───────────┼───────────┬─────────────┐
                    spirv::writer  hlsl::writer  msl::writer  glsl::writer  wgsl::writer (IRToProgram)
```

The WGSL side ([`arch.md`][arch]) builds an AST into a `ProgramBuilder`; `Resolve()` performs
validation and semantic analysis into an immutable `Program`. `wgsl::reader::ProgramToIR`
lowers it into `core::ir` ([`src/tint/lang/core/ir/`][core-ir]). The IR has `blocks`,
`values` and `instructions`; control instructions (`if`, `switch`, `loop`) own their blocks,
and every block ends in a terminator — `exit_if`, `exit_switch`, `exit_loop`, `break_if`,
`continue`, `next_iteration`, `return`, `unreachable` — that may carry values out of the
construct ([`ir.md`][ir-doc]). Structure is therefore explicit and nesting-checked by the IR
validator. Each writer has a `raise` stage of target-specific transforms
(`src/tint/lang/*/writer/raise/`) before its printer.

### Shared transforms

`src/tint/lang/core/ir/transform/` holds the cross-target passes, among them `robustness`,
`demote_to_helper`, `zero_init_workgroup_memory`, `prevent_infinite_loops`,
`preserve_padding`, `binding_remapper`, `vertex_pulling`, `direct_variable_access`,
`builtin_polyfill`, `signed_integer_polyfill`, `multiplanar_external_texture`,
`substitute_overrides` and `single_entry_point`. `Robustness`
([`robustness.h`][robustness]) clamps texture, storage, uniform and immediate accesses by
configuration, optionally using integer range analysis to skip provably in-bounds indices.

---

## Execution model and stages

WGSL's three stages only: `@vertex`, `@fragment`, `@compute` with `@workgroup_size`. Entry
inputs and outputs are parameters and return values with `@builtin`, `@location`,
`@interpolate` attributes; module-scope I/O variables do not exist in WGSL. The SPIR-V
reader converts Vulkan's Input/Output variables into entry parameters and results
(`lower/shader_io.cc`), keeps only `gl_Position` from a `gl_PerVertex` block, and requires
any `gl_PointSize` assignment to be the constant `1.0` — _"It's a WGSL rule"_
([`spirv-reader-overview.md`][reader-doc]). Geometry, tessellation, mesh and ray-tracing
stages have no WGSL form and no Tint path. The parser sets
`kAllowMultipleEntryPoints` on SPIR-V-derived modules, and a `single_entry_point` IR
transform exists to strip a module down to one entry point.

## Type system and generic programming

WGSL's types: `bool`, `i32`, `u32`, `f32`, `f16` (with `enable f16`), abstract numeric
types for constant expressions, `vecN<T>`, `matCxR<T>`, fixed and runtime arrays, structures,
atomics, pointers and references with explicit address space and access mode, textures,
samplers, and subgroup-matrix types under a Chromium extension. Semantic types are
deduplicated — _"you can compare `type::Type*` pointers to check for type equivalence"_
([`arch.md`][arch]). There are no user generics; built-in overloads are described in
TableGen-like `.def` files ([`wgsl.def`][wgsl-def], `core.def`) from which the intrinsic
tables are generated.

The SPIR-V reader's type gate is narrow ([`parser.cc`][reader-parser], `ValidateTypes`):
**integer types must be 32-bit** (`"unsupported integer width"`), arrays of images,
samplers or buffer blocks are rejected (`"arrays of handle types are not supported"`,
`"arrays of buffer types are not supported"`), specialised array lengths are rejected, and
the only accepted type decorations are `Block`, `BufferBlock` and `ArrayStride`. SPIR-V's
per-instruction signedness is rewritten into WGSL's same-signedness operators with
`bitcast`s; strided arrays and row-major or strided matrices are decomposed by
`lower/decompose_strided_array.cc`, `decompose_strided_matrix.cc` and
`transpose_row_major.cc`.

## Resources, interfaces and memory layout

WGSL binds resources as `@group(g) @binding(b)` module-scope variables in the `uniform`,
`storage` (with `read` or `read_write`) and `handle` address spaces; immediates (push
constants) are a language feature (`immediate_address_space`). Layout follows WGSL's
"internal layout of values": uniform buffers use std140-like rules unless the
`uniform_buffer_standard_layout` language feature is on. The SPIR-V reader validates its
input with `uniform_buffer_standard_layout = true` ([`parser.cc`][reader-parser]), then
`RemapBufferBlockAddressSpace` moves old-style `BufferBlock` uniforms into `storage`.

Writers absorb the target layouts: HLSL storage buffers become `ByteAddressBuffer`
/`RWByteAddressBuffer` with explicit offsets (the HLSL `raise` stage's
`decompose_storage_access`), MSL marks read-only access `const`, and SPIR-V expresses
read-only through member `NonWritable` decorations ([`translations.md`][translations]).
Combined image-samplers in SPIR-V input are split by SPIRV-Tools'
`SplitCombinedImageSamplerPass` before parsing, and binding conflicts are resolved by
`ResolveBindingConflictsPass`.

## Built-in library and intrinsics

WGSL's built-in function library is defined in [`wgsl.def`][wgsl-def]; Tint lowers it to
`core` builtins and each writer maps or polyfills them (`builtin_polyfill`,
`builtin_scalarize`, `conversion_polyfill`, and per-writer option structs listing
workarounds such as `polyfill_reflect_vec2_f32` or `polyfill_dot_4x8_packed` in
[`hlsl/writer/common/options.h`][hlsl-options]). Extensions are explicit `enable` directives;
at this revision [`wgsl.def`][wgsl-def] lists the standardised `f16`, `clip_distances`,
`dual_source_blending`, `subgroups`, `primitive_index`, `subgroup_size_control` and
`atomic_vec2u_min_max`, Chromium-only experiments (`chromium_disable_uniformity_analysis`,
input attachments, pixel-local storage, framebuffer fetch, subgroup matrices, barycentrics,
resource tables) and `view_instancing`; language features include
`unrestricted_pointer_parameters`, `pointer_composite_access`, `subgroup_uniformity`,
`swizzle_assignment`, `texel_buffers` and `buffer_view`.

The SPIR-V reader's capability allow-list ([`parser.cc`][reader-parser]) is: `ClipDistance`,
`DerivativeControl`, `Float16`, `Geometry`, `GroupNonUniform`
(`…Arithmetic`, `…Ballot`, `…Quad`, `…Shuffle`, `…ShuffleRelative`, `…Vote`), `Image1D`,
`ImageQuery`, `InputAttachment`, `Matrix`, `MultiView`, `Sampled1D`, `SampledCubeArray`,
`SampleRateShading`, `Shader`, 16-bit storage capabilities, `StorageImageExtendedFormats`,
`VulkanMemoryModel`, `VulkanMemoryModelDeviceScope`. Extensions allowed:
`SPV_KHR_storage_buffer_storage_class`, `SPV_KHR_non_semantic_info`,
`SPV_KHR_16bit_storage`, **`SPV_KHR_terminate_invocation`**, `SPV_KHR_multiview`,
`SPV_KHR_vulkan_memory_model`. Extended instruction sets: `GLSL.std.450` and ignored
`NonSemantic.*`. Absent: `Int8`, `Int16`, `Int64`, `Float64`,
`PhysicalStorageBufferAddresses`, `VariablePointers`, `DemoteToHelperInvocation`, ray
tracing, mesh. `OpKill` and `OpTerminateInvocation` are both accepted and become WGSL
`discard`.

## Control flow, memory model and restrictions

Control flow is structured at every layer; WGSL forbids recursion and unstructured jumps,
and requires behaviour analysis (no statement after an unconditional exit, which is why the
SPIR-V path removes unreachable statements). Three WGSL rules shape what reaches a driver:

- **Uniformity analysis** ([`uniformity.cc`][uniformity-cc]) builds a directed dependency
  graph from values and control points to `RequiredToBeUniform` nodes for barriers,
  derivatives, implicit-LOD sampling and subgroup operations, with severity from diagnostic
  filters — the only filterable rules are `derivative_uniformity` and
  `subgroup_uniformity` ([`wgsl.def`][wgsl-def]), so barrier uniformity cannot be relaxed. It is the reference behaviour that [naga][naga] does not match for
  derivatives.
- **`discard` is demote.** WGSL's `discard` turns the invocation into a helper so quad
  derivatives stay defined. `DemoteToHelper` ([`demote_to_helper.h`][demote]) emulates that
  _"for backend targets that implement discard by terminating the invocation … by setting a
  global flag and masking all writes to storage buffers and textures"_.
- **Defined out-of-bounds and termination.** `Robustness` clamps indices;
  `prevent_infinite_loops` injects an extra exit condition _"to prevent downstream
  compilers from making bad assumptions due to the undefined behavior of infinite loops"_;
  workgroup memory is zero-initialised.

**The SPIR-V reader targets Vulkan 1.1.** Its first step validates the binary with SPIRV-Tools
against `constexpr auto kTargetEnv = SPV_ENV_VULKAN_1_1;` ([`parser.cc`][reader-parser]),
confirming the overview's _"validated against rules for Vulkan 1.1"_
([`spirv-reader-overview.md`][reader-doc]). Vulkan 1.1 accepts SPIR-V up to 1.3; a SPIR-V 1.6
module, as `ldc-vulkan` now emits, is outside that environment. (Inferred from SPIRV-Tools'
version-per-environment rule; not run against a sparkles module here.) The output of the
reader must then pass WGSL validation: in Dawn, `ParseSPIRV` converts the IR to a WGSL
`Program` and resolves it, with `allow_non_uniform_derivatives` as the one relaxation
([`ShaderModule.cpp`][dawn-shadermodule]).

## Compilation pipeline and targets

| Writer | Output and options                                                                                                                                           |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| SPIR-V | `SpvVersion::kSpv13`, `kSpv14` (`kSpv15` _"for testing purposes only"_) ([`spirv/writer/common/options.h`][spirv-options]); Dawn's Vulkan backend            |
| HLSL   | `Compiler::kFXC`, `kDXC_2018`, `kDXC_2021` downstream targets, plus per-feature polyfills ([`hlsl/writer/common/options.h`][hlsl-options]); Dawn D3D11/D3D12 |
| MSL    | Per-Metal-version extension options (e.g. `disable_demote_to_helper`); Dawn's Metal backend                                                                  |
| GLSL   | `Version { Standard::kDesktop or kES, major, minor }`, default ES 3.1 ([`glsl/writer/common/version.h`][glsl-version]); Dawn's OpenGL/GLES backend           |
| WGSL   | `IRToProgram` + printer; used by the SPIR-V → WGSL path and round-trip tests                                                                                 |

Each language has a `validate` directory that runs the real downstream tool in tests (DXC,
the Metal compiler, glslang), and Dawn exposes `enable_spirv_validation` to validate Tint's
SPIR-V output ([`Toggles.cpp`][dawn-toggles]). There is no DXIL writer: D3D gets HLSL text
for FXC or DXC.

## Host integration and CPU execution

Tint is embedded: Dawn calls the WGSL reader for every `createShaderModule`, the inspector
(`src/tint/lang/wgsl/inspector`) for reflection (entry points, bindings, overrides), and a
writer per pipeline with that pipeline's overrides and binding remapping. The SPIR-V path is
for native Dawn only; Chromium can switch it off entirely with the `disallow_spirv` toggle —
_"useful to prevent a Chromium renderer process from successfully sending SPIR-V code to be
compiled in the GPU process"_ ([`Toggles.cpp`][dawn-toggles]). Firefox uses `wgpu`/[naga][naga]
instead; Safari's WebGPU uses WebKit's own WGSL compiler (not verified against a pinned
source here). There is no CPU execution; a `null`
writer exists for testing.

---

## Lessons for sparkles:shaders

- **Adopt: Tint as the strict WGSL oracle.** When the vocabulary claims WGSL output, run the
  `tint` CLI over the generated WGSL (from naga or a future D emitter) in the build step; its
  uniformity analysis is the specification's, naga's is relaxed.
- **Match: the Vulkan 1.1 / SPIR-V 1.3 ingest profile.** If Tint's SPIR-V reader is a
  target, the build must emit (or down-convert to) SPIR-V 1.3 with 32-bit integers only, no
  `Float64`, no BDA, no demote — a third target profile beside "Vulkan 1.3" and "naga".
- **Adopt: `discard` means demote at the vocabulary level.** WGSL, HLSL SM 6 and SPIR-V 1.6
  agree on demote; GLSL/MSL/SM 5 terminate. Define the D `discard` once, and let a
  `DemoteToHelper`-style lowering (flag plus masked writes) restore the semantics on
  terminate-only targets, as Tint does — and do the same in the CPU simulator.
- **Match: defined out-of-bounds behaviour.** Adopt Tint's robustness contract (clamp
  indices per address space) as the vocabulary's semantics, so the CPU reference and every
  GPU target agree; leave an opt-out for trusted, measured hot paths.
- **Adopt: one structured IR with typed structured exits** (`exit_if`, `exit_loop`,
  `break_if`) as the model for a D-side shader IR; it is the form both a text emitter and an
  SPMD simulator consume without reconstruction.
- **Avoid: arrays of resources and narrow integers in WGSL-bound modules** — Tint's reader
  rejects both; enforce it in D when the WGSL profile is selected.

## Strengths

- Reference-quality WGSL validation, including the full uniformity analysis with diagnostic
  severities.
- One mutable structured IR shared by five writers and all transforms.
- Robustness, zero-initialisation and demote emulation built in, designed for untrusted
  input.
- Extensive per-target workaround options; each output validated with the real downstream
  compiler in tests.

## Weaknesses

- WGSL's three stages only; no geometry, tessellation, mesh or ray tracing.
- The SPIR-V reader validates against Vulkan 1.1 and accepts only 32-bit integers, a fixed
  capability list and no arrays of handles or buffers.
- SPIR-V writer limited to 1.3/1.4; no DXIL, no AIR.
- Tied to Dawn's build; no releases or semantic versions, consumed at a commit.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                                    | Trade-off                                                             |
| ----------------------------------------------- | ------------------------------------------------------------ | --------------------------------------------------------------------- |
| Conservative static uniformity analysis         | Barriers and derivatives must be safe for untrusted content  | Rejects some programs that are uniform at run time                    |
| WGSL `discard` as demote, emulated where needed | Keeps derivatives defined after discard on every target      | Extra flag and masked writes on terminate-only backends               |
| AST for WGSL, IR for transforms and writers     | Faithful diagnostics on source; fast, simple transforms      | Two representations and a lossy AST ↔ IR round trip                   |
| SPIR-V input validated as Vulkan 1.1            | One well-understood environment, fewer features to translate | Modern SPIR-V (1.4+, BDA, 64-bit) is out of scope                     |
| SPIR-V converted to WGSL, then re-validated     | Every shader passes the same WGSL rules regardless of source | SPIR-V must fit WGSL's type and uniformity rules, not just Vulkan's   |
| Robustness as a configurable IR transform       | Defined OOB behaviour per address space and per binding      | Index clamps cost instructions unless range analysis proves them away |

## Sources

- [google/dawn at `67d4d6e6`][tree] — `src/tint/`, `docs/tint/` · [dawn.googlesource.com][googlesource]
- [Dawn `README.md`][dawn-readme] · [`LICENSE`][license]
- [`docs/tint/arch.md`][arch] · [`docs/tint/ir.md`][ir-doc] ·
  [`docs/tint/spirv-reader-overview.md`][reader-doc] ·
  [`docs/tint/uniformity_analysis.md`][uniformity-doc] · [`docs/tint/translations.md`][translations]
- [`src/tint/lang/spirv/reader/parser/parser.cc` — SPIR-V reader gates][reader-parser]
- [`src/tint/lang/wgsl/wgsl.def` — extensions, language features, builtins][wgsl-def] ·
  [`src/tint/lang/wgsl/resolver/uniformity.cc`][uniformity-cc]
- [`src/tint/lang/core/ir/`][core-ir] · [`transform/robustness.h`][robustness] ·
  [`transform/demote_to_helper.h`][demote]
- [`spirv/writer/common/options.h`][spirv-options] · [`hlsl/writer/common/options.h`][hlsl-options] ·
  [`glsl/writer/common/version.h`][glsl-version]
- [`src/dawn/native/ShaderModule.cpp` — SPIR-V ingestion][dawn-shadermodule] ·
  [`src/dawn/native/Toggles.cpp`][dawn-toggles]
- Related: [naga][naga] · [WGSL][wgsl] · [SPIRV-Cross][spirv-cross] ·
  [LLVM SPIR-V backend][llvm-spirv] · [DXC][dxc] · [Concepts][concepts] ·
  [Comparison][comparison] · [Index][index] · [`sparkles:shaders` SPEC][spec]

<!-- References -->

[repo]: https://github.com/google/dawn
[tree]: https://github.com/google/dawn/tree/67d4d6e64b0755d638f76549794692badfdbc8ab/src/tint
[googlesource]: https://dawn.googlesource.com/dawn
[license]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/LICENSE
[dawn-readme]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/README.md
[docs-dir]: https://github.com/google/dawn/tree/67d4d6e64b0755d638f76549794692badfdbc8ab/docs/tint
[arch]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/docs/tint/arch.md
[ir-doc]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/docs/tint/ir.md
[reader-doc]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/docs/tint/spirv-reader-overview.md
[uniformity-doc]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/docs/tint/uniformity_analysis.md
[translations]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/docs/tint/translations.md
[reader-parser]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/src/tint/lang/spirv/reader/parser/parser.cc
[wgsl-def]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/src/tint/lang/wgsl/wgsl.def
[uniformity-cc]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/src/tint/lang/wgsl/resolver/uniformity.cc
[core-ir]: https://github.com/google/dawn/tree/67d4d6e64b0755d638f76549794692badfdbc8ab/src/tint/lang/core/ir
[robustness]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/src/tint/lang/core/ir/transform/robustness.h
[demote]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/src/tint/lang/core/ir/transform/demote_to_helper.h
[spirv-options]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/src/tint/lang/spirv/writer/common/options.h
[hlsl-options]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/src/tint/lang/hlsl/writer/common/options.h
[glsl-version]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/src/tint/lang/glsl/writer/common/version.h
[dawn-shadermodule]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/src/dawn/native/ShaderModule.cpp
[dawn-toggles]: https://github.com/google/dawn/blob/67d4d6e64b0755d638f76549794692badfdbc8ab/src/dawn/native/Toggles.cpp
[naga]: ./naga.md
[wgsl]: ./wgsl.md
[spirv-cross]: ./spirv-cross.md
[llvm-spirv]: ./llvm-spirv-backend.md
[dxc]: ./dxc.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[spec]: ../../specs/shaders/SPEC.md
