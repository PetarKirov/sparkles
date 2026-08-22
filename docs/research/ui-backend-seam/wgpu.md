# wgpu / WebGPU — capability as a request that fails, not a probe that degrades

**Category:** formal capability negotiation. **Last reviewed:** August 23, 2026.
Pinned at [`d4359d74`][rev].

Deliberately not a UI toolkit, and on the list for one reason: `wgpu` is the
only surveyed system whose backend contract is **data the caller negotiates
before drawing anything**, under far more target spread than any toolkit
faces — Vulkan, DX12, Metal, GLES, WebGL2 and WebGPU-in-a-browser behind one
API. Read it for the negotiation model, not for the GPU.

|                    |                                                                                 |
| ------------------ | ------------------------------------------------------------------------------- |
| Language           | Rust                                                                            |
| License            | MIT or Apache-2.0                                                               |
| Repository         | [`gfx-rs/wgpu`][rev]                                                            |
| Documentation      | [`wgpu-types` on docs.rs][docsrs]; the [WebGPU specification][spec] it tracks   |
| Category           | formal capability negotiation                                                   |
| Pinned revision    | `d4359d74946b9908c58eab9e70db061b2b8c8343` (`trunk`)                            |
| Target range       | Vulkan, DX12, Metal, OpenGL/GLES, WebGL2, browser WebGPU, plus a `noop` backend |
| Capability surface | [`Features`][features], [`Limits`][limits], [`DownlevelCapabilities`][limits]   |

## Overview

### What it solves

One API over backends that genuinely disagree about what exists — WebGL2 has no
compute shaders, Metal on old Apple GPUs has no indirect draw, a desktop Vulkan
driver has ray tracing. `wgpu` neither papers over that spread nor silently
emulates it: it **states** the spread in three typed values, and makes the
caller commit to a subset before a device exists.

### Design philosophy

The philosophy is stated in the doc comment on
[`DeviceDescriptor`][device] — and it is the sentence worth transplanting
whole:

> Specifies the features that are required by the device request.
> The request will fail if the adapter cannot provide these features.
>
> **Exactly the specified set of features, and no more or less,
> will be allowed in validation of API calls on the resulting device.**

Two clauses, and the second is the interesting one. Asking for less than the
adapter offers does not merely fail to enable extras — it **forbids** them.
A device created without `Features::TIMESTAMP_QUERY` rejects timestamp
queries even on hardware that supports them. The negotiated set is not a
best-effort hint; it is the validation contract for the device's whole
lifetime, and it is deliberately closed on both sides so that code cannot
accidentally come to depend on a capability that merely happened to be
present on the development machine.

The complementary rule is stated on [`Limits`][limits]:

> We recommend starting with the most restrictive limits you can and manually
> increasing the limits you need boosted. This will let you stay running on all
> hardware that supports the limits you need.

## How it works

Capability is split into **three kinds**, because three different questions
are being asked.

**1. `Features` — discrete, requestable, refusable.** A bitflags value split
into two named halves and unioned into one type
([`wgpu-types/src/features.rs`][features]):

```rust
bitflags_array! {
    /// Features that are not guaranteed to be supported.
    pub struct Features: [u64; 2];

    pub struct FeaturesWGPU features_wgpu { /* native-only extensions */ }

    pub struct FeaturesWebGPU features_webgpu { /* the web standard set */ }
}
```

The split is by provenance: `FeaturesWebGPU` holds what the
[WebGPU specification][spec] defines, `FeaturesWGPU` holds native-only extensions, and `Features::all_webgpu_mask()` / `Features::all_native_mask()`
recover either half. A third mask, `Features::all_experimental_mask()`, names
flags that additionally require `DeviceDescriptor::experimental_features` to
be enabled — a second consent gate on top of the first. Every flag carries a
`#[name("wgpu-shader-float32-atomic")]` kebab-case string, so the whole set
round-trips through `Features::as_str` / `Features::from_str` as text.

**2. `Limits` — continuous, requestable, direction-aware.** A flat struct of
some sixty numbers (`max_texture_dimension_2d`,
`min_uniform_buffer_offset_alignment`, …). The field list exists exactly once,
in a macro that pairs each limit with the direction in which "better" runs
([`wgpu-types/src/limits.rs`][limits]):

