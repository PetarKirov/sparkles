# ash (Rust)

The de-facto raw Vulkan binding for Rust — a deliberately thin, `vk.xml`-generated FFI layer whose only safety ambitions are strongly typed handles, lifetime-checked `p_next` chains, and `Result`-typed returns, and on which the safe layers ([vulkano][vulkano], [wgpu][wgpu]) are built.

| Field          | Value                                                                                       |
| -------------- | ------------------------------------------------------------------------------------------- |
| Language       | Rust (MSRV 1.69; `no_std`-capable with `alloc`)                                             |
| License        | MIT OR Apache-2.0 (dual)                                                                    |
| Repository     | [ash-rs/ash][repo]                                                                          |
| Documentation  | [docs.rs/ash][docs] · [crates.io][crate]                                                    |
| Category       | Thin / generated binding                                                                    |
| First release  | `0.1.0`, December 9, 2016 (Maik Klein)                                                      |
| Latest release | `0.38.0+1.3.281`, April 1, 2024; master tracks Vulkan-Headers 1.4.x for the unreleased 0.39 |

> [!NOTE]
> The `+1.3.281` build-metadata suffix pins the [Vulkan-Headers][vk-headers] revision the
> bindings were generated from. The crate has ~25 million downloads on crates.io and is the
> Vulkan substrate of both [wgpu][wgpu]'s `wgpu-hal` Vulkan backend and [vulkano][vulkano]
> (which [replaced its own `vk-sys` bindings with ash][vulkano-1500] in 2021).

---

## Overview

### What it solves

Raw `extern "C"` Vulkan bindings (what `bindgen` emits from `vulkan.h`) give Rust nothing the C
API doesn't have: untyped `u64`/pointer handles, out-parameters, `VkResult` codes the compiler
lets you ignore, hand-rolled function-pointer loading, and `void* pNext` chains assembled from
raw casts. ash's job is to remove exactly that layer of mechanical unsafety — and nothing more.
It generates the full API surface from [`vk.xml`][vk-xml], wraps every command in a method that
takes slices and references instead of pointer-plus-count pairs, returns
`Result<T, vk::Result>`, loads entry/instance/device function-pointer tables itself
(device-level functions through `vkGetDeviceProcAddr`, skipping the loader's dispatch
trampoline), and types the `p_next` extension chain so that only registry-sanctioned structs can
be attached.

What it explicitly does **not** do is enforce Vulkan's usage rules. Nearly every method on
[`Device`][device-src]/`Instance` is `unsafe fn`; there is no synchronization tracking, no
lifetime tying a `vk::Buffer` to its `Device`, and no host-side validation. Correctness is
delegated to the programmer and to the [Khronos validation layers][sync-validation] — the same
contract as C, with the FFI foot-guns removed.

### Design philosophy

The README's feature checklist ([`README.md`][readme]) is the philosophy, verbatim:

> - [x] A true Vulkan API without compromises
> - [x] Convenience features without limiting functionality
> - [x] Additional type safety
> - [x] Device local function pointer loading
> - [x] No validation, everything is **unsafe**
> - [x] Lifetime-safety on structs created with the builder pattern
> - [x] Generated from `vk.xml`

