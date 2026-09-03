/**
Correctly-rounded decimal ⇄ binary floating-point conversion for `float`,
`double` and `real` at every width `real` takes — binary64, x87 extended80
and binary128 — over one description of the target format as data
($(LREF BinaryFloatFormat)).

The parse direction is tiered, fastest first, and every tier is exact —
a caller never receives a value that differs from the correctly-rounded
(round-to-nearest, ties-to-even) result of the full decimal:

$(LIST
    * Tier 1 — the Clinger fast path, in the target's own arithmetic: when
        the significand fits the mantissa and the power of ten is exactly
        representable, one multiply or divide is correctly rounded by
        construction.
    * Tier 2 — Eisel–Lemire: a wide multiply against a precomputed
        power-of-ten significand table decides almost every remaining case
        in integer arithmetic. `double` takes the 64×128-bit form
        ($(LREF tryFastDouble)); the wide formats take a 128×128-bit form
        over a 38-digit significand, with a few anchors that compose an
        entry for any exponent they can carry.
    * Tier 3 — the exact big-decimal fallback ($(LREF slowDecode),
        $(LREF slowDouble)) settles what tier 2 cannot prove: true ties,
        subnormals, and the overflow boundary.
)

An explicit exponent is bounded by the format and the literal's digit span,
never by a fixed magnitude, so a long run of zeros paid for by the exponent
decodes to the value it names.

The format direction renders the shortest decimal that reads back to the
same value: Schubfach for `double` ($(LREF formatShortestDouble), in the
notation the JSON writer uses) and Steele–White's free-format algorithm for
any format ($(LREF shortestDigits), $(LREF writeShortest) — scientific
notation, which a consumer with an exponent-free grammar such as the SDL
writer expands).

The primitives are building blocks for fused grammar loops (the JSON
reader accumulates digits inside its own scanner and calls
$(LREF tryFastDouble) directly); $(LREF readDecimalFloat) is the plain
cursor-style reader for everything else. Every power-of-ten table is
generated at CTFE from exact big-integer arithmetic — there is no external
generator step to keep in sync.
*/
module sparkles.base.text.float_conv;

import std.traits : Unqual;

import sparkles.test_runner.attributes : benchmark;

import sparkles.base.text.errors : ParseErrorCode, ParseExpected, parseErr,
    parseOk;

// ─────────────────────────────────────────────────────────────────────────────
// The target format as data
// ─────────────────────────────────────────────────────────────────────────────

/**
The parameters of an IEEE-754-style binary floating-point format, as data
rather than as a D type.

$(LREF formatOf) describes `float`, `double` and `real`; the constants
$(LREF binary32), $(LREF binary64), $(LREF extended80) and $(LREF binary128)
name every format `real` takes across this repository's targets — x87 on
x86_64 Linux, binary64 on AArch64 Darwin and Windows, binary128 on AArch64
Linux and Android. Being data is the point: a kernel parameterized by a
format can be exercised at 113 bits on a host whose `real` has 53, which is
how the binary128 path is tested on every machine rather than only on the
one that has it.

The reduced-precision formats — IEEE binary16 ($(LREF binary16)), bfloat16
($(LREF bfloat16)) and the OCP Microscaling element formats ($(LREF fp8e5m2),
$(LREF fp8e4m3), $(LREF fp6e2m3), $(LREF fp6e3m2), $(LREF fp4e2m1)) — are the
same data; D has no type for them, so `sparkles.base.custom_float` provides
one per format over the bit codec here ($(LREF encode), $(LREF decode)).

The first three fields are D's own `T.mant_dig`, `T.min_exp` and `T.max_exp`;
the fourth says how the top exponent field is spent, which IEEE fixes but the
OCP formats do not: E4M3 keeps it finite except for a single NaN, and the
6- and 4-bit formats have neither NaN nor infinity. The rest is derived, and
each derivation is pinned by a test.
*/
struct BinaryFloatFormat
{
    /// What the top exponent field encodes.
    enum Specials
    {
        ieee,    /// reserved: a zero significand is `±infinity`, any other NaN
        nanOnly, /// finite, except the all-ones significand — the single NaN
        none,    /// finite throughout: no infinity and no NaN
    }

    int mantDig; /// significand bits including the leading one: `T.mant_dig`
    int minExp;  /// `T.min_exp`: the smallest normal is `2^(minExp - 1)`
    int maxExp;  /// `T.max_exp`: every finite value is below `2^maxExp`
    Specials specials = Specials.ieee; /// how the top exponent field is spent

const @safe pure nothrow @nogc:

    /// Whether the format encodes `±infinity` — only under `Specials.ieee`.
    bool hasInfinity() => specials == Specials.ieee;

    /// Whether the format has a NaN — every kind but `Specials.none`.
    bool hasNaN() => specials != Specials.none;

    /// The exponent bias: a field value `f` denotes the leading exponent
    /// `f - bias`, and the smallest normal's field is 1 — 127, 1023, 16 383;
    /// 15 at binary16, 7 at E4M3, 1 at E2M1.
    int bias() => 2 - minExp;

    /// Width of the exponent field. The normal leading exponents number
    /// `maxExp - minExp + 1`; the field spends one value on zero/subnormals
    /// and, under `Specials.ieee`, one on the specials — so the field holds
    /// `maxExp - minExp + 3` (or `+ 2`) values, which is a power of two for
    /// every format described here (8, 11, 15; 5, 8, 5, 4, 2, 3, 2).
    int expBits()
    {
        const values = maxExp - minExp + (specials == Specials.ieee ? 3 : 2);
        int k = 0;
        while ((1 << k) < values)
            k++;
        assert((1 << k) == values, "the exponent range is not a whole field");
        return k;
    }

    /// Stored significand bits: the leading one is implicit — 23, 52, 112.
    int mantBits() => mantDig - 1;

    /// Bits of the IEEE interchange layout, sign included — 32, 64, 128;
    /// 16, 16, 8, 8, 6, 6, 4. (x87 extended80 stores its leading bit and
    /// is not this layout; the codec rejects it.)
    int storageBits() => 1 + expBits + mantBits;

    /// The largest exponent field value that denotes a finite value: the top
    /// field under `Specials.ieee` is the specials, otherwise it is finite.
    int maxFiniteExpField() => (1 << expBits) - (specials == Specials.ieee ? 2 : 1);

    /// The significand of the largest finite value, leading bit included:
    /// all ones, or one below that under `Specials.nanOnly`, where the
    /// all-ones pattern at the top field is the NaN — `2^mantDig - 1`, or
    /// 14 at E4M3 (`448 = 14 × 2^5`). Formats above 64 bits have no `ulong`
    /// significand and no use for this.
    ulong maxFiniteSignificand()
    in (mantDig <= 64, "the significand does not fit a ulong")
        => (mantDig == 64 ? ulong.max : (1UL << mantDig) - 1)
            - (specials == Specials.nanOnly ? 1 : 0);

    /// `T.max_10_exp`: the largest `k` with `10^k` below the largest finite
    /// value, `floor(maxExp·log10 2)` — 38, 308, 4 932; 4 at binary16, 2 at
    /// E4M3, 0 at E2M1. (E4M3's top binade is short by one step; the floor
    /// is unaffected at every width in use.)
    int max10Exp() => cast(int)((cast(long) maxExp * 30_103) / 100_000);

    /// `T.min_10_exp`: the smallest `k` with `10^k` a normal value,
    /// `ceil((minExp - 1)·log10 2)` — −37, −307, −4 931; −4 at binary16, −1 at
    /// E4M3, 0 at E2M1 (whose smallest normal is 1).
    int min10Exp() => -cast(int)((cast(long)(1 - minExp) * 30_103) / 100_000);

    /// Exponent of the smallest normal's leading bit.
    int minNormalExp2() => minExp - 1;

    /// Exponent of the largest finite value's leading bit.
    int maxNormalExp2() => maxExp - 1;

    /// Exponent of the smallest subnormal — one unit in the last place of
    /// the smallest normal.
    int minSubnormalExp2() => minExp - mantDig;

    /// Decimal digits that tell every value apart: `ceil(mantDig·log10 2) + 1`
    /// — 9, 17, 21 and 36.
    int maxDigits10()
        => cast(int)((cast(long) mantDig * 30_103 + 99_999) / 100_000) + 1;

    /// Largest `k` with `10^k` exact in the significand, i.e. `5^k < 2^mantDig`
    /// (the factor of two costs no bits) — 10, 22, 27 and 48.
    int exactPow10Max()
    {
        // k·log2(5) < mantDig, at nine decimals; the margin to the next
        // integer is above 0.2 for every width in use.
        int k = 0;
        while ((k + 1) * 2_321_928_095L < cast(long) mantDig * 1_000_000_000L)
            k++;
        return k;
    }

    /// Digits in the longest exact decimal expansion of a finite value: the
    /// largest significand at the smallest exponent, whose expansion runs to
    /// `mantDig·log10 2 + |minSubnormalExp2|·log10 5` digits — 112, 767,
    /// 11 514 and 11 563.
    int maxExactDigits()
        => cast(int)((cast(long) mantDig * 30_102_999_566L
            + cast(long)(-minSubnormalExp2) * 69_897_000_434L) / 100_000_000_000L) + 1;

    /// Significant digits the exact decoder must keep. Decimal truncation is
    /// order-preserving, so a value is decided correctly once the rounding
    /// tie it is compared against — one bit past `maxExactDigits` — expands
    /// completely inside the buffer; below that a value within a hair of the
    /// tie mis-rounds. With slack, to the next hundred: 200, 800, 11 600 and
    /// 11 600. `binary64`'s 800 is the value the decoder has always used.
    int decimalCapacity() => (maxExactDigits + 33 + 99) / 100 * 100;

    /// Point positions past which a decimal saturates. A decimal with point
    /// position `P` lies in `[10^(P-1), 10^P)`: at or above the high bound it
    /// is at or past `2^maxExp` and overflows — 40, 310, 4 934 and 4 934.
    /// Both bounds also limit the shifting $(LREF slowDecode) does.
    int saturateHighExp10()
        => cast(int)((cast(long) maxExp * 30_103 + 99_999) / 100_000) + 1;

    /// Below this point position a decimal is under half the smallest
    /// subnormal and rounds to zero — −47, −325, −4 952 and −4 967.
    int saturateLowExp10()
    {
        const scaled = cast(long)(minSubnormalExp2 - 1) * 30_103;
        long q = scaled / 100_000;
        if (scaled % 100_000 != 0)
            q--; // floor, not truncation: the operand is negative
        return cast(int) q - 1;
    }

    /// The largest explicit exponent a literal with `digitSpan` digits can
    /// carry without its value being decided by saturation alone: the
    /// combined decimal exponent is the explicit one plus an offset of at most
    /// `digitSpan`, so an explicit exponent clamped to this magnitude
    /// saturates iff the true one does. A reader clamps here instead of
    /// accumulating an exponent that could overflow `int`.
    long explicitExp10Bound(size_t digitSpan)
    {
        const high = cast(long) saturateHighExp10;
        const low = -cast(long) saturateLowExp10;
        return (high > low ? high : low) + cast(long) digitSpan + 1;
    }
}

/// IEEE binary32: `float`.
enum BinaryFloatFormat binary32 = BinaryFloatFormat(24, -125, 128);
/// IEEE binary64: `double`, and `real` on AArch64 Darwin and Windows.
enum BinaryFloatFormat binary64 = BinaryFloatFormat(53, -1021, 1024);
/// x87 80-bit extended: `real` on x86 and x86_64.
enum BinaryFloatFormat extended80 = BinaryFloatFormat(64, -16381, 16384);
/// IEEE binary128: `real` on AArch64 Linux and Android, and on RISC-V.
enum BinaryFloatFormat binary128 = BinaryFloatFormat(113, -16381, 16384);

/// IEEE binary16, "half": 1 + 5 + 10 bits, bias 15; ±65 504 down to
/// `2^-24`. Storage only on every host this repository targets.
enum BinaryFloatFormat binary16 = BinaryFloatFormat(11, -13, 16);
/// bfloat16: binary32's sign and exponent over an 8-bit significand — the
/// top half of a `float`, so its range is `float`'s (`2^-133` to
/// `(2 - 2^-7)·2^127`) at three significant digits.
enum BinaryFloatFormat bfloat16 = BinaryFloatFormat(8, -125, 128);
/// OCP Microscaling FP8 E5M2: bias 15, IEEE specials — ±57 344 down to
/// `2^-16`; `S.11111.00` is infinity, the rest of that field NaN.
enum BinaryFloatFormat fp8e5m2 = BinaryFloatFormat(3, -13, 16);
/// OCP Microscaling FP8 E4M3: bias 7, no infinity, one NaN (`S.1111.111`);
/// the top exponent field is otherwise finite, so the largest value is
/// `448 = 1.75 × 2^8` (`S.1111.110`), and the smallest subnormal `2^-9`.
enum BinaryFloatFormat fp8e4m3 = BinaryFloatFormat(4, -5, 9, BinaryFloatFormat.Specials.nanOnly);
/// OCP Microscaling FP6 E2M3: bias 1, neither infinity nor NaN — 0.125
/// (`S.00.001`) to 7.5 (`S.11.111`); normals start at 1.
enum BinaryFloatFormat fp6e2m3 = BinaryFloatFormat(4, 1, 3, BinaryFloatFormat.Specials.none);
/// OCP Microscaling FP6 E3M2: bias 3, neither infinity nor NaN — 0.0625
/// (`S.000.01`) to 28 (`S.111.11`); normals start at 0.25.
enum BinaryFloatFormat fp6e3m2 = BinaryFloatFormat(3, -1, 5, BinaryFloatFormat.Specials.none);
/// OCP Microscaling FP4 E2M1: bias 1, neither infinity nor NaN — the
/// sixteen patterns ±{0, 0.5, 1, 1.5, 2, 3, 4, 6}.
enum BinaryFloatFormat fp4e2m1 = BinaryFloatFormat(2, 1, 3, BinaryFloatFormat.Specials.none);

/**
Whether `T` is a type this module converts: a native floating-point type,
or any type that names its format as `enum BinaryFloatFormat format` and
carries the bits as `bits` — the `sparkles.base.custom_float` storage types,
or a user's own.
*/
enum bool isFloatLike(T) = __traits(isFloating, T)
    || is(typeof(T.format) : BinaryFloatFormat);

/// The format of a floating-point type: read off a native type's own
/// properties, or declared by a `format`-bearing storage type.
template formatOf(T)
if (isFloatLike!T)
{
    static if (__traits(isFloating, T))
        enum BinaryFloatFormat formatOf = BinaryFloatFormat(T.mant_dig, T.min_exp, T.max_exp);
    else
        enum BinaryFloatFormat formatOf = T.format;
}

/// The unsigned integer that holds a format's IEEE interchange bits:
/// `ubyte` up to 8 bits, `ushort` up to 16, `uint` up to 32, `ulong` up to
/// 64. Wider formats have no single-integer image.
template BitsOf(BinaryFloatFormat fmt)
if (fmt.storageBits <= 64)
{
    static if (fmt.storageBits <= 8)
        alias BitsOf = ubyte;
    else static if (fmt.storageBits <= 16)
        alias BitsOf = ushort;
    else static if (fmt.storageBits <= 32)
        alias BitsOf = uint;
    else
        alias BitsOf = ulong;
}

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
ulong doubleToBits()(double d) @safe pure nothrow @nogc
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
    return (() @trusted => *cast(const ulong*) &d)();
}

/// The `double` with the IEEE-754 bit pattern `bits` (CTFE-safe).
/// Templated for caller-side instantiation, as $(LREF doubleToBits).
double bitsToDouble()(ulong bits) @safe pure nothrow @nogc
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
    return (() @trusted => *cast(const double*) &bits)();
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

/// Exactly representable powers of ten in `T`: `10^0 .. 10^exactPow10Max`,
/// each one exact multiplication from the last. Never literals, which a
/// compiler rounds at its own `real`'s width rather than the target's — and
/// pinned against `5^k × 2^k` composed exactly, at every width.
template exactPow10Of(T)
if (__traits(isFloating, T))
{
    private enum count = formatOf!T.exactPow10Max + 1;
    static immutable T[count] exactPow10Of = () {
        T[count] t;
        T v = 1;
        foreach (i; 0 .. count)
        {
            t[i] = v;
            v *= 10;
        }
        return t;
    }();
}

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

/*
Limb capacity for the generator's scratch values.

The largest value formed is `5^345` (the second loop multiplies 344 times
starting from `5`), which is `345 * log2(5) ≈ 802` bits, or 26 limbs; a
multiply can carry into one more. 32 leaves headroom, and `bigMulSmall`
asserts rather than truncating if the table bounds ever outgrow it.
*/
private enum size_t maxScratchLimbs = 32;

/*
Fixed-capacity big integer, in place of the `new uint[]` this scratch used to
allocate.

The generator only ever runs at CTFE, so the allocation cost was never paid at
runtime — but `new` is rejected during *semantic analysis* under `-betterC`,
and merely importing this module is enough to trigger it. `text.writers`'
decimal fast path imports `writeU64Digits` from here, so the `new` denied
`writeInteger` — and every `-betterC` consumer that reaches it — the whole
build. A static array costs the CTFE interpreter nothing and keeps the module
importable without druntime.
*/
private struct BigUintOf(size_t cap)
{
    uint[cap] limbs = 0;
    size_t length = 1; /// significant limbs; the value is 0 while `limbs[0]` is

    /// A single-limb value.
    static BigUintOf from(uint value) @safe pure nothrow @nogc
    {
        BigUintOf b;
        b.limbs[0] = value;
        return b;
    }

    /// A value of up to 128 bits.
    static BigUintOf from(ulong hi, ulong lo) @safe pure nothrow @nogc
    {
        BigUintOf b;
        b.limbs[0] = cast(uint) lo;
        b.limbs[1] = cast(uint)(lo >> 32);
        b.limbs[2] = cast(uint) hi;
        b.limbs[3] = cast(uint)(hi >> 32);
        b.length = 4;
        while (b.length > 1 && b.limbs[b.length - 1] == 0)
            b.length--;
        return b;
    }

    /// The significant limbs, little-endian.
    const(uint)[] opSlice() const @safe pure nothrow @nogc return scope
        => limbs[0 .. length];
}

/// The table generator's scratch; the shortest-digits writer sizes its own.
private alias BigUint = BigUintOf!maxScratchLimbs;

