# Vulkan-Hpp (C++)

The official Khronos C++ binding for Vulkan — a fully generated, header-only layer over the C API that adds strong handle types, compile-time-validated `pNext` chains, and three opt-in ownership models (`UniqueHandle`, `SharedHandle`, `vk::raii`) while deliberately adding **no** synchronization model of its own.

| Field          | Value                                                                                              |
| -------------- | -------------------------------------------------------------------------------------------------- |
| Language       | C++ (C++11 baseline; designated initializers need C++20, `std::expected` C++23)                    |
| License        | Apache-2.0 (repository/generator); the generated `vulkan/*.hpp` headers are Apache-2.0 OR MIT      |
| Repository     | [KhronosGroup/Vulkan-Hpp][repo]                                                                    |
| Documentation  | [`docs/Usage.md`][usage] · [`docs/Handles.md`][handles-doc] · [RAII programming guide][raii-doc]   |
| Category       | Thin / generated binding                                                                           |
| First release  | 2016 (developed at NVIDIA, adopted as the official Khronos C++ binding; in the LunarG SDK)         |
| Latest release | `v1.4.353` (newest tag as of June 11, 2026) — tags track the weekly Vulkan spec patch releases 1:1 |

> [!NOTE]
> Vulkan-Hpp is the baseline of this survey: it is what "maximum safety with zero
> runtime cost, but no synchronization help" looks like in practice. Every other
> subject — [ash][rust-ash], [vulkanalia][rust-vulkanalia], [erupted][d-erupted],
> [vulkano][rust-vulkano], [daxa][cpp-daxa], [vuk][cpp-vuk] — either copies one of
> its mechanisms or exists to fill a gap it leaves open.

---

## Overview

### What it solves

The Vulkan C API is verbose and weakly typed: every handle is (on 64-bit) a distinct pointer type but every non-dispatchable handle on 32-bit collapses to `uint64_t`; enums and flag bits are plain C constants that intermix freely; every extensible struct must have its `sType` set by hand and its `pNext` chain assembled from untyped `void *`; every array is a count-plus-pointer pair; and every function returns a bare `VkResult` the caller must remember to check. None of these mistakes is caught before the validation layers — or the GPU — sees them.

