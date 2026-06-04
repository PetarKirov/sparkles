/**
 * Hexadecimal encoding and decoding (§5).
 *
 * Encoding emits **lowercase** ASCII hex (`0-9`, `a-f`), two characters per
 * input byte, most-significant nibble first — the form used by age test
 * vectors and key fingerprints. Decoding is **case-insensitive**: it accepts
 * both lowercase and uppercase digits.
 *
 * Both directions are fully `@safe pure nothrow @nogc`. The encoder is an
 * output-range writer; the decoder writes into a caller-provided `ubyte[]` and
 * reports failures via $(REF ParseExpected, sparkles,core_cli,text,errors):
 *
 * $(UL
 *   $(LI an odd-length input — there is a dangling nibble — yields
 *     `unexpectedEnd` at the trailing character;)
 *   $(LI a character outside `[0-9A-Fa-f]` yields `unexpectedCharacter` at its
 *     offset.)
 * )
 *
 * An empty input encodes to the empty string and decodes to the empty slice.
 */
module sparkles.crypto.encoding.hex;

import sparkles.core_cli.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

@safe pure nothrow @nogc:

/// Number of hex characters produced for `n` input bytes (`n * 2`).
size_t hexEncodedLength(size_t n)
    => n * 2;

///
@("crypto.encoding.hex.hexEncodedLength")
@safe pure nothrow @nogc
unittest
{
    assert(hexEncodedLength(0) == 0);
    assert(hexEncodedLength(1) == 2);
    assert(hexEncodedLength(32) == 64);
}

/// Maximum number of bytes a `decodeHex` of `encodedChars` characters can
/// yield (`encodedChars / 2`), for sizing the caller's output buffer. An odd
/// `encodedChars` is rejected by the decoder, but its byte count still fits in
/// this bound.
size_t hexMaxDecodedLength(size_t encodedChars)
    => encodedChars / 2;

///
@("crypto.encoding.hex.hexMaxDecodedLength")
@safe pure nothrow @nogc
unittest
{
    assert(hexMaxDecodedLength(0) == 0);
    assert(hexMaxDecodedLength(2) == 1);
    assert(hexMaxDecodedLength(3) == 1); // odd input still bounds at 1 byte
    assert(hexMaxDecodedLength(64) == 32);
}

/// Lowercase hex digit (`0-9`, `a-f`) for a nibble value `0 … 15`.
private char hexDigit(uint nibble) @safe pure nothrow @nogc
in (nibble < 16, "nibble out of range")
    => cast(char)(nibble < 10 ? '0' + nibble : 'a' + (nibble - 10));

/**
 * Encodes `data` as lowercase hexadecimal into the output range `w`, writing
 * two characters (high nibble first) per byte.
 *
 * Params:
 *   data = bytes to encode
 *   w    = output range of `char` (anything supporting `put`)
 */
void encodeHex(Writer)(scope const(ubyte)[] data, ref Writer w)
{
    import std.range.primitives : put;

    foreach (b; data)
    {
        put(w, hexDigit(b >> 4));
        put(w, hexDigit(b & 0x0F));
    }
}

///
@("crypto.encoding.hex.encodeHex.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) buf;
    static immutable ubyte[4] data = [0xde, 0xad, 0xbe, 0xef];
    encodeHex(data[], buf);
    assert(buf[] == "deadbeef");
}

@("crypto.encoding.hex.encodeHex.empty")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 16) buf;
    encodeHex(null, buf);
    assert(buf[].length == 0);
}

@("crypto.encoding.hex.encodeHex.lowercase")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 16) buf;
    // 0x00 and 0xFF exercise both ends of the nibble range; output is lowercase.
    static immutable ubyte[3] data = [0x00, 0x0a, 0xff];
    encodeHex(data[], buf);
    assert(buf[] == "000aff");
}

