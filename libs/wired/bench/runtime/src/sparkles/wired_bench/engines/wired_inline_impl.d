// GENERATED FILE — DO NOT EDIT.
// Regenerate with: dub run --single tools/gen-wired-inline.d
//
// A single-translation-unit copy of the `sparkles:wired` native JSON
// reader and the `sparkles:base` primitives it calls, spliced together
// so every seam is intra-module and LDC's inliner sees the whole kernel
// at once. Backs the `wired-inline` bench engine, whose only difference
// from `wired-native` is that this code is all in one module — the A/B
// that isolates inlining from cross-module-inlining, LTO and PGO.
//
// Sources are copied verbatim (module headers, imports of the absorbed
// modules, and unittest blocks removed). Edit the originals, not this.
module sparkles.wired_bench.engines.wired_inline_impl;

import expected : Expected, err, ok;
import std.experimental.allocator.common : stateSize;
import std.experimental.allocator.mallocator : Mallocator;

// ═════════════════════════════════════════════════════════════════════════
// From libs/base/src/sparkles/base/text/errors.d
// ═════════════════════════════════════════════════════════════════════════



/// Machine-readable, scheme-agnostic text-parse error code.
enum ParseErrorCode
{
    emptyInput,          /// nothing to parse
    unexpectedCharacter, /// a character not allowed at this position
    unexpectedEnd,       /// input ended while more was required
    leadingZero,         /// a numeric field had a disallowed leading zero
    numericOverflow,     /// a number exceeded the target type's range
    invalidIdentifier,   /// an identifier contained a disallowed character
    unknownValue,        /// a token matched no value in a known (closed) set
    widthMismatch,       /// a fixed-width field did not meet its width
    nonCanonicalTrailing,/// unused trailing bits in a final encoded group were not zero
    paddingMismatch,     /// padding count did not match the final encoded group's length
    invalidEscape,       /// a string escape sequence was malformed
    invalidSurrogate,    /// a UTF-16 surrogate escape was lone or mispaired
    invalidUtf8,         /// a byte sequence was not well-formed UTF-8
    depthExceeded,       /// nesting exceeded the parser's depth limit
    trailingContent,     /// input continued after a complete value
    outOfMemory,         /// the parser's allocator failed
}

/// Structured parse error: a $(LREF ParseErrorCode) plus the byte offset
/// (within the input the failing parser received) of the failure.
struct ParseError
{
    ParseErrorCode code; /// what went wrong
    size_t offset;       /// byte offset of the failure
    /// optional borrowed detail (typically a CTFE literal, e.g.
    /// `"expected one of: a, b, c"`)
    string context = null;
}

/**
`expected` hook that keeps $(LREF ParseExpected) usable in
`@nogc nothrow` code: it disables the default constructor so a result is
always explicitly `ok` or `err`, never an ambiguous default.
*/
struct NoGcHook
{
    static immutable bool enableDefaultConstructor = false;
}

/// `Expected!` specialised for $(LREF ParseError): carries either a parsed
/// `T` or a structured $(LREF ParseError).
alias ParseExpected(T) = Expected!(T, ParseError, NoGcHook);

/// Constructs a successful $(LREF ParseExpected) carrying `value`, filling
/// in the `(ParseError, NoGcHook)` template arguments — a parser writes
/// `return parseOk(value);` rather than `ok!(ParseError, NoGcHook)(value)`.
ParseExpected!T parseOk(T)(T value) @safe pure nothrow @nogc
    => ok!(ParseError, NoGcHook)(value);

/// ditto — success with no payload (`ParseExpected!void`), for validators.
/// (Explicitly attributed: as a non-template it cannot infer them.)
ParseExpected!void parseOk() @safe pure nothrow @nogc
    => ok!(ParseError, NoGcHook)();

/// Constructs a failed $(LREF ParseExpected)`!T` carrying `error`. `T` is
/// explicit (there is no value to infer it from):
/// `return parseErr!uint(someError);`
ParseExpected!T parseErr(T)(ParseError error) @safe pure nothrow @nogc
    => err!(T, NoGcHook)(error);

/// ditto — the common `code` + `offset` form:
/// `return parseErr!T(ParseErrorCode.numericOverflow, i);`
ParseExpected!T parseErr(T)(ParseErrorCode code, size_t offset) @safe pure nothrow @nogc
    => err!(T, NoGcHook)(ParseError(code, offset));

/// ditto — `code` + `offset` + a borrowed `context` detail (typically a CTFE
/// literal so the call stays `@nogc`):
/// `return parseErr!T(ParseErrorCode.unknownValue, 0, msg);`
ParseExpected!T parseErr(T)(ParseErrorCode code, size_t offset, string context) @safe pure nothrow @nogc
    => err!(T, NoGcHook)(ParseError(code, offset, context));




// ═════════════════════════════════════════════════════════════════════════
// From libs/base/src/sparkles/base/text/float_conv.d
// ═════════════════════════════════════════════════════════════════════════



// ─────────────────────────────────────────────────────────────────────────────
// Bit and wide-multiply kernels
// ─────────────────────────────────────────────────────────────────────────────

/**
The IEEE-754 bit pattern of `d` (CTFE-safe).

Declared as a template with an empty parameter list — not for genericity,
but so the body is instantiated in the *caller's* translation unit. As a
plain function it lives only in this package's object file, and a consumer
cannot inline a one-`movq` reinterpretation without
`-enable-cross-module-inlining` (which is not a flag a library can require
of its users). Measured on the wired JSON reader's number kernel: this and
its neighbours below are worth ~5 % of retired instructions on a
float-heavy parse — see
$(LINK2 ../../../../docs/specs/wired/bench-baseline.md, the wired bench baseline).
*/
ulong doubleToBits()(double d) @trusted pure nothrow @nogc
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
/// Templated for caller-side instantiation, as $(LREF doubleToBits).
double bitsToDouble()(ulong bits) @trusted pure nothrow @nogc
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
/// to the smallest subnormal are representable). Templated so it follows
/// $(LREF bitsToDouble) into the caller's translation unit.
private double pow2()(int e) @safe pure nothrow @nogc
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
U128 mul64x64()(ulong a, ulong b) @safe pure nothrow @nogc
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
/// Templated for caller-side instantiation, as $(LREF doubleToBits).
private int leadingZeros()(ulong x) @safe pure nothrow @nogc
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

Templated (empty parameter list) so the whole fast path — this, $(LREF
eiselLemire) and $(LREF mul64x64) — is code-generated in the caller's
translation unit and can fold into a number-scanning loop. See
$(LREF doubleToBits).
*/
bool tryFastDouble()(ulong sig10, int exp10, out double result)
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
private bool eiselLemire()(ulong sig10, int exp10, out double result)
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


// ═════════════════════════════════════════════════════════════════════════
// From libs/base/src/sparkles/base/text/utf8.d
// ═════════════════════════════════════════════════════════════════════════



