/**
Bech32 encoding (BIP173) — the long, length-limit-free variant age uses for
`age1…` recipients and `AGE-SECRET-KEY-1…` identities.

A bech32 string is `<hrp>1<data-part>` where the data part is the base-32
payload (5 bits per character over the charset
$(D qpzry9x8gf2tvdw0s3jn54khce6mua7l)) followed by a 6-character BIP173
checksum. The human-readable part (`hrp`) and separator `1` precede it.

This module deliberately omits the BIP173 90-character total-length limit:
age uses arbitrarily long bech32 (e.g. the long `age1…` post-quantum
recipients), so long inputs MUST round-trip. All other BIP173 rules apply —
the checksum is computed over the lowercase form, mixed-case input is rejected
($(D nonCanonicalEncoding)), and a checksum failure is $(D checksumMismatch).

Encoding always emits lowercase. Decoding accepts an input that is entirely
lowercase or entirely uppercase (rejecting any mix), folds the checksum over
the numeric lowercased character values without allocating, and converts the
5-bit data symbols back to 8-bit bytes, rejecting leftover non-zero bits or
excess padding ($(D nonCanonicalEncoding)).

All functions are fully `@safe pure nothrow @nogc`.

See_Also: $(LINK https://github.com/bitcoin/bips/blob/master/bip-0173.mediawiki)
*/
module sparkles.crypto.encoding.bech32;

import sparkles.core_cli.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

/**
Encodes `hrp` + `data` as a lowercase bech32 string into the output range `w`,
emitting `<hrp>1<data-symbols><6-char checksum>`.

The human-readable part `hrp` is written verbatim (callers pass it already
lowercased); the data bytes are repacked from 8-bit groups into 5-bit symbols,
the BIP173 checksum is computed over the hrp-expanded form, and the six
checksum symbols are appended. No length limit is imposed.

Defined before the module-level `@safe pure nothrow @nogc:` block so its
attributes are *inferred* from `Writer`: `@nogc` with a `SmallBuffer`, but
GC-using when handed a GC-backed `Appender` (the age layer's `toString`). It is
otherwise `@safe pure nothrow`.

Params:
    hrp  = human-readable part (e.g. `"age"`), written as-is
    data = payload bytes to encode
    w    = output range of `char` (e.g. a `SmallBuffer!(char, N)`)
*/
void encodeBech32(Writer)(scope const(char)[] hrp, scope const(ubyte)[] data, ref Writer w)
    @safe pure nothrow
{
    import std.range.primitives : put;

    import sparkles.core_cli.smallbuffer : SmallBuffer;

    // hrp, then the separator.
    put(w, hrp);
    put(w, '1');

    // Collect the checksum input — hrpExpand(hrp) ‖ dataSymbols ‖ six zero
    // placeholders — into one buffer while emitting each data symbol. polymod
    // is not incremental across an unknown suffix, so we fold it once at the
    // end. The buffer is @nogc (inline storage, pureMalloc spill) and
    // length-limit-free, matching age's long-bech32 requirement.
    SmallBuffer!(ubyte, 256) values;
    hrpExpandInto(hrp, values);

    // 8-bit → 5-bit, MSB-first.
    uint acc = 0;
    int bits = 0;
    foreach (b; data)
    {
        acc = (acc << 8) | b;
        bits += 8;
        while (bits >= 5)
        {
            bits -= 5;
            ubyte sym = cast(ubyte)((acc >> bits) & 0x1f);
            values.put(sym);
            put(w, charset[sym]);
        }
    }
    if (bits > 0)
    {
        ubyte sym = cast(ubyte)((acc << (5 - bits)) & 0x1f);
        values.put(sym);
        put(w, charset[sym]);
    }

    // Append six zero symbols, fold, XOR with 1, then emit the checksum.
    foreach (_; 0 .. 6)
        values.put(cast(ubyte) 0);
    const uint mod = polymod(values[]) ^ 1;
    foreach (i; 0 .. 6)
    {
        const ubyte sym = cast(ubyte)((mod >> (5 * (5 - i))) & 0x1f);
        put(w, charset[sym]);
    }
}

