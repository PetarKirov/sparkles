# Type-System Mechanisms for Dimensional Types

The bridge from the mathematics to the machinery. Every formalization in this catalog agrees
that dimensions form a [free abelian group][fag] — `ℤⁿ` (or `ℚⁿ`) under exponent addition —
and every checked-units system is, at bottom, an attempt to make a type checker _compute in
that group_. This page compares the six mechanism families that attempt it: bare
**phantom/indexed types** with no index arithmetic; **type-level integer encodings** whose
arithmetic is evaluated by trait resolution or template instantiation (`typenum`, Peano `Z`,
C++ non-type template parameters); **closed type families** that normalize unit syntax
([`dimensional`][dimensional], [`units`][units-pkg]); a **compiler-native abelian-group
unifier** ([F#][fsharp], from [Kennedy's line][kennedy]); a **plugin abelian-group unifier**
bolted onto an existing solver ([`uom-plugin`][uom-plugin], [Gundry 2015][gundry]); and
**dependent types** where dimensions are ordinary mathematical objects and homogeneity is a
proposition ([Lean][lean], [Bobbin et al. 2025][bobbin]). Two theorems organize the whole
comparison: AG-unification is **decidable and unitary** (most general unifiers exist — the
enabling theorem for inference), and well-typed programs are **invariant under scaling** in a
semantics that _erases_ units entirely (Kennedy's parametricity theorem — the formal content
of "zero runtime cost").

> [!NOTE]
> This page is the theory→systems bridge: it compares _mechanisms_, cites the mechanism-level
> evidence in the pinned system repos, and hands each system off to its own deep-dive
> ([`fsharp-uom.md`][fsharp], [`haskell-uom-plugin.md`][uom-plugin],
> [`haskell-dimensional.md`][dimensional], [`rust-uom.md`][rust-uom],
> [`rust-dimensioned.md`][rust-dimensioned], [`cpp-mp-units.md`][mp-units],
> [`lean-mathlib-units.md`][lean], …) rather than re-surveying them. The Kennedy line itself —
> the type system, the unifier, the semantics — has its own page,
> [`kennedy-types.md`][kennedy]; the group theory is [`free-abelian-group.md`][fag]. Dynamic
> (run-time-checked) systems such as [Pint][pint], [Unitful.jl][unitful] and
> [Wolfram/MATLAB][wolfram] are out of scope here precisely because they do _not_ erase —
> the erasure analysis below is what separates the two halves of the catalog.

---

## At a glance

| Dimension             | Type-system mechanisms for dimensional types                                                                                                                                                                                               |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Question answered     | How the free abelian group `ℤⁿ` of dimension exponents becomes _checkable type structure_ — and what each host type system must supply (or fake) to compute in it                                                                          |
| Mechanism families    | Phantom indices (no algebra) · type-level integer vectors (`typenum`, Peano `Z`, C++ NTTPs) · closed type families (normalisation) · native AG unifier (F#) · plugin AG unifier (GHC) · dependent types (Lean)                             |
| Litmus test           | The generic squaring function `sqr : α → α²` — dimensional polymorphism forces the checker to do _group arithmetic on unknowns_, not just equality of ground indices                                                                       |
| Enabling theorem      | AG with nullary constants is **unitary** and AG-unification **decidable** ([Kennedy 2010][k10] §3.5) ⇒ principal types, full inference — the property F# builds in and `uom-plugin` retrofits                                              |
| Blocking fact         | Vanilla GHC's type equality is syntactic + terminating-rewrite-based, and associativity and commutativity "are hardly going to" form a terminating rewrite system ([Gundry 2015][gundry] §2.2) — hence normal-form workarounds or a plugin |
| Erasure               | Checking is compile-time only in every static mechanism: F# spec — _"Measures play no role at runtime; in fact, they are erased"_; `newtype` (GHC), `PhantomData` + `#[repr(transparent)]` (Rust), empty tag types (C++)                   |
| "Zero-cost", formally | [Kennedy POPL '97][k97]: the denotational semantics **ignores units** (`⟦num µ⟧ = Q⊥`); unit-correctness is then a _relational_ property — invariance under the scaling action — recovered by parametricity, not by run-time state         |
| Kind (VIM sense)      | Absent from the Kennedy/F# lineage; reintroduced by libraries: `uom`'s `type Kind` associated type, mp-units' `quantity_spec` hierarchy — a tree refinement _on top of_ the group                                                          |
| Exemplar system pages | [F#][fsharp] · [`uom-plugin`][uom-plugin] · [`dimensional`][dimensional] · [`uom` (Rust)][rust-uom] · [`dimensioned`][rust-dimensioned] · [mp-units][mp-units] · [Boost.Units][boost] · [Au][au] · [GNAT Ada][gnat] · [Lean][lean]         |

---

## Primary sources

Read in full or in targeted extractions from the local artifacts under
`$REPOS/papers/units-of-measure/` (`$REPOS` = `/home/petar/code/repos`); quotes transcribed
from `pdftotext -layout` output of those PDFs and from the pinned repo files.

- **Andrew Kennedy, "Types for Units-of-Measure: Theory and Practice"**, CEFP '09 lecture
  notes (revised), LNCS 6299, Springer, 2010, pp. 268–305 — **inspected in full**
  ([`kennedy-2010-types-units-of-measure-cefp.pdf`][k10]). The mechanism-level reference:
  the unit grammar and equational theory `=U` (§3.1–3.2), normal forms and the `exp`
  decision procedure (§3.3), the AG-unification algorithm `Unify`/`UnifyOne` (Fig. 5) with
  soundness/completeness (Theorem 1), type schemes and their non-trivial equivalence (§3.9),
  and the semantics sections (§4) restating the POPL '97 erasure/parametricity story.
- **Andrew Kennedy, "Relational Parametricity and Units of Measure"**, _POPL '97_,
  pp. 442–455 — **inspected** ([`kennedy-1997-relational-parametricity-units-popl.pdf`][k97]).
  The erasure semantics (`⟦num µ⟧ = Q⊥`, `⟦∀u.τ⟧ = ⟦τ⟧`, Fig. 3), scaling environments and
  the type-indexed logical relation (Fig. 4), the parametricity theorem (Theorem 1), the
  completeness characterisation of scaling environments as subgroup homomorphisms into `ℚ⁺`
  (Theorem 2, Fig. 5), and the applications (free theorems, uninhabited `sqrt`, the Pi
  theorem as a type isomorphism).
- **Adam Gundry, "A Typechecker Plugin for Units of Measure: Domain-Specific Constraint
  Solving in GHC Haskell"**, _Haskell Symposium 2015_, pp. 11–22 — **inspected in full**
  ([`gundry-2015-typechecker-plugin-uom-haskell.pdf`][gundry]). The "why vanilla GHC cannot"
  analysis (§1.1, §2.2), the closed-type-family workaround and its failure modes (§2.2.1),
  the `OutsideIn(X)` plugin interface (§3), the rewrite-system AG solver (Fig. 7), soundness
  (Theorem 1) and the _weakened_ generality result (Theorem 2) with the `TORSION-FREE` rule.
- **The F# Language Specification 4.1**, §9 "Units Of Measure" — **inspected (§9)**
  ([`fsharp-spec-4.1.pdf`][fsharp-spec]). The normative erasure statements (§9, §9.6).
- **Maxwell P. Bobbin, Colin Jones, John Velkey & Tyler R. Josephson, "Formalizing
  Dimensional Analysis Using the Lean Theorem Prover"**, arXiv:2509.13142, 2025 —
  **inspected (targeted sections)**
  ([`bobbin-2025-formalizing-dimensional-analysis-lean-arxiv.pdf`][bobbin]), together with
  the companion repo [`LeanDimensionalAnalysis`][lean-repo] (pinned `de263ee`):
  `DimensionalAnalysis/Basic.lean` — `dimension B E := B → E`, the `CommGroup` instance,
  the `Classical.epsilon` addition, the Buckingham-Pi matrix development.
- **Robert Atkey, "From Parametricity to Conservation Laws, via Noether's Theorem"**,
  _POPL '14_ — **abstract/introduction only inspected**
  ([`atkey-2014-parametricity-conservation-laws-popl.pdf`][atkey]); cited here solely for
  the frontier direction (invariance-indexed types beyond units). The earlier
  Atkey–Johann–Kennedy POPL '13 "algebraically indexed types" paper is **not held locally**
  and is cited only as restated in [Gundry 2015][gundry] §6.1 (translation groups for
  temperature origins).
- **Mechanism evidence in pinned repos** (SHAs listed per repo under
  [Mechanization](#mechanization) below) —
  **inspected files**: `dotnet/fsharp` `src/Compiler/TypedTree/TypedTree.fs` (`type Measure`,
  L4696) and `src/Compiler/Checking/ConstraintSolver.fs` (`UnifyMeasures` L801,
  `SimplifyMeasure`/`SimplifyMeasuresInType`); `rust/uom` `src/system.rs` (the `system!`
  macro: `Dimension` trait, `Quantity` struct, `typenum` exponent arithmetic);
  `rust/dimensioned` `src/make_units.rs` + `src/traits.rs`; `cpp/mp-units`
  `src/core/include/mp-units/framework/{dimension.h,symbolic_expression.h,quantity_spec.h}`;
  `haskell/dimensional` `src/Numeric/Units/Dimensional/Dimensions/TypeLevel.hs`;
  `haskell/units` `units/Data/Metrology/{Z.hs,Factor.hs,Qu.hs}`; `haskell/uom-plugin`
  `uom-plugin/src/Data/UnitsOfMeasure/Internal.hs`.

---

## Formal core

The mechanisms all target the same object: the equational theory of units. Fixing base units
`b ∈ UBase` and unit variables `α ∈ UVars`, [Kennedy 2010][k10] §3.1–3.2 defines

```text
u, v, w ::= b | α | 1 | u · v | u⁻¹

=U  =  the smallest congruence containing the abelian-group axioms:
       (u · v) · w =U u · (v · w)      u · v =U v · u
       u · 1 =U u                      u · u⁻¹ =U 1
```

Every unit expression has a **normal form** `α₁^x₁ · … · αₘ^xₘ · b₁^y₁ · … · bₙ^yₙ` with
non-zero integer exponents, computed by the exponent-counting map
`exp(u) : (UBase ∪ UVars) → ℤ`; then `u =U v` iff `exp(u) = exp(v)` (Kennedy 2010 §3.3,
Exercise 6). Deciding _equality_ is therefore trivial — the entire mechanism comparison turns
on deciding **solvability**: given `u =U v` containing variables, find a substitution `S`
with `S(u) =U S(v)`. This is _equational unification_ in the theory AG, and its status is
unusually good:

> _"We are fortunate that the theory of Abelian groups (AG) with nullary constants is
> unitary, the technical term for “possesses most general unifiers”. Rather few equational
> theories have this property; one other is the theory of Boolean Rings. Moreover,
> AG-unification is decidable, and the algorithm is straightforward to implement."_
> — [Kennedy 2010][k10] §3.5

### Theorem 1 — AG-unification is decidable with most general unifiers

**Statement** (Kennedy 2010, Theorem 1). `Unify(u, v)` either returns a substitution `S`
with `S(u) =U S(v)` (**soundness**), or fails; and if any unifier exists, `Unify` succeeds
and every unifier factors through its result (**completeness / most-generality**).

**Proof sketch** (following Fig. 5 of [Kennedy 2010][k10]; full proof in Kennedy's thesis,
covered on the [Kennedy page][kennedy]). First reduce to matching against `1`:
`u =U v` has the same solution set as `u · v⁻¹ =U 1`. Now run `UnifyOne` on the normal form
`α₁^x₁ · … · αₘ^xₘ · b₁^y₁ · … · bₙ^yₙ` with `|x₁|` minimal among variable exponents:

```text
m = 0, n = 0:  the equation is 1 =U 1              → identity substitution
m = 0, n ≠ 0:  ground and non-trivial              → fail (free AG is consistent:
                                                      a non-empty product of base
                                                      units is never 1)
m = 1:         α₁^x₁ = ground. Solvable iff x₁ | yᵢ for all i (the group is
               torsion-free: α^k =U c has a solution only if k divides every
               exponent of c); if so  α₁ ↦ b₁^(−y₁/x₁) · … · bₙ^(−yₙ/x₁)
otherwise:     apply the Euclid/Gauss step
               S₁ = { α₁ ↦ α₁ · α₂^(−⌊x₂/x₁⌋) · … · bₙ^(−⌊yₙ/x₁⌋) }
               and recurse on S₁(u).
```

The step `S₁` is a solution-set-preserving change of variables (it is invertible modulo
`=U` — a unimodular row operation on the exponent matrix), and after it every exponent is
replaced by its remainder `mod x₁`, so the minimal `|exponent|` strictly decreases —
termination. Completeness: each step being an invertible change of variables, any unifier of
the input is the image of a unifier of the reduct; at the base cases the unifier is forced
(or provably absent). In lattice language (see [free-abelian-group][fag]): unification is
solving a linear system over `ℤ`, and `UnifyOne` is Hermite-normal-form reduction performed
one pivot at a time. ∎

This theorem is the load-bearing wall of the whole bridge. A checker that _has_ it (F#'s
built-in solver, `uom-plugin`) gets full Hindley–Milner-style inference with principal types;
a checker that lacks it (closed type families, template instantiation, trait resolution)
can only _evaluate_ the group operation on sufficiently-known arguments, never _solve_ it —
with the concrete failure modes catalogued under [Structural anatomy](#structural-anatomy).

### Theorem 2 — erasure + parametricity: what "zero runtime cost" means

The second theorem explains why all of this may safely happen _only_ at compile time.
[Kennedy POPL '97][k97] gives the language `Λᵤ` a denotational semantics in which the unit
structure is simply discarded — `⟦bool⟧ = B⊥`, `⟦num µ⟧ = Q⊥` for _every_ `µ`,
`⟦τ₁ → τ₂⟧ = ⟦τ₁⟧ → ⟦τ₂⟧`, and crucially `⟦∀u.τ⟧ = ⟦τ⟧` (Fig. 3: unit abstraction and
application are semantically the identity):

> _"This underlying semantics ignores the unit annotations in types; instead, units are
> accounted for by a binary relation over the underlying semantics defined in Section 4."_
> — [Kennedy, POPL '97][k97] §1

That is the **dimension-erasure semantics**: a program means exactly what its unit-stripped
version means. On its own this would make the type discipline vacuous — Kennedy is explicit
that ordinary type-soundness arguments have nothing to grip:

> _"If run-time values do not carry their units, as is the case with F# and other systems,
> then syntactic type soundness tells us precisely nothing."_
> — [Kennedy 2010][k10] §4.1

The content is recovered _relationally_. A **scaling environment** `ψ` maps unit expressions
to binary relations on `ℚ`, respecting `=U` and sending `1` to the identity. It induces a
type-indexed logical relation (POPL '97 Fig. 4):

```text
Rψ_bool      = identity (lifted over ⊥)
Rψ_(num µ)   = ψ(µ)⊥
Rψ_(τ₁→τ₂)   = related arguments ↦ related results
Rψ_(∀u.τ)    = related at every extension of ψ on u
```

**Statement** (POPL '97 Theorems 1 + 2). (_Parametricity_) If `V; Γ ⊢ e : τ` then `e` is
related to itself: for every admissible `ψ` and related environments `(ρ, ρ′)`,
`(⟦e⟧ρ, ⟦e⟧ρ′) ∈ Rψ_τ`. (_Completeness of the scaling model_) The scaling environments that
preserve the standard arithmetic primitives are exactly the `ψ_{G,h}` built from a subgroup
`G` of the unit group and a group homomorphism `h : G → ℚ⁺`, acting by
`ψ(µ) = { (r, h(µ)·r) }` — i.e. admissible "changes of units" are precisely positive scale
factors composed multiplicatively along the group structure.

**Proof sketch.** Parametricity is induction on the typing derivation: the `(abs)`/`(app)`
cases are the standard logical-relations argument; the `(eq)` rule (types equal up to `=U`)
is sound because `ψ` respects `=U`; `(rec)` needs the relations to be strict and chain-complete
(Lemma 1); `∀`-introduction/elimination use the extension and substitution lemmas
(`Rψ∘S_τ = Rψ_{Sτ}`, Lemma 2). Completeness: polymorphic zero forces `(0,0)` into every
relation; closure of the primitives (`+`, `*`, `/`, `<`) then forces each `ψ(µ)` to be
either the graph of multiplication by a positive rational or the degenerate `{(0,0)}`, and
multiplicativity across `·` and `⁻¹` makes `µ ↦ h(µ)` a homomorphism (Appendix A of POPL
'97). ∎

**Reading of the theorem.** "Zero runtime cost" is not a compiler-flag promise but a
semantic equation plus a guarantee that it loses nothing: (i) _erasure_ — the compiled
program's meaning is the unit-free meaning, so there is literally nothing to pay for at run
time; (ii) _parametricity_ — despite (i), a well-typed program provably commutes with every
change-of-units homomorphism, which Kennedy argues is the actual definition of unit
correctness ("the real essence of unit correctness: the ability to change the unit system
without affecting behaviour", [Kennedy 2010][k10] §4.1). Every static mechanism below
implements (i) by construction — GHC `newtype` (`newtype Quantity a (u :: Unit) = MkQuantity a`,
[`Internal.hs` L98][uom-plugin-repo]), Rust `#[repr(transparent)]` over a `PhantomData`-tagged
value ([`system.rs` L251–265][uom-repo]), F# by specification — and inherits a claim to (ii)
exactly to the extent that its typed interface matches Kennedy's. The F# specification states
erasure normatively:

> _"Measures play no role at runtime; in fact, they are erased."_
> — [The F# Language Specification 4.1][fsharp-spec], §9 (p. 175)

with the operational consequences spelled out in §9.6: casting, method resolution and
reflection all act on the erased types.

---

## Structural anatomy

The comparability-protocol questions, answered per mechanism. The table is the summary; the
subsections give the evidence.

| Mechanism                  | Exponent domain                                                      | Polymorphic `sqr`?                                                                      | Inference                                                                    | Erasure story                                           | Exemplar                                                                     |
| -------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Phantom index, no algebra  | none (opaque tags)                                                   | **No** — `Real<Meter>` has no `Meter²` to name                                          | trivial (syntactic equality only)                                            | tag type erased                                         | historical encodings ([Kennedy 2010][k10] §3)                                |
| Type-level integer vectors | `ℤ` per base (`typenum` `Z0`/`P1`/…; Peano `Z`; C++ `std::intmax_t`) | **Expressible**, with per-component arithmetic bounds; inverse (`sqrt`) partial         | none — checker _evaluates_, never solves; errors at instantiation/resolution | `PhantomData` + `#[repr(transparent)]`; empty `struct`s | [`uom`][rust-uom] · [`dimensioned`][rust-dimensioned] · [mp-units][mp-units] |
| Closed type families       | `ℤ` (unary `Z.hs`, `TypeInt`)                                        | **Expressible** (`d * d`) but stuck on variables; commutativity unprovable for unknowns | forward-only rewriting; normal-form constraints leak into signatures         | `newtype`                                               | [`dimensional`][dimensional] · [`units`][units-pkg]                          |
| Native AG unifier          | `ℚ` (`Measure.RationalPower` in the compiler)                        | **Yes, inferred**: `float<'u> → float<'u ^ 2>`                                          | full HM inference, principal types (Theorem 1)                               | erased by spec (§9.6)                                   | [F#][fsharp]                                                                 |
| Plugin AG unifier          | `ℤ` (torsion-free normal forms)                                      | **Yes, inferred** modulo plugin; generality weakened (fresh variables)                  | `OutsideIn(X)` + plugin rewriting (Fig. 7)                                   | `newtype Quantity`                                      | [`uom-plugin`][uom-plugin]                                                   |
| Dependent types            | any `CommRing E` — `ℤ`, `ℚ`, `ℝ` exponents                           | **Yes**: `dimension B E` is a value; `sqr` is a theorem-friendly function               | none needed — equality is a proposition, proved by `simp`/tactics            | `noncomputable` — proof artifacts never execute         | [Lean][lean] ([Bobbin 2025][bobbin])                                         |

### What structure is primary, and what are its objects and morphisms?

All six mechanisms take the **free abelian group of dimension/unit exponents** as the
primary mathematical structure; they differ in _where_ the group lives.

- **Phantom types**: the group does not live anywhere — only the _set_ of its generators
  does, as inert type tags. [Kennedy 2010][k10] §3 analyses exactly this encoding
  (`UProd<m, UInv<UProd<s, s>>>` for `m/s^2`) and locates the failure:

  > _"The crucial aspect of units-of-measure that is not captured by this encoding is
  > equations that hold between syntactically distinct units."_ — [Kennedy 2010][k10] §3

  `m·s` and `s·m` are distinct types; without the equational theory, even homogeneity
  checking is wrong (too strict), and no arithmetic on indices exists at all.

- **Type-level integer vectors**: the group is `ℤⁿ` in fixed coordinates — one type-level
  integer per base quantity. In [`uom`][rust-uom] the `system!` macro generates a
  `Dimension` trait with one associated `typenum::Integer` per base quantity
  ([`src/system.rs`][uom-repo] L126–141); multiplication of quantities adds exponents
  componentwise via trait-level arithmetic
  (`typenum::Sum<Dl::L, Dr::L>` bounds on the `Mul` impl, L465–476). In
  [`dimensioned`][rust-dimensioned] the coordinates are `typenum` integers in a type-level
  array (`pub type $Unitless = tarr![Z0, …]`, [`make_units.rs`][dimensioned-repo] L1034).
  In [mp-units][mp-units] the group element is a canonicalized _symbolic expression_ —
  `derived_dimension` inherits `expr_fractions`, `operator*` is `expr_multiply`, and
  exponents are compile-time rationals (`power<T, Num, Den>` carrying a
  `static constexpr detail::ratio _exponent_`, [`symbolic_expression.h`][mp-units-repo]
  L106–121) — so the group is `ℚⁿ` over an open-ended set of base dimensions rather than a
  fixed-width vector. Objects: index types; morphisms: the arithmetic primitives whose
  _types_ implement the group operation (`Mul`/`Div` impls, `consteval operator*`).
- **Closed type families**: the group is `ℤ⁷` (in [`dimensional`][dimensional]:
  `data Dimension = Dim TypeInt TypeInt TypeInt TypeInt TypeInt TypeInt TypeInt`,
  [`TypeLevel.hs`][dimensional-repo] L60) or an association list of factors (in
  [`units`][units-pkg]: `[Factor *]` with unary integers `data Z = Zero | S Z | P Z`,
  [`Z.hs`][units-pkg] L85), with the group operations as closed type families (`*`, `/`,
  `^`, `NRoot`; `Normalize`, `Reorder`, `@~`).
- **Native/plugin AG unifier**: the group is a first-class syntactic sort with its
  equational theory built into type _equality_. F#'s typed tree has a dedicated measure AST
  — `type Measure = Var | Const | Prod | Inv | One | RationalPower`
  ([`TypedTree.fs`][fsharp-repo] L4696) — and `uom-plugin` introduces an opaque kind `Unit`
  whose operators are empty type families precisely so GHC's syntactic rules cannot touch
  them ([Gundry][gundry] §2.1). Objects: measure expressions modulo `=U`; morphisms: the
  unifier's substitutions.
- **Dependent types**: the group is literally itself. `LeanDimensionalAnalysis` defines
  `def dimension (B : Type u) (E : Type v) [CommRing E] := B → E` — a dimension _is_ the
  exponent function — and proves `instance : CommGroup (dimension B E)`
  ([`Basic.lean`][lean-repo] L61, L234). No encoding gap exists; the cost is that nothing is
  inferred, everything is proved.

### What is a quantity, a unit, a dimension, a kind?

- **F#/Kennedy**: a _quantity_ is a value of `float<u>`; a _unit_ is a measure expression;
  a _dimension_ does not exist in the mechanism (the system indexes by units only —
  [POPL '97][k97] §2.3 discusses the choice); _kind_ in the VIM sense is absent. The only
  "kind" is the trivial type-vs-measure sort distinction (`[<Measure>]`), and [Kennedy
  2010][k10] §5 lists a richer kind system as an open extension. **Silence recorded**: the
  origin mechanism has no answer to torque-vs-energy.
- **`uom` (Rust)**: `Quantity<D, U, V>` separates _dimension_ `D` (typenum exponents),
  _base-unit system_ `U`, and storage `V`; a _unit_ is a conversion-coefficient type within
  a quantity module; and — uniquely in this family — _kind_ is explicit:

  > _"Kind of the quantity. Quantities of the same dimension but differing kinds are not
  > comparable."_ — `type Kind: ?Sized` doc comment, [`uom` `src/system.rs`][uom-repo]
  > (L138–141; the comment's "Kind" links to VIM 1.2)

  The kind is an extra associated type on `Dimension` — an opaque tag layered on the group,
  restoring exactly the distinction the group quotients away.

- **mp-units (C++)**: four separate notions — `dimension` (the group element), `unit`,
  `quantity`, and `quantity_spec`: a _hierarchy_ of named quantity kinds over the same
  dimension, with tree operations `get_kind_tree_root` / `clone_kind_of` and an ordering on
  specs ([`quantity_spec.h`][mp-units-repo]). This is the most structured kind mechanism in
  the catalog — a partially ordered refinement of each dimension, checked during conversions.
- **`dimensional`/`units` (Haskell)**: `dimensional` indexes `Quantity` by _dimension_
  (`ℤ⁷` vector) with units as term-level conversion data; `units` goes further and indexes
  by dimension _relative to a local coherent system of units_ (`Qu d lcsu n`), making
  "unit" a deliberately erased choice-of-representation ([Gundry][gundry] §5.2 discusses the
  contrast). Kind: absent as a mechanism in both.
- **Lean**: a dimension is a function `B → E`; a quantity is whatever structure the
  formalizer attaches a dimension to; units live in a separate development. Kind: absent —
  **silence recorded**, and notable, since a dependent theory could express it easily.

### How is dimensional homogeneity expressed?

In every static mechanism, homogeneity of a law is the _typability_ of its expression, and
the crux is what "the two sides have equal dimension" means to the checker:

- **F#**: the `(eq)` typing rule imports `=U` wholesale; addition at `float<'u> → float<'u> → float<'u>`
  forces unification of the two indices, and the error message speaks units ("The unit of
  measure 'm' does not match the unit of measure 'm/s ^ 2'", [Kennedy 2010][k10] §2.1).
- **`uom-plugin`**: `(⊕) :: Quantity a u → Quantity a u → Quantity a u` — the same type as
  F#, honest because the plugin makes GHC's `~` constraint _be_ `=U` on kind `Unit`.
- **Closed type families**: the honest type is unavailable, so [`units`][units-pkg] weakens
  the interface: `(|+|) :: (d1 @~ d2, Num n) ⇒ Qu d1 l n → Qu d2 l n → Qu d1 l n`, where
  `d1 @~ d2` is defined as `Normalize (d1 @- d2) ~ '[]` ([`Factor.hs`][units-pkg] L119–120)
  — equality _of normal forms_, a distinct and weaker relation than type equality, with
  normal-form debris in every error message ([Gundry][gundry] §2.2.1 shows
  `Couldn't match type '[F Mass One, F Length (P Zero)]' with '[]'`).
- **Rust/C++ integer vectors**: homogeneity is plain type equality of fully-evaluated
  indices — `Add` is implemented only for two `Quantity` values sharing the same `D`
  ([`system.rs`][uom-repo]), and mp-units' `operator==` on dimensions is `is_same_v` after
  canonicalization ([`dimension.h`][mp-units-repo] L82–85). Works perfectly on ground
  dimensions; on _unknown_ dimensions there is nothing to unify, only bounds to state.
- **Lean**: homogeneity is a proposition `dim lhs = dim rhs` proved (or supplied as a
  hypothesis) by the author; the Buckingham-Pi development then manipulates whole systems of
  such propositions as an exponent matrix ([`Basic.lean`][lean-repo] L259 ff.; see
  [Buckingham Π][pi]).

### What acts as change of units, and what is invariant?

The Kennedy semantics answers once for the whole family: a change of units is a scaling
environment — by POPL '97 Theorem 2, a group homomorphism `h : G → ℚ⁺` acting on values of
type `num µ` as multiplication by `h(µ)` — and the invariant is _all observable behaviour of
well-typed programs_ (Theorem 1). It is a **relational** notion: nothing in a single run
represents "the current units"; the theorem compares two runs of the same erased program.
Mechanisms that store a normalization choice make the same move concretely: `uom` stores
values pre-converted to the base units of `U` so that changing display units touches only
constructors/accessors; `units` makes the local coherent system (`lcsu`) a type parameter so
re-basing is a type-level substitution; mp-units keeps units in the type and converts
explicitly at typed boundaries (see the [system page][mp-units]). In the dependent setting
the question becomes explicit
mathematics; the torsor/group-action account of what a unit choice _is_ lives on the
[torsor page][torsor] and in [Whitney's][whitney] structure theorem.

### Addition across different dimensions

Multiplication is total across dimensions in every mechanism (`mul : float<'u> → float<'v> → float<'u 'v>`;
`typenum::Sum` bounds; `expr_multiply`; `dimension.mul`) — the group structure makes the
product of any two quantities a quantity. Addition is where the mechanisms diverge, and each
one _says something different about why_:

- **F#/`uom-plugin`** — ill-typed; a unification failure. The deeper "why" is Theorem 2:
  the erased sum of an `m`-value and a `kg`-value computes fine, but the result is not
  invariant under the scaling action — the mixed sum fails to commute with `h` unless the
  two indices are equal. The type error is the decidable shadow of a semantic
  non-invariance. (See the check-in example in [Kennedy 2010][k10] §4.1, where the mixed
  comparison silently changes behaviour under metrication.)
- **Integer-vector libraries** — undefined rather than forbidden: there is simply no
  `Add` impl / no overload for distinct `D`; the operation does not exist to be rejected.
  The "why" is left implicit in the API design.
- **Closed type families** — forbidden via the normal-form constraint `d1 @~ d2`; the
  "why" degenerates into "the difference list must normalize to `'[]`".
- **Lean (Bobbin et al.)** — the most philosophically explicit answer in the catalog:
  dimension addition is _total but unknowable off-diagonal_. It is defined with Hilbert's
  epsilon operator —

  ```lean
  protected noncomputable def add : dimension B E → dimension B E → dimension B E :=
  Classical.epsilon $ fun f => ∀ a b, a = b → f a b = a
  ```

  ([`Basic.lean`][lean-repo] L87–88; discussed in [Bobbin 2025][bobbin] §4) — i.e. _some_
  function satisfying `a = b → a + b = a`, about which nothing else is provable. Adding
  equal dimensions provably yields that dimension (`a + a = a`, not `2a`); adding unequal
  dimensions yields a term with no derivable properties. Where the type-system mechanisms
  make heterogeneous addition a static _error_, the dependent mechanization makes it a
  well-formed expression with **no theory** — arguably the most faithful rendering yet of
  "meaningless" as opposed to "false", and a direct data point for this survey's central
  open question.

---

## Expressive power & limits

### The `sqr` litmus test

`sqr x = x * x` at type `α → α²` is the smallest program that separates the mechanisms,
because its type requires the checker to (a) _name_ a squared index and (b) reason about it
symbolically.

- **Phantom-only**: fails at (a). `Real<Meter>` admits no `Meter²`; historical encodings
  stop at homogeneity tags.
- **F#**: inferred, principal ([Kennedy 2010][k10] §2.6):

  ```fsharp
  > let sqr (x:float<_>) = x*x;;
  val sqr : float<'u> -> float<'u ^ 2>
  ```

  and the inverse direction is equally strong: `fun (x : float<_>) -> sqrt x` infers
  `float<'u ^ 2> -> float<'u>` — solving `α² =U m²` is Theorem 1's `m = 1` case. Meanwhile
  parametricity (POPL '97 §5.2) proves that no _closed_ term of type
  `∀u. num u² → num u` computes a non-trivial square root — the initial estimate for any
  iteration cannot be manufactured at type `num u` — so the primitive `sqrt` must be
  built in.

- **`uom-plugin`**: expressible and inferable — `sqrt :: Floating a ⇒ Quantity a (u *: u) → Quantity a u`
  is in the library's own interface ([Gundry][gundry] §2.1.2), and the plugin solves
  `α² ∼ β³`-style constraints by the Fig.-7 rewriting.
- **Closed type families**: `sqr` is _expressible_ — `\x -> x |*| x` gets a type mentioning
  `d @* d` or `Normalize (d @@+ d)` — but the index arithmetic is stuck on variables, so the
  symmetric use `f x y = (x |*| y) |+| (y |*| x)` needs `u ⊗ v ∼ v ⊗ u`, which the family
  cannot prove for unknowns; Gundry exhibits the resulting unusable inferred type
  ([Gundry][gundry] §2.2.1). Inversion (`sqrt` at a variable dimension) works only where a
  dedicated `NRoot` family applies.
- **`uom`/`dimensioned` (Rust)**: expressible with the arithmetic spelled out as bounds —
  the library's own generic impls are the pattern: multiplication demands
  `Dl::L: Add<Dr::L>` per base symbol ([`system.rs`][uom-repo] L465–476), and `sqrt`
  demands divisibility, `D::L: PartialDiv<P2>` with output an `Integer` (L925–929) — the
  torsion-freeness side condition of Theorem 1 reified as a trait bound that simply fails to
  hold for odd exponents. `dimensioned` packages the same idea as `Root`/`Sqrt` traits
  ([`traits.rs`][dimensioned-repo] L222, L288). There is no unification: a bound either
  resolves or errors.
- **mp-units (C++)**: `sqr` is trivially "generic" because unconstrained templates
  type-check at instantiation — and dimension arithmetic is total even for roots, since
  exponents are rationals: `sqrt(d) = pow<1, 2>(d)` on dimensions
  ([`dimension.h`][mp-units-repo]). The cost is the usual template trade: no principal
  types, no inference, errors reported per-instantiation (concepts like `Dimension` sharpen
  them into requires-clause failures).
- **Lean**: `sqr` is an ordinary function and `dimension.pow` an ordinary group power; the
  interesting content moves into theorems _about_ it.

### Fractional and irrational powers

The exponent domain is a design axis, not an afterthought. Kennedy's original theory fixes
`ℤ` deliberately (POPL '97 §2.3: fractional units suggest revising the base-unit set) — but
the shipped F# compiler now carries `Measure.RationalPower … Rational` in its typed tree and
divides exponents with `DivRational` in `SimplifyMeasure` ([`ConstraintSolver.fs`][fsharp-cs];
[Gundry][gundry] fn. 21 dates fractional-unit support to F# 4.0). Over `ℚ` the group becomes
a vector space and unification collapses to one elimination step per variable — no Euclid
loop. mp-units likewise chose `ℚ` (`power<T, Num, Den>`). The `typenum` libraries and
`dimensional` stay on `ℤ`; `dimensional` states the philosophy in a comment:

> _"We limit ourselves to integer powers of Dimensionals as fractional powers make little
> physical sense."_ — [`dimensional` `TypeLevel.hs`][dimensional-repo] (comment above `^`)

Gundry's future-work list points the other way — `√Hz` "arises when quantifying electronic
noise levels" ([Gundry][gundry] §6.1). **Irrational** powers are outside every mechanism
here: they leave the finitely-generated group entirely (see [Whitney][whitney] and the
[tensor-of-lines][tensor] account for what would replace it).

### Affine, logarithmic, and angular quantities

The group mechanism has no place for any of them, and the sources say so explicitly.
Temperature-with-origin: Gundry — "Multiple origins need to be considered to handle units of
temperature, since 0C ≈ 273K. It may be possible to handle these by indexing quantities by
an abelian group of translations as well as units (Atkey et al. 2013)" ([Gundry][gundry]
§6.1; the [torsor page][torsor] develops the mathematics). Logarithmic units: "Logarithmic
units such as dBm require arithmetic operations like ⊕ to be given different types" (ibid.).
Angles: [Kennedy 2010][k10] §2.5 keeps them dimensionless by default and shows the
`deg`/`rev` opt-in pattern — a per-program choice, not a mechanism feature. Library systems
that _do_ ship affine machinery (interval/point types, `TemperatureInterval` vs
`ThermodynamicTemperature` kinds in [`uom`][rust-uom], `quantity_point` in
[mp-units][mp-units]) do it by layering more types on top of the group, not by changing the
group — details on the system pages.

### Same dimension, different kind

The free abelian group identifies torque with energy (`kg·m²·s⁻²`) and `Hz` with `Bq`
(`s⁻¹`). Kennedy's mechanism inherits the identification; F# users get no protection. The
two library answers are `uom`'s flat opaque `Kind` tag (quantities of equal dimension but
different kinds "are not comparable", [`system.rs`][uom-repo]) and mp-units'
`quantity_spec` _tree_, which additionally orders kinds so that conversions can move down
but not sideways ([`quantity_spec.h`][mp-units-repo]). Both restore distinctions by adding
structure the group lacks — evidence for the [Hart][hart]/[Whitney][whitney]-side view that
dimension is not the whole invariant. **Silence recorded**: no mechanism in this family
derives kind distinctions from the algebra; all bolt them on nominally.

### Graded structures: dimensions as effects

Kennedy's primitive types are a **grading** of the numeric functor by the unit group: in
POPL '97's `Γops` (Fig. 2), multiplication has type `∀u₁.∀u₂. num u₁ → num u₂ → num (u₁·u₂)`
and the constant `1 : num 1` — i.e. `num` is a monoid-graded family with `*` as graded
multiplication and dimensionless as the unit grade, exactly the shape of a graded
monoid/monad indexed by `(Units, ·, 1)`. The practical consequence shows up in Gundry's
framing of the plugin as _generic_ index-theory support: the same mechanism slot serves
"indexing a monad by the available effects, using a solver for a theory of sets, maps or
boolean rings, as in the effect-monad library of Orchard and Petricek (2014)"
([Gundry][gundry] §6.3) — units are one instance of algebraically indexed types, effects
another, and each index theory needs its own equational solver plugged into the same
`OutsideIn(X)` socket. [Atkey 2014][atkey] pushes the semantic side of the same
generalisation: index the types by other invariance groups and parametricity yields
conservation laws rather than unit-safety. (Assessment, flagged as such: no surveyed
_units_ library actually packages itself as a graded monad; the observation is structural.)

---

## Mechanization

### Decision procedures, complexity, and inference

| Mechanism                    | Procedure                                                                                                                                                                                                                                                                  | Decidable?                                                                                   | Principal types?                                                                                                                                                                  |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| F# native                    | `UnifyMeasures ms1 ms2 = UnifyMeasureWithOne (Prod(ms1, Inv ms2))` — Kennedy's reduction verbatim in the compiler; elimination over `ℚ` (`DivRational`), plus `SimplifyMeasure`(-`sInType`) for scheme normalisation ([`ConstraintSolver.fs`][fsharp-cs] L801, L807, L839) | yes — Gaussian elimination, polynomial in exponent-matrix size                               | yes (Theorem 1; scheme normal forms per [Kennedy 2010][k10] §3.9)                                                                                                                 |
| `uom-plugin`                 | rewrite system of [Gundry Fig. 7][gundry]: normalise to `u ∼ 1`, eliminate variables by the mod-step, iterate under `OutsideIn(X)`                                                                                                                                         | yes for the unit fragment; plugin-extended-solver termination unproven ([Gundry][gundry] §6) | sound (Thm 1); generality only up to fresh-variable substitution (Thm 2) — the guess-free condition fails because "the fresh variable γ has been conjured out of thin air" (§4.3) |
| Closed type families         | terminating rewriting on ground(ish) index terms; `Normalize`/`Reorder` families                                                                                                                                                                                           | yes on closed terms; constraints involving variables get _stuck_, not failed                 | no — and the leaked normal-form constraints are the diagnostic cost ([Gundry][gundry] §2.2.1)                                                                                     |
| Trait resolution (Rust)      | `typenum` arithmetic evaluated during trait solving; requirements appear as `where`-bounds                                                                                                                                                                                 | evaluation of ground exponent arithmetic always terminates                                   | n/a — no let-generalisation over indices; monomorphization resolves everything                                                                                                    |
| Template instantiation (C++) | `consteval`/`constexpr` canonicalisation (`expr_consolidate`, `expr_multiply`); equality is `is_same_v` of canonical types                                                                                                                                                 | yes at instantiation                                                                         | n/a — two-phase checking, no inference; concepts give earlier, better errors                                                                                                      |
| Dependent types (Lean)       | none built in — `Decidable (a = b)` is obtained _classically_ (`Classical.propDecidable`, [`Basic.lean`][lean-repo] L80), i.e. noncomputably; practical checking is `simp`/`decide`/hand proofs                                                                            | equality of `B → E` functions decidable when `B` finite, `E` decidable                       | n/a — full proofs replace inference                                                                                                                                               |

Two cross-cutting findings. First, the **`TORSION-FREE` rule** is where the mathematics
constrains the implementation most delicately: Gundry's soundness _and_ generality proofs
both need `u ~ ⋯ ~ u ∼ 1 ⊢ u ∼ 1`, which

> _"amounts to restricting models of `Unit` to being free abelian groups, i.e. those
> generated by the base units and abelian group laws but with no other equations."_
> — [Gundry 2015][gundry] §4.3

— an axiom `kg ~ kg ∼ 1` would break both directions; the freeness of the group (see
[free-abelian-group][fag]) is not a modelling nicety but a soundness precondition of the
solver. Second, the **plugin existence proof**: Gundry's headline —

> _"The crucial observation of this paper is that we need to introduce support for a
> domain-specific equational theory."_ — [Gundry 2015][gundry] §2.2.1

— generalises past units. GHC could not host `=U` natively because type families "may
pattern match only on constructors, not other type families" and AC axioms are not a
terminating rewrite system ([Gundry][gundry] §2.2); the typechecker-plugin interface
(implemented by Diatchki, Seidel and Gundry in GHC 7.10.1) turns the built-in solver into
the `X` of `OutsideIn(X)` for any theory that can supply sound, most-general simplification.

### Where each mechanism lives (pointers, not surveys)

- **F#** — [`fsharp-uom.md`][fsharp]; compiler evidence in `dotnet/fsharp` pinned
  `25c6a37e`: [`TypedTree.fs`][fsharp-repo] L4696, [`ConstraintSolver.fs`][fsharp-cs].
- **GHC plugin** — [`haskell-uom-plugin.md`][uom-plugin]; repo pinned `0b87268`:
  `uom-plugin/src/Data/UnitsOfMeasure/Internal.hs` (the `newtype`, the empty type families),
  `…/Plugin` (the solver).
- **Closed type families** — [`haskell-dimensional.md`][dimensional] (with the
  [`units`][units-pkg] contrast): `dimensional` pinned `f759f32`
  (`Dimensions/TypeLevel.hs`); `units` pinned `c06d560` (`Data/Metrology/{Z,Factor,Qu}.hs`).
- **Rust type-level integers** — [`rust-uom.md`][rust-uom] (pinned `a465bcc`,
  `src/system.rs`; note that as of this 2026 pin it still uses `typenum`, not const
  generics) and [`rust-dimensioned.md`][rust-dimensioned] (pinned `615c908`,
  `src/make_units.rs`).
- **C++** — [`cpp-mp-units.md`][mp-units] (pinned `d7b11de`,
  `framework/{dimension.h,symbolic_expression.h,quantity_spec.h}`); the same
  template-mechanism family with different design points in
  [`cpp-boost-units.md`][boost] and [`cpp-au.md`][au]; the D-language cousins in
  [`d-quantities.md`][d-quantities]; the Ada compiler-aspect variant in
  [`ada-gnat-dimensions.md`][gnat].
- **Dependent types** — [`lean-mathlib-units.md`][lean]; `LeanDimensionalAnalysis` pinned
  `de263ee` (`DimensionalAnalysis/Basic.lean`) + [Bobbin 2025][bobbin]; note the honest
  negative finding from the source survey: mathlib4 itself has no
  dedicated physical-units development.

---

## Open problems & frontier

- **Principality under plugins.** Gundry's Theorem 2 is deliberately weaker than
  `OutsideIn(X)`'s guess-free condition — the most general AG-unifier necessarily introduces
  fresh variables, and the framework "does not have a clear notion of scope for type
  variables" to license them ([Gundry][gundry] §4.3, including the observation that the same
  gap already afflicts the base algorithm's own Lemma 7.2). Whether the weakened generality
  suffices for principal types in full GHC is stated as a conjecture. Termination of the
  plugin-extended solver is likewise open (§6).
- **Kinds: nominal patch or algebraic structure?** `uom`'s flat `Kind` tag and mp-units'
  `quantity_spec` tree solve torque-vs-energy in incompatible ways, and neither derives from
  the group theory; the Kennedy lineage is silent. Whether "kind" has a canonical
  mathematical home (Hart's per-component structure? Whitney's structure theorem refined?)
  is exactly the reconciliation question deferred to this tree's synthesis —
  see [Hart][hart] and [comparison][comparison].
- **The design space of automatic conversion.** Both Kennedy ([2010][k10] §5: is
  `[<Measure>] type ft = 0.3048<m>` a unit or a literal notation? how do conversions lift
  through higher-order types given floating-point non-associativity?) and Gundry (§6.1:
  `convert`, `Pack`/`Unpack` type families that must be plugin-defined because they observe
  unit structure) leave unit-conversion inference open; the library world answers it several
  different ways (`uom` stores values pre-converted to base units, `units` parameterizes by
  a local coherent system of units, [mp-units][mp-units] and [Au][au] make yet other
  choices) — a live disagreement, catalogued on the system pages.
- **Beyond the group: translations, logarithms, fractions.** Gundry §6.1's list — abelian
  groups of translations for temperature origins (Atkey et al. 2013, held here only as
  restated by Gundry), differently-typed `⊕` for `dBm`, fractional units — remains the
  agreed frontier checklist a decade later; mp-units' rational exponents and F#'s
  `RationalPower` have ticked exactly one box of it.
- **Erasure theorems for the encodings.** Kennedy's parametricity theorem is proved for
  `Λᵤ`, and the F# spec asserts erasure normatively; but no analogous abstraction theorem
  has been mechanized for the `typenum`-, template-, or type-family encodings (assessment
  from the surveyed artifacts — no such proof appears in any pinned repo or paper here).
  The dependent-type track is positioned to close the gap — Bobbin et al. formalize the
  _mathematics_ of dimensional analysis, but a formalized account of a _checker_ (Theorem 1
  - Theorem 2, end to end) does not yet exist in this catalog's evidence base.
- **What heterogeneous addition _is_.** The mechanisms disagree in an unusually crisp way:
  unification failure (F#/GHC-plugin), missing operation (Rust/C++), unprovable constraint
  (type families), and a total-but-unknowable `Classical.epsilon` function (Lean). Whether
  "meaningless", "undefined", "partial", or "unknowable" is the right formal rendering — and
  what the mathematical formalizations ([Whitney][whitney], [tensor-of-lines][tensor],
  [torsors][torsor]) say it should be — is the survey's central open question, deliberately
  left unreconciled here.

---

## Sources

- Andrew Kennedy, ["Types for Units-of-Measure: Theory and Practice"][k10], CEFP '09
  lecture notes, LNCS 6299, 2010 — the mechanism reference: `=U`, normal forms, `Unify`
  (Fig. 5, Theorem 1), scheme equivalence, the semantics recap, and the phantom-encoding
  analysis quoted above. (Local artifact `kennedy-2010-types-units-of-measure-cefp.pdf`;
  quotes from a `pdftotext -layout` extraction.)
- Andrew Kennedy, ["Relational Parametricity and Units of Measure"][k97], _POPL '97_ — the
  erasure semantics, scaling relations, parametricity (Theorem 1), completeness of scaling
  environments (Theorem 2), definability and Pi-theorem corollaries. (Local artifact
  `kennedy-1997-relational-parametricity-units-popl.pdf`.)
- Adam Gundry, ["A Typechecker Plugin for Units of Measure"][gundry], _Haskell Symposium
  2015_ — the vanilla-GHC impossibility analysis, the plugin interface in `OutsideIn(X)`,
  the AG rewrite solver, soundness/generality, `TORSION-FREE`, and the future-work frontier.
  (Local artifact `gundry-2015-typechecker-plugin-uom-haskell.pdf`.)
- [The F# Language Specification 4.1][fsharp-spec], §9 — normative measure syntax, checking,
  and erasure (§9.6). (Local artifact `fsharp-spec-4.1.pdf`.)
- Maxwell P. Bobbin, Colin Jones, John Velkey & Tyler R. Josephson,
  ["Formalizing Dimensional Analysis Using the Lean Theorem Prover"][bobbin],
  arXiv:2509.13142, 2025 + the
  [`LeanDimensionalAnalysis`][lean-repo] repo (pinned `de263ee`) — the dependent-type
  mechanization: `dimension B E := B → E`, `CommGroup`, `Classical.epsilon` addition,
  Buckingham-Pi matrices. (Local artifacts
  `bobbin-2025-formalizing-dimensional-analysis-lean-arxiv.pdf`, `$REPOS/lean/LeanDimensionalAnalysis`.)
- Robert Atkey, ["From Parametricity to Conservation Laws, via Noether's Theorem"][atkey],
  _POPL '14_ — frontier: invariance-indexed types beyond units (abstract/introduction
  inspected). (Local artifact `atkey-2014-parametricity-conservation-laws-popl.pdf`.)
- Pinned repos (reviewed at the survey's pinned SHAs): [`dotnet/fsharp`][fsharp-repo]
  (`TypedTree.fs`, [`ConstraintSolver.fs`][fsharp-cs]); [`uom-plugin`][uom-plugin-repo]
  (`Internal.hs`); [`dimensional`][dimensional-repo] (`Dimensions/TypeLevel.hs`);
  [`units`][units-pkg] (`Z.hs`, `Factor.hs`, `Qu.hs`); [`uom`][uom-repo] (`src/system.rs`);
  [`dimensioned`][dimensioned-repo] (`src/make_units.rs`, `src/traits.rs`);
  [`mp-units`][mp-units-repo] (`framework/dimension.h`, `symbolic_expression.h`,
  `quantity_spec.h`); [`LeanDimensionalAnalysis`][lean-repo] (`Basic.lean`).
- Related pages: [theory index][theory-index] · [umbrella][umbrella] ·
  [concepts][concepts] · [Kennedy's type theory][kennedy] · [free abelian group][fag] ·
  [Buckingham Π][pi] · [Whitney][whitney] · [tensor of lines][tensor] ·
  [torsors][torsor] · [Hart][hart] · systems: [F#][fsharp] · [`uom-plugin`][uom-plugin] ·
  [`dimensional`][dimensional] · [`uom`][rust-uom] · [`dimensioned`][rust-dimensioned] ·
  [mp-units][mp-units] · [Boost.Units][boost] · [Au][au] · [D quantities][d-quantities] ·
  [GNAT Ada][gnat] · [Pint][pint] · [Unitful.jl][unitful] · [Lean][lean] ·
  [Wolfram/MATLAB][wolfram] · [comparison][comparison].

<!-- References -->

<!-- Same-tree theory siblings -->

[theory-index]: ./index.md
[kennedy]: ./kennedy-types.md
[fag]: ./free-abelian-group.md
[pi]: ./buckingham-pi.md
[whitney]: ./whitney.md
[tensor]: ./tensor-of-lines.md
[torsor]: ./torsor-representation.md
[hart]: ./hart-multidimensional.md

<!-- Tree umbrella / concepts / comparison / grounding -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md

<!-- System deep-dives -->

[fsharp]: ../fsharp-uom.md
[uom-plugin]: ../haskell-uom-plugin.md
[dimensional]: ../haskell-dimensional.md
[rust-uom]: ../rust-uom.md
[rust-dimensioned]: ../rust-dimensioned.md
[mp-units]: ../cpp-mp-units.md
[boost]: ../cpp-boost-units.md
[au]: ../cpp-au.md
[d-quantities]: ../d-quantities.md
[gnat]: ../ada-gnat-dimensions.md
[pint]: ../python-pint.md
[unitful]: ../julia-unitful.md
[lean]: ../lean-mathlib-units.md
[wolfram]: ../wolfram-matlab.md

<!-- Primary sources & external -->

[k10]: https://doi.org/10.1007/978-3-642-17685-2_8
[k97]: https://dl.acm.org/doi/10.1145/263699.263761
[gundry]: https://dl.acm.org/doi/10.1145/2804302.2804305
[fsharp-spec]: https://fsharp.org/specs/language-spec/4.1/FSharpSpec-4.1-latest.pdf
[bobbin]: https://arxiv.org/abs/2509.13142
[atkey]: https://dl.acm.org/doi/10.1145/2535838.2535867
[fsharp-repo]: https://github.com/dotnet/fsharp
[fsharp-cs]: https://github.com/dotnet/fsharp/blob/25c6a37e/src/Compiler/Checking/ConstraintSolver.fs
[uom-plugin-repo]: https://github.com/adamgundry/uom-plugin
[dimensional-repo]: https://github.com/bjornbm/dimensional
[units-pkg]: https://github.com/goldfirere/units
[uom-repo]: https://github.com/iliekturtles/uom
[dimensioned-repo]: https://github.com/paholg/dimensioned
[mp-units-repo]: https://github.com/mpusz/mp-units
[lean-repo]: https://github.com/ATOMSLab/LeanDimensionalAnalysis
