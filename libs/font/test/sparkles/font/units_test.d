module sparkles.font.units_test;

import std.bigint : BigInt;
import std.math.exponential : frexp, ldexp;
import std.math.operations : nextDown, nextUp;
import std.random : Random, uniform;

import sparkles.base.text.layout_units : I128, LayoutUnit, Rational, signedWide, U128;

import sparkles.font.errors : FontErrorKind;
import sparkles.font.units;

private enum long tick = 1; // one LayoutUnit raw step
private enum long point = 65_536; // ticks per point

/// A ppem of `numerator / denominator`.
private Ppem ppemOf(ulong numerator, ulong denominator) @safe pure nothrow @nogc
    => Ppem.fromRational(Rational(I128(U128(numerator, 0)), U128(denominator, 0))).value;

@("units.FTM9.halfTicksTieToEven")
@safe pure nothrow @nogc
unittest
{
    // At upem 2048 and an em of 1024 ticks, one font unit is exactly half a tick.
    const em = LayoutUnit(1_024 * tick);
    static immutable long[2][6] cases = [[1, 0], [3, 2], [5, 2], [-1, 0], [-3, -2], [-5, -2]];
    foreach (c; cases)
        assert(toLayoutUnit(DesignValue.fromUnits(cast(int) c[0], 2_048), em).value == LayoutUnit(c[1]));
    // Just past a tie rounds away from it, either sign.
    assert(toLayoutUnit(DesignValue(65_537, 2_048), em).value == LayoutUnit(1));
    assert(toLayoutUnit(DesignValue(-65_537, 2_048), em).value == LayoutUnit(-1));
}

@("units.FTM9.rangeEdges")
@safe pure nothrow @nogc
unittest
{
    // At upem 1 and a one-point em, a design subunit is exactly one tick.
    const onePoint = LayoutUnit(point);
    assert(toLayoutUnit(DesignValue(long.max, 1), onePoint).value == LayoutUnit(long.max));
    assert(toLayoutUnit(DesignValue(long.min, 1), onePoint).value == LayoutUnit(long.min));
    // One unit past the top: 2^62 · 2 = 2^63.
    const over = toLayoutUnit(DesignValue(1L << 62, 1), LayoutUnit(2 * point));
    assert(over.hasError && over.error.kind == FontErrorKind.arithmeticExhausted);
    // (2^64 - 1) / 2 = long.max + 1/2 ties to the even 2^63, out of range; its
    // negation ties to long.min, in range.
    enum long third = 6_148_914_691_236_517_205; // (2^64 - 1) / 3
    const tie = toLayoutUnit(DesignValue(third, 2), LayoutUnit(3 * point));
    assert(tie.error.kind == FontErrorKind.arithmeticExhausted);
    assert(toLayoutUnit(DesignValue(-third, 2), LayoutUnit(3 * point)).value == LayoutUnit(long.min));
    // The widest products are exact: one far out of range, one landing on long.max.
    assert(toLayoutUnit(DesignValue(long.min, 16_384), LayoutUnit(long.max)).hasError);
    assert(toLayoutUnit(DesignValue(long.max, 16_384), LayoutUnit(16_384 * point)).value
        == LayoutUnit(long.max));
}

@("units.FTM8.designSumOverflow")
@safe pure nothrow @nogc
unittest
{
    static immutable DesignValue[3] run = [DesignValue(long.max - 10, 1_000), DesignValue(10, 1_000),
        DesignValue(1, 1_000)];
    const over = checkedSum(run[], 1_000);
    assert(over.hasError && over.error.kind == FontErrorKind.arithmeticExhausted);
    assert(checkedSum(run[0 .. 2], 1_000).value == DesignValue(long.max, 1_000));
    static immutable DesignValue[2] low = [DesignValue(long.min, 1_000), DesignValue(-1, 1_000)];
    assert(checkedSum(low[], 1_000).error.kind == FontErrorKind.arithmeticExhausted);
}

