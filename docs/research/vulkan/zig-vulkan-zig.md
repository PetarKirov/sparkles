# vulkan-zig (Zig)

A build-time Vulkan binding generator for Zig that parses `vk.xml` and emits a single idiomatic `vk.zig` — error sets from `VkResult`, packed-struct bitflags, slice-merged parameters, and layered dispatch/wrapper/proxy types — while staying a strictly thin, zero-tracking binding.

| Field         | Value                                                                                                 |
| ------------- | ----------------------------------------------------------------------------------------------------- |
| Language      | Zig (`master` tracks Zig master; `minimum_zig_version` 0.16.0; `zig-<version>-compat` branches)       |
| License       | MIT                                                                                                   |
| Repository    | [Snektron/vulkan-zig][repo]                                                                           |
| Documentation | [README.md][readme] (the only docs) · [examples/][examples]                                           |
| Category      | Thin / generated binding                                                                              |
| First release | ~2020 (no tagged releases — rolling `master`, `build.zig.zon` version stays `0.0.0`)                  |
| Latest        | Rolling; last commit May 12, 2026 (`b496a6a`); CI regenerates daily against the latest `vk.xml` + Zig |

> [!NOTE]
> vulkan-zig is the de-facto standard Vulkan binding in the Zig ecosystem (≈860 GitHub stars; used by the `mach-glfw` Vulkan example and most Zig Vulkan tutorials). It deliberately stops at the binding layer: it is the Zig analogue of [Ash (Rust)][ash] and [erupted (D)][erupted], not of [Vulkano][vulkano] or the C++ [render-graph layers][vuk].

---

## Overview

### What it solves

Consuming Vulkan from Zig via `@cImport`/`translate-c` gives the raw C API: `VkResult` return codes the compiler never forces you to check, `uint32_t`-typedef'd flag bits with no type distinction between `VkQueueFlagBits` and `VkQueueFlags`, out-parameters everywhere, and — on 32-bit targets — non-dispatchable handles that all collapse to `uint64_t`, destroying type safety. vulkan-zig regenerates the entire API surface from the [Vulkan XML registry][vk-xml] (`vk.xml`) into native Zig constructs instead, per the [README][readme]:

> _"vulkan-zig attempts to provide a better experience to programming Vulkan applications in Zig, by providing features such as integration of vulkan errors with Zig's error system, function pointer loading, renaming fields to standard Zig style, better bitfield handling, turning out parameters into return values, slices for buffer parameters and more."_

The second problem it solves is **loading**: vulkan-zig generates no static `extern` symbols at all — _"Vulkan-zig provides no integration for statically linking libvulkan, and these symbols are not generated at all"_ ([README § Dispatch Tables][readme]). Every function is a dynamically loaded pointer in one of three dispatch tables, mirroring how the Vulkan loader actually works (and skipping its per-call trampoline for device functions, the same motivation as [`volk`][volk] in C and the wrapper structs in [erupted][erupted]).

### Design philosophy

Idiomatic-but-transparent: every generated construct is ABI-identical to its C counterpart, so the binding adds Zig's type system without adding a runtime. Where a convenience could cost safety, the README is explicit that the burden stays on the programmer — on unconditionally loaded function pointers:

> _"The `load` function tries to load all function pointers unconditionally, regardless of enabled extensions or platform. If a function pointer could not be loaded, its entry in the dispatch table is set to `null`. … **it is up to the programmer to ensure that a function pointer is valid for the platform before calling it**, either by checking whether the associated extension or Vulkan version is supported or simply by checking whether the function pointer is non-null."_ — [README § Initializing Wrappers][readme]

Even micro-architecture is reasoned about: proxying wrappers store a _pointer_ to their dispatch table rather than embedding it, because _"By using a separate function pointer, LLVM knows that the 'vtable' dispatch struct can never be modified and so it can subject each call to vtable optimizations."_ ([README § Proxying Wrappers][readme]).

---

## How it works

