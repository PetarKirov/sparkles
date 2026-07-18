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
