# mp-units (C++)

The C++ standardization vehicle for quantities and units ([P3045][p3045]): a value-based C++20/23 design — concepts, NTTPs, and `consteval` symbolic algebra over empty tag types — carrying the field's most developed **kind system**, in which `quantity_spec` hierarchies distinguish _width_ from _height_ (both _length_), _torque_ from _energy_, and `Hz` from `Bq`, beyond what any dimension vector can see.

| Field            | Value                                                                                                                                                                                                             |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | C++ (C++20 minimum; C++23 `explicit this` removes the CRTP; C++20 modules and freestanding builds supported)                                                                                                      |
| License          | MIT                                                                                                                                                                                                               |
| Repository       | [mpusz/mp-units][repo]                                                                                                                                                                                            |
| Documentation    | [mpusz.github.io/mp-units][docs-site] (MkDocs; sources in-tree under [`docs/`][docs-dir])                                                                                                                         |
| Key authors      | Mateusz Pusz (original author), Johel Ernesto Guerrero Peña, Chip Hogg, "The mp-units project team" ([`CITATION.cff`][citation])                                                                                  |
| Category         | Library-level [compile-time checking][concepts] (no compiler support; WG21 standardization candidate for C++29)                                                                                                   |
| Mechanism        | Value-based symbolic expressions: `quantity<R, Rep>` where the NTTP `R` binds a `quantity_spec` (a node in a kind-hierarchy tree) to a unit; dimension/unit/spec algebra runs in `consteval` over empty tag types |
| Exponent domain  | `ℚ` — rational exponents via `power<F, Num, Den>` (`pow<1, 2>(…)`, `sqrt`, `cbrt`); base-dimension set **open** (any `base_dimension<Symbol>`)                                                                    |
| Checking time    | Compile time (concept-constrained overloads + immediate `consteval` functions); zero runtime checks                                                                                                               |
| Analyzed version | `d7b11de` (pinned clone, 2026-07-01; in-tree version `2.6.0`-dev per [`src/CMakeLists.txt`][src-cmake])                                                                                                           |
| Latest release   | `v2.5.0` (2025-12-24, [`CITATION.cff`][citation])                                                                                                                                                                 |

