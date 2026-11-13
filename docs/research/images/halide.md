# Halide (C++)

An image and array processing language embedded in C++ that keeps the algorithm, a set of pure functions over an infinite integer grid, apart from its schedule, which decides loop order, tiling, vectorisation, parallelism, storage and GPU mapping, and lowers both through LLVM to x86, ARM, WebAssembly and CUDA, and through source or SPIR-V emitters to Metal, D3D12, OpenCL, Vulkan and WebGPU.

| Field         | Value                                                                                                                       |
| ------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Language      | C++17 (compiler and API), freestanding C++ runtime, Python bindings; version `22.0.0` in `CMakeLists.txt`; LLVM 21 or newer |
| License       | MIT ([`LICENSE.txt`][license]); `apps/bgu` is Apache-2.0                                                                    |
| Repository    | [halide/Halide][repo]                                                                                                       |
| Revision read | `85f16183923fcec94c2fb6e756d98e6831ea1524` (October 27, 2026)                                                               |
| Documentation | [halide-lang.org][site] · [API reference][api] · [tutorials][tutorials] · [`doc/`][doc-dir] in the tree                     |
| Category      | Generic libraries: image DSL, scheduling compiler, raw strided buffer ABI                                                   |
| Tier          | A                                                                                                                           |
| Last reviewed | November 7, 2026                                                                                                            |

> [!NOTE]
> Everything below was read from the source at the pinned revision with `git show`, unless it is marked
> **verified**. Verified claims were demonstrated by compiling and running a probe under `/tmp/halide-abi`
> on x86_64 Linux: a C++ program built with GCC 14.3 against the pinned `HalideRuntime.h` and
> `HalideBuffer.h`, and a D mirror of the buffer ABI built with LDC 1.43 under `-betterC`. Halide itself
> (which needs LLVM) was not built, so no pipeline was compiled or timed, and this page states no
> performance number of its own.

---

## Overview

### What it solves

An image pipeline is a chain of cheap stages (a blur, a colour transform, a resample, a pyramid level), and its speed depends mostly on how the stages are interleaved in memory, not on the inner-loop arithmetic. Writing the fused, tiled, vectorised, multithreaded form by hand ties the arithmetic to one machine: changing a tile size or moving a stage onto the GPU means rewriting the loops. Halide makes the stage definitions and their arrangement two separate programs. The [paper thread][p-dsl] covers the theory (Ragan-Kelley et al. 2012, 2013, 2018); this page covers how the pinned source implements it.

The README states the scope and the embedding ([`README.md`][readme]):

> _"Halide is a programming language designed to make it easier to write high-performance image and array processing code on modern machines."_ … _"Rather than being a standalone programming language, Halide is embedded in C++. This means you write C++ code that builds an in-memory representation of a Halide pipeline using Halide's C++ API. You can then compile this representation to an object file, or JIT-compile it and run it in the same process."_

Three artefacts make up a Halide deployment, and each is a separate lesson for Sparkles:

1. **The front end and compiler** (`libHalide`): `Func`, `Var`, `RDom`, `Expr`, the scheduling directives, about sixty announced lowering steps in `lower_impl` (`src/Lower.cpp`), and code generators for each target.
2. **The raw buffer ABI**: `halide_buffer_t` and `halide_dimension_t` in `src/runtime/HalideRuntime.h`, a C struct that every compiled pipeline takes and returns, with a device handle and two dirty bits.
3. **The runtime**: a freestanding C++ library (allocator, thread pool, error reporting, CPU feature probing, one device interface per GPU API) that is linked into every AOT pipeline or the JIT.

### Design philosophy

The tutorial puts the central trade-off in plain words ([`tutorial/lesson_08_scheduling_2.cpp`][lesson8]):

> _"In any given situation the correct choice can be difficult to make. If you're memory-bandwidth limited, or don't have much memory (e.g. because you're running on an old cell-phone), then it can make sense to do redundant math. On the other hand, sin is expensive, so if you're compute-limited then fewer calls to sin will make your program faster. Adding vectorization or multi-core parallelism tilts the scales in favor of doing redundant work, because firing up multiple cpu cores increases the amount of math you can do per second, but doesn't increase your system memory bandwidth or capacity."_

The consequences visible in the source:

- **The schedule never changes the result.** Every directive is a rewrite of loop structure, storage or placement; the algorithm (`f(x, y) = …`) is the only place values are defined. Tests rely on this: `simd_op_check` compiles the same expression scalar and vectorised and compares them.
- **Bounds are inferred, not written.** Intermediate images have no declared size; lowering derives the region each stage needs from its consumers, so the user writes no edge loops and no index checks.
- **The schedule is target-dependent, the algorithm is not.** The blur generator in `apps/blur` holds one algorithm and three schedules selected by `get_target()`: GPU, Hexagon and CPU.
- **Everything compiles ahead of time if wanted.** A `Generator` emits an object file, a C header and a runtime; the deployed program needs no compiler, and the README notes that Python deployments of precompiled AOT pipelines can install only the `halide-runtime` distribution, "avoiding the compiler and LLVM entirely".

---

## How it works

### Algorithm, schedule and the blur

`apps/blur/halide_blur_generator.cpp` is the canonical example. The algorithm is two lines, and the schedule branches on the target ([source][blur]):

```cpp
// apps/blur/halide_blur_generator.cpp (abridged: the GPU "Slide" case and the CPU case)
// The algorithm
blur_x(x, y) = (input(x, y) + input(x + 1, y) + input(x + 2, y)) / 3;
blur_y(x, y) = (blur_x(x, y) + blur_x(x, y + 1) + blur_x(x, y + 2)) / 3;

// How to schedule it
if (get_target().has_gpu_feature()) {
    blur_y
        .split(y, y, y_inner, tile_y)
        .reorder(y_inner, x)
        .unroll(y_inner)
        .gpu_tile(x, y, xi, yi, tile_x, 1);
} else {
    // CPU schedule.
    blur_y
        .split(y, y, yi, 32)
        .parallel(y)
        .vectorize(x, 16);
    blur_x
        .store_at(blur_y, y)
        .compute_at(blur_y, x)
        .vectorize(x, 16);
}
```

The vocabulary, read from `src/Func.h` ([`Stage` directives][func-stage], [GPU directives][func-gpu]):

| Directive                                     | What it rewrites                                                                                                   |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `split(x, xo, xi, factor, tail)`              | one loop into an outer and an inner loop of extent `factor`; `tail` is a `TailStrategy`                            |
| `fuse`, `reorder`, `tile`                     | merge two loops; permute the nest; `tile` is two splits plus a reorder                                             |
| `vectorize(x, n)`, `unroll(x, n)`             | an inner loop of constant extent into vector lanes or straight-line code                                           |
| `parallel(x)`                                 | a loop into `halide_do_par_for` tasks on the runtime thread pool                                                   |
| `compute_at(f, x)`, `compute_root`            | the loop level at which a producer is computed: inside a consumer's loop over `x`, or once for the whole output    |
| `store_at(f, x)`, `hoist_storage`             | the loop level at which the producer's buffer is allocated, which may be outside where it is computed              |
| `compute_inline` (the default)                | substitute the producer's expression into each use                                                                 |
| `gpu_blocks`, `gpu_threads`, `gpu_tile`       | loops onto the workgroup grid and the invocations within a workgroup, for a `DeviceAPI`                            |
| `store_in(MemoryType)`                        | `Heap`, `Stack`, `Register`, `GPUShared`, `GPUTexture`, `LockedCache`, `VTCM`, `AMXTile`, `GPUSharedAsync`         |
| `bound`, `align_bounds`, `specialize`         | constrain an output's region; round it to a modulus; compile a second copy of the stage under a run-time condition |
| `rfactor`, `atomic`                           | turn an associative reduction over an `RDom` into a parallel one                                                   |
| `async`, `ring_buffer`, `prefetch`, `memoize` | run a producer on another thread; give it multiple buffers; prefetch an input; cache a result between calls        |

