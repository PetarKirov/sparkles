/**
Storage types for the floating-point formats D has no type for — IEEE
binary16, bfloat16 and the OCP Microscaling element formats FP8 E5M2 / E4M3,
FP6 E2M3 / E3M2 and FP4 E2M1 — and, by the same construction, for any format
`sparkles.base.text.float_conv` describes whose layout fits 64 bits.

A $(LREF CustomFloat) is its format's interchange bits and nothing else: 16,
8, 6 or 4 of them, in the smallest unsigned integer that holds them. It is a
storage type in the sense of Phobos' `std.numeric.CustomFloat`, which it is
modelled on — arithmetic happens in the narrowest native type that holds the
format exactly (`float` for every reduced format) and the result is stored
back with one correctly-rounded conversion — but with the parts Phobos gets
wrong put right: a 6- or 4-bit format is admissible, a value below the
smallest subnormal rounds instead of flushing, an out-of-range value follows
the format's overflow rule instead of asserting, and NaN-only formats exist.

Conversion is exact where the format allows and correctly rounded (ties to
even) where it does not, in every direction: a native value is decomposed
exactly and rounded once (`float` → `Float16` never rounds through a
`double` first), and `get!float` of a reduced value is the value itself. Text
goes through `sparkles.base.text.float_conv`'s reader and shortest writer at
the format's own width — `readDecimalFloat!Float16` is correctly rounded and
`writeShortest` prints the fewest digits that read back to the same bits.

The overflow rule is the format's: an IEEE-shaped format (`Float16`,
`BFloat16`, `Float8E5M2`) goes to `±infinity`; `Float8E4M3`, which has no
infinity, goes to its NaN, as PyTorch's `float8_e4m3fn` and `ml_dtypes` do;
the FP6 and FP4 formats, which have neither, saturate to the largest finite
value with the sign. A NaN assigned to a format that has none is a
precondition violation, as in Phobos.

Everything here is integer arithmetic and runs at CTFE; `enum h =
Float16(0.1f)` is a compile-time constant with the bits `0x2E66`. Serialisers
in `sparkles:wired` dispatch on `std.traits.isFloatingPoint` and do not yet
know these types.
*/
module sparkles.base.custom_float;

import std.traits : Unqual, isIntegral, isUnsigned;

import sparkles.base.text.float_conv : BinaryFloatFormat, BitsOf, DecodedFloat,
    bfloat16, binary16, binary32, compose, decode, decompose, encode, formatOf,
    fp4e2m1, fp6e2m3, fp6e3m2, fp8e4m3, fp8e5m2, isFloatLike, roundTo,
    writeShortest;

/// Whether `T` is a $(LREF CustomFloat) of some format.
enum bool isCustomFloat(T) = is(Unqual!T == CustomFloat!fmt, BinaryFloatFormat fmt);

/**
A value of format `fmt`, stored as its IEEE interchange bits.

The members follow the native types' where the concept exists (`mant_dig`,
`min_exp`, `max_exp`, `dig`, `max_10_exp`, `min_10_exp`, `max`, `min_normal`,
`epsilon`, `infinity`, `nan`), so generic code that reads a type's properties
reads these; a property the format lacks — `infinity` for `Float8E4M3`, `nan`
for the FP6 and FP4 formats — is absent rather than wrong. `epsilon` is a
subnormal for the two formats whose smallest normal is 1 (`Float6E2M3`,
`Float4E2M1`).

Params:
    fmt = the format, any $(LINK2 ../text/float_conv.html#BinaryFloatFormat,
        `BinaryFloatFormat`) whose interchange layout fits 64 bits — the
        seven reduced-precision constants, or `binary32`/`binary64` (a
        `CustomFloat!binary32` is bit-for-bit a `float`, which is how the
        construction is tested against the FPU)
*/
struct CustomFloat(BinaryFloatFormat fmt)
{
    static assert(fmt.storageBits <= 64, "the layout does not fit 64 bits");

    /// The format, as data — what `formatOf!(CustomFloat!fmt)` reads.
    enum BinaryFloatFormat format = fmt;

    /// The unsigned integer holding the interchange bits.
    alias Bits = BitsOf!fmt;

    /// The narrowest native type that holds every value of the format
    /// exactly: `float` for every reduced format. Arithmetic happens here.
    alias Native = NativeOf!fmt;

    private enum Bits signBit = cast(Bits)(1UL << (fmt.storageBits - 1));
    private enum Bits mantMask = cast(Bits)((1UL << fmt.mantBits) - 1);
    private enum Bits expMask = cast(Bits)(((1UL << fmt.expBits) - 1) << fmt.mantBits);

    private Bits _bits; // the invariant: bits above `storageBits` are zero

    // ── The native types' vocabulary ─────────────────────────────────────

    enum int mant_dig = fmt.mantDig;       /// `T.mant_dig`: significand bits, the implicit one included
    enum int min_exp = fmt.minExp;         /// `T.min_exp`: the smallest normal is `2^(min_exp - 1)`
    enum int max_exp = fmt.maxExp;         /// `T.max_exp`: every finite value is below `2^max_exp`
    enum int dig = fmt.dig;                /// `T.dig`: decimal digits of precision — 3, 2, 0, 0, 0, 0, 0
    enum int max_10_exp = fmt.max10Exp;    /// `T.max_10_exp`: the largest `k` with `10^k` finite
    enum int min_10_exp = fmt.min10Exp;    /// `T.min_10_exp`: the smallest `k` with `10^k` normal

