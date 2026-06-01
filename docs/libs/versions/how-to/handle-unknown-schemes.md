# Handle versions of an unknown scheme

When versions arrive from purls or an SBOM, you may not know the scheme
at compile time — one row is PyPI, the next is npm, the next Debian. The
sum types `AnyVersion` and `AnyRange` (in `sparkles.versions.any`) hold a
version of _any_ shipped scheme, and `compareAny` compares them safely.

## Hold a version of any scheme

`parsePurlVersion` and `parseVersAny` already return these sum types, so
you get an `AnyVersion` without choosing a scheme yourself:

```d
auto a = parsePurlVersion("pkg:pypi/django@3.13.0a1").value;  // AnyVersion
```

## Compare safely with `compareAny`

There is **no universal order across schemes** — see
[No cross-scheme order](../explanation/cross-scheme-policy.md). So
`compareAny` is _partial_: it returns a `Nullable!int` that holds a
three-way result when both operands are the same scheme, and is `null`
when they differ. The `null` is the defined contract, not an error:

```d
auto b = parsePurlVersion("pkg:pypi/django@4.0.0").value;
auto same = compareAny(a, b);
writeln("same-scheme compare null? ", same.isNull);     // false
if (!same.isNull)
    writeln("  3.13.0a1 vs 4.0.0: ", same.get);          // -1

auto c = parsePurlVersion("pkg:npm/leftpad@1.3.0").value;
writeln("cross-scheme compare null? ", compareAny(a, c).isNull);  // true
```

This is why you cannot accidentally mis-order an SBOM: a PyPI version and
an npm version simply have no ordering, and the API makes you handle that
`null` explicitly.

## Recover the concrete type

When you need scheme-specific behaviour, `match` on the sum type to get
the concrete struct back (this is `std.sumtype.match`):

```d
import std.sumtype : match;

a.match!(v => writeln("a is a ", typeof(v).stringof));   // a is a PypiVersion
```

A `match` with one handler per scheme lets you branch per ecosystem;
a generic `match!(v => …)` handler runs the same generic code (`order`,
`satisfies`, `toString`) against whichever type is inside.

## Complete example

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "unknown_schemes"
    dependency "sparkles:versions" version="*"
+/
import std.stdio : writeln;
import std.sumtype : match;
import sparkles.versions;

void main()
{
    // Two versions of the same scheme, arriving as purls.
    auto a = parsePurlVersion("pkg:pypi/django@3.13.0a1").value;
    auto b = parsePurlVersion("pkg:pypi/django@4.0.0").value;

    // compareAny is partial: same scheme → a real ordering...
    auto same = compareAny(a, b);
    writeln("same-scheme compare null? ", same.isNull);
    if (!same.isNull)
        writeln("  3.13.0a1 vs 4.0.0: ", same.get);

    // ...different schemes → null (no cross-scheme order exists).
    auto c = parsePurlVersion("pkg:npm/leftpad@1.3.0").value;
    writeln("cross-scheme compare null? ", compareAny(a, c).isNull);

    // Recover the concrete type when you need scheme-specific logic.
    a.match!(v => writeln("a is a ", typeof(v).stringof));
}
```

```
same-scheme compare null? false
  3.13.0a1 vs 4.0.0: -1
cross-scheme compare null? true
a is a PypiVersion
```

## Notes

- **`AnyRange`** is the analogous sum over `Ranges!Scheme` for every
  scheme; `parseVersAny` returns it.
- **Why partial and not a total fallback order?** A single universal
  comparator is silently wrong on exactly the schemes that differ most
  (Debian epochs, PEP 440 local versions, Maven qualifiers). The
  reasoning is in
  [No cross-scheme order](../explanation/cross-scheme-policy.md).