`compute_at` and `store_at` are the two knobs of the 2013 paper. The header documents them with the C code they produce. For `g.compute_at(f, x).store_at(f, y)` on a 2×2 stencil, Halide notices that each `x` step needs one new column and folds the storage ([`Func.h`][func-store-at]):

> _"Halide has detected that it's possible to use a circular buffer to represent g, and has reduced all accesses to g modulo 2 in the x dimension. This optimization only triggers if the for loop over x is serial, and if halide can statically determine some power of two large enough to cover the range needed."_

The blur's CPU schedule uses exactly this: `blur_x` is stored per strip of `y` and computed per vector of `x`, so the three-row window of `blur_x` lives in a folded buffer (the source comment: "Halide will store `blur_x` in a circular buffer so its results can be re-used").

### Tails

A `split` by a factor that does not divide the extent needs a policy. `TailStrategy` in `src/Schedule.h` lists eight: `RoundUp`, `GuardWithIf`, `PredicateLoads`, `PredicateStores`, `ShiftInwards`, `ShiftInwardsAndBlend`, `RoundUpAndBlend` and `Auto`, plus a deprecated `Predicate` alias of `GuardWithIf` ([source][sched-tail]). `ShiftInwards`, the default for pure definitions, re-evaluates a few points near the end so the inner loop always runs a full vector:

> _"Like RoundUp, it supports vectorization well, because the inner loop is always a fixed size with no data-dependent branching. … this strategy only requires that the input/output extent be at least the split factor, instead of a multiple of the split factor as with RoundUp."_

### Reductions and boundaries

A pure `Func` has one definition; a reduction adds update definitions over an `RDom`, a bounded multi-dimensional domain, executed in order after the initial value ([`RDom.h`][rdom]). Histograms, integral images and convolutions with explicit loops are written this way. Edges are explicit wrapper functions in `src/BoundaryConditions.h` (`constant_exterior`, `repeat_edge`, `repeat_image`, `mirror_image`, `mirror_interior`) ([source][bc]): the algorithm reads `clamped(x - 1, y)` instead of `input(x - 1, y)` and the wrapper owns the finite domain.

### Lowering and bounds inference

`lower()` in `src/Lower.cpp` calls `lower_impl`, which runs the pipeline through a fixed sequence of passes, each announced with `debug(1)` ([source][lower]). The relevant order is: create loop nests from the schedule; add parameter checks; compute value bounds of each function; clamp unsafe data-dependent accesses; computation bounds inference; sliding window; allocation bounds inference; **add checks for images**; storage folding; storage flattening; inject host/device copies; unroll; vectorise; partition loops for boundary conditions; and strip asserts if the target asks, which is the last pass before any custom lowering passes and the split into host and device code (Hexagon and GPU offload, parallel tasks).

Bounds inference (`src/BoundsInference.cpp`) walks from the outputs back to the inputs and, for every producer at its `compute_at` level, defines symbolic `min` and `extent` variables from the interval of coordinates its consumers read. The 2013 paper calls the model axis-aligned boxes, not polytopes. `AddImageChecks` then turns the inferred region of every _input and output buffer_ into one assertion per dimension, placed at the top of the pipeline ([source][aic-oob]):

```cpp
// src/AddImageChecks.cpp (abridged)
Expr oob_condition = actual_min <= min_required_var && actual_max >= max_required;
Expr oob_error = Call::make(Int(32), "halide_error_access_out_of_bounds",
                            {error_name, j, min_required_var, max_required, actual_min, actual_max},
                            Call::Extern);
asserts_required.push_back(AssertStmt::make(oob_condition, oob_error));
```

This is how Halide removes per-pixel bounds checks: the loop body indexes with no checks at all, because a single per-dimension comparison before the first loop has proved that every access the schedule will make lands inside the buffer the caller passed. Intermediate buffers need no check, since Halide sized them from the same intervals. An access whose interval cannot be bounded is a compile-time error, not a run-time check ([source][aic-unbounded]):

```cpp
// src/AddImageChecks.cpp
user_error << "Buffer " << name
           << " may be accessed in an unbounded way in dimension "
           << j << "\n";
```

The same pass also emits the size checks (per dimension, `extent × stride` within `maximum_buffer_size()`; the running product of extents within the same limit; no negative extents) and, when the target has no device support, an assertion that no input is `device_dirty` ([sizes][aic-size], [dirty][aic-dirty]).

**Bounds queries.** A compiled pipeline doubles as a function that reports what it needs. If a buffer argument has `host == nullptr && device == 0` ([`_halide_buffer_is_bounds_query`][bq]), the pipeline writes the required region into that buffer's `dim` array and returns without computing anything. A caller can therefore ask "which input rectangle do you need for this output rectangle?" before allocating. `Target::NoBoundsQuery` removes the mode.

### Generators, AOT and JIT

A `Generator` is a class with typed `Input`, `Output` and `GeneratorParam` members and `generate()` / `schedule()` methods ([`Generator.h`][gen]); `HALIDE_REGISTER_GENERATOR` registers it, and the `GenGen` driver compiles it for a target string such as `x86-64-linux-avx2` or `host-vulkan-vk_int8-vk_v13`. The output is an object or static library with a C entry point taking `halide_buffer_t *` per buffer and returning an `int` error code, a header, and optionally a standalone runtime. `RunGen` wraps any generator into a command-line benchmark ([`doc/RunGen.md`][doc-rungen]). The same `Func` graph can instead be JIT-compiled in-process with `Func::realize`.

**Multi-target dispatch** is AOT-only. `compile_multitarget` compiles one sub-function per target and a wrapper that asks `halide_can_use_target_features` at run time which one to call ([`Module.cpp`][module-mt]):

> _"The final target in the list is considered "baseline", and is used for (e.g.) the runtime and shared code."_

`halide_can_use_target_features` returns one of four values, `never`, `always`, `not_right_now` and `for_the_moment`, so a decision can be cached permanently or re-asked on the next call; an application may override it ([`HalideRuntime.h`][rt-canuse]).

### Targets and features

`halide_target_feature_t` in `HalideRuntime.h` is the flat list of what a target string can name ([source][rt-features]): `sse41`, `avx`, `avx2`, `avx512` with per-family sets (`avx512_skylake`, `avx512_cannonlake`, `avx512_zen4`, `avx512_zen5`, `avx512_sapphirerapids`), `sve`, `sve2`, `no_neon` for 32-bit ARM, and per-API device features. Two details matter to Sparkles.

