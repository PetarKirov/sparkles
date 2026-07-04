# dimensional (Haskell)

The venerable statically-typed units library of the Haskell ecosystem: physical quantities as `Quantity d a` where `d` is a type-level vector of seven integer exponents over the fixed SI basis, with all dimension algebra performed by GHC's closed type families — no compiler extension, no plugin, stock GHC only.

| Field            | Value                                                                                                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | Haskell (GHC only; `DataKinds`, closed `TypeFamilies`, `TypeOperators`, `KindSignatures`)                                                         |
| License          | BSD3                                                                                                                                              |
| Repository       | [bjornbm/dimensional][repo]                                                                                                                       |
| Documentation    | [Hackage haddocks][hackage] · [`README.md`][readme] (the haddock header of [`Numeric.Units.Dimensional`][core] is the de-facto manual)            |
| Key authors      | Björn Buckwalter (author/maintainer, 2006–); Douglas McClean (co-designer of the 1.0 `DataKinds` rewrite, per [Gundry 2015][gundry-paper] fn. 20) |
| Category         | Statically-typed units library (library-only; contrast the [plugin][uom-plugin] and [compiler-native][fsharp] approaches)                         |
| Mechanism        | Phantom `Dimension`-kinded type index + closed type families over type-level integers ([`numtype-dk`][numtype-dk])                                |
| Exponent domain  | `ℤ⁷` — integer exponents over a **fixed** basis of the 7 SI base dimensions; no rationals, no user-added generators                               |
| Checking time    | Compile time (opt-in runtime checking via [`Numeric.Units.Dimensional.Dynamic`][dynamic])                                                         |
| Analyzed version | `f759f32` (2026-01-01; local clone `$REPOS/haskell/dimensional`, pinned in the survey's grounding table)                                          |
| Latest release   | `1.6.2` (January 2026, "Support for GHC 9.14" — [`CHANGELOG.md`][changelog])                                                                      |

> [!NOTE]
> `dimensional` is the **closed-type-family** data point of this survey's Haskell trio:
> it encodes Kennedy-style dimension algebra using only stock GHC features, where
> [`uom-plugin`][uom-plugin] extends GHC's constraint solver with a true abelian-group
> unifier and [F#][fsharp] builds one into the compiler. The second half of this page
> contrasts it with Richard Eisenberg's [`units`][units-repo] package — the _other_
> type-family library, which trades `dimensional`'s fixed SI basis for user-extensible
> dimensions and a "locally coherent system of units" generalization. The mechanism
> theory behind both is in [type-system mechanisms][mechanisms]; the cross-system
> synthesis is in the [comparison][comparison] capstone.

---

## Overview

### What it solves

`dimensional` makes GHC's type checker verify dimensional consistency of numeric
code. The haddock header of the core module states the contract
([`src/Numeric/Units/Dimensional.hs`][core]):

> _"In this module we provide data types for performing arithmetic with physical
> quantities and units. Information about the physical dimensions of the
> quantities/units is embedded in their types and the validity of operations is
> verified by the type checker at compile time. The wrapping and unwrapping of
> numerical values as quantities is done by multiplication and division of units,
> of which an incomplete set is provided."_

That last sentence is the library's signature idiom: there are no dimensioned
literals. A quantity is _formed_ by multiplying a number by a unit with `*~`, and a
number is _recovered_ by dividing a quantity by a unit with `/~` — mirroring the
metrological definition of a quantity as numerical value × unit (the VIM/SI framing
collected in [concepts][concepts]):

```haskell
-- dimensional: src/Numeric/Units/Dimensional.hs
(*~) :: (Num a) => a -> Unit m d a -> Quantity d a
x *~ (Unit _ _ y) = Quantity (x Prelude.* y)

(/~) :: Fractional a => Quantity d a -> Unit m d a -> a
(Quantity x) /~ (Unit _ _ y) = (x Prelude./ y)
```

The package is among the oldest living systems in this survey: the copyright
line runs from 2006 ([`Dimensional.hs`][core]), and version 1.0
(2015-11) rewrote the original functional-dependency encoding onto `DataKinds` and
closed type families ([`CHANGELOG.md`][changelog]: _"Changed to DataKinds and
ClosedTypeFamilies encoding of dimensions"_ — the rewrite Gundry's paper cites as
`dimensional-dk`). The [`dimensional.cabal`][cabal] `tested-with` list spans GHC
8.10.7 through 9.14.1 — two decades of maintenance on one design.

### Design philosophy

Three commitments, each stated in the library's own documentation.

**Newtonian scope, SI discipline.** The haddock header draws the physics boundary
and the standards allegiance in two sentences ([`Dimensional.hs`][core]):

> _"We limit ourselves to \"Newtonian\" physics. We do not attempt to accommodate
> relativistic physics in which e.g. addition of length and time would be valid."_

> _"As far as possible and/or practical the conventions and guidelines of NIST's
> 'Guide for the Use of the International System of Units (SI)' [1] are followed."_

The NIST guide (SP 811, a grounding source of this survey's [concepts][concepts]
page) is cited section-by-section throughout the source — `SIUnits.hs` walks its
tables, and deviations are explained inline.

**Self-documenting client code over clever inference.** The [`README.md`][readme]
positions the encoding choice as an ergonomics decision:

> _"Data kinds and closed type families provide a flexible, safe, and discoverable
> implementation that leads to largely self-documenting client code."_

Client signatures read as physics — `escapeVelocity :: (Floating a) => Mass a ->
Length a -> Velocity a` — because every common dimension has a named `Quantity`
synonym. What the library deliberately does _not_ chase is complete unit
polymorphism: the haddock concedes that _"we could provide the 'Mul' and 'Div'
classes with full functional dependencies"_ but that _"Efforts are underway to
develop a type-checker plugin that does enable these scenarios"_
([`Dimensional.hs`][core] `$dimension-arithmetic`) — the gap [`uom-plugin`][uom-plugin]
was later built to fill.

**Exactness where it is free.** Every `Unit` carries its conversion factor to the SI
coherent unit as an `ExactPi` — an exact rational multiple of a power of π from the
[`exact-pi`][exact-pi] companion package — so degree↔radian and inch↔metre chains
stay exact until a value is demanded at an approximate numeric type.

---

## How it works

### One data family, two variants: `Quantity` and `Unit`

The central type is a data family indexed by a promoted `Variant` kind, giving
units and quantities _different runtime representations_ behind one set of
operators ([`src/Numeric/Units/Dimensional/Internal.hs`][internal]):

```haskell
-- dimensional: src/Numeric/Units/Dimensional/Internal.hs
class KnownVariant (v :: Variant) where
  data Dimensional v :: Dimension -> Type -> Type
  ...

instance KnownVariant ('DQuantity s) where
  newtype Dimensional ('DQuantity s) d a = Quantity a   -- bare newtype: erased
  ...
  dmap = coerce

instance (Typeable m) => KnownVariant ('DUnit m) where
  data Dimensional ('DUnit m) d a = Unit !(UnitName m) !ExactPi !a  -- runtime record
  ...

type Unit (m :: Metricality) = Dimensional ('DUnit m)
type Quantity = SQuantity E.One
type SQuantity s = Dimensional ('DQuantity s)
```

A `Quantity d a` is a newtype around `a` — the dimension is purely phantom. A
`Unit m d a` is a genuine runtime value: a structured `UnitName` (with
[UCUM][concepts] interchange names), the exact `ExactPi` factor to the SI coherent
unit, and that factor pre-approximated at type `a`. The haddock explains why the
two share a type ([`Dimensional.hs`][core] `$types`): _"to allow code reuse as they
are largely subject to the same operations"_ and to permit _"reuse of operators
(and functions) between the two without resorting to occasionally cumbersome type
classes."_

The `Metricality` index (`'Metric` / `'NonMetric`) is a second phantom that gates
SI-prefix application (see [Extensibility](#extensibility)); the `s` in
`SQuantity s` is a type-level `ExactPi'` scale factor used by the fixed-point
module (see [Expressiveness edges](#expressiveness-edges)).

| Concept                 | Type / item                                             | Role                                                                  |
| ----------------------- | ------------------------------------------------------- | --------------------------------------------------------------------- |
| Quantity                | `Quantity d a` (= `SQuantity E.One d a`)                | newtype around `a`; dimension `d` phantom; stored in SI coherent unit |
| Unit                    | `Unit m d a`                                            | name + exact SI factor (`ExactPi`) + approximated factor `a`          |
| Dimension (type level)  | `'Dim l m t i th n j` of kind `Dimension`               | 7-vector of type-level integer exponents                              |
| Exponents               | `TypeInt` (from [`numtype-dk`][numtype-dk])             | `'Neg1`, `'Zero`, `'Pos2`, … with type families `+`, `-`, `*`, `/`    |
| Dimension (term level)  | `Dimension'` (`Dim' Int Int Int Int Int Int Int`)       | for `Dynamic` quantities, parsing, pretty-printing                    |
| Metricality             | `'Metric` / `'NonMetric`                                | compile-time gate on SI-prefix application                            |
| Formation / elimination | `*~`, `/~` (and `*~~`, `/~~` over functors)             | number × unit → quantity; quantity ÷ unit → number                    |
| Unit construction       | `mkUnitZ` / `mkUnitQ` / `mkUnitR`, `siUnit`, `one`      | new named units as integer/rational/real multiples of existing ones   |
| Runtime escape hatch    | `AnyQuantity a`, `DynQuantity a` ([`Dynamic`][dynamic]) | dimension carried as a term-level `Dimension'`, checked at runtime    |

### Arithmetic: types computed by closed type families

Multiplication and division are defined once for both variants; their result
dimension is computed by type families, and their result _variant_ too — the
product of two units is a `'NonMetric` unit, the product of two quantities is a
quantity ([`Dimensional.hs`][core], [`Variants.hs`][variants]):

```haskell
-- dimensional: src/Numeric/Units/Dimensional.hs
(*) :: (KnownVariant v1, KnownVariant v2, KnownVariant (v1 V.* v2), Num a)
    => Dimensional v1 d1 a -> Dimensional v2 d2 a -> Dimensional (v1 V.* v2) (d1 * d2) a

(+) :: Num a => Quantity d a -> Quantity d a -> Quantity d a
(+) = liftQ2 (Prelude.+)

(^) :: (Fractional a, KnownTypeInt i, KnownVariant v, KnownVariant (Weaken v))
    => Dimensional v d1 a -> Proxy i -> Dimensional (Weaken v) (d1 ^ i) a
```

Addition needs no dimension arithmetic at all — both operands must have the _same_
`d`, enforced by ordinary nominal type equality. Powers take the exponent as a
`Proxy` to a type-level integer (`x ^ pos2`), because the exponent changes the
result _type_. The worked example from the haddock header shows the idiom end to
end ([`Dimensional.hs`][core]):

```haskell
-- dimensional: src/Numeric/Units/Dimensional.hs (haddock header example)
escapeVelocity :: (Floating a) => Mass a -> Length a -> Velocity a
escapeVelocity m r = sqrt (two * g * m / r)
  where
      two = 2 *~ one
      g = 6.6720e-11 *~ (newton * meter ^ pos2 / kilo gram ^ pos2)
```

`sqrt` is dimensionally typed too — `sqrt :: Floating a => Quantity d a ->
Quantity (Sqrt d) a` — and `Sqrt (DEnergy * DLength / DMass / DLength)` reduces to
`DVelocity` by type-family evaluation. A `Show` instance renders any quantity in
the SI coherent unit _derived from its dimension_ — the doctest
`sum [12.4 *~ meter, 1 *~ foot]` prints `12.7048 m` — and `showIn (mile / hour)`
renders in a chosen unit ([`Dimensional.hs`][core], [`Internal.hs`][internal]).

---

## Dimension representation

The dimension is a promoted seven-field tuple — one field per SI base dimension, in
the order length, mass, time, current, temperature, amount of substance, luminous
intensity ([`src/Numeric/Units/Dimensional/Dimensions/TypeLevel.hs`][typelevel]):

```haskell
-- dimensional: src/Numeric/Units/Dimensional/Dimensions/TypeLevel.hs
data Dimension = Dim TypeInt TypeInt TypeInt TypeInt TypeInt TypeInt TypeInt

type DOne      = 'Dim 'Zero 'Zero 'Zero 'Zero 'Zero 'Zero 'Zero
type DLength   = 'Dim 'Pos1 'Zero 'Zero 'Zero 'Zero 'Zero 'Zero
type DTime     = 'Dim 'Zero 'Zero 'Pos1 'Zero 'Zero 'Zero 'Zero

type family (a :: Dimension) * (b :: Dimension) where
  DOne * d = d
  d * DOne = d
  ('Dim l  m  t  i  th  n  j) * ('Dim l' m' t' i' th' n' j')
    = 'Dim (l + l') (m + m') (t + t') (i + i') (th + th') (n + n') (j + j')
```

This is the free abelian group `ℤ⁷` on a **fixed seven-generator basis** — the
concrete instance of the [free-abelian-group][fag] representation theory, with
group multiplication as component-wise exponent addition. Three properties follow:

- **Exponents are integers**, supplied by the [`numtype-dk`][numtype-dk] companion
  package as a `TypeInt` kind (`'Neg1`/`'Zero`/`'Pos2`/…) with its own type-level
  `+`, `-`, `*`, `/` families. The restriction is deliberate
  ([`TypeLevel.hs`][typelevel], comment above `^`): _"We limit ourselves to integer
  powers of Dimensionals as fractional powers make little physical sense."_ The
  `NRoot d x` family divides each exponent by `x` via `numtype-dk`'s partial
  type-level division, which is stuck (no matching equation) when the division is
  inexact — so `sqrt` of a non-square dimension is a compile error,
  and `ℚ` exponents are unrepresentable (contrast [mp-units][mp-units]' rational
  exponents and [F#][fsharp]'s `RationalPower`).
- **The representation is a normal form by construction.** Because a dimension _is_
  its exponent vector, `kg·m` and `m·kg` are not two type expressions to be proved
  equal — both reduce to the same `'Dim` tuple. `dimensional` therefore never needs
  the normalization _constraints_ that plague the [`units`][units-repo] package
  (below); equality of ground dimensions is ordinary `~`.
- **The basis is closed.** There is no type-class or type-family hook through which
  a client can add an eighth generator. This is the page's headline finding —
  expanded under [Extensibility](#extensibility).

Every type-level dimension has a term-level twin — `Dimension'` with strict `Int`
fields ([`TermLevel.hs`][termlevel]) — reachable via `KnownDimension`/`dimension`,
which is what the [`Dynamic`][dynamic] module, the `Show` instance, and unit-name
machinery operate on. The single-kind design is itself argued for in the haddock
([`Dimensional.hs`][core] `$dimensions`): providing _"type variables for the seven
base dimensions in 'Dimensional'"_ instead _"would have made any type signatures
involving 'Dimensional' very cumbersome."_

## Checking & inference

There is **no unification-level dimension algebra**: checking is GHC's ordinary
nominal equality plus forward reduction of the closed type families above. That
split determines exactly what works and what doesn't.

**Ground dimensions: complete and silent.** Any concrete dimension expression —
`DEnergy * DLength / DMass / DLength` — reduces to a unique `'Dim` vector, so
mismatches reduce to a mismatch of two literal tuples and additions type-check
without any constraint machinery. Decidability is inherited from closed-type-family
termination (each family is a structurally terminating rewrite).

**Variables: stuck, by design of GHC.** For an opaque `d`, `d * d` cannot reduce —
type families _"may pattern match only on constructors, not other type families"_
and the abelian-group axioms _"are hardly going to"_ form a terminating rewrite
system ([Gundry 2015][gundry-paper] §2.2, the analysis that motivated the plugin).
Dimensional polymorphism is therefore expressible _only up to syntactic spelling_
of the stuck family application:

```haskell
-- Expressible: the signature spells the result as the literal family application.
-- (Derived from the family definitions in Dimensions/TypeLevel.hs @ f759f32;
--  not compiled locally for this survey.)
sqr :: Num a => Quantity d a -> Quantity (d * d) a
sqr x = x * x

-- Rejected: GHC cannot prove  d * d ~ d ^ 'Pos2  for an opaque d.
-- Both sides are stuck family applications; there is no AG unifier to relate them.
sqr' :: Num a => Quantity d a -> Quantity (d ^ 'Pos2) a
sqr' x = x * x
```

The same wall blocks commutativity (`u * v ~ v * u` is unprovable for variables),
"backwards" inference (from `d1 * d2` and `d1`, GHC will not solve for `d2` — the
haddock names type-checker plugins as the way to get this, _"e.g. for linear
algebra"_), and any signature whose author normalized the algebra differently than
the type families do. In [Kennedy's terms][kennedy] the system checks the free
abelian group's _word problem on closed terms_ but has no equational theory for
open ones — the defining limitation of the closed-type-family row in this survey's
[mechanism comparison][mechanisms]. Where the F# compiler [infers][fsharp]
`sqr : float<'u> -> float<'u ^ 2>` from an unannotated body, `dimensional` requires
the annotation and requires it in normal form.

In practice the library leans on **monomorphic-by-synonym** style — signatures like
`Mass a -> Length a -> Velocity a` are ground, so the sharp edge cuts only authors
of generic dimensional combinators (vector spaces, linear algebra over quantities —
exactly the use cases the haddock defers to plugins).

## Extensibility

**New units: cheap, safe, and exact.** A unit is defined as a multiple of an
existing unit with `mkUnitZ` (integer factor), `mkUnitQ` (rational), or `mkUnitR`
(real/`ExactPi`), carrying a structured name with a [UCUM][concepts] interchange
code ([`src/Numeric/Units/Dimensional/NonSI.hs`][nonsi]):

```haskell
-- dimensional: src/Numeric/Units/Dimensional/NonSI.hs
foot :: Fractional a => Unit 'NonMetric DLength a
foot = mkUnitQ (ucum "[ft_i]" "ft" "foot") (1 Prelude./ 3) $ yard

inch :: Fractional a => Unit 'NonMetric DLength a
inch = mkUnitQ (ucum "[in_i]" "in" "inch") (1 Prelude./ 12) $ foot
```

Zero factors are rejected at construction because — in the library's own words —
_"the library relies upon units forming a group under multiplication"_
([`Dimensional.hs`][core], `mkUnitR` haddock; the group structure is the
[free-abelian-group][fag] story again, this time on the _unit_ side).

**Prefixes: a compile-time gate.** SI prefixes are functions, not string glue, and
their type consumes `'Metric` and produces `'NonMetric`
([`SIUnits.hs`][siunits]):

```haskell
-- dimensional: src/Numeric/Units/Dimensional/SIUnits.hs
kilo :: Num a => Unit 'Metric d a -> Unit 'NonMetric d a
```

So `kilo (kilo meter)` and `kilo (meter / second)` are _type errors_ — composite
units are `'NonMetric` by the `Variants.hs` product family — statically enforcing
NIST SP 811's prohibitions on compound (§6.2.4) and stand-alone (§6.2.6, the section
cited in the source) prefixes.

**New base dimensions: impossible.** This is the finding the brief flags. The
`Dimension` kind is a closed seven-field tuple; there is no class, family, or open
kind through which client code can add a generator. A codebase that wants to track
currency, information (bits), or angle as an independent dimension has exactly
three bad options: hijack an unused SI slot, encode it as `Dimensionless`, or fork
the library. Likewise there is no notion of _alternative unit systems_: every
`Unit`'s `exactValue` is defined _"expressed in terms of the SI coherent derived
unit … of the same 'Dimension'"_ ([`Dimensional.hs`][core]), so CGS or natural
units exist only as conversion factors into SI, and every `Quantity` is stored in
the SI coherent basis. Both restrictions are precisely what Eisenberg's
[`units` package](#the-units-package-contrast-user-extensible-dimensions) was
designed to lift — and [mp-units][mp-units], [Boost.Units][boost], and
[`uom` (Rust)][rust-uom] all chose the open-basis road as well.

## Expressiveness edges

- **Fractional powers — absent, deliberately.** `NRoot`/`Sqrt`/`Cbrt` reduce only
  when every exponent divides; `sqrt (x :: Frequency Double)` does not type-check,
  so `V/√Hz`-style noise densities are unrepresentable. The exponent domain is
  `ℤ`, full stop ([`TypeLevel.hs`][typelevel]).
- **Affine quantities (temperature) — conversion functions, not types.** The
  library documents the problem and its 80% answer ([`SIUnits.hs`][siunits]
  `$celsius`): _"A problematic area is units which increase proportionally to the
  base SI units but cross zero at a different point."_ `degreeCelsius` is literally
  `kelvin` (a relative/interval unit), and absolute temperatures go through
  `fromDegreeCelsiusAbsolute` / `toDegreeCelsiusAbsolute`, which hard-code the
  `273.15` offset. There is no affine/point type: adding two absolute temperatures
  — the classic error a [torsor representation][torsor] rules out — type-checks
  fine. (Contrast [Pint][pint]'s delta units and [mp-units][mp-units]'
  `quantity_point`.)
- **Logarithmic units (dB, neper) — absent, documented.** [`NonSI.hs`][nonsi]:
  _"The units of section 5.1.2 are purposefully (but not permanently) omitted. In
  fact the logarithmic units (see section 8.7) are problematic and it is not clear
  how to implement them. Perhaps with a conversion function similar to for degrees
  Celsius."_ Still open at the analyzed pin — matching Gundry's frontier list in
  [type-system mechanisms][mechanisms].
- **Angles — dimensionless, with the known consequences.**
  `type DPlaneAngle = DOne; type PlaneAngle = Dimensionless`
  ([`Quantities.hs`][quantities]) — the orthodox SI reading. `radian`-vs-`degree`
  scaling is handled (units carry factors; `sin`/`cos` take `Dimensionless`), but
  nothing stops adding an angle to a pure ratio, and `Hz` vs `rad/s` is
  untrackable.
- **Kind vs dimension — not modelled.** The library aliases, rather than
  distinguishes, same-dimension quantities: `type DTorque = DMomentOfForce` with
  `DMomentOfForce = DEnergy`, and `type DActivity = DFrequency` (becquerel vs
  hertz) ([`Quantities.hs`][quantities]). Torque added to energy type-checks. The
  synonyms _document_ intent without _enforcing_ it — the gap that
  [mp-units][mp-units]' `quantity_spec` hierarchy and [`uom` (Rust)][rust-uom]'s
  `Kind` tag were invented to close.
- **What it has that most rivals lack:** exact conversion factors (`ExactPi`
  arithmetic keeps `π`-rational chains exact through unit composition); a
  **fixed-point/scaled-quantity layer** — `SQuantity s d a` gives quantities an
  extra type-level `ExactPi'` scale factor, with [`FixedPoint.hs`][fixedpoint]
  providing `Angle8`/`Angle16`/`Angle32` binary-angle synonyms and `rescale`
  machinery for integer representations; and a **dynamic tier**
  ([`Dynamic.hs`][dynamic]) where `AnyQuantity`/`DynQuantity` carry the dimension
  as a term-level `Dimension'` value, support arithmetic that propagates
  invalidity, and `promoteQuantity` re-enters the static world with a runtime
  check — a principled static↔dynamic bridge few statically-typed systems in this
  survey offer.

## Zero-cost story

For **quantities**, erasure is structural and visible in the source rather than
asserted in prose ([`Internal.hs`][internal]):

```haskell
-- dimensional: src/Numeric/Units/Dimensional/Internal.hs
newtype Dimensional ('DQuantity s) d a = Quantity a      -- the representation
liftQ2 :: (a -> a -> a) -> SQuantity s1 d1 a -> SQuantity s2 d2 a -> SQuantity s3 d3 a
liftQ2 = coerce                                          -- +, -, abs, … are coerce

instance Storable a => Storable (SQuantity s d a) where
  sizeOf _ = sizeOf (undefined :: a)                     -- exactly the payload size
  alignment _ = alignment (undefined :: a)
  poke ptr = poke (castPtr ptr :: Ptr a) . coerce

newtype instance U.Vector (SQuantity s d a)    =  V_Quantity {unVQ :: U.Vector a}
newtype instance U.MVector v (SQuantity s d a) = MV_Quantity {unMVQ :: U.MVector v a}
```

A `Quantity DVelocity Double` is a `Double` at runtime: the arithmetic wrappers are
`coerce` (`dmap = coerce`, `liftQ`/`liftQ2 = coerce`), the `Storable` instance is a
pointer cast with `INLINE` pragmas, and an unboxed `Vector` of quantities is
_defined as_ an unboxed `Vector` of the payload — no boxing, no per-element tags.
Quantity formation costs one multiplication (`x *~ u` multiplies by the unit's
pre-approximated factor at construction; thereafter values live in the SI coherent
unit and `+`/`-` are raw machine ops).

**Units are deliberately not free**: `Unit` is a strict three-field record
(name, `ExactPi`, factor). The design collapses all unit-ness into the boundary
operators `*~`/`/~`, after which only erased quantities flow. The repository ships
a criterion harness comparing raw `Double` pipelines against the dimensional
equivalents ([`benchmarks/Main.hs`][benchmark] — `rawArithmetic` vs `arithmetic`
over 1000-element lists), but commits no result numbers; the honest statement is
that the erasure evidence is the `newtype`/`coerce`/`Storable` definitions above,
not a published benchmark. No erasure _theorem_ exists for this encoding either —
Kennedy proved parametricity for his calculus and F# asserts erasure normatively,
but the type-family encodings have no analogous mechanized result (see the open
problems in [type-system mechanisms][mechanisms]).

## Diagnostics

`dimensional`'s own haddock documents the error for adding metres to seconds — the
best case, where GHC's expected/actual types surface the library's synonyms
([`src/Numeric/Units/Dimensional.hs`][core] L98–110 @ `f759f32`; **provenance:
repo documentation** — the library's recorded GHC output, per this survey's rung-2
ladder; not re-captured locally):

```text
let x = 1 *~ meter + 1 *~ second

Couldn't match type 'Numeric.NumType.DK.Integers.Zero
               with 'Numeric.NumType.DK.Integers.Pos1
Expected type: Unit 'Metric DLength a
  Actual type: Unit 'Metric DTime a
In the second argument of `(*~)', namely `second'
In the second argument of `(+)', namely `1 *~ second'
```

Two things are characteristic. First, the mismatch is reported at the _exponent_
level — the leading line says a type-level `'Zero` isn't `'Pos1` (the length
components of the two `'Dim` vectors) before the readable
`Unit 'Metric DLength a` / `Unit 'Metric DTime a` pair appears. Second, because
addition fixed the expected type from the left operand, the error lands on the
`second` _unit_ inside `1 *~ second` — accurate, but one step removed from the `+`
that is morally at fault. The header immediately shows the less friendly case
([`Dimensional.hs`][core] L112–124, same provenance):

```text
let x = 1 *~ meter / (1 *~ second) + 1 *~ kilo gram

Couldn't match type 'Numeric.NumType.DK.Integers.Zero
               with 'Numeric.NumType.DK.Integers.Neg1
Expected type: Quantity DMass a
  Actual type: Dimensional
                 ('DQuantity V.* 'DQuantity) (DLength / DTime) a
In the first argument of `(+)', namely `1 *~ meter / (1 *~ second)'
In the expression: 1 *~ meter / (1 *~ second) + 1 *~ kilo gram
In an equation for `x':
      x = 1 *~ meter / (1 *~ second) + 1 *~ kilo gram
```

When the offending side is a _computed_ dimension, internal machinery leaks: the
`Dimensional ('DQuantity V.* 'DQuantity) (DLength / DTime) a` spelling exposes the
variant-product family instead of reducing to `Quantity DVelocity a`. (The block
predates the scale-factor parameter added to `'DQuantity`, so the exact spelling
has drifted cosmetically since; the shape — internal families in the "actual type"
— is the durable point.) The author's own verdict, in the same header:

> _"It is the author's experience that the usefulness of the compiler error
> messages is more often than not limited to pinpointing the location of errors."_

That is still a materially better story than the [`units`][units-repo] package's
normal-form errors quoted in the contrast below — and materially worse than
[`uom-plugin`][uom-plugin]'s `'m' ~ 's'`-level messages or [F#][fsharp]'s
`The unit of measure 'm' does not match the unit of measure 's'`.

## Ergonomics & compile-time cost

- **Prelude replacement.** Client modules enable `NoImplicitPrelude` and import
  [`Numeric.Units.Dimensional.Prelude`][prelude-mod], which _"re-exports the
  'Prelude', hiding arithmetic functions whose names collide with the
  dimensionally-typed versions"_ — `*`, `/`, `+`, `-`, `sqrt`, `sum`, `pi`, the
  trigonometric family, all shadowed. This is the largest single adoption cost:
  dimensional code lives in a different arithmetic dialect, and mixing plain and
  dimensioned math in one module means qualified `Prelude` imports (`P.*`). The
  haddock also advises `NegativeLiterals` ([`Dimensional.hs`][core]).
- **Declaration overhead is low** for the SI-shaped 99%: quantities are formed with
  `*~` and named synonyms (`Velocity Double`), and scores of dimension/quantity
  synonyms — the NIST-guide tables plus extras — ship in [`Quantities.hs`][quantities]. Exponents need value-level proxies
  (`x ^ pos2`, `nroot pos3`) — mild noise unique to the type-level-integer
  encoding. Convenience constants `_1`…`_9`, `pi`, `tau` cover dimensionless
  literals.
- **Error readability** is bimodal, as the previous section shows: synonym-level
  when the mismatch is between named ground dimensions, internals-level when a
  computed dimension or a polymorphic context is involved.
- **Compile-time cost: no measured data.** Neither the repository nor its docs
  publish compile-time figures (this survey found none in the clone @ `f759f32`).
  Structurally the encoding is frugal — every dimension is a 7-tuple whose family
  reductions are constant-size, with none of the quadratic normalization of factor
  lists ([`units`][units-repo]) or plugin solver passes ([`uom-plugin`][uom-plugin])
  — and the `tested-with` matrix (GHC 8.10.7 → 9.14.1, [`dimensional.cabal`][cabal])
  shows the maintenance burden of tracking nine GHC majors is being paid.

---

## The `units` package contrast: user-extensible dimensions

Richard Eisenberg's [`units`][units-repo] (with Takayuki Muranushi; pinned locally
@ `c06d560`, `units` 2.4.1.5 + `units-defs` 2.2.1) is the other type-family units
library — the one [Gundry 2015][gundry-paper] §5.2 calls _"the state of the art as
far as units of measure in Haskell are concerned"_ before demonstrating why a
plugin beats it. It differs from `dimensional` on exactly the two axes this page
flagged as findings.

**Open dimension basis.** Where `dimensional` hard-codes seven generators, `units`
is _"completely agnostic to the actual system of units used"_
([`README.md`][units-readme-root]): the engine package defines only
`Dimensionless`/`Number`, and even SI is just the bundled `units-defs` library. A
base dimension is any type with a `Dimension` instance, and a quantity's index is a
type-level **association list of factors** rather than a fixed-width vector
([`units/Data/Metrology/Qu.hs`][units-qu], [`Factor.hs`][units-factor]):

```haskell
-- units: units/Data/Metrology/Qu.hs
newtype Qu (a :: [Factor *]) (lcsu :: LCSU *) (n :: *) = Qu n

-- units: units/Data/Metrology/Factor.hs
data Factor star = F star Z          -- a dimension (or unit) with a Z exponent
```

so the group is the free abelian group over an _open_ set of generators — `[F
LengthDim One, F TimeDim MOne]` — with unary type-level integers
([`Z.hs`][units-z]). Declaring a new basis element is three lines (or one
Template-Haskell call, `declareDimension`) ([`units/README.md`][units-readme]):

```haskell
-- units: units/README.md — a user-defined base dimension and two units
data LengthDim = LengthDim
instance Dimension LengthDim

data Meter = Meter
instance Unit Meter where
  type BaseUnit Meter = Canonical      -- Meter is the canonical unit of LengthDim
  type DimOfUnit Meter = LengthDim

data Foot = Foot
instance Unit Foot where
  type BaseUnit Foot = Meter           -- inter-convertible with Meter
  conversionRatio _ = 0.3048
```

The payoff shows immediately in `units-defs`, which does what `dimensional`
_cannot_: it declares `PlaneAngle` and `SolidAngle` as **fundamental dimensions**,
on the record that _"It would be wrong to divide 2 meters by 1 meter and conclude
that the quantity is 2 radians or degrees"_ ([`units-defs/Data/Dimensions/SI.hs`][units-defs-si]),
and ships a CGS module alongside SI.

**The coherent-unit-system generalization.** `dimensional` stores every quantity in
the SI coherent unit; `units` abstracts the storage basis into a type-level map
from dimensions to units — the LCSU, _locally coherent system of units_:

```haskell
-- units: units/README.md
type MyLCSU = MkLCSU '[(LengthDim, Meter), (TimeDim, Second)]
```

Within one LCSU no conversions ever happen; conversions occur only at the `%` /
`#` boundaries or between LCSUs. Gundry's summary of why this matters: it lets
code _"be typechecked for dimension safety, but remain polymorphic in the
particular units, and makes it easier to avoid numeric overflow"_
([Gundry 2015][gundry-paper] §5.2) — e.g. an astrophysics simulation can store
lengths in parsecs without accumulating `3.086e16`-scale factors, something
structurally impossible in `dimensional`.

**Why its inference is weaker than a plugin's.** The price of the open basis is
that the factor-list index is _not_ a canonical form — `[F Length 1, F Time -1]`
and `[F Time -1, F Length 1]` are different types. `units` therefore compares
indices up to a normalization type family: addition constrains its operands with
`d1 @~ d2`, defined as ([`Factor.hs`][units-factor]):

```haskell
-- units: units/Data/Metrology/Factor.hs
type family (a :: [Factor *]) @~ (b :: [Factor *]) :: Constraint where
  a @~ b = (Normalize (a @- b) ~ '[])
```

Gundry's §2.2.1 dissects the consequences. Errors are phrased in normal forms —
adding a mass to a length yields, verbatim (quoted from
[`gundry-2015-typechecker-plugin-uom-haskell.pdf`][gundry-paper] §2.2.1, a local
artifact of this survey):

```text
Couldn't match
    type '[F Mass One, F Length (P Zero)]'
    with '[]'
In the expression: mass |+| distance
```

— the user must decode "the normalized quotient of your two dimensions is not the
empty list" where `dimensional` said `DLength` vs `DTime`. And polymorphism
degrades the same way it does in `dimensional`, but harder, because even _ground_
equalities now route through `Normalize`: the normalisation approach, Gundry
writes, "breaks down when there are variables or other non-canonical unit
expressions present. It cannot conclude that [`u * v`] is interchangeable with
[`v * u`], because it cannot compute the normal form of variables such as `u` and
`v`" (operators rendered in ASCII). A two-argument polymorphic function picks up an
inferred type whose context is a wall of `Normalize`/`Reorder`/`@@+` applications
(reproduced in full in §2.2.1). `units` papers over the worst of it with `redim` —
a compile-time _"dimension-safe cast"_ that re-normalizes an index against a
signature ([`units/README.md`][units-readme]: _"When providing type annotations, it
is good practice to start your function with a `redim $`"_) — a manual crank for
equalities a real abelian-group unifier discharges silently. That unifier is
exactly what [`uom-plugin`][uom-plugin] adds to GHC and what [F#][fsharp] has
natively; the three-way trade (`dimensional`: canonical-but-closed basis; `units`:
open basis, normal-form constraints; plugin: open basis _and_ full AG unification,
at the cost of a compiler extension) is the closed-type-family section of
[type-system mechanisms][mechanisms] in miniature.

> [!NOTE]
> **Which to reach for.** Within Haskell, `dimensional` is the conservative choice:
> stock GHC, SI-only, ground-type ergonomics, two decades of releases. `units` buys
> extensible dimensions and unit-polymorphic storage at the price of gnarlier
> errors and `redim` ceremony. [`uom-plugin`][uom-plugin] buys real inference at the price of a
> GHC-version-coupled plugin. The survey's [comparison][comparison] page plays the
> three against the non-Haskell systems.

---

## Strengths

- **Erased quantities, visibly.** `newtype` + `coerce` + payload-sized `Storable` +
  newtype-deriving unboxed `Vector` instances: the zero-cost claim is inspectable
  in ~30 lines of [`Internal.hs`][internal].
- **Canonical representation ⇒ trivial ground checking.** The `'Dim` 7-vector is
  its own normal form; no normalization constraints, no `redim`, no plugin — plain
  `~` equality, on any stock GHC from 8.10 to 9.14.
- **Exactness discipline.** `ExactPi` conversion factors and the
  `mkUnitZ`/`mkUnitQ`/`mkUnitR` hierarchy keep unit chains exact (`1 *~ inch ::
Length Rational` is `127 % 5000 m`, per the [`NonSI.hs`][nonsi] doctests).
- **Metricality gate.** Double prefixes and prefixed composite units are compile
  errors — a NIST SP 811 rule made structural.
- **Static↔dynamic bridge.** `AnyQuantity`/`DynQuantity` + `promoteQuantity` give a
  checked runtime tier for parsing/serialization, term-mirrored by `Dimension'`.
- **Scaled/fixed-point quantities.** The `SQuantity s d a` scale parameter and
  [`FixedPoint.hs`][fixedpoint] support integer and binary-angle representations —
  rare among the systems in this survey.
- **Longevity.** 2006–2026 under one maintainer, with the 1.0 encoding migration
  (fundeps → `DataKinds`) executed without abandoning the API.

## Weaknesses

- **Closed 7-dimension basis.** No custom base dimensions — currency, information,
  angle-as-dimension are unrepresentable; no alternative unit systems beyond
  conversion factors into SI. The single deepest limitation, and the reason the
  [`units`][units-repo] package exists.
- **No kind discipline.** Torque = energy, becquerel = hertz, angle = 1 — aliases
  document, nothing enforces ([`Quantities.hs`][quantities]).
- **Integer exponents only.** `NRoot` rejects inexact roots at compile time — sound
  but restrictive; no `ℚ` domain for noise densities or fracture mechanics.
- **Polymorphism at the syntactic mercy of type families.** `Quantity (d * d)`
  works; proving `d * d ~ d ^ 'Pos2` doesn't; no backwards inference. Generic
  dimensional libraries need [`uom-plugin`][uom-plugin] or heavy annotation.
- **Affine and logarithmic blind spots.** Celsius via offset _functions_ (absolute
  temperature addition type-checks); dB/neper explicitly unimplemented.
- **Prelude shadowing.** `NoImplicitPrelude` + operator redefinition is a real
  adoption barrier and complicates mixed dimensioned/plain arithmetic.
- **Error messages leak internals** (`Numeric.NumType.DK.Integers.Zero`,
  `'DQuantity V.*` spellings) whenever the mismatch isn't between two named ground
  synonyms — per the author's own assessment, useful mainly for _locating_ errors.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                                        | Trade-off                                                                                                   |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Fixed 7-generator SI basis in one `Dimension` kind                 | Signatures stay compact (per-dimension type variables would be _"very cumbersome"_); representation is canonical | No user-defined base dimensions or unit systems; angle/kind distinctions unrepresentable                    |
| Closed type families for the group algebra                         | Stock GHC, decidable, silent on ground dimensions                                                                | Stuck on variables: no AC reasoning, no backwards inference; polymorphic signatures must spell normal forms |
| Integer exponents (`numtype-dk` `TypeInt`)                         | _"Fractional powers make little physical sense"_; `NRoot` statically checks divisibility                         | No `ℚ` exponents (contrast [mp-units][mp-units], [F#][fsharp] `RationalPower`)                              |
| One `Dimensional` data family for `Quantity` and `Unit`            | Operator reuse across variants; quantities erase while units carry names + exact factors                         | Intimidating operator signatures (`KnownVariant`, `V.*` families) that surface in error messages            |
| Values stored in the SI coherent unit; units act only at `*~`/`/~` | Arithmetic after construction is raw machine ops; one multiplication at the boundary                             | Storage basis is unchangeable — no LCSU-style unit-polymorphic representation (contrast `units`)            |
| `ExactPi` conversion factors + `mkUnitZ/Q/R` hierarchy             | Exact π-rational unit chains; doctest-verifiable exact conversions                                               | `Unit` is a runtime record; extra dependency surface (`exact-pi`, `numtype-dk`)                             |
| Prefixes as `'Metric`→`'NonMetric` functions                       | NIST §6.2.4/§6.2.6 made structural; double/composite prefixing rejected at compile time                          | Occasionally over-strict; unit-name machinery (`UnitNames`, UCUM codes) is a large ancillary subsystem      |
| Prelude-shadowing `Numeric.Units.Dimensional.Prelude`              | Client code reads as ordinary arithmetic on quantities                                                           | `NoImplicitPrelude` everywhere; qualified imports for mixed plain/dimensioned math                          |

## Sources

- [bjornbm/dimensional — GitHub repository][repo] (analyzed at pin `f759f32`, local clone `$REPOS/haskell/dimensional`)
- [`src/Numeric/Units/Dimensional.hs` — haddock manual: usage, `*~`/`/~`, operators, documented error messages, `mkUnit*`][core]
- [`src/Numeric/Units/Dimensional/Dimensions/TypeLevel.hs` — `Dimension` kind, `*`/`/`/`^`/`NRoot` families, integer-exponent rationale][typelevel]
- [`src/Numeric/Units/Dimensional/Internal.hs` — `Dimensional` data family, `Quantity` newtype, `coerce` lifts, `Storable`/`Unbox` instances][internal]
- [`src/Numeric/Units/Dimensional/Variants.hs` — `Variant` kind, `Metricality`, variant product/quotient families][variants]
- [`src/Numeric/Units/Dimensional/Quantities.hs` — dimension/quantity synonyms; `DTorque`/`DEnergy`, `DActivity`/`DFrequency`, `DPlaneAngle = DOne` aliases][quantities]
- [`src/Numeric/Units/Dimensional/SIUnits.hs` — prefixes and `Metricality` gate, Celsius discussion][siunits] · [`NonSI.hs` — `foot`/`inch` definitions, neper/bel omission note][nonsi]
- [`src/Numeric/Units/Dimensional/Dynamic.hs` — `AnyQuantity`/`DynQuantity` runtime tier][dynamic] · [`FixedPoint.hs` — scaled quantities, binary angles][fixedpoint]
- [`README.md` — design statement, worked example][readme] · [`CHANGELOG.md` — 1.0 `DataKinds` rewrite, 1.6.2 release][changelog] · [`dimensional.cabal` — description, `tested-with` matrix][cabal] · [`benchmarks/Main.hs` — criterion harness][benchmark]
- [goldfirere/units — GitHub repository][units-repo] (contrast subject; pin `c06d560`, local clone `$REPOS/haskell/units`): [root `README.md`][units-readme-root] · [`units/README.md` — dimension/unit/LCSU walkthrough, `redim`][units-readme] · [`units/Data/Metrology/Qu.hs`][units-qu] · [`Factor.hs` — `@~` normal-form constraint][units-factor] · [`Z.hs` — unary type-level integers][units-z] · [`units-defs/Data/Dimensions/SI.hs` — `PlaneAngle` as a fundamental dimension][units-defs-si]
- [Adam Gundry, "A Typechecker Plugin for Units of Measure" (Haskell Symposium 2015) — §2.2 type-family impossibility analysis, §2.2.1 `units` error/polymorphism critique, §5.2 `units` appraisal][gundry-paper] (local artifact `gundry-2015-typechecker-plugin-uom-haskell.pdf`)
- [NIST SP 811, "Guide for the Use of the International System of Units (SI)" — the guideline document the library tracks section-by-section][nist] (local artifact `nist-2008-sp811-guide-si.pdf`)
- [`numtype-dk` on Hackage — the type-level integer companion package][numtype-dk] · [`exact-pi` on Hackage — exact π-rational arithmetic][exact-pi]
- Related deep-dives in this survey: [`uom-plugin`][uom-plugin] · [F# units of measure][fsharp] · [type-system mechanisms][mechanisms] · [Kennedy's type system][kennedy] · [free abelian group representation][fag] · [torsors & affine quantities][torsor] · [mp-units][mp-units] · [Boost.Units][boost] · [`uom` (Rust)][rust-uom] · [Pint][pint] · [concepts][concepts] · [the comparison capstone][comparison]

<!-- References -->

<!-- dimensional (pinned clone f759f32) -->

[repo]: https://github.com/bjornbm/dimensional
[hackage]: https://hackage.haskell.org/package/dimensional
[readme]: https://github.com/bjornbm/dimensional/blob/f759f32/README.md
[changelog]: https://github.com/bjornbm/dimensional/blob/f759f32/CHANGELOG.md
[cabal]: https://github.com/bjornbm/dimensional/blob/f759f32/dimensional.cabal
[core]: https://github.com/bjornbm/dimensional/blob/f759f32/src/Numeric/Units/Dimensional.hs
[typelevel]: https://github.com/bjornbm/dimensional/blob/f759f32/src/Numeric/Units/Dimensional/Dimensions/TypeLevel.hs
[termlevel]: https://github.com/bjornbm/dimensional/blob/f759f32/src/Numeric/Units/Dimensional/Dimensions/TermLevel.hs
[internal]: https://github.com/bjornbm/dimensional/blob/f759f32/src/Numeric/Units/Dimensional/Internal.hs
[variants]: https://github.com/bjornbm/dimensional/blob/f759f32/src/Numeric/Units/Dimensional/Variants.hs
[quantities]: https://github.com/bjornbm/dimensional/blob/f759f32/src/Numeric/Units/Dimensional/Quantities.hs
[siunits]: https://github.com/bjornbm/dimensional/blob/f759f32/src/Numeric/Units/Dimensional/SIUnits.hs
[nonsi]: https://github.com/bjornbm/dimensional/blob/f759f32/src/Numeric/Units/Dimensional/NonSI.hs
[dynamic]: https://github.com/bjornbm/dimensional/blob/f759f32/src/Numeric/Units/Dimensional/Dynamic.hs
[fixedpoint]: https://github.com/bjornbm/dimensional/blob/f759f32/src/Numeric/Units/Dimensional/FixedPoint.hs
[prelude-mod]: https://github.com/bjornbm/dimensional/blob/f759f32/src/Numeric/Units/Dimensional/Prelude.hs
[benchmark]: https://github.com/bjornbm/dimensional/blob/f759f32/benchmarks/Main.hs

<!-- units package (pinned clone c06d560) -->

[units-repo]: https://github.com/goldfirere/units
[units-readme-root]: https://github.com/goldfirere/units/blob/c06d560/README.md
[units-readme]: https://github.com/goldfirere/units/blob/c06d560/units/README.md
[units-qu]: https://github.com/goldfirere/units/blob/c06d560/units/Data/Metrology/Qu.hs
[units-factor]: https://github.com/goldfirere/units/blob/c06d560/units/Data/Metrology/Factor.hs
[units-z]: https://github.com/goldfirere/units/blob/c06d560/units/Data/Metrology/Z.hs
[units-defs-si]: https://github.com/goldfirere/units/blob/c06d560/units-defs/Data/Dimensions/SI.hs

<!-- Companion packages & external primary sources -->

[numtype-dk]: https://hackage.haskell.org/package/numtype-dk
[exact-pi]: https://hackage.haskell.org/package/exact-pi
[gundry-paper]: https://dl.acm.org/doi/10.1145/2804302.2804305
[nist]: https://www.nist.gov/pml/special-publication-811

<!-- Same-tree cross-links -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md
[mechanisms]: ./theory/type-system-mechanisms.md
[kennedy]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[torsor]: ./theory/torsor-representation.md
[uom-plugin]: ./haskell-uom-plugin.md
[fsharp]: ./fsharp-uom.md
[mp-units]: ./cpp-mp-units.md
[boost]: ./cpp-boost-units.md
[rust-uom]: ./rust-uom.md
[pint]: ./python-pint.md