Vulkan-Hpp closes exactly this class of bugs at compile time and stops there. It is generated wholesale from [`vk.xml`][vkxml] (the machine-readable Vulkan registry), so it covers the entire API surface — core, every extension, and the `vulkan_video` headers — and re-emits it as scoped enums, type-safe flag bitmasks, one strong class per handle type, structs whose `sType` is pre-set and whose `pNext` chains are typed (see [`StructureChain`](#type-system-techniques)), and member functions on the handle that logically owns the call (`device.createBuffer(...)` instead of `vkCreateBuffer(device, ...)`).

### Design philosophy

The first sentence of the [README][repo] is the whole contract:

> _"Vulkan-Hpp provides header-only C++ bindings for the Vulkan C API to improve the developer experience with Vulkan without introducing run-time CPU costs."_

"Without run-time CPU costs" is enforced structurally: a `vk::Buffer` is asserted to be layout-identical to a `VkBuffer` (the generated [`vulkan_static_assertions.hpp`][static-asserts] checks `sizeof( VULKAN_HPP_NAMESPACE::Instance ) == sizeof( VkInstance )` — _"handle and wrapper have different size!"_ — for every handle and struct), so arrays of wrappers can be `reinterpret_cast` to arrays of C handles and the C ABI is reachable from any point. Everything that does cost something — `std::vector`-returning enumeration wrappers, exception throwing, smart handles, the RAII layer — is a separately opt-in/opt-out layer controlled by macros ([`docs/Configuration.md`][config]): `VULKAN_HPP_NO_EXCEPTIONS`, `VULKAN_HPP_NO_SMART_HANDLE`, `VULKAN_HPP_NO_CONSTRUCTORS`, `VULKAN_HPP_DISPATCH_LOADER_DYNAMIC`, and ~30 more.

What it deliberately does **not** attempt: any model of GPU-CPU or queue synchronization, any resource state tracking, any use-after-free protection beyond what RAII scoping gives. Those are left to the [validation layers][sync-validation] and to higher-level libraries ([daxa][cpp-daxa], [vuk][cpp-vuk], [tephra][cpp-tephra]).

---

## How it works

### Binding generation & API coverage

The generator lives in-tree under [`generator/`][generator]: [`VkXMLParser.cpp`][parser] (~3,300 lines) parses `vk.xml` with `tinyxml2` into a typed model, and [`VulkanHppGenerator.cpp`][generator-cpp] (~15,000 lines, 686 KB) emits the entire `vulkan/` directory: `vulkan.hpp` (core types, `StructureChain`, dispatch loaders, exceptions), `vulkan_enums.hpp`, `vulkan_structs.hpp`, `vulkan_handles.hpp`, `vulkan_funcs.hpp`, [`vulkan_raii.hpp`][raii-hpp], `vulkan_shared.hpp`, `vulkan_static_assertions.hpp`, `vulkan_format_traits.hpp`, `vulkan_extension_inspection.hpp`, `vulkan_hash.hpp`, `vulkan_to_string.hpp`, and the C++20 named module `vulkan.cppm` (`import vulkan_hpp;`). The `Vulkan-Headers` repo is a git submodule, and CI re-generates and tags a release for every weekly spec patch — coverage is total and lag is days, not months.

Which registry metadata survives into the generated types is the interesting question:

| `vk.xml` attribute            | Fate in Vulkan-Hpp                                                                                                                                                      |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `structextends`               | **Survives** — one `StructExtends<X, Y>` trait specialization per legal extension pair (1,213 in `vulkan.hpp` as of `v1.4.353`); powers compile-time `pNext` validation |
| `allowduplicate`              | **Survives** — a per-struct `static bool const allowDuplicate` consumed by `StructureChainValidation`                                                                   |
| `len` (count/pointer pairing) | **Survives** — count+pointer parameter pairs merge into a single [`ArrayProxy`](#overhead--escape-hatches) parameter or a returned `std::vector`                        |
| `successcodes` / `errorcodes` | **Survives** — drives the per-function return type (value vs `ResultValue`) and the typed exception hierarchy                                                           |
| `optional`                    | **Survives** — optional pointer parameters become `vk::Optional<T>` / default arguments                                                                                 |
| `externsync`                  | **Does not survive** — see below                                                                                                                                        |

The `externsync` story is the survey's cleanest negative finding. The parser dutifully reads and _schema-validates_ the attribute — [`VkXMLParser.cpp`][parser] checks `param.externSync.starts_with( "maybe:" )` forms and reports _"param `<...>` has unknown value `<...>` for attribute externsync"_ on malformed input — and `parseImplicitExternSyncParamsParam` is literally an empty validator:

```cpp
// generator/VkXMLParser.cpp — the implicitexternsyncparams content is checked and discarded
void parseImplicitExternSyncParamsParam( tinyxml2::XMLElement const * element )
{
  int const line = element->GetLineNum();
  checkAttributes( "vk.xml", line, getAttributes( element ), {}, {} );
  checkElements( "vk.xml", line, getChildElements( element ), {} );
}
```

`VulkanHppGenerator.cpp` — the file that actually emits code — contains **zero** references to `externSync`. The registry's machine-readable external-synchronization contract (which parameters must be externally synchronized per command, including the `maybe:` and host-access variants) is parsed for XML hygiene and then thrown away. No generated type, attribute, comment, or assertion reflects it.

### Handle lifetime & ownership model

Vulkan-Hpp ships **four** handle families, escalating in ownership semantics ([`docs/Handles.md`][handles-doc]):

1. **Plain `vk::` handles** — _"thin wrappers around the Vulkan C handles"_ that _"provide type safety and convenience functions, but do not manage the lifetime of the underlying Vulkan resources."_ Trivially copyable, same size as the C handle, no destructor logic. Lifetime is entirely manual, exactly as in C.
2. **`vk::UniqueHandle`** — `std::unique_ptr`-style scope ownership, created via parallel `*Unique` factory functions (`device.createBufferUnique(...)`). The deleter (`vk::detail::ObjectDestroy<OwnerType, Dispatch>`, [`vulkan.hpp`][vulkan-hpp]) stores the owning handle, the `vk::AllocationCallbacks` pointer, and a dispatcher reference — the docs are upfront that this means _"additional memory overhead, and function pointer chain dereferencing during destruction."_
3. **`vk::SharedHandle`** (`vulkan_shared.hpp`) — `shared_ptr`-style reference counting that also retains the **parent**: _"the parent handle will not be destroyed until all child resources are deleted."_ This is the only family that addresses the destroy-parent-before-child ordering bug. The docs warn verbatim: _"Shared handles are not thread-safe. Multi-threaded access to the same `vk::SharedHandle` instance must be synchronised by the user."_
4. **`vk::raii` handles** ([`vulkan_raii.hpp`][raii-hpp], [guide][raii-doc]) — _"vulkan_raii.hpp is a C++ layer on top of vulkan.hpp that follows the RAII-principle"_: the constructor performs `vkCreate*`/`vkAllocate*`, the destructor performs `vkDestroy*`/`vkFree*`. RAII objects owning destructible resources are _"just movable, but not copyable"_; non-owning ones (`vk::raii::PhysicalDevice`) are copyable. Each handle stores its parent, allocator, and a dispatcher pointer — e.g. `vk::raii::Buffer` carries `m_device`, `m_buffer`, `m_allocator`, `m_dispatcher` ([`vulkan_raii.hpp`][raii-hpp], `class Buffer`). The entry point is `vk::raii::Context`, a class with _"no counterpart in either the `vk` namespace or the pure C-API"_ that loads `vkGetInstanceProcAddr` and bootstraps per-instance and per-device dispatchers. `release()` and `clear()` are the escape hatches back to manual management.

None of the four families is a _linear_ type: C++ cannot forbid use-after-move or use-after-destroy, so a dangling plain `vk::Buffer` copy of a destroyed `UniqueHandle`/raii handle compiles and crashes exactly as in C. Parent/child destruction ordering is unchecked except under `SharedHandle`.

### Synchronization safety

**This dimension is explicitly absent, by design.** Vulkan-Hpp wraps `vk::Fence`, `vk::Semaphore`, `vk::Event`, and the timeline-semaphore structs (`vk::TimelineSemaphoreSubmitInfo` participates in `StructureChain` like any other extension struct) as plain typed handles with member functions — the _protocol_ of when to signal, wait, and insert barriers is byte-for-byte the C API's manual protocol. There is:

- no render/task graph and no automatic barrier or layout-transition derivation (contrast [daxa][cpp-daxa], [vuk][cpp-vuk], [tephra][cpp-tephra]);
- no runtime tracking of resource states, queue-family ownership, or submission order (contrast [vulkano][rust-vulkano], [wgpu][rust-wgpu]);
- no compile-time distinction between externally-synchronized and internally-synchronized commands — a direct consequence of `externsync` being [discarded by the generator](#binding-generation--api-coverage). `commandBuffer.draw(...)` and a thread-safe call like `device.getQueue(...)` have identical type signatures and identical (none) host-synchronization requirements expressed in the types.

The implicit position, consistent with the README's no-runtime-cost charter, is that synchronization correctness is the job of the [Khronos validation layers and synchronization validation][sync-validation], which Vulkan-Hpp neither integrates with nor duplicates. For a survey of bindings that _do_ encode synchronization, see the [comparison][comparison].

### Type-system techniques

The techniques are classic C++ template machinery — no typestate, no linear ownership — but applied thoroughly:

- **Strong handle types.** One class per `VkHandle` with `objectType`/`debugReportObjectType` constants and `CType` typedefs; mixing a `vk::Buffer` where a `vk::Image` is expected is a compile error. Caveat: on 32-bit targets non-dispatchable C handles all alias `uint64_t`, so cross-type _conversions_ are only blocked when `VULKAN_HPP_TYPESAFE_CONVERSION` semantics permit — the docs note _"32-bit vulkan is not typesafe for non-dispatchable handles, so we don't allow copy constructors on this platform by default."_
- **Scoped enums + `vk::Flags<BitType>`.** `VK_IMAGE_TYPE_2D` becomes `vk::ImageType::e2D`; flag bits get a per-enum `Flags` bitmask template so OR-ing bits from unrelated enums no longer compiles.
- **Typed `pNext` chains.** `vk::StructureChain<ChainElements...>` derives from `std::tuple<ChainElements...>` and `static_assert`s, at construction, that every element legally extends the head struct and that duplicates appear only where `vk.xml` allows them ([`vulkan.hpp`][vulkan-hpp]):

  ```cpp
  // vulkan/vulkan.hpp — compile-time pNext chain validation
  template <size_t Index, typename... ChainElements>
  struct StructureChainValidation
  {
    using TestType          = typename std::tuple_element<Index, std::tuple<ChainElements...>>::type;
    static bool const valid = StructExtends<TestType, typename std::tuple_element<0, std::tuple<ChainElements...>>::type>::value &&
                              ( TestType::allowDuplicate || !StructureChainContains<Index - 1, TestType, ChainElements...>::value ) &&
                              StructureChainValidation<Index - 1, ChainElements...>::valid;
  };
  // ...
  VULKAN_HPP_STATIC_ASSERT( StructureChainValidation<sizeof...( ChainElements ) - 1, ChainElements...>::valid,
                            "The structure chain is not valid!" );
  ```

  The constructor wires the `pNext` pointers automatically; `get<T>()` retrieves a member struct; `unlink<T>()`/`relink<T>()` toggle a member in and out of the chain at runtime (with `static_assert`-checked membership). Per [`docs/Usage.md`][usage]: _"only chains which are valid according to the Vulkan specification can be created, which is verified at compile time."_ Query functions have chain-returning overloads (`device.getBufferMemoryRequirements2<...>()` returning a populated `StructureChain`).

- **`sType` elimination.** Every generated struct's constructor (or default member initializer) pre-sets `sType`; with `VULKAN_HPP_NO_CONSTRUCTORS` and C++20 the structs become aggregates usable with **designated initializers** (`.pApplicationName = AppName, .applicationVersion = 1`), trading the builder-ish setter chains for plain-text member naming.
- **`ArrayProxy` / `ArrayProxyNoTemporaries`.** A borrowed (pointer, count) view that accepts a single value, a C array, `std::initializer_list`, `std::array`, or `std::vector` — collapsing every `len`-annotated count/pointer pair into one parameter. The `NoTemporaries` variant is used in struct constructors because _"that pointer is assumed to be valid throughout the lifetime of the structure"_ ([`docs/Usage.md`][usage]) — a lifetime hint encoded as overload-set restriction, the closest the library gets to borrow checking.
- **Dispatch as a template parameter.** Every function takes a trailing `Dispatch const &` defaulting to `VULKAN_HPP_DEFAULT_DISPATCHER` — either `vk::detail::DispatchLoaderStatic` (direct calls into the loader's exported prototypes) or `vk::detail::DispatchLoaderDynamic`, which _"pre-fetches **all** function pointers known to the library"_ in a three-step `init()` (loader → instance → device). The `vk::raii` namespace instead bakes per-object dispatchers in: _"For each instantiated `vk::raii::Device`, the device-specific Vulkan function pointers are resolved"_ ([RAII guide][raii-doc]) into a heap-allocated `detail::DeviceDispatcher` the handles share — skipping the loader's per-call dispatch trampoline, which is the standard advice for multi-GPU and for shaving call overhead.
- **Auxiliary comptime metadata.** `vulkan_format_traits.hpp` exposes `constexpr` per-format block size/texel queries; `vulkan_extension_inspection.hpp` exposes extension dependency/promotion data — registry knowledge surfaced as compile-time functions.

### Overhead & escape hatches

The cost model is tiered, and each tier is optional:

| Layer                         | Runtime cost                                                                                                                         |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Plain handles, enums, structs | Zero — layout-asserted identical to C; calls inline to the C entry points                                                            |
| Enhanced-mode functions       | A `std::vector` heap allocation per enumeration call; exception machinery on error paths                                             |
| `StructureChain`              | Zero beyond the `std::tuple` layout; validation is `static_assert`-only; `link`/`unlink` are pointer writes                          |
| `UniqueHandle`                | Deleter storage (owner + allocation callbacks + dispatcher) per handle                                                               |
| `SharedHandle`                | Reference-count control block per handle; parent retention                                                                           |
| `vk::raii`                    | Parent + allocator + dispatcher pointer per handle; one heap-allocated full function-pointer table per `Context`/`Instance`/`Device` |
| `DispatchLoaderDynamic`       | One big table of every known `PFN_vk*`; eliminates the loader trampoline (commonly a _gain_)                                         |

There are no locks, no hash maps, no per-resource state tracking anywhere — the most expensive thing in the library is a `std::vector` return. Escape hatches are pervasive: every wrapper converts to/from its C handle (`static_cast<VkBuffer>( buffer )`), the layout `static_assert`s license `reinterpret_cast` of whole arrays, C-style output-parameter overloads coexist with the `std::vector`-returning ones, raii handles expose `release()`, and because the headers are additive over `vulkan.h`, raw C calls can be mixed in freely at any point.

### Error handling & validation integration

The generator turns `successcodes`/`errorcodes` into a per-function policy ([`docs/Usage.md`][usage]): a function whose only success code is `VK_SUCCESS` returns its value directly and **throws** on error — a typed exception per `VkResult` (e.g. `vk::OutOfDeviceMemoryError`), all deriving from `vk::SystemError` so `errc`-style handling works. Functions with multiple success codes return a `ResultValue<T>`. Three alternative regimes exist:

- `VULKAN_HPP_NO_EXCEPTIONS` — returns `vk::ResultValue<T>` everywhere (struct of `vk::Result` + value; structured bindings recommended), with `VULKAN_HPP_ASSERT` (default `<cassert>`, overridable) guarding unexpected codes.
- `VULKAN_HPP_USE_STD_EXPECTED` (C++23) — `vk::ResultValue<T>::type` becomes `std::expected<T, vk::Result>` with monadic `and_then`/`or_else`. Under `VULKAN_HPP_RAII_NO_EXCEPTIONS` the raii constructors (which would have to throw) are replaced by factory functions returning `std::expected<vk::raii::Object, vk::Result>`.

This maps cleanly onto the D `Expected` idiom this repo already standardizes on. Validation-layer integration is otherwise nil: Vulkan-Hpp generates the `DebugUtilsMessengerEXT` plumbing like any other extension but performs no validity checking of its own at runtime — the division of labor is compile-time structure (Hpp) vs runtime behavior ([validation layers][sync-validation]).

---

## Strengths

- **Total, perpetually fresh API coverage** — generated from `vk.xml` and re-released for every weekly spec patch; extensions appear in the binding the week they appear in the registry.
- **Genuinely zero-cost core** — layout-asserted handle/struct parity with C, header-only inlining, all conveniences opt-in; the C ABI is one `static_cast` away at every point.
- **`StructureChain` is the gold standard for typed `pNext`** — 1,213 generated `StructExtends` pairs make invalid chains a compile error, with runtime `unlink`/`relink` flexibility on top.
- **Four ownership models on one substrate** lets a codebase choose its safety/overhead point per resource (plain in the hot path, raii at the architecture level).
- **Per-device dispatcher in `vk::raii`** removes the loader trampoline — the "safer" layer is also the faster call path.
- **Configurable error-handling spectrum** (exceptions → `ResultValue` → `std::expected`) plus a C++20 named module (`import vulkan_hpp;`) that tames the multi-megabyte header's compile-time cost.

## Weaknesses

- **No synchronization model at all** — barriers, layouts, semaphores, fences, timeline waits, and queue-family ownership transfer are exactly as manual and as silently wrong as in C; the types do not even _mark_ which commands require external synchronization.
- **`externsync` registry metadata is parsed and discarded** — the one piece of machine-readable host-threading contract in `vk.xml` never reaches the type system, docs, or even comments.
- **No temporal safety** — handles are freely copyable values; use-after-destroy, destroy-order, and dangling-`pNext`/`ArrayProxy` pointer bugs all compile (only `ArrayProxyNoTemporaries` and `SharedHandle` nibble at the edges).
- **Compile-time weight** — `vulkan.hpp` is ~27,000 lines before `vulkan_structs.hpp`/`vulkan_funcs.hpp`; without the C++20 module, including it everywhere is a build-time tax.
- **Template-error ergonomics** — a wrong `StructureChain` fails with a `static_assert` ("The structure chain is not valid!") but locating _which_ element offends is left to the reader of a tuple-instantiation backtrace.
- **The raii layer's heap-allocated dispatchers and parent pointers** make it strictly heavier than plain handles, and `vk::raii` types _"are not compatible"_ with the `UniqueHandle`/`SharedHandle` families — mixing models mid-codebase is awkward.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                       | Trade-off                                                                                           |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Generate everything from `vk.xml`, release per spec patch           | Total coverage, zero lag, registry metadata (`structextends`, `len`, result codes) drives types | Generator is a 15k-line bespoke C++ program; binding fidelity is bounded by what it chooses to read |
| Layout-identical wrappers + `static_assert` parity                  | True zero overhead; `reinterpret_cast` interop; C escape hatch everywhere                       | No room for fat pointers/generation counters → no temporal safety in the core types                 |
| `pNext` validation via `StructExtends` traits + `static_assert`     | Invalid chains caught at compile time at zero runtime cost                                      | Errors surface as tuple-template noise; chain composition fixed at compile time (modulo `unlink`)   |
| Discard `externsync` during generation                              | Host-sync contracts don't fit C++'s type system cheaply; keeps generator and API simple         | The only machine-readable threading contract in the registry is lost; no `const`/marker distinction |
| Ownership as opt-in layers (`Unique`/`Shared`/`raii`) over plain    | Pay-for-what-you-use; hot paths keep raw-handle cost                                            | Four coexisting, partially incompatible models; safety depends on which one a codebase picks        |
| Dispatch as a defaulted template parameter + per-device raii tables | Static, dynamic, and per-object dispatch coexist; raii skips the loader trampoline              | `VULKAN_HPP_DEFAULT_DISPATCHER` global storage macro dance; raii dispatchers heap-allocate          |
| Exceptions by default, `ResultValue`/`std::expected` by macro       | Idiomatic C++ default; embedded/no-exceptions and monadic styles still served                   | Macro-flavored API surface: the same function has three signatures across the ecosystem             |

---

## Sources

- [KhronosGroup/Vulkan-Hpp — GitHub repository][repo] (README: positioning, feature list)
- [`docs/Usage.md` — naming, `ArrayProxy`, `StructureChain`, error handling, dispatch loaders][usage]
- [`docs/Handles.md` — plain / `UniqueHandle` / `SharedHandle` / raii families][handles-doc]
- [`docs/VkRaiiProgrammingGuide.md` — `vk::raii::Context`, per-device dispatchers, move-only semantics][raii-doc]
- [`docs/Configuration.md` — the macro configuration surface][config]
- [`generator/VulkanHppGenerator.cpp` — code emission (no `externSync` references)][generator-cpp]
- [`generator/VkXMLParser.cpp` — `externsync` parsing/validation, `implicitexternsyncparams` discard][parser]
- [`vulkan/vulkan.hpp` — `StructureChain`, `StructureChainValidation`, `ObjectDestroy`, dispatch loaders][vulkan-hpp]
- [`vulkan/vulkan_raii.hpp` — raii handle classes and `ContextDispatcher`/`InstanceDispatcher`/`DeviceDispatcher`][raii-hpp]
- [`vulkan/vulkan_static_assertions.hpp` — handle/struct layout parity asserts][static-asserts]
- [Vulkan registry `vk.xml`][vkxml]
- Related: [ash (Rust)][rust-ash] · [vulkanalia (Rust)][rust-vulkanalia] · [erupted (D)][d-erupted] · [vulkano (Rust)][rust-vulkano] · [daxa (C++)][cpp-daxa] · [vuk (C++)][cpp-vuk] · [tephra (C++)][cpp-tephra] · [wgpu (Rust)][rust-wgpu] · [Synchronization validation][sync-validation] · [Concepts][concepts] · [Comparison][comparison]

<!-- References -->

[repo]: https://github.com/KhronosGroup/Vulkan-Hpp
[usage]: https://github.com/KhronosGroup/Vulkan-Hpp/blob/66ac921bb67efeef0ac298e1cf584ea2eb8e4ec5/docs/Usage.md
[handles-doc]: https://github.com/KhronosGroup/Vulkan-Hpp/blob/66ac921bb67efeef0ac298e1cf584ea2eb8e4ec5/docs/Handles.md
[raii-doc]: https://github.com/KhronosGroup/Vulkan-Hpp/blob/66ac921bb67efeef0ac298e1cf584ea2eb8e4ec5/docs/VkRaiiProgrammingGuide.md
[config]: https://github.com/KhronosGroup/Vulkan-Hpp/blob/66ac921bb67efeef0ac298e1cf584ea2eb8e4ec5/docs/Configuration.md
[generator]: https://github.com/KhronosGroup/Vulkan-Hpp/tree/66ac921bb67efeef0ac298e1cf584ea2eb8e4ec5/generator
[generator-cpp]: https://github.com/KhronosGroup/Vulkan-Hpp/blob/66ac921bb67efeef0ac298e1cf584ea2eb8e4ec5/generator/VulkanHppGenerator.cpp
[parser]: https://github.com/KhronosGroup/Vulkan-Hpp/blob/66ac921bb67efeef0ac298e1cf584ea2eb8e4ec5/generator/VkXMLParser.cpp
[vulkan-hpp]: https://github.com/KhronosGroup/Vulkan-Hpp/blob/66ac921bb67efeef0ac298e1cf584ea2eb8e4ec5/vulkan/vulkan.hpp
[raii-hpp]: https://github.com/KhronosGroup/Vulkan-Hpp/blob/66ac921bb67efeef0ac298e1cf584ea2eb8e4ec5/vulkan/vulkan_raii.hpp
[static-asserts]: https://github.com/KhronosGroup/Vulkan-Hpp/blob/66ac921bb67efeef0ac298e1cf584ea2eb8e4ec5/vulkan/vulkan_static_assertions.hpp
[vkxml]: https://github.com/KhronosGroup/Vulkan-Headers/blob/8d6039a455a7ecc7d2a592ff97f62db4e59b70bf/registry/vk.xml
[rust-ash]: ./rust-ash.md
[rust-vulkanalia]: ./rust-vulkanalia.md
[d-erupted]: ./d-erupted.md
[rust-vulkano]: ./rust-vulkano.md
[cpp-daxa]: ./cpp-daxa.md
[cpp-vuk]: ./cpp-vuk.md
[cpp-tephra]: ./cpp-tephra.md
[rust-wgpu]: ./rust-wgpu.md
[sync-validation]: ./sync-validation.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