The pipeline is a freestanding Zig program, `vulkan-zig-generator` ([`src/main.zig`][main]): a hand-written XML parser ([`src/xml.zig`][xml]) reads `vk.xml`, a mini C tokenizer ([`src/vulkan/c_parse.zig`][c-parse]) parses the C declarations embedded in registry `<type>`/`<command>` elements into a typed registry model ([`src/vulkan/registry.zig`][registry], filled by [`src/vulkan/parse.zig`][parse]), and [`src/vulkan/render.zig`][render] (~2400 lines) renders the final `vk.zig`, which is then formatted with Zig's own `std.zig` formatter. Typical integration runs the generator as a build artifact, so bindings regenerate whenever `vk.xml` changes ([README § build.zig][readme]):

```zig
// build.zig — generate vk.zig from the Vulkan-Headers registry at build time
const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
const vk_gen = b.dependency("vulkan", .{}).artifact("vulkan-zig-generator");
const vk_generate_cmd = b.addRunArtifact(vk_gen);
vk_generate_cmd.addFileArg(registry);
const vulkan_zig = b.addModule("vulkan-zig", .{
    .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
});
exe.root_module.addImport("vulkan", vulkan_zig);
```

The generated API is layered: plain **dispatch tables** (`BaseDispatch` / `InstanceDispatch` / `DeviceDispatch` — structs of optional function pointers, grouped by whether they load via `vkGetInstanceProcAddr` with no instance, with an instance, or via `vkGetDeviceProcAddr`), **wrappers** (`BaseWrapper` / `InstanceWrapper` / `DeviceWrapper`) adding the Zig-style signatures and error sets, and **proxies** (`InstanceProxy`, `DeviceProxy`, `QueueProxy`, `CommandBufferProxy`) bundling a handle with a wrapper pointer so the handle argument disappears from call sites ([`examples/graphics_context.zig`][gctx]):

```zig
// examples/graphics_context.zig (abridged)
self.vkb = BaseWrapper.load(getGlfwInstanceProcAddr);
const instance = try self.vkb.createInstance(.{ ... }, null);   // error union, struct literal
vki.* = InstanceWrapper.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr.?);
self.instance = vk.InstanceProxy.load(instance, vki);
defer instance.destroyInstance(null);                           // still manual destruction
```

### Binding generation & API coverage

Generation is **whole-registry**: every type, command, and extension in the supplied `vk.xml` is emitted, with no feature-level or extension filtering. That is a stated limitation, not an oversight — promoted extensions lose their author tags when they enter core (`VkSemaphoreWaitFlagsKHR` → `VkSemaphoreWaitFlags`), so per-feature-level slicing would need tag re-derivation: _"vulkan-zig has as of yet no functionality for selecting feature levels and extensions when generating bindings"_ ([README § Limitations][readme]). Coverage is kept honest by CI: the project _"is automatically tested daily against the latest vk.xml and zig, and supports vk.xml from version 1.x.163"_ (Vulkan 1.2.163, December 2020). Vulkan Video definitions are opt-in via `--video video.xml` / `-Dvideo=`.

Which registry metadata survives into the output is precisely enumerable from [`parse.zig`][parse]'s attribute reads:

| `vk.xml` attribute                               | Survives as                                                                                                                                                       |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `successcodes` / `errorcodes`                    | Per-command [error sets](#error-handling--validation-integration) + returned non-`success` `Result` values                                                        |
| `optional`                                       | Optional pointers (`?*`), defaulted fields (`= null`, `= .null_handle`, `= .{}`)                                                                                  |
| `len`                                            | [Slice-merged parameters](#type-system-techniques) with shared-length debug assertions                                                                            |
| `values` (on `sType`)                            | `s_type` field defaults (`= .instance_create_info`)                                                                                                               |
| `structextends`                                  | Only to detect feature structs (extenders of `VkDeviceCreateInfo`) and default their `VkBool32` fields to `.false` — **not** rendered as a typed `pNext` relation |
| `api`, `supported`, `promotedto`, `requiresCore` | Declaration filtering + the `vk.features` / `vk.extensions` `ApiInfo` metadata tables                                                                             |
| `parent` (on handles)                            | Parsed into the registry model but unused in rendering                                                                                                            |
| `externsync`                                     | **Dropped entirely** — the string `externsync` does not appear anywhere in `src/`                                                                                 |

The "comptime substitutes for codegen" story is two-stage. Stage one is genuine codegen (the generator executable). Stage two is `comptime` inside the _generated_ file doing what other ecosystems need more generated text for: `FlagsMixin(comptime FlagsType: type)` derives all set operations for every flags type from one ~90-line template via `inline for (comptime std.meta.fieldNames(FlagsType))`; each wrapper is a type constructor (`pub fn BaseWrapperWithCustomDispatch(DispatchType: type) type`, with `BaseWrapper = BaseWrapperWithCustomDispatch(BaseDispatch)`); and the loader is a single reflective loop instead of one generated line per function ([`render.zig`][render], `renderWrapperLoader`):

```zig
// generated vk.zig — wrapper loader (rendered by render.zig:renderWrapperLoader)
pub fn load(device: Device, loader: anytype) Self {
    var self: Self = .{ .dispatch = .{} };
    inline for (std.meta.fields(Dispatch)) |field| {
        if (loader(device, field.name.ptr)) |cmd_ptr| {
            @field(self.dispatch, field.name) = @ptrCast(cmd_ptr);
        }
    }
    return self;
}
```

Platform types use the same trick for late binding: `pub const xcb_connection_t = if (@hasDecl(root, "xcb_connection_t")) root.xcb_connection_t else opaque{};` lets the application's root module inject real windowing-system types at compile time with zero generator involvement ([README § Platform types][readme]).

### Handle lifetime & ownership model

Handles are **branded but unowned**. Each handle type is a distinct non-exhaustive enum — `usize`-backed for dispatchable handles, `u64`-backed for non-dispatchable ones ([README § Handles][readme]):

```zig
const Instance = extern enum(usize) { null_handle = 0, _ };
```

> _"This means that handles are type-safe even when compiling for a 32-bit target."_ — [README § Handles][readme]

This fixes the C headers' 32-bit collapse (where every non-dispatchable handle is the same `uint64_t`) purely nominally: passing a `Buffer` where an `Image` is expected is a compile error, and `null_handle` replaces `VK_NULL_HANDLE` with a typed zero. But that is the full extent of the model. There is no RAII, no destructor generation, no reference counting, and no use of the registry's `parent` attribute (parsed in [`parse.zig`][parse] line 185, never rendered): `defer instance.destroyInstance(null)` in the [example][gctx] is the idiom, and use-after-destroy or double-destroy is undiagnosed. Even the proxying wrappers, which _look_ like objects, are plain `(handle, *wrapper)` pairs — `DeviceProxy.destroyDevice()` must still be called explicitly. Contrast [vulkan-hpp][hpp]'s optional `vk::raii` namespace and [Vulkano][vulkano]'s `Arc`-based ownership; vulkan-zig matches [Ash][ash]'s position that lifetime is the application's problem.

### Synchronization safety

**None — and explicitly out of scope.** vulkan-zig generates `Fence`, `Semaphore`, timeline-semaphore commands (`waitSemaphores`, `signalSemaphore`), `cmdPipelineBarrier2`, and queue-family ownership-transfer structs exactly as the registry declares them, as inert data types. There is:

- no barrier/layout tracking, render graph, or auto-sync layer (compare [vuk][vuk], [daxa][daxa]);
- no typed distinction between externally synchronized and internally synchronized commands — the registry's `externsync` attribute (which marks, e.g., the `commandPool` parameter of `vkFreeCommandBuffers` as requiring host-side exclusion) is **not even parsed**, as the attribute table above shows;
- no thread-safety annotations: a `CommandBufferProxy` can be recorded from two threads and neither the type system nor a debug assertion objects.

The absence is coherent with the project's thin-binding category: the expectation is that correctness comes from the standard [Khronos validation layers][sync-val] (including synchronization validation) at runtime, which work unmodified since every generated call is ABI-identical to C. But it makes vulkan-zig a floor, not a ceiling, for the survey's [synchronization question][index] — the interesting Zig-specific observation is that nothing in the language would prevent an `externsync`-aware layer (e.g. wrapper variants taking `*CommandPool` exclusively), and the generator already has the parse infrastructure it would need.

### Type-system techniques

vulkan-zig's safety budget is spent on **representation**, where Zig's type system is strongest:

- **Error sets per command** — `errorcodes` becomes a named Zig error set (`CreateInstanceError = error{ OutOfHostMemory, … , Unknown }`), and the wrapper returns `CreateInstanceError!Instance`. Ignoring a result is now a compile error. See [Error handling](#error-handling--validation-integration).
- **Packed structs of bools for bitflags** — one type replaces the C `FlagBits`/`Flags` pair ([README § Bitflags][readme]):

  ```zig
  pub const QueueFlags = packed struct {
      graphics_bit: bool align(@alignOf(Flags)) = false,
      compute_bit: bool = false,
      transfer_bit: bool = false,
      ...
  };
  ```

  The first field's `align(@alignOf(Flags))` pins struct ABI; on function-call boundaries the flags are reinterpreted through the mixin's `IntType` because the alignment trick does not survive the call ABI. `FlagsMixin` contributes `toInt`/`fromInt`/`merge`/`intersect`/`complement`/`subtract`/`contains`. The cost of unifying the pair: where C distinguishes "exactly one bit" (`VkQueueFlagBits`) from "a set" (`VkQueueFlags`), here _"The programmer is responsible for only enabling a single bit."_

- **Out-parameters become return values; in-pointers lose one indirection** — a non-const non-optional single-item pointer is returned; a const one is taken by value so `InstanceCreateInfo` can be a struct literal; multiple returns synthesize an ad-hoc result struct with `return_value`, `result`, and de-`p_`-prefixed out fields ([README § Wrappers][readme]; classification in [`render.zig`][render] `classifyParam`).
- **Pointer+length pairs become slices**, with a generated `std.debug.assert` when several slices share one length parameter ([README § slices][readme]).
- **Non-exhaustive enums everywhere** (`enum(i32) { …, _ }`) so values from newer drivers/extensions than the generation-time registry round-trip without UB.
- **Defaults from registry semantics** — `s_type` pre-set, `p_next = null`, optional handles `= .null_handle`, optional bitmasks `= .{}`, and `VkBool32` fields of feature structs `= .false` (the only consumer of `structextends`; [`render.zig`][render] `isFeatureStruct`), making `.{ .sampler_anisotropy = .true }`-style feature requests total.
- **Version/extension metadata as values** — `vk.features.version_1_2` and per-extension `vk.extensions.*` constants of type `ApiInfo { name, version }` support runtime capability checks against `apiVersion`.

What is **absent** is equally diagnostic: `pNext` stays `?*const anyopaque`, so structure chains are untyped and an invalid extender compiles silently (compare [vulkanalia][vulkanalia]'s `push_next`-style typed chains and [vulkan-hpp][hpp]'s `vk::StructureChain`); there is no typestate, no linear/affine ownership, and no capability typing of extensions beyond the loaded-or-null function pointer.

### Overhead & escape hatches

The runtime added over raw C calls is close to the theoretical minimum for dynamic dispatch:

| Mechanism                          | Cost                                                                                                         |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Dispatch table                     | One direct call through a non-null-checked-at-load function pointer — same as `volk`-style C                 |
| Optional-pointer unwrap (`.?`)     | A null check in `Debug`/`ReleaseSafe`; **undefined behavior** in `ReleaseFast` if the pointer never loaded   |
| Wrapper marshalling                | Compile-time only: re-introducing `&create_info`, the `Result` switch (a jump the C caller writes by hand)   |
| Slice length assertions            | `std.debug.assert` — compiled out of release modes                                                           |
| Flags ABI reinterpretation         | A bitcast (`toInt`) at call boundaries — free                                                                |
| Proxy types                        | One extra pointer dereference; deliberately shaped so LLVM treats the dispatch struct as an immutable vtable |
| State tracking / locks / hash maps | **None exist**                                                                                               |

Loading all function pointers unconditionally trades a few thousand `vkGet*ProcAddr` calls at startup for zero per-call capability logic — and shifts validity to the programmer (the bolded README warning [quoted above](#design-philosophy)). The escape hatches are total and zero-cost: `wrapper.dispatch.vkFuncYouWant.?(...)` calls the raw C function pointer with the exact registry signature (`PfnCreateInstance` types are generated with `callconv(vulkan_call_conv)`), handles are `@intFromEnum`-convertible integers ABI-compatible with C libraries (the [example][gctx] passes `vk.Instance` straight to GLFW), and an `enumerate`-style wrapper's manual two-call form remains available beside the allocating one.

### Error handling & validation integration

`VkResult` handling is the binding's signature feature. For each command, [`render.zig`][render] (`renderErrorSwitch`, `renderErrorSet`) renders the registry's `errorcodes` into an error set and a switch:

```zig
// generated vk.zig — shape of every wrapper body (per render.zig:renderErrorSwitch)
switch (result) {
    .success => {},
    .error_out_of_host_memory => return error.OutOfHostMemory,
    .error_initialization_failed => return error.InitializationFailed,
    ...
    else => return error.Unknown,   // forward-compat: codes newer than the registry
}
```

Non-error success codes are not flattened away: a command whose `successcodes` exceed `VK_SUCCESS` (e.g. `vkAcquireNextImageKHR` with `VK_SUBOPTIMAL_KHR` / `VK_TIMEOUT`) returns the `Result` value (or a result struct containing it), so semantically meaningful statuses survive the error-set translation — a design point [Ash][ash] shares but several C++ wrappers fumble. For the enumerate pattern (`vkEnumeratePhysicalDevices` and friends, listed in a `StaticStringMap` in [`render.zig`][render]), an additional `fooAlloc(..., allocator)` wrapper is generated per command and on each proxy that owns it; it loops `while (result == .incomplete)`, growing a caller-supplied `std.mem.Allocator` allocation — the only allocating code in the entire binding, and explicitly opt-in by suffix.

Validation-layer integration is **pass-through**: nothing generated knows about `VK_LAYER_KHRONOS_validation`, but because handles, structs, and calling conventions are ABI-exact, the layers (and `DebugUtilsMessengerEXT`, whose creation functions are ordinary generated wrappers) work without adapters — see the [synchronization-validation deep-dive][sync-val] for what that runtime net actually catches.

---

## Strengths

- **Zero runtime above dynamic dispatch** — no tracking structures, no locks, no allocation outside the opt-in `*Alloc` wrappers; release-mode marshalling compiles to the code a careful C programmer writes.
- **Result-code discipline by construction**: per-command error sets make unchecked `VkResult` a compile error while preserving non-`SUCCESS` success codes.
- **Representation-level fixes C cannot express**: branded 32-bit-safe handles, one packed-struct flags type with set algebra, slices with length checking, `s_type`/`p_next` defaults that kill an entire class of boilerplate bugs.
- **Build-time generation from the exact `vk.xml` you ship** — bindings can never drift from the headers/SDK in use, and day-one extension support is a regeneration away (CI proves it daily).
- **Layering with clean exits**: dispatch table → wrapper → proxy, each level optional, raw C function pointers always reachable.
- **`comptime` keeps the generator small** (~5.8 kLoC total): mixins, loaders, and platform-type injection are reflective templates in the generated file rather than expanded text.

## Weaknesses

- **No synchronization or lifetime safety whatsoever** — barriers, semaphores, queue-family transfers, and destruction ordering are entirely manual; `externsync` metadata is discarded unparsed, so even host-synchronization _documentation_ is absent from the generated API.
- **Unconditional pointer loading defers capability errors to call time**: an extension function missing on the platform is a `null` unwrap — a checked crash in safe modes, UB in `ReleaseFast`.
- **Untyped `pNext`** (`?*const anyopaque`): structure chains, the fastest-growing part of modern Vulkan, get no help.
- **No feature/extension selection at generation time** — the whole registry is always emitted (single large `vk.zig`; compile time and namespace noise scale with the registry).
- **Single-bit vs. multi-bit flag distinction is lost** by unifying `FlagBits`/`Flags`; the registry's `optional` data is also _"not everywhere as useful … leading to places where optional-ness is not correct"_ ([README § Pointer types][readme]).
- **Rolling versioning against a rolling language**: no tagged releases; `master` chases Zig `master`, with compat branches as the only stability story — awkward for long-lived projects.
- Docs are a single README; there is no generated per-function reference (the Vulkan spec remains the manual).

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                        | Trade-off                                                                                       |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| Build-time generator executable (not `comptime` parsing of XML)   | Full Zig program can parse XML + embedded C and run `zig fmt`; output is inspectable, vendorable | Two-stage build; users must wire `vk.xml` through `build.zig`                                   |
| Generate everything; no feature/extension selection               | Promoted extensions lose author tags, making sliced generation inconsistent                      | Large single `vk.zig`; unsupported functions exist as `null` traps rather than absent symbols   |
| Dynamic loading only; no `extern` libvulkan symbols               | Matches loader reality; per-device tables skip loader trampolines                                | Startup loads every pointer; validity checking pushed to the programmer                         |
| `VkResult` → per-command error sets + returned success codes      | Compiler-enforced handling; `try` ergonomics; statuses like `suboptimal_khr` preserved           | `else => error.Unknown` lumps future codes; error names lose the numeric code                   |
| Flags as one packed struct of bools + `FlagsMixin`                | Field-named bits, defaults, set algebra; no `FlagBits`/`Flags` duplication                       | "Exactly one bit" contracts unchecked; ABI needs the `align` trick + `IntType` reinterpretation |
| Handles as non-exhaustive `enum(usize)`/`enum(u64)`               | Nominal typing on all targets, typed `null_handle`, zero cost                                    | No ownership/lifetime semantics; `parent` registry data unused                                  |
| `externsync` ignored                                              | Keeps the binding thin; host sync is the validation layers' job                                  | The registry's only thread-safety metadata vanishes — not even surfaced in doc comments         |
| Proxies hold `(handle, *wrapper)` with the table behind a pointer | LLVM "vtable" optimization on an immutable dispatch struct; ergonomic call sites                 | One more indirection and one more lifetime for the user to keep straight                        |

For the cross-language synthesis — especially how a D library could consume the same registry metadata vulkan-zig drops (`externsync`, `parent`) using CTFE where Zig uses a generator binary — see the [comparison][comparison] and [concepts][concepts] docs.

---

## Sources

- [Snektron/vulkan-zig — GitHub repository][repo]
- [README.md — features, wrappers, proxies, bitflags, handles, limitations][readme]
- [`src/vulkan/render.zig` — wrapper/proxy/error-set/flags rendering][render]
- [`src/vulkan/parse.zig` — registry attribute consumption (`optional`, `len`, `successcodes`, `structextends`)][parse]
- [`src/vulkan/registry.zig` — typed registry model][registry]
- [`src/vulkan/c_parse.zig` — embedded-C declaration tokenizer][c-parse]
- [`src/xml.zig` — hand-written XML parser][xml]
- [`src/main.zig` — generator CLI entry point][main]
- [`examples/graphics_context.zig` — wrapper/proxy usage end to end][gctx]
- [Vulkan XML registry (`vk.xml`), Khronos Vulkan-Docs][vk-xml]
- [volk — C meta-loader (same dispatch-table motivation)][volk]
- Related deep-dives: [Ash (Rust)][ash] · [vulkanalia (Rust)][vulkanalia] · [erupted (D)][erupted] · [Vulkan-Hpp (C++)][hpp] · [Vulkano (Rust)][vulkano] · [vuk (C++)][vuk] · [Daxa (C++)][daxa] · [Synchronization validation][sync-val] · [Comparison][comparison] · [Index][index]

<!-- References -->

[repo]: https://github.com/Snektron/vulkan-zig
[readme]: https://github.com/Snektron/vulkan-zig/blob/master/README.md
[render]: https://github.com/Snektron/vulkan-zig/blob/master/src/vulkan/render.zig
[parse]: https://github.com/Snektron/vulkan-zig/blob/master/src/vulkan/parse.zig
[registry]: https://github.com/Snektron/vulkan-zig/blob/master/src/vulkan/registry.zig
[c-parse]: https://github.com/Snektron/vulkan-zig/blob/master/src/vulkan/c_parse.zig
[xml]: https://github.com/Snektron/vulkan-zig/blob/master/src/xml.zig
[main]: https://github.com/Snektron/vulkan-zig/blob/master/src/main.zig
[gctx]: https://github.com/Snektron/vulkan-zig/blob/master/examples/graphics_context.zig
[examples]: https://github.com/Snektron/vulkan-zig/tree/master/examples
[vk-xml]: https://registry.khronos.org/vulkan/specs/latest/registry.html
[volk]: https://github.com/zeux/volk
[ash]: ./rust-ash.md
[vulkanalia]: ./rust-vulkanalia.md
[erupted]: ./d-erupted.md
[hpp]: ./cpp-vulkan-hpp.md
[vulkano]: ./rust-vulkano.md
[vuk]: ./cpp-vuk.md
[daxa]: ./cpp-daxa.md
[sync-val]: ./sync-validation.md
[comparison]: ./comparison.md
[concepts]: ./concepts.md
[index]: ./index.md
