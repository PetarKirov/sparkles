/**
Alphabet-driven binary-to-text codecs for the power-of-two "base" family
(RFC 4648 Base16/Base32/Base32hex/Base64/Base64url and alphabet-compatible
relatives), plus the digit-vocabulary machinery shared with the scalar
numeral conversions in `sparkles.base.text.readers` / `.writers`.

Every per-base behavior — bits per character, group size, padding length,
decode tables — derives at compile time from an $(LREF Alphabet) value;
nothing is hardcoded per base.
*/
module sparkles.base.text.base_codecs;

import core.bitop : bsr;
import std.math.traits : isPowerOf2;
import std.numeric : gcd;

import sparkles.base.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

// Unconditional import (phobos-style, cf. std.internal.attributes): unittest
// UDAs are resolved even in builds where the unittest bodies are not compiled.
import sparkles.test_runner.attributes : betterC;

/**
A positional digit vocabulary: `digits[i]` is the character for symbol
value `i`, so `digits.length` is the radix.

One `Alphabet` value drives both layers built on it: the whole-integer
numeral conversions (`readInteger`/`writeInteger`, any radix 2–36 sliced
from $(LREF alnum)) and the bit-regrouping codecs ($(LREF encodeBase) /
$(LREF decodeBase), power-of-two radix only).
*/
struct Alphabet
{
    /// index == symbol value; `radix == digits.length`
    string digits;
    /// decode accepts either letter case
    bool caseInsensitive = false;
    /// decode-only (aliasChar, canonicalDigit) pairs, e.g. Crockford `"O0I1L1"`
    string aliases = "";
    /// `'\0'` == none; e.g. `'='` for RFC base32/base64
    char padding = '\0';

    /// The number of symbols in the vocabulary.
    ubyte radix() const @safe pure nothrow @nogc => cast(ubyte) digits.length;
}

/// The full lower-case alphanumeric vocabulary. Sliced to `[0 .. radix]` it
/// is the single source of digits for every scalar radix 2–36
/// (`readInteger` / `writeInteger`); whole, it is base36.
enum Alphabet alnum = Alphabet(
    digits: "0123456789abcdefghijklmnopqrstuvwxyz", caseInsensitive: true);

/// RFC 4648 §8 Base16 (upper-case; decode accepts either case).
enum Alphabet base16 = Alphabet(digits: "0123456789ABCDEF", caseInsensitive: true);

