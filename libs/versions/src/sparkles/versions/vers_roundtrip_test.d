/**
The VERS round-trip law (SPEC §9), exercised per scheme over a fixture corpus
drawn from the [`univers`](https://github.com/aboutcode-org/univers) test
suite.

For every scheme `S` that
$(REF supportsNativeRange, sparkles,versions,traits) and every native range
expression `e` that `S.parseNativeRange(e)` accepts, the law is:

```
parseNativeRange(e)               // a Ranges!(S.Version)
    -> toVersUriStringAs!S        // canonical vers: URI (every comparator `|`-joined)
    -> parseVersAs!S              // back to a Ranges!(S.Version)
```

yields a `Ranges!(S.Version)` equal to the original. Because `Ranges.opEquals`
compares the canonical (sorted, merged) interval representation, equality is
the right notion: two ranges built from different but semantically-equivalent
texts compare equal.

`toVersUriStringAs` emits the canonical `vers:` grammar — `|` between every
comparator, so a bounded interval `[lo, hi)` is `>=lo|<hi` — and `parseVersAs`
re-folds the flat `|`-separated comparator list into the same contiguous
intervals (SPEC §9 multi-constraint semantics), closing the loop.

The corpus mirrors fixtures from the
[`univers`](https://github.com/aboutcode-org/univers) test suite
(`tests/data/schema/range/` npm/pypi `*_range_from_native.json`) and the
per-scheme native-range tests, restricted to expressions whose semantics
match ours.

See `docs/specs/versions/SPEC.md` §9 (VERS interop, the round-trip law).
*/
module sparkles.versions.vers_roundtrip_test;

version (unittest):

import sparkles.versions.traits : isVersionScheme, supportsNativeRange;
import sparkles.versions.vers : parseVersAs, toVersUriStringAs;

// ---------------------------------------------------------------------------
// Round-trip harness
// ---------------------------------------------------------------------------

/// Asserts the VERS round-trip law for one native range expression `e` of
/// scheme `S`: `parseNativeRange(e)` survives a `toVersUriStringAs` →
/// `parseVersAs!S` round-trip unchanged.
private void checkVersRoundTrip(S)(
    string e, string file = __FILE__, size_t line = __LINE__,
) @safe
if (isVersionScheme!S && supportsNativeRange!S)
{
    import core.exception : AssertError;
    import sparkles.base.lifetime : recycledErrorInstance;

    void fail(in char[] msg) @trusted
    {
        throw recycledErrorInstance!AssertError(msg, file, line);
    }

    auto native = S.parseNativeRange(e);
    if (!native.hasValue)
        fail("parseNativeRange rejected the corpus expression: " ~ e);

    const original = native.value;

    // Emit the canonical `vers:` URI (every comparator `|`-joined) and parse
    // the emitted text straight back. The full set spells `*`; the empty set
    // has no canonical literal — both are exercised through their explicit
    // forms elsewhere, so the corpus avoids them.
    const uri = toVersUriStringAs!S(original);

    auto back = parseVersAs!S(uri);
    if (!back.hasValue)
        fail("parseVersAs rejected the round-tripped URI: " ~ uri);

    if (back.value != original)
        fail("round-trip mismatch for: " ~ e ~ " (via " ~ uri ~ ")");
}

// ---------------------------------------------------------------------------
// semver — node-semver native grammar (^/~/>=/hyphen/||)
// ---------------------------------------------------------------------------

@("vers.roundTrip.semver")
@safe
unittest
{
    import sparkles.versions.schemes.semver : SemVer;

    // node-semver expressions whose desugared interval set has a faithful
    // VERS form. (Caret/tilde/x-ranges all desugar to plain intervals.)
    static immutable corpus = [
        ">=4.1.0",
        ">=2.0.0 <=4.0.4",
        "<0.0.0",
        "<=99.999.99999",
        ">=2.11.2",
        "<2.11.2",
        "<=0.6.2",
        "^1.2.0",
        "~1.2.3",
        "1.2.x",
        "1.x",
        ">=1.2.0 <2.0.0",
        "1.2.3 - 1.5.7",
        "^1.2.0 || ^2.0.0",
        ">=1.0.0 <1.5.0 || >=2.0.0",
        "=1.2.0",
        "1.2.0",
    ];
    foreach (e; corpus)
        checkVersRoundTrip!SemVer(e);
}

// ---------------------------------------------------------------------------
// pypi — PEP 440 specifier sets (>=/</~=/==x.*/!=)
// ---------------------------------------------------------------------------

