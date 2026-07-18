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
import sparkles.test_runner.attributes : benchmark, betterC;

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

    /// Fixed-length: encode `src` into an exactly-sized `dst`. Group
    /// count, tail handling, and padding are all compile-time constants,
    /// and each group's inner loops are unrolled (`static foreach`) —
    /// byte-identical to the streaming overload.
    void encodeBase(size_t N, size_t M)(ref const ubyte[N] src, ref char[M] dst)
    if (M == encodedLen(a, N)) // both lengths deduce; the constraint ties them
    {
        enum string digits = a.digits;
        enum int bpc = bsr(a.radix);
        enum uint msk = a.radix - 1;
        enum size_t cpg = 8 / gcd(8, bpc);      // chars per group
        enum size_t bpg = bpc * cpg / 8;        // bytes per group
        enum size_t fullGroups = N / bpg;
        enum size_t tailBytes = N % bpg;

        foreach (g; 0 .. fullGroups)
        {
            ulong acc = 0;
            static foreach (k; 0 .. bpg)
                acc = (acc << 8) | src[g * bpg + k];
            static foreach (k; 0 .. cpg)
                dst[g * cpg + k] = digits[(acc >> (bpc * (cpg - 1 - k))) & msk];
        }
        static if (tailBytes > 0)
        {
            enum size_t tailChars = (tailBytes * 8 + bpc - 1) / bpc;
            ulong acc = 0;
            static foreach (k; 0 .. tailBytes)
                acc = (acc << 8) | src[fullGroups * bpg + k];
            acc <<= bpc * tailChars - tailBytes * 8; // MSB-align the partial
            static foreach (k; 0 .. tailChars)
                dst[fullGroups * cpg + k] =
                    digits[(acc >> (bpc * (tailChars - 1 - k))) & msk];
            static if (a.padding != '\0')
                static foreach (k; tailChars .. cpg)
                    dst[fullGroups * cpg + k] = a.padding;
        }
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

    /// Fixed-length: decode exactly `encodedLen(a, N)` chars into `dst`.
    /// A thin wrapper over the streaming kernel through a stack sink, so
    /// the rejection behavior (codes and offsets) is identical by
    /// construction; the compile-time win is the exact input/output
    /// sizing (and that failure leaves no partial heap output to manage).
    // Both lengths deduce independently (deducing M as encodedLen(a, N)
    // from the first parameter would reference N before it is known),
    // with the constraint tying them together.
    ParseExpected!void decodeBase(size_t M, size_t N)(
        in char[M] src, ref ubyte[N] dst)
    if (M == encodedLen(a, N))
    {
        static struct FixedSink
        {
            ubyte[] rem;
            void put(ubyte b)
            {
                rem[0] = b;
                rem = rem[1 .. $];
            }
        }

        scope sink = FixedSink(dst[]);
        auto r = .decodeBase!a(sink, src[]);
        if (!r.hasValue)
            return parseErr!void(r.error);
        assert(r.value == N); // structural: the input length is exact
        return parseOk();
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

@("text.base_codecs.fixedLength.knownAnswers")
@safe pure nothrow @nogc
unittest
{
    const ubyte[3] man = ['M', 'a', 'n'];
    char[4] enc = void;
    encodeBase64(man, enc); // the alias resolves the fixed-length overload too
    assert(enc == "TWFu");

    ubyte[3] back = void;
    auto r = decodeBase64("TWFu", back);
    assert(!r.hasError);
    assert(back == man);

    const ubyte[4] deadbeef = [0xDE, 0xAD, 0xBE, 0xEF];
    char[8] hexed = void;
    encodeBase16(deadbeef, hexed);
    assert(hexed == "DEADBEEF");

    const ubyte[1] m = ['M'];
    char[4] padded = void;
    encodeBase64(m, padded);
    assert(padded == "TQ==");
}

@("text.base_codecs.fixedLength.matchesStreaming")
@safe pure nothrow @nogc
unittest
{
    import std.meta : AliasSeq;
    import sparkles.base.smallbuffer : SmallBuffer;

    static void check(Alphabet a, size_t N)()
    {
        uint x = cast(uint)(N * 2654435761u + 1);
        ubyte[N] src = void;
        foreach (ref b; src)
        {
            x = x * 1664525 + 1013904223;
            b = cast(ubyte)(x >> 24);
        }

        char[encodedLen(a, N)] dst = void;
        encodeBase!a(src, dst);

        SmallBuffer!(char, 128) reference;
        encodeBase!a(reference, src[]);
        assert(dst[] == reference[]); // byte-identical to streaming

        ubyte[N] back = void;
        auto r = decodeBase!a(dst, back);
        assert(!r.hasError);
        assert(back == src);
    }

    static foreach (a; AliasSeq!(base16, base32, base32hex, base64, base64url, zbase32))
        static foreach (N; AliasSeq!(1, 2, 3, 4, 5, 6, 7, 8, 16, 20, 31, 32, 33, 64))
            check!(a, N)();
}

@("text.base_codecs.fixedLength.rejectsLikeStreaming")
@safe pure nothrow @nogc
unittest
{
    // The fixed-length decoder is the streaming kernel behind an exact-size
    // sink, so codes and offsets match by construction — spot-check anyway.
    ubyte[1] one = void;
    auto r = decodeBase64("TR==", one);
    assert(r.hasError);
    assert(r.error.code == ParseErrorCode.nonCanonicalTrailing);
    assert(r.error.offset == 4);

    auto s = decodeBase64("T$==", one);
    assert(s.hasError);
    assert(s.error.code == ParseErrorCode.unexpectedCharacter);
    assert(s.error.offset == 1);

    ubyte[4] four = void;
    auto h = decodeBase16("DEADBEEZ", four);
    assert(h.hasError);
    assert(h.error.code == ParseErrorCode.unexpectedCharacter);
    assert(h.error.offset == 7);
}

@("text.base_codecs.writeHexByte.anchor")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.base.text.writers : writeHexByte;

    // writeHexByte is definitionally the one-byte fixed-length encode over
    // a lower-case base16 alphabet — anchor the codec kernel to it.
    enum Alphabet base16lower = Alphabet(digits: "0123456789abcdef");
    foreach (b; 0 .. 256)
    {
        const ubyte[1] src = [cast(ubyte) b];
        char[2] viaCodec = void;
        encodeBase!base16lower(src, viaCodec);

        SmallBuffer!(char, 4) viaWriter;
        writeHexByte(viaWriter, cast(ubyte) b);
        assert(viaWriter[] == viaCodec[]);
    }
}

/**
A column-counting decorator writer: forwards characters to the wrapped
writer, inserting `newline` before every character that would start column
`width + 1` — i.e. lines are at most `width` characters, with no trailing
newline after the last one (append one yourself if the framing requires
it). The codec kernels stay free of framing logic; wrap MIME (76-column
CRLF) or PEM (64-column LF) output by encoding through this.

Note: this wraps codec output — pure single-column ASCII. For wrapping
prose by terminal cell width, see `sparkles.base.text.wrap`.
*/
struct LineWrapWriter(Writer)
{
    private Writer* inner;
    private size_t width;
    private const(char)[] newline;
    private size_t column;

    /// Output-range primitive.
    void put(char c)
    {
        import std.range.primitives : basePut = put;

        if (column == width)
        {
            basePut(*inner, newline);
            column = 0;
        }
        basePut(*inner, c);
        column++;
    }
}

/// Wraps `w` at `width` columns with `newline` (default `"\n"`; MIME
/// base64 uses `"\r\n"` at 76): `encodeBase64(lineWrapWriter(w, 76, "\r\n"), data)`.
auto lineWrapWriter(Writer)(
    return ref Writer w, size_t width, const(char)[] newline = "\n")
    => LineWrapWriter!Writer(&w, width, newline);

@("text.base_codecs.lineWrap.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import std.string : representation;

    SmallBuffer!(char, 128) buf;
    auto lw = lineWrapWriter(buf, 4);
    encodeBase64(lw, "foobarbaz".representation);
    assert(buf[] == "Zm9v\nYmFy\nYmF6"); // no trailing newline

    // A width no line exceeds leaves the output untouched.
    SmallBuffer!(char, 128) wide;
    auto lww = lineWrapWriter(wide, 80);
    encodeBase64(lww, "foobarbaz".representation);
    assert(wide[] == "Zm9vYmFyYmF6");
}

@("text.base_codecs.lineWrap.mime76")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    // 60 zero bytes encode to 80 'A's; MIME wraps at 76 with CRLF.
    ubyte[60] data = 0;
    SmallBuffer!(char, 128) buf;
    auto lw = lineWrapWriter(buf, 76, "\r\n");
    encodeBase64(lw, data[]);

    assert(buf[].length == 82);
    foreach (c; buf[][0 .. 76])
        assert(c == 'A');
    assert(buf[][76 .. 78] == "\r\n");
    assert(buf[][78 .. $] == "AAAA");
}

