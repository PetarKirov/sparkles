# ComputeSharp (C# / .NET)

A Roslyn source generator that transpiles a restricted subset of C# — a `partial struct` with an `Execute()` method — into HLSL at build time, compiles it with an embedded DXC (DX12 compute) or FXC (Direct2D pixel shaders), and embeds the bytecode in the assembly: the most production-proven "shader as a host-language type" design, and the clearest counter-example to a CPU-runnable vocabulary.

| Field          | Value                                                                                                                                                          |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | C# 12+ (host and shader source); HLSL is generated, never written                                                                                              |
| License        | MIT ([`LICENSE`][license])                                                                                                                                     |
| Repository     | [Sergio0694/ComputeSharp][repo], pinned at `40dbe40de0b1eafb570e2af43f78bcdbffdcc00a` (2026-09-05)                                                             |
| Documentation  | [GitHub wiki][wiki]; package READMEs ([`ComputeSharp`][readme-core], [`ComputeSharp.D2D1`][readme-d2d]); the author's thesis [`docs/ComputeSharp.pdf`][thesis] |
| Category       | Single-source peer — host-language subset → vendor shading language via a compile-time generator                                                               |
| Latest version | Latest tag `v3.2.0` (tag commit 2025-04-13); the pin is `v3.2.0-43-g40dbe40d` and [`build/Directory.Build.props`][props] already says `4.0.0` (unreleased)     |
| Targets        | HLSL → DXIL `cs_6_0` (D3D12 compute); HLSL → DXBC `ps_4_0_level_9_1` … `ps_5_0` (Direct2D effects); Windows only (`net10.0`, `SupportedOSPlatformVersion 6.2`) |
| Stages         | Compute (`IComputeShader`), "pixel-like" compute (`IComputeShader<TPixel>`), D2D1 pixel (`ID2D1PixelShader`). No vertex, geometry, mesh or ray stages          |
| CPU execution  | None of its own: intrinsics are stubs; a machine without a GPU falls back to D3D12 [WARP][warp], Microsoft's software rasterizer                               |
| Users          | Microsoft Store (D2D1 effects since January 2023), Paint.NET 5.0 (core effect pipeline) — per the [root `README.md`][readme-root]                              |

---

## Overview

### What it solves

ComputeSharp lets a .NET developer write a GPU kernel as a C# `struct` and dispatch it with one call, with no HLSL file, no shader compiler on the target machine, and no hand-written binding code. The [`ComputeSharp` package README][readme-core] gives the whole programming model in one sample:

```csharp
[ThreadGroupSize(DefaultThreadGroupSizes.X)]
[GeneratedComputeShaderDescriptor]
public readonly partial struct MultiplyByTwo(ReadWriteBuffer<int> buffer) : IComputeShader
{
    public void Execute()
    {
        buffer[ThreadIds.X] *= 2;
    }
}

// host side
GraphicsDevice.GetDefault().For(buffer.Length, new MultiplyByTwo(buffer));
```

The struct's fields (here, the primary-constructor capture `buffer`) are the shader's inputs; `Execute()` is the entry point; `ThreadIds` stands in for `SV_DispatchThreadID`. The second package, `ComputeSharp.D2D1`, applies the same machinery to Direct2D custom effects, which is what Paint.NET and the Microsoft Store ship.

### Design philosophy

The project's stance is that the C# _syntax tree_ is the shader, and the generator owns everything else — HLSL text, register assignment, constant-buffer packing, bytecode. The root README states the goal plainly:

> "**ComputeSharp** is a .NET library to run C# code in parallel on the GPU through DX12, D2D1, and dynamically generated HLSL compute and pixel shaders. [...] The goal of this project is to make GPU computing easy to use for all .NET developers!" — [`README.md`][readme-root]

Two consequences follow, and both matter to sparkles. First, the C# that names a shader operation does not _implement_ it: every intrinsic carries the doc remark "This method is an intrinsic and can only be used within a shader on the GPU. Using it on the CPU is undefined behavior." ([`Hlsl.g.cs`][hlsl-g]). Second, the CPU story is delegated to the platform: "If your machine doesn't have a supported GPU [...] **ComputeSharp** will automatically create a WARP device instead, [...] with shaders running on the CPU instead through an emulation layer" ([`src/ComputeSharp/README.md`][readme-core]). ComputeSharp is thus single-_source_ but not single-_semantics_: one text, one meaning (HLSL's), one executor (a D3D device, hardware or WARP).

Within the catalog, compare it with [ILGPU][ilgpu] (the other .NET subject, which compiles IL rather than syntax and does ship a CPU accelerator), [TypeGPU][typegpu] (a host-language subset whose functions also run on the CPU), [rust-gpu][rust-gpu] and the D baseline [dcompute][dcompute] (both compile through a real compiler back end rather than rewriting syntax).

---

## How it works

### Discovery: an incremental generator keyed on an attribute

