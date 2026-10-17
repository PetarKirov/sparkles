# CUDA and HIP (C++ / NVIDIA and AMD)

The single-source GPU compute model that the rest of the field copies: ordinary C++ functions tagged with an execution space (`__host__`, `__device__`, `__global__`), compiled once per side from one translation unit, with HIP as AMD's near-identical, MIT-licensed re-implementation on Clang.

| Field             | Value                                                                                                                                                                 |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | CUDA C++ / HIP C++ (C++17–C++20 dialects with execution-space and memory-space specifiers)                                                                            |
| License           | CUDA Toolkit: NVIDIA proprietary EULA. HIP: MIT ([`LICENSE.md`][hip-license]). Clang's CUDA/HIP front end: Apache-2.0 with LLVM exception                             |
| Repository        | CUDA: closed. [ROCm/HIP][hip-repo] (pinned `e00661614d20`), Clang in [llvm/llvm-project][compile-cuda] (pinned `27ba49378121`), [ROCm/HIP-CPU][hipcpu-readme]         |
| Documentation     | [CUDA Programming Guide][cuda-pg] · [Compiling CUDA with clang][compile-cuda] · [Clang HIP Support][clang-hip] · [HIP C++ language extensions][hip-ext]               |
| Category          | Single-source peer: compute-only, SIMT kernel language                                                                                                                |
| Latest version    | CUDA Programming Guide v13.4.2, last updated 2026-09-10 ([guide index][cuda-pg]). HIP `VERSION` file at the pin reads `7.13.0` ([`VERSION`][hip-version], 2026-10-05) |
| Targets           | nvcc / Clang → PTX → SASS (NVIDIA). hipcc / Clang → AMDGCN code objects, or `spirv64-amd-amdhsa` SPIR-V (`--offload-arch=amdgcnspirv`); chipStar → SPIR-V (Intel)     |
| Graphics stages   | None. Compute kernels only; graphics reaches CUDA through interop (`cudaGraphicsResource`), not through the language                                                  |
| CPU execution     | No official one since CUDA 3.1 removed device emulation. HIP-CPU (header-only, fibers) runs unmodified HIP on CPUs                                                    |
| Relation to D/LDC | LDC's `ldc.dcompute` already maps `@kernel` to `__global__` and has `CompileFor.hostAndDevice` ([`dcompute.d`][ldc-dcompute])                                         |

---

## Overview

### What it solves

A shading language keeps device code in a separate language and a separate file, joined to the host by strings and reflection. CUDA instead makes the device a second compilation target of the same C++ program: a `.cu` file contains host code, device code, and code meant for both, and the toolchain splits, compiles and re-links them into one executable that carries a fat binary of device images. Kernels are launched with an ordinary-looking call plus an execution configuration (`kernel<<<grid, block, shmem, stream>>>(args)`), and data structures, templates, lambdas and math helpers are shared between the two sides.

HIP exists to make that model portable. Its documentation describes it as _"a C++ runtime API and kernel language for AMD GPUs … using CPUs and AMD GPUs from a single source code base"_ ([`docs/what_is_hip.rst`][hip-what]); on NVIDIA it is a header layer over the CUDA runtime, compiled by `nvcc`. Both languages share Clang's front end, so CUDA and HIP have one semantic model for host/device targets in open source ([Clang HIP Support][clang-hip]: _"Clang's front end, used for both CUDA and HIP programming models, shares the same parsing and semantic analysis mechanisms"_).

### Design philosophy

The CUDA programming guide states the contract a single-source design must honour: one function, compiled per context, with a macro to tell the passes apart.

> _"Functions declared with multiple execution spaces (for example, `__host__ __device__`) are compiled for each context. The `__CUDA_ARCH__` macro can be used to differentiate the host and device code paths."_ ([CUDA Programming Guide § 5.4.1, C/C++ Language Extensions][cuda-ext])

The guide also states the SIMT model as a programming model rather than a hardware description, which is what makes CPU emulation legitimate:

> _"In the SIMT model, all threads in a warp progress through the kernel in lock step. Hardware execution may differ. … Exploiting knowledge of how warp execution is actually mapped to real hardware is discouraged."_ ([§ 1.2, Programming Model][cuda-model])

Clang's own docs record the cost of doing this as a C++ dialect with no specification: _"There is no formal CUDA spec, and clang and nvcc speak slightly different dialects of the language."_ ([`CompileCudaWithLLVM.md`][compile-cuda])

## How it works

### Execution spaces are attributes on functions

Clang models each specifier as an attribute in [`Attr.td`][attr-td] — `CUDAHost`, `CUDADevice`, `CUDAGlobal`, plus `CUDAShared`, `CUDAConstant`, `HIPManaged`, `CUDALaunchBounds`, `CUDAGridConstant`, `CUDAClusterDims` — and `SemaCUDA::IdentifyTarget` reduces a declaration to one `CUDAFunctionTarget` ([`SemaCUDA.cpp`][sema-cuda]):

