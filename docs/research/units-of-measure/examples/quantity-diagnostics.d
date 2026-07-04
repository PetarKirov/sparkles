#!/usr/bin/env dub
/+ dub.sdl:
    name "uom_quantity_diagnostics"
    targetPath "build"
+/
/**
 * Units of measure — engineered domain-language diagnostics for a raytracer.
 *
 * The single sharpest adoption tax on static units libraries is *encoding
 * leakage*: a mismatch prints the mangled template payload — here a bare
 * `Quantity!(Dim(1, 0, -3, -1), …)` struct literal — instead of the sentence a
 * physicist would say. mp-units and Au answer this by treating diagnostics as a
 * product: prose (and even doc URLs) baked into `static_assert` text, plus a
 * type/dimension pretty-printer. This prototype ports that stance to D. A CTFE
 * pretty-printer `unitString` renders a dimension's exponent vector as SI base
 * symbols (`kg·s⁻³·sr⁻¹`), and a `checkAddable!(A, B)` template turns a
 * dimension clash into the raytracer's own vocabulary:
 * *"cannot add Radiance [W·m⁻²·sr⁻¹] to Irradiance [W·m⁻²] — dimensions differ"*.
 * A module-scope `pragma(msg, …)` prints that engineered sentence at compile
 * time next to the raw leaked type name, so the reader SEES the contrast without
 * the build failing — the real mismatch stays quarantined behind a passing
 * `static assert(!__traits(compiles, …))`.
 *
 * The raytracer framing gives the messages teeth: `Radiance` (W·m⁻²·sr⁻¹) and
 * `Irradiance` (W·m⁻²) differ only by a solid-angle exponent, exactly the
 * confusion a rendering-equation implementation must never make silently.
 *
 * Companion to docs/research/units-of-measure/comparison.md § 6 "Diagnostics and
 * compile cost", and to ./cpp-au.md, ./cpp-mp-units.md, ./d-quantities.md (the
 * "messages are a feature" exemplars and D's first-line-readability prior art).
 *
 * Composition: this file is scalar — the diagnostic lives entirely in the CTFE
 * `Dim` value and the type's compile-time labels, so it is orthogonal to the
 * numeric payload. Wrapping a `sparkles:math` `Vector` would use composition
 * *ordering A* (`Quantity!(dim, Vec3)`, as in `quantity-affine-torsor.d`): the
 * dimension, its labels, and `checkAddable` are unchanged, and a `Vec3` payload
 * only alters `toString`'s value rendering — the engineered prose is payload-blind.
 *
 * Run with: `dub run --single quantity-diagnostics.d`
 */
module uom_quantity_diagnostics;

/// A dimension: an exponent vector in the free abelian group `ℤ⁴` over the base
/// dimensions (mass, length, time, solid angle), stored as its unique normal
/// form. Solid angle is carried as an extra base dimension — the Boost-units
/// "angle as a dimension" choice — precisely so `Radiance` and `Irradiance`,
/// which are SI-dimensionally identical, become distinguishable types.
struct Dim
{
    int mass;
    int length;
    int time;
    int solidAngle;
}

/// The group operation, component-wise: `sign = +1` for multiplication,
/// `sign = -1` for division (the group inverse).
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

/// CTFE dimension pretty-printer: renders an exponent vector as SI base symbols
/// joined by middle dots with Unicode superscripts, e.g.
/// `Dim(mass: 1, time: -3, solidAngle: -1)` → `"kg·s⁻³·sr⁻¹"`. The identity
/// renders as `"(dimensionless)"`. GC-allocating, but only ever evaluated at
/// compile time — this is the custom `toString` on the dimension *value* that
/// lets a diagnostic speak base-SI instead of leaking a struct literal.
string unitString(in Dim d) @safe pure
{
    static immutable string[] supDigit =
        ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"];

    static string superscript(int e) @safe pure
    {
        import std.conv : to;

        string s = e < 0 ? "⁻" : "";
        foreach (ch; (e < 0 ? -e : e).to!string)
            s ~= supDigit[ch - '0'];
        return s;
    }

    string result;

    void put(in string symbol, in int exp)
    {
        if (exp == 0)
            return;
        if (result.length > 0)
            result ~= "·";
        result ~= symbol;
        if (exp != 1)
            result ~= superscript(exp);
    }

    put("kg", d.mass);
    put("m", d.length);
    put("s", d.time);
    put("sr", d.solidAngle);
    return result.length > 0 ? result : "(dimensionless)";
}

