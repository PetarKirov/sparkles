# Compare and sort versions

You have version strings and you need to order them: pick the latest,
sort a list, or just compare two. This guide covers parsing safely,
three-way comparison, and sorting.

It uses `SemVer`, but everything here works for any shipped scheme — swap
the import. See the [scheme catalogue](../reference/schemes.md) for the
full list.

## Parse without exceptions

`parse` returns a result, never throws. Check `.hasValue` before reading
`.value`; on failure, `.error` carries a `code` and a byte `offset`:

```d
auto bad = SemVer.parse("1.2.x");
if (!bad.hasValue)
    writeln("parse error: ", bad.error.code, " at offset ", bad.error.offset);
// → parse error: unexpectedCharacter at offset 4
```

The error codes are listed in the [concepts reference](../reference/concepts.md#parsing).

## Compare two versions

Conforming versions are totally ordered, so `<`, `<=`, `==`, `>=`, `>`
all work directly. When you want the three-way result (-1 / 0 / +1), use
`order` — it is identical to `opCmp` but takes the `orderKey` fast path
when the scheme provides one:

```d
import sparkles.versions.operations : order;

auto a = SemVer.parse("1.2.0").value;
auto b = SemVer.parse("1.2.0-rc.1").value;
writeln("order(a, b): ", order(a, b));   // 1 — a release outranks its prerelease
```

## Sort a list and take the latest

`sort` orders a slice ascending, in place, using the same ordering. The
latest version is then the last element:

```d
import sparkles.versions.operations : sort;

auto releases = [
    SemVer.parse("2.0.0").value,
    SemVer.parse("1.9.0").value,
    SemVer.parse("2.0.0-beta.1").value,
];
sort(releases);
writeln("latest: ", releases[$ - 1]);    // 2.0.0
```

`2.0.0-beta.1` sorts _before_ `2.0.0` (prerelease precedes release) and
both sort after `1.9.0`, so the stable `2.0.0` is last.

## Complete example

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "compare_and_sort"
    dependency "sparkles:versions" version="*"
+/
import std.stdio : writeln;
import sparkles.versions.schemes.semver : SemVer;
import sparkles.versions.operations : sort, order;

void main()
{
    // Handle a parse failure without exceptions.
    auto bad = SemVer.parse("1.2.x");
    if (!bad.hasValue)
        writeln("parse error: ", bad.error.code, " at offset ", bad.error.offset);

    // Three-way compare via `order`.
    auto a = SemVer.parse("1.2.0").value;
    auto b = SemVer.parse("1.2.0-rc.1").value;
    writeln("order(a, b): ", order(a, b));

    // Sort, then take the latest.
    auto releases = [
        SemVer.parse("2.0.0").value,
        SemVer.parse("1.9.0").value,
        SemVer.parse("2.0.0-beta.1").value,
    ];
    sort(releases);
    writeln("latest: ", releases[$ - 1]);
}
```

```
parse error: unexpectedCharacter at offset 4
order(a, b): 1
latest: 2.0.0
```

## Notes

- **Numeric, not lexical.** Components compare as numbers: `1.10.0` is
  greater than `1.2.0`.
- **No cross-scheme compare.** You cannot compare a `SemVer` with a
  `PypiVersion` — it does not compile. To hold mixed schemes, see
  [Handle versions of an unknown scheme](./handle-unknown-schemes.md).
- **Prerelease rule in _ranges_ is different** from plain comparison —
  see [Constrain versions with ranges](./constrain-with-ranges.md).
