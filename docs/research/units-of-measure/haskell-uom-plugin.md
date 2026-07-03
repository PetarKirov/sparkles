# uom-plugin (Haskell)

Adam Gundry's GHC typechecker plugin that turns units of measure into a type-system extension without forking the compiler: units live in an uninterpreted kind `Unit` built from equation-less type families, and a domain-specific solver for the equational theory of [free abelian groups][fag] is plugged into GHC's [OutsideIn(X)][outsidein-doi] constraint pipeline to solve what ordinary type-family reduction never could.

| Field            | Value                                                                                                                                                    |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | Haskell (GHC-only; the plugin links against the GHC API via [`ghc-tcplugin-api`][tcplugin-api])                                                          |
| License          | BSD-3-Clause ([`uom-plugin.cabal`][cabal])                                                                                                               |
| Repository       | [adamgundry/uom-plugin][repo]                                                                                                                            |
| Documentation    | [Hackage haddocks][hackage] (incl. `Data.UnitsOfMeasure.Tutorial`) · [the companion paper][paper-page]                                                   |
| Key authors      | Adam Gundry (Well-Typed); GHC 9.x port with Phil de Joux and Sam Derbyshire ([`CHANGELOG.md`][changelog])                                                |
| Category         | Statically-checked units — [compiler-plugin abelian-group unifier][mechanisms] (the "external solver" data point of this survey)                         |
| Mechanism        | GHC typechecker plugin: unit types normalised to a signed multiset of atoms (`Map Atom Integer`), unified over the free-AG theory, evidence by assertion |
| Exponent domain  | `ℤ` (solver-side); surface `^:` takes a `Nat`, negative powers written via `/:`; **no fractional exponents**                                             |
| Checking time    | Compile time (constraint solving); unit **conversions** are explicit runtime multiplications                                                             |
| Analyzed version | `0b87268` (2022-10-09 — the `0.4.0.0` release merge; also the repository HEAD)                                                                           |
| Latest release   | `0.4.0.0` (2022-10-08); supports GHC 9.0–9.4 only                                                                                                        |

> [!NOTE]
> `uom-plugin` is this survey's cleanest specimen of the **plugin AG-unifier** mechanism:
> [Kennedy-style][kennedy] units checking (as shipped natively in [F#][fsharp]) retrofitted
> onto a compiler whose built-in solver cannot decide abelian-group equations. Its foil is
> the **type-families-only** encoding used by [`dimensional`][dimensional] and by
> Muranushi & Eisenberg's `units` package (surveyed alongside `dimensional`), which trades
> inference quality and error messages for zero compiler extensions. The
> [type-system mechanisms][mechanisms] theory page compares all six mechanism families;
> the [comparison][comparison] capstone places this system in the full catalog.

---

## Overview

### What it solves

Haskell's type system is expressive enough to _encode_ units of measure — but not to make
them pleasant. Gundry's 2015 Haskell Symposium paper (archived locally for this survey as
`gundry-2015-typechecker-plugin-uom-haskell.pdf`) opens with the diagnosis
([abstract][paper-page]):

> _"Typed functional programming and units of measure are a natural combination, as F#
> ably demonstrates. However, encoding statically-checked units in Haskell's type system
> leads to inevitable disappointment with the usability of the resulting system. Extending
> the language itself would produce a much better result, but it would be a lot of work! In
> this paper, I demonstrate how typechecker plugins in the Glasgow Haskell Compiler allow
> users to define domain-specific constraint solving behaviour, making it possible to
> implement units of measure as a type system extension without rebuilding the compiler."_

The concrete obstruction is the [equational theory][fag]: unit multiplication must be
associative, commutative, have identity `One` and inverses — the laws of an abelian group.
GHC's constraint solver knows nothing of these laws, and the paper (§2.2) explains why the
standard Haskell escape hatch — closed type families — cannot supply them:

> _"GHC allows new axioms to be introduced using a type family, but type families (like
> functions) may pattern match only on constructors, not other type families, in the
> interests of checking consistency and termination of constraint solving. … In any case,
> type families are typically useful only if they define a terminating rewrite system, but
> associativity and commutativity are hardly going to do so!"_

