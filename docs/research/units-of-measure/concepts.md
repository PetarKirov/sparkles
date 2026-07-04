# Units of Measure: Concepts & Vocabulary

Quantities of different dimensions multiply freely — `1 m × 1 s` is an unremarkable
`metre-second` — yet they do not add: every formalization in the
[theory subtree][theory-index] and every system in this survey treats `1 m + 1 s` as a
defect, while disagreeing profoundly about what _kind_ of defect it is. **Why is the
product total and the sum partial?** That asymmetry is the spine of the whole
[catalog][umbrella]: each theory page answers a shared protocol question about it, each system page
documents how a checker enforces it, and the [capstone comparison][comparison]
reconciles the answers. This page fixes the _vocabulary_ those pages lean on — _quantity_
and _quantity value_, _kind of quantity_, _dimension_, _unit_, _system of quantities_ vs
_system of units_, _base_ / _derived_ / _coherent_ / _off-system_ units, _quantity of
dimension one_, and the recurring _affine_ and _logarithmic_ edge cases — as the
metrology primaries define them, and records where the mathematical literature and the
surveyed libraries part ways with metrology (and where metrology parts ways with
itself).

> [!NOTE]
> **The primaries.** The definitional authority throughout is the **VIM** — the
> _International Vocabulary of Metrology_, 3rd edition ([JCGM 200:2012][vim], identical
> in content to ISO/IEC Guide 99), quoted by clause number below. The **SI Brochure**,
> 9th edition ([BIPM 2019, v4.01][si-brochure]), supplies the SI-specific definitions
> (coherence, the dimensional product, `rad`/`sr`, `Np`/`B`/`dB`). **ISO 80000-1:2022**
> — the ISQ's own standard — is [paywalled][iso80000] with no legitimate open copy, so
> wherever ISQ specifics matter this survey grounds them in the SI Brochure and in
> NIST's guide to the SI ([SP 811, 2008 edition][sp811]), the open secondaries; claims
> that only ISO 80000-1 itself could settle are flagged. The machine-facing angle comes
> from the [UCUM specification][ucum] (case-sensitive unit codes for electronic
> interchange) and the [QUDT ontology][qudt] (units as RDF data; repo pinned locally at
> `bb9e04d`).

---

## One prohibition, six accounts

What, exactly, is wrong with `1 m + 1 s`? The survey's sources give answers that are
genuinely incompatible — not paraphrases of one answer — and the disagreement is the
single most useful orientation device for a reader of this tree:

- **Inexpressible** — [Whitney][whitney]'s measurement models are disjoint carriers
  equipped only with physically warranted operations, so `m + l` is not an error the
  axioms rule out; it is a string with no denotation. A heterogeneous equation is not
  _false_ but _unformulable_. (And yet Whitney's own counting example computes
  `6(2 bl + 3 ck) = 12 bl + 18 ck` distributively, without ever naming the structure
  that sum lives in.)
