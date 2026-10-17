# Zig's self-hosted SPIR-V backend (Zig)

A SPIR-V code generator written in Zig inside the Zig compiler, lowering Zig's own typed IR (AIR) straight to SPIR-V without LLVM, so that ordinary Zig, with address spaces, calling conventions and a handful of builtins, compiles to Vulkan shaders and OpenCL kernels.

| Field          | Value                                                                                                                                          |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | Zig (the compiler and the shader source are both Zig)                                                                                          |
| License        | MIT (Expat) — [`LICENSE`][license]                                                                                                             |
| Repository     | [codeberg.org/ziglang/zig][repo] (moved from GitHub to Codeberg); pinned at `d924f83bf3e1a5726d9eca1e9d501aece08107c5` (master, 2026-10-17)    |
| Documentation  | [Language reference `@SpirvType`][langref]; [Zig devlog, "SPIR-V Backend Progress" (2026-06-26)][devlog]; [Ali Cheraghi, "Zig and GPUs"][blog] |
| Category       | Single-source peer: general-purpose systems language with a native SPIR-V backend                                                              |
| Latest version | Zig `0.17.0` (tagged 2026-10-01); the pin is `0.17.0-349-gd924f83bf3`                                                                          |
| Targets        | `spirv32`/`spirv64` × `vulkan`, `opengl`, `opencl` (`src/link/Spirv.zig`); no DXIL, MSL, WGSL or GLSL output                                   |
| Backend        | Self-hosted by default in Debug (`selfHostedBackendIsAsRobustAsLlvm` is `true` for SPIR-V); release modes prefer LLVM unless `-fno-llvm`       |
| Maintenance    | One active maintainer (Ali Cheraghi); the SPIR-V behaviour-test CI target has been disabled since 2025-09-08 ([`test/tests.zig`][tests-zig])   |

> [!NOTE]
> Two revisions matter. The local clone's earlier `HEAD`,
> `1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa` (2026-06-02), still has `std.gpu`, a
> `std.gpu.executionMode()` helper that emits `OpExecutionMode` through inline
> assembly, and a `structured_cfg` module option. The June 2026 overhaul described in
> the [devlog][devlog] replaced all three; this deep-dive cites the later pin
> throughout and names the older one only where the change is itself the finding.

---

## Overview

### What it solves

Zig wants one language for CPU and GPU without a second toolchain. Its GPU story has
two halves: the LLVM backend emits PTX and AMDGCN for vendor runtimes, and a
**self-hosted SPIR-V backend** emits SPIR-V for Vulkan, OpenGL and OpenCL. The backend
consumes the same AIR every other self-hosted backend (x86_64, aarch64, wasm) consumes,
so the whole language front end — `comptime`, generics as functions returning types,
`@Vector`, error unions, optionals — is available to shader code; whatever the backend
cannot lower becomes a compile error or a `TODO (SPIR-V)` failure.

For a single-source D design this is the most direct analogue of the question
`sparkles:shaders` faces: what happens when a general-purpose systems language, whose
programs assume flat memory and a generic address space, is pointed at Vulkan's logical
addressing model. Zig answers it without LLVM, which isolates the language-level
problems from the LLVM-specific ones the
[LLVM SPIR-V backend deep-dive][llvm-spirv] covers.

### Design philosophy

The backend's author states the two central problems plainly ([blog], 2025-04-17):

> _"One core challenge in targeting SPIR-V from a general-purpose language like Zig is
> the need to explicitly specify address spaces (a.k.a. storage classes). Zig supports
> this via the addrspace keyword, but nearly all Zig code assumes pointers live in the
> generic address space. That works fine until you need to lower to SPIR-V, where we
> sometimes rely on OpPtrCastToGeneric. Unfortunately, Vulkan doesn't support that, so
> as a temporary workaround, all pointers are assumed to be local (Function) memory."_

> _"For example, unlike Zig or OpenCL, some Vulkan instructions (fma, sqrt, exp, log) do
> NOT guarantee correctly rounded results."_

and the stated goal, after "Composite integers":

> _"spirv-val should never fail on a binary emitted by Zig. As Zen says, 'Compile errors
> are better than runtime crashes'."_

The June 2026 overhaul pushed the same philosophy into the compiler itself: anything
that used to be hand-written SPIR-V in inline assembly — execution modes, capabilities,
extensions — is now a typed language construct or a target feature, and the assembler
**rejects** the hand-written form ([`Assembler.zig`][assembler]):

