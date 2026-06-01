/**
`Dmd` — the D compiler's internal versioning (`2.111.0`, `2.079.0`).

Same `major.minor.patch[-prerelease]` shape as SemVer, but the `minor` field
is printed zero-padded to **3 digits** (`079`), and the strict parser
requires that width. DMD releases carry no build metadata, so `Dmd` omits
`build`. The prerelease grammar and ordering reuse SemVer's
package-scoped identifier rules.

See `docs/specs/versions/PRESETS.md` §3.2.
*/
module sparkles.versions.schemes.dmd;

import sparkles.versions.parsing : parseOk, parseErr;

import sparkles.versions.parsing :
    NoGcHook, ParseError, ParseErrorCode, ParseExpected, ParseMode;
import sparkles.versions.ranges : Ranges;
import sparkles.versions.schemes.semver :
    compareSemVerPrerelease, minorBits, noWidths, patchBits, parseSemVerShaped;
import sparkles.versions.traits :
    compareComponents, hasComponents, hasOrderKey, hasSemVerComponents,
    isVersion, isVersionScheme, supportsPrerelease;

@safe:

/**
A DMD version. The `minor` field zero-pads to 3 digits on output and the
strict parser demands at least 3 digits there (`2.079.0`, not `2.79.0`).
*/
struct Dmd
{
    /// Numeric core (`major ≤ 32767`, `minor`/`patch ≤ 16,777,215`).
    uint major, minor, patch;

    /// Prerelease identifier list without the leading `-`, compared per
    /// SemVer §11.4.
    string prerelease;

    // ----- scheme handle -----

    alias Version = Dmd;
    alias Range = Ranges!Dmd;
    enum string purlType = "dmd";
    enum string[] components = ["major", "minor", "patch"];

    // ----- required surface -----

    int opCmp(in Dmd other) const @safe pure nothrow @nogc
    {
        if (const c = compareComponents(this, other))
            return c;
        return compareSemVerPrerelease(prerelease, other.prerelease);
    }

    bool opEquals(in Dmd other) const @safe pure nothrow @nogc
        => opCmp(other) == 0;

    size_t toHash() const @trusted pure nothrow @nogc
    {
        import core.internal.hash : hashOf;
        auto h = hashOf(orderKey);
        return hashOf(prerelease, h);
    }

    /// Writes `major.MMM.patch[-prerelease]` (minor zero-padded to 3).
    void toString(W)(ref W w) const
    {
        import sparkles.core_cli.text.writers : writeInteger, writeIntegerPadded;
        import std.range.primitives : put;

        writeInteger(w, major);
        put(w, '.');
        writeIntegerPadded(w, minor, 3);
        put(w, '.');
        writeInteger(w, patch);
        if (prerelease.length)
        {
            put(w, '-');
            put(w, prerelease);
        }
    }

    // ----- optional capabilities -----

    /// `major:minor:patch:stableFlag` packed into a `ulong`. The 3-digit
    /// padding is formatting only and does not affect the key.
    ulong orderKey() const @safe pure nothrow @nogc
    {
        const stable = prerelease.length == 0 ? 1UL : 0UL;
        return (cast(ulong) major << (minorBits + patchBits + 1))
            | (cast(ulong) minor << (patchBits + 1))
            | (cast(ulong) patch << 1)
            | stable;
    }

    bool isPrerelease() const @safe pure nothrow @nogc
        => prerelease.length != 0;

    // ----- parsing -----

    static ParseExpected!Dmd parse(string s) @safe pure nothrow @nogc
        => parseSemVerShaped!Dmd(s, ParseMode.strict, dmdWidths);

    /// Loose mode relaxes the leading-`v`/`=`, surrounding spaces, partial
    /// versions, leading zeroes, and the 3-digit minor width (as for
    /// `semver`); the canonical form still re-pads the minor on output.
    static ParseExpected!Dmd parseLoose(string s) @safe pure nothrow @nogc
        => parseSemVerShaped!Dmd(s, ParseMode.loose, noWidths);

    static ParseExpected!Range parseNativeRange(string s)
        @safe pure nothrow @nogc
        => parseErr!(Range)(
            ParseError(ParseErrorCode.unexpectedCharacter, 0));
}

/// Per-component minimum widths: 3-digit minor, unpadded major/patch.
private enum int[] dmdWidths = [0, 3, 0];

static assert(isVersion!Dmd && isVersionScheme!Dmd);
static assert(hasOrderKey!Dmd);
static assert(supportsPrerelease!Dmd);
static assert(hasComponents!Dmd);
static assert(hasSemVerComponents!Dmd);

@("dmd.parse.historicalAndCurrent")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkRoundTrip;

    checkRoundTrip!Dmd("2.079.0");
    checkRoundTrip!Dmd("2.111.0");
    checkRoundTrip!Dmd("1.075.0");
}

@("dmd.parse.requires3DigitMinor")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;
    import sparkles.versions.testing : checkRejects;

    auto v = Dmd.parse("2.009.0");
    assert(v.hasValue);
    checkToString(v.value, "2.009.0");

    // 2.79.0 violates the 3-digit minor width.
    checkRejects!Dmd("2.79.0");
}

@("dmd.ordering")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkAscending;

    checkAscending!Dmd("2.079.0", "2.111.0");
    checkAscending!Dmd("2.111.0-beta.1", "2.111.0-rc.1", "2.111.0");
}

@("dmd.loose.normalisation")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    static immutable cases = [
        ["v2.79.0", "2.079.0"],
        ["= 2.111.0", "2.111.0"],
        ["2.79", "2.079.0"],
        ["02.079.0", "2.079.0"],
    ];
    foreach (tc; cases)
    {
        auto parsed = Dmd.parseLoose(tc[0]);
        assert(parsed.hasValue, tc[0]);
        checkToString(parsed.value, tc[1]);
    }
}

@("dmd.orderKey.matchesOpCmp")
@safe pure nothrow @nogc
unittest
{
    static immutable corpus = ["2.079.0", "2.111.0", "2.111.0-rc.1", "3.000.0"];
    foreach (i; 0 .. corpus.length)
        foreach (j; 0 .. corpus.length)
        {
            const a = Dmd.parse(corpus[i]).value;
            const b = Dmd.parse(corpus[j]).value;
            if (a.orderKey != b.orderKey)
            {
                const k = a.orderKey < b.orderKey ? -1 : 1;
                const c = a.opCmp(b) < 0 ? -1 : (a.opCmp(b) > 0 ? 1 : 0);
                assert(k == c);
            }
        }
}
