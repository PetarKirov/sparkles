/**
Design, physical and pixel values (`docs/specs/font/variation-metrics.md`,
FTM8–FTM10).

A `DesignValue` is a fixed-point count of 1/65,536 font units with the face's
`unitsPerEm`; sums of them are checked. `toLayoutUnit` turns one into base's
physical `LayoutUnit` at a physical em size, exactly and rounded once, ties to
even. `toPixels` turns one into pixels at a `Ppem`, the exact rational rounded
once to the nearest `double`. Nothing here allocates.

Errors these operations report concern values, not font bytes: their tag is
none and their offset 0.
*/
module sparkles.font.units;

import core.bitop : bsr;
import core.checkedint : adds;
import std.math.exponential : ldexp;

import sparkles.base.text.layout_units : checkedDivide, checkedMultiply, checkedNormalize, checkedRound,
    checkedSubtract, compare, I128, LayoutUnit, Rational, signedWide, U128, UnitStatus;

import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk;

@safe pure nothrow @nogc:

/// `DesignValue.raw` steps per font unit.
enum long designSubunits = 65_536;

/**
A measurement in font design units (FTM8): a signed count of 1/65,536 font
units, together with the face's `unitsPerEm` (nonzero, as `Face.unitsPerEm`
guarantees).
*/
struct DesignValue
{
    @safe pure nothrow @nogc:

    /// The value in 1/65,536 font units.
    long raw;
    /// The em the units are a fraction of.
    ushort unitsPerEm;

    /// A stored integer field of `units` font units, exactly.
    static DesignValue fromUnits(int units, ushort unitsPerEm)
    in (unitsPerEm != 0)
    {
        return DesignValue(long(units) * designSubunits, unitsPerEm);
    }

    /// Whether the value is a whole number of font units.
    bool isWholeUnits() const => raw % designSubunits == 0;
}

///
@("units.DesignValue.fromUnits")
unittest
{
    const advance = DesignValue.fromUnits(-1_229, 2_048);
    assert(advance.raw == -1_229 * 65_536 && advance.unitsPerEm == 2_048);
    assert(advance.isWholeUnits && !DesignValue(32_768, 2_048).isWholeUnits);
}

private FontError valueError(FontErrorKind kind) => FontError(kind);

/**
`a + b`, or `arithmeticExhausted` when the sum leaves the 64-bit range (FTM8).
Both values must share their `unitsPerEm`.
*/
FontResult!DesignValue checkedAdd(DesignValue a, DesignValue b)
in (a.unitsPerEm == b.unitsPerEm, "design values of different ems do not add")
{
    bool overflow;
    const raw = adds(a.raw, b.raw, overflow);
    if (overflow)
        return fontErr!DesignValue(valueError(FontErrorKind.arithmeticExhausted));
    return fontOk(DesignValue(raw, a.unitsPerEm));
}

///
@("units.checkedAdd")
unittest
{
    const sum = checkedAdd(DesignValue.fromUnits(600, 1_000), DesignValue.fromUnits(-40, 1_000));
    assert(sum.value == DesignValue.fromUnits(560, 1_000));
    const over = checkedAdd(DesignValue(long.max, 1_000), DesignValue(1, 1_000));
    assert(over.error.kind == FontErrorKind.arithmeticExhausted);
}

/**
The sum of `values`, all of `unitsPerEm`, added in order; `arithmeticExhausted`
as soon as a partial sum leaves the 64-bit range (FTM8). Every value must have
`unitsPerEm`. Costs O(n).
*/
FontResult!DesignValue checkedSum(scope const(DesignValue)[] values, ushort unitsPerEm)
in (unitsPerEm != 0)
{
    auto total = DesignValue(0, unitsPerEm);
    foreach (value; values)
    {
        const next = checkedAdd(total, value);
        if (next.hasError)
            return next;
        total = next.value;
    }
    return fontOk(total);
}

///
@("units.checkedSum")
unittest
{
    static immutable DesignValue[3] run = [DesignValue(10, 2_048), DesignValue(-4, 2_048), DesignValue(1, 2_048)];
    assert(checkedSum(run[], 2_048).value == DesignValue(7, 2_048));
    assert(checkedSum(null, 2_048).value == DesignValue(0, 2_048));
}

/**
Pixels per em: a positive rational (FTM10). An instance sized in pixels
carries one; a physically sized one derives it from a device scale with
`fromPhysical`. Numerator and denominator are reduced and each fits 64 bits,
so every pixel conversion is exact before its one rounding. `Ppem.init` is
not a valid ppem.
*/
struct Ppem
{
    @safe pure nothrow @nogc:

    private ulong numerator_;
    private ulong denominator_ = 1;

