/**
Physical lengths, terminal extents, and exact bounded arithmetic for layout.

A physical tick is exactly 1/65536 point; a point is exactly 1/72 inch.
Cells have no implicit physical scale. Rational scales used by cell conversions
are expressed in raw physical ticks per cell, not points per cell.

Every operation is allocation-free, uses only fixed-size local state, and commits
its ref outputs only on success. No arena, mutable global state, or native cent
support is needed. Unsigned intermediates have 128 bits; signed intermediates
have the ordinary [-2^127, 2^127-1] range. A rational has a signed128 numerator
and a nonzero unsigned128 denominator. Rational operations reduce factors before
multiplication but still report exhaustion when an exact intermediate cannot be
represented. No rounded arithmetic is used for rational comparisons.
*/
module sparkles.base.text.layout_units;

import std.math.exponential : frexp;
import std.math.traits : isFinite;

@safe pure nothrow @nogc:

enum UnitStatus : ubyte { ok, invalidInput, arithmeticExhausted }

/// Distinct physical dimension. Every signed64 raw value is valid, including zero.
struct LayoutUnit
{
    long raw;
    enum long ticksPerPoint = 65_536;
    enum long pointsPerInch = 72;
}

/// Distinct integral terminal dimension; construction cannot produce negatives.
struct CellExtent
{
    ulong value;
}

/// Portable unsigned128, least-significant limb first; all bit patterns are valid.
struct U128
{
    ulong lo;
    ulong hi;

    bool isZero() const @safe pure nothrow @nogc => lo == 0 && hi == 0;
}

/// Signed128 sign/magnitude. Negative zero is accepted and normalized on output.
struct I128
{
    U128 magnitude;
    bool negative;

    bool valid() const @safe pure nothrow @nogc
    {
        return magnitude.hi < (1UL << 63)
            || (negative && magnitude.hi == (1UL << 63) && magnitude.lo == 0);
    }
}

/// Exact fraction. Public fields are checked by each fallible rational operation.
struct Rational
{
    I128 numerator;
    U128 denominator = U128(1, 0);

    bool valid() const @safe pure nothrow @nogc
        => numerator.valid() && !denominator.isZero();
}

I128 signedWide(long value)
{
    // Avoid negating long.min in signed arithmetic.
    return I128(U128(value < 0 ? 0UL - cast(ulong) value : cast(ulong) value, 0),
        value < 0);
}

private I128 canonical(I128 value)
{
    if (value.magnitude.isZero())
        value.negative = false;
    return value;
}

int compare(U128 a, U128 b)
{
    if (a.hi != b.hi)
        return a.hi < b.hi ? -1 : 1;
    return a.lo == b.lo ? 0 : (a.lo < b.lo ? -1 : 1);
}

/// Inputs must be valid signed128 representations; negative zero compares as zero.
int compare(I128 a, I128 b)
{
    a = canonical(a);
    b = canonical(b);
    if (a.negative != b.negative)
        return a.negative ? -1 : 1;
    const order = compare(a.magnitude, b.magnitude);
    return a.negative ? -order : order;
}

UnitStatus checkedAdd(U128 a, U128 b, ref U128 result)
{
    const lo = a.lo + b.lo;
    const carry = lo < a.lo ? 1UL : 0UL;
    const hi = a.hi + b.hi;
    if (hi < a.hi || hi > ulong.max - carry)
        return UnitStatus.arithmeticExhausted;
    result = U128(lo, hi + carry);
    return UnitStatus.ok;
}

UnitStatus checkedSubtract(U128 a, U128 b, ref U128 result)
{
    if (compare(a, b) < 0)
        return UnitStatus.arithmeticExhausted;
    result = U128(a.lo - b.lo, a.hi - b.hi - (a.lo < b.lo ? 1UL : 0UL));
    return UnitStatus.ok;
}

/// Exact full product of two unsigned64 operands (never exhausts).
UnitStatus checkedMultiply(ulong a, ulong b, ref U128 result)
{
    const a0 = cast(ulong) cast(uint) a;
    const a1 = a >> 32;
    const b0 = cast(ulong) cast(uint) b;
    const b1 = b >> 32;
    const p0 = a0 * b0;
    const t = a1 * b0 + (p0 >> 32);
    const mid = a0 * b1 + cast(uint) t;
    result = U128((mid << 32) | cast(uint) p0,
        a1 * b1 + (t >> 32) + (mid >> 32));
    return UnitStatus.ok;
}

