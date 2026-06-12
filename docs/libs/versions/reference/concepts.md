# Concepts and API

_Information-oriented. A lookup page for the three compile-time concepts,
the optional capability vocabulary, parsing, and pURL interop. It is
deliberately terse and defers to the normative
[SPEC](../../../specs/versions/SPEC.md) for full detail; for per-scheme
specifics see [the scheme catalogue](./schemes.md), for the symbol index
see [the API index](./api.md), and for the reasoning behind the design
see the [explanation](../explanation/design.md) pages._

The library rests on three concepts, all in `sparkles.versions.traits`:
`isVersion!T` (a value), `isVersionRange!R` (a set of values), and
`isVersionScheme!S` (the handle that parses an ecosystem's strings).
Optional capabilities layer on top, each independently detectable.

## The Version concept

A version is _totally ordered and renders to text_ — nothing else is
required. `isVersion!T` checks for a three-way `opCmp` and an
output-range `toString`:

```d
int  opCmp(in T other) const @safe pure nothrow @nogc;  // three-way order
void toString(W)(ref W sink) const;                      // into an output range
```

Conforming types should also provide `opEquals` and `toHash` consistent
with `opCmp`, so versions work as `==` operands and associative-array
keys.

Full detail:
[SPEC §3.1](../../../specs/versions/SPEC.md#31-required-surface--isversiont).
For _why_ the contract is this small, see
[the design](../explanation/design.md).

### Optional capability vocabulary

A type that provides a capability enables a fast path or an extra
feature; a type that omits one still works through the required surface.
Each capability is governed by two rules — it must hold for _every_ value
of the type (all-or-nothing), and its fast path must agree with the
required-surface fallback (equivalence).

| Capability              | Detection rule                                   | Behavioural impact                                              |
| ----------------------- | ------------------------------------------------ | --------------------------------------------------------------- |
| `hasOrderKey!T`         | `.orderKey` → any unsigned int (`ubyte`…`ulong`) | radix `sort`, compact `Ranges!T` bounds, fast `opCmp` pre-check |
| `supportsPrerelease!T`  | `.isPrerelease` → `bool`                         | prerelease-in-range rule (gates `satisfies`)                    |
| `hasComponents!T`       | `enum string[] components` of named uint fields  | generic component iteration/compare, `truncateTo`               |
| `hasSemVerComponents!T` | `components` begins `["major","minor","patch"]`  | caret `^` / tilde `~` range operators                           |
| `hasBuildMetadata!T`    | `.build` → `const(char)[]`                       | build-aware compare                                             |

`OrderKeyType!T` is the unsigned integer type `T.orderKey` returns (valid
only when `hasOrderKey!T`); generic code reads it back to size compact
key storage. The component list drives three helpers schemes reuse:
`compareComponents(a, b)`, `componentAt(v, i)`, and `componentCount!T`.

Schemes also carry two scheme-level capabilities (see
[the Scheme concept](#the-scheme-concept)):

| Capability              | Detection rule                                                 | Behavioural impact                         |
| ----------------------- | -------------------------------------------------------------- | ------------------------------------------ |
| `supportsNativeRange!S` | `.parseNativeRange("")` → `ParseExpected!(Ranges!(S.Version))` | parse the ecosystem's native range grammar |
| `supportsLooseParse!S`  | `.parseLoose("")` → `ParseExpected!(S.Version)`                | accept compatibility forms (`v1.2`, `1`)   |

`Generic` is the baseline scheme with _none_ of the optional
capabilities, so every fallback path is exercised against it.

Full detail:
[SPEC §3.2](../../../specs/versions/SPEC.md#32-optional-capability-vocabulary).
Which scheme has which capability is tabulated in
[the scheme catalogue](./schemes.md); the required/optional split is
explained in [the design](../explanation/design.md).

## The Range concept

A range is a _set of versions_ expressed as set algebra. `isVersionRange!R`
requires an associated `R.Version` (itself `isVersion`) plus five
set-algebra members; four more are derived by default via De Morgan and
need not be hand-written:

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

`Ranges!V` (in `sparkles.versions.ranges`) is the single concrete
implementation — a sorted, disjoint interval sequence; each scheme's
`Range` alias is `Ranges!ThatVersion`. Its `toString` emits VERS
constraint syntax.

Full detail:
[SPEC §4](../../../specs/versions/SPEC.md#4-the-range-concept).

## The Scheme concept

A scheme is the handle the library parses through and identifies by pURL
type. The struct is both the version value _and_ the scheme handle.
`isVersionScheme!S` requires an associated `S.Version` (itself
`isVersion`), a non-empty `purlType`, and a `parse`:

```d
alias Version = S;                          // usually the struct itself
alias Range   = Ranges!S;
enum string purlType = "semver";            // non-empty pURL type string
static ParseExpected!S parse(string s);     // exact-syntax parser
```

`purlType` must be non-empty. Internal schemes without a published
Package-URL type declare a synthetic, scheme-named `purlType` (e.g.
`"dmd"`); these are _not_ published types, so the purl→scheme registry
never resolves them. Cross-scheme comparison does not compile — there is
no shared `opCmp` across distinct scheme types.

Full detail:
[SPEC §6](../../../specs/versions/SPEC.md#6-the-scheme-concept). For why
cross-scheme order is impossible, see
[no cross-scheme order](../explanation/cross-scheme-policy.md).

## Parsing

Parsing is non-throwing and `Expected`-based. The error vocabulary is
generic and lives in `sparkles.base.text.errors`; `ParseMode` is a
versions enum in `sparkles.versions.parsing`.

```d
struct ParseError
{
    ParseErrorCode code;  // what went wrong
    size_t offset;        // byte offset of the failure within the input
}

alias ParseExpected(T) = Expected!(T, ParseError, NoGcHook);

enum ParseMode { strict, loose }
```

`ParseExpected!T` carries either a parsed `T` or a `ParseError`. Branch
on `result.hasValue`, then read `result.value` or `result.error`.

`ParseErrorCode` values:

| Code                  | Meaning                                 |
| --------------------- | --------------------------------------- |
| `emptyInput`          | the input was empty                     |
| `unexpectedCharacter` | a character not allowed at that point   |
| `unexpectedEnd`       | input ended before the parse completed  |
| `leadingZero`         | a disallowed leading zero               |
| `numericOverflow`     | a numeric component overflowed          |
| `invalidIdentifier`   | a malformed identifier                  |
| `widthMismatch`       | a fixed-width component had wrong width |

The three parse entry points across the concepts:

| Function                | Concept                 | Required? | Behaviour                                                        |
| ----------------------- | ----------------------- | --------- | ---------------------------------------------------------------- |
| `S.parse(s)`            | `isVersionScheme!S`     | required  | exact canonical syntax → `ParseExpected!(S.Version)`             |
| `S.parseLoose(s)`       | `supportsLooseParse!S`  | optional  | also accept `v`-prefix and missing trailing components           |
| `S.parseNativeRange(s)` | `supportsNativeRange!S` | optional  | the ecosystem's native range grammar → `ParseExpected!(S.Range)` |

Full detail:
[SPEC §7](../../../specs/versions/SPEC.md#7-parsing).

## pURL interop

`sparkles.versions.purl` _consumes_ Package URLs — it parses, it does not
generate them. `parsePurl(string)` returns a `ParseExpected!PackageUrl`
whose `ver` field is the raw, not-yet-parsed version string.

Dispatch from a purl to a scheme goes through a mapping table rather than
identity, because the purl `type` does not always equal the scheme name
(e.g. `pkg:packagist/…` maps to the `composer` scheme):

```d
// sparkles.versions.purl — fold a purl type onto a scheme name
// (npm/cargo/gem/… → "semver"; pypi/maven/deb → their own).
string purlTypeToSchemeName(string purlType);

// sparkles.versions.schemes.registry — resolve a scheme name to its
// scheme struct at compile time.
template schemeForPurlType(string purlType) { /* … */ }

// sparkles.versions.purl — runtime: parse a purl, dispatch, return AnyVersion.
ParseExpected!AnyVersion parsePurlVersion(string purlUri);
```

`parsePurlVersion` parses the URI, resolves `type` → scheme through the
table, hands the raw `ver` to that scheme's `parse`, and wraps the result
in `AnyVersion` (the sum type over every shipped scheme; cross-scheme
comparison is the partial `compareAny`, which returns `null` across
differing schemes).

Full detail:
[SPEC §10](../../../specs/versions/SPEC.md#10-purl-interop) and
[SPEC §11](../../../specs/versions/SPEC.md#11-anyversion--anyrange). For
the recipe-level walkthrough, see
[interoperate with VERS and pURL](../how-to/vers-and-purl-interop.md).
