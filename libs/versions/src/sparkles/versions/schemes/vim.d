/**
`VimVer` — Vim's versioning with a 4-digit zero-padded patch (`9.1.0400`).

Same `major.minor.patch` numeric shape as the SemVer triple, but the `patch`
field prints zero-padded to **4 digits** and the strict parser requires that
width. Vim's running patch counter has millennia of headroom, so values whose
natural width exceeds 4 print unpadded (`9.1.10000`). No prerelease, no build.

See `docs/specs/versions/PRESETS.md` §3.7.
*/
module sparkles.versions.schemes.vim;

import sparkles.versions.parsing : parseOk, parseErr;

import sparkles.versions.parsing :
    NoGcHook, ParseError, ParseErrorCode, ParseExpected, ParseMode;
import sparkles.versions.ranges : Ranges;
import sparkles.versions.schemes.semver : parseSemVerShaped;
import sparkles.versions.traits :
    compareComponents, hasComponents, hasOrderKey, hasSemVerComponents,
    isVersion, isVersionScheme, supportsPrerelease;

@safe:

/// A Vim version. The `patch` field zero-pads to 4 digits on output and the
/// strict parser demands at least 4 digits there (`9.1.0400`, not `9.1.400`).
struct VimVer
{
    /// Numeric core (`major ≤ 65535`, `minor`/`patch ≤ 16,777,215`).
    uint major, minor, patch;

    // ----- scheme handle -----

    alias Version = VimVer;
    alias Range = Ranges!VimVer;
    enum string purlType = "vim";
    enum string[] components = ["major", "minor", "patch"];

    /// Per-component bounds consulted by the shared SemVer-shaped parser; they
    /// match the `orderKey` slot widths so a parsed value can never overflow
    /// the packed key (keeping `orderKey` monotone with `opCmp`).
    enum ulong[] componentMaxes = [65535, 16_777_215, 16_777_215];

    // ----- required surface -----

    int opCmp(in VimVer other) const @safe pure nothrow @nogc
        => compareComponents(this, other);

    bool opEquals(in VimVer other) const @safe pure nothrow @nogc
        => orderKey == other.orderKey;

    size_t toHash() const @safe pure nothrow @nogc => orderKey;

    /// Writes `major.minor.PPPP` (patch zero-padded to 4 digits).
    void toString(W)(ref W w) const
    {
        import sparkles.core_cli.text.writers : writeInteger, writeIntegerPadded;
        import std.range.primitives : put;

        writeInteger(w, major);
        put(w, '.');
        writeInteger(w, minor);
        put(w, '.');
        writeIntegerPadded(w, patch, 4);
    }

    // ----- optional capabilities -----

    /// `major:16 | minor:24 | patch:24` packed into a `ulong`. The 4-digit
    /// padding is formatting only.
    ulong orderKey() const @safe pure nothrow @nogc
        => (cast(ulong) major << 48) | (cast(ulong) minor << 24)
            | cast(ulong) patch;

    // ----- parsing -----

    static ParseExpected!VimVer parse(string s) @safe pure nothrow @nogc
        => parseSemVerShaped!VimVer(s, ParseMode.strict, vimWidths);

    static ParseExpected!VimVer parseLoose(string s) @safe pure nothrow @nogc
        => parseSemVerShaped!VimVer(s, ParseMode.loose, vimWidths);

    static ParseExpected!Range parseNativeRange(string s)
        @safe pure nothrow @nogc
        => parseErr!(Range)(
            ParseError(ParseErrorCode.unexpectedCharacter, 0));
}

/// Per-component minimum widths: 4-digit patch, unpadded major/minor.
private enum int[] vimWidths = [0, 0, 4];

static assert(isVersion!VimVer && isVersionScheme!VimVer);
static assert(hasOrderKey!VimVer);
static assert(hasComponents!VimVer);
static assert(hasSemVerComponents!VimVer);
static assert(!supportsPrerelease!VimVer);

@("vim.parse.fourDigitPatch")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;
    import sparkles.versions.testing : checkParse, checkRejects, checkRoundTrip;

    auto v = checkParse!VimVer("9.1.0400");
    checkToString(v, "9.1.0400");
    assert(v.major == 9 && v.minor == 1 && v.patch == 400);

    // 3-digit patch rejected by the width rule.
    checkRejects!VimVer("9.1.400");

    // Patch wider than 4 prints unpadded.
    checkRoundTrip!VimVer("9.1.10000");
}

@("vim.ordering")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkAscending;

    checkAscending!VimVer("9.1.0399", "9.1.0400", "9.2.0001");
}

@("vim.orderKey.matchesOpCmp")
@safe pure nothrow @nogc
unittest
{
    static immutable corpus = ["9.1.0399", "9.1.0400", "9.2.0001", "10.0.0000"];
    foreach (i; 0 .. corpus.length)
        foreach (j; 0 .. corpus.length)
        {
            const a = VimVer.parse(corpus[i]).value;
            const b = VimVer.parse(corpus[j]).value;
            if (a.orderKey != b.orderKey)
            {
                const k = a.orderKey < b.orderKey ? -1 : 1;
                const c = a.opCmp(b) < 0 ? -1 : (a.opCmp(b) > 0 ? 1 : 0);
                assert(k == c);
            }
        }
}
