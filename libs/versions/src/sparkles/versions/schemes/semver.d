/**
`SemVer` — strict Semantic Versioning 2.0.0.

The reference scheme. It declares every optional capability: an `orderKey`
that packs `major:minor:patch:stable` into a `ulong`, the SemVer triple in
`components` (so it gets caret/tilde), `isPrerelease`, and build metadata.

This module also hosts the SemVer identifier grammar
($(LREF compareSemVerPrerelease), $(LREF validateIdentifierList),
$(LREF IdentifierKind)) `package`-scoped, so the other SemVer-shaped schemes
(`Dmd`, …) reuse it without re-importing the engine.

See `docs/specs/versions/SPEC.md` §3 and `PRESETS.md` §3.1.
*/
module sparkles.versions.schemes.semver;

import sparkles.versions.parsing : parseOk, parseErr;

import sparkles.versions.parsing :
    NoGcHook, ParseError, ParseErrorCode, ParseExpected, ParseMode;
import sparkles.versions.ranges : Ranges;
import sparkles.versions.traits :
    compareComponents, hasComponents, hasOrderKey, hasSemVerComponents,
    hasBuildMetadata, isVersion, isVersionScheme, supportsPrerelease;

@safe:

// ---------------------------------------------------------------------------
// Field bit widths (shared with the SemVer-shaped schemes)
// ---------------------------------------------------------------------------

/// Bit width of the `major` field in the packed `orderKey` (max 32767).
package enum int majorBits = 15;
/// Bit width of the `minor` field (max 16,777,215).
package enum int minorBits = 24;
/// Bit width of the `patch` field (max 16,777,215).
package enum int patchBits = 24;

/// Maximum representable value of an `n`-bit unsigned field.
package enum ulong fieldMax(int n) = (n >= 64) ? ulong.max : ((1UL << n) - 1);

// ---------------------------------------------------------------------------
// SemVer
// ---------------------------------------------------------------------------

/**
A strict SemVer 2.0.0 version: `major.minor.patch` with optional
`-prerelease` and `+build` metadata.

Ordering follows SemVer §11: compare `major`, then `minor`, then `patch`
numerically; a version with a prerelease has lower precedence than the same
triple without one; prerelease identifiers compare per §11.4; build metadata
is ignored in ordering (§10).
*/
struct SemVer
{
    /// Numeric core. `major ≤ 32767`, `minor`/`patch ≤ 16,777,215`.
    uint major, minor, patch;

    /// Prerelease identifier list without the leading `-` (empty when the
    /// version is a stable release). Compared per SemVer §11.4.
    string prerelease;

    /// Build metadata without the leading `+`. Ignored in ordering (§10).
    string build;

    // ----- scheme handle -----

    /// This struct is its own version type.
    alias Version = SemVer;

    /// The range type for this scheme.
    alias Range = Ranges!SemVer;

    /// pURL type string.
    enum string purlType = "semver";

    /// Named numeric components, most-significant-first.
    enum string[] components = ["major", "minor", "patch"];

    // ----- required surface -----

    /// SemVer §11 three-way order.
    int opCmp(in SemVer other) const @safe pure nothrow @nogc
    {
        if (const c = compareComponents(this, other))
            return c;
        return compareSemVerPrerelease(prerelease, other.prerelease);
    }

    /// Equality consistent with $(LREF opCmp). Build metadata is ignored.
    bool opEquals(in SemVer other) const @safe pure nothrow @nogc
        => opCmp(other) == 0;

    /// Hash consistent with $(LREF opEquals).
    size_t toHash() const @trusted pure nothrow @nogc
    {
        import core.internal.hash : hashOf;
        auto h = hashOf(orderKey);
        return hashOf(prerelease, h);
    }

    /// Writes `major.minor.patch[-prerelease][+build]`.
    void toString(W)(ref W w) const
    {
        import sparkles.core_cli.text.writers : writeInteger;
        import std.range.primitives : put;

        writeInteger(w, major);
        put(w, '.');
        writeInteger(w, minor);
        put(w, '.');
        writeInteger(w, patch);
        if (prerelease.length)
        {
            put(w, '-');
            put(w, prerelease);
        }
        if (build.length)
        {
            put(w, '+');
            put(w, build);
        }
    }

    // ----- optional capabilities -----

