# Hart's Multidimensional Analysis (Dimensioned Linear Algebra)

George W. Hart's _Multidimensional Analysis: Algebras and Systems for Science and
Engineering_ (Springer 1995) is the survey's only formalization that takes the step every
other one stops short of: it asks what happens to **linear algebra** — not just scalar
arithmetic — when the entries of vectors and matrices are dimensioned quantities. The
answer is a demolition and a reconstruction. Because dimensioned scalars multiply freely
but add only within a dimension, a matrix product `[AB]ᵢⱼ = Σₖ AᵢₖBₖⱼ` contains scalar
sums, and those sums are only _sometimes_ defined — so "any square matrix can be squared"
fails, most arrays have no determinant, no eigenvalues, and no exponential, `Aᵀ` stops
being the adjoint, and the SVD survives only on the single class ("uniform") where all
entries share one dimension. Hart's central structural result is that every matrix that
can participate in _any_ product has a dimensional form that factors as an outer product
`yx̃` — matrices are "dimensionally of rank 1" — and the familiar operations reappear one
by one as that form specializes. The scalar foundation is his **typed family of fields
(`TFF`)**: pairs `(f, g)` of a field element and a group element, with total
multiplication and partial addition.

> [!NOTE]
> **Provenance discipline is part of this page's content.** The 1995 book is paywalled;
> its body was **not inspected**. Three local artifacts ground this page: Hart's own
> 5-page 1994 SIAM proceedings paper ["The Theory of Dimensioned Matrices"][siam-ps]
> (`hart-1994-dimensioned-matrices-siam.pdf` — **full text, the quotable primary**; it
> states every definition and theorem used below), the Springer **front matter/TOC**
> (`hart-1995-multidimensional-analysis-frontmatter-springer.pdf` — used _only_ for the
> book's bibliographic identity and chapter structure; the scan is OCR-noisy), and Hart's
> own [book web page][hart-site] (`hart-1995-multidimensional-analysis-website.html`).
> Claims are tagged **(book, TOC-level)** when a chapter/section _title_ is the only
> local evidence and the underlying content is unverifiable here. Equations `(1)`–`(26)`
> and Theorems 3.1–3.5 refer to the SIAM paper's own numbering; the 2×2 matrices and the
> `∼`/`≈`/`x̃` notation were verified against page renders of the PDF (its text layer
> drops ligatures and math glyphs).

---

## At a glance

| Dimension                | Hart's multidimensional analysis                                                                                                                                                                                                      |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Primary structure        | The **typed family of fields** `TFF = F × G` (field `F`, group `G` of "types"): total multiplication `(f₁,g₁)(f₂,g₂) = (f₁f₂, g₁g₂)`, addition defined **only** when `g₁ = g₂` (eqs. `(3)`, `(4)`)                                    |
| Quantity                 | A **dimensioned scalar** — an ordered pair `(f, g)`; `f` the numeric component, `g` its **type**, extracted by the type function `T((f, g)) = g`                                                                                      |
| Dimension                | The group element `g ∈ G`; "usually `g` is taken as a vector of exponents on fundamental units" (§1) — but the definitions require only _a group_, not a free abelian one (`G` may even be non-abelian)                               |
| Unit                     | **Not a formal object in the SIAM paper** (units appear only as notation: "`m` abbreviates meters"); the book has §6.2.6 "Output and Units Conversion" and §1.2.6 "The Basis-Independence Principle" (book, TOC-level)                |
| Kind                     | Absent — `g` is a quantity's entire dimensional identity (torque ≡ energy)                                                                                                                                                            |
| Vectors / matrices       | Arrays of dimensioned scalars; classified by **dimensional similarity** `A ∼ B` (same type entrywise) and **parallelism** `A ≈ B` (`∃c, A ∼ cB`); key tool: the **dimensional inverse** `Ã` with `T([Ã]ᵢⱼ) = (T([A]ⱼᵢ))⁻¹`            |
| Central theorem          | Thm 3.1: `A` can appear in at least one product `⟺` `∃x, y` with `A ∼ yx̃` — dimensional forms of usable matrices are **outer products** ("dimensionally of rank 1"); a transformation from an `x`-space to a `y`-space _is_ `∼ yx̃`    |
| Class tower              | dimensionless `⊂` endomorphic (`xx̃`, `e^A` defined) `⊂` squarable (`cxx̃`, eigenstructure) `⊂` has determinant/inverse `⊂` multipliable (`yx̃`) `⊂` arbitrary arrays — each inclusion proper (website §D)                               |
| Broken classical facts   | `Aᵀ` is not the adjoint (`Ã` is); `AA⁻¹ = A⁻¹A ⟺ A` uniform; symmetric (`xxᵀ`) matrices generally have **no eigenstructure**; `Uᵀ = U⁻¹ ⟹ U` dimensionless; SVD exists `⟹ A` uniform (results `(20)`–`(26)`)                          |
| Cross-dimension addition | **Undefined by definition `(4)`** — no error value, no formal sum; every "surprising" matrix theorem is this one partiality propagated through `Σₖ AᵢₖBₖⱼ`; mixed-dimension data lives in _tuples_ (dimensioned vectors), never sums  |
| Mechanization            | Hart's `DimCalc` (public-domain Windows program, **scalars only**); book ch. 6 designs a dimensioned-linear-algebra environment (domain/range representation) (book, TOC-level); **no mainstream units library implements any of it** |
| Provenance               | SIAM paper inspected in full (5 pp.); book grounded via front matter TOC + Hart's web page only; frontier reading via Zapata-Carratalá 2021 (inspected)                                                                               |

The scalar substrate Hart builds on is the classical quantity calculus that the
[free-abelian-group page][fag] and [Whitney's quantity structures][whitney] formalize —
his own reference list spans Brand, Drobot, Quade, Kurth, Krantz–Luce–Suppes–Tversky, and
Whitney (`[1]`–`[9]` of the SIAM paper). What is new is everything above the scalars. The
[comparison capstone][comparison] records that none of the surveyed systems mechanizes
this layer.

---

## Primary sources

- **G. W. Hart, ["The Theory of Dimensioned Matrices"][siam-ps], _Proceedings of the 5th
  SIAM Conference on Applied Linear Algebra_, Snowbird, Utah, June 1994, pp. 186–190.**
  _Inspected — full text_ (local:
  `hart-1994-dimensioned-matrices-siam.pdf`, 5 pp.; the venue and page range are as Hart
  cites it on his own web page, which also hosts the [PostScript][siam-ps]). Defines the
  `TFF`, dimensioned matrices, similarity/parallelism/dimensional inverse, and states
  Theorems 3.1–3.5 plus results `(11)`–`(26)`. All formal content on this page is
  grounded here. The paper cites the book as reference `[3]`, "to be published by
  Springer Verlag, (1994)" — it actually appeared in 1995.
- **G. W. Hart, [_Multidimensional Analysis: Algebras and Systems for Science and
  Engineering_][book-doi], Springer-Verlag New York, 1995. ISBN 0-387-94417-6 (hardcover);
  the local scan is the softcover reprint (ISBN-13 978-1-4612-8697-4,
  e-ISBN 978-1-4612-4208-6, DOI `10.1007/978-1-4612-4208-6`).**
  _Not inspected beyond the front matter._ The local artifact
  (`hart-1995-multidimensional-analysis-frontmatter-springer.pdf`) is the title pages +
  full table of contents + list of figures/tables; every book-structure claim below cites
  a TOC entry and is marked (book, TOC-level). Per the SIAM paper, the book carries the
  proofs, "additional classes, details, and analysis" the 5-page version omits.
- **G. W. Hart, ["Multidimensional Analysis" (book web page)][hart-site]** (local:
  `hart-1995-multidimensional-analysis-website.html`). _Inspected._ Hart's own summary:
  the motivating `X`, `Y`, `Z` examples, a "pop quiz", six "surprising theorems"
  (including the proper-inclusion tower), the `DimCalc` download, and the Math Reviews
  blurb _"thoroughly recommended to those who really wish to understand the theory of
  dimensions"_.
- **C. Zapata-Carratalá, ["Dimensioned Algebra: the mathematics of physical
  quantities"][zapata], arXiv:2108.08703, 2021** (local:
  `zapata-carratala-2021-dimensioned-algebra-arxiv.pdf`). _Inspected._ The modern
  categorical generalization (dimensioned sets, rings, fields, modules); credits Hart
  with "the first efforts in developing a general mathematical theory of physical
  quantities" (§1). Used for [Open problems & frontier](#open-problems--frontier).
- Hart's own scalar-level bibliography — Brand 1957, Drobot 1954, Kasprzak–Lysik–Rybaczuk
  1990, Krantz et al. 1971, Kurth 1965, Quade 1967, Thun 1960, Whitney 1968 (SIAM paper
  refs `[1]`–`[9]`) — is cited here from that reference list, **not inspected** for this
  page [unverified], except where a source has its own page in this tree
  ([Whitney][whitney], [Drobot via the Π-theorem page][pi]).

---

## Formal core

### The typed family of fields

The scalar layer (SIAM paper §2). A **typed family of fields (`TFF`)** over a field `F`
and a group `G` is the Cartesian product `F × G` with two operations. Writing a typical
element `(f, g)` — `g` is its **type**, extracted by the type function `T((f, g)) = g` —
multiplication is total:

```text
(3)    (f₁, g₁)(f₂, g₂) = (f₁f₂, g₁g₂)         f₁f₂ in F,  g₁g₂ the group operation in G
```

and addition is partial, the load-bearing definition of the whole theory:

```text
(4)    (f₁, g₁) + (f₂, g₂) = (f₁ + f₂, g₁)     if g₁ = g₂
                           = undefined          otherwise
```

> _"The TFF has elements which are ordered pairs, `(f, g)`, `f ∈ F`, `g ∈ G`, where `F`
> is a field and `G` is a group of “types.” Operations are defined so that the TFF is
> closed under multiplication, but not addition."_
> — Hart, _The Theory of Dimensioned Matrices_, abstract
> (`hart-1994-dimensioned-matrices-siam.pdf`, p. 1)

An element `c` is **dimensionless** iff `T(c) = 1` (the identity of `G`). A **zero** is
any `(0, g)` — note the plural: `(0, g)` is _"a unique additive identity element for all
elements of type `g`"_ (§2), i.e. one zero **per type**, while `(1, 1)` is the unique
multiplicative identity for the entire `TFF`. The `TFF` satisfies the commutative,
associative, and distributive field axioms _"whenever the sums are defined, except that
multiplication is only commutative if `G` is Abelian"_ (§2) — the definition genuinely
permits a non-abelian type group, a generality no other formalization in this survey even
states. Elements of the `TFF` are called **dimensioned scalars**; the intended model has
`F = ℝ` and `G` the exponent group of the [free-abelian-group picture][fag]: "usually `g`
is taken as a vector of exponents on fundamental units of length, mass, time, charge,
etc., and the group operation is vector addition of these exponents" (§1, crediting
refs `[1]`–`[9]`).

### Dimensioned matrices, similarity, parallelism, and the dimensional inverse

An `n × m` **dimensioned matrix (`DM`)** is an array of dimensioned scalars; a
**dimensioned vector** is an `n × 1` `DM`; a matrix is **uniform** iff all its entries
have one type (`∀i, j: T(Aᵢⱼ) = T(A₁,₁)`) and **dimensionless** iff all entries are.
Matrix sum `(5)` and product `(6)` are defined entrywise/by `Σₖ AᵢₖBₖⱼ` in the usual way
— _"except that the sum is undefined if any of the `nm` scalar sums are undefined"_ (and
likewise for the product). Nothing else is changed; the entire theory is the shadow that
one partiality casts.

Three relations organize the classification (§2):

```text
(8)    A ∼ B   ⟺   ∀i, j:  T(Aᵢⱼ) = T(Bᵢⱼ)          dimensional similarity
(9)    A ≈ B   ⟺   ∃c:     A ∼ cB                    dimensional parallelism (weaker)
(10)   T([Ã]ᵢⱼ) = (T([A]ⱼᵢ))⁻¹                        Ã = a dimensional inverse of A
```

`∼` compares full dimensional forms; `≈` compares them up to a single (possibly
dimensioned) scalar `c`, so `A ∼ B ⇒ A ≈ B`. The **dimensional inverse** `Ã` is any
`m × n` matrix obtained by transposing `A` and inverting every entry's type _in `G`_ —
_"no constraints are placed on the `F` components"_, so `Ã` only ever appears inside `∼`
or `≈` relations, never equalities. It is the theory's pivotal gadget: dimensional
structure has its own inverse, distinct from both the numeric inverse `A⁻¹` and the
transpose `Aᵀ`.

For a dimensioned vector `x`, the **complete dimensioned vector space (`CDVS`)** of type
`x` is `{y : y ∼ x}`; a **dimensioned vector space (`DVS`, an "`x`-space")** is a subset
of a `CDVS` closed under addition and multiplication by _dimensionless_ scalars. An
`x`-space is the fixed-heterogeneity habitat for mixed-dimension state vectors — the
abstract's "multidimensional signals or states", e.g. a state holding a position _and_ a
velocity. The basic identities follow mechanically from `(3)`–`(10)` (§3.1 — "if an
operation is undefined, that is because it entails a scalar sum of different types"):

```text
(11)   (Ã)˜ ∼ A                        (12)   (Ã)ᵀ ∼ (Aᵀ)˜
(13)   (AB)˜ ∼ B̃Ã                     (14)   [xyᵀ]ᵢⱼ ∼ xᵢyⱼ         outer: always defined
(15)   [xỹ]ᵢⱼ ∼ xᵢ/yⱼ                  (16)   x̃x always defined, T(x̃x) = 1
(17)   xᵀx defined  ⟺  x uniform      (18)   x̃y defined  ⟺  x ≈ y
(19)   xᵀy defined  ⟺  x ≈ ỹᵀ
```

Outer products `(14)`, `(15)` never sum, so they always exist. Inner products
`(16)`–`(19)` do sum, so they exist only in special positions — and `(17)` already kills
a sacred cow: `xᵀx`, hence a norm or magnitude, exists **only for uniform vectors**, so
_"familiar derivations involving magnitudes are not general to all `x`-spaces"_ (§3.1).
The one inner product that always works is `x̃x` — the dimensional inverse cancels every
type, leaving a dimensionless `1×1` result.

### Central theorem: usable matrices are dimensionally of rank 1

**Theorem 3.1 (SIAM paper §3.2).** `A` can appear in at least one defined product
`⟺ ∃x, y` such that `A ∼ yx̃`.

Unpacked via `(15)`: a multipliable `n × m` matrix has `T(Aᵢⱼ) = T(yᵢ)/T(xⱼ)` — the
`n × m` array of types, an apparently `n·m`-parameter object, is determined by an
**outer product** of two type vectors. Hart's phrase is that useful matrices are
_dimensionally of rank 1_.

_Proof sketch (the paper's own for the forward direction, §3.2; the converse is
immediate)._ Suppose `Ax` is defined. Then an inner product
is defined between each row of `A` (transposed into a column) and `x`; by `(19)` each
row is `≈ x̃ᵀ`, and by transitivity of `≈` **all rows of `A` are dimensionally parallel
to each other**. So the dimensional form of `A` factors as a column of scalars
`(1, c₂, …, cₙ)ᵀ` times its first row — an outer product — and consequently all columns
are dimensionally parallel too. A dual argument covers products `xᵀA`, and the
matrix-matrix case reduces to the same factorization. Writing the row-type vector as
`x̃` and the column-scale vector as `y` gives `A ∼ yx̃`. For the converse, a matrix of
form `yx̃` visibly multiplies onto any vector `∼ x` (each entrywise sum is
same-typed). `∎`

The example matrix `X` below is a square array that violates the condition — it "can
enter into no products and can not be factored as `X ∼ yx̃`" — so it is not merely
singular but **not a matrix in any operational sense**. Two corollaries close the
section:

- **Theorem 3.2.** The matrix of a linear transformation from an `x`-space to a
  `y`-space has the form `yx̃`. (Proof: if `A ∼ yx̃` then
  `Ax ∼ (yx̃)x ∼ y(x̃x) ∼ y` by `(16)` and associativity — the inner `x̃x` is
  dimensionless and vanishes from the form.)
- **The adjoint is `Ã`, not `Aᵀ`.** The reverse mapping of `A ∼ yx̃` is provided by
  `Ã ∼ xỹ` — the dimensional inverse, not the transpose, carries a `y`-space back to an
  `x`-space. `Aᵀ ∼ x̃ᵀyᵀ` maps between the _dual-typed_ spaces instead.

### The class tower: endomorphic, squarable, eigenstructure, determinant, SVD

Specializing `yx̃` produces the operations one at a time (§§3.3–3.5):

- **Endomorphic** (`A ∼ xx̃`): maps an `x`-space to itself. Since
  `(xx̃)(xx̃) ∼ x(x̃x)x̃ ∼ xx̃`, powers preserve the dimensional form, so polynomials
  and Taylor series make sense. **Theorem 3.3:**
  `∃x, A ∼ xx̃ ⟺ Aⁿ ∼ A ⟺ e^A is defined`. By `(15)` the diagonal of an endomorphic
  matrix is dimensionless — which contains, as the `1 × 1` case, the folklore rule that
  _"a scalar argument to a transcendental function must be dimensionless"_ (§3.3).
  Identity matrices are endomorphic, and there are **many distinct `n × n` identity
  matrices** — same numeric entries, different off-diagonal zero types — but fewer than
  there are spaces, since `x ≈ y ⇒ xx̃ ∼ yỹ`.
- **Squarable** (`A ∼ cxx̃`): **Theorem 3.4:** `A²` is defined `⟺ ∃c, x` with
  `A ∼ cxx̃`; then `A² ∼ c²xx̃ ∼ cA` — squaring exists but _scales the dimensional
  form by `c`_, so `A + A²` needs `c` dimensionless (i.e. endomorphic `A`).
- **Eigenstructure:** defining `Ax = λx` as usual, Theorem 3.2 forces `A ∼ λxx̃`.
  **Theorem 3.5:** `A` has eigenstructure **iff** `A` is squarable, and for
  `A ∼ cxx̃`: every eigenvalue `λ ∼ c` and every eigenvector `y ≈ x`. Eigenvalues of a
  physically meaningful matrix all carry _the same dimension_, the squarability scale
  `c` — and _"most square matrices are not squarable and so have no eigenstructure"_
  (§3.4). In particular symmetric matrices, whose form is `xxᵀ`, are generally **not**
  squarable, _"so the analysis of positive definite matrices in terms of eigenstructure
  is not generally meaningful"_.
- **Additional results** (§3.5, stated without proof, referred to the book):

```text
(20)   A ∼ yx̃ is n×n      ⟹   det(A) is defined and det(A) ∼ ∏ᵢ yᵢ/xᵢ
(21)   A ∼ yx̃ nonsingular ⟹   A⁻¹ ∼ Ã ∼ xỹ
(22)   xᵀAx defined        ⟺   A ≈ x̃ᵀx̃
(23)   AA⁻¹ = A⁻¹A         ⟺   A is uniform
(24)   A ∼ cxx̃ and A ∼ Aᵀ ⟹   A is uniform
(25)   Uᵀ = U⁻¹            ⟹   U is dimensionless
(26)   A = UΣVᵀ is a SVD   ⟹   A is uniform
```

`(20)` makes the determinant a _dimensioned_ scalar of type `∏ T(yᵢ)/T(xᵢ)` — defined
for every multipliable square matrix because each of the `n!` expansion terms picks one
entry per row and column, hence has that same type. `(24)`–`(26)` demolish the
orthogonal/spectral toolkit off the uniform class: dimensional symmetry plus
squarability forces uniformity, orthogonality forces dimensionlessness, and therefore
the singular value decomposition — built from two orthogonal factors — _"can only give
a uniform matrix"_ (§3.5). Hart's website adds the proper-inclusion **tower** over
square arrays: dimensionless `⊂` exponential-admitting (endomorphic) `⊂` eigenstructure
(squarable) `⊂` determinant/inverse `⊂` multipliable `⊂` all arrays (website §D.4).

---

## Structural anatomy

### What structure is primary; objects and morphisms

The primary structure is the **`TFF` `F × G`** — a two-sorted algebra with a total
product and a type-guarded partial sum — and, over it, the hierarchy of dimensioned
vectors, `x`-spaces, and dimensioned matrices. The working objects are the `CDVS`/`DVS`
(fixed heterogeneous type profile, closed under `+` and dimensionless scaling); the
morphisms between an `x`-space and a `y`-space are exactly the matrices of dimensional
form `yx̃` (Theorem 3.2), composing by `(13)`-compatible matrix product, with `Ã` as
the adjoint-like dual. Equivalences `∼` and `≈` quotient matrices into the classes that
carry the theory. There is no category-theoretic packaging in the primary sources —
Hart works concretely, in arrays — but the data is manifestly that of a category of
finite products of `TFF` "lines" with dimension-respecting linear maps; that reading is
[Zapata-Carratalá's later move](#open-problems--frontier), not Hart's own.

### What is a quantity, a unit, a dimension, a kind

- **Quantity** — a dimensioned scalar `(f, g) ∈ F × G`: the numeric component and the
  type, nothing else. Note what this presupposes: writing a quantity as a _bare pair_
  globally identifies each dimension's fiber with `F`, i.e. the construction has
  implicitly already chosen a unit for every dimension. The [torsor][torsor] and
  [tensor-of-lines][tensor-of-lines] pages exist precisely to avoid that identification;
  Hart's `TFF` is their picture _after_ trivialization.
- **Unit** — **not a formal object of the theory** (a recorded silence). In the SIAM
  paper units occur only as notation for types ("where `m` abbreviates meters, and `s`,
  seconds"). The book's TOC indicates the engineering layer lives in chapter 6 —
  §6.2.5 "Input String Conversion", §6.2.6 "Output and Units Conversion" — and that
  chapter 1 discusses "The Dimensional Basis" (§1.2.4) and "The Basis-Independence
  Principle" (§1.2.6) (book, TOC-level).
- **Dimension** — the type `g ∈ G`, with `T` projecting it out. `G` is any group;
  the free-abelian exponent lattice is the _usual_ instance, not an axiom.
- **Kind** — absent. As in every group-of-exponents formalization, equal dimension means
  equal type: torque and energy, `Hz` and `Bq`, are indistinguishable. Nothing in the
  definitions _forbids_ a richer `G` (the axioms never require freeness or even
  commutativity), but the paper never exploits that slack. Kind mechanisms in this survey
  live a level up, in systems like [`mp-units`' `quantity_spec` hierarchy][cpp-mp-units]
  (see the [concepts glossary][concepts]).

### How is dimensional homogeneity expressed?

At the scalar level Hart simply inherits the classical statement — _"all physically
meaningful scalar calculations can be explicitly carried out with dimensioned quantities
in such a way that all equations and all sums are dimensionally homogeneous"_ (§1, citing
his refs `[1]`–`[9]`). His contribution is homogeneity **one level up**: a matrix
equation is meaningful iff every scalar sum it entails is same-typed, and that condition
is not checked equation-by-equation but **classified once and for all** — homogeneity of
`AB`, `A + B`, `A²`, `det A`, `e^A`, `Ax = λx` becomes membership of `A` (and `B`) in the
multipliable / similar / squarable / endomorphic classes. Homogeneity of a linear _law_
`y = Ax` is Theorem 3.2: the law is dimensionally consistent iff `A ∼ yx̃`, i.e. iff the
matrix's dimensional form is the outer product of the output and inverse-input type
vectors. This is the [Π-theorem][pi] worldview transplanted to operators: the shape of
the law is dictated by the dimensional bookkeeping before any numbers are known.

### What acts as a change of units, and what is invariant?

The SIAM paper contains **no explicit change-of-units map** (a second recorded silence —
the 5 pages classify structure at fixed types; the book's §1.2.6 "Basis-Independence
Principle" and §6.2.6 are the advertised home of that story, book, TOC-level). What the
paper does have is the invariance _vocabulary_: every theorem is stated up to `∼` (which
forgets numeric components entirely) or `≈` (which additionally forgets one global
dimensioned scale). Since a change of units multiplies each entry's numeric part by a
positive factor depending only on its type, both relations — and therefore every class
membership above (multipliable, endomorphic, squarable, uniform, dimensionless) — are
unit-invariant statements; so are definedness facts like "`X²` does not exist", and the
dimensional forms `yx̃`, `T(det A)`, `T(λ)`. What is _not_ invariant is exactly what the
relations quotient away: the `F`-components. Compare [Kennedy's semantics][kennedy-types],
where the same division of labour is enforced by scaling-invariance of typed programs
rather than by equivalence classes of arrays.

### How is addition across quantities of different dimension treated?

**Undefined — by definition, not by error.** Definition `(4)` gives cross-type sums no
value, no error element, no formal-sum completion: the operation's domain simply excludes
them (`"undefined, otherwise"`). Hart never repairs scalar addition; instead the whole
theory is a systematic account of _which composite operations inherit the partiality_.
Matrix product entails scalar sums; therefore squaring, determinants, inverses,
eigenstructure, exponentials each exist exactly on the class where the entailed sums are
same-typed. The paper's closing paragraph is the sharpest statement of the "why" —
operational and physical, not proof-theoretic:

> _"Different classes of dimensioned matrices have different operations defined upon
> them. Attempting to apply operations to classes for which the operation is not defined
> entails adding scalars of different types, which is a physically meaningless numeric
> manipulation."_
> — Hart, _The Theory of Dimensioned Matrices_, §4 Conclusions
> (`hart-1994-dimensioned-matrices-siam.pdf`, p. 5)

Two refinements distinguish Hart's answer from the scalar-only formalizations:

1. **Aggregation without addition.** Mixed-dimension data is not merely tolerated but
   central: a dimensioned vector _is_ an ordered collection of differently-typed scalars
   (a point of the product of fibers `F_g₁ × ⋯ × F_gₙ`), and `x`-spaces make such
   collections into vector spaces over the dimensionless subfield. Heterogeneity is
   legitimate as **juxtaposition** (tupling), never as summation — vector addition is
   defined only _within_ a `CDVS` (`y ∼ x`), where it is componentwise same-type
   addition. So where [Kennedy][kennedy-types] forbids `m + s` by typing and
   [Jonsson][fag] leaves it outside the signature, Hart shows how far a theory can go
   while _keeping_ the ban absolute: all of applied linear algebra fits in the fragment
   where sums stay home.
2. **Per-type zeros.** Because addition never crosses types, additive identities cannot
   be shared: `(0, g)` is the zero _of type `g`_, one per fiber. This is why "the" zero
   matrix and "the" identity matrix fracture into families ("many different `n × n`
   identity matrices with different zeros", §3.3), and it aligns Hart with
   [Raposo's and Jonsson's per-fiber zeros][whitney] against Kennedy's single polymorphic
   `0`.

The multiplicative asymmetry itself — total `·`, partial `+` — is _postulated_ in `(3)`,
`(4)`, mirroring practice; Hart offers no derivation of why the algebra of quantities
must have this shape. (For a modern answer to that "why" — distributivity forcing the
grading — see [Zapata-Carratalá on the free-abelian-group page][fag].)

---

## Expressive power & limits

### What it adds over scalar dimension systems

Every other formalization in this tree — [Whitney][whitney], the
[free abelian group][fag], [Kennedy's types][kennedy-types] — polices scalar expressions.
Hart's subject is the **composite operations** engineering actually runs: matrix
products, decompositions, spectra, matrix exponentials in `ẋ = Ax` systems theory (the
book devotes chapter 5 to state-space forms, transfer functions, controllability
grammians — book, TOC-level). The paper's own 2×2 motivating example, worked through the
class tower:

```text
        ⎡ 1m   1s ⎤          ⎡ 1m    1ms ⎤          ⎡ 1    1s ⎤
    X = ⎢         ⎥      Y = ⎢           ⎥      Z = ⎢         ⎥        (paper eq. (1))
        ⎣ 1s   1m ⎦          ⎣ 1m/s  1m  ⎦          ⎣ 1/s  1  ⎦

X:  [X²]₁₁ = X₁₁X₁₁ + X₁₂X₂₁ = 1m² + 1s²   ← different types: undefined by (4)
    det X  = 1m·1m − 1s·1s   = m² − s²      ← undefined
    rows (m, s) and (s, m) are not dimensionally parallel
      ⟹  no x, y with X ∼ yx̃: X can enter into NO products (Theorem 3.1)

Y = (1m)·xx̃  with T(x) = (1, s⁻¹)          ← squarable, c ∼ 1m (Theorem 3.4)
        ⎡ 2m²    2m²s ⎤
    Y² = ⎢            ⎥  ∼ (1m)·Y            ⟹  Y + Y² undefined (m vs m²):
        ⎣ 2m²/s  2m²  ⎦                          polynomials/e^Y do not exist
    eigenvalues of Y: λ ∼ 1m (Theorem 3.5) — both carry meters

Z = xx̃   with T(x) = (1, s⁻¹)              ← endomorphic (Theorem 3.3)
        ⎡ 2    2s ⎤
    Z² = ⎢         ⎥  ∼ Z                    ⟹  Z + Z², polynomials, e^Z all defined
        ⎣ 2/s  2  ⎦
    det Z = 1·1 − 1s·(1/s) = 0, dimensionless — defined but singular
```

`X`, `Y`, `Z` witness three distinct rungs: `X` is an array but not a matrix; `Y` is
squarable (eigenstructure exists) but not endomorphic (no exponential); `Z` supports the
full transcendental toolkit. A "reals with attached units" system that checks only
scalar `+` catches the bad sum in `X²` _at evaluation time, entry by entry_; Hart's
classification predicts it _from the shape_, and tells you which repairs are impossible
(no reordering or scaling of `X` makes it multipliable, because its rows are not
dimensionally parallel).

### The failure catalog for naive linear algebra over quantities

The conclusions section compresses the damage into four headline items — _"(1) `Aᵀ` is
not the adjoint of `A`; (2) `e^A` is defined iff `A` is endomorphic; (3) Symmetric
matrices generally have no eigenstructure; and (4) the SVD is only defined on uniform
matrices"_ (§4) — and the website adds the working engineer's translations:

- **"Any square matrix can be squared" — false.** Squarability is the special form
  `cxx̃` (Theorem 3.4). Determinant-possession is strictly weaker than squarability:
  Hart's pop-quiz asks for a matrix with a determinant that cannot be squared (the "if"
  of "determinant iff squarable" holds, the "only if" fails — website §C.1). A minimal
  witness, checkable by `(4)`/`(6)`: `A = [1m 2s; 1m 1s]` has `det A = 1ms − 2ms = −1ms`
  (defined, type `ms`, nonsingular) but `[A²]₁₁ = 1m² + 2sm` is undefined.
- **`AA⁻¹ ≠ A⁻¹A` in general** — `(23)`: they agree iff `A` is uniform. Both products
  equal an identity matrix _numerically_; they are different identity matrices, with
  differently-typed off-diagonal zeros (`AA⁻¹ ∼ yỹ`, `A⁻¹A ∼ xx̃`). Hart poses exactly
  this as quiz #2 and spells out the resolution among his "surprising theorems":
  _"For a nonsingular square matrix, A with inverse B, it is true as
  expected that AB=I and BA=I, but in general AB does not equal BA. The explanation lies
  in the fact that there are many different dimensionally distinct identity matrices."_
  (website §D.6).
- **Norms, orthogonality, positive definiteness collapse off the uniform class.**
  `xᵀx` needs a uniform `x` `(17)`; `Uᵀ = U⁻¹` forces `U` dimensionless `(25)`;
  quadratic-form definiteness needs `A ≈ x̃ᵀx̃` `(22)` while eigenstructure needs
  `A ∼ cxx̃` — and _"the set of matrices for which definiteness is defined barely
  intersects the set of matrices for which eigenvalues are defined"_ (website §D.5), so
  "positive definite iff all eigenvalues positive" is not even well-posed. Likewise the
  null-space/row-space orthogonality theorem fails dimensionally (website §D.5).
- **The vector/matrix concepts themselves split.** _"The traditional concept of a vector
  as a quantity with direction and magnitude is far too narrow for engineering purposes,
  while the traditional concept of a matrix as an array of scalars is far too broad.
  (Most vectors have no magnitude. Most arrays are not matrices.)"_ (website §D.2).

The practical warning is aimed at numerics: engineers strip units, feed the bare
`F`-components to a linear-algebra library, and read the results back with units — which
is exactly _"using traditional (dimensionless) linear algebra … on numeric matrices
obtained by ignoring the tacit dimensional components"_, and _"may lead to misleading and
physically meaningless results"_ (§4). An SVD of a non-uniform data matrix (mixed sensor
channels), a symmetric-eigenvalue analysis of a mixed-dimension covariance matrix, or a
matrix exponential of a non-endomorphic state matrix are all type errors that no scalar
units checker can see, because every _scalar_ operation performed along the way is
locally well-typed once the units are gone.

### What it cannot express

- **Fractional and irrational powers.** Not a limitation of the definitions — `G` is an
  arbitrary group, so `ℚⁿ`- or `ℝⁿ`-exponent dimension groups instantiate it — but the
  paper is silent on exponentiation of dimensioned scalars; the book's §1.2.3
  "Constraints on Exponentiation" and §1.2.5 "Dimensional Logarithms" advertise the
  treatment (book, TOC-level; contents unverifiable here). See the
  [free-abelian-group page][fag] for what the `ℚⁿ` extension costs.
- **Affine quantities** (temperature scales, calendar dates, positions). The `TFF` is a
  family of _fields_ sharing per-type zeros — every fiber has an origin, and every
  quantity may be scaled by dimensionless factors. Celsius-style offset scales and other
  torsor-like quantities have no representation; the [torsor page][torsor] covers the
  structure Hart's trivialized fibers cannot see.
- **Logarithmic quantities** (`dB`, `pH`) and **angles**: no treatment in the SIAM paper.
  The TOC's "Dimensional Logarithms" (§1.2.5) is the only hint that the book engages
  logarithm-like structure at all (book, TOC-level); angles never appear in any local
  Hart artifact — a recorded silence.
- **Kinds** (torque vs energy, `Hz` vs `Bq`): identified, as in every pure
  group-of-exponents system; see [Structural anatomy](#what-is-a-quantity-a-unit-a-dimension-a-kind).
- **Unit-free foundations.** The `TFF` hard-codes the global trivialization "quantity =
  number × type". The formalizations that refuse that identification
  ([Whitney][whitney], [tensor-of-lines][tensor-of-lines], [torsor][torsor],
  Zapata-Carratalá's non-trivializable dimensioned fields) locate a real foundational
  gap: in Hart there is no way to even _state_ "this equation holds independently of any
  choice of unit", because a choice of unit is baked into the carrier. The book's
  "Basis-Independence Principle" (§1.2.6) presumably addresses the dimension-basis
  analogue [unverified — TOC title only].

---

## Mechanization

### Hart's own software

- **`DimCalc`** — Hart's public-domain calculator _"for manipulating, converting, and
  calculating with dimensioned scalars"_, distributed from his book page as
  [`DimCalc.zip`][dimcalc]: a Microsoft Windows (3.1/95/98) Visual Basic program (it
  ships `vbrun300.dll`). Note the scope: **dimensioned scalars only** — the downloadable
  tool implements the `TFF`, not the matrix theory. (Some catalogs describe a
  Mathematica package; the local capture of Hart's page documents only the Windows
  program — the Mathematica attribution is [unverified].)
- **The book's chapter 6, "Multidimensional Computational Methods"** (book, TOC-level)
  designs — on paper — a software environment for dimensioned linear algebra: scalar
  representation and units conversion (§6.2), dimensioned vs dimension vectors (§6.3),
  the **"Domain/Range Matrix Representation"** (§6.4.2), and dimensioned versions of
  matrix operations: Gaussian elimination (§6.5.4), determinant/singularity (§6.5.5),
  inverse, transpose, eigenstructure, and SVD (§6.5.7–6.5.10), with tables for the
  "Dimensions of the LDU decomposition" (Table 6.4) and "Dimensions of the SVD"
  (Table 6.5).

The domain/range representation is Theorem 3.1 turned into a data structure: since a
usable `n × m` matrix satisfies `T(Aᵢⱼ) = T(yᵢ)/T(xⱼ)`, storing the two type vectors
`y` (range) and `x` (domain) — `n + m` group elements instead of `n·m` — captures the
entire dimensional form, and rescaling both by a common type (`x ↦ cx`, `y ↦ cy`) leaves
every `yᵢ/xⱼ` fixed, so the true parameter count is `n + m − 1`. The book's appendix 3.A
is titled "The `n + m − 1` Theorem" (book, TOC-level); the arithmetic above follows
directly from the paper's `(15)`. This representation is also the obvious **decision
procedure**: given an arbitrary array of types, checking whether it is multipliable —
i.e. factoring its type array as an outer product or refuting it — takes one pass fixing
`x₁ := 1`, reading off `y` from column 1 and `x` from row 1, then verifying
`T(Aᵢⱼ) = T(yᵢ)/T(xⱼ)` in `O(n·m)` group operations. Class membership (endomorphic,
squarable, uniform) then reduces to `O(n + m)` comparisons on the factors. Nothing here
is computationally deep — the barrier to mechanization is representational, not
algorithmic.

### Absence in mainstream units libraries — a finding

**No system surveyed in this tree implements dimensioned linear algebra.** The typed
libraries type _scalars_ and inherit homogeneous containers from their host language: an
[F#][fsharp-uom] array `float<m>[]` or a matrix over `float<m>` is Hart-**uniform** by
construction; [`pint`][python-pint] attaches _one_ unit to a whole NumPy array, so a
mixed-dimension matrix is expressible only as a boxed object array that defeats
vectorized linear algebra; [`Unitful.jl`][julia-unitful] can hold mixed-unit arrays only
at an abstract (boxed) element type, and generic linear-algebra routines are dependable
on uniform arrays; [`mp-units`][cpp-mp-units] and the other C++
libraries type `quantity` scalars, with matrix support delegated to external
linear-algebra types. None models the multipliable/endomorphic/squarable classes, the
`yx̃` factorization, or the dimensional inverse `Ã`; none can reject an SVD of a
non-uniform matrix _by type_ — the precise failure Hart flags as physically meaningless
is invisible to every production checker (see the [comparison capstone][comparison]).
The mismatch is structural: in [Kennedy-style type systems][kennedy-types] a container
type constructor takes _one_ element type, whereas Hart's matrices need a type indexed
by a **pair of dimension vectors** `(x, y)` with definitional equality up to the common
factor `c` — a dependent-typing burden the [type-system mechanisms page][mechanisms]
takes up. The domain/range representation is, in effect, the typing discipline such a
library would need.

### Proof assistants

No mechanization of Hart's theory in a proof assistant is known to this survey — the
survey's Lean findings ([`LeanDimensionalAnalysis`, mathlib's negative
finding][lean-units]) cover scalar dimension groups only. Formalizing Theorems 3.1–3.5
would be a small, self-contained target (the proofs are elementary), and would give the
first machine-checked account of _which_ linear-algebra theorems survive dimensioned
entries. Recorded as an open gap.

---

## Open problems & frontier

- **From `TFF` to dimensioned algebra.** [Zapata-Carratalá 2021][zapata] is the direct
  modern descendant: it credits Hart as first — _"rigorous mathematical axiomatizations
  of dimensional analysis have only appeared relatively recently. The first efforts in
  developing a general mathematical theory of physical quantities are due to Hart
  [Har12] in the 1980s"_ (§1, p. 2) — and then generalizes the `TFF` into **dimensioned
  rings/fields/modules** over a dimension projection `δ : A → D`, where Hart's `F × G`
  reappears as exactly the _trivializable_ case (a dimensioned field with a global
  choice-of-units section is isomorphic to `R₁ × D`, his Proposition 3.4 — but
  non-trivializable examples exist). In that frame, Hart's decision to define quantities
  as bare pairs is the one structural commitment the successors reject; see the
  [free-abelian-group page][fag] for the derivation of the grading and the
  [torsor page][torsor] for the bundle view. What Zapata-Carratalá does **not** yet
  redevelop is the matrix theory: dimensioned linear algebra over a non-trivializable
  dimensioned field — where the domain/range factorization cannot be globalized — is
  open.
- **A dating discrepancy.** Zapata-Carratalá places Hart's work "in the 1980s" while
  citing only the book (his `[Har12]` is a 2012-dated reprint of it); the local
  primaries are dated 1994 (SIAM) and 1995 (Springer). Whether Hart published
  1980s-era precursors (e.g. a dissertation) is not decidable from the local corpus
  [unverified].
- **What replaces the SVD off the uniform class?** The paper proves the classical SVD
  exists only for uniform matrices `(26)`; the book's TOC advertises §4.2 "Dimensioned
  Singular Value Decomposition (DSVD)" and §4.4 "Norms for Nonuniform Matrices" —
  i.e. Hart claims constructive replacements (book, TOC-level), but their statements
  are locally unverifiable. Independently assessing the DSVD against the modern
  numerical-analysis practice of pre-scaling ("nondimensionalizing") data matrices is an
  open task for this survey; the book's §1.1.3 "Nondimensionalization" names the
  competing technique (book, TOC-level).
- **Non-abelian type groups.** The `TFF` axioms permit a non-abelian `G` (losing only
  commutativity of multiplication) — a generality with no known physical instantiation
  and, in the local corpus, no follow-up. Whether anything in dimensional analysis
  _needs_ noncommuting dimensions is open (compare the free-abelian consensus in
  [the group page][fag]).
- **Statistics on dimensioned data.** The book's §5.8 "Expectations and Probability
  Densities" (book, TOC-level) points at a live issue this survey re-encounters in the
  systems pages: covariance matrices of mixed-dimension state vectors are of form
  `xxᵀ`-symmetric but generally **not squarable**, so principal-component analysis on
  raw (non-uniformized) physical data is dimensionally meaningless by Theorem 3.5 —
  a widely-ignored consequence with no standard resolution.
- **Typing dimensioned matrices.** No type system in this survey can express "matrix
  from `x`-space to `y`-space" with the `(x, y) ∼ (cx, cy)` quotient; whether
  Kennedy-style principal typing extends from [AG-unification on scalars][kennedy-types]
  to the outer-product matrix discipline is open. See
  [type-system mechanisms][mechanisms].

---

## Sources

- G. W. Hart, ["The Theory of Dimensioned Matrices"][siam-ps], _Proc. 5th SIAM Conf. on
  Applied Linear Algebra_, June 1994, pp. 186–190 — the primary: `TFF` definitions
  `(3)`–`(4)`, matrix definitions and `∼`/`≈`/`Ã` `(5)`–`(10)`, basic identities
  `(11)`–`(19)`, Theorems 3.1–3.5, results `(20)`–`(26)`, and the conclusions quoted
  above. (Local: `hart-1994-dimensioned-matrices-siam.pdf`; quotes verified against page
  renders — the PDF text layer drops ligatures.)
- G. W. Hart, [_Multidimensional Analysis: Algebras and Systems for Science and
  Engineering_][book-doi], Springer-Verlag, 1995, ISBN 0-387-94417-6 — the full
  treatment; grounded here **only** via its front matter/TOC (local:
  `hart-1995-multidimensional-analysis-frontmatter-springer.pdf`): chapter structure,
  §§ titles cited as (book, TOC-level), figures/tables list.
- G. W. Hart, ["Multidimensional Analysis" book page][hart-site] (georgehart.com; local:
  `hart-1995-multidimensional-analysis-website.html`) — the `X`/`Y`/`Z` walkthrough, the
  pop quiz, the six "surprising theorems" (inclusion tower, definiteness/eigenvalue
  disjointness, `AB ≠ BA`), the Math Reviews blurb, [`DimCalc.zip`][dimcalc], and the
  book/SIAM-paper citations.
- C. Zapata-Carratalá, ["Dimensioned Algebra: the mathematics of physical
  quantities"][zapata], arXiv:2108.08703, 2021 (local:
  `zapata-carratala-2021-dimensioned-algebra-arxiv.pdf`) — Hart's priority claim (§1),
  dimensioned rings/fields as the `TFF`'s generalization (§3), the trivialization
  `R₁ × D` (Prop. 3.4).
- Related deep-dives: [theory index][theory-index] · [units-of-measure
  umbrella][umbrella] · [concepts glossary][concepts] ·
  [Whitney's quantity structures][whitney] · [Buckingham Π][pi] ·
  [dimensions as a free abelian group][fag] · [tensor of lines][tensor-of-lines] ·
  [torsor representation][torsor] · [Kennedy's dimension types][kennedy-types] ·
  [type-system mechanisms][mechanisms] · system pages [F# units][fsharp-uom],
  [`pint`][python-pint], [`Unitful.jl`][julia-unitful], [`mp-units`][cpp-mp-units],
  [Lean/mathlib][lean-units] · [comparison capstone][comparison].

<!-- References -->

<!-- Same-tree theory siblings -->

[theory-index]: ./index.md
[whitney]: ./whitney.md
[pi]: ./buckingham-pi.md
[fag]: ./free-abelian-group.md
[tensor-of-lines]: ./tensor-of-lines.md
[torsor]: ./torsor-representation.md
[kennedy-types]: ./kennedy-types.md
[mechanisms]: ./type-system-mechanisms.md

<!-- Tree umbrella / concepts / comparison -->

[umbrella]: ../index.md
[concepts]: ../concepts.md
[comparison]: ../comparison.md

<!-- System pages -->

[fsharp-uom]: ../fsharp-uom.md
[python-pint]: ../python-pint.md
[julia-unitful]: ../julia-unitful.md
[cpp-mp-units]: ../cpp-mp-units.md
[lean-units]: ../lean-mathlib-units.md

<!-- External primary sources -->

[siam-ps]: https://www.georgehart.com/research/tdm.ps
[book-doi]: https://doi.org/10.1007/978-1-4612-4208-6
[hart-site]: https://www.georgehart.com/research/multanal.html
[dimcalc]: https://www.georgehart.com/research/dimcalc.zip
[zapata]: https://arxiv.org/abs/2108.08703