@safe pure nothrow @nogc:

// ─────────────────────────────────────────────────────────────────────────────
// Charset and checksum primitives (BIP173)
// ─────────────────────────────────────────────────────────────────────────────

/// The 32-symbol bech32 charset; index = 5-bit value, value = lowercase char.
private static immutable string charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

/// The five BIP173 generator constants used by $(LREF polymod).
private static immutable uint[5] generator =
    [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];

/// Maps a lowercase bech32 character to its 5-bit value, or `-1` if the
/// character is not in the charset.
private int charsetValue(char c)
{
    foreach (i, ch; charset)
        if (ch == c)
            return cast(int) i;
    return -1;
}

/// Folds the BIP173 generator polynomial over the 5-bit `values`, returning
/// the running checksum accumulator. A complete bech32 string (hrp-expanded ‖
/// data ‖ 6 checksum symbols) is valid iff this returns `1`.
private uint polymod(scope const(ubyte)[] values)
{
    uint chk = 1;
    foreach (v; values)
    {
        const uint top = chk >> 25;
        chk = ((chk & 0x1ffffff) << 5) ^ v;
        foreach (i; 0 .. 5)
            if ((top >> i) & 1)
                chk ^= generator[i];
    }
    return chk;
}

/// True if `c` is an ASCII uppercase letter.
private bool isUpperAscii(char c) => c >= 'A' && c <= 'Z';

/// True if `c` is an ASCII lowercase letter.
private bool isLowerAscii(char c) => c >= 'a' && c <= 'z';

/// Lowercases an ASCII character numerically (no table, no allocation).
private char toLowerAscii(char c) => isUpperAscii(c) ? cast(char)(c + 32) : c;

/// Stores a borrowed sub-slice into a caller-provided `ref` slice. This exists
/// to express a cross-parameter borrow (`hrpOut` aliases the input `s`) that
/// DIP1000 cannot model when the function's value return separately borrows a
/// different parameter. The borrow is sound by the documented contract that the
/// `hrpOut` result must not outlive the input it was sliced from.
private void assignBorrowed(ref const(char)[] dst, scope const(char)[] src) @trusted
{
    dst = cast(const(char)[]) src;
}

// ─────────────────────────────────────────────────────────────────────────────
// Length helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Number of 5-bit symbols a `dataLen`-byte payload expands into (ceil of
/// `dataLen * 8 / 5`).
private size_t dataSymbolCount(size_t dataLen) => (dataLen * 8 + 4) / 5;

/**
Exact character count $(LREF encodeBech32) emits for an `hrpLen`-character
human-readable part and a `dataLen`-byte payload:
`hrpLen` + `1` (separator) + data symbols + `6` (checksum).
*/
size_t bech32EncodedLength(size_t hrpLen, size_t dataLen)
    => hrpLen + 1 + dataSymbolCount(dataLen) + 6;

///
@("crypto.bech32.bech32EncodedLength")
@safe pure nothrow @nogc
unittest
{
    // hrp "age" (3) + '1' + ceil(32*8/5)=52 symbols + 6 checksum = 62
    assert(bech32EncodedLength(3, 32) == 62);
}

/**
Upper bound on the number of decoded bytes $(LREF decodeBech32) can yield from
an `sLen`-character input — used to size the caller's `outBuf`. It assumes the
entire input (minus a minimal `<hrp>1` and the 6 checksum symbols) is data:
`(symbols * 5) / 8`. Always safe to over-allocate.
*/
size_t bech32MaxDecodedLength(size_t sLen)
{
    // Subtract the minimal non-data overhead: 1 separator + 6 checksum symbols.
    // (An hrp of length 0 maximizes the data-part length.)
    enum overhead = 1 + 6;
    if (sLen <= overhead)
        return 0;
    const symbols = sLen - overhead;
    return (symbols * 5) / 8;
}

///
@("crypto.bech32.bech32MaxDecodedLength")
@safe pure nothrow @nogc
unittest
{
    // 62-char "age1…": 62 - 7 = 55 symbols, (55*5)/8 = 34 ≥ the real 32.
    assert(bech32MaxDecodedLength(62) >= 32);
    assert(bech32MaxDecodedLength(5) == 0);   // too short for any data
}

