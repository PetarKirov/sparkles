# `sparkles:versions` — Specification

_Audience: first-time readers and library consumers. This document is
self-contained — read it on its own to understand what the library
provides. See [PLAN.md](./PLAN.md) for the delivery schedule and
[RATIONALE.md](./RATIONALE.md) for design history and open questions._

## 1. Overview

`sparkles:versions` is a Design-by-Introspection (DbI) versioning
library for D. A single engine — the `Version(Layout)` template — is
parameterised by a **layout type** that names the version's
components, their bit widths, and their formatting. From a single
implementation, the library supports:

- strict Semantic Versioning 2.0.0,
- DMD-style versions with zero-padded minor/patch and constrained
  prerelease grammar,
- compact internal layouts for storage-sensitive use,
- and future schemes (PEP 440, CalVer, …) without engine changes.

Consumers who only need standard SemVer use the pre-built
`SemVer` alias and ignore the DbI machinery entirely. Layout authors
follow the protocol in §3–§5 to add new versioning schemes.

For the DbI paradigm itself, see
[`docs/guidelines/design-by-introspection-00-intro.md`](../../guidelines/design-by-introspection-00-intro.md).
The engine is a **shell with hooks**: the layout supplies optional UDAs
and optional members; the engine introspects to discover what each
layout offers and adapts accordingly.

## 2. Package and module layout

| Identifier              | Value                                  |
| ----------------------- | -------------------------------------- |
| Dub sub-package         | `sparkles:versions`                    |
| Source root             | `libs/versions/src/sparkles/versions/` |
| Primary module          | `sparkles.versions`                    |
| Engine template (D FQN) | `sparkles.versions.Version`            |
| Standard SemVer alias   | `sparkles.versions.SemVer`             |

Consumer imports:

```d
import sparkles.versions : SemVer, ParseMode;

auto v = SemVer.parse("1.2.3-rc.1", ParseMode.loose).value;
```

The folder uses the plural name `versions/` because `version` is a
D keyword.

## 3. DbI vocabulary

The engine exposes five names that form its contract with layout types.
The engine itself knows nothing about specific versioning schemes
(SemVer's prerelease/build conventions, identifier grammars, ordering
rules); those are layout-supplied via the vocabulary below.

### `Component(printOrder, printWidth = 0)`

UDA value attached to a layout's bit-packed component via the
`layoutBody` mixin (see below). Tags the member as a semantic component
that participates in the version's printed form and (by default) in
comparison.

- `printOrder` — formatting sequence; smaller values print first.
- `printWidth` — minimum number of digits emitted by `toString` and
  required by the parser. `0` means "no padding, no width constraint"
  and is the natural default. Width is a **static** property of the
  layout, not a per-instance value.

### `InternalFlag`

Marker UDA attached to a 1-bit layout member via the `layoutBody`
mixin. Participates in ordering but is not printed. Conventional use:
the "has-no-prerelease" tiebreaker. Must sit at the LSB of the packed
core (see §5).

### `StringSlot { name, prefix, includeInOrdering, validate, compare }`

Describes an auxiliary string slot a layout exposes alongside its
bit-packed core. The engine generates one `string <name>;` member on
`Version!Layout` per declared slot, and walks the slots generically in
`opCmp`, `toString`, and the parser. The engine has no built-in
knowledge of SemVer's `prerelease` or `build` slots — those are just
two slots SemVer-style layouts happen to declare.

- `name` — field name generated on `Version!Layout`.
- `prefix` — single character separating this slot from the preceding
  content in the canonical string form (e.g. `'-'` for SemVer
  prerelease, `'+'` for SemVer build).
- `includeInOrdering` — when `true`, `opCmp` tiebreaks on this slot
  after the packed-core compare ties.
- `validate` — optional `SlotValidator` function pointer; `null`
  accepts any non-empty content.
- `compare` — optional `SlotComparator` function pointer; `null` falls
  back to `std.algorithm.cmp` lexicographic compare.

`SlotValidator` and `SlotComparator` are function-pointer aliases:

```d
alias SlotValidator = ParseExpected!void function(
    in string segment, size_t segmentOffset) @safe pure nothrow @nogc;

alias SlotComparator = int function(
    in string lhs, in string rhs) @safe pure nothrow @nogc;
```

