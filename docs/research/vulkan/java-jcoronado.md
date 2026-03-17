# Java: `jcoronado`

## Mechanism: Immutable API Surfaces + Typed Extensions + Scoped Lifetime Management

`jcoronado` is intentionally a thin layer over LWJGL Vulkan bindings, but it adds an opinionated safety envelope: immutable value objects, typed extension interfaces, explicit lifecycle control via `AutoCloseable`, and a constrained synchronization model.

## Immutable Value Model

The project states a "heavy emphasis on immutable value types" and implements most API structs as immutable interfaces generated via `org.immutables` (`@Value.Immutable`). In practice, this means create-info/data payloads are passed around as immutable values instead of mutable C-style structs.

Pattern relevance for D: this maps well to immutable-by-default input descriptors and compile-time validated builder APIs.

## Type-Safe Extension Typing

Extensions share a common `VulkanExtensionType` base, but each extension is exposed as a typed interface in its own module (for example, `VulkanExtKHRSurfaceType`, `VulkanDebugUtilsType`).

The key API pattern is typed discovery:

- `enabledExtensions()` returns `Map<String, VulkanExtensionType>`.
- `findEnabledExtension(name, Class<T>)` returns `Optional<T>` only if both the extension name and runtime type match.

This provides safer extension dispatch than raw function-pointer access while still keeping extension boundaries explicit.

Pattern relevance for D: model extensions as capability interfaces/traits, and resolve them through typed queries rather than untyped name lookups.

## Lifecycle Management Choices

All Vulkan handles implement `AutoCloseable` (`VulkanHandleType`), and the API strongly encourages `try-with-resources` usage. The README and examples repeatedly use resource scopes (`try (...) { ... }`) for instances, swapchain images, mapped memory, and helper managers.

Implementation-side, closed-handle checks are explicit (`checkNotClosed()`), throwing `VulkanDestroyedException` on use-after-destroy.

Pattern relevance for D: RAII/scope guards plus explicit "destroyed" state checks for debug builds can mirror this lifecycle discipline.

## Synchronization Model Choices

`jcoronado` deliberately narrows Vulkan's feature matrix:

- Requires Vulkan 1.3+.
- Requires `synchronization2` and `timelineSemaphore` as baseline features.
- Enables both during logical-device feature packing.
- Warns on missing `synchronization2` during device enumeration, and requests these features at device-creation time.

This is a design tradeoff: narrower compatibility surface in exchange for simpler, less branched synchronization code paths.

The API also annotates externally synchronized operations with `@VulkanExternallySynchronizedType` (queue submits, wait-idle paths, close operations, etc.), documenting host-thread synchronization obligations directly in signatures.

Pattern relevance for D: explicitly choose a synchronization baseline and encode host-sync obligations into API metadata/types.

## Key Patterns To Reuse In D Research

1. Prefer immutable API payloads for Vulkan create/submit descriptors.
2. Treat extensions as typed capabilities with explicit acquisition.
3. Make lifecycle scopes cheap and pervasive; fail fast on use-after-destroy.
4. Collapse synchronization variants behind a required modern baseline when ergonomics/safety outweigh legacy coverage.
5. Surface externally synchronized contracts directly in API declarations (attributes/UDAs in D).

## Sources Used

- Repository README (`Background`, `Features`, `Requirements`, and utility examples): <https://github.com/io7m-com/jcoronado>
- API interfaces (`VulkanExtensionType`, `VulkanInstanceType`, `VulkanLogicalDeviceType`, `VulkanExternallySynchronizedType`, `VulkanHandleType`)
- Extension API modules (`ext_debug_utils`, `khr_surface`)
- LWJGL implementation checks (`VulkanLWJGLInstanceProvider`, `VulkanLWJGLPhysicalDevice`, `VulkanLWJGLInstance`)
