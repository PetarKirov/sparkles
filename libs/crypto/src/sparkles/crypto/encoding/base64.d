/**
 * Standard-alphabet base64, unpadded and `=`-padded, with strict canonical
 * decoding.
 *
 * The age wire format uses two base64 flavours over the standard RFC 4648
 * alphabet `A-Za-z0-9+/`:
 *
 * $(UL
 *   $(LI **unpadded** — stanza bodies and stanza arguments (§7.3); no `=`
 *        characters appear, and feeding one to $(LREF decodeBase64) is an
 *        error.)
 *   $(LI **`=`-padded** (RFC 4648 §4) — PEM armor (§7.6).)
 * )
 *
 * Encoding is an output-range writer (`w.put(c)`); decoding writes into a
 * caller-provided `ubyte[] outBuf` and returns a
 * $(REF ParseExpected, sparkles,core_cli,text,errors)`!(ubyte[])` whose value
 * is the populated sub-slice `outBuf[0 .. n]`. Callers size `outBuf` with the
 * length helpers below.
 *
 * Decoding is **strict and canonical** — required by the age spec (§5):
 *
 * $(UL
 *   $(LI any character outside the alphabet (or a misplaced `=`) is rejected;)
 *   $(LI the unused low bits of a partial final group MUST be zero, else
 *        $(REF nonCanonicalEncoding, sparkles,core_cli,text,errors);)
 *   $(LI an unpadded length of `1 mod 4` is impossible
 *        ($(REF nonCanonicalEncoding, sparkles,core_cli,text,errors));)
 *   $(LI $(LREF decodeBase64) rejects every `=`
 *        ($(REF invalidPadding, sparkles,core_cli,text,errors)); the padded
 *        decoder requires exactly the correct `=` count in the correct place.)
 * )
 *
 * Everything here is `@safe pure nothrow @nogc`.
 */
module sparkles.crypto.encoding.base64;

import sparkles.core_cli.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

// ─────────────────────────────────────────────────────────────────────────────
// Encoders (writer-templated; attributes inferred — see the note below)
// ─────────────────────────────────────────────────────────────────────────────
//
// These are defined before the module-level `@safe pure nothrow @nogc:` block
// so their attributes are *inferred* from the `Writer` output range: `@nogc`
// when handed a `SmallBuffer`, but GC-using when the age layer hands them a
// GC-backed `Appender`. Pinning them `@nogc` would reject the `Appender` path.

/// Shared core for both encoders. Emits full 4-char groups, then a 2- or
/// 3-char partial group for a 1- or 2-byte tail. When `pad`, the partial group
/// is filled out to four characters with `'='`.
private void encodeImpl(bool pad, Writer)(scope const(ubyte)[] data, ref Writer w)
    @safe pure nothrow
{
    // Indexing the immutable alphabet yields an `immutable(char)` lvalue, which
    // can't bind to `SmallBuffer.put`'s `auto ref char`; emit a plain `char`.
    void emitChar(char c) { w.put(c); }

    size_t i = 0;
    // Full 3-byte → 4-char groups.
    for (; i + 3 <= data.length; i += 3)
    {
        const b0 = data[i], b1 = data[i + 1], b2 = data[i + 2];
        emitChar(encodeAlphabet[b0 >> 2]);
        emitChar(encodeAlphabet[((b0 & 0x03) << 4) | (b1 >> 4)]);
        emitChar(encodeAlphabet[((b1 & 0x0F) << 2) | (b2 >> 6)]);
        emitChar(encodeAlphabet[b2 & 0x3F]);
    }

    const rem = data.length - i;
    if (rem == 1)
    {
        const b0 = data[i];
        emitChar(encodeAlphabet[b0 >> 2]);
        emitChar(encodeAlphabet[(b0 & 0x03) << 4]);
        static if (pad)
        {
            emitChar('=');
            emitChar('=');
        }
    }
    else if (rem == 2)
    {
        const b0 = data[i], b1 = data[i + 1];
        emitChar(encodeAlphabet[b0 >> 2]);
        emitChar(encodeAlphabet[((b0 & 0x03) << 4) | (b1 >> 4)]);
        emitChar(encodeAlphabet[(b1 & 0x0F) << 2]);
        static if (pad)
            emitChar('=');
    }
}

