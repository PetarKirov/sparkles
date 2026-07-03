# Dimensions as a Free Abelian Group (`ℤⁿ` / `ℚⁿ`)

The formalization that most typed units-of-measure libraries implement without saying so:
fix a set of base dimensions, let a **dimension** be a vector of exponents over them, write
the vectors multiplicatively (`M·L⁻³`, `L²·M·T⁻²`), and observe that under product and
inverse the dimensions form the **free abelian group** on the base dimensions — `ℤⁿ` when
exponents are integers, `ℚⁿ` after the fractional-power extension. [Kennedy's 1996
thesis][kennedy-thesis] develops the group explicitly and builds ML-style type inference on
top of it; [Jonsson 2020/2021][jonsson-2020] re-derives the same group _semantically_, as the
quotient of a quantity space by "differs by a scalar"; [Zapata-Carratalá 2021][zapata]
inverts the dependency and studies rings and fields _graded by_ a dimension group; and the
[ATOMSLab `LeanDimensionalAnalysis`][lean-repo] development mechanizes the picture in Lean 4,
literally proving a `CommGroup` instance for dimensions-as-exponent-functions and computing
Buckingham's π-count as the corank of an exponent matrix. On this page the group itself is
the subject: its construction, its two `GL`-actions (unit rescaling and basis change), the
π theorem re-read as lattice linear algebra, and what the `ℤ → ℚ` extension buys and breaks.