/// A graded quantity: one bare `double` tagged with its dimension, plus two
/// compile-time labels used only by the diagnostic machinery — a domain `kind`
/// name (`"Radiance"`) and a preferred display `unit` (`"W·m⁻²·sr⁻¹"`). When a
/// label is empty (an anonymous product of a `*`/`/`), it falls back to the
/// CTFE-derived base-SI form from `unitString`.
struct Quantity(Dim dim, string kind = "", string unit = "")
{
    double value;

    /// The dimension exponent vector (read by `checkAddable`).
    enum Dim dimension = dim;

    /// Domain kind name, or the derived base-unit form for anonymous products.
    enum string kindName = kind.length ? kind : "quantity";

    /// Preferred display unit, or the CTFE-derived base-SI form.
    enum string unitLabel = unit.length ? unit : unitString(dim);

    /// `+`/`-` within one grade: both operands share the exact type.
    Quantity opBinary(string op)(in Quantity rhs) const @safe pure nothrow @nogc
    if (op == "+" || op == "-")
        => Quantity(mixin("value " ~ op ~ " rhs.value"));

    /// `+`/`-` across grades is the *diagnostic* path: instantiating
    /// `checkAddable` on a dimension clash fires the engineered domain-language
    /// `static assert`, so `radiance + irradiance` fails to compile with prose.
    auto opBinary(string op, Dim rd, string rk, string ru)(in Quantity!(rd, rk, ru) rhs) const
    if ((op == "+" || op == "-") && rd != dim)
    {
        enum _ = checkAddable!(typeof(this), Quantity!(rd, rk, ru)); // emits the domain assert
        return this; // unreachable — the static assert above aborts this instantiation
    }

    /// `*`/`/` are total: dimensions combine, and the result is an anonymous
    /// product whose unit label comes from the CTFE `unitString` printer.
    auto opBinary(string op, Dim rd, string rk, string ru)(in Quantity!(rd, rk, ru) rhs) const
        @safe pure nothrow @nogc
    if (op == "*" || op == "/")
    {
        enum Dim rdim = combine(dim, rd, op == "*" ? 1 : -1);
        return Quantity!rdim(mixin("value " ~ op ~ " rhs.value"));
    }

    /// Scale by a plain dimensionless scalar, keeping the dimension and labels.
    Quantity opBinary(string op)(in double s) const @safe pure nothrow @nogc
    if (op == "*" || op == "/")
        => Quantity(mixin("value " ~ op ~ " s"));

    /// Render as `value unitLabel` through an `appender` sink (kept `@safe`).
    string toString() const @safe
    {
        import std.array : appender;
        import std.format : formattedWrite;

        auto sink = appender!string();
        formattedWrite(sink, "%.6g %s", value, unitLabel);
        return sink[];
    }
}

/// The engineered domain-language mismatch sentence for an add of `A` to `B`.
/// Factored out of `checkAddable` so a `pragma(msg, …)` can *show* the exact
/// message text at compile time without failing the build.
enum string addMismatchMsg(A, B) =
    "cannot add " ~ A.kindName ~ " [" ~ A.unitLabel ~ "] to "
    ~ B.kindName ~ " [" ~ B.unitLabel ~ "] — dimensions differ";

/// The `static assert` gate. Same dimension → `true`; otherwise a hard,
/// passing-by-construction compile error carrying `addMismatchMsg` prose. This
/// is D's analogue of Au's prose `static_assert` and mp-units' `unsatisfied<…>`.
template checkAddable(A, B)
{
    static if (A.dimension == B.dimension)
        enum bool checkAddable = true;
    else
        static assert(false, addMismatchMsg!(A, B));
}

enum Dim lengthDim = Dim(length: 1);
enum Dim areaDim = Dim(length: 2);
enum Dim solidAngleDim = Dim(solidAngle: 1);
enum Dim powerDim = Dim(mass: 1, length: 2, time: -3);        // W  = kg·m²·s⁻³
enum Dim irradianceDim = Dim(mass: 1, time: -3);              // W·m⁻² = kg·s⁻³
enum Dim radianceDim = Dim(mass: 1, time: -3, solidAngle: -1); // W·m⁻²·sr⁻¹

