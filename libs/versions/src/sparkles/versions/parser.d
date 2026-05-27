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

// ParseMode, ParseError, ParseErrorCode, ParseExpected, ParseExpectedHook
// are defined in sparkles.versions.engine so that the engine's StringSlot
// validator alias can reference ParseExpected without a circular import.
// Re-export them here so callers that import only sparkles.versions.parser
// still see them.
public import sparkles.versions.engine :
    ParseError, ParseErrorCode, ParseExpected, ParseMode;

@safe:

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

    // Default: every $(LREF InternalFlag) bit (e.g. SemVer's stableFlag)
    // starts set. It is cleared below when an ordering-relevant slot is
    // consumed.
    static if (Layout.descriptor.internalFlag.name.length > 0)
        __traits(getMember, result.core, Layout.descriptor.internalFlag.name)
            = true;

    // Walk the layout's declared StringSlots in declared order. Each slot
    // is recognised by its `prefix` character; its content is everything
    // up to the prefix character of a later-declared slot (or end of
    // input). The engine has no built-in knowledge of which slot any of
    // them represents — it only knows the slot's prefix and validator.
    enum slots = layoutStringSlots!Layout();
    static foreach (slotIdx, slot; slots)
    {{
        // Precompute the prefix characters of slots declared AFTER this
        // one. The current slot's own prefix is allowed inside its
        // content (e.g. SemVer accepts `alpha-beta` inside a prerelease).
        enum char[] laterPrefixes = () {
            char[] r;
            foreach (j; slotIdx + 1 .. slots.length)
                r ~= slots[j].prefix;
            return r;
        }();

        if (i < s.length && s[i] == slot.prefix)
        {
            const start = ++i;
            while (i < s.length)
            {
                bool stop = false;
                static foreach (p; laterPrefixes)
                    if (s[i] == p) stop = true;
                if (stop) break;
                i++;
            }
            const segment = s[start .. i];

            // Layout-supplied validation (e.g. SemVer identifier rules)
            // OR engine default: non-empty.
            static if (slot.validate !is null)
            {
                auto check = slot.validate(segment, start);
                if (check.hasError)
                    return parseErr!Layout(check.error);
            }
            else if (segment.length == 0)
                return parseErr!Layout(
                    ParseErrorCode.emptyIdentifier, start);

            __traits(getMember, result, slot.name) = segment;

            static if (slot.includeInOrdering
                && Layout.descriptor.internalFlag.name.length > 0)
                __traits(getMember, result.core,
                    Layout.descriptor.internalFlag.name) = false;
        }
    }}

    if (mode == ParseMode.loose)
        skipHorizontalSpace(s, i);

    if (i != s.length)
        return parseErr!Layout(
            ParseErrorCode.unexpectedCharacter, i);

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

// SemVer identifier validation and prerelease comparison live in
// `sparkles.versions.semver_rules` — they are layout-supplied, not
// engine-baked, so the parser sees only opaque SlotValidator hooks.

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
