# Units-of-Measure Theory

The mathematical foundations under every checked-units system in this survey — from
the classical quantity calculus ([Buckingham π][pi], [Whitney][whitney]) through the
modern algebraic formalizations ([free abelian groups][fag],
[tensor lines][tensor], [torsors and the scaling torus][torsor],
[Hart's dimensioned linear algebra][hart]) to the type-theoretic line that runs in
production compilers ([Kennedy][kennedy], and the [mechanisms bridge][mech] into the
system pages). This is the theory subtree of the [units-of-measure survey][umbrella];
the [concepts glossary][concepts] sits above it with the metrology vocabulary
(VIM, SI Brochure, UCUM, QUDT), the systems deep-dives ([F#][fsharp], mp-units,
Pint, …) are where these ideas ship, and the [comparison capstone][comparison]
reconciles what the pages below deliberately leave unreconciled. Where a deep-dive
names a real system, it links to that system's page.

**Last reviewed:** July 3, 2026

---

## The one organizing question: what is wrong with `1 m + 1 s` — and what is primitive?

Quantities of different dimensions multiply freely (`1 m × 1 s` is an unremarkable
metre-second) yet refuse to add. Every page in this subtree answers a shared protocol
about that asymmetry — what a quantity _is_, what a unit is, what homogeneity means,
what a change of units does — and the answers are genuinely incompatible, because each
is downstream of a deeper choice: **which object is primitive**, with everything else
constructed from it.

> [!IMPORTANT]
> **The prohibition is a construction, not a theorem.** Nowhere in this corpus is "you
> cannot add apples and oranges" _proved_: Bridgman exhibits a unit-invariant yet
> inhomogeneous equation (`v + s = gt + ½gt²`) and explicitly refutes the intuition as
> a proof ([Buckingham π][pi]), and every formalization that bans the mixed sum does so
> by construction — disjoint carriers, partial operations, typing rules. What each page
> really fixes is _where the ban is installed_, and that placement **is** the
> formalization. The [comparison's seven-readings ledger][comparison-seven] holds the
> answers side by side.

The deep-dives split along the classical, algebraic, and type-theoretic axes:

- **Buckingham π** ([buckingham-pi][pi]) — the classical workhorse: the π-theorem as
  rank–nullity for the dimension matrix over `ℚ`, plus the hypotheses folklore elides
  (completeness, unit-invariance, single relation, positivity).
- **Whitney** ([whitney][whitney]) — the axiomatic high-water mark: quantities
  primitive, number systems constructed afterwards as operators; the `Q ≅ ℝ × ℚⁿ`
  representation theorem.
- **Free abelian group** ([free-abelian-group][fag]) — the skeleton every typed library
  implements: dimensions as exponent vectors in `ℤⁿ` (or `ℚⁿ`), two `GL`-actions, and
  π re-read as lattice linear algebra.
- **Tensor of lines** ([tensor-of-lines][tensor]) — Tao's coordinate-free picture: base
  dimensions as one-dimensional lines, units as basis vectors, inconsistency as
  _unwritability_; Janyška–Modugno–Vitolo's positive spaces as the rigorous companion.
- **Torsor / scaling torus** ([torsor-representation][torsor]) — the action-first
  reading: dimensional analysis as representation theory of `(ℝ⁺)ⁿ`, units as torsor
  points, and a choice of units as a never-canonical trivialization.
- **Kennedy types** ([kennedy-types][kennedy]) — the programming-language
  formalization: units as type-level group elements, principal types by
  AG-unification, meaning as invariance under rescaling (parametricity), erasure.
- **Hart** ([hart-multidimensional][hart]) — the partiality of `+` propagated through
  linear algebra: dimensioned matrices, the outer-product factorization, and how much
  of matrix theory survives (little).
- **Type-system mechanisms** ([type-system-mechanisms][mech]) — the theory→systems
  bridge: six encodings of the group, organized by whether the checker _evaluates_ or
  _solves_, and by what "zero runtime cost" formally means.

The [tensor-of-lines][tensor] and [torsor][torsor] pages develop two halves of one
picture — carriers-first versus action-first — and state their ownership boundary and
the three source-supported bridges between them explicitly.

---

## Catalog

| Deep-dive                            | Primary structure                                               | What it pins down                                                                                                 | Canonical sources                                                           | Link      |
| ------------------------------------ | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | --------- |
| **Buckingham π via linear algebra**  | the dimension matrix `A` + the rescaling group                  | π-theorem = rank–nullity over `ℚ` + one analytic step; the hypotheses ledger; four accounts of the addition ban   | Vaschy 1892; Buckingham 1914; Bridgman 1922; Drobot 1953; CLP 1982          | [pi]      |
| **Whitney's quantity structures**    | one-kind measurement models (rays/birays); numbers as operators | quantities-first axiomatics; unique factorization `Q ≅ ℝ × ℚⁿ`; the unresolved exponent ring (`ℚ` vs `ℝ`)         | Whitney 1968 (Monthly I & II); Raposo 2018/2019; Jonsson 2021               | [whitney] |
| **Free abelian group**               | `Dim ≅ ℤⁿ` (`ℚⁿ` after fractional powers)                       | freeness = unique normal forms; rescaling vs `GL(n, ℤ)` base change; what `ℤ → ℚ` buys and breaks                 | Kennedy 1996; Jonsson 2020/2021; Zapata-Carratalá 2021; the Lean repo       | [fag]     |
| **Tensor of lines**                  | 1-D ordered lines under `⊗`/duals; JMV positive spaces          | units as basis vectors; inconsistency as unwritability; the abstract↔parametric dictionary; the kind ladder       | Tao 2012; Janyška–Modugno–Vitolo 2007                                       | [tensor]  |
| **Torsor / scaling torus**           | the `(ℝ⁺)ⁿ` action; dimensioned rings fibred over `D`           | homogeneity = equivariance; units = torsor points; unit systems = sections; trivialization never canonical        | Baez; Tao 2012; Zapata-Carratalá 2021; Jonsson 2021                         | [torsor]  |
| **Kennedy's types**                  | a typed λ-calculus with the group embedded in the type grammar  | principal types via unitary AG-unification; parametricity = invariance under rescaling; the erasure semantics     | Wand & O'Keefe 1991; Kennedy 1994 / 1996 / 1997 / 2010                      | [kennedy] |
| **Hart's multidimensional analysis** | the `TFF` `F × G`; dimensioned vectors and matrices above it    | multipliable ⇔ dimensionally rank-1 (`A ∼ yx̃`); the matrix class tower; why no library ships dimensioned matrices | Hart 1994 (SIAM) & 1995 (Springer); Zapata-Carratalá 2021                   | [hart]    |
| **Type-system mechanisms**           | the group as checkable type structure — six mechanism families  | evaluate vs solve; the two organizing theorems (AG-unification unitary; erasure + parametricity)                  | Kennedy 2010; Gundry 2015; the pinned F#/Rust/C++/Haskell/Lean source trees | [mech]    |

---

## Three cross-cutting splits

### What is primitive

The deepest disagreement, developed in full in
[comparison § what is primitive][comparison-primitive]: each ordering makes an axiom
of what the others must prove.

| Primitive                            | Pages             | What must then be earned                                                                                      |
| ------------------------------------ | ----------------- | ------------------------------------------------------------------------------------------------------------- |
| **The quantities themselves**        | [whitney]         | the number systems — `ℕ → ℚ⁺ → ℝ⁺ → ℝ` constructed as operators on rays                                       |
| **Measures + a transformation rule** | [pi]              | the quantity/measure distinction (conflated deliberately; re-axiomatized by Drobot/CLP)                       |
| **The carriers (1-D lines)**         | [tensor]          | the rescaling group — derived as basis change; a change of units is abstractly "nothing"                      |
| **The group action**                 | [torsor]          | the carriers — recovered as weight spaces/slices; even same-dimension `+` must be recovered                   |
| **Types and programs**               | [kennedy], [mech] | the scaling group itself — derived from the primitives `0`, `1`, `+`, `−`, `*`, `/`, `<` (POPL '97 Theorem 2) |
| **The trivialized pair `(f, g)`**    | [hart]            | nothing — a unit per dimension is already chosen, non-canonically; invariance via quotients                   |

### The exponent ring: `ℤ`, `ℚ`, or `ℝ`

No two corners agree, and the disagreement is load-bearing: the local restatements of
Whitney's Part II contradict each other (`ℚ` vs `ℝ` — [whitney]); the classical
π-theorem allows `ℝ` but `ℚ` provably suffices and integer kernel bases always exist
([pi]); Kennedy fixed `ℤ` deliberately, and his sqrt-indefinability theorem holds only
there ([kennedy]); the torus picture over-generates (its characters form `ℝⁿ`) and
explains no particular lattice ([torsor]); and the `ℤ → ℚ` extension is a change of
category — freeness over base symbols, the perfect-square predicate, and gcd/lattice
structure are all lost ([fag]). Practice quietly drifted to `ℚ` behind the theory's
back ([comparison § exponents][comparison-exp]); the two CI-verified prototypes make
both ends runnable ([`quantity-zn-graded.d`][ex-z],
[`quantity-rational-exponents.d`][ex-q]).

### Semantic/algebraic vs syntactic/type-theoretic

|                  | **Semantic / algebraic**                                      | **Syntactic / type-theoretic**                                   |
| ---------------- | ------------------------------------------------------------- | ---------------------------------------------------------------- |
| Pages            | [whitney], [pi], [tensor], [torsor], [hart]                   | [kennedy], [mech]                                                |
| The object       | quantities/carriers/actions, axiomatized directly             | programs; the group lives in the type grammar                    |
| Homogeneity is   | well-formedness, or equivariance under the scaling action     | typability — with parametricity proving the two coincide         |
| "Meaningless" is | undefined, unwritable, or hybrid (outside every weight space) | ill-typed — but semantically defined, and merely _not invariant_ |

The two sides meet in the Lean mechanization, where the algebra is a **theorem**
(`CommGroup (dimension B E)`) stated _inside_ a type theory ([fag], [mech]) — and in
Kennedy's parametricity results, which prove the syntactic discipline sound for
exactly the semantic notion of invariance the algebraic side axiomatizes.

---

## Suggested reading paths

- **"Ground up, classical first."** [concepts][concepts] → [buckingham-pi][pi] →
  [whitney][whitney] → [free-abelian-group][fag].
- **"The coordinate-free modern picture."** [tensor-of-lines][tensor] →
  [torsor-representation][torsor] → the [graded-algebra verdict][comparison-graded].
- **"From the group to a type checker."** [free-abelian-group][fag] →
  [kennedy-types][kennedy] → [type-system-mechanisms][mech] → [fsharp-uom][fsharp]
  (the production realization).
- **"The road not taken."** [hart-multidimensional][hart] — then the
  [comparison][comparison] on why no mainstream library implements dimensioned linear
  algebra.
- **"Show me running code."** The three CI-verified D prototypes:
  [`quantity-zn-graded.d`][ex-z] (the `ℤⁿ` normal form),
  [`quantity-rational-exponents.d`][ex-q] (the `ℚⁿ` extension),
  [`quantity-erasure.d`][ex-e] (representation-level erasure, machine-checked).

---

## Sources

Each deep-dive carries its own primary citations and pins the exact local artifact and
edition used (its `Primary sources` and `Sources` sections). The spine here rests on
Buckingham 1914, Bridgman 1922, Drobot 1953, Whitney 1968, Curtis–Logan–Parker 1982,
Wand & O'Keefe 1991, Kennedy 1994–2010, Hart 1994/1995, Janyška–Modugno–Vitolo 2007,
Tao 2012, Atkey 2014, Gundry 2015, Raposo 2018/2019, Jonsson 2020/2021,
Zapata-Carratalá 2021, and Bobbin et al. 2025, together with the pinned production
source trees (the F# constraint solver, `uom`, mp-units, the Lean development) cited on
[type-system-mechanisms][mech].

<!-- References -->

<!-- Tree umbrella / synthesis -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md
[comparison-seven]: ../comparison.md#seven-readings-of-one-prohibition
[comparison-primitive]: ../comparison.md#what-is-primitive-quantities-units-dimensions-or-the-action
[comparison-exp]: ../comparison.md#2-the-exponent-domain-in-practice
[comparison-graded]: ../comparison.md#part-ii-the-graded-algebra-hypothesis-tested

<!-- Theory siblings -->

[pi]: ./buckingham-pi.md
[whitney]: ./whitney.md
[fag]: ./free-abelian-group.md
[tensor]: ./tensor-of-lines.md
[torsor]: ./torsor-representation.md
[kennedy]: ./kennedy-types.md
[hart]: ./hart-multidimensional.md
[mech]: ./type-system-mechanisms.md

<!-- System pages -->

[fsharp]: ../fsharp-uom.md

<!-- Runnable prototypes -->

[ex-z]: ../examples/quantity-zn-graded.d
[ex-q]: ../examples/quantity-rational-exponents.d
[ex-e]: ../examples/quantity-erasure.d
