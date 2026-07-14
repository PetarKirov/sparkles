# F# Units of Measure (F# / .NET)

The only mainstream language whose _compiler_ implements [Kennedy's units-of-measure type system][kennedy-types] natively: `[<Measure>]` declarations mint type-level units, the built-in numeric types take measure parameters (`float<m/s>`), the Hindley–Milner constraint solver unifies measures modulo the abelian-group laws, and every trace of a unit is erased before IL generation.

| Field            | Value                                                                                                                                                                       |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | F# (feature of the language itself; compiler implemented in F#)                                                                                                             |
| License          | MIT                                                                                                                                                                         |
| Repository       | [dotnet/fsharp][repo]                                                                                                                                                       |
| Documentation    | [MS Learn: Units of Measure][msdocs] · [F# 4.1 spec §9][spec] · [Kennedy, CEFP 2010][k10]                                                                                   |
| Key authors      | Andrew Kennedy (design + original implementation); Don Syme and the F# team (compiler)                                                                                      |
| Category         | Compiler-native static units (a type-system feature, not a library)                                                                                                         |
| Mechanism        | Measure-kinded type parameters (`TyparKind.Measure`) + abelian-group unification inside the constraint solver; measures fully erased at code generation                     |
| Exponent domain  | `ℚ` — integer at the surface by default; parenthesized rational literals (`kg^(1/2)`) accepted; the solver computes over rationals throughout                               |
| Checking time    | Compile time only — no run-time representation exists to check                                                                                                              |
| Analyzed version | [`dotnet/fsharp`][repo] @ `25c6a37e` (2026-07-03)                                                                                                                           |
| Latest release   | F# 10 (newest shipped entry in the clone's `docs/release-notes/.Language/`, with `11.0.md` in development); units-of-measure unchanged since F# 6.0's `ExpandedMeasurables` |

> [!NOTE]
> F# is the reference point of this survey: every library-level system in the catalog
> ([Boost.Units][boost-units], [`dimensional`][dimensional], [`uom`][rust-uom],
> [mp-units][mp-units], …) is an encoding of what F# gets as a primitive. The theory it
> implements — AG unification, principal types, erasure semantics, the parametricity
> theorem — is covered in [Kennedy's type-theoretic units][kennedy-types] and is **not**
> re-derived here; this page surveys the shipped product. The closest sibling is the GHC
> [`uom-plugin`][uom-plugin], which transplants the same solver into Haskell as a plugin.
> How other type systems approximate the mechanism is [`type-system-mechanisms.md`][mechanisms].

---

## Overview

### What it solves

Dimensional consistency as ordinary type checking, with inference and zero run-time
cost. Kennedy's lecture notes on the F# design open with the framing
([`kennedy-2010-types-units-of-measure-cefp.pdf`][k10], §1, local artifact):

> _"Units-of-measure are to science what types are to programming."_

and motivate it with the 1999 Mars Climate Orbiter loss (a newton/pound-force
confusion). In F#, `let speed = distance / time` on `float<m>` and `float<s>` operands
_infers_ `float<m/s>`; adding metres to seconds is a compile error; and a generic
`let sqr (x: float<_>) = x * x` gets the principal type `float<'u> -> float<'u ^ 2>`
without naming a single unit ([spec §9][spec] intro). No wrapper objects, no quantity class, no
conversion registry: units are type-level decorations on the numeric primitives the
program already uses.

### Design philosophy

**Checking, not conversion.** F# units are exact and algebraic; metrology is the
programmer's problem. There is no table of conversion factors anywhere in the language
([`kennedy-2010-…-cefp.pdf`][k10], §2.3):

> _"As far as F# is concerned, ft and m have nothing to do with each other. It's up to
> the programmer to define appropriate conversion factors. But the presence of units on
> the conversion factors makes mistakes much less likely."_

**Units, not dimensions.** Types are indexed by _units_ (`kg`, `m`); a "dimension"
(mass, length) has no representation in the language at all. The thesis-level design
treats this as a minor choice ([theory page][kennedy-types]); the practical consequence
is that a dimension is whatever equivalence class of units your code happens to respect.

**Erasure first.** The measure parameter is a compile-time fiction, stated as such in
the very doc comments of the core library
([`src/FSharp.Core/prim-types.fsi`][prim-types] L1054–1057, pinned clone):

> _"The type of double-precision floating point numbers, annotated with a unit of
> measure. The unit of measure is erased in compiled code and when values of this type
> are analyzed using reflection. The type is representationally equivalent to
> System.Double."_

The [spec][spec] (§9 intro) is blunter still: _"Measures play no role at runtime; in
fact, they are erased."_

**Inference first.** Because the feature lives inside the compiler's own constraint
solver, measure polymorphism falls out of ordinary let-generalization: library authors
write unit-generic code (`float<'u> -> float<'u ^ 2>`) and clients instantiate it for
free — the property every library-level encoding in this survey struggles to imitate.

---

## How it works

### Declaring and using measures

A `[<Measure>]` attribute on a type definition mints a fresh base unit (no
representation, no members required); with `=` it defines a transparent abbreviation.
The standard library ships the SI system this way — the entire "unit database" of the
language is 50-odd lines of declarations
([`src/FSharp.Core/SI.fs`][si-fs], abridged; namespace
`Microsoft.FSharp.Data.UnitSystems.SI.UnitNames`):

```fsharp
// dotnet/fsharp @ 25c6a37e: src/FSharp.Core/SI.fs (abridged)
[<Measure>] type metre                              // fresh base unit
[<Measure>] type second
[<Measure>] type kilogram
[<Measure>] type hertz  = / second                  // reciprocal syntax
[<Measure>] type newton = kilogram metre / second^2 // juxtaposition = product
[<Measure>] type joule  = newton metre
```

A parallel `UnitSymbols` namespace abbreviates the names (`type m = metre`,
`type N = newton`, …). Numeric literals take a measure in angle brackets — `9.81<m/s^2>`,
`101325.0<N m^-2>`, `0.0f<_>` (anonymous, inferred) — and the numeric primitives have
measure-parameterized versions ([`prim-types.fsi`][prim-types] L1060–1170):

```fsharp
// dotnet/fsharp @ 25c6a37e: src/FSharp.Core/prim-types.fsi (2 of the 13)
[<MeasureAnnotatedAbbreviation>]
type float<[<Measure>] 'Measure> = float

[<MeasureAnnotatedAbbreviation>]
type int<[<Measure>] 'Measure> = int
```

Thirteen primitives carry the annotation in the pinned clone: `float`, `float32`,
`decimal`, `int`, `sbyte`, `int16`, `int64`, `nativeint`, `byte`, `uint16`, `uint`,
`uint64`, `unativeint` (plus `double` as an alias of `float`). Plain `float` is
literally `float<1>` — the dimensionless instantiation ([spec §9.7][spec]).

A minimal end-to-end program — declaration, valid arithmetic, inference — reproduced
locally (toolchain in [Diagnostics](#diagnostics)):

```fsharp
// locally reproduced: valid.fsx
[<Measure>] type m
[<Measure>] type s

let distance = 300.0<m>
let time     = 12.5<s>
let speed    = distance / time          // inferred: float<m/s>   = 24.0
let sqr (x: float<'u>) : float<'u^2> = x * x
let area     = sqr distance             // inferred: float<m^2>   = 90000.0
```

### The `Measure` sort and the two-kind system

Internally every type parameter carries one of two sorts
([`src/Compiler/TypedTree/TypedTree.fs`][tt-fs] L271): `TyparKind.Type` or
`TyparKind.Measure`. The checker uses the sort to reject ill-formed applications in
both directions — `float<int>` ("Expected unit-of-measure, not type", FS0705) and
`IEnumerable<m/s>` ("Expected type, not unit-of-measure", FS0704) — per
[spec §9.5][spec] and [`FSComp.txt`][fscomp] L558–563. Measure expressions themselves
are a small unnormalized AST in the typed tree:

```fsharp
// dotnet/fsharp @ 25c6a37e: src/Compiler/TypedTree/TypedTree.fs L4694 (abridged)
/// Represents a unit of measure in the typed AST
type Measure =
    | Var           of typar: Typar                        // 'u
    | Const         of tyconRef: TyconRef * range: range   // kg, m, s
    | Prod          of measure1: Measure * measure2: Measure * range: range
    | Inv           of measure: Measure
    | One           of range: range                        // float = float<1>
    | RationalPower of measure: Measure * power: Rational
```

The arithmetic operators are given measure-polymorphic types by fiat: the spec's table
of assumed static members (§9.7) types `op_Addition` as `N<'U> -> N<'U> -> N<'U>`,
`op_Multiply` as `N<'U> -> N<'V> -> N<'U 'V>`, `op_Division` as
`N<'U> -> N<'V> -> N<'U/'V>`, `Sqrt` as `F<'U^2> -> F<'U>`, and `Atan2` as
`F<'U> -> F<'U> -> F<1>` — the exact primitive schemes of [Kennedy's calculus][kennedy-types].

### What the spec promises vs what the implementation does

The normative description is still the F# 4.1 spec's chapter 9; the shipped compiler
has drifted past it in three verifiable places:

| Spec (4.1, §9)                                                                            | Implementation @ `25c6a37e`                                                                                                                                                                 |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Powers are `measure-atom ^ int32` — integer exponents only (§9, grammar)                  | Parenthesized **rational** exponents parse and check: `SynRationalConst.Rational` in [`SyntaxTree.fsi`][syntree] L221–235, grammar in [`pars.fsy`][parsfsy] L3488; verified locally (below) |
| Seven measure-annotated base types: `sbyte`…`int64`, `float32`, `float`, `decimal` (§9.7) | **Thirteen** — unsigned and native-size integers added under the F# 6.0 `ExpandedMeasurables` feature ([`LanguageFeatures.fs`][langfeatures] L40, L176; [`prim-types.fsi`][prim-types])     |
| Measure annotations on constants may not include measure variables (§9.2)                 | Still true — but the anonymous `_` is allowed (`0.0f<_>`), and its silent defaulting to `1` is a warning, FS0464 ([`FSComp.txt`][fscomp] L309)                                              |

The rational-exponent divergence, reproduced locally:

```fsharp
// locally reproduced: frac.fsx — spec grammar says int32 exponents only
[<Measure>] type kg
let x = 2.0<kg^(1/2)>          // accepted
let y : float<kg> = x * x      // y = 4.0<kg>
```

---

## Dimension representation

Measures are **compiler-internal term trees at the type level**, not phantom types and
not a value-level registry. The `Measure` AST above is kept _unnormalized_ — `Prod`,
`Inv`, `RationalPower` nodes as written — and quotiented by the abelian-group laws only
when the solver compares or unifies ([spec §9.3][spec] lists the rules verbatim:
commutativity, associativity, identity, inverses, plus abbreviation expansion, and
notes _"these are the laws of Abelian groups together with expansion of abbreviations"_).
Presentation re-normalizes: positive powers before `/`, parameters then identifiers
alphabetically, so `m^1 kg s^-1` prints as `kg m / s` (§9.3). Abbreviations are
expanded for _equality_ but preserved for _display_ — `1<b> / 1<a>` with
`[<Measure>] type b = a * a` prints as `int<b/a>`, not `int<a>` (§9.3).

Three structural choices define the representation:

- **Open set of generators.** Every `[<Measure>] type` declaration anywhere in any
  assembly mints a new `Const` generator; the measure algebra is the
  [free abelian group][fag] over an open, user-extensible set of constants plus
  inference variables. There is no fixed base-dimension vector as in
  [Boost.Units][boost-units] or [`uom`][rust-uom] — and consequently no positional
  exponent tuple anywhere.
- **Rational exponents.** The `Rational` in `RationalPower` is exact
  (numerator/denominator `int32` pairs, [`TypedTreePickle.fs`][pickle] L2176). Kennedy's
  published system is integer-only by design; production F# quietly generalized the
  domain to `ℚ` — surface syntax defaults to integers, but `^(p/q)` is accepted and the
  solver divides exponents freely.
- **Units, not dimensions, not kinds.** One namespace of generators does all the work.
  There is no dimension layer above units and no [kind][concepts] layer above
  dimensions; two units are the same iff their normal forms coincide, and different iff
  they are different generators. Both halves of that coin appear below under
  [Expressiveness edges](#expressiveness-edges).

## Checking & inference

Measure constraints arise when type application meets type application:
`float<m^2/s^2> = float<'U^2>` decomposes to the measure equation `m^2/s^2 = 'U^2`,
which must be solved modulo the AG laws ([spec §9.3.1][spec]). The production solver is
two functions in [`ConstraintSolver.fs`][cs-fs] — the textbook `δ₁ · δ₂⁻¹ = 1`
reduction, then a single most-general-unifier step:

```fsharp
// dotnet/fsharp @ 25c6a37e: src/Compiler/Checking/ConstraintSolver.fs L776
/// Imperatively unify the unit-of-measure expression ms against 1.
/// There are three cases
/// - ms is (equivalent to) 1
/// - ms contains no non-rigid unit variables, and so cannot be unified with 1
/// - ms has the form v^e * ms' for some non-rigid variable v, non-zero exponent e, and measure expression ms'
///   the most general unifier is then simply v := ms' ^ -(1/e)
let UnifyMeasureWithOne (csenv: ConstraintSolverEnv) trace ms = ...

/// Imperatively unify unit-of-measure expression ms1 against ms2
let UnifyMeasures (csenv: ConstraintSolverEnv) trace ms1 ms2 =
    UnifyMeasureWithOne csenv trace (Measure.Prod(ms1, Measure.Inv ms2, ...))
```

Because exponents are rational, the divisibility case analysis of Kennedy's
Euclid-style `DimUnify` collapses: `e` always divides, so elimination is **one step per
variable** (`DivRational`/`NegRational` in the body, L790–795) — Gauss–Jordan over `ℚ`
rather than Hermite reduction over `ℤ`, with integrality maintained at the displayed
surface. Variables are partitioned into rigid (from signatures/annotations) and
non-rigid before a substitution target is chosen, and the theory being unitary, the
result is a principal type — the algorithm-level story is on the
[theory page][kennedy-types].

Displayed type schemes are canonicalized by `SimplifyMeasure` (L807) /
`SimplifyMeasuresInType` (L839) / `NormalizeExponentsInTypeScheme` (L905), whose
header comment shows the solver's internal rational world leaking and being repaired:

```fsharp
// dotnet/fsharp @ 25c6a37e: src/Compiler/Checking/ConstraintSolver.fs L901
// Normalize the exponents on generalizable variables in a type
// by dividing them by their "rational gcd". For example, the type
// float<'u^(2/3)> -> float<'u^(4/3)> would be normalized to produce
// float<'u> -> float<'u^2> by dividing the exponents by 2/3.
```

**Dimensional polymorphism is fully expressible — and inferred.** The generic square
is the spec's own example (§9 intro): from `let sqr (x:float<_>) = x*x` the compiler
infers `val sqr : float<'u> -> float<'u ^ 2>`, and
`let sumOfSquares x y = sqr x + sqr y` gets
`float<'u> -> float<'u> -> float<'u ^ 2>`. User-defined types parameterize the same
way (`type Vector<[<Measure>] 'U> = { X: float<'U>; ... }`, spec §9.5). The
edges: measure-polymorphic _recursion_ requires full annotations, λ-bound arguments
are monomorphic as in any ML, and an anonymous `_` that the solver pins to `1` warns
FS0464 rather than generalizing ([`FSComp.txt`][fscomp] L309) — the "less generic than
indicated" trap.

## Extensibility

- **Custom base unit = one line.** `[<Measure>] type tick` anywhere creates a new
  generator, fully equal in status to `metre`. There is no registration step and no
  central authority; scoping is ordinary .NET namespacing, so two `[<Measure>] type ft`
  in different namespaces are distinct, incompatible units.
- **Derived units are transparent abbreviations.** `[<Measure>] type N = kg m / s^2`
  behaves exactly like its expansion in checking. Abbreviation cycles are rejected
  (spec §9.4 shows `[<Measure>] type X = X^2` as invalid), and measure definitions may
  not themselves take type or measure parameters (FS0928, [`FSComp.txt`][fscomp] L779).
- **Conversions are values, not types.** The idiom is a constant carrying a mixed
  unit — `let ftPerMetre = 3.28084<ft/m>` — or a static member on the measure type
  itself; measure declarations may carry _only_ static members
  ([`FSComp.txt`][fscomp] L751, FS0897). Nothing checks the factor's numeric value.
- **No prefixes, no unit systems.** There is no `kilo`/`milli` mechanism; a prefixed
  unit is just another declaration plus a manual factor. The stdlib SI module contains
  _only_ the coherent SI units — no `gram` (the base is `kilogram`), no `km`, no
  minute/hour ([`SI.fs`][si-fs]). Interop between "systems" (imperial vs SI) is
  entirely convention: declare both sets of generators and write conversion constants.
- **Extending to new numeric carriers is walled off.** Measures attach only to the 13
  blessed primitives and to F#-defined types with measure parameters. Annotating a
  foreign numeric type is rejected — see the next section — and the
  `MeasureAnnotatedAbbreviation` escape hatch is explicitly reserved: the spec's note
  (§9.7) says it _"is not for use in user code and in future revisions of the language
  may result in a warning or error."_

## Expressiveness edges

- **Fractional powers: yes** (beyond the published design). `kg^(1/2)` parses, checks,
  and cancels correctly (reproduced above); the solver is rational throughout.
  Irrational exponents remain inexpressible.
- **Affine quantities: no.** `kelvin` is in the stdlib; Celsius/Fahrenheit as _units_
  are not expressible — a measure rescales multiplicatively by construction, and a
  `float<degC>` declared by the user behaves as a fresh linear unit whose zero is
  meaningless. The offset lives in hand-written conversion functions the type system
  cannot see. (The [torsor formalization][torsor] is this survey's treatment of the
  missing structure.)
- **Logarithmic quantities: no.** dB/pH have no support; `log`/`exp` are typed
  `float<1> -> float<1>`, so dimensioned arguments must be manually divided by a
  reference quantity first.
- **Angles: dimensionless, with an opt-in workaround.** The stdlib SI module defines
  **no** `radian` or `steradian` — visible in [`SI.fs`][si-fs], where
  `lumen = candela` (the steradian in `cd·sr` simply vanishes). `sin`/`cos` accept any
  bare `float`. Users can mint `[<Measure>] type rad` and wrap the trig functions, but
  the moment one module doesn't, radians/degrees confusion type-checks.
- **Kind vs dimension: collapses, demonstrably — in the stdlib itself.** `hertz` and
  `becquerel` are both abbreviations with normal form `second^-1`; `gray` and
  `sievert` are both `joule/kilogram` ([`SI.fs`][si-fs] L42, L102, L106, L110). Since
  abbreviations are transparent, the type system identifies them:

  ```fsharp
  // locally reproduced: kind.fsx — same-dimension, different-kind units unify
  open Microsoft.FSharp.Data.UnitSystems.SI.UnitSymbols
  let f = 5.0<Hz> + 3.0<Bq>   // frequency + radioactivity: type-checks, f = 8.0
  let d = 2.0<Gy> + 1.0<Sv>   // absorbed dose + dose equivalent: type-checks, d = 3.0
  ```

  Likewise torque (`N m`) and energy (`J`) are indistinguishable. The only recourse —
  minting distinct base units — then falsely forbids the legitimate identifications.
  This is the gap the quantity-kind hierarchy of [mp-units][mp-units] exists to fill.

- **Carrier types: the 13 primitives or F# wrappers only.** Measures on `bigint` are
  rejected with FS0636 — _"Units-of-measure are only supported on float, float32,
  decimal, and integer types"_ ([`FSComp.txt`][fscomp] L492; compile-fail fixture
  [`E_UnsupportedType01.fsx`][e-unsupported] applies `1I<Kg>`). A user-defined numeric
  type, a C# `struct`, `System.TimeSpan`, or a matrix type can carry units only by
  wrapping in an F# type with a measure parameter — there is no way to bless an
  existing type.
- **No automatic conversion — by design.** `1.0<ft> + 1.0<m>` is a type error, not a
  conversion site; F# checks and never converts (contrast [Pint][pint] and
  [Unitful][julia-unitful], which normalize at run time).

## Zero-cost story

The story is total erasure, and it is documented, implemented, and observable:

- **Spec-level guarantee.** §9.6: _"In contrast to type parameters on generic types,
  measure parameters are not exposed in the metadata that the runtime interprets;
  instead, measures are erased"_ — with the three consequences enumerated: casting,
  method application resolution, and reflection all operate on erased types
  ([spec][spec] §9.6).
- **Compiler mechanism.** Erasure is a first-class mode of type equivalence:

  ```fsharp
  // dotnet/fsharp @ 25c6a37e: src/Compiler/TypedTree/TypedTreeOps.Remap.fs L976
  /// This erases outermost occurrences of inference equations, type abbreviations,
  /// non-generated provided types and measurable types (float<_>).
  let rec stripTyEqnsAndErase eraseFuncAndTuple (g: TcGlobals) ty = ...

  type Erasure = EraseAll | EraseMeasures | EraseNone      // L1005
  ```

  Code generation and duplicate-signature checking compare types modulo measure
  erasure (`typeEquivAux EraseMeasures` in `IlxGen.fs`; `EraseAll` in the FS0438
  duplicate-method check), so `float<m>` and `float` are the same IL type `float64` —
  no wrapper struct exists to optimize away.

- **Observable at run time** (reproduced locally; toolchain below):

  ```fsharp
  // locally reproduced: erasure.fsx
  open Microsoft.FSharp.Data.UnitSystems.SI.UnitSymbols
  typeof<float<m>> = typeof<float>    // true
  let o = box 42.0<m>
  let r = o :?> float                 // succeeds: casting is at the erased type
  let w = o :?> float<s>              // ALSO succeeds — warning FS1240, no runtime check
  ```

- **The bill for zero cost.** Erasure's holes are the same mechanism seen from the
  other side. A type test or downcast silently ignores measures (warning FS1240,
  [`FSComp.txt`][fscomp] L1119, reproduced above). Overloads that differ only in
  measure collide (reproduced locally):

  ```text
  overload.fsx(5,14): error FS0438: Duplicate method. The method 'Speed' has the same
  name and signature as another method in type 'Api' once tuples, functions, units of
  measure and/or provided types are erased.
  ```

  Reflection, serialization, and every non-F# consumer see plain `System.Double` — a
  C# caller can pass any `double` into a `float<m>` parameter without complaint.

- **F#-to-F# is the exception.** Measures survive across _F#_ assembly boundaries
  because they are pickled into the F#-specific metadata blob, not the IL metadata:
  [`TypedTreePickle.fs`][pickle] L2180–2220 serializes measure constructors,
  variables, and rational powers (`p_measure_con`, `p_measure_var`,
  `p_measure_power`). Unit checking is cross-assembly for F# consumers and
  nonexistent for everyone else.

## Diagnostics

The mismatch program:

```fsharp
// mismatch.fsx
[<Measure>] type m
[<Measure>] type s
let d = 3.0<m> + 4.0<s>
```

produces exactly:

```text
/home/petar/.claude/jobs/83fdacd5/tmp/repro-fsharp-uom/mismatch.fsx(3,18): error FS0001: The unit of measure 's' does not match the unit of measure 'm'
```

\[reproduced locally, `dotnet fsi` from nixpkgs `dotnet-sdk` 8.0.420 — F# Interactive
12.8.403.0 for F# 8.0, 2026-07-03\]. The valid counterpart (`valid.fsx` above) printed
`speed = 24 m/s` / `area = 90000 m^2` under the same toolchain.

The compiler's own test suite pins the same shape of message. The conformance fixture
[`E_MassForce.fsx`][e-massforce] (pinned clone @ `25c6a37e`) expects, for `me + apple`
with `me : float<kg>` and `apple : float<N>`:

```text
//<Expects id="FS0001" span="(15,27-15,32)" status="error">The unit of measure 'N' does not match the unit of measure 'kg'</Expects>
//<Expects id="FS0043" span="(15,25-15,26)" status="error">The unit of measure 'N' does not match the unit of measure 'kg'</Expects>
```

and the typecheck baseline [`neg21.bsl`][neg21] shows the normalized-form rendering of
compound units in real errors — `The unit of measure 's ^ 3' does not match the unit
of measure 's ^ 4'`, `The unit of measure 'sqrm' does not match the unit of measure
'm ^ 3'`. When the mismatch surfaces through a general type mismatch, the unit line is
appended to the standard expected/given form
([`E_RangeOfDimensioned03.fsx`][e-range] expectation):

```text
Type mismatch. Expecting a
    'float<Kg>'
but given a
    'float<s>'
The unit of measure 'Kg' does not match the unit of measure 's'
```

Two properties are worth naming. The message is expressed **at the unit level** — it
names the two offending measures in the spec's normalized display form (`m/s ^ 2`,
`kg m / s`), never a mangled encoding — and it is **short**: one line, since there is
no instantiation stack or trait-resolution trace to dump. This is the diagnostic
quality bar the template- and trait-based systems in this survey are measured against.

## Ergonomics & compile-time cost

- **Declaration overhead is the lowest in the survey.** One attribute per base unit;
  one line per derived unit; literals annotated in angle brackets; everything else
  inferred. There is no quantity wrapper to construct and no `.value()` to unwrap —
  dimensionless code and dimensioned code are the same code.
- **Reading inferred signatures is mostly painless.** Scheme normalization
  (`SimplifyMeasuresInType`, `NormalizeExponentsInTypeScheme`) keeps displayed types
  in a canonical integer-exponent form. The residual wart is inherent to the theory:
  equivalent schemes have no unique "natural" syntax, so an inferred
  `float<'u 'v> -> float<'v>` may not be the form the author had in mind
  ([theory page][kennedy-types], "principal syntax").
- **Compile-time cost is absorbed into ordinary inference.** Measure unification is
  one rational-elimination step per variable inside the same constraint solver that
  runs anyway ([`ConstraintSolver.fs`][cs-fs]); there is no combinatorial
  normalization, no template instantiation, and no per-unit code generation. No
  published benchmark isolates units-of-measure checking cost — consistent with it
  never having been a reported pain point in fifteen-plus years of production use; the
  units chapter has needed essentially no compiler work since F# 6.0 (the only
  units-related entry in the F# 10 release notes is an anonymous-records parsing fix,
  [`docs/release-notes/.Language/10.0.md`][relnotes10]).
- **Footguns.** The `_`-to-`1` defaulting warning FS0464 ("This code is less generic
  than indicated by its annotations", [`FSComp.txt`][fscomp] L309); nonzero literals
  are never unit-polymorphic (only `0`, `infinity`, `nan` are); range expressions
  demand a dimensioned step (`[1<s> .. 1<s> .. 5<s>]`, spec §9.8); and erasure's
  boundary holes (FS1240 downcasts, C# callers) require discipline precisely where
  the type system stops.

---

## Strengths

- **Native inference with principal types** — unit-generic code costs zero
  annotations; the solver is unitary, so there is one best answer
  ([`ConstraintSolver.fs`][cs-fs]; [theory][kennedy-types]).
- **Genuinely zero cost** — `float<m>` _is_ `float64` in IL; there is not even an
  abstraction to rely on the optimizer to remove ([spec §9.6][spec];
  [`TypedTreeOps.Remap.fs`][tto-remap]).
- **Best-in-class diagnostics** — one-line, unit-level, normalized-form errors
  (reproduced above).
- **Trivial extensibility** — a new base unit or derived abbreviation is one
  declaration; the SI stdlib is itself just declarations ([`SI.fs`][si-fs]).
- **Rational exponents** — the shipped solver quietly exceeds the published design
  (and most of the systems in this survey) by working over `ℚ`.
- **Measure-parameterized user types** — records, unions, and classes generalize over
  units (`Vector<[<Measure>] 'U>`), not just scalars.

## Weaknesses

- **Erasure holes at every boundary** — reflection, serialization, boxing/downcasts
  (FS1240), overloading (FS0438), and all non-F# .NET code see naked numbers; units
  are only as strong as the F#-only perimeter.
- **Closed carrier set** — units attach to 13 blessed primitives only; no measures
  over `bigint`, C# types, or user numerics without hand-rolled wrapper types
  (FS0636); `MeasureAnnotatedAbbreviation` is reserved to the core library.
- **No kinds, no affine, no logarithmic, no angles** — `Hz` = `Bq` and `Gy` = `Sv` in
  the shipped stdlib; torque = energy; °C, dB unrepresentable; radians erased to `1`.
  Every gap of Kennedy's design ships unfilled.
- **No conversion or prefix machinery** — every factor is a hand-written constant
  whose numeric value nothing checks; no `km` without declaring it.
- **Units are F#-shaped** — the design is frozen into one language's compiler; the
  ecosystem cannot iterate on it the way a library can (contrast the C++ line from
  [Boost.Units][boost-units] to [mp-units][mp-units]).
- **Spec drift** — the normative spec (4.1) predates rational exponents and the
  expanded carrier set; the precise current behaviour is discoverable only from the
  implementation and its tests.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                             | Trade-off                                                                                                       |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Build units into the compiler's constraint solver          | Principal types + full inference; no encoding artifacts in errors                     | Feature evolves at compiler speed; unavailable to other .NET languages; spec drift                              |
| Total erasure before IL                                    | True zero cost; no runtime dependency; `float<m>` interops as `double`                | No runtime checking possible; reflection/serialization/C# boundaries are unit-blind; no overloading on measures |
| Index types by **units**, no dimension or kind layer       | One simple algebra; minimal syntax; matches Kennedy's calculus                        | `Hz`/`Bq`, `Gy`/`Sv`, torque/energy collapse; stdlib itself exhibits the collapse                               |
| Checking, not conversion (`ft` and `m` unrelated)          | Exact algebraic checking; no hidden numeric error; factors visible in code            | All conversion factors hand-written and unverified; no prefix system                                            |
| Rational exponent domain internally (`ℚ`)                  | One-step most general unifiers; `sqrt` on odd powers; simpler solver than `ℤ`-Hermite | Deviates from spec grammar and published theory; integrality re-imposed only at display time                    |
| Fixed set of measure-annotated primitives                  | Erasure needs representational identity with an existing runtime type                 | Closed world: wrappers required for any other carrier; `MeasureAnnotatedAbbreviation` reserved                  |
| Stdlib ships names only (`SI.fs` declarations, no factors) | Zero-cost, dependency-free SI vocabulary                                              | No prefixed units, no `gram`, no non-SI units; every project re-declares its own conversion constants           |

## Sources

- [`dotnet/fsharp`][repo] pinned @ `25c6a37e` —
  [`src/Compiler/Checking/ConstraintSolver.fs`][cs-fs] (`UnifyMeasureWithOne` L782,
  `UnifyMeasures` L801, `SimplifyMeasure` L807, `SimplifyMeasuresInType` L839,
  `NormalizeExponentsInTypeScheme` L905), [`src/Compiler/TypedTree/TypedTree.fs`][tt-fs]
  (`TyparKind` L271, `type Measure` L4696),
  [`src/Compiler/TypedTree/TypedTreeOps.Remap.fs`][tto-remap] (`stripTyEqnsAndErase`
  L980, `Erasure` L1005), [`src/Compiler/TypedTree/TypedTreePickle.fs`][pickle]
  (measure pickling L2176–2220), [`src/FSharp.Core/SI.fs`][si-fs],
  [`src/FSharp.Core/prim-types.fsi`][prim-types] (measure-annotated primitives
  L1060–1178), [`src/Compiler/FSComp.txt`][fscomp] (diagnostic texts),
  [`src/Compiler/SyntaxTree/SyntaxTree.fsi`][syntree] + [`src/Compiler/pars.fsy`][parsfsy]
  (rational-exponent syntax), [`src/Compiler/Facilities/LanguageFeatures.fs`][langfeatures]
  (`ExpandedMeasurables` → 6.0).
- Compiler test evidence @ `25c6a37e`: [`E_MassForce.fsx`][e-massforce],
  [`E_UnsupportedType01.fsx`][e-unsupported], [`E_RangeOfDimensioned03.fsx`][e-range],
  [`neg21.bsl`][neg21].
- [The F# 4.1 Language Specification][spec], §9 "Units Of Measure" (pp. 175–181) —
  grammar, AG equivalence rules, normalized display, constraint solving, erasure
  consequences, core-library table, restrictions. (Local artifact
  `fsharp-spec-4.1.pdf`.)
- A. Kennedy, ["Types for Units-of-Measure: Theory and Practice"][k10], CEFP 2009
  lecture notes, LNCS 6299, 2010 — the design rationale and programmer's tour. (Local
  artifact `kennedy-2010-types-units-of-measure-cefp.pdf`; the theory is surveyed in
  [Kennedy's type-theoretic units][kennedy-types].)
- [Microsoft Learn: Units of Measure (F# language reference)][msdocs].
- Local reproductions (`valid.fsx`, `mismatch.fsx`, `frac.fsx`, `kind.fsx`,
  `erasure.fsx`, `overload.fsx`) — `dotnet fsi`, nixpkgs `dotnet-sdk` 8.0.420,
  F# Interactive 12.8.403.0 for F# 8.0, 2026-07-03.
- Related deep-dives in this survey: [Kennedy's type system][kennedy-types] ·
  [free abelian group][fag] · [type-system mechanisms][mechanisms] ·
  [torsors (affine gap)][torsor] · [`uom-plugin`][uom-plugin] ·
  [`dimensional`][dimensional] · [`uom` (Rust)][rust-uom] · [mp-units][mp-units] ·
  [Boost.Units][boost-units] · [Au][au] · [Pint][pint] · [Unitful.jl][julia-unitful] ·
  [concepts][concepts] · [the comparison capstone][comparison].

<!-- References -->

<!-- Same-tree theory pages -->

[kennedy-types]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[uom-plugin]: ./haskell-uom-plugin.md
[dimensional]: ./haskell-dimensional.md
[rust-uom]: ./rust-uom.md
[mp-units]: ./cpp-mp-units.md
[boost-units]: ./cpp-boost-units.md
[au]: ./cpp-au.md
[pint]: ./python-pint.md
[julia-unitful]: ./julia-unitful.md

<!-- Pinned clone (dotnet/fsharp @ 25c6a37e) -->

[repo]: https://github.com/dotnet/fsharp
[cs-fs]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/src/Compiler/Checking/ConstraintSolver.fs
[tt-fs]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/src/Compiler/TypedTree/TypedTree.fs
[tto-remap]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/src/Compiler/TypedTree/TypedTreeOps.Remap.fs
[pickle]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/src/Compiler/TypedTree/TypedTreePickle.fs
[si-fs]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/src/FSharp.Core/SI.fs
[prim-types]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/src/FSharp.Core/prim-types.fsi
[fscomp]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/src/Compiler/FSComp.txt
[syntree]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/src/Compiler/SyntaxTree/SyntaxTree.fsi
[parsfsy]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/src/Compiler/pars.fsy
[langfeatures]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/src/Compiler/Facilities/LanguageFeatures.fs
[relnotes10]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/docs/release-notes/.Language/10.0.md
[e-massforce]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/tests/FSharp.Compiler.ComponentTests/Conformance/UnitsOfMeasure/Basic/E_MassForce.fsx
[e-unsupported]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/tests/FSharp.Compiler.ComponentTests/Conformance/UnitsOfMeasure/Diagnostics/E_UnsupportedType01.fsx
[e-range]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/tests/FSharp.Compiler.ComponentTests/Conformance/UnitsOfMeasure/Diagnostics/E_RangeOfDimensioned03.fsx
[neg21]: https://github.com/dotnet/fsharp/blob/25c6a37e68d01387a5d5322e70efecb4551cb058/tests/fsharp/typecheck/sigs/neg21.bsl

<!-- Specs, papers & official docs -->

[spec]: https://fsharp.org/specs/language-spec/4.1/FSharpSpec-4.1-latest.pdf
[k10]: https://doi.org/10.1007/978-3-642-17685-2_8
[msdocs]: https://learn.microsoft.com/en-us/dotnet/fsharp/language-reference/units-of-measure
