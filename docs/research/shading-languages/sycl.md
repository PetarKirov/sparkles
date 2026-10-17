# SYCL (ISO C++ / Khronos)

The Khronos single-source C++ model for heterogeneous compute: kernels are ordinary C++ lambdas handed to `parallel_for`, the device compiler finds them by reachability, and implementations as different as Intel's DPC++ and AdaptiveCpp's single-pass JIT lower the same source to SPIR-V, PTX, amdgcn, Vulkan-flavoured SPIR-V and — the part that matters most here — vectorized host CPU code with work-group barriers.

| Field          | Value                                                                                                                                                                   |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | ISO C++17 (C++20 also normative) plus a library; no new keywords                                                                                                        |
| License        | Specification sources CC BY 4.0, headers/samples Apache-2.0 ([`LICENSE.txt`][lic]); AdaptiveCpp BSD-2-Clause; DPC++ Apache-2.0 with LLVM exception                      |
| Repository     | [KhronosGroup/SYCL-Docs][spec-repo] · [AdaptiveCpp/AdaptiveCpp][acpp-repo] · [intel/llvm][dpcpp-repo] (DPC++)                                                           |
| Documentation  | [SYCL 2020 HTML specification][spec-html] · [AdaptiveCpp docs][acpp-doc] · [DPC++ users manual][dpcpp-manual]                                                           |
| Category       | Single-source compute; host + device in one translation unit                                                                                                            |
| Latest version | SYCL 2020 revision 12 (tag `SYCL-2020/final-rev12`, tagged commit dated 2026-08-06); `main` is the "SYCL Next" draft. AdaptiveCpp `v25.10.0` (tagged commit 2025-11-05) |
| Targets        | Any "backend": OpenCL, Level Zero (SPIR-V), CUDA (PTX), HIP (amdgcn), host CPU; AdaptiveCpp adds experimental Metal (MSL) and Vulkan (shader SPIR-V via `clspv`)        |
| Stages         | Compute only — `single_task`, `parallel_for` over `range`/`nd_range`; no graphics stages                                                                                |
| Pinned sources | SYCL-Docs `e468723a8b…`, AdaptiveCpp `31db2e8390…`, intel/llvm `4a08d0453c…` (all 2026-10)                                                                              |

> [!NOTE]
> The pinned SYCL-Docs revision is `main`, whose `sycl_version.txt` reads `SYCLVERSION=NEXT`. The text cited here is the SYCL 2020 text carried forward; the only post-2020 changes listed in its [`what_changed.adoc`][what-changed] are a deprecated `submit()` overload and address-space aliases.

---

## Overview

### What it solves

SYCL lets one C++ source describe both the host program and the kernels it launches, without a separate kernel language (OpenCL C, GLSL) and without CUDA's non-standard `__global__`/`<<<…>>>` syntax. A kernel is any callable returning `void`; templates, lambdas, classes and the standard library's value types work inside it, subject to a short list of restrictions. The specification is API-neutral: "there is no requirement that SYCL implementations must use OpenCL; SYCL implementations are free to support devices via any low-level API (or "backend") they choose" ([`introduction.adoc`][intro]).

For sparkles the interest is structural. SYCL is the only mainstream model with **several independent compilers** for one single-source language, so it shows which parts of a single-source design are language (what the user writes) and which are implementation (how kernels are found, named, embedded and lowered). It also contains the most developed answer to the question sparkles' CPU simulator must answer: how to run `nd_range` kernels with barriers, sub-groups and local memory on a CPU, fast.

### Design philosophy

From the specification's introduction ([`introduction.adoc`][intro]):

> _"All computational kernels to be executed on a device can be written inside C++ source files as normal C++ code, alongside any code intended to be run on a system's host processor. This concept, known as "single-source" programming, reduces the complexity of heterogeneous programming for developers and gives compilers greater opportunities to analyze/optimize across the host-device boundary."_

and, immediately after:

> _"SYCL is designed to be as close to standard C++ as possible, and some implementations of SYCL may be able to use a standard C++ compiler to target CPU devices."_

That second sentence is the design's escape hatch and its burden: a SYCL kernel is valid C++, so a library-only implementation (AdaptiveCpp's `omp.library-only`) can run it on the CPU with no special compiler. But `nd_range` barriers are not expressible in plain C++ without fibers, which is why the efficient CPU paths all became compiler passes.

---

## How it works

A command group is submitted to a `queue`; inside it, a kernel invocation command (`single_task`, `parallel_for`) receives a function object. The spec's own minimal example ([`anatomy.cpp`][anatomy]) uses USM and an in-order queue:

```cpp
sycl::queue myQueue{sycl::property::queue::in_order()};
int *dataDevice = sycl::malloc_device<int>(N, myQueue);

myQueue.parallel_for(N, [=](sycl::id<1> idx) {
  dataDevice[idx] = idx;          // kernel body: ordinary C++
});
myQueue.copy(dataDevice, dataHost.data(), N);
myQueue.wait();
```

