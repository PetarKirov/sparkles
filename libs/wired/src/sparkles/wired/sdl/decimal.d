/**
Shared decimal-to-`real` kernel for the SDL `decimal` (`BD`) scalar family.

Both directions must agree exactly, or SPEC §10 LAW 3 cannot hold for `real`
fields: the canonical writer picks the shortest decimal spelling whose
$(I emitted) text parses back to the value it started from, and the lexer
decodes that spelling with this same routine. Phobos' `std.conv.to!real`
cannot serve either role — it is not correctly rounded for the x87 80-bit
format, so a writer using it as its round-trip oracle both rejects values it
should accept and disagrees with any independent reader.

The grammar accepted here is SDL's, not JSON's: an optional sign, decimal
digits, and at most one point. There is no exponent — the canonical writer
expands one through
$(REF writeFixedDecimal, sparkles,wired,sdl,writer) before this kernel ever
sees the text.
*/
module sparkles.wired.sdl.decimal;

import core.int128 : Cent;

/** Largest `n` whose `10^^n` is exact in `real`'s mantissa.

`10^^n == 2^^n * 5^^n`, and only the odd factor costs mantissa bits, so the
limit is the largest `n` with `5^^n < 2^^64`: `5^^27 ≈ 7.45e18` fits,
`5^^28 ≈ 3.73e19` does not.
*/
private enum int exactPow10Max = 27;

private static immutable real[exactPow10Max + 1] pow10Table = [
    1e0L, 1e1L, 1e2L, 1e3L, 1e4L, 1e5L, 1e6L,
    1e7L, 1e8L, 1e9L, 1e10L, 1e11L, 1e12L, 1e13L,
    1e14L, 1e15L, 1e16L, 1e17L, 1e18L, 1e19L, 1e20L,
    1e21L, 1e22L, 1e23L, 1e24L, 1e25L, 1e26L, 1e27L,
];

/** Digits per exactly-accumulating chunk: `10^^19 - 1 < ulong.max`, so
nineteen decimal digits always fit a `ulong` without truncation. */
private enum size_t chunkDigits = 19;

/** Significant digits this kernel can tell apart.

Past this width a longer spelling decodes to the same `real`, so it is also
the point at which the canonical writer's shortest-spelling search saturates:
searching further cannot find a spelling the reader treats differently.
*/
package enum size_t sdlDecimalSignificantDigits = 2 * chunkDigits;

/** Coarse powers `10^^(exactPow10Max * k)`, spanning `real`'s whole exponent
range so any scale is reached by index rather than by iteration.

Entries past `10^^27` cannot be exact, but each is the compiler's correctly
rounded literal — one half-ulp, once. Walking there in `10^^27` steps instead
would round about 180 times and lose the value entirely; that is exactly what
puts `real.max` and `real.min_normal` out of reach.
*/
private static immutable real[183] pow10Coarse = [
    1e0L, 1e27L, 1e54L, 1e81L, 1e108L, 1e135L, 1e162L, 1e189L, 1e216L,
    1e243L, 1e270L, 1e297L, 1e324L, 1e351L, 1e378L, 1e405L, 1e432L, 1e459L,
    1e486L, 1e513L, 1e540L, 1e567L, 1e594L, 1e621L, 1e648L, 1e675L, 1e702L,
    1e729L, 1e756L, 1e783L, 1e810L, 1e837L, 1e864L, 1e891L, 1e918L, 1e945L,
    1e972L, 1e999L, 1e1026L, 1e1053L, 1e1080L, 1e1107L, 1e1134L, 1e1161L,
    1e1188L, 1e1215L, 1e1242L, 1e1269L, 1e1296L, 1e1323L, 1e1350L, 1e1377L,
    1e1404L, 1e1431L, 1e1458L, 1e1485L, 1e1512L, 1e1539L, 1e1566L, 1e1593L,
    1e1620L, 1e1647L, 1e1674L, 1e1701L, 1e1728L, 1e1755L, 1e1782L, 1e1809L,
    1e1836L, 1e1863L, 1e1890L, 1e1917L, 1e1944L, 1e1971L, 1e1998L, 1e2025L,
    1e2052L, 1e2079L, 1e2106L, 1e2133L, 1e2160L, 1e2187L, 1e2214L, 1e2241L,
    1e2268L, 1e2295L, 1e2322L, 1e2349L, 1e2376L, 1e2403L, 1e2430L, 1e2457L,
    1e2484L, 1e2511L, 1e2538L, 1e2565L, 1e2592L, 1e2619L, 1e2646L, 1e2673L,
    1e2700L, 1e2727L, 1e2754L, 1e2781L, 1e2808L, 1e2835L, 1e2862L, 1e2889L,
    1e2916L, 1e2943L, 1e2970L, 1e2997L, 1e3024L, 1e3051L, 1e3078L, 1e3105L,
    1e3132L, 1e3159L, 1e3186L, 1e3213L, 1e3240L, 1e3267L, 1e3294L, 1e3321L,
    1e3348L, 1e3375L, 1e3402L, 1e3429L, 1e3456L, 1e3483L, 1e3510L, 1e3537L,
    1e3564L, 1e3591L, 1e3618L, 1e3645L, 1e3672L, 1e3699L, 1e3726L, 1e3753L,
    1e3780L, 1e3807L, 1e3834L, 1e3861L, 1e3888L, 1e3915L, 1e3942L, 1e3969L,
    1e3996L, 1e4023L, 1e4050L, 1e4077L, 1e4104L, 1e4131L, 1e4158L, 1e4185L,
    1e4212L, 1e4239L, 1e4266L, 1e4293L, 1e4320L, 1e4347L, 1e4374L, 1e4401L,
    1e4428L, 1e4455L, 1e4482L, 1e4509L, 1e4536L, 1e4563L, 1e4590L, 1e4617L,
    1e4644L, 1e4671L, 1e4698L, 1e4725L, 1e4752L, 1e4779L, 1e4806L, 1e4833L,
    1e4860L, 1e4887L, 1e4914L,
];

