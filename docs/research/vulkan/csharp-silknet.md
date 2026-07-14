# Silk.NET (C#)

The .NET ecosystem's mainline Vulkan binding: a `vk.xml`-generated, `unsafe`-struct, function-pointer-based thin layer maintained under the .NET Foundation, whose safety story is a handful of opt-in typed conveniences (typed `pNext` chains, extension objects) layered over an otherwise raw API — the survivor of an ecosystem contest that the genuinely idiomatic wrapper, [SharpVk](#sharpvk-the-idiomatic-predecessor-that-lost), lost.

| Field          | Value                                                                                                 |
| -------------- | ----------------------------------------------------------------------------------------------------- |
| Language       | C# (.NET Standard 2.0; .NET 5+ for the function-pointer fast path)                                    |
| License        | MIT                                                                                                   |
| Repository     | [dotnet/Silk.NET][repo]                                                                               |
| Documentation  | [dotnet.github.io/Silk.NET][docs] · [NuGet `Silk.NET.Vulkan`][nuget]                                  |
| Category       | Thin + typed chains (raw binding with typed-chain conveniences over a thin core)                      |
| First release  | `v1.0.0-preview` August 4, 2019; `v1.0.0` March 6, 2020; `v2.0.0` (SilkTouch rewrite) January 2, 2021 |
| Latest release | `v2.23.0` (January 22, 2026); 2.x is in ad-hoc maintenance while 3.0 is rewritten                     |