    /// Monotone `ulong` order key: `major:minor:patch:stableFlag`, the
    /// stable flag (set when there is no prerelease) at the LSB. Equal keys
    /// fall through to $(LREF opCmp) for the prerelease-identifier tiebreak.
    ulong orderKey() const @safe pure nothrow @nogc
    {
        const stable = prerelease.length == 0 ? 1UL : 0UL;
        return (cast(ulong) major << (minorBits + patchBits + 1))
            | (cast(ulong) minor << (patchBits + 1))
            | (cast(ulong) patch << 1)
            | stable;
    }

    /// True when this version carries a prerelease tag.
    bool isPrerelease() const @safe pure nothrow @nogc
        => prerelease.length != 0;

    // ----- parsing -----

    /// Parses strict SemVer 2.0.0 syntax.
    static ParseExpected!SemVer parse(string s) @safe pure nothrow @nogc
        => parseSemVerShaped!SemVer(s, ParseMode.strict, noWidths);

    /// Parses with the loose compatibility forms: a leading `v`, leading
    /// `=`, surrounding spaces, partial versions (zero-filled), and leading
    /// zeroes on numeric components.
    static ParseExpected!SemVer parseLoose(string s) @safe pure nothrow @nogc
        => parseSemVerShaped!SemVer(s, ParseMode.loose, noWidths);

    /// Native node-semver range grammar. Stubbed in M1; filled in M2.
    static ParseExpected!Range parseNativeRange(string s)
        @safe pure nothrow @nogc
        => parseErr!(Range)(
            ParseError(ParseErrorCode.unexpectedCharacter, 0));
}

// ---------------------------------------------------------------------------
// SemVer-shaped parsing (shared by SemVer, Dmd, Tiny, CalVer*, Vim)
// ---------------------------------------------------------------------------

/// Per-component minimum print width: `0` = unpadded/unconstrained,
/// `n > 0` = the strict parser requires at least `n` digits (Dmd's 3-digit
/// minor, Vim's 4-digit patch, CalVer's 2-digit month/day).
package alias ComponentWidths = const(int)[];

/// All-unpadded widths for a 3-component SemVer-shaped scheme.
package enum ComponentWidths noWidths = [0, 0, 0];

/**
Generic SemVer-shaped parser, used by every scheme that follows the
`major.minor.patch[-prerelease][+build]` shape. The `widths` array gives the
strict minimum digit width per component (in `S.components` order); `0` means
unpadded with the strict leading-zero rule. Prerelease/build slots are only
populated when `S` declares the matching `prerelease`/`build` members.
*/
package ParseExpected!S parseSemVerShaped(S)(
    string input, ParseMode mode, ComponentWidths widths,
) @safe pure nothrow @nogc
{
    enum ncomp = S.components.length;
    assert(widths.length == ncomp);

    S result;
    scope const(char)[] s = input;
    size_t consumed = 0; // byte offset within `input` for error reporting

    // Helper closures advance `s` and `consumed` together.
    void advance(size_t n) @safe pure nothrow @nogc
    {
        s = s[n .. $];
        consumed += n;
    }

    if (mode == ParseMode.loose)
    {
        while (s.length && (s[0] == ' ' || s[0] == '\t'))
            advance(1);
        if (s.length && (s[0] == 'v' || s[0] == 'V' || s[0] == '='))
        {
            advance(1);
            while (s.length && (s[0] == ' ' || s[0] == '\t'))
                advance(1);
        }
    }

    if (s.length == 0)
        return parseErr!(S)(
            ParseError(ParseErrorCode.emptyInput, consumed));

    bool stop = false;
    static foreach (idx, name; S.components)
    {{
        if (!stop)
        {
            if (idx > 0)
            {
                if (s.length == 0 || s[0] != '.')
                {
                    if (mode == ParseMode.strict)
                        return parseErr!(S)(ParseError(
                            s.length == 0
                                ? ParseErrorCode.unexpectedEnd
                                : ParseErrorCode.unexpectedCharacter,
                            consumed));
                    stop = true;
                }
                else
                    advance(1);
            }

            if (!stop)
            {
                ulong value;
                ParseError e = readComponent(
                    s, consumed, mode, widths[idx],
                    componentFieldMax!(S, name, idx), value);
                // `e.offset == size_t.max` is the "no error" sentinel.
                if (e.offset != size_t.max)
                    return parseErr!(S)(e);
                __traits(getMember, result, name) =
                    cast(typeof(__traits(getMember, result, name))) value;
            }
        }
    }}

    // Prerelease / build slots, only when the scheme declares them.
    static if (__traits(hasMember, S, "prerelease"))
    {
        if (s.length && s[0] == '-')
        {
            advance(1);
            const start = consumed;
            // Prerelease runs up to a `+` (build separator) or end. Recover
            // the immutable slice from `input` directly (no `@system` cast):
            // `readSlot` advanced `consumed` past the slot.
            readSlot(s, consumed, '+');
            string seg = input[start .. consumed];
            auto check = validateIdentifierList(
                seg, start, IdentifierKind.prerelease);
            if (check.hasError)
                return parseErr!(S)(check.error);
            __traits(getMember, result, "prerelease") = seg;
        }
    }
    static if (__traits(hasMember, S, "build"))
    {
        if (s.length && s[0] == '+')
        {
            advance(1);
            const start = consumed;
            readSlot(s, consumed, '\0');
            string seg = input[start .. consumed];
            auto check = validateIdentifierList(
                seg, start, IdentifierKind.build);
            if (check.hasError)
                return parseErr!(S)(check.error);
            __traits(getMember, result, "build") = seg;
        }
    }

    if (mode == ParseMode.loose)
        while (s.length && (s[0] == ' ' || s[0] == '\t'))
            advance(1);

    if (s.length != 0)
        return parseErr!(S)(
            ParseError(ParseErrorCode.unexpectedCharacter, consumed));

    return parseOk(result);
}