> [!NOTE]
> mp-units is this survey's canonical data point for **kind-aware** dimensional analysis:
> where every other system stops at the dimension group (or bolts on comparability tags,
> like [`uom`][uom]'s `Kind`), mp-units models the ISO 80000 _system of quantities_ as a
> first-class tree and computes with it. It is also the survey's C++ **standardization**
> story: P1935R2 (2020) → P2980R1 (2023) → P3045R8 (2026), all captured locally. Its C++
> siblings are the template-metaprogramming ancestor [Boost.Units][boost] and the
> deliberately-smaller [Au][au] (whose vector-space unit magnitudes mp-units adopted). See
> the [comparison capstone][comparison] for the cross-system synthesis.

---

## Overview

### What it solves

mp-units gives C++ compile-time dimensional analysis _and_ a stronger property no
dimension vector can provide: quantity-kind and quantity-hierarchy safety. The README
states the positioning in its opening paragraph ([`README.md`][readme]):

> "mp-units is a Modern C++ (C++20 and later) library providing the full spectrum of
> compile-time safety for domain-specific quantities and units, from dimensional analysis
> to quantity kind safety, built on the ISO 80000 International System of Quantities
> (ISQ). It is a candidate for C++29 standardization (P3045), your chance to shape the
> future of C++."

The kind claim is concrete and the README leads with it ([`README.md`][readme]):

> "Quantity Kind Safety — mp-units pioneered this level: it distinguishes quantities that
> share the same dimension but represent fundamentally different physical concepts:
> frequency (Hz) ≠ radioactive activity (Bq), absorbed dose (Gy) ≠ dose equivalent (Sv),
> plane angle (rad) ≠ solid angle (sr). Dimensional analysis alone cannot catch these
> errors, mp-units prevents them at compile time."

Function signatures can demand not just a dimension but a _specific quantity_:
`void calculate_trajectory(quantity<isq::kinetic_energy[J]> e);` accepts a kinetic energy
and rejects a potential energy, though both are joules ([`README.md`][readme]). The
justification is ISO 80000 itself, quoted in the user's guide
([`docs/users_guide/framework_basics/systems_of_quantities.md`][soq] L67–80):

> "Quantities of the same dimension are not necessarily of the same kind."

### Design philosophy

**Everything is a value.** Dimensions, units, and quantity specs are `inline constexpr`
objects of empty types (`detail::SymbolicConstant` requires `std::is_empty_v` —
[`symbolic_expression.h`][symexpr] L50–53); all algebra on them is done by `consteval`
functions on those objects, and the _types_ surface only in one place — diagnostics. The
convention is stated in the framework headers themselves ([`dimension.h`][dimension-h]
L136–139):

> "A common convention in this library is to assign the same name for a type and an
> object of this type. Besides defining them user never works with the dimension types in
> the source code. All operations are done on the objects. Contrarily, the dimension
> types are the only one visible in the compilation errors. Having them of the same names
> improves user experience and somehow blurs those separate domains."

**Diagnostics are a design goal, not a by-product.** The feature list in
[`docs/getting_started/about.md`][about] promises being "Optimized for readable
compilation errors and great debugging experience", and the library engineers for it: a
documented set of expression-simplification rules keeps generated types short
([`interface_introduction.md`][iface] L160–240), and truncation errors carry
`constexpr`-formatted English messages (see [Diagnostics](#diagnostics)).

**Both the quantity and the unit stay in the type.** Unlike [`uom`][uom]'s eager
normalization to base units, a `quantity<isq::height[m]>` remembers both its place in the
ISQ tree and its unit; conversions are lazy and explicit at boundaries. This is also
[Au][au]'s stance — the two libraries co-evolved, and their authors co-author [P3045][p3045].

### The WG21 trajectory

The three locally captured papers mark the arc. **P1935R2** (2020, LEWG/SG6/SG18) is the
V1-era pitch — "This document starts the discussion about the Physical Units support for
the C++ Standard Library" ([P1935R2][p1935]) — reviewed in Belfast 2019 and Prague 2020,
where (per P3045's history) the groups "expressed interest in the potential
standardization of such a library and encouraged further work" ([P3045R8][p3045]).
**P2980R1** (2023-11-28) resets after the V2 redesign with a motivation/scope/plan paper:
"Having quantities and units support in C++ would be extremely useful for many C++
developers, and ideally, we should ship it in C++29. We believe that it can be done, and
we propose a plan to get there" ([P2980R1][p2980]). **P3045R8** (2026-05-12,
LEWG/SG6/SG16/SG20) is the wording-track omnibus — "This paper describes and defines a
generic framework for quantities and units library" — authored jointly by the mp-units
developers and "the authors of other actively maintained similar libraries on the market"
([P3045R8][p3045]), i.e. the field's consensus paper rather than one library's.

---

## How it works

### One value-carrying class

The whole runtime surface is a single class template with a single data member; every
other property is a `static constexpr` value of an empty type
([`quantity.h`][quantity-h] L448–459):

```cpp
// mp-units: src/core/include/mp-units/framework/quantity.h L448-459 (abridged)
template<Reference auto R, RepresentationOf<get_quantity_spec(R)> Rep = double>
class quantity : public detail::quantity_iface {
public:
  Rep numerical_value_is_an_implementation_detail_;  ///< needs to be public for a structural type

  static constexpr Reference auto reference = R;
  static constexpr QuantitySpec auto quantity_spec = get_quantity_spec(reference);
  static constexpr Dimension auto dimension = quantity_spec.dimension;
  static constexpr Unit auto unit = get_unit(reference);
  using rep = Rep;
```

The reference `R` is built by _indexing a quantity spec with a unit_ —
`isq::speed[m / s]` — or by a bare unit whose definition already names its kind
(`42 * m` is a `quantity<si::metre{}, int>` of `kind_of<isq::length>`). A
`quantity_point<R, Origin, Rep>` wraps a `quantity` plus an origin for affine use
([`quantity_point.h`][qpoint-h] L507–519).

### Units are one-liners; magnitudes are a vector space

Units are empty strong types declaring a symbol, an optional kind, and a magnitude
expression ([`si/units.h`][si-units] L42–95):

```cpp
// mp-units: src/systems/include/mp-units/systems/si/units.h L42-95 (abridged)
inline constexpr struct second    final : named_unit<"s", kind_of<isq::duration>> {} second;
inline constexpr struct metre     final : named_unit<"m", kind_of<isq::length>> {} metre;
inline constexpr struct hertz     final : named_unit<"Hz", one / second, kind_of<isq::frequency>> {} hertz;
inline constexpr struct becquerel final : named_unit<"Bq", one / second, kind_of<isq::activity>> {} becquerel;
inline constexpr struct gray      final : named_unit<"Gy", joule / kilogram, kind_of<isq::absorbed_dose>> {} gray;
inline constexpr struct sievert   final : named_unit<"Sv", joule / kilogram, kind_of<isq::dose_equivalent>> {} sievert;
inline constexpr struct degree_Celsius final : named_unit<symbol_text{u8"℃", "`C"}, kelvin, ice_point> {} degree_Celsius;
```

Scale factors are `mag<N>`, `mag_ratio<N, D>`, `mag_power<Base, Num, Den>`, and constants
like `mag<pi_c>` — represented as a **vector space over prime-number bases with rational
exponents**, plus "custom tag" bases for irrationals ([`bits/unit_magnitude.h`][mag-bits]
L74–93: prime bases as NTTPs, `mag_constant` types with a `long double` value for "any
irrational base we admit into our representation"). This is the representation pioneered
by [Au][au]; it keeps `km/h` → `m/s` exact, lets `π` cancel symbolically, and underlies
the "faster-than-lightspeed constants" feature
([`faster_than_lightspeed_constants.md`][ftl]):

> "The mp-units library allows and encourages the implementation of physical constants as
> regular units. With that, the constant's value is handled at compile-time, and under
> favorable circumstances, it can be simplified in the same way as all other repeated
> units do."

so `speed_of_light_in_vacuum` is `named_constant<"c", mag<299'792'458> * metre / second>`
and `p / (m * c)` strikes `c` out of the type before any arithmetic happens.

### The symbolic expression engine

All three entity families — dimensions, quantity specs, units — share one engine
([`symbolic_expression.h`][symexpr]): a product is a sorted argument list, negative
exponents live in a trailing `per<...>`, and non-unit exponents wrap in
`power<F, Num, Den>`. `expr_multiply`/`expr_divide` merge sorted lists;
`expr_consolidate` aggregates equal factors by adding exponents; `expr_simplify` cancels
across numerator/denominator ([`symbolic_expression.h`][symexpr] L188–307, L417–477).
The result is a _canonical form_: `A * B` and `B * A` produce the same type, so equality
of dimensions is literally type identity ([`dimension.h`][dimension-h] L81–84 —
`operator==` returns `is_same_v<Lhs, Rhs>`). The user's guide documents each
simplification rule with before/after tables, explicitly "to keep generated types short
and readable" ([`interface_introduction.md`][iface] L178–240).

### Locally verified round trip

The survey's standard valid-path program, compiled and run against the pinned clone
[reproduced locally, `g++ (GCC) 15.2.0`, `-std=c++23`, 2026-07-03]:

```cpp
// locally reproduced — mixed-unit addition; L/T evaluates to speed
quantity l1 = 500.0 * m;
quantity l2 = 1.5 * km;
quantity sum = l1 + l2;                        // OK: common unit computed (m)
quantity<isq::speed[m / s]> v = sum / (4.0 * s);  // OK: length/time -> speed
static_assert(sum.unit == m);
// v.numerical_value_in(m / s) == 500.0  — checked at run time, exit code 0
```

Unlike [`uom`][uom], the mixed-unit sum does not silently live in a base unit: the result
unit is the _common unit_ of the operands (here `m`), computed at compile time, and the
integer-overflow implications of scaling are themselves concept-checked
([`quantity.h`][quantity-h] L152–187).

---

## Dimension representation

A base dimension is an empty type keyed by a **symbol**, not a position in a vector
([`dimension.h`][dimension-h] L143–146):

```cpp
// mp-units: src/core/include/mp-units/framework/dimension.h L143-146
MP_UNITS_EXPORT template<symbol_text Symbol>
struct base_dimension : detail::dimension_interface {
  static constexpr auto _symbol_ = Symbol;  ///< Unique base dimension identifier
};
```

Derived dimensions are the normalized symbolic products described above —
`speed` has dimension `derived_dimension<dim_length, per<dim_time>>`, `acceleration`
`derived_dimension<dim_length, per<power<dim_time, 2>>>` ([`dimension.h`][dimension-h]
L149–191, with a worked list in the doc comment). `dimension_one` is the empty product
(L200–203). Three properties are load-bearing for this survey:

- **The exponent domain is `ℚ`.** `power<F, Num, Den>` accepts any valid non-zero
  rational ([`symbolic_expression.h`][symexpr] L117–122), and the dimension interface
  exposes `pow<Num, Den>`, `sqrt`, `cbrt` directly on dimension values
  ([`dimension.h`][dimension-h] L96–110). Fractional dimensions are first-class, not an
  encoding trick — contrast the `ℤ`-only [`uom`][uom]/[`dimensioned`][dimensioned] and
  F#'s `ℚ`-during-inference ([Kennedy's type system][kennedy]).
- **The base set is open.** Any library or user can mint `base_dimension<"X">`; there is
  no 7-slot vector to outgrow. The shipped strong angular system does exactly this —
  `inline constexpr struct dim_angle final : base_dimension<symbol_text{u8"α", "a"}> {} dim_angle;`
  ([`angular/units.h`][angular] L39) — giving angle a real dimension for those who want it.
  In the [free-abelian-group model][fag], mp-units implements the group over an
  _open, named generator set_ with `ℚ` exponents, normalized by sorting on type names
  (`type_list_name_less`, [`symbolic_expression.h`][symexpr] L330–331).
- **Dimensions are computed, not declared, for derived quantities.** A
  `derived_quantity_spec` obtains its dimension by projecting each quantity spec in its
  expression to its dimension and re-normalizing (`expr_map<to_dimension, …>`,
  [`quantity_spec.h`][qspec-h] L584–585). The dimension layer is thus a _quotient_ of the
  richer quantity-spec layer — many specs, one dimension — which is precisely what makes
  room for kinds.

## Checking & inference

**The checker evaluates; it never solves.** Every operator is a concept-constrained
overload whose result type is produced by running the `consteval` algebra on the operand
values: `operator*` on quantities computes `R1 * R2` ([`quantity.h`][quantity-h]
L316–321), which multiplies the quantity specs ([`quantity_spec.h`][qspec-h] L196–210)
and the units, normalizing both. Addition and comparison require a **common reference** to
exist: `operator+` is constrained by `CommonlyInvocableQuantities`, which requires
`HaveCommonReference` — `requires { mp_units::get_common_reference(R1, R2); }`
([`quantity.h`][quantity-h] L144–167, L236–245). Everything terminates (it is ordinary
overload resolution plus template instantiation over concrete types); in the
[mechanism taxonomy][mechanisms] mp-units sits with [`uom`][uom] in the
"checker evaluates" row, opposite the [AG-unification][kennedy] of [F#][fsharp] and
[`uom-plugin`][uom-plugin].

What is genuinely novel is _which_ common type addition computes. For two quantities of
the same kind, the common quantity spec is their **lowest common ancestor in the kind
tree** ([`systems_of_quantities.md`][soq] L236–247):

```cpp
// mp-units: docs/users_guide/framework_basics/systems_of_quantities.md L244-246
static_assert(get_common_quantity_spec(isq::width, isq::height) == isq::length);
static_assert(get_common_quantity_spec(isq::thickness, isq::radius) == isq::width);
static_assert(get_common_quantity_spec(isq::distance, isq::path_length) == isq::path_length);
```

`width + height` compiles and yields a `length` — mutually comparable per ISO 80000 —
while `width + duration` has no common spec and fails. Around the tree sits a four-level
conversion lattice ([`systems_of_quantities.md`][soq] L258–347): **implicit** up the tree
(every _radius_ is a _width_ is a _length_), **explicit** down the tree
(`isq::height(q)` — not every _length_ is a _height_), **`quantity_cast`** across
branches (_height_ → _width_: same kind, different branch), and **nothing** across kinds
or dimensions (not even `quantity_cast<isq::length>(42 * s)` compiles).

**Dimensional polymorphism is expressible with zero bound-spelling.** Because result
types are computed from argument values, a generic `sqr : α → α²` is just
`auto sqr(Quantity auto q) { return q * q; }` — no per-dimension `where`-clauses (contrast
[`uom`][uom]'s seven-fold `typenum` bounds). The idiomatic constrained form uses
`QuantityOf` ([`generic_interfaces.md`][generic] L139–166):

```cpp
// mp-units: docs/users_guide/framework_basics/generic_interfaces.md L164-168 (abridged)
QuantityOf<isq::speed> auto avg_speed(QuantityOf<isq::length> auto distance,
                                      QuantityOf<isq::duration> auto duration)
{
  return distance / duration;
}
```

which is checked _semantically_: the deduced result must be implicitly convertible to
`isq::speed` in the tree, not merely dimension-`LT⁻¹`. What the model cannot do is run
backwards — there is no unification, no principal types, and no inferring an argument's
dimension from a required result ([Kennedy][kennedy]-style `sqrt : α² → α` polymorphic
_inference_ has no counterpart; `sqrt` exists but as a value-level `consteval` function on
known operands).

## Extensibility

Extension is the library's showcase — the README claims "Custom dimensions, quantities,
and units in a single line of code" ([`README.md`][readme]), and the shipped systems are
built exclusively from the public surface:

- **New unit:** one line, referencing any existing unit expression —
  `inline constexpr struct yard final : named_unit<"yd", mag_ratio<9'144, 10'000> * si::metre> {} yard;`
  ([`yard_pound.h`][yardpound] L50). Because `yard` is _defined in terms of_ `si::metre`,
  yard/metre interop needs no registration: any two units of the same kind convert through
  their magnitudes. Prefixes are unit templates —
  `template<PrefixableUnit U> struct nano_ final : prefixed_unit<"n", mag_power<10, -9>, U{}> {};`
  ([`si/prefixes.h`][prefixes] L41).
- **New quantity in a kind tree:** one `QUANTITY_SPEC` line naming the parent —
  `QUANTITY_SPEC(width, length);` — optionally with an equation and/or `is_kind`
  ([`systems_of_quantities.md`][soq] L204–224; the CRTP-hiding macro is the portable
  spelling, C++23 needs none of it).
- **New base dimension / whole system:** `base_dimension<"X">` plus a root
  `quantity_spec` — the pattern of the strong angular system ([`angular/units.h`][angular]
  L39–43) and of the natural-units system (`natural.h`, where `electronvolt` is a base
  unit and `c = 1`). The **ISQ/SI split** is architectural: `src/systems/isq` defines the
  _system of quantities_ (the tree — no units at all), `src/systems/si` the _system of
  units_ that references it; CGS, IAU, HEP, imperial/`yard_pound`, IEC, and typographic
  systems all reuse the same ISQ tree with different units, so cross-system conversion is
  just magnitude arithmetic.
- **Scoping:** definitions are ordinary C++ namespaced objects; there is no global
  registry to collide in ([`concepts`-checked at use][concepts]). Two independently
  defined base dimensions with the same symbol text would be _distinct_ types (symbol is
  identity for sorting, the type for equality) — collisions surface as failed conversions,
  not silent merges.

## Expressiveness edges

- **Fractional powers: present and exercised.** The dedicated static test builds
  `nV/√Hz`-style amplitude spectral density (`T^(1/2)` dimension), fracture toughness
  `MPa·√m` (`M L^(-1/2) T⁻²`), and a cube-root Manning coefficient — asserting, e.g.,
  `unit_symbol(si::mega<si::pascal> * sqrt(si::metre)) == "MPa m^(1/2)"` and
  `dimension_symbol(...) == "ML^-(1/2)T⁻²"`
  ([`test/static/fractional_exponent_quantity.cpp`][fracexp] L40–95). This is the survey's
  clearest demonstration that `ℚ` exponents pay off in real quantities — the exact idiom
  [`uom`][uom] cannot write at all.
- **Affine quantities: a full framework, not a temperature special-case.** `quantity` is
  the displacement vector, `quantity_point` the point; the guide enumerates the affine
  operations and their prohibitions — "It is not possible to: add two points, subtract a
  point from a vector, multiply nor divide points with anything else"
  ([`the_affine_space.md`][affine] L34–41). Origins are typed:
  `absolute_point_origin<QS>` roots a frame, `relative_point_origin<Point>` chains
  compile-time offsets, and `si::kelvin` carries `absolute_zero` while `degree_Celsius`
  is defined against `ice_point` (`relative_point_origin` at exactly
  `point<milli<kelvin>>(273'150)` — [`si/units.h`][si-units] L86–89). The multiply syntax
  is deliberately _disabled_ for temperature units (ambiguous point-vs-delta); `delta<deg_C>(3)`
  and `point<deg_C>(20)` disambiguate. Distinct absolute origins are bridged by an
  explicit `frame_projection` customization point ([`the_affine_space.md`][affine]
  L407–430). This is the survey's most complete realization of the
  [torsor model][torsor].
- **Logarithmic quantities: absent, and acknowledged.** The SI units file carries the
  honest marker ([`si/units.h`][si-units] L119–122):

  ```cpp
  // mp-units: src/systems/include/mp-units/systems/si/units.h L119-122
  // TODO the below are logarithmic units - how to support those?
  // neper
  // bel
  // decibel
  ```

  No `dB` support exists anywhere in the pinned clone — the same gap as nearly every
  system here except [Pint][pint].

- **Angles: both answers, user's choice.** In the default SI/ISQ model _angular measure_
  is a **dimensionless subkind** (`is_kind` off the _dimensionless_ tree), so `rad` and
  `sr` are distinct from each other and from bare ratios but erase to one in dimension.
  The optional strong angular system instead gives angle a genuine base dimension `α`
  with `radian = named_unit<"rad", kind_of<angle>>` ([`angular/units.h`][angular]
  L39–47). Shipping both — with the ISQ-conforming one as default — is unique in this
  survey.
- **Kind vs dimension: the system's crown jewel.** Three `T⁻¹` kinds (_frequency_,
  _activity_, _modulation rate_), `Gy` vs `Sv`, _torque_ vs _energy_ — each is a separate
  tree root or subkind, and the user's guide motivates each pair before defining the
  machinery ([`systems_of_quantities.md`][soq] L15–80). Within a kind, the hierarchy
  refines further (the _length_ tree: _width_/_altitude_/_wavelength_/…; the _energy_
  tree: _mechanical_/_potential_/_kinetic_/…). Kinds **propagate through arithmetic**
  instead of eroding: operations on `kind_of` values stay kinds
  (`kind_of<isq::length> / kind_of<isq::duration>` **is**
  `kind_of<isq::length / isq::duration>`), while mixing a kind with a strong quantity
  produces the strong quantity ([`systems_of_quantities.md`][soq] L449–462) — contrast
  [`uom`][uom], whose kinds erase to the default under every `×`/`÷`. Subkinds via
  `is_kind` (e.g. _fluid head_ vs _water head_, both _height_) inherit the parent's unit
  and dimension yet stay mutually incomparable ([`systems_of_quantities.md`][soq]
  L477–560).
- **Residual honesty:** the ISO hierarchy itself is admitted to be "to some extent,
  arbitrary" (ISO/IEC Guide 99, quoted at [`systems_of_quantities.md`][soq] L355–359),
  and the V2 tree reverses ISO's _height_/_altitude_ parentage as a documented workaround
  for signed coordinates, slated for a V3 `point_for` mechanism
  ([`systems_of_quantities.md`][soq] L110–125). Kind modeling has judgment calls in it;
  mp-units documents its own.

## Zero-cost story

The claim is structural, stated as "Zero space overhead for high-level abstractions" and
"Performance on par with (sometimes even better than) fundamental types"
([`about.md`][about], [`README.md`][readme]). The evidence in the clone:

- **One data member, everything else empty.** `quantity<R, Rep>` stores exactly
  `Rep numerical_value_is_an_implementation_detail_` ([`quantity.h`][quantity-h] L451);
  `R` is an NTTP value of an empty type (`SymbolicConstant` demands `std::is_empty_v` —
  [`symbolic_expression.h`][symexpr] L50–53). Locally verified against the pinned clone:
  `sizeof(quantity<si::metre>) == sizeof(double)` and
  `sizeof(quantity<si::kilo<si::metre>, int>) == sizeof(int)` both `static_assert` clean
  [reproduced locally, `g++ 15.2.0`, 2026-07-03].
- **The symbolic algebra cannot survive to runtime by construction** — `expr_multiply`,
  `pow`, `get_common_quantity_spec` etc. are `consteval` (immediate) functions; there is
  no code path on which dimension bookkeeping could execute at runtime.
- **Lazy conversion.** Values stay in their declared unit; scaling happens only at
  explicit boundaries (`.in(unit)`, `value_cast`, construction of a differently-referenced
  quantity), with the conversion factor folded at compile time
  ([`value_conversions.md`][valconv] L225–261). Constants-as-units go further: repeated
  constants cancel in the _type_, so the multiplication is never emitted ([`ftl`
  doc][ftl]).
- **The measured exception.** Mixed-unit comparison/addition of integer representations
  routes through a double-width integer scaling path to avoid overflow
  (`compare_quantities`, [`quantity.h`][quantity-h] L189–226) — deliberate correctness
  work a raw `int` comparison would not do, and concept guards
  (`overflows_non_zero_common_values`) reject cases that cannot be done safely at all.
- **No benchmark suite ships in the pinned clone** — `test/runtime` is functional tests
  only. The performance claims rest on the structural argument plus Compiler
  Explorer links in the docs ([`README.md`][readme] links a live godbolt example), not on
  an in-repo measured corpus. That is thinner _published_ evidence than the claim's
  prominence suggests, even if the structural case is strong.

## Diagnostics

The mandated experiment — adding metres to seconds — against the pinned clone (headers
included with `-I src/core/include -I src/systems/include`):

```cpp
// locally reproduced — mismatch.cpp
quantity<si::metre> l = 1.0 * si::metre;
quantity<si::second> t = 1.0 * si::second;
auto err = l + t;
```

```text
mismatch.cpp: In function ‘int main()’:
mismatch.cpp:9:16: error: no match for ‘operator+’ (operand types are
    ‘mp_units::quantity<mp_units::si::metre()>’ and ‘mp_units::quantity<mp_units::si::second()>’)
    9 |   auto err = l + t;
      |              ~ ^ ~
      |              |   |
      |              |   quantity<mp_units::si::second()>
      |              quantity<mp_units::si::metre()>
mismatch.cpp:9:16: note: there are 4 candidates
```

[reproduced locally, `g++ (GCC) 15.2.0`, `-std=c++23`, 2026-07-03; long compiler lines
re-wrapped, content verbatim]

The headline is the survey's best-in-class: the operand types read in the **domain's
language** — `quantity<mp_units::si::metre()>` vs `quantity<mp_units::si::second()>` —
with no exponent encodings, no eight-slot trait-object dumps, no side files (contrast the
[`uom`][uom] error quoted in that page's Diagnostics). The full output is 80 lines: GCC
then walks the four `operator+` candidates, and the binary-candidate trail ends at the
exact semantic reason (paths abbreviated, lines re-wrapped):

```text
.../framework/quantity.h:145:9: required for the satisfaction of
    ‘HaveCommonReference<Q1::reference, Q2::reference>’
    [with Q1 = mp_units::quantity<mp_units::si::metre{}, double>;
          Q2 = mp_units::quantity<mp_units::si::second{}, double>]
.../framework/quantity.h:145:72: note: the required expression
    ‘mp_units::get_common_reference(R1, R2)’ is invalid
```

The kind-safety failure gives the same quality of headline
[reproduced locally, `g++ 15.2.0`, 2026-07-03]:

```text
kinds.cpp:8:19: error: no match for ‘operator+’ (operand types are
    ‘mp_units::quantity<mp_units::si::hertz(), int>’ and ‘mp_units::quantity<mp_units::si::becquerel(), int>’)
    8 |   auto q = 1 * Hz + 1 * Bq;  // same dimension T^-1, different kinds
```

Three engineered mechanisms produce this quality. First, the _same-name type/object
convention_ quoted above means the type in the error **is** the name the user wrote.
Second, the expression-template simplification rules exist explicitly "to keep generated
types short and readable" ([`interface_introduction.md`][iface] L178) — a derived unit
prints as `derived_unit<si::metre, per<si::second>>`, not a nest of aliases. Third, for
constraint failures with a _reason_ (truncation, overflow), concepts embed
`constexpr`-formatted English via `unsatisfied<"…">` — e.g.
`unsatisfied<"Conversion from '{}' as '{}' to '{}' as '{}' is truncating">(unit_symbol(FromUnit), …)`
([`quantity.h`][quantity-h] L98–102); under compilers with `constexpr` exceptions
(`__cpp_constexpr_exceptions`, auto-enabled — [`bits/hacks.h`][hacks] L159–161) the
message is _thrown_ inside the `consteval` evaluation ([`bits/unsatisfied.h`][unsat]
L63–67), so the compiler prints the formatted sentence as part of the error. This is the
most deliberate diagnostics engineering in the survey.

## Ergonomics & compile-time cost

**Declaration overhead is minimal at every tier.** Using the library is
`#include <mp-units/systems/si.h>` plus `using namespace si::unit_symbols;`; a new unit,
quantity, prefix, or base dimension is one line each (grounded above). The library
deliberately offers **two commitment levels** — simple (`quantity<km / h>`, unit-only,
kind-checked) and typed (`quantity<isq::speed[km / h]>`, tree-checked) — so ISQ rigor is
opt-in per interface ([`simple_and_typed_quantities.md`][simple]). UDLs are rejected by
design with documented reasons (literals-only, widest-type defaults, namespace pollution —
[`faq.md`][faq] L10–35); the multiply syntax `42 * m` works for variables and any
representation type.

**Error readability** is quoted above; the one caveat is volume — the readable two-line
headline is followed by ~78 lines of candidate/constraint notes, and GCC suggests
`-fconcepts-diagnostics-depth=2` for the deeper "why" of a constraint failure.

**Compile-time cost is real but moderate, and modules are the sanctioned fix.** Locally,
compiling a single TU that includes `<mp-units/systems/si.h>` + `<mp-units/systems/isq.h>`
takes **3.6 s wall** (`g++ 15.2.0 -std=c++23 -c`, header mode, 2026-07-03) — each TU pays
it in header mode. The project ships C++20 modules (`import mp_units;`, clang 17+ per the
[compiler-support matrix][compiler-support]) precisely to amortize this, and documents
per-feature macro switches (`MP_UNITS_API_NO_CRTP`, `MP_UNITS_API_THROWING_CONSTRAINTS`)
that trade portability against interface quality ([`bits/hacks.h`][hacks] L150–163).
Freestanding builds (`MP_UNITS_HOSTED=0`) strip the text/formatting layer for embedded
use.

---

## Strengths

- **The kind system** — quantity hierarchies with LCA-based addition, four-level
  conversion lattice, `kind_of` propagation, and `is_kind` subkinds; catches `Hz`/`Bq`,
  `Gy`/`Sv`, _torque_/_energy_, _width_/_height_ misuse that every dimension-vector
  system in this survey admits.
- **`ℚ` exponents over an open generator set** — `nV/√Hz` and `MPa·√m` are first-class,
  test-covered quantities; new base dimensions are one-liners.
- **Best-in-survey diagnostics** — domain-language types in errors by deliberate
  engineering (same-name convention, simplification rules, `unsatisfied` formatted
  messages).
- **Full affine-space model** — typed origins, absolute/relative/frame-projected,
  temperature done via origins rather than special cases; the most complete
  [torsor][torsor] realization surveyed.
- **Vector-space unit magnitudes** — exact rational/irrational scale factors, symbolic
  `π`, constants-as-units that cancel in the type.
- **Structurally zero-cost** — one `Rep` member, empty NTTP tags, `consteval` algebra;
  locally verified size identities.
- **Standardization gravity** — P3045 is co-authored across competing libraries; the
  design documented here is the likely shape of `std` quantities in C++29.

## Weaknesses

- **C++20/23 floor with real compiler sensitivity** — CRTP fallbacks, clang-version
  workarounds, and MSVC ICE shims lace the headers ([`unit_magnitude.h`][mag-fw]
  L76–91); older toolchains get a degraded interface (no `explicit this`, no throwing
  constraints, no modules).
- **No logarithmic quantities** — `dB`/`Np` are an open `TODO` in the SI system itself.
- **Kind hierarchies embed contestable judgments** — ISO's own "to some extent,
  arbitrary" caveat applies; the V2 _height_/_altitude_ inversion shows the tree can
  disagree with the standard it models, and downstream code inherits those calls.
- **No inference** — the checker evaluates only; nothing like [Kennedy][kennedy]
  principal types or [`uom-plugin`][uom-plugin] unification; generic code is
  concept-constrained forward-only.
- **Compile-time weight in header mode** — seconds per TU; modules help but narrow the
  supported-compiler set further.
- **Performance claims outrun in-repo evidence** — no benchmark suite in the pinned
  clone; the zero-cost case is structural plus external godbolt links.
- **Sheer conceptual surface** — quantity spec vs kind vs dimension vs unit vs reference
  vs point origin is a five-layer ontology; the docs are excellent but long, and P3045's
  own teachability chapter segments its audiences for a reason.

## Key design decisions and trade-offs

| Decision                                                                  | Rationale                                                                                                         | Trade-off                                                                                                       |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Value-based API: entities are `constexpr` objects, algebra is `consteval` | Natural syntax (`m / s`, `pow<2>(m)`); types appear only in diagnostics; same-name convention makes them readable | Requires C++20 NTTP/concepts machinery; heavy header instantiation cost per TU                                  |
| Kind tree (`quantity_spec` hierarchy) above the dimension group           | Catches same-dimension misuse (`Hz`/`Bq`, _torque_/_energy_); LCA gives meaningful `width + height`               | Tree contents are judgment calls (ISO: "to some extent, arbitrary"); five-layer ontology to learn               |
| Symbolic expressions with `ℚ` exponents, canonicalized by sorting         | `√Hz`-class quantities expressible; type identity = structural equality with no fixed base-vector arity           | Type names grow with expression complexity; canonical order is by type name, not physics convention             |
| Unit kept in the type; lazy, explicit conversions                         | No boundary precision loss; integer reps stay exact; conversion cost visible in code                              | Mixed-unit integer comparisons need double-width scaling; common-unit computation adds concept complexity       |
| Vector-space magnitudes (prime + irrational bases, `ℚ` exponents)         | Exact `km/h`→`m/s`; symbolic `π`; constants-as-units cancel before arithmetic                                     | Magnitude machinery is intricate (MSVC ICE workarounds); `long double` constant values cap irrational precision |
| Diagnostics engineered as a feature (`unsatisfied`, simplification rules) | Survey-best error headlines in the domain's vocabulary                                                            | Full errors still ~80 lines of candidate notes; best messages gated on `constexpr`-exceptions compilers         |
| ISQ/SI split: systems of quantities separate from systems of units        | One quantity tree serves SI/CGS/IAU/HEP/imperial; cross-system conversion is pure magnitude arithmetic            | Users must grasp the quantity/unit distinction before their first typed interface                               |
| WG21 standardization as the explicit end-state                            | API stability pressure, multi-library consensus (P3045 co-authors), field-wide review                             | Design conservatism (portability macros, CRTP fallbacks) and paper-driven feature pacing                        |

## Sources

- [mpusz/mp-units — GitHub repository][repo] (pinned locally at `$REPOS/cpp/mp-units` @
  `d7b11de`, 2026-07-01)
- [`framework/quantity.h` — `quantity` class, operator constraints, `unsatisfied` truncation messages, double-width comparison][quantity-h]
- [`framework/dimension.h` — `base_dimension`, `derived_dimension`, `pow<Num, Den>`/`sqrt`/`cbrt`, type-identity equality, same-name convention note][dimension-h]
- [`framework/symbolic_expression.h` — `per`/`power<F, Num, Den>`, consolidation, simplification, `expr_multiply`/`expr_pow`/`expr_map`][symexpr]
- [`framework/quantity_spec.h` — `quantity_spec` specializations, kind interface, `kind_of`, dimension projection][qspec-h]
- [`framework/quantity_point.h` — `quantity_point`, `absolute_point_origin`/`relative_point_origin`][qpoint-h]
- [`bits/unit_magnitude.h` — vector-space magnitudes over prime/irrational bases][mag-bits] · [`framework/unit_magnitude.h` — `mag`/`mag_ratio`/`mag_power`/`pi_c`][mag-fw]
- [`bits/unsatisfied.h` — consteval-throw diagnostic messages][unsat] · [`bits/hacks.h` — feature gates (`NO_CRTP`, `THROWING_CONSTRAINTS`)][hacks]
- [`systems/si/units.h` — SI unit definitions, Celsius origins, logarithmic-units TODO][si-units] · [`systems/si/prefixes.h`][prefixes] · [`systems/angular/units.h` — strong angle base dimension][angular] · [`systems/yard_pound.h`][yardpound]
- [`test/static/fractional_exponent_quantity.cpp` — `√Hz`, `MPa·√m`, cube-root quantities][fracexp]
- [Docs: systems of quantities (kind trees, conversion lattice, `is_kind`)][soq] · [the affine space][affine] · [interface introduction (simplification rules)][iface] · [generic interfaces][generic] · [faster-than-lightspeed constants][ftl] · [value conversions][valconv] · [simple vs typed quantities][simple] · [about (feature claims)][about] · [FAQ (no UDLs)][faq] · [compiler support][compiler-support]
- [`README.md` — positioning, kind-safety pitch, key features][readme] · [`CITATION.cff` — authors, release][citation] · [`src/CMakeLists.txt` — in-tree version][src-cmake]
- WG21 captures (local: `$PAPERS/mpusz-{2020-p1935r2,2023-p2980r1,2026-p3045r8}-*.html`): [P1935R2 — "A C++ Approach to Physical Units"][p1935] · [P2980R1 — motivation/scope/plan, C++29 target][p2980] · [P3045R8 — "Quantities and units library"][p3045]
- Local reproductions (mismatch + kind errors, valid ops, `sizeof` asserts, compile
  timing): scratch workspace against the pinned clone, `g++ (GCC) 15.2.0`, `-std=c++23`,
  2026-07-03
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [Kennedy's type system][kennedy] · [free abelian group][fag] ·
  [torsors & affine quantities][torsor] · [`uom`][uom] · [`dimensioned`][dimensioned] ·
  [F# units of measure][fsharp] · [`uom-plugin`][uom-plugin] · [Boost.Units][boost] ·
  [Au][au] · [Pint][pint] · [`Unitful.jl`][unitful] · [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone (mp-units @ d7b11de) -->

[repo]: https://github.com/mpusz/mp-units
[quantity-h]: https://github.com/mpusz/mp-units/blob/d7b11de/src/core/include/mp-units/framework/quantity.h
[dimension-h]: https://github.com/mpusz/mp-units/blob/d7b11de/src/core/include/mp-units/framework/dimension.h
[symexpr]: https://github.com/mpusz/mp-units/blob/d7b11de/src/core/include/mp-units/framework/symbolic_expression.h
[qspec-h]: https://github.com/mpusz/mp-units/blob/d7b11de/src/core/include/mp-units/framework/quantity_spec.h
[qpoint-h]: https://github.com/mpusz/mp-units/blob/d7b11de/src/core/include/mp-units/framework/quantity_point.h
[mag-bits]: https://github.com/mpusz/mp-units/blob/d7b11de/src/core/include/mp-units/bits/unit_magnitude.h
[mag-fw]: https://github.com/mpusz/mp-units/blob/d7b11de/src/core/include/mp-units/framework/unit_magnitude.h
[unsat]: https://github.com/mpusz/mp-units/blob/d7b11de/src/core/include/mp-units/bits/unsatisfied.h
[hacks]: https://github.com/mpusz/mp-units/blob/d7b11de/src/core/include/mp-units/bits/hacks.h
[si-units]: https://github.com/mpusz/mp-units/blob/d7b11de/src/systems/include/mp-units/systems/si/units.h
[prefixes]: https://github.com/mpusz/mp-units/blob/d7b11de/src/systems/include/mp-units/systems/si/prefixes.h
[angular]: https://github.com/mpusz/mp-units/blob/d7b11de/src/systems/include/mp-units/systems/angular/units.h
[yardpound]: https://github.com/mpusz/mp-units/blob/d7b11de/src/systems/include/mp-units/systems/yard_pound.h
[fracexp]: https://github.com/mpusz/mp-units/blob/d7b11de/test/static/fractional_exponent_quantity.cpp
[readme]: https://github.com/mpusz/mp-units/blob/d7b11de/README.md
[citation]: https://github.com/mpusz/mp-units/blob/d7b11de/CITATION.cff
[src-cmake]: https://github.com/mpusz/mp-units/blob/d7b11de/src/CMakeLists.txt
[docs-dir]: https://github.com/mpusz/mp-units/tree/d7b11de/docs

<!-- Pinned in-tree docs -->

[soq]: https://github.com/mpusz/mp-units/blob/d7b11de/docs/users_guide/framework_basics/systems_of_quantities.md
[affine]: https://github.com/mpusz/mp-units/blob/d7b11de/docs/users_guide/framework_basics/the_affine_space.md
[iface]: https://github.com/mpusz/mp-units/blob/d7b11de/docs/users_guide/framework_basics/interface_introduction.md
[generic]: https://github.com/mpusz/mp-units/blob/d7b11de/docs/users_guide/framework_basics/generic_interfaces.md
[ftl]: https://github.com/mpusz/mp-units/blob/d7b11de/docs/users_guide/framework_basics/faster_than_lightspeed_constants.md
[valconv]: https://github.com/mpusz/mp-units/blob/d7b11de/docs/users_guide/framework_basics/value_conversions.md
[simple]: https://github.com/mpusz/mp-units/blob/d7b11de/docs/users_guide/framework_basics/simple_and_typed_quantities.md
[about]: https://github.com/mpusz/mp-units/blob/d7b11de/docs/getting_started/about.md
[faq]: https://github.com/mpusz/mp-units/blob/d7b11de/docs/getting_started/faq.md
[compiler-support]: https://github.com/mpusz/mp-units/blob/d7b11de/docs/getting_started/cpp_compiler_support.md

<!-- Official docs & WG21 -->

[docs-site]: https://mpusz.github.io/mp-units/
[p1935]: https://wg21.link/p1935r2
[p2980]: https://wg21.link/p2980r1
[p3045]: https://wg21.link/p3045r8

<!-- Same-tree theory -->

[kennedy]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[uom]: ./rust-uom.md
[dimensioned]: ./rust-dimensioned.md
[fsharp]: ./fsharp-uom.md
[uom-plugin]: ./haskell-uom-plugin.md
[boost]: ./cpp-boost-units.md
[au]: ./cpp-au.md
[pint]: ./python-pint.md
[unitful]: ./julia-unitful.md