/// RFC 4648 §6 Base32.
enum Alphabet base32 = Alphabet(
    digits: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567", padding: '=');

/// RFC 4648 §7 Base32 with extended hex alphabet (sorts like the bytes).
enum Alphabet base32hex = Alphabet(
    digits: "0123456789ABCDEFGHIJKLMNOPQRSTUV", padding: '=');

/// RFC 4648 §4 Base64.
enum Alphabet base64 = Alphabet(
    digits: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
    padding: '=');

/// RFC 4648 §5 URL- and filename-safe Base64.
enum Alphabet base64url = Alphabet(
    digits: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
    padding: '=');

/// z-base-32 (human-oriented base32; no padding).
enum Alphabet zbase32 = Alphabet(digits: "ybndrfg8ejkmcpqxot1uwisza345h769");

/**
Builds the 256-entry reverse table for `a`: `table[c]` is the symbol value
of character `c`, or `-1` for characters outside the vocabulary. Case
folding (`a.caseInsensitive`) and decode-only alias pairs (`a.aliases`)
are baked in. Evaluated at compile time by the codec layer
(`static immutable table = makeDecodeTable(a)`).
*/
// NB: `const Alphabet` by value, not `in` — with `-preview=in` the by-ref
// passing of an enum Alphabet argument segfaults the CTFE interpreter
// (LDC 1.41 / DMD 2.111 front end).
byte[256] makeDecodeTable(const Alphabet a) @safe pure nothrow @nogc
{
    byte[256] t = -1;
    foreach (i, char c; a.digits)
        t[cast(ubyte) c] = cast(byte) i;
    if (a.caseInsensitive)
        foreach (i, char c; a.digits)
        {
            if (c >= 'A' && c <= 'Z')
                t[cast(ubyte)(c + 32)] = cast(byte) i;
            else if (c >= 'a' && c <= 'z')
                t[cast(ubyte)(c - 32)] = cast(byte) i;
        }
    for (size_t i = 0; i + 1 < a.aliases.length; i += 2)
    {
        immutable ubyte from = cast(ubyte) a.aliases[i];
        immutable byte canon = t[cast(ubyte) a.aliases[i + 1]];
        t[from] = canon;
        if (a.caseInsensitive)
        {
            if (from >= 'A' && from <= 'Z')
                t[from + 32] = canon;
            else if (from >= 'a' && from <= 'z')
                t[from - 32] = canon;
        }
    }
    return t;
}

/**
The encoded length of `n` input bytes under alphabet `a` (power-of-two
radix): `ceil(n*8 / bitsPerChar)` characters, rounded up to a whole group
when the alphabet pads. CTFE-able — the fixed-length overloads size their
output buffers with it.
*/
size_t encodedLen(const Alphabet a, size_t n) @safe pure nothrow @nogc
in (isPowerOf2(a.radix))
{
    immutable bpc = bsr(a.radix);
    immutable raw = (n * 8 + bpc - 1) / bpc;
    immutable cpg = 8 / gcd(8, bpc);
    return a.padding != '\0' ? (raw + cpg - 1) / cpg * cpg : raw;
}

/**
Encodes bytes as text under alphabet `a` (power-of-two radix only): an
MSB-first bit accumulator emits `log2(a.radix)` bits per character, plus
final-group padding when the alphabet pads. The streaming overload writes
`encodedLen(a, data.length)` chars to any `char` output range; use the
per-preset aliases ($(LREF encodeBase64), $(LREF encodeBase32), …) for the
common alphabets.

The eponymous-template shape lets a partial instantiation be aliased
(`alias encodeBase64 = encodeBase!base64;`) while keeping one overload set
for the streaming and fixed-length forms.
*/
template encodeBase(Alphabet a)
if (isPowerOf2(a.radix))
{
    /// Streaming: encode `data` into the output range `w`.
    void encodeBase(Writer)(ref Writer w, scope const(ubyte)[] data)
    {
        import std.range.primitives : put;

        enum string digits = a.digits;
        enum int bpc = bsr(a.radix);
        enum uint msk = a.radix - 1;
        enum size_t cpg = 8 / gcd(8, bpc);

        uint buf = 0;
        int nbits = 0;
        size_t n = 0;
        foreach (ubyte b; data)
        {
            buf = (buf << 8) | b;
            nbits += 8;
            while (nbits >= bpc)
            {
                nbits -= bpc;
                put(w, digits[(buf >> nbits) & msk]);
                n++;
            }
            buf &= (1u << nbits) - 1;
        }
        if (nbits > 0) // MSB-aligned partial character
        {
            put(w, digits[(buf << (bpc - nbits)) & msk]);
            n++;
        }
        static if (a.padding != '\0')
            foreach (_; 0 .. (cpg - n % cpg) % cpg)
                put(w, a.padding);
    }
}

/**
Decodes text produced by $(LREF encodeBase) under the same alphabet,
writing the bytes to a `ubyte` output range and returning the number of
bytes written.

The decoder is strict per RFC 4648 §3.5 (all three checks on by default):

$(NUMBERED_LIST
    $(LIST_ITEM a final group whose length can hold no complete byte is a
        `unexpectedEnd` error ("truncated group");)
    $(LIST_ITEM unused trailing bits must be zero — `nonCanonicalTrailing`
        otherwise;)
    $(LIST_ITEM for padding alphabets, the padding character count must
        complete the final group exactly — `paddingMismatch` otherwise.)
)

A character outside the alphabet is `unexpectedCharacter` at its offset; a
data character after padding started is `unexpectedCharacter` with context
`"data after padding"`. The end-of-input checks report `text.length` as
their offset.

Note (deviation from the `readers.d` cursor convention): the input is taken
by value, not as an advancing cursor — a codec payload is a whole value,
not a token in a larger grammar — and on failure `w` may already hold a
partial prefix of the output (a streaming decoder cannot un-write). Callers
needing all-or-nothing semantics use the fixed-length overload or a
throwaway buffer.
*/
template decodeBase(Alphabet a)
if (isPowerOf2(a.radix))
{
    private static immutable byte[256] table = makeDecodeTable(a);

    /// Streaming: decode `text` into the `ubyte` output range `w`.
    ParseExpected!size_t decodeBase(Writer)(ref Writer w, scope const(char)[] text)
    {
        import std.range.primitives : put;

        enum int bpc = bsr(a.radix);
        enum size_t cpg = 8 / gcd(8, bpc);

        uint buf = 0;
        int nbits = 0;
        size_t sc = 0, padCount = 0, written = 0;
        bool sawPad = false;
        foreach (i, char c; text)
        {
            static if (a.padding != '\0')
                if (c == a.padding)
                {
                    sawPad = true;
                    padCount++;
                    continue;
                }
            if (sawPad)
                return parseErr!size_t(
                    ParseErrorCode.unexpectedCharacter, i, "data after padding");
            immutable v = table[c];
            if (v < 0)
                return parseErr!size_t(ParseErrorCode.unexpectedCharacter, i);
            buf = (buf << bpc) | cast(uint) v;
            nbits += bpc;
            sc++;
            while (nbits >= 8)
            {
                nbits -= 8;
                put(w, cast(ubyte)((buf >> nbits) & 0xFF));
                written++;
            }
            buf &= (1u << nbits) - 1;
        }
        immutable r = sc % cpg;
        if (r != 0 && (r * bpc) % 8 >= bpc)                     // check (1)
            return parseErr!size_t(ParseErrorCode.unexpectedEnd, text.length);
        if (buf != 0)                                           // check (2)
            return parseErr!size_t(
                ParseErrorCode.nonCanonicalTrailing, text.length);
        static if (a.padding != '\0')
            if (padCount != (cpg - r) % cpg)                    // check (3)
                return parseErr!size_t(
                    ParseErrorCode.paddingMismatch, text.length);
        return parseOk(written);
    }
}

/// RFC 4648 Base16 (hex, upper-case) — see $(LREF encodeBase) / $(LREF decodeBase).
alias encodeBase16 = encodeBase!base16;
/// ditto
alias decodeBase16 = decodeBase!base16;
/// RFC 4648 Base32 — see $(LREF encodeBase) / $(LREF decodeBase).
alias encodeBase32 = encodeBase!base32;
/// ditto
alias decodeBase32 = decodeBase!base32;
/// RFC 4648 Base32hex — see $(LREF encodeBase) / $(LREF decodeBase).
alias encodeBase32Hex = encodeBase!base32hex;
/// ditto
alias decodeBase32Hex = decodeBase!base32hex;
/// RFC 4648 Base64 — see $(LREF encodeBase) / $(LREF decodeBase).
alias encodeBase64 = encodeBase!base64;
/// ditto
alias decodeBase64 = decodeBase!base64;
/// RFC 4648 URL-safe Base64 — see $(LREF encodeBase) / $(LREF decodeBase).
alias encodeBase64Url = encodeBase!base64url;
/// ditto
alias decodeBase64Url = decodeBase!base64url;
/// z-base-32 — see $(LREF encodeBase) / $(LREF decodeBase).
alias encodeZBase32 = encodeBase!zbase32;
/// ditto
alias decodeZBase32 = decodeBase!zbase32;

@("text.base_codecs.Alphabet.radix")
@betterC
unittest
{
    static assert(alnum.radix == 36);
    static assert(base16.radix == 16);
    static assert(base32.radix == 32);
    static assert(base32hex.radix == 32);
    static assert(base64.radix == 64);
    static assert(base64url.radix == 64);
    static assert(zbase32.radix == 32);
}

@("text.base_codecs.makeDecodeTable.basic")
@betterC
unittest
{
    static immutable t = makeDecodeTable(base64);
    assert(t['A'] == 0);
    assert(t['Z'] == 25);
    assert(t['a'] == 26);
    assert(t['z'] == 51);
    assert(t['0'] == 52);
    assert(t['9'] == 61);
    assert(t['+'] == 62);
    assert(t['/'] == 63);
    assert(t['-'] == -1);
    assert(t['='] == -1); // padding is handled structurally, not via the table
}

@("text.base_codecs.makeDecodeTable.caseInsensitive")
@betterC
unittest
{
    static immutable t = makeDecodeTable(base16);
    assert(t['A'] == 10 && t['a'] == 10);
    assert(t['F'] == 15 && t['f'] == 15);
    assert(t['0'] == 0 && t['9'] == 9);
    assert(t['g'] == -1 && t['G'] == -1);

    static immutable u = makeDecodeTable(alnum);
    assert(u['z'] == 35 && u['Z'] == 35);
    assert(u['/'] == -1);
}

@("text.base_codecs.makeDecodeTable.aliases")
@betterC
unittest
{
    // Crockford-style decode aliases: O→0, I→1, L→1 (with case folding).
    enum Alphabet crockfordish = Alphabet(
        digits: "0123456789abcdefghjkmnpqrstvwxyz",
        caseInsensitive: true,
        aliases: "O0I1L1");
    static immutable t = makeDecodeTable(crockfordish);
    assert(t['O'] == 0 && t['o'] == 0);
    assert(t['I'] == 1 && t['i'] == 1);
    assert(t['L'] == 1 && t['l'] == 1);
    assert(t['u'] == -1);
}

@("text.base_codecs.encodedLen")
@betterC
unittest
{
    // Padded alphabets round up to whole groups; unpadded emit raw chars.
    static assert(encodedLen(base16, 4) == 8);
    static assert(encodedLen(base64, 1) == 4);
    static assert(encodedLen(base64, 2) == 4);
    static assert(encodedLen(base64, 3) == 4);
    static assert(encodedLen(base32, 1) == 8);
    static assert(encodedLen(base32, 5) == 8);
    static assert(encodedLen(base32, 6) == 16);
    static assert(encodedLen(zbase32, 1) == 2);
    static assert(encodedLen(zbase32, 5) == 8);
    foreach (a; [base16, base32, base32hex, base64, base64url, zbase32])
        assert(encodedLen(a, 0) == 0);
}

@("text.base_codecs.encode.rfc4648")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;
    import std.string : representation;

    // RFC 4648 §10 test vectors, exercised through the named aliases.
    checkWriter!((ref b) => encodeBase64(b, "".representation))("");
    checkWriter!((ref b) => encodeBase64(b, "f".representation))("Zg==");
    checkWriter!((ref b) => encodeBase64(b, "fo".representation))("Zm8=");
    checkWriter!((ref b) => encodeBase64(b, "foo".representation))("Zm9v");
    checkWriter!((ref b) => encodeBase64(b, "foob".representation))("Zm9vYg==");
    checkWriter!((ref b) => encodeBase64(b, "fooba".representation))("Zm9vYmE=");
    checkWriter!((ref b) => encodeBase64(b, "foobar".representation))("Zm9vYmFy");

    checkWriter!((ref b) => encodeBase32(b, "".representation))("");
    checkWriter!((ref b) => encodeBase32(b, "f".representation))("MY======");
    checkWriter!((ref b) => encodeBase32(b, "fo".representation))("MZXQ====");
    checkWriter!((ref b) => encodeBase32(b, "foo".representation))("MZXW6===");
    checkWriter!((ref b) => encodeBase32(b, "foob".representation))("MZXW6YQ=");
    checkWriter!((ref b) => encodeBase32(b, "fooba".representation))("MZXW6YTB");
    checkWriter!((ref b) => encodeBase32(b, "foobar".representation))("MZXW6YTBOI======");

    checkWriter!((ref b) => encodeBase32Hex(b, "".representation))("");
    checkWriter!((ref b) => encodeBase32Hex(b, "f".representation))("CO======");
    checkWriter!((ref b) => encodeBase32Hex(b, "fo".representation))("CPNG====");
    checkWriter!((ref b) => encodeBase32Hex(b, "foo".representation))("CPNMU===");
    checkWriter!((ref b) => encodeBase32Hex(b, "foob".representation))("CPNMUOG=");
    checkWriter!((ref b) => encodeBase32Hex(b, "fooba".representation))("CPNMUOJ1");
    checkWriter!((ref b) => encodeBase32Hex(b, "foobar".representation))("CPNMUOJ1E8======");

    checkWriter!((ref b) => encodeBase16(b, "".representation))("");
    checkWriter!((ref b) => encodeBase16(b, "f".representation))("66");
    checkWriter!((ref b) => encodeBase16(b, "fo".representation))("666F");
    checkWriter!((ref b) => encodeBase16(b, "foo".representation))("666F6F");
    checkWriter!((ref b) => encodeBase16(b, "foob".representation))("666F6F62");
    checkWriter!((ref b) => encodeBase16(b, "fooba".representation))("666F6F6261");
    checkWriter!((ref b) => encodeBase16(b, "foobar".representation))("666F6F626172");
}

