#!/usr/bin/env dub
/+ dub.sdl:
    name "uom_quantity_kind_tags"
    targetPath "build"
+/
/**
 * Units of measure — flat *kind tags* on top of a `ℤⁿ`-graded `Quantity`
 * (open decision #3a), motivated by a physically-based raytracer.
 *
 * Dimensional analysis alone cannot tell apart every physically-distinct
 * quantity: a raytracer's `Frequency` and a detector's `Radioactivity` are both
 * `s⁻¹`, a `SolidAngle` and a plain reflectance `Ratio` are both dimensionless,
 * yet adding or comparing across them is a bug. `uom`'s answer — the design point
 * this file prototypes — is a second, orthogonal label on the type: a flat
 * `enum` *kind* tag. `Quantity!(dim, kind, Payload = double)` makes *same `dim` +
 * different `kind`* two **distinct** types; `+`/`-`/`==` demand identical `dim`
 * **and** `kind`. `static assert(!__traits(compiles, hz + bq))` and
 * `!__traits(compiles, angle == ratio)` turn those intended rejections into
 * checked, passing parts of the program.
 *
 * This prototype tracks steradian (`sr`) as a base dimension, so the radiometric
 * pair `Radiance` (`W·m⁻²·sr⁻¹`) and `Irradiance` (`W·m⁻²`) separate *by
 * dimension* — the job a kind tag is **not** needed for. The kinds earn their
 * keep on `Frequency`/`Bq` (identical `s⁻¹`) and `PlaneAngle`/`Ratio` (both
 * dimensionless), where no exponent vector can help.
 *
 * The **honest limit** (comparison.md's rung 3): flat kinds are comparability
 * tags, not an algebra — they are **erased under `×`/`÷`**. An `AngularVelocity`
 * (`s⁻¹`, kind `angle`) times a `Time` is dimensionless but comes back with the
 * *default* kind, not `angle`: the radian is silently dropped. This file
 * `static assert`s exactly that loss.
 *
 * Companion to docs/research/units-of-measure/comparison.md § 4 (Kinds) and
 * ./rust-uom.md (uom's `Kind` associated type — the flat-tag reference design).
 *
 * Composition: the `kind` tag is orthogonal to the numeric `Payload`, so it
 * rides equally on a scalar `Quantity!(dim, kind, double)` or, in composition
 * *ordering A*, on a vectorized `Quantity!(dim, kind, Vec3)` wrapping
 * `sparkles:math`'s `Vector` — a directional radiance carries both its `sr⁻¹`
 * dimension and its `radiance` kind while its payload is a 3-vector. This file
 * stays scalar (zero-dep) but keeps the `Payload` parameter to show the axis is
 * independent.
 *
 * Run with: `dub run --single quantity-kind-tags.d`
 */
module uom_quantity_kind_tags;

/// A flat quantity-*kind* tag: an orthogonal label distinguishing quantities
/// that share a dimension. `none` is the default kind a bare number carries and
/// the kind every `×`/`÷` product collapses to (the erasure limit below).
enum Kind
{
    none,
    angle,
    radioactivity,
}

/// A dimension: an exponent vector in the free abelian group `ℤ⁴` over the base
/// dimensions (mass, length, time, solid angle), stored as its normal form.
/// Steradian is a base dimension here, so radiometric quantities separate
/// dimensionally; the alternative (SI-faithful, `sr` dimensionless) pushes that
/// job onto the kind tag instead — see comparison.md § 4 rungs 2 vs 3.
struct Dim
{
    int mass;
    int length;
    int time;
    int solidAngle;
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
        solidAngle: a.solidAngle + sign * b.solidAngle,
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
    put("sr", d.solidAngle);
    return result.length > 0 ? result : "(dimensionless)";
}

/// CTFE label for a non-default kind, e.g. `" [angle]"`; empty for `Kind.none`.
string kindString(in Kind k) @safe pure nothrow
{
    final switch (k)
    {
    case Kind.none:
        return "";
    case Kind.angle:
        return " [angle]";
    case Kind.radioactivity:
        return " [radioactivity]";
    }
}

