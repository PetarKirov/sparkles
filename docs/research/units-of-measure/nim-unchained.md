# unchained (Nim)

A compile-time-only Nim units library whose quantities are `distinct float`
types and whose entire dimensional algebra runs inside term-rewriting macros over
an integer [`QuantityPowerArray`][quantities] — so a checked value _is_ a bare
`float` at runtime, with no dimension data and no wrapper left behind.

| Field            | Value                                                                                                                         |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Language         | Nim (`requires "nim >= 1.6.0"`; verified here on `nim 2.2.4`)                                                                 |
| License          | MIT (declared in [`unchained.nimble`][nimble] L6; there is no standalone `LICENSE` file in the tree)                          |
| Repository       | [SciNim/Unchained][repo]                                                                                                      |
| Documentation    | [`README.org`][readme] (the primary reference) · generated API docs via the `gen_docs` nimble task                            |
| Key authors      | Sebastian Schmidt (`Vindaar`) and contributors, under the [SciNim][scinim] scientific-computing org                           |
| Category         | Library-level [compile-time checking][concepts] (no compiler support; a macro-based DSL on stock Nim)                         |
| Mechanism        | `distinct float` unit types; dimensions are integer exponent arrays reduced and compared inside Nim macros at compile time    |
| Exponent domain  | `ℤ` — `QuantityPower.power: int` ([`ct_unit_types.nim`][ctunit] L31, [`quantities.nim`][quantities] L15–18); **no rationals** |
| Checking time    | Compile time (macros evaluated during semantic analysis); zero runtime checks and zero runtime dimension representation       |
| Analyzed version | `426d72a` (pinned clone, 2025-11-20; `unchained.nimble` version `0.4.8`, git tag `v0.4.8`)                                    |
| Latest release   | `v0.4.8` (git tag; the project publishes no GitHub "release", only the nimble/tag version)                                    |

