#!/usr/bin/env dub
/+ dub.sdl:
    name "uom_quantity_polymorphism"
    dependency "sparkles:math" path="../../../.."
    dflags "-preview=in" "-preview=dip1000"
    targetPath "build"
+/
/**
 * Units of measure — dimensional polymorphism and the inference ceiling, over
 * `sparkles:math`'s `Vector`.
 *
 * A physically-based raytracer wants generic, dimension-correct geometry:
 * `dot` of two length-vectors is an *area*, `lengthSquared` is an area, a
 * `magnitude` is a length, and `normalize` yields a *dimensionless* direction.
 * D's IFTI (implicit function template instantiation) delivers this *forward*:
 * the result dimension is computed from the arguments' dimensions by the same
 * "checker evaluates" arithmetic every non-F# system in the survey uses. What D
 * (and every evaluator) cannot do is *invert* it — infer an argument dimension
 * from a desired result type. There are no principal types here; see
 * theory/type-system-mechanisms.md § "evaluators vs solvers" and
 * theory/kennedy-types.md.
 *
 * Composition finding: `sparkles:math.Vector` composes for `dot` (ordering A —
 * `Quantity!(dim, Vec3)`), but its `dot` is dimension-blind (`cast(CommonType)`),
 * and it ships no 3-D `cross`, `magnitude`, or `normalize` at all — a raytracer
 * needs them, and they must be dimension-aware. This prototype wraps the numeric
 * `Vector.dot` to restore the dimension, and implements `cross`/`magnitude`/
 * `normalize` locally: concrete input for the `sparkles:math` co-design (see
 * quantity-vector-composition.d).
 *
 * Companion to docs/research/units-of-measure/theory/type-system-mechanisms.md.
 *
 * Run with: `dub run --single quantity-polymorphism.d`
 */
module uom_quantity_polymorphism;

import sparkles.math.vector : Vector;
import std.traits : Unqual;

/// The raytracer's numeric payload for a 3-vector quantity.
alias Vec3 = Vector!(double, 3);

/// A dimension: an exponent vector in the free abelian group `ℤ³` over
/// (mass, length, time), stored as its unique normal form.
struct Dim
{
    int mass;
    int length;
    int time;
}

/// The group operation: `sign = +1` multiplies dimensions, `-1` divides.
Dim combine(in Dim a, in Dim b, in int sign) @safe pure nothrow @nogc
in (sign == 1 || sign == -1)
{
    return Dim(
        mass: a.mass + sign * b.mass,
        length: a.length + sign * b.length,
        time: a.time + sign * b.time,
    );
}

/// CTFE unit label for an exponent vector (only ever evaluated at compile time).
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

/// A graded quantity: a `Payload` (`double`, or `Vec3` for a dimensioned vector)
/// tagged with its dimension (composition ordering A).
struct Quantity(Dim dim, Payload = double)
{
    Payload value;

    enum string symbol = unitString(dim);

    /// `+`/`-` within one grade.
    Quantity opBinary(string op)(in Quantity rhs) const
    if (op == "+" || op == "-")
        => Quantity(mixin("value " ~ op ~ " rhs.value"));

    /// `*`/`/` between quantities: dimensions combine, payloads multiply (at least
    /// one side scalar; two vectors are `dot`/`cross`-ed, never `*`-ed).
    auto opBinary(string op, Dim rhsDim, RP)(in Quantity!(rhsDim, RP) rhs) const
    if (op == "*" || op == "/")
    {
        auto p = mixin("value " ~ op ~ " rhs.value");
        return Quantity!(combine(dim, rhsDim, op == "*" ? 1 : -1), Unqual!(typeof(p)))(p);
    }

    /// Scale by a plain dimensionless scalar, keeping the dimension.
    auto opBinary(string op)(in double s) const
    if (op == "*" || op == "/")
    {
        auto p = mixin("value " ~ op ~ " s");
        return Quantity!(dim, Unqual!(typeof(p)))(p);
    }