UnitStatus checkedMultiply(U128 a, U128 b, ref U128 result)
{
    if (a.hi && b.hi)
        return UnitStatus.arithmeticExhausted;
    U128 product, crossA, crossB;
    checkedMultiply(a.lo, b.lo, product);
    checkedMultiply(a.hi, b.lo, crossA);
    checkedMultiply(a.lo, b.hi, crossB);
    if (crossA.hi || crossB.hi || product.hi > ulong.max - crossA.lo)
        return UnitStatus.arithmeticExhausted;
    product.hi += crossA.lo;
    if (product.hi > ulong.max - crossB.lo)
        return UnitStatus.arithmeticExhausted;
    product.hi += crossB.lo;
    result = product;
    return UnitStatus.ok;
}

/// Quotient and remainder are published together. The two output refs must differ.
UnitStatus checkedDivide(U128 dividend, U128 divisor,
    ref U128 quotient, ref U128 remainder)
{
    if (divisor.isZero() || &quotient == &remainder)
        return UnitStatus.invalidInput;
    if (dividend.hi == 0 && divisor.hi == 0)
    {
        const q64 = dividend.lo / divisor.lo;
        const r64 = dividend.lo % divisor.lo;
        quotient = U128(q64, 0);
        remainder = U128(r64, 0);
        return UnitStatus.ok;
    }
    if (compare(dividend, divisor) < 0)
    {
        quotient = U128.init;
        remainder = dividend;
        return UnitStatus.ok;
    }
    if (divisor == U128(1, 0))
    {
        quotient = dividend;
        remainder = U128.init;
        return UnitStatus.ok;
    }
    U128 q, r;
    // Restoring division. Carry retains the 129th bit of the trial remainder.
    for (uint bit = 128; bit != 0; )
    {
        --bit;
        const incoming = bit >= 64 ? (dividend.hi >> (bit - 64)) & 1
            : (dividend.lo >> bit) & 1;
        const carry = (r.hi >> 63) != 0;
        r.hi = (r.hi << 1) | (r.lo >> 63);
        r.lo = (r.lo << 1) | incoming;
        if (carry || compare(r, divisor) >= 0)
        {
            // Modular limb subtraction is exact after discarding the trial carry.
            const borrow = r.lo < divisor.lo ? 1UL : 0UL;
            r.lo -= divisor.lo;
            r.hi = r.hi - divisor.hi - borrow;
            if (bit >= 64)
                q.hi |= 1UL << (bit - 64);
            else
                q.lo |= 1UL << bit;
        }
    }
    quotient = q;
    remainder = r;
    return UnitStatus.ok;
}

UnitStatus checkedDivide(U128 a, U128 b, ref U128 result)
{
    U128 quotient, remainder;
    const status = checkedDivide(a, b, quotient, remainder);
    if (status == UnitStatus.ok)
        result = quotient;
    return status;
}

UnitStatus checkedSquare(ulong value, ref U128 result)
    => checkedMultiply(value, value, result);

UnitStatus checkedSquare(long value, ref U128 result)
{
    const magnitude = signedWide(value).magnitude.lo;
    return checkedMultiply(magnitude, magnitude, result);
}

UnitStatus checkedSquare(U128 value, ref U128 result)
    => checkedMultiply(value, value, result);

UnitStatus checkedAdd(I128 a, I128 b, ref I128 result)
{
    if (!a.valid() || !b.valid())
        return UnitStatus.invalidInput;
    I128 sum;
    if (a.negative == b.negative)
    {
        const status = checkedAdd(a.magnitude, b.magnitude, sum.magnitude);
        if (status != UnitStatus.ok)
            return status;
        sum.negative = a.negative;
    }
    else if (compare(a.magnitude, b.magnitude) >= 0)
    {
        checkedSubtract(a.magnitude, b.magnitude, sum.magnitude);
        sum.negative = a.negative;
    }
    else
    {
        checkedSubtract(b.magnitude, a.magnitude, sum.magnitude);
        sum.negative = b.negative;
    }
    if (!sum.valid())
        return UnitStatus.arithmeticExhausted;
    result = canonical(sum);
    return UnitStatus.ok;
}

