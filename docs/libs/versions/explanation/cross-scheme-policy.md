# No cross-scheme order

_Understanding-oriented. This page explains why `sparkles:versions`
deliberately makes it **impossible** to compare versions across
ecosystems — why asking whether a Debian version is "greater than" a
PyPI one is not a feature gap but a refusal grounded in evidence. For
the practical recipe on holding and comparing mixed schemes, see the
how-to [Handle versions of an unknown scheme](../how-to/handle-unknown-schemes.md);
for the wider prior-art picture, see [prior art](./prior-art.md); for the
normative wording, see [SPEC §6.3](../../../specs/versions/SPEC.md#63-cross-scheme-incomparability) and
[§11](../../../specs/versions/SPEC.md#11-anyversion--anyrange)._

## The tempting wrong answer

A universal comparator — one function that takes any two version strings
and returns which is newer — looks like an obvious convenience. If a
tool already knows how to order SemVer, PEP 440, and Debian versions,
why not stitch the three together behind a single entry point and let
callers stop worrying about which ecosystem a string came from?

Because the stitching cannot be correct. Each ecosystem's ordering is
defined by its _own_ rules, and those rules disagree in ways that have no
neutral arbiter. There is no fact of the matter about whether the PyPI
release `1.0` precedes the npm release `1.0` — the two strings live in
different universes whose ordering relations were never meant to be
joined.

## The one precedent, and why it fails quietly

There is exactly one notable attempt at a universal cross-scheme
comparator: Repology's `libversion` (C), which powers Repology's
cross-distribution package tracking. It is explicitly best-effort, and
it is _silently_ wrong — not loudly, not with an error, but by returning
a confident answer that disagrees with the ecosystem's own tooling — on
precisely the schemes where semantics diverge most:

- **Debian epochs.** Debian versions carry an `epoch:` prefix that
  overrides normal ordering; a best-effort tokeniser that does not model
  epochs orders affected versions backwards.
- **PEP 440 local versions.** Python's `+local` suffixes and the
  pre/post/dev release machinery do not map onto a generic
  dotted-number comparison.
- **Maven qualifiers.** Maven's qualifier ordering (`alpha` < `beta` <
  `milestone` < `rc` < ``(release) <`sp`) is a bespoke table that a
  universal tokeniser cannot reconstruct from the text alone.

The failure mode is the dangerous one: no exception, no `null`, just a
wrong boolean that a caller trusts. This is the evidence base for the
library's refusal. A universal comparator is not merely hard to get
right; the one production attempt demonstrates that "mostly right" here
means "silently wrong on the cases that matter."

## What the libraries that got it right do instead

The library Python's vulnerability tooling reaches for, `univers`, takes
the opposite stance: one `Version` subclass per ecosystem
(`PypiVersion`, `NpmVersion`, `DebianVersion`, …), and cross-scheme
comparison is _forbidden_ outright — every comparison guards with
`if not isinstance(other, self.__class__): return NotImplemented`. The
`vers` specification, the emerging cross-ecosystem range standard, holds
the same line: a `vers:` range is always scoped to a single scheme.

The consensus is therefore not "comparison across schemes is hard," but
"comparison across schemes is **undefined**, and a correct library must
say so rather than guess."

## How the policy is enforced: compile time, not runtime

`sparkles:versions` lifts univers's runtime `NotImplemented` one level
earlier — to the type system. Within a single scheme, comparison is a
**compile-time-guaranteed total order**: `SemVer` has an `opCmp` against
`SemVer`, and the type system proves every two `SemVer` values are
ordered. Across schemes, there is simply no `opCmp(SemVer,
PypiVersion)` — `SemVer` and `PypiVersion` are distinct nominal types
with no shared comparison — so the expression `a < b` for mixed schemes
**does not compile** at all (see [SPEC §6.3](../../../specs/versions/SPEC.md#63-cross-scheme-incomparability)).

This is stronger than a runtime guard. univers can only tell you that a
cross-scheme comparison is meaningless _after_ you have written and run
the code; D tells you _before_, when the program will not build. The
mistake Repology ships is, in this library, not expressible.

It is worth naming what this trades away: there is genuinely no fallback
ordering, not even a degraded one. That is the point. A degraded order
is exactly the Repology failure mode — an answer that looks usable and
is wrong. Refusing to compile is the honest alternative.

## The consequence for callers with mixed schemes

Compile-time refusal is the right default, but real workflows do ingest
mixed schemes — an SBOM row is PyPI, the next is npm, the next Debian,
and the scheme is not known until the string is parsed. For those
callers the library provides the sum type `AnyVersion`, which holds a
version of _any_ shipped scheme, and the **partial** comparator
`compareAny`:

```d
Nullable!int compareAny(in AnyVersion a, in AnyVersion b);
```

Its contract is the whole policy in one signature. When both operands
are the same scheme, it returns the three-way result wrapped in the
`Nullable`. When the schemes differ, it returns `null` — and the `null`
is the _defined answer_, not an error or a missing case. The type
forces the caller to branch on it:

```d
auto cmp = compareAny(a, b);
if (cmp.isNull)
    // different schemes — no ordering exists; handle it explicitly
else
    // same scheme — cmp.get is -1 / 0 / +1
```

You cannot accidentally mis-order a mixed-scheme list, because there is
no code path that yields a bogus comparison: same-scheme pairs get a
real order, cross-scheme pairs make you confront the `null`. The
compile-time wall and the runtime `null` are the same policy seen from
two altitudes — the wall for code that names concrete types, the `null`
for code that has erased the type into `AnyVersion`.

The step-by-step recipe for parsing into `AnyVersion`, calling
`compareAny`, and recovering the concrete type lives in the how-to
[Handle versions of an unknown scheme](../how-to/handle-unknown-schemes.md).

## See also

- [Handle versions of an unknown scheme](../how-to/handle-unknown-schemes.md)
  — the practical recipe for `AnyVersion` and `compareAny`.
- [Prior art](./prior-art.md) — univers, Repology, and the wider survey
  that grounds this policy.
- [The design](./design.md) — where this policy sits in the library's
  overall shape.
- [SPEC §6.3](../../../specs/versions/SPEC.md#63-cross-scheme-incomparability) and
  [§11](../../../specs/versions/SPEC.md#11-anyversion--anyrange) — the normative wording.