/// Encodes `data` as **unpadded** standard base64 into the output range `w`
/// (no `'='` characters). This is the age wire form for stanza bodies and
/// arguments.
void encodeBase64(Writer)(scope const(ubyte)[] data, ref Writer w) @safe pure nothrow
{
    encodeImpl!false(data, w);
}

/// Encodes `data` as **`=`-padded** standard base64 (RFC 4648 §4) into `w`.
/// This is the PEM-armor form (§7.6).
void encodeBase64Padded(Writer)(scope const(ubyte)[] data, ref Writer w) @safe pure nothrow
{
    encodeImpl!true(data, w);
}

@safe pure nothrow @nogc:

// ─────────────────────────────────────────────────────────────────────────────
// Alphabet and decode table
// ─────────────────────────────────────────────────────────────────────────────

/// The standard RFC 4648 base64 alphabet: index `0 … 63` → output character.
private immutable char[64] encodeAlphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// 256-entry reverse lookup: a character byte → its `0 … 63` value, or `0xFF`
/// for any byte outside the alphabet. Computed at compile time from
/// $(LREF encodeAlphabet) so the two can never drift apart.
private immutable ubyte[256] decodeTable = () {
    ubyte[256] table;
    foreach (ref e; table)
        e = 0xFF;
    foreach (ubyte v, c; encodeAlphabet)
        table[cast(ubyte) c] = v;
    return table;
}();

// ─────────────────────────────────────────────────────────────────────────────
// Length helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Number of characters an **unpadded** encode of `n` bytes produces:
/// `ceil(n * 8 / 6)`. A 3-byte group is 4 chars; a 1- or 2-byte tail is 2 or 3.
size_t base64EncodedLength(size_t n)
    => (n * 8 + 5) / 6;

@("crypto.base64.base64EncodedLength")
@safe pure nothrow @nogc
unittest
{
    assert(base64EncodedLength(0) == 0);
    assert(base64EncodedLength(1) == 2);
    assert(base64EncodedLength(2) == 3);
    assert(base64EncodedLength(3) == 4);
    assert(base64EncodedLength(4) == 6);
    assert(base64EncodedLength(5) == 7);
    assert(base64EncodedLength(6) == 8);
}

/// Number of characters a **`=`-padded** encode of `n` bytes produces:
/// `ceil(n / 3) * 4` — always a multiple of four.
size_t base64PaddedEncodedLength(size_t n)
    => ((n + 2) / 3) * 4;

@("crypto.base64.base64PaddedEncodedLength")
@safe pure nothrow @nogc
unittest
{
    assert(base64PaddedEncodedLength(0) == 0);
    assert(base64PaddedEncodedLength(1) == 4);
    assert(base64PaddedEncodedLength(2) == 4);
    assert(base64PaddedEncodedLength(3) == 4);
    assert(base64PaddedEncodedLength(4) == 8);
    assert(base64PaddedEncodedLength(6) == 8);
}

/// Upper bound on the number of bytes a decode of `encodedChars` characters
/// could yield, for sizing `outBuf`. Works for both the padded and unpadded
/// forms: `encodedChars / 4 * 3 + extra`, where a partial group of `r` chars
/// contributes at most `r - 1` bytes (and padded inputs, being a multiple of
/// four, simply over-allocate by the padding — which is safe).
size_t base64MaxDecodedLength(size_t encodedChars)
{
    const groups = encodedChars / 4;
    const rem = encodedChars % 4;
    // rem ∈ {0,1,2,3}; a 1-char remainder is never valid but `rem - 1 == 0`
    // keeps the bound non-negative and correct as an upper bound.
    const extra = rem == 0 ? 0 : rem - 1;
    return groups * 3 + extra;
}

