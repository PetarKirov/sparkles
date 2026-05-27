# DbI Versioning Library — Revised Plan

This plan supersedes the original `sparkles:semver → sparkles:versions`
overhaul sketch. It is grounded in a compiler spike (see _Findings from the
spike_ below), and reframed around the actual goals you stated:

- **Primary goal:** a Design-by-Introspection redesign so a single engine can
  serve **multiple versioning schemes** (strict SemVer 2.0.0, Dlang-style with
  zero-padded minor/patch, future schemes such as PEP 440 / CalVer / a
  compact internal layout, etc.).
- **Secondary goal:** a more efficient data layout (bit-packed core, optional
  SSO strings, fast `opCmp` via a single integer comparison).

The DbI design tenets we are reaching for are described in
`docs/guidelines/design-by-introspection-00-intro.md`: a minimal **shell**
(the engine) driven by **hooks** (the `Layout` type with optional UDAs and
optional members). The shell must work with `Layout = void` semantics in
spirit — every UDA, every secondary field, every formatting concern is opt-in.

## Module name

`version` is a D keyword, so the obvious singular name is taken. Decision:

- **Rename the dub sub-package from `sparkles:semver` to `sparkles:versions`.**
- The D FQN for the engine type is **`sparkles.versions.Version`**, i.e.
  the package module is `sparkles.versions` and the engine is the
  `Version(Layout)` template inside it.
- The SemVer 2.0.0 layout produces `alias SemVer = Version!SemVerLayout;`,
  exported from `sparkles.versions`.
- The existing `sparkles.semver` module is removed; downstream imports
  switch to `import sparkles.versions : SemVer, SemVerParseMode;`.

## Findings from the spike

We ran four short spikes against DMD 2.110.0 and LDC 1.41.0 (which carries
roughly the DMD 2.111 frontend). Full programs were not checked in; they
informed the decisions below.

1. **`std.bitmanip.bitfields` is fully `@safe pure nothrow @nogc` and BetterC-
   compatible.** Setter contracts assert width-overflow but stay `nothrow`
   (the assert throws an `Error`, which is allowed in `nothrow`). Conclusion:
   `std.bitmanip` is a viable backbone for the bit-packed core; we do **not**
   need a custom UDA-based bitfield generator at this stage.

