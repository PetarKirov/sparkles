#!/usr/bin/env dub
/+ dub.sdl:
    name "uom_quantity_rational_exponents"
    targetPath "build"
+/
/**
 * Units of measure — the `ℚⁿ` variant: rational exponents make `sqrt` total.
 *
 * Exponents are normalized rationals (CTFE `gcd` reduction, `den > 0`), so
 * dimension equality is still field-wise comparison of unique normal forms:
 * `sqrt(m²)` produces exponent `2/2`, which normalizes to `1/1` and is
 * therefore *the same type* as a plain length. Over `ℚ` the map `d ↦ d²` is
 * an automorphism, so `sqrt` applies to every grade — including `m` itself,
 * yielding the first-class grade `m^(1/2)` — which is nevertheless NOT
 * addable to `m` (`static assert(!__traits(compiles, ...))`). A
 * pendulum-period demo shows a fractional grade appearing transiently and
 * landing back in the integer lattice.
 *
 * Companion to docs/research/units-of-measure/theory/free-abelian-group.md
 * § "`ℤⁿ` vs `ℚⁿ`: what forces the extension, what it costs" (see also
 * theory/type-system-mechanisms.md § "Fractional and irrational powers").
 *
 * Run with: `dub run --single quantity-rational-exponents.d`
 */
module uom_quantity_rational_exponents;

/// Euclid on non-negative operands; CTFE-friendly, no Phobos needed.
int gcd(int a, int b) @safe pure nothrow @nogc
in (a >= 0 && b >= 0)
{
    while (b != 0)
    {
        const t = a % b;
        a = b;
        b = t;
    }
    return a;
}

/// A rational exponent kept in unique normal form: `gcd(num, den) == 1` and
/// `den > 0`. Normalization is what makes type identity work — equal
/// exponents are bit-identical template arguments, so `2/2` and `1/1` name
/// the *same* dimension.
struct Rational
{
    int num;
    int den = 1;

    invariant (den > 0, "Rational must stay normalized: den > 0");

    Rational opBinary(string op)(in Rational rhs) const
    if (op == "+" || op == "-")
        => rational(mixin("num * rhs.den " ~ op ~ " rhs.num * den"), den * rhs.den);

    Rational opUnary(string op : "-")() const
        => Rational(-num, den);

    /// The exact halving that `ℤⁿ` lacks: division by 2 is total over `ℚ`.
    Rational halved() const @safe pure nothrow @nogc
        => rational(num, den * 2);
}

/// Builds the unique normal form: reduces by the gcd and keeps `den > 0`.
Rational rational(int num, int den) @safe pure nothrow @nogc
in (den != 0, "denominator must be non-zero")
out (r; r.den > 0)
{
    if (den < 0)
    {
        num = -num;
        den = -den;
    }
    const g = gcd(num < 0 ? -num : num, den);
    return g == 0 ? Rational(0, 1) : Rational(num / g, den / g);
}

@("Rational.normalization.unique-normal-form")
@safe pure nothrow @nogc
unittest
{
    assert(rational(2, 4) == Rational(1, 2));
    assert(rational(1, -2) == Rational(-1, 2));
    assert(rational(0, 7) == Rational(0, 1));
    assert(Rational(1, 2) + Rational(1, 2) == Rational(1));
}

/// A dimension: one element of `ℚ³` over (mass, length, time), stored as
/// normalized rational exponents.
struct Dim
{
    Rational mass;
    Rational length;
    Rational time;
}

/// The group operation, component-wise: `sign = +1` for multiplication,
/// `sign = -1` for division (the group inverse).
Dim combine(in Dim a, in Dim b, in int sign) @safe pure nothrow @nogc
in (sign == 1 || sign == -1)
{
    Rational signed(in Rational r) => sign == 1 ? r : -r;

    return Dim(
        mass: a.mass + signed(b.mass),
        length: a.length + signed(b.length),
        time: a.time + signed(b.time),
    );
}

/// Halves every exponent — the dimension-level image of `sqrt`, total on
/// every grade because `ℚ³` is divisible.
Dim halved(in Dim d) @safe pure nothrow @nogc
    => Dim(mass: d.mass.halved, length: d.length.halved, time: d.time.halved);

@("Dim.halved.lands-on-normal-form")
@safe pure nothrow @nogc
unittest
{
    // 2/1 halves to the *normalized* 1/1, not a distinct 2/2.
    static assert(halved(Dim(length: Rational(2))) == Dim(length: Rational(1)));
}

