/**
Scan seams of the native JSON reader — the free functions a SIMD
iteration replaces without touching the grammar loop (SPEC §11; the six
vectorizable seams are catalogued in the parsing research). Scalar-only
bodies here; signatures are the contract.
*/
module sparkles.wired.json.scan;

/// One unaligned 64-bit load — the memcpy idiom guarantees a single mov
/// with no alignment assumption.
package ulong loadWord(const(char)* p) @system pure nothrow @nogc
{
    pragma(inline, true);
    import core.stdc.string : memcpy;

    ulong x;
    memcpy(&x, p, 8);
    return x;
}

@safe pure nothrow @nogc package:

/// Advances `i` past insignificant whitespace (RFC 8259: space, tab,
/// LF, CR) in the reader's padded pool. The four zero bytes of padding
/// terminate the walk (NUL is not whitespace), so the hot loop carries
/// no bounds check.
void skipWs(scope const(char)[] paddedPool, ref size_t i)
in (paddedPool.length >= 8 && paddedPool[$ - 1] == '\0')
{
    pragma(inline, true);
    i = (() @trusted {
        auto p = paddedPool.ptr;
        size_t j = i;
        while (p[j] == ' ' || p[j] == '\t' || p[j] == '\n' || p[j] == '\r')
        {
            j++;
            // Pretty-printed runs: skip 8 spaces at a time (padding keeps
            // the word loads in bounds; NUL is not a space, so the walk
            // terminates).
            while (loadWord(p + j) == 0x2020_2020_2020_2020)
                j += 8;
        }
        return j;
    })();
}

/// The result of a string-body scan: the index of the first structural
/// stop byte (quote, backslash, or control), or — when `invalidUtf8` is
/// set — the first byte of an ill-formed UTF-8 sequence.
struct StringScan
{
    size_t stop;
    bool invalidUtf8;
}

// ── UTF-8 sequence shapes (Unicode Table 3-7) ────────────────────────────
// Each predicate tests one candidate sequence in a single 4-byte window:
// a masked compare for the lead/continuation pattern, then the constraint
// bits that exclude overlongs, surrogates, and code points above U+10FFFF.
// Constants are little-endian byte views (byte 0 in the low 8 bits), so a
// truncated sequence reads the following bytes — a quote, or the pool's
// zero padding — which fail the continuation mask and correctly report the
// sequence as ill-formed. This is yyjson's formulation; it validates
// during the scan instead of re-walking the string afterwards.

/// True when the window starts with an ASCII byte.
bool isUtf8Seq1(uint w)
{
    pragma(inline, true);
    return (w & 0x0000_0080) == 0;
}

/// True when the window starts with a well-formed 2-byte sequence
/// (U+0080–U+07FF; the `0x1E` bits reject the overlong `C0`/`C1` leads).
bool isUtf8Seq2(uint w)
{
    pragma(inline, true);
    return (w & 0x0000_C0E0) == 0x0000_80C0 && (w & 0x0000_001E) != 0;
}

/// True when the window starts with a well-formed 3-byte sequence
/// (U+0800–U+FFFF): the constraint bits must be non-zero (no `E0 80..9F`
/// overlong) and must not spell the surrogate window (`ED A0..BF`).
bool isUtf8Seq3(uint w)
{
    pragma(inline, true);
    if ((w & 0x00C0_C0F0) != 0x0080_80E0)
        return false;
    const t = w & 0x0000_200F;
    return t != 0 && t != 0x0000_200D;
}

/// True when the window starts with a well-formed 4-byte sequence
/// (U+10000–U+10FFFF): non-zero constraint bits reject the `F0 80..8F`
/// overlongs, and the two-way test rejects everything above U+10FFFF
/// (`F4 90..BF` and the never-valid `F5`–`F7` leads).
bool isUtf8Seq4(uint w)
{
    pragma(inline, true);
    if ((w & 0xC0C0_C0F8) != 0x8080_80F0)
        return false;
    const t = w & 0x0000_3007;
    return t != 0 && ((t & 0x0000_0004) == 0 || (t & 0x0000_3003) == 0);
}

