/**
`MavenVersion` — Maven's `ComparableVersion` ordering.

A _structural_ scheme. The string is tokenised at `.`, `-`, `_`, and
digit↔letter transitions; trailing "null" tokens (`0`, empty, `final`, `ga`,
`release`) are trimmed so that `1.0.0 == 1`. Numeric tokens compare
numerically; qualifier tokens compare by the fixed rank

```
alpha < beta < milestone < rc (= cr) < snapshot
    < ""(= ga = final = release) < sp
```

Comparison is case-insensitive, and `alpha`/`beta`/`milestone` may be
abbreviated `a`/`b`/`m` when directly followed by a number. No fixed-width
integer key reproduces this order, so `maven` declares **no** `orderKey` and
`opCmp` compares token lists.

See `docs/specs/versions/PRESETS.md` §3.9.
*/
module sparkles.versions.schemes.maven;

import sparkles.versions.parsing : parseOk, parseErr;

import sparkles.versions.parsing :
    NoGcHook, ParseError, ParseErrorCode, ParseExpected;
import sparkles.versions.ranges : Ranges;
import sparkles.versions.traits :
    hasComponents, hasOrderKey,
    isVersion, isVersionScheme, supportsPrerelease;

@safe:

/// Discriminates a Maven token's kind.
enum TokenKind : ubyte
{
    number,    /// a numeric run
    qualifier, /// a recognised or arbitrary qualifier string
}

/// A single Maven `ComparableVersion` token.
struct Token
{
    TokenKind kind; /// number or qualifier
    ulong num;      /// value when `kind == number`
    string text;    /// verbatim (lowercased) text when `kind == qualifier`
}

/// The rank of the well-known release qualifier (`"" = ga = final = release`),
/// against which an unknown qualifier and the numeric tokens are positioned.
private enum int releaseRank = 5;

/// Returns the ordering rank of a qualifier string per the Maven table.
/// Unknown qualifiers rank above the release marker and sort lexically.
private int qualifierRank(in string q) @safe pure nothrow @nogc
{
    switch (q)
    {
        case "alpha": return 0;
        case "beta": return 1;
        case "milestone": return 2;
        case "rc": case "cr": return 3;
        case "snapshot": return 4;
        case "": case "ga": case "final": case "release": return releaseRank;
        case "sp": return 6;
        default: return 7; // unknown qualifier ranks above `sp`, sorts lexically
    }
}

/// Whether a qualifier is a trailing "null" token that may be trimmed.
private bool isNullQualifier(in string q) @safe pure nothrow @nogc
    => qualifierRank(q) == releaseRank;

/**
A Maven version: its trimmed list of comparison tokens plus the verbatim
input for round-tripping.
*/
struct MavenVersion
{
    /// The canonical, trailing-null-trimmed token list driving `opCmp`.
    Token[] tokens;

    /// The original input string, preserved for `toString`.
    string raw;

    // ----- scheme handle -----

    alias Version = MavenVersion;
    alias Range = Ranges!MavenVersion;
    enum string purlType = "maven";

    // ----- required surface -----

    /// `ComparableVersion` three-way order over the token lists.
    int opCmp(in MavenVersion other) const @safe pure nothrow @nogc
    {
        const n = tokens.length > other.tokens.length
            ? tokens.length : other.tokens.length;
        foreach (i; 0 .. n)
        {
            // A missing token compares as the "null" padding for its side.
            // A `0`/release-marker pad is *equal* to null, so the comparison
            // must continue past it to the remaining tokens rather than
            // returning the `0`.
            if (i >= tokens.length)
            {
                if (const c = -compareToNull(other.tokens[i]))
                    return c;
            }
            else if (i >= other.tokens.length)
            {
                if (const c = compareToNull(tokens[i]))
                    return c;
            }
            else if (const c = compareToken(tokens[i], other.tokens[i]))
                return c;
        }
        return 0;
    }

