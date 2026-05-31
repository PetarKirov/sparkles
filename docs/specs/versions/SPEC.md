# `sparkles:versions` — Specification

_Audience: developers and coding agents building against the library.
This document is normative and self-contained — it states what the
library provides, not why. For design history, prior-art, and the
reasoning behind each decision, see [RATIONALE.md](./RATIONALE.md); for
the delivery plan, see [PLAN.md](./PLAN.md); for the per-scheme catalogue
(real-world examples, edge cases, provenance, and how to add a scheme),
see [PRESETS.md](./PRESETS.md)._

## 1. Overview

`sparkles:versions` parses, compares, and constrains the version strings
of many package ecosystems — Semantic Versioning, PEP 440 (PyPI), Maven,
Debian, CalVer, and several internal schemes — and interoperates with
[pURL](https://github.com/package-url/purl-spec) (Package URL) and
[VERS](https://github.com/package-url/vers-spec) (version-range URI).

Each ecosystem is one hand-written struct (`SemVer`, `PypiVersion`,
`DebianVersion`, …) that conforms to the compile-time concept
[`isVersion!T`](#3-the-version-concept) and, where it parses an
ecosystem's strings, [`isVersionScheme!S`](#6-the-scheme-concept).
Generic algorithms — [`Ranges!V`](#4-the-range-concept),
[`satisfies`](#5-operations), [`sort`](#5-operations) — operate over any
conforming type.

Core rules:

- A scheme is a plain struct plus
  `static assert(isVersion!S && isVersionScheme!S);`. There is no base
  class, no registration step, and no code generation.
- Optional capabilities (§3.2) are opt-in per struct. Their absence is
  never an error; a generic algorithm falls back to the required surface.
- Cross-scheme comparison does not compile: `SemVer` and `PypiVersion`
  are distinct nominal types with no shared `opCmp`. Hold mixed-scheme
  values in [`AnyVersion`](#11-anyversion--anyrange) and compare them
  with the partial `compareAny`.

A consumer who needs only SemVer imports one type:

```d
import sparkles.versions.schemes.semver : SemVer;

auto a = SemVer.parse("1.2.3-rc.1").value;
auto b = SemVer.parse("1.2.3").value;
assert(a < b);                       // prerelease precedes its release
assert(a.toString == "1.2.3-rc.1");
```

## 2. Package and module layout

| Identifier      | Value                                  |
| --------------- | -------------------------------------- |
| Dub sub-package | `sparkles:versions`                    |
| Source root     | `libs/versions/src/sparkles/versions/` |
| Package module  | `sparkles.versions`                    |

The folder uses the plural name `versions/` because `version` is a D
keyword.

| Module                                      | Contents                                                                            |
| ------------------------------------------- | ----------------------------------------------------------------------------------- |
| `sparkles.versions`                         | Public re-exports (`package.d`)                                                     |
| `sparkles.versions.traits`                  | `isVersion!T`, `isVersionRange!R`, `isVersionScheme!S` + optional-capability traits |
| `sparkles.versions.parsing`                 | `ParseMode`; re-exports the parse types from `core_cli.parse_error`                 |
| `sparkles.versions.ranges`                  | `Ranges!V` (sorted disjoint intervals)                                              |
| `sparkles.versions.vers`                    | VERS URI parser/emitter + compile-time scheme registry                              |
| `sparkles.versions.purl`                    | Package URL parser + purl-type → scheme mapping                                     |
| `sparkles.versions.any`                     | `AnyVersion` / `AnyRange` sum types, `compareAny`                                   |
| `sparkles.versions.schemes`                 | Re-exports every scheme module + registry hook                                      |
| `sparkles.versions.schemes.semver`          | `SemVer` (strict SemVer 2.0.0)                                                      |
| `sparkles.versions.schemes.dmd`             | `Dmd` (3-digit zero-padded minor)                                                   |
| `sparkles.versions.schemes.dmd_compact`     | `DmdCompact` (4-byte bitfield-encoded prerelease)                                   |
| `sparkles.versions.schemes.tiny`            | `Tiny` (4-byte, no prerelease)                                                      |
| `sparkles.versions.schemes.calver_yymm`     | `CalVerYYMM` (Ubuntu `24.04.1`)                                                     |
| `sparkles.versions.schemes.calver_yyyymmdd` | `CalVerYYYYMMDD` (Arch `2024.05.01`)                                                |
| `sparkles.versions.schemes.vim`             | `VimVer` (4-digit patch)                                                            |
| `sparkles.versions.schemes.pypi`            | `PypiVersion` (PEP 440)                                                             |
| `sparkles.versions.schemes.maven`           | `MavenVersion` (qualifier order)                                                    |
| `sparkles.versions.schemes.deb`             | `DebianVersion` (epoch/upstream/revision)                                           |
| `sparkles.versions.schemes.generic`         | `Generic` (opaque lexicographic baseline)                                           |
| `sparkles.versions.testing`                 | `version(unittest)` test helpers (`checkParse`, `checkRoundTrip`, …)                |

The library has no `_internal` package: shared low-level primitives live
in `sparkles.core_cli`, and the SemVer identifier grammar
(`compareSemVerPrerelease`, identifier validation) lives `package`-scoped
in `schemes/semver.d`, reused by the other SemVer-shaped schemes.

**Foundation in `sparkles.core_cli`** — the parsing/formatting primitives
are generic and live in core_cli, not in `versions`:

| Module                           | Provides                                                                       |
| -------------------------------- | ------------------------------------------------------------------------------ |
| `sparkles.core_cli.parse_error`  | `ParseError {code, offset}`, `ParseErrorCode`, `ParseExpected!T` (generic)     |
| `sparkles.core_cli.text_readers` | `readInteger`, `skipWhile`, `tryConsume`, `readUntil` (slice-advance, `@nogc`) |
| `sparkles.core_cli.text_writers` | `writeIntegerPadded` (alongside the existing `writeInteger`)                   |

## 3. The Version concept

A version is totally ordered and renders to text. That is the entire
required surface; everything else is optional (§3.2).

### 3.1 Required surface — `isVersion!T`

`isVersion!T` (in `sparkles.versions.traits`) requires a three-way
`opCmp` and an output-range `toString`. Named sub-checks report which
half is missing:

```d
template isVersion(T)
{
    enum hasOpCmp    = is(typeof((const T a, const T b) => a.opCmp(b)) : int);
    enum hasToString = __traits(compiles, (const T v) {
        void delegate(scope const(char)[]) @safe sink;
        v.toString(sink);                 // exact output-range call
    });
    enum isVersion = hasOpCmp && hasToString;
}
```

A conforming struct provides:

```d
int  opCmp(in T other) const @safe pure nothrow @nogc;  // three-way total order
void toString(W)(ref W sink) const;                      // writes into an output range
```

- Provide `opEquals` and `toHash` consistent with `opCmp` so versions
  work as associative-array keys and in `==`.
- `toString` writes into an output range, per the `sparkles.core_cli`
  conventions in [`AGENTS.md`](../../guidelines/AGENTS.md#output-ranges).

### 3.2 Optional capability vocabulary

Each capability is an independently-detectable trait in
`sparkles.versions.traits`. A type that provides one enables a fast path
or an extra feature; a type that omits one still works through the
required surface.

| Capability              | Detection rule                                   | Behavioural impact                                              |
| ----------------------- | ------------------------------------------------ | --------------------------------------------------------------- |
| `hasOrderKey!T`         | `.orderKey` → any unsigned int (`ubyte`…`ulong`) | radix `sort`, compact `Ranges!T` bounds, fast `opCmp` pre-check |
| `supportsPrerelease!T`  | `.isPrerelease` → `bool`                         | prerelease-in-range rule (gates [`satisfies`](#5-operations))   |
| `hasComponents!T`       | `enum string[] components` of named uint fields  | generic component iteration/compare, `truncateTo`               |
| `hasSemVerComponents!T` | `components` begins `["major","minor","patch"]`  | caret `^` / tilde `~` range operators                           |
| `hasBuildMetadata!T`    | `.build` → `const(char)[]`                       | build-aware compare                                             |

```d
import std.traits : isUnsigned;

/// Monotonic unsigned-integer key of any width (`ubyte` … `ulong`): the
/// scheme picks the narrowest type that fits its components, so a compact
/// scheme can expose a `uint` (or smaller) key for narrower comparisons
/// and tighter `Ranges!T` bound storage. Where present,
/// `sign(a.orderKey <=> b.orderKey) == sign(a <=> b)` whenever the keys
/// differ; equal keys fall through to `opCmp`. (`isUnsigned` excludes
/// `bool` and the character types, so a stray `bool`/`char` member does
/// not accidentally qualify.)
enum hasOrderKey(T) = isUnsigned!(typeof(T.init.orderKey));

/// The unsigned integer type a scheme's `orderKey` returns — `uint` for a
/// 4-byte scheme, `ulong` for SemVer. Only valid when `hasOrderKey!T`;
/// generic code uses it to size compact key storage.
alias OrderKeyType(T) = typeof(T.init.orderKey);

enum supportsPrerelease(T) = is(typeof((const T v) => v.isPrerelease) : bool);

/// A version exposing an ordered list of named numeric components.
/// `T.components` is a compile-time `string[]` of readable unsigned-int
/// member names, most-significant first (the order `opCmp` compares and
/// `toString` prints them in). Arity is free: 3 for SemVer, 4 for .NET /
/// Windows, `["year","month","day"]` for CalVer. Generic code iterates
/// the list to compare, truncate, and bucket without hardcoding names.
template hasComponents(T)
{
    static if (is(typeof(T.components) : const(string)[]))
        enum hasComponents = T.components.length >= 1 && allComponentsUnsigned!T;
    else
        enum hasComponents = false;
}

private enum bool allComponentsUnsigned(T) = () {
    bool ok = true;
    static foreach (name; T.components)
        static if (!__traits(hasMember, T, name)
                || !isUnsigned!(typeof(__traits(getMember, T.init, name))))
            ok = false;
    return ok;
}();

/// True when the list begins with the SemVer triple, so caret `^` / tilde
/// `~` have their conventional "compatible within major/minor" meaning. A
/// 4-component or calendar scheme has `hasComponents` but not this, so it
/// correctly gets no caret operator.
enum hasSemVerComponents(T) =
    hasComponents!T && T.components.length >= 3
    && T.components[0] == "major"
    && T.components[1] == "minor"
    && T.components[2] == "patch";

enum hasBuildMetadata(T) = is(typeof((const T v) => v.build) : const(char)[]);
```

The component list drives three generic helpers (in
`sparkles.versions.traits`) that schemes reuse and generic algorithms
call:

- `compareComponents(a, b)` — walks the list most-significant-first for
  the numeric part of `opCmp`.
- `componentAt(v, i)` — reads the `i`-th component as a `ulong`.
- `componentCount!T` — `T.components.length`.

The list carries names and order only. Per-component zero-pad width
stays in each scheme's own `toString`.

Two rules govern optional capabilities:

- **All-or-nothing.** Expose a capability only when it holds for every
  value of the type — never one that works sometimes. A scheme whose
  components can overflow its chosen `orderKey` width omits `orderKey`
  entirely; to gain headroom, it returns a wider unsigned type.
- **Equivalence.** A capability's fast path produces the same result as
  the required-surface fallback. `orderKey` satisfies
  `sign(a.orderKey <=> b.orderKey) == sign(a.opCmp(b))` whenever the keys
  differ, and the test suite asserts this across each scheme's corpus.

`Generic` (§8) is the baseline scheme: an opaque, lexicographically
compared version with zero optional capabilities. Every generic
algorithm's fallback path runs against it.

## 4. The Range concept

A version range is a set of versions, expressed as set algebra.
`Ranges!V` is the single concrete implementation.

### 4.1 Required surface — `isVersionRange!R`

Five members are required — the minimal set-algebra basis. `full`,
`union_`, `isDisjoint`, and `subsetOf` are derived by default and need
not be hand-written:

```d
template isVersionRange(R)
{
    enum isVersionRange =
        is(R.Version) && isVersion!(R.Version) &&
        is(typeof(R.empty()) == R) &&
        is(typeof(R.singleton(R.Version.init)) == R) &&
        is(typeof((const R r) => r.complement()) : R) &&
        is(typeof((const R a, const R b) => a.intersection(b)) : R) &&
        is(typeof((const R r, const R.Version v) => r.contains(v)) : bool);
}
```

| Method                     | Status    | Meaning                                                      |
| -------------------------- | --------- | ------------------------------------------------------------ |
| `static empty()`           | required  | the empty set                                                |
| `static singleton(V v)`    | required  | the set `{v}`                                                |
| `complement()`             | required  | set complement                                               |
| `intersection(in R other)` | required  | set intersection                                             |
| `contains(in V v)`         | required  | membership test                                              |
| `static full()`            | defaulted | `empty().complement()`                                       |
| `union_(in R other)`       | defaulted | `complement().intersection(other.complement()).complement()` |
| `isDisjoint(in R other)`   | defaulted | `intersection(other) == empty()`                             |
| `subsetOf(in R other)`     | defaulted | `this == intersection(other)`                                |

### 4.2 The concrete type — `Ranges!V`

`Ranges!V` (in `sparkles.versions.ranges`) is the only generic data
structure in the library. It stores a sorted, disjoint sequence of
intervals and maintains those invariants on every operation: segments
stay sorted, no segment is empty, and adjacent mergeable intervals
coalesce.

```d
struct Ranges(V) if (isVersion!V)
{
    alias Version = V;

    // --- required set-algebra basis ---
    static Ranges empty();
    static Ranges singleton(V v);
    Ranges complement() const;
    Ranges intersection(in Ranges other) const;
    bool contains(in V v) const;

    // --- defaulted via De Morgan ---
    static Ranges full() => empty().complement();
    Ranges union_(in Ranges other) const
        => complement().intersection(other.complement()).complement();
    bool isDisjoint(in Ranges other) const => intersection(other) == empty();
    bool subsetOf(in Ranges other) const => this == intersection(other);

    // --- interval conveniences ---
    static Ranges higherThan(V v);          // [v, +∞)
    static Ranges strictlyHigherThan(V v);  // (v, +∞)
    static Ranges lowerThan(V v);           // (-∞, v]
    static Ranges strictlyLowerThan(V v);   // (-∞, v)
    static Ranges between(V lo, V hi);      // [lo, hi)

    // --- equality / formatting ---
    bool opEquals(in Ranges other) const;
    void toString(W)(ref W w) const;        // emits VERS constraint syntax
}
```

Rules:

- There is no per-scheme range type — no `NpmRange`, `PypiRange`, or
  `DebianRange`. Each scheme's `Range` alias is `Ranges!ThatVersion`.
- The native range grammar (`^1.2.0` for npm, `[1.0,2.0)` for Maven,
  `>=1.2.4` for PEP 440) and the `vers:` constraint syntax are static
  methods on the scheme struct (§6, §9), not on `Ranges`.
- `opEquals` compares canonical (sorted, merged) interval sequences, so
  two ranges built from different but equivalent expressions compare
  equal.
- `toString` emits VERS constraint syntax (§9), giving every range a
  scheme-agnostic textual form.

## 5. Operations

Generic operations live in `sparkles.versions.ranges` and
`sparkles.versions.traits`. Each pairs a baseline that needs only the
required surface with an opt-in fast path gated on an optional
capability.

### 5.1 `order` — fast-path / fallback compare

`order(a, b)` returns the same three-way result as `a.opCmp(b)` for any
`isVersion!T`. When `T` provides `hasOrderKey`, compare the keys first
and fall through to `opCmp` only on a key tie:

```d
int order(T)(in T a, in T b) @safe pure nothrow @nogc
if (isVersion!T)
{
    static if (hasOrderKey!T)
    {
        const ka = a.orderKey, kb = b.orderKey;
        if (ka != kb)
            return ka < kb ? -1 : 1;   // keys differ → decisive
    }
    return a.opCmp(b);                  // fallback / tie-break
}
```

`Generic`, lacking `orderKey`, always takes the fallback branch.

### 5.2 `satisfies` — version-in-range, prerelease-gated

`satisfies(v, range)` reports whether a version is admitted by a range.
The base case is `range.contains(v)`. When `T` provides
`supportsPrerelease`, apply the **prerelease-in-range rule**:

> A prerelease version satisfies a range only when at least one
> comparator in the range names a prerelease of the same
> `(major, minor, patch)` triple.

Given the range `>=1.2.0`:

- `1.3.0` satisfies it (a stable release ≥ the bound).
- `1.3.0-beta.1` does **not** satisfy it — even though it is numerically
  inside `[1.2.0, +∞)` — because no comparator in `>=1.2.0` names a
  prerelease of the `1.3.0` triple.
- `1.2.0-beta.1` satisfies `>=1.2.0-alpha`, because that comparator names
  a prerelease of the same `1.2.0` triple.

When `T` does not provide `supportsPrerelease` (e.g. `Tiny`, `Generic`),
`satisfies` reduces to `contains` — the rule is statically inert for
schemes that do not model prereleases.

### 5.3 Caret / tilde — gated on `hasSemVerComponents`

The npm-style operators desugar to `Ranges!V` intervals using the
`(major, minor, patch)` triple, so they require `hasSemVerComponents!T`
(not merely `hasComponents`, since `^`/`~` are undefined for a
4-component or calendar scheme):

- `^1.2.3` → `[1.2.3, 2.0.0)` (compatible within the major).
- `~1.2.3` → `[1.2.3, 1.3.0)` (compatible within the minor).

They are scheme-level static helpers (`SemVer.caret(v)`,
`SemVer.tilde(v)`). Calling one on a scheme without the SemVer triple is
a compile-time error:

```d
static assert(hasSemVerComponents!V,
    "caret/tilde require components beginning [\"major\",\"minor\",\"patch\"] "
    ~ "(hasSemVerComponents!V). " ~ V.stringof
    ~ " has no SemVer triple; build the range explicitly instead.");
```

### 5.4 `sort`

`sort(versions)` orders a slice of `isVersion!T`. With `hasOrderKey` it
may radix-sort on the keys (resolving key ties with `opCmp`); without it
it comparison-sorts via `opCmp`. Both paths produce the same ordering.

### 5.5 `truncateTo`

`truncateTo!"name"(v)` returns a version of the same type with every
component below the named one (in `components` order) zeroed — useful for
bucketing (group SemVer by `major.minor`, group a CalVer by `"month"`).
The name must appear in `T.components`, so it requires `hasComponents!T`
(any arity) and is a compile-time error otherwise, with the same
diagnostic shape as §5.3.

## 6. The Scheme concept

A scheme is the handle the library parses through and identifies by pURL
type. The struct is both the version value and the scheme handle: `SemVer`
is the version type _and_ carries the static `parse`, `purlType`, and
range helpers — there is no separate scheme singleton. (Background:
[RATIONALE §5.2](./RATIONALE.md#52-the-struct-is-both-value-and-scheme-handle).)

### 6.1 Required surface — `isVersionScheme!S`

```d
template isVersionScheme(S)
{
    enum isVersionScheme =
        is(S.Version) && isVersion!(S.Version) &&
        is(typeof(S.purlType) : string) && S.purlType.length > 0 &&
        is(typeof(S.parse("")) : ParseExpected!(S.Version));
}
```

A conforming scheme provides:

```d
alias Version = S;                          // usually the struct itself
alias Range   = Ranges!S;
enum string purlType = "semver";            // non-empty pURL type string
static ParseExpected!S parse(string s);     // exact-syntax parser (§7)
```

### 6.2 Optional scheme capabilities

| Capability              | Detection rule                                                 | Behavioural impact                         |
| ----------------------- | -------------------------------------------------------------- | ------------------------------------------ |
| `supportsNativeRange!S` | `.parseNativeRange("")` → `ParseExpected!(Ranges!(S.Version))` | parse the ecosystem's native range grammar |
| `supportsLooseParse!S`  | `.parseLoose("")` → `ParseExpected!(S.Version)`                | accept compatibility forms (`v1.2`, `1`)   |

```d
enum supportsNativeRange(S) =
    is(typeof(S.parseNativeRange("")) : ParseExpected!(Ranges!(S.Version)));
enum supportsLooseParse(S) =
    is(typeof(S.parseLoose("")) : ParseExpected!(S.Version));
```

A scheme that only parses exact versions is still a valid
`isVersionScheme`; the VERS and pURL layers `static if` on these
capabilities. Each shipped scheme module ends with a compile-time
conformance assertion:

```d
static assert(isVersion!SemVer && isVersionScheme!SemVer);
```

### 6.3 Cross-scheme incomparability

Cross-scheme comparison does not compile. There is no
`opCmp(SemVer, PypiVersion)` because `SemVer` and `PypiVersion` are
distinct nominal types — the type system rules out a cross-scheme order
at compile time. A caller that must hold versions of mixed schemes uses
[`AnyVersion`](#11-anyversion--anyrange) and the partial `compareAny`,
which returns `null` across schemes.

## 7. Parsing

Parsing is non-throwing and `Expected`-based. The error vocabulary is
generic and lives in `sparkles.core_cli.parse_error` (reused by every
core_cli text parser, not just versions); `ParseMode` is a versions enum
in `sparkles.versions.parsing`.

```d
// sparkles.core_cli.parse_error (generic, @nogc)
enum ParseErrorCode
{
    emptyInput, unexpectedCharacter, unexpectedEnd, leadingZero,
    numericOverflow, invalidIdentifier, widthMismatch, /* … */
}

struct ParseError
{
    ParseErrorCode code;  /// what went wrong
    size_t offset;        /// byte offset (within the parsed input) of the failure
}

alias ParseExpected(T) = Expected!(T, ParseError, NoGcHook);

// sparkles.versions.parsing
enum ParseMode { strict, loose }
```

`ParseExpected!T` carries either a parsed `T` or a structured
`ParseError`. Branch on `result.hasValue` / `result.error`:

```d
auto r = SemVer.parse("1.2.x");
if (r.hasValue)
    use(r.value);
else
    report(r.error.code, r.error.offset);  // unexpectedCharacter @ 4
```

The parsing surface across the three concepts:

| Function                | Concept                 | Required? | Behaviour                                                               |
| ----------------------- | ----------------------- | --------- | ----------------------------------------------------------------------- |
| `S.parse(s)`            | `isVersionScheme!S`     | required  | exact canonical syntax → `ParseExpected!(S.Version)`                    |
| `S.parseLoose(s)`       | `supportsLooseParse!S`  | optional  | additionally accept `v`-prefix, missing trailing components (zero-fill) |
| `S.parseNativeRange(s)` | `supportsNativeRange!S` | optional  | the ecosystem's native range grammar → `ParseExpected!(S.Range)`        |

`ParseMode` is the strict/loose selector for schemes that route both
behaviours through one entry point; `parseLoose` is the discoverable,
capability-gated form. Each scheme's exact grammar and native range
grammar are documented in [PRESETS.md](./PRESETS.md).

## 8. Shipped schemes

The library ships a set of preset schemes that span the capability space
— from `SemVer` (every optional capability) to `Generic` (none). The full
list, the complete capability matrix, and the per-scheme detail
(real-world examples, ordering rules, native-range grammar, edge cases,
provenance) live in [PRESETS.md](./PRESETS.md) — adding a preset touches
only that document.

Every scheme provides the required `isVersion!T` surface (`opCmp` +
`toString`). An illustrative slice shows how the **optional** capabilities
vary across schemes:

| Scheme        | `hasOrderKey` | `supportsPrerelease` | `hasComponents` | `hasBuildMetadata` |
| ------------- | :-----------: | :------------------: | :-------------: | :----------------: |
| `SemVer`      |      ✅       |          ✅          |       ✅        |         ✅         |
| `CalVerYYMM`  |      ✅       |          —           |       ✅        |         —          |
| `PypiVersion` |       —       |          ✅          |       ✅        |         —          |
| `Generic`     |       —       |          —           |        —        |         —          |

- `SemVer` packs into an `orderKey` and carries the full SemVer triple
  (so it also gets caret/tilde via `hasSemVerComponents`).
- `CalVerYYMM` is numeric-only — no prereleases, and its
  `["year","month","day"]` list gives `hasComponents` but not the
  caret/tilde-enabling `hasSemVerComponents`.
- `PypiVersion` is _structural_: its ordering does not pack into an
  integer, so it omits `orderKey`, yet it still has prereleases and
  components.
- `Generic` is the opaque baseline with no optional capabilities — it
  exercises every generic algorithm's fallback path.

## 9. VERS interop

[VERS](https://github.com/package-url/vers-spec) is a URI scheme for
version-range expressions:
`vers:<scheme>/<constraint>|<constraint>|…`. The `sparkles.versions.vers`
module parses and emits the URI surface; per-scheme constraint
translation lives on each scheme struct.

```d
struct VersUri
{
    string scheme;        // "npm", "pypi", "deb", "semver", …
    string[] constraints; // pre-split on '|', not yet typed
}

ParseExpected!VersUri parseVersUri(string s);
void formatVersUri(W)(ref W w, in VersUri v);
```

`parseVersUri` handles only the URI surface: scheme extraction,
`|`-splitting, and ASCII/lowercase normalisation. Translating a
constraint segment to a typed `Ranges!V` and back is per-scheme:

```d
static ParseExpected!Range fromVersConstraint(string segment);  // segment → Range
static void toVersConstraint(W)(ref W w, in Range r);           // Range → segment
```

The scheme registry is built at compile time: a CTFE walk over the
`sparkles.versions.schemes.*` modules maps each scheme's `purlType` to
its struct. The registry drives two dispatch forms:

```d
/// Static dispatch when the caller knows the scheme at compile time.
template parseVersAs(SchemeStruct)
    if (isVersionScheme!SchemeStruct)
{
    ParseExpected!(SchemeStruct.Range) parseVersAs(string versUri);
}

/// Runtime dispatch on the URI's `scheme` field → AnyRange (§11).
ParseExpected!AnyRange parseVersAny(string versUri);
```

**Round-trip law.** For every scheme `S` and every native range
expression `e` that `S.parseNativeRange(e)` accepts,
`parseNativeRange(e)` → `toVersConstraint` → `fromVersConstraint` yields
a `Ranges!(S.Version)` equal to the original. The test suite asserts this
per scheme.

## 10. pURL interop

[pURL](https://github.com/package-url/purl-spec) (Package URL) names a
package across ecosystems:
`pkg:<type>/<namespace>/<name>@<version>?<qualifiers>#<subpath>`. The
`sparkles.versions.purl` module consumes purls — it parses, it does not
generate them:

```d
struct PackageUrl
{
    string type;                 // "pypi", "npm", "deb", "maven", …
    string namespace;            // optional, may contain '/'
    string name;
    string ver;                  // raw version string; not yet parsed
    string[string] qualifiers;
    string subpath;
}

ParseExpected!PackageUrl parsePurl(string s);
```

The purl `type` does not always equal the VERS scheme verbatim (e.g.
`pkg:packagist/…` maps to the `composer` scheme), so dispatch goes
through a mapping table rather than identity. Two dispatch forms mirror
§9:

```d
/// Compile-time: resolve a purl type to its scheme struct, or fail to
/// compile when no built-in scheme matches.
template schemeForPurlType(string purlType) { /* … */ }

/// Runtime: parse a purl and return an AnyVersion (§11).
ParseExpected!AnyVersion parsePurlVersion(string purlUri);
```

`parsePurlVersion` parses the URI, resolves `type` → scheme through the
mapping table, hands the raw `ver` string to that scheme's `parse`, and
wraps the result in `AnyVersion`.

## 11. `AnyVersion` / `AnyRange`

Callers that handle versions of statically-unknown scheme (purl-driven
workflows, SBOM ingestion, vulnerability matching) use the sum types in
`sparkles.versions.any`:

```d
import std.sumtype : SumType;

alias AnyVersion = SumType!(SemVer, Dmd, DmdCompact, Tiny,
    CalVerYYMM, CalVerYYYYMMDD, VimVer,
    PypiVersion, MavenVersion, DebianVersion, Generic);

alias AnyRange = SumType!(Ranges!SemVer, Ranges!Dmd, /* … one per scheme */);
```

Because there is no universal order across schemes (§6.3), cross-scheme
comparison is partial:

```d
/// Three-way compare wrapped in a Nullable!int.
/// Same scheme        → Nullable(a.opCmp(b)).
/// Differing schemes  → null (no cross-scheme order exists).
Nullable!int compareAny(in AnyVersion a, in AnyVersion b);
```

`compareAny` returning `null` is the defined contract, not a failure
mode. (Background:
[RATIONALE §5.3](./RATIONALE.md#53-no-cross-scheme-total-order).)

## 12. Public API surface

A consumer who needs a single ecosystem imports just that scheme:

```d
import sparkles.versions.schemes.semver : SemVer;
import sparkles.versions.parsing : ParseMode;
import sparkles.core_cli.parse_error : ParseError, ParseErrorCode;
```

A polyglot consumer (purl/VERS-driven) imports the package module, which
re-exports the concepts, the parse types, `Ranges`, the sum types, the
interop entry points, and every shipped scheme:

```d
import sparkles.versions;   // SemVer, PypiVersion, …, AnyVersion,
                            // Ranges, parseVersUri, parsePurl, compareAny, …
```

A scheme author — writing a new ecosystem struct in their own code —
imports the concepts and the generic range type, then asserts
conformance:

```d
import sparkles.versions.traits : isVersion, isVersionScheme,
    hasOrderKey, supportsPrerelease, hasComponents, hasSemVerComponents,
    hasBuildMetadata;
import sparkles.versions.ranges : Ranges;
import sparkles.core_cli.parse_error : ParseExpected, ParseError, ParseErrorCode;

struct MyScheme { /* … */ }
static assert(isVersion!MyScheme && isVersionScheme!MyScheme);
```

Any struct conforming to `isVersion!T` participates in every generic
algorithm; conforming additionally to `isVersionScheme!S` plugs into the
VERS and pURL layers. Static use needs no registration — the registry
(§9) discovers built-in schemes at compile time, and a user-defined
scheme is used directly through its own type.

---

→ [PLAN.md](./PLAN.md) — delivery milestones and workflow orchestration
→ [RATIONALE.md](./RATIONALE.md) — design history, prior-art, decisions, open questions
→ [PRESETS.md](./PRESETS.md) — per-scheme catalogue, examples, provenance, how-to-add-a-scheme