```cpp
// clang/lib/Sema/SemaCUDA.cpp — IdentifyTarget (abridged)
if (D->hasAttr<CUDAGlobalAttr>())        return CUDAFunctionTarget::Global;
if (D->isConsteval())                    return CUDAFunctionTarget::HostDevice;
if (hasAttr<CUDADeviceAttr>(D, ...)) {
  if (hasAttr<CUDAHostAttr>(D, ...))     return CUDAFunctionTarget::HostDevice;
  return CUDAFunctionTarget::Device;
} else if (hasAttr<CUDAHostAttr>(D, ...)) return CUDAFunctionTarget::Host;
else if (D->isImplicit() || !D->isUserProvided())
  return CUDAFunctionTarget::HostDevice;  // "the most lenient target"
return CUDAFunctionTarget::Host;          // unannotated = host
```

Three defaults matter for a D design. An unannotated function is host-only. `consteval` functions are both. And `LangOptions.def` turns on `CUDAHostDeviceConstexpr` by default — _"treating unattributed constexpr functions as `__host__` `__device__`"_ ([`LangOptions.def`][langopts]) — which is how `std::min`/`std::max` became usable on the device. A newer `OffloadImplicitHostDeviceTemplates` option extends the same treatment to all function templates.

### Overload resolution by side

In Clang (not nvcc) the execution space is part of the signature, so `__host__ void f()` and `__device__ void f()` may coexist. Resolution ranks candidates with `CUDAFunctionPreference` ([`SemaCUDA.h`][sema-cuda-h]), _"ordered numerically from worst to best"_:

| Preference       | Meaning                                                         |
| ---------------- | --------------------------------------------------------------- |
| `CFP_Never`      | invalid caller/callee pair (H→D, D→H, G→H)                      |
| `CFP_WrongSide`  | HD caller calling a function of the side not being compiled now |
| `CFP_HostDevice` | any call to an HD function                                      |
| `CFP_SameSide`   | HD caller calling the side being compiled now                   |
| `CFP_Native`     | H→H, D→D, H→G, G→D, and D/G→G (dynamic parallelism)             |

`IdentifyPreference` implements the table. The interesting case is (d): from an HD function, a call into the non-current side is _"allowed at the sema level, but eventually rejected if they're ever codegened"_ ([`SemaCUDA.cpp`][sema-cuda]) — the **wrong-side rule**.

### Deferred diagnostics

Because a header full of HD helpers would otherwise fail on whichever side it does not support, Clang records such errors and emits them only when a function whose linkage guarantees emission (a kernel, an externally visible H or D function) reaches the offending HD function. The Clang docs call these **HD-promoted functions** — lambdas without attributes, `inline __host__ __device__` helpers, and HD template instantiations — and print one error with a call-chain note per reaching caller ([Clang HIP Support § Deferred Diagnostics][clang-hip]):

```text
error: reference to __host__ function 'host_only' in __host__ __device__ function
  note: 'host_only' declared here
  note: called by 'df1'
  note: called by 'df2'
```

nvcc behaves differently: it only warns on a non-inline HD function that calls a host function, and _"may omit `not_inline_hd`'s call to `host_only` entirely"_ ([`CompileCudaWithLLVM.md`][compile-cuda]).

### Split compilation versus merged parsing

nvcc preprocesses a `.cu` file into separate host and device sources, compiles device code per virtual architecture to PTX (and optionally SASS), packs a fat binary, and hands the host half to `gcc`/`clang`/MSVC ([NVCC § 2.7][cuda-nvcc]). Clang uses **merged parsing**: the whole TU is parsed once per device architecture and once for the host, and _"all of the host and device code is present and must be semantically-correct in both compilation steps"_ ([`CompileCudaWithLLVM.md`][compile-cuda]). Clang explains why it does not reuse one AST: _"we have to define different macros during host compilation and during device compilation for each GPU architecture."_

### Kernels and launch

A `__global__` function returns `void`, may not be a class member, does not support recursion, and is launched asynchronously ([CUDA § 5.4.1][cuda-ext]). HIP adds kernel-parameter restrictions that are really ABI rules: no references, no `va_list`, and no _"struct-type arguments which have different layouts in host and device code"_ ([`hip_cpp_language_extensions.rst`][hip-ext]). On the host side Clang's `CGNVCUDARuntime::emitDeviceStub` replaces the kernel's body with a stub that packs arguments into an array and calls `cudaLaunchKernel`/`hipLaunchKernel` ([`CGCUDANV.cpp`][cgcudanv]); a module constructor registers the fat binary with `__hipRegisterFatBinary` before `main` ([Clang HIP Support § Fat Binary Registration][clang-hip]).

```cpp
__global__ void saxpy(float a, const float* x, float* y, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) y[i] = a * x[i] + y[i];
}
// host
saxpy<<<(n + 255) / 256, 256>>>(2.0f, dx, dy, n);           // CUDA / HIP
hipLaunchKernelGGL(saxpy, dim3(blocks), dim3(256), 0, 0, 2.0f, dx, dy, n); // HIP macro form
```

Built-in coordinates (`threadIdx`, `blockIdx`, `blockDim`, `gridDim`) are not variables in Clang: [`__clang_cuda_builtin_vars.h`][builtin-vars] declares them as structs whose fields are `__declspec(property)` getters that call `__nvvm_read_ptx_sreg_tid_x()` and friends, with constructors, copy and `operator&` deleted so they behave like nvcc's non-addressable specials.

