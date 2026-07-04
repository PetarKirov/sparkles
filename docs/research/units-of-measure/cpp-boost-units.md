# Boost.Units (C++)

The 2007-era baseline for compile-time dimensional analysis in C++: `quantity<Unit, Y>` over MPL-style typelists of (base-dimension, `static_rational` exponent) pairs, checked entirely by template instantiation — rational exponents, mixed-system algebra, and affine temperatures a decade and a half before [mp-units][mp-units], at the price of C++03 metaprogramming ergonomics and the most notorious error messages in this survey.

| Field            | Value                                                                                                                                                                                                       |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | C++ (header-only; C++98/03-compatible template metaprogramming with opt-in `constexpr` — [P1935R2][p1935] classifies it as "C++98 + constexpr")                                                             |
| License          | Boost Software License 1.0                                                                                                                                                                                  |
| Repository       | [boostorg/units][repo]                                                                                                                                                                                      |
| Documentation    | [Boost.Units manual][boostdoc] (QuickBook source: [`doc/units.qbk`][qbk])                                                                                                                                   |
| Key authors      | Matthias C. Schabel (original author, 2003–2008); Steven Watanabe (co-author; the 2007 `dimension.hpp` rewrite)                                                                                             |
| Category         | Library-level [compile-time checking][concepts] (pure template metaprogramming; no compiler support, no macros-as-DSL)                                                                                      |
| Mechanism        | `quantity<unit<Dim, System>, Y>` where `Dim` is a sorted, reduced typelist of `dim<BaseDimension, static_rational<N, D>>` pairs; dimension algebra runs as MPL metafunctions (`mpl::times`, `static_power`) |
| Exponent domain  | `ℚ` over an **open set** of base dimensions — `static_rational<N, D>` exponents, GCD-normalized at compile time; rational powers first-class since the original design                                      |
| Checking time    | Compile time; zero runtime representation of dimensions                                                                                                                                                     |
| Analyzed version | `f39b667` (pinned clone, 2026-02-07; tagged `boost-1.91.0`)                                                                                                                                                 |
| Latest release   | Ships with every Boost release (Boost 1.91.0 at the pin); feature-frozen since library v1.2 (March 2010, Boost 1.43)                                                                                        |

