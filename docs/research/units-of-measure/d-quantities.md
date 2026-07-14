# quantities, units-d & the `std.units` RFC (D)

The D ecosystem's three units-of-measure artifacts — really **two designs**: `biozic/quantities`, a CTFE-driven library whose dimension vector is a compile-time _value_ (with a runtime-checked `QVariant` twin and a unit-string parser that runs both at compile time and at run time), and David Nadlinger's 2011 `std.units` Phobos proposal, a units-as-types conversion-graph design with `BaseUnit`/`DerivedUnit`/`ScaledUnit`/`AffineUnit` templates and compile-time rational exponents — the latter surviving today as Per Nordlöw's modernized port `nordlow/units-d`.

| Field            | Value                                                                                                                                                                                                                                                                                                   |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | D (all three; `quantities` requires nothing beyond Phobos)                                                                                                                                                                                                                                              |
| License          | BSL-1.0 (all three — Boost License 1.0)                                                                                                                                                                                                                                                                 |
| Repository       | [biozic/quantities][repo-q] · [nordlow/units-d][repo-u] · [dnadlinger/phobos `units` branch][repo-n]                                                                                                                                                                                                    |
| Documentation    | [quantities DDoc][docs-q] · [dub: quantities][dub-q] · [dub: units-d][dub-u] · [Nadlinger's project page][klickverbot] · [the 2011–2016 RFC thread][rfc]                                                                                                                                                |
| Key authors      | Nicolas Sicard (`quantities`); David Nadlinger (`std.units`/`si.d`); Per Nordlöw (`units-d` modernization)                                                                                                                                                                                              |
| Category         | Library-level [compile-time checking][concepts] + a runtime-checked variant (`QVariant`); `std.units` is a **never-merged standard-library proposal**                                                                                                                                                   |
| Mechanism        | `quantities`: a CTFE-built `Dimensions` _value_ (sorted array of symbol–`Rational` pairs) as a template value parameter of `Quantity!(N, dims)`. `std.units`/`units-d`: units as _types_ — canonicalized `AliasSeq` of `BaseUnitExp!(B, Rational!(n, d))`; no dimension concept, convertibility instead |
| Exponent domain  | `ℚ` in all three — `quantities` normalizes an `int`-pair `Rational` struct at CTFE; `std.units` canonicalizes a `Rational!(int n, uint d)` _template_ by gcd so equal rationals are the same type                                                                                                       |
| Checking time    | Compile time (`Quantity` in both designs) **and** run time (`quantities`' `QVariant` throws `DimensionException`)                                                                                                                                                                                       |
| Analyzed version | `quantities` @ `3cb3205` (2020-01-27, = tag `v0.11.0`) · `units-d` @ `9589ac9` (2021-03-13) · `dnadlinger/phobos` `units` branch @ `4a7279a` (2011-12-10)                                                                                                                                               |
| Latest release   | `quantities` `v0.11.0` (2020 — dormant since); `units-d` `v0.1.0` (repo dormant since 2021); `std.units` never released, never formally reviewed                                                                                                                                                        |

> [!NOTE]
> This is the survey's home-ecosystem page and the **direct prior-art input for a
> future sparkles units library**. All three artifacts still compile under `ldc2` 1.41
> (D 2.111) in 2026 — `quantities` passes its full test suite, and in both
> Nadlinger-lineage artifacts the core units module passes while the SI layer's tests
> fail on float-comparison asserts; the compilability results below are all locally
> reproduced, including a 2011 file that builds warning-free without a single edit. The mechanism taxonomy these libraries
> instantiate (template normal forms, per-instantiation checking, no unification) is
> [type-system mechanisms][mechanisms]; what a checker with real measure _inference_
> looks like is [Kennedy's type system][kennedy] as shipped in [F#][fsharp]. The
> cross-system synthesis — and the delta table toward a sparkles design — is the
> [comparison capstone][comparison], not this page.

---

## Overview

### What it solves

**`quantities`** (Nicolas Sicard, 2013–2020) is a pragmatic both-worlds library. Its
[`README.md`][readme-q] opens:

> _"The purpose of this small library is to perform automatic compile-time or
> run-time dimensional checking when dealing with quantities and units."_

One library, two checking regimes sharing one API surface: `Quantity!(N, dims)`
carries its dimension vector in the type and rejects mismatches with a
`static assert`; `QVariant!N` stores the same vector in a runtime field and throws
`DimensionException`. A unit-expression parser (`si!"299_792_458 m/s"` at compile
time, `parseSI("384_400 km")` at run time) makes units data, not just code.

**`std.units` + `std.si`** (David Nadlinger, April 2011) was pitched as _the_
standard-library units module, announced on the `digitalmars.D` newsgroup
([RFC thread][rfc], 2011-04-12):

> "Recently, I have been playing around with a little units of measurement system in
> D. As this topic has already been brought up quite a number of times here, I thought
> I would put my implementation up for discussion here."

It is the more theoretically adventurous design: units are marker _types_ assembled by
`BaseUnit`, `DerivedUnit`, `ScaledUnit`, `AffineUnit` and `PrefixedUnit` templates,
exponents are compile-time rationals built from `std.typetuple`-era metaprogramming,
and conversions are a statically-searched graph of arbitrary callables.

**`units-d`** (Per Nordlöw, 2016–2021) is not a third design. Its
[`README.md`][readme-u] says so in its second sentence:

> "This is a modified version of David Nadlinger's original library for working with
> units of measurement in D."

It renames the modules to `experimental.units`, replaces `TypeTuple` with `AliasSeq`,
adopts UFCS and modern template syntax, and annotates the tests
`@safe pure nothrow @nogc` — a syntactic modernization of the `std.units` design whose
remaining task list (breadth-first `GetConversion`, a `LinearUnit` for Fahrenheit,
integer-precision `ScaledUnit`) documents exactly where the 2011 design was left off.

### Design philosophy

The two designs answer the same question — _what is the type of a quantity?_ — in
opposite ways, and the opposition is the most instructive thing D prior art has to
offer.

**`quantities`: dimensions are the type; units are just values.** The README erases
the unit/quantity distinction entirely ([`README.md`][readme-q]):

> _"There is no actual distinction between units and quantities, so there are no
> distinct quantity and unit types. All operations are actually done on quantities.
> For example, `meter` is both the unit meter and the quantity 1m."_

Every quantity is normalized to base units at construction ([`README.md`][readme-q],
"Consequences of the design"):

> _"…all quantities sharing the same dimensions are internally expressed in the same
> unit, which is the base unit for this quantity. For instance, all lengths are stored
> as meters… The quantity 3 km is stored as 3000 m, 2 min is stored as 120 s, etc."_

This is the canonical-basis view — a quantity is a scalar times a point in the
[free abelian group][fag] of dimensions — and it buys the property the README lists as
principle #3: two quantities with the same dimensions _share the same type_, so
`kilo(meter)` and `meter` add freely and functions over `Length` need no templates.

**`std.units`: units are the type; dimensions don't exist.** Nadlinger's module
header takes the exact opposite position ([`units.d`][units-d-file] L24–28):

> _"In the design of this module, the explicit concept of dimensions does not appear,
> because it would add a fair amount of complication to both the interface and the
> implementation for little benefit. Rather, the notion is established implicitly by
> defining conversions between pairs of units – to see if two units share the same
> dimension, just check for convertibility."_

And values are never re-based ([`units.d`][units-d-file] L13–16):

> _"Conversions only happen if explicitly requested and there is no different internal
> representation of values – for example 1 \* kilo(metre) is stored just as 1 in
> memory, not as 1000 or relative to any other »canonical unit«."_

This is the unit-centric view later industrialized by [Unitful.jl][unitful] and
[mp-units][mp-units]: `1 * kilo(metre) + 1 * metre` is a _type error_ until you
`convert!`, no precision is ever silently lost, and affine units (Celsius) fit
naturally because a unit is free to define _any_ pair of conversion callables — but
every function over lengths must template over the unit, and "same dimension" becomes
a graph-reachability query instead of a type-equality test.

---

## How it works

### `quantities` — a dimension vector as a template _value_ parameter

The core datatypes are ordinary structs, built and compared **by CTFE**, not by
template type-list arithmetic ([`internal/dimensions.d`][dims] L200–205, L325–336):

```d
// quantities: source/quantities/internal/dimensions.d (abridged)
struct Dim
{
    string symbol;             /// The symbol of the dimension
    Rational power;            /// The power of the dimension
    size_t rank = size_t.max;  /// The rank of the dimension in the vector
}

struct Dimensions
{
    private immutable(Dim)[] _dims;   // kept sorted by (rank, symbol)
    // opBinary!"*" / "/" merge-sort the vectors; pow/powinverse scale exponents
}
```

`Rational` is a normalized `int` pair with gcd reduction
([`internal/dimensions.d`][dims] L21–65). The quantity type then takes the whole
vector as an `alias` value parameter and enforces the zero-overhead representation in
its own definition ([`compiletime.d`][ct] L124–146):

```d
// quantities: source/quantities/compiletime.d (abridged)
struct Quantity(N, alias dims)
{
    static assert(isNumeric!N);
    static assert(is(typeof(dims) : Dimensions));
    static assert(Quantity.sizeof == N.sizeof);   // the zero-cost claim, in-source

private:
    N _value;

    void ensureSameDim(const Dimensions d)() const
    {
        static assert(dimensions == d,
                "Dimension error: %s is not consistent with %s".format(dimensions, d));
    }
    // ...
    auto opBinary(string op, Q)(auto ref const Q qty) const
            if (isQuantity!Q && (op == "*" || op == "/"))
    {
        alias RQ = Quantity!(N, mixin("dimensions" ~ op ~ "Q.dimensions"));
        return RQ.make(mixin("_value" ~ op ~ "qty._value"));
    }
}
```

Multiplication literally evaluates `dimensions * Q.dimensions` — a CTFE merge of two
sorted arrays — and uses the resulting _value_ to name the result type. A new base
dimension is one declaration ([`compiletime.d`][ct] L493–504):

```d
// quantities: source/quantities/compiletime.d — custom base dimension
auto unit(N, string dimSymbol, size_t rank = size_t.max)()
{
    enum dims = Dimensions.mono(dimSymbol, rank);
    return Quantity!(N, dims).make(1);
}
///
unittest
{
    enum meter = unit!(double, "L", 1);
    enum kilogram = unit!(double, "M", 2);
    // Dimensions will be in this order: L M
}
```

The whole SI layer is a mixin template parameterized by the numeric type
([`internal/si.d`][si-q] L17–41: `mixin template SIDefinitions(N)` defining
`meter = unit!(N, "L", 1)` … `candela = unit!(N, "J", 7)`, all derived units, all
prefixes, plus the parser and formatter); [`si.d`][si-q-top] instantiates it once as
`mixin SIDefinitions!double;`. `QVariant!N` ([`runtime.d`][rt] L138–156) is the same
struct with `Dimensions _dimensions` demoted to a runtime field and every
`static assert` replaced by
`enforce(_dimensions == dim, new DimensionException(...))`.

The parser is the same code in both worlds: `SymbolList!N` maps symbol strings to
`QVariant`s and prefix factors ([`parsing.d`][parsing] L22–56), and the `si!` template
simply runs that runtime parser **in CTFE** and freezes the result into a typed
constant ([`internal/si.d`][si-q] L254–259):

```d
// quantities: source/quantities/internal/si.d — one grammar, two phases
template si(string str)
{
    enum ctSIParser = Parser!(N, (ref s) => parse!N(s))(siSymbolList);
    enum qty = ctSIParser.parse(str);              // CTFE-executed runtime parser
    enum si = Quantity!(N, qty.dimensions())(qty); // type derived from parsed dims
}
```

### `std.units` / `units-d` — units as canonicalized types

Every unit is a struct that mixes in `UnitImpl` (operator sugar + a marker alias);
a bare base unit is one line ([`units.d`][units-d-file] L257–270):

```d
// nadlinger-std-units: units.d — base units and derived-unit normal form
// (abridged; gathered from L257, L304, L351)
struct BaseUnit(string name, string symbol = null) { mixin UnitImpl; /* toString */ }

struct BaseUnitExp(B, R) if (!isDerivedUnit!B && isUnit!B && isRational!R)
{
    alias B BaseUnit;
    alias R Exp;
}

template DerivedUnit(T...) if (allSatisfy!(isBaseUnitExp, T))
{
    alias MakeDerivedUnit!(T).Result DerivedUnit;
}
```

`DerivedUnit` computes a **normal form**: the `BaseUnitExp` list is sorted by the
_mangled name_ of each base-unit type, adjacent exponents of the same base are summed,
zero exponents pruned, and a single-unit-to-the-power-one list collapses to the bare
unit ([`CanonicalizeBaseUnitExps`][units-d-file], `units.d` L490–540). Type equality
of normal forms then _is_ unit equality — the same
[template-normal-form mechanism][mechanisms] as [Boost.Units][boost], five years
early. Exponents are rationals canonicalized **at the type level** by gcd-recursion,
so `Rational!(6, 3u)` and `Rational!2` are literally the same type
([`units.d`][units-d-file] L1894–1907):

```d
// nadlinger-std-units: units.d — type-level rationals with gcd canonicalization
template Rational(int n, uint d = 1u) {
    static if (gcd(cast(uint)abs(n), d) > 1) {
        alias Rational!(n / cast(int)gcd(...), d / gcd(...)) Rational;
    } else {
        struct Rational {
            enum int numerator = n;
            enum uint denominator = d;
        }
    }
}
```

A quantity is `Quantity!(Unit, ValueType = double)` with a single `value` field
([`units.d`][units-d-file] L634, L987). Scaling, affine offsets and prefixes are unit
_constructors_ that attach a `Conversions` alias — a list of
`Conversion!(TargetUnit, toFunc, fromFunc)` links whose converter callables are
arbitrary (they need not be CTFE-able; a unit test scales by a **global runtime
variable**, [`units.d`][units-d-file] L1509–1521):

```d
// nadlinger-std-units: units.d — ScaledUnit stores no value transformation,
// only a conversion edge to its base unit
struct ScaledUnit(BaseUnit, alias toBaseFactor, string name, string symbol = null)
{
    mixin UnitImpl;
    alias TypeTuple!(Conversion!(BaseUnit, toBase, fromBase)) Conversions;
    static V toBase(V)(V v)   { return cast(V)(v * toBaseFactor); }
    static V fromBase(V)(V v) { return cast(V)(v / toBaseFactor); }
}
```

`convert!target(quantity)` triggers `GetConversion`, a compile-time **depth-first
search** over that graph: it decomposes both units into `BaseUnitExp` lists, tries
substituting each base unit by each of its conversion targets (raising the converter
to the exponent's power via `PowerConvFunc`), recurses, and if forward search fails
retries from the target side (`tryReverse`) ([`units.d`][units-d-file] L1310–1416;
same algorithm in [`units-d/package.d`][pkg-u] L1404–1507, whose README still lists
"Refactor `GetConversion` to do a breadth-first search instead of current depth-first"
as an open task). Multi-hop chains compose:
`static assert(convert!microfoo(1L * megafoo) == 10L^^12 * microfoo)` walks
MicroFoo→MilliFoo→Foo←KiloFoo←MegaFoo at compile time
([`units.d`][units-d-file] L1523–1532).

The SI module builds the periodic table from these pieces — with two choices worth
noting: the mass base unit is **`gram`**, `kilogram` being `kilo!gram`
([`si.d`][si-n] L54, L68), and `radian`/`steradian` are honest **base units**, not 1
([`si.d`][si-n] L59–60, L78–79).

---

## Dimension representation

The two designs sit at opposite corners of the representation taxonomy:

| Aspect             | `quantities`                                                                              | `std.units` / `units-d`                                                                          |
| ------------------ | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Dimension carrier  | CTFE **value**: sorted `immutable(Dim)[]` of (`symbol`, `Rational` power, `rank`) triples | **No dimension concept at all** — a canonicalized type-level list of (base-unit, `ℚ`-exponent)   |
| Base-dimension set | Open: any `string` symbol mints one (`unit!(double, "C")` for currency)                   | Open: any `BaseUnit!(name, symbol)` instantiation (or any struct with `mixin UnitImpl`)          |
| Exponents          | `ℚ` — `Rational` struct (`int num`/`int den`, gcd-normalized, [`dims`][dims] L21–65)      | `ℚ` — `Rational!(int, uint)` template, gcd-canonicalized to unique types ([L1894][units-d-file]) |
| Identity test      | CTFE array equality of `Dimensions` values                                                | Type equality of `DerivedUnit` normal forms; _same dimension_ = convertibility (graph search)    |
| Vector ordering    | Explicit `rank` field (SI ranks 1–7 hard-coded, [`internal/si.d`][si-q] L33–40)           | Sort key = `mangledName` of the base-unit type ([`units.d`][units-d-file] L490–540)              |

Both are [free-abelian-group][fag] representations over an open generator set; neither
is a fixed-length ISQ vector like [`uom`][rust-uom]'s or [F#][fsharp]'s erased
measures. The `quantities` choice of a template **value** parameter (rather than a
type list) is the distinctive D move: D permits arbitrary struct values as template
parameters, so the entire group operation is plain runtime-looking code executed by
CTFE — no `staticMap`, no recursion-depth games. The cost is that the vector's value
_is_ part of the mangled type name (see [Diagnostics](#diagnostics)).

Nadlinger's mangled-name sort key is clever but subtle: canonical order is an
implementation artifact of symbol mangling, not anything semantic — fine for identity,
meaningless for display order.

## Checking & inference

**Checking is template normal-form equality, at instantiation, in both designs.**
There is no unification, no constraint solving, and no inference of unit variables:
D's templates — like C++'s — type-check each _instantiation_, so the checking
algorithm is (a) compute the normal form (CTFE array merge, or `DerivedUnit`
canonicalization), (b) compare for equality (`static assert(dimensions == d)` /
overload-constraint match on the same `Unit`), (c) fail the instantiation otherwise.
`convert!` adds the one nontrivial procedure: the `GetConversion` DFS, which
terminates on the acyclic conversion DAGs real unit systems form but performs
redundant work (the depth-first order "may lead to unnecessary conversions in cases
such as newton -> milli(newton)", [`package.d`][pkg-u] L1424–1426) and has no
occurs-check-style cycle guard.

**Dimensional polymorphism is expressible — per instantiation, without principal
types.** A generic `sqr : α → α²` is a one-line template in either design, because the
return type is _computed_, not unified:

```d
// quantities: source/quantities/compiletime.d L519-530 (shipped as square/sqrt)
auto square(Q)(auto ref const Q quantity) if (isQuantity!Q)
{
    return Quantity!(Q.valueType, Q.dimensions.pow(2)).make(quantity._value ^^ 2);
}

auto sqrt(Q)(auto ref const Q quantity) if (isQuantity!Q)
{
    return Quantity!(Q.valueType, Q.dimensions.powinverse(2)).make(std.math.sqrt(quantity._value));
}
```

Nadlinger's `si.d` demonstrates value-type-polymorphic, unit-fixed signatures
(`Quantity!(mole, V) idealGasAmount(V)(Quantity!(pascal, V) …)`,
[`si.d`][si-n] L111–118). What is _not_ expressible is Kennedy-style inference: no
compiler-invented unit variables, no principal type for
`fun mean xs = sum xs / length xs`, and errors surface at instantiation depth rather
than at definition site. Contrast [Kennedy's type system][kennedy] and its
[uom-plugin][uom-plugin] transplant; this per-instantiation regime is exactly the
C++-family cell of [type-system mechanisms][mechanisms].

**`QVariant` moves the same check to run time.** `checkDim` is an `enforce` against
the stored vector ([`runtime.d`][rt] L146–150) — the [Pint][pint]-style open-world
regime, in the same library, with `Quantity ↔ QVariant` conversions checked at the
boundary (`this(Q)(auto ref const Q qty) if (isQVariant!Q)` re-checks dimensions and
throws, [`compiletime.d`][ct] L177–185).

## Extensibility

**`quantities`.** New base dimension = one `unit!(N, "symbol", rank)` call; new
_unit_ = any scalar multiple of existing quantities (`enum inch = 2.54 * centi(meter)`);
new prefix = `alias few = prefix!2` ([`common.d`][common] L8–24). A whole parallel
system with its own parser fits in a unit test — the pinned clone's
[`tests/fake_units_tests.d`][fake] builds an apples/cookies/movies economy with emoji
symbols:

```d
// quantities: tests/fake_units_tests.d (abridged)
auto apple = unit!int("Apple");
auto cookie = unit!int("Cookie");
auto movie = unit!int("Movie");
alias few = prefix!2;

auto symbols = SymbolList!int().addUnit("🍎", apple).addUnit("🍪", cookie)
        .addUnit("🎬", movie).addPrefix("🙂", 2).addPrefix("😃", 100);
auto parser = Parser!int(symbols);
assert(few(cookie) / movie == parser.parse("🙂🍪/🎬"));
```

The `SIDefinitions!N` mixin makes the entire SI layer numeric-type-generic, but note
the granularity: you instantiate a whole _system_ per numeric type, not per quantity.
Interop between systems is automatic as long as symbols and ranks agree — and silently
wrong if two systems reuse a symbol for different things (identity is stringly-typed).

**`std.units` / `units-d`.** New base unit = `BaseUnit!("foo", "f")`; scaled/affine
units via `scale!`/`affine!`; a prefix system is data — `PrefixSystem!(10, { return
[Prefix(3, "kilo", "k"), …]; })` — from which `DefinePrefixSystem` generates the
`kilo!`, `milli!`, … templates ([`si.d`][si-n] L27–50). `PrefixedUnit` even folds
`milli(kilo(metre))` back to `metre` ([`units.d`][units-d-file] L1536–1546). Because
any struct with `mixin UnitImpl` is a unit, a fully custom unit with a hand-written
conversion table is a first-class citizen ([`units.d`][units-d-file] L93–117, the
`Inch` example). Scoping is D's module system, with one deliberate restriction
([`units.d`][units-d-file] L119–122): two existing units "can't be retroactively
extended with a direct conversion between them… as it would break D's
modularization/encapsulation approach" — no orphan conversions; bridging requires a
third unit convertible to both.

## Expressiveness edges

- **Fractional powers — yes, in both designs, and honestly `ℚ`.** `quantities` ships
  `sqrt`/`cbrt`/`nthRoot` via `Dimensions.powinverse` ([`compiletime.d`][ct]
  L526–559); `std.units` proves `PowerUnit!(DerivedUnit!(BaseUnitExp!(Foo,
Rational!(-2))), Rational!(1, 4u))` is `Foo^(-1/2)` in a unit test
  ([`package.d`][pkg-u] L1257–1259). Converting _across_ a fractional power is where
  it frays: `PowerConvFunc` for a non-integer exponent resorts to
  `func(v ^^ denominator) ^^ (1.0 / denominator)` ([`units.d`][units-d-file]
  L1405–1416) — floating-point round-tripping with an in-source `@@BUG@@` comment on
  the exponent-sign assert.
- **Affine quantities — the sharpest divergence.** `std.units` has a real
  [torsor][torsor]: `AffineUnit` only defines point−point and point±vector operations,
  with the doc comment spelling out the geometry ([`package.d`][pkg-u] L632–638): "an
  affine space is a vector space which »forgot« its origin… a quantity of an affine
  unit cannot be added to another…, but… a quantity of the underlying base unit can
  be. Also, two affine quantities can be substracted to yield a quantity of the base
  unit". `Quantity` statically switches off the vector-space operators when the unit
  has a `LinearBaseUnit` ([`package.d`][pkg-u] L756–759). **`quantities` has no affine
  story at all — worse, it hard-codes the trap:** `enum celsius = kelvin;`
  ([`internal/si.d`][si-q] L58), so `20 * celsius` _is_ 20 K and `°C`-as-offset is
  unrepresentable. Neither `si.d` actually wires Celsius up to `AffineUnit` either
  (`units-d` [`si.d`][si-u] L94–95 leaves `// TODO Celsius: Use AffineUnit`); the
  machinery exists, the SI layer never used it.
- **Logarithmic quantities (dB, Np) — absent from all three.** No level types, no
  reference-point encoding, nothing. This is a finding: D prior art offers no
  precedent for the hardest expressiveness tier.
- **Angles — opposite choices, both defensible.** `quantities`:
  `enum radian = meter / meter` ([`internal/si.d`][si-q] L43) — an angle is
  dimensionless, so degrees/radians confusion type-checks. This bothered readers
  immediately; Nordlöw in the [RFC thread][rfc] (2014-02-26): "I know what angles are
  but I have never seen them defined like this before! … What on earth does this
  mean?". `std.units`/`units-d`: `radian` and `steradian` are **base units**
  ([`si.d`][si-n] L59–60), and `units-d` gates trigonometry on convertibility —
  `auto sin(Q)(Q angle) if (Q.init.isConvertibleTo!radian)` ([`si.d`][si-u]
  L104–109) — anticipating the SI-brochure-defying but bug-catching choice
  [Boost.Units][boost] made with its `plane_angle` base dimension.
- **Kind vs dimension — conflated in both designs.** `hertz` and `becquerel` are the
  same type (`quantities` [`internal/si.d`][si-q] L45, L61; `std.units` [`si.d`][si-n]
  L84, L99 — both `dimensionless / second`), `gray = sievert`, and torque = energy.
  Ironically the conversion-graph design could have distinguished them for free (mint
  `Hz` and `Bq` as distinct base units with conversions only where meaningful — the
  same fiat that saved angles), but the shipped SI layer didn't. No D artifact has
  anything like [mp-units][mp-units]' `quantity_spec` kind hierarchy.
- **Output fidelity.** `quantities` cannot print a unit: normalization discards it, so
  `toString` emits the raw vector — `"5.945e-05 [M]"` — and the README concedes "no
  simple algorithm is capable of guessing the relevant unit"; you must name a target
  via `siFormat!"%.1f mg"`. `std.units` preserves the source unit and prints
  `"1 kilo<metre per second>"`-style names, but has **no named derived units**
  (Nadlinger, [RFC thread][rfc], 2011-04-16: "currently, there is no way you could
  enable (kilogram \* metre / pow!2(second) to be printed as »Newton«").

## Zero-cost story

**`quantities` asserts its representation in-source**: `static
assert(Quantity.sizeof == N.sizeof)` is part of the struct definition
([`compiletime.d`][ct] L128), and the README claims codegen parity: "With
optimizations on, the compiler generates the same code as if normal numeric values
were used" — plausible for a single-`double` wrapper with forwarding operators, but
undocumented by any benchmark in the repo (the `dub.sdl` declares a `benchmark`
configuration whose `bench/` source directory does not exist at the pinned SHA).
`QVariant` is the opposite by design: every value drags a GC-managed
`immutable(Dim)[]`, every multiplication allocates a fresh merged vector
(`insertSorted` calls `.dup`/`insertInPlace`, [`internal/dimensions.d`][dims]
L265–316), and the API is neither `@nogc` nor `nothrow`.

**`std.units` is a single-field struct** (`ValueType value;`,
[`units.d`][units-d-file] L987) with no runtime dimension data anywhere;
`static assert((1.0 * metre).sizeof == double.sizeof)` and
`static assert(Quantity!(newton, float).sizeof == float.sizeof)` both pass
[reproduced locally, `ldc2` 1.41.0, 2026-07-03]. Its _conversion_ codegen is
self-confessedly unoptimized — the header TODO list includes "Replace the
proof-of-concept unit conversion implementation with an optimized one – currently some
unneeded function calls are generated" and "Benchmark quantity operations vs. plain
value type operations" ([`units.d`][units-d-file] L44–48): `GetConversion` composes
per-hop lambdas with `std.functional.compose`, relying on the inliner to collapse the
tower. No benchmark ever existed in any of the three repos.

## Diagnostics

All three mismatch errors below are **[reproduced locally, `ldc2` 1.41.0 (DMD
v2.111.0 front end), 2026-07-03]** against the pinned clones, compiling a
metres-plus-seconds program with `-I` pointing at each source tree.

**`quantities`, compile time** — the `ensureSameDim` static assert speaks dimensional
language first, then the instantiation trace exposes the CTFE-value-in-type encoding:

```text
source/quantities/compiletime.d(144): Error: static assert:  "Dimension error: [L] is not consistent with [T]"
        static assert(dimensions == d,
        ^
source/quantities/compiletime.d(326):        instantiated from here: `ensureSameDim!(Dimensions([Dim("T", Rational(1, 1), 3LU)]))`
mismatch.d(10):        instantiated from here: `opBinary!("+", Quantity!(double, Dimensions([Dim("T", Rational(1, 1), 3LU)])))`
```

The first line is excellent — `[L]` vs `[T]` is exactly the mismatch. The type names
below it (`Quantity!(double, Dimensions([Dim("T", Rational(1, 1), 3LU)]))`) show the
price of value-parameter dimensions: every diagnostic and mangled symbol carries the
full struct literal.

**`quantities`, run time** — the `QVariant` twin throws
(`mass + qVariant(1.0 * meter)`):

```text
quantities.runtime.DimensionException@source/quantities/runtime.d(149): Incompatible dimensions
```

(The exception object carries `thisDim`/`otherDim` fields, [`runtime.d`][rt]
L102–118, but the default message does not print them.)

**`std.units` @ `4a7279a`** — mismatched addition is an overload-resolution failure,
the classic template-library wall of candidates:

```text
mismatch_n.d(5): Error: none of the overloads of template `std.units.Quantity!(BaseUnit!("metre", "m"), double).Quantity.opBinary` are callable using argument types `!("+")(Quantity!(BaseUnit!("second", "s"), double))`
    auto oops = 1.0 * metre + 1.0 * second;
                ^
std/units.d(727):        Candidates are: `opBinary(string op, RhsV)(Quantity!(Unit, RhsV) rhs)`
std/units.d(756):                        `opBinary(string op, T)(T rhs)`
  with `op = "+", T = Quantity!(BaseUnit!("second", "s"), double)`
  must satisfy one of the following constraints:
`       op == "*"
       op == "/"`
[... four more opBinary candidates elided ...]
```

The unit names are at least legible inside the type names. Where Nadlinger _did_
control the diagnostic he did it well — an unconvertible `convert!second(1.0 * metre)`
hits a hand-written `pragma(msg)` ([`units.d`][units-d-file] L1238–1240):

```text
Error: No conversion from 'metre' to 'second' could be found.
std/units.d(1240): Error: static assert:  `false` is false
```

`units-d` @ `9589ac9` produces the same two shapes with `experimental.units`
module paths (also reproduced locally).

## Ergonomics & compile-time cost

**Declaration overhead.** `quantities` is the terser system by a wide margin: a
working program is `import quantities.compiletime; import quantities.si;` plus
arithmetic on ready-made constants, with `si!"…"` string literals for anything
exotic, and `alias Speed = typeof(meter / second)` for signatures. The
`std.units` design needs unit types in every generic signature
(`Quantity!(pow!3(meter), V)`) and explicit `convert!` calls at every unit boundary —
safer, noisier.

**Compile-time cost is a non-issue at this scale** [measured locally, `ldc2` 1.41.0,
2026-07-03, front-end-only `-o-` builds of each full library + the unittests that
compile]: Nadlinger `std.units`+`std.si` 0.15 s (without `-unittest` — `std.si`'s
unittest no longer compiles, see below); `units-d` 0.25 s; `quantities` (all six
modules, including CTFE-parsing tests) 0.36 s; a full compile-link of a small
`quantities` program ≈ 1.2 s. Against the minutes-scale numbers of the C++ pages
([Boost.Units][boost], [mp-units][mp-units]) this is two orders of magnitude —
partly D's front end, partly the fact that CTFE array merges are cheaper than
SFINAE-era type-list arithmetic.

**Current compilability — the headline finding of this page** [all reproduced
locally, `ldc2` 1.41.0, 2026-07-03]:

| Artifact                       | Compiles?                           | Own tests                                                                                                           |
| ------------------------------ | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `quantities` @ `3cb3205`       | Yes; `-de` clean for library code   | **All 6 modules pass** under `-unittest`; only warnings are deprecated `approxEqual` calls inside its own doc-tests |
| `units-d` @ `9589ac9`          | Yes; `-de` clean                    | `experimental.units` passes; **`experimental.units.si` FAILS at runtime** (`si.d:147`, see below)                   |
| `std.units` @ `4a7279a` (2011) | **Yes — unmodified, zero warnings** | `std.units` passes all its unittests; **`std.si`'s unittest FAILS to compile** (`si.d:130`, see below)              |

Two surprises. First, the 1992-line `units.d` that Nadlinger pushed in December 2011
— `alias TypeTuple!(…) Conversions;`-era syntax, `std.typetuple`, workarounds for
long-fixed DMD bugs still commented `@@BUG@@` — compiles **without a single edit and
passes its whole test suite on a 2026 compiler**. Fifteen years of D language
evolution (and this survey's expectation of bit-rot) notwithstanding, the old alias
syntax and `std.typetuple` remain legal; the proposal did not die of language drift.
Its companion `std.si` is the one casualty: under `-unittest`, `si.d:130`'s
`static assert(n == 0xb.dd95ef4ddcb82f7p-59 * mole)` — a 2011 hex-float exactness
check on a CTFE gas-law computation — now fails to compile, identically under `ldc2`
1.41.0 and `dmd` 2.112.1 (without `-unittest` the module builds clean).
Second, the _modernized_ fork broke in its own, new way: `units-d`'s HEAD commit
(2021-03-13, "Replace approxEqual with isClose") mechanically swapped `approxEqual`
for `isClose` in [`si.d`][si-u], and `assert(isClose(sin(PI*radian), 0))` (L147) now
fails **at runtime** — `isClose` against a zero reference uses a default absolute
tolerance of `0.0`, so `sin(π) ≈ 1.2e-16` no longer "equals" zero. (Tellingly,
Nordlöw had already commented out the 2011 hex-float assert — `units-d` `si.d:210` —
only to plant a float-comparison failure of his own.) The port's final commit broke
its own test suite in a way its author evidently never ran.

**API-ergonomics history.** The [RFC thread][rfc] captures early usability data:
within three days a reviewer found `enum foo = metre / 2;` failing to compile on
integer negative powers ("cannot raise int to a negative integer power" — fixed the
same day with the `(rhs ^^ 0) / rhs` idiom that survives
at [`units.d`][units-d-file] L170–172 — with Nadlinger warning the reporter that
`int` value-type inference made the result `0 * metre` anyway), and Nadlinger
flagged, presciently, that template constraints "lose the ability to specify helpful
error messages (which is somewhat important as the underlying types can be quite
complex)".

**Why `std.units` stalled — the community-history finding.** The thread is the whole
record. 2011-04-12: Nadlinger frames the RFC as pre-review — "even if we should come
to the conclusion that we really want something like this in Phobos, this is not a
formal review request yet. There are still a couple of items left on my to-do list,
but I'd like to get some feedback first." Reception was warm (Simen Kjaeraas,
2011-04-15: "All in all, it seems a high-quality submission, and I'm prepared to vote
for its inclusion in Phobos."). Then nothing: the to-do items never got finished, no
formal review was ever requested, and the next post is Nordlöw's 2014-02-26 "Is
somebody waiting for this to be reviewed?" — answered not with a review but with a
pointer to the by-then-existing `biozic/quantities` ("Tangentially related"). Pings
recur in 2015; a long 2016 revival (Nordlöw, Schadek, Nadlinger, Andrei Alexandrescu
among the posters, per the thread index) ends 2016-03-30 — the very day
`nordlow/units-d` gets its initial commit, moving the code out of the Phobos queue
into a personal repo under `experimental.units`, where it received 15 commits and
stopped. Phobos never got a units module; the artifact outlived the process that was
supposed to absorb it. For a sparkles library the lesson is procedural as much as
technical: the design survived fifteen years of compilers, but "feedback first, formal
review later" meant later never came.

## Strengths

- **`quantities`: the CTFE-value dimension vector is the most D-native encoding in
  this survey** — group operations are ordinary code, not type-level recursion; the
  first error line reads `[L] is not consistent with [T]`; the whole library is 2.8
  KLOC and front-end-compiles in a third of a second.
- **`quantities`: one grammar, three phases.** The same parser handles `si!"…"`
  (CTFE → static type), `parseSI!Length(str)` (run time → checked static type) and
  `parseSI(str)` (run time → `QVariant`) — compile-time and runtime worlds share
  symbols, prefixes and semantics by construction. No other system in this survey
  gets string-defined units into the _static_ type system this cheaply.
- **`quantities`: graduated checking.** `Quantity`/`QVariant` interconvert with
  boundary checks — the [Pint][pint]-style open world and the [F#][fsharp]-style
  closed world in one library.
- **`std.units`: a real affine-unit type** with torsor-correct operator gating, in
  2011 — earlier than any other statically-checked system surveyed here except
  [Boost.Units][boost]' `absolute<T>`.
- **`std.units`: no-silent-conversion discipline.** Values are never re-based;
  `1 * kilo(metre) + 1 * metre` refuses to compile until you say `convert!` — the
  bit-exactness stance [Unitful.jl][unitful] and [Au][au] later made mainstream.
- **`std.units`: conversions as arbitrary callables** (even closing over runtime
  state) — a generality point none of the C++/Rust template systems match.
- **Longevity for free:** all three artifacts compile on a 2026 toolchain untouched;
  `quantities` passes its full suite, and both Nadlinger-lineage core modules pass
  theirs — only the two SI layers' float-comparison tests fail.

## Weaknesses

- **Both designs conflate kinds with dimensions** — `Hz = Bq`, `Gy = Sv`,
  torque = energy — and `quantities` additionally makes angles vanish
  (`radian = meter/meter`) and Celsius a lie (`celsius = kelvin`).
- **No logarithmic quantities anywhere;** no named derived units in `std.units`; no
  unit-faithful printing in `quantities` (normalization discards the source unit).
- **No inference.** Per-instantiation template checking only; a mistyped generic
  bubbles up as an instantiation trace or a six-candidate overload dump, not a
  measure-variable unification error at the definition site (contrast
  [Kennedy][kennedy]).
- **`QVariant` costs are structural:** GC allocation on every dimension-changing
  operation, stringly-typed dimension identity, no `@nogc`/`nothrow` anywhere in the
  library — disqualifying for the allocation-conscious half of a 2026 D codebase as-is.
- **`GetConversion` is a compile-time DFS with acknowledged redundancy** and no
  cycle-guard discipline; `units-d`'s own task list still carries the BFS refactor,
  the integer-precision `ScaledUnit` bug and the Fahrenheit `LinearUnit` as TODOs.
- **All three are dead.** `quantities` last commit 2020-01-27 (an LDC compatibility
  patch), `units-d` 2021-03-13 (the commit that broke its own test), `std.units`
  2011-12-10. There is no maintained units library in the D ecosystem in 2026.

## Key design decisions and trade-offs

| Decision                                                                      | Rationale                                                                                                               | Trade-off                                                                                                                                                                                           |
| ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `quantities`: dimensions as a CTFE struct **value** in a template parameter   | Group arithmetic is ordinary code run by CTFE; open generator set; readable first-line errors                           | The full struct literal lands in every mangled name and diagnostic; identity is stringly-typed (symbol + rank); per-numeric-type SI instantiation via mixin                                         |
| `quantities`: normalize to base units at construction                         | Same dimension ⇒ same type; mixed-prefix arithmetic just works; non-template APIs (`Time calculateTime(Length, Speed)`) | Binary representation lost for non-base units; source unit unrecoverable at output; affine/offset units unrepresentable — `celsius = kelvin` is the smoking gun                                     |
| `quantities`: `QVariant` runtime twin sharing the API                         | Config-file/user-input units; gradual typing between worlds                                                             | Doubled API surface; GC + exceptions; the compile-time guarantees end wherever a `QVariant` enters                                                                                                  |
| `quantities`: one parser for CTFE and run time                                | `si!"…"` literals with zero extra machinery; guaranteed CT/RT semantic agreement                                        | Parser lives on the type-checking path; exceptions/GC in the shared code keep it out of `@nogc` territory                                                                                           |
| `std.units`: units as types, **no dimension concept**, convertibility instead | Affine & irregular units are just conversion edges; no canonical basis to distort values; kinds distinguishable by fiat | "Same dimension?" becomes graph search (DFS, superlinear, unoptimized); every generic function templates over units; the shipped SI layer never used the fiat (Hz = Bq anyway)                      |
| `std.units`: type-level `ℚ` exponents via gcd-canonicalized `Rational!(n, d)` | Fractional dimensions with type identity, in 2011, with nothing but templates                                           | Fractional-power _conversion_ degrades to floating-point round-trips (`PowerConvFunc`); `std.typetuple` machinery is verbose by 2026 standards (D now has CTFE-friendlier tools — see `quantities`) |
| `std.units`: conversions are arbitrary callables attached per unit type       | Runtime-valued factors, exotic mappings, no closed-world assumption; no orphan conversions (module-system discipline)   | Conversions not guaranteed CTFE-able; codegen quality left to the inliner (in-source TODO admits unoptimized output)                                                                                |
| Nadlinger 2011: "feedback first, formal review later"                         | Honest pre-review; avoid burning the one Phobos review slot on an unfinished module                                     | Later never came: no owner, no deadline, 5 years of pings, fork-and-fade. A sparkles library should land as a normal versioned sub-package, not wait on an ecosystem-blessing process               |

For a 2026 sparkles design the synthesis is direct: the `quantities` _mechanism_
(CTFE value-level dimension vectors — now expressible even more cleanly with modern
D) with the `std.units` _semantics_ where they are stronger (affine units, explicit
conversion, kind-mintable base units), minus both libraries' non-negotiables for this
codebase: the GC-bound `QVariant` core and the exception-based runtime path would
need an [`Expected`-style][mechanisms] `@nogc` re-imagining, and every template here
predates `-preview=dip1000`/`-preview=in` scope discipline. That delta belongs to —
and is drawn in — the [comparison capstone][comparison].

## Sources

- [biozic/quantities — GitHub repository][repo-q] (pinned locally at
  `$REPOS/dlang/quantities` @ `3cb3205`, 2020-01-27, = tag `v0.11.0`)
- [`README.md` — design rationale: CT/RT checking, unit=quantity, base-unit normalization and its consequences][readme-q]
- [`source/quantities/internal/dimensions.d` — `Rational`, `Dim`, `Dimensions` (the CTFE dimension vector)][dims]
- [`source/quantities/compiletime.d` — `Quantity!(N, dims)`, `sizeof` static assert, `ensureSameDim`, `unit!`, `square`/`sqrt`/`nthRoot`][ct]
- [`source/quantities/runtime.d` — `QVariant`, `DimensionException`][rt] · [`source/quantities/parsing.d` — `SymbolList`, `Parser`][parsing]
- [`source/quantities/internal/si.d` — `SIDefinitions!N`: base units + ranks, `celsius = kelvin`, `radian = meter/meter`, `si!` CTFE parsing, `siFormat`][si-q] · [`source/quantities/si.d`][si-q-top] · [`source/quantities/common.d` — `prefix`][common]
- [`tests/fake_units_tests.d` — custom apples/cookies/movies system with emoji parser symbols][fake]
- [nordlow/units-d — GitHub repository][repo-u] (pinned locally at
  `$REPOS/dlang/units-d` @ `9589ac9`, 2021-03-13; created 2016-03-30)
- [`units-d/README.md` — "modified version of David Nadlinger's original library" + modernization task list][readme-u]
- [`src/experimental/units/package.d` — the modernized core: `UnitImpl`, `DerivedUnit` canonicalization, `AffineUnit` torsor docs, `GetConversion` DFS][pkg-u]
- [`src/experimental/units/si.d` — SI layer, `isConvertibleTo!radian`-gated trig, Celsius TODO, the failing `isClose` assert (L147)][si-u]
- [dnadlinger/phobos `units` branch — the `std.units` proposal][repo-n] (pinned raw
  `units.d` + `si.d` @ `4a7279a`, 2011-12-10, at `$REPOS/dlang/nadlinger-std-units`)
- [`units.d` — module header (design philosophy), `BaseUnit`/`BaseUnitExp`/`DerivedUnit`, `Rational!(n,d)`, `ScaledUnit`, `AffineUnit`, `PrefixSystem`, `GetConversion`, `PowerConvFunc`][units-d-file]
- [`si.d` — gram-based SI, radian/steradian as base units, compile-time `convert!` static asserts][si-n]
- ["RFC: Units of measurement for D (Phobos?)" — digitalmars.D thread, 2011-04-12 → 2016-03-30][rfc] (local capture
  `$REPOS/dlang/nadlinger-std-units/rfc-units-of-measurement-forum-thread.html`) · [Nadlinger's `std.units` project page][klickverbot] (local capture `klickverbot-std-units-page.html`)
- [dub registry: quantities][dub-q] · [dub registry: units-d][dub-u] · [quantities rendered DDoc][docs-q]
- Local reproductions (both mismatch errors, `DimensionException`, no-conversion
  `pragma(msg)`, unittest runs for all three artifacts, `sizeof` asserts, compile
  timings): scratch workspace against the pinned clones, `ldc2` 1.41.0 (DMD v2.111.0
  front end, LLVM 18.1.8), 2026-07-03
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [Kennedy's type system][kennedy] · [free abelian group][fag] ·
  [torsors & affine quantities][torsor] · [F# units of measure][fsharp] ·
  [`uom-plugin`][uom-plugin] · [`uom` (Rust)][rust-uom] ·
  [`dimensioned`][dimensioned] · [Boost.Units][boost] · [mp-units][mp-units] ·
  [Au][au] · [Pint][pint] · [Unitful.jl][unitful] ·
  [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone: biozic/quantities @ 3cb3205 -->

[repo-q]: https://github.com/biozic/quantities
[readme-q]: https://github.com/biozic/quantities/blob/3cb3205a53ead6af5f557523984ed52ddb625ea7/README.md
[dims]: https://github.com/biozic/quantities/blob/3cb3205a53ead6af5f557523984ed52ddb625ea7/source/quantities/internal/dimensions.d
[ct]: https://github.com/biozic/quantities/blob/3cb3205a53ead6af5f557523984ed52ddb625ea7/source/quantities/compiletime.d
[rt]: https://github.com/biozic/quantities/blob/3cb3205a53ead6af5f557523984ed52ddb625ea7/source/quantities/runtime.d
[parsing]: https://github.com/biozic/quantities/blob/3cb3205a53ead6af5f557523984ed52ddb625ea7/source/quantities/parsing.d
[si-q]: https://github.com/biozic/quantities/blob/3cb3205a53ead6af5f557523984ed52ddb625ea7/source/quantities/internal/si.d
[si-q-top]: https://github.com/biozic/quantities/blob/3cb3205a53ead6af5f557523984ed52ddb625ea7/source/quantities/si.d
[common]: https://github.com/biozic/quantities/blob/3cb3205a53ead6af5f557523984ed52ddb625ea7/source/quantities/common.d
[fake]: https://github.com/biozic/quantities/blob/3cb3205a53ead6af5f557523984ed52ddb625ea7/tests/fake_units_tests.d

<!-- Pinned clone: nordlow/units-d @ 9589ac9 -->

[repo-u]: https://github.com/nordlow/units-d
[readme-u]: https://github.com/nordlow/units-d/blob/9589ac9ccdf566134b3e2e94c7a1bcc93c6a93b4/README.md
[pkg-u]: https://github.com/nordlow/units-d/blob/9589ac9ccdf566134b3e2e94c7a1bcc93c6a93b4/src/experimental/units/package.d
[si-u]: https://github.com/nordlow/units-d/blob/9589ac9ccdf566134b3e2e94c7a1bcc93c6a93b4/src/experimental/units/si.d

<!-- Pinned artifact: dnadlinger/phobos units branch @ 4a7279a -->

[repo-n]: https://github.com/dnadlinger/phobos/tree/units
[units-d-file]: https://github.com/dnadlinger/phobos/blob/4a7279a7759495df1f8e2793fd5ccd4a3a80cd46/std/units.d
[si-n]: https://github.com/dnadlinger/phobos/blob/4a7279a7759495df1f8e2793fd5ccd4a3a80cd46/std/si.d

<!-- Official docs, registry & history -->

[docs-q]: https://biozic.github.io/quantities/quantities.html
[dub-q]: https://code.dlang.org/packages/quantities
[dub-u]: https://code.dlang.org/packages/units-d
[rfc]: https://forum.dlang.org/thread/io1vgo%241fnc%241%40digitalmars.com
[klickverbot]: https://klickverbot.at/code/units/

<!-- Same-tree theory -->

[kennedy]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[fsharp]: ./fsharp-uom.md
[uom-plugin]: ./haskell-uom-plugin.md
[rust-uom]: ./rust-uom.md
[dimensioned]: ./rust-dimensioned.md
[boost]: ./cpp-boost-units.md
[mp-units]: ./cpp-mp-units.md
[au]: ./cpp-au.md
[pint]: ./python-pint.md
[unitful]: ./julia-unitful.md
