# Wolfram `Quantity` & MATLAB `symunit` (computer algebra)

The symbolic / computer-algebra pole of this survey: Wolfram Language's `Quantity[magnitude, unit]` makes units held symbolic expressions over a curated, Wolfram|Alpha-backed units corpus, with compatibility resolved every time an expression evaluates; MATLAB's Symbolic Math Toolbox `symunit` makes units inert symbolic _factors_ that commute through arithmetic entirely unchecked until `checkUnits`, `simplify`, or `unitConvert` is explicitly called — checking as an opt-in query rather than a gate.

| Field            | Value                                                                                                                                                                                                                                                                                                                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | Wolfram Language (Mathematica) · MATLAB with the Symbolic Math Toolbox (`symunit` lives in the toolbox, not core MATLAB)                                                                                                                                                                                                                                                  |
| License          | Proprietary, closed source — both; **no source tree exists to pin**, so this page is grounded exclusively in locally captured vendor documentation (see the note below)                                                                                                                                                                                                   |
| Repository       | None (closed source). Local artifacts: `$PAPERS/vendor-docs/wolfram-{quantity,unitconvert,knownunitq,unitdimensions,units-guide}.html` and `$PAPERS/vendor-docs/matlab-{units-of-measurement,symunit,checkunits,unitconvert}.html`                                                                                                                                        |
| Documentation    | [Wolfram: `Quantity`][wq] · [`UnitConvert`][wuc] · [`KnownUnitQ`][wkq] · [`UnitDimensions`][wud] · [Units & Quantities guide][wguide] — [MATLAB: Units of Measurement][muom] · [`symunit`][msym] · [`checkUnits`][mcheck] · [`unitConvert`][mconv]                                                                                                                        |
| Key authors      | Wolfram Research (each page's cite-block reads "Wolfram Research (2012)") · The MathWorks, Inc.                                                                                                                                                                                                                                                                           |
| Category         | [Runtime, term-level checking][concepts] inside a computer-algebra system — Wolfram checks **eagerly at evaluation time**; MATLAB checks **only on explicit request**                                                                                                                                                                                                     |
| Mechanism        | Wolfram: `Quantity` is a symbolic expression with attribute `HoldRest`; unit strings are canonicalized (free-form parsing via Wolfram\|Alpha), validated by `KnownUnitQ`, dimensioned by `UnitDimensions`. MATLAB: `u.m`, `u.s`, … are symbolic objects multiplied into `sym` expressions; `checkUnits`/`unitConvert`/`simplify` run the dimensional analysis when called |
| Exponent domain  | Term-level exponents on symbolic unit expressions (`"Meters"/"Seconds"^2`; `u.m/u.s^2`); `UnitDimensions` returns dimension–exponent **pairs** over an open base set. The captures exhibit integer exponents only and state no bound — the representation imposes none                                                                                                    |
| Checking time    | **Run time.** Wolfram: per evaluation of each arithmetic/conversion expression. MATLAB: never implicitly — only when `checkUnits`, `simplify`, or `unitConvert` is invoked                                                                                                                                                                                                |
| Analyzed version | Doc captures: Wolfram reference pages fetched live 2026-07-03 (page histories current through 13.2/14.0/14.1); MATLAB pages are Wayback snapshots — `checkunits` 2019-12-15 (R2019b-era site), `symunit` 2024-09-09, `unitconvert` 2024-11-05, `units-of-measurement` 2024-11-09 (R2024a/b-era)                                                                           |
| Latest release   | Not pinned by the captures. Wolfram: units introduced in Mathematica 9.0 (2012); captured histories show updates through 14.1 (2024). MATLAB: `symunit`/`checkUnits` introduced R2017a, `unitConvert` R2018b; captured version-history entries reach R2022b                                                                                                               |

> [!NOTE]
> This is the survey's **symbolic pole** and its only page grounded purely in vendor
> documentation: both systems are closed source, so — unlike every other system page —
> there is no pinned clone to excerpt and no toolchain in nixpkgs to reproduce against
> (both require commercial licenses). Every claim below cites one of the nine local
> HTML captures listed above; where the captures are silent, that silence is reported
> rather than papered over. Within the survey these two bracket the runtime family
> from the opposite side to [Pint][pint]: Pint is imperative and eager, Wolfram is
> symbolic and eager, and MATLAB `symunit` is symbolic and **lazy** — the only system
> in the catalog where a dimensionally absurd expression is a perfectly legal value
> and checking is something you _ask for_. The
> [mechanism taxonomy][mechanisms] excludes both from its erasure discussion for
> precisely this reason. See the [comparison capstone][comparison] for the synthesis.

---

## Overview

### What it solves

Both systems bolt dimensional awareness onto a general symbolic-computation engine,
which changes what "units support" even means: units participate in symbolic
simplification, equation solving, and visualization, not just in arithmetic on
numeric magnitudes. The Wolfram units guide states the ambition
([`wolfram-units-guide.html`][wguide] capture, intro):

> "The Wolfram Language allows you to do arithmetic not only with symbols and
> numbers, but also with units. The Wolfram Language's integration with
> Wolfram|Alpha allows for a sophisticated unit system that combines the flexibility
> of free-form linguistics with the computational power of numerical and symbolic
> algorithms. The units framework integrates seamlessly with visualization, numeric
> and algebraic computation functions. It also supports dimensional analysis, as
> well as purely symbolic operations on quantities."

MATLAB's landing page is more modest and states the same term-level stance
([`matlab-units-of-measurement.html`][muom] capture, intro):

> "Use and manipulate physical units of measurement. These units act as symbolic
> expressions and can be used with Symbolic Math Toolbox™ functions. You can verify
> unit dimensions, convert between units, and create your own custom units."

Neither offers any static guarantee, and neither erases anything: a quantity is a
symbolic expression from construction to output. What that buys is the highest
symbolic ceiling in the survey — exact rational magnitudes, units flowing through
`solve`-class machinery, and (in Wolfram's case) a curated knowledge base of units
reaching well past SI into currencies, dated units, and per-person counts.

### Design philosophy

**Wolfram: curated data plus eager canonicalization.** The units corpus is not a
user-visible definition file (as in [Pint][pint]) but a curated database wired into
the language kernel and Wolfram|Alpha's linguistics. The `Quantity` reference page
grounds both halves ([`wolfram-quantity.html`][wq] capture, "Details"):

> "Supported units include all those specified by NIST Special Publication 811."

> "Quantity will automatically attempt to parse an unknown unit string to its
> canonical form."

So `Quantity` accepts free-form input, resolves it against the curated corpus, and
canonicalizes; from then on compatibility questions are answered eagerly whenever an
expression evaluates. Some of the corpus is _live_ data — "An internet connection is
required for conversion between currency units"
([`wolfram-unitconvert.html`][wuc] capture, "Details") — a dependence no other
system in this survey has.

**MATLAB: units as inert factors, checking on demand.** `symunit` deliberately does
_not_ weave checking into arithmetic. Units multiply into symbolic expressions and
ride along like any other symbol ([`matlab-symunit.html`][msym] capture):

> "Units behave like symbolic expressions when you perform standard operations on
> them. For numeric operations, separate the value from the units, substitute for
> any symbolic parameters, and convert the result to double."

> "Units are not automatically simplified or checked for consistency unless you
> call simplify."

That is a genuinely different design point from everything else in the catalog —
including Wolfram. In every other system, adding metres to seconds is an _event_
(a compile error, an exception, an unevaluated form). In MATLAB it is a value:
`A*u.m/u.s == B*u.kg/u.s` constructs a well-formed symbolic equation, and only a
subsequent `checkUnits` call reports — as a `logical` result, not an error — that
its dimensions are incompatible ([`matlab-checkunits.html`][mcheck] capture; see
[Diagnostics](#diagnostics)).

---

## How it works

### Wolfram: `Quantity` as held symbolic data over a curated corpus

The two constructor forms and the structural rules, verbatim from the reference page
([`wolfram-quantity.html`][wq] capture, usage + "Details"):

```wolfram
Quantity[magnitude, unit]  (* a quantity with size magnitude and unit *)
Quantity[unit]             (* magnitude of the specified unit assumed to be 1 *)
```

> "In `Quantity[m,u]`, the unit `u` can be given as a string, such as `"Meters"`, or
> a product of powers of units, such as `"Meters"/"Seconds"^2`."

> "Quantity has attribute HoldRest and preserves the structure of unit."

`HoldRest` is the load-bearing detail: the unit argument is held unevaluated, so the
unit expression is symbolic _data_ the kernel can inspect, canonicalize, and rewrite
— not a value computed away at construction. Its consequences surface throughout the
page's "Properties & Relations" items: units accept metric prefixes; canonical unit
strings are always plural; a `Quantity` first argument that is itself a `Quantity`
multiplies the units; and — notably — products are **not** normalized eagerly:

> "When quantities are multiplied, the resulting unit is not automatically
> simplified:" … "Use UnitSimplify to get a simpler form of the unit:"

Interrogation and conversion are separate curated functions. `KnownUnitQ` validates
canonical units (attribute `HoldFirst`; a dimensional second argument checks
compatibility — `KnownUnitQ[expr,dims]` "returns True if expr is a canonical unit
and is compatible with dims", [`wolfram-knownunitq.html`][wkq] capture).
`UnitDimensions` exposes the dimension vector (next section). `UnitConvert` converts
to a target unit, a target `Quantity`'s unit, or a whole unit system
([`wolfram-unitconvert.html`][wuc] capture, "Details"):

> "A targetunit specification can also be one of the following unit systems:
> `"SIBase"`, `"SI"`, `"Imperial"`, `"Conventional"` or `"Metric"`."

with `$UnitSystem` supplying the ambient default — "default unit system for output
(e.g. `"Imperial"` or `"Metric"`)" ([`wolfram-units-guide.html`][wguide] capture).
An `Information` call on a quantity reports `"Magnitude"`, `"Unit"`,
`"UnitDimensions"`, and `"SIBaseUnits"` properties ([`wolfram-quantity.html`][wq]
capture, "Details") — the full term-level representation, queryable at run time.

> [!IMPORTANT]
> **Capture limitation.** Wolfram documentation pages store their example notebook
> cells as _images_ (the capture's example inputs reference external `Files/…/i_N.txt`
> assets that are not part of the HTML). The section headings and Details text quoted
> here are verbatim; no in-notebook input/output — including any error-message text —
> exists in the local captures, and none is quoted on this page.

### MATLAB: units as symbolic factors from the `symunit` collection

The whole API surface is one collection object plus dot access
([`matlab-symunit.html`][msym] capture, description):

> "`u = symunit` returns the units collection. Then, specify any unit by using
> `u.unit`. For example, specify 3 meters as `3*u.m`. Common alternate names for
> units are supported, such as `u.meter` and `u.metre`. Plurals are not supported."

Because the carrier is the symbolic engine, magnitudes are exact from the first
multiplication — "Because units are symbolic expressions, numeric inputs are
converted to exact symbolic values. Here, `9.81` is converted to `981/100`"
([`matlab-symunit.html`][msym] capture). The documented force computation shows the
commute-through behavior: the product keeps its raw factors until a conversion is
requested ([`matlab-unitconvert.html`][mconv] capture, "Convert Between Units" —
"The result is not automatically in newtons"):

```matlab
u = symunit;
m = 2*u.kg;
a = 5*u.m/u.s^2;
F = m*a
% F = 10 kg*m/s^2      (capture typesets it as 10 kg m/s² — not rewritten as newtons)

F = unitConvert(F,u.N)
% F = 10 N
```

Getting a plain number back out is likewise explicit — `separateUnits` splits value
from units, `double` converts (`[sNum,sUnits] = separateUnits(s)`, then
`double(sNum)`; [`matlab-symunit.html`][msym] capture). Conversion targets can be a
unit, a compound unit, a vector of per-dimension units, or a unit system —
"By default, the SI, CGS, and US unit systems are available. You can also define
custom unit systems by using `newUnitSystem`" ([`matlab-unitconvert.html`][mconv]
capture, description). And the conversion failure mode is the quietest in this
survey ([`matlab-unitconvert.html`][mconv] capture, "Convert Between Units"):

> "If conversion is not possible, unitConvert returns the input."

## Dimension representation

**Wolfram — dimension–exponent pairs over an openly extended base set.** Dimensions
are reified, queryable values: `UnitDimensions[unit]` "returns a list of base
dimensions associated with the specified unit", concretely "a list of ordered
dimension pairs, indicating the magnitude of the unit in that dimension"
([`wolfram-unitdimensions.html`][wud] capture, usage + "Details") — the
[free-abelian-group][fag] exponent vector, stored as an association-style list of
pairs rather than a fixed-width tuple. The base set is documented explicitly, and it
is **larger than SI's seven** ([`wolfram-unitdimensions.html`][wud] capture,
"Details"):

> "Physical dimensions are: `"AmountUnit"`, `"ElectricCurrentUnit"`, `"LengthUnit"`,
> `"LuminousIntensityUnit"`, `"MassUnit"`, `"TemperatureUnit"`, and `"TimeUnit"`."

> "Additional unit dimensions include: `"AngleUnit"`, `"InformationUnit"`,
> `"MoneyUnit"`, `"PersonUnit"` and `"SolidAngleUnit"`."

Angle and solid angle as first-class dimensions is a deliberate departure from the
SI Brochure's `rad = 1` convention (contrast [Pint][pint], where `radian = []` and
angular frequency conflates with frequency); money, information, and persons as
dimensions are the curated-data angle showing through. The set is open at the user
level too: an `IndependentUnit` behaves as its own base — "UnitDimensions returns
the argument of an IndependentUnit specification together with its power"
([`wolfram-unitdimensions.html`][wud] capture). Dimensionless is the empty list
("An empty list is returned for units without dimension"), and prefixes are
dimensionless known units ([`wolfram-knownunitq.html`][wkq] capture).

**MATLAB — dimensions live inside the engine, surfaced only as verdicts.** The
captured MATLAB pages expose no `UnitDimensions`-style reflection value. Dimensions
appear in the API as the _criterion_ `checkUnits` applies
([`matlab-checkunits.html`][mcheck] capture, description):

> "expr has compatible dimensions if all terms have the same dimensions, such as
> length or time. expr has consistent units if all units of the same dimension can
> be converted to each other with a conversion factor of 1."

plus the per-system base-unit lists reachable through `baseUnits`/`derivedUnits`
([`matlab-units-of-measurement.html`][muom] capture, function table). Exponents in
both systems are term-level numbers on symbolic expressions; every exponent in the
captured examples is an integer, and no capture states a domain restriction —
honest reading: the representation is open-ended, the documented practice is `ℤ`.

## Checking & inference

**Wolfram checks eagerly, per evaluation.** There is no inference because there are
no types: every check is a concrete computation on canonicalized unit expressions at
evaluation time. The `Quantity` page documents arithmetic only for the compatible
case — "Additions of Quantity objects with compatible units will heuristically
determine the result units" and likewise for products
([`wolfram-quantity.html`][wq] capture, "Properties & Relations") — with
`CompatibleUnitQ` provided to "test whether multiple quantities are compatible"
_before_ the fact ([`wolfram-units-guide.html`][wguide] capture). For conversion the
incompatible outcome is documented precisely
([`wolfram-unitconvert.html`][wuc] capture, "Possible Issues"):

> "UnitConvert will return $Failed for incompatible specifications, such as those
> between different unit dimensions:"

**MATLAB checks only when asked — checking is a query with a `logical` answer.**
`checkUnits(expr)` "checks expr for compatible dimensions and consistent units and
returns a structure containing the fields `Consistent` and `Compatible`. The fields
contain logical 0 (false) or logical 1 (true) depending on the check results"
([`matlab-checkunits.html`][mcheck] capture, description). Two design consequences
follow directly from the captures:

- **Unknowns are dimensionless by fiat.** "MATLAB® assumes that symbolic variables
  are dimensionless" ([`matlab-checkunits.html`][mcheck] capture) — so `A*u.m` is
  length-dimensioned regardless of what `A` "means". There is nothing like
  [Kennedy-style][kennedy] unit polymorphism for the symbolic variables; they are
  transparent to the analysis.
- **Compatibility and consistency are distinct verdicts.** "Checking units for
  consistency is a stronger check than compatibility. … For example, 1 Newton is
  consistent with 1 kg m/s² but not with 1 kg cm/s²"
  ([`matlab-checkunits.html`][mcheck] capture) — a coherence-of-scale check no other
  system in this survey names as a separate concept (it falls out of the lazy
  design: since `1*u.N + 1*u.kg*u.cm/u.s^2` is a legal un-normalized value, "same
  dimension but mismatched factors" is an observable state worth its own verdict).

**Dimensional polymorphism is trivial — and vacuous.** The generic `sqr : α → α²`
that stresses every static system costs nothing here: any function of a symbolic
expression works over any units, because nothing is checked at abstraction
boundaries (MATLAB) or before evaluation (Wolfram). The question the
[type-system-mechanisms][mechanisms] page asks — _can the checker prove it?_ — has
no referent; there is no checker in that sense. Wolfram does, however, ship genuine
**symbolic dimensional analysis** as library functions, closer to
[Buckingham π][pi] than to type checking ([`wolfram-units-guide.html`][wguide]
capture, "Dimensional Analysis"): `DimensionalCombinations` — "possible combinations
of dimensional physical quantities" — and `NondimensionalizationTransform` —
"convert an equation to dimensionless form" — operating on `QuantityVariable`
placeholders ("a variable representing a physical quantity").

## Extensibility

**Wolfram — three `Independent*` escape hatches plus curated exotica.** The guide's
"User-Defined Units & Physical Quantities" section names the extension points
([`wolfram-units-guide.html`][wguide] capture):

> "IndependentUnit — represent an arbitrary user-specified unit (e.g. "foxes")"

> "IndependentUnitDimension — represent a user-specified independent dimension for
> units"

plus `IndependentPhysicalQuantity` for named quantity kinds. An independent unit is
hermetic by construction — "An independent unit can only be converted to itself and
multiples or submultiples of itself" ([`wolfram-unitconvert.html`][wuc] capture,
"Properties & Relations") — exactly the fresh-generator semantics of a new base
dimension in the static systems, delivered at run time. Around the user extensions
sits the curated periphery no other surveyed system has: `DatedUnit` (a unit pinned
to a date), `CurrencyConvert` "using real-time data", `InflationAdjust`, and
`MixedUnit`/`MixedMagnitude` for sexagesimal-style compound displays ("a mixed unit
formed from a list of units (e.g. hours, minutes, seconds)"; all
[`wolfram-units-guide.html`][wguide] capture). The `"SIBase"` targets for the
non-SI dimensions are themselves curated policy: "The "SIBase" unit for
"InformationUnit" is "Bits"" and "The "SIBase" unit for "MoneyUnit" is "USDollars""
([`wolfram-unitconvert.html`][wuc] capture).

**MATLAB — a registry API in function form.** The Units of Measurement function
table documents `newUnit` ("Define new unit") and `removeUnit`, and a full
unit-system layer: `newUnitSystem` ("Define unit system"), `removeUnitSystem`,
`unitSystems`, `baseUnits`, `derivedUnits` — with SI, CGS, and US shipped by default
([`matlab-units-of-measurement.html`][muom] + [`matlab-unitconvert.html`][mconv]
captures). String round-tripping (`str2symunit`/`symunit2str`) and lookup
(`findUnits`, `isUnit`, `unitInfo`, `unitConversionFactor`) complete the registry
surface. The captured pages document these signatures but contain no worked
`newUnit` example, so none is shown here.

## Expressiveness edges

- **Affine temperature — both systems treat it, oppositely.** Wolfram distinguishes
  point and difference _in the unit itself_ and polices the [torsor][torsor]
  algebra in arithmetic ([`wolfram-quantity.html`][wq] capture, "Details" and
  "Properties & Relations"):

  > "Quantity expresses temperatures using units such as "DegreesCelsius" and
  > temperature differences using units such as "DegreesCelsiusDifference".
  > Quantity arithmetic operations systematically distinguish this."

  The documented rules are torsor-correct point by point: "Subtraction of
  temperatures in non-absolute scales like Celsius or Fahrenheit produces
  temperature differences"; "Addition of a temperature and a temperature difference
  gives another temperature"; "Operations involving products and divisions of
  temperatures may convert automatically to kelvins". Conversion is directional —
  temperatures convert _to_ differences "by interpreting them as differences with
  respect to absolute zero", but "Conversions from temperature differences to
  temperatures are not permitted" ([`wolfram-unitconvert.html`][wuc] capture).
  MATLAB instead resolves the ambiguity by **defaulting to differences**
  ([`matlab-unitconvert.html`][mconv] capture): "By default, temperatures are
  assumed to represent temperature differences. For example, `5*u.Celsius`
  represents a temperature difference of 5 degrees Celsius." — absolute readings
  are an opt-in flag, `unitConvert(T,u.K,'Temperature','absolute')` (documented
  result for 23 °C: `5923/20 K`, i.e. 296.15 K, typeset as a fraction in the
  capture). A documented sharp edge follows from the symbolic carrier: `0` times a
  unit collapses to a dimensionless `0`, so 0 °C must be written as the cell array
  `{0,u.Celsius}` to survive conversion (`unitConvert(tC,u.Fahrenheit,'Temperature','Absolute')`
  → `32*[Fahrenheit]`; [`matlab-symunit.html`][msym] capture, "Limitations").

- **Logarithmic units — MATLAB documents the absence.** From the `symunit` tips
  ([`matlab-symunit.html`][msym] capture): "Certain non-linear units, such as
  decibels, are not implemented because arithmetic operations are not possible for
  these units." An explicit, reasoned omission — contrast [Pint][pint]'s Beta-grade
  `dB` support. The five Wolfram captures neither document nor disclaim logarithmic
  units, so no claim is made for Wolfram either way.
- **Angles — a genuine dimension in Wolfram.** `"AngleUnit"` and `"SolidAngleUnit"`
  are listed base dimensions ([`wolfram-unitdimensions.html`][wud] capture), making
  Wolfram one of the few systems in the survey where radian-vs-steradian and
  angle-vs-dimensionless confusions are representable as dimension errors at all.
  The captured MATLAB pages are silent on angle dimensionality.
- **Kind vs dimension — a partial mechanism, documented at the temperature edge.**
  Wolfram's temperature handling is a _kind_ distinction layered above dimensions:
  "Temperatures and temperature differences share a common unit dimension"
  ([`wolfram-unitdimensions.html`][wud] capture) yet their arithmetic is
  "systematically" distinguished — the same shape as [mp-units][mp-units]'
  `quantity_spec` splitting kinds within one dimension, realized dynamically. The
  captures document no analogous torque-vs-energy or Hz-vs-Bq separation, and for
  MATLAB no kind machinery of any sort appears — absence is the finding.
- **Fractional powers** — undocumented either way in all nine captures (all shown
  exponents are integers). Given term-level symbolic exponents there is no
  structural reason they could not exist, but this page makes no claim the captures
  cannot back.
- **Uncertainty and curiosities.** Wolfram pairs quantities with uncertainty
  (`Around`, `VectorAround`, `MeanAround`; [`wolfram-units-guide.html`][wguide]
  capture) and admits units whose _definitions_ are intervals — "Some units contain
  Interval expressions, which can result in comparisons returning unevaluated"
  ([`wolfram-quantity.html`][wq] capture, "Possible Issues") — a corpus-realism
  wrinkle (a "cup" is not one number) that no fixed-factor registry in this survey
  can even state.

## Zero-cost story

Inverted twice over — and differently in each system.

**Wolfram: the quantity is the expression.** A `Quantity` is held symbolic data
(`HoldRest`) carrying its unit structure through every evaluation; canonicalization,
compatibility resolution, and the heuristic result-unit choice documented under
"Properties & Relations" all run inside the kernel's evaluator, per operation. The
captures contain no performance numbers; what they do document is the mitigation
shaped exactly like [Pint][pint]'s NumPy facet — `QuantityArray`, which factors the
unit out of a rectangular array: "Use QuantityArray to describe rectangular arrays
of Quantity objects of common units", with `Normal` converting back to "an
equivalent normal array of Quantity objects" ([`wolfram-quantity.html`][wq]
capture). Amortizing one unit over an array is precisely the concession that
per-element symbolic units cost too much.

**MATLAB: the exit door is the documented workflow.** Attaching `u.m` converts the
computation to _exact symbolic arithmetic_ — `9.81` becomes `981/100` — so the cost
is not a wrapper around a float but the difference between `sym` and `double`
computation wholesale. The docs present leaving the units system as the normal
final step ([`matlab-symunit.html`][msym] capture): "For numeric operations,
separate the value from the units, substitute for any symbolic parameters, and
convert the result to double" — and note the interop wall directly: "You may prefer
double output, or require double output for a MATLAB® function that does not accept
symbolic values." No erasure, no packed representation, no benchmark: the zero-cost
story is that there is none, by architecture.

## Diagnostics

Both systems are closed source with license-gated toolchains, so per this survey's
reproduction ladder the diagnostics below are **rung 3 — vendor docs**, quoted from
the local captures.

**MATLAB — the mismatch "diagnostic" is `logical 0`, not an error.** The
`checkUnits` page's first example is precisely this survey's mandated experiment —
a velocity equated to a mass flow — and its documented outcome
([`matlab-checkunits.html`][mcheck] capture, "Check Dimensions of Units"; Wayback
snapshot of 2019-12-15, R2019b-era page, function introduced R2017a):

```matlab
u = symunit;
syms A B
eqn = A*u.m/u.s == B*u.kg/u.s;
checkUnits(eqn,'Compatible')

ans =
  logical
   0
```

The equation itself constructs without complaint; the check is a separate, optional
query, and its answer is a bare logical. After `subs(eqn,u.kg,u.m)` the same call
returns `logical 1` (same capture). The two-field verdict form appears in the
projectile example — a `cm`-vs-`m` slip yields
([`matlab-checkunits.html`][mcheck] capture, "Check Dimensions and Consistency of
Units"):

```matlab
S = checkUnits([x y])

S =
  struct with fields:

    Consistent: [1 0]
    Compatible: [1 1]
```

— dimensions fine, scale factors wrong, and still no exception anywhere. The
consistency check that catches the slip
([`matlab-checkunits.html`][mcheck] capture, "Check Consistency of Units"):

```matlab
u = symunit;
expr1 = 1*u.N + 1*u.kg*u.m/u.s^2;
expr2 = 1*u.N + 1*u.kg*u.cm/u.s^2;
checkUnits(expr1,'Consistent')

ans =
  logical
   1

checkUnits(expr2,'Consistent')

ans =
  logical
   0
```

The third documented failure mode is quieter still: "If conversion is not possible,
unitConvert returns the input" ([`matlab-unitconvert.html`][mconv] capture) — a
no-op, distinguishable from success only by inspecting the result.

**Wolfram — documented sentinel, unquotable message.** The documented
incompatible-conversion behavior ([`wolfram-unitconvert.html`][wuc] capture,
"Possible Issues"):

```text
UnitConvert will return $Failed for incompatible specifications, such as
those between different unit dimensions:
```

[vendor docs — live-site capture of `reference.wolfram.com/language/ref/UnitConvert.html`,
fetched 2026-07-03]. For incompatible _addition_, the captures document the positive
contract only ("Additions of Quantity objects with compatible units will
heuristically determine the result units", [`wolfram-quantity.html`][wq] capture);
because the example cells are stored as images (see the capture-limitation note
above), the notebook message text emitted for an incompatible sum is **not present
in the local captures and is therefore not quoted here** — `CompatibleUnitQ` is the
documented pre-flight test.

## Ergonomics & compile-time cost

There is no compile time, so the ergonomic ledger is all about input convenience
and where the costs re-materialize:

- **Input is the headline feature.** Wolfram accepts free-form linguistics
  (quantities enterable via the Wolfram|Alpha interpreter and "Inline Free-form
  Input"; unknown unit strings are auto-canonicalized —
  [`wolfram-quantity.html`][wq] capture). MATLAB has tab completion on the
  collection — "You can use tab expansion to find names of units. Type `u.`, press
  Tab, and continue typing" — plus string input `symunit("m")`
  ([`matlab-symunit.html`][msym] capture, "Tips").
- **Naming conventions diverge exactly oppositely.** Wolfram: "Canonical unit
  strings are always plural" ([`wolfram-quantity.html`][wq] capture). MATLAB:
  "Plurals are not supported" ([`matlab-symunit.html`][msym] capture). A trivial
  detail with real porting-friction consequences between the two CAS dialects.
- **Failure ergonomics are the weak side.** Wolfram's `$Failed`/unevaluated forms
  appear wherever the offending expression happens to evaluate; MATLAB's `logical 0`
  verdicts appear only if somebody wrote the `checkUnits` call — the page's own
  examples model the intended workflow as _test-suite-like assertions_ over
  symbolic derivations, with `subs` used to fix the units and re-check
  ([`matlab-checkunits.html`][mcheck] capture).
- **Costs re-materialize as evaluation latency and data dependence.** Symbolic
  arithmetic in place of float arithmetic (MATLAB: exact rationals everywhere;
  Wolfram: kernel evaluation plus curated-corpus lookups), and for Wolfram's
  currency corner, a network round-trip ("An internet connection is required for
  conversion between currency units", [`wolfram-unitconvert.html`][wuc] capture).
  Neither vendor documents overhead numbers in the captured pages — contrast
  [Pint][pint], whose docs quantify their own ~38× scalar overhead.

## Strengths

- **Highest symbolic ceiling in the survey** — units participate in exact rational
  arithmetic, symbolic simplification, equation manipulation, and (Wolfram)
  nondimensionalization and dimensional-combination search; quantities and units
  are first-class values that can be inspected, rewritten, and solved over.
- **Wolfram's curated corpus** — NIST SP 811 coverage plus non-SI exotica no
  registry file matches: currencies with live rates, `DatedUnit`, inflation
  adjustment, mixed units, per-person and information dimensions, interval-defined
  units, uncertainty via `Around`.
- **Wolfram's temperature treatment** — point/difference distinguished in the unit
  system itself with torsor-correct arithmetic rules and directional conversion,
  matching [Pint][pint]'s delta units as the field's most explicit affine handling.
- **Angle and solid angle as dimensions (Wolfram)** — catches the `rad`/`sr`/`1`
  conflations that SI-conformant systems let through by construction.
- **MATLAB's compatible-vs-consistent distinction** — naming "same dimension,
  incoherent scale factors" as its own verdict is a genuinely useful diagnostic
  category unique to the lazy design.
- **Zero declaration overhead** — `3*u.m` or `Quantity[3, "Meters"]` and free-form
  input; new units and unit systems are one function call.

## Weaknesses

- **No static checking, no erasure — by architecture.** Everything this survey's
  typed systems guarantee before execution is here deferred to evaluation (Wolfram)
  or to an optional query the programmer must remember to write (MATLAB). An
  unexecuted or unchecked path ships silently.
- **MATLAB's silent modes compound.** Dimensionally absurd expressions are legal
  values; `unitConvert` returns its input on impossible conversions; symbolic
  variables are assumed dimensionless; `0*u.unit` loses its unit. Every failure
  mode defaults to _quiet_.
- **Closed source, docs-only auditability.** No mechanism can be read, no behavior
  reproduced without a commercial license; this very survey could ground the other
  systems in pinned source and had to ground these two in captures.
- **Wolfram's data dependence** — currency conversion requires an internet
  connection, and the curated corpus is a black box that updates on Wolfram's
  schedule, not the user's.
- **No documented kind discipline beyond temperature** — torque vs energy, Hz vs
  Bq: nothing in the captures suggests either system separates them.
- **MATLAB has no logarithmic units at all** (documented as impossible within its
  arithmetic model), and requires the Symbolic Math Toolbox — units are unavailable
  to plain-MATLAB numeric code.

## Key design decisions and trade-offs

| Decision                                                                                | Rationale                                                                                           | Trade-off                                                                                                              |
| --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Units as symbolic expressions in a CAS (both)                                           | Units flow through exact arithmetic, simplification, and solving; quantities are inspectable values | No erasure and no static story; every operation pays symbolic-evaluation cost                                          |
| Wolfram: curated corpus + free-form parsing instead of a definition file                | NIST SP 811 coverage, exotica (currency, dated units), forgiving input                              | Black-box registry; network dependence for live data; corpus evolves at vendor speed                                   |
| Wolfram: eager evaluation-time checking (`$Failed`, `CompatibleUnitQ`)                  | Errors surface where expressions evaluate; no discipline required of the user                       | Failures appear at use sites, not defect sites; sentinel values must be checked for                                    |
| MATLAB: units commute through arithmetic; checking is opt-in (`checkUnits`)             | Symbolic workflows stay unblocked; analysis runs when meaningful, on whole derivations              | The design point's cost: nothing stops a wrong equation until someone asks; verdicts are logicals, easy to not consult |
| MATLAB: separate `Compatible` vs `Consistent` verdicts                                  | Distinguishes wrong dimension from incoherent scale factors within a dimension                      | Two-step mental model; both checks must be run to clear an expression                                                  |
| Wolfram: temperature point vs difference as distinct units, shared dimension            | Torsor-correct affine arithmetic without leaving the units language                                 | Kind machinery exists only where curated (temperature); not user-extensible per the captures                           |
| MATLAB: temperatures default to _differences_; absolute is a conversion flag            | Makes ordinary arithmetic on temperature values legal by default                                    | Absolute-temperature intent must be remembered at every conversion; `0*u.Celsius` collapses to dimensionless `0`       |
| Wolfram: `"AngleUnit"`/`"SolidAngleUnit"` (+ money, information, persons) as dimensions | Catches angle conflations SI-conformant systems cannot; curated data needs the extra axes           | Diverges from the SI Brochure; conversions to SI base need curated policy (`"Bits"`, `"USDollars"`)                    |

## Sources

- Wolfram Language & System Documentation Center — local live-site captures
  (2026-07-03) under `$PAPERS/vendor-docs/`: [`Quantity`][wq]
  (`wolfram-quantity.html` — usage, `HoldRest`, NIST SP 811, temperature
  point/difference rules, `QuantityArray`, Interval-defined units);
  [`UnitConvert`][wuc] (`wolfram-unitconvert.html` — target unit systems,
  temperature conversion directionality, `$Failed` on incompatible specifications,
  currency internet requirement, `"SIBase"` policy for money/information);
  [`KnownUnitQ`][wkq] (`wolfram-knownunitq.html` — canonical-unit validation,
  `HoldFirst`, dimensional second argument); [`UnitDimensions`][wud]
  (`wolfram-unitdimensions.html` — dimension pairs, the 7 + 5 base-dimension lists,
  temperature/difference shared dimension, `IndependentUnit` as its own base);
  [Units & Quantities guide][wguide] (`wolfram-units-guide.html` — framing
  paragraph, `$UnitSystem`, `Independent*` extension points, dimensional-analysis
  and uncertainty function groups, `CurrencyConvert`/`DatedUnit`/`MixedUnit`).
- MATLAB Symbolic Math Toolbox — local Wayback captures under
  `$PAPERS/vendor-docs/`: [Units of Measurement][muom]
  (`matlab-units-of-measurement.html`, snapshot 2024-11-09 — intro, function table
  incl. `newUnit`/`newUnitSystem`/`baseUnits`/`derivedUnits`); [`symunit`][msym]
  (`matlab-symunit.html`, snapshot 2024-09-09 — collection semantics, exact
  rationalization, `separateUnits` workflow, temperature default, `0*unit` and
  decibel limitations, tips); [`checkUnits`][mcheck] (`matlab-checkunits.html`,
  snapshot 2019-12-15 (R2019b-era; function introduced R2017a) — compatible vs
  consistent definitions, all quoted example blocks); [`unitConvert`][mconv]
  (`matlab-unitconvert.html`, snapshot 2024-11-05 — conversion forms, unit systems,
  `'Temperature'` modes, returns-input-on-failure).
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [free abelian group][fag] · [torsors & affine quantities][torsor] ·
  [Buckingham π][pi] · [Kennedy's type system][kennedy] · [Pint][pint] ·
  [Julia `Unitful.jl`][unitful] · [F# units of measure][fsharp] ·
  [mp-units][mp-units] · [Au][au] · [`uom`][uom] · [concepts][concepts] ·
  [the comparison capstone][comparison]

<!-- References -->

<!-- Wolfram vendor docs (live pages; captured locally 2026-07-03 under $PAPERS/vendor-docs/) -->

[wq]: https://reference.wolfram.com/language/ref/Quantity.html
[wuc]: https://reference.wolfram.com/language/ref/UnitConvert.html
[wkq]: https://reference.wolfram.com/language/ref/KnownUnitQ.html
[wud]: https://reference.wolfram.com/language/ref/UnitDimensions.html
[wguide]: https://reference.wolfram.com/language/guide/Units.html

<!-- MATLAB vendor docs (Wayback snapshots matching the local captures) -->

[muom]: https://web.archive.org/web/20241109022526/https://www.mathworks.com/help/symbolic/units-of-measurement.html
[msym]: https://web.archive.org/web/20240909120544/https://www.mathworks.com/help/symbolic/symunit.html
[mcheck]: https://web.archive.org/web/20191215034843/https://www.mathworks.com/help/symbolic/checkunits.html
[mconv]: https://web.archive.org/web/20241105142208/https://www.mathworks.com/help/symbolic/unitconvert.html

<!-- Same-tree theory pages -->

[kennedy]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md
[pi]: ./theory/buckingham-pi.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[pint]: ./python-pint.md
[unitful]: ./julia-unitful.md
[fsharp]: ./fsharp-uom.md
[mp-units]: ./cpp-mp-units.md
[au]: ./cpp-au.md
[uom]: ./rust-uom.md