/// Max value of the `idx`-th component's backing field. A scheme may declare
/// an `enum ulong[] componentMaxes` to override the bounds (e.g. `Tiny`'s
/// 16/8/8-bit split or the calendar schemes); otherwise the SemVer triple
/// uses the SemVer bit widths and any other field its natural type max.
private template componentFieldMax(S, string name, size_t idx)
{
    static if (is(typeof(S.componentMaxes) : const(ulong)[]))
        enum componentFieldMax = S.componentMaxes[idx];
    else static if (name == "major")
        enum componentFieldMax = fieldMax!majorBits;
    else static if (name == "minor")
        enum componentFieldMax = fieldMax!minorBits;
    else static if (name == "patch")
        enum componentFieldMax = fieldMax!patchBits;
    else
        enum componentFieldMax =
            cast(ulong) typeof(__traits(getMember, S.init, name)).max;
}

/**
Reads one numeric component, advancing the cursor. Returns a $(LREF ParseError)
whose `offset == size_t.max` signals success (so the caller can distinguish a
genuine `emptyInput`-coded error at offset 0 from "no error").
*/
private ParseError readComponent(
    ref scope const(char)[] s, ref size_t consumed, ParseMode mode,
    int width, ulong maxValue, out ulong value,
) @safe pure nothrow @nogc
{
    import std.ascii : isDigit;

    enum ParseError success = ParseError(ParseErrorCode.init, size_t.max);
    const start = consumed;

    if (s.length == 0)
        return ParseError(ParseErrorCode.unexpectedEnd, consumed);
    if (!s[0].isDigit)
        return ParseError(ParseErrorCode.unexpectedCharacter, consumed);

    const firstDigit = s[0];
    value = 0;
    size_t len = 0;
    while (s.length && s[0].isDigit)
    {
        const digit = cast(ulong)(s[0] - '0');
        if (value > (ulong.max - digit) / 10)
            return ParseError(ParseErrorCode.numericOverflow, consumed);
        value = value * 10 + digit;
        s = s[1 .. $];
        consumed++;
        len++;
    }

    if (value > maxValue)
        return ParseError(ParseErrorCode.numericOverflow, start);

    if (width > 0)
    {
        // Width-constrained: at least `width` digits; leading zeroes are
        // part of the canonical format.
        if (len < cast(size_t) width)
            return ParseError(ParseErrorCode.widthMismatch, start);
    }
    else if (mode == ParseMode.strict && len > 1 && firstDigit == '0')
    {
        // Strict mode rejects leading zeroes on unpadded components.
        return ParseError(ParseErrorCode.leadingZero, start);
    }

    return success;
}