[`ComputeShaderDescriptorGenerator`][gen] is an `IIncrementalGenerator`. It registers `ForAttributeWithMetadataName("ComputeSharp.GeneratedComputeShaderDescriptorAttribute", …)` and, for each annotated `struct`, bails out silently unless: unsafe blocks are enabled, the type is non-generic and has at least one interface, it is accessible from its assembly, and it implements exactly one shader interface (`TryGetIsPixelShaderLike`). It then runs a fixed sequence of "syntax processors", each producing an equatable model so Roslyn can cache it:

| Step                                  | Produces                                                                                     |
| ------------------------------------- | -------------------------------------------------------------------------------------------- |
| `ConstantBuffer.GetInfo`              | byte size of the root-constant block and the HLSL offset of every captured value field       |
| `NumThreads.GetInfo`                  | `ThreadsX/Y/Z` from `[ThreadGroupSize]`, and whether build-time compilation is possible      |
| `HlslBytecode.GetCompileOptions`      | `[CompileOptions]` flags                                                                     |
| `HlslSource.GetInfo`                  | the transpiled HLSL text, plus "is the static sampler used" / "is the implicit texture used" |
| `Resources.GetInfo`                   | register/descriptor-range layout for every resource field                                    |
| `HlslBytecodeSyntaxProcessor.GetInfo` | DXIL bytes (cached in a process-wide `DynamicCache` keyed on source + options)               |

Diagnostics are split from the model before source output, so a diagnostic-only change does not invalidate generated code ([`ComputeShaderDescriptorGenerator.cs`][gen]).

### Transpilation: a `CSharpSyntaxRewriter` with a semantic model

`HlslSource.GetInfo` ([`…HlslSource.cs`][gen-src]) walks the shader's members. Instance fields become either resources (`HlslKnownTypes.IsTypedResourceType`) or value fields in the constant buffer; anything else is `CMPS0001` "Invalid shader field". Static `[GroupShared]` array fields become `groupshared` arrays. Methods are rewritten by [`ShaderSourceRewriter`][ssr], a subclass of [`HlslSourceRewriter`][hsr], which asks the semantic model about every node and:

- renames C# types to HLSL (`Float4` → `float4`, `Bool` → `bool`) through `HlslKnownTypes`, and intrinsic calls through the `[HlslIntrinsicName("…")]` attribute on each `Hlsl` method;
- renames identifiers that collide with HLSL keywords to `__reserved__<name>` ([`HlslKnownKeywords.cs`][keywords]) instead of rejecting them;
- rewrites indexers (`texture[x, y]` → `texture[int2(x, y)]`), matrix swizzle indexers (`m[M11, M12]` → `m._m00_m01`, constant indices only, else `CMPS0037`), and `const` field reads (inlined as `#define`d `__Owner__Name` constants);
- follows every called method, constructor and static field transitively, emitting each as an HLSL function or global — but only when its _source_ is in the compilation: a call to anything else is `CMPS0049` "methods or constructors need to either be HLSL intrinsics or with source available for analysis" ([`DiagnosticDescriptors.cs`][diag]);
- rejects the rest of C# node by node: [`HlslSourceRewriter.Diagnostics.cs`][hsr-diag] overrides one `Visit…` per forbidden construct (`foreach`, `try`, `throw`, `lock`, `await`, LINQ queries, ranges, recursive/relational patterns, `ref` types, tuples, `stackalloc`, `sizeof`, pointers, function pointers, `unsafe`, `using`, `yield`, collection and initializer expressions, string literals).

The entry point gets its own rewriter, [`ExecuteMethodRewriter`][exec]. It appends `uint3 ThreadIds : SV_DispatchThreadID` (and `SV_GroupThreadID`, `SV_GroupIndex`, `SV_GroupID` only when the body touches `GroupIds`/`GridIds`), and wraps the body in a bounds check, because a dispatch of `N` threads is rounded up to whole groups:

```hlsl
// shape emitted by GetHlslSourceInfo + ExecuteMethodRewriter.Compute
#define __GroupSize__get_X 64
#define __GroupSize__get_Y 1
#define __GroupSize__get_Z 1
cbuffer _ : register(b0) { uint __x; uint __y; uint __z; /* captured values */ }
RWStructuredBuffer<int> buffer : register(u0);
[NumThreads(__GroupSize__get_X, __GroupSize__get_Y, __GroupSize__get_Z)]
void Execute(uint3 ThreadIds : SV_DispatchThreadID)
{
    if (ThreadIds.x < __x && ThreadIds.y < __y && ThreadIds.z < __z) { buffer[ThreadIds.x] *= 2; }
}
```

For `IComputeShader<TPixel>` the `Pixel` rewriter changes the return type to `void`, turns each `return e;` into `__outputTexture[ThreadIds.xy] = e; return;`, binds `__outputTexture` at `u0`, and constant-folds `__z` to `1` ([`ExecuteMethodRewriter.cs`][exec]). A "pixel shader" in the DX12 package is therefore a compute shader over a 2D UAV — not a rasterizer stage.

### Bytecode: DXC inside the analyzer