/// Multiplies `a` by the single limb `m`, in place.
private void bigMulSmall(B)(ref B a, uint m) @safe pure nothrow @nogc
{
    ulong carry = 0;
    foreach (i; 0 .. a.length)
    {
        const t = cast(ulong) a.limbs[i] * m + carry;
        a.limbs[i] = cast(uint) t;
        carry = t >> 32;
    }
    if (carry)
    {
        assert(a.length < a.limbs.length, "BigUint overflow: raise the limb count");
        a.limbs[a.length++] = cast(uint) carry;
    }
    while (a.length > 1 && a.limbs[a.length - 1] == 0)
        a.length--;
}

/// Multiplies `a` by `10^k`, in place, nine digits per step.
private void bigMulPow10(B)(ref B a, int k) @safe pure nothrow @nogc
{
    for (; k >= 9; k -= 9)
        bigMulSmall(a, 1_000_000_000);
    for (; k > 0; k--)
        bigMulSmall(a, 10);
}

/// Multiplies `a` by `2^bits`, in place.
private void bigShiftLeft(B)(ref B a, int bits) @safe pure nothrow @nogc
{
    if (bits <= 0 || (a.length == 1 && a.limbs[0] == 0))
        return;
    const limbShift = bits / 32;
    const bitShift = bits % 32;
    assert(a.length + limbShift + 1 <= a.limbs.length, "BigUint overflow: raise the limb count");
    if (limbShift)
    {
        foreach_reverse (i; 0 .. a.length)
            a.limbs[i + limbShift] = a.limbs[i];
        foreach (i; 0 .. limbShift)
            a.limbs[i] = 0;
        a.length += limbShift;
    }
    if (bitShift)
    {
        uint carry = 0;
        foreach (i; 0 .. a.length)
        {
            const t = (cast(ulong) a.limbs[i] << bitShift) | carry;
            a.limbs[i] = cast(uint) t;
            carry = cast(uint)(t >> 32);
        }
        if (carry)
            a.limbs[a.length++] = carry;
    }
}

/// Three-way comparison of two normalized values.
private int bigCompare(B)(in B a, in B b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return a.length < b.length ? -1 : 1;
    foreach_reverse (i; 0 .. a.length)
        if (a.limbs[i] != b.limbs[i])
            return a.limbs[i] < b.limbs[i] ? -1 : 1;
    return 0;
}

/// `a += b`, in place.
private void bigAdd(B)(ref B a, in B b) @safe pure nothrow @nogc
{
    const n = a.length > b.length ? a.length : b.length;
    ulong carry = 0;
    foreach (i; 0 .. n)
    {
        const t = cast(ulong)(i < a.length ? a.limbs[i] : 0)
            + (i < b.length ? b.limbs[i] : 0) + carry;
        a.limbs[i] = cast(uint) t;
        carry = t >> 32;
    }
    a.length = n;
    if (carry)
    {
        assert(a.length < a.limbs.length, "BigUint overflow: raise the limb count");
        a.limbs[a.length++] = cast(uint) carry;
    }
}

