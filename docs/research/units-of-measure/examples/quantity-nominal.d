#!/usr/bin/env dub
/+ dub.sdl:
    name "uom_quantity_nominal"
    dependency "sparkles:math" path="../../../.."
    dflags "-preview=in" "-preview=dip1000"
    targetPath "build"
+/
/**
 * Units of measure — the *nominal* fork of the kind system: one distinct struct
 * per quantity, with NO shared exponent algebra, as a raytracer would meet it.
 *
 * The graded prototypes (`quantity-zn-graded.d`, `quantity-affine-torsor.d`)
 * make a quantity's identity its exponent vector in `ℤⁿ`, so `*`/`/` are *total*
 * and every product has a type computed by the group operation. This file takes
 * the opposite design-space point — the one [squants][squants] (Scala) and
 * [Swift Foundation `Measurement`][swift] occupy. Here each physical quantity is
 * its own hand-written struct — `struct Irradiance { double w_m2; }`,
 * `struct Radiance { double w_m2_sr; }`, `struct Position { Vec3 m; }` — and there
 * is no exponent group at all. Products and quotients are not derived: each legal
 * one is a *hand-wired* `opBinary` (`Radiance * SolidAngle → Irradiance`,
 * `Irradiance * Area → Power`, `Position - Position → Displacement`).
 *
 * The fork's upside is *kind for free*: because typing is nominal, `Radiance` and
 * `Irradiance` — or `Torque` and `Energy`, both dimensionally `N·m` — are simply
 * unrelated types, so `radiance + irradiance` and `torque + energy` do not compile
 * with no kind machinery written at all. This is exactly the distinction the
 * graded systems *cannot* make: to them `W·m⁻²·sr⁻¹ · sr` and `W·m⁻²` are the same
 * exponent vector.
 *
 * The cost is the Swift dead-end: an *undeclared* product has no type. Nothing
 * derives `Position * Position` — `!__traits(compiles, pos * pos)` unless you sit
 * down and hand-declare that struct and its `opBinary`. The combinatorial closure
 * the group gives you for free must be enumerated by hand, edge by edge.
 *
 * **Composition finding.** Nominal typing composes *poorly* with a generic vector.
 * A graded design reuses one template — `Quantity!(dim, Vec3)` — for every
 * vector-valued quantity (`Displacement`, `Direction`, a force field…), the
 * dimension riding along as a type parameter. The nominal fork *cannot*: with no
 * `dim` to parameterize on, each vector quantity must be its own bespoke struct
 * wrapping `Vec3` (`Position`, `Displacement`, … each re-declared, each re-wiring
 * `toString` and its own operators). So `sparkles:math`'s `Vector` is still used
 * as the payload (composition *ordering A*, dimension-wraps-vector), but the reuse
 * is per-struct boilerplate rather than one instantiation — the nominal fork
 * multiplies the surface that would compose with `Vector`, instead of factoring it.
 *
 * Companion to docs/research/units-of-measure/scala-squants.md and
 * docs/research/units-of-measure/swift-units.md (the two nominal data points),
 * and docs/research/units-of-measure/comparison.md § "Kinds: the shared blind
 * spot" (nominal typing as the counter-example to the graded-group hypothesis).
 *
 * Run with: `dub run --single quantity-nominal.d`
 */
module uom_quantity_nominal;

import sparkles.math.vector : Vector;

/// The raytracer's numeric payload for a 3-vector quantity.
alias Vec3 = Vector!(double, 3);

// ─── Scalar radiometric quantities ───────────────────────────────────────────
//
// Each is a DISTINCT struct. There is no exponent vector anywhere: `Radiance`
// does not "know" it is `W·m⁻²·sr⁻¹`; that fact lives only in the hand-wired
// products below and in the human-readable `unit` label.

/// Radiant power, in watts (W). The energy flux leaving a source per second.
struct Power
{
    double w;
    enum unit = "W";
    string toString() const @safe => scalarLabel(w, unit);
}