A layout declares its slots as a `static immutable StringSlot[]
stringSlots` member; the engine reads it on `Version!Layout`
instantiation.

### `layoutBody!(spec...)`

Mixin template that emits both the bit-packed storage (via
`std.bitmanip.bitfields`) and a `LayoutDescriptor` describing every
component, the optional internal flag, and the layout's total bit
width. The `spec` tuple groups its arguments in (UDA, type, name,
width) quadruples, declared from LSB to MSB:

```d
mixin layoutBody!(
    InternalFlag,             bool,  "stableFlag", 1,
    Component(printOrder: 2), ulong, "patch",     24,
    Component(printOrder: 1), ulong, "minor",     24,
    Component(printOrder: 0), ulong, "major",     15,
);
```

The UDA position accepts `Component(...)`, `InternalFlag`, or `void`
(padding).

### `GetCoreType!(size_t bytes)`

Compile-time map from a layout's byte size to the unsigned integer
used for packed reinterpretation:

| `Layout.sizeof` | `CoreType` |
| --------------- | ---------- |
| 1               | `ubyte`    |
| 2               | `ushort`   |
| 4               | `uint`     |
| 8               | `ulong`    |

Other sizes are not supported in the current library.

## 4. The `Version(Layout)` engine

```d
struct Version(Layout)
{
    alias CoreType = GetCoreType!(Layout.sizeof);
    enum LayoutDescriptor descriptor = /* derived from Layout */;

    union { Layout core; CoreType packed; }

    // One `string <slot.name>;` member generated per slot declared in
    // Layout.stringSlots (see §9).
    static foreach (slot; descriptor.stringSlots)
        mixin("string " ~ slot.name ~ ";");

    // operations from §6, composed by introspection over Layout
}
```

The `descriptor` is a `LayoutDescriptor` aggregating:

- `ComponentDesc[] components` — sorted by `printOrder`.
- `InternalFlagDesc internalFlag` — name and offset of the LSB
  tiebreaker bit, or `name == ""` if the layout has none.
- `int totalBitWidth` — sum of declared bitfield widths.
- `immutable(StringSlot)[] stringSlots` — auxiliary slots from the
  layout's `stringSlots` static member.

At instantiation the engine performs CTFE validation on `Layout`:

1. `Layout.sizeof` is one of {1, 2, 4, 8}.
2. Every bitfield member is generated by the `layoutBody` mixin (which
   uses `std.bitmanip.bitfields` underneath).
3. Every `@Component.printOrder` is unique.
4. At most one `@InternalFlag` member, of width 1, at bit offset 0
   (LSB).
5. Total declared bit width ≤ `sizeof(CoreType) * 8`.

A layout that declares only a single `@Component`, with default
`printWidth` and no `@InternalFlag` or string slots, is a valid input.
It produces a `Version` that compares as a single integer and prints
as a single number — the DbI "void-hook" baseline.

## 5. Bit-allocation contract

Layout fields map to the packed integer **LSB-first in declaration
order**. The first declared field occupies the lowest bits; the last
declared field occupies the highest bits.

A layout therefore lists its components from **lowest-precedence (LSB)
to highest-precedence (MSB)**. For SemVer:

```d
import sparkles.versions;
import sparkles.versions.semver_rules : semVerBuildSlot,
    semVerPrereleaseSlot;

struct SemVerLayout
{
    mixin layoutBody!(
        InternalFlag,             bool,  "stableFlag", 1, // LSB
        Component(printOrder: 2), ulong, "patch",     24,
        Component(printOrder: 1), ulong, "minor",     24,
        Component(printOrder: 0), ulong, "major",     15, // MSB
    );

    static immutable StringSlot[] stringSlots = [
        semVerPrereleaseSlot,  // {name:"prerelease", prefix:'-', …}
        semVerBuildSlot,       // {name:"build",      prefix:'+', …}
    ];
}
```

Reinterpreting via the `union { Layout core; ulong packed; }` overlay
yields `(major << 49) | (minor << 25) | (patch << 1) | stableFlag`.
Single-integer unsigned comparison of `packed` produces SemVer §11
precedence directly.