// ─────────────────────────────────────────────────────────────────────────────
// Benchmarks (`dub test :base -b bench -- --bench --group-by=preset,op,size`)
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private struct CharSink
    {
        char[] buf;
        size_t n;
        void put(char c) @safe { buf[n++] = c; }
    }

    private struct ByteSink
    {
        ubyte[] buf;
        size_t n;
        void put(ubyte b) @safe { buf[n++] = b; }
    }

    /// Per-cell bench state on the GC heap. The timed/after callbacks are
    /// member delegates (context = this instance), NOT frame closures:
    /// `base` source-includes the runner impl, so under this package's
    /// -preview=dip1000 the harness's delegate parameters scope-infer and a
    /// frame closure passed to benchCase is stack-allocated — dangling by
    /// the time the deferred measurement runs (stack-use-after-return).
    private final class StreamingBenchCase(Alphabet a)
    {
        ubyte[] data;
        char[] encoded;
        ubyte[] decoded;

        this(size_t size) @safe
        {
            data = new ubyte[](size);
            uint x = 0x9E3779B9 ^ cast(uint) size;
            foreach (ref b; data)
            {
                x = x * 1664525 + 1013904223;
                b = cast(ubyte)(x >> 24);
            }
            encoded = new char[](encodedLen(a, size));
            decoded = new ubyte[](size);
            auto w = CharSink(encoded);
            encodeBase!a(w, data); // seed `encoded` for the decode case
        }

        size_t timedEncode() @safe
        {
            auto w = CharSink(encoded);
            encodeBase!a(w, data);
            return w.n;
        }

        void afterEncode(ref size_t n) @safe
        {
            if (n != encoded.length)
                throw new Exception("encoded length mismatch");
        }

        // The timed result must be default-constructible for the harness,
        // which ParseExpected deliberately is not — collapse it to the
        // byte count (size_t.max signals an error).
        size_t timedDecode() @safe
        {
            auto w = ByteSink(decoded);
            auto r = decodeBase!a(w, encoded);
            return r.hasError ? size_t.max : r.value;
        }

        void afterDecode(ref size_t n) @safe
        {
            if (n != decoded.length)
                throw new Exception("decode mismatch");
        }
    }

    /// Registers the streaming encode + decode rows for one
    /// (alphabet, size) cell.
    private void registerStreamingBench(Alphabet a)(
        string preset, string sizeLabel, size_t size) @safe
    {
        import sparkles.test_runner.bench : benchCase, Metric, Unit;

        auto c = new StreamingBenchCase!a(size);
        benchCase(
            name: "scalar",
            labels: ["preset": preset, "op": "encode", "size": sizeLabel],
            timed: &c.timedEncode,
            after: &c.afterEncode,
            metrics: [Metric(Unit("B"), size, Metric.Mode.rate)]);
        benchCase(
            name: "scalar",
            labels: ["preset": preset, "op": "decode", "size": sizeLabel],
            timed: &c.timedDecode,
            after: &c.afterDecode,
            metrics: [Metric(Unit("B"), size, Metric.Mode.rate)]);
    }
}

