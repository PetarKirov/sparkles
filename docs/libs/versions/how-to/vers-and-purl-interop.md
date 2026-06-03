# Interoperate with VERS and pURL

[pURL](https://github.com/package-url/purl-spec) (Package URL) names a
package across ecosystems; [VERS](https://github.com/package-url/vers-spec)
is a URI for a version range. This guide shows how to go from those wire
formats to typed values and back: parse a purl and type its version,
parse a `vers:` URI into a range, and emit a range as a canonical VERS
string.

These entry points come from the package module, so a single
`import sparkles.versions;` brings them all in.

## pURL → a typed version

A purl looks like `pkg:pypi/django@3.13.0a1`. `parsePurlVersion` parses
the URI, resolves the `type` to the right scheme through the
[purl→scheme table](../reference/concepts.md#purl-interop), hands the raw
version to that scheme's `parse`, and returns an
[`AnyVersion`](./handle-unknown-schemes.md). Match on it to recover the
concrete type:

```d
import std.sumtype : match;

auto pv = parsePurlVersion("pkg:pypi/django@3.13.0a1");
pv.value.match!(v => writeln("typed as ", typeof(v).stringof, ": ", v));
// → typed as PypiVersion: 3.13.0a1
```

If you only need the URI fields (not a typed version), `parsePurl`
returns the raw surface — `type`, `namespace`, `name`, `ver`,
`qualifiers`, `subpath` — without consulting any scheme:

```d
auto p = parsePurl("pkg:pypi/django@3.13.0a1").value;
writeln("type=", p.type, " name=", p.name, " ver=", p.ver);
// → type=pypi name=django ver=3.13.0a1
```

Note `pkg:npm/...`, `pkg:cargo/...`, and friends all resolve to the
`semver` scheme — the purl `type` is the dispatch key, and many ecosystem
types share the SemVer value grammar.

## VERS → a typed range

A VERS URI is `vers:<scheme>/<constraint>|<constraint>|…`.
`parseVersAny` dispatches on the scheme and returns an
[`AnyRange`](./handle-unknown-schemes.md):

```d
auto va = parseVersAny("vers:npm/>=1.2.0|<2.0.0");
writeln("parseVersAny ok: ", va.hasValue);   // true
```

When you know the scheme at compile time, `parseVersAs!Scheme` returns
the concrete `Ranges!(Scheme.Version)` directly. If you only need the URI
surface — the scheme label and the raw, un-typed constraint list — use
`parseVersUri`.

## A range → a canonical VERS string

`toVersUriStringAs!Scheme` renders a range to VERS text. Because a
`Ranges!V` is a sorted, disjoint interval list, the output is
**version-ordered** (canonical), and the disjoint intervals are joined
with `|`:

```d
auto a = Ranges!SemVer.singleton(SemVer.parse("9.0.0").value);
auto b = Ranges!SemVer.singleton(SemVer.parse("10.0.0").value);
writeln("emitted: ", toVersUriStringAs!SemVer(a.union_(b)));
// → emitted: vers:semver/9.0.0|10.0.0   (canonical version order)
```

## Complete example

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "vers_and_purl"
    dependency "sparkles:versions" version="*"
+/
import std.stdio : writeln;
import std.sumtype : match;
import sparkles.versions;

void main()
{
    // pURL → typed version. parsePurlVersion parses the URI, resolves the
    // `type` to a scheme, and parses the version with it.
    auto pv = parsePurlVersion("pkg:pypi/django@3.13.0a1");
    pv.value.match!(v =>
        writeln("typed as ", typeof(v).stringof, ": ", v));

    // The raw URI surface, when you only need the fields.
    auto p = parsePurl("pkg:pypi/django@3.13.0a1").value;
    writeln("type=", p.type, " name=", p.name, " ver=", p.ver);

    // VERS → typed range. parseVersAny dispatches on the URI's scheme.
    auto va = parseVersAny("vers:npm/>=1.2.0|<2.0.0");
    writeln("parseVersAny ok: ", va.hasValue);

    // Range → canonical VERS string, version-ordered.
    auto a = Ranges!SemVer.singleton(SemVer.parse("9.0.0").value);
    auto b = Ranges!SemVer.singleton(SemVer.parse("10.0.0").value);
    writeln("emitted: ", toVersUriStringAs!SemVer(a.union_(b)));
}
```

```[Output]
typed as PypiVersion: 3.13.0a1
type=pypi name=django ver=3.13.0a1
parseVersAny ok: true
emitted: vers:semver/9.0.0|10.0.0
```

## Notes

- **The library consumes purls; it does not emit them.** There is no
  `formatPurl` — `parsePurl` is parse-only by design.
- **Schemes without a published purl type** (the D-internal `Dmd`,
  `Tiny`, CalVer, … schemes) are never reached by purl dispatch; the
  registry maps only real ecosystem types. See
  [the concepts reference](../reference/concepts.md#the-scheme-concept).
- **Unknown scheme?** `parsePurlVersion` and `parseVersAny` return sum
  types precisely so you can handle a statically-unknown scheme — see
  [Handle versions of an unknown scheme](./handle-unknown-schemes.md).