    /// The largest finite value — 65 504, `(2 - 2^-7)·2^127`, 57 344, 448,
    /// 7.5, 28, 6.
    enum CustomFloat max = fromDecoded(DecodedFloat(0, fmt.maxFiniteSignificand,
        fmt.maxNormalExp2 - (fmt.mantDig - 1)));
    /// The smallest normal, `2^(min_exp - 1)`.
    enum CustomFloat min_normal = fromDecoded(DecodedFloat(0, 1, fmt.minNormalExp2));
    /// The gap between 1 and the next value, `2^(1 - mant_dig)`.
    enum CustomFloat epsilon = fromDecoded(DecodedFloat(0, 1, 1 - fmt.mantDig));
    /// The smallest positive value, one unit at the subnormal floor.
    enum CustomFloat min_subnormal = fromBits(1);
    static if (fmt.hasInfinity)
        /// Positive infinity — only in formats that encode one.
        enum CustomFloat infinity = fromDecoded(DecodedFloat(0, 0, 0, false, true));
    static if (fmt.hasNaN)
        /// The canonical NaN — only in formats that encode one.
        enum CustomFloat nan = fromDecoded(DecodedFloat(0, 0, 0, false, false, true));

    // ── Bits ─────────────────────────────────────────────────────────────

    /// The interchange bits; a 6- or 4-bit format's live in the low bits of
    /// a `ubyte`, the rest zero.
    Bits bits() const @safe pure nothrow @nogc => _bits;

    /// The value with interchange bits `raw` — the inverse of $(LREF bits).
    static CustomFloat fromBits(Bits raw) @safe pure nothrow @nogc
    in (fmt.storageBits == Bits.sizeof * 8 || (raw >> fmt.storageBits) == 0,
        "bits above the format's width")
    {
        CustomFloat r;
        r._bits = raw;
        return r;
    }

    /// The sign bit.
    bool sign() const @safe pure nothrow @nogc => (_bits & signBit) != 0;

    /// The biased exponent field.
    uint exponent() const @safe pure nothrow @nogc => cast(uint)((_bits & expMask) >> fmt.mantBits);

    /// The stored significand field, the implicit bit not included.
    Bits significand() const @safe pure nothrow @nogc => cast(Bits)(_bits & mantMask);

    /// The value as an integer significand and exponent — NaN and infinity
    /// as flags, `-0` as a negative zero.
    DecodedFloat decoded() const @safe pure nothrow @nogc => decode!fmt(_bits);

    /// The nearest value of the format to an exact `DecodedFloat` — the one
    /// rounding of every conversion into the type.
    static CustomFloat fromDecoded(DecodedFloat exact) @safe pure nothrow @nogc
        => fromBits(encode!fmt(roundTo!fmt(exact)));

    // ── Conversions in ───────────────────────────────────────────────────

    /// Constructs from a native floating-point value, another
    /// `CustomFloat`, or an integer, rounding once (ties to even).
    this(F)(F value) @safe pure nothrow @nogc
    if (isFloatLike!F || isIntegral!F)
    {
        this = value;
    }

    /// ditto
    ref CustomFloat opAssign(F)(F value) @safe pure nothrow @nogc return
    if (isFloatLike!F)
    {
        _bits = encode!fmt(roundTo!fmt(decompose!F(value)));
        return this;
    }

    /// ditto
    ref CustomFloat opAssign(F)(F value) @safe pure nothrow @nogc return
    if (isIntegral!F)
    {
        // Exact, whatever the integer's width: a `long` into a `Float16`
        // does not detour through a native type that would round it first.
        DecodedFloat d;
        static if (isUnsigned!F)
            d.lo = value;
        else
        {
            d.negative = value < 0;
            d.lo = value < 0 ? -cast(ulong) value : cast(ulong) value;
        }
        _bits = encode!fmt(roundTo!fmt(d));
        return this;
    }

    // ── Conversions out ──────────────────────────────────────────────────

    /// The value as `F` — exact when `F` holds the format (every native
    /// type does for the reduced formats), correctly rounded otherwise:
    /// `roundTo` is the identity on a value the target holds, and one
    /// rounding of the exact value where it does not — never a cast chain.
    F get(F)() const @safe pure nothrow @nogc
    if (isFloatLike!F)
        => compose!F(roundTo!(formatOf!F)(decoded));

    /// ditto
    alias opCast = get;

    // ── Arithmetic ───────────────────────────────────────────────────────

    /// Unary plus converts to $(LREF Native); negation is exact and stays
    /// in the type.
    Native opUnary(string op : "+")() const @safe pure nothrow @nogc => get!Native;

    /// ditto
    CustomFloat opUnary(string op : "-")() const @safe pure nothrow @nogc
        => fromBits(cast(Bits)(_bits ^ signBit));

    /**
    Binary arithmetic and comparison happen in the type D itself would pick
    for `Native op rhs` — so a `double` operand is not narrowed to `float`
    first (which would round twice), and two values of one format compute in
    their common `Native`. The result is that native type; assign it back to
    round it into the format.
    */
    auto opBinary(string op, F)(F rhs) const
    if ((op == "+" || op == "-" || op == "*" || op == "/" || op == "%")
        && (isFloatLike!F || isIntegral!F))
        => mixin("get!Native " ~ op ~ " asNative(rhs)");

    /// ditto
    auto opBinaryRight(string op, F)(F lhs) const
    if ((op == "+" || op == "-" || op == "*" || op == "/" || op == "%")
        && (__traits(isFloating, F) || isIntegral!F))
        => mixin("lhs " ~ op ~ " get!Native");

    /// ditto
    ref CustomFloat opOpAssign(string op, F)(F rhs) return
    if ((op == "+" || op == "-" || op == "*" || op == "/" || op == "%")
        && (isFloatLike!F || isIntegral!F))
    {
        this = opBinary!op(rhs);
        return this;
    }

    /// Equality by value: `-0 == +0`, and a NaN equals nothing, itself
    /// included.
    bool opEquals(F)(F rhs) const
    if (isFloatLike!F || isIntegral!F)
        => get!Native == asNative(rhs);

    /// Ordering by value; unordered (a NaN operand) compares false every
    /// way, as the native types do — the result is a `float` so it can be
    /// NaN.
    float opCmp(F)(F rhs) const
    if (isFloatLike!F || isIntegral!F)
    {
        const a = get!Native;
        const b = asNative(rhs);
        return a < b ? -1 : a > b ? 1 : a == b ? 0 : float.nan;
    }