/// A kind-tagged graded quantity: a `Payload` (a scalar `double` here; a `Vec3`
/// under composition ordering A) tagged with **both** a dimension `dim` and a
/// flat `kind`. `dim` and `kind` are independent axes of identity.
struct Quantity(Dim dim, Kind kind = Kind.none, Payload = double)
{
    Payload value;

    /// Compile-time unit label of this grade (used by `toString`).
    enum string symbol = unitString(dim);

    /// This quantity's kind, exposed for external `static assert`s.
    enum Kind quantityKind = kind;

    /// `+`/`-` exist only within one identity: identical dimension **and** kind
    /// (i.e. the same `Quantity` instantiation). Differing kind ⇒ different type
    /// ⇒ this overload does not match ⇒ the addition is rejected.
    Quantity opBinary(string op)(in Quantity rhs) const
    if (op == "+" || op == "-")
        => Quantity(mixin("value " ~ op ~ " rhs.value"));

    /// Equality is defined only against the *same* type — same dimension and
    /// same kind. `angle == ratio` (kinds differ) therefore fails to compile.
    bool opEquals(in Quantity rhs) const
        => value == rhs.value;

    /// `×`/`÷` between quantities: dimensions combine, but the **kind is erased**
    /// to `Kind.none`. This is the flat-tag design's honest limit — kinds are
    /// comparability tags, not an algebra closed under multiplication.
    auto opBinary(string op, Dim rDim, Kind rKind, RP)(in Quantity!(rDim, rKind, RP) rhs) const
    if (op == "*" || op == "/")
    {
        import std.traits : Unqual;

        auto p = mixin("value " ~ op ~ " rhs.value");
        return Quantity!(combine(dim, rDim, op == "*" ? 1 : -1), Kind.none, Unqual!(typeof(p)))(p);
    }

    /// Scaling by a plain scalar **keeps** both dimension and kind — unlike a
    /// quantity product, a rescale of an angle is still an angle.
    auto opBinary(string op)(in double s) const
    if (op == "*" || op == "/")
    {
        import std.traits : Unqual;

        auto p = mixin("value " ~ op ~ " s");
        return Quantity!(dim, kind, Unqual!(typeof(p)))(p);
    }

    /// Render as `value symbol [kind]`, e.g. `3 s^-1 [radioactivity]`.
    string toString() const @safe
    {
        import std.array : appender;
        import std.format : formattedWrite;

        auto sink = appender!string();
        formattedWrite(sink, "%.6g %s%s", value, symbol, kindString(kind));
        return sink[];
    }
}

// --- The raytracer's radiometric vocabulary, plus the classic kind clashes. ---

/// Length in metres and its square, area (both plain, kind `none`).
alias Length = Quantity!(Dim(length: 1));
/// ditto
alias Area = Quantity!(Dim(length: 2));

/// A duration in seconds.
alias Time = Quantity!(Dim(time: 1));

/// Radiant power in watts, `W = kg·m²·s⁻³`.
alias Power = Quantity!(Dim(mass: 1, length: 2, time: -3));

/// Irradiance `W·m⁻²` and radiance `W·m⁻²·sr⁻¹`. They differ **by the `sr`
/// dimension**, so no kind tag is needed to separate them.
alias Irradiance = Quantity!(Dim(mass: 1, time: -3));
/// ditto
alias Radiance = Quantity!(Dim(mass: 1, time: -3, solidAngle: -1));

/// A solid angle in steradians — dimensioned here, and additionally kind `angle`.
alias SolidAngle = Quantity!(Dim(solidAngle: 1), Kind.angle);

/// Frequency and radioactivity are **both `s⁻¹`** — indistinguishable by
/// dimension. The `radioactivity` kind is the only thing keeping `Bq` off `Hz`.
alias Frequency = Quantity!(Dim(time: -1));
/// ditto
alias Radioactivity = Quantity!(Dim(time: -1), Kind.radioactivity);

