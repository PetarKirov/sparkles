# measured (Kotlin)

A small Kotlin Multiplatform library that encodes a quantity's dimension directly as the generic parameter of `Measure<T: Units>`, builds compound dimensions out of nested generic types (`UnitsProduct`, `UnitsRatio`, `InverseUnits`) rather than an exponent vector, and combines them through a hand-written table of `operator fun` overloads — type-safe at compile time, with dimensions fully erased at runtime.

| Field            | Value                                                                                                                                                                                                                   |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | Kotlin (declared toolchain `2.3.20`); Kotlin Multiplatform — JVM (target 1.8), JS, Wasm-JS, iOS, macOS, watchOS, tvOS, Android-Native, `mingwX64`, `linux{X64,Arm64}`                                                   |
| License          | MIT                                                                                                                                                                                                                     |
| Repository       | [nacular/measured][repo]                                                                                                                                                                                                |
| Documentation    | [Dokka API site][docs] · [`README.md`][readme] · [`Module.md`][module]                                                                                                                                                  |
| Key authors      | Nicholas Eddy (`nacular`; formerly `pusolito`)                                                                                                                                                                          |
| Category         | Library-level [compile-time checking][concepts] (no compiler support; ordinary generics + operator overloading)                                                                                                         |
| Mechanism        | Dimension **is** the generic parameter `T` of `Measure<T: Units>`; compound dimensions are nested generic types (`UnitsProduct<A, B>`, `UnitsRatio<A, B>`, `InverseUnits<T>`) combined by a hand-written overload table |
| Exponent domain  | **None explicit** — powers are structural product types (`Square<T> = UnitsProduct<T, T>`); Kotlin has no type-level integers, so no fractional and no general exponent algebra                                         |
| Checking time    | Compile time (Kotlin type-checker + overload resolution); JVM type erasure leaves **no** runtime dimension representation                                                                                               |
| Analyzed version | `3f65500` (pinned clone, 2026-04-05; tag `v0.5.0` points at this commit)                                                                                                                                                |
| Latest release   | `v0.5.0` (2026-04-05)                                                                                                                                                                                                   |