    /// Consistent with $(LREF opEquals): both zeros hash alike.
    size_t toHash() const @safe pure nothrow @nogc
        => (_bits & ~signBit) == 0 ? 0 : _bits;

    /// The shortest decimal that reads back to the same bits, in scientific
    /// notation (`sparkles.base.text.float_conv.writeShortest`), plus `nan`,
    /// `inf` and `-inf`.
    void toString(Writer)(ref Writer w) const
    {
        writeShortest!CustomFloat(w, this);
    }

    private static auto asNative(F)(F rhs)
    {
        static if (isCustomFloat!F)
            return rhs.get!(F.Native);
        else
            return rhs;
    }
}

/// IEEE binary16, "half".
alias Float16 = CustomFloat!binary16;
/// bfloat16 — a `float`'s top half.
alias BFloat16 = CustomFloat!bfloat16;
/// OCP Microscaling FP8 E5M2.
alias Float8E5M2 = CustomFloat!fp8e5m2;
/// OCP Microscaling FP8 E4M3 — no infinity, one NaN.
alias Float8E4M3 = CustomFloat!fp8e4m3;
/// OCP Microscaling FP6 E2M3 — neither infinity nor NaN.
alias Float6E2M3 = CustomFloat!fp6e2m3;
/// OCP Microscaling FP6 E3M2 — neither infinity nor NaN.
alias Float6E3M2 = CustomFloat!fp6e3m2;
/// OCP Microscaling FP4 E2M1 — neither infinity nor NaN.
alias Float4E2M1 = CustomFloat!fp4e2m1;

/// The narrowest of `float`, `double` and `real` that holds every value of
/// `fmt` exactly.
template NativeOf(BinaryFloatFormat fmt)
{
    static if (holds!(binary32, fmt))
        alias NativeOf = float;
    else static if (holds!(formatOf!double, fmt))
        alias NativeOf = double;
    else
    {
        static assert(holds!(formatOf!real, fmt), "no native type holds the format");
        alias NativeOf = real;
    }
}

/// Whether every finite value of `narrow` is a value of `wide`.
private enum bool holds(BinaryFloatFormat wide, BinaryFloatFormat narrow) =
    wide.mantDig >= narrow.mantDig && wide.maxExp >= narrow.maxExp
    && wide.minSubnormalExp2 <= narrow.minSubnormalExp2;

// ─────────────────────────────────────────────────────────────────────────────
// The Phobos spelling
// ─────────────────────────────────────────────────────────────────────────────

/**
`std.numeric.CustomFloatFlags`, for the $(LREF CustomFloat) overload that
takes Phobos' `(precision, exponentWidth, flags)` — the subset a
$(LINK2 ../text/float_conv.html#BinaryFloatFormat, `BinaryFloatFormat`)
expresses: signed, normalised, with subnormals, and any combination of
`infinity` and `nan` but infinity without NaN.
*/
enum CustomFloatFlags
{
    signed = 1,           /// a sign bit — always, here
    storeNormalized = 2,  /// an implicit leading one — always, here
    allowDenorm = 4,      /// subnormals — always, here
    infinity = 8,         /// `±infinity` encoded
    nan = 16,             /// NaN encoded
    ieee = signed | storeNormalized | allowDenorm | infinity | nan, /// all of IEEE
    none = 0,             /// none of the above (not expressible here)
}

/**
The Phobos spelling: `CustomFloat!(10, 5)` is $(LREF Float16),
`CustomFloat!(3, 4, CustomFloatFlags.ieee ^ CustomFloatFlags.infinity)` is
$(LREF Float8E4M3). The bias is Phobos' default, `2^(exponentWidth - 1) - 1`.
*/
template CustomFloat(uint precision, uint exponentWidth,
    CustomFloatFlags flags = CustomFloatFlags.ieee)
{
    alias CustomFloat = CustomFloat!(phobosFormat(precision, exponentWidth, flags));
}