@("vers.roundTrip.pypi")
@safe
unittest
{
    import sparkles.versions.schemes.pypi : PypiVersion;

    // PEP 440 specifier-set expressions. `~=` and `==x.*` desugar to bounded
    // intervals; `!=` punches a hole; comma-AND tightens to a sub-interval.
    static immutable corpus = [
        ">= 1.0",
        "<2.1.0",
        ">=1.2.4",
        ">=1.2.4,<2",
        "~=1.4.5",
        "==1.4.*",
        "==1.2.3",
        "<2.0",
        ">1.0",
        "<=2.0",
        ">=1.0,<2.0",
    ];
    foreach (e; corpus)
        checkVersRoundTrip!PypiVersion(e);
}

// ---------------------------------------------------------------------------
// maven — bracket intervals ([1.0], (,1.0], [1.0,2.0), …)
// ---------------------------------------------------------------------------

@("vers.roundTrip.maven")
@safe
unittest
{
    import sparkles.versions.schemes.maven : MavenVersion;

    // Maven interval notation. Each desugars to a single interval that the
    // VERS comparator form reproduces.
    static immutable corpus = [
        "[1.0]",
        "(,1.0]",
        "[1.0,)",
        "[1.0,2.0)",
        "(1.0,2.0)",
        "[1.0,2.0]",
        "(1.0,)",
        "(,2.0)",
    ];
    foreach (e; corpus)
        checkVersRoundTrip!MavenVersion(e);
}

// ---------------------------------------------------------------------------
// deb — dpkg relations (>=, >>, <=, <<, =)
// ---------------------------------------------------------------------------

@("vers.roundTrip.deb")
@safe
unittest
{
    import sparkles.versions.schemes.deb : DebianVersion;

    // Single dpkg version relations. Each is one comparator → one interval.
    static immutable corpus = [
        ">= 2.0",
        ">> 2.0",
        "<= 3.0",
        "<< 3.0",
        "= 1.2.3-4",
        ">= 2:4.13.1-0ubuntu0.16.04.1.1~",
    ];
    foreach (e; corpus)
        checkVersRoundTrip!DebianVersion(e);
}

// ---------------------------------------------------------------------------
// Mechanical per-scheme coverage — every native-range scheme in the registry.
//
// The hand-written corpora above pin down the tricky ecosystem grammars
// (npm caret/tilde, PEP 440, Maven brackets, dpkg relations). To guarantee
// the round-trip law holds for EVERY scheme that supportsNativeRange — not
// just the four spelled out above — walk the registry's `allSchemes` list and
// round-trip a small per-scheme corpus of native range expressions. The
// corpus is selected by purlType so each scheme gets version literals valid
// under its own grammar (e.g. dmd's 3-digit minor, vim's 4-digit patch,
// CalVer's zero-padded month/day).
// ---------------------------------------------------------------------------

/// Native-range corpus for scheme `S`, chosen by `S.purlType` so the version
/// literals are valid under that scheme's grammar. All schemes here parse npm
/// range syntax (`>=v`, `>=a <=b`, …) via `parseNpmRange`.
private string[] nativeRangeCorpus(string purlType) @safe pure nothrow
{
    switch (purlType)
    {
    case "semver":
        return [">=1.2.0", ">=1.2.0 <2.0.0", "<2.0.0", "=1.2.0"];
    case "dmd":
    case "dmd_compact":
        return [">=2.079.0", ">=2.079.0 <2.111.0", "<2.111.0", "=2.111.0"];
    case "tiny":
        return [">=1.2.3", ">=1.2.3 <2.0.0", "<7.8.9", "=100.50.25"];
    case "vim":
        return [">=9.1.0400", ">=9.1.0400 <9.2.0001", "<9.2.0001", "=9.1.0400"];
    case "calver_yymm":
        return [">=24.04.1", ">=24.04.1 <25.04.1", "<25.04.1", "=24.10.1"];
    case "calver_yyyymmdd":
        return [
            ">=2024.05.01", ">=2024.05.01 <2025.01.01",
            "<2025.01.01", "=2024.06.01",
        ];
    case "pypi":
        return [">=1.0", ">=1.0,<2.0", "<2.0", "==1.2.3"];
    case "maven":
        return ["[1.0]", "[1.0,2.0)", "(,2.0)", "[1.0,)"];
    case "deb":
        return [">= 2.0", ">> 2.0", "<< 3.0", "= 1.2.3-4"];
    default:
        return [];
    }
}

@("vers.roundTrip.allNativeRangeSchemes")
@safe
unittest
{
    import core.exception : AssertError;
    import sparkles.base.lifetime : recycledErrorInstance;
    import sparkles.versions.vers : allSchemes;

    void fail(in char[] msg) @trusted
    {
        throw recycledErrorInstance!AssertError(msg);
    }

    static foreach (S; allSchemes)
        static if (supportsNativeRange!S)
        {{
            const corpus = nativeRangeCorpus(S.purlType);
            // Every native-range scheme must contribute a corpus: a missing
            // entry (empty list) is a coverage gap, flagged mechanically.
            if (corpus.length == 0)
                fail("no native-range corpus for scheme " ~ S.purlType);
            foreach (e; corpus)
                checkVersRoundTrip!S(e);
        }}
}