```zig
// src/codegen/spirv/Assembler.zig
.OpExecutionMode, .OpExecutionModeId => {
    return ass.fail(ass.inst.inst_offset, "cannot set execution mode in assembly", .{});
},
.OpCapability, .OpExtension => {
    return ass.fail(ass.inst.inst_offset, "cannot declare capabilities or extensions in assembly; use -mcpu instead", .{});
},
```

---

## How it works

A shader is an `export fn` with a SPIR-V calling convention. Interface variables are
`extern` globals (or `@extern` pointers) in a GPU address space, decorated through
`std.lang.ExternOptions.decoration`. The minimal shape, from the compile test
[`test/cases/callconv_spirv.zig`][cc-test]:

```zig
export fn vert() callconv(.spirv_vertex) void {}
export fn frag() callconv(.{ .spirv_fragment = .{ .depth_assumption = .greater } }) void {}
export fn comp() callconv(.{ .spirv_kernel = .{ .x = 8, .y = 8, .z = 1 } }) void {}
export fn task() callconv(.{ .spirv_task = .{ .x = 1, .y = 1, .z = 1 } }) void {}
export fn mesh() callconv(.{ .spirv_mesh = .{ .stage_output = .output_lines, .max_primitives = 1, .max_vertices = 2, .x = 1, .y = 1, .z = 1 } }) void {}

// compile
// target=spirv32-vulkan
// cpu_features=vulkan_v1_2+mesh_shading_ext
```

Resources are declared as externs. From [`test/behavior/spirv.zig`][behavior-spirv]:

```zig
const Image = @SpirvType(.{ .image = .{
    .usage = .{ .sampled = u32 }, .format = .unknown, .dim = .@"2d",
    .depth = .unknown, .arrayed = false, .multisampled = false, .access = .unknown,
} });
const SampledImage = @SpirvType(.{ .sampled_image = Image });
const RuntimeArray = @SpirvType(.{ .runtime_array = u32 });
const RuntimeArrayBuf = extern struct { e: RuntimeArray };

const sampled_image = @extern(*addrspace(.constant) const SampledImage, .{
    .name = "sampled_image",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 1 } },
});
const runtime_array = @extern(*addrspace(.storage_buffer) const RuntimeArrayBuf, .{
    .name = "runtime_array",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 3 } },
});
```

The pipeline, end to end:

1. **Sema** validates the SPIR-V-specific surface: calling-convention options
   (`"kernel workgroup dimensions must be at least 1"`), decorations against address
   spaces (`"'location' decoration requires 'input' or 'output' address space"`,
   [`extern_spirv_decoration_validation.zig`][deco-test]), and `@SpirvType` placement
   (`"struct field of type '@SpirvType(.runtime_array, u32)' must be the last field"`,
   [`directly_embedding_spirv_type_in_struct_and_union.zig`][embed-test]).
2. **`CodeGen.zig`** ([source][codegen]) lowers each function's AIR into a `Mir`
   value. Since June 2026 these jobs run on the compiler's thread pool like every other
   self-hosted backend ([devlog]).
3. **The linker** ([`src/link/Spirv.zig`][link], [`Flush.zig`][flush]) stitches `Mir`s
   and any external `.spv` objects into one module, deduplicates types, prunes dead
   code, and emits the module header from target data: `OpCapability` from the CPU
   feature set, `OpMemoryModel`, `OpEntryPoint` with a computed interface list, and
   `OpExecutionMode` from each entry point's calling-convention payload.

---

## Execution model and stages

Stages are **calling conventions** in `std.lang.CallingConvention`
([`lib/std/lang.zig`][lang]): `spirv_device` (an ordinary callable function),
`spirv_vertex`, `spirv_kernel: SpirvKernelOptions`, `spirv_fragment:
SpirvFragmentOptions`, `spirv_task: SpirvKernelOptions` and `spirv_mesh:
SpirvMeshOptions`. The payload is the execution-mode data:

| Calling convention | Payload fields                                                               | Execution modes emitted ([`Flush.zig`][flush])                                               |
| ------------------ | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `spirv_kernel`     | `x`, `y`, `z`                                                                | `LocalSize`; model `GLCompute` (Vulkan/OpenGL) or `Kernel` (OpenCL)                          |
| `spirv_fragment`   | `pixel_centered_integer`, `depth_assumption` (`none/greater/less/unchanged`) | `OriginUpperLeft` on Vulkan, `OriginLowerLeft` otherwise; `PixelCenterInteger`; `Depth*`     |
| `spirv_vertex`     | none                                                                         | none                                                                                         |
| `spirv_task`       | `x`, `y`, `z`                                                                | `LocalSize`; model `TaskEXT`                                                                 |
| `spirv_mesh`       | `stage_output`, `max_primitives`, `max_vertices`, `x`, `y`, `z`              | `OutputVertices`, `OutputPrimitivesEXT`, `LocalSize`, `Output{Points,LinesEXT,TrianglesEXT}` |

