# coulomb (Scala)

A statically-typed unit-analysis library for Scala 3 in which units are phantom
type expressions over base-unit types combined with `*`, `/`, and `^` (rational
exponent), a `Quantity[V, U]` is an [`opaque type`][opaque] equal to its raw value
`V` at runtime, and all dimensional checking runs in a `quotes.reflect` macro that
reduces any unit expression to a canonical base-unit signature at compile time.

| Field            | Value                                                                                                       |
| ---------------- | ----------------------------------------------------------------------------------------------------------- |
| Language         | Scala 3 only (`crossScalaVersions := Seq("3.3.8")`, an LTS; JDK 17)                                         |
| License          | Apache-2.0                                                                                                  |
| Repository       | [erikerlandson/coulomb][repo]                                                                               |
| Documentation    | [erikerlandson.github.io/coulomb][docsite] · [javadoc.io][javadoc]                                          |
| Key authors      | Erik Erlandson (`erikerlandson`, author/maintainer)                                                         |
| Category         | Library-level [compile-time checking][concepts] (no compiler plugin; a `inline` + `scala.quoted` macro DSL) |
| Mechanism        | `opaque type Quantity[V, U] = V`; a macro canonicalizes `U` to a `List[(baseUnitType, Rational)]` signature |
| Exponent domain  | `ℚ` — type-level `Rational` exponents (`Meter ^ (1 / 2)` is first-class), via `spire.math.Rational`         |
| Checking time    | Compile time (implicit search drives macro expansion); **zero** runtime dimensional representation          |
| Analyzed version | `681442a` (pinned clone, 2026-06-22; `tlBaseVersion := "0.9"`, post-`v0.9.1`)                               |
| Latest release   | `v0.9.1` (2025-09-03; latest on Maven Central `com.manyangled:coulomb-core_3`)                              |

