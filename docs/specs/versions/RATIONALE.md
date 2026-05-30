# `sparkles:versions` — Rationale and History

_Audience: anyone wondering why the library is shaped the way it is.
This is the historical record — the design arc, the prior-art evidence
base, compiler-spike findings, the decisions and the reasoning behind
them, and open questions. For the desired-state specification, read
[SPEC.md](./SPEC.md); for the delivery schedule, read
[PLAN.md](./PLAN.md); for the per-scheme catalogue, read
[PRESETS.md](./PRESETS.md)._

## 1. Why this redesign

The library passed through three shapes. Understanding why it abandoned
the first two is the fastest way to understand the third.

### 1.1 The arc

**Shape one — `sparkles:semver` (single-purpose).** The original
`sparkles:semver` library was a comprehensive, correct SemVer 2.0.0
implementation. It worked, but it was single-purpose and overbuilt for
its actual use cases:

- `ulong` storage for major/minor/patch — every real version fits in
  far less.
- Hardcoded to SemVer 2.0.0 — no path to DMD's versioning conventions,
  PEP 440, CalVer, or compact internal layouts.
- Allocation-heavy parsing for prerelease and build metadata even when
  those fields fit easily in an inline buffer.

The driving need was **support for multiple versioning schemes**, which
SemVer-only code could not give us.

**Shape two — a Design-by-Introspection _engine_ (now deleted).** The
response was a `Version!Layout` template parameterised on a `Layout`
struct that used a `layoutBody!(spec...)` mixin to declare bit-packed
components, plus `@Component` / `@InternalFlag` / `@StringSlot` UDAs and
a `LayoutDescriptor`. A generic descriptor-walking parser, `opCmp`, and
`toString` were composed by introspecting the layout. It worked, and
it shipped — but roughly 1500 lines of meta-programming surrounded a
contract that, the prior art shows, is **trivial**.

