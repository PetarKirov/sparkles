# Swift units (Foundation `Measurement`)

Swift's standard units facility is Foundation's `Measurement<UnitType>` — a value struct pairing a `Double` with a reference-type `Unit`/`Dimension` object, whose dimensional identity is the _class identity_ of the generic argument rather than an exponent algebra; it is built for locale-aware conversion and display, not for compile-time dimensional analysis. This page reads it against a runtime-typed third-party contrast, [`NeedleInAJayStack/Units`][units-repo], to place the whole Swift story: neither library gives the compile-time dimension safety of the [Kennedy][kennedy] or [`typenum`][uom]-vector systems in this survey.

| Field            | Value                                                                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language         | Swift (this clone builds with `-swift-version 6`; the `Measurement` API dates to the Swift 3 / macOS 10.12 era)                                                          |
| License          | Apache-2.0 with Runtime Library Exception                                                                                                                                |
| Repository       | [swiftlang/swift-corelibs-foundation][repo] (the Linux/open-source mirror of the Foundation that ships with the Swift toolchain)                                         |
| Documentation    | [Apple Developer: `Measurement`][apple-measurement] · [`Unit` / `Dimension`][apple-dimension]                                                                            |
| Key authors      | Apple Inc. and the Swift project authors                                                                                                                                 |
| Category         | Standard-library **runtime conversion** facility with a **thin nominal compile-time guard** (no dimensional algebra; no compiler support)                                |
| Mechanism        | `Measurement<UnitType : Unit>` generic over a **reference-type unit class**; dimensional identity = the _class identity_ of `UnitType`; conversion via `UnitConverter`   |
| Exponent domain  | **None** — there is no exponent vector and no product type; each physical quantity is a hand-written `final class : Dimension`                                           |
| Checking time    | Compile time for **same-vs-different-quantity addition only** (generic-parameter identity); everything else (comparison, conversion) is runtime, some of it `fatalError` |
| Analyzed version | `cd04666` (pinned clone, 2026-07-01, `main`; no independent semver — versioned with the Swift toolchain)                                                                 |
| Latest release   | Tracks the Swift toolchain (Swift 6.x at analysis); the classic `Measurement`/`Unit` API is unchanged since Swift 3                                                      |