@("scan.utf8Seq.tableThreeSeven")
@safe pure nothrow @nogc
unittest
{
    static uint win(in char[4] s)
    {
        uint w = 0;
        foreach_reverse (c; s)
            w = w << 8 | cast(ubyte) c;
        return w;
    }

    assert(isUtf8Seq1(win("a\0\0\0")) && !isUtf8Seq1(win("\xC3\xA9\0\0")));
    // 2-byte: é, and the two never-valid overlong leads.
    assert(isUtf8Seq2(win("\xC3\xA9\0\0")));
    assert(!isUtf8Seq2(win("\xC0\x80\0\0")) && !isUtf8Seq2(win("\xC1\xBF\0\0")));
    assert(!isUtf8Seq2(win("\xC3\x28\0\0"))); // bad continuation
    // 3-byte: あ and €, rejecting the overlong and surrogate windows.
    assert(isUtf8Seq3(win("\xE3\x81\x82\0")) && isUtf8Seq3(win("\xE2\x82\xAC\0")));
    assert(!isUtf8Seq3(win("\xE0\x80\xAF\0"))); // overlong
    assert(!isUtf8Seq3(win("\xED\xA0\x80\0"))); // U+D800 surrogate
    assert(isUtf8Seq3(win("\xED\x9F\xBF\0"))); // U+D7FF, just below
    assert(!isUtf8Seq3(win("\xE3\x81\x22"))); // truncated by a quote
    // 4-byte: U+10000 and U+10FFFF, rejecting overlong and out-of-range.
    assert(isUtf8Seq4(win("\xF0\x90\x80\x80")) && isUtf8Seq4(win("\xF4\x8F\xBF\xBF")));
    assert(!isUtf8Seq4(win("\xF0\x8F\xBF\xBF"))); // overlong
    assert(!isUtf8Seq4(win("\xF4\x90\x80\x80"))); // above U+10FFFF
    assert(!isUtf8Seq4(win("\xF5\x80\x80\x80"))); // never-valid lead
}

/// True when all eight bytes of `w` are ASCII digits (`'0'..'9'`) — the
/// gate for $(LREF eightDigits). Two masked compares: every high nibble
/// must be 3, and adding 6 to a low nibble may not carry out of it.
bool allDigits8(ulong w)
{
    pragma(inline, true);
    enum ulong hi = 0xF0F0_F0F0_F0F0_F0F0;
    return ((w & hi) | (((w + 0x0606_0606_0606_0606) & hi) >> 4))
        == 0x3333_3333_3333_3333;
}

/// Converts eight ASCII digits packed little-endian in `w` (first digit
/// in the lowest byte) to their numeric value in three multiplies
/// (Lemire's SWAR reduction) — callers must have gated on
/// $(LREF allDigits8). Replaces eight steps of a serial
/// `sig = sig * 10 + d` chain in the reader's number kernel.
uint eightDigits(ulong w)
{
    pragma(inline, true);
    w -= 0x3030_3030_3030_3030;
    w = w * 10 + (w >> 8); // bytes 0,2,4,6 become adjacent-digit pairs
    const lo = (w & 0x0000_00FF_0000_00FF) * 0x000F_4240_0000_0064;
    const hi = ((w >> 16) & 0x0000_00FF_0000_00FF) * 0x0000_2710_0000_0001;
    return cast(uint)((lo + hi) >> 32);
}