> [!NOTE]
> Silk.NET covers far more than Vulkan (OpenGL, DirectX, OpenCL, OpenAL, OpenXR, GLFW, SDL, WebGPU, windowing, input, math). This deep-dive examines only the `Silk.NET.Vulkan` package family and the [SilkTouch](#binding-generation--api-coverage) machinery underneath it, with [SharpVk](#sharpvk-the-idiomatic-predecessor-that-lost) as historical contrast.

---

## Overview

### What it solves

C# sits in an awkward spot for Vulkan: it has a GC and a JIT, but also true value types, raw pointers under `unsafe`, blittable struct layout control, and (since C# 9 / .NET 5) first-class native function pointers (`delegate* unmanaged`). The historical pain was the _call mechanism_: classic `[DllImport]` P/Invoke cannot reach Vulkan's per-instance/per-device function pointers at all (everything past `vkGetInstanceProcAddr` must be loaded dynamically), and `Marshal.GetDelegateForFunctionPointer` adds a managed-delegate indirection plus marshalling stubs on every call.

Silk.NET's answer is a generator pipeline that emits **blittable `unsafe` structs straight from [`vk.xml`][vkxml]** and a Roslyn source generator — **SilkTouch** — that fills in every API method body with a **direct function-pointer invocation** (`calli` in IL terms) through a generated VTable that lazily resolves and caches each entry point. The result is a 1:1, pointer-level Vulkan API surface (`Vk.CreateInstance(InstanceCreateInfo*, AllocationCallbacks*, Instance*)`) plus generated ergonomic overloads (`ref readonly` / `out` / `Span`-based), with no managed wrapper objects on the call path. In spirit it is the C# equivalent of [`ash`][ash] (Rust) or [`erupted`][erupted] (D): a loader plus typed raw declarations, not a safety layer.

### Design philosophy

Performance-first, measured at the JIT-assembly level. From the repository README ([`README.md`][readme]):

> _"Having poured lots of hours into examining generated C# code and its JIT assembly, you can count on us to deliver blazing fast bindings with negligible overhead induced by Silk.NET!"_

and, on staying current:

> _"With an efficient bindings regeneration mechanism, we are committed to ensuring our bindings reflect the latest specifications with frequent updates generated straight from the upstream sources."_

Safety, by contrast, is opt-in and local: the one place Silk.NET invests real type-system effort is the [`pNext` structure-chain subsystem](#type-system-techniques), where `vk.xml`'s `structextends` metadata is compiled into generic interface constraints. Everything else — synchronization, handle lifetime, valid usage — is the caller's problem, exactly as in C. The project is currently mid-transition: the README states _"We are currently hard at work on Silk.NET 3.0 - the latest and greatest Silk.NET, laser-focused on addressing pain points and reimagining how C# bindings libraries can be done"_, with 2.x explicitly in volunteer-maintenance mode ([`README.md`][readme]).

---

## How it works

### Binding generation & API coverage

Silk.NET 2.x bindings are produced by an in-repo generator, `Silk.NET.BuildTools` ([`src/Core/Silk.NET.BuildTools`][buildtools]), driven by a declarative [`generator.json`][generatorjson] at the repo root. The Vulkan task consumes the Khronos registry directly:

```json
// generator.json — the Vulkan profile (abridged)
{
  "profileName": "Vulkan",
  "sources": [
    "https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/7f61271fa6b6e7d71bf56dbc3a6165cda43bd8cb/xml/vk.xml"
  ],
  "mode": "ConvertConstruct",
  "converter": { "reader": "vk", "constructor": "vk", "className": "Vk" },
  "prefix": "vk"
}
```

A dedicated `vk` reader parses `vk.xml` (types, commands, enums, extensions, `structextends`, `len` attributes), a converter/"bakery" stage normalizes profiles, and an overloader stage mass-produces ergonomic permutations. The committed output is checked into the tree (`Vk.gen.cs`, `Structs/*.gen.cs`, `Enums/*.gen.cs`), so the published package is reproducible and diffable. Each command becomes a **partial method declaration** carrying registry metadata as attributes — note `Count` and `Flow` (the `len` and in/out direction from `vk.xml`) surviving as decoration:

```csharp
// src/Vulkan/Silk.NET.Vulkan/Vk.gen.cs
[NativeApi(EntryPoint = "vkCreateInstance", Convention = CallingConvention.Winapi)]
public unsafe partial Result CreateInstance(
    [Count(Count = 0), Flow(FlowDirection.In)] InstanceCreateInfo* pCreateInfo,
    [Count(Count = 0), Flow(FlowDirection.In)] AllocationCallbacks* pAllocator,
    [Count(Count = 0), Flow(FlowDirection.Out)] Instance* pInstance);
```

The same entry point is emitted in several overloads (`pointer`, `ref readonly`, `out`), so user code rarely needs manual pinning. The **SilkTouch** Roslyn source generator (`src/Core/Silk.NET.SilkTouch`, [`NativeApiGenerator.cs`][natgen]) then fills in every `[NativeApi]` partial body at the consumer's compile time. Its design (per the November 2020 blog post [_SilkTouch: Invokes & Marshalling_][silktouch-blog]) is an ASP.NET-Core-style middleware pipeline of marshallers (string allocation, span pinning, bool conversion, delegate marshalling — see [`Middlewares/`][middlewares]) around a core that _"generates a `calli` instruction using function pointers"_. [`VTableGeneration.cs`][vtable] emits one `System.IntPtr` slot field per entry point, populated lazily via `_ctx.GetProcAddress` and reused on every subsequent call — so `vkGetInstanceProcAddr`/`vkGetDeviceProcAddr` are hit once per function, not per call.

Coverage is essentially total: core Vulkan plus every registry extension, with vendor extension functions generated into separate per-tag packages (`Silk.NET.Vulkan.Extensions.KHR`, `.Extensions.EXT`, …) as classes loaded at runtime (e.g. `KhrSwapchain`) — see [Type-system techniques](#type-system-techniques). Video headers (`vk_video.h`) are handled by a parallel ClangSharp-based C++ path in BuildTools.

**The 3.0 rewrite** abandons both the bespoke `vk.xml` reader and the source-generator delivery. The design proposal ([_Generation of Library Sources and PInvoke Mechanisms_][proposal]) delegates header parsing to the **ClangSharp P/Invoke generator** with a "mod" system for metadata injection, and **pre-generates** code instead of generating in the consumer's build — the proposal concedes the 2.x approach _"was too bleeding-edge"_ and leaned on an immature understanding of source generators. 3.0 also replaces the overload explosion with implicit-converting pointer wrapper types (`Ref`, `Ptr` and friends). Notably, moving from `vk.xml` to Clang-parsed _headers_ **loses** registry-only metadata (`len`, `externsync`, `structextends` must be re-injected as mods) — a regression worth remembering when designing a D generator.

### Handle lifetime & ownership model

There is none, by design. Every dispatchable and non-dispatchable handle is a plain blittable struct around the raw value:

```csharp
// src/Vulkan/Silk.NET.Vulkan/Structs/Instance.gen.cs
[NativeName("Name", "VkInstance")]
public unsafe partial struct Instance
{
    public nint Handle;
}
```

No `IDisposable`, no finalizer, no ownership tracking, no use-after-destroy detection: forgetting `DestroyInstance` leaks, double-destroying is UB, and a copied `Instance` struct is just a copied integer. The only stateful object is the **`Vk` API class itself** ([`Vk.cs`][vkcs]), which is a _function-table holder_, not a resource owner: `Vk.GetApi()` loads the loader, and assigning `vk.CurrentInstance` / `vk.CurrentDevice` swaps the active VTable so subsequent calls dispatch through instance- or device-level function pointers (device-level loading skips the instance dispatch trampoline, the same optimization [`vulkan-hpp`][vulkan-hpp]'s dispatchers and [`erupted`][erupted]'s `loadDeviceLevelFunctions` perform). VTables are cached in a `ConcurrentDictionary` keyed by `(Instance?, Device?)`, and `CloneWith()` produces an additional `Vk` view sharing those caches for multi-device/multi-threaded setups. A `// TODO` in `Vk.cs` already marks this dictionary machinery for removal in 3.0.

### Synchronization safety

Not modeled — full stop, and the absence is informative for a "mainstream-platform thin binding" data point. `vkCmdPipelineBarrier2`, semaphores, fences, timeline semaphores, and queue-family ownership transfers are exposed as raw generated calls with raw generated structs; nothing distinguishes them from any other entry point. There is no render graph, no automatic barrier placement, no typed encoding of pipeline stages vs. access flags (both are plain `[Flags]` enums, so `srcStageMask`/`srcAccessMask` mismatches compile fine), and no `Send`/`Sync`-style thread-affinity typing — C# has no such mechanism to offer.

The `externsync` attribute in `vk.xml` does **not** survive generation: it appears neither as an attribute on parameters (the way `Count`/`Flow` do) nor in documentation comments — most generated members carry the placeholder `/// <summary>To be documented.</summary>`. A user cannot tell from the binding that `vkQueueSubmit` requires external synchronization of the `VkQueue` while `vkGetDeviceQueue` does not. Ironically, the binding layer itself is internally thread-safe where _it_ has shared state: `Vk.cs` guards its extension-presence caches with a `ReaderWriterLockSlim` and its VTable/physical-device caches with `ConcurrentDictionary`/`Interlocked.CompareExchange` — careful engineering spent on the loader's own hash maps, with zero carried over to the API's synchronization contract. Correctness is delegated wholesale to the validation layers and synchronization validation (see [`sync-validation`][sync-validation]).

### Type-system techniques

The flagship technique — and the part most transferable to a D design — is the **typed `pNext` chain subsystem**, where `vk.xml`'s `structextends` metadata is compiled into a three-interface hierarchy ([`IChainable.cs`][ichainable], [`IChainStart.cs`][ichainstart], [`IExtendsChain.cs`][iextends]):

```csharp
// src/Vulkan/Silk.NET.Vulkan/IExtendsChain.cs
/// <summary>
/// Marks a chainable struct indicating which chain this type extends.
/// </summary>
public interface IExtendsChain<out TChain> : IChainable
    where TChain : unmanaged, IChainable
{ }
```

Every generated struct that the registry says may start a chain implements `IChainStart`; every struct with a `structextends` entry implements one `IExtendsChain<TChain>` **per legal parent**:

```csharp
// src/Vulkan/Silk.NET.Vulkan/Structs/PhysicalDeviceVulkan12Features.gen.cs
public unsafe partial struct PhysicalDeviceVulkan12Features :
    IExtendsChain<PhysicalDeviceFeatures2>,
    IExtendsChain<PhysicalDeviceFeatures2KHR>,
    IExtendsChain<DeviceCreateInfo>
{ ... }
```

The extension methods in [`ChainExtensions.cs`][chainext] then make illegal chains unrepresentable at compile time: `chain.AddNext(out TNext next)` is constrained `where TNext : unmanaged, IExtendsChain<TChain>`, so attaching `PhysicalDeviceVulkan12Features` to a `BufferCreateInfo` chain is a compile error. The methods also auto-set every `SType` (via [`IStructuredType`][istructured]`.StructureType()`, which _"also ensures it is set to the correct value"_) and splice `PNext` pointers. The layout contract is documented on `IChainable` itself:

> _"Note that any structure marked `IChainable` must start with a `StructureType` and a `void*` field, in that order. This is so that a pointer to it can be coerced to a pointer to a `BaseInStructure`."_ — [`IChainable.cs`][ichainable]

A deliberate escape hatch exists for registry gaps: parallel `*Any` methods constrained only on `IChainable`, documented as _"The `Any` versions of chain methods do not validate that items belong in the chain, this is useful for situations where the specification does not indicate required chain constraints."_ ([`ChainExtensions.cs`][chainext]). On top of the by-`ref` stack-based extension methods sits a managed `Chain` class family ([`Chain.cs`][chaincs], T4-generated arities in `Chain.g.cs`) that owns a single contiguous unmanaged allocation for a whole chain — convenient, heap-allocating, `IDisposable`.

Beyond chains, the typing is modest:

- **Distinct handle structs** (`Instance`, `Buffer`, `DeviceMemory`, …) prevent cross-handle confusion that raw `ulong`s would allow — but there is no phantom/branding to distinguish handles from different devices, and no linear/affine ownership (C# cannot express it).
- **Typed enums and `[Flags]` bitmasks** from the registry; `Bool32` wraps `VkBool32`.
- **Extension capability typing, runtime-checked:** extension functions live in separate classes (`KhrSwapchain`, `ExtDebugUtils`) obtained via `vk.TryGetDeviceExtension(instance, device, out KhrSwapchain ext)` — possessing the object is weak evidence the extension was loaded. It is advisory only: [`Vk.cs`][vkcs]'s `IsExtensionPresent` warns _"This function doesn't check that the extension is enabled — you will get an error later on if you attempt to call an extension function from an extension that isn't loaded."_
- **Builder typestate, lifetimes, branded types: absent.** Struct initialization uses generated constructors with optional parameters that default `SType` correctly — the C# analogue of designated initializers, not a typestate builder.

### Overhead & escape hatches

The overhead story is the project's calling card, and it is genuinely thin for a GC'd-language binding:

| Cost center           | Silk.NET 2.x answer                                                                                                                                       |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Call dispatch         | SilkTouch-generated direct function-pointer invocation (`calli`); no managed delegates, no reflection, no `DllImport` stubs                               |
| Function resolution   | One `IntPtr` slot per entry point in a generated VTable, lazily filled via `GetProcAddress`, then cached ([`VTableGeneration.cs`][vtable])                |
| Struct marshalling    | None for Vulkan structs — all blittable `unsafe` structs, identical layout to C; pointer overloads pass straight through                                  |
| Convenience overloads | `ref`/`out`/`Span` overloads pin or take refs; string parameters allocate/copy via `SilkMarshal` (avoidable by using `byte*` overloads)                   |
| Chain helpers         | By-`ref` `ChainExtensions` work on stack structs (no allocation); the managed `Chain` class allocates one unmanaged block + a managed wrapper             |
| Loader bookkeeping    | `ConcurrentDictionary` VTable cache and `ReaderWriterLockSlim`-guarded extension caches — touched on context switches and extension queries, not per call |

Residual costs are the JIT/GC platform itself (a `cli/calli` transition still erects a P/Invoke frame; .NET cannot inline across the native boundary) and the convenience-overload marshalling when chosen. Escape hatches are trivially available because the floor _is_ raw: every function has a pure-pointer overload, every handle exposes its `Handle` field for interop with other libraries, and `Vk` can be constructed over a custom `INativeContext` (e.g. a `LamdaNativeContext` wrapping someone else's `vkGetInstanceProcAddr`), which is how Silk.NET interoperates with externally created instances. The unusual direction of the escape hatch is worth noting: in [`Vulkano`][vulkano]-style wrappers you escape _down_ to raw handles; in Silk.NET you opt _up_ into the typed chain helpers.

### Error handling & validation integration

Vulkan's `VkResult` is exposed as the `Result` enum and returned **raw** — no exceptions, no `Expected`-style sum type, no `[[nodiscard]]` analogue; an ignored error is silently ignored (C#'s unused-return warning does not apply to enum returns). User code conventionally writes a `ThrowIfFailed`-style helper or pattern-matches. This is the polar opposite of [SharpVk](#sharpvk-the-idiomatic-predecessor-that-lost), which translated every non-success `VkResult` into a thrown `SharpVkException`.

Validation integration is "bring your own layers": the bindings expose `VK_EXT_debug_utils` (typed `PfnDebugUtilsMessengerCallbackEXT` function-pointer wrappers, `ExtDebugUtils` extension class) so applications can register messenger callbacks, and Silk.NET ships a `Silk.NET.Vulkan.SwiftShader.Native` package (a bundled CPU ICD) useful for CI hosts without GPUs. There is no binding-level valid-usage checking of any kind; the [Khronos validation layers][sync-validation] are the assumed development-time backstop.

---

## SharpVk: the idiomatic predecessor that lost

[FacticiusVir/SharpVk][sharpvk] (2016–2019, MIT) was the earlier, opposite bet: an **idiomatic** C# Vulkan wrapper, also generated from `vk.xml`, that modeled each handle as a **managed class** with instance methods (`device.CreateBuffer(...)` returning a `Buffer` object), hid pointers behind marshalling glue, translated `VkResult` into thrown `SharpVkException`s, and even bundled a LINQ-to-SPIR-V experiment ("Shanq"). It is the C# analogue of what [`Vulkano`][vulkano] is to [`ash`][ash] — minus the synchronization tracking, which SharpVk never attempted.

It is effectively abandoned: the last release (`0.4.2`) dates to January 2018, the last push to December 2022, and the repo (156 stars) never reached Vulkan 1.2 coverage. The failure mode is instructive for any "make it idiomatic" design:

- **Per-call marshalling cost.** Class-per-handle plus managed↔native translation on every call put allocations and copies on the hottest path of an API whose entire premise is CPU-overhead elimination.
- **Generator treadmill.** An idiomatic surface multiplies the per-`vk.xml`-release maintenance: every new extension needs hand-tuned shaping decisions, where a thin generator just re-runs. A volunteer project could not keep up; Silk.NET's "regenerate from upstream `main`" pipeline could.
- **The ecosystem chose thin+fast.** Engine-minded .NET users (Stride, Veldrid-adjacent, evergine) standardized on raw-style bindings (Silk.NET, or `Vortice.Vulkan`) and built their own abstractions above, exactly mirroring Rust's drift from `vulkano` toward `ash`.

---

## Strengths

- **Negligible call overhead for a managed language**: SilkTouch's `calli`-based dispatch through a cached VTable is the measured-at-the-JIT-assembly design the README advertises; no delegates or reflection on the call path.
- **Typed `pNext` chains are a genuine innovation**: `IChainStart`/`IExtendsChain<TChain>` mechanically compile `vk.xml` `structextends` into generic constraints, making invalid chains a compile error while auto-maintaining `SType`/`PNext` — with a documented `*Any` escape hatch.
- **Total, fast-refreshing coverage**: bindings regenerate from Khronos `main`, extensions included, with checked-in diffable output.
- **Raw floor always available**: pointer overloads, public `Handle` fields, and custom `INativeContext` make interop with external Vulkan code trivial.
- **Institutional backing**: .NET Foundation project under the `dotnet` org — unusual longevity insurance for a bindings library.
- **Ecosystem winner**: the de-facto standard .NET Vulkan binding, validated against the abandoned idiomatic alternative.

## Weaknesses

- **No safety beyond chains**: lifetime, synchronization, valid usage, and error checking are all caller responsibilities; `Result` returns are ignorable.
- **`externsync` and most registry semantics are dropped**: `Count`/`Flow` attributes survive as inert decoration, `externsync` not at all; generated docs are largely `To be documented.`
- **The `Vk` context object is awkward state**: `CurrentInstance`/`CurrentDevice` setters mutate global-ish dispatch state, and the `(Instance?, Device?)`-keyed cache is acknowledged in-source as a 3.0 removal target.
- **2.x is in maintenance limbo**: the README states 2.x investment is _"currently limited"_ to ad-hoc volunteer releases (one release between November 2024 and January 2026) while 3.0 is rewritten — and 3.0 has been "coming" since 2022.
- **Source-generator delivery proved fragile**: SilkTouch 2.x runs in the _consumer's_ compile (slow, "abuses what Source Generators are supposed to do" per its own blog post); 3.0 retreats to pre-generated code.
- **Overload explosion**: emitting every pointer/`ref`/`out`/`Span` permutation per entry point bloats the API surface and IntelliSense; 3.0's `Ref`/`Ptr` implicit-conversion wrappers are the planned fix.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                 | Trade-off                                                                                            |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Thin raw API, not an idiomatic wrapper                              | Zero abstraction tax; survives the `vk.xml` release treadmill via full regeneration       | All Vulkan hazards (sync, lifetime, VU) pass through to the user                                     |
| SilkTouch source generator emitting `calli` function-pointer calls  | Eliminates delegate/`DllImport` overhead; per-entry-point lazy VTable caching             | Generator runs in consumer builds, slow and brittle — reversed (pre-generated) in 3.0                |
| Handles as blittable `nint`-wrapping structs                        | Free interop, no GC pressure, distinct types prevent handle mix-ups                       | No ownership/lifetime tracking; double-destroy and use-after-free are uncaught                       |
| `structextends` → `IChainStart`/`IExtendsChain<TChain>` constraints | Compile-time-valid `pNext` chains with auto-`SType`; the registry metadata does real work | Only this one slice of registry semantics is typed; `*Any` methods can bypass it                     |
| `externsync` discarded during generation                            | Simpler generator; C# offers no ownership system to attach it to                          | Threading contract invisible in types _and_ docs; validation layers are the only net                 |
| Raw `Result` returns, no exceptions                                 | No hidden control flow or allocation on the call path (contrast SharpVk)                  | Errors are silently ignorable; every user reinvents `ThrowIfFailed`                                  |
| Extension functions in runtime-loaded per-tag classes               | Object possession ≈ capability evidence; keeps core package lean                          | Runtime-checked only (reflection + `Activator.CreateInstance`); presence ≠ enabled, per its own docs |
| 3.0: ClangSharp headers + "mods" instead of the `vk.xml` reader     | Reuses a maintained industrial parser; one pipeline for all APIs                          | Registry-only metadata (`len`, `structextends`, `externsync`) must be re-injected manually           |

---

## Sources

- [dotnet/Silk.NET — GitHub repository][repo]
- [`README.md` — overhead claim, 3.0 status, maintainership][readme]
- [`generator.json` — Vulkan profile sourcing `vk.xml` from Khronos `main`][generatorjson]
- [`src/Core/Silk.NET.BuildTools` — readers/converters/overloaders][buildtools]
- [`src/Core/Silk.NET.SilkTouch/NativeApiGenerator.cs` — the source generator][natgen] · [`VTableGeneration.cs` — per-entry-point slots][vtable] · [`Middlewares/` — marshalling pipeline][middlewares]
- [SilkTouch: Invokes & Marshalling — Silk.NET blog, November 2020][silktouch-blog]
- [Proposal — Generation of Library Sources and PInvoke Mechanisms (3.0)][proposal]
- [`Vk.cs` — context, VTable swapping, extension caches][vkcs] · [`Vk.gen.cs` — generated `[NativeApi]` declarations][vkgen]
- [`IChainable.cs`][ichainable] · [`IChainStart.cs`][ichainstart] · [`IExtendsChain.cs`][iextends] · [`IStructuredType.cs`][istructured] · [`ChainExtensions.cs`][chainext] · [`Chain.cs`][chaincs]
- [`Structs/Instance.gen.cs` — handle struct][instance] · [`Structs/PhysicalDeviceVulkan12Features.gen.cs` — `IExtendsChain` in the wild][pdv12]
- [Silk.NET.Vulkan on NuGet][nuget]
- [FacticiusVir/SharpVk — the abandoned idiomatic wrapper][sharpvk]
- Related: [`ash` (Rust)][ash] · [`erupted` (D)][erupted] · [`vulkan-hpp` (C++)][vulkan-hpp] · [Vulkano (Rust)][vulkano] · [LWJGL & vulkan4j (Java)][lwjgl] · [Synchronization validation][sync-validation] · [Comparison][comparison] · [Survey index][index]

<!-- References -->

[repo]: https://github.com/dotnet/Silk.NET
[docs]: https://dotnet.github.io/Silk.NET/
[nuget]: https://www.nuget.org/packages/Silk.NET.Vulkan
[readme]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/README.md
[vkxml]: https://github.com/KhronosGroup/Vulkan-Docs/blob/7f61271fa6b6e7d71bf56dbc3a6165cda43bd8cb/xml/vk.xml
[generatorjson]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/generator.json
[buildtools]: https://github.com/dotnet/Silk.NET/tree/266259d37bcbab3646f61c3a83229a292b851376/src/Core/Silk.NET.BuildTools
[natgen]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/src/Core/Silk.NET.SilkTouch/NativeApiGenerator.cs
[vtable]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/src/Core/Silk.NET.SilkTouch/VTableGeneration.cs
[middlewares]: https://github.com/dotnet/Silk.NET/tree/266259d37bcbab3646f61c3a83229a292b851376/src/Core/Silk.NET.SilkTouch/Middlewares
[silktouch-blog]: https://dotnet.github.io/Silk.NET/blog/nov-2020/silktouch-invokes-marshalling/
[proposal]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/documentation/proposals/Proposal%20-%20Generation%20of%20Library%20Sources%20and%20PInvoke%20Mechanisms.md
[vkcs]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/src/Vulkan/Silk.NET.Vulkan/Vk.cs
[vkgen]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/src/Vulkan/Silk.NET.Vulkan/Vk.gen.cs
[ichainable]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/src/Vulkan/Silk.NET.Vulkan/IChainable.cs
[ichainstart]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/src/Vulkan/Silk.NET.Vulkan/IChainStart.cs
[iextends]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/src/Vulkan/Silk.NET.Vulkan/IExtendsChain.cs
[istructured]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/src/Vulkan/Silk.NET.Vulkan/IStructuredType.cs
[chainext]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/src/Vulkan/Silk.NET.Vulkan/ChainExtensions.cs
[chaincs]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/src/Vulkan/Silk.NET.Vulkan/Chain.cs
[instance]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/src/Vulkan/Silk.NET.Vulkan/Structs/Instance.gen.cs
[pdv12]: https://github.com/dotnet/Silk.NET/blob/266259d37bcbab3646f61c3a83229a292b851376/src/Vulkan/Silk.NET.Vulkan/Structs/PhysicalDeviceVulkan12Features.gen.cs
[sharpvk]: https://github.com/FacticiusVir/SharpVk
[ash]: ./rust-ash.md
[erupted]: ./d-erupted.md
[vulkan-hpp]: ./cpp-vulkan-hpp.md
[vulkano]: ./rust-vulkano.md
[lwjgl]: ./java-lwjgl-vulkan4j.md
[sync-validation]: ./sync-validation.md
[comparison]: ./comparison.md
[index]: ./index.md
