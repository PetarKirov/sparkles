# Tao's Tensor-of-Lines Formulation

Terence Tao's December 2012 blog essay _A mathematical formalisation of dimensional
analysis_ is the modern coordinate-free answer to "what _is_ a dimensionful quantity?":
each base dimension is an abstract **one-dimensional ordered real vector space** — a
_line_ — with **no preferred unit**; composite dimensions are **tensor products and
duals** of these lines (`V^{ML} := V^M ⊗ V^L`, `V^{T⁻¹} := (V^T)*`); choosing a unit is
choosing a basis vector of a line; and dimensional consistency is the statement that an
expression **type-checks as a tensor** — an inconsistent expression is not false but
_unwritable_. Tao develops this "abstract" picture in tandem with an equivalent
"parametric" one — quantities as families indexed by unit choices, transforming under a
structure group, with dimensional analysis as the **representation theory of `(ℝ⁺)³`**
— and gives the exact dictionary between the two. The closest published refinement is
[Janyška, Modugno & Vitolo's 2007 theory of **positive spaces**][jmv-arxiv]: scales as
zero-free positive half-lines (one-dimensional _semi-vector spaces_ over the semi-field
`ℝ⁺`), composed by **semi-tensor products** and **rational powers**, with a unit of
measurement defined — exactly — as a semi-basis of a scale space. Where the
[free-abelian-group view][free-abelian] keeps only the exponent bookkeeping, the
tensor-of-lines view keeps the _carriers_: it answers not just "which dimensions
multiply to which" but "what set does a 3.7-metre length live in, before anyone picked
the metre".

> [!NOTE]
> **Scope and provenance.** This page is grounded against two local artifacts: a
> static HTML capture of the full Tao post
> (`tao-2012-formalisation-dimensional-analysis-blog.html`) and the arXiv v1 PDF of
> Janyška–Modugno–Vitolo (`janyska-modugno-vitolo-2007-semi-vector-spaces-units-arxiv.pdf`),
> both under the survey's pinned corpus (`$REPOS/papers/units-of-measure/`, catalogued
> in the grounding ledger). The Tao capture includes the comment thread, but **only its
> newest page** (the capture shows "94 comments" and a "« Older Comments" link; the
> visible comments run 2018–2025) — claims about comments are limited to that page.
> **Boundary with the torsor page.** This page owns Tao's _abstract_ model (the lines
> themselves: tensor products, duals, ordering, fractional powers), the parametric ↔
> abstract **dictionary theorem**, and JMV's positive-space algebra. The
> [torsor representation][torsor] page owns the _group-action_ layer: the torsor
> concept itself (Baez), weights/characters and equivariance developed as primary
> structure, Zapata-Carratalá's dimensioned rings, and Jonsson's scalable monoids.
> Tao's parametric model necessarily appears on both pages — here only as far as the
> dictionary theorem needs it; its representation-theoretic development lives there.
> How the two pictures relate, so far as this page's two sources state it, is
> collected under the dictionary theorem below; relational glue beyond the sources is
> marked `[exposition]`.

---

## At a glance