/// Projected solid angle, in steradians (sr). Dimensionless in SI, but a
/// *distinct nominal type* here — that is the whole point.
struct SolidAngle
{
    double sr;
    enum unit = "sr";
    string toString() const @safe => scalarLabel(sr, unit);
}

/// Area, in square metres (m²) — e.g. a differential surface patch `dA`.
struct Area
{
    double m2;
    enum unit = "m^2";
    string toString() const @safe => scalarLabel(m2, unit);
}

/// Irradiance, in W·m⁻²: power arriving per unit area on a surface.
struct Irradiance
{
    double w_m2;
    enum unit = "W m^-2";
    string toString() const @safe => scalarLabel(w_m2, unit);

    /// HAND-WIRED: `Irradiance * Area → Power` (W·m⁻² · m² = W). The group would
    /// *derive* this; nominally we enumerate it.
    Power opBinary(string op : "*")(in Area a) const @safe pure nothrow @nogc
        => Power(w_m2 * a.m2);
}

/// Radiance, in W·m⁻²·sr⁻¹: the raytracer's central quantity — power per unit
/// projected area per unit solid angle, carried along a ray.
struct Radiance
{
    double w_m2_sr;
    enum unit = "W m^-2 sr^-1";
    string toString() const @safe => scalarLabel(w_m2_sr, unit);

    /// HAND-WIRED: `Radiance * SolidAngle → Irradiance` (W·m⁻²·sr⁻¹ · sr =
    /// W·m⁻²) — integrating radiance over a cone of directions. The canonical
    /// nominal edge: the sr cancels only because *we said so* on this line.
    Irradiance opBinary(string op : "*")(in SolidAngle s) const @safe pure nothrow @nogc
        => Irradiance(w_m2_sr * s.sr);
}

// ─── The kind-for-free pair: Torque vs Energy ────────────────────────────────
//
// Both are dimensionally N·m = kg·m²·s⁻². A graded system gives them the SAME
// type and so type-checks `torque + energy`. Nominal typing makes them unrelated
// structs — the distinction the survey calls "kind" — for free, no tags written.

/// Torque (moment of force), in N·m. Dimensionally identical to `Energy`.
struct Torque
{
    double n_m;
    enum unit = "N m";
    string toString() const @safe => scalarLabel(n_m, unit);
}

/// Energy / work, in joules (J = N·m). Dimensionally identical to `Torque`,
/// but a *distinct nominal type* — so `torque + energy` cannot compile.
struct Energy
{
    double j;
    enum unit = "J";
    string toString() const @safe => scalarLabel(j, unit);
}

// ─── Vector-valued quantities: the composition finding, made concrete ─────────
//
// Position and Displacement BOTH wrap a `Vec3` of metres, yet — with no `dim` to
// parameterize on — each must be its own struct. There is no single
// `Quantity!(lengthDim, Vec3)` serving both, as in quantity-affine-torsor.d.
// This bespoke-per-quantity duplication IS the poor `Vector` reuse.

/// An affine world position, in metres. A distinct nominal type from
/// `Displacement`, even though both are just a `Vec3` of metres.
struct Position
{
    Vec3 m;
    string toString() const @safe => vecLabel(m, "m (pos)");

    /// HAND-WIRED: `Position - Position → Displacement`. Subtraction of two
    /// positions is the only affine combination that has a declared type.
    Displacement opBinary(string op : "-")(in Position rhs) const @safe pure nothrow @nogc
        => Displacement(m - rhs.m);

    /// HAND-WIRED: `Position + Displacement → Position` — offset a point.
    Position opBinary(string op : "+")(in Displacement d) const @safe pure nothrow @nogc
        => Position(m + d.m);
}

/// A free length-vector (the difference of two positions), in metres. A distinct
/// nominal struct wrapping the *same* `Vec3` payload as `Position` — the
/// duplication the composition finding is about.
struct Displacement
{
    Vec3 m;
    string toString() const @safe => vecLabel(m, "m (disp)");
}

// ─── Shared rendering helpers (CTFE-friendly, run at runtime here) ────────────

