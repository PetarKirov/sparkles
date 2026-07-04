# Units of Measure

A breadth-first survey of **units of measure** — the mathematics of physical
quantities and dimensional analysis (quantity calculus, the Buckingham π theorem, free
abelian groups of dimensions, tensor lines, torsors, dimensioned algebra, and
Kennedy's type-theoretic line), and the twenty checked-units systems real ecosystems
ship, from compiler-native ([F#][fsharp], [GNAT][gnat]) through static library
encodings (Rust, C++, Haskell, D) and dependent types ([Lean][lean]) to dispatch-time
([Julia][unitful]), runtime registries ([Python][pint]), and symbolic engines
([Wolfram / MATLAB][wolfram]). The goal is a grounded map of the design space to
inform a future **Sparkles quantities library**: the repo's constraints — templates +
CTFE, `@safe pure nothrow @nogc` cores, [`Expected`-based error handling][expected] —
select a specific region of that space, and the survey closes with the delta
([comparison, Part IV][comparison-sparkles]), the D prior art ([d-quantities][dq]),
and thirteen CI-verified runnable D prototypes ([`examples/`](#runnable-prototypes)).

This survey answers seven questions:

1. **What is a quantity — and what, exactly, is wrong with `1 m + 1 s`?** The
   metrology vocabulary (VIM, SI Brochure, UCUM, QUDT) and the six-account orientation
   ledger for the survey's central prohibition. See [concepts][concepts].
2. **What are the classical results?** The π-theorem as rank–nullity over the
   dimension matrix — with the hypotheses folklore elides — and the free-abelian-group
   skeleton every library implements. See [buckingham-pi][pi] and
   [free-abelian-group][fag].
3. **What are the rigorous formalizations of "quantity"?** Whitney's rays and birays,
   Tao's tensor of lines, the torsor/weight-space picture, and Hart's dimensioned
   linear algebra — with what each takes as primitive. See the
   [theory subtree][theory].
4. **How does the algebra become a type system?** Kennedy's line — types-as-invariance,
   AG-unification, erasure — and the six mechanism families that encode the group in
   real checkers. See [kennedy-types][kennedy] and [type-system-mechanisms][mech].
5. **How do real ecosystems package this?** Twenty systems, from the one compiler
   with the theory built in to registries and symbolic engines. See the
   [master catalog](#systems-master-catalog).
6. **What does the field agree on, and where does it split?** Seven consensus points,
   nine genuinely open trade-off axes, and a candidate unifying hypothesis
   (quantities as a graded object) tested against the evidence. See the
   [comparison][comparison].
7. **Where would a Sparkles units library sit?** The D evidence — two complete prior
   designs, thirteen runnable prototypes — and the open decisions a `docs/specs/`
   proposal must make. See [comparison, Part IV][comparison-sparkles],
   [d-quantities][dq], and the [prototypes](#runnable-prototypes).

> [!NOTE]
> **Scope: foundations, vocabulary, and twenty flagship systems (waves 1–2).** The
> [theory subtree][theory] (eight deep-dives), the [concepts glossary][concepts], the
> twenty system pages below, the [comparison capstone][comparison], and the three
> CI-verified D prototypes are landed. **Wave 2 has now landed six further system
> pages** — the Scala libraries ([coulomb][scala-coulomb] + [squants][scala-squants]),
> Nim's [unchained][nim-unchained], Swift's Foundation [`Measurement`][swift-units],
> Kotlin's [measured][kotlin-measured], and the
> [UCUM / QUDT interchange implementations][ucum-qudt] — taking the catalog from
> fourteen to **twenty** systems. Several systems are covered as in-page asides rather
> than own rows: `astropy.units` (inside [python-pint][pint]), Eisenberg's `units`
> package (inside [haskell-dimensional][dimensional]), `std::chrono` (inside
> [cpp-boost-units][boost]), `nordlow/units-d` (inside [d-quantities][dq]),
> `NeedleInAJayStack/Units` (inside [swift-units][swift-units]), and the JSR-385
> `indriya` / `unit-api` layer (inside [ucum-qudt][ucum-qudt]). Other-language units
> libraries remain out of scope for now; the UCUM spec and the QUDT ontology
> _themselves_ are covered in [concepts][concepts] as the interchange and data poles
> of the design space.

**Last reviewed:** July 4, 2026

---

## Foundations (theory)

The formalizations, each developed in its own deep-dive. Start with the
[concepts glossary][concepts] for the shared vocabulary, then the
[theory umbrella][theory] for the organizing question (what is wrong with `1 m + 1 s`,
and what is primitive) and the cross-cutting splits.

| Topic                                | What it pins down                                                                                              | Canonical sources                                                     | Link       |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- | ---------- |
| **Concepts & vocabulary**            | VIM/SI/UCUM/QUDT definitions; the one-prohibition-six-accounts ledger; the affine/logarithmic/angle edge cases | VIM 3rd ed.; SI Brochure 9th ed.; NIST SP 811; UCUM; QUDT             | [concepts] |
| **Buckingham π via linear algebra**  | the π-theorem as rank–nullity over `ℚ` + one analytic step; the hidden-hypotheses ledger                       | Vaschy 1892; Buckingham 1914; Bridgman 1922; Drobot 1953; CLP 1982    | [pi]       |
| **Whitney's quantity structures**    | quantities-first axiomatics; the `Q ≅ ℝ × ℚⁿ` representation theorem; the unresolved exponent ring             | Whitney 1968 (Monthly I & II); Raposo 2018/2019; Jonsson 2021         | [whitney]  |
| **Free abelian group**               | dimensions as exponent vectors (`ℤⁿ`/`ℚⁿ`); two `GL`-actions; what `ℤ → ℚ` buys and breaks                     | Kennedy 1996; Jonsson 2020/2021; Zapata-Carratalá 2021; the Lean repo | [fag]      |
| **Tensor of lines**                  | base dimensions as 1-D lines; units as basis vectors; inconsistency as unwritability                           | Tao 2012; Janyška–Modugno–Vitolo 2007                                 | [tensor]   |
| **Torsor / scaling torus**           | homogeneity = equivariance under `(ℝ⁺)ⁿ`; units = torsor points; trivialization never canonical                | Baez; Tao 2012; Zapata-Carratalá 2021; Jonsson 2021                   | [torsor]   |
| **Kennedy's types**                  | principal types via unitary AG-unification; parametricity = invariance under rescaling; erasure                | Wand & O'Keefe 1991; Kennedy 1994/1996/1997/2010                      | [kennedy]  |
| **Hart's multidimensional analysis** | dimensioned linear algebra: multipliable ⇔ dimensionally rank-1; most of matrix theory breaks                  | Hart 1994 (SIAM) & 1995 (Springer); Zapata-Carratalá 2021             | [hart]     |
| **Type-system mechanisms**           | the theory→systems bridge: six encodings of the group; the checker _evaluates_ vs _solves_                     | Kennedy 2010; Gundry 2015; the pinned system source trees             | [mech]     |

---

## Systems master catalog

One row per surveyed system — the identity and classification columns only.
**Checked** is when a mismatch is reported: at _compile_ time, at _elaboration_ (proof
assistant), per JIT _dispatch_ specialization, at _run_ time, or only on an explicit
_opt-in_ query. **Exponents** is the dimension group's exponent domain as shipped.
**Kind** is whether same-dimension, different-kind quantities (`Hz` vs `Bq`, torque vs
energy) are distinguishable. The full per-dimension comparison — affine and
logarithmic support, polymorphism, erasure evidence, diagnostics, compile cost — is
the [comparison's at-a-glance matrix][comparison-matrix]; this catalog is who-is-who.

| System                       | Ecosystem              | Mechanism                                                                              | Checked        | Exponents           | Kind                       | Link                               |
| ---------------------------- | ---------------------- | -------------------------------------------------------------------------------------- | -------------- | ------------------- | -------------------------- | ---------------------------------- |
| **F# units of measure**      | F# / .NET              | native AG unifier in the compiler's constraint solver                                  | compile        | `ℚ`¹                | —²                         | [fsharp-uom][fsharp]               |
| **uom-plugin**               | Haskell (GHC)          | typechecker-plugin AG unifier over an uninterpreted `Unit` kind                        | compile        | `ℤ`³                | —                          | [haskell-uom-plugin][uom-plugin]   |
| **dimensional**              | Haskell                | closed type families over a fixed 7-slot `Dimension` kind                              | compile        | `ℤ⁷`, closed basis  | —⁴                         | [haskell-dimensional][dimensional] |
| **uom**                      | Rust                   | macro-generated `Quantity` over `typenum` trait arithmetic                             | compile        | `ℤ⁷`                | flat `Kind` tags⁵          | [rust-uom][rust-uom]               |
| **dimensioned**              | Rust                   | `make_units!` systems over `typenum` `tarr!` exponent arrays                           | compile        | `ℤⁿ` per system⁶    | —                          | [rust-dimensioned][dimensioned]    |
| **mp-units**                 | C++20/23               | `consteval` symbolic expressions (constexpr values of empty types)                     | compile        | `ℚ`, open basis     | `quantity_spec` hierarchy⁷ | [cpp-mp-units][mp-units]           |
| **Boost.Units**              | C++03                  | MPL typelists of (base dimension, `static_rational`) pairs                             | compile        | `ℚ`, open basis     | extra base dimensions⁸     | [cpp-boost-units][boost]           |
| **Au**                       | C++14                  | canonicalized variadic packs + a prime/π magnitude vector space                        | compile        | `ℚ`, open basis     | —⁹                         | [cpp-au][au]                       |
| **quantities / std.units**   | D                      | CTFE dimension values · units-as-types conversion graph                                | compile¹⁰      | `ℚ` (all artifacts) | —                          | [d-quantities][dq]                 |
| **Pint**                     | Python                 | runtime `UnitRegistry` + exponent dictionaries                                         | run            | `ℚ`, open basis     | —                          | [python-pint][pint]                |
| **Unitful.jl**               | Julia                  | `Rational{Int}` exponents as type parameters, multiple dispatch                        | dispatch¹¹     | `ℚ`, open basis     | —                          | [julia-unitful][unitful]           |
| **GNAT dimensionality**      | Ada (GNAT-only)        | implementation-defined aspects; `ℚ` vectors on AST nodes                               | compile        | `ℚ`, ≤ 7 dimensions | —                          | [ada-gnat-dimensions][gnat]        |
| **LeanDimensionalAnalysis**  | Lean 4                 | dependent types; `CommGroup (dimension B E)` proved, not encoded                       | elaboration    | open ring¹²         | —                          | [lean-mathlib-units][lean]         |
| **Wolfram / MATLAB**         | Wolfram Lang. · MATLAB | symbolic `Quantity` data · inert `symunit` factors                                     | run / opt-in¹³ | `ℤ` observed        | temperature only¹⁴         | [wolfram-matlab][wolfram]          |
| **coulomb**                  | Scala                  | opaque-type `Quantity[V,U]=V` + reflective-macro canonicalization (`cansig`)           | compile        | `ℚ`                 | —¹⁵                        | [scala-coulomb][scala-coulomb]     |
| **squants**                  | Scala                  | runtime values; a dimension is a distinct final class; F-bounded nominal typing        | compile¹⁶      | n/a (nominal)       | nominal (free)¹⁷           | [scala-squants][scala-squants]     |
| **unchained**                | Nim                    | compile-time-only macros over an integer `QuantityPower` array                         | compile        | `ℤ`                 | —                          | [nim-unchained][nim-unchained]     |
| **measured**                 | Kotlin                 | `Measure<T:Units>` with nested `UnitsProduct`/`UnitsRatio` generics (no normalization) | compile        | `ℤ` (structural)¹⁸  | —                          | [kotlin-measured][kotlin-measured] |
| **Foundation `Measurement`** | Swift                  | nominal `Measurement<UnitType:Unit>`; per-quantity `Dimension` subclass                | compile¹⁹      | n/a (nominal)       | nominal                    | [swift-units][swift-units]         |
| **UCUM / QUDT**              | JVM · JS               | UCUM string-grammar canonicalization / QUDT dimension-vector IRI; JSR-385 type-API     | run            | `ℤ` (7–8-slot)      | —                          | [ucum-qudt][ucum-qudt]             |

<sub>¹ Surface syntax defaults to integers, but parenthesized `kg^(1/2)` parses and the
shipped solver is rational throughout — diverging from Kennedy's published `ℤ` design.
² `5.0<Hz> + 3.0<Bq>` type-checks; the stdlib's own `SI.fs` defines both as
`second^-1`. ³ Solver-side `ℤ`; the surface `^:` family takes only `Nat` (negative
powers via `/:`, fractional powers inexpressible). Final release 0.4.0.0 (2022);
GHC 9.0–9.4 only. ⁴ `DTorque = DEnergy` and `DActivity = DFrequency` are type synonyms
by construction. ⁵ Kinds separate `Hz`/`Bq`, torque/energy, and temperature
point/interval, but reset to the default kind under `×`/`÷` — comparability tags, not
algebra. ⁶ Gaussian half-integer dimensions handled by rescaling the basis
(`SqrtCentimeter`); dormant since 2022. ⁷ The field's most developed kind system:
lowest-common-ancestor addition, a four-level conversion lattice, kind algebra closed
under `*`/`÷`. ⁸ Nine-base-unit SI (radian, steradian) makes torque ≠ energy, but
`Bq` = `Hz` survives. ⁹ Explicit policy ("No plans at present to support");
`Angle`/`Information` ship as extra base dimensions instead. ¹⁰ Plus a run-time twin:
`quantities`' `QVariant` throws `DimensionException` (GC + exceptions); all three D
artifacts are dormant. ¹¹ Resolved per JIT specialization: a mismatch compiles to an
unconditional `throw`, a match to bare arithmetic — a third category between compile
and run. ¹² Any `CommRing E` — `ℝ` exponents type-check; the artifact is theorems
(`noncomputable`), not executables. ¹³ Wolfram checks eagerly at evaluation (`$Failed`
on incompatibles); MATLAB checks only on an explicit `checkUnits` query returning
logicals, never raising. ¹⁴ Wolfram curates `DegreesCelsius` vs
`DegreesCelsiusDifference`; MATLAB defaults all temperatures to differences.
¹⁵ coulomb has NO Kind mechanism — torque/energy, Hz/Bq, angle/ratio are unguarded
(the sharpest contrast with uom's `Kind`). ¹⁶ squants rejects `Power + Energy` at
compile time as an ordinary nominal type mismatch; value + scale-conversion are
runtime. ¹⁷ nominal typing gives kind-vs-dimension for free — `Torque` ≠ `Energy`
despite identical dimension. ¹⁸ Kotlin has no type-level integers; composite dimensions
are nested generic types (`A·B` ≠ `B·A`), not a normalized exponent vector; no
fractional powers. ¹⁹ Foundation catches `m + s` as a generic-parameter mismatch, but
there is no product type (`m·s` is unnameable); the typed third-party contrast on the
same page (`NeedleInAJayStack/Units`) is runtime-thrown — neither is a full type-level
exponent algebra.</sub>

### Runnable prototypes

Thirteen single-file D programs co-located with this tree, compiled and run by the
repository's `ci` helper on every pass; each header cross-links the theory or system page
it demonstrates. The first three are zero-dependency and pin the core mechanism:

- [`quantity-zn-graded.d`][ex-z] — a minimal `ℤ³`-graded `Quantity`: the dimension is
  its unique normal form as a template value parameter; `metres + seconds` is a
  _checked_ rejection via `static assert(!__traits(compiles, …))`.
- [`quantity-rational-exponents.d`][ex-q] — the `ℚⁿ` variant: CTFE-gcd-normalized
  rational exponents make `sqrt` total (`sqrt(m²)` _is_ the length type) while
  `m^(1/2) + m` stays rejected.
- [`quantity-erasure.d`][ex-e] — representation-level erasure machine-checked
  (`sizeof`/`alignof`/`offsetof`/array layout), with the codegen-identity honesty
  boundary stated.

Ten more are motivated by a physically-based raytracer and, where relevant, composed with
`sparkles:math`'s `Vector`; they prototype the remaining design-space axes:

- [`quantity-affine-torsor.d`][ex-affine] — affine `Point3` vs `Displacement` vs
  `Direction` and `Ray.at(Length t)`; `Point + Point` and `scalar · Point` rejected
  (composition ordering A: `Quantity!(dim, Vec3)` over the real `Vector`).
- [`quantity-kind-tags.d`][ex-kind] — a flat `Kind` tag orthogonal to the exponent
  vector (`Hz` ≠ `Bq`, plane-angle ≠ ratio); kind erased under `×`/`÷`.
- [`quantity-nominal.d`][ex-nominal] — a distinct struct per quantity (kind for free),
  hand-wired products, undeclared product unnameable; poor `Vector` reuse shown.
- [`quantity-runtime-expected.d`][ex-runtime] — a runtime dimension value; fallible ops
  return an `Expected` (`m + s` is a runtime `err`, not a throw).
- [`quantity-unit-in-type.d`][ex-unit] — the unit (rational scale) lives in the type;
  `nm + m` converts lazily at the boundary, not eagerly at construction.
- [`quantity-diagnostics.d`][ex-diag] — a CTFE pretty-printer emits domain-language
  `static assert` prose, contrasted with the raw mangled encoding.
- [`quantity-polymorphism.d`][ex-poly] — dimension-aware generic `dot`/`cross`/
  `magnitude`/`normalize`; forward IFTI inference works, the invert-from-result ceiling
  does not.
- [`quantity-open-basis.d`][ex-open] — an open `(name, exp)` dimension basis; mint a
  custom base dimension without editing a closed vector core.
- [`quantity-logarithmic.d`][ex-log] — EV/stops and dB: log-domain add = linear-domain
  multiply; why logarithmic units resist the exponent-vector model.
- [`quantity-vector-composition.d`][ex-compose] — units ⋈ linear algebra, head to head:
  `Vector!(Quantity, N)` is blocked today (the `isNumeric!T` constraint) while an
  element-generic `Vec` works, yielding a co-design recommendation for `sparkles:math`
  (see the [comparison capstone][comparison]).

---

## Taxonomy

### By checking time

The survey's most load-bearing axis ([comparison][comparison] reads the matrix along
it): _when_ is a dimensional mismatch reported, and by whom.

| Checking time                     | The contract                                                               | Systems                                                                                                                                                                                                                                                                                                |
| --------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Compile — compiler-native**     | the language's own type checker / semantic pass reports the mismatch       | [F#][fsharp] (AG unifier), [GNAT][gnat] (`sem_dim` aspects)                                                                                                                                                                                                                                            |
| **Compile — compiler plugin**     | a plugin extends the stock solver with the abelian-group theory            | [uom-plugin][uom-plugin]                                                                                                                                                                                                                                                                               |
| **Compile — library encoding**    | the host's generic-programming machinery _evaluates_ the group; no solver  | [dimensional][dimensional], [uom][rust-uom], [dimensioned][dimensioned], [mp-units][mp-units], [Boost.Units][boost], [Au][au], [D artifacts][dq], [coulomb][scala-coulomb], [squants][scala-squants], [unchained][nim-unchained], [measured][kotlin-measured], [Foundation `Measurement`][swift-units] |
| **Elaboration (proof assistant)** | homogeneity is a proposition; the output is theorems, not executables      | [Lean][lean]                                                                                                                                                                                                                                                                                           |
| **Dispatch / specialization**     | the check resolves per JIT specialization — mismatch compiles to a `throw` | [Unitful.jl][unitful]                                                                                                                                                                                                                                                                                  |
| **Run**                           | checked when two quantities actually meet (registry / symbolic evaluation) | [Pint][pint], [Wolfram][wolfram], [UCUM / QUDT][ucum-qudt]                                                                                                                                                                                                                                             |
| **Opt-in query**                  | arithmetic never checks; an explicit call reports a logical verdict        | [MATLAB `symunit`][wolfram]                                                                                                                                                                                                                                                                            |

### By exponent domain

Theory published `ℤ`; practice shipped `ℚ` ([comparison § exponents][comparison-exp]);
the [free-abelian-group page][fag] tallies what the extension costs.

| Exponent domain                  | Systems                                                                                                                                     | The documented cost / benefit                                                                           |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| **`ℤ` — closed 7-vector**        | [dimensional][dimensional], [UCUM / QUDT][ucum-qudt] (7–8-slot)                                                                             | `sqrt` of a non-square dimension is a compile error ("fractional powers make little physical sense")    |
| **`ℤ` — per-system vectors**     | [uom][rust-uom], [dimensioned][dimensioned], [uom-plugin][uom-plugin], [unchained][nim-unchained], [measured][kotlin-measured] (structural) | `Length.sqrt()` rejected; `√Hz` named future work; Gaussian basis rescaled to stay integral             |
| **`ℚ` — capped basis**           | [GNAT][gnat] (≤ 7 dimensions)                                                                                                               | `Sqrt` halves vectors; `**` requires a static exponent                                                  |
| **`ℚ` — open basis**             | [F#][fsharp], [mp-units][mp-units], [Boost.Units][boost], [Au][au], [D][dq], [Pint][pint], [Unitful][unitful], [coulomb][scala-coulomb]     | total `sqrt` and honest `√Hz` — at the price of freeness, perfect squares, and gcd structure            |
| **Open ring**                    | [Lean][lean]                                                                                                                                | any `CommRing E`; nothing enforces the physics convention against `ℝ`                                   |
| **`ℤ` observed (uncommitted)**   | [Wolfram / MATLAB][wolfram]                                                                                                                 | captures show integer powers only, with no stated bound                                                 |
| **Nominal — no exponent vector** | [squants][scala-squants], [Foundation `Measurement`][swift-units]                                                                           | a dimension is a class / generic-parameter identity, not an exponent tuple — there is no domain to have |

### By kind treatment

The four-rung ladder from [comparison § kinds][comparison-kinds] — no rung is derived
from theory, and [QUDT][concepts] (kind above dimension, as data) sits off-ladder.

| Rung                          | Mechanism                                                                                             | Systems                                                                                                                                                                                                                                                                                      |
| ----------------------------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1 — nothing**               | the dimension vector is the whole identity; `Hz + Bq` passes                                          | [F#][fsharp], [GNAT][gnat], [dimensional][dimensional], [dimensioned][dimensioned], [uom-plugin][uom-plugin], [Pint][pint], [Unitful][unitful], [Lean][lean], [D artifacts][dq], [coulomb][scala-coulomb], [unchained][nim-unchained], [measured][kotlin-measured], [UCUM / QUDT][ucum-qudt] |
| **2 — extra base dimensions** | mint an axis; splits torque/energy but never `Hz`/`Bq`                                                | [Boost.Units][boost] (radian/steradian), [Au][au] (`Angle`, `Information`), [Wolfram][wolfram] (angle/solid-angle/information/money/person axes)                                                                                                                                             |
| **3 — flat tags**             | nominal comparability tags, erased under `×`/`÷`                                                      | [uom][rust-uom]                                                                                                                                                                                                                                                                              |
| **4 — propagating hierarchy** | a `quantity_spec` tree: LCA addition + a conversion lattice                                           | [mp-units][mp-units]                                                                                                                                                                                                                                                                         |
| **Nominal — kind for free**   | same-dimension quantities are distinct nominal types, so `Torque` ≠ `Energy` with no tag (off-ladder) | [squants][scala-squants], [Foundation `Measurement`][swift-units]                                                                                                                                                                                                                            |

---

## Milestones

A timeline interleaving **theory / formalization milestones** with **system / tooling
milestones**. Every date below is grounded in a landed page of this tree (per-result
provenance in each page's `Sources`); uncertain entries are marked `*`.

| Year      | Theory / formalization milestone                                                                   | System / tooling milestone                                                                                                                                                                                                                                 |
| --------- | -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1892**  | **Vaschy** states the π-theorem ([buckingham-pi][pi])                                              | —                                                                                                                                                                                                                                                          |
| **1914**  | **Buckingham** names it, proving "for special cases" under a sum-of-monomials postulate            | —                                                                                                                                                                                                                                                          |
| **1922**  | **Bridgman** — _Dimensional Analysis_: complete equations, the tacit single-relation restriction   | —                                                                                                                                                                                                                                                          |
| **1953**  | **Drobot** — the first fully rigorous algebraic foundation                                         | —                                                                                                                                                                                                                                                          |
| **1968**  | **Whitney** — _The Mathematics of Physical Quantities_ I & II ([whitney][whitney])                 | —                                                                                                                                                                                                                                                          |
| **1982**  | **Curtis–Logan–Parker** — the π-theorem as frames + group action, no smoothness                    | —                                                                                                                                                                                                                                                          |
| **1991**  | **Wand & O'Keefe** — dimensional inference "fits neatly" into ML type inference                    | —                                                                                                                                                                                                                                                          |
| **1994**  | **Kennedy** — _Dimension Types_ (ESOP); **Hart** — dimensioned matrices (SIAM)                     | ML Kit extension — the first implementation of Kennedy's dimension types ([kennedy-types][kennedy])                                                                                                                                                        |
| 1995–1997 | Kennedy's thesis (TR-391, 1996) and POPL '97 parametricity; Hart's Springer book (1995)            | —                                                                                                                                                                                                                                                          |
| **2003**  | —                                                                                                  | Schabel's MPL dimensional-analysis demo — Boost.Units' origin ([cpp-boost-units][boost])                                                                                                                                                                   |
| **2007**  | **Janyška–Modugno–Vitolo** — positive spaces (arXiv, Oct)                                          | Boost.Units formal review (Feb; after a factor-of-10 compile-time rewrite)                                                                                                                                                                                 |
| **2008**  | —                                                                                                  | Boost.Units 1.0.0 ships in Boost 1.36 (Aug), `ℚ` exponents from the start                                                                                                                                                                                  |
| **2010**  | **Kennedy's CEFP notes** — the shipped F# design, didactically ([kennedy-types][kennedy])          | Boost.Units feature-frozen (v1.2, Boost 1.43)                                                                                                                                                                                                              |
| **2011**  | —                                                                                                  | Nadlinger's `std.units` Phobos RFC (Apr) and push (Dec) — never formally reviewed ([d-quantities][dq])                                                                                                                                                     |
| **2012**  | **Tao** — the tensor-of-lines / weight-space essay (Dec) ([tensor-of-lines][tensor])               | GNAT dimensionality aspects presented (HILT 2012\*); Mathematica 9.0 ships `Quantity` ([wolfram-matlab][wolfram])                                                                                                                                          |
| **2013**  | —                                                                                                  | `quantities` — D's CTFE value-level design (Sicard, 2013–2020) ([d-quantities][dq])                                                                                                                                                                        |
| **2014**  | **Atkey** — parametricity → conservation laws, closing Kennedy's POPL '97 conjecture               | —                                                                                                                                                                                                                                                          |
| **2015**  | **Gundry** — the GHC typechecker-plugin AG unifier ([haskell-uom-plugin][uom-plugin])              | `dimensioned` 0.5.0 moves to `typenum` (Dec) ([rust-dimensioned][dimensioned])                                                                                                                                                                             |
| **2016**  | —                                                                                                  | `units-d` fork created the day the `std.units` thread ends (30 Mar) ([d-quantities][dq]); Foundation `Measurement` ships with Swift 3\* ([swift-units][swift-units])                                                                                       |
| 2017–2018 | —                                                                                                  | MATLAB `symunit`/`checkUnits` (R2017a); `unitConvert` (R2018b)                                                                                                                                                                                             |
| 2018–2019 | **Raposo** — the algebraic structure of quantity calculus, I & II ([whitney][whitney])             | —                                                                                                                                                                                                                                                          |
| 2020–2021 | **Jonsson** (2020 π-foundation; 2021 scalable monoids); **Zapata-Carratalá** — dimensioned algebra | mp-units **P1935R2** before WG21 (2020) ([cpp-mp-units][mp-units]); `squants` v1.8.3 — last tagged release (Aug 2021) ([scala-squants][scala-squants])                                                                                                     |
| **2022**  | —                                                                                                  | `uom-plugin` 0.4.0.0 final (Oct; GHC 9.0–9.4, then dormant); `dimensioned` 0.8.0 final (Apr)                                                                                                                                                               |
| **2023**  | —                                                                                                  | **P2980R1** — the C++29 standardization plan; JSR-385 `unit-api` v2.2 (May) ([ucum-qudt][ucum-qudt])                                                                                                                                                       |
| **2025**  | **Bobbin et al.** — the Lean 4 formalization (arXiv, Sep) ([lean-mathlib-units][lean])             | mp-units v2.5.0 (Dec); `coulomb` v0.9.1 (Sep) ([scala-coulomb][scala-coulomb])                                                                                                                                                                             |
| 2026\*    | —                                                                                                  | **P3045R8** — _Quantities and units library_ (WG21); Kotlin `measured` v0.5.0 (Apr) ([kotlin-measured][kotlin-measured]); indriya v2.2.4, the JSR-385 RI (May) ([ucum-qudt][ucum-qudt]); current pins as reviewed: uom 0.38.0, Unitful 1.28.0, Pint 0.25.3 |

<sub>\* The HILT 2012 attribution (Pucci & Schonberg) is stated on the
[GNAT page][gnat] but has no local artifact behind it; the Swift 3 / macOS 10.12 date
for Foundation `Measurement` is the platform era, not a pinned release; 2026 entries are
current-as-of-review (July 2026).</sub>

---

## Quick navigation

### Suggested reading paths

- **"I'm designing the Sparkles units library."** [concepts][concepts] →
  [kennedy-types][kennedy] + [type-system-mechanisms][mech] → [d-quantities][dq] →
  [comparison § Part IV][comparison-sparkles] (the Sparkles delta and open decisions)
  → the runnable [prototypes](#runnable-prototypes).
- **"I want the mathematics."** [concepts][concepts] → [whitney][whitney] →
  [tensor-of-lines][tensor] → [torsor-representation][torsor] →
  [hart-multidimensional][hart] → [comparison § Part II][comparison-graded] (the
  graded-algebra hypothesis, tested).
- **"I'm implementing a units library (any language)."** [free-abelian-group][fag] →
  [type-system-mechanisms][mech] → [fsharp-uom][fsharp] (the inference ceiling) →
  [cpp-mp-units][mp-units] (kinds, affine, engineered diagnostics) →
  [rust-uom][rust-uom] (the evaluator mainstream) →
  [comparison § Part III][comparison-matrix].
- **"Just the π-theorem."** [buckingham-pi][pi] → [free-abelian-group][fag] (the
  kernel lattice) → [python-pint][pint] (a shipped `pi_theorem` solver).
- **"The metrology / interchange view."** [concepts][concepts] (VIM, SI, UCUM, QUDT) →
  [wolfram-matlab][wolfram] (curated corpora) → [python-pint][pint]
  (registry-as-data).

### Synthesis

- **[Concepts & vocabulary][concepts]** — the metrology-grounded glossary + the
  one-prohibition-six-accounts ledger.
- **[Theory umbrella][theory]** — the organizing question, the catalog, and the
  primitive / exponent-ring / semantic-vs-syntactic splits.
- **[Comparison][comparison]** — the formalizations reconciled, the graded-algebra
  hypothesis tested, the at-a-glance matrix, the consensus, and the Sparkles delta.

---

## Sources

Each deep-dive carries its own primary-source citations — papers and books (pinned as
local artifacts, with editions and page numbers), SHA-pinned source trees for every
surveyed implementation, vendor-doc captures where a system is closed-source, and
local reproductions (compiler transcripts, codegen diffs) for the load-bearing
behavioural claims. The authoritative artifacts behind this index's classifications
are:

- **Foundational theory** — Buckingham 1914; Bridgman 1922; Drobot 1953; Whitney 1968;
  Curtis–Logan–Parker 1982; Wand & O'Keefe 1991; Kennedy 1994–2010; Hart 1994/1995;
  Janyška–Modugno–Vitolo 2007; Tao 2012; Gundry 2015; Raposo 2018/2019; Jonsson
  2020/2021; Zapata-Carratalá 2021; Bobbin et al. 2025 — as cited in the
  [theory subtree][theory].
- **Metrology primaries** — the VIM (JCGM 200:2012), the SI Brochure (9th ed.), NIST
  SP 811, the UCUM specification, and the QUDT ontology — as quoted in
  [concepts][concepts].
- **Per-system sources** — the pinned project source trees, official docs, and papers
  cited in each linked system page.

<!-- References -->

<!-- Within-tree: foundations -->

[concepts]: ./concepts.md
[theory]: ./theory/index.md
[pi]: ./theory/buckingham-pi.md
[whitney]: ./theory/whitney.md
[fag]: ./theory/free-abelian-group.md
[tensor]: ./theory/tensor-of-lines.md
[torsor]: ./theory/torsor-representation.md
[kennedy]: ./theory/kennedy-types.md
[hart]: ./theory/hart-multidimensional.md
[mech]: ./theory/type-system-mechanisms.md

<!-- Within-tree: systems -->

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
[scala-coulomb]: ./scala-coulomb.md
[scala-squants]: ./scala-squants.md
[nim-unchained]: ./nim-unchained.md
[swift-units]: ./swift-units.md
[kotlin-measured]: ./kotlin-measured.md
[ucum-qudt]: ./ucum-qudt.md

<!-- Synthesis -->

[comparison]: ./comparison.md
[comparison-matrix]: ./comparison.md#at-a-glance-matrix
[comparison-exp]: ./comparison.md#2-the-exponent-domain-in-practice
[comparison-kinds]: ./comparison.md#4-kinds
[comparison-graded]: ./comparison.md#part-ii-the-graded-algebra-hypothesis-tested
[comparison-sparkles]: ./comparison.md#part-iv-where-a-sparkles-units-library-would-fit

<!-- Runnable prototypes -->

[ex-z]: ./examples/quantity-zn-graded.d
[ex-q]: ./examples/quantity-rational-exponents.d
[ex-e]: ./examples/quantity-erasure.d
[ex-affine]: ./examples/quantity-affine-torsor.d
[ex-kind]: ./examples/quantity-kind-tags.d
[ex-nominal]: ./examples/quantity-nominal.d
[ex-runtime]: ./examples/quantity-runtime-expected.d
[ex-unit]: ./examples/quantity-unit-in-type.d
[ex-diag]: ./examples/quantity-diagnostics.d
[ex-poly]: ./examples/quantity-polymorphism.d
[ex-open]: ./examples/quantity-open-basis.d
[ex-log]: ./examples/quantity-logarithmic.d
[ex-compose]: ./examples/quantity-vector-composition.d

<!-- Repo guidelines -->

[expected]: ../../guidelines/idioms/expected/index.md