/**
Returns the index of the first byte of the first ill-formed UTF-8 sequence
in `s`, or `s.length` when the whole slice is well-formed.

Scalar implementation: a word-at-a-time ASCII skip and a pairwise 3-byte
lane (two adjacent lead+continuation+continuation shapes validated with a
single masked compare on one u64 load — the dominant pattern in CJK
text), then per-sequence validation — the common lead classes check both
continuations with one 16-bit masked compare; only the window-constrained
leads (`E0 ED F0 F4`) branch to exact range checks. (A DFA was measured
slower here: its serial load-to-load dependency loses to well-predicted
branches.)
*/
size_t indexOfInvalidUtf8(scope const(char)[] s) @safe pure nothrow @nogc
{
    const n = s.length;
    size_t i = 0;

    while (i < n)
    {
        // Word lanes: skip 8 ASCII bytes or two unconstrained 3-byte
        // sequences per iteration.
        if (!__ctfe)
        {
            while (i + 8 <= n)
            {
                const word = (() @trusted {
                    import core.stdc.string : memcpy;

                    ulong w;
                    memcpy(&w, s.ptr + i, 8);
                    return w;
                })();
                if (!(word & 0x8080_8080_8080_8080))
                {
                    i += 8;
                    continue;
                }
                // Pairwise 3-byte lane: bytes 0..5 shaped as two
                // lead(E0..EF) + continuation + continuation sequences in
                // one masked compare. Only the unconstrained leads
                // (E1..EC, EE, EF) qualify; E0/ED (overlong/surrogate
                // windows) fall through to the exact checks below.
                if ((word & 0x0000_C0C0_F0C0_C0F0) == 0x0000_8080_E080_80E0)
                {
                    const b0 = cast(ubyte) word;
                    const b3 = cast(ubyte)(word >> 24);
                    if (b0 != 0xE0 && b0 != 0xED && b3 != 0xE0 && b3 != 0xED)
                    {
                        i += 6;
                        continue;
                    }
                }
                break;
            }
        }
        if (i >= n)
            break;

        const c = s[i];
        if (c < 0x80)
        {
            i++;
            continue;
        }
        const len = utf8SequenceLength(s, i);
        if (len == 0)
            return i;
        i += len;
    }
    return n;
}

/**
Validates the single UTF-8 sequence whose lead byte sits at `s[i]`
(`s[i] ≥ 0x80`) and returns its byte length (2–4), or `0` when the
sequence is ill-formed or truncated. The shortest-form, surrogate, and
U+10FFFF constraints are folded into the second-byte window
(Unicode Table 3-7). Building block for scanners that validate strings
inline (e.g. the wired JSON reader's string lanes).
*/
size_t utf8SequenceLength(scope const(char)[] s, size_t i) @safe pure nothrow @nogc
in (i < s.length && s[i] >= 0x80)
{
    pragma(inline, true);
    const n = s.length;
    const c = s[i];

    if (c >= 0xC2 && c <= 0xDF) // 2-byte
    {
        if (n - i <= 1 || (s[i + 1] & 0xC0) != 0x80)
            return 0;
        return 2;
    }
    if (c >= 0xE0 && c <= 0xEF) // 3-byte
    {
        if (n - i <= 2)
            return 0;
        // Both continuations in one masked compare; the constrained
        // leads (E0: no overlongs, ED: no surrogates) take exact checks.
        const uint w = s[i + 1] | (uint(s[i + 2]) << 8);
        if ((w & 0xC0C0) != 0x8080)
            return 0;
        if (c == 0xE0 && s[i + 1] < 0xA0)
            return 0;
        if (c == 0xED && s[i + 1] > 0x9F)
            return 0;
        return 3;
    }
    if (c >= 0xF0 && c <= 0xF4) // 4-byte
    {
        if (n - i <= 3)
            return 0;
        const uint w = s[i + 1] | (uint(s[i + 2]) << 8) | (uint(s[i + 3]) << 16);
        if ((w & 0xC0C0C0) != 0x808080)
            return 0;
        if (c == 0xF0 && s[i + 1] < 0x90) // overlongs
            return 0;
        if (c == 0xF4 && s[i + 1] > 0x8F) // above U+10FFFF
            return 0;
        return 4;
    }
    return 0; // 0x80..0xC1 (bare continuation / overlong lead), 0xF5..0xFF
}

/**
Validates that `s` is well-formed UTF-8; an error carries
`ParseErrorCode.invalidUtf8` with the offset of the offending sequence's
first byte.
*/
ParseExpected!void validateUtf8(scope const(char)[] s) @safe pure nothrow @nogc
{
    const i = indexOfInvalidUtf8(s);
    if (i == s.length)
        return parseOk();
    return parseErr!void(ParseErrorCode.invalidUtf8, i);
}


// ═════════════════════════════════════════════════════════════════════════
// From libs/wired/src/sparkles/wired/json/document.d
// ═════════════════════════════════════════════════════════════════════════



/// The dynamic type of a JSON value in a parsed document.
enum JsonKind : ubyte
{
    none, /// default-constructed / invalid view
    null_, /// JSON `null`
    bool_, /// `true` / `false`
    integer, /// integer-shaped number that fits `long`
    uinteger, /// integer-shaped number that fits only `ulong`
    floating, /// number with fraction/exponent (or saturated overflow)
    string_, /// string (unescaped, NUL-terminated in the pool)
    rawNumber, /// verbatim number token (`JsonReadOptions.rawNumbers`)
    array, /// JSON array
    object, /// JSON object
}

/**
One 16-byte arena cell: a tag (kind in the low 8 bits, size — string
byte length or container member count — in the high 56) and an 8-byte
payload.
*/
package struct JsonCell
{
    ulong tag;
    /// The 8-byte payload, kind-dependent: i64/u64/f64 scalar bits, a
    /// pool pointer (strings), or the container extent. Stored as plain
    /// bits — a union with a pointer member would make every access
    /// `@system`; instead the few pointer reinterpretations live in
    /// small `@trusted` kernels.
    ulong bits;

    this(JsonKind kind, ulong size = 0) @safe pure nothrow @nogc
    {
        tag = kind | (size << 8);
    }

    JsonKind kind() const @safe pure nothrow @nogc
        => cast(JsonKind)(tag & 0xFF);

    /// String byte length or container member count.
    ulong size() const @safe pure nothrow @nogc
        => tag >> 8;

    /// Cells to the next sibling, this cell included.
    size_t extent() const @safe pure nothrow @nogc
    {
        const k = kind;
        return k == JsonKind.array || k == JsonKind.object
            ? cast(size_t) bits : 1;
    }

    /// The pool bytes of a string/rawNumber cell.
    const(char)[] text() const @trusted pure nothrow @nogc
    in (kind == JsonKind.string_ || kind == JsonKind.rawNumber)
        => (cast(immutable(char)*) bits)[0 .. size];
}

static assert(JsonCell.sizeof == 16);

/**
An owning, non-copyable, movable parsed JSON document (SPEC §11.2).

`Allocator` supplies both blocks (cell arena + string pool). The
document stores block slices (client-tracked sizes — the untyped `void[]`
protocol) and frees them in the destructor when the allocator supports
`deallocate`; under an arena parent (e.g. `Region`) the individual frees
may no-op and the region reclaims wholesale.
*/
struct JsonDocument(Allocator = Mallocator)
{
    static if (stateSize!Allocator)
        package Allocator alloc;
    else
        package alias alloc = Allocator.instance;

    package JsonCell[] cells; /// allocated arena (capacity)
    package size_t cellCount; /// cells in use, root first
    package char[] pool; /// string pool (padded input copy)

    @disable this(this);

    /// Move-assignment (by-value parameter = rvalues only, since copying
    /// is disabled): swap ownership; the temporary's destructor frees the
    /// previous blocks.
    void opAssign(JsonDocument rhs)
    {
        import std.algorithm.mutation : swap;

        static if (stateSize!Allocator)
            swap(alloc, rhs.alloc);
        swap(cells, rhs.cells);
        swap(cellCount, rhs.cellCount);
        swap(pool, rhs.pool);
    }