    /// Render through an `appender` (see quantity-affine-torsor.d for why).
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
enum Dim timeDim = Dim(time: 1);

alias Length = Quantity!(lengthDim, double);
alias Displacement = Quantity!(lengthDim, Vec3);
alias Direction = Quantity!(Dim(), Vec3);

// --- Dimension-polymorphic geometry (generic over the dimension via IFTI) -----

/// `sqr` on a scalar quantity: `Quantity!(d)` → `Quantity!(2·d)`. Forward
/// inference computes the result grade from the argument's — the `sqr` litmus.
auto sqr(Q)(in Q q) => q * q;

/// Dimension-aware dot product: `dot(Quantity!(a,Vec3), Quantity!(b,Vec3))` is a
/// scalar `Quantity!(a·b)`. `dot(length, length) = area`. This *restores* the
/// dimension that `Vector.dot` (dimension-blind `cast(CommonType)`) discards.
auto dot(Dim a, Dim b)(in Quantity!(a, Vec3) x, in Quantity!(b, Vec3) y)
    => Quantity!(combine(a, b, 1), double)(x.value.dot(y.value));

/// Squared length: `dot` with self. `lengthSquared(length-vec) = area`.
auto lengthSquared(Dim a)(in Quantity!(a, Vec3) x) => dot(x, x);

/// Magnitude: `|v| = sqrt(Σ vᵢ²)` has the *same* dimension as the components
/// (`sqrt` of an area grade back to length). Dimension-aware.
auto magnitude(Dim a)(in Quantity!(a, Vec3) x)
{
    import std.math : sqrt;
    return Quantity!(a, double)(sqrt(x.value.dot(x.value)));
}

/// 3-D cross product — **absent from `sparkles:math.Vector`**, implemented here.
/// Dimension-aware: `cross(length, length)` is an area-normal.
Vec3 cross3(in Vec3 a, in Vec3 b) @safe pure nothrow @nogc
    => Vec3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    );

/// ditto (dimensioned wrapper).
auto cross(Dim a, Dim b)(in Quantity!(a, Vec3) x, in Quantity!(b, Vec3) y)
    => Quantity!(combine(a, b, 1), Vec3)(cross3(x.value, y.value));

/// Normalize a dimensioned vector to a dimensionless unit `Direction`.
Direction normalize(Dim a)(in Quantity!(a, Vec3) x)
    => Direction(x.value / magnitude(x).value);

@("Quantity.polymorphism.dimension-aware-geometry")
@safe pure nothrow @nogc
unittest
{
    auto edge1 = Displacement(Vec3(2, 0, 0)); // metres
    auto edge2 = Displacement(Vec3(0, 3, 0)); // metres

    // dot / lengthSquared of length-vectors are AREAS.
    auto a = dot(edge1, edge2);
    static assert(is(typeof(a) == Quantity!(Dim(length: 2), double)));
    assert(a.value == 0);

    auto l2 = lengthSquared(edge1);
    static assert(is(typeof(l2) == Quantity!(Dim(length: 2), double)));
    assert(l2.value == 4);

    // magnitude is a length again; normalize is dimensionless.
    auto m = magnitude(edge1);
    static assert(is(typeof(m) == Length));
    assert(m.value == 2);
    static assert(is(typeof(normalize(edge1)) == Direction));

    // cross of two length-vectors is an area-normal.
    auto n = cross(edge1, edge2);
    static assert(is(typeof(n) == Quantity!(Dim(length: 2), Vec3)));
    assert(n.value == Vec3(0, 0, 6));

    // sqr forward-infers the doubled grade.
    static assert(is(typeof(sqr(Length(3.0))) == Quantity!(Dim(length: 2), double)));

    // Polymorphism does not loosen the within-grade rule: adding a length to an
    // area still does not compile.
    static assert(!__traits(compiles, Length(1.0) + lengthSquared(edge1)));
}

void main() @safe
{
    import std.stdio : writeln;

    // A triangle's two edges (metres): dot, cross (normal), and areas.
    auto e1 = Displacement(Vec3(4, 0, 0));
    auto e2 = Displacement(Vec3(0, 3, 0));

    auto area2 = lengthSquared(e1);         // m^2
    auto normal = cross(e1, e2);            // m^2, an area-vector
    auto unit = normalize(normal);          // dimensionless direction
    auto speed = Length(6.0) / timeQty(2.0); // m / s : a velocity scalar

    // FORWARD inference works, and composes through a chain: each grade below is
    // computed by IFTI from the arguments, never annotated.
    auto chained = normalize(cross(e1, e2)); // (m·m)-vec -> dimensionless dir
    static assert(is(typeof(chained) == Direction));

    // The CEILING: D dispatches on argument types, never on the *result* type, so
    // there is no inverse of `sqr`. `magnitude` maps grade `a` -> `a`; `sqr` maps
    // `a` -> `2a`; but no generic function can be *asked* for "the grade whose
    // square is an area" — the target grade must be given at the call site, not
    // inferred from a desired return type. That return-type inference is exactly
    // Kennedy's AG-unification; an evaluator like D (and every non-F# system in
    // the survey) confirms spelled-out grades, it does not solve for them.

    writeln("edge1            = ", e1);
    writeln("|edge1|²         = ", area2);
    writeln("cross(e1,e2)     = ", normal, "  (area-normal; Vector has no cross — local impl)");
    writeln("normalize(normal)= ", unit);
    writeln("6 m / 2 s        = ", speed);
    writeln("dot(e1,e2)       = ", dot(e1, e2), "  (dimension-aware; Vector.dot alone loses the m²)");
}

/// Small helper: a scalar time quantity (keeps `main` readable).
Quantity!(timeDim, double) timeQty(in double s) @safe pure nothrow @nogc
    => Quantity!(timeDim, double)(s);
