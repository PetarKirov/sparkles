/**
`DebianVersion` — dpkg version comparison.

A _structural_ scheme with the shape `[epoch:]upstream_version[-debian_revision]`.
The epoch (default `0`) is compared numerically first; then the upstream
version and the Debian revision are each compared by the dpkg algorithm:
alternating non-digit and digit runs, where in a non-digit run all letters
sort before all non-letters and the **tilde `~` sorts before everything —
even the end of the string** (so `1.0~beta1 < 1.0`), and in a digit run
leading zeroes are ignored and an empty run counts as `0`.

The `~`-before-empty rule defeats any fixed-width integer key, so `deb`
declares **no** `orderKey`.

See `docs/libs/versions/reference/schemes.md` §3.10.
*/
module sparkles.versions.schemes.deb;

import sparkles.versions.parsing : parseOk, parseErr;

import sparkles.versions.parsing :
    NoGcHook, ParseError, ParseErrorCode, ParseExpected;
import sparkles.versions.ranges : Ranges;
import sparkles.versions.traits :
    hasComponents, hasOrderKey,
    isVersion, isVersionScheme, supportsPrerelease;

@safe:

/**
A Debian version: epoch, upstream version, and Debian revision, plus the
verbatim input for round-tripping.
*/
struct DebianVersion
{
    /// Optional epoch (default `0`), compared first.
    ulong epoch;

    /// The upstream version part (between any epoch and the last `-`).
    string upstream;

    /// The Debian revision (after the last `-`); empty when absent.
    string revision;

    /// The original input string, preserved for `toString`.
    string raw;

    // ----- scheme handle -----

    alias Version = DebianVersion;
    alias Range = Ranges!DebianVersion;
    enum string purlType = "deb";

    // ----- required surface -----

    /// dpkg three-way order: epoch, then upstream, then revision.
    int opCmp(in DebianVersion other) const @safe pure nothrow @nogc
    {
        if (epoch != other.epoch)
            return epoch < other.epoch ? -1 : 1;
        if (const c = compareDpkg(upstream, other.upstream))
            return c;
        return compareDpkg(revision, other.revision);
    }

    bool opEquals(in DebianVersion other) const @safe pure nothrow @nogc
        => opCmp(other) == 0;

    size_t toHash() const @trusted pure nothrow @nogc
    {
        import core.internal.hash : hashOf;
        size_t h = hashOf(epoch);
        h = hashOf(upstream, h);
        return hashOf(revision, h);
    }

    /// Writes the verbatim input string.
    void toString(W)(ref W w) const
    {
        import std.range.primitives : put;
        put(w, raw);
    }

    // ----- parsing -----

    /// Parses `[epoch:]upstream[-revision]`. dpkg parsing is permissive.
    static ParseExpected!DebianVersion parse(string s) @safe pure nothrow
    {
        import std.ascii : isDigit;

        DebianVersion result;
        result.raw = s;
        const(char)[] rest = s;

        if (rest.length == 0)
            return parseErr!(DebianVersion)(
                ParseError(ParseErrorCode.emptyInput, 0));

        // Epoch: digits followed by ':'.
        {
            size_t i = 0;
            while (i < rest.length && rest[i].isDigit)
                i++;
            if (i > 0 && i < rest.length && rest[i] == ':')
            {
                ulong ep = 0;
                foreach (c; rest[0 .. i])
                    ep = ep * 10 + (c - '0');
                result.epoch = ep;
                rest = rest[i + 1 .. $];
            }
        }

        // Revision: everything after the last '-'.
        size_t dash = size_t.max;
        foreach (i, c; rest)
            if (c == '-')
                dash = i;
        if (dash != size_t.max)
        {
            result.upstream = cast(string) rest[0 .. dash].idup;
            result.revision = cast(string) rest[dash + 1 .. $].idup;
        }
        else
            result.upstream = cast(string) rest.idup;

        return parseOk(result);
    }

