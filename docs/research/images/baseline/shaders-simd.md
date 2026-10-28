# Sparkles baseline: shaders, math and host SIMD

What `sparkles:shaders`, `sparkles:math` and the host-SIMD code in `sparkles:base` already give a pixel kernel that must run once on the CPU with runtime-dispatched vector instructions and once on the GPU as a compute shader, and what they do not: the graphics half is shipped and verified, the compute half is a plan, and the host-SIMD half is a pattern repeated by hand.

| Field          | Value                                                                                                                                                                                                                                                        |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Packages       | `sparkles:shaders` (`libs/shaders`, `libs/ui/shaders`, `apps/shader-compile`), `sparkles:math` (`libs/math`), `sparkles:base` (`hash/blake3*.d`, `text/simd_caps.d`, `text/grapheme.d`, `hw_caps.d`, `term_caps.d`), `sparkles:test-runner` (benchmark UDAs) |
| Specs read     | [`sparkles:shaders` specification][shaders-spec] (all topic pages, plan, decisions, testing ledger), [`sparkles:math` specification][math-spec]                                                                                                              |
| Status summary | Shipped: vertex and fragment stages, vocabulary, layout, one vector type, per-target SIMD for hashing and text. Specified, not started: compute, storage resources, workgroup memory, CPU executor. Not found: GPU timing, a shared SIMD capability API.     |
| Last reviewed  | October 27, 2026                                                                                                                                                                                                                                             |

> [!NOTE]
> This is a baseline, not a design. Statuses follow the repository on branch `feat/images`. A claim marked "not verified" was not established by reading a file in this session. Test names are cited from the [evidence ledger][testing] and the test files, and the tests themselves were not run for this document.

## What exists today

The four statuses are kept apart. Nothing in the SPECIFIED, DRAFT or PLANNED lists is code on this branch.

### Shipped (code on this branch)

**The graphics shader stack.** `sparkles:shaders` compiles D modules marked `@compute` to SPIR-V and GLSL through a forked LDC. It is a pure graphics pipeline today.

- **The library.** `libs/shaders/src/sparkles/shaders/` holds `attributes.d` (the `@compute`, `@fragment`, `@vertex`, `@input`, `@uniform`, `@builtin`, `@binding`, `@resources` markers, real `ldc.dcompute` symbols under `version (LDC_DCompute)` and inert stand-ins otherwise), `types.d` (the `float2`..`float4`, `int2`..`int4`, `mat*` aliases of `sparkles.math`), `math.d` (the GLSL built-ins `floor`, `mix`, `smoothstep`, `dot`, `luma`, ...), `fragment.d` (`dpdx`, `fwidth`, `discard`, `demote`), `layout.d` (`layoutOf`, `writeLayout`, `Rule.std140`, `Rule.std430`), `resources.d` (`UniformsOf`), `capabilities.d` (`Cap`, the profiles), `stages.d` (`stagesLink`) and `compute_mode.d` (`computeModeOf`, a lexical `@compute` detector).
- **The capability set is graphics-only.** `Cap` in `capabilities.d` lists `shader`, `vertexStage`, `fragmentStage`, `looseUniforms`, `uniformBlocks`, `pushConstants`, `sampledImages`, `intVertexInputs`, `int64`, `int16`, `int8`, `float64`, `bufferDeviceAddress`, `derivatives`, `derivativeControl` and `demote`. It has no compute stage, storage buffer, storage image, workgroup memory, barrier or atomic. The profiles of `SHC2` are `gl330`, `gles100`, `vulkan1.3`, `vulkan1.1` and `cpu`.
- **The build step.** `apps/shader-compile` runs one compilation per profile, validates the SPIR-V, translates GLSL with SPIRV-Cross and writes build products that are never committed. A package selects the device build with a `configuration "shaders"` whose `dflags` hold `-mdcompute-targets=vulkan-130`; `libs/shaders/dub.sdl` shows the pattern.
- **Consumers.** `libs/ui/shaders/effects.d` holds the built-in effects as `@fragment` entry points (scanlines, bloom passes, the CRT tube) wrapping `hostAndDevice` functions, so the terminal calls the same function per cell. `libs/ui-vulkan/shaders` and `libs/ui-vulkan/src/sparkles/ui_vulkan/shading.d` hold the Vulkan canvas stages (`canvasVertex`). The ledger records the Vulkan triangle of `sparkles:vulkan-wsi`.
- **Verified by tests, per the ledger.** Host and device agreement within the `D12` bounds is read back from a GL driver (`ui_raylib.shader_readback.hostAndDeviceAgree`) and from lavapipe, the Vulkan software rasteriser (`vulkan_wsi.triangle_readback.hostAndDeviceAgree`); `std140` and `std430` layouts are checked against hand-worked offsets and a block read back from lavapipe (`vulkan_wsi.triangle_readback.aStd140BlockReadsAsWritten`); samplers of their own are read back on lavapipe (`vulkan_wsi.triangle_readback.eachImageReadsThroughTheSamplerItNames`). The CI runner is x86_64 Linux; a real GPU is not verified.
- **The vector and matrix types.** `libs/math/src/sparkles/math/vector.d` has `Vector!(T, N, layout, names)` and `Layout.packed` / `Layout.device`; `matrix.d` has `Matrix!(T, R, C, order)`; `device.d` has the inert `compute`, `CompileFor` and `vectorType` stand-ins. `libs/math/src/sparkles/math/testing.d` carries the tests (the ledger names `Vector.layout`, `Vector.ctfe`, `Matrix.products` and others).