Every `export` of a function with a stage convention becomes an `OpEntryPoint`; its
export name is the entry-point name. The fragment origin is chosen by the target OS, not
by the user — the convention carries no origin field.

Graphics stages exist only on Vulkan and OpenGL: on `spirv64-opencl`, each of
`spirv_fragment`, `spirv_vertex`, `spirv_task` and `spirv_mesh` is rejected with
`"calling convention 'spirv_fragment' not supported by compiler backend 'stage2_spirv'"`
([`callconv_spirv_on_unsupported_platform.zig`][cc-unsupported]). There are **no
geometry, tessellation or ray-tracing conventions**; their absence is the coverage
boundary, not an oversight hidden elsewhere.

Built-in inputs and outputs are not entry parameters but externs in `std.spirv`
([`lib/std/spirv.zig`][std-spirv]), matched to `BuiltIn` by name: a nav whose name
parses as a `spec.BuiltIn` tag gets `OpDecorate … BuiltIn` (`CodeGen.zig`,
`std.meta.stringToEnum(spec.BuiltIn, …)`):

```zig
// lib/std/spirv.zig
pub const position_out = @extern(*addrspace(.output) @Vector(4, f32), .{ .name = "position" });
pub extern const frag_coord: @Vector(4, f32) addrspace(.input);
pub extern var frag_depth: f32 addrspace(.output);
pub extern const global_invocation_id: @Vector(3, u32) addrspace(.input);
```

`front_facing` and `sample_mask` are still commented `TODO`s in that file. Compute
indices also have language builtins (`@workItemId`, `@workGroupId`, `@workGroupSize`),
lowered by `builtin3D` to the `LocalInvocationId`, `WorkgroupId` and `WorkgroupSize`
built-ins.

## Type system and generic programming

The backend inherits Zig's type system whole; the restrictions are in lowering.

- **Vectors.** `@Vector(N, T)` becomes `OpTypeVector` only when `T` is a bool, int or
  float and `2 <= N <= 4` (or `N` is 8 or 16 with the `vector16` feature); any other
  vector is lowered as an array (`isSpvVector`, [`CodeGen.zig`][codegen]). There is no
  swizzle syntax and no matrix type in the language or in `std.spirv`.
- **Two representations.** Every type has a `.direct` form (a SPIR-V value) and an
  `.indirect` form (as stored in memory); `bool`, for instance, is `OpTypeBool` directly
  but a `u1` integer in memory, because SPIR-V booleans have no storage size.
- **Composite integers.** Integers wider than the target's limb (64 bits with `int64`
  or on `spirv64`, else 32) are lowered as arrays of limbs, with arithmetic expanded per
  limb; many operations on them are still `cg.todo` (`"div_floor for composite
integers"`, `"implement composite int switch"`).
- **Floats.** `f16` and `f64` require the `float16`/`float64` target features, otherwise
  `"'f64' is not supported on the current SPIR-V feature set"`; `f80`/`f128` are
  rejected.
- **Opaque SPIR-V types.** `@SpirvType(options: std.lang.Type.Spirv)` returns
  `sampler`, `image` (usage, format, dimensionality, depth, access, arrayed,
  multisampled), `sampled_image` or `runtime_array` types. The devlog calls it the
  answer to "the longest-standing blocker for writing shaders". Using it on a CPU
  target is a compile error: `"builtin @SpirvType is only available when targeting
SPIR-V; targeted CPU architecture is x86_64"`.
- **Generics.** `comptime` parameters and type-returning functions monomorphise before
  AIR, so the backend sees only concrete code — the same position D templates put an
  LDC backend in. Function _pointers_ are not represented: their indirect form is a
  `usize` placeholder (`"TODO: Represent function pointers properly."`).

## Resources, interfaces and memory layout

**Address spaces are the resource model.** `std.lang.AddressSpace` carries GPU members
(`global`, `constant`, `param`, `shared`, `local`, `private`, `input`, `output`,
`uniform`, `push_constant`, `storage_buffer`, `physical_storage_buffer`), and
`CodeGen.storageClass` maps them onto SPIR-V storage classes:

```zig
// src/codegen/spirv/CodeGen.zig — storageClass
.generic => .function,
.global => switch (target.os.tag) {
    .opencl, .amdhsa => .cross_workgroup,
    else => .storage_buffer,
},
.constant => .uniform_constant,
.shared => .workgroup,
.local => .function,
.private => .private,
```

The first line is the generic-address-space workaround from the blog: any pointer whose
type does not name an address space is a `Function` pointer. Code that is generic over
"a pointer" therefore compiles only when the pointee really is function-local; passing
a pointer into a storage buffer through it is a type error resolved by
`@addrSpaceCast`, whose own documentation says the cast "may be a no-op, a complex
operation, or illegal" depending on target ([langref][langref-addrspacecast]). The
language reference entry for the `addrspace` keyword itself reads `TODO add
documentation for addrspace` at the pin.

**Decorations** are a closed union, `ExternOptions.Decoration = { location: u32, flat:
u32, descriptor: { set, binding } }`. `flat` emits `Location` plus `Flat`; there is no
`noperspective`, `centroid`, `sample`, `invariant` or `Component`. **Thread-local
globals** (`threadlocal var`) become `Private` `OpVariable`s with an initializer — the
natural per-invocation reading of TLS.

**Layout.** For `uniform`, `push_constant`, `storage_buffer` and
`physical_storage_buffer` externs, `decorateLayout` writes `Offset` decorations from
**Zig's own ABI** (`ty.structFieldOffset`) and `ArrayStride` from `abiSize`; packed
structs are skipped, unions get explicit padding arrays, and `Block` is applied to the
root. Nothing in `decorateLayout` computes or checks std140/std430 rules: the layout is
correct for Vulkan exactly when the user's `extern struct` already satisfies the rules
the validator applies. A `const` storage-buffer extern is decorated `NonWritable`;
image access qualifiers map to `NonWritable`/`NonReadable`.

**Addressing model.** `Flush.emitMemoryModel` picks `Logical` for `spirv32-vulkan` and
OpenGL, but `PhysicalStorageBuffer64` for `spirv64-vulkan`, adding the
`PhysicalStorageBufferAddresses` capability and `SPV_KHR_physical_storage_buffer`
automatically. Integer-to-pointer casts are permitted on Vulkan only into
`physical_storage_buffer`; otherwise `"cannot cast integer to pointer with address
space '…'"`. The architecture choice (`spirv32` vs `spirv64`) thus silently selects
whether buffer device addresses are in play.

## Built-in library and intrinsics

There is no shading-language standard library. Zig's math builtins lower to the
target's extended instruction set — `GLSL.std.450` on Vulkan/OpenGL, `OpenCL.std` on
OpenCL (`importExtendedSet`) — and `std.spirv` ([source][std-spirv]) adds a thin layer
written in SPIR-V inline assembly:

| `std.spirv` function                                  | SPIR-V it emits                                       |
| ----------------------------------------------------- | ----------------------------------------------------- |
| `controlBarrier`, `memoryBarrier`, `workgroupBarrier` | `OpControlBarrier`, `OpMemoryBarrier`                 |
| `specConst(T, default, spec_id)`                      | `OpSpecConstant{True,False,}`/`…Composite` + `SpecId` |
| `imageSampleImplicitLod(sampled_image, coord)`        | `OpLoad` + `OpImageSampleImplicitLod`                 |
| `imageQuerySize`, `imageWrite`                        | `OpImageQuerySize`, `OpImageWrite`                    |
| `setMeshOutputs`                                      | `OpSetMeshOutputsEXT`                                 |

Each wrapper reflects on its argument with `@typeInfo(...).spirv` and turns misuse into
a `@compileError` ("Can not implicitly sample a sampled image that was multisampled").
Missing at the pin: explicit-LOD and gradient sampling, derivatives, subgroup
operations, atomics beyond what the language's `@atomicRmw` lowers to, and every
GLSL-level compound (`mix`, `smoothstep`, `reflect`).