"Without compromises" is load-bearing: wherever ergonomics would limit functionality, ash sides
with functionality (e.g. functions return `Vec<T>` only where that doesn't preclude passing a
`p_next` chain into the output struct, and "_Raw function pointers are available, if something
hasn't been exposed yet in the higher level API_" — [`README.md`][readme]). Within this survey,
ash is the **baseline data point**: the maximum type safety attainable while remaining a
zero-policy 1:1 mirror of the C API. Compare [vulkanalia][vulkanalia] (the other Rust thin
binding, which makes even unsafety more explicit) and [vulkano][vulkano] (the safety-first layer
built on top of ash).

---

## How it works

A program touches three hand-written wrapper types — `Entry` (loader-level), `Instance`, and
`Device` — each owning a generated function-pointer table (`EntryFnV1_0`…, `InstanceFnV1_0`…,
`DeviceFnV1_0`…`DeviceFnV1_3`) populated at creation time. Extensions live in per-extension
modules (`ash::khr::swapchain`, `ash::ext::debug_utils`, …), each exposing its own
`Instance`/`Device` loader struct so instance-level functions can't accidentally be fetched via
`vkGetDeviceProcAddr` (a deliberate split introduced in 0.38, [`Changelog.md`][changelog]). All
raw types, constants, and bitflags live in the generated [`ash::vk`][vk-mod] module.

```rust
// README.md — extension loading
use ash::khr;
let swapchain_loader = khr::swapchain::Device::new(&instance, &device);
let swapchain = swapchain_loader.create_swapchain(&swapchain_create_info).unwrap();
```

### Binding generation & API coverage

The bindings are produced by an in-repo, unpublished [`generator`][generator] crate
(`generator/Cargo.toml` pins its inputs): [`vk-parse`][vk-parse] 0.20 (with the
`vkxml-convert` feature) and `vkxml` 0.3 parse the registry, `nom` + `regex` parse the C macro
definitions `vk.xml` embeds (e.g. `VK_MAKE_API_VERSION`), and `proc-macro2`/`quote`/`syn` emit
the ~76k-line [`definitions.rs`][definitions] plus `enums.rs`, `bitflags.rs`, `extensions.rs`,
`features.rs`, and `const_debugs.rs`. A **pinned** `bindgen` (`=0.69.4`, "_Pin version to have
control over how ash/src/vk/native.rs is generated_" — [`generator/Cargo.toml`][gen-cargo])
separately translates the C video-codec headers (`vk_video/*.h`) into `vk::native`, which is why
the Vulkan Video bindings are declared semver-exempt in the README. Generation is offline: the
output is committed, so consumers never run the generator, and a release is regenerated against
a specific Vulkan-Headers tag (the `+1.3.281` suffix).

Coverage is total — core 1.0–1.4 plus every extension in the registry, including provisional
ones behind a `provisional` cargo feature (the generator wraps those in
`#[cfg(feature = "provisional")]`, [`generator/src/lib.rs`][gen-src]). Registry metadata that
**survives** into Rust: `structextends` → [`Extends`](#type-system-techniques) impls; member
`len` attributes → combined slice setters; `optional` parameters → `Option<&T>` (lowered via the
`RawPtr` trait, [`lib.rs`][lib-src]); `successcodes`/`errorcodes` → `Result`-shaped wrappers;
`sType` values → `TaggedStructure::STRUCTURE_TYPE`; `deprecated` attributes → `#[deprecated]`
with a link to the explanation; handle `objtypeenum` → `Handle::TYPE`. Metadata that is
**dropped**: the string `externsync` does not occur anywhere in
[`generator/src/lib.rs`][gen-src] — external-synchronization requirements, like all other
valid-usage rules, vanish at generation time (see
[Synchronization safety](#synchronization-safety)).

### Handle lifetime & ownership model

Handles are `#[repr(transparent)]` newtypes with **no ownership semantics**: dispatchable
handles wrap `*mut u8`, non-dispatchable ones wrap `u64`
([`vk/macros.rs`][macros]: `define_handle!` / `handle_nondispatchable!`). Every handle is
`Copy + Clone + Eq + Hash + Default` (default = null), dispatchable handles are explicitly
`unsafe impl Send/Sync`, and all implement the [`Handle`][vk-src] trait:

```rust
// ash/src/vk.rs
pub trait Handle: Sized {
    const TYPE: ObjectType;
    fn as_raw(self) -> u64;
    fn from_raw(_: u64) -> Self;
    fn is_null(self) -> bool { self.as_raw() == 0 }
}
```

That is the entire model. A `vk::Buffer` is not tied to the `Device` that created it, can be
freely copied, used after `destroy_buffer`, or sent across threads mid-recording — none of which
the compiler can see. `Drop` is implemented nowhere; destruction is an explicit `unsafe`
`destroy_*` call, and double-destroy/leak prevention is the caller's job. The only typed
property a handle carries is `Handle::TYPE` (its `VkObjectType`), which is what makes generic
debug-marker utilities possible. This is the maximal contrast with [vulkano][vulkano]'s
`Arc`-tracked ownership and with what D's [DIP1000][dip1000] `scope`/ownership could express —
ash chose `Copy` handles precisely so that the binding adds zero lifetime policy.

The one place real lifetimes do appear is **structs**, not handles: since 0.38 every generated
struct containing a pointer carries a `'a` parameter and a `PhantomData<&'a ()>` marker
([`definitions.rs`][definitions]):

```rust
// ash/src/vk/definitions.rs (generated)
pub struct DeviceQueueCreateInfo<'a> {
    pub s_type: StructureType,
    pub p_next: *const c_void,
    pub flags: DeviceQueueCreateFlags,
    pub queue_family_index: u32,
    pub queue_count: u32,
    pub p_queue_priorities: *const f32,
    pub _marker: PhantomData<&'a ()>,
}
```

The separate `vk::XxxBuilder` types of 0.37 were deleted; setters now sit directly on the struct
and consume `self`, so "_The borrow checker now ensures structs cannot outlive contained
references_" with no `.build()` escape hatch that erased the lifetime
([`Changelog.md`][changelog]). A slice setter writes the pointer **and** the count in one move
(`queue_priorities(&'a [f32])` sets both `p_queue_priorities` and `queue_count`), eliminating
the classic count/pointer mismatch. The guarantee is enforced in CI by a `trybuild` compile-fail
test, [`tests/fail/long_lived_root_struct_borrow.rs`][trybuild]: reading a chained output struct
while the root struct still borrows it is a compile error.

### Synchronization safety

None — by design, and explicitly. ash exposes `vkQueueSubmit`, `vkCmdPipelineBarrier`,
fences, binary and timeline semaphores, and queue-family ownership transfer **exactly as the C
API does**, every one an `unsafe fn` whose contract lives in the linked Vulkan refpage:

```rust
// ash/src/device.rs
pub unsafe fn queue_submit(
    &self,
    queue: vk::Queue,
    submits: &[vk::SubmitInfo<'_>],
    fence: vk::Fence,
) -> VkResult<()>
```

The contribution is limited to _shape_: barriers are typed slices
(`memory_barriers: &[vk::MemoryBarrier<'_>]`), stage/access masks are distinct bitflag newtypes
(`vk::PipelineStageFlags2` vs `vk::AccessFlags2` cannot be swapped), and wait/signal arrays are
length-checked slices instead of count+pointer pairs. There is no render graph, no hazard
tracking, no typestate on command buffers, and — because `externsync` is dropped at generation
time (see [above](#binding-generation--api-coverage)) — **no distinction in the signature
between externally synchronized and internally synchronized commands**: `queue_submit` (caller
must externally synchronize `queue` and `fence`) takes the same `&self` and `Copy` handles as a
thread-safe query. A user must read the spec or run the
[synchronization validation layer][sync-validation] to know the difference. The README's "_No
validation, everything is **unsafe**_" is the whole synchronization story; this is the gap every
higher layer in this survey ([vulkano][vulkano], [daxa][daxa], [vuk][vuk]) exists to fill.

### Type-system techniques

ash concentrates its type-system budget on four mechanisms:

1. **Newtype handles and bitflags.** Every handle, enum, and flag type is a distinct newtype
   with associated constants (`vk::PipelineBindPoint::GRAPHICS`,
   `vk::AccessFlags::COLOR_ATTACHMENT_READ`), so mixing a `vk::Buffer` into an image parameter
   or OR-ing access flags into a stage mask is a type error — the cheapest 80% of FFI safety.

2. **Lifetime-parameterized structs** (previous section): borrow-checked `p_next`/array
   pointers with `PhantomData`, replacing the builder-typestate approach of 0.37.

3. **Typed `p_next` chains via marker traits.** The registry's `structextends` attribute is
   compiled into an `unsafe` marker trait per relationship
   ([`vk.rs`][vk-src], [`generator/src/lib.rs`][gen-src]):

   ```rust
   // ash/src/vk.rs
   /// Implemented for every structure that extends base structure `B`. Concretely that means
   /// struct `B` is listed in its array of `structextends` in the Vulkan registry.
   pub unsafe trait Extends<B> {}

   // generated, e.g.:
   unsafe impl Extends<DeviceCreateInfo<'_>> for PhysicalDeviceVariablePointerFeatures<'_> {}
   ```

   (master generates 1,217 such impls). The safe chain-builder is constrained by it —
   `fn push<T: Extends<Self> + TaggedStructure<'_>>(self, next: &'a mut T) -> Self` — so
   attaching a struct to a chain that `vk.xml` doesn't sanction **does not compile**. `push` is
   safe because it `assert!`s the pushed struct's own `p_next` is null ("_push() expects a
   struct without an existing p_next pointer chain_"); splicing a whole pre-built chain requires
   the `unsafe fn extend` introduced in 0.38 (which must trust every node of the foreign chain).
   `TaggedStructure<'a>` is itself an `unsafe trait` asserting `BaseOutStructure` layout
   compatibility and carrying the `STRUCTURE_TYPE` constant that `Default` writes into `s_type`
   — the user never touches `sType` at all.

4. **Checked downcasting of returned chains.** For the inverse problem — decoding a
   `p_next` chain handed _back_ by the driver or a validation-layer callback — the
   [`match_out_struct!`/`match_in_struct!`][lib-src] macros dispatch on the runtime `s_type`
   tag against each arm's `TaggedStructure::STRUCTURE_TYPE`, rebinding the pointer at the
   matched type: a tag-checked union read, the closest a C ABI allows to a safe downcast.

Absent, deliberately: no phantom branding of handles to their parent `Device`, no
linear/affine ownership, no typestate on command buffers or pipeline construction, no
const-generic API-version gating. Each was left out because it would either add policy
("compromises") or break the 1:1 C correspondence.

### Overhead & escape hatches

The overhead story is effectively **zero beyond C**:

- Every wrapper method is `#[inline]` and expands to a direct call through the cached
  per-device/per-instance function-pointer table — no global dispatch, no mutex, no
  ref-counting, no handle table. `vk::Result::result()` is a `match` on `SUCCESS`.
- Structs are `#[repr(C)]` with a zero-sized `PhantomData` appended; the lifetime machinery,
  `Extends` impls, and `TaggedStructure` constants are all compile-time-only. `push` is a
  two-pointer write plus one null `assert!`.
- The only allocations the binding itself performs are the `Vec<T>` returns for enumeration
  commands, implemented by [`read_into_uninitialized_vector`][lib-src], which loops the
  count/fill protocol until the driver stops returning `vk::Result::INCOMPLETE` and writes
  directly into uninitialized capacity.
- The `debug` (default) feature generates `Debug` impls that pretty-print flag names; disabling
  it shrinks the binary. `loaded` (default) pulls in `libloading` for runtime discovery;
  `linked` instead links the loader at build time and exposes the infallible `Entry::linked()`.

Escape hatches are first-class, in both directions: `device.fp_v1_0()` exposes the raw
function-pointer tables ("_if something hasn't been exposed yet in the higher level API_" —
[`README.md`][readme]); `Handle::as_raw`/`from_raw` convert any handle to/from `u64` for FFI
with C/C++ middleware (this is the interop hinge [wgpu][wgpu]'s `wgpu-hal` and gpu-allocator
rely on); `Entry::from_static_fn()` lets the application supply its own
`vkGetInstanceProcAddr`; and every struct field is `pub`, so the setter layer is skippable with
plain struct syntax (`vk::ApplicationInfo { api_version: …, ..Default::default() }`).

### Error handling & validation integration

Every fallible command returns `pub type VkResult<T> = Result<T, vk::Result>`
([`lib.rs`][lib-src]) — success codes other than `SUCCESS` that carry a payload (e.g.
`SUBOPTIMAL_KHR` from `acquire_next_image`, which returns `VkResult<(u32, bool)>`) are mapped
case-by-case in the hand-written wrappers. `vk::Result` itself is the raw `VkResult` newtype, so
no information is lost, and structs/commands are `#[must_use]` where the registry marks them so.
Out-parameters are materialized through `MaybeUninit` + `assume_init_on_success`, so a failed
creation can never yield a half-initialized handle.

Host-side validation is **out of scope** ("No validation"): ash integrates with the
[Khronos validation layers][sync-validation] rather than reimplementing them, providing the
typed plumbing — `ext::debug_utils` wrappers, `vk::DebugUtilsMessengerCreateInfoEXT` (pushable
into `InstanceCreateInfo` via `push`, validating instance creation itself), and the
`match_in_struct!` macro for decoding callback data. Functions that failed to load are stubbed
with a panicking function pointer, so calling a Vulkan 1.1 entry point on a 1.0 instance panics
loudly instead of jumping to null.

---

## Strengths

- **Zero-overhead by construction**: `#[inline]` wrappers over cached function-pointer tables;
  all safety machinery (`Extends`, lifetimes, `TaggedStructure`) is compile-time-only.
- **The `p_next` chain is actually type-checked** — `structextends` is the one piece of registry
  safety metadata ash promotes into the type system, and it eliminates a whole class of
  silent-driver-ignores-your-struct bugs; `s_type` is never written by hand.
- **Lifetime-checked struct graphs without builders** (since 0.38): the borrow checker rejects
  dangling `p_*` pointers, proven by an in-tree compile-fail test.
- **Total, fast-moving coverage**: core 1.0–1.4 plus all extensions including video and
  provisional, regenerated from each Vulkan-Headers tag.
- **Honest contract**: `unsafe fn` everywhere a Vulkan valid-usage rule exists, so the unsafety
  is visible in the source rather than hidden behind a leaky safe facade.
- **Proven foundation**: [wgpu][wgpu]'s Vulkan backend and [vulkano][vulkano] both build on it;
  `as_raw`/`from_raw` make C/C++ interop (VMA, OpenXR) trivial.
- **`no_std` + `alloc` support** and a small feature surface (`std`, `debug`, `loaded`,
  `linked`, `provisional`).

## Weaknesses

- **No synchronization model at all** — barriers, semaphores, fences, timeline semaphores, and
  queue-family transfers are passed through verbatim; correctness depends entirely on the
  programmer plus the [validation layers][sync-validation].
- **`externsync` metadata is discarded**: externally synchronized parameters are
  indistinguishable from thread-safe ones in the signatures (`&self` + `Copy` handles
  everywhere), so a data race on a `VkQueue` or `VkCommandPool` compiles silently.
- **No handle ownership/lifetime tracking**: use-after-destroy, double-destroy, leaks, and
  cross-device handle mixups are all expressible in (unsafe) safe-looking code.
- **Struct lifetimes are uniform `'a` borrows**, not a model of Vulkan's actual retention rules
  — they are conservative (occasionally forcing awkward scoping, as the
  `test_use_struct_after_pointer_chain` test demonstrates) yet say nothing about how long the
  _driver_ needs the memory.
- **Breaking releases are routine** (0.37 → 0.38 renamed every extension module and deleted all
  builders); there is no 1.0 and the video bindings are explicitly semver-exempt.
- The `Vec<T>`-returning enumeration helpers allocate and loop on `INCOMPLETE` — convenient,
  but a hot-path caller must drop to the raw function pointers to control allocation.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                                    | Trade-off                                                                                          |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| "No validation, everything is `unsafe`"                          | 1:1 C semantics; safety layers can be built on top without fighting binding policy           | Every call site is `unsafe`; all valid-usage discipline outsourced to the user + validation layers |
| `Copy` newtype handles, no `Drop`, no parent tracking            | Zero overhead; handles freely shareable/FFI-able; matches Vulkan's own handle semantics      | Use-after-destroy, double-free, and wrong-device bugs are uncatchable at compile time              |
| Lifetimes + `PhantomData` on structs, builders deleted (0.38)    | Borrow checker proves `p_*` pointers outlive the struct; no `.build()` lifetime-erasure hole | Generated structs gain a viral `'a` parameter; conservative borrows occasionally over-constrain    |
| `structextends` → `Extends<B>` marker traits gating `push`       | Invalid `p_next` attachment becomes a compile error; `s_type` auto-set via `TaggedStructure` | Only registry-declared relationships allowed; chains built elsewhere need `unsafe extend`          |
| Drop `externsync` (and all other valid-usage metadata)           | Keeping signatures identical to C; encoding it would impose an ownership/threading policy    | Externally synchronized parameters look exactly like thread-safe ones in the types                 |
| Offline generation, committed output, pinned headers + `bindgen` | Consumers never run the generator; reproducible bindings per Vulkan-Headers tag              | New extensions wait for a regeneration + release; ~76k-line generated `definitions.rs` in-tree     |
| Per-device function-pointer tables (`vkGetDeviceProcAddr`)       | Skips the loader's per-call dispatch trampoline; missing functions panic loudly              | `Entry`/`Instance`/`Device` must outlive their children — documented, not compiler-enforced        |
| `Vec<T>` returns with an `INCOMPLETE` retry loop                 | Ergonomic enumeration; handles the count-changed-between-calls race correctly                | Hidden allocation; `no_std` still requires `alloc`; hot paths must use raw pointers instead        |

---

## Sources

- [ash-rs/ash — GitHub repository][repo]
- [ash on docs.rs][docs] · [ash on crates.io][crate]
- [`README.md` — feature checklist, builder/`push` docs, raw function pointers][readme]
- [`Changelog.md` — 0.38 builder removal, `extend` semantics, module reorganization][changelog]
- [`ash/src/vk.rs` — `Handle`, `TaggedStructure`, `Extends`, `push`/`extend`, chain tests][vk-src]
- [`ash/src/vk/macros.rs` — `define_handle!` / `handle_nondispatchable!`][macros]
- [`ash/src/vk/definitions.rs` — generated lifetime-parameterized structs][definitions]
- [`ash/src/lib.rs` — `VkResult`, `match_out_struct!`, `read_into_uninitialized_vector`][lib-src]
- [`ash/src/device.rs` — hand-written `unsafe fn` command wrappers][device-src]
- [`ash/tests/fail/long_lived_root_struct_borrow.rs` — compile-fail lifetime proof][trybuild]
- [`generator/Cargo.toml` — `vk-parse`, `vkxml`, pinned `bindgen`][gen-cargo] · [`generator/src/lib.rs`][gen-src]
- [vulkano-rs/vulkano#1500 — "Proposal: replace vk-sys with ash"][vulkano-1500]
- [Vulkan registry — `vk.xml`][vk-xml] · [Vulkan-Headers][vk-headers] · [vk-parse crate][vk-parse]
- Related: [vulkanalia (Rust)][vulkanalia] · [vulkano (Rust)][vulkano] · [wgpu (Rust)][wgpu] ·
  [Vulkan-Hpp (C++)][vulkan-hpp] · [erupted (D)][erupted] · [sync validation][sync-validation] ·
  [comparison][comparison]

<!-- References -->

[repo]: https://github.com/ash-rs/ash
[docs]: https://docs.rs/ash/latest/ash/
[crate]: https://crates.io/crates/ash
[readme]: https://github.com/ash-rs/ash/blob/master/README.md
[changelog]: https://github.com/ash-rs/ash/blob/master/Changelog.md
[vk-src]: https://github.com/ash-rs/ash/blob/master/ash/src/vk.rs
[vk-mod]: https://docs.rs/ash/latest/ash/vk/index.html
[macros]: https://github.com/ash-rs/ash/blob/master/ash/src/vk/macros.rs
[definitions]: https://github.com/ash-rs/ash/blob/master/ash/src/vk/definitions.rs
[lib-src]: https://github.com/ash-rs/ash/blob/master/ash/src/lib.rs
[device-src]: https://github.com/ash-rs/ash/blob/master/ash/src/device.rs
[trybuild]: https://github.com/ash-rs/ash/blob/master/ash/tests/fail/long_lived_root_struct_borrow.rs
[generator]: https://github.com/ash-rs/ash/tree/master/generator
[gen-cargo]: https://github.com/ash-rs/ash/blob/master/generator/Cargo.toml
[gen-src]: https://github.com/ash-rs/ash/blob/master/generator/src/lib.rs
[vk-parse]: https://crates.io/crates/vk-parse
[vk-xml]: https://registry.khronos.org/vulkan/specs/latest/registry.html
[vk-headers]: https://github.com/KhronosGroup/Vulkan-Headers
[vulkano-1500]: https://github.com/vulkano-rs/vulkano/issues/1500
[dip1000]: https://dlang.org/spec/memory-safe-d.html
[daxa]: ./cpp-daxa.md
[vuk]: ./cpp-vuk.md
[vulkanalia]: ./rust-vulkanalia.md
[vulkano]: ./rust-vulkano.md
[wgpu]: ./rust-wgpu.md
[vulkan-hpp]: ./cpp-vulkan-hpp.md
[erupted]: ./d-erupted.md
[sync-validation]: ./sync-validation.md
[comparison]: ./comparison.md