**Host SIMD with runtime dispatch, in `sparkles:base`.** This is the repository's real precedent for a kernel written once and instantiated per target.

- **BLAKE3 is the template.** `libs/base/src/sparkles/base/hash/blake3_simd.d` writes each kernel once over LLVM's generic vector type and instantiates it per target through `@target(tgt)` with `targetSse41 = "sse4.1"`, `targetAvx2 = "avx2"` and `targetAvx512 = "avx2,avx512f,avx512vl,evex512"`; the NEON backend is `targetNeon = "neon"`. `blake3.d` defines `Blake3Backend` (`automatic`, `portable`, `sse41`, `avx2`, `avx512`, `neon`), `bestBlake3Backend()` (always `portable` in CTFE, otherwise AVX-512 if `hasAvx512FVl && avx2`, then AVX2, then SSE4.1, NEON unconditionally on AArch64) and `isSupported(backend)`. `blake3_test.d` loops over every backend with `static foreach`, skips unsupported ones through `requireSupported` (which calls `skipTest`) and compares each against the portable backend on the official vectors and on random input.
- **Detection.** `libs/base/src/sparkles/base/text/simd_caps.d` probes AVX-512 with inline `cpuid` and `xgetbv` (so OS-enabled ZMM state counts, not only CPU bits) in a `shared static this()` into `package` immutables (`hasAvx512BwVl`, `hasAvx512Vbmi2`, `hasAvx512FVl`). `blake3.d` and `text/grapheme.d` call `core.cpuid` (`avx2`, `sse41`) for the lower tiers. The whole module is under `version (LDC)` and `version (X86_64)`; other builds get the portable path.
- **Other kernels.** `text/utf8_simd.d`, `text/utf16_simd.d` and `text/utf16_emit.d` use `ldc.simd` (`equalMask`, `greaterMask`, `shufflevector`, `storeUnaligned`) with `@target("sse2")` and `@target("avx512f,avx512bw,avx512vl,avx512vbmi2,evex512")`, and `utf16_emit.d` embeds LLVM IR for `llvm.x86.avx512.mask.compress`. `grapheme.d` selects `printableAsciiBlocks!32` (AVX2) or `!16` (SSE2) at run time. A grep of `libs` and `apps` for NEON or SVE found NEON only in the BLAKE3 backend and found no SVE; no SIMD code for images exists.
- **Not SIMD.** `libs/base/src/sparkles/base/hw_caps.d` answers worker counts, affinity, RAM and cgroup quotas (`hwParallelism`); it has no vector-ISA query. `term_caps.d` has `ImageProtocol` (`sixel`, `kitty`, ...) and a `ColorDepth` field (the enum lives in `term_color.d`), which describe a terminal sink, not a pixel format.

**Benchmark policy.** `sparkles:test-runner` provides the `@benchmark` and `@workload` UDAs (`libs/test-runner/src/sparkles/test_runner/attributes.d`); `libs/base/bench/utf` is a separate matrix against simdutf, simdutf8 and xutf. The build types are in [build settings][build-settings]: `checked` ships with "no native CPU requirement", while `bench`, `bench-unchecked` and `bench-static` add `-mcpu=native -O3` for LDC (visible in every `dub.sdl` managed block, for example `libs/shaders/dub.sdl`).

### Specified (accepted spec text, not yet delivered)

