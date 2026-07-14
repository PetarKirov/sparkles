# LWJGL 3 / vulkan4j / jcoronado (Java)

The JVM Vulkan landscape in one page: [LWJGL 3][lwjgl-repo] (the JNI-era workhorse — flyweight struct views over off-heap memory plus a thread-local `MemoryStack`), [club-doki7/vulkan4j][v4j-repo] (a clean-slate binding generated from `vk.xml` onto Java 22's Project Panama `java.lang.foreign` API), and [io7m/jcoronado][jcor-repo] (a hand-written, interface-driven safety layer **on top of** LWJGL 3, built around `try-with-resources` and debugging).

| Field          | LWJGL 3                                     | vulkan4j                                                | jcoronado                                |
| -------------- | ------------------------------------------- | ------------------------------------------------------- | ---------------------------------------- |
| Language       | Java 8+ (bindings), Kotlin (generator)      | Java 22+ (`java.lang.foreign` / [JEP 454][jep454])      | Java 25+                                 |
| License        | BSD-3-Clause                                | BSD-3-Clause                                            | ISC                                      |
| Repository     | [LWJGL/lwjgl3][lwjgl-repo]                  | [club-doki7/vulkan4j][v4j-repo]                         | [io7m-com/jcoronado][jcor-repo]          |
| Documentation  | [javadoc.lwjgl.org][lwjgl-javadoc]          | [vulkan4j.doki7.club][v4j-docs]                         | [io7m.com/software/jcoronado][jcor-docs] |
| Category       | Raw binding (JNI)                           | Raw binding + thin wrapper (Panama FFM)                 | Safety-first wrapper (over LWJGL)        |
| First release  | LWJGL 3.0.0, June 2016 (Vulkan from 3.0.0b) | 2024 (as `chuigda/vulkan4j`, later moved to club-doki7) | 0.0.1, 2018                              |
| Latest release | 3.3.x stable line; 3.4.0 in snapshot        | `v0.4.4`, July 11, 2025                                 | `1.0.0-beta0005`                         |

> [!NOTE]
> This is deliberately one combined page: the three projects form a single dependency-and-philosophy story (jcoronado _wraps_ LWJGL; vulkan4j exists to replace LWJGL's JNI substrate with Panama), and the survey's interesting JVM-specific question — what does a garbage-collected runtime with no ownership types do about Vulkan safety? — is answered by contrasting them, not by any one alone.

---

## Overview

### What it solves

A JVM language faces three problems before it can issue a single `vkCreateInstance`:

1. **ABI-compatible struct memory.** Vulkan's API surface is thousands of C structs passed by pointer. Java objects live on a GC-managed heap with no defined layout, so every binding must marshal into _off-heap_ memory — and do so without generating garbage per call, or frame-time GC pauses defeat the point of using Vulkan.
2. **Calling native functions.** Until Java 22 the only standard mechanism was [JNI][jni], which requires hand- or machine-written C stubs and has a measurable per-call transition cost. [JEP 454][jep454] (Panama FFM, final in Java 22) replaces this with `Linker.downcallHandle` + `MemorySegment`, pure-Java and JIT-optimizable.
3. **Lifetime discipline without ownership types.** Java has no destructors, no affine types, no lifetimes — only `AutoCloseable` + `try-with-resources` and, since Panama, the [`Arena`][arena] scope object whose `close()` invalidates every `MemorySegment` allocated from it (further access throws `IllegalStateException`).

The three subjects are three positions on this terrain. **LWJGL 3** solves (1) and (2) maximally for speed: structs are flyweight Java views over `malloc`'d memory, calls are tuned JNI stubs, and almost no safety is added beyond optional runtime checks. **vulkan4j** re-solves (2) with Panama and hardens (1) and (3) with typed pointers and `Arena`-scoped allocation. **jcoronado** ignores (1)/(2) — it delegates them to LWJGL — and attacks (3) plus type safety head-on with an interface-per-handle, immutable-value-type API.

### Design philosophy

LWJGL's memory design is driven by escape analysis and allocation-free hot loops. From the LWJGL blog's [Memory management in LWJGL 3][lwjgl-blog]:

> _"Passing Java objects to and from native code makes them escape, by definition. This means escape analysis can never eliminate allocations of such objects when dealing with standard JNI code."_

and the stack rule:

> _"The recommendation is that any small buffer/struct allocation that is shortly-lived, should happen via the stack API."_

vulkan4j positions itself explicitly in the lineage of this survey's Rust subjects — its [README][v4j-repo] describes _"a series of graphics and relevant API binding for Java, implemented with Java 22 Project Panama `java.lang.foreign` APIs"_ and states: _"This project is heavily inspired by the [`vulkanalia`] crate"_ — i.e. it is a Java port of [vulkanalia's][vulkanalia] raw-commands-plus-thin-wrapper architecture, swapping Rust ownership for `Arena` scopes.

jcoronado states the safety-first position directly ([README][jcor-repo]):

> _"The `jcoronado` package provides a very thin layer over the Vulkan API that intends to provide some degree of memory and type safety."_

with the stated goal to _"make Vulkan feel like a Java API, without sacrificing performance"_ — _"Extensive use of `try-with-resources` to prevent resource leaks"_ and _"Strongly-typed interfaces with a heavy emphasis on immutable value types"_ are the first two bullets of its feature list.

---

## How it works

### The three layers in code

LWJGL: a thread-local [`MemoryStack`][memorystack] frame is pushed inside `try-with-resources`; struct classes (`VkApplicationInfo`, …) are mutable flyweight views allocated _on that stack_, with fluent setters and a generated `sType$Default()` that writes the correct `VK_STRUCTURE_TYPE_*` value ([release notes][lwjgl-notes]):

```java
// Idiomatic LWJGL 3 Vulkan setup (pattern per the LWJGL blog and
// org.lwjgl.vulkan javadoc; sType$Default per the 3.3.0 release notes)
try (MemoryStack stack = MemoryStack.stackPush()) {
    VkApplicationInfo appInfo = VkApplicationInfo.calloc(stack)
        .sType$Default()
        .pApplicationName(stack.UTF8("demo"))
        .apiVersion(VK.getInstanceVersionSupported());

    VkInstanceCreateInfo ci = VkInstanceCreateInfo.calloc(stack)
        .sType$Default()
        .pApplicationInfo(appInfo);

    PointerBuffer pInstance = stack.mallocPointer(1);
    int err = VK10.vkCreateInstance(ci, null, pInstance);   // err is a raw VkResult int
    // user must check err and wrap the long into a VkInstance dispatchable handle
}
```

vulkan4j: every handle is a generated **record over a `MemorySegment`** — e.g. [`handle/VkDevice.java`][v4j-vkdevice]:

```java
// modules/vulkan/src/main/java/club/doki7/vulkan/handle/VkDevice.java
@ValueBasedCandidate
@UnsafeConstructor
public record VkDevice(@NotNull MemorySegment segment) implements IPointer
```

Its javadoc carries an explicit validity contract — _"The property `segment()` should always be not-null (`segment != NULL && !segment.equals(MemorySegment.NULL)`), and properly aligned to `AddressLayout#byteAlignment()` bytes"_ — and the `@UnsafeConstructor` annotation flags that the constructor performs **no** runtime validation (so machine-generated code stays branch-free). Commands live in four generated classes mirroring Vulkan's loader hierarchy ([`command/`][v4j-command]): `VkStaticCommands`, `VkEntryCommands`, `VkInstanceCommands`, `VkDeviceCommands`, populated by a `VulkanLoader` — the same _per-device function table_ split as [vulkanalia][vulkanalia] and [vulkan-hpp's][vulkan-hpp] dispatcher, which avoids the instance-level trampoline on every device call.