/// Render a scalar quantity as `value unit`.
private string scalarLabel(in double v, in string unit) @safe
{
    import std.array : appender;
    import std.format : formattedWrite;

    auto sink = appender!string();
    formattedWrite(sink, "%.6g %s", v, unit);
    return sink[];
}

/// Render a `Vec3`-valued quantity through an `appender` sink — never `writeln`
/// or `format(vec)` directly, whose `LockingTextWriter` fails `Vector.toString`'s
/// `scope` analysis under `-preview=dip1000`.
private string vecLabel(in Vec3 v, in string unit) @safe
{
    import std.array : appender;

    auto sink = appender!string();
    v.toString(sink);
    sink.put(" ");
    sink.put(unit);
    return sink[];
}

@("Quantity.nominal.hand-wired-products-and-kind-for-free")
@safe pure nothrow @nogc
unittest
{
    // Hand-wired radiometric edges resolve to their declared nominal types.
    auto radiance = Radiance(100.0);
    auto cone = SolidAngle(0.5);
    auto e = radiance * cone;
    static assert(is(typeof(e) == Irradiance),
        "Radiance * SolidAngle must be Irradiance");
    assert(e.w_m2 == 50.0);

    auto received = e * Area(2.0);
    static assert(is(typeof(received) == Power),
        "Irradiance * Area must be Power");
    assert(received.w == 100.0);

    // Kind for free: Radiance and Irradiance are unrelated, so no `+`.
    static assert(!__traits(compiles, radiance + e),
        "radiance + irradiance must not compile (distinct nominal kinds)");

    // Torque vs Energy — dimensionally both N·m, nominally distinct.
    static assert(!__traits(compiles, Torque(3.0) + Energy(3.0)),
        "torque + energy must not compile (distinct nominal kinds)");

    // Affine geometry: the two hand-wired edges exist...
    auto a = Position(Vec3(0, 0, 0));
    auto b = Position(Vec3(3, 4, 0));
    auto d = b - a;
    static assert(is(typeof(d) == Displacement));
    assert(d.m == Vec3(3, 4, 0));
    static assert(is(typeof(a + d) == Position));

    // ...but the UNDECLARED product has no type (the Swift dead-end).
    static assert(!__traits(compiles, a * b),
        "Position * Position is undeclared — nominally it has no type at all");
}

void main() @safe
{
    import std.stdio : writeln;

    // A hand-enumerated radiometric chain: radiance → irradiance → power.
    const radiance = Radiance(120.0);        // W·m⁻²·sr⁻¹ along a ray
    const cone = SolidAngle(0.25);           // sr subtended by the light
    const patch = Area(2.0);                 // m² of receiving surface

    const irradiance = radiance * cone;      // hand-wired: sr cancels
    const power = irradiance * patch;        // hand-wired: m² cancels

    writeln("radiance         = ", radiance);
    writeln("solid angle      = ", cone);
    writeln("irradiance       = ", irradiance, "  (Radiance * SolidAngle)");
    writeln("area             = ", patch);
    writeln("power on patch   = ", power, "  (Irradiance * Area)");

    // Kind for free — these hold precisely because the additions do NOT compile.
    static assert(!__traits(compiles, radiance + irradiance),
        "Radiance + Irradiance must not compile");
    static assert(!__traits(compiles, Torque(1.0) + Energy(1.0)),
        "Torque + Energy must not compile — kind distinction is free here");
    writeln("kind for free    : Radiance+Irradiance and Torque+Energy both rejected");

    // Affine geometry over a bespoke Vec3-wrapping struct pair.
    const eye = Position(Vec3(0, 1, 4));
    const target = Position(Vec3(0, 0, 0));
    auto look = target - eye;                // hand-wired: Position - Position
    static assert(is(typeof(look) == Displacement));

    writeln("eye              = ", eye);
    writeln("target           = ", target);
    writeln("look (t - e)     = ", look, "  (Position - Position)");

    // The Swift dead-end: an undeclared product simply has no type.
    static assert(!__traits(compiles, eye * target),
        "Position * Position is undeclared — nominally unnameable");
    writeln("dead-end         : Position * Position has no type (undeclared product)");
}
