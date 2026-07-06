/**
Correctly-rounded decimal ⇄ binary floating-point conversion.

The parse direction is tiered, fastest first, and every tier is exact —
a caller never receives a value that differs from the correctly-rounded
(round-to-nearest, ties-to-even) result of the full decimal:

$(LIST
    * Tier 1 — the Clinger fast path: when the significand fits the
        `double` mantissa and the power of ten is exactly representable,
        one FP multiply or divide is correctly rounded by construction.
    * Tier 2 — Eisel–Lemire: a 128-bit multiply against a precomputed
        power-of-ten significand table decides almost every remaining
        case, in pure 64-bit integer arithmetic.
    * Tier 3 — a big-integer comparison (`slowDouble`, next milestone)
        settles the rare inputs tier 2 cannot prove (including subnormals
        and overflow-boundary values, which tier 2 deliberately punts).
)

The primitives are building blocks for fused grammar loops (the JSON
reader accumulates digits inside its own scanner and calls
$(LREF tryFastDouble) directly); $(LREF readDecimalFloat) is the plain
cursor-style reader for everything else.

The power-of-ten table is generated at CTFE from exact big-integer
arithmetic — there is no external generator step to keep in sync.
*/
module sparkles.base.text.float_conv;

import sparkles.base.text.errors : ParseErrorCode, ParseExpected, parseErr,
    parseOk;

// ─────────────────────────────────────────────────────────────────────────────
// Bit and wide-multiply kernels
// ─────────────────────────────────────────────────────────────────────────────

/// The IEEE-754 bit pattern of `d` (CTFE-safe).
ulong doubleToBits(double d) @trusted pure nothrow @nogc
{
    if (__ctfe)
    {
        // Pointer reinterpretation is unavailable at CTFE; decompose
        // arithmetically (finite values, infinities, and NaN).
        if (d != d)
            return 0x7FF8_0000_0000_0000; // canonical quiet NaN
        ulong sign = 0;
        if (d < 0 || (d == 0 && 1.0 / d < 0))
        {
            sign = 1UL << 63;
            d = -d;
        }
        if (d == 0)
            return sign;
        if (d == double.infinity)
            return sign | 0x7FF0_0000_0000_0000;
        int exp = 0;
        while (d >= 2)
        {
            d /= 2; // exact: halving cannot round
            exp++;
        }
        while (d < 1 && exp > -1022)
        {
            d *= 2; // exact: doubling a representable value below 1
            exp--;
        }
        if (d < 1) // subnormal: exponent field 0, no implicit bit
            return sign | cast(ulong)(d * (1UL << 52));
        const frac = cast(ulong)((d - 1) * (1UL << 52));
        return sign | (cast(ulong)(exp + 1023) << 52) | frac;
    }
    return *cast(const ulong*) &d;
}

/// The `double` with the IEEE-754 bit pattern `bits` (CTFE-safe).
double bitsToDouble(ulong bits) @trusted pure nothrow @nogc
{
    if (__ctfe)
    {
        const negative = (bits >> 63) != 0;
        const expField = cast(int)((bits >> 52) & 0x7FF);
        const frac = bits & ((1UL << 52) - 1);
        double magnitude;
        if (expField == 0x7FF)
            magnitude = frac ? double.nan : double.infinity;
        else if (expField == 0)
            // frac × 2^-1074, via the exactly-representable smallest normal
            magnitude = cast(double) frac * (double.min_normal / (1UL << 52));
        else
            magnitude = (1.0 + cast(double) frac / (1UL << 52)) * pow2(expField - 1023);
        return negative ? -magnitude : magnitude;
    }
    return *cast(const double*) &bits;
}

/// `2.0 ^^ e` by squaring — exact for `e ≥ -1074` (all powers of two down
/// to the smallest subnormal are representable).
private double pow2(int e) @safe pure nothrow @nogc
{
    double base = e < 0 ? 0.5 : 2.0;
    uint n = e < 0 ? -e : e;
    double result = 1;
    while (n)
    {
        if (n & 1)
            result *= base;
        base *= base;
        n >>= 1;
    }
    return result;
}

/// A 128-bit unsigned product.
struct U128
{
    ulong hi; /// most-significant 64 bits
    ulong lo; /// least-significant 64 bits
}

/// Full 64×64 → 128-bit unsigned multiply. On LDC the body is one LLVM
/// `i128 mul` (a single widening `mul`/`umulh` pair — the four-multiply
/// decomposition demonstrably does not fold); elsewhere and at CTFE the
/// portable decomposition runs (bare `ucent` is deprecated as of D 2.111).
U128 mul64x64(ulong a, ulong b) @safe pure nothrow @nogc
{
    pragma(inline, true);
    version (LDC)
    {
        if (!__ctfe)
        {
            import ldc.llvmasm : __ir_pure;

            // LLVM CSEs the two identical multiplies into one.
            const lo = __ir_pure!(`
                %a = zext i64 %0 to i128
                %b = zext i64 %1 to i128
                %m = mul i128 %a, %b
                %t = trunc i128 %m to i64
                ret i64 %t`, ulong)(a, b);
            const hi = __ir_pure!(`
                %a = zext i64 %0 to i128
                %b = zext i64 %1 to i128
                %m = mul i128 %a, %b
                %s = lshr i128 %m, 64
                %t = trunc i128 %s to i64
                ret i64 %t`, ulong)(a, b);
            return U128(hi, lo);
        }
    }
    const aLo = a & 0xFFFF_FFFF, aHi = a >> 32;
    const bLo = b & 0xFFFF_FFFF, bHi = b >> 32;
    const p00 = aLo * bLo;
    const mid = aLo * bHi + (p00 >> 32) + (aHi * bLo & 0xFFFF_FFFF);
    const lo = (mid << 32) | (p00 & 0xFFFF_FFFF);
    const hi = aHi * bHi + (aHi * bLo >> 32) + (mid >> 32);
    return U128(hi, lo);
}

/// Count of leading zero bits (defined for `x != 0`; CTFE-compatible).
private int leadingZeros(ulong x) @safe pure nothrow @nogc
in (x != 0)
{
    if (!__ctfe)
    {
        import core.bitop : bsr;

        return 63 - bsr(x);
    }
    int n = 0;
    if (x >> 32 == 0) { n += 32; x <<= 32; }
    if (x >> 48 == 0) { n += 16; x <<= 16; }
    if (x >> 56 == 0) { n += 8; x <<= 8; }
    if (x >> 60 == 0) { n += 4; x <<= 4; }
    if (x >> 62 == 0) { n += 2; x <<= 2; }
    if (x >> 63 == 0) { n += 1; }
    return n;
}

// ─────────────────────────────────────────────────────────────────────────────
// Digit accumulation
// ─────────────────────────────────────────────────────────────────────────────

/**
Reads a run of ASCII digits from the front of `s`, accumulating into `sig`
(`sig = sig * 10 + digit`), stopping at the first non-digit, the end of
input, or after `maxDigits` digits — whichever comes first. Returns the
number of digits consumed. `s` is not advanced (callers slice by the
returned count); `sig`'s existing value participates, so a fused grammar
loop can continue one accumulation across the decimal point.

The body is a manually unrolled compare/multiply-add chain (a `ulong`
holds any 19-digit value without overflow) — the scalar equivalent of
yyjson's `repeat_in_1_18`: one subtract, one compare, one multiply-add and
one predictable branch per digit.
*/
size_t readDigits(uint maxDigits = 19)(scope const(char)[] s, ref ulong sig)
if (maxDigits >= 1 && maxDigits <= 19)
{
    size_t i = 0;
    static foreach (_; 0 .. maxDigits)
    {
        {
            if (i >= s.length)
                return i;
            const uint d = cast(uint)(s[i] - '0');
            if (d > 9)
                return i;
            sig = sig * 10 + d;
            i++;
        }
    }
    return i;
}

/// ditto — runtime-capped variant for continuing a budgeted accumulation
/// (e.g. fraction digits after some integer digits already consumed).
size_t readDigits(scope const(char)[] s, ref ulong sig, size_t maxDigits)
    @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < maxDigits && i < s.length)
    {
        const uint d = cast(uint)(s[i] - '0');
        if (d > 9)
            break;
        sig = sig * 10 + d;
        i++;
    }
    return i;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tier 1 + tier 2: tryFastDouble
// ─────────────────────────────────────────────────────────────────────────────