/// Reads a slot (prerelease/build) segment up to `terminator` (or end when
/// `terminator == '\0'`), advancing the cursor.
// Advances `s`/`consumed` past the next slot (up to `terminator` or end).
// Callers recover the slot text as an immutable slice of the original input
// via the recorded `consumed` offsets, so no slice need be returned.
private void readSlot(
    ref scope const(char)[] s, ref size_t consumed, char terminator,
) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < s.length && !(terminator != '\0' && s[i] == terminator))
        i++;
    s = s[i .. $];
    consumed += i;
}

// ---------------------------------------------------------------------------
// SemVer identifier grammar (package-scoped, reused by Dmd, …)
// ---------------------------------------------------------------------------

/// Discriminates SemVer prerelease (numeric identifiers must not have
/// leading zeros) from build metadata (no such rule).
package enum IdentifierKind { prerelease, build }

/**
Validates a dot-separated identifier list per SemVer 2.0.0 §9 (prerelease)
or §10 (build metadata). `listOffset` is the byte offset of `list` within
the original input; reported errors carry the offset of the failing
character.
*/
package ParseExpected!void validateIdentifierList(
    in string list, size_t listOffset, IdentifierKind kind,
) @safe pure nothrow @nogc
{
    import std.algorithm.searching : all;
    import std.ascii : isAlphaNum, isDigit;
    import std.utf : byCodeUnit;

    if (list.length == 0)
        return parseErr!(void)(
            ParseError(ParseErrorCode.invalidIdentifier, listOffset));

    size_t segStart;
    while (true)
    {
        size_t segEnd = segStart;
        while (segEnd < list.length && list[segEnd] != '.')
            segEnd++;

        const seg = list[segStart .. segEnd];
        const segOff = listOffset + segStart;

        if (seg.length == 0)
            return parseErr!(void)(
                ParseError(ParseErrorCode.invalidIdentifier, segOff));

        foreach (idx, c; seg)
        {
            if (!(c.isAlphaNum || c == '-'))
                return parseErr!(void)(
                    ParseError(ParseErrorCode.invalidIdentifier, segOff + idx));
        }

        if (kind == IdentifierKind.prerelease
            && seg.length > 1
            && seg[0] == '0'
            && seg.byCodeUnit.all!isDigit)
            return parseErr!(void)(
                ParseError(ParseErrorCode.leadingZero, segOff));

        if (segEnd == list.length)
            break;
        segStart = segEnd + 1;
    }

    return parseOk();
}

/**
SemVer §11.4 precedence for two prerelease identifier lists:

$(UL
    $(LI Empty (no prerelease) ranks higher than any non-empty list.)
    $(LI Lists are compared identifier-by-identifier left to right.)
    $(LI Numeric identifiers compare numerically; alphanumeric compare
        lexically; numeric < alphanumeric at the same position.)
    $(LI A shorter prefix loses against a longer one with an equal prefix.)
)
*/
package int compareSemVerPrerelease(in string lhs, in string rhs)
    @safe pure nothrow @nogc
{
    if (lhs.length == 0)
        return rhs.length == 0 ? 0 : 1;
    if (rhs.length == 0)
        return -1;

    size_t li, ri;
    while (li < lhs.length || ri < rhs.length)
    {
        if (li >= lhs.length)
            return -1;
        if (ri >= rhs.length)
            return 1;

        size_t lEnd = li;
        while (lEnd < lhs.length && lhs[lEnd] != '.')
            lEnd++;
        size_t rEnd = ri;
        while (rEnd < rhs.length && rhs[rEnd] != '.')
            rEnd++;

        if (const c = compareSegment(lhs[li .. lEnd], rhs[ri .. rEnd]))
            return c;

        li = lEnd < lhs.length ? lEnd + 1 : lEnd;
        ri = rEnd < rhs.length ? rEnd + 1 : rEnd;
    }
    return 0;
}

private int compareSegment(in string lhs, in string rhs)
    @safe pure nothrow @nogc
{
    import std.algorithm.comparison : cmp;

    const lhsNumeric = isNumericIdentifier(lhs);
    const rhsNumeric = isNumericIdentifier(rhs);

    if (lhsNumeric && rhsNumeric)
    {
        if (lhs.length != rhs.length)
            return lhs.length < rhs.length ? -1 : 1;
        return cmp(lhs, rhs);
    }

    if (lhsNumeric)
        return -1;
    if (rhsNumeric)
        return 1;

    return cmp(lhs, rhs);
}

