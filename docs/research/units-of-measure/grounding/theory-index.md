# Grounding ledger — `theory/index.md` (theory-subtree umbrella)

Cross-page consistency verification of the theory umbrella page
`docs/research/units-of-measure/theory/index.md` against the eight landed theory
deep-dives it catalogs and against `comparison.md`. This is a **synthesis /
umbrella** page: its grounding target is that its catalog table, its three
cross-cutting splits, its reading paths, its source spine, and the few
primary-artifact claims it states directly all stay consistent with the pages
they summarize. Claims are checked against the relevant section of each theory
page (and, where the theory page is itself already grounded, against its landed
ledger `theory-*.md`) rather than re-derived from the PDFs. One primary-artifact
claim (Bridgman's inhomogeneous equation) is spot-checked against the
Buckingham-π page's own grounding.

Deep-dives cross-checked: `theory/buckingham-pi.md`, `theory/whitney.md`,
`theory/free-abelian-group.md`, `theory/tensor-of-lines.md`,
`theory/torsor-representation.md`, `theory/kennedy-types.md`,
`theory/hart-multidimensional.md`, `theory/type-system-mechanisms.md`, and
`comparison.md` (plus the landed ledgers `theory-whitney.md`, `cpp-au.md` for
house format). Runnable prototypes checked against their own file headers under
`docs/research/units-of-measure/examples/`.

Type: **synth** = summary/classification consistent with a deep-dive · **fact** =
date/attribution/source-list · **quote/primary** = a claim about a primary
artifact stated directly on the umbrella · **meta** = internal cross-table check ·
**opinion** = editorial framing.
Status: ✓ consistent with deep-dive(s) + local source · ≈ consistent, minor gloss ·
⚠ drift / cross-page mismatch · ◯ editorial/opinion · 🌐 not locally groundable.

## Claims

### Framing & the organizing question (L1–68)

| #   | Claim                                                                                                                                                                                             | Type          | Source (page + locator)                                                                      | Evidence                                                                                                                                                                                      | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- | -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| 1   | Intro positioning (classical → algebraic → type-theoretic line; concepts sits above, systems ship the ideas, comparison reconciles); "Last reviewed July 3, 2026" (L16)                           | opinion       | —                                                                                            | navigational framing; the date matches `index.md:60` and `comparison.md:21` (all three synthesis pages say July 3, 2026 — internally consistent)                                              | ◯      |
| 2   | Organizing question: different-dimension quantities multiply freely (`1 m × 1 s`) but refuse to add; each page is downstream of a "which object is primitive" choice (L20–27)                     | synth         | `comparison.md:42–75` (what-is-primitive)                                                    | matches the comparison's six-way primitive split and every page's "what structure is primary" section                                                                                         | ✓      |
| 3   | IMPORTANT: the prohibition is a construction not a theorem; **Bridgman exhibits a unit-invariant yet inhomogeneous `v + s = gt + ½gt²` and explicitly refutes the intuition as a proof** (L29–37) | quote/primary | `buckingham-pi.md` H3 row + §"How homogeneity is expressed" (Bridgman p. 42)                 | pi page: `v + s = gt + ½gt²` "complete (unit-invariant) yet not dimensionally homogeneous"; Bridgman "refutation of the intuitional method of proof" (p. 42) — grounded on local Bridgman PDF | ✓      |
| 4   | Every formalization bans the mixed sum "by construction — disjoint carriers, partial operations, typing rules"; comparison's seven-readings ledger holds them side by side (L33–37)               | synth         | `comparison.md:150` (Seven readings); `whitney`/`hart`/`kennedy` addition sections           | disjoint carriers (Whitney), partial ops (Hart/Zapata), typing rules (Kennedy) — all present; `[comparison-seven]` anchor resolves to the L150 heading                                        | ✓      |
| 5   | Deep-dive split — pi: "π-theorem as rank–nullity for the dimension matrix over `ℚ`, plus the hypotheses folklore elides (completeness, unit-invariance, single relation, positivity)" (L41)       | synth         | `buckingham-pi.md` §"usually-elided hypotheses" H1–H4                                        | H1 completeness, H2 unit-invariance, H3 single-relation, H4 positivity — verbatim the four listed                                                                                             | ✓      |
| 6   | Deep-dive split — whitney: "quantities primitive, number systems constructed afterwards as operators; the `Q ≅ ℝ × ℚⁿ` representation theorem" (L44)                                              | synth         | `whitney.md` "At a glance" (Primary objects, Numbers, Central theorems)                      | rays/birays primitive; `ℕ→ℚ⁺→ℝ⁺→ℝ` as operators; representation `Q ≅ ℝ × ℚⁿ` — matches `theory-whitney.md` rows 14,36                                                                         | ✓      |
| 7   | Deep-dive split — fag: "dimensions as exponent vectors in `ℤⁿ` (or `ℚⁿ`), two `GL`-actions, and π re-read as lattice linear algebra" (L47)                                                        | synth         | `free-abelian-group.md` "At a glance" (Change of units: "Two `GL`-actions"); §"Buckingham π" | fag itself labels rescaling + base change "Two `GL`-actions"; π as `ker A` lattice — umbrella mirrors the page's own wording                                                                  | ✓      |
| 8   | Deep-dive split — tensor: "base dimensions as one-dimensional lines, units as basis vectors, inconsistency as unwritability; JMV positive spaces as the rigorous companion" (L50)                 | synth         | `tensor-of-lines.md` "At a glance" (Primary structure, Unit, Cross-dim addition)             | 1-D lines; unit = basis vector; abstract addition "unwritable"; JMV positive spaces — all in the At-a-glance table                                                                            | ✓      |
| 9   | Deep-dive split — torsor: "dimensional analysis as representation theory of `(ℝ⁺)ⁿ`, units as torsor points, a choice of units as a never-canonical trivialization" (L53)                         | synth         | `torsor-representation.md` "At a glance" (Primary structure, Unit, Central theorem)          | scaling torus `(ℝ⁺)ⁿ`; unit = torsor point; trivialization `R_D ≅ R₁ × D` "always non-canonically"                                                                                            | ✓      |
| 10  | Deep-dive split — kennedy: "units as type-level group elements, principal types by AG-unification, meaning as invariance under rescaling (parametricity), erasure" (L56)                          | synth         | `kennedy-types.md` "At a glance" (Primary structure, Inference, Central theorem)             | free-abelian-group-indexed types; unitary AG-unification ⇒ principal types; dimensional invariance = parametricity; erasure                                                                   | ✓      |
| 11  | Deep-dive split — hart: "dimensioned matrices, the outer-product factorization, and how much of matrix theory survives (little)" (L59)                                                            | synth         | `hart-multidimensional.md` "At a glance" (Central theorem, Broken classical facts)           | Thm 3.1 usable matrix ⇔ `A ∼ yx̃` (outer product); broken determinant/eigen/SVD tower                                                                                                          | ✓      |
| 12  | Deep-dive split — mech: "six encodings of the group, organized by whether the checker _evaluates_ or _solves_, and by what 'zero runtime cost' formally means" (L62)                              | synth         | `type-system-mechanisms.md` "At a glance" (six families); L170 "evaluate … never solve"      | six mechanism families; evaluate-vs-solve framing (mech L170; comparison §"1. Mechanism: evaluators vs solvers" L400); erasure/zero-cost                                                      | ✓      |
| 13  | tensor & torsor "develop two halves of one picture — carriers-first vs action-first — and state their ownership boundary and the three source-supported bridges" (L66–68)                         | synth         | `tensor-of-lines.md` L302–343 (three bridge bullets + boundary NOTE); `torsor` NOTE          | tensor states "exactly three statements about how the pictures connect"; both pages carry explicit ownership-boundary NOTE blocks                                                             | ✓      |

### Catalog table (L74–83) — per-row vs the deep-dive "At a glance"

| #   | Claim (row → structure / pins / sources)                                                                                                                                                                                                                              | Type  | Source (page)                                                  | Evidence                                                                                                                                          | Status         |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- |
| 14  | **Buckingham π** — "dimension matrix `A` + rescaling group" / "rank–nullity over `ℚ` + one analytic step; hypotheses ledger; four accounts of the ban" / Vaschy 1892; Buck 1914; Bridg 1922; Drobot 1953; CLP 1982                                                    | synth | `buckingham-pi.md` "At a glance" + §Formal core + intro L11–17 | structure/pins verbatim-consistent; **sources cell dropped Jonsson 2020**, which the pi page's intro lists as one of its five primaries → see D1  | ⚠ → fixed (D1) |
| 15  | **Whitney** — "one-kind measurement models (rays/birays); numbers as operators" / "quantities-first; `Q ≅ ℝ × ℚⁿ`; unresolved exponent ring (`ℚ` vs `ℝ`)" / Whitney 1968 I & II; Raposo 2018/2019; Jonsson 2021                                                       | synth | `whitney.md` "At a glance" + Primary sources                   | all three cells match the page (`ℝ × ℚⁿ` is the page's own canonical form + the ℚ-vs-ℝ dispute it declines to resolve, `theory-whitney.md` r40)   | ✓              |
| 16  | **Free abelian group** — "`Dim ≅ ℤⁿ` (`ℚⁿ` after fractional powers)" / "freeness = unique normal forms; rescaling vs `GL(n, ℤ)`; what `ℤ → ℚ` buys and breaks" / Kennedy 1996; Jonsson 2020/2021; Zapata 2021; Lean repo                                              | synth | `free-abelian-group.md` "At a glance" + Primary sources        | structure/pins/sources all match (page's four foregrounded primaries + Lean repo)                                                                 | ✓              |
| 17  | **Tensor of lines** — "1-D ordered lines under `⊗`/duals; JMV positive spaces" / "units as basis vectors; inconsistency as unwritability; the abstract↔parametric dictionary; the kind ladder" / Tao 2012; JMV 2007                                                   | synth | `tensor-of-lines.md` "At a glance"                             | carriers-first reading (parametric half deliberately assigned to torsor per the ownership split); dictionary theorem; structure-group kind ladder | ✓              |
| 18  | **Torsor / scaling torus** — "the `(ℝ⁺)ⁿ` action; dimensioned rings fibred over `D`" / "homogeneity = equivariance; units = torsor points; unit systems = sections; trivialization never canonical" / Baez; Tao 2012; Zapata 2021; Jonsson 2021                       | synth | `torsor-representation.md` "At a glance"                       | action-first reading; every pin present; canonical-sources cell matches the page's "Canonical sources" row exactly                                | ✓              |
| 19  | **Kennedy's types** — "typed λ-calculus with the group embedded in the type grammar" / "principal types via unitary AG-unification; parametricity = invariance; erasure semantics" / Wand & O'Keefe 1991; Kennedy 1994/1996/1997/2010                                 | synth | `kennedy-types.md` "At a glance" + Primary sources             | structure/pins/sources match the page's four Kennedy texts + the W&O'K precursor                                                                  | ✓              |
| 20  | **Hart** — "the `TFF` `F × G`; dimensioned vectors and matrices above it" / "multipliable ⇔ dimensionally rank-1 (`A ∼ yx̃`); the matrix class tower; why no library ships dimensioned matrices" / Hart 1994 (SIAM) & 1995 (Springer); Zapata 2021                     | synth | `hart-multidimensional.md` "At a glance"                       | TFF `F × G`; Thm 3.1 outer-product; class tower; "no mainstream units library implements any of it"; sources match                                | ✓              |
| 21  | **Type-system mechanisms** — "the group as checkable type structure — six mechanism families" / "evaluate vs solve; the two organizing theorems (AG-unification unitary; erasure + parametricity)" / Kennedy 2010; Gundry 2015; pinned F#/Rust/C++/Haskell/Lean trees | synth | `type-system-mechanisms.md` "At a glance" + Primary sources    | six families; two organizing theorems verbatim; sources match (Kennedy 2010 + Gundry 2015 + the pinned repos)                                     | ✓              |

### Cross-cutting split 1 — "What is primitive" table (L95–102)

| #   | Claim (primitive → page → what must be earned)                                                                                                           | Type  | Source (page / comparison)                                         | Evidence                                                                                                                                                                      | Status      |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| 22  | Quantities → [whitney] → "number systems `ℕ → ℚ⁺ → ℝ⁺ → ℝ` constructed as operators on rays"                                                             | synth | `whitney.md` §Numbers; `comparison.md:47–49`                       | "numbers arise as operators … `ℕ → ℚ⁺ → ℝ⁺ → ℝ`" (whitney); "quantities first … numbers constructed afterwards" (comparison)                                                  | ✓           |
| 23  | Measures + transformation rule → [pi] → "quantity/measure distinction (conflated deliberately; re-axiomatized by Drobot/CLP)"                            | synth | `buckingham-pi.md` §Structural anatomy; `comparison.md:57–60`      | Buckingham/Bridgman "deliberately conflated with the magnitude"; "Drobot, CLP, and Jonsson then re-axiomatize" (umbrella lists Drobot/CLP)                                    | ✓           |
| 24  | Carriers (1-D lines) → [tensor] → "rescaling group derived as basis change; a change of units is abstractly 'nothing'"                                   | synth | `tensor-of-lines.md` L586–592; `comparison.md:50–52`               | "Abstractly, a change of units is nothing at all"; rescaling "acts here derivedly, through basis choices"                                                                     | ✓           |
| 25  | Group action → [torsor] → "carriers recovered as weight spaces/slices; even same-dimension `+` must be recovered"                                        | synth | `torsor-representation.md` "At a glance"; `comparison.md:53–56,73` | action-first; carriers "recovered as weight spaces, slices"; comparison: "torsor picture must _recover_ same-dimension addition"                                              | ✓           |
| 26  | Types and programs → [kennedy], [mech] → "the scaling group itself — derived from the primitives `0`, `1`, `+`, `−`, `*`, `/`, `<` (POPL '97 Theorem 2)" | synth | `kennedy-types.md:272` (`ρops` of `0, 1, +, -, *, /, <`), L462–463 | umbrella's SEVEN-primitive list matches `kennedy-types.md:272` exactly; scaling group "derived — not assumed — from the primitives (Theorem 2)"                               | ✓           |
| 27  | Trivialized pair `(f, g)` → [hart] → "nothing — a unit per dimension is already chosen, non-canonically; invariance via quotients"                       | synth | `comparison.md:64–69`; `hart-multidimensional.md` (TFF `F × G`)    | "writing a quantity as a bare pair has _already_ chosen a unit per dimension … non-canonical isomorphism"; "invariance via quotients" is editorial gloss (basis-independence) | ✓ (◯ gloss) |
| 28  | The six primitive rows match comparison's six bullets one-for-one (Whitney/pi/tensor/torsor/kennedy/hart)                                                | meta  | `comparison.md:47–69` vs umbrella L95–102                          | same six pages, same "what must be earned" content; umbrella adds [mech] beside [kennedy] (consistent with the syntactic grouping in split 3)                                 | ✓           |

### Cross-cutting split 2 — the exponent ring (L104–116)

| #   | Claim (clause)                                                                                                                                             | Type  | Source (page)                                                                    | Evidence                                                                                                                           | Status |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | ------ |
| 29  | "local restatements of Whitney's Part II contradict each other (`ℚ` vs `ℝ`)" ([whitney])                                                                   | synth | `whitney.md` §"What the restatements disagree on"                                | Raposo 2018 = `ℚ`, Raposo 2019 = `ℝ`, Jonsson "`Q` or `R`" (`theory-whitney.md` r40)                                               | ✓      |
| 30  | "the classical π-theorem allows `ℝ` but `ℚ` provably suffices and integer kernel bases always exist" ([pi])                                                | synth | `buckingham-pi.md` NOTE "Why `ℚ` is enough"                                      | "`ker A` always has a basis of rational vectors, hence … integer vectors"; CLP/Drobot allow `ℝ`                                    | ✓      |
| 31  | "Kennedy fixed `ℤ` deliberately, and his sqrt-indefinability theorem holds only there" ([kennedy])                                                         | synth | `kennedy-types.md` (fractional by design); `fag` §costs; `comparison.md:111–114` | "over `ℚ` the perfect-square predicate is inexpressible and the theorem has no analogue"                                           | ✓      |
| 32  | "the torus picture over-generates (its characters form `ℝⁿ`) and explains no particular lattice" ([torsor])                                                | synth | `torsor-representation.md` L180–182; `comparison.md:115–116`                     | "the character group of the scaling torus is `ℝⁿ`, and the integer dimension vectors `ℤⁿ` … form a sublattice of it"               | ✓      |
| 33  | "the `ℤ → ℚ` extension is a change of category — freeness over base symbols, the perfect-square predicate, and gcd/lattice structure are all lost" ([fag]) | synth | `free-abelian-group.md` §"What it costs"                                         | "a genuine change of category"; freeness lost; "Is this dimension a perfect square?" inexpressible; gcd/lattice collapse           | ✓      |
| 34  | "Practice quietly drifted to `ℚ`"; two CI-verified prototypes make both ends runnable ([`quantity-zn-graded.d`], [`quantity-rational-exponents.d`])        | synth | `comparison.md#2-the-exponent-domain-in-practice`; examples/                     | `quantity-zn-graded.d` header = "ℤⁿ normal form", `quantity-rational-exponents.d` header = "the `ℚⁿ` variant" — both files present | ✓      |

### Cross-cutting split 3 — semantic vs syntactic (L118–130), reading paths, sources

| #   | Claim                                                                                                                                                                                                                                                                           | Type  | Source (page)                                                             | Evidence                                                                                                                   | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ------ |
| 35  | Semantic/algebraic = [whitney],[pi],[tensor],[torsor],[hart]; syntactic/type-theoretic = [kennedy],[mech]                                                                                                                                                                       | synth | all eight "At a glance" tables                                            | matches each page's own self-description (algebraic vs type-system); same grouping as comparison Part I/Part III           | ✓      |
| 36  | "the two sides meet in the Lean mechanization … `CommGroup (dimension B E)` stated inside a type theory ([fag],[mech])"                                                                                                                                                         | synth | `free-abelian-group.md` L614 (`instance : CommGroup …`, Basic.lean:234)   | `CommGroup (dimension B E)` proved instance — verbatim                                                                     | ✓      |
| 37  | "Kennedy's parametricity results prove the syntactic discipline sound for exactly the semantic notion of invariance"                                                                                                                                                            | synth | `kennedy-types.md` §parametricity (Theorems 1+2)                          | parametricity = invariance under scaling; completeness (Theorem 2)                                                         | ✓      |
| 38  | Reading paths + anchors: `comparison-seven`/`-primitive`/`-exp`/`-graded` resolve to comparison headings; `fsharp-uom.md` + 3 example files exist                                                                                                                               | fact  | `comparison.md` headings L42/100/150/199; `ls examples/`; `fsharp-uom.md` | four target headings present; example files present; anchor forms match landed `index.md`/`concepts.md` (house convention) | ✓      |
| 39  | Source spine (L157–162): Buckingham 1914 · Bridgman 1922 · Drobot 1953 · Whitney 1968 · CLP 1982 · Wand & O'Keefe 1991 · Kennedy 1994–2010 · Hart 1994/1995 · JMV 2007 · Tao 2012 · Atkey 2014 · Gundry 2015 · Raposo 2018/2019 · Jonsson 2020/2021 · Zapata 2021 · Bobbin 2025 | fact  | each theory page's Primary sources                                        | every date/author consistent with the page that treats it as primary; "pinned production trees … cited on [mech]" matches  | ✓      |

## Discrepancies

**#D1 ⚠ (minor) — `theory/index.md:76` (Catalog, Buckingham-π row, "Canonical
sources" cell).** The cell read
"Vaschy 1892; Buckingham 1914; Bridgman 1922; Drobot 1953; CLP 1982", stopping at
1982 and omitting **Jonsson 2020**. But the Buckingham-π page's own intro
enumerates its primary sources as five inspected artifacts —
"Buckingham 1914 …, Bridgman 1922 …, Drobot 1953 …, Curtis–Logan–Parker 1982 …,
and Jonsson 2020 (the modern 'amended' strengthening)"
(`theory/buckingham-pi.md:11–17`) — and the same umbrella row's "What it pins
down" cell ("the hypotheses ledger; four accounts of the addition ban") is
substantially the Jonsson-2020 amended material (his Example 4 derived-addition
account, the field-agnostic positivity drop). The omission is also asymmetric with
the sibling catalog rows, which do list their modern/algebraic sources (Whitney
row → Jonsson 2021; free-abelian row → "Jonsson 2020/2021"; torsor row →
Jonsson 2021). **Fix:** appended "; Jonsson 2020" so the cell matches the pi page's
own five-source enumeration and the catalog's own house style. Fixed: yes (this
pass).

## Unsourced / opinion / observations (no edit)

- ◯ **"Last reviewed: July 3, 2026" (L16).** Editorial; internally consistent with
  the two other synthesis pages (`index.md:60`, `comparison.md:21`, both July 3,
  2026). The eight theory deep-dives carry no "Last reviewed" marker, so there is
  no conflict to reconcile. (Today's calendar date differs, but "last reviewed" is
  a claim about when the review happened, not about today.)
- ◯ **Hart "invariance via quotients" (L102).** The "a unit per dimension is
  already chosen, non-canonically" half is grounded (`comparison.md:64–69`); the
  "invariance via quotients" tail is an editorial gloss on Hart's
  Basis-Independence Principle (§1.2.6, book/TOC-level), not a quoted claim — it
  neither contradicts nor is contradicted by any page, so it is left as the
  umbrella's own synthesis.
- ◯ **Anchor slugs to `comparison.md` sub-sections.** `comparison-exp`
  (`#2-the-exponent-domain-in-practice`) and `comparison-primitive`
  (`#…-quantities-units-dimensions-or-the-action`) use the same
  drop-special-chars/single-hyphen slug convention as the already-landed
  `index.md:330,332` and `concepts.md:586` (which reuse `comparison-exp`,
  `comparison-graded`, `comparison-seven` verbatim). Whatever VitePress's
  slugifier does to a digit-leading or em-dash heading, it does uniformly across
  the whole survey — so this is a tree-wide convention, not a theory/index.md
  drift, and consistency requires matching (which it does). Out of scope for this
  page's ledger.
- Note (no edit): the umbrella's "Types and programs" primitive cell lists the
  full seven Kennedy primitives `0, 1, +, −, *, /, <` (matching the authoritative
  `kennedy-types.md:272`); `comparison.md:74` abbreviates the same derivation to
  "`0`, `<`, `*`, `/`". The mismatch is an under-listing on the **comparison**
  page, not on the umbrella — recorded here so the comparison ledger can decide
  whether to expand it; the umbrella is correct as written and needs no change.

## Net

39 checked claims across the umbrella's framing block, the eight-row catalog
table, the three cross-cutting splits (six-way "what is primitive", the
exponent-ring prose, the semantic-vs-syntactic table), the reading paths, and the
source spine. The page is **highly consistent** with the eight theory deep-dives,
`comparison.md`, and the three runnable prototypes: every catalog structure/pins
cell, every primitive-table assignment, every exponent-ring clause, and every
source date checks out against the page it summarizes, and the one directly-stated
primary-artifact claim (Bridgman's `v + s = gt + ½gt²` and his explicit refutation
of the "apples and oranges" proof) is grounded via the Buckingham-π page's own
local-Bridgman evidence. One minor discrepancy, fixed this pass: **D1** — the
Buckingham-π catalog row dropped Jonsson 2020 from its canonical-sources cell,
contradicting the pi page's own primary-source enumeration and the catalog's
house style. No cross-page **contradiction** found; three ◯ observations
(editorial "Last reviewed" date, the Hart "invariance via quotients" gloss, the
tree-wide anchor-slug convention) and one forward-note (the comparison page's
shorter Kennedy-primitive list) require no edit to this page.