private BinaryFloatFormat phobosFormat(uint precision, uint exponentWidth,
    CustomFloatFlags flags) @safe pure nothrow @nogc
{
    alias F = CustomFloatFlags;
    enum required = F.signed | F.storeNormalized | F.allowDenorm;
    assert((flags & required) == required,
        "only signed, normalised formats with subnormals are expressible");
    assert(!((flags & F.infinity) && !(flags & F.nan)), "infinity without NaN is not a layout");
    assert(exponentWidth >= 2 && exponentWidth < 31 && precision >= 1,
        "an exponent field of two bits or more, and a significand");
    const specials = (flags & F.infinity) ? BinaryFloatFormat.Specials.ieee
        : (flags & F.nan) ? BinaryFloatFormat.Specials.nanOnly : BinaryFloatFormat.Specials.none;
    const bias = (1 << (exponentWidth - 1)) - 1;
    const minExp = 2 - bias;
    const fields = 1 << exponentWidth;
    const maxExp = minExp + fields - (specials == BinaryFloatFormat.Specials.ieee ? 3 : 2);
    return BinaryFloatFormat(cast(int) precision + 1, minExp, maxExp, specials);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

@("CustomFloat.properties")
@safe pure nothrow @nogc
unittest
{
    static assert(Float16.mant_dig == 11 && Float16.min_exp == -13 && Float16.max_exp == 16);
    static assert(Float16.dig == 3 && Float16.max_10_exp == 4 && Float16.min_10_exp == -4);
    static assert(BFloat16.dig == 2 && BFloat16.max_10_exp == 38 && BFloat16.min_10_exp == -37);
    static assert(Float8E4M3.dig == 0 && Float8E4M3.max_10_exp == 2 && Float8E4M3.min_10_exp == -1);
    static assert(Float4E2M1.dig == 0 && Float4E2M1.max_10_exp == 0 && Float4E2M1.min_10_exp == 0);
    static assert(is(Float16.Bits == ushort) && is(Float8E4M3.Bits == ubyte)
        && is(Float6E2M3.Bits == ubyte) && is(Float4E2M1.Bits == ubyte));
    static assert(is(Float16.Native == float) && is(BFloat16.Native == float)
        && is(Float4E2M1.Native == float));
    static assert(is(CustomFloat!binary32.Native == float));
    static assert(is(CustomFloat!(formatOf!double).Native == double));

    // The OCP MX v1.0 tables, bit for bit.
    static assert(Float16.max.bits == 0x7BFF && Float16.max.get!float == 65_504.0f);
    static assert(BFloat16.max.bits == 0x7F7F && BFloat16.max.get!float == 0x1.FEp127f);
    static assert(Float8E5M2.max.bits == 0x7B && Float8E5M2.max.get!float == 57_344.0f);
    static assert(Float8E4M3.max.bits == 0x7E && Float8E4M3.max.get!float == 448.0f);
    static assert(Float6E2M3.max.bits == 0x1F && Float6E2M3.max.get!float == 7.5f);
    static assert(Float6E3M2.max.bits == 0x1F && Float6E3M2.max.get!float == 28.0f);
    static assert(Float4E2M1.max.bits == 0x7 && Float4E2M1.max.get!float == 6.0f);
    static assert(Float16.min_normal.bits == 0x0400 && Float16.min_normal.get!float == 0x1p-14f);
    static assert(BFloat16.min_normal.bits == 0x0080 && Float8E5M2.min_normal.bits == 0x04);
    static assert(Float8E4M3.min_normal.bits == 0x08 && Float8E4M3.min_normal.get!float == 0x1p-6f);
    static assert(Float6E2M3.min_normal.bits == 0x08 && Float6E2M3.min_normal.get!float == 1.0f);
    static assert(Float6E3M2.min_normal.bits == 0x04 && Float6E3M2.min_normal.get!float == 0.25f);
    static assert(Float4E2M1.min_normal.bits == 0x2 && Float4E2M1.min_normal.get!float == 1.0f);
    static assert(Float16.min_subnormal.get!float == 0x1p-24f);
    static assert(BFloat16.min_subnormal.get!float == 0x1p-133f);
    static assert(Float8E5M2.min_subnormal.get!float == 0x1p-16f);
    static assert(Float8E4M3.min_subnormal.get!float == 0x1p-9f);
    static assert(Float6E2M3.min_subnormal.get!float == 0.125f);
    static assert(Float6E3M2.min_subnormal.get!float == 0.0625f);
    static assert(Float4E2M1.min_subnormal.get!float == 0.5f);
    static assert(Float16.epsilon.get!float == 0x1p-10f && BFloat16.epsilon.get!float == 0x1p-7f);
    static assert(Float6E2M3.epsilon.bits == 1 && Float4E2M1.epsilon.bits == 1); // subnormal
    static assert(Float16.infinity.bits == 0x7C00 && Float16.nan.bits == 0x7E00);
    static assert(Float8E5M2.infinity.bits == 0x7C && Float8E5M2.nan.bits == 0x7E);
    static assert(Float8E4M3.nan.bits == 0x7F);
    static assert(!__traits(hasMember, Float8E4M3, "infinity"));
    static assert(!__traits(hasMember, Float6E2M3, "nan") && !__traits(hasMember, Float4E2M1, "infinity"));
    static assert(Float16.init.bits == 0 && Float16.init == 0);

    // Raw fields.
    const h = Float16.fromBits(0xC500); // -5
    assert(h.sign && h.exponent == 17 && h.significand == 0x100);
    assert(h.get!float == -5.0f);
    // The same properties as a `float`'s, on the format that is one.
    alias F32 = CustomFloat!binary32;
    static assert(F32.mant_dig == float.mant_dig && F32.dig == float.dig
        && F32.max_10_exp == float.max_10_exp && F32.min_10_exp == float.min_10_exp);
    static assert(F32.max.get!float == float.max && F32.min_normal.get!float == float.min_normal
        && F32.epsilon.get!float == float.epsilon);
}

@("CustomFloat.conversionPins")
@safe pure nothrow @nogc
unittest
{
    static assert(Float16(1.0f).bits == 0x3C00);
    static assert(Float16(0.1f).bits == 0x2E66);
    static assert(Float16(65_504.0f).bits == 0x7BFF);
    static assert(Float16(65_519.0f).bits == 0x7BFF);   // below the threshold
    static assert(Float16(65_520.0f).bits == 0x7C00);   // the threshold: even → inf
    static assert(Float16(-65_520.0).bits == 0xFC00);
    static assert(Float16(-0.0f).bits == 0x8000 && Float16(0.0).bits == 0);
    static assert(Float16(0x1p-25f).bits == 0);         // half the smallest subnormal → 0
    static assert(Float16(0x1.8p-25f).bits == 1);       // three quarters → up
    static assert(Float16(float.nan).bits == 0x7E00 && Float16(-float.infinity).bits == 0xFC00);
    // One rounding, not two: 1 + 2^-11 + 2^-35 is above the Float16 midpoint
    // 1 + 2^-11 (a `double` value); a `float` cast would land on the midpoint
    // first and then break the tie down.
    static assert(Float16(1.0 + 0x1p-11 + 0x1p-35).bits == 0x3C01);
    assert(Float16(cast(float)(1.0 + 0x1p-11 + 0x1p-35)).bits == 0x3C00); // runtime: CTFE casts may not round
    static assert(Float16(1.0 + 0x1p-11).bits == 0x3C00);   // the tie itself: even
    static assert(Float16(1.0 + 0x1p-11 + 0x1p-10).bits == 0x3C02); // 1 + 3·2^-11: even, up

    // The overflow rule per format.
    static assert(Float8E4M3(448.0f).bits == 0x7E);
    static assert(Float8E4M3(464.0f).bits == 0x7E);      // the tie: even is 448
    static assert(Float8E4M3(464.1f).bits == 0x7F);      // NaN
    static assert(Float8E4M3(1000).bits == 0x7F && Float8E4M3(-1000).bits == 0xFF);
    static assert(Float8E5M2(60_000.0f).bits == 0x7B);   // below the threshold 61 440
    static assert(Float8E5M2(62_000.0f).bits == 0x7C);   // inf
    static assert(Float6E2M3(7.75f).bits == 0x1F);       // tie → 8, which saturates to 7.5
    static assert(Float6E2M3(100).bits == 0x1F && Float6E2M3(-100).bits == 0x3F);
    static assert(Float6E3M2(30.0f).bits == 0x1F);       // tie → 32, saturates to 28
    static assert(Float4E2M1(7).bits == 0x7);            // tie → 8, saturates to 6
    static assert(Float4E2M1(6.9f).bits == 0x7 && Float4E2M1(5).bits == 0x6); // 5: tie → even, 4
    static assert(Float4E2M1(2.5f).bits == 0x4);         // tie between 2 and 3: even is 2
    static assert(Float4E2M1(0.25f).bits == 0 && Float4E2M1(0.26f).bits == 1);

    // Integers, exactly, however wide.
    static assert(Float16(1).bits == 0x3C00 && Float16(-2).bits == 0xC000);
    static assert(Float16(2049).bits == 0x6800);         // 2049 ties to even: 2048
    static assert(Float16(2051).bits == 0x6802);         // 2051 ties to even: 2052
    static assert(Float16(long.min).bits == 0xFC00 && Float16(ulong.max).bits == 0x7C00);
    static assert(BFloat16(long.max).bits == 0x5F00);    // 2^63
    static assert(BFloat16(0x0100_0100_0000_0001UL).bits == 0x5B80); // 2^56 + 2^40 + 1 → 2^56

    // Between formats.
    static assert(Float8E4M3(Float16(3.5f)).bits == 0x46);
    static assert(Float16(Float8E4M3.max).get!float == 448.0f);
    static assert(BFloat16(Float16.max).bits == 0x4780);   // 65504 → 65536 (bfloat16 has 8 bits)
    static assert(Float16(BFloat16.max).bits == 0x7C00);   // way past: inf

    // Out, exactly and rounded — `get` rounds to the destination, so a
    // `double`-shaped value narrows to `float` the way the FPU does, and a
    // narrower storage type is reached in one rounding.
    static assert(Float16.fromBits(0x2E66).get!float == 0.0999755859375f);
    static assert(Float16.fromBits(0x2E66).get!double == 0.0999755859375);
    alias F64 = CustomFloat!(formatOf!double);
    static assert(F64.fromBits(0x3690_0000_0000_0001).get!float == 0x1p-149f); // 0x1.0000000000001p-150: above half the smallest float subnormal
    static assert(F64.fromBits(0x3690_0000_0000_0000).get!float == 0.0f);       // exactly half: even, zero
    static assert(Float16(0.1f).get!Float8E4M3.bits == Float8E4M3(0.1f).bits);
    static assert(Float16(0.1f).get!Float8E4M3.bits == 0x1D);                  // 0.1 → 0.09375 (1.5 × 2^-4)
    static assert(BFloat16.max.get!Float16.bits == 0x7C00);                    // past binary16: inf
    static assert(Float16(7).get!Float4E2M1.bits == 0x7);                       // 7 → the tie → 8 → saturates to 6
    static assert(Float16(464).get!Float8E4M3.bits == 0x7E && Float16(465).get!Float8E4M3.bits == 0x7F);
    static assert(Float16(-0.0f).get!Float4E2M1.bits == 0x8 && Float16.nan.get!Float8E4M3.bits == 0x7F);
    assert(CustomFloat!(formatOf!double)(0.1).get!float == 0.1f); // rounds once (runtime: an x87 CTFE carries 0.1 at 64 bits)
    assert(cast(float) Float16(2.5f) == 2.5f);
    assert(cast(real) Float4E2M1(6) == 6.0L);
}

// Every pattern of every ≤16-bit format widens to `float` and back to the
// same bits; the NaN patterns come back as NaN.
@("CustomFloat.widenIsExact")
@safe pure nothrow @nogc
unittest
{
    import std.meta : AliasSeq;

    static foreach (T; AliasSeq!(Float16, BFloat16, Float8E5M2, Float8E4M3, Float6E2M3,
        Float6E3M2, Float4E2M1))
    {{
        foreach (raw; 0 .. 1u << T.format.storageBits)
        {
            const v = T.fromBits(cast(T.Bits) raw);
            const float f = v.get!float;
            if (f != f)
            {
                assert(v.decoded.isNaN && T(f).decoded.isNaN);
                continue;
            }
            assert(T(f).bits == raw);
            assert(T(cast(double) f).bits == raw);
            assert(T(cast(real) f).bits == raw);
            assert(v == v && v == f && f == v.get!double);
        }
    }}
}

// A `CustomFloat!binary32` is a `float`, bit for bit, in both directions;
// `binary64` likewise against `doubleToBits`. The narrowing constructor from
// `double` must agree with the FPU's `cast(float)`.
@("CustomFloat.matchesNativeBits")
@system unittest
{
    import sparkles.base.text.float_conv : doubleToBits, bitsToDouble;

    alias F32 = CustomFloat!binary32;
    alias F64 = CustomFloat!(formatOf!double);
    ulong state = 0xC0FF_EE12_3456_789B;
    foreach (i; 0 .. 200_000)
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const uint fb = cast(uint) state;
        const float f = *cast(const float*) &fb;
        if (f == f)
        {
            assert(F32(f).bits == fb);
            assert(F32.fromBits(fb).get!float is f);
        }
        const ulong db = state ^ (state >> 29);
        const double d = bitsToDouble(db);
        if (d == d)
        {
            assert(F64(d).bits == db);
            assert(F64.fromBits(db).get!double is d);
            assert(F32(d).get!float is cast(float) d);          // one rounding in, the FPU's
            assert(F64.fromBits(db).get!float is cast(float) d); // one rounding out, likewise
        }
    }
    // …and ±0.
    assert(F32(-0.0f).bits == 0x8000_0000 && F32(0.0f).bits == 0);
}

