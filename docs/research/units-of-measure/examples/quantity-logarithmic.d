#!/usr/bin/env dub
/+ dub.sdl:
    name "uom_quantity_logarithmic"
    targetPath "build"
+/
/**
 * Units of measure — logarithmic quantities (photographic stops / decibels),
 * and *why* they resist the free-abelian-group exponent-vector model.
 *
 * A physically-based raytracer accumulates *linear* radiance
 * (W·m⁻²·sr⁻¹); a photographer's exposure controls are *logarithmic*. One
 * photographic **stop** (an exposure value, EV, base-2) *doubles* exposure;
 * power **decibels** obey `+3 dB ≈ ×2` power (the familiar `+6 dB ≈ ×2` is the
 * amplitude/field convention, `20·log₁₀`). The defining move is that
 * LOG-DOMAIN ADDITION corresponds to LINEAR-DOMAIN MULTIPLICATION:
 * stacking `+1 EV` then `+2 EV` gives `+3 EV`, which scales linear radiance by
 * `×2 · ×4 = ×8`. We model `struct Stops { double ev; }` whose `+`/`-` compose
 * gains, with a `toLinear()`/`fromLinear()` bridge to a plain multiplicative
 * `Ratio`, and prove the homomorphism both ways.
 *
 * This is exactly why logarithmic units are a "fourfold silence" in the theory
 * tree (comparison #9): a stop is **not a grade in the dimension group**. It
 * carries no exponent vector — its underlying `Ratio` is *dimensionless* — yet
 * its `+` means `×` on that ratio, so the `ℤⁿ` exponent-vector algebra, whose
 * `+` is ordinary linear addition within a grade, represents the wrong
 * operation. A `Stops` is instead the isomorphism `log₂ : (ℝ_{>0}, ×) → (ℝ, +)`
 * — a re-coordinatization of the dimensionless ratios — and it is only
 * meaningful *relative to a reference* (a base exposure; a reference power).
 * The bridge `2^ev` is nonlinear, so a *vector* of log-values is nonlinear too:
 * you cannot component-add exposures the way you add displacements (§ below).
 *
 * Companion to docs/research/units-of-measure/python-pint.md (the only shipped
 * dB unit) and docs/research/units-of-measure/julia-unitful.md (the
 * experimental log layer); see comparison.md #9 (Angle & logarithmic policy).
 *
 * Composition: `Stops` is scalar here, but a per-RGB-channel exposure would be
 * `Vector!(Stops, 3)` (ordering B) — a *product* structure, not a vector space,
 * because component-adding stop vectors component-*multiplies* the linear RGB
 * gains and does NOT distribute over radiance addition; a single scalar `Stops`
 * acting on a dimensioned radiance `Quantity!(dim, Vec3)` (ordering A) is the
 * only composition that stays linear-algebra-clean.
 *
 * Run with: `dub run --single quantity-logarithmic.d`
 */
module uom_quantity_logarithmic;

import std.math : log2, log10, isClose;

/// A plain dimensionless LINEAR ratio — an element of the multiplicative group
/// `(ℝ_{>0}, ×)`. This is what a raytracer actually accumulates and scales:
/// a gain applied to linear radiance. Its group operation is MULTIPLICATION,
/// its identity `Ratio(1.0)`. It carries no dimension exponent (see the graded
/// `Quantity` below: it is the `Quantity!0` grade).
struct Ratio
{
    double factor;

    /// The multiplicative group op: gains compose by `*`, invert by `/`.
    Ratio opBinary(string op)(in Ratio rhs) const @safe pure nothrow @nogc
    if (op == "*" || op == "/")
        => Ratio(mixin("factor " ~ op ~ " rhs.factor"));

    string toString() const @safe
    {
        import std.format : format;
        return format!"×%.6g"(factor);
    }
}

/// A LOGARITHMIC quantity: a photographic stop / exposure value (EV), base-2.
/// One stop doubles exposure. The payload `ev` lives in the ADDITIVE group
/// `(ℝ, +)`: composing two exposure adjustments ADDS their stop counts, which
/// MULTIPLIES the underlying linear `Ratio`. `Stops` is therefore not a new
/// dimension grade — it is the isomorphism `log₂ : (ℝ_{>0}, ×) → (ℝ, +)`,
/// meaningful only relative to a reference exposure.
struct Stops
{
    double ev;

    /// Compose gains: `+` stacks exposure adjustments, `-` removes one.
    /// LOG-domain addition ≙ LINEAR-domain multiplication (proven below).
    Stops opBinary(string op)(in Stops rhs) const @safe pure nothrow @nogc
    if (op == "+" || op == "-")
        => Stops(mixin("ev " ~ op ~ " rhs.ev"));