jcoronado: every Vulkan object is an **interface** (implementations live in a separate LWJGL-backed module — _"Strong separation of API and implementation to allow for switching to different bindings at compile-time"_, [README][jcor-repo]), all resources are `AutoCloseable`, and create-info structs are immutable [io7m-style value types][jcor-docs] rather than mutable off-heap views.

### Binding generation & API coverage

- **LWJGL 3** generates its Vulkan bindings via a dedicated pipeline: [`lwjgl3-vulkangen`][vulkangen] _"parses the Vulkan API specification and generates LWJGL 3 Generator templates, with the goal to fully automate the process of updating the LWJGL bindings of Vulkan and all its extensions"_ (repo description). The output is the Kotlin template set that LWJGL's own generator turns into Java classes: per-core-version classes (`VK10` … `VK14`), **400+ per-extension classes** (`KHRSwapchain`, `EXTDebugUtils`, `NVRayTracing`, …), and one struct class + companion `.Buffer` per Vulkan struct ([package javadoc][lwjgl-javadoc]). Coverage is effectively total, including `MoltenVK` bundling on macOS.
- **vulkan4j** generates from `vk.xml` **and `video.xml`** (the Vulkan Video std headers, which several bindings skip), per its [README][v4j-repo]; the generated tree is cleanly partitioned into `bitmask/`, `command/`, `datatype/`, `enumtype/`, `handle/` packages ([source tree][v4j-tree]). Sibling registries (`gl.xml`, GLFW, VMA, shaderc, STB, experimental WebGPU/OpenXR/SDL3) feed the other modules.
- **jcoronado** is **hand-written** — the API module is authored, not generated, and the LWJGL-backed implementation marshals to/from LWJGL's generated structs. The price is coverage: it targets core Vulkan 1.4 plus a curated extension set via a _"type-safe extension mechanism"_, not the full registry.
- **Registry metadata survival:** essentially **none of `vk.xml`'s safety metadata survives** into any of the three. `externsync` attributes, `optional`, handle parent relationships, and valid-usage are not reflected in LWJGL's or vulkan4j's generated types (both emit what the C signature says); jcoronado re-introduces _some_ of it manually (e.g. enum/bitmask typing) but not external-synchronization contracts. This is the recurring finding across raw bindings — compare [erupted][erupted] and [ash][ash].