// ---------------------------------------------------------------------------
// Canonical vers: string round-trip — parseVersUri → formatVersUri identity
// after normalisation (sorted + deduped + space-stripped constraints).
// ---------------------------------------------------------------------------

@("vers.roundTrip.canonicalUriIdentity")
@safe
unittest
{
    import core.exception : AssertError;
    import sparkles.base.lifetime : recycledErrorInstance;
    import sparkles.versions.vers : parseVersUri, toVersUriString;

    void check(string canonical, string file = __FILE__, size_t line = __LINE__) @safe
    {
        void fail(in char[] msg) @trusted
        {
            throw recycledErrorInstance!AssertError(msg, file, line);
        }

        auto parsed = parseVersUri(canonical);
        if (!parsed.hasValue)
            fail("parseVersUri rejected a canonical URI: " ~ canonical);
        const reformatted = toVersUriString(parsed.value);
        if (reformatted != canonical)
            fail("canonical URI not stable: " ~ canonical ~ " -> " ~ reformatted);
    }

    // formatVersUri is an order-preserving textual renderer (it does NOT
    // version-sort — that needs a scheme, see formatVersAs). So a `vers:` URI
    // whose constraints are already in their stored order survives a
    // parse → format round-trip verbatim (scheme lowercased, spaces stripped,
    // exactly-equal segments deduped).
    check("vers:semver/1.3.4");
    check("vers:pypi/!=5");
    check("vers:semver/>=1.2.0|<2.0.0");
    check("vers:semver/>=1.0.0|>=2.0.0");
    check("vers:deb/>=2.6|<3");
}

@("vers.roundTrip.uriNormalisesToCanonical")
@safe
unittest
{
    import core.exception : AssertError;
    import sparkles.base.lifetime : recycledErrorInstance;
    import sparkles.versions.vers : parseVersUri, toVersUriString;

    void check(
        string input, string canonical,
        string file = __FILE__, size_t line = __LINE__,
    ) @safe
    {
        void fail(in char[] msg) @trusted
        {
            throw recycledErrorInstance!AssertError(msg, file, line);
        }

        auto parsed = parseVersUri(input);
        if (!parsed.hasValue)
            fail("parseVersUri rejected: " ~ input);
        const got = toVersUriString(parsed.value);
        if (got != canonical)
            fail("normalisation mismatch: " ~ input ~ " -> " ~ got
                ~ " (expected " ~ canonical ~ ")");
    }

    // formatVersUri normalises the URI surface only: scheme lowercased,
    // spaces stripped, exactly-equal segments deduped — but the constraint
    // ORDER is preserved (no version sort).
    check("VERS:NPM/1.0.0", "vers:npm/1.0.0");
    check("  vers:pypi/ >=1.0 | <2.0 ", "vers:pypi/>=1.0|<2.0");
    check("vers:npm/2.0.0|1.0.0|2.0.0", "vers:npm/2.0.0|1.0.0");
}

// ---------------------------------------------------------------------------
// Scheme-typed canonical (version-ordered) emission — formatVersAs. This is
// the vers-spec canonical form, distinct from formatVersUri's textual order.
// ---------------------------------------------------------------------------

@("vers.roundTrip.typedCanonicalVersionOrder")
@safe
unittest
{
    import core.exception : AssertError;
    import sparkles.base.lifetime : recycledErrorInstance;
    import sparkles.versions.schemes.semver : SemVer;
    import sparkles.versions.vers : parseVersAs, toVersUriStringAs;

    void check(
        string input, string canonical,
        string file = __FILE__, size_t line = __LINE__,
    ) @safe
    {
        void fail(in char[] msg) @trusted
        {
            throw recycledErrorInstance!AssertError(msg, file, line);
        }

        auto r = parseVersAs!SemVer(input);
        if (!r.hasValue)
            fail("parseVersAs rejected: " ~ input);
        const got = toVersUriStringAs!SemVer(r.value);
        if (got != canonical)
            fail("typed-canonical mismatch: " ~ input ~ " -> " ~ got
                ~ " (expected " ~ canonical ~ ")");
    }

    // The decisive case where TEXT order and VERSION order diverge: textually
    // `<10.0.0` sorts before `<9.0.0` ('1' < '9'), but by version 9.0.0 <
    // 10.0.0. The typed path emits version order — proving it is NOT
    // text-sorted. (The two upper bounds union to the wider `<10.0.0`.)
    check("vers:semver/<10.0.0|<9.0.0", "vers:semver/<10.0.0");

    // Two disjoint singletons whose text and version order differ: kept in
    // version order, `9.0.0` before `10.0.0`.
    check("vers:semver/10.0.0|9.0.0", "vers:semver/9.0.0|10.0.0");
}