> [!NOTE]
> Swift is this survey's **nominal-plus-runtime** data point, and its two libraries
> occupy _different_ corners of that space. **Foundation** encodes dimension as the
> _nominal identity of a unit class_ (`UnitLength` vs `UnitDuration` are unrelated
> types) and offers **no product type at all** — you cannot even _name_ an `m·s`.
> **[`NeedleInAJayStack/Units`][units-repo]** is the opposite: a **structural** runtime
> exponent map with full `*`/`/`/`pow` algebra, but every dimension check is deferred
> to a **thrown runtime error**. So both sit at the runtime pole with
> [Pint][pint]'s registry and the [UCUM/QUDT][ucum] runtime-exception model, distinct
> from the compile-time pole held by [uom][uom], [F#][fsharp], [Nim `unchained`][nim]
> and [Kotlin `measured`][kotlin]. For the exponent-algebra theory see
> [free abelian group][fag] and [type-system mechanisms][mechanisms]; for the affine
> temperature discussion see [torsors & affine quantities][torsor].

The contrast library's facts, for reference:

| Field           | Value (`NeedleInAJayStack/Units`)                                                                      |
| --------------- | ------------------------------------------------------------------------------------------------------ |
| License         | MIT (© 2021 Jay Herron)                                                                                |
| Repository      | [NeedleInAJayStack/Units][units-repo] · pinned `08ab9be` (2026-07-03), release `v1.2.0`                |
| Mechanism       | single non-generic `Measurement` struct; `Unit` value carries a runtime `[Quantity: Int]` exponent map |
| Exponent domain | `ℤ` — integer exponents in a runtime dictionary; **no fractional powers** (`pow(_ raiseTo: Int)`)      |
| Checking time   | **Runtime** — `+`/`-` are `throws`; a dimension mismatch throws `UnitError.incompatibleUnits`          |

---

## Overview

### What it solves

Foundation's `Measurement` is a **model-and-display type**: it holds a magnitude and a
unit so an app can convert between units of the same physical quantity and render the
result in the user's locale. The type's own doc comment states the scope plainly
([`Measurement.swift`][f-meas] L23–24):

> "A `Measurement` is a model type that holds a `Double` value associated with a
> `Unit`. Measurements support a large set of operators, including `+`, `-`, `*`, `/`,
> and a full set of comparison operators."

The center of gravity is _conversion and formatting_, not dimensional algebra. The
conversion power is gated behind the unit being a `Dimension` ([`Measurement.swift`][f-meas]
L76):

> "When a `Measurement` contains a `Dimension` unit, it gains the ability to convert
> between the kinds of units in that dimension."

And the headline consumer is [`MeasurementFormatter`][f-fmt], whose job is locale-aware
display — it will "implicitly convert the measurement object to miles" for an `en_US`
locale ([`MeasurementFormatter.swift`][f-fmt] L37–40). That framing — units as an
_i18n/display_ concern — explains every design choice below, and why compile-time
dimensional _correctness_ is not among the goals.

### Design philosophy

Two decisions define Foundation's model against the rest of this survey.

**Dimension is nominal, carried by a reference type.** `Measurement` is generic over
`UnitType : Unit`, and `Unit` is an `open class` (`Dimension` is its subclass). A
`Measurement<UnitLength>` and a `Measurement<UnitDuration>` are unrelated
instantiations of the generic; there is no exponent vector anywhere. The value struct
stores the value _and a live class reference_ ([`Measurement.swift`][f-meas] L26–33):

```swift
// Foundation: Sources/Foundation/Measurement.swift L26-33 (illustration; not runnable)
public struct Measurement<UnitType : Unit> : ReferenceConvertible, Comparable, Equatable {
    /// The unit component of the `Measurement`.
    public let unit: UnitType
    /// The value component of the `Measurement`.
    public var value: Double
}
```

**Values are stored in the unit you gave them, not normalized.** Unlike [uom][uom]'s
eager normalization to base units, a `Measurement` keeps its original `unit` and
converts lazily, through the unit's `converter`, only when asked (`converted(to:)`, or
when two different units of the same dimension are added). This keeps the stored unit
identity for display, at the cost of a heap `UnitConverter` object and a virtual call
on every conversion.

For the contrast library, [`Units`][units-repo] takes the structural route: its `Unit`
doc comment promises a full algebra ([`Unit.swift`][u-unit] L3–7) — "Units may be
multiplied and divided, resulting in 'composite' units" — and its README is candid that
the safety is _runtime_ ([`README.md`][u-readme] L35):

> "addition and subtraction requires that both measurements have the same dimensionality
> (5 meters - 10 seconds ❌), otherwise a runtime error is thrown."

---

## How it works

### Foundation: a class tower, one quantity per subclass

The type hierarchy is three layers ([`Unit.swift`][f-unit]):

- `Unit` — an `open class` whose only state is a `symbol: String` (L151–152).
- `Dimension : Unit` — adds a `converter: UnitConverter` and an abstract base-unit
  hook (L194–211):

  ```swift
  // Foundation: Sources/Foundation/Unit.swift L194-211 (illustration; not runnable)
  open class Dimension : Unit, @unchecked Sendable {
      public let converter: UnitConverter
      open class func baseUnit() -> Self {
          fatalError("*** You must override baseUnit in your class to define its base unit.")
      }
  }
  ```

- **One `final class` per physical quantity.** `UnitLength`, `UnitDuration`,
  `UnitArea`, `UnitTemperature`, `UnitSpeed`, … — 22 hand-written `Dimension`
  subclasses in the shipped set ([`Unit.swift`][f-unit] L251–2340), each exposing its
  units as `class var`s (`UnitLength.meters`, `UnitDuration.seconds`) and overriding
  `baseUnit()`.

Crucially, `UnitArea` is a _separately authored class_, not `UnitLength` squared, and
`UnitSpeed` is not `UnitLength / UnitDuration`. There is no type-level relationship
between them at all — the library has no way to _derive_ one quantity from others.

Conversion is a linear affine map. `UnitConverterLinear` stores a coefficient and a
constant and applies `value * coefficient + constant` toward the base unit
([`Unit.swift`][f-unit] L56–58):

```swift
// Foundation: Sources/Foundation/Unit.swift L56-58 (illustration; not runnable)
open override func baseUnitValue(fromValue value: Double) -> Double {
    return value * coefficient + constant
}
```

