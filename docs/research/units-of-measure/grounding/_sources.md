# Grounding sources — local-artifact map

Lookup table for the per-page verification pass. Every external citation in the
units-of-measure survey maps here to a **local** artifact: a PDF/HTML capture under
`$REPOS/papers/units-of-measure/` or a repo cloned under `$REPOS` (pinned below).
Web is a fallback **only** for the handful marked _unobtainable_.
`$REPOS` = `/home/petar/code/repos`.

**Acquisition:** 2026-07-03 — 30 papers/spec/web captures + 11 vendor-doc HTML
captures downloaded; 19 repos cloned and SHA-pinned; 4 primaries paywalled with
no open copy → grounded against secondary local artifacts (noted per row).
Provenance details (mirror used, wayback snapshot, sha256 checks) live in the
acquisition manifest notes; the load-bearing facts are repeated here.

**Wave-2 acquisition:** 2026-07-04 — 11 further repos cloned and SHA-pinned for the
deferred wave-2 system pages (Scala, Nim, Swift, Kotlin, and the UCUM/QUDT
interchange implementations); see [Wave-2 source repos](#wave-2-source-repos).

## Source repos (pinned to reviewed HEAD)

| Repo                    | Path                                  | Pinned SHA | As of      |
| ----------------------- | ------------------------------------- | ---------- | ---------- |
| dotnet/fsharp           | `$REPOS/dotnet/fsharp`                | `25c6a37e` | 2026-07-03 |
| uom-plugin              | `$REPOS/haskell/uom-plugin`           | `0b87268`  | 2022-10-09 |
| dimensional             | `$REPOS/haskell/dimensional`          | `f759f32`  | 2026-01-01 |
| units (goldfirere)      | `$REPOS/haskell/units`                | `c06d560`  | 2025-06-27 |
| uom (Rust)              | `$REPOS/rust/uom`                     | `a465bcc`  | 2026-04-04 |
| dimensioned             | `$REPOS/rust/dimensioned`             | `615c908`  | 2022-12-09 |
| mp-units                | `$REPOS/cpp/mp-units`                 | `d7b11de`  | 2026-07-02 |
| au                      | `$REPOS/cpp/au`                       | `50b97bf`  | 2026-07-01 |
| boost-units             | `$REPOS/cpp/boost-units`              | `f39b667`  | 2026-02-07 |
| quantities (D)          | `$REPOS/dlang/quantities`             | `3cb3205`  | 2020-01-27 |
| units-d                 | `$REPOS/dlang/units-d`                | `9589ac9`  | 2021-03-13 |
| nadlinger std.units ¹   | `$REPOS/dlang/nadlinger-std-units`    | `4a7279a`  | 2011-12-10 |
| pint                    | `$REPOS/python/pint`                  | `7a927b4`  | 2026-06-10 |
| astropy                 | `$REPOS/python/astropy`               | `8104d4c`  | 2026-07-02 |
| Unitful.jl ²            | `$REPOS/julia/Unitful.jl`             | `829da44`  | 2026-06-22 |
| gcc (GNAT, sparse) ³    | `$REPOS/ada/gcc`                      | `8363c23`  | 2026-07-03 |
| mathlib4                | `$REPOS/lean/mathlib4`                | `ab4e75d`  | 2026-07-03 |
| LeanDimensionalAnalysis | `$REPOS/lean/LeanDimensionalAnalysis` | `de263ee`  | 2025-09-11 |
| qudt-public-repo        | `$REPOS/misc/qudt-public-repo`        | `bb9e04d`  | 2026-07-02 |

¹ Not a clone: raw `units.d` (1992 lines) + `si.d` pinned to the `units` branch
HEAD `4a7279a` of `dnadlinger/phobos` (byte-verified against the commit-pinned
raw URL), plus two HTML captures — the D forum RFC announcement thread and the
author's `klickverbot.at/code/units/` project page.
² Ownership moved: `PainterQubits/Unitful.jl` → `JuliaPhysics/Unitful.jl`
(cloned from the canonical JuliaPhysics URL).
³ `--depth 1 --filter=blob:none --sparse`, `sparse-checkout set gcc/ada` (~110 MB).

In-repo docs/manuals to use for quote-grounding: fsharp
`src/Compiler/Checking/ConstraintSolver.fs` (`UnifyMeasures` L801,
`SimplifyMeasuresInType` L839) + `src/Compiler/TypedTree/TypedTree.fs`
(`type Measure`, L4696); uom `src/system.rs` (the `system!` macro) +
`src/quantity.rs`; dimensioned `src/make_units.rs` + `src/dimensions.rs`;
mp-units `docs/` (MkDocs) + `src/core/include/mp-units/framework/{quantity.h,dimension.h,quantity_spec.h}`;
au `docs/` (esp. `discussion/`) + `au/{quantity.hh,unit_of_measure.hh,dimension.hh}`;
boost-units `doc/units.qbk` + `include/boost/units/{quantity.hpp,dimension.hpp,base_dimension.hpp}`;
GNAT `gcc/ada/sem_dim.ads`/`.adb` (compiler checking) +
`gcc/ada/libgnat/s-di*.ads` (`System.Dim` runtime, e.g. `s-digemk.ads` declaring
the MKS `Dimension_System`); astropy `astropy/units/`;
LeanDimensionalAnalysis `DimensionalAnalysis/{Basic,Basic_Multiplicative,Dimensions,ISQ}.lean`
(`CommGroup (dimension B E)` at `Basic.lean:234`; Buckingham-Pi sections at
`Basic.lean:259` / `Basic_Multiplicative.lean:270`); mathlib4 — honest negative
finding: nothing dedicated to physical units/dimensional analysis (`Units` =
invertible monoid elements); closest building block
`Mathlib/GroupTheory/FreeAbelianGroup.lean`.

## Wave-2 source repos

Pins for the wave-2 system pages (deferred systems, acquired 2026-07-04). Same
conventions as the wave-1 table above.

| Repo                        | Path                                     | Pinned SHA | As of      |
| --------------------------- | ---------------------------------------- | ---------- | ---------- |
| coulomb (Scala)             | `$REPOS/scala/coulomb`                   | `681442a`  | 2026-06-22 |
| squants (Scala)             | `$REPOS/scala/squants`                   | `29aa57f`  | 2026-03-17 |
| unchained (Nim)             | `$REPOS/nim/unchained`                   | `426d72a`  | 2025-11-20 |
| swift-corelibs-foundation ⁴ | `$REPOS/swift/swift-corelibs-foundation` | `cd04666`  | 2026-07-01 |
| Units (Swift, secondary) ⁵  | `$REPOS/swift/Units`                     | `08ab9be`  | 2026-07-03 |
| measured (Kotlin)           | `$REPOS/kotlin/measured`                 | `3f65500`  | 2026-04-05 |
| Ucum-java (FHIR) ⁶          | `$REPOS/java/ucum-java`                  | `70106f4`  | 2026-04-28 |
| ucum-lhc (JS)               | `$REPOS/js/ucum-lhc`                     | `3713cd1`  | 2026-06-16 |
| indriya (JSR-385 RI)        | `$REPOS/java/indriya`                    | `c3dc219`  | 2026-05-18 |
| unit-api (JSR-385 API)      | `$REPOS/java/unit-api`                   | `79682ff`  | 2026-05-19 |
| qudtlib-java                | `$REPOS/java/qudtlib-java`               | `8530b43`  | 2026-02-11 |

⁴ `--depth 1 --filter=blob:none --sparse`, `sparse-checkout set Sources/Foundation`
— Foundation's `Measurement`/`Unit`/`Dimension`, the standard Swift units facility
(the primary for the Swift page). ⁵ `NeedleInAJayStack/Units` — a runtime-checked
typed-units library, pinned as the compile-time-safety contrast foil (Foundation is
the primary). ⁶ The canonical UCUM grammar parser on the JVM is `FHIR/Ucum-java`
(Health Intersections / Grahame Grieve; Maven `org.fhir:ucum`) —
`unitsofmeasurement/ucum-java` does not exist.

In-repo files for wave-2 quote-grounding: coulomb
`core/src/main/scala/coulomb/{quantity.scala,infra/meta.scala,define/define.scala}`
(opaque `Quantity[V, U]`; the `cansig` canonical-signature macro; the compile error
`report.error(…"not convertable"…)` at `meta.scala:140`; compile-fail tests under
`core/src/test/scala/coulomb/`); squants
`shared/src/main/scala/squants/{Quantity.scala,Dimension.scala,UnitOfMeasure.scala,space/Length.scala,thermal/Temperature.scala}`
(F-bounded `Quantity[A <: Quantity[A]]`; runtime `conversionFactor`); unchained
`src/unchained/{core_types.nim,quantities.nim,units.nim,si_units.nim}`
(`QuantityPower` int-exponent array; the `+` macro `error("Different quantities…")`
at `units.nim:265`); Swift Foundation
`Sources/Foundation/{Measurement.swift,Unit.swift}` (`Measurement<UnitType: Unit>`;
per-quantity `Dimension` subclasses; `UnitConverterLinear` coefficient+constant) +
`$REPOS/swift/Units` `Sources/Units/{Unit/Unit.swift,Measurement/Measurement.swift,Quantity.swift}`
(runtime `[Quantity: Int]` map; throwing `+`); Kotlin measured
`src/commonMain/kotlin/io/nacular/measured/units/Units.kt` (`Measure<T: Units>`;
`UnitsProduct`/`UnitsRatio` nested generics; `plus` at `:113`); UCUM/QUDT — ucum-java
`src/main/java/org/fhir/ucum/{Lexer,ExpressionParser,Converter,Canonical,BaseUnit,UcumEssenceService}.java`
(canonical-string commensurability; `UcumException` at `UcumEssenceService.java:304`),
ucum-lhc `source/{unitString,dimension,unit,ucumLhcUtils}.js` (numeric 7-slot
`dimVec_`; `Error` throw at `unit.js:400`), indriya
`src/main/java/tech/units/indriya/{AbstractUnit.java,unit/UnitDimension.java}` +
unit-api `src/main/java/javax/measure/{Unit,Quantity,Dimension,IncommensurableException}.java`
(`Map<Dimension, Integer>` exponents; checked `IncommensurableException`),
qudtlib-java
`qudtlib-model/src/main/java/io/github/qudtlib/model/{Unit.java,DimensionVector.java}`
(QUDT dimension-vector IRI; `InconvertibleQuantitiesException`).

## Papers present — `$REPOS/papers/units-of-measure/`

All PDFs have an extractable text layer (use
`nix shell nixpkgs#poppler-utils -c pdftotext`) **except**
`drobot-1953-…` (image-only ICM scan — OCR locally or fetch the IMPAN PDF via
DOI `10.4064/sm-14-1-84-99` if quotes are needed). `bridgman-1922-…` and
`curtis-logan-parker-1982-…` are OCR with minor noise. `whitney-…-excerpt.pdf`
is a 2-page re-typeset excerpt of Part I's introduction only.

```
atkey-2014-parametricity-conservation-laws-popl.pdf
baez-torsors-made-easy-web.html
bipm-2019-si-brochure-9th-ed.pdf
bobbin-2025-formalizing-dimensional-analysis-lean-arxiv.pdf
bridgman-1922-dimensional-analysis-book.pdf
buckingham-1914-similar-systems-physrev.pdf
curtis-logan-parker-1982-pi-theorem-laa.pdf
drobot-1953-foundations-dimensional-analysis-studia.pdf
fsharp-spec-4.1.pdf
gundry-2015-typechecker-plugin-uom-haskell.pdf
hart-1994-dimensioned-matrices-siam.pdf
hart-1995-multidimensional-analysis-frontmatter-springer.pdf
hart-1995-multidimensional-analysis-website.html
janyska-modugno-vitolo-2007-semi-vector-spaces-units-arxiv.pdf
jcgm-2012-vim-3rd-ed.pdf
jonsson-2020-algebraic-foundation-dimensional-analysis-arxiv.pdf
jonsson-2021-magnitudes-scalable-monoids-quantity-spaces-arxiv.pdf
kennedy-1994-dimension-types-esop.pdf
kennedy-1996-programming-languages-dimensions-thesis.pdf
kennedy-1997-relational-parametricity-units-popl.pdf
kennedy-2010-types-units-of-measure-cefp.pdf
mpusz-2020-p1935r2-physical-units-wg21.html
mpusz-2023-p2980r1-quantities-plan-wg21.html
mpusz-2026-p3045r8-quantities-and-units-library-wg21.html
nist-2008-sp811-guide-si.pdf
raposo-2018-algebraic-structure-quantity-calculus-msr.pdf
raposo-2019-algebraic-structure-quantity-calculus-ii-msr.pdf
tao-2012-formalisation-dimensional-analysis-blog.html
ucum-spec.html
wand-okeefe-1991-automatic-dimensional-inference-lpar.pdf
whitney-1968-physical-quantities-i-monthly-excerpt.pdf
zapata-carratala-2021-dimensioned-algebra-arxiv.pdf
```

Vendor docs (closed-source systems + GNAT manuals) —
`$REPOS/papers/units-of-measure/vendor-docs/`:

```
gnat-rm-implementation-defined-aspects.html
gnat-ugn-dimensionality-analysis.html
matlab-checkunits.html
matlab-symunit.html
matlab-unitconvert.html
matlab-units-of-measurement.html
wolfram-knownunitq.html
wolfram-quantity.html
wolfram-unitconvert.html
wolfram-unitdimensions.html
wolfram-units-guide.html
```

(The four MATLAB captures are Wayback snapshots — mathworks.com bot-walls curl;
`matlab-checkunits.html` is a 2019 capture, the others 2024. WG21 revisions
actually resolved by `wg21.link` on 2026-07-03: P1935R2 (2020), P2980R1 (2023),
P3045R8 (2026). SI Brochure fetched: 9th ed., update V4.01 (June 2026). The
Kennedy ESOP'94 + CEFP'10 author copies were recovered from Kennedy's defunct
MSR page via Wayback; Raposo 2018 is the published MSR version via Wayback —
the live `measurement.sk` host fails TLS.)

## Unobtainable primaries → secondary grounding

| Citation                                          | Why                                  | Ground instead against                                                                                                                                       |
| ------------------------------------------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Whitney 1968, Part I (Amer. Math. Monthly 75(2))  | JSTOR / Taylor & Francis paywall     | local 2-page excerpt `whitney-1968-…-i-monthly-excerpt.pdf` (Whitney's own framing) + restatements in `kennedy-1996-…-thesis.pdf` and `raposo-2018-…msr.pdf` |
| Whitney 1968, Part II (Amer. Math. Monthly 75(3)) | JSTOR / Taylor & Francis paywall     | claim-by-claim restatements in `raposo-2018-…msr.pdf` + `raposo-2019-…ii-msr.pdf` (both explicitly build on Part II)                                         |
| ISO 80000-1:2022                                  | ISO paywall; no legitimate open copy | `bipm-2019-si-brochure-9th-ed.pdf` + `nist-2008-sp811-guide-si.pdf`                                                                                          |
| Hart 1995, _Multidimensional Analysis_ (Springer) | Book paywall                         | `hart-1995-…-frontmatter-springer.pdf` + `hart-1994-dimensioned-matrices-siam.pdf` + `hart-1995-…-website.html`                                              |

## Per-page citation → artifact

Format: page → {claim source : local artifact}. "secondary" = see table above.
Official manuals/blogs/Wikipedia reground in the primary paper or repo named.
(Initial mapping from the acquisition pass; refined as pages land.)

- **theory/whitney.md** — Whitney I & II → secondary; Whitney's own words → the local excerpt; modern restatements → `raposo-2018`/`raposo-2019`, `jonsson-2021` (quantity spaces lineage).
- **theory/buckingham-pi.md** — Buckingham 1914 → `buckingham-1914`; Bridgman 1922 → `bridgman-1922`; rigorous rank–nullity treatment → `curtis-logan-parker-1982`; Drobot 1953 → `drobot-1953` (image-only; quotes need OCR); amended π results → `jonsson-2020`.
- **theory/free-abelian-group.md** — Kennedy thesis ch. on dimension groups → `kennedy-1996`; quantity spaces / scalable monoids → `jonsson-2020`, `jonsson-2021`; mechanization → `$REPOS/lean/LeanDimensionalAnalysis` + `bobbin-2025`; mathlib building block → `Mathlib/GroupTheory/FreeAbelianGroup.lean`.
- **theory/tensor-of-lines.md** — Tao 2012 → `tao-2012-…-blog.html`; semi-vector spaces → `janyska-modugno-vitolo-2007`.
- **theory/torsor-representation.md** — Baez → `baez-torsors-made-easy-web.html`; dimensioned algebra → `zapata-carratala-2021`; Tao's torsor remarks → `tao-2012`.
- **theory/kennedy-types.md** — ESOP'94 → `kennedy-1994`; thesis → `kennedy-1996`; POPL'97 parametricity → `kennedy-1997`; CEFP notes → `kennedy-2010`; AG-unification in practice → `gundry-2015`, fsharp `ConstraintSolver.fs`; precursor → `wand-okeefe-1991`; frontier → `atkey-2014`.
- **theory/hart-multidimensional.md** — Hart 1995 book → secondary; Hart 1994 SIAM → `hart-1994-dimensioned-matrices-siam.pdf`.
- **theory/type-system-mechanisms.md** — `kennedy-2010`, `gundry-2015`, `kennedy-1997` + the mechanism evidence in the pinned system repos (uom `typenum` exponents, dimensioned `make_units.rs`, mp-units `quantity_spec.h`, F# `TypedTree.fs`, uom-plugin/units type families).
- **fsharp-uom.md** — `$REPOS/dotnet/fsharp` + `fsharp-spec-4.1.pdf` §9 + `kennedy-2010`.
- **haskell-uom-plugin.md** — `$REPOS/haskell/uom-plugin` + `gundry-2015`.
- **haskell-dimensional.md** — `$REPOS/haskell/dimensional` (+ contrast `$REPOS/haskell/units`).
- **rust-uom.md** — `$REPOS/rust/uom`.
- **rust-dimensioned.md** — `$REPOS/rust/dimensioned`.
- **cpp-mp-units.md** — `$REPOS/cpp/mp-units` + `mpusz-2020-p1935r2` + `mpusz-2023-p2980r1` + `mpusz-2026-p3045r8`.
- **cpp-boost-units.md** — `$REPOS/cpp/boost-units`.
- **cpp-au.md** — `$REPOS/cpp/au`.
- **d-quantities.md** — `$REPOS/dlang/quantities`, `$REPOS/dlang/units-d`, `$REPOS/dlang/nadlinger-std-units` (code + RFC thread + project page).
- **python-pint.md** — `$REPOS/python/pint` (+ aside `$REPOS/python/astropy` `astropy/units/`).
- **julia-unitful.md** — `$REPOS/julia/Unitful.jl`.
- **ada-gnat-dimensions.md** — `$REPOS/ada/gcc` (`sem_dim.*`, `libgnat/s-di*`) + `vendor-docs/gnat-rm-…` + `vendor-docs/gnat-ugn-…`.
- **lean-mathlib-units.md** — `$REPOS/lean/LeanDimensionalAnalysis` + `bobbin-2025` + the mathlib4 negative finding.
- **wolfram-matlab.md** — `vendor-docs/wolfram-*.html` + `vendor-docs/matlab-*.html` only (closed source; docs-grounded).
- **scala-coulomb.md** (wave 2) — `$REPOS/scala/coulomb` (`quantity.scala`, `infra/meta.scala`, `define/define.scala`, `conversion/{unit,coefficient}.scala`, `deltaquantity.scala` + compile-fail tests under `core/src/test/scala/coulomb/`).
- **scala-squants.md** (wave 2) — `$REPOS/scala/squants` (`Quantity.scala`, `Dimension.scala`, `UnitOfMeasure.scala`, `space/Length.scala`, `thermal/Temperature.scala`, `README.md` type-mismatch block).
- **nim-unchained.md** (wave 2) — `$REPOS/nim/unchained` (`core_types.nim`, `quantities.nim`, `units.nim`, `si_units.nim`, `README.org`, `unchained.nimble`).
- **swift-units.md** (wave 2) — `$REPOS/swift/swift-corelibs-foundation` (`Sources/Foundation/{Measurement,Unit}.swift`) as primary + `$REPOS/swift/Units` (`Sources/Units/…`) as the runtime-checked contrast.
- **kotlin-measured.md** (wave 2) — `$REPOS/kotlin/measured` (`src/commonMain/kotlin/io/nacular/measured/units/Units.kt`, `README.md`, `gradle/libs.versions.toml`).
- **ucum-qudt.md** (wave 2) — `$REPOS/java/ucum-java` (FHIR UCUM), `$REPOS/js/ucum-lhc` (NLM UCUM), `$REPOS/java/{indriya,unit-api}` (JSR-385), `$REPOS/java/qudtlib-java` (QUDT); the UCUM spec (`ucum-spec.html`) and QUDT ontology (`$REPOS/misc/qudt-public-repo`) are grounded as the interchange/data poles in `concepts.md`.
- **concepts.md** — `jcgm-2012-vim-3rd-ed`, `bipm-2019-si-brochure-9th-ed`, `nist-2008-sp811-guide-si` (ISO-80000 secondary), `ucum-spec.html`, `$REPOS/misc/qudt-public-repo`.