### Handle lifetime & ownership model

- **LWJGL 3** distinguishes only what the C ABI forces it to: **dispatchable handles** (`VkInstance`, `VkPhysicalDevice`, `VkDevice`, `VkQueue`, `VkCommandBuffer`) are real Java classes carrying their capabilities/function-pointer tables; **non-dispatchable handles are bare `long`s** — a `VkBuffer` and a `VkImage` are the same Java type, and nothing stops you from passing one where the other is expected. There is no ownership: `vkDestroy*` is a plain call, double-destroy and use-after-free are the user's problem. Struct _memory_ lifetime is managed by `MemoryStack` frames (`push`/`pop` pairs enforced in debug mode) and by the debug allocator, which _"tracks allocations and reports leaks with full stack traces"_ ([blog][lwjgl-blog]).
- **vulkan4j** gives **every** handle — dispatchable or not — its own record type wrapping a `MemorySegment`, restoring the type distinction LWJGL erases. Struct and array memory is allocated from a Panama [`Arena`][arena] (tutorial code uses `Arena.ofConfined()`): closing the arena frees and **invalidates** all segments allocated from it, so a dangling struct pointer surfaces as a Java `IllegalStateException` rather than a native crash. This is RAII-ish for _host memory only_ — Vulkan **object** destruction (`vkDestroyDevice` …) remains a manual call; an `Arena` does not own GPU objects.
- **jcoronado** is the only one with real resource ownership semantics: every Vulkan object interface extends `AutoCloseable`, the documented idiom is nested `try-with-resources`, and the [`allocation_tracker` utility module][jcor-docs] wraps any `VulkanHostAllocatorType` (e.g. jemalloc) and _"tracks the current amount of memory allocated for every allocation type."_ Ownership is still dynamic (a forgotten `close()` is a leak found by the tracker, not a compile error) — Java has no affine types to make it static, in contrast to [vulkano's][vulkano] `Arc`-based or Rust's move-based models.

### Synchronization safety

The headline finding: **all three are manual-with-validation; none models synchronization in types, and none automates it.**

- **LWJGL 3** exposes `vkCmdPipelineBarrier(2)`, semaphores, fences, timeline semaphores, and queue-family ownership transfers exactly as C does. The bindings add nothing — correctness comes from the Khronos validation layers (see [sync-validation][sync-validation]).
- **vulkan4j** likewise: following [vulkanalia][vulkanalia], the commands classes are 1:1 projections of the C API; its tutorial walks through writing `VkSubmitInfo` wait/signal semaphores by hand, the same as the C tutorial.
- **jcoronado** makes one structural sync decision — it **requires the `synchronization2` device feature**: _"The package requires the `synchronization2` feature to be available and enabled. This is necessary to avoid having a lot of branching code paths around queue submission and render passes"_ ([README][jcor-repo], noting the feature is on _"99.82% of hardware"_ per the Vulkan hardware database). That is an API-surface simplification (only `VkPipelineStageFlags2`-style paths exist), not automation — barrier placement is still user code.
- **Externally synchronized handles** (`vk.xml` `externsync`) are distinguished **nowhere**: not in LWJGL (a `VkCommandPool` is a `long`), not in vulkan4j (a record with no thread affinity), not in jcoronado (interfaces are not documented as confined). The JVM adds its own hazard here: LWJGL's `MemoryStack` is **thread-local**, so a struct allocated on one thread's stack must not be retained across threads or frames — a discipline documented in the blog but unenforced. No JVM binding has an equivalent of even [vulkanalia's][vulkanalia] doc-level externsync notes.

### Type-system techniques

Java has no phantom types over primitives, no linear/affine ownership, no lifetimes, and (pre-Valhalla) no zero-cost value wrappers — and the three projects' divergent answers map exactly onto that gap:

- **LWJGL 3**: dispatchable-handle classes only; enums and bitmasks are plain `int` constants in the version/extension classes; `pNext` is an untyped `long` (with `sType$Default()` as the lone structure-chain aid — there is no typed `pNext` chain builder). Maximum speed, near-zero typing.
- **vulkan4j**: the most interesting JVM answer. Per-handle records annotated `@ValueBasedCandidate` (eligible for Valhalla flattening later); the [`ffm-plus`][ffm-plus] companion library contributes **typed pointers** (`BytePtr`, `IntPtr`, `PointerPtr`, plus per-handle `VkDevice.Ptr` with `slice()`/`offset()`/`reinterpret()` and `Iterable` support) so a `uint32_t*` and a `char*` are distinct Java types. Enum/bitmask typing is done with `@EnumType` and `@Bitmask` annotations **on `int` parameters, enforced by an external IntelliJ inspections plugin** ([`ffm-plus-inspections`][ffm-plus-insp]) — a candid admission that Java's type system cannot brand integers, so the checking is pushed into tooling. This is the static-analysis analogue of what D would do with `enum` + `@safe` natively.
- **jcoronado**: classic OO typing — one interface per Vulkan object, real Java `enum`s for Vulkan enums, immutable value types for create-info structs, and a type-safe extension lookup so an extension's functions are only reachable through its typed interface. Strongest nominal typing of the three, achieved by hand and paid for in wrapper objects.
- **Absent everywhere**: builder typestate, typed `pNext` chains, capability/extension typing at the type level (LWJGL checks function-pointer presence at runtime via its capabilities classes), and any compile-time encoding of `externsync` or handle parentage.

### Overhead & escape hatches

This is where the **Panama-vs-JNI** contrast lives:

- **LWJGL 3 (JNI)**: generated, hand-tuned JNI stubs; structs are flyweights over `malloc`/jemalloc memory (no `ByteBuffer.allocateDirect()`, which the blog calls _"horrible: It is slow, much slower than the raw malloc() call. … It scales badly under contention."_ — [blog][lwjgl-blog]); `MemoryStack` makes per-frame struct traffic allocation-free. Runtime parameter checks (null-termination, capacity, function-pointer presence) are on by default and globally removable with `-Dorg.lwjgl.util.NoChecks=true` / `Configuration.DISABLE_CHECKS` ([Configuration javadoc][lwjgl-config]) — _"Disabled LWJGL checks have no runtime overhead"_ beyond bytecode size affecting inlining ([Checks javadoc][lwjgl-checks]). Escape hatch: there is nothing to escape from — handles are already `long`s and struct classes expose their raw `address()`.
- **vulkan4j (Panama FFM)**: downcalls go through cached `MethodHandle`s from `Linker.downcallHandle`. Cross-project benchmarks ([Glavo/java-ffi-benchmark][glavo-bench]; production write-ups report ~49.7 ns vs ~56.6 ns per call-only op, FFM vs JNI ([Java Code Geeks][jcg-ffm])) put plain FFM downcalls **at par to ~12% faster than JNI**, and `Linker.Option.critical` (né `isTrivial`, Java 21+) — the FFM analogue of critical JNI — pushes short leaf calls to roughly **160% of JNI throughput**. The cost model's footgun is failing to cache the handle (symbol resolution per call costs hundreds of ns). `MemorySegment` access is bounds- and liveness-checked; the JIT hoists these in hot loops, but they are a real (small) runtime tax LWJGL's raw `Unsafe`-based access does not pay. Escape hatch: every wrapper is a record over a public `MemorySegment`, and `@UnsafeConstructor` lets you wrap any raw address back into a typed handle.
- **jcoronado**: an entire object layer over LWJGL — interface dispatch, immutable value objects per create-info, and marshalling into LWJGL structs per call. It is honest about the trade: the goal is Vulkan that _feels like Java_ "without sacrificing performance", which holds at the granularity Vulkan encourages (chunky setup calls, pre-recorded command buffers) but would not for per-draw hot paths. Escape hatch: the API/implementation split — the implementation types expose the underlying LWJGL objects/handles.

### Error handling & validation integration

- **LWJGL 3**: `vkCreateInstance` returns a raw `int`; checking it against `VK_SUCCESS` is entirely user code (every LWJGL Vulkan demo defines its own `check(int)` helper). Validation comes from enabling the standard layers + `EXT_debug_utils`, both fully bound; LWJGL's own contribution is the JVM-side **debug allocator** (leak reports with stack traces) and `MemoryStack` push/pop mismatch detection in debug mode.
- **vulkan4j**: commands return the `VkResult` integer carrying the `@EnumType` annotation, with the IDE inspections flagging unchecked/wrongly-compared constants — detection at edit time rather than run time. Liveness errors in host memory become Java exceptions via `Arena`/`MemorySegment` confinement rather than segfaults, which is a genuine debuggability upgrade over JNI bindings.
- **jcoronado** is the **debugging-oriented** pole: failing `VkResult`s become thrown `VulkanException`s (no silent error codes), resources are leak-proofed by `try-with-resources`, host allocations are observable through the allocation-tracker module, and the [`swapchain` utility module][jcor-docs] packages the notoriously error-prone swapchain-recreation dance. The whole design optimizes for _correct-by-construction application code under validation layers_, accepting wrapper overhead.

---

## Strengths

- **LWJGL 3** is the production-proven baseline: total registry coverage kept current by [`lwjgl3-vulkangen`][vulkangen], allocation-free struct traffic via `MemoryStack`, hand-tuned JNI, MoltenVK bundling, and a debug allocator — Minecraft-scale deployment pedigree.
- **vulkan4j** shows what a **post-JNI generated binding** looks like: per-handle nominal types (fixing LWJGL's bare-`long` non-dispatchable handles), typed pointers, `Arena`-scoped host memory that fails with exceptions instead of corruption, `video.xml` coverage, and FFM call overhead at-or-below JNI.
- **jcoronado** demonstrates that meaningful Vulkan safety is achievable **purely with mainstream-Java idioms** — interfaces, immutability, `AutoCloseable` — plus genuinely novel touches (allocation tracking, mandated `synchronization2`, API/impl separation).
- The trio collectively maps the JVM design space: each successive layer trades a measured amount of overhead for a class of bugs.

## Weaknesses

- **No synchronization help anywhere**: barriers, semaphores, fences, timeline semaphores, and queue-family transfers are raw on all three; no render graph, no auto-sync, no typed sync — the JVM ecosystem has no analogue of [vulkano][vulkano], [daxa][daxa], or [vuk][vuk].
- **`externsync` is invisible** in all three type systems; LWJGL's thread-local `MemoryStack` adds a JVM-specific cross-thread lifetime hazard on top.
- **LWJGL**: non-dispatchable handles are untyped `long`s; `pNext` chains are untyped; error codes uncheckable by the compiler.
- **vulkan4j**: young (0.4.x, small team), Java 22+ only, and its enum/bitmask checking lives in an **IDE plugin** — `javac` alone enforces none of it; `MemorySegment` bounds/liveness checks are a small runtime tax.
- **jcoronado**: coverage is a curated subset (Vulkan 1.4 + selected extensions, Java 25+, `synchronization2` mandatory), still pre-1.0 (`1.0.0-beta0005`), and the wrapper-object layer makes it the wrong tool for per-draw hot loops.
- Pre-Valhalla Java cannot make any of these wrappers true zero-cost: records and interfaces are heap references unless escape analysis cooperates.

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                | Trade-off                                                                          |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| LWJGL: structs as flyweight views + thread-local `MemoryStack`       | Zero GC traffic per call; escape-analysis-friendly; _"shines even in tight loops"_       | Manual `push`/`pop` discipline; thread-confined memory; mutable aliasable views    |
| LWJGL: non-dispatchable handles as `long`                            | Zero wrapper cost in the JNI era                                                         | `VkBuffer`/`VkImage`/`VkFence` are indistinguishable to the compiler               |
| LWJGL: runtime checks on by default, killable via `NoChecks`         | Crash-avoidance for newcomers, raw speed for shipping builds                             | Checks are dynamic and coarse — nothing like valid-usage; off means off everywhere |
| vulkan4j: Panama FFM instead of JNI                                  | Pure-Java, no C stubs; cached downcall handles match/beat JNI; `critical` for leaf calls | Java 22 floor; per-access segment bounds/liveness checks; handle-caching footgun   |
| vulkan4j: record-per-handle + `ffm-plus` typed pointers              | Restores nominal typing over raw addresses; `@ValueBasedCandidate` is Valhalla-ready     | Wrapper allocation until Valhalla; `@UnsafeConstructor` trusts the caller          |
| vulkan4j: `@EnumType`/`@Bitmask` checked by an IntelliJ plugin       | Brands `int`s without runtime cost, which Java's type system cannot express              | Enforcement is tooling-optional — a plain `javac` build checks nothing             |
| jcoronado: hand-written interfaces over LWJGL, immutable value types | Real nominal + ownership (`AutoCloseable`) safety; implementation swappable              | Coverage lags the registry; wrapper objects + marshalling per call                 |
| jcoronado: require `synchronization2`                                | One modern sync code path; _"avoid having a lot of branching code paths"_                | Excludes the ~0.2% of devices without it; still no sync automation                 |

---

## Sources

- [LWJGL/lwjgl3 — GitHub repository][lwjgl-repo] · [org.lwjgl.vulkan javadoc][lwjgl-javadoc]
- [Memory management in LWJGL 3 — LWJGL blog][lwjgl-blog] (escape-analysis and `MemoryStack` quotes)
- [LWJGL/lwjgl3-vulkangen — Vulkan template generator][vulkangen]
- [`org.lwjgl.system.Checks` javadoc][lwjgl-checks] · [`Configuration` javadoc][lwjgl-config] · [LWJGL release notes][lwjgl-notes]
- [club-doki7/vulkan4j — GitHub repository][v4j-repo] · [docs site][v4j-docs] · [generated source tree][v4j-tree]
- [`handle/VkDevice.java` — generated handle record + validity javadoc][v4j-vkdevice] · [`command/` — loader-hierarchy commands classes][v4j-command]
- [club-doki7/ffm-plus-inspections — IntelliJ checking for `@EnumType`/`@Bitmask`][ffm-plus-insp]
- [io7m-com/jcoronado — GitHub repository][jcor-repo] · [io7m.com documentation][jcor-docs]
- [JEP 454: Foreign Function & Memory API][jep454] · [`java.lang.foreign.Arena` javadoc][arena] · [JNI specification][jni]
- [Glavo/java-ffi-benchmark — FFM vs JNI vs JNA/JNR][glavo-bench] · [FFM-in-production overhead figures][jcg-ffm]
- Related: [vulkanalia (Rust)][vulkanalia] · [ash (Rust)][ash] · [erupted (D)][erupted] · [Vulkan-Hpp (C++)][vulkan-hpp] · [vulkano (Rust)][vulkano] · [Silk.NET (C#)][silknet] · [daxa][daxa] · [vuk][vuk] · [sync validation][sync-validation] · [concepts][concepts] · [comparison][comparison] · [survey index][index]

<!-- References -->

[lwjgl-repo]: https://github.com/LWJGL/lwjgl3
[lwjgl-javadoc]: https://javadoc.lwjgl.org/org/lwjgl/vulkan/package-summary.html
[lwjgl-blog]: https://blog.lwjgl.org/memory-management-in-lwjgl-3/
[vulkangen]: https://github.com/LWJGL/lwjgl3-vulkangen
[lwjgl-checks]: https://javadoc.lwjgl.org/org/lwjgl/system/Checks.html
[lwjgl-config]: https://javadoc.lwjgl.org/org/lwjgl/system/Configuration.html
[lwjgl-notes]: https://github.com/LWJGL/lwjgl3/blob/32593afe25e2f1394c3425673f1b71a0122f5cd4/doc/notes/full.md
[memorystack]: https://javadoc.lwjgl.org/org/lwjgl/system/MemoryStack.html
[v4j-repo]: https://github.com/club-doki7/vulkan4j
[v4j-docs]: https://vulkan4j.doki7.club/
[v4j-tree]: https://github.com/club-doki7/vulkan4j/tree/50baa5e5401a3998b34979a7066cabdde1fda266/modules/vulkan/src/main/java/club/doki7/vulkan
[v4j-vkdevice]: https://github.com/club-doki7/vulkan4j/blob/50baa5e5401a3998b34979a7066cabdde1fda266/modules/vulkan/src/main/java/club/doki7/vulkan/handle/VkDevice.java
[v4j-command]: https://github.com/club-doki7/vulkan4j/tree/50baa5e5401a3998b34979a7066cabdde1fda266/modules/vulkan/src/main/java/club/doki7/vulkan/command
[ffm-plus]: https://github.com/club-doki7/vulkan4j/tree/50baa5e5401a3998b34979a7066cabdde1fda266/modules/ffm-plus
[ffm-plus-insp]: https://github.com/club-doki7/ffm-plus-inspections
[jcor-repo]: https://github.com/io7m-com/jcoronado
[jcor-docs]: https://www.io7m.com/software/jcoronado/
[jep454]: https://openjdk.org/jeps/454
[arena]: https://docs.oracle.com/en/java/javase/22/docs/api/java.base/java/lang/foreign/Arena.html
[jni]: https://docs.oracle.com/en/java/javase/22/docs/specs/jni/index.html
[glavo-bench]: https://github.com/Glavo/java-ffi-benchmark
[jcg-ffm]: https://www.javacodegeeks.com/2026/03/project-panamas-ffm-api-in-production-replacing-jni-without-writing-c-wrappers.html
[vulkanalia]: ./rust-vulkanalia.md
[`vulkanalia`]: ./rust-vulkanalia.md
[ash]: ./rust-ash.md
[erupted]: ./d-erupted.md
[vulkan-hpp]: ./cpp-vulkan-hpp.md
[vulkano]: ./rust-vulkano.md
[silknet]: ./csharp-silknet.md
[daxa]: ./cpp-daxa.md
[vuk]: ./cpp-vuk.md
[sync-validation]: ./sync-validation.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[index]: ./index.md