**Precision is the finding.** Zig's semantics for `@mulAdd`, `@sqrt`, `@exp`, `@log`
are correctly rounded (as OpenCL's are); Vulkan's `GLSL.std.450` versions are not. The
backend maps them anyway and leaves notes in the source:

```zig
// src/codegen/spirv/CodeGen.zig
// NOTE: Vulkan's FMA does not meet Zig's nor OpenCL's precision guarantees and needs
// to be emulated.
.vulkan, .opengl => @backingInt(spec.GlslOpcode.Fma),
```

```zig
// Note: We'll need to check these for floating point accuracy
// Vulkan does not put tight requirements on these, for correction
// we might want to emulate them at some point.
.vulkan, .opengl => @backingInt(@as(spec.GlslOpcode, switch (op) { … .sqrt => .Sqrt, .exp => .Exp, … })),
```

So a Zig function that computes `@sqrt(x)` gives a different, implementation-bounded
answer on a Vulkan GPU from the one it gives on the CPU, and nothing in the type system
or the build says so. The [Vulkan precision table][vk-precision] is the contract the
GPU actually meets.

## Control flow, memory model and restrictions

**Structured control flow is generated, not recovered.** Zig's AIR is already
block-structured (`block`, `loop`, `cond_br`, `switch_br`, `br` to an enclosing block),
so the backend emits `OpSelectionMerge`/`OpLoopMerge` directly while walking it. A
`Block` is either a `selection` — which "can't use early exits", so closing it
"requires a 'merge ladder' of nested OpSelectionMerge instructions, one per pending
merge" — or a `loop`, which "early-exit[s] by jumping to the loop merge label"
([`CodeGen.zig`][codegen]). Breaks out of nested selections are routed through a
next-block id compared at each merge (`structuredNextBlock`/`structuredBreak`). There
is no structuriser pass over an unstructured CFG. At the older pin, an unstructured
mode existed for OpenCL behind `structured_cfg` (default `false` only for `opencl`,
`src/Package/Module.zig` at `1bcd8d9f`); at the current pin the option is gone and all
SPIR-V is structured.

**Memory model.** `OpMemoryModel` is `GLSL450` on Vulkan/OpenGL and `OpenCL` on OpenCL
— not `Vulkan`. Barriers take explicit `Scope` and `MemorySemantics` (a packed
`u32` mirroring the SPIR-V bits) through `std.spirv`.

**Restrictions** (each a `cg.fail`/`cg.todo` at the pin unless stated):

- No function pointers or indirect calls (placeholder `usize`); no recursion support of
  any kind, since SPIR-V `Shader` has no call stack and nothing emulates one.
- No `memcpy` (`"TODO implement airMemcpy for spirv"`), no alignment on variables
  outside OpenCL, no opaque types outside OpenCL, no field access into packed structs or
  unions, inline assembly with at most one returned output.
- In logical addressing, composites with pointer members cannot be built with
  `OpCompositeConstruct`; `constructComposite` spills to a local variable, stores each
  field, and loads.
- Behaviour-test skips: 897 `stage2_spirv) return error.SkipZigTest` lines across
  `test/behavior/` against 2140 `test "…"` declarations (counted with `git grep` at the
  pin; one skip line per skipped test or helper, so the ratio is approximate). The
  devlog reports 49% of behaviour tests passing on `spirv64-vulkan` after the overhaul;
  the blog reported ~50% on Vulkan 1.2 and ~75% on OpenCL in April 2025, adding that
  "these numbers are not expected to get significantly higher since a lot of these
  tests are not meant to be working in GPUs anyway."

## Compilation pipeline and targets

```text
.zig ──► AstGen ──► ZIR ──► Sema ──► AIR ──► spirv/CodeGen.zig ──► Mir
                                                                     │
          external .spv objects ───────────────────────► link/Spirv.zig + Flush.zig
                                                                     │
                                                                  module.spv
```

Invocation, from the blog (the flags predate the overhaul, but the target triples and
`-ofmt=spirv -fno-llvm` are unchanged):

```bash
zig build-obj -target spirv64-vulkan-none -mcpu vulkan_v1_2+int64 -ofmt=spirv -fno-llvm kernel.zig
zig build-obj -target spirv64-opencl-none -mcpu opencl_v2+int64 -ofmt=spirv -fno-llvm kernel.zig
```

- **Capabilities are target features.** `Flush.emitCapabilities` emits `Shader` (or
  `Kernel` + `Addresses`), then one `OpCapability` per SPIR-V capability whose name is a
  `std.Target.spirv.Feature` enabled by `-mcpu`, and likewise for extensions; the
  dependency chains come from SPIRV-Headers ([devlog]). A feature the code needs but
  `-mcpu` did not enable is a compile error at the use (`f64`, mesh conventions), not a
  validation error later.
- **Object files and linking.** `.spv` files are object files; when emitting an object (`build-obj`) that
  exports symbols, the `Linkage` capability is emitted, so separately compiled modules can be linked.
- **Interface lists are computed.** `emitEntryPoints` walks each entry point's call
  graph, collecting every non-`Function` variable it reaches (only `Input`/`Output`
  before SPIR-V 1.4, all of them from 1.4).
- **Output is SPIR-V only.** No GLSL, HLSL, MSL or WGSL; reaching those is left to
  translators such as [SPIRV-Cross][spirv-cross], [naga][naga] or [Tint][tint]. Note
  that `spirv64-vulkan` output uses `PhysicalStorageBuffer64` addressing, which is
  outside the subset some of them accept.
- **Two backends can emit SPIR-V.** `hasLlvmSupport` accepts `spirv32`/`spirv64`, and
  `src/Compilation/Config.zig` prefers LLVM "for release builds" whenever the user has
  not chosen; in Debug the self-hosted backend wins because
  `selfHostedBackendIsAsRobustAsLlvm` returns `true` for SPIR-V. Everything this
  deep-dive describes is the self-hosted path, which is why the blog's commands pass
  `-fno-llvm`; a release build without it goes through LLVM's SPIR-V target instead
  (see [LLVM SPIR-V backend][llvm-spirv]).

## Host integration and CPU execution

**There is no host API.** Zig ships no Vulkan, OpenCL or CUDA runtime binding in
`std`; the blog lists "Provide bindings to CUDA/HIP runtime" as future work, and its
complete example points at a third-party project (`snektron/shallenge`). The host loads
the `.spv` through whatever Vulkan or OpenCL binding it uses and must reproduce the
`set`/`binding`/`location` numbers written in the `@extern` decorations by hand — no
reflection data is emitted.

**CPU execution is "compile the same file for another target", with limits.** Plain
Zig functions with the default calling convention compile for any target, so helper
logic can be shared between a CPU build and a shader build. Everything that is
SPIR-V-specific refuses to compile for the CPU: `@SpirvType` is a compile error on
`x86_64`, the `spirv_*` calling conventions are rejected outside SPIR-V, and `std.spirv`
is extern declarations in SPIR-V-only address spaces plus SPIR-V inline assembly. There
is no CPU implementation of sampling, barriers or built-ins, and — the precision
finding above — no promise that the shared helpers compute the same values.

**Tests run as kernels, but not in CI.** `generateTestEntryPoint` lowers each Zig
`test` into its own entry point that stores the returned `anyerror` into a buffer, with
the comment _"The SPIR-V backend is not yet advanced enough to support the std testing
infrastructure. In order to be able to run tests, we 'temporarily' lower test kernels
into separate entry-points. The test executor will then be able to invoke these to run
the tests."_; the linker writes the error names into an `OpSourceExtension` so the
executor can print them. The executor is not in the tree, and `test/tests.zig` only
builds SPIR-V test binaries (`// Don't run spirv binaries`) — and the Vulkan entry is
commented out: _"Disabled due to no active maintainer (feel free to fix the failures and
then re-enable at any time). The failures occur due to changing AIR from the frontend,
and backend being incomplete."_ Compile-only cases in `test/cases/` still run.