| Dimension                | Tensor-of-lines (Tao 2012 · Janyška–Modugno–Vitolo 2007)                                                                                                                                                                                                                      |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Primary structure        | Abstract picture: a family of 1-D ordered real vector spaces closed under `⊗` and duals; parametric picture: representations (weight spaces) of a **structure group**, `(ℝ⁺)³` for `M, L, T`; JMV: the category of **positive spaces** and semi-linear/rational maps          |
| Quantity                 | An element of a line `V^{MᵃLᵇTᶜ}` (abstract); an equivariant family `x = x_{M,L,T}` obeying the scaling law (1) (parametric); a scale `k ∈ S[d₁,d₂,d₃]`, or a section of `S ⊗́ F` for field quantities (JMV)                                                                   |
| Unit                     | A (positive) basis vector of the line — equivalently an identification of the line with `ℝ`; JMV, verbatim: a scale "regarded as a semi–basis of the scale space `S`, is called a unit of measurement"                                                                        |
| Dimension                | The line itself, indexed (up to canonical isomorphism) by its exponent vector; the weight `(a,b,c)` of the `(ℝ⁺)³`-action; JMV's **scale dimension** `(d₁,d₂,d₃) ∈ ℚ³`                                                                                                        |
| Kind                     | The richest kind story in the survey: enlarge the structure group and quantities split by **transformation law** — vectors vs covectors (`GL₃(ℝ)`), polar vs axial vectors, position vs displacement (`E(2)`), even vs odd (`{−1,+1}`), Poincaré/gauge representations        |
| Cross-dimension addition | Abstract: **unwritable** — "impossible to write down in the first place"; parametric: **defined but dimension-destroying** (a "hybrid" quantity, outside every weight space), with a convex-hull criterion for when hybrid _inequalities_ still hold; JMV: no operation given |
| Change of units          | Parametric: the (passive) structure-group action itself; abstract: a non-event — only the numerical coordinate under a basis choice changes; JMV: semi-basis transitions are multiplication by a positive scalar (Prop 1.6)                                                   |
| Exponent domain          | Parametric: arbitrary real exponents (Tao's convex-hull lemma quantifies over `(a,b,c) ∈ ℝ³`); abstract construction: `ℤ` via `⊗`/duals, fractional by formal roots; JMV: `ℚ` in full rigor via `q`-rational maps                                                             |
| Buckingham π             | Not proven in either source; positioned — `E = αmc²` as "a simple instance", normalisation `c = 1` as "spending" the scaling freedom (Tao); dimension functions are power-law monomials, independence = scale basis, `det(\|eⱼ\|ᵢ) ≠ 0` (JMV Prop 3.4)                        |
| Central theorem          | The abstract ↔ parametric dictionary: fixing reference units `M₀, L₀, T₀` puts pure-dimension parametric quantities in bijection with elements of the lines, and dimensionally consistent statements transfer — verifiable at a _single_ choice of units                      |
| Rigorous companion       | JMV's semi-vector-space theory: sesqui-tensor products `V ⊗̀ U`, universal vector extension `Ū := ℝ ⊗̀ U`, semi-tensor products `U ⊗̂ V`, rational powers `U^q` with `U^p ⊗̂ U^q ≅ U^(p+q)`                                                                                       |
| Mechanization            | None in a proof assistant (in this survey's corpus); a reader reports a C++ embedding of 1-D spaces/duals/tensors/affine spaces via strong typing; the type-system lineage ([Kennedy][kennedy-types], [F#][fsharp-uom]) mechanises the exponent shadow of this picture        |

The neighbouring theory pages carve up the same territory: [Whitney's quantity
structures][whitney] axiomatise the one-dimensional carriers a generation earlier (rays
and birays, numbers constructed afterwards); the [free abelian group of
dimensions][free-abelian] is what remains of the tensor picture after taking
isomorphism classes of lines; [Buckingham π][buckingham-pi] is the theorem both of this
page's sources gesture at without proving; the [torsor representation][torsor] page
develops the group-action layer in its own right — Baez's torsors, Tao's weight spaces
read as characters of the scaling torus, Zapata-Carratalá's dimensioned rings,
Jonsson's scalable monoids — for which this page's lines are the carriers; and
[Kennedy's dimension types][kennedy-types] mechanise the parametric viewpoint as a
type discipline.

---

## Primary sources

- **T. Tao, ["A mathematical formalisation of dimensional analysis"][tao-blog], _What's
  new_ (blog), 29 December 2012** (post header: "29 December, 2012 in expository,
  math.MP, math.RA | Tags: dimensional analysis, rescaling"). _Inspected in full_ via
  the local static capture `tao-2012-formalisation-dimensional-analysis-blog.html`,
  including the LaTeX `alt`-text of every rendered formula. The post has two named
  sections — "1. The parametric approach" and "2. The abstract approach" — framed by an
  introduction on the informal practice of manipulating units syntactically, and closed
  by a paragraph on the torsor variant. The capture also holds the newest page of the
  comment thread (2018–2025, of 94 total), used below for the fractional-exponent,
  commutativity, finance/C++, and convex-cone exchanges; **older comments (2012–2017)
  are not in the artifact** and nothing is claimed from them.
- **J. Janyška, M. Modugno & R. Vitolo, ["Semi-vector spaces and units of
  measurement"][jmv-arxiv], arXiv:0710.1313v1 \[math.AC\], 5 October 2007** (preprint
  dated 2007.07.26). _Inspected in full_ (28 pp.):
  `janyska-modugno-vitolo-2007-semi-vector-spaces-units-arxiv.pdf`. §1 develops
  semi-vector spaces over the semi-field `ℝ⁺`, sesqui- and semi-tensor products; §2
  positive spaces, rational maps, and rational powers; §3 the algebraic model of scales,
  units, coupling scales, scaled bundles, and the interplay with dimensional analysis.
  The authors state the formalism "has been widely used in several papers dealing with
  physical theories" (their refs. \[4, 7, 8, 9, 13, 14, 15\], covariant classical and
  quantum mechanics) and that "In the present paper we analyse the mathematical
  foundations of this formalism for the first time" (§3 preamble). Those application
  papers, and G. I. Barenblatt's _Scaling_ (their dimensional-analysis reference
  \[2\]), were **not inspected** for this survey — every claim about them below is
  as-cited-by-JMV.
- Mentioned in the captured comment thread and _not_ used as a source here: H. Whitney's
  _The Mathematics of Physical Quantities_ Part II (pointed out by a commenter, 10 June
  2020 — see [Whitney][whitney]) and C. Zapata-Carratalá's dimensioned-algebra preprint
  arXiv:2108.08703 (pointed out 14 September 2024, described as "a more abstract
  version"; it is in the survey corpus and is covered on the
  [torsor representation][torsor] page).

---

## Formal core

### The three ways of working with dimensionful quantities, as Tao frames them

Tao's introduction starts from the **syntactic practice** every physics student knows:
units are carried along as formal symbols and "manipulated using the laws of algebra as
if they were numerical quantities" — `(10 m)/(5 s) = 2 ms⁻¹`, with `kg`, `m`, `s`
"being manipulated algebraically as if they were mathematical variables such as `x` and
`y`". The practice comes with one famous restriction, which the whole survey orbits:

> _"There is however one important limitation to the ability to manipulate
> “dimensionful” quantities as if they were numbers: one is not supposed to add,
> subtract, or compare two physical quantities if they have different dimensions,
> although it is acceptable to multiply or divide two such quantities."_
> — Tao 2012, introduction (`tao-2012-…-blog.html`)

He notes it "would be a category error to assert that the length of some object was a
number such as `10`", that changing the unit changes the numeral while "these lengths
are considered all equal to each other" (`10 yards = 30 feet = 9.144 metres`), and that
transcendental functions apply only to dimensionless arguments (`arctanh(v)` is
meaningless for a speed `v`; `arctanh(v/c)` — the rapidity — is fine). The syntactic
practice itself is not developed further; its algebra is formalised on the
[free-abelian-group page][free-abelian]. Tao then sketches and sets aside a
**geometric** route — model a length as "the equivalence class of all line segments
congruent to the original line segment (cf. the Frege-Russell definition of a number)"
— which works for lengths and areas but does not generalise conceptually (envisioning
`E = mc²` as the volume of a box with height `m` is, he remarks, neither geometrically
natural nor helpful). The post's substance is the two formalizations he announces next:

> _"But there are at least two other ways to formalise dimensionful quantities in
> mathematics, which I will discuss below the fold."_ — Tao 2012, introduction

namely the **parametric** model (quantities as unit-indexed families, transforming
under a structure group — "coordinate-heavy", the physicist's implicit model) and the
**abstract** model (quantities as elements of abstract spaces admitting only the
dimensionally consistent operations — "coordinate-free", the pure mathematician's).

### The parametric model: dimensions as weights of a structure group

Postulate dimensional parameters `M, L, T` ranging freely over `ℝ⁺` — "the parameter
space (or structure group) here is given by the multiplicative group `(ℝ⁺)³`". A
**dimensionful object** is a family `x = x_{M,L,T}` — one value for each choice of the
mass, length, and time unit. The worked example: the numerical length `l` of a ten-yard
rod, measured in a length unit `L` yards long, is `l_{M,L,T} = 10·L⁻¹` (thirty when the
unit is a foot, `L = 1/3`). This motivates:

```text
x has dimension MᵃLᵇTᶜ   ⟺   x_{M,L,T} = x̃ · M⁻ᵃ L⁻ᵇ T⁻ᶜ   for some fixed number x̃   (1)
```

The negative exponents record that (1) is a **passive** transformation — "describing
the effect of a passive change of units rather than an active change of the object" —
and Tao immediately puts the definition in representation-theoretic terms: the
collection of quantities of dimension `MᵃLᵇTᶜ` "is a weight space of the structure
group `(ℝ⁺)³ = { (M,L,T): M,L,T ∈ ℝ⁺ }` of weight `(a,b,c)`" — dimensional analysis
as "the representation theory of groups such as `(ℝ⁺)³`". That reading — weights as
characters of the scaling torus, homogeneity as equivariance, invariants as weight
zero — is developed as a formalization in its own right on the
[torsor page][torsor]; here the parametric model appears only as far as the
dictionary theorem below needs it.

All operations act pointwise per parameter choice, so **every** operation is available:
`x + y`, `x·y`, `sin(x)`, comparisons. What varies is whether the _result_ still has a
dimension. Products behave perfectly (weights add); but the sum of a length
`l = 10·L⁻¹` and a speed `v = 30·L⁻¹T` is the family `10L⁻¹ + 30L⁻¹T` — a perfectly
well-defined dimensionful object "of hybrid dimension", not of the form (1) for any
`(a,b,c)`. Even the pathological `L^{sin(M+T)}` is a legitimate object of the
dimensionful universe; it simply "does not have any specific dimension attached to it".
The payoff of restricting to pure dimensions is the **transfer principle** (Tao's
explicit analogy is nonstandard analysis): a dimensionally consistent statement need
only be checked at a _single_ choice of parameters —

```text
Transfer.  If x, y both have dimension MᵃLᵇTᶜ and x_{M₀,L₀,T₀} = y_{M₀,L₀,T₀} at one
parameter choice (M₀,L₀,T₀), then x = y, i.e. x_{M,L,T} = y_{M,L,T} for all M, L, T.

Sketch.  By (1), x_{M,L,T} = x̃·M⁻ᵃL⁻ᵇT⁻ᶜ and y_{M,L,T} = ỹ·M⁻ᵃL⁻ᵇT⁻ᶜ.  The scale
factor M₀⁻ᵃL₀⁻ᵇT₀⁻ᶜ is invertible, so equality at (M₀,L₀,T₀) forces x̃ = ỹ, and the
two families coincide identically.  Likewise for ≤, and for n-ary consistent relations.
```

Conversely, a dimensionally _inconsistent_ nontrivial identity "can be automatically
ruled out as being false": if `x` and `y` have different pure dimensions, `x = y`
cannot hold "unless `x` and `y` both vanish" (the two scaling laws diverge as the
parameters vary). This is the formal content of dimensional error-checking. Tao's
`E = mc²`/Planck-units discussion sharpens the transfer into a trade-off: choosing
units with `c = 1` collapses the consistent `E = mc²` into the inconsistent `E = m`,
which holds _only_ in that gauge —

> _"So we see a tradeoff between the freedom to vary units, and the freedom to work
> with dimensionally inconsistent equations; one can spend one freedom for another, but
> one cannot have both at the same time."_ — Tao 2012, §1

The same machinery extends to dimensionful **sets** (a set of families is _not_
determined by its per-parameter evaluations — `ℝ_{MᵃLᵇTᶜ}` evaluates to `ℝ` for every
parameter choice yet the sets for different `(a,b,c)` "only intersect at the origin"),
**functions** (a family `f_{M,L,T}` between dimensionful sets, obeying the conjugation
law `f_{M,L,T}(x) = f̃(MᵃLᵇTᶜ·x)·M⁻ᵃ'L⁻ᵇ'T⁻ᶜ'` for a dimensionless `f̃`), **integration**
(dimension of `∫ f dx` = dimension of `f` times dimension of `dx`, proven "for Riemann
sums" first, dimensions being "a closed condition ... preserved under limits"), and
**derivatives** (exponents subtract). Tao uses this to run dimensional analysis on the
homogeneous Sobolev inequality and read off `d/q = d/p − 1` as a necessary condition —
see [Buckingham π below](#buckingham-π-in-this-picture).

### The abstract model: dimensions as one-dimensional lines

The abstract approach discards the parameters and the coordinates together. Its warm-up
is the vector/covector distinction: for an abstract 3-D vector space `V` with no inner
product, a covector in `V*` simply cannot be added to a vector in `V` — and this is the
model for everything that follows:

> _"Thus, in this framework, dimensionally inconsistent operations are not just
> inconvenient to use; they are impossible to write down in the first place (unless one
> introduces some non-canonical choices, such as an identification of `V` with `ℝ³`)."_
> — Tao 2012, §2 (`tao-2012-…-blog.html`)

Scalars get the same treatment: "One can apply the same abstract perspective to
scalars, such as the length or mass of an object, by viewing these quantities as lying
in an abstract one-dimensional real vector space, rather than in a copy of `ℝ`." For
the `M, L, T` system, "we can postulate the existence of three one-dimensional real
vector spaces `V^M, V^L, V^T`" — the spaces of possible masses, lengths, and times,
"where we permit for now the possibility of negative values for these units" — each
equipped with a compatible total ordering (so they are **ordered** 1-D real vector
spaces), and crucially: "However, we do not designate a preferred unit in these spaces
(which would identify each of them with `ℝ`)." Composite dimensions are then built by
pure algebra, with no coordinates in any statement:

```text
V^{ML}     := V^M ⊗ V^L      — the universal recipient of a bilinear · : V^M × V^L → V^{ML};
                               ordered by declaring (positive) ⊗ (positive) positive
V^{T⁻¹}    := (V^T)*         — the dual line; a functional is positive if positive on positives
V^{LT⁻¹}   := V^L ⊗ (V^T)*   — and so on
V^{MᵃLᵇTᶜ}, a,b,c ∈ ℤ        — iterated ⊗ and duals; the several possible bracketings/orderings
                               are "canonically and naturally isomorphic to each other"
V^{L^(1/2)}                  — formal signed square roots ±l^(1/2) of non-negative l ∈ V^L,
                               "with a rather complicated but explicitly definable rule for
                               addition and scalar multiplication"
```

A quantity of dimension `MᵃLᵇTᶜ` is an element of `V^{MᵃLᵇTᶜ}`. Multiplication is the
tensor product (canonical, total across all pairs of lines); addition, subtraction, and
comparison exist only _within_ a line — "particularly if one is careful to keep the
origins `0` of each of these vector spaces distinct from each other". All universal
laws of algebra survive subject to typing — "(The situation here is similar to that of
a graded algebra, except that one does not permit addition of objects of different
dimensions or gradings.)" — and integrals and derivatives extend ("as limits of Riemann
sums and Newton quotients respectively"), so dimensionally consistent analysis carries
over wholesale. What does _not_ carry over is anything inconsistent: the AM-GM hybrid
inequality below simply "does not make sense if `l` lies in `V^L` and `v` lies in
`V^{LT⁻¹}`". Tao is explicit that the loss is the point: the abstract framework is
"apparently less powerful", yet "the operations that remain in the framework tend to be
precisely the ones that one actually needs to solve problems".

### The dictionary between the two pictures — central theorem, with proof sketch

The post's central mathematical claim is that the two models are equivalent on their
common domain, via a non-canonical but controlled choice:

> _"It is possible to convert the abstract framework into the parametric one by making
> some non-canonical choices of a reference unit system."_ — Tao 2012, §2

```text
Theorem (Tao's dictionary, §2).  Fix reference units M₀ ∈ V^M, L₀ ∈ V^L, T₀ ∈ V^T.
(i)   Identifying M₀ᵃL₀ᵇT₀ᶜ with 1 identifies each line V^{MᵃLᵇTᶜ} with ℝ; writing
      x = x̃ · M₀ᵃL₀ᵇT₀ᶜ, the recipe  x_{M,L,T} := x̃ · M⁻ᵃL⁻ᵇT⁻ᶜ  makes each abstract
      element a parametric quantity of dimension MᵃLᵇTᶜ.
(ii)  Conversely, "every object x_{M,L,T} that has dimension MᵃLᵇTᶜ in the parametric
      framework arises from a unique object x in the abstract framework (if one keeps
      the reference units M₀, L₀, T₀ fixed)" — and similarly for sets and functions.
(iii) Parametric objects of hybrid dimension "do not correspond to any particular
      object in the abstract setting", short of adjoining formal sums of lines.

Proof sketch.  Each line is one-dimensional and M₀ᵃ ⊗ L₀ᵇ ⊗ T₀ᶜ (dualised where the
exponent is negative) is a basis vector of V^{MᵃLᵇTᶜ}: tensor products of bases are
bases, duals of bases are dual bases, and the canonical isomorphisms between the
different bracketings match these basis vectors up.  So x ↦ x̃ is a linear bijection
V^{MᵃLᵇTᶜ} → ℝ.  Replacing the reference units by the rescaled units MM₀, LL₀, TT₀
rescales the basis vector by MᵃLᵇTᶜ and hence the coordinate by M⁻ᵃL⁻ᵇT⁻ᶜ — which "is
of course just (1)": the parametric transformation law is *derived* from basis change
on the line, and equivariance under (ℝ⁺)³ holds by construction.  Injectivity and
surjectivity in (ii) follow from one-dimensionality (the family determines x̃ at the
reference choice, x̃ determines the family).  For (iii), a hybrid family fails (1) for
every single weight, so no single line can receive it.  ∎
```

Together with the transfer principle this closes the loop: prove a dimensionally
consistent statement numerically (at one unit choice) and it holds abstractly; state it
abstractly and it is automatically consistent.

**Relation to the [torsor picture][torsor], as far as this page's sources state it.**
Tao ends by noting the residual inelegance — the reference units — can be removed by
letting `M, L, T` themselves range over the `ℝ`-torsors `V^M, V^L, V^T` (the full
passage is quoted on the [torsor page][torsor]), at which point "one loses ... the
power to perform numerical operations even if they are dimensionally inconsistent, and
so one may as well work entirely in the abstract setting instead". This page's two
sources support exactly three statements about how the pictures connect:

- **Torsorializing the parametric model collapses it into this one (Tao).** The
  closing remark is Tao's own verdict: once the parameters are torsor-valued rather
  than numerical, the parametric framework's surplus — total, dimension-ignoring
  operations — is gone, and "one may as well work entirely in the abstract setting
  instead". On Tao's account the torsor variant is not a third formalization sitting
  between his two models; it is the lines picture, reached from the parametric side.
- **The set of units of one line is a torsor (JMV).** Scalar multiplication on a
  positive space "turns out to be a free and transitive action of the group `(ℝ⁺,·)`
  on the set `U`" (Note 2.3), and a unit is any scale regarded as a semi-basis
  (§3.1) — so choosing a basis vector of a line (this page's unit) and choosing a
  point of a torsor (that page's unit) are the same act, stated for positive spaces
  verbatim in JMV. For Tao's signed lines the analogous statement — the positive
  basis vectors of an ordered 1-D space form an `ℝ⁺`-torsor — is standard but appears
  in no local source. \[exposition\]
- **The scaling torus is this picture's basis-change group.** JMV's Prop 1.6 makes a
  change of semi-basis of one scale space multiplication by a unique positive scalar,
  and step one of the dictionary proof shows that rescaling the reference units
  multiplies each line's coordinate by the character `M⁻ᵃL⁻ᵇT⁻ᶜ`: the `(ℝ⁺)³` the
  torsor page takes as primary acts here _derivedly_, through basis choices, on all
  tensor powers at once. That each line is thereby a weight space of weight `(a,b,c)`
  is the dictionary read backwards. \[exposition\]

The two pictures do **not** take the same structure as primary, and the difference is
substantive rather than notational. This page's sources posit the _carriers_ — lines,
positive spaces — with their multiplicative calculus, and recover the group as basis
changes; the torsor page's sources posit the _action_ or the dimension fibration and
recover the carriers (weight spaces; slices of a dimensioned ring — Zapata-Carratalá's
power functor, that page's central theorem, realises precisely this page's tensor
powers of lines as a dimensioned field). The packagings also retain different
structure: a positive space is _more_ than the `ℝ⁺`-torsor of Note 2.3 — it carries
the addition of same-dimension scales as a primitive (Def 1.1), which a bare torsor,
by the axioms quoted on the [torsor page][torsor], deliberately lacks. Reading a line
only as the torsor of its unit choices forgets the additive structure this page's
sources are built on. \[exposition\]

### Janyška–Modugno–Vitolo: positive spaces and semi-tensor products

JMV publish the rigorous algebra the abstract picture needs when one takes seriously
that scales are **positive**. Their abstract states the program:

> _"This paper is aimed at introducing an algebraic model for physical scales and units
> of measurement. This goal is achieved by means of the concept of “positive space” and
> its rational powers. Positive spaces are 1–dimensional “semi–vector spaces” without
> the zero vector."_ — Janyška–Modugno–Vitolo 2007, abstract (`janyska-modugno-vitolo-…-arxiv.pdf`)

The scaffolding (their §1–§2), in order of construction:

```text
semi-field:       ℝ⁺ with + and ·  (no zero, no additive inverses; cancellation holds)
semi-vector space (Def 1.1):  a set U with + : U×U → U and · : ℝ⁺×U → U satisfying the
                  six vector-space equations (associativity and commutativity of +,
                  (rs)u = r(su), 1u = u, and both distributive laws)
complete / simple / regular / semi-free (Defs 1.1–1.4):  has a zero vector / has no
                  invertible elements / cancellative / has a semi-basis (unique finite
                  positive decompositions);  semi-free ⇒ regular (Prop 1.5); all
                  semi-bases have equal cardinality — the semi-dimension (Cor 1.7)
sesqui-tensor product (Def 1.29, Thm 1.30):  V ⊗̀ U for V a vector space, U a
                  semi-vector space — universal for maps linear in V, semi-linear in U;
                  built as a quotient of finitely-supported maps, like the classical case
universal vector extension (Def 1.44):  Ū := ℝ ⊗̀ U;  ı : U → Ū, u ↦ 1 ⊗̀ u is
                  injective for semi-free U, and dim(ℝ ⊗̀ U) = s-dim U (Prop 1.43)
semi-tensor product (Def 1.51, Thm 1.52):  U ⊗̂ V — universal for semi-bilinear maps;
                  constructed inside Ū ⊗̀ V;  s-dim(U ⊗̂ V) = s-dim U · s-dim V (Prop 1.53)
positive space (Def 2.1):  a non-complete semi-free semi-vector space of semi-dimension 1
                  — equivalently (Note 2.2) the ℝ⁺-span of a single non-vanishing element
q-rational map (Def 2.5):  f(ru) = r^q f(u) for all r ∈ ℝ⁺, q ∈ ℚ
q-th power (Def 2.12):  U^q := Rat_q(U*, ℝ⁺), with π^q : u ↦ u^q the unique q-rational
                  map sending u to the functional with u^q(1/u) = 1
power calculus (Props 2.15–2.16):  U^p ⊗̂ U^q ≅ U^(p+q)  and  (U^p)^q ≅ U^(pq);
                  U⁰ ≅ ℝ⁺,  U¹ ≅ U,  U⁻¹ ≅ U* (Note 2.14)
```

The sesqui-tensor product hides a genuine subtlety that separates this theory from
ordinary linear algebra: for two _vector_ spaces, `dim(V ⊗̀ U) = 2·(dim V)(dim U)`
(Prop 1.36) — twice the classical dimension — because semi-linearity in the second slot
cannot move signs across the tensor: `−(v ⊗̀ u) = (−v) ⊗̀ u ≠ v ⊗̀ (−u)` (Remark 1.35).
Two structural results anchor the "line" reading and this page's cross-links:

- **Every positive space is an `ℝ⁺`-torsor.** "The scalar multiplication
  `s : ℝ⁺ × U → U` turns out to be a free and transitive action of the group `(ℝ⁺,·)`
  on the set `U`" (Note 2.3) — the set of unit choices for a scale space is exactly a
  torsor; see [torsor representation][torsor].
- **Semi-basis transitions are rigid.** For semi-free semi-vector spaces the transition
  law between semi-bases "is essentially more restrictive than the transition law
  between bases of vector spaces" (their emphasis after Prop 1.6): in semi-dimension 1
  a change of semi-basis is precisely multiplication by a positive scalar — a change of
  units, and nothing else.

Existence of the semi-tensor product (Thm 1.52) is the load-bearing theorem; its proof
is a two-step reduction worth sketching because it explains why the sesqui product and
the vector extension exist at all. _Sketch:_ embed both factors in their universal
vector extensions `Ū, V̄`; inside the honest vector space `Ū ⊗̀ V` take the sub-semi-vector
space of semi-linear combinations of elements `(1 ⊗̀ u) ⊗̀ v`; a semi-bilinear
`f : U × V → W` extends (by Prop 1.45, via `f̄(1 ⊗̀ u) = f(u)`, `f̄((−1) ⊗̀ u) = −f(u)`)
to a bilinear map of the extensions, whose restriction to the subspace is the required
unique semi-linear factorisation. ∎ On top of this, §3 defines the model of scales:

```text
basic spaces of scales:  three positive spaces T (time), L (length), M (mass)
scale space (Def 3.1):   S[d₁,d₂,d₃] := T^d₁ ⊗̂ L^d₂ ⊗̂ M^d₃,  dᵢ ∈ ℚ
scale:                   an element k ∈ S;  unit of measurement: k regarded as a semi-basis
scale dimension:         |k| := (d₁,d₂,d₃) ∈ ℚ³, with |1/k| = −|k|, |k ⊗̂ k′| = |k|+|k′|,
                         |k^q| = q·|k|  (Note 3.2)
scale basis (Def 3.3):   scales (e₁,e₂,e₃) through which every scale factors uniquely as
                         k = r·e₁^c¹ ⊗̂ e₂^c² ⊗̂ e₃^c³,  r ∈ ℝ⁺, cᵢ ∈ ℚ
criterion (Prop 3.4):    (e₁,e₂,e₃) is a scale basis  ⟺  det(|eⱼ|ᵢ) ≠ 0
```

(The arXiv v1 twice misprints the mass factor of Definition 3.1 as `M^d₂`; that the
intended exponent is `d₃` is unambiguous from the scale dimension `(d₁,d₂,d₃)` defined
immediately below it.) The definition of a **unit** deserves its verbatim form, because
it is the cleanest statement in the survey of "a unit is just a distinguished quantity":

> _"A scale `k ∈ S`, regarded as a semi–basis of the scale space `S`, is called a unit
> of measurement."_ — JMV 2007, §3.1

§3.3 populates the model: the speed of light `c ∈ T⁻¹ ⊗̂ L`, Planck's constant
`ħ ∈ T⁻¹ ⊗̂ L² ⊗̂ M`, the gravitational constant `g ∈ T⁻² ⊗̂ L³ ⊗̂ M⁻¹`, the positron
charge `e ∈ L^(3/2) ⊗̂ M^(1/2)` — genuinely fractional exponents in a Gaussian-flavoured
system — are **universal coupling scales**; particle-dependent scales include a mass
`m ∈ M` and a charge `q ∈ T̄⁻¹ ⊗̂ L^(3/2) ⊗̂ M^(1/2)`, where the bar marks the vector
extension because "a charge might be positive, vanishing, or negative". Prop 3.4 then
computes: `(m, q, ħ)`, `(m, ħ, g)`, `(q, ħ, g)` are scale bases (determinants `−1/2`,
`1`, `1`); `(m, q, g)` is not (determinant `0`, since `|g| = |q²/m²|`). Finally, §3.2
extends everything from scalars to fields: a **scaled object** is a section of
`S ⊗́ F` for a vector bundle `F → B` (sesqui-tensor with the trivial positive-space
bundle), and any linear differential operator `D` — exterior differential, Lie
derivative, covariant derivative — lifts to scaled sections by
`Ds := u ⊗́ D⟨s, 1/u⟩`, independently of the chosen scale `u`. "The positive factors
can be treated as numerical constants, with respect to differential operators" (§3.2
preamble) — dimensions ride along outside the calculus.

### Buckingham π in this picture

Neither source states or proves the [π theorem][buckingham-pi]; both position it
precisely, and the positioning is instructive. Tao's introduction runs the canonical
miniature: postulating a mass–energy relationship involving only `E`, `m`, `c`,
"dimensional analysis is already sufficient to deduce that the relationship must be of
the form `E = αmc²` for some dimensionless absolute constant `α` ... (This is a simple
instance of a more general application of dimensional analysis known as the Buckingham
`π` theorem.)". In the body, the π-style workflow appears twice more, in his own
terms:

- **Normalisation = spending the group freedom.** Choosing Planck-type units with
  `c = 1` is using one `ℝ⁺` factor of the structure group to kill one quantity's
  numerical value — the reduction step of every π-theorem proof, with the "spend a
  freedom" trade-off quoted above as its bookkeeping.
- **Exponent relations as necessary conditions.** For the homogeneous Sobolev
  inequality (his eq. (4)), assigning the amplitude and length weights and demanding
  both sides share a dimension yields `d/q = d/p − 1` — "a necessary condition",
  sufficiency being "a non-trivial fact that cannot be proven purely by dimensional
  analysis". This is the π theorem's logical shape in miniature: dimensional analysis
  constrains the _form_ of a law, "one can often identify the form of a physical law
  before one has fully derived it", and no more.

In weight-space language the classical statement transliterates as follows (this
paragraph is a transliteration, not a claim of either source — the theorem itself, its
hypotheses, and its proofs live on the [Buckingham π page][buckingham-pi]):

```text
Quantities x₁,…,xₙ of pure dimensions have weight vectors w₁,…,wₙ ∈ ℝ³ (the rows of
the dimension matrix A).  A monomial x₁^c₁ ⋯ xₙ^cₙ is invariant under the (ℝ⁺)³ action
— dimensionless — iff Aᵀc = 0, so the independent dimensionless monomials number
n − rank A.  The reduction: spend rank A of the three ℝ⁺ freedoms to normalise rank A
of the xᵢ to 1 (Tao's c = 1 move); by the transfer principle the normalised statement
determines the general one; what survives is a relation among the n − rank A invariants.
```

JMV's §3.4 ("Interplay with dimensional analysis") makes the same connections from the
algebraic side, deferring the theorem to Barenblatt: a class of systems of units "is,
in our language, the choice of basic spaces of scales"; the dimension of a physical
quantity "is what we call the scale dimension"; the classical fact that "the dimension
function is always a power-law monomial ... justifies our algebraic setting" (this is
_why_ tensor products and rational powers suffice — nothing in physics needs
polynomials of scales); "The independence of dimensions for some quantities \[2, p. 20\]
is just the property of those quantities of being a scale basis" — i.e. the π theorem's
rank condition is their `det(|eⱼ|ᵢ) ≠ 0` (Prop 3.4); and homogeneity of physical
relationships "is a natural consequence of our setting that functions between scale
spaces are rational. This property leads to the Π-theorem of dimensional analysis
\[2\]." The `(m, q, g)` non-basis (determinant zero) is a worked instance of the rank
condition failing.

---

## Structural anatomy

### What structure is primary; objects and morphisms

Tao's post deliberately keeps **two** primary structures and a dictionary between them.
In the parametric picture the primary object is the **structure group** and its
representations: the objects are weight spaces (and, in general, spaces carrying an
action — the framework generalises verbatim from `(ℝ⁺)³` to `GL₃(ℝ)`, `E(2)`, `O(3)`,
the Poincaré group, diffeomorphism groups, gauge groups, and even `{−1,+1}`), and the
admissible maps are the **equivariant** ones. In the abstract picture the primary
structure is a family of **one-dimensional ordered real vector spaces closed under `⊗`
and duals**, with canonical isomorphisms identifying the different ways of composing
them; morphisms are linear maps, and the dimensionally meaningful ones are those
built from the tensor structure. JMV commit to a single answer with categorical
hygiene: the **category of positive spaces**, "positive spaces and semi–linear maps
constitute a category" (§2.1) — and a second, coarser category with the same objects
whose morphisms are the **rational maps** of arbitrary degree, "positive spaces and
rational maps constitute a category" (§2.2), composition multiplying degrees. The
degree-`q` maps between two fixed positive spaces themselves form a positive space
(Prop 2.8) — the theory is closed under its own hom-construction.

### What is a quantity, a unit, a dimension, a kind?

**Quantity.** Abstract: an element of a line `V^{MᵃLᵇTᶜ}` (or, for vector-valued
quantities, of a tensor product of a line with a vector space — JMV's scaled sections
of `S ⊗́ F`). Parametric: an equivariant family `x_{M,L,T}` satisfying (1). The two are
in bijection by the dictionary theorem. JMV restrict the scalar carriers to positive
elements — a **scale** `k ∈ S` — and reach signed quantities (charge) by tensoring with
the vector extension.

**Unit.** A unit is not a new kind of entity: it is a quantity in a distinguished
_role_. Abstract: a choice of (positive) basis vector of the line — the thing Tao
pointedly refuses to build in ("we do not designate a preferred unit in these spaces").
JMV say it in one line: a scale "regarded as a semi–basis of the scale space `S`, is
called a unit of measurement". Because a positive space is an `ℝ⁺`-torsor (Note 2.3),
the set of possible units of one dimension is a torsor over the group of unit
conversions — the observation the [torsor page][torsor] develops.

**Dimension.** The line itself — with the exponent vector as its name. Parametrically,
the weight `(a,b,c)`; in JMV, the scale dimension `|k| = (d₁,d₂,d₃) ∈ ℚ³`, a complete
invariant of the scale space ("for two scales `k` and `k′`, we have `|k| = |k′|` if and
only if the two scales belong to the same scale space", Note 3.2 — and then `k = rk′`
for a unique `r ∈ ℝ⁺`). The map `k ↦ |k|` is a homomorphism onto `(ℚ³, +)`: this is the
precise sense in which the [free abelian (here: rational) group of dimensions][free-abelian]
is the decategorified shadow of the tensor picture.

**Kind.** Uniquely among the survey's formalizations, Tao's parametric picture has a
_productive_ notion of kind: enlarge the structure group and one dimension splits into
many kinds by **transformation law**. Under `GL₃(ℝ)`, vectors (transforming by
`v_L = ṽ(Lᵗ)⁻¹`, his (6)) and covectors (`w_L = w̃L`, his (7)) are distinct kinds with
the same underlying `ℝ³`: "it is not possible for a vector and covector to be equal as
dimensionful quantities (unless they are both zero)". Under `E(2)`, **position vectors**
and **displacement vectors** become rigorously distinct (transforming by `L⁻¹` versus
its homogeneous part `L̇⁻¹`) — "a rigorous distinction between the concepts of position
and displacement vector that one sometimes sees in introductory linear algebra or
physics courses"; the [torsor page][torsor] reads this same example as the
point/difference (torsor/group) split re-derived as a representation distinction.
Under `O(3)`, polar versus axial vectors ("the cross product of two
polar vectors is an axial vector rather than a polar vector"). Under `{−1,+1}`, even
versus odd scalars, yielding the parity rules of trigonometric identities. JMV have no
kind notion inside the algebra, but record a kind-shaped distinction _outside_ it:
universal coupling scales (`c`, `ħ`, `g`, `e`) versus particle-dependent scales
(`m`, `q`), noting "It may be algebraically correct, but not physically reasonable to
express certain scales by means of some of the above scale bases" — the algebra cannot
see the difference; physics can.

### How is dimensional homogeneity of physical laws expressed?

Three equivalent renderings, in increasing abstraction. Parametrically, a law is a
statement about dimensionful families that is **invariant under the structure-group
action** — both sides transform with the same weight — and hence, by transfer, checkable
at one unit choice; a law that privileges a unit choice (`E = m`) is exactly one that
fails this. For laws _between_ quantities (functions), homogeneity is the conjugation
law (his (3)): every dimensionful function is a dimensionless `f̃` dressed by the
scaling action on domain and codomain. Abstractly, a law is an equation between
elements of — or maps between — the same line, and homogeneity is **well-typedness**:
there is nothing to check because heterogeneous equations cannot be written. In JMV,
laws between scale spaces are **rational maps**, and homogeneity is a theorem-shaped
consequence of the setting ("It is a natural consequence of our setting that functions
between scale spaces are rational") rather than an assumption — this is their gloss on
the classical result that dimension functions are power-law monomials.

### What acts as a change of units, and what is invariant under it?

Parametrically, a change of units **is** the primitive act: the structure group's
element `(M,L,T)` is "a passive change of units", and the model consists of nothing but
the orbit data. Invariant: the weight-`(0,0,0)` quantities (dimensionless numbers), all
equations and inequalities between quantities of equal pure dimension (by transfer),
and — for the generalised groups — every equivariant statement. Not invariant: the
numerical instantiations `x_{M,L,T}`, and every dimensionally inconsistent statement
(these hold at most on a subgroup — the "spend a freedom" trade-off). Abstractly, a
change of units is **nothing at all**: no structure was fixed, so none changes. The
gauge freedom reappears only in the dictionary: re-choosing the reference units
`(M₀,L₀,T₀) → (MM₀, LL₀, TT₀)` re-identifies each line with `ℝ`, multiplying
coordinates by `M⁻ᵃL⁻ᵇT⁻ᶜ`. In JMV the same statement is Prop 1.6 in semi-dimension 1:
a semi-basis change is multiplication by a unique positive scalar, so the group of unit
changes of one scale space is exactly `ℝ⁺` acting freely and transitively — and a
scale-basis change for the whole system is an invertible `ℚ`-matrix on scale dimensions
(Prop 3.4).

### Addition across quantities of different dimension

This formalization gives the survey's most differentiated answer — three answers, in
fact, one per layer, plus a theorem about the grey zone. (The [torsor page][torsor]
sets Tao's parametric answer beside Baez's, Zapata-Carratalá's, and Jonsson's without
reconciling them; the abstract and JMV layers below are this page's.)

**Abstract layer: unwritable.** `m + v` for `m ∈ V^M`, `v ∈ V^{LT⁻¹}` is not false,
not partial, not an error value — it is not a term. "Dimensionally inconsistent
operations are not just inconvenient to use; they are impossible to write down in the
first place." The _why_ is structural, and the contrast with multiplication is exact:
multiplication across dimensions exists because the tensor product is a canonical
construction on every pair of lines with a canonical recipient (`V^M ⊗ V^{LT⁻¹}`,
unique up to canonical isomorphism); addition is an operation _internal_ to one vector
space, and two distinct lines admit no canonical linear map into a common recipient —
any such identification "introduces some non-canonical choices". The only canonical
recipient of a heterogeneous sum is the direct sum `V^M ⊕ V^{LT⁻¹}`, and taking it
means leaving the graded fragment — Tao's "formal sums of spaces of different
dimensionalities", which he notes exist but declines to develop, pointing instead at
the formalisms that embrace them (Clifford algebras "do in fact allow one to (among
other things) add vectors with scalars"; `exp(ω)` of a symplectic form, whose `n`-th
graded component is the Liouville measure).

**Parametric layer: total but dimension-destroying.** Here `x + y` always exists
(pointwise), and the theory says something _about_ it: the sum of quantities of
different pure dimensions is a **hybrid** — a well-defined dimensionful object lying in
no weight space. Equality degenerates ("the equation `x = y` cannot hold at all,
unless `x` and `y` both vanish"); trichotomy fails (his `l = 10L⁻¹` versus
`v = 30L⁻¹T`: none of `l = v`, `l < v`, `l > v` holds, the comparison flipping as `T`
crosses `1/3`). But inequality does **not** degenerate, and this is the formalization's
distinctive contribution to the addition question: for `x` a positive sum of terms with
exponent vectors `(aᵢ,bᵢ,cᵢ)` and `y` a positive sum with exponents `(a′ⱼ,b′ⱼ,c′ⱼ)`,
an inequality `x < y` or `x ≤ y` "can only hold if the convex hull of the `(aᵢ,bᵢ,cᵢ)`
is contained in the convex hull of the `(a′ⱼ,b′ⱼ,c′ⱼ)`" — dimensional consistency for
inequalities is a **convex-geometry condition on exponent vectors**, not exponent
equality. The arithmetic-geometric mean inequality `lv ≤ ½l² + ½v²` is his witness:
dimensionally heterogeneous on the right, yet valid and consistent in the generalised
sense, since `(0,2,−1)` lies in the hull of `{(0,2,0), (0,2,−2)}`. The same analysis
explains why physics rarely meets hybrids — a hybrid can bound a pure quantity but "the
converse is not possible", so any chain of estimates between pure endpoints must stay
pure — and why hybrid inequalities that do arise (his inhomogeneous Sobolev (5)) can
often be **amplified** into pure ones by optimising over rescalings
(Gagliardo–Nirenberg, via the trick he cross-references).

**JMV layer: total within a scale space, absent across, and no subtraction anywhere.**
Addition is a primitive of every semi-vector space, so two scales of the _same_ scale
space add (two mass scales sum to a mass scale — positivity is closed under `+`).
Across different scale spaces no operation is defined, and the paper offers none: the
carriers are disjoint sets and the only products are tensorial. The genuinely new
restriction is _within_ a space: a positive space has no zero and no additive inverses
(it is "non-complete" by definition), so **subtraction of same-dimension scales is also
undefined** — a stronger stance than Tao's ordered lines, motivated by scales being
strictly positive magnitudes. Signed quantities re-enter only via the universal vector
extension (`q ∈ T̄⁻¹ ⊗̂ …` because charge "might be positive, vanishing, or negative").
The comment thread completes the JMV-side picture from Tao's end: masses constrained
positive "lie in a convex cone inside a one-dimensional vector space" —

> _"Formally, one could view masses that are restricted for physical reasons to be
> positive to lie in a convex cone inside a one-dimensional vector space, if desired."_
> — Tao, comment reply of 31 May 2025 (`tao-2012-…-blog.html`, comment page)

which is, up to packaging, exactly JMV's positive space (a 1-D cone minus its vertex is
an `ℝ⁺`-torsor; JMV's Note 1.47: "all semi–free semi–vector spaces can be regarded as
cones in a vector space").

---

## Expressive power & limits

### What it handles that "reals with attached units" cannot

- **Carriers, not tags.** A quantity has a home before any unit exists; "no preferred
  unit" is a theorem-friendly statement, not a style guideline. Unit conversion factors
  are not magic numbers but basis-change scalars, and the exact failure mode of `E = m`
  (true only in a gauge) is expressible and provable.
- **Kinds via structure groups.** Vector/covector, polar/axial, position/displacement,
  even/odd — distinctions invisible to exponent vectors — fall out of one mechanism
  (enlarge the group, classify the representations), scaling up to special relativity
  ("the principle of special relativity can be interpreted as the assertion that all
  physical quantities transform cleanly with respect to this group action" for the
  Poincaré group), general relativity (diffeomorphism groups, with the caveat of local
  charts), and gauge theory.
- **Hybrid inequalities with a criterion.** The convex-hull condition is a genuine
  extension of dimensional analysis beyond "exponents must match" — no
  exponents-as-tags system expresses `lv ≤ ½l² + ½v²` at all, let alone decides when
  such an inequality is consistent.
- **Dimensional analysis of analysis.** Integrals, derivatives, function spaces, and
  norms get dimensions; Sobolev-exponent numerology becomes a two-line weight
  computation, and the scaled differential operators of JMV (§3.2) let dimensions ride
  through exterior/Lie/covariant derivatives "as numerical constants".
- **Fractional powers with an actual construction** — next.

### Fractional and irrational exponents

The parametric picture is indifferent to the exponent domain: (1) makes sense for any
real `(a,b,c)`, and Tao's convex-hull lemma explicitly quantifies over
`(aᵢ,bᵢ,cᵢ) ∈ ℝ³`. The abstract picture must _build_ each line, and here the two
sources divide the labour. Tao constructs integer powers by `⊗`/duals and sketches
fractional ones — `V^{L^(1/2)}` as "the space of formal signed square roots `±l^(1/2)`
of non-negative elements `l` in `V^L`, with a rather complicated but explicitly
definable rule for addition and scalar multiplication" — noting they occur in nature
(half-densities in Fourier integral operators), and flags the higher-dimensional
obstruction: "there are representation-theoretic obstructions to taking arbitrary
fractional powers of units" for vector quantities, spinors (via the spin double cover)
being the exception that proves the rule. JMV make the scalar case fully rigorous and
effortless: because positive spaces are zero-free and positive, `U^q := Rat_q(U*, ℝ⁺)`
works uniformly for **all** `q ∈ ℚ` with the expected calculus (`U^p ⊗̂ U^q ≅ U^(p+q)`,
`(U^p)^q ≅ U^(pq)`) — no sign bookkeeping, no formal-root case analysis; their positron
charge `e ∈ L^(3/2) ⊗̂ M^(1/2)` uses it in earnest. **Irrational** exponents are an open
edge: a reader asked in February 2018 whether the construction extends to irrational
powers (motivated by "prefactors in two-point correlation functions for interacting
conformal field theories"); no answer appears in the captured comment page, and neither
source constructs `U^r` for irrational `r` (JMV's rational maps are ℚ-indexed by
definition).

### Affine quantities (temperature, dates)

Tao's own text handles the affine phenomenon — but for _space_, not temperature: with
structure group `E(2)` (translations included), **position** and **displacement**
become different kinds; positions do not add ("when adding a position vector to another
position vector, one obtains a new type of vector which is neither a position vector
nor a displacement vector"), position + displacement = position, and "convex
combinations of position vectors still give a position vector" — the complete affine
calculus, derived rather than postulated. Temperature, calendar dates, and gauge
pressure appear nowhere in the post; the extension is supplied in the captured comment
thread by the finance commenter (7 January 2025): "A quantity such as temperature is
modeled by a 1-dimensional affine space (possibly with boundary), where the associated
vector space models the change in the affine quantity", so that "it makes no sense to
add two temperature measurements but it does makes sense to add a change in temperature
to a temperature" \[sic\]. JMV are silent on affine quantities (their positive spaces
have no additive origin at all, but that models positivity, not affineness). The
formal-story-with-torsors — an affine line is a torsor over its difference line — is
[torsor-representation][torsor] territory: Baez's essay, that page's primary source,
develops temperature zeroes, voltage grounds, and calendar dates natively.

### Logarithmic quantities, angles — silences

Tao states the classical constraint — transcendental functions "should only be applied
to arguments that are dimensionless", with the rapidity `arctanh(v/c)` as the paradigm
— and the abstract picture enforces it structurally: `exp` on a line `V^L` is not a
term. Neither source addresses **logarithmic quantities** as first-class citizens
(decibels, pH, magnitudes): there is no `log`-image space construction, and the closest
JMV get is the observation that power series in physics "always involve real numbers,
i.e. unscaled quantities (usually called “pure numbers”), obtained as ratio of two
scales belonging to the same positive space" — the ratio-then-log recipe, with the log
kept outside the formalism. **Angles** are likewise absent as quantities: rotation
groups appear as structure groups (`O(2)`, `O(3)`), but angle-as-dimension (the
radian question) is never posed. Both silences are findings; the practical systems'
treatments are catalogued on the system pages.

### Same dimension, different kind (torque vs energy, `Hz` vs `Bq`)

At structure group `(ℝ⁺)³` the formalization is exactly as blind as the
free-abelian-group picture: torque and energy both live in `V^{ML²T⁻²}`; `Hz` and `Bq`
both in `V^{T⁻¹}`. Nothing distinguishes them, and neither source claims otherwise. The
tensor picture's honest advantage is that its **general recipe** recovers _part_ of the
distinction: pass to `O(3)` (or `E(3)`) and torque is an **axial-vector**-valued
quantity while energy is a scalar — different representations, unaddable, exactly as
polar/axial reasoning predicts parity rules ("either all terms have an even number of
cross products, or all terms have an odd number"). But this is the vector-character
distinction, not a per-radian or per-count semantics: scalar same-dimension pairs
(`Hz`/`Bq`, energy/torque-magnitude) stay conflated at every group in the post. Kind
systems that split these by fiat are surveyed under
[type-system mechanisms][mechanisms].

### Failure modes, concretely

- A **hybrid** parametric quantity (`10L⁻¹ + 30L⁻¹T`) has no abstract counterpart —
  the dictionary's clause (iii). Anything producing hybrids (naive summation across
  dimensions, inhomogeneous norms) exits the abstract framework entirely.
- **Non-power-law parameter dependence** (`L^{sin(M+T)}`) is a dimensionful object with
  no dimension — the parametric universe is bigger than the graded one, and only the
  graded part transfers.
- **Inhomogeneous norms**: a 2020 comment exchange (M. Calvao, 21 July 2020; Tao's
  reply, 29 July 2020) works out that standard `C^k`-norms — `max|x| + max|x′|` — "do
  not have a scale invariance and so cannot be assigned a single “dimension”; at best
  they can be viewed as a combination of expressions of different homogeneity", the fix
  being an explicit length-scale parameter multiplying the derivative terms. Real
  mathematical practice contains dimensionally hybrid objects, and the formalism's
  response is to parametrise them, not to type them.

---

## Mechanization

Neither source mechanises anything, and no proof-assistant formalization of the
tensor-of-lines picture exists in this survey's corpus — the Lean development the
survey tracks formalises the [group-of-dimensions picture][free-abelian] instead (see
[Lean / mathlib][lean-units]). What the corpus does contain:

- **A reader's C++ embedding.** The captured comment of 7 January 2025 reports an
  independent rediscovery in quantitative finance (any asset can serve as numéraire —
  a currency is a unit):

  > _"It is in this context that I first realized that dimensional analysis could be
  > modeled by 1-dimensional vector spaces, their duals and tensor products, and
  > 1-dimensional affine spaces. I in fact implemented this in C++ code, where these
  > concepts combined with strong type checking caught a lot of my coding errors."_
  > — comment of 7 January 2025 (`tao-2012-…-blog.html`, comment page)

  This is the tensor-of-lines picture's practical thesis in one sentence: lines map to
  nominal types, tensor/dual composition maps to type-level arithmetic, and dimensional
  errors become type errors.

- **The type-system lineage is the exponent shadow.** [Kennedy's dimension
  types][kennedy-types] — mechanised in [F# units of measure][fsharp-uom] and the
  [GHC `uom-plugin`][haskell-uom-plugin] — type-check exactly the fragment the
  dictionary theorem covers (pure dimensions, `ℚ`- or `ℤ`-valued exponents), with the
  lines erased to their exponent names; Kennedy's semantic story (types as
  scaling-invariance properties) is the parametric viewpoint, treated on that page
  and — as torus-equivariance — on the [torsor page][torsor]. The affine calculus Tao
  derives from `E(2)` — point vs displacement — is the design rationale behind the
  quantity/point splits of the practical libraries; the [torsor page][torsor]
  catalogues that point-type discipline, with verified file paths across
  [mp-units][cpp-mp-units], [Au][cpp-au], Pint, and Unitful.jl.
- **JMV in the field.** The positive-space formalism predates its own foundations
  paper: JMV cite seven prior papers in covariant classical and quantum mechanics that
  already used scale spaces and scaled bundles operationally (their refs.
  \[4, 7, 8, 9, 13, 14, 15\]) — a formalization adopted by working mathematical
  physicists, if not by proof assistants.

**Decision procedure.** Checking dimensional consistency of a tensor expression
reduces to additive arithmetic on exponent vectors in `ℚⁿ` — decidable, linear-time,
and identical to the [free-abelian-group][free-abelian] computation, because the map
`k ↦ |k|` (JMV Note 3.2) is a complete invariant of scale spaces. Scale-basis and
π-group computations are `ℚ`-linear algebra: `det ≠ 0` (Prop 3.4), rank–nullity for
the invariant count. The specifically tensorial cost is **coherence bookkeeping**: the
several composites `(V^M ⊗ V^L) ⊗ V^T`, `V^M ⊗ (V^L ⊗ V^T)`, `V^L ⊗ V^M ⊗ …` are
distinct-but-canonically-isomorphic objects, and an implementation must either
normalise (fix an exponent-vector normal form — what every type system in the survey
does) or thread the canonical isomorphisms explicitly. The comment thread records the
issue: a reader objected (16 October 2018) that "the commutativity of multiplication is
not very natural" since `length·time` and `time·length` are inequivalent as tensor
products unless one fixes "some arbitrary ordering"; Tao's reply (24 October 2018)
concedes the mechanism —

> _"Well, in practice this is not a problem because there is a canonical isomorphism
> `ι: X ⊗ Y → Y ⊗ X` between the two different ways to take the tensor product of two
> vector spaces (and similarly for tensor products `(X ⊗ Y) ⊗ Z`, `X ⊗ (Y ⊗ Z)` of
> three spaces). So, up to the abuse of notation of identifying these two spaces,
> multiplication becomes commutative and associative again."_
> — Tao, comment reply of 24 October 2018

"Up to the abuse of notation" is free on a blackboard and is precisely the part a
mechanised development must pay for — either in normal forms or in coherence lemmas.

---

## Open problems & frontier

- **Irrational exponents in the abstract picture.** The parametric model takes real
  exponents in stride; the constructed lines stop at `ℚ` in both sources. The 2018
  CFT-motivated question (anomalous dimensions are generically irrational) is
  unanswered in the captured page, and `U^r` for `r ∈ ℝ` would need a completion or a
  direct `Rat_r`-style definition whose calculus (JMV Props 2.15–2.16) survives — open
  in this corpus.
- **Coherence versus normal forms.** Tao's "up to the abuse of notation" and the
  commenter's ordering objection mark a real formalization decision: a mechanised
  tensor-of-lines theory must either prove the canonical-isomorphism coherence it uses
  or collapse lines to exponent vectors (at which point it _is_ the
  [free-abelian-group formalization][free-abelian]). Whether anything is genuinely
  gained by keeping the lines around in a proof assistant — rather than on the
  semantic side — is unresolved.
- **Signed lines versus positive half-lines.** The two sources disagree at the root:
  Tao's carriers are ordered lines that "permit for now the possibility of negative
  values" for masses and lengths, buying vector-space algebra at the cost of
  complicated fractional powers (formal signed roots); JMV's carriers are zero-free
  positive spaces, buying effortless `ℚ`-powers at the cost of losing subtraction and
  needing the vector extension for signed quantities like charge. Tao's 2025
  convex-cone comment shows the pictures are interconvertible; which is the _right_
  primitive — and what "physically positive" should mean structurally — is exactly the
  kind of disagreement this survey records rather than resolves.
- **The hybrid fragment.** Tao proves one theorem about dimension-heterogeneous
  expressions (the convex-hull criterion) and gestures at the graded-formal-sum algebra
  that would host them ("formal sums of spaces of different dimensionalities",
  Clifford algebras, `exp(ω)`). A worked-out theory of the hybrid layer — which
  inequalities amplify to pure ones, what replaces transfer — does not exist in these
  sources.
- **Lines-first versus action-first.** Within this page's sources the torsor
  packaging deflates: Tao's closing paragraph replaces the parameter group by
  `ℝ`-torsors and immediately concludes "one may as well work entirely in the
  abstract setting instead", and JMV's Note 2.3 exhibits every positive space as an
  `ℝ⁺`-torsor without using the word (see the relation passage under the dictionary
  theorem). But the [torsor-representation][torsor] page's sources take the opposite
  primitive — the group action, or the dimension fibration — and derive from it
  structure this page's sources postulate (there, dimension multiplication is forced
  by distributivity; here it is the tensor product, given). Whether anything beyond
  direction of explanation separates the two — the captured thread already points
  outward to Zapata-Carratalá's dimensioned algebra as "a more abstract version" — is
  work for that page and the [comparison capstone][comparison].
- **Unproven π, unclaimed lineage.** Neither source proves Buckingham π inside the
  formalism (JMV defer to Barenblatt; Tao gives an instance), and neither cites the
  classical quantity-calculus lineage — a commenter had to point Tao to
  [Whitney 1968][whitney], whose birays are recognisably these lines' ancestors.
  Connecting the tensor picture rigorously to the π theorem's hypotheses (which live on
  the [Buckingham π page][buckingham-pi]) and to the axiomatic lineage is synthesis
  work this tree schedules for its [comparison capstone][comparison].
- **Recorded silences.** Logarithmic quantities, angles, and scalar same-dimension
  kinds (`Hz` vs `Bq`) are unaddressed in both sources — the tensor machinery has no
  stated position, and the survey treats that as a finding about the formalization's
  perimeter, not an oversight to be paraphrased away.

---

## Sources

- T. Tao, ["A mathematical formalisation of dimensional analysis"][tao-blog], _What's
  new_, 29 December 2012 — the parametric and abstract formalizations, the dictionary
  and transfer principle, weight spaces, hybrid quantities and the convex-hull
  criterion, structure-group generalisations (`GL₃`, `E(2)`, Poincaré, gauge, parity),
  fractional powers, Sobolev applications, and the closing torsor remarks. All quotes
  transcribed from the local capture
  `tao-2012-formalisation-dimensional-analysis-blog.html` (LaTeX recovered from image
  `alt` text); comment-thread quotes (2018–2025: fractional exponents, commutativity,
  Whitney pointer, `C^k` norms, finance/C++, convex cone, Zapata-Carratalá pointer) from
  the same capture's newest comment page.
- J. Janyška, M. Modugno & R. Vitolo, ["Semi-vector spaces and units of
  measurement"][jmv-arxiv], arXiv:0710.1313v1, 2007 — semi-vector spaces over `ℝ⁺`
  (Def 1.1), sesqui-tensor products and the universal vector extension (Defs 1.29,
  1.44; Props 1.36, 1.43), semi-tensor products (Thm 1.52), positive spaces (Def 2.1,
  Note 2.3), rational maps and powers (Defs 2.5, 2.12; Props 2.15–2.16), scale spaces
  and units (Defs 3.1, 3.3; Note 3.2; Prop 3.4), coupling scales, scaled bundles and
  operators (§3.2), and the dimensional-analysis interplay (§3.4). Local:
  `janyska-modugno-vitolo-2007-semi-vector-spaces-units-arxiv.pdf`.
- C. Zapata-Carratalá, ["Dimensioned Algebra: the mathematics of physical quantities"][zapata-arxiv],
  arXiv:2108.08703 — pointed to from the captured comment thread;
  covered on the [torsor representation][torsor] page, not used as a source here.
- Related deep-dives: [theory index][theory-index] · [units-of-measure
  umbrella][umbrella] · [concepts glossary][concepts] · [Whitney's quantity
  structures][whitney] · [Buckingham π][buckingham-pi] · [free abelian group of
  dimensions][free-abelian] · [torsor representation][torsor] · [Kennedy's dimension
  types][kennedy-types] · [type-system mechanisms][mechanisms] · systems:
  [F# units of measure][fsharp-uom] · [GHC `uom-plugin`][haskell-uom-plugin] ·
  [mp-units (C++)][cpp-mp-units] · [Au (C++)][cpp-au] · [Lean / mathlib][lean-units] ·
  [comparison capstone][comparison].

<!-- References -->

<!-- Same-tree theory siblings -->

[theory-index]: ./index.md
[whitney]: ./whitney.md
[buckingham-pi]: ./buckingham-pi.md
[free-abelian]: ./free-abelian-group.md
[torsor]: ./torsor-representation.md
[kennedy-types]: ./kennedy-types.md
[mechanisms]: ./type-system-mechanisms.md

<!-- Tree umbrella / concepts / comparison -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md

<!-- System pages -->

[fsharp-uom]: ../fsharp-uom.md
[haskell-uom-plugin]: ../haskell-uom-plugin.md
[cpp-mp-units]: ../cpp-mp-units.md
[cpp-au]: ../cpp-au.md
[lean-units]: ../lean-mathlib-units.md

<!-- External primary sources -->

[tao-blog]: https://terrytao.wordpress.com/2012/12/29/a-mathematical-formalisation-of-dimensional-analysis/
[jmv-arxiv]: https://arxiv.org/abs/0710.1313
[zapata-arxiv]: https://arxiv.org/abs/2108.08703