> [!NOTE]
> This page covers the **dimension group** and its immediate algebra. Neighbouring layers
> get their own pages: the classical π theorem and its history is
> [Buckingham π][buckingham-pi]; Kennedy's type _system_ and abelian-group unification as an
> inference algorithm is [Kennedy's dimension types][kennedy-types]; the readings that put
> **quantities** (not dimensions) at the centre — one-dimensional vector spaces and their
> tensor calculus, torsors of units — are [tensor of lines][tensor-of-lines] and
> [torsor representation][torsor]; Whitney's earlier group-theoretic treatment is
> [Whitney 1968][whitney]; Hart's typed family of fields is
> [Hart's multidimensional analysis][hart]. Zapata-Carratalá's dimensioned rings — fields
> graded by a dimension group — are covered **here**, because they answer "what structure
> must the dimension set carry?" from the inside.

---

## At a glance

| Dimension                   | Dimensions as a free abelian group                                                                                                                                                                                      |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Primary structure           | The **dimension group** `Dim ≅ ℤⁿ` — free abelian group on base dimensions, written multiplicatively; `ℚⁿ` (a `ℚ`-vector space) after the fractional-power extension                                                    |
| Quantity                    | A value _indexed by_ a group element: Kennedy's type `real δ`; Jonsson's fiber element `x ∈ C` for `C ∈ Q/∼`; Lean's `PhysicalVariable dim` structure                                                                   |
| Unit                        | Deferred or derived: Kennedy fixes "some global unit of measure for each base dimension"; Jonsson: a non-zero quantity per dimension, bases of `Q` = systems of base units; Zapata: a monoid section `u : D → R` of `δ` |
| Dimension                   | An element of the group — an exponent vector `(x₁, …, xₙ) ∈ ℤⁿ`, i.e. a normal form `d₁^x₁ ⋯ Bₙ^yₙ`                                                                                                                     |
| Kind                        | **Absent** — the group element is a dimension's whole identity, so torque ≡ energy, `Hz ≡ Bq` (recorded as a finding below)                                                                                             |
| Homogeneity                 | Equality in the group: a law is well-formed iff both sides carry the same element; semantically, invariance under every scaling homomorphism `ψ : Dim → (ℝ⁺, ·)`                                                        |
| Change of units             | Two `GL`-actions: rescaling = homomorphism `ψ : Dim → (ℝ⁺, ·)` on values; base change = automorphism of `ℤⁿ`, an integer matrix with `det = ±1`                                                                         |
| Addition across dimensions  | Outside the structure — the group has no additive operation at all; the four sources make its absence precise in four different ways (see [anatomy](#how-addition-across-dimensions-is-treated))                        |
| Buckingham π                | Lattice linear algebra: π-monomials = `ker A` of the `m×n` exponent matrix; count = `n − rank A`; mechanized as `Matrix.rank` / `LinearMap.ker` in Lean                                                                 |
| Equality decision           | Normalize to exponent vectors and compare — linear time; unique normal forms are the freeness theorem                                                                                                                   |
| Unification (for inference) | Abelian-group unification: **unitary** with free nullary constants, gcd-based `DimUnify` (Kennedy); over `ℚ`, plain Gaussian elimination (Wand & O'Keefe)                                                               |
| Canonical mechanization     | [`LeanDimensionalAnalysis`][lean-repo] (pinned `de263ee`): `instance : CommGroup (dimension B E)` at [`Basic.lean:234`][lean-basic]                                                                                     |
| Origin                      | Implicit since Fourier's exponent bookkeeping; explicit as a group: [Whitney 1968][whitney] (mathematics), [Kennedy 1996][kennedy-thesis] (programming languages), [Jonsson 2020/21][jonsson-2020] (abstract algebra)   |

---

## Primary sources

- **A. J. Kennedy, [_Programming Languages and Dimensions_][kennedy-thesis], PhD dissertation,
  University of Cambridge, 1996** (Technical Report UCAM-CL-TR-391, April 1996; dissertation
  submitted November 1995). The origin of the dimension-group formalization in programming
  languages: §2.1 defines dimension expressions and the congruence `=D` whose axioms "are
  precisely the axioms of Abelian groups", §3.1 develops unitary abelian-group unification
  (`DimUnify`), Chapter 6 defines scaling environments as group homomorphisms `Dim → ℝ⁺`,
  §7.3 restates the π theorem over the exponent matrix, and Appendix B recasts everything as
  `ℤ`-module (integer matrix) linear algebra. **Inspected** — local artifact
  `$PAPERS/kennedy-1996-programming-languages-dimensions-thesis.pdf`. (The earlier ESOP'94
  paper and the F# lineage are covered in [Kennedy's dimension types][kennedy-types].)
- **D. Jonsson, ["An Algebraic Foundation of Amended Dimensional Analysis"][jonsson-2020],
  arXiv:2010.15769v2, December 2020.** Quantity spaces, the congruence `∼`, the theorem that
  `Q/∼` is a finitely generated free abelian group, dimensional matrices as expansions
  relative to a basis, and an amended π theorem (multiple adequate partitions, integer
  exponents with `gcd = 1` normalization). **Inspected** — local artifact
  `$PAPERS/jonsson-2020-algebraic-foundation-dimensional-analysis-arxiv.pdf`.
- **D. Jonsson, ["Magnitudes, Scalable Monoids and Quantity Spaces"][jonsson-2021],
  arXiv:2108.02106v6, 2021 (v6 January 2023).** The systematic algebra: scalable monoids
  over a ring, congruences, tensor products, unit elements; Propositions 3.18–3.25 prove
  `Q/∼` free abelian of finite rank, equicardinality of bases, and the classification of
  quantity spaces by rank. **Inspected** — local artifact
  `$PAPERS/jonsson-2021-magnitudes-scalable-monoids-quantity-spaces-arxiv.pdf`.
- **C. Zapata-Carratalá, ["Dimensioned Algebra: the mathematics of physical
  quantities"][zapata], arXiv:2108.08703v1, August 2021.** Dimensioned sets, dimensional vs
  dimensioned binars, dimensioned rings/fields graded by a dimension monoid/group, units as
  sections, and the power functor building a `ℤ`-graded dimensioned field from a line.
  **Inspected** — local artifact `$PAPERS/zapata-carratala-2021-dimensioned-algebra-arxiv.pdf`.
- **M. P. Bobbin, C. Jones, J. Velkey, T. R. Josephson, ["Formalizing Dimensional Analysis
  Using the Lean Theorem Prover"][bobbin], arXiv:2509.13142v1, September 2025** — the
  companion paper to [`ATOMSLab/LeanDimensionalAnalysis`][lean-repo]. **Inspected** — local
  artifact `$PAPERS/bobbin-2025-formalizing-dimensional-analysis-lean-arxiv.pdf` **plus the
  repository itself**, cloned and pinned to `de263ee` (2025-09-11):
  `DimensionalAnalysis/{Basic,Basic_Multiplicative,Dimensions,ISQ,DimensionalHomogeneity}.lean`.
- **M. Wand & P. M. O'Keefe, ["Automatic Dimensional Inference"][wand-okeefe], in
  _Computational Logic: in honor of J. Alan Robinson_, MIT Press, 1991, pp. 479–486.** The
  `ℚⁿ` variant: dimensions as `N`-tuples of linear number expressions with rational
  coefficients, solved by Gaussian elimination. **Inspected** — local artifact
  `$PAPERS/wand-okeefe-1991-automatic-dimensional-inference-lpar.pdf`.
- **W. D. Curtis, J. D. Logan, W. A. Parker, ["Dimensional analysis and the pi
  theorem"][clp], _Linear Algebra and its Applications_ 47:117–126, 1982.** The rank–nullity
  reading of π used below. **Inspected** — local artifact
  `$PAPERS/curtis-logan-parker-1982-pi-theorem-laa.pdf`.
- Cited **from secondary only** (not inspected; each flagged where used): Whitney 1968
  (paywalled — grounded via the [Whitney page][whitney] and its restatements), Birkhoff's
  π-theorem proof, Lankford–Butler–Brady's abelian-group unification, Rittri's
  semi-unification results, and Goubault's rational-exponent system — all **[unverified],
  as cited in Kennedy's thesis** (§3.1, §3.4–3.5, §7.3).

---

## Formal core

### The dimension group as a syntactic quotient (Kennedy)

Kennedy's thesis (§2.1) starts from raw dimension expressions:

```text
δ ::= d          dimension variables   (d ∈ DimVars)
    | B          base dimensions       (B ∈ DimCons)
    | 1          unit dimension
    | δ₁ · δ₂    dimension product
    | δ⁻¹        dimension inverse
```

and imposes the congruence `=D` generated by exactly four equations — commutativity,
associativity, identity, inverses. This is not an incidental choice of axioms:

> _"Dimensions satisfy certain algebraic properties, namely those of an Abelian group whose
> operation is dimension product. […] Then the set of all dimension expressions quotiented
> by this equivalence forms a free Abelian group."_
> — Kennedy, _Programming Languages and Dimensions_, §2.1, p. 16

Exponentiation `δⁿ` (`n ∈ ℤ`) is defined as iterated product/inverse, and Kennedy notes
that with it "the set of dimensions can be treated as a vector space over the integers, or
more properly, a free `ℤ`-module" (§2.1, p. 16; the module view is developed in his
Appendix B). Two normal-form devices make the group concrete. First the ordered monomial

```text
d₁^x₁ · d₂^x₂ ⋯ dₘ^xₘ · B₁^y₁ · B₂^y₂ ⋯ Bₙ^yₙ ,   xᵢ, yⱼ ∈ ℤ \ {0}, all atoms distinct
```

and second the exponent-extraction function, defined by structural recursion:

```text
exp[δ] : DimVars ∪ DimCons → ℤ

exp[d](v)      = 1 if v = d, 0 otherwise      (dimension variable)
exp[B](v)      = 1 if v = B, 0 otherwise      (base dimension)
exp[1](v)      = 0
exp[δ₁·δ₂](v)  = exp[δ₁](v) + exp[δ₂](v)
exp[δ⁻¹](v)    = −exp[δ](v)
```

### Central theorem: freeness, i.e. unique normal forms

Kennedy states the crux as a one-line "Fact" (§2.1, p. 17): **normal forms are unique** —
`δ₁ =D δ₂` if and only if `exp[δ₁] = exp[δ₂]`. Unfolded, this is the freeness theorem:

**Theorem.** The quotient `Dim = DimExprs/=D` is the free abelian group on
`DimVars ∪ DimCons`; equivalently, `exp` descends to a group isomorphism
`Dim ≅ ⊕_{v ∈ DimVars ∪ DimCons} ℤ` sending the atoms to the standard basis. With finitely
many atoms this is `Dim ≅ ℤⁿ`.

**Proof sketch.** Two directions.

- _`exp` is well-defined and homomorphic._ By the recursion, `exp[δ₁·δ₂] = exp[δ₁] + exp[δ₂]`
  and `exp[δ⁻¹] = −exp[δ]`, so `exp` maps product to pointwise sum. Each generating equation
  of `=D` preserves `exp`: commutativity and associativity because `+` on `ℤ` is commutative
  and associative; `1·δ =D δ` because `exp[1] = 0`; `δ·δ⁻¹ =D 1` because
  `exp[δ] + (−exp[δ]) = 0`. Since `=D` is the congruence _generated_ by these equations,
  `exp` factors through the quotient as a homomorphism into the direct sum (each expression
  mentions finitely many atoms, so the image has finite support).
- _`exp` is injective and surjective on the quotient._ Surjectivity: any finite-support
  vector `(x₁, …, xₘ)` is hit by the monomial `v₁^x₁ ⋯ vₘ^xₘ`. Injectivity: the four axioms
  suffice to rewrite any expression to the ordered normal form — flatten with associativity,
  sort with commutativity, merge repeated atoms into powers, cancel `v^x·v^(−x)` with the
  inverse law, drop `v⁰` with the identity law. The resulting normal form's exponents are
  exactly `exp[δ]` (each rewrite preserves `exp`, and on normal forms `exp` reads off the
  exponents). Two expressions with equal `exp` therefore reach the _same_ normal form, hence
  are `=D`-equal. So `exp` is an isomorphism, and since the atoms map to the standard basis,
  `Dim` is free abelian on them. ∎

Freeness is what makes the formalization _computational_: dimension equality is "normalize
and compare vectors", every dimension has a canonical name, and homomorphisms out of `Dim`
are determined freely by their values on the base dimensions — the fact that underlies both
unit conversion and unification below.

### The semantic counterpart: `Q/∼` (Jonsson)

Kennedy quotients _syntax_; Jonsson obtains the same group from _quantities_. A **scalable
monoid** over a ring `R` is a monoid `Q` with an `R`-action `α·x` satisfying `1·x = x`,
`α·(β·x) = αβ·x`, and `α·xy = (α·x)y = x(α·y)`; a **quantity space** is a commutative
scalable monoid over a field `K` admitting a finite **basis** `E = {e₁, …, eₘ}` such that
every `x ∈ Q` has a _unique_ expansion `x = μ_E(x) · ∏ eⱼ^{W(x)ⱼ}` with `μ_E(x) ∈ K` and
integer exponents ([Jonsson 2020][jonsson-2020], §2). Then:

> _"The relation `∼` on `Q` defined by `x ∼ y` if and only if `α·x = β·y` for some
> `α, β ∈ K` is a congruence on `Q`. The corresponding equivalence classes are called
> dimensions; `[x]` is the dimension that contains `x`. […] The set of all dimensions in
> `Q`, denoted `Q/∼`, is a finitely generated free abelian group with multiplication defined
> by `[x][y] = [xy]` and identity element `[1_Q]`."_
> — Jonsson, _An Algebraic Foundation of Amended Dimensional Analysis_, §2, p. 3

[Jonsson 2021][jonsson-2021] proves this in three steps (Propositions 3.18–3.20): `Q/∼` is
an abelian group (the inverse of `[x]` is `[x̆]⁻¹` for the unit-coefficient representative
`x̆`); the classes `{[e₁], …, [eₙ]}` of a basis for `Q` form a basis for `Q/∼` (uniqueness
of expansions transfers); hence `Q/∼` is free abelian of finite rank. Two corollaries carry
real weight: any two bases of a quantity space are equicardinal (Prop. 3.21 — the "dimension
theorem" for quantity spaces), and **quantity spaces over the same field are isomorphic iff
they have the same rank** (Prop. 3.23) — the dimension group's rank is the _entire_
structural invariant. Each dimension `C ∈ Q/∼` is a one-dimensional `K`-vector space with
its own zero `0_C`; any non-zero `u ∈ C` is a **unit quantity** for `C`, and every `x ∈ C`
is `μ·u` for a unique measure `μ ∈ K` — Maxwell's `q = {q}[q]` recovered as a theorem, per
fiber. (The fiber-by-fiber view is developed further on the
[tensor-of-lines][tensor-of-lines] page.)

### Unit change: two different group actions

The formalization cleanly separates two things called "changing units".

**Rescaling within a basis.** Kennedy (Chapter 6) models a change in the _sizes_ of the base
units as a **scaling environment** `ψ` assigning a positive factor to each base dimension —
e.g. `{M ↦ 2.205}` for kilograms→pounds — extended to all of `Dim` by

> _"the following equations which ensure that `ψ` is a homomorphism between the Abelian
> group of dimensions and the Abelian group `⟨ℝ⁺, ·⟩`."_
> — Kennedy, §6.4, p. 99 (`ψ(1) = 1`, `ψ(δ₁·δ₂) = ψ(δ₁)·ψ(δ₂)`, `ψ(δ⁻¹) = 1/ψ(δ)`)

Freeness makes `ψ` total and unique from its values on generators, and evaluation _is_ unit
conversion: converting a density from `kg/m³` to `lb/ft³` is computing
`ψ(M·L⁻³) = 2.205 · 3.281⁻³` for `ψ = {M ↦ 2.205, L ↦ 3.281}`. Kennedy's conclusion states
the moral outright: the scaling environment "can be viewed as a homomorphism between
elements of the free Abelian group of dimensions and the Abelian group of unit conversions
on the values of base type (the rationals)" (§8.1, p. 122–123).

**Changing the basis itself.** Replacing base dimensions by an equivalent derived set —
`{L, T, M} → {L, T, F}` with `F = MLT⁻²` ([Jonsson 2021][jonsson-2021], Example 3.22) — is an
**automorphism of `ℤⁿ`**. Kennedy's Appendix B works this out as integer matrix algebra:
substitutions are `m×m` integer matrices acting by multiplication, composition is matrix
product, and a substitution is invertible **iff its determinant is `±1`** (p. 134) — i.e.
the base-change group is `GL(n, ℤ)`, generated by the elementary substitutions
`{dᵢ ↦ dᵢ⁻¹}`, `{dᵢ ↦ dⱼ, dⱼ ↦ dᵢ}`, `{dᵢ ↦ dᵢ·dⱼ^x}`. Over `ℚ` the same role is played by
`GL(n, ℚ)`, which is where [Wand & O'Keefe][wand-okeefe] land:

> _"Hence we get a principal type, unique up to change of basis."_
> — Wand & O'Keefe, _Automatic Dimensional Inference_, §4

### Buckingham π as lattice linear algebra

Fix a basis, so `Dim ≅ ℤᵐ`. Given `n` variables with dimensions `D₁, …, Dₙ ∈ Dim`, collect
their exponent vectors as the columns of the `m×n` **dimensional matrix** `A`. The map
sending a tuple of exponents to the dimension of the corresponding power-product,

```text
μ : ℤⁿ → Dim ≅ ℤᵐ,    μ(α₁, …, αₙ) = [D₁^α₁ ⋯ Dₙ^αₙ]
```

is a group homomorphism whose matrix is `A`. A monomial `Q₁^α₁ ⋯ Qₙ^αₙ` is dimensionless
exactly when `Aα = 0` ([Curtis–Logan–Parker][clp], eq. (5)), so the **π-monomials form the
kernel lattice** `Π = ker A ⊆ ℤⁿ`, sitting in the exact sequence

```text
0 ⟶ Π ⟶ ℤⁿ ──A──▶ ℤᵐ
        Π = ker A,   rank Π = n − rank A
```

Rank–nullity gives the counting half of the π theorem — Curtis, Logan & Parker: "among the
`m` dimensional quantities `Q₁, …, Qₘ`, we have shown that `m − r` dimensionless quantities
can be formed, where `r = rank A`" (§2, p. 120–121; their `m` counts the variables — our
`n`) — and a basis of `Π` gives the π-groups themselves. Kennedy states the theorem in exactly these terms (§7.3, p. 112: `n` variables,
`m×n` exponent matrix `A`, `n − r` dimensionless power-products; proof deferred to Birkhoff
**[unverified]**) and uses his dimensional-invariance theorem to derive program-level
analogues. Over `ℤ` rather than `ℝ` one point needs care: `ker A` is a _saturated_ (pure)
sublattice, so it is free of rank `n − rank A` and admits integer bases; Jonsson's amended π
theorem normalizes each row to a distinguished tuple with
`gcd(W_k, W_k1, …, W_kr) = 1` ([Jonsson 2020][jonsson-2020], §5) — the lattice-arithmetic
residue that vanishes over `ℚ`. Computationally, bases of `ker A` and canonical
representatives come from Hermite/Smith normal-form algorithms, the same integer-matrix
toolkit Kennedy uses for type-scheme simplification (Appendix B: his `Simplify` computes the
invertible matrix bringing a type's exponent matrix into **Hermite Normal Form**, p. 137).
Jonsson also proves the dictionary is faithful: a tuple of dimensions is independent iff the
corresponding columns are linearly independent, and "the rank of `[D_ℓi]` is equal to the
rank of `D`" (§5, p. 10–11). The classical statement, its assumptions, and its history live
on the [Buckingham π page][buckingham-pi]; the point here is that once dimensions are `ℤⁿ`,
**the π theorem's combinatorial content is exactly the exact sequence above** — and the
[Lean mechanization](#mechanization) implements precisely this, defining the π-count as
`n - Matrix.rank` and the π-groups as `LinearMap.ker`.

### Dimensioned rings and `G`-graded fields (Zapata-Carratalá)

Zapata-Carratalá turns the picture inside out: instead of building the group from syntax or
quantities, he asks what algebra a set of physical quantities `R` with a **dimension
projection** `δ : R → D` must carry, and lets the group structure of `D` _fall out_. A
**dimensioned ring** is a triple `(R_D, +_D, ·_D)`: addition is _partial_ — defined only
within the fibers ("dimension slices") `R_d = δ⁻¹(d)`, each an abelian group — while
multiplication is total and **dimensioned**: `R_d · R_e ⊆ R_de` for a monoid structure on
`D`, making `δ` a monoid morphism (§3). In graded-algebra language this is a `D`-graded
ring whose every element is homogeneous. Two derivations matter for this survey:

- **Distributivity forces the grading.** Starting from slice-wise addition and a total
  multiplication, demanding `(a + b)·c = a·c + b·c` "whenever it is defined" forces the
  dimension of `a_d · c_f` to depend only on `d` and `f` — i.e. forces multiplication to be
  dimensioned and `D` to be a monoid (§3, p. 9–10). The asymmetry "multiplication crosses
  dimensions freely, addition stays home" is not postulated; it is the unique compatibility
  regime between a partial `+` and a total `·`.
- **Division forces the group.** _"A dimensioned ring `R_D` is called a dimensioned field
  when all non-zero elements are invertible. Note that for this requirement to be consistent
  with the dimension projection `δ : R → D`, the monoid structure on `D` must be a group."_
  (§3, p. 13). Choosing units — a section `u : D → R` of `δ` with `u_de = u_d·u_e`, `u_d ≠ 0`
  — trivializes a dimensioned field: `R_D ≅ R₁ × D` (Proposition 3.4), an ordinary field
  times the dimension group, _non-canonically_. Units may fail to exist globally (his
  Möbius-band example), which is the graded restatement of "there is no canonical unit".

Notably, `D` here need only be an abelian group — **freeness is extra**, imposed exactly
when one chooses base dimensions. His **power functor** (§4) builds the minimal non-trivial
example: for a 1-dimensional vector space ("line") `L`, the set `L^ℤ = ⋃_{n∈ℤ} Lⁿ` of all
tensor powers (`L⁻ⁿ := (L*)^⊗n`, `L⁰ := F`) is a dimensioned field graded by `ℤ` — the rank-1
dimension group — with `Lⁿ ⊗ Lᵐ = L^(n+m)`. This is the bridge to the
[tensor-of-lines][tensor-of-lines] formalization, and the general `R₁ × D` trivialization is
the bridge to the [torsor picture][torsor] (each fiber a torsor over the scalars once a unit
is chosen). Hart's earlier "typed family of fields", which Zapata-Carratalá cites as the
first general theory, has [its own page][hart].

---

## Structural anatomy

### What structure is primary; objects and morphisms

The primary object is the **free abelian group `Dim ≅ ℤⁿ`** itself, written
multiplicatively; equivalently a free `ℤ`-module of finite rank (Kennedy, Appendix B).
Its elements are dimensions; its operations are product and inverse. The morphisms that do
work are: **endomorphisms of `Dim`** = dimension substitutions = `n×n` integer matrices
(Kennedy App. B — inference operates on these); **automorphisms** = base changes =
`GL(n, ℤ)`; and **homomorphisms out of the group** — `ψ : Dim → (ℝ⁺, ·)` for unit rescaling
(Kennedy §6.4), `μ : ℤⁿ → Dim` for power-product formation (the π theorem's matrix). In the
`ℚ`-extension the same roles are played by `ℚⁿ`, `GL(n, ℚ)`, and `ℚ`-linear maps. Jonsson
adds a layer _below_ the group: the quantity space `Q`, a commutative scalable monoid whose
morphisms are `R`-action-preserving monoid maps, with `Dim = Q/∼` a derived invariant.
Zapata-Carratalá adds a layer _around_ it: the category `DimRing` of `D`-graded rings, in
which `D`'s group structure is forced rather than assumed.

### What is a quantity, a unit, a dimension, a kind

- **Dimension** — a group element: an exponent vector, or (Jonsson) a `∼`-congruence class
  of quantities, or (Zapata-Carratalá) a point of the grading group `D`.
- **Quantity** — a value indexed by a group element. Kennedy: a term of type `real δ`
  (numeric value whose meaning is relative to the units chosen for base dimensions).
  Jonsson: a primitive element `x ∈ Q`; each dimension-fiber is a one-dimensional
  `K`-vector space with its own zero `0_C`, and `x = μ·u` holds per fiber once a unit
  quantity `u` is picked. Lean: `structure PhysicalVariable (dim : dimension B V)` carrying
  `value : V` ([Bobbin][bobbin], §4.5) — "a graded structure over a dimension".
- **Unit** — the formalization's soft spot, answered three ways. Kennedy _defers_: "we
  assume some global unit of measure for each base dimension", and — the sharpest line —
  "a dimension is an abstract data type which 'hides' the actual units used (it is a class
  of units)" (§1.3, p. 7). Jonsson _derives_: a unit is any non-zero quantity of a
  dimension; a basis `E` of `Q` is a system of base units and induces a coherent system of
  derived units (`§2`; [Jonsson 2021][jonsson-2021] §3.4–3.5). Zapata-Carratalá _globalizes_:
  a unit is a multiplicative section `u : D → R` of the dimension projection, which may not
  exist (§3).
- **Kind** — **not representable.** The group element is a dimension's entire identity, so
  quantities of equal dimension but different kind (torque vs energy, both `L²MT⁻²`;
  frequency vs radioactivity, both `T⁻¹`) are _identified_. None of the four primary sources
  offers a kind mechanism; Jonsson's historical introduction notes that Greek magnitudes
  "are of different kinds" but his formal system identifies kind with dimension. Recorded as
  a finding: **this formalization has no room for kinds**, which is precisely the gap
  layered systems like `mp-units`' `quantity_spec` hierarchy fill outside the group (see
  [mp-units][mp-units] and [type-system mechanisms][type-mech], and the survey's
  [concepts glossary][concepts] for the VIM's "kind of quantity").

### How dimensional homogeneity is expressed

At the surface: **a law is well-formed iff both sides denote the same group element**, and
the arithmetic signatures enforce it compositionally — Kennedy's primitives type as
`+, − : real d × real d → real d`, `* : real d₁ × real d₂ → real d₁·d₂`,
`< : real d × real d → bool` (§1.3, p. 8), so ill-dimensioned equations are untypable rather
than false. In the Lean mechanization homogeneity claims are literal _equalities in the
group_, proved by rewriting with the group axioms:
`theorem accel_eq_vel_div_time : acceleration B E = velocity B E / time B E`
([`DimensionalHomogeneity.lean:7`][lean-homog]), and "dimensionless" claims equate with the
identity element (`reynolds_eq_dimless`, ibid. line 10). At depth, homogeneity is
**invariance under the scaling action**: Kennedy's dimensional-invariance theorem (Chapter 6) defines the logical relation `R^ψ_{real δ}(r, r′) ⟺ ψ(δ)·r = r′` and proves well-typed
programs related to themselves under every scaling environment `ψ` — a law is homogeneous
iff its truth is preserved by every homomorphism `ψ : Dim → ℝ⁺`. Jonsson's version is the
"covariant scalar representation": a quantity function `Φ : C₁ × ⋯ × Cₙ → C₀` admits
`φ : Kⁿ → K` with `μ_E(Φ(q₁, …, qₙ)) = φ(μ_E(q₁), …, μ_E(qₙ))` _for every local basis `E`_
([Jonsson 2020][jonsson-2020], §2) — and functions without such a representation (his
`Φ_u` counterexample) are exactly the unphysical ones.

### What acts as change of units; what is invariant

Rescaling units is the homomorphism `ψ : Dim → (ℝ⁺, ·)` acting on values fiber-wise
(`r ↦ ψ(δ)·r` at dimension `δ`); changing the base-dimension basis is a `GL(n, ℤ)` (after
`ℚ`-extension, `GL(n, ℚ)`) automorphism acting on exponent vectors; choosing units at all
is, in the graded picture, a trivialization `R_D ≅ R₁ × D`. Invariant under rescaling:
every dimension (types don't move), the truth of well-typed program equivalences (Kennedy's
Chapter 6 parametricity — behaviour "is independent of the units of measure used", §1.6),
the truth of unit-free laws ([Curtis–Logan–Parker][clp] Definition 2), and dimensionless
values (`ψ(1) = 1` — the π-groups are the maximal invariant coordinates, which is the π
theorem's other face). Invariant under base change: the group up to isomorphism, its rank
(Jonsson Prop. 3.21/3.23 — the rank _is_ the quantity space's classifying invariant), the
kernel lattice `ker A` of any dimensional matrix (Jonsson §5: "the basis `E` for `Q/∼` can
be chosen freely"), and hence the π-groups. Kennedy's positivity proviso is part of the
formalization: scale factors live in `ℝ⁺` because comparisons (`<`) would otherwise be
broken by sign flips — "it makes no sense for units of measure to be negative or zero"
(§6.4, p. 98).

### How addition across dimensions is treated

The group itself is silent — **`Dim` carries no additive structure at all**; addition is a
statement about quantities, one level up. The four sources then make the impossibility
precise in four genuinely different ways, which is this page's main comparative finding:

1. **Forbidden by typing, justified by invariance (Kennedy).** `+ : real d × real d → real d`
   simply admits no instance at distinct dimensions; there is no error value, just no type.
   The _reason_ is semantic, not syntactic: the underlying value model is untyped rationals,
   where `3 kg + 2 m` would compute perfectly well — but no dimension type for it survives
   the scaling relation. Kennedy's `div` example makes the criterion explicit: dimensioned
   integer division `int d₁ → int d₂ → int d₁·d₂⁻¹` is rejected _not_ because it can't be
   written but because "it is not dimensionally invariant" (§8.1, p. 120–121). What is
   admissible is exactly what commutes with every `ψ`. (His polymorphic zero — `0 : real d`
   for every `d` — is the deliberate boundary case: one value inhabiting all fibers.)
2. **Outside the signature (Jonsson).** A quantity space is a _multiplicative_ structure;
   addition exists only inside each dimension class, where the class is a one-dimensional
   vector space with its own zero `0_C`. Cross-dimension sums are not "errors" — they are
   not in the algebra's vocabulary. The per-dimension zeros are the sharp edge: there is no
   single `0` shared across dimensions, where Kennedy has one polymorphic `0`.
3. **Total but unspecified (the Lean mechanization).** `dimension.add` is defined via
   Hilbert's choice operator:
   `Classical.epsilon $ fun f => ∀ a b, a = b → f a b = a`
   ([`Basic.lean:87–88`][lean-basic]) — a total, `noncomputable` function about which only
   `a = b → a + b = a` is provable. `length + time` type-checks and denotes _some_ dimension,
   but no theorem can pin down which. Addition across dimensions is thus **underspecified**
   rather than forbidden — a mechanization-driven third answer with real proof-engineering
   consequences (every `simp` lemma about `+` carries an `a = b` hypothesis; the `[Output]`
   of `#eval` is unavailable).
4. **Structurally partial, with distributivity as the "why" (Zapata-Carratalá).** Partial
   addition within slices is taken as _primitive_ (the dimensional abelian group), and the
   interaction axiom is derived: demanding distributivity of a total product over a partial
   sum _forces_ the product to descend to a group operation on dimensions (§3). On this
   reading, "you can multiply across dimensions but not add" is not a physical postulate
   about quantities — it is the only way a partial `+` and a total `·` can coexist in a
   ring-like structure.

No source treats heterogeneous addition as _meaningful-but-partial_ in the sense of
returning a formal sum; that option (direct sums of fibers, `⊕_C C`) belongs to
[Hart's multidimensional analysis][hart] and is deliberately absent here.

---

## Expressive power & limits

### What it buys over "reals with attached units"

- **Canonical names and linear-time equality.** Freeness ⇒ unique normal forms ⇒ dimension
  checking is vector comparison, not term rewriting modulo AC.
- **Dimension polymorphism with principal types.** Because the equational theory is exactly
  abelian groups, unification is **unitary** — Kennedy: _"We are very fortunate in that
  unification is unitary for Abelian groups with free nullary constants (our base
  dimensions). So if a unifier exists at all then there is a unique most general unifier
  from which all others can be derived by instantiation."_ (§3.1, p. 44). Types like
  `sqr : real d → real d²` are inferable, most-generally, by machine — the load-bearing
  property behind [F#'s units of measure][fsharp] and the [`uom-plugin`][uom-plugin]
  (developed on the [Kennedy types page][kennedy-types]).
- **Unit conversion as homomorphism evaluation.** `ψ(M·L⁻³) = ψ(M)·ψ(L)⁻³` — conversion
  factors of derived units need no tables, only the generators' factors.
- **The π theorem as a kernel computation** — see [above](#buckingham-π-as-lattice-linear-algebra);
  dimensional analysis becomes `rank`/`ker` over the exponent lattice, mechanizable in a few
  lines (and mechanized — [`Basic.lean:263–275`][lean-basic]).
- **Scaling theorems for free.** Kennedy's Chapter 7: every dimension type yields a
  parametricity-style theorem; e.g. no non-trivial term has type `∀d. real d² → real d` —
  the language _cannot_ define a dimension-polymorphic square root, a definability result
  invisible to naive unit-tagging.

### `ℤⁿ` vs `ℚⁿ`: what forces the extension, what it costs

**What forces it: roots.** In `ℤⁿ`, squaring `d ↦ d²` embeds the group onto a proper
sublattice (index `2ⁿ`) — most dimensions are not squares, so `sqrt` is typable only at
even vectors: Kennedy's `sqrt : real d² → real d` (§1.3, p. 8). This is sound and
polymorphic but _partial at the type level_: `sqrt` applies to `real (M²)` yet rejects
`real M`. Wand & O'Keefe's `ℚⁿ` system instead types square root as
`√ : Q(i, j, k) → Q(0.5·i, 0.5·j, 0.5·k)`, applicable to `Q(1, 0, 0)` — over `ℚ` the map
`d ↦ d²` is an _automorphism_, so every dimension has roots of every order (`ℚⁿ` is
divisible). Kennedy states both positions and takes a side:

> _"The most important decision is whether or not to allow fractional exponents of
> dimensions. […] The argument in favour is pragmatic: sometimes it is easier to write
> program code which temporarily creates a value whose dimension has fractional exponents.
> In this dissertation the former view prevails, and fractional exponents are not
> considered."_
> — Kennedy, §1.3, p. 7 (the "argument against" being that a dimension such as `M^(1/2)`
> "makes no sense physically" and should prompt "revision of the set of base dimensions")

Practice went the other way. The compiler that industrialized Kennedy's design carries
rational powers in its core measure algebra — F#'s `Measure` type includes
`RationalPower of measure: Measure * power: Rational`
([`TypedTree.fs:4714`][fsharp-typedtree], pinned `25c6a37e`); `mp-units` defines
`sqrt(Dimension auto d)` as `pow<1, 2>(d)` ([`dimension.h:109`][mp-units-dim-h], pinned
`d7b11de`); GNAT's `Dimension_System` aspect stores "an aggregate of rational values for
each" base dimension ([`sem_dim.ads:63`][gnat-ugn], with a dedicated rational-arithmetic
package in `sem_dim.adb`); and the Lean mechanization is parametric from the start —
`dimension B E` for any `CommRing E`, with a heterogeneous power `HPow (dimension B E) E2`
via any scalar action `SMul E2 E` ([`Basic.lean:100–101, 115–117`][lean-basic]), and
[Bobbin][bobbin] §3.2 explicitly permitting `ℚ` while excluding real exponents ("Real
numbers like `√2` and `π` are excluded as powers in dimensional analysis", fn. 1).

**What it costs.** The move `ℤⁿ → ℚⁿ` is a genuine change of category, not a relaxation:

- **Freeness over the base symbols is lost.** `ℚⁿ` is free as a `ℚ`-vector space but _not_
  free abelian as a group (divisible groups never are): base dimensions stop being free
  generators, and the integer-exponent monomial normal form `d₁^x₁⋯Bₙ^yₙ` over them no
  longer exists — normal forms need rational exponents.
- **Divisibility structure trivializes.** "Is this dimension a perfect square?" is
  expressible in `ℤⁿ` (membership in the index-`2ⁿ` sublattice) and _inexpressible_ in
  `ℚⁿ`. Kennedy's definability theorem — no dimension-polymorphic `sqrt` exists — has no
  `ℚⁿ` analogue, because there the type `∀d. real d → real d^(1/2)` is perfectly sensible.
- **The `ℤ`-module subtleties disappear — with their information.** Over `ℤ`, "linearly
  dependent" does not mean "one is a combination of the others": _"Consider, for example,
  the linearly dependent dimensions `d²` and `d³`."_ (Kennedy, Appendix B, p. 133 — neither
  is an integer power of the other, though `d²ˣ·d³ʸ = 1` has non-trivial solutions). AG
  unification must thread gcd arithmetic (Kennedy's `DimUnify` reduces to solving
  `x₁z₁ + ⋯ + xₘzₘ + g = 0` in integers via "Knuth's [algorithm], which is essentially an
  adaptation of Euclid's greatest common divisor algorithm", §3.1, p. 44); over `ℚ` all of
  this collapses into Gaussian elimination (Wand & O'Keefe §4; Kennedy on their system:
  "equations are not necessarily integral, so Gaussian elimination is used to solve them",
  §3.4, p. 62).
- **The type language over-generates.** With arbitrary rational-linear maps as
  substitutions, types like `∀i,j,k. Q(i,j,k) → Q(i, 2j, k)` (square only the length
  exponent) or `Q(i,j,k) → Q(j,i,k)` (swap mass and length) become well-formed — Kennedy:
  "Wand and O'Keefe's types are unnecessarily expressive and can be nonsensical
  dimensionally", though "no expression in the language will be assigned such types" (§3.4,
  p. 62). Freeness over named generators is what kept the type language honest.
- One thing is _gained_ beyond roots: **semi-unification** (needed for polymorphic
  recursion) is decidable over `ℚ`-vector spaces (Rittri, **[unverified], as cited in
  Kennedy §3.5**) while the general abelian-group case was open — see
  [frontier](#open-problems--frontier).

### What it cannot express

- **Affine quantities** (temperature points, calendar dates, gauge pressures). The entire
  semantics is multiplicative — `ψ` acts by scaling, fibers are one-dimensional vector
  spaces through zero. Kennedy flags the boundary himself, in a parenthesis doing a lot of
  work: _"(Of course this assumes that the units are linear with origin at zero—it makes no
  sense to add two amplitudes measured in decibels or to double a temperature measured in
  degrees Celsius)."_ (§1.3, p. 6–7). Affine structure is the [torsor page's][torsor]
  subject; libraries bolt it on outside the group (`quantity_point` in
  [mp-units][mp-units], `absolute` in [dimensional][dimensional], non-multiplicative units
  in [pint][pint]).
- **Logarithmic quantities** (dB, pH, neper). Same parenthesis; formally, `log` maps
  products to sums, so its image cannot live in any fiber. The formalization's only move is
  to confine transcendentals to the identity element — Kennedy types
  `exp, ln, sin, cos, tan : real 1 → real 1` (§1.3, p. 8), and the Lean development defines
  a `relativeOperator` via Hilbert's `ε` that is constrained only on dimensionless input
  ([`Basic.lean:131–132`][lean-basic]). Log-scale _units_ (a ratio plus a reference) are
  outside the group's vocabulary.
- **Angles.** `rad = m/m = 1` in the group: angles collapse into the identity element, so
  `sin` cannot demand an angle and torque (`N·m`) collides with energy (`J`) even in unit
  print-outs. Jonsson is explicit about the residue: a dimensionless quantity "does not
  correspond to a unique number, but to a number that depends on the choice of a quantity
  unit for `[1_Q]`. For example, plane angles can be measured in both radians and degrees."
  ([Jonsson 2021][jonsson-2021], §3.4, p. 21–22) — the fiber over `1` is still a line with a
  choice of unit, but the _group_ cannot distinguish rad from unity. Making angle a base
  dimension is a `GL`-inexpressible change of group (rank `n → n+1`), which is why it stays
  a system-design controversy (see [concepts][concepts] and per-system pages).
- **Same-dimension, different-kind quantities.** Torque vs energy, `Hz` vs `Bq`, luminous
  vs radiant flux: identified, as recorded [above](#what-is-a-quantity-a-unit-a-dimension-a-kind).
  Any fix (Hart's per-kind fields, `mp-units`' `quantity_spec` partial order,
  [au][au]'s distinct unit types) lives strictly outside this formalization.
- **Dimensioned integers / counts.** Kennedy's own limit case: integer `div` fails
  dimensional invariance, so dimensioned integers only support `+`, `−`, `×` — _"So perhaps
  the correct equational theory for dimensions in this case is not that of Abelian groups,
  but of commutative monoids instead, with axioms just for associativity, commutativity and
  identity of dimensions."_ (§8.1, p. 121). The group is calibrated to _fields_ of values;
  weaken the value structure and the right dimension algebra weakens with it.

---

## Mechanization

### `LeanDimensionalAnalysis`: the group, live, with file:line

The [ATOMSLab development][lean-repo] (Lean 4 + Mathlib, pinned `de263ee`) implements this
page's object directly. The paper's summary is accurate to the code:

> _"We define physical dimensions as mappings from base dimensions to exponents, prove that
> they form an Abelian group under multiplication, and implement derived dimensions and
> dimensional homogeneity theorems."_
> — Bobbin, Jones, Velkey & Josephson, _Formalizing Dimensional Analysis Using the Lean
> Theorem Prover_, abstract

The core definition is one line — a dimension _is_ an exponent vector, as a function type
([`Basic.lean:61`][lean-basic]):

```lean
def dimension (B : Type u) (E : Type v) [CommRing E] := B → E
```

with base-dimension systems supplied as type classes (`HasBaseLength`, `HasBaseTime`, …;
`Basic.lean:12–55`), the concrete seven-generator ISQ system as an `inductive` with a
`Fintype` instance ([`ISQ.lean:4–6`][lean-isq]), the identity as the zero vector
(`dimensionless := Function.const B 0`, `Basic.lean:76`), generators as `Pi.single` basis
vectors (`def length … := Pi.single HasBaseLength.Length 1`,
[`Dimensions.lean:12`][lean-dims]), and the group operations as pointwise exponent
arithmetic (`Basic.lean:93–101`):

```lean
protected def mul  : dimension B E → dimension B E → dimension B E
| a, b => fun i => a i + b i
protected def div  : dimension B E → dimension B E → dimension B E
| a, b => fun i => a i - b i

protected def pow {E E2} [CommRing E] [SMul E2 E]: dimension B E → E2 → dimension B E
| a, n => fun i => n • (a i)
```

The abelian-group law is then a proved `instance` — the page's central theorem as a type
class ([`Basic.lean:234`][lean-basic]):

```lean
instance  : CommGroup (dimension B E) where
  mul := dimension.mul
  div := dimension.div
  inv a := dimension.pow a (-1)
  mul_assoc := dimension.mul_assoc
  one := dimensionless B E
  ...
```

A sibling file restates the definition through Mathlib's additive↔multiplicative bridge —
`def dimension (B : Type) (E : Type) [AddCommGroup E] := Multiplicative (B → E)`
([`Basic_Multiplicative.lean:66–67`][lean-basic-mult]) — which is this page's slogan
("exponent vectors, written multiplicatively") as a single application of a Mathlib type
wrapper. Homogeneity theorems are group equalities discharged by rewriting
([`DimensionalHomogeneity.lean:7–14`][lean-homog]), and the **Buckingham-π section**
([`Basic.lean:258–275`][lean-basic]; mirrored at `Basic_Multiplicative.lean:269–287`) is the
exact-sequence reading verbatim:

```lean
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

Three honest observations, load-bearing for the survey:

- **`CommGroup` is proved; freeness is not.** The instance holds for _any_ `CommRing E` —
  including `E = ℚ`, where the group is not free abelian — and the development never states
  or uses a `FreeAbelianGroup` connection, although Mathlib provides the building block
  ([`Mathlib/GroupTheory/FreeAbelianGroup.lean`][mathlib-fag]). The basis property lives
  only implicitly in the `Pi.single` generators. (Mathlib itself has **no** dedicated
  physical-units/dimensional-analysis library — its `Units` are invertible monoid elements;
  this survey's mathlib finding is recorded on the [Lean systems page][lean-page].)
- **The π machinery is definitions, not theorems.** `number_of_dimensionless_parameters`
  and `dimensionless_numbers_matrix` _compute_ the corank and kernel, but no Lean theorem
  connects them to invariance of physical laws — the representation theorem that Jonsson
  proves on paper (his Theorem 1) has no mechanized counterpart here.
- **The `ε`-addition is total-but-opaque** (see [anatomy above](#how-addition-across-dimensions-is-treated)),
  and it renders `+`/`−` on dimensions `noncomputable` — a concrete engineering cost of
  choosing "unspecified" over "untypable" for heterogeneous addition.

### Decision procedures and complexity

| Problem                                 | Procedure                                                                                                                    | Status / cost                                                                                                                |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Dimension equality                      | Normalize to exponent vectors (`exp`), compare                                                                               | Decidable, linear in expression size; in Lean: `funext` + `simp`/`ring_nf` (`evalAutoDim`, `DimensionalHomogeneity.lean:16`) |
| Unification over `ℤⁿ` (with constants)  | Kennedy's `DimUnify` (Fig. 3.1): iterate invertible substitutions driven by the smallest exponent — Euclid/Knuth gcd descent | **Unitary**; sound & complete (Kennedy Thm. 3.1); "Abelian group unification can be done in polynomial-time" (Kennedy §8.1)  |
| Unification over `ℚⁿ`                   | Gaussian elimination on linear exponent equations                                                                            | Decidable, unitary up to basis change (Wand & O'Keefe Thms. 1–2)                                                             |
| π-groups from a dimensional matrix      | `rank` / `ker` over the exponent lattice; integer bases via Hermite/Smith normal form, gcd-normalized rows (Jonsson §4–5)    | Polynomial; mechanized as `Matrix.rank` / `LinearMap.ker` (`Basic.lean:268–275`)                                             |
| Semi-unification over `ℤⁿ` (poly. rec.) | Single inequation: Rittri's algorithm **[unverified], as cited in Kennedy §3.5**                                             | General case **open** (as of Kennedy 1996); over `ℚ` decidable (Rittri, ibid.)                                               |

### Where the picture lives in typed libraries

Nearly every system this survey covers is a realization of `ℤⁿ` or `ℚⁿ` with the group
placed at a different point of the compile/run spectrum; the mechanics are dissected on
[type-system mechanisms][type-mech] and the per-system pages:

| Realization of `Dim`                                | Exponents      | Systems                                                                                                                                 |
| --------------------------------------------------- | -------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Compiler-native measure algebra with AG unification | `ℚ`            | [F# units of measure][fsharp] (`Measure.RationalPower`, `TypedTree.fs:4714`)                                                            |
| Typechecker plugin doing AG unification             | `ℤ`            | [uom-plugin][uom-plugin] (Gundry)                                                                                                       |
| Type-level integer vectors over a fixed basis       | `ℤ`            | [dimensional][dimensional] (closed SI basis), [uom][uom] (`typenum` exponents), [dimensioned][dimensioned]                              |
| Compile-time symbolic exponent expressions          | `ℚ`            | [mp-units][mp-units] (`pow<1, 2>`, `dimension.h:109`), [au][au], [boost-units][boost-units] (`static_rational` exponents, `dim.hpp:43`) |
| Aspect-driven compile-time vectors                  | `ℚ`            | [GNAT `Dimension_System`][gnat] (`sem_dim.ads:63`)                                                                                      |
| Type-level rational exponents in parametric types   | `ℚ`            | [Unitful.jl][unitful]                                                                                                                   |
| Run-time exponent dictionaries/vectors              | numeric        | [pint][pint], [Wolfram/MATLAB][wolfram-matlab]                                                                                          |
| Proof-assistant `CommGroup` instance                | any `CommRing` | [LeanDimensionalAnalysis][lean-page] (`Basic.lean:234`)                                                                                 |
| Library-level D template arithmetic                 | `ℤ`            | [D `quantities` / `units-d`][d-quantities]                                                                                              |

---

## Open problems & frontier

- **`ℤ` or `ℚ` remains genuinely unsettled.** Kennedy's philosophical position (fractional
  exponents "would suggest revision of the set of base dimensions") lost in his own lineage
  — the F# compiler's measure algebra carries `RationalPower` — yet no published account
  reconciles the pragmatics with what the extension destroys (the divisibility structure
  underlying his `sqrt`-indefinability theorem). Each ecosystem re-decides ad hoc; the
  [comparison capstone][comparison] tabulates who chose what.
- **Decidability of abelian-group semi-unification.** Needed for dimension-polymorphic
  recursion. Kennedy's summary still stands as the sharpest statement: single inequation
  decidable (Rittri), the general integral case "is not known", while the `ℚ` case is
  decidable — and it is "not known whether a reduction can be made in the other direction"
  from semi-unification back to inference (§3.5, pp. 64–66). **[Status as of the thesis;
  not re-verified against later literature.]**
- **Where does the group structure come from?** The sources derive different fragments:
  Zapata-Carratalá _derives_ "D is a group" from distributivity + invertibility but allows
  arbitrary abelian `D`; Jonsson _derives_ freeness and finite rank from the existence of a
  basis of quantities; Kennedy _postulates_ the axioms outright. What none of them derives
  is why physical dimension groups should be free of small finite rank — that is exactly the
  choice of base dimensions, and proposals that flex it (angle as a generator, rank-changing
  "revision of the set of base dimensions") have no theory of _which_ group is right.
  [Whitney's page][whitney] and the [concepts glossary][concepts] carry the older and the
  metrological sides of this question.
- **Kinds have no algebra here.** The identification kind = group element is the
  formalization's most consequential coarsening (torque ≡ energy). Layered fixes exist in
  systems (`quantity_spec` in [mp-units][mp-units]) and in [Hart's][hart] per-kind fields,
  but there is no accepted account of what algebraic object refines a free abelian group
  with a kind structure — a live gap this survey returns to in the
  [comparison][comparison].
- **The right dimension algebra depends on the value algebra.** Kennedy's commutative-monoid
  remark for dimensioned integers (§8.1) generalizes to a frontier question: for values in
  a semiring/non-field, which quotient of the free _commutative monoid_ on base dimensions
  is appropriate, and what replaces unitary AG unification there? No source pursues it.
- **Mechanization gaps.** In the only live proof-assistant development: freeness unproved
  (no bridge to Mathlib's `FreeAbelianGroup`), the π _theorem_ (as opposed to the π
  _computation_) unstated, and the `ε`-based addition unable to support computation.
  Jonsson's representation theorem — the strongest paper-level result in this formalization
  — has no mechanized counterpart anywhere. Meanwhile his own amended π (multiple adequate
  partitions yielding a _set_ of representations, challenging the tacit "one `Ψ` suffices"
  assumption — [Jonsson 2020][jonsson-2020] §1) has yet to be absorbed by any library or
  mechanization; see [Buckingham π][buckingham-pi].

---

## Sources

- A. J. Kennedy, [_Programming Languages and Dimensions_][kennedy-thesis], PhD dissertation,
  University of Cambridge, Tech. Report UCAM-CL-TR-391, 1996 — dimension expressions and
  `=D` (§2.1), free-abelian-group quotient and unique normal forms (p. 16–17), unitary AG
  unification and `DimUnify` (§3.1), rational-exponent trade-offs (§1.3, §3.4–3.5), scaling
  environments as homomorphisms (§6.4), π theorem over the exponent matrix (§7.3),
  `ℤ`-module/integer-matrix view incl. `GL`-invertibility and Hermite forms (Appendix B).
  (Quotes verified against a `pdftotext -layout` extraction of the local PDF.)
- D. Jonsson, ["An Algebraic Foundation of Amended Dimensional Analysis"][jonsson-2020],
  arXiv:2010.15769v2, 2020 — quantity spaces, `Q/∼` free abelian (§2), dimensional matrices
  and column-independence dictionary (§5), gcd-normalized π tuples, amended π theorem.
- D. Jonsson, ["Magnitudes, Scalable Monoids and Quantity Spaces"][jonsson-2021],
  arXiv:2108.02106v6, 2021 — scalable monoids; Props. 3.18–3.25 (free abelian of finite
  rank, basis correspondence, rank classification); radian/degree residue of `[1_Q]` (§3.4).
- C. Zapata-Carratalá, ["Dimensioned Algebra: the mathematics of physical
  quantities"][zapata], arXiv:2108.08703v1, 2021 — dimensioned rings/fields (§3), units as
  sections and `R_D ≅ R₁ × D` (Prop. 3.4), distributivity forcing the grading, power
  functor `L^ℤ` (§4).
- M. P. Bobbin, C. Jones, J. Velkey & T. R. Josephson, ["Formalizing Dimensional Analysis
  Using the Lean Theorem Prover"][bobbin], arXiv:2509.13142v1, 2025 — the companion paper;
  and the [`ATOMSLab/LeanDimensionalAnalysis`][lean-repo] repository pinned at `de263ee`:
  [`Basic.lean`][lean-basic] (`dimension` def :61, `CommGroup` instance :234, Buckingham-π
  defs :258–275), [`Basic_Multiplicative.lean`][lean-basic-mult] (`Multiplicative (B → E)`
  :66–67), [`Dimensions.lean`][lean-dims], [`ISQ.lean`][lean-isq],
  [`DimensionalHomogeneity.lean`][lean-homog]. Code excerpts quoted verbatim.
- M. Wand & P. M. O'Keefe, ["Automatic Dimensional Inference"][wand-okeefe], in
  _Computational Logic: in honor of J. Alan Robinson_, MIT Press, 1991 — `Q(n₁, …, n_N)`
  types, rational exponents, Gaussian elimination, principal types up to change of basis.
- W. D. Curtis, J. D. Logan & W. A. Parker, ["Dimensional analysis and the pi
  theorem"][clp], _Linear Algebra Appl._ 47:117–126, 1982 — `Aα = 0` characterization of
  dimensionless monomials, `m − r` count, unit-free laws.
- Mechanization context: [`Mathlib/GroupTheory/FreeAbelianGroup`][mathlib-fag] (the unused
  building block); [`mp-units` `dimension.h`][mp-units-dim-h]; [F# `TypedTree.fs`][fsharp-typedtree];
  [GNAT dimensionality analysis][gnat-ugn].
- Related deep-dives: [theory index][theory-index] · [umbrella][umbrella] ·
  [concepts][concepts] · [Whitney][whitney] · [Buckingham π][buckingham-pi] ·
  [tensor of lines][tensor-of-lines] · [torsor representation][torsor] ·
  [Kennedy's dimension types][kennedy-types] · [Hart][hart] ·
  [type-system mechanisms][type-mech] · [comparison][comparison].

<!-- References -->

<!-- Same-tree theory siblings -->

[theory-index]: ./index.md
[whitney]: ./whitney.md
[buckingham-pi]: ./buckingham-pi.md
[tensor-of-lines]: ./tensor-of-lines.md
[torsor]: ./torsor-representation.md
[kennedy-types]: ./kennedy-types.md
[hart]: ./hart-multidimensional.md
[type-mech]: ./type-system-mechanisms.md

<!-- Tree umbrella / concepts / comparison -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md

<!-- System deep-dives -->

[fsharp]: ../fsharp-uom.md
[uom-plugin]: ../haskell-uom-plugin.md
[dimensional]: ../haskell-dimensional.md
[uom]: ../rust-uom.md
[dimensioned]: ../rust-dimensioned.md
[mp-units]: ../cpp-mp-units.md
[boost-units]: ../cpp-boost-units.md
[au]: ../cpp-au.md
[d-quantities]: ../d-quantities.md
[pint]: ../python-pint.md
[unitful]: ../julia-unitful.md
[gnat]: ../ada-gnat-dimensions.md
[lean-page]: ../lean-mathlib-units.md
[wolfram-matlab]: ../wolfram-matlab.md

<!-- Primary sources & external -->

[kennedy-thesis]: https://www.cl.cam.ac.uk/techreports/UCAM-CL-TR-391.pdf
[jonsson-2020]: https://arxiv.org/abs/2010.15769
[jonsson-2021]: https://arxiv.org/abs/2108.02106
[zapata]: https://arxiv.org/abs/2108.08703
[bobbin]: https://arxiv.org/abs/2509.13142
[wand-okeefe]: https://www.semanticscholar.org/paper/18222b4f2f646982c16771b74343a5515dec3dfd
[clp]: https://doi.org/10.1016/0024-3795%2882%2990229-4
[lean-repo]: https://github.com/ATOMSLab/LeanDimensionalAnalysis
[lean-basic]: https://github.com/ATOMSLab/LeanDimensionalAnalysis/blob/de263eed945693058ef2b8a1fa56c2ec5642ea7a/DimensionalAnalysis/Basic.lean
[lean-basic-mult]: https://github.com/ATOMSLab/LeanDimensionalAnalysis/blob/de263eed945693058ef2b8a1fa56c2ec5642ea7a/DimensionalAnalysis/Basic_Multiplicative.lean
[lean-dims]: https://github.com/ATOMSLab/LeanDimensionalAnalysis/blob/de263eed945693058ef2b8a1fa56c2ec5642ea7a/DimensionalAnalysis/Dimensions.lean
[lean-isq]: https://github.com/ATOMSLab/LeanDimensionalAnalysis/blob/de263eed945693058ef2b8a1fa56c2ec5642ea7a/DimensionalAnalysis/ISQ.lean
[lean-homog]: https://github.com/ATOMSLab/LeanDimensionalAnalysis/blob/de263eed945693058ef2b8a1fa56c2ec5642ea7a/DimensionalAnalysis/DimensionalHomogeneity.lean
[mathlib-fag]: https://leanprover-community.github.io/mathlib4_docs/Mathlib/GroupTheory/FreeAbelianGroup.html
[mp-units-dim-h]: https://github.com/mpusz/mp-units/blob/d7b11de/src/core/include/mp-units/framework/dimension.h
[fsharp-typedtree]: https://github.com/dotnet/fsharp/blob/25c6a37e/src/Compiler/TypedTree/TypedTree.fs
[gnat-ugn]: https://gcc.gnu.org/onlinedocs/gnat_ugn/Performing-Dimensionality-Analysis-in-GNAT.html
