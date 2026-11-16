# dcompute (D)

The D-native GPU compute library: LDC compiles `@compute` modules to SPIR-V for OpenCL
and to PTX for CUDA, and `libmir/dcompute` supplies the device standard library and the
host drivers that launch those kernels, which makes it the only existing answer to "what
does an image kernel written in D look like on a GPU".

| Field         | Value                                                                                                                                                                  |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | D (a device subset, compiled by LDC with `-mdcompute-targets=`)                                                                                                        |
| License       | BSL-1.0 ([`dub.json`][dub-json])                                                                                                                                       |
| Repository    | [libmir/dcompute][repo]; the compiler half lives in [ldc-developers/ldc][ldc-dcompute-d]                                                                               |
| Revision read | `cdb5792d49ba2e43149acf219f3a6a61e9bff07e` (July 19, 2026, the tip of `master`; 21 commits after tag `v0.1.1`); LDC read at `ac0e420af3fe74de50ff2138f9ffcb464c29873a` |
| Documentation | The [README][readme-about], the [`docs/`][docs-kernels] chapters (kernels, hardware, `std`, driver); in-source comments                                                |
| Category      | D landscape: GPU compute (single-source kernels plus OpenCL and CUDA host drivers)                                                                                     |
| Tier          | B                                                                                                                                                                      |
| Last reviewed | November 7, 2026                                                                                                                                                       |