### `Units`: a runtime exponent map

[`Units`][units-repo] has a single non-generic `Measurement` struct
([`Measurement.swift`][u-meas] L4) wrapping a `Unit` value. A `Unit` is either `.none`,
a `.defined(DefinedUnit)`, or a `.composite([DefinedUnit: Int])`, and it computes its
**dimension as a `[Quantity: Int]` map** by summing sub-unit exponents
([`Unit.swift`][u-unit] L69–88). `Quantity` is a `RawRepresentable` struct — the 7 ISQ
base quantities plus `angle` and `data` — deliberately a struct so callers can add their
own ([`Quantity.swift`][u-quantity] L17–38). Units get a real algebra: `*`
([`Unit.swift`][u-unit] L137), `/` (L160), `pow(_ raiseTo: Int)` (L185), and
`isDimensionallyEquivalent(to:)` defined as `dimension == to.dimension` (L204–205).

---

## Dimension representation

**Foundation has no dimensional representation** in the algebraic sense this survey uses
elsewhere. A "dimension" is a _nominal class_ (`UnitLength`), and dimensional identity is
Swift's ordinary generic-type identity: `Measurement<UnitLength>` is a distinct type
from `Measurement<UnitDuration>` because `UnitLength` and `UnitDuration` are distinct
classes. There is:

- **no exponent vector** — nothing encodes that length is `L¹` and area is `L²`; they
  are two unrelated classes;
