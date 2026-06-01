# Prerelease in ranges

_Understanding-oriented. This page explains why a prerelease version is
not admitted by a range merely by falling numerically inside it, and why
`sparkles:versions` adopted the node-semver rule that governs this. For
the runnable demonstration, see the how-to
[Constrain versions with ranges](../how-to/constrain-with-ranges.md); for
the normative statement, see
[SPEC §5.2](../../../specs/versions/SPEC.md#52-satisfies--version-in-range-prerelease-gated)._

## The surprising case

Consider the range `>=1.2.0`. The version `1.3.0-beta.1` sorts _above_
`1.2.0` — a release is greater than the prerelease that precedes it, and
`1.3.0-beta.1` is greater still. So by a naive reading of the interval
`[1.2.0, +∞)`, the prerelease is a member.

The library says it is **not**. A prerelease satisfies a range _only_
when at least one comparator in that range names a prerelease of the same
`(major, minor, patch)` triple. Numeric containment is necessary but not
sufficient.

## Why containment is not enough

The interval `[1.2.0, +∞)` is the answer to a question — "which versions
do I accept?" — and the person who wrote `>=1.2.0` was answering it about
_stable_ releases. They want any release from `1.2.0` onward. They almost
certainly do **not** want to be handed `1.3.0-beta.1`: a prerelease of a
version that has not shipped yet, carrying whatever instability the `beta`
label implies. Prereleases are, by construction, opt-in artifacts; a
constraint that never mentions one should not silently sweep one in.

The opt-in is the other half of the rule. If the author _did_ write a
prerelease bound — say `>=1.2.0-alpha` — they have explicitly declared
that `1.2.0` prereleases are acceptable to them. Then `1.2.0-beta.1`
should satisfy the range, because the author named a prerelease of that
exact `1.2.0` triple. The opt-in is scoped to the triple it was written
against: naming a `1.2.0` prerelease admits other `1.2.0` prereleases, but
says nothing about prereleases of `1.3.0` or `2.0.0`.

So the rule reads each comparator as a small declaration of intent.
Stable bounds keep prereleases out; a prerelease bound opens the door, but
only for the one triple it mentions.

## The worked examples

Against `>=1.2.0`:

- `1.3.0` **satisfies** it — an ordinary stable release at or above the
  bound.
- `1.3.0-beta.1` does **not** satisfy it. It is numerically inside
  `[1.2.0, +∞)`, but no comparator in `>=1.2.0` names a prerelease of the
  `1.3.0` triple, so the prerelease is excluded.

Against `>=1.2.0-alpha`:

- `1.2.0-beta.1` **satisfies** it. The comparator names a prerelease of
  the same `1.2.0` triple, so other `1.2.0` prereleases are admitted.

## Where the rule applies — and where it does not

The rule is defined over the `(major, minor, patch)` triple, so it is
gated on two capabilities at once: `supportsPrerelease!T` (the scheme
models prereleases at all) **and** `hasSemVerComponents!T` (the scheme has
that leading triple to name). Both gates are static, decided at compile
time, which is what keeps the rule from costing anything where it cannot
apply.

This produces three behaviours across the shipped schemes:

- **Full SemVer triple with prereleases** (`SemVer`, `PypiVersion`): the
  rule is in force, exactly as above.
- **Prereleases but no SemVer triple** (`MavenVersion`): Maven models
  prerelease-like qualifiers but does not expose a fixed `major.minor.patch`
  triple to anchor the rule on, so `satisfies` falls back to plain
  `contains` — membership is pure numeric containment.
- **No prerelease model at all** (`Tiny`, `Generic`): there is nothing to
  gate, so the rule is _statically inert_ and `satisfies` reduces to
  `contains`. The branch is never compiled, not merely skipped at runtime.

Splitting the gate this way means a scheme only pays for the rule when it
genuinely has both ingredients the rule is written in terms of. For the
broader story of why capabilities are detected individually rather than
assumed, see [the design](./design.md).

## This is the node-semver convention

The rule is not invented here. It is the convention established by
node-semver, the range engine behind npm, and it is the behaviour that
JavaScript developers have internalised over many years: a published range
of stable bounds will not resolve to someone's in-flight beta, and you
reach a prerelease only by asking for one. Adopting it verbatim means a
developer who already reasons about npm ranges does not have to relearn
membership for `SemVer`.

## See also

- [Constrain versions with ranges](../how-to/constrain-with-ranges.md) —
  the runnable demonstration of all three examples above.
- [The design](./design.md) — the capability vocabulary and the
  required/optional split that the gating relies on.
- [SPEC §5.2](../../../specs/versions/SPEC.md#52-satisfies--version-in-range-prerelease-gated) — the normative statement
  of the prerelease-in-range rule.
