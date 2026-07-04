#!/usr/bin/env dub
/+ dub.sdl:
    name "uom_quantity_unit_in_type"
    targetPath "build"
+/
/**
 * Units of measure — unit-in-type storage with *lazy* boundary conversion.
 *
 * This prototype keeps the **unit**, not merely the dimension, in the type: a
 * `Unit` bundles a `ℤ³` dimension exponent vector with a rational **scale to
 * the base unit** (`num/den`, reduced by a CTFE `gcd`). So `Metre` and
 * `Nanometre` are *different types* of the same length dimension —
 * `Unit(length, 1, 1)` versus `Unit(length, 1, 1_000_000_000)`. Nothing is
 * normalized at construction; a `500`-nanometre value is stored as the bare
 * `double 500.0`. Conversion is deferred to the arithmetic boundary: `+`/`-`
 * between two units of the *same* dimension bakes a compile-time rational
 * factor (`convFactor`) and converts the right operand into the left operand's
 * unit right there, at the `+` site. Cross-dimension addition has no matching
 * operator and is rejected — the `static assert(!__traits(compiles, …))` demos
 * turn those intended failures into checked, passing parts of the program.
 *
 * The framing is a physically-based raytracer whose scene distances live in
 * metres but whose spectral wavelengths live in nanometres. `distance +
 * wavelength` must *mean* something and must not silently mix magnitudes:
 * unit-in-type keeps each quantity in its natural, human-scaled unit and lets
 * the `+` boundary insert the `1e-9` factor lazily — contrast
 * `quantity-zn-graded.d`, which stores everything in base units eagerly and
 * has no per-unit scale to carry. See `cpp-mp-units.md`, `cpp-au.md`
 * (`CommonUnit`/`Quantity<Unit>` machinery) and `rust-uom.md` for the
 * production incarnations of exactly this storage choice, and
 * `comparison.md` § "Architectural trade-offs" (the *Unit storage* row,
 * Option B: "keep the unit in the type; convert lazily at boundaries").
 *
 * Companion to docs/research/units-of-measure/examples/cpp-mp-units.md,
 * ./cpp-au.md, ./rust-uom.md and docs/research/units-of-measure/comparison.md.
 *
 * Composition: unit-in-type composes with `sparkles:math`'s `Vector` as
 * ordering A — `Quantity!(unit, Vec3)`, the unit (dimension + scale) wrapping
 * the payload, `Payload` defaulting to `double` exactly as in
 * `quantity-affine-torsor.d`. A positions-in-`cm` `Vec3` and a bounds-in-`m`
 * `Vec3` are then *different types* that convert lazily at the `+` boundary,
 * reusing the very same rational-scale `convFactor` shown here for scalars.
 *
 * Run with: `dub run --single quantity-unit-in-type.d`
 */
module uom_quantity_unit_in_type;

/// Euclid on non-negative operands; CTFE-friendly, no Phobos needed. Used to
/// reduce every rational scale to a unique normal form so equal scales are
/// bit-identical `Unit` template arguments (hence the same `Quantity` type).
long gcd(long a, long b) @safe pure nothrow @nogc
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

/// A dimension: an exponent vector in the free abelian group `ℤ³` over the base
/// dimensions (mass, length, time), stored directly as its normal form.
struct Dim
{
    int mass;
    int length;
    int time;
}

/// The dimension group operation, component-wise: `sign = +1` for
/// multiplication (join of dimensions), `sign = -1` for division (the inverse).
Dim combine(in Dim a, in Dim b, in int sign) @safe pure nothrow @nogc
in (sign == 1 || sign == -1)
{
    return Dim(
        mass: a.mass + sign * b.mass,
        length: a.length + sign * b.length,
        time: a.time + sign * b.time,
    );
}

/// A **unit**: a dimension *plus* a rational scale `num/den` to the base unit of
/// that dimension. This is the whole point of the prototype — the type carries
/// the unit, not just the dimension. `Nanometre` has the same `dim` as `Metre`
/// but `den = 1e9`, so they are distinct types. Kept normalized (`den > 0`,
/// `gcd(num, den) == 1`) by `unit` below, so scale equality is value equality.
struct Unit
{
    Dim dim;
    long num = 1;
    long den = 1;
}

