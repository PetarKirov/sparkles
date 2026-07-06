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
/// stop byte (quote, backslash, or control) and whether any byte ≥ 0x80
/// was seen on the way (may over-report bytes near the stop — callers
/// use it only to skip UTF-8 validation of pure-ASCII spans).
struct StringScan
{
    size_t stop;
    bool sawHigh;
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

/// Scans a string body from `i` (just after the opening quote) to the
/// first quote, backslash, or control byte (< 0x20) in the reader's
/// padded pool. SWAR: eight bytes per iteration via the classic
/// zero-byte/less-than masks; the ≥ 8 zero-padding bytes both terminate
/// the walk (NUL is a control byte) and keep every word load in bounds.
StringScan scanStringBody(scope const(char)[] paddedPool, size_t i)
in (paddedPool.length >= 8 && paddedPool[$ - 1] == '\0')
{
    pragma(inline, true);
    return (() @trusted {
        enum ulong ones = 0x0101_0101_0101_0101;
        enum ulong highs = 0x8080_8080_8080_8080;

        auto p = paddedPool.ptr;
        size_t j = i;
        ulong seenHigh = 0;
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
            const stops = zq | zb | ctl;
            if (stops != 0)
            {
                import core.bitop : bsf;

                const at = j + bsf(stops) / 8;
                // High bytes strictly before the stop still count.
                const mask = ~0UL >> (63 - bsf(stops));
                seenHigh |= x & highs & (mask >> 8);
                return StringScan(at, seenHigh != 0);
            }
            seenHigh |= x & highs;
            j += 8;
        }
    })();
}
