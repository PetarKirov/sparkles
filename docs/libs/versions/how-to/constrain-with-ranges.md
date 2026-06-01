# Constrain versions with ranges

A _range_ is a set of versions. This guide shows how to build ranges
three ways — from a native range string, from caret/tilde shorthands, and
explicitly — and how the prerelease-in-range rule affects membership.

Ranges are `Ranges!V` values; you test membership with `satisfies`. The
examples use `SemVer`; the [scheme catalogue](../reference/schemes.md)
notes each scheme's native-range grammar.

## Parse the ecosystem's native range grammar

`parseNativeRange` reads the scheme's own syntax. For SemVer that is the
node-semver grammar: comparators (`>=`, `<`, …), AND-by-space, unions
with `||`, hyphen ranges, and wildcards:

```d
auto r = SemVer.parseNativeRange(">=1.2.0 <2.0.0").value;
writeln("1.5.0 in >=1.2.0 <2.0.0: ", v("1.5.0").satisfies(r));   // true
writeln("2.0.0 in >=1.2.0 <2.0.0: ", v("2.0.0").satisfies(r));   // false
```

(`v` here is a tiny helper, `auto v(string s) => SemVer.parse(s).value;`,
used to keep the examples short.)

## Caret and tilde

`caret` and `tilde` desugar the npm shorthands directly from a version,
without going through the string grammar. They are gated on the SemVer
triple at compile time, so they are only available on SemVer-shaped
schemes:

```d
import sparkles.versions.operations : caret, tilde;

auto c = caret(v("1.2.3"));   // ^1.2.3 → [1.2.3, 2.0.0)  (compatible within major)
auto t = tilde(v("1.2.3"));   // ~1.2.3 → [1.2.3, 1.3.0)  (compatible within minor)
writeln("1.9.9 in ^1.2.3: ", v("1.9.9").satisfies(c));   // true
writeln("1.3.0 in ~1.2.3: ", v("1.3.0").satisfies(t));   // false — 1.3.0 is the exclusive upper bound
```

## The prerelease-in-range rule

This is the rule that surprises people. A **prerelease only satisfies a
range when some comparator in that range names a prerelease of the same
`major.minor.patch` triple.** A prerelease is _not_ admitted just because
it falls numerically inside the interval:

```d
auto stable = SemVer.parseNativeRange(">=1.2.0").value;
writeln("1.3.0-beta.1 in >=1.2.0: ", v("1.3.0-beta.1").satisfies(stable));
// → false: 1.3.0-beta.1 is numerically ≥ 1.2.0, but no comparator names a 1.3.0 prerelease

auto withPre = SemVer.parseNativeRange(">=1.2.0-alpha").value;
writeln("1.2.0-beta in >=1.2.0-alpha: ", v("1.2.0-beta").satisfies(withPre));
// → true: the comparator names a prerelease of the same 1.2.0 triple
```

This matches node-semver. For _why_ it works this way, see
[Prerelease in ranges](../explanation/prerelease-in-range.md). The rule
is statically inert for schemes that do not model prereleases (e.g.
`Tiny`, `Generic`), where `satisfies` is just membership.

## Complete example

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "constrain_with_ranges"
    dependency "sparkles:versions" version="*"
+/
import std.stdio : writeln;
import sparkles.versions.schemes.semver : SemVer;
import sparkles.versions.operations : satisfies, caret, tilde;

void main()
{
    auto v(string s) => SemVer.parse(s).value;

    // Native npm range grammar.
    auto r = SemVer.parseNativeRange(">=1.2.0 <2.0.0").value;
    writeln("1.5.0 in >=1.2.0 <2.0.0: ", v("1.5.0").satisfies(r));
    writeln("2.0.0 in >=1.2.0 <2.0.0: ", v("2.0.0").satisfies(r));

    // Caret and tilde desugarings, built directly from a version.
    auto c = caret(v("1.2.3"));   // [1.2.3, 2.0.0)
    auto t = tilde(v("1.2.3"));   // [1.2.3, 1.3.0)
    writeln("1.9.9 in ^1.2.3: ", v("1.9.9").satisfies(c));
    writeln("1.3.0 in ~1.2.3: ", v("1.3.0").satisfies(t));

    // Prerelease-in-range rule.
    auto stable = SemVer.parseNativeRange(">=1.2.0").value;
    writeln("1.3.0-beta.1 in >=1.2.0: ", v("1.3.0-beta.1").satisfies(stable));
    auto withPre = SemVer.parseNativeRange(">=1.2.0-alpha").value;
    writeln("1.2.0-beta in >=1.2.0-alpha: ", v("1.2.0-beta").satisfies(withPre));
}
```

```
1.5.0 in >=1.2.0 <2.0.0: true
2.0.0 in >=1.2.0 <2.0.0: false
1.9.9 in ^1.2.3: true
1.3.0 in ~1.2.3: false
1.3.0-beta.1 in >=1.2.0: false
1.2.0-beta in >=1.2.0-alpha: true
```

## Notes

- **Ranges are sets.** `Ranges!V` supports `intersection`, `union_`,
  `complement`, `contains`, and the derived `isDisjoint` / `subsetOf` —
  the full set algebra. See the [concepts reference](../reference/concepts.md#the-range-concept).
- **One range type for every scheme.** There is no `NpmRange` or
  `PypiRange`; a scheme's range is just `Ranges!ThatVersion`. What differs
  is the _native grammar_ each scheme parses.
- **Emit as VERS.** A range's `toString` produces VERS constraint syntax;
  see [VERS and pURL interop](./vers-and-purl-interop.md).