/// The number of leading ASCII digits in `w` (0–8) — the partial-run
/// companion to $(LREF allDigits8), for a digit run that ends inside the
/// word. Both badness tests keep their bits inside their own byte (the
/// low-nibble test cannot carry, since a nibble plus 6 stays under 0x16),
/// so the first non-digit is just the lowest set bit's byte index.
uint digitRun8(ulong w)
{
    pragma(inline, true);
    import core.bitop : bsf;

    enum ulong hi = 0xF0F0_F0F0_F0F0_F0F0;
    enum ulong lo = 0x0F0F_0F0F_0F0F_0F0F;
    // High nibble must be 3; low nibble must not exceed 9.
    const badHi = (w & hi) ^ 0x3030_3030_3030_3030;
    const badLo = ((w & lo) + 0x0606_0606_0606_0606) & 0x1010_1010_1010_1010;
    const bad = badHi | badLo;
    return bad == 0 ? 8 : cast(uint)(bsf(bad) >> 3);
}

/// `w` with byte positions `n..8` replaced by `'0'`, so a run of `n < 8`
/// digits can go through $(LREF eightDigits) unchanged. The result reads
/// as the `n` digits followed by `8 - n` zeros — i.e. the run's value
/// scaled by `10 ^^ (8 - n)`; callers cancel that by counting the padding
/// as consumed digits in the decimal exponent.
ulong padDigits8(ulong w, uint n)
in (n < 8)
{
    pragma(inline, true);
    const keep = (1UL << (n * 8)) - 1;
    return (w & keep) | (0x3030_3030_3030_3030 & ~keep);
}

@("scan.digitRun8.partialRuns")
@safe pure nothrow @nogc
unittest
{
    static ulong word(in char[8] s)
    {
        ulong w = 0;
        foreach_reverse (c; s)
            w = w << 8 | c;
        return w;
    }

    assert(digitRun8(word("12345678")) == 8);
    assert(digitRun8(word("1234567,")) == 7);
    assert(digitRun8(word("12,45678")) == 2);
    assert(digitRun8(word(",1234567")) == 0);
    assert(digitRun8(word("1234567\0")) == 7); // the pool's zero padding
    // Neighbours of the digit range, and a high byte (no cross-byte carry).
    assert(digitRun8(word("12/45678")) == 2 && digitRun8(word("12:45678")) == 2);
    assert(digitRun8(word("12\xFF5678")) == 2);
}

@("scan.padDigits8.scalesByPowerOfTen")
@safe pure nothrow @nogc
unittest
{
    static ulong word(in char[8] s)
    {
        ulong w = 0;
        foreach_reverse (c; s)
            w = w << 8 | c;
        return w;
    }

    // Seven digits padded to eight read as the run followed by one zero.
    assert(eightDigits(padDigits8(word("1234567,"), 7)) == 12_345_670);
    assert(eightDigits(padDigits8(word("12,45678"), 2)) == 12_000_000);
    assert(eightDigits(padDigits8(word(",1234567"), 0)) == 0);
}

@("scan.eightDigits.swarConversion")
@safe pure nothrow @nogc
unittest
{
    static ulong word(in char[8] s)
    {
        ulong w = 0;
        foreach_reverse (c; s)
            w = w << 8 | c;
        return w;
    }

    assert(allDigits8(word("12345678")) && eightDigits(word("12345678")) == 12_345_678);
    assert(allDigits8(word("00000000")) && eightDigits(word("00000000")) == 0);
    assert(allDigits8(word("99999999")) && eightDigits(word("99999999")) == 99_999_999);
    assert(allDigits8(word("09182736")) && eightDigits(word("09182736")) == 9_182_736);
    assert(!allDigits8(word("1234567e")));
    assert(!allDigits8(word("12345.78")));
    assert(!allDigits8(word("1234567\0")));
    assert(!allDigits8(word("/2345678"))); // '/': just below '0'
    assert(!allDigits8(word(":2345678"))); // ':': just above '9'
}