// ─────────────────────────────────────────────────────────────────────────────
// Encoding
// ─────────────────────────────────────────────────────────────────────────────

// `encodeBech32` is defined ABOVE the module-level `@safe pure nothrow @nogc:`
// block (see the top of the module) so that its attributes are *inferred* from
// its `Writer` output range: `@nogc` when handed a `SmallBuffer`, but
// GC-using when the age layer hands it a GC-backed `Appender`. Pinning it
// `@nogc` would reject the `Appender` path.

/// Expands `hrp` into the BIP173 checksum prefix — every char's high 3 bits,
/// then a `0` separator, then every char's low 5 bits — appending into `out_`.
/// Characters are lowercased numerically.
private void hrpExpandInto(Writer)(scope const(char)[] hrp, ref Writer out_)
{
    foreach (c; hrp)
        out_.put(cast(ubyte)(toLowerAscii(c) >> 5));
    out_.put(cast(ubyte) 0);
    foreach (c; hrp)
        out_.put(cast(ubyte)(toLowerAscii(c) & 0x1f));
}

///
@("crypto.bech32.encodeBech32.roundTripKnownKey")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    // An age-style key: hrp "age" + 32 bytes.
    static immutable ubyte[32] key = [
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    ];

    SmallBuffer!(char, 128) buf;
    encodeBech32("age", key[], buf);
    assert(buf[].length == bech32EncodedLength(3, 32));
    assert(buf[][0 .. 4] == "age1");

    // Decode it back to the same hrp + bytes.
    ubyte[64] out_;
    const(char)[] hrpOut;
    auto r = decodeBech32(buf[], hrpOut, out_[]);
    assert(r.hasValue);
    assert(hrpOut == "age");
    assert(r.value == key[]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Decoding
// ─────────────────────────────────────────────────────────────────────────────

/**
Decodes a bech32 string `s` into `outBuf`, returning the populated sub-slice
`outBuf[0 .. n]` on success.

The input is split on its $(B last) `1` into the human-readable part and the
data part; the data part's characters (the base-32 payload plus the 6-symbol
checksum) are validated against the bech32 charset. The BIP173 checksum is
verified (`polymod == 1`) over the lowercased character values, then the
payload symbols (excluding the checksum) are repacked from 5-bit to 8-bit
bytes.

`hrpOut` is set to the hrp sub-slice of `s` $(B as-is) (case preserved); the
caller is responsible for case-normalizing it before comparison.

No length limit is imposed, so arbitrarily long inputs decode.

Errors:
$(UL
    $(LI `emptyInput` — empty input, or no `1` separator, or an empty hrp.)
    $(LI `nonCanonicalEncoding` — mixed-case input, a too-short data part,
        a data character outside the charset that is a valid letter of the
        wrong case, or leftover non-zero / excess padding bits.)
    $(LI `unexpectedCharacter` — an hrp byte outside `[33, 126]`, or a data
        character outside the bech32 charset.)
    $(LI `checksumMismatch` — the 6-symbol checksum does not verify.)
)

Params:
    s      = bech32 string to decode
    hrpOut = set to the (case-preserved) hrp sub-slice of `s` on success
    outBuf = caller-provided buffer; size via $(LREF bech32MaxDecodedLength)

Returns: `ParseExpected!(ubyte[])` carrying `outBuf[0 .. n]` or a `ParseError`.
*/
ParseExpected!(ubyte[]) decodeBech32(
    return scope const(char)[] s, ref const(char)[] hrpOut, return scope ubyte[] outBuf)
in (outBuf.length >= bech32MaxDecodedLength(s.length),
    "outBuf too small for the maximum possible decode")
{
    alias R = ubyte[];

    hrpOut = null;

    if (s.length == 0)
        return parseErr!R(ParseErrorCode.emptyInput, 0);

    // 1. Determine the global case (all-lower / all-upper); reject any mix.
    bool sawLower = false, sawUpper = false;
    foreach (c; s)
    {
        if (isLowerAscii(c))
            sawLower = true;
        else if (isUpperAscii(c))
            sawUpper = true;
    }
    if (sawLower && sawUpper)
        return parseErr!R(ParseErrorCode.nonCanonicalEncoding, 0);

    // 2. Split on the LAST '1' separator.
    size_t sep = size_t.max;
    foreach_reverse (i, c; s)
        if (c == '1')
        {
            sep = i;
            break;
        }
    if (sep == size_t.max)              // no separator at all
        return parseErr!R(ParseErrorCode.emptyInput, 0);
    if (sep == 0)                       // empty hrp
        return parseErr!R(ParseErrorCode.emptyInput, 0);

    // `hrpOut` borrows the hrp sub-slice of `s`; it is the caller's contract
    // that the result not outlive `s` (both are caller-owned). DIP1000 can't
    // express this cross-parameter borrow when the value return separately
    // borrows `outBuf`, so the assignment is performed through a trusted helper.
    assignBorrowed(hrpOut, s[0 .. sep]);
    const dataPart = s[sep + 1 .. $];

    // The data part must hold at least the 6-symbol checksum.
    if (dataPart.length < 6)
        return parseErr!R(ParseErrorCode.nonCanonicalEncoding, sep + 1);

    // 3. Validate the hrp characters (printable ASCII, BIP173 range 33..126).
    foreach (i, c; hrpOut)
        if (c < 33 || c > 126)
            return parseErr!R(ParseErrorCode.unexpectedCharacter, i);

    // 4. Decode the data-part characters into 5-bit values, simultaneously
    //    folding the checksum. We compute polymod over
    //    hrpExpand(lowercased hrp) ‖ dataValues using a single buffer.
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(ubyte, 256) values;
    hrpExpandInto(hrpOut, values);      // lowercases hrp values internally

    foreach (i, c; dataPart)
    {
        const v = charsetValue(toLowerAscii(c));
        if (v < 0)
        {
            // Offset is relative to `s` (the input the parser received).
            return parseErr!R(ParseErrorCode.unexpectedCharacter, sep + 1 + i);
        }
        values.put(cast(ubyte) v);
    }

    // 5. Verify the checksum: polymod over the full expanded form == 1.
    if (polymod(values[]) != 1)
        return parseErr!R(ParseErrorCode.checksumMismatch, sep + 1);

    // 6. Repack the payload symbols (all but the trailing 6 checksum symbols)
    //    from 5-bit to 8-bit bytes. The payload symbols sit at the tail of
    //    `values` after the hrp-expanded prefix.
    const prefixLen = hrpOut.length * 2 + 1;            // hrpExpand length
    const symbols = values[][prefixLen .. $ - 6];        // exclude the 6 checksum syms

    uint acc = 0;
    int bits = 0;
    size_t n = 0;
    foreach (sym; symbols)
    {
        acc = (acc << 5) | sym;
        bits += 5;
        if (bits >= 8)
        {
            bits -= 8;
            if (n >= outBuf.length)     // defensive bounds check
                return parseErr!R(ParseErrorCode.nonCanonicalEncoding, sep + 1);
            outBuf[n++] = cast(ubyte)((acc >> bits) & 0xff);
        }
    }

    // 7. Reject non-canonical padding: leftover bits must be < 5 and zero, and
    //    there must not be a full extra group's worth of padding.
    if (bits >= 5)
        return parseErr!R(ParseErrorCode.nonCanonicalEncoding, sep + 1);
    if (((acc << (8 - bits)) & 0xff) != 0)
        return parseErr!R(ParseErrorCode.nonCanonicalEncoding, sep + 1);

    return parseOk!R(outBuf[0 .. n]);
}

///
@("crypto.bech32.decodeBech32.bip173Vector")
@safe pure nothrow @nogc
unittest
{
    // BIP173 valid test vector. "A12UEL5L" decodes hrp "A" with an empty
    // data part (its 6 symbols are all checksum). All-uppercase is accepted.
    ubyte[8] out_;
    const(char)[] hrpOut;
    auto r = decodeBech32("A12UEL5L", hrpOut, out_[]);
    assert(r.hasValue);
    assert(hrpOut == "A");          // case preserved
    assert(r.value.length == 0);    // empty data part

    // Lowercase form of the same vector also decodes.
    ubyte[8] out2;
    const(char)[] hrp2;
    auto r2 = decodeBech32("a12uel5l", hrp2, out2[]);
    assert(r2.hasValue);
    assert(hrp2 == "a");
    assert(r2.value.length == 0);
}

@("crypto.bech32.decodeBech32.checksumMismatch")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    static immutable ubyte[16] payload = [
        0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80,
        0x90, 0xa0, 0xb0, 0xc0, 0xd0, 0xe0, 0xf0, 0x01,
    ];

    SmallBuffer!(char, 128) buf;
    encodeBech32("age", payload[], buf);

    // Flip one character of the data part (not in the hrp, not the separator).
    SmallBuffer!(char, 128) corrupted;
    const src = buf[];
    foreach (i, c; src)
    {
        if (i == 5)     // somewhere inside the data part
        {
            // Map to a different but valid charset character.
            char next = (c == 'q') ? 'p' : 'q';
            corrupted.put(next);
        }
        else
        {
            char cc = c;
            corrupted.put(cc);
        }
    }

    ubyte[64] out_;
    const(char)[] hrpOut;
    auto r = decodeBech32(corrupted[], hrpOut, out_[]);
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.checksumMismatch);
}

