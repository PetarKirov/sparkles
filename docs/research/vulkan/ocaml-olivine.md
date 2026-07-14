# Olivine (OCaml)

A generator-driven OCaml Vulkan binding experiment by Florian Angeletti (`Octachron`, of the OCaml core team) that compiles `vk.xml` into a typed module hierarchy over [ctypes], using generative functors for handle branding, phantom types for bitsets, polymorphic-variant narrowing of `VkResult`, and ML functors to model extension dependencies — a showcase of how far the OCaml _module system_ (rather than codegen volume) can carry Vulkan safety.

| Field           | Value                                                                                                |
| --------------- | ---------------------------------------------------------------------------------------------------- |
| Language        | OCaml (98.7% of the tree)                                                                            |
| License         | Apache-2.0                                                                                           |
| Repository      | [Octachron/olivine][repo]                                                                            |
| Documentation   | [`README.md`][readme] (the only documentation)                                                       |
| Category        | Safety-first wrapper (generator + typed runtime)                                                     |
| First release   | **Never released** — no opam package; install is `opam pin add olivine <git url>` ([README][readme]) |
| Latest activity | August 12, 2025 (PR merge); vendored spec at Vulkan **1.2.162** since July 23, 2025                  |
| Spec input      | Vendored [`spec/vk.xml`][spec-dir], parsed by an in-tree XML/C/latex parser stack (`info/`)          |
| FFI substrate   | [ctypes] + `Foreign` (libffi dynamic calls), no C stub generation                                    |

> [!IMPORTANT]
> Olivine is honestly assessed here as a **research artifact, not a maintained library**: 279 commits total, ~85% of them from April–December 2017, single-digit commits per year 2018–2023, then complete dormancy until Thomas Leonard (`talex5`) revived it in July–August 2025 (spec bump to 1.2.162, README rewrite, option-type hardening). Leonard's September 2025 write-up calls the bindings _"unfinished"_ and _"unreleased"_ and notes he ships _"a patched copy in my repository"_ while _"slowly upstreaming my changes to Olivine"_ ([roscidus.com][blog]). It has 48 GitHub stars. Its value to a future `sparkles:vulkan` is as a **design catalog**, not as prior art to depend on.

---

## Overview

### What it solves

Raw Vulkan in OCaml via [ctypes] alone would be as stringly- and intly-typed as C: every handle a `nativeint`, every enum an `int`, every flags field an `int`, every `pNext` a `void*`. Olivine's bet is that a **generator with "a modest amount of a priori knowledge"** can recover almost all of the lost structure from the registry itself: `len` attributes become real arrays and strings, `optional` attributes become OCaml optional labelled arguments, `successcodes`/`errorcodes` become per-function polymorphic-variant `result` types, and the `sType`/`pNext` idiom becomes an open extensible sum type. The target audience is OCaml programmers who want Vulkan with ML-grade types but without a hand-maintained wrapper layer.

Coverage is deliberately scoped: _"the generated bindings covers all Vulkan APIs except for the WSL extensions (i.e. the interface with the various windows systems) due to a lack of OCaml libraries covering the corresponding window systems"_ ([README][readme]) — surface creation is delegated to SDL ≥ 2.0.6 via `tsdl` ≥ 0.9.6. (A `wsl/` directory with `wayland.ml`/`xcb.ml`/`xlib.ml` stubs exists but is not wired into the generated library.)

### Design philosophy

From the first lines of the [README][readme]:

> _"Olivine is a binding generator for Vulkan and OCaml. It generates OCaml code from the xml specification of the Vulkan API and a modest amount of a priori knowledge. The bindings themselves use the OCaml Ctype library. **Olivine aims to generate thin but well-typed bindings.**"_

"Thin but well-typed" is the whole thesis. There is no attempt at the [vulkano][rust-vulkano]-style runtime-safety layer or a render graph; the abstraction budget is spent entirely on making the _existing_ C API surface honest in OCaml's type system, and the heavy lifting is done by language features other ecosystems lack or underuse: **generative functors** mint fresh abstract types per handle, **phantom type parameters** distinguish bitset singletons from unions, **polymorphic variants** give structural, per-function error types without declaring N nominal enums, and plain **functors** encode "this extension needs a `VkInstance`/`VkDevice`" as a module-level dependency. Within this survey it is the closest cousin to [vulkan (Haskell)][haskell-vulkan] (typed FP binding generated from the registry) and the antipode of [ash][rust-ash] (untyped-by-choice thinness); like [erupted (D)][d-erupted] it is a one-person generator project, but with far more type-level ambition and far less maintenance.

