# vulkan (Haskell)

The "slightly high level" Haskell bindings to Vulkan by Ellie Hermaszewska — a fully generated, marshalled API whose signature feature is encoding the `pNext` structure chain as a **type-level list**, so extension structs are composed and returned with compile-time checking and full type inference.

| Field            | Value                                                                                                  |
| ---------------- | ------------------------------------------------------------------------------------------------------ |
| Language         | Haskell (GHC ≥ 8.6 — needs `QuantifiedConstraints`; 64-bit only)                                       |
| License          | BSD-3-Clause                                                                                           |
| Repository       | [expipiplus1/vulkan][repo]                                                                             |
| Documentation    | [Hackage: vulkan][hackage] · [Haddock mirror][gh-pages]                                                |
| Category         | Safety-first wrapper                                                                                   |
| First release    | `0.1.0.0` on Hackage (2016)                                                                            |
| Latest release   | `v3.26.6`, March 7, 2026 (80 releases, ~2,000 commits)                                                 |
| Sibling packages | [`VulkanMemoryAllocator`][vma-pkg] (generated VMA bindings) · [`vulkan-utils`][utils] · `openxr` (WIP) |

> [!NOTE]
> This deep-dive is part of the [Vulkan bindings survey][index]; shared vocabulary
> (structure chains, `externsync`, dispatchable vs non-dispatchable handles) is defined
> in [Concepts][concepts], and the cross-language synthesis lives in
> [Comparison][comparison].

---

## Overview

### What it solves

Raw Vulkan in Haskell via plain FFI means hand-managing `Storable` instances for
hundreds of structs, setting every `sType`, threading pointer-and-length pairs, checking
every `VkResult`, and loading function pointers per instance/device. The `vulkan`
package generates all of that away. From the [Hackage description][hackage]:

> _"Slightly high level Haskell bindings to the Vulkan graphics API. These bindings
> present an interface to Vulkan which looks like more idiomatic Haskell and which is
> much less verbose than the C API. Nevertheless, it retains access to all the
> functionality."_

Concretely, per the [`readme.md`][readme]: commands are linked dynamically (only
`vkGetInstanceProcAddr` is resolved statically); there is _"no setting the `sType`
member, this is done automatically"_; _"no checking `VkResult` return values for
failure, a `VulkanException` will be thrown if a Vulkan command returns an error"_; and
_"no manual memory management for command parameters or Vulkan structs"_ — `Vector`
replaces pointer+count pairs, `Maybe` replaces optional pointers, `VkBool32` becomes
`Bool`, C strings become `ByteString`. Coverage is complete: all of Vulkan 1.0–1.3 plus
extensions (a few video extensions excepted), and the same generator produces
[`VulkanMemoryAllocator`][vma-pkg] bindings in the same style.

### Design philosophy

Maximize what Haskell's type system can check **at the API-shape level** — chains,
optionality, array lengths, success-code presence — while staying a 1:1 mapping of the
C API rather than a framework. The struct-chain section of the [`readme.md`][readme]
states the core idea:

> _"Most structures in Vulkan have a member called `pNext` which can be a pointer to
> another Vulkan structure containing additional information. In these high level
> bindings the head of any struct chain is parameterized over the rest of the items in
> the chain. This allows for using type inference for getting struct chain return
> values out of Vulkan."_

There is **no attempt to automate synchronization or resource lifetimes** beyond
bracket pairing — the library is deliberately a faithful, typed mirror of Vulkan, with
ergonomics layered on top by [`vulkan-utils`][utils] and user code. In this survey it is
the maximal data point for "how much of `vk.xml`'s _structural_ metadata can a rich
type system absorb", sitting between the thin typed mirrors ([ash][rust-ash],
[erupted][d-erupted]) and the runtime-checked safety layer of [vulkano][rust-vulkano].

---

## How it works

### Binding generation & API coverage

