/**
UTF-8 well-formedness validation (RFC 3629 / Unicode "Table 3-7" rules).

The core primitive is $(LREF indexOfInvalidUtf8) — index-of-first-error
over a byte slice, `length` when well-formed. Its signature is the
replaceable seam: a SIMD implementation (lookup-table shuffle validation)
swaps the body without touching any caller. $(LREF validateUtf8) wraps it
in the `ParseExpected` error vocabulary.

Rejected exactly as the Unicode standard requires: overlong encodings,
UTF-16 surrogates (U+D800–U+DFFF), code points above U+10FFFF, bare
continuation bytes, truncated sequences, and the never-valid bytes
`0xC0`/`0xC1`/`0xF5`–`0xFF`.
*/
module sparkles.base.text.utf8;

import sparkles.base.text.errors : ParseErrorCode, ParseExpected, parseErr,
    parseOk;

/**
Returns the index of the first byte of the first ill-formed UTF-8 sequence
in `s`, or `s.length` when the whole slice is well-formed.

Scalar implementation: a word-at-a-time ASCII skip, then per-sequence
validation — the common lead classes check both continuations with one
16-bit masked compare; only the window-constrained leads (`E0 ED F0 F4`)
branch to exact range checks. (A DFA was measured slower here: its
serial load-to-load dependency loses to well-predicted branches.)
*/
size_t indexOfInvalidUtf8(scope const(char)[] s) @safe pure nothrow @nogc
{
    const n = s.length;
    size_t i = 0;

    while (i < n)
    {
        // ASCII fast lane: skip 8 bytes per iteration while no high bit.
        if (!__ctfe)
        {
            while (i + 8 <= n)
            {
                const word = (() @trusted {
                    import core.stdc.string : memcpy;

                    ulong w;
                    memcpy(&w, s.ptr + i, 8);
                    return w;
                })();
                if (word & 0x8080_8080_8080_8080)
                    break;
                i += 8;
            }
        }
        if (i >= n)
            break;

        const c = s[i];
        if (c < 0x80)
        {
            i++;
            continue;
        }
        const len = utf8SequenceLength(s, i);
        if (len == 0)
            return i;
        i += len;
    }
    return n;
}

/**
Validates the single UTF-8 sequence whose lead byte sits at `s[i]`
(`s[i] ≥ 0x80`) and returns its byte length (2–4), or `0` when the
sequence is ill-formed or truncated. The shortest-form, surrogate, and
U+10FFFF constraints are folded into the second-byte window
(Unicode Table 3-7). Building block for scanners that validate strings
inline (e.g. the wired JSON reader's string lanes).
*/
size_t utf8SequenceLength(scope const(char)[] s, size_t i) @safe pure nothrow @nogc
in (i < s.length && s[i] >= 0x80)
{
    pragma(inline, true);
    const n = s.length;
    const c = s[i];

    if (c >= 0xC2 && c <= 0xDF) // 2-byte
    {
        if (n - i <= 1 || (s[i + 1] & 0xC0) != 0x80)
            return 0;
        return 2;
    }
    if (c >= 0xE0 && c <= 0xEF) // 3-byte
    {
        if (n - i <= 2)
            return 0;
        // Both continuations in one masked compare; the constrained
        // leads (E0: no overlongs, ED: no surrogates) take exact checks.
        const uint w = s[i + 1] | (uint(s[i + 2]) << 8);
        if ((w & 0xC0C0) != 0x8080)
            return 0;
        if (c == 0xE0 && s[i + 1] < 0xA0)
            return 0;
        if (c == 0xED && s[i + 1] > 0x9F)
            return 0;
        return 3;
    }
    if (c >= 0xF0 && c <= 0xF4) // 4-byte
    {
        if (n - i <= 3)
            return 0;
        const uint w = s[i + 1] | (uint(s[i + 2]) << 8) | (uint(s[i + 3]) << 16);
        if ((w & 0xC0C0C0) != 0x808080)
            return 0;
        if (c == 0xF0 && s[i + 1] < 0x90) // overlongs
            return 0;
        if (c == 0xF4 && s[i + 1] > 0x8F) // above U+10FFFF
            return 0;
        return 4;
    }
    return 0; // 0x80..0xC1 (bare continuation / overlong lead), 0xF5..0xFF
}