private bool isNumericIdentifier(in string value) @safe pure nothrow @nogc
{
    import std.algorithm.searching : all;
    import std.ascii : isDigit;
    import std.utf : byCodeUnit;

    return value.length > 0 && value.byCodeUnit.all!isDigit;
}

// ---------------------------------------------------------------------------
// Conformance
// ---------------------------------------------------------------------------

static assert(isVersion!SemVer && isVersionScheme!SemVer);
static assert(hasOrderKey!SemVer);
static assert(supportsPrerelease!SemVer);
static assert(hasComponents!SemVer);
static assert(hasSemVerComponents!SemVer);
static assert(hasBuildMetadata!SemVer);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("semver.parse.realWorld")
@safe pure
unittest
{
    import sparkles.versions.testing : checkRoundTrip;

    static immutable cases = [
        "20.13.1", "1.78.0", "1.30.0", "17.3.0", "18.3.1", "6.8.9",
        "2.45.1", "8.3.7", "3.3.1", "1.26.0", "2.4.59", "7.2.4",
        "7.0.8", "3.45.3", "8.7.1", "7.0.1", "14.5.1", "26.1.1",
        "1.0.0-rc.1", "1.0.0-alpha.1+build.5",
    ];
    foreach (s; cases)
        checkRoundTrip!SemVer(s);
}

@("semver.ordering.precedenceChain")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkAscending;

    checkAscending!SemVer(
        "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta",
        "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
        "1.0.0-rc.1", "1.0.0");
}

@("semver.ordering.majorDominates")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkAscending;

    // 2.0.0-alpha > 1.999.999.
    checkAscending!SemVer("1.999999.999999", "2.0.0-alpha", "2.0.0");
}

@("semver.prerelease.lowerThanRelease")
@safe pure nothrow @nogc
unittest
{
    auto pre = SemVer.parse("1.0.0-rc.1").value;
    auto rel = SemVer.parse("1.0.0").value;
    assert(pre < rel);
    assert(pre.isPrerelease);
    assert(!rel.isPrerelease);
}

@("semver.build.ignoredInOrdering")
@safe pure nothrow @nogc
unittest
{
    auto a = SemVer.parse("1.0.0+build.1").value;
    auto b = SemVer.parse("1.0.0+build.2").value;
    assert(a == b);
    assert(a.build == "build.1");
    assert(b.build == "build.2");
}

@("semver.orderKey.matchesOpCmp")
@safe pure nothrow @nogc
unittest
{
    static immutable corpus = [
        "0.0.0", "0.0.1", "0.1.0", "1.0.0", "1.2.3", "2.0.0",
        "1.0.0-alpha", "1.0.0",
    ];
    foreach (i; 0 .. corpus.length)
        foreach (j; 0 .. corpus.length)
        {
            const a = SemVer.parse(corpus[i]).value;
            const b = SemVer.parse(corpus[j]).value;
            if (a.orderKey != b.orderKey)
            {
                const k = a.orderKey < b.orderKey ? -1 : 1;
                const c = a.opCmp(b) < 0 ? -1 : (a.opCmp(b) > 0 ? 1 : 0);
                assert(k == c);
            }
        }
}

@("semver.loose.normalisation")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    static immutable cases = [
        ["v1.2.3", "1.2.3"],
        ["= 1.2.3", "1.2.3"],
        ["1", "1.0.0"],
        ["1.2", "1.2.0"],
        ["1.2-beta.5", "1.2.0-beta.5"],
        ["01.002.0003", "1.2.3"],
    ];
    foreach (tc; cases)
    {
        auto parsed = SemVer.parseLoose(tc[0]);
        assert(parsed.hasValue, tc[0]);
        checkToString(parsed.value, tc[1]);
    }
}

@("semver.parse.rejects")
@safe pure nothrow @nogc
unittest
{
    import sparkles.versions.testing : checkRejects;

    static immutable bad = [
        "", "   ", "1.2", "1.2.3.4", "v1.2.3", "a.b.c", "01.2.3",
        "1.2.3-", "1.2.3+", "1.2.3-+build", "1.0.0-alpha..1",
        "1.2.3-01", "100000.0.0", "0.16777216.0",
    ];
    foreach (s; bad)
        checkRejects!SemVer(s);
}