UnitStatus checkedSubtract(I128 a, I128 b, ref I128 result)
{
    if (!a.valid() || !b.valid())
        return UnitStatus.invalidInput;
    // Do not validate a negated signed minimum as a standalone signed value.
    I128 difference;
    if (a.negative != b.negative)
    {
        const status = checkedAdd(a.magnitude, b.magnitude, difference.magnitude);
        if (status != UnitStatus.ok)
            return status;
        difference.negative = a.negative;
    }
    else if (compare(a.magnitude, b.magnitude) >= 0)
    {
        checkedSubtract(a.magnitude, b.magnitude, difference.magnitude);
        difference.negative = a.negative;
    }
    else
    {
        checkedSubtract(b.magnitude, a.magnitude, difference.magnitude);
        difference.negative = !a.negative;
    }
    if (!difference.valid())
        return UnitStatus.arithmeticExhausted;
    result = canonical(difference);
    return UnitStatus.ok;
}

UnitStatus checkedMultiply(I128 a, I128 b, ref I128 result)
{
    if (!a.valid() || !b.valid())
        return UnitStatus.invalidInput;
    I128 product;
    const status = checkedMultiply(a.magnitude, b.magnitude, product.magnitude);
    if (status != UnitStatus.ok)
        return status;
    product.negative = a.negative != b.negative;
    if (!product.valid())
        return UnitStatus.arithmeticExhausted;
    result = canonical(product);
    return UnitStatus.ok;
}

/// Signed division truncates toward zero; the remainder has the dividend's sign.
UnitStatus checkedDivide(I128 a, I128 b, ref I128 quotient, ref I128 remainder)
{
    if (!a.valid() || !b.valid() || &quotient == &remainder)
        return UnitStatus.invalidInput;
    U128 q, r;
    const status = checkedDivide(a.magnitude, b.magnitude, q, r);
    if (status != UnitStatus.ok)
        return status;
    const signedQ = canonical(I128(q, a.negative != b.negative));
    if (!signedQ.valid())
        return UnitStatus.arithmeticExhausted;
    quotient = signedQ;
    remainder = canonical(I128(r, a.negative));
    return UnitStatus.ok;
}

UnitStatus checkedDivide(I128 a, I128 b, ref I128 result)
{
    I128 quotient, remainder;
    const status = checkedDivide(a, b, quotient, remainder);
    if (status == UnitStatus.ok)
        result = quotient;
    return status;
}

UnitStatus checkedSquare(I128 value, ref U128 result)
{
    if (!value.valid())
        return UnitStatus.invalidInput;
    return checkedSquare(value.magnitude, result);
}

UnitStatus checkedNarrow(I128 value, ref long result)
{
    if (!value.valid())
        return UnitStatus.invalidInput;
    const limit = value.negative ? 1UL << 63 : cast(ulong) long.max;
    if (value.magnitude.hi || value.magnitude.lo > limit)
        return UnitStatus.arithmeticExhausted;
    // Convert the representable final bit pattern, including long.min.
    result = cast(long) (value.negative ? 0UL - value.magnitude.lo : value.magnitude.lo);
    return UnitStatus.ok;
}

UnitStatus checkedNarrow(U128 value, ref ulong result)
{
    if (value.hi)
        return UnitStatus.arithmeticExhausted;
    result = value.lo;
    return UnitStatus.ok;
}

private U128 gcd(U128 a, U128 b)
{
    while (!b.isZero())
    {
        U128 quotient, remainder;
        checkedDivide(a, b, quotient, remainder);
        a = b;
        b = remainder;
    }
    return a;
}

UnitStatus checkedNormalize(Rational value, ref Rational result)
{
    if (!value.valid())
        return UnitStatus.invalidInput;
    Rational normalized;
    if (!value.numerator.magnitude.isZero())
    {
        const divisor = gcd(value.numerator.magnitude, value.denominator);
        checkedDivide(value.numerator.magnitude, divisor, normalized.numerator.magnitude);
        checkedDivide(value.denominator, divisor, normalized.denominator);
        normalized.numerator.negative = value.numerator.negative;
    }
    result = normalized;
    return UnitStatus.ok;
}

UnitStatus checkedRational(long numerator, ulong denominator, ref Rational result)
    => checkedNormalize(Rational(signedWide(numerator), U128(denominator, 0)), result);