// Phobos' `CustomFloat` is a differential oracle where it is right: the
// normal range. (Its subnormal rounding shifts twice, and it flushes deep
// subnormals to zero, so those are excluded; its overflow is an assertion.)
@("CustomFloat.agreesWithPhobos")
@system unittest
{
    import std.numeric : PhobosFloat = CustomFloat;

    alias Ours = CustomFloat!(10, 5);
    static assert(is(Ours == Float16));
    alias Theirs = PhobosFloat!(10, 5);

    ulong state = 0x5EED_5EED_5EED_5EED;
    size_t compared = 0;
    foreach (i; 0 .. 100_000)
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        // A float in Float16's normal range: exponent field 113 .. 142.
        const uint fb = (cast(uint) state & 0x807F_FFFF) | ((113 + cast(uint)(state >> 40) % 30) << 23);
        const float f = *cast(const float*) &fb;
        Theirs t = f;
        const Ours o = f;
        const tBits = (cast(ushort) t.sign << 15) | (cast(ushort) t.exponent << 10) | cast(ushort) t.significand;
        if (t.exponent == 0 || t.exponent == 31)
            continue; // a result Phobos rounds outside the normal range
        assert(o.bits == tBits);
        assert(o.get!float == t.get!float);
        compared++;
    }
    assert(compared > 90_000);
}