/// A plane angle in radians and a plain dimensionless ratio — **both
/// dimensionless**, told apart only by the `angle` kind tag.
alias PlaneAngle = Quantity!(Dim(), Kind.angle);
/// ditto
alias Ratio = Quantity!(Dim());

/// Angular velocity `rad·s⁻¹`: dimension `s⁻¹`, kind `angle` *by construction*.
/// (It cannot be *derived* as `PlaneAngle / Time` — that division would already
/// erase the `angle` kind. The tag has to be asserted, not computed.)
alias AngularVelocity = Quantity!(Dim(time: -1), Kind.angle);

@("Quantity.kind.flat-tags-erase-under-product")
@safe pure nothrow @nogc
unittest
{
    // Same dimension, different kind ⇒ distinct types ⇒ no cross addition.
    static assert(is(Frequency == Quantity!(Dim(time: -1), Kind.none)));
    static assert(!is(Frequency == Radioactivity));
    static assert(!__traits(compiles, Frequency(50.0) + Radioactivity(3.0)));

    // Both dimensionless, different kind ⇒ no cross comparison.
    static assert(!__traits(compiles, PlaneAngle(1.5) == Ratio(1.5)));

    // The honest limit: angular velocity × time is dimensionless but comes back
    // with the DEFAULT kind — the `angle` tag is erased under the product.
    auto swept = AngularVelocity(2.0) * Time(3.0);
    static assert(is(typeof(swept) == Quantity!(Dim(), Kind.none, double)));
    static assert(typeof(swept).quantityKind == Kind.none); // NOT Kind.angle
    assert(swept.value == 6.0);

    // A scalar rescale, by contrast, keeps the kind.
    auto faster = AngularVelocity(2.0) * 4.0;
    static assert(typeof(faster).quantityKind == Kind.angle);
}

void main() @safe
{
    import std.stdio : writeln;

    // --- Radiometry: Radiance vs Irradiance separate BY DIMENSION (the sr). ---
    auto e = Power(60.0) / Area(4.0);        // irradiance = W / m²
    static assert(is(typeof(e) == Irradiance));
    auto l = e / SolidAngle(0.5);            // radiance   = irradiance / sr
    static assert(is(typeof(l) == Radiance));
    // The exponent vectors differ, so the two are simply different types.
    static assert(!__traits(compiles, l + e),
        "radiance and irradiance differ by the sr dimension — not addable");

    // --- The classics: same dimension (or none), separated BY KIND tag. ---
    auto hz = Frequency(50.0);               // s⁻¹, kind none
    auto bq = Radioactivity(3.0);            // s⁻¹, kind radioactivity
    static assert(!__traits(compiles, hz + bq),
        "frequency and radioactivity are both s^-1 — kept apart only by kind");

    auto angle = PlaneAngle(1.5);            // dimensionless, kind angle
    auto ratio = Ratio(0.8);                 // dimensionless, kind none
    static assert(!__traits(compiles, angle == ratio),
        "a plane angle and a bare ratio are both dimensionless — distinct by kind");
    // ...but same-kind, same-dimension arithmetic is of course fine:
    static assert(__traits(compiles, angle + PlaneAngle(0.5)));

    // --- The honest limit: kind erased under ×/÷. ---
    auto omega = AngularVelocity(2.0);       // rad·s⁻¹, kind angle (asserted)
    auto swept = omega * Time(3.0);          // should be an angle... but isn't:
    static assert(typeof(swept).quantityKind == Kind.none,
        "the angle kind is erased by the product — swept angle is default-kind");

    writeln("irradiance          = ", e);
    writeln("radiance            = ", l, "   (differs from irradiance by sr)");
    writeln("frequency           = ", hz);
    writeln("radioactivity       = ", bq, "   (same s^-1 as frequency, kind splits them)");
    writeln("plane angle         = ", angle);
    writeln("ratio               = ", ratio, "   (same dimension as angle, kind splits them)");
    writeln("omega * time        = ", swept, "   (physically 6 rad, but the angle kind was erased)");
}