private UnitStatus rationalSum(Rational a, Rational b, bool subtract,
    ref Rational result)
{
    if (!a.valid() || !b.valid())
        return UnitStatus.invalidInput;
    checkedNormalize(a, a);
    checkedNormalize(b, b);
    const common = gcd(a.denominator, b.denominator);
    U128 factorA, factorB, denominator;
    checkedDivide(b.denominator, common, factorA);
    checkedDivide(a.denominator, common, factorB);
    I128 left = a.numerator, right = b.numerator;
    auto status = checkedMultiply(left.magnitude, factorA, left.magnitude);
    if (status != UnitStatus.ok)
        return status;
    status = checkedMultiply(right.magnitude, factorB, right.magnitude);
    if (status != UnitStatus.ok)
        return status;
    // Sign/magnitude inputs to the signed operation must themselves be representable.
    if (!left.valid() || !right.valid())
        return UnitStatus.arithmeticExhausted;
    I128 numerator;
    status = subtract ? checkedSubtract(left, right, numerator)
        : checkedAdd(left, right, numerator);
    if (status != UnitStatus.ok)
        return status;
    // Cancel the shared factor before forming the final denominator.
    const cancellation = gcd(numerator.magnitude, common);
    checkedDivide(numerator.magnitude, cancellation, numerator.magnitude);
    U128 reducedB;
    checkedDivide(b.denominator, cancellation, reducedB);
    status = checkedMultiply(factorB, reducedB, denominator);
    if (status != UnitStatus.ok)
        return status;
    return checkedNormalize(Rational(numerator, denominator), result);
}

UnitStatus checkedAdd(Rational a, Rational b, ref Rational result)
    => rationalSum(a, b, false, result);

UnitStatus checkedSubtract(Rational a, Rational b, ref Rational result)
    => rationalSum(a, b, true, result);

private UnitStatus rationalProduct(Rational a, Rational b, bool divide,
    ref Rational result)
{
    if (!a.valid() || !b.valid() || (divide && b.numerator.magnitude.isZero()))
        return UnitStatus.invalidInput;
    U128 an = a.numerator.magnitude, ad = a.denominator;
    U128 bn = divide ? b.denominator : b.numerator.magnitude;
    U128 bd = divide ? b.numerator.magnitude : b.denominator;
    const crossA = gcd(an, bd);
    const crossB = gcd(bn, ad);
    checkedDivide(an, crossA, an);
    checkedDivide(bd, crossA, bd);
    checkedDivide(bn, crossB, bn);
    checkedDivide(ad, crossB, ad);
    Rational product;
    auto status = checkedMultiply(an, bn, product.numerator.magnitude);
    if (status != UnitStatus.ok)
        return status;
    status = checkedMultiply(ad, bd, product.denominator);
    if (status != UnitStatus.ok)
        return status;
    product.numerator.negative = a.numerator.negative != b.numerator.negative;
    if (!product.numerator.valid())
        return UnitStatus.arithmeticExhausted;
    return checkedNormalize(product, result);
}

UnitStatus checkedMultiply(Rational a, Rational b, ref Rational result)
    => rationalProduct(a, b, false, result);

UnitStatus checkedDivide(Rational a, Rational b, ref Rational result)
    => rationalProduct(a, b, true, result);

UnitStatus checkedSquare(Rational value, ref Rational result)
    => checkedMultiply(value, value, result);

/// Continued-fraction comparison never constructs overflowing cross products.
private int compareFractions(U128 an, U128 ad, U128 bn, U128 bd)
{
    bool reversed;
    while (true)
    {
        U128 aq, ar, bq, br;
        checkedDivide(an, ad, aq, ar);
        checkedDivide(bn, bd, bq, br);
        const order = compare(aq, bq);
        if (order)
            return reversed ? -order : order;
        if (ar.isZero() || br.isZero())
        {
            const remainderOrder = ar.isZero() ? (br.isZero() ? 0 : -1) : 1;
            return reversed ? -remainderOrder : remainderOrder;
        }
        an = ad;
        ad = ar;
        bn = bd;
        bd = br;
        reversed = !reversed;
    }
}

UnitStatus checkedCompare(Rational a, Rational b, ref int result)
{
    if (!a.valid() || !b.valid())
        return UnitStatus.invalidInput;
    const left = canonical(a.numerator);
    const right = canonical(b.numerator);
    if (left.negative != right.negative)
        result = left.negative ? -1 : 1;
    else
    {
        const order = compareFractions(left.magnitude, a.denominator,
            right.magnitude, b.denominator);
        result = left.negative ? -order : order;
    }
    return UnitStatus.ok;
}

/// Nearest integer, ties to even. This is the only quantization in rational scaling.
private UnitStatus roundedMagnitude(Rational value, ref U128 result)
{
    if (!value.valid())
        return UnitStatus.invalidInput;
    U128 quotient, remainder, complement;
    checkedDivide(value.numerator.magnitude, value.denominator, quotient, remainder);
    checkedSubtract(value.denominator, remainder, complement);
    const halfOrder = compare(remainder, complement);
    if (halfOrder > 0 || (halfOrder == 0 && (quotient.lo & 1)))
    {
        const status = checkedAdd(quotient, U128(1, 0), quotient);
        if (status != UnitStatus.ok)
            return status;
    }
    result = quotient;
    return UnitStatus.ok;
}