/// The raytracer's radiometric vocabulary, each with a domain kind name and a
/// preferred derived-unit label — the two ingredients the diagnostic speaks in.
alias Length = Quantity!(lengthDim, "Length", "m");
alias Area = Quantity!(areaDim, "Area", "m²");
alias SolidAngle = Quantity!(solidAngleDim, "Solid angle", "sr");
alias Power = Quantity!(powerDim, "Power", "W");
alias Irradiance = Quantity!(irradianceDim, "Irradiance", "W·m⁻²");
alias Radiance = Quantity!(radianceDim, "Radiance", "W·m⁻²·sr⁻¹");

// Compile-time demonstration — prints during the build, never at run time, and
// never fails it. Line 1 is the raw encoding leak (the mangled struct literal a
// naive mismatch would surface); line 2 is the engineered domain sentence.
pragma(msg,
    "\n[quantity-diagnostics] raw type encoding leaks the struct literal:\n"
    ~ "    " ~ Radiance.stringof ~ "\n"
    ~ "[quantity-diagnostics] engineered domain diagnostic (demo — build still succeeds):\n"
    ~ "    " ~ addMismatchMsg!(Radiance, Irradiance) ~ "\n");

@("Quantity.diagnostics.checkAddable-gates-on-dimension")
@safe pure nothrow @nogc
unittest
{
    // Same dimension is addable; the gate yields `true`.
    static assert(checkAddable!(Radiance, Radiance));
    static assert(__traits(compiles, Radiance(1) + Radiance(2)));

    // A dimension clash makes `checkAddable` (and hence `+`) fail to compile.
    // These asserts PASS precisely because the operations do not — the intended
    // failure is turned into a checked part of the program.
    static assert(!__traits(compiles, checkAddable!(Radiance, Irradiance)));
    static assert(!__traits(compiles, Radiance(1) + Irradiance(2)));

    // `*`/`/` are total: power over area is an irradiance-dimensioned product,
    // and its label is derived by the CTFE `unitString` printer.
    auto e = Power(1000.0) / Area(2.0);
    static assert(is(typeof(e) == Quantity!irradianceDim));
    assert(e.value == 500.0);
    static assert(Quantity!irradianceDim.unitLabel == "kg·s⁻³");
}

void main() @safe
{
    import std.stdio : writeln;

    // Two radiometric quantities that differ only by a solid-angle exponent.
    auto radiance = Radiance(1200.0);
    auto irradiance = Irradiance(340.0);

    // The mismatch is quarantined: this holds because the add does NOT compile,
    // so the program builds and runs while the clash stays rejected.
    static assert(!__traits(compiles, radiance + irradiance),
        "adding radiance to irradiance must not compile");
    static assert(__traits(compiles, radiance + radiance)); // ...same grade is fine.

    // Total products: splitting incident Power over Area gives an Irradiance
    // dimension; per unit Solid angle gives a Radiance dimension. Because these
    // are anonymous products, their labels come from the CTFE `unitString`
    // printer as base-SI normal forms — the honest derivation behind the
    // domain-friendly `W·m⁻²` / `W·m⁻²·sr⁻¹` the named aliases advertise.
    auto derivedIrradiance = Power(1000.0) / Area(2.0);
    auto derivedRadiance = derivedIrradiance / SolidAngle(4.0);
    static assert(is(typeof(derivedIrradiance) == Quantity!irradianceDim));
    static assert(is(typeof(derivedRadiance) == Quantity!radianceDim));

    writeln("Named domain quantities (preferred derived-unit labels):");
    writeln("  radiance             = ", radiance);
    writeln("  irradiance           = ", irradiance);
    writeln();
    writeln("Anonymous products (CTFE unitString → SI base normal form):");
    writeln("  power / area         = ", derivedIrradiance, "   (domain: Irradiance, W·m⁻²)");
    writeln("  … / solid angle      = ", derivedRadiance, "   (domain: Radiance, W·m⁻²·sr⁻¹)");
    writeln();
    writeln("The rejected add, spoken in the raytracer's own vocabulary:");
    writeln("  ", addMismatchMsg!(Radiance, Irradiance));
    writeln();
    writeln("Contrast — the raw encoding a naive mismatch would leak:");
    writeln("  ", Radiance.stringof);
}
