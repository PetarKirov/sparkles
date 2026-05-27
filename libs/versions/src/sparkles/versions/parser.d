/**
Generic parser for $(LREF Version) layouts.

Supports strict SemVer 2.0.0 syntax and a $(LREF ParseMode.loose)
mode that accepts common compatibility forms (`v1.2.3`, `1`, `1.2`).
The parser is generic over the layout — component count, per-component
`printWidth`, and bitfield bounds are all derived from
`Layout.descriptor` at compile time.

A layout may opt out of the generic parser by providing a static
`customParse(string s, ParseMode mode)` member; the engine
defers to it entirely.

See `docs/specs/versions/SPEC.md` §8.
*/
module sparkles.versions.parser;

import expected : Expected, err, ok;
import sparkles.versions.engine;

@safe:

// ---------------------------------------------------------------------------
// Public API surface
// ---------------------------------------------------------------------------

/// Parsing mode for $(LREF parse).
enum ParseMode
{
    /// Accept only Semantic Versioning 2.0.0 syntax.
    strict,

    /// Accept common compatibility forms such as `v1.2.3`, `1`, and `1.2`.
    loose,
}

/// Machine-readable parse error code.
enum ParseErrorCode
{
    emptyInput,
    unexpectedCharacter,
    unexpectedEnd,
    leadingZero,
    emptyIdentifier,
    invalidIdentifier,
    duplicateBuildMetadata,
    numericOverflow,
    widthMismatch,
}

/// Structured parse error.
struct ParseError
{
    ParseErrorCode code; /// Error kind.
    size_t index;              /// Byte offset where parsing failed.
}

package struct ParseExpectedHook
{
    static immutable bool enableDefaultConstructor = false;
}

package alias ParseExpected(T) = Expected!(
    T, ParseError, ParseExpectedHook,
);

/// Expected result of $(LREF parse) for a given layout.
template ParseResult(Layout)
{
    alias ParseResult = ParseExpected!(Version!Layout);
}

// ---------------------------------------------------------------------------
// Entry points
// ---------------------------------------------------------------------------

/**
Parses `s` into a `Version!Layout` value. If `Layout` declares a
`customParse(string, ParseMode)` static member the engine
delegates to it; otherwise the generic numeric-component parser is
used.
*/
ParseResult!Layout parse(Layout)(string s, ParseMode mode)
    @safe pure nothrow @nogc
{
    static if (__traits(hasMember, Layout, "customParse"))
        return Layout.customParse(s, mode);
    else
        return parseGeneric!Layout(s, mode);
}

// ---------------------------------------------------------------------------
// Generic numeric-component parser
// ---------------------------------------------------------------------------

package ParseResult!Layout parseGeneric(Layout)(string s, ParseMode mode)
    @safe pure nothrow @nogc
{
    Version!Layout result;
    size_t i;

    if (mode == ParseMode.loose)
        skipHorizontalSpace(s, i);

    if (i >= s.length)
        return parseErr!Layout(ParseErrorCode.emptyInput, i);

    if (mode == ParseMode.loose)
        skipLoosePrefix(s, i);

    if (i >= s.length)
        return parseErr!Layout(ParseErrorCode.emptyInput, i);

    bool stopComponents = false;
    static foreach (idx, comp; Layout.descriptor.components)
    {{
        if (!stopComponents)
        {
            if (idx > 0)
            {
                if (i >= s.length || s[i] != '.')
                {
                    if (mode == ParseMode.strict)
                        return parseErr!Layout(
                            i >= s.length
                                ? ParseErrorCode.unexpectedEnd
                                : ParseErrorCode.unexpectedCharacter,
                            i);
                    stopComponents = true;
                }
                else
                    i++;
            }

            if (!stopComponents)
            {
                ulong value;
                auto numResult = parseNumericComponent(
                    s, i, mode, comp.component.printWidth,
                    componentMaxValue(comp.bitWidth), value);
                if (numResult.hasError)
                    return parseErr!Layout(numResult.error);
                __traits(getMember, result.core, comp.name) =
                    cast(typeof(__traits(getMember, result.core, comp.name)))
                        value;
            }
        }
    }}

    // Default: stable (no prerelease). Cleared if a `-` segment follows.
    static if (Layout.descriptor.internalFlag.name.length > 0)
        __traits(getMember, result.core, Layout.descriptor.internalFlag.name)
            = true;

    // Prerelease parsing (only if the layout has the slot).
    static if (hasPrerelease!Layout)
    {
        if (i < s.length && s[i] == '-')
        {
            const start = ++i;
            while (i < s.length && s[i] != '+')
                i++;
            if (i == start)
                return parseErr!Layout(
                    ParseErrorCode.emptyIdentifier, start);
            auto check = validateIdentifierList(
                s[start .. i], start, IdentifierKind.prerelease);
            if (check.hasError)
                return parseErr!Layout(check.error);
            result.prerelease = s[start .. i];

            // Mark as prerelease (clear stable flag if present).
            static if (Layout.descriptor.internalFlag.name.length > 0)
                __traits(getMember, result.core,
                    Layout.descriptor.internalFlag.name) = false;
        }
    }

    // Build-metadata parsing (only if the layout has the slot).
    static if (hasBuild!Layout)
    {
        if (i < s.length && s[i] == '+')
        {
            import std.algorithm.searching : countUntil;
            import std.utf : byCodeUnit;

            const start = ++i;
            auto slice = s[start .. $];
            if (slice.length == 0)
                return parseErr!Layout(
                    ParseErrorCode.emptyIdentifier, start);
            const dupPlus = slice.byCodeUnit.countUntil('+');
            if (dupPlus >= 0)
                return parseErr!Layout(
                    ParseErrorCode.duplicateBuildMetadata,
                    start + dupPlus);
            auto check = validateIdentifierList(
                slice, start, IdentifierKind.build);
            if (check.hasError)
                return parseErr!Layout(check.error);
            result.build = slice;
            i = s.length;
        }
    }

    if (mode == ParseMode.loose)
        skipHorizontalSpace(s, i);

    if (i != s.length)
        return parseErr!Layout(
            s[i] == '+'
                ? ParseErrorCode.duplicateBuildMetadata
                : ParseErrorCode.unexpectedCharacter,
            i);

    return ok!(ParseError, ParseExpectedHook)(result);
}