    /// Whether the document holds a parsed value.
    bool valid() const @safe pure nothrow @nogc
        => cellCount != 0;

    /// The root value; its lifetime (and that of every view and string
    /// slice reached through it) is bound to this document.
    JsonValue root() const return scope @trusted pure nothrow @nogc
    in (valid, "empty document has no root")
        => JsonValue(&cells[0]);

    ~this()
    {
        static if (__traits(hasMember, Allocator, "deallocate"))
        {
            if (cells.length)
                () @trusted { alloc.deallocate(cast(void[]) cells); }();
            if (pool.length)
                () @trusted { alloc.deallocate(cast(void[]) pool); }();
        }
        cells = null;
        pool = null;
        cellCount = 0;
    }

    // ── package construction interface (used by the reader) ──────────────

    /// Allocates the two blocks; returns false on allocator failure.
    /// The reader passes a worst-case `cellCapacity` (its appends carry
    /// no capacity checks); `goodAllocSize` slack is still claimed for
    /// the arena.
    package bool acquire(size_t cellCapacity, size_t poolBytes)
    {
        import std.experimental.allocator.common : goodAllocSize;

        const cellBytes = goodAllocSize(alloc, cellCapacity * JsonCell.sizeof);
        auto cellBlock = alloc.allocate(cellBytes);
        if (cellBlock is null)
            return false;
        auto poolBlock = alloc.allocate(poolBytes);
        if (poolBlock is null)
        {
            static if (__traits(hasMember, Allocator, "deallocate"))
                () @trusted { alloc.deallocate(cellBlock); }();
            return false;
        }
        cells = () @trusted {
            return (cast(JsonCell*) cellBlock.ptr)[0 .. cellBlock.length / JsonCell.sizeof];
        }();
        pool = () @trusted {
            return (cast(char*) poolBlock.ptr)[0 .. poolBlock.length];
        }();
        return true;
    }

}

/**
A borrowed, copyable, 8-byte view of one value in a document
(SPEC §11.2). Copying a view is free; the document must outlive every
view (`dip1000`-enforced from `root()` onward). Accessors carry
`in`-contracts on the dynamic kind; iteration is forward-only through
$(LREF byElement) / $(LREF byKeyValue) — element access is sequential by
design (the layout stores extents, not child pointers).
*/
struct JsonValue
{
    private const(JsonCell)* cell;

    static assert(JsonValue.sizeof == 8);

    /// The dynamic type (`JsonKind.none` for a default view).
    JsonKind kind() const scope @safe pure nothrow @nogc
        => cell is null ? JsonKind.none : (() @trusted => cell.kind)();

    /// `true`/`false` payload.
    bool boolean() const scope @trusted pure nothrow @nogc
    in (kind == JsonKind.bool_)
        => cell.bits != 0;

    /// Integer payload (`JsonKind.integer`).
    long integer() const scope @trusted pure nothrow @nogc
    in (kind == JsonKind.integer)
        => cast(long) cell.bits;

    /// Unsigned payload (`JsonKind.uinteger`: fits `ulong` but not `long`).
    ulong uinteger() const scope @trusted pure nothrow @nogc
    in (kind == JsonKind.uinteger)
        => cell.bits;

    /// Floating payload (`JsonKind.floating`).
    double floating() const scope @trusted pure nothrow @nogc
    in (kind == JsonKind.floating)
    {
        import sparkles.base.text.float_conv : bitsToDouble;

        return bitsToDouble(cell.bits);
    }

    /// Any number kind, converted to `double`.
    double asDouble() const scope @safe pure nothrow @nogc
    in (kind == JsonKind.integer || kind == JsonKind.uinteger
        || kind == JsonKind.floating)
    {
        final switch (kind) with (JsonKind)
        {
        case integer:
            return cast(double) this.integer;
        case uinteger:
            return cast(double) this.uinteger;
        case floating:
            return this.floating;
        case none, null_, bool_, string_, rawNumber, array, object:
            assert(false);
        }
    }

    /// String payload — unescaped; a NUL byte follows the slice in the
    /// document's pool. Borrowed from the document.
    const(char)[] str() const return scope @trusted pure nothrow @nogc
    in (kind == JsonKind.string_)
        => cell.text;

    /// Verbatim number token text (`JsonKind.rawNumber`).
    const(char)[] raw() const return scope @trusted pure nothrow @nogc
    in (kind == JsonKind.rawNumber)
        => cell.text;

    /// Array element count / object member count.
    size_t length() const scope @trusted pure nothrow @nogc
    in (kind == JsonKind.array || kind == JsonKind.object)
        => cast(size_t) cell.size;

    /// Forward range over an array's elements.
    JsonArrayRange byElement() const return scope @trusted pure nothrow @nogc
    in (kind == JsonKind.array)
        => JsonArrayRange(cell + 1, cast(size_t) cell.size);

    /// Forward range over an object's members (`JsonMember`s).
    JsonObjectRange byKeyValue() const return scope @trusted pure nothrow @nogc
    in (kind == JsonKind.object)
        => JsonObjectRange(cell + 1, cast(size_t) cell.size);

    /// The value under `key`, or a `JsonKind.none` view when absent —
    /// a linear scan (O(members)); prefer one `byKeyValue` pass over
    /// repeated lookups.
    JsonValue objectGet(scope const(char)[] key) const return scope @safe pure nothrow @nogc
    in (kind == JsonKind.object)
    {
        foreach (m; byKeyValue)
            if (m.key == key)
                return m.value;
        return JsonValue.init;
    }
}

/// One object member: the (unescaped, borrowed) key and the value view.
struct JsonMember
{
    const(char)[] key;
    JsonValue value;
}

/// Forward range over array elements (extent-hop walk).
struct JsonArrayRange
{
    private const(JsonCell)* cur;
    private size_t remaining;

    bool empty() const scope @safe pure nothrow @nogc => remaining == 0;

    JsonValue front() const return scope @safe pure nothrow @nogc
    in (!empty)
        => JsonValue(cur);

    void popFront() scope @trusted pure nothrow @nogc
    in (!empty)
    {
        cur += cur.extent;
        remaining--;
    }
}

/// Forward range over object members (key cell + value extent hops).
struct JsonObjectRange
{
    private const(JsonCell)* cur; // points at a key cell
    private size_t remaining;

    bool empty() const scope @safe pure nothrow @nogc => remaining == 0;

    JsonMember front() const return scope @trusted pure nothrow @nogc
    in (!empty)
    {
        assert(cur.kind == JsonKind.string_, "object key must be a string cell");
        return JsonMember(cur.text, JsonValue(cur + 1));
    }

    void popFront() scope @trusted pure nothrow @nogc
    in (!empty)
    {
        const valueCell = cur + 1;
        cur = valueCell + valueCell.extent;
        remaining--;
    }
}


// ═════════════════════════════════════════════════════════════════════════
// From libs/wired/src/sparkles/wired/json/scan.d
// ═════════════════════════════════════════════════════════════════════════


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

