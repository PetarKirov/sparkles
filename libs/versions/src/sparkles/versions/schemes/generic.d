/**
`Generic` — the opaque, lexicographically compared baseline scheme.

`Generic` declares **zero** optional capabilities: no `orderKey`, no
`components`, no `isPrerelease`, no `build`, no native range, no loose
parse. It provides only the required $(REF isVersion, sparkles,versions,traits)
surface (`opCmp` + `toString`) over the raw version string, comparing
lexicographically by code point. It exists to exercise every generic
algorithm's fallback path: comparison-based `sort`, comparison-based
`Ranges!Generic`, and the "no native range, exact versions only" branch of
the VERS/purl layers.

`parse` always succeeds — any string is a valid `Generic`.

See `docs/specs/versions/PRESETS.md` §3.11.
*/
module sparkles.versions.schemes.generic;

import sparkles.versions.parsing : parseOk;

import sparkles.versions.parsing :
    NoGcHook, ParseError, ParseExpected;
import sparkles.versions.ranges : Ranges;
import sparkles.versions.traits :
    hasBuildMetadata, hasComponents, hasOrderKey,
    isVersion, isVersionScheme, supportsPrerelease;

@safe:

/// An opaque version: the raw string, compared lexicographically.
struct Generic
{
    /// The raw version string. No structure is parsed.
    string raw;

    // ----- scheme handle -----

    alias Version = Generic;
    alias Range = Ranges!Generic;
    enum string purlType = "generic";

    // ----- required surface -----

    /// Lexicographic (code-point) three-way order on the raw string.
    int opCmp(in Generic other) const @safe pure nothrow @nogc
    {
        import std.algorithm.comparison : cmp;
        return cmp(raw, other.raw);
    }

    bool opEquals(in Generic other) const @safe pure nothrow @nogc
        => raw == other.raw;

    size_t toHash() const @trusted pure nothrow @nogc
    {
        import core.internal.hash : hashOf;
        return hashOf(raw);
    }

    /// Writes the raw string verbatim.
    void toString(W)(ref W w) const
    {
        import std.range.primitives : put;
        put(w, raw);
    }

    // ----- parsing -----

    /// Always succeeds: any string is a valid `Generic`.
    static ParseExpected!Generic parse(string s) @safe pure nothrow @nogc
        => parseOk(Generic(s));
}

// ---------------------------------------------------------------------------
// Conformance — the baseline declares no optional capabilities.
// ---------------------------------------------------------------------------

static assert(isVersion!Generic && isVersionScheme!Generic);
static assert(!hasOrderKey!Generic);
static assert(!supportsPrerelease!Generic);
static assert(!hasComponents!Generic);
static assert(!hasBuildMetadata!Generic);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("generic.parse.anyStringSucceeds")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkRoundTrip;

    checkRoundTrip!Generic("build-2024-05-30");
    checkRoundTrip!Generic("r1234");
    checkRoundTrip!Generic("snapshot-xyz");
    checkRoundTrip!Generic("");
}

@("generic.ordering.lexicographic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkAscending;

    checkAscending!Generic("a", "b", "c");
    checkAscending!Generic("r1", "r2", "r20"); // lexicographic, not numeric
}