    /// Scale the *count* of stops by a plain scalar (e.g. `* 0.5` = half a
    /// stop). Note there is deliberately no `Stops * Stops`: multiplying two
    /// logarithms is not a group operation on the exposures (see rejections).
    Stops opBinary(string op)(in double s) const @safe pure nothrow @nogc
    if (op == "*" || op == "/")
        => Stops(mixin("ev " ~ op ~ " s"));

    /// Bridge to the linear domain: `2^ev`. This is the isomorphism's inverse
    /// and is NONLINEAR in `ev` — the root of the vector nonlinearity below.
    Ratio toLinear() const @safe pure nothrow @nogc
        => Ratio(2.0 ^^ ev);

    /// Bridge from a linear ratio: `log₂(factor)`. Defined only for a positive
    /// ratio — logarithms exist only on the positive multiplicative group,
    /// which is *why* a log unit needs a reference to be meaningful.
    static Stops fromLinear(in Ratio r) @safe pure nothrow @nogc
    in (r.factor > 0, "a logarithmic stop is defined only for a positive ratio")
        => Stops(log2(r.factor));

    string toString() const @safe
    {
        import std.format : format;
        return format!"%+.6g EV"(ev);
    }
}

/// A second logarithmic quantity, on a different base and reference: power
/// decibels, `dB = 10·log₁₀(P/P_ref)`, so `+3 dB ≈ ×2` power. It shares Stops'
/// structure (add-in-log ≙ multiply-in-linear) but with base 10 and factor 10.
/// That two log units with *different* constants share one algebra underscores
/// the point: the log unit carries no dimension of its own — it is the
/// reference and base that give it meaning, not a grade in the dimension group.
struct Decibels
{
    double db;

    Decibels opBinary(string op)(in Decibels rhs) const @safe pure nothrow @nogc
    if (op == "+" || op == "-")
        => Decibels(mixin("db " ~ op ~ " rhs.db"));

    Ratio toLinear() const @safe pure nothrow @nogc
        => Ratio(10.0 ^^ (db / 10.0));

    static Decibels fromLinear(in Ratio r) @safe pure nothrow @nogc
    in (r.factor > 0, "decibels are defined only for a positive power ratio")
        => Decibels(10.0 * log10(r.factor));

    string toString() const @safe
    {
        import std.format : format;
        return format!"%+.6g dB"(db);
    }
}

/// A minimal `ℤ¹`-graded quantity (a single length exponent) — the
/// free-abelian-group model in miniature, present only to make the contrast
/// concrete. Its `+` is ORDINARY LINEAR addition within a grade. The
/// dimensionless grade `Quantity!0` IS a linear `Ratio` — but its `+` is the
/// WRONG operation for a stop: `Quantity!0(2) + Quantity!0(2) == 4`, whereas
/// composing `+1 EV` twice is `+2 EV`, i.e. a linear `×4`. Same dimensionless
/// numbers, different group — which is precisely why a log unit is not a grade.
struct Quantity(int lengthExp)
{
    double value;

    Quantity opBinary(string op)(in Quantity rhs) const @safe pure nothrow @nogc
    if (op == "+" || op == "-")
        => Quantity(mixin("value " ~ op ~ " rhs.value"));

    auto opBinary(string op, int e)(in Quantity!e rhs) const @safe pure nothrow @nogc
    if (op == "*" || op == "/")
        => Quantity!(op == "*" ? lengthExp + e : lengthExp - e)(
            mixin("value " ~ op ~ " rhs.value"));
}

/// The dimensionless grade: a bare ratio with LINEAR `+`.
alias Dimensionless = Quantity!0;

/// Per-channel RGB radiance/gain helpers (plain `double[3]`, zero-dep). A stop
/// vector maps to a linear RGB gain through `2^ev` component-wise; this is
/// NONLINEAR, hence not a vector space over radiance.
double[3] rgbToLinear(in double[3] evPerChannel) @safe pure nothrow @nogc
{
    double[3] lin;
    static foreach (i; 0 .. 3)
        lin[i] = 2.0 ^^ evPerChannel[i];
    return lin;
}