    /**
    Native dpkg-relations range grammar (scheme catalogue §3.10).

    A single comparison relation — `>=`, `<=`, `<<` (strictly less),
    `>>` (strictly greater), or `=` — followed by a version, as used in
    `dpkg --compare-versions` and `Depends:` fields (e.g. `>= 2.0`,
    `<< 3.0`). The relation desugars to a `Ranges!DebianVersion`:

    $(UL
        $(LI `>= v` → `[v, +∞)`)
        $(LI `>> v` → `(v, +∞)`)
        $(LI `<= v` → `(-∞, v]`)
        $(LI `<< v` → `(-∞, v)`)
        $(LI `=  v` → the singleton `{v}`)
    )
    */
    static ParseExpected!Range parseNativeRange(string s) @safe pure nothrow
    {
        import sparkles.core_cli.text.readers : skipSpaces, tryConsume;

        const(char)[] rest = s;
        if (rest.length == 0)
            return parseErr!(Range)(
                ParseError(ParseErrorCode.emptyInput, 0));

        // ----- relation operator -----
        // Distinguish the two-character `<<`/`>>` from the two-character
        // `<=`/`>=` and the single-character `=`.
        enum Rel { ge, le, lt, gt, eq }
        Rel rel;
        skipSpaces(rest);
        if (tryConsume(rest, '>'))
        {
            if (tryConsume(rest, '>'))
                rel = Rel.gt;            // `>>` strictly greater
            else if (tryConsume(rest, '='))
                rel = Rel.ge;            // `>=`
            else
                return parseErr!(Range)(ParseError(
                    ParseErrorCode.unexpectedCharacter, s.length - rest.length));
        }
        else if (tryConsume(rest, '<'))
        {
            if (tryConsume(rest, '<'))
                rel = Rel.lt;            // `<<` strictly less
            else if (tryConsume(rest, '='))
                rel = Rel.le;            // `<=`
            else
                return parseErr!(Range)(ParseError(
                    ParseErrorCode.unexpectedCharacter, s.length - rest.length));
        }
        else if (tryConsume(rest, '='))
            rel = Rel.eq;                // `=`
        else
            return parseErr!(Range)(ParseError(
                ParseErrorCode.unexpectedCharacter, s.length - rest.length));

        // ----- version operand -----
        skipSpaces(rest);
        if (rest.length == 0)
            return parseErr!(Range)(
                ParseError(ParseErrorCode.emptyInput, s.length));

        auto ver = DebianVersion.parse(cast(string) rest.idup);
        if (!ver.hasValue)
            return parseErr!(Range)(ver.error);
        const v = ver.value;

        final switch (rel)
        {
        case Rel.ge:
            return parseOk(Range.higherThan(v));
        case Rel.gt:
            return parseOk(Range.strictlyHigherThan(v));
        case Rel.le:
            return parseOk(Range.lowerThan(v));
        case Rel.lt:
            return parseOk(Range.strictlyLowerThan(v));
        case Rel.eq:
            return parseOk(Range.singleton(v));
        }
    }
}

// ---------------------------------------------------------------------------
// dpkg comparison
// ---------------------------------------------------------------------------

/// The dpkg ordering weight of a non-digit character: `~` sorts before
/// everything (including end-of-string, modelled as weight `0`), letters sort
/// by their code, and other characters sort after letters.
private int charWeight(char c) @safe pure nothrow @nogc
{
    import std.ascii : isAlpha;

    if (c == '~')
        return -1;
    if (c.isAlpha)
        return cast(int) c; // letters: 'A'..'z' in ASCII order
    // Non-letter, non-tilde punctuation sorts after letters.
    return cast(int) c + 256;
}

