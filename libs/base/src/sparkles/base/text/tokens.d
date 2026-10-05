/** Borrowed logical token iteration with explicit malformed-input policy. */
module sparkles.base.text.tokens;

import sparkles.base.text.utf : UtfToken, UtfResult, UtfDecodeResult, UtfMode,
    UtfStatus, decodeToken;

/// Forward range; strict failure stops iteration and remains observable in result.
struct UtfTokenRange(Unit)
if (is(Unit == char) || is(Unit == wchar) || is(Unit == dchar))
{
    private const(Unit)[] source;
    private size_t position;
    private size_t origin;
    private UtfMode mode;
    private UtfDecodeResult decoded;

    bool empty() scope const @safe pure nothrow @nogc
        => decoded.result.status != UtfStatus.ok;
    UtfToken front() scope const @safe pure nothrow @nogc
    in (!empty())
    {
        return decoded.token;
    }
    UtfResult result() scope const @safe pure nothrow @nogc => decoded.result;
    size_t consumed() scope const @safe pure nothrow @nogc => position;

    void popFront() scope @safe pure nothrow @nogc
    in (!empty())
    {
        position += decoded.result.consumed;
        refresh();
    }

    private void refresh() scope @safe pure nothrow @nogc
    {
        if (position > size_t.max - origin)
        {
            decoded = UtfDecodeResult.init;
            decoded.result.status = UtfStatus.overflow;
            return;
        }
        decoded = decodeToken(source[position .. $], mode, true, origin + position);
    }
}

/// Opaque mode is UTF-8 only. Token spans use the supplied absolute origin.
UtfTokenRange!Unit byUtfToken(Unit)(return scope const(Unit)[] source,
    UtfMode mode = UtfMode.strict, size_t origin = 0)
if (is(Unit == char) || is(Unit == wchar) || is(Unit == dchar))
{
    auto result = UtfTokenRange!Unit(source: source, origin: origin, mode: mode);
    result.refresh();
    return result;
}

@("text.tokens.strictFailureAndOpaqueIdentity")
@safe pure nothrow @nogc
unittest
{
    auto strict = byUtfToken("A\xE1\x80B", UtfMode.strict, 10);
    assert(strict.front.scalar == 'A');
    strict.popFront();
    assert(strict.empty && strict.result.status == UtfStatus.invalid);
    assert(strict.result.offset == 11 && strict.consumed == 1);
    auto opaque = byUtfToken("A\xE1\x80B", UtfMode.opaque, 10);
    opaque.popFront();
    assert(opaque.front.start == 11 && opaque.front.end == 12);
    assert(opaque.front.byteValue == 0xE1);
    opaque.popFront();
    assert(opaque.front.byteValue == 0x80);
    opaque.popFront();
    assert(opaque.front.scalar == 'B');
    opaque.popFront();
    assert(opaque.empty && opaque.result.status == UtfStatus.end);
    auto replacement = byUtfToken("\xE1\x80B", UtfMode.replacement);
    assert(replacement.front.start == 0 && replacement.front.end == 2);
    assert(replacement.front.scalar == 0xFFFD);
}