/**
Scans a string body from `i` (just after the opening quote) to the first
quote, backslash, or control byte (< 0x20) in the reader's padded pool.
SWAR: eight bytes per iteration via the classic zero-byte/less-than masks;
the ≥ 8 zero-padding bytes both terminate the walk (NUL is a control byte)
and keep every word load in bounds.

With `validate` set, bytes ≥ 0x80 join the stop set and the non-ASCII run
is checked in place before the ASCII scan resumes — runs of equal-length
sequences are consumed in their own tight loop, which suits real text
(CJK is a long run of 3-byte sequences) and keeps the branch predictable.
Fusing the check here is what lets the reader validate in one pass instead
of re-walking every string that contains a high byte.

With `validate` set but `resolveNonAscii` cleared, a byte ≥ 0x80 still
stops the scan but is returned unresolved (`invalidUtf8` stays false; the
stop byte speaks for itself). This is the reader's inline key probe: it
keeps the UTF-8 machinery out of the grammar loop and punts non-ASCII
keys to the general string kernel, which re-validates from scratch.
*/
StringScan scanStringBody(bool validate = true, bool resolveNonAscii = true)(
    scope const(char)[] paddedPool, size_t i)
in (paddedPool.length >= 8 && paddedPool[$ - 1] == '\0')
{
    pragma(inline, true);
    return (() @trusted {
        enum ulong ones = 0x0101_0101_0101_0101;
        enum ulong highs = 0x8080_8080_8080_8080;

        auto p = paddedPool.ptr;
        size_t j = i;
        while (true)
        {
            // One unaligned 64-bit load; in bounds while j ≤ content
            // length (the padding NUL stops the loop at the boundary).
            const x = loadWord(p + j);

            const q = x ^ 0x2222_2222_2222_2222; // '"'
            const b = x ^ 0x5C5C_5C5C_5C5C_5C5C; // '\\'
            const zq = (q - ones) & ~q & highs; // zero-byte detect
            const zb = (b - ones) & ~b & highs;
            const ctl = (x - 0x2020_2020_2020_2020) & ~x & highs; // < 0x20
            // A byte ≥ 0x80 is already its own high bit, so joining the
            // validation stop set costs one `or` — cheaper than the
            // separate seen-high accumulator it replaces.
            static if (validate)
                const stops = zq | zb | ctl | (x & highs);
            else
                const stops = zq | zb | ctl;
            if (stops != 0)
            {
                import core.bitop : bsf;

                j += bsf(stops) / 8;
                static if (validate && resolveNonAscii)
                {
                    if ((p[j] & 0x80) == 0)
                        return StringScan(j, false);
                    if (!skipUtf8Run(p, j))
                        return StringScan(j, true);
                    continue; // back to the ASCII lane
                }
                else
                    return StringScan(j, false);
            }
            j += 8;
        }
    })();
}

/// Advances `j` over the run of well-formed non-ASCII sequences starting
/// at `p[j]` (which must be ≥ 0x80), returning false — with `j` left on
/// the offending lead — when the first sequence is ill-formed. The 4-byte
/// window is read with one 8-bit-truncated word load; the pool's padding
/// keeps it in bounds at every position.
///
/// Templated (empty parameter list) so it is code-generated in the
/// caller's translation unit: `scanStringBody` is itself a template, and a
/// plain function here stayed an out-of-line call in the reader — 5.7 % of
/// twitter's instructions — with `pragma(inline, true)` unable to cross the
/// package boundary.
private bool skipUtf8Run()(const(char)* p, ref size_t j) @system pure nothrow @nogc
{
    pragma(inline, true);
    const start = j;
    uint w = cast(uint) loadWord(p + j);
    // Most-common length first, each in its own loop: text tends to stay
    // in one script, so the same branch is taken repeatedly.
    while (isUtf8Seq3(w))
    {
        j += 3;
        w = cast(uint) loadWord(p + j);
    }
    if (!isUtf8Seq1(w))
    {
        while (isUtf8Seq2(w))
        {
            j += 2;
            w = cast(uint) loadWord(p + j);
        }
        while (isUtf8Seq4(w))
        {
            j += 4;
            w = cast(uint) loadWord(p + j);
        }
    }
    return j != start;
}
