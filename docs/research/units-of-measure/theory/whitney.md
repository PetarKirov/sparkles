# Whitney's Axiomatic Quantity Structures

Hassler Whitney's two-part _The Mathematics of Physical Quantities_ (American
Mathematical Monthly, 1968) is the axiomatic high-water mark of the classical
quantity-calculus lineage. Instead of modelling a quantity as "a real number with a
unit attached", it takes the quantities themselves — masses, lengths, time intervals
— as the primitive elements of one-dimensional measurement models called **rays** and
**birays**, constructs the number systems `ℕ → ℚ⁺ → ℝ⁺ → ℝ` afterwards as _operators_
on those models, and (in Part II) assembles finitely many base birays into a
**quantity structure** in which every quantity factors uniquely as a numerical
multiple of a product of powers of base units — the representation theorem that every
later formalization either inherits, restricts, or reacts against. [Raposo's algebraic
fiber bundles][raposo-2018], [Jonsson's quantity spaces][jonsson-2021], and
(structurally, though — as shown below — without citation) [Kennedy's dimension
types][kennedy-types] are all recognizable as refinements of exactly this picture.

> [!NOTE]
> **Provenance discipline is part of this page's content.** Both Monthly papers are
> paywalled. Part I is quoted from a local two-page **re-typeset excerpt of its
> introduction only** (`whitney-1968-physical-quantities-i-monthly-excerpt.pdf`) —
> Whitney's own framing, but _only_ the framing: the actual postulate lists for rays
> and birays are behind the paywall. Part II was **not inspected at all**; every
> Part II claim below is grounded in explicit restatements by [Raposo
> 2018][raposo-2018]/[2019][raposo-2019] and [Jonsson 2021][jonsson-2021] and is
> tagged "as restated by …". Where the restatements disagree (they do, on the
> exponent ring), the disagreement is reported, not resolved. Kennedy's 1996 thesis —
> which this survey initially expected to restate Whitney — in fact **never cites
> him** (checked against the full text of the local copy); it appears here as a
> structural parallel and for mechanization, not as a witness for Whitney's
> constructions. Local artifact paths below are file names under the survey's pinned
> corpus (`$REPOS/papers/units-of-measure/`, catalogued in the grounding ledger).

---

## At a glance

| Dimension                | Whitney's quantity structures                                                                                                                                                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Primary objects          | One-kind measurement models: **rays** (positive quantities, "like a half line") and **birays** (signed, "like an oriented line with starting point"); Part II: **quantity structures** built from finitely many base birays                |
| Quantity                 | An element of a ray/biray — the physical property itself, taken as primitive ("why not let this property itself be an element of the model?")                                                                                              |
| Unit                     | Any element `l₀` "being kept fixed for a period" — pure bookkeeping, no algebraic privilege; the models contain no distinguished `1`                                                                                                       |
| Dimension                | The biray a quantity belongs to (what Drobot calls a "dimension", Whitney a "biray" — Jonsson App. B.1); in the `ℝ × ℚⁿ` reading, the exponent tuple `(r₁, …, rₙ)`                                                                         |
| Kind                     | No notion beyond biray membership; for counting, distinct kinds are kept apart by using "several isomorphic models" (`bl` ≠ `ck`)                                                                                                          |
| Numbers                  | Not presupposed: `ℕ` (iterated addition), `ℚ⁺` (subdivision), `ℝ⁺` (completeness), `ℝ` (negatives) arise as **operators on the models**; multiplication in `ℝ` is _derived_ via the isomorphism theorem                                    |
| Central theorems         | Part I: **isomorphism theorem** — every ray homomorphism "is necessarily an isomorphism onto"; Part II (as restated): **representation** `q = α · u₁^r₁ ⋯ uₙ^rₙ` uniquely, i.e. `Q ≅ ℝ × ℚⁿ`                                               |
| Exponent ring            | `ℚ` per Raposo 2018, `ℝ` per Raposo 2019, "`Q` or `R`" per Jonsson's comparison table — unresolved here because Part II is uninspected                                                                                                     |
| Cross-dimension addition | Inexpressible at carrier level (`m + l` has no home: different sets, no shared operation) — yet Whitney's own counting example manipulates the formal sum `2 bl + 3 ck` distributively without naming its habitat                          |
| Dimensional analysis     | Part II's subtitle; per Raposo 2019 the `ℝ × ℚⁿ` model "has served its main purpose: giving a proof of Buckingham's Pi Theorem"                                                                                                            |
| Provenance               | Part I inspected via 2-page excerpt (intro §§1–7 only); Part II via restatements in `raposo-2018`/`raposo-2019`/`jonsson-2021`; Kennedy 1996 contains **no Whitney citation**                                                              |
| Modern descendants       | [Raposo's fiber bundle][raposo-2018] (dimension-centred, `ℤ` exponents, one zero _per fiber_), [Jonsson's quantity spaces][jonsson-2021] (proved equivalent to Raposo's), [Kennedy's dimension types][kennedy-types] (structural parallel) |

The neighbouring theory pages carve up the same territory: [Buckingham's Π
theorem][buckingham-pi] is the dimensional-analysis payoff Whitney's Part II
re-founds; the [free-abelian-group view of dimensions][free-abelian] is the
`ℤ`-exponent restriction of Whitney's biray algebra; [Tao's tensor-of-lines
construction][tensor-of-lines] and the [torsor representation][torsor] are two
modern answers to the fiber structure Whitney's rays anticipate; the [comparison
capstone][comparison] places all of them side by side.

---

## Primary sources

