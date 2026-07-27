/++
`@nogc nothrow` UTF-8 scalar primitives: encode a code point to bytes, and decode
the first code point of a slice.

`std.utf.encode`/`decode` can throw (on surrogates / malformed input) and so are
unavailable in `@safe pure nothrow @nogc` code. These cover the common path where
the scalar / slice is already known-valid — terminal cell content, a grapheme
cluster's lead scalar — and are deliberately non-validating (a caller with
untrusted bytes should validate first).
+/
module sparkles.base.text.utf;

@safe pure nothrow @nogc:

/// Encode a valid code point to UTF-8 into `buf`, returning the byte count (1–4).
/// No surrogate check (that is `std.utf.encode`'s throwing path); `cp` is assumed
/// to be a valid Unicode scalar.
ubyte encodeUtf8(dchar cp, ref char[4] buf)
{
    if (cp < 0x80)
    {
        buf[0] = cast(char) cp;
        return 1;
    }
    if (cp < 0x800)
    {
        buf[0] = cast(char)(0xC0 | (cp >> 6));
        buf[1] = cast(char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000)
    {
        buf[0] = cast(char)(0xE0 | (cp >> 12));
        buf[1] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = cast(char)(0x80 | (cp & 0x3F));
        return 3;
    }
    buf[0] = cast(char)(0xF0 | (cp >> 18));
    buf[1] = cast(char)(0x80 | ((cp >> 12) & 0x3F));
    buf[2] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
    buf[3] = cast(char)(0x80 | (cp & 0x3F));
    return 4;
}

/// Decode the first code point of a (valid) UTF-8 slice, without advancing past
/// it. An empty slice yields a space (`0x20`); a lead byte whose continuation
/// bytes are truncated yields the replacement character (`U+FFFD`).
dchar decodeFirstUtf8(scope const(char)[] s)
{
    if (s.length == 0)
        return 0x20;
    const c0 = cast(ubyte) s[0];
    if (c0 < 0x80)
        return c0;
    if (c0 < 0xE0 && s.length >= 2)
        return ((c0 & 0x1F) << 6) | (cast(ubyte) s[1] & 0x3F);
    if (c0 < 0xF0 && s.length >= 3)
        return ((c0 & 0x0F) << 12) | ((cast(ubyte) s[1] & 0x3F) << 6) | (cast(ubyte) s[2] & 0x3F);
    if (s.length >= 4)
        return ((c0 & 0x07) << 18) | ((cast(ubyte) s[1] & 0x3F) << 12)
            | ((cast(ubyte) s[2] & 0x3F) << 6) | (cast(ubyte) s[3] & 0x3F);
    return 0xFFFD;
}

@("text.utf.encodeDecodeRoundTrip")
@safe pure nothrow @nogc
unittest
{
    static void check(dchar cp, ubyte want)
    {
        char[4] b;
        assert(encodeUtf8(cp, b) == want);
        assert(decodeFirstUtf8(b[0 .. want]) == cp);
    }

    check('A', 1);            // ASCII
    check('é', 2);       // é
    check('€', 3);       // €
    check('\U0001F600', 4);   // 😀

    // Edge cases: empty → space; a truncated 4-byte lead → replacement.
    assert(decodeFirstUtf8("") == 0x20);
    char[4] b;
    encodeUtf8('\U0001F600', b);
    assert(decodeFirstUtf8(b[0 .. 1]) == 0xFFFD);
}