@("Quantity.logarithmic.homomorphism-and-graded-mismatch")
@safe pure nothrow @nogc
unittest
{
    // The core theorem, forward: log-domain `+` ≙ linear-domain `×`.
    // fromLinear(a) + fromLinear(b) == fromLinear(a * b).
    auto a = Ratio(2.0);
    auto b = Ratio(4.0);
    auto sumOfLogs = Stops.fromLinear(a) + Stops.fromLinear(b);
    auto logOfProduct = Stops.fromLinear(a * b);
    assert(isClose(sumOfLogs.ev, logOfProduct.ev));
    assert(isClose(sumOfLogs.ev, 3.0)); // 1 EV + 2 EV = 3 EV

    // The core theorem, inverse: (s + t).toLinear ≈ s.toLinear * t.toLinear.
    auto s = Stops(1.0);
    auto t = Stops(2.0);
    assert(isClose((s + t).toLinear.factor, s.toLinear.factor * t.toLinear.factor));
    assert(isClose((s + t).toLinear.factor, 8.0)); // +3 EV == ×8

    // A log unit is NOT the dimensionless grade: the graded `+` is linear.
    static assert(is(typeof(Dimensionless(2) + Dimensionless(2)) == Dimensionless));
    assert(Dimensionless(2).value + Dimensionless(2).value == 4.0); // linear add
    // ...while composing the SAME ratio-of-2 twice as stops gives ×4, not 4.
    assert(isClose((Stops.fromLinear(Ratio(2.0)) + Stops.fromLinear(Ratio(2.0)))
            .toLinear.factor, 4.0));
}

void main() @safe
{
    import std.stdio : writeln;

    // A raytracer holds linear radiance; the photographer thinks in stops.
    auto baseGain = Ratio(1.0);              // reference exposure (×1)
    auto pushOne = Stops(1.0);               // +1 stop
    auto pushTwo = Stops(2.0);               // +2 stops

    // Compose exposure adjustments by ADDING stops...
    auto total = pushOne + pushTwo;          // +3 EV
    // ...which MULTIPLIES the underlying linear ratio (×2 · ×4 = ×8).
    auto linear = total.toLinear;

    writeln("+1 EV                     = ", pushOne, "  (", pushOne.toLinear, ")");
    writeln("+2 EV                     = ", pushTwo, "  (", pushTwo.toLinear, ")");
    writeln("(+1 EV) + (+2 EV)         = ", total, "  (", linear, ")");

    // Round trip through the bridge, both directions.
    auto a = Ratio(2.0), b = Ratio(4.0);
    writeln("fromLinear(×2)+fromLinear(×4) = ",
        Stops.fromLinear(a) + Stops.fromLinear(b),
        "   == fromLinear(×2·×4) = ", Stops.fromLinear(a * b));

    // A different log unit, different base/reference, same algebra:
    // +3 dB ≈ ×2 power; stacking it doubles again → ×4.
    auto threeDb = Decibels.fromLinear(Ratio(2.0));
    writeln("Decibels.fromLinear(×2)   = ", threeDb,
        "   (doubled) = ", threeDb + threeDb, " ≈ ", (threeDb + threeDb).toLinear);

    // Rejections are proofs. A log quantity is not a linear ratio, not a
    // dimensionless grade, and stops do not multiply — none of these compile.
    static assert(!__traits(compiles, pushOne + baseGain),
        "a logarithmic Stops is not a linear Ratio — they must not add");
    static assert(!__traits(compiles, pushOne + Dimensionless(1)),
        "a stop is not the dimensionless grade — its + is × on the ratio");
    static assert(!__traits(compiles, pushOne * pushTwo),
        "multiplying two logarithms is not a group op on exposures");
    static assert(__traits(compiles, pushOne + pushTwo)); // ...but composing gains is.

    // VECTOR NONLINEARITY. Two per-channel exposure adjustments, in stops.
    // You might hope to "add exposures" the way you add displacements — but
    // component-ADDING the stop vectors component-MULTIPLIES the linear RGB
    // gains, and does NOT correspond to adding the linear radiances.
    double[3] expA = [0.0, 1.0, 2.0];   // stops per channel
    double[3] expB = [1.0, 1.0, 1.0];
    double[3] summedStops = [expA[0] + expB[0], expA[1] + expB[1], expA[2] + expB[2]];

    auto linA = rgbToLinear(expA);      // [×1, ×2, ×4]
    auto linB = rgbToLinear(expB);      // [×2, ×2, ×2]
    auto linOfSum = rgbToLinear(summedStops);
    double[3] productOfLin = [linA[0] * linB[0], linA[1] * linB[1], linA[2] * linB[2]];
    double[3] sumOfLin = [linA[0] + linB[0], linA[1] + linB[1], linA[2] + linB[2]];

    writeln("stops A                   = ", expA, "  → linear ", linA);
    writeln("stops B                   = ", expB, "  → linear ", linB);
    writeln("component-add stops       = ", summedStops,
        "  → linear ", linOfSum, " (== component-MULTIPLY ", productOfLin, ")");
    writeln("linear radiance ADD would = ", sumOfLin,
        "  ≠ ", linOfSum, "  ⇒ a vector of log-values is nonlinear");
}
