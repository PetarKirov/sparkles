# vulkanalia (Rust)

A thin, fully-generated Rust binding to Vulkan, _"heavily inspired by"_ [ash][ash] but regenerated nightly from `vk.xml` by a Kotlin generator, with lifetime-carrying builder structs and typed `pNext`-chain traits as its main safety additions over raw FFI.

| Field          | Value                                                                                                                          |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Language       | Rust (MSRV 1.88.0)                                                                                                             |
| License        | Apache-2.0                                                                                                                     |
| Repository     | [KyleMayes/vulkanalia][repo]                                                                                                   |
| Documentation  | [docs.rs/vulkanalia][docs] · [docs.rs/vulkanalia-sys][docs-sys] · [Vulkan tutorial book][tutorial]                             |
| Category       | Thin / generated binding                                                                                                       |
| First release  | `0.1.0` — October 19, 2020                                                                                                     |
| Latest release | `0.35.0` — February 15, 2026 (37 releases)                                                                                     |
| Key crates     | `vulkanalia` (wrapper) · `vulkanalia-sys` (raw types) · `vulkanalia-vma` (VMA integration) · `generator` (Kotlin, unpublished) |

> [!NOTE]
> vulkanalia and [ash][ash] occupy the same niche — unsafe, registry-generated, full-coverage Rust bindings — and this deep-dive repeatedly contrasts the two. The headline differences are vulkanalia's separate builder types (ash 0.38 moved lifetimes onto the structs themselves), its generated [`pNext`-chain introspection traits](#typed-pnext-chains-and-the-chain-module) (ash has no output-chain equivalent), and its split [`SuccessCode`/`ErrorCode`](#error-handling--validation-integration) result types.

---

## Overview

### What it solves

Raw Vulkan from Rust means hand-loading hundreds of function pointers through `vkGetInstanceProcAddr`/`vkGetDeviceProcAddr`, filling `repr(C)` structs whose `sType`/`pNext` fields are easy to get wrong, and hand-rolling the two-call enumerate-count-then-fill idiom for every query. vulkanalia generates all of that from the [Vulkan API Registry][vk-xml] (`vk.xml`): a complete `vulkanalia-sys` layer of raw commands, structs, enums, bitmasks and handles, plus a wrapper layer that loads commands progressively and reshapes signatures into idiomatic Rust (`&[T]` slices, `Option<&T>`, `bool`, `Result`). The project's own positioning, verbatim from the [README][readme]:

> _"`vulkanalia-sys` consists of the Vulkan types and command signatures generated from the Vulkan API Registry. … `vulkanalia` offers a fairly thin wrapper around `vulkanalia-sys` that handles function loading for you and makes the Vulkan API somewhat less error prone and more idiomatic to use from Rust."_

Coverage is exhaustive and self-maintaining: a scheduled GitHub Actions workflow ([`.github/workflows/update.yml`][update-yml], cron `0 21 * * *`) reruns the generator against the latest `vk.xml` every night and opens an update PR, so new extensions (including the `video` and `provisional` ones) land without manual binding work.

### Design philosophy