> [!NOTE]
> Boost.Units is this survey's **C++03 baseline**: the proof, contemporaneous with
> [F#][fsharp]'s compiler-native measures, that a library can do full dimensional
> analysis — with `ℚ` exponents, which several later systems dropped — inside an
> unmodified compiler. In the [mechanism taxonomy][mechanisms] it sits with
> [`uom`][rust-uom]/[`dimensioned`][dimensioned] in the "checker _evaluates_
> normal forms, never solves" row, opposite the [Kennedy][kennedy] unification
> lineage. Its two C++20 successors, [mp-units][mp-units] and [Au][au], define
> themselves point-by-point against its pain points; see the
> [comparison capstone][comparison] for that lineage.

---

## Overview

### What it solves

Boost.Units brings compile-time dimensional analysis to C++ as a pure library. The
manual's opening paragraph is the positioning statement of the whole MPL era
([`doc/units.qbk`][qbk] L75–79):

> "The Boost.Units library is a C++ implementation of dimensional analysis in a
> general and extensible manner, treating it as a generic compile-time
> metaprogramming problem. With appropriate compiler optimization, no runtime
> execution cost is introduced, facilitating the use of this library to provide
> dimension checking in performance-critical code."

The scope was maximal from the start: "arbitrary unit system models and arbitrary
value types", "a fine-grained general facility for unit conversions", shipped SI and
CGS systems, plus systems for angles (degrees, radians, gradians, revolutions) and
temperatures (Kelvin, Celsius, Fahrenheit) ([`doc/units.qbk`][qbk] L78–85). The
release notes date the project precisely: v0.1 was "written as a Boost
demonstration of MPL-based dimensional analysis in 2003", v0.5.7 was "submitted for
formal review as a Boost library" in February 2007, and 1.0.0 shipped with
Boost 1.36 on August 1, 2008 ([`doc/units.qbk`][qbk] L1320–1465). The last feature
release was v1.2 (March 2010); everything since has been maintenance — the pinned
HEAD is a Boost 1.91-era cleanup merge (PR #66, `remove_static_assert`).

### Design philosophy

Two commitments shape every API decision, both stated in the manual.

**Safety above convenience.** Construction and conversion are deliberately strict
([`doc/units.qbk`][qbk] L461–470):

> "This library is designed to emphasize safety above convenience when performing
> operations with dimensioned quantities. Specifically, construction of quantities
> is required to fully specify both value and unit. Direct construction from a
> scalar value is prohibited …"

So `quantity<si::length> q(1.0);` does not compile; the idiom is
`quantity<si::length> q(1.0 * si::meter);`. The FAQ defends this with a
search-and-replace argument: replacing `si::` with `cgs::` in `q(1.0)` silently
turns one meter into one centimeter, while `q(1.0 * meter)` either converts
correctly or fails to compile ([`doc/units.qbk`][qbk] L1218–1256). Conversions
between unit systems are **explicit by default** — "Safety and the potential for
unintended conversions leading to precision loss and hidden performance costs"
([`doc/units.qbk`][qbk] L1258–1263) — and implicit only when two units reduce to
the identical set of base units ([`include/boost/units/quantity.hpp`][quantity-hpp]
L199–213, [`include/boost/units/unit.hpp`][unit-hpp] L96–100).

**Full generality of the dimension algebra.** The manual defines a dimension as "a
collection of zero or more base dimensions, each potentially raised to a different
**rational** power" ([`doc/units.qbk`][qbk] L119–121) — rational from the outset,
in 2003-vintage C++, a point the modern integer-exponent systems
([`uom`][rust-uom], [`dimensioned`][dimensioned]) quietly walked back. The price is
named in the same introduction: the library "relies heavily on the
[Boost Metaprogramming Library] (MPL) and on template metaprogramming techniques,
and is, as a consequence, fairly demanding of compiler compliance to ISO
standards" ([`doc/units.qbk`][qbk] L87–89), followed by a compatibility matrix of
2007 compilers (g++ 3.4/4.0, MSVC 7.1–9.0, Intel CC 9/10, Sun CC 5.9, CodeWarrior).

---

## How it works

### Base dimensions: CRTP tags with unique ordinals

A base dimension is an empty tag struct registered with a unique integer ordinal,
via CRTP ([`include/boost/units/base_dimension.hpp`][base-dimension-hpp] L48–66):

```cpp
// boost-units: include/boost/units/base_dimension.hpp L48-54 (doc comment)
/// Defines a base dimension.  To define a dimension you need to provide
/// the derived class (CRTP) and a unique integer.
///   struct my_dimension : boost::units::base_dimension<my_dimension, 1> {};
/// It is designed so that you will get an error message if you try
/// to use the same value in multiple definitions.
template<class Derived, long N> class base_dimension : public ordinal<N> { /* … */ };
```

The ordinal exists because dimensions are represented as **sorted** typelists (next
section): the sort key must be totally ordered, and C++ types are not — so the
author supplies the order. Uniqueness is enforced at compile time by a
friend-injection registration trick (`boost_units_is_registered` overloads,
[`base_dimension.hpp`][base-dimension-hpp] L86–100); colliding ordinals are a
compile error, and "negative ordinals are reserved for use by the library"
([`doc/units.qbk`][qbk] L236). The worked custom system in the examples defines
three ([`example/test_system.hpp`][test-system] L30–39):

```cpp
// boost-units: example/test_system.hpp L30-39
struct length_base_dimension : base_dimension<length_base_dimension,1> { };
struct mass_base_dimension   : base_dimension<mass_base_dimension,2> { };
struct time_base_dimension   : base_dimension<time_base_dimension,3> { };
```

### Dimensions: reduced typelists of `dim<Tag, static_rational>` pairs

A composite dimension is a typelist of `dim<Tag, Exponent>` pairs — the pair type
is trivial ([`include/boost/units/dim.hpp`][dim-hpp] L60–67) — where the exponent
is a compile-time rational, GCD-normalized inside the template
([`include/boost/units/static_rational.hpp`][static-rational-hpp] L125–157):

```cpp
// boost-units: include/boost/units/static_rational.hpp L125-149 (abridged)
template<integer_type N, integer_type D = 1>
class static_rational
{
    BOOST_STATIC_CONSTEXPR integer_type den =
        static_cast<integer_type>(boost::integer::static_gcd<nabs,dabs>::value)
        * ((D < 0) ? -1 : 1);
public:
    BOOST_STATIC_CONSTEXPR integer_type Numerator = N/den, Denominator = D/den;
    /// static_rational<N,D> reduced by GCD
    typedef static_rational<Numerator,Denominator> type;
};
```

Arbitrary lists (any order, duplicate tags, zero exponents) are collapsed to a
canonical **reduced dimension** by `make_dimension_list`, whose contract is the
load-bearing sentence of the whole design
([`include/boost/units/dimension.hpp`][dimension-hpp] L31–34):

> "Reduce dimension list to cardinal form. This algorithm collapses duplicate base
> dimension tags and sorts the resulting list by the tag ordinal value. Dimension
> lists that resolve to the same dimension are guaranteed to be represented by an
> identical type."

Same dimension ⇒ same C++ type: equality checking is type identity, with no
separate normalization pass at use sites. Dimension arithmetic is spelled as MPL
metafunction specializations on the list's tag ([`dimension.hpp`][dimension-hpp]
L42–51 doc comment, specializations L85–132): `mpl::times` merges two sorted lists adding exponents, `mpl::divides`
merges against the inverse, `static_power`/`static_root` multiply/divide every
exponent by a `static_rational` — and, tellingly, `mpl::plus`/`mpl::minus` are
"defined only on two equal dimensions" via a `BOOST_STATIC_ASSERT((is_same…))`.
The user-facing convenience wrapper handles integer powers
([`example/test_system.hpp`][test-system] L82–86):

```cpp
// boost-units: example/test_system.hpp L82-86 — energy = M L² T⁻²
typedef derived_dimension<length_base_dimension,2>::type  area_dimension;
typedef derived_dimension<mass_base_dimension,1,
                          length_base_dimension,2,
                          time_base_dimension,-2>::type   energy_dimension;
```

### Units and systems: the same algebra, tagged by who measures

A `unit` pairs a dimension with a **system** — the set of base units that give the
dimension a concrete measure ([`include/boost/units/unit.hpp`][unit-hpp] L36–65;
`template<class Dim, class System> class unit` is an empty, stateless class).
Systems come in two flavors, and the distinction is original to Boost.Units
([`doc/units.qbk`][qbk] L270–284):

- a **homogeneous system** is "a sorted list of base units"
  ([`include/boost/units/heterogeneous_system.hpp`][heterogeneous-hpp] L47–50) —
  e.g. SI, defined as `make_system<meter_base_unit, kilogram_base_unit, second_base_unit, ampere_base_unit, kelvin_base_unit, mole_base_unit, candela_base_unit, angle::radian_base_unit, angle::steradian_base_unit>::type`
  ([`include/boost/units/systems/si/base.hpp`][si-base-hpp] L36–45 — note **nine**
  base units, including plane and solid angle);
- a **heterogeneous system** is "a sorted list of base unit/exponent pairs" —
  needed when one quantity genuinely mixes base units of the same dimension. The
  manual's example is an aviation empirical formula ([`doc/units.qbk`][qbk]
  L279–284):

> "A practical example of the need for heterogeneous units, is an empirical
> equation used in aviation: H = (r/C)^2 where H is the radar beam height in feet
> and r is the radar range in nautical miles. In order to enforce dimensional
> correctness of this equation, the constant, C, must be expressed in nautical
> miles per foot^(1/2), mixing two distinct base units of length."

That constant is real shipped code — `1.23*nautical::miles/root<2>(imperial::feet)`
([`example/radar_beam_height.cpp`][radar] L129–136) — and exercises rational
exponents over a heterogeneous unit in one expression. Homogeneous systems exist
(rather than only heterogeneous ones) so that unit information survives round
trips: the FAQ's example is `asin(sin(90.0 * degrees))`, which must print in
degrees, yet `sin` returns a `quantity<dimensionless>` — only the homogeneous
system tag remembers "dimensionless _in the degree system_"
([`doc/units.qbk`][qbk] L1203–1216).

Unit-level arithmetic mirrors dimension arithmetic: `multiply_typeof_helper` on two
same-system units multiplies the dimensions and keeps the system; on
different-system units it promotes both to heterogeneous form and merges
([`include/boost/units/unit.hpp`][unit-hpp] L136–217).

### Quantities and `BOOST_UNITS_STATIC_CONSTANT`

`quantity<Unit, Y>` is the one value-carrying type — a single `Y val_` field
with a compile-time layout check ([`include/boost/units/quantity.hpp`][quantity-hpp]
L88–104, L477–478):

