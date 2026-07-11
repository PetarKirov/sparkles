/**
Slice-advance text reading primitives.

Each reader takes the input as a `ref scope const(char)[]` cursor and, on
success, advances it past the consumed characters (the cursor _is_ the
position). Readers are mechanism, not policy: they report mechanical
outcomes via $(REF ParseExpected, sparkles,core_cli,text,errors) and leave
all higher-level rules (leading-zero handling, field widths, which error
to surface) to the caller.

The integer reader is the inverse of
$(REF writeInteger, sparkles,core_cli,text,writers); $(LREF readEnumString) is
the inverse of `writeEnumMemberName` (`sparkles.base.text.writers`).
*/
module sparkles.base.text.readers;

import std.traits : isUnsigned;

import sparkles.base.text.case_style : CaseStyle, convertCase;
import sparkles.base.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

// Unconditional import (phobos-style, cf. std.internal.attributes): unittest
// UDAs are resolved even in builds where the unittest bodies are not compiled.
import sparkles.test_runner.attributes : betterC;

@safe pure nothrow @nogc:

/**
Reads leading decimal digits from the front of `s` into an unsigned
integer `T`, advancing `s` past them on success.

Fails — leaving `s` unchanged — when the cursor is empty
(`emptyInput`), does not start with a digit (`unexpectedCharacter`), or
the value would overflow `T` (`numericOverflow`). Reported offsets are
relative to `s` as received (0 at its first character).
*/
ParseExpected!T readInteger(T)(ref scope const(char)[] s)
if (isUnsigned!T)
{
    import std.ascii : isDigit;

    if (s.length == 0)
        return parseErr!T(ParseErrorCode.emptyInput, 0);
    if (!s[0].isDigit)
        return parseErr!T(ParseErrorCode.unexpectedCharacter, 0);

    T value = 0;
    size_t i = 0;
    while (i < s.length && s[i].isDigit)
    {
        const digit = cast(T)(s[i] - '0');
        if (value > cast(T)((T.max - digit) / 10))
            return parseErr!T(ParseErrorCode.numericOverflow, i);
        value = cast(T)(value * 10 + digit);
        i++;
    }

    s = s[i .. $]; // advance only on success
    return parseOk(value);
}

/// Advances `s` past leading characters satisfying `pred`, returning the
/// number skipped.
size_t skipWhile(alias pred)(ref scope const(char)[] s)
{
    size_t i = 0;
    while (i < s.length && pred(s[i]))
        i++;
    s = s[i .. $];
    return i;
}

/// Advances `s` past leading ASCII spaces and tabs, returning the number
/// skipped.
size_t skipSpaces(ref scope const(char)[] s)
    => skipWhile!(c => c == ' ' || c == '\t')(s);

/// If `s` starts with `c`, advances past it and returns `true`; otherwise
/// leaves `s` unchanged and returns `false`.
bool tryConsume(ref scope const(char)[] s, char c)
{
    if (s.length == 0 || s[0] != c)
        return false;
    s = s[1 .. $];
    return true;
}

/// If `s` starts with any character in `set`, advances past it and returns
/// `true`; otherwise leaves `s` unchanged and returns `false`.
bool tryConsumeAny(ref scope const(char)[] s, scope const(char)[] set)
{
    if (s.length == 0)
        return false;
    foreach (c; set)
        if (s[0] == c)
        {
            s = s[1 .. $];
            return true;
        }
    return false;
}

/// Reads characters from the front of `s` up to (but not including) the
/// first character in `delims`, advancing `s` to that delimiter (or to the
/// end if none is found). Returns the consumed slice.
const(char)[] readUntil(return ref scope const(char)[] s, scope const(char)[] delims)
{
    size_t i = 0;
    cursor: while (i < s.length)
    {
        foreach (d; delims)
            if (s[i] == d)
                break cursor;
        i++;
    }
    const head = s[0 .. i];
    s = s[i .. $];
    return head;
}

/// `true` iff `c` is an ASCII hex digit (`0-9`, `a-f`, `A-F`).
bool isHexDigit(char c)
    => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');

/// The value `0 … 15` of a hex digit `c` (case-insensitive). `c` must satisfy
/// $(LREF isHexDigit).
ubyte hexNibble(char c)
in (isHexDigit(c))
    => c <= '9' ? cast(ubyte)(c - '0') : cast(ubyte)((c | 0x20) - 'a' + 10);

///
@("text.readers.hexDigit")
@betterC
unittest
{
    assert(isHexDigit('0') && isHexDigit('9'));
    assert(isHexDigit('a') && isHexDigit('f'));
    assert(isHexDigit('A') && isHexDigit('F'));
    assert(!isHexDigit('g') && !isHexDigit('/') && !isHexDigit(' '));

    assert(hexNibble('0') == 0);
    assert(hexNibble('9') == 9);
    assert(hexNibble('a') == 10 && hexNibble('A') == 10);
    assert(hexNibble('f') == 15 && hexNibble('F') == 15);
}

/// The enum's member names joined as `"a, b, c"`, computed at compile time —
/// the body of the `"expected one of: …"` detail $(LREF readEnumString) attaches
/// to an `unknownValue` error.
private template enumExpectedList(E, CaseStyle style)
if (is(E == enum))
{
    enum string enumExpectedList = {
        string s;
        static foreach (i, memberName; __traits(allMembers, E))
        {
            static if (i)
                s ~= ", ";
            s ~= convertCase!style(memberName);
        }
        return s;
    }();
}

