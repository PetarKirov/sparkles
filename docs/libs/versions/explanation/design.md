# The design

_Understanding-oriented. This page explains why `sparkles:versions` is
shaped the way it is — per-ecosystem structs conforming to a small
concept, with capabilities layered on top. For what the library
provides, see the [reference](../reference/concepts.md) and the normative
[SPEC](../../../specs/versions/SPEC.md); for the evidence base, see
[prior art](./prior-art.md)._

## The shortest possible version contract

The central design bet is that the abstract notion of "a version" is
**tiny**: a version is _an ordered type that renders to text_. Nothing
more is universal across ecosystems. Everything else — numeric
components, prereleases, build metadata, a packed ordering key — is a
capability that _some_ schemes have and others do not.

So the required concept, [`isVersion!T`](../reference/concepts.md#the-version-concept),
asks for exactly two things: a three-way `opCmp` and an output-range
`toString`. A type that provides those participates in every generic
algorithm in the library. This matches what the prior art converged on
independently — Rust's pubgrub requires only `Ord + Display`, Maven
Aether only `Comparable<Version> + toString` (see
[prior art](./prior-art.md)).

## Why not a version-_generating_ engine

An earlier shape of this library was a Design-by-Introspection _engine_:
a `Version!Layout` template, parameterised on a `Layout` struct that
declared bit-packed components through a `layoutBody!(…)` mixin, from
which a generic parser, `opCmp`, and `toString` were composed by
introspection. It worked and it shipped — roughly 1500 lines of
meta-programming.

The trouble is that it over-shot its target. A version-_generating_
engine invents storage, formatting, and parsing machinery for a
relationship — "this value is ordered and prints like so" — that a
consumer can express directly in twenty lines of a plain struct. The
engine coupled two things that should be separate: _expressing an
ordering_ and _laying out bits_.

What the engine got right was the observation that versioning has a high,
**orthogonal capability vocabulary** — packed ordering keys, optional
prerelease semantics, numeric component accessors, build metadata. That
is the genuine introspection surface. But the vocabulary belongs in
**concepts plus generic algorithms**, where each capability is
independently detectable and individually opt-in — not bound into a
mixin engine that forces every scheme through one bit-packing substrate.

## Concept flavour, not shell-with-hooks

D's Design-by-Introspection admits two flavours. The headline one is
**shell-with-hooks**: a wrapper type handles boilerplate and a hook type
customises behaviour through `static if`-discovered intercept points
(think `std.checkedint`). The deleted engine _was_ that pattern —
`Version!Layout` the shell, `Layout` the hook.

The shipped design uses the other flavour: **orthogonal trait predicates
over named concepts**, the `isInputRange!R` idiom from Phobos ranges. The
version structs are concrete and self-contained; the _generic algorithms
over them_ (`Ranges!V`, `satisfies`, `sort`) are the shells, and the
optional capability traits are the hooks they introspect.

This fits versioning better because the entities we abstract over — a
`SemVer`, a `PypiVersion` — are **domain values**, not policy objects.
They should be plain structs a reader can understand in isolation. A
reviewer checking that `DebianVersion.opCmp` matches
`dpkg --compare-versions` reads straight-line D, not a descriptor walk.

## The required / optional split

The capability vocabulary is the heart of the design:

- **Required** ([`isVersion!T`](../reference/concepts.md#the-version-concept)):
  `opCmp` and `toString`. Two members, both trivial. The bar is held
  deliberately high — adding a third required member would be a breaking
  change for every scheme.
- **Optional** (the capability traits): `hasOrderKey`,
  `supportsPrerelease`, `hasComponents`, `hasSemVerComponents`,
  `hasBuildMetadata`, plus the scheme-level `supportsNativeRange` and
  `supportsLooseParse`. Each is individually detectable, orthogonal, and
  governed by two rules: it must hold for _every_ value of the type
  (all-or-nothing), and its fast path must produce the same answer as the
  required-surface fallback (equivalence).

Detection is **centralised** in `sparkles.versions.traits`. Generic
algorithms `static if` on a named trait, never on an inline
`__traits(compiles, …)` check scattered through the logic.

### Bit-packing, demoted

In the engine, bit-packing was the _mandatory substrate_: every scheme's
ordering _was_ an unsigned compare of a packed integer. The redesign
inverts this. The **reference behaviour** is a hand-written,
field-by-field `opCmp`. The **fast path** is the packed-integer compare,
exposed through the optional `hasOrderKey` primitive — and a scheme whose
ordering does not pack monotonically into any unsigned integer (Debian,
PEP 440 with local versions) simply _omits_ `orderKey`. Nothing is wrong;
a fast path is merely unavailable, and `sort` falls back to comparison
sorting.

The key width is not fixed: a 4-byte scheme exposes a `uint` key, full
SemVer a `ulong`, and generic code reads the width back through
`OrderKeyType!T` to size `Ranges!T` bounds tightly. (The one genuinely
tricky correctness point — where the "is-stable" tiebreaker bit must sit
in a packed key — is its own story; see the
[SPEC](../../../specs/versions/SPEC.md) and the scheme sources.)

### The baseline scheme

Because the optional capabilities are what make the design interesting,
there must be a scheme that has **none** of them, to keep every fallback
path exercised. That is `Generic`: an opaque, lexicographically-compared
string version with no `orderKey`, no prereleases, no components. Every
generic algorithm runs against it, which is exactly the smoke test the
DbI discipline prescribes for a `void`-hook baseline.

## Two consequences worth calling out

- **The struct is both the value and the scheme handle.** A D struct can
  carry instance `opCmp`/`toString` _and_ static `parse`/`purlType`. So
  `SemVer` is the version value _and_ the thing you parse through — no
  separate scheme singleton. This collapses two of Maven Aether's three
  nouns into one type.
- **Cross-scheme comparison cannot compile.** `SemVer` and `PypiVersion`
  are distinct nominal types with no shared `opCmp`. This is not an
  omission; it is the [policy](./cross-scheme-policy.md), enforced by the
  type system instead of at runtime.

## Named component lists over fixed `major`/`minor`/`patch`

`hasComponents` is driven by a declarative `enum string[] components` on
the scheme, not by probing for three fixed fields. This is the old
engine's component descriptor — _minus the engine_ — and it fixes three
rigidities:

- **Arity.** Four-component schemes (.NET `8.0.0.0`, Windows,
  Chrome) become directly expressible.
- **Honesty.** CalVer declares `["year","month","day"]` instead of
  aliasing date fields onto `major`/`minor`/`patch`, so
  `hasSemVerComponents` correctly reports that a date version has no
  `^`/`~` semantics.
- **Genericity.** `compareComponents`, `componentAt`, and `truncateTo`
  walk the list without hardcoding arity or names.

The split into `hasComponents` (arity-free; gates iteration, compare,
truncation) and `hasSemVerComponents` (the leading triple; gates
caret/tilde) keeps each operator gated on exactly the capability it
needs.

## What was deliberately left out

- **A dependency solver.** The library ships `Ranges!V` and its
  set-algebra, not a pubgrub-style resolver. A solver would import this
  library and live separately.
- **`bump` / `inc` / `diff`.** Rare across the surveyed ecosystems, and
  pubgrub explicitly _removed_ `bump`/`lowest` as harmful — they assume a
  discrete successor that many schemes lack (what comes "after"
  `1.0.0-alpha`?). Deferred until a real consumer needs them.
- **A universal cross-scheme order.** See
  [No cross-scheme order](./cross-scheme-policy.md).

## See also

- [Prior art](./prior-art.md) — pubgrub, Aether, univers, Repology.
- [No cross-scheme order](./cross-scheme-policy.md).
- [Prerelease in ranges](./prerelease-in-range.md).
- [SPEC](../../../specs/versions/SPEC.md) — the normative specification.