    bool opEquals(in MavenVersion other) const @safe pure nothrow @nogc
        => opCmp(other) == 0;

    size_t toHash() const @trusted pure nothrow @nogc
    {
        import core.internal.hash : hashOf;
        size_t h = 0;
        foreach (t; tokens)
        {
            h = hashOf(t.kind, h);
            h = hashOf(t.num, h);
            h = hashOf(t.text, h);
        }
        return h;
    }

    /// Writes the verbatim input string.
    void toString(W)(ref W w) const
    {
        import std.range.primitives : put;
        put(w, raw);
    }

    // ----- optional capabilities -----

    /// True when the version's trailing qualifier ranks below the release
    /// marker (alpha/beta/milestone/rc/snapshot).
    bool isPrerelease() const @safe pure nothrow @nogc
    {
        // Find the last qualifier token; if it ranks below release, this is a
        // pre-release.
        foreach_reverse (t; tokens)
            if (t.kind == TokenKind.qualifier)
                return qualifierRank(t.text) < releaseRank;
        return false;
    }

    // ----- parsing -----

    /// Parses any string into its `ComparableVersion` token list — Maven's
    /// parser accepts essentially anything.
    static ParseExpected!MavenVersion parse(string s) @safe pure nothrow
    {
        MavenVersion result;
        result.raw = s;
        result.tokens = tokenise(s);
        return parseOk(result);
    }

    /// Native Maven interval-notation range grammar. Stubbed in M1; filled
    /// in M2.
    static ParseExpected!Range parseNativeRange(string s) @safe pure nothrow
        => parseErr!(Range)(
            ParseError(ParseErrorCode.unexpectedCharacter, 0));
}

// ---------------------------------------------------------------------------
// Token comparison
// ---------------------------------------------------------------------------

/// Three-way compares two tokens. A number outranks a qualifier (numbers
/// sit at the release boundary above all pre-release qualifiers but below
/// `sp`/unknown — modelled by ranking a number just above the release
/// marker).
private int compareToken(in Token a, in Token b) @safe pure nothrow @nogc
{
    if (a.kind == TokenKind.number && b.kind == TokenKind.number)
        return a.num < b.num ? -1 : (a.num > b.num ? 1 : 0);
    if (a.kind == TokenKind.number)
        return -compareToNull(b);
    if (b.kind == TokenKind.number)
        return compareToNull(a);

    // Both qualifiers: compare by rank, then lexically for unknowns.
    const ra = qualifierRank(a.text), rb = qualifierRank(b.text);
    if (ra != rb)
        return ra < rb ? -1 : 1;
    import std.algorithm.comparison : cmp;
    const c = cmp(a.text, b.text);
    return c < 0 ? -1 : (c > 0 ? 1 : 0);
}

/// Compares a token against an absent (padding) token, which behaves as the
/// release-marker null. A number is `> null`; a qualifier compares by rank.
private int compareToNull(in Token t) @safe pure nothrow @nogc
{
    if (t.kind == TokenKind.number)
        return t.num == 0 ? 0 : 1;
    const r = qualifierRank(t.text);
    if (r == releaseRank)
        return 0;
    return r < releaseRank ? -1 : 1;
}

// ---------------------------------------------------------------------------
// Tokeniser
// ---------------------------------------------------------------------------