/// Builds a `Unit` in unique normal form: reduces the scale by its gcd and
/// keeps `den > 0`. Normalization is what makes `Metre` and `Metre` the *same*
/// type while `Metre` and `Centimetre` differ.
Unit unit(in Dim d, long num, long den) @safe pure nothrow @nogc
in (den != 0, "unit scale denominator must be non-zero")
out (u; u.den > 0)
{
    if (den < 0)
    {
        num = -num;
        den = -den;
    }
    const g = gcd(num < 0 ? -num : num, den);
    const gg = g == 0 ? 1 : g;
    return Unit(d, num / gg, den / gg);
}

/// The unit group operation for `*`/`/`: dimensions combine (add/subtract
/// exponents) and scales multiply/divide as rationals, renormalized. So
/// `cm * cm` is an area whose scale is `1/10000` of `m²`, tracked exactly.
Unit scaleCombine(in Unit a, in Unit b, in int sign) @safe pure nothrow @nogc
in (sign == 1 || sign == -1)
{
    const d = combine(a.dim, b.dim, sign);
    // scale(a) * scale(b)^sign : (na/da) * (nb/db) or (na/da) / (nb/db).
    const num = sign == 1 ? a.num * b.num : a.num * b.den;
    const den = sign == 1 ? a.den * b.den : a.den * b.num;
    return unit(d, num, den);
}

/// The **lazy boundary conversion** factor: multiply a value expressed in
/// `from` by this to re-express it in `to` (same dimension assumed). It is the
/// ratio of the two rational scales, `(from.num/from.den) / (to.num/to.den)`,
/// evaluated to a `double` at the `+` site — the deferred conversion made
/// concrete. For `nm → m` it is `1e-9`; for `m → nm` it is `1e9`.
double convFactor(in Unit from, in Unit to) @safe pure nothrow @nogc
    => (cast(double) from.num * to.den) / (cast(double) from.den * to.num);

/// CTFE base-dimension label for an exponent vector (only ever run at compile
/// time). `Dim(length: 2)` renders `"m^2"`; the identity is `"(dimensionless)"`.
string dimString(in Dim d) @safe pure
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

/// CTFE label for a whole unit: SI shorthand for the length units the raytracer
/// uses (`m`/`cm`/`mm`/`um`/`nm`), otherwise the base label with an explicit
/// rational scale annotation. GC-allocating, but only evaluated at compile time.
string unitString(in Unit u) @safe pure
{
    import std.conv : to;

    if (u.dim == Dim(length: 1) && u.num == 1)
        switch (u.den)
        {
        case 1: return "m";
        case 100: return "cm";
        case 1000: return "mm";
        case 1_000_000: return "um";
        case 1_000_000_000: return "nm";
        default: break;
        }

    const base = dimString(u.dim);
    if (u.num == 1 && u.den == 1)
        return base;
    return "[" ~ u.num.to!string ~ "/" ~ u.den.to!string ~ "] " ~ base;
}

/// A quantity whose *unit* (dimension + rational scale) lives in the type. The
/// bare `double value` is expressed in that unit — nothing is normalized to
/// base units. Ordering-A composition would add a `Payload = double` parameter
/// (a `Vec3` for dimensioned vectors); this scalar prototype keeps it a `double`.
struct Quantity(Unit U)
{
    double value;

    /// The unit carried by this type (dimension + scale), for introspection.
    alias unit = U;

    /// Compile-time label of this unit (used by `toString`).
    enum string symbol = unitString(U);

    /// Scale by a plain dimensionless scalar, keeping the unit.
    Quantity opBinary(string op)(in double s) const @safe pure nothrow @nogc
    if (op == "*" || op == "/")
        => Quantity(mixin("value " ~ op ~ " s"));

    /// `+`/`-` between two units of the **same dimension**: insert a *lazy*
    /// boundary conversion. The right operand is converted into *this* (the
    /// left) operand's unit by the compile-time `convFactor`, and the result is
    /// in the left unit. If the dimensions differ, this overload's constraint
    /// fails, no operator matches, and the addition does not compile.
    auto opBinary(string op, Unit RU)(in Quantity!RU rhs) const @safe pure nothrow @nogc
    if ((op == "+" || op == "-") && U.dim == RU.dim)
    {
        enum double f = convFactor(RU, U); // the deferred conversion, baked here
        return Quantity!U(mixin("value " ~ op ~ " rhs.value * f"));
    }