[`DxcShaderCompiler.Compile`][dxc] calls `IDxcUtils::BuildArguments` with profile `cs_6_0` and `-Zpr` (row-major matrices), plus `-O0…-O3`, `-WX`, `-Gis`, `-all-resources-bound`, `-Qstrip_reflect` etc. according to `[CompileOptions]`. [`DxcLibraryLoader`][dxc-load] extracts `dxcompiler.dll` and `dxil.dll` for `x64`/`arm64` from the generator's own manifest resources, so the bytecode is produced on the developer's machine at build time. Compiler errors surface as `CMPS0046`; a shader without `[ThreadGroupSize]` is `CMPS0047` because "dynamic shader compilation is not supported". The generated `HlslBytecode` property returns a `ReadOnlyMemory<byte>` over a `ReadOnlySpan<byte> Data => [ … ]` literal — RVA static data, no allocation, no runtime compiler ([`…HlslBytecode.Syntax.cs`][gen-bc]).

### The generated descriptor

The generator adds `IComputeShaderDescriptor<T>` to the struct and implements it with `static abstract` members ([`IComputeShaderDescriptor{T}.cs`][descriptor]): `ThreadsX/Y/Z`, `ConstantBufferSize`, `IsStaticSamplerRequired`, `ResourceDescriptorRanges`, `HlslSource`, `HlslBytecode`, `LoadConstantBuffer<TLoader>` and `LoadGraphicsResources<TLoader>`. Dispatch (`GraphicsDevice.For<T>(x, y, z, in T shader)`, [`GraphicsDeviceExtensions.Dispatching.cs`][dispatch]) is then fully generic and reflection-free: it reads the static members of `T`, marshals the struct through the generated loader, and records a D3D12 dispatch.

> [!NOTE]
> `[AutoConstructor]`, the v2 generator that synthesised a field-initialising constructor, is gone at the pin (no matching file under `v3.0.0` or later); C# 12 primary constructors replaced it. Likewise there is no `IPixelShader` any more: the DX12 "pixel" form is `IComputeShader<TPixel>`, and the rasterizer-style one is `ID2D1PixelShader`.

### Direct2D pixel shaders

`ComputeSharp.D2D1` reuses the rewriter for [`ID2D1PixelShader`][d2d-iface] (`Float4 Execute()`), driven by attributes on the struct:

| Attribute                                 | Effect                                                                                                                                       |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| [`[D2DInputCount(n)]`][d2d-count]         | mandatory; `n` in `[0, 8]` (`CMPSD2D0035`) — emitted as `#define D2D_INPUT_COUNT n`                                                          |
| [`[D2DInputSimple(i)]`][d2d-simple]       | input `i` is sampled only at the current pixel (`D2D_INPUTi_SIMPLE`), which lets D2D link shaders together                                   |
| [`[D2DInputComplex(i)]`][d2d-complex]     | input `i` may be sampled anywhere (`D2D_INPUTi_COMPLEX`); the default                                                                        |
| [`[D2DShaderProfile(p)]`][d2d-profile]    | FXC profile from [`D2D1ShaderProfile`][d2d-prof-enum]: `PixelShader40Level91`, `…Level93`, `PixelShader40`, `PixelShader41`, `PixelShader50` |
| `[D2DRequiresScenePosition]`              | required when `D2D.GetScenePosition()` / `SampleInputAtPosition` is used (`CMPSD2D0045`)                                                     |
| [`[D2DEnableRuntimeCompilation]`][d2d-rt] | allows a shader with no profile, compiled at run time instead                                                                                |

The generated HLSL `#include`s Microsoft's `d2d1effecthelpers.hlsli` and calls its macros; the [`D2D`][d2d-intr] intrinsics class maps `GetInput` → `D2DGetInput`, `SampleInput` → `D2DSampleInput` and so on, and tags the complex-only ones with `[HlslD2DIntrinsicInputType(Complex)]` so that using `SampleInput` on a simple input is a compile-time error ([`D2DPixelShaderDescriptorGenerator.HlslSource.cs`][d2d-gen-src]). Bytecode comes from FXC (`D3DCompile`, [`D3DCompiler.cs`][d3dcompiler]), compiled twice — once with `D2D_FULL_SHADER` and once as an export function — so Direct2D can [link effect shaders][d2d-linking]. Build-time compilation happens only when a profile is given explicitly; otherwise the default is `PixelShader50` at run time ([`…HlslBytecode.cs`][d2d-gen-bc]).

---

## Execution model and stages

Three entry shapes, all reached through one interface per struct (`CMPS0042` forbids two):

- **Compute** — `IComputeShader.Execute()`, a 1/2/3-D grid of `[ThreadGroupSize]` groups ([`ThreadGroupSizeAttribute.cs`][tgs]). `DefaultThreadGroupSizes.X/Y/Z` mean 64 threads on that axis, `XY/XZ/YZ` mean 8×8, `XYZ` means 4×4×4. Dispatch IDs come from static classes (`ThreadIds`, `GroupIds`, `GridIds`, `GroupSize`, `DispatchSize`, plus normalized variants) usable only in the entry body (`CMPS0006`–`CMPS0009`, `CMPS0039`).
- **Pixel-like compute** — `IComputeShader<TPixel>.Execute()` returns the texel for `ThreadIds.xy`; still a compute shader.
- **D2D1 pixel** — `ID2D1PixelShader.Execute()`, a real pixel-shader stage run by Direct2D inside an effect graph.

