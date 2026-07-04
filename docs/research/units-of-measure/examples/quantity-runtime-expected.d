#!/usr/bin/env dub
/+ dub.sdl:
    name "uom_quantity_runtime_expected"
    dependency "sparkles:base" path="../../../.."
    dependency "sparkles:math" path="../../../.."
    dflags "-preview=in" "-preview=dip1000"
    targetPath "build"
+/
/**
 * Units of measure — runtime dimensions checked at runtime, failures reported
 * as `Expected` (not thrown), for a raytracer whose material data is loaded at
 * runtime.
 *
 * The compile-time prototypes in this catalog put the dimension in the *type*
 * (`Quantity!dim`), so a mismatch is a build error. That is the right default
 * when the units are known when the code is written. But a physically-based
 * renderer often reads its spectra, BRDFs and emitters from a *material file*
 * parsed at startup: the fact that a given channel is a `Radiance` and another
 * is an `Irradiance` is data, not a type. So here the dimension is a plain
 * runtime value — `struct Dim` — stored *inside* every quantity
 * (`struct RQuantity { double value; Dim dim; }`), and the check runs when the
 * data flows, not when the program is compiled.
 *
 * Because the check can now *fail at runtime*, arithmetic that can fail does
 * not throw: `add`/`sub` return `Expected!(RQuantity, DimError)` from the
 * repo's `expected` library — `add(len, len)` is `ok`, `add(radiance,
 * irradiance)` and `metre + second` are `err`, and the caller branches on
 * `hasError` instead of unwinding. Multiplication is *total* (any two
 * dimensions combine), so `mul`/`div` return an `RQuantity` directly. The whole
 * checking core is `@safe pure nothrow @nogc`; only the CTFE-flavoured
 * `unitString` pretty-printer (run at runtime here, since the dims aren't known
 * earlier) may GC, and the one deliberate throwing path (`mustAdd`) uses the
 * `recycledErrorInstance` idiom so it stays `@nogc`.
 *
 * (Aside: `Dim` carries a fourth exponent, solid angle / steradian. SI treats
 * `sr` as dimensionless, which is exactly why `Radiance = W·m⁻²·sr⁻¹` and
 * `Irradiance = W·m⁻²` collapse to the *same* base dimensions and silently add
 * — tracking `sr` is what lets the runtime check catch the confusion the
 * prompt asks for.)
 *
 * Companion to docs/research/units-of-measure/python-pint.md (Pint's runtime
 * `Quantity`/`UnitRegistry` is the canonical runtime-checking design) and
 * docs/research/units-of-measure/ucum-qudt.md (UCUM/QUDT model units as runtime
 * data too); the `Expected`-not-throw discipline follows
 * docs/guidelines/idioms/expected/. In the comparison matrix this is the
 * runtime-checking + runtime-companion cell (#4/#8) — the mirror of the
 * compile-time cells the other prototypes occupy.
 *
 * Composition: a runtime-dim vector (`RVec3 { Vec3 value; Dim dim; }`, using
 * `sparkles:math`'s `Vector`) is composition *ordering A* — one `Dim` tag wraps
 * the whole `Vec3`, so a 3-component radiance sample is checked once, not thrice.
 * That is memory-honest for a vector, but the per-value `Dim` (four `int`s here)
 * is exactly the runtime cost the type-level prototypes erase to zero: this
 * approach trades that footprint for the ability to decide units at runtime.
 *
 * Run with: `dub run --single quantity-runtime-expected.d`
 */
module uom_quantity_runtime_expected;

import expected : Expected, ok, err;
import sparkles.math.vector : Vector;

/// The raytracer's numeric payload for a 3-vector quantity.
alias Vec3 = Vector!(double, 3);

/// `expected` hook that keeps the results usable in `@nogc nothrow` code: a
/// result must be explicitly `ok` or `err`, never a default-constructed limbo.
struct NoGcHook
{
    static immutable bool enableDefaultConstructor = false;
}

/// A dimension carried as a *runtime* value: an exponent vector over
/// (mass, length, time, solid-angle). Two quantities are addable iff their
/// `Dim`s are equal; `==` on the struct is the entire dimension check.
struct Dim
{
    int mass;
    int length;
    int time;
    int solidAngle;
}

/// The group operation, component-wise: `sign = +1` for multiplication (the
/// join of two dimensions), `sign = -1` for division (the group inverse).
Dim combine(in Dim a, in Dim b, in int sign) @safe pure nothrow @nogc
in (sign == 1 || sign == -1)
    => Dim(
        mass: a.mass + sign * b.mass,
        length: a.length + sign * b.length,
        time: a.time + sign * b.time,
        solidAngle: a.solidAngle + sign * b.solidAngle,
    );

/// Runtime unit label for an exponent vector (`Dim(mass: 1, time: -3)` →
/// `"kg s^-3"`). Called at runtime here — the dims are not known earlier — so
/// it may GC; that is fine off the `@nogc` checking path.
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