Everything under `src/` is emitted by the `generate-new` generator
([`generate-new/readme.md`][gen-readme]) — a Haskell program (`generate-new/vk/Main.hs`)
run over the Khronos [`Vulkan-Docs`][vulkan-docs] submodule. It consumes the registry
(`vk.xml`, parsed by the `khronos-spec` sub-library) **and the built asciidoc
reference pages**: the readme requires _"documentation having been built in
`Vulkan-Docs`"_ via `./makeAllExts refpages generated`, because the generator inlines
each command's and struct's spec prose — valid-usage tables, "Host Synchronization"
sections and all — into the Haddock docs. The generator _"outputs the `vulkan` source
to a directory called `out`"_, which is committed; downstream users never run it.
Sibling generators `vma` (VulkanMemoryAllocator) and `xr` (OpenXR, work in progress)
share the infrastructure, and a `patches/` directory carries hand-fixes on top of
generated output.

What the generator derives from registry metadata, per the marshalling rules in the
[`readme.md`][readme]:

| `vk.xml` metadata             | Surfaces as                                                                        |
| ----------------------------- | ---------------------------------------------------------------------------------- |
| `len=` attributes             | `Vector a` parameters/members (length passed implicitly)                           |
| `optional="true"` pointers    | `Maybe a`                                                                          |
| `structextends=`              | the `Extends` type family (see [Type-system techniques](#type-system-techniques))  |
| `sType` values                | elided; poked automatically                                                        |
| success/error codes           | error codes → `VulkanException`; non-`SUCCESS` success codes returned in tuples    |
| create/destroy command pairs  | generated `with*` bracket functions                                                |
| spec prose incl. `externsync` | Haddock documentation only (see [Synchronization safety](#synchronization-safety)) |

Modules mirror the registry's `features`/`extensions` partition — `Vulkan.Core10`,
`Vulkan.Core11`, …, `Vulkan.Extensions.VK_KHR_swapchain` — and the readme advises
importing _"`Vulkan.CoreXX` along with `Vulkan.Extensions.{whatever extensions you
want}`"_, qualified, with the `vk`/`Vk`/`VK_` prefixes stripped.

### Handle lifetime & ownership model

Handles are plain values; there is no linear/affine ownership and no ref-counting.
Dispatchable handles bundle their loaded function-pointer table; non-dispatchable
handles are bare `newtype`s ([`Vulkan.Core10.Handles`][handles]):

```haskell
-- Vulkan.Core10.Handles (generated)
data Instance = Instance
  { instanceHandle :: Ptr Instance_T
  , instanceCmds   :: InstanceCmds }

data Queue = Queue
  { queueHandle :: Ptr Queue_T
  , deviceCmds  :: DeviceCmds }

newtype Buffer = Buffer Word64
newtype Fence  = Fence  Word64
```

Per the readme, _"the function pointers are attached to any dispatchable handle to save
you the trouble of passing them around"_ — dispatch is one record-field read plus an
indirect call, with no global mutable loader state.

Lifetime management is **bracket-style, not GC-tied**: every create/destroy pair gets a
generated `with*` higher-order function which _"takes as its last argument a consumer
for a pair of `create` and `destroy` commands"_. The generated definition is trivially
thin ([`Vulkan.Core10.DeviceInitialization` source][di-src]):

```haskell
-- "A convenience wrapper to make a compatible pair of calls to
-- createInstance and destroyInstance"
withInstance pCreateInfo pAllocator b =
  b (createInstance pCreateInfo pAllocator)
    (\(Instance o0) -> destroyInstance o0 pAllocator)
```

Passing `Control.Exception.bracket` as `b` gives exception-safe scoped cleanup; passing
a `ContT`/`managed`-style allocator gives composable "register a destructor" semantics
(the pattern all the official examples use). Nothing stops use-after-destroy — a
`Buffer` is just a `Word64`, freely copyable after `destroyBuffer` — so correctness of
_ordering_ (destroy child before parent, don't destroy while in use) remains the
caller's job, exactly as in C. There are no finalizers and no destruction on GC.

### Synchronization safety

**Not modeled — and that absence is deliberate.** Fences, semaphores, timeline
semaphores, events, pipeline barriers and queue-family ownership transfers are exposed
1:1 as data (`SubmitInfo`, `MemoryBarrier`, `cmdPipelineBarrier`, `waitForFences`, …)
with no render graph, no automatic barrier insertion, no typestate over image layouts,
and no type-level distinction between externally-synchronized and thread-safe
parameters. The library's position is to mirror the spec; the spec's synchronization
rules survive **as generated documentation**: every command's Haddock embeds the
reference page's "Host Synchronization" section, e.g. for [`queueSubmit`][queue]:

> _"Host access to `queue` must be externally synchronized"_ ·
> _"Host access to `fence` must be externally synchronized"_

So `vk.xml`'s `externsync` attribute survives into docs, not into types — a `Queue`
record can be submitted to from two Haskell threads and neither the type checker nor
the library will object (only the validation layers will). The one genuinely
sync-relevant _typed_ affordance is the FFI annotation: blocking commands such as
`waitForFences`, `queueWaitIdle` and `deviceWaitIdle` get generated `*Safe` variants
(`waitForFencesSafe`) that use `safe` foreign calls so the GC and other Haskell threads
can run while the host blocks — see [Overhead & escape hatches](#overhead--escape-hatches).
Compare the automated end of the spectrum in [daxa][cpp-daxa], [vuk][cpp-vuk] and
[wgpu][rust-wgpu], and the tooling baseline in [sync-validation][sync-validation].

### Type-system techniques

This is the package's research payload — the most aggressive type-level encoding of
the `pNext` chain in any surveyed binding (its only close peer is `vulkan-hpp`'s
`StructureChain`, see [cpp-vulkan-hpp][cpp-vulkan-hpp]):

- **Chain-indexed structs.** Every extensible struct is parameterized by the type-level
  list of structs chained behind it: `InstanceCreateInfo '[]` has an empty chain;
  `PhysicalDeviceFeatures2 '[PhysicalDeviceVulkan12Features]` carries one extension.
  Chains in records are nested tuples — `next :: (Something, (SomethingElse, ()))` —
  built and matched with two pattern synonyms from
  [`Vulkan.CStruct.Extends`][extends-mod]: `h ::& t` attaches a chain to a head struct,
  `e :& es` conses chain elements, `()` terminates.

  ```haskell
  -- Vulkan.CStruct.Extends (vulkan-3.26.6)
  pattern (::&) :: Extensible a => a es' -> Chain es -> a es
  pattern (:&)  :: e -> Chain es -> Chain (e : es)
  ```

- **Legality via closed type families.** Which struct may extend which is the registry's
  `structextends` attribute compiled into a closed constraint family — an illegal chain
  is a type error, not a validation-layer message at runtime:

  ```haskell
  type family Extends  (a :: [Type] -> Type) (b :: Type) :: Constraint where ...
  type family Extendss (p :: [Type] -> Type) (xs :: [Type]) :: Constraint where ...
  ```

- **Bidirectional inference for output chains.** `Chain` is an _injective_ type family
  (`= r | r -> xs`), so the chain type can be inferred from a pattern match: bind the
  result of `getPhysicalDeviceFeatures2` as `_ ::& vk12 :& ()` with
  `vk12 :: PhysicalDeviceVulkan12Features` and GHC infers — and marshals — exactly that
  query chain. This is the "type inference for getting struct chain return values out
  of Vulkan" the readme advertises.

- **Existential erasure where the spec is heterogeneous.** Parameters like
  `queueSubmit`'s submit array take differently-chained structs in one `Vector`, so the
  generator wraps them in `SomeStruct`:

  ```haskell
  data SomeStruct (a :: [Type] -> Type) where
    SomeStruct :: forall a es . (Extendss a es, PokeChain es, Show (Chain es))
               => a es -> SomeStruct a

  queueSubmit :: forall io . MonadIO io
              => Queue -> ("submits" ::: Vector (SomeStruct SubmitInfo))
              -> Fence -> io ()
  ```

- **Marshalling classes** `PokeChain`/`PeekChain` recurse over the list to poke/peek the
  linked C chain; `Extensible` allows runtime chain inspection (`extends` checks a
  `Typeable` extension and produces evidence).
- **Type-level parameter names.** The `("submits" ::: Vector …)` syntax is a
  documentation-only type synonym (`:::`) attaching the spec's parameter name to the
  type — phantom labelling with zero semantic content.
- **`Zero` class** — every struct has a canonical all-zero value, mirroring C's
  `= {0}` idiom, so partially-specified create-infos are written as record updates of
  `zero`.

Not used: no phantom branding of handles to their parent device, no linear types
(GHC's `LinearTypes` postdates the design), no typestate on command buffers or image
layouts, no capability typing of enabled extensions — calling an extension command the
device was not created with fails at runtime, not compile time.

### Overhead & escape hatches

The chain machinery is **compile-time-only** — `Extends`/`Extendss` are constraints
GHC discharges and erases, and chain types are monomorphized away. The runtime costs
are in marshalling and are real but bounded:

- **Per-call marshalling allocation.** Every command body runs in `evalContT`,
  `withCStruct`-ing each argument into temporarily allocated C memory and peeking
  results back ([`createInstance` source][di-src]):

  ```haskell
  createInstance createInfo allocator = liftIO . evalContT $ do
    ...
    pCreateInfo <- ContT $ withCStruct createInfo
    pPInstance  <- ContT $ bracket (callocBytes @(Ptr Instance_T) 8) free
    r <- lift $ traceAroundEvent "vkCreateInstance"
           (vkCreateInstance' (forgetExtensions pCreateInfo) pAllocator pPInstance)
    lift $ when (r < SUCCESS) (throwIO (VulkanException r))
    ...
  ```

  The generator optimizes layout — _"non-optional arrays/structs can be allocated at
  the same time as their parent struct, no need for two allocations"_
  ([`generate-new/readme.md`][gen-readme]) — but a hot-loop `cmdDraw` still pays a
  Haskell→C call through a record-fetched function pointer, and struct-taking commands
  pay poke traffic per call. This is "low-overhead", not zero-overhead.

- **`unsafe` FFI by default.** _"Calls to Vulkan are marked as `unsafe` by default to
  reduce FFI overhead"_ ([readme][readme]) — an `unsafe` call is a few ns vs ~100 ns
  for `safe`. The flip side, stated in the same section: Vulkan then _"is unable to
  safely call Haskell code"_ (debug/allocation callbacks must be C functions) and _"the
  garbage collector will not run while these calls are in progress"_. The
  `safe-foreign-calls` Cabal flag flips everything to `safe`; blocking calls get
  generated `*Safe` twins regardless.
- **Strictness.** _"The library is compiled with `-XStrict` so expect all record
  members to be strict (and unboxed when they're small)."_
- **Escape hatches.** `instanceHandle`/`deviceHandle` expose the raw pointers and every
  non-dispatchable handle unwraps to its `Word64`, for interop with C libraries (this
  is exactly how the `VulkanMemoryAllocator` package and windowing FFI plug in);
  `InstanceCmds`/`DeviceCmds` expose the raw loaded function pointers;
  `forgetExtensions` erases a chain type; and every struct's `ToCStruct`/`FromCStruct`
  instances allow manual pointer-level work without leaving the package's types.

### Error handling & validation integration

Generated commands check the returned `Result` and `throwIO (VulkanException r)`
whenever `r < SUCCESS` (visible in the [`createInstance` body][di-src]); non-error
success codes such as `TIMEOUT`/`INCOMPLETE` are returned as part of the result tuple
rather than swallowed, and the enumerate-style two-call dance (query count, then fill)
is performed internally so users receive a sized `Vector` directly. There is no
`Either`-based variant — exceptions are the only generated error channel.

Validation-layer integration is delegated to [`vulkan-utils`][utils]:
`Vulkan.Utils.Debug` wires `VK_EXT_debug_utils` messengers (with a C-side callback,
since `unsafe` FFI forbids Haskell callbacks), `Vulkan.Utils.Initialization` creates
instances/devices with layers enabled, `Vulkan.Utils.Requirements(.TH)` checks
device/feature/extension requirements (with Template Haskell for compile-time
requirement lists), `Vulkan.Utils.QueueAssignment` solves queue-family selection, and
the `ShaderQQ` quasiquoters compile GLSL/HLSL to SPIR-V **at Haskell compile time** via
`glslang`/`shaderc` — shader syntax errors become build errors.

---

## Strengths

- **The most complete typed `pNext` encoding surveyed**: illegal extension chains are
  compile errors, and injectivity gives full inference for _output_ chains — a
  capability even `vulkan-hpp`'s `StructureChain` lacks ([comparison][comparison]).
- **Registry-faithful and complete**: Vulkan 1.0–1.3 + extensions + VMA + (WIP) OpenXR
  from one generator; spec prose, including synchronization requirements, embedded in
  the Haddocks at the exact call site.
- **Boilerplate elimination without semantic invention**: `sType`, lengths, two-call
  enumeration, function-pointer loading, result checking all generated; the API still
  maps 1:1 onto the C spec, so C-oriented Vulkan literature transfers directly.
- **Disciplined overhead**: `unsafe` calls, `-XStrict`, fused parent/child struct
  allocation, per-handle dispatch tables; type-level machinery fully erased.
- **Actively maintained for a decade** (2016 → v3.26.6 in March 2026, 80 releases)
  with a Matrix community (`#haskell-vulkan:matrix.org`).

## Weaknesses

- **No synchronization or lifetime safety**: `externsync`, image layouts, barrier
  correctness and destruction ordering are documentation-only; the type system that
  polices struct chains polices none of the things that actually crash GPUs (contrast
  [vulkano][rust-vulkano], [daxa][cpp-daxa]).
- **Marshalling cost on hot paths**: per-call `ContT` allocation and poke/peek traffic
  makes ten-thousand-draw-call loops measurably more expensive than the raw C API;
  there is no generated "pre-marshalled struct" caching mode.
- **`unsafe`-FFI trade-off is a footgun**: Haskell debug/allocator callbacks are
  silently unsupported by default, and a long `unsafe` call stalls the GC for every
  Haskell thread.
- **Type-level chains have a GHC-skill price**: errors mention `Extendss`, injective
  type families and existentials; `SomeStruct` erasure reintroduces runtime shape where
  the spec demands heterogeneity.
- **No typed capability tracking**: nothing ties an extension command or struct to
  having enabled that extension/feature at device creation.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                        | Trade-off                                                                                 |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Chain-indexed structs (type-level list + `Extends` families)  | Illegal `pNext` chains rejected at compile time; inference drives output queries | Heavyweight type errors; needs `SomeStruct` erasure for heterogeneous arrays              |
| Generate from `Vulkan-Docs` (registry **and** built refpages) | Haddocks carry the spec's valid-usage and Host Synchronization prose verbatim    | Heavy generator toolchain (asciidoctor et al.); sync rules stay prose, never become types |
| Bracket pairs (`withInstance`) instead of GC finalizers       | Deterministic destruction order, composable with `bracket`/`ContT`/`managed`     | No protection against use-after-destroy or wrong destruction order                        |
| Handles as plain values; dispatch table inside the handle     | Zero global state; correct per-device function pointers for free                 | Handles freely aliasable/copyable; `externsync` unenforced                                |
| `unsafe` FFI by default, `*Safe` variants + flag              | Cuts per-call FFI overhead by an order of magnitude                              | No Haskell callbacks; GC paused during calls; users must know to pick `waitForFencesSafe` |
| Exceptions (`VulkanException`) as the sole error channel      | Removes universal `VkResult` checking boilerplate                                | No typed/`Either` recovery path; success-code tuples are easy to ignore                   |
| Marshalled value types (`Vector`, `Maybe`, `ByteString`)      | Idiomatic Haskell; impossible to mismatch pointer and length                     | Per-call marshalling allocation/copies on hot paths                                       |
| Safety extras live in `vulkan-utils`, not the core            | Core stays a faithful generated mirror; utilities can be opinionated             | Out-of-the-box experience is raw; every app re-assembles its own safety layer             |

---

## Sources

- [expipiplus1/vulkan — GitHub repository][repo]
- [`readme.md` — design statements (marshalling, chains, brackets, FFI)][readme]
- [`generate-new/readme.md` — generator pipeline and notes][gen-readme]
- [vulkan on Hackage (3.26.6)][hackage] · [Haddock mirror][gh-pages]
- [`Vulkan.CStruct.Extends` — `SomeStruct`, `Extends`/`Extendss`, `(:&)`/`(::&)`, `PeekChain`/`PokeChain`][extends-mod]
- [`Vulkan.Core10.Handles` — dispatchable vs non-dispatchable handle definitions][handles]
- [`Vulkan.Core10.Queue` — `queueSubmit`, Host Synchronization docs, `*Safe` variants][queue]
- [`Vulkan.Core10.DeviceInitialization` source — `createInstance`/`withInstance` bodies][di-src]
- [VulkanMemoryAllocator on Hackage][vma-pkg] · [vulkan-utils on Hackage][utils]
- [Khronos Vulkan-Docs (registry + refpages consumed by the generator)][vulkan-docs]
- Related: [Comparison][comparison] · [Concepts][concepts] · [vulkan-hpp (C++)][cpp-vulkan-hpp] · [ash (Rust)][rust-ash] · [vulkano (Rust)][rust-vulkano] · [erupted (D)][d-erupted] · [daxa (C++)][cpp-daxa] · [vuk (C++)][cpp-vuk] · [wgpu (Rust)][rust-wgpu] · [Synchronization validation][sync-validation]

<!-- References -->

[repo]: https://github.com/expipiplus1/vulkan
[readme]: https://github.com/expipiplus1/vulkan/blob/577b4b1c2edca0613ede04fa3917225435fadd35/readme.md
[gen-readme]: https://github.com/expipiplus1/vulkan/blob/577b4b1c2edca0613ede04fa3917225435fadd35/generate-new/readme.md
[hackage]: https://hackage.haskell.org/package/vulkan
[gh-pages]: https://expipiplus1.github.io/vulkan/
[vma-pkg]: https://hackage.haskell.org/package/VulkanMemoryAllocator
[utils]: https://hackage.haskell.org/package/vulkan-utils
[extends-mod]: https://hackage.haskell.org/package/vulkan-3.26.6/docs/Vulkan-CStruct-Extends.html
[handles]: https://hackage.haskell.org/package/vulkan-3.26.6/docs/Vulkan-Core10-Handles.html
[queue]: https://hackage.haskell.org/package/vulkan-3.26.6/docs/Vulkan-Core10-Queue.html
[di-src]: https://hackage.haskell.org/package/vulkan-3.26.6/docs/src/Vulkan.Core10.DeviceInitialization.html
[vulkan-docs]: https://github.com/KhronosGroup/Vulkan-Docs
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[cpp-vulkan-hpp]: ./cpp-vulkan-hpp.md
[rust-ash]: ./rust-ash.md
[rust-vulkano]: ./rust-vulkano.md
[d-erupted]: ./d-erupted.md
[cpp-daxa]: ./cpp-daxa.md
[cpp-vuk]: ./cpp-vuk.md
[rust-wgpu]: ./rust-wgpu.md
[sync-validation]: ./sync-validation.md