@("text.base_codecs.encode.knownAnswers")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;
    import std.string : representation;

    checkWriter!((ref b) => encodeBase64(b, "M".representation))("TQ==");
    checkWriter!((ref b) => encodeBase64(b, "Ma".representation))("TWE=");
    checkWriter!((ref b) => encodeBase64(b, "Man".representation))("TWFu");
    checkWriter!((ref b) => encodeBase64Url(b, [0xFB, 0xEF, 0xFE]))("--_-");

    static immutable ubyte[4] deadbeef = [0xDE, 0xAD, 0xBE, 0xEF];
    checkWriter!((ref b) => encodeBase16(b, deadbeef))("DEADBEEF");

    // z-base-32 spec example (0xF0BFC7), and its unpadded partial group.
    static immutable ubyte[3] zb = [0xF0, 0xBF, 0xC7];
    checkWriter!((ref b) => encodeZBase32(b, zb))("6n9hq");

    // Anonymous Alphabet literals bind as template arguments too.
    static immutable ubyte[1] one = [0xA5];
    checkWriter!((ref b) => encodeBase!(Alphabet(digits: "01"))(b, one))("10100101");
}

@("text.base_codecs.decode.rfc4648")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import std.string : representation;

    static void checkDecode(alias dec)(
        scope const(char)[] text, scope const(ubyte)[] expected)
    {
        SmallBuffer!(ubyte, 64) buf;
        auto r = dec(buf, text);
        assert(r.hasValue);
        assert(r.value == expected.length);
        assert(buf[] == expected);
    }

    checkDecode!decodeBase64("", "".representation);
    checkDecode!decodeBase64("Zg==", "f".representation);
    checkDecode!decodeBase64("Zm8=", "fo".representation);
    checkDecode!decodeBase64("Zm9v", "foo".representation);
    checkDecode!decodeBase64("Zm9vYmFy", "foobar".representation);

    checkDecode!decodeBase32("MY======", "f".representation);
    checkDecode!decodeBase32("MZXW6YTBOI======", "foobar".representation);
    checkDecode!decodeBase32Hex("CPNMUOJ1E8======", "foobar".representation);

    checkDecode!decodeBase16("666F6F626172", "foobar".representation);
    checkDecode!decodeBase16("666f6f626172", "foobar".representation); // either case

    static immutable ubyte[3] zb = [0xF0, 0xBF, 0xC7];
    checkDecode!decodeZBase32("6n9hq", zb);
}