@("crypto.base64.base64MaxDecodedLength")
@safe pure nothrow @nogc
unittest
{
    assert(base64MaxDecodedLength(0) == 0);
    assert(base64MaxDecodedLength(2) == 1);   // "Zg"   → 1 byte
    assert(base64MaxDecodedLength(3) == 2);   // "Zm8"  → 2 bytes
    assert(base64MaxDecodedLength(4) == 3);   // "Zm9v" → 3 bytes
    assert(base64MaxDecodedLength(6) == 4);   // "Zm9vYg"
    assert(base64MaxDecodedLength(8) == 6);   // padded "Zm9vYg==" or "foobar" core
    // A padded encode sizes by char count, so it over-allocates by the padding,
    // which is always safe (never an underestimate).
    assert(base64MaxDecodedLength(base64PaddedEncodedLength(4)) >= 4);
}

// ─────────────────────────────────────────────────────────────────────────────
// Encoding
// ─────────────────────────────────────────────────────────────────────────────

// The writer-templated encoders (`encodeImpl`, `encodeBase64`,
// `encodeBase64Padded`) are defined ABOVE the module-level
// `@safe pure nothrow @nogc:` block (see the top of the module) so their
// attributes are *inferred* from the `Writer`: `@nogc` with a `SmallBuffer`,
// but GC-using when the age layer hands them a GC-backed `Appender`.

///
@("crypto.base64.encodeBase64.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) buf;
    encodeBase64(cast(const(ubyte)[]) "foobar", buf);
    assert(buf[] == "Zm9vYmFy");
}

///
@("crypto.base64.encodeBase64Padded.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) buf;
    encodeBase64Padded(cast(const(ubyte)[]) "fo", buf);
    assert(buf[] == "Zm8=");
}

// ─────────────────────────────────────────────────────────────────────────────
// Decoding
// ─────────────────────────────────────────────────────────────────────────────

/// Strict-canonical core for both decoders. `s` is the alphabet portion only —
/// the padded decoder strips and validates `'='` before calling this; the
/// unpadded decoder passes the whole input. `s.length % 4 == 1` is rejected as
/// non-canonical (an impossible base64 length).
///
/// On success returns the populated `outBuf[0 .. n]`. Defends against an
/// undersized `outBuf` by bounds-checking each write rather than overrunning.
private ParseExpected!(ubyte[]) decodeCore(scope const(char)[] s, ubyte[] outBuf)
in (outBuf.length >= base64MaxDecodedLength(s.length),
    "outBuf too small; size it with base64MaxDecodedLength")
{
    const rem = s.length % 4;
    if (rem == 1)
        // A single trailing character can never be a valid base64 group.
        return parseErr!(ubyte[])(ParseErrorCode.nonCanonicalEncoding, s.length - 1);

    size_t outLen = 0;

    // Writes one decoded byte, defensively bounds-checked against outBuf.
    bool emit(ubyte b)
    {
        if (outLen >= outBuf.length)
            return false;
        outBuf[outLen++] = b;
        return true;
    }

    size_t i = 0;

    // Full 4-char → 3-byte groups.
    for (; i + 4 <= s.length; i += 4)
    {
        ubyte[4] v = void;
        foreach (k; 0 .. 4)
        {
            const d = decodeTable[cast(ubyte) s[i + k]];
            if (d == 0xFF)
                return invalidCharOrPadding(s[i + k], i + k);
            v[k] = d;
        }
        if (!emit(cast(ubyte)((v[0] << 2) | (v[1] >> 4)))
            || !emit(cast(ubyte)((v[1] << 4) | (v[2] >> 2)))
            || !emit(cast(ubyte)((v[2] << 6) | v[3])))
            return parseErr!(ubyte[])(ParseErrorCode.widthMismatch, i);
    }

    // Partial trailing group: rem ∈ {0, 2, 3} (1 handled above).
    if (rem == 2)
    {
        const d0 = decodeTable[cast(ubyte) s[i]];
        if (d0 == 0xFF)
            return invalidCharOrPadding(s[i], i);
        const d1 = decodeTable[cast(ubyte) s[i + 1]];
        if (d1 == 0xFF)
            return invalidCharOrPadding(s[i + 1], i + 1);
        // The last char's low 4 bits are unused and MUST be zero (canonical).
        if (d1 & 0x0F)
            return parseErr!(ubyte[])(ParseErrorCode.nonCanonicalEncoding, i + 1);
        if (!emit(cast(ubyte)((d0 << 2) | (d1 >> 4))))
            return parseErr!(ubyte[])(ParseErrorCode.widthMismatch, i);
    }
    else if (rem == 3)
    {
        const d0 = decodeTable[cast(ubyte) s[i]];
        if (d0 == 0xFF)
            return invalidCharOrPadding(s[i], i);
        const d1 = decodeTable[cast(ubyte) s[i + 1]];
        if (d1 == 0xFF)
            return invalidCharOrPadding(s[i + 1], i + 1);
        const d2 = decodeTable[cast(ubyte) s[i + 2]];
        if (d2 == 0xFF)
            return invalidCharOrPadding(s[i + 2], i + 2);
        // The last char's low 2 bits are unused and MUST be zero (canonical).
        if (d2 & 0x03)
            return parseErr!(ubyte[])(ParseErrorCode.nonCanonicalEncoding, i + 2);
        if (!emit(cast(ubyte)((d0 << 2) | (d1 >> 4)))
            || !emit(cast(ubyte)((d1 << 4) | (d2 >> 2))))
            return parseErr!(ubyte[])(ParseErrorCode.widthMismatch, i);
    }

    return parseOk(outBuf[0 .. outLen]);
}

