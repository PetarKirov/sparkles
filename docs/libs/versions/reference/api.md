# API index

The public symbols of `sparkles:versions`, by module. This page is a
lookup table; for the concepts behind it see the
[concepts reference](./concepts.md), and for the normative definitions
the [SPEC](../../../specs/versions/SPEC.md) (§12 lists the same surface).

There are three import patterns:

- **Single scheme.** Import just the scheme module and the parse types:
  `sparkles.versions.schemes.semver : SemVer`, `sparkles.versions.parsing
: ParseMode`, `sparkles.core_cli.text.errors : ParseError`.
- **Polyglot package import.** `import sparkles.versions;` re-exports the
  concepts, parse types, `Ranges`, the operations, the VERS/pURL interop,
  the sum types, and every shipped scheme.
- **Scheme author.** Import the concepts and `Ranges` from
  `sparkles.versions.traits` / `.ranges` and the parse vocabulary from
  `sparkles.core_cli.text.errors`, then `static assert` conformance.

## `sparkles.versions`

The package module (`package.d`). Publicly re-exports `traits`,
`parsing`, `ranges`, `operations`, `vers`, `purl`, `any`, and `schemes`;
under `version(unittest)` it also re-exports `testing`.

## `sparkles.versions.traits`

The three concepts and the optional-capability vocabulary.

| Symbol                                     | Description                                                                                        |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| `isVersion!T`                              | Required version surface: three-way `opCmp` + output-range `toString`.                             |
| `isVersionRange!R`                         | Required range set-algebra basis (`empty`, `singleton`, `complement`, `intersection`, `contains`). |
| `isVersionScheme!S`                        | A version type that also carries `purlType` and a static `parse`.                                  |
| `hasOrderKey!T`                            | True when `.orderKey` is an unsigned integer (fast-path compare/sort).                             |
| `OrderKeyType!T`                           | The unsigned type `.orderKey` returns; valid only when `hasOrderKey!T`.                            |
| `supportsPrerelease!T`                     | True when `.isPrerelease` is a `bool` (gates the prerelease-in-range rule).                        |
| `hasComponents!T`                          | True when `T.components` is a non-empty `string[]` of unsigned-int field names.                    |
| `hasSemVerComponents!T`                    | True when `components` begins `["major","minor","patch"]` (gates caret/tilde).                     |
| `hasBuildMetadata!T`                       | True when `.build` is `const(char)[]`.                                                             |
| `supportsNativeRange!S`                    | True when the scheme has `parseNativeRange`.                                                       |
| `supportsLooseParse!S`                     | True when the scheme has `parseLoose`.                                                             |
| `componentCount!T`                         | `T.components.length`.                                                                             |
| `ulong componentAt(T)(in T v, size_t i)`   | The `i`-th component read as a `ulong`.                                                            |
| `int compareComponents(T)(in T a, in T b)` | Three-way compare of the component list, most-significant first.                                   |

## `sparkles.versions.parsing`

The parse-mode selector; re-exports the generic parse types from
`sparkles.core_cli.text.errors`.

| Symbol                                            | Description                                                      |
| ------------------------------------------------- | ---------------------------------------------------------------- |
| `ParseMode { strict, loose }`                     | Strict/loose selector for parsers that share one code path.      |
| `ParseError`, `ParseErrorCode`, `ParseExpected!T` | Re-exported parse vocabulary (see `core_cli.text.errors` below). |

## `sparkles.versions.ranges`

The single generic range type.

| Symbol                                                                                                  | Description                                             |
| ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `Ranges!V`                                                                                              | Sorted, disjoint interval set over any `isVersion!V`.   |
| `Ranges.empty()` / `full()`                                                                             | The empty / universal set.                              |
| `Ranges.singleton(V v)`                                                                                 | The set `{v}`.                                          |
| `complement()`, `intersection(in Ranges)`, `union_(in Ranges)`                                          | Set algebra.                                            |
| `contains(in V v)`                                                                                      | Membership test.                                        |
| `isDisjoint(in Ranges)`, `subsetOf(in Ranges)`                                                          | Derived relations.                                      |
| `higherThan(V)`, `strictlyHigherThan(V)`, `lowerThan(V)`, `strictlyLowerThan(V)`, `between(V lo, V hi)` | Interval constructors.                                  |
| `opEquals(in Ranges)`                                                                                   | Compares canonical (sorted, merged) interval sequences. |
| `void toString(W)(ref W w)`                                                                             | Emits VERS constraint syntax.                           |

