# dimensioned (Rust)

The pioneer Rust dimensional-analysis crate: a `make_units!` macro that stamps out an entire unit system — struct, type aliases, constants, and operator impls — with dimensions carried as a type-level array of [`typenum`][typenum] integers, one array slot per base unit of that system.

| Field            | Value                                                                                                                                                  |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language         | Rust (MSRV `1.23.0` per [`README.md`][readme]; `no_std`-capable — `std` is a default feature)                                                          |
| License          | MIT/Apache-2.0                                                                                                                                         |
| Repository       | [paholg/dimensioned][repo]                                                                                                                             |
| Documentation    | [docs.rs/dimensioned][docs] · [crates.io][crate]                                                                                                       |
| Key authors      | Paho Lurie-Gregg (`paholg`, original author; also co-author of the [`typenum`][typenum] crate itself)                                                  |
| Category         | Library-level [compile-time checking][concepts] (no compiler support; declarative macro DSL + build-script codegen)                                    |
| Mechanism        | `make_units!`-generated per-system struct `SI<V, U>` where `U` is a `tarr![…]` type-level array of `typenum` integers, one exponent slot per base unit |
| Exponent domain  | `ℤⁿ` per system (`n` = that system's base-unit count); **no rational exponents** — Gaussian half-integer dimensions encoded by square-root base units  |
| Checking time    | Compile time (trait solving + type identity); zero runtime checks                                                                                      |
| Analyzed version | `615c908` (pinned clone — repository HEAD, 2022-12-09)                                                                                                 |
| Latest release   | `0.8.0` (2022-04-28, per [`CHANGELOG.md`][changelog]); **dormant since 2022** — see below                                                              |

> [!NOTE]
> `dimensioned` is this survey's _elder_ Rust data point: it worked out the
> type-level-integer mechanism (first with Peano numbers, then by spawning
> [`typenum`][typenum]) years before [`uom`][rust-uom] industrialized the same idea, and
> it remains the more adventurous design — five unit systems including UCUM and
> Gaussian CGS, system-polymorphic generic code, and nightly auto-trait experiments.
> The repository has had no commit since 2022-12-09; the maintenance contrast with
> `uom` (releasing through 2026) is itself a finding this page documents. Mechanism
> theory: [type-system mechanisms][mechanisms]; cross-system synthesis: the
> [comparison capstone][comparison].

---

## Overview

### What it solves

`dimensioned` gives Rust compile-time dimensional analysis as a pure library: a
quantity is a value wrapped in a phantom-typed struct, arithmetic is overloaded so that
unit errors become type errors, and everything erases before runtime. The crate states
its goal in one line ([`src/lib.rs`][lib] L2–4):

> "Compile-time dimensional analysis for various unit systems using Rust's type
> system. Its goal is to provide zero cost unit safety while requiring minimal effort
> from the programmer."

The [`Cargo.toml`][cargo] description adds the ergonomic pitch:

> "Dimensioned aims to build on Rust's safety features by adding unit safety with no
> runtime cost. In addition, it aims to be as easy to use as possible, hopefully making
> things easier for you not just by avoiding bugs but also by making it clear what
> units things are. Never again should you need to specify units in a comment!"

Where [`uom`][rust-uom] ships one quantity system (ISQ) in depth, `dimensioned` ships
five unit systems in breadth — `si`, `ucum`, `mks`, `cgs`, `fps`
([`src/lib.rs`][lib] L203) — including a substantial slice of the
[UCUM][concepts] code (§30–§47 of the spec transcribed as constants,
[`src/build/ucum.rs`][ucum-build]) and the Gaussian CGS/MKS systems with their
half-integer electromagnetic dimensions.

### Design philosophy

Two ideas define the crate against its successor.

**The unit system is the type; the macro makes the system.** There is no single shared
`Quantity` type. Each `make_units!` invocation defines a _fresh_ struct (`SI<V, U>`,
`CGS<V, U>`, …) plus all of its aliases, constants, and trait impls. The crate-root
docs walk the mechanism ([`src/lib.rs`][lib] L43–48):

> "When a unit system is created, say the SI system, a struct with two parameters is
> made; in this case `SI<V, U>`. The first parameter, `V`, is for the value type -- it
> can be anything, and is the value to which we are giving units. The second parameter,
> `U`, is where the magic happens. It represents the units, and is a type-level array
> of type-level numbers."

**Constants, not constructors.** The idiomatic way to build a quantity is to multiply a
scalar by a unit constant — `let x = 3.0 * si::M;` — rather than call a
unit-parameterized constructor as in `uom`'s `Length::new::<meter>(3.0)`. Every base
unit, derived unit, and physical constant of a system exists as a `const` in `f32consts`
/ `f64consts` submodules (plus ten integer flavors), with the `f64` set re-exported at
module level ([`src/make_units.rs`][make-units] L348–402). The whole safety story is
then one sentence ([`src/lib.rs`][lib] L95–97):

> "That's basically it. All of the dimensional safety comes from whether things
> typecheck, and from performing type-level arithmetic, thanks to the typenum crate.
> Pretty much everything else is for ergonomics."

---

## How it works

### `make_units!` — a whole system from one declaration

The macro is "the heart of this library" ([`src/make_units.rs`][make-units] L3). Its own
docs define a miniature two-unit system that this survey reproduced locally (see
[Diagnostics](#diagnostics) for the toolchain):

```rust
// dimensioned: src/make_units.rs L18-49 (macro doc example, abridged; locally re-run)
pub mod ms {
    make_units! {
        MS;
        ONE: Unitless;

        base {
            M: Meter, "m", Length;
            S: Second, "s", Time;
        }

        derived {
            MPS: MeterPerSecond = (Meter / Second), Velocity;
            HZ: Hertz = (Unitless / Second), Frequency;
        }

        constants {
            FT: Meter = 0.3048;
            MIN: Second = 60.0;
        }

        fmt = true;
    }
    pub use self::f64consts::*;
}
```

Each `base` line is `CONST: Type, "token", Dimension;` — the constant, the type alias,
the print token, and an optional marker trait from [`src/dimensions.rs`][dimensions]
that the macro implements for the alias. `derived` lines carry a formula over
already-declared units (only `*` and `/`, evaluated by a recursive helper macro into
`typenum::Sum`/`Diff` on the exponent arrays —
[`src/make_units.rs`][make-units] L1163–1169). `constants` attach values to any unit
(`FT` is `0.3048` in the `Meter` type — feet are a constant, not a type).

The generated struct is minimal ([`src/make_units.rs`][make-units] L196–216):

```rust
// dimensioned: src/make_units.rs L196-216 (abridged) — generated once per system
#[derive(Eq, PartialEq, Ord, PartialOrd, Clone, Copy, Hash)]
pub struct $System<V, U> {
    /// This is the value of whatever type we're giving units. Using it directly
    /// bypasses all of the dimensional analysis that having a unit system provides,
    /// and should be avoided whenever possible.
    pub value_unsafe: V,

    _marker: PhantomData<U>,
}

impl<V, U> $System<V, U> {
    #[inline]
    pub const fn new(v: V) -> Self {
        $System { value_unsafe: v, _marker: PhantomData }
    }
}
```

The field name `value_unsafe` is a deliberate ergonomic signal — raw access bypasses
the analysis, and the name says so at every use site.

### The exponent array and the operators

`U` is a `tarr![…]` — `typenum`'s type-level cons-list of type-level integers, copied
into the crate "so that users don't have to import typenum for the make_units macro to
work" ([`src/lib.rs`][lib] L143–172). The SI
aliases from the crate docs ([`src/lib.rs`][lib] L61–64):

```rust
// dimensioned: src/lib.rs L61-64 — SI's 7-slot exponent vectors
type Meter<V>    = SI<V, tarr![P1, Z0, Z0, Z0, Z0, Z0, Z0]>;
type Kilogram<V> = SI<V, tarr![Z0, P1, Z0, Z0, Z0, Z0, Z0]>;
type Second<V>   = SI<V, tarr![Z0, Z0, P1, Z0, Z0, Z0, Z0]>;
type Newton<V>   = SI<V, tarr![P1, P1, N2, Z0, Z0, Z0, Z0]>;
```

Arithmetic is generated by an internal ops macro. Addition demands the _same_ `U` on
both sides; multiplication and division map value-level `*`/`/` to exponent-level
`Add`/`Sub` on the whole array ([`src/make_units.rs`][make-units] L719–769):

```rust
// dimensioned: src/make_units.rs L722-730 (abridged) — Mul: units add
impl<Vl, Ul, Vr, Ur> Mul<$System<Vr, Ur>> for $System<Vl, Ul>
where
    Vl: Mul<Vr>, Ul: Add<Ur>,          // typenum adds the arrays element-wise
{
    type Output = $System<<Vl as Mul<Vr>>::Output, <Ul as Add<Ur>>::Output>;
    #[inline]
    fn mul(self, rhs: $System<Vr, Ur>) -> Self::Output {
        $System::new(Mul::mul(self.value_unsafe, rhs.value_unsafe))
    }
}
```

Scalar-times-quantity works through a `prim!` macro instantiated for every primitive
(`f32`…`usize`, even `bool` and `char` — [`src/make_units.rs`][make-units] L993–1009);
the nightly-only `oibit` feature replaces that enumeration with a negative-impl auto
trait `NotDim` so _any_ non-quantity type can be a scalar
([`src/traits.rs`][traits] L121–123, [`README.md`][readme] L21–23).

### Printing recovers the exponents at runtime

`Display` walks the type-level array by converting it to a value-level
`GenericArray<isize, _>` (`U::to_ga()`, [`src/array.rs`][array]) and zips it with the
per-system print tokens — which is how `format!("{}", x*t)` yields `"6 m*s"`
([`src/lib.rs`][lib] L83–93; verified locally, output `x * t = 6 m*s`).

### The shipped systems are build-script-generated

The five bundled systems are not handwritten source: a build script
([`src/build/mod.rs`][build-mod]) holds each system as data (`base_units!`,
`derived_units!`, `constants!` tables in [`src/build/{si,ucum,mks,cgs,fps}.rs`][si-build])
and writes out `make_units!` invocations — plus documentation tables and
cross-system reflexivity tests — into `OUT_DIR` at compile time
([`src/lib.rs`][lib] L194). The stated purpose: "it lets us make unit systems with
nice, matching documentation that is guaranteed to be correct" and to "generate some
tests that we could not do otherwide" _[sic]_ ([`src/build/mod.rs`][build-mod] L1–9).

---

## Dimension representation

A dimension is a **`ℤⁿ` exponent vector encoded as a type-level array**
(`TArr`/`tarr![…]`) of `typenum` integers, attached as the phantom `U` parameter of the
per-system struct — for SI, `ℤ⁷` in the declaration order Meter, Kilogram, Second,
Ampere, Kelvin, Candela, Mole ([`src/lib.rs`][lib] L50–64,
[`src/build/si.rs`][si-build] L13–21). Three representation choices distinguish it
from [`uom`][rust-uom]:

- **Positional array, not named associated types.** `uom` names each exponent
  (`type L`, `type M`, …) on a `Dimension` trait; `dimensioned` uses a bare cons-list
  whose meaning is positional ("the order is the order in which the base units were
  defined", [`src/lib.rs`][lib] L51–52). Structural type identity of the array is
  dimension equality — no normalization step is ever needed, but errors print nested
  `TArr<…, TArr<…>>` spines (see [Diagnostics](#diagnostics)).
- **The vector spans base _units_, not base _quantities_.** Each system's array is
  indexed by its own base units; there is no system-transcending dimension object.
  Cross-system genericity is instead recovered by marker traits: `dimensions::Length`,
  `dimensions::Time`, … are empty traits implemented by whichever alias of each system
  the declaration tags ([`src/dimensions.rs`][dimensions] L44–75) — `si::Meter<V>`,
  `cgs::Centimeter<V>`, and `ucum::Meter<V>` all implement `Length`.
- **Exponents are integers only — but the basis is negotiable.** Nothing in the crate
  can write a fractional power of a base unit (the answer to this survey's "typenum
  rationals?" question is **no** — every exponent bound is `typenum` integer
  arithmetic). Instead, systems that need half-integer dimensions _rescale the basis_:
  Gaussian CGS declares its base units as `SqrtCentimeter` and `SqrtGram`, making the
  centimeter itself a derived unit ([`src/build/cgs.rs`][cgs-build] L12–19):

  ```rust
  // dimensioned: src/build/cgs.rs L12-19 — sqrt base units keep exponents in ℤ
  base: base_units!(
      SQRTCM: SqrtCentimeter, sqrtcm;
      SQRTG: SqrtGram, sqrtg;
      S: Second, s, Time;
  ),
  derived: derived_units!(
      CM: Centimeter = SqrtCentimeter * SqrtCentimeter, Length;
      G: Gram = SqrtGram * SqrtGram, Mass;
      // …
  ```

  In the doubled basis the statcoulomb's `cm^3/2 · g^1/2 · s^-1` becomes the integer
  vector `tarr![P3, P1, N1]` over `(SqrtCentimeter, SqrtGram, Second)`
  ([`src/build/cgs.rs`][cgs-build] L49: `STATC: StatCoulomb = SqrtGram *
SqrtCentimeter * Centimeter / Second`). This is the classic free-abelian-group move —
  a change of generators, not a change of exponent group (see
  [free abelian group][fag]) — and the formatter papers over it by halving exponents at
  print time, emitting `1 cm^1.5*g^0.5*s^-1` for one statcoulomb
  ([`src/fmt.rs`][fmt] L12–37; output verified locally).

Dimensionless is the all-zeros array (`Unitless`, `pub type $Unitless =
tarr![Z0, …]` — [`src/make_units.rs`][make-units] L1034), with a `Dimensionless` trait
and a `Deref` to the bare value implemented _only_ for it
([`src/make_units.rs`][make-units] L507–514).

## Checking & inference

All checking is **stock `rustc` trait solving** — no plugin, no proc macro, no custom
solver. `l + t` requires both operands to be the same type (`U` equal as types);
`l * t` instantiates the generated `Mul` impl whose associated `Output` _evaluates_
`Ul + Ur` in `typenum`'s closed type-level arithmetic. The process is decidable and
purely computational: like [`uom`][rust-uom] and unlike the
[Kennedy][kennedy]-lineage systems ([F#][fsharp], [`uom-plugin`][uom-plugin]), the
checker **evaluates dimension arithmetic the author spelled out; it never solves for
unknowns** (the "checker evaluates, never solves" row of the
[mechanism taxonomy][mechanisms]).

**Dimensional polymorphism is expressible — and, unusually, system-polymorphic.** The
README's flagship example is a `speed` function generic over _both_ the dimension
arithmetic and the unit system ([`README.md`][readme] L56–91, shipped as
[`examples/readme-example.rs`][example]; re-run locally against the pinned clone):

```rust
// dimensioned: examples/readme-example.rs — generic over any unit system
use dim::dimensions::{Length, Time};
use dim::typenum::Quot;
use std::ops::Div;

fn generic_speed<L, T>(dist: L, time: T) -> Quot<L, T>
where
    L: Length + Div<T>,
    T: Time,
{
    dist / time
}
```

`Quot<L, T>` is just `<L as Div<T>>::Output` — because the arithmetic impls live on the
quantity types themselves, `typenum`'s operator aliases apply directly to quantities.
The same call works for `si` metres and `cgs` centimetres (verified locally: `cgs`
values flow through `generic_speed` unchanged). This is strictly more polymorphic than
`uom`'s `powi`-style generics, which are pinned to one system's seven named exponent
slots. What remains impossible is Kennedy-style **inference**: nothing can conclude
"this argument must be `Length`" from usage, no principal types exist, and an
under-annotated generic simply fails to resolve. Exponent-manipulating generics carry
`typenum` bounds (`U: Add<Ur>`, `U: PartialDiv<P2>`, …) exactly as in `uom`, just over
one array instead of seven slots — e.g. the generated `Sqrt` impl requires
`U: PartialDiv<P2>` so that a square root exists only when every exponent is even
([`src/make_units.rs`][make-units] L465–476).

One generated impl is deliberately loose: `Rem` accepts a right-hand side of _any_
dimension and keeps the left-hand units ("it's kinda its own thing" —
[`src/make_units.rs`][make-units] L771–783), so `6.0*si::M % 4.0*si::S` type-checks.
A small, documented-by-comment soundness concession no other operator makes.

## Extensibility

- **A whole unit system in user code — first-class and cheap.** `make_units!` is
  exported precisely so users can build systems the crate lacks; the macro docs open by
  asking you to upstream them: "If you find yourself using this macro, please think
  about whether the unit system you are creating would be useful to others; if so,
  submit an issue to get it added to dimensioned"
  ([`src/make_units.rs`][make-units] L6–7). The base-dimension set of
  a new system is arbitrary (`n` slots for `n` base lines), so a currency-plus-time
  system is as writable as a physics one. This is the axis where `dimensioned` is
  _more_ extensible than [`uom`][rust-uom], whose `system!`/`quantity!` split assumes
  ISQ-style quantity bookkeeping.
- **New derived aliases on an existing system — the `derived!` macro.**
  `derived!(si, SI: InverseMeter3 = Unitless / Meter3);` creates a type alias by
  folding `typenum::Sum`/`Diff` over the formula ([`src/make_units.rs`][make-units]
  L1059–1118). Notably restricted: "This macro is a bit fragile. It only supports the
  operators `*` and `/` and no parentheses" ([`src/make_units.rs`][make-units] L1076).
  Ordinary `typenum` aliases work too (`type MPS<T> = Quot<Meter<T>, Second<T>>;` —
  [`tests/derived.rs`][tests]).
- **New units on an existing system — constants only.** A "unit" like the foot is a
  `const FT: Meter<f64> = 0.3048 m`; adding one is one `constants` line (or a plain
  `const` in user code, [`src/make_units.rs`][make-units] L121–127). There is no
  per-unit type: unit identity is erased at construction, exactly as in `uom`'s
  eager-normalization model, with SI prefixes as plain float constants
  (`f64prefixes::CENTI` etc., [`src/f64prefixes.rs`][prefixes]).
- **Cross-system interop — hand-written, partial, and honest about physics.**
  Conversions are `core::convert::From` impls written per system pair
  ([`src/conversion.rs`][conversion]), with the module doc cataloguing the
  asymmetries: SI→UCUM "is defined only for SI units that don't contain `Mole`s";
  UCUM→SI only for quantities without `Radian`s; SI→CGS/MKS only for
  meter/kilogram/second/ampere combinations ([`src/conversion.rs`][conversion] L13–26).
  The SI→CGS impl performs the actual Gaussian identification in types — the target
  exponent array is computed as `2·Meter + 3·Ampere` sqrt-centimetres,
  `2·Kilogram + Ampere` sqrt-grams, `Second + 2·Ampere` seconds
  ([`src/conversion.rs`][conversion] L151–177), i.e. the ampere is dimensionally
  dissolved into `g^1/2 cm^3/2 s^-2`. The build script generates round-trip
  reflexivity tests for every convertible constant pair
  ([`src/build/mod.rs`][build-mod] L538–638).

## Expressiveness edges

- **Fractional powers: representable only by basis choice, not in general.** The
  exponent group is `ℤⁿ`; there is no `ℚ`. The sqrt-base-unit trick (above) covers
  Gaussian CGS/MKS/FPS because those systems' half-integers are known _in advance_ —
  but the trick doubles every exponent in the system, and a new fractional need
  (`V/√Hz` noise density in SI) would require redefining the whole system's basis.
  `Sqrt`/`Cbrt`/`Root` are partial operations gated on `PartialDiv` divisibility
  ([`src/make_units.rs`][make-units] L451–491): `(x*x).sqrt()` compiles, `x.sqrt()` for
  odd metres does not. Contrast the genuine `ℚ` exponents of [mp-units][mp-units] and
  [Au][au] and the rational powers of [Unitful.jl][unitful]; compare
  [`uom`][rust-uom], which shares the `ℤ`-only limit without the basis workaround.
- **Affine quantities: absent, by documented exclusion.** No Celsius or Fahrenheit
  exists anywhere in the crate; constants are strictly multiplicative ("the constants
  in the `base` and `derived` blocks are always created with a value of 1.0",
  [`src/make_units.rs`][make-units] L108–109). The UCUM system's prelude says why
  ([`src/build/ucum.rs`][ucum-build] L26–31):

  > "Units that require conversions that involve more than multiplication. These
  > include some temperature units (such as degrees Celcius) and logrithmic units
  > (such as decibels)." _[sic]_

  There is no point/difference split either — nothing like `uom`'s
  `TemperatureInterval` or [Au][au]'s `QuantityPoint`; the [torsor model][torsor] is
  simply out of scope. Kelvin (absolute) is the only temperature.

- **Logarithmic quantities: absent.** The UCUM build file has a section header
  "Levels (UCUM Section 46):" with **no entries under it**
  ([`src/build/ucum.rs`][ucum-build] L357–358) — decibels and nepers were
  contemplated and skipped, per the quote above.
- **Angle: two systems, two answers.** In `si`, angle is dimensionless — `RAD` and
  `SR` are `Unitless` constants of value `1.0` ([`src/build/si.rs`][si-build]
  L143–144). In `ucum`, `Radian` is a **base unit** with its own exponent slot
  ([`src/build/ucum.rs`][ucum-build] L59), following the UCUM spec — so
  `ucum` distinguishes torque from energy and angular frequency from frequency, while
  `si` cannot. The conversion layer refuses to bridge the disagreement (UCUM→SI is
  undefined for `Radian`-carrying quantities). As a bonus heterodoxy, UCUM's mole is a
  dimensionless _count_: `MOL: Unitless = 6.0221367e23*ONE.value_unsafe`
  ([`src/build/ucum.rs`][ucum-build] L122).
- **Kind-vs-dimension: absent.** There is no analogue of `uom`'s `Kind` tag. In `si`,
  `Becquerel` is literally defined as `Hertz` ([`src/build/si.rs`][si-build] L38:
  `BQ: Becquerel = Hertz`), `Sievert` as `Gray`, and torque can only be spelled
  `Joule` — same-dimension quantities are the same type, full stop. The
  `dimensions.rs` marker-trait set has one trait per dimension (`Frequency`), not per
  kind — there is no `Radioactivity` marker to distinguish (verified by reading
  [`src/dimensions.rs`][dimensions] end to end).

## Zero-cost story

The claim is "zero cost unit safety" ([`src/lib.rs`][lib] L4); the evidence at the
pinned SHA:

- **A quantity is one field plus a `PhantomData`.** The struct body is
  `pub value_unsafe: V` and `_marker: PhantomData<U>`
  ([`src/make_units.rs`][make-units] L196–207). Locally verified:
  `size_of::<si::Meter<f64>>() == size_of::<f64>()` holds
  [reproduced locally, `rustc 1.91.1`, 2026-07-03].
- **But — unlike [`uom`][rust-uom] — there is no `#[repr(transparent)]`.** The
  generated struct carries only a `derive` list; size equality is a fact of the
  compiler's layout in practice, not an ABI guarantee. The crate itself leans on
  layout compatibility in `unsafe` code — the generated `Index` impls cast
  `&V::Output` to `&Self::Output` by raw-pointer transmute
  ([`src/make_units.rs`][make-units] L519–546), and the crate-level clippy allow for
  `clippy::transmute_ptr_to_ptr` wears the caveat "// Not great. See issue #52."
  ([`src/lib.rs`][lib] L120–121).
- **`#[inline]` on every generated operator** and a `const fn new`
  ([`src/make_units.rs`][make-units] L211–216, made `const` in `0.8.0` —
  [`CHANGELOG.md`][changelog]), so wrapper arithmetic collapses to scalar arithmetic.
- **Construction is one multiplication.** `3.0 * si::M` multiplies by the constant
  `1.0`; `3.0 * si::FT` multiplies by `0.3048` — the same eager-normalization
  boundary cost as `uom`, with no conversion in steady-state arithmetic.
- **Serialization documents the erasure.** The `impl_serde!` macro doc:
  "The implementations generated by this macro only serialize the numeric values -
  not the actual units. Therefore, serialization is dimensionally unsafe, but it does
  not add any overhead over using plain numeric types"
  ([`src/make_units.rs`][make-units] L1239–1245).
- **The runtime residue is opt-in formatting**: `Display` reconstructs the exponent
  vector as a `GenericArray` at print time ([`src/array.rs`][array]); arithmetic never
  touches it. No benchmark suite exists in the repository (as with `uom`, the
  zero-cost claim is structural).

## Diagnostics

The mandated experiment — adding metres to seconds — against the pinned clone (path
dependency on `$REPOS/rust/dimensioned` @ `615c908`):

```rust
// locally reproduced — mismatch/src/main.rs
extern crate dimensioned as dim;

use dim::si;

fn main() {
    let l = 1.0 * si::M;
    let t = 1.0 * si::S;
    let err = l + t;
    println!("{}", err);
}
```

```text
error[E0308]: mismatched types
 --> src/main.rs:8:19
  |
7 |     let t = 1.0 * si::S;
  |             ----------- here the type of `t` is inferred to be `SI<f64, TArr<Z0, TArr<Z0, TArr<PInt<UInt<UTerm, B1>>, TArr<Z0, TArr<Z0, TArr<Z0, TArr<Z0, ATerm>>>>>>>>`
8 |     let err = l + t;
  |                   ^ expected `SI<_, TArr<PInt<UInt<UTerm, B1>>, ...>>`, found `SI<f64, TArr<Z0, TArr<Z0, ...>>>`
  |
  = note: expected struct `SI<_, TArr<PInt<UInt<UTerm, B1>>, TArr<_, TArr<Z0, _>>>>`
             found struct `SI<f64, TArr<Z0, TArr<_, TArr<PInt<UInt<UTerm, B1>>, _>>>>`

For more information about this error, try `rustc --explain E0308`.
```

[reproduced locally, `rustc 1.91.1` / `cargo 1.91.0` (nixpkgs), 2026-07-03]

The signal is present but encoded: the reader must know that slot 1 of the `TArr`
spine is metres and slot 3 seconds, then decode `PInt<UInt<UTerm, B1>>` as `+1`. It is
arguably _worse_ than `uom`'s output — the positional array gives no names at all,
where `uom` at least prints `L = …`/`T = …` bindings. The README owns this outright
([`README.md`][readme] L100–107):

> "Probably the biggest weakness of dimensioned are the error messages generated. The
> type signatures coming from dimensioned tend to just look like a bunch of
> gobbly-guck. Someday, we may have a better way to display them. For now, my advice
> is that when you get an error message involving dimensioned, just go to the line
> number and hopefully the issue will be apparant from the code alone." _[sic]_

The hoped-for fix never landed: [`todo.org`][todo] (in the pinned clone) still lists
"on_unimplemented :: Once this stabilizes, we can try try to make error messages
better." At `615c908` there is **no compile-fail test suite** — no `compiletest`
harness, no `compile_fail` doctests (verified by search of the clone); the negative
path lives only as a comment (`// Compiler error: // speed(x, x);` —
[`src/dimensions.rs`][dimensions] L35–36). Rung-1 local reproduction is therefore the
only diagnostic evidence this page relies on.

The valid-path counterpart, same toolchain, same clone [reproduced locally,
`rustc 1.91.1`, 2026-07-03]:

```rust
// locally reproduced — same-units addition, unit-changing mul/div, partial sqrt
let x = 3.0 * si::M;
let t = 2.0 * si::S;
println!("x + x = {}", x + x);        // prints: x + x = 6 m
println!("x * t = {}", x * t);        // prints: x * t = 6 m*s
println!("x / t = {}", x / t);        // prints: x / t = 1.5 m*s^-1
let a = 4.0 * si::M2;
println!("sqrt(a) = {}", a.sqrt());   // prints: sqrt(a) = 2 m
let q = 1.0 * cgs::STATC;
println!("statcoulomb = {}", q);      // prints: statcoulomb = 1 cm^1.5*g^0.5*s^-1
```

## Ergonomics & compile-time cost

**Use-site ergonomics are the crate's best feature.** `3.0 * si::M` is about the
lightest quantity-construction syntax any statically-checked system in this survey
offers (only [F#][fsharp]'s literal suffixes `3.0<m>` beat it); `Deref` on `Unitless`
lets dimensionless results flow into plain-`f64` APIs; `Map`/`MapUnsafe` give
explicitly-labelled escape hatches ([`src/traits.rs`][traits] L83–119). Declaring a
whole new system is a single readable block (the `ms` example above is 20 lines
including constants).

**Definition-site ergonomics were fighting 2015-era Rust.** The stable/nightly split
shows the era: scalar interop needs either the `prim!` enumeration of 14 primitive
types or the nightly `oibit` auto-trait; `no_std` needs nightly for `Sqrt`/`Root` and
conversions ([`CHANGELOG.md`][changelog] `0.8.0`); `spec` (specialization) gates the
generated cross-system tests. [`todo.org`][todo] records the endgame the author was
waiting for — "Numerics :: If and when Rust supports numerics and arithmetic in type
signatures, switch to using them instead of typenum. This is almost certainly in the
far future." — i.e. const generics, which stabilized (in `min_const_generics` form)
after the crate's active period and still cannot express the required type-level
arithmetic on stable Rust in 2026.

**Compile-time cost is modest — far lighter than `uom`.** A clean debug build of the
whole dependency graph (`dimensioned` + `typenum` + `generic-array` + `num-traits` +
a demo binary) takes **5.8 s wall / ~0.3 GB peak RSS**, versus 16.1 s / ~1.1 GB for
`uom`'s default SI on the same machine and toolchain [measured locally,
`rustc 1.91.1`, dev profile, 2026-07-03]. Five systems of tens of units generate far
less code than `uom`'s 118-quantity SI stamped out per storage type.

**Maintenance status is the decisive ergonomic fact.** Repository HEAD is `615c908`,
2022-12-09 ("Allow serde without std (#84)"); the last release is `0.8.0`
(2022-04-28). The pinned clone still builds and runs on `rustc 1.91.1` — but with 84
warnings, dominated by the deprecated `generic-array 0.14` pin ("please upgrade to
generic-array 1.x") plus a future-incompatibility warning on the `oibit` auto-trait
syntax [observed locally, 2026-07-03]. Nothing is broken; nothing is moving.

---

## dimensioned vs `uom`: what it pioneered, and why the ecosystem consolidated

What `dimensioned` pioneered, with receipts in the pinned artifacts:

- **The type-level-integer mechanism itself, in Rust.** The crate predates the
  changelog it added in `0.5.0` (2015-12-02), and that release records the pivotal
  move: "Use typenum instead of peano for faster and more complete type-level numbers"
  ([`CHANGELOG.md`][changelog] `0.5.0`, PR [#3][pr3]). `typenum` is co-authored by
  `dimensioned`'s own author (Paho Lurie-Gregg, per the `typenum` crate metadata) —
  the type-level arithmetic library that [`uom`][rust-uom] (`typenum = "1.13"` in its
  `Cargo.toml`) and half the embedded-Rust ecosystem (via `generic-array`) later
  standardized on **was built to serve this crate**. That is the deepest sense in
  which `dimensioned` is the pioneer: `uom` industrialized a mechanism whose
  foundation `dimensioned` created.
- **Whole-system genericity** — the `make_units!`/marker-trait design lets one function
  serve `si`, `cgs`, and user systems ([Checking & inference](#checking--inference)),
  which `uom` still cannot express across `system!` invocations.
- **Breadth over depth** — UCUM as a typed system (unique in this survey's Rust/C++
  cohort) and Gaussian CGS with the sqrt-basis encoding of half-integer dimensions
  ([Dimension representation](#dimension-representation)).

Why consolidation went the other way (all observable in the two pinned clones):

- **Coverage.** `uom` ships 118 SI quantities with vetted conversion factors;
  `dimensioned`'s own generated docs say "Note: this system is incomplete" for
  CGS/MKS ([`src/build/cgs.rs`][cgs-build] L9), and its SI has no torque, no Celsius,
  no kind distinctions.
- **Semantic guard-rails.** `uom`'s `Kind` mechanism, affine temperature pair, and
  `#[repr(transparent)]` ABI guarantee answer exactly the edges this page lists as
  absent ([Expressiveness edges](#expressiveness-edges),
  [Zero-cost story](#zero-cost-story)).
- **Maintenance.** `dimensioned`: last commit 2022-12-09, last release 2022-04-28.
  `uom`: `v0.38.0` released 2026-02-13, with active compile-time work
  ([rust-uom § Ergonomics][rust-uom]). For a dependency whose whole value is
  soundness, a responsive maintainer is a feature.
- **The error-message ceiling.** Both crates emit `typenum` spines, but `uom`'s named
  associated-type bindings (`L = …`) are one notch more decodable than positional
  `TArr` nesting — and neither ever matched what F# or [mp-units][mp-units] print.

---

## Strengths

- **Lightest construction syntax in the Rust cohort** — `3.0 * si::M`, constants for
  every unit and physical constant, `Deref` on dimensionless.
- **True whole-system extensibility** — `make_units!` builds an arbitrary-basis system
  in user code, with formatting, constants, and trait impls included; `uom` has no
  equivalent for non-ISQ-shaped systems.
- **System-polymorphic generics** — `dimensions::Length`/`Time` marker traits +
  `Quot<L, T>` output types let one function serve every system
  ([`examples/readme-example.rs`][example]).
- **Unusual breadth** — SI, UCUM (spec §30–§47 as constants, radian-as-dimension,
  mole-as-count), Gaussian CGS/MKS, FPS; typed cross-system `From` conversions that
  encode the Gaussian unit identification in the exponent arithmetic.
- **The sqrt-basis encoding** — half-integer Gaussian dimensions inside a `ℤ`-only
  exponent engine, with fraction-aware printing; a genuinely clever free-abelian-group
  change of generators.
- **Light to compile** — 5.8 s / 0.3 GB clean versus `uom`'s 16.1 s / 1.1 GB on the
  same toolchain.
- **Still builds in 2026** — the 2022 HEAD compiles and runs correctly on
  `rustc 1.91.1` (verified locally), a testament to the stability of the
  macro + `typenum` substrate.

## Weaknesses

- **Dormant since 2022** — no commit since 2022-12-09, no release since `0.8.0`
  (2022-04-28); deprecated `generic-array 0.14` pin; the ecosystem has moved to
  [`uom`][rust-uom].
- **Worst-in-cohort error messages** — positional `TArr` spines with `typenum` binary
  integers and no names; the README's own "gobbly-guck" admission; no
  `on_unimplemented` rendering ever landed.
- **Integer-only exponents** — the sqrt-basis trick is per-system and design-time; no
  `ℚ`, no ad-hoc fractional dimensions, `sqrt` partial (even exponents only).
- **No affine, no logarithmic, no kinds** — Celsius and decibels explicitly excluded;
  `Becquerel` _is_ `Hertz`; torque _is_ energy; no point/difference distinction.
- **Zero-cost is unguaranteed** — no `#[repr(transparent)]`; the crate's own `unsafe`
  `Index` casts ride on unpromised layout (acknowledged as issue #52).
- **`Rem` accepts mismatched dimensions** — `metres % seconds` compiles, a deliberate
  but unsound corner of the generated ops.
- **Stable/nightly seams** — `oibit`, `spec`, and `no_std` roots all want nightly;
  scalar ops on stable are a closed list of primitives.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                                   | Trade-off                                                                                               |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Type-level `tarr![…]` array of `typenum` integers as phantom `U`  | Works on 2015-era stable Rust; structural identity = dimension equality; spawned `typenum` itself           | Positional, nameless exponents dominate error messages; `ℤ` only                                        |
| One fresh struct per system (`make_units!`), no shared `Quantity` | Whole-system user extensibility; arbitrary base sets; system-local semantics (UCUM radians, CGS sqrt units) | No cross-system dimension object; interop needs hand-written `From` impls per pair                      |
| Base units may be roots (`SqrtCentimeter`)                        | Gaussian half-integer dimensions without leaving `ℤ`                                                        | Basis fixed at design time; every exponent in the system doubles; printing must halve exponents back    |
| Constants (`3.0 * si::M`), units erased at construction           | Minimal construction syntax; steady-state arithmetic is bare scalar ops                                     | Unit identity forgotten (feet vs metres both `Meter`); integer storage cannot hold sub-base values      |
| Marker traits (`dimensions::Length`) for cross-system genericity  | `generic_speed` works over any system — beyond what `uom` can express                                       | Traits are an open, manually-curated list; no kind discipline (one trait per dimension, none per kind)  |
| Ship UCUM alongside SI                                            | Spec-scale breadth; forces the angle/mole questions into the open                                           | UCUM's radian/mole choices conflict with SI's, and the conversion layer must refuse the ambiguous cases |
| No `#[repr(transparent)]`, `unsafe` layout-dependent `Index`      | Predates the attribute's idiomatization; kept the derive list simple                                        | Zero-size erasure is unpromised ABI; acknowledged as "not great" (issue #52)                            |
| Wait for const generics rather than evolve (`todo.org`)           | `typenum` was always meant as a stopgap ("far future" numerics)                                             | The future arrived without generic const arithmetic; the crate stopped instead — dormancy since 2022    |

## Sources

- [paholg/dimensioned — GitHub repository][repo] (pinned locally at
  `$REPOS/rust/dimensioned` @ `615c908`, 2022-12-09 — repository HEAD; shallow clone,
  so branch archaeology beyond HEAD was not possible locally)
- [`src/lib.rs` — crate docs: `SI<V, U>` mechanism, `tarr!` aliases, "typecheck + type-level arithmetic" summary][lib]
- [`src/make_units.rs` — the `make_units!` macro: struct, consts, ops, `Sqrt`/`Root`, `derived!`, `impl_serde!`][make-units]
- [`src/traits.rs` — `Dimensioned`/`Dimensionless`/`Map`/`MapUnsafe`, `Root`/`Sqrt`/`Cbrt`, `NotDim` auto trait][traits]
- [`src/dimensions.rs` — cross-system dimension marker traits + the generic `speed` doc example][dimensions]
- [`src/conversion.rs` — inter-system `From` impls, Gaussian SI→CGS exponent arithmetic, documented asymmetries][conversion]
- [`src/build/mod.rs` + `src/build/{si,ucum,cgs,mks,fps}.rs` — build-script system definitions, sqrt base units, UCUM exclusions, generated tests][build-mod]
- [`src/fmt.rs` — fraction-aware printing for the sqrt-basis systems][fmt] · [`src/array.rs` — type-array → `GenericArray` runtime reflection][array]
- [`README.md` — positioning, generic example, the error-message admission][readme] · [`CHANGELOG.md` — peano→typenum (0.5.0), 0.6.0 rewrite, 0.8.0][changelog] · [`todo.org` — `on_unimplemented` and const-generics aspirations][todo]
- [`examples/readme-example.rs`][example] · [`tests/`][tests] (quickcheck property tests; no compile-fail suite at this SHA)
- [dimensioned on docs.rs][docs] · [crates.io][crate] · [`typenum` crate][typenum] · [Lurie-Gregg, "Dimensioned 0.6" blog post — the 0.6.0 ground-up rewrite][blog]
- Local reproductions (mismatch error, valid ops, statcoulomb formatting, `size_of`,
  build timing): scratch workspace against the pinned clone,
  `rustc 1.91.1` / `cargo 1.91.0`, 2026-07-03
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [free abelian group][fag] · [Kennedy's type system][kennedy] ·
  [torsors & affine quantities][torsor] · [`uom` (Rust)][rust-uom] ·
  [F# units of measure][fsharp] · [`uom-plugin`][uom-plugin] ·
  [`dimensional`][dimensional] · [mp-units][mp-units] · [Au][au] ·
  [Boost.Units][boost] · [Pint][pint] · [Unitful.jl][unitful] ·
  [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone (dimensioned @ 615c908) -->

[repo]: https://github.com/paholg/dimensioned
[lib]: https://github.com/paholg/dimensioned/blob/615c908/src/lib.rs
[make-units]: https://github.com/paholg/dimensioned/blob/615c908/src/make_units.rs
[traits]: https://github.com/paholg/dimensioned/blob/615c908/src/traits.rs
[dimensions]: https://github.com/paholg/dimensioned/blob/615c908/src/dimensions.rs
[conversion]: https://github.com/paholg/dimensioned/blob/615c908/src/conversion.rs
[fmt]: https://github.com/paholg/dimensioned/blob/615c908/src/fmt.rs
[array]: https://github.com/paholg/dimensioned/blob/615c908/src/array.rs
[build-mod]: https://github.com/paholg/dimensioned/blob/615c908/src/build/mod.rs
[si-build]: https://github.com/paholg/dimensioned/blob/615c908/src/build/si.rs
[ucum-build]: https://github.com/paholg/dimensioned/blob/615c908/src/build/ucum.rs
[cgs-build]: https://github.com/paholg/dimensioned/blob/615c908/src/build/cgs.rs
[prefixes]: https://github.com/paholg/dimensioned/blob/615c908/src/f64prefixes.rs
[readme]: https://github.com/paholg/dimensioned/blob/615c908/README.md
[changelog]: https://github.com/paholg/dimensioned/blob/615c908/CHANGELOG.md
[cargo]: https://github.com/paholg/dimensioned/blob/615c908/Cargo.toml
[todo]: https://github.com/paholg/dimensioned/blob/615c908/todo.org
[example]: https://github.com/paholg/dimensioned/blob/615c908/examples/readme-example.rs
[tests]: https://github.com/paholg/dimensioned/tree/615c908/tests
[pr3]: https://github.com/paholg/dimensioned/pull/3

<!-- Official docs & registry -->

[docs]: https://docs.rs/dimensioned/latest/dimensioned/
[crate]: https://crates.io/crates/dimensioned
[typenum]: https://docs.rs/typenum/latest/typenum/
[blog]: https://paholg.com/2017/03/03/dimensioned_0.6/

<!-- Same-tree theory -->

[kennedy]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[rust-uom]: ./rust-uom.md
[fsharp]: ./fsharp-uom.md
[uom-plugin]: ./haskell-uom-plugin.md
[dimensional]: ./haskell-dimensional.md
[mp-units]: ./cpp-mp-units.md
[au]: ./cpp-au.md
[boost]: ./cpp-boost-units.md
[pint]: ./python-pint.md
[unitful]: ./julia-unitful.md