### The newest wrinkle: tile kernels

CUDA 13 adds a second, block-granular kernel language beside SIMT: `__tile_global__` and `__tile__` functions that operate on compile-time-shaped tiles and _"execute once per block"_. The guide notes that _"`__tile__` functions cannot be called from `__global__` or `__device__` functions"_ yet, and that for tile kernels _"the considerations for branch divergence within a warp do not apply"_ ([§ 2.4, Writing Tile Kernels][cuda-tile]). It is a fourth execution space, which shows the attribute set is open-ended.

## Execution model and stages

There is one stage: the compute kernel. The hierarchy is grid → (cluster) → block → warp → thread. Blocks share `__shared__` memory and `__syncthreads()`; warps are 32 threads on NVIDIA; on AMD the wavefront is _"64 for gfx9 and 32 for gfx10 and above"_ and _"`warpSize` should not be assumed to be a specific value in portable HIP applications"_ ([`hip_cpp_language_extensions.rst`][hip-ext]). Since ROCm 7.0, `warpSize` is _"early folded by the compiler"_ instead of being a true compile-time constant.

**Independent thread scheduling** changed the semantics under every warp-level idiom. The guide: _"In GPUs of compute capability 7.0 and later, independent thread scheduling allows full concurrency between threads, regardless of warp. … threads can now diverge and reconverge at sub-warp granularity"_, and _"Any warp-synchronous code developed for GPUs prior to CC 7.0 … should be revisited"_ ([§ 3.2.2.1.1][cuda-adv]). HIP takes the opposite hardware position — _"AMD GPUs guarantee, that all warp lanes are executed in lockstep, whereas NVIDIA GPUs that support Independent Thread Scheduling might require additional synchronization"_ ([`hip_cpp_language_extensions.rst`][hip-ext]) — but the portable language contract is the weaker one.

Forward progress is specified as a delta on ISO C++ `[intro.progress]`: device threads get **parallel** forward progress, and once a thread has made progress, _"all device threads in its thread-block cluster shall eventually make progress"_, or its whole grid for a cooperative launch ([§ 5.8, Execution model][cuda-exec]). A spin-wait between blocks of a normal launch is therefore not guaranteed to terminate.

Graphics stages (vertex, fragment, mesh, ray tracing) do not exist in the language. Ray tracing reaches CUDA only through the separate OptiX SDK, _"which uses CUDA as its shader language"_ ([§ 2.3, Writing SIMT Kernels][cuda-simt]); this deep-dive does not cover OptiX.

## Type system and generic programming

The type system is C++: templates, lambdas, classes, `constexpr`, and the standard vector types (`float4`, `int2`, `dim3`) from `vector_types.h`, which are plain structs rather than first-class SIMD types — there is no swizzle syntax and no built-in matrix type (Tensor Core fragments are opaque `wmma::fragment` templates). The dialect restrictions are the interesting part:

- **RTTI and exceptions** are not supported in device code; `__global__`/`__tile__` functions cannot recurse, `__device__` functions can ([§ 5.3, C++ Language Support][cuda-cpp]).
- **Virtual functions** work only on the side that constructed the object: _"An object constructed on the device side contains a pointer to the virtual function table on the device side, which is not accessible in host code, and vice versa"_ ([Clang HIP Support § Virtual Function Support][clang-hip]).
- **Layout must not depend on the side.** _"The type signatures of the following entities shall not depend on whether `__CUDA_ARCH__` is defined, nor on its value"_, and `__global__` template instantiations must be identical across host and every device program ([§ 5.4.7.1][cuda-ext]). Clang's docs give the reason: a class with different members per side _"would have a different layout on H and D, so would not work properly"_ as a kernel argument ([`CompileCudaWithLLVM.md`][compile-cuda]).
- **Lambdas** are implicitly HD-promoted in Clang; nvcc needs `--extended-lambda` for `__device__` lambdas passed from host code.

Pointer width is shared: _"In CUDA, the device code and host code always have the same pointer widths"_ ([`CompileCudaWithLLVM.md`][compile-cuda]). That single rule is what lets the same `struct` cross the launch boundary without marshalling.

## Resources, interfaces and memory layout

CUDA has **no resource binding model**. Kernel parameters are a packed argument block (`__grid_constant__` lets a `const` parameter be addressed in place on sm_70+ — [`AttrDocs.td`][attr-docs]); everything else is a raw pointer. Memory spaces are specifiers on variables ([§ 5.4.1.2, Memory Space Specifiers][cuda-ext]):

| Specifier      | Location                 | Visibility                    | SPIR-V analogue                     |
| -------------- | ------------------------ | ----------------------------- | ----------------------------------- |
| `__device__`   | device global memory     | all device threads, runtime   | `StorageBuffer` / `CrossWorkgroup`  |
| `__constant__` | constant memory (cached) | all device threads, read-only | `Uniform` (UBO) / `UniformConstant` |
| `__shared__`   | on-chip, per block       | threads of one block          | `Workgroup`                         |
| `__managed__`  | unified memory           | host and device               | none (BDA + host mapping)           |
| automatic      | registers / local stack  | one thread                    | `Function` / `Private`              |