```cpp
// boost-units: include/boost/units/quantity.hpp (abridged)
template<class Unit, class Y = double>
class quantity
{
public:
    BOOST_CONSTEXPR quantity() : val_()
    {
        BOOST_UNITS_CHECK_LAYOUT_COMPATIBILITY(this_type, Y);  // sizeof(quantity) == sizeof(Y)
    }
    // no quantity(Y) constructor — construct as `2.0 * si::meters`
    static BOOST_CONSTEXPR this_type from_value(const value_type& val);  // escape hatch
    BOOST_CONSTEXPR const value_type& value() const { return val_; }
private:
    value_type val_;
};
```

`Y` defaults to `double` but is fully generic — the examples run quantities over
`std::complex<double>`, `boost::math::quaternion`, and a `measurement` type with
error propagation ([`doc/units.qbk`][qbk] L657–799), with result value types
deduced through the `add_typeof_helper`/`multiply_typeof_helper` family so that
even asymmetric value-type algebras (natural ∖ integer ∖ rational) work
([`doc/units.qbk`][qbk] L391–413).

The unit constants used in the `2.0 * si::meters` idiom are made ODR-safe in
headers by `BOOST_UNITS_STATIC_CONSTANT` — in C++03, a template-static-member +
anonymous-namespace-reference trick; under C++11 just a `constexpr` variable
([`include/boost/units/static_constant.hpp`][static-constant-hpp] L16–36):

```cpp
// boost-units: include/boost/units/static_constant.hpp L19-32 (C++03 branch)
#define BOOST_UNITS_STATIC_CONSTANT(name, type)                       \
template<bool b> struct name##_instance_t { static const type instance; }; \
namespace { static const type& name = name##_instance_t<true>::instance; } \
template<bool b> const type name##_instance_t<b>::instance
```

A curiosity worth recording: the macro is a pre-C++17 emulation of `inline`
variables, and its presence in every system header (`BOOST_UNITS_STATIC_CONSTANT(meter, length);` …,
[`example/test_system.hpp`][test-system] L112–125) dates the library as precisely
as the compiler matrix does.

---

## Dimension representation

The dimension of a quantity is a **canonically sorted typelist of
(base-dimension tag, `ℚ` exponent) pairs** — `list<dim<length_base_dimension, static_rational<1>>, dimensionless_type>`
is `length_dimension`, and the terminator `dimensionless_type` doubles as the
dimension-one value ([`include/boost/units/base_dimension.hpp`][base-dimension-hpp]
L72, [`example/dimension.cpp`][dimension-ex] L50–71). Three properties characterize
the representation against the rest of the survey:

- **Exponents are rationals, not integers.** Every exponent slot is a
  `static_rational<N, D>` reduced by compile-time GCD; `static_power`/`static_root`
  scale all exponents by a rational. `m^(1/2)` is a first-class dimension (see
  [Expressiveness edges](#expressiveness-edges)), where [`uom`][rust-uom] and
  [`dimensioned`][dimensioned] structurally cannot write it. This is the
  [free abelian group][fag] over the base-dimension tags with `ℚ`-valued —
  strictly, free `ℚ`-vector-space — exponents, computed by sorted-list merge.
- **The basis is open, not fixed.** There is no 7-slot vector: any type with a
  unique ordinal is a base dimension, and a dimension list only mentions tags with
  non-zero exponent ("dimensions with zero exponent are elided",
  [`doc/units.qbk`][qbk] L213–218). Users add base dimensions (currency, decays,
  pixels) without touching the library — the exact extension the FAQ prescribes for
  becquerel-vs-hertz disambiguation.
- **Normalization is by construction, and identity is type identity.** Sorting by
  ordinal plus zero-elision makes the reduced form unique, so "dimension lists that
  resolve to the same dimension are guaranteed to be represented by an identical
  type" ([`dimension.hpp`][dimension-hpp] L31–34). Nothing compares dimension lists
  structurally at use sites; `boost::is_same` does all the work.

One layer up, the **system** parameter re-runs the same trick over base _units_:
a heterogeneous system is a sorted list of `heterogeneous_system_dim<BaseUnit, Exponent>`
pairs plus a dimension and a scale
([`include/boost/units/heterogeneous_system.hpp`][heterogeneous-hpp] L60–92), which
is how `nmi·ft^(-1/2)` keeps both length units alive in one type. Scaled base units
are represented symbolically, not numerically: the kilogram is literally
`scaled_base_unit<gram_base_unit, scale<10, static_rational<3>>>` — "this basically
defines a kilogram as being 10^3 times a gram" ([`doc/units.qbk`][qbk] L329–348) —
so prefix relationships survive in the type and conversions/symbols derive
automatically (and the SI mass unit prints its heritage in every error message; see
[Diagnostics](#diagnostics)).

## Checking & inference

All checking is **template instantiation evaluating metafunctions** — in the
[taxonomy of this survey][mechanisms], the checker _evaluates_ dimension arithmetic
the author wrote; it never _solves_ for anything. The mechanics differ by operation:

- **Multiplication/division** compute the result type: `operator*` on quantities
  has return type `multiply_typeof_helper<…>::type`, which merges the two sorted
  dimension lists via `mpl::times` ([`unit.hpp`][unit-hpp] L136–163,
  [`quantity.hpp`][quantity-hpp] L743–762, L1172–1184). The merge is structural
  recursion over sorted lists — terminating, decidable, no search.
- **Addition/subtraction** demand type equality — enforced not by an assert but by
  **SFINAE-controlled absence**: the `add_typeof_helper` for two quantities of
  different dimensions is an empty struct with no `type` member
  ([`quantity.hpp`][quantity-hpp] L590–610), so `operator+` drops out of overload
  resolution and the compiler reports "no match for `operator+`" (see
  [Diagnostics](#diagnostics)). The commented rationale — "for sun CC we need to
  invoke SFINAE at the top level, otherwise it will silently return int" — is
  2008-era compiler archaeology preserved in place.
- **Powers/roots** cannot overload `std::pow` (the exponent must be a compile-time
  value to compute the result dimension), so the library ships `pow<N>`/`pow<static_rational<N,D>>`
  and `root<N>` free functions ([`doc/units.qbk`][qbk] L286–294,
  [`include/boost/units/pow.hpp`][pow-hpp]).

**Inference: none.** C++ template argument deduction gives local, forward-only
convenience (`auto e = f * d;` picks up the energy type), but nothing
Kennedy-shaped exists: no principal types, no solving `α² = area` for `α`, no
generalization. What Boost.Units _does_ support — and idiomatically — is
**dimensional polymorphism spelled as templates**, in two axes:

```cpp
// boost-units: example/kitchen_sink.cpp L200-210 — generic over the SYSTEM
template<class System, class Y>
constexpr quantity<unit<energy_dimension, System>, Y>
work(quantity<unit<force_dimension, System>, Y> F,
     quantity<unit<length_dimension, System>, Y> dx)
{
    return F * dx;
}
```

([`example/kitchen_sink.cpp`][kitchen-sink] L200–210.)

```cpp
// locally reproduced — generic over the UNIT: sqr : quantity<U> → quantity<U²>
template<class U, class Y>
typename power_typeof_helper<quantity<U, Y>, static_rational<2> >::type
sqr(const quantity<U, Y>& q) { return pow<2>(q); }

sqr(3.0 * si::meters);   // 9 m^2
sqr(2.0 * si::watts);    // 4 m^4 kg^2 s^-6
```

Both compile and run against the pinned clone [reproduced locally, `g++ 15.2.0`,
2026-07-03]. The generic `sqr : α → α²` is therefore _expressible_ — but the
author must name the result type via the `typeof_helper` machinery in the
signature, the C++03 ancestor of [`uom`][rust-uom]'s seven-fold `typenum` bounds
and precisely the boilerplate [F#][fsharp] erases with measure inference.

## Extensibility

Extensibility is Boost.Units' strongest suit, and the manual walks a complete
custom system in ~40 lines ([`example/test_system.hpp`][test-system]): base
dimensions with ordinals, base units tied to dimensions, `make_system`, unit
typedefs, `BOOST_UNITS_STATIC_CONSTANT` constants, and `base_unit_info`
specializations for names/symbols. The tiers:

- **New base dimension** — a one-line CRTP struct with a user-chosen positive
  ordinal; collisions are compile errors. The becquerel FAQ shows the intended
  use: "expanding the set of base dimensions can provide disambiguation … adding a
  base dimension for radioactive decays would allow the becquerel to be written as
  decays/second" ([`doc/units.qbk`][qbk] L1183–1191). [P1935R2][p1935] reproduces a
  worked currency system (a `currency_base_dimension` plus per-currency base units
  with runtime-looked-up conversion factors) built this way.
- **New base unit** — `struct foot_base_unit : base_unit<foot_base_unit, length_dimension, 10> {};`
  plus a conversion: `BOOST_UNITS_DEFINE_CONVERSION_FACTOR(foot_base_unit, meter_base_unit, double, 0.3048);`
  ([`doc/units.qbk`][qbk] L429–444). `BOOST_UNITS_DEFAULT_CONVERSION` designates a
  hub unit so N units need N conversions, not N²; conversion factors may even be
  runtime values ([`example/runtime_conversion_factor.cpp`][example-dir]). Base
  units can carry _derived_ dimensions too (a base unit of L·T⁻¹, say —
  [`example/non_base_dimension.cpp`][example-dir]).
- **Scaled units, two ways** — `scaled_base_unit` (kilogram = `scale<10, static_rational<3>>`
  of gram) inherits conversions and symbols from the parent; `make_scaled_unit`
  scales a whole unit (`nanosecond` from `si::time`), the mechanism behind
  [`systems/si/prefixes.hpp`][si-base-hpp] ([`doc/units.qbk`][qbk] L329–366).
- **New system** — `make_system<…>::type` over any base-unit set; the shipped
  catalog has SI, CGS, four angle systems, Celsius/Fahrenheit temperature systems,
  an abstract system for pure dimensional reasoning, and an information system
  (bit, byte, nat, hartley, shannon — [`systems/information/`][info-dir]).
- **Cross-system interop is a design center, not an afterthought.** Explicit
  `quantity<si::length>(q_nautical)` conversion works wherever a factor chain
  exists; implicit conversion is permitted exactly when `reduce_unit` yields the
  identical type (SI seconds ↔ CGS seconds); and heterogeneous units let one
  expression mix systems — `1.5*si::meter*cgs::centimeter` is a well-typed m·cm
  quantity, explicitly convertible to `quantity<si::area>`
  ([`example/heterogeneous_unit.cpp`][het-ex] L59–84). Contrast
  [`uom`][rust-uom], where two `system!` invocations produce unrelated worlds.

## Expressiveness edges

- **Fractional powers: yes, first-class — the survey's earliest system to have
  them.** `root<2>(4.0 * si::meters)` compiles and prints `2 m^(1/2)`
  [reproduced locally, `g++ 15.2.0`, 2026-07-03]; the radar-beam-height constant
  `nmi·ft^(-1/2)` is shipped example code ([`example/radar_beam_height.cpp`][radar]
  L129–136). The one gap is at the _value_ level, by design: `static_power`/`static_root`
  of a `static_rational` are undefined "because template types may not be floating
  point values, while powers and roots of rational numbers can produce floating
  point values" ([`static-rational.hpp`][static-rational-hpp] L64–66) — exponents
  stay exact rationals; only conversion _factors_ go through `double`.
- **Affine quantities: a real point/vector distinction, temperature-scoped.** The
  `absolute<Y>` wrapper implements the [torsor][torsor] operations exactly
  ([`include/boost/units/absolute.hpp`][absolute-hpp] L28–33):

  > "A wrapper to represent absolute units (points rather than vectors). Intended
  > originally for temperatures, this class implements operators for absolute units
  > so that addition of a relative unit to an absolute unit results in another
  > absolute unit : `absolute<T> +/- T -> absolute<T>` and subtraction of one
  > absolute unit from another results in a relative unit :
  > `absolute<T> - absolute<T> -> T`."

  Point-point addition simply has no overload. Offsets are registered per unit
  pair — `BOOST_UNITS_DEFINE_CONVERSION_OFFSET(si::kelvin_base_unit, temperature::celsius_base_unit, double, -273.15);`
  ([`include/boost/units/base_units/temperature/conversions.hpp`][temp-conv] L21–30)
  — and the Fahrenheit worked example converts absolute °F to absolute K and
  interval °F to interval K with different arithmetic
  ([`example/temperature.cpp`][temperature-ex] L70–90). Unlike [Au][au]'s
  `QuantityPoint`, `absolute` is generic in principle but used only for
  temperature in the shipped systems.

- **Logarithmic quantities: absent.** No decibel, neper, or level type exists
  anywhere under `include/` (verified by search of the pinned clone) — the same
  gap as most of the survey; [Pint][pint] is the exception.
- **Angles: a base dimension, opt-in by system choice.** Boost.Units' "SI" is a
  nine-base-unit system — the seven SI bases plus radian and steradian
  ([`systems/si/base.hpp`][si-base-hpp] L36–45). Consequently **torque and energy
  are genuinely different types**: `torque_dimension` is
  `derived_dimension<length_base_dimension,2, mass_base_dimension,1, time_base_dimension,-2, plane_angle_base_dimension,-1>`
  ([`include/boost/units/physical_dimensions/torque.hpp`][torque-dim] L25–28) —
  N·m·rad⁻¹, not J. The FAQ owns the design ([`doc/units.qbk`][qbk] L1171–1181,
  L1195–1201): "Because Boost.Units includes plane and solid angle units in the SI
  system, torque and energy are, in fact, distinguishable", and for those who
  object to dimensioned angles: "you can just ignore the angle units and go on
  your merry way (periodically screwing up when a routine wants degrees and you
  give it radians instead…)". `cmath.hpp` gives trig over angular quantities and
  inverse trig returning them ([`include/boost/units/cmath.hpp`][cmath-hpp]).
- **Kind-vs-dimension: solved only by adding base dimensions — and honestly
  documented as unsolved otherwise.** There is no kind tag (contrast
  [`uom`][rust-uom]'s `Kind`, [mp-units][mp-units]' `quantity_spec` hierarchy):
  becquerel and hertz are the _same type_ (`activity_dimension` and
  `frequency_dimension` are both `derived_dimension<time_base_dimension,-1>` —
  [`physical_dimensions/activity.hpp`][activity-dim] L22,
  [`physical_dimensions/frequency.hpp`][frequency-dim] L22), and the FAQ concedes "the
  sievert … is degenerate with the gray", prescribing a new base dimension as the
  remedy ([`doc/units.qbk`][qbk] L1183–1191). Angle-aware torque is thus the only
  shipped kind-like distinction, achieved dimensionally rather than by tagging.
- **Dimensionless quantities collapse to scalars** — implicit conversion to the
  value type is allowed by specialization ([`quantity.hpp`][quantity-hpp]
  L457–458), with the homogeneous-system tag retaining which system's
  dimensionless you have (the `asin(sin(...))` FAQ above).

## Zero-cost story

The claim is in the first paragraph of the manual ("no runtime execution cost",
quoted above) and is backed at three levels in the clone plus one local check:

- **Representation:** `quantity` stores exactly one `Y`; every constructor runs
  `BOOST_UNITS_CHECK_LAYOUT_COMPATIBILITY(this_type, Y)`, which is
  `BOOST_STATIC_ASSERT((sizeof(a) == sizeof(b)))` under the testing config
  ([`include/boost/units/config.hpp`][config-hpp] L73–78) — the C++03 spelling of
  [`uom`][rust-uom]'s `#[repr(transparent)]` guarantee. `unit` and all dimension
  machinery are empty types that exist only in signatures.
- **The project's own evidence:** an ad hoc benchmark comparing `quantity<double>`
  matrix code against raw `double` ([`example/performance.cpp`][performance-ex]),
  with the manual reporting "zero overhead for this test has been verified using
  gcc 4.0.1, and icc 9.0, 10.0, and 10.1 on Mac OS 10.4 and 10.5, and using
  msvc 8.0 on Windows XP" ([`doc/units.qbk`][qbk] L801–813). Period hardware,
  period compilers — but a real measurement, not an assertion.
- **Local codegen check** [reproduced locally, `g++ 15.2.0 -O2`, 2026-07-03]:
  compiling `f * d + e` both as raw `double`s and as
  `quantity<si::force> * quantity<si::length> + quantity<si::energy>` yields the
  same two-instruction core (`mulsd`, `addsd`) for both functions — the dimension
  algebra leaves no instruction behind.
- **The honest ABI caveat the docs don't mention:** `quantity` declares its own
  copy constructor and copy assignment ([`quantity.hpp`][quantity-hpp] L111–132),
  making it non-trivially-copyable — so under the Itanium ABI a
  `quantity<si::energy>` argument is passed by invisible reference (memory) where
  a `double` rides in `%xmm0`. In the same local check the `quantity` version
  loads its operands from pointers. Inlining erases the difference inside a TU;
  across un-inlined ABI boundaries a `quantity` is _not_ calling-convention-
  identical to its scalar. (The mangled name of that little function is 715
  characters — see [Ergonomics](#ergonomics--compile-time-cost).)

## Diagnostics

The mandated experiment — adding meters to seconds — compiled against the pinned
clone's headers (`-I $REPOS/cpp/boost-units/include`, sibling Boost 1.87.0 headers
for MPL):

```cpp
// locally reproduced — mismatch.cpp
#include <boost/units/quantity.hpp>
#include <boost/units/systems/si.hpp>

using namespace boost::units;

int main()
{
    quantity<si::length> d = 2.0 * si::meters;
    quantity<si::time>   t = 1.0 * si::seconds;
    auto oops = d + t;   // dimension mismatch: L + T
    (void)oops;
}
```

The full error is **37 lines and 9,821 bytes** for this 12-line program; the
longest single line is 2,087 characters. Head and tail verbatim, middle elided:

```text
mismatch.cpp: In function ‘int main()’:
mismatch.cpp:10:19: error: no match for ‘operator+’ (operand types are ‘boost::units::quantity<boost::units::unit<boost::units::list<boost::units::dim<boost::units::length_base_dimension, boost::units::static_rational<1> >, boost::units::dimensionless_type>, boost::units::homogeneous_system<boost::units::list<boost::units::si::meter_base_unit, boost::units::list<boost::units::scaled_base_unit<boost::units::cgs::gram_base_unit, boost::units::scale<10, boost::units::static_rational<3> > >, boost::units::list<boost::units::si::second_base_unit, boost::units::list<boost::units::si::ampere_base_unit, boost::units::list<boost::units::si::kelvin_base_unit, boost::units::list<boost::units::si::mole_base_unit, boost::units::list<boost::units::si::candela_base_unit, boost::units::list<boost::units::angle::radian_base_unit, boost::units::list<boost::units::angle::steradian_base_unit, boost::units::dimensionless_type> > > > > > > > > > > >’ and ‘boost::units::quantity<boost::units::unit<boost::units::list<boost::units::dim<boost::units::time_base_dimension, boost::units::static_rational<1> >, boost::units::dimensionless_type>, boost::units::homogeneous_system<boost::units::list<boost::units::si::meter_base_unit, boost::units::list<boost::units::scaled_base_unit<boost::units::cgs::gram_base_unit, boost::units::scale<10, boost::units::static_rational<3> > >, boost::units::list<boost::units::si::second_base_unit, boost::units::list<boost::units::si::ampere_base_unit, boost::units::list<boost::units::si::kelvin_base_unit, boost::units::list<boost::units::si::mole_base_unit, boost::units::list<boost::units::si::candela_base_unit, boost::units::list<boost::units::angle::radian_base_unit, boost::units::list<boost::units::angle::steradian_base_unit, boost::units::dimensionless_type> > > > > > > > > > > >’)
   10 |     auto oops = d + t;   // dimension mismatch: L + T
      |                 ~ ^ ~
      |                 |   |
      |                 |   quantity<unit<list<dim<boost::units::time_base_dimension,[...]>,[...]>,[...]>>
      |                 quantity<unit<list<dim<boost::units::length_base_dimension,[...]>,[...]>,[...]>>
[... 28 lines: four rejected candidates; the add_typeof_helper substitution
     failure ("no type named ‘type’ in …") restates both ~1,300-character
     quantity types twice more in full ...]
   10 |     auto oops = d + t;   // dimension mismatch: L + T
      |                     ^
```

[reproduced locally, `g++ (GCC) 15.2.0`, 2026-07-03]

Reading it, the anatomy of the representation is on full display: each operand
type spells out the entire dimension list _and_ the entire nine-element SI
base-unit list — including the kilogram as
`scaled_base_unit<cgs::gram_base_unit, scale<10, static_rational<3>>>` — twice in
the first message alone. GCC 15's caret summary (`dim<length_base_dimension,[...]>`
vs `dim<time_base_dimension,[...]>`) is the most readable part, and it is the
_compiler's_ 2020s-era elision doing the work, not the library's: on the 2007
compilers the library targeted, the user got only the wall of `list<…>`. The error
_shape_ — "no match for `operator+`" rather than a static-assert message — falls
out of the SFINAE design of `add_typeof_helper` ([Checking &
inference](#checking--inference)); the library never gets a chance to say
"cannot add length to time".

As rung-2 corroboration, the pinned clone dedicates **20 compile-fail tests** to
exactly these mismatches — [`test/fail_quantity_add.cpp`][fail-add] is verbatim
`2.0 * bu::si::seconds + 2.0 * bu::si::meters;`, alongside
`fail_quantity_construct.cpp`, `fail_add_temperature.cpp` (absolute + absolute),
`fail_heterogeneous_unit.cpp`, `fail_base_dimension.cpp` (duplicate ordinal), and
15 more `fail_*.cpp` ([`test/`][test-dir]) — the library treats "does not compile"
as a specified, regression-tested behavior, but specifies nothing about the
message.

The valid-path counterpart, against the same headers [reproduced locally,
`g++ 15.2.0`, 2026-07-03]:

```cpp
// locally reproduced — same-dimension addition; F·L → energy; pow/root
quantity<si::length> d = (2.0 * si::meters) + (0.5 * si::meters);  // OK
quantity<si::energy> w = (4.0 * si::newtons) * d;   // OK: F L evaluates to energy
quantity<si::area>   a = pow<2>(d);                 // 6.25 m^2
quantity<si::length> r = root<2>(a);                // 2.5 m
// prints: d = 2.5 m / w = 10 m^2 kg s^-2 / a = 6.25 m^2 / r = 2.5 m
```

## Ergonomics & compile-time cost

**Declaration overhead is front-loaded and system-shaped.** Using the shipped SI is
pleasant enough (`2.0 * si::meters`, `quantity<si::energy>`), but the moment a
program needs a non-SI unit it needs a base-unit struct, an ordinal, a conversion
macro, and usually a `make_system` — the full ceremony of
[Extensibility](#extensibility). [P1935R2][p1935]'s retrospective (the mp-units
proposal, grounding its design against Boost.Units) itemizes the experience: users
"have to: include a lot of specific header files, define a lot of types by
themselves …, fight with compilation errors … and debugging, define custom systems
to workaround intermediate conversions issues", and records that Boost.Units "is
claimed to require expertise in both C++ and dimensional analysis". The
header-granularity complaint is echoed for novices: "sometimes it is not obvious
why the code does not compile and which headers are missing" ([P1935R2][p1935]).

**Error readability is the historical low-water mark** quoted above: structurally
sound, domain-language-free, and quadratic in verbosity (every note restates both
full types). The 715-character mangled symbol from the codegen check tells the
same story in the debugger and the profiler.

**Compile-time cost was a defining battle of the library's own history.** The
release notes record the war story ([`doc/units.qbk`][qbk] v0.6.0, February 2007):

> "incorporated Steven Watanabe's optimized code for dimension.hpp, leading to
> _dramatic_ decreases in compilation time (nearly a factor of 10 for
> unit_example_4.cpp in my tests)."

— i.e. before optimization, a single example took ~10× longer to compile; MPL
sorted-list merging was expensive enough to need a rewrite before review. On
modern hardware the absolute numbers are tame for small TUs: locally, a trivial
four-quantity program including `<boost/units/systems/si.hpp>` + `io.hpp` compiles
in **1.63 s** versus **0.41 s** for the scalar-only equivalent
[measured locally, `g++ 15.2.0 -O2`, 2026-07-03] — a fixed ~1.2 s tax per TU that
scaled painfully on 2007 machines and still multiplies across large builds. This
compile-time reputation, together with the diagnostics, is the standard answer to
why Boost.Units — despite being correct, general, and zero-cost — never became the
C++ default; [P1935R2][p1935] adds the structural reason:

> "there is a considerable difference between the adoption of a mature 3rd party
> library and the usage of features released as a part of the C++ Standard
> Library. If it were not the case all products would use Boost.Units already. A
> motivating example here can be `std::chrono` released as a part of C++11."

## The `std::chrono` contrast

The standard library's own units success story is instructive precisely because it
attempted so much less. [`std::chrono::duration<Rep, Period>`][chrono-duration]
(C++11, Howard Hinnant's design) is a quantity type for
**one base dimension — time — only**:

- `Period` is a [`std::ratio`][std-ratio] — a compile-time `ℚ` **scale factor**
  relative to seconds, not an exponent vector. There is no dimension algebra at
  all: `duration * duration` has no meaning in the type system (no `seconds²`),
  `1 / duration` is not a frequency, and no derived dimension can ever be formed.
  The whole [free-abelian-group][fag] structure is collapsed to the one-generator
  case, where "dimension checking" degenerates to unit-conversion bookkeeping.
- What chrono _did_ keep is exactly the two hard non-algebraic ideas:
  **exact rational conversion** (implicit conversions only when lossless for
  integral `Rep` — the same "no silent truncation" stance as Boost.Units'
  explicit-by-default rule) and the **point/vector distinction** —
  [`std::chrono::time_point`][chrono-timepoint] vs `duration` is the same
  [torsor][torsor] split as `absolute<T>` vs `T`, hardened into everyday use.
- The trade paid off in adoption. [P2980R1][p2980] (the mp-units standardization
  plan) states the lesson this survey keeps re-learning: "Introducing
  `std::chrono::duration` and `std::chrono::time_point` improved the interfaces a
  lot, but time is only one of many quantities that we deal with in our software
  on a daily basis." And its design was not even reusable as a component:
  [P1935R2][p1935] notes SG6's objection to `duration`'s `common_type_t`-returning
  arithmetic and concludes "we cannot just use `std::chrono::duration` design as
  it is right now and use it for physical units implementation or even as a
  representation of only time quantity"; [P2980R1][p2980] describes the proposed
  `std::quantity` (now [P3045R8][p3045]) as "an incompatible generalization of
  `std::chrono::duration`".

The juxtaposition is the cleanest natural experiment in the catalog: Boost.Units
solved the general problem in 2008 and stayed niche; chrono solved the
one-dimensional special case in 2011 and became universal. Generality was not the
bottleneck — ergonomics, diagnostics, and standard-library distribution were.

---

## Strengths

- **Rational exponents from the very first design** — `static_rational<N, D>`
  everywhere, `root<2>` of a unit as a shipped example; the earliest system in
  this survey with `ℚ` powers, preceding [mp-units][mp-units] by 13 years.
- **Open base-dimension set with compile-time collision detection** — any tag
  type + unique ordinal is a base dimension; currency/decays/information systems
  are user-definable without forking.
- **Canonical-form-by-type-identity** — sorted, GCD-reduced, zero-elided typelists
  make dimension equality literal `is_same`, with no normalization at use sites.
- **Genuine multi-system algebra** — homogeneous and heterogeneous systems,
  symbolic scaled units (kilogram = 10³ gram), pairwise + hub conversions,
  mixed-unit types like `nmi·ft^(-1/2)`; still the most complete system-interop
  story in the survey.
- **Affine temperature via `absolute<T>`** — a real torsor API with per-unit-pair
  offsets, 15+ years before `quantity_point` reached the C++ mainstream.
- **Torque ≠ energy, dimensionally** — the nine-base-unit SI (radian, steradian
  included) makes angle a checked dimension instead of a convention.
- **Arbitrary value types** — `complex`, `quaternion`, `measurement`-with-error;
  result value types deduced via typeof helpers, so even non-closed scalar
  algebras work.
- **Zero-cost with receipts** — `sizeof` static assert on every construction, an
  in-tree performance benchmark, and (locally verified) instruction-identical
  codegen at `-O2`.

## Weaknesses

- **Diagnostics** — 9.8 KB of `list<…>` for `m + s`; no library-side rendering,
  no domain vocabulary; the message quality ceiling is whatever the compiler's
  generic elision provides. The single most cited reason it never became the
  default.
- **Compile-time cost** — MPL list merging per operation; a factor-of-10 speedup
  was needed just to pass review, and a ~4× per-TU tax survives on 2026 hardware.
- **No kind mechanism** — Bq = Hz and Sv = Gy as types; the only remedy is
  inventing base dimensions, which changes the algebra for everyone downstream.
- **No inference, verbose polymorphism** — generic code names every result type
  through `typeof_helper` traits; nothing Kennedy-shaped; pre-`auto` idioms
  (`typedef` walls, `BOOST_TYPEOF` registration for user value types) persist in
  the API surface.
- **No logarithmic quantities** — dB/neper absent entirely.
- **ABI is not scalar-identical** — user-declared copy operations make `quantity`
  non-trivially-copyable, so it passes in memory where `double` passes in
  registers; invisible after inlining, real at library boundaries.
- **Frozen in 2010** — C++03 idioms (CRTP ordinals, `BOOST_UNITS_STATIC_CONSTANT`,
  typeof emulation) were never modernized; the energy moved to
  [mp-units][mp-units] and [Au][au], leaving Boost.Units as the maintained-but-
  static baseline.

## Key design decisions and trade-offs

| Decision                                                                   | Rationale                                                                                                             | Trade-off                                                                                                                           |
| -------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Dimensions as sorted typelists of `dim<Tag, static_rational>` pairs        | Open basis + `ℚ` exponents + canonical form = type identity; the full free-abelian-group algebra in C++03             | Typelists leak verbatim into every diagnostic; MPL merge cost per operation; author-supplied ordinals needed to make types sortable |
| `static_rational<N, D>` exponents (never bare integers)                    | Fractional dimensions (`√Hz`, `ft^(1/2)`) representable; `pow`/`root` closed over units                               | Every exponent prints as `static_rational<1>` noise even in the integer-only common case                                            |
| Unit = dimension × system; homogeneous **and** heterogeneous systems       | Feet vs meters can't be confused; dimensionless-in-degrees ≠ dimensionless-in-radians; mixed units (`nmi/√ft`) work   | Two-layer type structure doubles the spelled-out types in errors; "which system am I in" is a new concept to teach                  |
| Strict construction (`1.0 * si::meter`, no `quantity(1.0)`) + `from_value` | Search-and-replace safety across systems; zero is the only literal generic code should make                           | Verbose numerics-heavy code; every boundary needs the multiply idiom or an explicit escape hatch                                    |
| Conversions explicit by default, implicit only on identical reduced units  | No silent precision loss or hidden conversion cost                                                                    | Users "define custom systems to workaround intermediate conversions issues" ([P1935R2][p1935])                                      |
| Addition gated by SFINAE absence (`add_typeof_helper` empty primary)       | Mismatches surface as overload-resolution failure — robust across 2007 compilers (Sun CC would "silently return int") | The compiler, not the library, words the error; no chance to say "length + time is meaningless"                                     |
| Angle (and solid angle) as SI base dimensions                              | Torque ≠ energy; degree/radian confusion becomes a type error                                                         | Departs from ISO SI; dimensionless-angle interop with external code needs explicit casts; Bq/Hz still unsolved                      |
| Value-type genericity via `typeof_helper` traits + Boost.Typeof            | `complex`/`quaternion`/error-propagating scalars just work, pre-C++11                                                 | Registration macros and helper specializations for every user type; a large API surface obsoleted by `decltype`                     |
| Header-only, per-unit headers (`si/length.hpp`, …)                         | Pay-for-what-you-include after the 0.5.6 "kitchen sink" split                                                         | "Not obvious … which headers are missing" ([P1935R2][p1935]); include archaeology as a user-facing task                             |

## Sources

- [boostorg/units — GitHub repository][repo] (pinned locally at
  `$REPOS/cpp/boost-units` @ `f39b667`, tagged `boost-1.91.0`)
- [`doc/units.qbk` — the QuickBook manual: introduction, dimensional-analysis model, systems, conversion rules, FAQ, release notes][qbk]
- [`include/boost/units/{dimension,dim,base_dimension,static_rational}.hpp` — the dimension engine][dimension-hpp]
- [`include/boost/units/{unit,quantity,homogeneous_system,heterogeneous_system}.hpp` — units, systems, the value type][unit-hpp]
- [`include/boost/units/{static_constant,absolute,pow,cmath,config}.hpp` — ODR constants, affine wrapper, powers, math, layout check][static-constant-hpp]
- [`include/boost/units/systems/` — SI (9 base units), CGS, angle, temperature, information systems][si-base-hpp]
- [`example/` — `test_system.hpp`, `kitchen_sink.cpp`, `radar_beam_height.cpp`, `temperature.cpp`, `performance.cpp`, and 20 more worked examples][example-dir]
- [`test/fail_*.cpp` — 20 compile-fail regression tests for dimension mismatches][test-dir]
- [Boost.Units manual (rendered)][boostdoc]
- [P1935R2 — _A C++ Approach to Physical Units_ (mp-units): Boost.Units retrospective, adoption analysis, chrono comparison][p1935] (local capture: `$PAPERS/mpusz-2020-p1935r2-physical-units-wg21.html`)
- [P2980R1 — _A motivation, scope, and plan for a quantities and units library_: chrono's lesson][p2980] · [P3045R8 — `std::quantity` as chrono's incompatible generalization][p3045]
- [`std::chrono::duration`][chrono-duration] · [`std::chrono::time_point`][chrono-timepoint] · [`std::ratio`][std-ratio] (cppreference)
- Local reproductions (mismatch error, valid ops, generic `sqr`, `root<2>` of meters, codegen diff, compile timing): scratch workspace against the pinned clone's `include/`, `g++ 15.2.0` (nixpkgs) with Boost 1.87.0 sibling headers, 2026-07-03
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [free abelian group][fag] · [torsors & affine quantities][torsor] ·
  [Kennedy's type system][kennedy] · [mp-units][mp-units] · [Au][au] ·
  [`uom`][rust-uom] · [`dimensioned`][dimensioned] · [F# units of measure][fsharp] ·
  [`uom-plugin`][uom-plugin] · [`dimensional`][dimensional] · [Pint][pint] ·
  [D `quantities`][d-quantities] · [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone (boostorg/units @ f39b667) -->

[repo]: https://github.com/boostorg/units
[qbk]: https://github.com/boostorg/units/blob/f39b667/doc/units.qbk
[quantity-hpp]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/quantity.hpp
[unit-hpp]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/unit.hpp
[dimension-hpp]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/dimension.hpp
[dim-hpp]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/dim.hpp
[base-dimension-hpp]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/base_dimension.hpp
[static-rational-hpp]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/static_rational.hpp
[static-constant-hpp]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/static_constant.hpp
[absolute-hpp]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/absolute.hpp
[heterogeneous-hpp]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/heterogeneous_system.hpp
[pow-hpp]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/pow.hpp
[cmath-hpp]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/cmath.hpp
[config-hpp]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/config.hpp
[si-base-hpp]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/systems/si/base.hpp
[torque-dim]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/physical_dimensions/torque.hpp
[activity-dim]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/physical_dimensions/activity.hpp
[frequency-dim]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/physical_dimensions/frequency.hpp
[temp-conv]: https://github.com/boostorg/units/blob/f39b667/include/boost/units/base_units/temperature/conversions.hpp
[het-ex]: https://github.com/boostorg/units/blob/f39b667/example/heterogeneous_unit.cpp
[info-dir]: https://github.com/boostorg/units/tree/f39b667/include/boost/units/systems/information
[test-system]: https://github.com/boostorg/units/blob/f39b667/example/test_system.hpp
[dimension-ex]: https://github.com/boostorg/units/blob/f39b667/example/dimension.cpp
[radar]: https://github.com/boostorg/units/blob/f39b667/example/radar_beam_height.cpp
[kitchen-sink]: https://github.com/boostorg/units/blob/f39b667/example/kitchen_sink.cpp
[temperature-ex]: https://github.com/boostorg/units/blob/f39b667/example/temperature.cpp
[performance-ex]: https://github.com/boostorg/units/blob/f39b667/example/performance.cpp
[example-dir]: https://github.com/boostorg/units/tree/f39b667/example
[fail-add]: https://github.com/boostorg/units/blob/f39b667/test/fail_quantity_add.cpp
[test-dir]: https://github.com/boostorg/units/tree/f39b667/test

<!-- Official docs & standardization papers -->

[boostdoc]: https://www.boost.org/doc/libs/release/doc/html/boost_units.html
[p1935]: https://wg21.link/p1935r2
[p2980]: https://wg21.link/p2980r1
[p3045]: https://wg21.link/p3045r8
[chrono-duration]: https://en.cppreference.com/w/cpp/chrono/duration
[chrono-timepoint]: https://en.cppreference.com/w/cpp/chrono/time_point
[std-ratio]: https://en.cppreference.com/w/cpp/numeric/ratio/ratio

<!-- Same-tree theory -->

[kennedy]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[mp-units]: ./cpp-mp-units.md
[au]: ./cpp-au.md
[rust-uom]: ./rust-uom.md
[dimensioned]: ./rust-dimensioned.md
[fsharp]: ./fsharp-uom.md
[uom-plugin]: ./haskell-uom-plugin.md
[dimensional]: ./haskell-dimensional.md
[pint]: ./python-pint.md
[d-quantities]: ./d-quantities.md