**x86 detection checks the OS.** `src/runtime/x86_cpu_detect.h` is shared by the compiler (to compute the host target) and the freestanding runtime (to answer `halide_can_use_target_features`), and it tests XCR0 before trusting a CPUID bit ([source][x86-os]):

```cpp
// src/runtime/x86_cpu_detect.h (abridged)
// Check OS support for AVX/AVX-512 state saving via XSAVE. Even if the CPU
// supports these features, the OS must enable the corresponding state
// components in XCR0 or use will fault.
const uint64_t xcr0 = ops.xgetbv(0);
os_avx = (xcr0 & 0x6) == 0x6;                   // XMM (bit 1) + YMM (bit 2)
os_avx512 = os_avx && ((xcr0 & 0xE0) == 0xE0);  // opmask (5) + ZMM_Hi256 (6) + Hi16_ZMM (7)
```

The header injects `cpuid` and `xgetbv` through an "ops" object so the decision logic "is testable against recorded CPU state from machines we don't have" ([source][x86-detect]).

**SVE2 is compiled for a fixed vector length.** The ARM back end generates scalable vectors only for `sve2` (plain `sve` draws the warning "Halide does not support SVE for now. Use SVE2 if your target device supports it."), and refuses SVE2 without a vector length ([`CodeGen_ARM.cpp`][arm-sve]):

> "For SVE/SVE2 support, `Target::vector_bits` must be set. For generator target strings, add "`vector_bits_<bits>`"."

Host detection fills `vector_bits` from the running machine's SVE length ([`Target.cpp`][target-sve]). A Halide SVE2 binary is therefore vector-length-specific, not vector-length-agnostic.

### The Vulkan back end

`doc/Vulkan.md` describes the back end as "considered _BETA_ quality at this stage" ([source][doc-vk-status]). `src/CodeGen_Vulkan_Dev.cpp` (3,330 lines) emits SPIR-V directly, without GLSL and without `glslang`, using the `GLCompute` execution model, the `Logical` addressing model and the `GLSL450` memory model ([source][cvk-header]). What it emits:

- **Buffers are storage buffers, not images.** Each `halide_buffer_t` argument becomes a runtime array in a `BufferBlock` struct with an `ArrayStride` decoration, bound at its own binding in the entry point's descriptor set ([source][cvk-buf]). A grep of the file for `OpImage` finds nothing: strided indexing is arithmetic on a flat array, and there are no samplers or storage images.
- **Scalars travel in one uniform block** (`param_pack`), followed by one element offset per buffer (the code comment: `These offsets are stored *after* all scalar args in the uniform struct`). The runtime fills each with the region's `indexing.offset`, whose declaration says it is "used to adjust indices in compute shader to avoid alignment constraints for arbitrary crops" ([source][vk-crop-offset]), so a device crop at any element offset binds the parent allocation without a copy.
- **Workgroup size** is a static `LocalSize` from the `gpu_threads` extents, or, if the extents are not constant, three specialization constants, which needs Vulkan 1.3 ([source][cvk-wgs]): _"Vulkan: Dynamic workgroup sizes require Vulkan v1.3+ support!"_
- **Shared memory** (`MemoryType::GPUShared`) becomes `Workgroup` storage-class arrays; one of them may be dynamically sized through a specialization constant.
- **A sidecar header** precedes the SPIR-V words and lists, per entry point, the uniform and storage buffer counts, the specialization constants and the shared-memory allocations, so the runtime can build descriptor set layouts without reflecting the module ([source][cvk-header]).
- **Optional types are opt-in features**: `vk_int8`, `vk_int16`, `vk_int64`, `vk_float16`, `vk_float64`, plus `vk_v10`, `vk_v12`, `vk_v13` ([`doc/Vulkan.md`][doc-vk-features]): _"Note that 32-bit integer and floating-point types are always available. All other optional device features are off by default"_. Booleans in parameters are widened to `UInt(32)` because `OpTypeBool` has no storage representation ([source][cvk-bool]).

