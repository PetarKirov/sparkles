# Au (C++)

Aurora's pragmatic, embedded-first C++ units library: header-only C++14, quantity makers (`meters(3.0)`) instead of UDLs, a vector-space `Magnitude` type whose basis vectors are prime numbers and `π`, and a conversion policy that turns silent truncation and overflow into compile errors — all delivered with unusually rich design-rationale documentation.

| Field            | Value                                                                                                                                                                                |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language         | C++ (any standard from **C++14** up; header-only; CUDA/HIP-compatible)                                                                                                               |
| License          | Apache-2.0                                                                                                                                                                           |
| Repository       | [aurora-opensource/au][repo]                                                                                                                                                         |
| Documentation    | [aurora-opensource.github.io/au][docs] (MkDocs, built from `docs/` in-tree)                                                                                                          |
| Key authors      | Chip Hogg (`chiphogg`) and Aurora Operations contributors                                                                                                                            |
| Category         | Library-level [compile-time checking][concepts] (no compiler support; pure template metaprogramming)                                                                                 |
| Mechanism        | Strong unit types carrying `Dim` + `Mag` member typedefs; canonicalized variadic packs `Dimension<BPs...>` / `Magnitude<BPs...>`; `Quantity<Unit, Rep>` with maker-only construction |
| Exponent domain  | `ℚ` — `std::ratio` exponents via `Pow<B, N>` / `RatioPow<B, N, D>`, over an **open** basis (9 shipped base dimensions incl. `Angle` and `Information`; user-extensible)              |
| Checking time    | Compile time; **opt-in runtime value checks** (`will_conversion_truncate`, overflow checkers) complement the static policy                                                           |
| Analyzed version | `50b97bf` (pinned clone, 2026-07-01; post-`0.5.0` development)                                                                                                                       |
| Latest release   | `0.5.0` (per the pinned clone's `CMakeLists.txt` `VERSION` and `docs/howto/upgrade.md`; the local clone carries no tags)                                                             |

> [!NOTE]
> Au is this survey's data point for the **pragmatic pole** of C++ dimensional
> analysis: where [mp-units][mp-units] spends C++20 concepts and NTTPs on maximal
> expressiveness (kinds, quantity hierarchies, systems), Au deliberately holds a
> **C++14 floor** for embedded reach and spends its novelty budget on _safety
> mechanics_ — magnitude arithmetic, conversion-risk policy, and diagnosable errors.
> Its dimension machinery is the same template-normal-form mechanism family as
> [Boost.Units][boost] and the `typenum` encodings of [`uom`][rust-uom] /
> [`dimensioned`][dimensioned] (see the [mechanism taxonomy][mechanisms]), but its
> exponents are rational and its basis is open. See the [comparison
> capstone][comparison] for the cross-system synthesis.

---

## Overview

### What it solves

Au ("ay yoo", the chemical symbol of gold) generalizes the one units success story
every C++ programmer already ships — `std::chrono` — from time to all physical
quantities. The `README.md` states it in exactly those terms ([`README.md`][readme]):

> "What the `<chrono>` library did for time variables, _Au_ does for _all physical
> quantities_ (lengths, speeds, voltages, and so on). Namely: Catch unit errors at
> compile time, with **no runtime penalty**. Make unit conversions effortless to get
> right."

The library's organizing concept is **unit safety**, defined precisely in the first
tutorial ([`docs/tutorial/101-quantity-makers.md`][tutorial]):

> "**Unit safety**: We call a program _unit-safe_ when the _unit-correctness_ of
> _each line_ of code can be checked by _inspection_, in _isolation_."

That definition drives Au's most distinctive API decision: `Quantity`'s
numeric constructor is **private** — stricter than the `explicit` constructors of
every other library in this survey. The only way in is a **quantity maker**,
`meters(3.0)`, and the only way out is naming the unit again, `q.in(meters)`.
The troubleshooting guide explains why `explicit` is not enough
([`docs/troubleshooting.md`][troubleshooting]):

> "A core principle of the Au library is that the only way to enter or exit the
> library boundaries is to name the unit of measure, explicitly, at the callsite"

— because a user-made alias like `using Length = QuantityD<Meters>;` would otherwise
let `Length MAX_LENGTH{5.5};` compile with the unit invisible at the callsite.

### Design philosophy

Three commitments define Au against its C++ siblings.

**The C++14 floor is a product decision, not a legacy accident.** The `README.md`
positions Au by conjunction: many libraries offer _some_ of "wide compatibility with
C++ versions (anything C++14 or newer); easy installation in any project (including a
customizable single-header option); small compile time burden; concise, readable
typenames in compiler errors" — "**only Au** offers _all_ of them" ([`README.md`][readme]).
The embedded audience is named as the driver: "Aurora's embedded teams have been first
class customers since the library's inception", and the compiler-support policy is
standards-based rather than list-based ([`docs/supported-compilers.md`][compilers]):

> "We've endeavored to use only standards-compliant C++14 in Au, with the goal of
> making it work with any compiler that fully supports the C++14 standard (or any
> newer one)."

**Exact symbolic arithmetic for conversion factors.** The `Magnitude` header states
the goal in its opening comment ([`au/magnitude.hh`][magnitude-hh] L34–37):

> "'Magnitude' is a collection of templated types, representing positive real numbers.
> The key design goal is to support products and rational powers _exactly_, including
> for many irrational numbers, such as Pi, or sqrt(2)."

This is the vector-space representation examined in
[Dimension representation](#dimension-representation) below — Au's genuinely novel
contribution, since [shared with mp-units][alternatives] ("Formerly, Au alone was
best, but we shared Magnitudes with mp-units").

**No macros, no UDLs, one namespace.** New units are defined by "just writing regular
C++ code" — the how-to guide's footnote is a small manifesto
([`docs/howto/new-units.md`][new-units]):

> "Macros have long been considered contrary to C++ best practices. … They mostly
> exist to save typing. But code is read far more often than written, and macros
> actually make the definitions _harder_ to read and understand (because they use
> _positional_ arguments, so the meaning of the parameters is unclear at the
> callsite)."

Quantity makers replace user-defined literals for the same composability reason: a
maker is an ordinary `constexpr` object, so `(miles / hour)(65.0)`,
`kilo(meters)(2.5)`, and `pow<2>(meters)` all work by plain operator overloading —
UDLs compose with none of those ([`docs/discussion/idioms/unit-slots.md`][unit-slots]).

---

## How it works

### A unit is a type with `Dim` and `Mag`

The whole library rests on a two-typedef duck type
([`au/unit_of_measure.hh`][unit-hh] L27–44):

```cpp
// au: au/unit_of_measure.hh L27-44 (comment abridged)
// A "unit" is any type which has:
// - a member typedef `Dim`, which is a valid Dimension; and,
// - a member typedef `Mag`, which is a valid Magnitude.

// A UnitImpl is one easy way (although not the only way) to make a "Unit".
template <typename D, typename M = Magnitude<>>
struct UnitImpl {
    using Dim = D;
    using Mag = M;
};
```

The same comment block records a deliberate abstraction boundary: end users are
discouraged from ever asking "which dimension" or "what magnitude" a unit has — only
whether two units share a dimension, and what their _ratio_ is. Dimensions are "an
implementation detail" ([`docs/howto/new-dimensions.md`][new-dimensions]), which is
why they "rarely appear in compiler errors".

### Defining a unit: inherit from a unit expression

A named unit is a strong type inheriting from the `decltype` of arithmetic on existing
units ([`docs/howto/new-units.md`][new-units]; reproduced locally against the pinned
clone, gcc 15.2.0, 2026-07-03):

```cpp
// locally reproduced — the docs/howto/new-units.md C++14 pattern
struct Fathoms : decltype(au::Inches{} * au::mag<72>()) {
    static constexpr const char label[] = "ftm";
};
constexpr const char Fathoms::label[];                    // C++14 needs the definition
constexpr auto fathoms = au::QuantityMaker<Fathoms>{};
```

Five optional pieces (label, singular name for grammatical `miles / hour`, quantity
maker, point maker, unit symbol) are each independent; omitting the label merely
prints `[UNLABELED UNIT]` ([`au/unit_of_measure.hh`][unit-hh] L62–70). The guide's
best-practice rule: **strong types for named units** (they "show up in compiler
errors, making them easier to read"), **aliases for compound units**
(`using MilesPerHour = decltype(au::Miles{} / au::Hours{});`) because aliases preserve
exact cancellation ([`docs/howto/new-units.md`][new-units] §"Aliases vs. strong types").

### Arithmetic: common units, lazy conversion

Unlike [`uom`][rust-uom]'s eager normalization to base units, Au keeps every quantity
in the unit it was made in, and converts _lazily_ at operations. Same-dimension
addition lands on the `CommonUnit` — "the largest unit that evenly divides all input
units" ([`au/unit_of_measure.hh`][unit-hh] L163–180, [`au/quantity.hh`][quantity-hh]
L992–997):

```cpp
// au: au/quantity.hh L992-997
template <typename U1, typename U2, typename R1, typename R2>
AU_DEVICE_FUNC constexpr auto operator+(const Quantity<U1, R1> &q1, const Quantity<U2, R2> &q2) {
    using U = CommonUnit<U1, U2>;
    return make_quantity<U>(detail::ref_or_scaled_copy<R2>(U{}, q1) +
                            detail::ref_or_scaled_copy<R1>(U{}, q2));
}
```

Multiplication builds `UnitProduct<Unit, OtherUnit>` — the units' identities are
retained rather than reduced to base units, so labels compose (`mi / h`) and errors
mention familiar names ([`au/quantity.hh`][quantity-hh] L361–374,
[`docs/discussion/implementation/vector_space.md`][vector-space] §"Units"). The
valid-path behaviour, reproduced locally [gcc 15.2.0, `-std=c++14`, 2026-07-03]:

```cpp
// locally reproduced — mixed-unit addition, compound makers, conversions
std::cout << fathoms(1) + inches(3);      // prints "75 in"   (common unit: inches)
std::cout << (miles / hour)(65.0);        // prints "65 mi / h"
std::cout << feet(6).as(inches);          // prints "72 in"   (int, exact: allowed)
std::cout << inches(24).as<int>(feet);    // prints "2 ft"    (explicit rep: forced)
```

### The conversion-risk policy: explicit rep as consent to truncate

Every conversion API takes an optional **risk policy**. The defaults encode the
library's safety stance ([`au/quantity.hh`][quantity-hh] L198–235):

- `q.as(unit)` / `q.in(unit)` — default policy `check_for(ALL_RISKS)`: conversions
  with material overflow **or** truncation risk are compile errors.
- `q.as<NewRep>(unit)` / `q.in<NewRep>(unit)` — default policy `ignore(ALL_RISKS)`:
  naming the rep at the callsite is treated as `static_cast`-like consent
  ([`docs/reference/quantity.md`][quantity-ref]: "The conversion is considered
  'forcing', and will be permitted in spite of any overflow or truncation risk. The
  semantics are similar to `static_cast<T>`.").
- Granular overrides: `q.as(unit, ignore(TRUNCATION_RISK))`,
  `check_for(OVERFLOW_RISK)`, and combinations via `|`
  ([`au/conversion_policy.hh`][conversion-policy-hh] L40–100).

So `inches(24).as(feet)` refuses to compile even though 24 happens to be divisible by
12 — the _conversion_, not the value, carries the risk — while
`inches(24).as<int>(feet)` compiles. (The reference docs flag that issue
[#122][issue-122] plans to make even the explicit-rep form checked from `0.6.0`,
with policy arguments as the blessed forcing syntax.)

The **overflow** side is Au's "adaptive safety surface": a conversion is admitted only
if values up to a threshold survive it, with the threshold chosen against the rep's
range ([`au/conversion_policy.hh`][conversion-policy-hh] L118–119):

```cpp
// au: au/conversion_policy.hh L118-119
// Chosen so as to allow populating a `QuantityI32<Hertz>` with an input in MHz.
constexpr auto OVERFLOW_THRESHOLD = mag<2'147>();
```

— so `giga(hertz)(1).as(hertz)` on `int` is a compile error (would overflow), while
`mega(hertz)(x).as(hertz)` on `int32_t` is allowed (safe up to 2 147 MHz ≈
`INT32_MAX` Hz). The static policy is complemented by **runtime checkers** on values:
`will_conversion_truncate(q, u)` / overflow analogues
([`docs/discussion/concepts/truncation.md`][truncation-doc]) — the documented idiom is
to check the value at runtime, then convert with `ignore(TRUNCATION_RISK)`.

---

## Dimension representation

### Variadic packs of base powers, `ℚ` exponents

A dimension is a canonicalized variadic pack of base-dimension powers
([`au/dimension.hh`][dimension-hh] L23–36):

```cpp
// au: au/dimension.hh L23-36 (comments elided)
template <typename... BPs>
struct Dimension {
    static_assert(AreAllPowersNonzero<Dimension, Dimension<BPs...>>::value,
                  "All powers must be nonzero");
    static_assert(AreBasesInOrder<Dimension, Dimension<BPs...>>::value,
                  "Bases must be listed in ascending order");
    static_assert(IsValidPack<Dimension, Dimension<BPs...>>::value, "Ill-formed Dimension");
};
```

Exponents are `std::ratio`s attached by wrapper types — `Pow<B, N>` for integer
powers, `RatioPow<B, N, D>` for rational ones ([`au/packs.hh`][packs-hh] L34–40) — so
the exponent domain is genuinely `ℚ`, not `ℤ`: `DimPower<T, ExpNum, ExpDen>` and
`root<N>(dim)` are first-class ([`au/dimension.hh`][dimension-hh] L43–76). The
`static_assert`s enforce the [free-abelian-group][fag] normal form _in the type
itself_: zero powers deleted, bases sorted by a strict total ordering, so two equal
dimensions are literally the same C++ type and checking is type identity. The engine
is `au/packs.hh` (691 lines): `InOrderFor`, `LexicographicTotalOrdering`, sorted-merge
products — shared by dimensions, magnitudes, and unit products alike ("Products of
base powers are the foundation of au", [`au/packs.hh`][packs-hh] L26–30).

The design-rationale doc derives this from first principles, rejecting the
positional-vector encoding used by [Boost.Units][boost] and [`uom`][rust-uom]
([`docs/discussion/implementation/vector_space.md`][vector-space]):

> "Compiler errors are inscrutable. (What exactly does
> `Dimension<std::ratio<1, 1>, std::ratio<-1, 1>>` represent?) … If we need to add a
> new basis vector, it will affect an immense number of callsites. … Some applications
> need infinitely many basis vectors! This approach is a complete non-starter."

With variadic packs, "when we see something like
`Dimension<base_dim::Length, Pow<base_dim::Time, -1>>`, we can recognize it as
'Speed'", and the basis is **open**: nine base dimensions ship — the seven SI ones
**plus `Angle` and `Information`** — each a struct with a unique ordering index
([`au/dimension.hh`][dimension-hh] L105–113), and users add more without touching any
existing code (see [Extensibility](#extensibility)).

### Magnitudes: primes and `π` as basis vectors

The same pack machinery is instantiated a second time for the **magnitude** — the
positive-real scale factor between a unit and its dimension's implicit reference. This
is Au's flagship idea. The basis vectors of this second vector space are **prime
numbers** and **`π`** ([`au/magnitude.hh`][magnitude-hh] L146–165):

```cpp
// au: au/magnitude.hh L146-165 (abridged)
template <std::uintmax_t N>
struct Prime {
    static_assert(detail::is_prime(N), "Prime<N> requires that N is prime");
    static AU_DEVICE_FUNC constexpr std::uintmax_t value() { return N; }
};

struct Pi {
    static AU_DEVICE_FUNC constexpr long double value() {
        return 3.14159265358979323846264338327950288419716939L;
    }
};
```

The rationale doc explains why this basis is exactly right
([`docs/discussion/implementation/vector_space.md`][vector-space] §"Magnitude"):
unique factorization makes prime exponent vectors a faithful encoding of the positive
rationals — "unlike a `(num, denom)` representation, we're always automatically in
lowest terms: any common factors cancel out automatically" — and the representation
_surpasses_ `std::ratio` in three documented ways:

- **No overflow for huge factors:** `yotta` (`10²⁴`) "doesn't even fit in
  `std::intmax_t`, but `pow<24>(mag<10>())` handles it with ease" — it is just
  `Magnitude<Pow<Prime<2>, 24>, Pow<Prime<5>, 24>>`.
- **Exact radicals:** `root<2>(mag<2>())` is `Magnitude<RatioPow<Prime<2>, 1, 2>>` —
  "something unthinkable for `std::ratio`".
- **Exact irrationals:** precisely _because_ no product of rational prime powers
  equals `π`, "π is **independent**, and we can add it as a new basis vector". The
  degrees-to-radians factor `Magnitude<Pi>{} / mag<180>()` expands to
  `Magnitude<Pow<Prime<2>, -2>, Pow<Prime<3>, -2>, Pi, Pow<Prime<5>, -1>>`.

`mag<N>()` computes the prime factorization at compile time
(`PrimeFactorizationImpl`, [`au/magnitude.hh`][magnitude-hh] L668–692); a `Negative`
marker base extends the group to signed magnitudes with correct root semantics
("Cannot take even root of negative magnitude",
[`au/magnitude.hh`][magnitude-hh] L81–110) — the basis of Au's unusual
**negative units** support. When a numeric value is finally needed,
`get_value<T>(Magnitude)` evaluates each base power with overflow-checked integer
exponentiation and a binary-search integer root, entirely in `constexpr`
([`au/magnitude.hh`][magnitude-hh] L785–997) — conversion factors are compile-time
constants, never runtime computation.

Two magnitude-level operations deserve note because most libraries cannot express
them: `CommonMagnitude` (the largest magnitude evenly dividing both — the engine
behind `CommonUnit`) and `MagSum`, defined only when the result provably fits in
`uint64_t` ([`au/magnitude.hh`][magnitude-hh] L277–301).

## Checking & inference

Checking is **template normal-form evaluation** — the "checker evaluates, never
solves" family in this survey's [mechanism taxonomy][mechanisms], shared with
[Boost.Units][boost] and [`uom`][rust-uom], and opposite to the
[AG-unification][kennedy] of [F#][fsharp] and [`uom-plugin`][uom-plugin]:

- Same-dimension operations demand a computable `CommonUnit`, whose specialization
  hard-errors (`static_assert`) when dimensions differ
  ([`au/unit_of_measure.hh`][unit-hh] L130–134, L163–180).
- Product/quotient/power types are computed by the pack algebra
  (sorted-merge on exponent vectors), and canonicalization means equality is type
  identity — no reduction step at comparison time.
- Everything is decidable and terminating: sorting and merging of finite packs, with
  compile-time `constexpr` arithmetic on `std::ratio` exponents. There is no
  unification, no inference of unknown dimensions, and no principal types — C++'s
  template argument deduction only propagates _forward_.

**Dimensional polymorphism (`sqr : α → α²`) is expressible** — this is C++'s native
strength: a function template with a deduced return type is implicitly polymorphic
over the whole (open) dimension group, with no per-base-dimension bounds
(contrast [`uom`][rust-uom]'s seven-fold `typenum` where-clauses). Reproduced
locally [gcc 15.2.0, `-std=c++14`, 2026-07-03]:

```cpp
// locally reproduced — generic over ANY unit; result unit computed by the type system
template <typename U, typename R>
constexpr auto sqr(au::Quantity<U, R> q) {
    return q * q;
}

sqr(au::meters(3.0));       // prints "9 m^2"
sqr(sqr(au::meters(2.0)));  // composes: prints "16 m^4"
```

The cost of the C++14 floor shows in _constraining_ such templates: without concepts
there is no `QuantityOf<Length>`-style signature, only SFINAE. Au's own comparison
matrix self-assesses "Generic Dimensions" as "Currently clunky. Could be better by
adding concepts in extra C++20-only file, without compromising C++14 support"
([`docs/alternatives/index.md`][alternatives]) — honest, and the survey's clearest
example of what the C++14 floor actually costs.

## Extensibility

- **New units — the primary, frictionless path.** Five lines of ordinary code (shown
  [above](#defining-a-unit-inherit-from-a-unit-expression)); no macro, no registry,
  no fork. Prefixes compose on both types and makers: `Kilo<Grams>{}`,
  `kilo(grams)`, `mebi(bytes)` ([`au/prefix.hh`][prefix-hh]). 60 unit headers (each
  with a `_fwd.hh` companion) ship in `au/units/`, plus SI-2019 exact constants in
  `au/constants/` ([`au/constants/`][constants-dir]).
- **New base dimensions — supported, with a distributed-uniqueness quirk.** A base
  dimension is any type with a unique `int64_t base_dim_index`
  ([`docs/howto/new-dimensions.md`][new-dimensions]):

  ```cpp
  // au: docs/howto/new-dimensions.md — a "pixels" base dimension + unit
  struct PixelBaseDim : au::base_dim::BaseDimension<1690384951> {};

  struct Pixels : au::UnitImpl<au::Dimension<PixelBaseDim>> {
      static constexpr const char label[] = "px";
  };
  constexpr auto pixels = au::QuantityMaker<Pixels>{};
  ```

  The index orders the pack; "negative indices are reserved for the Au library", and
  the recommended way to keep user indices "unique among all base dimensions in your
  program" is — verbatim — "a GitHub issue number for your project, or a current
  timestamp in seconds using the Unix epoch". Coordination-free, but global
  uniqueness rests on convention: two independent libraries picking the same index
  for different base dimensions would produce a silently shared basis vector.

- **No systems of measurement.** There is exactly one implicit global system; the
  comparison matrix marks Au "poor" on this axis by its own hand, with the rationale
  attached: "Single, implicit global system. (Intentional design tradeoff: reduces
  learning curve, and makes compiler errors shorter.)"
  ([`docs/alternatives/index.md`][alternatives]). Contrast [mp-units][mp-units]'
  explicit systems and [`uom`][rust-uom]'s per-`system!` worlds — Au's answer to CGS
  vs MKS is "they're all just units with magnitudes".
- **Interop as a first-class feature.** `CorrespondingQuantity<T>` gives
  _bidirectional implicit_ conversion with equivalent types from `std::chrono` or
  any other units library ([`au/quantity.hh`][quantity-hh] L58–110) — explicitly
  pitched at incremental migration, including "two-hop" conversions
  (`docs/reference/corresponding_quantity.md`).

## Expressiveness edges

- **Fractional powers: fully supported.** Rational exponents are native in both
  dimensions and magnitudes; `sqrt` maps to `UnitPower<U, 1, 2>`
  ([`au/math.hh`][math-hh] L1014–1017). The `V/√Hz`-style noise-density idiom that
  [`uom`][rust-uom] cannot type is unremarkable here — reproduced locally
  [gcc 15.2.0, 2026-07-03]: `au::meters(4.0) / au::sqrt(au::seconds(4.0))` prints
  `2 m / s^(1/2)`.
- **Affine quantities: a general torsor type.** `QuantityPoint` is an explicit
  affine-space companion to `Quantity` — "`QuantityPoint` instances cannot be added
  to each other, and cannot be multiplied. However, they can be subtracted"
  ([`au/quantity_point.hh`][quantity-point-hh] L28–41; cf. the
  [torsor model][torsor]). Units opt into a nonzero origin via a member:
  `Celsius::origin()` returns `centi(kelvins)(27315)` — an exact integer in
  centikelvins, dodging the 273.15 float ([`au/units/celsius.hh`][celsius-hh]
  L35–41). `CommonPointUnit` is engineered so mixed-origin conversions need only
  positive-integer multiply and non-negative add, keeping unsigned-integer reps safe
  ([`au/unit_of_measure.hh`][unit-hh] L182–206). This is torsor machinery for _any_
  unit, not just temperature — ahead of [`uom`][rust-uom]'s temperature-only pair,
  behind [mp-units][mp-units]' `point`/`delta` quantity-spec modifiers.
- **Logarithmic quantities: absent.** No decibel/neper support exists; the
  comparison matrix marks Au "poor" ("Plan to support someday; see [#41][issue-41]")
  and, notably, scores the otherwise-simpler nholthaus/units "best" on this one axis
  ([`docs/alternatives/index.md`][alternatives]).
- **Angles: a base dimension.** `base_dim::Angle` sits alongside `Length` and `Time`
  ([`au/dimension.hh`][dimension-hh] L110), so `Radians`, `Degrees` (magnitude
  `π/180`), and `Revolutions` are dimensioned units and radians-vs-degrees confusion
  is a compile error. This is a deliberate departure from strict SI (which makes
  angle dimensionless); Au does **not** offer the "pure SI" mode that
  [mp-units][mp-units] provides alongside its strong angles. `Information`
  (bits/bytes) gets the same base-dimension treatment.
- **Kind vs dimension: deliberately absent — and the edges show.** Au has no kind
  mechanism; the matrix row "'Kind' Types" reads "No plans at present to support"
  ([`docs/alternatives/index.md`][alternatives]). `Hertz` and `Becquerel` are
  distinct strong types with the _same_ dimension (`T⁻¹`) and magnitude
  ([`au/units/hertz.hh`][hertz-hh], [`au/units/becquerel.hh`][becquerel-hh]), so
  they are "quantity-equivalent" and interconvert **implicitly**: locally verified,
  `au::QuantityD<au::Hertz> h = au::becquerel(3.0);` compiles and prints `3 Hz`
  [gcc 15.2.0, 2026-07-03]. No Hz/Bq or J/N·m firewall exists. Curiously,
  _adding_ `hertz(1.0) + becquerel(2.0)` fails to compile — but with
  `static assertion failed: Broken strict total ordering: distinct input types
compare equal` ([`au/packs.hh`][packs-hh] L312): the pack ordering cannot rank two
  units tied on every property. That is an artifact of the common-unit machinery
  (the documented escape is a `UnitOrderTiebreaker` specialization,
  [`docs/troubleshooting.md`][troubleshooting] §"Broken strict total ordering"), not
  a semantic kind check — the implicit-conversion route around it is wide open.
- **Dimensionless is graded, and exact cancellation exits the library.** `Unos`
  (magnitude 1), `Percent` (magnitude `1/100` as `Pow<Prime<2>, -2>, Pow<Prime<5>, -2>`
  — [`au/units/percent.hh`][percent-hh]) are ordinary units; `unos(0.75).as(percent)`
  replaces remember-to-multiply-by-100. But a _perfectly cancelling_ quotient
  returns a **raw number**, not `Quantity<Unos>`: "Users generally tend to expect
  the result of a perfectly unit-cancelling expression to behave exactly like a raw
  number, in _every_ respect" ([`docs/discussion/concepts/dimensionless.md`][dimensionless-doc]),
  at an acknowledged cost to generic code.
- **The `Zero` type.** A dedicated type implicitly convertible to any quantity
  (`Quantity(Zero)`, [`au/quantity.hh`][quantity-hh] L184–185) legitimizes the one
  number meaningful in every unit — construction (`q = ZERO;`) and sign comparison
  (`q < ZERO`) without naming a unit.

## Zero-cost story

The claim is structural and compile-time-arithmetic-based; the clone contains no
benchmark suite, but the mechanisms are all inspectable:

- **A `Quantity` is one field.** `Rep value_{};` is the sole data member
  ([`au/quantity.hh`][quantity-hh] L623); `Unit` exists only as a template
  parameter. Locally verified:
  `static_assert(sizeof(au::Quantity<au::Hertz, double>) == sizeof(double))` holds
  [gcc 15.2.0, 2026-07-03]. Every operator is `constexpr` and delegates to the
  underlying rep's operator (e.g. same-unit `operator+` is
  `make_quantity<UnitT>(a.value_ + b.value_)`, [`au/quantity.hh`][quantity-hh]
  L328–338).
- **Conversion factors are compile-time constants.** `get_value<T>(Magnitude)` runs
  entirely in `constexpr` context ([`au/magnitude.hh`][magnitude-hh] L785–997), so a
  runtime conversion is a single multiply (or divide) by a literal — and the
  [applying-magnitudes discussion][applying-mag] documents which form (integer
  multiply, integer divide, or float multiply) each category of magnitude compiles
  to. Same-unit operations touch no factor at all.
- **The safety machinery is compile-time-only by default.** Risk policies, the
  overflow "safety surface", and the truncation analysis are all template
  metafunctions ([`au/conversion_policy.hh`][conversion-policy-hh]); the _runtime_
  checkers (`will_conversion_truncate` etc.) are separate opt-in calls.
- **The embedded posture doubles as erasure evidence:** no RTTI, no exceptions, no
  allocation anywhere in the core headers; labels are `sizeof()`-compatible `char`
  arrays rather than `std::string` ([`au/unit_of_measure.hh`][unit-hh] L49–70); I/O
  is a separable header (`au_noio.hh` single-file variant,
  [`docs/install.md`][install]); `AU_DEVICE_FUNC` annotations make the same headers
  CUDA-callable. The README's summary claim — "Catch unit errors at compile time,
  with **no runtime penalty**" ([`README.md`][readme]) — is the standard
  phantom-type erasure argument; unlike [`uom`][rust-uom]'s
  `#[repr(transparent)]` there is no ABI-layout guarantee attribute, but a
  single-non-static-member standard-layout class is layout-identical to its member
  in practice on every ABI Au supports.

## Diagnostics

The mandated experiment — adding metres to seconds — against the pinned clone
(`-I $REPOS/cpp/au`, `#include "au/au.hh"`):

```cpp
// locally reproduced — mismatch.cc
auto oops = au::meters(1.0) + au::seconds(1.0);
```

```text
au/unit_of_measure.hh: In instantiation of ‘struct au::UnitRatioImpl<au::Meters, au::Seconds>’:
    [ ~8 "required from" frames through EliminateRedundantUnitsImpl / ComputeCommonUnit ]
au/quantity.hh:994:11:   required from ‘constexpr auto au::operator+(const Quantity<U1, R1>&,
    const Quantity<U2, R2>&) [with U1 = Meters; U2 = Seconds; R1 = double; R2 = double]’
  994 |     using U = CommonUnit<U1, U2>;
mismatch.cc:7:50:   required from here
    7 |     auto oops = au::meters(1.0) + au::seconds(1.0);
      |                                                  ^
au/unit_of_measure.hh:132:45: error: static assertion failed: Can only compute ratio of same-dimension units
  132 |     static_assert(HasSameDimension<U1, U2>::value,
      |                                             ^~~~~
```

[reproduced locally, `g++ (GCC) 15.2.0`, `-std=c++14`, 2026-07-03; 61 lines total
(the assertion fires once per operand order), instantiation-stack paths abbreviated,
error lines verbatim]

The signal is good by C++ standards: the offending types are `au::Meters` and
`au::Seconds` — two short, human-named strong types, exactly the payoff promised for
strong unit typedefs — the `[with U1 = Meters; U2 = Seconds; …]` binding names both
operands, and the `static_assert` string states the semantic problem. The 8-frame
`ComputeCommonUnit` scaffolding between user code and the assertion is the residual
noise.

The **policy errors** are better still — Au embeds the _documentation URL and the
risk set_ in the assertion text. `au::inches(24).as(au::feet)` produces, in 15
lines [reproduced locally, same toolchain]:

```text
au/quantity.hh:605:24: error: static assertion failed: Truncation risk too high.
    See <https://aurora-opensource.github.io/au/main/troubleshooting/#risk-too-high>.
    Your "risk set" is `TRUNCATION_RISK`.
```

Diagnostics are a **documented, tested product surface**: `au/error_examples.cc`
maintains one broken snippet per error category, and the 1 419-line
[`docs/troubleshooting.md`][troubleshooting] pastes each snippet's full compiler
output for **clang 14, gcc 10, and MSVC 2022** so users can search their own error
text against it ("copy some relevant snippets from your compiler error, and then
search the text of this page"). No other system in this survey documents its failure
modes this systematically. One honesty note from comparing rungs: the guide's
recorded metres-plus-seconds error is the older
`no type named 'type' in 'std::common_type<au::Quantity<au::Meters, int>, au::Quantity<au::Seconds, int>>'`
([`docs/troubleshooting.md`][troubleshooting] §"No type named 'type'"), while the
pinned implementation now fails earlier with the readable `static_assert` above —
the diagnostic _improved_ ahead of its own documentation.

## Ergonomics & compile-time cost

**Declaration overhead is minimal at every tier.** Using shipped units is one
include per unit (`au/units/meters.hh` — "easily-guessable header per unit") or one
generated single file; a new unit is ~5 lines; a new base dimension ~8. Everything
lives in the single short namespace `au::`. Callsite grammar is a stated design
goal: singular names exist so `speed.in(miles / hour)` reads correctly, and symbols
(`using symbols::m;` then `3.5f * m`) cover terse construction without UDLs.

**Compile time is treated as a budget.** Measured locally against the pinned
clone [gcc 15.2.0, `-std=c++14`, 2026-07-03]: a TU including `au/au.hh` + `au/io.hh` +
six unit headers plus `<iostream>` compiles in **0.57 s / ~111 MB peak RSS**, vs
0.39 s for an `<iostream>`-only baseline — an increment of ~0.2 s, matching the
README's "small compile time burden" claim. The scaling law is documented: "the
library's compile time slowdown is largely proportional to the number of units
included in a translation unit" ([`docs/install.md`][install]) — which is why the
default single-file build ships only base units and why all-units files are "only
for use cases where you don't care about compile time". `fwd.hh` forward-declaration
headers exist for interface-only TUs.

**Delivery is a spectrum.** Full Bazel/CMake install; Conan/vcpkg community
packages; or the single-header path:
`tools/bin/make-single-file --units meters seconds newtons > au.hh` generates a
custom, version-stamped header with exactly the chosen units
([`docs/install.md`][install] §"Custom single file"), with `--noio` to drop
`<iostream>`; pre-generated variants (`au.hh`, `au_noio.hh`, `au_stdformat.hh`, …)
are published from every commit.

**Error readability was a first-class requirement** (see
[Diagnostics](#diagnostics)) — strong typenames, one short namespace, and the
troubleshooting guide are three coordinated parts of one policy, and the alternatives
matrix ranks C++ units libraries on "Compiler Error Readability" as an explicit
criterion ([`docs/alternatives/index.md`][alternatives]).

---

## Strengths

- **The magnitude vector space** — primes + `π` as basis vectors gives exact,
  overflow-proof, radical-capable conversion factors; the survey's most elegant
  answer to "what number type are conversion factors?", since adopted by
  [mp-units][mp-units].
- **Conversion-risk policy with an adaptive overflow surface** — truncation and
  overflow are separately named, separately waivable compile-time risks; the
  explicit-rep escape hatch keeps the force visible at the callsite; runtime value
  checkers complete the story.
- **Maker-only construction (unit safety)** — the private constructor plus quantity
  makers make every entry/exit of the library name its unit, by construction.
- **C++14 + header-only + single-file generation** — the widest deployment envelope
  of any modern units library; embedded and CUDA users are first-class.
- **Diagnostics as a product** — strong short typenames, doc URLs inside
  `static_assert` strings, per-compiler documented error catalogs, `error_examples.cc`
  kept compiling-broken on purpose.
- **Rational exponents and an open basis** — `sqrt`/`root` of units just work;
  pixels-per-inch-style base dimensions are user-addable in a few lines.
- **`QuantityPoint` + origins + `Zero`** — affine quantities and sign handling done
  generally, with integer-safe common-point-unit machinery.

## Weaknesses

- **No kind mechanism, by declared policy** — `Hz` and `Bq` interconvert implicitly;
  torque vs energy is unguarded; the only Hz+Bq "protection" is an accidental
  pack-ordering error. The one axis where [mp-units][mp-units] and even
  [`uom`][rust-uom]'s flat `Kind` tag are strictly ahead.
- **No logarithmic quantities** — dB/neper support is an open issue ([#41][issue-41]).
- **Single implicit global system** — no CGS/natural-units scoping, no
  per-system interop story; acknowledged as a deliberate trade
  ([`docs/alternatives/index.md`][alternatives]).
- **Generic-dimension code is clunky under the C++14 floor** — no concepts means
  SFINAE-style constraints; self-assessed as the library's weak axis.
- **Exact cancellation returns raw numbers** — ergonomic for application code,
  a documented wart for generic code (is `a / b` a `Quantity` or a `double`?).
- **Distributed base-dimension indices** — uniqueness of `base_dim_index` across
  independent libraries rests on a timestamp/issue-number convention, not on the
  type system.
- **Explicit-rep conversions currently skip all risk checks** — the
  `static_cast`-like semantics of `q.as<T>(unit)` is a known footgun scheduled to
  tighten in `0.6.0` ([#122][issue-122]).

## Key design decisions and trade-offs

| Decision                                                                          | Rationale                                                                                                            | Trade-off                                                                                                           |
| --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| C++14 floor, header-only, no macros/UDLs                                          | Reach every production toolchain incl. embedded/CUDA; readable non-positional unit definitions                       | No concepts: generic-dimension constraints are SFINAE-clunky; C++14 label boilerplate (`.cc` definitions)           |
| Variadic packs with strong named base types (not positional vectors)              | Readable errors (`Dimension<base_dim::Length, Pow<base_dim::Time, -1>>`); open basis; no callsite churn on extension | Strict-total-ordering machinery leaks (`Broken strict total ordering`) exactly when two units tie on every property |
| Magnitudes as a `ℚ`-vector space over primes + `Pi`                               | Exact products/powers/roots; no `std::ratio` overflow; `π` exactly representable for angles                          | Novel formalism to learn; magnitude types in errors (`Pow<Prime<2>, -2>, …`) are implementation-flavored            |
| Quantity makers + private constructor                                             | Unit safety: every boundary crossing names its unit at the callsite; makers compose (`kilo(meters)`, `miles / hour`) | No literals-style terseness without importing `symbols::`; makers are one more concept vs a plain constructor       |
| Lazy conversion at `CommonUnit`, units kept in the type                           | No boundary rounding at construction; integer reps stay exact in their own unit; labels/errors keep familiar names   | Cross-unit ops instantiate common-unit machinery; strong types reduce exact cancellation (alias guidance needed)    |
| Risk-policy conversions (`check_for`/`ignore`, overflow threshold `mag<2'147>()`) | Truncation/overflow become named, auditable, per-callsite decisions; adapts to rep width                             | `.as<T>(unit)` currently ignores all risks (until [#122][issue-122]); policy objects add API surface                |
| Angle and Information as base dimensions                                          | rad/deg and bits/bytes errors caught with zero extra mechanism                                                       | Diverges from strict SI; no "pure SI angle" mode; doesn't generalize to Hz/Bq or torque/energy (no kinds)           |
| One implicit global system                                                        | Shorter errors, flatter learning curve                                                                               | No explicit systems of measurement; "poor" on its own comparison matrix                                             |

## Sources

- [aurora-opensource/au — GitHub repository][repo] (pinned locally at
  `$REPOS/cpp/au` @ `50b97bf`, 2026-07-01)
- [`README.md` — positioning, `<chrono>` analogy, "only Au offers all of them"][readme]
- [`au/dimension.hh` — `Dimension` pack, 9 base dimensions, rational `DimPower`][dimension-hh]
- [`au/magnitude.hh` — `Magnitude` pack, `Prime`/`Pi`/`Negative` bases, `mag<N>()`, `get_value`][magnitude-hh]
- [`au/packs.hh` — the shared base-powers engine: `Pow`, `RatioPow`, orderings][packs-hh]
- [`au/unit_of_measure.hh` — unit duck type, `UnitRatio`, `CommonUnit`, labels][unit-hh]
- [`au/quantity.hh` — `Quantity`, makers, `as`/`in`/risk policies, operators][quantity-hh]
- [`au/conversion_policy.hh` — risk sets, `OVERFLOW_THRESHOLD`, implicit-conversion policy][conversion-policy-hh]
- [`au/quantity_point.hh` — affine `QuantityPoint`][quantity-point-hh] ·
  [`au/units/celsius.hh` — integer-exact origin][celsius-hh] ·
  [`au/units/{hertz,becquerel}.hh` — the kind gap][hertz-hh] ·
  [`au/units/percent.hh`][percent-hh] · [`au/math.hh` — `sqrt` → `UnitPower<U, 1, 2>`][math-hh]
- [`docs/discussion/implementation/vector_space.md` — the vector-space rationale][vector-space] ·
  [applying magnitudes][applying-mag] ·
  [`docs/discussion/concepts/{truncation,conversion_risks,dimensionless}.md`][truncation-doc]
- [`docs/howto/new-units.md`][new-units] · [`docs/howto/new-dimensions.md`][new-dimensions] ·
  [`docs/discussion/idioms/unit-slots.md`][unit-slots]
- [`docs/troubleshooting.md` — per-compiler documented errors][troubleshooting] ·
  [`au/error_examples.cc` — the maintained broken snippets][error-examples]
- [`docs/alternatives/index.md` — Au's own comparison matrix (kinds, dB, systems self-assessments)][alternatives] ·
  [`docs/install.md` — single-file generation][install] ·
  [`docs/supported-compilers.md`][compilers] · [`docs/tutorial/101-quantity-makers.md` — unit safety][tutorial] ·
  [`docs/reference/quantity.md` — explicit-rep semantics][quantity-ref]
- Local reproductions (mismatch, truncation, valid ops, custom unit, generic `sqr`,
  fractional powers, Hz/Bq interconversion, `sizeof`, compile timing): scratch
  workspace against the pinned clone, `g++ (GCC) 15.2.0`, `-std=c++14`, 2026-07-03
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [free abelian group][fag] · [Kennedy's type system][kennedy] ·
  [torsors & affine quantities][torsor] · [mp-units][mp-units] ·
  [Boost.Units][boost] · [`uom` (Rust)][rust-uom] · [`dimensioned`][dimensioned] ·
  [F# units of measure][fsharp] · [`uom-plugin`][uom-plugin] · [Pint][pint] ·
  [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone (au @ 50b97bf) -->

[repo]: https://github.com/aurora-opensource/au
[readme]: https://github.com/aurora-opensource/au/blob/50b97bf/README.md
[dimension-hh]: https://github.com/aurora-opensource/au/blob/50b97bf/au/dimension.hh
[magnitude-hh]: https://github.com/aurora-opensource/au/blob/50b97bf/au/magnitude.hh
[packs-hh]: https://github.com/aurora-opensource/au/blob/50b97bf/au/packs.hh
[unit-hh]: https://github.com/aurora-opensource/au/blob/50b97bf/au/unit_of_measure.hh
[quantity-hh]: https://github.com/aurora-opensource/au/blob/50b97bf/au/quantity.hh
[conversion-policy-hh]: https://github.com/aurora-opensource/au/blob/50b97bf/au/conversion_policy.hh
[quantity-point-hh]: https://github.com/aurora-opensource/au/blob/50b97bf/au/quantity_point.hh
[math-hh]: https://github.com/aurora-opensource/au/blob/50b97bf/au/math.hh
[prefix-hh]: https://github.com/aurora-opensource/au/blob/50b97bf/au/prefix.hh
[celsius-hh]: https://github.com/aurora-opensource/au/blob/50b97bf/au/units/celsius.hh
[hertz-hh]: https://github.com/aurora-opensource/au/blob/50b97bf/au/units/hertz.hh
[becquerel-hh]: https://github.com/aurora-opensource/au/blob/50b97bf/au/units/becquerel.hh
[percent-hh]: https://github.com/aurora-opensource/au/blob/50b97bf/au/units/percent.hh
[constants-dir]: https://github.com/aurora-opensource/au/tree/50b97bf/au/constants
[error-examples]: https://github.com/aurora-opensource/au/blob/50b97bf/au/error_examples.cc
[vector-space]: https://github.com/aurora-opensource/au/blob/50b97bf/docs/discussion/implementation/vector_space.md
[applying-mag]: https://github.com/aurora-opensource/au/blob/50b97bf/docs/discussion/implementation/applying_magnitudes.md
[truncation-doc]: https://github.com/aurora-opensource/au/blob/50b97bf/docs/discussion/concepts/truncation.md
[dimensionless-doc]: https://github.com/aurora-opensource/au/blob/50b97bf/docs/discussion/concepts/dimensionless.md
[new-units]: https://github.com/aurora-opensource/au/blob/50b97bf/docs/howto/new-units.md
[new-dimensions]: https://github.com/aurora-opensource/au/blob/50b97bf/docs/howto/new-dimensions.md
[unit-slots]: https://github.com/aurora-opensource/au/blob/50b97bf/docs/discussion/idioms/unit-slots.md
[troubleshooting]: https://github.com/aurora-opensource/au/blob/50b97bf/docs/troubleshooting.md
[alternatives]: https://github.com/aurora-opensource/au/blob/50b97bf/docs/alternatives/index.md
[install]: https://github.com/aurora-opensource/au/blob/50b97bf/docs/install.md
[compilers]: https://github.com/aurora-opensource/au/blob/50b97bf/docs/supported-compilers.md
[tutorial]: https://github.com/aurora-opensource/au/blob/50b97bf/docs/tutorial/101-quantity-makers.md
[quantity-ref]: https://github.com/aurora-opensource/au/blob/50b97bf/docs/reference/quantity.md

<!-- Official docs & issues -->

[docs]: https://aurora-opensource.github.io/au/main/
[issue-41]: https://github.com/aurora-opensource/au/issues/41
[issue-122]: https://github.com/aurora-opensource/au/issues/122

<!-- Same-tree theory -->

[mechanisms]: ./theory/type-system-mechanisms.md
[fag]: ./theory/free-abelian-group.md
[kennedy]: ./theory/kennedy-types.md
[torsor]: ./theory/torsor-representation.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[mp-units]: ./cpp-mp-units.md
[boost]: ./cpp-boost-units.md
[rust-uom]: ./rust-uom.md
[dimensioned]: ./rust-dimensioned.md
[fsharp]: ./fsharp-uom.md
[uom-plugin]: ./haskell-uom-plugin.md
[pint]: ./python-pint.md
