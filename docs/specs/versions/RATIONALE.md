# `sparkles:versions` — Rationale and History

_Audience: anyone wondering why the library is shaped the way it is.
This is the historical record — design motivation, compiler-spike
findings, decisions and the reasoning behind them, and open
questions. For the desired-state specification, read
[SPEC.md](./SPEC.md); for the delivery schedule, read
[PLAN.md](./PLAN.md)._

## 1. Why this redesign

The `sparkles:semver` 0.2 library, landed in commit `db7a2e6`, was a
comprehensive SemVer 2.0.0 implementation. It worked, but it was
single-purpose and overbuilt for its actual use cases:

- `ulong` storage for major/minor/patch — every real version fits in
  far less.
- Hardcoded to SemVer 2.0.0 — no path to support DMD's versioning
  conventions, PEP 440, CalVer, or compact internal layouts.
- Allocation-heavy parsing for prerelease and build metadata even
  when those fields fit easily in an inline buffer.

The driving need is **support for multiple versioning schemes from a
single engine**. The bit-packed core that falls out of the
Design-by-Introspection redesign is a derived efficiency, not the
primary motivator. We pursue DbI for its compositional and
extensibility properties (see
[`docs/guidelines/design-by-introspection-00-intro.md`](../../guidelines/design-by-introspection-00-intro.md));
the storage compaction is a welcome side-effect.

## 2. Compiler-spike findings

Four short spikes ran against **DMD `2.110.0`** and **LDC `1.41.0`**
(carrying roughly the DMD `2.111` frontend). The programs were not
checked in; the findings below shaped the design.

### 2.1 `std.bitmanip.bitfields` attribute profile

`std.bitmanip.bitfields` is fully `@safe pure nothrow @nogc` and
BetterC-compatible. Generated setters carry width-overflow contracts
but stay `nothrow` because the assert raises an `Error`
(which is permitted in `nothrow` context).

**Implication:** we use `std.bitmanip` as the backbone of the bit-
packed core. We do not need a custom UDA-based bitfield generator
(e.g. a `@Bits!N` scheme).

### 2.2 Built-in C-style bitfields

Built-in bitfields require `-preview=bitfields` on DMD `2.110`. Reading
them through a union of two overlapping fields raises a `@safe`
deprecation: _"cannot access overlapped field with unsafe bit patterns
in `@safe` code"_. Reinterpretation therefore requires a small
`@trusted` shim.

Built-in bitfields enable `__traits(isBitfield)` and (on LDC)
`__traits(getBitfieldOffset)` / `__traits(getBitfieldWidth)`.

### 2.3 `__traits(getBitfieldOffset/Width)` portability

| Compiler    | `__traits(isBitfield)` | `__traits(getBitfieldOffset)` |
| ----------- | ---------------------- | ----------------------------- |
| DMD `2.110` | ✅                     | ❌                            |
| LDC `1.41`  | ✅                     | ✅                            |

**Implication:** the engine cannot rely on
`__traits(getBitfieldOffset)`. It computes field offsets and widths
itself by summing declared widths, treating the trait as a
verification-only cross-check on compilers that support it.

### 2.4 Bit-allocation order is LSB-first

In both `std.bitmanip.bitfields` and built-in bitfields, the first
declared field occupies the **low** bits and the last declared field
occupies the **high** bits:

```d
mixin(bitfields!(
    bool,  "stableFlag", 1,    // bits [0..0]   (LSB)
    ulong, "patch",     24,    // bits [1..24]
    ulong, "minor",     24,    // bits [25..48]
    ulong, "major",     15,    // bits [49..63] (MSB)
));
```

Reinterpreting via `union { Layout core; ulong packed; }` gives
`(major << 49) | (minor << 25) | (patch << 1) | stableFlag`.

**Implication:** layouts declare components from **lowest-precedence
(LSB) to highest-precedence (MSB)**, so a direct unsigned compare of
the packed integer produces correct ordering.

## 3. The LSB-vs-MSB flag correction

The original plan placed the "has-no-prerelease" tiebreaker bit at
the **MSB** of the packed integer, on the assumption that an MSB flag
would give stable versions the strongest possible precedence.

The spike demonstrated this is **wrong** for SemVer §11.