## `sparkles.versions.operations`

Generic algorithms, each pairing a required-surface baseline with an
optional fast path.

| Symbol                                            | Description                                                                   |
| ------------------------------------------------- | ----------------------------------------------------------------------------- |
| `int order(T)(in T a, in T b)`                    | Three-way compare; takes the `orderKey` fast path when available.             |
| `T[] sort(T)(T[] versions)`                       | Sorts a slice ascending in place (radix when `hasOrderKey`, else comparison). |
| `bool satisfies(T)(const T v, in Ranges!T range)` | Version-in-range, with the prerelease-in-range rule when applicable.          |
| `Ranges!V caret(V)(in V v)`                       | `^v` → `[v, nextMajor)`; requires `hasSemVerComponents!V`.                    |
| `Ranges!V tilde(V)(in V v)`                       | `~v` → `[v, nextMinor)`; requires `hasSemVerComponents!V`.                    |
| `T truncateTo(string name, T)(in T v)`            | Zeroes every component below `name`; requires `hasComponents!T`.              |

## `sparkles.versions.vers`

VERS URI parsing/emission and constraint translation.

| Symbol                                                                | Description                                                               |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `VersUri { string scheme; string[] constraints; }`                    | The parsed URI surface, constraints pre-split on `\|`.                    |
| `ParseExpected!VersUri parseVersUri(string s)`                        | Parse the URI surface only (prefix, scheme, splitting, normalisation).    |
| `void formatVersUri(W)(ref W w, in VersUri v)`                        | Render constraints in stored order (scheme-agnostic, not version-sorted). |
| `ParseExpected!(Ranges!S) fromVersConstraint(S)(string segment)`      | One `<op><version>` segment → a typed `Ranges!S`.                         |
| `void toVersConstraint(S, W)(ref W w, in Ranges!S r)`                 | A `Ranges!S` → VERS constraint segments.                                  |
| `void formatVersAs(Scheme, W)(ref W w, in Ranges!(Scheme.Version) r)` | Canonical version-ordered emit under a known scheme.                      |
| `string toVersUriStringAs(Scheme)(in Ranges!(Scheme.Version) r)`      | Canonical emit to a freshly-allocated string.                             |
| `parseVersAs!(Scheme)(string versUri)`                                | Static dispatch: parse a `vers:` URI to `Scheme.Range`.                   |
| `ParseExpected!AnyRange parseVersAny(string versUri)`                 | Runtime dispatch on the URI scheme → `AnyRange`.                          |

## `sparkles.versions.purl`

Package-URL parsing and purl-type → scheme mapping. Consumes purls; does
not generate them.

| Symbol                                                                                  | Description                                                                      |
| --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `PackageUrl { string type, namespace, name, ver, subpath; string[string] qualifiers; }` | The parsed purl; `ver` is the raw, not-yet-parsed version string.                |
| `ParseExpected!PackageUrl parsePurl(string s)`                                          | Parse a `pkg:` URI into a `PackageUrl`.                                          |
| `string purlTypeToSchemeName(string purlType)`                                          | CTFE table folding purl types onto scheme names (e.g. `packagist` → `composer`). |
| `hasSchemeNameForPurlType(string purlType)`                                             | `static if`-friendly probe behind `purlTypeToSchemeName`.                        |
| `ParseExpected!AnyVersion parsePurlVersion(string purlUri)`                             | Parse a purl, resolve its type, and wrap the parsed version in `AnyVersion`.     |

## `sparkles.versions.any`

Sum types for statically-unknown schemes, and partial comparison.

| Symbol                                                      | Description                                                                |
| ----------------------------------------------------------- | -------------------------------------------------------------------------- |
| `AnyVersion`                                                | `SumType` over every shipped scheme version.                               |
| `AnyRange`                                                  | `SumType` over `Ranges!S` for every shipped scheme.                        |
| `Nullable!int compareAny(in AnyVersion a, in AnyVersion b)` | Three-way compare; `null` across differing schemes (the defined contract). |

## `sparkles.versions.schemes`

Re-exports every scheme struct and the compile-time registry.

