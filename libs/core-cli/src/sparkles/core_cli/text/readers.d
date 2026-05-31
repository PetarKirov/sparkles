/**
Slice-advance text reading primitives.

Each reader takes the input as a `ref scope const(char)[]` cursor and, on
success, advances it past the consumed characters (the cursor _is_ the
position). Readers are mechanism, not policy: they report mechanical
outcomes via $(REF ParseExpected, sparkles,core_cli,text,errors) and leave
all higher-level rules (leading-zero handling, field widths, which error
to surface) to the caller.

The integer reader is the inverse of
$(REF writeInteger, sparkles,core_cli,text,writers).
*/
module sparkles.core_cli.text.readers;

import std.traits : isUnsigned;

import sparkles.core_cli.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

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

@("text.readers.readInteger.advancesOnSuccess")
unittest
{
    const(char)[] s = "123abc";
    auto r = readInteger!uint(s);
    assert(r.hasValue);
    assert(r.value == 123);
    assert(s == "abc");
}

@("text.readers.readInteger.rejectsNonDigitWithoutAdvancing")
unittest
{
    const(char)[] s = "abc";
    auto r = readInteger!uint(s);
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.unexpectedCharacter);
    assert(s == "abc");
}

@("text.readers.readInteger.overflow")
unittest
{
    const(char)[] s = "256";
    auto r = readInteger!ubyte(s);
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.numericOverflow);
    assert(s == "256"); // not advanced on failure

    const(char)[] ok = "255";
    assert(readInteger!ubyte(ok).value == 255);
}

@("text.readers.skipSpaces")
unittest
{
    const(char)[] s = "  \tx";
    assert(skipSpaces(s) == 3);
    assert(s == "x");
}

@("text.readers.tryConsume")
unittest
{
    const(char)[] s = "=1";
    assert(tryConsume(s, '='));
    assert(s == "1");
    assert(!tryConsume(s, '='));
    assert(s == "1");
}

@("text.readers.tryConsumeAny")
unittest
{
    const(char)[] s = "v2";
    assert(tryConsumeAny(s, "=vV"));
    assert(s == "2");
    assert(!tryConsumeAny(s, "=vV"));
}

@("text.readers.readUntil")
unittest
{
    const(char)[] s = "alpha.1";
    assert(readUntil(s, ".") == "alpha");
    assert(s == ".1");

    const(char)[] none = "abc";
    assert(readUntil(none, ".") == "abc");
    assert(none.length == 0);
}