/// A dimension mismatch: the two operands' dimensions, plus a fixed message.
/// It carries no heap data, so constructing one stays `@nogc nothrow`.
struct DimError
{
    Dim have; /// the left operand's dimension
    Dim want; /// the right operand's dimension (what `have` was required to match)
    string message = "operands have incompatible dimensions"; /// static, GC-free

    /// A human-readable rendering (GC-allocating via `unitString`; used only
    /// on the reporting path, never inside `@nogc` arithmetic).
    string describe() const @safe pure
    {
        import std.format : format;
        return format!"%s: %s vs %s"(message, have.unitString, want.unitString);
    }
}

/// `Expected!(T, DimError)` with the `@nogc`-friendly hook baked in. A fallible
/// operation returns `DimExpected!RQuantity`; the caller inspects `hasValue` /
/// `hasError` rather than catching an exception.
alias DimExpected(T) = Expected!(T, DimError, NoGcHook);

/// A quantity whose dimension is a *runtime* field, not a type parameter. Two
/// distinct dimensions inhabit the *same* type `RQuantity` — the distinction is
/// data, checked when the values meet.
struct RQuantity
{
    double value;
    Dim dim;

    /// `+`/`-`: fallible. Same `dim` → `ok`; different `dim` → `err` (no throw).
    DimExpected!RQuantity add(in RQuantity rhs) const @safe pure nothrow @nogc
    {
        if (dim != rhs.dim)
            return err!(RQuantity, NoGcHook)(DimError(dim, rhs.dim));
        return ok!(DimError, NoGcHook)(RQuantity(value + rhs.value, dim));
    }

    /// ditto for subtraction.
    DimExpected!RQuantity sub(in RQuantity rhs) const @safe pure nothrow @nogc
    {
        if (dim != rhs.dim)
            return err!(RQuantity, NoGcHook)(DimError(dim, rhs.dim));
        return ok!(DimError, NoGcHook)(RQuantity(value - rhs.value, dim));
    }

    /// `*`: *total* — any two dimensions combine, so it returns an `RQuantity`
    /// directly (never an `err`). `Length · Length` → an area, and so on.
    RQuantity mul(in RQuantity rhs) const @safe pure nothrow @nogc
        => RQuantity(value * rhs.value, combine(dim, rhs.dim, 1));

    /// ditto for division (the group inverse of the right dimension).
    RQuantity div(in RQuantity rhs) const @safe pure nothrow @nogc
        => RQuantity(value / rhs.value, combine(dim, rhs.dim, -1));

    /// Render as `value unit` with the dimension resolved at runtime.
    string toString() const @safe pure
    {
        import std.format : format;
        return format!"%.6g %s"(value, dim.unitString);
    }
}

/// The rare path that must *throw* in `@nogc` code rather than return a result:
/// it uses `recycledErrorInstance` (a pre-allocated, reusable `Error`) so no GC
/// allocation happens on the throw — `recycledErrorInstance` requires
/// `T : Error`, which suits a "this is a programming mistake" assertion. The
/// `Expected`-returning `add` above is the recoverable, `nothrow` default you
/// should prefer. See docs/guidelines/idioms/expected/ for when to pick which.
RQuantity mustAdd(in RQuantity a, in RQuantity b) @system @nogc
{
    import sparkles.base.lifetime : recycledErrorInstance;

    auto r = a.add(b);
    if (r.hasError)
        throw recycledErrorInstance!Error("dimension mismatch in mustAdd");
    return r.value;
}

// --- Runtime material table: the units are DATA, loaded at startup ----------

/// One row of a (toy) material file: a channel name and the dimension the
/// renderer should tag that channel's samples with.
struct MaterialRow
{
    string name;
    Dim dim;
}

enum Dim metreDim      = Dim(length: 1);
enum Dim secondDim     = Dim(time: 1);
enum Dim powerDim      = Dim(mass: 1, length: 2, time: -3);            // W
enum Dim irradianceDim = Dim(mass: 1, length: 0, time: -3);           // W·m⁻²
enum Dim radianceDim   = Dim(mass: 1, time: -3, solidAngle: -1);      // W·m⁻²·sr⁻¹

/// A material catalogue "parsed from a file" — here a static table, but the
/// point is that `load` resolves a channel's *dimension at runtime*.
immutable MaterialRow[] materialTable = [
    MaterialRow("length",     metreDim),
    MaterialRow("duration",   secondDim),
    MaterialRow("power",      powerDim),
    MaterialRow("irradiance", irradianceDim),
    MaterialRow("radiance",   radianceDim),
];

/// Look a channel up by name and tag a measured `value` with its dimension —
/// no compile-time knowledge of which unit it is. `@nogc nothrow`: string
/// comparison and struct copy only.
RQuantity load(in char[] channel, in double value) @safe pure nothrow @nogc
{
    foreach (row; materialTable)
        if (row.name == channel)
            return RQuantity(value, row.dim);
    return RQuantity(value, Dim()); // unknown → dimensionless
}