The `@InternalFlag` lives at the **LSB**, not the MSB. A bit at the
MSB would dominate `major` and make every stable version compare
greater than every prerelease — violating
`2.0.0-alpha > 1.999.999`. The LSB position makes the flag a
tiebreaker that only matters when the printed components are equal.
Encoding: `1` = stable (no prerelease), `0` = has prerelease, so
`1.0.0 > 1.0.0-alpha` falls out of integer compare.

## 6. Operations

### 6.1 `opCmp`

Two-stage compare:

1. Compare `lhs.packed` against `rhs.packed` as a single unsigned
   integer. Every bit in the packed core is semantically meaningful —
   no masking step.
2. If the integers tie, walk each `StringSlot` declared by the layout
   in declared order. For each slot with `includeInOrdering == true`,
   call its `compare` function (or fall back to lexicographic compare
   when `compare == null`). The first non-zero result wins. Slots with
   `includeInOrdering == false` (e.g. SemVer build metadata) are never
   consulted.

For `CoreType.sizeof <= 8` stage 1 is a single CPU compare.

### 6.2 `toString`

CTFE-driven from the layout:

1. Collect every `@Component` member, sorted by `printOrder`.
2. For each, format with `"%0*d"` and the component's static
   `printWidth` when `printWidth > 0`, else `"%d"`.
3. Emit each `StringSlot` whose value is non-empty, prefixed by its
   `prefix` character (e.g. SemVer prerelease prepends `-`, build
   prepends `+`). The prefix is a property of the slot, not hardcoded
   in the engine.