> [!NOTE]
> The compiler side of dcompute (the device rules, address-space mapping, the
> unmerged Vulkan target and the Sparkles fork's fragment stage) is already surveyed in
> [shading languages: dcompute and `sparkles:shaders`][sl-dcompute], and the state of
> `sparkles:shaders` in [the shaders and SIMD baseline][bl-shaders]. This page covers the
> library from the image side: its image types, its host drivers, its maintenance
> state, and what an image kernel looks like through each route.

## Overview

### What it solves

A GPU program normally has two languages: OpenCL C or CUDA C++ for the kernel, and a
host language that loads and launches it. dcompute removes the first one. The README
states the scope ([`README.md`][readme-about]):

> "This project is a set of libraries designed to work with LDC to enable native
> execution of D on GPUs (and other more exotic targets of OpenCL such as FPGAs DSPs,
> hereafter just 'GPUs') on the OpenCL and CUDA runtimes."

It names four parts: `std` ("abstractions over the intrinsics of OpenCL and CUDA"),
`driver` (the compute API wrappers), `kernels` ("a set of standard kernels and
primitives") and `tests`.

### Design philosophy

- **The kernel is ordinary D under a restriction.** A module marked `@compute` is
  compiled once per device target; a function marked `@kernel()` is an entry point; a
  pointer carries its address space in its type (`GlobalPointer!float`). The kernel
  chapter tabulates the mapping ([`docs/03-kernels.md`][docs-kernels]): `Global` is
  OpenCL `__global` and CUDA `__device__`, `Shared` is `__local` and `__shared__`, and
  so on for `Constant`, `Private` and `Generic`.
- **One source, per-target folding.** Portable functions branch on
  `__dcompute_reflect(ReflectTarget.OpenCL, …)` and `ReflectTarget.CUDA`, which LDC folds
  to a constant per target, so one `GlobalIndex.x` serves both backends.
- **The host launch is typed by the kernel.** `q.enqueue!(saxpy)(grid, block)(args)`
  derives its parameter list from the kernel's signature, replacing each device pointer
  with a host buffer. The README pairs it with the CUDA spelling
  `saxpy<<<1,N,0,q>>>(b_res,alpha,b_x,b_y, N);` ([`README.md`][readme-example]).
- **The hardware model is "the body of a loop".** The hardware chapter
  ([`docs/02-hardware.md`][docs-hardware]): "you write the kernel as the body of a for
  loop that is then vectorised and run in parallel by the `device`", and on GPUs
  "Texture fetch means you can load from nearby in 2D or 3D efficiently."

## How it works

### Device side: `dcompute.std`

`dcompute.std.index` defines `GlobalIndex`, `GlobalDimension`, `GroupIndex`,
`SharedIndex` and their `.linear` forms, each a `__dcompute_reflect` chain that ends in
`assert(0)` ([`std/index.d`][std-index]):

```d
// source/dcompute/std/index.d (abridged)
@compute(CompileFor.hostAndDevice) module dcompute.std.index;
pure: nothrow: @nogc:
struct GlobalDimension
{
    pragma(inline,true);
    @property static size_t x()()
    {
        if(__dcompute_reflect(ReflectTarget.OpenCL,0))
            return ocl.get_global_size(0);
        else if(__dcompute_reflect(ReflectTarget.CUDA,0))
            return cuda.ntid_x()*cuda.nctaid_x();
        else
            assert(0);
    }
```

`AutoIndexed!(GlobalPointer!float)` wraps a pointer so that reading or assigning it
indexes at `GlobalIndex.linear` ([`std/index.d`][std-autoindexed]); the test kernel
`auto_index_test` writes `a = b + c;` with it ([`dummykernels.d`][tests-dummy]).
`dcompute.std.sync` has `barrier`, `local_fence` and `global_fence` for both backends,
with "TODO: image fence?" at the end ([`std/sync.d`][std-sync]). `dcompute.std.atomic`
implements `atomicAdd` and `atomicExchange` for CUDA only; the OpenCL path is
`assert(0)` ([`std/atomic.d`][std-atomic]). `dcompute.std.warp` is a comment listing a
planned vote, shuffle and reduce API with no code ([`std/warp.d`][std-warp]), and
`dcompute.std.memory` is the same for shared-memory reservation
([`std/memory.d`][std-memory]). `dcompute.kernels` is a module declaration and an
eight-line comment ([`kernels/package.d`][kernels]): the "standard kernels" of the README do not exist.

### Device side: OpenCL images

The only image support is OpenCL-specific: `dcompute.std.opencl.image` (added in 2022
by commit `af45dfa6`, "Add support for OpenCL Image I/O") aliases LDC's opaque
`ldc.opencl` types and declares the OpenCL C built-ins by their Itanium-mangled names
([`std/opencl/image.d`][cl-image]):

```d
// source/dcompute/std/opencl/image.d (abridged)
template ReadOnlyImage(int dim)
{
    static if (dim == 2)
        alias ReadOnlyImage = GlobalPointer!image2d_ro_t;
    // dim 1 and 3 likewise
}
alias Sampler = SharedPointer!sampler_t;
template read(T) if (is(T == float))
{
    alias T4 = __vector(T[4]);
    pragma(mangle,"_Z11read_imagef14ocl_image2d_ro11ocl_samplerDv2_i")
        T4 read(GlobalPointer!image2d_ro_t, Sampler, __vector(int[2]));
}
```

LDC's OpenCL target recognises any `ldc.opencl.image*` struct behind a pointer
parameter, derives the `read_only`, `write_only` or `read_write` kernel-argument
qualifier from the `_ro_t`, `_wo_t`, `_rw_t` suffix, and records `cl_images` usage
([`targetOCL.cpp`][ldc-ocl-image]). The pixel format of an image is not in the device
type at all: it is chosen on the host, and `read!float`, `read!int` and `read!uint`
return a four-lane vector whose interpretation the OpenCL runtime supplies (normalised
float for `unorm` channels, integer for integer channels).

### Host side: `dcompute.driver`

- **OpenCL.** `Context.createProgram(void[] spirv)` calls `clCreateProgramWithIL`
  ([`ocl/context.d`][ocl-context]); the test loads `.dub/obj/kernels_ocl200_64.spv`
  from disk ([`tests/main.d`][tests-main-ocl]). The host `Image` struct holds a
  `cl_mem` and enumerates `ChannelOrder` (`r` … `bgra`, `depth`) and `ChannelType`
  (`unormInt8`, `half_`, `float_`, `unormInt101010` …) with an `Info` record of
  `rowPitch`, `slicePitch`, `width`, `height`, `depth`, `arraySize`, `mipLevels`; its
  `getInfo` mixin is commented out and there is no constructor
  ([`ocl/image.d`][host-image]). Only the raw binding in `ocl/raw/functions.d` wraps
  `clCreateImage`; no driver type calls it, so a host program cannot allocate the image a
  D image kernel takes without calling the raw binding itself. `Sampler` is a handle
  with enums, `retain` and `release` ([`ocl/sampler.d`][host-sampler]), created by
  `Context.createSampler` through `clCreateSampler` ([`ocl/context.d`][ocl-sampler-create]).
- **CUDA.** `Buffer!T` pairs a `CUdeviceptr` with an optional host slice and copies
  with `copy!(Copy.hostToDevice)` ([`cuda/buffer.d`][cuda-buffer]); `UnifiedBuffer!T`
  wraps `cuMemAllocManaged` so that "explicit copy … calls are not needed"
  ([`cuda/unified_buffer.d`][cuda-unified]). `Queue.enqueue!k` builds a `void*[]` of
  argument addresses and calls `cuLaunchKernel` ([`cuda/queue.d`][cuda-queue]).
  `Program.fromModule!"…"` loads PTX that LDC 1.43 embeds as a
  `__dcompute_ptx_<arch>_<module>` global. `launch!k(grid, block, args)` loads that
  program on its first call; the platform, context and per-thread queue come from module
  constructors (under `version(LDC_DCompute_CUDA)`), with `ensureInit()` as a fallback
  ([`cuda/program.d`][cuda-program], [`cuda/runtime.d`][cuda-launch]). Textures and
  surfaces are an open TODO: "Support globals & images. Requires competent compiler."
  ([`cuda/program.d`][cuda-program-todo]).
- **The typed launch.** `HostArgsOf!F` maps every `Pointer!(n, U)` parameter to
  `Buffer!U` and leaves the rest alone. The OpenCL queue uses the copy in
  `driver/util.d`, whose own comment says "TODO substitute Pointer!(n,T) with Buffer!T,
  Image etc." ([`driver/util.d`][util]); the CUDA driver has its own, built on a
  `ReplaceTemplate!(Pointer, Buffer)` helper ([`cuda/package.d`][cuda-hostargs]). An image
  parameter therefore has no host counterpart type.
- **Errors.** Driver calls store a thread-local `Status` and call `checkErrors()`,
  which hands it to the `onDriverError` delegate; the default throws
  `DComputeDriverException`, and under `D_BetterC` it prints instead
  ([`driver/error.d`][error]).

### Demonstration: the routes on this repository's toolchain

A scratch directory, `/tmp/dcompute-demo`, compiled four small device modules against
the pinned `libmir/dcompute` sources with the dev shell's `ldc2` and `ldc2-vulkan` (both
report "LDC 1.43.0 … based on DMD v2.113.0 and LLVM 24.0.0git"), then ran `spirv-val`
(the `spirv-tools-1.4.363.0` package, whose binary reports v2026.4). Observed:

| Module                                                                  | Target       | Result                                                                                                                                                      |
| ----------------------------------------------------------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| any, with the README's flag `-mdcompute-targets=ocl-300`                | OpenCL 3.0   | rejected: "Valid version strings for OpenCl are ocl-{100, 110, 120, 200, 210, 220}" ([`dcomputecodegenerator.cpp`][ldc-ocl-ver])                            |
| any                                                                     | `cuda-800`   | rejected: "LDC was not built with CUDA DCompute support" (the shell's LLVM registers no NVPTX target)                                                       |
| README `saxpy` over `GlobalPointer!float`                               | `ocl-200`    | `-O0`: SPIR-V that fails `spirv-val` (`OpInBoundsPtrAccessChain` result type mismatch); `-O2`: valid                                                        |
| `write(WriteOnlyImage!2, int2, float4)`                                 | `ocl-200`    | `-O2`: `OpImageWrite` on a non-image operand, "Expected Image to be of type OpTypeImage"                                                                    |
| `read!float(ReadOnlyImage!2, Sampler, int2)` then `write`               | `ocl-200`    | LLVM assertion in SPIR-V call lowering, "This is not a register operand!"                                                                                   |
| `read!float` and `read!int` in one module                               | `ocl-200`    | frontend error: "Function type does not match previously declared function with the same mangled name: `_Z11read_imagef14ocl_image2d_ro11ocl_samplerDv2_i`" |
| `samplerInit!(false, clampToEdge, nearest)`                             | `ocl-200`    | "undefined identifier `coords`" ([`image.d`][cl-sampler-init] names its parameter `normalisedCoords`)                                                       |
| any kernel importing `dcompute.std.index`                               | `vulkan-130` | LLVM assertion, "Calling a function with a bad signature!"                                                                                                  |
| packed-RGBA8 invert over `GlobalPointer!uint`, `llvm.spv.thread.id.i32` | `vulkan-130` | valid under `--target-env vulkan1.3`: `GLCompute`, `LocalSize 64 1 1`, `PhysicalStorageBuffer64`, one argument block at `Binding 0`                         |

The mangled-name error has a visible cause: the `int` and `uint` overloads of `read` for
2-D and 3-D images reuse the `read_imagef` names of the `float` overloads, and the
`int` overload of the 1-D `write` is declared as `write_imagef`
([`image.d`][cl-read-int], [`image.d`][cl-write-1d]). The LLVM-level failures are
observations on this toolchain (LLVM main plus the project's local SPIR-V patches,
described in [the shading-languages page][sl-dcompute]), not on a released LDC.

## Analysis

### 1. Pixel and memory model

dcompute has two memory models and no image model of its own. Buffers are raw
`Pointer!(AddrSpace, T)` with no length, extent or [stride][c-stride]: a 2-D image
kernel over a buffer receives `width`, `height` and a pitch as scalar parameters and
indexes `p[y * pitch + x]` itself, as [mir `Slice`][mir] or [DLPack][dlpack] would
encode in a descriptor. OpenCL images are opaque handles whose layout, channel order,
channel type, row and slice pitch live in the host `Image.Format` and `Image.Info`
records, the same split the OpenCL C model has. The address-space table (`Global`,
`Shared`, `Constant`, `Private`, `Generic`) is the part that would carry over to any
D-written kernel; there is no notion of planes, [tiles][c-tiling] or views.

### 2. Genericity mechanism

Templates and per-target constant folding. `__dcompute_reflect` turns one generic
function into the right intrinsic per backend; `read(T)` and `write(I)` are templates
constrained on the element or image type; `HostArgsOf` rewrites a kernel signature by
`staticMap`. Each is a compile-time switch over a closed list: a third target (Vulkan)
falls into `assert(0)` everywhere, and a new image kind means another hand-written
mangled declaration. The library is a precedent for introspecting a kernel signature to
build the host call, not for an open pixel abstraction.

### 5. Hostile input and safety

Device code has no bounds checks: `GlobalPointer` indexes like a raw pointer and the
`saxpy` guard `if (i >= N) return;` is the user's job. On the host, a missing
`-mdcompute-targets` flag surfaces as "Need to use a DCompute enabled compiler"
([`README.md`][readme-flags]). The image module's mangled names are unchecked strings,
and 18 of them, in three groups, are wrong (see the demonstration), which compiles
until two overloads meet in one module. Nothing validates image dimensions against
`Device.Info.image2DMaxWidth`. [Hostile input][c-hostile] in the codec sense is out of
scope: dcompute never parses a file.

### 6. Allocation and ownership

Host objects are plain structs holding a raw handle (`cl_mem`, `CUdeviceptr`) with
explicit `release()`; the CUDA tests pair each with `scope(exit) b.release()`. There is no
reference counting or RAII destructor, so a copied `Buffer!T` aliases the handle.
`UnifiedBuffer!T` hands back the managed allocation as a host slice. Error reporting
allocates (`new DComputeDriverException`) unless built as BetterC.

### 7. CPU parallelism and SIMD

None. `dcompute.std.index` is `@compute(CompileFor.hostAndDevice)`, but on the host
every index function reaches `assert(0)`, so a kernel cannot run as a CPU loop. The
hardware chapter treats the CPU only as one more device class ("Caches are present and
reasonable in size. Vectors are relatively short."). The CPU twin that
`sparkles:shaders` gives its vocabulary ([baseline][bl-shaders]) has no counterpart.

### 8. GPU offload and interop

This is the subject's whole content, and it splits by route:

- **OpenCL.** The only route with image objects and samplers on the device. The host
  side cannot create them, the device declarations are partly wrong, and on this
  repository's toolchain the generated SPIR-V for image access is invalid or crashes
  the backend. Program loading is `clCreateProgramWithIL` from a file the build wrote.
- **CUDA.** Mature for buffers: typed launch, embedded PTX, managed memory. No
  textures or surfaces, so an image kernel is a buffer kernel with manual indexing,
  and no image interop with a graphics API. Sparkles' toolchain has no NVPTX backend.
- **Vulkan.** Not in the library. The compiler target from LDC pull request 5132 accepts
  `@kernel` and passes every argument through one storage buffer of 64-bit
  buffer-device addresses ([shading languages][sl-dcompute]); the library's index,
  barrier and atomic helpers have no Vulkan branch, and importing the index module
  aborts the compiler today. What works is the bare form: a kernel over
  `GlobalPointer!uint` that reads its invocation index through a hand-declared
  `llvm.spv.thread.id.i32` intrinsic, as in the demonstration and in the fork's test
  `vulkan_global_pointer_index.d`.

The three shapes an image kernel takes in D, side by side:

```d
// A. dcompute, OpenCL images (ocl-200): typed images and a sampler; invalid on this toolchain
@kernel() void invert(ReadOnlyImage!2 src, WriteOnlyImage!2 dst, Sampler s)
{
    __vector(int[2]) p; p[0] = cast(int) GlobalIndex.x; p[1] = cast(int) GlobalIndex.y;
    __vector(float[4]) c = read!float(src, s, p);
    __vector(float[4]) one = 1.0f;
    c = one - c; c[3] = 1.0f;
    write(dst, p, c);
}

// B. Vulkan compute (vulkan-130, ldc2-vulkan): packed pixels in a storage buffer; validates
pragma(LDC_intrinsic, "llvm.spv.thread.id.i32") uint threadId(uint dim);
@kernel([64, 1, 1]) void invert(GlobalPointer!uint src, GlobalPointer!uint dst, uint n)
{
    const i = threadId(0);
    if (i >= n) return;
    dst[i] = (~src[i] & 0x00FF_FFFFu) | (src[i] & 0xFF00_0000u);
}

// C. sparkles:shaders today: a fragment pass over a sampled texture (libs/ui/shaders/effects.d)
@fragment vec4 scanlines(@input vec2 fragTexCoord, @input vec4 fragColor,
    Sampler2D texture0, @uniform vec2 uExtentCells)
    => tier0!(sparkles.ui.effect_shaders.scanlines)(fragTexCoord, fragColor, texture0, uExtentCells);
```

Route A is the only one where the format conversion (unorm8 to float and back) is done
by the hardware's image unit. Route B leaves unpacking to the kernel and needs the host
to put buffer addresses in the argument block, for which no D host code exists (the
[Vulkan baseline][bl-vk] has no compute dispatch). Route C runs today through
[`effects.d`][effects] and the [`sparkles:shaders` build][shaders-docs], but it writes
a render target through the rasteriser, not a storage image; `sparkles:shaders` imports
the fork's `ldc.dcompute` symbols (`fragment`, `vertex`, `UniformBlock`,
`PushConstants`, `binding` …) under `version (LDC_DCompute)` and none of
`libmir/dcompute` ([`attributes.d`][attributes]). Compute with storage images and
workgroup memory is milestone M10 of the [shaders plan][shaders-plan], not started.

### 10. Testing and conformance

One test program, `source/dcompute/tests/main.d`, runs `saxpy` on a real device and
`enforce`s the result; OpenCL and CUDA are separate `dub` configurations
([`dub.json`][dub-json]), and the CUDA embedded-PTX tests skip themselves on compilers
older than frontend 2113 ([`tests/main.d`][tests-main-cuda]). There is no image test,
no CPU reference, no continuous integration in the tree, and no oracle beyond the host
recomputing `alpha * x[i] + y[i]`. The mangled-name and `samplerInit` defects above
survive because no test instantiates them.

Not covered: 3, 4, 9.

## Lessons for Sparkles

- **Q3, Q7:** dcompute shows that a D kernel can be source-shared across GPU backends
  through `__dcompute_reflect` and address-space-typed pointers, but it never runs the
  same kernel on the CPU. The Sparkles requirement that a pixel kernel run as host SIMD
  and as a compute shader needs a host meaning for every index and barrier, which
  dcompute's `assert(0)` branches do not give.
- **Q6:** The useful host idea is `HostArgsOf`: derive the host argument list from the
  kernel signature. A Vulkan compute dispatch in Sparkles would need the same derivation
  to fill the buffer-device-address argument block that the LDC Vulkan target emits; the
  OpenCL and CUDA implementations do not transfer, because neither API is in the
  repository's GPU stack ([Vulkan baseline][bl-vk]).
- **Q1:** dcompute's buffer kernels index raw pointers with scalar extents. An image
  kernel in Sparkles would want the extent, [stride][c-stride] and pixel format carried
  in a descriptor (the role `Slice` or a [DLPack][dlpack] tensor plays on the host), not
  repeated as loose parameters.
- **Q5, Q6:** Hardware image objects (OpenCL images, Vulkan storage and sampled images)
  move format conversion into the GPU's texture unit. Neither dcompute nor the
  Sparkles fork has a storage-image type for compute; the fork's `Sampler2D` is the
  nearest, and the shading-languages page lists a templated image type as the missing
  piece.
- **Q8:** The library's failure modes (wrong mangled names, an uninstantiated template
  with an undefined identifier, image code that compiles to invalid SPIR-V) are what an
  untested device library produces. Every device primitive Sparkles adds needs a
  compile-and-`spirv-val` test per profile and a host-versus-device readback, like the
  readback tests `sparkles:shaders` already has ([baseline][bl-shaders]).
- **Q9:** Depending on `libmir/dcompute` would bring in `derelict-cl`, `bindbc-cuda`
  and `taggedalgebraic` and two GPU APIs Sparkles does not use, for a device library
  whose image half does not work on the toolchain Sparkles pins. Its address-space
  vocabulary is in LDC's druntime, not in the library, so a Sparkles GPU image package
  can use the language feature without the dependency.

## Strengths

- Kernels are D: templates, CTFE, UFCS and `static if` on the device, with
  address spaces in the type rather than in qualifiers.
- One source serves OpenCL and CUDA through codegen-time `__dcompute_reflect`.
- A typed CUDA launch (`launch!saxpy(grid, block, args)`) with embedded PTX and
  implicit initialisation, and managed memory through `UnifiedBuffer!T`.
- Revived since 2025: 21 commits after `v0.1.1`, among them the BindBC CUDA backend,
  `UnifiedBuffer`, embedded kernels and the first atomics.
- Driver errors go through one replaceable delegate, with a BetterC mode.

## Weaknesses

- No Vulkan support in the library; on the Vulkan target its index module crashes the
  compiler.
- Image support is OpenCL-only, has wrong mangled names, an uncompilable `samplerInit`,
  no host-side image creation, and produces invalid SPIR-V on this repository's
  toolchain.
- No CUDA textures or surfaces; image kernels on CUDA are buffer kernels.
- `kernels`, `warp`, `memory` and OpenCL atomics are comments or `assert(0)`.
- No CPU execution of kernels, no image tests, no CI in the tree.
- The README's recommended `ocl-300` target is rejected by LDC 1.43.
- The [shading-languages page][sl-dcompute] calls the library "stalled at `v0.1.1`";
  the git history shows otherwise, but no release has been tagged since June 12, 2025.

## Sources

- [`libmir/dcompute` `README.md`][readme-about]; docs: [kernels][docs-kernels],
  [hardware][docs-hardware]
- Device library: [`std/index.d`][std-index] ([`AutoIndexed`][std-autoindexed]),
  [`std/sync.d`][std-sync], [`std/atomic.d`][std-atomic], [`std/warp.d`][std-warp],
  [`std/memory.d`][std-memory], [`std/opencl/image.d`][cl-image],
  [`kernels/package.d`][kernels]
- Host drivers: [`driver/util.d`][util], [`driver/error.d`][error],
  [`ocl/context.d`][ocl-context], [`ocl/image.d`][host-image], [`cuda/package.d`][cuda-hostargs],
  [`ocl/sampler.d`][host-sampler], [`cuda/buffer.d`][cuda-buffer],
  [`cuda/unified_buffer.d`][cuda-unified], [`cuda/queue.d`][cuda-queue],
  [`cuda/program.d`][cuda-program], [`cuda/runtime.d`][cuda-launch]
- Tests: [`tests/dummykernels.d`][tests-dummy], [`tests/main.d`][tests-main-ocl],
  [`dub.json`][dub-json]
- LDC at `ac0e420a`: [`ldc/dcompute.d`][ldc-dcompute-d], [`ldc/opencl.di`][ldc-opencl],
  [`targetOCL.cpp`][ldc-ocl-image], [`dcomputecodegenerator.cpp`][ldc-ocl-ver]
- Sparkles: [`attributes.d`][attributes], [`effects.d`][effects],
  [`sparkles:shaders` docs][shaders-docs], [shaders plan][shaders-plan]
- Related: [shading languages: dcompute][sl-dcompute], [shaders and SIMD
  baseline][bl-shaders], [Vulkan baseline][bl-vk], [Halide][halide] (algorithm and
  schedule across CPU and GPU), [OpenCV][opencv] (`UMat` over OpenCL), [concepts][concepts],
  [umbrella][umbrella]
- Demonstration: `/tmp/dcompute-demo` (scratch; not committed)

<!-- References -->

[repo]: https://github.com/libmir/dcompute/tree/cdb5792d49ba2e43149acf219f3a6a61e9bff07e
[readme-about]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/README.md#L10-L17
[readme-example]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/README.md#L23-L46
[readme-flags]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/README.md#L66-L71
[dub-json]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/dub.json#L1-L39
[docs-kernels]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/docs/03-kernels.md#L16-L48
[docs-hardware]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/docs/02-hardware.md#L1-L30
[std-index]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/std/index.d#L1-L72
[std-autoindexed]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/std/index.d#L298-L323
[std-sync]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/std/sync.d#L9-L39
[std-atomic]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/std/atomic.d#L8-L20
[std-warp]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/std/warp.d#L1-L19
[std-memory]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/std/memory.d#L1-L17
[kernels]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/kernels/package.d#L1-L9
[cl-image]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/std/opencl/image.d#L1-L131
[cl-sampler-init]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/std/opencl/image.d#L82-L90
[cl-read-int]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/std/opencl/image.d#L133-L150
[cl-write-1d]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/std/opencl/image.d#L200-L217
[cuda-hostargs]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/cuda/package.d#L33-L36
[ocl-sampler-create]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/ocl/context.d#L101-L113
[util]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/util.d#L7-L19
[error]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/error.d#L167-L223
[ocl-context]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/ocl/context.d#L125-L150
[host-image]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/ocl/image.d#L4-L71
[host-sampler]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/ocl/sampler.d#L4-L44
[cuda-buffer]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/cuda/buffer.d#L5-L45
[cuda-unified]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/cuda/unified_buffer.d#L1-L60
[cuda-queue]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/cuda/queue.d#L60-L98
[cuda-program]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/cuda/program.d#L42-L80
[cuda-program-todo]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/cuda/program.d#L21-L24
[cuda-launch]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/driver/cuda/runtime.d#L140-L163
[tests-dummy]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/tests/dummykernels.d#L1-L25
[tests-main-ocl]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/tests/main.d#L80-L92
[tests-main-cuda]: https://github.com/libmir/dcompute/blob/cdb5792d49ba2e43149acf219f3a6a61e9bff07e/source/dcompute/tests/main.d#L116-L124
[ldc-dcompute-d]: https://github.com/ldc-developers/ldc/blob/ac0e420af3fe74de50ff2138f9ffcb464c29873a/runtime/druntime/src/ldc/dcompute.d
[ldc-opencl]: https://github.com/ldc-developers/ldc/blob/ac0e420af3fe74de50ff2138f9ffcb464c29873a/runtime/druntime/src/ldc/opencl.di#L1-L26
[ldc-ocl-image]: https://github.com/ldc-developers/ldc/blob/ac0e420af3fe74de50ff2138f9ffcb464c29873a/gen/dcompute/targetOCL.cpp#L210-L235
[ldc-ocl-ver]: https://github.com/ldc-developers/ldc/blob/ac0e420af3fe74de50ff2138f9ffcb464c29873a/driver/dcomputecodegenerator.cpp#L29-L74
[attributes]: ../../../libs/shaders/src/sparkles/shaders/attributes.d
[effects]: ../../../libs/ui/shaders/effects.d
[shaders-docs]: ../../libs/shaders/index.md
[shaders-plan]: ../../specs/shaders/PLAN.md
[sl-dcompute]: ../shading-languages/dcompute.md
[bl-shaders]: ./baseline/shaders-simd.md
[bl-vk]: ./baseline/vulkan.md
[mir]: ./mir-algorithm/index.md
[dlpack]: ./dlpack.md
[halide]: ./halide.md
[opencv]: ./opencv.md
[concepts]: ./concepts.md
[c-stride]: ./concepts.md#stride
[c-tiling]: ./concepts.md#tiling
[c-hostile]: ./concepts.md#hostile-input
[umbrella]: ./index.md