/// Tokenises `input` into the trailing-null-trimmed token list.
private Token[] tokenise(string input) @safe pure nothrow
{
    import std.ascii : isDigit, toLower;

    Token[] tokens;
    char[] buf;
    bool inNumber = false;
    bool haveRun = false;

    void flush() @safe pure nothrow
    {
        if (!haveRun)
            return;
        if (inNumber)
        {
            ulong v = 0;
            foreach (c; buf)
                v = v * 10 + (c - '0');
            tokens ~= Token(TokenKind.number, v, null);
        }
        else
            tokens ~= Token(TokenKind.qualifier, 0, expand(cast(string) buf.idup));
        buf = null;
        haveRun = false;
    }

    foreach (ch; input)
    {
        const c = cast(char) toLower(ch);
        if (c == '.' || c == '-' || c == '_')
        {
            flush();
            continue;
        }
        const digit = c.isDigit;
        if (haveRun && digit != inNumber)
            flush(); // digit↔letter transition splits a token
        inNumber = digit;
        haveRun = true;
        buf ~= c;
    }
    flush();

    // Trim trailing "null" tokens: numeric 0 and release-marker qualifiers.
    while (tokens.length)
    {
        const t = tokens[$ - 1];
        const isNull = (t.kind == TokenKind.number && t.num == 0)
            || (t.kind == TokenKind.qualifier && isNullQualifier(t.text));
        if (!isNull)
            break;
        tokens = tokens[0 .. $ - 1];
    }
    return tokens;
}

/// Expands the single-letter qualifier abbreviations `a`/`b`/`m` and the
/// `cr` synonym; other strings pass through unchanged.
private string expand(string q) @safe pure nothrow
{
    switch (q)
    {
        case "a": return "alpha";
        case "b": return "beta";
        case "m": return "milestone";
        case "cr": return "rc";
        default: return q;
    }
}

// ---------------------------------------------------------------------------
// Conformance
// ---------------------------------------------------------------------------

static assert(isVersion!MavenVersion && isVersionScheme!MavenVersion);
static assert(!hasOrderKey!MavenVersion);
static assert(supportsPrerelease!MavenVersion);
static assert(!hasComponents!MavenVersion);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("maven.parse.realWorld")
@safe pure
unittest
{
    import sparkles.versions.testing : checkRoundTrip;

    checkRoundTrip!MavenVersion("1.0");
    checkRoundTrip!MavenVersion("1.0-SNAPSHOT");
    checkRoundTrip!MavenVersion("1.0-alpha-1");
    checkRoundTrip!MavenVersion("1.0-rc1");
    checkRoundTrip!MavenVersion("1.0-1");
}

@("maven.ordering.qualifierRank")
@safe pure
unittest
{
    import sparkles.versions.testing : checkAscending;

    checkAscending!MavenVersion(
        "1.0-alpha-1", "1.0-beta-1", "1.0-milestone-1", "1.0-rc1",
        "1.0-SNAPSHOT", "1.0", "1.0-sp1");
}

@("maven.ordering.trailingNullEquivalence")
@safe pure
unittest
{
    // 1.0.0 == 1 (trailing zero tokens trimmed).
    auto a = MavenVersion.parse("1.0.0").value;
    auto b = MavenVersion.parse("1").value;
    assert(a == b);

    // ga / final / release are release-marker synonyms.
    auto c = MavenVersion.parse("1.0-final").value;
    assert(c == MavenVersion.parse("1.0").value);
}

@("maven.ordering.caseInsensitive")
@safe pure
unittest
{
    auto a = MavenVersion.parse("1.0-RC1").value;
    auto b = MavenVersion.parse("1.0-rc1").value;
    assert(a == b);
}

@("maven.parse.abbreviations")
@safe pure
unittest
{
    // alpha/beta/milestone may be abbreviated a/b/m before a number, and
    // `cr` is a synonym for `rc` — so the abbreviated forms compare equal
    // to their long forms.
    assert(MavenVersion.parse("1.0-a1").value
        == MavenVersion.parse("1.0-alpha-1").value);
    assert(MavenVersion.parse("1.0-cr1").value
        == MavenVersion.parse("1.0-rc1").value);
}

@("maven.prerelease.flag")
@safe pure
unittest
{
    assert(MavenVersion.parse("1.0-SNAPSHOT").value.isPrerelease);
    assert(MavenVersion.parse("1.0-alpha-1").value.isPrerelease);
    assert(!MavenVersion.parse("1.0").value.isPrerelease);
    assert(!MavenVersion.parse("1.0-sp1").value.isPrerelease);
}