UnitStatus checkedRound(Rational value, ref long result)
{
    U128 magnitude;
    const status = roundedMagnitude(value, magnitude);
    if (status != UnitStatus.ok)
        return status;
    return checkedNarrow(I128(magnitude, value.numerator.negative), result);
}

/// Exact floor/ceiling for solver costs; no float or physical-unit quantization.
UnitStatus checkedFloor(Rational value, ref I128 result)
{
    if (!value.valid())
        return UnitStatus.invalidInput;
    U128 quotient, remainder;
    checkedDivide(value.numerator.magnitude, value.denominator, quotient, remainder);
    if (value.numerator.negative && !remainder.isZero())
    {
        const status = checkedAdd(quotient, U128(1, 0), quotient);
        if (status != UnitStatus.ok)
            return status;
    }
    const rounded = canonical(I128(quotient, value.numerator.negative));
    if (!rounded.valid())
        return UnitStatus.arithmeticExhausted;
    result = rounded;
    return UnitStatus.ok;
}

UnitStatus checkedCeil(Rational value, ref I128 result)
{
    if (!value.valid())
        return UnitStatus.invalidInput;
    U128 quotient, remainder;
    checkedDivide(value.numerator.magnitude, value.denominator, quotient, remainder);
    if (!value.numerator.negative && !remainder.isZero())
    {
        const status = checkedAdd(quotient, U128(1, 0), quotient);
        if (status != UnitStatus.ok)
            return status;
    }
    const rounded = canonical(I128(quotient, value.numerator.negative));
    if (!rounded.valid())
        return UnitStatus.arithmeticExhausted;
    result = rounded;
    return UnitStatus.ok;
}

UnitStatus checkedAdd(LayoutUnit a, LayoutUnit b, ref LayoutUnit result)
{
    I128 wide;
    checkedAdd(signedWide(a.raw), signedWide(b.raw), wide);
    long raw;
    const status = checkedNarrow(wide, raw);
    if (status == UnitStatus.ok)
        result = LayoutUnit(raw);
    return status;
}

UnitStatus checkedSubtract(LayoutUnit a, LayoutUnit b, ref LayoutUnit result)
{
    I128 wide;
    checkedSubtract(signedWide(a.raw), signedWide(b.raw), wide);
    long raw;
    const status = checkedNarrow(wide, raw);
    if (status == UnitStatus.ok)
        result = LayoutUnit(raw);
    return status;
}

/// Sequential checked accumulation; failure leaves the published total unchanged.
UnitStatus checkedAccumulate(scope const(LayoutUnit)[] values,
    LayoutUnit initial, ref LayoutUnit result)
{
    auto total = initial;
    foreach (value; values)
    {
        const status = checkedAdd(total, value, total);
        if (status != UnitStatus.ok)
            return status;
    }
    result = total;
    return UnitStatus.ok;
}

private UnitStatus scaledPhysical(LayoutUnit value, Rational scale, bool divide,
    ref LayoutUnit result)
{
    Rational exact;
    const input = Rational(signedWide(value.raw), U128(1, 0));
    const status = divide ? checkedDivide(input, scale, exact)
        : checkedMultiply(input, scale, exact);
    if (status != UnitStatus.ok)
        return status;
    long raw;
    const rounded = checkedRound(exact, raw);
    if (rounded == UnitStatus.ok)
        result = LayoutUnit(raw);
    return rounded;
}

UnitStatus checkedScale(LayoutUnit value, Rational scale, ref LayoutUnit result)
    => scaledPhysical(value, scale, false, result);

UnitStatus checkedUnscale(LayoutUnit value, Rational scale, ref LayoutUnit result)
    => scaledPhysical(value, scale, true, result);

UnitStatus checkedMultiply(LayoutUnit value, Rational scale, ref LayoutUnit result)
    => checkedScale(value, scale, result);

UnitStatus checkedDivide(LayoutUnit value, Rational scale, ref LayoutUnit result)
    => checkedUnscale(value, scale, result);

