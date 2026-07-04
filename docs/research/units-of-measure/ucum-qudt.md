# UCUM & QUDT interchange implementations

The survey's **interchange / data pole**: five libraries that consume two standards
— the [UCUM][concepts] string grammar and the [QUDT][concepts] RDF ontology — rather
than inventing a units DSL. The headline finding unifies all five: **mixing
incommensurable units (the `m + s` experiment) is caught at run time by a thrown
exception, never by the type checker.** Dimensional safety here is a data-driven
run-time check (string equality of canonical forms, integer-vector equality, or IRI
equality), not a type-level guarantee. The one partial exception — Java's generic
`Unit<Q>` in the JSR-385 middle layer — still defers all arithmetic and conversion
checking to run time.

| Library                                  | Ecosystem         | Role in the pole                                                | License           | Pinned clone                                        |
| ---------------------------------------- | ----------------- | --------------------------------------------------------------- | ----------------- | --------------------------------------------------- |
| [FHIR/Ucum-java][ucumj-repo]             | JVM (Java 17)     | UCUM grammar → **canonical-string** reduction                   | BSD-3-Clause      | `$REPOS/java/ucum-java` @ `70106f4` (2026-04-28)    |
| [LHNCBC/ucum-lhc][lhc-repo]              | JavaScript (Node) | UCUM grammar → **integer 7-vector** reduction                   | Custom NLM/US-Gov | `$REPOS/js/ucum-lhc` @ `3713cd1` (2026-06-16)       |
| [qudtlib/qudtlib-java][qudt-repo]        | JVM (Java 17)     | QUDT ontology → **IRI dimension-vector + (multiplier, offset)** | Apache-2.0        | `$REPOS/java/qudtlib-java` @ `8530b43` (2026-02-11) |
| [unitsofmeasurement/unit-api][uapi-repo] | JVM (Java 8)      | JSR-385 **type-API** both poles adapt to                        | BSD-3-Clause      | `$REPOS/java/unit-api` @ `79682ff` (2026-05-19)     |
| [unitsofmeasurement/indriya][ind-repo]   | JVM (Java 8)      | JSR-385 **reference implementation**                            | BSD-3-Clause      | `$REPOS/java/indriya` @ `c3dc219` (2026-05-18)      |