---

## Lessons for sparkles:shaders

- **Adopt: execution-mode data on the entry-point attribute, never in inline
  assembly.** Zig's move from `std.gpu.executionMode()` to
  `callconv(.{ .spirv_fragment = .{ .depth_assumption = .greater } })` — with the
  assembler then _rejecting_ `OpExecutionMode` — is the shape a D `@fragment(...)` /
  `@compute(x, y, z)` UDA payload should have: a typed struct the compiler validates
  (`"kernel workgroup dimensions must be at least 1"`) and emits.
- **Adopt: capabilities from the target, checked at the use.** Zig derives
  `OpCapability`/`OpExtension` from `-mcpu` and fails at the `f64` or mesh use when the
  feature is off. A D device module should declare its required features (a
  module-level UDA) and the build should reject uses outside them, rather than letting
  `spirv-val` or a translator find out.
- **Match, and test: the GPU's precision, not the host's.** Zig's `@sqrt` and
  `@mulAdd` are correctly rounded on the CPU and are not on Vulkan, and the backend
  only leaves a note. The vocabulary must state GLSL/Vulkan precision as its contract
  and the agreement oracle must judge by it — exactly what decision `D12` in
  [`decisions.md`][decisions] does with the Vulkan precision table. Do not expose an
  `fma` whose CPU and GPU meanings differ without saying so in its type or name.
