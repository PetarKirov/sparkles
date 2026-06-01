/**
`Tiny` — a 4-byte, no-prerelease, no-build version.

Three numeric components (`major ≤ 65535`, `minor ≤ 255`, `patch ≤ 255`)
packed into a `uint`; plain unsigned compare. The storage-sensitive baseline
for the packed path. Loose parse infills missing trailing components with
`0`.

See `docs/specs/versions/PRESETS.md` §3.4.
*/
module sparkles.versions.schemes.tiny;

import sparkles.versions.parsing : parseOk, parseErr;

import sparkles.versions.parsing :
    NoGcHook, ParseError, ParseErrorCode, ParseExpected, ParseMode;
import sparkles.versions.ranges : Ranges;
import sparkles.versions.schemes.semver : parseSemVerShaped;
import sparkles.versions.traits :
    compareComponents, hasComponents, hasOrderKey, hasSemVerComponents,
    isVersion, isVersionScheme, supportsPrerelease;

@safe:

/// A compact 3-component version with no prerelease or build metadata.
struct Tiny
{
    /// Numeric core (`major ≤ 65535`, `minor`/`patch ≤ 255`).
    uint major, minor, patch;

    // ----- scheme handle -----

    alias Version = Tiny;
    alias Range = Ranges!Tiny;
    enum string purlType = "tiny";
    enum string[] components = ["major", "minor", "patch"];

    /// Per-component bounds consulted by the shared SemVer-shaped parser.
    enum ulong[] componentMaxes = [65535, 255, 255];

    // ----- required surface -----

    int opCmp(in Tiny other) const @safe pure nothrow @nogc
        => compareComponents(this, other);

    bool opEquals(in Tiny other) const @safe pure nothrow @nogc
        => orderKey == other.orderKey;

    size_t toHash() const @safe pure nothrow @nogc => orderKey;

    /// Writes `major.minor.patch`.
    void toString(W)(ref W w) const
    {
        import sparkles.core_cli.text.writers : writeInteger;
        import std.range.primitives : put;

        writeInteger(w, major);
        put(w, '.');
        writeInteger(w, minor);
        put(w, '.');
        writeInteger(w, patch);
    }

    // ----- optional capabilities -----

    /// The 4-byte packed integer: `major:16, minor:8, patch:8`.
    uint orderKey() const @safe pure nothrow @nogc
        => (cast(uint) major << 16) | (cast(uint) minor << 8) | cast(uint) patch;

    // ----- parsing -----

    static ParseExpected!Tiny parse(string s) @safe pure nothrow @nogc
        => parseSemVerShaped!Tiny(s, ParseMode.strict, [0, 0, 0]);

    static ParseExpected!Tiny parseLoose(string s) @safe pure nothrow @nogc
        => parseSemVerShaped!Tiny(s, ParseMode.loose, [0, 0, 0]);

    static ParseExpected!Range parseNativeRange(string s)
        @safe pure nothrow @nogc
        => parseErr!(Range)(
            ParseError(ParseErrorCode.unexpectedCharacter, 0));
}

static assert(isVersion!Tiny && isVersionScheme!Tiny);
static assert(hasOrderKey!Tiny);
static assert(is(typeof(Tiny.init.orderKey()) == uint));
static assert(hasComponents!Tiny);
static assert(hasSemVerComponents!Tiny);
static assert(!supportsPrerelease!Tiny);

@("tiny.parse.roundTrip")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkRoundTrip;

    checkRoundTrip!Tiny("7.8.9");
    checkRoundTrip!Tiny("100.50.25");
}

@("tiny.parse.boundsAndLoose")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;
    import sparkles.versions.testing : checkRejects;

    // minor over 255 is rejected.
    checkRejects!Tiny("1.256.0");

    // loose infills patch=0.
    auto v = Tiny.parseLoose("1.2");
    assert(v.hasValue);
    checkToString(v.value, "1.2.0");
}

@("tiny.ordering")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkAscending;

    checkAscending!Tiny("1.0.0", "1.0.1", "1.1.0", "2.0.0");
}

@("tiny.orderKey.matchesOpCmp")
@safe pure nothrow @nogc
unittest
{
    static immutable corpus = ["0.0.0", "1.0.0", "1.2.3", "65535.255.255"];
    foreach (i; 0 .. corpus.length)
        foreach (j; 0 .. corpus.length)
        {
            const a = Tiny.parse(corpus[i]).value;
            const b = Tiny.parse(corpus[j]).value;
            if (a.orderKey != b.orderKey)
            {
                const k = a.orderKey < b.orderKey ? -1 : 1;
                const c = a.opCmp(b) < 0 ? -1 : (a.opCmp(b) > 0 ? 1 : 0);
                assert(k == c);
            }
        }
}
