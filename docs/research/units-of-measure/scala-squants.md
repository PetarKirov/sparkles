# squants (Scala)

The long-standing Scala quantities library: a hand-enumerated family of nominal
`Quantity` classes — one Scala class per dimension — whose dimensional safety is an
F-bounded self-type checked by `scalac`, while the numeric value and its unit live as
ordinary runtime fields and conversions run at runtime through a `Double`
`conversionFactor`.

| Field            | Value                                                                                                                                                             |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | Scala (cross-built `2.12.21`, `2.13.18`, `3.3.7`; cross-platform JVM / Scala.js / Scala Native)                                                                   |
| License          | Apache-2.0                                                                                                                                                        |
| Repository       | [typelevel/squants][repo] (moved from `garyKeorkunian/squants`)                                                                                                   |
| Documentation    | [README][readme] · [Wiki][wiki] · [Scaladoc][scaladoc]                                                                                                            |
| Key authors      | Gary Keorkunian (`garyKeorkunian`, original author) and contributors; now under the [Typelevel][typelevel] umbrella                                               |
| Category         | Library-level [compile-time dimensional safety][concepts] over **runtime** unit-carrying values (no compiler support; nominal-type DSL)                           |
| Mechanism        | `abstract class Quantity[A <: Quantity[A]] { self: A => }` — an F-bounded self-typed base; each dimension is a distinct final class                               |
| Exponent domain  | **None** — dimensions are not exponent vectors; there is no type-level exponent algebra. Derived quantities (Area, Velocity, …) are separate hand-written classes |
| Checking time    | **Compile time** for dimensional safety (nominal type identity); **run time** for the value (`Double`) and scale conversion (`conversionFactor`)                  |
| Analyzed version | `29aa57f` (pinned clone, 2026-03-17; well past the last tagged release — README still advertises `1.6.0`)                                                         |
| Latest release   | `v1.8.3` (2021-08-26)                                                                                                                                             |