---

## How it works

The generated library is a nested module tree rooted at `Vk` ([README][readme]):

```text
Vk
├── Const                 constants
├── Types                 one module per type definition (each with a main type t,
│                         a pretty-printer, and helper functions)
├── Core                  core commands
└── $Extension_name       one module per extension — a functor over an
                          Instance or Device module, per the extension's scope
```

All names are converted to snake_case and the `vk`/`Vk` prefixes (and redundant per-enum prefixes) are stripped by a dedicated naming engine (`info/linguistic.ml`), so `VkInstanceCreateInfo` becomes `Vk.Types.Instance_create_info.t`.

### Binding generation & API coverage

The generator executable is [`generator/libgen.ml`][libgen]; the README documents its five-stage pipeline verbatim:

1. _"The Vulkan XML specification is loaded as an `Info.Xml.xml` tree."_ The parser stack is entirely in-tree (`info/cxml_lexer.mll`, `info/cxml_parser.mly`) and even includes a **latex lexer/parser pair** (`info/latex_lexer.mll`, `info/latex_parser.mly`) to evaluate the latex math embedded in registry `len` attributes (e.g. `latexmath:[\lceil...\rceil]`).
2. _"`Info.Structured_spec.typecheck` converts this to an `Info.Structured_spec.spec`"_ — i.e. the registry is **typechecked** into a richer IR, merging _"entities from all enabled extensions into the main registry"_.
3. `Aster.Lib.generate` (the `aster/` directory: `enum.ml`, `bitset.ml`, `handle.ml`, `record_extension.ml`, `fn.ml`, `funptr.ml`, …) builds the module tree as OCaml `Parsetree` fragments via `ppxlib`-style `Ast_helper` quotations.
4. Called without an output directory, `libgen` just lists the modules to be generated — this drives the dune build rules.
5. `Printer.lib` writes each module out by converting items to AST.