/// Exactly representable powers of ten: `10^0 .. 10^22` all fit a `double`
/// mantissa (`5^22 < 2^53`).
private static immutable double[23] exactPow10 = () {
    double[23] t;
    double v = 1;
    foreach (i; 0 .. 23)
    {
        t[i] = v;
        v *= 10;
    }
    return t;
}();

/// Exponent bounds of the power-of-ten table (shared by the reader and
/// the Schubfach writer, which needs the wider positive range).
private enum int tableMinExp10 = -343;
/// ditto
private enum int tableMaxExp10 = 324;

/// The reader's saturation bounds: outside them the value saturates
/// regardless of a ≤19-digit significand (`sig × 10^-343 < 2^-1075` rounds
/// to zero, `sig × 10^309 > double.max` to infinity).
private enum int minExp10 = -342;
/// ditto
private enum int maxExp10 = 308;

/**
Converts `sig10 × 10^exp10` to the correctly-rounded nearest `double`.

Returns `false` when the result cannot be *proven* correctly rounded by
the fast tiers — the caller falls back to the exact big-integer path
(`slowDouble`) with the original digits. Deliberately punted to that path:
subnormal results, values at the overflow boundary, and unprovable ties.
`sig10 == 0` and out-of-range exponents always succeed (`0` /
`double.infinity` per the saturation policy).

`sig10` must carry at most 19 significant digits (a full `ulong`
accumulation); `exp10` is the decimal exponent of its last digit.
*/
bool tryFastDouble(ulong sig10, int exp10, out double result)
    @safe pure nothrow @nogc
{
    pragma(inline, true);
    if (sig10 == 0 || exp10 < minExp10)
    {
        result = 0;
        return true;
    }
    if (exp10 > maxExp10)
    {
        result = double.infinity;
        return true;
    }

    // Tier 1 — Clinger: one exactly-rounded FP operation. (Skipped at
    // CTFE so compile-time results flow through the same integer path.)
    if (!__ctfe && sig10 < (1UL << 53) && -22 <= exp10 && exp10 <= 22)
    {
        result = exp10 >= 0
            ? cast(double) sig10 * exactPow10[exp10]
            : cast(double) sig10 / exactPow10[-exp10];
        return true;
    }

    return eiselLemire(sig10, exp10, result);
}

/**
The Eisel–Lemire algorithm (the Go `strconv` formulation): multiply the
normalized significand by the 128-bit truncated power-of-ten significand
and prove the truncation cannot affect the rounded result. Correctly
rounded whenever it returns `true`; conservative `false` otherwise.
*/
private bool eiselLemire(ulong sig10, int exp10, out double result)
    @safe pure nothrow @nogc
in (sig10 != 0 && minExp10 <= exp10 && exp10 <= maxExp10)
{
    pragma(inline, true);
    const lz = leadingZeros(sig10);
    const w = sig10 << lz;

    // floor(exp10 × log2(10)) by fixed-point multiply: 217706 / 2^16.
    const long retExp2Base = ((217_706 * cast(long) exp10) >> 16) + 64 + 1023;
    long retExp2 = retExp2Base - lz;

    const entry = pow10Sig128[exp10 - tableMinExp10];
    auto x = mul64x64(w, entry.hi);

    // If the 9 bits feeding mantissa+rounding are all ones, the truncated
    // table tail could carry into them — refine with the low word.
    if ((x.hi & 0x1FF) == 0x1FF && x.lo + w < x.lo)
    {
        const y = mul64x64(w, entry.lo);
        auto mergedHi = x.hi;
        auto mergedLo = x.lo + y.hi;
        if (mergedLo < x.lo)
            mergedHi++;
        if ((mergedHi & 0x1FF) == 0x1FF && mergedLo + 1 == 0 && y.lo + w < w)
            return false; // still ambiguous after 192 bits — exact tier
        x = U128(mergedHi, mergedLo);
    }

    const msb = x.hi >> 63;
    ulong mantissa = x.hi >> (msb + 9); // 54 bits: 53-bit mantissa + round bit
    retExp2 -= 1 ^ msb;

    // Exactly-halfway trap: the truncated table cannot distinguish a true
    // tie from a value infinitesimally off it.
    if (x.lo == 0 && (x.hi & 0x1FF) == 0 && (mantissa & 3) == 1)
        return false;

    // Round to nearest, ties away resolved by the even check above.
    mantissa += mantissa & 1;
    mantissa >>= 1;
    if (mantissa >> 53)
    {
        mantissa >>= 1;
        retExp2++;
    }

    // Subnormal (retExp2 ≤ 0) and overflow (≥ 0x7FF) punt to the exact
    // tier — one unsigned comparison covers both.
    if (cast(ulong)(retExp2 - 1) >= 0x7FF - 1)
        return false;

    result = bitsToDouble((cast(ulong) retExp2 << 52) | (mantissa & ((1UL << 52) - 1)));
    return true;
}

// ─────────────────────────────────────────────────────────────────────────────
// The 128-bit power-of-ten significand table (CTFE-generated)
// ─────────────────────────────────────────────────────────────────────────────

private struct Pow10Entry
{
    ulong hi;
    ulong lo;
}

/**
For each `q` in `[tableMinExp10, tableMaxExp10]`: the top 128 bits of the
binary expansion of `10^q`, normalized to `[2^127, 2^128)` and truncated
(never rounded up) — the yyjson convention, which both the Eisel–Lemire
reader and the Schubfach writer build on (the writer applies its own +1
ceiling adjustment). The power-of-two factor lives in the exponent
formulas.

Generated at CTFE by exact big-integer arithmetic (`5^|q|` grows to ~800
bits).
*/
private static immutable Pow10Entry[tableMaxExp10 - tableMinExp10 + 1] pow10Sig128 =
    generatePow10Table();

// --- CTFE big-integer scratch: little-endian base-2^32 limbs -----------------

private uint[] bigMulSmall(const uint[] a, uint m) @safe pure nothrow
{
    auto r = new uint[](a.length + 1);
    ulong carry = 0;
    foreach (i, limb; a)
    {
        const t = cast(ulong) limb * m + carry;
        r[i] = cast(uint) t;
        carry = t >> 32;
    }
    r[a.length] = cast(uint) carry;
    while (r.length > 1 && r[$ - 1] == 0)
        r = r[0 .. $ - 1];
    return r;
}

/// Number of significant bits (`a != 0`).
private size_t bigBitLength(const uint[] a) @safe pure nothrow @nogc
{
    size_t bits = (a.length - 1) * 32;
    uint top = a[$ - 1];
    while (top)
    {
        bits++;
        top >>= 1;
    }
    return bits;
}

private bool bigBit(const uint[] a, size_t i) @safe pure nothrow @nogc
{
    const limb = i / 32;
    return limb < a.length && ((a[limb] >> (i % 32)) & 1) != 0;
}

/// The value normalized to 128 bits: top 128 bits when longer (truncated),
/// left-shifted into `[2^127, 2^128)` when shorter.
private Pow10Entry bigTop128(const uint[] a) @safe pure nothrow @nogc
{
    const bits = bigBitLength(a);
    ulong hi = 0, lo = 0;
    foreach (k; 0 .. 128)
    {
        bool b = false;
        if (k < bits)
            b = bigBit(a, bits - 1 - k);
        if (k < 64)
            hi = (hi << 1) | (b ? 1 : 0);
        else
            lo = (lo << 1) | (b ? 1 : 0);
    }
    return Pow10Entry(hi, lo);
}