vulkanalia is deliberately **not** a safety layer. The [tutorial book's overview][tutorial-overview] is explicit that command wrappers stay `unsafe`:

> _"while `vulkanalia` can eliminate certain classes of errors … there are still plenty of things that can go horribly wrong and cause fun things like segfaults."_

The safety budget is spent on exactly two mechanisms, both compile-time-only: **builder lifetimes** (a builder borrows everything passed into it for `'b`, so passing the builder — not the `.build()` output — to a command lets the borrow checker catch dangling pointers) and **typed `pNext` chains** (per-struct `Extends*` marker traits restrict what may be chained onto what). Everything else — synchronization, handle lifetime, queue-family ownership — is the user's problem, backstopped by the standard validation layers. This is the same stance as [ash][ash-dd] and the opposite end of the spectrum from [vulkano][vulkano].

---

## How it works

The crate stack is three layers. `vulkanalia-sys` holds the raw generated types and is `no_std`-compatible; the `vulkanalia` crate re-exports it as the [`vk` module][vk-mod] together with generated builders, chains, version traits and extension traits; on top sit three hand-written wrapper structs — `Entry`, `Instance`, `Device` — each pairing a Vulkan handle with its loaded command table (`vk::EntryCommands`, `vk::InstanceCommands`, `vk::DeviceCommands`, bootstrapped from `vk::StaticCommands`, i.e. `vkGetInstanceProcAddr`/`vkGetDeviceProcAddr`). Commands are exposed as **traits** implemented by these structs: version traits (`vk::EntryV1_0` … `vk::DeviceV1_4`) and per-extension traits (e.g. `vk::KhrSwapchainExtension`), so the set of callable commands is visible in the type signature of what you import. A typical wrapper, from [`vk::InstanceV1_0`][instancev1_0]:

```rust
// docs.rs/vulkanalia — trait vk::InstanceV1_0 (generated)
unsafe fn create_device(
    &self,
    physical_device: PhysicalDevice,
    create_info: &DeviceCreateInfo,
    allocator: Option<&AllocationCallbacks>,
) -> VkResult<Device>
```

Optional cargo features keep the core dependency-free: `libloading` (runtime loader discovery), `window` ([`raw-window-handle`][rwh] surface creation), `provisional` (beta extensions), and `no_std_error` ([README][readme]).

### Binding generation & API coverage

Unusually for a Rust project, the generator is written in **Kotlin** (Gradle project under [`generator/`][generator]). Its pipeline is split into a `registry` package that parses and indexes `vk.xml` ([`registry/Parse.kt`, `Extract.kt`, `Index.kt`, `Filter.kt`][extract-kt]) and a `generate` package with one emitter per output file — [`Builders.kt`][builders-kt], [`Chains.kt`][chains-kt], `Commands.kt`, `Enums.kt`, `Extensions.kt`, `Handles.kt`, `Structs.kt`, `Versions.kt`, etc. — each producing a Rust source file that is `rustfmt`-ed and committed into `vulkanalia-sys`/`vulkanalia`.

Which registry metadata survives extraction is checkable directly in [`registry/Extract.kt`][extract-kt]:

| `vk.xml` attribute                                | Extracted? | Becomes                                                                                                              |
| ------------------------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------- |
| `successcodes` / `errorcodes`                     | Yes        | The [`VkResult` vs `VkSuccessResult` split](#error-handling--validation-integration)                                 |
| `optional`                                        | Yes        | `Option<&T>` / `Option<&CStr>` wrapper parameters                                                                    |
| `len` (incl. `null-terminated`, arithmetic forms) | Yes        | Slice parameters with auto-set count fields; two-call enumeration collapsed into `Vec<T>` returns                    |
| `structextends`                                   | Yes        | Per-struct `Extends*` marker traits + `push_next` ([typed `pNext` chains](#typed-pnext-chains-and-the-chain-module)) |
| `externsync`                                      | **No**     | Nothing — the attribute is never read ([`Extract.kt`][extract-kt] has no occurrence)                                 |
| `noautovalidity`                                  | **No**     | Nothing                                                                                                              |

The signature-reshaping logic lives in [`generate/support/Wrapper.kt`][wrapper-kt]: it turns count+pointer pairs into slices, allocates an output `Vec` sized by a setup invocation of the same command (the classic two-call idiom, executed inside the wrapper), maps `Bool32` to `bool`, maps `null-terminated` pointers to `&CStr`, and routes `pNext`-extendable output structs back through user-provided `&mut` parameters so callers can pre-chain extension structs onto query outputs.

Coverage is the whole registry — core 1.0–1.4, all extensions, the `video` sub-module, and provisional extensions behind the `provisional` feature — kept current by the [nightly update workflow][update-yml]. The repo also ships a [`layer/`][repo] example for writing Vulkan **layers** in Rust against the same generated types, something ash does not package.

### Handle lifetime & ownership model

Handles are plain newtypes over `u64`/pointers implementing a `Handle` trait (`as_raw`/`from_raw`/`null`), generated by `Handles.kt`. There is **no RAII, no reference counting, and no destruction tracking**: `destroy_instance`, `destroy_device`, `free_memory` etc. are ordinary `unsafe fn`s on the version traits, and nothing prevents use-after-destroy or double-destroy — this dimension is explicitly absent, exactly as in [ash][ash-dd] (and unlike [vulkano][vulkano]'s `Arc`-based ownership or the [`erupted`][erupted] D bindings' equally manual model). Parent–child relationships (`Instance` → `Device`) exist only in the hand-written wrapper structs insofar as a `Device` holds command pointers loaded from its parent; dropping the wrapper drops the function-pointer table, not the Vulkan object.

The one place lifetimes do real work is the **builder layer**. Every struct gets a `#[repr(transparent)]` companion `<Name>Builder<'b>` wrapping the raw struct plus a `PhantomData<&'b ()>` marker; every setter that stores a pointer takes `&'b`-bounded input, so the builder cannot outlive what it points at (template in [`Builders.kt`][builders-kt]). Builders implement `Deref`/`DerefMut` to the raw struct and the crate-wide `Cast` trait —

> _"A type that can be used interchangeably with another in FFI."_ — [`Builders.kt`][builders-kt]

— so command wrappers accept `impl Cast<Target = vk::InstanceCreateInfo>` and you pass the **builder itself**, never calling `.build()`. The [tutorial][tutorial-overview] warns that calling `.build()` _"discards the builder lifetimes"_: the canonical bug it demonstrates — `enabled_extension_names(&vec![…]).build()` followed by `create_instance` — compiles and segfaults with `.build()`, but is rejected by the borrow checker ("temporary value dropped while borrowed") when the builder is passed directly. ash 0.38 reached the same destination by a different route: it deleted builders and put the `'a` lifetime on the structs themselves (`vk::InstanceCreateInfo<'a>`). vulkanalia's split keeps the raw structs lifetime-free POD (friendlier for FFI storage and `vulkanalia-sys`-only consumers) at the cost of a parallel builder type per struct and a lifetime-erasing `.build()` escape hatch that remains one method call away.

### Synchronization safety

**Not modeled at all.** Barriers, semaphores, fences, timeline semaphores, events and queue-family ownership transfers are bound exactly as the C API defines them — `cmd_pipeline_barrier`, `queue_submit`, `wait_for_fences` are `unsafe fn`s taking the same structs C takes, with no automation, no typestate, and no runtime tracking. There is no render-graph or auto-sync layer (contrast [vulkano][vulkano]'s runtime tracking or [daxa][daxa]/[vuk][vuk]'s task graphs), and no API distinction between commands that require external synchronization of their parameters and those that do not: since [`externsync` is dropped at extraction time](#binding-generation--api-coverage), a host-synchronization requirement like `vkDestroyDevice`'s is invisible in the Rust types — wrapper methods take `&self` regardless. The wrappers are `Send`/`Sync` function-pointer tables; concurrent misuse of an externally-synchronized handle from two threads compiles silently and is left to the [synchronization validation layer][sync-val] to catch at runtime. For a generated thin binding this is a defensible scope decision, but it means vulkanalia contributes nothing to the survey's [synchronization question (research question 1)][index] beyond confirming the baseline: thin bindings punt synchronization entirely to validation layers.

### Type-system techniques

The techniques in play, all compile-time:

- **Lifetime-parameterized builders** (`<Name>Builder<'b>` + `PhantomData<&'b ()>`) — pointer-validity-by-borrow, as above.
- **`Cast` + `HasBuilder` traits** — `Cast` is an `unsafe trait` justifying the `#[repr(transparent)]` reinterpret between builder and struct; `HasBuilder<'b>` ties each struct to its builder type so generic code can say `T: HasBuilder<'b>` ([`Builders.kt`][builders-kt]).
- **Typed `pNext` chains** — see below.
- **Marker-trait command scoping** — version traits (`EntryV1_0`…`DeviceV1_4`) and extension traits gate which commands exist on a wrapper, a weak form of capability typing: importing `vk::KhrSwapchainExtension` is what brings `create_swapchain_khr` into scope. Nothing verifies the extension was actually _enabled_ at instance/device creation — calling an unloaded command hits a panicking stub pointer at runtime, not a compile error.
- **Newtype handles** — `vk::Buffer` vs `vk::Image` are distinct types (vs raw `u64`), but with no phantom branding by parent device and no affine destruction (a handle is `Copy`).

Notably absent: typestate, linear/affine resource ownership, const-generic or trait-level format/usage typing. The generator does no semantic modeling beyond what `vk.xml`'s structural attributes give it.

#### Typed `pNext` chains and the `chain` module

For every struct that appears in some `structextends` list, the generator emits a marker trait and impls ([`Builders.kt`][builders-kt]):

```rust
// vulkanalia-sys (generated; template in generator/…/file/Builders.kt)
/// A Vulkan struct that can be used to extend a [`InstanceCreateInfo`].
pub unsafe trait ExtendsInstanceCreateInfo: fmt::Debug { }
unsafe impl ExtendsInstanceCreateInfo for DebugUtilsMessengerCreateInfoEXT { }
unsafe impl ExtendsInstanceCreateInfo for ValidationFeaturesEXT { }
// …
```

and a `push_next` on the builder, generated only when the struct has known extensions:

```rust
// docs.rs/vulkanalia — vk::InstanceCreateInfoBuilder (generated)
pub fn push_next<T>(self, next: &'b mut impl Cast<Target = T>) -> Self
where
    T: ExtendsInstanceCreateInfo
```

`push_next` calls a shared `merge` helper that walks to the tail of the _new_ chain and appends the existing base chain there ([`Builders.kt`][builders-kt]) — so a pre-built sub-chain can be pushed in one call; ash's equivalent instead _"prepends the given extension struct between the root and the first pointer"_ ([ash docs][ash-push-next]) and both derive the trait bound from the same `structextends` metadata. So far the two crates are equivalent in what they type-check: _membership_ of a struct in a chain root's extension set, not duplicate-`sType` prevention or chain-order rules.

Where vulkanalia goes further is **chain introspection**. [`Chains.kt`][chains-kt] generates two more unsafe traits — `InputChainStruct` (with `const TYPE: StructureType`, `s_type()`, `next()`) implemented by every chainable struct, and `OutputChainStruct` (adding `next_mut()`) implemented when the struct's `pNext` is non-const, i.e. the registry says it can appear in an _output_ chain. The wrapper crate's [`chain` module][chain-mod] builds `input_chain(...)`/`output_chain(...)` iterator functions on top, yielding type-erased `InputChainPtr`/`OutputChainPtr` entries that can be inspected by `s_type` and downcast (`as_ref::<vk::ValidationFlagsEXT>()` — still `unsafe`). This directly encodes the registry's input/output chain distinction in the type system — the closest any surveyed thin binding comes to the survey's [host-synchronization question (research question 2)][index] — and has no generated counterpart in ash, where walking a returned `pNext` chain is raw pointer arithmetic. ([vulkan-zig][vulkan-zig] and [vulkan4j][vulkan4j] sit between the two.)

### Overhead & escape hatches

The runtime cost model is "what you'd write by hand, plus `Vec`":

- **Builders are free.** `#[repr(transparent)]`, `Copy`, all setters `#[inline]`; `PhantomData` is zero-sized. A builder _is_ the struct at the ABI level — that is what `Cast` asserts.
- **Command dispatch** is one indirect call through a per-`Entry`/`Instance`/`Device` function-pointer table loaded once at creation ([`Wrapper.kt`][wrapper-kt]'s `(self.commands().cmd)(…)`), identical to ash and to well-written C.
- **The real (opt-in) cost is allocation in enumeration wrappers**: any command with an output array allocates a `Vec` (`Vec::with_capacity` + `set_len` after the call) and two-call commands invoke the command twice ([`Wrapper.kt`][wrapper-kt]). Hot paths that care can drop to `vulkanalia-sys` and manage buffers themselves.
- **No tracking, no locks, no hashing** anywhere — there is no state to maintain.

Escape hatches are layered and total: `.build()` strips builder lifetimes when you genuinely need an owned POD struct; `Handle::as_raw`/`from_raw` round-trip every handle through `u64`; and `vulkanalia-sys` is a published crate usable standalone (raw `extern "system"` signatures, no wrappers) for FFI with C/C++ engine code. The `bytecode` module's `Bytecode` type solves one real-world UB trap — guaranteeing 4-byte alignment of SPIR-V passed to `create_shader_module` — that raw `include_bytes!` does not.

### Error handling & validation integration

vulkanalia refines `VkResult` more than ash does. The generator reads `successcodes`/`errorcodes` per command ([`Extract.kt`][extract-kt]) and splits the C enum into two Rust-side types, `vk::SuccessCode` and `vk::ErrorCode`, choosing the return shape per command ([`Wrapper.kt`][wrapper-kt]):

```rust
// vulkanalia — generated return types, selected by registry metadata
pub type VkResult<T>        = Result<T, ErrorCode>;                 // single success code
pub type VkSuccessResult<T> = Result<(T, SuccessCode), ErrorCode>;  // multiple success codes
```

A command with multiple success codes (e.g. `acquire_next_image_khr`, which can return `SUBOPTIMAL_KHR`) hands you the success code in the `Ok` tuple instead of silently discarding it — a registry-metadata-driven refinement ash's plain `Result<T, vk::Result>` does not make (ash documents non-`SUCCESS` success codes per method instead). A `ResultExt` trait adds combinators on `vk::Result` itself.

Validation is wholly external: the [tutorial][tutorial] wires up `VK_LAYER_KHRONOS_validation` plus a `DebugUtilsMessengerEXT` (using `push_next` to chain the messenger create-info into `InstanceCreateInfo`, so layer output covers instance creation itself), and the typed-chain machinery makes `ValidationFeaturesEXT`/GPU-assisted-validation configuration type-checked. There is no binding-level validation mode of its own — see [sync-validation][sync-val] for what the layers actually catch.

---

## Strengths

- **Complete, perpetually fresh coverage** — the whole registry including video and provisional extensions, regenerated nightly by [`update.yml`][update-yml]; binding lag is structurally impossible rather than maintainer-dependent.
- **Builder lifetimes catch real bugs** that compile fine in ash-pre-0.38-style raw structs — the dangling-`Vec` `create_instance` segfault is a borrow-check error if you never call `.build()`.
- **Best-in-class-among-thin-bindings `pNext` typing**: `Extends*` bounds on input, plus generated `InputChainStruct`/`OutputChainStruct` traits and chain iterators for output-chain introspection that [ash][ash-dd] lacks.
- **`SuccessCode`/`ErrorCode` split** surfaces multi-success-code commands in the signature instead of in documentation.
- **Clean layer separation** — `no_std`-capable `vulkanalia-sys` is independently consumable; the `layer/` example shows the same generated types driving Vulkan layer authorship.
- **Outstanding learning material**: the [complete Rust port of the Vulkan Tutorial][tutorial] doubles as the crate's narrative documentation.

## Weaknesses

- **No safety beyond pointers**: synchronization, handle lifetime, queue-family ownership and external-synchronization requirements are untyped and untracked; every command is `unsafe`.
- **`externsync` (and `noautovalidity`) registry metadata is discarded** at extraction — the one piece of host-synchronization information `vk.xml` offers never reaches the type system.
- **`.build()` is a silent lifetime eraser** one method away from every builder; the discipline "pass the builder, don't build" is conventional, not enforced.
- **Extension traits don't prove enablement** — importing `KhrSwapchainExtension` compiles regardless of whether the extension was enabled; failure is a runtime panic through a stub pointer.
- **Enumeration wrappers always allocate `Vec`s** — fine for setup-time calls, but per-frame queries must drop to `vulkanalia-sys` to avoid it.
- **Small ecosystem next to ash** (~380 stars vs ash's ~2k; most of the Rust graphics stack, including [wgpu][wgpu], builds on ash), and an essentially single-maintainer project; the Kotlin/Gradle generator raises the contribution bar for a Rust audience.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                          | Trade-off                                                                                               |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Thin unsafe wrapper, no semantic safety layer                     | Zero runtime overhead; API maps 1:1 to the spec; trivially verifiable against C docs               | All of Vulkan's hazards (sync, lifetime, externsync) remain; validation layers are mandatory in dev     |
| Separate `Builder<'b>` types (vs ash 0.38's lifetimes on structs) | Raw structs stay lifetime-free POD for FFI/storage; builders are an opt-in safety layer            | Doubled type surface; `.build()` escape hatch silently discards the lifetime protection                 |
| `Cast` trait + `#[repr(transparent)]` builders                    | Commands accept struct or builder interchangeably at zero cost; no `.build()` needed at call sites | An `unsafe trait` whose soundness rests on generator-enforced layout; type errors mention `impl Cast`   |
| Generated `Extends*` + `InputChainStruct`/`OutputChainStruct`     | `structextends` and `pNext` const-ness from the registry become compile-time chain typing          | Membership-only checking: duplicate `sType`s and chain-order constraints still pass the compiler        |
| `successcodes`-driven `VkResult`/`VkSuccessResult` split          | Multi-success-code commands can't silently lose `SUBOPTIMAL_KHR`-class information                 | Two result aliases to learn; tuple returns are slightly noisier than ash's plain `Result`               |
| Kotlin generator + nightly auto-update workflow                   | Rich typed XML model; bindings track the registry with zero maintainer latency                     | Contributors to a Rust crate must touch Kotlin/Gradle; generator logic isn't reusable as a Rust library |
| Commands as version/extension traits                              | Callable surface is explicit in imports; wrappers stay object-safe over `commands()`/`handle()`    | Trait imports proliferate; no compile-time proof the extension was enabled at runtime                   |

For the sparkles design: vulkanalia is the strongest evidence in the survey that **registry metadata is an underused safety resource even in the best generated bindings** — it consumes `structextends`, `len`, `optional` and `successcodes` to real effect, yet drops `externsync` on the floor like everyone else. A D generator with CTFE over a parsed `vk.xml` could replicate the entire `Extends*`/chain-trait scheme cheaply (template constraints instead of marker traits) and go one step further by mapping `externsync` onto distinct parameter qualifiers or wrapper types — see [concepts][concepts] and the [comparison][comparison].

---

## Sources

- [KyleMayes/vulkanalia — GitHub repository][repo]
- [vulkanalia README — crate split, features, ash inspiration][readme]
- [vulkanalia on docs.rs (0.35.0)][docs] · [vulkanalia-sys on docs.rs][docs-sys]
- [`vulkanalia::vk` module — generated bindings, builders, traits][vk-mod]
- [`vulkanalia::chain` — input/output pointer-chain iterators][chain-mod]
- [`vk::InstanceV1_0` — version-trait command wrappers][instancev1_0]
- [`vk::InstanceCreateInfoBuilder` — `push_next`/`Cast` signatures][builder-docs]
- [`generator/…/generate/file/Builders.kt` — builder/`Cast`/`Extends*`/`merge` templates][builders-kt]
- [`generator/…/generate/file/Chains.kt` — `InputChainStruct`/`OutputChainStruct` generation][chains-kt]
- [`generator/…/generate/support/Wrapper.kt` — signature reshaping, success-code handling][wrapper-kt]
- [`generator/…/registry/Extract.kt` — which `vk.xml` attributes are extracted][extract-kt]
- [`.github/workflows/update.yml` — nightly auto-regeneration][update-yml]
- [Vulkan tutorial (vulkanalia edition) — Overview chapter, safety stance, builder lifetimes][tutorial-overview]
- [Vulkan API Registry (`vk.xml`)][vk-xml] · [ash `push_next` documentation][ash-push-next]
- Related: [ash][ash-dd] · [vulkano][vulkano] · [erupted (D)][erupted] · [vulkan-zig][vulkan-zig] · [vulkan4j][vulkan4j] · [daxa][daxa] · [vuk][vuk] · [wgpu][wgpu] · [sync validation][sync-val] · [concepts][concepts] · [comparison][comparison] · [survey index][index]

<!-- References -->

[repo]: https://github.com/KyleMayes/vulkanalia
[readme]: https://github.com/KyleMayes/vulkanalia/blob/3fcda51f2950689ae85f4adeb6558b36419be26d/README.md
[docs]: https://docs.rs/vulkanalia/latest/vulkanalia/
[docs-sys]: https://docs.rs/vulkanalia-sys/latest/vulkanalia_sys/
[vk-mod]: https://docs.rs/vulkanalia/latest/vulkanalia/vk/index.html
[chain-mod]: https://docs.rs/vulkanalia/latest/vulkanalia/chain/index.html
[instancev1_0]: https://docs.rs/vulkanalia/latest/vulkanalia/vk/trait.InstanceV1_0.html
[builder-docs]: https://docs.rs/vulkanalia/latest/vulkanalia/vk/struct.InstanceCreateInfoBuilder.html
[tutorial]: https://kylemayes.github.io/vulkanalia/
[tutorial-overview]: https://kylemayes.github.io/vulkanalia/overview.html
[generator]: https://github.com/KyleMayes/vulkanalia/tree/3fcda51f2950689ae85f4adeb6558b36419be26d/generator
[builders-kt]: https://github.com/KyleMayes/vulkanalia/blob/3fcda51f2950689ae85f4adeb6558b36419be26d/generator/src/main/kotlin/com/kylemayes/generator/generate/file/Builders.kt
[chains-kt]: https://github.com/KyleMayes/vulkanalia/blob/3fcda51f2950689ae85f4adeb6558b36419be26d/generator/src/main/kotlin/com/kylemayes/generator/generate/file/Chains.kt
[wrapper-kt]: https://github.com/KyleMayes/vulkanalia/blob/3fcda51f2950689ae85f4adeb6558b36419be26d/generator/src/main/kotlin/com/kylemayes/generator/generate/support/Wrapper.kt
[extract-kt]: https://github.com/KyleMayes/vulkanalia/blob/3fcda51f2950689ae85f4adeb6558b36419be26d/generator/src/main/kotlin/com/kylemayes/generator/registry/Extract.kt
[update-yml]: https://github.com/KyleMayes/vulkanalia/blob/3fcda51f2950689ae85f4adeb6558b36419be26d/.github/workflows/update.yml
[vk-xml]: https://github.com/KhronosGroup/Vulkan-Docs/blob/7f61271fa6b6e7d71bf56dbc3a6165cda43bd8cb/xml/vk.xml
[ash]: https://github.com/ash-rs/ash
[ash-push-next]: https://docs.rs/ash/latest/ash/vk/struct.InstanceCreateInfo.html
[rwh]: https://crates.io/crates/raw-window-handle
[ash-dd]: ./rust-ash.md
[vulkano]: ./rust-vulkano.md
[erupted]: ./d-erupted.md
[vulkan-zig]: ./zig-vulkan-zig.md
[vulkan4j]: ./java-lwjgl-vulkan4j.md
[daxa]: ./cpp-daxa.md
[vuk]: ./cpp-vuk.md
[wgpu]: ./rust-wgpu.md
[sync-val]: ./sync-validation.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