@safe pure nothrow @nogc package
{

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
*/
StringScan scanStringBody(bool validate = true)(
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
                static if (validate)
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
}

// ═════════════════════════════════════════════════════════════════════════
// From libs/wired/src/sparkles/wired/json/reader.d
// ═════════════════════════════════════════════════════════════════════════




/// Compile-time reader configuration (SPEC §11.3). Each combination
/// specializes the reader; dead option branches vanish.
struct JsonReadOptions
{
    bool rawNumbers = false; /// keep numbers as verbatim token text
    bool validateUtf8 = true; /// strict RFC 8259: reject ill-formed UTF-8
    uint maxDepth = 1024; /// nesting limit (`depthExceeded` beyond)

    // Declared, not yet implemented (SPEC §11.3):
    bool allowTrailingCommas = false; /// ditto
    bool allowComments = false; /// ditto
    bool allowInfNan = false; /// ditto
    bool insitu = false; /// ditto
    bool stopWhenDone = false; /// ditto
}

/// The outcome of a parse: the document, or a `ParseError` (byte offset
/// into the original input). Expected-shaped; the non-copyable document
/// forbids the `Expected` type itself.
struct JsonParseResult(Allocator = Mallocator)
{
    JsonDocument!Allocator document; /// valid iff `hasValue`
    ParseError error; /// meaningful iff `hasError`

    bool hasValue() const @safe pure nothrow @nogc => document.valid;
    /// ditto
    bool hasError() const @safe pure nothrow @nogc => !document.valid;
}

/**
Parses `text` into an arena document (SPEC §11.3). The input needs no
padding or NUL termination and is never modified. Attributes infer from
the allocator — over the `Mallocator` default the whole parse path is
`@safe pure nothrow @nogc`.
*/
JsonParseResult!Allocator parseJsonDocument(
    JsonReadOptions opts = JsonReadOptions.init, Allocator = Mallocator)(
    scope const(char)[] text)
if (stateSize!Allocator == 0)
{
    JsonParseResult!Allocator result;
    parseInto!opts(result, text);
    return result;
}

/// ditto — stateful allocators pass an instance (the store-the-allocator
/// rule: the document keeps it for its whole lifetime).
JsonParseResult!Allocator parseJsonDocument(
    JsonReadOptions opts = JsonReadOptions.init, Allocator)(
    scope const(char)[] text, Allocator alloc)
if (stateSize!Allocator != 0)
{
    import core.lifetime : move;

    JsonParseResult!Allocator result;
    result.document.alloc = move(alloc);
    parseInto!opts(result, text);
    return result;
}

private enum ulong maxCellSize = (1UL << 56) - 1;

/// Branch-expectation hint (folds away when the backend lacks it).
private pragma(inline, true) bool unlikely()(bool cond)
{
    import core.builtins : expect;

    return expect(cond, false);
}

/// Failure channel of the file-scope token kernels ($(LREF scanNumber),
/// $(LREF scanString)) — written only on the error path, so the hot
/// paths carry no stores for it.
private struct ScanError
{
    ParseErrorCode code;
    size_t offset;
    string context;
}

// ── number scanning (fused grammar + accumulation) ──────────────────────
// Standalone pointer kernel with a register-narrow interface (yyjson's
// read_number discipline): keeping it out of the grammar loop's nested
// scope keeps the loop's captured state out of the kernel's register
// allocation. `p` is the padded pool base — the ≥ 8 zero bytes
// terminate every digit run, so the hot loops carry no bounds checks
// (the same invariant as the scan seams). The parsed value cell is
// stored straight into `*cell`; returns the index just past the token,
// or 0 with `*err` filled on failure.
private size_t scanNumber(JsonReadOptions opts)(
    const(char)* p, size_t tokenStart, JsonCell* cell, ScanError* err) @system
{
    size_t k = tokenStart;
    bool negative = false;
    if (p[k] == '-')
    {
        negative = true;
        k++;
    }

    // Integer part (strict: no leading zeros, at least one digit).
    const intStart = k;
    ulong sig = 0;
    size_t taken = 0;
    if (p[k] == '0')
    {
        k++;
        taken = 1;
        if (unlikely(p[k] >= '0' && p[k] <= '9'))
        {
            *err = ScanError(ParseErrorCode.leadingZero, tokenStart);
            return 0;
        }
    }
    else
    {
        // Accumulate up to 19 digits: eight per SWAR gulp while the
        // budget allows (long ids), then unrolled two at a time.
        while (taken + 8 <= 18)
        {
            const w = loadWord(p + k);
            if (!allDigits8(w))
                break;
            sig = sig * 100_000_000 + eightDigits(w);
            taken += 8;
            k += 8;
        }
        while (taken < 18)
        {
            const uint d0 = cast(uint)(p[k] - '0');
            if (d0 > 9)
                break;
            const uint d1 = cast(uint)(p[k + 1] - '0');
            if (d1 > 9)
            {
                sig = sig * 10 + d0;
                taken++;
                k++;
                break;
            }
            sig = sig * 100 + d0 * 10 + d1;
            taken += 2;
            k += 2;
        }
        if (taken == 18)
        {
            const uint d = cast(uint)(p[k] - '0');
            if (d <= 9)
            {
                sig = sig * 10 + d;
                taken++;
                k++;
            }
        }
        if (taken == 0)
        {
            *err = ScanError(ParseErrorCode.unexpectedCharacter, k);
            return 0;
        }
    }
    // Integer digits beyond the 19-digit accumulator (cold).
    size_t intExtra = 0;
    while (unlikely(p[k] >= '0' && p[k] <= '9'))
    {
        intExtra++;
        k++;
    }
    const intEnd = k;

    // Fraction.
    size_t fracStart = 0, fracEnd = 0, fracTaken = 0;
    bool fracExtraNonzero = false;
    if (p[k] == '.')
    {
        k++;
        fracStart = k;
        if (intExtra == 0)
        {
            // The budget bound is hoisted so the loops carry a single
            // moving index.
            const fs = k;
            const budgetEnd = k + (19 - taken);
            // Eight fraction digits per SWAR gulp first — the dominant
            // shape in geo data (canada: 2-3 integer digits then 15-17
            // fraction digits).
            while (k + 8 <= budgetEnd)
            {
                const w = loadWord(p + k);
                if (!allDigits8(w))
                    break;
                sig = sig * 100_000_000 + eightDigits(w);
                k += 8;
            }
            // Tail (1–7 digits — the shape geo data always ends on: canada
            // is 15 fraction digits, so one gulp then a short remainder).
            // Padding the remainder to a full gulp keeps it on the SWAR
            // path: `padDigits8` appends `8 - n` decimal zeros, scaling
            // `sig` by that power of ten, and counting the padding as
            // consumed fraction digits subtracts the same power from
            // `exp10` — the value is unchanged and the scalar pair loop
            // disappears. Only worth it while the padded run still fits
            // the 19-digit significand budget.
            size_t padded = 0;
            const w = loadWord(p + k);
            const run = digitRun8(w);
            if (run != 0 && run < 8 && k + run <= budgetEnd
                && taken + (k - fs) + 8 <= 19)
            {
                sig = sig * 100_000_000 + eightDigits(padDigits8(w, run));
                k += run;
                padded = 8 - run;
            }
            else
            {
                while (k + 2 <= budgetEnd)
                {
                    const uint d0 = cast(uint)(p[k] - '0');
                    if (d0 > 9)
                        break;
                    const uint d1 = cast(uint)(p[k + 1] - '0');
                    if (d1 > 9)
                    {
                        sig = sig * 10 + d0;
                        k++;
                        break;
                    }
                    sig = sig * 100 + d0 * 10 + d1;
                    k += 2;
                }
                if (k < budgetEnd)
                {
                    const uint d = cast(uint)(p[k] - '0');
                    if (d <= 9)
                    {
                        sig = sig * 10 + d;
                        k++;
                    }
                }
            }
            // The padding rides in `fracTaken`: it feeds both the budget
            // (`taken`) and `exp10`, which is exactly where the appended
            // zeros must cancel. The raw digit slices handed to
            // `slowDouble` use `fracStart`/`fracEnd`, so the exact
            // fallback still sees the real digits.
            fracTaken = (k - fs) + padded;
            taken += fracTaken;
        }
        while (p[k] >= '0' && p[k] <= '9')
        {
            fracExtraNonzero |= p[k] != '0';
            k++;
        }
        fracEnd = k;
        if (fracEnd == fracStart)
        {
            *err = ScanError(ParseErrorCode.unexpectedCharacter, k,
                "digit required after decimal point");
            return 0;
        }
    }

    // Exponent.
    int explicitExp = 0;
    bool hasExp = false;
    if ((p[k] | 0x20) == 'e')
    {
        hasExp = true;
        k++;
        bool expNeg = false;
        if (p[k] == '+' || p[k] == '-')
        {
            expNeg = p[k] == '-';
            k++;
        }
        ulong e = 0;
        size_t eDigits = 0;
        while (eDigits < 10)
        {
            const uint d = cast(uint)(p[k] - '0');
            if (d > 9)
                break;
            e = e * 10 + d;
            eDigits++;
            k++;
        }
        if (eDigits == 0)
        {
            *err = ScanError(ParseErrorCode.unexpectedCharacter, k,
                "digit required in exponent");
            return 0;
        }
        while (p[k] >= '0' && p[k] <= '9') // absurd exponents saturate
            k++;
        if (e > 400)
            e = 400;
        explicitExp = expNeg ? -cast(int) e : cast(int) e;
    }

    static if (opts.rawNumbers)
    {
        *cell = JsonCell(JsonKind.rawNumber, k - tokenStart);
        cell.bits = cast(ulong)(p + tokenStart);
        return k;
    }
    else
    {
        const isInt = fracStart == 0 && !hasExp;
        if (isInt && intExtra == 0) // ≤19 digits: exact
        {
            if (!negative)
            {
                const kind = sig <= long.max
                    ? JsonKind.integer : JsonKind.uinteger;
                *cell = JsonCell(kind);
                cell.bits = sig;
                return k;
            }
            if (sig == 0) // "-0": preserve the sign (yyjson behavior)
            {
                *cell = JsonCell(JsonKind.floating);
                cell.bits = doubleToBits(-0.0);
                return k;
            }
            if (sig <= 1UL << 63) // down to long.min
            {
                *cell = JsonCell(JsonKind.integer);
                cell.bits = 0 - sig;
                return k;
            }
            // Below long.min: floating (≤19-digit ulong → double is a
            // single correct rounding).
            *cell = JsonCell(JsonKind.floating);
            cell.bits = doubleToBits(-cast(double) sig);
            return k;
        }
        if (isInt && intExtra == 1)
        {
            // The 20-digit u64 tail: one extra digit may still fit.
            const d = cast(uint)(p[intEnd - 1] - '0');
            if (sig < ulong.max / 10
                || (sig == ulong.max / 10 && d <= ulong.max % 10))
            {
                const wide = sig * 10 + d;
                const kind = negative ? JsonKind.floating
                    : wide <= long.max ? JsonKind.integer : JsonKind.uinteger;
                *cell = JsonCell(kind);
                cell.bits = negative
                    ? doubleToBits(-cast(double) wide) : wide;
                return k;
            }
        }

        // Floating path (fraction / exponent / oversized integer).
        // Conservative truncation: extra integer digits might be all
        // zeros (still exact), but claiming truncation just routes
        // through bracketing or slowDouble — exact either way.
        const truncated = intExtra != 0 || fracExtraNonzero;
        const exp10 = explicitExp + cast(int) intExtra - cast(int) fracTaken;

        double value;
        bool decided;
        if (!truncated)
            decided = tryFastDouble(sig, exp10, value);
        else
        {
            // Bracket: if sig and sig+1 round identically, the true
            // in-between value must round there too.
            double lowV, highV;
            decided = tryFastDouble(sig, exp10, lowV)
                && tryFastDouble(sig + 1, exp10, highV)
                && doubleToBits(lowV) == doubleToBits(highV);
            value = lowV;
        }
        if (!decided)
            value = slowDouble(p[intStart .. intEnd],
                fracStart == 0 ? null : p[fracStart .. fracEnd],
                explicitExp);

        *cell = JsonCell(JsonKind.floating);
        cell.bits = doubleToBits(negative ? -value : value);
        return k;
    }
}

// ── string scanning (shared by keys and values) ─────────────────────────
// Standalone kernel, same discipline as scanNumber: keeping it out of
// the grammar loop's nested scope keeps the loop's captured state out
// of the string lane's register allocation. `pool` is the padded
// mutable pool (content + 8 zero bytes; escapes unescape in place,
// dst ≤ src always). The string cell whose opening quote sits at
// `openQuote` is stored into `*cell`; returns the index just past the
// closing quote, or 0 with `*err` filled on failure.
private size_t scanString(JsonReadOptions opts)(
    scope char[] pool, size_t openQuote, JsonCell* cell, ScanError* err) @system
{
    const n = pool.length - 8; // content length; padding beyond
    size_t i = openQuote + 1; // past '"'
    const start = i;
    const scan = scanStringBody!(opts.validateUtf8)(pool, i);
    size_t j = scan.stop;
    if (unlikely(scan.invalidUtf8))
    {
        *err = ScanError(ParseErrorCode.invalidUtf8, j);
        return 0;
    }
    if (unlikely(j >= n))
    {
        *err = ScanError(ParseErrorCode.unexpectedEnd, openQuote);
        return 0;
    }
    if (pool[j] == '"') // fast lane: no escapes (and, when validating,
    { //                   already known to be well-formed UTF-8)
        pool[j] = '\0';
        *cell = JsonCell(JsonKind.string_, j - start);
        cell.bits = cast(ulong)(pool.ptr + start);
        return j + 1;
    }
    if (pool[j] != '\\')
    {
        *err = ScanError(ParseErrorCode.unexpectedCharacter, j,
            "control character inside string");
        return 0;
    }

    // Escape lane: unescape in place (dst ≤ src always); clean
    // segments between escapes move as one bulk copy over the same
    // SWAR scan as the fast lane.
    size_t dst = j;
    size_t src = j;
    while (true)
    {
        if (src >= n)
        {
            *err = ScanError(ParseErrorCode.unexpectedEnd, openQuote);
            return 0;
        }
        const c = pool[src];
        if (c == '"')
            break;
        if (c < 0x20)
        {
            *err = ScanError(ParseErrorCode.unexpectedCharacter, src,
                "control character inside string");
            return 0;
        }
        if (c != '\\')
        {
            // Bulk-move the clean run up to the next stop byte.
            // dst ≤ src and copying forward word-by-word is overlap-
            // safe for a leftward move; ≥8 padding bytes keep the
            // word loads in bounds. Escape-dense strings have tiny
            // segments — avoid the memmove call for them.
            const run = scanStringBody!(opts.validateUtf8)(pool, src);
            if (unlikely(run.invalidUtf8))
            {
                *err = ScanError(ParseErrorCode.invalidUtf8, run.stop);
                return 0;
            }
            const seg = run.stop - src;
            auto d = pool.ptr + dst;
            auto q = pool.ptr + src;
            if (src - dst >= 8)
            {
                // Word copies rounded up to 8: the ≤7-byte overshoot
                // lands in the dead zone between the shrunken
                // destination and the unconsumed source (gap ≥ 8
                // guarantees it), and pool padding keeps the loads in
                // bounds.
                size_t k = 0;
                do
                {
                    memcpyWord(d + k, q + k);
                    k += 8;
                }
                while (k < seg);
            }
            else
                foreach (k; 0 .. seg)
                    d[k] = q[k];
            dst += seg;
            src += seg;
            continue;
        }

        const escAt = src;
        src++;
        if (src >= n)
        {
            *err = ScanError(ParseErrorCode.unexpectedEnd, escAt);
            return 0;
        }
        const e = pool[src];
        src++;
        switch (e)
        {
        case '"', '\\', '/':
            pool[dst++] = e;
            break;
        case 'b':
            pool[dst++] = '\b';
            break;
        case 'f':
            pool[dst++] = '\f';
            break;
        case 'n':
            pool[dst++] = '\n';
            break;
        case 'r':
            pool[dst++] = '\r';
            break;
        case 't':
            pool[dst++] = '\t';
            break;
        case 'u':
            uint cp;
            if (!readHex4(pool, n, src, cp))
            {
                *err = ScanError(ParseErrorCode.invalidEscape, escAt);
                return 0;
            }
            if (cp >= 0xD800 && cp <= 0xDBFF) // high surrogate
            {
                if (src + 1 < n && pool[src] == '\\' && pool[src + 1] == 'u')
                {
                    src += 2;
                    uint low;
                    if (!readHex4(pool, n, src, low))
                    {
                        *err = ScanError(ParseErrorCode.invalidEscape, escAt);
                        return 0;
                    }
                    if (low < 0xDC00 || low > 0xDFFF)
                    {
                        *err = ScanError(ParseErrorCode.invalidSurrogate, escAt);
                        return 0;
                    }
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                }
                else
                {
                    *err = ScanError(ParseErrorCode.invalidSurrogate, escAt);
                    return 0;
                }
            }
            else if (cp >= 0xDC00 && cp <= 0xDFFF) // lone low surrogate
            {
                *err = ScanError(ParseErrorCode.invalidSurrogate, escAt);
                return 0;
            }
            dst += encodeUtf8(pool, dst, cp);
            break;
        default:
            *err = ScanError(ParseErrorCode.invalidEscape, escAt);
            return 0;
        }
    }
    // No trailing validation pass: every byte of the result came either
    // from a clean run (checked inside `scanStringBody` above) or from
    // `encodeUtf8`, which emits well-formed UTF-8 by construction — lone
    // surrogates are rejected in the `\u` case before they reach it.
    pool[dst] = '\0';
    *cell = JsonCell(JsonKind.string_, dst - start);
    cell.bits = cast(ulong)(pool.ptr + start);
    return src + 1; // past closing quote
}

private void parseInto(JsonReadOptions opts, Allocator)(
    ref JsonParseResult!Allocator result, scope const(char)[] text)
{
    static assert(!opts.allowTrailingCommas && !opts.allowComments
            && !opts.allowInfNan && !opts.insitu && !opts.stopWhenDone,
        "JsonReadOptions flag declared but not implemented yet (SPEC §11.3)");

    void fail(ParseErrorCode code, size_t offset, string context = null)
    {
        result.error = ParseError(code, offset, context);
        result.document.cellCount = 0;
    }

    if (text.length == 0)
    {
        fail(ParseErrorCode.emptyInput, 0);
        return;
    }

    // Worst-case cell bound — there is no growth path; appends in the
    // hot loop are checkless stores. Proof sketch: every cell's first
    // byte is distinct input (≤ 1 cell/byte), and among closed values
    // sibling cells are comma-separated while closed containers pair an
    // opener with a closer (≤ len/2 cells + 1 per still-open container,
    // and opens are capped at maxDepth before the next one appends).
    const worst = text.length / 2 + opts.maxDepth;
    const cellCapacity = (text.length < worst ? text.length : worst) + 4;

    if (!result.document.acquire(cellCapacity, text.length + 8))
    {
        fail(ParseErrorCode.outOfMemory, 0);
        return;
    }

    auto doc = () @trusted { return &result.document; }();
    auto pool = doc.pool;
    pool[0 .. text.length] = text[];
    pool[text.length .. text.length + 8] = '\0';

    const n = text.length; // content length; padding beyond
    size_t i = 0;

    // ── cell append / container machinery (threaded parent) ─────────────
    // Hot state lives in locals — stores through `pool` would otherwise
    // force conservative reloads of every document field on each append;
    // the document is synced on completion.
    auto cells = doc.cells;
    size_t cellCount = 0;

    enum size_t noParent = size_t.max;
    size_t parent = noParent;
    bool parentIsObject = false; // cells[parent].kind cached (hot loop)
    uint depth = 0;

    // The arena is pre-sized to the worst case (see cellCapacity), so
    // every append is a checkless store + bump — @trusted on that bound.
    size_t appendCell(JsonKind kind, ulong size = 0) @trusted
    {
        const idx = cellCount++;
        cells.ptr[idx] = JsonCell(kind, size);
        return idx;
    }

    // Appends a scalar cell with a u64/i64/f64 payload (always true —
    // the bool shape matches the grammar loop's return discipline).
    bool appendScalar(JsonKind kind, ulong payload) @trusted
    {
        const idx = cellCount++;
        cells.ptr[idx] = JsonCell(kind);
        cells.ptr[idx].bits = payload;
        return true;
    }

    bool appendStringCell(size_t start, size_t len,
        JsonKind kind = JsonKind.string_) @trusted
    {
        const idx = cellCount++;
        cells.ptr[idx] = JsonCell(kind, len);
        cells.ptr[idx].bits = cast(ulong)(pool.ptr + start);
        return true;
    }


    // String tokens go through the file-scope scanString kernel; the
    // shared rare-path error channel lives here so the hot call sites
    // carry no per-call initialization.
    ScanError serr;


    // ── literals ─────────────────────────────────────────────────────────
    bool parseLiteral(string lit)(JsonKind kind, ulong payload)
    {
        // One unaligned 32-bit compare ("true"/"null"/"alse" after 'f');
        // the zero padding makes the loads safe near the end.
        enum tail = lit.length == 5 ? lit[1 .. 5] : lit;
        enum uint word = tail[0] | tail[1] << 8 | tail[2] << 16
            | cast(uint) tail[3] << 24;
        const at = i + (lit.length == 5 ? 1 : 0);
        const got = (() @trusted {
            import core.stdc.string : memcpy;

            uint w;
            memcpy(&w, pool.ptr + at, 4);
            return w;
        })();
        if (got != word)
        {
            fail(ParseErrorCode.unexpectedCharacter, i);
            return false;
        }
        i += lit.length;
        return appendScalar(kind, payload);
    }

    // ── the grammar loop ─────────────────────────────────────────────────
    skipWs(pool, i);

value: // parse one value at pool[i]
    if (i >= n)
    {
        fail(ParseErrorCode.unexpectedEnd, i);
        return;
    }
    {
        const c0 = pool[i];
        if (c0 == '"') // most frequent first (string-heavy JSON)
        {
            const end = (() @trusted => scanString!opts(pool, i,
                cells.ptr + cellCount, &serr))();
            if (end == 0)
            {
                fail(serr.code, serr.offset, serr.context);
                return;
            }
            cellCount++;
            i = end;
            goto afterValue;
        }
        if (c0 != '{' && c0 != '[')
        {
            if (c0 == 't')
            {
                if (!parseLiteral!"true"(JsonKind.bool_, 1))
                    return;
                goto afterValue;
            }
            if (c0 == 'f')
            {
                if (!parseLiteral!"false"(JsonKind.bool_, 0))
                    return;
                goto afterValue;
            }
            if (c0 == 'n')
            {
                if (!parseLiteral!"null"(JsonKind.null_, 0))
                    return;
                goto afterValue;
            }
            {
                // The number kernel is a file-scope function (see
                // scanNumber) so the grammar loop's live state stays out
                // of its register allocation; @trusted on the padded
                // pool and the pre-sized arena slot.
                const end = (() @trusted => scanNumber!opts(pool.ptr, i,
                    cells.ptr + cellCount, &serr))();
                if (end == 0)
                {
                    fail(serr.code, serr.offset, serr.context);
                    return;
                }
                cellCount++;
                i = end;
                goto afterValue;
            }
        }
        {
            const isObject = c0 == '{';
            if (depth >= opts.maxDepth)
            {
                fail(ParseErrorCode.depthExceeded, i);
                return;
            }
            depth++;
            const idx = appendCell(isObject ? JsonKind.object : JsonKind.array);
            cells[idx].bits = parent; // threaded parent
            parent = idx;
            parentIsObject = isObject;
            i++;
            skipWs(pool, i);
            if (i < n && pool[i] == (isObject ? '}' : ']'))
            {
                i++;
                goto closeContainer;
            }
            if (isObject)
                goto objectKey;
            goto value;
        }
    }

objectKey: // parse `"key" :` then its value
    if (i >= n || pool[i] != '"')
    {
        fail(i >= n ? ParseErrorCode.unexpectedEnd
                : ParseErrorCode.unexpectedCharacter,
            i, "object key must be a string");
        return;
    }
    {
        // Short-key fast path: keys are overwhelmingly ≤15 bytes of
        // escape-free ASCII — find the quote in two word loads and skip
        // the general machinery (which remains the fallback).
        const quick = (() @trusted {
            enum ulong ones = 0x0101_0101_0101_0101;
            enum ulong highs = 0x8080_8080_8080_8080;
            auto p = pool.ptr + i + 1;
            static ulong stopsOf(ulong x)
            {
                const q = x ^ 0x2222_2222_2222_2222; // '"'
                const b = x ^ 0x5C5C_5C5C_5C5C_5C5C; // '\\'
                return ((q - ones) & ~q & highs)
                    | ((b - ones) & ~b & highs)
                    | ((x - 0x2020_2020_2020_2020) & ~x & highs)
                    | (x & highs);
            }

            import core.bitop : bsf;

            const x0 = loadWord(p);
            const s0 = stopsOf(x0);
            if (s0 != 0)
            {
                const at = bsf(s0) / 8;
                return p[at] == '"' ? at : size_t.max;
            }
            const x1 = loadWord(p + 8);
            const s1 = stopsOf(x1);
            if (s1 != 0)
            {
                const at = 8 + bsf(s1) / 8;
                return p[at] == '"' ? at : size_t.max;
            }
            return size_t.max; // long/escaped/non-ASCII key: general path
        })();
        if (quick != size_t.max)
        {
            const start = i + 1;
            pool[start + quick] = '\0';
            i = start + quick + 1;
            if (!appendStringCell(start, quick))
                return;
        }
        else
        {
            const end = (() @trusted => scanString!opts(pool, i,
                cells.ptr + cellCount, &serr))();
            if (end == 0)
            {
                fail(serr.code, serr.offset, serr.context);
                return;
            }
            cellCount++;
            i = end;
        }
    }
    skipWs(pool, i);
    if (i >= n || pool[i] != ':')
    {
        fail(i >= n ? ParseErrorCode.unexpectedEnd
                : ParseErrorCode.unexpectedCharacter,
            i, "':' expected after object key");
        return;
    }
    i++;
    skipWs(pool, i);
    goto value;

afterValue: // a value completed; count it, then continue its container
    if (parent == noParent)
        goto endCheck;
    cells[parent].tag += 1UL << 8; // one more member
    skipWs(pool, i);
    if (unlikely(i >= n))
    {
        fail(ParseErrorCode.unexpectedEnd, i);
        return;
    }
    {
        const isObject = parentIsObject;
        const c = pool[i];
        if (c == ',')
        {
            // Minified object hot path: `,"` starts the next key.
            if (isObject && pool[i + 1] == '"')
            {
                i++;
                goto objectKey;
            }
            i++;
            skipWs(pool, i);
            if (isObject)
                goto objectKey;
            goto value;
        }
        if (c == (isObject ? '}' : ']'))
        {
            i++;
            goto closeContainer;
        }
        fail(ParseErrorCode.unexpectedCharacter, i,
            "',' or container close expected");
        return;
    }

closeContainer: // finalize cells[parent], pop the threaded parent
    {
        const idx = parent;
        parent = cast(size_t) cells[idx].bits;
        parentIsObject = parent != noParent
            && cells[parent].kind == JsonKind.object;
        cells[idx].bits = cellCount - idx;
        depth--;
        goto afterValue;
    }

endCheck:
    skipWs(pool, i);
    if (i != n)
    {
        fail(ParseErrorCode.trailingContent, i);
        return;
    }
    doc.cellCount = cellCount; // success: nonzero ⇒ hasValue
}

/// Copies one 8-byte word (used by the escape lane's segment moves;
/// callers guarantee in-bounds via the pool padding).
private void memcpyWord(char* d, const(char)* q) @system pure nothrow @nogc
{
    pragma(inline, true);
    import core.stdc.string : memcpy;

    ulong x;
    memcpy(&x, q, 8);
    memcpy(d, &x, 8);
}

/**
Validates that `text` is a single well-formed RFC 8259 JSON document —
the same strict grammar as $(LREF parseJsonDocument), materializing
nothing: no input copy, no arena, no unescaping (SPEC §11.5). Roughly
the parse loop minus every store, over the original (unpadded) input.
*/
ParseError validateJson(scope const(char)[] text) @safe pure nothrow @nogc
{
    // Non-failure sentinel: code emptyInput + offset max (never produced
    // for real errors, which use offset < length or == length).
    enum size_t none = size_t.max;

    const n = text.length;
    if (n == 0)
        return ParseError(ParseErrorCode.emptyInput, 0);

    size_t i = 0;
    uint depth = 0;
    // Container kinds as a bit stack: 1 = object, 0 = array (bounded
    // only by input size — one ulong word per 64 levels).
    ulong[16] kindStack; // 1024 levels — matches the reader's default cap
    bool parentIsObject = false;

    void skipWsG() @safe pure nothrow @nogc
    {
        while (i < n && (text[i] == ' ' || text[i] == '\t'
                || text[i] == '\n' || text[i] == '\r'))
            i++;
    }

    // Validates the string whose opening quote sits at `i`; advances past
    // the closing quote. Returns the error offset or `none`.
    size_t checkString() @safe pure nothrow @nogc
    {
        const openQuote = i;
        i++;
        while (true)
        {
            if (i >= n)
                return openQuote; // unterminated
            const c = text[i];
            if (c == '"')
            {
                i++;
                return none;
            }
            if (c < 0x20)
                return i;
            if (c >= 0x80)
            {
                import sparkles.base.text.utf8 : utf8SequenceLength;

                const len = utf8SequenceLength(text, i);
                if (len == 0)
                    return i;
                i += len;
                continue;
            }
            if (c != '\\')
            {
                i++;
                continue;
            }
            // Escape.
            i++;
            if (i >= n)
                return openQuote;
            const e = text[i];
            i++;
            switch (e)
            {
            case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
                break;
            case 'u':
                uint cp;
                if (!readHex4(text, n, i, cp))
                    return i - 2;
                if (cp >= 0xD800 && cp <= 0xDBFF)
                {
                    if (i + 1 < n && text[i] == '\\' && text[i + 1] == 'u')
                    {
                        i += 2;
                        uint low;
                        if (!readHex4(text, n, i, low))
                            return i - 2;
                        if (low < 0xDC00 || low > 0xDFFF)
                            return i - 6;
                    }
                    else
                        return i - 6;
                }
                else if (cp >= 0xDC00 && cp <= 0xDFFF)
                    return i - 6;
                break;
            default:
                return i - 2;
            }
        }
    }

    // Validates the number starting at `i` (guarded — no padding here).
    size_t checkNumber() @safe pure nothrow @nogc
    {
        const tokenStart = i;
        if (text[i] == '-')
            i++;
        if (i >= n)
            return tokenStart;
        if (text[i] == '0')
        {
            i++;
            if (i < n && text[i] >= '0' && text[i] <= '9')
                return tokenStart; // leading zero
        }
        else
        {
            if (text[i] < '1' || text[i] > '9')
                return i;
            while (i < n && text[i] >= '0' && text[i] <= '9')
                i++;
        }
        if (i < n && text[i] == '.')
        {
            i++;
            if (i >= n || text[i] < '0' || text[i] > '9')
                return i;
            while (i < n && text[i] >= '0' && text[i] <= '9')
                i++;
        }
        if (i < n && (text[i] == 'e' || text[i] == 'E'))
        {
            i++;
            if (i < n && (text[i] == '+' || text[i] == '-'))
                i++;
            if (i >= n || text[i] < '0' || text[i] > '9')
                return i;
            while (i < n && text[i] >= '0' && text[i] <= '9')
                i++;
        }
        return none;
    }

    size_t checkLiteral(string lit)() @safe pure nothrow @nogc
    {
        if (n - i < lit.length || text[i .. i + lit.length] != lit)
            return i;
        i += lit.length;
        return none;
    }

    skipWsG();

value:
    if (i >= n)
        return ParseError(ParseErrorCode.unexpectedEnd, i);
    {
        const c0 = text[i];
        if (c0 == '"')
        {
            const bad = checkString();
            if (bad != none)
                return ParseError(ParseErrorCode.unexpectedCharacter, bad,
                    "invalid string");
            goto afterValue;
        }
        if (c0 == '{' || c0 == '[')
        {
            if (depth >= 1024)
                return ParseError(ParseErrorCode.depthExceeded, i);
            const bit = 1UL << (depth & 63);
            if (c0 == '{')
                kindStack[depth >> 6] |= bit;
            else
                kindStack[depth >> 6] &= ~bit;
            parentIsObject = c0 == '{';
            depth++;
            i++;
            skipWsG();
            if (i < n && text[i] == (parentIsObject ? '}' : ']'))
            {
                i++;
                goto closeContainer;
            }
            if (parentIsObject)
                goto objectKey;
            goto value;
        }
        size_t bad;
        if (c0 == 't')
            bad = checkLiteral!"true"();
        else if (c0 == 'f')
            bad = checkLiteral!"false"();
        else if (c0 == 'n')
            bad = checkLiteral!"null"();
        else
            bad = checkNumber();
        if (bad != none)
            return ParseError(ParseErrorCode.unexpectedCharacter, bad);
        goto afterValue;
    }

objectKey:
    if (i >= n || text[i] != '"')
        return ParseError(i >= n ? ParseErrorCode.unexpectedEnd
                : ParseErrorCode.unexpectedCharacter, i,
            "object key must be a string");
    {
        const bad = checkString();
        if (bad != none)
            return ParseError(ParseErrorCode.unexpectedCharacter, bad,
                "invalid string");
    }
    skipWsG();
    if (i >= n || text[i] != ':')
        return ParseError(i >= n ? ParseErrorCode.unexpectedEnd
                : ParseErrorCode.unexpectedCharacter, i,
            "':' expected after object key");
    i++;
    skipWsG();
    goto value;

afterValue:
    if (depth == 0)
        goto endCheck;
    skipWsG();
    if (i >= n)
        return ParseError(ParseErrorCode.unexpectedEnd, i);
    {
        const c = text[i];
        if (c == ',')
        {
            i++;
            skipWsG();
            if (parentIsObject)
                goto objectKey;
            goto value;
        }
        if (c == (parentIsObject ? '}' : ']'))
        {
            i++;
            goto closeContainer;
        }
        return ParseError(ParseErrorCode.unexpectedCharacter, i,
            "',' or container close expected");
    }

closeContainer:
    depth--;
    parentIsObject = depth > 0
        && (kindStack[(depth - 1) >> 6] & (1UL << ((depth - 1) & 63))) != 0;
    goto afterValue;

endCheck:
    skipWsG();
    if (i != n)
        return ParseError(ParseErrorCode.trailingContent, i);
    return ParseError(ParseErrorCode.emptyInput, none); // the ok sentinel
}

/// Whether a $(LREF validateJson) result means "well-formed".
bool isValidJson(const ParseError e) @safe pure nothrow @nogc
    => e.code == ParseErrorCode.emptyInput && e.offset == size_t.max;

/// Convenience: one-call well-formedness check.
bool isValidJson(scope const(char)[] text) @safe pure nothrow @nogc
    => isValidJson(validateJson(text));

/// Reads exactly 4 hex digits at `src`, advancing it.
private bool readHex4(scope const(char)[] pool, size_t n, ref size_t src,
    out uint value) @safe pure nothrow @nogc
{
    if (n - src < 4)
        return false;
    uint v = 0;
    foreach (k; 0 .. 4)
    {
        const c = pool[src + k];
        uint d;
        if (c >= '0' && c <= '9')
            d = c - '0';
        else if (c >= 'a' && c <= 'f')
            d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F')
            d = c - 'A' + 10;
        else
            return false;
        v = (v << 4) | d;
    }
    src += 4;
    value = v;
    return true;
}

/// Encodes `cp` (a valid scalar value) as UTF-8 at `pool[dst]`; returns
/// the byte count.
private size_t encodeUtf8(scope char[] pool, size_t dst, uint cp)
    @safe pure nothrow @nogc
{
    if (cp < 0x80)
    {
        pool[dst] = cast(char) cp;
        return 1;
    }
    if (cp < 0x800)
    {
        pool[dst] = cast(char)(0xC0 | (cp >> 6));
        pool[dst + 1] = cast(char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000)
    {
        pool[dst] = cast(char)(0xE0 | (cp >> 12));
        pool[dst + 1] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
        pool[dst + 2] = cast(char)(0x80 | (cp & 0x3F));
        return 3;
    }
    pool[dst] = cast(char)(0xF0 | (cp >> 18));
    pool[dst + 1] = cast(char)(0x80 | ((cp >> 12) & 0x3F));
    pool[dst + 2] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
    pool[dst + 3] = cast(char)(0x80 | (cp & 0x3F));
    return 4;
}