| Symbol                                      | Description                                                                 |
| ------------------------------------------- | --------------------------------------------------------------------------- |
| `schemeForPurlType!(string purlType)`       | Resolve a published pURL type to its scheme struct (compile error if none). |
| `hasSchemeForPurlType!(string purlType)`    | `static if`-friendly probe for the above.                                   |
| `allSchemes`                                | `AliasSeq` of every scheme, internal compact schemes included.              |
| `publishedSchemes`                          | `allSchemes` filtered to those with a real published pURL type.             |
| `publishedPurlTypes`                        | The `string[]` of published pURL types.                                     |
| `publishedSchemeEntries`, `SchemePurlEntry` | The published purl-type → scheme entry list used by dispatch.               |

Each scheme submodule exports one struct conforming to `isVersion!T` and
`isVersionScheme!S`. See the [scheme catalogue](./schemes.md) for the
per-scheme detail (pURL type, examples, ordering rules, capabilities,
native-range grammar, provenance).

| Module                                      | Struct           |
| ------------------------------------------- | ---------------- |
| `sparkles.versions.schemes.semver`          | `SemVer`         |
| `sparkles.versions.schemes.dmd`             | `Dmd`            |
| `sparkles.versions.schemes.dmd_compact`     | `DmdCompact`     |
| `sparkles.versions.schemes.tiny`            | `Tiny`           |
| `sparkles.versions.schemes.calver_yymm`     | `CalVerYYMM`     |
| `sparkles.versions.schemes.calver_yyyymmdd` | `CalVerYYYYMMDD` |
| `sparkles.versions.schemes.vim`             | `VimVer`         |
| `sparkles.versions.schemes.pypi`            | `PypiVersion`    |
| `sparkles.versions.schemes.maven`           | `MavenVersion`   |
| `sparkles.versions.schemes.deb`             | `DebianVersion`  |
| `sparkles.versions.schemes.generic`         | `Generic`        |

A conforming scheme provides `alias Version`, `alias Range = Ranges!S`,
`enum string purlType`, and `static ParseExpected!S parse(string)`;
optionally `parseLoose` and `parseNativeRange`.

## `sparkles.versions.testing`

Re-exported only under `version(unittest)`. Test helpers such as
`checkParse` and `checkRoundTrip`.

## `sparkles.core_cli.text.errors`

The generic, `@nogc` parse vocabulary reused by every core_cli text
parser.

| Symbol                                               | Description                                                                                                                                              |
| ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ParseErrorCode`                                     | Enum of failure kinds (`emptyInput`, `unexpectedCharacter`, `unexpectedEnd`, `leadingZero`, `numericOverflow`, `invalidIdentifier`, `widthMismatch`, …). |
| `ParseError { ParseErrorCode code; size_t offset; }` | A structured failure with a byte offset.                                                                                                                 |
| `ParseExpected!T`                                    | `Expected!(T, ParseError, …)`: either a parsed `T` or a `ParseError`.                                                                                    |

## `sparkles.core_cli.text.readers`

Slice-advance parser primitives (`@nogc`); useful when hand-writing a
scheme's `parse`.

| Symbol                                                                           | Description                                                    |
| -------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `ParseExpected!T readInteger(T)(ref scope const(char)[] s)`                      | Read an unsigned integer of type `T`, advancing the slice.     |
| `size_t skipWhile(alias pred)(ref scope const(char)[] s)`                        | Skip leading chars matching `pred`; returns the count skipped. |
| `bool tryConsume(ref scope const(char)[] s, char c)`                             | Consume `c` if present; report whether it was.                 |
| `bool tryConsumeAny(ref scope const(char)[] s, scope const(char)[] set)`         | Consume one char from `set` if present.                        |
| `const(char)[] readUntil(ref scope const(char)[] s, scope const(char)[] delims)` | Take chars up to the first delimiter, advancing the slice.     |

## `sparkles.core_cli.text.writers`

Integer-formatting primitives (`@nogc`); useful when hand-writing a
scheme's `toString`.

| Symbol                                                                            | Description                                           |
| --------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `void writeInteger(Writer, T)(ref Writer w, const T val)`                         | Write an integer into an output range.                |
| `void writeIntegerPadded(Writer, T)(ref Writer w, const T val, size_t minDigits)` | Write an integer zero-padded to at least `minDigits`. |

## See also

- [Concepts](./concepts.md) — the concepts and capability vocabulary in
  prose.
- [Scheme catalogue](./schemes.md) — per-scheme detail.
- [The design](../explanation/design.md) — why the surface is shaped this
  way.
- [SPEC](../../../specs/versions/SPEC.md) — the normative specification.