Libraries that stop at type families (the paper dissects Muranushi & Eisenberg's `units`)
must compare _normal forms_ computed by type-level normalisation functions, which works for
concrete units but collapses in the presence of unit **variables** — no normal form can be
computed for `u *: v` when `u` is unknown — so unit polymorphism degrades and errors are
reported in terms of internal encodings. `uom-plugin`'s answer is to teach the constraint
solver the group theory itself.

### Design philosophy

Three decisions define the system, all visible in the pinned clone.

**Units are opaque type-level syntax; all meaning lives in the solver.** `One`, `Base`,
`*:` and `/:` are declared as type families _with no equations_ — not data constructors —
so GHC treats them as uninterpreted, non-injective symbols (paper §2.1):

> _"Representing them as type families with no equations means they are essentially opaque
> symbols that may not be partially applied and are not injective; this avoids the
> equational theory of units conflicting with GHC's built-in equality rules for types."_

**Defer to the plugin, on purpose.** The library even routes some equalities through a fake
constraint former `~~` so GHC's solver cannot touch them prematurely
([`Internal.hs`][internal]):

> "This is a bit of a hack, honestly, but a good hack. Constraints `u ~~ v` are just like
> equalities `u ~ v`, except solving them will be delayed until the plugin. This may lead
> to better inferred types."

**Honesty about maturity.** The README's first line after the title is a warning kept
through the final release ([`README.md`][readme] @ `0b87268`):

> "This library is experimental, and may lead to unexpected type-checking failures or even
> type soundness bugs."

That is not false modesty: the plugin asserts equality evidence _by fiat_ (see
[Zero-cost story](#zero-cost-story) and [Checking & inference](#checking--inference)), so
its soundness rests on the correctness of the AG-unification algorithm, not on anything
GHC can verify.

---

## How it works

### Core abstractions and types

| Concept            | Type / item                                                     | Role                                                                   |
| ------------------ | --------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Unit kind          | `data Unit` (empty datatype, promoted)                          | The kind of all units                                                  |
| Identity           | `One` — empty closed type family                                | Dimensionless unit (group identity)                                    |
| Generators         | `Base :: Symbol -> Unit` — empty closed type family             | Base units as type-level strings                                       |
| Group operations   | `*:`, `/:` — empty closed type families                         | Uninterpreted multiplication/division, solved only by the plugin       |
| Exponentiation     | `^: :: Unit -> Nat -> Unit` — closed family _with_ equations    | Expands `u ^: n` to repeated `*:`; `Nat` powers only                   |
| Quantity           | `newtype Quantity a (u :: Unit)`                                | A value of `a` tagged with phantom units                               |
| Deferred equality  | `~~` — empty closed type family returning `Constraint`          | Equality delayed until the plugin runs                                 |
| Unit names         | `MkUnit :: Symbol -> Unit` — **open** type family               | Maps a unit's name to its definition; the extension point              |
| Syntactic view     | `UnitSyntax`, `Unpack`, `Pack`                                  | Plugin-computed concrete representation, used by `Show`/`Read`/convert |
| Solver normal form | `NormUnit` = `Map Atom Integer` ([`NormalForm.hs`][normalform]) | Signed multiset of atoms — the free-AG element                         |
| Evidence           | `mkPluginUnivCo "units"` / `evByFiat` ([`Plugin.hs`][plugin])   | Unchecked universal coercions justifying solved constraints            |

### The `Unit` kind and `Quantity`

The whole type-level vocabulary fits on one screen
([`src/Data/UnitsOfMeasure/Internal.hs`][internal]):

```haskell
-- uom-plugin: src/Data/UnitsOfMeasure/Internal.hs @ 0b87268
-- | (Kind) Units of measure
data Unit

-- | Dimensionless unit (identity element)
type family One :: Unit where

-- | Base unit
type Base :: Symbol -> Unit
type family Base b where

-- | Multiplication for units of measure
type (*:) :: Unit -> Unit -> Unit
type family u *: v where

-- | Division for units of measure
type (/:) :: Unit -> Unit -> Unit
type family u /: v where

-- | A @Quantity a u@ is represented identically to a value of
-- underlying numeric type @a@, but with units @u@.
newtype Quantity a (u :: Unit) = MkQuantity a
type role Quantity representational nominal
```

The arithmetic API threads units through the index — addition demands equal units,
multiplication multiplies them (the term-level `*:` deliberately puns on the type-level
one), and the results are constrained via the plugin-deferred `~~`:

```haskell
-- uom-plugin: src/Data/UnitsOfMeasure/Internal.hs @ 0b87268
(+:) :: Num a => Quantity a u -> Quantity a u -> Quantity a u
(*:) :: (Num a, w ~~ u *: v) => Quantity a u -> Quantity a v -> Quantity a w
(/:) :: (Fractional a, w ~~ u /: v) => Quantity a u -> Quantity a v -> Quantity a w
sqrt' :: (Floating a, w ~~ u ^: 2) => Quantity a w -> Quantity a u
```

`MkQuantity` is exported only from the `.Internal` module: exposing it polymorphically
would let `MkQuantity . unQuantity` re-tag any quantity with any units. Safe construction
goes through the quasiquoter.

### The `u` quasiquoter

The Template Haskell quasiquoter ([`TH.hs`][th]) is the surface syntax, with a different
meaning per splice context: in **types** it parses a unit expression into the `Unit` kind;
in **expressions** it builds `MkQuantity` applications instantiated at concrete units
(`[u| 42 m |]`, or `[u| m/s |]` as a function `a -> Quantity a (Base "m" /: Base "s")`); in
**patterns** it matches `Integer`/`Rational` quantities; and in **declarations** it defines
new units. A valid multiplication, from the test suite
([`test-suite-units/Tests.hs`][tests]):

```haskell
-- uom-plugin: uom-plugin/test-suite-units/Tests.hs @ 0b87268
myMass :: Quantity Double (Base "kg")
myMass = [u| 65 kg |]

gravityOnEarth :: Quantity Double [u| m/s^2 |]
gravityOnEarth = [u| 9.808 m/(s*s) |]

forceOnGround :: Quantity Double [u| N |]
forceOnGround = gravityOnEarth *: myMass   -- plugin solves  N ~ (m/s^2) *: kg
```

That last line is the whole pitch: `N` is a _derived_ unit whose `MkUnit` instance expands
to `kg m / s^2`, and proving `Base "kg" *: (Base "m" /: Base "s" ^: 2)` equal to
`(Base "m" /: Base "s" ^: 2) *: Base "kg"` requires commutativity — a fact GHC alone
cannot use.

### The plugin

`Data.UnitsOfMeasure.Plugin` registers two hooks with GHC ([`Plugin.hs`][plugin]): a
**constraint solver** (`tcPluginSolve`) and — new in the 0.4/GHC 9.x port — a type-family
**rewriter** (`tcPluginRewrite`) that reduces `Unpack u` when `u` is fully concrete
("implemented by the plugin, because we cannot define it otherwise" —
[`Internal.hs`][internal]). The solver:

1. filters the unsolved constraints for equalities at kind `Unit` (including `~~`
   irreducibles) — `toUnitEquality` in [`Unify.hs`][unify];
2. **normalises** each side into a `NormUnit` — a signed multiset mapping each atom (base
   unit, variable, or stuck type-family application) to its integer exponent
   ([`NormalForm.hs`][normalform]):

   ```haskell
   -- uom-plugin: src/Data/UnitsOfMeasure/Plugin/NormalForm.hs @ 0b87268
   data Atom = BaseAtom Type | VarAtom TyVar | FamAtom TyCon [Type]

   -- | A unit normal form is a signed multiset of atoms; we maintain the
   -- invariant that the map does not contain any zero values.
   newtype NormUnit = NormUnit { _NormUnit :: Map.Map Atom Integer }
   ```

3. rewrites each equation `u ~ v` to `u /: v ~ 1` and runs Kennedy's AG-unification
   (`unifyOne`), eliminating variables one at a time — either solving a variable outright
   when its exponent divides all others, or introducing a fresh variable `beta` to reduce
   exponents modulo the smallest (the Gaussian-elimination step, rule (4) of the paper's
   Figure 7); results are `Win`/`Draw`/`Lose`;
4. reports contradictions (`Lose`, e.g. `kg ~ m`) as `TcPluginContradiction` — which is
   what turns into the user-visible type error — and returns solved constraints paired
   with evidence.

The evidence step is deliberately blunt ([`Plugin.hs`][plugin]):

```haskell
-- uom-plugin: src/Data/UnitsOfMeasure/Plugin.hs @ 0b87268
-- | Produce bogus evidence for a constraint, including actual
-- equality constraints and our fake '(~~)' equality constraints.
evMagic :: UnitDefs -> Ct -> EvTerm
```

`evByFiat` wraps `mkPluginUnivEvTerm "units"` — a universal coercion with `PluginProv`
provenance. The paper (§6.1) calls this "the method of proof by blatant assertion" and
lists genuine evidence generation from the group axioms as future work; it never landed.
The project CI compiles everything with `-dcore-lint` as a partial check
([`haskell-ci.yml`][ci]).

One more solver detail from the pinned source: the **givens-only simplification pass is
disabled** at this commit — a `TODO` in [`Plugin.hs`][plugin] explains that emitting
simplified givens caused rewriter loops ("if we emit a given constraint like
`x[sk] ~ Base "kg"` then GHC will 'simplify' all occurrences of the type family application
… This can then result in loops"), and the code returns `TcPluginOk [] []` for the
givens-only case. Givens are still simplified _internally_ when wanteds are being solved,
which is why `givens :: ((a *: a) ~ One) => Quantity Double a -> Quantity Double One`
still typechecks ([`Tests.hs`][tests]).

---

## Dimension representation

There are **no dimensions in the index — only units**, exactly as in F#. The paper is
explicit about the choice (§5.2):

> _"In the interests of simplicity, the uom-plugin library follows F#'s approach of
> indexing types by units of measure alone, not including dimensions, but the approach
> described in this paper should be able to scale to handle dimensions."_

- A unit is an element of the [free abelian group][fag] generated by `Base b` atoms, where
  `b` is a type-level `Symbol`. There is no fixed basis: the generator set is **open**
  (any string names a base unit once declared via `MkUnit`), unlike the closed 7-dimension
  SI vectors of [`rust-uom`][rust-uom] or [`dimensional`][dimensional].
- **Exponents are integers.** The solver's representation is literally a
  `Map Atom Integer` (signed multiset, zero entries pruned — [`NormalForm.hs`][normalform]).
  The surface exponentiation family is narrower: `^:` takes a `Nat`, with the doc comment
  "negative exponents are not yet supported (they require an Integer kind)"
  ([`Internal.hs`][internal]); the quasiquoter compiles `s^-1` to `One /: Base "s" ^: 1`
  ([`TH.hs`][th]), so negative powers exist only as division. Fractional exponents are
  representable nowhere — see [Expressiveness edges](#expressiveness-edges).
- **Dimension-like grouping is recovered by convention**, not by a kind: the conversion
  subsystem ([`Convert.hs`][convert]) picks a "canonical base unit" per dimension —
  "Rather than defining dimensions explicitly, we pick a 'canonical' base unit for each
  dimension, and record the conversion ratio between each base unit and the canonical base
  unit for its dimension" — and defines `Convertible u v` as "both units reduce to the same
  canonical form". Two units share a dimension iff `ToCanonicalUnit u ~ ToCanonicalUnit v`.

## Checking & inference

The checking story is the reason this system exists, and it is the strongest inference
story in the catalog outside F# itself.

**Algorithm.** Equational unification in the theory **AG** of free abelian groups
(decidable; unitary — most general unifiers exist), implemented as the incremental
simplification relation of the paper's Figure 7 and the `unifyOne`/`simplifyUnits` loop of
[`Unify.hs`][unify]. Each step replaces a constraint with an equivalent one (up to the
group laws), so steps may be applied in any order; `SimplifyState` tracks the substitution
`θ` and its inverse-ish companion `φ` (`simplifySubst`/`simplifyUnsubst`) exactly as in the
paper's soundness proof. Crucially the entailment relation adds a **torsion-freeness**
rule (`uᵏ ~ 1` implies `u ~ 1`) beyond the group laws — the paper notes it "amounts to
restricting models of `Unit` to being free abelian groups", and it is what licenses solving
`α² ~ 1` with `α ~ 1` (`Base "kg"` would otherwise be an alternative model).

**Metatheory — documented, with a documented gap.** Soundness is proved outright
(Theorem 1). Principality is _not_: the mgu for `α² ~ β³` is `α ~ γ³, β ~ γ²` for a fresh
`γ`, and OutsideIn(X)'s "guess-free" condition cannot account for the fresh variable. The
paper proves a weakened generality result (Theorem 2) and conjectures it suffices:

> _"That is, the solution found by the algorithm may not be guess-free in the original
> sense, but there is some substitution for the fresh variables it introduces by which it
> can be transformed into a guess-free solution. I conjecture that this weaker property is
> in fact sufficient for the proof that OutsideIn(X) type inference (if it succeeds)
> delivers principal types."_

**Dimensional polymorphism is expressible and inferred.** The generic-`sqr` test of this
survey passes here, unannotated ([`Tutorial.hs`][tutorial] doctest):

```haskell
-- GHCi, with the plugin enabled (uom-plugin/doc/Data/UnitsOfMeasure/Tutorial.hs @ 0b87268)
>>> let cube x = x *: x *: x
>>> :t cube
cube :: Num a => Quantity a v -> Quantity a (v *: (v *: v))

>>> let f x y = (x *: y) +: (y *: x)
>>> :t f
f :: Num a => Quantity a v -> Quantity a u -> Quantity a (u *: v)
```

Inferring `f`'s type requires solving `u *: v ~ v *: u` under binders — the exact point
where the type-families encoding gives up. The test suite goes further, checking genuinely
equational givens ([`Tests.hs`][tests]):

```haskell
-- uom-plugin: uom-plugin/test-suite-units/Tests.hs @ 0b87268
-- w^-2 ~ kg^-2  =>  w ~ kg
f :: (One /: (w ^: 2)) ~ (One /: [u| kg^2 |]) => Quantity a w -> Quantity a [u| kg |]
f = id

-- a^2 ~ b^3, b^6 ~ 1 => a ~ 1
givens2 :: ((a ^: 2) ~ (b ^: 3), (b ^: 6) ~ One) => Quantity Double a -> Quantity Double One
givens2 = id
```

For contrast, the inferred type the `units` package produces for the same `f` (paper
§2.2.1) shows what the plugin buys — this is the "before" picture:

```text
(Num a
, [] ~ Normalize (Normalize (d1 @@+ Reorder d2 d1)
                  @- Normalize (d2 @@+ Reorder d1 d2))
) => Qu d1 l a -> Qu d2 l a -> Qu (Normalize (d1 @@+ Reorder d2 d1)) l a
```

**Documented incompleteness.** The repository ships _negative_ tests: `ErrorTests.hs`
pins down constraints the solver is known not to discharge, e.g. exponent distribution
over type-level `Nat` addition ([`ErrorTests.hs`][errortests]):

```haskell
-- uom-plugin: uom-plugin/test-suite-units/ErrorTests.hs @ 0b87268
exponentDoesn'tDistribute :: Quantity Double ([u| m |] ^: (x + y))
                          -> Quantity Double (([u| m |] ^: x) *: [u| m |] ^: y)
exponentDoesn'tDistribute x = x   -- expected to be REJECTED
```

Exponent _variables_ are outside the free-AG fragment (that would be the theory of
`ℤ`-modules with symbolic scalars), so `m^(x+y) ~ m^x *: m^y` is stuck — the suite asserts
the resulting `Couldn't match type` error. Similarly `given1`–`given3` assert that trivial
or torsion-only givens (`(a ^: 2) ~ (b ^: 3)` alone) do **not** let unrelated wanteds
through. Generalisation has sharp edges too: a local binding that must be
unit-polymorphic "is accepted only with a type signature, even with `NoMonoLocalBinds`"
([`Tests.hs`][tests], the `tricky` example).

## Extensibility

Everything is user-extensible, because the "standard library" of units is itself just
demo material ("subject to change" — [`Tutorial.hs`][tutorial]).

**Custom base and derived units** are `MkUnit` instances, written via the declaration
quasiquoter or the TH helpers `declareBaseUnit` / `declareDerivedUnit` /
`declareConvertibleUnit` ([`TH.hs`][th]). The bundled defs module shows all three forms
([`Defs.hs`][defs]):

```haskell
-- uom-plugin: src/Data/UnitsOfMeasure/Defs.hs @ 0b87268
[u| m, kg, s, A, K, mol, cd |]          -- SI base units
[u| km = 1000m, g = 0.001 kg |]         -- convertible (prefixed) units
[u| Hz = s^-1
  , N  = kg m / s^2
  , Pa = N / m^2
  , J  = N m
 |]                                      -- derived units (definitional synonyms)
[u| ft = 100 % 328 m, mi = 1609.344 m |] -- imperial, via rational ratios
```

A bare name generates `type instance MkUnit "m" = Base "m"` plus a
`HasCanonicalBaseUnit "m"` instance; a definition with a numeric factor generates a _new
base unit_ carrying a `conversionBase` ratio to its canonical unit; a definition without a
factor is a pure synonym expanded at type-family-reduction time (so `N` really _is_
`kg m / s^2` to the solver). Note the demo quality: `ft` is declared as `100 % 328 m`
(≈ `0.3048780…`), not the exact `0.3048`.

**Prefixes** have no dedicated mechanism — `km` is just another convertible unit; there is
no systematic SI-prefix generator as in [`mp-units`][mp-units] or [Pint][pint].

**Scoping and interop.** `MkUnit` is a single global open type family and base units are
raw `Symbol`s, so unit names are **global**: two packages that both declare `[u| psi |]`
with different meanings produce conflicting `type instance`s (a compile error if both are
in scope), and `Base "m"` means the same thing everywhere whether or not anyone declared
it. There is no notion of a unit _system_ to scope against — contrast
[`boost-units`][boost-units]' per-system dimensions or [`au`][au]'s unit types.
Cross-dimension conversion interop is handled by the canonical-base-unit scheme:
`convert :: (Fractional a, Convertible u v) => Quantity a u -> Quantity a v` multiplies by
a statically-derived rational ratio ([`Convert.hs`][convert]).

## Expressiveness edges

The edges are unusually well documented — by the paper's own future-work list (§6.1) and
by the negative test suite. Each absence below is a finding.

- **Fractional powers: absent.** `sqrt'` demands the argument's units be a perfect square
  (`w ~~ u ^: 2`), with the comment "Fractional units are not currently supported"
  ([`Internal.hs`][internal]). The paper concedes the use case: "Fractional units are
  sometimes useful, such as `√Hz` … which arises when quantifying electronic noise levels."
  The exponent group is `ℤⁿ`, never `ℚⁿ` — a footnote in the paper (§5.1) notes that the
  then-upcoming F# 4.0 would support fractional units, leaving this system behind on that
  axis; see [F# units of measure][fsharp].
- **Affine quantities (temperature): absent.** `conversionBase` is a _ratio_ — conversion
  is multiplication only, so `°C ↔ K` is inexpressible. The paper points at the
  [torsor-flavoured][torsor] fix without implementing it: "Multiple origins need to be
  considered to handle units of temperature, since 0C ≈ 273K. It may be possible to handle
  these by indexing quantities by an abelian group of translations as well as units
  (Atkey et al. 2013)."
- **Logarithmic units (dB, dBm): absent.** Paper §6.1: "Logarithmic units such as dBm
  require arithmetic operations like ⊕ to be given different types." Nothing in the
  library models them.
- **Angles: dimensionless with explicit conversion.** `rad` and `sr` are declared as
  convertible units with ratio 1 (`[u| rad = 1 1 |]`, [`Defs.hs`][defs]), so `rad` is
  distinct from `One` in types but erasable via `convert` — the test suite converts
  `42 rad/s` to `42 s^-1` ([`Tests.hs`][tests]). Angle safety is thus opt-in and shallow.
- **Kind-vs-dimension (torque vs energy, Hz vs Bq): absent.** With units-only indexing and
  definitional expansion, `J = N m` and a would-be torque unit `N m` are _the same type_;
  `Hz = s^-1` and `Bq` (were it declared as `s^-1`) would be interchangeable. There is no
  quantity-kind layer at all — the axis on which [`mp-units`][mp-units] and [`au`][au]
  differentiate themselves.
- **Exponent polymorphism: partial.** `u ^: i` with a variable `i` participates in
  solving as an opaque atom (`pow :: Quantity a (u *: (v ^: i)) -> Quantity a ((v ^: i) *: u)`
  typechecks), but arithmetic in the exponent (`m^(x+y) ~ m^x * m^y`) is documented as
  unsolvable ([`ErrorTests.hs`][errortests]).
- **`Num` interop: restricted by design.** `Quantity a u` has `Num`/`Fractional`/…
  instances only at `u ~ One` ([`Internal.hs`][internal]), so literals and `+`/`*` work on
  dimensionless quantities only; everything else goes through `+:`/`*:`. Pattern-matching
  on quantity literals is limited to `Integer`/`Rational` representations
  ([`TH.hs`][th]).

## Zero-cost story

The claim is the standard newtype-erasure argument, stated in the paper (§2.1) as a design
requirement rather than measured:

> _"…which makes `Quantity a u` use the same runtime representation as the underlying
> (typically numeric) type `a`, but tagged with a phantom type parameter … This means that
> using `Quantity a u` has no runtime overhead compared to using plain `a`, but it can have
> additional safety guarantees."_

The repr evidence in the clone ([`Internal.hs`][internal]):

- `newtype Quantity a (u :: Unit) = MkQuantity a` — no wrapper at runtime by GHC's newtype
  semantics; every arithmetic primitive (`+:`, `*:`, `-:`, `/:`, `recip'`, `sqrt'`, …)
  is a one-liner over the underlying operation marked `{-# INLINE #-}`.
- `deriving instance Storable a => Storable (Quantity a u)` — commented "To enable
  marshalling into FFI code": a `Quantity Double u` can be poked into a C buffer
  directly, which is only possible because the representation _is_ `Double`.
- `type role Quantity representational nominal` — the **nominal** role on the unit index
  closes the `Data.Coerce` back door: `coerce` cannot re-unit a quantity even though the
  runtime representation is identical. Safety and erasure coexist by role discipline.

Two costs are _not_ zero, and the source is candid about both: explicit `convert` is a
runtime multiplication by a `Rational`-derived ratio (built recursively over the unit's
syntactic form via singletons, `{-# INLINABLE #-}` but still arithmetic —
[`Convert.hs`][convert]); and `Show`/`Read` reconstruct concrete unit syntax at runtime
through the `KnownUnit`/`SUnit` singleton machinery ([`Singleton.hs`][singleton]). The
type-checking itself — the plugin — is purely compile-time. No benchmark suite exists in
the repository; there are no published numbers behind the zero-overhead claim.

## Diagnostics

The units mismatch is expressed in the _user's_ unit vocabulary — the headline advantage
over normal-form encodings. The repository pins the expected messages in a dedicated
error-test module, compiled with `-fdefer-type-errors` so the type errors become runtime
exceptions the suite can string-match ([`ErrorTests.hs`][errortests]):

```haskell
-- uom-plugin: uom-plugin/test-suite-units/ErrorTests.hs @ 0b87268
mismatch2 :: Quantity Int [u| s |]
mismatch2 = [u| 2 m |] +: ([u| 2 s |] :: Quantity Int [u| s |])

mismatch2_errors :: [[String]]
mismatch2_errors = couldn'tMatchErrors "Base \"s\"" "Base \"m\""
```

The expected error text (modulo GHC's 9.x punctuation change, which the test accepts in
four variants):

```text
Couldn't match type: Base "s"
              with: Base "m"
```

**Provenance:** repo tests — `uom-plugin/test-suite-units/ErrorTests.hs` and `Tests.hs`
@ `0b87268`; the suite's `tested-with` compilers are GHC 9.0.2, 9.2.4 and 9.4.2 per
[`uom-plugin.cabal`][cabal]. Not reproduced locally: building a GHC-9.4-era typechecker
plugin was out of budget for this survey, so the error text above is quoted from the
project's own expected-error definitions rather than a fresh compile.

The paper (§2.1.2) shows the fully-rendered form of the same class of error, from the
GHC 7.10 era:

```text
Couldn't match type ‘Base "m"’ with ‘Base "kg"’
Expected type: Quantity Double (Base "m")
  Actual type: Quantity Double (Base "kg")
In the first argument of ‘(+:)’, namely ‘mass’
In the expression: mass +: distance
```

Compare `[F Mass One, F Length (P Zero)] ~ []` — the `units`-package error for the same
mistake, quoted in §2.2.1 — to see what the plugin buys. Two caveats, both documented:
quasiquote syntax never appears in errors (paper §5.1: TH syntax "will not be used in
output (such as error messages or inferred types)"), so users read `Base "m" /: Base "s"`
rather than `[u| m/s |]`; and an _unsolved-but-not-contradictory_ constraint (e.g. a
missing unit declaration) surfaces as a mysterious
`KnownUnit (Unpack (MkUnit "m"))`-style residual constraint rather than a domain error
([`Tutorial.hs`][tutorial]).

## Ergonomics & compile-time cost

**Declaration overhead is low** — among the lowest in the catalog: one pragma
(`{-# OPTIONS_GHC -fplugin Data.UnitsOfMeasure.Plugin #-}`) plus `DataKinds`,
`QuasiQuotes`, `TypeOperators` per module (`TypeFamilies` + `UndecidableInstances` where
units are declared), then units are one-liners. Forgetting the pragma is the classic
footgun: the module still compiles against the library but every unit equation becomes an
unsolved constraint ([`Tutorial.hs`][tutorial] warns about exactly this).

**Inferred types are readable but desugared** — `Quantity a (Base "m" /: Base "s")`, not
`[u| m/s |]`; the paper (§5.1) notes a type may even be displayed as an unsimplified
`Base "s" *: (Base "m" /: Base "s")` because plugins cannot hook type _presentation_.

**Compile-time cost is unquantified but visibly nonzero.** No benchmarks exist, but the
pinned tree records friction: the solver loop can hit GHC's constraint-solver iteration
cap — "`solveSimpleWanteds: too many iterations (limit = 4)`" appears twice as a comment
explaining disabled tests and a rejected `PartialTypeSignatures` refactor
([`Tests.hs`][tests]), and on GHC 8.0.2 the same limit broke `unQuantity [u| 3 m s^-1 |]`
outright. A long comment in [`Plugin.hs`][plugin] documents Core Lint
`Trans coercion mis-match` warnings on GHC 9.2 that "seem to work on 9.4" — plugin-GHC
version coupling in the raw.

**Maintenance status is the sharpest finding.** The pinned HEAD `0b87268` (2022-10-09) _is_
the `0.4.0.0` release; there are no commits after it. Version support is a window, not a
floor ([`README.md`][readme]):

> "The latest version of the library is tested with GHC 9.0 to 9.4. Older versions of
> `uom-plugin` (0.3 and earlier) work with the GHC 7.10, 8.0 and 8.2 series. There are no
> versions supporting GHC 8.4 to 8.10 (#43)."

The 0.3 → 0.4 gap was four years ([#43][i43]; the port ultimately required the
[`ghc-tcplugin-api`][tcplugin-api] compatibility layer, `>= 0.8.3 && < 0.9` in the cabal
file), and as of this survey's acquisition date (2026-07-03) no release supports any GHC
newer than 9.4 — a plugin is coupled to compiler internals, and this one has been left
behind by them twice. That fragility is intrinsic to the mechanism, and it is the
strongest practical argument for either native support ([F#][fsharp]) or plain
type-families encodings ([`dimensional`][dimensional]) despite their inference deficits.

---

## Strengths

- **Real abelian-group inference in Haskell.** Commutativity, associativity, inverses and
  torsion-freeness are solved, not normalised around; unit-polymorphic functions get
  principal-looking most-general types (`f :: Num a => Quantity a v -> Quantity a u -> Quantity a (u *: v)`)
  with no annotations.
- **Errors in the user's vocabulary** — `Couldn't match type: Base "s" with: Base "m"` —
  instead of encoded normal forms; contradiction detection (`kg ~ m`) is immediate.
- **Zero-runtime-cost representation** with the coercion back door closed by a nominal
  role, plus `Storable` for FFI.
- **Formal backing.** The solver is the algorithm of a peer-reviewed paper with soundness
  proved and the principality gap honestly characterised (Theorem 2 + conjecture) — rare
  candour in this catalog.
- **Negative tests as documentation.** `ErrorTests.hs` pins what must _not_ typecheck and
  what the solver is known not to solve — the survey's best example of documenting
  completeness limits.
- **Tiny core.** The entire type-level surface is ~7 symbols; the plugin is under 800
  lines across four modules (`Plugin.hs` plus `Plugin/{Convert,NormalForm,Unify}.hs`).

## Weaknesses

- **Abandoned at GHC 9.4.** HEAD and latest release date to October 2022; two historical
  support gaps (8.4–8.10 never supported; nothing after 9.4). Using it today means using
  an old compiler.
- **Soundness by assertion.** Evidence is `PluginProv` universal coercions ("bogus
  evidence", per the source); a solver bug is a type-soundness bug, as the README warns.
  Issue [#22][i22] (a unit-safety bug on GHC 8.0) shows the risk was real.
- **Units only — no dimensions, no quantity kinds.** Torque ≡ energy, `Hz` ≡ `Bq`;
  no affine temperatures, no logarithmic units, no fractional exponents.
- **Global, unscoped unit names.** `Symbol`-keyed `MkUnit` instances cannot be namespaced
  or versioned per system of units.
- **TH-dependent surface.** Safe literal construction fundamentally requires the
  quasiquoter (paper §6.1 calls this "slightly unsatisfying"); quasiquote syntax never
  round-trips into diagnostics or inferred types.
- **Solver/compiler coupling artifacts.** Iteration-limit blowups, GHC-version-dependent
  error formats (four accepted variants per mismatch in the test suite), Core Lint noise
  on some GHC versions, and disabled givens-simplification.

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                                      | Trade-off                                                                                                 |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Units as equation-less type families in an opaque kind `Unit`         | Keeps the AG theory out of GHC's built-in equality; non-injective symbols can't be mis-unified | All reasoning must happen in the plugin; without `-fplugin` every unit equation is simply stuck           |
| Domain-specific AG unifier plugged into OutsideIn(X)                  | Decidable theory with most general unifiers → real inference and unit polymorphism             | Plugin is coupled to compiler internals; abandoned when GHC internals moved on                            |
| Evidence by fiat (`PluginProv` coercions)                             | Shipping the solver without mechanising group-law proofs in Core                               | Type soundness rests entirely on solver correctness; Core Lint can't fully check it                       |
| Index by **units only**, no dimension layer (following F#)            | Simplicity; one group, one solver                                                              | Torque vs energy indistinguishable; "any unit of this dimension" APIs need the `Convertible` workaround   |
| Integer exponents (`ℤⁿ`), `Nat`-powered surface `^:`                  | Free abelian group = torsion-free; unitary unification                                         | No `√Hz`; negative powers only via `/:`; exponent arithmetic (`x + y`) unsolvable                         |
| `newtype` + nominal role on the unit index                            | True zero-cost representation with the `coerce` loophole closed                                | `Num` instances only at `One`; dedicated operators (`+:`, `*:`) instead of overloading                    |
| TH quasiquoter for literals, types, patterns and declarations         | Safe construction without exposing `MkQuantity`; pleasant concrete syntax                      | TH dependency; syntax invisible in errors/inferred types; pattern splices limited to `Integer`/`Rational` |
| Canonical-base-unit conversion scheme instead of a dimension registry | Automatic ratio derivation between any two units sharing a canonical form                      | Multiplicative conversions only — affine (temperature) and logarithmic (dB) scales are out of reach       |
| Deferred-equality family `~~` on arithmetic result types              | Delays unification until the plugin can solve it, improving inferred types                     | Self-described "hack"; needs special-casing in the solver (`IrredPred` handling, `mkFunnyEqEvidence`)     |

## Sources

- [adamgundry/uom-plugin — GitHub repository][repo] (pinned locally at `0b87268`, 2022-10-09)
- [`README.md` — experimental-status warning, GHC support window][readme]
- [`src/Data/UnitsOfMeasure/Internal.hs` — `Unit` kind, `Quantity`, roles, `~~`, `Unpack`/`Pack`][internal]
- [`src/Data/UnitsOfMeasure/Plugin.hs` — solver/rewriter registration, `evMagic`, givens TODO, Core Lint note][plugin]
- [`src/Data/UnitsOfMeasure/Plugin/NormalForm.hs` — `Atom`, `NormUnit` signed multiset][normalform]
- [`src/Data/UnitsOfMeasure/Plugin/Unify.hs` — `unifyOne`, `SimplifyState`, Win/Draw/Lose][unify]
- [`src/Data/UnitsOfMeasure/TH.hs` — the `u` quasiquoter, unit-declaration TH][th]
- [`src/Data/UnitsOfMeasure/Defs.hs` — SI base/derived/convertible unit declarations][defs]
- [`src/Data/UnitsOfMeasure/Convert.hs` — canonical base units, `convert`/`ratio`][convert]
- [`doc/Data/UnitsOfMeasure/Tutorial.hs` — doctested tutorial incl. inference examples][tutorial]
- [`test-suite-units/Tests.hs` — positive suite: group laws, givens, generalisation edges][tests]
- [`test-suite-units/ErrorTests.hs` — expected type errors, documented incompleteness][errortests]
- [`uom-plugin.cabal` — license, `tested-with`, `ghc-tcplugin-api` bound][cabal] · [`CHANGELOG.md`][changelog] · [`haskell-ci.yml` — `-dcore-lint` CI][ci]
- Adam Gundry, _"A Typechecker Plugin for Units of Measure: Domain-Specific Constraint Solving in GHC Haskell"_, Haskell Symposium 2015 — [author page][paper-page] (archived locally for this survey as `gundry-2015-typechecker-plugin-uom-haskell.pdf`)
- [GHC issue tracker: #43 (GHC 8.4–8.10 gap)][i43] · [#66 (haddock needs GHC 9.4)][i66] · [#22 (unit-safety bug on GHC 8.0)][i22]
- [`ghc-tcplugin-api` — the GHC-version compatibility layer the 0.4 port targets][tcplugin-api]
- [GHC User's Guide — typechecker plugins][ghc-plugins]
- Vytiniotis, Peyton Jones, Schrijvers, Sulzmann, _"OutsideIn(X): Modular type inference with local assumptions"_, JFP 21(4–5), 2011 — [DOI][outsidein-doi]
- Related deep-dives in this survey: [Kennedy's type system][kennedy] · [free abelian groups][fag] · [type-system mechanisms][mechanisms] · [torsors & affine quantities][torsor] · [F# units of measure][fsharp] · [`dimensional` and the type-families encodings][dimensional] · [concepts][concepts] · [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone (adamgundry/uom-plugin @ 0b87268) -->

[repo]: https://github.com/adamgundry/uom-plugin
[readme]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/README.md
[internal]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/uom-plugin/src/Data/UnitsOfMeasure/Internal.hs
[plugin]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/uom-plugin/src/Data/UnitsOfMeasure/Plugin.hs
[normalform]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/uom-plugin/src/Data/UnitsOfMeasure/Plugin/NormalForm.hs
[unify]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/uom-plugin/src/Data/UnitsOfMeasure/Plugin/Unify.hs
[th]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/uom-plugin/src/Data/UnitsOfMeasure/TH.hs
[defs]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/uom-plugin/src/Data/UnitsOfMeasure/Defs.hs
[convert]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/uom-plugin/src/Data/UnitsOfMeasure/Convert.hs
[singleton]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/uom-plugin/src/Data/UnitsOfMeasure/Singleton.hs
[tutorial]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/uom-plugin/doc/Data/UnitsOfMeasure/Tutorial.hs
[tests]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/uom-plugin/test-suite-units/Tests.hs
[errortests]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/uom-plugin/test-suite-units/ErrorTests.hs
[cabal]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/uom-plugin/uom-plugin.cabal
[changelog]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/uom-plugin/CHANGELOG.md
[ci]: https://github.com/adamgundry/uom-plugin/blob/0b87268c9ec5251aeebec87bb63b2d797d5722fe/.github/workflows/haskell-ci.yml
[i22]: https://github.com/adamgundry/uom-plugin/issues/22
[i43]: https://github.com/adamgundry/uom-plugin/issues/43
[i66]: https://github.com/adamgundry/uom-plugin/issues/66

<!-- Paper & external documentation -->

[paper-page]: https://adam.gundry.co.uk/pub/typechecker-plugins/
[hackage]: https://hackage.haskell.org/package/uom-plugin
[tcplugin-api]: https://hackage.haskell.org/package/ghc-tcplugin-api
[ghc-plugins]: https://downloads.haskell.org/ghc/9.4.2/docs/users_guide/extending_ghc.html#typechecker-plugins
[outsidein-doi]: https://doi.org/10.1017/S0956796811000098

<!-- Survey cross-links -->

[kennedy]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md
[fsharp]: ./fsharp-uom.md
[dimensional]: ./haskell-dimensional.md
[rust-uom]: ./rust-uom.md
[mp-units]: ./cpp-mp-units.md
[au]: ./cpp-au.md
[boost-units]: ./cpp-boost-units.md
[pint]: ./python-pint.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
