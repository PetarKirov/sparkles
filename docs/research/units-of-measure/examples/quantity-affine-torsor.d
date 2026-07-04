#!/usr/bin/env dub
/+ dub.sdl:
    name "uom_quantity_affine_torsor"
    dependency "sparkles:math" path="../../../.."
    dflags "-preview=in" "-preview=dip1000"
    targetPath "build"
+/
/**
 * Units of measure — affine quantities (points vs vectors) as a raytracer spine,
 * composed with `sparkles:math`'s `Vector`.
 *
 * A physically-based raytracer's core geometry is an *affine* space. A world
 * `Point3` (a position, in metres) is not a `Displacement` (a free length-vector),
 * and neither is a `Direction` (a dimensionless unit vector). The torsor algebra
 * `Point − Point = Displacement`, `Point + Displacement = Point` — with
 * `Point + Point` and `scalar · Point` rejected at compile time — is exactly what
 * stops the position/displacement confusion that plagues vector-only ray code.
 * A `Ray` is then `origin + dir * t`, where the distance `t` is a `Length`.
 *
 * Dimensions live in the type as a `ℤ³` exponent vector; the numeric payload is a
 * `Vec3 = Vector!(double, 3)` from `sparkles:math`. This is composition *ordering
 * A* — `Quantity!(dim, Vec3)`, the dimension wrapping the vector — which works with
 * the current `Vector` unchanged. See `quantity-vector-composition.d` for why the
 * other ordering, `Vector!(Quantity, N)`, does not compile today, and the
 * linear-algebra co-design that would enable it.
 *
 * Companion to docs/research/units-of-measure/theory/torsor-representation.md
 * and docs/research/units-of-measure/swift-units.md (the affine-at-conversion
 * pitfall); the affine `Point`/`Vec` split is also proposed for `sparkles:math`.
 *
 * Run with: `dub run --single quantity-affine-torsor.d`
 */
module uom_quantity_affine_torsor;

import sparkles.math.vector : Vector;
import std.traits : Unqual;

/// The raytracer's numeric payload for a 3-vector quantity.
alias Vec3 = Vector!(double, 3);

/// A dimension: an exponent vector in the free abelian group `ℤ³` over
/// (mass, length, time), stored directly as its unique-normal-form vector.
struct Dim
{
    int mass;
    int length;
    int time;
}

/// The group operation, component-wise: `sign = +1` for multiplication (join of
/// dimensions), `sign = -1` for division (the group inverse).
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

/// A graded quantity: a `Payload` (a scalar `double`, or a `Vec3` for a
/// *dimensioned vector*) tagged with its dimension. `Payload` defaults to
/// `double`. Wrapping a `Vec3` is composition ordering A.
struct Quantity(Dim dim, Payload = double)
{
    Payload value;

    /// Compile-time unit label of this grade (used by `toString`).
    enum string symbol = unitString(dim);

    /// `+`/`-` exist only within one grade: identical dimension and payload type.
    Quantity opBinary(string op)(in Quantity rhs) const
    if (op == "+" || op == "-")
        => Quantity(mixin("value " ~ op ~ " rhs.value"));

    /// `*`/`/` between quantities: dimensions combine and payloads multiply. The
    /// payload product is defined when at least one side is scalar — two vectors
    /// are dotted or crossed, never `*`-ed component-wise (see the polymorphism
    /// prototype). So `dir * t` (dimensionless `Vec3` · `Length`) is a length
    /// `Displacement`, exactly the ray-marching step.
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

    /// Render as `value symbol`. A `Vec3` payload is rendered through an
    /// `appender` (not `writeln`'s `LockingTextWriter`): `sparkles:math`'s
    /// `Vector.toString` takes a `scope` writer whose escape analysis only
    /// admits a non-escaping sink — a small composition wrinkle worth noting.
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

/// A scalar distance, in metres.
alias Length = Quantity!(lengthDim, double);

/// A free length-vector: the difference between two positions.
alias Displacement = Quantity!(lengthDim, Vec3);

/// A dimensionless (unit) direction.
alias Direction = Quantity!(Dim(), Vec3);

/// An affine world position in metres. It carries the same `Vec3` as a
/// `Displacement`, but is a *distinct* type: you cannot add two positions or
/// scale one — only subtract them, or offset one by a `Displacement`.
struct Point3
{
    Vec3 coords;

    /// `Point − Point = Displacement`; `Point ± Displacement = Point`. Any other
    /// combination (notably `Point + Point`) fails to compile.
    auto opBinary(string op, R)(in R rhs) const @safe pure nothrow @nogc
    if (op == "+" || op == "-")
    {
        static if (is(R == Point3))
        {
            static assert(op == "-",
                "two positions cannot be added — only subtracted to a Displacement");
            return Displacement(coords - rhs.coords);
        }
        else static if (is(R == Displacement))
            return Point3(mixin("coords " ~ op ~ " rhs.value"));
        else
            static assert(0,
                "Point3 " ~ op ~ " " ~ R.stringof ~ " is not an affine operation");
    }

    /// Render as `P(x: …, y: …, z: …) m` via the payload's writer `toString`.
    string toString() const @safe
    {
        import std.array : appender;

        auto sink = appender!string();
        sink.put("P");
        coords.toString(sink);
        sink.put(" m");
        return sink[];
    }
}

/// A ray: an origin position and a (dimensionless) direction. `at(t)` marches a
/// `Length` along the direction — `origin + dir * t`.
struct Ray
{
    Point3 origin;
    Direction dir;

    Point3 at(in Length t) const @safe pure nothrow @nogc
        => origin + dir * t;
}

@("Quantity.affine.ray-marching-and-torsor-algebra")
@safe pure nothrow @nogc
unittest
{
    const a = Point3(Vec3(0, 0, 0));
    const b = Point3(Vec3(3, 4, 0));

    // Point − Point is a length Displacement (a free vector).
    auto d = b - a;
    static assert(is(typeof(d) == Displacement));
    assert(d.value == Vec3(3, 4, 0));

    // Point + Displacement is a Point again.
    static assert(is(typeof(a + d) == Point3));
    assert((a + d).coords == b.coords);

    // dir * t : dimensionless direction times a Length is a length Displacement.
    const r = Ray(a, Direction(Vec3(1, 0, 0)));
    auto hit = r.at(Length(5.0));
    static assert(is(typeof(hit) == Point3));
    assert(hit.coords == Vec3(5, 0, 0));
}

void main() @safe
{
    import std.stdio : writeln;

    const eye = Point3(Vec3(0, 1, 4));      // camera position (m)
    const target = Point3(Vec3(0, 0, 0));   // look-at point (m)

    // The un-normalized look vector is a length Displacement...
    auto look = target - eye;
    static assert(is(typeof(look) == Displacement));

    // ...and a Ray marches a Length along a direction.
    const forward = Direction(Vec3(0, 0, -1));
    const ray = Ray(eye, forward);
    const p = ray.at(Length(4.0));

    // Affine misuse is rejected at compile time — these asserts hold precisely
    // because the operations do NOT compile.
    static assert(!__traits(compiles, eye + target),
        "two positions must not be addable");
    static assert(!__traits(compiles, 2.0 * eye),
        "a position must not be scalable");
    static assert(__traits(compiles, eye - target)); // ...but subtraction is fine.

    writeln("eye        = ", eye);
    writeln("target     = ", target);
    writeln("look (t-e) = ", look);
    writeln("ray.at(4m) = ", p);
    writeln("|look|²    = ", look.value.dot(look.value), " m^2 (dot of two length-vectors)");
}
