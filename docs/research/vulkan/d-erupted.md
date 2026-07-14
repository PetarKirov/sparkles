# ErupteD & the D landscape (D)

Auto-generated, dependency-free D bindings for Vulkan with three-tier function loading and a per-device dispatch struct — the de-facto (but stale) D binding, surveyed here together with every other route a D program has into Vulkan: `d-vulkan`, `derelict-vulkan`, `bindbc-vulkan`, `nuvk`, and ImportC on the C headers.

| Field          | Value                                                                                           |
| -------------- | ----------------------------------------------------------------------------------------------- |
| Language       | D (generator: Python 3 + `lxml.etree`)                                                          |
| License        | MIT (generated files carry the Khronos copyright + MIT notice, see [`types.d`][types])          |
| Repository     | [ParticlePeter/ErupteD][repo] · generator: [ParticlePeter/V-Erupt][verupt]                      |
| Documentation  | [README][readme] · [`erupted` on code.dlang.org][dub]                                           |
| Category       | Thin / generated binding                                                                        |
| First release  | 2016 (as a fork of [ColonelThirtyTwo/dvulkan][dvulkan])                                         |
| Latest release | `2.1.98+v1.3.248` — April 20, 2023 (build metadata = Vulkan-Docs version it was generated from) |

> [!WARNING]
> **Maintenance status (checked June 11, 2026):** the last commit to ErupteD `master` and the last
> dub release both date to **April 20, 2023** (Vulkan header `1.3.248`). The current
> `Vulkan-Headers` `main` is at `VK_HEADER_VERSION` **353** — ErupteD is ~105 header revisions
> behind and predates Vulkan 1.4 entirely. Everything below describes a high-quality but
> **effectively unmaintained** project; the [D landscape](#the-broader-d-landscape) section
> assesses the alternatives.

---

## Overview

### What it solves

ErupteD answers the same question as [Ash][ash] in Rust or the raw `vulkan.h` in C: _give me the
complete Vulkan API, faithfully, in my language, with the function-pointer loading ritual handled
for me_. Vulkan deliberately ships as a C header plus a machine-readable registry ([`vk.xml`][vkxml]);
every binding must (a) translate ~17,000 lines of types and ~2,800 lines of command pointers, and
(b) decide how commands are _loaded_ — through the loader's exported trampolines, through
`vkGetInstanceProcAddr`, or through `vkGetDeviceProcAddr` for dispatch-free device calls.

ErupteD does (a) by code generation from the official registry and (b) by committing fully to
**runtime dynamic loading**: it does not link against `libvulkan` at all. The
`erupted.vulkan_lib_loader` module `dlopen`s the shared library, and three loader tiers —
`loadGlobalLevelFunctions()`, `loadInstanceLevelFunctions(VkInstance)`,
`loadDeviceLevelFunctions(VkDevice|VkInstance)` — populate module-level function pointers. The
loading strategy follows Intel's [API without Secrets][intel] tutorial, which the [README][readme]
cites as its basis. Device-level loading exists in two flavors precisely because of dispatch
overhead — per the README, with instance-level acquisition

> _"the acquired functions call indirectly through the `VkInstance` and will be internally
> dispatched to various devices by the implementation"_

whereas `loadDeviceLevelFunctions(VkDevice)` fetches direct per-device entry points that skip the
loader trampoline.

### Design philosophy

Minimalism and zero dependencies. The 2.x redesign ([README § ErupteD v2.x.x][readme]) states:

> _"All dependency requirements have been removed, including derelict-util to load
> `vkGetInstanceProcAddr`. This functionality has been replaced through the new module
> `vulkan_lib_loader`."_

The same release extracted the generator into its own project, [V-Erupt][verupt], and moved
platform-specific extensions out of the core: instead of shipping bindings to Xlib/XCB/Wayland
types (and forcing those dependencies on everyone), ErupteD exposes a
[mixin template](#type-system-techniques) the _user_ instantiates with the platform identifiers
they need. The philosophy is exactly that of a thin binding: be the C API, in D, with D
conveniences (default-initialized `sType`, named enums, `nothrow @nogc` annotations) — and nothing
that costs anything. There is no wrapper layer, no RAII, no synchronization model. Within this
survey it is the D analogue of [Ash][ash] / [vulkanalia's `vulkanalia-sys` tier][vulkanalia], not
of [Vulkano][vulkano].

---

## How it works

A complete startup sequence, condensed from the [README][readme]:

```d
import erupted;                     // types + functions + dispatch device
import erupted.vulkan_lib_loader;   // optional: dlopen-based bootstrap

loadGlobalLevelFunctions();         // dlopens libvulkan, loads vkGetInstanceProcAddr,
                                    // vkCreateInstance, vkEnumerateInstance*
VkInstance instance;
vkCreateInstance(&createInfo, null, &instance);
loadInstanceLevelFunctions(instance);   // physical-device + surface functions

VkDevice device;
vkCreateDevice(physDevice, &deviceCI, null, &device);
loadDeviceLevelFunctions(device);       // direct, dispatch-free device commands
```

The generated tree is four modules plus a platform-extension template:
`erupted.types` (all enums/structs/handles, [17,030 lines][types]), `erupted.functions`
(`PFN_` aliases, `__gshared` pointers, and the three loaders, [2,843 lines][functions]),
`erupted.dispatch_device`, `erupted.vulkan_lib_loader`, and `erupted.platform_extensions`.

### Binding generation & API coverage

The generator, [`erupt_dlang.py`][gen] in [V-Erupt][verupt], is not an independent `vk.xml` parser
— it plugs into Khronos's own registry framework. Its docstring is explicit:

> _"D Vulkan bindings generator, based off of and using the Vulkan-Docs code."_

It appends the `Vulkan-Docs` checkout's `registry/`/`scripts/` directories to `sys.path`, imports
the official `reg.py` `Registry` and `generator.py` `OutputGenerator`, and registers a `DGenerator`
subclass plus a directory of D templates (`templates/dlang/{types,functions,dispatch_device,…}.py`).
Both `vk.xml` and `video.xml` are processed (`reg.loadElementTree(etree.parse(vk_xml))`), so the
Vulkan Video `StdVideo*` types are covered too. Since 2023 a lightweight `Vulkan-Headers` checkout
can substitute for the full `Vulkan-Docs` tree (commit `2023-04-18`, ["Vulkan-Headers (lightweight)
can optionally be used as source of generation"][repo]).

Coverage at the frozen point is **complete**: every core 1.0–1.3 command and every extension in
registry `1.3.248`, including platform and (since Vulkan `1.2.135`) provisional/beta extensions,
which are gated behind the same opt-in mixin as platform ones. Versioning encodes provenance: dub
version `2.1.98+v1.3.248` uses SemVer build metadata to pin the exact Vulkan-Docs tag the bindings
were generated from.

What does **not** survive generation is most of the registry's _semantic_ metadata.
[`erupt_dlang.py`][gen] contains no handling of `externsync`, `successcodes`, `errorcodes`,
`optional`, or `len` attributes — they are consumed by Khronos's `reg.py` for validity text, but
the D templates never read them. Parameter names and types are the only contract that crosses over
(grep the generator: the attribute names simply do not appear). This is the common failure mode of
thin bindings — compare [Ash][ash], which likewise drops `externsync`, and contrast
[vulkan-hpp][vulkan-hpp]'s `successcodes`-driven return-type synthesis.

### Handle lifetime & ownership model

Handles are exactly the C model, reproduced via string mixins ([`types.d`][types]):

```d
enum VK_DEFINE_HANDLE( string name ) = "struct " ~ name ~ "_T; alias " ~ name ~ " = " ~ name ~ "_T*;";

version( D_LP64 ) {
    alias VK_DEFINE_NON_DISPATCHABLE_HANDLE( string name ) = VK_DEFINE_HANDLE!name;
    enum VK_NULL_ND_HANDLE = null;
} else {
    enum VK_DEFINE_NON_DISPATCHABLE_HANDLE( string name ) = "alias " ~ name ~ " = ulong;";
    enum VK_NULL_ND_HANDLE = 0uL;
}
```

On 64-bit targets every handle — dispatchable or not — is a distinct opaque-struct pointer type, so
`VkSemaphore` and `VkFence` cannot be confused (the same strong-typedef guarantee
`VK_DEFINE_NON_DISPATCHABLE_HANDLE` gives C on 64-bit). On 32-bit targets non-dispatchable handles
all collapse to `ulong` and the type distinction **vanishes**, which also forces the awkward
`VK_NULL_ND_HANDLE` companion to `VK_NULL_HANDLE` (the README documents this and recommends
_"building 64 Bit apps and ignore `VK_NULL_ND_HANDLE`"_, hoping `multiple alias this` would one day
fix it — it never landed in D).

There is **no ownership or lifetime model**: no destructors, no RAII, no parent-child tracking
(`VkDevice` owning `VkBuffer`, `VkCommandPool` owning its `VkCommandBuffer`s). Create/destroy
discipline, use-after-destroy, and destruction ordering are entirely the caller's problem, exactly
as in C. Nothing connects to D's `@safe`/[DIP1000][dip1000] scope checking — the modules are
annotated `nothrow @nogc` (module-top attribute in [`types.d`][types] and [`functions.d`][functions])
but not `@safe`, and every command taking a pointer is callable only from `@system`/`@trusted` code.

### Synchronization safety

Not modeled — and that absence is the headline finding for the sparkles delta. Fences, binary and
timeline semaphores, events, pipeline barriers, render-pass dependencies, and queue-family
ownership transfers appear exactly as their C structs (`VkImageMemoryBarrier` with raw
`srcQueueFamilyIndex`/`dstQueueFamilyIndex` `uint32_t`s, [`types.d` line 5002][types]); correctness
is delegated wholesale to the [validation layers][sync-validation].

The one place synchronization _thinking_ does appear is host-side function dispatch, and it is a
hazard rather than a guarantee: the loaded commands are **`__gshared` module-level function
pointers** ([`functions.d` line 702][functions]) — shared, unsynchronized, mutable globals. The
generated doc comment on `loadDeviceLevelFunctions(VkDevice)` warns verbatim:

> _"calling this function again with another VkDevices will overwrite the `__gshared` functions
> retrieved previously"_

So a two-device program using the convenient global tier is silently broken; the supported
multi-device path is the [`DispatchDevice`](#overhead--escape-hatches) struct, which encapsulates
its own pointer table per device. Vulkan's own external-synchronization contract (the
[`externsync`][externsync] attribute in `vk.xml` — e.g. that `VkCommandPool` and `VkQueue` access
must be host-synchronized) is not represented in types or docs at any tier.

### Type-system techniques

ErupteD uses a narrow but real slice of D's metaprogramming, all of it compile-time-only:

- **String-mixin strong handles** — `VK_DEFINE_HANDLE!q{VkInstance}` (above) generates distinct
  opaque pointer types; the closest thing to branding in the binding, free at runtime.
- **Default-initialized `sType`** — the single biggest ergonomic win over C and over ImportC.
  Every one of the **666** `sType`-bearing structs in [`types.d`][types] carries a D default field
  initializer:

  ```d
  struct VkBufferCreateInfo {
      VkStructureType      sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
      const( void )*       pNext;
      VkBufferCreateFlags  flags;
      // ...
  }
  ```

  `VkBufferCreateInfo bci;` is correctly tagged with zero runtime cost — a whole class of
  `VUID-*-sType-sType` validation errors becomes unrepresentable. (This is what
  [vulkan-hpp][vulkan-hpp] needs constructors for and [Ash][ash] needs `::default()` for; D's
  default field initializers give it to a plain POD struct.)

- **Named enums + C-style aliases** — `enum VkResult { VK_SUCCESS = 0, … }` plus generated
  module-level manifest constants (`enum VK_SUCCESS = VkResult.VK_SUCCESS;`), so both scoped and
  C-flavored spellings compile.
- **Mixin-template platform/beta gating** — `mixin Platform_Extensions!USE_PLATFORM_XLIB_KHR;`
  (or `!ENABLE_BETA_EXTENSIONS`) instantiates, in the _user's_ module, the extension types,
  function pointers, and extended `loadInstanceLevelFunctions`/`loadDeviceLevelFunctions`/
  `DispatchDevice` definitions for the chosen platforms. Dependency choice (e.g. which `xlib-d`
  binding supplies `Display`) stays with the user. This is a genuinely D-flavored answer to a
  problem [vulkan-hpp][vulkan-hpp] solves with `#ifdef VK_USE_PLATFORM_*` and
  [vulkan-zig][vulkan-zig] solves with comptime API specs.

What it does **not** use is the rest of the survey's toolbox: bitmask flags are weak aliases
(`alias VkAccessFlags = VkFlags;` where `alias VkFlags = uint32_t;` — every flags type is mutually
assignable, unlike vulkan-hpp's `vk::Flags<BitType>`); `pNext` is `const(void)*` with no typed
structure-chain machinery; no typestate, no capability/extension typing, no `@safe`, no
[DIP1000][dip1000] `scope` on pointer parameters. For a binding generated in 2016-era D that is
unsurprising; for a 2026 D library it is the gap [the comparison doc][comparison] quantifies.

### Overhead & escape hatches

There is nothing to escape _from_: ErupteD **is** the raw API. Every command is one indirect call
through a function pointer — the same cost profile as C with `volkLoadDevice`-style loading, and
strictly cheaper than calling the loader's exported trampolines once device-level loading is used.
No locks, no hash maps, no reference counts, no per-resource state. The binary-size/compile-time
cost of the 17k-line `types.d` is paid once per build.

[`DispatchDevice`][dispatch] is the only "abstraction", and it is a plain struct: a `VkDevice`, a
`const(VkAllocationCallbacks)*`, and the full table of device-level pointers loaded via
`vkGetDeviceProcAddr`. Convenience members drop the `vk` prefix and supply the stored
device/allocator implicitly:

```d
auto dd = DispatchDevice( device );
dd.DestroyDevice;                  // instead of dd.vkDestroyDevice( dd.vkDevice, dd.pAllocator )
dd.commandBuffer = cmd_buffer;     // public member feeds the Cmd* convenience calls
dd.BeginCommandBuffer( &beginInfo );
dd.CmdBindPipeline( VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline );
```

The prefix is dropped because _"function pointers can't be overloaded with regular functions"_
([README][readme]) — a D-specific naming constraint, not a design flourish. Cost: one extra member
load per call versus a global; in exchange, per-device tables make multi-GPU correct.

### Error handling & validation integration

`VkResult` is returned raw, as a D `enum`; there is no exception layer, no
[`Expected`][expected-idiom]-style wrapper, no success/error-code partitioning (the registry's
`successcodes`/`errorcodes` metadata [does not survive generation](#binding-generation--api-coverage)).
Checking `VK_SUCCESS` is the caller's job. Nothing interferes with the validation layers — since
the binding adds no behavior, `VK_LAYER_KHRONOS_validation` and [synchronization
validation][sync-validation] see exactly the calls the application made, and remain the **only**
correctness net at every level. `VK_EXT_debug_utils` is bound like any other extension, with no
helper sugar.

---

## The broader D landscape

No other D option changes the abstraction level — every route below is also a thin binding. As of
June 11, 2026:

| Option                        | Mechanism                                                                                      | Status (June 2026)                                                                                                                                  |
| ----------------------------- | ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`erupted`][dub]              | Generated from `vk.xml` via official `reg.py`; runtime `dlopen` loading                        | **Stale**: last release/commit April 20, 2023 (header `1.3.248`); ~6k total downloads                                                               |
| [`d-vulkan`][dvulkan]         | The predecessor; `vkdgen.py` generator                                                         | **Archived**; last push September 21, 2016                                                                                                          |
| [`derelict-vulkan`][derelict] | Hand-maintained dynamic binding in the Derelict family                                         | Dead; v`0.0.20`, the Derelict family itself was superseded by BindBC                                                                                |
| [`bindbc-vulkan`][bindbc]     | [BindBC][bindbc-repo]-style dynamic binding (`@nogc nothrow`, BetterC-compatible family)       | **New & minimal**: v`0.0.1`, July 31, 2025 (Timur Gafarov / DLangGamedev); one release, low coverage                                                |
| [`nuvk`][nuvk]                | `@nogc` loader + utilities; links `vulkan-1` directly; extensions preloaded via dub `versions` | **Active**: v`0.5.1`, October 2025; Vulkan **1.3 minimum** ("mainly due to … dynamic rendering"); built for Inochi2D, includes SPIR-V introspection |
| ImportC on `vulkan_core.h`    | Compile the C header directly with `-P-I<include>` (see [ImportC guideline][importc-guide])    | **Always current** — verified below against header `353`                                                                                            |

Two observations matter for sparkles:

1. **ImportC works on today's headers.** Verified June 11, 2026 with LDC 1.41.0 (DMD 2.111
   frontend): a one-line `vk.c` shim `#include <vulkan/vulkan_core.h>` against `Vulkan-Headers`
   `main` (plus its `vk_video/*.h` siblings on the include path) compiles and runs:

   ```bash
   printf '#include <vulkan/vulkan_core.h>\n' > vk.c
   ldc2 -I. -P-I. main.d vk.c   # main.d: VkApplicationInfo ai; → VK_HEADER_VERSION == 353 ✓
   ```

   ImportC yields C-faithful types — which means **no** default-initialized `sType` (C has no
   default field initializers), weak typedef handles, and prototypes that require linking the
   loader (or defining `VK_NO_PROTOTYPES` and loading manually). It trades ErupteD's ergonomics
   for guaranteed freshness; per the [ImportC guideline][importc-guide], the shim needs a
   multi-file dub package, not a single-file script.

2. **Nobody in the D ecosystem has built above the thin tier.** The only wrapper-flavored entries —
   [`vulkanish`][vulkanish] (helper templates over ErupteD, `1.0.0-alpha.1`) and [`nuvk`][nuvk]
   (engine-specific utilities) — are small or project-bound. There is no D equivalent of
   [Vulkano][vulkano], [vuk][vuk], or [Daxa][daxa]: no RAII layer, no sync automation, no render
   graph. A `sparkles:vulkan` library targeting typed handles (`@safe` + [DIP1000][dip1000]
   `scope`), CTFE-generated typed `pNext` chains, and Design-by-Introspection capability traits
   would occupy entirely empty territory — with V-Erupt's `reg.py` integration and ErupteD's
   `sType`-defaulting as proven, borrowable techniques.

---

## Strengths

- **Complete, registry-faithful coverage** at its freeze point — core 1.0–1.3, all extensions,
  Vulkan Video, beta extensions — generated through Khronos's own `reg.py` framework rather than an
  ad-hoc parser.
- **Default-initialized `sType` on all 666 tagged structs** — zero-cost elimination of an entire
  validation-error class; the single best idea for any future D binding to inherit.
- **Zero dependencies, zero overhead**: no link-time `libvulkan` requirement, one indirect call per
  command, plain `nothrow @nogc` PODs throughout.
- **Three-tier loading done right**, including direct `vkGetDeviceProcAddr` device tables and a
  per-device `DispatchDevice` for multi-GPU correctness.
- **User-controlled platform/beta extension instantiation** via `mixin Platform_Extensions!(…)` —
  no forced windowing-system dependencies.
- **Honest versioning**: SemVer build metadata (`+v1.3.248`) pins the generated-from registry tag.

## Weaknesses

- **Unmaintained**: frozen at Vulkan `1.3.248` (April 2023); no Vulkan 1.4, no
  `VK_KHR_maintenance6`+, no new extensions for three years. The generator still exists, so
  regeneration is _possible_, but nobody is doing it.
- **No registry safety metadata survives**: `externsync`, `successcodes`/`errorcodes`, `optional`,
  `len` are all discarded — the type system knows parameter types and nothing else.
- **`__gshared` global function pointers**: the default loading tier is thread-unsafe mutable
  global state, and device-level reloading silently breaks other devices.
- **No `@safe`/DIP1000 integration**: raw pointers everywhere; unusable from `@safe` code without
  caller-written `@trusted` shims.
- **Weakly-typed flags and untyped `pNext`**: `VkAccessFlags`/`VkImageUsageFlags`/… are mutually
  assignable `uint` aliases; structure chains are `const(void)*` with no compile-time checking.
- **32-bit handle degradation** to `ulong` aliases (plus the `VK_NULL_ND_HANDLE` wart).
- **No sync, lifetime, or error model whatsoever** — by design, but it means the validation layers
  are the only net.

## Key design decisions and trade-offs

| Decision                                                                  | Rationale                                                                                        | Trade-off                                                                                               |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| Reuse Khronos `reg.py`/`generator.py` instead of a custom `vk.xml` parser | Tracks registry-format evolution for free; correct extension/feature dependency resolution       | Generation requires a `Vulkan-Docs`/`Vulkan-Headers` checkout; templates see only what `reg.py` exposes |
| Runtime `dlopen` + three-tier loading (no link-time `libvulkan`)          | Apps run where no Vulkan driver exists (graceful fallback); device tables skip dispatch overhead | Loading ritual is user-visible; global tier is `__gshared` and thread/multi-device-unsafe               |
| Module-level `__gshared` function pointers as the default tier            | C-like call syntax (`vkCreateBuffer(…)`) with no context object                                  | Mutable global state; second `loadDeviceLevelFunctions(VkDevice)` call corrupts the first device        |
| `DispatchDevice` struct as the multi-device path                          | Per-device pointer table; convenience calls auto-supply device/allocator                         | `vk` prefix must be dropped (pointers can't overload functions); stateful `commandBuffer` member        |
| Default field initializers for `sType`                                    | Correct-by-construction structure tagging at zero runtime cost                                   | None measurable — pure win, uniquely cheap in D                                                         |
| Platform/beta extensions as user-instantiated mixin templates             | Core stays dependency-free; user picks the Xlib/XCB/Wayland binding                              | Boilerplate module per platform; collision escape hatches (`…Ext` names) needed                         |
| Faithful C surface — no RAII, no sync model, no error wrapper             | Zero overhead, zero semantic drift from the spec                                                 | All Vulkan hazards intact; validation layers are the only safety net                                    |
| SemVer build metadata encodes the Vulkan-Docs tag                         | Exact provenance of every release                                                                | dub treats `+v1.3.247`→`+v1.3.248` as equal precedence; pinning needs exact versions                    |

---

## Sources

- [ParticlePeter/ErupteD — repository][repo] · [README][readme]
- [`erupted` on code.dlang.org (2.1.98+v1.3.248, April 20, 2023)][dub]
- [`source/erupted/types.d` — handles, `sType` defaults, flags aliases][types]
- [`source/erupted/functions.d` — `PFN_` aliases, `__gshared` pointers, loaders][functions]
- [`source/erupted/dispatch_device.d` — `DispatchDevice`][dispatch]
- [ParticlePeter/V-Erupt — `erupt_dlang.py` generator][verupt] · [the script][gen]
- [ColonelThirtyTwo/dvulkan — archived predecessor][dvulkan] · [`d-vulkan` on dub][dvulkan-dub]
- [`bindbc-vulkan` on dub (0.0.1, July 31, 2025)][bindbc] · [BindBC organisation][bindbc-repo]
- [Inochi2D/nuvk — `@nogc` Vulkan 1.3 loader + utilities][nuvk] · [`nuvk` on dub][nuvk-dub]
- [`derelict-vulkan` on dub][derelict] · [`vulkanish` on dub][vulkanish]
- [Intel — API without Secrets: Introduction to Vulkan][intel]
- [Vulkan registry `vk.xml`][vkxml] · [Vulkan spec — externally synchronized parameters][externsync]
- [Sparkles ImportC guideline][importc-guide] · [Expected error-handling idiom][expected-idiom]
- Related: [Ash (Rust)][ash] · [vulkanalia (Rust)][vulkanalia] · [vulkan-zig (Zig)][vulkan-zig] · [vulkan-hpp (C++)][vulkan-hpp] · [Vulkano (Rust)][vulkano] · [vuk (C++)][vuk] · [Daxa (C++)][daxa] · [Sync validation][sync-validation] · [Comparison][comparison] · [Index][index]

<!-- References -->

[repo]: https://github.com/ParticlePeter/ErupteD
[readme]: https://github.com/ParticlePeter/ErupteD/blob/1b3c80c49ebbeafc48252b61652644ff0c6dab91/README.md
[dub]: https://code.dlang.org/packages/erupted
[types]: https://github.com/ParticlePeter/ErupteD/blob/1b3c80c49ebbeafc48252b61652644ff0c6dab91/source/erupted/types.d
[functions]: https://github.com/ParticlePeter/ErupteD/blob/1b3c80c49ebbeafc48252b61652644ff0c6dab91/source/erupted/functions.d
[dispatch]: https://github.com/ParticlePeter/ErupteD/blob/1b3c80c49ebbeafc48252b61652644ff0c6dab91/source/erupted/dispatch_device.d
[verupt]: https://github.com/ParticlePeter/V-Erupt
[gen]: https://github.com/ParticlePeter/V-Erupt/blob/ba03fbea909746d00555d6286689eebfebbb6ed4/erupt_dlang.py
[dvulkan]: https://github.com/ColonelThirtyTwo/dvulkan
[dvulkan-dub]: https://code.dlang.org/packages/d-vulkan
[bindbc]: https://code.dlang.org/packages/bindbc-vulkan
[bindbc-repo]: https://github.com/BindBC
[nuvk]: https://github.com/Inochi2D/nuvk
[nuvk-dub]: https://code.dlang.org/packages/nuvk
[derelict]: https://code.dlang.org/packages/derelict-vulkan
[vulkanish]: https://code.dlang.org/packages/vulkanish
[intel]: https://www.intel.com/content/www/us/en/developer/articles/training/api-without-secrets-introduction-to-vulkan-part-1.html
[vkxml]: https://github.com/KhronosGroup/Vulkan-Headers/blob/8d6039a455a7ecc7d2a592ff97f62db4e59b70bf/registry/vk.xml
[externsync]: https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html#fundamentals-threadingbehavior
[dip1000]: https://dlang.org/spec/memory-safe-d.html
[importc-guide]: ../../guidelines/importc-c-libraries.md
[expected-idiom]: ../../guidelines/idioms/expected/index.md
[ash]: ./rust-ash.md
[vulkanalia]: ./rust-vulkanalia.md
[vulkan-zig]: ./zig-vulkan-zig.md
[vulkan-hpp]: ./cpp-vulkan-hpp.md
[vulkano]: ./rust-vulkano.md
[vuk]: ./cpp-vuk.md
[daxa]: ./cpp-daxa.md
[sync-validation]: ./sync-validation.md
[comparison]: ./comparison.md
[index]: ./index.md