- **Avoid: a generic pointer that silently means `Function`.** "All pointers are
  assumed to be local (Function) memory" turns every generic-pointer helper into a
  latent compile error or miscompile on buffers. D shader code should pass resources by
  `ref` or by typed wrappers (dcompute's `GlobalPointer!T`-style, see
  [`dcompute.md`][dcompute]) and monomorphise per storage class, with a clear diagnostic
  when an untyped pointer reaches a non-`Function` resource.
- **Avoid: layout taken from the host ABI without a check.** Zig decorates `Offset`
  from its own struct layout and leaves std140/std430 conformance to the user. A D
  design should derive offsets for the chosen block layout from one struct and
  `static assert` them against the host layout (the `SHV2` decision for `vec3`
  generalises), so a mismatch is a D compile error.
- **Adopt: map D's thread-local module variables to `Private`.** Zig lowers
  `threadlocal var` to a `Private` `OpVariable`; D's module-level variables are
  thread-local by default, so the same mapping gives them per-invocation meaning on the
  device instead of rejecting them.
- **Avoid: an untested backend.** Zig's SPIR-V behaviour suite was disabled when its
  maintainer stepped away and bit-rotted until a rescue overhaul. Every
  `sparkles:shaders` requirement already has a test oracle ([`testing.md`][testing]);
  the lesson is to keep a GPU-executing conformance run in CI (software rasterizer or
  `lavapipe`), not compile-only checks.

## Strengths

- No LLVM in the path: AIR is block-structured, so structured control flow falls out
  of codegen with no structuriser, and the backend controls every emitted instruction.
- The full language front end (`comptime`, generics, `@Vector`, error unions) is
  available to shader code; monomorphisation happens before the backend.
- Typed, validated configuration: calling-convention payloads, closed decoration
  unions checked against address spaces in Sema, `@SpirvType` placement rules, and
  target-feature-driven capabilities, each with a precise compile error.
- Graphics, compute, task and mesh stages from one compiler; separate compilation and
  linking of `.spv` objects.
- Source comments state the semantic gaps honestly (FMA precision, function pointers,
  the test executor) — the backend's limits are discoverable from the code.

## Weaknesses

- A generic pointer is a `Function` pointer; generic Zig code over pointers does not
  port to resources without `@addrSpaceCast` or rewrites.
- Vulkan math is mapped to `GLSL.std.450` despite Zig's correctly rounded semantics; no
  emulation, no diagnostic.
- No std140/std430 layout derivation or check; layout correctness is the user's.
- Thin built-in library: implicit-LOD sampling, image size/write, barriers, spec
  constants; no derivatives, subgroups, explicit-LOD sampling or GLSL compounds, no
  swizzles, no matrices.
- No host runtime, no reflection output, no CPU implementation of the GPU-specific
  surface.
- Roughly half the behaviour suite passes on Vulkan, the CI target is disabled, and the
  backend depends on one maintainer; it bit-rotted once already (2025-09 to 2026-06).
- SPIR-V only; `spirv64-vulkan` defaults to physical addressing, narrowing what
  translators accept.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                     | Trade-off                                                                                           |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Self-hosted backend from AIR, not LLVM                          | AIR is structured and typed; no dependence on LLVM's SPIR-V maturity          | Every instruction, type and layout rule is hand-written and maintained by one person                |
| Stages and execution modes as calling conventions               | One typed place for stage data; Sema validates it; assembler forbids bypasses | New stages need language changes (`std.lang`), not library additions                                |
| GPU storage classes as Zig address spaces                       | Reuses an existing language feature; pointer types carry the storage class    | `generic` defaults to `Function`, so idiomatic generic-pointer code breaks on resources             |
| Interface via `extern` globals with a closed `Decoration` union | Mirrors SPIR-V's global `OpVariable` model; easy to validate                  | No interpolation qualifiers beyond `flat`; bindings are hand-numbered and not reflected to the host |
| Capabilities and extensions from `-mcpu` features               | Same mechanism as every other target; dependency chains from SPIRV-Headers    | Users must know which feature names a shader needs                                                  |
| Map math builtins straight to `GLSL.std.450`                    | Uses hardware instructions; fast                                              | CPU and GPU results differ beyond Zig's documented semantics, silently                              |
| Layout from Zig's ABI (`structFieldOffset`)                     | One layout for host and device structs; no second layout engine               | std140/std430 conformance is unchecked                                                              |
| Tests lowered to per-test entry points with an error buffer     | Reuses the behaviour suite without `std.testing` on the GPU                   | Needs an out-of-tree executor; CI now only compiles                                                 |