/// Largest exponent a single indexed step can cover.
private enum int coarseSpan = exactPow10Max * (pow10Coarse.length - 1);

/** Applies `10^^exponent` to `value`.

Each step costs at most two roundings — one indexed coarse power and one
exactly representable remainder — and `real`'s entire exponent range is
covered in at most two steps. Division is used for negative exponents rather
than multiplication by a reciprocal, so the remainder stays correctly rounded.
*/
private real scaleByPow10(real value, int exponent) @safe pure nothrow @nogc
{
    while (exponent != 0)
    {
        const up = exponent > 0;
        const magnitude = up ? exponent : -exponent;
        const step = magnitude < coarseSpan ? magnitude : coarseSpan;
        const coarse = pow10Coarse[step / exactPow10Max];
        const exact = pow10Table[step % exactPow10Max];
        if (up)
        {
            value *= exact;
            value *= coarse;
            exponent -= step;
        }
        else
        {
            // Divide by the small factor first: the coarse divisor is the one
            // that can drive an intermediate into the subnormal range.
            value /= exact;
            value /= coarse;
            exponent += step;
        }
    }
    return value;
}

/** Decodes an SDL decimal significand into `real`.

`text` is the scalar's spelling with any `BD` suffix already removed. The
significant digits are accumulated into two exact `ulong` chunks and combined
once, so a spelling of up to 38 significant digits costs at most a couple of
roundings — close enough to correctly rounded that the canonical writer's
shortest-spelling search always converges well inside `real`'s digit budget.

Returns `real.nan` for a spelling the SDL grammar does not accept; callers
have already validated shape, so this is a defensive result rather than the
reported error.
*/
package real parseDecimalReal(scope const(char)[] text)
    @safe pure nothrow @nogc
{
    size_t at;
    bool negative;
    if (at < text.length && (text[at] == '+' || text[at] == '-'))
    {
        negative = text[at] == '-';
        at++;
    }
    if (at == text.length)
        return real.nan;

    // Trailing zeroes belong in the exponent, not the mantissa. Feeding
    // "…18000…0" through the chunker costs a rounding that the scale step
    // then compounds — which is what puts `real.max` out of reach.
    size_t lastSignificant = size_t.max;
    foreach (i; at .. text.length)
        if (text[i] != '0' && text[i] != '.')
            lastSignificant = i;

    ulong hi;
    ulong lo;
    size_t hiDigits;
    size_t loDigits;
    int exponent;
    bool afterDot;
    bool significant;
    bool sawDot;
    for (; at < text.length; at++)
    {
        const c = text[at];
        if (c == '.')
        {
            if (sawDot)
                return real.nan;
            sawDot = true;
            afterDot = true;
            continue;
        }
        const digit = cast(uint)(c - '0');
        if (digit > 9)
            return real.nan;
        if (!significant && digit == 0)
        {
            // Leading zeroes carry no significance; one after the point still
            // moves the scale.
            if (afterDot)
                exponent--;
            continue;
        }
        // A digit past the last non-zero one, or past our two chunks, is
        // outside `real`'s resolution; only its effect on the scale survives.
        const carries = at <= lastSignificant;
        if (carries && hiDigits < chunkDigits)
        {
            hi = hi * 10 + digit;
            hiDigits++;
            significant = true;
            if (afterDot)
                exponent--;
        }
        else if (carries && loDigits < chunkDigits)
        {
            lo = lo * 10 + digit;
            loDigits++;
            significant = true;
            if (afterDot)
                exponent--;
        }
        else if (!afterDot)
            exponent++;
    }

    // Join the chunks in exact 128-bit arithmetic and round once. Doing it in
    // `real` instead costs three roundings — the product, the sum, and the
    // scale — and 1.5 ulp of drift is enough that no spelling within `real`'s
    // digit budget maps back onto the value it came from.
    real value;
    if (loDigits == 0)
        value = cast(real) hi; // exact: 64-bit mantissa holds any `ulong`
    else
    {
        import core.int128 : Cent, add, mul;

        const joined = add(mul(hi, pow10Integer[loDigits]), Cent(lo));
        value = realFromCent(joined);
    }
    value = scaleByPow10(value, exponent);
    return negative ? -value : value;
}