/// Compares two version parts using the dpkg two-phase algorithm.
private int compareDpkg(in char[] a, in char[] b) @safe pure nothrow @nogc
{
    import std.ascii : isDigit;

    size_t i, j;
    while (i < a.length || j < b.length)
    {
        // --- non-digit run ---
        while ((i < a.length && !a[i].isDigit)
            || (j < b.length && !b[j].isDigit))
        {
            // End-of-string and a non-tilde count as weight 0; `~` is -1, so
            // `~` < end-of-string.
            const wa = i < a.length && !a[i].isDigit ? charWeight(a[i]) : 0;
            const wb = j < b.length && !b[j].isDigit ? charWeight(b[j]) : 0;
            if (wa != wb)
                return wa < wb ? -1 : 1;
            if (i < a.length && !a[i].isDigit)
                i++;
            if (j < b.length && !b[j].isDigit)
                j++;
        }

        // --- digit run (leading zeros ignored; empty run == 0) ---
        while (i < a.length && a[i] == '0')
            i++;
        while (j < b.length && b[j] == '0')
            j++;

        size_t ai = i, bj = j;
        while (ai < a.length && a[ai].isDigit)
            ai++;
        while (bj < b.length && b[bj].isDigit)
            bj++;

        const da = a[i .. ai];
        const db = b[j .. bj];
        // Longer digit run (after stripping zeros) is the larger number.
        if (da.length != db.length)
            return da.length < db.length ? -1 : 1;
        foreach (k; 0 .. da.length)
            if (da[k] != db[k])
                return da[k] < db[k] ? -1 : 1;

        i = ai;
        j = bj;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Conformance
// ---------------------------------------------------------------------------

static assert(isVersion!DebianVersion && isVersionScheme!DebianVersion);
static assert(!hasOrderKey!DebianVersion);
static assert(!supportsPrerelease!DebianVersion);
static assert(!hasComponents!DebianVersion);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("deb.parse.realWorld")
@safe pure
unittest
{
    import sparkles.versions.testing : checkRoundTrip;

    checkRoundTrip!DebianVersion("1.2.3-4");
    checkRoundTrip!DebianVersion("2:4.13.1-0ubuntu0.16.04.1.1~");

    auto v = DebianVersion.parse("2:4.13.1-0ubuntu0.16.04.1.1~").value;
    assert(v.epoch == 2);
    assert(v.upstream == "4.13.1");
    assert(v.revision == "0ubuntu0.16.04.1.1~");
}

@("deb.ordering.tildeBeforeEverything")
@safe pure
unittest
{
    import sparkles.versions.testing : checkAscending;

    // ~~ < ~~a < ~ < "" < a, and 1.0~beta1 < 1.0.
    checkAscending!DebianVersion("1.0~beta1", "1.0");
    checkAscending!DebianVersion("1.0~~", "1.0~~a", "1.0~", "1.0", "1.0a");
}

@("deb.ordering.epochDominates")
@safe pure
unittest
{
    import sparkles.versions.testing : checkAscending;

    checkAscending!DebianVersion("9.0", "1:1.0");
    checkAscending!DebianVersion("1:1.0-1", "2:0.1-1");
}

@("deb.ordering.numericAndRevision")
@safe pure
unittest
{
    import sparkles.versions.testing : checkAscending;

    checkAscending!DebianVersion("1.2.3-4", "1.2.3-5", "1.2.4-1");
    // Leading zeros in digit runs are ignored.
    auto a = DebianVersion.parse("1.007").value;
    auto b = DebianVersion.parse("1.7").value;
    assert(a == b);
}

// ---------------------------------------------------------------------------
// Native range parsing (dpkg relations)
// ---------------------------------------------------------------------------

version (unittest)
{
    private DebianVersion debVer(string s) @safe pure nothrow
        => DebianVersion.parse(s).value;
}

@("deb.nativeRange.greaterEqual")
@safe pure
unittest
{
    auto r = DebianVersion.parseNativeRange(">= 2.0");
    assert(r.hasValue);
    auto rng = r.value;
    assert(rng == DebianVersion.Range.higherThan(debVer("2.0")));
    assert(rng.contains(debVer("2.0")));
    assert(rng.contains(debVer("2.1")));
    assert(!rng.contains(debVer("1.9")));
}

@("deb.nativeRange.strictlyGreater")
@safe pure
unittest
{
    auto r = DebianVersion.parseNativeRange(">> 2.0");
    assert(r.hasValue);
    auto rng = r.value;
    assert(rng == DebianVersion.Range.strictlyHigherThan(debVer("2.0")));
    assert(!rng.contains(debVer("2.0")));
    assert(rng.contains(debVer("2.1")));
}

@("deb.nativeRange.lessEqual")
@safe pure
unittest
{
    auto r = DebianVersion.parseNativeRange("<= 3.0");
    assert(r.hasValue);
    auto rng = r.value;
    assert(rng == DebianVersion.Range.lowerThan(debVer("3.0")));
    assert(rng.contains(debVer("3.0")));
    assert(rng.contains(debVer("2.9")));
    assert(!rng.contains(debVer("3.1")));
}

@("deb.nativeRange.strictlyLess")
@safe pure
unittest
{
    auto r = DebianVersion.parseNativeRange("<< 3.0");
    assert(r.hasValue);
    auto rng = r.value;
    assert(rng == DebianVersion.Range.strictlyLowerThan(debVer("3.0")));
    assert(!rng.contains(debVer("3.0")));
    assert(rng.contains(debVer("2.9")));
}

@("deb.nativeRange.equals")
@safe pure
unittest
{
    auto r = DebianVersion.parseNativeRange("= 1.2.3-4");
    assert(r.hasValue);
    auto rng = r.value;
    assert(rng == DebianVersion.Range.singleton(debVer("1.2.3-4")));
    assert(rng.contains(debVer("1.2.3-4")));
    assert(!rng.contains(debVer("1.2.3-5")));
}

@("deb.nativeRange.epochAndRevision")
@safe pure
unittest
{
    // A relation operand carries the full `[epoch:]upstream[-revision]` shape.
    auto r = DebianVersion.parseNativeRange(">= 2:4.13.1-0ubuntu0.16.04.1.1~");
    assert(r.hasValue);
    auto v = debVer("2:4.13.1-0ubuntu0.16.04.1.1~");
    assert(r.value == DebianVersion.Range.higherThan(v));
    assert(r.value.contains(v));
}

@("deb.nativeRange.rejectsMissingOperator")
@safe pure
unittest
{
    // A bare version with no relation is not a dpkg relation.
    assert(!DebianVersion.parseNativeRange("2.0").hasValue);
    // A lone operator with no version operand.
    assert(!DebianVersion.parseNativeRange(">=").hasValue);
    assert(!DebianVersion.parseNativeRange(">= ").hasValue);
    // Empty input.
    assert(!DebianVersion.parseNativeRange("").hasValue);
}