// ---------------------------------------------------------------------------
// Component parsing
// ---------------------------------------------------------------------------

private ulong componentMaxValue(int bitWidth) pure nothrow @nogc @safe
{
    return bitWidth >= 64 ? ulong.max : ((1UL << bitWidth) - 1);
}

private alias ValidationResult = ParseExpected!void;

package ValidationResult parseNumericComponent(
    in string s,
    ref size_t i,
    ParseMode mode,
    int printWidth,
    ulong maxValue,
    out ulong value,
) @safe pure nothrow @nogc
{
    import std.ascii : isDigit;

    const start = i;
    if (i >= s.length)
        return parseErrV(ParseErrorCode.unexpectedEnd, i);
    if (!s[i].isDigit)
        return parseErrV(ParseErrorCode.unexpectedCharacter, i);

    value = 0;
    while (i < s.length && s[i].isDigit)
    {
        const digit = cast(ulong)(s[i] - '0');
        if (value > (ulong.max - digit) / 10)
            return parseErrV(ParseErrorCode.numericOverflow, i);
        value = value * 10 + digit;
        i++;
    }

    if (value > maxValue)
        return parseErrV(ParseErrorCode.numericOverflow, start);

    const len = i - start;

    if (printWidth > 0)
    {
        // Width-constrained component: input must be at least `printWidth`
        // digits. Leading zeros are part of the format and accepted.
        if (len < cast(size_t) printWidth)
            return parseErrV(ParseErrorCode.widthMismatch, start);
    }
    else if (mode == ParseMode.strict && len > 1 && s[start] == '0')
    {
        // Strict SemVer rejects leading zeros on unpadded numeric components.
        return parseErrV(ParseErrorCode.leadingZero, start);
    }

    return ok!(ParseError, ParseExpectedHook)();
}

// ---------------------------------------------------------------------------
// Identifier validation (prerelease / build)
// ---------------------------------------------------------------------------

package enum IdentifierKind { prerelease, build }

package ValidationResult validateIdentifierList(
    in string list, size_t listOffset, IdentifierKind kind,
) @safe pure nothrow @nogc
{
    import std.algorithm.searching : all;
    import std.ascii : isAlphaNum, isDigit;
    import std.utf : byCodeUnit;

    if (list.length == 0)
        return ok!(ParseError, ParseExpectedHook)();

    size_t segStart;
    while (true)
    {
        size_t segEnd = segStart;
        while (segEnd < list.length && list[segEnd] != '.')
            segEnd++;

        const seg = list[segStart .. segEnd];
        const segOff = listOffset + segStart;

        if (seg.length == 0)
            return parseErrV(ParseErrorCode.emptyIdentifier, segOff);

        foreach (idx, c; seg)
        {
            if (!(c.isAlphaNum || c == '-'))
                return parseErrV(
                    ParseErrorCode.invalidIdentifier, segOff + idx);
        }

        if (kind == IdentifierKind.prerelease
            && seg.length > 1
            && seg[0] == '0'
            && seg.byCodeUnit.all!isDigit)
            return parseErrV(ParseErrorCode.leadingZero, segOff);

        if (segEnd == list.length) break;
        segStart = segEnd + 1;
    }

    return ok!(ParseError, ParseExpectedHook)();
}

// ---------------------------------------------------------------------------
// Loose-mode utilities
// ---------------------------------------------------------------------------

private void skipHorizontalSpace(in string s, ref size_t i)
    @safe pure nothrow @nogc
{
    import std.algorithm.comparison : among;

    while (i < s.length && s[i].among(' ', '\t'))
        i++;
}

