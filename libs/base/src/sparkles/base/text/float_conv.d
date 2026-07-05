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

/// Full 64×64 → 128-bit unsigned multiply. CTFE-compatible; LLVM folds
/// this standard four-multiply decomposition into a single widening `mul`
/// (bare `ucent` is deprecated as of D 2.111).
U128 mul64x64(ulong a, ulong b) @safe pure nothrow @nogc
{
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

/// The exponent range with a defined table entry. Outside it the value
/// saturates regardless of a ≤19-digit significand: `sig × 10^-343 <
/// 2^-1075` rounds to zero, `sig × 10^309 > double.max` to infinity.
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
    const lz = leadingZeros(sig10);
    const w = sig10 << lz;

    // floor(exp10 × log2(10)) by fixed-point multiply: 217706 / 2^16.
    const long retExp2Base = ((217_706 * cast(long) exp10) >> 16) + 64 + 1023;
    long retExp2 = retExp2Base - lz;

    const entry = pow10Sig128[exp10 - minExp10];
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
For each `q` in `[minExp10, maxExp10]`: the top 128 bits of the binary
expansion of `10^q`, normalized to `[2^127, 2^128)`. Positive powers are
truncated; negative powers (infinite binary expansions) are rounded up —
the reference Eisel–Lemire convention. The power-of-two factor lives in
the exponent formula.

Generated at CTFE by exact big-integer arithmetic (`5^|q|` grows to ~800
bits).
*/
private static immutable Pow10Entry[maxExp10 - minExp10 + 1] pow10Sig128 =
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

/// `ceil(2^(bitLength(d) + 127) / d)` as 128 normalized bits — restoring
/// long division producing one quotient bit per step.
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

    bool nonZeroRem = false;
    foreach (limb; rem)
        if (limb)
        {
            nonZeroRem = true;
            break;
        }
    if (nonZeroRem) // round up (cannot overflow past 2^128 for d = 5^q > 1)
    {
        lo += 1;
        if (lo == 0)
            hi += 1;
    }
    return Pow10Entry(hi, lo);
}

private Pow10Entry[maxExp10 - minExp10 + 1] generatePow10Table() @safe pure nothrow
{
    Pow10Entry[maxExp10 - minExp10 + 1] table;

    // q ≥ 0: top 128 bits of 5^q (10^q = 5^q × 2^q).
    uint[] pow5 = [1u];
    foreach (q; 0 .. maxExp10 + 1)
    {
        table[q - minExp10] = bigTop128(pow5);
        pow5 = bigMulSmall(pow5, 5);
    }

    // q < 0: normalized, rounded-up 128-bit reciprocal of 5^|q|.
    pow5 = [5u];
    foreach (q; 1 .. -minExp10 + 1)
    {
        table[-q - minExp10] = bigReciprocal128(pow5);
        pow5 = bigMulSmall(pow5, 5);
    }

    return table;
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
round to the same `double`, that value is proven correct). The rare inputs
only the exact big-integer tier can settle report `numericOverflow` until
`slowDouble` lands (tier 3, next milestone).
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
    if (!decided)
        return parseErr!double(ParseErrorCode.numericOverflow, 0,
            "value requires the exact conversion tier");

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
    const one = pow10Sig128[0 - minExp10];
    assert(one.hi == 1UL << 63 && one.lo == 0);
    // 10^1 → 5 normalized: 0xA000…
    const ten = pow10Sig128[1 - minExp10];
    assert(ten.hi == 0xA000_0000_0000_0000 && ten.lo == 0);
    // 10^-1 → the classic 0xCCCC…CD rounded-up reciprocal.
    const tenth = pow10Sig128[-1 - minExp10];
    assert(tenth.hi == 0xCCCC_CCCC_CCCC_CCCC);
    assert(tenth.lo == 0xCCCC_CCCC_CCCC_CCCD);
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

    // Deliberate punts — decided by the exact tier in the next milestone:
    // subnormals, and true ties like 2^53 + 1 (must round to even …992).
    double r;
    assert(!tryFastDouble(5, -324, r));
    assert(!tryFastDouble(9_007_199_254_740_993, 0, r));
}

@("float_conv.tryFastDouble.ctfeMatchesRuntime")
unittest
{
    // The CTFE path (pure integer Eisel–Lemire) must produce bit-identical
    // results to the runtime tiers.
    static double conv(ulong sig, int exp)
    {
        double r;
        const ok = tryFastDouble(sig, exp, r);
        assert(ok);
        return r;
    }

    enum ctA = conv(314_159_265_358_979, -14);
    assert(doubleToBits(ctA) == doubleToBits(conv(314_159_265_358_979, -14)));
    enum ctB = conv(25, -1);
    assert(ctB == 2.5);
    enum ctC = conv(123_456_789_012_345_678, -30);
    assert(doubleToBits(ctC) == doubleToBits(conv(123_456_789_012_345_678, -30)));
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

    // The canonical halfway literal 1e23 punts to the exact tier (next
    // milestone) — it must fail loudly rather than round wrongly.
    const(char)[] halfway = "1e23";
    assert(readDecimalFloat(halfway).hasError);

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
    size_t settled;
    foreach (iter; 0 .. 20_000)
    {
        const sig = next(state) >> (next(state) % 40); // vary digit counts
        const exp = cast(int)(next(state) % 641) - 320;
        const len = snprintf(buf.ptr, buf.length, "%llue%d", sig, exp);
        const(char)[] text = buf[0 .. len];

        auto ours = readDecimalFloat(text);
        if (ours.hasError)
            continue; // needs tier 3 (exact); not a correctness failure
        settled++;
        const oracle = strtod(buf.ptr, null);
        assert(doubleToBits(ours.value) == doubleToBits(oracle));
    }
    // The fast tiers must settle the overwhelming majority.
    assert(settled > 19_000);
}