Pointers are **generic**: a `float*` can point into any space, and the backend recovers the space where it can. Clang's docs list this as an LLVM optimisation — _"pointers in CUDA are not explicitly annotated with their address space, so it's up to LLVM to infer it where possible"_ — via `InferAddressSpaces` ([`CompileCudaWithLLVM.md`][compile-cuda]). Runtime predicates (`__isGlobal`, `__isShared`, …) exist for the cases inference misses ([§ 5.4.8.1][cuda-ext]).

Host/device memory is one virtual address space: _"A single virtual address space is used for all host memory and all global memory on all GPUs in the system within a single OS process"_ ([§ 2.6.1, Unified Virtual Address Space][cuda-mem]). Full unified memory (`cudaMallocManaged`, or all system memory on Grace Hopper and Linux HMM systems) adds page migration on top ([§ 4.1, Unified Memory][cuda-um]). Clang lowers device accesses to a `__managed__` variable to _"loads from a pointer to a chunk of managed memory allocated by the HIP runtime"_ ([Clang HIP Support § Managed Variables][clang-hip]).

Textures and surfaces are opaque 64-bit object handles (`cudaTextureObject_t`), created on the host and passed as ordinary kernel arguments — bindless by construction, with no descriptor sets or root signatures.

## Built-in library and intrinsics

- **Math:** `<cmath>` and `<math.h>` work in Clang device code, including the integer overloads nvcc lacks ([`CompileCudaWithLLVM.md`][compile-cuda]). Fast paths are flags: `-fcuda-approx-transcendentals` emits `sin.approx.f32`; `-ffp-contract` defaults to `fast` on both sides.
- **Warp functions:** `__activemask`, vote (`__all_sync`, `__any_sync`, `__ballot_sync`, `__uni_sync`), shuffle (`__shfl_sync`, `__shfl_up_sync`, `__shfl_down_sync`, `__shfl_xor_sync`), match (`__match_any_sync`, `__match_all_sync`), reduce (`__reduce_add_sync`, …) and `__syncwarp` ([§ 5.4.6, Warp Functions][cuda-ext]). In Clang they are thin wrappers over NVVM builtins, e.g. `__ballot_sync` → `__nvvm_vote_ballot_sync` ([`__clang_cuda_intrinsics.h`][cuda-intrin]).
- **Atomics and fences:** classic `atomicAdd`/`atomicCAS`, scoped `__nv_atomic_*` builtins, and libcu++ `cuda::atomic_ref` with explicit `cuda::thread_scope_{thread,block,device,system}` ([§ 5.7, Memory Model][cuda-memmodel]).
- **Cooperative groups:** a library of group handles — `thread_block`, `thread_block_tile`, `coalesced_group`, `grid_group` — with `sync()`, `tiled_partition`, and collectives (`reduce`, scans, `invoke_one`). The guide motivates it by the warp-level hacks it replaces: _"an ever-growing collection of brittle code that is expensive to write, tune, and maintain over time and across GPU generations"_ ([§ 4.4, Cooperative Groups][cuda-cg]). Grid-wide `sync()` requires `cudaLaunchCooperativeKernel`, which guarantees every block is co-resident. HIP mirrors the API in [`hip_cooperative_groups.h`][hip-cg-h] but has no explicit warp group and deprecates multi-grid groups since ROCm 5.0 ([`cooperative_groups.rst`][hip-cg]).
- **Missing compared with shading languages:** samplers with implicit derivatives, quad operations, `discard`, interpolation, and every graphics built-in.

## Control flow, memory model and restrictions

Control flow is unrestricted C++ minus exceptions: `goto`, `break` out of nested loops, irreducible CFGs, recursion in `__device__` functions, function pointers within a device image. Divergence is the hardware's problem: _"the threads which do not follow the branch will be masked off while the threads which follow the branch are executed"_ ([§ 1.2][cuda-model]).

The `_sync` warp intrinsics are where the language makes convergence explicit. Every call names its participants with a mask, and the rules read like a convergence-control specification ([§ 5.4.6.6][cuda-ext]):

> _"The intrinsic waits until all non-exited warp threads specified in the mask reach the call. … All non-exited threads specified in the mask must execute the intrinsic with the same mask value. Warp threads may call the intrinsic concurrently with different mask values, provided the masks are disjoint. Such condition is valid even in divergent control flow."_

`__activemask()` is explicitly not a convergence oracle: threads convergent at the call _"are not guaranteed to remain convergent at subsequent instructions unless those instructions are warp synchronizing intrinsics"_ ([§ 5.4.6.1][cuda-ext]). HIP keeps the same rules but widens every mask to 64 bits: _"All mask values returned or accepted by these built-ins are 64-bit unsigned integer values, even when compiled for a device with 32 threads per warp"_, with a static assert to catch ported CUDA code ([`hip_cpp_language_extensions.rst`][hip-ext]).

At the LLVM level the same problem is the `convergent` attribute and convergence-control tokens: a convergent operation is _"inter-thread communication or synchronization that occurs outside of the memory model, where the set of threads which participate in communication is implicitly affected by control flow"_ ([`ConvergentOperations.rst`][llvm-convergent]). CUDA's masks move that set from implicit to explicit; SPIR-V's `OpGroupNonUniform*` keep it implicit (the active invocations in the subgroup).