> [!NOTE]
> `measured` is this survey's data point for the **nested-generics-as-dimensions,
> no-exponent-algebra** mechanism: unlike the exponent-vector systems ([`uom`][uom]'s
> `typenum` `ℤ⁷`, [Boost.Units][boost]'s MPL type-lists) that _compute_ a normal form,
> `measured` never normalizes — `A·B` and `B·A` are distinct types, and every legal
> combination is a separately-written `operator fun` overload. It is the JVM cousin of
> [`squants`][squants] (also value-in-the-type on the JVM, but class-based rather than
> generic) and a lighter contrast to Scala's type-level [`coulomb`][coulomb]. Read it
> against the [type-system mechanism taxonomy][mechanisms] and the
> [free-abelian-group model][fag] it deliberately does _not_ implement. See the
> [comparison capstone][comparison] for the cross-system synthesis.

---

## Overview

### What it solves

`measured` gives Kotlin code compile-time dimensional analysis with an "intuitive,
mathematical" surface: a value carries its unit in its static type, so passing metres
where seconds are expected is a type error, and multiplying/dividing quantities yields
new compound-unit types. The README states the positioning in its first paragraph
([`README.md`][readme] L8):

> "Measured provides a safe and simple way to work with units of measure. It uses the
> compiler to ensure correctness, and provides intuitive, mathematical operations to
> work with any units. This means you can write more robust code that avoids implicit
> units. Time handling for example, is often done with implicit assumptions about
> milliseconds vs microseconds or seconds. Measured helps you avoid pitfalls like
> these."

The shipped model is deliberately small — seven dimension files
(`Length`, `Mass`, `Time`, `Angle`, `BinarySize`, `GraphicsLength`, and the compound
`Velocity`/`Acceleration` aliases) sitting on one 429-line core
([`Units.kt`][units]) — and its ambition is ergonomics on the JVM/Multiplatform stack
(UI/graphics/time code) rather than a complete SI. The `time` example is the library's
motivating case: `Measure<Time>` makes "is this milliseconds or seconds?" a
type-checked question, with the base unit fixed at milliseconds
([`Time.kt`][time] L11).

### Design philosophy

Two decisions define `measured` against the other systems in this survey.

**The dimension _is_ the generic parameter, not an exponent vector.** A quantity is
`Measure<T: Units>` where `T` is the unit's own type; a compound dimension is a
_nested generic type_ built from three combinators —
`UnitsProduct<A, B>`, `UnitsRatio<A, B>`, and `InverseUnits<T>`
([`Units.kt`][units] L55, L66, L77). `Velocity` is literally the type alias
`UnitsRatio<Length, Time>` ([`Units.kt`][units] L427). There is no exponent list and
no reduction step: the "algebra" of dimensions is emulated by a large table of
`operator fun` overloads that spell out each legal shape by hand (see
[How it works](#how-it-works)).

**A unit carries only a scale factor to its base.** The whole of the `Units` base class
is a `suffix` string and a multiplicative `ratio` to the base unit
([`Units.kt`][units] L17):

```kotlin
// measured: Units.kt L17 — the entire unit model is a suffix + a scale ratio
abstract class Units(val suffix: String, val ratio: Double = 1.0) {
    // ...display helpers, equals/hashCode over (suffix, ratio)...
}
```

Everything downstream — conversion (`in`/`as`), comparison, the compound-unit `ratio`
products — is arithmetic on that single `Double`. This is what makes the library tiny
and extensible, and it is also the source of its sharpest limitation: a purely
multiplicative `ratio` cannot express an **affine** unit like Celsius or Fahrenheit
(see [Expressiveness edges](#expressiveness-edges)), which the README states outright
([`README.md`][readme] L144–146):

> "Measured currently only supports linear units where all members of a given unit are
> related by a single magnitude. This applies to many units, but Fahrenheit and Celsius
> are examples of temperature units that requires more than a multiplier for
> conversion."

---

## How it works

### `Units` — a unit is a labelled scale factor

Every concrete dimension is an `open class` extending `Units`, declaring its members as
`companion object` constants whose `ratio` places them relative to the base unit. The
base unit takes the default `ratio = 1.0`; the rest are multiples of it
([`Length.kt`][length] L6–18):

```kotlin
// measured: Length.kt L6-18 (abridged) — members are scale factors off the base (m)
open class Length(suffix: String, ratio: Double = 1.0): Units(suffix, ratio) {
    operator fun div(other: Length) = ratio / other.ratio    // Length / Length -> Double

    companion object {
        val meters      = Length("m"            )            // base: ratio 1.0
        val centimeters = Length("cm",   0.0100)
        val kilometers  = Length("km", 1000.0000)
        val miles       = Length("mi", 1609.3440)
        // ...
    }
}
```

Conversion is a single division of ratios. `Measure<T>.in` returns the magnitude in a
requested member, and `as` returns a re-based `Measure` ([`Units.kt`][units] L103–108):

```kotlin
// measured: Units.kt L103-108
infix fun <A: T> `as`(other: A): Measure<T> = if (units == other) this else Measure(this `in` other, other)
infix fun <A: T> `in`(other: A): Double = if (units == other) amount else amount * (units.ratio / other.ratio)
```

### `Measure<T>` — the value carrier

`Measure<T: Units>` is the one value type: an `amount: Double` plus its `units: T`,
implementing `Comparable<Measure<T>>` ([`Units.kt`][units] L98). Same-dimension
arithmetic lives on it as members, so both operands must have the _same_ `T`
([`Units.kt`][units] L113–131):

```kotlin
// measured: Units.kt L113-131 (abridged) — same-dimension add/sub/scale; note the shared T
class Measure<T: Units>(val amount: Double, val units: T): Comparable<Measure<T>> {
    operator fun plus (other: Measure<T>): Measure<T> = minOf(units, other.units).let { Measure((this `in` it) + (other `in` it), it) }
    operator fun minus(other: Measure<T>): Measure<T> = minOf(units, other.units).let { Measure((this `in` it) - (other `in` it), it) }
    operator fun times(other: Number    ): Measure<T> = amount * other.toDouble() * units   // scalar
    operator fun div  (other: Number    ): Measure<T> = amount / other.toDouble() * units    // scalar
    // ...
}
```

`plus`/`minus` convert both operands to the _smaller_ unit (via `minOf` on the ratios,
[`Units.kt`][units] L84–89) and add — so `500 m + 1.5 km` is well-typed and yields
`2000 m` (verified locally, [Diagnostics](#diagnostics)). Because both parameters are
`Measure<T>` with the _same_ `T`, adding a `Measure<Length>` to a `Measure<Time>` has
no matching overload and is a compile error — the core of the
[`m + s` experiment](#diagnostics).

### The overload table — dimensional "algebra" spelled out by hand

Cross-dimension multiplication and division are **free functions**, not members, and
there is one overload per structural shape of the operands. The base case builds a
product type; a matching inverse cancels to a raw `Double`
([`Units.kt`][units] L166–176, L228):

```kotlin
// measured: Units.kt L166-176, L228 (abridged) — a slice of the Units*Units / Measure*Measure table
operator fun <A: Units, B: Units> A.times(other: B              ): UnitsProduct<A, B> = UnitsProduct(this, other)  // A * B
@JvmName("times7") operator fun <A: Units> A.times(other: InverseUnits<A>): Double    = ratio * other.ratio        // A * (1/A) -> scalar
operator fun <A: Units, B: Units> A.times(other: UnitsRatio<B, A>): Measure<B>        = ratio / other.denominator.ratio * other.numerator

// and on Measures:
@JvmName("times1") operator fun <A: Units, B: Units> Measure<A>.times(other: Measure<B>): Measure<UnitsProduct<A, B>> = amount * other.amount * (units * other.units)
```

`@JvmName` disambiguation is pervasive because JVM erasure collapses these signatures to
the same descriptor. `Units.kt` carries **127** `operator fun` declarations across four
regions (`Units * Units`, `Units / Units`, `Measure * Measure`, `Measure / Measure`, plus
`Measure * Units` and `Number - Measure`). Crucially, the table is _incomplete by
construction_: **16** combinations are checked in as commented-out `// FIXME` lines —
every one of them a `UnitsProduct` operand that Kotlin's overload resolution cannot
disambiguate from its siblings ([`Units.kt`][units] L179–186, L281–288):

```kotlin
// measured: Units.kt L179-186 — the acknowledged holes in the algebra (commented out)
// FIXME operator fun <A: Units, B: Units> UnitsProduct<A, B>.times(other: InverseUnits<A>): Measure<B> = units * other
// FIXME operator fun <A: Units, B: Units> UnitsProduct<A, B>.times(other: InverseUnits<B>): A          = units * other
// ...six more...
```

This is the mechanism's signature trade-off, examined under
[Extensibility](#extensibility) and [Weaknesses](#weaknesses): with no exponent
normal form, cancellation and re-association must each be enumerated, and some
enumerations collide.

---

## Dimension representation

The dimension of a quantity is **the generic type argument `T` of `Measure<T: Units>`**,
carried structurally: a base dimension is a leaf `Units` subclass (`Length`, `Time`, …),
and a compound dimension is a nested tree of three combinators
([`Units.kt`][units] L55–77):

- `UnitsProduct<A, B>` — the product `A·B`, with `ratio = A.ratio * B.ratio`
  ([`Units.kt`][units] L55).
- `UnitsRatio<A, B>` — the quotient `A/B`, with a lazily-built `reciprocal`
  ([`Units.kt`][units] L66–68).
- `InverseUnits<T>` — `1/T`, with `ratio = 1 / T.ratio` ([`Units.kt`][units] L77).

Powers are **structural, not numeric**: the only "power" is
`typealias Square<T> = UnitsProduct<T, T>` ([`Units.kt`][units] L57), i.e. a product
type. There is no type-level integer anywhere; `Acceleration` is spelled
`UnitsRatio<Length, Square<Time>>` ([`Units.kt`][units] L428), a nested tree, not an
exponent `T⁻²`. Three consequences follow directly, and distinguish `measured` from
every exponent-vector system in this survey:

- **No normal form.** The type checker never reduces a dimension. `UnitsProduct<A, B>`
  and `UnitsProduct<B, A>` are different types; `A·A⁻¹` does not automatically reduce to
  dimensionless — it reduces only because a specific overload
  (`A.times(InverseUnits<A>): Double`, [`Units.kt`][units] L167) is written to return a
  raw `Double`. Order-sensitivity is documented as a first-class limitation
  ([`README.md`][readme] L112–122): `radians * seconds` has type
  `UnitsProduct<Angle, Time>` and `seconds * radians` has type
  `UnitsProduct<Time, Angle>`, and the two are not interchangeable (reproduced under
  [Diagnostics](#diagnostics)).
- **Dimensionless collapses to `Double`.** Because cancellation is modeled by overloads
  that _return_ `Double` (or a scale factor), a fully-cancelled quantity is a bare
  `Double`, not a distinguished dimensionless `Measure`. There is no dimension-one type
  in the [free-abelian-group][fag] sense; `measured` approximates the group with a
  finite, hand-written multiplication table rather than realizing it.
- **The runtime carries nothing.** On the JVM, `Measure<Length>` and `Measure<Time>`
  are the _same erased class_ `Measure`; the dimension exists only in the static type
  tree. Safety is entirely a compile-time property (see [Zero-cost story](#zero-cost-story)).

## Checking & inference

Checking is **ordinary Kotlin type-checking plus operator-overload resolution** — no
compiler plugin, no annotation processor, no code generation (the source even muses
"`// TODO: Kapt code generation possible?`", [`Units.kt`][units] L244). Two rules do all
the work:

- **Addition/subtraction demand identical `T`.** `plus`/`minus` are members of
  `Measure<T>` taking `Measure<T>` ([`Units.kt`][units] L113–118); a mismatched
  dimension has no applicable overload and fails resolution. This is the `m + s`
  rejection.
- **Multiplication/division select a compound result type by structural pattern.** The
  free-function table ([`Units.kt`][units] L166–320) picks the overload whose parameter
  shapes match the operands and produces the corresponding nested-generic result. Where
  the table has an entry, the result type is inferred with no annotation; forward
  inference is pleasant — the README's `val velocity = 5 * meters / seconds` infers
  `Measure<Velocity>` without a written type ([`README.md`][readme] L36).

What the checker **cannot** do:

- **Invert arithmetic or generalize over dimension.** There is no Kennedy-style
  principal-type inference ([Kennedy's type system][kennedy]); a function generic over
  "any dimension raised to a power" cannot be written, because there is no type-level
  exponent to be generic over. User code can be generic over a _fixed_ shape
  (`fun <T: Units> f(m: Measure<T>)`), as `abs`/`round`/`ceil`/`floor` are
  ([`Units.kt`][units] L346–361), but not over the exponent algebra.
- **Resolve every compound combination.** The `// FIXME` gaps
  ([`Units.kt`][units] L179–186, L281–288) mean some well-defined products of
  `UnitsProduct` operands simply have no overload and won't type-check — the checker is
  as complete as the hand-written table, no more.

## Extensibility

Extensibility is where `measured`'s value-is-a-scale-factor model shines, and where its
no-algebra model shows its seams.

- **New members on an existing dimension — trivial.** Because a unit is just a
  `suffix` + `ratio`, a new `Length` is one constructor call from user code, and it
  interoperates immediately ([`README.md`][readme] L72–84):

  ```kotlin
  // measured: README.md L73-80 — a user-defined Length member, no library change
  val hands = Length("hands", 0.1016)     // define new unit inline
  val v: Measure<Velocity> = 100_000 * hands / hours
  println(5 * hands `as` meters)          // 0.508 m
  ```

- **New dimensions — a small class.** A brand-new dimension is an `open class`
  extending `Units` with a `companion object` of members and a
  `div(other: Self): Double` for same-dimension division; the README's `Blits` example
  builds one and composes it into `UnitsRatio<Blits, Time>` compound types
  ([`README.md`][readme] L88–110). No registration step exists — there is no central
  dimension registry, because there is no exponent vector whose length would need
  fixing.

- **New _compound_ interactions — potentially manual.** This is the cost of the
  non-normalizing design. Any product/quotient shape the built-in table doesn't cover
  needs a user-supplied `operator fun`. The README documents the canonical case —
  **operand order** — and shows the fix as a hand-written extension
  ([`README.md`][readme] L124–142):

  ```kotlin
  // measured: README.md L128-134 — user extension to canonicalize Mass-before-Length ordering
  operator fun Length.times(mass: Mass) = mass * this
  val f1 = 1 * (kilograms * meters) / (seconds * seconds)
  val f2 = 1 * (meters * kilograms) / (seconds * seconds)   // f1 and f2 now share a type
  ```

  The library ships exactly this workaround for its own dimensions — `Time · Length`
  is redirected to `Length · Time` ([`Length.kt`][length] L23–24) and
  `Length · Mass` to `Mass · Length` ([`Mass.kt`][mass] L15–16) — proof that
  canonicalization is a per-pair chore, not a systemic guarantee.

There is no cross-"system" story because there are no systems: every dimension is a
peer `Units` subclass in one flat namespace, and any two can be multiplied the moment an
overload (built-in or user-written) connects them.

## Expressiveness edges

- **Fractional powers: impossible.** Powers are structural product types
  (`Square<T> = UnitsProduct<T, T>`, [`Units.kt`][units] L57) and Kotlin has no
  type-level integers, so there is no `sqrt` on dimensions and no way to spell
  `Length^(1/2)`. Not merely unimplemented — unrepresentable in the mechanism, a
  stronger absence than [`uom`][uom]'s integer-only limitation.
- **Affine / temperature: absent by design.** `Units` carries only a multiplicative
  `ratio` ([`Units.kt`][units] L17); there is **no `Temperature` dimension at all** in
  the library (a search of `src/` finds no temperature file), precisely because °C/°F
  need an additive offset the model can't hold. The README says so directly
  ([`README.md`][readme] L144–146, quoted in [Design philosophy](#design-philosophy)).
  For how a proper point-vs-difference treatment would look, see the
  [torsor / affine-quantity model][torsor]; `measured` implements none of it.
- **Logarithmic quantities: absent.** No decibel, neper, or level type; the model is
  purely multiplicative scale factors. (`BinarySize` covers bits/bytes and their
  decimal _and_ binary multiples — kB vs KiB — but these are ordinary ratios, not a
  log scale; [`BinarySize.kt`][binarysize].)
- **Angle: a first-class dimension, not dimensionless-with-tag.** Unlike the
  kind-tagged approaches, `Angle` is a genuine `Units` subclass with `radians` (base)
  and `degrees` (`ratio = π/180`, printed without a space) and its own trig
  ([`Angle.kt`][angle] L11–19): `sin`/`cos`/`tan` take a `Measure<Angle>` and convert
  to radians internally ([`Angle.kt`][angle] L21–33). The upside is that a bare
  `Double` cannot be passed where an angle is expected; the downside is that angle is
  not unified with the dimensionless `Double` that cancellation produces, so
  `AngularVelocity · Time` does not automatically land back on `Angle` — it depends on
  which overloads exist.
- **Kind-vs-dimension disambiguation: not modeled.** There is no `Kind` tag
  (contrast [`uom`][uom]); same-dimension-different-meaning quantities (torque vs
  energy, frequency vs becquerel) are not distinguished, because the library's scope is
  a handful of physical/graphics dimensions rather than a complete ISQ. The one
  meaning-level distinction it _does_ draw — `Length` vs `GraphicsLength` (physical
  distance vs on-screen pixels, [`GraphicsLength.kt`][graphics]) — is achieved simply by
  making them separate `Units` subclasses, so pixels and metres never accidentally add.

## Zero-cost story

`measured`'s cost story is **runtime-representational, not zero-cost-in-the-Rust-sense**,
and it is honest to say so:

- **Dimensions are erased, but the wrapper is not free.** `Measure<T>` is a real heap
  class (`class Measure<T: Units>(val amount: Double, val units: T)`,
  [`Units.kt`][units] L98) holding a boxed `Double` amount _and_ a reference to a
  `Units` object. It is **not** `@JvmInline value class`-optimized; there is no
  `#[repr(transparent)]` analogue. Every `Measure` is an allocation, and every
  arithmetic op allocates a new one (e.g. `plus` returns a fresh `Measure`,
  [`Units.kt`][units] L113). So the safety is compile-time-only, but the runtime pays
  object and boxing overhead that a raw `Double` would not — the opposite pole from
  [`uom`][uom]'s verified `size_of::<Length>() == size_of::<f64>()`.
- **The unit's `ratio` is consulted at runtime.** Conversion (`in`/`as`) and
  same-unit-normalizing `plus`/`minus` do `Double` divisions on `units.ratio` at
  runtime ([`Units.kt`][units] L108, L113); compound `ratio` is recomputed by
  multiplying the operands' ratios ([`Units.kt`][units] L55). None of this is folded
  away — the unit objects are live values, not phantom types.
- **Type erasure has a soundness cost.** `Measure.equals` casts an untyped
  `Measure<*>` to `Measure<T>` with an **unchecked cast** ([`Units.kt`][units] L149) —
  the compiler emits `warning: unchecked cast of 'Measure<*>' to 'Measure<T>'`
  (observed locally while compiling the clone). Comparing two erased `Measure`s of
  different dimensions via `equals` does not fail at compile time and can compare
  ratio-scaled amounts across dimensions; the static safety guarantee covers the typed
  operators (`+`, `-`, `*`, `/`), not reflective/erased paths.

The correct framing: `measured` buys **compile-time dimensional safety** at the price of
**ordinary boxed-object runtime overhead** — an ergonomic, not a zero-cost, library.

## Diagnostics

The mandated experiment — adding a `Length` to a `Time` — compiled against the pinned
clone's sources with `kotlinc-jvm` from `nixpkgs`:

```kotlin
// locally reproduced — MPlusS.kt, compiled with the measured sources on the classpath
import io.nacular.measured.units.*
import io.nacular.measured.units.Length.Companion.meters
import io.nacular.measured.units.Time.Companion.seconds

fun main() {
    val m = 1 * meters
    val s = 1 * seconds
    val bad = m + s   // should not compile
    println(bad)
}
```

```text
MPlusS.kt:8:19: error: argument type mismatch: actual type is 'Measure<Time>', but 'Measure<Length>' was expected.
    val bad = m + s   // should not compile
                  ^
```

[reproduced locally, `kotlinc-jvm 2.2.21` (nixpkgs, JRE 21), against `measured` sources @ `3f65500`, 2026-07-04]

The diagnostic is **excellent** — and this is a genuine differentiator from the
exponent-vector systems. Because the dimension is a plain nominal type (`Length`,
`Time`) rather than a `typenum` binary encoding, the error names the domain types
directly: _actual `Measure<Time>`, expected `Measure<Length>`_. There is no
`PInt<UInt<UTerm, B1>>` mangling ([`uom`][uom]'s weak flank), no eight-way
associated-type record, no truncation-to-file. The mechanism explaining it: `plus` is
`Measure<T>.plus(other: Measure<T>)` ([`Units.kt`][units] L113), so with `T = Length`
fixed by the receiver, `Measure<Time>` simply isn't an applicable argument.

The **valid same-dimension path** compiles and runs, confirming mixed-unit addition and
`L/T → Velocity` inference [reproduced locally, `kotlinc-jvm 2.2.21`, 2026-07-04]:

```kotlin
// locally reproduced — Valid.kt; prints "2000.0 m" then "500.0 m/s"
val d = 500 * meters + 1.5 * kilometers   // OK: same dimension, mixed units -> 2000 m
val v: Measure<Velocity> = d / (4 * seconds)
println(d)                                // 2000.0 m
println(v `as` meters / seconds)          // 500.0 m/s
```

The library's own **order-sensitivity** limitation reproduces as a compile error too —
`UnitsProduct<Angle, Time>` is not assignable to `UnitsProduct<Time, Angle>`
([`README.md`][readme] L112–122):

```text
Order.kt:8:40: error: initializer type mismatch: expected 'UnitsProduct<Time, Angle>', actual 'UnitsProduct<Angle, Time>'.
    val c: UnitsProduct<Time, Angle> = radians * seconds  // should FAIL: order-sensitive
                                       ^^^^^^^^^^^^^^^^^
```

[reproduced locally, `kotlinc-jvm 2.2.21`, 2026-07-04]

This is the flip side of the great `m + s` message: the same lack of normalization that
keeps error types readable also makes `A·B` ≠ `B·A` a real, user-visible type error the
README must warn about and patch by hand. The in-repo tests corroborate the _positive_
behaviour (the operators are exercised in
[`UnitTests.kt`][unittests] L616–627, `plusMinusOperatorsWork`), but there is no
compile-fail test harness in the repo — the rejection evidence here is the local
reproduction, rung 1 of the provenance ladder.

## Ergonomics & compile-time cost

**The surface is genuinely pleasant.** Kotlin's infix functions and operator
overloading let the DSL read like maths: `5 * meters / seconds`,
`duration `in` milliseconds`, `distance `as` kilometers`
([`README.md`][readme] L36–50). Named members off companion objects
(`Length.meters`) and the `Number.times(Units)` bridge ([`Units.kt`][units] L328,
L335) make construction terse. For the library's target domains — time handling,
graphics, everyday physical quantities on Kotlin Multiplatform — this is a low-ceremony,
high-readability experience, and the error messages (above) are among the most readable
in the survey.

**Compile-time cost is modest.** The model is small (one 429-line core + seven short
dimension files), so there is no macro expansion or type-family solving to pay for. A
full JVM compile of the entire library plus a small consumer file finishes in **~4.2 s
wall** (`kotlinc-jvm 2.2.21`, `-include-runtime`), most of it compiler/JVM startup
rather than type-checking [measured locally, 2026-07-04]. The latent cost is
**overload-resolution pressure**: 127 `operator fun` overloads distinguished by
`@JvmName` and generic shape mean that deeply-nested compound expressions can force the
resolver to consider many candidates, and — as the `// FIXME` lines attest — some shapes
are ambiguous enough that no overload could be written at all. In practice this bites as
_missing_ operators (a compile error telling you the combination is unsupported), not as
slow builds.

**The ergonomic cliff is compound arithmetic beyond the shipped table.** Everyday
one- and two-factor expressions are covered; three-plus-factor products, or any product
of `UnitsProduct` operands, may hit a `// FIXME` hole and require the user to write an
extension `operator fun` (and possibly an order-canonicalizing one, per the README's
guidance). The library is optimized for the common case, and explicit about where the
common case ends.

---

## Strengths

- **Readable, domain-language diagnostics** — because dimensions are nominal generic
  types, a mismatch reads _expected `Measure<Length>`, actual `Measure<Time>`_, with no
  `typenum`-style encoding or truncation; among the clearest error messages in the
  survey ([Diagnostics](#diagnostics)).
- **Tiny, transparent model** — one 429-line core; a unit is a `suffix` + `ratio`, a
  dimension is a class, a compound dimension is a nested generic. Easy to read end to
  end and to extend.
- **Trivial user extension of units and dimensions** — new members and whole new
  dimensions are a few lines from user code, no registry, no macro
  ([`README.md`][readme] L72–110).
- **Kotlin Multiplatform reach** — the same dimensional machinery runs on JVM, JS,
  Wasm-JS, and a broad Native matrix (iOS/macOS/watchOS/tvOS/Android-Native/Windows/
  Linux), which is the library's real distribution advantage.
- **Ergonomic operator DSL** — infix `in`/`as`, operator `* / + -`, and companion-object
  members make quantity code read mathematically.
- **Angle as a real dimension** — trig is angle-typed, so radians/degrees can't be
  confused with a bare `Double` ([`Angle.kt`][angle]).

## Weaknesses

- **No exponent algebra → order-sensitive, hole-ridden compound types** —
  `A·B ≠ B·A`, dimensionless collapses to `Double`, and **16** `UnitsProduct`
  combinations are un-writable `// FIXME` gaps ([`Units.kt`][units] L179–186,
  L281–288). Canonicalization is a per-pair manual chore ([Extensibility](#extensibility)).
- **No fractional powers, and none possible** — powers are product types; Kotlin lacks
  type-level integers, so `sqrt`/rational exponents are unrepresentable, not just
  unimplemented.
- **No affine/temperature support at all** — `Units` holds only a multiplicative
  `ratio`; there is no `Temperature` dimension, and the README states °C/°F are out of
  scope ([`README.md`][readme] L144–146).
- **Not zero-cost at runtime** — `Measure<T>` is a heap object with a boxed `Double`
  and a `Units` reference; no `value class`/`repr(transparent)`; every op allocates
  ([Zero-cost story](#zero-cost-story)).
- **Erasure soundness gap** — `Measure.equals` does an unchecked cast
  ([`Units.kt`][units] L149); reflective/erased paths escape the static guarantee that
  the typed operators enforce.
- **No `Kind`-style same-dimension disambiguation** — torque vs energy, Hz vs Bq, etc.,
  are not modeled; scope is a small dimension set, not a complete ISQ.
- **No dimensional polymorphism / inference** — generic-over-power functions can't be
  written; there is nothing like [Kennedy][kennedy]-style principal types.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                       | Trade-off                                                                                                          |
| ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Dimension = the generic parameter `T` of `Measure<T: Units>`        | No new machinery — plain generics + operator overloading; excellent nominal-type error messages | JVM erasure leaves no runtime dimension; unchecked-cast soundness gaps on erased paths                             |
| Compound dimensions as nested generic types, not an exponent vector | Simple, transparent, no reduction engine; readable diagnostics                                  | No normal form: `A·B ≠ B·A`, dimensionless collapses to `Double`, cancellation must be enumerated                  |
| Combine dimensions via a hand-written `operator fun` overload table | Direct, debuggable; each legal shape has an explicit, readable definition                       | 127 overloads with `@JvmName` disambiguation; **16 `// FIXME`** un-writable holes; per-pair order canonicalization |
| A unit is a `suffix` + multiplicative `ratio` only                  | Tiny model; trivial to add units/dimensions; conversion is one division                         | Cannot express affine units — no Celsius/Fahrenheit, no `Temperature` dimension at all                             |
| `Measure<T>` as an ordinary class (not a `value class`)             | Simplicity; carries the live `Units` object for printing/conversion                             | Boxing + allocation per value and per operation; not zero-cost                                                     |
| Kotlin Multiplatform, no compiler plugin / annotation processing    | One library across JVM/JS/Wasm/Native; fast builds; no codegen step                             | No type-level power arithmetic or dimensional inference is achievable within the mechanism                         |

## Sources

- [nacular/measured — GitHub repository][repo] (pinned locally at
  `$REPOS/kotlin/measured` @ `3f65500`, tag `v0.5.0`, 2026-04-05)
- [`src/commonMain/kotlin/io/nacular/measured/units/Units.kt` — the entire model: `Units`, `Measure<T>`, `UnitsProduct`/`UnitsRatio`/`InverseUnits`, the operator table, `// FIXME` gaps, `Velocity`/`Acceleration` aliases][units]
- [`Length.kt` / `Time.kt` / `Mass.kt` / `Angle.kt` / `BinarySize.kt` / `GraphicsLength.kt` — the shipped dimensions and their scale-factor members][length]
- [`Angle.kt` — angle as a first-class dimension with degrees/radians and trig][angle]
- [`BinarySize.kt` — decimal (kB) and binary (KiB) storage multiples][binarysize]
- [`README.md` — positioning, complex-units examples, extensibility, and the "Current Limitations" section (order-sensitivity, linear-only/temperature)][readme] · [`Module.md`][module]
- [`src/commonTest/kotlin/io/nacular/measured/units/UnitTests.kt` — operator behaviour tests (`plusMinusOperatorsWork`, L616)][unittests]
- [Dokka API documentation site][docs]
- Local reproductions (`m + s` rejection, valid mixed-unit addition + `L/T → Velocity`,
  order-sensitivity rejection, unchecked-cast warning, ~4.2 s compile timing):
  scratch workspace compiling the pinned clone's sources, `kotlinc-jvm 2.2.21`
  (nixpkgs, JRE 21), 2026-07-04
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [free abelian group][fag] · [torsors & affine quantities][torsor] ·
  [Kennedy's type system][kennedy] · [`squants`][squants] · [`coulomb`][coulomb] ·
  [`uom`][uom] · [Boost.Units][boost] · [mp-units][mp-units] · [`dimensioned`][dimensioned] ·
  [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone (measured @ 3f65500) -->

[repo]: https://github.com/nacular/measured
[units]: https://github.com/nacular/measured/blob/3f65500/src/commonMain/kotlin/io/nacular/measured/units/Units.kt
[length]: https://github.com/nacular/measured/blob/3f65500/src/commonMain/kotlin/io/nacular/measured/units/Length.kt
[time]: https://github.com/nacular/measured/blob/3f65500/src/commonMain/kotlin/io/nacular/measured/units/Time.kt
[mass]: https://github.com/nacular/measured/blob/3f65500/src/commonMain/kotlin/io/nacular/measured/units/Mass.kt
[angle]: https://github.com/nacular/measured/blob/3f65500/src/commonMain/kotlin/io/nacular/measured/units/Angle.kt
[binarysize]: https://github.com/nacular/measured/blob/3f65500/src/commonMain/kotlin/io/nacular/measured/units/BinarySize.kt
[graphics]: https://github.com/nacular/measured/blob/3f65500/src/commonMain/kotlin/io/nacular/measured/units/GraphicsLength.kt
[unittests]: https://github.com/nacular/measured/blob/3f65500/src/commonTest/kotlin/io/nacular/measured/units/UnitTests.kt
[readme]: https://github.com/nacular/measured/blob/3f65500/README.md
[module]: https://github.com/nacular/measured/blob/3f65500/Module.md

<!-- Official docs -->

[docs]: https://nacular.github.io/measured/

<!-- Same-tree theory -->

[mechanisms]: ./theory/type-system-mechanisms.md
[fag]: ./theory/free-abelian-group.md
[torsor]: ./theory/torsor-representation.md
[kennedy]: ./theory/kennedy-types.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[squants]: ./scala-squants.md
[coulomb]: ./scala-coulomb.md
[uom]: ./rust-uom.md
[dimensioned]: ./rust-dimensioned.md
[boost]: ./cpp-boost-units.md
[mp-units]: ./cpp-mp-units.md