private UnitStatus fromFloat(real value, int tickExponent, ref LayoutUnit result)
{
    if (!isFinite(value))
        return UnitStatus.invalidInput;
    if (value == 0)
    {
        result = LayoutUnit(0);
        return UnitStatus.ok;
    }
    const negative = value < 0;
    int exponent;
    real fraction = frexp(negative ? -value : value, exponent);
    // No multiply of the supplied value that could overflow or lose low bits.
    exponent += tickExponent;
    if (exponent > 64)
        return UnitStatus.arithmeticExhausted;
    ulong magnitude;
    if (exponent >= 0)
    {
        // Each power-of-two step and subtraction is exact in binary floating point.
        for (int bit = 0; bit < exponent; ++bit)
        {
            fraction *= 2;
            const one = fraction >= 1;
            magnitude = (magnitude << 1) | (one ? 1UL : 0UL);
            if (one)
                fraction -= 1;
        }
        if (fraction > 0.5L || (fraction == 0.5L && (magnitude & 1)))
        {
            if (magnitude == ulong.max)
                return UnitStatus.arithmeticExhausted;
            ++magnitude;
        }
    }
    long raw;
    const status = checkedNarrow(I128(U128(magnitude, 0), negative), raw);
    if (status == UnitStatus.ok)
        result = LayoutUnit(raw);
    return status;
}

/// Explicit finite physical ticks, rounded once to nearest-even raw tick.
UnitStatus checkedFromTicks(real ticks, ref LayoutUnit result)
    => fromFloat(ticks, 0, result);

/// Explicit finite typographic points, rounded once to nearest-even raw tick.
UnitStatus checkedFromPoints(real points, ref LayoutUnit result)
    => fromFloat(points, 16, result);

UnitStatus checkedAdd(CellExtent a, CellExtent b, ref CellExtent result)
{
    if (a.value > ulong.max - b.value)
        return UnitStatus.arithmeticExhausted;
    result = CellExtent(a.value + b.value);
    return UnitStatus.ok;
}

UnitStatus checkedSubtract(CellExtent a, CellExtent b, ref CellExtent result)
{
    if (a.value < b.value)
        return UnitStatus.arithmeticExhausted;
    result = CellExtent(a.value - b.value);
    return UnitStatus.ok;
}

UnitStatus checkedMultiply(CellExtent value, ulong factor, ref CellExtent result)
{
    U128 wide;
    checkedMultiply(value.value, factor, wide);
    if (wide.hi)
        return UnitStatus.arithmeticExhausted;
    result = CellExtent(wide.lo);
    return UnitStatus.ok;
}

/// Rejects negative signed counts instead of implicitly converting them to ulong.
UnitStatus checkedCells(long value, ref CellExtent result)
{
    if (value < 0)
        return UnitStatus.invalidInput;
    result = CellExtent(cast(ulong) value);
    return UnitStatus.ok;
}

private bool positiveScale(Rational scale)
    => scale.valid() && !scale.numerator.negative && !scale.numerator.magnitude.isZero();

/// Explicit positive raw-ticks-per-cell scale, one final nearest-even rounding.
UnitStatus checkedCellsToPhysical(CellExtent cells, Rational ticksPerCell,
    ref LayoutUnit result)
{
    if (!positiveScale(ticksPerCell))
        return UnitStatus.invalidInput;
    Rational exact;
    const status = checkedMultiply(Rational(I128(U128(cells.value, 0), false),
        U128(1, 0)), ticksPerCell, exact);
    if (status != UnitStatus.ok)
        return status;
    long raw;
    const rounded = checkedRound(exact, raw);
    if (rounded == UnitStatus.ok)
        result = LayoutUnit(raw);
    return rounded;
}

/// Converts a nonnegative physical length to nearest-even integral cells.
UnitStatus checkedPhysicalToCells(LayoutUnit physical, Rational ticksPerCell,
    ref CellExtent result)
{
    if (physical.raw < 0 || !positiveScale(ticksPerCell))
        return UnitStatus.invalidInput;
    Rational exact;
    const status = checkedDivide(Rational(signedWide(physical.raw), U128(1, 0)),
        ticksPerCell, exact);
    if (status != UnitStatus.ok)
        return status;
    U128 magnitude;
    const rounded = roundedMagnitude(exact, magnitude);
    if (rounded != UnitStatus.ok)
        return rounded;
    if (magnitude.hi)
        return UnitStatus.arithmeticExhausted;
    result = CellExtent(magnitude.lo);
    return UnitStatus.ok;
}