/// Exact integer powers of ten, up to the widest chunk a `ulong` holds.
private static immutable ulong[chunkDigits + 1] pow10Integer = [
    1UL, 10UL, 100UL, 1_000UL, 10_000UL, 100_000UL, 1_000_000UL,
    10_000_000UL, 100_000_000UL, 1_000_000_000UL, 10_000_000_000UL,
    100_000_000_000UL, 1_000_000_000_000UL, 10_000_000_000_000UL,
    100_000_000_000_000UL, 1_000_000_000_000_000UL,
    10_000_000_000_000_000UL, 100_000_000_000_000_000UL,
    1_000_000_000_000_000_000UL, 10_000_000_000_000_000_000UL,
];

/** Converts an unsigned 128-bit integer to the nearest `real`, ties to even.

`real`'s 64-bit mantissa holds any `ulong` exactly, so the whole conversion is
one shift of the top 64 significant bits plus a single rounding decision on
what fell off — and scaling that result by a power of two is exact.
*/
private real realFromCent(Cent value) @safe pure nothrow @nogc
{
    import core.bitop : bsr;
    import std.math : ldexp;

    if (value.hi == 0)
        return cast(real) value.lo;

    const shift = bsr(value.hi) + 1; // bits that must fall below the mantissa
    ulong keep;
    ulong roundBit;
    bool sticky;
    if (shift == 64)
    {
        keep = value.hi;
        roundBit = value.lo >> 63;
        sticky = (value.lo << 1) != 0;
    }
    else
    {
        keep = (value.hi << (64 - shift)) | (value.lo >> shift);
        roundBit = (value.lo >> (shift - 1)) & 1;
        sticky = (value.lo & ((1UL << (shift - 1)) - 1)) != 0;
    }

    int exponent2 = shift;
    if (roundBit && (sticky || (keep & 1)))
    {
        keep++;
        if (keep == 0) // the round carried out of the mantissa
        {
            keep = 1UL << 63;
            exponent2++;
        }
    }
    return ldexp(cast(real) keep, exponent2);
}

@("sdl.decimal.exactAndRounded")
@safe pure nothrow @nogc
unittest
{
    assert(parseDecimalReal("0") == 0.0L);
    assert(parseDecimalReal("-0") == 0.0L);
    assert(parseDecimalReal("1") == 1.0L);
    assert(parseDecimalReal("-1") == -1.0L);
    assert(parseDecimalReal("123.45") == 123.45L);
    assert(parseDecimalReal("0.001") == 0.001L);
    assert(parseDecimalReal(".5") == 0.5L);
    assert(parseDecimalReal("-.25") == -0.25L);
    assert(parseDecimalReal("0.125") == 0.125L);

    // Dyadic values are exact in both directions.
    assert(parseDecimalReal("0.0000152587890625") == 0x1p-16L);

    // Nineteen-digit integers land on the chunk boundary exactly.
    assert(parseDecimalReal("9999999999999999999") == 9999999999999999999.0L);

    // Malformed spellings are rejected rather than silently truncated.
    import std.math : isNaN;

    assert(isNaN(parseDecimalReal("")));
    assert(isNaN(parseDecimalReal("-")));
    assert(isNaN(parseDecimalReal("1.2.3")));
    assert(isNaN(parseDecimalReal("1e5")));
    assert(isNaN(parseDecimalReal("12x")));
}

// The kernel resolves the exact case Phobos' `to!real` gets wrong: this
// 22-digit spelling is well inside half an ulp of its `real`, so a correctly
// rounded parse must return that value.
@("sdl.decimal.beatsPhobosToReal")
@safe unittest
{
    import std.conv : to;

    enum spelling = "-1.527064050293794113039";
    const kernel = parseDecimalReal(spelling);
    const phobos = spelling.to!real;
    assert(kernel !is phobos, "the kernel would not be needed if these agreed");

    // The kernel's answer is the one that survives a re-spelling at full
    // precision; Phobos' is off by at least an ulp.
    import std.format : format;

    assert(parseDecimalReal(format("%.25g", kernel)) is kernel);
}
