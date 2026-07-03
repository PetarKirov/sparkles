# Torsors, weights, and the scaling torus

The representation-theoretic reading of dimensional analysis: the group of global unit
rescalings is a **torus** `(ℝ⁺)ⁿ` — one multiplicative factor per base dimension — and a
quantity of dimension vector `d ∈ ℤⁿ` is precisely an object that transforms under the
**character** (weight) `d` of that torus. Dimensional homogeneity of a physical law becomes
**equivariance** under the torus action; "dimensionless" becomes "weight zero"; and the set
of possible _units_ of any one dimension is not a group but a **torsor** — a set the group
acts on freely and transitively, with no distinguished identity. [John Baez's "Torsors Made
Easy"][baez] is the primary source for what a torsor is and why unit-like choices (voltage
ground, quantum phase, calendar dates) are torsorial; [Terence Tao's 2012 blog
post][tao] develops the weight-space picture explicitly and connects it to torsors at both
ends of the post; and [Zapata-Carratala 2021][zapata] is the load-bearing published
development, rebuilding commutative algebra itself around a partial, slice-wise addition
(**dimensioned rings**) and proving that a choice of units is exactly a trivialization
`R_D ≅ R₁ × D`. [Jonsson 2021][jonsson]'s **scalable monoids** give the same "scaling acts
on magnitudes" content in a one-sorted universal-algebra idiom and are treated here as the
comparison foil.