// --- Composition with sparkles:math: one Dim tag for a whole vector ---------

/// A dimensioned 3-vector, composition *ordering A*: the runtime `Dim` wraps
/// the `Vec3`, tagging all three components at once (one tag, not three).
struct RVec3
{
    Vec3 value;
    Dim dim;

    /// Fallible add, mirroring `RQuantity.add`: a single `Dim` compare guards
    /// the whole vector.
    DimExpected!RVec3 add(in RVec3 rhs) const @safe pure nothrow @nogc
    {
        if (dim != rhs.dim)
            return err!(RVec3, NoGcHook)(DimError(dim, rhs.dim));
        return ok!(DimError, NoGcHook)(RVec3(value + rhs.value, dim));
    }

    /// Render the vector through an `appender` sink (never `writeln`'s
    /// `LockingTextWriter`), then the runtime unit label.
    string toString() const @safe
    {
        import std.array : appender;

        auto sink = appender!string();
        value.toString(sink);
        sink.put(" ");
        sink.put(dim.unitString);
        return sink[];
    }
}

@("RQuantity.runtime.add-checks-and-total-multiply")
@safe pure nothrow @nogc
unittest
{
    const a = RQuantity(3.0, metreDim);
    const b = RQuantity(4.0, metreDim);
    const t = RQuantity(2.0, secondDim);

    // Same dimension: add is ok.
    auto sum = a.add(b);
    assert(sum.hasValue);
    assert(sum.value.value == 7.0);
    assert(sum.value.dim == metreDim);

    // Different dimension: add is an err — no throw.
    auto bad = a.add(t);
    assert(bad.hasError);
    assert(bad.error.have == metreDim);
    assert(bad.error.want == secondDim);

    // Multiplication is total: length · length is an area (length^2).
    auto area = a.mul(b);
    assert(area.value == 12.0);
    assert(area.dim == Dim(length: 2));

    // Radiance vs irradiance: distinct only because sr is tracked.
    const rad = RQuantity(1.0, radianceDim);
    const irr = RQuantity(1.0, irradianceDim);
    assert(rad.add(irr).hasError);

    // Composition: one Dim tag guards the whole Vec3.
    const v1 = RVec3(Vec3(1, 0, 0), radianceDim);
    const v2 = RVec3(Vec3(0, 1, 0), radianceDim);
    assert(v1.add(v2).hasValue);
    assert(v1.add(RVec3(Vec3(0, 0, 1), irradianceDim)).hasError);
}

@("RQuantity.runtime.mustAdd-throws-recycled-on-mismatch")
@system unittest
{
    const a = RQuantity(1.0, metreDim);
    const b = RQuantity(2.0, metreDim);

    // Matching dimensions: the throwing helper returns the sum.
    assert(mustAdd(a, b).value == 3.0);

    // Mismatch: it throws (a recycled `Error`, GC-free) instead of returning.
    bool threw;
    try
        mustAdd(a, RQuantity(1.0, secondDim));
    catch (Error e)
        threw = true;
    assert(threw);
}

void main() @safe
{
    import std.stdio : writeln;

    // "Material data loaded at runtime": dimensions come from the table, not
    // from types written into this source.
    const len1 = load("length", 3.0);
    const len2 = load("length", 4.0);
    const secs = load("duration", 2.0);
    const rad  = load("radiance", 1.0);
    const irr  = load("irradiance", 1.0);

    writeln("Loaded (dimension resolved at runtime):");
    writeln("  length     = ", len1);
    writeln("  duration   = ", secs);
    writeln("  radiance   = ", rad);
    writeln("  irradiance = ", irr);
    writeln();

    // add(len, len) -> ok
    auto okSum = len1.add(len2);
    writeln("add(length, length) -> ", okSum.hasValue ? "ok" : "err");
    if (okSum.hasValue)
        writeln("  = ", okSum.value);

    // add(radiance, irradiance) -> err (only because sr is tracked)
    auto radErr = rad.add(irr);
    writeln("add(radiance, irradiance) -> ", radErr.hasError ? "err" : "ok");
    if (radErr.hasError)
        writeln("  ", radErr.error.describe);

    // m + s -> err
    auto msErr = len1.add(secs);
    writeln("add(length, duration)  [m + s] -> ", msErr.hasError ? "err" : "ok");
    if (msErr.hasError)
        writeln("  ", msErr.error.describe);
    writeln();

    // Multiplication is total: length · length is an area.
    auto area = len1.mul(len2);
    writeln("mul(length, length) is total -> ", area);

    // Composition: a runtime-dim Vec3 radiance sample — one Dim tag, three
    // components, checked once.
    const s1 = RVec3(Vec3(0.8, 0.2, 0.1), radianceDim);
    const s2 = RVec3(Vec3(0.1, 0.3, 0.9), radianceDim);
    writeln("RVec3 radiance sample s1 = ", s1);
    writeln("add(s1, s2) [one Dim tag for 3 components] -> ", s1.add(s2).value);
}