@("CustomFloat.operators")
@safe pure nothrow @nogc
unittest
{
    Float16 h = 1.5f;
    // Binary arithmetic yields the native type; assignment rounds back.
    static assert(is(typeof(h + h) == float));
    static assert(is(typeof(h * 2) == float));
    static assert(is(typeof(h + 1.0) == double));
    static assert(is(typeof(2.0 - h) == double));
    static assert(is(typeof(h / 1.0L) == real));
    assert(h + h == 3.0f && h * 2 == 3.0f && 2.0 - h == 0.5 && h / 3 == 0.5f);
    assert(h % 1 == 0.5f);
    h += 1;
    assert(h == 2.5f && h.bits == 0x4100);
    h *= 0.1;                         // 0.25 → the nearest Float16
    assert(h.bits == 0x3400);
    h -= h;
    assert(h == 0 && h.bits == 0);
    // The `double` operand is not narrowed first: 1 + (2^-11 + 2^-35) in
    // `double`, then rounded once into the format, is 1 + 2^-10.
    const one = Float16(1);
    Float16 sum = one + (0x1p-11 + 0x1p-35);
    assert(sum.bits == 0x3C01);
    // Unary.
    static assert(is(typeof(+one) == float));
    assert(+one == 1.0f && (-one).bits == 0xBC00 && (-(-one)).bits == 0x3C00);
    assert((-Float16(0)).bits == 0x8000);
    // Equality and ordering by value, NaN unordered, zeros equal.
    assert(Float16(-0.0f) == Float16(0.0f) && Float16(-0.0f).bits != Float16(0.0f).bits);
    assert(Float16.nan != Float16.nan && !(Float16.nan == Float16.nan));
    assert(!(Float16.nan < one) && !(Float16.nan > one) && !(Float16.nan <= one) && !(Float16.nan >= one));
    assert(Float16(1) < Float16(2) && Float16(2) > 1 && Float16(2) >= 2.0 && Float16(-1) < 0);
    assert(Float16.infinity > Float16.max && -Float16.infinity < -Float16.max);
    assert(Float16(3) == Float8E4M3(3) && Float16(3.5f) > Float8E4M3(3));
    assert(Float16(-0.0f).toHash == Float16(0.0f).toHash);
    // Ordering of a mixed comparison happens in the wider operand's type.
    assert(one < 1.0 + 0x1p-30);
}

@("CustomFloat.toString")
@safe unittest
{
    import sparkles.base.buffer : checkToString;

    checkToString(Float16(0.1f), "1e-1");
    checkToString(Float16(65_504), "6.55e4");
    checkToString(Float16(-2.5f), "-2.5e0");
    checkToString(Float16(-0.0f), "-0e0");
    checkToString(Float16.min_subnormal, "6e-8");
    checkToString(Float16.infinity, "inf");
    checkToString(-Float16.infinity, "-inf");
    checkToString(Float16.nan, "nan");
    checkToString(Float8E4M3.max, "4.5e2"); // 450 reads back as 448
    checkToString(Float4E2M1(6), "6e0");
    checkToString(Float4E2M1(0.5f), "5e-1");
    checkToString(BFloat16.max, "3.39e38");
    checkToString(Float8E5M2(57_344), "6e4"); // 60 000 reads back as 57 344
}

// `formatOf`, and through it the reader and the shortest writer, take the
// storage types.
@("CustomFloat.readAndWrite")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.text.float_conv : readDecimalFloat, shortestDigits, slowFloat;

    static assert(formatOf!Float16 == binary16 && formatOf!Float4E2M1 == fp4e2m1);
    static assert(isFloatLike!Float16 && !isFloatLike!int);

    static Float16 read(string text)
    {
        const(char)[] s = text;
        const r = readDecimalFloat!Float16(s);
        assert(r.hasValue && s.length == 0);
        return r.value;
    }

    assert(read("0.1").bits == 0x2E66);
    assert(read("-0").bits == 0x8000);
    assert(read("65504").bits == 0x7BFF);
    assert(read("65520").bits == 0x7C00);     // the tie past max: even, up → inf
    assert(read("65519.999").bits == 0x7BFF);
    assert(read("1e100").bits == 0x7C00);
    assert(read("2049").bits == 0x6800);      // tie → 2048
    assert(read("2049.0000000000000000000001").bits == 0x6801); // above the tie: 2050
    assert(read("5.960464477539063e-8").bits == 1);  // a hair above the smallest subnormal
    assert(read("2.98023223876953125e-8").bits == 0); // exactly half: even → 0
    static assert(read("3.140625").bits == 0x4248);   // at CTFE
    assert(slowFloat!Float16("1", null, 0).bits == 0x3C00);
    assert(decompose(Float16.fromBits(0x3C00)) == DecodedFloat(0, 1024, -10));
    assert(compose!Float16(DecodedFloat(0, 1024, -10)).bits == 0x3C00);

    char[8] digits;
    int exp10;
    assert(shortestDigits!Float16(Float16(0.1f), digits[], exp10) == 1 && digits[0] == '1' && exp10 == -1);
}

