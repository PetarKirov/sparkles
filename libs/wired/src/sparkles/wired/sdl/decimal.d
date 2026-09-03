/**
The SDL numeric-literal adapter over `sparkles.base.text.float_conv`.

SDL's float grammar is not `readDecimalFloat`'s: an optional `-`, decimal
digits, and at most one point that must be followed by a digit — `.5` is
legal, `1.` and `+1` are not — and there is no exponent (the canonical
writer expands one through
$(REF writeFixedDecimal, sparkles,wired,sdl,writer) before the text gets
here). $(LREF readSdlDecimalFloat) enforces that grammar, exactly as the
lexer's token shape does, and normalizes the spelling to the reader's
`[-]digits[.digits]`, then lets
$(REF readDecimalFloat, sparkles,base,text,float_conv) do the conversion —
correctly rounded at whatever width `T` has: binary64, x87, or binary128.

Every float kind the lexer decodes (`F`, `D`, `BD`) comes through here, and
the canonical writer renders with the matching
$(REF shortestDigits, sparkles,base,text,float_conv), so reader and writer
share one correctly-rounded kernel per type. That is what SPEC §10 LAW 3
needs, and why no private accumulator lives here any more. The allowances
are SDL's, which is why this adapter lives in `wired` rather than in
`float_conv`: JSON forbids them, and D and C allow different subsets.
*/
module sparkles.wired.sdl.decimal;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.text.errors : ParseErrorCode, ParseExpected, parseErr, parseOk;
import sparkles.base.text.float_conv : readDecimalFloat;

/** Reads an SDL float spelling — the token with its kind suffix already
removed — as `T`, correctly rounded.

Returns `ParseErrorCode.unexpectedCharacter` at the offending byte for a
spelling outside SDL's grammar and `ParseErrorCode.emptyInput` for one with
no digit at all. Callers have already validated the token's shape, so these
are defensive rather than the reported error.
*/
package ParseExpected!T readSdlDecimalFloat(T)(scope const(char)[] text)
    @safe pure nothrow @nogc
if (__traits(isFloating, T))
{
    size_t at;
    bool negative;
    if (at < text.length && text[at] == '-')
    {
        negative = true;
        at++;
    }
    auto rest = text[at .. $];

    bool sawDot;
    bool sawDigit;
    foreach (i, c; rest)
    {
        if (c == '.')
        {
            if (sawDot)
                return parseErr!T(ParseErrorCode.unexpectedCharacter, at + i);
            sawDot = true;
            continue;
        }
        if (cast(uint)(c - '0') > 9)
            return parseErr!T(ParseErrorCode.unexpectedCharacter, at + i);
        sawDigit = true;
    }
    if (!sawDigit)
        return parseErr!T(ParseErrorCode.emptyInput, at);
    if (rest[$ - 1] == '.')
        return parseErr!T(ParseErrorCode.unexpectedCharacter, text.length - 1);

    // The reader wants a digit before the point too: SDL's `.5` is 0.5.
    UniqueBuffer!(char, 64) owned;
    scope const(char)[] input;
    if (rest[0] == '.')
    {
        owned ~= '0';
        owned ~= rest;
        input = owned[];
    }
    else
        input = rest;

    auto parsed = readDecimalFloat!T(input);
    if (parsed.hasError || input.length)
        return parseErr!T(ParseErrorCode.unexpectedCharacter, at);
    return parseOk(negative ? -parsed.value : parsed.value);
}

/// $(LREF readSdlDecimalFloat) at `real`, with `real.nan` for a spelling
/// outside the grammar — the shape the lexer's `decimal` path and the
/// writer's tests use.
package real parseDecimalReal(scope const(char)[] text) @safe pure nothrow @nogc
{
    auto parsed = readSdlDecimalFloat!real(text);
    return parsed.hasValue ? parsed.value : real.nan;
}

@("sdl.decimal.exactAndRounded")
@safe pure nothrow @nogc
unittest
{
    assert(parseDecimalReal("0") == 0.0L);
    assert(parseDecimalReal("-0") == 0.0L);
    assert(parseDecimalReal("1") == 1.0L);
    assert(parseDecimalReal("-1") == -1.0L);
    assert(parseDecimalReal("123.45") == 123.45L);
    assert(parseDecimalReal("0.001") == 0.001L);
    assert(parseDecimalReal(".5") == 0.5L);
    assert(parseDecimalReal("-.25") == -0.25L);
    assert(parseDecimalReal("0.125") == 0.125L);

    // Dyadic values are exact in both directions.
    assert(parseDecimalReal("0.0000152587890625") == 0x1p-16L);

    // Nineteen-digit integers land on the chunk boundary exactly.
    assert(parseDecimalReal("9999999999999999999") == 9999999999999999999.0L);

    // Malformed spellings are rejected rather than silently truncated.
    import std.math : isNaN;

    assert(isNaN(parseDecimalReal("")));
    assert(isNaN(parseDecimalReal("-")));
    assert(isNaN(parseDecimalReal("1.2.3")));
    assert(isNaN(parseDecimalReal("1e5")));
    assert(isNaN(parseDecimalReal("12x")));
}

// The adapter is a grammar gate over a correctly-rounded reader, so whatever
// tier the reader takes must land where the exact one does — including the
// 22-digit spelling Phobos' x87 `to!real` gets wrong, which the old private
// kernel existed to resolve.
@("sdl.decimal.agreesWithTheExactTier")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.text.float_conv : slowFloat;

    assert(parseDecimalReal("-1.527064050293794113039")
        is -slowFloat!real("1", "527064050293794113039", 0));
    assert(parseDecimalReal("0.1") is slowFloat!real(null, "1", 0));
    assert(parseDecimalReal("123.45") is slowFloat!real("123", "45", 0));
    assert(parseDecimalReal("999999999999999999999999999999")
        is slowFloat!real("999999999999999999999999999999", null, 0));

    // The typed adapter serves the other kinds the same way.
    assert(readSdlDecimalFloat!float("0.1").value is 0.1f);
    assert(readSdlDecimalFloat!double("-.5").value is -0.5);
    assert(readSdlDecimalFloat!double("1e5").hasError);
    assert(readSdlDecimalFloat!double(".").hasError);
    assert(readSdlDecimalFloat!double("").hasError);
    // Exactly the lexer's shape: no trailing point, no explicit plus.
    assert(readSdlDecimalFloat!double("1.").hasError);
    assert(readSdlDecimalFloat!double("1.").error.offset == 1);
    assert(readSdlDecimalFloat!double("+1").hasError);
    assert(readSdlDecimalFloat!double("-1.").hasError);
}