@("units.FTM9.integerAdvancesAt12pt")
@safe pure nothrow @nogc
unittest
{
    // upem 2048 at 12 pt: 12 · 65,536 / 2048 = 384 ticks per font unit, exactly.
    const em = LayoutUnit(12 * point);
    static immutable int[6] advances = [0, 1, 1_229, 2_048, -517, int.max];
    foreach (a; advances)
        assert(toLayoutUnit(DesignValue.fromUnits(a, 2_048), em).value == LayoutUnit(long(a) * 384));
}

@("units.FTM9.runRoundsOnce")
@safe pure nothrow @nogc
unittest
{
    // Two glyphs of one unit each, upem 2048, em 1024 ticks: half a tick each.
    const em = LayoutUnit(1_024 * tick);
    static immutable DesignValue[2] advances = [DesignValue(65_536, 2_048), DesignValue(65_536, 2_048)];
    foreach (a; advances)
        assert(toLayoutUnit(a, em).value == LayoutUnit(0));
    // Summed in design units first, the run is one tick.
    assert(toLayoutUnit(checkedSum(advances[], 2_048).value, em).value == LayoutUnit(1));
}

@("units.FTM10.deviceScaleIndependence")
@safe pure nothrow @nogc
unittest
{
    const em = LayoutUnit(12 * point);
    const at96 = Ppem.fromPhysical(em, 96).value, at192 = Ppem.fromPhysical(em, 192).value;
    assert(at96.numerator == 16 && at192.numerator == 32 && at96.isInteger && at192.isInteger);
    static immutable int[4] advances = [1_229, 1, -517, 2_047];
    foreach (a; advances)
    {
        const d = DesignValue.fromUnits(a, 2_048);
        assert(toPixels(d, at192) == 2 * toPixels(d, at96));
        // The physical result does not depend on the device at all.
        assert(toLayoutUnit(d, em).value == LayoutUnit(long(a) * 384));
    }
    // A fractional scale: 1.25 · 96 = 120 dpi gives 20 ppem.
    const at120 = Ppem.fromPhysical(em, Rational(I128(U128(480, 0)), U128(4, 0))).value;
    assert(at120.isInteger && at120.numerator == 20);
}

@("units.FTM10.integerAndFractionalPpem")
@safe pure nothrow @nogc
unittest
{
    const ten = LayoutUnit(10 * point);
    const fractional = Ppem.fromPhysical(ten, 96).value; // 10 · 96 / 72 = 40/3
    assert(!fractional.isInteger && fractional.numerator == 40 && fractional.denominator == 3);
    const value = fractional.value;
    assert(value.numerator.magnitude == U128(40, 0) && value.denominator == U128(3, 0));
    assert(Ppem.fromPhysical(ten, 72).value.isInteger);
    assert(Ppem.fromPhysical(LayoutUnit(point / 2), 1).value.denominator == 144);
    assert(Ppem.fromPhysical(ten, 0).error.kind == FontErrorKind.badValue);
    assert(Ppem.fromPhysical(ten, -96).error.kind == FontErrorKind.badValue);
    assert(Ppem.fromPhysical(LayoutUnit(-point), 96).error.kind == FontErrorKind.badValue);
    assert(Ppem.fromRational(Rational(I128(U128(0, 1)), U128(3, 0))).error.kind
        == FontErrorKind.arithmeticExhausted);
    assert(Ppem.fromRational(Rational(I128(U128(1, 0)), U128(0, 0))).error.kind == FontErrorKind.badValue);
}

@("units.FTM10.roundsOnceToNearestEven")
@safe pure nothrow @nogc
unittest
{
    // upem 1 and ppem 1/2^37: raw / 2^53, so raw picks the bits below the last place of 1.0.
    const p37 = ppemOf(1, 1UL << 37), p38 = ppemOf(1, 1UL << 38);
    assert(toPixels(DesignValue((1L << 53) + 1, 1), p37) == 1.0); // a tie, to the even 1.0
    assert(toPixels(DesignValue((1L << 53) + 3, 1), p37) == 1.0 + 0x1p-51); // a tie, to the even side
    assert(toPixels(DesignValue((1L << 54) + 3, 1), p38) == 1.0 + 0x1p-52); // past half: up
    assert(toPixels(DesignValue((1L << 54) + 1, 1), p38) == 1.0); // below half: down
    assert(toPixels(DesignValue(-((1L << 53) + 3), 1), p37) == -(1.0 + 0x1p-51));
    // Just below a power of two, where the spacing halves: 1 - 2^-54 ties to 1.0.
    assert(toPixels(DesignValue((1L << 54) - 1, 1), p38) == 1.0);
    assert(toPixels(DesignValue((1L << 54) - 3, 1), p38) == 1.0 - 0x1p-52); // a tie below 1, to the even side
    assert(toPixels(DesignValue(0, 1), p37) == 0.0);
    // The extremes: the largest numerator and the smallest nonzero value.
    assert(toPixels(DesignValue(long.min, 1), ppemOf(ulong.max, 1)) == -0x1p+111);
    assert(toPixels(DesignValue(1, 16_384), ppemOf(1, ulong.max)) > 0);
}