The memory model is the C++ model with **thread scopes** added (`cuda::thread_scope_*`) and HIP's equivalents as `__HIP_MEMORY_SCOPE_{SINGLETHREAD,WAVEFRONT,WORKGROUP,CLUSTER,AGENT,SYSTEM}` macros ([Clang HIP Support § Predefined Macros][clang-hip]) — the same scope ladder as Vulkan's `Subgroup`/`Workgroup`/`QueueFamily`/`Device` scopes.

## Compilation pipeline and targets

```text
              ┌─ device pass, per --offload-arch ─ Clang → LLVM IR ─┬─ NVPTX → PTX → ptxas → SASS ─┐
x.cu / x.hip ─┤                                                      ├─ AMDGPU → code object ───────┼─ fat binary
              │                                                      └─ SPIR-V backend → .spv ──────┘     │
              └─ host pass ─ Clang → host object (kernel stubs + registration ctor) ◀─ embedded ──────────┘
```

- **NVIDIA:** Clang parses the TU once per `sm_XX`, emits PTX through the NVPTX backend, always runs `ptxas` to SASS, and embeds PTX only with `--cuda-include-ptx` ([`CompileCudaWithLLVM.md`][compile-cuda]). Clang added CUDA in LLVM 3.9; Google's gpucc paper (CGO 2016) introduced it, and its GPU-specific passes — straight-line scalar optimisation, speculative execution, address-space inference, 64-bit division bypass, aggressive unrolling and inlining — are now in stock LLVM.
- **AMD:** the HIPAMD toolchain emits AMDGCN code objects per `gfx` target. With `--offload-arch=amdgcnspirv` it instead targets `spirv64-amd-amdhsa` and emits _"generic AMDGCN SPIR-V which retains architecture specific elements without hardcoding them"_, finalized by the runtime; this path goes through LLVM's SPIR-V backend, which _"does not currently preserve debug information"_ ([Clang HIP Support § SPIR-V Support on HIPAMD ToolChain][clang-hip]).
- **Intel and other OpenCL devices:** chipStar implements the HIP runtime over Level Zero or OpenCL, with the HIPSPV toolchain translating device IR to SPIR-V _"via the SPIR-V backend or the out-of-tree LLVM-SPIRV translator"_ ([Clang HIP Support][clang-hip]). This is OpenCL-flavoured (`Kernel` capability, `Physical64` addressing) SPIR-V, not Vulkan SPIR-V.
- **Separate compilation:** whole-program by default; `-rdc=true` (nvcc) or `-fgpu-rdc` (Clang) links device code across TUs and is required for cross-TU function pointers ([NVCC § 2.7.3.3][cuda-nvcc]; [Clang HIP Support § Function Pointers][clang-hip]).
- **Standard parallelism:** `--hipstdpar` offloads `std::` algorithms with `parallel_unsequenced_policy` by compiling the TU as HIP and relaxing the side checks with `HIPStdPar` (visible in `IdentifyPreference`) ([`SemaCUDA.cpp`][sema-cuda]).

None of these produce Vulkan-environment SPIR-V. The generic address space CUDA leans on needs the SPIR-V `GenericPointer` capability, which the LLVM SPIR-V backend declares as requiring `Addresses` ([`SPIRVSymbolicOperands.td`][spv-ops]) — a Kernel-environment capability; Vulkan shaders use `Logical` or `PhysicalStorageBuffer64` addressing. See [the LLVM SPIR-V backend deep-dive][llvm-spirv].

## Host integration and CPU execution

Host integration is the model's strongest feature. A kernel is a symbol in the host program; launching it is a call that the compiler rewrites into argument packing plus `cudaLaunchKernel`; the fat binary is registered before `main`; shared structs need no reflection or binding generation because both sides agree on layout by construction. HIP adds `hipLaunchKernelGGL` as a macro form and keeps API parity with the CUDA runtime.

CPU execution is where the model is weakest:

- **NVIDIA had one and removed it.** The CUDA runtime's deprecated error codes record that _"Device emulation mode was removed with the CUDA 3.1 release"_ ([CUDA Runtime API, Deprecated List][cuda-deprecated]). Today's CUDA has no CPU device; `__host__ __device__` functions run on the CPU only as ordinary host calls, with no `threadIdx`, no shared memory, and no warp intrinsics. HIP's docs say the same: HD functions _"can't use the HIP built-ins (e.g., `threadIdx.x` … or `warpSize`), as they are not available on the host"_ ([`hip_cpp_language_extensions.rst`][hip-ext]).
- **HIP-CPU** is AMD's header-only emulator, endorsed by the Clang docs (_"This header-only library enables CPUs to execute unmodified HIP code"_ — [Clang HIP Support][clang-hip]). It runs each block on the C++ Parallel Algorithms library and each thread as a **fiber** (it vendors `libco`). Warp intrinsics are implemented through a per-tile scratchpad and a fiber barrier: `ballot` writes the lane's predicate into a `std::bitset`, calls `Tile::this_tile().barrier()`, reads the word, and barriers again ([`intrinsics.hpp`][hipcpu-intrin]). It _"does not do any explicit vectorisation and does not rely on a vectorising back-end"_ ([`docs/overview.md`][hipcpu-overview]), and its performance guide warns that barriers cost _"`O(block_size)` fiber switches"_ ([`docs/performance.md`][hipcpu-perf]). Its `warpSize` is hard-coded to 64 with the comment _"TODO: this is untrue and a problem"_ ([`hip_constants.h`][hipcpu-const]). The overview lists _"reliance of lock-stepped execution of fibers in a warp"_ as non-portable, _"technically this is UB even in current HIP / CUDA"_. The last commit at the pin is dated 2024-03-19.
- **Research transpilers** lower CUDA to CPU threads instead of emulating it: Polygeist's GPU-to-CPU work (Moses et al., [arXiv 2207.00257][polygeist], 2022) uses barrier elimination and loop fission over MLIR. It runs threads as loops, not as SIMD lanes, so subgroup operations get no vector-lane semantics. _Not verified against a pinned source._