4. If the layout supplies its own `customToString(Writer)(ref Writer w)
const` member, the engine defers to it. This is how layouts with
   non-numeric components (e.g. `DmdOptimized`'s `prereleasePhase`)
   produce their textual form.

`toString` writes into an output range, following the
`sparkles.core_cli` conventions in
[`AGENTS.md`](../../../AGENTS.md#output-ranges).

### 6.3 `truncateTo!"name"()`

CTFE function returning a new `Version` of the same type with every
bit below the named component zeroed. Useful for grouping
(`v.truncateTo!"minor"` to bucket by `major.minor`).

## 7. Concrete layouts

The library ships four layouts. All have power-of-two byte sizes so
they fit `GetCoreType` cleanly.

| Layout         | Size | Bitfields (LSB → MSB)                                            | Component widths (major / minor / patch) | String slots          |
| -------------- | ---- | ---------------------------------------------------------------- | ---------------------------------------- | --------------------- |
| `SemVerLayout` | 8 B  | `stableFlag:1, patch:24, minor:24, major:15`                     | unpadded / unpadded / unpadded           | `prerelease`, `build` |
| `DmdLayout`    | 8 B  | `stableFlag:1, patch:24, minor:24, major:15`                     | unpadded / **3-digit** / unpadded        | `prerelease`, `build` |
| `DmdOptimized` | 4 B  | `prereleaseNum:6, prereleasePhase:2, patch:6, minor:10, major:8` | unpadded / **3-digit** / unpadded        | **none**              |
| `TinyLayout`   | 4 B  | `patch:8, minor:8, major:16`                                     | unpadded / unpadded / unpadded           | none                  |

The total declared bit widths reach exactly the container size in
each layout; the engine asserts this.

### 7.1 `SemVerLayout`

Strict Semantic Versioning 2.0.0. Major fits up to 32767; minor and
patch each up to 16,777,215. Prerelease and build metadata stored as
string slots (§9). Comparison follows SemVer §11.

### 7.2 `DmdLayout`

Same bitfield shape as `SemVerLayout`, but the `minor` component
carries `printWidth = 3`. `toString` emits minor as at least 3
digits, padding with leading zeroes when needed; major and patch are
unpadded. The parser requires minor to be at least 3 digits.

This matches real DMD / Dlang versioning across eras: minor=79 from
the `2.079.0` era prints `079` (padded), minor=111 from the current
`2.111.0` era prints `111` (no padding needed because it is already
3 digits), and minor=999 prints `999`. Minor values ≥ 1000 are
emitted at their natural width (e.g. `1234`), which is forward-
compatible should DMD ever overflow 3 digits.

`SemVerLayout` and `DmdLayout` share storage and differ only in
static format hooks. This is the DbI design's headline
demonstration: same bits, different behaviour via UDAs.

Zero-padded round-tripping is a **layout-level** property, not
per-instance. `DmdLayout` cannot round-trip `2.79.0` back to
`2.79.0` — it always emits `2.079.0`.

### 7.3 `DmdOptimized`

A 4-byte layout that exploits two facts about DMD's actual versioning
to fit a fully ordered, fully formatted version into 32 bits with
**zero string allocations**:

1. DMD releases carry no build metadata; the `build` slot is omitted.
2. DMD prereleases follow the constrained grammar `beta.N` or `rc.N`
   (e.g. `2.111.0-beta.2`, `2.111.0-rc.3`), so the prerelease is
   encoded as a 2-bit phase plus a 6-bit number rather than a general
   string.

Phase encoding (the values must be monotone for ordering to work):

| `prereleasePhase` | Meaning  | Canonical `prereleaseNum` |
| ----------------- | -------- | ------------------------- |
| `00`              | beta     | 1–63                      |
| `01`              | rc       | 1–63                      |
| `10`              | stable   | 0                         |
| `11`              | reserved | parser rejects            |

Because `prereleasePhase` sits just above `prereleaseNum` in the
packed integer, single-integer comparison yields
`2.111.0-beta.N < 2.111.0-rc.M < 2.111.0` for all N, M ≤ 63.

Bit budget: major ≤ 255, minor ≤ 1023, patch ≤ 63 — comfortably ahead
of where DMD is realistically headed; prerelease numbers up to 63
cover every DMD release in history.

`DmdOptimized` does **not** use an LSB `stableFlag` because the
`(phase, num)` pair already encodes the stable-beats-every-prerelease
relation. `prereleasePhase` is also not a numeric `@Component` (it
formats as `beta`/`rc`/`""`, not digits), so the layout supplies its
own `toString` / `parse` hooks per §6.2 / §8.

### 7.4 `TinyLayout`

A 4-byte layout with neither prerelease nor build metadata, and no
`stableFlag`. Major ≤ 65535, minor ≤ 255, patch ≤ 255. Useful for
storage-sensitive internal use. Validates the DbI "void-hook"
baseline (§4).

### 7.5 Real-world preset layouts

The four layouts above prove the engine's design. A companion module,
`sparkles.versions.presets`, ships additional layouts mapped to
versioning schemes used by widely-deployed software, with unit tests
that parse real example strings (Node.js `20.13.1`, Ubuntu `24.04.1`,
Vim `9.1.0400`, …) and exercise the engine's operations end-to-end.
The presets all share the SemVer bitfield shape and differ only via
static `@Component.printWidth` hooks — they are direct evidence that
the DbI design scales to real-world schemes without engine changes.

| Layout                 | Widths (major/minor/patch)    | Representative example  |
| ---------------------- | ----------------------------- | ----------------------- |
| `CalVerYYMMLayout`     | unpadded / 2-digit / unpadded | Ubuntu `24.04.1`        |
| `CalVerYYYYMMDDLayout` | unpadded / 2-digit / 2-digit  | Arch Linux `2024.05.01` |
| `VimLayout`            | unpadded / unpadded / 4-digit | Vim `9.1.0400`          |

Most strict-SemVer products (Rust, Kubernetes, Linux Kernel, Git,
PHP, etc.) parse with `SemVerLayout` directly; 2-part versions like
PostgreSQL `16.3` use `SemVerLayout.parse(s, ParseMode.loose)`;
the historical Dlang scheme (`2.079.0`) is covered by `DmdLayout`.

The full per-product coverage table, parse mode per entry, and the
provenance record (each example fact-checked against project
releases / git tags / official changelogs) live in
[PRESETS.md](./PRESETS.md).

## 8. Parser

`parse!Layout(string, ParseMode)` (from `sparkles.versions.parser`)
returns a non-throwing `Expected`-based result. Errors carry a
structured `ParseError { ParseErrorCode code; size_t index; }`.

The parser is generic over the layout:

1. Numeric components reject values that do not fit in their declared
   bit width via `ParseErrorCode.numericOverflow`. Bounds are computed
   from the layout's `descriptor.components[i].bitWidth` at compile
   time.
2. Each `@Component.printWidth` is enforced at parse time. Components
   with `printWidth > 0` require inputs of at least that width
   (e.g. `DmdLayout` rejects `2.79.0` because minor must be at least 3
   digits) and accept zero-padded inputs that strict SemVer's leading-
   zero rule would normally reject. Components with `printWidth == 0`
   keep the strict SemVer rule.
3. After parsing numeric components, the parser walks the layout's
   `StringSlot` declarations in declared order. Each slot is
   recognised by its `prefix` character; its content is read up to
   the prefix of a later-declared slot (or end of input) and passed
   to the slot's `validate` function (or, if `null`, validated only
   for non-emptiness). Slots whose `includeInOrdering` is true also
   clear the layout's `@InternalFlag` bit when populated, encoding
   "this is no longer a stable release".
4. **Strict mode** follows the layout's canonical syntax exactly.
5. **Loose mode** additionally accepts `v1.2.3`, `1`, `1.2`, etc. The
   engine fills missing fields with zero.
6. Layouts that supply a `parse(string, …)` member override the
   generic path entirely. `DmdOptimized` uses this hook to map
   `beta` / `rc` to its `prereleasePhase` field.

Typical call shape:

```d
import sparkles.versions : parse, SemVerLayout, ParseMode;

auto parsed = parse!SemVerLayout(s, ParseMode.loose);
if (parsed.hasError)
    handle(parsed.error);
else
    use(parsed.value);
```

## 9. String slots and the (deferred) SSO optimisation

Auxiliary string data (SemVer's prerelease and build metadata,
distribution suffixes, etc.) lives in fields generated on
`Version!Layout` from the layout's declared `StringSlot` list (§3).

For SemVer-style layouts the library ships pre-built slot constants:

```d
import sparkles.versions.semver_rules :
    semVerPrereleaseSlot, semVerBuildSlot;

struct SemVerLayout
{
    mixin layoutBody!(/* … bit-packed core … */);

    static immutable StringSlot[] stringSlots = [
        semVerPrereleaseSlot,  // -prefix, ordering, SemVer §9/§11 rules
        semVerBuildSlot,       // +prefix, no ordering, SemVer §10 rules
    ];
}
```

SemVer 2.0.0's asymmetric precedence (`prerelease` participates in
ordering, `build` does not) is encoded by each slot's
`includeInOrdering` boolean. SemVer's identifier grammar and §11.4
comparison rules are encoded by the slot's `validate` and `compare`
function pointers — defined in `sparkles.versions.semver_rules`, not
in the engine.