**Kernel discovery is by reachability, not annotation.** From [`device_compiler.adoc`][devcomp]:

> _"The device compiler identifies kernels by looking for calls to Kernel invocation commands such as `parallel_for`. One of the parameters is a function object which is known as a SYCL kernel function, and this function must always return `void`. Any function called by the SYCL kernel function is also compiled for the device … The device compiler searches recursively for any functions called from a device function."_

There is no `__device__` marker. A function becomes device code because a kernel calls it; `SYCL_EXTERNAL` exists only for device functions defined in another translation unit.

**Kernel naming** exists so that the host runtime can find the device image of a kernel. A kernel name is a C++ typename that "must be forward declarable at namespace scope" ([`device_compiler.adoc` § Naming of kernels][devcomp]); for a lambda it is optional in the full feature set (`h.single_task<class MyKernel>([=]{…})`, [`lambdaNameExamples.cpp`][lambda-names]) and mandatory in the reduced feature set ([`feature_sets.adoc`][feature-sets]). Implementations generate names for unnamed lambdas with compiler support (AdaptiveCpp's explicit multipass needs clang's `__builtin_unique_stable_name()`, [`compilation.md`][acpp-compilation]).

**Two index spaces.** `parallel_for(range<N>, [](item<N>){…})` is a basic data-parallel launch with no work-groups exposed and no barriers. `parallel_for(nd_range<N>(global, local), [](nd_item<N>){…})` exposes work-groups and sub-groups, local memory, and `group_barrier` ([`parallelforbarrier.cpp`][pfbarrier]):

```cpp
cgh.parallel_for(nd_range<3>(range<3>(4, 4, 4), range<3>(2, 2, 2)),
                 [=](nd_item<3> item) {
                   //[kernel code]
                   group_barrier(item.get_group());
                   //[kernel code]
                 });
```