/// CTFE-built unit label, e.g. `"m^(1/2)"` or `"m s^-2"`; the identity
/// element renders as `"(dimensionless)"`. GC-allocating, but only ever
/// evaluated at compile time below.
string unitString(in Dim d) @safe pure
{
    import std.conv : to;

    string result;

    void put(in string symbol, in Rational exp)
    {
        if (exp.num == 0)
            return;
        if (result.length > 0)
            result ~= ' ';
        result ~= symbol;
        if (exp == Rational(1))
            return;
        result ~= exp.den == 1
            ? "^" ~ exp.num.to!string
            : "^(" ~ exp.num.to!string ~ "/" ~ exp.den.to!string ~ ")";
    }

    put("kg", d.mass);
    put("m", d.length);
    put("s", d.time);
    return result.length > 0 ? result : "(dimensionless)";
}

/// A `ℚ³`-graded quantity: one bare `double` tagged with its grade `dim`.
struct Quantity(Dim dim)
{
    double value;

    /// Compile-time unit label of this grade (used by `toString`).
    enum string symbol = unitString(dim);

    /// `+`/`-` exist only within a single grade: both operands share `dim`.
    Quantity opBinary(string op)(in Quantity rhs) const
    if (op == "+" || op == "-")
        => Quantity(mixin("value " ~ op ~ " rhs.value"));

    /// `*`/`/` are total: the result grade adds/subtracts exponent vectors.
    auto opBinary(string op, Dim rhsDim)(in Quantity!rhsDim rhs) const
    if (op == "*" || op == "/")
        => Quantity!(combine(dim, rhsDim, op == "*" ? 1 : -1))(
            mixin("value " ~ op ~ " rhs.value"));

    /// Scaling by a bare number is dimensionless: the grade is unchanged.
    Quantity opBinaryRight(string op : "*")(in double k) const
        => Quantity(k * value);

    string toString() const
    {
        import std.format : format;
        return format!"%.6g %s"(value, symbol);
    }
}

/// `sqrt` over `ℚ³`: total on every grade — every exponent is exactly halved.
/// (In `ℤⁿ` this is typable only at even exponent vectors: Kennedy's
/// `sqrt : real d² → real d`.)
auto sqrt(Dim dim)(in Quantity!dim q)
in (q.value >= 0, "sqrt of a negative quantity")
{
    import std.math : stdSqrt = sqrt;
    return Quantity!(halved(dim))(stdSqrt(q.value));
}

void main() @safe
{
    import std.math : PI;
    import std.stdio : writeln;

    auto area = Quantity!(Dim(length: Rational(2)))(156.25); // 156.25 m^2
    auto side = sqrt(area);

    // Normalization pays off here: halving 2/1 yields exactly 1/1, so
    // sqrt(area) has the *same type* as any other length ...
    static assert(is(typeof(side) == Quantity!(Dim(length: Rational(1)))));
    auto metre = Quantity!(Dim(length: Rational(1)))(1.0);
    static assert(__traits(compiles, side + metre));

    // ... and m^(1/2) is a first-class grade of its own ...
    auto rootSide = sqrt(side);
    static assert(is(typeof(rootSide) == Quantity!(Dim(length: Rational(1, 2)))));

    // ... but it is NOT a length: adding m^(1/2) to m is rejected at compile
    // time. This assert holds precisely because the addition does not compile.
    static assert(!__traits(compiles, rootSide + side),
        "adding m^(1/2) to m must not compile");

    // A fractional grade can be transient: the pendulum period
    // T = 2π·sqrt(L/g) passes through sqrt over s² and lands back in the
    // integer lattice.
    auto pendulum = Quantity!(Dim(length: Rational(1)))(2.5); // 2.5 m
    auto gravity =                                            // toy g = 10 m/s²
        Quantity!(Dim(length: Rational(1), time: Rational(-2)))(10.0);
    auto period = 2.0 * PI * sqrt(pendulum / gravity);
    static assert(is(typeof(period) == Quantity!(Dim(time: Rational(1)))));

    writeln("area       = ", area);
    writeln("sqrt(area) = ", side, " (a plain length: 2/2 normalizes to 1)");
    writeln("sqrt(side) = ", rootSide, " (a first-class fractional grade)");
    writeln("period     = ", period, " (2π·sqrt(L/g) — back in the integer lattice)");
}