@("layout_units.physical.tiesAndRange")
unittest
{
    LayoutUnit output = LayoutUnit(99);
    assert(checkedFromTicks(0.5L, output) == UnitStatus.ok && output.raw == 0);
    assert(checkedFromTicks(1.5L, output) == UnitStatus.ok && output.raw == 2);
    assert(checkedFromTicks(2.5L, output) == UnitStatus.ok && output.raw == 2);
    assert(checkedFromTicks(-1.5L, output) == UnitStatus.ok && output.raw == -2);
    assert(checkedFromTicks(-2.5L, output) == UnitStatus.ok && output.raw == -2);
    assert(checkedFromPoints(0x1p-17L, output) == UnitStatus.ok && output.raw == 0);
    assert(checkedFromPoints(0x1.8p-16L, output) == UnitStatus.ok && output.raw == 2);
    assert(checkedFromTicks(-0x1p63L, output) == UnitStatus.ok && output.raw == long.min);
    assert(checkedFromTicks(0x1p63L, output) == UnitStatus.arithmeticExhausted);
    assert(output.raw == long.min);
    assert(checkedFromPoints(real.max, output) == UnitStatus.arithmeticExhausted);
    assert(checkedFromPoints(real.infinity, output) == UnitStatus.invalidInput);
    assert(checkedFromPoints(real.nan, output) == UnitStatus.invalidInput);
    assert(output.raw == long.min);
    assert(checkedAdd(LayoutUnit(long.max), LayoutUnit(1), output)
        == UnitStatus.arithmeticExhausted && output.raw == long.min);
    assert(checkedSubtract(LayoutUnit(long.min), LayoutUnit(1), output)
        == UnitStatus.arithmeticExhausted && output.raw == long.min);
    LayoutUnit[2] values = [LayoutUnit(1), LayoutUnit(1)];
    assert(checkedAccumulate(values[], LayoutUnit(long.max - 1), output)
        == UnitStatus.arithmeticExhausted && output.raw == long.min);
    static if (real.mant_dig >= 64)
    {
        assert(checkedFromTicks(cast(real) long.max, output) == UnitStatus.ok);
        assert(output.raw == long.max);
        assert(checkedFromTicks(0x1p63L - 0.5L, output)
            == UnitStatus.arithmeticExhausted && output.raw == long.max);
        assert(checkedFromTicks(0x1p63L - 1.5L, output) == UnitStatus.ok);
        assert(output.raw == long.max - 1);
    }
}

@("layout_units.wide.productDivisionAndSignedLimits")
unittest
{
    U128 product;
    assert(checkedMultiply(ulong.max, ulong.max, product) == UnitStatus.ok);
    assert(product == U128(1, ulong.max - 1));
    U128 quotient, remainder;
    assert(checkedDivide(product, U128(ulong.max, 0), quotient, remainder)
        == UnitStatus.ok);
    assert(quotient == U128(ulong.max, 0) && remainder.isZero());
    const hugeDivisor = U128(5, 1UL << 63);
    assert(checkedDivide(U128(ulong.max, ulong.max), hugeDivisor, quotient, remainder)
        == UnitStatus.ok);
    assert(quotient == U128(1, 0) && remainder == U128(ulong.max - 5, (1UL << 63) - 1));
    const oldQ = quotient;
    const oldR = remainder;
    assert(checkedDivide(product, U128.init, quotient, remainder) == UnitStatus.invalidInput);
    assert(quotient == oldQ && remainder == oldR);
    assert(checkedDivide(product, U128(1, 0), quotient, quotient) == UnitStatus.invalidInput);
    assert(quotient == oldQ);
    product = U128(17, 19);
    assert(checkedAdd(U128(ulong.max, ulong.max), U128(1, 0), product)
        == UnitStatus.arithmeticExhausted && product == U128(17, 19));
    assert(checkedMultiply(U128(0, 1), U128(0, 1), product)
        == UnitStatus.arithmeticExhausted && product == U128(17, 19));
    assert(checkedSubtract(U128(0, 1), U128(1, 0), product) == UnitStatus.ok);
    assert(product == U128(ulong.max, 0));
    assert(checkedSquare(long.min, product) == UnitStatus.ok);
    assert(product == U128(0, 1UL << 62));
    const minimum = I128(U128(0, 1UL << 63), true);
    I128 signedResult = signedWide(7);
    assert(checkedSubtract(minimum, minimum, signedResult) == UnitStatus.ok);
    assert(signedResult == signedWide(0));
    assert(checkedDivide(minimum, signedWide(-1), signedResult)
        == UnitStatus.arithmeticExhausted && signedResult == signedWide(0));
    assert(checkedAdd(minimum, signedWide(-1), signedResult)
        == UnitStatus.arithmeticExhausted && signedResult == signedWide(0));
    assert(checkedAdd(signedWide(long.max), signedWide(long.max), signedResult) == UnitStatus.ok);
    assert(signedResult.magnitude == U128(ulong.max - 1, 0) && !signedResult.negative);
}