@("text.base_codecs.roundTrip")
@safe pure nothrow @nogc
unittest
{
    import std.meta : AliasSeq;
    import sparkles.base.smallbuffer : SmallBuffer;

    static void roundTrip(Alphabet a)()
    {
        // Deterministic inline LCG — std.random would break pure nothrow @nogc.
        uint x = 0x9E3779B9;
        ubyte[64] data = void;
        foreach (n; 0 .. data.length + 1)
        {
            foreach (j; 0 .. n)
            {
                x = x * 1664525 + 1013904223;
                data[j] = cast(ubyte)(x >> 24);
            }

            SmallBuffer!(char, 256) enc;
            encodeBase!a(enc, data[0 .. n]);
            assert(enc[].length == encodedLen(a, n));

            SmallBuffer!(ubyte, 128) dec;
            auto r = decodeBase!a(dec, enc[]);
            assert(r.hasValue);
            assert(r.value == n);
            assert(dec[] == data[0 .. n]);
        }
    }

    static foreach (a; AliasSeq!(base16, base32, base32hex, base64, base64url, zbase32))
        roundTrip!a();
}

@("text.base_codecs.decode.rejectsInvalidSymbol")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(ubyte, 16) buf;
    auto r = decodeBase64(buf, "Zm9$");
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.unexpectedCharacter);
    assert(r.error.offset == 3);

    // The RFC base64 alphabet is case-sensitive and rejects '-'.
    buf.clear();
    auto u = decodeBase64(buf, "----");
    assert(!u.hasValue);
    assert(u.error.code == ParseErrorCode.unexpectedCharacter);
    assert(u.error.offset == 0);
}