> [!NOTE]
> `coulomb` is this survey's data point for **opaque-type erasure + a reflective
> canonicalization macro**: a quantity carries _no_ runtime dimension at all (it
> _is_ its underlying scalar), and compatibility is decided by a hand-written macro
> that expands both operands to base units and checks the residual cancels — not by
> the host type-checker evaluating type-level arithmetic ([uom][uom],
> [`dimensioned`][dimensioned]) nor by AG-unification ([F#][fsharp],
> [`uom-plugin`][uom-plugin]; see [Kennedy's type system][kennedy] and the
> [mechanism taxonomy][mechanisms]). Its rational type-level exponents put it beside
> [mp-units][mp-units] and [F#][fsharp] on the [free-abelian-group][fag]
> fractional-power axis. Its Scala sibling [`squants`][squants] takes the opposite
> path — runtime unit values with F-bounded compile-time safety — making the two a
> clean intra-language contrast. See the [comparison capstone][comparison].

---

## Overview

### What it solves

`coulomb` gives Scala programs dimensional analysis as a type-system discipline:
adding metres to seconds is a compile error, dividing metres by seconds _is_
`Meter / Second`, and none of it survives into the runtime representation. The
crate-root docs frame unit analysis as an extension of the type system itself
([`docs/coulomb-core.md`][coredoc] L34–56):

> "Unit analysis performs a role very similar to a type system in programming
> languages such as Scala. Like data types, unit analysis provides us information
> about what operations may be allowed or disallowed. Just as Scala's type system
> informs us that the expression `7 + false` is not a valid expression ... unit
> analysis informs us that adding `meters + seconds` is not a valid computation."

The `README.md` splash alt-text states the positioning in one line — "coulomb: a
statically typed unit analysis library for Scala" ([`README.md`][readme] L1). The
predefined-units package ships seven SI base units (`Meter`, `Kilogram`, `Second`,
`Ampere`, `Mole`, `Candela`, `Kelvin` — [`units/.../si.scala`][si] L28–53), the SI
prefixes, the US/imperial units, information units, temperature, time, physical
constants, and the historically-accepted metric units.

### Design philosophy

Two decisions define `coulomb` against the other systems in this survey.

**A quantity is its value.** `Quantity[V, U]` is declared as an
[`opaque type`][opaque] aliasing `V` ([`core/.../quantity.scala`][quantity] L64):

```scala
// coulomb: core/src/main/scala/coulomb/quantity.scala L64
opaque type Quantity[V, U] = V
```

Outside the `Quantity` object the unit `U` is a phantom that the compiler tracks
but that has no runtime footprint; inside, `withUnit` and `value` are `inline`
identity coercions (`inline def withUnit[U]: Quantity[V, U] = v` —
[`quantity.scala`][quantity] L91, L103). At runtime a `Quantity[Double, Meter]`
_is_ a `Double`. This is the same erasure story [uom][uom] achieves with
`#[repr(transparent)]` + `PhantomData`, reached instead through Scala 3's
opaque-type feature.

**Units, not quantities, are the primitive — and the checker is a macro, not the
type-checker.** Where [uom][uom] normalizes every value to a quantity's base unit
_eagerly at the boundary_, `coulomb` keeps the _unit expression_ in the type and
computes conversion coefficients lazily, at each operation, in a compile-time
macro. A unit is a type-level expression — base-unit phantom types combined with
the three operator types `*`, `/`, `^` ([`quantity.scala`][quantity] L29, L41, L55)
— and the whole dimensional theory lives in one reflective function, `cansig`,
that reduces such an expression to a canonical signature. The author calls this
"the fundamental algorithmic unit analysis criterion" and links his own write-up
of the algorithm in a source comment ([`core/.../infra/meta.scala`][meta]
L136–137).

---

## How it works

A unit type is a tree of the phantom operator types over leaves that are either
numeric literal constants (`1`, `1000`, `10 ^ 3`) or _abstract_ unit types tagged
by a `given` instance of one of three marker classes ([`core/.../define/define.scala`][define]):

- `BaseUnit[U, Name, Abbv]` — a fundamental dimension axis. `Meter`, `Second`,
  `Kilogram` are each a bare `final type` plus a `given BaseUnit` instance
  ([`si.scala`][si] L28–53; `define.scala` L43).
- `DerivedUnit[U, D, Name, Abbv]` — a unit _defined as_ another unit expression `D`
  times a coefficient. `Liter` is `DerivedUnit[Liter, (Meter ^ 3) / 1000, …]`;
  `Kilo` is `DerivedUnit[Kilo, 10 ^ 3, …]` ([`accepted.scala`][accepted],
  [`si.scala`][si] L75–77; `define.scala` L72).
- `DeltaUnit[U, D, O, Name, Abbv]` — a `DerivedUnit` carrying an additive offset `O`
  for affine scales like temperature ([`define.scala`][define] L104–113).

There is **no separate "dimension" entity**: a `BaseUnit` _is_ a dimension axis,
and a quantity's dimension is whatever base-unit signature its unit expression
reduces to.

### The canonicalization macro (`cansig`)

Every dimensional decision routes through `cansig` ([`meta.scala`][meta] L168–221),
which walks a unit `TypeRepr` and returns a coefficient plus a canonical
**signature** — a `List[(TypeRepr, Rational)]` pairing each base-unit type with its
net rational exponent. Under `SigMode.Canonical` it "yields signatures fully
expand[ed] down to base units" ([`meta.scala`][meta] L52–57): it multiplies
coefficients and _adds_ exponents across `*`, divides and _subtracts_ across `/`,
scales exponents across `^`, expands each `DerivedUnit` by recursing into its
definition, and looks up each `BaseUnit`/`DerivedUnit` leaf by an
`Implicits.search` for the corresponding `given` ([`meta.scala`][meta] L286–350):

```scala
// coulomb: core/src/main/scala/coulomb/infra/meta.scala L190-199 (abridged)
case AppliedType(op, List(lu, ru)) if (op =:= TypeRepr.of[*]) =>
    val (lcoef, lsig) = cansig(lu)
    val (rcoef, rsig) = cansig(ru)
    val usig = unifyOp(lsig, rsig, _ + _)    // multiply units => add exponents
    (lcoef * rcoef, usig)
case AppliedType(op, List(lu, ru)) if (op =:= TypeRepr.of[/]) =>
    val (lcoef, lsig) = cansig(lu)
    val (rcoef, rsig) = cansig(ru)
    val usig = unifyOp(lsig, rsig, _ - _)    // divide units => subtract exponents
    (lcoef / rcoef, usig)
```

This is the [free-abelian-group model][fag] made operational: the signature is a
finite map from base-unit generators to `ℚ` exponents, `unifyOp` is the group
operation, and cancellation to `Nil` is the identity. Two unit types are
_convertible_ iff dividing one by the other canonicalizes to the empty signature
([`meta.scala`][meta] L159–165):

```scala
// coulomb: core/src/main/scala/coulomb/infra/meta.scala L159-165
def convertible(u1: TypeRepr, u2: TypeRepr): Boolean =
    given sigmode: SigMode = SigMode.Canonical
    val (_, rsig) = cansig(TypeRepr.of[/].appliedTo(List(u1, u2)))
    rsig == Nil
```

### Coefficients and the compile error

`coef` (the coefficient the conversion multiplies by) is computed the same way, and
_it is where the rejection is raised_ ([`meta.scala`][meta] L130–145):

```scala
// coulomb: core/src/main/scala/coulomb/infra/meta.scala L130-145 (abridged)
def coef(u1: TypeRepr, u2: TypeRepr): Rational =
    if (u1 =:= u2) Rational.one
    else
        // the fundamental algorithmic unit analysis criterion:
        given sigmode: SigMode = SigMode.Canonical
        val (rcoef, rsig) = cansig(TypeRepr.of[/].appliedTo(List(u1, u2)))
        if (rsig == Nil) then rcoef
        else
            report.error(
                s"unit type ${typestr(u1)} not convertable to ${typestr(u2)}")
            Rational.zero
```

The macro is reached through implicit search: `Coefficient[V, UF, UT]` and
`UnitConversion[V, UF, UT]` are typeclasses whose `inline given` instances call the
`coefficientDouble`/`coefficientRational`/… splices, which call `coef`
([`conversion/coefficients.scala`][coeffs] L23–41; `conversion/coefficient.scala`
L60–103; `conversion/unit.scala` L68–104). If `coef` calls `report.error`, the
whole implicit resolution fails at the call site. There is a second, simplifying
signature mode: operator _output_ types (`a * b`, `a / b`, `a.pow[E]`) are built by
`SimplifiedUnit[U]`, a `transparent inline given` macro that canonicalizes in
`SigMode.Simplify` — which "does not expand derived units, and respects type
aliases" ([`meta.scala`][meta] L59–63; [`infra/simplified.scala`][simplified]
L28–40) — so `Meter * Meter` surfaces as `Meter ^ 2`, not fully expanded.

---

## Dimension representation

A dimension is a **canonical signature** — a `List[(baseUnitType, Rational)]` of
(base-unit type, net exponent) pairs — computed on demand from a unit _type
expression_ ([`meta.scala`][meta] L168–221). Three properties distinguish it from
the type-level-integer-vector systems:

- **Exponents are `ℚ`, not `ℤ`.** Each signature exponent is a
  [`spire.math.Rational`][spire]; the `^` operator type takes a type-level rational
  (`Meter ^ (1 / 2)`, `Second ^ -1`, [`quantity.scala`][quantity] L43–55), and
  `cansig` handles a rational power by `fpow` on the coefficient and `unifyPow`
  scaling on the signature ([`meta.scala`][meta] L200–213, L401–408). Half-integer
  dimensions are representable **by construction**, the direct opposite of
  [uom][uom]/[`dimensioned`][dimensioned]'s `typenum::Integer` walls.
- **The base-dimension set is open and un-fixed.** Nothing pins the number of base
  units: a signature is a sparse map, so a `BaseUnit[Scoville, "scoville", "sco"]`
  declared in three lines of user code ([`define.scala`][define] L36–42) is a new
  dimension axis on equal footing with `Meter`. There is no per-system exponent
  vector whose length must be edited (contrast [uom][uom]'s closed `system!`).
- **Normalization is by list unification with `=:=` term-matching**, not by type
  identity. `unifyOp`/`insertTerm` fold terms together when their base-unit
  `TypeRepr`s are `=:=`, dropping any that cancel to a zero exponent
  ([`meta.scala`][meta] L379–399). So "same dimension, different spelling"
  (`Meter / Second` vs `Meter * (Second ^ -1)`) canonicalizes identically — but the
  cost is that this reduction is _recomputed by the macro_ at every operation, not
  memoized in a nominal type.

Dimensionless-ness is the empty signature: `1` (and any pure numeric-constant unit)
canonicalizes to `(coefficient, Nil)` ([`meta.scala`][meta] L179–186), which is why
`Meter / Meter` and `Radian` alike reduce to unitless.

## Checking & inference

Checking is **implicit search that triggers a reflective macro** — decidable and
terminating (the macro is structural recursion over a finite type tree), never a
constraint solve. Binary `+`/`-`/comparison require the right operand be _converted_
to the left's unit, so each is defined in terms of `UnitConversion[V, UR, U]`
([`quantity.scala`][quantity] L192–196):

```scala
// coulomb: core/src/main/scala/coulomb/quantity.scala L192-196
inline def +[UR](qr: Quantity[V, UR])(using
    alg: AdditiveSemigroup[V]
): Quantity[V, U] =
    val qrv: V = UnitConversion[V, UR, U](qr)   // fails to resolve if not convertible
    alg.plus(q, qrv)
```

Because the value algebra (`AdditiveSemigroup[V]`, `MultiplicativeGroup[V]`, …) is
itself a `using` parameter from [`spire`][spire]/[`algebra`][algebra], `coulomb`
inherits Scala's ordinary term inference: `val v = d / t` infers `Quantity[Double,
Meter / Second]` without annotation, and multiplying builds the output unit via the
`SimplifiedUnit[U * UR]` macro's `su.UO` member type ([`quantity.scala`][quantity]
L236–240). What it cannot do — like every non-Kennedy system here — is _invert_
unit arithmetic: there is no principal-type generalization that would infer the
exponent of a `pow` from a desired result type.

**Dimensional polymorphism** is expressible by carrying the same context bounds the
concrete operators use. A function generic over a value type `V` and a unit `U` can
demand `SimplifiedUnit[U * U]` and a `MultiplicativeSemigroup[V]` and return
`Quantity[V, su.UO]`; unlike [uom][uom]'s seven-fold `typenum` where-clauses, the
bound is a single `SimplifiedUnit`, because the exponent arithmetic is hidden inside
the macro rather than spelled out per base symbol.

## Extensibility

Extension is uniformly "declare a `final type` and a `given`", with no macro
authoring required — the three-line pattern from the `BaseUnit` doc comment
([`define.scala`][define] L36–42) is the entire vocabulary:

- **A new base dimension** — `type Scoville; given BaseUnit[Scoville, "scoville",
"sco"] = BaseUnit()`. Immediately a full dimensional citizen; no system to edit.
- **A new derived unit** — `type Smoot; given DerivedUnit[Smoot, 67 * Inch,
"smoot", "smt"] = DerivedUnit()` ([`define.scala`][define] L63–70). The definition
  is any unit expression, so units compose transitively (`Liter` ⊂ `Meter ^ 3`,
  `Bit` ⊂ `Byte / 8` — [`info.scala`][info] L42–52).
- **A new affine unit** — a `DeltaUnit` with a rational offset (see
  [Expressiveness edges](#expressiveness-edges)).
- **Value-type genericity** — the same machinery works for any `V` with the right
  `spire`/`algebra` typeclasses in scope: `Float`, `Double`, `BigDecimal`,
  `Rational`, boxed `java.lang.Float`/`Double` have direct coefficient macros, and
  any other `V` is served by summoning `Fractional[V]` plus a
  `ValueConversion[Rational, V]` ([`conversion/coefficient.scala`][coefficient]
  L60–103). Integer value types are deliberately _not_ Fractional — see the
  truncation finding under [Diagnostics](#diagnostics).

The companion `coulomb-runtime` module bridges to _runtime_ unit analysis: a
`RuntimeQuantity[V]` pairs a value with a `RuntimeUnit` AST
(`UnitConst`/`UnitType`/`Mul`/`Div`/`Pow` — [`runtime/.../runtime.scala`][runtime]
L26–89) so units parsed from strings or config can be converted via a staged
mapping at runtime. It is the escape hatch for the one thing the opaque-type core
cannot do: decide dimensions not known until runtime. Additional integration
modules (`coulomb-parser`, `coulomb-pureconfig`, `coulomb-refined`) layer on top.

## Expressiveness edges

- **Fractional powers: first-class.** Exponents are type-level rationals throughout;
  `pow[E]` dispatches on the value algebra — `Fractional[V]` "supports all rational
  exponents", `MultiplicativeGroup[V]` all integers, `MultiplicativeMonoid[V]`
  non-negative integers, `MultiplicativeSemigroup[V]` positive integers
  ([`quantity.scala`][quantity] L333–363). `2d.withUnit[Meter].pow[1 / 2]`
  type-checks and evaluates to `Quantity[Double, Meter ^ (1 / 2)]`
  [reproduced locally, scala-cli 1.10.1 / Scala 3.3.8, 2026-07-04 — see
  [Diagnostics](#diagnostics)]; the corresponding in-repo tests assert both the
  value and the `Meter ^ (1 / 2)` output type
  ([`core/.../test/.../quantity.scala`][qtest] L190–198). This places `coulomb` with
  [mp-units][mp-units] and [F#][fsharp] on the [free-abelian-group][fag]
  rational-exponent axis.
- **Affine quantities: a distinct type anchored to a base unit.** Points live in
  `DeltaQuantity[V, U, B]` ([`core/.../deltaquantity.scala`][delta] L30), a separate
  opaque type from the linear `Quantity`, parameterized by the base unit `B` it is
  anchored to (`Kelvin` for temperature, `Second`-epoch for time). The affine
  algebra is enforced structurally: `DeltaQuantity - DeltaQuantity` yields a linear
  `Quantity` (a difference of points is a vector), while `DeltaQuantity ± Quantity`
  yields a `DeltaQuantity` (point plus vector is a point —
  [`deltaquantity.scala`][delta] L145–197). There is no `DeltaQuantity +
DeltaQuantity`. The offset lives in the type: `Fahrenheit` is
  `DeltaUnit[Fahrenheit, (5 / 9) * Kelvin, 45967 / 100, "fahrenheit", "°F"]` and
  `Celsius` carries offset `27315 / 100` ([`units/.../temperature.scala`][temp]
  L27–44), extracted by the macro's `offset` function ([`meta.scala`][meta]
  L147–157). This is a concrete, general instance of the
  [torsor / affine-quantity model][torsor] — not restricted to temperature the way
  [uom][uom]'s is; `EpochTime` reuses the identical machinery for
  timestamp-vs-duration.
- **Logarithmic quantities: absent.** There is no decibel, neper, or
  level-of-power/field unit anywhere in the units package (verified by search of the
  pinned clone) — dB is out of scope, as in most systems here ([Pint][pint] is the
  exception).
- **Angles: dimensionless, with no kind tag to keep them apart.** `Radian` is
  `DerivedUnit[Radian, 1, "radian", "rad"]` — literally derived from the constant `1`
  ([`units/.../mks.scala`][mks] L39–40) — and `Degree` is `DerivedUnit[Degree,
3.141592653589793 / 180, "degree", "°"]` ([`accepted.scala`][accepted] L47–49). So
  radians, degrees, and pure `Ratio` all share the empty signature and are freely
  inter-convertible; `coulomb` does not treat angle as a quantity distinct from a
  dimensionless number.
- **Kind-vs-dimension disambiguation: not modeled.** `coulomb` has **no `Kind`
  mechanism** (verified: no `Kind` type anywhere in `core/src/main`). Same-dimension
  quantities that differ only in intent — torque vs energy (both `L²MT⁻²`), frequency
  vs becquerel (both `T⁻¹`), angle vs ratio — are the _same_ `coulomb` type and
  interconvert silently. This is the clearest capability gap against [uom][uom]'s
  `Kind` and [F#][fsharp]'s measure-name distinctions: `coulomb`'s dimension algebra
  is purely the [free abelian group][fag] over base units, with no orthogonal tag
  layer. The trade-off is a simpler, tag-free model with no kind-erasure surprises
  under multiplication (the failure mode [uom][uom] has); the price is that the
  torque/energy and Hz/Bq collisions are unguarded.

## Zero-cost story

The "zero runtime cost" claim is **structural**, resting on Scala 3's opaque types
and `inline`, and there is no `benches/` proving it against hand-written scalar
code:

- **`opaque type Quantity[V, U] = V`** ([`quantity.scala`][quantity] L64): outside
  the defining scope the two types are distinct; at runtime they are erased to the
  same representation. A `Quantity[Double, Meter]` is a `Double` — no wrapper object,
  no boxed dimension, no `PhantomData`-equivalent field (there isn't even a field;
  the value _is_ the quantity). `DeltaQuantity[V, U, B]` is likewise opaque over `V`
  ([`deltaquantity.scala`][delta] L30).
- **Constructors/extractors are `inline` identities** — `withUnit`, `value`,
  `withDeltaUnit` compile to the value itself ([`quantity.scala`][quantity] L91,
  L103; [`deltaquantity.scala`][delta] L54, L68).
- **Conversion coefficients are compile-time constants, inlined.** For the primitive
  value types the coefficient is spliced in as a literal by the
  `coefficientDouble`/`coefficientRational`/… macros ([`coefficients.scala`][coeffs]
  L23–41), and `UnitConversion.apply` short-circuits the identity case entirely
  (`if (typeexpr.uniteq[UF, UT]) v` — [`conversion/unit.scala`][unitconv] L68–69) so
  same-unit arithmetic carries _no_ multiply at all. Steady-state `l1 + l2` on the
  same unit is a bare `alg.plus`.
- **The cost is moved to compile time.** Every distinct unit operation triggers a
  `cansig` traversal and an implicit search; the macro engine, not the runtime, pays.
  This is the mirror image of a runtime-checked library like [`squants`][squants],
  and the same trade [uom][uom] makes — the bill is compile time and diagnostics, not
  cycles.

The honest caveat is representational rather than performance: because arithmetic
runs in the raw value type, using a non-`Fractional` storage type (e.g. `Int`) makes
any _lossy_ conversion a compile error rather than a silent truncation (next
section) — a safety feature, but one that means integer quantities cannot convert
across scale factors at all.

## Diagnostics

The mandated experiment — adding a `Length` to a `Time` — reproduced against the
published `v0.9.1` artifact (the pinned clone's `HEAD`), value type `Double`:

```scala
// locally reproduced — mplusS.scala
//> using scala 3.3.8
//> using dep com.manyangled::coulomb-core:0.9.1
//> using dep com.manyangled::coulomb-units:0.9.1
import coulomb.*
import coulomb.syntax.*
import algebra.instances.all.given
import coulomb.units.si.{*, given}

@main def run(): Unit =
    val bad = 1d.withUnit[Meter] + 1d.withUnit[Second]
    println(bad.show)
```

```text
[error] ./mplusS.scala:11:15
[error] unit type Second not convertable to Meter
[error]     val bad = 1d.withUnit[Meter] + 1d.withUnit[Second]
[error]               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
[error] Error compiling project (Scala 3.3.8, JVM (21))
```

[reproduced locally, `scala-cli 1.10.1` (nixpkgs), Scala `3.3.8` / JVM 21,
2026-07-04]

This is the single most striking contrast in the survey. The error is written in
**the domain's language, not the implementation's** — "unit type Second not
convertable to Meter", the exact string from `report.error` ([`meta.scala`][meta]
L142–143), rendered by `typestr`, whose "policy goal ... is that type aliases are
never expanded" ([`meta.scala`][meta] L424–426). No `typenum` binary encoding, no
alphabetized associated-type record, no truncation-to-file — where [uom][uom] dumps
`PInt<UInt<UTerm, B1>>` to a side file, `coulomb` names the offending units. (The
report points at the whole expression rather than the second operand, and the
message says "convertable" — a spelling quirk carried verbatim in the source.)

The in-repo compile-fail tests corroborate the rejection as rung-2 evidence: the
`munit` suite asserts `assertCE("1d.withUnit[Meter] + 1d.withUnit[Second]")`
("non convertible units should fail") ([`quantity.scala`][qtest] L122–123), with the
sibling cases for `-`, unit conversion, and comparison at
[`quantity.scala`][qtest] L141, L86–87, L256. The `Coefficient` and `UnitConversion`
typeclasses additionally carry `@implicitNotFound` messages ("No coefficient could
be derived …", "No unit conversion in scope …") for the cases the macro doesn't
reach ([`conversion/coefficient.scala`][coefficient] L32–35,
[`conversion/unit.scala`][unitconv] L31–34).

A second, subtler rejection: **lossy integer conversion is a compile error, not a
truncation.** `assertCE("1.withUnit[Meter] - 1.withUnit[Yard]")` and its `Long`
counterpart fail ([`quantity.scala`][qtest] L143–145) because `Int`/`Long` have no
`Fractional` instance, so no non-trivial coefficient can be summoned — `coulomb`
refuses the silent rounding that [uom][uom]'s eager integer normalization performs
(`1 cm` → `0 m`). Same-unit integer arithmetic still works via the `uniteq`
short-circuit.

The valid path, reproduced against the same artifact
[reproduced locally, `scala-cli 1.10.1` / Scala `3.3.8`, 2026-07-04]:

```scala
// locally reproduced — valid.scala (excerpt)
val d = 100d.withUnit[Meter]
val t = 9.58d.withUnit[Second]
val v = d / t                      // inferred Quantity[Double, Meter / Second]
println(v.show)                    // => "10.438413361169102 m/s"
val a = 2d.withUnit[Meter].pow[1 / 2]
println(a.show)                    // => "1.4142135623730951 m^(1/2)"
```

Note the fractional-power result renders in domain language too —
`1.4142135623730951 m^(1/2)` — because `show` uses the same `ShowUnit` type-to-text
macro that produces the abbreviations ([`core/.../io/show.scala`][ioshow] L28–44).

## Ergonomics & compile-time cost

**The surface is minimal for the common case.** Using the shipped SI is
`import coulomb.*; import coulomb.syntax.*; import coulomb.units.si.{*, given}` plus
a value-algebra import (`algebra.instances.all.given` or a `spire` std import);
constructing is `100d.withUnit[Meter]`. Defining any new unit is a `final type` +
a one-line `given` — no macro to author, in sharp contrast to [uom][uom]'s
three-macro `system!`/`quantity!`/`unit!` architecture or the template
metaprogramming of the C++ systems.

**Error readability is a genuine strength**, as the reproduction shows — arguably
the most readable diagnostics of any type-level system in this survey, because the
rejection message is generated by library code (`report.error` + `typestr`) rather
than surfaced by the host type-checker's generic mismatch machinery. The costs are
elsewhere:

- **Scala 3 only.** `coulomb`'s macro engine is built entirely on `scala.quoted` /
  `quotes.reflect` and opaque types, so there is no Scala 2 line
  (`crossScalaVersions := Seq("3.3.8")` — [`build.sbt`][build] L44). A consumer must
  be on Scala 3.
- **Compile-time macro expansion per operation.** Every distinct unit operation runs
  an implicit search that expands a `cansig` traversal and (for outputs) a
  `SimplifiedUnit` macro; unit-heavy code pays a compile-time tax that scales with
  the number and depth of distinct unit expressions. (No wall-clock figure is
  reproduced here; the mechanism — reflective macro per operation — is the finding.)
- **Dependency surface.** The core pulls in [`spire`][spire], [`algebra`][algebra],
  and `cats-kernel` for the numeric-tower typeclasses that parameterize every
  operation ([`build.sbt`][build]) — heavier than a self-contained library, in
  exchange for working uniformly over the entire Typelevel numeric ecosystem.

---

## Strengths

- **Domain-language diagnostics** — "unit type Second not convertable to Meter",
  produced by library code, not the compiler's generic mismatch; the most readable
  errors of the type-level systems surveyed, and a direct answer to [uom][uom]'s
  weakest flank. Shown in [Diagnostics](#diagnostics).
- **True zero-runtime dimensions** — `opaque type Quantity[V, U] = V` plus `inline`
  everywhere; a quantity _is_ its scalar, verified by construction (no field to
  carry a dimension).
- **First-class rational exponents** — type-level `Rational` powers, so `Meter ^
(1 / 2)` and `V/√Hz`-style dimensions are ordinary types; `sqrt` is total, not the
  even-exponent-only partial function of the integer-vector libraries.
- **Open base-dimension set, uniform extension** — any `final type` + `given
BaseUnit`/`DerivedUnit`/`DeltaUnit` is a first-class unit; no macro authoring, no
  fixed exponent-vector length to edit.
- **General affine model** — `DeltaQuantity[V, U, B]` with a type-level offset gives
  point-vs-vector semantics for _any_ anchored scale (temperature, epoch time), not
  a temperature special case.
- **Runtime escape hatch** — `coulomb-runtime`'s `RuntimeQuantity`/`RuntimeUnit`
  bridges to units-known-only-at-runtime (parsing, config), which a pure opaque-type
  core cannot.
- **Integer safety** — lossy conversions on non-`Fractional` storage are compile
  errors, not silent truncation.

## Weaknesses

- **No kind/quantity-name layer** — torque vs energy, frequency vs becquerel, angle
  vs ratio are the same type; the dimension algebra is the bare free abelian group
  with no orthogonal tag, so those classic collisions are unguarded (contrast
  [uom][uom]'s `Kind`). See [Expressiveness edges](#expressiveness-edges).
- **Scala 3 only** — no Scala 2 support at all; the whole engine is `scala.quoted` +
  opaque types.
- **Compile-time macro cost** — dimensional work is redone by a reflective macro at
  every operation rather than memoized in a nominal type; unit-heavy code carries a
  compile-time tax.
- **No logarithmic units** — no decibel/neper support.
- **Heavier dependency graph** — `spire` + `algebra` + `cats-kernel` are pulled in
  for the value-algebra typeclasses that gate every operator.
- **Normalization is not free-of-recompute** — canonicalization by list unification
  is recomputed per operation, where an integer-vector library's structural type
  identity is decided once (its own, different, cost being unreadable type names).

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                                                  | Trade-off                                                                                                    |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `opaque type Quantity[V, U] = V`                                 | Zero runtime footprint — a quantity is its scalar; no wrapper, no dimension field                          | Erasure means all dimensional work must happen at compile time in a macro; Scala 3-only (opaque types)       |
| Units-in-the-type + lazy per-op coefficient (vs eager-to-base)   | Unit identity is preserved; conversions computed only where needed; rational coefficients kept exact       | The `cansig` canonicalization macro reruns on every operation instead of a one-time normalization            |
| A hand-written `quotes.reflect` macro decides compatibility      | Full control of the algorithm _and_ the error text — "unit type X not convertable to Y" in domain language | A bespoke macro engine (`meta.scala`) to maintain; reflection-heavy; no reuse of the host type-checker       |
| Type-level `Rational` exponents                                  | Fractional powers first-class; `sqrt`/`cbrt` total; half-integer dimensions representable                  | Exponent arithmetic needs a `Rational` type-level encoding and `spire` at compile time                       |
| No `Kind`/quantity-name tag — pure base-unit group               | Simplest possible model; no kind-erasure-under-multiplication surprises                                    | Torque/energy, Hz/Bq, angle/ratio collisions are unguarded — same-dimension intents are indistinguishable    |
| Value algebra as `using` params from `spire`/`algebra`           | One library works over `Float`…`BigDecimal`…`Rational` and any Typelevel numeric type; inherits inference  | Heavy dependency graph; `Int`/`Long` (non-`Fractional`) can't do lossy conversions (a safety win, a limit)   |
| Affine scales as a separate `DeltaQuantity[V, U, B]` opaque type | Point-vs-vector algebra enforced by types for any anchored scale (temperature, epoch time)                 | A parallel type and operator set to the linear `Quantity`; the base-unit anchor `B` must be threaded through |

## Sources

- [erikerlandson/coulomb — GitHub repository][repo] (pinned locally at
  `$REPOS/scala/coulomb` @ `681442a`, 2026-06-22)
- [`core/.../coulomb/quantity.scala` — the `opaque type Quantity`, operator and
  ordering extensions, `pow`][quantity]
- [`core/.../coulomb/infra/meta.scala` — the macro engine: `cansig`, `coef`,
  `convertible`, `offset`, `typestr`; where compatibility is decided and the compile
  error raised][meta]
- [`core/.../coulomb/define/define.scala` — `BaseUnit`/`DerivedUnit`/`DeltaUnit`
  marker classes][define]
- [`core/.../coulomb/conversion/{coefficient,unit,coefficients}.scala` — the
  `Coefficient`/`UnitConversion` typeclasses and coefficient splice macros][coefficient]
- [`core/.../coulomb/infra/simplified.scala` — `SimplifiedUnit` operator-output-type
  macro][simplified]
- [`core/.../coulomb/deltaquantity.scala` — the affine `DeltaQuantity` opaque type
  and its point/vector algebra][delta]
- [`units/.../coulomb/units/{si,accepted,temperature,info,mks}.scala` — base units,
  angle, temperature offsets, information units][si]
- [`runtime/.../coulomb/runtime/runtime.scala` — `RuntimeQuantity`/`RuntimeUnit`
  for runtime unit analysis][runtime]
- [`core/src/test/.../coulomb/quantity.scala` — `assertCE` compile-fail tests
  (`m + s`, lossy-int, fractional-power)][qtest]
- [`docs/coulomb-core.md` — "unit analysis performs a role very similar to a type
  system" positioning][coredoc] · [`README.md`][readme] · [`build.sbt` — Scala
  3.3.8, JDK 17, `spire`/`algebra` deps][build]
- Local reproductions (m+s error, valid ops, fractional power): scratch scala-cli
  project against `com.manyangled:coulomb-{core,units}_3:0.9.1`, `scala-cli 1.10.1` /
  Scala `3.3.8` / JVM 21, 2026-07-04
- [coulomb concept docs][docsite] · [javadoc.io API][javadoc] · [Maven Central][maven]
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [Kennedy's type system][kennedy] · [free abelian group][fag] ·
  [torsors & affine quantities][torsor] · [`squants`][squants] · [uom][uom] ·
  [`dimensioned`][dimensioned] · [F# units of measure][fsharp] ·
  [`uom-plugin`][uom-plugin] · [mp-units][mp-units] · [Pint][pint] ·
  [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone (coulomb @ 681442a) -->

[repo]: https://github.com/erikerlandson/coulomb
[quantity]: https://github.com/erikerlandson/coulomb/blob/681442a/core/src/main/scala/coulomb/quantity.scala
[meta]: https://github.com/erikerlandson/coulomb/blob/681442a/core/src/main/scala/coulomb/infra/meta.scala
[define]: https://github.com/erikerlandson/coulomb/blob/681442a/core/src/main/scala/coulomb/define/define.scala
[coefficient]: https://github.com/erikerlandson/coulomb/blob/681442a/core/src/main/scala/coulomb/conversion/coefficient.scala
[unitconv]: https://github.com/erikerlandson/coulomb/blob/681442a/core/src/main/scala/coulomb/conversion/unit.scala
[coeffs]: https://github.com/erikerlandson/coulomb/blob/681442a/core/src/main/scala/coulomb/conversion/coefficients.scala
[simplified]: https://github.com/erikerlandson/coulomb/blob/681442a/core/src/main/scala/coulomb/infra/simplified.scala
[delta]: https://github.com/erikerlandson/coulomb/blob/681442a/core/src/main/scala/coulomb/deltaquantity.scala
[si]: https://github.com/erikerlandson/coulomb/blob/681442a/units/src/main/scala/coulomb/units/si.scala
[accepted]: https://github.com/erikerlandson/coulomb/blob/681442a/units/src/main/scala/coulomb/units/accepted.scala
[temp]: https://github.com/erikerlandson/coulomb/blob/681442a/units/src/main/scala/coulomb/units/temperature.scala
[info]: https://github.com/erikerlandson/coulomb/blob/681442a/units/src/main/scala/coulomb/units/info.scala
[mks]: https://github.com/erikerlandson/coulomb/blob/681442a/units/src/main/scala/coulomb/units/mks.scala
[runtime]: https://github.com/erikerlandson/coulomb/blob/681442a/runtime/src/main/scala/coulomb/runtime/runtime.scala
[ioshow]: https://github.com/erikerlandson/coulomb/blob/681442a/core/src/main/scala/coulomb/io/show.scala
[qtest]: https://github.com/erikerlandson/coulomb/blob/681442a/core/src/test/scala/coulomb/quantity.scala
[coredoc]: https://github.com/erikerlandson/coulomb/blob/681442a/docs/coulomb-core.md
[readme]: https://github.com/erikerlandson/coulomb/blob/681442a/README.md
[build]: https://github.com/erikerlandson/coulomb/blob/681442a/build.sbt

<!-- Official docs & registry -->

[docsite]: https://erikerlandson.github.io/coulomb/
[javadoc]: https://javadoc.io/doc/com.manyangled/coulomb-docs_3
[maven]: https://central.sonatype.com/artifact/com.manyangled/coulomb-core_3
[spire]: https://typelevel.org/spire/
[algebra]: https://typelevel.org/algebra/
[opaque]: https://docs.scala-lang.org/scala3/book/types-opaque-types.html

<!-- Same-tree theory -->

[kennedy]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[squants]: ./scala-squants.md
[uom]: ./rust-uom.md
[dimensioned]: ./rust-dimensioned.md
[fsharp]: ./fsharp-uom.md
[uom-plugin]: ./haskell-uom-plugin.md
[mp-units]: ./cpp-mp-units.md
[pint]: ./python-pint.md