// ─────────────────────────────────────────────────────────────────────────────
// Exhaustive proofs over the reduced formats, with `std.bigint` as the
// exact arithmetic
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import std.bigint : BigInt;

    private alias Reduced = imported!"std.meta".AliasSeq!(Float16, BFloat16, Float8E5M2,
        Float8E4M3, Float6E2M3, Float6E3M2, Float4E2M1);

    /// `n × 2^e` as decimal text `digits e exp10` — exact.
    private string dyadicText(BigInt n, int e)
    {
        import std.conv : to;

        if (e >= 0)
            return (n << e).to!string;
        foreach (_; 0 .. -e)
            n *= 5;
        return n.to!string ~ "e" ~ e.to!string;
    }

    /// The largest finite pattern of `T` — the positive patterns below it are
    /// every finite positive value, in order.
    private enum maxFiniteBits(T) = T.max.bits;

    /// Exact round-to-nearest-even of `num / den` (both positive) in `fmt`.
    private DecodedFloat oracleRound(BinaryFloatFormat fmt)(BigInt num, BigInt den)
    {
        enum p = fmt.mantDig;
        // e = floor(log2(num / den)).
        int e = cast(int)(num.uintLength * 32) - cast(int)(den.uintLength * 32);
        while ((e >= 0 ? den << e : den) > (e < 0 ? num << -e : num))
            e--;
        while ((e + 1 >= 0 ? den << (e + 1) : den) <= (e + 1 < 0 ? num << -(e + 1) : num))
            e++;
        int lsb = e - (p - 1);
        if (lsb < fmt.minSubnormalExp2)
            lsb = fmt.minSubnormalExp2;
        // q = floor(x / 2^lsb), r = the rest, compared with a half.
        const scaledNum = lsb < 0 ? num << -lsb : num;
        const scaledDen = lsb > 0 ? den << lsb : den;
        BigInt q = scaledNum / scaledDen;
        const rest = scaledNum - q * scaledDen;
        const twice = rest * 2;
        if (twice > scaledDen || (twice == scaledDen && (q & 1) == 1))
            q++;
        if (q == BigInt(1) << p)
        {
            q = BigInt(1) << (p - 1);
            lsb++;
        }
        DecodedFloat r;
        if (q == 0)
            return r;
        r.lo = cast(ulong) q.toLong;
        r.exp2 = lsb;
        if (lsb + imported!"core.bitop".bsr(r.lo) > fmt.maxNormalExp2)
            r.isInf = true;
        return r;
    }
}

// Every rounding boundary of every reduced format: the exact midpoint between
// two neighbouring values reads as the even one, the spellings one decimal
// unit either side as the neighbours; the overflow threshold takes the
// format's overflow rule and half the smallest subnormal reads as zero.
@("CustomFloat.everyMidpointParses")
@system unittest
{
    static foreach (T; Reduced)
    {{
        static T read(string text)
        {
            const(char)[] s = text;
            const r = imported!"sparkles.base.text.float_conv".readDecimalFloat!T(s);
            assert(r.hasValue && s.length == 0, text);
            return r.value;
        }

        enum top = maxFiniteBits!T;
        foreach (uint b; 0 .. top)
        {
            const lo = T.fromBits(cast(T.Bits) b).decoded, hi = T.fromBits(cast(T.Bits)(b + 1)).decoded;
            // m = (lo + hi) / 2 as n × 2^e.
            const e = (lo.exp2 < hi.exp2 ? lo.exp2 : hi.exp2) - 1;
            const n = (BigInt(lo.lo) << (lo.exp2 - e - 1)) + (BigInt(hi.lo) << (hi.exp2 - e - 1));
            const even = (b & 1) == 0 ? b : b + 1;
            assert(read(dyadicText(n, e)).bits == even, T.stringof);
            assert(read(dyadicText(n - 1, e)).bits == b, T.stringof);
            assert(read(dyadicText(n + 1, e)).bits == b + 1, T.stringof);
            assert(read("-" ~ dyadicText(n, e)).bits == (even | T.signBit), T.stringof);
        }
        // max + half an ulp: the tie past the largest finite value goes to
        // even — up, into the overflow rule's answer, where max's significand
        // is odd (every all-ones format), down to max where it is even (E4M3,
        // whose all-ones pattern is the NaN).
        const maxD = T.max.decoded;
        const threshold = (BigInt(maxD.lo) << 1) + 1;
        const overflow = T.fromDecoded(DecodedFloat(0, 0, 0, false, true)).bits;
        const tie = (maxD.lo & 1) ? overflow : T.max.bits;
        assert(read(dyadicText(threshold, maxD.exp2 - 1)).bits == tie, T.stringof);
        assert(read(dyadicText(threshold - 1, maxD.exp2 - 1)).bits == T.max.bits, T.stringof);
        assert(read(dyadicText(threshold + 1, maxD.exp2 - 1)).bits == overflow, T.stringof);
        // Half the smallest subnormal: a tie with zero, which is even.
        assert(read(dyadicText(BigInt(1), T.format.minSubnormalExp2 - 1)).bits == 0, T.stringof);
        assert(read(dyadicText(BigInt(3), T.format.minSubnormalExp2 - 2)).bits == 1, T.stringof);
    }}
}