> [!NOTE]
> None of these is an SPMD-on-SIMD executor in the ISPC sense: HIP-CPU is the "scalar reference" shape (one fiber per invocation, barriers as context switches), and Polygeist is a loop transformation. See [the ISPC deep-dive][ispc] for the vectorizing shape.

## Lessons for sparkles:shaders

- **Adopt per-side resolution with deferred, reachability-based diagnostics.** LDC's `@compute(CompileFor.hostAndDevice)` ([`dcompute.d`][ldc-dcompute]) already gives D the dual-compiled module; what it lacks is Clang's `CFP_*` ranking and wrong-side rule. A host-only call inside a `hostAndDevice` function should be an error only when device-emitted code reaches it, and the error should name the reaching entry point the way Clang's call-chain notes do. D templates already instantiate on use, which matches Clang's treatment of HD templates.
- **Match the "layout never depends on the side" rule, and test it.** CUDA forbids types whose signature depends on `__CUDA_ARCH__`. sparkles should forbid any `version`/`__dcompute_reflect` branch that changes a struct crossing the CPU/GPU boundary, and back the rule with a conformance test that compares `.sizeof`, `.alignof` and every `.offsetof` from the host build against the SPIR-V reflection of the same type.
- **Avoid unannotated generic pointers in the graphics path.** CUDA can leave address spaces implicit because PTX and AMDGCN have a flat space and `InferAddressSpaces` cleans up. Vulkan SPIR-V has no generic storage class. Keep dcompute's explicit `Pointer!(AddrSpace, T)` (or BDA `PhysicalStorageBuffer` pointers), and treat inference as an optimisation, never as a correctness requirement.
- **Make subgroup width a value, and masks at least 64 bits wide.** HIP's 32-versus-64 split and its 64-bit masks are the portable minimum; SPIR-V's ballot is a `uvec4` (128 bits). One `SubgroupMask` type sized for 128 lanes, with `subgroupSize` read at run time (folded where it is a specialization constant), avoids the port-time breakage HIP documents.
- **Specify convergence as Volta does, not as lockstep.** Since CC 7.0, code that assumes lockstep is wrong, and HIP-CPU calls relying on it UB. The CPU simulator's contract should be "a subgroup operation sees exactly the invocations that reach it together". The reference executor should be free to schedule invocations independently, and a conformance test should check that results do not depend on that schedule.
- **Take HIP-CPU's design for the scalar reference executor, and its measurements as a warning.** One fiber per invocation, plus scratchpad-and-barrier for ballot and shuffle, is the simplest correct shape for workgroup barriers and subgroup operations. Its `O(block_size)` barrier cost is also why the SPMD-on-SIMD executor must not be fiber-based.
- **Do not copy the missing specification.** Clang and nvcc disagree on overloading and HD semantics because CUDA has no spec. sparkles' rules for which side a function runs on belong in `SPEC.md` ([spec][spec]) as numbered, testable contracts.

## Strengths

- One function, compiled per side, with layout shared by construction: kernel arguments are plain structs, and nothing generates bindings.
- Clang's target-aware overload resolution and deferred diagnostics make HD libraries practical without macro walls.
- Explicit convergence through `_sync` masks and cooperative groups: the clearest mainstream specification of who participates in a cross-lane operation.
- Scoped memory model aligned with ISO C++ (`cuda::atomic_ref`, thread scopes), with forward-progress rules written as edits to `[intro.progress]`.
- An open-source, production front end (Clang) serving NVIDIA, AMD and SPIR-V devices from one AST model.

## Weaknesses

- Compute only: no graphics stages, derivatives, samplers-with-LOD, interpolation or `discard`. A shading-language replacement cannot copy its scope.
- No formal specification; nvcc and Clang differ on overloading, the wrong-side rule and standard-library support.
- Generic pointers and address-space inference do not map to Vulkan's logical addressing.
- CPU execution was removed from CUDA (3.1); HIP-CPU is incomplete, scalar and fiber-bound, and appears unmaintained since 2024-03.
- Warp size and mask width differ between vendors (32 vs 64; 32-bit vs 64-bit masks), and ported code breaks on it.
- Closed toolchain on NVIDIA (`nvcc`, `ptxas`), and an EULA-governed SDK even when Clang compiles the source.