/**
Validates that `s` is well-formed UTF-8; an error carries
`ParseErrorCode.invalidUtf8` with the offset of the offending sequence's
first byte.
*/
ParseExpected!void validateUtf8(scope const(char)[] s) @safe pure nothrow @nogc
{
    const i = indexOfInvalidUtf8(s);
    if (i == s.length)
        return parseOk();
    return parseErr!void(ParseErrorCode.invalidUtf8, i);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

@("utf8.wellFormed.acceptedCorpus")
@safe pure nothrow @nogc
unittest
{
    static immutable string[] valid = [
        "", "hello", "hello world, plain ASCII only . . . . . . . . . . .",
        "καλημέρα", "здравей", "こんにちは", "你好", "안녕하세요",
        "🌍🎉👨\u200D👩\u200D👧\u200D👦", "ẹ\u0301", // ZWJ + combining marks
        "\u007F", "\u0080", "\u07FF", // 1↔2-byte boundaries
        "\u0800", "\uD7FF", "\uE000", "\uFFFD", "\uFFFF", // 3-byte edges
        "\U00010000", "\U0010FFFF", // 4-byte edges
    ];
    foreach (s; valid)
    {
        assert(indexOfInvalidUtf8(s) == s.length, s);
        assert(validateUtf8(s).hasError == false);
    }
}

@("utf8.illFormed.rejectedWithOffset")
@safe pure nothrow @nogc
unittest
{
    static struct Case
    {
        string bytes;
        size_t errorAt;
    }

    static immutable Case[] invalid = [
        Case("\xC0\x80", 0), // overlong NUL (modified UTF-8 — rejected)
        Case("\xC1\xBF", 0), // overlong
        Case("\xE0\x80\x80", 0), // overlong 3-byte
        Case("\xE0\x9F\xBF", 0), // overlong 3-byte (below U+0800)
        Case("\xF0\x80\x80\x80", 0), // overlong 4-byte
        Case("\xF0\x8F\xBF\xBF", 0), // overlong 4-byte (below U+10000)
        Case("\xED\xA0\x80", 0), // U+D800 high surrogate
        Case("\xED\xBF\xBF", 0), // U+DFFF low surrogate
        Case("\xF4\x90\x80\x80", 0), // above U+10FFFF
        Case("\xF5\x80\x80\x80", 0), // lead beyond F4
        Case("\xFE", 0), Case("\xFF", 0), // never valid
        Case("\x80", 0), // bare continuation
        Case("abc\xBFdef", 3), // bare continuation mid-string
        Case("\xC2", 0), // truncated 2-byte
        Case("\xE1\x80", 0), // truncated 3-byte
        Case("\xF1\x80\x80", 0), // truncated 4-byte
        Case("ok\xE2\x28\xA1no", 2), // wrong continuation
        Case("1234567\xC3\x28", 7), // invalid just after the ASCII lane
        Case("12345678\xED\xA0\x80", 8), // surrogate after full word skip
    ];
    foreach (c; invalid)
    {
        assert(indexOfInvalidUtf8(c.bytes) == c.errorAt);
        auto r = validateUtf8(c.bytes);
        assert(r.hasError);
        assert(r.error.code == ParseErrorCode.invalidUtf8);
        assert(r.error.offset == c.errorAt);
    }
}

@("utf8.ctfeMatchesRuntime")
@safe pure nothrow @nogc
unittest
{
    static assert(indexOfInvalidUtf8("héllo🌍") == "héllo🌍".length);
    static assert(indexOfInvalidUtf8("\xED\xA0\x80") == 0);
    static assert(indexOfInvalidUtf8("abc\xC2") == 3);
    enum ctfe = indexOfInvalidUtf8("x\xF4\x8F\xBF\xBFy");
    assert(ctfe == indexOfInvalidUtf8("x\xF4\x8F\xBF\xBFy"));
}

@("utf8.differentialVsPhobos")
@system unittest
{
    import std.utf : validate;

    // Random byte soup differential: agree with std.utf.validate on
    // validity (offsets are ours alone — Phobos reports code-unit indices
    // differently).
    ulong state = 0xBEEF_FACE_D00D_0001;
    ulong next()
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return state;
    }

    char[24] buf;
    foreach (iter; 0 .. 50_000)
    {
        const len = next() % buf.length;
        foreach (k; 0 .. len)
            // Bias toward the interesting non-ASCII space.
            buf[k] = cast(char)(next() % (iter % 3 ? 0x100 : 0xC0));
        const(char)[] s = buf[0 .. len];

        bool phobosOk = true;
        try
            validate(s);
        catch (Exception)
            phobosOk = false;

        assert((indexOfInvalidUtf8(s) == s.length) == phobosOk);
    }
}