private void skipLoosePrefix(in string s, ref size_t i)
    @safe pure nothrow @nogc
{
    import std.algorithm.comparison : among;

    if (i >= s.length)
        return;

    if (s[i].among('=', 'v', 'V'))
    {
        i++;
        skipHorizontalSpace(s, i);
    }
}

// ---------------------------------------------------------------------------
// Error constructors
// ---------------------------------------------------------------------------

package ParseExpected!(Version!Layout) parseErr(Layout)(
    ParseErrorCode code, size_t index,
) @safe pure nothrow @nogc
{
    return err!(Version!Layout, ParseExpectedHook)(
        ParseError(code: code, index: index));
}

package ParseExpected!(Version!Layout) parseErr(Layout)(
    ParseError error,
) @safe pure nothrow @nogc
{
    return err!(Version!Layout, ParseExpectedHook)(error);
}

private ValidationResult parseErrV(ParseErrorCode code, size_t index)
    @safe pure nothrow @nogc
{
    return err!(void, ParseExpectedHook)(
        ParseError(code: code, index: index));
}

private ValidationResult parseErrV(ParseError error)
    @safe pure nothrow @nogc
{
    return err!(void, ParseExpectedHook)(error);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.versions.layouts :
        DmdLayout, SemVerLayout, TinyLayout;
}

@("parser.SemVer.strictValid")
@safe pure nothrow @nogc
unittest
{
    static immutable cases = [
        "0.0.0",
        "1.0.0",
        "1.2.3-alpha.1",
        "1.2.3+build.42",
        "1.2.3-alpha.1+build.42",
        "1.2.3-rc1-with-hyphen",
        "1.2.3+build.01",
        "1.2.3-0abc123",
        "1.0.0-0",
        "1.2.3-1.alpha1.9+build5.7.3aedf",
        "1.2.3-0a",
        "0.4.0-beta.1+0851523",
    ];

    foreach (ver; cases)
        assert(parse!SemVerLayout(ver, ParseMode.strict).hasValue, ver);
}

@("parser.SemVer.looseNormalisation")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    static immutable cases = [
        ["v1.2.3", "1.2.3"],
        ["= 1.2.3", "1.2.3"],
        ["1", "1.0.0"],
        ["1.2", "1.2.0"],
        ["1.2-5", "1.2.0-5"],
        ["1.2-beta.5", "1.2.0-beta.5"],
        ["01.002.0003", "1.2.3"],
    ];

    foreach (testCase; cases)
    {
        auto parsed = parse!SemVerLayout(testCase[0], ParseMode.loose);
        assert(parsed.hasValue, testCase[0]);
        checkToString(parsed.value, testCase[1]);
    }
}

@("parser.SemVer.invalid")
@safe pure nothrow @nogc
unittest
{
    static immutable strictInvalid = [
        "",
        "   ",
        "1.2",
        "1.2.3.4",
        "1.2.3 abc",
        "v1.2.3",
        "a.b.c",
        "01.2.3",
        "07",
        "1.2.3-",
        "1.2.3+",
        "1.2.3++",
        "1.2.3-+build",
        "1.2.3-.",
        "1.2.3-alpha..",
        "1.0.0-alpha_beta",
        "1.0.0-alpha..1",
        "1.2.3-0123",
        "1.2.3-01",
        "9.8.7+meta+meta",
        ".1.2.3",
        "-1.2.3",
        "111111111111111111111.0.0", // 21-digit major overflow
        "100000.0.0", // overflows 15-bit major (max 32767)
    ];

    foreach (ver; strictInvalid)
        assert(parse!SemVerLayout(ver, ParseMode.strict).hasError, ver);
}

@("parser.SemVer.overflow")
@safe pure nothrow @nogc
unittest
{
    // 15-bit major: max 32767.
    assert(parse!SemVerLayout("32767.0.0", ParseMode.strict).hasValue);
    assert(parse!SemVerLayout("32768.0.0", ParseMode.strict).hasError);

    // 24-bit minor/patch: max 16777215.
    assert(parse!SemVerLayout("0.16777215.0", ParseMode.strict).hasValue);
    assert(parse!SemVerLayout("0.16777216.0", ParseMode.strict).hasError);
}

@("parser.DmdLayout.requires3DigitMinor")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    // Real Dlang versions across eras.
    auto v079 = parse!DmdLayout("2.079.0", ParseMode.strict);
    assert(v079.hasValue);
    checkToString(v079.value, "2.079.0");

    auto v111 = parse!DmdLayout("2.111.0", ParseMode.strict);
    assert(v111.hasValue);
    checkToString(v111.value, "2.111.0");

    // 2.79.0 is a leading-zero violation under the printWidth=3 rule.
    assert(parse!DmdLayout("2.79.0", ParseMode.strict).hasError);
}

@("parser.TinyLayout.parse")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : checkToString;

    auto v = parse!TinyLayout("100.50.25", ParseMode.strict);
    assert(v.hasValue);
    checkToString(v.value, "100.50.25");
}