/// Classifies a non-alphabet character at `offset`: an `'='` is a padding
/// error (it is structurally meaningful but misplaced here), anything else is
/// an unexpected character.
private ParseExpected!(ubyte[]) invalidCharOrPadding(char c, size_t offset)
    => c == '='
        ? parseErr!(ubyte[])(ParseErrorCode.invalidPadding, offset)
        : parseErr!(ubyte[])(ParseErrorCode.unexpectedCharacter, offset);

/// Decodes **unpadded** standard base64 from `s` into `outBuf`, strictly and
/// canonically. Any `'='` is rejected as
/// $(REF invalidPadding, sparkles,core_cli,text,errors); a non-alphabet
/// character as $(REF unexpectedCharacter, sparkles,core_cli,text,errors)
/// (at its offset); a partial group's non-zero unused bits, or a `1 mod 4`
/// length, as $(REF nonCanonicalEncoding, sparkles,core_cli,text,errors).
/// On success the result value is `outBuf[0 .. n]`.
///
/// Size `outBuf` with $(LREF base64MaxDecodedLength)`(s.length)`.
ParseExpected!(ubyte[]) decodeBase64(scope const(char)[] s, ubyte[] outBuf)
    => decodeCore(s, outBuf);

///
@("crypto.base64.decodeBase64.basic")
@safe pure nothrow @nogc
unittest
{
    ubyte[8] out_ = void;
    auto r = decodeBase64("Zm9v", out_[]);
    assert(r.hasValue);
    assert(r.value == cast(const(ubyte)[]) "foo");
}

/// Decodes **`=`-padded** standard base64 (RFC 4648 §4) from `s` into
/// `outBuf`, strictly and canonically. The input length MUST be a multiple of
/// four; the `'='` count MUST be exactly the amount the final group requires
/// (0, 1, or 2) and they MUST be the trailing characters — anything else is
/// $(REF invalidPadding, sparkles,core_cli,text,errors). The remaining rules
/// match $(LREF decodeBase64). On success the result value is `outBuf[0 .. n]`.
///
/// Size `outBuf` with $(LREF base64MaxDecodedLength)`(s.length)`.
ParseExpected!(ubyte[]) decodeBase64Padded(scope const(char)[] s, ubyte[] outBuf)
{
    // Padded input is always a whole number of 4-char groups.
    if (s.length % 4 != 0)
        return parseErr!(ubyte[])(ParseErrorCode.invalidPadding, s.length);

    if (s.length == 0)
        return parseOk(outBuf[0 .. 0]);

    // Count and validate the trailing '=' run: 0, 1, or 2, in the last group.
    size_t padCount = 0;
    if (s[$ - 1] == '=')
    {
        padCount = 1;
        if (s.length >= 2 && s[$ - 2] == '=')
            padCount = 2;
    }

    // No '=' may appear anywhere but the trailing run.
    foreach (i; 0 .. s.length - padCount)
        if (s[i] == '=')
            return parseErr!(ubyte[])(ParseErrorCode.invalidPadding, i);

    // Strip the padding and decode the alphabet remainder; the resulting length
    // mod 4 is exactly 4 - padCount, which decodeCore validates canonically.
    return decodeCore(s[0 .. $ - padCount], outBuf);
}