    /// `ppem` whole pixels per em; zero or negative is `badValue`.
    static FontResult!Ppem fromInteger(long ppem)
    {
        if (ppem <= 0)
            return fontErr!Ppem(valueError(FontErrorKind.badValue));
        return fontOk(Ppem(ppem, 1));
    }

    /**
    The exact rational `ppem`. An invalid, zero or negative one is `badValue`;
    one whose reduced numerator or denominator exceeds 64 bits is
    `arithmeticExhausted`.
    */
    static FontResult!Ppem fromRational(Rational ppem)
    {
        Rational reduced;
        if (checkedNormalize(ppem, reduced) != UnitStatus.ok || reduced.numerator.magnitude.isZero
            || reduced.numerator.negative)
            return fontErr!Ppem(valueError(FontErrorKind.badValue));
        if (reduced.numerator.magnitude.hi || reduced.denominator.hi)
            return fontErr!Ppem(valueError(FontErrorKind.arithmeticExhausted));
        return fontOk(Ppem(reduced.numerator.magnitude.lo, reduced.denominator.lo));
    }

    /**
    The ppem of a physical em `em` on a device of `dotsPerInch`: `e · dpi / 72`
    for `e` in points, exactly (FTM10). A zero or negative em or scale is
    `badValue`; a result `fromRational` cannot hold is `arithmeticExhausted`.
    */
    static FontResult!Ppem fromPhysical(LayoutUnit em, Rational dotsPerInch)
    {
        Rational scale;
        if (em.raw <= 0 || checkedNormalize(dotsPerInch, scale) != UnitStatus.ok
            || scale.numerator.magnitude.isZero || scale.numerator.negative)
            return fontErr!Ppem(valueError(FontErrorKind.badValue));
        Rational ppem;
        const emPoints = Rational(signedWide(em.raw),
            U128(ulong(LayoutUnit.ticksPerPoint * LayoutUnit.pointsPerInch), 0));
        if (checkedMultiply(emPoints, scale, ppem) != UnitStatus.ok)
            return fontErr!Ppem(valueError(FontErrorKind.arithmeticExhausted));
        return fromRational(ppem);
    }

    /// As above, for a whole number of dots per inch.
    static FontResult!Ppem fromPhysical(LayoutUnit em, long dotsPerInch)
    {
        if (dotsPerInch <= 0)
            return fontErr!Ppem(valueError(FontErrorKind.badValue));
        return fromPhysical(em, Rational(signedWide(dotsPerInch)));
    }

    /// Whether this is a constructed, positive ppem.
    bool valid() const => numerator_ != 0;

    /// The reduced numerator.
    ulong numerator() const => numerator_;

    /// The reduced denominator.
    ulong denominator() const => denominator_;

    /// The exact value.
    Rational value() const => Rational(I128(U128(numerator_, 0)), U128(denominator_, 0));

    /// Whether the ppem is a whole number, as a Device table needs (FTM11).
    bool isInteger() const => denominator_ == 1;
}

///
@("units.Ppem.construction")
unittest
{
    const twelvePoints = LayoutUnit(12 * 65_536);
    const at96 = Ppem.fromPhysical(twelvePoints, 96).value;
    assert(at96.isInteger && at96.numerator == 16);
    const tenAt96 = Ppem.fromPhysical(LayoutUnit(10 * 65_536), 96).value; // 40/3
    assert(!tenAt96.isInteger && tenAt96.numerator == 40 && tenAt96.denominator == 3);
    assert(Ppem.fromInteger(0).error.kind == FontErrorKind.badValue);
    assert(Ppem.fromPhysical(LayoutUnit(0), 96).error.kind == FontErrorKind.badValue);
    assert(Ppem.fromRational(Rational(signedWide(-3), U128(2, 0))).error.kind == FontErrorKind.badValue);
    assert(Ppem.fromRational(Rational(signedWide(6), U128(4, 0))).value.denominator == 2);
    assert(!Ppem.init.valid);
}

/**
The physical length of `d` at a physical em size `em` (FTM9): exactly
`d · em / (unitsPerEm · 65,536)`, rounded once to the nearest tick, ties to
even. A result outside `LayoutUnit`'s range is `arithmeticExhausted`; a zero
or negative `em` is `badValue`. The product of two 64-bit values fits base's
128-bit intermediate, so nothing else can overflow. Sum a run's design values
first and convert the total once, so the run rounds once.
*/
FontResult!LayoutUnit toLayoutUnit(DesignValue d, LayoutUnit em)
in (d.unitsPerEm != 0)
{
    if (em.raw <= 0)
        return fontErr!LayoutUnit(valueError(FontErrorKind.badValue));
    I128 product;
    // |d.raw · em.raw| < 2^126: always representable.
    checkedMultiply(signedWide(d.raw), signedWide(em.raw), product);
    const exact = Rational(product, U128(ulong(d.unitsPerEm) * designSubunits, 0));
    long raw;
    if (checkedRound(exact, raw) != UnitStatus.ok)
        return fontErr!LayoutUnit(valueError(FontErrorKind.arithmeticExhausted));
    return fontOk(LayoutUnit(raw));
}

