# Comparison & Synthesis

The capstone of the [units-of-measure survey][umbrella], in four parts: a
**reconciliation of the seven formalizations** in the [theory subtree][theory] across
the survey's shared protocol questions; a **test of a candidate unifying hypothesis**
(quantities as a graded commutative algebra / weight-space decomposition) against the
landed evidence; the **at-a-glance matrix** over the fourteen surveyed systems with the
consensus the field has converged on and the trade-offs that remain genuinely open; and
the **delta for a Sparkles units library** — the open design decisions a future
`docs/specs/` proposal must resolve, with the evidence that frames each. Terminology is
defined in the [concepts glossary][concepts].

> [!NOTE]
> **Scope.** This synthesis draws only on the landed pages of this tree — eight theory
> pages, fourteen system pages, and the three CI-verified D prototypes in
> [`examples/`](#part-iv-where-a-sparkles-units-library-would-fit) — and inherits
> their provenance limits (e.g. Whitney's Part II is known via restatements; Hart's
> book via its TOC; Wolfram/MATLAB via vendor-doc captures). Claims new to this page
> are syntheses of those sources, not fresh research.

**Last reviewed:** July 3, 2026

---

## Part I — The formalizations, reconciled

Every theory page answers the same protocol; here the answers sit side by side. Each
page presents its own framing as the natural one — the purpose of this table and the
prose after it is to expose where the framings genuinely conflict.

| Formalization                    | Primary structure                                                                                 | Quantity                                              | Unit                                                                    | Dimension                                               | Homogeneity                                                                            | Change of units                                                                         | Cross-dimension `+`                                                                                 |
| -------------------------------- | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| [Whitney][whitney]               | One-kind measurement models (rays/birays); numbers arrive later as operators                      | element of a model — the property itself              | any element "kept fixed for a period"; no algebraic privilege           | the biray itself (the set of comparables)               | well-formedness — heterogeneous equations are unformulable                             | a change of _description_; quantities untouched                                         | **inexpressible** — yet Whitney computes `6(2 bl + 3 ck) = 12 bl + 18 ck` distributively            |
| [Buckingham π][pi]               | multiplicative skeleton of measures + the rescaling group; the dimension matrix `A`               | a positive measure-number (CLP: exponent vector)      | `k` of the problem's own quantities; a frame; a local basis             | exponent tuple; Drobot/Jonsson: an equivalence class    | four accounts — assumed, derived-and-**conditional** (Bridgman), two axioms, definable | the group action `S_λ`; invariants = exactly the `Π`s                                   | four accounts; Bridgman's `v + s = gt + ½gt²` shows the ban is a _conditional theorem_              |
| [Free abelian group][fag]        | the dimension group `Dim ≅ ℤⁿ` itself (`ℚⁿ` after fractional powers)                              | a value _indexed by_ a group element                  | deferred (Kennedy), derived (Jonsson), a section `u : D → R` (Zapata)   | a group element — an exponent vector                    | equality in the group; semantically, invariance under every `ψ : Dim → (ℝ⁺, ·)`        | two actions: rescaling homomorphism + `GL(n, ℤ)` base change                            | outside the structure; four precise renderings (typing, signature, `Classical.epsilon`, partiality) |
| [Tensor of lines][tensor]        | 1-D ordered lines closed under `⊗`/duals; weight spaces of a structure group; JMV positive spaces | element of a line; equivariant family; a scale        | a (positive) basis vector — "a semi–basis … is called a unit"           | the line itself; the weight `(a,b,c)`                   | well-typedness (abstract); equivariance (parametric); rationality of maps (JMV)        | a non-event (abstract); the passive group action (parametric)                           | **unwritable** / total-but-**hybrid** with a convex-hull criterion / no subtraction at all (JMV)    |
| [Torsor / scaling torus][torsor] | the group action `(ℝ⁺)ⁿ`; a dimensioned ring `R_D` fibred over `D`                                | a weight-`d` family; a slice element `a_d`            | a **torsor point**; a whole system = a section `u : D → R`              | a character/weight of the torus; a slice `R_d`          | equivariance; verifiable at a single unit choice (transfer)                            | a torus element acting passively; a change of section/trivialization                    | partial by definition, with distributivity _forcing_ `·` to grade (Zapata); hybrid (Tao)            |
| [Kennedy types][kennedy]         | a typed λ-calculus with the AG embedded in the type grammar                                       | `r : num µ` — a bare rational at run time             | a unit _variable_ (base units = free occurrences)                       | a class of units ≅ isomorphic data representations      | typability; provably equal to scaling invariance (parametricity)                       | a scaling environment `ψ : G → ℚ⁺` — **derived** from the primitives, not assumed       | ill-typed statically; **defined but not invariant** semantically; `0` the unique polymorphic value  |
| [Hart][hart]                     | the `TFF` `F × G`: total `·`, type-guarded partial `+`; dimensioned vectors/matrices above        | an ordered pair `(f, g)`                              | **not a formal object** (recorded silence)                              | the group element `g` — any group, not necessarily `ℤⁿ` | class membership: multipliable/similar/squarable/endomorphic                           | absent from the paper; invariance carried by the `∼`/`≈` quotients                      | undefined by definition `(4)`; aggregation by **tupling**; one zero _per type_                      |
| [Type-system mechanisms][mech]   | the group as _checkable type structure_ — six encodings from phantom tags to dependent types      | a value of an indexed type; at run time a bare scalar | a type-level index (measure AST, `typenum` vector, symbolic expression) | the index, modulo whatever equality the host can decide | typability of `+` at equal index; the erased program means its unit-stripped self      | relational — Kennedy's scaling semantics; erasure _is_ choosing a global trivialization | unification failure / missing `impl` / unprovable constraint / `Classical.epsilon`-unknowable       |

### What is primitive — quantities, units, dimensions, or the action?

The deepest disagreement is about which object the others are made of, and
[Raposo's unit-centred vs dimension-centred axis][whitney] only names half of it:

- **Quantities first** ([Whitney][whitney]): the physical properties themselves are the
  elements; even the number systems are constructed afterwards as operators on them.
  Units are "pure bookkeeping"; dimensions are just the models.
- **Carriers first** ([tensor of lines][tensor]): the one-dimensional lines (or JMV's
  zero-free positive spaces) are posited, with `⊗` and duals; the rescaling group is
  _derived_ as basis change, and a change of units is, abstractly, "nothing at all".
- **Action first** ([torsor / scaling torus][torsor]): the group and its action are the
  signature; the carriers are recovered as weight spaces, slices, or orbitoids —
  Zapata-Carratalá goes furthest and derives even the action from the fibration plus
  distributivity.
- **Measures first** ([Buckingham π][pi]): Buckingham and Bridgman deliberately conflate
  a quantity with its numerical measure; the entire structure is the transformation rule
  of numbers under unit change. Drobot, CLP, and Jonsson then re-axiomatize exactly to
  undo that conflation.
- **Types first** ([Kennedy][kennedy]): quantities have _no algebraic structure at all_
  in the model (`num µ` denotes bare `ℚ⊥` for every `µ`); all dimensional structure
  lives in types and relations between runs.
- **The trivialized pair** ([Hart][hart]): `(f, g)` — a number and a group element. As
  the Hart page itself notes, writing a quantity as a bare pair has _already_ chosen a
  unit per dimension: Hart's `TFF` is the carriers-first picture **after**
  trivialization, which is precisely the non-canonical isomorphism the
  [torsor page][torsor]'s central theorem (`R_D ≅ R₁ × D`, never canonically) warns
  about.

These are not styles: they order the definitions differently, and each ordering makes
something the others must prove into an axiom (Whitney must _construct_ ℝ; the torsor
picture must _recover_ same-dimension addition; Kennedy must _prove_ the scaling group
exists rather than posit it — his POPL '97 Theorem 2 derives it from `0`, `<`, `*`,
`/`).

### One zero, many zeros, or none

A genuine three-way conflict that the pages document without resolving:

- **One global zero.** In the `ℝ × ℚⁿ` reading of Whitney's lineage "the rays coincide
  in a point, the zero of the algebraic structure" ([Whitney][whitney], per Raposo
  2019); Kennedy keeps a single **polymorphic** `0 : real d` for every `d` — semantically
  justified as the unique fixed point of every scaling ([Kennedy][kennedy]).
- **One zero per fiber.** Raposo's bundle ("`0 ms−1` is a different quantity than
  `0 kg`"), Jonsson's `0_C` per dimension class, and Hart's per-type zeros `(0, g)` —
  which is why Hart's identity and zero _matrices_ fracture into families
  ([Hart][hart]).
- **No zero at all.** JMV's positive spaces are zero-free by construction — the price is
  that even same-dimension _subtraction_ is undefined ([tensor of lines][tensor]) — and
  no torsor can contain a zero, since the scaling action fixes it and freeness would
  fail ([torsor][torsor]).

The system pages inherit the fork: F# makes `0` (and `±∞`, `NaN`) the only
unit-polymorphic constants ([fsharp-uom][fsharp]), while every affine-aware library
(`delta_degC` in [Pint][pint], `QuantityPoint` origins in [Au][au]) is quietly on the
zero-per-fiber side.

### The exponent ring: `ℤ`, `ℚ`, or `ℝ`

No two corners of the survey agree, and the disagreement is load-bearing:

- The three local restatements of Whitney's Part II **disagree with each other** — `ℚ`
  (Raposo 2018), `ℝ` (Raposo 2019), "`Q` or `R`" (Jonsson) — unresolvable while Part II
  stays uninspected ([Whitney][whitney]).
- The classical π-theorem treatments allow `ℝ`, but `ℚ` provably suffices whenever the
  dimension matrix is rational, and after clearing denominators `ℤ` bases always exist
  for `ker A` ([Buckingham π][pi]) — which is why integer-exponent type systems can
  state the theorem at all.
- Kennedy fixed `ℤ` **deliberately** (fractional dimensions "should prompt revision of
  the set of base dimensions") and his sqrt-indefinability theorem _depends_ on it; over
  `ℚ` the perfect-square predicate is inexpressible and the theorem has no analogue
  ([free abelian group][fag]).
- The torus picture is indifferent — its character group is all of `ℝⁿ`, so it "explains
  none of them"; Zapata-Carratalá names the gap as an open problem (§8: no justification
  found for singling out `ℤ` or `ℚ`) ([torsor][torsor]).
- Jonsson's verdict on the dense-exponent lineage is sharper than taste: embedding
  scalars _and_ treating exponentiation as a scalar product "are not fully compatible" —
  repairing it forces **all quantities positive**, and `q^0.2` or `q^π` remains
  uninterpretable regardless ([Whitney § fractional exponents][whitney]).

Practice, meanwhile, drifted to `ℚ` behind the theory's back — see
[Part III § exponents](#2-the-exponent-domain-in-practice).

### Multiplication: basic or derived?

The standard puzzle — multiply freely across dimensions, add only within one — gets
_opposite_ resolutions at the two ends of the survey:

- **Whitney inverts it at the base**: Part I dismisses multiplication as having "no
  natural physical counterpart" for a single kind; addition-within-a-kind is the deep
  operation, and cross-kind product is Part II superstructure ([Whitney][whitney]).
- **Zapata-Carratalá derives the product's totality**: given slice-wise partial
  addition, demanding distributivity _forces_ multiplication to act transitively on
  dimensions — "the dimension of `a_d · c_f` only depends on `d` and `f`" — so the very
  existence of a dimension monoid is explained by the partiality of `+`
  ([torsor][torsor]).
- **Kennedy derives the asymmetry from equivariance**: scale factors themselves
  multiply (`h(µ₁·µ₂) = h(µ₁)·h(µ₂)`), so `*` is equivariant for _arbitrary_ pairs
  while `+` is equivariant only on the diagonal ([Kennedy][kennedy]).
- **Jonsson derives addition itself**: same-dimension `+` is not primitive but a
  consequence of multiplicative covariance plus symmetry (`Φ(a,b) = Φ(b,a)` forces
  `Φ(a,b) = k(a+b)`) — "multiplication is the structure the covariance group preserves;
  addition is what covariance leaves room for inside a single fiber"
  ([Buckingham π][pi]).
- **Hart postulates both** and derives nothing about the asymmetry — his contribution is
  propagating it, unrepaired, through all of linear algebra ([Hart][hart]).

### Seven readings of one prohibition

The survey's central question — what, exactly, is wrong with `1 m + 1 s` — receives
genuinely incompatible answers, not paraphrases of one answer:

| Reading                             | Who                                         | The load-bearing detail                                                                                                    |
| ----------------------------------- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| **Inexpressible** (no denotation)   | [Whitney][whitney], Tao abstract, CLP       | disjoint carriers, no spanning operation; CLP cannot even _write_ quantity addition (its vector `+` **is** multiplication) |
| **Conditional theorem**             | Bridgman ([Buckingham π][pi])               | `v + s = gt + ½gt²` is unit-invariant yet inhomogeneous — legal because the variables satisfy _other_ relations            |
| **Undefined by partiality**         | Drobot, [Hart][hart], Zapata-Carratalá      | the operation's domain excludes it; no error value, no completion; per-fiber zeros                                         |
| **Untypable but semantically fine** | [Kennedy][kennedy]                          | the erased sum computes; what fails is equivariance — the value depends on the arbitrary unit choice                       |
| **Total but hybrid**                | Tao parametric ([tensor of lines][tensor])  | the sum exists, lies in no weight space; hybrid _inequalities_ retain content exactly when exponent convex hulls nest      |
| **Never defined, because derived**  | Jonsson ([torsor][torsor])                  | addition is constructed from a unit element inside one orbitoid; across orbitoids the construction has no input data       |
| **Total but unknowable**            | the Lean mechanization ([mechanisms][mech]) | `Classical.epsilon`: `length + time` type-checks and denotes _some_ dimension, about which no theorem is provable          |

Two consequences worth stating plainly. First, "you cannot add apples and oranges" is
**not** a theorem anywhere in the corpus — Bridgman explicitly refutes it as a proof,
and the formalizations that ban the sum do so by _construction_, not derivation. Second,
Whitney's balloons-and-cookies computation and Hart's dimensioned vectors are, up to
notation, the **same object**: a point of the finite product of fibers
`F_g₁ × ⋯ × F_gₙ` is an element of the direct sum of those fibers, whether written
horizontally (`(2 bl, 3 ck)`, Hart's tuple) or additively (`2 bl + 3 ck`, Whitney's
formal sum). What Hart declines — and no formalization except Tao's parametric model
accepts — is letting scalar `+` _produce_ such an element. (The
[free-abelian-group page][fag] attributes "formal sums of fibers" to Hart and the
[Hart page][hart] insists he only tuples; on this reading both are right, and the
residual difference is which _sort_ the aggregate lives in.)

### Kinds: the shared blind spot

Every formalization whose dimension is a group element **identifies torque with
energy** and `Hz` with `Bq` — and the pages document that this is known, not
overlooked: Kennedy's thesis names the torque/energy problem and provides no mechanism
([Kennedy][kennedy]); Raposo concedes "the algebraic structure cannot distinguish this
detail" ([Whitney][whitney]); Jonsson makes the collapse a definition ("quantities are
of the same kind if and only if they are commensurable", [torsor][torsor]). The **only
productive mechanism** in the theory corpus is Tao's: enlarge the structure group and
one dimension splits into kinds by transformation law — vectors vs covectors under
`GL₃(ℝ)`, position vs displacement under `E(2)`, polar vs axial under `O(3)`
([tensor of lines][tensor]). But scalar same-dimension pairs (`Hz` vs `Bq`) stay
conflated at _every_ group in the ladder, so even the richest theoretical kind story
does not reach the cases the system pages care about. The engineering answers —
[`uom`'s flat `Kind` tags][rust-uom], [mp-units' `quantity_spec` hierarchy][mp-units],
[Boost.Units' and Au's extra base dimensions][boost] — all add structure the group
lacks, in mutually incompatible ways ([mechanisms][mech]).

---

## Part II — The graded-algebra hypothesis, tested

The candidate unifying hypothesis put to this synthesis:

> The field's unifying object is a commutative algebra graded by the free abelian group
> of dimensions (`≅ ℤⁿ` over base dimensions, or `ℚⁿ` if fractional powers are
> allowed), whose homogeneous components are 1-dimensional real lines; equivalently,
> the weight-space decomposition of quantities under a scaling torus `(ℝ₊)ⁿ`, with
> units as a torsor structure over each line.

### What the landed evidence supports

The hypothesis names real, repeatedly-rediscovered structure, and its two clauses are
provably the same picture:

- **The grading group is everywhere.** Kennedy's freeness fact, Jonsson's `Q/∼` (free
  abelian of finite rank, with rank the complete invariant), the π-theorem's kernel
  lattice, and every system's exponent vector are the same `ℤⁿ` ([free abelian
  group][fag]). Gundry's plugin even makes freeness a _soundness precondition_: his
  torsion-freeness rule "amounts to restricting models … to being free abelian groups"
  ([uom-plugin][uom-plugin]).