    /// `*`/`/` between quantities: dimensions and scales combine via
    /// `scaleCombine`; the numeric payloads multiply/divide directly. `cm * cm`
    /// is thus an area in `cm²` — a distinct type from `m²`, with scale tracked.
    auto opBinary(string op, Unit RU)(in Quantity!RU rhs) const @safe pure nothrow @nogc
    if (op == "*" || op == "/")
    {
        enum Unit ru = scaleCombine(U, RU, op == "*" ? 1 : -1);
        return Quantity!ru(mixin("value " ~ op ~ " rhs.value"));
    }

    /// Render as `value symbol`, e.g. `2 m` or `500 nm`.
    string toString() const @safe
    {
        import std.array : appender;
        import std.format : formattedWrite;

        auto sink = appender!string();
        formattedWrite(sink, "%.7g %s", value, symbol);
        return sink[];
    }
}

enum Dim lengthDim = Dim(length: 1);
enum Dim timeDim = Dim(time: 1);

enum Unit metre = Unit(lengthDim, 1, 1);
enum Unit centimetre = Unit(lengthDim, 1, 100);
enum Unit nanometre = Unit(lengthDim, 1, 1_000_000_000);
enum Unit second = Unit(timeDim, 1, 1);

/// Scene distances live in metres; spectral wavelengths in nanometres.
alias Metre = Quantity!metre;
alias Centimetre = Quantity!centimetre;
alias Nanometre = Quantity!nanometre;
alias Second = Quantity!second;

@("Quantity.unit-in-type.lazy-conversion-and-cross-dimension-rejection")
@safe pure nothrow @nogc
unittest
{
    // Same dimension, DIFFERENT units — distinct types.
    static assert(!is(Metre == Nanometre));
    static assert(Metre.unit.dim == Nanometre.unit.dim);

    auto distance = Metre(2.0);          // 2 m, scene scale
    auto wavelength = Nanometre(500.0);  // 500 nm, spectral scale

    // distance + wavelength : convert the nm operand into metres, lazily.
    auto d1 = distance + wavelength;
    static assert(d1.unit == metre); // result is in the LEFT operand's unit
    assert(d1.value == 2.0 + 500.0 * 1e-9);

    // wavelength + distance : now the metre operand converts into nanometres.
    auto d2 = wavelength + distance;
    static assert(d2.unit == nanometre);
    assert(d2.value == 500.0 + 2.0 * 1e9);

    // Cross-dimension addition is REJECTED: no operator matches (constraint
    // `U.dim == RU.dim` fails). The assert holds because the `+` does not exist.
    static assert(!__traits(compiles, Metre(1.0) + Second(1.0)),
        "adding a length to a time must not compile");

    // Multiplication tracks the scale: cm * cm is an area in cm², not m².
    auto area = Centimetre(3.0) * Centimetre(4.0);
    static assert(area.unit == Unit(Dim(length: 2), 1, 10_000));
    assert(area.value == 12.0);
}

void main() @safe
{
    import std.stdio : writeln;

    // A raytracer scene: distances in metres, a wavelength in nanometres.
    auto sceneDepth = Metre(2.0);
    auto wavelength = Nanometre(500.0); // green-ish light

    // nm + m converts LAZILY at the boundary. Left operand fixes the result
    // unit, so we can read the same physical sum at either scale.
    auto inMetres = sceneDepth + wavelength;      // 2 m + 500 nm, kept in m
    auto inNanometres = wavelength + sceneDepth;  // 500 nm + 2 m, kept in nm
    static assert(inMetres.unit == metre);
    static assert(inNanometres.unit == nanometre);

    // A patch area from two edge lengths given in centimetres, tracked in cm².
    auto patchArea = Centimetre(3.0) * Centimetre(4.0);
    static assert(patchArea.unit == Unit(Dim(length: 2), 1, 10_000));

    // Cross-dimension addition is rejected at compile time — the asserts hold
    // precisely because the operations do NOT compile.
    static assert(!__traits(compiles, sceneDepth + Second(1.0)),
        "length + time must not compile");
    static assert(!__traits(compiles, wavelength + Second(1.0)),
        "length + time must not compile even across scales");
    static assert(__traits(compiles, sceneDepth + wavelength)); // ...but m + nm is fine.

    writeln("scene depth        = ", sceneDepth);
    writeln("wavelength         = ", wavelength);
    writeln("depth + wavelength = ", inMetres, "   (lazy nm -> m at the +)");
    writeln("wavelength + depth = ", inNanometres, "   (lazy m -> nm at the +)");
    writeln("patch area (cm*cm) = ", patchArea, "   (scale tracked: cm^2, not m^2)");
}