> [!NOTE]
> squants is this survey's clearest example of the **runtime-value + nominal-type**
> mechanism: unlike the type-level-exponent lineage ([`uom`][uom], [F#][fsharp],
> [`coulomb`][coulomb]) it holds no dimension in the type system as an algebraic object
> — a dimension is simply _which Scala class_ a value is, and the whole library is a
> flat, hand-maintained catalogue of ~74 such classes wired together by explicitly
> overloaded `*`/`/` operators. It is the informative counterpoint to its Scala sibling
> [`coulomb`][coulomb], whose dimensions _are_ type-level rational-exponent vectors
> checked entirely at compile time with zero runtime unit representation. squants has
> **no** [free-abelian-group][fag] exponent arithmetic (see the
> [mechanism taxonomy][mechanisms]); its one algebraic subtlety — affine temperature —
> is hand-coded, a small instance of the [torsor / affine model][torsor]. See the
> [comparison capstone][comparison] for the cross-system synthesis.

---

## Overview

### What it solves

squants attacks "the trouble with doubles": a bare `Double` lets you add a power to an
energy, or a kilowatt to a megawatt-hour, and compile clean. The README opens with the
positioning ([`README.md`][readme] L3–8):

> "**The Scala API for Quantities, Units of Measure and Dimensional Analysis**
>
> Squants is a framework of data types and a domain specific language (DSL) for
> representing Quantities, their Units of Measure, and their Dimensional relationships.
> The API supports typesafe dimensional analysis, improved domain models and more. All
> types are immutable and thread-safe."

The design goal is stated as a rule ([`README.md`][readme] L108):

> "_Only quantities with the same dimensions may be compared, equated, added, or
> subtracted._"

and the split that defines squants — compile-time _dimensional_ checking but runtime
_scale_ handling — is made explicit ([`README.md`][readme] L110–111):

> "Squants helps prevent errors like these by type checking operations at compile time
> and automatically applying scale and type conversions at run-time."

That single sentence is the whole architecture: the _dimension_ is a type (checked by
the compiler); the _unit_ and the _value_ are objects (resolved at run time).

### Design philosophy

Two decisions set squants apart from the type-level libraries in this survey.

**A dimension is a nominal Scala class, not an exponent vector.** There is no `ℤⁿ` or
`ℚⁿ` of base-quantity exponents anywhere in the library. `Length`, `Area`, `Velocity`,
`Energy`, `Power`, and ~69 others are each a `final class … extends Quantity[Self]`
([`shared/src/main/scala/squants/space/Length.scala`][length] L25–31). Their
relationships are not _computed_ from exponents; they are _declared_ by hand as
overloaded operators (`Length * Length = Area`, `Length * Force = Energy`, …). This is
the opposite pole from [`coulomb`][coulomb] and [`uom`][uom], where `Area` is
_derived_ as `Length²` by the type checker.

**The value and unit are runtime data.** Every quantity is an immutable object wrapping
a `value: Double` and a `unit: UnitOfMeasure[A]` reference
([`Quantity.scala`][quantity] L23–35). Arithmetic and conversion execute at run time as
`Double` multiplies and divides against the unit's `conversionFactor`
([`UnitOfMeasure.scala`][uom-scala] L78–97). squants is therefore emphatically **not**
zero-cost: a `Length` is a heap object, not an unwrapped `Double` (see
[the runtime-cost story](#zero-cost-story)). What it buys in exchange is a fluent
runtime DSL — parsing `"10 kW"` from a string, formatting with symbols, currency
conversion under an exchange-rate context — that a purely type-level library cannot
offer without extra machinery.

---

## How it works

### The F-bounded self-typed base class

The whole dimensional-safety guarantee rests on one signature
([`Quantity.scala`][quantity] L23):

```scala
// squants @ 29aa57f — shared/src/main/scala/squants/Quantity.scala L23
abstract class Quantity[A <: Quantity[A]] extends Serializable with Ordered[A] { self: A =>
  def value: Double
  def unit: UnitOfMeasure[A]
  def dimension: Dimension[A]
  // ...
}
```

Two Scala features combine here. `A <: Quantity[A]` is **F-bounded polymorphism**: a
subclass must instantiate `A` with _itself_ (`final class Length … extends
Quantity[Length]`). The `self: A =>` is a **self-type annotation** asserting that every
`Quantity[A]` really _is_ an `A`. Together they force the additive operators to require
the exact same concrete type on both sides ([`Quantity.scala`][quantity] L48–49):

```scala
// squants @ 29aa57f — shared/src/main/scala/squants/Quantity.scala L48-56
def plus(that: A): A = unit(this.value + that.to(unit))
def +(that: A): A = plus(that)

def minus(that: A): A = plus(that.negate)
def -(that: A): A = minus(that)
```

`Power + Energy` cannot type-check because `Power.+` demands a `Power` and `Energy` is
a different class — an ordinary Scala type mismatch, decided by `scalac` with no
special solver. Comparison is the same story: `Ordered[A].compare` also takes an `A`
([`Quantity.scala`][quantity] L206), so `Length < Time` is a compile error.

Crucially, `that.to(unit)` inside `plus` performs a **runtime** scale conversion: the
right operand is re-expressed in the left operand's unit before the `Double` addition
([`Quantity.scala`][quantity] L260–263), so `Kilowatts(12) + Megawatts(0.023)` yields
`35.0 kW` — same dimension, mixed units, reconciled at run time.

### A dimension is a companion object mixing in `Dimension[A]`

Each quantity class has a companion object that _is_ the dimension, mixing in the
`Dimension[A]` trait ([`Dimension.scala`][dimension] L20–30,
[`Length.scala`][length] L103–116):

```scala
// squants @ 29aa57f — shared/src/main/scala/squants/space/Length.scala L103-116
object Length extends Dimension[Length] with BaseDimension {
  def name = "Length"
  def primaryUnit = Meters
  def siUnit = Meters
  def units = Set(Angstroms, Nanometers, /* … */ Kilometers, Inches, Feet, /* … */)
  def dimensionSymbol = "L"
}
```

`Dimension[A]` carries the runtime registry — the unit `Set`, the `primaryUnit` (the
unit whose `conversionFactor` is `1.0`), the `siUnit`, and string-parsing helpers
([`Dimension.scala`][dimension] L20–79). Seven of the quantities additionally mix in
`BaseDimension`, which adds an SI base-unit marker and a `dimensionSymbol: String`
([`Dimension.scala`][dimension] L101–115) — but that symbol is a **display string**
(`"L"`, `"Θ"`, …), not a participant in any exponent computation. Dimension identity is
implemented by comparing companion **class names** at runtime
([`Dimension.scala`][dimension] L87–93), used by `Quantity.equals` to reject
cross-dimension equality ([`Quantity.scala`][quantity] L173–176).

### A unit is a `conversionFactor` object

A `UnitOfMeasure[A]` is a singleton object holding a factor relative to the dimension's
`primaryUnit` ([`UnitOfMeasure.scala`][uom-scala] L21–97):

```scala
// squants @ 29aa57f — shared/src/main/scala/squants/UnitOfMeasure.scala L78-97 (abridged)
trait UnitConverter { uom: UnitOfMeasure[_] =>
  protected def conversionFactor: Double
  protected def converterTo:   Double => Double = value => value / conversionFactor
  protected def converterFrom: Double => Double = value => value * conversionFactor
}
// e.g. object Kilometers extends LengthUnit { val conversionFactor = MetricSystem.Kilo } // 1e3
```

Constructing `Kilometers(1.5)` stores `1.5` tagged with the `Kilometers` object; `to`
and arithmetic divide/multiply by the factor at run time. `MetricSystem` supplies the
SI prefix constants as plain `Double`s (`Kilo = 1e3`, `Milli = 1e-3`, …,
[`MetricSystem.scala`][metric] L18–39).

### Derived dimensions are wired by hand

Because there is no exponent algebra, every dimensional _relationship_ is a
hand-written operator overload on the participating classes. `Length` alone declares
`*`/`/` returning `Area`, `Volume`, `Energy`, `RadiantIntensity`, `Power`,
`ElectricalConductance`, `Resistivity`, and `Acceleration`
([`Length.scala`][length] L36–60):

```scala
// squants @ 29aa57f — shared/src/main/scala/squants/space/Length.scala L36-53 (abridged)
def *(that: Length): Area = unit match {
  case Centimeters => SquareCentimeters(this.value * that.toCentimeters)
  case Kilometers  => SquareKilometers(this.value * that.toKilometers)
  // …unit-by-unit, falling back to SquareMeters(toMeters * that.toMeters)
}
def *(that: Force): Energy = Joules(this.toMeters * that.toNewtons)
```

Time relationships get a reusable pair of traits, `TimeIntegral`/`TimeDerivative`, that
factor out the "X per Time = Y, Y × Time = X" pattern (`Length` is a
`TimeIntegral[Velocity]`, `Power` is a `TimeDerivative[Energy]` —
[`TimeDerivative.scala`][timederiv] L21–86); but the derivative/integral partner is
still named explicitly per class. There is no generic `a * b` that computes a result
dimension: if a product isn't spelled out somewhere, it doesn't compile.

---

## Dimension representation

A dimension is **a nominal type — a distinct `final class` extending `Quantity[Self]`**
— with no numeric encoding of base-quantity exponents anywhere in the library
([`Length.scala`][length] L25–31). This is the survey's purest instance of "dimension =
type identity": there is no `ℤⁿ`/`ℚⁿ` vector, no `typenum` chain, no phantom exponent
parameter. The pinned clone ships **74** such `Quantity` subclasses
(counted across `shared/src/main/scala/squants/`), from `Length` and `Mass` through
`MagneticFluxDensity`, `SpectralIrradiance`, and `Money`.

Consequences of the nominal choice, both distinctive:

- **Dimensional _equivalence_ is decided by name, not structure.** `Dimension.equals`
  compares companion class names ([`Dimension.scala`][dimension] L87–93). Two quantities
  interoperate only if they are the _same_ class — there is no "same exponent vector,
  different spelling" question because there are no exponent vectors. The flip side is
  that squants can, and does, keep **dimensionally identical quantities apart as
  distinct types**: `Torque` (N·m) and `Energy` (J) share the physical dimension
  `L²MT⁻²`, yet are separate classes ([`motion/Torque.scala`][torque] L14–15;
  [`energy/Energy.scala`][energy] L99), so adding them is a compile error
  (reproduced below). A pure exponent-vector library would conflate them without an
  extra "kind" tag.

- **Derived dimensions do not compose automatically.** Because `Area` is not `Length²`
  in the type system but a hand-declared class, the set of expressible products and
  quotients is exactly the set someone wrote an operator for. There is no way to form
  an arbitrary `Length³ · Mass⁻¹` on demand; if no class and operator exist for it, the
  expression is simply un-typable. This is the representational cost of trading the
  [free abelian group][fag] for a flat catalogue.

`Dimensionless` is itself just another class (units `Each`, `Percent`, `Dozen`, …),
not the all-zero vector of a group ([`Dimensionless.scala`][dimensionless] L24–52); it
special-cases `* Quantity[_]` to act as a scalar ([`Dimensionless.scala`][dimensionless]
L33–34).

## Checking & inference

All dimensional checking is **ordinary Scala type-checking** — nominal subtype/identity
matching by `scalac`, no macro, no implicit-search solver, no compiler plugin.
Addition, subtraction, and comparison require the identical concrete class through the
F-bounded `A` ([`Quantity.scala`][quantity] L48–49, L206). Multiplication and division
resolve by **overload selection**: `scalac` picks the `*`/`/` whose parameter type
matches the right operand and reads the return type off that overload. So
`val v = length / time` infers `Velocity` with no annotation — but only because a human
wrote `Length` a `TimeIntegral[Velocity]` whose `/(Time): Velocity` exists
([`TimeDerivative.scala`][timederiv] L64–66).

What squants **cannot** do is any form of _dimensional inference or polymorphism_:

- There is no way to write a function generic over "any quantity whose dimension is the
  product of these two" — the result type of a product is fixed by the specific overload,
  not solved for. You can write code generic over a _single_ `Quantity` subtype
  (`def scale[A <: Quantity[A]](q: A, k: Double): A = q * k`), because scalar
  multiplication stays within `A` ([`Quantity.scala`][quantity] L63–64), but you cannot
  abstract over the _dimensional arithmetic_ the way [Kennedy][kennedy]-style principal
  types or [`uom`][uom]'s `powi` bounds allow.
- There is no principal-type generalisation and no inversion: `scalac` never infers
  that some unknown `X` satisfies `X * Time = Length`.

The trade is deliberate: squants keeps the checker trivial (it is just Scala's ordinary
type system) at the cost of an inexpressible dimensional algebra.

## Extensibility

- **New units on an existing quantity — cheap and idiomatic.** A unit is a singleton
  object mixing `UnitConverter` with a `conversionFactor`
  ([`UnitOfMeasure.scala`][uom-scala] L78–86; the `Length` units at
  [`Length.scala`][length] L156–180 are the template). A downstream project can declare
  `object Furlongs extends LengthUnit { val conversionFactor = 201.168 }` and use it in
  arithmetic immediately; to have it participate in string parsing it must also be added
  to the dimension's `units` `Set` ([`Length.scala`][length] L109–114), which — since
  that `Set` is fixed in the library's companion object — generally means the unit is
  fully first-class only if contributed upstream.

- **New quantities / dimensions — a from-scratch class + companion.** Adding a dimension
  is not a one-line declaration; it is a new `final class Foo extends Quantity[Foo]`, a
  companion `object Foo extends Dimension[Foo]`, a `FooUnit` trait, one or more unit
  objects, and — to relate `Foo` to existing quantities — hand-written `*`/`/` overloads
  on _both_ sides of each relationship. This is real work per dimension and is why the
  library is a large, curated corpus rather than a small generator. The upside is total
  control: `Money` is a `Quantity[Money]` whose "unit" is a `Currency` and whose
  conversions consult a runtime `MoneyContext` of exchange rates
  ([`market/Money.scala`][money] L45–51) — a genuinely runtime, mutable "dimension" that
  no type-level library could express.

- **No user-defined base-dimension system.** Unlike [`uom`][uom]'s `system!` or
  [`coulomb`][coulomb]'s open type-level base units, there is no mechanism to declare a
  _new coordinate system_ of base quantities; the base set is whatever the seven
  `BaseDimension` classes are. Extension happens by adding classes to the same flat
  namespace, not by parameterising a system.

## Expressiveness edges

- **Fractional powers: not representable as dimensions.** With no exponent algebra there
  is no `L^(1/2)` type at all. `Length` offers `squared`/`cubed` as concrete methods
  returning `Area`/`Volume` ([`Length.scala`][length] L62–63), and `Area` offers a
  `squareRoot` returning `Length` — but these are hand-wired shortcuts between named
  classes, not a general power operator. A quantity like `V/√Hz` has no squants type,
  and cannot be given one without inventing a bespoke class.

- **Affine / temperature: hand-coded, the one genuinely algebraic edge.** `Temperature`
  is special-cased precisely because Celsius/Fahrenheit/Kelvin/Rankine have different
  zero points. squants overrides `plus`/`minus` so the **right** operand is interpreted
  as an interval (degrees), not an absolute point ([`thermal/Temperature.scala`][temp]
  L73–74):

  ```scala
  // squants @ 29aa57f — shared/src/main/scala/squants/thermal/Temperature.scala L73-74
  override def plus(that: Temperature): Temperature =
      Temperature(this.value + that.convert(unit, withOffset = false).value, unit)
  override def minus(that: Temperature): Temperature =
      Temperature(this.value - that.convert(unit, withOffset = false).value, unit)
  ```

  The private `convert` method carries two parallel conversion tables — a `withOffset =
true` "Scale" set that applies the zero-point offset (so `5 °C` reads as `41 °F` on a
  thermometer) and a `withOffset = false` "Degrees" set that does not (so a `5 °C`
  interval is a `9 °F` interval) ([`Temperature.scala`][temp] L88–131). The module doc
  states the intent and the headline example ([`Temperature.scala`][temp] L54–60):

  > "The Quantity.plus and Quantity.minus methods are implemented to treat right
  > operands as Quantity of Degrees and not a scale Temperature. … `val temp =
Fahrenheit(100) - Celsius(5) // returns Fahrenheit(91)`"

  This is a concrete, one-off instance of the [torsor / affine-quantity model][torsor],
  restricted to temperature and implemented by overriding the base operators — there is
  no general point-vs-interval type distinction (no `TemperatureInterval` type as in
  [`uom`][uom]; the point/interval semantics are collapsed into which operator argument
  you are).

- **Logarithmic quantities: absent.** There is no decibel, neper, or field/power level
  type anywhere under `shared/src/main/scala/squants/` (verified by search of the pinned
  clone). As in most of the survey, dB ergonomics are out of scope.

- **Angles: a first-class dimension, distinct from `Dimensionless`.** `Angle` is its own
  `Quantity[Angle]` with `Radians`/`Degrees`/`Gradians`/… units and trigonometry
  (`sin`/`cos`/`tan`) built in ([`space/Angle.scala`][angle] L21–37, L54–61) — it is
  **not** modelled as dimensionless. So `Angle` and `Dimensionless` are simply different
  classes and cannot be added; `SolidAngle` is likewise separate. This gives the
  angle-vs-ratio distinction for free (they are different types), but it also means angle
  carries no group relationship to dimensionless numbers — `Angle` interacts with the
  world only through the operators someone wrote (e.g. `angle.onRadius(length): Length`,
  [`Angle.scala`][angle] L46).

- **Kind-vs-dimension: handled by nominal typing, not a tag.** The classic collision
  pairs are kept apart simply by being distinct classes: `Torque` vs `Energy`
  (both `L²MT⁻²`), `Frequency` vs `Radioactivity`/`Activity` (both `T⁻¹`), `Angle` vs
  `Dimensionless`. There is no `Kind` machinery ([`uom`][uom]'s approach) because
  squants never unifies dimensions structurally in the first place — the "kind"
  distinction is the default, not an add-on. The cost is the mirror image of [`uom`][uom]'s
  kind-erasure problem: squants never has to compose kinds, but it also can never derive
  that two independently-defined classes are dimensionally the _same_.

## Zero-cost story

squants is **not** zero-cost, and does not claim to be — this section is the honest
runtime-cost story. The evidence in the clone:

- **A quantity is a heap object, not an unwrapped scalar.** `Quantity[A]` is an
  `abstract class` with two abstract members realised as fields on each `final class` —
  `value: Double` and `unit: UnitOfMeasure[A]` (a reference) —
  ([`Quantity.scala`][quantity] L23–35, [`Length.scala`][length] L25). A `Length` is a
  JVM object carrying a boxed-`Double`-worth of payload plus a unit pointer plus object
  header; it is emphatically not "an `f64` in a register" the way [`uom`][uom]'s
  `#[repr(transparent)]` `Quantity` is. (Scala 2/3 `AnyVal` value-class erasure is _not_
  used here, because the class has two fields and an inheritance hierarchy.)

- **Arithmetic touches conversion factors at run time.** `plus` calls `that.to(unit)`,
  which — unless the units already match — runs `uom.convertTo(this.unit.convertFrom(value))`,
  i.e. two `Double` operations against the stored `conversionFactor`
  ([`Quantity.scala`][quantity] L48, L260–263; [`UnitOfMeasure.scala`][uom-scala]
  L88–97). Even a same-unit add pays a `unit match` dispatch and an object allocation for
  the result (every operator returns a fresh immutable `Quantity`). Products allocate a
  new object of a different class and may run a `unit match` to choose the result unit
  ([`Length.scala`][length] L36–43).

- **The pay-off for the cost is a runtime DSL.** Because the unit is a live object,
  squants can parse `"10 kW"` and `(10, "kW")` tuples ([`Dimension.scala`][dimension]
  L56–79), format with symbols, expose a `Set` of a dimension's units, and — for
  `Money` — convert through a runtime, updatable exchange-rate `MoneyContext`
  ([`Money.scala`][money] L45–51). These are things a purely type-erased, zero-cost
  representation cannot do without re-introducing runtime metadata.

The contrast with the survey's zero-cost libraries is the crux: [`coulomb`][coulomb]
(the Scala sibling), [`uom`][uom], and F# all erase the dimension entirely so the
runtime value _is_ the scalar; squants keeps the unit at runtime and pays for it. The
trade is deliberate — safety **and** a fluent runtime model, at a per-operation
allocation-and-multiply cost.

## Diagnostics

The mandated experiment — adding a quantity of one dimension to another — reproduced
against the library, using the exact `Power + Energy` pair from the README:

```scala
// mplus.scala (scala-cli), against published squants 1.8.3
//> using scala 2.13.18
//> using dep org.typelevel::squants:1.8.3
import squants.energy.{Kilowatts, KilowattHours, Power, Energy}
object M {
    val load: Power    = Kilowatts(1.2)
    val energy: Energy = KilowattHours(23.0)
    val sum = load + energy
}
```

```text
[error] mplus.scala:4:105
[error] type mismatch;
[error]  found   : squants.energy.Energy
[error]  required: squants.energy.Power
[error] object M { … val sum = load + energy }
[error]                                 ^^^^^^
[error] Error compiling project (Scala 2.13.18, JVM (21))
```

[reproduced locally, `scala-cli 1.10.1` / Scala `2.13.18` / JVM 21 (nixpkgs), 2026-07-04,
against published `squants 1.8.3`; the `Quantity.plus` / F-bounded mechanism at
[`Quantity.scala`][quantity] L23, L48 is identical in the pinned clone `29aa57f`]

This is the **best diagnostic in the survey**, and it is essentially free: because the
dimension is a nominal class, `scalac` reports the mismatch in the domain's own
language — `found: Energy`, `required: Power` — with the plain class names, no
`typenum` binary encoding, no phantom-parameter soup, no truncation-to-file. The
library documents the identical error verbatim ([`README.md`][readme] L150–154):

```text
scala> val sum = load + energy
<console>:16: error: type mismatch;
 found   : squants.energy.Energy
 required: squants.energy.Power
       val sum = load + energy
                        ^
```

The nominal model also catches **same-dimension-different-quantity** mistakes that
pure exponent-vector libraries miss. Adding a torque to an energy — both physically
`L²MT⁻²` — is likewise a clean class mismatch
[reproduced locally, same toolchain, 2026-07-04]:

```text
[error] type mismatch;
[error]  found   : squants.motion.Torque
[error]  required: squants.energy.Energy
[error] object M2 { … val bad = e + t }
```

The valid-path counterpart — same dimension, mixed units, reconciled at runtime — runs
and prints the reconciled value [reproduced locally, same toolchain, 2026-07-04]:

```scala
val a: Length = Meters(500)
val b: Length = Kilometers(1.5)
val s: Length = a + b           // OK: same dimension, mixed units
println(s.toString(Meters))     // prints "2000.0 m"
```

The signal is precise and the message is domain-readable — the diametric opposite of
[`uom`][uom]'s `PInt<UInt<UTerm, B1>>` diagnostics — and this readability is the direct
reward of choosing nominal types over an exponent algebra.

## Ergonomics & compile-time cost

**Usage is fluent.** With the implicit-conversion DSL, quantities read like prose —
`Kilowatts(1.2)`, `10.kW`, `65.F +- 5.C`, `(load / time)` — and mixed-unit arithmetic
"just works" via the runtime `conversionFactor`. Immutability and thread-safety are
guaranteed by construction ([`README.md`][readme] L8), and the runtime unit enables
string parsing, symbol formatting, `QuantityRange`s, vectors
([`SVector.scala`][svector]), and money with live FX. For an application developer this
is an ergonomic high point among the surveyed libraries.

**Authoring a new dimension is heavy.** The other side of "no generator": each dimension
is a class + companion `Dimension` + unit trait + unit objects + hand-written `*`/`/`
overloads on every related quantity. Cross-referencing operators must be kept
consistent by hand (the library's `*` methods frequently `unit match` over many cases,
e.g. [`Length.scala`][length] L36–50), which is where maintenance effort concentrates.

**Compile-time cost is modest and ordinary.** Because checking is plain nominal
type-checking with no type-level computation, the compiler does no exponent solving —
there are no `typenum`-style recursion blow-ups and no macro expansion in user code. The
cost is compiling a large but conventional class hierarchy; downstream code that merely
_uses_ squants pays essentially normal Scala compile times. (The library's own
cross-build across Scala 2.12/2.13/3 and three platforms is substantial, but that is the
maintainers' cost, not the consumer's.)

**A note on version drift.** The README in the pinned clone still advertises Current
Release `1.6.0` ([`README.md`][readme] L23) while `project/Build.scala` cross-builds
`3.3.7` and the last _tagged_ GitHub release is `v1.8.3` (2021-08-26). Cite the pinned
SHA (`29aa57f`), not the README's stale version banner.

---

## Strengths

- **Best-in-survey diagnostics** — dimensional errors read `found: Energy / required:
Power` in domain vocabulary, for free, because dimensions are nominal classes; no
  encoding leaks into the message.
- **Same-dimension quantity distinctions by default** — `Torque` vs `Energy`,
  `Frequency` vs `Activity`, `Angle` vs `Dimensionless` are separate types with no extra
  "kind" machinery, a distinction pure exponent-vector libraries need a bolt-on to make.
- **Fluent runtime DSL** — string/tuple parsing, symbol formatting, mixed-unit
  arithmetic, ranges, vectors, and `Money` with a runtime exchange-rate context; things a
  zero-cost, type-erased model cannot do natively.
- **Immutable, thread-safe, cross-platform** — every quantity is an immutable value;
  cross-built for JVM, Scala.js, and Scala Native across Scala 2.12/2.13/3.
- **Trivial, plugin-free checking** — dimensional safety is ordinary Scala type-checking,
  so there is no macro/solver fragility and no exotic compile-time blow-up.
- **Honest, well-documented affine temperature** — the point-vs-interval subtlety is
  handled explicitly with parallel Scale/Degrees conversion tables and a clear module
  doc.

## Weaknesses

- **Not zero-cost** — a quantity is a heap object with a runtime unit reference; every
  operation allocates a result and may multiply by a `conversionFactor`. The polar
  opposite of [`coulomb`][coulomb] / [`uom`][uom] on the cost axis.
- **No exponent algebra, so no dimensional composition** — `Area` is a hand-declared
  class, not `Length²`; any product/quotient without a pre-written operator is
  un-typable. No `Length³·Mass⁻¹`-on-demand.
- **No fractional powers** — `√Hz`, `V/√Hz`, and similar half-integer dimensions have no
  type and cannot be given one without a bespoke class.
- **No dimensional polymorphism or inference** — you cannot abstract over "the product of
  two dimensions"; no [Kennedy][kennedy]-style principal types.
- **Heavy to extend with new dimensions** — a new dimension is a full class + companion +
  units + cross-operators, maintained by hand; the library is a large curated corpus, not
  a generator.
- **Closed base-dimension set** — no user-declarable system of base quantities the way
  [`uom`][uom]'s `system!` or [`coulomb`][coulomb]'s type-level base units allow.
- **Stale release cadence** — the last tagged release is `v1.8.3` (2021), and the README
  version banner lags the source further still.

## Key design decisions and trade-offs

| Decision                                                                  | Rationale                                                                                                      | Trade-off                                                                                                          |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Dimension = nominal `final class extends Quantity[Self]` (no exponents)   | Dimensional errors read in domain language; same-dimension quantities (torque/energy) stay distinct by default | No exponent algebra: `Area` ≠ `Length²` in the type system; arbitrary products are un-typable; ~74 classes by hand |
| F-bounded self-type `Quantity[A <: Quantity[A]] { self: A => }`           | `+`/`-`/`compare` require the identical concrete class using only ordinary Scala type-checking                 | No dimensional polymorphism or inference; every relationship must be spelled out as an overload                    |
| Value + unit are **runtime** fields; conversions via `conversionFactor`   | Enables a fluent runtime DSL: string parsing, symbol formatting, mixed-unit ops, `Money` with live FX          | Not zero-cost — heap object per quantity, allocation + `Double` multiply per operation                             |
| Derived dimensions wired by explicit `*`/`/` overloads (+ `TimeIntegral`) | Total control over which relationships exist and their result units; readable, closed set of operations        | Combinatorial hand-maintenance; a missing operator = a compile error for a physically valid product                |
| Affine temperature via overridden `plus`/`minus` + dual conversion tables | Correctly models zero-point offsets and the interval-vs-scale distinction where it actually matters            | One-off, temperature-only; no general point/interval types (no `TemperatureInterval`), no reusable torsor model    |
| Angle is a first-class dimension, not dimensionless                       | Angle/ratio and solid-angle distinctions come for free as separate types; trig lives on `Angle`                | Angle carries no group relation to dimensionless numbers; interacts only through hand-written operators            |
| Flat catalogue, no user-declarable base-quantity system                   | Simple mental model; a large vetted set of physical quantities and units out of the box                        | No new coordinate systems; extension means adding classes to one namespace, not parameterising a system            |

## Sources

- [typelevel/squants — GitHub repository][repo] (pinned locally at
  `$REPOS/scala/squants` @ `29aa57f`, 2026-03-17)
- [`shared/src/main/scala/squants/Quantity.scala` — the F-bounded `Quantity[A]` base: `plus`/`minus`/`compare`/`to`/`equals`][quantity]
- [`shared/src/main/scala/squants/Dimension.scala` — the `Dimension[A]` / `BaseDimension` traits, name-based dimension equality, string parsing][dimension]
- [`shared/src/main/scala/squants/UnitOfMeasure.scala` — `UnitOfMeasure`, `UnitConverter`, `conversionFactor`, `PrimaryUnit`][uom-scala]
- [`shared/src/main/scala/squants/space/Length.scala` — a full dimension: class, companion `Dimension`, units, hand-written `*`/`/`][length]
- [`shared/src/main/scala/squants/thermal/Temperature.scala` — affine temperature: overridden `plus`/`minus`, Scale vs Degrees conversion][temp]
- [`shared/src/main/scala/squants/space/Angle.scala` — angle as a first-class dimension with trigonometry][angle]
- [`shared/src/main/scala/squants/{energy/Energy,energy/Power,motion/Torque,Dimensionless,market/Money}.scala` — nominal same-dimension distinctions and the runtime `Money` "dimension"][energy]
- [`shared/src/main/scala/squants/time/TimeDerivative.scala` — the `TimeIntegral`/`TimeDerivative` derived-dimension traits][timederiv]
- [`README.md` — positioning, the "trouble with doubles", the documented `Power + Energy` compile error][readme] · [`project/Build.scala` — Scala versions / cross-build][build]
- Local reproductions (`Power + Energy`, `Torque + Energy`, valid mixed-unit add):
  `scala-cli 1.10.1` / Scala `2.13.18` / JVM 21 against published `squants 1.8.3`, 2026-07-04
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [free abelian group][fag] · [torsors & affine quantities][torsor] ·
  [Kennedy's type system][kennedy] · [`coulomb`][coulomb] · [`uom`][uom] ·
  [F# units of measure][fsharp] · [concepts][concepts] · [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone (squants @ 29aa57f) -->

[repo]: https://github.com/typelevel/squants
[quantity]: https://github.com/typelevel/squants/blob/29aa57f/shared/src/main/scala/squants/Quantity.scala
[dimension]: https://github.com/typelevel/squants/blob/29aa57f/shared/src/main/scala/squants/Dimension.scala
[uom-scala]: https://github.com/typelevel/squants/blob/29aa57f/shared/src/main/scala/squants/UnitOfMeasure.scala
[length]: https://github.com/typelevel/squants/blob/29aa57f/shared/src/main/scala/squants/space/Length.scala
[temp]: https://github.com/typelevel/squants/blob/29aa57f/shared/src/main/scala/squants/thermal/Temperature.scala
[angle]: https://github.com/typelevel/squants/blob/29aa57f/shared/src/main/scala/squants/space/Angle.scala
[energy]: https://github.com/typelevel/squants/blob/29aa57f/shared/src/main/scala/squants/energy/Energy.scala
[torque]: https://github.com/typelevel/squants/blob/29aa57f/shared/src/main/scala/squants/motion/Torque.scala
[dimensionless]: https://github.com/typelevel/squants/blob/29aa57f/shared/src/main/scala/squants/Dimensionless.scala
[money]: https://github.com/typelevel/squants/blob/29aa57f/shared/src/main/scala/squants/market/Money.scala
[timederiv]: https://github.com/typelevel/squants/blob/29aa57f/shared/src/main/scala/squants/time/TimeDerivative.scala
[metric]: https://github.com/typelevel/squants/blob/29aa57f/shared/src/main/scala/squants/MetricSystem.scala
[svector]: https://github.com/typelevel/squants/blob/29aa57f/shared/src/main/scala/squants/SVector.scala
[readme]: https://github.com/typelevel/squants/blob/29aa57f/README.md
[build]: https://github.com/typelevel/squants/blob/29aa57f/project/Build.scala

<!-- Official docs & project -->

[typelevel]: https://typelevel.org/
[wiki]: https://github.com/typelevel/squants/wiki
[scaladoc]: https://www.javadoc.io/doc/org.typelevel/squants_2.13

<!-- Same-tree theory -->

[kennedy]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[coulomb]: ./scala-coulomb.md
[uom]: ./rust-uom.md
[fsharp]: ./fsharp-uom.md