> [!NOTE]
> `unchained` is this survey's **Nim** data point for the **integer-exponent-array,
> compile-time-macro** mechanism: the checker _evaluates_ dimension arithmetic the
> author spelled out — reducing each side to a base-quantity power vector and
> comparing — with no compiler plugin and no Kennedy-style inference of unknown
> exponents (contrast [F#][fsharp] and [`uom-plugin`][uom-plugin]; see
> [Kennedy's type system][kennedy] and the [mechanism taxonomy][mechanisms]). Its
> closest relatives are the type-level-integer libraries [`uom`][uom] and
> [`dimensioned`][dimensioned] in Rust and [mp-units][mp-units] in C++, but the
> comparison is instructive precisely where it breaks: `unchained` does its exponent
> arithmetic in macro code over a runtime [`seq`][quantities] rather than in a trait
> solver over [`typenum`][uom], and it keeps **no** kind/tag slot at all
> ([free abelian group][fag] · [type-system mechanisms][mechanisms]). Wave-2
> siblings: [coulomb][coulomb] and [squants][squants] (Scala), [swift-units][swift],
> [measured][measured] (Kotlin), and the [UCUM/QUDT][ucum] data model. See the
> [comparison capstone][comparison] for the synthesis.

---

## Overview

### What it solves

`unchained` gives Nim programs dimensional analysis that is _checked entirely at
compile time_ and _costs nothing at runtime_. Every unit is a `distinct float`, and
every operation between units is a macro that inspects the compile-time unit of each
operand, does the dimensional bookkeeping, and emits ordinary float arithmetic. The
`README.org` states the positioning in its first sentences ([`README.org`][readme]
L4–7):

```text
Unchained is a fully type safe, compile time only units library. There is
*absolutely no* performance loss over pure float based code (aside from insertion
of possible conversion factors, but those would have to be written by hand
otherwise of course).
```

The distinguishing ergonomic claim is that composite units need never be predeclared
— arbitrary products synthesize their own type on the fly ([`README.org`][readme]
L26–33):

```nim
# unchained README.org L28-32 (illustration; nim 2.2.4)
import unchained
let x = 10.m * 10.m * 10.m * 10.m * 10.m
doAssert typeof(x) is Meter⁵
```

`Meter⁵` was never defined; the `*` macro built the type. This is the library's
signature move and the reason its whole model is macro-driven rather than
type-level.

### Design philosophy

Three decisions define `unchained` against the other systems in this survey.

**Units are `distinct float`, not a generic wrapper.** The foundation is a short
chain of `distinct` types ([`core_types.nim`][coretypes] L17–24):

```nim
# unchained src/unchained/core_types.nim L17-24
type
  Unit* = distinct FloatType
  Quantity* = distinct Unit
  CompoundQuantity* = distinct Quantity
  Dimensionless* = distinct Quantity
  UnitLess* = distinct Dimensionless
```

`Meter`, `KiloGram`, `Newton`, and every composite like `Meter⁵` are `distinct`
descendants of these. Because Nim's `distinct` carries **no** representation
overhead, a `KiloGram` occupies exactly the bytes of a `float`; there is no phantom
field to elide (contrast [`uom`][uom]'s `#[repr(transparent)]` `PhantomData`
struct — `unchained` needs no such guarantee because there is no wrapper to begin
with). All the dimensional information lives in the _name_ of the distinct type, and
is recovered by macros re-parsing that name at compile time.

**The dimension is data the macro computes, not a type the solver equates.** A
quantity's dimension is a [`QuantityPowerArray`][quantities] — a fixed-length `seq`
of `QuantityPower{quant, power: int}`, one slot per base quantity
([`quantities.nim`][quantities] L11–23). Operators reduce both operands to this
array and compare with a plain structural `==` ([`quantities.nim`][quantities]
L123–128). Nothing is solved for; the macro _evaluates_ the arithmetic the author
wrote, exactly as [`uom`][uom]'s trait solver evaluates `typenum` sums — but here in
imperative Nim run at compile time.

**The unit system is user-declarable from scratch.** The built-in SI is itself just
a use of the public DSL — `declareQuantities` then `declareUnits`
([`si_units.nim`][siunits] L8–43, L53–251). A downstream module can import only the
[`api`][api]/`ct_api` submodules and declare an entirely different set of base
quantities and units ([`examples/custom_unit_system.nim`][custom]), so "SI" is a
default, not a hardwired assumption.

---

## How it works

There is no procedural macro, no build step, and no runtime library of dimensions —
everything is `macro` code executed during semantic analysis.

### Declaring quantities and units (the DSL)

`declareQuantities` parses a `Base:`/`Derived:` block into `CTQuantity` objects and
generates the `distinct` quantity types plus a `QuantityKind` enum
([`quantities.nim`][quantities] L187–353). The SI base set is seven quantities
([`si_units.nim`][siunits] L8–16):

```nim
# unchained src/unchained/si_units.nim L8-40 (abridged)
declareQuantities:
  Base:
    Time
    Length
    Mass
    Current
    Temperature
    AmountOfSubstance
    Luminosity
  Derived:
    Velocity:  [(Length, 1), (Time, -1)]
    Force:     [(Mass, 1), (Length, 1), (Time, -2)]
    Energy:    [(Mass, 1), (Length, 2), (Time, -2)]
    Torque:    [(Mass, 1), (Length, 2), (Time, -2)]
    # ...
```

A derived quantity is a named list of `(base, power)` pairs — an integer exponent
vector spelled out by the author. `declareUnits` then attaches concrete units to
those quantities, marking base units and giving non-base units a `conversion:` to an
existing unit ([`si_units.nim`][siunits] L53–251), e.g. `Meter` (base, quantity
`Length`), `Newton` (derived, quantity `Force`), and `Pound` (`conversion:
0.45359237.kg`).

### The value type and the parse-compute-emit loop

At runtime a unit value is a `distinct float`. At compile time, each arithmetic
macro runs the same three-step loop:

1. **Parse** both operands' types back into a `UnitProduct` — a `seq` of
   `UnitInstance{unit, prefix, power: int, value}` ([`ct_unit_types.nim`][ctunit]
   L27–39) — via `parseDefinedUnit`.
2. **Compute** the result: reduce each side to a `QuantityPowerArray`, compare, and
   (for `*`/`/`) add or subtract the exponent vectors, simplifying and merging SI
   prefixes.
3. **Emit** a `quote do:` block that (a) `defUnit`s the freshly computed result type
   if it does not yet exist and (b) performs the underlying `float` operation,
   inserting literal scale factors only when a prefix/unit conversion is required.

The `*` macro is the canonical example ([`units.nim`][units] L312–353):

```nim
# unchained src/unchained/units.nim L312-327 (abridged)
macro `*`*[T: SomeUnit|SomeNumber; U: SomeUnit|SomeNumber](x: T; y: U): untyped =
  var xCT = parseDefinedUnit(x)
  let yCT = parseDefinedUnit(y)
  # ... reduce, add exponent vectors, simplify, merge prefixes ...
  let resType = xCT.simplify(mergePrefixes = true).toNimType()
  result = quote do:
    defUnit(`resType`)
    `resType`(`xr`.FloatType * `yr`.FloatType)
```

The emitted body is a bare `float` multiply cast to the computed distinct type; the
`defUnit(`resType`)` line is what makes `Meter⁵` (or any never-before-seen composite)
materialize as a type. `SomeUnit` is a Nim `concept` — `concept x: isAUnit(x)`
([`units.nim`][units] L13–15) — so the operators match any unit type and reject
non-units at overload resolution.

---

## Dimension representation

A dimension is a **fixed-length integer exponent vector**, the
[`QuantityPowerArray`][quantities]. Its element type is
`QuantityPower{quant: CTBaseQuantity, power: int}` and the array has one slot per
declared base quantity ([`quantities.nim`][quantities] L11–23):

```nim
# unchained src/unchained/quantities.nim L15-23
QuantityPower* = object
  quant*: CTBaseQuantity
  power*: int

QuantityPowerArray* {.requiresInit.} = object
  data: seq[QuantityPower]
```

Equality of dimensions is a component-wise integer comparison
([`quantities.nim`][quantities] L123–128), and `commonQuantity` is defined as "same
reduced power array" ([`define_units.nim`][defunits] L47–54):

```nim
# unchained src/unchained/define_units.nim L47-54
proc commonQuantity*[...](a: T; b: U): bool =
  let aQuant = a.toQuantityPower()
  let bQuant = b.toQuantityPower()
  result = aQuant == bQuant
```

Three consequences follow directly from this representation:

- **Powers are integers, full stop.** `QuantityPower.power` and `UnitInstance.power`
  are both `int`. The source even flags the ceiling in a comment on the field: "we
  could make the power a `Rational` and that way support `sqrt` and things in a ~
  reasonable way without having to rely on float hacks" ([`ct_unit_types.nim`][ctunit]
  L31–33). Rational exponents are absent by construction — a finding shared with
  [`uom`][uom] and [`dimensioned`][dimensioned] and contrasted by [mp-units][mp-units].
- **Normalization is explicit and imperative.** Unlike [`uom`][uom]'s trait-object
  identity (where two spellings of the same exponent vector are literally the same
  type), `unchained` must _reduce_ each `UnitProduct` — flattening compounds, merging
  duplicate bases, sorting — in macro code (`simplify`/`flatten`,
  [`define_units.nim`][defunits] L231, L281) before comparing. Correctness rests on
  that reduction, not on the type system.
- **The derived-quantity _name_ is not part of the dimension.** Because
  `commonQuantity` compares only the reduced base-quantity vector, two derived
  quantities with the same base decomposition are dimensionally identical. `Torque`
  and `Energy` are both declared `(Mass, 1), (Length, 2), (Time, -2)`
  ([`si_units.nim`][siunits] L25–26), so `unchained` treats them as one dimension —
  there is **no** kind/tag slot to separate them (see
  [Expressiveness edges](#expressiveness-edges)). This is the sharpest structural
  contrast with [`uom`][uom]'s `Kind`.

Dimensionless is the all-zero vector, surfaced as the `UnitLess` distinct type with a
`converter` to `float` so unitless ratios flow into `std/math`
([`core_types.nim`][coretypes] L23–24, [`units.nim`][units] L50–53).

## Checking & inference

All checking happens **inside the operator macros**, during semantic analysis. Each
of `+`, `-`, `*`, `/`, `==`, `<`, `<=` is a macro over
`[T: SomeUnit|SomeNumber; U: SomeUnit|SomeNumber]` that parses both operands, and:

- if the two `UnitProduct`s are identical, emits the raw float op;
- else if `commonQuantity` holds (same reduced dimension, different unit/prefix),
  converts both to the base type and emits float ops with literal scale factors;
- else calls `error(...)` — a hard compile error raised from within the macro
  ([`units.nim`][units] L238–265 for `+`, L267–296 for `-`, L188–204 for `==`).

So the "type checking" is not the Nim type system equating types; it is the macro
_evaluating_ the dimensional arithmetic and choosing to emit code or an error. In the
[mechanism taxonomy][mechanisms] this is the "checker evaluates, never solves" row,
alongside [`uom`][uom] and [`dimensioned`][dimensioned] and opposite the
[AG-unification][kennedy] of F# / `uom-plugin`.

**Forward inference is good; backward inference is absent.** Because the result type
is computed by the macro, `let v = length / time` gives `v` its `Velocity`-shaped
type with no annotation, and `Meter⁵` appears from `10.m * ... * 10.m`. What cannot
happen is inferring an operand's dimension from a desired result: there is no
Kennedy-style principal type, and `sqrt`'s argument dimension is not derived from an
expected output.

**Dimensional polymorphism uses Nim `concept`s.** Every quantity gets a generated
`concept` that matches any unit of that quantity ([`define_units.nim`][defunits]
L746–766):

```nim
# unchained src/unchained/define_units.nim L762-766 (generated per quantity)
type
  Length* = concept x
    isAUnit(x)
    isQuantity(x, Length)
```

So a function can be written against a _quantity_, accepting metres, kilometres, or
inches alike ([`README.org`][readme] L74–85):

```nim
# unchained README.org L78-85 (illustration; nim 2.2.4)
proc force[M: Mass, A: Acceleration](m: M, a: A): Force = m * a
let f = force(80.kg, 9.81.m•s⁻²)
doAssert typeof(f) is Newton
doAssert f == 784.8.N
```

This is genuinely more ergonomic than [`uom`][uom]'s seven-fold `typenum`
where-clauses for the same generality — the concept hides the exponent bookkeeping —
though it inherits the same limitation that the return dimension (`Force`) must be
nameable, not solved for.

## Extensibility

Extension is a strength, and it comes in three tiers grounded in shipped code:

- **New composite units — automatic.** Any product/quotient synthesizes its result
  type via the `defUnit` emitted inside the operator macro; no declaration is needed
  before `10.m * 10.m` yields `Meter²`. To _name_ a composite for use in a signature
  or `to` target, `defUnit(km•h⁻¹)` declares it explicitly ([`units.nim`][units]
  L125–185); `toDef` both defines and converts in one step ([`units.nim`][units]
  L475–498).
- **New named units on an existing quantity — a `declareUnits` entry** with a
  `conversion:` to a known unit. The shipped SI adds dozens this way (`Pound`,
  `ElectronVolt`, `LightYear`, …, [`si_units.nim`][siunits] L126–251), and SI-prefixed
  variants are generated in bulk by `generateSiPrefixedUnits`
  ([`si_units.nim`][siunits] L268–289).
- **A whole new system — `declareQuantities` + `declareUnits` from scratch.**
  [`examples/custom_unit_system.nim`][custom] builds a toy system with base
  quantities `Line`, `Triangle`, `Circle`, … and derived `Car = (Circle, 4),
(Rectangle, 1)`, then does dimensional analysis over them
  ([`custom_unit_system.nim`][custom] L11–75). The base-quantity set is _not_ closed
  the way [`uom`][uom]'s per-system exponent length is: you declare exactly the bases
  you want.

The one real limitation is that the definitions populate **global compile-time
tables** (`QuantityTab`, and a global `UnitTable`, both `{.compileTime.}` vars —
[`quantities.nim`][quantities] L55–57). There is a single active unit registry per
compilation, so a module that `import unchained` gets SI and cannot trivially host a
second, independent system alongside it in the same scope; a custom system imports
the bare `api`/`ct_api` instead of the SI-populated `unchained`.

## Expressiveness edges

- **Fractional powers: absent.** Exponents are `int`, so `sqrt` succeeds only when
  _every_ component power is even; otherwise the macro raises a compile error
  ([`units.nim`][units] L393–416):

  ```nim
  # unchained src/unchained/units.nim L406-410
  for u in mitems(mType.units):
    if u.power mod 2 == 0: # can be divided
      u.power = u.power div 2
    else:
      error("Cannot take the `sqrt` of input unit " & $(typ.toNimType()) &
        " as it's not a perfect square!")
  ```

  `sqrt(1.m)` therefore fails at compile time (reproduced below); `sqrt(1.m²)` gives
  `1.m`. The library is clever enough to flatten derived units first, so
  `sqrt(1.W•Ω⁻¹)` succeeds as `1.A` because `W·Ω⁻¹` reduces to `A²`
  ([`units.nim`][units] L399–403, test at [`tests/tunchained.nim`][tests] L1078–1083).
  But there is no type for `L^(1/2)`, so no `V/√Hz`-style noise-density idiom.

- **Affine / temperature quantities: absent.** The only temperature base unit is
  `Kelvin` ([`si_units.nim`][siunits] L68–70); there is no `Celsius`/`Fahrenheit`
  offset unit anywhere in the tree, and every non-base unit is defined by a _pure
  multiplicative_ `conversion:` factor ([`si_units.nim`][siunits] L126–251) — the DSL
  has no slot for an additive origin. There is thus no point-vs-difference
  distinction, no `QuantityPoint` analogue; this is the [torsor / affine-quantity
  model][torsor] left entirely unimplemented (contrast [`uom`][uom]'s
  temperature-only affine handling and [mp-units][mp-units]' general `quantity_point`).

- **Logarithmic quantities: absent.** No decibel, neper, or level quantity exists in
  the unit tables; the `Bel`/`dB` idiom is out of scope, as in most systems here
  ([Pint][pint] being the exception).

- **Angles are dimensionless, kept apart only as a _unit_.** `Angle` is declared as a
  _derived_ quantity `(Length, 1), (Length, -1)` ([`si_units.nim`][siunits] L36),
  which reduces to the all-zero vector — so its dimension is literally dimensionless
  (a `quantityOf(1.rad)` renders empty, matching `UnitLess`; verified against the
  pinned clone). `Radian` and `Steradian` survive as _distinct units_ only because
  they are flagged `autoConvert: false`, which stops `flatten` from silently dropping
  them ([`si_units.nim`][siunits] L116–124). So `unchained` keeps `rad` visible in
  types but does **not** give angle a dimension or kind of its own.

- **Kind-vs-dimension disambiguation: none — same dimension means interchangeable.**
  Because `commonQuantity` compares only reduced base vectors and there is no kind
  slot, quantities that share a dimension are freely combinable. `Torque` (`N•m`) and
  `Energy` (`J`) share `M·L²·T⁻²`; `Frequency` (`Hz`) and `Activity` (`Bq`) share
  `T⁻¹` — and both pairs add without complaint
  [reproduced locally, `nim 2.2.4` (nixpkgs), 2026-07-04]:

  ```text
  # against the pinned clone
  let torque = 5.N•m
  let energy = 3.J
  echo torque + energy        # => 8 N•m   (typeof: Joule)
  echo typeof(2.Hz + 4.Bq)    # => Hertz
  ```

  This is the exact capability [`uom`][uom]'s `Kind` mechanism exists to provide, and
  `unchained` does not have it: it is a pure dimension checker, not a
  quantity-kind checker. The `QuantityKind` enum it generates
  ([`quantities.nim`][quantities] L311–324) is used for pretty-naming and lookup, not
  for gating operations.

- **Automatic unit/prefix reconciliation on `+`/`-`/comparison.** Where a dimension
  _does_ match but units differ, the macro converts to the base unit and inserts the
  scale factor, so `5.kg + 5.lbs` compiles and yields kilograms
  ([`README.org`][readme] L34–40, [`units.nim`][units] L249–265). This is real
  ergonomic value the dimension-only model still delivers.

## Zero-cost story

The zero-cost claim here is _stronger and cheaper to justify_ than most in this
survey, because the mechanism guarantees it structurally:

- **A unit is a `distinct float`.** `Unit* = distinct FloatType`
  ([`core_types.nim`][coretypes] L17–18), and Nim's `distinct` types share the
  representation of their base with no added storage. There is no wrapper struct and
  no phantom field — unlike [`uom`][uom], which needs `#[repr(transparent)]` +
  `PhantomData` to _reach_ the same guarantee, `unchained` has nothing to elide.
- **Arithmetic emits bare float ops.** Every operator macro's emitted body is a plain
  `float` operation cast to the result type, e.g.
  `` `resType`(`xr`.FloatType * `yr`.FloatType) `` ([`units.nim`][units] L327). No
  dimension object is constructed, compared, or stored at runtime; the entire check
  happened in the compiler.
- **The only runtime cost is deliberate conversion factors**, and only when the
  author mixes prefixes/units of the same quantity — the macro multiplies by a
  compile-time literal scale ([`units.nim`][units] L261–263). The README frames this
  precisely as the sole exception ("aside from insertion of possible conversion
  factors, but those would have to be written by hand otherwise" —
  [`README.org`][readme] L4–7).

The honest counterweight is that the cost is not eliminated but _relocated to compile
time_ (see [Ergonomics & compile-time cost](#ergonomics-compile-time-cost)): the macro
loop re-parses type names and manipulates `seq`s on every operation, and the source
notes even that caching unit-name strings "is 50% slower than just regenerating them"
([`ct_unit_types.nim`][ctunit] L53). Runtime is free; the compiler pays.

## Diagnostics

The mandated experiment — adding a `Meter` to a `Second` — compiled against the
pinned clone with `nim c --path:$REPOS/nim/unchained/src`:

```nim
# reproduced locally — mps.nim
import unchained
let x = 1.m + 1.s
echo x
```

```text
stack trace: (most recent call last)
.../unchained/src/unchained/units.nim(265, 10) +
mps.nim(2, 13) template/generic instantiation of `+` from here
.../unchained/src/unchained/units.nim(265, 10) Error: Different quantities
  cannot be added! Quantity 1: m, Quantity 2: s
```

[reproduced locally, `nim 2.2.4` (nixpkgs), 2026-07-04]

This is the **best-in-class end of the survey's diagnostics**: the message is written
in the domain's language — "Different quantities cannot be added! Quantity 1: m,
Quantity 2: s" — not the implementation's. There is no `typenum` binary encoding to
decode (as in [`uom`][uom]'s `PInt<UInt<UTerm, B1>>`), no nameless positional array
(as in [`dimensioned`][dimensioned]): the macro rendered the offending units with
their short names via `pretty(...)` in the `error(...)` call
([`units.nim`][units] L265). The one blemish is the leaked implementation frame — the
stack trace points at `units.nim(265,10)` (inside the `+` macro) rather than only at
the user's line, a normal artifact of a macro-raised error. The exact-line error is
encoded in the repo's own compile-fail tests, which assert the rejection with a
`fails(...)` (`when compiles` negation) template
([`tests/tunchained.nim`][tests] L4–8, L115–118):

```nim
# unchained tests/tunchained.nim L115-118
test "Math: `+` of units - different quantities cannot be added":
  let a = 10.kg
  let b = 5.m
  check fails(a + b)
```

The two other edges reproduce the same way. `sqrt` of a non-square unit
[reproduced locally, `nim 2.2.4`, 2026-07-04]:

```text
# sqrt(10.m)
.../unchained/src/unchained/units.nim(410, 12) Error: Cannot take the `sqrt` of
  input unit Meter as it's not a perfect square!
```

and feeding a non-dimensionless quantity to `sin` fails at overload resolution,
because only `UnitLess` has a `converter` to `float`
([`units.nim`][units] L50) — `sin(10.m / 5.kg)` reports a plain `type mismatch`
against `func sin(x: float64)`, the `m•kg⁻¹` argument having no path to `float`
[reproduced locally, `nim 2.2.4`, 2026-07-04]. The valid counterpart compiles and
runs [reproduced locally, `nim 2.2.4`, 2026-07-04]:

```nim
# reproduced locally — same dimension, mixed units and prefixes
let sum = 5.kg + 5.lbs          # => KiloGram (auto-converted)
let v = 100.m / 4.s             # => Meter•Second⁻¹  (Velocity-shaped)
doAssert typeof(1.m * 1.m * 1.m) is Meter³   # composite synthesized on the fly
```

## Ergonomics & compile-time cost

**Surface ergonomics are excellent for the common cases** — `import unchained`, then
`10.m`, `9.81.m•s⁻²`, `5.kg + 5.lbs`, `f.to(kN)`. Composites need no declaration to
_use_ in expressions, quantity `concept`s make dimension-polymorphic functions short,
and error messages read in domain terms. The notable friction is _syntactic_: the
product separator is the Unicode bullet `•` and exponents are Unicode superscripts
(`m•s⁻²`), chosen deliberately to sidestep Nim's identifier rules
([`README.org`][readme] L187–224). The library offers an ASCII-in-accented-quotes
escape hatch — ``10.`m*s^-2` `` — but the README concedes it "does _not_ allow you to
write actual unit names in function arguments or return types"
([`README.org`][readme] L226–231). The separator is configurable via
`-d:UnicodeSep=·` ([`core_types.nim`][coretypes] L47).

**Compile-time cost is the real price, and it is significant.** Because every unit
operation runs a parse-reduce-emit macro over `seq`s of unit instances — with string
manipulation of type names throughout — dimension-heavy code is slow and
memory-hungry to compile. The project's own test suite quarantines a regression test
for exactly this reason, and the nimble file is candid about it
([`unchained.nimble`][nimble] L23–26):

```nim
# unchained unchained.nimble L23-26
task regressionTests, "Run regression tests (require cligen)":
  # NOTE: the following even compiled before, but took 10 GB of RAM. In a CI this
  # will fail for that reason, locally we just test it by hand
  exec "nim c -r tests/test_issue04_modified.nim"
```

A single stress test taking ~10 GB of compiler RAM — excluded from CI as
unaffordable — is the clearest statement of the model's cost profile: zero at
runtime, potentially very large at compile time, and super-linear in the complexity
of the unit expressions the compiler must reduce. For typical scientific code the
cost is unremarkable; for machine-generated or deeply nested unit expressions it can
dominate the build.

---

## Strengths

- **True zero runtime cost, structurally guaranteed** — units are `distinct float`
  with no wrapper; arithmetic emits bare float ops. The zero-cost claim needs no
  benchmark because there is nothing at runtime to measure
  ([`core_types.nim`][coretypes] L17–18, [`units.nim`][units] L327).
- **Best-in-survey diagnostics** — errors are raised by the macro in domain language
  ("Different quantities cannot be added! Quantity 1: m, Quantity 2: s"), with no
  type-level encoding leaking into the message
  ([`units.nim`][units] L265).
- **Composite units synthesize on the fly** — `10.m * 10.m` yields `Meter²` and
  `Meter⁵` needs no predeclaration; a genuine ergonomic edge over predefine-everything
  systems ([`README.org`][readme] L26–33).
- **Fully user-declarable unit systems** — `declareQuantities`/`declareUnits` build
  arbitrary base quantities and units; the base set is not fixed
  ([`custom_unit_system.nim`][custom]).
- **Quantity `concept`s give clean dimensional polymorphism** — functions over
  `Mass`, `Length`, `Velocity` without exponent-vector boilerplate
  ([`define_units.nim`][defunits] L746–766).
- **Automatic prefix/unit reconciliation** — mixed-unit same-dimension arithmetic
  (`5.kg + 5.lbs`) converts and works ([`README.org`][readme] L34–40).

## Weaknesses

- **Integer-only exponents** — no `ℚ` powers, so `sqrt` is partial (perfect squares
  only) and half-integer dimensions are unwritable; the source itself notes `Rational`
  powers as an unrealized wish ([`ct_unit_types.nim`][ctunit] L31–33).
- **No kind mechanism** — same-dimension quantities are interchangeable: `Torque + Energy`
  and `Hz + Bq` both compile, so the classic collision pairs are _not_ distinguished
  (reproduced; [`si_units.nim`][siunits] L25–26). A capability [`uom`][uom] has and
  `unchained` lacks.
- **No affine/temperature or logarithmic quantities** — only `Kelvin`, only
  multiplicative conversions; no Celsius offset, no decibel
  ([`si_units.nim`][siunits] L68–70, L126–251).
- **Angles are dimensionless** — `Angle = Length/Length` collapses to the zero
  vector; `rad` survives only as a non-auto-converting _unit_, not a distinct
  dimension ([`si_units.nim`][siunits] L36, L116–124).
- **Heavy, unbounded compile-time cost** — the macro reduction is slow and
  memory-hungry; a real regression test cost ~10 GB of compiler RAM and is barred from
  CI ([`unchained.nimble`][nimble] L23–26).
- **Unicode-heavy surface syntax** — `•` and superscripts are required for unit
  _types_; the ASCII escape hatch cannot be used in signatures
  ([`README.org`][readme] L187–231).
- **A single global unit registry per compilation** — custom systems must avoid
  importing the SI-populated `unchained`; two live systems don't trivially coexist
  ([`quantities.nim`][quantities] L55–57).

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                              | Trade-off                                                                                                          |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Units as `distinct float`, no wrapper struct                     | Zero-cost by construction — a unit _is_ its scalar; nothing to elide                   | All dimensional info lives in the type _name_, forcing macros to re-parse names on every operation                 |
| Dimension algebra in term-rewriting macros over an integer `seq` | Runs on stock Nim, no plugin; composites synthesize on the fly; domain-language errors | Cost moves to compile time and can explode (~10 GB RAM on a stress test); correctness rests on `reduce`/`simplify` |
| Integer `QuantityPower.power`                                    | Simple, decidable exponent arithmetic; matches SI's integer dimensions                 | No rational powers; `sqrt` partial; half-integer dimensions unrepresentable                                        |
| Compare only reduced base-quantity vectors (`commonQuantity`)    | Automatic reconciliation of any same-dimension units; simple, uniform check            | No kind/tag slot — `Torque`≡`Energy`, `Hz`≡`Bq`; derived-quantity names are cosmetic                               |
| Multiplicative-only `conversion:` in the DSL                     | Keeps every unit a pure scaling of its base; conversions fold to compile-time literals | No affine/offset units (Celsius, temperature points); no torsor/point-vs-difference model                          |
| User-declarable systems via `declareQuantities`/`declareUnits`   | Not tied to SI; arbitrary base quantities; extensible without forking                  | Global compile-time registry — one active system per compilation; SI import blocks a second system                 |
| Quantity `concept`s for polymorphism                             | Short, readable dimension-generic functions (`proc force[M: Mass, A: Acceleration]`)   | The return dimension must be nameable; no inference of unknown exponents (no Kennedy principal types)              |
| Unicode `•` + superscripts for unit types                        | Circumvents Nim identifier rules so composites parse unambiguously                     | Awkward to type; the ASCII accented-quote escape hatch is unusable in signatures                                   |

## Sources

- [SciNim/Unchained — GitHub repository][repo] (pinned locally at
  `$REPOS/nim/unchained` @ `426d72a`, 2025-11-20)
- [`README.org` — positioning, zero-cost claim, on-the-fly composites, prefix reconciliation, concept polymorphism, syntax rationale][readme]
- [`src/unchained/core_types.nim` — the `distinct float` unit chain, SI prefixes, `UnicodeSep`][coretypes]
- [`src/unchained/quantities.nim` — `QuantityPower`/`QuantityPowerArray`, `declareQuantities`, `QuantityKind` enum][quantities]
- [`src/unchained/ct_unit_types.nim` — `UnitInstance`/`UnitProduct`, the integer `power` field + `Rational` TODO][ctunit]
- [`src/unchained/units.nim` — the operator macros (`+`,`-`,`*`,`/`,`==`,`<`), `sqrt`, `defUnit`, `to`, `SomeUnit` concept][units]
- [`src/unchained/define_units.nim` — `commonQuantity`, `flatten`/`simplify`, `isAUnit`, `generateQuantityConcepts`][defunits]
- [`src/unchained/si_units.nim` — the SI `declareQuantities`/`declareUnits` invocation; base units, derived quantities, prefixed-unit generation][siunits]
- [`src/unchained/api.nim` — the public API surface for custom unit systems][api]
- [`examples/custom_unit_system.nim` — a from-scratch non-SI system][custom]
- [`tests/tunchained.nim` — compile-fail (`fails`/`when compiles`) tests for cross-quantity math and `sqrt`][tests]
- [`unchained.nimble` — MIT license, version `0.4.8`, the ~10 GB regression-test note][nimble]
- Local reproductions (`m + s`, `sqrt(m)`, `sin(m/kg)`, `Torque+Energy`, `Hz+Bq`, valid ops): scratch programs compiled against the pinned clone with `nim 2.2.4` (nixpkgs), 2026-07-04
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [Kennedy's type system][kennedy] · [free abelian group][fag] ·
  [torsors & affine quantities][torsor] · [`uom`][uom] · [`dimensioned`][dimensioned] ·
  [mp-units][mp-units] · [F# units of measure][fsharp] · [`uom-plugin`][uom-plugin] ·
  [Pint][pint] · [coulomb][coulomb] · [squants][squants] · [swift-units][swift] ·
  [measured][measured] · [UCUM/QUDT][ucum] · [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone (unchained @ 426d72a) -->

[repo]: https://github.com/SciNim/Unchained
[readme]: https://github.com/SciNim/Unchained/blob/426d72a/README.org
[coretypes]: https://github.com/SciNim/Unchained/blob/426d72a/src/unchained/core_types.nim
[quantities]: https://github.com/SciNim/Unchained/blob/426d72a/src/unchained/quantities.nim
[ctunit]: https://github.com/SciNim/Unchained/blob/426d72a/src/unchained/ct_unit_types.nim
[units]: https://github.com/SciNim/Unchained/blob/426d72a/src/unchained/units.nim
[defunits]: https://github.com/SciNim/Unchained/blob/426d72a/src/unchained/define_units.nim
[siunits]: https://github.com/SciNim/Unchained/blob/426d72a/src/unchained/si_units.nim
[api]: https://github.com/SciNim/Unchained/blob/426d72a/src/unchained/api.nim
[custom]: https://github.com/SciNim/Unchained/blob/426d72a/examples/custom_unit_system.nim
[tests]: https://github.com/SciNim/Unchained/blob/426d72a/tests/tunchained.nim
[nimble]: https://github.com/SciNim/Unchained/blob/426d72a/unchained.nimble

<!-- Official / org -->

[scinim]: https://github.com/SciNim

<!-- Same-tree theory -->

[kennedy]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[uom]: ./rust-uom.md
[dimensioned]: ./rust-dimensioned.md
[mp-units]: ./cpp-mp-units.md
[fsharp]: ./fsharp-uom.md
[uom-plugin]: ./haskell-uom-plugin.md
[pint]: ./python-pint.md
[coulomb]: ./scala-coulomb.md
[squants]: ./scala-squants.md
[swift]: ./swift-units.md
[measured]: ./kotlin-measured.md
[ucum]: ./ucum-qudt.md
