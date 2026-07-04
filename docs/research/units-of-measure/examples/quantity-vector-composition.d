#!/usr/bin/env dub
/+ dub.sdl:
    name "uom_quantity_vector_composition"
    dependency "sparkles:math" path="../../../.."
    dflags "-preview=in" "-preview=dip1000"
    targetPath "build"
+/
/**
 * Units of measure ⋈ linear algebra — the two orderings, head to head, and a
 * co-design recommendation for `sparkles:math`.
 *
 * A dimensioned 3-vector (a raytracer position or edge) can be built two ways:
 *
 *   A.  `Quantity!(dim, Vec3)` — the dimension wraps a numeric `Vector`. Works
 *       with the current `sparkles:math.Vector` unchanged; one dimension for the
 *       whole vector. But `Vector.dot` is dimension-blind (`cast(CommonType)`),
 *       so the caller must re-attach the grade (dot of two length-vectors is an
 *       area), and `Vector` ships no 3-D `cross`/`magnitude`/`normalize`.
 *
 *   B.  `Vector!(Quantity!dim, N)` — a vector *of* dimensioned scalars. This is
 *       what you actually want to write, and it **does not compile today**: the
 *       library constrains `struct Vector(T, N) if (isNumeric!T)`, and a
 *       `Quantity` is not `isNumeric`. Relaxing that to an `isScalar` capability
 *       concept (supports `+ - * /`) makes a vector of quantities work, and — the
 *       payoff — `dot` returns the *element's* product type, so `dot(length-vec,
 *       length-vec)` is an area *for free*, with no cast. This file reimplements a
 *       ~30-line element-generic `Vec(Scalar, N)` to demonstrate B.
 *
 * The recommendation this yields for the `sparkles:math` redesign (which is open):
 *   1. Relax `Vector`'s `isNumeric!T` to an `isScalar!T` capability concept so a
 *      `Quantity` is a valid element (ordering B).
 *   2. Make `dot`/`cross`/`magnitude` element-type-driven (dimension-correct),
 *      not `cast(CommonType)`; add the missing 3-D `cross`/`magnitude`/`normalize`.
 *   3. Add an N-generic, unit-aware affine `Point!(dim,N)`/`Vec!(dim,N)` split
 *      (ordering C) — the same affine separation the 2-D math-evolution plan wants
 *      (see quantity-affine-torsor.d).
 *
 * Companion to docs/research/units-of-measure/theory/type-system-mechanisms.md
 * and docs/research/units-of-measure/theory/torsor-representation.md.
 *
 * Run with: `dub run --single quantity-vector-composition.d`
 */
module uom_quantity_vector_composition;

import sparkles.math.vector : Vector;
import std.traits : Unqual;

/// The numeric payload used by ordering A.
alias Vec3 = Vector!(double, 3);

/// A dimension: an exponent vector in `ℤ³` over (mass, length, time).
struct Dim
{
    int mass;
    int length;
    int time;
}

Dim combine(in Dim a, in Dim b, in int sign) @safe pure nothrow @nogc
in (sign == 1 || sign == -1)
    => Dim(
        mass: a.mass + sign * b.mass,
        length: a.length + sign * b.length,
        time: a.time + sign * b.time,
    );

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

/// A graded quantity — the scalar `double` case is a valid `isScalar` element for
/// ordering B; the `Vec3` case is ordering A.
struct Quantity(Dim dim, Payload = double)
{
    Payload value;

    enum string symbol = unitString(dim);

    Quantity opBinary(string op)(in Quantity rhs) const
    if (op == "+" || op == "-")
        => Quantity(mixin("value " ~ op ~ " rhs.value"));

    auto opBinary(string op, Dim rhsDim, RP)(in Quantity!(rhsDim, RP) rhs) const
    if (op == "*" || op == "/")
    {
        auto p = mixin("value " ~ op ~ " rhs.value");
        return Quantity!(combine(dim, rhsDim, op == "*" ? 1 : -1), Unqual!(typeof(p)))(p);
    }

