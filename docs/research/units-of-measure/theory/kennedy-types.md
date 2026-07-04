# Kennedy's Type-Theoretic Units of Measure

The programming-language formalization of dimensional analysis: units and dimensions become
**type-level parameters** of numeric types in an ML-style language, obeying the equations of a
[free abelian group][fag], with **principal types** inferred by equational unification over that
group. [Andrew Kennedy's line][k94] — [ESOP 1994][k94] (the dimension-polymorphic type system),
the [1995/96 Cambridge thesis][k96] (the complete system: types, inference, operational and
denotational semantics), [POPL 1997][k97] (the rescaling-invariance parametricity theorem), and
the [2010 CEFP lecture notes][k10] (the shipped F# design) — is the only formalization in this
catalog that runs in a production compiler ([F#'s `float<m/s^2>`][fsharp]). Its distinctive
philosophical move is **types-as-invariance**: a unit has no run-time existence at all (units are
erased before evaluation); what the unit structure of a type _means_ is a family of scaling
relations that every well-typed program provably respects, so that "dimensionally correct" is
identified with "behaviour commutes with change of units".

> [!NOTE]
> This page covers the theory line: the precursor [Wand & O'Keefe 1991][wo91], Kennedy's four
> core texts, the production unifier in the F# compiler's [`ConstraintSolver.fs`][cs-fs], the
> [`uom-plugin`][gundry] transplant of the same algorithm into GHC, and the [Atkey 2014][atkey]
> parametricity-to-Noether frontier. The survey of **F# as a product** (syntax, `Measure` kinds,
> generics interop, spec) is [`fsharp-uom.md`][fsharp]; how _other_ type systems encode or
> approximate this machinery is [`type-system-mechanisms.md`][mechanisms]; the free-abelian-group
> structure itself, independent of type systems, is [`free-abelian-group.md`][fag].

---

## At a glance

| Dimension            | Kennedy's type-theoretic units                                                                                                                                                                 |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Primary structure    | An ML-style typed λ-calculus whose numeric type `real δ` / `num µ` / `float<u>` is indexed by a **free abelian group** of unit expressions (base units + unit variables, modulo AG axioms)     |
| Quantity             | A typed value `r : num µ` — in the underlying semantics a bare rational; the unit lives only in the type and is **erased** before evaluation                                                   |
| Unit                 | A unit _variable_: base units are free occurrences, polymorphism is bound occurrences ([POPL '97 §3.1][k97])                                                                                   |
| Dimension            | A class of units ≅ a class of isomorphic data representations ([POPL '97 §2.1][k97]); the thesis parameterises on dimensions, F# on units — formally a minor choice                            |
| Central theorem      | **Dimensional invariance** (parametricity): a term of type `∀u. num u → num u²` satisfies `e (k·x) ≈ k²·(e x)` for every scale factor `k` — [POPL '97][k97] Theorems 1 + 2                     |
| Inference            | Damas–Milner with syntactic unification replaced by **abelian-group (AG) unification**; AG with nullary constants is a **unitary** theory ⇒ single most general unifier ⇒ principal types      |
| Decision procedure   | `DimUnify` — a Euclid-style iteration on integer exponent vectors ([thesis Fig. 3.1][k96]); production F# solves over ℚ in one elimination step per variable ([`ConstraintSolver.fs`][cs-fs])  |
| Canonical forms      | Normal form `d₁^x₁···B₁^y₁···` for unit expressions; **Hermite normal form** for type schemes; **Smith normal form** inside the Pi-theorem proof                                               |
| Addition across dims | Ill-typed statically; semantically **defined but not invariant** — the erased sum computes fine, but its value depends on the arbitrary unit choice (fails to commute with the scaling action) |
| Buckingham Π         | Recast as a **type isomorphism**: a first-order unit-polymorphic type collapses to `n − rank(A)` dimensionless arguments ([POPL '97 Theorem 3][k97]) — see [Buckingham Π][pi]                  |
| Cannot express       | Fractional/irrational exponents (by design), value-dependent exponents (`xⁿ`), affine units (°C), logarithmic units (dB), same-dimension different-kind (torque vs energy)                     |
| Realizations         | ML Kit extension (1994); **F#** (`[<Measure>]`); GHC **`uom-plugin`** (2015); every library-level encoding surveyed in this tree approximates it — see [Mechanization](#mechanization)         |

---

## Primary sources

All items below were **read in the local artifacts** under
`$REPOS/papers/units-of-measure/` (`$REPOS` = `/home/petar/code/repos`) or in pinned repos;
quotes were transcribed from `pdftotext -layout` extractions of those PDFs.

- **Mitchell Wand & Patrick O'Keefe, "Automatic Dimensional Inference"**, in _Computational
  Logic: Essays in Honor of Alan Robinson_ (J.-L. Lassez & G. Plotkin, eds.), MIT Press, 1991,
  pp. 479–486 — the precursor ([`wand-okeefe-1991-…-lpar.pdf`][wo91]). Dimension inference for
  the simply-typed λ-calculus with a fixed number `N` of base dimensions, types
  `Q(n₁, …, n_N)` with **rational**-linear-combination exponents, solved by ordinary
  unification followed by **Gaussian elimination**; principal types "unique up to a choice of
  basis" — no single most general unifier, and no user-declared base units inside the solver.
- **Andrew Kennedy, "Dimension Types"**, _ESOP '94_, LNCS 788, pp. 348–362 — the origin paper
  ([`kennedy-1994-dimension-types-esop.pdf`][k94]). The polymorphic dimension type system over
  ML, the first AG-unification-based inference algorithm (after Lankford–Butler–Brady), the ML
  Kit implementation, and the first statement of the open problems (equivalent types with no
  canonical syntax; dependent exponents; ML-polymorphism limits).
- **Andrew Kennedy, _Programming Languages and Dimensions_**, PhD thesis, University of
  Cambridge; submitted November 1995, published April 1996 as Technical Report
  **UCAM-CL-TR-391** ([`kennedy-1996-…-thesis.pdf`][k96]). The full system: `MLδ` (implicit) and
  `Λδ` (explicit) calculi, syntax-directed typing, `DimUnify`/`Infer` with correctness proofs,
  the `Simplify`/Hermite-normal-form canonicalization, generalisation via change of basis
  (`CofB`), operational semantics with **dimension erasure** ("well-dimensioned programs don't
  go wrong"), denotational semantics with the scaling relation, and Appendix B's algebraic view
  (dimensions as a free `ℤ`-module; substitutions as integer matrices).
- **Andrew Kennedy, "Relational Parametricity and Units of Measure"**, _POPL '97_, pp. 442–455
  ([`kennedy-1997-…-popl.pdf`][k97], author's copy). The semantic capstone: the explicitly-typed
  calculus `Λu`, the scaling logical relation, the **parametricity theorem** and the
  **completeness theorem** characterising exactly which scalings the arithmetic primitives
  admit, free theorems, type-inhabitation results (no polymorphic square root), type
  isomorphisms, and the **Pi theorem for `Λu`**.
- **Andrew Kennedy, "Types for Units-of-Measure: Theory and Practice"**, CEFP 2009 revised
  lecture notes, LNCS 6299 (2010) ([`kennedy-2010-…-cefp.pdf`][k10], the revised 42-page
  author copy). The F# design as shipped, the didactic presentation of the type system
  and unification algorithm (Figures 4–8), the decidability/unitary discussion, open type
  schemes and generalized `let`, and the semantics recast for a practitioner audience.
- **Adam Gundry, "A Typechecker Plugin for Units of Measure"**, _Haskell Symposium 2015_
  ([`gundry-2015-typechecker-plugin-uom-haskell.pdf`][gundry]) — the AG-unification algorithm
  re-implemented as a GHC constraint-solver plugin; identifies the **torsion-free** axiom needed
  beyond the AG laws for most-general solutions.
- **Robert Atkey, "From Parametricity to Conservation Laws, via Noether's Theorem"**, _POPL '14_
  ([`atkey-2014-parametricity-conservation-laws-popl.pdf`][atkey]) — the frontier: Kennedy-style
  invariance types generalised from scalings to arbitrary geometric symmetry groups in System
  `Fω`, yielding conserved quantities from Lagrangian types.
- **`dotnet/fsharp`** pinned at `25c6a37e` — the production implementation:
  [`src/Compiler/Checking/ConstraintSolver.fs`][cs-fs] (`UnifyMeasureWithOne` L782,
  `UnifyMeasures` L801, `SimplifyMeasure` L807, `SimplifyMeasuresInType` L839) and
  `src/Compiler/TypedTree/TypedTree.fs` (`type Measure`, L4696).

Cited only through the above, **not inspected** (all such uses are marked in context):
Lankford, Butler & Brady 1984 (the first AG-unification algorithms) [unverified];
Rittri, "Dimension inference under polymorphic recursion", FPCA '95 [unverified];
Kennedy, "Formalizing an extensional semantics for units of measure", WMM 2008 [unverified];
Goubault 1994 (rational-exponent dimension inference for ML) [unverified];
House 1983 (dimension-polymorphic Pascal) [unverified];
Baader 1989 / Nutt 1990 (unification in commutative/monoidal theories) [unverified];
Atkey, Johann & Kennedy, POPL '13 (geometric invariance types) [unverified].

The lineage is explicit in the sources: ESOP '94 records that "an anonymous referee has pointed
out work by Wand and O'Keefe" only after submission, and Wand & O'Keefe open with the claim that

> _"it appears that no one has made the easy observation that dimensional analysis fits neatly
> into the pattern of ML-style type inference … we show that every typable dimension-preserving
> term has a principal type. The principal type is unique up to a choice of basis."_
> — Wand & O'Keefe 1991, ¶1 ([`wand-okeefe-1991-…-lpar.pdf`][wo91], p. 1)

The two systems were devised independently; the thesis (§3.4) draws the contrast used throughout
this page: Wand & O'Keefe fix the base dimensions in advance and allow rational exponents, so
their "principal type" is a basis of a solution space of a ℚ-linear system rather than a single
most general unifier — and their types can be dimensionally nonsensical (e.g.
`∀i,j,k. Q(i,j,k) → Q(j,i,k)`, which swaps mass and length), though no program is ever assigned
one.

---

## Formal core

### The dimension algebra in the types

Three notations for the same system appear across the sources; this page uses each where it
quotes its source:

| Text              | Numeric type | Unit/dimension variables | Polymorphism                             |
| ----------------- | ------------ | ------------------------ | ---------------------------------------- |
| ESOP '94 / thesis | `real δ`     | `d`, `d₁`, … (dimension) | implicit, ML-style `let` (system `MLδ`)  |
| POPL '97          | `num µ`      | `u`, `u₁`, … (unit)      | explicit, System-F-style `Λu.e` (`Λu`)   |
| CEFP '10 / F#     | `float<u>`   | `'u`, `'v`, … (measure)  | implicit, ML-style `let` + `[<Measure>]` |

Dimension (unit) expressions form the grammar

```text
δ ::= d          dimension/unit variable   (an infinite set DimVars)
    | B          base dimension/unit       (kg, m, s, … — a set DimCons)
    | 1          the unit dimension        (dimensionless)
    | δ₁ · δ₂    product
    | δ⁻¹        inverse
```

identified up to the congruence `=D` generated by exactly the **abelian-group axioms**:
commutativity `δ₁·δ₂ =D δ₂·δ₁`, associativity, identity `1·δ =D δ`, and inverses
`δ·δ⁻¹ =D 1` ([thesis §2.1][k96]; [CEFP Fig. 4][k10]). The thesis states the punchline directly:
"the set of all dimension expressions quotiented by this equivalence forms a free Abelian
group", and — with `δⁿ` as scalar multiplication — "can be treated as a vector space over the
integers, or more properly, a free `ℤ`-module" ([thesis p. 16][k96]). Every expression has a
unique **normal form** `d₁^x₁ ··· d_m^x_m · B₁^y₁ ··· B_n^y_n` with non-zero integer exponents,
computed by an exponent-counting map `expδ : DimVars ∪ DimCons → ℤ`; `δ₁ =D δ₂` iff
`exp_δ₁ = exp_δ₂`. This is the [free-abelian-group formalization][fag] embedded, wholesale, into
a type grammar — the group-theoretic content is deliberately identical; what is new is
everything the type system builds on top.

Two structural properties of `=D` drive the whole design:

- **The theory is non-regular.** The axiom `δ·δ⁻¹ =D 1` equates terms with _different_
  variables, so equivalent dimensions can have different syntactic variables
  (`d₁·(d₂·d₁⁻¹) =D d₂`). "Free variables" must be redefined semantically (`fdv(δ)` = variables
  with non-zero exponent in the normal form), and a substitution can make variables **vanish**
  that are not in its domain — "the cause of most of the subtlety present in the dimension type
  system" ([thesis §2.1][k96]). To Kennedy's knowledge, "dimension inference is the first
  application of a non-regular equational theory to type inference" ([thesis §3.4][k96]).
- **The syntax is stratified.** Units may appear inside types (`num µ`, `τ₁ → τ₂`) but types may
  never appear inside units. This keeps the free function symbols (`→`, `num`) _outside_ the
  equational theory, which is what preserves unitary unification (below).

Simple types and type schemes are then (thesis form):

```text
τ ::= t | bool | real δ | τ₁ → τ₂
σ ::= τ | ∀t.σ | ∀d.σ
```

with an equivalence rule folding `=D` into typing — the only typing rule beyond Damas–Milner:

```text
        Γ ⊢ e : τ₁    τ₁ =D τ₂
(eq)   ─────────────────────────
              Γ ⊢ e : τ₂
```

The arithmetic primitives carry the dimensional discipline in their type schemes
([thesis §1.3][k96]; the same schemes appear in [POPL '97 Fig. 2][k97]'s `Γops` and as F#'s
operator types [CEFP §2.6][k10]):

```text
+, -   : ∀d. real d × real d → real d              (same dimension required)
*      : ∀d₁ d₂. real d₁ × real d₂ → real d₁·d₂    (dimensions multiply, freely)
/      : ∀d₁ d₂. real d₁ × real d₂ → real d₁·d₂⁻¹
sqrt   : ∀d. real d² → real d                      (integer exponents only)
<, ⩽   : ∀d. real d × real d → bool
0      : ∀d. real d                                (the ONLY polymorphic constant)
exp, ln, sin, cos : real 1 → real 1                (dimensionless only)
```

Non-zero literals are dimensionless by necessity, not taste: a polymorphic `1.0 : ∀d. real d`
would let `x * x * 1.0<'u>` "pretend" that squaring has type `float<'u> -> float<'u^3>`,
destroying soundness ([CEFP Exercise 2 solution][k10]). Zero is special for a semantic reason
made precise below: it is the unique fixed point of every scaling. (In F# the other
unit-polymorphic values are exactly `infinity`, `-infinity` and `nan` — also scaling
fixed points.)

Inferred principal types are already striking in the 1994 paper: `mean : ∀d. [d] real list →
[d] real`, `variance : ∀d. [d] real list → [d²] real`, the numerical differentiation operator
`diff : ∀d₁ d₂. [d₁] real → ([d₁] real → [d₂] real) → ([d₁] real → [d₂ d₁⁻¹] real)`, and for
`fun f (x,y,z) = x*x + y*y*y + z*z*z*z*z` the inferred
`∀d. [d¹⁵] real × [d¹⁰] real × [d⁶] real → [d³⁰] real` ([ESOP '94 §3.3][k94]).

### The central theorem: types as rescaling invariance

What does a unit-annotated type _mean_? Kennedy's answer is deliberately negative on the
operational side: nothing. The denotational semantics **ignores units entirely** —
`[[num µ]] = ℚ⊥` for every `µ`, `[[∀u.τ]] = [[τ]]` ([POPL '97 §3.3][k97]) — and the thesis proves
an erasure theorem for the operational semantics: evaluating a term and evaluating its
dimension-erased version are indistinguishable, so "well-dimensioned programs don't go wrong"
in the only sense available — there is no run-time event for a unit error to cause
([thesis §5.4][k96]). The CEFP notes make the point memorably:

> _"Nature does not seg-fault or throw ClassCastException! In nature, physical laws are
> independent of the units used, i.e. they are invariant under changes to the unit system. This,
> then, is the real essence of unit correctness: the ability to change the unit system without
> affecting behaviour."_
> — Kennedy, _Types for Units-of-Measure_, §4.1 ([`kennedy-2010-…-cefp.pdf`][k10], p. 28)

Unit correctness is therefore a **relational** property — a statement about a program and its
unit-converted counterpart, not about one execution. The formal device is a type-indexed logical
relation, in the style of Reynolds. In the thesis's concrete form, a **scaling environment**
`ψ : V → ℝ⁺` assigns a positive scale factor to each dimension variable and extends to a group
homomorphism from dimensions into `(ℝ⁺, ·)` — `ψ(1) = 1`, `ψ(δ₁·δ₂) = ψ(δ₁)·ψ(δ₂)`,
`ψ(δ⁻¹) = 1/ψ(δ)` ([thesis §6.4][k96]). The **scaling relation** `Rψ_τ ⊆ [[τ]] × [[τ]]` is defined
by induction on `τ` ([thesis Fig. 6.4][k96]; [CEFP §4.3][k10]):

```text
Rψ_bool  (b, b′)   ⇔  b′ = b                      (booleans: identity — observations agree)
Rψ_real δ (r, r′)  ⇔  r′ = ψ(δ) · r               (scale by the dimension's factor)
Rψ_τ₁→τ₂ (f, f′)   ⇔  ∀ (w, w′) ∈ Rψ_τ₁ .  (f w, f′ w′) ∈ Rψ_τ₂     (logical relation)
Rψ_∀d.τ  (w, w′)   ⇔  ∀ k ∈ ℝ⁺ .  (w, w′) ∈ R^(ψ[d ↦ k])_τ          (ALL scalings of d)
```

**Theorem (Dimensional invariance / parametricity).** If `V; Γ ⊢ e : τ` then for any scaling
environment `ψ` and environments `ρ, ρ′` with `Rψ_Γ(ρ, ρ′)`, it holds that
`Rψ_τ⊥([[e]]ρ, [[e]]ρ′)` — [thesis Theorem 6.11][k96]; [POPL '97 Theorem 1][k97] in the more
general relational form. The abstract states the informal content:

> _"Quantification over units then introduces a new kind of parametric polymorphism with a
> corresponding Reynolds-style representation independence principle: that the behaviour of
> programs is invariant under changes to the units used."_
> — Kennedy, _Relational Parametricity and Units of Measure_, abstract
> ([`kennedy-1997-…-popl.pdf`][k97])

**Proof sketch.** The proof splits into two halves — a parametricity half that is standard
logical-relations machinery, and a completeness half that is where the units-of-measure content
actually lives.

1. _Preliminaries._ Two lemmas by induction on `τ`: the relations are **strict and complete**
   (they contain `(⊥, ⊥)` and are closed under lubs of chains — needed for `rec`), and a
   **substitution lemma** `Rψ_{Sτ} = R^{ψ∘S}_τ` connecting type substitution to
   scaling-environment composition ([POPL '97 Lemmas 1–2][k97]).
2. _Parametricity (Theorem 1)._ Induction on the typing derivation. Abstraction and application
   are the standard "related arguments to related results" cases; `(rec)` uses strictness and
   completeness; the `(eq)` case is discharged because `ψ` respects `=E` — this is precisely
   where the abelian-group axioms enter the semantics. For `(∀-intro)`, `[[Λu.e]] = [[e]]`, and
   relatedness at `∀u.τ` demands relatedness under every extension `χ(ψ)` of the scaling
   environment to `u`, which the induction hypothesis at `V ∪ {u}` supplies. For `(∀-elim)`,
   the map `ψ ↦ ψ ∘ {u ↦ µ}` is such an extension, and the substitution lemma converts
   `R^{ψ∘S}_τ` into `Rψ_{Sτ}` — the type of `e µ`. ([POPL '97 §4][k97].)
3. _Completeness of the scaling family (Theorem 2)._ Theorem 1 holds for **any** family of
   relations `ψ(µ)` that respects `=E` — it does not yet know what "scaling" means. The second
   theorem pins that down: the standard interpretation `ρops` of `0, 1, +, -, *, /, <` is
   invariant under a family `E` **iff** every `ψ ∈ E` has the form `ψ_{G,h}` for a subgroup
   `G ⊆ Units(V)` and a group homomorphism `h ∈ hom(G, ℚ⁺)`, where `ψ_{G,h}(µ) = {(r, h(µ)·r)}`
   if `µ ∈ G` and `{(0, 0)}` otherwise ([POPL '97 Fig. 5, Appendix A][k97]). The derivation is a
   small gem of reverse engineering:
   - polymorphic `0` forces `(0,0) ∈ ψ(µ)` for every `µ`;
   - the comparison `<` forces any pair beyond `(0,0)` to be **order- and sign-preserving**, and
     with `/` and `ψ(1) = id_ℚ` this collapses each `ψ(µ)` to either the singleton `{(0,0)}` or
     a genuine rescaling `{(r, kr) | r ∈ ℚ}` with a single `k ∈ ℚ⁺`;
   - `*`, `/` and `1` then force the support `G = {µ | ψ(µ) ≠ {(0,0)}}` to be closed under
     product and inverse — a **subgroup** — and `µ ↦ k` to be a **homomorphism**
     (`h(µ₁·µ₂) = h(µ₁)h(µ₂)`, `h(µ⁻¹) = 1/h(µ)`).

   So "change of units" is not postulated; it is _derived_ as the largest symmetry the
   arithmetic primitives admit. (If `<` is replaced by a magnitude comparison, `ℚ⁺` relaxes to
   `ℚ \ {0}` — the symmetry group is exactly as large as the observations are weak;
   [POPL '97 §7][k97].)

4. _Instantiation._ For a closed term `e : ∀u. num u → num u²` pick `ψ(uⁿ) = {(r, kⁿr)}`
   (that is, `G` = all powers of `u`, `h(u) = k`): relatedness of `e` to itself yields
   `e (k*x) ≈ k² * (e x)` for every `k` — the headline rescaling free theorem.
   ∎

The split matters. A naive semantics that assigns scale factors to unit variables directly (the
thesis's `ψ : V → ℝ⁺`) proves the equational free theorems but is too weak for inhabitation
results; POPL '97's relational generalisation — allowing the degenerate `{(0,0)}` outside a
subgroup — is what makes impossibility proofs go through. (The thesis gets the same effect
differently: scale factors range over `ℝ⁺` while values are rationals, so an irrational scaling
relates only zeros — the choice is made in [thesis §6.4][k96], the argument run in §7.2.)

### Consequences of the theorem

**Theorems for free.** From the type alone ([POPL '97 §5.1][k97]; [CEFP §4.4][k10]):
`e : ∀u. num u → num uⁿ` gives `e(k*x) ≈ kⁿ*e(x)`; the differentiation operator satisfies the
higher-order scaling equation

```text
diff h f x  =  (k₂/k₁) · diff (h/k₁) (λx. f(x·k₁)/k₂) (x/k₁)
```

for all `k₁, k₂ > 0` — the type
`∀u₁ u₂. num u₁ → (num u₁ → num u₂) → (num u₁ → num u₂·u₁⁻¹)` _is_ this equation.

**Uninhabited types.** A polymorphic square root `∀u. num u² → num u` has no non-trivial
inhabitant over the arithmetic primitives. Proof: choose the scaling environment supported on
the subgroup of _even_ powers — `ψ(u²ⁿ) = {(r, kⁿr)}`, `ψ(u²ⁿ⁺¹) = {(0,0)}`. Relatedness forces
`f(r)` and `f(kr)` to be related at `{(0,0)}⊥`, i.e. each is `⊥` or `0`; combined with the
full-support scalings, `f` is one of "just nine possible functions", all of them trivial
sign-case dispatchers ([POPL '97 §5.2][k97]).
The operational reading: a root-finder needs an initial estimate of type `num u`, and the only
`num u` it can manufacture is zero. Hence the _repair_: `∀u. num u → num u² → num u` (seed
supplied by the caller) **is** inhabited. Similarly `∀u₁ u₂. (num u₁ → num u₂) → num u₁·u₂`
(a would-be "area under a curve" function, impossible with "no arguments representing bounds")
contains only trivial terms, and a first-order type
`∀u₁…u_m. num µ₁ → ⋯ → num µ_n → num µ₀` has a non-trivial inhabitant **iff** the integer linear
system `A·X = B` of its exponents is solvable — in which case `x₁^z₁·…·x_n^z_n` is an inhabitant
([POPL '97 §5.2][k97]).

**The Pi theorem as a type isomorphism.** With values restricted to positive reals,
`∀u. num u → num u → num u ≅ num 1 → num 1` — one argument can serve as the _unit_ for the
other (`j g = Λu. λx y. x * g(y/x)`). In general ([POPL '97 Theorem 3][k97]):

> for `τ = ∀u₁…u_m. num µ₁ → ⋯ → num µ_n → num µ₀` with exponent matrix `A` (of the arguments)
> and vector `B` (of the result), if `A·X = B` is solvable in integers then
> `τ ≅⁺ num 1 → ⋯ → num 1 → num 1` with `n − rank(A)` dimensionless arguments.

The proof mirrors classical dimensional analysis in matrix algebra: elementary row operations on
`A` are changes of base units, elementary column operations are argument recombinations, and the
**Smith normal form** `U·A·V = diag(s₁…s_r)` reduces the type to a diagonal core whose
remaining arguments cancel. This is exactly [Buckingham's Π-theorem][pi] — `n − rank(A)`
dimensionless groups — restated as: _the space of unit-polymorphic functions at a type is in
bijection with the space of dimensionless functions of its Π-groups_. Kennedy proves it for
first-order types and shows a higher-order instance (the `diff` type is isomorphic to
`(num 1 → num 1) → (num 1 → num 1)`).

**Semantic types and relative definability.** Some code has behaviour more polymorphic than its
inferred type: the natural geometric-mean program is typed `list (num 1) → num 1` (the product
of `n` list elements would need units `uⁿ` — a dependent type), yet it _scales_ like
`∀u. list (num u) → num u`. Rittri's normalization trick — divide the list by `|head|`, apply,
multiply back — produces a term with the polymorphic type and provably the same meaning, the
proof being an application of invariance ([POPL '97 §5.4][k97]; [CEFP Exercise 4][k10]).
Kennedy proposes "semantic type" (`e ∼σ e`) as the right notion for foreign-function
boundaries: the scaling propositions attached to an interface type are exactly the proof
obligations for an implementation in a units-blind language ([CEFP §5][k10]).

### Principal types via abelian-group unification

Inference is Damas–Milner with one substitution: wherever ML unifies syntactically, `MLδ`/F#
must **solve equations modulo `=D`** — equational unification. The ESOP abstract announces
precisely this:

> _"Our approach improves on previous proposals in that dimension types may be polymorphic.
> Furthermore, any expression which is typable in the system has a most general type, and we
> describe an algorithm which infers this type automatically. The algorithm exploits equational
> unification over Abelian groups in addition to ordinary term unification."_
> — Kennedy, _Dimension Types_, abstract ([`kennedy-1994-dimension-types-esop.pdf`][k94])

Why is this not doomed? Equational unification is generally much worse than syntactic
unification: theories are classified **unitary** (a most general unifier exists), **finitary**
(a finite complete set of incomparable unifiers), or **infinitary** ([thesis §3.1][k96]). Even
the innocuous AC1 (associativity + commutativity + identity — a free commutative _monoid_)
becomes finitary once free constants are present: `α·β =U kg·s` has, without inverses, four
incomparable unifiers (`{α:=kg, β:=s}`, `{α:=s, β:=kg}`, `{α:=1, β:=kg·s}`, `{α:=kg·s, β:=1}`)
and no most general one ([CEFP §3.4, Exercise 7][k10]). Adding the **inverse** axiom repairs
this — the single most general solution is `{β := α⁻¹·kg·s}` — and:

> _"We are fortunate that the theory of Abelian groups (AG) with nullary constants is unitary,
> the technical term for 'possesses most general unifiers'. Rather few equational theories have
> this property; one other is the theory of Boolean Rings."_
> — Kennedy, _Types for Units-of-Measure_, §3.5 ([`kennedy-2010-…-cefp.pdf`][k10], p. 19)

Two caveats make "unitary" true, and both are design decisions:

- **Nullary constants only.** AG with free _function_ symbols is finitary: the thesis exhibits
  `x·(y ⊕ z) =D w·(a ⊕ b)` with two incomparable unifiers. The type grammar's stratification is
  what excludes this: "the stratification of the syntax into dimensions and types means that
  these cannot occur inside a dimension expression such as that in the type `real (d₁ → d₂)`.
  This ensures that the problem remains unitary even at the level of types"
  ([thesis §3.1, p. 44][k96]). Base units are nullary constants; nothing else may enter the
  group.
- **Integer exponents.** Over ℚ (Wand–O'Keefe, Goubault) unification is mere Gaussian
  elimination but the solved forms have fractional exponents; over ℤ it is a lattice problem —
  harder, but with dimensionally meaningful answers.

The algorithm ([thesis Fig. 3.1][k96]; [ESOP '94 §5.2][k94]; [CEFP Fig. 5][k10], after
Lankford–Butler–Brady [unverified] and Knuth's linear-Diophantine method [unverified]) reduces
`δ₁ =U δ₂` to matching `δ₁·δ₂⁻¹` against `1`, normalises to
`d₁^x₁···d_m^x_m · B₁^y₁···B_n^y_n` with `|x₁| ⩽ ⋯ ⩽ |x_m|`, and iterates a Euclid-style
elimination:

```text
DimUnify(δ):
  if m = 0 and n = 0:   return identity            (already 1)
  if m = 0 and n ≠ 0:   fail                       (bare base units can't be 1)
  if m = 1:
      if x₁ divides every yⱼ:  return { d₁ ↦ B₁^(−y₁/x₁) ··· B_n^(−y_n/x₁) }
      else fail                                    (e.g. α² =U kg³ has no integer solution)
  else:
      U := { d₁ ↦ d₁ · d₂^(−⌊x₂/x₁⌋) ··· d_m^(−⌊x_m/x₁⌋) · B₁^(−⌊y₁/x₁⌋) ··· }
      return DimUnify(U(δ)) ∘ U
```

The invertible substitution `U` (inverse: flip the exponent signs) rewrites the problem to
`d₁^x₁ · d₂^(x₂ mod x₁) ···` — every other exponent is reduced modulo the smallest one, exactly
Euclid's gcd step run in parallel across the exponent vector. Termination: the smallest absolute
exponent strictly decreases. Correctness ([thesis Theorem 3.1][k96]) rests on the fact that
**invertible substitutions preserve most general unifiers**, so each elimination step is
solution-set-preserving; soundness and completeness of the type-level `Unify` (add one clause:
`Unify(real δ₁, real δ₂) = DimUnify(δ₁·δ₂⁻¹)`) and of the full `Infer` follow the Damas–Milner
template with `=D` threaded through every statement ([thesis Theorems 3.2–3.4][k96]).

**Where the real difficulty lives: not unification, but generalisation.** In ML, generalising a
`let`-bound type is trivial (`ftv(τ) \ ftv(Γ)`). Under a non-regular theory the notion "free in
the environment" is not stable: an equivalent type scheme can have more or fewer free variables
(`∀α.float<α*β⁻¹> -> float<α⁻¹*β>` is equivalent to `∀α.float<α> -> float<α⁻¹>` despite the
"free" `β`). Naive generalisation is sound but **incomplete** — Kennedy exhibits
`fun x -> let d = div x in (d mass, d time)`, typeable in the declarative system but rejected by
the naive algorithm because the generalizable variable is _hidden_ until a change of basis
(`{α := α·β⁻¹}`) reveals it ([CEFP §3.10][k10]). The thesis's repair is `Gen` computed via
`CofB`, an invertible "change of basis" that brings the environment into _free variable reduced
form_ before generalising ([thesis §3.3][k96]); the technical-report preface notes the later
simplification that plain `NGen` suffices once a weaker invariant is shown to be preserved by
inference. The same non-regularity means type schemes have no syntactic canonical form "up to
renaming": ESOP '94 §7.1 already worries that the inferred
`∀d₁d₂. [d₁] real list → [d₂d₁⁻¹] real list → [1] real` and the "natural"
`∀d₁d₂. [d₁] real list → [d₂] real list → [1] real` are equivalent but not alpha-convertible.
The thesis resolves canonicity — a scheme corresponds to an integer exponent **matrix**, scheme
equivalence to row equivalence over ℤ, and `Simplify` computes the unique **Hermite normal
form** of that matrix ([thesis §3.3, Appendix B][k96]) — while "which representative reads most
naturally" remains informal to this day. The summary table of the thesis (Fig. 8.1) is the
cleanest statement of the whole delta: syntactic equivalence → semantic `=D`; alpha-equivalence
of schemes → Hermite normal forms; `ftv(Γ)` → essential variables + change of basis; syntactic
unification → unitary AG-unification; "well-typed programs don't go wrong" → "well-dimensioned
programs don't go wrong, so erase dimensions at run time".

---

## Structural anatomy

### What structure is primary?

A **typed λ-calculus**, not a quantity algebra. The objects are programs and their types; the
morphism-like entities are substitutions (on unit variables) and, semantically, the scaling
relations. The free abelian group of units is _embedded_ in the type grammar as an indexed
family — [Appendix B of the thesis][k96] makes the algebra explicit: dimensions form a free
`ℤ`-module, a dimension type `real δ₁ → ⋯ → real δ_n` is an integer matrix (columns = arrows,
rows = variables), substitutions are square integer matrices, scheme equivalence is
row-equivalence, and canonical forms are Hermite matrices. (Compare [Hart][hart], who also puts
matrices of dimensions at the centre — but as _values_, dimensioned matrices, where Kennedy's
matrices are purely static descriptions of types.) The semantic layer adds the second structure:
the group `hom(G, ℚ⁺)` of admissible scalings, derived — not assumed — from the primitives
(Theorem 2). Notably, **quantities themselves have no algebraic structure at all** in this
formalization: the model of `num µ` is bare `ℚ⊥` for every `µ`. All dimensional structure lives
in types and relations; none lives in values.

### What is a quantity, a unit, a dimension, a kind?

- **Quantity** — a typed value `r : num µ`: a rational number whose unit exists only statically.
  In the explicit calculus `Λδ` the operational semantics briefly materialises dimensioned reals
  `⟨r, δ⟩`, but the erasure theorem shows evaluation never depends on `δ` ([thesis §5.4][k96]).
  There is deliberately no "magnitude × unit" pairing at run time — the opposite pole from
  [Whitney's][whitney] quantity structures, where the quantity is the primary object.
- **Unit** — a unit variable. The design collapses the base/variable distinction into
  free/bound:

  > _"Unit variables (ranged over by u) are used both to stand for base units (such as
  > kilograms, metres and seconds) and to express polymorphism through explicit quantification.
  > We will see later that the distinction is really that of free and bound occurrences."_
  > — Kennedy, POPL '97 §3.1 ([`kennedy-1997-…-popl.pdf`][k97])

  A "system of units" is then a value environment for the free unit constants
  (`Γunits = {kg : num kg, m : num m, s : num s}`), and choosing one is exactly choosing an
  interpretation the invariance theorem quantifies over.

- **Dimension** — a class of units, i.e. a class of interconvertible representations:
  "In computer science terms, these can be seen as isomorphic data representations; then the
  notion of dimension is a class of representations" ([POPL '97 §2.1][k97]). The thesis
  sharpens the same idea in ADT language: "a dimension is an abstract data type which 'hides'
  the actual units used (it is a class of units)" ([thesis §1.3][k96]). Whether types are
  indexed by dimensions (thesis) or units (F#) is "mostly a matter of taste" for checking —
  it matters only once multiple units per dimension coexist and conversions are automated
  ([thesis §1.3][k96]; [POPL '97 §2.3][k97]).
- **Kind** — two unrelated senses, and the interesting one is a **silence**. (a) Formally,
  F# has a trivial two-kind system (`type` vs `measure`, the `[<Measure>]` attribute) that
  merely keeps the two sorts of parameters apart ([CEFP §3.6][k10]). (b) In the metrologist's
  sense — quantities of the same dimension but different _kind_ — the thesis explicitly
  acknowledges the phenomenon: "it is not necessarily true that two quantities of the same
  dimension can meaningfully be compared. For example, it usually does not make sense … to
  compare torque with energy" ([thesis §1.1][k96]) — and then provides **no mechanism** for it.
  The type system identifies `N·m` with `J`. This gap is recorded as a finding; the
  quantity-kind hierarchies of [mp-units][mp-units] are the modern attempt to fill it.

### How is dimensional homogeneity expressed?

Twice, and the two are proven to coincide where they overlap. **Statically**, homogeneity _is_
typability: `+`, `-`, `<` demand equal unit parameters, `*`/`/` compose them through the group
operation, and the `(eq)` rule quotients by `=D`, so a well-typed term is exactly a term all of
whose additions and comparisons are homogeneous. **Semantically**, homogeneity is closure under
the scaling family `Eops` — a program is unit-correct iff its observable behaviour is invariant
under every admissible change of units, the airline-check-in example being the canonical
demonstration that an ill-typed comparison (`float<lb>` against `float<cm>`) is precisely a
program whose decision _flips_ under metrication ([CEFP §4.1][k10]). The parametricity theorem
says static implies semantic. The converse fails in interesting ways — that is the "semantic
type" gap (the geometric-mean program) — and the thesis notes the classical caveat that a
dimensionally _inconsistent_ equation can be trivially invariant (`(v − v)(v + t) = 0`), so
invariance and consistency are close but not identical notions ([thesis §1.1][k96]).

### What is a change of units, and what is invariant?

A **scaling environment**: concretely a homomorphism `ψ` from the group of unit expressions into
`(ℝ⁺, ·)` ([thesis §6.4][k96]); in full generality a `ψ_{G,h}` — a subgroup `G` of units on
which scaling is a genuine rescaling `r ↦ h(µ)·r`, degenerate (`{(0,0)}`) elsewhere
([POPL '97 Fig. 5][k97]). Positivity is forced by the observations: `<` can detect a sign flip,
so "it makes no sense for units of measure to be negative or zero" — and if the language's only
comparison were by magnitude, the admissible group would grow to `ℚ \ {0}`
([POPL '97 §4, §7][k97]). Invariant under all such `ψ`: everything observable — boolean and
dimensionless results, hence contextual behaviour of whole programs; equations between scaled
runs (the free theorems); inhabitation and isomorphism structure of types. **Not** invariant:
the raw numerals inside a run, which is the entire point — `40.0` in kilograms and `88.0` in
pounds are the same quantity precisely because a `ψ` maps one run to the other.

### What does it say about addition across dimensions?

The most precise answer of any formalization in this catalog, in three layers:

1. **Statically forbidden**: `+ : ∀u. num u → num u → num u` — there is no rule to apply to
   `x : num u₁` and `y : num u₂` with `u₁ ≠_U u₂`; the compile error is the F# demo
   `error FS0001: The unit of measure 'm' does not match the unit of measure 'm/s ^ 2'`
   ([CEFP §2.1][k10]).
2. **Dynamically meaningful** — and that is exactly why static rejection needs justification. In
   the erased semantics, adding a mass to a length is a perfectly well-defined rational
   addition: nothing goes wrong operationally — no stuck state, no `wrong` value
   ([thesis §5.4][k96]; [CEFP §4.1][k10]). Heterogeneous addition is not _undefined_ or
   _meaningless_ in the model; it is **defined but not invariant**.
3. **The invariance asymmetry explains why multiplication is free and addition is not.** Scale
   factors themselves multiply: the completeness proof shows `*` carries
   `ψ(µ₁) × ψ(µ₂)` into `ψ(µ₁·µ₂)` for _every_ pair of units, because
   `h(µ₁·µ₂) = h(µ₁)·h(µ₂)` is the homomorphism law — the group structure of unit conversions
   absorbs any mixture of dimensions. Addition has no such law: `k₁·r₁ + k₂·r₂` is of the form
   `k·(r₁ + r₂)` for a uniform `k` only when `k₁ = k₂`, i.e. only when both operands scale by
   the _same_ factor — which is what sharing a unit means. So `+` preserves `ψ(µ)` only
   diagonally, and a heterogeneous sum denotes a number whose value depends on the arbitrary
   choice of units — no unit-independent fact about the world corresponds to it. The unique
   exception is the additive identity: `k·0 = 0` for every `k`, which is _the_ semantic reason
   zero (and only zero, among finite values) is unit-polymorphic ([CEFP §4.5][k10];
   [POPL '97 §4][k97]).

In Kennedy's language the survey's central question — _why_ do quantities multiply freely
across dimensions but not add? — receives the answer: **because the group of unit changes acts
multiplicatively, product is equivariant for arbitrary pairs while sum is equivariant only on
the diagonal**. Whether that answer is fundamental or an artefact of choosing multiplicative
scaling as the symmetry is deferred to the [synthesis][comparison].

---

## Expressive power & limits

What the system delivers beyond "reals with attached units" is **unit polymorphism with
inference** — the entire statistics/calculus toolbox (`mean`, `variance`, `diff`, `findRoot`)
gets principal types relating argument and result units with no annotations
([ESOP '94 §3.3][k94]; [CEFP §2.8–2.9][k10]) — plus user-defined unit-parameterised datatypes
(`vector3<'u>`, `complex<'u>`), **polymorphic recursion** at annotated types (the `derivs<'u,'v>`
nested datatype whose tail is `derivs<'u,'v/'u>` — each successive derivative divides the units;
[CEFP §2.11][k10]), and uniquely, the _negative_ results: the type system can **prove code
impossible** (no polymorphic `sqrt` from arithmetic alone) and **certify refactorings** (a
units-metrication tool is semantics-preserving _because_ of the invariance theorem;
[CEFP §5][k10]).

The limits are equally sharp, and mostly deliberate:

- **Fractional and irrational exponents.** Exponents are integers by philosophical choice: a
  dimension like `M^(1/2)` "would suggest revision of the set of base dimensions rather than a
  re-evaluation of integral exponents" ([thesis §1.3][k96]). Consequence: `α² =U kg³` fails
  (`DimUnify`'s divisibility check), `sqrt : ∀u. num u² → num u` cannot be applied to a bare
  `kg` — which Kennedy defends and [Wand & O'Keefe][wo91] permit (their `Q(0.5·i, …)` type).
  Irrational exponents are outside every variant. The production twist: F#'s internal `Measure`
  representation carries `RationalPower` and the solver divides exponents freely over ℚ
  ([`TypedTree.fs` L4696, `ConstraintSolver.fs`][cs-fs]) — see [Mechanization](#mechanization).
- **Value-dependent exponents.** `power : int → real 1 → real 1` — the honest type is the
  dependent `∀d. Π n:int. real d → real dⁿ`, which the system excludes to stay decidable
  ([ESOP '94 §7.2][k94]). Same root cause as the geometric-mean weakness: any exponent computed
  from data (list length, loop count) collapses to dimensionless, recoverable only by the
  normalize-then-rescale idiom.
- **Affine quantities.** Out of scope from the first page: units are assumed "linear with
  origin at zero — it makes no sense to add two amplitudes measured in decibels or to double a
  temperature measured in degrees Celsius" ([thesis §1.3][k96]; ESOP '94 §2.1 calls Celsius/
  Fahrenheit "more complicated" and decibels "even worse"). The scaling model captures only the
  multiplicative part of unit conversion; the translation part (`°C = K − 273.15`, epochs,
  gauge origins) has no counterpart in `ψ`. The [torsor formalization][torsor] is the
  catalog's dedicated treatment of exactly this gap; POPL '97's conclusion and [Atkey
  2014][atkey] show the symmetry-group generalisation that would cover it.
- **Logarithmic quantities** (dB, pH): same failure mode as affine, compounded — the conversion
  is not even affine, and `ln : real 1 → real 1` walls logarithms off from dimensioned
  arguments entirely (correctly, per the classical account — but the system offers no `Level`
  concept either). Silence, explicitly flagged as such in the sources.
- **Angles.** Declared dimensionless on the classical ground that an angle "is just a
  dimensionless ratio of two lengths" ([POPL '97 §2.1][k97]; same argument in
  [ESOP '94 §2.1][k94]) — so
  `sin : real 1 → real 1` accepts any bare number and radians/degrees confusion type-checks.
  F# documents the pragmatic recovery: declare `[<Measure>] type deg` and `rev` with conversion
  members and keep radians as `float<1>` ([CEFP §2.5][k10]) — opt-in, and unsound the moment
  one module opts out.
- **Same dimension, different kind.** Torque vs energy acknowledged and unaddressed (see
  [anatomy](#what-is-a-quantity-a-unit-a-dimension-a-kind) above); `Hz` vs `Bq` likewise
  indistinguishable. The only recourse is minting fresh base units per kind, which then falsely
  forbids legitimate identifications.
- **ML-polymorphism ceilings.** λ-bound variables are monomorphic, so `twice sqr` yields
  `fourth : [1] real → [1] real` instead of `∀d. [d] real → [d⁴] real` — fixing it needs
  intersection types or `Fω`-style dimension operators ([ESOP '94 §7.3][k94];
  [thesis §8.1][k96]). Recursive definitions are monomorphic in their own bodies, so a function
  that swaps argument order across the recursive call (`prodlists`) loses generality; inference
  for dimension-polymorphic recursion is an open decidability question (below).
- **No conversions, no unit systems.** `ft` and `m` "have nothing to do with each other" until
  the programmer writes `3.28084<ft/m>` ([CEFP §2.3][k10]); automatic conversion is left as an
  acknowledged design space ([CEFP §5][k10]). Checking is exact and algebraic; metrology
  (which unit _is_ canonical, what the factor is) is entirely the user's problem — the
  complement of what [UCUM-style catalogs][concepts] provide.

---

## Mechanization

Kennedy's line is unusual in this catalog: the formalization was **born mechanized** and the
decision procedure is its centrepiece.

**Decidability and complexity.** `DimUnify` is Euclid's gcd algorithm generalised to exponent
vectors: each iteration applies one invertible substitution and strictly decreases the smallest
absolute exponent, so the iteration count is bounded as for gcd (Kennedy uses Knuth's
linear-Diophantine solver [unverified — cited from ESOP '94/thesis]); each step is linear in the
normal form. Unification is thus cheap and, the theory being **unitary**, yields a single most
general unifier — this is the entire reason inference scales to a production compiler. The
expensive part is `let`-generalisation (change of basis over the whole environment,
[thesis §3.4][k96]), which is also the part F# elected to simplify: "the current implementation
of F# doesn't actually use the more sophisticated algorithm hinted at in Section 3.10", relying
on annotations for the rare local-`let` cases ([CEFP §5][k10]).

**ML Kit (1994).** The first implementation, an extension of the ML Kit Standard ML compiler:
`dimension M unit kg;` declarations, dimension variables spelled `_a`, concrete types like
`[_a:2] real -> [_a] real` for `sqrt`, and dimension parameters on `datatype` declarations
([ESOP '94 §6][k94]). Already hits the ML-overloading wall (`num*num -> num` defaulting), which
F# later resolves by operator overloading with unit-polymorphic instances.

**F# (the production system).** Covered as a system in [`fsharp-uom.md`][fsharp]; the
compiler internals belong here because they _are_ the algorithm of this page, transposed. In the
pinned tree (`dotnet/fsharp` @ `25c6a37e`):

- `TypedTree.fs` L4696 defines `Measure` with constructors `Var`, `Const`, `Prod`, `Inv`, `One`,
  `RationalPower` — the free-abelian-group signature, plus rational powers.
- `ConstraintSolver.fs` L801 (`UnifyMeasures`) reduces `ms₁ =U ms₂` to
  `UnifyMeasureWithOne (Measure.Prod(ms₁, Measure.Inv ms₂, …))` — literally the
  `δ₁·δ₂⁻¹ =U 1` reduction of the thesis. `UnifyMeasureWithOne` (L782) partitions unit
  variables into rigid and non-rigid, picks a preferred variable `v` with exponent `e`, and per
  its header comment:

  ```fsharp
  /// - ms has the form v^e * ms' for some non-rigid variable v, non-zero exponent e, and measure expression ms'
  ///   the most general unifier is then simply v := ms' ^ -(1/e)
  ```

  Note what changed from the paper algorithm: exponents are **rationals** internally
  (`DivRational`, `NegRational`), so `e` always divides and the Euclid-style iteration collapses
  to **one elimination step per variable** — Gauss–Jordan over ℚ rather than Hermite reduction
  over ℤ; since F# 4.0, fractional exponents are even admitted in the surface syntax
  ([Gundry 2015][gundry] fn. 21 dates the feature). This is the
  Wand–O'Keefe linear-algebra picture quietly re-adopted _inside_ Kennedy's own compiler, two
  decades on.

- `SimplifyMeasure` (L807) / `SimplifyMeasuresInType` (L839) implement the thesis's
  `Simplify`-style scheme normalisation: walk the type scheme, repeatedly choose a preferred
  generalizable variable, and rewrite by an invertible substitution so the displayed scheme is
  canonical — the production echo of the Hermite-normal-form story (down to the
  result-first/argument-first traversal order controlling which variable "owns" the scheme).

**GHC `uom-plugin` (2015).** [Gundry][gundry] re-implements the same solver as a GHC
typechecker plugin: units are a kind `Unit` with type families for product/inverse, and the
plugin discharges equality constraints "up to the abelian group laws" that GHC's syntactic
solver cannot. The load-bearing theoretical addition: for the plugin's solutions to be sound
_and most general_, the equational theory must be restricted to **free** abelian groups — an
explicit `TORSION-FREE` axiom beyond the AG laws ([Gundry 2015, Fig. 6][gundry]) — since GHC's open
world (user type families at kind `Unit`) would otherwise admit non-free models. Surveyed as a
system in [`haskell-uom-plugin.md`][uom-plugin].

**Library-level encodings (everyone else).** The CEFP notes explain in two sentences why every
non-compiler realization in this tree is fighting the same fire: one can encode units as dummy
type constructors (`UProd<m, UInv<UProd<s,s>>>`), but "the crucial aspect of units-of-measure
that is not captured by this encoding is _equations that hold between syntactically distinct
units_" — `m·s` vs `s·m`, `s·s⁻¹` vs `1` — so every encoding must either canonicalise (fixed
exponent vectors: [Boost.Units][boost], [dimensional][dimensional], [uom][rust-uom]) or witness
the AG laws in proofs ([CEFP §3][k10]; the notes' introduction cites Boost.Units and Buckwalter's
`dimensional` as the "abuse the rich type systems … at some cost in usability" exhibits). The catalog-wide
comparison of these strategies is [`type-system-mechanisms.md`][mechanisms].

**Mechanized metatheory.** The parametricity semantics itself was later formalized — Kennedy,
"Formalizing an extensional semantics for units of measure", WMM 2008 [unverified — cited from
CEFP ref. 10]; the CEFP presentation of the `j ∘ i = id` isomorphism proof marks the semi-formal
steps that the formalization makes rigorous ([CEFP §4.8][k10]).

---

## Open problems & frontier

Kennedy's texts are unusually candid about what remains open; several problems stated in
1994–1997 are still open, and one closed spectacularly.

- **Principal syntax.** Principal _types_ exist, but no notion of the most "natural"
  representative: ESOP '94 §7.1 — "there is no obvious way of choosing a canonical
  representative … I do not know how to formalise this notion". The Hermite normal form
  ([thesis §3.3][k96]) gives a unique canonical matrix, and F# normalises displayed schemes,
  but "natural" (the form a physicist would write) remains unformalised.
- **Dimension-polymorphic recursion.** ML's polymorphic recursion is undecidable to infer
  (Henglein; Kfoury–Tiuryn–Urzyczyn — cited in [ESOP '94 §7.3][k94]); whether the
  _dimension-only_ restriction is decidable is explicitly open — the thesis's comparison table
  ends "Polymorphic recursion undecidable / Dimension-polymorphic recursion **not known**"
  ([thesis Fig. 8.1][k96]). Rittri studied dimension inference under polymorphic recursion
  [unverified — cited from POPL '97 ref. 12 and thesis]; F# sidesteps by requiring full
  annotations ([CEFP §2.11][k10]).
- **Relative definability and full abstraction.** Does every term whose _behaviour_ is
  dimensionally invariant at `σ` have an equivalent term _typed_ at `σ`? Kennedy proves
  instances (geometric mean) and shows that if it holds at all types, quotienting the model by
  the scaling PER yields a model **fully abstract relative to** the underlying cpo semantics —
  "an open problem" ([POPL '97 §5.4, §6][k97]).
- **A general higher-order Pi theorem.** Theorem 3 covers first-order types; the higher-order
  case is demonstrated by example only — "a general result in the style of Theorem 3 is the
  subject of further research" ([POPL '97 §5.3][k97]). A modern reconciliation with the
  classical [Buckingham Π][pi] rank–nullity picture across _all_ types is still missing.
- **Conversions and richer kinds.** Automatic unit conversion — a declaration like
  `[<Measure>] type ft = 0.3048<m>` — opens a design space F# never shipped: do conversions
  lift contravariantly through function types? how do they interact with floating-point
  non-associativity? And
  parameterising over both numeric representation and unit wants measure-to-type type-level
  functions, i.e. a real kind system ([CEFP §5][k10]).
- **Let-generalisation.** The complete-inference story for open type schemes (change of basis)
  was never productionised, and the field moved toward "let should not be generalized"
  (Vytiniotis et al., cited in [CEFP §5][k10]) — the tension between principal types and
  practical inference under equational theories is live in every plugin-style implementation
  ([Gundry 2015][gundry]).
- **From scalings to arbitrary symmetries — the closed conjecture.** POPL '97 ends with:
  physical laws "are also invariant under changes in the coordinate system, given by a
  translation or rotation of the axes. Perhaps this too can be supported by the type system of
  a programming language" ([POPL '97 §7][k97]). This is exactly what happened: Atkey, Johann &
  Kennedy (POPL '13) [unverified — cited from Atkey 2014] built types indexed by geometric
  transformation groups, and [Atkey 2014][atkey] reformulates that system in `Fω` and connects
  it to **Noether's theorem**: a Lagrangian whose _type_ is invariant under a symmetry (e.g.
  `∀y:T(1). C∞(ℝ⟨1,0⟩ × ℝ⟨1,y⟩ × … , ℝ⟨1,0⟩)` — quantification over spatial translations)
  yields its conservation law (momentum, energy, angular momentum) as a **free theorem**.
  Kennedy's rescaling theorem is thereby revealed as the simplest case — symmetry group
  `(ℚ⁺, ·)` — of a general types-as-symmetries programme; how far that programme can absorb
  the affine/torsor and kind problems above is the open frontier this survey tracks.
- **Silences this catalog cares about.** No treatment of quantity _kinds_ (torque/energy), no
  affine or logarithmic scales, no run-time quantity objects, no account of measurement
  uncertainty. Each silence is inherited by every system downstream of Kennedy's design —
  see the [comparison capstone][comparison].

---

## Sources

- M. Wand & P. M. O'Keefe, ["Automatic Dimensional Inference"][wo91], in _Computational Logic:
  Essays in Honor of Alan Robinson_, MIT Press, 1991, pp. 479–486 — dimension inference as
  ML-style unification + Gaussian elimination over ℚ; principal types up to change of basis;
  `newdim` local dimensions. (Quotes transcribed from the local
  `wand-okeefe-1991-automatic-dimensional-inference-lpar.pdf`; OCR ligatures restored.)
- A. Kennedy, ["Dimension Types"][k94], _ESOP '94_, LNCS 788 — the polymorphic dimension type
  system, `DimUnify`, the ML Kit implementation, equivalent-types and dependent-exponent
  problems. (Local artifact `kennedy-1994-dimension-types-esop.pdf`, author copy recovered via
  Wayback.)
- A. Kennedy, [_Programming Languages and Dimensions_][k96], PhD thesis, University of Cambridge
  (submitted Nov 1995), Tech. Report UCAM-CL-TR-391, April 1996 — the full system: `MLδ`/`Λδ`,
  Theorems 3.1–3.4, Hermite normal form, `CofB`, dimension erasure, scaling relations, the
  ML-vs-`MLδ` comparison table (Fig. 8.1), Appendix B's ℤ-module view. (Local artifact
  `kennedy-1996-programming-languages-dimensions-thesis.pdf`.)
- A. Kennedy, ["Relational Parametricity and Units of Measure"][k97], _POPL '97_ — Theorems 1–2
  (parametricity + completeness of `Eops`), free theorems, square-root non-inhabitation, type
  isomorphisms, the Pi theorem for `Λu` via Smith normal form, relative definability and
  relative full abstraction. (Local artifact `kennedy-1997-relational-parametricity-units-popl.pdf`.)
- A. Kennedy, ["Types for Units-of-Measure: Theory and Practice"][k10], CEFP 2009 lecture notes,
  LNCS 6299, 2010 — the F# programmer's tour, the didactic unification/inference presentation,
  unitary-theory discussion, open type schemes, semantics for practitioners, exercises with
  solutions. (Local artifact `kennedy-2010-types-units-of-measure-cefp.pdf`, revised author copy.)
- A. Gundry, ["A Typechecker Plugin for Units of Measure"][gundry], _Haskell Symposium 2015_ —
  AG-unification as a GHC plugin; the torsion-free requirement for most-general solutions.
  (Local artifact `gundry-2015-typechecker-plugin-uom-haskell.pdf`.)
- R. Atkey, ["From Parametricity to Conservation Laws, via Noether's Theorem"][atkey],
  _POPL '14_ — invariance types generalised to geometric symmetry groups; conservation laws as
  free theorems. (Local artifact `atkey-2014-parametricity-conservation-laws-popl.pdf`.)
- [`dotnet/fsharp`][fsharp-repo] pinned `25c6a37e` —
  [`src/Compiler/Checking/ConstraintSolver.fs`][cs-fs] (`UnifyMeasureWithOne` L782,
  `UnifyMeasures` L801, `SimplifyMeasure` L807, `SimplifyMeasuresInType` L839) and
  `src/Compiler/TypedTree/TypedTree.fs` (`type Measure`, L4696). Code comment quoted verbatim.
- Related pages: [theory index][theory-index] · [umbrella][umbrella] ·
  [concepts][concepts] · [free abelian group][fag] · [Buckingham Π][pi] · [Whitney][whitney] ·
  [torsors][torsor] · [Hart][hart] · [type-system mechanisms][mechanisms] ·
  [F# units][fsharp] · [uom-plugin][uom-plugin] · [dimensional][dimensional] ·
  [Boost.Units][boost] · [uom (Rust)][rust-uom] · [mp-units][mp-units] ·
  [comparison][comparison].

<!-- References -->

<!-- Same-tree theory siblings -->

[theory-index]: ./index.md
[fag]: ./free-abelian-group.md
[pi]: ./buckingham-pi.md
[whitney]: ./whitney.md
[torsor]: ./torsor-representation.md
[hart]: ./hart-multidimensional.md
[mechanisms]: ./type-system-mechanisms.md

<!-- Tree umbrella / concepts / comparison -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md

<!-- System deep-dives -->

[fsharp]: ../fsharp-uom.md
[uom-plugin]: ../haskell-uom-plugin.md
[dimensional]: ../haskell-dimensional.md
[boost]: ../cpp-boost-units.md
[rust-uom]: ../rust-uom.md
[mp-units]: ../cpp-mp-units.md

<!-- Primary sources & external -->

[wo91]: https://www.khoury.northeastern.edu/home/wand/papers/dimensions.ps
[k94]: https://doi.org/10.1007/3-540-57880-3_23
[k96]: https://www.cl.cam.ac.uk/techreports/UCAM-CL-TR-391.html
[k97]: https://dl.acm.org/doi/10.1145/263699.263761
[k10]: https://doi.org/10.1007/978-3-642-17685-2_8
[gundry]: https://dl.acm.org/doi/10.1145/2804302.2804305
[atkey]: https://dl.acm.org/doi/10.1145/2535838.2535867
[fsharp-repo]: https://github.com/dotnet/fsharp
[cs-fs]: https://github.com/dotnet/fsharp/blob/25c6a37e/src/Compiler/Checking/ConstraintSolver.fs