- **Ill-typed but semantically defined — and not invariant** — in
  [Kennedy's type system][kennedy] the mixed sum is a static type error, but the erased
  program underneath it is an ordinary rational addition that never gets stuck. What
  fails is _equivariance_: the sum's value depends on the arbitrary choice of units,
  whereas multiplication commutes with every rescaling. "Meaningless" is rendered as
  "defined but not invariant".
- **Total, but exiled from every weight space** — in the graded reading
  ([tensor of lines][tensor], [torsor / scaling torus][torsor]) the ambient algebra
  happily contains `1 m + 1 s` as a "hybrid" element lying in no weight space; what
  physical laws demand is _homogeneity_ (equivariance under the scaling action), and
  Tao's convex-hull criterion measures exactly how little law-like content the hybrid
  part carries.
- **Moved up a level, into the vector space** — [Hart][hart] keeps scalar cross-type
  addition undefined by definition, but makes the heterogeneous _aggregate_ legitimate
  as a **dimensioned vector**: a tuple with one component per type, i.e. a point of the
  product (equivalently the direct sum) of the fibers. The formal sums Whitney computed
  with but never housed are, up to notation, Hart's vectors — the
  [comparison][comparison] works through that identification.
- **Raised as an error at evaluation** — the runtime systems define the sum and make it
  _fail_: [Pint][pint] raises `DimensionalityError` at the moment two incompatible
  quantities actually meet; [Unitful][unitful] resolves the check per JIT
  specialization, compiling a mismatch into an unconditional `throw`.
- **Not even checked until asked** — MATLAB's `symunit` lets `1*u.m + 1*u.s` flow
  through arithmetic as inert symbolic factors; only an explicit `checkUnits` call
  reports (as a `logical`, not an error) that the expression is inconsistent
  ([wolfram-matlab][wolfram]).

No winner is crowned here. The full reconciliation — including Bridgman's demonstration
that the prohibition is a _conditional theorem_ rather than an axiom, and the Lean
mechanization's total-but-unknowable rendering via `Classical.epsilon` — lives in the
comparison's [seven-readings ledger][comparison-seven]; the checkable type-system
renderings are catalogued in the [mechanisms bridge][mech].

---

## Quantity — and quantity value

The VIM's opening definition, the one every other clause builds on:

> "**quantity** — property of a phenomenon, body, or substance, where the property has
> a magnitude that can be expressed as a number and a reference" — [VIM][vim] 1.1

Three of its notes carry weight for this survey. Note 2: "A reference can be a
measurement unit, a measurement procedure, a reference material, or a combination of
such" — metrology's quantity concept is deliberately _wider_ than unit-referenced
measurement (Rockwell hardness is a quantity whose reference is a procedure; UCUM's
[arbitrary units](#ucum-units-as-case-sensitive-codes) are the interchange rendering of
that width, and no surveyed type system models it). Note 5: "A quantity as defined here
is a scalar" — vectors and tensors are quantities only componentwise, which is exactly
the stance [Hart][hart] attacks as under-ambitious. And the VIM keeps a **separate
concept** for the number-and-reference pair:

> "**quantity value** — number and reference together expressing magnitude of a
> quantity" — [VIM][vim] 1.19

That quantity/quantity-value distinction is the cleanest lens on the
[formalizations' deepest split][comparison]: [Whitney][whitney] and the
[tensor-of-lines][tensor] school axiomatize VIM's _quantity_ — the property itself,
prior to any number — while [Buckingham and Bridgman][pi] "deliberately conflate a
quantity with its numerical measure" and [Hart][hart]'s `(f, g)` pairs formalize VIM's
_quantity value_ (a number with a group-element reference). [Kennedy][kennedy]'s
quantities are a third thing: bare rationals at run time whose reference lives only in
the type, erased before evaluation. When a theory page says "quantity", it matters
which of these three it means; the pages say so, and this glossary is the place the
words are held apart.

---

## Unit — and the unit–quantity circle

> "**measurement unit** — real scalar quantity, defined and adopted by convention, with
> which any other quantity of the same kind can be compared to express the ratio of the
> two quantities as a number" — [VIM][vim] 1.9

Two structural facts hide in this sentence. First, the definition is **circular with
1.1 by design**: a unit is itself a _quantity_, while a quantity's magnitude is
expressed by reference to a _unit_ (1.1 Note 2). The VIM is a concept system, not an
axiomatization, and tolerates the circle; the formalizations each break it at a chosen
point, and where they break it is what [distinguishes them][comparison]:

| Where the circle is cut         | Unit becomes…                                                                                              | Page                                         |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| Quantities primitive            | any element "kept fixed for a period" — pure bookkeeping, no algebraic privilege                           | [Whitney][whitney]                           |
| Carriers (1-D lines) primitive  | a (positive) basis vector — JMV: "a semi-basis … is called a unit"                                         | [tensor][tensor]                             |
| The group action primitive      | a **torsor point**; a whole system of units = a section `u : D → R`, never canonical                       | [torsor][torsor]                             |
| Unit syntax primitive           | a unit _variable_ — base units and polymorphism distinguished only as free vs bound occurrences            | [Kennedy][kennedy]                           |
| Neither — the pair is primitive | **no formal object at all** (a recorded silence: writing `(f, g)` has already chosen a unit per dimension) | [Hart][hart]                                 |
| Operational (interchange)       | a code with conversion data — UCUM's `(r, û)` magnitude-and-vector pair, QUDT's `conversionMultiplier`     | [below](#ucum-units-as-case-sensitive-codes) |

Second, the ratio phrasing — "any other quantity of the **same kind**" — makes
[kind](#kind-of-quantity) _prior to_ unit in the metrology concept order: comparability
comes first, units presuppose it. Almost every surveyed type system inverts this,
deriving comparability _from_ unit (or dimension) equality; the consequences are the
kind cluster's story below.

---

## Dimension

> "**quantity dimension** — expression of the dependence of a quantity on the base
> quantities of a system of quantities as a product of powers of factors corresponding
> to the base quantities, omitting any numerical factor" — [VIM][vim] 1.7

Metrology's dimension is a piece of **notation** — an expression like `dim F = LMT⁻²`,
derived from the quantity's defining equations and read modulo the "omitting any
numerical factor" convention. The SI Brochure fixes the SI's instance of it:

> "In general the dimension of any quantity `Q` is written in the form of a dimensional
> product, `dim Q = T^α L^β M^γ I^δ Θ^ε N^ζ J^η` where the exponents α, β, γ, δ, ε, ζ
> and η, which are generally small integers, which can be positive, negative, or zero,
> are called the dimensional exponents." — [SI Brochure][si-brochure] §2.3.3

The mathematical literature reads the same object structurally: a dimension is an
**element of the free abelian group** on the base dimensions (`≅ ℤ⁷` for the ISQ), the
dimensional product is the group operation, and "omitting any numerical factor" is the
quotient that [Buckingham's tradition][pi] undoes by conflating quantities with
measures. The [free-abelian-group page][fag] develops this reading; the
[mechanisms bridge][mech] catalogues its type-system encodings; the CI-verified
[`quantity-zn-graded.d`][ex-z] prototype implements it directly. Three frictions
between the metrology text and the group-theoretic reading are worth pinning:

- **The basis is conventional, and so is its order.** VIM 1.7 Note 5 writes the product
  `dim Q = L^α M^β T^γ I^δ Θ^ε N^ζ J^η`; the SI Brochure's own §2.3.3 writes
  `T^α L^β M^γ …`; QUDT's vector labels run `A…E…L…I…M…H…T…D`
  ([below](#qudt-units-as-an-ontology)). The two flagship metrology primaries disagree
  on display order because the group has no canonical ordered basis — a triviality in
  the algebra that becomes load-bearing in positional encodings
  ([`dimensioned`][dimensioned]'s `tarr!` arrays, and every diagnostics spine that
  leaks index positions). Base _change_ — e.g. `{L, T, M} → {L, T, F}` — is a
  `GL(n, ℤ)` action the VIM has no vocabulary for at all ([fag][fag]).
- **"Generally small integers" is not a commitment.** The VIM's very own Example 3
  computes a fractional exponent — a pendulum analysis ending in
  `dim C(g) = L^(−1/2) T` — two paragraphs below a definition whose SI rendering says
  "generally small integers". Whether exponents live in `ℤ`, `ℚ`, or `ℝ` is precisely
  the axis the formalizations never settled and practice quietly resolved toward `ℚ`
  ([comparison, Part I & III][comparison]; [`quantity-rational-exponents.d`][ex-q]).
- **Dimension is not the whole identity.** VIM 1.7 Note 4 states it as a three-bullet
  asymmetry: same kind ⟹ same dimension; different dimension ⟹ different kind; same
  dimension ⇏ same kind. Every formalization whose dimension _is_ the quantity's whole
  identity collapses the third bullet — the [kind cluster](#kind-of-quantity) next.

For quantities whose exponents are all zero, the VIM keeps a dedicated term —
"**quantity of dimension one**" (VIM 1.8, with "dimensionless quantity" retained "for
historical reasons") — whose surprisingly sharp edges are deferred to the
[edge cases](#angles-and-quantities-of-dimension-one) below.

---

## Kind of quantity

The one metrology concept most surveyed type systems drop — and the survey's widest
theory/practice gap ([comparison § kinds][comparison-kinds]):

> "**kind of quantity, kind** — aspect common to mutually comparable quantities" —
> [VIM][vim] 1.2

The VIM immediately concedes the concept's softness, in exactly these words:

> "NOTE 1 The division of ‘quantity’ according to ‘kind of quantity’ is to some extent
> arbitrary." — [VIM][vim] 1.2, Note 1

and then states the relationship to dimension that no free-abelian-group encoding can
express:

> "NOTE 2 Quantities of the same kind within a given system of quantities have the same
> quantity dimension. However, quantities of the same dimension are not necessarily of
> the same kind. — EXAMPLE The quantities moment of force and energy are, by
> convention, not regarded as being of the same kind, although they have the same
> dimension. Similarly for heat capacity and entropy, as well as for number of
> entities, relative permeability, and mass fraction." — [VIM][vim] 1.2, Note 2

Kind reaches into the unit system itself: VIM 1.9 Note 2 records that "in some cases
special measurement unit names are restricted to be used with quantities of a specific
kind only. For example, the measurement unit ‘second to the power minus one’ (1/s) is
called hertz (Hz) when used for frequencies and becquerel (Bq) when used for activities
of radionuclides" — and the SI Brochure's Table 4 turns the restriction into normative
language ("The hertz shall only be used for periodic phenomena and the becquerel shall
only be used for stochastic processes…"). The Brochure is explicit that some of these
distinctions exist for safety:

> "The special names becquerel, gray and sievert were specifically introduced because
> of the dangers to human health that might arise from mistakes involving the units
> reciprocal second and joule per kilogram, in case the latter units were incorrectly
> taken to identify the different quantities involved." — [SI Brochure][si-brochure] §2.3.4

NIST SP 811 adds the complementary rule — kind information belongs to the _quantity_,
never to the unit: "it is incorrect to attach letters or other symbols to the unit in
order to provide information about the quantity or its conditions of measurement.
Instead, the letters or other symbols should be attached to the quantity"
(`Vmax = 1000 V`, not `V = 1000 Vmax`; [SP 811][sp811] §7.4).

How the rest of the survey treats kind:

- **The theory corpus drops it, knowingly.** Where dimension is a group element, the
  group element is the quantity's entire identity: torque ≡ energy, `Hz` ≡ `Bq`.
  Kennedy names the torque/energy problem and provides no mechanism; Jonsson turns the
  collapse into a definition (same kind _iff_ commensurable); the only productive
  theoretical mechanism — Tao's structure-group enlargement — still never separates
  scalar same-dimension pairs like `Hz`/`Bq`
  ([comparison § kinds][comparison-kinds]).
- **Most type systems inherit the collapse.** `5.0<Hz> + 3.0<Bq>` type-checks in
  [F#][fsharp] — the stdlib's own `SI.fs` defines both as `second^-1` — and the same
  holds across [GNAT][gnat], [dimensional][dimensional], [dimensioned][dimensioned],
  [Pint][pint], [Unitful][unitful], [Lean][lean], and the D artifacts ([d-quantities][dq]).
- **The engineering resurrections are mutually incompatible.**
  [`uom`][rust-uom]'s flat `Kind` tags separate `Hz` from `Bq` but reset to the default
  kind under `×`/`÷`; [Boost.Units][boost] and [Au][au] mint extra base dimensions
  (radian/steradian; `Angle`, `Information`), which splits torque from energy but can
  never split anything sharing a genuine dimension; [mp-units][mp-units] rebuilds the
  ISQ itself as a `quantity_spec` hierarchy with kind algebra — and its documentation
  grounds the design by quoting this very VIM text, arbitrariness caveat included.
- **The ontology puts kind at the centre.** In [QUDT](#qudt-units-as-an-ontology)
  a unit _must_ name its quantity kind and the dimension vector hangs off the kind —
  the exact inversion of the dimension-only type systems.

---

## System of quantities vs system of units

Metrology maintains **two parallel systems**, related but never identified:

> "**system of quantities** — set of quantities together with a set of
> non-contradictory equations relating those quantities" — [VIM][vim] 1.3

> "**system of units** — set of base units and derived units, together with their
> multiples and submultiples, defined in accordance with given rules, for a given
> system of quantities" — [VIM][vim] 1.13

The **ISQ** (VIM 1.6) is a system of quantities — seven base quantities and the
equations of physics; the **SI** (VIM 1.16) is a system of units _based on_ the ISQ.
Each side has its own base/derived split. A **base quantity** is a member of "a
conventionally chosen subset … where no subset quantity can be expressed in terms of
the others" (VIM 1.4) — the note makes the independence multiplicative ("cannot be
expressed as a product of powers of the other base quantities"), which the
[free-abelian-group page][fag] reads as linear independence in the exponent lattice,
and whose failure modes (is the chosen basis actually of full rank for the problem at
hand?) are the [π-theorem][pi]'s bread and butter. A **derived quantity** is "defined
in terms of the base quantities" (VIM 1.5); a **base unit** is "adopted by convention
for a base quantity" (VIM 1.10 — with Note 1's "in each coherent system of units,
there is only one base unit for each base quantity", i.e. the [torsor page][torsor]'s
section `u : D → R` picks exactly one point per fiber); a **derived unit** is simply "a
measurement unit for a derived quantity" (VIM 1.11).

Most surveyed libraries collapse the quantity level into the unit level — their only
notion of "what this value is" is its unit (or its dimension vector). The exceptions
prove the distinction is implementable: [mp-units][mp-units] models the ISQ as a
first-class `quantity_spec` tree _above_ its units layer, and
[QUDT](#qudt-units-as-an-ontology) stores quantity kinds and units as separate node
types. Meanwhile the formalizations mostly axiomatize the quantity side and let units
be derived décor — the exact opposite collapse ([comparison, Part I][comparison]).

---

## Coherent, off-system, and accepted units

> "**coherent derived unit** — derived unit that, for a given system of quantities and
> for a chosen set of base units, is a product of powers of base units with no other
> proportionality factor than one" — [VIM][vim] 1.12

The SI Brochure explains what the property buys:

> "The word 'coherent' here means that equations between the numerical values of
> quantities take exactly the same form as the equations between the quantities
> themselves." — [SI Brochure][si-brochure] §2.3.4

Coherence is relative twice over (VIM 1.12 Note 2: "only with respect to a particular
system of quantities and a given set of base units"; Note 3's example: `cm/s` is
coherent in CGS, not in the SI), and it is fragile: prefixes destroy it ("when prefixes are used with SI units,
the resulting units are no longer coherent, because the prefix introduces a numerical
factor other than one" — §2.3.4), with the kilogram as the standing historical joke
("the kilogram is the only coherent SI unit that includes a prefix in its name and
symbol", §3). In the [torsor page][torsor]'s vocabulary this all becomes one sentence:
a system of units is a section `u : D → R` of the dimension fibration, and coherence is
the demand that the section be **multiplicative** — `u(d·e) = u(d)·u(e)` with factor
one — which is why "numerical-value equations keep the form of quantity equations" and
why normalize-to-base libraries ([`uom`][rust-uom], [`quantities`][dq]) can do all
arithmetic in one trivialization and convert only at the boundaries
([comparison, Part III][comparison]).

Outside a system sit the **off-system units** — "measurement unit that does not belong
to a given system of units" (VIM 1.15; its examples are the electronvolt and
day/hour/minute) — and, cutting across that, the _accepted_ ones: units "outside the
SI but accepted for use with the SI" (VIM 1.11's `km/h` example). The 9th-edition
Brochure's chapter 4 gathers these into Table 8 ("Non-SI units") with a shrug of
realism: "It is recognized that some non-SI units are widely used and that this is
expected to continue for many years." The practice side mirrors the taxonomy exactly:
registry systems carry the whole Table-8 world as data ([Pint][pint]'s
`default_en.txt`), unit-in-type systems mint off-system units with exact
rational/symbolic conversion factors ([Au][au]'s magnitude vectors, [Unitful][unitful]'s
`Rational{Int}` powers — the [comparison][comparison]'s "exact conversion factors are
kept exact" consensus), and minimal systems like [F#][fsharp] ship no metrology at all — every
unit is off-system because there is no system.

---

## UCUM: units as case-sensitive codes

The [Unified Code for Units of Measure][ucum] is what the unit concept looks like when
the consumer is a wire protocol: "a code system intended to include all units of
measures being contemporarily used in international science, engineering, and business
… to facilitate unambiguous electronic communication of quantities together with their
units" ([UCUM][ucum], Introduction). Its angles, in survey terms:

- **Case-sensitivity as a correctness feature.** UCUM's predecessor standards
  (ISO 2955, ANSI X3.50) were case-insensitive and paid with name collisions — "`cd`
  means candela and centi-day and `PEV` means peta-volt and pico-electronvolt"
  ([UCUM][ucum], Introduction). UCUM's primary symbols are case-sensitive (`Cel` is not
  `cel`); a separate case-insensitive variant exists for degraded channels and is
  declared "incompatible to the case sensitive symbols" (§3). The lesson generalizes:
  every registry-driven system in the survey ([Pint][pint], [Wolfram][wolfram]) owns an
  equivalent symbol-disambiguation problem.
- **The algebra is stated in the spec, not implied.** UCUM defines equality `=` and
  commensurability `~` as equivalence relations (§17); units are the `=`-classes and
  "(`U`, ·) is an Abelian group" (§18); **dimensions are the `~`-classes** (§19); any system
  is generated by "a finite set `B` of mutually independent base units", against which
  every unit is "a pair (`r`, `û`) of magnitude `r` and dimension `û`" (§20). This is
  the [free-abelian-group][fag] picture published as an interchange spec — with the
  spec-level twist that conformance is semantic: full implementations "must compare
  unit expressions by their semantics, i.e. they must detect equivalence for different
  expressions with the same meaning" (§2).
- **The `metric` predicate** marks which atoms take prefixes (§11): all base units are
  metric, customary units never are, and — decisively — "a unit must be a quantity on a
  ratio scale in order to be metric".
- **Special units quarantine the non-ratio scales.** Interval- and logarithmic-scale
  symbols (`Cel`, `[degF]`, `B`, `Np`, `dB`) "do not represent proper units as elements
  of the group (`U`, ·)"; each is a triple `(u, fₛ, fₛ⁻¹)` — a corresponding proper
  unit plus a conversion function pair — and "in theory, special units cannot take part
  in any algebraic operations" (§§21–22). UCUM here disagrees with the VIM, which
  counts the decibel among "special names" for units of dimension one (VIM 1.9 Note 3);
  the [edge cases](#the-recurring-edge-cases) below inherit the dispute. The spec's
  editorial aside on the CCU's 1995 decision to allow prefixes on `°C` is the sharpest
  sentence in the corpus on the affine problem: "One wonders why the CGPM keeps the
  Celsius temperature in the SI as it is superfluous and in a unique way incoherent
  with the SI" (§22).
- **Arbitrary units** (`[IU]`, procedure-defined assay units) are "not 'of any specific
  dimension' and are not 'commensurable with' any other unit" (§24) — the interchange
  rendering of VIM 1.1 Note 2's procedure-referenced quantities. Curly-brace
  annotations carry human context but "do not contribute to the semantics of the unit"
  — UCUM's mechanized form of [SP 811][sp811] §7.4's no-information-on-the-unit rule.

---

## QUDT: units as an ontology

[QUDT][qudt] ("Quantities, Units, Dimensions and Types") is the semantic-web
codification: everything the static libraries put into types is here **RDF data** —
classes, properties, and SHACL constraints in a public repo ([pinned
locally][qudt-repo] at `bb9e04d`). Its ontological commitments answer this page's
vocabulary questions in an instructively different order:

- **Kind is mandatory; dimension hangs off the kind.** A `qudt:Unit` must carry at
  least one `qudt:hasQuantityKind` (`owl:minCardinality 1` in the schema,
  `sh:minCount 1` in the SHACL shapes), and a
  `qudt:QuantityKind` — "any observable property that can be measured and quantified
  numerically … Less familiar examples include currency, interest rate, price to
  earning ratio, and information capacity" (`SCHEMA_QUDT.ttl`) — must carry exactly one
  `qudt:hasDimensionVector`. Where the dimension-only type systems make the exponent
  vector the identity and drop kind, QUDT makes kind the identity and demotes the
  vector to one of its properties.
- **The `Hz`/`Bq` split is data.** Via `unitForQuantityKind`, `unit:HZ` points at
  `quantitykind:Frequency` and `unit:BQ` at `quantitykind:Activity`, while
  both carry the same dimension vector `qkdv:A0E0L0I0M0H0T-1D0`. The becquerel's own
  description note reads: "both the becquerel and the hertz are basically defined as
  one event per second, yet they measure different things"
  (`VOCAB_QUDT-UNITS-ALL.ttl`). Likewise one vector node,
  `qkdv:A0E0L2I0M1H0T-2D0`, lists **both** `quantitykind:Energy` and
  `quantitykind:Torque` as reference kinds — the VIM 1.2 Note 2 example encoded as a
  many-kinds-per-vector graph shape.
- **An eight-slot dimension vector.** QUDT's vectors carry the ISQ seven **plus a `D`
  slot**: `quantitykind:Dimensionless` — and `unit:RAD` — get `…T0D1`, not the all-zero
  vector. Dimensionless-ness is a coordinate, not the group identity: an engineering
  move (it keeps dimensionless kinds from colliding with the empty product) that no
  formalization in the [theory subtree][theory-index] endorses, and a concrete
  instance of the [angle problem](#angles-and-quantities-of-dimension-one) being
  patched at the data layer.
- **Conversion is two numbers.** `qudt:conversionMultiplier` and — for the affine cases
  — `qudt:conversionOffset` (`unit:DEG_C` carries `conversionOffset 273.15`) put the
  point/difference distinction of the [affine edge case](#affine-quantities-points-vs-differences)
  into plain properties, with none of the operational safety of a
  point/difference type split: what a consumer does with the offset is its own affair.
- **The bridge to UCUM is a property.** A unit may carry at most one `qudt:ucumCode` —
  the ontology and the wire code deliberately cross-reference rather than duplicate.

QUDT is thus the run-time-registry pole of the [mechanisms spectrum][mech] taken to its
limit: a units "library" with no checker at all, only queryable structure — and,
precisely because nothing must type-check, the richest kind vocabulary in the survey.

---

## The recurring edge cases

Three quantity shapes recur throughout the survey wherever a page has an
"Expressiveness edges" section; they are defined once here, as the canonical link
target. What unites them: each is a place where the plain
multiply-freely/add-within-a-fiber picture — the consensus core of both metrology and
the formalizations — stops describing the physics people actually record.

### Affine quantities: points vs differences

Celsius temperature is the SI's own affine quantity: not a magnitude but a
_displacement from a conventional origin_,

> "it remains common practice to express a thermodynamic temperature, symbol `T`, in
> terms of its difference from the reference temperature `T₀ = 273.15 K` … This
> difference is called the Celsius temperature, symbol `t`, which is defined by the
> quantity equation `t = T − T₀`." — [SI Brochure][si-brochure] §2.3.1

with the degree Celsius "by definition equal in magnitude to the unit kelvin" — and the
Brochure concedes the algebraic consequence in one line: "The unit degree Celsius is
only coherent when expressing temperature differences" (§2.3.4). Points (temperatures,
timestamps, positions, voltages) support point − point → difference and
point ± difference → point, but not point + point, not scalar × point, and their zero
is a convention, not an identity. The theory home is the [torsor page][torsor]: each
fiber's points form a torsor under its **additive** group — a second, different torsor
from the multiplicative torsor of unit choices — and [Whitney][whitney] had the
structure in 1968 (his Part I §6 time-point space `T*` with a biray `T` of
translations). UCUM quarantines the same cases as
[special units](#ucum-units-as-case-sensitive-codes) on interval scales; QUDT stores
them as a `conversionOffset`.

Practice converged independently on the point/difference split wherever temperature is
handled correctly — [Pint][pint]'s auto-generated `delta_` units and
`OffsetUnitCalculusError`, [Unitful][unitful]'s `@affineunit` + `AffineError` (for any
dimension, not just temperature), [mp-units][mp-units]'s `quantity_point` with typed
origins, [Au][au]'s `QuantityPoint`, D's 2011 `std.units` `AffineUnit`
([d-quantities][dq]), C++'s own `std::chrono` `time_point`/`duration` pair
([boost-units][boost]) — while the systems that skip it exhibit the two standard
failure modes: a linear-unit costume (`Celsius_Temperature` as a Kelvin vector with a
`°C` display symbol in [GNAT][gnat]; `enum celsius = kelvin` in `quantities` —
[d-quantities][dq]) or a documented trap (MATLAB's `0*u.Celsius` collapsing to a
dimensionless `0` — [wolfram-matlab][wolfram]). The convergence and its exceptions are
tabulated in [comparison § affine][comparison-affine].

### Logarithmic quantities: `Np`, `B`, `dB`

The SI Brochure itself ships three logarithmic units — in Table 8 ("Non-SI units"),
with a footnote where their conversion value should be:

> "The neper, bel and decibel are used to express values of specified logarithmic ratio
> quantities. When using these units, it is important that the quantity be specified,
> and that any reference value used be specified. … The statement `LX = m dB = (m/10) B`
> (where `m` is a number) is interpreted to mean that `m = 10 lg(X/X₀)`." —
> [SI Brochure][si-brochure], Table 8, note (m)

A decibel value is thus parameterized twice — by the quantity it describes _and_ by a
reference value `X₀` — and the primaries disagree on what the thing even is: the VIM
counts the decibel among the special names for units of dimension one (VIM 1.9 Note 3),
while UCUM expels it from the unit group as a special unit on a logarithmic scale
(§21). The theory subtree has **no account at all** — the [torsor page][torsor] records
the fourfold silence of its sources — and practice is nearly as thin: [Pint][pint]
(documented Beta) and [Unitful][unitful] (`@logscale`; `dB`, `Np`, referenced levels
like `dBm`) are the only shipped implementations in the survey, with
[mp-units][mp-units] carrying an in-source `TODO` ("how to support those? // neper //
bel // decibel") and the rest silent ([comparison § affine/log][comparison-affine]).

### Angles and quantities of dimension one

> "**quantity of dimension one** — quantity for which all the exponents of the factors
> corresponding to the base quantities in its quantity dimension are zero" —
> [VIM][vim] 1.8

In the group reading this is the identity element, and everything at it is invariant
under all rescalings — which is exactly why it is a dumping ground: length ratios,
amounts-of-substance fractions, counts of entities, Mach numbers, and _angles_ all land
on the same group element, and [Kennedy's Π-theorem-as-type-isomorphism][kennedy] says
every unit-polymorphic program factors through it. The SI's treatment of angles is an
explicit, documented compromise:

> "For reasons of history and convention, plane and solid angles are treated within the
> SI as quantities with the unit one." — [SI Brochure][si-brochure] §2.3.3

with the kind problem conceded in Table 4's footnote on the radian: `rad = m/m` "is not
intrinsic and may be misleading since angle is not the same kind of quantity as other
length ratios" (note (b); mutatis mutandis for the steradian, note (c)). So `rad` and
`sr` are dimension-one units with kind-restricted use — the same shape as `Hz`/`Bq`,
one level down. The systems split three ways: follow the SI and pay the documented
`2π` trap between frequency and angular frequency ([Pint][pint]); promote angle to a
base dimension and leave the SI ([Boost.Units][boost]'s nine-base-unit system,
[Au][au]'s `Angle`); or tag kinds above an SI-conformant dimension
([`uom`][rust-uom], [mp-units][mp-units]). QUDT gives `unit:RAD` the `D¹` slot of its
eight-component vector plus an angle quantity kind — both workarounds at once. No
option is cost-free; the trade-offs are the [comparison][comparison]'s angle-policy
row.

---

## The vocabulary at a glance

| Term                        | VIM/SI says                                                                                           | The mathematical formalizations say                                                                                   | Where they part ways                                                                                                                                 |
| --------------------------- | ----------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Quantity**                | property with "a magnitude that can be expressed as a number and a reference" (VIM 1.1)               | element of a model ([Whitney][whitney]); of a 1-D line ([tensor][tensor]); a typed bare rational ([Kennedy][kennedy]) | metrology's reference can be a _procedure_ or _material_; every formalization assumes unit-referenced ratio scales                                   |
| **Quantity value**          | "number and reference together" (VIM 1.19), a concept distinct from the quantity                      | [Hart][hart]'s `(f, g)` pair; [Buckingham][pi]'s measure-numbers — the pair _is_ the primitive                        | half the formalizations axiomatize the quantity, half the quantity value; the trivialization gap between them is the [torsor page][torsor]'s theorem |
| **Unit**                    | "real scalar quantity, defined and adopted by convention" (VIM 1.9) — itself a quantity, circularly   | basis vector, torsor point, unit variable, or nothing at all — each formalization cuts the 1.1↔1.9 circle elsewhere   | metrology tolerates the circularity; the formalizations must not, and where they cut it is what distinguishes them                                   |
| **Dimension**               | an _expression_: "product of powers of factors … omitting any numerical factor" (VIM 1.7)             | an element of the free abelian group `ℤⁿ` (or `ℚⁿ`) on the base dimensions ([fag][fag])                               | exponent ring (`ℤ`/`ℚ`/`ℝ`) unsettled — VIM's own Example 3 is fractional while the SI says "generally small integers"                               |
| **Kind of quantity**        | "aspect common to mutually comparable quantities" (VIM 1.2) — partitioning "to some extent arbitrary" | mostly **dropped**: the group element is the whole identity; Jonsson defines kind _as_ commensurability               | the survey's widest gap: metrology restricts `Hz`/`Bq` by kind; only engineering overlays ([mp-units][mp-units], [uom][rust-uom], QUDT) recover it   |
| **System of quantities**    | quantities + "non-contradictory equations relating those quantities" (VIM 1.3); the ISQ               | usually implicit — the equations become the grading's algebra; only the basis survives                                | mp-units and QUDT model it explicitly; every other system collapses it into the unit system                                                          |
| **System of units**         | base + derived units + multiples "for a given system of quantities" (VIM 1.13); the SI                | a section `u : D → R` of the dimension fibration — one torsor point per fiber ([torsor][torsor])                      | the section is never canonical; metrology's "adopted by convention" is the theory's non-canonicity, agreed on by both sides                          |
| **Coherent unit**           | product of powers of base units "with no other proportionality factor than one" (VIM 1.12; SI §2.3.4) | the section being multiplicative — numerical-value equations keep the form of quantity equations                      | prefixes break coherence in metrology; in the algebra a prefix is just another scalar — coherence is invisible to the group structure                |
| **Off-system / accepted**   | "does not belong to a given system of units" (VIM 1.15); Table 8's tolerated non-SI units             | no concept — all units are interchangeable trivializations                                                            | registries ([Pint][pint]) encode Table 8 as data; typed systems either normalize it away or carry exact factors                                      |
| **Dimension one**           | all exponents zero (VIM 1.8); `rad`, `sr` there "for reasons of history and convention"               | the group identity; the target of the Π-theorem's factorization ([pi][pi], [kennedy][kennedy])                        | SI's own footnotes concede angle is "not the same kind" as other ratios; the identity element can't say so                                           |
| **Affine quantity** (`°C`)  | `t = T − T₀`; `°C` "only coherent when expressing temperature differences" (SI §2.3.4)                | an **additive** torsor per fiber — a second torsor the graded picture does not supply ([torsor][torsor])              | UCUM calls Celsius temperature "in a unique way incoherent with the SI"; practice re-invents point/difference splits seven times over                |
| **Logarithmic unit** (`dB`) | a special name for a dimension-one unit (VIM 1.9 Note 3); Table 8 with a footnote for a value (SI)    | **no account** — a recorded fourfold silence ([torsor][torsor])                                                       | VIM counts `dB` a unit; UCUM expels it from the unit group; the theory corpus says nothing at all                                                    |

---

## Sources

- **JCGM 200:2012** — _International vocabulary of metrology — Basic and general
  concepts and associated terms (VIM)_, 3rd edition (identical to ISO/IEC Guide 99).
  Clauses 1.1–1.19 quoted throughout. ([PDF][vim]; local:
  `jcgm-2012-vim-3rd-ed.pdf`.)
- **BIPM** — _The International System of Units (SI)_, SI Brochure, 9th edition
  (2019; update V4.01, June 2026). §§2.3.1–2.3.4 and Table 4, §3, chapter 4/Table 8
  with note (m). ([publication page][si-brochure]; local:
  `bipm-2019-si-brochure-9th-ed.pdf`.)
- **NIST SP 811** (2008 edition) — _Guide for the Use of the International System of
  Units (SI)_; the survey's open stand-in, together with the SI Brochure, for the
  paywalled **ISO 80000-1:2022** ([catalog page][iso80000]). §7.4 quoted.
  ([DOI][sp811]; local: `nist-2008-sp811-guide-si.pdf`.)
- **UCUM** — _The Unified Code for Units of Measure_ specification. §§1–4 (grammar,
  case sensitivity), §§16–20 (semantics: the unit group, commensurability,
  dimensions), §§21–24 (special and arbitrary units). ([spec][ucum]; local:
  `ucum-spec.html`.)
- **QUDT** — schema `SCHEMA_QUDT.ttl` (class definitions and SHACL cardinalities) and
  vocabularies `VOCAB_QUDT-QUANTITY-KINDS-ALL.ttl`, `VOCAB_QUDT-UNITS-ALL.ttl`,
  `VOCAB_QUDT-DIMENSION-VECTORS.ttl` (`HZ`/`BQ`, `DEG_C`, `RAD`,
  torque/energy). ([qudt.org][qudt] · [repository][qudt-repo]; local clone pinned at
  `bb9e04d`, 2026-07-02.)
- **In-tree pages** carry the survey-side citations quoted here: the
  [theory deep-dives][theory-index] ([Whitney][whitney], [Buckingham π][pi],
  [free abelian group][fag], [tensor of lines][tensor], [torsor][torsor],
  [Kennedy][kennedy], [Hart][hart], [mechanisms][mech]), the fourteen system pages,
  and the [comparison capstone][comparison].

<!-- References -->

<!-- Tree umbrella / synthesis -->

[umbrella]: ./index.md
[comparison]: ./comparison.md
[comparison-seven]: ./comparison.md#seven-readings-of-one-prohibition
[comparison-kinds]: ./comparison.md#kinds-the-shared-blind-spot
[comparison-affine]: ./comparison.md#3-affine-and-logarithmic-quantities
[theory-index]: ./theory/index.md

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

<!-- External primary sources -->

[vim]: https://www.bipm.org/documents/20126/2071204/JCGM_200_2012.pdf
[si-brochure]: https://www.bipm.org/en/publications/si-brochure
[sp811]: https://doi.org/10.6028/NIST.SP.811e2008
[iso80000]: https://www.iso.org/standard/76921.html
[ucum]: https://ucum.org/ucum
[qudt]: https://qudt.org/
[qudt-repo]: https://github.com/qudt/qudt-public-repo