- **H. Whitney, ["The Mathematics of Physical Quantities. Part I: Mathematical
  Models for Measurement"][whitney-i], _The American Mathematical Monthly_ 75(2),
  February 1968, pp. 115–138.** _Inspected via excerpt only_: the local artifact
  `whitney-1968-physical-quantities-i-monthly-excerpt.pdf` is a two-page re-typeset
  of the introduction (§§1–7) — it confirms title, part subtitle, venue, and date
  ("American Mathematical Monthly. February 1968"), and even garbles the byline to
  "Whitney Hassler". The page range 115–138 is from the publisher's bibliographic
  record (the DOI resolves to Monthly 75(2), first page 115); the range itself is
  otherwise [unverified] against a local artifact. All Part I quotes below are from
  this excerpt; note that a re-typeset excerpt carries transcription risk (it
  visibly confuses `l`/`1` in places), flagged where it matters.
- **H. Whitney, ["The Mathematics of Physical Quantities. Part II: Quantity
  Structures and Dimensional Analysis"][whitney-ii], _The American Mathematical
  Monthly_ 75(3), March 1968, pp. 227–256.** _Not inspected — grounded via
  restatement._ The full citation including the 227–256 page range is printed in
  both local restatements: Raposo 2018 reference [22]
  (`raposo-2018-algebraic-structure-quantity-calculus-msr.pdf`, p. 156) and Jonsson
  2021 reference [31]
  (`jonsson-2021-magnitudes-scalable-monoids-quantity-spaces-arxiv.pdf`).
- **Á. P. Raposo, ["The Algebraic Structure of Quantity Calculus"][raposo-2018],
  _Measurement Science Review_ 18(4):147–157, 2018** (local:
  `raposo-2018-algebraic-structure-quantity-calculus-msr.pdf`). _Inspected._
  Positions Whitney in the "unit-centred" lineage (with Drobot and Carlson),
  restates the lineage's structure as `ℝ × ℚⁿ` with the unique factorization
  `q = α u₁^r₁ ⋯ uₙ^rₙ`, criticizes it, and replaces it with a dimension-centred
  algebraic fiber bundle.
- **Á. P. Raposo, ["The Algebraic Structure of Quantity Calculus II: Dimensional
  Analysis and Differential and Integral Calculus"][raposo-2019], _Measurement
  Science Review_ 19(2):70–78, 2019** (local:
  `raposo-2019-algebraic-structure-quantity-calculus-ii-msr.pdf`). _Inspected._
  Restates the Whitney-lineage model again (this time with _real_ exponents and the
  family-of-rays-glued-at-zero picture) and credits it with the proof of the Π
  theorem; then proves a Π theorem with integer exponents in the fiber-bundle
  setting.
- **D. Jonsson, ["Magnitudes, Scalable Monoids and Quantity Spaces"][jonsson-2021],
  arXiv:2108.02106 (v6, January 2023)** (local:
  `jonsson-2021-magnitudes-scalable-monoids-quantity-spaces-arxiv.pdf`).
  _Inspected._ Appendix B.1 is the most detailed local restatement of Whitney's
  Part II construction (the multiplicative vector space `V_Q` with embedded scalars,
  birays, derived addition, which results Whitney _proves_), plus a
  primitive-vs-derived comparison table across Drobot/Quade/Whitney/Carlson/
  Jonsson/Raposo.
- **A. J. Kennedy, ["Programming Languages and Dimensions"][kennedy-thesis], PhD
  thesis, University of Cambridge, Computer Laboratory TR-391, 1996** (local:
  `kennedy-1996-programming-languages-dimensions-thesis.pdf`). _Inspected —
  negative finding:_ a full-text search of the local copy finds **no citation of
  Whitney** (nor of Drobot or Carlson); Kennedy's related work engages Wand &
  O'Keefe, Goubault, House, and Rittri instead. His `ℤ`-module treatment of
  dimensions (thesis Appendix B) and scaling-invariance semantics (ch. 6–7) parallel
  Whitney structurally but were developed on a separate track. Used below for
  [Mechanization](#mechanization).
- **S. Drobot, "On the Foundations of Dimensional Analysis", _Studia Mathematica_
  14:84–99, 1953.** The local artifact
  (`drobot-1953-foundations-dimensional-analysis-studia.pdf`) is an image-only scan
  and was not text-inspected for this page; Drobot appears here only as restated by
  Raposo and Jonsson ("The approach introduced by Drobot [5] and developed by
  Whitney [31]…"). The [Buckingham Π page][buckingham-pi] treats Drobot directly.
- **D. Carlson, "A mathematical theory of physical units, dimensions and measures",
  _Archive for Rational Mechanics and Analysis_ 70:289–304, 1979.** [unverified] —
  no local artifact; cited from Raposo 2018 reference [23] and Jonsson's Appendix
  B.1 restatement.
- **J. de Boer, "On the history of quantity calculus and the international system",
  _Metrologia_ 31:405–429, 1994.** [unverified] — no local artifact; both Raposo and
  Jonsson lean on it as the standard history of the lineage.

---

## Formal core

### Part I: measurement models before numbers

Whitney's opening move (Part I §1) is a critique of exactly the "reals with attached
units" design that most programming-language libraries still ship:

> _"Commonly one takes R+ or R as a model for measurement. There are disadvantages
> in this, however. These models contain a specific number 1, and there is no
> natural way of putting this number in correspondence with a particular
> measurement; moreover, the models contain an operation of multiplication, with no
> natural physical counterpart."_ — Whitney, _The Mathematics of Physical
> Quantities_, Part I §1 (`whitney-1968-physical-quantities-i-monthly-excerpt.pdf`,
> p. 1)

The fix is to admit the physical property itself as a mathematical object:

> _"Let us consider the problem of choosing a model M for masses. An object A has a
> certain property which we call its "mass" ; why not let this property itself be an
> element of the model? As far as the structure of the model is concerned, we need
> not theorize on what "mass" really is; we need merely give it certain properties
> in the model."_ — Whitney, Part I §1 (excerpt, p. 1)

The model `M` gets an **addition** — because combining two objects `A`, `B` into one
object `C` gives `m_C = m_A + m_B`, a real physical process — "and any further
properties we choose". Nothing else is primitive: no `1`, no multiplication, no
numbers. Two model shapes cover most measurement:

> _"The two types of models that best fit in most situations we shall call "rays"
> and "birays." A ray (like a half line) is used for positive measurements, and a
> biray ( like an oriented line with starting point ), for measurements of
> quantities both positive and negative."_ — Whitney, Part I §1 (excerpt, p. 1)

Numbers then appear as **operators on the model** (§2), in a tower that recapitulates
how measurement actually refines:

```text
ℕ    iterated addition:      2l = l + l,   3l = l + l + l, …
     ("Thus N appears as a natural set of operators on our model.")
ℚ⁺   subdivision:            find l′ with 3l′ = l, set l′ = (1/3)l, then 2l′ = (2/3)l
ℝ⁺   completion:             "if our model has a certain completeness property,
                              we may enlarge Q+ to R+ as operator system"
ℝ    signed quantities:      "if we have negative quantities, we may enlarge R+ to R"
```

Equational reasoning happens _inside_ the model (§3): Whitney's own examples are

```text
5 cakes + 2 cakes = (5 + 2)cakes = 7 cakes
2 yd = 2(3ft) = (2 x3)ft = 6ft.
```

(transcribed exactly from the re-typeset excerpt, spacing artifacts included), with
the punchline that model-elementhood replaces "measures the same as":

> _"The fact that "2 yd" and "6 ft" name the same element of the model enables us to
> say they are equal; there is no need for such mysterious phrases as "2 yd measures
> the same as 6 ft.""_ — Whitney, Part I §3 (excerpt, p. 1)

> [!IMPORTANT]
> The excerpt ends at the introduction. Whitney says the models are introduced
> _postulationally_ and that "The postulates used for rays and birays are few in
> number and simple in character, and correspond to simple experimental phenomena"
> (§5) — but the postulate lists themselves are in the paywalled body. This page can
> quote Whitney's design intent verbatim; it cannot quote his axioms.

### The Part I isomorphism theorem

The excerpt does state Part I's central theorem, in Whitney's own words:

> _"A basic theorem in the subject is an isomorphism theorem; a homomorphism of one
> ray into another is necessarily an isomorphism onto, and has certain additional
> properties (and similarly for birays). This theorem is a great aid in setting up
> the theory; in particular, with its use, multiplication in R+ and in R is
> introduced and its properties derived with a minimal effort."_ — Whitney, Part I
> §5 (excerpt, p. 2)

Two consequences matter downstream. First, **rigidity**: rays admit no interesting
quotients or sub-models — any structure-preserving comparison of two rays is a full
identification, so a ray is "one-dimensional" in the strongest sense, and choosing a
single element (`l₀`) coordinatizes the whole ray. Second, **numbers gain their
multiplication from measurement**, not vice versa: composing the operator "×2" with
the operator "×3" on any ray must again be an operator, and the isomorphism theorem
makes that composite well-defined — this is how "multiplication in `R+` and in `R`
is introduced". The same rigidity resurfaces in [Raposo's bundle][raposo-2018] as
"All fibers are isomorphic as vector spaces, and isomorphic to the field `F`"
(`raposo-2018-…msr.pdf`, §2.2) and in the [torsor reading][torsor] of fibers.

### Part II: quantity structures (as restated)

Part I flags the plan: "in mechanics, one uses separate rays M, L, T for measurement
of mass, length and time. (We study structures containing several rays in Part II.)"
(excerpt, p. 2). For what Part II actually builds, the best local witness is
[Jonsson's Appendix B.1][jonsson-2021]:

- The set of quantities itself — "rather than a set of pre-units" — forms a vector
  space `V_Q` **written multiplicatively** over a field of exponents: the "scalar
  product" is exponentiation `q^λ`. `V_Q` is also assumed to _contain_ a set `R` of
  scalars, identified with the dimensionless quantities, giving a second scalar
  action `r·q` (Jonsson, App. B.1: "the authors identify dimensionless quantities
  with scalars").
- Quantities of the same kind form classes — "called 'dimensions' by Drobot and
  'birays' by Whitney". Addition is **derived**, not primitive: for `q = α·u` and
  `r = β·u` with `u` non-zero, `q + r = (α + β)·u` — and, Jonsson notes pointedly,
  _"although only Whitney proves that this definition is legitimate"_ (i.e. proves
  independence from the chosen `u`).
- The biray algebra is likewise derived from the quantity algebra: `[x][y] = [xy]`
  and `[x]^λ = [x^λ]`, where `[q]` is the biray containing `q`. Whitney additionally
  proves distributivity `q(r + s) = qr + qs` for `[r] = [s]`, and cancellation:
  `qs = rs` with `s` non-zero implies `q = r` (all per Jonsson, App. B.1).

Jonsson's comparison table (App. B.1) records Whitney's choice of primitives:
_product of quantities_ and _exponentiation of quantities_ are **primitive**;
_addition_, _scalar product_, _product of dimensions_ and _exponent of dimensions_
are all **derived**; the "ring of exponents" is listed as "`Q` or `R`". [Raposo
2018][raposo-2018] gives the complementary bird's-eye view of the same lineage:

> _"this structure starts with a system of units {u₁, . . . , uₙ} and writes any
> quantity q in a unique way as q = α u₁^r₁ · · · uₙ^rₙ … where α is a real number
> and r₁, . . . , rₙ are rational numbers. Therefore, the algebraic structure
> depicted by this theory is R × Qⁿ, where the factor R hosts the numerical value of
> q relative to this system of units, while Qⁿ hosts the rational exponents of the
> units and exhibits a linear space structure."_ — Raposo,
> `raposo-2018-algebraic-structure-quantity-calculus-msr.pdf`, §1 (notation lightly
> flattened from the PDF's `u₁^r1 ··· uₙ^rn`)

and [Raposo 2019][raposo-2019] adds the geometric picture and the payoff:

> _"The set of quantities, thus, adopts the form of a family of rays, each
> identified and spanned by a unit as in (1) by letting α run through the reals. The
> rays coincide in a point, the zero of the algebraic structure. The numbers
> (r₁, . . . , rₙ) are referred to as the dimensions of the quantity q. This
> algebraic structure has served its main purpose: giving a proof of Buckingham's Pi
> Theorem."_ — Raposo, `raposo-2019-algebraic-structure-quantity-calculus-ii-msr.pdf`, §1

### The representation theorem, with proof sketch

Assembling the two restatements, Part II's central result is a **representation (and
implicitly classification) theorem**:

```text
Theorem (representation; Part II as restated by Raposo 2018 §1, Raposo 2019 §1,
Jonsson 2021 App. B.1).  Let Q be a quantity structure with a fundamental system
of units u₁, …, uₙ.  Every quantity q ∈ Q has a unique expression

    q = α · u₁^r₁ ⋯ uₙ^rₙ          α ∈ ℝ;  rᵢ ∈ ℚ (2018) / ℝ (2019)

and the coordinate map q ↦ (α, (r₁, …, rₙ)) is an isomorphism Q ≅ ℝ × ℚⁿ with

    (α, r) · (β, s) = (αβ, r + s)         product of quantities
        λ · (α, r)  = (λα, r)             scalar action
    (α, r) + (β, r) = (α + β, r)          addition — same exponent tuple only
    (α, r) + (β, s)   undefined, r ≠ s
```

Any two quantity structures with the same number of fundamental units are therefore
isomorphic — non-canonically, since the isomorphism threads through the chosen
units. (Raposo proves the exact analogue for his fiber bundles as his Theorem 2 —
"Two spaces of quantities over the same field, free of zero divisors, are isomorphic
if and only if they have the same rank" — and notes of the coordinate isomorphism
"the isomorphism is not canonical, for it depends on the system of units chosen",
`raposo-2018-…msr.pdf` §4, Example 4.5.)

> [!WARNING]
> The sketch below is a **reconstruction** from Part I's quoted machinery plus the
> Part II restatements; Whitney's own proof was not inspected. It is the argument
> the restated ingredients force, not a paraphrase of his text.

1. **Each biray is one-dimensional over the operators.** Fix a non-zero `u` in a
   biray `B`. Part I's operator construction gives `α·u ∈ B` for every `α ∈ ℝ`, and
   the isomorphism theorem makes the assignment `α ↦ α·u` an isomorphism of the
   operator biray `ℝ` onto `B`: every `q ∈ B` is `q = α·u` for a **unique** `α`.
   (This uniqueness is also exactly what makes the derived addition
   `α·u + β·u = (α+β)·u` legitimate — the fact Jonsson highlights Whitney alone
   bothered to prove.)
2. **The birays form an exponent-vector space.** The derived operations
   `[x][y] = [xy]` and `[x]^λ = [x^λ]` make the set of birays a vector space over
   the exponent field, written multiplicatively (for `ℤ` exponents this is a
   [free abelian group][free-abelian]). The fundamental birays `[u₁], …, [uₙ]` are
   independent generators, so every biray has a unique expansion
   `[q] = [u₁]^r₁ ⋯ [uₙ]^rₙ` — the exponent tuple `(r₁, …, rₙ)`.
3. **Compose.** Given `q`, step 2 produces the unique tuple with
   `[q] = [u₁^r₁ ⋯ uₙ^rₙ]`; then `q` and `u₁^r₁ ⋯ uₙ^rₙ` share a biray, so step 1
   produces the unique `α` with `q = α · (u₁^r₁ ⋯ uₙ^rₙ)`.
4. **Operations transport.** Multiplicativity of the coordinate map follows from
   `(α·x)(β·y) = αβ·xy` (scalars commute out — in Whitney's setting because scalars
   _are_ dimensionless quantities; compare Jonsson's Lemma 2.5, which proves the
   same identity from his scalable-monoid axioms); addition transports within a
   fiber by step 1; and `dim`-preservation is step 2. Hence `Q ≅ ℝ × ℚⁿ` with the
   componentwise operations above. ∎

Dimensional analysis then rides on the representation: a change of units rescales
`α` and fixes `(r₁, …, rₙ)`, so a law invariant under all unit changes can depend
only on the dimensionless combinations — the [Π-theorem][buckingham-pi] route Raposo
2019 credits to this structure. (Raposo's own integer-exponent Π theorem, Theorem
4.4 of `raposo-2019-…msr.pdf`, is the modern descendant, with homogeneity defined as
equivariance under the group `G` of scale-factor maps `χ : D → F*`.)

### What the restatements disagree on

The three local witnesses give three exponent rings for Part II: **`ℚ`** (Raposo
2018: "r₁, . . . , rₙ are rational numbers … `R × Qⁿ`"), **`ℝ`** (Raposo 2019: "where
α, r₁, . . . , rₙ are real numbers"), and **"`Q` or `R`"** (Jonsson's table). With
Part II paywalled this page cannot adjudicate; the honest reading is that the
lineage as a whole worked with dense exponents (contrast Quade and Raposo's `ℤ`,
Kennedy's `ℤ`), and that Whitney's text supports at least `ℚ`. The disagreement is
substantive, not clerical — it decides which [mechanization](#mechanization) theory
applies and whether `q^0.2` denotes anything.

---

## Structural anatomy

Answers to the survey's shared comparability protocol, in Whitney's own terms.

### What structure is primary?

The **one-kind measurement model** — a ray or biray with _addition as its only
primitive operation_, postulated to "correspond to simple experimental phenomena".
Numbers are not part of the furniture: they arrive later as operators, and even
their multiplication is derived (via the isomorphism theorem). In Part II the
primary structure is the **quantity structure**: per Jonsson's table, its primitives
are _product of quantities_ and _exponentiation of quantities_; addition, scalar
product, and the entire dimension algebra are derived. Morphisms are ray/biray
homomorphisms — which the isomorphism theorem collapses to isomorphisms, so the
category of rays is a groupoid, and "the same quantity structure" is only ever
determined up to a unit-dependent isomorphism. [Raposo][raposo-2018] files the whole
construction under the **unit-centred** camp: "authors such as Drobot [21], Whitney
[22], and Carlson [23] developed an algebraic structure which resembled that of
quantity calculus, but was centered on the concept of unit over which the rest of
the set of quantities was built" — the axis along which his own dimension-centred
bundle differs.

### What is a quantity, a unit, a dimension, a kind?

- **Quantity** — an element of a model; the property itself ("why not let this
  property itself be an element of the model?"). A quantity is not a number-unit
  pair; the pair `(α, unit)` is a _description_ that exists only after a unit is
  chosen.
- **Unit** — any element temporarily held fixed, with Whitney's deliberately
  deflationary gloss: _"If we choose a length l0 ∈ L, and compare other lengths with
  it, we may call, l0 our "unit"; this serves merely to remind us that l0 is being
  kept fixed for a period."_ (excerpt, p. 2 — the stray comma is the re-typeset's).
  Units have no algebraic status a non-unit element lacks.
- **Dimension** — the biray itself: a dimension _is_ the set of mutually comparable
  quantities, not a label attached to them ("called 'dimensions' by Drobot and
  'birays' by Whitney" — Jonsson App. B.1). Only in the coordinatized `ℝ × ℚⁿ`
  picture does a dimension flatten to an exponent tuple (Raposo 2019: "The numbers
  (r₁, . . . , rₙ) are referred to as the dimensions of the quantity q").
- **Kind** — no separate notion inside a quantity structure: kind = biray
  membership. But Part I's counting discussion shows Whitney had the missing
  distinction in hand at the model level: "if several such types of quantities are
  considered together, it is better to use several isomorphic models" — balloons and
  cookies get _isomorphic but distinct_ models precisely so that they remain
  un-addable. The formalism distinguishes kinds by **model choice**, not by
  dimension formula; nothing in the Part II restatements says whether that trick
  survives inside a single multiplicatively closed quantity structure (recorded as a
  silence — see [limits](#expressive-power-limits)).

### How is dimensional homogeneity of physical laws expressed?

By **well-formedness, not by a side condition**. Addition and equality exist only
inside a model, so a heterogeneous equation is not _false_ — it is _unformulable_:
there is no set in which `2 yd` and `6 kg` both live to be equated. The "2 yd = 6 ft"
quote above is the positive half: sameness of dimension is sameness of model, and
homogeneous equations are ordinary equalities between elements. The quantitative
half — that a law relating quantities can be reduced to a relation among
dimensionless combinations — is Part II's dimensional-analysis payload (its
subtitle), delivered per Raposo 2019 as the lineage's "main purpose: giving a proof
of Buckingham's Pi Theorem". The modern sharpening of "homogeneity = invariance
under unit change" into equivariance under a group action on fibers is Raposo
2019's Definition 4.1, treated on the [Buckingham Π page][buckingham-pi].

### What acts as a change of units, and what is invariant?

In Whitney's models a change of units is **not a map on quantities at all** — it is
a change of _description_, and the quantities are untouched:

> _"Suppose we wish to "change units," say from ft to in. Then since, for any
> a ∈ R+, a ft = a(12 in) =12 a in, we would replace "the length a" by "the length
> 12a." If any problems about units arise, they are at once resolved by going back
> to the explicit phrase "a ft.""_ — Whitney, Part I §4 (excerpt, p. 2; "=12 a in"
> spacing is the re-typeset's)

Invariant: every element of every model, and every in-model equation — `a ft` and
`12a in` **name the same element**. Variant: the numerals, i.e. the coordinates
induced by the choice of `l₀`. Choosing `l₀` is what "replaces `L` by `R+`", and
Whitney treats that replacement as a notational convenience with an explicit escape
hatch back to the invariant phrase "`a` ft". In the descendants this becomes a
theorem about non-canonicity (Raposo: `Q ≅ F × D` "but the isomorphism is not
canonical, for it depends on the system of units chosen") and, in
[Kennedy's world][kennedy-types], the scaling-invariance ("dimensional invariance")
theorem for well-typed programs — same idea, restated as parametricity.

### Addition across different dimensions: forbidden, partial, undefined, meaningless?

**Inexpressible** — which is stronger than forbidden. `m + l` for `m ∈ M`, `l ∈ L`
is not an error the axioms rule out; it is a string with no denotation, because the
two summands inhabit disjoint carriers and no operation spans them. Whitney's
_reason_ is operationalist and stated up front: a model gets exactly the operations
with physical counterparts. Addition of masses earns its place from a physical
process (aggregating objects); no process aggregates a mass with a length; therefore
no such operation is postulated. Two further Whitney-specific twists sharpen the
survey's central question:

1. **The multiplication asymmetry is inverted at the base.** The standard puzzle
   asks why quantities multiply freely across dimensions but add only within one.
   In Part I, multiplication does not exist _at all_ — it is dismissed in §1 as
   having "no natural physical counterpart" for a single kind. Cross-kind
   multiplication is a **Part II superstructure** erected over the one-kind additive
   models (and even there, per Jonsson's table, it is a _primitive of the
   aggregate_, not something inherited from the models). So for Whitney the deep
   operation is addition-within-a-kind; multiplication is algebraic scaffolding
   added later to relate kinds. The [free-abelian-group page][free-abelian] and
   [Tao's tensor construction][tensor-of-lines] give the two modern justifications
   of that scaffolding.
2. **Whitney himself computes with a cross-kind sum.** Part I §6, on counting:

   > _"However, if several such types of quantities are considered together, it is
   > better to use several isomorphic models. For a plebeian illustration, suppose
   > there will be six children at a party. We wish each to have two balloons and
   > three cookies. What is the total supply needed? The answer is: 6(2 bl + 3 ck) =
   > 6(2 bl) + 6(3 ck) = 12 bl + 18 ck."_ — Whitney, Part I §6 (excerpt, p. 2)

   The expression `2 bl + 3 ck` is manipulated distributively — operators act on it,
   nothing collapses — yet the excerpt never says _what_ it is an element of. The
   natural modern home is a direct sum of the two models, i.e. exactly the
   dimensioned vector spaces of [Hart's multidimensional analysis][hart]; Whitney's
   text (as available here) leaves the sum formal. So the finding is: cross-kind
   addition is **undefined within any one model, but not treated as meaningless as
   notation** — a subtlety most of the lineage's descendants legislate away.

One more delta worth recording: in the `ℝ × ℚⁿ` reading restated by Raposo 2019,
"the rays coincide in a point, the zero of the algebraic structure" — a **single
shared zero** for all dimensions. Raposo's replacement structure takes the opposite
choice (a zero _per fiber_: "0 ms−1 is a different quantity than 0 kg",
`raposo-2018-…msr.pdf` §2.3), and his 2018 critique of the unit-centred lineage is
precisely that its addability relation is not intrinsic: _"we can find quantities
which, dependending on the unit system of choice, can be compared or cannot, can be
added or cannot"_ [sic] (`raposo-2018-…msr.pdf`, §1). Whether Whitney's original
axioms are guilty of that charge cannot be checked against the excerpt; the charge
is Raposo's, aimed at the lineage's `ℝ × ℚⁿ` skeleton.

---

## Expressive power & limits

### What it handles that "reals with attached units" cannot

- **No privileged `1`, no phantom multiplication.** The two defects Whitney indicts
  in `ℝ`-as-model (§1 quote above) are absent by construction: a ray has no
  distinguished element and no internal product. Libraries that store a quantity as
  a bare `double` reintroduce both defects and then police them with types; the
  [type-system-mechanisms page][mechanisms] catalogues how.
- **Affine quantities are first-class.** Part I §6 supplies the exact structure that
  modern libraries bolt on for temperatures and timestamps: _"A model of a somewhat
  different nature is an oriented affine one-dimensional space T\*; this is the
  natural model for instance for moments in time (or positions on a line). There is
  a corresponding biray T of translations of T\*; this is the natural model for
  intervals of time (or directed lengths)."_ (excerpt, p. 2). Point-vs-translation
  is the [torsor story][torsor] avant la lettre — 1968, in the introduction.
- **Zero is a design decision, not an accident.** A ray deliberately excludes zero
  ("in measuring masses, one wishes to allow the mass zero (not present in a ray).
  This extra element may be introduced and related to the remaining elements in the
  obvious manner", §6) — so positivity, signedness, and the existence of a zero are
  per-kind modelling choices rather than global consequences of the number type.
- **Counting, and even non-cancellative measurement.** Progressions get `ℕ`-models;
  distinct countable kinds get distinct isomorphic models (balloons ≠ cookies); and
  §7's finite model — where `a′ + b′ = (a+b)′` saturates at `n′` — deliberately
  breaks the embedding into `ℝ`: "these operations are commutative and associative,
  and the distributive laws hold. However, the cancellation laws fail" (Helen's
  spoon-drawer bookkeeping: `8s + 4s = 8s + 2s`). Measurement models need not be
  sub-structures of the reals at all — a degree of freedom no descendant in this
  survey retains.
- **The reals are an output, not an input.** Part I constructs `ℝ` from the models
  ("the real number system is constructed along with the models in a natural
  manner", §1) — the formalization does not presuppose the very number system whose
  role in measurement it is trying to explain.

### Fractional and irrational exponents

Whitney's exponent field (`ℚ` or `ℝ`, per the restatements) buys closure under
`√` — dimensionally `[x]^λ = [x^λ]` is total — at two documented costs. First,
**over-expressiveness**: Raposo argues physical equations reach quantities only
through product, scalar product, and same-kind addition, "Therefore, only integer
exponents of quantities, and thus of units, should be expected … An algebraic
structure for quantity calculus, which allows fractional exponents, is oversized"
(`raposo-2018-…msr.pdf`, §1 — his `v = √(2T/m)` and pendulum examples show every
physical square root acting on a quantity that is already a square). Second,
**incoherence at the scalars**: Jonsson's verdict on the Drobot–Whitney design is
that the two assumptions — `V_Q` is a vector space over the exponent field via
`(λ, q) ↦ q^λ`, _and_ `V_Q` contains the scalars — "are not fully compatible":
closure forces `q^λ` to be a real number for scalar `q`, which fails unless the
embedded scalars are restricted to `ℝ_{>0}`, "then all quantities must be positive".
And interpretability is open regardless:

> _"while integral powers of quantities make sense in physics, it is not clear how
> to interpret q^0.2 or q^π, where q is a "dimensionful" quantity rather than a
> number."_ — Jonsson,
> `jonsson-2021-magnitudes-scalable-monoids-quantity-spaces-arxiv.pdf`, App. B.1
> (superscripts restored from the PDF's layout)

### Same dimension, different kind (torque vs energy, `Hz` vs `Bq`)

Inside one quantity structure there is no mechanism: the biray of a product is
_determined_ by `[x][y] = [xy]`, so once torque and energy are both `M L² T⁻²`-birays
they are the _same_ biray and freely addable. Whitney's isomorphic-copies trick from
counting does not obviously survive multiplicative closure — duplicating a biray
breaks the uniqueness of the exponent expansion that the representation theorem
needs — and neither the excerpt nor any restatement addresses the question
(recorded as a **silence**). The descendants inherit the gap knowingly: Raposo,
citing the VIM, concedes "quantities of the same kind belong to the same fiber,
while the opposite is not necessarily true. However, the algebraic structure cannot
distinguish this detail" (`raposo-2018-…msr.pdf`, §2.2). The systems that _do_
distinguish torque from energy (notably [mp-units' `quantity_spec`
hierarchy][cpp-mp-units]) had to add structure the Whitney lineage never had.

### Logarithmic quantities, angles — silences

- **Logarithmic scales** (`dB`, `pH`): nothing in the excerpt or in any restatement.
  A logarithm of a dimensionful quantity is exactly a non-integer/transcendental
  functional image, which the previous subsection shows the lineage cannot
  interpret; the silence is therefore consistent but total.
- **Angles**: no treatment. Worse, the lineage's identification of dimensionless
  quantities with scalars (Jonsson: "the authors identify dimensionless quantities
  with scalars") forecloses the modern move of giving angle its own dimension —
  a dimensionless `rad` collapses into the bare number `1`. (Raposo's fiber bundle
  keeps the dimension-one fiber as a distinguished object — "naturally isomorphic
  with the field" but still a fiber — which at least leaves the question visible.)
- **Quantized quantities**: Raposo 2019 §1 notes that one-dimensional vector-space
  fibers "cannot be the ultimate model … for it does not fit properly to quantized
  quantities" — a limit the fibers inherit directly from Whitney's rays.

---

## Mechanization

No proof assistant or library in this survey mechanizes rays, birays, or Whitney's
quantity structures as such — a **negative finding** (checked: the local corpus's
Lean artifacts formalize dimensions as groups for [Buckingham-Π
purposes][lean-units], and `mathlib4` has nothing dedicated to physical quantities
at all; see the [Lean page][lean-units]). What is mechanized, pervasively, is the
**decision problem the representation theorem induces**: once `Q ≅ ℝ × ℚⁿ` (or
`ℝ × ℤⁿ`), checking dimensional consistency is linear algebra over the exponent
ring, and _inference_ is unification in the corresponding equational theory. The
exponent-ring fork in the restatements maps exactly onto the mechanization
landscape, per [Kennedy's thesis][kennedy-thesis] (§3.5's summary, quoted from
`kennedy-1996-programming-languages-dimensions-thesis.pdf`):

| Exponent ring                               | Equational theory of dimensions       | Decision procedure                                                                                                                                                                                                                                                 |
| ------------------------------------------- | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ℤ` (Kennedy, Quade, Raposo, Jonsson)       | [free abelian group][free-abelian]    | AG-unification — decidable, unitary; the basis of [Kennedy's dimension types][kennedy-types] and [F#'s `UnifyMeasures` solver][fsharp-uom]; with polymorphic recursion, AG _semi_-unification is solved for one inequation (Rittri), general case open per Kennedy |
| `ℚ` (Whitney per Raposo 2018; Goubault)     | vector space over `ℚ`                 | Gaussian elimination for solving; Kennedy: inference with dimension-polymorphic recursion "can be reduced to semi-unification over vector spaces. That problem is decidable and admits a straightforward algorithm" (Rittri's result)                              |
| `ℝ` (Whitney per Raposo 2019; Wand–O'Keefe) | vector space over `ℝ` (rational data) | Gaussian elimination (Kennedy on Wand & O'Keefe: "equations are not necessarily integral, so Gaussian elimination is used to solve them"); types can be dimensionally nonsensical, e.g. exponent-swapping                                                          |

The curiosity is that the `ℚ`-exponent theory — Whitney's, on the 2018 restatement —
is in one respect **better-behaved for type inference** than the `ℤ` theory the
programming-language tradition standardized on: over a field, semi-unification is
decidable in general, while over `ℤ` its general case was still open at thesis time
(Kennedy §3.5). The `ℤ` choice won for the physical reason Raposo articulates
(integer exponents are all that physics produces) rather than for a computational
one. Runtime-checked systems, unburdened by unification, largely keep dense
exponents — see [python-pint][python-pint] — while the statically-checked systems
in this tree are `ℤ`-exponent descendants; the [mechanisms page][mechanisms] tracks
the split. Whitney's Part I program itself — numbers as operators, quantities
opaque, units as mere bookkeeping — survives most visibly in the _semantics_ used to
prove such systems sound: Kennedy's dimensional-invariance theorem interprets
`real δ` over models with a positive-reals scaling action and derives "scaling
theorems" from types, reinventing (independently — no citation, as established
above) Whitney's operator picture as relational parametricity.

---

## Open problems & frontier

1. **The exponent ring.** `ℤ` vs `ℚ` vs `ℝ` is still the live fault line: Raposo
   2018/2019 argue `ℤ` suffices and that dense exponents are "oversized"; Whitney's
   Part II (per the restatements) chose `ℚ` or `ℝ`; Jonsson leaves the
   interpretability of `q^0.2`/`q^π` explicitly unresolved. Any mechanization must
   pick a side before it can state the representation theorem.
2. **Unit-centred vs dimension-centred axiomatics.** Raposo's critique — the
   operations' rules "need to be set in the axioms", and addability can depend on
   the unit system — is aimed at the whole Drobot–Whitney–Carlson line; whether
   Whitney's actual postulates (uninspected) are vulnerable to it, or already
   anticipate the fiber-bundle reading, is a _reading_ problem blocked on the
   paywall, and worth settling given how much of the modern literature cites Part II
   through secondaries.
3. **Scalars: embedded or acting?** Jonsson's incompatibility argument (embedded
   scalars + exponentiation-as-scalar-product force positivity) identifies a real
   defect in the Part II design. Kock's short-exact-sequence repair
   (`ℚ_{>0} → P → D`, restated by Jonsson) accepts the positivity restriction;
   Raposo and Jonsson instead make scalars act externally. Which repair preserves
   more of Whitney's "numbers as operators" program is unexamined.
4. **One zero or many?** The lineage's rays "coincide in a point" (one global zero);
   Raposo's bundle has a zero per fiber (`0 ms⁻¹ ≠ 0 kg`) and must then manage zero
   divisors and non-comparable zeros (his 2019 order analysis shows zeros of
   different fibers are _never_ comparable). Neither choice dominates; the
   [torsor page][torsor] shows a third option (no distinguished zero at all).
5. **Kinds beyond dimension.** Nothing in the lineage separates torque from energy;
   Raposo concedes the algebra "cannot distinguish this detail". Whitney's
   several-isomorphic-models device for counting is the germ of a kind system, but
   whether it can coexist with multiplicative closure (and a representation theorem)
   is open — the [mp-units `quantity_spec` design][cpp-mp-units] is the engineering
   answer awaiting a Whitney-style algebraic one.
6. **The habitat of `2 bl + 3 ck`.** Whitney computes distributively with formal
   cross-kind sums but (in the available text) never assigns them a structure.
   [Hart's dimensioned vector spaces][hart] are the natural completion; connecting
   them back to quantity structures — direct sums of birays with a compatible
   product — appears in none of the local artifacts.
7. **Convergence of the descendants.** Jonsson reports his quantity spaces and
   Raposo's fiber bundles "have been shown to be completely equivalent", citing a
   2021 Raposo manuscript — i.e. the two independent modern re-axiomatizations of
   the Whitney lineage agree, essentially on "free-abelian-group of dimensions +
   one-dimensional fibers + per-fiber zeros". Whether that equivalence extends to a
   faithful embedding of Whitney's original (dense-exponent, single-zero) structures
   is not addressed in the manuscript's published surroundings.

---

## Sources

- H. Whitney, ["The Mathematics of Physical Quantities. Part I: Mathematical Models
  for Measurement"][whitney-i], _Amer. Math. Monthly_ 75(2):115–138, 1968 — rays,
  birays, numbers as operators, the isomorphism theorem. (Quoted from the local
  2-page re-typeset excerpt of the introduction,
  `whitney-1968-physical-quantities-i-monthly-excerpt.pdf`; page range beyond the
  DOI's first page [unverified].)
- H. Whitney, ["The Mathematics of Physical Quantities. Part II: Quantity Structures
  and Dimensional Analysis"][whitney-ii], _Amer. Math. Monthly_ 75(3):227–256, 1968
  — quantity structures and the representation theorem. (Not inspected; cited and
  restated by Raposo 2018 ref. [22], Raposo 2019 ref. [5], Jonsson 2021 ref. [31].)
- Á. P. Raposo, ["The Algebraic Structure of Quantity Calculus"][raposo-2018],
  _Measurement Science Review_ 18(4):147–157, 2018 — the unit-centred-lineage
  restatement (`ℝ × ℚⁿ`, unique factorization), its critique, and the
  dimension-centred fiber-bundle replacement with the rank classification theorem.
  (Local: `raposo-2018-algebraic-structure-quantity-calculus-msr.pdf`.)
- Á. P. Raposo, ["The Algebraic Structure of Quantity Calculus II"][raposo-2019],
  _Measurement Science Review_ 19(2):70–78, 2019 — the real-exponent restatement,
  rays glued at one zero, the Π-theorem credit, order structure, and the
  integer-exponent Π theorem. (Local:
  `raposo-2019-algebraic-structure-quantity-calculus-ii-msr.pdf`.)
- D. Jonsson, ["Magnitudes, Scalable Monoids and Quantity Spaces"][jonsson-2021],
  arXiv:2108.02106v6, 2023 — scalable monoids and quantity spaces; Appendix B.1's
  detailed Drobot/Whitney restatement, the primitive-vs-derived comparison table,
  and the equivalence-with-Raposo report. (Local:
  `jonsson-2021-magnitudes-scalable-monoids-quantity-spaces-arxiv.pdf`.)
- A. J. Kennedy, ["Programming Languages and Dimensions"][kennedy-thesis], PhD
  thesis, Univ. of Cambridge, TR-391, 1996 — the `ℤ`-module view of dimensions
  (App. B), the unification/semi-unification landscape (§3.5) used in
  [Mechanization](#mechanization), and the **no-Whitney-citation** negative finding.
  (Local: `kennedy-1996-programming-languages-dimensions-thesis.pdf`.)
- Related deep-dives: [theory index][theory-index] · [units-of-measure
  umbrella][umbrella] · [concepts glossary][concepts] ·
  [Buckingham Π & Drobot][buckingham-pi] · [free abelian group of
  dimensions][free-abelian] · [tensor of lines][tensor-of-lines] ·
  [torsor representation][torsor] · [Kennedy's dimension types][kennedy-types] ·
  [Hart's multidimensional analysis][hart] · [type-system
  mechanisms][mechanisms] · systems: [F# units of measure][fsharp-uom] ·
  [mp-units (C++)][cpp-mp-units] · [Pint (Python)][python-pint] ·
  [Lean / mathlib][lean-units] · [comparison capstone][comparison].

<!-- References -->

<!-- Same-tree theory siblings -->

[theory-index]: ./index.md
[buckingham-pi]: ./buckingham-pi.md
[free-abelian]: ./free-abelian-group.md
[tensor-of-lines]: ./tensor-of-lines.md
[torsor]: ./torsor-representation.md
[kennedy-types]: ./kennedy-types.md
[hart]: ./hart-multidimensional.md
[mechanisms]: ./type-system-mechanisms.md

<!-- Tree umbrella / concepts / comparison -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md

<!-- System pages -->

[fsharp-uom]: ../fsharp-uom.md
[cpp-mp-units]: ../cpp-mp-units.md
[python-pint]: ../python-pint.md
[lean-units]: ../lean-mathlib-units.md

<!-- External primary sources -->

[whitney-i]: https://doi.org/10.2307/2315883
[whitney-ii]: https://doi.org/10.2307/2314953
[raposo-2018]: https://doi.org/10.1515/msr-2017-0021
[raposo-2019]: https://doi.org/10.2478/msr-2019-0012
[jonsson-2021]: https://arxiv.org/abs/2108.02106
[kennedy-thesis]: https://www.cl.cam.ac.uk/techreports/UCAM-CL-TR-391.pdf
