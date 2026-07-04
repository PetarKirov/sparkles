#!/usr/bin/env dub
/+ dub.sdl:
    name "uom_quantity_open_basis"
    targetPath "build"
+/
/**
 * Units of measure — an OPEN-basis `Quantity` over a user-extensible generator set.
 *
 * The `ℤⁿ`-graded prototype (`quantity-zn-graded.d`) fixes the basis: a dimension
 * is a 3-slot `struct Dim { int mass, length, time; }`, so the group `ℤ³` — and its
 * generators — are baked into the core. This prototype takes the *open* stance: a
 * dimension is a CTFE-normalized array of `(name, exp)` pairs — `Gen[]` — over an
 * unbounded tag set. Normal form is "sorted by name, zero exponents dropped, equal
 * names merged", so `[Gen("m", -2), Gen("W", 1)]` and `[Gen("W", 1), Gen("m", -2)]`
 * are the *same* type. A user mints a brand-new base dimension — `"sr"` (steradian),
 * `"W"` (watt), or a bespoke `"sample"` axis for a Monte-Carlo path tracer — just by
 * naming it, with no edit to a closed `ℤⁿ` core. `combine` is a CTFE merge of two
 * `(name, exp)` lists (the group op and its inverse); `+`/`-` live within one grade,
 * `*`/`/` are total. Radiance `W m^-2 sr^-1` and a `sample`-carrying estimator
 * coexist, while `static assert(!__traits(compiles, radiance + irradiance))` turns
 * the intended cross-grade rejection into a checked, passing part of the program.
 *
 * The trade against the closed basis: the open form pays a small CTFE-normalization
 * and array-comparison cost per instantiation and loses the `int[3]` layout guarantee,
 * but never needs a central registry edit and composes new axes freely — the
 * "registry vs closed generator set" axis of the comparison matrix.
 *
 * Companion to docs/research/units-of-measure/cpp-au.md (Au's fixed `Dimension` pack)
 * and docs/research/units-of-measure/cpp-mp-units.md (mp-units' extensible base-quantity
 * system); the "closed vs open basis" comparison axis.
 *
 * Composition: scalar here, but the same open `Gen[]` dimension would wrap a
 * `sparkles:math` `Vector!(double, N)` in composition *ordering A* —
 * `Quantity!(dims, Vec3)`, the dimension outside the vector — exactly as
 * `quantity-affine-torsor.d` wraps a fixed `ℤ³` `Dim`; the basis being open changes
 * nothing about how the payload nests.
 *
 * Run with: `dub run --single quantity-open-basis.d`
 */
module uom_quantity_open_basis;

/// One generator of the open dimension algebra: a base-dimension tag raised to an
/// integer power. The tag set is unbounded — any `string` names a fresh axis.
struct Gen
{
    string name;
    int exp;
}

/// Reduce a list of generators to its unique normal form: merge equal names,
/// drop zero exponents, sort by name. Two dimensions are the *same type* iff their
/// normal forms are equal arrays. GC-allocating, but only ever evaluated at CTFE.
Gen[] normalize(in Gen[] gens) @safe pure
{
    import std.algorithm : sort;

    Gen[] merged;
    outer: foreach (g; gens)
    {
        if (g.exp == 0)
            continue;
        foreach (ref m; merged)
            if (m.name == g.name)
            {
                m.exp += g.exp;
                continue outer;
            }
        merged ~= Gen(g.name, g.exp);
    }

    Gen[] result;
    foreach (m; merged)
        if (m.exp != 0)
            result ~= m;

    result.sort!((a, b) => a.name < b.name);
    return result;
}

/// The group operation on open dimensions: append `b` (with each exponent scaled by
/// `sign`) to `a` and re-normalize. `sign = +1` is quantity multiplication (join),
/// `sign = -1` is division (the group inverse). A CTFE merge of two `(name, exp)` lists.
Gen[] combine(in Gen[] a, in Gen[] b, in int sign) @safe pure
in (sign == 1 || sign == -1)
{
    Gen[] all = a.dup;
    foreach (g; b)
        all ~= Gen(g.name, sign * g.exp);
    return normalize(all);
}

/// A convenience for a single base dimension, e.g. `base("W")` is the watt axis.
Gen[] base(in string name) @safe pure => normalize([Gen(name, 1)]);

/// CTFE unit label for a normalized generator list, e.g. `"W m^-2 sr^-1"`; the
/// identity (empty list) renders as `"(dimensionless)"`. Only ever run at CTFE.
string unitString(in Gen[] dims) @safe pure
{
    import std.conv : to;

    if (dims.length == 0)
        return "(dimensionless)";

    string result;
    foreach (g; dims)
    {
        if (result.length > 0)
            result ~= ' ';
        result ~= g.name;
        if (g.exp != 1)
            result ~= "^" ~ g.exp.to!string;
    }
    return result;
}

/// A quantity graded by an *open* dimension: one bare `double` tagged with its
/// normalized `Gen[]`. `+`/`-` exist only within a single grade (identical normal
/// form); `*`/`/` are total and `combine` the generator lists.
struct Quantity(Gen[] dims)
{
    double value;

