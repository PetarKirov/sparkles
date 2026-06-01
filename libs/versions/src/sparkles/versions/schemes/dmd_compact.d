/**
`DmdCompact` — a 4-byte bitfield encoding of a DMD version.

Exploits two facts about DMD's actual versioning to fit a fully ordered,
fully formatted version into 32 bits with zero string allocations:

$(OL
    $(LI DMD releases carry no build metadata.)
    $(LI DMD prereleases follow the constrained grammar `beta.N` / `rc.N`
        (e.g. `2.111.0-beta.2`), so the prerelease is encoded as a 2-bit
        phase plus a small number rather than a general string.)
)

Because the `(phase, num)` pair sits just below the stable marker in the
packed integer, a single unsigned compare yields
`2.111.0-beta.N < 2.111.0-rc.M < 2.111.0`. The packed `uint` _is_ the
`orderKey`. There is no loose parse.

See `docs/specs/versions/PRESETS.md` §3.3.
*/
module sparkles.versions.schemes.dmd_compact;

import sparkles.versions.parsing : parseOk, parseErr;

import sparkles.versions.parsing :
    NoGcHook, ParseError, ParseErrorCode, ParseExpected;
import sparkles.versions.ranges : Ranges;
import sparkles.versions.schemes.semver : parseNpmRange;
import sparkles.versions.traits :
    hasComponents, hasOrderKey, hasSemVerComponents,
    isVersion, isVersionScheme, supportsPrerelease;

@safe:

/**
Compact DMD version. `major ≤ 255`, `minor ≤ 1023`, `patch ≤ 63`,
prerelease number ≤ 63.
*/
struct DmdCompact
{
    /// Prerelease phase, monotone for ordering: `stable > rc > beta`.
    enum Phase : ubyte
    {
        beta = 0,
        rc = 1,
        stable = 2,
        reserved = 3,
    }

    /// Numeric core.
    uint major, minor, patch;

    /// Prerelease phase (defaults to `stable`).
    Phase phase = Phase.stable;

    /// Prerelease number for `beta`/`rc` (`0` when stable).
    ubyte prereleaseNum;

    // ----- scheme handle -----

    alias Version = DmdCompact;
    alias Range = Ranges!DmdCompact;
    enum string purlType = "dmd_compact";
    enum string[] components = ["major", "minor", "patch"];

    // Field bit widths within the packed core (LSB → MSB):
    // prereleaseNum:6, phase:2, patch:6, minor:10, major:8.
    private enum int numBits = 6, phaseBits = 2, patchBits = 6,
        minorBits = 10, majorBits = 8;

    // ----- required surface -----

    /// Order via the packed key; the phase encoding is monotone by
    /// construction.
    int opCmp(in DmdCompact other) const @safe pure nothrow @nogc
    {
        const a = orderKey, b = other.orderKey;
        return a < b ? -1 : (a > b ? 1 : 0);
    }

    bool opEquals(in DmdCompact other) const @safe pure nothrow @nogc
        => orderKey == other.orderKey;

    size_t toHash() const @safe pure nothrow @nogc => orderKey;

    /// Writes `major.MMM.patch` with optional `-beta.N` / `-rc.N` suffix
    /// (minor zero-padded to 3 digits).
    void toString(W)(ref W w) const
    {
        import sparkles.core_cli.text.writers : writeInteger, writeIntegerPadded;
        import std.range.primitives : put;

        writeInteger(w, major);
        put(w, '.');
        writeIntegerPadded(w, minor, 3);
        put(w, '.');
        writeInteger(w, patch);

        final switch (phase)
        {
            case Phase.beta:
                put(w, "-beta.");
                writeInteger(w, prereleaseNum);
                break;
            case Phase.rc:
                put(w, "-rc.");
                writeInteger(w, prereleaseNum);
                break;
            case Phase.stable:
                break;
            case Phase.reserved:
                put(w, "-?");
                break;
        }
    }

    // ----- optional capabilities -----

    /// The 4-byte packed integer, monotone for ordering.
    uint orderKey() const @safe pure nothrow @nogc
    {
        return (cast(uint) major << (minorBits + patchBits + phaseBits + numBits))
            | (cast(uint) minor << (patchBits + phaseBits + numBits))
            | (cast(uint) patch << (phaseBits + numBits))
            | (cast(uint) phase << numBits)
            | cast(uint) prereleaseNum;
    }