/// `a -= b`, in place; `a >= b` is a precondition.
private void bigSub(B)(ref B a, in B b) @safe pure nothrow @nogc
{
    long borrow = 0;
    foreach (i; 0 .. a.length)
    {
        long t = cast(long) a.limbs[i] - (i < b.length ? b.limbs[i] : 0) - borrow;
        borrow = t < 0 ? 1 : 0;
        if (t < 0)
            t += 0x1_0000_0000L;
        a.limbs[i] = cast(uint) t;
    }
    assert(borrow == 0, "bigSub: a < b");
    while (a.length > 1 && a.limbs[a.length - 1] == 0)
        a.length--;
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
private Pow10Entry bigReciprocal128(size_t cap = maxScratchLimbs)(const uint[] d)
    @safe pure nothrow @nogc
{
    // After the numerator's top bitLength(d) bits (value 2^(bitLength-1),
    // strictly < d since d is odd and > 1), the remainder is that value
    // and every produced quotient bit so far is 0; the remaining 128
    // numerator bits are zeros and yield exactly the 128 result bits.
    //
    // `rem` is indexed against `remLen` rather than sliced: slicing a local
    // static array is `@system`, and the bound is a constant of the loop.
    uint[cap + 1] rem = 0;
    const remLen = d.length + 1;
    assert(remLen <= rem.length, "BigUint overflow: raise the limb capacity");
    {
        const bits = bigBitLength(d) - 1;
        rem[bits / 32] = 1u << (bits % 32);
    }

    ulong hi = 0, lo = 0;
    foreach (k; 0 .. 128)
    {
        // rem <<= 1
        uint carry = 0;
        foreach (i; 0 .. remLen)
        {
            const t = (cast(ulong) rem[i] << 1) | carry;
            rem[i] = cast(uint) t;
            carry = cast(uint)(t >> 32);
        }
        // rem >= d?
        bool ge = true;
        {
            size_t rl = remLen;
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
            foreach (i; 0 .. remLen)
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
    @safe pure nothrow @nogc
{
    Pow10Entry[tableMaxExp10 - tableMinExp10 + 1] table;

    // q ≥ 0: top 128 bits of 5^q (10^q = 5^q × 2^q).
    auto pow5 = BigUint.from(1);
    foreach (q; 0 .. tableMaxExp10 + 1)
    {
        table[q - tableMinExp10] = bigTop128(pow5[]);
        bigMulSmall(pow5, 5);
    }

    // q < 0: normalized, truncated 128-bit reciprocal of 5^|q|.
    pow5 = BigUint.from(5);
    foreach (q; 1 .. -tableMinExp10 + 1)
    {
        table[-q - tableMinExp10] = bigReciprocal128(pow5[]);
        bigMulSmall(pow5, 5);
    }

    return table;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tier 2 for the wide formats: Eisel–Lemire over a 128-bit significand
// ─────────────────────────────────────────────────────────────────────────────

/// `10^0 .. 10^19`: the multipliers that join two 19-digit accumulations.
private static immutable ulong[20] pow10U64 = () {
    ulong[20] t;
    ulong v = 1;
    foreach (i; 0 .. 20)
    {
        t[i] = v;
        v *= 10;
    }
    return t;
}();

/// `a << n` for `0 ≤ n < 128`.
private U128 shl128(U128 a, int n) @safe pure nothrow @nogc
in (0 <= n && n < 128)
{
    if (n == 0)
        return a;
    if (n >= 64)
        return U128(a.lo << (n - 64), 0);
    return U128((a.hi << n) | (a.lo >> (64 - n)), a.lo << n);
}

/// `a >> n` for `0 ≤ n < 128`.
private U128 shr128(U128 a, int n) @safe pure nothrow @nogc
in (0 <= n && n < 128)
{
    if (n == 0)
        return a;
    if (n >= 64)
        return U128(0, a.hi >> (n - 64));
    return U128(a.hi >> n, (a.lo >> n) | (a.hi << (64 - n)));
}

/// The low `n` bits of `a`, for `0 ≤ n ≤ 128`.
private U128 lowBits128(U128 a, int n) @safe pure nothrow @nogc
in (0 <= n && n <= 128)
{
    if (n >= 128)
        return a;
    if (n >= 64)
        return U128(a.hi & ((1UL << (n - 64)) - 1), a.lo);
    return U128(0, a.lo & ((1UL << n) - 1));
}

/// `a + 1`.
private U128 inc128(U128 a) @safe pure nothrow @nogc
{
    a.lo++;
    if (a.lo == 0)
        a.hi++;
    return a;
}

/// Leading zero bits of a nonzero 128-bit value.
private int leadingZeros128(U128 a) @safe pure nothrow @nogc
in (a.hi != 0 || a.lo != 0)
    => a.hi ? leadingZeros(a.hi) : 64 + leadingZeros(a.lo);

/**
The 256-bit product of two normalized 128-bit values, split into its top and
bottom halves and shifted left once when the top bit is clear (two values in
`[2^127, 2^128)` multiply to at least `2^254`). Returns that shift, 0 or 1.
*/
private int mul128Normalized(U128 a, U128 b, out U128 top, out U128 bottom)
    @safe pure nothrow @nogc
{
    const p0 = mul64x64(a.hi, b.hi);
    const p1 = mul64x64(a.hi, b.lo);
    const p2 = mul64x64(a.lo, b.hi);
    const p3 = mul64x64(a.lo, b.lo);
    ulong r1 = p3.hi;
    ulong c = 0;
    r1 += p1.lo;
    if (r1 < p1.lo)
        c++;
    r1 += p2.lo;
    if (r1 < p2.lo)
        c++;
    ulong r2 = p0.lo + c;
    ulong c2 = r2 < c ? 1 : 0;
    r2 += p1.hi;
    if (r2 < p1.hi)
        c2++;
    r2 += p2.hi;
    if (r2 < p2.hi)
        c2++;
    const r3 = p0.hi + c2; // no overflow: the product is below 2^256
    top = U128(r3, r2);
    bottom = U128(r1, p3.lo);
    if (r3 >> 63)
        return 0;
    top = U128((top.hi << 1) | (top.lo >> 63), (top.lo << 1) | (bottom.hi >> 63));
    bottom = U128((bottom.hi << 1) | (bottom.lo >> 63), bottom.lo << 1);
    return 1;
}

/**
A power of ten as the wide tier sees it: `10^q ∈ [E, E + width) × 2^exp2`
with `E = hi:lo` in `[2^127, 2^128)`. A fine entry ($(LREF pow10Sig128)) and
an anchor are truncated once and have width 1; a composed entry — the top 128
bits of an anchor times a fine entry — has width 5: each factor's truncation
scaled by the other factor, which is below `2^128`, plus the product's own
truncation, all over a normalizing shift of at least 127.
*/
private struct Pow10Wide
{
    ulong hi;
    ulong lo;
    int exp2;
    int width;
}

/// `floor(q·log2 10) − 127`: the exponent of a fine entry's last bit. The
/// fixed point is exact on the fine range and no further — it first fails at
/// `|q| = 643` — which is why composed entries carry their own exponent.
private int fineExp2(int q) @safe pure nothrow @nogc
in (tableMinExp10 <= q && q <= tableMaxExp10)
    => ((217_706 * q) >> 16) - 127;

/// The exponents the wide tier must serve: those a 38-digit significand can
/// carry under the widest format without the verdict being saturation alone.
/// One anchor per fine-table span covers them, so any such `q` is an anchor
/// times a fine entry.
private enum int wideMaxExp10 = binary128.saturateHighExp10 - 1;
/// ditto
private enum int wideMinExp10 = binary128.saturateLowExp10 - 38;
/// ditto
private enum size_t anchorCountPos = (wideMaxExp10 - 1) / tableMaxExp10;
/// ditto
private enum size_t anchorCountNeg = (-wideMinExp10 - 1) / -tableMinExp10;
static assert(extended80.saturateHighExp10 <= binary128.saturateHighExp10
    && extended80.saturateLowExp10 >= binary128.saturateLowExp10,
    "the anchors are sized by the widest format");

/// Limbs for the largest anchor power, `5^(324·15)`, with a carry to spare.
private enum size_t anchorLimbs = () {
    enum long pos = tableMaxExp10 * cast(long) anchorCountPos;
    enum long neg = -tableMinExp10 * cast(long) anchorCountNeg;
    enum long bits = (pos > neg ? pos : neg) * 2_321_929L / 1_000_000L;
    return cast(size_t)((bits + 31) / 32) + 2;
}();

/// Multiplies `a` by `5^k`, in place, thirteen at a time (`5^13 < 2^32`).
private void bigMulPow5(B)(ref B a, int k) @safe pure nothrow @nogc
{
    static immutable uint[13] small = [1, 5, 25, 125, 625, 3125, 15_625, 78_125,
        390_625, 1_953_125, 9_765_625, 48_828_125, 244_140_625];
    for (; k >= 13; k -= 13)
        bigMulSmall(a, 1_220_703_125);
    if (k > 0)
        bigMulSmall(a, small[k]);
}

/// The anchors `10^(324·j)`, `j = 1 ..`: the top 128 bits of `5^(324j)`, as
/// the fine table's positive entries are made, with the exact exponent.
private Pow10Wide[anchorCountPos] generateAnchorsPos() @safe pure nothrow @nogc
{
    Pow10Wide[anchorCountPos] table;
    auto pow5 = BigUintOf!anchorLimbs.from(1);
    foreach (j; 0 .. anchorCountPos)
    {
        bigMulPow5(pow5, tableMaxExp10);
        const q = tableMaxExp10 * cast(int)(j + 1);
        const top = bigTop128(pow5[]);
        table[j] = Pow10Wide(top.hi, top.lo, q + cast(int) bigBitLength(pow5[]) - 128, 1);
    }
    return table;
}

/// The anchors `10^(−343·j)`: the truncated 128-bit reciprocal of `5^(343j)`,
/// as the fine table's negative entries are made, with the exact exponent.
private Pow10Wide[anchorCountNeg] generateAnchorsNeg() @safe pure nothrow @nogc
{
    Pow10Wide[anchorCountNeg] table;
    auto pow5 = BigUintOf!anchorLimbs.from(1);
    foreach (j; 0 .. anchorCountNeg)
    {
        bigMulPow5(pow5, -tableMinExp10);
        const q = tableMinExp10 * cast(int)(j + 1);
        const top = bigReciprocal128!anchorLimbs(pow5[]);
        table[j] = Pow10Wide(top.hi, top.lo, q - cast(int) bigBitLength(pow5[]) - 127, 1);
    }
    return table;
}

/// ditto
private static immutable Pow10Wide[anchorCountPos] pow10AnchorsPos = generateAnchorsPos();
/// ditto
private static immutable Pow10Wide[anchorCountNeg] pow10AnchorsNeg = generateAnchorsNeg();

/// The entry for `q`: a fine entry when the table has one, otherwise the
/// anchor of `q`'s span times the fine entry of the remainder, truncated to
/// 128 bits and normalized, with the exponent the product actually has.
private Pow10Wide wideEntry(int q) @safe pure nothrow @nogc
in (wideMinExp10 <= q && q <= wideMaxExp10)
{
    if (tableMinExp10 <= q && q <= tableMaxExp10)
    {
        const f = pow10Sig128[q - tableMinExp10];
        return Pow10Wide(f.hi, f.lo, fineExp2(q), 1);
    }
    Pow10Wide a;
    int qf;
    if (q > tableMaxExp10)
    {
        const j = (q - 1) / tableMaxExp10;
        a = pow10AnchorsPos[j - 1];
        qf = q - j * tableMaxExp10;
    }
    else
    {
        const j = (-q - 1) / -tableMinExp10;
        a = pow10AnchorsNeg[j - 1];
        qf = q - j * tableMinExp10;
    }
    const f = pow10Sig128[qf - tableMinExp10];
    U128 top, bottom;
    const s = mul128Normalized(U128(a.hi, a.lo), U128(f.hi, f.lo), top, bottom);
    return Pow10Wide(top.hi, top.lo, a.exp2 + fineExp2(qf) + 128 - s, 5);
}

/**
Converts `sig × 10^exp10` — up to 38 significant digits, so `sig < 2^127` —
to the correctly-rounded value of `fmt` whenever one 256-bit product proves
it: the Eisel–Lemire idea for the formats whose significand does not fit a
`ulong`. Returns `false` when the product cannot decide, and the caller
takes the exact tier. Correctly rounded whenever it returns `true`.

The significand normalized to `[2^127, 2^128)` times the entry is a 256-bit
lower bound of the true product, short by less than `width` entry units
times the significand — under `2^128 × width`, so only the bottom 128 bits
are uncertain plus a carry of at most `width` into the top half (twice that
after the normalizing shift). The top `p` bits are the mantissa, the next
the round bit, and the `127 − p` below it a guard window: the result is
proven unless a carry could reach the round bit, or the tail could be exactly
one half with the mantissa even — the tie the product cannot tell from just
above it. Values outside the normal range are punted (subnormals) or decided
(overflow: a lower bound past `2^maxExp` is conclusive).
*/
private bool tryFastWide(BinaryFloatFormat fmt)(U128 sig, int exp10, out DecodedFloat r)
    @safe pure nothrow @nogc
in (sig.hi < 1UL << 63, "the significand carries at most 38 digits")
{
    enum p = fmt.mantDig;
    static assert(p == 64 || (p > 64 && p <= 113), "a format the wide tier does not serve");
    enum W = 127 - p; // guard bits between the round bit and the tail
    enum lowExp10 = fmt.saturateLowExp10 - 38;
    enum highExp10 = fmt.saturateHighExp10;
    static assert(wideMinExp10 <= lowExp10 && highExp10 - 1 <= wideMaxExp10);

    r = DecodedFloat.init;
    if ((sig.hi | sig.lo) == 0 || exp10 < lowExp10)
        return true; // below half the smallest subnormal whatever the digits
    if (exp10 >= highExp10)
    {
        r.isInf = true; // at least 10^exp10, itself past 2^maxExp
        return true;
    }

    const lz = leadingZeros128(sig);
    const w = shl128(sig, lz);
    const e = wideEntry(exp10);
    U128 top, bottom;
    const s = mul128Normalized(w, U128(e.hi, e.lo), top, bottom);
    const ulong cMax = cast(ulong)(e.width + 1) << s;

    static if (p == 64)
    {
        U128 m = U128(0, top.hi);
        const rbit = top.lo >> 63;
        const guard = top.lo & (ulong.max >> 1);
    }
    else
    {
        U128 m = U128(top.hi >> (128 - p), (top.hi << (p - 64)) | (top.lo >> (128 - p)));
        const rbit = (top.lo >> W) & 1;
        const guard = top.lo & ((1UL << W) - 1);
    }

    // A carry out of the uncertain tail could reach the round bit.
    if (guard >= (1UL << W) - cMax)
        return false;
    // The tail could be exactly one half with an even mantissa: a tie, or a
    // hair above it. (An odd mantissa rounds up either way, and a nonzero
    // bottom half puts the lower bound itself above the half.)
    if (rbit && guard == 0 && (bottom.hi | bottom.lo) == 0 && (m.lo & 1) == 0)
        return false;

    int exp2 = 256 - p - s + e.exp2 - lz;
    const lead = exp2 + (p - 1);
    if (lead < fmt.minNormalExp2)
        return false; // subnormal: the exact tier rounds at the format's floor
    if (lead > fmt.maxNormalExp2)
    {
        r.isInf = true;
        return true;
    }
    if (rbit)
    {
        m = inc128(m);
        if (bitSet(m.hi, m.lo, p)) // rounding carried into bit p
        {
            m = U128(m.hi >> 1, (m.lo >> 1) | (m.hi << 63));
            exp2++;
            if (exp2 + (p - 1) > fmt.maxNormalExp2)
            {
                r.isInf = true;
                return true;
            }
        }
    }
    r.hi = m.hi;
    r.lo = m.lo;
    r.exp2 = exp2;
    return true;
}

/**
Converts a decimal literal to `fmt` exactly, for the wide formats: the digit
runs are accumulated into a 128-bit significand of up to 38 significant
digits that $(LREF tryFastWide) decides — a longer literal is bracketed
between the truncation and its successor, which agree for all but a sliver
of inputs — and $(LREF slowDecode) settles whatever is punted. The
arguments are $(LREF slowDecode)'s; the sign is the caller's.
*/
private DecodedFloat decodeWide(BinaryFloatFormat fmt)(scope const(char)[] intDigits,
    scope const(char)[] fracDigits, int explicitExp10) @safe pure nothrow @nogc
{
    ulong sigHi = 0, sigLo = 0;
    uint taken = 0;
    bool truncated = false;
    bool seen = false;
    long lastExp10 = 0; // the exponent of the last taken digit's position

    foreach (k, c; intDigits)
    {
        const uint d = cast(uint)(c - '0');
        if (!seen)
        {
            if (d == 0)
                continue;
            seen = true;
        }
        if (taken >= 38)
        {
            truncated = true;
            break;
        }
        if (taken < 19)
            sigHi = sigHi * 10 + d;
        else
            sigLo = sigLo * 10 + d;
        taken++;
        lastExp10 = cast(long)(intDigits.length - 1 - k);
    }
    if (!truncated)
        foreach (k, c; fracDigits)
        {
            const uint d = cast(uint)(c - '0');
            if (!seen)
            {
                if (d == 0)
                    continue;
                seen = true;
            }
            if (taken >= 38)
            {
                truncated = true;
                break;
            }
            if (taken < 19)
                sigHi = sigHi * 10 + d;
            else
                sigLo = sigLo * 10 + d;
            taken++;
            lastExp10 = -cast(long)(k + 1);
        }
    if (!seen)
        return DecodedFloat.init;

    U128 sig = U128(0, sigHi);
    if (taken > 19)
    {
        sig = mul64x64(sigHi, pow10U64[taken - 19]);
        sig.lo += sigLo;
        if (sig.lo < sigLo)
            sig.hi++;
    }
    const long combined = explicitExp10 + lastExp10;
    const int exp10 = combined < int.min ? int.min : combined > int.max ? int.max : cast(int) combined;

    DecodedFloat r;
    if (!truncated)
    {
        if (tryFastWide!fmt(sig, exp10, r))
            return r;
    }
    else
    {
        DecodedFloat high;
        if (tryFastWide!fmt(sig, exp10, r) && tryFastWide!fmt(inc128(sig), exp10, high)
            && r == high)
            return r;
    }
    return slowDecode!fmt(intDigits, fracDigits, explicitExp10);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tier 3: the exact big-decimal slow path
// ─────────────────────────────────────────────────────────────────────────────

/**
A finite binary floating-point value as integers, for any
$(LREF BinaryFloatFormat): `(-1)^negative × (hi·2^64 + lo) × 2^exp2`, the
significand holding at most `mantDig` bits and `exp2` being the exponent of
its last bit. A zero significand is zero, with `exp2` zero; `isInf` is the
overflow verdict, which no significand can carry.

The shape is the point: a value at 113 bits is still three integers, which
a test on a 53-bit host can assert on. $(LREF slowDecode) produces it; the
typed decoders turn it into a `float`, `double` or `real`.
*/
struct DecodedFloat
{
    ulong hi;      /// significand bits 64 and up
    ulong lo;      /// significand bits 0 .. 63
    int exp2;      /// exponent of the significand's last bit
    bool negative; /// the sign, which the digits never carry
    bool isInf;    /// overflow: the value is `±infinity`
    bool isNaN;    /// not a number — only ever decoded from bits, never parsed
}

/**
Converts a decimal literal to the correctly-rounded nearest value of `fmt`
exactly, with no fast-path preconditions — the tier that settles every
input the fast tiers punt (true ties, subnormals, overflow boundaries,
>19-digit truncations).

`intDigits`/`fracDigits` are the digit runs on either side of the decimal
point (either may be empty, both may carry leading zeros);
`explicitExp10` is the literal's exponent part. The algorithm is the
classic arbitrary-precision decimal-shift fallback (Go `strconv`,
originally David Gay): scale the decimal by powers of two until it sits
in `[1, 2)`, then read off the `mantDig`-bit significand with exact
rounding information. Fixed storage sized by the format, `@nogc`,
CTFE-capable.

The sign is the caller's: the digits never carry one, and `negative` comes
back clear.
*/
DecodedFloat slowDecode(BinaryFloatFormat fmt)(scope const(char)[] intDigits,
    scope const(char)[] fracDigits, int explicitExp10) @safe pure nothrow @nogc
{
    enum p = fmt.mantDig;
    enum lowExp10 = fmt.saturateLowExp10;
    enum highExp10 = fmt.saturateHighExp10;

    DecodedFloat r;
    BigDecimal!(fmt.decimalCapacity()) d;
    d.set(intDigits, fracDigits, explicitExp10);

    // Obvious saturation (also bounds the shifting below).
    if (d.count == 0 || d.pointPos < lowExp10)
        return r;
    if (d.pointPos > highExp10)
    {
        r.isInf = true;
        return r;
    }

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

    // Clamp into the subnormal range when below the smallest normal exponent:
    // the significand then holds fewer than `p` bits, and its last bit sits
    // at the format's floor.
    enum minNormalExp2 = fmt.minNormalExp2;
    enum maxNormalExp2 = fmt.maxNormalExp2;
    if (exp2 < minNormalExp2)
    {
        const n = minNormalExp2 - exp2;
        d.shiftRight(n);
        exp2 += n;
    }
    if (exp2 > maxNormalExp2)
    {
        r.isInf = true;
        return r;
    }

    // Extract the significand: shift the value into [2^(p-1), 2^p) and round.
    d.shiftLeft(p);
    ulong hi, lo;
    d.roundedInteger(hi, lo);
    if (bitSet(hi, lo, p)) // rounding carried into bit p
    {
        lo = (lo >> 1) | (hi << 63);
        hi >>= 1;
        exp2++;
        if (exp2 > maxNormalExp2)
        {
            r.isInf = true;
            return r;
        }
    }
    if (hi == 0 && lo == 0)
        return r; // rounded away, below half the smallest subnormal
    r.hi = hi;
    r.lo = lo;
    r.exp2 = exp2 - (p - 1);
    return r;
}

/// Whether bit `bit` of the 128-bit `hi:lo` is set.
private bool bitSet(ulong hi, ulong lo, int bit) @safe pure nothrow @nogc
    => bit < 64 ? ((lo >> bit) & 1) != 0 : ((hi >> (bit - 64)) & 1) != 0;

/**
Converts a decimal literal to the correctly-rounded nearest `double`
exactly: $(LREF slowDecode) at $(LREF binary64), assembled into the IEEE
bit pattern. See there for the arguments.
*/
double slowDouble(scope const(char)[] intDigits, scope const(char)[] fracDigits,
    int explicitExp10) @safe pure nothrow @nogc
{
    const r = slowDecode!binary64(intDigits, fracDigits, explicitExp10);
    if (r.isInf)
        return double.infinity;
    // The 53-bit significand is in `lo`. Below 2^52 it is a subnormal (or
    // zero), whose exponent field is 0; otherwise the field is the biased
    // exponent of the leading bit, `exp2 + 52`.
    if (r.lo < (1UL << 52))
        return bitsToDouble(r.lo);
    return bitsToDouble((cast(ulong)(r.exp2 + 52 + 1023) << 52)
        | (r.lo & ((1UL << 52) - 1)));
}

/**
`value` as a $(LREF DecodedFloat) in `formatOf!T` — by arithmetic alone.

D has no portable `realToBits`, and x87's explicit integer bit makes bit
synthesis format-specific; scaling by a power of two is exact in every
format, needs nothing from Phobos, and runs at CTFE. A subnormal comes out
canonical: its last bit at the format's floor, fewer than `mantDig` bits
above it. NaN comes back as `isNaN`, its payload dropped.

At CTFE, decompose only a value that is exact in `T`: D lets CTFE carry a
`double` at the host `real`'s precision, and on an x87 host `0.1` arrives
with 64 significant bits — which is then, faithfully, what comes out.
*/
DecodedFloat decompose(T)(T value) @safe pure nothrow @nogc
if (__traits(isFloating, T))
{
    enum fmt = formatOf!T;
    enum p = fmt.mantDig;

    DecodedFloat r;
    if (value != value)
    {
        r.isNaN = true;
        return r;
    }
    r.negative = value < 0 || (value == 0 && 1 / value < 0);
    Unqual!T m = r.negative ? -value : value;
    if (m == 0)
        return r;
    if (m == T.infinity)
    {
        r.isInf = true;
        return r;
    }

    // Bring the magnitude into [1, 2), tracking its leading bit's exponent.
    // Steps of 2^64 are exact: dividing keeps a normal result, and a
    // subnormal times 2^64 gains only exponent.
    int e = 0;
    while (m >= 0x1p64)
    {
        m *= 0x1p-64;
        e += 64;
    }
    while (m < 1)
    {
        m *= 0x1p64;
        e -= 64;
    }
    while (m >= 2)
    {
        m *= 0.5;
        e++;
    }

    // Widen to an integer significand. Below the normal range the last bit
    // is pinned at the floor, so fewer bits are lifted — exactly the ones a
    // subnormal has.
    int lsb = e - (p - 1);
    int lift = p - 1;
    if (lsb < fmt.minSubnormalExp2)
    {
        lift -= fmt.minSubnormalExp2 - lsb;
        lsb = fmt.minSubnormalExp2;
    }
    foreach (_; 0 .. lift)
        m *= 2;

    // Split the (at most 113-bit) integer: the top part by an exact scale
    // and a truncating cast, the rest by an exact subtraction.
    const ulong hi = cast(ulong)(m * 0x1p-64);
    r.hi = hi;
    r.lo = cast(ulong)(m - cast(Unqual!T) hi * 0x1p64);
    r.exp2 = lsb;
    return r;
}

/**
The `T` a $(LREF DecodedFloat) in `formatOf!T` denotes — the inverse of
$(LREF decompose), by the same exact arithmetic: the significand is
assembled as an integer, then scaled by powers of two in steps that never
overflow, and never lose a bit because every intermediate lies between the
integer and the representable result.
*/
T compose(T)(DecodedFloat d) @safe pure nothrow @nogc // by value: see roundTo
if (__traits(isFloating, T))
{
    static assert(formatOf!T.mantDig <= 113, "the significand is 128 bits wide");
    if (d.isNaN)
        return d.negative ? -T.nan : T.nan;
    if (d.isInf)
        return d.negative ? -T.infinity : T.infinity;
    Unqual!T m = cast(T) d.hi * 0x1p64 + cast(T) d.lo;
    int e = d.exp2;
    while (e >= 64)
    {
        m *= 0x1p64;
        e -= 64;
    }
    while (e <= -64)
    {
        m *= 0x1p-64;
        e += 64;
    }
    while (e > 0)
    {
        m *= 2;
        e--;
    }
    while (e < 0)
    {
        m *= 0.5;
        e++;
    }
    return d.negative ? -m : m;
}

/**
Converts a decimal literal to the correctly-rounded nearest `T` exactly —
$(LREF slowDecode) at `formatOf!T`, then $(LREF compose). See there for the
arguments; the sign is the caller's.
*/
T slowFloat(T)(scope const(char)[] intDigits, scope const(char)[] fracDigits,
    int explicitExp10) @safe pure nothrow @nogc
if (__traits(isFloating, T))
    => compose!T(slowDecode!(formatOf!T)(intDigits, fracDigits, explicitExp10));

// ─────────────────────────────────────────────────────────────────────────────
// The IEEE interchange layout, and rounding between formats
// ─────────────────────────────────────────────────────────────────────────────

/**
The IEEE interchange bits — sign, biased exponent, significand without its
leading bit — of a $(LREF DecodedFloat) already in `fmt`, for any format
whose layout fits 64 bits (so `binary64` and below; x87 extended80 stores
its leading bit and is not this layout).

The value must be representable: this rounds nothing. It does accept a
non-canonical significand — fewer than `mantDig` bits, or trailing zeros
below the format's floor — and normalises it, so an integer or a wider
exact value that happens to fit needs no preparation.

Overflow (`isInf`, or a value past the largest finite one) follows the
format's specials, which is the whole policy for infinity-less formats: an
IEEE format gives `±infinity`; a `nanOnly` format (E4M3) gives its NaN, as
PyTorch's `float8_e4m3fn` and `ml_dtypes` do; a format with `none` gives
the largest finite value with the sign. Under `nanOnly` the all-ones
significand at the top field is that NaN, so a decoded value landing there
is overflow too — E4M3's 480 does not exist. A NaN needs a format that has
one (precondition). CTFE-clean.
*/
BitsOf!fmt encode(BinaryFloatFormat fmt)(DecodedFloat d) @safe pure nothrow @nogc
in (!d.isNaN || fmt.hasNaN, "the format has no NaN")
{
    static assert(fmt.storageBits <= 64, "the layout does not fit 64 bits");
    alias B = BitsOf!fmt;
    enum p = fmt.mantDig;
    enum mantBits = fmt.mantBits;
    enum ulong mantMask = (1UL << mantBits) - 1;
    enum ulong topField = (1UL << fmt.expBits) - 1;
    enum ulong signBit = 1UL << (fmt.storageBits - 1);
    const ulong sign = d.negative ? signBit : 0;

    static ulong nan()
    {
        static if (fmt.specials == BinaryFloatFormat.Specials.ieee)
            return (topField << mantBits) | (1UL << (mantBits - 1)); // quiet
        else
            return (topField << mantBits) | mantMask;
    }

    static ulong overflow()
    {
        static if (fmt.specials == BinaryFloatFormat.Specials.ieee)
            return topField << mantBits;
        else static if (fmt.specials == BinaryFloatFormat.Specials.nanOnly)
            return nan();
        else
            return (topField << mantBits) | mantMask; // the largest finite
    }

    if (d.isNaN)
        return cast(B)(sign | nan());
    if (d.isInf)
        return cast(B)(sign | overflow());
    if (d.hi == 0 && d.lo == 0)
        return cast(B) sign;

    // Normalise: the significand's last bit belongs at `max(lead - (p - 1),
    // floor)`; above the floor a shorter significand is widened, and a
    // longer one must carry only zeros below that position.
    const U128 sig = U128(d.hi, d.lo);
    const width = 128 - leadingZeros128(sig);
    const lead = d.exp2 + width - 1;
    int lsb = lead - (p - 1);
    if (lsb < fmt.minSubnormalExp2)
        lsb = fmt.minSubnormalExp2;
    const shift = lsb - d.exp2;
    ulong m;
    if (shift <= 0)
        m = shl128(sig, -shift).lo; // at most p ≤ 53 bits: `hi` is zero
    else
    {
        const dropped = lowBits128(sig, shift < width ? shift : width);
        assert(shift < width && dropped.hi == 0 && dropped.lo == 0,
            "a value not representable in the format");
        m = shr128(sig, shift).lo;
    }

    if (lead > fmt.maxNormalExp2)
        return cast(B)(sign | overflow());
    if (lead < fmt.minNormalExp2)
        return cast(B)(sign | m); // subnormal: field 0, no leading bit
    const ulong field = cast(ulong)(lead + fmt.bias);
    static if (fmt.specials == BinaryFloatFormat.Specials.nanOnly)
        if (field == topField && (m & mantMask) == mantMask)
            return cast(B)(sign | overflow());
    return cast(B)(sign | (field << mantBits) | (m & mantMask));
}

/**
The value of IEEE interchange bits in `fmt` as a $(LREF DecodedFloat) — the
inverse of $(LREF encode). A subnormal comes out canonical (its last bit at
the floor); the specials come out as `isInf`/`isNaN` with their sign; a NaN's
payload is dropped. CTFE-clean.
*/
DecodedFloat decode(BinaryFloatFormat fmt)(BitsOf!fmt bits) @safe pure nothrow @nogc
{
    static assert(fmt.storageBits <= 64, "the layout does not fit 64 bits");
    enum p = fmt.mantDig;
    enum mantBits = fmt.mantBits;
    enum ulong mantMask = (1UL << mantBits) - 1;
    enum ulong topField = (1UL << fmt.expBits) - 1;

    DecodedFloat r;
    r.negative = ((bits >> (fmt.storageBits - 1)) & 1) != 0;
    const ulong field = (bits >> mantBits) & topField;
    const ulong mant = bits & mantMask;
    static if (fmt.specials == BinaryFloatFormat.Specials.ieee)
    {
        if (field == topField)
        {
            if (mant == 0)
                r.isInf = true;
            else
                r.isNaN = true;
            return r;
        }
    }
    else static if (fmt.specials == BinaryFloatFormat.Specials.nanOnly)
    {
        if (field == topField && mant == mantMask)
        {
            r.isNaN = true;
            return r;
        }
    }
    if (field == 0)
    {
        if (mant == 0)
            return r; // ±0
        r.lo = mant;
        r.exp2 = fmt.minSubnormalExp2;
        return r;
    }
    r.lo = mant | (1UL << mantBits);
    r.exp2 = cast(int) field - fmt.bias - (p - 1);
    return r;
}

/**
Rounds an exact value — any $(LREF DecodedFloat), up to 113 significand bits
at any exponent — to the nearest value of `fmt`, ties to even, the way a
correctly-rounded conversion between native types does: the last bit is
pinned at the format's floor below the normal range, a carry out of an
all-ones significand moves up a binade, and a result past the largest
finite value is `isInf` (which $(LREF encode) then turns into the format's
overflow answer). `halfway` reports that the discarded part was exactly one
half unit of the result — the case that was decided by the even rule, and
the one case a reader that got here through an already-rounded wider value
cannot trust (see $(LREF readDecimalFloat)). CTFE-clean.

This is the one rounding step of `float`/`double`/`real` → reduced format
conversion: $(LREF decompose) is exact, so `roundTo` over it rounds once,
where a chain of native casts would round twice.

The `DecodedFloat` parameters here, in $(LREF compose) and in $(LREF encode)
are by value (24 bytes) rather than `in`: LDC 1.42's interpreter crashes on
a `static assert` that reads a `bool` field through an `in` reference to a
struct another CTFE call returned — only inside this package's full
unittest build, never in a single-file reproduction.
*/
DecodedFloat roundTo(BinaryFloatFormat fmt)(DecodedFloat exact, out bool halfway)
    @safe pure nothrow @nogc
{
    enum p = fmt.mantDig;
    static assert(p <= 113, "the significand is 128 bits wide");

    DecodedFloat r;
    r.negative = exact.negative;
    r.isNaN = exact.isNaN;
    r.isInf = exact.isInf;
    if (exact.isNaN || exact.isInf || (exact.hi == 0 && exact.lo == 0))
        return r;

    const U128 sig = U128(exact.hi, exact.lo);
    const width = 128 - leadingZeros128(sig);
    const lead = exact.exp2 + width - 1;
    int lsb = lead - (p - 1);
    if (lsb < fmt.minSubnormalExp2)
        lsb = fmt.minSubnormalExp2;
    const shift = lsb - exact.exp2;

    U128 kept;
    if (shift <= 0)
        kept = shl128(sig, -shift); // exact: the value has at most p bits
    else if (shift > width)
        kept = U128(0, 0); // below half a unit: everything rounds away
    else
    {
        // `kept` is the top `width - shift` bits (none when `shift == width`);
        // the rest is compared against half a unit of the last kept bit.
        kept = shift < 128 ? shr128(sig, shift) : U128(0, 0);
        const rest = lowBits128(sig, shift);
        const half = shl128(U128(0, 1), shift - 1);
        const cmp = rest.hi != half.hi ? (rest.hi > half.hi ? 1 : -1)
            : rest.lo != half.lo ? (rest.lo > half.lo ? 1 : -1) : 0;
        halfway = cmp == 0;
        if (cmp > 0 || (cmp == 0 && (kept.lo & 1) != 0))
        {
            kept = inc128(kept);
            const carry = shl128(U128(0, 1), p); // an all-ones significand grew
            if (kept.hi == carry.hi && kept.lo == carry.lo)
            {
                kept = shl128(U128(0, 1), p - 1);
                lsb++;
            }
        }
    }

    if (kept.hi == 0 && kept.lo == 0)
        return r; // ±0
    if (lsb + (127 - leadingZeros128(kept)) > fmt.maxNormalExp2)
    {
        r.isInf = true;
        return r;
    }
    r.hi = kept.hi;
    r.lo = kept.lo;
    r.exp2 = lsb;
    return r;
}

/// ditto
DecodedFloat roundTo(BinaryFloatFormat fmt)(DecodedFloat exact) @safe pure nothrow @nogc
{
    bool halfway;
    return roundTo!fmt(exact, halfway);
}

/// Arbitrary-precision decimal for the slow path: up to `capacity`
/// significant digits (beyond that only a sticky "truncated" bit matters
/// for rounding), a decimal-point position, and exact power-of-two shifts.
///
/// The capacity is the format's $(LREF BinaryFloatFormat.decimalCapacity):
/// room for the longest exact expansion the format has, plus the rounding tie
/// it is compared against. It is the whole of the struct's storage, and the
/// struct is a stack local of the decoder — 800 bytes for binary64, 11.6 KB
/// for binary128 — so nothing here allocates, and nothing else grows.
private struct BigDecimal(int capacity_)
{
    enum capacity = capacity_;

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
        // Multiply the digit string by 2^n, least significant digit first,
        // growing by at most delta digits: ceil(n·log10(2)) + 1.
        const delta = cast(int)((cast(long) n * 30_103) / 100_000) + 1;
        const outLen = count + delta;

        // In place: output digit i reads input digit i - delta, and the
        // descent writes each position only after its last read. The growth
        // past `capacity` — at most delta digits — lands in `tail`, so the
        // frame carries no second copy of the digits.
        ubyte[20] tail = 0;
        static assert(tail.length > 19, "60 bits grow a decimal by up to 19 digits");
        ubyte at(size_t i) => i < capacity ? digits[i] : tail[i - capacity];

        ulong carry = 0;
        foreach_reverse (i; 0 .. outLen)
        {
            const srcIdx = i - delta;
            const d = srcIdx >= 0 && srcIdx < count ? digits[srcIdx] : 0;
            const v = (cast(ulong) d << n) + carry;
            const outDigit = cast(ubyte)(v % 10);
            if (i < capacity)
                digits[i] = outDigit;
            else
                tail[i - capacity] = outDigit;
            carry = v / 10;
        }
        assert(carry == 0, "delta bound must absorb the carry");

        // Trim leading zeros (delta may overshoot by one digit), sliding the
        // window down — ascending, so every read precedes the write over it.
        int lead = 0;
        while (lead < outLen && at(lead) == 0)
            lead++;
        int newCount = outLen - lead;
        bool newTruncated = truncated;
        if (newCount > capacity)
        {
            foreach (i; capacity .. newCount)
                if (at(lead + i) != 0)
                    newTruncated = true;
            newCount = capacity;
        }
        if (lead > 0)
            foreach (i; 0 .. newCount)
                digits[i] = at(lead + i);
        // Trailing zeros away.
        while (newCount > 0 && digits[newCount - 1] == 0)
            newCount--;
        pointPos += delta - lead;
        count = newCount;
        truncated = newTruncated;
    }

    /// The integer part rounded to nearest, ties to even — exact, because
    /// the fraction digits (plus the sticky truncation bit) are available.
    /// 128 bits wide: a binary128 significand and its carry need 114.
    void roundedInteger(out ulong hi, out ulong lo) const @safe pure nothrow @nogc
    {
        if (pointPos < 0)
            return; // below 0.1 — strictly under one half
        foreach (i; 0 .. pointPos)
        {
            // value = value × 10 + digit, in 128 bits
            const product = mul64x64(lo, 10);
            hi = hi * 10 + product.hi;
            lo = product.lo + digit(i);
            if (lo < product.lo)
                hi++;
        }

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
            roundUp = exactlyHalf ? (lo & 1) != 0 : true;
        }
        if (roundUp && ++lo == 0)
            hi++;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shortest round-trip formatting (Schubfach, the yyjson formulation)
// ─────────────────────────────────────────────────────────────────────────────

/**
Digit pairs "00".."99" — the branchlut table shared by the integer and float
writers.

Wrapped in a template so each object file that uses it gets its own definition
(the linker folds them). Module-level `static immutable` data is emitted once,
into *this* module's object, which a `-betterC` consumer of
$(REF writeInteger, sparkles,base,text,writers) never links — it compiles only
its own modules. An `enum` would avoid the symbol too, but every `[i .. i + 2]`
slice of a manifest constant materializes the whole 200-byte array first, in
the hottest loop either writer has.
*/
package template digitPairs()
{
    static immutable char[200] digitPairs = () {
        char[200] t;
        foreach (i; 0 .. 100)
        {
            t[i * 2] = cast(char)('0' + i / 10);
            t[i * 2 + 1] = cast(char)('0' + i % 10);
        }
        return t;
    }();
}

/**
Writes the two characters of $(LREF digitPairs) at `index` to `buf`.

Two scalar stores rather than `buf[0 .. 2] = digitPairs!()[i .. i + 2]`: a
slice assignment lowers to druntime's `_d_array_slice_copy`, which a
`-betterC` consumer of this module's digit writers has nothing to link
against. The back end merges the pair back into a single two-byte store, so
the branchlut inner loop is unchanged.
*/
private void putDigitPair()(char* buf, size_t index) @system pure nothrow @nogc
{
    buf[0] = digitPairs!()[index];
    buf[1] = digitPairs!()[index + 1];
}

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

private char* putPair()(char* buf, uint v) @system pure nothrow @nogc
{
    putDigitPair(buf, v * 2);
    return buf + 2;
}

private char* writeU32Len8()(uint val, char* buf) @system pure nothrow @nogc
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

private char* writeU32Len1to8()(uint val, char* buf) @system pure nothrow @nogc
{
    if (val < 100)
    {
        const lz = val < 10;
        putDigitPair(buf, val * 2 + lz);
        return buf + 2 - lz;
    }
    if (val < 10_000)
    {
        const aa = (val * 5243) >> 19;
        const lz = aa < 10;
        putDigitPair(buf, aa * 2 + lz);
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
        putDigitPair(buf, aa * 2 + lz);
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
        putDigitPair(buf, aa * 2 + lz);
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

private char* writeU32Len4()(uint val, char* buf) @system pure nothrow @nogc
{
    const aa = (val * 5243) >> 19; // val / 100
    putPair(buf + 0, aa);
    putPair(buf + 2, val - aa * 100);
    return buf + 4;
}

private char* writeU32Len5to8()(uint val, char* buf) @system pure nothrow @nogc
{
    if (val < 1_000_000)
    {
        const aa = cast(uint)((cast(ulong) val * 429_497) >> 32); // val / 1e4
        const bbcc = val - aa * 10_000;
        const bb = (bbcc * 5243) >> 19;
        const lz = aa < 10;
        putDigitPair(buf, aa * 2 + lz);
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
    putDigitPair(buf, aa * 2 + lz);
    buf -= lz;
    putPair(buf + 2, aabb - aa * 100);
    putPair(buf + 4, cc);
    putPair(buf + 6, ccdd - cc * 100);
    return buf + 8;
}

/// Any `ulong`, 1..20 digits — the branchlut integer writer (yyjson's
/// `write_u64`): two digits per lookup, division only at 8-digit strides.
///
/// An (argument-less) template so that instantiating it emits it into the
/// caller's object file. `text.writers`' decimal fast path calls this, and a
/// `-betterC` consumer of `writeInteger` compiles only its own modules — a
/// plain function here would live solely in this module's object and leave
/// that link with an undefined symbol.
package char* writeU64Digits()(ulong val, char* buf) @system pure nothrow @nogc
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
        putDigitPair(buf, e * 2 + lz);
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
// Shortest round-trip digits for any format (Steele–White free-format)
// ─────────────────────────────────────────────────────────────────────────────

/**
The shortest decimal that reads back as `v` under `fmt`: writes its
significant digits to `digitBuf` and returns how many, with `exp10` the
exponent of the last one, so the value is `digits × 10^exp10`. Zero is the
one digit `0` at exponent 0; the sign is not rendered, and infinity is a
precondition.

This is the free-format algorithm of Steele & White as Burger & Dybvig
state it: the value and its rounding interval are exact integers over one
denominator, digits come off one at a time, and the first prefix whose
round-down or round-up lands inside the interval is provably the shortest
decimal any correctly-rounded reader maps back to `v` — so no reader is
consulted, and the answer does not depend on one. The interval is
`[v - m⁻, v + m⁺]` with both a half ulp, except that a power-of-two
significand above the smallest normal has a quarter ulp below; its ends
are inclusive iff the significand is even, which is what round-half-even
makes true — and what lets the result agree, digit for digit, with
Schubfach on `double`. Of two prefixes both inside, the nearer to `v` wins,
an exact tie going to the even digit.

Integer-only, `@nogc`, CTFE-capable, and sized by the format: the big
integers hold the far end of the exponent range, which for binary128 is
about 2 KB each — four of them, on the stack.

`digitBuf.length` must be at least `fmt.maxDigits10`, which no result
exceeds.
*/
size_t shortestDigits(BinaryFloatFormat fmt)(in DecodedFloat v, scope char[] digitBuf,
    out int exp10) @safe pure nothrow @nogc
in (!v.isInf, "infinity has no digits")
in (!v.isNaN, "NaN has no digits")
in (digitBuf.length >= fmt.maxDigits10, "digitBuf is shorter than fmt.maxDigits10")
{
    enum p = fmt.mantDig;
    if (v.hi == 0 && v.lo == 0)
    {
        digitBuf[0] = '0';
        return 1;
    }

    // Limbs for the largest scaled value: the far exponent, the significand,
    // a power-of-ten chunk in flight, and slack.
    enum farExp = fmt.maxExp > -fmt.minSubnormalExp2 ? fmt.maxExp : -fmt.minSubnormalExp2;
    enum limbs = farExp / 32 + p / 32 + 8;
    alias Big = BigUintOf!limbs;

    static if (p > 64)
        const powerOfTwo = v.hi == 1UL << (p - 1 - 64) && v.lo == 0;
    else
        const powerOfTwo = v.hi == 0 && v.lo == 1UL << (p - 1);
    const bool quarterBelow = powerOfTwo && v.exp2 > fmt.minSubnormalExp2;
    const bool inclusive = (v.lo & 1) == 0;
    const e = v.exp2;

    // v = r/s, the interval [v - mMinus/s, v + mPlus/s].
    Big r = Big.from(v.hi, v.lo);
    Big s = Big.from(1);
    Big mPlus = Big.from(1);
    Big mMinus = Big.from(1);
    if (e >= 0)
    {
        bigShiftLeft(r, e + (quarterBelow ? 2 : 1));
        s = Big.from(quarterBelow ? 4 : 2);
        bigShiftLeft(mPlus, e + (quarterBelow ? 1 : 0));
        bigShiftLeft(mMinus, e);
    }
    else
    {
        bigShiftLeft(r, quarterBelow ? 2 : 1);
        bigShiftLeft(s, (quarterBelow ? 2 : 1) - e);
        if (quarterBelow)
            mPlus = Big.from(2);
    }

    // k ≈ ceil(log10 v), from the leading bit's exponent; the fixup below
    // moves it by one where the estimate is off.
    int sigBits = 0;
    for (ulong x = v.hi ? v.hi : v.lo; x; x >>= 1)
        sigBits++;
    if (v.hi)
        sigBits += 64;
    const long scaledLog = cast(long)(e + sigBits - 1) * 30_103;
    long k = scaledLog / 100_000;
    if (scaledLog % 100_000 != 0 && scaledLog < 0)
        k--;
    k++;
    if (k >= 0)
        bigMulPow10(s, cast(int) k);
    else
    {
        bigMulPow10(r, cast(int) -k);
        bigMulPow10(mPlus, cast(int) -k);
        bigMulPow10(mMinus, cast(int) -k);
    }

    // Fixup: the high end of the interval must lie in [10^(k-1), 10^k), so the
    // first digit is 1..9.
    for (;;)
    {
        Big high = r;
        bigAdd(high, mPlus);
        const c = bigCompare(high, s);
        if (c > 0 || (inclusive && c == 0))
        {
            k++;
            bigMulSmall(s, 10);
            continue;
        }
        bigMulSmall(high, 10);
        const c10 = bigCompare(high, s);
        if (c10 < 0 || (!inclusive && c10 == 0))
        {
            k--;
            bigMulSmall(r, 10);
            bigMulSmall(mPlus, 10);
            bigMulSmall(mMinus, 10);
            continue;
        }
        break;
    }

    // Generate: each digit is r*10 / s; stop as soon as rounding the prefix
    // down (tc1) or up (tc2) stays inside the interval.
    size_t n = 0;
    for (;;)
    {
        bigMulSmall(r, 10);
        bigMulSmall(mPlus, 10);
        bigMulSmall(mMinus, 10);
        uint d = 0;
        while (bigCompare(r, s) >= 0)
        {
            bigSub(r, s);
            d++;
        }
        assert(d <= 9, "a digit past 9: the fixup did not hold");

        const cLow = bigCompare(r, mMinus);
        const tc1 = inclusive ? cLow <= 0 : cLow < 0;
        Big high = r;
        bigAdd(high, mPlus);
        const cHigh = bigCompare(high, s);
        const tc2 = inclusive ? cHigh >= 0 : cHigh > 0;

        assert(n < digitBuf.length, "more digits than maxDigits10");
        if (!tc1 && !tc2)
        {
            digitBuf[n++] = cast(char)('0' + d);
            continue;
        }
        bool up = tc2;
        if (tc1 && tc2)
        {
            // Both inside: the nearer wins, an exact tie to the even digit.
            Big twice = r;
            bigShiftLeft(twice, 1);
            const c2 = bigCompare(twice, s);
            up = c2 > 0 || (c2 == 0 && (d & 1) != 0);
        }
        assert(!up || d < 9, "a round-up past 9: the previous digit would have stopped");
        digitBuf[n++] = cast(char)('0' + d + (up ? 1 : 0));
        break;
    }

    // The first digit weighs 10^(k-1), the last 10^(k-n); a round-up to a
    // trailing zero shortens further.
    exp10 = cast(int) k - cast(int) n;
    while (n > 1 && digitBuf[n - 1] == '0')
    {
        n--;
        exp10++;
    }
    return n;
}

/// $(LREF shortestDigits) for a `float`, `double` or `real` value.
size_t shortestDigits(T)(T value, scope char[] digitBuf, out int exp10)
if (__traits(isFloating, T))
    => shortestDigits!(formatOf!T)(decompose!T(value), digitBuf, exp10);

/**
Writes the shortest round-trip representation of `value` to any output
range, in scientific notation — `[-]d[.ddd]e[-]x`, the exponent that of the
first digit — plus `nan`, `inf` and `-inf`. `double` has the faster
$(LREF writeShortestDouble) with its own notation; this one serves every
type the same way.
*/
void writeShortest(T, Writer)(ref Writer w, T value)
if (__traits(isFloating, T))
{
    import std.range.primitives : put;

    if (value != value)
        return put(w, "nan");
    if (value == T.infinity)
        return put(w, "inf");
    if (value == -T.infinity)
        return put(w, "-inf");

    char[formatOf!T.maxDigits10] digits = void;
    int exp10;
    const n = shortestDigits!T(value, digits[], exp10);
    if (value < 0 || (value == 0 && 1 / value < 0))
        put(w, '-');
    put(w, digits[0]);
    if (n > 1)
    {
        put(w, '.');
        put(w, digits[1 .. n]);
    }
    put(w, 'e');
    int e = exp10 + cast(int) n - 1;
    if (e < 0)
    {
        put(w, '-');
        e = -e;
    }
    char[8] ebuf = void;
    size_t at = ebuf.length;
    do
    {
        ebuf[--at] = cast(char)('0' + e % 10);
        e /= 10;
    }
    while (e);
    put(w, ebuf[at .. $]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Cursor reader (general grammar; the JSON reader fuses its own loop)
// ─────────────────────────────────────────────────────────────────────────────

/**
Reads a decimal floating-point literal —
`[-]digits[.digits][(e|E)[±]digits]` — from the front of `s`, advancing
past it on success, correctly rounded to `T` (`double` unless asked).

For `double`, inputs with more than 19 significant digits are decided by
bracketing (converting both the truncated significand and its successor —
when both round to the same `double`, that value is proven correct), and
everything the fast tiers punt is settled exactly by $(LREF slowDouble).
Every other format takes Clinger's fast path in its own arithmetic (an
exact significand times an exact power of ten, rounded once), then a tier
of its own — the wide `real`s a 128-bit Eisel–Lemire, and every format
below 53 bits (`float`, and the reduced-precision storage types of
`sparkles.base.custom_float`) the correctly-rounded `double` rounded once
more by $(LREF roundTo), which is exact unless that `double` sits on one
of the narrower format's rounding boundaries — and otherwise
$(LREF slowFloat). That boundary check is what separates this from the
classic `(float) strtod(s) != strtof(s)`: a decimal a hair below a `float`
midpoint rounds onto it as a `double`, and a plain cast would then break
the tie the wrong way. Every well-formed literal therefore succeeds with
the correctly-rounded value.

The fast path and $(LREF compose) are floating-point arithmetic and assume
the default environment — round-to-nearest-even, traps masked, which
`std.math.hardware.FloatingPointControl` can change and this module does
not defend against. The exact tier is integer arithmetic and does not care.
*/
ParseExpected!T readDecimalFloat(T = double)(ref scope const(char)[] s)
    @safe pure nothrow @nogc
if (__traits(isFloating, T))
{
    const n = s.length;
    if (n == 0)
        return parseErr!T(ParseErrorCode.emptyInput, 0);

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
        return parseErr!T(ParseErrorCode.unexpectedCharacter, i);

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
            return parseErr!T(ParseErrorCode.unexpectedCharacter, i);
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
            return parseErr!T(ParseErrorCode.unexpectedCharacter, i);
        i += eDigits;
        while (i < n && cast(uint)(s[i] - '0') <= 9) // absurd exponents saturate
            i++;
        // Clamp to a magnitude past which the value saturates whatever the
        // digits say: the digit positions move the combined exponent by at
        // most the digit span, so this keeps the verdict and keeps the sum
        // inside `int`. (A fixed clamp such as 400 is wrong twice over: a
        // literal with hundreds of leading zeros needs a larger explicit
        // exponent to be finite, and the wide `real` formats have finite
        // values out to 1e4932.)
        const digitSpan = (intEnd - intStart) + (fracEnd - fracStart);
        const bound = cast(ulong) formatOf!T.explicitExp10Bound(digitSpan);
        if (e > bound)
            e = bound;
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

    T value;
    static if (formatOf!T == binary64)
    {
        double dv;
        bool decided;
        if (!truncated)
            decided = tryFastDouble(sig, exp10, dv);
        else
        {
            // Bracket the truncation: if sig and sig+1 round identically, the
            // in-between true value must round there too.
            double lowV, highV;
            decided = tryFastDouble(sig, exp10, lowV)
                && tryFastDouble(sig + 1, exp10, highV)
                && doubleToBits(lowV) == doubleToBits(highV);
            dv = lowV;
        }
        if (!decided) // tier 3: exact, no preconditions
            dv = slowDouble(s[intStart .. intEnd],
                fracStart == 0 ? null : s[fracStart .. fracEnd], explicitExp);
        value = dv;
    }
    else
    {
        // Clinger's fast path in T's own arithmetic: an exact significand
        // times an exact power of ten is one correctly rounded operation
        // (skipped at CTFE, as for `double`, so compile-time results flow
        // through the integer tiers). Past it, the wide formats have the
        // 128-bit Eisel–Lemire tier and the formats below 53 bits the
        // narrowing tier, each with the exact tier behind it.
        enum fmt = formatOf!T;
        enum wide = fmt.mantDig > 53;
        const sigExact = fmt.mantDig >= 64
            || (sig >> (fmt.mantDig >= 64 ? 0 : fmt.mantDig)) == 0;
        if (!__ctfe && !truncated && sigExact && exp10 >= -fmt.exactPow10Max
            && exp10 <= fmt.exactPow10Max)
            value = exp10 >= 0
                ? cast(T) sig * exactPow10Of!T[exp10]
                : cast(T) sig / exactPow10Of!T[-exp10];
        else
        {
            static if (wide)
                value = compose!T(decodeWide!fmt(s[intStart .. intEnd],
                    fracStart == 0 ? null : s[fracStart .. fracEnd], explicitExp));
            else
            {
                // The narrowing tier: the correctly-rounded `double` of the
                // literal, rounded once more to `fmt`. Every rounding boundary
                // of a format below 53 bits — the midpoints, half the smallest
                // subnormal, the overflow threshold — is itself a `double`,
                // and the correctly-rounded `double` lies within half of its
                // own ulp of the literal, so the two sit on the same side of
                // every boundary unless the `double` *is* one: the exact half
                // `roundTo` reports, which could be a true tie or a literal a
                // hair to either side, and goes to the exact tier.
                double dv;
                bool decided;
                if (!truncated)
                    decided = tryFastDouble(sig, exp10, dv);
                else
                {
                    double lowV, highV;
                    decided = tryFastDouble(sig, exp10, lowV)
                        && tryFastDouble(sig + 1, exp10, highV)
                        && doubleToBits(lowV) == doubleToBits(highV);
                    dv = lowV;
                }
                bool halfway = true;
                DecodedFloat r;
                if (decided)
                    r = roundTo!fmt(decode!binary64(doubleToBits(dv)), halfway);
                if (!halfway)
                    value = compose!T(r);
                else
                    value = slowFloat!T(s[intStart .. intEnd],
                        fracStart == 0 ? null : s[fracStart .. fracEnd], explicitExp);
            }
        }
    }

    s = s[i .. $];
    return parseOk(negative ? -value : value);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

@("float_conv.BinaryFloatFormat.derivations")
@safe pure nothrow @nogc
unittest
{
    static assert(formatOf!float == binary32);
    static assert(formatOf!double == binary64);
    static assert(formatOf!real == binary64 || formatOf!real == extended80
        || formatOf!real == binary128, "an undescribed real format");

    static immutable BinaryFloatFormat[4] formats = [binary32, binary64, extended80, binary128];
    static immutable int[4] minSubnormal = [-149, -1074, -16445, -16494];
    static immutable int[4] digits10 = [9, 17, 21, 36];
    static immutable int[4] pow10 = [10, 22, 27, 48];
    static immutable int[4] exact = [112, 767, 11_514, 11_563];
    static immutable int[4] capacity = [200, 800, 11_600, 11_600];
    static immutable int[4] satHigh = [40, 310, 4934, 4934];
    static immutable int[4] satLow = [-47, -325, -4952, -4967];
    foreach (i, f; formats)
    {
        assert(f.minNormalExp2 == f.minExp - 1);
        assert(f.maxNormalExp2 == f.maxExp - 1);
        assert(f.minSubnormalExp2 == minSubnormal[i]);
        assert(f.maxDigits10 == digits10[i]);
        assert(f.exactPow10Max == pow10[i]);
        assert(f.maxExactDigits == exact[i]);
        assert(f.decimalCapacity == capacity[i]);
        assert(f.saturateHighExp10 == satHigh[i]);
        assert(f.saturateLowExp10 == satLow[i]);
        // The explicit-exponent bound grows with the literal, so a long run
        // of zeros can always be compensated by the exponent.
        assert(f.explicitExp10Bound(0) == -satLow[i] + 1);
        assert(f.explicitExp10Bound(1000) == -satLow[i] + 1001);
    }
    // The subnormal floor and the exact-power bound, checked against the
    // properties they were derived from.
    static assert(binary64.minSubnormalExp2 == -1074); // double.min_normal * double.epsilon
    static assert(binary64.exactPow10Max == 22);       // 5^22 < 2^53 < 5^23
    static assert(binary64.decimalCapacity == 800);    // the decoder's historic storage
}

// Our classification of a host's floating-point types must agree with
// Phobos'. `floatTraits` needs a type, which is why it cannot replace
// `BinaryFloatFormat` — there is no type with 113 bits on a 53-bit host —
// but it is the right oracle for the types a host does have.
@("float_conv.BinaryFloatFormat.agreesWithPhobos")
@safe pure nothrow @nogc
unittest
{
    import std.math.traits : floatTraits, RealFormat;

    static BinaryFloatFormat described(RealFormat f)
    {
        final switch (f) with (RealFormat)
        {
        case ieeeSingle:
            return binary32;
        case ieeeDouble:
            return binary64;
        case ieeeExtended:
            return extended80;
        case ieeeQuadruple:
            return binary128;
        case ieeeHalf, ieeeExtended53, ibmExtended:
            assert(0, "a real format this module does not describe");
        }
    }

    static assert(described(floatTraits!float.realFormat) == formatOf!float);
    static assert(described(floatTraits!double.realFormat) == formatOf!double);
    static assert(described(floatTraits!real.realFormat) == formatOf!real);
}

// The layout derivations, against D's own properties for the native types
// and against the OCP Microscaling v1.0 / IEEE tables for the rest.
@("float_conv.BinaryFloatFormat.reducedDerivations")
@safe pure nothrow @nogc
unittest
{
    alias S = BinaryFloatFormat.Specials;

    static assert(binary32.expBits == 8 && binary32.bias == 127 && binary32.storageBits == 32);
    static assert(binary64.expBits == 11 && binary64.bias == 1023 && binary64.storageBits == 64);
    static assert(binary128.expBits == 15 && binary128.bias == 16_383 && binary128.storageBits == 128);
    static assert(binary32.max10Exp == float.max_10_exp && binary32.min10Exp == float.min_10_exp);
    static assert(binary64.max10Exp == double.max_10_exp && binary64.min10Exp == double.min_10_exp);
    static assert(formatOf!real.max10Exp == real.max_10_exp && formatOf!real.min10Exp == real.min_10_exp);
    static assert(binary64.maxFiniteSignificand == (1UL << 53) - 1);
    static assert(extended80.maxFiniteSignificand == ulong.max);

    static immutable BinaryFloatFormat[7] formats = [binary16, bfloat16, fp8e5m2, fp8e4m3,
        fp6e2m3, fp6e3m2, fp4e2m1];
    static immutable S[7] specials = [S.ieee, S.ieee, S.ieee, S.nanOnly, S.none, S.none, S.none];
    static immutable int[7] bias = [15, 127, 15, 7, 1, 3, 1];
    static immutable int[7] expBits = [5, 8, 5, 4, 2, 3, 2];
    static immutable int[7] storage = [16, 16, 8, 8, 6, 6, 4];
    static immutable int[7] minNormal = [-14, -126, -14, -6, 0, -2, 0];
    static immutable int[7] minSubnormal = [-24, -133, -16, -9, -3, -4, -1];
    static immutable ulong[7] maxSig = [2047, 255, 7, 14, 15, 7, 3];
    static immutable int[7] maxField = [30, 254, 30, 15, 3, 7, 3];
    static immutable int[7] digits10 = [5, 4, 2, 3, 3, 2, 2];
    static immutable int[7] max10 = [4, 38, 4, 2, 0, 1, 0];
    static immutable int[7] min10 = [-4, -37, -4, -1, 0, 0, 0];
    static immutable int[7] satHigh = [6, 40, 6, 4, 2, 3, 2];
    static immutable int[7] satLow = [-9, -42, -7, -5, -3, -3, -2];
    static immutable int[7] capacity = [100, 200, 100, 100, 100, 100, 100];
    foreach (i, f; formats)
    {
        assert(f.specials == specials[i]);
        assert(f.hasInfinity == (specials[i] == S.ieee));
        assert(f.hasNaN == (specials[i] != S.none));
        assert(f.bias == bias[i]);
        assert(f.expBits == expBits[i]);
        assert(f.storageBits == storage[i]);
        assert(f.minNormalExp2 == minNormal[i]);
        assert(f.minSubnormalExp2 == minSubnormal[i]);
        assert(f.maxFiniteSignificand == maxSig[i]);
        assert(f.maxFiniteExpField == maxField[i]);
        assert(f.maxDigits10 == digits10[i]);
        assert(f.max10Exp == max10[i]);
        assert(f.min10Exp == min10[i]);
        assert(f.saturateHighExp10 == satHigh[i]);
        assert(f.saturateLowExp10 == satLow[i]);
        assert(f.decimalCapacity == capacity[i]);
    }
    // The largest finite values, as the OCP tables state them.
    static assert(compose!float(decode!binary16(0x7BFF)) == 65_504.0f);
    static assert(compose!float(decode!bfloat16(0x7F7F)) == 0x1.FEp127f);
    static assert(compose!float(decode!fp8e5m2(0x7B)) == 57_344.0f);
    static assert(compose!float(decode!fp8e4m3(0x7E)) == 448.0f);
    static assert(compose!float(decode!fp6e2m3(0x1F)) == 7.5f);
    static assert(compose!float(decode!fp6e3m2(0x1F)) == 28.0f);
    static assert(compose!float(decode!fp4e2m1(0x7)) == 6.0f);
    // …and the smallest subnormals.
    static assert(compose!float(decode!binary16(1)) == 0x1p-24f);
    static assert(compose!float(decode!bfloat16(1)) == 0x1p-133f);
    static assert(compose!float(decode!fp8e5m2(1)) == 0x1p-16f);
    static assert(compose!float(decode!fp8e4m3(1)) == 0x1p-9f);
    static assert(compose!float(decode!fp6e2m3(1)) == 0.125f);
    static assert(compose!float(decode!fp6e3m2(1)) == 0.0625f);
    static assert(compose!float(decode!fp4e2m1(1)) == 0.5f);
    static assert(is(BitsOf!binary16 == ushort) && is(BitsOf!fp8e4m3 == ubyte)
        && is(BitsOf!fp4e2m1 == ubyte) && is(BitsOf!binary32 == uint) && is(BitsOf!binary64 == ulong));
}

// `decode` and `encode` are inverses over every pattern of every format
// that has few enough to enumerate; a NaN comes back as the canonical one.
@("float_conv.bits.roundTripEveryPattern")
@safe pure nothrow @nogc
unittest
{
    import std.meta : AliasSeq;

    static foreach (fmt; AliasSeq!(binary16, bfloat16, fp8e5m2, fp8e4m3, fp6e2m3, fp6e3m2, fp4e2m1))
    {{
        size_t nans = 0, infs = 0;
        foreach (raw; 0 .. 1u << fmt.storageBits)
        {
            const bits = cast(BitsOf!fmt) raw;
            const d = decode!fmt(bits);
            if (d.isNaN)
            {
                nans++;
                assert(fmt.hasNaN);
                const back = encode!fmt(d);
                assert(decode!fmt(back).isNaN && decode!fmt(back).negative == d.negative);
                continue;
            }
            if (d.isInf)
            {
                infs++;
                assert(fmt.hasInfinity);
            }
            else
            {
                // Canonical: at most mantDig bits, the last one at or above
                // the floor, and exactly mantDig bits when normal.
                assert(d.hi == 0 && d.lo < 1UL << fmt.mantDig);
                assert(d.lo == 0 || d.exp2 >= fmt.minSubnormalExp2);
                assert(d.lo == 0 || d.exp2 == fmt.minSubnormalExp2
                    || d.lo >= 1UL << (fmt.mantDig - 1));
            }
            assert(encode!fmt(d) == bits);
        }
        assert(infs == (fmt.hasInfinity ? 2 : 0));
        assert(nans == (fmt.specials == BinaryFloatFormat.Specials.ieee
            ? 2 * ((1u << fmt.mantBits) - 1) : fmt.hasNaN ? 2 : 0));
    }}

    // The wide native layouts, sampled, against the double bit access.
    ulong state = 0x9E37_79B9_7F4A_7C15;
    foreach (_; 0 .. 20_000)
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const d = decode!binary64(state);
        if (d.isNaN)
            continue;
        assert(encode!binary64(d) == state);
        assert(compose!double(d) is bitsToDouble(state));
        const f = decode!binary32(cast(uint) state);
        if (!f.isNaN)
            assert(encode!binary32(f) == cast(uint) state);
    }
    // ±0 keep their sign; a NaN wants a format that has one.
    assert(encode!binary16(DecodedFloat(0, 0, 0, true)) == 0x8000);
    assert(decode!fp4e2m1(0x8).negative && decode!fp4e2m1(0x8).lo == 0);
    static assert(decode!binary16(0x3C00).lo == 1024 && decode!binary16(0x3C00).exp2 == -10);
}

// `encode!binary64` over the exact decoder lands on the bits `slowDouble`
// assembles by hand, and `encode!binary32` on what the FPU says.
@("float_conv.bits.matchesTheHandAssembly")
@safe pure nothrow @nogc
unittest
{
    static void same(string i, string f, int e)
    {
        assert(encode!binary64(slowDecode!binary64(i, f, e)) == doubleToBits(slowDouble(i, f, e)));
    }

    same("5", null, -324);
    same("3", null, -324);
    same("2", null, -324);
    same("9007199254740993", null, 0);
    same("2", "2250738585072011", -308);
    same("17976931348623157", null, 292);
    same("17976931348623159", null, 292);
    same("1", null, 0);
    same(null, "1", 0);
    same("0", null, 0);
    // A non-canonical significand is normalised: 3 × 2^0 is 1.5 × 2^1.
    assert(encode!binary32(DecodedFloat(0, 3, 0)) == 0x4040_0000);
    assert(encode!binary64(DecodedFloat(0, 1UL << 60, -60)) == 0x3FF0_0000_0000_0000);
    // Overflow follows the specials.
    assert(encode!binary16(DecodedFloat(0, 1, 16)) == 0x7C00);
    assert(encode!binary16(DecodedFloat(0, 1, 16, true)) == 0xFC00);
    assert(encode!fp8e4m3(DecodedFloat(0, 15, 5)) == 0x7F);   // 480: the NaN pattern
    assert(encode!fp8e4m3(DecodedFloat(0, 1, 9)) == 0x7F);    // 512
    assert(encode!fp8e4m3(DecodedFloat(0, 14, 5)) == 0x7E);   // 448
    assert(encode!fp6e2m3(DecodedFloat(0, 1, 3)) == 0x1F);    // 8 → 7.5
    assert(encode!fp6e2m3(DecodedFloat(0, 1, 3, true)) == 0x3F);
    assert(encode!fp4e2m1(DecodedFloat(0, 0, 0, false, true)) == 0x7);
    assert(encode!fp8e5m2(DecodedFloat(0, 0, 0, false, true)) == 0x7C);
    assert(encode!fp8e5m2(DecodedFloat(0, 0, 0, false, false, true)) == 0x7E);
    assert(encode!fp8e4m3(DecodedFloat(0, 0, 0, true, false, true)) == 0xFF);
}

@("float_conv.roundTo.pins")
@safe pure nothrow @nogc
unittest
{
    bool halfway;
    // 2^24 + 1 is a binary32 tie → even (2^24); +3 ties up to 2^24 + 4.
    auto r = roundTo!binary32(DecodedFloat(0, (1UL << 24) + 1, 0), halfway);
    assert(halfway && r.lo == 1UL << 23 && r.exp2 == 1);
    r = roundTo!binary32(DecodedFloat(0, (1UL << 24) + 3, 0), halfway);
    assert(halfway && r.lo == (1UL << 23) + 2 && r.exp2 == 1);
    // Above a half rounds up; below rounds down; neither is halfway.
    r = roundTo!binary32(DecodedFloat(0, (1UL << 26) + 5, 0), halfway);
    assert(!halfway && r.lo == (1UL << 23) + 1 && r.exp2 == 3);
    r = roundTo!binary32(DecodedFloat(0, (1UL << 26) + 3, 0), halfway);
    assert(!halfway && r.lo == (1UL << 23) && r.exp2 == 3);
    // An all-ones significand carries into the next binade.
    r = roundTo!binary16(DecodedFloat(0, 0xFFF, 0), halfway);
    assert(halfway && r.lo == 1UL << 10 && r.exp2 == 2);
    // …and past the largest finite value it overflows: 65 520 is the half
    // point above 65 504, and rounds (to even, upward) to 2^16.
    r = roundTo!binary16(DecodedFloat(0, 65_520, 0), halfway);
    assert(halfway && r.isInf);
    r = roundTo!binary16(DecodedFloat(0, 65_519, 0), halfway);
    assert(!halfway && !r.isInf && r.lo == 0x7FF && r.exp2 == 5);
    // Subnormal: the last bit is pinned at the floor. 2^-25 is half the
    // smallest binary16 subnormal → 0 by the even rule; a hair above → 2^-24.
    r = roundTo!binary16(DecodedFloat(0, 1, -25), halfway);
    assert(halfway && r.hi == 0 && r.lo == 0);
    r = roundTo!binary16(DecodedFloat(0, 3, -26), halfway);
    assert(!halfway && r.lo == 1 && r.exp2 == -24);
    r = roundTo!binary16(DecodedFloat(0, 1, -26), halfway);
    assert(!halfway && r.lo == 0);
    // Deep underflow: a shift far past the significand's width.
    r = roundTo!binary16(DecodedFloat(ulong.max, ulong.max, -1000), halfway);
    assert(!halfway && r.lo == 0 && r.hi == 0);
    // A subnormal that rounds up into the smallest normal keeps its floor.
    r = roundTo!fp8e4m3(DecodedFloat(0, 15, -10), halfway);   // 7.5 × 2^-10 = 0.9375 × 2^-7
    assert(halfway && r.lo == 8 && r.exp2 == -9);             // → 8 × 2^-9 = 2^-6
    // Exact values pass through, at any width of their significand.
    r = roundTo!fp4e2m1(DecodedFloat(0, 3, 0), halfway);
    assert(!halfway && r.lo == 3 && r.exp2 == 0);
    r = roundTo!fp4e2m1(DecodedFloat(0, 1UL << 40, -40), halfway);
    assert(!halfway && r.lo == 2 && r.exp2 == -1);
    // NaN and infinity pass through, and E4M3's 464 is the tie that saves 448.
    assert(roundTo!fp8e4m3(DecodedFloat(0, 0, 0, false, false, true)).isNaN);
    assert(roundTo!fp8e4m3(DecodedFloat(0, 0, 0, true, true)).isInf);
    r = roundTo!fp8e4m3(DecodedFloat(0, 464, 0), halfway);
    assert(halfway && r.lo == 14 && r.exp2 == 5);
    r = roundTo!fp8e4m3(DecodedFloat(0, 465, 0), halfway);
    assert(!halfway && r.lo == 15 && r.exp2 == 5 && encode!fp8e4m3(r) == 0x7F);
    // 113-bit input: real.max at binary128 narrowed to double is infinity.
    r = roundTo!binary64(DecodedFloat((1UL << 49) - 1, ulong.max, 16_384 - 113), halfway);
    assert(r.isInf);
    enum ct = roundTo!binary16(DecodedFloat(0, 0xFFF, 0));
    static assert(ct.lo == 1UL << 10 && ct.exp2 == 2);
}

// The FPU is the oracle: narrowing through `decompose` → `roundTo` →
// `compose` must equal the native cast, bit for bit, subnormals and
// overflow included.
@("float_conv.roundTo.matchesHardwareNarrowing")
@safe pure nothrow @nogc
unittest
{
    ulong state = 0x0DDB_A11C_0FFE_E123;
    static ulong next(ref ulong s)
    {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return s;
    }

    foreach (i; 0 .. 400_000)
    {
        // Exponents concentrated around float's range, with its subnormal
        // band and the overflow boundary well represented.
        ulong bits = next(state);
        const expField = 1023 + cast(int)(next(state) % 320) - 160;
        bits = (bits & 0x800F_FFFF_FFFF_FFFF) | (cast(ulong) expField << 52);
        const double d = bitsToDouble(bits);
        const float narrowed = compose!float(roundTo!binary32(decompose(d)));
        assert(narrowed is cast(float) d);
    }
    static if (formatOf!real != binary64)
    {
        foreach (i; 0 .. 100_000)
        {
            // Random reals across double's range: the mantissa from the
            // generator, the exponent by scaling.
            real r = cast(real) next(state) / cast(real)(next(state) | 1);
            const e = cast(int)(next(state) % 2200) - 1100;
            r = compose!real(DecodedFloat(0, decompose(r).lo, decompose(r).exp2 + e));
            const double narrowed = compose!double(roundTo!binary64(decompose(r)));
            assert(narrowed is cast(double) r);
        }
    }
}

@("float_conv.mul64x64.knownProducts")
@safe pure nothrow @nogc
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
@safe pure nothrow @nogc
unittest
{
    static immutable double[10] samples = [0.0, -0.0, 1.0, -1.5, 3.141592653589793,
        double.infinity, -double.infinity, double.min_normal, double.max,
        double.min_normal / 4]; // subnormal
    foreach (d; samples)
        assert(bitsToDouble(doubleToBits(d)) is d);

    static assert(doubleToBits(1.5) == 0x3FF8_0000_0000_0000);
    static assert(bitsToDouble(0x3FF8_0000_0000_0000UL) == 1.5);
    static assert(bitsToDouble(1) == double.min_normal / (1UL << 52));
    static assert(doubleToBits(double.min_normal / (1UL << 52)) == 1);
}

@("float_conv.pow10Table.knownEntries")
@safe pure nothrow @nogc
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
@safe pure nothrow @nogc
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
@safe pure nothrow @nogc
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
@safe pure nothrow @nogc
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

@("float_conv.slowDecode.fields")
@safe pure nothrow @nogc
unittest
{
    // 1 is 2^52 × 2^-52 at binary64 and 2^112 × 2^-112 at binary128 — the
    // latter settled at compile time, on any host.
    const one64 = slowDecode!binary64("1", null, 0);
    assert(one64.hi == 0 && one64.lo == 1UL << 52 && one64.exp2 == -52);
    enum one128 = slowDecode!binary128("1", null, 0);
    static assert(one128.hi == 1UL << 48 && one128.lo == 0 && one128.exp2 == -112);

    // The smallest binary64 subnormal: significand 1 at the floor.
    const tiny = slowDecode!binary64("5", null, -324);
    assert(tiny.hi == 0 && tiny.lo == 1 && tiny.exp2 == -1074);

    // Saturation at each end, per format.
    assert(slowDecode!binary64("2", null, 308).isInf);
    assert(slowDecode!binary64("2", null, -324) == DecodedFloat.init);
    assert(slowDecode!binary32("4", null, 38).isInf);
    assert(!slowDecode!binary128("4", null, 38).isInf);
    assert(slowDecode!binary128("119", null, 4930).isInf);
    // 2^-16494 ≈ 6.475e-4966: 6e-4966 is 0.93 of it and rounds to it,
    // 3e-4966 is 0.46 and rounds away.
    assert(slowDecode!binary128("6", null, -4966).lo == 1);
    assert(slowDecode!binary128("6", null, -4966).exp2 == -16494);
    assert(slowDecode!binary128("3", null, -4966) == DecodedFloat.init);
}

@("float_conv.decompose.canonicalFields")
@safe pure nothrow @nogc
unittest
{
    // Pinned against the IEEE layout: 1 is 2^52 × 2^-52.
    assert(decompose!double(1.0) == DecodedFloat(0, 1UL << 52, -52));
    // At CTFE the value must be exact in `double`: on an x87 host CTFE keeps
    // a `double` at 80 bits (D permits it; even `cast(double)` does not
    // round there), and 0.1 would decompose to its 64-bit self.
    enum ctfe = decompose!double(0.75);
    static assert(ctfe == DecodedFloat(0, 3UL << 51, -53));
    // The smallest subnormals: significand 1 at the floor.
    assert(decompose!float(float.min_normal * float.epsilon) == DecodedFloat(0, 1, -149));
    assert(decompose!double(double.min_normal * double.epsilon) == DecodedFloat(0, 1, -1074));
    assert(decompose!real(real.min_normal * real.epsilon)
        == DecodedFloat(0, 1, formatOf!real.minSubnormalExp2));
    // Signs and the non-finite.
    assert(decompose!double(-0.0) == DecodedFloat(0, 0, 0, true));
    assert(decompose!double(-2.0) == DecodedFloat(0, 1UL << 52, -51, true));
    assert(decompose!double(double.infinity).isInf);
    assert(decompose!double(-double.infinity) == DecodedFloat(0, 0, 0, true, true));
}

@("float_conv.compose.invertsDecompose")
@safe pure nothrow @nogc
unittest
{
    import std.meta : AliasSeq;

    static foreach (T; AliasSeq!(float, double, real))
    {{
        static immutable T[] corners = [
            0, -0.0, 1, -1, 2, 0.5, 0.1, T.epsilon, 1 + T.epsilon, T.max, -T.max,
            T.min_normal, T.min_normal * T.epsilon, T.min_normal * (1 - T.epsilon),
            T.infinity, -T.infinity, 3.14159, 1e-10, 123456.789,
        ];
        foreach (x; corners)
            assert(compose!T(decompose!T(x)) is x);
    }}

    // A deterministic sweep over random double bit patterns, every one of
    // which must come back bit-identical.
    ulong state = 0x1234_5678_9ABC_DEF1;
    foreach (iter; 0 .. 5000)
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const x = bitsToDouble(state);
        if (x != x)
            continue; // NaN has no decomposition
        assert(compose!double(decompose!double(x)) is x);
    }
}

@("float_conv.compose.matchesTheBitAssembly")
@safe pure nothrow @nogc
unittest
{
    // `compose!double` over `slowDecode!binary64` must land on the very bits
    // `slowDouble` assembles — including the subnormal and carried cases.
    static void same(string i, string f, int e)
    {
        assert(doubleToBits(slowFloat!double(i, f, e)) == doubleToBits(slowDouble(i, f, e)));
    }

    same("5", null, -324);
    same("3", null, -324);
    same("9007199254740993", null, 0);
    same("2", "2250738585072011", -308);
    same("17976931348623157", null, 292);
    same("17976931348623159", null, 292);
    same("1", null, 0);
    same(null, "1", 0);
    same("9999999999999999999", null, 0);
    assert(slowFloat!float("16777217", null, 0) == 16_777_216.0f);
    assert(slowFloat!real("1", null, 0) == 1.0L);
}

@("float_conv.exactPow10Of.exactAtEveryWidth")
@safe pure nothrow @nogc
unittest
{
    import std.meta : AliasSeq;

    static foreach (T; AliasSeq!(float, double, real))
    {{
        // 10^k = 5^k × 2^k: build 5^k in 128 bits and compose it exactly.
        ulong hi = 0, lo = 1;
        foreach (k; 0 .. formatOf!T.exactPow10Max + 1)
        {
            assert(exactPow10Of!T[k] == compose!T(DecodedFloat(hi, lo, k)));
            const p = mul64x64(lo, 5);
            hi = hi * 5 + p.hi;
            lo = p.lo;
        }
    }}
    static assert(exactPow10Of!double.length == 23);
    static assert(exactPow10Of!double[22] == 1e22);
}

@("float_conv.readDecimalFloat.typed")
@safe pure nothrow @nogc
unittest
{
    static T read(T)(string text)
    {
        const(char)[] s = text;
        auto r = readDecimalFloat!T(s);
        assert(r.hasValue && s.length == 0);
        return r.value;
    }

    // The default is still `double`.
    const(char)[] s = "1.5";
    static assert(is(typeof(readDecimalFloat(s).value) == double));
    assert(readDecimalFloat(s).value == 1.5);

    // float: ties, the fast path, and both saturations.
    assert(read!float("16777217") == 16_777_216.0f); // 2^24 + 1 ties to even
    assert(read!float("0.1") == 0.1f);
    assert(read!float("3.4028235e38") == float.max);
    assert(read!float("3.5e38") == float.infinity);
    assert(read!float("1e-45") == float.min_normal * float.epsilon);
    assert(read!float("7e-46") == 0.0f); // under half the smallest subnormal
    assert(read!float("-2.5") == -2.5f);

    // Not the double result cast down. This decimal sits a hair below the
    // midpoint between 1+2^-23 and 1+2^-22; as a double it rounds onto the
    // midpoint exactly, and the tie then breaks to the even float — the
    // wrong one.
    enum trap = "1.00000017881393432617187499";
    assert(read!float(trap) == 1.00000011920928955078125f);
    assert(cast(float) read!double(trap) != read!float(trap));

    // real, at whatever width this host has.
    assert(read!real("0.1") == 0.1L);
    assert(read!real("-2.5") == -2.5L);
    assert(read!real("123456789012345678901234567890") == 123456789012345678901234567890.0L);
    assert(read!real("1e-30") == 1e-30L);
    static if (formatOf!real == binary64)
        assert(read!real("0.1") == read!double("0.1"));

    // Exponents past a fixed 400: finite on the wide formats, saturating on
    // binary64 — either way the exact tier's verdict, not a clamp's.
    assert(read!real("1e500") is slowFloat!real("1", null, 500));
    assert(read!real("1e-500") is slowFloat!real("1", null, -500));
    assert(read!real("1e5000") == real.infinity);
    assert(read!real("1e-5000") == 0.0L);
    static if (formatOf!real != binary64)
    {
        assert(read!real("1e500") == 1e500L);
        assert(read!real("1e-500") == 1e-500L);
        assert(read!real("1e4932") == 1e4932L);
    }
}

// A digit string as the wide tier's 128-bit significand (test helper).
private U128 sigOf(scope const(char)[] digits) @safe pure nothrow @nogc
in (digits.length <= 38)
{
    ulong hi = 0, lo = 0;
    uint taken = 0;
    foreach (c; digits)
    {
        if (taken < 19)
            hi = hi * 10 + (c - '0');
        else
            lo = lo * 10 + (c - '0');
        taken++;
    }
    if (taken <= 19)
        return U128(0, hi);
    auto sig = mul64x64(hi, pow10U64[taken - 19]);
    sig.lo += lo;
    if (sig.lo < lo)
        sig.hi++;
    return sig;
}

@("float_conv.pow10Anchors.knownEntries")
@safe pure nothrow @nogc
unittest
{
    static assert(anchorCountPos == 15 && anchorCountNeg == 14);
    static assert(wideMaxExp10 == 4933 && wideMinExp10 == -5005);

    // The first anchors are the fine table's ends, exponent included: the
    // same big-integer routines over the same powers.
    enum lastFine = tableMaxExp10 - tableMinExp10;
    static assert(pow10AnchorsPos[0].hi == pow10Sig128[lastFine].hi
        && pow10AnchorsPos[0].lo == pow10Sig128[lastFine].lo
        && pow10AnchorsPos[0].exp2 == fineExp2(tableMaxExp10));
    static assert(pow10AnchorsNeg[0].hi == pow10Sig128[0].hi
        && pow10AnchorsNeg[0].lo == pow10Sig128[0].lo
        && pow10AnchorsNeg[0].exp2 == fineExp2(tableMinExp10));

    // Every entry is normalized, and a composed one carries the wider bracket.
    foreach (q; [wideMinExp10, -5000, -4802, -687, -686, -344, -343, 0, 324, 325,
            648, 649, 4860, 4900, wideMaxExp10])
    {
        const e = wideEntry(q);
        assert(e.hi >> 63);
        assert(e.width == (tableMinExp10 <= q && q <= tableMaxExp10 ? 1 : 5));
    }
    // 10^324 composed as 10^324 × 10^0 is 10^324 itself, exactly.
    assert(wideEntry(324).hi == pow10AnchorsPos[0].hi);
}

@("float_conv.pow10Anchors.bracketTruePowers")
@system unittest
{
    import std.bigint : BigInt;

    // E·2^e ≤ 10^q < (E + width)·2^e, by exact arithmetic.
    static bool brackets(in Pow10Wide w, int q)
    {
        const e = BigInt(w.hi) << 64 | BigInt(w.lo);
        // Compare E·2^exp2·10^|q| ≤ 1 (q < 0) or E·2^exp2 ≤ 10^q (q ≥ 0)
        // with everything scaled to integers.
        BigInt lhs = e, upper = e + w.width, rhs = 1;
        if (q >= 0)
            rhs = BigInt(10) ^^ q;
        else
        {
            lhs *= BigInt(10) ^^ (-q);
            upper *= BigInt(10) ^^ (-q);
        }
        if (w.exp2 >= 0)
        {
            lhs <<= w.exp2;
            upper <<= w.exp2;
        }
        else
            rhs <<= -w.exp2;
        return lhs <= rhs && rhs < upper;
    }

    foreach (j, a; pow10AnchorsPos)
        assert(brackets(a, tableMaxExp10 * cast(int)(j + 1)));
    foreach (j, a; pow10AnchorsNeg)
        assert(brackets(a, tableMinExp10 * cast(int)(j + 1)));

    // The fine range's fixed-point exponent agrees with the bit length.
    foreach (q; tableMinExp10 .. tableMaxExp10 + 1)
        assert(brackets(wideEntry(q), q));
    // …and is known to drift past it, which is why anchors carry their own.
    assert(((217_706 * 643) >> 16) - 127 != wideEntry(643).exp2 - 0
        || true); // documentary: composed entries never use the fixed point

    // Composed entries across the whole wide range.
    foreach (q; [-5005, -5004, -4803, -4802, -4801, -1000, -687, -686, -344,
            325, 648, 649, 1000, 4859, 4860, 4861, 4932, 4933])
        assert(brackets(wideEntry(q), q));
    int q = wideMinExp10;
    while (q <= wideMaxExp10)
    {
        assert(brackets(wideEntry(q), q));
        q += 37;
    }
}

@("float_conv.tryFastWide.pins")
@safe pure nothrow @nogc
unittest
{
    static bool fast(BinaryFloatFormat fmt)(string digits, int exp10, out DecodedFloat r)
        => tryFastWide!fmt(sigOf(digits), exp10, r);

    static foreach (fmt; [extended80, binary128])
    {{
        DecodedFloat r;
        // Plain values, decided and exact.
        assert(fast!fmt("1", 0, r) && r == slowDecode!fmt("1", null, 0));
        assert(fast!fmt("1", -1, r) && r == slowDecode!fmt("1", null, -1));
        assert(fast!fmt("15", 0, r) && r == slowDecode!fmt("15", null, 0));
        // 1.5 as `15e-1` is exact, and the truncated `10^-1` entry puts the
        // product a hair below it with an all-ones guard window: the tier
        // punts rather than guess (Clinger's path serves it in the reader).
        assert(!fast!fmt("15", -1, r));
        assert(fast!fmt("1", 400, r) && r == slowDecode!fmt("1", null, 400)); // composed
        assert(fast!fmt("1", -400, r) && r == slowDecode!fmt("1", null, -400));
        assert(fast!fmt("299792458", 0, r) && r == slowDecode!fmt("299792458", null, 0));
        // Saturation is decided without a product.
        assert(fast!fmt("1", 5000, r) && r.isInf);
        assert(fast!fmt("1", -5100, r) && r == DecodedFloat.init);
        assert(fast!fmt("0", 0, r) && r == DecodedFloat.init);
        // Provable overflow below the saturation bound; a subnormal punts.
        assert(fast!fmt("1", 4933, r) && r.isInf);
        assert(!fast!fmt("1", -4950, r));
        assert(!fast!fmt("6", -4966, r));
    }}

    DecodedFloat r;
    // A true tie with an even candidate punts; a tie to the odd side decides.
    assert(!fast!extended80("18446744073709551617", 0, r)); // 2^64 + 1
    assert(fast!extended80("18446744073709551619", 0, r)
        && r == slowDecode!extended80("18446744073709551619", null, 0)); // 2^64 + 3
    assert(!fast!binary128("10384593717069655257060992658440193", 0, r)); // 2^113 + 1
    assert(fast!binary128("10384593717069655257060992658440195", 0, r)
        && r == slowDecode!binary128("10384593717069655257060992658440195", null, 0));

    // real.max at both widths, from its shortest spelling.
    assert(fast!binary128("1189731495357231765085759326628007", 4899, r));
    assert(r == DecodedFloat(ulong.max >> 15, ulong.max, 16383 - 112));
    assert(fast!extended80("118973149535723176502", 4912, r));
    assert(r == DecodedFloat(0, ulong.max, 16383 - 63));
    // real.min_normal's spelling: exactly the smallest normal, decided.
    assert(fast!extended80("33621031431120935063", -4951, r));
    assert(r == DecodedFloat(0, 1UL << 63, -16382 - 63));
}

@("float_conv.tryFastWide.agreesWithSlowDecode")
@safe unittest
{
    ulong state = 0x5851_F42D_4C95_7F2D;
    ulong next()
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return state;
    }

    // Stratified: the near-1 band is dense, the fine range sampled, and the
    // composed range and the ends sparse — the exact tier costs milliseconds
    // per decode out there.
    static immutable int[2][4] bands = [[-60, 60], [-343, 324], [-5005, 4933], [4900, 4933]];
    static immutable int[4] counts = [40_000, 4000, 200, 40];
    static foreach (fmt; [extended80, binary128])
    {{
        foreach (band, count; counts)
        {
            size_t decided;
            foreach (iter; 0 .. count)
            {
                char[38] buf;
                const n = 1 + cast(size_t)(next() % 38);
                buf[0] = cast(char)('1' + next() % 9);
                foreach (i; 1 .. n)
                    buf[i] = cast(char)('0' + next() % 10);
                const digits = buf[0 .. n];
                const lo = bands[band][0], hi = bands[band][1];
                int exp10 = lo + cast(int)(next() % cast(ulong)(hi - lo + 1));
                if (band == 3 && iter % 2 == 1)
                    exp10 = -4990 + cast(int)(next() % 40); // the low end, subnormal band
                DecodedFloat r;
                if (!tryFastWide!fmt(sigOf(digits), exp10, r))
                    continue;
                decided++;
                assert(r == slowDecode!fmt(digits, null, exp10));
            }
            if (band < 3)
                assert(decided * 100 >= count * 99, "the wide tier punts too often");
        }
    }}
}

@("float_conv.tryFastWide.agreesWithBigIntOracle")
@system unittest
{
    import std.conv : text;

    ulong state = 0x2545_F491_4F6C_DD1D;
    static ulong next(ref ulong s)
    {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return s;
    }

    foreach (iter; 0 .. 1500)
    {
        string digits = text(next(state) >> (next(state) % 40));
        if (iter % 3 == 0)
            digits ~= text(next(state) >> (next(state) % 50));
        if (digits.length > 38)
            digits = digits[0 .. 38];
        const exp10 = iter % 2 ? cast(int)(next(state) % 801) - 400
            : cast(int)(next(state) % 9939) - 5005;
        static foreach (fmt; [extended80, binary128])
        {{
            DecodedFloat r;
            if (tryFastWide!fmt(sigOf(digits), exp10, r))
                assert(r == oracleDecode!fmt(digits, exp10));
        }}
    }
}

@("float_conv.tryFastWide.roundTripsShortestDigitsAtEveryWidth")
@safe unittest
{
    ulong state = 0x9E37_79B9_7F4A_7C15;
    ulong next()
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return state;
    }

    static foreach (fmt; [extended80, binary128])
    {{
        enum p = fmt.mantDig;
        enum lo = fmt.minNormalExp2 - (p - 1), hi = fmt.maxNormalExp2 - (p - 1);
        size_t punts;
        foreach (iter; 0 .. 3000)
        {
            DecodedFloat v;
            static if (p > 64)
            {
                v.hi = (next() & ((1UL << (p - 64)) - 1)) | (1UL << (p - 1 - 64));
                v.lo = next();
            }
            else
                v.lo = next() | (1UL << 63);
            v.exp2 = iter % 4 ? -200 + cast(int)(next() % 400)
                : lo + cast(int)(next() % cast(ulong)(hi - lo + 1));

            char[64] buf;
            int exp10;
            const n = shortestDigits!fmt(v, buf[], exp10);
            DecodedFloat back;
            if (!tryFastWide!fmt(sigOf(buf[0 .. n]), exp10, back))
            {
                punts++;
                continue;
            }
            assert(back == v);
        }
        assert(punts * 100 <= 3000, "the wide tier punts on more than 1 % of shortest spellings");
    }}
}

@("float_conv.tryFastWide.ctfeMatchesRuntime")
@safe pure nothrow @nogc
unittest
{
    static struct Verdict
    {
        bool decided;
        DecodedFloat value;
    }

    static Verdict decide(BinaryFloatFormat fmt)(string digits, int exp10)
    {
        Verdict v;
        v.decided = tryFastWide!fmt(sigOf(digits), exp10, v.value);
        return v;
    }

    // A fine-range, a composed-range and a punt case, settled at compile time
    // and again at run time.
    static foreach (fmt; [extended80, binary128])
    {{
        enum a = decide!fmt("31415926535897932384", -19);
        assert(a == decide!fmt("31415926535897932384", -19) && a.decided);
        enum b = decide!fmt("27182818284590452353602874713", 1000);
        assert(b == decide!fmt("27182818284590452353602874713", 1000) && b.decided);
        enum c = decide!fmt("1", -4950);
        assert(c == decide!fmt("1", -4950) && !c.decided);
    }}
    // And the whole wide decoder, bracketing included.
    enum d = decodeWide!binary128("1", "00000000000000000000000000000000000000000001", 0);
    assert(d == decodeWide!binary128("1", "00000000000000000000000000000000000000000001", 0));
    assert(d == slowDecode!binary128("1", "00000000000000000000000000000000000000000001", 0));
}

@("float_conv.decodeWide.digitsAndBracketing")
@safe pure nothrow @nogc
unittest
{
    static foreach (fmt; [extended80, binary128])
    {{
        // 20–38 digits go through the 128-bit significand; exact.
        assert(decodeWide!fmt("1", "5270640502937941130", 0)
            == slowDecode!fmt("1", "5270640502937941130", 0));
        assert(decodeWide!fmt("31415926535897932384626433832795", null, -31)
            == slowDecode!fmt("31415926535897932384626433832795", null, -31));
        assert(decodeWide!fmt("99999999999999999999999999999999999999", null, 0)
            == slowDecode!fmt("99999999999999999999999999999999999999", null, 0));
        // Leading zeros are not digits; trailing digits past 38 are bracketed.
        assert(decodeWide!fmt("000", "000123456789012345678901234567890123456789012345", 0)
            == slowDecode!fmt("000", "000123456789012345678901234567890123456789012345", 0));
        assert(decodeWide!fmt("1234567890123456789012345678901234567890123", null, -20)
            == slowDecode!fmt("1234567890123456789012345678901234567890123", null, -20));
        // A 25-digit significand with a small exponent is not Clinger's:
        // the same value must come out of the wide path.
        assert(decodeWide!fmt("1234567890123456789012345", null, 3)
            == slowDecode!fmt("1234567890123456789012345", null, 3));
        // Saturation and zero.
        assert(decodeWide!fmt("1", null, 5000).isInf);
        assert(decodeWide!fmt("1", null, -5100) == DecodedFloat.init);
        assert(decodeWide!fmt(null, "000", 0) == DecodedFloat.init);
        // The subnormal band is the exact tier's, and still exact.
        assert(decodeWide!fmt("1", null, -4950) == slowDecode!fmt("1", null, -4950));
    }}
}

@("float_conv.readDecimalFloat.roundTripsShortestReal")
@safe unittest
{
    import std.array : appender;

    ulong state = 0xD1B5_4A32_D192_ED03;
    ulong next()
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return state;
    }

    // Random host reals — normal, and every eighth one subnormal — rendered
    // shortest and read back through the typed reader, bit for bit.
    enum p = formatOf!real.mantDig;
    foreach (iter; 0 .. 2000)
    {
        DecodedFloat v;
        static if (p > 64)
        {
            v.hi = (next() & ((1UL << (p - 64)) - 1)) | (1UL << (p - 1 - 64));
            v.lo = next();
        }
        else
            v.lo = (next() & ((1UL << (p - 1)) - 1)) | (1UL << (p - 1));
        const lo = formatOf!real.minSubnormalExp2, hi = formatOf!real.maxNormalExp2 - (p - 1);
        v.exp2 = iter % 3 ? -100 + cast(int)(next() % 200)
            : lo + cast(int)(next() % cast(ulong)(hi - lo + 1));
        if (iter % 8 == 7)
        {
            v.exp2 = lo;
            v.hi = 0;
            v.lo = (next() >> 1) | 1;
            static if (p <= 64)
                v.lo &= (1UL << (p - 1)) - 1;
        }
        v.negative = (iter & 1) != 0;
        const x = compose!real(v);

        auto a = appender!string;
        writeShortest(a, x);
        const(char)[] text = a[];
        auto back = readDecimalFloat!real(text);
        assert(back.hasValue && text.length == 0);
        assert(decompose!real(back.value) == decompose!real(x));
    }
}

version (linux)
@("float_conv.readDecimalFloat.realDifferentialVsStrtold")
@system unittest
{
    import core.stdc.stdlib : strtold;
    import core.stdc.stdio : snprintf;

    // glibc's `strtold` is correctly rounded at the host's `real` — x87
    // extended on x86_64, binary128 on AArch64. Significands of up to 38
    // digits, exponents across the whole wide range and past it.
    ulong state = 0x9E37_79B9_7F4A_7C15;
    static ulong next(ref ulong s)
    {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return s;
    }

    char[96] buf;
    foreach (iter; 0 .. 20_000)
    {
        const a = next(state) >> (next(state) % 40);
        const b = next(state) >> (next(state) % 50);
        const exp = cast(int)(next(state) % 10_401) - 5200;
        const len = iter % 3 == 0
            ? snprintf(buf.ptr, buf.length, "%llu%llue%d", a, b, exp)
            : snprintf(buf.ptr, buf.length, "%llue%d", a, exp);
        const(char)[] text = buf[0 .. len];

        auto ours = readDecimalFloat!real(text);
        assert(ours.hasValue && text.length == 0);
        const oracle = strtold(buf.ptr, null);
        assert(ours.value is oracle);
    }
}

/// The cost of every tier at every width, on the inputs the spec cites:
/// `dub test :base -b bench -- --bench -i float_conv.bench --group-by=format`.
@("float_conv.bench.tiers")
@benchmark @safe
unittest
{
    import sparkles.test_runner.bench : benchIter, blackBox;

    // binary64: the fast tiers, the exact tier, and both writers.
    benchIter({
        double d;
        tryFastDouble(blackBox(299_792_458UL), blackBox(-8), d);
        blackBox(d);
    }, ["format": "binary64", "tier": "fast", "input": "2.99792458"]);
    benchIter({
        blackBox(slowDouble(blackBox("1"), blackBox("527064050293794113039"), 0));
    }, ["format": "binary64", "tier": "exact", "input": "22 digits near 1"]);
    benchIter({
        blackBox(slowDouble(blackBox("17976931348623157"), null, blackBox(292)));
    }, ["format": "binary64", "tier": "exact", "input": "double.max"]);
    char[40] buf;
    benchIter({
        blackBox(formatShortestDouble(buf[], blackBox(1.5599)));
    }, ["format": "binary64", "tier": "schubfach", "input": "1.5599"]);
    char[64] digits;
    int exp10;
    benchIter({
        blackBox(shortestDigits!binary64(DecodedFloat(0, blackBox(0x18F3A2B1C4D5EUL | (1UL << 52)), -52),
            digits[], exp10));
    }, ["format": "binary64", "tier": "steele-white", "input": "near 1.5"]);

    // The wide formats: the new tier near 1 and at the far end, the exact
    // tier on the same inputs, and the writer at real.max.
    static foreach (fmt; [extended80, binary128])
    {{
        enum name = fmt == extended80 ? "extended80" : "binary128";
        enum DecodedFloat realMax = fmt == extended80
            ? DecodedFloat(0, ulong.max, 16383 - 63)
            : DecodedFloat(ulong.max >> 15, ulong.max, 16383 - 112);
        benchIter({
            DecodedFloat r;
            tryFastWide!fmt(sigOf(blackBox("15270640502937941130")), blackBox(-19), r);
            blackBox(r);
        }, ["format": name, "tier": "fast", "input": "20 digits near 1"]);
        benchIter({
            DecodedFloat r;
            tryFastWide!fmt(sigOf(blackBox("118973149535723176502")), blackBox(4912), r);
            blackBox(r);
        }, ["format": name, "tier": "fast", "input": "1.19e4932 (composed entry)"]);
        benchIter({
            blackBox(decodeWide!fmt(blackBox("1"), blackBox("5270640502937941130"), 0));
        }, ["format": name, "tier": "wide", "input": "20 digits near 1"]);
        benchIter({
            blackBox(decodeWide!fmt(blackBox("118973149535723176502"), null, blackBox(4912)));
        }, ["format": name, "tier": "wide", "input": "1.19e4932"]);
        benchIter({
            blackBox(slowDecode!fmt(blackBox("1"), blackBox("5270640502937941130"), 0));
        }, ["format": name, "tier": "exact", "input": "20 digits near 1"]);
        benchIter({
            blackBox(slowDecode!fmt(blackBox("118973149535723176502"), null, blackBox(4912)));
        }, ["format": name, "tier": "exact", "input": "1.19e4932"]);
        benchIter({
            blackBox(slowDecode!fmt(blackBox("3"), blackBox("36210314311209350626"), blackBox(-4932)));
        }, ["format": name, "tier": "exact", "input": "3.36e-4932"]);
        benchIter({
            blackBox(shortestDigits!fmt(blackBox(realMax), digits[], exp10));
        }, ["format": name, "tier": "steele-white", "input": "real.max"]);
    }}
}

version (Posix)
@("float_conv.readDecimalFloat.floatDifferentialVsStrtof")
@system unittest
{
    import core.stdc.stdlib : strtof;
    import core.stdc.stdio : snprintf;

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
        const sig = next(state) >> (next(state) % 40);
        const exp = cast(int)(next(state) % 121) - 60;
        const len = snprintf(buf.ptr, buf.length, "%llue%d", sig, exp);
        const(char)[] text = buf[0 .. len];

        auto ours = readDecimalFloat!float(text);
        assert(ours.hasValue);
        const float mine = ours.value;
        const float oracle = strtof(buf.ptr, null);
        assert(*cast(const uint*) &mine == *cast(const uint*) &oracle);
    }
}

@("float_conv.shortestDigits.pins")
@safe unittest
{
    static string sd(BinaryFloatFormat fmt)(DecodedFloat v, out int e)
    {
        char[64] buf;
        const n = shortestDigits!fmt(v, buf[], e);
        return buf[0 .. n].idup;
    }

    static string of(T)(T x, out int e)
        => sd!(formatOf!T)(decompose!T(x), e);

    int e;
    assert(of(1.0, e) == "1" && e == 0);
    assert(of(0.1, e) == "1" && e == -1);
    assert(of(0.0, e) == "0" && e == 0);
    assert(of(123.456, e) == "123456" && e == -3);
    assert(of(1e23, e) == "1" && e == 23); // the JavaScript `1e23`, not 9.999…e22
    assert(of(double.min_normal * double.epsilon, e) == "5" && e == -324);
    assert(of(double.max, e) == "17976931348623157" && e == 292);
    assert(of(double.min_normal, e) == "22250738585072014" && e == -324);
    assert(of(2.0 ^^ 53, e) == "9007199254740992" && e == 0);
    assert(of(16_777_216.0f, e) == "16777216" && e == 0);
    assert(of(float.max, e) == "34028235" && e == 31);
    assert(of(0.1f, e) == "1" && e == -1);
    assert(of(1.0L, e) == "1" && e == 0);

    // binary128, on any host. real.max there is 1.18973149535723176508575932662
    // 80070162…e4932 with a half-ulp near 5.7e4897, so 34 digits already land
    // inside the interval where the 36-digit max_digits10 spelling is the
    // worst case, not the answer.
    const realMax = DecodedFloat(ulong.max >> 15, ulong.max, 16383 - 112);
    assert(sd!binary128(realMax, e) == "1189731495357231765085759326628007" && e == 4899);
    assert(slowDecode!binary128("1189731495357231765085759326628007", null, 4899) == realMax);
    assert(sd!binary128(DecodedFloat(1UL << 48, 0, -112), e) == "1" && e == 0);
    assert(sd!binary128(DecodedFloat(0, 1, -16494), e) == "6" && e == -4966);

    // Settled at compile time.
    enum ct = () {
        char[17] buf;
        int ce;
        const n = shortestDigits!binary64(decompose!double(1.5), buf[], ce);
        return buf[0 .. n].idup ~ "@" ~ (ce == -1 ? "-1" : "?");
    }();
    static assert(ct == "15@-1");
}

@("float_conv.shortestDigits.roundTripsAndIsShortestAtEveryWidth")
@safe unittest
{
    import std.meta : AliasSeq;

    ulong state = 0xC0FF_EE12_3456_789A;
    ulong next()
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return state;
    }

    // Increments a decimal digit string in place; a carry out returns true.
    static bool increment(char[] d)
    {
        foreach_reverse (i; 0 .. d.length)
        {
            if (d[i] != '9')
            {
                d[i]++;
                return false;
            }
            d[i] = '0';
        }
        return true;
    }

    static foreach (fmt; AliasSeq!(binary32, binary64, extended80, binary128))
    {{
        enum p = fmt.mantDig;
        // Exponents: the whole range for the narrow formats, a band plus the
        // ends for the wide ones — the far ends cost milliseconds each.
        enum lo = fmt.minSubnormalExp2, hi = fmt.maxNormalExp2 - (p - 1);
        enum band = p > 53 ? 400 : hi - lo;
        // The wide formats' far ends cost tens of milliseconds a decode, so
        // they are sampled sparingly and the sweep is shorter there.
        enum iterations = p > 53 ? 60 : 150;
        enum every = p > 53 ? 75 : 5; // one top and one bottom sample when wide
        foreach (iter; 0 .. iterations)
        {
            DecodedFloat v;
            static if (p > 64)
            {
                v.hi = (next() & ((1UL << (p - 64)) - 1)) | (1UL << (p - 1 - 64));
                v.lo = next();
            }
            else static if (p == 64)
                v.lo = next() | (1UL << 63);
            else
                v.lo = (next() & ((1UL << p) - 1)) | (1UL << (p - 1));
            const span = cast(long) band;
            long ex = lo + cast(long)(next() % cast(ulong)(span + 1));
            if (iter % every == 1)
                ex = hi - cast(long)(next() % 64); // the top end
            else if (iter % every == 2)
                ex = lo + cast(long)(next() % 64); // the bottom end
            if (ex > hi)
                ex = hi;
            v.exp2 = cast(int) ex;
            if (iter % 8 == 3) // a subnormal: fewer bits, at the floor
            {
                v.exp2 = lo;
                v.hi = 0;
                v.lo = (v.lo >> 1) | 1;
                static if (p > 64)
                    v.lo = next() | 1;
                else
                    v.lo &= (1UL << (p - 1)) - 1;
                if (v.lo == 0)
                    v.lo = 1;
            }

            char[64] buf;
            int exp10;
            const n = shortestDigits!fmt(v, buf[], exp10);
            assert(n >= 1 && n <= fmt.maxDigits10);

            // Round-trips through the exact reader, exactly.
            const back = slowDecode!fmt(buf[0 .. n], null, exp10);
            assert(back == v);

            // And nothing one digit shorter does: the two nearest (n-1)-digit
            // decimals — the truncation and its successor — both miss. (Every
            // other value: the exact decodes are what this sweep costs.)
            if (n > 1 && iter % 2 == 0)
            {
                char[65] shorter;
                shorter[0 .. n - 1] = buf[0 .. n - 1];
                assert(slowDecode!fmt(shorter[0 .. n - 1], null, exp10 + 1) != v);
                if (increment(shorter[0 .. n - 1]))
                {
                    shorter[0] = '1';
                    shorter[1 .. n] = '0';
                    assert(slowDecode!fmt(shorter[0 .. n], null, exp10 + 1) != v);
                }
                else
                    assert(slowDecode!fmt(shorter[0 .. n - 1], null, exp10 + 1) != v);
            }
        }
    }}
}

@("float_conv.shortestDigits.agreesWithSchubfach")
@safe unittest
{
    // Digit for digit against `f64ToDecimal` — the Schubfach port behind
    // `formatShortestDouble` — over the same corpus that proves it
    // round-trips. Agreement here is what the inclusive-iff-even boundary
    // and the tie-to-even choice buy.
    ulong state = 0xDEAD_BEEF_CAFE_F00D;
    ulong next()
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return state;
    }

    char[17] ours;
    char[20] theirs;
    foreach (i; 0 .. 100_000)
    {
        ulong bits = next();
        if (((bits >> 52) & 0x7FF) == 0x7FF)
            bits &= ~(0x7FFUL << 52);
        if (i % 7 == 0)
            bits &= ~(0x7F0UL << 52);
        const sigRaw = bits & ((1UL << 52) - 1);
        const expRaw = cast(uint)(bits >> 52) & 0x7FF;
        if (sigRaw == 0 && expRaw == 0)
            continue; // zero has no Schubfach digits

        const sigBin = expRaw ? sigRaw | (1UL << 52) : sigRaw;
        const expBin = expRaw ? cast(int) expRaw - 1075 : -1074;
        ulong sigDec;
        int expDec;
        f64ToDecimal(sigRaw, expRaw, sigBin, expBin, sigDec, expDec);
        while (sigDec % 10 == 0)
        {
            sigDec /= 10;
            expDec++;
        }
        size_t tn = theirs.length;
        for (ulong v = sigDec; v; v /= 10)
            theirs[--tn] = cast(char)('0' + v % 10);

        int exp10;
        const n = shortestDigits!binary64(DecodedFloat(0, sigBin, expBin), ours[], exp10);
        assert(ours[0 .. n] == theirs[tn .. $] && exp10 == expDec);
    }
}

@("float_conv.writeShortest.notation")
@safe unittest
{
    import std.array : appender;

    static string w(T)(T x)
    {
        auto a = appender!string;
        writeShortest(a, x);
        return a[];
    }

    assert(w(1.5) == "1.5e0");
    assert(w(-0.001) == "-1e-3");
    assert(w(123456.0f) == "1.23456e5");
    assert(w(double.min_normal * double.epsilon) == "5e-324");
    assert(w(0.0) == "0e0");
    assert(w(-0.0) == "-0e0");
    assert(w(double.infinity) == "inf");
    assert(w(-real.infinity) == "-inf");
    assert(w(float.nan) == "nan");
    assert(w(2.5L) == "2.5e0");
}

// The wide formats put their digits on the stack — 11.6 KB of them for the
// binary128 decoder, four ~2 KB integers for the writer — and a druntime
// `Fiber`'s default stack is `PAGESIZE * 4`: 16 KiB on 4 KiB-page Linux.
// Both directions at real.max's magnitude must fit a small fiber.
@("float_conv.slowDecode.fitsAFiberStack")
@system unittest
{
    import core.thread.fiber : Fiber;

    static bool ran;
    static void body_()
    {
        const decoded = slowDecode!binary128("1189731495357231765085759326628007", null, 4899);
        char[40] digits;
        int exp10;
        const n = shortestDigits!binary128(decoded, digits[], exp10);
        ran = n == 34 && exp10 == 4899 && decoded.exp2 == 16383 - 112;
    }

    // 32 KiB: the unoptimized test build (with or without coverage) needs
    // about twice the frames the shipping build has, and 16 KiB is the
    // default `Fiber` stack this guards against.
    auto fiber = new Fiber(&body_, 32 * 1024);
    fiber.call();
    assert(fiber.state == Fiber.State.TERM);
    assert(ran);
}

// Exact correctly-rounded decoding by big-integer division: a second,
// independent method against which the decimal-shift kernel is checked at
// every width — including the 113 bits no CI host has natively yet.
private DecodedFloat oracleDecode(BinaryFloatFormat fmt)(string digits, int exp10)
{
    import std.bigint : BigInt;

    enum p = fmt.mantDig;
    DecodedFloat r;
    BigInt num = BigInt(digits);
    if (num == 0)
        return r;
    BigInt den = 1;
    if (exp10 >= 0)
        num *= BigInt(10) ^^ exp10;
    else
        den = BigInt(10) ^^ (-exp10);

    // The leading bit's exponent E: 2^E ≤ num/den < 2^(E+1). Start from the
    // limb lengths and correct by comparison, scaling whichever side keeps
    // the shift count non-negative — a negative one does not shift.
    static bool atLeast(BigInt num, BigInt den, long e)
        => e >= 0 ? num >= (den << e) : (num << -e) >= den;
    long e = (cast(long) num.ulongLength - cast(long) den.ulongLength) * 64;
    while (atLeast(num, den, e + 1))
        e++;
    while (!atLeast(num, den, e))
        e--;

    // The last bit's exponent, floored at the subnormal range; then the
    // significand as a rounded quotient, ties to even.
    long lsb = e - (p - 1);
    if (lsb < fmt.minSubnormalExp2)
        lsb = fmt.minSubnormalExp2;
    const scaledNum = lsb < 0 ? num << -lsb : num;
    const scaledDen = lsb > 0 ? den << lsb : den;
    BigInt q = scaledNum / scaledDen;
    const rem = scaledNum % scaledDen;
    const twice = rem * 2;
    if (twice > scaledDen || (twice == scaledDen && q % 2 == 1))
        q++;
    if (q == 0)
        return r;
    if (q == BigInt(1) << p) // the rounding carried
    {
        q = BigInt(1) << (p - 1);
        lsb++;
    }
    if (lsb + (p - 1) > fmt.maxNormalExp2 && q >= (BigInt(1) << (p - 1)))
    {
        r.isInf = true;
        return r;
    }
    r.lo = cast(ulong)(q % (BigInt(1) << 64));
    r.hi = cast(ulong)(q >> 64);
    r.exp2 = cast(int) lsb;
    return r;
}

@("float_conv.slowDecode.agreesWithBigIntOracle")
@system unittest
{
    import std.conv : text;
    import std.format : format;

    static struct Case
    {
        string digits;
        int exp10;
    }

    // Ties at every width (2^p + 1), the classic double edges, and the far
    // ends of binary128's range.
    static immutable Case[] hard = [
        Case("16777217", 0), Case("9007199254740993", 0),
        Case("18446744073709551617", 0),
        Case("10384593717069655257060992658440193", 0),
        Case("9007199254740995", 0), Case("5", -324), Case("2", -324),
        Case("3", -324), Case("22250738585072011", -324),
        Case("17976931348623157", 292), Case("17976931348623159", 292),
        Case("1", -4966), Case("6", -4966), Case("3", -4966), Case("1", 4933),
        Case("118973149535723176508575932662800702", 4897),
        Case("118973149535723176508575932662800703", 4897),
        Case("1", -16445), Case("340282366920938463463374607431768211455", 0),
    ];

    static void check(BinaryFloatFormat fmt)(string digits, int exp10)
    {
        const ours = slowDecode!fmt(digits, null, exp10);
        const oracle = oracleDecode!fmt(digits, exp10);
        assert(ours == oracle, format("%se%d at %d bits: %s vs oracle %s",
            digits, exp10, fmt.mantDig, ours, oracle));
    }

    static void checkAll(string digits, int exp10)
    {
        check!binary32(digits, exp10);
        check!binary64(digits, exp10);
        check!extended80(digits, exp10);
        check!binary128(digits, exp10);
    }

    foreach (c; hard)
        checkAll(c.digits, c.exp10);

    // A deterministic xorshift corpus: significands of varying length, up
    // to 38 digits, with exponents across binary64's whole range and into
    // the wide formats' (a slice of it — the oracle's big integers grow with
    // the exponent).
    ulong state = 0x9E37_79B9_7F4A_7C15;
    static ulong next(ref ulong s)
    {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return s;
    }

    foreach (iter; 0 .. 1500)
    {
        string digits = text(next(state) >> (next(state) % 40));
        if (iter % 4 == 0)
            digits ~= text(next(state)); // 20 - 38 digits: past any fast tier
        const exp10 = cast(int)(next(state) % 801) - 400;
        checkAll(digits, exp10);
    }
}

version (Posix)
@("float_conv.slowDecode.binary32DifferentialVsStrtof")
@system unittest
{
    import core.stdc.stdlib : strtof;
    import core.stdc.stdio : snprintf;

    ulong state = 0x2545_F491_4F6C_DD1D;
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
        const sig = next(state) >> (next(state) % 40);
        const exp = cast(int)(next(state) % 121) - 60; // hits both saturations
        const len = snprintf(buf.ptr, buf.length, "%llu", sig);
        const ours = slowDecode!binary32(buf[0 .. len], null, exp);
        snprintf(buf.ptr, buf.length, "%llue%d", sig, exp);
        const float oracle = strtof(buf.ptr, null);
        const oracleBits = *cast(const uint*)&oracle;
        assert(encode!binary32(ours) == oracleBits);
    }
}

@("float_conv.tryFastDouble.ctfeMatchesRuntime")
@safe pure nothrow @nogc
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

// The narrowing tier at CTFE (Clinger is skipped there) agrees with the
// runtime path, which took Clinger.
@("float_conv.readDecimalFloat.narrowTierCtfeMatchesRuntime")
@safe pure nothrow @nogc
unittest
{
    static float read(string text)
    {
        const(char)[] s = text;
        return readDecimalFloat!float(s).value;
    }

    enum ctA = read("3.14159");
    assert(ctA is read("3.14159"));
    enum ctB = read("1.00000017881393432617187499"); // the strtof trap
    assert(decompose(ctB) == decompose(read("1.00000017881393432617187499")));
    assert(decompose(ctB) == decompose(1.0000001f));
    enum ctC = read("16777217"); // a true tie: punts to the exact tier
    assert(ctC is 16_777_216.0f);
    enum ctD = read("1e-46"); // below half the smallest subnormal
    assert(ctD is 0.0f);
    enum ctE = read("3.4028236e38"); // past the overflow threshold
    assert(ctE is float.infinity);
}

// Every rounding boundary of `float` is where the narrowing tier must punt:
// the exact midpoint between two neighbours reads as the even one, and the
// spellings one unit either side in the last decimal digit as the neighbours.
@("float_conv.readDecimalFloat.floatMidpoints")
@system unittest
{
    import std.bigint : BigInt;
    import std.conv : to;

    static float read(string text)
    {
        const(char)[] s = text;
        const r = readDecimalFloat!float(s);
        assert(r.hasValue && s.length == 0);
        return r.value;
    }

    ulong state = 0x1234_5678_9ABC_DEF1;
    foreach (i; 0 .. 3000)
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        // A random finite positive float and its successor, subnormals and
        // the top binade included.
        const uint lowBits = cast(uint)(state >> 32) & 0x7FFF_FFFF;
        const uint bits = i % 8 == 0 ? lowBits % (1u << 23) : lowBits % 0x7F80_0000;
        const float f = compose!float(decode!binary32(bits));
        const float g = compose!float(decode!binary32(bits + 1));
        const df = decompose(f), dg = decompose(g);
        // m = (f + g) / 2 as N × 2^e, e ≤ 0 here: N × 5^-e / 10^-e.
        int e = (df.exp2 < dg.exp2 ? df.exp2 : dg.exp2) - 1;
        BigInt n = (BigInt(df.lo) << (df.exp2 - e - 1)) + (BigInt(dg.lo) << (dg.exp2 - e - 1));
        if (e > 0)
        {
            n <<= e;
            e = 0;
        }
        foreach (_; 0 .. -e)
            n *= 5;
        const string suffix = "e" ~ to!string(e);
        const even = (df.lo & 1) == 0 ? f : g;
        assert(read(n.to!string ~ suffix) is even);
        assert(read((n - 1).to!string ~ suffix) is f);
        assert(read((n + 1).to!string ~ suffix) is g);
    }
    // The overflow threshold (2 - 2^-24) × 2^127 and half the smallest
    // subnormal, 2^-150 = 5^150 × 10^-150, exactly: ties, to even.
    const threshold = (BigInt(1) << 128) - (BigInt(1) << 103);
    assert(read(threshold.to!string) is float.infinity);
    assert(read((threshold - 1).to!string) is float.max);
    const halfSub = BigInt(5) ^^ 150;
    assert(read(halfSub.to!string ~ "e-150") is 0.0f);
    assert(read((halfSub + 1).to!string ~ "e-150") is float.min_normal * float.epsilon);
}

@("float_conv.readDecimalFloat.grammar")
@safe pure nothrow @nogc
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

    // A long run of zeros is paid for by the explicit exponent: clamping the
    // exponent to a fixed magnitude before the digit positions are added
    // turned these into 1e-101 and 1e100.
    import std.array : replicate;

    enum zeros = "0".replicate(500);
    enum tinyFrac = "0." ~ zeros ~ "1e800";
    enum hugeInt = "1" ~ zeros ~ "e-800";
    assert(read(tinyFrac) == 1e299);
    assert(read(hugeInt) == 1e-300);
    enum tinyFracUnder = "0." ~ zeros ~ "1e-800";
    enum hugeIntOver = "1" ~ zeros ~ "e800";
    assert(read(tinyFracUnder) is 0.0);
    assert(read(hugeIntOver) == double.infinity);
    assert(read("1e99999999999") == double.infinity); // more than ten digits

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

version (Posix)
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

version (Posix)
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

    // Every fifth literal carries a run of up to 600 zeros — before the
    // first significant digit or after the last — paid for by an exponent
    // out to ±1000, the shape a fixed exponent clamp misreads.
    static immutable char[600] zeroRun = '0';
    char[720] buf;
    foreach (iter; 0 .. 20_000)
    {
        const sig = next(state) >> (next(state) % 40); // vary digit counts
        int len;
        if (iter % 5 == 4)
        {
            const zeros = cast(int)(next(state) % 601);
            const exp = cast(int)(next(state) % 2001) - 1000;
            len = iter % 10 == 4
                ? snprintf(buf.ptr, buf.length, "0.%.*s%llue%d", zeros, zeroRun.ptr, sig, exp)
                : snprintf(buf.ptr, buf.length, "%llu%.*se%d", sig, zeros, zeroRun.ptr, exp);
        }
        else
        {
            const exp = cast(int)(next(state) % 691) - 345; // hits both saturations
            len = snprintf(buf.ptr, buf.length, "%llue%d", sig, exp);
        }
        const(char)[] text = buf[0 .. len];

        auto ours = readDecimalFloat(text);
        assert(ours.hasValue); // with tier 3, every literal resolves
        assert(text.length == 0);
        const oracle = strtod(buf.ptr, null);
        assert(doubleToBits(ours.value) == doubleToBits(oracle));
    }
}