No vertex, hull, domain, geometry, mesh, amplification or ray-tracing stage exists, and none can be expressed: the stage is a fixed interface, not an attribute on a function. For sparkles this is the important negative result — the "one struct, one `Execute`" model does not generalise to multi-stage pipelines whose stages share an interface block.

## Type system and generic programming

The shader vocabulary is a set of hand-generated (T4, `*.tt`) C# structs mirroring HLSL: `Int2…Int4`, `UInt*`, `Float*`, `Double*`, `Bool*`, and every `MxN` matrix of each. Lower-case aliases (`float4`, `int2`) are injected as global usings by `ComputeSharp.Core.SourceGenerators` (`GlobalUsingDirectivesGenerator`). Layout is explicit and HLSL-faithful: `Float4` is `StructLayout(Explicit, Size = 16)`, `Float3` is `Size = 12` ([`Float4.g.cs`][float4]) — unlike D's `__vector(float[3])`, which sparkles pads to 16 (`D9`).

`Bool` is a separate 4-byte struct wrapping an `int` ([`Bool.cs`][bool]) because C#'s `bool` is one byte and HLSL's is four; in constant buffers the generator always marshals booleans through `Bool` ([`ConstantBufferSyntaxProcessor.Generation.cs`][cb-gen]). Swizzles are properties (`XY`, `RGB`, `ZYX`, …) that return `ref *(Float2*)UndefinedData.Memory` on the CPU — a pointer into a dummy buffer — and become HLSL swizzles after rewriting.

Generic programming is the weak point. Shader types cannot be generic, nor nested in generic types (the generator returns early, [`ComputeShaderDescriptorGenerator.cs`][gen]); methods called from a shader must have source in the compilation (`CMPS0049`), which rules out library code shipped as binaries. User structs, their instance methods and constructors, static helpers, local functions, `const` values and static fields of primitive/vector/matrix types are all transpiled; interfaces with static-abstract members, generics over element types, and delegates are not translated as code (delegate-typed fields are accepted but map to an empty HLSL type, [`HlslKnownTypes.cs`][known-types-cs]). A D design with templates, CTFE and `static foreach` has strictly more compile-time power than this.

## Resources, interfaces and memory layout

Resource fields map one-to-one to HLSL objects and registers in declaration order:

| C# field type                                          | HLSL                                                           | Register |
| ------------------------------------------------------ | -------------------------------------------------------------- | -------- |
| `ConstantBuffer<T>`                                    | `cbuffer _name { T name[…]; }`                                 | `b1…`    |
| `ReadOnlyBuffer<T>`                                    | `StructuredBuffer<T>`                                          | `t0…`    |
| `ReadWriteBuffer<T>` (optionally `[GloballyCoherent]`) | `RWStructuredBuffer<T>` (`globallycoherent`)                   | `u0…`    |
| `ReadOnlyTexture{1,2,3}D<T>` / `<T, TPixel>`           | `Texture{1,2,3}D<T>` (normalized variant for `TPixel` formats) | `t…`     |
| `ReadWriteTexture{1,2,3}D<T>` / `<T, TPixel>`          | `RWTexture{1,2,3}D<T>`                                         | `u…`     |
| value fields (`float`, `Float4`, user structs, …)      | members of `cbuffer _ : register(b0)` after `__x/__y/__z`      | `b0`     |
| `static [GroupShared] T[]`                             | `groupshared T name[n or group size]`                          | —        |

A single static sampler (linear, mirror addressing) is bound at `s0` when any texture sampling is used (`IsStaticSamplerRequired`, [`IComputeShaderDescriptor{T}.cs`][descriptor]) — the same "one shared sampler" simplification sparkles made in `D7`.

The interesting part is **constant-buffer packing**. The C# struct's own layout is irrelevant: [`ConstantBufferSyntaxProcessor`][cb] computes HLSL `cbuffer` offsets field by field — pad to the type's alignment, never straddle a 16-byte register (`AlignmentHelper.AlignToBoundary(…, 16)`), start every nested struct on a 16-byte boundary, and give each row of a multi-row matrix its own register — and [`.Generation.cs`][cb-gen] emits a `file struct ConstantBuffer` with `[FieldOffset(n)]` for every leaf plus a `ConstantBufferMarshaller.FromManaged` that copies the user's fields into it. These are the [HLSL packing rules][packing] (≈ std140 without the array-stride rule). The total is pushed as D3D12 root constants, so [`ExcedeedComputeShaderDispatchDataSizeAnalyzer`][cb-size] reports `CMPS0041` when values plus resource descriptors exceed the 64-DWORD [root-signature limit][root-limits].