@("text.base_codecs.bench.streaming")
@benchmark @safe
unittest
{
    registerStreamingBench!base16("base16", "1KiB", 1 << 10);
    registerStreamingBench!base16("base16", "64KiB", 1 << 16);
    registerStreamingBench!base32("base32", "1KiB", 1 << 10);
    registerStreamingBench!base32("base32", "64KiB", 1 << 16);
    registerStreamingBench!base64("base64", "1KiB", 1 << 10);
    registerStreamingBench!base64("base64", "64KiB", 1 << 16);
}

/// The fixed-length encoders are tens of nanoseconds — measure them with
/// `benchIter` (batched timing), not per-call `benchCase` rows.
@("text.base_codecs.bench.fixed32")
@benchmark @safe
unittest
{
    import std.meta : AliasSeq;
    import sparkles.test_runner.bench : benchIter, blackBox;

    ubyte[32] src = void;
    uint x = 0xDEADBEEF;
    foreach (ref b; src)
    {
        x = x * 1664525 + 1013904223;
        b = cast(ubyte)(x >> 24);
    }

    static foreach (i, a; AliasSeq!(base16, base32, base64))
    {{
        enum names = ["base16", "base32", "base64"];
        char[encodedLen(a, 32)] dst = void;
        benchIter({
            encodeBase!a(blackBox(src), dst);
            blackBox(dst);
        }, ["preset": names[i], "op": "encode", "size": "32B-fixed"]);
    }}
}