// Random decimals of up to 25 digits across each format's exponent range,
// against an independent exact rounding in `std.bigint`.
@("CustomFloat.agreesWithBigIntOracle")
@system unittest
{
    import std.conv : to;

    ulong state = 0xB1A5_ED12_3456_789F;
    static ulong next(ref ulong s)
    {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return s;
    }

    static foreach (T; Reduced)
    {{
        enum fmt = T.format;
        enum span = fmt.saturateHighExp10 - fmt.saturateLowExp10 + 12;
        foreach (i; 0 .. 4000)
        {
            // 1 .. 25 significant digits, an exponent that puts the value
            // anywhere from below zero's threshold to past overflow.
            const nd = 1 + next(state) % 25;
            char[25] digits;
            foreach (k; 0 .. nd)
                digits[k] = cast(char)('0' + next(state) % 10);
            if (digits[0] == '0')
                digits[0] = '1';
            const exp10 = cast(int)(next(state) % span) + fmt.saturateLowExp10 - 6 - cast(int) nd;
            const text = digits[0 .. nd].idup ~ "e" ~ exp10.to!string;
            const(char)[] s = text;
            const ours = imported!"sparkles.base.text.float_conv".readDecimalFloat!T(s);
            assert(ours.hasValue && s.length == 0);

            BigInt num = BigInt(digits[0 .. nd]);
            BigInt den = 1;
            if (exp10 >= 0)
                num *= BigInt(10) ^^ exp10;
            else
                den = BigInt(10) ^^ (-exp10);
            const expected = T.fromDecoded(oracleRound!fmt(num, den));
            assert(ours.value.bits == expected.bits, text ~ " in " ~ T.stringof);
        }
    }}
}

// Every finite value of every reduced format round-trips through its
// shortest spelling, and no spelling with fewer significant digits reads
// back to it: the candidates with fewer digits inside the value's rounding
// interval are enumerated exactly and each is read.
@("CustomFloat.shortestIsShortest")
@system unittest
{
    import std.conv : to;
    import std.math : floor, log10;
    import sparkles.base.buffer : UniqueBuffer;

    static foreach (T; Reduced)
    {{
        enum fmt = T.format;
        static T read(string text)
        {
            const(char)[] s = text;
            const r = imported!"sparkles.base.text.float_conv".readDecimalFloat!T(s);
            assert(r.hasValue && s.length == 0, text);
            return r.value;
        }

        enum top = maxFiniteBits!T;
        foreach (uint b; 1 .. top + 1)
        {
            const v = T.fromBits(cast(T.Bits) b);
            UniqueBuffer!(char, 32) text;
            v.toString(text);
            const spelled = text[].idup;
            assert(read(spelled).bits == b, spelled ~ " in " ~ T.stringof);
            // Significant digits: everything before 'e' that is a digit.
            size_t nDigits = 0;
            foreach (c; spelled)
            {
                if (c == 'e')
                    break;
                if (c >= '0' && c <= '9')
                    nDigits++;
            }
            if (spelled.length > 1 && spelled[0] == '0')
                nDigits--; // never happens for a nonzero value, but be exact

            // The rounding interval [lo, hi] as rationals over 2^-(k):
            // lo = (v + prev) / 2, hi = (v + next) / 2 — next past max is
            // the overflow threshold, prev below the smallest is v / 2.
            const d = v.decoded;
            const prev = T.fromBits(cast(T.Bits)(b - 1)).decoded;
            const nextD = b == top ? DecodedFloat(0, d.lo * 2 + 1, d.exp2 - 1) // max + ½ulp, as 2·max + 1 at exp - 1
                : T.fromBits(cast(T.Bits)(b + 1)).decoded;
            // Everything is a multiple of 2^-k; twice the endpoints at that
            // scale keeps the halves exact: a bound is n / den2.
            const int k = -(fmt.minSubnormalExp2 - 3);
            static BigInt scaled(in DecodedFloat x, int k) => BigInt(x.lo) << (x.exp2 + k);
            const lo2 = scaled(prev, k) + scaled(d, k);
            const hi2 = scaled(d, k) + scaled(nextD, k);
            const den2 = BigInt(1) << (k + 1);
            const inclusive = (b & 1) == 0;

            // For every shorter digit count, every candidate m × 10^q inside
            // [lo, hi] must fail to read back as v.
            foreach (int fewer; 1 .. cast(int) nDigits)
            {
                // m × 10^q ∈ [lo, hi] with m of `fewer` digits pins q to
                // floor(log10 v) - fewer + 1, give or take one at the ends of
                // the interval; the m bounds below empty every other q.
                const int qMid = cast(int) floor(log10(v.get!double)) - fewer + 1;
                foreach (int q; qMid - 2 .. qMid + 2)
                {
                    // bounds of m: ceil(lo2 / (den2 · 10^q)) .. floor(hi2 / (den2 · 10^q))
                    BigInt scale = den2;
                    BigInt numLo = lo2, numHi = hi2;
                    if (q >= 0)
                        scale *= BigInt(10) ^^ q;
                    else
                    {
                        numLo *= BigInt(10) ^^ (-q);
                        numHi *= BigInt(10) ^^ (-q);
                    }
                    BigInt mLo = numLo / scale;
                    if (mLo * scale < numLo)
                        mLo++;
                    if (!inclusive && mLo * scale == numLo)
                        mLo++;
                    BigInt mHi = numHi / scale;
                    if (!inclusive && mHi * scale == numHi)
                        mHi--;
                    const BigInt digitsLo = BigInt(10) ^^ (fewer - 1), digitsHi = BigInt(10) ^^ fewer - 1;
                    if (mLo < digitsLo)
                        mLo = digitsLo;
                    if (mHi > digitsHi)
                        mHi = digitsHi;
                    for (BigInt m = mLo; m <= mHi; m++)
                    {
                        const candidate = m.to!string ~ "e" ~ q.to!string;
                        assert(read(candidate).bits != b,
                            candidate ~ " is a shorter spelling of " ~ spelled ~ " in " ~ T.stringof);
                    }
                }
            }
        }
    }}
}
