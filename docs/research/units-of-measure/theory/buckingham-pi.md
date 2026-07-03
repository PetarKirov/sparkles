# Buckingham π via linear algebra

The π-theorem is the workhorse of classical dimensional analysis: any "physically
meaningful" relation among `n` quantities is equivalent to a relation among `n − r`
dimensionless power products, where `r` is the rank of the **dimension matrix** — the
integer matrix whose columns are the quantities' dimension exponents. Stated this way
it is pure linear algebra ([rank–nullity][free-abelian] for a matrix over `ℚ`), and the
interesting content lies almost entirely in the _hypotheses_ that the classical
literature elides: that the variable list is complete, that the relation is invariant
under change of units, and (in some proofs, not others) that the relating function is
smooth. This page reconstructs the theorem from four generations of primary sources —
[Buckingham 1914][buckingham-hal] (the eponym, who proved less than folklore credits),
[Bridgman 1922][bridgman-archive] (the canonical exposition, and the sharpest early
statement of the hidden hypotheses), [Drobot 1953][drobot-doi] (the first fully
rigorous algebraic foundation), [Curtis–Logan–Parker 1982][clp-doi] (the clean
linear-algebra statement and proof), and [Jonsson 2020][jonsson-arxiv] (the modern
"amended" strengthening on [quantity spaces][free-abelian]).