///
@("crypto.base64.decodeBase64Padded.basic")
@safe pure nothrow @nogc
unittest
{
    ubyte[8] out_ = void;
    auto r = decodeBase64Padded("Zm8=", out_[]);
    assert(r.hasValue);
    assert(r.value == cast(const(ubyte)[]) "fo");
}

// ─────────────────────────────────────────────────────────────────────────────
// RFC 4648 §10 round-trip vectors
// ─────────────────────────────────────────────────────────────────────────────

@("crypto.base64.rfc4648.unpadded")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    static struct V { string input; string encoded; }
    static immutable V[7] vectors = [
        V("",        ""),
        V("f",       "Zg"),
        V("fo",      "Zm8"),
        V("foo",     "Zm9v"),
        V("foob",    "Zm9vYg"),
        V("fooba",   "Zm9vYmE"),
        V("foobar",  "Zm9vYmFy"),
    ];

    foreach (v; vectors)
    {
        // Encode matches the vector.
        SmallBuffer!(char, 32) enc;
        encodeBase64(cast(const(ubyte)[]) v.input, enc);
        assert(enc[] == v.encoded);
        assert(enc.length == base64EncodedLength(v.input.length));

        // Decode round-trips back to the input.
        ubyte[32] out_ = void;
        auto r = decodeBase64(v.encoded, out_[]);
        assert(r.hasValue);
        assert(r.value == cast(const(ubyte)[]) v.input);
    }
}

