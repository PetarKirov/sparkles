# LeanDimensionalAnalysis (Lean 4)

The proof-assistant data point of this survey, with an honest headline in two halves: **mathlib4 — the de-facto standard library of formalized mathematics — contains no units-of-measure or dimensional-analysis development at all** (its `Units` is invertible monoid elements, nothing physical), and the positive subject is therefore a small external research framework, [ATOMSLab/LeanDimensionalAnalysis][lda-repo], which defines dimensions as exponent-valued functions on an open set of base dimensions, **proves** they form an abelian group, grades quantities by their dimension, and formalizes the ingredients of the Buckingham-π theorem — theorems _about_ the framework, not merely programs checked by it.

| Field            | Value                                                                                                                                                                                                                                                                      |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | Lean 4 (toolchain `leanprover/lean4:v4.23.0-rc2` per the repo's `lean-toolchain`; mathlib pinned to a master rev in `lake-manifest.json`)                                                                                                                                  |
| License          | Apache-2.0 (both `LeanDimensionalAnalysis` and mathlib4)                                                                                                                                                                                                                   |
| Repository       | [ATOMSLab/LeanDimensionalAnalysis][lda-repo] (positive subject) · [leanprover-community/mathlib4][mathlib] (negative finding)                                                                                                                                              |
| Documentation    | [Bobbin, Jones, Velkey & Josephson 2025 (arXiv:2509.13142)][bobbin-arxiv] — the companion paper; the repo `README.md` is one line ("Formally-verified dimensional analysis in Lean")                                                                                       |
| Key authors      | Maxwell P. Bobbin, Colin Jones, John Velkey, Tyler R. Josephson (ATOMS Lab, UMBC)                                                                                                                                                                                          |
| Category         | Proof-assistant formalization — a verified _theory_ of dimensional analysis, not a production units library                                                                                                                                                                |
| Mechanism        | Dependent types: `dimension B E := B → E` (term-level exponent maps) used as **type indices**; a proved `CommGroup` instance; quantities as a graded structure `PhysicalVariable (d : dimension B V)`; homogeneity by definitional equality or an explicit `cast` + tactic |
| Exponent domain  | Open — any `CommRing E` (`ℤ` minimum, `ℚ` for roots, even `ℝ` type-checks); the `Basic_Multiplicative` variant's type definition asks only `AddCommGroup E`                                                                                                                |
| Checking time    | Elaboration time (type checking + proof checking); no dimension data in values; large parts deliberately `noncomputable`                                                                                                                                                   |
| Analyzed version | [`LeanDimensionalAnalysis`][lda-repo] @ `de263ee` (2025-09-11, `$REPOS/lean/LeanDimensionalAnalysis`) · [`mathlib4`][mathlib] @ `ab4e75d` (2026-07-03, `$REPOS/lean/mathlib4`)                                                                                             |
| Latest release   | None — untagged, single-commit public history (`version = "0.1.0"` in `lakefile.toml`); the paper's v1 hit arXiv 2025-09-16                                                                                                                                                |

> [!NOTE]
> This page is the survey's answer to "what do **dependent types and a proof
> kernel** buy for units?" Every other system in the catalog — from
> [F#'s compiler-native inference][fsharp-uom] to [GNAT's aspect vectors][gnat] to
> [mp-units' template algebra][mp-units] — _implements_ the
> [free-abelian-group model][fag] and asks you to trust the implementation.
> Lean is the one place in the catalog where the model itself is **stated and
> proved**: `CommGroup (dimension B E)` is a theorem
> ([`Basic.lean` L234][lda-basic] @ `de263ee`), and Buckingham's π-count is a
> definition over `Matrix.rank`. The trade is equally stark: no inference, no
> diagnostics engineering, no ecosystem — and the flagship mathematical library
> underneath it has no units development to build on. Mechanism placement:
> the "dependent types" row of [`type-system-mechanisms.md`][mechanisms].

---

## Overview

### What it solves

Every checking system in this survey enforces dimensional homogeneity; none of
them can state it as a mathematical object and prove things about it. That gap
is the paper's explicit motivation ([Bobbin et al. 2025][bobbin-arxiv] §1, local
copy `bobbin-2025-formalizing-dimensional-analysis-lean-arxiv.pdf`):

> "However, the code created to implement physical variables and tools, like the
> Buckingham Pi theorem, has yet to be implemented in a way that formally
> encompasses the properties of dimensional analysis and the fact that it forms
> an Abelian group."

The framework's contents, per the abstract:

> "We define physical dimensions as mappings from base dimensions to exponents,
> prove that they form an Abelian group under multiplication, and implement
> derived dimensions and dimensional homogeneity theorems. Building on this
> foundation, we introduce a definition of physical variables that combines
> numeric values with dimensions, extend the framework to incorporate SI base
> units and fundamental constants, and implement the Buckingham Pi Theorem."

The pay-off claimed over library encodings is kernel-checked trust
([Bobbin et al. 2025][bobbin-arxiv] §1): "Unlike unit systems in other programs,
this implementation is built upon the Lean 4 kernel, ensuring that any theorem
written is logically correct, so long as it can be parsed by Lean 4."

### The mathlib4 baseline — a negative finding

mathlib4 @ `ab4e75d` (2026-07-03) was searched for this survey: no file or
directory relates to physical dimensions (`LinearAlgebra/Dimension` is module
rank, `KrullDimension` is ring theory, `SmallInductiveDimension` is topology),
and repository-wide greps for "dimensional analysis", "units of measure",
"Buckingham", and "physical quantit-" return **zero hits**. What mathlib calls
`Units` is abstract algebra ([`Mathlib/Algebra/Group/Units/Defs.lean`][mathlib-units]
L13–17 @ `ab4e75d`):

> "An element of a `Monoid` is a unit if it has a two-sided inverse. …
> `Units M`: the group of units (i.e., invertible elements) of a monoid."

The closest building block to a dimension group is
[`Mathlib/GroupTheory/FreeAbelianGroup.lean`][mathlib-fag] — the free abelian
group `FreeAbelianGroup α`, which its header describes in exactly the shape a
dimension lattice needs (L20–22 @ `ab4e75d`):

> "Alternatively, one could define it as the functions `α → ℤ` which send all
> but finitely many `(a : α)` to `0`, under pointwise addition."

Notably, `LeanDimensionalAnalysis` does **not** use it (see
[Dimension representation](#dimension-representation)): it takes the full
function space `B → E` instead, and re-proves the group structure by hand. The
negative finding cuts both ways — nothing in mathlib blocks a units
development, and nothing in mathlib provides one.

### Design philosophy

**Dimension algebra as ordinary group theory.** The framework's central move is
to make "dimensions form an abelian group" a _proved instance_ rather than a
design metaphor: `instance : CommGroup (dimension B E)` at
[`Basic.lean` L234][lda-basic] discharges every group law (`mul_assoc`,
`inv_mul_cancel`, `zpow_succ'`, …) by `funext` plus ring reasoning on
exponents. From that point on, all of mathlib's group machinery — `simp`
lemmas, `Matrix.rank`, kernels of linear maps — applies to dimensions for free.
The [free-abelian-group theory page][fag] treats this as the mechanized
endpoint of the Kennedy/Jonsson lineage.

**Open everything.** Both the base-dimension set and the exponent type are
parameters, by explicit design ([Bobbin et al. 2025][bobbin-arxiv] §3.2):

> "Therefore, a better definition needs to be able to include new base
> dimensions easily, allow the user to specify which base dimensions they want
> to consider, and allow flexibility in the exponent type."

**Classical logic where computation is not the point.** Degenerate operations —
adding two dimensions, which is only meaningful when they are equal — are
defined with Hilbert's choice operator (`Classical.epsilon`,
[`Basic.lean` L87–90][lda-basic]) and marked `noncomputable`. The framework
optimizes for provability, not for `#eval`.

**Quantities graded by dimension.** The pinned HEAD commit — the repo's entire
public history is this one commit, "Changed physical variable to be a graded
structure and strengthened power definitions." — moves the dimension from a
runtime field into the **type index**: `PhysicalVariable (d : dimension B V)`
stores only a `value : V`. The paper: "With the graded structure, we can encode
the dimension manipulation of an operator directly into the type"
([Bobbin et al. 2025][bobbin-arxiv] §4.5). The superseded field-based version
survives as [`Basic_implicityDimension.lean`][lda-pv-implicit].

---

## How it works

### Dimensions: exponent maps with a proved group structure

The whole representation is one line ([`Basic.lean` L60–61][lda-basic]):

```lean
-- LeanDimensionalAnalysis @ de263ee: DimensionalAnalysis/Basic.lean
-- Here we define a dimension as a mapping of a base dimension to a number which is the exponent.
def dimension (B : Type u) (E : Type v) [CommRing E] := B → E
```

Multiplication adds exponents pointwise, division subtracts, powers scale —
and the scalar of a power may live in a _different_ type acting on `E`
([`Basic.lean` L93–101][lda-basic]):

```lean
-- LeanDimensionalAnalysis @ de263ee: DimensionalAnalysis/Basic.lean
protected def mul  : dimension B E → dimension B E → dimension B E
| a, b => fun i => a i + b i
protected def div  : dimension B E → dimension B E → dimension B E
| a, b => fun i => a i - b i

protected def pow {E E2} [CommRing E] [SMul E2 E]: dimension B E → E2 → dimension B E
| a, n => fun i => n • (a i)
```

The identity is `dimensionless B E := Function.const B 0`, bound to `One`
(L76–77). Addition of dimensions — legal only between equal dimensions, and
then a no-op — is specified rather than computed
([`Basic.lean` L87–88][lda-basic]):

```lean
-- LeanDimensionalAnalysis @ de263ee: DimensionalAnalysis/Basic.lean
protected noncomputable def add : dimension B E → dimension B E → dimension B E :=
Classical.epsilon $ fun f => ∀ a b, a = b → f a b = a
```

— "a formal way of saying if `a = b`, `a + b = a`"
([Bobbin et al. 2025][bobbin-arxiv] §4.2). After a battery of `@[simp]` helper
lemmas and hand-proved laws, the headline instance lands at
[`Basic.lean` L234][lda-basic]:

```lean
-- LeanDimensionalAnalysis @ de263ee: DimensionalAnalysis/Basic.lean (abridged)
instance  : CommGroup (dimension B E) where
  mul := dimension.mul
  div := dimension.div
  inv a := dimension.pow a (-1)
  one := dimensionless B E
  mul_comm := dimension.mul_comm
  inv_mul_cancel a := dimension.mul_left_inv a
  -- … npow/zpow laws discharged by funext + ring rewriting
```

### Base dimensions: an open set unified by type classes

There is no fixed base-dimension enumeration. Any type `B` can serve, and
membership of a conceptual base dimension is a type class
([`Basic.lean` L16–18][lda-basic]):

```lean
-- LeanDimensionalAnalysis @ de263ee: DimensionalAnalysis/Basic.lean
class HasBaseLength (B : Type u) where
  [dec : DecidableEq B]
  Length : B
```

Seven such classes cover the ISQ set (`HasBaseTime`, `HasBaseLength`,
`HasBaseMass`, `HasBaseAmount`, `HasBaseCurrent`, `HasBaseTemperature`,
`HasBaseLuminosity`), and an eighth — `HasBaseCurrency` (L41–43) — exists
precisely to demonstrate that the set is open. [`ISQ.lean`][lda-isq] packages
the standard system: a seven-constructor `inductive ISQ` with instances tying
each class to its constructor. Concrete dimensions select a coordinate via
`Pi.single`, and derived dimensions are ordinary group words
([`Dimensions.lean` L12, L30–31, L43][lda-dims]):

```lean
-- LeanDimensionalAnalysis @ de263ee: DimensionalAnalysis/Dimensions.lean
def length [HasBaseLength B] : dimension B E := Pi.single HasBaseLength.Length 1

abbrev velocity := length B E/time B E
abbrev acceleration := length B E / ((time B E) ^ 2)
abbrev energy := mass B E * (length B E)^2/(time B E)^2
```

`abbrev` (reducible definitions) is a deliberate choice "so Lean's type checker
can automatically look inside the definition" during unification
([Bobbin et al. 2025][bobbin-arxiv] §4.4). Homogeneity facts are then ordinary
theorems — [`DimensionalHomogeneity.lean` L7–14][lda-homog] proves
`acceleration B E = velocity B E / time B E` by rewriting, and that the
Reynolds-number dimension equals `dimensionless B E` by two `rw` chains
totalling 21 rewrite steps.

### Quantities: a graded structure, with units as values

A physical variable is a single value indexed by its dimension; operators
compute the result dimension **in the type**
([`PhysicalVariables/Basic.Lean` L5–6, L16–20, L35–39][lda-pv]):

```lean
-- LeanDimensionalAnalysis @ de263ee: PhysicalVariables/Basic.Lean
structure PhysicalVariable {B : Type u} {V : Type v} [Field V] (dim : dimension B V) where
(value : V)

protected def Mul {B : Type u} {V : Type v} [Field V] {d1 d2 : dimension B V}:
PhysicalVariable d1 →  PhysicalVariable d2 → PhysicalVariable (d1*d2)
| a,b => PhysicalVariable.mk (a.value*b.value)

protected def Add {B : Type u} {V : Type v} [Field V] {d : dimension B V} :
  PhysicalVariable d → PhysicalVariable d → PhysicalVariable d
| a, b => ⟨a.value + b.value⟩
```

`Add` is the mismatch rule: it exists only at a _single_ dimension index `d`,
so adding a length to a time is ill-typed before any "checking" happens (see
[Diagnostics](#diagnostics)). Per-dimension quantities form a proved
`AddCommGroup (PhysicalVariable d)` (L145–162) — the group-per-dimension shape
of [Whitney's quantity structures][whitney].

Units are plain values of the graded type — SI-2019 style, defined from the
defining constants down ([`PhysicalVariables/Basic.Lean` L171–189][lda-pv]):

```lean
-- LeanDimensionalAnalysis @ de263ee: PhysicalVariables/Basic.Lean
def casesium133GroundStateHyperfineOscillationDuration {B : Type u} {V : Type v} [Field V] [HasBaseTime B] :
PhysicalVariable (dimension.time B V) := ⟨1⟩

def second (B : Type u) (V : Type v) [Field V] [HasBaseTime B] : PhysicalVariable (dimension.time B V) := 9192631770•casesium133GroundStateHyperfineOscillationDuration

def meter (B : Type u) (V : Type v) [Field V] [HasBaseLength B] : PhysicalVariable (dimension.length B V) := ⟨1⟩

def SpeedOfLight (B : Type u) (V : Type v) [Field V]   [HasBaseLength B] [HasBaseTime B] : PhysicalVariable (dimension.length B V / dimension.time B V) :=
  299792458 • meter B V/second B V
```

Planck's constant, the elementary charge, the Boltzmann constant, Avogadro's
number and the luminous-efficacy constant follow the same pattern (L191–216),
fixing the 2019 SI defining values as scalars on dimension-indexed `1`s.

### The cast and the tactic

Grading has a cost: `F = m·a` fails elaboration because the dimension `force`
is not _definitionally_ equal to `mass * acceleration` — only provably so. The
framework's answer is an explicit cast whose proof obligation is discharged by
a custom tactic ([`PhysicalVariables/Basic.Lean` L10–13][lda-pv];
[`DimensionalHomogeneity.lean` L16–28][lda-homog]):

```lean
-- LeanDimensionalAnalysis @ de263ee: PhysicalVariables/Basic.Lean
protected def cast {B : Type u} {V : Type v} [Field V] {d1 d2 : dimension B V} (Q : PhysicalVariable d1) (_ : d1=d2 := by evalAutoDim) :
PhysicalVariable d2 := ⟨Q.value⟩

prefix:100 (priority := high) "↑" => PhysicalVariable.cast
```

```lean
-- LeanDimensionalAnalysis @ de263ee: DimensionalAnalysis/DimensionalHomogeneity.lean
macro "evalAutoDim" : tactic =>
  `(tactic|
    (first | rfl
           | try rw [mul_one,one_mul,mul_comm,one_eq_dimensionless]
             try simp
             try funext
             try module
             try ring_nf
             try field_simp
             try simp
             try rfl
    ))
```

`evalAutoDim` is a best-effort normalizer (`rfl`, then a cascade of `simp`/
`ring_nf`/`field_simp` attempts); the paper credits the cast-function design to
advice from Alfredo Moriera-Rosa and Terence Tao
([Bobbin et al. 2025][bobbin-arxiv], acknowledgements).

### Buckingham π and the Lennard-Jones application

The π machinery is three definitions over mathlib linear algebra — the only
mathlib import in `Basic.lean` is `Mathlib.LinearAlgebra.Matrix.Rank`
([`Basic.lean` L258–275][lda-basic]):

```lean
-- LeanDimensionalAnalysis @ de263ee: DimensionalAnalysis/Basic.lean
def dimensional_matrix {n : ℕ} [Fintype B] (d : Fin n → dimension B E)
  (perm : Fin (Fintype.card B) → B) : Matrix (Fin (Fintype.card B)) (Fin n) E :=
    Matrix.of.toFun (fun (a : Fin (Fintype.card B)) (i : Fin n) => d i (perm a))

noncomputable def number_of_dimensionless_parameters {n : ℕ}  [Fintype B]
  (d : Fin n → dimension B E) (perm : Fin (Fintype.card B) → B) :=
    n - Matrix.rank (dimensional_matrix d perm)

def dimensionless_numbers_matrix {n : ℕ}  [Fintype B] (d : Fin n → dimension B E)
  (perm : Fin (Fintype.card B) → B) :=
    LinearMap.ker (Matrix.toLin' (dimensional_matrix d perm))
```

— exactly the rank–nullity reading of the theorem developed on the
[Buckingham-π theory page][buckingham]: π-count `= n − rank`, π-groups from the
kernel. The showcase application ([`PhysicalVariables/LennardJones.lean`][lda-lj])
defines the Lennard-Jones potential over dimension-indexed `σ`, `ε`, `r` and
proves `LJ_zero_energy` (zero energy at separation `σ`, L19–29) and `LJ_deriv`
(the force law as the framework's dimension-aware derivative, L43–70) — physical
theorems whose _statements_ are dimensionally checked by construction.

---

## Dimension representation

- **Term-level exponent function, used as a type index.** A dimension is an
  ordinary Lean function `B → E` — data, not a type-level encoding — but
  `PhysicalVariable (d : dimension B V)` promotes it to a type index, so
  quantity checking is dependent typing over that data. No other system in the
  catalog has this shape: the closest cousins are the type-level exponent
  vectors of [`dimensional`][dimensional]/[Boost.Units][boost-units] (closed
  base set, type-level `ℤ`) and F#'s compiler-internal `Measure` terms
  ([fsharp-uom][fsharp-uom]).
- **Open base set, per-concept type classes.** `B` is any type;
  `HasBaseLength B` etc. assert membership. Two different systems
  (the paper's `KinematicSystem` vs `SpatialTemporalSystem`) unify at the level
  of shared classes, not shared constructors — see
  [Extensibility](#extensibility).
- **Open exponent domain.** `E` is any `CommRing` — `ℤ` for classical integer
  lattices, `ℚ` for fractional powers, and nothing stops `ℝ` (the physics
  convention against irrational exponents is _not_ enforced; the paper's own
  footnote excludes reals informally, [Bobbin et al. 2025][bobbin-arxiv] §3.2).
  A `Coe (dimension B E1) (dimension B E2)` instance (L69–70) migrates a
  dimension between exponent types, and `pow`'s `SMul E2 E` constraint lets the
  power scalar live in yet another type. The
  [`Basic_Multiplicative.lean`][lda-basic-mult] variant goes further: its type
  definition is `Multiplicative (B → E)` under only `[AddCommGroup E]` (L66–67)
  — the exponent structure genuinely needed — though the rest of that file
  re-imposes `CommRing` (it is visibly an experiment, with `#check` debris at
  L75–76).
- **The full function group, not the free abelian group.** `B → E` with
  pointwise operations is `Eᴮ`, which for infinite `B` contains
  infinitely-supported "dimensions" no finite product of base dimensions
  generates. mathlib's `FreeAbelianGroup α` (functions `α → ℤ` with **finite
  support**, [`FreeAbelianGroup.lean`][mathlib-fag] L20–22) is the exact
  [free-abelian-group][fag] construction — and is not used. For the finite
  systems the framework actually instantiates (`Fintype B`, as in
  [`ISQ.lean`][lda-isq]; also required by `dimensional_matrix`) the two
  coincide, so the choice costs nothing in practice; it does mean "dimensions
  form the free abelian group on the base set" is true here only for finite
  `B`.
- **Comparison operators are equality tests.** `le` and `lt` on dimensions are
  both `ite (a = b) true false` ([`Basic.lean` L105–108][lda-basic]) — "same
  dimension" predicates for guarding comparisons of quantities. A wart follows:
  `@[simp] lemma lt_def' : a < a` is provable (L179–181) — `<` is not an
  order.

## Checking & inference

**There is no inference and no dedicated solver — checking _is_ elaboration.**
Where [F#][fsharp-uom] runs Kennedy's abelian-group unification and the
[`uom-plugin`][uom-plugin] extends GHC's solver with a units theory, Lean has
exactly two mechanisms, and the framework leans on both:

1. **Definitional equality.** `velocity` is an `abbrev`, so
   `length/time` and `velocity` unify silently during type checking. Whatever
   reduces to the same normal form needs no proof at all.
2. **Propositional equality plus tactics.** Anything true only up to group
   laws (`force` vs `mass * acceleration`) requires an explicit `↑` cast whose
   equality obligation `d1 = d2` is discharged by `evalAutoDim` — in effect a
   user-space, best-effort normal-form procedure playing the role that
   [Kennedy's AG-unification][kennedy-types] plays inside the F# compiler,
   with `funext` + `ring_nf` on exponents substituting for Gaussian
   elimination.

Decidability is dodged, not solved: `Decidable (a = b)` for dimensions is
obtained classically (`Classical.propDecidable`, [`Basic.lean` L79–80][lda-basic]),
i.e. noncomputably. For `Fintype B` and decidable `E` equality it _would_ be
decidable by enumeration; the framework never builds that instance because
proofs, not decision procedures, are its currency.

**Dimensional polymorphism is free — and stronger than anywhere else in the
catalog.** Every definition and theorem is already polymorphic over `B`, `E`,
_and the dimension index itself_: `PhysicalVariable.Mul` works at any pair
`d1 d2`, and the exponent-shifting generic that most systems cannot express is
one line over the repo's `Pow` (L50–51):

```lean
-- illustrative composition of PhysicalVariable.Pow (Basic.Lean L50–51) @ de263ee
def sqr {d : dimension B V} (a : PhysicalVariable d) :
    PhysicalVariable (d ^ (2 : ℕ)) := a.Pow 2
```

The `sqr : α → α²` litmus of this survey holds — with one syntactic
concession: `Pow` cannot be bound to the `HPow` notation class, "because we
have to know the power `n` to know the output dimension. To write `a^b`, we
would write `a.Pow b`" ([Bobbin et al. 2025][bobbin-arxiv] §4.5). And beyond
polymorphic _programs_, the framework states polymorphic _theorems_ —
`PhysicalVariable.mul_comm` (with a cast, L97–98), `LJ_deriv` — quantified over
all dimensions and all systems: the "theorems about the framework" capability
no non-dependently-typed system in this catalog possesses.

## Extensibility

Defining a new system is an inductive type plus instances — the paper's own
example ([Bobbin et al. 2025][bobbin-arxiv] §4.1):

```lean
-- Bobbin et al. 2025 §4.1 (paper listing; ISQ.lean carries the full 7-dimension analogue)
inductive KinematicSystem
| Length | Time | Mass

instance : HasBaseLength KinematicSystem :=
{ dec := KinematicSystem.DecidableEq, Length := KinematicSystem.Length }
```

- **Interop between systems is by concept, not by name.** A theorem assuming
  `[HasBaseLength B] [HasBaseTime B]` applies to `ISQ`, to `KinematicSystem`,
  and to any user system with those instances — the two `Length`s are unified
  through the class, though the underlying types stay distinct. This is
  structurally richer than [GNAT's positional cross-system conversion][gnat]
  and closest in spirit to mp-units' quantity-spec hierarchy, minus the kinds.
- **New base dimensions are additive.** `HasBaseCurrency`
  ([`Basic.lean` L41–43][lda-basic]) demonstrates the open set: no 7-slot
  ceiling (contrast GNAT's `Max_Number_Of_Dimensions = 7`), no library rebuild
  (contrast [`uom`'s closed `system!` invocation][rust-uom]).
- **Units and prefixes are unchecked value-level constants.** `centimeter :=
(1/100)•meter`, `inch := (100/254) • centimeter`, `millisecond := (1/100) •
second` ([`PhysicalVariables/Basic.Lean` L218–228][lda-pv]). The framework
  verifies their _dimensions_ only — and the pinned clone proves the point the
  hard way: `millisecond` is defined as 1/100 of a second (not 1/1000), and
  `inch` as `100/254` centimetres (the 2.54 cm/inch factor inverted). Both
  type-check, because both are lengths and times of _some_ magnitude. This is
  the same "wrong `km` factor compiles" weakness every checking-not-conversion
  system in the survey shares — here it is present in the shipped source at
  the pin.
- **No scoping story.** Everything is global `def`s and instances in two
  `lean_lib`s; there is no unit-name resolution, no registry, no notion of
  local systems beyond ordinary Lean namespacing.

## Expressiveness edges

- **Fractional powers: yes, by choosing the exponent ring.** Instantiate
  `E := ℚ` and `d ^ (q : ℚ)` scales exponents exactly; the heterogeneous
  `SMul E2 E` power even allows mixed exponent types, and the `Coe` instance
  migrates integer-exponent dimensions into `ℚ` on demand. No system-wide
  commitment is needed (contrast Boost.Units' `static_rational` everywhere or
  [F#'s `ℚ`-normal forms][fsharp-uom]).
- **Affine quantities (temperature): absent.** `kelvin` is a base-unit value;
  there is no Celsius, no affine layer, no point/difference distinction —
  the gap the [torsor page][torsor] formalizes. A framework whose whole point
  is proving structure _could_ state torsor axioms; it has not.
- **Logarithmic quantities (dB): absent, prohibitively so.** The framework
  encodes the classical rule that transcendental maps fix only dimensionless
  arguments as `relativeOperator` ([`Basic.lean` L131–132][lda-basic]), again by
  `Classical.epsilon`: any operator with `dim = 1 → Operator dim = 1`. Log-scale
  quantities have no representation.
- **Angles: dimensionless.** `steradian` is _defined_ as
  `PhysicalVariable (dimension.dimensionless B V)` via `m²/m²`
  ([`PhysicalVariables/Basic.Lean` L208–210][lda-pv]); radians never appear. The
  `rad`/`sr` collapse of SI is inherited verbatim.
- **Kind vs dimension: collapses.** Dimensions are exponent functions, so
  `Hz` vs `Bq` or torque vs energy are indistinguishable — with the one
  mitigation that a determined user can mint a new _base_ dimension (e.g. an
  `Angle` base à la `HasBaseCurrency`) and rebuild, which closed-vector systems
  cannot. No kind system à la [mp-units][mp-units] exists.
- **The π theorem is defined, not proved.** The "Buckingham-Pi Theorem"
  section ([`Basic.lean` L258–275][lda-basic]) contains three _definitions_ —
  matrix, count, kernel — and no theorem: nothing states that a dimensionally
  homogeneous relation factors through `n − rank` dimensionless products (the
  actual content of the [π theorem][buckingham], whose proof needs the analytic
  step). The paper's phrasing ("implement the Buckingham Pi Theorem") is
  accurate for the linear-algebra scaffolding only. Likewise `number_of_…` uses
  truncated `ℕ` subtraction, and `Matrix.rank` over a general `CommRing E` is
  only as well-behaved as `E` (fields are the intended case).
- **Unit conversion: out of scope.** All values are coherent-SI magnitudes;
  there is no quantity-vs-unit distinction, no conversion checking, no output
  formatting. The repo's closing comment says as much
  ([`LennardJones.lean` L84–88][lda-lj]): "if epsilon in kcal vs equiv kelvin,
  who makes sure its right? - show unit conversion … vectors/matrices?" — both
  named as future work (the latter is [Hart's program][hart]).

## Zero-cost story

For a proof assistant the question inverts: the artifact is certainty, not
machine code. Still, the story has two precise halves:

- **Dimension data has no runtime representation — by the same construction
  as everywhere else.** `PhysicalVariable d` has exactly one field, `value : V`
  ([`PhysicalVariables/Basic.Lean` L5–6][lda-pv]); the dimension is a type index,
  erased like any Lean type parameter. In the pre-grading variant
  ([`Basic_implicityDimension.lean`][lda-pv-implicit] L6–8) the dimension _was_ a
  runtime field carried through every operation — the HEAD commit's move to a
  graded structure is, among other things, the erasure step.
- **But large parts are deliberately noncomputable.** `add`/`sub` on dimensions
  (`Classical.epsilon`), dimension-equality decidability
  (`Classical.propDecidable`), `number_of_dimensionless_parameters`
  (`Matrix.rank`), and the physical-variable `deriv` are all `noncomputable` —
  the paper spells out the consequence: "the definition cannot be compiled by
  Lean for the use of the `#eval` command"
  ([Bobbin et al. 2025][bobbin-arxiv] §4.2). The computable remainder does
  compile — the pinned clone ships committed `.lake/build/ir/*.c` artifacts
  (Lean-emitted C for `Basic`, `Dimensions`, `Basic_GradedStructure`, …) — but
  no benchmark, ABI note, or codegen claim exists, and none would be to the
  point. Checking cost is paid entirely at elaboration time; run time
  inherits whatever the extracted value arithmetic costs.

## Diagnostics

**Rung 2 — repo-typing + paper, by design.** No local elaboration was
attempted: reproducing the pinned toolchain (`v4.23.0-rc2` + a mathlib master
revision) means fetching a multi-gigabyte mathlib build cache or rebuilding
mathlib from source, which is out of proportion for this survey run. Neither
the repo nor the paper prints a verbatim Lean error message, and none is
fabricated here; what both artifacts document precisely is _which_ terms are
ill-typed and why. The mismatch program is ill-typed by the `Add` signature —
addition exists only at a single dimension index:

```lean
-- ill-dimensioned term (illustrative, not elaborated locally);
-- rejected by the typing at PhysicalVariables/Basic.Lean L35–39 @ de263ee
#check Units.meter ISQ ℚ + Units.second ISQ ℚ
-- `Add`/`HAdd` is only available at one index `d`:
--   PhysicalVariable d → PhysicalVariable d → PhysicalVariable d
-- `meter…  : PhysicalVariable (dimension.length ISQ ℚ)`
-- `second… : PhysicalVariable (dimension.time  ISQ ℚ)`  — no instance applies;
-- elaboration fails with a type/instance mismatch at the `+`.
```

\[repo-tests: typing at [`PhysicalVariables/Basic.Lean`][lda-pv] L35–39 @
`de263ee`; no compile-fail test suite exists in the pinned clone\]. The paper
documents the failure mode — including its false-positive flavour, where even a
_correct_ equation is rejected until cast
([Bobbin et al. 2025][bobbin-arxiv] §4.5):

> "if Newton's second law F = ma was written using this formulation, we would
> get an error because the dimension force is not definitionally equal to the
> dimension mass times acceleration. However, it is prepositionally \[sic\]
> equal. This means Lean cannot automatically do a type class inference on this
> equation and throws an error."

So the diagnostic surface splits in two: a **true mismatch** (`m + s`) fails
with no instance/defeq at any cast, while a **homogeneous-but-not-definitional**
term fails identically until the user inserts `↑` and `evalAutoDim` proves
`d1 = d2`. The error text in both cases is Lean's generic elaboration
vocabulary — type mismatches over fully-elaborated dependent types
(`PhysicalVariable (dimension.length B V)` vs
`PhysicalVariable (dimension.time B V)`) — not a domain message; nothing in the
framework customizes diagnostics. By the standards of this survey that places
Lean below [GNAT][gnat]/[F#][fsharp-uom] (owned error channels) and roughly
beside the C++ template systems (mechanism-vocabulary errors), with the unique
consolation that the "error" for a homogeneity _claim_ can be an unfinished
proof goal — inspectable, and closable interactively.

## Ergonomics & compile-time cost

- **Declaration overhead is real.** Every unit and constant is a `def`
  threading `(B : Type u) (V : Type v) [Field V] [HasBase… B]` parameters;
  every non-definitional homogeneity point needs a visible `↑`. The pinned
  [`ISQ.lean`][lda-isq] hand-writes a 49-case `DecidableEq ISQ` instance
  (L8–57) that `deriving DecidableEq` would generate — research-code
  ergonomics, not library polish.
- **Compile-time cost is mathlib.** The framework itself is ~1,200 lines, but
  it imports mathlib (`Matrix.Rank`, `Mathlib.Tactic`, analysis for `deriv`);
  first builds without a cache fetch are hours, and the `.lake` cache is
  gigabytes. Per-file elaboration after that is seconds-to-minutes —
  unmeasured here (no local toolchain; see Diagnostics) and undocumented in
  the artifacts.
- **Proof burden scales with ambition.** `reynolds_eq_dimless` is a
  21-step rewrite chain ([`DimensionalHomogeneity.lean` L10–14][lda-homog]);
  `LJ_deriv` is ~25 tactic lines ending in two `aesop`s
  ([`LennardJones.lean` L43–70][lda-lj]). `evalAutoDim` absorbs the routine
  cases ("for all the cases we tested, we found the tactic to be strong
  enough", [Bobbin et al. 2025][bobbin-arxiv] §4.5), but it is a heuristic
  cascade, not a decision procedure with a completeness theorem.
- **Repo hygiene at the pin, stated plainly:** a single-commit public history
  with committed `.lake/build` artifacts; `PhysicalVariables/LennardJones.lean`
  L1 imports `PhysicalVariables.Basic_GradedStructure`, a module whose source
  file does not exist at `de263ee` (the committed build IR shows it was renamed
  to `Basic.Lean` — capital-`L` extension — without updating the import, so the
  flagship application file cannot build as pinned); plus the `millisecond`/
  `inch` factor slips and `casesium`/`viscocity` spellings noted above. None of
  this undermines the formal content — the kernel checked what was built — but
  it calibrates expectations: this is a research artifact accompanying a paper,
  not maintained infrastructure.

### Other provers, via the paper

The companion paper's bibliography is the groundable gateway to non-Lean
mechanizations, and it is thinner than one might expect — **no Coq or Isabelle
units-of-measure formalization is cited** (Isabelle-lineage and HOL references
appear only as general prover background). What it does cite (all via-paper,
not independently verified here): the **PVS** dimensional analysis of
Owre, Saha & Shankar for cyber-physical systems (FM 2012) — the one other
proof-assistant units system in its related work; McBride &
Nordvall-Forsberg's dependent-type-theoretic "Type systems for programs
respecting dimensions" (2021); and, within Lean, Tooby-Smith's
**HepLean/PhysLean** (independent physical-variable formulations, per the
paper's acknowledgements) and the ATOMS Lab's own precursors (formalized
chemical physics 2024; verified Lennard-Jones computation 2025). The theory
side of this survey grounds the mathematics those provers would formalize:
[Kennedy's thesis][kennedy-types] ch. 8 and [Tao's 2012 post][tensor-lines]
both sketch what a full mechanization owes, and this framework is the furthest
any prover has taken it as of the pin.

---

## Strengths

- **The model is proved, not assumed.** `CommGroup (dimension B E)` is a
  checked theorem over an open base set and open exponent ring — the only
  system in this catalog where the [free-abelian-group model][fag] is a
  conclusion rather than an encoding target.
- **Theorems about the framework.** Dimension-polymorphic, system-polymorphic
  statements (`mul_comm` over all `d1 d2`, Reynolds dimensionlessness, the LJ
  force law) are inexpressible in every non-dependent system surveyed.
- **`sqr : α → α²` and beyond, for free.** Exponent-shifting polymorphism —
  the hard case for [F#][fsharp-uom] and impossible for
  [GNAT][gnat]/[C++][mp-units] — is ordinary dependent function space here.
- **Open base dimensions via type classes** — `HasBaseCurrency` adds a base
  dimension without touching existing code; systems interoperate by concept.
- **Buckingham-π scaffolding on real linear algebra** — π-count and π-group
  kernel as definitions over `Matrix.rank`/`LinearMap.ker`, directly matching
  the [theory page's rank–nullity reading][buckingham].
- **Graded quantities erase dimension data structurally** — one `value` field;
  the HEAD commit's redesign moved dimensions wholly into types.

## Weaknesses

- **mathlib has nothing** — the negative finding stands on its own: no
  dedicated development, no `Quantity`, no SI, only `FreeAbelianGroup` as raw
  material. Everything here lives in one unreleased external repo.
- **No inference, generic diagnostics.** Homogeneity that isn't definitional
  needs a hand-inserted cast plus a heuristic tactic; errors are Lean's
  elaboration vocabulary, not units language.
- **The π theorem itself is unformalized** — definitions only; no statement or
  proof of the factorization result, which is the theorem's actual content.
- **Affine, logarithmic, angular, kind distinctions: all absent** — °C, dB,
  rad-vs-sr, Hz-vs-Bq are out of scope at the pin.
- **Unit conversion is out of scope and value-level factors are unchecked** —
  demonstrated _in the pinned source_ by the wrong `millisecond` and `inch`
  factors.
- **Not executable where it counts** — `Classical.epsilon`/`noncomputable`
  choices rule out `#eval` for dimension arithmetic and π-counts; this is a
  proving framework, not a computing one.
- **Research-artifact fragility** — single commit, committed build artifacts, a
  stale import that breaks the flagship example's build, typos; no releases,
  no CI, no maintenance signal since 2025-09.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                         | Trade-off                                                                                                       |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| `dimension B E := B → E`, a term-level function as a type index     | Ordinary group theory applies; open base set and exponent ring; theorems quantify over dimensions | Full function space, not free abelian group (coincide only for finite `B`); no computable equality by default   |
| Base dimensions as type classes (`HasBaseLength …`)                 | Systems stay user-defined yet interoperable by concept; new base dimensions are additive          | Instance boilerplate per system; nothing prevents incoherent duplicate instances                                |
| Exponents in any `CommRing E`                                       | `ℤ`/`ℚ`/mixed via `SMul`/`Coe`; fractional powers by instantiation, not redesign                  | More permissive than physics (irrational exponents type-check); rank/kernels best-behaved only over fields      |
| `add` on dimensions via `Classical.epsilon`                         | Specifies "defined only when equal" without partial functions; keeps `a + a = a` provable         | `noncomputable`; meaningless off the diagonal; startles readers expecting a partial operation                   |
| Quantities as a graded structure `PhysicalVariable d` (HEAD commit) | Homogeneity is typing — `Add` exists only per-dimension; dimension data structurally erased       | `F = m·a` needs explicit casts; `Pow` can't join `HPow`; every proof drags dependent indices around             |
| Homogeneity casts discharged by a bespoke tactic (`evalAutoDim`)    | Routine group-law obligations close automatically; user can always supply a manual proof          | Heuristic `first/try` cascade — no completeness result, silent dependence on `simp`-set behaviour               |
| Buckingham-π as definitions over `Matrix.rank`                      | Reuses mathlib linear algebra verbatim; π-count/π-groups computable in principle from the matrix  | The theorem's factorization statement is never proved; `ℕ`-truncated subtraction hides rank-vs-`n` corner cases |
| Build on mathlib, publish as standalone research repo               | Full tactic/algebra stack for free; kernel-checked trust story                                    | Gigabyte-scale dependency; no releases or CI; drifts against mathlib master; mathlib itself gains nothing back  |

## Sources

- [`ATOMSLab/LeanDimensionalAnalysis`][lda-repo] pinned @ `de263ee`
  (`$REPOS/lean/LeanDimensionalAnalysis`) — [`DimensionalAnalysis/Basic.lean`][lda-basic]
  (base-dimension classes L12–55, `dimension` L61, `add` via `Classical.epsilon`
  L87–90, `mul`/`div`/`pow` L93–101, `relativeOperator` L131–132, `le`/`lt`
  L105–108 + `lt_def'` L179–181, `CommGroup` instance L234–251, Buckingham-π
  defs L258–275); [`Basic_Multiplicative.lean`][lda-basic-mult]
  (`Multiplicative (B → E)` over `AddCommGroup E`, L66–67);
  [`Dimensions.lean`][lda-dims] (`Pi.single` primaries, derived `abbrev`s);
  [`ISQ.lean`][lda-isq] (the packaged 7-dimension system);
  [`DimensionalHomogeneity.lean`][lda-homog] (homogeneity theorems,
  `evalAutoDim` L16–28); [`PhysicalVariables/Basic.Lean`][lda-pv] (graded
  `PhysicalVariable` L5–6, `cast` L10–13, ops L16–60, `AddCommGroup` instance
  L145–162, SI units & constants L169–228);
  [`PhysicalVariables/Basic_implicityDimension.lean`][lda-pv-implicit] (the
  superseded dimension-as-field design);
  [`PhysicalVariables/LennardJones.lean`][lda-lj] (application theorems; stale
  `Basic_GradedStructure` import at L1).
- [Bobbin, Jones, Velkey & Josephson, "Formalizing Dimensional Analysis Using
  the Lean Theorem Prover", arXiv:2509.13142 (2025)][bobbin-arxiv] — local copy
  `$PAPERS/bobbin-2025-formalizing-dimensional-analysis-lean-arxiv.pdf`
  (motivation §1, definition rationale §3.2, implementation §4, `F = ma`
  failure mode & cast §4.5, Buckingham-π supplement §S1, derivative §S2,
  acknowledgements for the Tao/Moriera-Rosa cast advice and the
  HepLean/PhysLean pointers; its refs \[18\] McBride & Nordvall-Forsberg,
  \[23\] Owre–Saha–Shankar PVS, \[29\]\[30\] Tooby-Smith, \[4\]\[31\] ATOMS Lab
  precursors — all cited via-paper).
- [`leanprover-community/mathlib4`][mathlib] pinned @ `ab4e75d`
  (`$REPOS/lean/mathlib4`) — negative finding (zero hits for
  "dimensional analysis" / "units of measure" / "Buckingham" /
  "physical quantit-" across `Mathlib/`, searched 2026-07-03);
  [`Mathlib/Algebra/Group/Units/Defs.lean`][mathlib-units] (what `Units` is);
  [`Mathlib/GroupTheory/FreeAbelianGroup.lean`][mathlib-fag] (the closest
  building block).
- Related deep-dives in this survey: [free abelian group][fag] ·
  [Buckingham π][buckingham] · [Kennedy's dimension types][kennedy-types] ·
  [type-system mechanisms][mechanisms] · [torsors (affine gap)][torsor] ·
  [Whitney's quantity structures][whitney] · [tensor of lines][tensor-lines] ·
  [Hart's multidimensional analysis][hart] · [F#][fsharp-uom] ·
  [`uom-plugin`][uom-plugin] · [`dimensional`][dimensional] ·
  [`uom` (Rust)][rust-uom] · [Boost.Units][boost-units] ·
  [mp-units][mp-units] · [GNAT][gnat] · [concepts][concepts] ·
  [the comparison capstone][comparison].

<!-- References -->

<!-- Same-tree theory pages -->

[fag]: ./theory/free-abelian-group.md
[buckingham]: ./theory/buckingham-pi.md
[kennedy-types]: ./theory/kennedy-types.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md
[whitney]: ./theory/whitney.md
[tensor-lines]: ./theory/tensor-of-lines.md
[hart]: ./theory/hart-multidimensional.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[fsharp-uom]: ./fsharp-uom.md
[uom-plugin]: ./haskell-uom-plugin.md
[dimensional]: ./haskell-dimensional.md
[rust-uom]: ./rust-uom.md
[boost-units]: ./cpp-boost-units.md
[mp-units]: ./cpp-mp-units.md
[gnat]: ./ada-gnat-dimensions.md

<!-- Pinned clone (ATOMSLab/LeanDimensionalAnalysis @ de263eed945693058ef2b8a1fa56c2ec5642ea7a) -->

[lda-repo]: https://github.com/ATOMSLab/LeanDimensionalAnalysis
[lda-basic]: https://github.com/ATOMSLab/LeanDimensionalAnalysis/blob/de263eed945693058ef2b8a1fa56c2ec5642ea7a/DimensionalAnalysis/Basic.lean
[lda-basic-mult]: https://github.com/ATOMSLab/LeanDimensionalAnalysis/blob/de263eed945693058ef2b8a1fa56c2ec5642ea7a/DimensionalAnalysis/Basic_Multiplicative.lean
[lda-dims]: https://github.com/ATOMSLab/LeanDimensionalAnalysis/blob/de263eed945693058ef2b8a1fa56c2ec5642ea7a/DimensionalAnalysis/Dimensions.lean
[lda-isq]: https://github.com/ATOMSLab/LeanDimensionalAnalysis/blob/de263eed945693058ef2b8a1fa56c2ec5642ea7a/DimensionalAnalysis/ISQ.lean
[lda-homog]: https://github.com/ATOMSLab/LeanDimensionalAnalysis/blob/de263eed945693058ef2b8a1fa56c2ec5642ea7a/DimensionalAnalysis/DimensionalHomogeneity.lean
[lda-pv]: https://github.com/ATOMSLab/LeanDimensionalAnalysis/blob/de263eed945693058ef2b8a1fa56c2ec5642ea7a/PhysicalVariables/Basic.Lean
[lda-pv-implicit]: https://github.com/ATOMSLab/LeanDimensionalAnalysis/blob/de263eed945693058ef2b8a1fa56c2ec5642ea7a/PhysicalVariables/Basic_implicityDimension.lean
[lda-lj]: https://github.com/ATOMSLab/LeanDimensionalAnalysis/blob/de263eed945693058ef2b8a1fa56c2ec5642ea7a/PhysicalVariables/LennardJones.lean

<!-- Companion paper -->

[bobbin-arxiv]: https://arxiv.org/abs/2509.13142

<!-- mathlib4 (pinned @ ab4e75d4a94f9bb4c0f47bded965aa5504e39422) -->

[mathlib]: https://github.com/leanprover-community/mathlib4
[mathlib-units]: https://github.com/leanprover-community/mathlib4/blob/ab4e75d4a94f9bb4c0f47bded965aa5504e39422/Mathlib/Algebra/Group/Units/Defs.lean
[mathlib-fag]: https://github.com/leanprover-community/mathlib4/blob/ab4e75d4a94f9bb4c0f47bded965aa5504e39422/Mathlib/GroupTheory/FreeAbelianGroup.lean