/**
Reads an enum member name from the front of `s`, advancing past it on success.

The inverse of `writeEnumMemberName` (`sparkles.base.text.writers`): each member
is matched by its identifier recased with `convertCase!style`
(`sparkles.base.text.case_style`); `style` defaults to `CaseStyle.original`.
Matching is greedy — the longest member name that is a prefix of `s` wins, so
names that prefix one another (e.g. `fast` / `faster`) resolve to the longer.

Fails — leaving `s` unchanged — on empty input (`emptyInput`) or when no member
name is a prefix (`unknownValue`, with a `"expected one of: …"` context). For
an exact whole-token match (e.g. a JSON key), check that `s` is empty
afterwards.
*/
ParseExpected!E readEnumString(E, CaseStyle style = CaseStyle.original)(ref scope const(char)[] s)
if (is(E == enum))
{
    if (s.length == 0)
        return parseErr!E(ParseErrorCode.emptyInput, 0);

    size_t bestLen = 0;
    E best;
    bool matched = false;

    static foreach (memberName; __traits(allMembers, E))
    {{
        enum name = convertCase!style(memberName);
        if (name.length > bestLen && s.length >= name.length && s[0 .. name.length] == name)
        {
            bestLen = name.length;
            best = __traits(getMember, E, memberName);
            matched = true;
        }
    }}

    if (!matched)
    {
        enum string msg = "expected one of: " ~ enumExpectedList!(E, style);
        return parseErr!E(ParseErrorCode.unknownValue, 0, msg);
    }

    s = s[bestLen .. $]; // advance only on success
    return parseOk(best);
}

@("text.readers.readInteger.advancesOnSuccess")
@betterC
unittest
{
    const(char)[] s = "123abc";
    auto r = readInteger!uint(s);
    assert(r.hasValue);
    assert(r.value == 123);
    assert(s == "abc");
}

@("text.readers.readInteger.rejectsNonDigitWithoutAdvancing")
@betterC
unittest
{
    // Local import: extracted @betterC tests only see the module's public API.
    import sparkles.base.text.errors : ParseErrorCode;

    const(char)[] s = "abc";
    auto r = readInteger!uint(s);
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.unexpectedCharacter);
    assert(s == "abc");
}

@("text.readers.readInteger.overflow")
@betterC
unittest
{
    import sparkles.base.text.errors : ParseErrorCode;

    const(char)[] s = "256";
    auto r = readInteger!ubyte(s);
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.numericOverflow);
    assert(s == "256"); // not advanced on failure

    const(char)[] ok = "255";
    assert(readInteger!ubyte(ok).value == 255);
}

@("text.readers.skipSpaces")
@betterC
unittest
{
    const(char)[] s = "  \tx";
    assert(skipSpaces(s) == 3);
    assert(s == "x");
}

@("text.readers.tryConsume")
@betterC
unittest
{
    const(char)[] s = "=1";
    assert(tryConsume(s, '='));
    assert(s == "1");
    assert(!tryConsume(s, '='));
    assert(s == "1");
}

@("text.readers.tryConsumeAny")
@betterC
unittest
{
    const(char)[] s = "v2";
    assert(tryConsumeAny(s, "=vV"));
    assert(s == "2");
    assert(!tryConsumeAny(s, "=vV"));
}

@("text.readers.readUntil")
@betterC
unittest
{
    const(char)[] s = "alpha.1";
    assert(readUntil(s, ".") == "alpha");
    assert(s == ".1");

    const(char)[] none = "abc";
    assert(readUntil(none, ".") == "abc");
    assert(none.length == 0);
}

@("text.readers.readEnumString.advancesOnSuccess")
@safe pure nothrow @nogc
unittest
{
    enum Mode { fastMode, slow }

    // Under kebab-case, `fastMode` is matched as `fast-mode`.
    const(char)[] s = "fast-mode!";
    auto r = readEnumString!(Mode, CaseStyle.kebabCase)(s);
    assert(r.hasValue);
    assert(r.value == Mode.fastMode);
    assert(s == "!"); // advanced past the member name only

    const(char)[] t = "slow";
    assert(readEnumString!(Mode, CaseStyle.kebabCase)(t).value == Mode.slow);
    assert(t.length == 0);
}

@("text.readers.readEnumString.longestMatchWins")
@safe pure nothrow @nogc
unittest
{
    enum Mode { fast, faster }

    // "faster" must beat the "fast" prefix and consume the whole token.
    const(char)[] s = "faster";
    auto r = readEnumString!Mode(s);
    assert(r.hasValue);
    assert(r.value == Mode.faster);
    assert(s.length == 0);

    // A "fast" member leaves the trailing "est" for the caller to reject.
    enum Only { fast }
    const(char)[] t = "fastest";
    auto rt = readEnumString!Only(t);
    assert(rt.hasValue);
    assert(rt.value == Only.fast);
    assert(t == "est");
}

@("text.readers.readEnumString.emptyInput")
@safe pure nothrow @nogc
unittest
{
    enum Mode { fast }

    const(char)[] s = "";
    auto r = readEnumString!Mode(s);
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.emptyInput);
    assert(r.error.offset == 0);
}

@("text.readers.readEnumString.unknownValueWithContext")
@safe pure nothrow @nogc
unittest
{
    enum Mode { fast, slow }

    const(char)[] s = "zoom";
    auto r = readEnumString!Mode(s);
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.unknownValue);
    assert(r.error.offset == 0);
    assert(r.error.context == "expected one of: fast, slow");
    assert(s == "zoom"); // not advanced on failure
}