A flag at the MSB makes every stable version compare greater than
every prerelease — regardless of major. SemVer 2.0.0 mandates
`2.0.0-alpha > 1.999.999` (major dominates everything). Empirically:

| Flag position | Test: `2.0.0-pre > 1.999.999 stable?` | Verdict |
| ------------- | ------------------------------------- | ------- |
| MSB           | `false`                               | wrong   |
| LSB           | `true`                                | correct |

The fix is to put the flag at the **LSB**, where it acts only as a
tiebreaker after major / minor / patch have been compared. Encoding:
`1` = stable (no prerelease), `0` = has prerelease, so
`1.0.0 > 1.0.0-alpha` falls out of integer compare.

This finding is the spike's most important deliverable. SPEC §5
states the rule positively; this section explains why the rule is
counter-intuitive (the surface-level argument "MSB = strongest
precedence" sounds reasonable; only the cross-version test exposes
the flaw).

## 4. Design decisions and justifications

### 4.1 Static `@Component.printWidth` instead of runtime width-tracker bits

An earlier draft of the design carried a `@WidthTracker` UDA that
attached extra bitfields recording the as-parsed width of each
numeric component. This allowed perfect round-tripping of inputs like
`1.02.3` → `1.02.3` even when the layout permitted unpadded inputs.

We dropped it for two reasons:

1. **Bit budget.** Width trackers consumed bits that the semantic
   components needed. The 64-bit budget couldn't accommodate both
   wide ranges (DMD's growing minor numbers) and per-instance widths.
2. **Semantic noise in `opCmp`.** Width-tracker bits stored in the
   packed core participated in integer comparison, making
   `1.02.3 != 1.2.3` numerically. The fix — a `SEMANTIC_MASK` that
   zeroed width-tracker bits before compare — added engine
   complexity for zero functional gain.

The replacement: width is a **static property of the layout** via
`@Component(printOrder, printWidth)`. `DmdLayout` declares
`printWidth: 3` on minor and **always** emits minor as at least 3
digits (padding `79` → `079`, leaving `111` unchanged) — see
[SPEC §7.2](./SPEC.md#72-dmdlayout). Per-instance width
preservation is not supported; no current consumer needs it.

### 4.2 `core.int128.Cent` dropped from the first release

The original plan included a 16-byte layout option using
`core.int128.Cent` for the packed core. This complicates the
generated code (`ult`/`ugt` are function calls rather than CPU
instructions), and no consumer needs the extra range.

We omit `GetCoreType!16` until a real use case appears.

### 4.3 Baseline plain GC `string` for prerelease/build, SSO as optional layer

The original plan mandated an `SsoString` (small-string-optimised)
struct for prerelease and build metadata. We demoted it to an
optional drop-in.

The trade-off:

- **SSO advantage:** elides the GC allocation for prereleases that
  fit in 23 bytes (the common case — `alpha`, `beta.1`, `rc.3` are
  all ≤ 7 bytes).
- **Plain `string` advantage:** trivially POD, no inline-vs-heap
  branching in every accessor, no need for a tag bit. Implementation
  is straightforward.

By specifying the engine to require only a minimal slot interface
(`length` plus indexed read), both options coexist. The library ships
with plain `string` first, then adds `SsoString` as a non-breaking
swap.

### 4.4 Rename to `sparkles:versions`; no compatibility shim

`version` is a D keyword, so we cannot reuse the singular module
name. We chose plural `versions` over alternatives like
`versioning` because:

- Plural matches `sparkles:tools-as-a-set` other sub-package naming.
- The dub sub-package name and the D module FQN line up
  (`sparkles:versions` ↔ `sparkles.versions`).

The old `sparkles:semver` sub-package is **removed outright** rather
than aliased. With a single in-repo consumer to update, a clean break
costs less than maintaining a compatibility shim indefinitely.

### 4.5 Power-of-two layout sizes only

`GetCoreType` maps only 1, 2, 4, and 8-byte layouts to native
unsigned integers (`ubyte`, `ushort`, `uint`, `ulong`). Odd or
non-power-of-two sizes (3, 5, 6, 7, 12) would require a synthetic
core type with custom compare / mask helpers.

We do not support such sizes. Layouts that need an intermediate range
pad to the next power of two; the unused tail bits sit at the LSB so
they remain semantically inert. (The engine's "total widths exactly
equal container size" assertion catches accidental tails.)

### 4.6 `DmdOptimized`: phase encoding, no LSB stableFlag

`DmdOptimized` exploits two facts about DMD's actual versioning:

- DMD releases carry no build metadata.
- DMD prereleases follow the constrained grammar `beta.N` or `rc.N`.

We encode the prerelease as a 2-bit `prereleasePhase`
(`00` = beta, `01` = rc, `10` = stable, `11` = reserved) plus a 6-bit
`prereleaseNum`. The phase values are monotone and sit just above
`prereleaseNum` in the packed integer, so a single unsigned compare
yields `beta.N < rc.M < stable` directly.

Crucially, the layout does **not** use an LSB `stableFlag` like the
other layouts. The `(phase, num)` pair already encodes the
stable-beats-every-prerelease relation; an additional flag would be
redundant and would also have to dominate the prerelease pair, which
is structurally awkward. The lesson: the LSB-flag pattern is the
right answer when the only tiebreaker is "has prerelease yes/no",
but layouts with richer prerelease structure can supply their own
ordering via a normal `@Component` instead.

The reserved phase code (`11`) gives the layout a forward-compatible
slot for adding `alpha` if DMD ever ships such a release.

### 4.7 No SemVer knowledge inside the engine (the `StringSlot` abstraction)

An earlier iteration of the engine used `static enum hasPrerelease =
true;` / `static enum hasBuild = true;` flags on the layout to opt
into named `prerelease` / `build` `string` fields on
`Version!Layout`. The engine read those flags directly and the parser
hardcoded `-` and `+` as the prerelease/build separators. This worked
for SemVer-style layouts but baked SemVer's data model into the DbI
engine — the very thing DbI is supposed to abstract over.

The shipped design replaces the flags with a generic abstraction:

- Each layout declares a `static immutable StringSlot[] stringSlots`
  list. Each `StringSlot` carries `(name, prefix, includeInOrdering,
validate, compare)` — function pointers for the last two.
- The engine generates one `string <name>;` field per slot on
  `Version!Layout` and walks the slot list in `opCmp`, `toString`,
  and the parser without knowing what any specific slot represents.
- SemVer-specific behaviour (the `-`/`+` separators, the identifier
  grammar from SemVer §9–§10, the prerelease comparison rule from
  SemVer §11.4) lives in `sparkles.versions.semver_rules`, behind two
  pre-built `StringSlot` constants — `semVerPrereleaseSlot` and
  `semVerBuildSlot` — that SemVer-style layouts (SemVerLayout,
  DmdLayout, CalVerYYMMLayout, …) reference in their `stringSlots`.

A hypothetical layout for, say, Debian's `1:1.2.3-4+deb12u1` can
declare entirely different slots (epoch prefix `:`, distribution
suffix, etc.) without engine changes; conversely, a layout that
needs no auxiliary text at all (TinyLayout, DmdOptimized) declares
no slots and pays no cost. The engine's contract with its layouts is
genuinely about the _mechanism_ of auxiliary string slots, not about
SemVer's specific use of them.

## 5. Open questions

These are unresolved and may inform later work; they do not block any
current milestone.

- **Trait portability strategy.** The engine computes bitfield
  offsets manually for portability across DMD `2.110` and LDC `1.41`. We
  could instead require a minimum DMD that supports
  `__traits(getBitfieldOffset)`, simplifying the engine. Decision
  deferred until we know which compilers `sparkles` officially
  supports.
- ~~**Final UDA names for the build-metadata semantics.**~~
  **Resolved.** The shipped design uses `@InternalFlag` for the LSB
  tiebreaker bit and a `StringSlot.includeInOrdering` boolean on each
  declared slot for the "this slot tiebreaks, that one doesn't"
  distinction (rather than two separate UDAs as originally
  speculated). SemVer prerelease is `includeInOrdering: true`; build
  metadata is `includeInOrdering: false`. See SPEC §3.
- **`Cent` resurrection.** Dropped from the first release per §4.2.
  If a 128-bit layout appears, reintroduce `GetCoreType!16` plus a
  small `cmp128` helper. Localised; not a structural change.
- **Where `SsoString` lives long-term.** Currently planned for
  `sparkles.versions`. If a second consumer (e.g. `sparkles.core_cli`)
  emerges, lift it into `core_cli`. Defer until the second consumer
  is real.
