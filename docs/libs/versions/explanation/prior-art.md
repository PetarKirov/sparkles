# Prior art

_Understanding-oriented. This page surveys how other version libraries
model versions, and traces which of their decisions `sparkles:versions`
adopted, adapted, or rejected. For how those lessons assemble into the
shipped shape, see [the design](./design.md); for the cross-scheme
stance in particular, see
[No cross-scheme order](./cross-scheme-policy.md)._

The redesign rests on a survey of how thirteen production version
libraries model versions, plus three deeper reads of the abstraction
strategies that most directly informed the trait design.

## The consensus core

Across node-semver, Rust `semver`, Python `packaging` (PEP 440), Go's
`golang.org/x/mod/semver` and Masterminds `semver`, Maven, RubyGems,
Composer, NuGet, Haskell's `base` `Version` and Cabal, Elixir's
`Version`, and the prior D `sparkles:semver`, the same capabilities
recur in essentially _all_ of them:

- parse a canonical string into a typed value;
- render a canonical `toString`;
- a **total order** — the five comparison operators plus a three-way
  compare;
- equality plus a hash;
- component accessors (major / minor / patch, or the scheme's analog);
- a **separate** range / requirement type with `satisfies` / `matches`;
- range operators plus AND-composition;
- prerelease excluded from ranges by default, with explicit opt-in;
- a `sort`.

A handful of features show up only in a minority: `inc` / `bump` (just
node-semver, Masterminds, and RubyGems, three of the thirteen),
`maxSatisfying`, range set-operations (intersection is common; union is
rare), a `diff` that names the changed component, and the caret/tilde
shorthands.

The consensus core maps almost exactly onto the required version
concept — order plus `toString` — together with a separate range type
carrying `contains` / `satisfies`. The rare features are deliberately
deferred; see [what was left out](./design.md#what-was-deliberately-left-out).

## Three abstraction traditions

Three libraries answer the question _"what is the abstract version
interface?"_ in three instructively different ways.

### pubgrub — abstract over the _set_, not the _value_

The Rust pubgrub solver, in its v0.3 release, **deleted its `Version`
trait entirely**. Its changelog records the new stance plainly: a
version "can be almost any ordered type now, it only needs to support
set operations through `VersionSet`." The replacement trait
(pubgrub `src/version_set.rs`) requires only a few set primitives —
emptiness, a singleton, complement, intersection, and membership — and
defaults the rest (full set, union, disjointness, subset) via De
Morgan's laws. The value type behind a set is constrained to nothing
more than being ordered, cloneable, and printable.

Critically, the _removed_ `Version` trait had carried `lowest()` and
`bump()`, and those were dropped as **harmful**: they assume a discrete
successor that does not exist for many real schemes. What, after all,
is the version "after" `1.0.0-alpha`? The concrete range representation
that survived is a sorted, disjoint list of intervals.

> **Lesson:** abstract over the set, keep the value contract to
> ordering plus display, and never bake in a successor or `bump`.
> `sparkles:versions` ports the `VersionSet` interface almost verbatim
> as its [range concept](../../../specs/versions/SPEC.md#41-required-surface--isversionranger)
> and copies the sorted-disjoint-interval shape into its
> [concrete range type](../../../specs/versions/SPEC.md#42-the-concrete-type--rangesv).

### Maven Aether — the scheme is a separate factory

Aether's version SPI exposes parsing entry points for versions,
ranges, and constraints. It is a **factory**, kept separate from the
`Version` value — which is merely something comparable that renders to
text. Aether models three nouns: a version, a range (a single
interval), and a constraint (a union of ranges, plus a soft
requirement).

The older Maven `ArtifactVersion` had leaked `getMajor` / `getMinor` /
`getQualifier` through its abstract interface — an **anti-pattern**
Aether deliberately walked back, because component accessors are not
universal across schemes.

> **Lesson:** keep component accessors _off_ the required interface
> (they become an optional capability,
> [`hasComponents`](../reference/concepts.md)), and separate parsing
> (the factory) from the value. `sparkles:versions` adopts the factory
> idea as its [scheme concept](../../../specs/versions/SPEC.md#61-required-surface--isversionschemes),
> but collapses Aether's version and scheme nouns into a _single_ D
> struct: a struct can carry both instance methods and static factory
> methods, so `SemVer` is the value and the thing you parse through at
> once.

### univers — per-ecosystem subclasses, no cross-scheme order

The Python univers library ships one `Version` subclass per ecosystem —
`PypiVersion`, `NpmVersion`, `DebianVersion`, `MavenVersion`,
`RpmVersion`, `ArchLinuxVersion`, and more. Cross-scheme comparison is
**forbidden**: every comparison method guards against an operand of a
different class and returns Python's `NotImplemented` rather than a
bogus answer. A registry keyed by purl `type` dispatches range parsing,
and a small non-identity map handles the cases where the purl type and
the scheme name diverge (for instance, `packagist` maps to `composer`).
univers also implements the version-range URI round-trip with ASCII,
lowercase, sort-and-dedupe normalisation.

> **Lesson:** per-ecosystem types are the right unit, cross-scheme
> comparison must be impossible, and the purl type is the dispatch key.
> `sparkles:versions` gets all three from D's nominal typing: there is
> simply no `opCmp` between `SemVer` and `PypiVersion`, so cross-scheme
> comparison **does not compile** — a compile-time analog of univers's
> runtime `NotImplemented` (see
> [No cross-scheme order](./cross-scheme-policy.md)). The registry
> shape, the non-identity purl-type map (see
> [pURL interop](../../../specs/versions/SPEC.md#10-purl-interop)), and
> the range-URI normalisation rules are copied across.

## The cautionary tale — Repology `libversion`

Repology's `libversion` (in C) is the one notable precedent for a
**single universal comparator across all schemes**. It is explicitly
best-effort, and it is silently wrong on Debian epochs, PEP 440 local
versions, and Maven qualifier ordering — exactly the schemes where
ecosystem semantics diverge most. That is the evidence base for
`sparkles:versions` refusing to provide a universal cross-scheme total
order: its cross-scheme compare returns a _nullable_ result, `null`
whenever the two operands belong to different schemes (see
[`AnyVersion` / `AnyRange`](../../../specs/versions/SPEC.md#11-anyversion--anyrange)).
The same stance is held by univers and by the version-range
specification. The full reasoning lives in
[No cross-scheme order](./cross-scheme-policy.md).

## The interchange formats

The [VERS](https://github.com/package-url/vers-spec) and
[pURL](https://github.com/package-url/purl-spec) specifications are the
emerging cross-ecosystem interchange standards. `sparkles:versions`
adopts `vers:` as the canonical range **wire format** and the purl
`type` as the **scheme key**. That is what lets a purl-driven workflow —
SBOM ingestion, OSV vulnerability matching — dispatch to the correct
typed scheme without a hand-maintained switch.

## See also

- [The design](./design.md) — how these lessons assemble into the
  shipped shape.
- [No cross-scheme order](./cross-scheme-policy.md) — the univers and
  Repology stance, in full.
- [Scheme catalogue](../reference/schemes.md) — the per-ecosystem
  schemes themselves.
- [SPEC](../../../specs/versions/SPEC.md) — the normative specification.
