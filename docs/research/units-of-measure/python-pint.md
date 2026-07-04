# Pint (Python)

The canonical runtime-checked units system: a `UnitRegistry` built by parsing a plain-text definition file into term-level data, a `Quantity` that wraps a magnitude and a dict-like `UnitsContainer` of unit-name → exponent, and dimensional analysis performed as ordinary dictionary arithmetic on every operation — with a `DimensionalityError` raised at the moment two incompatible quantities actually meet.

| Field            | Value                                                                                                                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language         | Python (`requires-python >= 3.12` at the pinned SHA; only `platformdirs`, `typing_extensions`, `flexcache`, `flexparser` as dependencies — NumPy optional)                                                               |
| License          | BSD 3-clause                                                                                                                                                                                                             |
| Repository       | [hgrecco/pint][repo]                                                                                                                                                                                                     |
| Documentation    | [pint.readthedocs.io][docs] · in-repo `docs/` (Sphinx)                                                                                                                                                                   |
| Key authors      | Hernan E. Grecco (original author); maintained with Jules Chéron and Andrew Savage ([`AUTHORS`][authors])                                                                                                                |
| Category         | [Runtime checking][concepts] (dynamic, term-level registry — no static guarantees of any kind)                                                                                                                           |
| Mechanism        | `UnitRegistry` parses `default_en.txt` into definition objects; `Quantity` = magnitude + `UnitsContainer` (mapping `str → exponent`); every operation resolves dimensionality by recursive lookup and raises on mismatch |
| Exponent domain  | Open-set base dimensions (a `[dimension]` springs into existence on first use) × term-level numeric exponents (`int`/`float`/`Fraction`/`Decimal`) — **fractional powers first-class**                                   |
| Checking time    | **Run time**, on every operation; unexecuted code paths are never checked                                                                                                                                                |
| Analyzed version | `7a927b4` (pinned clone, 2026-06-10; `0.26.0` development line, post-`0.25.3`)                                                                                                                                           |
| Latest release   | `0.25.3` (2026-03-19, per [`CHANGES`][changes])                                                                                                                                                                          |