@("layout_units.rational.exactScalingAndComparison")
unittest
{
    Rational half;
    assert(checkedRational(1, 2, half) == UnitStatus.ok);
    LayoutUnit output = LayoutUnit(77);
    assert(checkedScale(LayoutUnit(3), half, output) == UnitStatus.ok && output.raw == 2);
    assert(checkedScale(LayoutUnit(5), half, output) == UnitStatus.ok && output.raw == 2);
    assert(checkedScale(LayoutUnit(-5), half, output) == UnitStatus.ok && output.raw == -2);
    assert(checkedUnscale(LayoutUnit(long.max), half, output)
        == UnitStatus.arithmeticExhausted && output.raw == -2);
    const zeroDenominator = Rational(signedWide(1), U128.init);
    assert(checkedScale(LayoutUnit(1), zeroDenominator, output)
        == UnitStatus.invalidInput && output.raw == -2);
    const a = Rational(I128(U128(ulong.max, (1UL << 63) - 1), false),
        U128(ulong.max, ulong.max));
    const b = Rational(I128(U128(ulong.max - 1, (1UL << 63) - 1), false),
        U128(ulong.max - 1, ulong.max));
    int order;
    assert(checkedCompare(a, b, order) == UnitStatus.ok && order > 0);
    Rational sum, product;
    assert(checkedAdd(half, half, sum) == UnitStatus.ok);
    assert(sum == Rational(signedWide(1), U128(1, 0)));
    assert(checkedMultiply(Rational(signedWide(long.max), U128(3, 0)),
        Rational(signedWide(3), U128(cast(ulong) long.max, 0)), product) == UnitStatus.ok);
    assert(product == Rational(signedWide(1), U128(1, 0)));
    const largest = Rational(I128(U128(ulong.max, (1UL << 63) - 1), false),
        U128(1, 0));
    const sentinel = sum;
    assert(checkedAdd(largest, Rational(signedWide(1), U128(1, 0)), sum)
        == UnitStatus.arithmeticExhausted && sum == sentinel);
    assert(checkedDivide(half, Rational.init, sum)
        == UnitStatus.invalidInput && sum == sentinel);
    assert(checkedMultiply(largest, largest, sum)
        == UnitStatus.arithmeticExhausted && sum == sentinel);
    I128 integer;
    assert(checkedCeil(Rational(signedWide(-3), U128(2, 0)), integer) == UnitStatus.ok);
    assert(integer == signedWide(-1));
    assert(checkedFloor(Rational(signedWide(-3), U128(2, 0)), integer) == UnitStatus.ok);
    assert(integer == signedWide(-2));
}

@("layout_units.cells.explicitScaleAndAtomicFailures")
unittest
{
    const scale = Rational(signedWide(3), U128(2, 0));
    LayoutUnit physical = LayoutUnit(91);
    assert(checkedCellsToPhysical(CellExtent(3), scale, physical) == UnitStatus.ok);
    assert(physical.raw == 4);
    CellExtent cells = CellExtent(91);
    assert(checkedPhysicalToCells(LayoutUnit(3), scale, cells) == UnitStatus.ok);
    assert(cells.value == 2);
    assert(checkedCells(-1, cells) == UnitStatus.invalidInput && cells.value == 2);
    assert(checkedPhysicalToCells(LayoutUnit(-1), scale, cells)
        == UnitStatus.invalidInput && cells.value == 2);
    assert(checkedCellsToPhysical(CellExtent(1), Rational.init, physical)
        == UnitStatus.invalidInput && physical.raw == 4);
    assert(checkedCellsToPhysical(CellExtent(ulong.max),
        Rational(signedWide(1), U128(1, 0)), physical)
        == UnitStatus.arithmeticExhausted && physical.raw == 4);
    assert(checkedSubtract(CellExtent(0), CellExtent(1), cells)
        == UnitStatus.arithmeticExhausted && cells.value == 2);
    assert(checkedAdd(CellExtent(ulong.max), CellExtent(1), cells)
        == UnitStatus.arithmeticExhausted && cells.value == 2);
}