- **The weight-space reading is verbatim in the corpus.** Tao: the quantities of
  dimension `MᵃLᵇTᶜ` form "a weight space of the structure group `(ℝ⁺)³ … of weight
(a,b,c)`", and dimensional analysis is "the representation theory of groups such as
  `(ℝ⁺)³`" ([torsor][torsor]). The abstract↔parametric dictionary theorem
  ([tensor of lines][tensor]) is precisely the equivalence the hypothesis asserts
  between its graded and weight-space clauses.
- **Units-as-torsor is verbatim too.** JMV Note 2.3: the scalar multiplication "turns
  out to be a free and transitive action of the group `(ℝ⁺, ·)`" on each positive
  space; Zapata-Carratalá's Prop 3.4/Thm 4.1 make "a choice of units is a
  trivialization `R_D ≅ R₁ × D`, never canonically" a theorem ([torsor][torsor]).
- **The type-system lineage checks this object's shadow.** Kennedy's `num` is literally
  a monoid-graded family (`* : num u₁ → num u₂ → num (u₁·u₂)`, `1 : num 1`), erasure is
  choosing a global trivialization, and parametricity recovers the graded/torsor
  content relationally — with the scaling group _derived_ (Theorem 2)
  ([mechanisms][mech], [Kennedy][kennedy]).
- **Hart extends rather than breaks it.** His `x`-spaces are finite products of fibers —
  direct sums of homogeneous lines, i.e. objects of the graded-module world over the
  hypothesis's algebra — and dimensioned matrices are the degree-shifting morphisms
  between them ([Hart][hart]).

### Where it strains

Confronting the hypothesis with the stress cases the pages document:

1. **The graded _algebra_ contains elements almost nobody wants.** A graded algebra's
   total space includes non-homogeneous sums, and the formalizations
   overwhelmingly exclude them: Whitney's carriers are disjoint; Hart's `+` is partial
   with tupling as the only aggregate; Zapata-Carratalá's dimensioned ring has
   _partial_ addition — and whether a dimensioned algebra even coincides with a
   `ℤ`-graded algebra is one of his open questions (their tensor products differ;
   [torsor § open problems][torsor]). Only Tao's parametric model works in the total
   space — and its distinctive theorem (the convex-hull criterion) exists to show the
   non-homogeneous part carries almost no law-like content ([tensor of lines][tensor]).
   The field's working object is the **homogeneous fragment**, not the algebra.
2. **"1-dimensional real lines" is contested at both words.** JMV's carriers are
   zero-free positive cones over `ℝ⁺` — no zero, no subtraction — not lines; Whitney's
   Part I carriers are rays; and Jonsson's incompatibility result shows the
   dense-exponent lineage is _forced_ toward all-positive carriers ([Whitney][whitney],
   [tensor of lines][tensor]). Whether the primitive is a signed line or a positive
   cone changes what `sqrt` and negation even mean, and Tao's 2025 convex-cone remark
   shows the two are interconvertible but not identical packaging.
3. **The grading group's ring is exactly what the field has not settled.** The
   hypothesis's parenthetical — "`ℤⁿ`, or `ℚⁿ` if fractional powers are allowed" —
   quietly contains [Part I's unresolved axis](#the-exponent-ring-ℤ-ℚ-or-ℝ). Worse for
   the weight-space clause: the torus's characters form `ℝⁿ`, so the representation
   theory **over-generates** and cannot explain why physical dimension groups are
   free abelian of small finite rank — a metrological input, not an output
   ([torsor][torsor]).
4. **Kennedy's model has no lines in it.** The lineage that industrialized the
   hypothesis's checking discipline interprets every fiber as the _same_ untyped
   `ℚ⊥` — the fibers exist only relationally, as invariance classes under the scaling
   action (and Kennedy's torus is over `ℚ⁺`, not `ℝ₊`). The hypothesis is right about
   what is _checked_, but nothing in the shipped semantics is a graded algebra
   ([Kennedy][kennedy]).
5. **Affine quantities need a second, different torsor.** The hypothesis's "units as a
   torsor structure over each line" is the multiplicative `ℝ⁺`-torsor of _unit
   choices_. Temperature points, dates, and voltages are torsors under the fiber's
   **additive** group — a distinct structure the graded object does not supply, which
   is why every system that handles `°C` correctly bolts on a point/difference pair
   ([torsor][torsor], and the affine row of [Part III](#at-a-glance-matrix)). Baez's
   pre-absolute-zero temperature — translations _and_ dilations at once — needs "a more
   sophisticated concept than that of 'torsor'", with no candidate named anywhere in
   the corpus.
6. **Logarithmic and kind structure resist entirely.** dB/pH are a fourfold silence
   across the theory sources (the log-converts-multiplicative-to-additive-torsor
   observation on the [torsor page][torsor] is explicitly `[exposition]`, uncited);
   kinds are [Part I's shared blind spot](#kinds-the-shared-blind-spot). Both are real:
   [Pint][pint] and [Unitful][unitful] ship log units; `mp-units`, `uom`, Boost, Au,
   and Wolfram all ship kind machinery of some sort. None of it is derivable from the
   graded object.

### Verdict, row by row

| Formalization / mechanism family                                         | Fits the graded reading?                                                                         | Where it strains                                                                                               | What resists                                                                                          |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| [Whitney][whitney]                                                       | Yes — `Q ≅ ℝ × ℚⁿ` is the trivialized graded object                                              | one _global_ zero (rays "coincide in a point"); exponent ring unresolved (`ℚ` vs `ℝ`); positivity incoherence  | kinds by model-choice, not by grading; the balloons/cookies formal sum has no declared home           |
| [Buckingham π][pi]                                                       | Yes — the theorem _is_ lattice linear algebra on the grading group (`ker A`, rank–nullity)       | quantities are pre-trivialized positive numbers; no lines anywhere                                             | Bridgman's conditional homogeneity: law-level content the graded reading cannot see                   |
| [Free abelian group][fag]                                                | It **is** the grading group, by definition                                                       | `ℤⁿ` vs `ℚⁿ` is a change of category (freeness, perfect squares, gcd structure all lost over `ℚ`)              | kind unrepresentable — the group element is a dimension's whole identity                              |
| [Tensor of lines][tensor]                                                | Yes, nearly verbatim — lines, `⊗`, weights, and the dictionary theorem                           | JMV carriers are zero-free cones, not lines; irrational exponents open; is keeping the lines worth it vs `ℤⁿ`? | hybrids live outside; `Hz` vs `Bq` conflated at _every_ structure group                               |
| [Torsor / scaling torus][torsor]                                         | Yes — the hypothesis's second clause is this page                                                | characters form `ℝⁿ`: the torus explains no particular lattice; trivialization always non-canonical            | affine layer needs _additive_ torsors; logarithmic units a fourfold silence                           |
| [Kennedy types][kennedy]                                                 | As the checked shadow: `num` is a graded family, the scaling group is derived                    | model has no lines — every fiber denotes bare `ℚ⊥`; torus over `ℚ⁺`, not `ℝ₊`                                  | value-dependent exponents, affine, log, kind — all outside by declaration                             |
| [Hart][hart]                                                             | Yes, if extended to graded _modules_: `x`-spaces = direct sums of fibers, matrices = graded maps | `TFF` is post-trivialization; `G` need not be free abelian (or abelian)                                        | the matrix classes are indexed by `(x, y)` mod scaling — `n + m − 1` parameters no grading names      |
| Native AG unifier ([F#][fsharp])                                         | Checks equality in the grading group; erasure = global trivialization                            | shipped group is `ℚⁿ` (`RationalPower`), against the published `ℤⁿ` theory                                     | `Hz + Bq` type-checks — the stdlib itself exhibits the kind collapse                                  |
| Plugin AG unifier ([uom-plugin][uom-plugin])                             | Same object; torsion-freeness rule names free abelian groups as _the_ intended models            | evidence by assertion; weakened principality; plugin died of compiler coupling                                 | `√Hz`, affine, dB all explicitly future work                                                          |
| Type-level integer vectors ([uom][rust-uom], C++)                        | The grading group in fixed (or symbolic) coordinates; checker evaluates the group operation      | no solver: ground grades only; bounds substitute for unification                                               | kind tags/trees are extra-graded structure bolted on nominally                                        |
| Closed type families ([dimensional][dimensional])                        | The group as syntactic normal forms                                                              | AC axioms are not a terminating rewrite system — stuck on variables                                            | normal-form debris in errors; no backwards inference                                                  |
| Dependent types ([Lean][lean])                                           | The only mechanization where the group is a **theorem** (`CommGroup (dimension B E)`)            | `B → E` is the full function group `Eᴮ` — free abelian only for finite `B`; grades are not 1-D lines           | `+` on dimensions via `Classical.epsilon`: total, unknowable — deliberately not the graded answer     |
| Term-level dictionaries ([Pint][pint], [Julia][unitful], [CAS][wolfram]) | The grading group as run-time data (dicts, `Rational` tuples, symbolic exponents)                | fibers never materialize; checking only on executed paths (or on request)                                      | precisely the systems that ship what the graded object lacks: affine deltas, log units, curated kinds |

### The verdict, plainly

**Confirmed as the common core; rejected as sufficient.** Every formalization in the
tree either implements the hypothesis's object, proves theorems about it, or is
definable as a reaction to it (Whitney _constructs_ it; the π tradition computes in its
kernel lattice; Kennedy checks its shadow and erases it; Hart propagates its partiality
through linear algebra; the torsor and tensor pages are its two halves developed
separately) — and the two clauses of the hypothesis are genuinely equivalent, by Tao's
dictionary theorem. That is more unification than any single source states.

Three amendments are forced by the evidence, and they matter for anyone building on
the hypothesis:

1. **Replace "algebra" with "homogeneous fragment".** The formal sums a graded algebra
   contains are exactly what the field refuses (or, in Tao's model, tolerates and then
   proves nearly lawless). The unifying object is the family of homogeneous components
   with a total graded product and fiber-wise addition — Zapata-Carratalá's dimensioned
   ring, not the `ℤ`-graded algebra it resembles; whether the two theories coincide is
   an _open question in the corpus_, not a safe assumption.
2. **The parenthetical is the battlefield.** "`ℤⁿ`, or `ℚⁿ` if fractional powers are
   allowed" — plus signed-line vs positive-cone carriers — is precisely what the
   sources disagree about, the weight-space reading cannot arbitrate (its characters
   form `ℝⁿ`), and the systems split over in practice.
3. **Two needed structures are not in it.** The affine layer (additive torsors per
   fiber, with origins) and the kind layer (any refinement distinguishing `Hz` from
   `Bq`) are demonstrably required by mature systems and demonstrably not derivable
   from the graded object. A "unifying object" for the _field_ — as opposed to for
   classical dimensional analysis — must carry both as additional structure.

---

## Part III — The systems

### At-a-glance matrix

| System                               | Checked      | Mechanism                                 | Exponents    | Affine           | Log     | Kind           | Poly. `sqr` / inference | Erasure evidence            | Mismatch diagnostics          |
| ------------------------------------ | ------------ | ----------------------------------------- | ------------ | ---------------- | ------- | -------------- | ----------------------- | --------------------------- | ----------------------------- |
| [F# UoM][fsharp]                     | compile      | **native AG unifier**                     | `ℚ`¹         | —                | —       | —²             | ✅ inferred, principal  | ✅ total erasure³           | ✅ one-line, unit-level       |
| [uom-plugin][uom-plugin] (Haskell)   | compile      | **plugin AG unifier**                     | `ℤ`          | —                | —       | —              | ✅ inferred⁴            | ✅ `newtype` (unmeasured)   | ✅ unit-level (via plugin)    |
| [dimensional][dimensional] (Haskell) | compile      | closed type families                      | `ℤ⁷` closed  | ~ offset fns     | —⁵      | —              | ~ stuck on variables    | ✅ `newtype`/`coerce`⁶      | ~ type-level leaks            |
| [uom][rust-uom] (Rust)               | compile      | `typenum` trait arithmetic                | `ℤ⁷`         | ~ temp-only⁷     | —       | ✅ flat tags⁸  | ~ 7-fold bounds         | ✅ verified (`transparent`) | ✗ `typenum` spines            |
| [dimensioned][dimensioned] (Rust)    | compile      | `typenum` `tarr!` arrays                  | `ℤⁿ`⁹        | —                | —       | —              | ~ system-polymorphic    | ✅ verified¹⁰               | ✗✗ positional spines          |
| [mp-units][mp-units] (C++)           | compile      | `consteval` symbolic expressions          | `ℚ` open     | ✅ general       | —¹¹     | ✅✅ hierarchy | ~ generic, no inference | ✅ verified                 | ✅✅ engineered, domain-level |
| [Boost.Units][boost] (C++)           | compile      | MPL typelists                             | `ℚ` open     | ✅ `absolute<T>` | —       | ~ base dims¹²  | ~ `typeof` helpers      | ✅ verified + codegen diff  | ✗✗✗ 37-line/9.8 KB            |
| [Au][au] (C++)                       | compile      | variadic packs + magnitude vector space   | `ℚ` open     | ✅ general       | —¹³     | —¹⁴            | ~ generic               | ✅ verified                 | ✅ `static_assert` prose      |
| [D: quantities / std.units][dq]      | compile¹⁵    | CTFE dimension values / unit-type graph   | `ℚ` (all 3)  | ~ split¹⁶        | —       | ~ by fiat¹⁷    | ~ CTFE, no inference    | ✅ in-source asserts        | ~ readable first line         |
| [Pint][pint] (Python)                | run          | registry + exponent dictionaries          | `ℚ` open     | ✅✅ `delta_`    | ✅ Beta | —              | n/a (dynamic)           | ✗ 38×–250× overhead         | ✅ most readable (runtime)    |
| [Unitful.jl][unitful] (Julia)        | dispatch¹⁸   | `Rational{Int}` values in type parameters | `ℚ` open     | ✅ any dim       | ✅ exp. | —              | ~ free, uncheckable     | ✅ `isbits` + LLVM check    | ✅ most readable              |
| [GNAT Ada][gnat]                     | compile      | compiler aspects, `ℚ` vectors on AST      | `ℚ⁷` (cap 7) | —¹⁹              | —       | —              | ✗ inexpressible         | ✅ byte-identical asm       | ✅ compiler-grade             |
| [Lean][lean]                         | elaboration  | dependent types, proved `CommGroup`       | open ring²⁰  | —                | —       | —              | ✅ as theorems          | n/a (`noncomputable`)       | ~ generic type mismatch       |
| [Wolfram / MATLAB][wolfram]          | run / opt-in | symbolic expressions over curated corpus  | `ℤ` observed | ✅ curated²¹     | —²²     | ~ temp only    | n/a                     | ✗ symbolic cost             | ~ `$Failed` / quiet logicals  |

<sub>¹ Surface syntax defaults to integers; parenthesized `kg^(1/2)` accepted and the
solver is rational throughout — diverging from both the spec grammar and Kennedy's
published `ℤ` design. ² `5.0<Hz> + 3.0<Bq>` type-checks; the stdlib's own `SI.fs`
defines both as `second^-1`. ³ `typeof<float<m>>` = `typeof<float>`; holes: `box` +
downcast crosses measures with only a warning, and measures are invisible to
C#/reflection/serialization. ⁴ Principality formally weakened (fresh-variable unifiers
fail OutsideIn(X)'s guess-free condition); GHC 9.0–9.4 only, dormant since 2022.
⁵ "Purposefully (but not permanently) omitted" — the library's own comment. ⁶ Quantities
erase; `Unit` values are deliberately runtime records. ⁷ Hand-built: `TemperatureKind`
omits add/sub markers; `degree_celsius` uses the only additive conversion slot.
⁸ Kinds reset to the default under `×`/`÷` — comparability tags, not group elements.
⁹ Per system; Gaussian half-integer dimensions handled by `SqrtCentimeter` base units.
¹⁰ `size_of` verified but no `#[repr(transparent)]` — layout unpromised. ¹¹ In-source
`TODO` at `si/units.h` L119: "how to support those? // neper // bel // decibel".
¹² Nine-base-dim SI (radian, steradian) makes torque ≠ energy, but `Bq` = `Hz` stays.
¹³ Rated "poor" by Au's own comparison matrix. ¹⁴ "No plans at present to support" —
explicit policy; `Hz`/`Bq` are quantity-equivalent. ¹⁵ Plus a run-time twin: `QVariant`
throws `DimensionException` (GC + exceptions). ¹⁶ `std.units` has a real `AffineUnit`;
`quantities` hard-codes `enum celsius = kelvin`. ¹⁷ Units-as-types could mint kind
distinctions by fiat; the shipped SI layer never does (`Hz` = `Bq` anyway).
¹⁸ Dispatch-time: the check is resolved per JIT specialization — mismatch compiles to an
unconditional `throw`, match to bare arithmetic; a third category between compile and
run. ¹⁹ `Celsius_Temperature` is the Kelvin vector with a `°C` symbol; K-to-°C
assignment type-checks. ²⁰ Any `CommRing E` — `ℝ` exponents type-check; nothing enforces
the physics convention. ²¹ Wolfram: point/difference temperature units curated;
MATLAB: all temperatures default to _differences_, with a documented
`0*u.Celsius` → dimensionless-`0` trap. ²² MATLAB documents the exclusion ("arithmetic
operations are not possible for these units"); Wolfram captures are silent.</sub>

Reading across: the matrix splits into a **static majority** (nine systems where
mismatches are compile/elaboration errors), a **dynamic pole** (Pint, the CAS pair)
where expressiveness is highest and cost is inverted, and Julia's **specialization-time**
middle. Within the static majority the deepest split is not language but
_solver access_: only the two AG-unifier systems infer; everything else evaluates.
And the affine/log/kind columns are nearly the inverse of the "Checked" column — the
systems with the strongest static guarantees historically shipped the least of the
structure the graded object lacks, though mp-units and Au show that is contingent, not
necessary.

### 1. Mechanism: evaluators vs solvers

This synthesis standardizes the terminology the [mechanisms bridge][mech] and the
system pages already use: a checker **evaluates** when it computes the group operation
on _known_ exponents and compares normal forms (typelists, `typenum`, `consteval`
expressions, CTFE values, dictionaries); it **solves** when it unifies _unknowns_
modulo the AG axioms. Only [F#][fsharp] (native) and [uom-plugin][uom-plugin] (plugin)
solve — and both rest on the same enabling theorem (AG with nullary constants is
unitary; unification decidable). Everything solving buys — principal types, inferred
`sqr : float<'u> → float<'u ^ 2>`, backwards inference for `sqrt` — is unavailable to
evaluators _in principle_, not by implementation laziness: vanilla GHC cannot even
express the rewrite system (AC axioms terminate no rewriting), and Rust/C++ have no
solver socket at all. The engineering coda: solver access is also a **liability** —
`uom-plugin` died of GHC-internals coupling twice over ([uom-plugin][uom-plugin]),
while the evaluator systems ride ordinary language stability. Inference is rare
because it is expensive to _keep_, not just to build.

### 2. The exponent domain in practice

Theory published `ℤ`; practice shipped `ℚ`:

- Kennedy's thesis argues for `ℤ` and proves theorems that only hold there — yet the F#
  compiler carries `Measure.RationalPower` and unifies over `ℚ` in one elimination step
  per variable ([fsharp-uom][fsharp]).
- [Boost.Units][boost] had `static_rational` exponents in **2003–2007**; [mp-units][mp-units]
  and [Au][au] kept `ℚ`; all three D artifacts are `ℚ` ([d-quantities][dq]); GNAT's
  aspect grammar is rational ([gnat][gnat]); Pint and Unitful are `ℚ` at the term level.
- The `ℤ` camp — [uom][rust-uom], [dimensioned][dimensioned], [dimensional][dimensional],
  [uom-plugin][uom-plugin] — is exactly the camp whose _encoding_ (type-level integers,
  unary families) makes rationals expensive, and it pays visibly: `Length.sqrt()` is a
  compile error in uom; `√Hz` is uom-plugin's own named future work; `dimensioned`
  rescales the whole Gaussian basis to `SqrtCentimeter` to stay integral.

The [free-abelian-group page][fag] is the caution against reading this as "ℚ won": the
extension is a change of category — freeness over base symbols, the perfect-square
predicate, and gcd/lattice structure are all lost, and the type language over-generates
(dimension-swapping types become well-formed). The
[`quantity-rational-exponents.d`][ex-q] prototype demonstrates the practical middle
path: normalized rational exponents whose normal forms land back on the integer lattice
whenever the physics does.

### 3. Affine and logarithmic quantities

The affine row of the matrix is the survey's clearest case of **independent convergence
on the theory's answer**: every system that handles temperature correctly implements
the same point/difference (torsor) split the [torsor page][torsor] derives — Pint's
auto-generated `delta_` units, Unitful's `@affineunit` + `AffineError`, mp-units'
`quantity_point` with typed origins, Au's `QuantityPoint` with exact integer origins,
Wolfram's curated `DegreesCelsiusDifference`, `std.units`' `AffineUnit` in 2011, even
`std::chrono`'s `time_point`/`duration` pair ([boost-units § chrono][boost]). The
systems that skip the split exhibit the same two failure modes: a fake linear unit
whose zero is meaningless (F#, GNAT's `°C` costume, `quantities`' `enum celsius =
kelvin`) or a documented trap (MATLAB's `0*u.Celsius`). Logarithmic units, by
contrast, have **no theory anywhere in the tree** and almost no practice: Pint (Beta)
and Unitful (experimental) are the only implementations; mp-units and dimensioned
carry in-source admissions of the gap; Kennedy, Gundry, and all four torsor-page
sources are silent or explicitly defer.

### 4. Kinds

A four-rung ladder, from the matrix:

1. **Nothing** — dimension is the whole identity; `Hz + Bq` compiles/passes in F#,
   GNAT, dimensional, dimensioned, Pint, Unitful, Lean, `std.units`-as-shipped.
2. **Extra base dimensions** — Boost.Units (radian/steradian: torque ≠ energy), Au
   (Angle, Information), Wolfram (angle/solid-angle/money/person axes). Buys some kind
   distinctions with zero new mechanism; cannot split anything sharing a genuine
   dimension (`Bq` = `Hz` survives in all three).
3. **Flat tags** — `uom`'s `Kind` associated type: torque/energy, `Hz`/`Bq`,
   angle/ratio, temperature point/interval all separated — but kinds **erase under
   multiplication** (the product resets to the default kind), so they are comparability
   tags, not algebra ([rust-uom][rust-uom]).
4. **A hierarchy that propagates** — mp-units' `quantity_spec` tree: LCA-based addition
   (`width + height → length`), a four-level conversion lattice, kind algebra closed
   under `*`/`÷` ([mp-units][mp-units]).

The theory corpus offers no derivation for any rung
([Part I § kinds](#kinds-the-shared-blind-spot)); rung 4 is engineering judgment
(mp-units' own docs quote ISO: the tree is "to some extent, arbitrary"). This is the
survey's widest theory/practice gap.

### 5. The zero-cost evidence ladder

"Zero-cost" claims stratify by the strength of their receipts:

- **Codegen-verified**: GNAT (byte-identical `-O2` assembly, dimensioned vs bare) and
  Boost.Units (same `mulsd`/`addsd` core, plus an ABI caveat: user-declared copy ops
  make `quantity` non-trivially-copyable) — both reproduced locally on the system
  pages. Unitful's LLVM-level check (conversion folded to one `fmul`, mismatch to
  `unreachable`) is the dynamic-world equivalent.
- **Representation-verified**: `sizeof`/layout asserts — uom (`repr(transparent)`),
  mp-units, Au, both D designs, F# (`typeof` identity). The
  [`quantity-erasure.d`][ex-e] prototype machine-checks exactly this rung for D and
  states the honesty boundary: representation equality is not codegen identity.
- **Structural-only**: uom-plugin (`newtype` + roles, no benchmarks behind the paper's
  claim), dimensioned (no `repr(transparent)` — erasure rides unpromised layout).
- **Inverted**: Pint documents its own 38×–250× overheads; Wolfram/MATLAB pay symbolic
  evaluation everywhere and amortize only by leaving the units system
  (`QuantityArray`, `separateUnits`).

Kennedy's erasure semantics is the theory underneath the whole ladder: the program
_means_ its unit-stripped version, so zero-cost is a semantic default the static
systems merely have to not spoil ([mechanisms][mech]) — and the observable holes (F#'s
`box` downcast, reflection blindness, uom's non-float `autoconvert` caveat) are all
places where a runtime peeks behind the trivialization.

### 6. Diagnostics and compile cost

The survey's sharpest irony: **diagnostic quality anti-correlates with static
strength unless explicitly engineered.** The most readable mismatch messages in the
catalog are runtime ones (Unitful's "`1 m` and `1 s` are not dimensionally
compatible"; Pint's `DimensionalityError` with dimensions spelled out), followed by
the two compilers (F#'s one-line FS0001; GNAT's "left operand has dimension [L]").
Among libraries, encoding leakage is the norm — `typenum` spines (uom), positional
`TArr` nests (dimensioned, self-described "gobbly-guck"), 9.8 KB of typelists for a
12-line program (Boost) — and the exceptions prove deliberate investment: mp-units
treats diagnostics as a feature (same-name type/object convention, type-simplification
rules, `unsatisfied<"…">` consteval messages) and Au embeds prose and doc URLs in
`static_assert` text. The D prior art sits in the readable camp (the offending
dimension vector prints in the first error line) with struct-literal noise below it
([d-quantities][dq]). Compile-time cost, where measured, spans an order of magnitude:
uom 16.1 s / ~1.1 GB clean build vs dimensioned's 5.8 s / 0.3 GB on the same
toolchain; mp-units ~3.6 s/TU header-mode; Au ~0.2 s increment over an `iostream`
baseline; Boost ~1.2 s over baseline; Unitful pays ~10.5 s of one-time precompile plus
per-specialization JIT tax.

### The consensus standard

Across fourteen systems and forty years, the field agrees on:

1. **Dimensions are exponent vectors in a free abelian group, compared by unique
   normal form.** Every system — static, dynamic, or symbolic — implements the
   [free-abelian-group][fag] picture as its data model: typelists, `typenum` vectors,
   `consteval` expressions, CTFE structs, dicts, `Rational` tuples, symbolic pairs.
   Normalization-then-identity _is_ the equality algorithm everywhere.
2. **Multiplication is total across dimensions; addition and comparison exist only
   within one.** Enforced by whatever the host has — unification, missing `impl`s,
   SFINAE absence, dispatch fallbacks, dict comparison — but the signature is
   universal, and matches every formalization's core asymmetry.
3. **A quantity is one scalar at run time.** All static systems (and Julia's
   specializations) reduce a quantity to its bare numeric payload; dimension data
   lives in types, or nowhere. Kennedy's erasure theorem is the shared semantics; the
   representation asserts of [Part III §5](#5-the-zero-cost-evidence-ladder) are its
   checkable shadow.
4. **The checker evaluates.** Solving (inference, principal types) is a two-system
   niche with a decidability theorem behind it and a maintenance record against it;
   the field's default is spelled-out dimension arithmetic the checker merely
   confirms.
5. **Affine quantities get a point/difference split, wherever they are handled at
   all.** Seven independent implementations of the same torsor structure
   ([§3](#3-affine-and-logarithmic-quantities)) — the survey's strongest case of
   practice converging on theory.
6. **The dimension vector is known to be too coarse, and no one derives the fix.**
   Stdlib after stdlib ships the `Hz`/`Bq` collapse; the kind mechanisms that exist
   are nominal overlays ([§4](#4-kinds)).
7. **Exact conversion factors are kept exact.** `static_rational`, Au's prime/π
   magnitude vector space, Unitful's `Rational{Int}`, `ExactPi`, chrono's `Period` —
   scale factors are symbolic/rational until a value forces them numeric.

### Architectural trade-offs (still genuinely open)

| Axis            | Option A                                         | Option B                                                      | Choose A when…                                                                                  |
| --------------- | ------------------------------------------------ | ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Exponent domain | `ℤⁿ` (free generators, perfect-square info, gcd) | `ℚⁿ` (total `sqrt`, one-step solving, honest `√Hz`)           | fractional dimensions never arise and you want the type language to reject nonsense             |
| Basis           | closed fixed-width vector (SI-7)                 | open generator set (mint base dimensions freely)              | the domain is settled physics; closed vectors are simpler and diagnose better                   |
| Checking epoch  | static (compile/elaboration)                     | dynamic (run/dispatch time, registry)                         | correctness must not depend on test coverage; erasure and zero-cost matter                      |
| Solver          | checker evaluates (spelled-out arithmetic)       | checker solves (AG unification, inference)                    | you lack compiler/solver access or fear coupling to it — i.e. almost always outside F#          |
| Unit storage    | normalize to base units at construction          | keep the unit in the type; convert lazily at boundaries       | one canonical representation simplifies everything and boundary rounding is acceptable          |
| Kind discipline | dimension-only (+ extra base dims at most)       | a kind layer (flat tags or a spec hierarchy)                  | `Hz`/`Bq`-class confusions are out of scope; kind trees are judgment calls you'd rather not own |
| Affine handling | dedicated point type with typed origins          | offsets confined to conversion functions                      | temperatures/timestamps/positions are first-class data, not I/O edge cases                      |
| Unit vocabulary | code-declared, closed at build time              | data-driven registry (Pint's `default_en.txt`)                | the unit set is known statically; registries trade guarantees for runtime extensibility         |
| Diagnostics     | let the encoding leak (free)                     | engineer messages as a feature (mp-units/Au-style investment) | never — the survey's evidence is that leakage is the single biggest adoption tax                |

---

## Part IV — Where a Sparkles units library would fit

Sparkles' constraints — templates + CTFE, `@safe pure nothrow @nogc` cores,
`-preview=dip1000`/`-preview=in`, `Expected`-based error handling — select a specific
region of the design space, and the survey's D evidence is unusually direct:
[d-quantities][dq] shows two complete prior designs (biozic's CTFE value-level
dimension vectors; Nadlinger's units-as-types conversion graph, still compiling
unmodified after fifteen years), and the three runnable prototypes co-located with
this tree already demonstrate the mechanism end-to-end, CI-verified:
[`quantity-zn-graded.d`][ex-z] (dimension = `ℤ³` normal form as a template value
parameter; rejection demos as `static assert(!__traits(compiles, …))`),
[`quantity-rational-exponents.d`][ex-q] (CTFE-gcd-normalized `ℚ` exponents making
`sqrt` total while `m^(1/2) + m` stays rejected), and [`quantity-erasure.d`][ex-e]
(representation-equality machine-checked, with the codegen-identity boundary stated).

What the findings imply, without designing anything:

- **The mechanism is settled: CTFE dimension values, checker-evaluates.** D has no
  solver socket, so the AG-unification rung is out of reach — and
  [§1](#1-mechanism-evaluators-vs-solvers) shows that rung is a maintenance liability
  even where it exists. D's IFTI covers the `sqr` litmus test at the
  evaluate-and-check level (the prototypes' `Quantity!dim` arithmetic), which is where
  every non-F#/plugin system in the matrix lives anyway. The `quantities` library
  proved the value-parameter encoding in 2013–2020; modern D (named arguments, DIP1000,
  `checkToString`-style `@nogc` test helpers) removes its remaining awkwardness.
- **The prior art's non-negotiables for this codebase are known.** `quantities`' GC- and
  exception-bound runtime twin (`QVariant`) and its parser-on-the-type-path are
  incompatible with a `@nogc` core; a runtime companion, if any, would be an
  [`Expected`][expected]-shaped re-imagining ([d-quantities][dq] draws exactly this
  conclusion).
- **Process lesson, from the `std.units` history:** land as a normal versioned
  sub-package with runnable examples — Nadlinger's technically-sound 2011 proposal
  died of an ecosystem-blessing process, not of design flaws ([d-quantities][dq]).
- **Diagnostics are a first-class requirement, not polish.**
  [§6](#6-diagnostics-and-compile-cost) is unambiguous: encoding leakage is the
  dominant adoption tax on static systems, and D's value-parameter encoding has the
  same failure mode (struct literals in mangled names). mp-units demonstrates that
  engineering the messages is tractable; D's `static assert` + custom `toString` on
  the CTFE dimension value is the natural analogue of Au's prose asserts.

The decisions a future `docs/specs/` proposal must actually make:

| Open decision              | Options on the table                                                                                          | Evidence that frames it                                                                                                                                                                   |
| -------------------------- | ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Exponent domain            | `ℤⁿ` · `ℚⁿ` · `ℤⁿ` surface with `ℚⁿ` escape hatch                                                             | [free-abelian-group][fag] (`ℤⁿ→ℚⁿ` is a change of category); [§2](#2-the-exponent-domain-in-practice) (practice drifted to `ℚ`); both prototypes ([ℤ][ex-z], [ℚ][ex-q]) are green         |
| Affine quantities          | dedicated point type with typed origins · offsets in conversions only · out of scope v1                       | [torsor][torsor] (the additive-torsor layer); [§3](#3-affine-and-logarithmic-quantities) (seven-way convergence; the `celsius = kelvin` trap in [d-quantities][dq])                       |
| Kind system                | none · extra base dimensions · flat tags · spec hierarchy                                                     | [§4](#4-kinds) ladder; [mp-units][mp-units] (propagating kinds are possible but a five-layer ontology); theory offers no derivation ([Part I](#kinds-the-shared-blind-spot))              |
| Registry vs closed system  | code-declared closed set · open generator set · data-driven runtime registry                                  | [Pint][pint] (registry ceiling and its cost); [fsharp-uom][fsharp] (one-liner declarations, no metrology); [Au][au]/[mp-units][mp-units] (open basis with static checking)                |
| Unit storage               | normalize-to-base at construction (`quantities`, uom) · unit-in-type, lazy conversion (mp-units, Au, Unitful) | [rust-uom][rust-uom] (boundary rounding, integer-storage limits); [cpp-au][au] (exact integer reps, `CommonUnit` machinery); [d-quantities][dq] (both designs shipped, trade-offs listed) |
| Diagnostics strategy       | raw encoding · engineered `static assert` prose · custom dimension pretty-printing                            | [§6](#6-diagnostics-and-compile-cost); [mp-units][mp-units] and [Au][au] as the engineered exemplars; [d-quantities][dq] first-line readability finding                                   |
| Erasure guarantee          | representation asserts only · plus codegen checks in CI · plus documented ABI story                           | [§5](#5-the-zero-cost-evidence-ladder); [`quantity-erasure.d`][ex-e] (what is checkable in-language); [boost-units][boost] (the trivially-copyable ABI caveat to avoid)                   |
| Runtime companion          | none · `Expected`-based dynamic quantity · parse-only bridge                                                  | [d-quantities][dq] (`QVariant`'s GC/exception cost); [Pint][pint] (what a term-level twin is for); repo [`Expected` idiom][expected]                                                      |
| Angle & logarithmic policy | SI-dimensionless angles · angle as base dimension · log units deferred                                        | [boost-units][boost]/[au][au] (angle-as-dimension trade); [python-pint][pint] (the `2π` trap; the only shipped dB); theory silence recorded on [torsor][torsor]                           |

---

## Sources

This synthesis rests entirely on the landed pages of this tree: the eight
[theory deep-dives][theory], the fourteen system pages, and the three CI-verified
prototypes in `examples/`. Each carries its own primary citations (papers, pinned
source trees, vendor-doc captures, local reproductions); nothing is cited here that is
not already grounded on one of them. The cross-cutting framings introduced on this
page — the evaluator/solver split, the addition ledger, the zero-cost evidence ladder,
the kind ladder — are syntheses of per-page findings, attributed inline.

<!-- References -->

<!-- Tree -->

[umbrella]: ./index.md
[concepts]: ./concepts.md
[theory]: ./theory/index.md

<!-- Theory pages -->

[whitney]: ./theory/whitney.md
[pi]: ./theory/buckingham-pi.md
[fag]: ./theory/free-abelian-group.md
[tensor]: ./theory/tensor-of-lines.md
[torsor]: ./theory/torsor-representation.md
[kennedy]: ./theory/kennedy-types.md
[hart]: ./theory/hart-multidimensional.md
[mech]: ./theory/type-system-mechanisms.md

<!-- System pages -->

[fsharp]: ./fsharp-uom.md
[uom-plugin]: ./haskell-uom-plugin.md
[dimensional]: ./haskell-dimensional.md
[rust-uom]: ./rust-uom.md
[dimensioned]: ./rust-dimensioned.md
[mp-units]: ./cpp-mp-units.md
[boost]: ./cpp-boost-units.md
[au]: ./cpp-au.md
[dq]: ./d-quantities.md
[pint]: ./python-pint.md
[unitful]: ./julia-unitful.md
[gnat]: ./ada-gnat-dimensions.md
[lean]: ./lean-mathlib-units.md
[wolfram]: ./wolfram-matlab.md

<!-- Runnable prototypes -->

[ex-z]: ./examples/quantity-zn-graded.d
[ex-q]: ./examples/quantity-rational-exponents.d
[ex-e]: ./examples/quantity-erasure.d

<!-- Repo guidelines -->

[expected]: ../../guidelines/idioms/expected/index.md