**Storage** — slot fields are plain GC `string`s. A future,
deliberately deferred optimisation will introduce an `SsoString` type
(23-byte inline `char[23]` + length, falling back to a GC `string`
slice past 23 bytes) and let the engine accept either as the slot
storage type. The engine already requires of slot values only that
they expose `length` and indexed read, so the swap will be local to
the field types and need no API change. The motivation is to elide
the GC allocation for the common short content (`alpha`, `beta.1`,
`rc.3` all ≤ 7 bytes); the cost is the inline-vs-heap tag bit.
Tracked as the final milestone in [PLAN.md](./PLAN.md).

## 10. Public API surface

Consumers reach the library via a single import:

```d
import sparkles.versions :
    SemVer,           // alias for Version!SemVerLayout
    parse,            // parse!Layout(string, ParseMode) → ParseResult
    ParseMode,        // strict | loose
    ParseError,       // { code, index }
    ParseErrorCode,   // emptyInput, unexpectedCharacter, …
    ParseResult;      // ParseExpected!(Version!Layout)
```

Layout-authoring consumers additionally import:

```d
import sparkles.versions :
    Version,          // the generic engine template
    Component,        // UDA value attached via layoutBody
    InternalFlag,     // marker UDA attached via layoutBody
    GetCoreType,      // size → unsigned-int selector
    LayoutDescriptor, // descriptor type
    StringSlot,       // auxiliary-slot descriptor
    SlotValidator,    // function-pointer alias
    SlotComparator,   // function-pointer alias
    layoutBody;       // mixin template
```

SemVer-style layout authors typically also pull the pre-built slot
constants:

```d
import sparkles.versions :
    semVerPrereleaseSlot,
    semVerBuildSlot;
```

The `Version!OtherLayout` instantiation produces all the names above
(parametrically). `SemVer` is just the most common instantiation.

---

→ [PLAN.md](./PLAN.md) — delivery milestones
→ [RATIONALE.md](./RATIONALE.md) — design history, decisions, open questions