The runtime side, `src/runtime/vulkan.cpp`, is synchronous. `halide_vulkan_run` records one command buffer with one `vkCmdDispatch`, submits it and calls `vkQueueWaitIdle` before returning ([source][vk-run]); `halide_vulkan_copy_to_device` maps a host-visible, uncached-coherent staging region, copies the strided host data into it, records `vkCmdCopyBuffer`, submits and waits again ([source][vk-copy]). A host application can supply its own `VkInstance`, `VkDevice`, `VkPhysicalDevice` and `VkQueue` by overriding `halide_vulkan_acquire_context` / `halide_vulkan_release_context` (the allocator out-parameter is Halide's internal `halide_vulkan_memory_allocator`), and its own `VkAllocationCallbacks` through `halide_vulkan_set_allocation_callbacks` ([`HalideRuntimeVulkan.h`][vk-api]), and can wrap an existing `VkBuffer` through `halide_device_wrap_native`, which dispatches to `halide_vulkan_wrap_vk_buffer` ([source][vk-wrap]). That function is not declared in the public Vulkan header, unlike `halide_cuda_wrap_device_ptr` and `halide_metal_wrap_buffer`.

The block allocator's defaults in `src/runtime/vulkan_memory.h` are `minimum_block_size = 4 * 1024` and `nearest_multiple = 32` ([source][vk-mem]), while `doc/Vulkan.md` says of the minimum block size "Default is 32MB" ([source][doc-vk-alloc]). The documentation and the code disagree at this revision.

### The autoschedulers

The four autoschedulers are plugins: each registers itself through `REGISTER_AUTOSCHEDULER(NAME)`, which calls `Pipeline::add_autoscheduler` from a static constructor ([`HalidePlugin.h`][plugin]). All of them need size estimates on the pipeline's outputs (`set_estimate`), because their cost models reason about concrete extents.

| Directory                          | Paper                            | Method in the source                                                                                                                                     |
| ---------------------------------- | -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/autoschedulers/mullapudi2016` | Mullapudi et al. 2016            | greedy grouping over bounds analysis, a cost model of arithmetic and loads; `parallelism`, `last_level_cache_size`, `balance` parameters ([source][m16]) |
| `src/autoschedulers/li2018`        | Li et al. 2018 (gradient Halide) | "a conservative autoscheduler that `compute_root` most Funcs except for the trivial ones (think of it as a -O1 optimizer for Halide)" ([README][li18])   |
| `src/autoschedulers/adams2019`     | Adams et al. 2019                | coarse-to-fine beam search over `LoopNest` trees, a learned cost model with `baseline.weights` and a retraining loop ([source][a19])                     |
| `src/autoschedulers/anderson2021`  | Anderson et al. 2021             | the same beam-search structure extended with `GPULoopInfo`, `GPUMemInfo`, `SearchSpace` and `Tiling` for block/thread mapping ([source][a21])            |

Two details in the source qualify the paper claims. Mullapudi2016's GPU mode is behind an opt-in parameter: `is_gpu_schedule = target.has_gpu_feature() && experimental_gpu_schedule`, with the defaults `parallelism = 128`, `last_level_cache_size = 48 * 1024` and `balance = 20` for GPUs ([source][m16]). And the Li2018 README still says it is "currently the only autoscheduler that generates GPU schedules", which `anderson2021` and the Mullapudi2016 `experimental_gpu_schedule` flag contradict; the README is stale. The README's own table reports the gradient autoscheduler slower than the manual schedules on most of its apps (for example `local_laplacian` at 42.29 ms manual against 128.31 ms on the CPU); those numbers are the README's, not measured here.

---

## Analysis

### 1. Pixel and memory model

The model is one struct with no notion of pixel, channel or plane ([`HalideRuntime.h`][rt-buf]):

```c
// src/runtime/HalideRuntime.h (fields only)
typedef struct halide_dimension_t {
    int32_t min, extent, stride;
    uint32_t flags;               // "None are defined yet"
} halide_dimension_t;

typedef struct halide_buffer_t {
    uint64_t device;                                   // device handle
    const struct halide_device_interface_t *device_interface;
    uint8_t *host;                                     // address of the min coordinate
    uint64_t flags;                                    // host_dirty = 1, device_dirty = 2
    struct halide_type_t type;                         // code, bits, info
    int32_t dimensions;
    halide_dimension_t *dim;                           // "Halide does not own this array"
    void *padding;
} halide_buffer_t;
```

**Verified** (C++ probe): `sizeof(halide_buffer_t)` is 56, `halide_dimension_t` 16 and `halide_type_t` 4 on x86_64 Linux, with `host` at offset 16, `type` at 32 and `dim` at 40. The D mirror reproduced the same sizes and offsets in `static assert`s under `-betterC`.

The defining choices:

- **Strides are in elements, signed, one per dimension, in any order.** Dimension 0 is innermost by default, but interleaved versus planar is only a stride permutation. **Verified**: `Buffer<uint8_t>::make_interleaved(4, 3, 3)` produced strides `3, 12, 1` for `x, y, c`, and `Buffer<uint8_t>(4, 3, 3)` produced the planar `1, 4, 12`. A negative stride flips an axis without a copy; **verified** that a five-element view with stride `-1` over a forward array reads `4 3 2 1 0`, and `begin_offset()` reports `-4`.
- **Every dimension has a `min`.** `host` points at the element with coordinates `(min0, min1, …)`, so a crop keeps the parent's coordinate system. **Verified**: cropping the interleaved buffer's x to `[2, 4)` and y to `[1, 3)` gave `x.min = 2`, `y.min = 1`, and `c(2, 1, 0)` aliased `rgb(2, 1, 0)`, 18 bytes into the parent (6 bytes for the same crop of the planar buffer). Bounds inference relies on this: required regions are absolute coordinates.
- **Everything is 32-bit.** `min`, `extent` and `stride` are `int32_t`, and `maximum_buffer_size()` is `2^31 - 1` bytes unless a 64-bit target enables `LargeBuffers` ([`Target.h`][target-max]).
- **The element type is a runtime tag**, not a template parameter: `halide_type_t` is a code (`int`, `uint`, `float`, `handle`, `bfloat`, `struct`), a bit width and a 16-bit `info`. At this revision the ABI type carries no lane count: _"Unlike the compiler-side Halide::Type, it does NOT carry a vector width ('lanes'): a value crossing the ABI boundary is always a single element"_ ([source][rt-type]).

Against [DLPack's `DLTensor`][dlpack], read at `94485e23`: both use element strides and a type tag, and both are plain C. They differ in four ways. DLPack's `shape` and `strides` are `int64_t`; Halide's are `int32_t`. DLPack has no per-axis origin, only a `byte_offset`; Halide's `min` is part of the buffer. DLPack's tensor lives on exactly one `DLDevice`; a Halide buffer can have a host allocation and a device allocation at once, with dirty bits saying which is current. And since DLPack 1.2, `strides` "can not be NULL if ndim != 0", which Halide never allowed. Halide has no DLPack import or export in the tree (a grep for `dlpack` finds nothing); its Python bindings use the Python buffer protocol (`py::buffer_info`) instead ([`PyRuntimeBuffer.cpp`][pyrt]).

There are no planes in the multi-plane sense: a YUV 4:2:0 frame is three buffers of different extents, and chroma subsampling is something the algorithm expresses (`uv(x / 2, y / 2)`), not the buffer.

### 2. Genericity mechanism

Genericity lives in the DSL, not in C++ templates. A `Func` is untyped until its definition is built; `Expr` arithmetic carries a `Halide::Type` with lanes, and the pipeline is specialised to concrete types when it is compiled. On the C++ side, `Halide::Runtime::Buffer<T, Dims, InClassDimStorage>` is a thin typed view over `halide_buffer_t`; `T = void` and `Dims = AnyDims` accept anything at run time, and up to `InClassDimStorage` dimensions (default 4 for `AnyDims`, otherwise `Dims`) are stored inline ([`HalideBuffer.h`][hb-class]). `Generator` introspects its `Input` and `Output` members to build the C signature, a form of reflection over declared members. `specialize(cond)` is the run-time counterpart: it compiles a second loop nest under a condition such as "stride 0 is 1" and branches once at the top. There are no concepts or traits in the user's sense: what a stage can do is decided by the compiler's IR, not by the element type.

### 3. Colour and metadata

Not applicable: Halide has no colour model. A buffer is numbers; sRGB, linear light, premultiplied alpha, ICC, CICP and EXIF are outside the type and the ABI. Colour conversions in `apps/` (for example `camera_pipe`) are ordinary arithmetic in the algorithm. The absence is deliberate (the ABI is shared with non-image arrays) and means a colour-aware library built on Halide-style kernels must carry colour metadata beside the buffer, never inside it.

### 4. I/O and codec architecture

Not applicable in the library: Halide has no image codec. `tools/halide_image_io.h` is a convenience loader for tests and apps that calls `libpng` and `libjpeg` unless `HALIDE_NO_PNG` or `HALIDE_NO_JPEG` is defined and reads PPM/PGM and a few others itself ([source][imgio]); it is not part of the runtime. The pipeline model is pull-based in a specific sense: the output region determines, through bounds inference and the bounds-query mode, which input region must exist, so an application can decode or fetch exactly that rectangle before calling the pipeline. Data-dependent stages such as entropy decoding do not fit the model (the papers' synthesis lists this as an open problem).

### 5. Hostile input and safety

Halide's safety story is that of a trusted pipeline over untrusted _shapes_. The checks are generated, run once per call, and cover:

- each dimension's required interval against the buffer's `[min, min + extent - 1]` (`halide_error_code_access_out_of_bounds`);
- negative extents (`halide_error_code_buffer_extents_negative`), and an `extent × stride` or an extent product above `maximum_buffer_size()`, which is `2^31 - 1` unless `LargeBuffers` is on (`halide_error_code_buffer_allocation_too_large`, `halide_error_code_buffer_extents_too_large`);
- type and dimensionality mismatches (`halide_error_code_bad_type`, `halide_error_code_bad_dimensions`) and user constraints (`halide_error_code_constraint_violated`) ([error codes][rt-errors]);
- dirty-bit invariants (`halide_error_code_host_and_device_dirty`, `halide_error_code_device_dirty_with_no_device_support`) ([source][rt-dirty-errs]).

Data-dependent indexing is handled twice. At compile time, an input access whose interval cannot be bounded is rejected ("may be accessed in an unbounded way"), which forces the author to clamp an index computed from pixel values. During lowering, `clamp_unsafe_accesses` inserts clamps where an index depends on another function's values and the allocation may be wider than the computed region ([`ClampUnsafeAccesses.h`][clamp]). Inside a pipeline the loops are unchecked; correctness rests on the compiler's interval arithmetic, which is why `test/fuzz/bounds.cpp` fuzzes it (section 10). `Target::NoAsserts` strips every check ("Stripping asserts..." runs after every pass that emits checks), so a deployment can remove the whole safety layer with a target flag. The 32-bit extents bound the damage of a hostile size: without `LargeBuffers`, a header that claims a 100,000 × 100,000 image fails the extent-product check before any loop runs.

The ABI itself is not memory-safe: `dim` is a raw pointer the caller owns, `host` is a raw pointer, and a lying stride passes every check that only looks at extents.

### 6. Allocation and ownership

The raw ABI owns nothing. Allocation inside a pipeline goes through `halide_malloc` / `halide_free`, which an application may replace ([source][rt-malloc]):

> _"Note that halide_malloc must return a pointer aligned to the maximum meaningful alignment for the platform for the purpose of vector loads and stores, *and* with an allocated size that is (at least) an integral multiple of that same alignment. The default implementation uses 32-byte alignment on arm and 64-byte alignment on x86. Additionally, it must be safe to read at least 8 bytes before the start and beyond the end."_

The last sentence is a contract a caller-provided buffer must also meet if a schedule over-reads. Small constant-size intermediates go on the stack or into registers ("Bounding small allocations..."), the rest on the heap; `store_in` overrides the choice. The C++ `Runtime::Buffer` adds ownership: an `AllocationHeader` with an atomic reference count for host memory and a `DeviceRefCount` whose `BufferDeviceOwnership` is `Allocated`, `WrappedNative`, `Unmanaged`, `AllocatedDeviceAndHost` or `Cropped` ([source][hb-own]). Crops share the parent's allocation through the count.

The runtime holds mutable process-global state (allocator hooks, thread pool, caches), and two components that each embed a runtime silently share it unless their symbols are renamed ([`doc/CustomRuntimes.md`][doc-custom]):

> _"When they are linked into one process the linker collapses those duplicate (weak/`linkonce`) symbols into a single copy, so the two components silently *share* one runtime."_

### 7. CPU parallelism and SIMD

`parallel(y)` lowers to a closure and a call to `halide_do_par_for(user_context, task, min, size, closure)`; the default pool spins briefly before sleeping, `halide_set_num_threads` sizes it, and `halide_set_custom_do_par_for` replaces it ([source][rt-parfor]). An application with its own scheduler can therefore run Halide tasks on its workers.

`vectorize(x, n)` turns a constant-extent loop into `Ramp` and `Broadcast` IR of `n` lanes; LLVM then selects instructions, after a "Finding intrinsics..." pass and the per-target code generators have rewritten idioms Halide wants guaranteed (the `simd_op_check` tests pin them, for example rounding averages to `pavgb`). Vector width is a schedule choice, not a type: the blur vectorises by 16 in its CPU schedule and by 256 and 128 in its Hexagon schedule. Tails are handled by `TailStrategy`, so the main loop is always full-width. ISA selection is per compilation (a target string) plus the optional multi-target wrapper at run time, with OS-aware x86 detection and fixed-length SVE2.

### 8. GPU offload and interop

Offload is a schedule property: `gpu_tile` on a stage in a pipeline compiled with a GPU feature turns its loops into a kernel, and the "Injecting host <-> dev buffer copies" pass inserts `halide_copy_to_device` before a kernel reads a buffer and marks outputs `device_dirty`. The dirty bits are the whole coherence protocol ([`device_interface.cpp`][di-tohost]):

```cpp
// src/runtime/device_interface.cpp (abridged)
WEAK int copy_to_host_already_locked(void *user_context, struct halide_buffer_t *buf) {
    if (!buf->device_dirty()) {
        return halide_error_code_success;  // my, that was easy
    }
    const halide_device_interface_t *interface = buf->device_interface;
    if (buf->host_dirty()) {
        return halide_error_code_copy_to_host_failed;
    }
    ...
    auto result = interface->impl->copy_to_host(user_context, buf);
    buf->set_device_dirty(false);
    ...
```

`copy_to_device` is the mirror image: allocate if `device == 0`, copy only if `host_dirty`, then clear it ([source][di-todevice]); both dirty bits set at once is an invariant violation that the device entry points check through `debug_log_and_validate_buf` ([source][di-validate]). Results stay on the device until the caller asks for `halide_copy_to_host`, so a chain of GPU pipelines exchanges buffers without round trips. **Verified**: a crop of a host buffer filled through `Runtime::Buffer::fill` reports `host_dirty = 1`, `device_dirty = 0`, `device = 0`.

`halide_device_interface_t` is a table of function pointers (`device_malloc`, `copy_to_host`, `copy_to_device`, `buffer_copy`, `device_crop`, `device_slice`, `wrap_native`, `detach_native`, …) shared by every GPU API, with the API-specific part behind `impl` ([source][rt-devif]). Interop with a host engine goes through `wrap_native` (adopt a `VkBuffer`, `MTLBuffer` or CUDA pointer) and the context hooks; the Vulkan back end additionally accepts the host's `VkAllocationCallbacks`. What Vulkan interop does not offer at this revision: images or samplers, timeline semaphores or any asynchronous submission (every dispatch and copy ends in `vkQueueWaitIdle`), and a public declaration of the wrap function.

### 9. Temporal, animation and containers

Not applicable: Halide has no time axis, no frame model and no container. A video is a 3-D or 4-D buffer, or a sequence of pipeline calls; temporal filters are written as stencils over a `t` coordinate. `async()` and `ring_buffer()` overlap a producer with its consumer within one call, which is the closest Halide gets to streaming.

### 10. Testing and conformance

The test tree is large and layered: 681 `.cpp` files in `test/correctness`, 111 in `test/generator`, 39 in `test/performance` and seven fuzz harnesses in `test/fuzz`, plus `test/autoschedulers`, `test/runtime`, `test/warning` and `test/failing_with_issue` (counts of `git ls-tree` entries at the pinned revision).

- **Instruction-selection tests.** `simd_op_check_x86.cpp`, `_arm`, `_sve2`, `_hvx`, `_powerpc`, `_riscv` and `_wasm` assert that a given expression at a given width compiles to a named instruction, for example `check("pavgb", 8 * w, u8((u16(u8_1) + u16(u8_2) + 1) / 2))` ([source][simd-x86]). Where the host can run the code, the shared harness also compiles a scalar `f_scalar` of the same expression and compares results ([`simd_op_check.h`][simd-op]): the scalar form is the oracle for the vector form.
- **Fuzzing the compiler's reasoning.** `test/fuzz` holds harnesses for `bounds`, `simplify`, `solve`, `cse`, `in_clone`, `lossless_cast` and `widening_lerp`, built on a small framework with a `std::mt19937_64` backend that prints its seed and a libFuzzer backend ([`doc/FuzzTesting.md`][doc-fuzz]). `fuzz_bounds` generates random expressions over `UInt(1)` to `Int(32)` and checks the interval analysis on which the removal of per-pixel checks depends ([source][fuzz-bounds]). `test/correctness/fuzz_schedule.cpp` keeps schedules found by fuzzing that crashed the compiler, and the `FuzzFloatStores` target feature masks off the least significant mantissa bit of every float store, which [its header][ffs] says "correlates very well with whether or not a pipeline will produce very different outputs on different architectures (e.g. with and without FMA)".
- **Bounds and device behaviour** have dedicated tests (`bounds_inference*.cpp`, `bounds_query.cpp`, `gpu_*.cpp`, `custom_vulkan_context.cpp`).
- **Vulkan status** is recorded in prose: all correctness tests pass on tested Linux and Windows configurations with `host-vulkan-vk_int8-vk_int16-vk_int64-vk_float16-vk_float64-vk_v13` "on LLVM v14.x" (the build now requires LLVM 21), macOS through MoltenVK fails some, and Android is "currently being worked on" ([`doc/Vulkan.md`][doc-vk-caveats]).

There is no image-conformance corpus, because there is no codec; correctness is "the schedule did not change the answer", checked against a scalar or reference schedule.

---

## Lessons for Sparkles

- **Q3 — The transferable unit is the split between a per-point kernel and a loop nest, not the compiler.** Halide's directives are loop rewrites a D template can perform on a kernel it is handed: `split` plus `vectorize` with a `ShiftInwards` tail is a loop over `__vector` lanes whose last iteration is moved back, and `compute_at`/`store_at` with folding is a ring of rows in a fixed-size buffer. A D schedule can be a compile-time value consumed by a loop-nest template, as the [papers' synthesis][p-dsl-synth] proposes; what does not transfer is bounds inference over arbitrary expressions, which needs an IR. Where Sparkles stands: the [shaders and SIMD baseline][bl-shaders-gaps] (G4: "no mechanism beyond hand-written per-target kernels").
- **Q1, Q8 — Check the shape once, then index without checks.** Halide's per-pixel loops are unchecked because one comparison per dimension at entry covers every access. The D form is a `@safe` entry that validates a view against a declared footprint (stencil radius, resample ratio) and a `@trusted` inner loop on raw pointers. **Verified** in miniature: the D probe's `covers` function decided, under `-betterC` with `-preview=dip1000`, that a 3×3 stencil on an edge output needs a halo outside a 4×3 buffer and that an interior one does not. This needs the footprint to be declared data, since D cannot infer it from a lambda; it fits `@nogc nothrow`, and a production form would return an `Expected` error rather than call a `halide_error_*`-style callback. Baseline: [existing image code][bl-existing-gaps] (G7: hostile-input bounds "by declared size, not by work").
- **Q1 — `halide_buffer_t` is the minimum strided ABI, and its `min` field is the feature DLPack lacks.** A Sparkles view that keeps an origin per axis gives crops in the parent's coordinate system and makes "which input rectangle does this output need" a box computation. Against D conventions the ABI's `int32_t` extents and strides conflict with `size_t` indices (the shaders baseline's `SHM6` already records `size_t` widening to 64 bits on the device), and the raw `dim` pointer and `host` pointer are `@system` by nature; a D view would keep the layout as `extern (C)` interop (the probe shows D can mirror it exactly) and expose a typed, `scope`-checked view above it. **Verified**: sizes and offsets match between the C++ header and the D mirror. Baseline: [existing image code][bl-existing-gaps] (G2: "No pixel view type") and [concepts: stride][concepts-stride].
- **Q6, Q7 — Two dirty bits are a complete host/device coherence protocol for a library that does not own the GPU timeline.** `host_dirty`/`device_dirty` plus lazy `copy_to_host` lets GPU stages chain without readback and lets a CPU stage force one. It transfers directly to a buffer type shared between host SIMD and `sparkles:shaders` compute. What does not transfer is Halide's synchronous Vulkan runtime (a `vkQueueWaitIdle` after each dispatch and copy), which contradicts the frame-budgeted, barrier-ordered upload path of `ui-vulkan` (`UVK29`, `UVK30`). Baseline: [Vulkan baseline][bl-vk] and [event-horizon baseline][bl-eh].
- **Q7 — Halide's Vulkan kernels read storage buffers and do strided arithmetic; they never sample.** That is the shape `sparkles:shaders` M10 would need (storage buffers, workgroup memory, specialization constants for workgroup size), and none of it exists yet. The specialization-constant workgroup size requires Vulkan 1.3 in Halide; the sidecar header (descriptor counts and constants per entry point) is a reflection-free binding description that `apps/shader-compile` could emit beside SPIR-V. Baseline: [shaders and SIMD][bl-shaders-gaps] (G1, G2, G9).
- **Q3, Q7 — Make the workgroup shape and the vector width schedule parameters, measured per device.** Halide encodes both as directives, the [papers' synthesis][p-dsl-synth] records GPU cost models as "fragile against downstream compilers" (after Anderson 2021), and the hardware matrix shows the machines Sparkles targets share AVX2+FMA on x86 and NEON with dot product on AArch64, with AVX-512 only on Zen 4 and SVE on none ([hardware: CPU SIMD][hw-simd]). Halide's fixed-length SVE2 (`vector_bits` required) is a precedent that a vector-length-specific build is acceptable. Baseline: [shaders and SIMD][bl-shaders-gaps] (G5, G7).
- **Q3 — Runtime ISA dispatch: copy the four-valued decision and the injectable probe.** `halide_can_use_target_features` separates permanent from temporary decisions and is overridable; `x86_cpu_detect.h` checks XCR0 and is tested against recorded CPU state. Sparkles' `simd_caps.d` already checks `xgetbv`, but its flags are `package`-visible and no NEON probe exists (G5). A public, testable `cpuid`/`xgetbv`/`getauxval` probe with recorded fixtures would serve image kernels and text kernels alike.
- **Q8 — The oracle pattern is "same algorithm, different schedule".** `simd_op_check` compares the vector form to a scalar form and also asserts instruction selection; `fuzz_bounds` attacks the analysis that removes checks. For Sparkles this is the BLAKE3 test shape (every backend against `portable`) generalised to image kernels, plus a fuzz of the footprint check. Instruction-selection assertions would need the build to emit assembly per `@target`, which `bench` builds with `-mcpu=native` do not exercise. Baseline: [shaders and SIMD][bl-shaders-gaps] (G7, G8).
- **Q9 — Halide's packaging is evidence for keeping the kernel ABI apart from the algorithms.** The runtime ships separately from the compiler, the buffer ABI is shared by every pipeline, and the Python packaging lets AOT users install only `halide-runtime`. The same shape appears in Sparkles as a small image-core (view, type tag, dirty state) that formats and algorithms both depend on. The counter-evidence is the runtime's global state: two embedded runtimes collide unless renamed, which in D would be module-level `__gshared` hook state shared by every user of the package.
- **Q2 — Genericity by a run-time type tag plus compile-time specialisation.** Halide's `halide_type_t` tags the ABI and the compiler specialises per type; D can do the specialisation with templates and design by introspection and keep a tag only at the boundary (files, GPU, `extern (C)`). What does not transfer is the untyped `Func`: D kernels are typed functions, so mixing element types is a template parameter, not an `Expr` cast.
- **Q4, Q5 — Nothing to take for codecs or colour.** Halide's absence of colour and container models is a finding: a kernel layer can stay colour-blind if colour lives in a separate descriptor, and the bounds-query mode suggests a codec API shape ("give me this rectangle") without saying anything about decoding it.
- **Q2, Q9 — betterC, wasm and Android.** Halide's runtime is freestanding C++ ("no standard library, no exceptions and no RTTI", per [`x86_cpu_detect.h`][x86-detect]) and has WebAssembly and Android runtime files; the equivalent D kernel layer would be `-betterC`-clean. The probe shows the ABI struct and a shape check compile under `-betterC`; dispatch through `shared static this()` constructors, which the shaders baseline flags (G6), is the part that needs a betterC-compatible replacement.

## Strengths

- **One algorithm, many schedules, provably the same result**: tiling, fusion, vectorisation, parallelism and GPU mapping change without touching the definitions.
- **Per-pixel bounds checks removed by construction**: one generated assertion per buffer dimension, with unbounded accesses rejected at compile time and the bounds-query mode exposing required regions to callers.
- **A small, stable, C buffer ABI** with per-axis origin, signed element strides and a host/device pair with dirty bits; the same struct works for images, tensors and arbitrary arrays.
- **AOT output needs no compiler at run time**, with a multi-target wrapper for ISA dispatch and a replaceable runtime (allocator, thread pool, context, error handler).
- **Broad, honest target coverage**: x86 up to AVX-512 per family, NEON, fixed-length SVE2, Hexagon, WebAssembly, and six GPU APIs (CUDA, OpenCL, Metal, D3D12, Vulkan, WebGPU), with OS-aware x86 detection.
- **Testing aimed at the compiler's own reasoning**: instruction-selection checks against scalar oracles, and fuzzers for bounds, simplification and solving.

## Weaknesses

- **It is a compiler.** Using Halide means LLVM 21 or newer at build time, a C++ embedding and a generator step; the scheduling model cannot be adopted as a library.
- **32-bit extents and strides** in the ABI, and `2^31 - 1` bytes per buffer unless a 64-bit target enables `LargeBuffers`; scientific volumes need the feature flag and still cannot exceed `2^31 - 1` elements along one axis.
- **No colour, metadata, codec or temporal model**; images are numbers.
- **Data-dependent control flow across stages** (entropy decoding, sparse work) does not fit the feed-forward model.
- **The Vulkan back end is beta and synchronous**: storage buffers only, no images or samplers, `vkQueueWaitIdle` after each dispatch and copy, Vulkan 1.3 for dynamic workgroup sizes, and a wrap function absent from the public header.
- **Documentation drift at the pinned revision**: the Vulkan allocator's minimum block size is 4 KiB in code and 32 MB in `doc/Vulkan.md`; the Li2018 README calls itself the only GPU autoscheduler; the Vulkan status section reports results on LLVM v14.x.
- **Autoschedulers need output-size estimates** and, for the learned ones, trained weights; GPU support in Mullapudi2016 is experimental and opt-in.
- **Process-global runtime state** collides between independently built components unless their symbols are prefixed.
- **Safety is removable by a flag**: `NoAsserts` strips every generated check.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                                      | Trade-off                                                                                                |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Algorithm as pure functions over an infinite grid          | Schedules can reorder, recompute and fold freely without changing results                      | Data-dependent pipelines and in-place mutation fit only through `RDom` updates and extern stages         |
| Separate schedule language (directives on `Func`/`Stage`)  | Target-specific tuning without touching the algorithm; autoschedulers emit the same directives | A second program to write and maintain; good schedules need expertise or a trained autoscheduler         |
| Axis-aligned interval bounds inference                     | Cheap, predictable, enough for stencils, resampling and pyramids                               | Over-approximates non-rectangular footprints; unbounded data-dependent accesses must be clamped by hand  |
| One check per buffer dimension at pipeline entry           | Inner loops carry no bounds checks                                                             | Safety depends on the interval analysis being right (hence the fuzzers); `NoAsserts` removes it entirely |
| `halide_buffer_t` with `min`, `extent`, `stride` per axis  | Crops keep coordinates; layouts are stride permutations; one ABI for every pipeline            | `int32_t` fields; raw caller-owned `dim` pointer; no plane or colour description                         |
| Host and device allocations in one buffer with dirty bits  | Lazy, minimal copies; GPU stages chain without readback                                        | Two-bit protocol has no notion of queues or timelines; invariant checked at every runtime call           |
| AOT generators plus a freestanding runtime                 | No compiler in deployments; runtime replaceable piece by piece                                 | Global runtime state shared by every pipeline in a process unless symbols are prefixed                   |
| Run-time dispatch by a multi-target wrapper                | One binary covers several ISAs; decisions can be cached or re-asked                            | A full pipeline copy per target; JIT not allowed                                                         |
| SVE2 compiled for a fixed `vector_bits`                    | Reuses fixed-width vectorisation and instruction selection                                     | Binaries are vector-length-specific                                                                      |
| Vulkan via direct SPIR-V over storage buffers, synchronous | No GLSL toolchain; strided indexing works for any layout; simple runtime                       | No texture hardware, no sampling, no overlap of transfer and compute; beta quality                       |
| Autoschedulers as plugins keyed by name                    | Heuristic, learned and GPU searches coexist and evolve outside the core                        | Require size estimates; learned models need training data per architecture                               |

## Sources

- [halide/Halide repository][repo], read at `85f16183923fcec94c2fb6e756d98e6831ea1524`: [`README.md`][readme], [`LICENSE.txt`][license], [`CMakeLists.txt`][cmake].
- Buffer ABI and runtime: [`halide_buffer_t`][rt-buf], [`halide_type_t`][rt-type], [device interface][rt-devif], [error codes][rt-errors], [`halide_malloc`][rt-malloc], [`halide_do_par_for`][rt-parfor], [`halide_can_use_target_features`][rt-canuse], [target features][rt-features], [`Runtime::Buffer`][hb-class], [ownership][hb-own], [dirty-bit copies][di-tohost], [`_halide_buffer_is_bounds_query`][bq].
- Scheduling and lowering: [`Stage` directives][func-stage], [GPU directives][func-gpu], [`store_at`][func-store-at], [`TailStrategy`][sched-tail], [`RDom`][rdom], [boundary conditions][bc], [`Lower.cpp`][lower], [image checks][aic-oob], [unbounded-access error][aic-unbounded], [size checks][aic-size], [`clamp_unsafe_accesses`][clamp], [`Target.h` buffer limits][target-max].
- Generators and dispatch: [`Generator.h`][gen], [`compile_multitarget`][module-mt], [x86 detection][x86-detect], [XCR0 check][x86-os], [SVE `vector_bits`][arm-sve], [host SVE length][target-sve], [`apps/blur`][blur], [tutorial lesson 8][lesson8].
- Vulkan: [`doc/Vulkan.md`][doc-vk-status], [`CodeGen_Vulkan_Dev.cpp` header][cvk-header], [buffer binding][cvk-buf], [workgroup size][cvk-wgs], [`vulkan.cpp` run][vk-run], [copy to device][vk-copy], [wrap][vk-wrap], [crop offset][vk-crop-offset], [allocator config][vk-mem], [context hooks][vk-api].
- Autoschedulers: [Mullapudi2016][m16], [Li2018 README][li18], [Adams2019][a19], [Anderson2021][a21], [plugin registration][plugin].
- Testing: [`simd_op_check.h`][simd-op], [`simd_op_check_x86.cpp`][simd-x86], [`test/fuzz/bounds.cpp`][fuzz-bounds], [`doc/FuzzTesting.md`][doc-fuzz], [`doc/CustomRuntimes.md`][doc-custom], [`doc/RunGen.md`][doc-rungen].
- [DLPack `DLTensor`][dlpack] at `94485e23519bc30e22a18397a9c8ff1ea6b2b81e`, for the ABI comparison.
- Papers: [DSLs and scheduling thread][p-dsl] (Ragan-Kelley 2012, 2013, 2018; Mullapudi 2016; Adams 2019; Anderson 2021; Li 2018).
- Within this survey: [umbrella][index], [concepts][concepts-schedule], [shaders and SIMD baseline][bl-shaders], [existing image code baseline][bl-existing], [Vulkan baseline][bl-vk], [event-horizon baseline][bl-eh], [hardware matrix][hw-simd].

<!-- References -->

[repo]: https://github.com/halide/Halide
[site]: https://halide-lang.org
[api]: https://halide-lang.org/docs
[tutorials]: https://github.com/halide/Halide/tree/85f16183923fcec94c2fb6e756d98e6831ea1524/tutorial
[doc-dir]: https://github.com/halide/Halide/tree/85f16183923fcec94c2fb6e756d98e6831ea1524/doc
[readme]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/README.md#L3-L16
[license]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/LICENSE.txt
[cmake]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/CMakeLists.txt#L194-L196
[rt-parfor]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/HalideRuntime.h#L230-L249
[rt-malloc]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/HalideRuntime.h#L475-L490
[rt-type]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/HalideRuntime.h#L555-L593
[rt-devif]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/HalideRuntime.h#L920-L968
[rt-errors]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/HalideRuntime.h#L1232-L1254
[rt-dirty-errs]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/HalideRuntime.h#L1370-L1405
[rt-features]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/HalideRuntime.h#L1513-L1649
[rt-canuse]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/HalideRuntime.h#L1674-L1712
[rt-buf]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/HalideRuntime.h#L1728-L1927
[hb-own]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/HalideBuffer.h#L164-L191
[hb-class]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/HalideBuffer.h#L195-L236
[di-tohost]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/device_interface.cpp#L30-L54
[di-validate]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/device_interface.cpp#L100-L124
[di-todevice]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/device_interface.cpp#L152-L205
[bq]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/halide_buffer_t.cpp#L85-L87
[vk-copy]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/vulkan.cpp#L414-L599
[vk-run]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/vulkan.cpp#L1338-L1371
[vk-wrap]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/vulkan.cpp#L1394-L1425
[vk-crop-offset]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/internal/memory_resources.h#L77-L79
[vk-mem]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/vulkan_memory.h#L24-L31
[vk-api]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/HalideRuntimeVulkan.h#L72-L136
[x86-detect]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/x86_cpu_detect.h#L1-L30
[x86-os]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/runtime/x86_cpu_detect.h#L228-L245
[cvk-bool]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/CodeGen_Vulkan_Dev.cpp#L32-L37
[cvk-header]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/CodeGen_Vulkan_Dev.cpp#L2460-L2530
[cvk-wgs]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/CodeGen_Vulkan_Dev.cpp#L2648-L2700
[cvk-buf]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/CodeGen_Vulkan_Dev.cpp#L2930-L2987
[arm-sve]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/CodeGen_ARM.cpp#L1004-L1011
[target-sve]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/Target.cpp#L289-L292
[target-max]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/Target.h#L378-L392
[func-stage]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/Func.h#L412-L530
[func-gpu]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/Func.h#L2074-L2099
[func-store-at]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/Func.h#L2544-L2637
[sched-tail]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/Schedule.h#L35-L130
[rdom]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/RDom.h#L76-L98
[bc]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/BoundaryConditions.h#L95-L250
[gen]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/Generator.h#L4-L41
[lower]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/Lower.cpp#L149-L562
[aic-unbounded]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/AddImageChecks.cpp#L381-L385
[aic-oob]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/AddImageChecks.cpp#L386-L418
[aic-size]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/AddImageChecks.cpp#L436-L475
[aic-dirty]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/AddImageChecks.cpp#L643-L652
[clamp]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/ClampUnsafeAccesses.h#L13-L19
[module-mt]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/Module.cpp#L844-L847
[m16]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/autoschedulers/mullapudi2016/AutoSchedule.cpp#L25-L64
[li18]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/autoschedulers/li2018/README.md
[a19]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/autoschedulers/adams2019/AutoSchedule.cpp#L1-L42
[a21]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/autoschedulers/anderson2021/AutoSchedule.cpp#L1-L30
[plugin]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/autoschedulers/common/HalidePlugin.h#L7-L13
[blur]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/apps/blur/halide_blur_generator.cpp#L34-L111
[lesson8]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/tutorial/lesson_08_scheduling_2.cpp#L162-L178
[doc-vk-status]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/doc/Vulkan.md#L3-L11
[doc-vk-features]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/doc/Vulkan.md#L159-L175
[doc-vk-alloc]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/doc/Vulkan.md#L228-L232
[doc-vk-caveats]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/doc/Vulkan.md#L284-L308
[doc-fuzz]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/doc/FuzzTesting.md#L1-L18
[doc-custom]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/doc/CustomRuntimes.md#L3-L19
[doc-rungen]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/doc/RunGen.md#L1-L12
[imgio]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/tools/halide_image_io.h#L1-L39
[simd-op]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/test/correctness/simd_op_check.h#L321-L368
[simd-x86]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/test/correctness/simd_op_check_x86.cpp#L172-L183
[ffs]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/src/FuzzFloatStores.h#L13-L20
[fuzz-bounds]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/test/fuzz/bounds.cpp
[pyrt]: https://github.com/halide/Halide/blob/85f16183923fcec94c2fb6e756d98e6831ea1524/python_bindings/halide-runtime/src/halide/runtime/PyRuntimeBuffer.cpp#L276-L290
[dlpack]: https://github.com/dmlc/dlpack/blob/94485e23519bc30e22a18397a9c8ff1ea6b2b81e/include/dlpack/dlpack.h#L232-L290
[p-dsl]: ./papers/dsl-scheduling.md
[p-dsl-synth]: ./papers/dsl-scheduling.md#thread-synthesis
[index]: ./index.md
[concepts-stride]: ./concepts.md#stride
[concepts-schedule]: ./concepts.md#algorithm-and-schedule
[bl-shaders]: ./baseline/shaders-simd.md
[bl-shaders-gaps]: ./baseline/shaders-simd.md#gaps-and-tensions
[bl-existing]: ./baseline/existing-code.md
[bl-existing-gaps]: ./baseline/existing-code.md#gaps-and-tensions
[bl-vk]: ./baseline/vulkan.md
[bl-eh]: ./baseline/event-horizon.md
[hw-simd]: ./hardware/index.md#cpu-simd