@("units.FTM10.naiveDoubleArithmeticDiffers")
@safe pure nothrow @nogc
unittest
{
    // 10 pt at 96 dpi, upem 1000. -380 units is -76/15 px exactly: 0x1.4444…p+2
    // with the next digit 4, so it rounds down; multiplying by a rounded 40/3
    // and dividing again lands one place too far out.
    const p = Ppem.fromPhysical(LayoutUnit(10 * point), 96).value;
    const d = DesignValue.fromUnits(-380, 1_000);
    const naive = cast(double) d.raw * (40.0 / 3.0) / (1_000 * 65_536.0);
    assert(toPixels(d, p) == -0x1.4444444444444p+2 && naive == -0x1.4444444444445p+2);
    const e = DesignValue.fromUnits(1_067, 1_000); // 21,340 / 1,500 px
    assert(toPixels(e, p) == 0x1.c740da740da74p+3);
    assert(cast(double) e.raw * (40.0 / 3.0) / (1_000 * 65_536.0) == 0x1.c740da740da75p+3);
}

/// Whether `x` is `numerator / denominator` (signs aside) rounded to nearest, ties to even.
private bool roundsCorrectly(double x, BigInt numerator, BigInt denominator) @safe
{
    if (numerator == 0)
        return x == 0;
    int exponent;
    const fraction = frexp(x, exponent);
    const m = cast(long) ldexp(fraction, 53); // x = m · 2^(exponent - 53), 2^52 ≤ m < 2^53
    const shift = exponent - 53;
    // Compare 4 · value with 4m ± the half-gaps, scaled to integers.
    BigInt lhs = numerator * 4, scale = denominator;
    if (shift >= 0)
        scale <<= shift;
    else
        lhs <<= -shift;
    const lowerGap = m == (1L << 52) ? 1 : 2;
    const low = scale * (4 * m - lowerGap), high = scale * (4 * m + 2);
    if (lhs < low || lhs > high)
        return false;
    return (lhs != low && lhs != high) || m % 2 == 0;
}

@("units.FTM10.matchesBigIntReference")
@safe
unittest
{
    auto rng = Random(0x5EED);
    foreach (i; 0 .. 20_000)
    {
        const raw = uniform!long(rng) >> uniform(0, 63, rng);
        const upem = cast(ushort) uniform(1, 16_385, rng);
        const numerator = uniform!ulong(rng) >> uniform(0, 64, rng) | 1;
        const denominator = uniform!ulong(rng) >> uniform(0, 64, rng) | 1;
        const ppem = Ppem.fromRational(Rational(I128(U128(numerator, 0)), U128(denominator, 0))).value;
        const x = toPixels(DesignValue(raw, upem), ppem);
        const magnitude = raw < 0 ? -BigInt(raw) : BigInt(raw);
        assert((raw < 0) == (x < 0));
        const exact = magnitude * BigInt(ppem.numerator), scale = BigInt(upem) * 65_536 * BigInt(ppem.denominator);
        const abs = x < 0 ? -x : x;
        assert(roundsCorrectly(abs, exact, scale));
        // The reference rejects either neighbor, so it would catch an off-by-one place.
        assert(raw == 0 || !roundsCorrectly(nextUp(abs), exact, scale));
        assert(raw == 0 || !roundsCorrectly(nextDown(abs), exact, scale));
    }
}