## Built-in library and intrinsics

[`Hlsl`][hlsl] is a static class of about 80 named HLSL intrinsic functions (78 distinct `[HlslIntrinsicName]` targets), each overload generated for every applicable scalar/vector/matrix type: arithmetic and transcendental math, `dot`/`cross`/`mul`/`transpose`/`determinant`, `lerp`/`smoothstep`/`saturate`, bit ops (`countbits`, `firstbithigh`, `reversebits`), conversions (`asfloat`, `f32tof16`), derivatives (`ddx[_coarse|_fine]`, `ddy…`, `fwidth`), `clip`, `abort`, the `Interlocked*` atomics, and the six memory barriers. Missing at the pin: every `Wave*`/`Quad*` operation, texture `Sample*`/`Gather*` methods beyond the implicit sampler path, and anything above SM 6.0.

**CPU behaviour is the key finding.** Value-returning intrinsics are `=> default;` ([`Hlsl.g.cs`][hlsl-g]); `void` ones and the dispatch-ID properties throw `InvalidExecutionContextException` ([`Hlsl.cs`][hlsl], [`Hlsl.Void.g.cs`][hlsl-void], [`ThreadIds.cs`][threadids]); vector operators such as `Float4.operator +` are also `=> default;` ([`Float4.g.cs`][float4]). Calling a ComputeSharp shader's `Execute()` on the CPU therefore silently computes zeros rather than failing. The library is a _syntax_ for HLSL with C# type checking, not an executable model of it.

## Control flow, memory model and restrictions

Control flow is HLSL's: `if`, `for`, `while`, `do`, `switch`, `break`, `continue`, `return` pass through; `foreach` is `CMPS0017`. Recursion has no generator diagnostic (the call-graph walk in [`ShaderSourceRewriter.cs`][ssr] only marks visited methods to terminate); it is left to DXC, which rejects recursive HLSL — so the error arrives as a `CMPS0046` compiler message rather than at the C# call site. There are no pointers, references or `unsafe` code in shader bodies (`CMPS0032`, `CMPS0035`), no managed objects (`CMPS0010`, `CMPS0031`), no exceptions, and no string literals (`CMPS0036`).

The memory model is D3D12's, exposed directly: `groupshared` via `[GroupShared]`, `globallycoherent` UAVs via `[GloballyCoherent]`, explicit `GroupMemoryBarrierWithGroupSync` and friends, `Interlocked*` atomics. Shader structs should be `readonly` (`CMPS0057`, a warning) because the struct is a value snapshot marshalled at dispatch.

## Compilation pipeline and targets

```text
C# syntax + semantic model ──(Roslyn incremental generator, at build)──▶ HLSL text
      HLSL ──DXC cs_6_0, -Zpr (embedded dxcompiler.dll)──▶ DXIL  ─▶ RVA byte[] in the assembly
D2D1: HLSL + d2d1effecthelpers.hlsli ──FXC ps_4_0_level_9_1…ps_5_0 (×2: full + export)──▶ DXBC
```

One target per package, both Microsoft-only: DXIL for D3D12, DXBC for Direct2D. There is no SPIR-V, Metal, GLSL or WGSL path and no plan for one in the tree; the generator's output is not an IR but HLSL _text_, which ties every feature to what DXC/FXC accept. The descriptor also keeps the HLSL source (`HlslSource`) for reflection/debugging, and `ComputeSharp.Dxc` adds run-time reflection services. Because DXC is loaded from Windows DLLs inside the analyzer, building shaders requires a Windows build host (not verified whether non-Windows builds degrade to a diagnostic or fail; [`DxcLibraryLoader.cs`][dxc-load] only selects `x64`/`arm64` resources).

## Host integration and CPU execution

Host integration is the project's strongest side. A shader is a value: constructing it captures inputs, `GraphicsDevice.For` dispatches it, `ComputeContext` batches several dispatches with barriers, and `PixelShaderEffect<T>` in `ComputeSharp.D2D1.WinUI/Uwp` makes a D2D1 shader a Win2D effect with generated property accessors. Every piece of binding metadata (`ResourceDescriptorRanges`, constant-buffer size, thread counts) is a compile-time constant on the type, so dispatch involves no reflection and no runtime shader compilation for DX12.

CPU execution is outsourced: there is no interpreter, no per-thread emulation of barriers or group-shared memory in ComputeSharp itself. Without a GPU, `GetDefault()` returns a [WARP][warp] device and the same DXIL runs in Microsoft's software rasterizer. That gives bit-for-bit "same program" execution on CPU — but only on Windows, only through D3D12, and with no way to step through the C# source. Contrast [ILGPU][ilgpu], whose CPU accelerator runs the kernel's IL with emulated groups and barriers.

---

## Lessons for sparkles:shaders