Registry metadata that **survives** into the type system: `optional` (→ labelled optional arguments), `len` (→ reconstructed array/string types and the `void f(size_t* n, ty array[])` enumerate-twice idiom mapped to a single array-returning call), `successcodes`/`errorcodes` (→ [narrowed result variants](#error-handling--validation-integration)), `sType`/`structextends` (→ the open extensible sum for `pNext`), and dispatchable-vs-non-dispatchable handle kind (→ two functor flavours). Registry metadata that does **not** survive: `externsync` (see [Synchronization safety](#synchronization-safety)), queue-family/command-buffer-level capability attributes, and all valid-usage prose.

The spec is vendored ([`spec/vk.xml`][spec-dir]) rather than fetched, so API coverage is frozen at the vendored version — Vulkan **1.2.162** since Leonard's July 2025 update ([commit `d7e705c5`][spec-bump]), which means Vulkan 1.3/1.4 and post-2020 extensions are absent.

### Handle lifetime & ownership model

Handles are abstract types minted by **generative functors** — the ML equivalent of branded/phantom handle types. The runtime support module [`lib/vk__builtin__handle.ml`][handle-builtin] defines two flavours, and the generator ([`aster/handle.ml`][handle-gen]) instantiates one per handle type depending on the registry's dispatchable/non-dispatchable classification:

```ocaml
(* lib/vk__builtin__handle.ml *)
module Make(): S =
struct
  type self
  type t = self Ctypes.structure Ctypes.ptr
  let t: t Ctypes.typ = Ctypes.ptr (Ctypes.structure "")
  let null = Ctypes.(coerce @@ ptr void) t Ctypes.null
  ...
  let to_ptr x = Ctypes.raw_address_of_ptr @@ Ctypes.coerce t Ctypes.(ptr void) x
  let unsafe_from_ptr x =
    Ctypes.coerce Ctypes.(ptr void) t @@ Ctypes.ptr_of_raw_address x
end

module Make_non_dispatchable(): S_non_dispatchable =
struct
  type self
  type t = int64
  ...
end
```

Because `Make` takes `()` — it is _generative_ — every application produces a **fresh, incompatible** `self`, so `Vk.Types.Device.t` and `Vk.Types.Instance.t` are distinct abstract types even though both are pointers underneath (and non-dispatchable handles are distinct types over the same `int64`). Mixing handles is a compile error; this is exactly the guarantee `VK_DEFINE_HANDLE` gives C via dummy structs, reproduced without any per-handle generated code.

What olivine does **not** model is lifetime or ownership. There is no RAII, no destroy-on-finalize, no parent–child tracking (destroying a `VkDevice` while its `VkCommandPool` handles are live is undetectable), and no use-after-destroy protection — handles are plain immutable values the GC knows nothing about. The one GC-interaction the library does handle is the inverse hazard, **OCaml collecting memory the C side still reads**: every handle/record module's `array : t list -> t Ctypes.CArray.t` combinator attaches a `Gc.finalise` closure that keeps the source list alive as long as the C array, _"to ensure that the GC does not collect the values living on the C side too soon"_ ([README][readme]). That is a manual, per-call-site discipline, not a tracked ownership model.

### Synchronization safety

**None — and the registry's sync metadata is explicitly dropped.** Olivine's parameter parser in [`info/structured_spec.ml`][structured-spec] skips the registry's external-synchronization nodes with a literal TODO:

```ocaml
(* info/structured_spec.ml — arg parsing *)
let arg l = function
  | Xml.Data s -> type_errorf "expected function arg, got data: %s" s
  | Node {name="implicitexternsyncparams"; _ } ->
    (* TODO *) l
  | Node ({ name = "param"; _ } as n) -> ...
```

So `externsync` / `implicitexternsyncparams` — the registry's machine-readable statement of which handles a command mutates under the caller's exclusive lock — never reaches stage 2 of the pipeline, let alone the generated types. Nothing distinguishes externally-synchronized parameters from concurrent-safe ones in signatures or docs. (OCaml ≤ 4.x's single-runtime model made this academically moot — only one OCaml thread runs at a time — but multicore OCaml 5 removes that accidental safety net, and olivine predates it.)

Barriers, semaphores, fences, and queue submission are likewise bound one-to-one with no graph, no auto-sync, and no typestate: the in-tree [`examples/triangle.ml`][triangle] hand-rolls the classic acquire/submit/present chain exactly as C would —

```ocaml
(* examples/triangle.ml (abridged) *)
let im_semaphore = create_semaphore ()
let render_semaphore = create_semaphore ()
let wait_sems = Vkt.Semaphore.array [im_semaphore]
let sign_sems = Vkt.Semaphore.array [render_semaphore]

let submit_info _index (* CHECK-ME *) =
  Vkt.Submit_info.array [
    Vkt.Submit_info.make
      ~wait_semaphores: wait_sems
      ~wait_dst_stage_mask: wait_stage
      ~command_buffers: Cmd.cmd_buffers
      ~signal_semaphores: sign_sems ()
  ]
```

— complete with an author's `(* CHECK-ME *)` on the synchronization-relevant code. Timeline semaphores exist in the vendored 1.2.162 registry but get no dedicated support. Leonard's verdict after building a real renderer on it is the right summary: the typed layer catches enum/bitset/result misuse, but _"the OCaml bindings do not fix this, and so care is still needed"_ regarding Vulkan's intrinsic hazards ([roscidus.com][blog]) — for which he leaned on the validation layers ([sync-validation][sync-validation]).

### Type-system techniques

Olivine is the survey's densest catalog of **ML-flavoured** typing tricks; each maps onto a D capability differently than the Rust/C++ entries do.

- **Generative functors as branding** — fresh abstract types per handle and per bitset, as shown [above](#handle-lifetime--ownership-model). (D analogue: a templated struct with a tag parameter, or a string-mixin-generated distinct type per `vk.xml` handle.)
- **Phantom type parameters on bitsets.** [`lib/vk__builtin__bitset.ml`][bitset-builtin] gives every flag type a phantom-indexed `'a set` where `index = singleton set` (one named flag) and `t = plural set` (any union); `mem` demands a singleton on the left, while set operators accept either and always produce `plural`:

  ```ocaml
  (* lib/vk__builtin__bitset.ml *)
  type singleton = private Singleton
  type plural = private Plural

  module type S = sig
    type +'a set
    type index = singleton set
    type t = plural set
    val mem: index -> 'a set -> bool
    val union: 'a set -> 'a set -> t
    val (+): 'a set -> 'a set -> t
    ...
  end
  ```

  Per the [README][readme], bitset types _"distinguish between singleton and non-singleton values through a phantom type parameter"_ — a compile-time distinction the C API (and most bindings, including [vulkan-hpp][cpp-vulkan-hpp]'s `Flags`/`FlagBits` pair, which does the same nominally) encodes at best by convention. Different flag types are separate `Bitset.Make()` instantiations, so cross-flag-type mixing is also a type error.

- **Open extensible sum for `pNext` chains.** [`aster/record_extension.ml`][record-ext] generates, for each extensible struct, an OCaml _open_ variant type (`Ptype_open`) with a `No_extension` constructor plus one constructor per `structextends` candidate; the `make` function pattern-matches the constructor to set both `sType` and the `pNext` pointer coherently, and decoding an unknown `sType` raises `Unknown_record_extension`. The README calls this mapping the `sType`/`pNext` _"idiom … mapped to a proper open sum types"_. This is a **typed pNext chain** (cf. the Haskell binding's type-level lists in [haskell-vulkan][haskell-vulkan]), though only one level deep — it types the immediate extension, not arbitrary chains.

- **Polymorphic-variant narrowing of `VkResult`** — per-function structural error types; detailed under [Error handling](#error-handling--validation-integration).

- **Functors as capability/extension typing.** Each extension module is _"a functor that takes as an argument an instance or device module depending on the scope of the extension"_ ([README][readme], sic). The runtime side ([`lib/vk__extension_sig.ml`][ext-sig]) shows the mechanism — function pointers are loaded through the supplied handle:

  ```ocaml
  (* lib/vk__extension_sig.ml *)
  module type Device = sig val x: Vk__Types__Device.t end
  module type Instance = sig val x: Vk__Types__Instance.t end

  module Foreign_instance(X:Instance): extension = struct
    let foreign name typ =
      let open Ctypes in
      coerce (ptr void) (Foreign.funptr typ) @@
      Vk__Core.get_instance_proc_addr (Some X.x) name
  end
  ```

  You _cannot name_ an extension's functions without first applying its functor to a module wrapping a live `VkInstance`/`VkDevice` — the extension's load-time dependency becomes a static module-system obligation. This is the design's most transferable idea: in D, the analogue is a `Design by Introspection` device wrapper whose extension mixins are instantiated only when the corresponding capability is present. Note the limit, though: the functor proves you _had a device_, not that the device _enabled the extension_ — `vkGetDeviceProcAddr` returning null is still a runtime failure.

- **Labelled + optional arguments** for struct construction (`Vkt.Submit_info.make ~wait_semaphores ... ()`), with registry-`optional` fields becoming `?arg` parameters — the OCaml equivalent of builder typestate, with the compiler checking required fields at the call site. There is no CTFE; all codegen happens offline in `libgen`, unlike [vulkan-zig][zig-vulkan-zig]'s comptime approach.

### Overhead & escape hatches

Olivine's "thin" claim needs qualification: it is thin in _abstraction_, not in _call cost_.

- **libffi-dynamic FFI.** Function bindings are generated as ctypes `foreign "vkXxx" (…typ…)` expressions ([`aster/fn.ml`][fn-gen]) and extension functions go through `Foreign.funptr` — i.e. every Vulkan call is marshalled dynamically through libffi rather than compiled C stubs. ctypes' stub-generation mode is not used. For Vulkan's coarse-grained calls this is rarely the bottleneck, but it is strictly more per-call overhead than [ash][rust-ash]'s direct function-pointer calls or erupted's extern declarations.
- **Per-call structure traffic.** `native`-mode wrappers allocate Ctypes-managed C structs for `make`, convert arrays/strings, wrap results into `Ok`/`Error` via a `Ctypes.view` ([`lib/vk__result.ml`][result-builtin]), and box output parameters into tuples. The bitset phantom machinery, by contrast, is **zero-cost**: `'a set = int` underneath, and all operators compile to machine-word `lor`/`land`.
- **GC interaction.** Keep-alive is via `Gc.finalise` on `array` combinators; everything else is the OCaml GC's business. Empirically adequate: Leonard reports no GC-induced hitches rendering at 60 Hz, calling `Gc.minor` at frame boundaries ([roscidus.com][blog]).
- **Escape hatches, three tiers.** (1) Function bindings are generated in **three modes** — _"`raw`, `regular` or `native`"_ ([README][readme]) — where `raw` _"maps directly to the C function"_, so every command has an unwrapped form. (2) Handles expose `to_ptr`/`unsafe_from_ptr` (dispatchable) and `to_int64`/`unsafe_from_int64` (non-dispatchable), enabling interop with anything expecting raw `VkInstance` values (e.g. `tsdl`'s surface creation). (3) Bitsets expose `of_int`/`to_int`. The branding is thus advisory-but-default: safe by construction, raw on request.

### Error handling & validation integration

This is olivine's best-executed dimension. `VkResult` is split at the FFI boundary by a `Ctypes.view` that maps negative codes to `Error` and non-negative to `Ok` ([`lib/vk__result.ml`][result-builtin]), and — crucially — the generator consumes the registry's per-command `successcodes`/`errorcodes` to **narrow each function's variant rows** to exactly the codes that command can return. The README's worked example:

```ocaml
(* Generated signature for vkCreateInstance (from README.md) *)
val create_instance:
  Vk.Types.Instance_create_info.t ->
  ?allocator:Vk.Types.Allocation_callbacks.t Ctypes_static.ptr ->
  unit ->
    ([ `Success ] * Vk.Types.Instance.t,
     [ `Error_extension_not_present
     | `Error_incompatible_driver
     | `Error_initialization_failed
     | `Error_layer_not_present
     | `Error_out_of_device_memory
     | `Error_out_of_host_memory ])
    result
```

Three things are happening at once: the output parameter (`VkInstance*`) has been folded into the success tuple; the success row is `[ `Success ]`only (a multi-success command like`vkAcquireNextImageKHR` instead gets `` `Success | `Suboptimal_khr | `Timeout | `Not_ready `` — visible in [`examples/triangle.ml`][triangle]'s `acquire*next`); and the error row is the command's \_actual* error set, structurally subtyped so handlers compose across commands. Exhaustiveness checking then forces callers to confront every possible code — Leonard notes the OCaml port _caught error handling the C tutorial code missed_ (an unchecked `vkMapMemory`) ([roscidus.com][blog]). This is strictly stronger than [vulkanalia][rust-vulkanalia]/[ash][rust-ash]'s single shared `VkResult` error enum, and equivalent in intent to the Haskell binding's per-command exception contracts.

Validation-layer integration is conventional and external: the Makefile's `make test-triangle` / `make test-tesseract` targets _"enable the LunarG standard validation layer for a more verbose log"_ ([README][readme]); there is no debug-utils messenger wrapper or olivine-specific validation tooling. Correctness beyond return codes is delegated to the layers — see [sync-validation][sync-validation].

---

## Strengths

- **Highest ideas-per-line-of-code in the survey.** Generative-functor handle branding, phantom singleton/plural bitsets, open-sum `pNext`, functor-gated extensions, and narrowed polymorphic-variant results are each implemented in tens of lines, because the module system does the work — a useful existence proof for what a small typed core can buy.
- **Result narrowing from registry metadata** (`successcodes`/`errorcodes` → per-command structural variants with exhaustiveness checking) is the strongest error-typing story among the thin bindings surveyed, and it demonstrably caught real bugs ([roscidus.com][blog]).
- **Extensions as functors** statically tie an extension's functions to possession of the instance/device they are loaded from — a module-level capability encoding with no runtime dispatch table exposed to the user.
- **The generator typechecks the registry** (`Info.Structured_spec.typecheck`), including evaluating latex `len` expressions — registry semantics are validated, not regex-scraped.
- **Three-mode generation (`raw`/`regular`/`native`)** plus `unsafe_from_ptr`-style escape hatches mean the typed layer never traps you.

## Weaknesses

- **Research artifact in practice.** Never published to opam; essentially one burst of 2017 development; spec frozen at 1.2.162 (no Vulkan 1.3/1.4, no dynamic rendering, no modern sync2 API); the only known production-ish consumer ([roscidus.com][blog]) had to carry a patch branch. Anyone adopting it adopts its maintenance.
- **Zero synchronization modeling**, and the registry's `externsync` data is dropped at the parser with a `(* TODO *)` — no type-level, doc-level, or runtime distinction between externally-synchronized and concurrent-safe operations, which OCaml 5 multicore makes a live hazard.
- **No lifetime/ownership story**: no RAII or destroy tracking; GC keep-alive for C-visible arrays is a per-call-site `Gc.finalise` discipline that the user must remember to go through the `array` combinators to get.
- **WSI is out of scope** — fine as a layering decision, but the SDL/`tsdl` handoff crosses the branding boundary via raw-pointer escape hatches.
- **libffi-dynamic calls** on every command; acceptable for Vulkan's call granularity but strictly slower than stub- or pointer-based bindings, and never benchmarked by the project.
- **Single-level `pNext` typing**: the open sum types the immediate extension struct but not full chains, and an unknown `sType` on read raises an exception rather than producing a typed "unknown" case.
- **Documentation is the README**, examples are two (`triangle`, `tesseract`), and the generated API has no published docs — discoverability depends on reading generator source.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                         | Trade-off                                                                                              |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| "Thin but well-typed": type the existing API, add no safety runtime | Maximum leverage from the module system; no runtime cost or policy imposed                        | Synchronization, lifetimes, and valid usage remain entirely the caller's problem                       |
| Generative functors (`Make()`) for handles                          | Fresh abstract type per handle with one 60-line runtime module; zero generated code per handle    | Branding is nominal-per-instantiation; raw interop needs `unsafe_from_ptr` escape hatches              |
| Phantom `singleton`/`plural` parameter on bitsets                   | Statically separates "one flag" from "flag union" (e.g. `mem` requires a singleton); zero-cost    | Slightly alien API for newcomers; `of_int` bypasses it                                                 |
| `VkResult` → narrowed polymorphic-variant `result` per command      | Exhaustive, composable, per-command error sets straight from registry `successcodes`/`errorcodes` | Polymorphic-variant signatures get long; row types are an OCaml-specific trick                         |
| Extensions as functors over `Instance`/`Device` modules             | Extension availability becomes a static module obligation; pointers loaded once per application   | Proves handle possession, not extension enablement; functor application is ceremony D/Rust users avoid |
| ctypes `foreign` (libffi) rather than C stub generation             | Pure-OCaml build, no C compiler in the loop, simpler generator                                    | Dynamic marshalling overhead on every call; FFI types checked at runtime, not link time                |
| Vendored `spec/vk.xml`, in-tree XML + latex parser, typechecked IR  | Hermetic generation; registry semantics (e.g. `len` math) actually validated                      | Coverage frozen at the vendored version (1.2.162); parser stack is its own maintenance burden          |
| Drop `externsync`/`implicitexternsyncparams` (`(* TODO *)`)         | Pre-multicore OCaml made data races on handles nearly impossible in practice                      | The registry's thread-safety metadata is lost; OCaml 5 invalidates the implicit excuse                 |
| WSI delegated to SDL/`tsdl`                                         | Avoids binding every window system; matches OCaml ecosystem reality                               | The typed boundary is breached by raw-pointer handoff exactly where lifetimes are trickiest            |

---

## Sources

- [Octachron/olivine — GitHub repository][repo] (metadata: created May 28, 2017; last push August 12, 2025; 48 stars; Apache-2.0)
- [`README.md` — module hierarchy, type mapping, function modes, `vkCreateInstance` example, generator internals][readme]
- [`lib/vk__builtin__handle.ml` — generative handle functors, `unsafe_from_ptr`, GC keep-alive arrays][handle-builtin]
- [`lib/vk__builtin__bitset.ml` — phantom `singleton`/`plural` bitsets][bitset-builtin]
- [`lib/vk__result.ml` — `VkResult` Ctypes view][result-builtin]
- [`lib/vk__extension_sig.ml` — `Foreign_instance`/`Foreign_device` extension functors][ext-sig]
- [`aster/handle.ml` — dispatchable vs non-dispatchable functor instantiation][handle-gen]
- [`aster/record_extension.ml` — `sType`/`pNext` open extensible sum generation][record-ext]
- [`aster/fn.ml` — `foreign`-based function binding generation][fn-gen]
- [`info/structured_spec.ml` — registry typechecking; `implicitexternsyncparams` TODO][structured-spec]
- [`examples/triangle.ml` — manual semaphore/submit/present synchronization][triangle]
- [`generator/libgen.ml` — five-stage generation pipeline entry point][libgen]
- [Update spec to v1.2.162 — commit `d7e705c5`, July 23, 2025][spec-bump]
- [Vulkan graphics in OCaml vs C — Thomas Leonard, September 20, 2025][blog]
- [ocaml-ctypes — FFI library underpinning the bindings][ctypes]
- Related: [vulkan (Haskell)][haskell-vulkan] · [ash (Rust)][rust-ash] · [vulkanalia (Rust)][rust-vulkanalia] · [vulkano (Rust)][rust-vulkano] · [erupted (D)][d-erupted] · [Vulkan-Hpp (C++)][cpp-vulkan-hpp] · [vulkan-zig (Zig)][zig-vulkan-zig] · [Synchronization validation][sync-validation] · [Comparison][comparison] · [Survey index][index]

<!-- References -->

[repo]: https://github.com/Octachron/olivine
[readme]: https://github.com/Octachron/olivine/blob/f48eba52fe747c63d72c193d04f2962995e26f82/README.md
[spec-dir]: https://github.com/Octachron/olivine/blob/f48eba52fe747c63d72c193d04f2962995e26f82/spec/vk.xml
[libgen]: https://github.com/Octachron/olivine/blob/f48eba52fe747c63d72c193d04f2962995e26f82/generator/libgen.ml
[handle-builtin]: https://github.com/Octachron/olivine/blob/f48eba52fe747c63d72c193d04f2962995e26f82/lib/vk__builtin__handle.ml
[bitset-builtin]: https://github.com/Octachron/olivine/blob/f48eba52fe747c63d72c193d04f2962995e26f82/lib/vk__builtin__bitset.ml
[result-builtin]: https://github.com/Octachron/olivine/blob/f48eba52fe747c63d72c193d04f2962995e26f82/lib/vk__result.ml
[ext-sig]: https://github.com/Octachron/olivine/blob/f48eba52fe747c63d72c193d04f2962995e26f82/lib/vk__extension_sig.ml
[handle-gen]: https://github.com/Octachron/olivine/blob/f48eba52fe747c63d72c193d04f2962995e26f82/aster/handle.ml
[record-ext]: https://github.com/Octachron/olivine/blob/f48eba52fe747c63d72c193d04f2962995e26f82/aster/record_extension.ml
[fn-gen]: https://github.com/Octachron/olivine/blob/f48eba52fe747c63d72c193d04f2962995e26f82/aster/fn.ml
[structured-spec]: https://github.com/Octachron/olivine/blob/f48eba52fe747c63d72c193d04f2962995e26f82/info/structured_spec.ml
[triangle]: https://github.com/Octachron/olivine/blob/f48eba52fe747c63d72c193d04f2962995e26f82/examples/triangle.ml
[spec-bump]: https://github.com/Octachron/olivine/commit/d7e705c5
[blog]: https://roscidus.com/blog/blog/2025/09/20/ocaml-vulkan/
[ctypes]: https://github.com/yallop/ocaml-ctypes
[haskell-vulkan]: ./haskell-vulkan.md
[rust-ash]: ./rust-ash.md
[rust-vulkanalia]: ./rust-vulkanalia.md
[rust-vulkano]: ./rust-vulkano.md
[d-erupted]: ./d-erupted.md
[cpp-vulkan-hpp]: ./cpp-vulkan-hpp.md
[zig-vulkan-zig]: ./zig-vulkan-zig.md
[sync-validation]: ./sync-validation.md
[comparison]: ./comparison.md
[index]: ./index.md
