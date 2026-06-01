/**
`CalVerYYYYMMDD` — Arch-style calendar versioning (`2024.05.01`).

A `year.month.day` calendar version with a 4-digit year and 2-digit
zero-padded month and day. Ordering is numeric and most-significant-first.
The component list is `["year","month","day"]`: `hasComponents` holds,
`hasSemVerComponents` does **not** (no caret/tilde for a date version). No
prerelease, no build.

See `docs/libs/versions/reference/schemes.md` §3.6.
*/
module sparkles.versions.schemes.calver_yyyymmdd;

import sparkles.versions.parsing : parseOk, parseErr;

import sparkles.versions.parsing :
    NoGcHook, ParseError, ParseErrorCode, ParseExpected, ParseMode;
import sparkles.versions.ranges : Ranges;
import sparkles.versions.schemes.semver : parseNpmRange, parseSemVerShaped;
import sparkles.versions.traits :
    compareComponents, hasComponents, hasOrderKey, hasSemVerComponents,
    isVersion, isVersionScheme, supportsPrerelease;

@safe:

/// An Arch-style calendar version. Both `month` and `day` zero-pad to 2
/// digits on output and the strict parser demands that width
/// (`2024.05.01`, not `2024.05.1`).
struct CalVerYYYYMMDD
{
    /// Calendar core (`year ≤ 65535`, `month ≤ 12`, `day ≤ 31`).
    uint year, month, day;

    // ----- scheme handle -----

    alias Version = CalVerYYYYMMDD;
    alias Range = Ranges!CalVerYYYYMMDD;
    enum string purlType = "calver_yyyymmdd";
    enum string[] components = ["year", "month", "day"];

    /// Per-component bounds consulted by the shared SemVer-shaped parser.
    enum ulong[] componentMaxes = [65535, 12, 31];

    // ----- required surface -----

    int opCmp(in CalVerYYYYMMDD other) const @safe pure nothrow @nogc
        => compareComponents(this, other);

    bool opEquals(in CalVerYYYYMMDD other) const @safe pure nothrow @nogc
        => orderKey == other.orderKey;

    size_t toHash() const @safe pure nothrow @nogc => orderKey;

    /// Writes `year.MM.DD` (month and day zero-padded to 2 digits).
    void toString(W)(ref W w) const
    {
        import sparkles.core_cli.text.writers : writeInteger, writeIntegerPadded;
        import std.range.primitives : put;

        writeInteger(w, year);
        put(w, '.');
        writeIntegerPadded(w, month, 2);
        put(w, '.');
        writeIntegerPadded(w, day, 2);
    }

    // ----- optional capabilities -----

    /// `year:16 | month:8 | day:8` packed into a `ulong`. The 2-digit
    /// month/day padding is formatting only.
    ulong orderKey() const @safe pure nothrow @nogc
        => (cast(ulong) year << 16) | (cast(ulong) month << 8)
            | cast(ulong) day;

    // ----- parsing -----

    static ParseExpected!CalVerYYYYMMDD parse(string s)
        @safe pure nothrow @nogc
        => parseSemVerShaped!CalVerYYYYMMDD(s, ParseMode.strict, calWidths);

    static ParseExpected!CalVerYYYYMMDD parseLoose(string s)
        @safe pure nothrow @nogc
        => parseSemVerShaped!CalVerYYYYMMDD(s, ParseMode.loose, calWidths);

    static ParseExpected!Range parseNativeRange(string s) @safe
        => parseNpmRange!CalVerYYYYMMDD(s);
}

/// Per-component minimum widths: 2-digit month and day, unpadded year.
private enum int[] calWidths = [0, 2, 2];

static assert(isVersion!CalVerYYYYMMDD && isVersionScheme!CalVerYYYYMMDD);
static assert(hasOrderKey!CalVerYYYYMMDD);
static assert(hasComponents!CalVerYYYYMMDD);
static assert(!hasSemVerComponents!CalVerYYYYMMDD);
static assert(!supportsPrerelease!CalVerYYYYMMDD);

@("calver_yyyymmdd.arch")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;
    import sparkles.versions.testing : checkParse, checkRejects;

    auto v = checkParse!CalVerYYYYMMDD("2024.05.01");
    checkToString(v, "2024.05.01");
    assert(v.year == 2024 && v.month == 5 && v.day == 1);

    // Day must be 2 digits.
    checkRejects!CalVerYYYYMMDD("2024.05.1");
}

@("calver_yyyymmdd.ordering")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkAscending;

    checkAscending!CalVerYYYYMMDD(
        "2024.05.01", "2024.05.02", "2024.06.01", "2025.01.01");
}

@("calver_yyyymmdd.orderKey.matchesOpCmp")
@safe pure nothrow @nogc
unittest
{
    static immutable corpus =
        ["2024.05.01", "2024.05.02", "2024.06.01", "2025.01.01"];
    foreach (i; 0 .. corpus.length)
        foreach (j; 0 .. corpus.length)
        {
            const a = CalVerYYYYMMDD.parse(corpus[i]).value;
            const b = CalVerYYYYMMDD.parse(corpus[j]).value;
            if (a.orderKey != b.orderKey)
            {
                const k = a.orderKey < b.orderKey ? -1 : 1;
                const c = a.opCmp(b) < 0 ? -1 : (a.opCmp(b) > 0 ? 1 : 0);
                assert(k == c);
            }
        }
}