/// `floor(2^(bitLength(d) + 127) / d)` as 128 normalized bits — restoring
/// long division producing one quotient bit per step (truncated, per the
/// table convention).
private Pow10Entry bigReciprocal128(const uint[] d) @safe pure nothrow
{
    // After the numerator's top bitLength(d) bits (value 2^(bitLength-1),
    // strictly < d since d is odd and > 1), the remainder is that value
    // and every produced quotient bit so far is 0; the remaining 128
    // numerator bits are zeros and yield exactly the 128 result bits.
    auto rem = new uint[](d.length + 1);
    {
        const bits = bigBitLength(d) - 1;
        rem[bits / 32] = 1u << (bits % 32);
    }

    ulong hi = 0, lo = 0;
    foreach (k; 0 .. 128)
    {
        // rem <<= 1
        uint carry = 0;
        foreach (i; 0 .. rem.length)
        {
            const t = (cast(ulong) rem[i] << 1) | carry;
            rem[i] = cast(uint) t;
            carry = cast(uint)(t >> 32);
        }
        // rem >= d?
        bool ge = true;
        {
            size_t rl = rem.length;
            while (rl > 1 && rem[rl - 1] == 0)
                rl--;
            if (rl != d.length)
                ge = rl > d.length;
            else
                foreach_reverse (i; 0 .. rl)
                    if (rem[i] != d[i])
                    {
                        ge = rem[i] > d[i];
                        break;
                    }
        }
        ulong bit = 0;
        if (ge)
        {
            long borrow = 0;
            foreach (i; 0 .. rem.length)
            {
                long t = cast(long) rem[i] - (i < d.length ? d[i] : 0) - borrow;
                borrow = t < 0 ? 1 : 0;
                if (t < 0)
                    t += 0x1_0000_0000L;
                rem[i] = cast(uint) t;
            }
            bit = 1;
        }
        if (k < 64)
            hi = (hi << 1) | bit;
        else
            lo = (lo << 1) | bit;
    }

    return Pow10Entry(hi, lo);
}