    string toString() const @safe
    {
        import std.array : appender;
        import std.format : formattedWrite;

        auto sink = appender!string();
        static if (is(Payload == double))
            formattedWrite(sink, "%.6g %s", value, symbol);
        else
        {
            value.toString(sink);
            formattedWrite(sink, " %s", symbol);
        }
        return sink[];
    }
}

enum Dim lengthDim = Dim(length: 1);
enum Dim areaDim = Dim(length: 2);

alias Length = Quantity!(lengthDim, double);
alias Area = Quantity!(areaDim, double);

// --- Ordering A: Quantity!(dim, Vec3) over the real sparkles:math.Vector -------

alias Displacement = Quantity!(lengthDim, Vec3);

/// Dimension-aware dot for ordering A: wrap the numeric `Vector.dot` and re-attach
/// the grade the library discards.
Area dotA(in Displacement x, in Displacement y) @safe pure nothrow @nogc
    => Area(x.value.dot(y.value));

// --- Ordering B: a minimal element-generic Vec(Scalar, N) ---------------------
//
// The element `T` need only support `+` and `*` — NOT be `isNumeric`. This is the
// proposed relaxation of `sparkles:math.Vector`'s `if (isNumeric!T)` constraint.

/// A vector whose element is any `+`/`*`-capable scalar — including a `Quantity`.
struct Vec(T, size_t N)
{
    T[N] data;

    this(T[N] xs...)
    {
        data[] = xs[];
    }

    /// Component-wise addition (both operands must share the element grade).
    Vec opBinary(string op : "+")(in Vec rhs) const
    {
        Vec r;
        foreach (i, ref e; r.data)
            e = data[i] + rhs.data[i];
        return r;
    }

    /// Dot product returns the ELEMENT product type: for `T = Length`, that is an
    /// `Area`. The dimension falls out of the element's own `*` — no cast, no
    /// dimension-blindness. This is the whole payoff of ordering B.
    auto dot()(in Vec rhs) const
    {
        auto acc = data[0] * rhs.data[0];
        foreach (i; 1 .. N)
            acc = acc + data[i] * rhs.data[i];
        return acc;
    }
}

@("Quantity.composition.orderings-agree-and-B-is-dimension-correct")
@safe pure nothrow @nogc
unittest
{
    // Ordering A: one dimension for the whole vector.
    auto a1 = Displacement(Vec3(3, 4, 0));
    auto a2 = Displacement(Vec3(3, 4, 0));
    auto areaA = dotA(a1, a2);
    static assert(is(typeof(areaA) == Area));
    assert(areaA.value == 25);

    // Ordering B: a vector of Length elements; dot is an Area by construction.
    auto b1 = Vec!(Length, 3)(Length(3), Length(4), Length(0));
    auto areaB = b1.dot(b1);
    static assert(is(typeof(areaB) == Area));
    assert(areaB.value == 25);

    // The two orderings agree numerically.
    assert(areaA.value == areaB.value);
}

void main() @safe
{
    import std.stdio : writeln;

    // The blocker, stated as a machine-checked fact: the current Vector cannot
    // hold a Quantity element, but the element-generic Vec can.
    static assert(!__traits(compiles, Vector!(Length, 3)),
        "sparkles:math.Vector requires isNumeric!T — a vector of Quantities is unnameable");
    static assert(__traits(compiles, Vec!(Length, 3)),
        "the element-generic Vec accepts a Quantity element (the proposed relaxation)");

    auto edge = Displacement(Vec3(3, 4, 0));
    auto viaA = dotA(edge, edge);

    auto edgeB = Vec!(Length, 3)(Length(3), Length(4), Length(0));
    auto viaB = edgeB.dot(edgeB);

    writeln("ordering A  Quantity!(length, Vec3)  |edge|² = ", viaA);
    writeln("ordering B  Vec!(Length, 3)          |edge|² = ", viaB);
    writeln("Vector!(Quantity, N) compiles today?  ",
        __traits(compiles, Vector!(Length, 3)), "  (the isNumeric!T blocker)");
    writeln("Vec!(Quantity, N)    compiles?        ",
        __traits(compiles, Vec!(Length, 3)), "  (element-generic — the recommendation)");
}