    bool isPrerelease() const @safe pure nothrow @nogc
        => phase == Phase.beta || phase == Phase.rc;

    // ----- parsing -----

    /// Parses `major.minor.patch` with optional `-beta.N` / `-rc.N`.
    static ParseExpected!DmdCompact parse(string s) @safe pure nothrow @nogc
    {
        import std.ascii : isDigit;

        DmdCompact result;
        scope const(char)[] cur = s;
        size_t off = 0;

        ParseExpected!DmdCompact fail(ParseErrorCode code)
            => parseErr!(DmdCompact)(ParseError(code, off));

        // Reads one unsigned field bounded by `maxValue`.
        bool readNum(ulong maxValue, out uint value)
        {
            if (cur.length == 0 || !cur[0].isDigit)
                return false;
            ulong v = 0;
            while (cur.length && cur[0].isDigit)
            {
                v = v * 10 + (cur[0] - '0');
                if (v > maxValue)
                    return false;
                cur = cur[1 .. $];
                off++;
            }
            value = cast(uint) v;
            return true;
        }

        bool eat(char c)
        {
            if (cur.length && cur[0] == c)
            {
                cur = cur[1 .. $];
                off++;
                return true;
            }
            return false;
        }

        if (!readNum(255, result.major))
            return fail(cur.length
                ? ParseErrorCode.unexpectedCharacter
                : ParseErrorCode.emptyInput);
        if (!eat('.'))
            return fail(ParseErrorCode.unexpectedCharacter);
        if (!readNum(1023, result.minor))
            return fail(ParseErrorCode.unexpectedCharacter);
        if (!eat('.'))
            return fail(ParseErrorCode.unexpectedCharacter);
        if (!readNum(63, result.patch))
            return fail(ParseErrorCode.unexpectedCharacter);

        if (eat('-'))
        {
            if (consumeWord(cur, off, "beta."))
                result.phase = Phase.beta;
            else if (consumeWord(cur, off, "rc."))
                result.phase = Phase.rc;
            else
                return fail(ParseErrorCode.unexpectedCharacter);

            uint num;
            if (!readNum(63, num))
                return fail(ParseErrorCode.unexpectedCharacter);
            result.prereleaseNum = cast(ubyte) num;
        }

        if (cur.length != 0)
            return fail(ParseErrorCode.unexpectedCharacter);

        return parseOk(result);
    }

    /// Native SemVer-shaped range grammar.
    static ParseExpected!Range parseNativeRange(string s) @safe
        => parseNpmRange!DmdCompact(s);
}

/// Consumes `word` from the front of `cur` (advancing `off`) when it
/// matches, returning whether it did.
private bool consumeWord(
    ref scope const(char)[] cur, ref size_t off, string word,
) @safe pure nothrow @nogc
{
    if (cur.length < word.length)
        return false;
    if (cur[0 .. word.length] != word)
        return false;
    cur = cur[word.length .. $];
    off += word.length;
    return true;
}

static assert(isVersion!DmdCompact && isVersionScheme!DmdCompact);
static assert(hasOrderKey!DmdCompact);
static assert(is(typeof(DmdCompact.init.orderKey()) == uint));
static assert(supportsPrerelease!DmdCompact);
static assert(hasComponents!DmdCompact);
static assert(hasSemVerComponents!DmdCompact);

@("dmd_compact.parse.roundTrip")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkRoundTrip;

    checkRoundTrip!DmdCompact("2.111.0");
    checkRoundTrip!DmdCompact("2.111.0-beta.2");
    checkRoundTrip!DmdCompact("2.111.0-rc.3");
    checkRoundTrip!DmdCompact("2.079.0");
}

@("dmd_compact.ordering")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkAscending;

    checkAscending!DmdCompact(
        "2.111.0-beta.2", "2.111.0-rc.1", "2.111.0");
    // Cross-major dominates the prerelease.
    checkAscending!DmdCompact("2.255.0", "3.0.0-beta.1", "3.0.0");
}

@("dmd_compact.fitsInFourBytes")
@safe pure nothrow @nogc
unittest
{
    static assert(DmdCompact.init.orderKey.sizeof == 4);
}