## Key design decisions and trade-offs

| Decision                                                  | Rationale                                                                      | Trade-off                                                                                   |
| --------------------------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| Execution space as a per-function attribute               | Fine-grained: one header mixes host, device and HD code                        | Every helper needs marking; defaults (`constexpr` ⇒ HD, templates opt-in) grow by exception |
| Execution space is part of the signature (Clang)          | Lets H and D overloads coexist; `CFP_*` ranking picks the side                 | Diverges from nvcc; portable code needs `#ifdef __NVCC__` idioms                            |
| Wrong-side errors deferred to codegen reachability        | HD headers compile even when one side cannot use part of them                  | Errors surface far from their cause; needs call-chain notes to be usable                    |
| Merged parsing per architecture (Clang)                   | Robust to C++ corner cases; no early decision about which declarations to keep | N+1 full front-end passes per TU; both sides must type-check                                |
| Generic pointers + `InferAddressSpaces`                   | Plain C++ pointers work unchanged on the device                                | Correct only on flat-address hardware; impossible on Vulkan logical SPIR-V                  |
| SIMT as the model, ITS as the hardware (CC 7.0+)          | Per-thread forward progress; locks and producer/consumer inside a warp work    | Broke warp-synchronous code; required `_sync` masks everywhere                              |
| Masks on every warp intrinsic                             | Participation is explicit and checkable                                        | Mask width is vendor-specific (32 vs 64 bits); verbose                                      |
| Remove device emulation (CUDA 3.1), rely on GPU debuggers | Emulation semantics diverged from hardware                                     | No vendor CPU path; testing without a GPU depends on third parties (HIP-CPU)                |
| HIP as a header layer over CUDA on NVIDIA                 | Portability without a second NVIDIA compiler                                   | Lowest-common-denominator API; AMD-only features need `#ifdef`s                             |

## Sources

- [CUDA Programming Guide v13.4.2 (index)][cuda-pg] — [§ 1.2 Programming Model][cuda-model] · [§ 2.3 Writing SIMT Kernels][cuda-simt] · [§ 2.4 Writing Tile Kernels][cuda-tile] · [§ 2.6 Unified and System Memory][cuda-mem] · [§ 2.7 NVCC][cuda-nvcc] · [§ 3.2 Advanced Kernel Programming (Independent Thread Scheduling)][cuda-adv] · [§ 4.1 Unified Memory][cuda-um] · [§ 4.4 Cooperative Groups][cuda-cg] · [§ 5.3 C++ Language Support][cuda-cpp] · [§ 5.4 C/C++ Language Extensions][cuda-ext] · [§ 5.7 Memory Model][cuda-memmodel] · [§ 5.8 Execution Model][cuda-exec]
- [CUDA Runtime API — Deprecated List (device emulation removed in 3.1)][cuda-deprecated]
- [`llvm/docs/CompileCudaWithLLVM.md` — Clang CUDA dialect, merged parsing, wrong-side rule][compile-cuda]
- [`clang/docs/HIPSupport.md` — HIP in Clang, deferred diagnostics, `amdgcnspirv`, chipStar, HIP-CPU][clang-hip]
- [`clang/lib/Sema/SemaCUDA.cpp` — `IdentifyTarget`, `IdentifyPreference`][sema-cuda] · [`clang/include/clang/Sema/SemaCUDA.h` — `CUDAFunctionPreference`][sema-cuda-h]
- [`clang/include/clang/Basic/Attr.td`][attr-td] · [`AttrDocs.td`][attr-docs] · [`LangOptions.def`][langopts]
- [`clang/lib/Headers/__clang_cuda_intrinsics.h`][cuda-intrin] · [`__clang_cuda_builtin_vars.h`][builtin-vars] · [`clang/lib/CodeGen/CGCUDANV.cpp`][cgcudanv]
- [`llvm/docs/ConvergentOperations.rst`][llvm-convergent] · [`llvm/lib/Target/SPIRV/SPIRVSymbolicOperands.td`][spv-ops]
- [ROCm/HIP — `docs/what_is_hip.rst`][hip-what] · [`docs/how-to/hip_cpp_language_extensions.rst`][hip-ext] · [`docs/understand/programming_model.rst`][hip-model] · [`docs/how-to/hip_runtime_api/cooperative_groups.rst`][hip-cg] · [`include/hip/hip_cooperative_groups.h`][hip-cg-h]
- [ROCm/HIP-CPU — `README.md`][hipcpu-readme] · [`docs/overview.md`][hipcpu-overview] · [`docs/performance.md`][hipcpu-perf] · [`src/include/hip/detail/intrinsics.hpp`][hipcpu-intrin] · [`include/hip/hip_constants.h`][hipcpu-const]
- [LDC `runtime/druntime/src/ldc/dcompute.d`][ldc-dcompute]
- [Moses et al., High-Performance GPU-to-CPU Transpilation and Optimization via High-Level Parallel Constructs (2022)][polygeist]
- Related: [SYCL][sycl] · [ISPC][ispc] · [dcompute][dcompute] · [LLVM SPIR-V backend][llvm-spirv] · [Clang HLSL][clang-hlsl] · [Concepts][concepts] · [Comparison][comparison] · [Index][index]