@("crypto.base64.rfc4648.padded")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    static struct V { string input; string encoded; }
    static immutable V[7] vectors = [
        V("",        ""),
        V("f",       "Zg=="),
        V("fo",      "Zm8="),
        V("foo",     "Zm9v"),
        V("foob",    "Zm9vYg=="),
        V("fooba",   "Zm9vYmE="),
        V("foobar",  "Zm9vYmFy"),
    ];

    foreach (v; vectors)
    {
        SmallBuffer!(char, 32) enc;
        encodeBase64Padded(cast(const(ubyte)[]) v.input, enc);
        assert(enc[] == v.encoded);
        assert(enc.length == base64PaddedEncodedLength(v.input.length));

        ubyte[32] out_ = void;
        auto r = decodeBase64Padded(v.encoded, out_[]);
        assert(r.hasValue);
        assert(r.value == cast(const(ubyte)[]) v.input);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Strict-canonical rejection tests
// ─────────────────────────────────────────────────────────────────────────────

@("crypto.base64.decodeBase64.rejectsNonCanonicalTrailingBits")
@safe pure nothrow @nogc
unittest
{
    ubyte[8] out_ = void;

    // 2-char tail: canonical "Zg" decodes 'f'; the last char's low 4 bits must
    // be zero. "Zh" sets a low bit ('h' = 33 = 0b100001) → non-canonical.
    auto a = decodeBase64("Zh", out_[]);
    assert(!a.hasValue);
    assert(a.error.code == ParseErrorCode.nonCanonicalEncoding);
    assert(a.error.offset == 1);

    // 3-char tail: canonical "Zm8" decodes "fo"; the last char's low 2 bits
    // must be zero. "Zm9" ('9' = 61 = 0b111101) sets a low bit → non-canonical.
    auto b = decodeBase64("Zm9", out_[]);
    assert(!b.hasValue);
    assert(b.error.code == ParseErrorCode.nonCanonicalEncoding);
    assert(b.error.offset == 2);
}

@("crypto.base64.decodeBase64.rejectsPadding")
@safe pure nothrow @nogc
unittest
{
    ubyte[8] out_ = void;

    // A '=' fed to the unpadded decoder is invalid padding.
    auto a = decodeBase64("Zm8=", out_[]);
    assert(!a.hasValue);
    assert(a.error.code == ParseErrorCode.invalidPadding);
    assert(a.error.offset == 3);

    // Even a fully-padded one-byte form is rejected unpadded.
    auto b = decodeBase64("Zg==", out_[]);
    assert(!b.hasValue);
    assert(b.error.code == ParseErrorCode.invalidPadding);
}

@("crypto.base64.decodeBase64.rejectsNonAlphabet")
@safe pure nothrow @nogc
unittest
{
    ubyte[8] out_ = void;

    // '-' is not in the standard alphabet; offset points at it.
    auto a = decodeBase64("Zm-v", out_[]);
    assert(!a.hasValue);
    assert(a.error.code == ParseErrorCode.unexpectedCharacter);
    assert(a.error.offset == 2);

    // A non-alphabet byte in the trailing partial group, too.
    auto b = decodeBase64("Z!8", out_[]);
    assert(!b.hasValue);
    assert(b.error.code == ParseErrorCode.unexpectedCharacter);
    assert(b.error.offset == 1);
}

@("crypto.base64.decodeBase64.rejectsLengthOneModFour")
@safe pure nothrow @nogc
unittest
{
    ubyte[8] out_ = void;

    // A single trailing character (length 1) can never be valid.
    auto a = decodeBase64("Z", out_[]);
    assert(!a.hasValue);
    assert(a.error.code == ParseErrorCode.nonCanonicalEncoding);
    assert(a.error.offset == 0);

    // 5 chars = one group + a 1-char remainder.
    auto b = decodeBase64("Zm9vY", out_[]);
    assert(!b.hasValue);
    assert(b.error.code == ParseErrorCode.nonCanonicalEncoding);
    assert(b.error.offset == 4);
}

@("crypto.base64.decodeBase64Padded.rejectsMisplacedAndWrongCount")
@safe pure nothrow @nogc
unittest
{
    ubyte[8] out_ = void;

    // Non-multiple-of-4 length is structurally invalid for padded input.
    auto a = decodeBase64Padded("Zm9", out_[]);
    assert(!a.hasValue);
    assert(a.error.code == ParseErrorCode.invalidPadding);

    // A '=' that is not in the trailing run is misplaced.
    auto b = decodeBase64Padded("Z=m8", out_[]);
    assert(!b.hasValue);
    assert(b.error.code == ParseErrorCode.invalidPadding);
    assert(b.error.offset == 1);

    // "====" — too much padding; after stripping two it leaves "==", and the
    // remaining '=' is caught as misplaced padding.
    auto c = decodeBase64Padded("====", out_[]);
    assert(!c.hasValue);
    assert(c.error.code == ParseErrorCode.invalidPadding);
}

@("crypto.base64.decodeBase64Padded.rejectsNonCanonicalTrailingBits")
@safe pure nothrow @nogc
unittest
{
    ubyte[8] out_ = void;

    // "Zh==" — same non-canonical low bits as the unpadded "Zh" case.
    auto r = decodeBase64Padded("Zh==", out_[]);
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.nonCanonicalEncoding);
}

// ─────────────────────────────────────────────────────────────────────────────
// Round-trip over the full byte range and larger inputs
// ─────────────────────────────────────────────────────────────────────────────

@("crypto.base64.roundTrip.allByteValues")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    // Every byte 0 … 255 exactly once, an input whose length (256) is not a
    // multiple of 3, so the tail logic is exercised.
    ubyte[256] data = void;
    foreach (i; 0 .. 256)
        data[i] = cast(ubyte) i;

    SmallBuffer!(char, 512) enc;
    encodeBase64(data[], enc);
    assert(enc.length == base64EncodedLength(data.length));

    ubyte[base64MaxDecodedLength(512)] out_ = void;
    auto r = decodeBase64(enc[], out_[]);
    assert(r.hasValue);
    assert(r.value == data[]);

    // And the padded variant round-trips too.
    SmallBuffer!(char, 512) encP;
    encodeBase64Padded(data[], encP);
    assert(encP.length == base64PaddedEncodedLength(data.length));

    ubyte[base64MaxDecodedLength(512)] outP = void;
    auto rp = decodeBase64Padded(encP[], outP[]);
    assert(rp.hasValue);
    assert(rp.value == data[]);
}