> [!NOTE]
> This page covers the _group-action_ layer of the survey: what acts, on what, and what is
> invariant. Division of labour with the sibling pages: **this page owns** the torsor
> concept (Baez), the scaling-torus/weight-space reading of dimensional analysis,
> Zapata-Carratala's dimensioned algebra, Jonsson's scalable monoids, and Tao's closing
> torsor variant. **[Tensor of lines][tensor-of-lines] owns** Tao's 2012 post as a
> formalization — the abstract one-dimensional lines composed by `⊗` and duals, the
> parametric model developed in tandem with them, the dictionary theorem between the two,
> hybrid quantities and the convex-hull criterion, the structure-group ladder of kinds —
> together with Janyška–Modugno–Vitolo's positive spaces. Results owned there are
> cross-referenced below, not restated; how the two pictures relate is set out under
> [Relation to the tensor-of-lines picture](#relation-to-the-tensor-of-lines-picture). The
> discrete skeleton `ℤⁿ` that indexes the weights is the subject of [free abelian group of
> dimensions][free-abelian-group]; and the classical invariance theorem that this picture
> reframes (every equivariant law factors through weight-zero combinations) is
> [Buckingham π][buckingham-pi]. Where this page states standard representation-theoretic
> glue that no local source spells out, it is marked `[exposition]` rather than attributed.

---

## At a glance

| Dimension                  | Torsors, weights & the scaling torus                                                                                                                                                                            |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Primary structure          | A group action: the **scaling torus** `(ℝ⁺)ⁿ` acting on parametrised quantities ([Tao][tao]); algebraically, a **dimensioned ring/field** `R_D` fibred over a monoid of dimensions ([Zapata-Carratala][zapata]) |
| Quantity                   | A family `x = x_{M,L,T}` obeying a power-law transformation — a vector of **weight** `d` — or an element `a_d` of the dimension slice `R_d`                                                                     |
| Dimension                  | A **character/weight** of the torus (exponent vector `d`); in dimensioned algebra, a point of the dimension monoid `D`, i.e. a slice `R_d = δ⁻¹(d)`                                                             |
| Unit                       | A point of a **torsor**: an element of `R_d^×` (any non-zero element serves); a whole unit _system_ is a multiplicative section `u : D → R` of the dimension projection                                         |
| Homogeneity of laws        | **Equivariance** under the torus action; verifiable at a _single_ choice of units (Tao's transfer principle)                                                                                                    |
| Dimensionless              | Weight `0` — literally invariant under all rescalings; the **dimensionless slice** `R₁` (an ordinary ring/field)                                                                                                |
| Central theorem            | A choice of units **trivializes**: `R_D ≅ R₁ × D` ([Prop 3.4][zapata]) and the power ring of `k` lines `≅ F × ℤᵏ` ([Thm 4.1][zapata]) — always non-canonically                                                  |
| Addition across dimensions | Partial (slice-wise) by algebraic necessity — distributivity _forces_ multiplication to act on dimensions ([Zapata-Carratala][zapata]); or total-but-**hybrid** with no single weight ([Tao][tao])              |
| One-sorted alternative     | **Scalable monoids / quantity spaces**: a monoid with a ring scaling action, dimensions as orbits, addition _derived_ from unit elements ([Jonsson][jonsson])                                                   |
| Canonical sources          | [Baez 2009][baez] (torsor pedagogy); [Tao 2012][tao] (weight spaces, structure groups); [Zapata-Carratala 2021][zapata] (dimensioned algebra); [Jonsson 2021][jonsson] (scalable monoids)                       |

---

## Primary sources

- **John Baez, ["Torsors Made Easy"][baez], web essay, December 27, 2009.** The
  primary source for the torsor concept as used throughout this page: the definition
  (free + transitive action, unique "ratio"), the physics examples (energy zero, voltage
  ground, quantum phase), the everyday examples (calendar dates, musical notes,
  antiderivatives' `+C`), and the affine-space moral. **Inspected in full** — the local
  capture `$REPOS/papers/units-of-measure/baez-torsors-made-easy-web.html` is the complete
  essay; all quotes below are transcribed from it.
- **Terence Tao, ["A mathematical formalisation of dimensional analysis"][tao], _What's
  New_ (blog), December 29, 2012.** Used here for the group-action half of the post:
  dimensional parameters `M, L, T` ranging over `ℝ⁺`, the structure group `(ℝ⁺)³`,
  quantities-of-dimension as power-law families, the explicit _weight space_ terminology,
  the equivariance reading of dimensional consistency, hybrid quantities (in brief),
  non-toral structure groups (`GL₃(ℝ)`, `E(2)`, Poincaré, diffeomorphism and gauge
  groups), and the two torsor remarks bracketing the post. The post's other half — the
  abstract tensor-of-lines model, the dictionary theorem between the two pictures, and
  the convex-hull criterion for hybrid inequalities — is developed on
  [tensor of lines][tensor-of-lines] and only cross-referenced here. **Inspected in
  full** — the local capture
  `$REPOS/papers/units-of-measure/tao-2012-formalisation-dimensional-analysis-blog.html`
  includes the comment thread; formulas were recovered from the WordPress LaTeX image
  `alt` attributes. Every Tao claim on this page was verified to appear in the capture.
- **Carlos Zapata-Carratala, ["Dimensioned Algebra: the mathematics of physical
  quantities"][zapata], arXiv:2108.08703, August 2021.** The modern algebraic development
  and this page's load-bearing published treatment: dimensioned sets, dimensional vs
  dimensioned binary operations, dimensioned rings/fields/modules/algebras, units as
  monoid sections, the trivialization propositions, and the **power functor** from the
  category `Line` of 1-dimensional vector spaces to dimensioned rings. **Inspected in
  full** via `pdftotext -layout` of
  `$REPOS/papers/units-of-measure/zapata-carratala-2021-dimensioned-algebra-arxiv.pdf`.
- **Dan Jonsson, ["Magnitudes, scalable monoids and quantity spaces"][jonsson],
  arXiv:2108.02106 (v6, January 2023).** The alternative algebraicization of "scaling acts
  on magnitudes": a scalable monoid is a monoid with a compatible ring action, dimensions
  are commensurability orbits, and addition is a _derived_ operation. **Inspected** (the
  definitional core §§2–3) via `pdftotext -layout` of
  `$REPOS/papers/units-of-measure/jonsson-2021-magnitudes-scalable-monoids-quantity-spaces-arxiv.pdf`.
- Cited from within the above but **not inspected here** (with one exception):
  [Janyška–Modugno–Vitolo][jmv]'s semi-vector spaces — the 2007 preprint is pinned
  locally and is a primary source of [tensor of lines][tensor-of-lines]; for this page
  only Note 2.3 (the `ℝ⁺`-torsor structure of positive spaces) and the §3.1 definition
  of a unit as a semi-basis were verified directly against the local capture, and the
  2010 _Acta Appl. Math._ journal version is cited via Zapata-Carratala's introduction
  `[unverified]`; Hart's 1980s–90s work, which
  Zapata-Carratala credits as "the first efforts in developing a general mathematical
  theory of physical quantities" (see [Hart's multidimensional analysis][hart]); the
  Baez–Dolan ["Doctrines of Algebraic Geometry"][baez-dolan] notes characterising physical
  quantities as _line objects_ `[unverified]`; and Vysoký's graded-manifold formalism
  ([arXiv:2105.02534][vysoky] `[unverified]`), which Zapata-Carratala's §8 compares to
  dimensioned algebra.

---

## Formal core

### Torsors (Baez)

For a group `G`, a `G`-**torsor** is a set `X` with an action of `G` — `1x = x` and
`(g₁g₂)x = g₁(g₂x)` — satisfying one extra axiom that separates torsors from arbitrary
actions:

> _"The special thing that makes a group action be a **torsor** is this: for any two
> elements x₁ and x₂ of our torsor there exists a unique group element g with g x₁ = x₂."_
> — Baez, ["Torsors Made Easy"][baez] (local capture, definition section)

The unique `g` is the **ratio** `x₂/x₁` (or, additively, the difference `x₂ − x₁`). The
action is thus _free_ (uniqueness) and _transitive_ (existence) `[exposition:
terminology]`. The operational consequence is Baez's additive-language summary:

> _"But you can't add elements of a G-torsor X. Instead, you can add an element of G to an
> element of X and get another element of X. You can also subtract two elements of X and
> get an element of G."_ — Baez, ["Torsors Made Easy"][baez]

and the two slogans: _"An affine space is like a vector space that has forgotten its
origin"_ and _"A torsor is like a group that has forgotten its identity."_ Baez's physics
examples are all unit-like or origin-like choices: energies and voltages live in
`ℝ`-torsors (only differences are real numbers — the electrical _ground_ convention is an
arbitrary base-point choice); quantum phases live in a `U(1)`-torsor (only _relative_
phases are unit complex numbers); calendar dates and musical notes are `ℤ`-torsors;
antiderivatives of a fixed function form an `ℝ`-torsor (the `+C`); positions form a torsor
of the vector space of displacements. The structure theorem — trivial to prove, load-bearing
everywhere below — is:

> _"Any group G is a G-torsor, and every other G-torsor is isomorphic to G - but **not
> canonically!**"_ — Baez, ["Torsors Made Easy"][baez]

**Proof sketch** (Baez's own): pick any `x₁ ∈ X` and "declare it to be the identity"; the
map `X → G` sending `x₂` to the unique `g` with `g x₁ = x₂` is well defined (torsor axiom),
injective (freeness) and surjective (transitivity), hence a bijection intertwining the
actions — but it depends on the arbitrary choice of `x₁`. ∎

### The scaling torus and weight spaces (Tao)

Tao's **parametric model** postulates dimensional parameters — for the `M, L, T` system,
three of them — ranging "freely and independently among the positive real numbers `ℝ⁺`,
thus the parameter space (or **structure group**) here is given by the multiplicative
group `(ℝ⁺)³`" ([Tao][tao], §1). A _dimensionful quantity_ is a family `x = x_{M,L,T}`
indexed by the parameters; it _has_ a dimension precisely when the dependence is a power
law:

```text
Structure group (the scaling torus):    G = (ℝ⁺)ⁿ        one ℝ⁺ factor per base dimension
                                        (Tao: (ℝ⁺)³ with coordinates M, L, T)

x has dimension MᵃLᵇTᶜ  ⟺   x_{M,L,T} = x̃ · M⁻ᵃ L⁻ᵇ T⁻ᶜ   for some number x̃    (Tao (1))

(negative exponents because (1) is a PASSIVE change of units, not an active change of x)
```

(The worked examples, the model's extension to dimensionful sets, functions, and
integrals, and the transfer principle's proof sketch are developed on
[tensor of lines][tensor-of-lines].) Dimensionless quantities are the constant families —
the weight-zero case `a = b = c = 0`. The representation-theoretic identification is
explicit and verbatim:

> _"In the language of representation theory, the collection of dimensionful quantities of
> dimension MᵃLᵇTᶜ is a weight space of the structure group (ℝ⁺)³ = {(M,L,T): M,L,T ∈ ℝ⁺}
> of weight (a,b,c). One can indeed view dimensional analysis as being the representation
> theory of groups such as (ℝ⁺)³ …"_ — [Tao][tao], §1 (formulas restored from the capture's
> LaTeX `alt` text)

`[exposition]` The standard glue Tao leaves implicit: the continuous characters
(1-dimensional representations) of the torus `(ℝ⁺)ⁿ` are exactly the power laws
`(λ₁,…,λₙ) ↦ λ₁^(d₁) ⋯ λₙ^(dₙ)`, one for each real exponent vector `(d₁,…,dₙ) ∈ ℝⁿ` — so
the character group of the scaling torus is `ℝⁿ`, and the integer dimension vectors `ℤⁿ`
of ordinary dimensional analysis form a sublattice of it. Multiplying quantities multiplies
characters, i.e. _adds_ weights; the [free abelian group of dimensions][free-abelian-group]
is the character lattice of the scaling torus. Tao's own exponents are deliberately
arbitrary reals (his convex-hull analysis of hybrid inequalities quantifies over
`(a,b,c) ∈ ℝ³`), and his model also contains parameter dependences with _no_ weight at
all — the contrived `L^{sin(M+T)}` "does not have any specific dimension attached to it"
([Tao][tao], §1).

Two torsor remarks bracket the post, both genuinely present in the capture. Near the start:
"it would be slightly more natural to use a parameter space which was a torsor of the
structure group, rather than the structure group itself; we discuss this at the very end of
the post." And at the very end, after the abstract model of one-dimensional ordered vector
spaces `V^M`, `V^L`, `V^T` (the [tensor-of-lines][tensor-of-lines] picture) has been set
up:

> _"One way to avoid this (which was alluded to previously) is to interpret M, L, T not as
> scalars in ℝ, but rather as elements of the ℝ-torsors V^M, V^L, V^T respectively. With
> this modification to the parametric framework, the reference units M₀, L₀, T₀ can now be
> omitted."_ — [Tao][tao], closing section (formulas restored from LaTeX `alt` text)

That is: the "value" of a dimensional parameter is itself a torsorial choice, not a number;
numbers only appear after an arbitrary reference unit turns the torsor into the group. Tao
immediately names the price — recorded under Open problems & frontier below. The same
`V^M, V^L, V^T` are, on [tensor of lines][tensor-of-lines], the primitive carriers: there
the passive law `(1)` is _derived_ from basis change on the lines ("is of course just
(1)", in the dictionary theorem's proof), whereas here it is the postulated torus action.

### Dimensioned rings and units as sections (Zapata-Carratala)

Zapata-Carratala starts from the observed algebra of working physicists — "Addition can
only be performed between quantities specified by the same unit of measurement … addition
is otherwise undefined", while "Multiplication can be performed between any two arbitrary
physical quantities" ([Zapata-Carratala][zapata], §2.1) — and rebuilds algebra so that this
is structure, not folklore:

> _"From a mathematical point of view, the set of physical quantities is R × Zⁿ with
> addition only partially defined in the first argument and multiplication defined as a
> direct product in both arguments. The Zⁿ component corresponds to the types of physical
> quantities and the domains of partial addition are precisely the subsets of matching
> type."_ — [Zapata-Carratala][zapata], §2.1 (`pdftotext` extraction, p. 4–5)

The machinery, in his own terms:

```text
Dimensioned set:      a surjection  δ : A → D          D = "set of dimensions"
                      slices  A_d := δ⁻¹(d)            (a_d denotes an element with δ(a) = d)

Dimensional binar:    a ∗ b defined ONLY within a slice  (δ(a) = δ(b) = δ(a ∗ b))
                      — addition-like: a family of ordinary operations indexed by D
Dimensioned binar:    a ∗ b TOTAL, mapping slices to slices:  A_d ∗ A_e ⊆ A_{d·e}
                      — multiplication-like: D itself acquires an operation and
                        δ becomes a morphism  (A, ∗) → (D, ·)

Dimensioned ring (R_D, +_D, ·_D):
    (R_D, +_D)   a dimensional abelian group          (partial, slice-wise +)
    (R_D, ·_D)   a dimensioned (commutative) monoid   (total ·; D becomes a monoid)
    (a + b)·c = a·c + b·c   whenever defined          (distributivity)
    R₁ := the slice over the monoid identity          ("dimensionless slice" — an ordinary ring)

Unit (choice of units):  a section  u : D → R  of δ  with  u_{de} = u_d · u_e  and  u_d ≠ 0_d
                          — a multiplicative SPLITTING of the monoid surjection δ
Dimensioned field:        every non-zero element invertible   (forces (D, ·) to be a GROUP)
```

Two structural points deserve emphasis. First, the direction of explanation is unusual:
the fact that dimensions themselves multiply (`D` is a monoid) is _derived_, not assumed —
see [Addition across dimensions](#addition-across-dimensions) for the distributivity
argument. Second, units are global _sections_, and sections can fail to exist: taking the
Möbius band as a dimensioned ring over the circle, "we find an explicit example of a
dimensioned ring that does not admit units, since they would correspond to global
non-vanishing sections of a non-trivialisable vector bundle"
([Zapata-Carratala][zapata], §3). Unit existence is a triviality condition, exactly as for
principal bundles — Baez's fiber-of-a-principal-`G`-bundle example ("what it actually _is_,
is a `G`-torsor") is the same geometry.

### Central theorem: a choice of units is a trivialization

The page's central theorem is Zapata-Carratala's Proposition 3.4 together with its
concrete realisation, Theorem 4.1. In a dimensioned field, every non-zero element `a_d`
induces **slice-wise multiplication** bijections `a_d· : R_e → R_{de}` (inverse:
multiplication by `1/a_d`), each an isomorphism of the slices' additive groups by
distributivity. Then:

> _"These maps allow to prove a general result that confers a role to choices of unit on
> dimensioned fields similar to that of a trivialization of a fibre bundle."_ —
> [Zapata-Carratala][zapata], §3 (`pdftotext` extraction, p. 13)

**Proposition 3.4 (units trivialize).** Let `(R_D, +_D, ·)` be a dimensioned field. A
choice of units `u : D → R` induces an isomorphism of dimensioned fields `R_D ≅ R₁ × D`,
where `R₁ × D` is the _product_ dimensioned field (numeral, dimension-tag) with
`(r,d)·(s,e) = (rs, de)` and slice-wise `+`.

**Proof sketch** (following the paper):

```text
Φ_u : R₁ × D → R_D           Φ_u(r, d) := u_d · r          (slice-wise multiplication by u_d)

bijective:   inverse  Φ_u⁻¹(a_d) := u_{d⁻¹} · a_d          (D is a group; u_{d⁻¹} inverts u_d)
additive:    each Φ_u|_{R₁ × {d}} : R₁ → R_d  is an abelian-group isomorphism  (slice-wise mult.)
multiplicative (u is a monoid morphism):
    Φ_u((r₁,d)·(r₂,e)) = Φ_u((r₁r₂, de)) = u_{de}·r₁·r₂ = (u_d·r₁)·(u_e·r₂) = Φ_u(r₁,d)·Φ_u(r₂,e)   ∎
```

**Theorem 4.1 (the power functor realises physics).** For the category `Line` of
1-dimensional vector spaces over a field `F` (morphisms: invertible linear maps, which the
paper calls **factors** — "a unit-free conversion factor"), tensor powers

```text
Lⁿ := L ⊗ ⋯ ⊗ L  (n > 0)        L⁰ := F        L⁻ⁿ := (L*)⊗ⁿ        Lⁿ ⊗ Lᵐ = Lⁿ⁺ᵐ

power of L               :=  ⋃_{n ∈ ℤ} Lⁿ                          dimension set  ℤ
power ring of L₁, …, L_k :=  ⋃ L₁^{n₁} ⊗ ⋯ ⊗ L_k^{n_k}             dimension group ℤᵏ
```

assemble into a functor `Line → DimRing`; each power is a dimensioned _field_; a choice of
non-zero `u ∈ L^×` induces a choice of units `n ↦ uⁿ` and hence a (non-canonical)
isomorphism with `F × ℤ`; and for `k` base lines with chosen units `uᵢ ∈ Lᵢ^×`, the induced
`U : ℤᵏ → R`, `(n₁,…,n_k) ↦ u₁^{n₁} ⋯ u_k^{n_k}` yields the power ring `≅ F × ℤᵏ`
([Zapata-Carratala][zapata], §4). The paper closes the loop explicitly: "We thus recover
the explicit algebraic structure of physical quantities identified in Section 2.1 from the
standard practice in dimensional analysis." Note the domain of the functor: `Line` is
exactly the carrier category of the [tensor-of-lines][tensor-of-lines] picture, so
Theorem 4.1 is the survey's formal bridge between that page and this one — it assembles
the lines and their tensor powers (that page's primitives) into a dimensioned field (this
page's object), on which unit choices then act torsorially (next paragraph).

This is Baez's non-canonical-isomorphism theorem industrialised: `F × ℤᵏ` (numeral +
exponent vector, the naive "reals with attached units") is what a quantity algebra looks
like _after_ an arbitrary choice; the invariant object is `R_D`, and the choice is a point
of a torsor. Concretely `[exposition]`: in a dimensioned field, for any two non-zero
`a_d, b_d` in the same slice there is a _unique_ non-zero dimensionless `r = b_d · (1/a_d)
∈ R₁^×` with `b_d = r · a_d` — existence and uniqueness are exactly Baez's torsor axiom, so
the non-zero part of every slice `R_d^×` is an `R₁^×`-torsor, and two unit systems
`u, u′ : D → R` differ by a unique monoid morphism `c : D → R₁^×` (a character!). For
`D = ℤⁿ` and `R₁ = ℝ` restricted to positive elements, the group of such characters is
`(ℝ⁺)ⁿ` — the scaling torus reappears as precisely the group that acts freely and
transitively on coherent unit systems. Zapata-Carratala never uses the word "torsor"; this
paragraph is standard mathematics layered on his Propositions 3.4/4.1.

### The scalable-monoid alternative (Jonsson)

Jonsson algebraicizes the same "scaling acts on magnitudes" intuition without any fibration
apparatus — one sorted structure, one total multiplication, and a ring action:

```text
Scalable monoid over a ring R:   a monoid (X, ∗, 1_X)  +  scaling action  ω : R × X → X  with
    1 · x = x        α · (β · x) = αβ · x        α · xy = (α·x)y = x(α·y)     (Def 2.1)
    — "an algebra without an additive group": keep (c) bilinearity, drop addition entirely

Commensurability:    x ∼ y  ⟺  α·x = β·y  for some α, β ∈ R
Orbitoid (dimension): an equivalence class of ∼   (orbits R·x may overlap; ∼ transitivises ≈)
Unit element for C:   u ∈ C  generating (every x ∈ C is λ·u)  and faithful (λ·u = λ′·u ⟹ λ = λ′)
Derived addition:     x + y := (ρ + σ)·u    where x = ρ·u, y = σ·u          (Def 2.35;
                      well defined independently of which unit element u is used — Lemma 2.34)
```

Proposition 2.36: a non-trivial orbitoid possessing a unit element is a **free module of
rank 1** over `R` — so a scalable monoid whose orbitoids all have unit elements "is the
union of disjoint isomorphic free modules of rank 1 over a non-trivial commutative ring, a
result that may be compared to definitions of systems of quantities in terms of unions of
one-dimensional vector spaces by Quade and Raposo" ([Jonsson][jonsson], §2.6) — the bridge
to [tensor of lines][tensor-of-lines]. A **quantity space** is a commutative scalable
monoid over a field with a finite basis of invertible elements (unique expansion
`x = µ · ∏ᵢ eᵢ^(kᵢ)`); its monoid of dimensions `Q/∼` is then a free abelian group of rank
`n` (Prop 3.20), each dimension is a 1-dimensional vector space (Prop 3.9), and _every_
non-zero quantity is a unit quantity for its dimension (Prop 3.7). Jonsson also never says
"torsor", but Definition 2.32's two conditions on a unit element — generating and faithful —
are exactly transitivity and freeness of the scalar action on the orbitoid `[exposition]`.
The character transformation law appears as his change-of-basis formula for measures
(Prop 3.15):

```text
basis E = {e₁, …, eₙ}   rescaled to   E′ = {λ₁·e₁, …, λₙ·eₙ}     (λᵢ ≠ 0):

    µ_{E′}(x) = ( λ₁^(−k₁) ⋯ λₙ^(−kₙ) ) · µ_E(x)        for  x = µ_E(x) · ∏ᵢ eᵢ^(kᵢ)
```

— numerically identical to Tao's passive law `(1)`: the measure of a weight-`k` quantity
transforms under the character `−k` of the rescaling `(λ₁,…,λₙ)`.

---

## Structural anatomy

### Primary structure — objects and morphisms

Each source takes a different structure as primary, and the differences are the content:

- **Baez**: the primary structure is a **group action** `G × X → X` subject to the
  free-and-transitive axiom. Objects: `G`-torsors; morphisms (implicit): `G`-equivariant
  maps. There is deliberately _no_ algebra on `X` itself — that absence is the point.
- **Tao (parametric)**: the primary structure is a **family indexed by the structure
  group** — a quantity is a function of the parameters `(M,L,T) ∈ (ℝ⁺)³`, and all
  operations are applied pointwise per parameter choice. The structure group is explicitly
  generalisable: `GL₃(ℝ)` for frame-dependent vectors, `E(2)` for points vs displacements,
  the Poincaré group ("the principle of special relativity can be interpreted as the
  assertion that all physical quantities transform cleanly with respect to this group
  action"), diffeomorphism and gauge groups. Dimensional analysis is the abelian,
  rank-`n`-torus rung of a ladder of representation theories.
- **Zapata-Carratala**: the primary structure is a **surjection** `δ : A → D` ("dimensioned
  set") and operations classified by how they interact with it — the category `DimSet` with
  commutative-square morphisms, then `DimRing`, `DimMod`, dimensioned algebras, up to
  dimensioned Poisson algebras. The group action is _recovered_ (slice-wise multiplication
  by invertibles), not postulated.
- **Jonsson**: the primary structure is a **variety of universal algebras** — one carrier
  set, operations `∗`, `1_X`, and a unary `ω_λ` per ring element, with equations. Orbits,
  quotients, tensor products, and homomorphisms all come from general universal algebra;
  the fibration over dimensions is _derived_ as the quotient `X → X/∼`.

### Relation to the tensor-of-lines picture

[Tensor of lines][tensor-of-lines] and this page formalize the same phenomena from
opposite ends. The local sources support three precise bridges between them — no more
than these are claimed here:

- **The units of one line form a torsor.** For Janyška–Modugno–Vitolo's positive spaces
  the statement is verbatim: "The scalar multiplication s : ℝ⁺ × U → U turns out to be a
  free and transitive action of the group (ℝ⁺, ·) on the set U" ([JMV][jmv], Note 2.3 —
  verified against the local capture). For the signed slices of a dimensioned field it is
  this page's derivation from [Proposition 3.4][zapata] above: `R_d^×` is an
  `R₁^×`-torsor. And Tao's closing move says it for his own lines: reinterpret `M, L, T`
  "as elements of the ℝ-torsors V^M, V^L, V^T".
- **A chosen basis vector of the line = a point of the torsor.** Tao refuses to
  "designate a preferred unit in these spaces (which would identify each of them with
  ℝ)"; JMV define a unit as "a scale k ∈ S, regarded as a semi-basis of the scale space
  S" (§3.1, verified locally); Baez picks a torsor point — "declare it to be the
  identity". These are one act described at three levels of structure `[exposition]`, and
  [Zapata-Carratala's Theorem 4.1][zapata] is where it becomes a theorem: a single
  non-zero `u ∈ L^×` induces the unit system `n ↦ uⁿ` and the trivialization `≅ F × ℤ`.
- **The scaling torus acts on the tensor powers.** Two unit systems differ by a unique
  character `c : D → R₁^×` (derived above from Prop 3.4), and for `D = ℤⁿ` the positive
  characters form `(ℝ⁺)ⁿ` — the scaling torus acts freely and transitively on unit
  systems for the power ring of `n` lines. Parametrically the same torus action is Tao's
  law `(1)`, which the dictionary theorem on [tensor of lines][tensor-of-lines] derives
  from basis change on the lines.

The two pictures are **not** interchangeable, and what each takes as primary is the
genuine difference:

- **Carriers first vs action first.** The tensor-of-lines picture takes the _carriers_ as
  primary — lines closed under `⊗` and duals, with no group in the signature; a change of
  units is, abstractly, not an operation on anything (the gauge freedom appears only once
  a dictionary to numbers is set up). The torsor/weight picture takes the _group and its
  action_ as primary — Tao's parametric structure group, Baez's `G`, Jonsson's scaling
  action — and recovers the carriers as weight spaces, slices, or orbitoids;
  Zapata-Carratala goes furthest, deriving even the action from the fibration `δ` and
  distributivity.
- **Zero and sign.** A line contains `0` — Tao is "careful to keep the origins 0 … of
  each of these vector spaces … distinct from each other" — but no torsor does: the
  scaling action fixes `0`, so freeness fails on any carrier containing it
  `[exposition]`. Accordingly units must be non-zero by fiat (`u_d ≠ 0_d`,
  Zapata-Carratala §3) or the carrier zero-free from the start (JMV's positive spaces).
  A line is strictly more structure than its torsor of units: torsor, plus zero, plus
  slice-wise addition `[exposition]`.
- **Is the torsor packaging a third formalization?** [Tensor of lines][tensor-of-lines]
  deliberately leaves this question to this page, and the answer splits. _Within Tao's
  post_, no: he deflates his own torsor variant as a re-parametrisation whose price means
  "one may as well work entirely in the abstract setting instead". But the action-first
  developments this page assembles — dimensioned rings, scalable monoids — are
  free-standing axiomatizations with their own primitives and theorems (trivializations,
  derived addition), not re-descriptions of the lines; the survey keeps the two pages
  separate for that reason.

### Quantity, unit, dimension, kind

| Notion    | Tao (parametric)                                                   | Zapata-Carratala                                                                 | Jonsson                                                                        | Baez                                                          |
| --------- | ------------------------------------------------------------------ | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------- |
| Quantity  | family `x_{M,L,T}` transforming by a power law (weight vector)     | element `a_d` of a slice of a dimensioned ring                                   | element of a quantity space                                                    | element of a `G`-torsor (for origin-like quantities)          |
| Dimension | the **weight** `(a,b,c)` — a character of the torus                | element `d` of the dimension monoid `D`; equivalently the slice `R_d`            | **orbitoid** `[x]` — a commensurability class; `Q/∼` is free abelian           | the group `G` itself (implicitly: which `G` acts)             |
| Unit      | a reference choice `M₀,L₀,T₀`; better, a point of a torsor `V^M` … | a multiplicative **section** `u : D → R`, `u_d ≠ 0` (may not exist globally)     | **unit element**: a generating, faithful `u ∈ C`; systems: dense+sparse+closed | a chosen base point of the torsor ("declare it the identity") |
| Kind      | — (see below)                                                      | — (silent; `D` is arbitrary, so a finer monoid _could_ split kinds, undeveloped) | **same kind ⟺ commensurable** — an explicit, radical identification            | — (silent)                                                    |

On _kind_, Jonsson is the only one of the four to commit, and he commits to the collapse:
"we introduce a seemingly more radical idea: quantities are of the same kind if and only if
they are commensurable" ([Jonsson][jonsson], §2.3). Under this definition torque and energy
(both `M L² T⁻²` in the classical dimension group) are the _same kind_ — a genuine finding
about this formalization's resolution, recorded as a limit below. Tao is formally silent on
the word "kind" but supplies the mechanism the others lack: **enlarging the structure
group** splits same-dimension quantities by transformation law — positions vs
displacements under the Euclidean group `E(2)` (laws `(8)`/`(9)`), vectors vs covectors
under `GL₃(ℝ)`, and onward up the ladder catalogued on [tensor of lines][tensor-of-lines].
The `E(2)` case is the one that matters here: position + displacement = position while
position + position is of neither kind — the torsor/group distinction (Baez's
positions/velocities) re-derived inside the parametric model as a _representation_
distinction.

### Dimensional homogeneity as equivariance

Tao states the identification directly — the abstract model admits "only … those operations
which are 'dimensionally consistent' or invariant (or more precisely, **equivariant**) with
respect to the action of the underlying structure group" ([Tao][tao], introduction). A law
relating quantities is dimensionally homogeneous iff it is stated between objects of a
single weight and is preserved by every rescaling; a hybrid statement fails to transform
"according to a single group action". Equivariance buys the **transfer principle**: "to
verify a dimensionally consistent statement between dimensionful quantities, it suffices to
do so for a single choice of the dimension parameters `M,L,T`" (stated with its proof
sketch on [tensor of lines][tensor-of-lines]) — Tao's worked example being
`E = mc²`: verify it in Planck-style units where `c = 1` (where it degenerates to the
dimensionally _inconsistent_ `E = m`), and equivariance propagates it to all unit systems;
but having spent the consistency one cannot transfer back ([Tao][tao], §2). In Jonsson the
same principle appears arithmetically: equal quantities have equal exponent vectors
(Lemma 3.6), and "this is the essence of the principle of dimensional homogeneity
formulated by Fourier" ([Jonsson][jonsson], §3.2). In Zapata-Carratala homogeneity is
enforced syntactically — an expression is well-formed only if all its `+`-joined terms
carry the same dimension subscript, and his notation "reflects the dimensioned structure
explicitly so that we can keep track of the consistency of expressions" (§2.2); laws are
morphism-level statements in `DimRing`, automatically slice-respecting. None of the four
sources states the [Buckingham π theorem][buckingham-pi] in this language; the missing
bridge (equivariant functions of quantities are functions of the weight-zero invariants) is
exactly what that sibling page's sources supply — recorded here as a silence.

### Change of units and its invariants

- **Tao**: a change of units is a point of the structure group acting _passively_: the
  numeral of a weight-`d` quantity is multiplied by the character `−d` of the rescaling
  (equation `(1)`; "the presence of the negative signs in (1) … is describing the effect of
  a passive change of units rather than an active change of the object"). Invariant:
  weight-zero quantities — and _relations_ between quantities that are equivariant.
- **Zapata-Carratala**: a change of units is a change of _section_ `u ↦ u′`, equivalently a
  change of trivialization `R_D ≅ R₁ × D`; between two base lines it is a `Line`-morphism, a
  **factor** ("a unit-free conversion factor"). Invariant: the dimensioned ring `R_D`
  itself, its dimensionless slice `R₁`, and everything functorial in it. All algebraic
  operations "are compatible with conversion factors that allow change between units of the
  same kind" (§2.1) — compatibility is built into the definitions.
- **Jonsson**: a change of units is a change of basis `E ↦ E′ = {λᵢ·eᵢ}`; measures
  transform by `∏ᵢ λᵢ^(−kᵢ)` (Prop 3.15). Invariant: the measures of the dimensionless
  orbitoid — "For every `x ∈ [1_Q]`, `µ_E(x)` does not depend on `E`" (Prop 3.16), which he
  flags as the hinge of the π theorem (Remark 3.17).
- **Baez**: a change of units _is the group element itself_ — the ratio of two torsor
  points. Invariant: ratios/differences, i.e. the `G`-valued pairings. His temperature coda
  adds the twist that both origin and scale can be torsorial at once: "As soon as we pick
  units of temperature, temperatures are elements of an R-torsor. When absolute zero was
  discovered, this R-torsor was revealed to be R itself" — and before picking units,
  temperatures live "on a line whose symmetries include not just translations but also
  dilations", needing "a more sophisticated concept than that of 'torsor' allowing both
  translations and dilations whenever you start with a ring."

### Addition across dimensions

The four sources give four distinct, precise answers to why quantities multiply freely
across dimensions while addition does not — this page reports them without reconciling
them (that is [comparison][comparison]'s job).

**Zapata-Carratala: partial by definition, and distributivity is why multiplication is
total.** Addition is a _dimensional_ binar — defined only within slices, "otherwise
undefined", mirroring practice. The non-obvious theorem-shaped observation is the converse
direction: given slice-wise addition, asking for _any_ distributive law forces the
multiplication to be a _dimensioned_ binar, i.e. forces dimensions themselves to compose:

> _"Therefore, if we are to demand distributivity as generally as possible, the
> multiplicative operation must map transitively between dimension slices, in other words,
> the dimension of a_d · c_f only depends on d and f."_ — [Zapata-Carratala][zapata], §3
> (`pdftotext` extraction, p. 9; subscripts inlined)

So in dimensioned algebra the monoid structure on `D` — the very existence of a
"multiplication of dimensions" — is _explained_ by the partiality of addition plus
distributivity, rather than both being posited independently.

**Tao: defined, but hybrid — and provably useless rather than ill-formed.** In the
parametric model everything is a family of reals, so any two quantities can be added
pointwise. The sum simply fails to lie in any single weight space: if `x` and `y` have
different exponent vectors, "the sum x+y or difference x−y, while still defined as a
dimensionful quantity, no longrer [sic] has any single dimension" ([Tao][tao], §1) —
`[exposition]` in representation-theoretic terms the sum lives in the direct sum of two
weight spaces and transforms by no single character. Tao then quantifies exactly how much
law-like content hybrids retain — his convex-hull criterion for hybrid _inequalities_,
developed with its AM–GM witness on [tensor of lines][tensor-of-lines] — whence "one
cannot bound a positive quantity of hybrid dimension by a quantity with a single
dimension", which "helps explain why we almost never see such hybrid dimensional
quantities appear in a physical problem". Addition across dimensions is thus neither
forbidden nor meaningless in this model: it is _equivariance-breaking_, and equivariance
is where the physics lives.

**Baez: for torsors, addition does not exist at all.** The torsor answer applies to the
_affine_ layer (energies, positions, dates): "there's no good reason you'd want to _add_
the day of your dentist appointment and Christmas day". Two torsor points subtract to a
group element; they do not add. This is an answer about origin-relative quantities of a
_single_ dimension, complementary to the exponent-mismatch answers above — a silence worth
recording: Baez's essay never discusses adding across _dimensions_ (his `G` is one group at
a time).

**Jonsson: addition is not primitive, so there is nothing to forbid.** A scalable monoid
has no addition in its signature. Sums are _constructed_ (Def 2.35) inside one orbitoid
from a unit element, and Lemma 2.34 shows the construction is independent of which unit
element is chosen. Across orbitoids the construction has no input data — `x + y` for
incommensurable `x, y` is not "rejected"; it was never defined. Of the four, this is the
most radical position: the partiality of addition is an artefact of addition being derived
structure.

---

## Expressive power & limits

**What the picture handles that naive "reals with attached units" cannot:**

- **Non-canonicity as a theorem.** `F × ℤᵏ` — a numeral and an exponent vector — is exactly
  the naive representation, and the trivialization theorems say it is _correct after a
  choice of units_ and canonical never. Everything unit-choice-independent factors through
  `R_D`; everything else is bookkeeping about a torsor point. The naive model cannot even
  state this distinction.
- **Affine quantities natively.** Temperature zero, voltage ground, energy origin, epochs
  and dates (`ℤ`-torsors!), quantum phase (`U(1)`) — Baez's examples are precisely the
  quantities the exponent-vector formalisms of [Kennedy][kennedy-types] and
  [Hart][hart] leave out. The torsor layer is _the_ formal home for them: point − point =
  delta, point + delta = point, point + point undefined. Baez's temperature story even
  captures ontology updates — discovering absolute zero "revealed" the torsor to be the
  group.
- **Kinds via bigger structure groups.** Tao's `E(2)` example distinguishes position from
  displacement — two same-dimension quantities — by their transformation law, and his
  Poincaré/diffeomorphism/gauge ladder shows the mechanism scales all the way to "the
  principle of general relativity" (the ladder is catalogued case by case on
  [tensor of lines][tensor-of-lines]). None of the exponent-lattice formalizations has a
  story of comparable reach.
- **Fractional and irrational exponents without strain.** A weight is any point of the
  character group; Tao's analysis quantifies over real exponent vectors, and a reader in
  the comment thread raises irrational powers from CFT correlation functions — the
  parametric framework absorbs them by construction, while the _constructed_ lines stop
  at `ℚ` (the abstract-side constructions and the open irrational edge are on
  [tensor of lines][tensor-of-lines]). In Zapata-Carratala the dimension monoid `D` is
  arbitrary, so `ℚⁿ` or `ℝⁿ` dimension groups are no harder than `ℤⁿ` (his §8 asks why
  physics only ever seems to need `ℤ` or `ℚ` — see below).
- **Angles, honestly.** Weight zero does _not_ mean "is a number". Jonsson's Remark 3.17:
  "A 'dimensionless quantity' does not correspond to a unique number, but to a number that
  depends on the choice of a quantity unit for `[1_Q]`. For example, plane angles can be
  measured in both radians and degrees" — and in a _coherent_ unit system the unit for
  `[1_Q]` is pinned to `1_Q`, "for a plane angle `1_Q` corresponds to the radian". The
  dimensionless slice is a 1-dimensional space with a torsor of unit choices like any
  other slice; coherence, not dimensionlessness, is what makes the radian special.

**What it cannot express, or expresses only by silence:**

- **Logarithmic quantities (dB, pH, magnitudes).** None of the four sources treats them —
  a fourfold silence, recorded as a finding. The picture is suggestive but undeveloped:
  `[exposition]` applying `log` to a positive weight-`d` quantity turns the multiplicative
  transformation into an additive one (`log x ↦ log x̃ − a·log M − …`), i.e. converts an
  `ℝ⁺`-torsor into an additive `ℝ`-torsor whose base-point choice is the _reference level_
  (the "re 20 µPa" of dB SPL) — but no local source states this, and Tao's model classifies
  `log` of a dimensionful quantity among the hybrid, no-single-dimension objects.
- **Same-dimension different-kind distinctions, at the torus rung.** With structure group
  `(ℝ⁺)ⁿ` and dimension lattice `ℤⁿ`, torque and energy have equal weight and are
  indistinguishable; Jonsson's commensurability definition of kind makes the collapse
  explicit and deliberate. The picture's own remedy (enlarge the group / refine `D`) is
  demonstrated by Tao only for the geometric cases; neither he nor Zapata-Carratala
  develops a torque-vs-energy refinement. Contrast the _kind_ hierarchies that
  [mp-units][mp-units] builds syntactically.
- **Hybrid objects break the typing.** Sums across weights exist in Tao's model but "do
  not correspond to any particular object in the abstract setting" short of "taking
  formal sums of spaces of different dimensionalities" ([Tao][tao], closing section —
  clause (iii) of the dictionary theorem as stated on
  [tensor of lines][tensor-of-lines]) — the abstract/torsor side must be extended (direct
  sums, graded objects) to even name what the parametric side produces freely.
- **No canonical exponent lattice.** The torus picture works for any `ℤⁿ`, `ℚⁿ`, `ℝⁿ` —
  and therefore explains none of them. Why physical dimension groups are free abelian of
  small finite rank is an input from metrology ([SI/VIM — concepts][concepts]), not an
  output of the representation theory; Zapata-Carratala names this gap explicitly (§8,
  quoted below).

---

## Mechanization

No system in this survey implements "torsor" as a first-class abstraction, but the
picture's two halves are both mechanized, separately:

- **Equivariance as the semantics of unit polymorphism.** Kennedy's POPL'97 theorem for
  the system behind [F# units of measure][fsharp-uom] is literally the statement that
  well-typed programs are equivariant under the scaling torus: "the behaviour of programs
  is invariant under changes to the units used. We prove this 'dimensional invariance'
  result" — with changes-of-units modelled as _scaling environments_ extended "to a
  homomorphism from the Abelian group of (equivalence classes of) unit expressions into
  the Abelian group of scale factors"
  (`$REPOS/papers/units-of-measure/kennedy-1997-relational-parametricity-units-popl.pdf`,
  abstract and §5). That is the character/weight picture in type-theoretic clothing —
  developed fully in [Kennedy's dimension types][kennedy-types] and
  [type-system mechanisms][type-system-mechanisms].
- **Torsor discipline as "point" types.** The affine layer ships in several libraries as a
  quantity/point split with exactly Baez's operation table (point − point = delta,
  point + delta = point, point + point rejected): [mp-units][mp-units] has
  `quantity_point.h` and `point_origin_concepts.h` in
  `src/core/include/mp-units/framework/`; [Au][au] has `au/quantity_point.hh`;
  [Pint][pint] implements offset units (`degC`) via `OffsetConverter` and logarithmic
  units via `LogarithmicConverter` in `pint/facets/nonmultiplicative/definitions.py`;
  [Unitful.jl][unitful] defines `°C`/`°F` through an `@affineunit` macro and an
  `AffineUnits` type (`src/pkgdefaults.jl`, `src/user.jl`). All paths verified in the
  pinned repos of the survey's grounding map (`grounding/_sources.md`). An independent
  rediscovery of the same discipline — a reader's C++ embedding of 1-D vector spaces,
  duals, tensor products, _and 1-dimensional affine spaces_ under strong typing — is
  recorded in the Tao comment thread and quoted on [tensor of lines][tensor-of-lines].
- **Proof assistants.** The [Lean formalization][lean] mechanizes the dimension _group_
  (`CommGroup (dimension B E)` in `LeanDimensionalAnalysis/Basic.lean`) — the character
  lattice — but not the torus action or a torsor layer; neither dimensioned rings nor
  scalable monoids have a known mechanization (a silence of the sources and, as far as
  this survey's artifacts show, of the ecosystem).

**Decision procedure.** The torsor/weight picture adds no new decision problem beyond the
free-abelian-group layer: equality of dimensions is equality of weights in `ℤⁿ`
(decidable, linear algebra over `ℤ`), and checking a law's homogeneity is checking that
all `+`-joined terms have equal weight — the same arithmetic every checker in this survey
runs, from [GNAT's `sem_dim`][gnat] to [F#'s `UnifyMeasures`][fsharp-uom]
(see [free abelian group][free-abelian-group] for the unification story and its
complexity). What the torsor layer adds is _bookkeeping_, not search: origin tags on
affine quantities and base-point management in conversions, enforced syntactically by the
point types above. Tao's transfer principle is also the semantic licence behind a cheap
dynamic strategy: verify an equivariant relation at one unit assignment (e.g. all SI base
units set to `1`) and conclude it for all — the strategy runtime unit systems like
[Pint][pint] implicitly rely on when they normalise to base units before comparing.

---

## Open problems & frontier

- **Why `ℤⁿ` (or `ℚⁿ`)?** The dimensioned formalism deliberately allows any dimension
  monoid, which converts a modelling convention into an open question. Zapata-Carratala,
  §8: "ordinary physical quantities are always formulated with the particular groups Z or
  Q as dimension sets … no further justification has been found to single out Z or Q as
  canonical choices for dimension sets." And the deliberately provocative follow-up:
  _"could it be scientifically justifiable or theoretically useful to consider physical
  theories whose observable quantities have dimensions displaying some exotic algebraic or
  topological properties?"_ ([Zapata-Carratala][zapata], §8).
- **Dimensioned vs graded.** Zapata-Carratala's §8 notes that Vysoký's graded-geometry
  definitions "match our definitions of dimensioned set, dimensioned map and dimensioned
  abelian group respectively by replacing all our generic dimension sets with Z" — yet the
  graded tensor product "differs significantly from our general definition of dimensioned
  tensor product". Whether dimensioned algebra and `ℤ`-graded algebra are two presentations
  of one theory or genuinely diverge is posed as "a fruitful line of further research".
- **The parametric/abstract trade-off.** Tao's closing torsor move (parameters as torsor
  elements, no reference units) has a cost he states exactly: "one loses some of the power
  of the parametric model, namely the power to perform numerical operations even if they
  are dimensionally inconsistent, and so one may as well work entirely in the abstract
  setting instead" ([Tao][tao], closing section; the two settings and the dictionary
  between them are [tensor of lines][tensor-of-lines]'s subject). Where a mechanized
  system should sit on
  this axis — fully abstract (only equivariant operations typecheck) vs parametric with
  escape hatches (any operation, homogeneity checked separately) — is exactly the design
  spectrum the [comparison capstone][comparison] maps across libraries.
- **Which structure group?** Tao's ladder — torus, `GL₃`, `E(2)`, Poincaré,
  diffeomorphisms, gauge groups — frames classical dimensional analysis as the smallest of
  a family of "representation theories of the dimensionful universe". No units library
  climbs past the torus rung (vector/frame-aware unit checking à la Tao's laws `(6)`–`(9)`
  is unmechanized in every system surveyed); [Hart's dimensioned matrices][hart] is the
  nearest theoretical rung. How much of the ladder is worth mechanizing is open.
- **Beyond torsors for affine-and-scaled quantities.** Baez's final remark observes that
  pre-unit temperature needs a line with translations _and_ dilations, "because R is not
  just a group, but a ring. So, there's a more sophisticated concept than that of 'torsor'
  allowing both translations and dilations whenever you start with a ring" — he names no
  such concept, and none of this survey's sources supplies one; the library `quantity` /
  `quantity_point` pairs are its untheorised engineering shadow.

---

## Sources

- J. Baez, ["Torsors Made Easy"][baez], web essay, December 27, 2009 — torsor definition
  and axioms, the ratio operation, energy/voltage/phase and dates/notes/antiderivative
  examples, the non-canonical-isomorphism slogan, principal-bundle fibres, the temperature
  coda. (Quotes transcribed from the local capture
  `$REPOS/papers/units-of-measure/baez-torsors-made-easy-web.html` — the full essay.)
- T. Tao, ["A mathematical formalisation of dimensional analysis"][tao], _What's New_,
  December 29, 2012 — used here for the structure group `(ℝ⁺)³`, transformation law
  `(1)`, the weight-space passage, equivariance and the transfer principle, hybrid
  quantities (in brief), non-toral structure groups (in brief), and the closing torsor
  modification; the abstract model, the dictionary theorem, and the convex-hull
  criterion are grounded on [tensor of lines][tensor-of-lines]. (Quotes verified against
  the local capture
  `$REPOS/papers/units-of-measure/tao-2012-formalisation-dimensional-analysis-blog.html`;
  formulas restored from the WordPress LaTeX `alt` attributes.)
- C. Zapata-Carratala, ["Dimensioned Algebra: the mathematics of physical
  quantities"][zapata], arXiv:2108.08703, 2021 — dimensioned sets/binars/rings/fields
  (§§2–3), units as sections and the Möbius counterexample, Proposition 3.4
  (trivialization), the power functor and Theorem 4.1 (§4), dimensioned
  modules/algebras/Poisson structures (§§5–7), and the §8 research programme. (Quotes
  verified against a `pdftotext -layout` extraction of
  `$REPOS/papers/units-of-measure/zapata-carratala-2021-dimensioned-algebra-arxiv.pdf`.)
- D. Jonsson, ["Magnitudes, scalable monoids and quantity spaces"][jonsson],
  arXiv:2108.02106v6, 2021/2023 — Definition 2.1 (scalable monoid), commensurability and
  orbitoids (§2.3), unit elements and derived addition (§2.6), rank-1 free-module
  structure (Prop 2.36), quantity spaces and bases (§3.1), measures and the
  change-of-basis law (Props 3.15–3.16), the free-abelian dimension group (§3.5). (Quotes
  verified against a `pdftotext -layout` extraction of
  `$REPOS/papers/units-of-measure/jonsson-2021-magnitudes-scalable-monoids-quantity-spaces-arxiv.pdf`.)
- J. Janyška, M. Modugno & R. Vitolo, ["Semi-vector spaces and units of
  measurement"][jmv], arXiv:0710.1313v1, 2007 — a primary source of
  [tensor of lines][tensor-of-lines], cited on this page only for Note 2.3 (the scalar
  multiplication of a positive space is "a free and transitive action of the group
  (ℝ⁺, ·)") and the §3.1 unit-as-semi-basis definition. (Both statements verified
  against a `pdftotext -layout` extraction of
  `$REPOS/papers/units-of-measure/janyska-modugno-vitolo-2007-semi-vector-spaces-units-arxiv.pdf`.)
- A. Kennedy, "Relational parametricity and units of measure", POPL '97 — dimensional
  invariance as the semantics of unit-polymorphic typing; cited here from the local author
  copy `$REPOS/papers/units-of-measure/kennedy-1997-relational-parametricity-units-popl.pdf`
  and developed in [Kennedy's dimension types][kennedy-types].
- Related deep-dives: [theory index][theory-index] · [units-of-measure umbrella][umbrella]
  · [concepts glossary][concepts] · [tensor of lines][tensor-of-lines] ·
  [free abelian group][free-abelian-group] · [Buckingham π][buckingham-pi] ·
  [Kennedy's dimension types][kennedy-types] · [Hart's multidimensional
  analysis][hart] · [type-system mechanisms][type-system-mechanisms] ·
  [comparison][comparison] · system pages: [F#][fsharp-uom] · [mp-units][mp-units] ·
  [Au][au] · [Pint][pint] · [Unitful.jl][unitful] · [GNAT][gnat] · [Lean][lean].

<!-- References -->

<!-- Same-tree theory siblings -->

[theory-index]: ./index.md
[tensor-of-lines]: ./tensor-of-lines.md
[free-abelian-group]: ./free-abelian-group.md
[buckingham-pi]: ./buckingham-pi.md
[kennedy-types]: ./kennedy-types.md
[hart]: ./hart-multidimensional.md
[type-system-mechanisms]: ./type-system-mechanisms.md

<!-- Tree umbrella / concepts / comparison -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md

<!-- System deep-dives -->

[fsharp-uom]: ../fsharp-uom.md
[mp-units]: ../cpp-mp-units.md
[au]: ../cpp-au.md
[pint]: ../python-pint.md
[unitful]: ../julia-unitful.md
[gnat]: ../ada-gnat-dimensions.md
[lean]: ../lean-mathlib-units.md

<!-- Primary sources & external -->

[baez]: https://math.ucr.edu/home/baez/torsors.html
[tao]: https://terrytao.wordpress.com/2012/12/29/a-mathematical-formalisation-of-dimensional-analysis/
[zapata]: https://arxiv.org/abs/2108.08703
[jonsson]: https://arxiv.org/abs/2108.02106
[jmv]: https://arxiv.org/abs/0710.1313
[baez-dolan]: https://ncatlab.org/johnbaez/show/Doctrines+of+algebraic+geometry
[vysoky]: https://arxiv.org/abs/2105.02534