<!-- References -->

[cuda-pg]: https://docs.nvidia.com/cuda/cuda-programming-guide/index.html
[cuda-model]: https://docs.nvidia.com/cuda/cuda-programming-guide/01-introduction/programming-model.html
[cuda-simt]: https://docs.nvidia.com/cuda/cuda-programming-guide/02-basics/writing-cuda-kernels.html
[cuda-tile]: https://docs.nvidia.com/cuda/cuda-programming-guide/02-basics/writing-tile-kernels.html
[cuda-mem]: https://docs.nvidia.com/cuda/cuda-programming-guide/02-basics/understanding-memory.html
[cuda-nvcc]: https://docs.nvidia.com/cuda/cuda-programming-guide/02-basics/nvcc.html
[cuda-adv]: https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/advanced-kernel-programming.html
[cuda-um]: https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/unified-memory.html
[cuda-cg]: https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/cooperative-groups.html
[cuda-cpp]: https://docs.nvidia.com/cuda/cuda-programming-guide/05-appendices/cpp-language-support.html
[cuda-ext]: https://docs.nvidia.com/cuda/cuda-programming-guide/05-appendices/cpp-language-extensions.html
[cuda-memmodel]: https://docs.nvidia.com/cuda/cuda-programming-guide/05-appendices/cuda-cpp-memory-model.html
[cuda-exec]: https://docs.nvidia.com/cuda/cuda-programming-guide/05-appendices/cuda-cpp-execution-model.html
[cuda-deprecated]: https://docs.nvidia.com/cuda/cuda-runtime-api/cuda_runtime_api/deprecated.html
[compile-cuda]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/docs/CompileCudaWithLLVM.md
[clang-hip]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/docs/HIPSupport.md
[sema-cuda]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Sema/SemaCUDA.cpp
[sema-cuda-h]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/include/clang/Sema/SemaCUDA.h
[attr-td]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/include/clang/Basic/Attr.td
[attr-docs]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/include/clang/Basic/AttrDocs.td
[langopts]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/include/clang/Basic/LangOptions.def
[cuda-intrin]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Headers/__clang_cuda_intrinsics.h
[builtin-vars]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/Headers/__clang_cuda_builtin_vars.h
[cgcudanv]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/clang/lib/CodeGen/CGCUDANV.cpp
[llvm-convergent]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/docs/ConvergentOperations.rst
[spv-ops]: https://github.com/llvm/llvm-project/blob/27ba493781215910f560b36cd5b3b2f6c93ec5a3/llvm/lib/Target/SPIRV/SPIRVSymbolicOperands.td
[hip-repo]: https://github.com/ROCm/HIP/tree/e00661614d20b38d0769c3755031f41925567d83
[hip-license]: https://github.com/ROCm/HIP/blob/e00661614d20b38d0769c3755031f41925567d83/LICENSE.md
[hip-version]: https://github.com/ROCm/HIP/blob/e00661614d20b38d0769c3755031f41925567d83/VERSION
[hip-what]: https://github.com/ROCm/HIP/blob/e00661614d20b38d0769c3755031f41925567d83/docs/what_is_hip.rst
[hip-ext]: https://github.com/ROCm/HIP/blob/e00661614d20b38d0769c3755031f41925567d83/docs/how-to/hip_cpp_language_extensions.rst
[hip-model]: https://github.com/ROCm/HIP/blob/e00661614d20b38d0769c3755031f41925567d83/docs/understand/programming_model.rst
[hip-cg]: https://github.com/ROCm/HIP/blob/e00661614d20b38d0769c3755031f41925567d83/docs/how-to/hip_runtime_api/cooperative_groups.rst
[hip-cg-h]: https://github.com/ROCm/HIP/blob/e00661614d20b38d0769c3755031f41925567d83/include/hip/hip_cooperative_groups.h
[hipcpu-readme]: https://github.com/ROCm/HIP-CPU/blob/e112c935057434897bb12d9ab3910380a8bd5f58/README.md
[hipcpu-overview]: https://github.com/ROCm/HIP-CPU/blob/e112c935057434897bb12d9ab3910380a8bd5f58/docs/overview.md
[hipcpu-perf]: https://github.com/ROCm/HIP-CPU/blob/e112c935057434897bb12d9ab3910380a8bd5f58/docs/performance.md
[hipcpu-intrin]: https://github.com/ROCm/HIP-CPU/blob/e112c935057434897bb12d9ab3910380a8bd5f58/src/include/hip/detail/intrinsics.hpp
[hipcpu-const]: https://github.com/ROCm/HIP-CPU/blob/e112c935057434897bb12d9ab3910380a8bd5f58/include/hip/hip_constants.h
[ldc-dcompute]: https://github.com/ldc-developers/ldc/blob/ac0e420af3fe74de50ff2138f9ffcb464c29873a/runtime/druntime/src/ldc/dcompute.d
[polygeist]: https://arxiv.org/abs/2207.00257
[spec]: ../../specs/shaders/SPEC.md
[sycl]: ./sycl.md
[ispc]: ./ispc.md
[dcompute]: ./dcompute.md
[llvm-spirv]: ./llvm-spirv-backend.md
[clang-hlsl]: ./clang-hlsl.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
