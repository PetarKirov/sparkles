# `sparkles:versions`

An **ecosystem-aware version library** for D. It parses, compares, and
constrains the version strings of many package ecosystems — Semantic
Versioning, PEP 440 (PyPI), Maven, Debian, CalVer, and several internal
schemes — and interoperates with
[pURL](https://github.com/package-url/purl-spec) (Package URL) and
[VERS](https://github.com/package-url/vers-spec) (version-range URI).

Each ecosystem is one hand-written struct (`SemVer`, `PypiVersion`,
`DebianVersion`, …) conforming to a tiny compile-time concept; generic
algorithms — ranges, sorting, satisfaction — work over any conforming
type. Cross-scheme comparison does not compile, so you cannot
accidentally ask whether a Debian version is "greater than" a PyPI one.

```d
import sparkles.versions.schemes.semver : SemVer;

auto a = SemVer.parse("1.2.3-rc.1").value;
auto b = SemVer.parse("1.2.3").value;
assert(a < b);          // a prerelease precedes its release
```

## How this documentation is organised

These docs follow the [Diátaxis](https://diataxis.fr/) framework: four
sections, each answering a different kind of question. If you are not
sure where to start, read the tutorial.

### [Tutorial](./tutorial/getting-started.md)

_Learning-oriented._ A single guided walk that has you parsing,
comparing, sorting, and range-testing versions in one runnable program.
Start here if you are new to the library.

- [Getting started](./tutorial/getting-started.md)

### How-to guides

_Task-oriented._ Short, focused recipes for a specific job. Reach for
these when you already know what you want to do.

- [Compare and sort versions](./how-to/compare-and-sort.md)
- [Constrain versions with ranges](./how-to/constrain-with-ranges.md)
- [Interoperate with VERS and pURL](./how-to/vers-and-purl-interop.md)
- [Handle versions of an unknown scheme](./how-to/handle-unknown-schemes.md)
- [Add a new scheme](./how-to/add-a-new-scheme.md)

### Reference

_Information-oriented._ Precise, lookup-style descriptions of what the
library provides.

- [Concepts and API](./reference/concepts.md) — the three concepts
  (`isVersion`, `isVersionRange`, `isVersionScheme`), the capability
  vocabulary, and the public surface, with pointers into the normative
  [SPEC](../../specs/versions/SPEC.md).
- [Scheme catalogue](./reference/schemes.md) — every shipped scheme: its
  pURL type, examples, ordering rules, capabilities, native-range
  grammar, and provenance.
- [API index](./reference/api.md) — the public symbols by module.

### Explanation

_Understanding-oriented._ The reasoning, history, and trade-offs behind
the design.

- [The design](./explanation/design.md) — why per-ecosystem structs over
  a generating engine, and the required/optional concept split.
- [Prior art](./explanation/prior-art.md) — what pubgrub, Maven Aether,
  univers, and Repology taught us.
- [No cross-scheme order](./explanation/cross-scheme-policy.md) — why
  comparing across ecosystems is deliberately impossible.
- [Prerelease in ranges](./explanation/prerelease-in-range.md) — the
  node-semver rule and why we adopted it.

## Source Code

- **Core Module Index**: [`libs/versions/src/sparkles/versions/`](../../../libs/versions/src/sparkles/versions/)
- **Version Schemes Catalog**: [`libs/versions/src/sparkles/versions/schemes/`](../../../libs/versions/src/sparkles/versions/schemes/)
- **Core Implementation Files**:
  - Version Ranges: [`ranges.d`](../../../libs/versions/src/sparkles/versions/ranges.d)
  - Package URL (pURL): [`purl.d`](../../../libs/versions/src/sparkles/versions/purl.d)
  - Version-Range URI (VERS): [`vers.d`](../../../libs/versions/src/sparkles/versions/vers.d)
  - Operations & Sorting: [`operations.d`](../../../libs/versions/src/sparkles/versions/operations.d)
  - Traits & Concepts: [`traits.d`](../../../libs/versions/src/sparkles/versions/traits.d)

## See also

- [SPEC](../../specs/versions/SPEC.md) — the normative specification.
- [Delivery plan](../../specs/versions/PLAN.md) — milestones and
  orchestration.