> [!NOTE]
> Pint is this survey's canonical **runtime-checked** data point — the pole against
> which every static system ([F#][fsharp], [`uom`][uom], [mp-units][mp-units],
> [Au][au], …) defines its "zero-cost" claim (see the
> [mechanism taxonomy][mechanisms]). It is also the survey's most complete treatment
> of the [affine][torsor] (`degC` vs `delta_degC`) and logarithmic (`dB`) edges that
> most compile-time systems simply omit. A closing aside covers
> [`astropy.units`](#aside-astropy-units-the-astronomy-standard), the
> astronomy-standard alternative with its own `Equivalency` mechanism. See the
> [comparison capstone][comparison] for the cross-system synthesis.

---

## Overview

### What it solves

Pint gives Python programs unit-aware arithmetic with essentially zero declaration
overhead: multiply a number by `ureg.meter` and the result is a quantity that
converts, formats, and — crucially — refuses to combine with incompatible quantities.
The README states the scope in two sentences ([`README.rst`][readme]):

> "Pint is a Python package to define, operate and manipulate physical quantities:
> the product of a numerical value and a unit of measurement. It allows arithmetic
> operations between them and conversions from and to different units."

Because Python is dynamically typed, there is no type checker to enlist; the check
happens where everything else in Python happens — at run time, per operation. What
Pint trades away in static guarantees it recovers in expressiveness: open-set
dimensions, fractional exponents, offset units, logarithmic units, and NumPy-array
magnitudes all fit naturally once dimensions are ordinary data.

### Design philosophy

The docs list the design principles explicitly
([`docs/getting/overview.rst`][overview]). Two of them define Pint against every
other system in this survey.

**The registry is data, not code.** Units live in an editable text file, not in
source declarations:

> "**Standalone unit definitions**: units definitions are loaded from a text file
> which is simple and easy to edit. Adding and changing units and their definitions
> does not involve changing the code."

**Derived forms are parsed, not enumerated.** Prefixes and plurals compose
grammatically:

> "**Unit parsing**: prefixed and pluralized forms of units are recognized without
> explicitly defining them. In other words: as the prefix _kilo_ and the unit _meter_
> are defined, Pint understands _kilometers_. This results in a much shorter and
> maintainable unit definition list as compared to other packages."

The remaining principles — "Free to choose the numerical type" (`float`, `Decimal`,
`Fraction`, `numpy.ndarray`, uncertainties) and NumPy support "**without monkey
patching or wrapping numpy**" ([`README.rst`][readme]) — follow from the same
term-level stance: since nothing is compiled, the magnitude slot can hold anything
numeric.

---

## How it works

### `default_en.txt` — the registry-as-data design

`UnitRegistry()` parses [`pint/default_en.txt`][defaults] (924 lines: ~271 unit and
prefix definitions plus groups, systems, and contexts; mathematical and physical
constants arrive via `@import constants_en.txt`, [`default_en.txt`][defaults] L123).
The file's own header documents the grammar
([`default_en.txt`][defaults] L7–52):

```text
# pint: default_en.txt (header comment, abridged)
# Units
# -----
# <canonical name> = <relation to another unit or dimension> [= <symbol>] [= <alias>] [...]
#
# Prefixes
# --------
# <prefix>- = <amount> [= <symbol>] [= <alias>] [...]
#
# Derived dimensions
# ------------------
# [dimension name] = <relation to other dimensions>
#
# Note that primary dimensions don't need to be declared; they can be
# defined for the first time in a unit definition.
# E.g. see below `meter = [length]`
```

Representative lines, verbatim from the pinned file (one trailing `#` comment
elided from the `kelvin` line):

```text
# pint: default_en.txt L109-110, L115-118, L207, L230
meter = [length] = m = metre
second = [time] = s = sec
kelvin = [temperature]; offset: 0 = K = degK = °K = degree_Kelvin = degreeK
radian = [] = rad
count = []
degree_Celsius = kelvin; offset: 273.15 = °C = celsius = degC = degreeC
hertz = 1 / second = Hz
```

`meter = [length]` simultaneously _creates_ the base dimension `[length]` and names
`meter` its reference unit — the base-dimension set is open, extended by data rather
than by code. The `; offset:` and `; logbase:`/`; logfactor:` clauses select
non-multiplicative converters (below).

### `Quantity` and `UnitsContainer` — magnitude plus a dict of exponents

A quantity is a thin wrapper: one magnitude field and one immutable mapping from
unit names to exponents ([`pint/facets/plain/quantity.py`][quantity] L129–145,
[`pint/util.py`][util] L424–443):

```python
# pint: pint/facets/plain/quantity.py L129-145 (abridged)
class PlainQuantity(PrettyIPython, SharedRegistryObject, Generic[MagnitudeT_co]):
    """Implements a class to describe a physical quantity:
    the product of a numerical value and a unit of measurement."""

    _magnitude: MagnitudeT_co
```

```python
# pint: pint/util.py L424-443 (abridged)
class UnitsContainer(Mapping[str, Scalar]):
    """The UnitsContainer stores the product of units and their respective
    exponent and implements the corresponding operations.

    UnitsContainer is a read-only mapping. All operations (even in place ones)
    return new instances."""

    __slots__ = ("_d", "_hash", "_one", "_non_int_type")
```

`Scalar` covers `complex | float | int | Decimal | Fraction`
(`_BuiltinScalar`, [`pint/_typing.py`][typing] L18; plus `np.number` when NumPy is
present) — the exponent slot is an arbitrary Python number,
which is where fractional powers come from. Multiplication merges the dicts adding
exponents; division subtracts; `**` scales them — the
[free-abelian-group][fag] operations executed literally on hash maps at run time.
Dimensionality is derived on demand by recursing definitions down to base dimensions,
with a per-registry memo cache ([`pint/facets/plain/registry.py`][plainreg]
L719–741), and cached per quantity
([`quantity.py`][quantity] L349–359: `dimensionality` returns e.g.
`{length: 1, time: -1}`).

### Facets — the registry as a mixin stack

The `UnitRegistry` is assembled from orthogonal "facets", each contributing
definitions syntax, registry behavior, and `Quantity`/`Unit` mixins
([`pint/registry.py`][registry] L367–376):

```python
# pint: pint/registry.py L367-376
class GenericUnitRegistry[QuantityT: _Quantity, UnitT: _Unit](
    facets.GenericSystemRegistry[QuantityT, UnitT],
    facets.GenericContextRegistry[QuantityT, UnitT],
    facets.GenericDaskRegistry[QuantityT, UnitT],
    facets.GenericNumpyRegistry[QuantityT, UnitT],
    facets.GenericMeasurementRegistry[QuantityT, UnitT],
    facets.GenericNonMultiplicativeRegistry[QuantityT, UnitT],
    facets.GenericPlainRegistry[QuantityT, UnitT],
):
    pass
```

The facet package docstring frames the intent: "Facets are way to add a specific set
of funcionalities to Pint. … It aims to enable growth while keeping each part small
enough to be hackable" ([`pint/facets/__init__.py`][facets] L1–8). The `plain` facet
is multiplicative dimensional analysis; `nonmultiplicative` adds offset and
logarithmic units; `numpy` implements `__array_ufunc__`/`__array_function__` so
NumPy operations dispatch through a registry of unit-aware wrappers
([`pint/facets/numpy/numpy_func.py`][numpyfunc] L232–240, `HANDLED_FUNCTIONS`);
`measurement` adds uncertainty propagation; `context`, `group`, and `system` are
covered under [Extensibility](#extensibility).

Each registry instance _manufactures its own_ `Quantity`/`Unit` classes with the
registry bound as a class attribute ([`pint/util.py`][util] L1143–1160,
`create_class_with_registry`), so quantities are tied to one registry and
cross-registry operations are rejected — scoping by object identity, not by module.
String inputs (`ureg("9.8 m/s^2")`) go through `pint_eval`, "an expression evaluator
to be used as a safe replacement for builtin eval"
([`pint/pint_eval.py`][pinteval] L1–9), tokenizing with Python's own `tokenize`
rather than executing arbitrary code.

---

## Dimension representation

Dimensions are **term-level dictionaries over an open set of names**. A
dimensionality is itself a `UnitsContainer` whose keys are `[length]`-style strings
and whose values are numbers — computed, not declared: `_get_dimensionality_recurse`
walks each unit's definition down to reference units, multiplying exponents along the
way and summing contributions into an accumulator
([`pint/facets/plain/registry.py`][plainreg] L743–764). Zero entries are dropped and
the result is cached ([`plainreg`][plainreg] L731–741), so structural equality of
reduced dicts is dimension equality — the same normal-form idea as
[Kennedy's][kennedy] `ℤⁿ` vectors, transplanted to hash maps with three decisive
differences:

- **The basis is open.** Nothing fixes the number of base dimensions; `meter =
[length]` mints `[length]` on first sight, and a user file can mint `[currency]`
  the same way ([`default_en.txt`][defaults] header L38–40). Contrast every static
  system in this survey, where the base-dimension set is fixed per system at
  compile/`system!` time ([`uom`][uom], [mp-units][mp-units], [F#][fsharp]'s is open
  but compile-time).
- **Exponents are arbitrary numbers, not `ℤ`.** The shipped file itself uses
  fractional exponents — the Gaussian electromagnetic dimensions are half-integer
  ([`default_en.txt`][defaults] L735, L721):

  ```text
  # pint: default_en.txt L735, L721
  [gaussian_charge] = [length] ** 1.5 * [mass] ** 0.5 / [time]
      franklin = erg ** 0.5 * centimeter ** 0.5 = Fr = statcoulomb = statC = esu
  ```

  so the dimension group is effectively `ℚⁿ` (stored as `float`, or exactly via a
  `Fraction`-valued registry — `non_int_type`, [`pint/util.py`][util] L444–457) over
  a dynamically extensible basis. `planck_length = (hbar * gravitational_constant /
c ** 3) ** 0.5` ([`default_en.txt`][defaults] L166) type-checks — at run time —
  because `** 0.5` just halves every exponent in the dict.

- **Representation is never erased.** Every live `Quantity` physically carries its
  units dict; there is no phantom-type story to tell and no erasure theorem to
  invoke — see [Zero-cost story](#zero-cost-story).

## Checking & inference

The "algorithm" is deliberately trivial: **compare reduced dictionaries at each
operation**. Addition/subtraction reduces both sides to dimensionalities and demands
equality ([`pint/facets/plain/quantity.py`][quantity] L823–826):

```python
# pint: pint/facets/plain/quantity.py L823-826 (inside _add_sub)
if not self.dimensionality == other.dimensionality:
    raise DimensionalityError(
        self._units, other._units, self.dimensionality, other.dimensionality
    )
```

Multiplication/division merges unit dicts without any check (any product is a valid
dimension in a free abelian group); conversion (`.to()`) computes the source/target
root-unit factors and verifies their dimensionalities agree. Decidability is a
non-question — everything is finite data — but the flip side is that **checking
covers only the paths that execute**. A dimensional bug on an untested branch ships;
Pint's own test-suite culture (and the `wraps`/`check` decorators below) exists to
compensate.

There is **no inference** because there is nothing to infer: no types are assigned
to expressions before execution, and static type annotations (`Quantity[float]`,
[`docs/advanced/typing.rst`][typingdoc]) track the _magnitude_ type, not the
dimension. The [Kennedy][kennedy] problems — principal types, let-generalization
over dimensions, [AG-unification][kennedy] — dissolve rather than get solved.

**Dimensional polymorphism is free, and unchecked.** The generic `sqr : α → α²`
that stresses every static system in this survey is just a Python function:

```python
# locally reproduced against pint 0.25.2 (see Diagnostics for toolchain)
def sqr(x):
    return x * x

sqr(3.0 * ureg.meter)         # <Quantity(9.0, 'meter ** 2')>  — α → α²
sqr(2.0 * ureg.second)        # <Quantity(4.0, 'second ** 2')>
```

It works over every dimension — and over strings and lists too, with the failure
deferred to whenever the result meets something it cannot combine with. Opt-in
runtime contracts recover some discipline at function boundaries: `@ureg.wraps(ret,
args)` converts/strips arguments to declared units and `@ureg.check("[length]",
"[time]")` validates argument dimensionalities, raising `DimensionalityError` on
call ([`pint/registry_helpers.py`][helpers] L196, L315).

## Extensibility

Everything is extension, because everything is data:

- **New units — one line, at run time or in a file.**
  `ureg.define("smoot = 1.702 * meter = _ = smoots")` takes effect immediately
  [reproduced locally — see [Diagnostics](#diagnostics)]; persistent definitions go
  in a text file loaded with `ureg.load_definitions("my_def.txt")`, or a file passed
  to the constructor replaces the defaults entirely
  ([`docs/advanced/defining.rst`][defining]).
- **New base dimensions — implicit.** `USD = [currency]` creates the dimension and
  its reference unit in one line; nothing else is needed, and `[currency]` then
  participates in derived dimensions like any other
  ([`defining.rst`][defining]; the mechanism is the same `meter = [length]` line the
  default file uses).
- **Prefixes — grammatical, universal.** `yocto- = 10.0**-24 = y-` defines a prefix
  that composes with _every_ unit, including non-metric ones. The docs are candid
  about the trade ([`defining.rst`][defining]):

  > "It is important to note that prefixed defined in this way can be used with any
  > unit, including non-metric ones (e.g. kiloinch is valid for Pint). This
  > simplifies definitions files enormously without introducing major problems.
  > Pint, like Python, believes that we are all consenting adults."

- **Groups and systems — named collections and base-unit choices.** `@group`
  clusters units (`USCSLengthInternational`, `Avoirdupois`, …); `@system` picks the
  base units used by `to_base_units()` — the shipped file defines `SI`, `mks`,
  `cgs`, `atomic`, `Planck`, `imperial`, and `US`
  ([`default_en.txt`][defaults] L876–924), and
  `ureg.default_system` switches among them at run time
  ([`docs/user/systems.rst`][systems]).
- **Contexts — sanctioned dimension-crossing.** A `@context` registers _parametric_
  conversions between otherwise-incompatible dimensionalities, enabled per call or
  per block: the `spectroscopy` context maps `[length] <-> [frequency]` via
  `speed_of_light / n / value` (refractive index `n` is a context parameter,
  [`default_en.txt`][defaults] L816–822); the `Gaussian` and `ESU` contexts bridge
  the half-integer electromagnetic dimensions to SI ones
  ([`default_en.txt`][defaults] L752–785, L802–812). This is Pint's counterpart of astropy's
  equivalencies (below) — an escape hatch a static system would need a distinct
  quantity-relationship mechanism for.
- **Scoping.** Each `UnitRegistry` is an isolated world: quantities are instances of
  registry-specific classes ([`pint/util.py`][util] L1143–1160) and mixing
  registries raises. A process-wide `application_registry` provides a shared
  default (`set_application_registry`) for libraries that must interoperate
  ([`pint/__init__.py`][init] L61, L106–117).

## Expressiveness edges

- **Fractional powers: fully supported.** Exponents are numbers, so
  `(2 ** 0.5) * u.meter ** 0.5` is a legal quantity whose square comes back as
  `meter` (magnitude `2.0000000000000004` — float exponents, float error)
  [reproduced locally], and the shipped registry itself defines half-integer
  dimensions ([`[gaussian_charge]`](#dimension-representation)). No static system in
  this survey with `ℤ`-only exponents ([`uom`][uom], [`dimensioned`][dimensioned],
  [F#][fsharp]) can express these definitions at all; the `ℚ`-exponent systems
  ([mp-units][mp-units], [`dimensional`'s roots extension][dimensional]) can.
- **Affine quantities: the field's most explicit treatment.** Every offset unit
  (`degC`, `degF`, `degRe` — `degree_Celsius = kelvin; offset: 273.15`,
  [`default_en.txt`][defaults] L207) automatically gets a **delta counterpart**: the
  registry synthesizes `delta_degree_Celsius`/`Δ°C` with a purely multiplicative
  reference when the unit is added
  ([`pint/facets/nonmultiplicative/registry.py`][nonmulreg] L86–109). The arithmetic
  then implements the [torsor structure][torsor] point-by-point in `_add_sub`:
  point − point → delta (the result's unit is _renamed_ `delta_…`,
  [`quantity.py`][quantity] L853), point ± delta → point, delta ± delta → delta, and
  point + point raises `OffsetUnitCalculusError`
  ([`quantity.py`][quantity] L888). The docs state the rule
  ([`docs/user/nonmult.rst`][nonmult]):

  > "Additionally, for every non-multiplicative temperature unit in the registry,
  > there is also a _delta_ counterpart to specify differences. Absolute units have
  > no _delta_ counterpart. For example, the change in celsius is equal to the change
  > in kelvin, but not in fahrenheit (as the scaling factor is different)."

  Multiplication involving an offset unit is likewise policed
  (`_ok_for_muldiv` rejects any compound or exponentiated offset unit,
  [`pint/facets/nonmultiplicative/objects.py`][nonmulobj] L54–72) unless
  `autoconvert_offset_to_baseunit=True` converts to kelvin first; inside compound
  unit expressions, `default_as_delta=True` reads a bare `degC` as its delta
  counterpart (`J / (kg degC)` means per-kelvin-of-difference,
  [`nonmultiplicative/registry.py`][nonmulreg] L46–68). The conversion itself is an
  `OffsetConverter` — "An affine transformation." — applying
  `value * scale + offset` to reference and its inverse back
  ([`pint/facets/nonmultiplicative/definitions.py`][nonmuldef] L19–48).

- **Logarithmic quantities: present — nearly unique in this survey.** The
  definition-file syntax has a logarithmic clause
  ([`default_en.txt`][defaults] L527–548):

  ```text
  # pint: default_en.txt L529-547 (abridged)
  #  Unit = scale; logbase; logfactor
  #  x_dB = [logfactor] * log( x_lin / [scale] ) / log( [logbase] )
  decibelwatt = watt; logbase: 10; logfactor: 10 = dBW
  decibelmilliwatt = 1e-3 watt; logbase: 10; logfactor: 10 = dBm
  decibel = 1 ; logbase: 10; logfactor: 10 = dB
  decade = 1 ; logbase: 10; logfactor: 1
  octave = 1 ; logbase: 2; logfactor: 1 = oct
  neper = 1 ; logbase: 2.71828182845904523536028747135266249775724709369995; logfactor: 0.5 = Np
  ```

  implemented by `LogarithmicConverter` ("Converts between linear units and
  logarithmic units, such as dB, octave, neper or pH",
  [`nonmultiplicative/definitions.py`][nonmuldef] L60–87). `(10 *
u.milliwatt).to(u.dBm)` gives `10.0 dBm` and round-trips [reproduced locally], and
  `_add_sub` special-cases log+log so `dB` offsets compose with `dBm` levels by
  multiplying the linear base values ([`quantity.py`][quantity] L806–822). The docs
  flag the maturity honestly — "Support for logarithmic units in Pint is currently
  in Beta" — and most workflows need `autoconvert_offset_to_baseunit=True`
  ([`docs/user/log_units.rst`][logunits]); a dedicated
  `LogarithmicUnitCalculusError` covers the ambiguous cases
  ([`pint/errors.py`][errors] L241).

- **Angles: dimensionless, with documented consequences.** `radian = []`
  ([`default_en.txt`][defaults] L116) follows the SI Brochure's `rad = 1`
  convention; `(1 * u.radian).dimensionality` is empty, so angle-hood cannot be
  checked, and angular frequency conflates with frequency:
  `(1 * u.turn / u.second).to(u.Hz)` yields `6.283185307179586 hertz`
  [reproduced locally] — the docs devote a page to warning that converted values
  come out "`2 * pi` larger than expected"
  ([`docs/user/angular_frequency.rst`][angular]).
- **Kind vs dimension: absent — absence is the finding.** Pint has no kind system.
  `hertz = 1 / second` and `becquerel = counts_per_second` _look_ distinct in the
  registry, but `count = []` is dimensionless ([`default_en.txt`][defaults] L118,
  L230, L378), so both reduce to `1 / [time]` and interconvert silently:
  `(1000 * u.Bq).to(u.Hz)` → `1000 hertz`, and `(5 * u.N * u.m).to(u.J)` →
  `5.0 joule` with no complaint [both reproduced locally]. Torque-vs-energy,
  Hz-vs-Bq, and rad-vs-sr distinctions that [`uom`][uom]'s `Kind` tags,
  [mp-units][mp-units]' `quantity_spec` hierarchy, and [Au][au] maintain statically
  simply do not exist here.

## Zero-cost story

Inverted: **the cost is the story.** Every quantity is a Python object holding a
magnitude and a hash map; every `+` walks definitions (cached) and compares dicts;
nothing is erased. Pint's own documentation opens its performance page with the
concession ([`docs/advanced/performance.rst`][perf]):

> "Pint can impose a significant performance overhead on computationally-intensive
> problems. The following are some suggestions for getting the best performance."

and quantifies it with its own `%timeit` numbers on scalar quantities: `q1 - q2` at
**8.24 µs** versus `q1.magnitude - q2.magnitude` at **214 ns** — a ~38× overhead per
scalar operation — and a `scipy.optimize.brentq` root-find at **286 µs** with
quantities versus **1.14 µs** on raw magnitudes (~250×), because the wrapper cost is
paid inside every solver iteration ([`performance.rst`][perf]). The documented
mitigations are exactly the ones that abandon or amortize checking:

- **Drop to magnitudes** in hot loops (`q.magnitude`) — with the warning that this
  "loses the benefits of automatic unit conversion" ([`performance.rst`][perf]).
- **`@ureg.wraps`** — check/convert once at the function boundary, compute on bare
  numbers inside ([`performance.rst`][perf], [`registry_helpers.py`][helpers] L196).
- **NumPy magnitudes** — one dimensional check per _array_ operation instead of per
  element, making the relative overhead vanish for large arrays (the numpy facet's
  entire purpose; [`facets/numpy/numpy_func.py`][numpyfunc]).

Startup is also non-trivial: constructing `UnitRegistry()` parses and links the
924-line default file; the `cache_folder` option (backed by `flexcache`) memoizes
the parsed registry on disk precisely because this cost is visible
([`pint/registry.py`][registry] L422–433). For the survey's purposes Pint is the
measured baseline of what "no erasure" costs — the number the
[erasure theorems][mechanisms] of the static systems are worth.

## Diagnostics

The mandated experiment — adding metres to seconds — against `pint 0.25.2`
(nixpkgs `python3.withPackages`; the pinned clone `7a927b4` is the same `0.26.0`
development line, raise site at [`quantity.py`][quantity] L823–826):

```python
# locally reproduced — mismatch.py
import pint
u = pint.UnitRegistry()
print(1 * u.metre + 1 * u.second)
```

```text
Traceback (most recent call last):
  File "/home/petar/.claude/jobs/83fdacd5/tmp/repro-python-pint/mismatch.py", line 5, in <module>
    print(1 * u.metre + 1 * u.second)
          ~~~~~~~~~~~~^~~~~~~~~~~~~~
  File ".../site-packages/pint/facets/plain/quantity.py", line 874, in __add__
    return self._add_sub(other, operator.add)
           ~~~~~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^
  File ".../site-packages/pint/facets/plain/quantity.py", line 101, in wrapped
    return f(self, *args, **kwargs)
  File ".../site-packages/pint/facets/plain/quantity.py", line 787, in _add_sub
    raise DimensionalityError(
        self._units, other._units, self.dimensionality, other.dimensionality
    )
pint.errors.DimensionalityError: Cannot convert from 'meter' ([length]) to 'second' ([time])
```

[reproduced locally, `pint 0.25.2` / CPython `3.13.12` (nixpkgs), 2026-07-03; nix
store paths abbreviated to `...`, message otherwise verbatim]

The final line is the survey's most _readable_ mismatch diagnostic — unit names and
bracketed dimensionalities in domain language, generated by
`DimensionalityError.__str__` ([`pint/errors.py`][errors] L190–201) — delivered at
the worst possible time: in production, on the executed path, as an exception.
(Note the quirk: `1 * u.metre + 1 * u.second` fails dimensionally, but `u.metre +
u.second` — without magnitudes — is a plain `TypeError: unsupported operand type(s)
for +: 'Unit' and 'Unit'`, since bare `Unit` objects don't implement addition.)

Pint's distinctive affine edge, same toolchain [reproduced locally]:

```python
# locally reproduced — affine.py (abridged)
Q = u.Quantity
print(Q(25, "degC") + Q(5, "delta_degC"))   # 30 degree_Celsius
print(Q(25, "degC") - Q(20, "degC"))        # 5 delta_degree_Celsius
print(Q(25, "degC") + Q(5, "degC"))         # raises:
```

```text
pint.errors.OffsetUnitCalculusError: Ambiguous operation with offset unit (degree_Celsius, degree_Celsius). See https://pint.readthedocs.io/en/stable/user/nonmult.html for guidance.
```

The error even carries a documentation URL ([`pint/errors.py`][errors] L18,
L228–235). Multiplying an offset quantity (`Q(25, "degC") * Q(2, "m")`) raises the
same error class from the `_mul_div` gate [reproduced locally;
[`quantity.py`][quantity] L1035].

The valid-path counterpart, all against the same toolchain [reproduced locally]:

```python
# locally reproduced — valid.py
u.define("smoot = 1.702 * meter = _ = smoots")   # custom unit, one line
print((364.4 * u.smoot).to(u.meter))             # 620.2088 meter
v = 364.4 * u.smoot / (10 * u.second)
print(v, "|", v.dimensionality)                  # 36.44 smoot / second | [length] / [time]
print(3 * u.meter + 4 * u.cm)                    # 3.04 meter
print(((2 ** 0.5) * u.meter ** 0.5) ** 2)        # 2.0000000000000004 meter
print((10 * u.milliwatt).to(u.dBm))              # 10.0 decibelmilliwatt
```

## Ergonomics & compile-time cost

**Declaration overhead is the lowest in the survey.** `3 * ureg.meter` is a
quantity; `ureg("9.8 m/s^2")` parses one from a string; a new unit is one
`ureg.define(...)` line; a new dimension is implicit in its first reference unit.
There is no system/quantity/unit macro architecture to learn because there is no
compile-time architecture at all.

**Error readability is excellent** — domain-language unit names, bracketed
dimensions, and guidance URLs, as quoted above. The trade is _when_, not _what_: the
same message a static system would pin to a source line at compile time surfaces
here as a runtime exception wherever the incompatible values happen to meet, which
may be far from the defect.

**"Compile-time" cost translates to startup and per-operation cost.** Registry
construction parses the definition file on every fresh process (mitigated by
`cache_folder`/`flexcache`, [`registry.py`][registry] L422–433); after that the tax
is the per-operation overhead measured in [Zero-cost story](#zero-cost-story).
Static type checkers see `Quantity[float]` (PEP 561 `py.typed`,
[`docs/advanced/typing.rst`][typingdoc]) but have no view of dimensions — `mypy`
will happily pass a program that dies with `DimensionalityError` on its first run.

A closing curiosity: Pint operationalizes more of the survey's theory than most
static systems — it ships a working [Buckingham-π][pi] solver.
`pint.pi_theorem({'V': '[length]/[time]', 'T': '[time]', 'L': '[length]'})` returns
`[{'V': 1.0, 'T': 1.0, 'L': -1.0}]`, the dimensionless group `V·T/L`
([`docs/advanced/pitheorem.rst`][pitheorem], [`pint/util.py`][util] L226). Term-level
dimensions make the exponent linear algebra a routine matrix kernel computation.

---

## Aside: `astropy.units`, the astronomy standard

> [!NOTE]
> One subsection, not a full survey page: `astropy.units` is grounded in the local
> clone at `$REPOS/python/astropy` @ `8104d4c` (2026-07-02) and appears here as
> Pint's chief runtime-checked rival and a different set of design answers.

`astropy.units` predates its packaging in Astropy (it descends from `pynbody`'s
units module) and is the de-facto standard in astronomy. Same category as Pint —
runtime-checked, term-level — with five instructive divergences:

- **`Quantity` subclasses `numpy.ndarray`** ([`astropy/units/quantity.py`][apyq]
  L291: `class Quantity(np.ndarray)`), where Pint's `Quantity` _wraps_ its magnitude
  (composition). Subclassing buys tighter NumPy integration at the price of
  inheriting ndarray semantics everywhere (a scalar quantity is a 0-d array).
- **Units are class instances, not registry strings.** `UnitBase` /
  `IrreducibleUnit` / `CompositeUnit(scale, bases, powers)` objects compose
  arithmetically ([`astropy/units/core.py`][apycore] L74, L1887, L2265); new units
  come from `def_unit(...)` calls ([`apycore`][apycore] L2596) rather than a parsed
  definition file — code-as-registry where Pint is registry-as-data.
- **Exponents are sanitized to `int`/`float`/`Fraction`**
  ([`astropy/units/utils.py`][apyutils] L86–93, `sanitize_power`), preserving exact
  rational powers where Pint stores floats — same `ℚ`-exponent expressiveness,
  more careful representation.
- **Equivalencies replace both contexts and offset units.** An `Equivalency` is a
  list of `(from_unit, to_unit, forward, backward)` lambda tuples passed to
  `.to(unit, equivalencies=...)`: `spectral()` links wavelength ↔ frequency ↔
  energy; `dimensionless_angles()` lets radians vanish
  ([`astropy/units/equivalencies.py`][apyeq] L54, `spectral()` and
  `dimensionless_angles()`). Temperature is _also_ an equivalency — the docstring
  concedes the structural gap Pint's delta units fill
  ([`apyeq`][apyeq] L764–767):

  > "Convert degrees Celsius and degrees Fahrenheit here because Unit and
  > CompositeUnit cannot do addition or subtraction properly."

  There is no `delta_degC` analogue: `deg_C` ([`astropy/units/si.py`][apysi] L286)
  converts _values_ through affine lambdas, but quantity arithmetic has no
  point/difference distinction — Pint's [torsor][torsor] treatment is strictly
  stronger here.

- **Two features Pint lacks:** `PhysicalType` names dimensionalities
  (the joule's dimensionality is registered as `{"energy", "work", "torque"}` — an
  advisory, non-enforcing acknowledgment of the kind problem;
  [`astropy/units/physical.py`][apyphys] L37, L141, L414) and a _function-units_
  subsystem gives logarithmic units their own quantity classes (`Magnitude`, `Dex`,
  `Decibel` over `DexUnit`/`DecibelUnit` —
  [`astropy/units/function/logarithmic.py`][apylog] L158–192, L424–432), the
  astronomer's magnitudes and `dex` being daily currency.

## Strengths

- **Expressiveness ceiling of the whole survey** — open-set dimensions, `ℚ`
  exponents, offset units with auto-generated delta counterparts, logarithmic
  units, parametric conversion contexts, uncertainty propagation, NumPy/Dask
  magnitudes: every edge case the static systems triage away, Pint ships.
- **The most explicit affine treatment in the field** — `degC`/`delta_degC` with
  torsor-correct addition rules enforced at run time and ambiguity as a dedicated,
  documented error class.
- **Registry-as-data** — units, dimensions, prefixes, groups, systems, and contexts
  all live in an editable text file; extension requires no code, no recompilation,
  no fork.
- **Best-in-survey error messages** — `Cannot convert from 'meter' ([length]) to
'second' ([time])`, with docs URLs in the affine/logarithmic errors.
- **Near-zero adoption overhead** — one import, one registry, multiply by
  `ureg.meter`; string parsing for configuration-driven units.
- **Ecosystem reach** — `pint-pandas`, `pint-xarray`, and downstream packages
  (`fluids`, `thermo`, InstrumentKit, …) build on the
  facet/application-registry architecture ([`docs/ecosystem.rst`][ecosystem]).

## Weaknesses

- **No static guarantees whatsoever** — dimensional errors surface only on executed
  paths, at run time, as exceptions; `mypy` sees nothing. The entire class of
  guarantees this survey's other systems exist to provide is absent by design.
- **Measured runtime overhead** — ~38× on scalar arithmetic and ~250× inside tight
  solver loops by Pint's own documentation; the recommended fixes (magnitudes,
  `wraps`) selectively abandon checking.
- **No kind discipline** — Hz ↔ Bq and N·m ↔ J interconvert silently; angles are
  dimensionless and angular frequency conversions are off by `2π` from naive
  expectations (documented, but a trap).
- **Registry-instance fragmentation** — quantities from different `UnitRegistry`
  instances cannot interact, a recurring integration pitfall the
  application-registry machinery only partially papers over.
- **Logarithmic units are Beta** — compound log units and most operations need
  `autoconvert_offset_to_baseunit=True`; the docs warn about calculation errors.
- **Startup cost** — parsing the definition file per process, mitigated but not
  removed by `cache_folder`.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                                      | Trade-off                                                                                                          |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Term-level dimensions: `UnitsContainer` dict of name → exponent     | Open basis, `ℚ` exponents, runtime extensibility; dimension algebra is plain dict arithmetic                   | Nothing is erased — every quantity carries a dict; every operation pays lookup/compare cost                        |
| Registry-as-data (`default_en.txt` grammar)                         | Units/dimensions/prefixes/systems editable without touching code; translations and domain registries are files | Parse cost at startup; correctness of the "standard library" rests on a text file, not on reviewed code            |
| Checking at operation time, `DimensionalityError` on mismatch       | Zero declaration overhead; works for any dynamically-created dimension                                         | Only executed paths are checked; failures surface far from defects; test coverage substitutes for a type system    |
| Auto-generated `delta_` units + offset-aware `_add_sub`             | Torsor-correct affine arithmetic (point vs difference) with explicit ambiguity errors                          | Extra rules to learn (`default_as_delta`, `autoconvert_offset_to_baseunit`); multiplication with offsets is gated  |
| Logarithmic units as first-class converters (`logbase`/`logfactor`) | dB/dBm/octave/neper conversions and dB-shift arithmetic — unmatched in this survey                             | Feature is Beta; compound log units are error-prone; needs the autoconvert flag                                    |
| Angles dimensionless per SI (`radian = []`)                         | Follows the SI Brochure; keeps the base-dimension set minimal                                                  | Angle-hood unverifiable; frequency vs angular frequency conflated with a documented `2π` trap                      |
| Per-registry generated `Quantity`/`Unit` classes                    | Hard isolation between registries; facet mixins compose cleanly                                                | Cross-registry interop fails at run time; libraries must coordinate on the application registry                    |
| Magnitude-type agnosticism (`float`, `Decimal`, `Fraction`, arrays) | One implementation serves scalars, exact arithmetic, NumPy, Dask, uncertainties                                | Behavior differences leak through (float offsets vs `Decimal` magnitudes needed dedicated fixes — `CHANGES` #2305) |

## Sources

- [hgrecco/pint — GitHub repository][repo] (pinned locally at `$REPOS/python/pint`
  @ `7a927b4`, 2026-06-10)
- [`pint/default_en.txt` — the registry: grammar header, offset/log/fractional definitions, groups/systems/contexts][defaults]
- [`pint/util.py` — `UnitsContainer`, `pi_theorem`, `create_class_with_registry`][util] · [`pint/_typing.py` — `Scalar`][typing]
- [`pint/facets/plain/quantity.py` — `PlainQuantity`, `_add_sub`/`_mul_div`, dimensionality cache][quantity] · [`pint/facets/plain/registry.py` — `get_dimensionality` recursion + cache][plainreg] · [`pint/facets/plain/qto.py` — `to_compact`/`to_reduced_units`/`to_preferred`][qto]
- [`pint/facets/nonmultiplicative/` — `OffsetConverter`, `LogarithmicConverter`, delta-unit synthesis, `_ok_for_muldiv`][nonmuldef]
- [`pint/errors.py` — `DimensionalityError`, `OffsetUnitCalculusError`, `LogarithmicUnitCalculusError`][errors]
- [`pint/registry.py` — the facet stack and `UnitRegistry` options][registry] · [`pint/facets/__init__.py` — the facet architecture][facets]
- [`docs/getting/overview.rst` — design principles][overview] · [`docs/advanced/performance.rst` — overhead numbers][perf] · [`docs/user/nonmult.rst`][nonmult] · [`docs/user/log_units.rst`][logunits] · [`docs/user/angular_frequency.rst`][angular] · [`docs/advanced/defining.rst`][defining] · [`docs/advanced/pitheorem.rst`][pitheorem]
- [`README.rst`][readme] · [`CHANGES`][changes] · [`AUTHORS`][authors] · [pint.readthedocs.io][docs]
- astropy aside: [astropy/astropy — GitHub repository][apyrepo] (pinned locally at
  `$REPOS/python/astropy` @ `8104d4c`, 2026-07-02) — [`astropy/units/core.py`][apycore] · [`astropy/units/quantity.py`][apyq] · [`astropy/units/equivalencies.py`][apyeq] · [`astropy/units/physical.py`][apyphys] · [`astropy/units/function/logarithmic.py`][apylog]
- Local reproductions (mismatch, affine, logarithmic, kind-absence, valid ops):
  scratch scripts run under nixpkgs `python3.withPackages`, `pint 0.25.2` /
  CPython `3.13.12`, 2026-07-03
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [torsors & affine quantities][torsor] · [free abelian group][fag] ·
  [Kennedy's type system][kennedy] · [Buckingham π][pi] · [F# units of measure][fsharp] ·
  [`uom`][uom] · [`dimensioned`][dimensioned] · [`dimensional`][dimensional] ·
  [mp-units][mp-units] · [Au][au] · [Julia `Unitful.jl`][unitful] ·
  [Wolfram & MATLAB][wolfram] · [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone (pint @ 7a927b4) -->

[repo]: https://github.com/hgrecco/pint
[defaults]: https://github.com/hgrecco/pint/blob/7a927b4/pint/default_en.txt
[util]: https://github.com/hgrecco/pint/blob/7a927b4/pint/util.py
[typing]: https://github.com/hgrecco/pint/blob/7a927b4/pint/_typing.py
[quantity]: https://github.com/hgrecco/pint/blob/7a927b4/pint/facets/plain/quantity.py
[plainreg]: https://github.com/hgrecco/pint/blob/7a927b4/pint/facets/plain/registry.py
[qto]: https://github.com/hgrecco/pint/blob/7a927b4/pint/facets/plain/qto.py
[nonmuldef]: https://github.com/hgrecco/pint/blob/7a927b4/pint/facets/nonmultiplicative/definitions.py
[nonmulreg]: https://github.com/hgrecco/pint/blob/7a927b4/pint/facets/nonmultiplicative/registry.py
[nonmulobj]: https://github.com/hgrecco/pint/blob/7a927b4/pint/facets/nonmultiplicative/objects.py
[numpyfunc]: https://github.com/hgrecco/pint/blob/7a927b4/pint/facets/numpy/numpy_func.py
[errors]: https://github.com/hgrecco/pint/blob/7a927b4/pint/errors.py
[registry]: https://github.com/hgrecco/pint/blob/7a927b4/pint/registry.py
[facets]: https://github.com/hgrecco/pint/blob/7a927b4/pint/facets/__init__.py
[helpers]: https://github.com/hgrecco/pint/blob/7a927b4/pint/registry_helpers.py
[pinteval]: https://github.com/hgrecco/pint/blob/7a927b4/pint/pint_eval.py
[init]: https://github.com/hgrecco/pint/blob/7a927b4/pint/__init__.py
[readme]: https://github.com/hgrecco/pint/blob/7a927b4/README.rst
[changes]: https://github.com/hgrecco/pint/blob/7a927b4/CHANGES
[authors]: https://github.com/hgrecco/pint/blob/7a927b4/AUTHORS
[overview]: https://github.com/hgrecco/pint/blob/7a927b4/docs/getting/overview.rst
[perf]: https://github.com/hgrecco/pint/blob/7a927b4/docs/advanced/performance.rst
[nonmult]: https://github.com/hgrecco/pint/blob/7a927b4/docs/user/nonmult.rst
[logunits]: https://github.com/hgrecco/pint/blob/7a927b4/docs/user/log_units.rst
[angular]: https://github.com/hgrecco/pint/blob/7a927b4/docs/user/angular_frequency.rst
[defining]: https://github.com/hgrecco/pint/blob/7a927b4/docs/advanced/defining.rst
[pitheorem]: https://github.com/hgrecco/pint/blob/7a927b4/docs/advanced/pitheorem.rst
[systems]: https://github.com/hgrecco/pint/blob/7a927b4/docs/user/systems.rst
[typingdoc]: https://github.com/hgrecco/pint/blob/7a927b4/docs/advanced/typing.rst
[ecosystem]: https://github.com/hgrecco/pint/blob/7a927b4/docs/ecosystem.rst

<!-- Pinned clone (astropy @ 8104d4c) -->

[apyrepo]: https://github.com/astropy/astropy
[apycore]: https://github.com/astropy/astropy/blob/8104d4c/astropy/units/core.py
[apyq]: https://github.com/astropy/astropy/blob/8104d4c/astropy/units/quantity.py
[apyeq]: https://github.com/astropy/astropy/blob/8104d4c/astropy/units/equivalencies.py
[apyutils]: https://github.com/astropy/astropy/blob/8104d4c/astropy/units/utils.py
[apyphys]: https://github.com/astropy/astropy/blob/8104d4c/astropy/units/physical.py
[apylog]: https://github.com/astropy/astropy/blob/8104d4c/astropy/units/function/logarithmic.py
[apysi]: https://github.com/astropy/astropy/blob/8104d4c/astropy/units/si.py

<!-- Official docs -->

[docs]: https://pint.readthedocs.io/en/stable/

<!-- Same-tree theory -->

[kennedy]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md
[pi]: ./theory/buckingham-pi.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[fsharp]: ./fsharp-uom.md
[uom]: ./rust-uom.md
[dimensioned]: ./rust-dimensioned.md
[dimensional]: ./haskell-dimensional.md
[mp-units]: ./cpp-mp-units.md
[au]: ./cpp-au.md
[unitful]: ./julia-unitful.md
[wolfram]: ./wolfram-matlab.md