> [!NOTE]
> This page is about the **theorem** — its linear-algebra core, its analytic step, and
> its hypotheses. The algebraic structures it presupposes get their own pages: the
> [free-abelian dimension group][free-abelian] (exponent lattices, Kennedy/Jonsson
> lineage), [Whitney's quantity structures][whitney] (the 1968 axiomatization the
> quantity-calculus school builds on), the [one-dimensional-vector-space
> picture][tensor-lines], and the [torsor view of unit systems][torsor]. Mechanized
> _type-system_ uses of the same linear algebra live in
> [type-system mechanisms][mechanisms] and [Kennedy's dimension types][kennedy].

---

## At a glance

| Dimension            | Buckingham π via linear algebra                                                                                                                                                                             |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Core object          | The dimension matrix `A` (`d` base dimensions × `n` quantities), entries in `ℚ` — the coordinate form of the dimension homomorphism onto the [free abelian dimension group][free-abelian]                   |
| Central theorem      | A **unit-free** relation `f(Q₁,…,Qₙ) = 0` is equivalent to `ψ(Π₁,…,Πₙ₋ᵣ) = 0` in `n − r` dimensionless products, `r = rank A` ([Curtis–Logan–Parker][clp-doi], Lemma 2 and §3)                              |
| Algebraic engine     | Rank–nullity: dimensionless products ↔ `ker A`, so the number of independent `Π`s is `dim ker A = n − r`                                                                                                    |
| Analytic engine      | The **covariance premise**: the relation holds in every system of units → normalize `r` quantities to `1` by a unit change and the rest of the relation only sees the `Π`s                                  |
| Origin               | Stated by Vaschy (1892); named after [Buckingham 1914][buckingham-hal], who proved it "for special cases" (per [CLP][clp-doi], p. 118) under a sum-of-monomials assumption                                  |
| Canonical exposition | [Bridgman 1922][bridgman-archive]: "complete equations", the `Π` theorem via partial differentiation (needs smoothness), and the sharpest early statement of the tacit hypotheses                           |
| Rigorous statements  | [Drobot 1953][drobot-doi] (multiplicative linear spaces, invariance + homogeneity axioms, counterexamples); [CLP 1982][clp-doi] (frames + group action, no smoothness); [Jonsson 2020][jonsson-arxiv]       |
| Exponent domain      | `ℝ` in the classical treatments (CLP Definition 1, Drobot's axioms); `ℚ` suffices whenever `A` is rational (rank is field-independent); `ℤ` in the amended version (Jonsson, after Quade and Raposo)        |
| Hidden hypotheses    | Completeness of the variable list; unit-invariance ("complete"/"unit-free"/covariant); the relation is the _only_ relation among the variables; positivity `Qᵢ > 0` (classical); smoothness (Bridgman only) |
| What it is _not_     | A theory of kinds or of addition: the formalism sees only the multiplicative skeleton of quantities — torque vs energy are indistinguishable, and `+` across dimensions is not even expressible             |
| Mechanizations       | [`pint.pi_theorem`][pint] (exact `Fraction` echelon form); [`LeanDimensionalAnalysis`][lean] (`dimensional_matrix`, kernel, `n − rank`); the same elimination underlies [unit type systems][mechanisms]     |

---

## Primary sources

Inspected directly (local artifacts under `$REPOS/papers/units-of-measure/`):

- **E. Buckingham, ["On Physically Similar Systems; Illustrations of the Use of
  Dimensional Equations"][buckingham-hal], _Physical Review_ 4(4):345–376, 1914.** The
  origin of the name. Read in full from
  `buckingham-1914-similar-systems-physrev.pdf` (HAL open-access scan of the original;
  the OCR text layer is noisy, so quotes below were transcribed against the page
  images).
- **P. W. Bridgman, _Dimensional Analysis_, Yale University Press, 1922.** The
  canonical book-length exposition; Chapter IV is "The Π theorem". Read from
  `bridgman-1922-dimensional-analysis-book.pdf` (OCR scan with minor noise; page
  numbers below are the book's).
- **S. Drobot, ["On the foundations of dimensional analysis"][drobot-doi], _Studia
  Mathematica_ 14:84–99, 1953.** The first fully rigorous algebraic foundation. The
  local artifact `drobot-1953-foundations-dimensional-analysis-studia.pdf` is an
  **image-only** scan (no text layer); it was read page-by-page as images, so this page
  cites it _structurally_ (section/page references, paraphrase); the two short quoted
  phrases below were transcribed from the page images.
- **W. D. Curtis, J. D. Logan & W. A. Parker, ["Dimensional Analysis and the Pi
  Theorem"][clp-doi], _Linear Algebra and its Applications_ 47:117–126, 1982.** The
  rigorous linear-algebra statement and proof this page's formal core follows. Read in
  full from `curtis-logan-parker-1982-pi-theorem-laa.pdf` (OCR with minor noise).
- **D. Jonsson, ["An Algebraic Foundation of Amended Dimensional
  Analysis"][jonsson-arxiv], arXiv:2010.15769v2, 2020.** The modern strengthening: a
  representation theorem for quantity functions on quantity spaces, integer exponents,
  no positivity, and _systems_ of representations. Read in full from
  `jonsson-2020-algebraic-foundation-dimensional-analysis-arxiv.pdf` (born-digital,
  clean text layer).

Cited only through the above (not independently inspected — treat each attribution as
the citing source's claim): **Vaschy 1892** (first statement of the theorem; per CLP
p. 118 and Jonsson §1) `[unverified]`; **Federman 1911** (identity-form proof of a
special case; per Jonsson p. 6) `[unverified]`; **Riabouchinsky 1911** and
**Martinot-Lagarde 1948** (more general proof; per CLP p. 118) `[unverified]`;
**Birkhoff, _Hydrodynamics_** (the algorithmic formulation CLP §2 expands; per CLP
p. 119) `[unverified]`; **Langhaar 1951** and **Brand 1957** (removal of the smoothness
hypothesis via generalized homogeneity; per Jonsson p. 1) `[unverified]`; **Quade
1961** and **Raposo 2019** (integer-exponent versions; per Jonsson p. 1)
`[unverified]` — Raposo's papers are inspected on the [Whitney page][whitney].

> [!IMPORTANT]
> **Notation collision across sources.** Buckingham writes `n` quantities and `k`
> fundamental units, Bridgman `n` quantities and `m` fundamental units, CLP `m`
> quantities and `n` fundamental dimensions, Jonsson `n` arguments of rank `r`. This
> page fixes: **`n` quantities `Q₁ … Qₙ`, `d` base dimensions, dimension matrix `A`
> of shape `d × n`, rank `r`** — and translates each quote's letters where needed.

---

## Formal core

### The dimension matrix and its null space

Fix base dimensions `𝔡₁, …, 𝔡_d` (e.g. `M`, `L`, `T`). Each quantity `Qᵢ` carries a
**dimension monomial** ([CLP][clp-doi] Definition 1, p. 119: "The dimension of each
dimensional quantity Q, expressed as a monomial with real exponents in the
`𝔮₁,…,𝔮ₙ`, is called the dimension monomial of Q and denoted `[Q]`"):

```text
[Qᵢ] = 𝔡₁^{a₁ᵢ} · 𝔡₂^{a₂ᵢ} ⋯ 𝔡_d^{a_dᵢ}
```

The exponents assemble into the **dimension matrix** `A = (a_ℓi)`, `d` rows (base
dimensions) by `n` columns (quantities). Because `[Q₁Q₂] = [Q₁][Q₂]` and
`[Qᶜ] = [Q]ᶜ`, forming a power product of quantities acts _linearly_ on exponent
vectors, and CLP's equation (5) falls out (p. 120): a product

```text
Q = Q₁^{α₁} · Q₂^{α₂} ⋯ Qₙ^{αₙ}     is dimensionless   ⟺   Aα = 0
```

where `α = (α₁,…,αₙ)ᵀ`. **Dimensionless power products are exactly the null space of
`A`.** By rank–nullity, `dim ker A = n − rank A = n − r`: there are precisely `n − r`
independent dimensionless products, no more and no fewer. That single line is the
entire combinatorial content of the π-theorem; everything else is about turning "the
law can be rewritten in the `Π`s" from a slogan into a theorem.

> [!NOTE]
> **Why `ℚ` is enough.** CLP and Drobot allow _real_ exponents, but the matrix `A`
> arising from any actual dimension system has rational (in practice integer) entries,
> and Gaussian elimination never leaves the field of the entries — so
> `rank_ℚ A = rank_ℝ A`, and `ker A` always has a basis of rational vectors, hence
> (clearing denominators) of _integer_ vectors. Nothing in the classical theorem is
> lost by working over `ℚ`, which is what makes the [free-abelian-group
> formalizations][free-abelian] and the [type-system mechanizations][mechanisms]
> adequate for it. Jonsson notes the spread of conventions explicitly: "The exponents
> `Wj` and `Wkj` are usually assumed to be rational or real numbers …, but Quade and
> more recently Raposo use integer exponents" ([Jonsson][jonsson-arxiv], p. 1), and his
> own amended theorem produces a _unique_ primitive integer tuple
> (`Wₖ > 0`, `gcd(Wₖ, Wₖ₁, …, Wₖᵣ) = 1`) per reducible variable (§4, pp. 7–8).

### Statement

CLP's concrete version ([Lemma 2][clp-doi], p. 122, their Section 2; "This lemma is
the content of the pi theorem", p. 122):

> "If the law `f(Q₁,…,Q_m) = 0` is unit free, then it is equivalent to a law of the
> form `φ(Π_{r+1},…,Π_m) = 0`." — Curtis, Logan & Parker,
> `curtis-logan-parker-1982-pi-theorem-laa.pdf`, p. 122 (their `m` is this page's `n`)

Here **unit free** is the load-bearing premise (CLP Definition 2, p. 121): writing
`S_λ(Q) = λ₁^{l₁} ⋯ λ_d^{l_d} · Q` for the rescaling of a quantity of dimension
`𝔡₁^{l₁} ⋯ 𝔡_d^{l_d}` under a change of units `λ ∈ ℝ₊^d`,

> "The law `f(Q₁,…,Q_m) = 0` is unit free if for all `λ` the laws `f = 0` and
> `S_λ(f) = 0` are equivalent […] This is a reasonable definition. `S_λ(Q)` is just Q
> 'measured in different units,' so it expresses the fact that a physical law should
> not depend on the units to express the various quantities." — Curtis, Logan &
> Parker, p. 121

### Proof sketch: rank–nullity plus one analytic step

The proof splits cleanly into a linear-algebra half (Steps 0–1: _which_ dimensionless
products exist) and an analytic half (Steps 2–4: _why the law factors through them_),
following CLP §2, pp. 119–122:

```text
Step 0 (data).       [Qᵢ] = 𝔡₁^{a₁ᵢ} ⋯ 𝔡_d^{a_dᵢ};   A = (a_ℓi), shape d × n;   r = rank A.

Step 1 (kernel).     Q₁^{α₁} ⋯ Qₙ^{αₙ} dimensionless ⟺ Aα = 0;   dim ker A = n − r.
                     Reorder so columns a₁ … a_r are linearly independent; for each
                     k = r+1 … n write  a_k = c_{k1}·a₁ + ⋯ + c_{kr}·a_r  and set

                         Π_k := Q_k · Q₁^{−c_{k1}} ⋯ Q_r^{−c_{kr}}

                     Each exponent vector (−c_{k1}, …, −c_{kr}, 0, …, 1, …, 0)ᵀ lies in
                     ker A, and the n − r of them are independent (the trailing block is
                     an identity) — a basis of ker A, i.e. a maximal set of Π's.

Step 2 (premise).    Unit-freeness: f(Q₁,…,Qₙ) = 0 ⟺ f(S_λQ₁,…,S_λQₙ) = 0 for all
                     λ ∈ ℝ₊^d.  Note S_λ(Π_k) = Π_k — the Π's are invariants of the
                     unit-change action (CLP eq. (10), p. 122).

Step 3 (normalize).  Given values Q₁,…,Q_r > 0, seek λ with S_λ(Qᵢ) = 1 for i ≤ r:
                     taking logarithms turns λ₁^{a₁ᵢ} ⋯ λ_d^{a_dᵢ} Qᵢ = 1 into

                         a₁ᵢ·ln λ₁ + ⋯ + a_dᵢ·ln λ_d = −ln Qᵢ      (i = 1 … r)

                     — a linear system whose coefficient columns a₁ … a_r are
                     independent, hence solvable (set λ_ℓ = e^{z_ℓ}).  This is where
                     BOTH remaining hypotheses bite: independence comes from r = rank A,
                     and ln Qᵢ needs the positivity assumption Qᵢ > 0.

Step 4 (reduce).     Φ(Q₁,…,Qₙ) := (Q₁,…,Q_r, Π_{r+1},…,Πₙ) is a bijection of ℝ₊ⁿ;
                     g := f ∘ Φ⁻¹ is unit free whenever f is (CLP Lemma 1).  Apply the
                     λ of Step 3: since the Π-coordinates are S_λ-invariant,

                         g(Q₁,…,Q_r, Π_{r+1},…,Πₙ) = 0  ⟺  g(1,…,1, Π_{r+1},…,Πₙ) = 0.

                     Define ψ(Π_{r+1},…,Πₙ) := g(1,…,1, Π_{r+1},…,Πₙ).  Then

                         f(Q₁,…,Qₙ) = 0  ⟺  ψ(Π_{r+1},…,Πₙ) = 0.                      ∎
```

No continuity, differentiability, or even measurability of `f` is used — the analytic
step is _exact normalization by a group action_, not calculus. (Contrast Bridgman's
1922 proof below, which differentiates.) The worked falling-body example, CLP
pp. 123–124:

```text
x = ½ g t²      (Q₁,Q₂,Q₃) = (t, x, g);   base dimensions T, L

                  t   x   g
            T ┌   1   0  −2 ┐         rank r = 2,   n − r = 1
            L └   0   1   1 ┘

a₃ = −2·a₁ + 1·a₂   ⟹   Π₃ = Q₃ · Q₁² · Q₂⁻¹ = g t² / x

and the law  f = x − ½gt² = 0  is equivalent to  1 − ½·Π₃ = 0   (ψ(z) = 1 − z/2).
```

### The abstract version: laws as equivariant families

CLP §3 (pp. 124–125) then restates the theorem — in their abstract's words,
"without reference to physical
quantities, units, dimensions, and so on": take an `n`-dimensional real vector space
`V` of "quantities" _written additively_ (the product `Q₁Q₂` becomes `Q₁ + Q₂`, the
power `Qᶜ` becomes `cQ` — i.e. `V` is the exponent space), a linear map
`T : V → ℝ^d` of rank `r` (the dimension homomorphism; `Q` is dimensionless iff
`T(Q) = 0`), and the set `F` of ordered bases ("frames") of `V`, each frame playing
the role of a choice of independent reference quantities. A **law on `V` compatible
with `T`** assigns to every frame `e` a nonempty subset `L_e ⊆ ℝ₊ⁿ` of admissible
value tuples such that (i) `L_e` is stable under the unit-change action of the
additive group `ℝ^d` (unit-freeness) and (ii) the assignment is equivariant under
change of frame (CLP Definition 2 of §3, p. 124). The theorem (p. 125):

> "Let L be a law on V compatible with T. Then there exist frames e such that
> `T(e_k) = 0` for `k = r + 1,…,m`, and for any such frame we have
> `L_e = R^r_+ × L̃_e` for some `L̃_e ⊆ R^{m−r}_+`." — Curtis, Logan & Parker, p. 125

That is: in a frame whose last `n − r` members are dimensionless, the law constrains
_only_ the dimensionless coordinates — "the values of `Q₁,…,Q_r` are unrestricted
while the values of `(Π_{r+1},…,Π_m)` must lie in a subset of `R^{m−r}_+`. We say the
law is a relationship among the `Π`'s" (Remark C, p. 125). The proof is three lines of
the same Step-3 normalization; CLP close by noting that in this formulation "the proof
is nearly transparent" (p. 125).

### The usually-elided hypotheses

The theorem is only as strong as premises that most textbook statements leave
implicit. Collecting them from the four sources:

| #   | Hypothesis                              | Where it is made explicit                                                                                                                                                                             | What fails without it                                                                                                                                                    |
| --- | --------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| H1  | **Completeness of the variable list**   | Buckingham p. 345 (the "complete equation" proviso); Jonsson §7 ("while the assumptions may be hidden or so intuitive as to be overlooked, assumptions there are", p. 16)                             | Omit `G` from the two-body problem and _no_ covariant relation among `M, m, d, t` exists at all — Jonsson Example 6, pp. 15–16                                           |
| H2  | **Unit-invariance (covariance)**        | Bridgman's "complete equation" (p. 37); CLP's "unit free" (Definition 2, p. 121); Drobot's dimensional invariance, his eq. (4), p. 90; Jonsson's "covariant scalar representation" (p. 3)             | Drobot's counterexample 1° (p. 91): a homogeneous but non-invariant `Φ` for which the coefficient of the reduced form depends on the quantity itself — the theorem fails |
| H3  | **Homogeneity / single relation**       | Drobot's homogeneity axiom, his eq. (5), p. 91 — _independent_ of H2 (counterexample 2°, p. 91); Bridgman's "tacit restriction" that `φ = 0` is the **only** relation among the variables (pp. 41–42) | Bridgman's falling body: `v + s = gt + ½gt²` is complete (unit-invariant) yet **not** dimensionally homogeneous, because `v = gt` and `s = ½gt²` both hold (p. 42)       |
| H4  | **Positivity `Qᵢ > 0`**                 | CLP work in `ℝ₊ⁿ` throughout (§2, p. 121); Jonsson p. 1 ("It is usually assumed that `t, tᵢ > 0` … but it restricts the scope")                                                                       | Step 3's logarithm is undefined; Jonsson's amendment drops H4 — only the basis quantities `xⱼ ≠ 0` are needed, over _any_ field (Theorem 1, pp. 4–5)                     |
| H5  | **Smoothness of `f`**                   | Bridgman's proof differentiates the invariance identity with respect to the scale factors (pp. 38–39); _not_ needed by Drobot, CLP, or Jonsson                                                        | Nothing — H5 is an artifact of Bridgman's proof method; "Langhaar and Brand later showed that a generalised homogeneity assumption suffices" (Jonsson p. 1)              |
| H6  | **`r` is the rank, not the unit count** | Bridgman pp. 43–44 (determinant caveats); Drobot's determinant criterion for dimensional independence (p. 94); CLP make `r = rank A` primitive (p. 120)                                               | Buckingham's `i = n − k` over-counts the reduction whenever the problem's quantities span fewer than `k` base dimensions — see the next subsection                       |

### What Buckingham actually proved — vs the folklore

The historical record, as reconstructed by [CLP][clp-doi] (p. 118):

> _"The pi theorem appears to have been first stated by A. Vaschy [9] in 1892. Later,
> in 1914, E. Buckingham [4] gave the first proof of the pi theorem for special cases,
> and now the theorem often carries his name."_ — Curtis, Logan & Parker, p. 118

and by [Jonsson][jonsson-arxiv] (p. 6), who adds Federman:

> _"(Vaschy's and Buckingham's proofs were sketchy, and Federman's proof covered only
> a special case, but this was pioneering work.)"_ — Jonsson,
> `jonsson-2020-algebraic-foundation-dimensional-analysis-arxiv.pdf`, p. 6

What the 1914 paper actually contains (all page references to
`buckingham-1914-similar-systems-physrev.pdf`):

1. **A structural assumption in place of a theorem.** Buckingham does not treat an
   arbitrary relation `f = 0`; he _postulates_ (his equation (3), p. 346) that "every
   complete physical equation" is a **sum of monomial power products** with
   dimensionless coefficients, arguing from meaning rather than proving:

   > _"Such expressions as log Q or sin Q do not occur in physical equations; for no
   > purely arithmetical operator, except a simple numerical multiplier, can be
   > applied to an operand which is not itself a dimensionless number, because we can
   > not assign any definite meaning to the result of such an operation."_ —
   > Buckingham 1914, p. 346

   Given that form, dividing by one term and applying Fourier's homogeneity principle
   (which Buckingham credits explicitly: "the familiar principle, which seems to have
   been first stated by Fourier, that all the terms of a physical equation must have
   the same dimensions, or that every correct physical equation is dimensionally
   homogeneous", p. 346) makes every term a dimensionless product — the reduction to
   `ψ(Π₁, Π₂, …) = 0` (his (9) and (13), pp. 347, 351) is then a repackaging of the
   assumed shape, not a proof for general `f`. This is exactly CLP's "special cases".

2. **`i = n − k` by counting units, not by rank.** Buckingham's count of independent
   `Π`s (p. 347) is `i = n − k` where "k [is] the number of arbitrary fundamental
   units needed as a basis for the absolute system `[Q₁], … [Qₙ]` by which the Q's are
   measured", and he _asserts_ — without criterion or proof — that "there is always
   among the n units [Q], at least one set of k which may be used as fundamental
   units, the remaining (n − k) being derived from them" (p. 347). That assertion is
   precisely the hypothesis `rank A = k`. To his credit, Buckingham _computes_ with
   the rank when it matters: in his electromagnetic energy-density example he notes
   that "although in general, electromagnetic units require four fundamental units,
   three are enough in this instance" and proceeds with `n = 5`, `k = 3`, `i = 2`
   (p. 358). The folklore statement "number of π's = variables minus number of base
   dimensions" fossilizes the special case; the correct count `n − rank A` — with the
   degenerate cases classified — is only nailed down later. Bridgman already flags the
   gap (pp. 43–44): after deriving `n − m` solutions "in the general case", he
   concedes that "there may be more than n − m independent solutions if it should
   happen that all the m-rowed determinants of the exponents vanish", and declines to
   develop the theory — "let the exceptions take care of themselves". Drobot replaces
   the hand-waving with a determinant criterion for dimensional independence (p. 94),
   and CLP simply define `r = rank A` (p. 120).

3. **The completeness proviso, stated but not formalized.** The hypothesis that no
   relevant quantity has been forgotten is Buckingham's own headline caveat:

   > _"If none of the quantities involved in the relation has been overlooked, the
   > equation will give a complete description of the relation subsisting among the
   > quantities represented in it, and will be a complete equation."_ — Buckingham
   > 1914, pp. 345–346

   Note his "complete equation" is a _conjunction_ of H1 and H2: nothing overlooked
   _and_ dimensionless coefficients (unit-invariance). Bridgman later teases the two
   apart, keeping "complete" for pure unit-invariance (p. 37: "it remains true
   formally without any change in the form of the function when the size of the
   fundamental units is changed in any way whatever. An equation of such a form we
   shall call a 'complete' equation") and insisting that "the assumption of the
   completeness of the equation is absolutely essential to the treatment" (p. 37).

4. **The name.** Both the `Π` notation and the attribution stuck because of
   Bridgman's book: "The result stated in this form is known as the Π theorem, and
   seems to have been first explicitly stated by Buckingham, although an equivalent
   result had been used by Jeans, without so explicit a statement" (Bridgman 1922,
   p. 40). Buckingham's own motivation was priority-adjacent: §7 of the 1914 paper is
   an extended rebuttal of Tolman's "principle of similitude", arguing the results
   "are merely consequences of the principle of dimensional homogeneity, which is far
   from being either new or unfamiliar" (pp. 356–357).

### The rigorized successors

**Drobot 1953** (structural summary; image-only scan, no verbatim quotes — all page
references to `drobot-1953-foundations-dimensional-analysis-studia.pdf`, journal
pagination). Drobot's stated diagnosis (§I.3, p. 85) is that the paradoxes of
dimensional analysis stem from primitive notions and axioms never being formulated
clearly, and his §I.4 program is to rebuild the subject inside linear-space theory. He
axiomatizes a **multiplicative linear space** `Π` — commutative, with division, and
with a real-power operation satisfying `A^{a+b} = A^a A^b`, `(AB)^a = A^a B^a`,
`(A^a)^b = A^{ab}`, `A¹ = A` (§III.1, p. 89) — containing the positive reals as a
distinguished subspace `Π⁰`; a **dimensional quantity** is any element outside `Π⁰`
(p. 89). A **system of units** is a maximal dimensionally independent set
`X₁, …, X_d` (independence: `A₁^{a₁} ⋯ A_m^{a_m}` a number forces all `aᵢ = 0`,
p. 89), and every element has a unique representation `A = a·X₁^{a₁} ⋯ X_d^{a_d}`
with `a > 0` (p. 90) — the free-abelian skeleton, in multiplicative dress. He then
defines **dimensional transformations** `Δ` (automorphisms fixing `Π⁰`, p. 90),
**dimensionally invariant** functions (`Φ(ΔQ₁,…,ΔQ_s) = ΔΦ(Q₁,…,Q_s)`, eq. (4),
p. 90) and **dimensionally homogeneous** functions (scaling each argument by positive
numbers rescales the value, eq. (5), p. 91), and proves _Theorem Π_ (p. 91): an
invariant and homogeneous `Φ(A₁,…,A_m; P₁,…,P_r)` with `A₁,…,A_m` dimensionally
independent equals `φ·∏ A_k^{f_k}` where the coefficient `φ` depends only on the
dimensionless `π`s of the `P`s. The proof works by transporting the multiplicative
axioms to an ordinary (additive) linear space and applying two translation/
equivariance theorems proved there (§II, Theorems I–II, pp. 86–87). Crucially, §IV
("Remarks on Theorem Π", pp. 91–92) shows the two premises are _independent_: he
exhibits a homogeneous-but-not-invariant function and an invariant-but-not-homogeneous
function for which the conclusion fails — the first time the theorem's hypotheses were
delimited by counterexamples. Dimensions themselves appear only afterwards (§VI,
p. 93), as the equivalence classes of `B = aA` — Maxwell's `[A] = [B]` notation — with
the determinant-nonvanishing criterion for independence (p. 94).

**Jonsson 2020** replaces real functions of measures with **quantity functions**
`Φ : C₁ × ⋯ × Cₙ → C₀` between dimensions of a [quantity space][free-abelian] `Q`
over an arbitrary field `K` (a commutative _scalable monoid_ with a finite basis;
dimensions are the congruence classes of `x ∼ y ⟺ α·x = β·y`, and `Q/∼` is a
finitely generated free abelian group — §2, pp. 2–3). His Theorem 1 (pp. 4–5) is the
π-theorem as a **representation theorem**: if the dimension tuple admits unique
integer expansions over a _local dimensional basis_ `(E₁,…,E_r)` and `Φ` admits a
**covariant scalar representation** — a single numeric function `φ : Kⁿ → K` that
computes `Φ`'s measure from the arguments' measures _for every choice of local basis_
(his eq. (5), p. 3) — then there is a unique quantity function `Ψ` of the `n − r`
dimensionless `π`s with `y₀ = ∏ xⱼ^{W₀ⱼ} · Ψ(π₁,…,π_{n−r})`. The amendments over the
classical statement: exponents are integers with a unique `gcd`-normalized tuple per
variable (§4, pp. 7–8, at the price of representing `y₀^{W₀}` rather than `y₀`);
positivity is dropped (only the basis quantities must be non-zero; "the present
representation theorem holds for any field, for example, the complex numbers", p. 6);
and — the genuinely new move — a problem generally admits **several** adequate
partitions of its dimension tuple, hence a _system_ of `S ≥ 1` simultaneous
representations (his eq. (18), p. 8), from which symmetry arguments extract strictly
more than any single reduction can. His Example 6 (pp. 15–16) runs the two-body
problem twice and derives `t² = k·d³·G⁻¹·(M + m)⁻¹` — Kepler's third law with the
correct mass dependence, "without use of equations of motion" (abstract, p. 1) —
where Bridgman, using one representation, had to leave an undetermined function of the
mass ratio:

> _"The basic reason why Bridgman was not able to derive the much more informative
> equation (25) was that he did not reflect on the possibility that the original
> function could have more than one representation, and as a consequence he did not
> reflect on what inferences could be drawn from symmetries between different
> representations."_ — Jonsson, p. 16

---

## Structural anatomy

### What structure is primary; objects and morphisms

The π-theorem tradition takes the **multiplicative-exponential skeleton of quantities
plus a group of unit rescalings** as primary; everything is engineered so that the
dimension map is linear. Concretely, per source:

- **Buckingham/Bridgman:** no explicit structure — quantities are positive numbers
  ("we use α interchangeably for the quantity itself and for its numerical measure",
  Bridgman p. 38) whose measures transform by `x₁^{a₁} ⋯ x_d^{a_d}` under unit
  changes; the "structure" is the transformation rule itself (Bridgman pp. 38–39).
- **Drobot:** the multiplicative linear space `Π ⊇ Π⁰` with real powers; morphisms are
  the dimensional transformations `Δ` (automorphisms fixing numbers, p. 90).
- **CLP:** an `n`-dimensional real vector space `V` of quantities-as-exponents plus a
  linear `T : V → ℝ^d`; a _law_ is a frame-indexed, unit-action-stable, change-of-
  frame-equivariant family of subsets `L_e ⊆ ℝ₊ⁿ` (§3, p. 124). The dimension matrix
  is the matrix of `T` in a frame.
- **Jonsson:** a quantity space (commutative scalable monoid over a field, finite
  basis); the dimension group `Q/∼` is finitely generated free abelian (p. 2), and
  the dimension matrix reappears as the coordinate expression of dimension expansions
  over a basis of `Q/∼` (§5, pp. 10–11), with independence of dimension tuples
  _equivalent_ to linear independence of the corresponding columns (p. 10).

In all four, quantities **multiply and take powers**; the free-abelian/vector-space
structure of dimensions is either assumed (Buckingham), derived from an invariance
postulate (Bridgman's "absolute significance of relative magnitude" — see
[homogeneity](#how-dimensional-homogeneity-is-expressed) below), or axiomatized
(Drobot, Jonsson).

### Quantity, unit, dimension, kind

**Quantity.** Buckingham/Bridgman: the number measuring a physical magnitude in a
given unit system (deliberately conflated with the magnitude; Bridgman p. 38). CLP §2:
a positive real; CLP §3: an element of the abstract vector space `V` (Remark A,
p. 124). Drobot: an element of `Π` that is not a number (p. 89). Jonsson: an element
of a quantity space; each has a _measure_ `µ_E(x) ∈ K` relative to a basis expansion
(p. 2).

**Unit.** Buckingham: the "fundamental units" of an absolute system, `k` of which can
be chosen among the problem's own quantities (p. 347). Drobot: a _system of units_ is
a maximal dimensionally independent tuple `X₁,…,X_d` of elements of `Π` — units are
ordinary quantities singled out for reference, and "such a system cannot contain
numbers" (p. 89). CLP: a **frame** — an ordered basis of `V` (p. 124). Jonsson: a
_local basis_ `E = (e₁,…,e_r)` of non-zero quantities spanning the dimensions in the
problem (p. 3) — local because it need only span the problem's dimensions, not all of
`Q` (remark after Theorem 1, p. 6).

**Dimension.** Buckingham/Bridgman: the exponent tuple in the "dimensional formula"
(Bridgman pp. 22–23). CLP: the value `T(Q) ∈ ℝ^d`, i.e. the dimension monomial read
as a vector (Remark A, p. 124). Drobot §VI (p. 93) and Jonsson (p. 2): an
**equivalence class** of quantities — `B = aA` for a number `a` (Drobot), `α·x = β·y`
(Jonsson) — with the classes forming a group under representative-wise product.

**Kind.** _Silence — with one nuance._ None of the four sources has a notion of kind
finer than dimension: two quantities with equal dimension-matrix columns are
interchangeable in every statement (see
[Expressive power & limits](#expressive-power--limits)). The nuance is Buckingham's
handling of _several quantities of the same kind_ (p. 345): only one representative of
each kind enters the `Q` list, the others being carried as dimensionless ratios
`r′, r″, …` that ride along as extra arguments of the unknown function (his
equations (1) and (13), pp. 345, 351). Kinds are thus acknowledged operationally — as
a bookkeeping device for shape parameters — but given no algebraic status.

### How dimensional homogeneity is expressed

Four distinct answers, in increasing order of rigor:

1. **As an inherited principle** (Buckingham): Fourier's principle is _assumed_, and
   sums, `log`, `sin` of dimensional operands are ruled out by an appeal to
   meaninglessness (p. 346, quoted above).
2. **As a theorem with counterexamples** (Bridgman): homogeneity is _derived_ from the
   complete-equation premise **plus** the tacit hypothesis that the relation is the
   only one binding the variables — "It is to be most carefully noticed that the work
   above was subject to a most important tacit restriction at the very outset. In
   putting `φ(α, β, …) = 0` it was tacitly assumed that this is the only relation
   between `α, β`, etc." (p. 41). Drop that and homogeneity _fails while
   unit-invariance holds_: for a falling body, `v + s = gt + ½gt²` "is obviously a
   complete equation in that it is true and remains true no matter how the fundamental
   units of length and time are changed in size", yet it is not dimensionally
   homogeneous, because `v = gt` and `s = ½gt²` are simultaneously true (p. 42).
   Bridgman explicitly demolishes the textbook "apples and oranges" argument as a
   proof: "The possibility of equations like those just considered is in itself a
   refutation of the intuitional method of proof of the principle of dimensional
   homogeneity sometimes given" (p. 42) — the very intuition CLP's introduction still
   opens with ("one cannot add apples and oranges", p. 117).
3. **As two independent axioms** (Drobot): _dimensional invariance_ (equivariance
   under `Δ`, eq. (4)) and _homogeneity_ (positive-scaling compatibility, eq. (5)) are
   separate hypotheses of Theorem Π, each shown necessary by a counterexample
   (pp. 90–91).
4. **As existence of a covariant representation** (Jonsson): homogeneity is not
   postulated about an equation at all; the primitive is whether the quantity function
   `Φ` _admits_ a basis-independent scalar representation. Some complete quantity
   functions admit none (his explicit example, p. 3), and then dimensional analysis
   simply does not apply. What used to be "the principle of dimensional homogeneity"
   becomes a _definable property_ with a characterization theorem.

### What acts as change of units, and what is invariant

The unit-change action is, in every formulation, a **multiplicative group action**:

- CLP §2: `S_λ`, `λ ∈ ℝ₊^d`, acting on each quantity through its dimension exponents;
  §3 abstractly: the additive group `ℝ^d` acting on value tuples via
  `exp(λ·Teᵢ)`-scalings per frame member (p. 124). "We regard the λᵢ as dimensionless
  (in practice they are just conversion factors)" (p. 121).
- Drobot: the dimensional transformations `Δ`, and separately the passage between two
  systems of units via a non-singular exponent matrix (his eqs. (2)–(3), p. 90 — a
  change of basis in the dimension group, cf. the [torsor picture][torsor] of unit
  systems).
- Jonsson: change of local basis `E ↦ E′`; covariance says the _same_ numeric `φ`
  works for all `E`.

The **invariants** are exactly the dimensionless products: CLP's eq. (10) shows
`S_λ(Π_k) = Π_k` (p. 122); Jonsson's Lemma 1(c)–(d) shows the measure of a quantity of
dimension `[1_Q]` — in particular each `π_k = y_k·Δ_k⁻¹` — "does not depend on E"
(pp. 4–5). The theorem itself is then a statement of invariant theory: _the law, being
unit-stable, factors through the invariants of the action_, and rank–nullity counts
the independent invariants. Bridgman's version of the invariance-of-`Π`s observation
is operational: keeping all `Π`s and `r`s constant across two similar systems, "any
function of these arguments must also remain constant, no matter what its form may be"
(Buckingham p. 355, in the similitude section; Bridgman Chapter IV passim). One more
invariant deserves note: Drobot's _principle of similitude_ (p. 94) reads model
testing as exactly this invariance — model and prototype are similar when their `π`s
agree, which is Buckingham's §6 notion of "physically similar systems" (pp. 353–355)
in rigorous form.

### Addition across quantities of different dimension

This is where the π-theorem tradition is at its most instructive, because the four
sources give **four different accounts of the same prohibition** — and one of them
shows the prohibition is _conditional_:

- **Buckingham — meaninglessness.** Cross-dimension sums are excluded by fiat from
  "complete physical equations" via the operational argument that no arithmetic
  operation except multiplication by a number applies to a dimensional operand
  (p. 346). Addition across dimensions is not false; it is _not a physical equation_.
- **Bridgman — a theorem's conclusion, not an axiom.** Since homogeneity is derived
  (from unit-invariance + single-relation), the addition ban has the same status: his
  `v + s = gt + ½gt²` is a perfectly true, unit-invariant equation that _does_ add a
  velocity to a length — legitimate precisely because the variables satisfy other
  relations that let the inhomogeneous sum stay invariant (p. 42). He even notes such
  compound equations decompose "like the vector equation, into a number of simpler
  equations, by picking out the parts with the same dimensions" (pp. 42–43). The "you
  cannot add apples and oranges" slogan is thus, on Bridgman's account, a statement
  about _isolated laws under the covariance premise_, not about algebra.
- **Drobot — addition only within a fiber.** `Π` has _no_ addition. Sums are
  introduced late (§VI.4, pp. 94–95) by the rule `αA + βA = (α+β)A` — i.e. addition
  and subtraction "can be performed only on quantities of the same dimension", as
  operations on numerical coefficients within one dimension class; he also notes the
  elements `αA` with non-positive coefficient fall _outside_ the original space `Π`
  (p. 95). Cross-dimension addition is not forbidden by an axiom; the operation simply
  has no definition.
- **CLP — not even expressible.** In the abstract model, `V`'s vector addition _is
  quantity multiplication_ (`Q₁Q₂ ↦ Q₁ + Q₂`, Remark A, p. 124). Quantity addition
  has no counterpart anywhere in the formalism: the theory sees only the
  multiplicative skeleton, and a law's subset `L_e` can encode any relation —
  including additive ones — only pointwise in the value tuples. The π-theorem is
  proved without addition of quantities ever being mentioned.
- **Jonsson — fibers with derivable addition.** Each dimension `C ∈ Q/∼` is a
  one-dimensional vector space over `K` with its own zero `0_C` (p. 3) — addition
  exists within a dimension, never across (the [tensor-of-lines picture][tensor-lines]
  of one line per dimension). Strikingly, his Example 4 (pp. 13–14) then _derives_
  addition from the π-theorem plus symmetry: for combined mass `c^W = Φ(a, b)` the two
  adequate partitions give `c = a·Ψ₁(b/a)` and `c = b·Ψ₂(a/b)`, and commutativity
  `Φ(a,b) = Φ(b,a)` forces the functional equation `Ψ(x) = x·Ψ(x⁻¹)`, whose solutions
  yield `c = k(a + b)`; he generalizes: "if `a, b, Φ(a, b) ∈ X ≠ [1_Q]` and
  `Φ(a, b) = Φ(b, a)` then `Φ(a, b) = k(a + b)`" (p. 14). Within this formalization,
  same-dimension addition is not a primitive to be legislated but a _consequence_ of
  multiplicative covariance plus symmetry — the strongest answer any surveyed source
  gives to "why do quantities multiply freely across dimensions while addition does
  not": multiplication is the structure the covariance group preserves; addition is
  what covariance _leaves room for_ inside a single fiber.

Recorded silence: none of the sources connects the addition question to types or
kinds; the reconciliation with the type-theoretic answers ([Kennedy][kennedy],
[Hart][hart]) is deferred to the [synthesis][comparison].

---

## Expressive power & limits

### What it delivers beyond "reals with attached units"

A checker that merely propagates unit annotations through arithmetic can _reject_
ill-dimensioned expressions; the π-theorem does something no such checker does — it
**extracts the full invariant content of a model before the model is known**:

- **Variable reduction with an exact count.** `n` variables become `n − rank A`
  dimensionless ones — e.g. CLP's Taylor blast-wave example, where
  `g(t, r, ρ₀, E, γ) = 0` collapses to a relation between two `Π`s and yields the
  `r ∝ t^{2/5}` law up to a function of `γ` (CLP p. 118).
- **Similarity and model testing.** Two systems with equal `π`s are "physically
  similar", so scale-model measurements transfer to prototypes (Buckingham §6,
  pp. 353–356; Drobot's principle of similitude, p. 94).
- **Detection of missing variables.** In Jonsson's formulation the machinery can
  _prove_ a proposed variable list inadequate: for the two-body period as a function
  of `M, m, d` alone there is no adequate partition, hence no covariant scalar
  representation exists at all — the gravitational constant `G` _must_ enter
  (Example 6, pp. 15–16). The classical form of this is Bridgman's doctrine of
  dimensional constants (Chapter IV context, pp. 37 ff).
- **Law derivation under symmetry.** With the amended, multi-representation version:
  Kepler's third law with the `(M + m)` dependence, mass addition, and the field-energy
  density `u = k(ǫE² + µH²)` all fall out of covariance plus symmetry alone (Jonsson
  Examples 4–6, pp. 13–16 — the last one sharpening Buckingham's own worked example
  from pp. 358–359 of the 1914 paper).

### What it cannot express

- **Fractional and irrational powers.** Over `ℝ` (CLP, Drobot) arbitrary real
  exponents are legal, so `L^{1/2}` or even `L^{√2}` are unproblematic _as monomials_
  — but then the dimension group is a `ℝ`-vector space, not the free abelian group
  physical practice suggests (see [free-abelian-group][free-abelian] for why `ℤ`
  matters). Buckingham treats fractional exponents as a notational nuisance, noting
  one may replace any `Π` by a power of it "to dispense with fractional exponents"
  (p. 348). Jonsson's integer-only amendment buys uniqueness (the `gcd`-normalized
  tuple) at the price of representing `y₀^{W₀}` instead of `y₀` (§4, pp. 7–8). Since
  any rational `A` has a rational kernel basis, the three conventions agree on every
  _classical_ problem; they differ on which _theory_ of dimensions they commit to.
- **Affine quantities (temperature scales, dates, gauge pressure).** The covariance
  group is purely multiplicative — `S_λ` has no translation component — so a unit
  change like `°C → K` (offset) or a calendar epoch shift is simply not among the
  transformations the theorem quantifies over. A relation involving Celsius
  temperatures can be unit-free in the theorem's sense and still epoch-dependent.
  Buckingham's §7 discussion of temperature (p. 357) is about whether temperature
  needs its _own base unit_ (he insists it does, contra Tolman's temperature-as-energy
  premise); the offset problem is invisible to him. The structure that does capture
  offsets is the [torsor / affine-space view][torsor] — outside this formalization.
- **Logarithmic and "level" quantities (dB, pH, magnitudes).** `log Q` for dimensional
  `Q` is exactly what Buckingham's p. 346 argument rules out of physical equations;
  the formalism admits logarithms only of `Π`s (ratios). dB and pH are therefore
  representable only after choosing a reference quantity to form the ratio — the
  choice itself is extra-theoretic. (Bridgman's monster equation on p. 42, with `sin`
  and `sinh` of dimensional arguments, is a deliberate freak show: legal only because
  the variables satisfy additional relations, i.e. exactly when hypothesis H3 fails.)
- **Angles.** Dimensionless by construction, so the theorem can never constrain how a
  law depends on them: an angle _is already a `Π`_ and survives every reduction intact
  as a bare argument of `ψ` — Jonsson's pendulum Example 2, where `[θ] = [1_Q]` and
  the conclusion is `t² = ℓg⁻¹Ψ(θ)` with `Ψ` unknowable to the method (p. 12);
  likewise Buckingham's radiation example, where the angle `θ` rides along "being
  dimensionless like the r's" (p. 362). Treating angle as a base dimension would
  change `A`'s rank and the count of `π`s — the formalism permits either convention
  and adjudicates nothing (cf. [concepts: angles][concepts]).
- **Same-dimension, different-kind quantities.** Torque vs energy, `Hz` vs `Bq`,
  stress vs pressure: identical columns of `A`, hence fully interchangeable — their
  ratio is certified "dimensionless" and can be handed to `ψ` as a physically
  spurious `Π`. No surveyed source even remarks on the problem; the silence is total.
  (The _number of base dimensions_ — which determines what gets conflated — is itself
  conventional: Buckingham's `k` varies per problem, p. 358, and Drobot's "paradoxical"
  heat-conduction example turns on taking temperature (the degree) as a fourth
  independent unit, p. 95.
  See [Open problems](#open-problems--frontier).)
- **Vector and tensor quantities.** The `Qᵢ` are scalars; direction-dependent laws
  must be scalarized first. The systematic extension of dimension bookkeeping to
  matrices and tensors is [Hart's multidimensional analysis][hart].

---

## Mechanization

The theorem's computational content is small and completely decidable: given `A` over
`ℚ`, compute `r = rank A` and a basis of `ker A` — Gaussian elimination, `O(d·n·min(d,n))`
field operations, with an integer (Hermite/Smith-style) basis obtainable in polynomial
time. Both halves of that sentence are realized in the pinned artifacts of this survey:

- **[`pint`][pint] ships the theorem as a library function.** `pint.pi_theorem`
  (`pint/util.py`, line 226 at the pinned SHA; re-exported as
  `UnitRegistry.pi_theorem`, `pint/registry.py` line 464) takes a `dict` of variables
  with units, "Builds dimensionless quantities using the Buckingham π theorem": it
  assembles the dimensionality matrix, runs `column_echelon_form` over exact
  `Fraction` arithmetic — the null space over `ℚ`, literally — then reads off the
  zero rows' companion vectors, clears denominators to integer exponents, and flips
  signs to "minimize the number of negative exponents". The classical pipeline
  (Step 0–1 of the proof sketch), industrialized.
- **[`LeanDimensionalAnalysis`][lean] formalizes the linear-algebra half.** In
  `DimensionalAnalysis/Basic.lean` (pinned SHA `de263ee`), after proving
  `CommGroup (dimension B E)` (line 234), a `Buckingham-Pi Theorem` section defines
  `dimensional_matrix` (a `Matrix (Fin (Fintype.card B)) (Fin n) E` of exponents),
  `number_of_dimensionless_parameters := n - Matrix.rank (dimensional_matrix d perm)`,
  and `dimensionless_numbers_matrix := LinearMap.ker (Matrix.toLin' (dimensional_matrix d perm))`
  — the rank–nullity reading verbatim. Honest negative finding: these are
  _definitions only_ — the analytic half (existence of the reduced `ψ` from a
  covariance premise, CLP Lemma 2 / Jonsson Theorem 1) is **not** stated or proved
  anywhere in the repository; the section ends after the three `def`s. A parallel
  section exists in `Basic_Multiplicative.lean` (line 270). The companion paper is
  Bobbin & al. 2025 (`bobbin-2025-formalizing-dimensional-analysis-lean-arxiv.pdf`);
  see the [Lean system page][lean] for the full assessment.
- **The same elimination, running inside type checkers.** Deciding whether a proposed
  `Π` is dimensionless, completing a set of `Π`s, and normalizing unit expressions
  are all instances of linear algebra over the exponent lattice — precisely the
  computation that [Kennedy-style dimension types][kennedy] perform during
  _unification_ (Gaussian elimination over `ℤ`, i.e. abelian-group unification) in
  [F#'s `UnifyMeasures`/`SimplifyMeasuresInType`][fsharp] and the
  [`uom-plugin`][uom-plugin]'s GHC constraint solver. The π-theorem is, in that
  precise sense, the _semantic theorem behind the syntactic type systems_: `n − r` is
  the number of free unit variables a principal type will exhibit. The survey's
  [type-system mechanisms page][mechanisms] develops this correspondence.
- **Algorithmics in the sources themselves.** CLP §2 is expressly packaged as "an
  algorithm which is an effective procedure" with a worked example (p. 119); Jonsson
  closes by observing his amended method — enumerate adequate partitions, extract the
  unique normalized integer tuples per partition — is mechanical: "We have described
  rules that make it possible to generate unique equation systems from a dimensional
  matrix … It would not be difficult to create a computer implementation of this
  algorithm" (p. 17). No implementation of the _amended_ (multi-representation)
  analysis exists among this survey's pinned systems — a genuine gap.

---

## Open problems & frontier

- **The single-ψ blind spot.** Jonsson's central charge is that a century of practice
  reduces a problem to _one_ representation and stops, discarding the information in
  the other adequate partitions: "Remarkably, the same restricted way of thinking
  still dominates dimensional analysis, next to a century after the appearance of
  Bridgman's classic, but mathematics does not always move quickly" (p. 16). How much
  of classical modeling folklore (which `Π`s to prefer, when a reduction is "the"
  reduction) is recoverable as theorems about representation _systems_ is open — his
  two-body and field-energy examples are existence proofs that the gain is real.
- **The covariance premise is physics, not mathematics.** The amended theorem makes
  the premise exact but not free: _"This assumption, underlying dimensional analysis,
  is a general covariance principle about the equivalence of certain reference frames,
  defined by corresponding systems of units of measurement."_ — Jonsson, §7 ("Ex
  nihilo nihil fit"), p. 16. When a given physical relationship _admits_ a covariant
  quantity-function model — and what stronger symmetry assumptions (his Mach's-
  principle aside, pp. 16–17) are legitimate — is exactly the part no algebra decides.
  Bridgman's dimensional constants (make any adequate equation complete by adjoining
  enough constants, p. 37) shift the question rather than answer it: _which_ constants
  belong in the variable list (H1) remains extra-mathematical, though Jonsson-style
  non-existence arguments can sometimes refute a list (Example 6).
- **Choice of the dimension system changes the answer.** The rank `r` — hence the
  strength of the reduction — depends on how many base dimensions the modeler
  recognizes: Buckingham's `k` drops from 4 to 3 within one worked problem (p. 358),
  and Drobot's §VII opens with the classically "paradoxical" examples in which
  treating heat (or temperature) as an extra independent unit yields a _sharper_
  π-reduction whose validity is a physical judgement (heat-ball example, p. 95; the
  phenomenon circulates in the literature under Riabouchinsky's name `[unverified
eponym — not groundable in the local artifacts]`). Jonsson's account of basis
  changes shows what invariance one _does_ have — his capacitor Example 3 re-derives
  identical representations under a `{L,T,M,I} → {L,F,Q,X}` basis change (pp. 12–13)
  — and where it stops: "in physics a change of units is often associated with a
  change of quantity space, affecting dependencies among dimensions and quantities"
  (p. 11). A principled theory of _which_ dimension system a problem warrants is
  still missing; it is the same open question as the kind-blindness above (torque vs
  energy), since finer kinds are finer dimension systems — the survey returns to it in
  the [synthesis][comparison].
- **Exponent domain.** `ℤ` vs `ℚ` vs `ℝ` remains genuinely unsettled as a matter of
  _foundation_ (Jonsson p. 1 catalogs the disagreement), even though all agree on
  classical computations. The choice decides whether dimensions form a free abelian
  group, a `ℚ`-vector space, or an `ℝ`-vector space — with consequences for
  uniqueness of the `Π`s, for [torsor structure][torsor], and for what a type system
  must implement ([Kennedy][kennedy] chose `ℤ`; some C++ libraries expose `ℚ`).
- **Negative, zero, and non-real quantities.** Classical positivity (H4) excludes
  signed quantities from the theorem's scope; Jonsson's field-agnostic version covers
  them but at the cost of the `y₀^{W₀}` reformulation and non-ordered fields' loss of
  the root extraction step (his pendulum example must re-assume `t, ℓ, g > 0` to take
  the square root, p. 12). A formulation that is simultaneously sign-friendly and
  root-friendly does not yet exist.
- **From π-theorem to symmetry analysis.** CLP flag the continuation: the `Π`s are
  the invariants of a particular abelian group action, and "dimensionless groups"
  feed the Lie-group similarity methods for PDEs (their nod to Bluman & Cole, p. 118).
  The modern frontier — relating unit covariance to parametricity and conservation
  laws — runs through [Kennedy's relational-parametricity results][kennedy] and
  Atkey's work, covered on the [type-system mechanisms page][mechanisms].

---

## Sources

- E. Buckingham, ["On Physically Similar Systems; Illustrations of the Use of
  Dimensional Equations"][buckingham-hal], _Physical Review_ 4(4):345–376, 1914 —
  origin of the name: "complete equations", the sum-of-monomials form (3), `i = n − k`
  (pp. 347–348), the propeller and electromagnetic examples, physically similar
  systems (§6), the Tolman rebuttal (§7). Local artifact:
  `buckingham-1914-similar-systems-physrev.pdf` (quotes transcribed against the noisy
  OCR of the HAL scan).
- P. W. Bridgman, [_Dimensional Analysis_][bridgman-archive], Yale University Press,
  1922 — the canonical exposition: absolute significance of relative magnitude and the
  power-law theorem (pp. 18–23), "complete equation" (p. 37), the differentiation
  proof of the Π theorem (pp. 38–41), the tacit single-relation restriction and the
  inhomogeneous counterexample (pp. 41–42), the rank caveats (pp. 43–44). Local
  artifact: `bridgman-1922-dimensional-analysis-book.pdf` (OCR scan).
- S. Drobot, ["On the foundations of dimensional analysis"][drobot-doi], _Studia
  Mathematica_ 14:84–99, 1953 — first rigorous algebraic foundation: multiplicative
  linear spaces (§III), invariance and homogeneity as independent axioms with
  counterexamples (§IV), dimensions as equivalence classes (§VI), fiberwise addition
  (§VI.4), the "paradoxical" examples (§VII). Local artifact:
  `drobot-1953-foundations-dimensional-analysis-studia.pdf` (image-only scan — cited
  structurally; two short phrases transcribed from the page images).
- W. D. Curtis, J. D. Logan & W. A. Parker, ["Dimensional Analysis and the Pi
  Theorem"][clp-doi], _Linear Algebra and its Applications_ 47:117–126, 1982 — the
  rigorous statement and proof this page follows: dimension matrix and `Aα = 0`
  (p. 120), unit-free laws (Definition 2, p. 121), Lemmas 1–2 (pp. 121–122), the
  abstract frame-equivariant theorem (§3, pp. 124–125), and the Vaschy/Buckingham
  history (p. 118). Local artifact: `curtis-logan-parker-1982-pi-theorem-laa.pdf`.
- D. Jonsson, ["An Algebraic Foundation of Amended Dimensional
  Analysis"][jonsson-arxiv], arXiv:2010.15769v2, 2020 — the amended theorem on
  quantity spaces: covariant scalar representations, Theorem 1 and its proof
  (pp. 4–6), integer-exponent normalization (§4), dimensional matrices (§5),
  the multi-representation examples (§6), and the covariance-premise discussion (§7).
  Local artifact: `jonsson-2020-algebraic-foundation-dimensional-analysis-arxiv.pdf`.
- Mechanizations inspected: [`pint`][pint] (`pint/util.py` L226, `pint/registry.py`
  L464 at SHA `7a927b4`) and [`LeanDimensionalAnalysis`][lean]
  (`DimensionalAnalysis/Basic.lean` L234/L259 ff, `Basic_Multiplicative.lean` L270 at
  SHA `de263ee`).
- Related deep-dives: [theory index][theory-index] · [umbrella][umbrella] ·
  [concepts][concepts] · [free abelian dimension groups][free-abelian] ·
  [Whitney][whitney] · [tensor of lines][tensor-lines] · [torsors][torsor] ·
  [Kennedy types][kennedy] · [Hart][hart] · [type-system mechanisms][mechanisms] ·
  [comparison][comparison].

<!-- References -->

<!-- Same-tree theory siblings -->

[theory-index]: ./index.md
[whitney]: ./whitney.md
[free-abelian]: ./free-abelian-group.md
[tensor-lines]: ./tensor-of-lines.md
[torsor]: ./torsor-representation.md
[kennedy]: ./kennedy-types.md
[hart]: ./hart-multidimensional.md
[mechanisms]: ./type-system-mechanisms.md

<!-- Tree umbrella / concepts / comparison -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md

<!-- System pages -->

[pint]: ../python-pint.md
[lean]: ../lean-mathlib-units.md
[fsharp]: ../fsharp-uom.md
[uom-plugin]: ../haskell-uom-plugin.md

<!-- External primary sources -->

[buckingham-hal]: https://hal.science/hal-03623703
[bridgman-archive]: https://archive.org/details/dimensionalanaly00bridrich
[drobot-doi]: https://doi.org/10.4064/sm-14-1-84-99
[clp-doi]: https://doi.org/10.1016/0024-3795(82)90229-4
[jonsson-arxiv]: https://arxiv.org/abs/2010.15769