///
@("units.toLayoutUnit")
unittest
{
    const twelvePoints = LayoutUnit(12 * 65_536);
    // At upem 2048 and 12 pt, a font unit is exactly 384 ticks.
    assert(toLayoutUnit(DesignValue.fromUnits(1_229, 2_048), twelvePoints).value == LayoutUnit(1_229 * 384));
    assert(toLayoutUnit(DesignValue(1, 1), LayoutUnit(-1)).error.kind == FontErrorKind.badValue);
}

/**
The pixel length of `d` at `ppem` (FTM10): the exact rational
`d · ppem / (unitsPerEm · 65,536)` converted once to the nearest `double`, ties
to even, never to whole pixels. `ppem` must be `valid`. Costs O(1): at most
about 150 steps of a bit-serial division.
*/
double toPixels(DesignValue d, Ppem ppem)
in (d.unitsPerEm != 0 && ppem.valid)
{
    U128 numerator, denominator;
    // < 2^63 · 2^64 and < 2^32 · 2^64: neither overflows 128 bits.
    checkedMultiply(signedWide(d.raw).magnitude.lo, ppem.numerator, numerator);
    checkedMultiply(ulong(d.unitsPerEm) * designSubunits, ppem.denominator, denominator);
    const magnitude = nearestDouble(numerator, denominator);
    return d.raw < 0 ? -magnitude : magnitude;
}

///
@("units.toPixels")
unittest
{
    const sixteen = Ppem.fromInteger(16).value;
    assert(toPixels(DesignValue.fromUnits(1_024, 2_048), sixteen) == 8.0);
    assert(toPixels(DesignValue.fromUnits(-1, 2_048), sixteen) == -0.0078125);
    // 10 pt at 96 dpi: 40/3 ppem, one rounding of 500 · 40/3 / 1000.
    const fractional = Ppem.fromPhysical(LayoutUnit(10 * 65_536), 96).value;
    assert(toPixels(DesignValue.fromUnits(500, 1_000), fractional) == 20.0 / 3.0);
}

private uint bitLength(U128 value)
    => value.hi ? 65 + bsr(value.hi) : (value.lo ? 1 + bsr(value.lo) : 0);

private U128 shiftRight(U128 value, uint shift)
in (shift < 128)
{
    if (shift == 0)
        return value;
    if (shift >= 64)
        return U128(value.hi >> (shift - 64), 0);
    return U128((value.lo >> shift) | (value.hi << (64 - shift)), value.hi >> shift);
}

private bool lowBitsZero(U128 value, uint count)
in (count < 128)
{
    if (count < 64)
        return (value.lo & ((1UL << count) - 1)) == 0;
    return value.lo == 0 && (value.hi & ((1UL << (count - 64)) - 1)) == 0;
}

/**
`numerator / denominator` rounded once to the nearest `double`, ties to even.
The denominator is nonzero and below 2^127, so a doubled remainder fits. The
quotient's 55 leading bits and a sticky bit for the rest decide the rounding;
the result is at least 2^-127 and below 2^128, so it is never subnormal or
infinite.
*/
private double nearestDouble(U128 numerator, U128 denominator)
in (!denominator.isZero && denominator.hi < (1UL << 63))
{
    if (numerator.isZero)
        return 0.0;
    U128 quotient, remainder;
    checkedDivide(numerator, denominator, quotient, remainder);
    // The value is bits · 2^exponent plus a rest, sticky when nonzero; bits has 55 bits.
    enum uint window = 55;
    ulong bits;
    int exponent;
    bool sticky;
    const length = bitLength(quotient);
    if (length >= window)
    {
        exponent = length - window;
        bits = shiftRight(quotient, exponent).lo;
        sticky = !lowBitsZero(quotient, exponent) || !remainder.isZero;
    }
    else
    {
        bits = quotient.lo;
        while (bits < (1UL << (window - 1)))
        {
            remainder = U128(remainder.lo << 1, (remainder.hi << 1) | (remainder.lo >> 63));
            bits <<= 1;
            if (compare(remainder, denominator) >= 0)
            {
                checkedSubtract(remainder, denominator, remainder);
                bits |= 1;
            }
            --exponent;
        }
        sticky = !remainder.isZero;
    }
    // 53 significant bits, a half bit, and the bit below it plus sticky.
    ulong significand = bits >> 2;
    const half = (bits >> 1) & 1;
    const belowHalf = (bits & 1) || sticky;
    if (half && (belowHalf || (significand & 1)))
        ++significand; // 2^53 at most, still exact
    return ldexp(cast(double) significand, exponent + 2);
}