2. **Built-in (C-style) bitfields require `-preview=bitfields`** on DMD 2.110,
   and reading them through a union of two overlapping fields raises a
   `@safe` deprecation ("cannot access overlapped field with unsafe bit
   patterns in `@safe` code"). Reinterpretation therefore requires a small
   `@trusted` shim. Built-in bitfields enable `__traits(isBitfield)` and (on
   LDC) `__traits(getBitfieldOffset)` / `__traits(getBitfieldWidth)`.

3. **`__traits(getBitfieldOffset/Width)` is unavailable on DMD 2.110.** It
   works on LDC 1.41.0. We must not assume both compilers expose it. The DbI
   engine should compute field offsets/widths by summing declared widths
   itself, falling back to the trait only as a verification check when
   present.

4. **Bit-allocation order is LSB-first, declaration order ascending.** In
   both `std.bitmanip.bitfields` and built-in bitfields, the first declared
   field occupies the low bits and the last declared field occupies the high
   bits. For example:

   ```
   stableFlag : 1   // bits  [0 .. 0]   (LSB)
   patch      : 24  // bits  [1 .. 24]
   minor      : 24  // bits  [25 .. 48]
   major      : 15  // bits  [49 .. 63]  (MSB)
   ```

   Reinterpreting via `union { Layout core; ulong packed; }` then gives
   `(major << 49) | (minor << 25) | (patch << 1) | stableFlag`.

5. **Critical correction to the previous plan: the no-prerelease flag must be
   at the LSB, not the MSB.** SemVer 2.0.0 precedence rules say
   `2.0.0-alpha > 1.999.999` (major dominates everything). If the
   stable-vs-prerelease bit sits at the MSB, then _every_ stable version
   compares greater than _every_ prerelease, which violates the spec. The
   spike confirmed this empirically:
   - Flag at MSB: `2.0.0-pre > 1.999.999 stable? **false**` (wrong)
   - Flag at LSB: `2.0.0-pre > 1.999.999 stable? **true**` (correct)

   Put major at the top, then minor, then patch, then the
   "has-no-prerelease" tiebreaker bit at the bottom. Encoding: `1` = stable,
   `0` = prerelease — so `1.0.0 > 1.0.0-alpha` falls out of integer compare.

## Phase 1 — DbI vocabulary

Define the UDAs and core-type selector once. These form the engine's
contract with layout types.

```d
/// Tags a member as a semantic component that participates in the version's
/// printed form (and, by default, in comparison).
///
/// `printOrder` controls the formatting sequence; smaller numbers print
/// first. `printWidth` is the minimum number of digits emitted by
/// `toString` and the minimum width the parser will accept without
/// rejecting (e.g. SemVer's leading-zero rule). `printWidth == 0` means
/// "no padding, no width constraint" — the natural default.
///
/// Width is a *static* property of the layout, not a per-instance value.
/// We do not store widths at runtime; layouts that need width-preserving
/// round-tripping must declare it at the type level.
struct Component { int printOrder; int printWidth = 0; }

/// Tags an internal flag that participates in ordering but is not printed.
/// Conventional use: the "has-no-prerelease" bit. Must sit at the LSB so
/// it acts only as a tiebreaker after the printed components.
enum InternalFlag;

/// Maps the byte-size of a Layout to the unsigned integer used for packed
/// reinterpretation. 1/2/4/8 → ubyte/ushort/uint/ulong. 16 bytes is
/// deliberately omitted in the first cut (see Phase 5 / open questions).
template GetCoreType(size_t bytes) { /* … */ }
```

## Phase 2 — Optional SSO string (POD-preserving)

A 24-byte struct (on 64-bit) overlaying:

- a 23-byte inline `char[23]` plus a 1-byte length, **OR**
- a standard GC-managed `string` slice (16 bytes on 64-bit, plus the length
  tag bit pattern that distinguishes the two modes).

Because the heap path stores a GC `string`, the struct has no destructor,
no postblit, and no manual `opAssign` — it stays POD-trivially-copyable.
We deliberately do not switch to manual `pureMalloc` here; the complexity
cost (ownership, exception safety, losing trivial copyability) is not
justified for any current consumer.

SemVer 2.0.0 has **two** strings — prerelease and build metadata — with
asymmetric precedence rules:

- Prerelease participates in ordering (`1.0.0-alpha < 1.0.0`).
- Build metadata is ignored for precedence.

The engine must treat these as separate optional capabilities, not a single
"hasSsoString" bit. We expose them as two independent UDAs / fields on the
layout, e.g. `@Component(3) SsoString prerelease;` and
`@Component(4) @InternalFlag SsoString build;` (where `@InternalFlag` on
the build field signals "do not include in opCmp"; we will likely refine
this name — see _Open questions_).

## Phase 3 — Engine core: `Version(Layout)`

```d
struct Version(Layout)
{
    private alias CoreType = GetCoreType!(Layout.sizeof);

    union { Layout core; CoreType packed; }

    // CTFE validation runs at instantiation:
    //   - Layout.sizeof ∈ {1, 2, 4, 8} (Phase 5 decision)
    //   - Every member is a real bitfield (where the compiler supports the
    //     trait) OR a recognised side-band slot (e.g. SsoString)
    //   - Every @Component.printOrder is unique
    //   - Exactly one @InternalFlag of width 1 at offset 0 (LSB) for
    //     layouts that need a precedence tiebreaker; zero allowed for
    //     layouts that don't (e.g. TinyLayout)
    //   - Total declared bit-width <= sizeof(CoreType) * 8

    // … methods composed via the hooks below …
}
```

The shell-with-hooks property: a layout that declares only one `@Component`
with default `printWidth`, no `@InternalFlag`, no SSO strings is a valid
input. It produces a `Version` that compares as a single integer and prints
as a single number. That is the DbI "void-hook" baseline.

## Phase 4 — Operations

### `opCmp`

Two-stage compare:

1. Compare `lhs.packed` against `rhs.packed` as a single unsigned integer.
   Because no width metadata is stored at runtime, every bit in the packed
   core is semantically meaningful — there is no mask step. The `1.02.3`
   vs `1.2.3` round-tripping concern is handled at the parse/print
   boundary using the layout's static `printWidth`, not by storing widths
   in the value.

2. If the integers tie _and_ the layout declares a prerelease SSO field,
   compare the prerelease lexicographically per SemVer §11. Build metadata
   is never consulted.

For `CoreType.sizeof <= 8`, stage 1 is a single CPU compare. We are
**not** adopting `core.int128.Cent` in the first cut: it complicates the
generated code (`ult`/`ugt` are function calls), and the only payoff
would be a 128-bit layout, which we do not need today. If we ever do,
this is a localised addition.

### `toString`

CTFE-driven from the layout:

1. Collect every `@Component` member, sorted by `printOrder`.
2. For each, format with `"%0*d"` and the component's static `printWidth`
   when `printWidth > 0`, else `"%d"`.
3. Emit punctuation between components per a separate per-layout hook
   (default: `.`). SemVer-specific punctuation (`-` before prerelease,
   `+` before build) is encoded as a per-component "prefix" UDA, not
   hardcoded in the engine.

`toString` writes into an output range (per `AGENTS.md` conventions). The
existing `SemVer.toString` tests should migrate to `checkToString` from
`sparkles.core_cli.smallbuffer`.

### `truncateTo!"name"()`

A CTFE function that computes the bitmask of every bit at or above the
named component and ANDs the packed core with it. Returns a new `Version`
of the same type, with the lower components zeroed. Useful for "group by
major.minor"-style operations and cheap to provide once the bit map
exists.

## Phase 5 — Concrete layouts

We ship four layouts initially. All sized at a power-of-two number of
bytes so they fit the `GetCoreType` selector cleanly.

| Layout         | Size | Bitfields (LSB → MSB)                                            | Component widths (major / minor / patch) | SSO                   |
| -------------- | ---- | ---------------------------------------------------------------- | ---------------------------------------- | --------------------- |
| `SemVerLayout` | 8 B  | `stableFlag:1, patch:24, minor:24, major:15`                     | unpadded / unpadded / unpadded           | `prerelease`, `build` |
| `DmdLayout`    | 8 B  | `stableFlag:1, patch:24, minor:24, major:15`                     | unpadded / **2-digit** / **2-digit**     | `prerelease`, `build` |
| `DmdOptimized` | 4 B  | `prereleaseNum:6, prereleasePhase:2, patch:6, minor:10, major:8` | unpadded / unpadded / unpadded           | **none**              |
| `TinyLayout`   | 4 B  | `patch:8, minor:8, major:16`                                     | unpadded / unpadded / unpadded           | none                  |

Notes:

- `SemVerLayout` and `DmdLayout` share the same bitfield shape; they
  differ only in the static `printWidth` carried on each component's
  `@Component` UDA. This makes them a clean DbI demonstration: same
  storage, different format hooks.
- Zero-padded round-tripping is therefore a _layout-level_ property, not
  a per-instance one. `DmdLayout` will always emit minor/patch as
  2-digit zero-padded; it cannot round-trip an input like `1.2.3` to
  itself (it will print `1.02.03`). That is the deliberate consequence of
  not storing widths at runtime.
- **`DmdOptimized` exploits two facts about DMD's actual versioning** to
  fit a fully ordered, fully formatted version into 4 bytes with **no
  SSO allocations whatsoever**:
  1. DMD releases carry no build metadata, so no `build` SSO is needed.
  2. DMD prereleases follow the constrained grammar `beta.N` or `rc.N`
     (e.g. `2.111.0-beta.2`, `2.111.0-rc.3`), so the prerelease can be
     encoded as a 2-bit phase plus a 6-bit number rather than as a
     general string.
     The phase encoding is `00 = beta`, `01 = rc`, `10 = stable`, with the
     stable canonical form forcing `prereleaseNum = 0`. Because the phase
     values are monotone _and_ `prereleasePhase` sits just above
     `prereleaseNum` in the packed integer, single-integer comparison
     yields the correct SemVer §11 precedence:
     `2.111.0-beta.N < 2.111.0-rc.M < 2.111.0` for all N, M ≤ 63. The 2-bit
     field gives one reserved code (`11`) for future extension (e.g.
     `alpha`); the engine rejects it on parse.
     Bit budget: major fits up to 255, minor up to 1023, patch up to 63 —
     comfortably ahead of where DMD is realistically headed. Prerelease
     numbers up to 63 cover every DMD release in history.
     `DmdOptimized` does not use the LSB-`stableFlag` trick from the other
     layouts because the `(phase, num)` pair already encodes the
     "stable beats every prerelease" relation; an extra flag would be
     redundant.
- `prereleasePhase` is not a numeric `@Component` in the standard sense
  (it formats as `beta`/`rc`/`""`, not as digits). The layout supplies
  its own `toString` / `parse` hooks, which the engine picks up by
  introspection (DbI: optional members on `Layout` override the
  default Component-driven path). This is the same hook protocol
  layouts with exotic punctuation use; `DmdOptimized` is just the first
  layout to need it. The exact UDA / member-name protocol is left to
  the implementation phase.
- `TinyLayout` has no prerelease/build, so no `stableFlag` is needed —
  this is the "void-hook" case validating the DbI design.
- Sizes 1, 2, and 16 are not used today. We add the `GetCoreType` slots
  for 1, 2 prophylactically; we omit 16 (Cent) until a concrete consumer
  appears.

The total declared bit widths reach exactly the container size in each
layout. The engine asserts this.

## Phase 6 — Parser

The current parser is comprehensive (836 lines including tests) and uses
the `expected`-based non-throwing API. We keep that API shape and rewire
the storage:

1. **Add a `numericOverflow` path that respects the layout's bit widths.**
   Today the parser rejects numbers above `ulong.max`; for `SemVerLayout`
   it must reject anything that does not fit in 15/24/24 bits. The
   `SemVerParseErrorCode.numericOverflow` enumerator already exists; we
   just compute the bounds from the layout at compile time.
2. **Generalise to `Version!Layout.parse(string, SemVerParseMode)`.** The
   current `SemVer.parse` becomes the natural `Version!SemVerLayout.parse`
   instantiation.
3. **Honour each `@Component.printWidth` at parse time.** Components with
   `printWidth > 0` reject inputs that do not match the declared width
   (e.g. `DmdLayout` rejects `1.2.3` because minor/patch require 2
   digits) and accept zero-padded inputs that strict SemVer would
   normally reject for having leading zeroes. Components with
   `printWidth == 0` retain the strict SemVer leading-zero rule.
4. **Parse prerelease / build into `SsoString`** without touching the heap
   when the content fits in 23 bytes. Beyond 23 bytes we allocate a GC
   string (keeps POD).
5. **Loose mode** stays exactly as today: accept `v1.2.3`, `1`, `1.2`,
   etc. The engine fills missing fields with zero.

## Phase 7 — Migration

The public API moves from `sparkles.semver` to `sparkles.versions`. The
consumer-facing surface area is small and stays the same in shape:

- `import sparkles.versions : SemVer, SemVerParseMode;`
- `SemVer.parse(s, SemVerParseMode.loose).value`
- comparison and sorting of `SemVer` values

Plan:

1. Move source from `libs/semver/src/sparkles/semver/` to
   `libs/versions/src/sparkles/versions/`. Update the sub-package config
   (`libs/versions/dub.sdl`) to name `sparkles:versions`.
2. Bump the dub version to `0.3.0` to mark the breaking rename and the
   precision regression from `ulong` to 15/24/24 bits.
3. The old `sparkles:semver` sub-package is removed outright (no
   compatibility shim). Downstream callers update their `dependency` and
   their `import` lines in one step.

## Phase 8 — Tests and docs

- Every public function gets a `@(name) @safe pure nothrow @nogc` unit test
  (per `AGENTS.md`).
- Existing parser-error tests transplant unchanged.
- New tests exercise the DbI design:
  - `TinyLayout` (no flag, no SSO) — proves the void-hook path.
  - `DmdLayout` formats `1.2.3` as `1.02.03` and parses `1.02.03` back
    to itself, while `SemVerLayout` continues to reject `1.02.03` as a
    leading-zero error. Same bitfield shape, different format hooks.
  - `DmdOptimized` round-trips `2.111.0`, `2.111.0-beta.2`, and
    `2.111.0-rc.3`; correctly orders
    `2.111.0-beta.N < 2.111.0-rc.M < 2.111.0`; rejects free-form
    prereleases like `2.111.0-alpha.1` (reserved phase code); fits
    `Version!DmdOptimized.sizeof == 4`. Proves the
    custom-`toString`/`parse`-hook path.
  - A purpose-built `EvilLayout` with only one `@Component` — proves the
    engine accepts a degenerate layout.
- `README.md` gets one runnable example per layout (per `AGENTS.md`'s
  `nix run .#ci -- --verify` workflow).
- DDoc per `docs/guidelines/ddoc.md`; engine traits referenced via
  `$(LREF …)`.

## Open questions

- **Trait portability.** Spike confirmed `__traits(getBitfieldOffset)` is
  unavailable on DMD 2.110.0. The engine should compute offsets by
  summing widths itself; the trait is a "verification-only" cross-check
  on compilers that support it. Decision needed: do we bump the minimum
  DMD to a version that supports the trait, or keep the manual path?
- **Build-metadata UDA name.** Using `@InternalFlag` to mean "do not
  include in `opCmp`" risks overloading that UDA with two meanings (the
  LSB flag, and an SSO field excluded from ordering). Likely split into
  `@OrderingTiebreaker` (the LSB bit) and `@ExcludeFromOrdering` (the
  build-metadata SSO).
- **Whether to keep `Cent` support at all.** Currently dropped from the
  first cut. If we later want a 128-bit layout, we resurrect `GetCoreType
!16` and add a small `cmp128`/`mask128` helper. We do not block this
  plan on it.
- **Where the SSO definition lives.** Either in `sparkles.versions` (if
  no other module needs it) or in `sparkles.core_cli` (if it is generally
  useful). Defer until we see a second consumer.