| Field            | Value                                                                                                                                                                                                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Documentation    | [`org.fhir:ucum` Maven Central][ucumj-maven] · [`@lhncbc/ucum-lhc` npm][lhc-npm] · [`io.github.qudtlib:qudtlib` Maven][qudt-maven] · [`javax.measure:unit-api` Maven][uapi-maven] · [`tech.units:indriya` Maven][ind-maven]                                               |
| Key authors      | Grahame Grieve / Health Intersections (ucum-java) · Lee Mericle / NLM-NIH LHNCBC, after Gunther Schadow's Java version (ucum-lhc) · Florian Kleedorfer / qudtlib (qudtlib-java) · Jean-Marie Dautelle, Werner Keil, Otavio Santana (JSR-385: unit-api + indriya)          |
| Category         | [Runtime, data/ontology-driven checking][concepts] — the interchange pole (contrast the type-level pole: [`uom`][uom], [F#][fsharp])                                                                                                                                      |
| Mechanism        | UCUM: parse a UCUM code to a `Term` tree, reduce to a canonical dimension form, compare forms. QUDT: look up each unit's precomputed dimension-vector IRI and `(multiplier, offset)` harvested from RDF, compare IRIs. JSR-385: `Dimension` interface + `Unit<Q>` generic |
| Exponent domain  | ucum-java: `int` exponents (`Canonical.CanonicalUnit.exponent`). ucum-lhc: `ℤ⁷` integer vector (`dimVec_`, length 7). qudtlib: `float[8]` — **fractional exponents representable** in the dimension-vector IRI. JSR-385: `Map<Dimension, Integer>` (integer)              |
| Checking time    | **Run time, in all five.** No compile-time dimensional guarantee — except JSR-385's `Unit<Q>` generic parameter, which prevents storing a `Unit<Length>` in a `Unit<Time>` reference but does not check arithmetic or conversion                                          |
| Analyzed version | ucum-java `70106f4` (2026-04-28; release `org.fhir:ucum` `1.0.10`) · ucum-lhc `3713cd1` (2026-06-16; npm `7.1.8`) · qudtlib-java `8530b43` (2026-02-11; `7.2.x`) · unit-api `79682ff` (2026-05-19; JSR-385 `v2.2`) · indriya `c3dc219` (2026-05-18; `v2.2.4` "Rainbow")   |
| Latest release   | ucum-java `1.0.10` (2025-04-22) · ucum-lhc `7.1.8` · qudtlib `7.2.x` · unit-api `2.2` (2023-05-20) · indriya `2.2.4` (2026-05-17)                                                                                                                                         |

> [!NOTE]
> This is the survey's only **five-library** page and its only **standards-implementation**
> page: every other system invents its own units model, whereas these consume the
> [UCUM][concepts] grammar and the [QUDT][concepts] ontology (the standards themselves
> are covered in [concepts][concepts]; this page covers the code that reads them).
> The page has three internal poles — a **string-grammar pole** (the two UCUM parsers,
> which split on how they reduce a parsed unit: [ucum-java][ucumj-repo] to a canonical
> _string_, [ucum-lhc][lhc-repo] to an _integer 7-vector_), an **ontology/RDF pole**
> ([qudtlib][qudt-repo], an IRI dimension-vector plus a declared `(multiplier, offset)`
> per unit), and the **JSR-385 middle** ([unit-api][uapi-repo] interfaces +
> [indriya][ind-repo] reference impl, the only one of the five with any compile-time
> type guard). All five sit with [Pint][pint], [Swift `Units`][swift], and
> [Wolfram/MATLAB][wolfram] in the **runtime-checked** family of this survey — see the
> [comparison capstone][comparison] and the [mechanism taxonomy][mechanisms].

---

## Overview

### What it solves

These libraries answer a different question from the typed systems. The typed pole
([`uom`][uom], [F#][fsharp], [mp-units][mpunits]) asks _"can the compiler prove this
program is dimensionally sound?"_. The interchange pole asks _"given a unit string or
ontology IRI produced by some other system — a lab instrument, an HL7/FHIR message,
an RDF knowledge graph — can I validate it, decide whether two such units are
comparable, and convert between them at run time?"_. The ucum-java README states the
service surface directly ([`README.md`][ucumj-readme] L11–17):

> "The library provides a set of services around UCUM:
>
> - validate a UCUM unit (and also against a particular base unit)
> - decide whether one unit can be converted/compared to another
> - translate a quantity from one unit to another
> - prepare a human-readable display of a unit
> - multiply 2 quantities together"

QUDT's library frames itself as an ontology-to-code bridge — the RDF is compiled into
a self-contained artifact ([`README.md`][qudt-readme] L1–10):

> "QUDTLib: Java Unit Conversion Library based on QUDT … Makes all conversions and
> related functionality defined by the excellent QUDT ontology available in a
> **self-contained jar** with **no external dependencies**. … 1745 units, such as
> second, Fahrenheit, or light year …"

The JSR-385 layer is the common vocabulary the JVM poles adapt to: a standardized
`javax.measure` interface set (`Unit<Q>`, `Quantity<Q>`, `Dimension`,
`UnitConverter`) so that a UCUM-backed or QUDT-backed unit source can present the same
API to a downstream consumer.

### Design philosophy

**Validation and conversion as data operations, not type operations.** In every one
of the five, a "unit" is a run-time value (a `Term` tree, a `Unit` object, a
`Dimension` vector) built from parsed text or ontology data, and commensurability is a
_computed predicate_ over that value. Nothing about a metre versus a second is known
to the compiler; the distinction is a fact the library recomputes on demand. This is
the deliberate opposite of the type-level pole and is what lets these libraries ingest
units whose identity is not known until run time (a UCUM code arriving in a message, a
QUDT IRI dereferenced from a graph).

**Two reductions of the same UCUM grammar.** The string-grammar pole is a within-pole
contrast worth stating up front. Both UCUM parsers accept the same grammar and both
reduce a parsed unit to base dimensions, but they store the reduced form differently:
ucum-java keeps a **sorted list of `(BaseUnit, exponent)` pairs** rendered back to a
_canonical string_ and compares strings; ucum-lhc keeps a **fixed-length integer
exponent vector** and compares vectors element-wise. The
[free-abelian-group model][fag] is the same; the concrete representation is not.

**QUDT precomputes; the RDF never runs.** qudtlib's philosophy is that all the
ontology reasoning happens at _code-generation_ time (in the `qudtlib-ingest-qudt` /
`*-gen` modules, not shipped in the runtime jar): each unit arrives with its dimension
vector already resolved to an IRI and its SI relationship already reduced to a
`(conversionMultiplier, conversionOffset)` pair. At run time there is no SPARQL, no
triple store — just field lookups and arithmetic.

---

## How it works

### UCUM string-grammar pole

**ucum-java** is a hand-written recursive-descent pipeline. The `Lexer`
([`Lexer.java`][ucumj-lexer] L37, L67–69, L155) tokenizes a UCUM code into `SOLIDUS`
(`/`), `PERIOD` (`.`), parentheses, numbers, symbols, and `{annotations}`; the
`ExpressionParser` ([`ExpressionParser.java`][ucumj-parser] L48–116) turns tokens into
a `Term` tree via `parse` → `parseTerm` → `parseComp` → `parseSymbol`. The dimensional
work is in `Converter.normalise`, which reduces a `Term` to a `Canonical` — a `Decimal`
magnitude plus a `List<CanonicalUnit>` — recursively expanding defined units to base
units, then **collating equal bases by summing their exponents, dropping zero
exponents, and sorting by base code** ([`Converter.java`][ucumj-conv] L100–125):

```java
// ucum-java: Converter.java L100-118 (collate equal bases, drop zeros) — illustration
for (int i = result.getUnits().size()-1; i >= 0; i--) {
    CanonicalUnit sf = result.getUnits().get(i);
    for (int j = i-1; j >= 0; j--) {
        CanonicalUnit st = result.getUnits().get(j);
        if (st.getBase() == sf.getBase()) {
            st.setExponent(sf.getExponent()+st.getExponent());   // sum exponents
            result.getUnits().remove(i);
            break;
        }
    }
}
// … then remove exponent==0 entries, then Collections.sort by base code
```

A `CanonicalUnit` is `{ BaseUnit base; int exponent; }` ([`Canonical.java`][ucumj-canon]
L42–64), and a `BaseUnit` carries a single dimension character `dim`
([`BaseUnit.java`][ucumj-base] L42). The public API (`UcumEssenceService`) exposes
`convert`, `isComparable`, and `getCanonicalUnits`.

**ucum-lhc** parses through `UnitString.parseString` → `_parseTheString` →
`_makeUnitsArray` ([`unitString.js`][lhc-ustr] L143, L264, L288) but reduces to a
genuine numeric exponent vector. The `Dimension` class wraps a length-7 integer array
`dimVec_` with add/subtract/multiply/invert/equals operations
([`dimension.js`][lhc-dim] L1–4):

> "This class implements an object containing the vector of exponents for a unit and
> its operations for addition, subtraction, and multiplication with a scalar."

The vector length is fixed at 7 (`Ucum.dimLen_: 7`, [`config.js`][lhc-config] L25), and
equality is element-wise over that length ([`dimension.js`][lhc-dim] L252–266). Public
entry points (`convertUnitTo`, `convertToBaseUnits`, `commensurablesList`) live in
`ucumLhcUtils.js` ([`ucumLhcUtils.js`][lhc-utils] L295, L464, L682).

### QUDT ontology pole

**qudtlib** stores per-unit data harvested from RDF. A `Unit` carries a
`conversionMultiplier` and `conversionOffset` (both `BigDecimal`) plus a
`dimensionVectorIri` ([`Unit.java`][qudt-unit] L60–61, L70). Conversion applies the
affine formula in `DECIMAL128` ([`Unit.java`][qudt-unit] L419–430):

```java
// qudtlib-java: Unit.java L419-430 (affine conversion) — illustration
BigDecimal result =
        value.add(fromOffset)
                .multiply(fromMultiplier, MathContext.DECIMAL128)
                .divide(toMultiplier, MathContext.DECIMAL128)
                .subtract(toOffset)
                .stripTrailingZeros();
```

The dimension vector is a `DimensionVector` over eight slots
`{'A','E','L','I','M','H','T','D'}` — amount, electric current, length, luminous
intensity, mass, thermodynamic temperature, time, and a special ratio flag `D`
([`DimensionVector.java`][qudt-dv] L21–28). The `D` slot is documented as an indicator,
not an exponent ([`DimensionVector.java`][qudt-dv] L15–18):

> "Note that the last value, the 'D' dimension is special: it is only an indicator
> that the dimension vector represents a ratio (causing all other dimensions to cancel
> each other out). It never changes by multiplication, and its value is only 1 iff all
> other dimensions are 0."

The vector serializes to a QUDT IRI in the `.../dimensionvector/` namespace — the
`A0E0L1I0M0H0T0D0` form for length — built by walking the eight slots
([`DimensionVector.java`][qudt-dv] L160–190). The internal store is `float[8]`, so
fractional exponents are representable (encoded with a `pt`/`dot` decimal marker); see
[Expressiveness edges](#expressiveness-edges).

### JSR-385 middle layer

`javax.measure` is interfaces only. `Unit<Q extends Quantity<Q>>` declares
`getDimension`, `isCompatible`, `getConverterTo`, `getConverterToAny`, `multiply`,
`divide`, `pow`, `root`, and `asType` ([`Unit.java`][uapi-unit] L75, L109, L153,
L205, L226, L191). `Dimension` is itself a group: `multiply`, `divide`, `pow(int)`,
`root(int)`, and `getBaseDimensions(): Map<? extends Dimension, Integer>`
([`Dimension.java`][uapi-dim] L53, L61, L79, L90, L98). The two conversion methods
encode the key contract asymmetry ([`Unit.java`][uapi-unit] L205, L226):

```java
// unit-api: Unit.java L205 & L226 — illustration
UnitConverter getConverterTo(Unit<Q> that) throws UnconvertibleException;
UnitConverter getConverterToAny(Unit<?> that)
        throws IncommensurableException, UnconvertibleException;
```

`getConverterTo` takes a `Unit<Q>` of the _same_ quantity type `Q` — the compiler has
already ruled out an incompatible dimension, so it throws only the _unchecked_
`UnconvertibleException`. `getConverterToAny` takes a `Unit<?>` of unknown type and so
must throw the _checked_ `IncommensurableException`. `IncommensurableException`'s
Javadoc states the rule ([`IncommensurableException.java`][uapi-inc] L31–38):

> "Only commensurable quantity (quantities with the same dimensions) may be compared,
> equated, added, or subtracted. … This is a **checked** exception."

**indriya** implements this. `AbstractUnit.getConverterToAny` is the gate: it calls
`isCompatible` and throws on mismatch ([`AbstractUnit.java`][ind-au] L400–401):

```java
// indriya: AbstractUnit.java L400-401 — illustration
if (!isCompatible(that))
    throw new IncommensurableException(this + " is not compatible with " + that);
```

`UnitDimension` realizes a dimension as a map keyed by pseudo-unit base symbols:
`getBaseDimensions()` returns `Map<? extends Dimension, Integer>`
([`UnitDimension.java`][ind-ud] L301–306), with each base dimension a
`pseudoUnit = new BaseUnit("[" + symbol + ']', NONE)` ([`UnitDimension.java`][ind-ud]
L196).

---

## Dimension representation

Five representations of the same free-abelian-group idea, spanning the whole design
space:

- **ucum-java — a sorted list of `(BaseUnit, int exponent)` pairs, compared as a
  canonical _string_.** `Canonical` holds `List<CanonicalUnit>`
  ([`Canonical.java`][ucumj-canon] L64); commensurability is **string equality of the
  rendered canonical form** (`getCanonicalUnits(u1).equals(getCanonicalUnits(u2))`,
  [`UcumEssenceService.java`][ucumj-svc] L334–342). Normalization is explicit
  (collate + drop-zeros + sort, [`Converter.java`][ucumj-conv] L100–125) precisely
  because two spellings must reduce to the same string.
- **ucum-lhc — a length-7 integer exponent vector.** `dimVec_` over `dimLen_ = 7`
  ([`dimension.js`][lhc-dim], [`config.js`][lhc-config] L25); commensurability is
  element-wise integer equality ([`dimension.js`][lhc-dim] L252–266). This is the
  classic numeric-vector approach — a direct contrast with ucum-java's string form for
  the very same UCUM grammar.
- **qudtlib — an 8-slot `float` vector, compared as an _IRI string_.** The runtime
  comparison is `getDimensionVectorIri().equals(...)` ([`Unit.java`][qudt-unit]
  L508–510) — like ucum-java, string equality, but the string is an ontology IRI. The
  eighth slot `D` is the ratio flag, not a base dimension
  ([`DimensionVector.java`][qudt-dv] L15–28).
- **JSR-385 / indriya — a `Map<Dimension, Integer>`.** A dimension is a map from base
  pseudo-units to integer exponents ([`UnitDimension.java`][ind-ud] L301–306), and
  `isCompatible` reduces to `getDimension().equals(...)`
  ([`Unit.java`][uapi-unit] L102–109).

The exponent _domain_ splits the field: ucum-java (`int`), ucum-lhc (`ℤ⁷`), and
JSR-385 (`Map<…, Integer>`) are integer-only, while **qudtlib's `float[8]` can hold
fractional exponents** — the one representation here that steps outside `ℤ`. See
[free abelian group][fag] for the shared algebra and
[type-system mechanisms][mechanisms] for the general exponent-domain axis.

## Checking & inference

There is **no type inference in any of the five** in the dimensional sense — no
principal types, no [Kennedy-style][kennedy] generalization. "Checking" means one
concrete run-time predicate:

- **ucum-java:** `isComparable(u1, u2)` computes both canonical forms and compares the
  strings ([`UcumEssenceService.java`][ucumj-svc] L334–342); `convert` recomputes the
  canonical forms and throws if they differ ([`UcumEssenceService.java`][ucumj-svc]
  L303–304).
- **ucum-lhc:** `Unit.convertFrom` compares the two dimension vectors and throws on
  inequality ([`unit.js`][lhc-unit] L394–401); the equivalence test at
  [`unit.js`][lhc-unit] L1181 is `unit1Sum == unit2Sum && this.dim_.equals(unit2.dim_)`.
- **qudtlib:** `isConvertible(toUnit)` is IRI equality ([`Unit.java`][qudt-unit]
  L504–511); `convert` calls it and throws on mismatch ([`Unit.java`][qudt-unit]
  L414–418).
- **JSR-385 / indriya:** `isCompatible` compares dimensions
  ([`AbstractUnit.java`][ind-au] L277–278); `getConverterToAny` throws
  `IncommensurableException` when it fails ([`AbstractUnit.java`][ind-au] L400–401).

**The one compile-time nuance is JSR-385's `Unit<Q>` generic.** Because `Unit` is
parameterized by its quantity type `Q`, a `Unit<Length>` variable cannot hold a
`Unit<Time>` — that _is_ a compile error, and `getConverterTo(Unit<Q>)` exploits it to
avoid the checked exception ([`Unit.java`][uapi-unit] L205). But this guard is
shallow: it protects _named references_, not arithmetic. `Unit.multiply`/`divide`
return `Unit<?>` (raw quantity type, [`Unit.java`][uapi-unit] L383, L392), and
`asType(Class<T>)` is a **run-time** cast that throws `ClassCastException` on a
dimension mismatch ([`AbstractUnit.java`][ind-au] L349–354). So the moment you compute
a unit rather than name one, you are back to run-time checking — the reason
`getConverterToAny` exists alongside `getConverterTo`. Dimensional polymorphism (the
generic `sqr : α → α²`) is trivially expressible because nothing is checked at
abstraction boundaries; it is also unguarded, for the same reason.

## Extensibility

- **ucum-java / ucum-lhc — extend the data, not the code.** Both are driven by an
  external definition artifact (`ucum-essence.xml`; ucum-lhc also ships
  `data/ucumDefs.min.json`). New units, prefixes, and special units come from editing
  or replacing that data source; the grammar and the base-dimension set are fixed by
  the [UCUM spec][concepts]. UCUM's annotation syntax (`{rbc}`, `{cells}`) provides a
  standardized escape hatch for uncatalogued units without changing the dimension.
- **qudtlib — extend the ontology upstream, regenerate.** Because every unit's
  dimension vector and `(multiplier, offset)` are precomputed from the QUDT RDF at
  codegen time, adding a unit means adding it to the ontology (or a supplementary
  graph) and re-running the ingest/gen modules. The shipped jar is a frozen snapshot —
  self-contained, but not user-extensible at run time without regeneration.
- **JSR-385 — extension _is_ the point of the API.** The whole `javax.measure`
  interface set exists so that alternative implementations (indriya, but also
  UCUM-backed or QUDT-backed `Unit` sources) can be swapped behind one contract.
  Within indriya, new units are `AbstractUnit` instances built by `multiply`/`divide`/
  `pow` from existing ones, and new dimensions are new `UnitDimension` pseudo-units
  ([`UnitDimension.java`][ind-ud] L196).

## Expressiveness edges

- **Fractional powers — only qudtlib can represent them.** ucum-java (`int`
  exponents), ucum-lhc (integer `dimVec_`), and JSR-385 (`Map<…, Integer>`) are all
  integer-only. qudtlib stores `float[8]` ([`DimensionVector.java`][qudt-dv]) and its
  IRI format carries a decimal marker (`pt`/`dot`), so a half-integer dimension exponent
  is expressible in principle. (UCUM itself keeps exponents integer at the grammar
  level; a fractional _magnitude_ like a square-root relation is handled numerically,
  not as a fractional dimension.)
- **Affine / temperature — explicit only in qudtlib.** qudtlib carries a
  `conversionOffset` per unit and applies the full affine formula
  ([`Unit.java`][qudt-unit] L419–430); it special-cases temperature _differences_ by
  passing a `QuantityKind` that suppresses the offset (`TEMPERATURE_DIFFERENCE`,
  [`Unit.java`][qudt-unit] L21, L398–411) — a run-time realization of the
  point-vs-difference [torsor][torsor] distinction. UCUM encodes Celsius/Fahrenheit as
  "special units" with a function-pair conversion handled inside the definition data;
  the parsers apply them numerically rather than modeling a distinct affine _type_. In
  none of the five does the type system distinguish a temperature point from a
  temperature interval.
- **Logarithmic units — UCUM has them as special units; the others do not model
  them.** UCUM's grammar includes special units such as `B` (bel) and `Np` (neper) with
  function-based conversions, so the parsers can validate and convert them via the
  definition data. qudtlib and indriya do not model logarithmic scales as a distinct
  algebra. Contrast [Pint][pint]'s dedicated `dB` support.
- **Angles — dimensionless in UCUM/JSR-385, an explicit slot nowhere.** UCUM treats
  `rad` as dimensionless (per the SI `rad = 1` convention); indriya follows the SI
  brochure. qudtlib's eight-slot vector has no angle slot either. So none of the five
  catches a radian-vs-dimensionless confusion as a _dimension_ error (contrast
  [Wolfram][wolfram], where angle is a base dimension).
- **Kind vs dimension — absent across the board.** No member of this pole distinguishes
  same-dimension quantities of different _kind_ (torque vs energy, frequency vs
  becquerel) at the representation level: ucum-java/ucum-lhc reduce both `Hz` and `Bq`
  to the same `T⁻¹` canonical form, qudtlib gives them the same dimension-vector IRI,
  and indriya the same `Dimension`. QUDT distinguishes them only at the higher
  `QuantityKind` layer, which is metadata, not a checking mechanism — a `Hz`/`Bq` mix
  is _not_ rejected. This is the field's sharpest weakness relative to the kind-aware
  typed systems ([`uom`][uom]'s `Kind`, [mp-units][mpunits]' `quantity_spec`).

## Zero-cost story

There is **no zero-cost story here, by design** — and none of the five claims one.
Every operation is a run-time computation on run-time data:

- **UCUM parsers pay per call.** Each `convert`/`isComparable` in ucum-java
  re-parses both unit strings, rebuilds two `Term` trees, and re-runs `normalise`
  (`new Converter(...).convert(new ExpressionParser(model).parse(sourceUnit))`,
  [`UcumEssenceService.java`][ucumj-svc] L299–302) — allocation and string work on the
  hot path, cacheable only by the caller. ucum-lhc similarly parses to a `Unit` and
  compares integer vectors.
- **qudtlib is the fast member of the pole.** Because the dimension vectors and
  `(multiplier, offset)` are precomputed, a conversion is a field lookup, an IRI
  string compare, and four `BigDecimal` operations in `DECIMAL128`
  ([`Unit.java`][qudt-unit] L419–430) — no parsing, no RDF, no reflection. The cost is
  arbitrary-precision decimal arithmetic (exact, but not machine-float speed) and the
  ~400 kB data-carrying jar.
- **JSR-385 / indriya** wrap conversions in `UnitConverter` chains built from the
  dimensional model ([`AbstractUnit.java`][ind-au] L400–413); the converter can be
  cached by the caller, but constructing it walks the system-unit graph.

The whole pole's value proposition is _interoperability and coverage_ (real UCUM
codes, 1745 QUDT units), traded against the run-time cost the typed systems avoid.

## Diagnostics

The mandated `m + s` experiment, applied to each pole. The unifying result: **all five
reject incommensurable units at run time with an ecosystem-specific exception** — none
uses the type checker.

**ucum-lhc — reproduced locally.** The library's ES-module source was Babel-transpiled
to CommonJS with the project's own build plugins
(`@babel/plugin-transform-modules-commonjs`, `@babel/plugin-proposal-class-properties`,
matching `Gruntfile.js`), then driven through the public `convertUnitTo` API against
the shipped `data/ucumDefs.min.json`:

```text
convert 1 m -> s: status=failed
  msg: ["Sorry.  m cannot be converted to s."]
convert 1 m -> km: status=succeeded
  toVal=0.001
```

[reproduced locally, `node 24.15.0` (nixpkgs), ucum-lhc @ `3713cd1`, Babel-transpiled,
2026-07-04]. The incommensurable conversion returns a `status: 'failed'` object whose
message is the raw error text; the commensurable conversion returns `0.001`. The
message originates as a plain JavaScript `Error` (no dimensional subtype) thrown inside
`Unit.convertFrom` ([`unit.js`][lhc-unit] L394–401):

```javascript
// ucum-lhc: unit.js L394-401 — illustration
if (fromUnit.dim_ && this.dim_ && !fromUnit.dim_.equals(this.dim_)) {
  if (this.isMolMassCommensurable(fromUnit)) {
    throw new Error(Ucum.needMoleWeightMsg_);
  } else {
    throw new Error(
      `Sorry.  ${fromUnit.csCode_} cannot be converted ` +
        `to ${this.csCode_}.`,
    );
  }
}
```

`convertUnitTo` catches that `Error` and folds it into the `failed` status object
([`ucumLhcUtils.js`][lhc-utils] L358–359, L424). The behavior is pinned by an in-repo
test: an attempt to convert `g` to `/g` (grams to inverse grams — dimensionally
`M` vs `M⁻¹`) asserts exactly this failure
([in-repo test: `test/testUcumLhcUtils.spec.js`][lhc-test] L193–200):

```javascript
// ucum-lhc: test/testUcumLhcUtils.spec.js L194-197 — illustration
var resp4 = utils.convertUnitTo('g', 847, '/g');
assert.equal(resp4.status, 'failed', resp4.status);
assert.equal(
  resp4.msg[0],
  'Sorry.  g cannot be converted to /g.',
  resp4.msg[0],
);
```

**ucum-java — quoted throw site.** The Java toolchain build was not exercised (rung 2);
the rejection is encoded directly in the conversion path, which compares the two
canonical-form strings and throws a `UcumException`
([`UcumEssenceService.java`][ucumj-svc] L303–304):

```java
// ucum-java: UcumEssenceService.java L303-304 — illustration
if (!s.equals(d))
    throw new UcumException("Unable to convert between units "+sourceUnit+" and "
        +destUnit+" as they do not have matching canonical forms ("+s+" and "+d
        +" respectively)");
```

For a metre-vs-second query, `s` reduces to the length canonical form and `d` to the
time canonical form; the strings differ and the exception fires. `isComparable`
returns `false` for the same pair without throwing
([`UcumEssenceService.java`][ucumj-svc] L334–342).

**qudtlib — quoted throw site.** `convert` calls `isConvertible` (IRI equality) and
throws `InconvertibleQuantitiesException` on mismatch
([`Unit.java`][qudt-unit] L414–418):

```java
// qudtlib-java: Unit.java L414-418 — illustration
if (!isConvertible(toUnit)) {
    throw new InconvertibleQuantitiesException(
            String.format(
                    "Cannot convert from %s to %s: dimension vectors differ",
                    this.getIri(), toUnit.getIri()));
}
```

A metre's dimension-vector IRI (`…/A0E0L1I0M0H0T0D0`) is not equal to a second's
(`…/A0E0L0I0M0H0T1D0`), so `isConvertible` is `false`
([`Unit.java`][qudt-unit] L504–511) and the exception carries both IRIs.

**JSR-385 / indriya — quoted throw site.** `getConverterToAny` throws the
JSR-385-standard `IncommensurableException` (checked) when `isCompatible` fails
([`AbstractUnit.java`][ind-au] L400–401), and `asType` throws `ClassCastException` on a
dimension mismatch ([`AbstractUnit.java`][ind-au] L349–354). Only the `getConverterTo`
overload — restricted to a `Unit<Q>` of the same quantity type — narrows the throw to
the unchecked `UnconvertibleException`, precisely because the compiler has already
excluded a cross-dimension argument ([`Unit.java`][uapi-unit] L205).

So the four exceptions — `Error` "Sorry. m cannot be converted to s." (ucum-lhc),
`UcumException` "do not have matching canonical forms" (ucum-java),
`InconvertibleQuantitiesException` "dimension vectors differ" (qudtlib), and
`IncommensurableException` "is not compatible with" (indriya) — are the same finding
in four dialects: **the check is data-driven and it happens at run time.**

## Ergonomics & compile-time cost

- **No compile-time dimensional cost — and no compile-time dimensional safety.** None
  of the five imposes the template-instantiation or trait-solving weight of the typed
  pole ([`uom`][uom]'s tens of seconds, [mp-units][mpunits]' heavy headers); a
  units-of-measure bug simply is not a build-time event. The trade is the whole point
  of the page: the guarantee moves to run time.
- **String and IRI inputs are the ergonomic headline.** UCUM's grammar accepts
  real-world codes (`mg/dL`, `mm[Hg]`, `/uL`); QUDT accepts ontology IRIs. This is
  exactly the interoperability the typed systems cannot offer — a UCUM code from a lab
  feed or a QUDT IRI from a graph is a first-class input.
- **JSR-385's generic gives partial IDE-level safety.** Because `Unit<Q>` and
  `Quantity<Q>` are parameterized, an IDE and the compiler catch _reference-level_
  mismatches (assigning a `Unit<Time>` to a `Unit<Length>`), and `add`/`subtract` on
  `Quantity<Q>` are type-restricted to the same `Q` ([`Quantity.java`][uapi-quantity]
  L97, L128). That is genuinely more than the untyped members of the pole offer — but
  it stops at named references, not computed units.
- **Failure ergonomics vary.** ucum-java, qudtlib, and indriya throw (a hard,
  visible failure); ucum-lhc's public API converts the throw into a `failed` status
  object the caller must inspect ([`ucumLhcUtils.js`][lhc-utils] L358–359) — quieter,
  and easy to ignore if the status field goes unchecked.

---

## Strengths

- **Standards fidelity and coverage** — real UCUM grammar (validated against the
  spec's functional test suite) and 1745 QUDT units with vetted SI relationships; the
  breadth no hand-rolled units DSL matches.
- **Run-time inputs are first-class** — a unit that is only known as a string or IRI at
  run time (from a message, a feed, or an RDF graph) is exactly what these libraries
  are built to ingest; the typed pole structurally cannot.
- **qudtlib's self-contained precomputation** — dimension vectors and
  `(multiplier, offset)` harvested from RDF at codegen time, shipped in a ~400 kB jar
  with no runtime ontology dependency: fast conversions, no SPARQL.
- **JSR-385 as a shared contract** — one `javax.measure` API that both UCUM-backed and
  QUDT-backed sources, plus the indriya RI, can present, with a real (if partial)
  compile-time reference guard from the `Unit<Q>` generic.
- **Two reductions of one grammar** — ucum-java's canonical-string and ucum-lhc's
  integer-vector show the same UCUM standard admits genuinely different, both-correct
  internal models.
- **qudtlib's affine handling** — a per-unit `conversionOffset` plus a
  temperature-difference `QuantityKind` gives correct point-vs-difference conversion at
  run time.

## Weaknesses

- **No compile-time dimensional safety** — the defining limitation: `m + s` is a
  run-time exception in all five (an unchecked `UnconvertibleException` on the one
  typed path), so an unexercised code path ships the bug. Contrast the entire typed
  pole.
- **Per-call parsing cost (UCUM)** — ucum-java and ucum-lhc re-parse and re-normalize
  on every `convert`/`isComparable`; caching is the caller's job.
- **No kind discipline** — `Hz` vs `Bq`, torque vs energy collapse to one dimension
  everywhere in the pole; QUDT's `QuantityKind` is metadata, not a check.
- **Integer-only exponents (except qudtlib)** — half-integer dimensions are
  unrepresentable in ucum-java, ucum-lhc, and JSR-385.
- **qudtlib is a frozen snapshot** — extension means editing the ontology and
  regenerating, not a run-time registry edit; the jar is not user-extensible live.
- **ucum-lhc's quiet failure mode** — the public API returns a `failed` status object
  rather than throwing, so an unchecked status silently yields no result.
- **JSR-385's guard is shallow** — `Unit<Q>` protects references but not computed
  units; `multiply`/`divide` return `Unit<?>` and `asType` is a run-time cast.

## Key design decisions and trade-offs

| Decision                                                                        | Rationale                                                                                   | Trade-off                                                                                             |
| ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Consume a standard (UCUM grammar / QUDT ontology) instead of a units DSL        | Interoperate with instruments, FHIR/HL7 messages, and RDF graphs; inherit vetted coverage   | All dimensional identity is run-time data; the compiler proves nothing                                |
| ucum-java: reduce a parsed `Term` to a **canonical string**, compare strings    | Normalization + comparison in one representation; human-readable canonical form for display | Per-call parse + normalize + render; string equality hides the numeric vector                         |
| ucum-lhc: reduce to an **integer 7-vector**, compare element-wise               | Cheap vector algebra; the textbook free-abelian-group model                                 | Same UCUM grammar, incompatible internal form from ucum-java; integer-only exponents                  |
| qudtlib: **precompute** dimension-vector IRIs + `(multiplier, offset)` from RDF | Self-contained jar, no runtime SPARQL, fast field-lookup conversion                         | Frozen snapshot; extension needs ontology edit + regeneration; `BigDecimal` (not float) arithmetic    |
| qudtlib: `float[8]` dimension vector with a ratio flag `D`                      | Fractional exponents representable; ratio-ness explicit                                     | Extra slot semantics to reason about; still IRI-string equality for the actual check                  |
| JSR-385: parameterize `Unit<Q>` / `Quantity<Q>` by quantity type                | Compile-time guard on named references; `getConverterTo` avoids the checked exception       | Guard is shallow — computed units are `Unit<?>`, `asType` is a run-time cast, arithmetic is unchecked |
| All five: reject incommensurable units by **throwing at run time**              | Simple, uniform, works on run-time-unknown units                                            | The bug surfaces only when the path executes; ucum-lhc even downgrades the throw to a status object   |

## Sources

- [FHIR/Ucum-java][ucumj-repo] @ `70106f4` — [`Lexer.java`][ucumj-lexer] /
  [`ExpressionParser.java`][ucumj-parser] (UCUM tokenizer + recursive-descent parser),
  [`Converter.java`][ucumj-conv] (`normalise`: collate/drop-zeros/sort to `Canonical`),
  [`Canonical.java`][ucumj-canon] (`CanonicalUnit {BaseUnit; int exponent}`),
  [`BaseUnit.java`][ucumj-base] (`char dim`),
  [`UcumEssenceService.java`][ucumj-svc] (`convert`/`isComparable`/`getCanonicalUnits`,
  the `m + s` throw site), [`README.md`][ucumj-readme] (service list)
- [LHNCBC/ucum-lhc][lhc-repo] @ `3713cd1` — [`dimension.js`][lhc-dim]
  (length-7 `dimVec_`, element-wise `equals`), [`unit.js`][lhc-unit]
  (`convertFrom` throw site), [`ucumLhcUtils.js`][lhc-utils]
  (`convertUnitTo` catch → `failed` status), [`unitString.js`][lhc-ustr] (parser),
  [`config.js`][lhc-config] (`dimLen_: 7`),
  [`test/testUcumLhcUtils.spec.js`][lhc-test] (`g`→`/g` rejection test)
- [qudtlib/qudtlib-java][qudt-repo] @ `8530b43` — [`Unit.java`][qudt-unit]
  (`conversionMultiplier`/`conversionOffset`, affine `convert`, `isConvertible` IRI
  equality, `m + s` throw site), [`DimensionVector.java`][qudt-dv] (8-slot `float`
  vector, `D` ratio flag, IRI serialization), [`README.md`][qudt-readme]
- [unitsofmeasurement/unit-api][uapi-repo] @ `79682ff` — [`Unit.java`][uapi-unit]
  (`getConverterTo`/`getConverterToAny` contract, `asType`, `pow`/`root`),
  [`Dimension.java`][uapi-dim] (`getBaseDimensions`), [`Quantity.java`][uapi-quantity]
  (`add`/`subtract` typed by `Q`), [`IncommensurableException.java`][uapi-inc]
- [unitsofmeasurement/indriya][ind-repo] @ `c3dc219` — [`AbstractUnit.java`][ind-au]
  (`getConverterToAny` throw site, `internalGetConverterTo` unchecked path, `asType`
  `ClassCastException`), [`UnitDimension.java`][ind-ud] (`Map`-of-pseudo-units
  dimension), [`README.md`][ind-readme]
- Local reproduction: ucum-lhc Babel-transpiled and driven via `convertUnitTo`,
  `node 24.15.0` (nixpkgs), 2026-07-04
- Related deep-dives in this survey: [concepts (UCUM & QUDT standards)][concepts] ·
  [free abelian group][fag] · [torsors & affine quantities][torsor] ·
  [type-system mechanisms][mechanisms] · [Kennedy's type system][kennedy] ·
  [Pint][pint] · [Swift `Units`][swift] · [Wolfram / MATLAB][wolfram] ·
  [`uom`][uom] · [mp-units][mpunits] · [Julia `Unitful.jl`][unitful] ·
  [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone: ucum-java (FHIR/Ucum-java @ 70106f4) -->

[ucumj-repo]: https://github.com/FHIR/Ucum-java
[ucumj-lexer]: https://github.com/FHIR/Ucum-java/blob/70106f4/src/main/java/org/fhir/ucum/Lexer.java
[ucumj-parser]: https://github.com/FHIR/Ucum-java/blob/70106f4/src/main/java/org/fhir/ucum/ExpressionParser.java
[ucumj-conv]: https://github.com/FHIR/Ucum-java/blob/70106f4/src/main/java/org/fhir/ucum/Converter.java
[ucumj-canon]: https://github.com/FHIR/Ucum-java/blob/70106f4/src/main/java/org/fhir/ucum/Canonical.java
[ucumj-base]: https://github.com/FHIR/Ucum-java/blob/70106f4/src/main/java/org/fhir/ucum/BaseUnit.java
[ucumj-svc]: https://github.com/FHIR/Ucum-java/blob/70106f4/src/main/java/org/fhir/ucum/UcumEssenceService.java
[ucumj-readme]: https://github.com/FHIR/Ucum-java/blob/70106f4/README.md

<!-- Pinned clone: ucum-lhc (LHNCBC/ucum-lhc @ 3713cd1) -->

[lhc-repo]: https://github.com/LHNCBC/ucum-lhc
[lhc-dim]: https://github.com/LHNCBC/ucum-lhc/blob/3713cd1/source/dimension.js
[lhc-unit]: https://github.com/LHNCBC/ucum-lhc/blob/3713cd1/source/unit.js
[lhc-utils]: https://github.com/LHNCBC/ucum-lhc/blob/3713cd1/source/ucumLhcUtils.js
[lhc-ustr]: https://github.com/LHNCBC/ucum-lhc/blob/3713cd1/source/unitString.js
[lhc-config]: https://github.com/LHNCBC/ucum-lhc/blob/3713cd1/source/config.js
[lhc-test]: https://github.com/LHNCBC/ucum-lhc/blob/3713cd1/test/testUcumLhcUtils.spec.js

<!-- Pinned clone: qudtlib-java (qudtlib/qudtlib-java @ 8530b43) -->

[qudt-repo]: https://github.com/qudtlib/qudtlib-java
[qudt-unit]: https://github.com/qudtlib/qudtlib-java/blob/8530b43/qudtlib-model/src/main/java/io/github/qudtlib/model/Unit.java
[qudt-dv]: https://github.com/qudtlib/qudtlib-java/blob/8530b43/qudtlib-model/src/main/java/io/github/qudtlib/model/DimensionVector.java
[qudt-readme]: https://github.com/qudtlib/qudtlib-java/blob/8530b43/README.md

<!-- Pinned clone: unit-api / JSR-385 (unitsofmeasurement/unit-api @ 79682ff) -->

[uapi-repo]: https://github.com/unitsofmeasurement/unit-api
[uapi-unit]: https://github.com/unitsofmeasurement/unit-api/blob/79682ff/src/main/java/javax/measure/Unit.java
[uapi-dim]: https://github.com/unitsofmeasurement/unit-api/blob/79682ff/src/main/java/javax/measure/Dimension.java
[uapi-quantity]: https://github.com/unitsofmeasurement/unit-api/blob/79682ff/src/main/java/javax/measure/Quantity.java
[uapi-inc]: https://github.com/unitsofmeasurement/unit-api/blob/79682ff/src/main/java/javax/measure/IncommensurableException.java

<!-- Pinned clone: indriya (unitsofmeasurement/indriya @ c3dc219) -->

[ind-repo]: https://github.com/unitsofmeasurement/indriya
[ind-au]: https://github.com/unitsofmeasurement/indriya/blob/c3dc219/src/main/java/tech/units/indriya/AbstractUnit.java
[ind-ud]: https://github.com/unitsofmeasurement/indriya/blob/c3dc219/src/main/java/tech/units/indriya/unit/UnitDimension.java
[ind-readme]: https://github.com/unitsofmeasurement/indriya/blob/c3dc219/README.md

<!-- Package registries -->

[ucumj-maven]: https://central.sonatype.com/artifact/org.fhir/ucum
[lhc-npm]: https://www.npmjs.com/package/@lhncbc/ucum-lhc
[qudt-maven]: https://central.sonatype.com/artifact/io.github.qudtlib/qudtlib
[uapi-maven]: https://central.sonatype.com/artifact/javax.measure/unit-api
[ind-maven]: https://central.sonatype.com/artifact/tech.units/indriya

<!-- Same-tree theory pages -->

[fag]: ./theory/free-abelian-group.md
[torsor]: ./theory/torsor-representation.md
[mechanisms]: ./theory/type-system-mechanisms.md
[kennedy]: ./theory/kennedy-types.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[pint]: ./python-pint.md
[swift]: ./swift-units.md
[wolfram]: ./wolfram-matlab.md
[uom]: ./rust-uom.md
[mpunits]: ./cpp-mp-units.md
[unitful]: ./julia-unitful.md
[fsharp]: ./fsharp-uom.md