## Sources

- [Zig repository on Codeberg][repo], pinned at `d924f83bf3e1a5726d9eca1e9d501aece08107c5`:
  - [`src/codegen/spirv/CodeGen.zig` — storage classes, layout, structured CFG, FMA/precision notes, test entry points][codegen]
  - [`src/codegen/spirv/Assembler.zig` — rejection of `OpExecutionMode`/`OpCapability`][assembler]
  - [`src/link/Spirv.zig`][link] · [`src/link/Spirv/Flush.zig` — capabilities, memory model, entry points, execution modes][flush]
  - [`lib/std/spirv.zig` — built-ins, barriers, spec constants, image wrappers][std-spirv]
  - [`lib/std/lang.zig` — `CallingConvention`, `AddressSpace`, `Type.Spirv`, `ExternOptions`][lang]
  - [`src/target.zig` — backend selection][target-zig] · [`test/tests.zig` — disabled SPIR-V target][tests-zig]
  - [`test/behavior/spirv.zig`][behavior-spirv] · [`test/cases/callconv_spirv.zig`][cc-test] · [`extern_spirv_decoration_validation.zig`][deco-test] · [`directly_embedding_spirv_type_in_struct_and_union.zig`][embed-test] · [`callconv_spirv_on_unsupported_platform.zig`][cc-unsupported]
  - [`doc/langref.html.in` — `@SpirvType`, `@addrSpaceCast`][langref-src]
  - Earlier pin `1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa`: [`lib/std/gpu.zig` — the removed `executionMode()` helper][old-gpu]
- [Ali Cheraghi, "Zig and GPUs" (2025-04-17)][blog]
- [Zig devlog 2026, "SPIR-V Backend Progress" (2026-06-26)][devlog]
- [Vulkan specification — precision of SPIR-V instructions][vk-precision]
- Related: [LLVM SPIR-V backend][llvm-spirv] · [rust-gpu][rust-gpu] · [Vcc / Shady][vcc-shady] · [dcompute][dcompute] · [SPIRV-Cross][spirv-cross] · [concepts][concepts] · [comparison][comparison] · [catalog index][index]
- Sparkles: [`sparkles:shaders` SPEC][spec] · [decisions][decisions] · [testing][testing]

<!-- References -->

[repo]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5
[license]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/LICENSE
[codegen]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/src/codegen/spirv/CodeGen.zig
[assembler]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/src/codegen/spirv/Assembler.zig
[link]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/src/link/Spirv.zig
[flush]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/src/link/Spirv/Flush.zig
[std-spirv]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/lib/std/spirv.zig
[lang]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/lib/std/lang.zig
[target-zig]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/src/target.zig
[tests-zig]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/test/tests.zig
[behavior-spirv]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/test/behavior/spirv.zig
[cc-test]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/test/cases/callconv_spirv.zig
[deco-test]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/test/cases/compile_errors/extern_spirv_decoration_validation.zig
[embed-test]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/test/cases/compile_errors/directly_embedding_spirv_type_in_struct_and_union.zig
[cc-unsupported]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/test/cases/compile_errors/callconv_spirv_on_unsupported_platform.zig
[langref-src]: https://codeberg.org/ziglang/zig/src/commit/d924f83bf3e1a5726d9eca1e9d501aece08107c5/doc/langref.html.in
[old-gpu]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/gpu.zig
[langref]: https://ziglang.org/documentation/master/#SpirvType
[langref-addrspacecast]: https://ziglang.org/documentation/master/#addrSpaceCast
[blog]: https://alichraghi.github.io/blog/zig-gpu/
[devlog]: https://ziglang.org/devlog/2026/#2026-06-26
[vk-precision]: https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html#spirvenv-precision-operation
[llvm-spirv]: ./llvm-spirv-backend.md
[rust-gpu]: ./rust-gpu.md
[vcc-shady]: ./vcc-shady.md
[dcompute]: ./dcompute.md
[spirv-cross]: ./spirv-cross.md
[naga]: ./naga.md
[tint]: ./tint.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[spec]: ../../specs/shaders/SPEC.md
[decisions]: ../../specs/shaders/decisions.md
[testing]: ../../specs/shaders/testing.md