/// Decodes a single hex character to its `0 … 15` nibble value, or `-1` if it
/// is not a hex digit. Accepts both cases.
private int hexValue(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

/**
 * Decodes hexadecimal `s` into `outBuf`, accepting both lowercase and
 * uppercase digits, and returns the populated sub-slice `outBuf[0 .. n]`.
 *
 * `outBuf` must hold at least `hexMaxDecodedLength(s.length)` bytes; the
 * contract requires it and the body still bounds-checks defensively, returning
 * an error rather than overrunning.
 *
 * Failure modes (all leave `outBuf` partially written but the result is the
 * error, not a slice):
 * $(UL
 *   $(LI odd-length `s` → `unexpectedEnd` at the final, unpaired character;)
 *   $(LI a non-hex character → `unexpectedCharacter` at its offset;)
 *   $(LI `outBuf` too small → `widthMismatch` at the byte index that did not
 *     fit.)
 * )
 *
 * Params:
 *   s      = hex characters to decode
 *   outBuf = caller-provided destination, sized via $(LREF hexMaxDecodedLength)
 * Returns: the decoded bytes `outBuf[0 .. s.length / 2]`, or a parse error.
 */
ParseExpected!(ubyte[]) decodeHex(scope const(char)[] s, ubyte[] outBuf)
in (outBuf.length >= hexMaxDecodedLength(s.length),
    "decodeHex: outBuf too small for s")
{
    if (s.length % 2 != 0)
        return parseErr!(ubyte[])(ParseErrorCode.unexpectedEnd, s.length - 1);

    const n = s.length / 2;
    if (outBuf.length < n)
        return parseErr!(ubyte[])(ParseErrorCode.widthMismatch, outBuf.length);

    foreach (i; 0 .. n)
    {
        const hi = hexValue(s[i * 2]);
        if (hi < 0)
            return parseErr!(ubyte[])(ParseErrorCode.unexpectedCharacter, i * 2);
        const lo = hexValue(s[i * 2 + 1]);
        if (lo < 0)
            return parseErr!(ubyte[])(ParseErrorCode.unexpectedCharacter, i * 2 + 1);
        outBuf[i] = cast(ubyte)((hi << 4) | lo);
    }

    return parseOk(outBuf[0 .. n]);
}

///
@("crypto.encoding.hex.decodeHex.basic")
@safe pure nothrow @nogc
unittest
{
    ubyte[hexMaxDecodedLength(8)] out_;
    auto r = decodeHex("deadbeef", out_[]);
    assert(r.hasValue);
    static immutable ubyte[4] expected = [0xde, 0xad, 0xbe, 0xef];
    assert(r.value == expected[]);
}

@("crypto.encoding.hex.decodeHex.mixedCase")
@safe pure nothrow @nogc
unittest
{
    // "deadBEEF" — mixed case must decode identically to all-lowercase.
    ubyte[8] out_;
    auto r = decodeHex("deadBEEF", out_[]);
    assert(r.hasValue);
    static immutable ubyte[4] expected = [0xde, 0xad, 0xbe, 0xef];
    assert(r.value == expected[]);
}

@("crypto.encoding.hex.decodeHex.empty")
@safe pure nothrow @nogc
unittest
{
    ubyte[1] out_;
    auto r = decodeHex("", out_[]);
    assert(r.hasValue);
    assert(r.value.length == 0);
}

@("crypto.encoding.hex.decodeHex.oddLength")
@safe pure nothrow @nogc
unittest
{
    ubyte[4] out_;
    auto r = decodeHex("abc", out_[]);
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.unexpectedEnd);
    assert(r.error.offset == 2); // the trailing, unpaired 'c'
}

@("crypto.encoding.hex.decodeHex.nonHexCharacter")
@safe pure nothrow @nogc
unittest
{
    ubyte[4] out_;
    // 'g' at offset 5 is not a hex digit; the preceding "dead" is valid.
    auto r = decodeHex("deadg0", out_[]);
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.unexpectedCharacter);
    assert(r.error.offset == 4); // 'g' is at index 4
}

@("crypto.encoding.hex.decodeHex.nonHexInLowNibble")
@safe pure nothrow @nogc
unittest
{
    ubyte[4] out_;
    // 'z' sits in the low-nibble position of the first byte (offset 1).
    auto r = decodeHex("az", out_[]);
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.unexpectedCharacter);
    assert(r.error.offset == 1);
}

@("crypto.encoding.hex.roundTrip")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    static immutable ubyte[5] a = [0x00, 0x10, 0x7f, 0x80, 0xff];
    static immutable ubyte[3] b = [0xca, 0xfe, 0x42];

    void roundTrip(scope const(ubyte)[] data)
    {
        SmallBuffer!(char, 64) enc;
        encodeHex(data, enc);

        ubyte[64] dec;
        auto r = decodeHex(enc[], dec[]);
        assert(r.hasValue);
        assert(r.value == data);
    }

    roundTrip(a[]);
    roundTrip(b[]);
    roundTrip(null);
}
