#!/usr/bin/env dub
/+ dub.sdl:
    name "uom_quantity_erasure"
    targetPath "build"
+/
/**
 * Units of measure — the erasure demo: dimensions cost zero bytes.
 *
 * Every `Quantity!dim` — whatever the grade — is represented as exactly one
 * `double`: same `sizeof`, same `alignof`, payload at `offsetof == 0`, and
 * arrays of quantities occupy exactly the bytes of arrays of doubles. All of
 * this is pinned down by `static assert`s, so the claim is machine-checked on
 * every build, for several distinct grades.
 *
 * Honesty note: these asserts establish *representation* equality only. They
 * deliberately do NOT claim codegen identity — that `a * b` on `Quantity`
 * emits the same instructions as on `double` is a property of the optimizer,
 * unobservable from inside this program; inspect the generated assembly for
 * that. The semantic counterpart is Kennedy's dimension-erasure semantics,
 * where a program means exactly what its unit-stripped version means.
 *
 * Companion to docs/research/units-of-measure/theory/type-system-mechanisms.md
 * § 'Theorem 2 — erasure + parametricity: what "zero runtime cost" means'.
 *
 * Run with: `dub run --single quantity-erasure.d`
 */
module uom_quantity_erasure;

/// A dimension: an exponent vector in `ℤ³` over (mass, length, time). It
/// exists only at compile time — no instance of it is ever stored.
struct Dim
{
    int mass;
    int length;
    int time;
}

/// The group operation, component-wise on exponent vectors: `sign = +1` for
/// quantity multiplication, `sign = -1` for division.
Dim combine(in Dim a, in Dim b, in int sign) @safe pure nothrow @nogc
in (sign == 1 || sign == -1)
{
    return Dim(
        mass: a.mass + sign * b.mass,
        length: a.length + sign * b.length,
        time: a.time + sign * b.time,
    );
}

/// CTFE-built unit label for an exponent vector (used by `toString`).
/// GC-allocating, but only ever evaluated at compile time below.
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

/// A graded quantity. The grade `dim` lives in the *type*; the only field is
/// the `double` payload, so the run-time representation is a bare `double`.
struct Quantity(Dim dim)
{
    double value;

    /// Compile-time unit label of this grade (used by `toString`).
    enum string symbol = unitString(dim);

    /// `+`/`-` exist only within a single grade: both operands share `dim`.
    Quantity opBinary(string op)(in Quantity rhs) const
    if (op == "+" || op == "-")
        => Quantity(mixin("value " ~ op ~ " rhs.value"));

    /// `*`/`/` are total: the result grade adds/subtracts exponent vectors.
    auto opBinary(string op, Dim rhsDim)(in Quantity!rhsDim rhs) const
    if (op == "*" || op == "/")
        => Quantity!(combine(dim, rhsDim, op == "*" ? 1 : -1))(
            mixin("value " ~ op ~ " rhs.value"));

    string toString() const
    {
        import std.format : format;
        return format!"%.6g %s"(value, symbol);
    }
}

enum Dim lengthDim = Dim(length: 1);
enum Dim timeDim = Dim(time: 1);
enum Dim speedDim = combine(lengthDim, timeDim, -1);
enum Dim forceDim = Dim(mass: 1, length: 1, time: -2);

// --- The layout half of "zero runtime cost", checkable in-program ----------
//
// Each distinct `Dim` value mints a distinct type, yet every one of them has
// the representation of a bare `double`: the grade is fully erased from the
// object layout.
static foreach (dim; [Dim(), lengthDim, speedDim, forceDim])
{
    // One quantity is exactly one double: same size, same alignment, and the
    // payload at offset 0 — no tag, no vtable, no padding.
    static assert(Quantity!dim.sizeof == double.sizeof);
    static assert(Quantity!dim.alignof == double.alignof);
    static assert(Quantity!dim.value.offsetof == 0);

    // Arrays inherit the layout: N quantities occupy exactly N doubles.
    static assert((Quantity!dim[1024]).sizeof == (double[1024]).sizeof);
}

@("Quantity.erasure.arithmetic-on-the-bare-payload")
@safe pure nothrow @nogc
unittest
{
    auto v = Quantity!lengthDim(6.0) / Quantity!timeDim(2.0);
    static assert(is(typeof(v) == Quantity!speedDim));
    static assert(typeof(v).sizeof == double.sizeof);
    assert(v.value == 3.0);
}

void main() @safe
{
    import std.stdio : writeln;

    // A fixed-size array of graded quantities — by the asserts above, the
    // same bytes as a `double[4]`.
    const Quantity!lengthDim[4] laps = [
        Quantity!lengthDim(400.0),
        Quantity!lengthDim(380.0),
        Quantity!lengthDim(420.0),
        Quantity!lengthDim(400.0),
    ];

    auto total = Quantity!lengthDim(0.0);
    foreach (lap; laps)
        total = total + lap;

    const elapsed = Quantity!timeDim(250.0);
    const meanSpeed = total / elapsed;

    writeln("laps       = ", laps);
    writeln("total      = ", total);
    writeln("elapsed    = ", elapsed);
    writeln("mean speed = ", meanSpeed);
    writeln("layout     : Quantity.sizeof == double.sizeof == ", double.sizeof,
        " (statically asserted for 4 grades)");
}
