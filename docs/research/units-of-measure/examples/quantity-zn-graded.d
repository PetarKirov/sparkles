#!/usr/bin/env dub
/+ dub.sdl:
    name "uom_quantity_zn_graded"
    targetPath "build"
+/
/**
 * Units of measure — a minimal `ℤⁿ`-graded `Quantity` prototype.
 *
 * A dimension is stored directly as its unique normal form in the free
 * abelian group `ℤ³`: a compile-time vector of integer exponents over the
 * base dimensions (mass, length, time). `Quantity!dim` wraps one `double`;
 * `+`/`-` exist only within a single grade (identical exponent vector), while
 * `*`/`/` are total and add/subtract exponent vectors — "normalize and
 * compare vectors" is the entire type-checking algorithm. The rejection demo
 * `static assert(!__traits(compiles, metres + seconds))` turns the intended
 * compile-time failure into a checked, passing part of the program.
 *
 * Companion to docs/research/units-of-measure/theory/free-abelian-group.md
 * § "Central theorem: freeness, i.e. unique normal forms" and
 * § "How addition across dimensions is treated".
 *
 * Run with: `dub run --single quantity-zn-graded.d`
 */
module uom_quantity_zn_graded;

/// A dimension: one element of the free abelian group `ℤ³` over the base
/// dimensions, stored directly as its unique-normal-form exponent vector.
struct Dim
{
    int mass;
    int length;
    int time;
}

/// The group operation, component-wise on exponent vectors: `sign = +1` for
/// quantity multiplication, `sign = -1` for division (the group inverse).
Dim combine(in Dim a, in Dim b, in int sign) @safe pure nothrow @nogc
in (sign == 1 || sign == -1)
{
    return Dim(
        mass: a.mass + sign * b.mass,
        length: a.length + sign * b.length,
        time: a.time + sign * b.time,
    );
}

/// CTFE-built unit label for an exponent vector, e.g. `Dim(mass: 1, time: -2)`
/// renders as `"kg s^-2"`; the identity element renders as `"(dimensionless)"`.
/// GC-allocating, but only ever evaluated at compile time below.
string unitString(in Dim d) @safe pure
{
    import std.conv : to;

    string result;

    void put(in string symbol, in int exp)
    {
        if (exp == 0)
            return;
        if (result.length > 0)
            result ~= ' ';
        result ~= symbol;
        if (exp != 1)
            result ~= "^" ~ exp.to!string;
    }

    put("kg", d.mass);
    put("m", d.length);
    put("s", d.time);
    return result.length > 0 ? result : "(dimensionless)";
}

/// A `ℤ³`-graded quantity: one bare `double` tagged with its grade `dim`.
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

    string toString() const
    {
        import std.format : format;
        return format!"%.6g %s"(value, symbol);
    }
}

enum Dim massDim = Dim(mass: 1);
enum Dim lengthDim = Dim(length: 1);
enum Dim timeDim = Dim(time: 1);

@("Quantity.grading.multiplication-adds-exponent-vectors")
@safe pure nothrow @nogc
unittest
{
    auto v = Quantity!lengthDim(6.0) / Quantity!timeDim(2.0);
    static assert(is(typeof(v) == Quantity!(Dim(length: 1, time: -1))));
    assert(v.value == 3.0);
}

void main() @safe
{
    import std.stdio : writeln;

    auto distance = Quantity!lengthDim(120.0); // 120 m
    auto elapsed = Quantity!timeDim(10.0);     // 10 s
    auto mass = Quantity!massDim(3.0);         // 3 kg

    // velocity : the grades (0,1,0) + (0,0,-1) add component-wise.
    auto velocity = distance / elapsed;
    static assert(is(typeof(velocity) == Quantity!(Dim(length: 1, time: -1))));

    // force : mass·length·time⁻² — a newton, assembled from base grades.
    auto acceleration = velocity / elapsed;
    auto force = mass * acceleration;
    static assert(is(typeof(force) == Quantity!(Dim(mass: 1, length: 1, time: -2))));

    // Within one grade, addition is defined ...
    static assert(__traits(compiles, distance + distance));

    // ... but crossing grades is REJECTED at compile time. These asserts hold
    // (and the program compiles) precisely because the additions do not.
    auto metres = Quantity!lengthDim(1.0);
    auto seconds = Quantity!timeDim(1.0);
    static assert(!__traits(compiles, metres + seconds),
        "adding length to time must not compile");
    static assert(!__traits(compiles, force + velocity),
        "adding force to velocity must not compile");

    // Round trip through the group: dividing then multiplying by the same
    // grade cancels the exponent vectors exactly.
    static assert(is(typeof(velocity * elapsed) == typeof(distance)));

    writeln("distance         = ", distance);
    writeln("elapsed          = ", elapsed);
    writeln("velocity         = ", velocity);
    writeln("acceleration     = ", acceleration);
    writeln("force            = ", force);
    writeln("velocity*elapsed = ", velocity * elapsed, " (back to the grade of distance)");
}