- **Compute and storage (M10).** [`PLAN.md`][plan] lists M10 as "not started": "Compute entry points beside dcompute's kernels; storage buffers, storage images, workgroup memory, barriers and atomics; module-scope constant tables." [`SHR1`'s page][resources] defers the same resources to "the milestones that bring them". There is no `SHC` capability and no requirement ID for any of them yet.
- **CPU executor (`SHX1`-`SHX3`).** [`executor.md`][executor] is an "outline" whose requirements are "coarse by design". The testing ledger marks `SHX1`-`SHX3` as `planned`. D22 chooses a scalar reference executor first and an SPMD-on-SIMD executor later (M16).
- **Vocabulary breadth (M9).** `uint`, `bool`, `half`, `double` and the remaining GLSL families are "not started". Today `SHV9` gives only `int2`..`int4`.
- **Further targets (M12).** GLSL ES 3.00, GLSL 4.60, HLSL, MSL and WGSL are "not started".

### Draft or unmerged

- **Upstream compiler support.** The Vulkan dcompute target is [ldc-developers/ldc#5132][pr5132], unmerged at the pin recorded by the [dcompute research page][dcompute-research]; the fragment and vertex stages and the SPIR-V backend patches live in a project fork and in patches tracked by issue 647 (`SHT1`). Compute kernels with a Vulkan target therefore depend on an unmerged upstream pull request plus project patches.
- **Dependency on a pinned toolchain.** The device path needs the toolchain of `SHT1`; it is available on "x86_64 Linux, aarch64 Linux and aarch64 macOS" (`SHT4`), and Windows is open question Q1 of the decisions page.

### Planned or not found

- **GPU compute dispatch on the host.** A grep of `libs` and `apps` for compute shader, `vkCmdDispatch` and storage buffer or image usage found only the buffer-device-address capability mapping in `capabilities.d` and a test string in `apps/shader-compile/src/app.d`. No host code in the repository dispatches a compute pipeline. `docs/research/shading-languages/dcompute.md` states that there is "no Vulkan host API anywhere" in dcompute itself.
- **Compute kernels in D.** `@kernel` appears in `libs/dmd-lsp/src/sparkles/dmd_lsp/dcompute.d` (editor analysis) and in research examples; no sparkles-owned `@kernel` function was found. Whether the fork compiles one end to end is not verified.
- **GPU timing.** A grep of `libs` for timestamp queries found no Vulkan timestamp use. There is no GPU benchmark harness; not verified beyond that grep.
- **A shared SIMD capability API.** None exists; see G5.
- **SVE, AVX10, RISC-V V, WebAssembly SIMD.** No code. `docs/research/simd-unicode/unicode-algorithms.md` records competitors that dispatch to NEON/SVE2 and Wasm SIMD128, which is research, not repository code.
- **Pixel and colour types in `sparkles:math`.** None; the library says it "does not cover transformations ... or numerically careful operations" (math introduction).
- **An mir-style N-D slice.** No `mir` dependency appears in any `dub.sdl` or `.d` file under `libs`; `Vector` is at most a small tuple, and no strided N-D view type was found in the packages read.

## Contracts that constrain image and video work

Quotes are copied from the cited line; where a sentence wraps across lines in the source, the line break is replaced by a space.

| ID                | Constraint                                                                                                                                                                                                                                                                             | Source                                                |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| Scope             | "The scope of this revision is the vertex and fragment stages, for Vulkan, OpenGL 3.3 and OpenGL ES 2.0, with uniforms, uniform blocks, push constants and sampled images."                                                                                                            | `docs/specs/shaders/SPEC.md`, section 1               |
| `SHF7`            | "The compiler supports the stages of `SHF1` and dcompute's kernels."                                                                                                                                                                                                                   | `docs/specs/shaders/entry-points.md:34`               |
| `SHM3`            | "no classes, interfaces, global variables, associative arrays, array literals, string literals, `new`, `delete`, concatenation, length assignment, run-time type information, inline assembly, exceptions, string `switch`, function pointers, delegates, `synchronized` or recursion" | `docs/specs/shaders/device-modules.md:32`             |
| `SHM4`            | "A `@compute` module **must not** contain unit tests. Tests of its functions live in a module without `@compute`."                                                                                                                                                                     | `docs/specs/shaders/device-modules.md:63`             |
| `SHM6`            | "D indexes with `size_t`, which is 64 bits on every host the build step runs on, so a plain `t[i]` widens its index to 64 bits and the module declares `Int64`."                                                                                                                       | `docs/specs/shaders/device-modules.md:58` (rationale) |
| `SHR4`            | "whose `std430` size, `layoutOf!(T, Rule.std430).size`, **must not** exceed 128 bytes, the minimum every Vulkan implementation offers"                                                                                                                                                 | `docs/specs/shaders/resources.md:102`                 |
| `SHR1` (deferral) | "Storage buffers, storage images, images other than 2-D ones, arrays of resources, bindless indexing, specialization constants and buffer device addresses are specified by the milestones that bring them"                                                                            | `docs/specs/shaders/resources.md:180`                 |
| `SHF4`            | "`sample(texture, uv)` on a `Sampler2D`, also callable as `texture.sample(uv)`, **must** return the `float4` that GLSL's `texture(sampler, uv)` returns for the same image, sampler state and coordinate."                                                                             | `docs/specs/shaders/entry-points.md`, `SHF4`          |
| `SHV2`            | "8 bytes for `float2`, 16 for `float3` and `float4`, under every compiler and on both sides"                                                                                                                                                                                           | `docs/specs/shaders/vocabulary.md:36`                 |
| `SHV7`            | "any operation may flush a denormal operand or result to zero."                                                                                                                                                                                                                        | `docs/specs/shaders/vocabulary.md:114`                |
| `SHV10`           | "so a matrix in a block has the bytes of a column-major matrix under `std140` and `std430`"                                                                                                                                                                                            | `docs/specs/shaders/vocabulary.md:61`                 |
| `SHX1`            | "which runs the invocations of a subgroup, a quad and a workgroup one at a time, in lock-step at every operation that exchanges values between invocations"                                                                                                                            | `docs/specs/shaders/executor.md:23`                   |
| `SHX1`            | "the SPMD executor **must** agree with the reference executor on every case of the conformance corpus."                                                                                                                                                                                | `docs/specs/shaders/executor.md:27`                   |
| `SHT4`            | "The device toolchain **must** be available on x86_64 Linux, aarch64 Linux and aarch64 macOS."                                                                                                                                                                                         | `docs/specs/shaders/toolchain.md:42`                  |
| `MV1`             | "a device-layout vector **must** have at most four components"                                                                                                                                                                                                                         | `docs/specs/math/SPEC.md:77`                          |
| `MV2`             | "Size and alignment **must** be the same under every compiler and in a host build and a device build."                                                                                                                                                                                 | `docs/specs/math/SPEC.md:85`                          |
| `MV3`             | "That field **must** be a native vector (`__vector(T[N])`) for a device vector of `float`, `int` or `uint`"                                                                                                                                                                            | `docs/specs/math/SPEC.md:94`                          |
| `MV3`             | "No other observable behaviour of this specification **may** depend on the storage."                                                                                                                                                                                                   | `docs/specs/math/SPEC.md:100`                         |
| `MD2`             | "DMD's optimiser hangs on and miscompiles some vector code (`-O` and `-inline`)"                                                                                                                                                                                                       | `docs/specs/math/SPEC.md:204`                         |
| Math scope        | "It promises no particular machine code: a native vector is an opportunity for the compiler, not a guarantee of SIMD instructions."                                                                                                                                                    | `docs/specs/math/SPEC.md`, introduction               |
| M10               | "Compute entry points beside dcompute's kernels; storage buffers, storage images, workgroup memory, barriers and atomics; module-scope constant tables."                                                                                                                               | `docs/specs/shaders/PLAN.md:468`                      |
| D22               | "later in an SPMD executor that runs invocations as SIMD lanes, checked against the reference (`SHX1`)."                                                                                                                                                                               | `docs/specs/shaders/decisions.md:476`                 |
| SIMD precedent    | "Runtime dispatch must include OS support, not only CPU capability bits."                                                                                                                                                                                                              | `docs/research/simd-unicode/index.md:39`              |
| Build policy      | "Shipping: optimized, inlined, debug information, assertions live; no native CPU requirement"                                                                                                                                                                                          | `docs/guidelines/build-settings.md:392`               |

Two further documented facts are binding in practice. The `D12` agreement table is "Vulkan table, at full single precision" with `floor`, `abs`, `min`, `max`, `clamp`, `step` and sampling exact, `sin` and `cos` within absolute 2⁻¹¹ for arguments in [−π, π], and division within 2.5 ULP (`docs/specs/shaders/decisions.md:237`). And the dcompute research page records that the device rules' "global-variable ban, which is what blocks workgroup memory and lookup tables" (`docs/research/shading-languages/dcompute.md:150`).

## Capability table

| Capability                                         | Where                                                                                                           | Status                                     | Evidence                                                                                                            |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| One source, host and device, for pure functions    | `hostAndDevice` modules; `libs/shaders/src/sparkles/shaders/math.d`, `libs/ui/src/sparkles/ui/effect_shaders.d` | Shipped                                    | `ui_raylib.shader_readback.hostAndDeviceAgree` (ledger `SHV7`); effects call the same function on the CPU           |
| Vertex and fragment entry points                   | `attributes.d`, the fork, `apps/shader-compile`                                                                 | Shipped                                    | ledger `SHF1`-`SHF3`, `SHF8`; `vulkan_wsi.triangle_readback.hostAndDeviceAgree` on lavapipe                         |
| Compute entry points, workgroup size, dispatch     | none                                                                                                            | Specified (M10), not started               | `PLAN.md` M10; `Cap` has no compute entry; no host dispatch code found                                              |
| Storage buffers and storage images                 | none                                                                                                            | Specified as deferred                      | `resources.md` "Not in this slice"; `Cap` has only `sampledImages`, `uniformBlocks`, `pushConstants`                |
| Workgroup shared memory, barriers, atomics         | none                                                                                                            | Specified (M10), not started               | `PLAN.md` M10; blocked today by the global-variable ban (`dcompute.md:150`)                                         |
| Push constants for kernel parameters               | `PushConstants!T`, `layoutOf`, `writeLayout`                                                                    | Shipped, 128-byte limit                    | `SHR4`; `vulkan_wsi.triangle_readback.hostAndDeviceAgree` (std430 push constant); `layout.layoutOf.std140AndStd430` |
| Uniform blocks and default uniform block           | `UniformBlock!T`, `UniformsOf!entry`                                                                            | Shipped                                    | `vulkan_wsi.triangle_readback.aStd140BlockReadsAsWritten`                                                           |
| Sampled 2-D images, samplers                       | `Sampler2D`, `SamplerState`                                                                                     | Shipped (filtered `sample` only)           | `eachImageReadsThroughTheSamplerItNames`; `SHF4`                                                                    |
| Integer texel load, 3-D / array / cube images      | none                                                                                                            | Not specified                              | `vocabulary.md` "texture operations beyond `sample`" are listed under "Not in this slice"                           |
| Device scalar types beyond `float` and `int`       | `Cap.int8`, `Cap.int16`, `Cap.float64` exist as capabilities only                                               | Specified (M9), not started                | `SHV9` gives `int2`..`int4` only; `PLAN.md` M9                                                                      |
| Vector types, device and packed layouts            | `libs/math/src/sparkles/math/vector.d`                                                                          | Shipped                                    | `Vector.layout`, `Vector.ctfe`, `Vector.arithmetic` (math ledger)                                                   |
| Native `__vector` storage                          | `Vector.storesNative`                                                                                           | Shipped, `float`, `int`, `uint` only       | `MV3`; every other `T` stores a static array                                                                        |
| Matrices up to 4x4, either order                   | `libs/math/src/sparkles/math/matrix.d`                                                                          | Shipped                                    | `Matrix.layout`, `Matrix.indexing`, `Matrix.products`                                                               |
| Colour spaces, pixel formats, N-D views            | none                                                                                                            | Not found                                  | no module in `libs/math` or `libs/shaders`                                                                          |
| Host/device agreement oracle for the vocabulary    | `ui_raylib.shader_readback`, `vulkan_wsi.triangle_readback`                                                     | Shipped, software rasterisers only         | ledger `SHV7`; CI x86_64 Linux; GPU hardware not verified                                                           |
| Reference or SPMD CPU executor                     | none                                                                                                            | Specified outline (M11, M16)               | `executor.md`; ledger `SHX1`-`SHX3` is `planned`                                                                    |
| Host SIMD, one kernel source, per-target `@target` | `libs/base/src/sparkles/base/hash/blake3_simd.d`                                                                | Shipped, one algorithm                     | `blake3_test.d` runs every backend against `portable`, skipping unsupported ones                                    |
| Runtime ISA detection                              | `text/simd_caps.d` (`cpuid`, `xgetbv`), `core.cpuid` in `blake3.d` and `grapheme.d`                             | Shipped, x86_64 only, `package` visibility | `bestBlake3Backend`; no NEON runtime probe (NEON is assumed on AArch64)                                             |
| NEON                                               | `blake3_simd.d` (`targetNeon`)                                                                                  | Shipped for BLAKE3 only                    | arm64 test runs: not verified in this session                                                                       |
| SVE, AVX10, RVV, Wasm SIMD                         | none                                                                                                            | Not found                                  | grep of `libs` and `apps`                                                                                           |
| Public SIMD capability query                       | none                                                                                                            | Not found                                  | `hw_caps.d` is worker counts; `simd_caps.d` fields are `package(sparkles.base)` or `package`                        |
| CPU benchmark harness                              | `@benchmark`, `@workload`, `bench*` build types, `libs/base/bench/utf`                                          | Shipped                                    | `attributes.d`; `build-settings.md`                                                                                 |
| GPU kernel timing, upload and readback timing      | none                                                                                                            | Not found                                  | grep of `libs` for timestamp queries                                                                                |
| Windows device toolchain                           | none                                                                                                            | Open question Q1                           | `decisions.md` open questions; `SHT4`                                                                               |

## Gaps and tensions

**G1. There is no compute pipeline, so "run the same pixel kernel on the GPU" has nothing to run on.** The accepted scope is vertex and fragment (`SPEC.md`), `Cap` has no compute-related entry, M10 is "not started", and no host code dispatches compute. A pixel filter can be written today only as a `@fragment` pass over a `Sampler2D` (the bloom blur in `libs/ui/shaders/effects.d` is the existing example), which writes a render target through the rasteriser instead of a storage image. Informs Q3, Q6, Q7.

**G2. The device rules forbid what pixel kernels routinely use.** `SHM3` bans global variables, array literals, string literals, function pointers, delegates and recursion. That excludes workgroup memory and module-scope lookup tables (gamma, quantisation, Huffman, DCT constants) until M10 adds "module-scope constant tables", rules out per-format dispatch through function pointers inside a kernel, and means the pixel format has to be a compile-time template parameter. `SHM4` forces tests into a separate host module, so a kernel's conformance test is never next to its source. Informs Q2, Q3, Q8.

**G3. The vocabulary has no byte, half or unsigned pixel types.** `SHV9` gives `int` vectors only and `Cap.int8` / `Cap.int16` are bare capabilities with no vocabulary behind them. `Vector!(ubyte, 4)` exists (`isNumeric!T`) but is a packed static array, and native `__vector` storage is limited to `float`, `int`, `uint` device vectors (`MV3`), so 8-bit and 16-bit pixel arithmetic gets no SIMD storage from `sparkles:math`. Packed formats (RGB565, 10-10-10-2, YUV subsampling) need `uint` bit operations the vocabulary lacks. Informs Q1, Q5.

**G4. "Write once, run on SIMD" has no mechanism beyond hand-written per-target kernels.** The SPMD executor is a plan (`SHX1`, M16), and `MV3` explicitly "promises no particular machine code". What exists is the BLAKE3 pattern: a generic-vector kernel template instantiated under `@target`. It works for a fixed-lane, hand-structured kernel; it does not take a shader entry point as input. A shader-shaped kernel and a host-SIMD kernel therefore remain two sources that agree only if a test says so. Informs Q2, Q3, Q7.

**G5. Host SIMD dispatch is repeated by hand, with visibility that stops at `sparkles:base`.** Capability bits live in `package` and `package(sparkles.base)` immutables of `simd_caps.d`; `blake3.d` and `grapheme.d` each call `core.cpuid` themselves; NEON is assumed on AArch64 rather than probed; there is no SVE, no cache of "which backend was chosen" exposed to a caller, and no shared enum of backends. An image package that needs AVX2 or NEON bulk loops would either copy this or force a new public API in `base`, which is the situation the standing rule against package-local copies of shared infrastructure targets. Informs Q3, Q9.

**G6. Portability of the dispatch code to the other build modes is only partly stated.** All x86 paths are under `version (LDC)` and `version (X86_64)`, so DMD, wasm and betterC builds take the portable path, which is the safe default; but the BLAKE3 NEON path is selected without a runtime check, and the dispatch relies on `shared static this()` constructors. Whether those run in a `--better-c` extraction, a wasm build or the Android APK was not verified. Informs Q3, Q4.

**G7. The benchmark policy cannot answer the SIMD-versus-GPU question.** `@benchmark` and `@workload` time CPU code. The benchmark build types add `-mcpu=native` for LDC, so a `bench` run lets LLVM use the build machine's widest ISA everywhere and does not exercise the `@target` dispatch that the `checked` shipping build (no native CPU requirement) will actually run. No GPU timestamp, upload or readback timing exists. The break-even between host SIMD and a compute dispatch (transfer, launch latency, pipeline creation, SPIR-V build step) cannot be measured with what is in the repository. Informs Q7, Q8.

**G8. The agreement oracle is calibrated for float shading, not for exact image kernels.** `SHV7` and `D12` allow ULP-scale differences, fused multiply-add on either side and flushed denormals, and the evidence runs on software rasterisers. An 8-bit conformance corpus (decoded image against a reference) needs either exactness, which float kernels on the GPU do not promise, or a stated tolerance per kernel. The readback harnesses live in the consumers (`ui_raylib.shader_readback`, `vulkan_wsi.triangle_readback`) and `shaders.testing` holds only vocabulary tests, so an image package would build a third harness or force the first two into a shared library. Informs Q8, Q9.

**G9. Resource binding is graphics-shaped.** One descriptor set, a reserved shared sampler at binding 0, `@binding(b)` fixed per parameter, 128-byte push constants and `std140`/`std430` only (scalar layout "comes with the first profile that grants it"). Images are 2-D and sampled with filtering; there is no integer `texelFetch`, no storage image, no array of images. Planar YUV, 16-bit integer planes, tiled or compressed texture formats, and large kernel tables cannot be expressed. Informs Q1, Q6.

**G10. The vector types do not cover pixels, planes or N-D views.** `Vector` is a tuple (device layout at most four components); `Matrix` is at most 4x4; there is no strided slice, plane, stride-in-bytes or sub-image type, and no `mir` dependency was found. Whether `Vector` can be the element type of a larger view, and whether an external N-D slice type fits, is untested. Informs Q1.

**G11. The GPU half rests on an unmerged compiler and a short list of platforms.** The Vulkan dcompute target is an open upstream pull request, the stages are in a fork, and the LLVM backend carries project patches; the toolchain exists for three platforms, not Windows. An image or video library that needs GPU kernels in its default build would violate the repository rule that "No compiler unless asked": the generated shader must come as a prebuilt Nix product (`SHB3`), and a consumer on an unsupported platform needs a host-only fallback that is always correct. Informs Q9, Q6.

**G12. Standing rules meet the device subset.** Writers over strings and `Expected` for errors have no device equivalent: device code has no exceptions, no string literals and no assertions the `math` library can rely on (`vector.d` notes "No contract: device code has no assertions"), so hostile-input checks must be host-side and a kernel must be total on its inputs. dip1000 and `@safe pure nothrow @nogc` already apply to the shared `hostAndDevice` modules; whether a kernel over slices can keep `scope` and `@safe` is not verified. Informs Q4, Q8.

## Questions for the design grill

These are the open decisions this area forces. None is decided here.

**1. How does a pixel kernel become both host-SIMD and GPU code?** (Q2, Q3, Q7)

- A. One scalar per-pixel function in a `hostAndDevice` module (the effects pattern), called per element on the host, with the host loop vectorised by LLVM or hand-written `@target` wrappers, and the GPU entry point generated around it.
- B. A generic-vector kernel template per algorithm, as in `blake3_simd.d`, with the GPU kernel written separately and the two checked against each other.
- C. Wait for the SPMD executor (M16) and make the shader entry point the single source for both.

Recommendation: A for kernels that are per-pixel pure functions, B where the algorithm needs shuffles, horizontal reductions or table lookups, and keep C as a later replacement. A is the only option with evidence in the repository today (`SHV7` readbacks), and it forces no new compiler work.

**2. Is GPU compute in the first image release?** (Q3, Q6, Q7)

- A. Not in the first release: fragment passes at most, compute after M10 lands.
- B. Pull M10 forward, with storage images, push-constant parameters and a minimal workgroup model, to deliver one reference compute kernel.
- C. Host-only first with the kernel source shaped so it can move to the device later.

Recommendation: C, then B. The plan has M10 as a prerequisite for M11 and nothing else in the image work depends on it, and the break-even question (G7) cannot be answered without a measurement harness.

**3. Where does host ISA detection live and who may call it?** (Q3, Q9)

- A. A public module in `sparkles:base` that exposes the detected tiers and the OS-state checks of `simd_caps.d`, used by hashing, text and images.
- B. Each package keeps its own call to `core.cpuid`.
- C. Compile-time selection through `-mcpu` per build, no runtime dispatch.

Recommendation: A. B is the current drift; C contradicts the shipping policy that `checked` has no native CPU requirement.

**4. How is the pixel element typed on the device?** (Q1, Q5)

- A. Float-only on the device: decode to `float4` on load (a texture format conversion), compute in float, quantise on store.
- B. Extend the vocabulary (M9) with `uint`, `half` and byte vectors and expose raw formats to kernels.
- C. Host-only integer paths, device float paths, with a stated tolerance between them.

Recommendation: A for the GPU path with C's tolerance written down, B only if a codec stage (for example an integer transform) must run on the GPU.

**5. What is the conformance oracle for kernels?** (Q8)

- A. Bit-exact host reference (portable backend) against each SIMD backend, as `blake3_test.d` does; GPU output within a per-kernel tolerance.
- B. Everything within the `D12` ULP bounds.
- C. Exact everywhere, restricting GPU kernels to operations the Vulkan table lists as exact.

Recommendation: A, with the GPU tolerance chosen per kernel and recorded next to it. B is too loose for 8-bit output and C excludes `mix`, `smoothstep` and `dot`.

**6. Where does the shared readback harness live?** (Q8, Q9)

- A. Extract the lavapipe readback from `vulkan_wsi.triangle_readback` and `ui_raylib.shader_readback` into a shared test library that image tests use.
- B. Image tests carry their own.
- C. Image GPU kernels are verified only through the host path.

Recommendation: A, in line with the rule against package-local copies of shared infrastructure; B would be the third harness.

**7. Which benchmark build measures the dispatch itself?** (Q3, Q7)

- A. Add a bench build type without `-mcpu=native` so `@target` dispatch is what is timed.
- B. Keep `-mcpu=native` and time each backend explicitly through its enum, as `Blake3Backend` allows.
- C. Both, reporting native as an upper bound.

Recommendation: B for kernels with a backend enum, plus a GPU timestamp harness (a gap, G7) before any break-even claim.

**8. Does `Vector` underlie pixels, or do pixels get their own element type?** (Q1, Q5)

- A. `Vector!(ubyte, 4)` and `Vector!(float, 4, Layout.device)` are the pixel types, with colour metadata outside the type.
- B. A separate `Pixel!(Format, ...)` type that converts to and from `Vector`.
- C. Views over raw bytes with a format tag, converting at the kernel edge.

Recommendation: B or C. `MV3` limits native storage to `float`, `int` and `uint` and `MV1` limits device vectors to four components, so `Vector` fits shader values but not storage formats; the choice also decides how an external slice type could fit (G10).

## Sources

Specification and plan: [`SPEC.md`][shaders-spec], [`PLAN.md`][plan], [`entry-points.md`][entry-points], [`resources.md`][resources], [`executor.md`][executor], [`device-modules.md`][device-modules], [`vocabulary.md`][vocabulary], [`profiles.md`][profiles], [`toolchain.md`][toolchain], [`decisions.md`][decisions], [`testing.md`][testing] (evidence ledger), [`sparkles:math` specification][math-spec].

Research and guidelines: [shading languages: dcompute][dcompute-research], [shading languages: comparison][shading-comparison], [SIMD UTF and Unicode][simd-unicode], [build settings][build-settings], [benchmarking and profiling][benchmarking].

Code read (paths relative to the repository root, backticked because they sit outside the documentation tree): `libs/shaders/dub.sdl`; `libs/shaders/src/sparkles/shaders/{attributes,capabilities,compute_mode,fragment,layout,math,resources,stages,testing,types}.d`; `libs/ui/shaders/effects.d`; `libs/math/src/sparkles/math/{vector,matrix,device,testing}.d`; `libs/base/src/sparkles/base/hash/{blake3,blake3_simd,blake3_test}.d`; `libs/base/src/sparkles/base/text/{simd_caps,grapheme,utf8_simd,utf16_simd,utf16_emit}.d`; `libs/base/src/sparkles/base/{hw_caps,term_caps}.d`; `libs/test-runner/src/sparkles/test_runner/attributes.d`; `apps/shader-compile/src/app.d`.

<!-- References -->

[shaders-spec]: ../../../specs/shaders/SPEC.md
[plan]: ../../../specs/shaders/PLAN.md
[entry-points]: ../../../specs/shaders/entry-points.md
[resources]: ../../../specs/shaders/resources.md
[executor]: ../../../specs/shaders/executor.md
[device-modules]: ../../../specs/shaders/device-modules.md
[vocabulary]: ../../../specs/shaders/vocabulary.md
[profiles]: ../../../specs/shaders/profiles.md
[toolchain]: ../../../specs/shaders/toolchain.md
[decisions]: ../../../specs/shaders/decisions.md
[testing]: ../../../specs/shaders/testing.md
[math-spec]: ../../../specs/math/SPEC.md
[dcompute-research]: ../../shading-languages/dcompute.md
[shading-comparison]: ../../shading-languages/comparison.md
[simd-unicode]: ../../simd-unicode/index.md
[build-settings]: ../../../guidelines/build-settings.md
[benchmarking]: ../../../guidelines/benchmarking-and-profiling.md
[pr5132]: https://github.com/ldc-developers/ldc/pull/5132
