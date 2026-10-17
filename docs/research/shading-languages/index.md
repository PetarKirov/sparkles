# Shading Languages and Single-Source GPU Programming

A survey of the languages GPU code is written in, the host languages that compile
their own code for the GPU, and the toolchains between them — the evidence base for
growing [`sparkles:shaders`][shaders-spec] from a fragment-shader vocabulary into a
complete single-source replacement for GLSL, HLSL, Slang, WGSL and MSL. It covers
five shading languages, twelve single-source systems (D's own [dcompute][dcompute]
among them) and seven compilers and translators, each read from its source tree at
a pinned revision.

The survey answers seven questions:

1. **What must a complete replacement express?** The stages, types, resources and
   built-ins of the five shading languages, and where they diverge —
   [GLSL][glsl], [HLSL][hlsl], [Slang][slang], [WGSL][wgsl], [MSL][msl], and the
   [capability matrix](./comparison.md#the-capability-matrix).
2. **How do other host languages compile their own code for the GPU, and what do they
   restrict?** [rust-gpu][rust-gpu], [CUDA and HIP][cuda-hip], [SYCL][sycl],
   [Circle][circle], [Vcc and Shady][vcc-shady], [TypeGPU][typegpu],
   [ComputeSharp][computesharp], [ILGPU][ilgpu], [Julia][julia], [Zig][zig-spirv];
   synthesis in [the single-source spectrum](./comparison.md#the-single-source-spectrum).
3. **How do shaders run on a CPU with their GPU semantics?** The SPMD-on-SIMD model of
   [ISPC][ispc], ILGPU's two CPU accelerators, HIP-CPU's fibers, SYCL's abandoned host
   device; synthesis in [CPU execution](./comparison.md#cpu-execution).
4. **What can the LLVM toolchain sparkles builds on emit, and what does it get
   wrong?** [LLVM's SPIR-V backend][llvm-spirv], [Clang HLSL][clang-hlsl] (which
   drives it), [DXC][dxc] as the reference it is measured against.
5. **What does each translator accept, and so which targets can one SPIR-V module
   reach?** [SPIRV-Cross][spirv-cross], [naga][naga], [Tint][tint]; synthesis in
   [the translation ceiling](./comparison.md#the-translation-ceiling).
6. **Would MLIR serve shaders better than LLVM IR?** [MLIR's SPIR-V dialect][mlir] and
   the LDC MLIR effort.
7. **Where does sparkles stand against all of it?** The
   [delta table](./comparison.md#delta-table) and the
   [recommendations](./comparison.md#recommendations).

The vocabulary is defined once in [Concepts](./concepts.md); the deep-dives link to it.

**Last reviewed:** October 17, 2026

> [!NOTE]
> Every GitHub citation is pinned to a commit, read from a local clone at that
> commit; non-GitHub sources (the Khronos registry, the W3C, Apple, Microsoft Learn,
> NVIDIA) are cited by URL. Claims a deep-dive could not verify against a pinned
> source say so where they are made. Three [runnable examples](#runnable-examples)
> compile D shaders with the toolchain sparkles ships and check claims this catalog
> makes about it.

---

## Master catalog

### Shading languages

| Language               | Owner               | Latest (at review)                                                  | Reaches                                         | Link           |
| ---------------------- | ------------------- | ------------------------------------------------------------------- | ----------------------------------------------- | -------------- |
| GLSL (GL, ES, Vulkan)  | Khronos             | GLSL 4.60 rev 9, ES 3.20 rev 9; growth by extension only            | OpenGL/ES drivers; SPIR-V via glslang           | [GLSL][glsl]   |
| HLSL                   | Microsoft           | Shader Model 6.9 retail (DXC `v1.9.2602`, 2026-02-20); 6.10 preview | DXIL (D3D12), SPIR-V (DXC `-spirv`, Clang)      | [HLSL][hlsl]   |
| Slang                  | Khronos (ex-NVIDIA) | `v2026.20` (2026-10-16); language editions `2025`, `2026`           | SPIR-V, DXIL, Metal, WGSL, CUDA, C++, LLVM      | [Slang][slang] |
| WGSL                   | W3C GPU for the Web | Candidate Recommendation Draft, 2026-09-21; no version numbers      | WebGPU (Tint, naga, WebKit) → SPIR-V, HLSL, MSL | [WGSL][wgsl]   |
| Metal Shading Language | Apple               | MSL 4.1 (2026-06-04), C++17-based                                   | AIR / `metallib` (Apple GPUs)                   | [MSL][msl]     |

### Single-source systems

| System                        | Host language  | Latest (at review)                         | Device targets                                                    | Graphics stages                           | CPU execution of device code            | Link                         |
| ----------------------------- | -------------- | ------------------------------------------ | ----------------------------------------------------------------- | ----------------------------------------- | --------------------------------------- | ---------------------------- |
| dcompute + `sparkles:shaders` | D (LDC)        | LDC `v1.43.0`; fork `64104a9a`             | OpenCL SPIR-V, PTX; Vulkan SPIR-V (compute; fragment in fork)     | fragment                                  | host build of host-and-device modules   | [dcompute][dcompute]         |
| rust-gpu                      | Rust (nightly) | `0.11.0` (2026-10-13)                      | Vulkan/OpenGL SPIR-V; WGSL via naga                               | all                                       | shared crates; GPU built-ins panic      | [rust-gpu][rust-gpu]         |
| CUDA, HIP                     | C++            | CUDA guide 13.4.2; HIP `7.13.0`            | PTX, AMDGCN, SPIR-V (chipStar, `amdgcnspirv`)                     | none                                      | none (HIP-CPU: one fiber per thread)    | [CUDA and HIP][cuda-hip]     |
| SYCL                          | C++17/20       | SYCL 2020 rev 12; AdaptiveCpp `v25.10.0`   | Level Zero SPIR-V, PTX, AMDGCN, host CPU; Vulkan experimental     | none                                      | CPU backends; host device removed       | [SYCL][sycl]                 |
| Circle                        | C++20 + Circle | unversioned; shaders repo to 2022-03-09    | Vulkan/OpenGL SPIR-V, DXIL (offline), PTX                         | all                                       | same AST lowers to x86-64               | [Circle][circle]             |
| Vcc / Shady                   | C/C++ (Clang)  | unreleased; commit `dd2787a7` (2025-10-17) | Vulkan SPIR-V; C11, GLSL, ISPC, CUDA dialects                     | vertex, fragment, compute, ray generation | via its C/ISPC backends                 | [Vcc and Shady][vcc-shady]   |
| TypeGPU                       | TypeScript     | `0.12.8` (2026-10-16)                      | WGSL; GLSL ES 3.00 (experimental)                                 | vertex, fragment, compute                 | one invocation at a time                | [TypeGPU][typegpu]           |
| ComputeSharp                  | C#             | `v3.2.0`; `4.0.0` unreleased               | HLSL → DXIL, DXBC (Direct2D)                                      | Direct2D pixel                            | built-ins return `default`              | [ComputeSharp][computesharp] |
| ILGPU                         | .NET IL        | `v1.5.3`; master `2.0.0-beta1`             | PTX, OpenCL C, CUDA C++, HIP, MSL, vectorized C#                  | none                                      | CPU accelerator: threads, or SIMD lanes | [ILGPU][ilgpu]               |
| ISPC                          | C dialect      | `v1.32.0` (2026-10-13)                     | x86 SSE2–AVX10.2, NEON, Intel Xe GPUs                             | none                                      | is the CPU target (SPMD on SIMD)        | [ISPC][ispc]                 |
| Julia GPU stack               | Julia          | GPUCompiler `2.15.1`; Lava.jl `0.1.0`      | PTX, AMDGCN, Metal AIR, SPIR-V; Vulkan SPIR-V (Lava, own emitter) | Lava only                                 | KernelAbstractions CPU backend          | [Julia][julia]               |
| Zig                           | Zig            | `0.17.0` (2026-10-01)                      | Vulkan, OpenGL, OpenCL SPIR-V                                     | vertex, fragment, compute, task, mesh     | native build                            | [Zig][zig-spirv]             |

### Compilers and translators

| Tool                 | Kind                       | Input → output                                        | Latest (at review)                     | Link                       |
| -------------------- | -------------------------- | ----------------------------------------------------- | -------------------------------------- | -------------------------- |
| LLVM SPIR-V backend  | compiler back end          | LLVM IR → SPIR-V 1.0–1.6 (kernel and shader)          | LLVM `main` `27ba4937` (2026-09-19)    | [LLVM SPIR-V][llvm-spirv]  |
| Clang HLSL           | front end + two back ends  | HLSL 202x → DXIL (DirectX backend), SPIR-V            | LLVM `main`, not complete in a release | [Clang HLSL][clang-hlsl]   |
| DXC                  | front end + two back ends  | HLSL → DXIL, SPIR-V (`-spirv`), Metal (via converter) | `v1.9.2609` (2026-09-16)               | [DXC][dxc]                 |
| MLIR `spirv` dialect | IR + serializer            | MLIR (`scf`, `gpu`, …) → SPIR-V                       | LLVM `main` `27ba4937`                 | [MLIR SPIR-V][mlir]        |
| SPIRV-Cross          | translator                 | SPIR-V → GLSL, ESSL, HLSL, MSL, C++                   | `vulkan-sdk-1.4.357.0` (sparkles' pin) | [SPIRV-Cross][spirv-cross] |
| naga                 | translator + validator     | WGSL, SPIR-V, GLSL → WGSL, SPIR-V, GLSL, HLSL, MSL    | `v30.0.1` (2026-08-21)                 | [naga][naga]               |
| Tint                 | WGSL compiler + translator | WGSL, SPIR-V → SPIR-V, HLSL, MSL, GLSL, WGSL          | Dawn `main` `67d4d6e6`                 | [Tint][tint]               |

---

## Taxonomies

### By how device code is produced

| Model                                                 | Systems                                                                                                          |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Separate shading language, its own compiler           | [GLSL][glsl], [HLSL][hlsl], [Slang][slang], [WGSL][wgsl], [MSL][msl]                                             |
| Host compiler grows a GPU back end (from IR)          | [dcompute][dcompute], [rust-gpu][rust-gpu], [Zig][zig-spirv], [Julia][julia], [Vcc][vcc-shady], [Circle][circle] |
| Host compiler, single-source C++ offload model        | [CUDA and HIP][cuda-hip], [SYCL][sycl]                                                                           |
| Host-language subset translated to a shading language | [TypeGPU][typegpu] (→ WGSL), [ComputeSharp][computesharp] (→ HLSL), [ILGPU][ilgpu] (IL → PTX, OpenCL C, MSL)     |
| SPMD dialect for CPU SIMD                             | [ISPC][ispc]                                                                                                     |

### By how structured control flow is recovered

| Approach                                         | Systems                                                                                                                            |
| ------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| Structured by construction (the source language) | GLSL, HLSL (DXC), WGSL, MSL, Slang's own SPIR-V emitter, [Tint][tint], [naga][naga]                                                |
| Structurizer over an unstructured IR             | [LLVM SPIR-V backend][llvm-spirv] (+ sparkles' `StructurizeCFG` prelude), [rust-gpu][rust-gpu], [Zig][zig-spirv], [Lava.jl][julia] |
| Structured IR from the front end                 | [MLIR][mlir] (`scf` → `spirv`), Circle                                                                                             |
| Emulation of unstructured flow                   | [Vcc and Shady][vcc-shady] (continuations, at a performance and translator cost)                                                   |

### By CPU execution of GPU semantics

| Model                                              | Systems                                                                                |
| -------------------------------------------------- | -------------------------------------------------------------------------------------- |
| None: device code only runs on a GPU               | HLSL, GLSL, WGSL, MSL, CUDA                                                            |
| Pure functions shared; GPU built-ins absent on CPU | [rust-gpu][rust-gpu], [TypeGPU][typegpu], [ComputeSharp][computesharp], sparkles today |
| Thread or fiber per invocation (reference)         | [ILGPU][ilgpu] `v1.5.3`, HIP-CPU ([CUDA and HIP][cuda-hip]), SYCL CPU backends         |
| SIMD lanes under masks (SPMD on SIMD)              | [ISPC][ispc], ILGPU master's vectorized CPU target, [Vcc][vcc-shady]'s ISPC backend    |

---

## Milestones

| Date       | Milestone                                                                                                          | Where                                     |
| ---------- | ------------------------------------------------------------------------------------------------------------------ | ----------------------------------------- |
| 2007       | CUDA 1.0: single-source `__host__ __device__` C++ for GPUs                                                         | [CUDA and HIP][cuda-hip]                  |
| 2012       | ISPC paper (InPar 2012): SPMD on SIMD for CPUs                                                                     | [ISPC][ispc]                              |
| 2015       | SPIR-V 1.0 published with Vulkan 1.0's provisional spec                                                            | [Concepts][concepts]                      |
| 2017       | Shader Model 6.0 and DXIL: wave intrinsics; DXC open-sourced                                                       | [HLSL][hlsl], [DXC][dxc]                  |
| 2020-07-24 | rust-gpu's first commit (Embark Studios); community-owned since 2024-08-12                                         | [rust-gpu][rust-gpu]                      |
| 2020       | Circle C++ shaders; SYCL 2020                                                                                      | [Circle][circle], [SYCL][sycl]            |
| 2021       | SPIR-V 1.6: `OpTerminateInvocation`, demote in core                                                                | [Concepts][concepts]                      |
| 2022–2023  | Vulkan Roadmap 2022 profile; mesh shaders (`VK_EXT_mesh_shader`)                                                   | [GLSL][glsl]                              |
| 2024       | Slang moves to Khronos; Roadmap 2024 (maximal reconvergence, quad control)                                         | [Slang][slang]                            |
| 2024–2025  | LLVM SPIR-V backend gains shader (Vulkan) support driven by Clang HLSL                                             | [LLVM SPIR-V][llvm-spirv]                 |
| 2025       | Vcc presented (HPG 2025)                                                                                           | [Vcc and Shady][vcc-shady]                |
| 2026-02-20 | Shader Model 6.9 retail                                                                                            | [HLSL][hlsl]                              |
| 2026-09-21 | WGSL Candidate Recommendation Draft                                                                                | [WGSL][wgsl]                              |
| 2026-10-16 | LDC builds against MLIR again (ldc#5300); sparkles' toolchain emits SPIR-V 1.6 with structured control flow (#659) | [MLIR SPIR-V][mlir], [dcompute][dcompute] |

> [!NOTE]
> The SPIR-V, Vulkan, CUDA and Shader Model dates are the specifications' publication years;
> the others come from the deep-dives' cited histories. Where a deep-dive could
> not pin a date to a source it says so.

---

## Runnable examples

Each compiles a D device module with the toolchain the dev and CI shells provide
(`ldc2-vulkan`, `spirv-val`, `spirv-cross`), runs under `ci --example-files`, and
prints `SKIP:` where the tools are missing.

| Example                                                             | Shows                                                                                                 |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| [`structured_control_flow.d`](./examples/structured_control_flow.d) | Early returns, `break` and `continue` reach SPIR-V structured at `-O0` and `-O2`                      |
| [`uniform_shapes.d`](./examples/uniform_shapes.d)                   | A loose uniform is valid SPIR-V that Vulkan rejects (`UniformConstant-04655`)                         |
| [`translator_ceiling.d`](./examples/translator_ceiling.d)           | Demote reaches Vulkan GLSL and HLSL SM 6 but not GLSL 3.30, ES 3.00 or MSL 2.0; terminate reaches all |

---

## Suggested reading paths

- **Designing the next `sparkles:shaders` milestones:** [dcompute][dcompute] (the
  baseline) → [Comparison][comparison] (delta table, recommendations) →
  [LLVM SPIR-V backend][llvm-spirv] → [SPIRV-Cross][spirv-cross] → [Slang][slang].
- **The CPU simulator:** [Concepts: SPMD](./concepts.md#spmd-simt-and-simd) →
  [ISPC][ispc] → [ILGPU][ilgpu] → [CUDA and HIP][cuda-hip] (HIP-CPU) → [SYCL][sycl]
  (the host device's removal) → [Comparison: CPU execution](./comparison.md#cpu-execution).
- **Language surface:** [GLSL][glsl] → [HLSL][hlsl] → [Slang][slang] → [WGSL][wgsl]
  → [MSL][msl] → [Comparison: capability matrix](./comparison.md#the-capability-matrix).
- **Host-language precedents:** [rust-gpu][rust-gpu] → [Circle][circle] →
  [Vcc and Shady][vcc-shady] → [Zig][zig-spirv] → [TypeGPU][typegpu] →
  [ComputeSharp][computesharp].
- **The IR question:** [LLVM SPIR-V backend][llvm-spirv] → [MLIR SPIR-V][mlir] →
  [Clang HLSL][clang-hlsl] → [DXC][dxc].

## Sources

The deep-dives carry their own sources. This page's facts come from them; the pinned
clones are listed in each deep-dive's `Sources` section.

- [`sparkles:shaders` specification][shaders-spec] and its [plan][shaders-plan].

<!-- References -->

[shaders-spec]: ../../specs/shaders/SPEC.md
[shaders-plan]: ../../specs/shaders/PLAN.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
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
[dxc]: ./dxc.md
[mlir]: ./mlir-spirv.md
[spirv-cross]: ./spirv-cross.md
[naga]: ./naga.md
[tint]: ./tint.md