- **Avoid: stub intrinsics that return `default` on the host.** ComputeSharp's `Float4 + Float4` is `default` on the CPU — a silent wrong answer. sparkles' contract is the opposite (`SHV7`: host and device agree within `D12`), and every new built-in must keep a real CPU twin or be **unavailable** on the host (a compile error, like `SHV8`'s device-only sampling), never a zero.
- **Adopt: generate layout, don't trust the host struct.** ComputeSharp computes each constant-buffer member's offset from the target's packing rules and emits a marshaller with explicit offsets. A D `@uniformBlock` lowering should do the same with CTFE — compute std140/std430/scalar offsets per target, emit a packed shadow struct and a `toBlock` copy — instead of requiring the D struct's natural layout to match (it does not for `vec3`, `D9`).
- **Adopt: one diagnostic per rejected construct, with a stable ID.** `HlslSourceRewriter.Diagnostics.cs` maps each forbidden C# node to its own ID and message (64 shipped `CMPS` IDs, 86 `CMPSD2D`). The LDC fork's dcompute semantic pass should likewise give each refusal a stable, documented code that tests can assert, and sparkles' conformance corpus should hold one negative case per code.
- **Match: compile-time binding metadata on the type.** `IComputeShaderDescriptor<T>`'s `static abstract` members are D's natural idiom: a template or `enum` members generated per entry point (thread counts, bindings, block size, the SPIR-V/GLSL blob) let the host side dispatch with no reflection, and let a CPU simulator read the same metadata.
- **Adopt: bounds-check the grid in the generated entry.** The `ThreadIds.x < __x` guard plus a dispatch size passed as root constants makes "dispatch exactly N items" safe with any group size; a sparkles compute stage should synthesise the same guard rather than leave it to each author.
- **Avoid: renaming reserved identifiers silently** (`__reserved__name`). It keeps compilation working but breaks name-based binding from the host; sparkles' fork rejects reserved and translator-hostile names with a diagnostic, which is the right choice for an interface that GLSL host code addresses by name.
- **Avoid: the "source must be in this compilation" rule.** Syntax-tree transpilation cannot see into binaries, so libraries cannot share shader code except as source packages (`CMPS0049`). Compiling D through LDC to LLVM IR has no such limit; keep it that way rather than adopting a source-to-source front end.
- **Avoid: one fixed interface per stage.** The `Execute()`-on-a-struct model cannot express vertex→fragment interfaces, mesh outputs or multi-entry modules. sparkles' function-level stage UDAs (`@fragment`, future `@vertex`/`@compute`) are the more general shape.

## Strengths

- **Production proven** at scale (Microsoft Store, Paint.NET) with a very low barrier: a `partial struct`, two attributes, one dispatch call.
- **No runtime compiler** for DX12: DXIL is produced at build time and embedded as RVA data; dispatch is reflection-free and AOT-friendly.
- **Excellent diagnostics**: 150 shipped analyzer IDs, errors at the offending C# node, IDE squiggles while typing, code fixers for missing attributes.
- **Correct, generated constant-buffer packing** and root-signature size checks, so host/device layout mismatches cannot happen.
- **Direct2D integration** that turns a C# struct into a linkable D2D effect, with simple/complex input semantics checked at compile time.

## Weaknesses

- **Windows and Microsoft APIs only**: D3D12 + DXIL, Direct2D + DXBC; no SPIR-V, Vulkan, Metal or WGSL; build host needs the embedded Windows DXC.
- **No CPU semantics**: intrinsics and vector operators return `default` or throw on the host; CPU execution means WARP, not the C# code.
- **Compute and D2D pixel only**: no graphics pipeline stages, no wave/subgroup intrinsics, SM 6.0 ceiling for DX12.
- **Weak generics**: shaders cannot be generic; callees need source in the same compilation; text-to-text transpilation inherits every HLSL limit and reports some errors (recursion) only through DXC.
- **Name mangling** (`__reserved__…`) and implicit registers make the generated interface hard to address from hand-written host code.

## Key design decisions and trade-offs

| Decision                                                               | Rationale                                                                                | Trade-off                                                                                   |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Transpile C# syntax (with semantic model) to HLSL text                 | Roslyn generators see syntax, not IL; HLSL is the native input to DXC/FXC                | Only source in the compilation is translatable (`CMPS0049`); every HLSL limit leaks through |
| Shader = `partial struct` implementing one interface                   | Fields are inputs, `Execute` is the entry; fits C# value semantics and dispatch generics | No multi-stage pipelines, no multiple entry points per type                                 |
| Compile with embedded DXC/FXC at build time                            | No compiler on end-user machines; errors at build time; AOT-friendly RVA bytecode        | Windows build hosts; DX12 path has no dynamic compilation (`CMPS0047`)                      |
| Generated `static abstract` descriptor (`IComputeShaderDescriptor<T>`) | Reflection-free, generic dispatch; metadata is compile-time constant                     | Requires C# 11+ static abstracts; one more generated surface to keep stable                 |
| Generated constant-buffer packing and marshaller                       | User structs keep C# layout; HLSL rules applied exactly once, by the generator           | A copy per dispatch; 64-DWORD root-constant ceiling (`CMPS0041`)                            |
| Intrinsics as stubs (`default` / throw) on the CPU                     | Keeps the C# API small and lets the type checker validate shader code                    | Host calls compute nonsense silently; no CPU reference to test against                      |
| CPU fallback via WARP, not an emulator                                 | Exact same DXIL semantics; zero maintenance                                              | Windows-only; no source-level debugging; no portable reference executor                     |
| Rename HLSL-keyword identifiers to `__reserved__name`                  | User code never fails on a name clash                                                    | Generated names diverge from source names                                                   |

---

## Sources

- [Sergio0694/ComputeSharp — repository][repo]; [wiki][wiki]; [author's thesis (PDF)][thesis]
- [`README.md`][readme-root] — goals, production users; [`src/ComputeSharp/README.md`][readme-core] — quick start, WARP fallback; [`src/ComputeSharp.D2D1/README.md`][readme-d2d]
- [`build/Directory.Build.props`][props] — package version; [`src/ComputeSharp/ComputeSharp.csproj`][csproj] — target framework
- Generator: [`ComputeShaderDescriptorGenerator.cs`][gen], [`…HlslSource.cs`][gen-src], [`…HlslBytecode.Syntax.cs`][gen-bc], [`ExecuteMethodRewriter.cs`][exec]
- Shared HLSL rewriting: [`HlslSourceRewriter.cs`][hsr], [`HlslSourceRewriter.Diagnostics.cs`][hsr-diag], [`ShaderSourceRewriter.cs`][ssr], [`HlslKnownTypes.cs`][known-types], [`HlslKnownKeywords.cs`][keywords]
- Layout: [`ConstantBufferSyntaxProcessor.cs`][cb], [`ConstantBufferSyntaxProcessor.Generation.cs`][cb-gen], [`ExcedeedComputeShaderDispatchDataSizeAnalyzer.cs`][cb-size]
- Bytecode: [`HlslBytecodeSyntaxProcessor.cs`][bc-proc], [`DxcShaderCompiler.cs`][dxc], [`DxcLibraryLoader.cs`][dxc-load], [`D3DCompiler.cs`][d3dcompiler]
- Diagnostics: [`DiagnosticDescriptors.cs`][diag], [`AnalyzerReleases.Shipped.md`][releases], [D2D1 `AnalyzerReleases.Shipped.md`][d2d-releases]
- API surface: [`IComputeShader.cs`][icompute], [`IComputeShader{TPixel}.cs`][icompute-pixel], [`IComputeShaderDescriptor{T}.cs`][descriptor], [`ThreadGroupSizeAttribute.cs`][tgs], [`GeneratedComputeShaderDescriptorAttribute.cs`][gen-attr], [`GroupSharedAttribute.cs`][groupshared], [`ThreadIds.cs`][threadids], [`GraphicsDeviceExtensions.Dispatching.cs`][dispatch]
- Vocabulary: [`Hlsl.cs`][hlsl], [`Hlsl.g.cs`][hlsl-g], [`Hlsl.Void.g.cs`][hlsl-void], [`Float4.g.cs`][float4], [`Bool.cs`][bool]
- D2D1: [`ID2D1PixelShader.cs`][d2d-iface], [`D2DInputCountAttribute.cs`][d2d-count], [`D2DInputSimpleAttribute.cs`][d2d-simple], [`D2DInputComplexAttribute.cs`][d2d-complex], [`D2DShaderProfileAttribute.cs`][d2d-profile], [`D2D1ShaderProfile.cs`][d2d-prof-enum], [`D2DEnableRuntimeCompilation.cs`][d2d-rt], [`D2D.cs`][d2d-intr], [`D2DPixelShaderDescriptorGenerator.HlslSource.cs`][d2d-gen-src], [`…HlslBytecode.cs`][d2d-gen-bc]
- Microsoft Learn: [WARP][warp], [HLSL constant-buffer packing rules][packing], [D3D12 root-signature limits][root-limits], [Direct2D effect shader linking][d2d-linking], [Direct2D HLSL helpers][d2d-helpers], [Roslyn source generators][srcgen]
- Related: [HLSL][hlsl-doc] · [DXC][dxc-doc] · [ILGPU][ilgpu] · [TypeGPU][typegpu] · [rust-gpu][rust-gpu] · [dcompute][dcompute] · [Concepts][concepts] · [Comparison][comparison] · [Catalog index][index] · [`sparkles:shaders` SPEC][spec] · [decisions][decisions]

<!-- References -->

[repo]: https://github.com/Sergio0694/ComputeSharp/tree/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a
[wiki]: https://github.com/Sergio0694/ComputeSharp/wiki
[license]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/LICENSE
[thesis]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/docs/ComputeSharp.pdf
[readme-root]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/README.md
[readme-core]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp/README.md
[readme-d2d]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.D2D1/README.md
[props]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/build/Directory.Build.props
[csproj]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp/ComputeSharp.csproj
[gen]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGenerators/ComputeShaderDescriptorGenerator.cs
[gen-src]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGenerators/ComputeShaderDescriptorGenerator.HlslSource.cs
[gen-bc]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGenerators/ComputeShaderDescriptorGenerator.HlslBytecode.Syntax.cs
[exec]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGenerators/SyntaxRewriters/ExecuteMethodRewriter.cs
[hsr]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGeneration.Hlsl/SyntaxRewriters/HlslSourceRewriter.cs
[hsr-diag]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGeneration.Hlsl/SyntaxRewriters/HlslSourceRewriter.Diagnostics.cs
[ssr]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGeneration.Hlsl/SyntaxRewriters/ShaderSourceRewriter.cs
[known-types]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGeneration.Hlsl/Mappings/HlslKnownTypes.cs
[known-types-cs]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGenerators/Mappings/HlslKnownTypes.cs
[keywords]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGeneration.Hlsl/Mappings/HlslKnownKeywords.cs
[cb]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGeneration.Hlsl/SyntaxProcessors/ConstantBufferSyntaxProcessor.cs
[cb-gen]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGeneration.Hlsl/SyntaxProcessors/ConstantBufferSyntaxProcessor.Generation.cs
[cb-size]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGenerators/Diagnostics/Analyzers/ExcedeedComputeShaderDispatchDataSizeAnalyzer.cs
[bc-proc]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGeneration.Hlsl/SyntaxProcessors/HlslBytecodeSyntaxProcessor.cs
[dxc]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGenerators/Dxc/DxcShaderCompiler.cs
[dxc-load]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGenerators/Dxc/DxcLibraryLoader.cs
[d3dcompiler]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.D2D1/Shaders/Translation/D3DCompiler.cs
[diag]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGenerators/Diagnostics/DiagnosticDescriptors.cs
[releases]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.SourceGenerators/AnalyzerReleases.Shipped.md
[d2d-releases]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.D2D1.SourceGenerators/AnalyzerReleases.Shipped.md
[icompute]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp/Interfaces/IComputeShader.cs
[icompute-pixel]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp/Interfaces/IComputeShader%7BTPixel%7D.cs
[descriptor]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp/Interfaces/Descriptors/IComputeShaderDescriptor%7BT%7D.cs
[tgs]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp/Attributes/ThreadGroupSizeAttribute.cs
[gen-attr]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp/Attributes/GeneratedComputeShaderDescriptorAttribute.cs
[groupshared]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp/Attributes/GroupSharedAttribute.cs
[threadids]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp/Dispatch/ThreadIds.cs
[dispatch]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp/Graphics/Extensions/GraphicsDeviceExtensions.Dispatching.cs
[hlsl]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.Core/Intrinsics/Hlsl.cs
[hlsl-g]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.Core/Intrinsics/Hlsl.g.cs
[hlsl-void]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.Core/Intrinsics/Hlsl.Void.g.cs
[float4]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.Core/Primitives/Float/Float4.g.cs
[bool]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.Core/Primitives/Bool/Bool.cs
[d2d-iface]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.D2D1/Interfaces/ID2D1PixelShader.cs
[d2d-count]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.D2D1/Attributes/D2DInputCountAttribute.cs
[d2d-simple]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.D2D1/Attributes/D2DInputSimpleAttribute.cs
[d2d-complex]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.D2D1/Attributes/D2DInputComplexAttribute.cs
[d2d-profile]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.D2D1/Attributes/D2DShaderProfileAttribute.cs
[d2d-prof-enum]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.D2D1/Attributes/Enums/D2D1ShaderProfile.cs
[d2d-rt]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.D2D1/Attributes/D2DEnableRuntimeCompilation.cs
[d2d-intr]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.D2D1/Intrinsics/D2D.cs
[d2d-gen-src]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.D2D1.SourceGenerators/D2DPixelShaderDescriptorGenerator.HlslSource.cs
[d2d-gen-bc]: https://github.com/Sergio0694/ComputeSharp/blob/40dbe40de0b1eafb570e2af43f78bcdbffdcc00a/src/ComputeSharp.D2D1.SourceGenerators/D2DPixelShaderDescriptorGenerator.HlslBytecode.cs
[warp]: https://learn.microsoft.com/windows/win32/direct3darticles/directx-warp
[packing]: https://learn.microsoft.com/windows/win32/direct3dhlsl/dx-graphics-hlsl-packing-rules
[root-limits]: https://learn.microsoft.com/windows/win32/direct3d12/root-signature-limits
[d2d-linking]: https://learn.microsoft.com/windows/win32/direct2d/effect-shader-linking
[d2d-helpers]: https://learn.microsoft.com/windows/win32/direct2d/hlsl-helpers
[srcgen]: https://learn.microsoft.com/dotnet/csharp/roslyn-sdk/source-generators-overview
[hlsl-doc]: ./hlsl.md
[dxc-doc]: ./dxc.md
[ilgpu]: ./ilgpu.md
[typegpu]: ./typegpu.md
[rust-gpu]: ./rust-gpu.md
[dcompute]: ./dcompute.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
[spec]: ../../specs/shaders/SPEC.md
[decisions]: ../../specs/shaders/decisions.md