private Pow10Entry[tableMaxExp10 - tableMinExp10 + 1] generatePow10Table()
    @safe pure nothrow
{
    Pow10Entry[tableMaxExp10 - tableMinExp10 + 1] table;

    // q ≥ 0: top 128 bits of 5^q (10^q = 5^q × 2^q).
    uint[] pow5 = [1u];
    foreach (q; 0 .. tableMaxExp10 + 1)
    {
        table[q - tableMinExp10] = bigTop128(pow5);
        pow5 = bigMulSmall(pow5, 5);
    }

    // q < 0: normalized, truncated 128-bit reciprocal of 5^|q|.
    pow5 = [5u];
    foreach (q; 1 .. -tableMinExp10 + 1)
    {
        table[-q - tableMinExp10] = bigReciprocal128(pow5);
        pow5 = bigMulSmall(pow5, 5);
    }

    return table;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tier 3: the exact big-decimal slow path
// ─────────────────────────────────────────────────────────────────────────────

/**
Converts a decimal literal to the correctly-rounded nearest `double`
exactly, with no fast-path preconditions — the tier that settles every
input `tryFastDouble` punts (true ties, subnormals, overflow boundaries,
>19-digit truncations).

`intDigits`/`fracDigits` are the digit runs on either side of the decimal
point (either may be empty, both may carry leading zeros);
`explicitExp10` is the literal's exponent part. The algorithm is the
classic arbitrary-precision decimal-shift fallback (Go `strconv`,
originally David Gay): scale the decimal by powers of two until it sits
in `[1, 2)`, then read off the 53-bit mantissa with exact rounding
information. Fixed storage, `@nogc`, CTFE-capable.
*/
double slowDouble(scope const(char)[] intDigits, scope const(char)[] fracDigits,
    int explicitExp10) @safe pure nothrow @nogc
{
    BigDecimal d;
    d.set(intDigits, fracDigits, explicitExp10);

    // Obvious saturation (also bounds the shifting below).
    if (d.count == 0 || d.pointPos < -330)
        return 0.0;
    if (d.pointPos > 310)
        return double.infinity;

    // Bits contributed by shifting by 10^k: powtab[k] = floor(k·log2(10)).
    static immutable int[9] powtab = [1, 3, 6, 9, 13, 16, 19, 23, 26];

    int exp2 = 0;
    // Scale down to below 1 (pointPos ≤ 0)…
    while (d.pointPos > 0)
    {
        const idx = d.pointPos >= powtab.length ? powtab.length - 1 : d.pointPos;
        const n = powtab[idx];
        d.shiftRight(n);
        exp2 += n;
    }
    // …then up into [0.5, 1): pointPos == 0 with a first digit ≥ 5.
    while (d.pointPos < 0 || (d.pointPos == 0 && d.digit(0) < 5))
    {
        const mag = -d.pointPos;
        const idx = mag >= powtab.length ? powtab.length - 1 : mag;
        const n = mag == 0 ? 1 : powtab[idx];
        d.shiftLeft(n);
        exp2 -= n;
    }
    exp2--; // [0.5, 1) → [1, 2)

    // Clamp into the subnormal range when below the smallest normal exponent.
    enum minNormalExp2 = -1022;
    if (exp2 < minNormalExp2)
    {
        const n = minNormalExp2 - exp2;
        d.shiftRight(n);
        exp2 += n;
    }
    if (exp2 > 1023)
        return double.infinity;

    // Extract mantissa: shift the value into [2^52, 2^53) and round.
    d.shiftLeft(53);
    ulong mantissa = d.roundedInteger();
    if (mantissa >= (1UL << 53)) // rounding carried
    {
        mantissa >>= 1;
        exp2++;
        if (exp2 > 1023)
            return double.infinity;
    }
    if (mantissa < (1UL << 52)) // subnormal (leading bit not reached)
        return bitsToDouble(mantissa); // exponent field 0
    return bitsToDouble((cast(ulong)(exp2 + 1023) << 52)
        | (mantissa & ((1UL << 52) - 1)));
}

/// Arbitrary-precision decimal for the slow path: up to `capacity`
/// significant digits (beyond that only a sticky "truncated" bit matters
/// for rounding), a decimal-point position, and exact power-of-two shifts.
private struct BigDecimal
{
    // 800 digits cover every exactly-representable double (the longest
    // exact decimal expansion of a subnormal is 767 significant digits).
    enum capacity = 800;

    ubyte[capacity] digits; // values 0..9, most significant first
    int count;              // significant digits stored
    int pointPos;           // decimal point sits after digits[0 .. pointPos]
    bool truncated;         // nonzero digits beyond capacity were dropped

    ubyte digit(size_t i) const @safe pure nothrow @nogc
        => i < count ? digits[i] : 0;

    /// Loads from integer/fraction digit runs and an explicit exponent.
    void set(scope const(char)[] intPart, scope const(char)[] fracPart,
        int explicitExp10) @safe pure nothrow @nogc
    {
        count = 0;
        truncated = false;
        int firstExp = 0; // pointPos before the explicit exponent
        bool seenSignificant = false;

        foreach (i; 0 .. intPart.length)
        {
            const ubyte v = cast(ubyte)(intPart[i] - '0');
            if (!seenSignificant)
            {
                if (v == 0)
                    continue;
                seenSignificant = true;
                firstExp = cast(int)(intPart.length - i); // digits before '.'
            }
            store(v);
        }
        foreach (i; 0 .. fracPart.length)
        {
            const ubyte v = cast(ubyte)(fracPart[i] - '0');
            if (!seenSignificant)
            {
                if (v == 0)
                    continue;
                seenSignificant = true;
                firstExp = -cast(int) i; // value = 0.00…digits
            }
            store(v);
        }

        while (count > 0 && digits[count - 1] == 0)
            count--; // trailing zeros carry no information
        pointPos = count == 0 ? 0 : firstExp + explicitExp10;
    }

    private void store(ubyte v) @safe pure nothrow @nogc
    {
        if (count < capacity)
            digits[count++] = v;
        else if (v != 0)
            truncated = true;
    }

    private void trimZeros() @safe pure nothrow @nogc
    {
        // Leading zeros shift the whole window (and the point) left…
        int lead = 0;
        while (lead < count && digits[lead] == 0)
            lead++;
        if (lead > 0)
        {
            foreach (i; 0 .. count - lead)
                digits[i] = digits[i + lead];
            count -= lead;
            pointPos -= lead;
        }
        // …trailing zeros just shrink the window.
        while (count > 0 && digits[count - 1] == 0)
            count--;
        if (count == 0)
            pointPos = 0;
    }

    /// Divides by 2^n exactly (Go strconv's `rightShift`, ≤60 bits/step).
    void shiftRight(int n) @safe pure nothrow @nogc
    {
        while (n > 0)
        {
            const step = n > 60 ? 60 : n;
            shiftRightUpTo60(step);
            n -= step;
        }
    }

    private void shiftRightUpTo60(int k) @safe pure nothrow @nogc
    {
        size_t r = 0; // read index
        ulong n = 0;

        // Pick up enough digits to cover the divisor.
        while ((n >> k) == 0)
        {
            if (r >= count)
            {
                if (n == 0)
                {
                    count = 0;
                    pointPos = 0;
                    return;
                }
                while ((n >> k) == 0)
                {
                    n *= 10;
                    r++;
                }
                break;
            }
            n = n * 10 + digits[r];
            r++;
        }
        pointPos -= cast(int) r - 1;

        const mask = (1UL << k) - 1;
        size_t w = 0; // write index
        while (r < count)
        {
            const c = digits[r];
            r++;
            const dig = n >> k;
            n &= mask;
            if (w < capacity)
                digits[w++] = cast(ubyte) dig;
            else if (dig != 0)
                truncated = true;
            n = n * 10 + c;
        }
        while (n > 0)
        {
            const dig = n >> k;
            n &= mask;
            if (w < capacity)
                digits[w++] = cast(ubyte) dig;
            else if (dig != 0)
                truncated = true;
            n *= 10;
        }
        count = cast(int) w;
        trimZeros();
    }

    /// Multiplies by 2^n exactly.
    void shiftLeft(int n) @safe pure nothrow @nogc
    {
        while (n > 0)
        {
            const step = n > 60 ? 60 : n;
            shiftLeftUpTo60(step);
            n -= step;
        }
    }

    private void shiftLeftUpTo60(int n) @safe pure nothrow @nogc
    {
        if (count == 0)
            return;
        // Multiply digit string by 2^n, least significant first.
        // Result grows by at most delta digits: ceil(n·log10(2)) + 1.
        const delta = cast(int)((cast(long) n * 30_103) / 100_000) + 1;

        ubyte[capacity + 20] outDigits; // room for the growth before trim
        ulong carry = 0;
        int outLen = count + delta;
        foreach_reverse (i; 0 .. outLen)
        {
            const srcIdx = i - delta;
            const d = srcIdx >= 0 && srcIdx < count ? digits[srcIdx] : 0;
            const v = (cast(ulong) d << n) + carry;
            outDigits[i] = cast(ubyte)(v % 10);
            carry = v / 10;
        }
        assert(carry == 0, "delta bound must absorb the carry");

        // Trim leading zeros (delta may overshoot by one digit).
        int lead = 0;
        while (lead < outLen && outDigits[lead] == 0)
            lead++;
        int newCount = outLen - lead;
        bool newTruncated = truncated;
        if (newCount > capacity)
        {
            foreach (i; capacity .. newCount)
                if (outDigits[lead + i] != 0)
                    newTruncated = true;
            newCount = capacity;
        }
        foreach (i; 0 .. newCount)
            digits[i] = outDigits[lead + i];
        // Trailing zeros away.
        while (newCount > 0 && digits[newCount - 1] == 0)
            newCount--;
        pointPos += delta - lead;
        count = newCount;
        truncated = newTruncated;
    }

    /// The integer part rounded to nearest, ties to even — exact, because
    /// the fraction digits (plus the sticky truncation bit) are available.
    ulong roundedInteger() const @safe pure nothrow @nogc
    {
        if (pointPos < 0)
            return 0; // below 0.1 — strictly under one half
        ulong value = 0;
        foreach (i; 0 .. pointPos)
            value = value * 10 + digit(i);

        // Decide the fraction: > ½ rounds up, < ½ down, exactly ½ to even.
        bool roundUp = false;
        const first = digit(pointPos);
        if (first > 5)
            roundUp = true;
        else if (first == 5)
        {
            bool exactlyHalf = !truncated;
            if (exactlyHalf)
                foreach (i; pointPos + 1 .. count)
                    if (digits[i] != 0)
                    {
                        exactlyHalf = false;
                        break;
                    }
            roundUp = exactlyHalf ? (value & 1) != 0 : true;
        }
        return value + (roundUp ? 1 : 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shortest round-trip formatting (Schubfach, the yyjson formulation)
// ─────────────────────────────────────────────────────────────────────────────

/// Digit pairs "00".."99" — the branchlut table shared by the integer and
/// float writers.
package static immutable char[200] digitPairs = () {
    char[200] t;
    foreach (i; 0 .. 100)
    {
        t[i * 2] = cast(char)('0' + i / 10);
        t[i * 2 + 1] = cast(char)('0' + i % 10);
    }
    return t;
}();

/// Count of trailing decimal zeros for 0..99 (0 itself counts as 2).
private static immutable ubyte[100] decTrailingZeros = () {
    ubyte[100] t;
    foreach (i; 0 .. 100)
        t[i] = i == 0 ? 2 : (i % 10 == 0 ? 1 : 0);
    return t;
}();

/// `a × b + add` as a full 128-bit result.
private U128 mulAdd64(ulong a, ulong b, ulong add) @safe pure nothrow @nogc
{
    auto p = mul64x64(a, b);
    p.lo += add;
    if (p.lo < add)
        p.hi++;
    return p;
}

/// The high 64 bits of `(hi:lo) × cp`, rounded to odd (sticky low bit).
private ulong roundToOdd128(ulong hi, ulong lo, ulong cp) @safe pure nothrow @nogc
{
    const x = mul64x64(cp, lo);
    const y = mulAdd64(cp, hi, x.hi);
    return y.hi | (y.lo > 1);
}

/**
Converts a nonzero finite `double` (given as its raw IEEE-754 fields and
decoded significand/exponent) to the shortest decimal significand and
exponent that round-trip: `sigDec × 10^expDec` re-parses to exactly the
input. `sigDec` may carry trailing zeros — the digit renderer trims them.

Port of yyjson's `f64_bin_to_dec`: a full-precision fast path that settles
most values with one 128-bit multiply, falling back to the Schubfach
algorithm (Raffaello Giulietti, "The Schubfach way to render doubles",
2022) for the boundary cases.
*/
private void f64ToDecimal(ulong sigRaw, uint expRaw, ulong sigBin, int expBin,
    out ulong sigDec, out int expDec) @safe pure nothrow @nogc
{
    // Fast path: for regular spacing, compare the value and its half-ulp
    // neighborhood in one fixed-point picture and pick among 4 candidates
    // (trim-and-round-down / round-down / round-up / trim-and-round-up).
    while (sigRaw != 0) // (single-iteration: `break` = fall to Schubfach)
    {
        // k = floor(expBin × log10(2)); h = expBin + floor(log2(10) × -k)
        const int k = (expBin * 315_653) >> 20;
        const int h = expBin + ((-k * 217_707) >> 16); // h ∈ [0, 3]
        const entry = pow10Sig128[-k - tableMinExp10];

        const cb = sigBin << (h + 1);
        auto s = mul64x64(cb, entry.lo);
        const p = mulAdd64(cb, entry.hi, s.hi);
        const sHi = p.hi;
        const sLo = p.lo;
        const mod = sHi % 10;
        const dec = sHi - mod;

        // Shift right 4 so one ulp's digit and the half-ulp fit u64.
        const c = (mod << 60) | (sLo >> 4);
        const halfUlp = entry.hi >> (4 - h);

        const w1Inside = sLo >= (1UL << 63);
        if (sLo == (1UL << 63))
            break;
        const u0Inside = halfUlp >= c;
        if (halfUlp == c)
            break;
        const t0 = 10UL << 60;
        const t1 = c + halfUlp;
        const w0Inside = t1 >= t0;
        if (t0 - t1 <= 1)
            break;

        const trim = u0Inside | w0Inside;
        const addTen = w0Inside ? 10 : 0;
        const addOne = mod + (w1Inside ? 1 : 0);
        sigDec = dec + (trim ? addTen : addOne);
        expDec = k;
        return;
    }

    // Schubfach: prove the shortest candidate via the rounding interval
    // [cbl, cbr] (scaled ×4), computed with round-to-odd products.
    const bool irregular = sigRaw == 0 && expRaw > 1;
    const bool isEven = (sigBin & 1) == 0;
    const cbl = 4 * sigBin - 2 + (irregular ? 1 : 0);
    const cb = 4 * sigBin;
    const cbr = 4 * sigBin + 2;

    // k = floor(expBin×log10(2) + (irregular ? log10(3/4) : 0));
    // h = expBin + floor(log2(10) × -k) + 1;  (h ∈ [1, 4])
    const int k = cast(int)(expBin * 315_653L - (irregular ? 131_237 : 0)) >> 20;
    const int h = expBin + ((-k * 217_707) >> 16) + 1;
    Pow10Entry entry = pow10Sig128[-k - tableMinExp10];
    entry.lo += 1; // ceiling adjustment over the truncated table

    const vbl = roundToOdd128(entry.hi, entry.lo, cbl << h);
    const vb = roundToOdd128(entry.hi, entry.lo, cb << h);
    const vbr = roundToOdd128(entry.hi, entry.lo, cbr << h);
    const lower = vbl + (isEven ? 0 : 1);
    const upper = vbr - (isEven ? 0 : 1);

    const s = vb / 4;
    if (s >= 10)
    {
        const sp = s / 10;
        const u0Inside = lower <= 40 * sp;
        const w0Inside = upper >= 40 * sp + 40;
        if (u0Inside != w0Inside)
        {
            sigDec = sp * 10 + (w0Inside ? 10 : 0);
            expDec = k;
            return;
        }
    }
    const u1Inside = lower <= 4 * s;
    const w1Inside = upper >= 4 * s + 4;
    const mid = 4 * s + 2;
    const roundUp = vb > mid || (vb == mid && (s & 1) != 0);
    sigDec = s + (u1Inside != w1Inside ? (w1Inside ? 1 : 0) : (roundUp ? 1 : 0));
    expDec = k;
}

// --- Digit renderers (yyjson's branchlut writers, pointer-based) -------------

private char* putPair(char* buf, uint v) @system pure nothrow @nogc
{
    buf[0 .. 2] = digitPairs[v * 2 .. v * 2 + 2];
    return buf + 2;
}

private char* writeU32Len8(uint val, char* buf) @system pure nothrow @nogc
{
    const aabb = cast(uint)((cast(ulong) val * 109_951_163) >> 40); // val / 1e4
    const ccdd = val - aabb * 10_000;
    const aa = (aabb * 5243) >> 19; // aabb / 100
    const cc = (ccdd * 5243) >> 19;
    putPair(buf + 0, aa);
    putPair(buf + 2, aabb - aa * 100);
    putPair(buf + 4, cc);
    putPair(buf + 6, ccdd - cc * 100);
    return buf + 8;
}

private char* writeU32Len1to8(uint val, char* buf) @system pure nothrow @nogc
{
    if (val < 100)
    {
        const lz = val < 10;
        buf[0 .. 2] = digitPairs[val * 2 + lz .. val * 2 + lz + 2];
        return buf + 2 - lz;
    }
    if (val < 10_000)
    {
        const aa = (val * 5243) >> 19;
        const lz = aa < 10;
        buf[0 .. 2] = digitPairs[aa * 2 + lz .. aa * 2 + lz + 2];
        buf -= lz;
        putPair(buf + 2, val - aa * 100);
        return buf + 4;
    }
    if (val < 1_000_000)
    {
        const aa = cast(uint)((cast(ulong) val * 429_497) >> 32); // val / 1e4
        const bbcc = val - aa * 10_000;
        const bb = (bbcc * 5243) >> 19;
        const lz = aa < 10;
        buf[0 .. 2] = digitPairs[aa * 2 + lz .. aa * 2 + lz + 2];
        buf -= lz;
        putPair(buf + 2, bb);
        putPair(buf + 4, bbcc - bb * 100);
        return buf + 6;
    }
    {
        const aabb = cast(uint)((cast(ulong) val * 109_951_163) >> 40);
        const ccdd = val - aabb * 10_000;
        const aa = (aabb * 5243) >> 19;
        const cc = (ccdd * 5243) >> 19;
        const lz = aa < 10;
        buf[0 .. 2] = digitPairs[aa * 2 + lz .. aa * 2 + lz + 2];
        buf -= lz;
        putPair(buf + 2, aabb - aa * 100);
        putPair(buf + 4, cc);
        putPair(buf + 6, ccdd - cc * 100);
        return buf + 8;
    }
}

package char* writeU64Len1to16(ulong val, char* buf) @system pure nothrow @nogc
{
    if (val < 100_000_000)
        return writeU32Len1to8(cast(uint) val, buf);
    const hgh = val / 100_000_000;
    const low = cast(uint)(val - hgh * 100_000_000);
    buf = writeU32Len1to8(cast(uint) hgh, buf);
    return writeU32Len8(low, buf);
}

private char* writeU32Len4(uint val, char* buf) @system pure nothrow @nogc
{
    const aa = (val * 5243) >> 19; // val / 100
    putPair(buf + 0, aa);
    putPair(buf + 2, val - aa * 100);
    return buf + 4;
}

private char* writeU32Len5to8(uint val, char* buf) @system pure nothrow @nogc
{
    if (val < 1_000_000)
    {
        const aa = cast(uint)((cast(ulong) val * 429_497) >> 32); // val / 1e4
        const bbcc = val - aa * 10_000;
        const bb = (bbcc * 5243) >> 19;
        const lz = aa < 10;
        buf[0 .. 2] = digitPairs[aa * 2 + lz .. aa * 2 + lz + 2];
        buf -= lz;
        putPair(buf + 2, bb);
        putPair(buf + 4, bbcc - bb * 100);
        return buf + 6;
    }
    const aabb = cast(uint)((cast(ulong) val * 109_951_163) >> 40);
    const ccdd = val - aabb * 10_000;
    const aa = (aabb * 5243) >> 19;
    const cc = (ccdd * 5243) >> 19;
    const lz = aa < 10;
    buf[0 .. 2] = digitPairs[aa * 2 + lz .. aa * 2 + lz + 2];
    buf -= lz;
    putPair(buf + 2, aabb - aa * 100);
    putPair(buf + 4, cc);
    putPair(buf + 6, ccdd - cc * 100);
    return buf + 8;
}

/// Any `ulong`, 1..20 digits — the branchlut integer writer (yyjson's
/// `write_u64`): two digits per lookup, division only at 8-digit strides.
package char* writeU64Digits(ulong val, char* buf) @system pure nothrow @nogc
{
    if (val < 100_000_000) // 1-8 digits
        return writeU32Len1to8(cast(uint) val, buf);
    if (val < 100_000_000UL * 100_000_000) // 9-16 digits
    {
        const hgh = val / 100_000_000;
        const low = cast(uint)(val - hgh * 100_000_000);
        buf = writeU32Len1to8(cast(uint) hgh, buf);
        return writeU32Len8(low, buf);
    }
    // 17-20 digits
    const tmp = val / 100_000_000;
    const low = cast(uint)(val - tmp * 100_000_000);
    const hgh = cast(uint)(tmp / 10_000);
    const mid = cast(uint)(tmp - cast(ulong) hgh * 10_000);
    buf = writeU32Len5to8(hgh, buf);
    buf = writeU32Len4(mid, buf);
    return writeU32Len8(low, buf);
}

private char* writeU64Len1to17(ulong val, char* buf) @system pure nothrow @nogc
{
    if (val >= 100_000_000UL * 10_000_000) // 16-17 digits
    {
        const hgh = val / 100_000_000;
        const low = cast(uint)(val - hgh * 100_000_000);
        const one = cast(uint)(hgh / 100_000_000);
        const mid = cast(uint)(hgh - cast(ulong) one * 100_000_000);
        *buf = cast(char)('0' + one);
        buf += one > 0;
        buf = writeU32Len8(mid, buf);
        return writeU32Len8(low, buf);
    }
    if (val >= 100_000_000) // 9-15 digits
    {
        const hgh = val / 100_000_000;
        const low = cast(uint)(val - hgh * 100_000_000);
        buf = writeU32Len1to8(cast(uint) hgh, buf);
        return writeU32Len8(low, buf);
    }
    return writeU32Len1to8(cast(uint) val, buf);
}

/// 16-17 digits with trailing zeros trimmed (digits named abbccddeeffgghhii).
private char* writeU64Len16to17Trim(ulong val, char* buf) @system pure nothrow @nogc
{
    const abbccddee = cast(uint)(val / 100_000_000);
    const ffgghhii = cast(uint)(val - cast(ulong) abbccddee * 100_000_000);
    const abbcc = abbccddee / 10_000;
    const ddee = abbccddee - abbcc * 10_000;
    const abb = cast(uint)((cast(ulong) abbcc * 167_773) >> 24); // abbcc / 100
    const a = (abb * 41) >> 12; // abb / 100
    const bb = abb - a * 100;
    const cc = abbcc - abb * 100;
    buf[0] = cast(char)('0' + a);
    buf += a > 0;
    putPair(buf + 0, bb);
    putPair(buf + 2, cc);

    if (ffgghhii)
    {
        const dd = (ddee * 5243) >> 19;
        const ee = ddee - dd * 100;
        const ffgg = cast(uint)((cast(ulong) ffgghhii * 109_951_163) >> 40);
        const hhii = ffgghhii - ffgg * 10_000;
        const ff = (ffgg * 5243) >> 19;
        const gg = ffgg - ff * 100;
        putPair(buf + 4, dd);
        putPair(buf + 6, ee);
        putPair(buf + 8, ff);
        putPair(buf + 10, gg);
        if (hhii)
        {
            const hh = (hhii * 5243) >> 19;
            const ii = hhii - hh * 100;
            putPair(buf + 12, hh);
            putPair(buf + 14, ii);
            const tz = ii ? decTrailingZeros[ii] : decTrailingZeros[hh] + 2;
            return buf + 16 - tz;
        }
        const tz = gg ? decTrailingZeros[gg] : decTrailingZeros[ff] + 2;
        return buf + 12 - tz;
    }
    if (ddee)
    {
        const dd = (ddee * 5243) >> 19;
        const ee = ddee - dd * 100;
        putPair(buf + 4, dd);
        putPair(buf + 6, ee);
        const tz = ee ? decTrailingZeros[ee] : decTrailingZeros[dd] + 2;
        return buf + 8 - tz;
    }
    const tz = cc ? decTrailingZeros[cc]
        : decTrailingZeros[bb] + decTrailingZeros[cc];
    return buf + 4 - tz;
}

/// Exponent suffix in `e-324` … `e308`.
private char* writeF64Exp(int exp, char* buf) @system pure nothrow @nogc
{
    buf[0 .. 2] = "e-";
    buf += 2 - (exp >= 0);
    uint e = exp < 0 ? -exp : exp;
    if (e < 100)
    {
        const lz = e < 10;
        buf[0 .. 2] = digitPairs[e * 2 + lz .. e * 2 + lz + 2];
        return buf + 2 - lz;
    }
    const hi = (e * 656) >> 16; // e / 100
    const lo = e - hi * 100;
    buf[0] = cast(char)('0' + hi);
    putPair(buf + 1, lo);
    return buf + 3;
}

/// Number of trailing zero bits (defined for `x != 0`).
private int trailingZeros(ulong x) @safe pure nothrow @nogc
in (x != 0)
{
    import core.bitop : bsf;

    return bsf(x);
}

/**
Formats `value` into `buf` as the shortest decimal representation that
re-parses to the identical bits (round-to-nearest, ties-to-even), and
returns the number of characters written.

The notation follows ECMAScript `Number.prototype.toString()` with two
deviations (the yyjson conventions): `-0.0` keeps its sign, and integral
values keep a trailing `.0` so the text stays unambiguously
floating-point. Non-finite values render as `nan`, `inf`, and `-inf` —
callers with stricter grammars (JSON) must reject those upstream.

Runtime only (not CTFE-callable); needs `buf.length ≥ 40`.
*/
size_t formatShortestDouble(scope char[] buf, double value) @trusted pure nothrow @nogc
in (buf.length >= 40)
{
    enum sigMask = (1UL << 52) - 1;
    const raw = doubleToBits(value);
    const sigRaw = raw & sigMask;
    const expRaw = cast(uint)(raw >> 52) & 0x7FF;
    const sign = raw >> 63;

    char* start = &buf[0];
    char* p = start;

    if (expRaw == 0x7FF) // inf / nan
    {
        if (sigRaw)
        {
            buf[0 .. 3] = "nan";
            return 3;
        }
        if (sign)
        {
            buf[0 .. 4] = "-inf";
            return 4;
        }
        buf[0 .. 3] = "inf";
        return 3;
    }

    *p = '-';
    p += sign;

    if ((raw << 1) == 0) // ±0
    {
        p[0 .. 3] = "0.0";
        return (p - start) + 3;
    }

    ulong sigDec;
    int expDec;
    if (expRaw != 0) // normal
    {
        const sigBin = sigRaw | (1UL << 52);
        const expBin = cast(int) expRaw - 1023 - 52;

        // Small integral values: exact, render directly.
        if (-52 <= expBin && expBin <= 0 && trailingZeros(sigBin) >= -expBin)
        {
            p = writeU64Len1to16(sigBin >> -expBin, p);
            p[0 .. 2] = ".0";
            return (p - start) + 2;
        }

        f64ToDecimal(sigRaw, expRaw, sigBin, expBin, sigDec, expDec);

        const int sigLen = 16 + (sigDec >= 100_000_000UL * 100_000_000);
        const int dotOfs = sigLen + expDec; // decimal point vs first digit

        if (-6 < dotOfs && dotOfs <= 21) // plain notation
        {
            // Zero-fill first: the fill provides both the "0.000…" prefix
            // and the zeros between trimmed digits and the dot (e.g. 1e20
            // renders one digit but needs "100000000000000000000.0").
            p[0 .. 32] = '0';

            const noPreZero = dotOfs > 0; // 1.234 / 1234.0 vs 0.001234
            const preOfs = noPreZero ? 0 : 2 - dotOfs;
            char* numHdr = p + preOfs;
            char* numEnd = writeU64Len16to17Trim(sigDec, numHdr);

            if (noPreZero) // open a one-byte gap for the dot
            {
                char* numSep = numHdr + dotOfs;
                char[16] tmp = numSep[0 .. 16];
                numSep[1 .. 17] = tmp;
                numEnd++;
            }
            p[noPreZero ? dotOfs : 1] = '.';

            char* dotEnd = p + dotOfs + 2; // covers the ".0" tail
            char* end = dotEnd > numEnd ? dotEnd : numEnd;
            return end - start;
        }
        else // scientific
        {
            char* end = writeU64Len16to17Trim(sigDec, p + 1);
            end -= end == p + 2; // "2." → "2" (drop lone trailing dot slot)
            expDec += sigLen - 1;
            p[0] = p[1];
            p[1] = '.';
            end = writeF64Exp(expDec, end);
            return end - start;
        }
    }
    else // subnormal — always scientific
    {
        f64ToDecimal(sigRaw, expRaw, sigRaw, 1 - 1023 - 52, sigDec, expDec);
        char* end = writeU64Len1to17(sigDec, p + 1);
        p[0] = p[1];
        p[1] = '.';
        expDec += cast(int)(end - p) - 2;
        while (end[-1] == '0')
            end--;
        end -= end[-1] == '.'; // "2.e-321" → "2e-321"
        end = writeF64Exp(expDec, end);
        return end - start;
    }
}

/**
Writes the shortest round-trip representation of `value` (see
$(LREF formatShortestDouble)) to any output range.
*/
void writeShortestDouble(Writer)(ref Writer w, double value)
{
    import std.range.primitives : put;

    char[40] buf = void;
    const len = formatShortestDouble(buf[], value);
    put(w, buf[0 .. len]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Cursor reader (general grammar; the JSON reader fuses its own loop)
// ─────────────────────────────────────────────────────────────────────────────

/**
Reads a decimal floating-point literal —
`[-]digits[.digits][(e|E)[±]digits]` — from the front of `s`, advancing
past it on success.

Inputs with more than 19 significant digits are decided by bracketing
(converting both the truncated significand and its successor — when both
round to the same `double`, that value is proven correct); everything the
fast tiers punt is settled exactly by $(LREF slowDouble). Every
well-formed literal therefore succeeds with the correctly-rounded value.
*/
ParseExpected!double readDecimalFloat(ref scope const(char)[] s)
    @safe pure nothrow @nogc
{
    const n = s.length;
    if (n == 0)
        return parseErr!double(ParseErrorCode.emptyInput, 0);

    size_t i = 0;
    bool negative = false;
    if (s[0] == '-')
    {
        negative = true;
        i = 1;
    }

    // Integer digits.
    const intStart = i;
    while (i < n && cast(uint)(s[i] - '0') <= 9)
        i++;
    const intEnd = i;
    if (intEnd == intStart)
        return parseErr!double(ParseErrorCode.unexpectedCharacter, i);

    // Fraction digits.
    size_t fracStart = 0, fracEnd = 0;
    if (i < n && s[i] == '.')
    {
        i++;
        fracStart = i;
        while (i < n && cast(uint)(s[i] - '0') <= 9)
            i++;
        fracEnd = i;
        if (fracEnd == fracStart)
            return parseErr!double(ParseErrorCode.unexpectedCharacter, i);
    }

    // Explicit exponent.
    int explicitExp = 0;
    if (i < n && (s[i] == 'e' || s[i] == 'E'))
    {
        i++;
        bool expNeg = false;
        if (i < n && (s[i] == '+' || s[i] == '-'))
        {
            expNeg = s[i] == '-';
            i++;
        }
        ulong e = 0;
        const eDigits = readDigits!10(s[i .. $], e);
        if (eDigits == 0)
            return parseErr!double(ParseErrorCode.unexpectedCharacter, i);
        i += eDigits;
        if (e > 400) // any further magnitude saturates identically
            e = 400;
        explicitExp = expNeg ? -cast(int) e : cast(int) e;
    }

    // Accumulate up to 19 significant digits across both runs (skipping
    // leading zeros), then derive the decimal exponent of the last taken
    // digit from its position — no incremental bookkeeping to get wrong.
    ulong sig = 0;
    size_t taken = 0;
    bool truncated = false;
    int exp10 = explicitExp;

    // First significant digit.
    size_t p = intStart;
    while (p < intEnd && s[p] == '0')
        p++;
    bool inFrac = p == intEnd && fracStart != 0;
    if (inFrac)
    {
        p = fracStart;
        while (p < fracEnd && s[p] == '0')
            p++;
    }

    if (!inFrac || p < fracEnd) // any significant digit at all?
    {
        bool lastInFrac = inFrac;
        size_t lastIdx = p;
        while (true)
        {
            const end = inFrac ? fracEnd : intEnd;
            while (p < end && taken < 19)
            {
                sig = sig * 10 + (s[p] - '0');
                lastInFrac = inFrac;
                lastIdx = p;
                taken++;
                p++;
            }
            if (p < end)
            {
                truncated = true; // significant digits beyond the budget
                break;
            }
            if (!inFrac && fracStart != 0)
            {
                p = fracStart;
                inFrac = true;
                continue;
            }
            break;
        }

        if (lastInFrac)
            exp10 -= cast(int)(lastIdx - fracStart + 1);
        else
            exp10 += cast(int)(intEnd - 1 - lastIdx);
    }

    double value;
    bool decided;
    if (!truncated)
        decided = tryFastDouble(sig, exp10, value);
    else
    {
        // Bracket the truncation: if sig and sig+1 round identically, the
        // in-between true value must round there too.
        double lowV, highV;
        decided = tryFastDouble(sig, exp10, lowV)
            && tryFastDouble(sig + 1, exp10, highV)
            && doubleToBits(lowV) == doubleToBits(highV);
        value = lowV;
    }
    if (!decided) // tier 3: exact, no preconditions
        value = slowDouble(s[intStart .. intEnd],
            fracStart == 0 ? null : s[fracStart .. fracEnd], explicitExp);

    s = s[i .. $];
    return parseOk(negative ? -value : value);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

@("float_conv.mul64x64.knownProducts")
unittest
{
    const p = mul64x64(ulong.max, ulong.max);
    assert(p.hi == 0xFFFF_FFFF_FFFF_FFFE && p.lo == 1);
    const q = mul64x64(1UL << 63, 2);
    assert(q.hi == 1 && q.lo == 0);
    // CTFE path must agree with the runtime path.
    enum ct = mul64x64(0x1234_5678_9ABC_DEF0, 0x0FED_CBA9_8765_4321);
    const rt = mul64x64(0x1234_5678_9ABC_DEF0, 0x0FED_CBA9_8765_4321);
    assert(ct.hi == rt.hi && ct.lo == rt.lo);
}

@("float_conv.doubleBits.roundTrip")
unittest
{
    foreach (d; [0.0, -0.0, 1.0, -1.5, 3.141592653589793, double.infinity,
            -double.infinity, double.min_normal, double.max,
            double.min_normal / 4]) // subnormal
        assert(bitsToDouble(doubleToBits(d)) is d);

    static assert(doubleToBits(1.5) == 0x3FF8_0000_0000_0000);
    static assert(bitsToDouble(0x3FF8_0000_0000_0000UL) == 1.5);
    static assert(bitsToDouble(1) == double.min_normal / (1UL << 52));
    static assert(doubleToBits(double.min_normal / (1UL << 52)) == 1);
}

@("float_conv.pow10Table.knownEntries")
unittest
{
    // 10^0 → 5^0 = 1 normalized: 2^127.
    const one = pow10Sig128[0 - tableMinExp10];
    assert(one.hi == 1UL << 63 && one.lo == 0);
    // 10^1 → 5 normalized: 0xA000…
    const ten = pow10Sig128[1 - tableMinExp10];
    assert(ten.hi == 0xA000_0000_0000_0000 && ten.lo == 0);
    // 10^-1 → the truncated 0xCCCC… reciprocal (no round-up: the yyjson
    // convention; the Schubfach writer applies its own +1).
    const tenth = pow10Sig128[-1 - tableMinExp10];
    assert(tenth.hi == 0xCCCC_CCCC_CCCC_CCCC);
    assert(tenth.lo == 0xCCCC_CCCC_CCCC_CCCC);
}

@("float_conv.readDigits.unrolledRuns")
unittest
{
    ulong sig = 0;
    assert(readDigits("12345x", sig) == 5);
    assert(sig == 12_345);

    sig = 0;
    assert(readDigits("18446744073709551615", sig) == 19); // caps at 19
    assert(sig == 1_844_674_407_370_955_161);

    sig = 7;
    assert(readDigits("5", sig) == 1); // continues an accumulation
    assert(sig == 75);

    sig = 0;
    assert(readDigits("", sig) == 0);
    assert(readDigits("x", sig) == 0);

    sig = 123;
    assert(readDigits("456789", sig, 3) == 3); // runtime budget
    assert(sig == 123_456);
}

@("float_conv.tryFastDouble.pins")
unittest
{
    static double conv(ulong sig, int exp)
    {
        double r;
        const ok = tryFastDouble(sig, exp, r);
        assert(ok, "tiers 1+2 must decide this pin");
        return r;
    }

    assert(conv(0, 0) is 0.0);
    assert(conv(1, 0) == 1.0);
    assert(conv(15, -1) == 1.5);
    assert(conv(1, 22) == 1e22);
    assert(conv(123_456_789, 0) == 123_456_789.0);
    assert(conv(1, 308) == 1e308);
    assert(conv(1, 309) == double.infinity); // saturation above the table
    assert(conv(1, -400) is 0.0); // saturation below the table
    assert(conv(17_976_931_348_623_157, 292) == double.max);
    assert(conv(1, -307) == 1e-307); // near the bottom of the normal range
    assert(conv(299_792_458, 0) == 299_792_458.0);
    assert(conv(602_214_076, 15) == 6.02214076e23);

    // Deliberate fast-tier punts (subnormals, true ties) — settled
    // exactly by slowDouble:
    double r;
    assert(!tryFastDouble(5, -324, r));
    assert(!tryFastDouble(9_007_199_254_740_993, 0, r));
}

@("float_conv.slowDouble.exactPins")
unittest
{
    // The smallest subnormal, exactly (5e-324 ≈ 2^-1074).
    assert(doubleToBits(slowDouble("5", null, -324)) == 1);
    assert(doubleToBits(slowDouble(null, "5", -323)) == 1); // "0.5e-323"
    // Below half the smallest subnormal → 0; above → rounds up to it.
    assert(slowDouble("2", null, -324) is 0.0);
    assert(doubleToBits(slowDouble("3", null, -324)) == 1);
    // 2^53 + 1 is a true tie → even (…992).
    assert(slowDouble("9007199254740993", null, 0) == 9_007_199_254_740_992.0);
    // 2^53 + 3 ties to even upward (…996).
    assert(slowDouble("9007199254740995", null, 0) == 9_007_199_254_740_996.0);
    // The infamous largest-subnormal constant (the "PHP hang" number)
    // 2.2250738585072011e-308 → the max subnormal bit pattern.
    assert(doubleToBits(slowDouble("2", "2250738585072011", -308))
        == 0x000F_FFFF_FFFF_FFFF);
    // Overflow saturates.
    assert(slowDouble("2", null, 308) == double.infinity);
    assert(slowDouble("17976931348623157", null, 292) == double.max);
    assert(slowDouble("17976931348623159", null, 292) == double.infinity);
    // Long exact expansions (the 767-digit case is what capacity covers):
    assert(slowDouble("1", null, 0) == 1.0);
    assert(slowDouble(null, "1", 0) == 0.1);
}

@("float_conv.tryFastDouble.ctfeMatchesRuntime")
unittest
{
    // The full tier chain runs at CTFE (tier 1 is skipped there, so the
    // integer tiers do all the work) and must produce results
    // bit-identical to the runtime path.
    static double conv(ulong sig, int exp)
    {
        double r;
        if (tryFastDouble(sig, exp, r))
            return r;
        // Punt → exact tier: render the significand digits.
        char[20] digits;
        size_t n = digits.length;
        for (ulong v = sig; v != 0; v /= 10)
            digits[--n] = cast(char)('0' + v % 10);
        return slowDouble(digits[n .. $], null, exp);
    }

    enum ctA = conv(314_159_265_358_979, -14);
    assert(doubleToBits(ctA) == doubleToBits(conv(314_159_265_358_979, -14)));
    enum ctB = conv(25, -1);
    assert(ctB == 2.5);
    enum ctC = conv(123_456_789_012_345_678, -30);
    assert(doubleToBits(ctC) == doubleToBits(conv(123_456_789_012_345_678, -30)));
    enum ctD = conv(9_007_199_254_740_993, 0); // true tie via slowDouble
    assert(ctD == 9_007_199_254_740_992.0);
}

@("float_conv.readDecimalFloat.grammar")
unittest
{
    static double read(string text)
    {
        const(char)[] s = text;
        auto r = readDecimalFloat(s);
        assert(r.hasValue, text);
        assert(s.length == 0, text);
        return r.value;
    }

    assert(read("0") is 0.0);
    assert(read("-0") is -0.0);
    assert(read("1.5") == 1.5);
    assert(read("-3.14159") == -3.14159);
    assert(read("1e10") == 1e10);
    assert(read("1E+10") == 1e10);
    assert(read("2.5e-3") == 2.5e-3);
    assert(read("1e999") == double.infinity);
    assert(read("-1e999") == -double.infinity);
    assert(read("1e-999") is 0.0);
    assert(read("0.000001") == 1e-6);
    assert(read("123456789012345678901234567890") == 1.2345678901234568e29);
    assert(read("0.3") == 0.3);

    // The canonical halfway literal: the fast tiers punt it, the exact
    // tier settles it (ties to even → the …611392 neighbor).
    assert(doubleToBits(read("1e23")) == 0x44B5_2D02_C7E1_4AF6);

    const(char)[] s = "1.5rest";
    assert(readDecimalFloat(s).value == 1.5);
    assert(s == "rest");

    const(char)[] bad = "x";
    assert(readDecimalFloat(bad).hasError);
    const(char)[] dot = "1.";
    assert(readDecimalFloat(dot).hasError); // digits required after '.'
    const(char)[] noExp = "1e";
    assert(readDecimalFloat(noExp).hasError);
}

@("float_conv.formatShortestDouble.pins")
@safe pure nothrow @nogc
unittest
{
    static void check(double v, string expected) @safe pure nothrow @nogc
    {
        import sparkles.base.lifetime : recycledErrorInstance;
        import core.exception : AssertError;

        char[40] buf = void;
        const len = formatShortestDouble(buf[], v);
        if (buf[0 .. len] != expected)
            throw (() @trusted => recycledErrorInstance!AssertError(
                "formatShortestDouble mismatch"))();
    }

    check(0.0, "0.0");
    check(-0.0, "-0.0");
    check(1.0, "1.0");
    check(-1.0, "-1.0");
    check(1.5, "1.5");
    check(0.1, "0.1");
    check(0.3, "0.3");
    check(1234.0, "1234.0");
    check(3.141592653589793, "3.141592653589793");
    check(1e20, "100000000000000000000.0");
    check(1e21, "1e21");
    check(1e22, "1e22");
    check(123.456, "123.456");
    check(0.000001, "0.000001");
    check(1e-7, "1e-7");
    check(-2.5e-3, "-0.0025");
    check(double.max, "1.7976931348623157e308");
    check(double.min_normal, "2.2250738585072014e-308");
    check(bitsToDouble(1), "5e-324"); // smallest subnormal
    check(bitsToDouble(0x000F_FFFF_FFFF_FFFF), "2.225073858507201e-308");
    check(9007199254740992.0, "9007199254740992.0"); // 2^53
    check(double.infinity, "inf");
    check(-double.infinity, "-inf");
    check(double.nan, "nan");
    check(1.0 / 3.0, "0.3333333333333333");
    check(2.0 / 3.0, "0.6666666666666666");
    check(6.02214076e23, "6.02214076e23");
    check(1.5e-9, "1.5e-9");
}

@("float_conv.formatShortestDouble.roundTripCorpus")
@safe unittest
{
    // The self-oracle: format → exact parse → identical bits, over random
    // bit patterns spanning every exponent regime (subnormals included).
    ulong state = 0xDEAD_BEEF_CAFE_F00D;
    ulong next()
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return state;
    }

    char[40] buf = void;
    foreach (i; 0 .. 100_000)
    {
        ulong bits = next();
        if (((bits >> 52) & 0x7FF) == 0x7FF)
            bits &= ~(0x7FFUL << 52); // skip inf/nan: force a finite exponent
        // Weight some iterations toward subnormals and tiny exponents.
        if (i % 7 == 0)
            bits &= ~(0x7F0UL << 52);
        const v = bitsToDouble(bits);

        const len = (() @trusted => formatShortestDouble(buf[], v))();
        const(char)[] text = buf[0 .. len];
        auto back = readDecimalFloat(text);
        assert(back.hasValue);
        assert(text.length == 0); // fully consumed
        assert(doubleToBits(back.value) == bits);
    }
}

version (linux)
@("float_conv.formatShortestDouble.shortestVsPrintf")
@system unittest
{
    import core.stdc.stdio : snprintf;

    // Shortest-ness spot check: for every value, no representation with
    // fewer significant digits may round-trip (compare against %.*g).
    ulong state = 0x0123_4567_89AB_CDEF;
    ulong next()
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return state;
    }

    char[64] ours = void, theirs = void;
    foreach (i; 0 .. 2_000)
    {
        ulong bits = next();
        if (((bits >> 52) & 0x7FF) == 0x7FF)
            bits &= ~(0x7FFUL << 52);
        const v = bitsToDouble(bits);
        const len = formatShortestDouble(ours[], v);

        // Count significant digits: the digit string before any exponent,
        // with leading and trailing zeros stripped (neither carries
        // round-trip information — "1e20" renders as "1000…0.0").
        char[24] digits = void;
        size_t nd;
        foreach (c; ours[0 .. len])
        {
            if (c == 'e')
                break;
            if (c >= '0' && c <= '9')
                digits[nd++] = c;
        }
        size_t lead;
        while (lead < nd && digits[lead] == '0')
            lead++;
        while (nd > lead && digits[nd - 1] == '0')
            nd--;
        const sigDigits = nd - lead;

        // One digit fewer must NOT round-trip.
        if (sigDigits > 1 && v != 0)
        {
            const tlen = snprintf(theirs.ptr, theirs.length, "%.*g",
                cast(int)(sigDigits - 1), v);
            const(char)[] ttext = theirs[0 .. tlen];
            auto back = readDecimalFloat(ttext);
            assert(back.hasValue);
            assert(doubleToBits(back.value) != bits,
                "a shorter representation round-trips — not shortest");
        }
    }
}

version (linux)
@("float_conv.readDecimalFloat.differentialVsStrtod")
@system unittest
{
    import core.stdc.stdlib : strtod;
    import core.stdc.stdio : snprintf;

    // Deterministic xorshift corpus: random (sig, exp) pairs rendered as
    // text; glibc strtod is the correctly-rounded oracle.
    ulong state = 0x9E37_79B9_7F4A_7C15;
    static ulong next(ref ulong s)
    {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return s;
    }

    char[64] buf;
    foreach (iter; 0 .. 20_000)
    {
        const sig = next(state) >> (next(state) % 40); // vary digit counts
        const exp = cast(int)(next(state) % 691) - 345; // hits both saturations
        const len = snprintf(buf.ptr, buf.length, "%llue%d", sig, exp);
        const(char)[] text = buf[0 .. len];

        auto ours = readDecimalFloat(text);
        assert(ours.hasValue); // with tier 3, every literal resolves
        const oracle = strtod(buf.ptr, null);
        assert(doubleToBits(ours.value) == doubleToBits(oracle));
    }
}