@("text.base_codecs.decode.rejectsDataAfterPadding")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(ubyte, 16) buf;
    auto r = decodeBase64(buf, "TQ==TWFu");
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.unexpectedCharacter);
    assert(r.error.offset == 4);
    assert(r.error.context == "data after padding");
}

@("text.base_codecs.decode.rejectsTruncatedGroup")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // A single base64 char holds 6 bits — no complete byte: check (1).
    SmallBuffer!(ubyte, 16) buf;
    auto r = decodeBase64(buf, "Z");
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.unexpectedEnd);
    assert(r.error.offset == 1);

    // Same for a lone base32 char (5 bits).
    buf.clear();
    auto u = decodeBase32(buf, "M");
    assert(!u.hasValue);
    assert(u.error.code == ParseErrorCode.unexpectedEnd);

    // base16 has no truncatable final length (every char pair is a byte),
    // but an odd count is: "DEA" + "D" round-trips, "DEA" does not.
    buf.clear();
    auto h = decodeBase16(buf, "DEA");
    assert(!h.hasValue);
    assert(h.error.code == ParseErrorCode.unexpectedEnd);
}

@("text.base_codecs.decode.rejectsNonCanonicalTrailingBits")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // "TQ==" is canonical; "TR==" leaves non-zero unused bits: check (2).
    SmallBuffer!(ubyte, 16) buf;
    auto r = decodeBase64(buf, "TR==");
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.nonCanonicalTrailing);
    assert(r.error.offset == 4);

    // Unpadded alphabets hit the same check directly.
    buf.clear();
    auto z = decodeZBase32(buf, "yn"); // 'n' = 2 → a trailing bit set
    assert(!z.hasValue);
    assert(z.error.code == ParseErrorCode.nonCanonicalTrailing);
}

@("text.base_codecs.decode.rejectsBadPaddingCount")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(ubyte, 16) buf;
    auto r = decodeBase64(buf, "TQ="); // needs two pads
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.paddingMismatch);
    assert(r.error.offset == 3);

    buf.clear();
    auto u = decodeBase64(buf, "TQ"); // needs two pads, has none
    assert(!u.hasValue);
    assert(u.error.code == ParseErrorCode.paddingMismatch);

    buf.clear();
    auto v = decodeBase64(buf, "TWFu="); // complete group + stray pad
    assert(!v.hasValue);
    assert(v.error.code == ParseErrorCode.paddingMismatch);
}