    /// Compile-time unit label of this grade (used by `toString`).
    enum string symbol = unitString(dims);

    /// Compile-time access to the grade's normal form.
    enum Gen[] dimension = dims;

    /// `+`/`-` exist only within a single grade: both operands share `dims`, so a
    /// cross-grade `rhs` simply fails to match this overload (and nothing else adds).
    Quantity opBinary(string op)(in Quantity rhs) const
    if (op == "+" || op == "-")
        => Quantity(mixin("value " ~ op ~ " rhs.value"));

    /// `*`/`/` are total: the result grade merges the two generator lists.
    auto opBinary(string op, Gen[] rhsDims)(in Quantity!rhsDims rhs) const
    if (op == "*" || op == "/")
        => Quantity!(combine(dims, rhsDims, op == "*" ? 1 : -1))(
            mixin("value " ~ op ~ " rhs.value"));

    string toString() const
    {
        import std.format : format;
        return format!"%.6g %s"(value, symbol);
    }
}

// Base axes minted by name — no closed core to edit. `"sr"` and `"sample"` are just
// as first-class as `"m"`; the algebra never knew they existed until now.
enum Gen[] powerDim = base("W");
enum Gen[] lengthDim = base("m");
enum Gen[] areaDim = combine(lengthDim, lengthDim, 1);      // m^2
enum Gen[] solidAngleDim = base("sr");
enum Gen[] sampleDim = base("sample");                      // a bespoke Monte-Carlo axis

/// Radiance `W m^-2 sr^-1` — the raytracer's central radiometric quantity.
enum Gen[] radianceDim = combine(combine(powerDim, areaDim, -1), solidAngleDim, -1);
/// Irradiance `W m^-2` — flux per area, with the solid-angle axis absent.
enum Gen[] irradianceDim = combine(powerDim, areaDim, -1);

alias Power = Quantity!powerDim;
alias Area = Quantity!areaDim;
alias SolidAngle = Quantity!solidAngleDim;
alias Radiance = Quantity!radianceDim;
alias Irradiance = Quantity!irradianceDim;
alias SampleCount = Quantity!sampleDim;

@("Quantity.open-basis.normal-form-is-order-independent")
@safe pure nothrow @nogc
unittest
{
    // Radiance assembled as (W / m^2) / sr equals the hand-written normal form,
    // regardless of the order the generators were introduced.
    auto radiance = Power(40.0) / Area(2.0) / SolidAngle(4.0);
    static assert(is(typeof(radiance) == Radiance));
    assert(radiance.value == 5.0);

    // `[W, m^-2, sr^-1]` and a shuffled build order normalize to the same type.
    static assert(is(Quantity!(normalize([Gen("sr", -1), Gen("W", 1), Gen("m", -2)]))
            == Radiance));
}

void main() @safe
{
    import std.stdio : writeln;

    auto power = Power(60.0);            // 60 W
    auto area = Area(3.0);              // 3 m^2
    auto solidAngle = SolidAngle(2.0);  // 2 sr

    // Radiance = power / area / solid-angle: the generator lists merge to
    // W · m^-2 · sr^-1 — a brand-new base dimension "sr" carried without any
    // edit to a closed core.
    auto radiance = power / area / solidAngle;
    static assert(is(typeof(radiance) == Radiance));

    // A bespoke "sample" axis coexists: a Monte-Carlo estimator that accumulates
    // radiance over N samples has grade W · m^-2 · sr^-1 · sample^-1.
    auto samples = SampleCount(16.0);
    auto perSample = radiance / samples;
    static assert(is(typeof(perSample)
            == Quantity!(normalize([Gen("W", 1), Gen("m", -2), Gen("sr", -1), Gen("sample", -1)]))));

    // Within one grade, addition is defined ...
    static assert(__traits(compiles, radiance + radiance));

    // ... but adding across grades is REJECTED at compile time. These asserts hold
    // (and the program compiles) precisely because the additions do not: radiance
    // and irradiance differ only by the "sr" axis, yet remain incompatible.
    auto irradiance = power / area;
    static assert(is(typeof(irradiance) == Irradiance));
    static assert(!__traits(compiles, radiance + irradiance),
        "radiance (W m^-2 sr^-1) and irradiance (W m^-2) must not be addable");
    static assert(!__traits(compiles, radiance + perSample),
        "a sample-carrying estimator is a distinct grade from radiance");

    // Round trip through the group: re-multiplying by the same grades cancels the
    // generators exactly, back to a bare power.
    static assert(is(typeof(radiance * solidAngle * area) == Power));

    writeln("power            = ", power);
    writeln("area             = ", area);
    writeln("solidAngle       = ", solidAngle);
    writeln("radiance         = ", radiance);
    writeln("irradiance       = ", irradiance);
    writeln("radiance/sample  = ", perSample);
    writeln("radiance*sr*area = ", radiance * solidAngle * area, " (back to the grade of power)");
}