- **no product type** — no operator or type constructor yields a combined dimension, so
  a value like `m·s` or `kg·m/s²` is **unnameable** (see [Checking & inference](#checking--inference));
- **no dimension-one / dimensionless type** — there is no `Ratio`, and dimensionless
  results simply cannot arise, because products don't exist.

The generic parameter is doing the work of a _kind tag_ (nominal typing), not of a
[free-abelian-group][fag] exponent. This is the far end of the "nominal" axis in the
[mechanism taxonomy][mechanisms]: even [uom][uom]'s `dyn Dimension` trait objects encode
structural exponent vectors, whereas Foundation encodes only which of 22 fixed boxes a
value is in.

**`Units` sits at the structural pole.** Its dimension is the runtime `[Quantity: Int]`
map ([`Unit.swift`][u-unit] L69–88), so `meter * meter` and `foot * foot` are
_dimensionally equivalent_ (both `[Length: 2]`), and `newton` equals
`kilogram * meter / second²` structurally — a genuine [free-abelian-group][fag] model,
computed by dictionary merges at runtime rather than by a type checker.

## Checking & inference

Foundation's compile-time safety is **real but narrow, and asymmetric across
operators.** Two facts fix its shape.

**Addition/subtraction _are_ compile-time-guarded.** Both `+` overloads require the
_same_ `UnitType` on both operands ([`Measurement.swift`][f-meas] L108 for the
`Dimension` case, L138 for the general case):

```swift
// Foundation: Sources/Foundation/Measurement.swift L108-119 (illustration; not runnable)
extension Measurement where UnitType : Dimension {
    public static func +(lhs: Measurement<UnitType>, rhs: Measurement<UnitType>) -> Measurement<UnitType> {
        if lhs.unit.isEqual(rhs.unit) {
            return Measurement(value: lhs.value + rhs.value, unit: lhs.unit)
        } else {
            // convert both to the dimension's base unit, then add
            let l = lhs.unit.converter.baseUnitValue(fromValue: lhs.value)
            let r = rhs.unit.converter.baseUnitValue(fromValue: rhs.value)
            return Measurement(value: l + r, unit: type(of: lhs.unit).baseUnit())
        }
    }
}
```

Because there is no `+` accepting two _different_ `UnitType`s, `length + duration` has
no matching overload and is rejected during overload resolution (see
[Diagnostics](#diagnostics)). Same-dimension, different-unit addition (`meters +
feet`) _is_ allowed and auto-converts through the base unit.

**But there is no multiplication that combines dimensions.** `*` and `/` take only a
`Double` scalar ([`Measurement.swift`][f-meas] L159–179):

```swift
// Foundation: Sources/Foundation/Measurement.swift L159-179 (illustration; not runnable)
public static func *(lhs: Measurement<UnitType>, rhs: Double) -> Measurement<UnitType> { … }
public static func *(lhs: Double, rhs: Measurement<UnitType>) -> Measurement<UnitType> { … }
public static func /(lhs: Measurement<UnitType>, rhs: Double) -> Measurement<UnitType> { … }
```

There is no `Measurement × Measurement`. You can scale a length by 2, but you cannot
multiply a length by a time — not because it is a type error, but because **the
operation does not exist and its result type could not be named.** Dimensional
_inference_ (deriving `Velocity` from `Length / Time`) is therefore impossible in
principle, not merely unsupported.

**Comparison is _not_ type-safe** — the sharp asymmetry. `==` and `<` are generic over
_two independent_ unit types ([`Measurement.swift`][f-meas] L185, L207):

```swift
// Foundation: Sources/Foundation/Measurement.swift L185, L207 (illustration; not runnable)
public static func ==<LeftHandSideType, RightHandSideType>(_ lhs: Measurement<LeftHandSideType>, _ rhs: Measurement<RightHandSideType>) -> Bool
public static func  <<LeftHandSideType, RightHandSideType>(lhs: Measurement<LeftHandSideType>, rhs: Measurement<RightHandSideType>) -> Bool
```

So `length == duration` **compiles**, and returns `false` (the units share no base
unit); `length < duration` **compiles** and then `fatalError`s at runtime — "Attempt to
compare measurements with non-equal dimensions" ([`Measurement.swift`][f-meas] L219).
Foundation's dimension safety thus holds for `+`/`-` and evaporates for comparison — a
subtlety a caller cannot see from the signatures alone.

**`Units` does no compile-time checking at all.** With a single non-generic
`Measurement` type, `meter + second` type-checks and the mismatch surfaces as a thrown
error at runtime (see [Diagnostics](#diagnostics)).

## Extensibility

**Foundation extends by subclassing — `open class` is the whole extension model.**
Because `Unit` and `Dimension` are `open`, downstream code can:

- **add units to an existing quantity** by adding `class var`s (there is no macro or
  registry — a new unit is a new stored `UnitLength(symbol:converter:)`), and
- **add a whole new quantity** by writing a `final class MyQuantity : Dimension` that
  overrides `baseUnit()` ([`Unit.swift`][f-unit] L209–211).

What is _not_ extensible is the dimensional relationships: since none exist, there is
nothing to extend. You can invent `UnitApples`, but you cannot declare that
`UnitApples / UnitBasket` is a new derived quantity, because the library has no notion
of derivation. Each subclass is an island, exactly like the shipped 22.

**`Units` extends structurally.** New base quantities are `Quantity(rawValue:)`
extensions — the doc comment warns that the raw-string namespace is _global_, so two
modules picking `"Money"` silently alias ([`Quantity.swift`][u-quantity] L11–16). New
units are registered through a `Registry`/`RegistryBuilder`, and composite units arise
for free from `*`/`/`. This is the more expressive model, at the price of every check
being deferred to runtime.

## Expressiveness edges

- **Fractional powers: absent in both, but for different reasons.** Foundation has no
  power operation at all — there is no `Measurement` exponent API, because there are no
  product dimensions to raise. `Units` has `pow(_ raiseTo: Int)`
  ([`Unit.swift`][u-unit] L185) — integer exponents only; `Unit.meter.pow(2)` works,
  half-integer powers (the `V/√Hz` idiom) are unrepresentable. Neither can express
  `L^(1/2)`.
- **Affine / temperature: modeled at the conversion layer, with a real hazard.**
  Foundation's `UnitConverterLinear` carries a `constant` ([`Unit.swift`][f-unit] L45,
  L56–58), and `UnitTemperature` uses it — Celsius is `coefficient 1.0, constant
273.15`, Fahrenheit `coefficient 0.5556, constant 255.372` ([`Unit.swift`][f-unit]
  L2278–2325). But that constant is applied _inside `+`'s base-unit conversion_
  ([`Measurement.swift`][f-meas] L110–116): adding two temperatures in different units
  converts each to _absolute_ kelvin (offset included) and sums them, so
  `20 °C + 68 °F` yields `≈ 548.5 K ≈ 275.4 °C` — the sum of two absolute temperatures,
  which is physically meaningless. There is a **single `UnitTemperature` type**, no
  point-vs-interval distinction, so nothing prevents adding absolute temperatures. This
  is precisely the discipline that [Au][au]'s `QuantityPoint` and [uom][uom]'s
  `ThermodynamicTemperature`-vs-`TemperatureInterval` split exists to enforce; see the
  [torsor / affine-quantity model][torsor]. `Units` at least _guards_ the composite
  case — raising or combining a unit with a non-zero `constant` throws
  `invalidCompositeUnit`: "Nonlinear unit prevents conversion" ([`Unit.swift`][u-unit]
  L223–225) — but it, too, has no point/interval types.
- **Logarithmic quantities: absent** in both. No decibel, neper, or level quantity in
  either source tree — dB ergonomics are entirely out of scope, as in most of this
  survey ([Pint][pint] excepted).
- **Angles: a base dimension, not dimensionless-with-kind.** Foundation's `UnitAngle`
  ([`Unit.swift`][f-unit] L300–365) is just another nominal `Dimension` class — degrees,
  radians, gradians, revolutions — dimensionally unrelated to everything else (there is
  no dimensionless type to relate it to). `Units` makes `angle` an explicit **base
  quantity** in the exponent map ([`Quantity.swift`][u-quantity] L34), tracked
  structurally like length. Neither adopts the [uom][uom] "dimensionless + kind tag"
  treatment of angle.
- **Kind-vs-dimension: opposite failure modes.** Foundation's nominal typing is
  _accidentally_ a kind system — `UnitEnergy` and (a hypothetical) `UnitTorque` would be
  unrelated types — but the point is moot: Foundation has **no derived quantities**, so
  torque-as-`force·distance` and energy-as-`force·distance` never even arise to be
  confused. `Units`, being structural, has the **classic collision**: torque and energy
  both reduce to `[Mass: 1, Length: 2, Time: -2]`, so `isDimensionallyEquivalent`
  reports them equal and they interconvert silently — the very hazard [uom][uom]'s
  `Kind` associated type and [`coulomb`][coulomb] address. Neither Swift library has any
  kind mechanism to separate same-dimension quantities.

## Zero-cost story

**Neither library is zero-cost — this is the honest runtime-cost story**, and it
follows directly from representing units as heap objects.

Foundation's `Measurement` is a value struct, but its `unit: UnitType` field is a
**reference to a class instance** ([`Measurement.swift`][f-meas] L30) — so a
`Measurement<UnitLength>` is a `Double` _plus a retained class pointer_, not a bare
`Double` (contrast [uom][uom]'s `#[repr(transparent)]` guarantee that a `Length` _is_ an
`f64`). Every mixed-unit `+`/`-` reads `unit.converter` — a heap `UnitConverter` object —
and calls its **virtual** `baseUnitValue(fromValue:)` ([`Measurement.swift`][f-meas]
L113–116, dispatching to [`Unit.swift`][f-unit] L56). So arithmetic carries: a stored
class reference (with ARC retain/release), a dynamic dispatch, and the affine
conversion math. The design target was correctness-of-display, not register-level
arithmetic, and it shows.

`Units` is heavier still: a composite `Unit` stores a `[DefinedUnit: Int]` **dictionary**
([`Unit.swift`][u-unit] L60–62), and `*`/`/` build a new unit by _merging dictionaries_
([`Unit.swift`][u-unit] L137–158). A single `speed = distance / time` allocates and
populates a hash map for the resulting composite unit; `isDimensionallyEquivalent`
compares two `[Quantity: Int]` maps ([`Unit.swift`][u-unit] L204–205). Every dimensional
operation is a runtime dictionary manipulation. There is a `PerformanceTests` target in
the package, acknowledging the cost is measurable rather than theoretical.

The upshot: on the [comparison capstone][comparison]'s cost axis, both Swift libraries
sit with the interpreted/registry systems ([Pint][pint]), not with the zero-cost
type-level systems.

## Diagnostics

The mandated experiment — the two ways `m + s` is rejected.

**Foundation: a compile error, via overload resolution.** A local reproduction was
attempted with `swift 5.10.1` from nixpkgs, but that toolchain reports "glibc not found"
and its `Foundation` clang module is unavailable on this host, so `import Foundation`
fails to resolve — the reproduction **fell** (as the task anticipated for Swift on
Linux). The mechanism is nonetheless pinned to source: with `+` defined only for
matching `UnitType` ([`Measurement.swift`][f-meas] L108, L138) and no overload accepting
two different unit types, the expression

```swift
// illustration; not runnable — reproduction fell (no Foundation module in nixpkgs swift 5.10.1)
let d = Measurement(value: 5.0, unit: UnitLength.meters)     // Measurement<UnitLength>
let t = Measurement(value: 10.0, unit: UnitDuration.seconds)  // Measurement<UnitDuration>
let bad = d + t                                               // ← rejected: no matching '+'
```

is rejected during overload resolution with Swift's standard "no matching operator"
diagnostic — the compiler reports that `+` cannot be applied to operands of type
`Measurement<UnitLength>` and `Measurement<UnitDuration>`. Unlike [uom][uom]'s
`typenum`-mangled type names, the error names the domain types directly
(`Measurement<UnitLength>`), because the dimension _is_ the nominal type — a genuine
readability advantage of the nominal approach.
[reproduction attempted, `swift 5.10.1` (nixpkgs), 2026-07-04 — fell: no `Foundation` module; mechanism from source, [`Measurement.swift`][f-meas] L108/138]

The catch, from [Checking & inference](#checking--inference): swap `+` for `<` and the
_same_ mismatch **compiles**, because comparison is generic over two unit types, and
then `fatalError`s at runtime ([`Measurement.swift`][f-meas] L219). Foundation's
compile-time signal is only as strong as the operator you happen to use.

**`Units`: a thrown runtime error** — and here the reproduction has firm in-repo
grounding. The package's own test suite encodes exactly this rejection
([`Tests/UnitsTests/MeasurementTests.swift`][u-test] L45–48):

```swift
// Units: Tests/UnitsTests/MeasurementTests.swift L45-48 (in-repo compile/throw test)
// Test that adding different dimensions throws an error
XCTAssertThrowsError(
    try 5.measured(in: .meter) + 5.measured(in: .second)
)
```

The `+` operator is `throws` ([`Measurement.swift`][u-meas] L58) and routes through
`convert(to:)`, which throws when the units are not dimensionally equivalent
([`Measurement.swift`][u-meas] L44–46):

```swift
// Units: Sources/Units/Measurement/Measurement.swift L44-46 (illustration; not runnable)
guard unit.isDimensionallyEquivalent(to: newUnit) else {
    throw UnitError.incompatibleUnits(message: "Cannot convert \(unit) to \(newUnit)")
}
```

So `meter + second` **compiles and links**; the dimensional error is a
`UnitError.incompatibleUnits` thrown at runtime, exactly as the README documents
([`README.md`][u-readme] L35). For a runtime-checked library, a thrown exception _is_
the finding: the dimensional guard exists, but it fires while the program runs, not
while it builds.
[in-repo throw test: `Tests/UnitsTests/MeasurementTests.swift` L45–48; documented: `README.md` L35]

The valid path, for contrast, is what both libraries do handle: Foundation's
`meters + feet` auto-converts through the base unit ([`Measurement.swift`][f-meas]
L110–116), and `Units`' `60.measured(in: .mile / .hour) * 30.measured(in: .minute)`
produces a distance whose composite unit reduces on `convert(to: .mile)`
([`README.md`][u-readme] L26–32).

## Ergonomics & compile-time cost

**Foundation wins on availability and ceremony.** It ships with the platform — no
dependency, no build step, no metaprogramming, so compile-time cost is negligible. The
API is the familiar `Measurement(value:unit:)`, `converted(to:)`, and the
locale-aware [`MeasurementFormatter`][f-fmt] that is the library's real _raison
d'être_. For its intended job — model a quantity, convert it, show it to a user in
their units — the ergonomics are excellent, and the nominal errors (when they fire) are
readable. It simply was not built to catch `force = mass * acceleration` mistakes, and
does not.

**`Units` adds sugar at a runtime price.** `5.measured(in: .meter)` and unit expressions
like `.meter / .second` read nicely, and a `unit` CLI ships with the package. But
because `+`/`-`/`convert` are `throws`, every dimensional combination site needs `try`,
pushing error handling into ordinary arithmetic — the syntactic tax of moving the check
to runtime. Compile times are unremarkable (a small, plain-Swift package with no
metaprogramming).

Neither imposes the tens-of-seconds template/trait-solving cost of the compile-time
systems ([uom][uom], [mp-units][mp-units]) — but that is because neither does the
compile-time work that cost buys.

---

## Strengths

- **Zero-setup, standard, and familiar (Foundation)** — ships with every Swift
  toolchain; `Measurement`/`Unit`/`Dimension` + `MeasurementFormatter` cover
  conversion and locale-aware display with no dependency.
- **Readable nominal errors (Foundation)** — when `+` does reject a mismatch, the
  diagnostic names `Measurement<UnitLength>` vs `Measurement<UnitDuration>`, not a
  mangled exponent encoding.
- **Correct, extensible affine conversion mechanics** — `UnitConverterLinear`'s
  coefficient+constant handles Celsius/Fahrenheit conversion, and `open class` units
  are subclassable for custom quantities.
- **Genuine dimensional algebra (`Units`)** — structural `[Quantity: Int]` exponents
  with full `*`/`/`/`pow`, user-definable base quantities, and composite units — the
  expressiveness Foundation lacks.
- **A composite-affine guard (`Units`)** — refusing to raise/compose a unit with an
  offset (`invalidCompositeUnit`) blocks nonsense like `°C²`.

## Weaknesses

- **No product type / no derived dimensions (Foundation)** — `Measurement × Measurement`
  does not exist; `m·s`, `kg·m/s²`, `Velocity = Length/Time` are **unnameable**, and
  dimensional inference is impossible in principle.
- **Asymmetric, partly-runtime safety (Foundation)** — `+`/`-` are compile-checked, but
  `==`/`<` are generic over two unit types: cross-dimension comparison compiles, with
  `==` → `false` and `<` → runtime `fatalError`.
- **Affine hazard (Foundation)** — one `UnitTemperature`, no point/interval split, and
  the offset is applied inside `+`, so adding two absolute temperatures silently yields
  a physically meaningless result.
- **Runtime-only checking (`Units`)** — `meter + second` compiles and throws at runtime;
  every combination site needs `try`; there is no compile-time dimension safety.
- **Structural collisions (`Units`)** — torque and energy share a dimension and
  interconvert silently; no kind mechanism to separate them.
- **Not zero-cost (both)** — Foundation carries a class reference + virtual conversion
  call per op; `Units` allocates and merges dictionaries per composite unit.

## Key design decisions and trade-offs

| Decision                                                                                | Rationale                                                                                   | Trade-off                                                                                                |
| --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Foundation: dimension = nominal class identity of `UnitType` (reference type)           | Cheap to build on Swift generics; ships in the stdlib; readable domain-named errors         | No exponent algebra; no product type; `m·s` unnameable; a class reference in every value                 |
| Foundation: only `Measurement + Double` scalar ops, no `Measurement × Measurement`      | The design target is convert-and-display, not derive-quantities                             | Cannot express or infer any derived quantity; dimensional analysis is out of reach                       |
| Foundation: `==`/`<` generic over two unit types                                        | Lets any two measurements be compared syntactically (convenient for formatting/sorting)     | Cross-dimension comparison compiles; `==` → `false`, `<` → runtime `fatalError` — safety hole vs `+`/`-` |
| Foundation: lazy conversion via reference-type `UnitConverter`                          | Keeps the original unit for display; affine (offset) conversions are expressible            | Virtual dispatch + heap object per op; adding absolute temperatures via the offset is physically wrong   |
| `Units`: single non-generic `Measurement`, dimension in a runtime `[Quantity: Int]` map | Full structural algebra (`*`/`/`/`pow`), user-definable base quantities, no metaprogramming | All checking is runtime; `+`/`-` are `throws`; per-op dictionary allocation; torque/energy collide       |
| `Units`: `throws` on dimension mismatch                                                 | Surfaces the error with a message instead of silently miscomputing                          | `try` at every combination site; the mistake escapes the type system to runtime                          |

## Sources

- [swiftlang/swift-corelibs-foundation — GitHub repository][repo] (pinned locally at
  `$REPOS/swift/swift-corelibs-foundation` @ `cd04666`, 2026-07-01)
- [`Sources/Foundation/Measurement.swift` — the `Measurement<UnitType>` struct, `+`/`-` (same-`UnitType`), scalar `*`/`/`, generic `==`/`<`, affine `+` conversion][f-meas]
- [`Sources/Foundation/Unit.swift` — `Unit`/`Dimension` classes, `UnitConverterLinear` (coefficient+constant), 22 quantity subclasses, `UnitTemperature`][f-unit]
- [`Sources/Foundation/MeasurementFormatter.swift` — locale-aware display, the library's primary consumer][f-fmt]
- [NeedleInAJayStack/Units — GitHub repository][units-repo] (pinned at `$REPOS/swift/Units` @ `08ab9be`, 2026-07-03, `v1.2.0`)
- [`Sources/Units/Unit/Unit.swift` — runtime `[Quantity: Int]` dimension, `*`/`/`/`pow`, `isDimensionallyEquivalent`, affine `toBaseUnit`/`invalidCompositeUnit` guard][u-unit]
- [`Sources/Units/Measurement/Measurement.swift` — non-generic `Measurement`, `throws` `+`/`-`, `convert(to:)` throwing `incompatibleUnits`][u-meas]
- [`Sources/Units/Quantity.swift` — `RawRepresentable` base quantities][u-quantity] · [`Sources/Units/UnitError.swift` — the error enum][u-err]
- [`Tests/UnitsTests/MeasurementTests.swift` — the in-repo `XCTAssertThrowsError(meter + second)` test][u-test] · [`README.md` — the "runtime error is thrown" contract][u-readme]
- [Apple Developer docs: `Measurement`][apple-measurement] · [`Unit`/`Dimension`][apple-dimension]
- `m + s` provenance: Foundation reproduction attempted with `swift 5.10.1` (nixpkgs), 2026-07-04 — fell (no `Foundation` module); mechanism pinned to `Measurement.swift` L108/138. `Units`: in-repo throw test `MeasurementTests.swift` L45–48 + documented `README.md` L35.
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [free abelian group][fag] · [torsors & affine quantities][torsor] ·
  [Kennedy's type system][kennedy] · [uom][uom] · [Au][au] · [mp-units][mp-units] ·
  [Pint][pint] · [UCUM/QUDT][ucum] · [`coulomb`][coulomb] · [`squants`][squants] ·
  [Nim `unchained`][nim] · [Kotlin `measured`][kotlin] · [F# units][fsharp] ·
  [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone (swift-corelibs-foundation @ cd04666) -->

[repo]: https://github.com/swiftlang/swift-corelibs-foundation
[f-meas]: https://github.com/swiftlang/swift-corelibs-foundation/blob/cd04666/Sources/Foundation/Measurement.swift
[f-unit]: https://github.com/swiftlang/swift-corelibs-foundation/blob/cd04666/Sources/Foundation/Unit.swift
[f-fmt]: https://github.com/swiftlang/swift-corelibs-foundation/blob/cd04666/Sources/Foundation/MeasurementFormatter.swift

<!-- Pinned clone (NeedleInAJayStack/Units @ 08ab9be) -->

[units-repo]: https://github.com/NeedleInAJayStack/Units
[u-unit]: https://github.com/NeedleInAJayStack/Units/blob/08ab9be/Sources/Units/Unit/Unit.swift
[u-meas]: https://github.com/NeedleInAJayStack/Units/blob/08ab9be/Sources/Units/Measurement/Measurement.swift
[u-quantity]: https://github.com/NeedleInAJayStack/Units/blob/08ab9be/Sources/Units/Quantity.swift
[u-err]: https://github.com/NeedleInAJayStack/Units/blob/08ab9be/Sources/Units/UnitError.swift
[u-test]: https://github.com/NeedleInAJayStack/Units/blob/08ab9be/Tests/UnitsTests/MeasurementTests.swift
[u-readme]: https://github.com/NeedleInAJayStack/Units/blob/08ab9be/README.md

<!-- Official docs -->

[apple-measurement]: https://developer.apple.com/documentation/foundation/measurement
[apple-dimension]: https://developer.apple.com/documentation/foundation/dimension

<!-- Same-tree theory -->

[kennedy]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md

<!-- Tree concepts / comparison -->

[comparison]: ./comparison.md

<!-- Sibling system pages -->

[uom]: ./rust-uom.md
[au]: ./cpp-au.md
[mp-units]: ./cpp-mp-units.md
[pint]: ./python-pint.md
[fsharp]: ./fsharp-uom.md
[coulomb]: ./scala-coulomb.md
[squants]: ./scala-squants.md
[nim]: ./nim-unchained.md
[kotlin]: ./kotlin-measured.md
[ucum]: ./ucum-qudt.md