The split matters for CPUs: a `range` kernel is an embarrassingly parallel loop a CPU vectorizes trivially, while an `nd_range` kernel with a barrier needs the whole compiler machinery described under [Host integration and CPU execution](#host-integration-and-cpu-execution).

---

## Execution model and stages

SYCL has one stage: the compute kernel. Its hierarchy is `nd_range` → work-group → sub-group → work-item. A `sub_group` cannot be constructed by the user — "the set of work-items represented by an instance of the `sub_group` class is determined by the implementation" ([`programming_interface.adoc` § `sub_group` class][pi]) — and its sizes are queried with `info::device::sub_group_sizes` or pinned with the `reqd_sub_group_size(size)` kernel attribute ([`device_compiler.adoc`][devcomp]).

Forward progress is specified in C++ terms ([`architecture.adoc` § Forward progress][arch]):

> _"Each work-item in SYCL is a separate thread of execution, providing at least weakly parallel forward progress guarantees. … All implementations must additionally ensure that a work-item arriving at a group barrier does not prevent other work-items in the same group from making progress."_

Weakly parallel progress is exactly what a CPU executor that runs work-items one after another can provide; the barrier clause is what forces it to split kernels at barriers (or use fibers). There are no vertex, fragment, mesh or ray-tracing stages, no derivatives, no helper invocations and no `discard`. SYCL 1.2.1's _hierarchical_ `parallel_for_work_group`/`parallel_for_work_item` model survives in SYCL 2020 but is widely regarded as hard to implement well; AdaptiveCpp's [scoped parallelism][acpp-scoped] replaces it, explicitly citing that "`nd_range` parallel for is notoriously difficult to implement efficiently in library-only CPU implementations".

## Type system and generic programming

The type system is C++'s: templates, overloading, lambdas with captures, `constexpr`, classes. Kernel arguments are the lambda's captures, which must be **device copyable** — trivially copyable types, plus `std::array`, `std::optional`, `std::pair`, `std::tuple` and `std::variant` of device-copyable types ([`architecture.adoc` § Device copyable][arch]).

Two vector-like types coexist, and the reason they coexist is instructive:

| Type               | Sizes                     | Semantics                                                                                                   | Source                    |
| ------------------ | ------------------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------- |
| `vec<DataT, N>`    | `N` ∈ {1, 2, 3, 4, 8, 16} | OpenCL-style SIMD vector, swizzles (`v.swizzle<2, 1>()`, `xyzw`/`rgba`), `vec<T, 3>` sized and aligned as 4 | [`pi` § Vector types][pi] |
| `marray<DataT, N>` | any positive `N`          | "contiguous fixed-size container" of numeric type, element-wise math, comparisons return `marray<bool, N>`  | [`pi` § Math array][pi]   |

`vec<T, 3>` deliberately has the size of `vec<T, 4>` "to provide interoperability with OpenCL vector types", on host and device alike, "to allow for instances of the `vec` class template to be passed to SYCL kernel functions". `marray` was added in 2020 "to begin disambiguation of" the two uses `vec` had served ([`what_changed.adoc`][what-changed]): a storage-and-math array with no layout promise beyond contiguity, versus a hardware-vector type. The swizzle API is a proxy-object design ([`swizzle-example.cpp`][swizzle]) whose temporaries "ha[ve] no effect" unless read or written — the same lvalue-swizzle problem D's `opDispatch` swizzles face.

Address spaces are **not** part of the C++ type: "if `int i;` is allocated to the global address space, then `decltype(&i)` shall evaluate to `int*`" ([`device_compiler.adoc` § Address space assignment][devcomp]). The compiler infers them, using the generic address space where the backend has one and an "inferred address space" mode otherwise; `multi_ptr<T, Space, Decorated>` exists to state them explicitly. The reduced feature set allows inference-only compilers that never assume a generic space ([`feature_sets.adoc`][feature-sets]) — the situation of a Vulkan target with Logical addressing.

## Resources, interfaces and memory layout

SYCL has two memory models, side by side by design ("These routines augment, rather than replace, the buffer-based interfaces", [`pi` § USM][pi]):

- **Buffers and accessors.** A `buffer<T, N>` owns data with no fixed location; a command group declares access with `accessor{buf, cgh, read_only}`, and the runtime derives the dependency DAG and the transfers from those declarations. `local_accessor` allocates work-group memory per launch. Image accessors (`unsampled_image_accessor`, `sampled_image_accessor`) exist but are optional and unimplemented in several implementations (AdaptiveCpp's [`limitations.md`][acpp-limits] lists images as unimplemented).
- **Unified Shared Memory.** `malloc_device`, `malloc_host`, `malloc_shared` return raw pointers with full pointer arithmetic ([`usm_shared.cpp`][usm-shared]); the user orders work with events or in-order queues.

Uniform-style data has no dedicated binding: small values travel as lambda captures (the implementation chooses push constants, kernel arguments or a uniform buffer), and **specialization constants** are first class. A `constexpr specialization_id<T>` at namespace or class scope names one; the host sets it with `handler::set_specialization_constant<id>(value)` and the kernel reads it through a `kernel_handler` parameter ([`usingSpecConstants.cpp`][spec-const]). The spec warns that "applications that frequently change the values of specialization constants may see an overhead associated with recompilation of the kernel's bundle" ([`pi` § Specialization constants][pi]) — on SPIR-V targets they become `OpSpecConstant`, elsewhere a JIT re-specialization.

There is no descriptor-set, binding-number or interface-block model in the language. Layout is C++ layout; the `vec<T, 3>` padding rule is the only shader-style layout rule SYCL carries.

## Built-in library and intrinsics

- **Math.** OpenCL-derived math (`sycl::sin`, `fma`, `native::` and `half_precision::` variants) over scalars, `vec` and `marray` ([`pi` § Math functions][pi]); precision follows OpenCL's ULP tables.
- **Group functions.** `group_broadcast`, `group_barrier`, and a C++17-style **group algorithms library** — `reduce_over_group`, `joint_reduce`, `exclusive_scan_over_group`, `any_of_group`, `permute_group_by_xor`, `shift_group_left`, `select_from_group` — whose first argument is a `group` or `sub_group`. Every algorithm "act[s] as [a] group function", inheriting its convergence rule (below).
- **Reductions.** `sycl::reduction(ptr, identity, plus<>())` passed to `parallel_for` produces a `reducer` argument — a portable spelling for what GPU code writes with sub-group and work-group collectives.
- **Atomics.** `atomic_ref<T, memory_order, memory_scope, address_space>` replaces the deprecated `atomic` types ([`pi` § Atomic references][pi]).

The implementations map these to per-target builtins. AdaptiveCpp's single-pass compiler emits calls to `__acpp_sscp_*` builtins with one definition per backend, linked at JIT time; on the host, for instance, the sub-group builtins are defined for a sub-group of size one ([`sscp/host/subgroup.cpp`][acpp-host-subgroup]):

```cpp
HIPSYCL_SSCP_BUILTIN __acpp_uint32 __acpp_sscp_get_subgroup_size() {
  return 1;
}
```

## Control flow, memory model and restrictions

The device-code restrictions are a short normative list ([`device_compiler.adoc` § Language restrictions for device functions][devcomp]):

> _"no virtual member functions are allowed to be called in a device function. No function pointers or references are allowed to be called … RTTI is disabled … No variadic functions … Exception-handling cannot be used inside a device function. `noexcept` is allowed. Recursion is not allowed in a device function. Variables with thread storage duration … are not allowed to be odr-used … Variables with static storage duration that are odr-used inside a device function, must be either `const` or `constexpr`"_

plus "memory storage allocation is not allowed in kernels" (placement `new` is fine) and a `void` return. DPC++ relaxes the virtual-call rule through the `sycl_ext_oneapi_virtual_functions` extension ([`VirtualFunctions.md`][dpcpp-virtual]); the core rule stands. These are almost exactly the restrictions a D `@compute` module needs (no GC allocation, no exceptions, no `TypeInfo`, no `shared`/TLS mutable globals), and the list is short because SYCL lets the compiler fail late — a kernel that is never submitted to a device never has to compile for it.

**Convergence** is the key semantic rule. Group functions "act as _synchronization points_ and must be encountered in converged control flow by all work-items in the group" ([`pi` § Group functions][pi]). That is the GLSL/HLSL "uniform control flow" rule restated, and it is what makes a CPU implementation legal: if every work-item reaches the barrier in the same dynamic instance, the kernel can be split at barriers and each region run as a loop over work-items. The memory model is C++'s, extended with `memory_scope` (`work_item`, `sub_group`, `work_group`, `device`, `system`) on fences and atomics; `group_barrier` takes an optional fence scope.

## Compilation pipeline and targets

SYCL fixes no pipeline; the spec distinguishes "single-source" and "shared-source" (separate host and device compiler passes over one file) implementations. The three that matter:

| Implementation                  | Device flow                                                                                                                   | CPU path                                                                                         | Source                                        |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------- |
| DPC++                           | clang device pass per target → `llvm-link` → `llvm-spirv` (SPIRV-LLVM-Translator) → `clang-offload-wrapper` into a fat binary | `spir64_x86_64` (SPIR-V AOT for the OpenCL CPU runtime) or `native_cpu` (Vecz + work-item loops) | [`CompilerAndRuntimeDesign.md`][dpcpp-design] |
| AdaptiveCpp SSCP                | one clang pass; device LLVM IR extracted and embedded in the host binary; JIT-lowered per device by `llvm-to-backend`         | `llvm-to-host` + CBS barrier passes + LLVM loop vectorizer                                       | [`generic-sscp.md`][acpp-sscp]                |
| AdaptiveCpp SMCP / library-only | clang CUDA/HIP drivers with a plugin (`cuda.integrated-multipass` …), or the library over OpenMP or `nvc++`                   | `omp.library-only` (fibers for barriers), `omp.accelerated` (clang plugin, CBS)                  | [`compilation.md`][acpp-compilation]          |

**DPC++.** "The resulting LLVM IR module is then translated into a SPIR-V module using the `llvm-spirv` tool and wrapped in a host object file using the `clang-offload-wrapper` tool" ([`CompilerAndRuntimeDesign.md`][dpcpp-design]). Its `-fsycl-targets` list includes `spir64`, `spir64_x86_64`, `spir64_gen`, and in special builds `nvptx64-nvidia-cuda`, `amdgcn-amd-amdhsa` and `native_cpu` ([`UsersManual.md`][dpcpp-manual]).

**AdaptiveCpp's generic SSCP** is the most relevant design in the SYCL world. From [`generic-sscp.md`][acpp-sscp]:

> _"kernels are compiled to a generic representation in LLVM IR, which is then lowered at runtime to backend-specific formats such as PTX or SPIR-V as needed. … there is only a single compiler invocation, and the code is only parsed once, no matter how many devices or backends are utilized."_

The mechanism is **IR constants**: globals with no value at parse time that are later fixed and constant-folded. Stage 1 clones the module, sets "is device" in one copy and "is host" in the other, so `if` statements guarding kernel calls fold away; builtins branch on the same constant between `__acpp_sscp_*` and host implementations, which "allows SYCL kernels to simultaneously run correctly both on the host as well as on SSCP-supported devices." The device bitcode is then embedded as a string constant in the host module. Stage 2 runs at runtime, when the device is known: `llvm-to-backend` "flavors" the IR (address spaces, entry-point marking, triple, data layout, calling conventions), links a backend bitcode library for the builtins, optimizes, and lowers. The pinned tree has six lowerings under [`src/compiler/llvm-to-backend/`][acpp-l2b]: `ptx`, `amdgpu`, `spirv`, `host`, `metal` and `clspv`.

Two of those six bear directly on sparkles:

- `spirv` targets **OpenCL/Level Zero kernel SPIR-V** by retargeting to `spir64-unknown-unknown` and shelling out to a patched `llvm-spirv`; the source is a catalogue of translator workarounds ("llvm-spirv translator does not like GEPs into 0-size arrays", "llvm-spirv wants ByVal attribute for all aggregates", [`LLVMToSpirv.cpp`][acpp-l2spirv]). It does not use LLVM's SPIR-V backend.
- The experimental **Vulkan** backend reaches _shader_ SPIR-V by "flavouring the LLVM-IR to resemble OpenCL-C generated IR" and handing it to `clspv` (pinned to [`clspv@3d017c6d`][clspv]) with the `Physical64` addressing model ([`install-vulkan.md`][acpp-vulkan]). Requirements are `bufferDeviceAddress`, `shaderInt64` and `variablePointers`; device USM maps to buffer device addresses; kernel arguments go to push constants or a uniform buffer. Its stated limits — no pointer chasing "in a linked list fashion", no storing addresses of variables to global memory, float atomics wrong, `marray<short, 3>` failing because it produces an `i48` — are the cost of a generic address space on `PhysicalStorageBuffer64`.

## Host integration and CPU execution

**The host device is gone.** SYCL 1.2.1 required every implementation to expose a host device; SYCL 2020 dropped it ([`what_changed.adoc`][what-changed]):

> _"A SYCL implementation is no longer required to provide a host device. Instead, an implementation is only required to provide at least one device. Implementations are still allowed to provide devices that are implemented on the host, but it is no longer required. The specification no longer defines any special semantics for a "host device" and APIs specific to the host device have been removed."_

The working group could not agree on what a host backend _is_. The unbuilt appendix [`host_backend.adoc`][host-backend] records the open question verbatim: "should the backend be a faithful emulation of a typical GPU accelerator? Or, should it be an optimized backend tailored to run on the host CPU? If we choose the later, the host backend could allow kernels to call arbitrary C++ code. If we choose the former, we would not allow this." That fork — reference emulator versus fast CPU target — is precisely the scalar-reference / SPMD-on-SIMD split in sparkles' plan, and SYCL's experience says to specify both separately rather than one device that tries to be both.

What replaced the host device are three CPU strategies, in rising sophistication:

1. **Fibers (AdaptiveCpp `omp.library-only`).** Each work-item is a fiber that yields at a barrier. Correct with any C++ compiler, but "the relative cost of a barrier in this paradigm is significantly higher … utilizing barriers in this scenario may prevent vectorization across work items" ([`compilation.md`][acpp-compilation]).
2. **Continuation-based synchronization, then the loop vectorizer (AdaptiveCpp CBS).** The CBS passes perform "deep loop fission on nd*range parallel_for kernels that contain barriers", after Karrenberg and Hack's \_Improving performance of OpenCL on CPUs* (CC 2012) and Joachim Meyer's [thesis][meyer-thesis]. The SSCP host lowering registers the pipeline explicitly (`registerCBSPipeline(MPM, OptLevel::O3, true)` in [`LLVMToHost.cpp`][acpp-l2host]); [`PipelineBuilder.cpp`][acpp-cbs-pipeline] runs `CanonicalizeBarriersPass`, `KernelFlatteningPass`, `SubCfgFormationPass`, `RemoveBarrierCallsPass` and `LoopsParallelMarkerPass`. `SubCfgFormation` cuts the CFG at barriers into sub-CFGs, wraps each in work-item loops, and "creates array allocas for values that are identified as spanning multiple subcfgs" — but stores uniform values in one-wide allocas and recomputes "contiguous" ones from the work-item index instead of spilling them ([`SubCfgFormation.cpp`][acpp-subcfg]), guided by a uniformity analysis "adapted from the RV Project" ([`UniformityAnalysis.cpp`][acpp-uniformity]). The work-item loops are then tagged `llvm.loop.vectorize.enable` (and scalable vectorization where available, [`LoopsParallelMarker.cpp`][acpp-parallel-marker]) so that **LLVM's ordinary loop vectorizer** does the SIMD work. The host sub-group has size 1 and the sub-group barrier is a fence.
3. **Whole-function vectorization (DPC++ `native_cpu`).** DPC++'s Native CPU pipeline uses Codeplay's **Vecz**, "based on the automatic whole function vectorization research by Ralf Karrenberg", enabled with `-cl-wfv={always|auto}` ([`SYCLNativeCPUVecz.md`][dpcpp-vecz]). `WorkItemLoopsPass` splits the kernel into "barrier regions", passes live values between them in a struct, rematerializes `get_global_id` in each region, and runs the vectorized kernel over the largest multiple of the vector width with "the original scalar kernel … called on the up to 3 remaining work-items" — the _peel_ iterations ([`SYCLNativeCPUPipeline.md`][dpcpp-ncpu-pipeline]). Crucially, Vecz supplies the vector definitions of the sub-group builtins, so "any target running Vecz … will be able to support sub-groups of a larger size than 1"; without it the builtins are defined for sub-group size 1 ([`SYCLNativeCPUPipelinePasses.md` § Sub-groups][dpcpp-ncpu-passes]). Barriers must carry unique IDs before vectorization because "vectorization can considerably affect control flow, so the ordering of the barriers in the function may change".

The contrast between 2 and 3 is the finding: a **sub-group equals a SIMD vector** only when the vectorizer owns the kernel (Vecz); with loop vectorization over work-items (CBS), sub-group operations cannot see neighbouring lanes and so collapse to size 1. A shader CPU executor that must run `subgroupShuffle`, `subgroupAdd` or quad derivatives faithfully needs the Vecz shape, not the CBS shape. See [ISPC][ispc] for the language-level form of the same mapping.

---

## Lessons for sparkles:shaders

- **Adopt: reachability-closed device code with a short normative restriction list.** SYCL's list (no virtual calls, function pointers, RTTI, exceptions, recursion, allocation, mutable statics or TLS) maps one-to-one onto a D `@compute` module; state it as a checked rule in the [spec][sparkles-spec] with a diagnostic per item, and keep the per-module `CompileFor` marking rather than SYCL's implicit reachability, which makes "is this function device code?" depend on the whole program.
- **Adopt: AdaptiveCpp's IR-constant trick for host/device builtin selection.** One D source compiled once, with builtins branching on a constant that the pipeline folds per target, is how sparkles can keep one `math.d` for the host reference and the device without `version` blocks per backend.
- **Match: "group functions must be encountered in converged control flow"** as the contract for barriers and subgroup operations, worded so the CPU executor's barrier-region splitting is legal by construction; test it with kernels whose barrier sits under uniform and non-uniform branches.
- **Match: specify the CPU executor as two devices.** SYCL dropped its host device because nobody could say whether it was an emulator or a fast CPU target. sparkles should name both: a scalar reference with sub-group size 1 _and_ an option for larger sizes, and an SPMD-on-SIMD executor whose sub-group size is the vector width, with the conformance corpus run against both.
- **Adopt the Vecz/`WorkItemLoopsPass` shape, not CBS, for SPMD-on-SIMD.** Barrier regions plus live-value structs plus a whole-function vectorizer with a scalar peel kernel is the layout that also gives real subgroup and quad semantics; loop-vectorizing work-item loops cannot.
- **Avoid: `vec`/`marray` duality and size-3 padding by fiat.** One project-wide `Vector!(T, N)` with explicit packed vs. std140/std430 layout views beats SYCL's two types and its "a 3-vector is a 4-vector" rule, which leaks into host arrays.
- **Avoid: reaching Vulkan through OpenCL-flavoured IR.** AdaptiveCpp's `clspv` route works but loses `marray` (odd-width integers), float atomics and pointer stores; sparkles' direct LLVM SPIR-V backend route with Logical addressing for shaders and `PhysicalStorageBuffer64` only where asked is the better-scoped choice.

## Strengths

- Pure ISO C++ with templates, lambdas and the standard value types in kernels; no language extension needed to write one.
- Multiple conforming, independently built compilers prove the language/implementation boundary is real.
- Both memory models — DAG-scheduled buffers/accessors and raw-pointer USM — in one API.
- A first-class, portable group-algorithm library and `reduction` object above raw sub-group intrinsics.
- The most mature CPU execution research of any GPU language: CBS, Vecz, work-item loops, fibers, scoped parallelism.
- AdaptiveCpp SSCP: parse once, embed generic IR, JIT per device — one binary runs on NVIDIA, AMD, Intel, the host and (experimentally) Vulkan and Metal.

## Weaknesses

- Compute only: no graphics stages, derivatives, helper invocations, interpolation or sampler-feedback vocabulary.
- Kernel naming and device-copyability are compiler/runtime plumbing that leaks into user code (named lambdas, forward-declarable types).
- `vec` vs `marray`, deprecated accessor targets, deprecated atomics and hierarchical parallelism show accumulated API debt.
- The host device was removed rather than defined, so "runs on the CPU" means different things per implementation (sub-group size 1 in AdaptiveCpp, vector-width sub-groups only with Vecz).
- Vulkan support exists only as an experimental OpenCL-to-Vulkan bridge with documented holes.
- Specialization constants may trigger recompilation on every new value.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                            | Trade-off                                                                                                       |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| Kernels discovered by reachability from `parallel_for`          | No `__device__` annotations; generic code works unchanged                            | Device-ness is a whole-program property; errors surface only when a kernel is compiled for a device             |
| Address spaces not in the C++ type; inferred                    | Plain `T*` and references in device code                                             | Targets without a generic address space (Vulkan) need inference or a reduced feature set                        |
| Buffers/accessors plus USM                                      | Automatic DAG and transfers for some code, raw pointers for the rest                 | Two models to learn and implement; accessor API has deprecated layers                                           |
| `vec` (1–16, swizzles, size-3 = size-4) beside `marray`         | OpenCL interop and SIMD semantics vs plain math arrays                               | Two vector types; padding rule leaks to host layout                                                             |
| Host device removed in SYCL 2020                                | Could not agree on emulator vs optimized CPU semantics                               | No portable definition of CPU execution; implementations diverge on sub-group size and barrier cost             |
| AdaptiveCpp: single pass, embedded generic IR, runtime lowering | Parse once, portable binaries, JIT specialization (kernel fusion, known group sizes) | Runtime compile latency; a JIT and backend toolchains ship with the application                                 |
| DPC++ Native CPU: whole-function vectorizer + work-item loops   | Real sub-groups on SIMD lanes; barriers handled by region splitting                  | Requires full inlining of barrier-containing functions and unique barrier IDs before vectorization              |
| AdaptiveCpp CBS: sub-CFGs + LLVM loop vectorizer                | Reuses the stock vectorizer; works with any LLVM CPU target                          | Sub-group size fixed at 1 on the host; vectorization can fail silently (warnings are redirected to `/dev/null`) |

---

## Sources

- [SYCL-Docs repository][spec-repo] (pinned `e468723a8b`), and the [SYCL 2020 HTML specification][spec-html]
- [`adoc/chapters/introduction.adoc` — single-source framing, backend neutrality][intro]
- [`adoc/chapters/device_compiler.adoc` — kernel discovery, naming, restrictions, address spaces, attributes][devcomp]
- [`adoc/chapters/architecture.adoc` — forward progress, device copyable][arch]
- [`adoc/chapters/programming_interface.adoc` — `sub_group`, USM, `vec`, `marray`, group functions, specialization constants][pi]
- [`adoc/chapters/what_changed.adoc` — host device removal, `marray`, generic address space][what-changed]
- [`adoc/chapters/host_backend.adoc` — the unbuilt host-backend appendix and its open question][host-backend]
- [`adoc/chapters/feature_sets.adoc` — full vs reduced feature set][feature-sets]
- Spec samples: [`anatomy.cpp`][anatomy], [`usm_shared.cpp`][usm-shared], [`parallelforbarrier.cpp`][pfbarrier], [`lambdaNameExamples.cpp`][lambda-names], [`swizzle-example.cpp`][swizzle], [`usingSpecConstants.cpp`][spec-const]
- [AdaptiveCpp repository][acpp-repo] (pinned `31db2e8390`): [`doc/compilation.md`][acpp-compilation], [`doc/generic-sscp.md`][acpp-sscp], [`doc/install-vulkan.md`][acpp-vulkan], [`doc/scoped-parallelism.md`][acpp-scoped], [`doc/limitations.md`][acpp-limits]
- AdaptiveCpp compiler: [`llvm-to-backend/`][acpp-l2b], [`spirv/LLVMToSpirv.cpp`][acpp-l2spirv], [`host/LLVMToHost.cpp`][acpp-l2host], [`cbs/PipelineBuilder.cpp`][acpp-cbs-pipeline], [`cbs/SubCfgFormation.cpp`][acpp-subcfg], [`cbs/UniformityAnalysis.cpp`][acpp-uniformity], [`cbs/LoopsParallelMarker.cpp`][acpp-parallel-marker], [`libkernel/sscp/host/subgroup.cpp`][acpp-host-subgroup]
- [intel/llvm (DPC++)][dpcpp-repo] (pinned `4a08d0453c`): [`CompilerAndRuntimeDesign.md`][dpcpp-design], [`UsersManual.md`][dpcpp-manual], [`SYCLNativeCPU.md`][dpcpp-ncpu], [`SYCLNativeCPUPipeline.md`][dpcpp-ncpu-pipeline], [`SYCLNativeCPUPipelinePasses.md`][dpcpp-ncpu-passes], [`SYCLNativeCPUVecz.md`][dpcpp-vecz], [`VirtualFunctions.md`][dpcpp-virtual]
- Joachim Meyer, [master thesis on hipSYCL CPU `nd_range` compilation][meyer-thesis]; Karrenberg & Hack, [_Improving performance of OpenCL on CPUs_ (CC 2012)][karrenberg-cc12]
- Related: [CUDA and HIP][cuda-hip] · [ISPC][ispc] · [Julia][julia] · [dcompute][dcompute] · [LLVM SPIR-V backend][llvm-spirv] · [Concepts][concepts] · [Comparison][comparison] · [Catalog][index]

<!-- References -->

[spec-repo]: https://github.com/KhronosGroup/SYCL-Docs/tree/e468723a8bb74247c1d89290704239189cceb82e
[spec-html]: https://registry.khronos.org/SYCL/specs/sycl-2020/html/sycl-2020.html
[lic]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/LICENSE.txt
[intro]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/adoc/chapters/introduction.adoc
[devcomp]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/adoc/chapters/device_compiler.adoc
[arch]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/adoc/chapters/architecture.adoc
[pi]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/adoc/chapters/programming_interface.adoc
[what-changed]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/adoc/chapters/what_changed.adoc
[host-backend]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/adoc/chapters/host_backend.adoc
[feature-sets]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/adoc/chapters/feature_sets.adoc
[anatomy]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/adoc/code/anatomy.cpp
[usm-shared]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/adoc/code/usm_shared.cpp
[pfbarrier]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/adoc/code/parallelforbarrier.cpp
[lambda-names]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/adoc/code/lambdaNameExamples.cpp
[swizzle]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/adoc/code/swizzle-example.cpp
[spec-const]: https://github.com/KhronosGroup/SYCL-Docs/blob/e468723a8bb74247c1d89290704239189cceb82e/adoc/code/usingSpecConstants.cpp
[acpp-repo]: https://github.com/AdaptiveCpp/AdaptiveCpp/tree/31db2e83903c1db9f50b03b620eb0a09224cd0eb
[acpp-doc]: https://github.com/AdaptiveCpp/AdaptiveCpp/blob/31db2e83903c1db9f50b03b620eb0a09224cd0eb/doc/index.md
[acpp-compilation]: https://github.com/AdaptiveCpp/AdaptiveCpp/blob/31db2e83903c1db9f50b03b620eb0a09224cd0eb/doc/compilation.md
[acpp-sscp]: https://github.com/AdaptiveCpp/AdaptiveCpp/blob/31db2e83903c1db9f50b03b620eb0a09224cd0eb/doc/generic-sscp.md
[acpp-vulkan]: https://github.com/AdaptiveCpp/AdaptiveCpp/blob/31db2e83903c1db9f50b03b620eb0a09224cd0eb/doc/install-vulkan.md
[acpp-scoped]: https://github.com/AdaptiveCpp/AdaptiveCpp/blob/31db2e83903c1db9f50b03b620eb0a09224cd0eb/doc/scoped-parallelism.md
[acpp-limits]: https://github.com/AdaptiveCpp/AdaptiveCpp/blob/31db2e83903c1db9f50b03b620eb0a09224cd0eb/doc/limitations.md
[acpp-l2b]: https://github.com/AdaptiveCpp/AdaptiveCpp/tree/31db2e83903c1db9f50b03b620eb0a09224cd0eb/src/compiler/llvm-to-backend
[acpp-l2spirv]: https://github.com/AdaptiveCpp/AdaptiveCpp/blob/31db2e83903c1db9f50b03b620eb0a09224cd0eb/src/compiler/llvm-to-backend/spirv/LLVMToSpirv.cpp
[acpp-l2host]: https://github.com/AdaptiveCpp/AdaptiveCpp/blob/31db2e83903c1db9f50b03b620eb0a09224cd0eb/src/compiler/llvm-to-backend/host/LLVMToHost.cpp
[acpp-cbs-pipeline]: https://github.com/AdaptiveCpp/AdaptiveCpp/blob/31db2e83903c1db9f50b03b620eb0a09224cd0eb/src/compiler/cbs/PipelineBuilder.cpp
[acpp-subcfg]: https://github.com/AdaptiveCpp/AdaptiveCpp/blob/31db2e83903c1db9f50b03b620eb0a09224cd0eb/src/compiler/cbs/SubCfgFormation.cpp
[acpp-uniformity]: https://github.com/AdaptiveCpp/AdaptiveCpp/blob/31db2e83903c1db9f50b03b620eb0a09224cd0eb/src/compiler/cbs/UniformityAnalysis.cpp
[acpp-parallel-marker]: https://github.com/AdaptiveCpp/AdaptiveCpp/blob/31db2e83903c1db9f50b03b620eb0a09224cd0eb/src/compiler/cbs/LoopsParallelMarker.cpp
[acpp-host-subgroup]: https://github.com/AdaptiveCpp/AdaptiveCpp/blob/31db2e83903c1db9f50b03b620eb0a09224cd0eb/src/libkernel/sscp/host/subgroup.cpp
[clspv]: https://github.com/google/clspv/tree/3d017c6d751cdabed1a5051b20c6bf5f71e8fd32
[dpcpp-repo]: https://github.com/intel/llvm/tree/4a08d0453c6b37a6e1eb5f52933f79c734b1149c
[dpcpp-design]: https://github.com/intel/llvm/blob/4a08d0453c6b37a6e1eb5f52933f79c734b1149c/sycl/doc/design/CompilerAndRuntimeDesign.md
[dpcpp-manual]: https://github.com/intel/llvm/blob/4a08d0453c6b37a6e1eb5f52933f79c734b1149c/sycl/doc/UsersManual.md
[dpcpp-ncpu]: https://github.com/intel/llvm/blob/4a08d0453c6b37a6e1eb5f52933f79c734b1149c/sycl/doc/design/SYCLNativeCPU.md
[dpcpp-ncpu-pipeline]: https://github.com/intel/llvm/blob/4a08d0453c6b37a6e1eb5f52933f79c734b1149c/sycl/doc/design/SYCLNativeCPUPipeline.md
[dpcpp-ncpu-passes]: https://github.com/intel/llvm/blob/4a08d0453c6b37a6e1eb5f52933f79c734b1149c/sycl/doc/design/SYCLNativeCPUPipelinePasses.md
[dpcpp-vecz]: https://github.com/intel/llvm/blob/4a08d0453c6b37a6e1eb5f52933f79c734b1149c/sycl/doc/design/SYCLNativeCPUVecz.md
[dpcpp-virtual]: https://github.com/intel/llvm/blob/4a08d0453c6b37a6e1eb5f52933f79c734b1149c/sycl/doc/design/VirtualFunctions.md
[meyer-thesis]: https://joameyer.de/hipsycl/Thesis_JoachimMeyer.pdf
[karrenberg-cc12]: https://link.springer.com/content/pdf/10.1007/978-3-642-28652-0_1.pdf
[sparkles-spec]: ../../specs/shaders/SPEC.md
[cuda-hip]: ./cuda-hip.md
[ispc]: ./ispc.md
[julia]: ./julia.md
[dcompute]: ./dcompute.md
[llvm-spirv]: ./llvm-spirv-backend.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