```rust
/// The supplied macro should take two arguments. The first is a limit name …
/// The second is `Ordering::Less` if valid values are less than the limit (the
/// common case), or `Ordering::Greater` if valid values are more than the limit
/// (for limits like alignments, which are minima instead of maxima).
macro_rules! with_limits {
    ($macro_name:ident) => {
        $macro_name!(max_texture_dimension_2d, Ordering::Less);
        $macro_name!(min_uniform_buffer_offset_alignment, Ordering::Greater);
        /* … */
    };
}
```

Because each field knows its direction, comparison and merge are written once and
generated for every field (`check_limits`, `check_limits_with_fail_fn`,
`or_better_values_from`, `or_worse_values_from`), and a unit test
(`with_limits_exhaustive`) reconstructs `Limits::unlimited()` through the macro
so the enumeration cannot silently rot.

Three named presets bound the space: `Limits::default()` (the WebGPU
guarantee), `Limits::downlevel_defaults()` ("guaranteed to work on almost all
backends, including the `downlevel` OpenGL backend, but excluding WebGL2"), and
`Limits::downlevel_webgl2_defaults()`, which zeroes whole capability classes —
`max_storage_buffers_per_shader_stage: 0`, every
`max_compute_workgroup_*: 0`.

> [!NOTE]
> A limit of `0` is how `wgpu` spells "this class of work does not exist here".
> The field stays in the struct; only its value collapses. `zero_native_only()`
> applies the same trick to strip a request down to the portable subset.

**3. `DownlevelCapabilities` — observable, not requestable.** The third kind is
the one a UI seam should look at hardest, because it is the kind our `isCanvas`
actually has:

```rust
/// Lists various ways the underlying platform does not conform to the WebGPU standard.
pub struct DownlevelCapabilities {
    pub flags: DownlevelFlags,
    pub limits: DownlevelLimits,
    pub shader_model: ShaderModel,
}
```

`DownlevelFlags` — `COMPUTE_SHADERS`, `INDIRECT_EXECUTION`, `BASE_VERTEX`,
`VERTEX_STORAGE`, `INDEPENDENT_BLEND`, `LINEAR_INTERPOLATION` and about twenty
more — names _ways a platform falls below the standard_. There is no
`required_downlevel_flags` on `DeviceDescriptor`: you cannot ask for these, only
read them and adapt. `DownlevelFlags::compliant()` is the stated floor (every
flag except `ANISOTROPIC_FILTERING`, "WebGPU doesn't actually require aniso"),
and `DownlevelCapabilities::is_webgpu_compliant()` answers in one call whether
this target is at or below it. `ShaderModel` (`Sm2`, `Sm4`, `Sm5`) adds an
**ordered tier** where flags would have been too fine-grained.

**The request.** `Adapter::features()`, `Adapter::limits()` and
`Adapter::get_downlevel_capabilities()` report; `DeviceDescriptor` requests;
`Adapter::validate_device_descriptor` adjudicates
([`wgpu-core/src/instance.rs`][coreinst]):

```rust
// Verify all features were exposed by the adapter
if !self.raw.features.contains(desc.required_features) {
    return Err(RequestDeviceError::UnsupportedFeature(
        desc.required_features - self.raw.features,
    ));
}
/* … */
if let Some(failed) = check_limits(&desc.required_limits, &caps.limits).pop() {
    return Err(RequestDeviceError::LimitsExceeded(failed));
}
```

The error is not a boolean. `UnsupportedFeature` carries the **set difference**
— exactly the flags that were missing — and `FailedLimit` carries
`{ name, requested, allowed }`, so the message reads
`Limit 'max_texture_dimension_2d' value 16384 is better than allowed 8192`.

**Enforcement afterwards.** The negotiated values are copied into the device
(`limits: desc.required_limits.clone(), features: desc.required_features`) and
every later validation reads _those_, not the adapter's
([`wgpu-core/src/device/resource.rs`][coreres]):

```rust
pub(crate) fn require_features(&self, feature: wgt::Features) -> Result<(), MissingFeatures> {
    if self.features.contains(feature) { Ok(()) } else { Err(MissingFeatures(feature)) }
}
```

Call sites read as ordinary preconditions at **resource-description** time, not
at draw time:

```rust
if desc.address_modes.iter().any(|am| am == &wgt::AddressMode::ClampToBorder) {
    self.require_features(wgt::Features::ADDRESS_MODE_CLAMP_TO_BORDER)?;
}
```

## Q1 — measurement units, and who answers

Does not arise as text measurement; `wgpu` has no text. The transferable
analogue is sharp, though: **`wgpu` never normalises a device quantity into a
framework unit.** `min_uniform_buffer_offset_alignment` is reported in the
device's own bytes; the framework supplies a _portable default_ (256) that a
caller may target instead, and marks the field `Ordering::Greater` so generic
code knows smaller is better. Both numbers are visible; neither is a lie.

That is the shape friction §1 lacks. `measure` returns cells because the
toolkit picked a unit and made the backend restate its answer in it. `wgpu`'s
equivalent move would have been to report every alignment as 256 — which it
explicitly does not do, even though 256 is the value it recommends you build
against.

## Q2 — is the contract stated in one place?

**Yes, three times, and the triplication is the design.** This is the subject's
whole contribution.

| Kind             | Question it answers                        | Requestable? | Failure mode                                                                                               |
| ---------------- | ------------------------------------------ | ------------ | ---------------------------------------------------------------------------------------------------------- |
| `Features`       | does this discrete capability exist?       | **yes**      | `RequestDeviceError::UnsupportedFeature` at device creation; `MissingFeatures` validation error afterwards |
| `Limits`         | how much of this can I have?               | **yes**      | `RequestDeviceError::LimitsExceeded(FailedLimit)`                                                          |
| `DownlevelFlags` | in what way is this platform sub-standard? | **no**       | observe and adapt; `MissingDownlevelFlags` if used anyway                                                  |

`sparkles:ui` has only the third kind, and has it implicitly: `rule`,
`scrollbar` and the `pushClip`/`popClip` pair are discovered by
`__traits(compiles)` at each interpreter call site, which is a `DownlevelFlags`
read with no flags, no `is_compliant()`, and no way to state a floor. It has
nothing at all corresponding to the first two.

Note what the split buys that a single flag set would not: because
`DownlevelFlags` is **not** requestable, `wgpu` never has to answer "what should
happen if the caller demands compute on WebGL2" — that request is
unrepresentable. Capabilities that can be refused and capabilities that can only
be observed are different types, not different values of one type.

> [!IMPORTANT]
> The failure messages take pains to say whose fault it is.
> `MissingDownlevelFlags` renders with `DOWNLEVEL_ERROR_MESSAGE`, which opens:
> "This is not an invalid use of WebGPU: the underlying API or device does not
> support enough features to be a fully compliant implementation."
> ([`wgpu-core/src/lib.rs`][corelib]). A seam that refuses work owes the caller
> that distinction — "you asked wrong" and "this target cannot" are different
> diagnoses, and our `__traits(compiles)` skip emits neither.

## Q3 — semantic operations, or primitives?

Does not arise — there are no widgets. But the **naming** of the capability
vocabulary is transferable and cuts against the instinct behind friction §3.
Every flag is named for the thing a caller wants to do, in the caller's
vocabulary: `ADDRESS_MODE_CLAMP_TO_BORDER`, `INDEPENDENT_BLEND`,
`NONBLOCKING_QUERY_RESOLVE`, `DEPTH_TEXTURE_AND_BUFFER_COPIES`. None is named
for a backend internal. The capability namespace is an API-surface namespace,
which is why `require_features` reads as a precondition on a descriptor rather
than as a backend interrogation.

The analogue for us: a capability named `hairlineRule` or `subCellFill` is right;
one named `hasSkia` is not.

## Q4 — command shape, and the wide-record question

Not a command seam. It nevertheless produces the survey's most awkward
evidence for [F2](./comparison.md)
and friction §4, because `Limits` **is** a sixty-field flat record where most
fields are zero on any given target — precisely the shape `sparkles.input.events`
rejected and friction §4 indicts.

`wgpu` keeps it, and pays for it in three specific ways rather than
apologising:

1. the field list exists once, in `with_limits!`, so no operation over limits
   can enumerate them by hand;
2. every field carries its comparison direction in that same list, so
   check/merge/clamp are generated rather than written;
3. a test proves the macro is exhaustive against `Limits::unlimited()`.

The distinction that rescues it: `Limits` has **no tag**. Every field is live
for every instance; a `0` means "none available", not "this field is garbage
for this variant". `DrawOp`'s eighteen fields fail on exactly that point —
`barThumbGlyph` is not "zero scrollbar" on a `fillRect`, it is meaningless, and
`==` compares it anyway. So the correct reading is narrower than F2's: **a wide
flat record is fine when it is tagless and its field list is generated from one
place; it is wrong when a tag makes most fields dead.** That refines F2 rather
than contradicting it, and it supplies the missing rationale for why a
`SumType` is the fix for `DrawOp` but would be the wrong fix for a capability
record.

## Q5 — sub-unit placement, and the tiering answer

No coordinates, so not applicable directly. Two mechanisms answer the
generalised question — _how do you express a capability that varies
continuously?_ — and both beat enumerating positions the way `RuleEdge` does:

- **Ordered tiers.** `ShaderModel::{Sm2, Sm4, Sm5}` is `Ord`, and
  `is_webgpu_compliant()` tests `shader_model >= ShaderModel::Sm5`. Where flags
  would have needed a combinatorial vocabulary, one ordered ladder suffices.
- **Bucketing.** `wgpu-core/src/limits.rs` quantises a device's real limits down
  to one of ten named buckets (`BUCKET_M1`, `BUCKET_LLVMPIPE`, `BUCKET_WARP`,
  `BUCKET_DEFAULT`, `BUCKET_FALLBACK`, …) — motivated by browser fingerprinting
  resistance, but with a second effect worth stealing: it collapses the number
  of distinct capability configurations an application can encounter to
  something enumerable and testable.

This is [F5](./comparison.md)'s
"name a fidelity, not a position" arriving from a completely unrelated domain,
with an extra clause: _and quantise the fidelities, so the set of behaviours you
must test stays finite._

## Q6 — resolved values, semantic role, or both

**Both, deliberately, because they answer different questions** — which is a
sharper reading than friction §6 assumes.

`Limits` carries resolved numbers; `DownlevelFlags` carries semantics — not "how
much" but "in what way this platform is not the standard". They are not two
encodings of one fact, so nothing is duplicated and no consumer must decide which
to trust. Friction §6's `visual` _and_ `slot` **are** two encodings of one fact,
one resolved from the other by the theme. The sin is therefore not carrying two
channels; it is carrying the same information twice while hedging about which is
authoritative.

## Q7 — payload ownership across the frame

The transferable result is the **capability set's** lifetime. The negotiated
`Features` and `Limits` are **copied into the `Device`** at creation; the
descriptor may then die, and every later `require_features` reads the device's
copy rather than borrowing the request or re-reading the adapter. `Limits` is
`Clone` but not `Copy`, with the reason in the source ("Even though this type is
simple, it is not copy because it is large"), and `DeviceDescriptor<L>` is
generic over its label type with a `map_label` adapter, so the borrowed part of a
descriptor is isolated in one type parameter instead of smeared across the
struct.

That last move is the structural lesson for friction §7 (`DrawOp.text` borrowed,
must outlive the op): a `DrawOp` generic over its text-payload type would let the
recorder own strings and the immediate painter borrow them, without the whole op
becoming `@system` under `dip1000`.

## Q8 — extent query

Answered on the **surface**, never on the workload — [F7](./comparison.md) again,
now from a third independent subject. `max_texture_dimension_2d` is a limit you
consult before allocating; `SurfaceCapabilities` reports what a given
surface/adapter pair can do.

`SurfaceCapabilities` also demonstrates a capability shape none of the other
subjects use: a **preference-ordered list**. `formats` is documented as "List of
supported formats to use with the given adapter. The first format in the vector
is preferred", with `usages` guaranteed to contain
`TextureUsages::RENDER_ATTACHMENT`. So the answer to "what can you do" is
sometimes neither a flag nor a number but a ranked menu with a guaranteed floor
element — the caller intersects it with its own preferences and picks the first
survivor.

## Strengths

- **Three capability kinds, typed apart by whether they can be refused.** The
  unrepresentable request (demanding a `DownlevelFlag`) is the cleanest part of
  the design.
- **Errors carry the set difference**, not a boolean — `UnsupportedFeature`
  reports exactly which flags were missing, `FailedLimit` reports name,
  requested and allowed.
- **The request closes on both sides.** Not requesting a capability disables it,
  so portability bugs surface on the developer's machine rather than the user's.
- **One enumeration point with a proof.** `with_limits!` plus its exhaustiveness
  test means the sixty-field record cannot silently gain an unhandled field.
- **A strict mode.** `InstanceFlags::STRICT_WEBGPU_COMPLIANCE` masks the feature
  set down to `Features::all_webgpu_mask()` and calls `zero_native_only()` on
  limits, so an application can _opt into being refused_ everything outside the
  portable subset. Settable from the environment (`WGPU_STRICT_WEBGPU_COMPLIANCE`).
- **Capabilities are nameable text.** Kebab-case names with `as_str`/`from_str`
  make a negotiated set loggable, diffable and pinnable in a golden.

## Weaknesses

- **The vocabulary is enormous.** Two feature words, sixty limits, ~27 downlevel
  flags, a shader model and ten buckets. Correct for a GPU API; a toolkit that
  copied the _scale_ rather than the _structure_ would drown.
- **The floor is a function, not a type.** `DownlevelFlags::compliant()` is
  computed by masking one flag out of `all()`, so "the floor" is a value anyone
  may forget to consult rather than something the type system enforces.
- **No framework-level emulation.** Unlike Qt, which
  [emulates a missing feature](./qt-qpaintengine.md)
  and hands the engine an image, `wgpu` refuses and hands the problem back. That
  is right for a GPU API and only partly right for a UI toolkit, where a missing
  hairline should still draw _something_.
- **Bucketing deliberately misreports the hardware.** Honest about it, but it
  means `Adapter::limits()` is not always the device's truth.

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                     | Trade-off                                                                            |
| --------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Capability is **requested**, and the request can fail                 | Portability bugs surface at development time on the developer's hardware      | Every application must write a negotiation step before it can draw anything          |
| The granted set is **closed above** ("no more or less")               | Code cannot come to depend on a capability that merely happened to be present | Adding a capability to an application is an edit to the request, not just a new call |
| `DownlevelFlags` are **observable but not requestable**               | Makes "demand compute on WebGL2" unrepresentable rather than an error case    | Two mechanisms to learn; callers must know which kind a capability is                |
| `Limits` is a **tagless flat record** with one macro enumeration      | Generic check/merge/clamp written once; exhaustiveness testable               | Sixty fields, most zero on any given target; requires macro machinery to stay honest |
| Named **presets** (`downlevel_defaults`, `downlevel_webgl2_defaults`) | Callers target a portable tier instead of hand-assembling one                 | Presets encode a moment in hardware history and must be maintained                   |
| **Bucketing** quantises real limits into ten named tiers              | Fingerprinting resistance, plus a finite set of configurations to test        | `Adapter::limits()` stops being the literal device truth                             |
| **No framework emulation** of a missing feature                       | A GPU API must not silently insert unbudgeted work                            | Every caller writes its own fallback; no shared degradation path                     |

## Bearing on the proposal

1. **Split our one "optional" bucket into two _types_, not two values**
   (friction §2, [F4](./comparison.md)).
   `wgpu`'s clean line is between capabilities a caller may _demand_ (and be
   refused) and capabilities it may only _observe_. Our `pushClip`/`popClip`
   pair is the second kind — probe and degrade. `rule` at hairline fidelity is
   the first kind: a golden test wants to demand it and be told no.
2. **Adopt the refusable request, and make the refusal carry the difference.**
   `static assert(isCanvas!T)` is a boolean; `UnsupportedFeature(required - available)`
   names the gap. A `CanvasCaps` bitflag with a `require` that returns the
   missing set gives friction §2 both halves at once.
3. **Close the grant above, not just below.** This is the idea most worth
   stealing and the one no other surveyed subject has: a canvas configured
   without `subCellRule` should _refuse_ sub-cell rules even if it could draw
   them. That makes the terminal/GPU parity harness a compile-and-run
   consequence of the seam rather than a discipline.
4. **State the floor as a named value.** `DownlevelFlags::compliant()` and
   `is_webgpu_compliant()` are the model for "which primitives is every backend
   required to have" — the thing friction §2 says `isCanvas` fails to say. Ours
   should be the concept itself: the required set is `isCanvas`, the negotiable
   set is a separate flags value.
5. **Add a strict mode.** `InstanceFlags::STRICT_WEBGPU_COMPLIANCE` masks a GPU
   backend down to the portable subset, from an environment variable. The
   equivalent — a `SkiaCanvas` that refuses everything `GridCanvas` cannot do —
   would catch terminal/GPU divergence during development instead of in a
   golden diff.
6. **Refines [F2](./comparison.md), and this contradicts the flat reading of friction §4.**
   `Limits` is a sixty-field flat record and is _not_ a design error, because it
   is **tagless** and its field list is generated from one macro with an
   exhaustiveness test. The defect in `DrawOp` is the tag, not the width. The
   proposal should say so, because "wide records are bad" would also condemn the
   capability record it is about to introduce.
7. **Complicates [F1](./comparison.md) not at all, but sharpens it.**
   `wgpu` publishes both a portable default (`min_uniform_buffer_offset_alignment`
   = 256) and the device's real value, and never converts one into the other.
   A split measurement layer should do the same: a cell answer _and_ the
   backend's own answer, both readable, neither pretending to be the other.
8. **Consider preference-ordered lists as a fourth capability shape.**
   `SurfaceCapabilities::formats` is a ranked menu with a guaranteed floor
   element rather than a set of flags. For friction §5 — "what fidelities can
   you draw a hairline at?" — a ranked list the caller intersects with its own
   preferences may beat both an enumerator (`RuleEdge`) and a flag.
9. **Do not copy the scale.** Sixty limits and twenty-seven downlevel flags are
   correct for a GPU driver abstraction. `sparkles:ui` has eight `OpKind`s; the
   capability record should be one flags word and a floor, and its value comes
   from the _rules_ above, not from enumerating more.

## Sources

- [`wgpu-types/src/features.rs`][features] — `Features`, `FeaturesWGPU`,
  `FeaturesWebGPU`, the webgpu/native/experimental masks, kebab-case names.
- [`wgpu-types/src/limits.rs`][limits] — `Limits`, `with_limits!`,
  `downlevel_defaults()`, `downlevel_webgl2_defaults()`, `check_limits*`,
  `zero_native_only`, `DownlevelCapabilities`, `DownlevelFlags`, `ShaderModel`.
- [`wgpu-types/src/device.rs`][device] — `DeviceDescriptor::required_features`
  and `required_limits`, and the "no more or less" contract.
- [`wgpu-types/src/instance.rs`][instance] — `InstanceFlags::STRICT_WEBGPU_COMPLIANCE`.
- [`wgpu-types/src/surface.rs`][surface] — `SurfaceCapabilities` as a
  preference-ordered list.
- [`wgpu/src/api/adapter.rs`][apiadapter] — `Adapter::features()`,
  `limits()`, `get_downlevel_capabilities()`, `request_device()` and its
  documented panic conditions.
- [`wgpu-core/src/instance.rs`][coreinst] — `validate_device_descriptor`,
  `RequestDeviceError`, `adapter_allowed`, `filter_features_and_limits`.
- [`wgpu-core/src/device/resource.rs`][coreres] — `require_features`,
  `require_downlevel_flags`, and the device storing the _requested_ sets.
- [`wgpu-core/src/device/mod.rs`][coredev] — `MissingFeatures`,
  `MissingDownlevelFlags`.
- [`wgpu-core/src/limits.rs`][corelimits] — `FailedLimit`, limit bucketing.
- [`wgpu-core/src/lib.rs`][corelib] — `DOWNLEVEL_ERROR_MESSAGE`.
- The [WebGPU specification][spec], which the `Features`/`Limits` split tracks.
- The seam under study: [`libs/ui/src/sparkles/ui/canvas.d`][canvas] and
  [`canvas-seam-friction.md`][friction].

<!-- References -->

[rev]: https://github.com/gfx-rs/wgpu/tree/d4359d74946b9908c58eab9e70db061b2b8c8343
[docsrs]: https://docs.rs/wgpu-types/
[spec]: https://www.w3.org/TR/webgpu/
[features]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-types/src/features.rs
[limits]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-types/src/limits.rs
[device]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-types/src/device.rs
[instance]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-types/src/instance.rs
[surface]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-types/src/surface.rs
[apiadapter]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu/src/api/adapter.rs
[coreinst]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-core/src/instance.rs
[coreres]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-core/src/device/resource.rs
[coredev]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-core/src/device/mod.rs
[corelimits]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-core/src/limits.rs
[corelib]: https://github.com/gfx-rs/wgpu/blob/d4359d74946b9908c58eab9e70db061b2b8c8343/wgpu-core/src/lib.rs
[canvas]: ../../../libs/ui/src/sparkles/ui/canvas.d
[friction]: ../../specs/ui-skia/canvas-seam-friction.md