**Shape three — concept-flavour DbI (shipped).** Hand-written
per-ecosystem version **structs**, one per package-URL (`purl`) `type`,
each conforming to a small compile-time **concept** — the
`isInputRange`-style flavour of Design by Introspection rather than the
shell-with-hooks flavour. The required concept is
[`isVersion!T`](./SPEC.md#31-required-surface--isversiont) (just `opCmp`

- `toString`). Orthogonal **optional** capability traits
  (`hasOrderKey`, `supportsPrerelease`, `hasComponents`,
  `hasBuildMetadata`) layer fast paths and extra features on top. Generic
  algorithms — [`Ranges!V`](./SPEC.md#42-the-concrete-type--rangesv), `satisfies`, `sort` —
  are fallback/fast-path shells over those capabilities. Bit-packing
  survives **only** as the optional `hasOrderKey` primitive, never as a
  mandatory substrate.

### 1.2 Why the engine over-built

The engine generated a _Version type_ from a _Layout_. But the prior
art (§2) is unanimous that the abstract `Version` contract is tiny:
**an ordered type that renders to text** — Rust pubgrub requires only
`Ord + Display`; Maven Aether requires only `Comparable<Version> +
toString`; univers's base class adds only normalisation around a
comparable inner value. A version-_generating_ engine over-shoots that
contract by a wide margin: it invents storage, formatting, and parsing
machinery for a relationship that the consumer could express directly
in twenty lines of a plain struct.

What the engine got _right_ was the observation that versioning has a
high, orthogonal capability vocabulary — packed ordering keys, optional
prerelease semantics, numeric component accessors, build metadata. That
is the genuine DbI surface. But the vocabulary belongs in **concepts
plus generic algorithms**, where each capability is independently
detectable and individually opt-in, not bound into a mixin engine that
forces every scheme through one bit-packing substrate. The engine
coupled "express an ordering" to "lay out bits"; the redesign
decouples them. Bit-packing is now one scheme's private implementation
choice (exposed, if it wants, through `hasOrderKey`), not the shared
foundation every scheme must inherit.

The user's request was verbatim: _"hand-written structs for each
package ecosystem 'type' (type as in the package-url), conforming to a
static interface (DbI style `isVersion!T`)"_ plus _"plan to
interoperate with pURL and VERS"_. The redesign follows it literally.

## 2. Prior-art survey

The redesign rests on a survey of how thirteen production libraries
model versions, plus three deeper reads of the abstraction strategies
that most directly inform our trait design.

### 2.1 The ADT survey — the consensus core

Surveyed: node-semver, Rust `semver`, Python `packaging` (PEP 440), Go
`golang.org/x/mod/semver` + Masterminds `semver`, Maven, RubyGems,
Composer, NuGet, Haskell `base` `Version` + Cabal, Elixir `Version`,
and the prior D `sparkles:semver`. The capabilities present in
essentially **all** of them:

- parse a canonical string into a typed value;
- render a canonical `toString`;
- a **total order** (`< <= == >= >` plus a 3-way compare);
- equality plus a hash;
- component accessors (major / minor / patch or the scheme's analog);
- a **separate** Range / Requirement type with `satisfies` / `matches`;
- range operators `= < <= > >=` plus AND-composition;
- prerelease excluded from ranges by default, with explicit opt-in;
- a `sort`.

Rarer nice-to-haves, present in a minority:

- `inc` / `bump` (only node-semver, Masterminds, RubyGems — 3 of 13);
- `maxSatisfying`;
- range set-operations — **intersection is common** (Maven, PEP 440,
  node-semver, Composer, Cabal); **union is rare** (Composer, Cabal);
- `diff(a, b) -> component`;
- caret `^` / tilde `~` shorthands.

The consensus core maps almost exactly onto `isVersion!T` (order +
`toString`) plus the separate `Ranges!V` type with `contains` /
`satisfies`. The rare features are deliberately deferred (§5).

### 2.2 Three abstraction traditions

Three libraries answer the question _"what is the abstract version
interface?"_ in three instructively different ways.

**pubgrub (Rust) — abstract over the _set_, not the _value_.** pubgrub
v0.3 **deleted its `Version` trait entirely**
(`/home/petar/code/repos/pubgrub/CHANGELOG.md`: _"A `Version` can be
almost any ordered type now, it only needs to support set operations
through `VersionSet`"_). The replacement, `VersionSet`
(`src/version_set.rs:29-80`), requires only `empty`, `singleton`,
`complement`, `intersection`, `contains`; `full`, `union`,
`is_disjoint`, `subset_of` are **defaulted via De Morgan**. The value
type behind a set is constrained to nothing more than
`Debug + Display + Clone + Ord`. Critically, the removed `Version`
trait had carried `lowest()` and `bump()`, and these were dropped as
**harmful** — they assume a discrete successor that does not exist for
many real schemes (what is the version "after" `1.0.0-alpha`?). Their
concrete `Ranges<V>` (`version-ranges/src/lib.rs`) is a sorted,
disjoint `SmallVec` of intervals.

> **Lesson:** abstract over the set, keep the value contract to
> ordering + display, and never bake in a successor/`bump`. We port
> `VersionSet` verbatim as
> [`isVersionRange!R`](./SPEC.md#41-required-surface--isversionranger)
> and copy the sorted-disjoint-interval shape into
> [`Ranges!V`](./SPEC.md#42-the-concrete-type--rangesv).

**Maven Aether (Java) — the scheme is a separate factory.** Aether's
`VersionScheme` SPI exposes `parseVersion` / `parseVersionRange` /
`parseVersionConstraint` — it is a **factory**, separate from the
`Version` value, which is merely `Comparable<Version> + toString`.
Aether models three nouns: `Version` / `VersionRange` (a single
interval) / `VersionConstraint` (a union, plus a soft requirement). The
older Maven `ArtifactVersion` had leaked `getMajor` / `getMinor` /
`getQualifier` through its abstract interface — an **anti-pattern**
Aether deliberately walked back, because component accessors are not
universal across schemes.

> **Lesson:** keep component accessors _off_ the required interface
> (they become our optional `hasComponents`), and separate parsing
> (factory) from the value. We adopt the factory idea as
> [`isVersionScheme!S`](./SPEC.md#61-required-surface--isversionschemes),
> but collapse Aether's `Version` and `VersionScheme` nouns into one D
> struct (§5.2), since a D struct can carry both instance methods and
> static factory methods.

**univers (Python) — per-ecosystem subclasses, no cross-scheme order.**
univers ships one `Version` subclass per ecosystem (`PypiVersion`,
`NpmVersion`, `DebianVersion`, `MavenVersion`, `RpmVersion`,
`ArchLinuxVersion`, …). Cross-scheme comparison is **forbidden**: every
`__lt__` / `__eq__` guards `if not isinstance(other, self.__class__):
return NotImplemented` (`src/univers/versions.py:332-354`). A
`RANGE_CLASS_BY_SCHEMES` registry (`src/univers/version_range.py:1434`)
keyed by purl `type` dispatches `vers:<scheme>/<constraints>` parsing,
and a small non-identity map (`PURL_TYPE_BY_GITLAB_SCHEME`, line 1464 —
e.g. `packagist` → `composer`) handles the cases where the purl type
and the scheme name diverge. univers implements the `vers:` URI
round-trip with ASCII, lowercase, sort-and-dedupe normalisation.

> **Lesson:** per-ecosystem types are the right unit, cross-scheme
> comparison must be impossible, and the purl type is the dispatch key.
> We get all three for free from D's nominal typing: there is simply no
> `opCmp(SemVer, PypiVersion)`, so cross-scheme comparison **does not
> compile** (a compile-time analog of univers's runtime
> `NotImplemented`). We copy the registry shape, the non-identity map
> ([`schemeForPurlType`](./SPEC.md#10-purl-interop)), and the
> `vers:` normalisation rules.

### 2.3 The cautionary tale — Repology `libversion`

Repology's `libversion` (C) is the one notable precedent for a
**single universal comparator across all schemes**. It is explicitly
best-effort and is silently wrong on Debian epochs, PEP 440 local
versions, and Maven qualifier ordering — exactly the schemes where
ecosystem semantics diverge most. This is the evidence base for our
refusal to provide a universal cross-scheme total order:
[`compareAny`](./SPEC.md#11-anyversion--anyrange) returns
`Nullable!int`, `null` whenever the two operands belong to different
schemes (§5.3). The same stance is held by univers and by the `vers`
specification.

### 2.4 The interchange formats

The [`vers`](https://github.com/package-url/vers-spec) and
[`purl`](https://github.com/package-url/purl-spec) specifications are
the emerging cross-ecosystem interchange standards. We adopt `vers:` as
the canonical range **wire format** and the purl `type` as the **scheme
key**, which is what lets a purl-driven workflow (SBOM ingestion, OSV
vulnerability matching) dispatch to the correct typed scheme without a
hand-maintained switch.

## 3. How the DbI guideline shaped the design

The [Design by Introspection guidelines](../../guidelines/design-by-introspection-01-guidelines.md)
admit two flavours. The redesign deliberately chose the second.

### 3.1 Concept flavour, not shell-with-hooks

The guideline's headline mental model (§1.1) is the
**shell-with-hooks** pattern: a wrapper type handles boilerplate and a
hook type customises behaviour through `static if`-discovered intercept
points (`std.checkedint`, `std.experimental.allocator`). The deleted
engine _was_ that pattern — `Version!Layout` was the shell, the
`Layout` struct was the hook.

The shipped design uses the other flavour the guideline endorses
(§13, reference row "`std.range` / Phobos ranges"): **orthogonal trait
predicates over named concepts**, the `isInputRange!R` idiom. The
version structs are concrete and self-contained; the _generic
algorithms over them_ are the shells, and the optional capability
traits are the hooks they introspect. This fits versioning better
because the entities we abstract over (a `SemVer`, a `PypiVersion`) are
domain values, not policy objects — they should be plain structs a
reader can understand in isolation, not parameterised shells.

### 3.2 The required/optional primitive split

The guideline's core rules (§4.1, §4.2) mandate a **minimal required
set** that is "semantically clear, hard to regret, and cheap to
implement," plus **truly optional** primitives whose absence "MUST NOT
break correctness." Our split:

- **Required** ([`isVersion!T`](./SPEC.md#31-required-surface--isversiont)):
  `opCmp` and `toString`. Two members, both trivial, both matching the
  cross-library consensus (§2.1). Adding a third would be a breaking
  change (guideline §10.2), so the bar is held deliberately high.
- **Optional** (the capability vocabulary): `hasOrderKey`,
  `supportsPrerelease`, `hasComponents`, `hasBuildMetadata`,
  `supportsNativeRange`, `supportsLooseParse`. Each is individually
  detectable, orthogonal, and documented with its capability name,
  detection rule, and behavioural impact, per guideline §4.2.

Detection is **centralised** in `sparkles.versions.traits` (guideline
§4.3: "Capability detection MUST be centralized into named traits …
Code MUST NOT scatter ad-hoc `__traits(compiles, …)` checks"). The
generic algorithms `static if` on a named trait, never on an inline
expression. `isVersion!T` follows the named-sub-check style of
guideline Appendix A.6 so a conformance failure reports _which_ half
broke (`hasOpCmp` vs `hasToString`).

### 3.3 Bit-packing demoted to the optional `hasOrderKey` primitive

In the engine, bit-packing was the **mandatory substrate**: every
scheme's ordering _was_ an unsigned compare of a packed integer. The
guideline's fallback/fast-path discipline (§6) inverts this. The
**reference behaviour** (guideline §6.1: "The fallback MUST be the
semantic reference implementation") is a hand-written, field-by-field
`opCmp`. The **fast path** (guideline §6.2) is the packed-integer
compare, exposed through the optional
[`hasOrderKey!T`](./SPEC.md#32-optional-capability-vocabulary)
primitive:

```d
/// Monotonic unsigned-integer key of any width (ubyte … ulong). Where
/// present, sign(a.orderKey <=> b.orderKey) == sign(a <=> b) whenever
/// the keys differ; equal keys fall through to opCmp.
enum hasOrderKey(T) = isUnsigned!(typeof(T.init.orderKey));
```

The key type is **not fixed to `ulong`** — a scheme returns the
narrowest unsigned type that holds its packed components, and generic
code reads the width back through `OrderKeyType!T`. A 4-byte scheme
(`Tiny`, `DmdCompact`) exposes a `uint` key; full SemVer needs a
`ulong`. This is what lets `Ranges!T` store its interval bounds in the
scheme's own narrow key type rather than always paying 8 bytes, and lets
a radix `sort` run fewer passes — the "more optimizations" the variable
width buys. Using `std.traits.isUnsigned` (rather than
`is(... : ulong)`) keeps `bool` and the character types — which would
implicitly convert to `ulong` — from accidentally qualifying.

This satisfies guideline §6.2 exactly: the fast path **MUST** be
behaviourally equivalent to the fallback and **MUST** be
equivalence-tested against it (guideline §9.2). A scheme that exposes
`orderKey` must prove `sign(a.orderKey <=> b.orderKey) == sign(a.opCmp(b))`
across representative inputs before the primitive is accepted — and a
scheme whose ordering does not pack monotonically into **any** unsigned
integer (Debian, PEP 440 with local versions) simply **omits**
`orderKey`, per guideline §6.2's "Types MUST NOT implement an optional
primitive that only works sometimes." The generic `sort` then falls back
to comparison sorting instead of a radix sort. Nothing is wrong; a fast
path is merely unavailable.

### 3.4 The mandated `void`-hook baseline — the Generic scheme

The guideline makes the `void`-hook baseline test **mandatory** for any
new DbI component (§7.3, §9.4: "`Widget!(T, void)` SHOULD compile and
behave as the baseline with no hook involvement"). For a concept-flavour
design, the analog of the `void` hook is a scheme that provides the
**required concept and nothing else** — zero optional capabilities.
That is the mandated
[`Generic`](./SPEC.md#8-shipped-schemes) scheme (a.k.a.
`Lexicographic`): an opaque string-compared version. It has no
`orderKey`, no `isPrerelease`, no `major`/`minor`/`patch`, no `build`.
Every generic algorithm must exercise its **fallback** path against
`Generic`, which is precisely the smoke test the guideline prescribes.

## 4. How SemVer-shaped schemes implement `orderKey` internally

The `orderKey` fast path (§3.3) is, for SemVer-shaped schemes, a
bit-packed unsigned integer — a `ulong` for full SemVer, a `uint` for
the 4-byte compact schemes (`Tiny`, `DmdCompact`). The mechanics below
were established by four short
compiler spikes against **DMD `2.110.0`** and **LDC `1.41.0`** (roughly
the DMD `2.111` frontend). The programs were not checked in; the
findings shaped the internal `orderKey` implementations. These are
**implementation notes for scheme authors**, not part of the abstract
contract — a scheme is free to compute `orderKey` any way it likes, or
to omit it.

### 4.1 `std.bitmanip.bitfields` attribute profile

`std.bitmanip.bitfields` is fully `@safe pure nothrow @nogc` and
BetterC-compatible. Generated setters carry width-overflow contracts
but stay `nothrow` because the assert raises an `Error` (permitted in a
`nothrow` context).

**Implication:** SemVer-shaped schemes can compute `orderKey` with
`std.bitmanip` and keep the whole struct `@safe pure nothrow @nogc`. No
custom `@Bits!N` generator is needed.

### 4.2 Bit-allocation order is LSB-first

In both `std.bitmanip.bitfields` and built-in C-style bitfields, the
first declared field occupies the **low** bits and the last declared
field occupies the **high** bits:

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

**Implication:** an `orderKey` builder packs components from
**lowest-precedence (LSB) to highest-precedence (MSB)**, so a direct
unsigned compare of the key produces correct ordering. (Built-in
bitfields require `-preview=bitfields` and, when reinterpreted through a
union in `@safe` code, a small `@trusted` shim — so `std.bitmanip` is
the more portable choice. `__traits(getBitfieldOffset)` is available on
LDC `1.41` but not DMD `2.110`, so an `orderKey` builder must not
depend on it.)

### 4.3 The LSB-vs-MSB stable-flag correction

This is the spike's most important deliverable, and it remains the key
correctness insight for any packed `orderKey` of a SemVer-shaped scheme.

A plausible-but-wrong instinct places the "has-no-prerelease"
tiebreaker bit at the **MSB**, reasoning that an MSB flag gives stable
versions the strongest precedence. That is **wrong** for SemVer §11. An
MSB flag makes every stable version compare greater than every
prerelease — regardless of major — but SemVer mandates
`2.0.0-alpha > 1.999.999` (major dominates everything):

| Flag position | Test: `2.0.0-pre > 1.999.999 stable?` | Verdict |
| ------------- | ------------------------------------- | ------- |
| MSB           | `false`                               | wrong   |
| LSB           | `true`                                | correct |

The flag belongs at the **LSB**, where it acts only as a tiebreaker
after major / minor / patch have been compared. Encoding: `1` = stable
(no prerelease), `0` = has prerelease, so `1.0.0 > 1.0.0-alpha` falls
out of the integer compare. The surface argument ("MSB = strongest
precedence") sounds reasonable; only the cross-version test exposes the
flaw. SemVer's own §11 prerelease comparison (the
identifier-by-identifier rule for `1.0.0-alpha < 1.0.0-alpha.1 <
1.0.0-beta`) cannot be packed into the `ulong` at all — it lives in the
fallback `opCmp`, which `orderKey`-equal versions fall through to.

The corollary: a scheme with richer prerelease structure than
"present / absent" supplies its own ordering instead of an LSB flag.
DMD's compact scheme (`DmdCompact`) encodes the prerelease as a 2-bit
phase (`beta < rc < stable`) plus a 6-bit number, packed just above
`patch`, so a single unsigned compare yields `beta.N < rc.M < stable`
directly — no separate stable-flag bit needed. The LSB-flag pattern is
correct only when the sole tiebreaker is "has prerelease yes/no."

## 5. Key design decisions

### 5.1 Per-ecosystem structs over a generating engine

Covered in §1.2: the abstract `Version` contract is too small to
justify an engine, and the real expressiveness is the optional
capability vocabulary, which belongs in concepts. A hand-written struct
is also far easier to read, debug, and audit than mixin-generated code
— a reviewer checking that `DebianVersion.opCmp` matches
`dpkg --compare-versions` reads straight-line D, not a descriptor walk.

### 5.2 The struct is both value and scheme handle

Aether keeps the `Version` value and the `VersionScheme` factory as
separate nouns because Java cannot put static factory methods and
instance comparison on the same type without awkwardness. D can: a
struct carries instance `opCmp` / `toString` _and_ static
`parse` / `parseNativeRange` / `purlType`. So
[`isVersionScheme!S`](./SPEC.md#61-required-surface--isversionschemes) is
satisfied by the version struct itself — `SemVer` is the value type and
the scheme handle. This collapses two of Aether's three nouns into one
D type. The third noun (Aether's `VersionConstraint`, a union of
intervals) is just [`Ranges!V`](./SPEC.md#42-the-concrete-type--rangesv) with more than one
segment, so we do not need it either.

### 5.3 No cross-scheme total order

Per the univers and Repology evidence (§2.2, §2.3), there is no
meaningful universal order across ecosystems, and the one library that
attempts it is silently wrong on exactly the schemes that matter.
Within a scheme, comparison is a compile-time-guaranteed total order.
Across schemes it does not compile (no `opCmp(SemVer, PypiVersion)`),
and the sum-type
[`compareAny`](./SPEC.md#11-anyversion--anyrange) returns `Nullable!int`
— `null` for a scheme mismatch. This is univers's runtime
`NotImplemented` policy lifted to compile time.

### 5.4 Plain GC `string` for text fields, SSO deferred

An earlier plan mandated an `SsoString` (small-string-optimised) type
for prerelease/build text. We ship plain GC `string` first:

- **plain `string`** is trivially POD — no inline-vs-heap branch in
  every accessor, no tag bit, straightforward implementation;
- **`SsoString`** would elide the GC allocation for the common short
  case (`alpha`, `beta.1`, `rc.3` are all ≤ 7 bytes), but at the cost
  of that branching.

Because the schemes only ever read these fields as `const(char)[]`,
swapping `string` for `SsoString` later is a non-breaking field-type
change. It is deferred until a benchmark or a real consumer justifies
it (§6).

### 5.5 Intersection before union for `Ranges!V` set-ops

The cross-library survey (§2.1) found **intersection is common, union
is rare**. The pubgrub design confirms why: a dependency solver builds
constraints by **intersecting** requirements as it walks the dependency
graph; union appears mainly when normalising a multi-interval
constraint. So `Ranges!V` treats `intersection` (and `complement`,
`contains`) as the primitive required operations and derives `union_`
via De Morgan — exactly pubgrub's `VersionSet` defaulting. This keeps
the required surface minimal and matches the operation a future solver
will actually lean on.

### 5.6 `diff` and `bump` deferred

`inc` / `bump` appear in only 3 of 13 surveyed libraries (§2.1), and
pubgrub explicitly **removed** `bump`/`lowest` as harmful because they
assume a discrete successor that many schemes lack (§2.2). `diff(a, b)`
is similarly rare. Neither is part of the abstract `Version` contract,
so both are deferred until a concrete consumer needs them, at which
point a `bump` would live as a scheme-specific method guarded by
`hasSemVerComponents`, not on the required interface.

### 5.7 Named component lists over fixed `major`/`minor`/`patch`

`hasComponents` is driven by a declarative `enum string[] components`
list on the scheme, not by probing for three fixed fields. This is the
**old engine's component descriptor, minus the engine**: the deleted
`LayoutDescriptor.components[]` carried exactly this name/order
information, but it was generated by a `layoutBody` mixin and bound to a
bit-packing substrate. Here it is a one-line `enum` on a plain struct —
the same generic-over-components capability, with none of the
meta-programming.

The list-based form fixes three rigidities of a fixed `major/minor/patch`
probe:

- **Arity.** Four-component schemes (.NET `8.0.0.0`, Windows
  `10.0.19045.3324`, Chrome `125.0.6422.60`) become directly
  expressible. Fixed-arity-3 was a real part of why they sat in the
  deferred catalogue (see [PRESETS §5.2](./PRESETS.md#52-part-2-heavyweight-schemes)).
- **Honesty.** CalVer declares `["year","month","day"]` instead of
  aliasing date fields onto `major`/`minor`/`patch`. The type now tells
  the truth about what its components mean, and `hasSemVerComponents`
  (the leading-triple subset) correctly reports that a date version has
  no `^`/`~` semantics.
- **Genericity.** `compareComponents`, `componentAt`, and
  `componentCount` let generic code walk a version's components without
  hardcoding arity or names — a scheme's numeric `opCmp` can be a
  one-liner (`=> compareComponents(this, other)`), and bucketing /
  truncation work for any named component.

The split into `hasComponents` (arity-free; gates iteration, compare,
`truncateTo`) and `hasSemVerComponents` (the leading `major/minor/patch`
triple; gates caret/tilde) keeps each operator gated on exactly the
capability it needs — the orthogonality the DbI guideline asks for
(§4.2). The list carries names and order only; per-component zero-pad
width stays in each scheme's hand-written `toString` (decided
deliberately to keep the primitive simple — a generic dotted formatter
with widths can come later as an optional `componentWidths` companion if
a consumer needs it).

## 6. Open questions

These are unresolved and may inform later work; none blocks a current
milestone.

- **Compiler-support floor for bitfield introspection.** Any future
  `orderKey` builder that wants to _verify_ field offsets via
  `__traits(getBitfieldOffset)` is limited to LDC `1.41+`; DMD `2.110`
  lacks it (§4.2). Today the builders compute offsets by summing
  declared widths and treat the trait as a cross-check only. Whether to
  require a minimum DMD that supports the trait depends on which
  compilers `sparkles` officially commits to.

- **Where `SsoString` lives long-term.** Currently it is a deferred
  addition local to `sparkles.versions` (§5.4). If a second consumer
  (e.g. `sparkles.core_cli`) gains a use case, lift it into `core_cli`
  rather than duplicating it. Defer until the second consumer is real.

- **A pubgrub-style solver as a separate library.** This library ships
  `Ranges!V` and its set-algebra but **not** a dependency resolver. If
  one is added, it would import `sparkles.versions`, define its own
  `DependencyProvider`, and live as a separate sub-package — keeping the
  value/range layer free of solver concerns, exactly as pubgrub
  separates `version-ranges` from the solver core.

- **Bucket-F and part-2 schemes.** A class of real-world schemes is not
  yet covered: pseudo-SemVer with hyphenless prerelease (Go `go1.22rc1`,
  Python `3.13.0a1`, OpenSSL `1.1.1w`, OpenSSH `9.7p1`, Unity
  `2023.2.1f1`) needs a numeric→alphanumeric boundary tokeniser, and the
  "part-2" catalogue needs 4-part (128-bit) keys, non-power-of-two
  shapes, pure-alphanumeric fallback, and epoch/dist-tag prefixes. Each
  is its own structural decision; the catalogue is retained as the test
  corpus for any milestone that admits them. See
  [PRESETS.md](./PRESETS.md) for the full per-scheme breakdown.

---

→ [SPEC.md](./SPEC.md) — desired-state specification
→ [PLAN.md](./PLAN.md) — delivery milestones