@("crypto.bech32.decodeBech32.mixedCaseRejected")
@safe pure nothrow @nogc
unittest
{
    // A valid lowercase vector with one uppercased character → mixed case.
    ubyte[8] out_;
    const(char)[] hrpOut;
    auto r = decodeBech32("A12uEL5L", hrpOut, out_[]);
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.nonCanonicalEncoding);
}

@("crypto.bech32.decodeBech32.longDataRoundTripsNoLengthLimit")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    // 256 bytes of payload — far past the BIP173 90-char total limit, which
    // age intentionally does not enforce (long PQ recipients). This MUST
    // round-trip without any length error.
    ubyte[256] payload = void;
    foreach (i; 0 .. payload.length)
        payload[i] = cast(ubyte)((i * 7 + 3) & 0xff);

    SmallBuffer!(char, 1024) buf;
    encodeBech32("age", payload[], buf);
    assert(buf[].length > 90);          // well over the BIP173 limit

    ubyte[512] out_;
    const(char)[] hrpOut;
    auto r = decodeBech32(buf[], hrpOut, out_[]);
    assert(r.hasValue);
    assert(hrpOut == "age");
    assert(r.value == payload[]);
}

@("crypto.bech32.decodeBech32.uppercaseEqualsLowercase")
@safe pure nothrow @nogc
unittest
{
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    static immutable ubyte[20] payload = [
        0xde, 0xad, 0xbe, 0xef, 0x00, 0x11, 0x22, 0x33,
        0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb,
        0xcc, 0xdd, 0xee, 0xff,
    ];

    // Encode (lowercase), then build an all-uppercase copy of it.
    SmallBuffer!(char, 128) lower;
    encodeBech32("age", payload[], lower);

    SmallBuffer!(char, 128) upper;
    foreach (c; lower[])
        upper.put(toUpperForTest(c));

    // The uppercase form decodes to the identical bytes.
    ubyte[64] outU;
    const(char)[] hrpU;
    auto ru = decodeBech32(upper[], hrpU, outU[]);
    assert(ru.hasValue);
    assert(ru.value == payload[]);

    // And the lowercase form too — same payload.
    ubyte[64] outL;
    const(char)[] hrpL;
    auto rl = decodeBech32(lower[], hrpL, outL[]);
    assert(rl.hasValue);
    assert(rl.value == payload[]);
    assert(rl.value == ru.value);
}

/// Test-only ASCII uppercaser (the production decoder never uppercases).
private char toUpperForTest(char c) @safe pure nothrow @nogc
    => (c >= 'a' && c <= 'z') ? cast(char)(c - 32) : c;
