/**
`CalVerYYMM` — Ubuntu-style calendar versioning (`24.04.1`).

A `year.month.patch` calendar version with a 2-digit zero-padded month.
Ordering is numeric and most-significant-first, so it is chronological. The
component list is declared honestly as `["year","month","patch"]`: it gets
`hasComponents` (generic compare, `truncateTo!"month"`) but **not**
`hasSemVerComponents` — a calendar version has no caret/tilde. No prerelease,
no build.

See `docs/libs/versions/reference/schemes.md` §3.5.
*/
module sparkles.versions.schemes.calver_yymm;

import sparkles.versions.parsing : parseOk, parseErr;

import sparkles.versions.parsing :
    NoGcHook, ParseError, ParseErrorCode, ParseExpected, ParseMode;
import sparkles.versions.ranges : Ranges;
import sparkles.versions.schemes.semver : parseNpmRange, parseSemVerShaped;
import sparkles.versions.traits :
    compareComponents, hasComponents, hasOrderKey, hasSemVerComponents,
    isVersion, isVersionScheme, supportsPrerelease;

@safe:

/// An Ubuntu-style calendar version. The `month` field zero-pads to 2 digits
/// on output and the strict parser demands that width (`24.04.1`, not
/// `24.4.1`).
struct CalVerYYMM
{
    /// Calendar core (`year ≤ 65535`, `month ≤ 12`, `patch ≤ 65535`).
    uint year, month, patch;

    // ----- scheme handle -----

    alias Version = CalVerYYMM;
    alias Range = Ranges!CalVerYYMM;
    enum string purlType = "calver_yymm";
    enum string[] components = ["year", "month", "patch"];

    /// Per-component bounds consulted by the shared SemVer-shaped parser.
    enum ulong[] componentMaxes = [65535, 12, 65535];

    // ----- required surface -----

    int opCmp(in CalVerYYMM other) const @safe pure nothrow @nogc
        => compareComponents(this, other);

    bool opEquals(in CalVerYYMM other) const @safe pure nothrow @nogc
        => orderKey == other.orderKey;

    size_t toHash() const @safe pure nothrow @nogc => orderKey;

    /// Writes `year.MM.patch` (month zero-padded to 2 digits).
    void toString(W)(ref W w) const
    {
        import sparkles.base.text.writers : writeInteger, writeIntegerPadded;
        import std.range.primitives : put;

        writeInteger(w, year);
        put(w, '.');
        writeIntegerPadded(w, month, 2);
        put(w, '.');
        writeInteger(w, patch);
    }

    // ----- optional capabilities -----

    /// `year:16 | month:8 | patch:16` packed into a `ulong`. The 2-digit
    /// month padding is formatting only.
    ulong orderKey() const @safe pure nothrow @nogc
        => (cast(ulong) year << 24) | (cast(ulong) month << 16)
            | cast(ulong) patch;

    // ----- parsing -----

    static ParseExpected!CalVerYYMM parse(string s) @safe pure nothrow @nogc
        => parseSemVerShaped!CalVerYYMM(s, ParseMode.strict, calWidths);

    static ParseExpected!CalVerYYMM parseLoose(string s)
        @safe pure nothrow @nogc
        => parseSemVerShaped!CalVerYYMM(s, ParseMode.loose, calWidths);

    static ParseExpected!Range parseNativeRange(string s) @safe
        => parseNpmRange!CalVerYYMM(s);
}

/// Per-component minimum widths: 2-digit month, unpadded year/patch.
private enum int[] calWidths = [0, 2, 0];

static assert(isVersion!CalVerYYMM && isVersionScheme!CalVerYYMM);
static assert(hasOrderKey!CalVerYYMM);
static assert(hasComponents!CalVerYYMM);
static assert(!hasSemVerComponents!CalVerYYMM);
static assert(!supportsPrerelease!CalVerYYMM);

@("calver_yymm.ubuntu")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkParse, checkRejects, checkRoundTrip;

    // Real-world fixture round-trips through parse + toString.
    checkRoundTrip!CalVerYYMM("24.04.1");

    auto v = checkParse!CalVerYYMM("24.04.1");
    assert(v.year == 24 && v.month == 4 && v.patch == 1);

    // Unpadded month is rejected.
    checkRejects!CalVerYYMM("24.4.1");
}

@("calver_yymm.ordering")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkAscending;

    checkAscending!CalVerYYMM("24.04.1", "24.04.2", "24.10.1", "25.04.1");
}

@("calver_yymm.orderKey.matchesOpCmp")
@safe pure nothrow @nogc
unittest
{
    static immutable corpus = ["24.04.1", "24.04.2", "24.10.1", "25.04.1"];
    foreach (i; 0 .. corpus.length)
        foreach (j; 0 .. corpus.length)
        {
            const a = CalVerYYMM.parse(corpus[i]).value;
            const b = CalVerYYMM.parse(corpus[j]).value;
            if (a.orderKey != b.orderKey)
            {
                const k = a.orderKey < b.orderKey ? -1 : 1;
                const c = a.opCmp(b) < 0 ? -1 : (a.opCmp(b) > 0 ? 1 : 0);
                assert(k == c);
            }
        }
}
