# Unitful.jl (Julia)

The de-facto standard Julia units library: a `Quantity{T,D,U}` whose dimension and unit parameters are singleton values carrying tuples of `Dimension`/`Unit` structs with **`Rational{Int}` exponents**, so the dimension algebra runs inside `@generated` functions at JIT-specialization time and a mismatch surfaces as a runtime `DimensionError` thrown from a method that multiple dispatch selected — and that the JIT compiled into an unconditional `throw`.

| Field            | Value                                                                                                                                                                                        |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | Julia (≥ 1.6; pure Julia, no compiler extension)                                                                                                                                             |
| License          | MIT "Expat" (copyright California Institute of Technology and contributors)                                                                                                                  |
| Repository       | [JuliaPhysics/Unitful.jl][repo]                                                                                                                                                              |
| Documentation    | [juliaphysics.github.io/Unitful.jl][docs] · in-repo `docs/src/` (Documenter.jl)                                                                                                              |
| Key authors      | Andrew Keller (original author; copyright assigned to Caltech — [`LICENSE.md`][license] L31); maintained by the JuliaPhysics org and contributors                                            |
| Category         | Library-level [dynamic checking][concepts] via multiple dispatch (with JIT specialization doing the work at compile time of each specialization)                                             |
| Mechanism        | `Quantity{T,D,U}` where `D` and `U` are singleton _value_ type parameters wrapping tuples of `isbits` structs (`Dimension{:Length}(1//1)`, `Unit{:Meter, 𝐋}(0, 1//1)`); `@generated` algebra |
| Exponent domain  | `ℚ` — `power::Rational{Int}` per base-dimension symbol, over an **open set** of user-extensible dimension symbols                                                                            |
| Checking time    | Run time (method dispatch); in type-stable code the JIT resolves the check per specialization — matches compile to bare arithmetic, mismatches to an unconditional `throw`                   |
| Analyzed version | `829da44` (pinned clone, 2026-06-22; `Project.toml` version `1.28.0`)                                                                                                                        |
| Latest release   | `v1.28.0` (2026-01-29, [`NEWS.md`][news])                                                                                                                                                    |

> [!NOTE]
> Unitful is this survey's canonical **dynamic-language** data point with a twist: unlike
> [Pint][pint] (a term-level registry, checked value-by-value at run time), Unitful puts
> dimensions and units _into the type_ — Julia types may be parameterized by arbitrary
> `isbits` values, so exponents are literal `Rational{Int}`s at the type level with no
> [`typenum`-style encoding][uom] and no [template normal form][boost]. The JIT then
> specializes every method per concrete quantity type, which is why the run-time-checked
> semantics has a compile-time cost profile — the nuance the
> [mechanism taxonomy][mechanisms] files under "dispatch-time checking". See the
> [comparison capstone][comparison] for the cross-system synthesis.

---

## Overview

### What it solves

Unitful gives Julia programs unit-safe arithmetic, unit conversion, and dimensional
analysis across an _open_, user-extensible set of dimensions, while exploiting Julia's
compilation model so that the safety is (mostly) free in hot loops. The README states
the goals directly ([`README.md`][readme] L9–13):

> "Unitful is a Julia package for physical units. We want to support not only SI units
> but also any other unit system. We also want to minimize or in some cases eliminate
> the run-time penalty of units. There should be facilities for dimensional analysis.
> All of this should integrate easily with the usual mathematical operations and
> collections that are found in Julia base."

The shipped defaults ([`src/pkgdefaults.jl`][pkgdefaults], 829 lines) define the seven
SI base dimensions, ~40 derived dimensions, the SI units with all power-of-ten
prefixes, an assortment of non-SI units (feet, hours, eV, …), affine `°C`/`°F`, and a
logarithmic-unit layer (`dB`, `dBm`, `Np`, …). Everything the defaults use goes through
the same public macros (`@dimension`, `@refunit`, `@unit`, `@affineunit`, `@logscale`)
that downstream packages use, so the SI system has no privileged status.

### Design philosophy

Two decisions define Unitful against the other systems in this survey.

**Offload unit computation to the compiler via staged functions.** The dimensions _and_
units live in the type signature precisely so Julia's `@generated` functions ("staged
functions") can do the group algebra once per concrete type combination rather than
once per operation ([`docs/src/types.md`][types-md]):

> "By putting units in the type signature of a quantity, staged functions can be used
> to offload as much of the unit computation to compile-time as is possible. By also
> having the dimensions explicitly in the type signature, dispatch can be done on
> dimensions: `isa(1u"m", Unitful.Length) == true`."

**Exact rational arithmetic, no eager normalization.** A quantity keeps the unit it was
constructed with (`1u"cm"` stays centimetres; contrast [uom][uom]'s normalize-to-base
storage), and conversion factors are kept as exact `Rational{Int}`s wherever possible —
`uconvert(u"ft", 1u"inch")` is `1//12 ft`, and `uconvert(u"°C", 32u"°F")` is `0//1 °C`
([`docs/src/trouble.md`][trouble-md] explains the choice: "We use rational numbers in
this package to permit exact conversions between different units where possible").

---

## How it works

### The type tower: values as type parameters

Everything rests on Julia's rule that a type parameter may be any `isbits` value — a
`Symbol`, a `Rational{Int}`, an immutable struct of those, or a tuple of such structs
([Julia manual, "Value types"][julia-valuetypes]). Unitful's atoms are two tiny structs
([`src/types.jl`][types] L19–21, L49–52):

```julia
# Unitful.jl: src/types.jl L19-21, L49-52
struct Dimension{D}          # D is a Symbol: :Length, :Time, :Mass, …
    power::Rational{Int}
end

struct Unit{U,D}             # U is a Symbol (:Meter), D a Dimensions object
    tens::Int                # power-of-ten prefix: cm is Unit{:Meter,𝐋}(-2, 1//1)
    power::Rational{Int}
end
```

Tuples of these are the type parameters of the composite singletons
([`src/types.jl`][types] L29, L94, L160–164):

```julia
# Unitful.jl: src/types.jl L29, L94, L160-164 (abridged)
struct Dimensions{N} <: Unitlike end          # N: sorted tuple of Dimension objects
struct FreeUnits{N,D,A} <: Units{N,D,A} end   # N: sorted tuple of Unit objects
struct Quantity{T,D,U} <: AbstractQuantity{T,D,U}
    val::T                                    # the ONE runtime field
end
```

The `FreeUnits` docstring spells out what a familiar unit _is_ under this encoding
([`src/types.jl`][types] L89–92):

> "Example: the unit `m` is actually a singleton of type
> `Unitful.FreeUnits{(Unitful.Unit{:Meter, 𝐋}(0, 1//1),), 𝐋, nothing}`. After dividing
> by `s`, a singleton of type
> `Unitful.FreeUnits{(Unitful.Unit{:Meter, 𝐋}(0, 1//1), Unitful.Unit{:Second, 𝐓}(0, -1//1)), 𝐋/𝐓, nothing}`
> is returned."

Note the asymmetry in `Quantity{T,D,U}`: `D` is a `Dimensions` _instance_ (a singleton
value) while `U` is a `Units` _type_ — and `D` is redundant with `U`. The
`AbstractQuantity` docstring justifies the redundancy ([`src/types.jl`][types]
L146–149): "Of course, the dimensions follow from the units, but the type parameters
are kept separate to permit convenient dispatch on dimensions." That is what makes
`whatsit(x::Unitful.Length)` a legal method signature (see
[Checking & inference](#checking--inference)).

### `@generated` group algebra

Multiplying units (or dimensions) concatenates the operand tuples, sorts them into a
canonical order, and merges powers of identical atoms — all inside a `@generated`
function, so the sort-and-merge runs **once per type combination** at specialization
time and the method body collapses to returning a constant
([`src/dimensions.jl`][dimensions] L25–64, same scheme for units in
[`src/units.jl`][units] L1–54):

```julia
# Unitful.jl: src/dimensions.jl L25-64 (abridged)
@generated function *(a0::Dimensions, a::Dimensions...)
    b = Vector{Dimension}()
    # … collect Dimension objects from the *type parameters* of the operands …
    sort!(b, by=power)
    sort!(b, by=name)
    # … merge equal names, summing powers; drop zero powers …
    d = (c...,)
    :(Dimensions{$d}())        # the whole method body is this constant
end
```

The canonical sort is the [free-abelian-group][fag] normal form made syntactic: two
dimension expressions are equal iff they are the _same type_, so
`typeof(u"𝐋*𝐌/𝐓^2") == typeof(u"𝐌*𝐋/𝐓^2")` holds by construction (the function's own
doctest, [`src/dimensions.jl`][dimensions] L14–23). Division is `x * inv(y)`;
exponentiation multiplies each `power` field by the exponent ([`src/dimensions.jl`][dimensions]
L66–76). Quantity construction runs `dimension(units)` through the same machinery, again
staged ([`src/quantities.jl`][quantities] L3–9).

### `@u_str`, registration, and promotion

`u"m/s"` is a string macro that parses its body as a Julia expression, looks each
symbol up in the registered unit modules, and splices the singleton in **at parse
time** — so `1.0u"m/s"` costs nothing at run time ([`src/user.jl`][user] L629–640;
runtime variant `uparse`, L660–663). `Unitful.register(MyModule)` adds a module to the
lookup list; a name collision emits a warning and prefers the most recently registered
module ([`src/user.jl`][user] L692–719).

Adding quantities with the same dimension but different units goes through Julia's
promotion: the result unit is chosen from the _types only_ — "We can't take runtime
values into account without compromising runtime performance"
([`docs/src/conversion.md`][conversion-md]) — via `promote_unit`, which defaults to the
preferred units of the dimension (SI base units, overridable per dimension by defining
a `promote_unit` method; [`src/promotion.jl`][promotion] L25–26). Three `Units`
subtypes tune this: ordinary `FreeUnits`, `ContextUnits` (carry a preferred promotion
unit in the type), and `FixedUnits` (refuse automatic conversion)
([`src/types.jl`][types] L94–137).

---

## Dimension representation

A dimension is a **sorted tuple of `Dimension{sym}(power)` value-objects used as a type
parameter**, where `power::Rational{Int}` — the type-level exponent domain is literally
`ℚ` (with `Int64` numerator/denominator), not an encoding of it. There is no fixed
base-dimension vector: the tuple holds only the dimensions with non-zero power, and the
set of dimension symbols is **open** — `@dimension` mints a new `Symbol` and a new
generator of the group at any time ([`src/user.jl`][user] L62–109). Dimensionless is
the empty tuple: `const NoDims = Dimensions{()}()` ([`src/types.jl`][types] L32).

Three consequences are worth naming:

- **Rational powers are native.** `sqrt` on dimensions maps each power through
  `p * 1//2` inside a `@generated` function kept type-stable by construction
  ([`src/dimensions.jl`][dimensions] L86–93); `𝐋^(1//2)` is as representable as `𝐋²`.
  The theory hook: because Julia type parameters carry arbitrary `isbits` values, the
  free abelian group over `ℚ` (a `ℚ`-vector space on an open generator set — see
  [free abelian group][fag]) is represented _directly_, where static-language systems
  must encode it ([`typenum` binary integers][uom], [template packs][boost],
  [type-level `TypeInt`][dimensional]). Arbitrary _real_ exponents are deliberately
  excluded ([`docs/src/types.md`][types-md]): "Fields of a `Unit` object keep track of
  a rational exponents and a power-of-ten prefix. We don't allow arbitrary floating
  point exponents of units because they probably aren't very useful."
- **Units are a parallel, finer group.** The `Units{N,D,A}` tuple keeps distinct units
  _and distinct prefixes_ apart (`cm ≠ m`; the `@generated *` merges only exact
  name+prefix matches, [`src/units.jl`][units] L33), with the dimension recomputed and
  stored alongside. Quantities therefore remember their units exactly — conversion
  happens at explicit `uconvert`/promotion boundaries, with factors computed in a
  `@generated convfact` that returns an exact rational constant when it can
  ([`src/conversion.jl`][conversion] L5–41).
- **Normal form is type identity, made by sorting.** As in [uom][uom]'s trait-object
  dimensions, structural equality is literal type equality — but here the
  normalization is a plain `sort!` over value-objects in a staged function, not a
  trait-solver evaluation. The docs warn that hand-built (unsorted) `Units` tuples
  break comparisons, and that the unary `*` re-canonicalizes
  ([`docs/src/newunits.md`][newunits-md]).

## Checking & inference

All checking is **method dispatch over the `D` parameter**. Addition is a three-rung
method ladder ([`src/quantities.jl`][quantities] L129–139):

```julia
# Unitful.jl: src/quantities.jl L129-139 (abridged)
for op in [:+, :-]
    # same dimension AND same units: add the raw values
    @eval ($op)(x::AbstractQuantity{S,D,U}, y::AbstractQuantity{T,D,U}) where {S,T,D,U} =
        Quantity(($op)(x.val, y.val), U())
    # same dimension, different units: promote (unit-convert), then retry
    @eval function ($op)(x::AbstractQuantity{S,D,SU}, y::AbstractQuantity{T,D,TU}) where {S,T,D,SU,TU}
        ($op)(promote(x,y)...)
    end
    # anything else: the dimensions differ
    @eval ($op)(x::AbstractQuantity, y::AbstractQuantity) = throw(DimensionError(x,y))
end
```

Julia selects the most specific applicable method; only a genuine dimension mismatch
falls through to the `throw`. The same pattern guards comparisons
([`src/quantities.jl`][quantities] L247), `uconvert` ([`src/conversion.jl`][conversion]
L96–112), promotion ([`src/promotion.jl`][promotion] L57), and ranges.

**The JIT nuance.** Semantically this is a run-time check — but Julia compiles a fresh
specialization of every method per concrete argument types, and in a specialization
the `D` parameters are known constants. So for matching dimensions the check _does not
exist_ in the generated code, and for mismatched dimensions the entire compiled body
is an unconditional call to the throwing method (see [Zero-cost story](#zero-cost-story)
for the LLVM). The comment above the `fma` implementation records the library's own
observation ([`src/quantities.jl`][quantities] L193–195):

> "It seems like most of this is optimized out by the compiler, including the apparent
> runtime check of dimensions, which does not appear in `@code_llvm`."

What is _not_ provided is any static rejection: a dimensionally absurd expression on a
never-executed path is never reported, there is no whole-program analysis, and nothing
plays the role of [Kennedy's][kennedy] principal types or [F#][fsharp]'s
AG-unification. Julia's inference only propagates _forward_ from concrete types.

**Dimensional polymorphism is free — but unchecked.** A generic `sqr : α → α²` needs no
declaration at all; duck typing plus specialization give it dimension-correct concrete
types per call site, verified locally against the pinned clone:

```julia
# locally reproduced [Julia 1.12.4, 2026-07-03] — dimension polymorphism for free
sqr(x) = x * x
sqr(3.0u"m")                    # 9.0 m^2
sqr(2.0u"s")                    # 4.0 s^2
@inferred sqr(3.0u"m")          # passes: return type Quantity{Float64, 𝐋^2, …} inferred
```

The flip side: `sqr`'s dimension behaviour is a fact about its body, not a checkable
contract — there is no way to _state_ `α → α²` and have anything verify it. The
closest to a checked signature is dispatching on dimension aliases: `@dimension` and
`@derived_dimension` emit abstract type aliases (`Unitful.Length`, `Unitful.Velocity`,
…) so `f(x::Unitful.Length)` constrains an argument's dimension (but not the unit or
number type) — the [`docs/src/highlights.md`][highlights-md] `whatsit` example,
reproduced locally.

## Extensibility

Extension is the same macro suite the package itself uses, tiered by ambition
([`src/user.jl`][user]):

- **A new unit of an existing dimension — one line.** `@unit` takes "a `Quantity`
  equal to one of the unit being defined": `@unit mi "mi" Mile (201168//125)*m false`
  ([`src/user.jl`][user] L234–250). With `tf=true` all SI prefixes are stamped out
  too. The docs show minting units at the REPL (`@unit M "M" Molar 1u"mol/L" true`
  then `1u"mM"` just works — [`docs/src/newunits.md`][newunits-md]).
- **A new base dimension — two lines.** `@dimension` creates the `Dimensions`
  singleton, the display rule, and the dispatch aliases; `@refunit` anchors a
  reference unit for it and registers it for promotion
  ([`src/user.jl`][user] L62–109, L173–231). Locally reproduced against the pinned
  clone [Julia 1.12.4, 2026-07-03]:

  ```julia
  # locally reproduced — a new base dimension, its reference unit, a derived unit
  module Pirates
      using Unitful
      @dimension 𝐁 "𝐁" Booty
      @refunit doubloon "doubloon" Doubloon 𝐁 false
      @unit chest "chest" Chest 100doubloon false
  end
  Unitful.register(Pirates)

  3u"chest" + 50u"doubloon"   # 350 doubloon  ::  Quantity{Int64, 𝐁, FreeUnits{(doubloon,), 𝐁, nothing}}
  1u"doubloon" + 1u"m"        # DimensionError: 1 doubloon and 1 m are not dimensionally compatible.
  ```

- **A units _package_.** The blessed pattern is a module calling `Unitful.register` in
  its `__init__` (plus a `merge!(Unitful.promotion, localpromotion)` when new
  dimensions are involved — a precompilation subtlety the docs walk through,
  [`docs/src/extending.md`][extending-md]). The ecosystem is broad:
  [`UnitfulUS.jl`][unitful-us] (cited by the docs as the reference example),
  `UnitfulAstro.jl`, `UnitfulAtomic.jl`, [`DimensionfulAngles.jl`][dimensionful-angles]
  (adds angle as a dimension), [`UnitfulBuckinghamPi.jl`][unitful-bpi] (solves for the
  dimensionless `Π` groups of the [Buckingham-Pi theorem][buckingham] over Unitful
  parameters) — [`README.md`][readme] L20–40.
- **Scoping and interop.** All registered systems share one global dimension algebra —
  two packages' units interoperate iff their dimensions match. Deliberately
  _non-convertible_ systems are possible by minting look-alike dimensions
  ([`docs/src/extending.md`][extending-md]): "The trick is to define dimensions that
  display suggestively like physical dimensions, like `𝐋*`, `𝐓*` etc., but are
  distinct as far as Julia's type system is concerned." The costs of openness: unit
  symbols are matched by `Symbol`, so two packages defining `myMeter` collide in
  dispatch ([`docs/src/extending.md`][extending-md], "Type uniqueness"), and `@u_str`
  warns and picks the most recently registered on name clashes.

## Expressiveness edges

- **Fractional powers: present and first-class.** `sqrt`/`cbrt` are staged to map
  powers through `1//2`/`1//3` ([`src/dimensions.jl`][dimensions] L86–93,
  [`src/units.jl`][units] L152–178), and the `V/√Hz` noise-density idiom that
  [`ℤ`-exponent systems][uom] cannot write is a documented highlight
  ([`docs/src/highlights.md`][highlights-md]) — locally reproduced:
  `1.0u"V/sqrt(Hz)"` prints `1.0 V Hz^-1/2`, with type
  `Quantity{Float64, 𝐋^2 𝐌 𝐈^-1 𝐓^-5/2, …}`. Only arbitrary-real exponents are
  excluded by design ([`docs/src/types.md`][types-md]).
- **Affine quantities: a general mechanism, policed operation-by-operation.** The
  third `Units` parameter `A` is `Affine{T}` (offset in the type) or `nothing`
  ([`src/types.jl`][types] L63–73). `@affineunit °C "°C" (27315//100)K` defines
  Celsius; Fahrenheit chains through Rankine
  ([`src/pkgdefaults.jl`][pkgdefaults] L267, L624–630). Conversion applies the
  translation in a staged `uconvert_affine` ([`src/conversion.jl`][conversion]
  L116–130). The [torsor discipline][torsor] is enforced by _banning_ the meaningless
  operations with `AffineError`: point + point, scalar × point, and powers of affine
  units all throw ([`src/quantities.jl`][quantities] L158–159, L32–41;
  [`src/units.jl`][units] L114–117), while point − point returns the absolute-scale
  interval — locally reproduced: `25u"°C" - 20u"°C"` is `5 K`, and
  `uconvert(u"°C", 32u"°F")` is exactly `0//1 °C`. The rationale is stated in
  [`docs/src/temperature.md`][temperature-md]: "problems can arise because e.g.
  `0°C + 0°C` could mean `0°C` or `273.15°C`, depending on whether the operands are
  variously interpreted as temperature differences or as absolute temperatures."
  Unlike [uom][uom]'s temperature-only torsor, `@affineunit` works for any dimension —
  but there is no general point-type machinery either (no position/displacement pair;
  contrast [Au][au]'s `QuantityPoint` and [mp-units][mp-units]' `quantity_point`).
- **Logarithmic quantities: present — rare in this survey.** `@logscale`/`@logunit`
  define `dB`, `B`, `Np`, `cNp` and referenced levels `dBm`, `dBV`, `dBSPL`, …
  ([`src/pkgdefaults.jl`][pkgdefaults] L689–702), built on `Level` (value stored
  linearly, reference in the type) vs `Gain` (value stored post-logarithm) vs
  `MixedUnits` like `dBm/Hz` ([`src/types.jl`][types] L229–280;
  [`src/logarithm.jl`][logarithm]). `uconvert(u"mW*s", 20u"dBm/Hz")` is a doctest
  ([`docs/src/highlights.md`][highlights-md]). The docs are candid that the layer
  "should be considered experimental because they break some of the basic assumptions
  about equality and hashing" ([`docs/src/logarithm.md`][logarithm-md], issue
  [#402][issue402]). Among this survey's systems only [Pint][pint] matches this.
- **Angles: dimensionless, faithfully SI — and therefore erased.** `rad`, `°`, `sr`
  are units of `NoDims` ([`src/pkgdefaults.jl`][pkgdefaults] L102–111);
  `π/2*u"rad" + 90u"°" ≈ π` yields a _pure number_ ([`docs/src/trouble.md`][trouble-md]).
  The docs acknowledge the cost: "`μm/m` and `rad` are both dimensionless units, but
  kind of have nothing to do with each other. It would be a little weird to add them.
  Nonetheless, we permit this to happen since they have the same dimensions." The
  ecosystem remedy is [`DimensionfulAngles.jl`][dimensionful-angles], which mints angle
  as a `@dimension` — possible precisely because the generator set is open.
- **Kind-vs-dimension: absent — an explicit finding.** There is no kind/quantity-spec
  layer at all. `Hz` and `Bq` are both defined as `1/s`
  ([`src/pkgdefaults.jl`][pkgdefaults] L135, L210) and add freely after promotion;
  torque and energy are indistinguishable, and the conversion docs even showcase the
  conflation as a feature — `uconvert(u"J", 1.0u"N*m")`, "You can use this method to
  switch between equivalent representations of the same unit, like `N m` and `J`"
  ([`src/conversion.jl`][conversion] L80–95). Contrast [uom][uom]'s `Kind` tag and
  [mp-units][mp-units]' quantity-spec hierarchy.
- **Mixed-dimension collections: representable, at a cost.** Arrays of same-typed
  quantities are stored unboxed ("stored efficiently in memory",
  [`docs/src/highlights.md`][highlights-md]); heterogeneous-dimension arrays fall back
  to an abstract element type with a documented "performance penalty" — the highlights
  even show a general-relativity `Diagonal([-1.0u"c^2", 1.0, 1.0, 1.0])`, this
  survey's only stdlib-integrated brush with [Hart's dimensioned matrices][hart].

## Zero-cost story

The claim is the README's "minimize or in some cases eliminate the run-time penalty"
— and here the erasure evidence is _generated machine code_, obtained locally against
the pinned clone [reproduced locally, Julia 1.12.4 (nixpkgs `julia-bin`), 2026-07-03]:

- **A quantity is its scalar.** `isbitstype(typeof(1.0u"m"))` is `true` and
  `sizeof` is 8 bytes — `Dimensions`/`FreeUnits` singletons occupy no storage; the
  one field is `val::T` ([`src/types.jl`][types] L160–164).
- **Same-unit addition is one `fadd`.** `@code_llvm` for
  `add(a,b) = a + b` at `(typeof(1.0u"m"), typeof(1.0u"m"))`:

  ```llvm
  ; locally reproduced — add(1.0u"m", 2.0u"m"), function body in full
  top:
    %"a::Quantity.unbox" = load double, ptr %"a::Quantity", align 8
    %"b::Quantity.unbox" = load double, ptr %"b::Quantity", align 8
    %0 = fadd double %"a::Quantity.unbox", %"b::Quantity.unbox"
    %"new::Quantity.unbox.fca.0.insert" = insertvalue [1 x double] zeroinitializer, double %0, 0
    ret [1 x double] %"new::Quantity.unbox.fca.0.insert"
  ```

- **Mixed-unit addition folds the conversion factor to a literal.** For
  `add(1.0u"m", 2.0u"km")` the promotion machinery and the staged
  `convfact` ([`src/conversion.jl`][conversion] L5–41) leave exactly one extra
  instruction: `%0 = fmul double %"b::Quantity.unbox", 1.000000e+03` before the
  `fadd`. The factor is computed at specialization time and baked in.
- **A mismatched addition compiles to an unconditional throw.** For
  `add(1.0u"m", 1.0u"s")` the entire specialized body is a `noreturn` call into the
  throwing `+` method followed by `unreachable` — the "runtime check" has been
  resolved statically; only the failure path was emitted. This is the precise sense
  in which a dynamic library gets compile-time-shaped behaviour.
- **The library's own evidence** is the `fma` comment quoted
  [above](#checking--inference) ([`src/quantities.jl`][quantities] L193–195) and the
  staged-function design statement in [`docs/src/types.md`][types-md].

The documented exception is **exponentiation by a runtime value**
([`docs/src/trouble.md`][trouble-md]):

> "Most operations with this package should in principle suffer little performance
> penalty if any at run time. An exception to this is rule is exponentiation. Since
> units and their powers are encoded in the type signature of a `Quantity` object,
> raising a `Quantity` to some power, which is just some run-time value, necessarily
> results in different result types."

`x^2` with a _literal_ exponent stays type-stable via `Base.literal_pow` lowering
(staged overloads in [`src/dimensions.jl`][dimensions] L78–81 and
[`src/units.jl`][units] L133–147; Julia PR [#20530][pr20530]), and `inv`/`sqrt`/`cbrt`
are staged for the same reason — but `x^p` with runtime `p` returns a type the
compiler cannot predict. Locally verified: `@inferred powp(3.0u"m", 2)` for
`powp(x, p) = x^p` fails with "inferred return type `Any`". In a hot loop such an
instability forces dynamic dispatch and boxing — the zero-cost story holds **only in
type-stable code**, which is the standard Julia performance contract rather than a
Unitful-specific caveat.

## Diagnostics

The mandated experiment — adding metres to seconds — run against the pinned clone via
`Pkg.develop(path=…)` [reproduced locally, Julia 1.12.4 (nixpkgs `julia-bin`),
2026-07-03]:

```julia
# locally reproduced — mismatch.jl
1u"m" + 1u"s"
```

```text
DimensionError: 1 m and 1 s are not dimensionally compatible.

Stacktrace:
 [1] +(x::Quantity{Int64, 𝐋, Unitful.FreeUnits{(m,), 𝐋, nothing}}, y::Quantity{Int64, 𝐓, Unitful.FreeUnits{(s,), 𝐓, nothing}})
   @ Unitful ~/code/repos/julia/Unitful.jl/src/quantities.jl:137
 [2] top-level scope
```

The first line is the survey's most human-readable mismatch message: it prints the
_offending values with their units_ in domain language ("1 m and 1 s"), because
`DimensionError` simply stores both operands and `showerror` formats them
([`src/utils.jl`][utils] L248–254):

```julia
# Unitful.jl: src/utils.jl L248-254
struct DimensionError <: Exception
    x
    y
end

Base.showerror(io::IO, e::DimensionError) =
    print(io, "DimensionError: $(e.x) and $(e.y) are not dimensionally compatible.");
```

The stacktrace's method signature does expose the type-level encoding
(`Quantity{Int64, 𝐋, Unitful.FreeUnits{(m,), 𝐋, nothing}}`), but even that stays close
to notation a physicist reads. The affine counterpart is equally direct — locally
reproduced: `25u"°C" + 5u"°C"` throws
`AffineError: an invalid operation was attempted with affine quantities: 25 °C + 5 °C`.

As rung-2 corroboration, the pinned clone's own test suite pins these expectations:
`@test_throws DimensionError 1+1m` and `@test_throws DimensionError 1-1m`
([`test/runtests.jl`][runtests] L751–752), `@test_throws DimensionError 1m < 1kg`
(L720), `@test_throws DimensionError uconvert(m, 1kg)` (L253) — 145 `@test_throws`
cases in all.

The structural weakness is _when_, not _what_: the error exists only on executed
paths. A unit bug in an uncalled branch, or one only reachable with rare inputs, ships
silently — the trade every dynamically checked system in this survey makes
([Pint][pint] included), softened here by the fact that a test that _does_ execute the
path fails loudly and cheaply.

## Ergonomics & compile-time cost

**Declaration overhead is the lowest in the survey.** Using the defaults is
`using Unitful` plus `u"…"` literals; a new unit is one macro line; a new base
dimension plus reference unit is two (the `Pirates` example above). No trait bounds,
no template specializations, no registry files. Units are deliberately _not exported_
— retrieved via `@u_str`, explicit `import`, or `using Unitful.DefaultSymbols`
([`docs/src/index.md`][index-md], "Important note on namespaces") — so the 1000-odd
generated symbols don't flood namespaces, at the cost of `u"…"` noise in user code.

**Error readability is excellent** (values-with-units, above); the pain point is
instead _type display_ in stacktraces and REPL introspection once units compound
(`Unitful.FreeUnits{(m, s^-1), 𝐋 𝐓^-1, nothing}` is still readable; deep composites
less so), plus a documented terminal-font gotcha rendering the bold dimension
characters `𝐋`, `𝐌` as boxes ([`docs/src/trouble.md`][trouble-md]).

**The compile-time cost is JIT latency, paid per specialization.** Measured locally on
2026-07-03 (Julia 1.12.4): precompiling Unitful `v1.28.0` from the pinned clone takes
**~10.5 s** once per environment (`10503.7 ms ✓ Unitful` in the `Pkg` output); after
that, every _new_ combination of quantity types at a call site triggers method
specialization and `@generated`-function expansion at first execution — small
individually, but it is the same time-to-first-x tax as the rest of Julia, and unit
diversity multiplies specializations (a length in `m` and a length in `km` are
distinct concrete types, each compiling its own methods). Nothing here approaches the
wall-clock of C++
[template-instantiation][boost] builds; the cost is smeared across first-run latency
instead of the build.

Two further ergonomic notes from the docs: exact `Rational` results surprise newcomers
(`1inch != 2.54cm` — literally, since `2.54 != 254//100`; use `≈`,
[`docs/src/trouble.md`][trouble-md]), and `u"N m"` fails to parse where `u"N*m"`
works, because `@u_str` bodies must be valid Julia expressions
([`src/user.jl`][user] L607–609).

---

## Strengths

- **Type-level `ℚ` exponents with zero encoding overhead** — `Rational{Int}` values
  sit directly in type parameters; `sqrt` is total, `V/√Hz` is writable, and the
  dimension algebra is ordinary Julia code in `@generated` functions rather than
  trait/template metaprogramming.
- **Open dimension set** — `@dimension` mints new base dimensions at any time
  (currency, booty, angle-as-dimension), the capability [closed-vector systems][uom]
  structurally lack; the ecosystem exercises it (`DimensionfulAngles`, `UnitfulMoles`).
- **Measured zero-cost hot path** — `isbits` quantities, one `fadd` for same-unit
  addition, constant-folded conversion factors, and dimension checks that compile away
  (or into bare `throw`s), all verified at the LLVM level.
- **Best-in-class mismatch message** — `DimensionError: 1 m and 1 s are not
dimensionally compatible`, values and units in domain language.
- **Honest affine and logarithmic layers** — general `@affineunit` machinery with
  `AffineError`-policed torsor semantics; `dB`/`Np` levels and gains that only
  [Pint][pint] rivals in this survey.
- **Exact rational conversions** — `1//12 ft`, `0//1 °C`; no eager-normalization
  precision loss, unit identity preserved through arithmetic.
- **Dispatch on dimensions** — `f(x::Unitful.Length)` as a method constraint is a
  genuinely pleasant middle ground between no checking and full static typing.

## Weaknesses

- **No static guarantee** — checks fire only on executed paths; dead-code unit bugs
  survive until run (or test) time. The JIT compiles the check away but never _reports_
  it ahead of execution.
- **No kind system** — `Hz` vs `Bq`, torque vs energy, `rad` vs `μm/m` are
  indistinguishable once dimensions agree; angle erases to pure number under addition
  with other dimensionless quantities.
- **Runtime-exponent type instability** — `x^p` for non-literal `p` returns `Any`-inferred
  types; performance (not soundness) silently degrades in hot loops, the library's own
  documented exception to its performance story.
- **Dimensional contracts are not checkable** — generic code is dimension-polymorphic
  by duck typing, but no `α → α²` signature can be stated and verified; no inference
  in the [Kennedy][kennedy] sense.
- **Global, symbol-keyed registration** — unit-name collisions across packages degrade
  to warnings and most-recent-wins; precompilation of extension packages needs the
  documented `__init__`/promotion-merge incantations.
- **JIT specialization tax** — per-type-combination compilation latency and code-size
  growth with unit diversity; heterogeneous-unit arrays fall off the fast path
  entirely.
- **Logarithmic layer self-declared experimental** — equality/hashing assumptions
  break ([#402][issue402]).

## Key design decisions and trade-offs

| Decision                                                               | Rationale                                                                                              | Trade-off                                                                                                          |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| Exponents as `Rational{Int}` values inside type parameters             | Julia types carry arbitrary `isbits` values → native `ℚ` powers, total `sqrt`, no encoding layer       | Exponentiation by runtime values is type-unstable; type-level values are a Julia-only trick, not portable          |
| Both `D` (dimensions) and `U` (units) in `Quantity{T,D,U}`             | Dispatch on dimension (`Unitful.Length`) without fixing units; promotion decided from types alone      | Redundant parameters to keep consistent; long type names in stacktraces                                            |
| Checking = multiple dispatch, fallback method throws                   | Zero checking machinery; JIT specialization erases the check or reduces it to an unconditional `throw` | Runtime-only detection; no report for unexecuted paths; soundness rests on method-ladder completeness              |
| `@generated` functions for group algebra and conversion factors        | Sort/merge and `convfact` run once per type combination; bodies collapse to constants                  | First-call compilation latency; generated-function restrictions; opaque to naive step-through debugging            |
| Keep units in the type, convert only at explicit boundaries            | Exact rational conversions (`1//12 ft`); no normalization precision loss; unit identity preserved      | `m + km` needs promotion machinery (`FreeUnits`/`ContextUnits`/`FixedUnits` trichotomy); more specializations      |
| Affine offsets in the type parameter `A`, ops banned via `AffineError` | General torsor-ish safety for any dimension's relative scales (`°C`, `°F`)                             | Meaningless ops must be enumerated and banned one method at a time; no general point/vector quantity pair          |
| Angle dimensionless, no kinds (SI-faithful)                            | Matches the SI/[VIM][concepts] stance; keeps the group algebra pure                                    | `rad` erasure, `Hz` = `Bq`, torque = energy; kind distinctions delegated to ecosystem forks (`DimensionfulAngles`) |
| Units unexported, `@u_str` + explicit registration                     | No namespace pollution from ~1000 generated symbols; parse-time unit lookup is free at run time        | `u"…"` syntax everywhere; symbol collisions across registered modules warn and pick most-recent                    |

## Sources

- [JuliaPhysics/Unitful.jl — GitHub repository][repo] (pinned locally at
  `$REPOS/julia/Unitful.jl` @ `829da44`, 2026-06-22; version `1.28.0`)
- [`src/types.jl` — `Dimension`/`Unit`/`Dimensions`/`Units`/`Quantity`, affine and log-scale types][types]
- [`src/dimensions.jl` — `@generated` dimension algebra, rational powers, `literal_pow`][dimensions]
- [`src/units.jl` — unit-tuple algebra, affine guards, `basefactor`][units]
- [`src/quantities.jl` — arithmetic method ladders, `DimensionError` fallbacks, affine ops, the `@code_llvm` comment][quantities]
- [`src/user.jl` — `@dimension`, `@refunit`, `@unit`, `@affineunit`, `@logscale`, `@u_str`, `register`][user]
- [`src/conversion.jl` — staged `convfact`, `uconvert`, `uconvert_affine`][conversion] · [`src/promotion.jl` — `promote_unit`][promotion] · [`src/utils.jl` — `DimensionError`/`AffineError`][utils]
- [`src/pkgdefaults.jl` — SI dimensions/units, `°C`/`°F`, `Hz`/`Bq`, `dB` scales][pkgdefaults] · [`src/logarithm.jl`][logarithm]
- [`docs/src/types.md` — staged-function design statement][types-md] · [`docs/src/highlights.md`][highlights-md] · [`docs/src/temperature.md`][temperature-md] · [`docs/src/trouble.md`][trouble-md] · [`docs/src/extending.md`][extending-md] · [`docs/src/newunits.md`][newunits-md] · [`docs/src/conversion.md`][conversion-md] · [`docs/src/logarithm.md`][logarithm-md] · [`docs/src/index.md`][index-md]
- [`README.md` — goals, ecosystem package list][readme] · [`NEWS.md` — release history][news] · [`LICENSE.md` — authorship][license] · [`test/runtests.jl` — `DimensionError` expectations][runtests]
- [Julia manual — "Value types"][julia-valuetypes] · [Generated functions][julia-generated] · [Julia PR #20530 — `literal_pow` lowering][pr20530]
- Local reproductions (mismatch error, LLVM excerpts, custom dimension, affine ops,
  `@inferred` checks, precompile timing): scratch workspace against the pinned clone
  via `Pkg.develop`, Julia 1.12.4 (nixpkgs `julia-bin`), 2026-07-03
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [free abelian group][fag] · [Kennedy's type system][kennedy] ·
  [torsors & affine quantities][torsor] · [Buckingham-Pi][buckingham] ·
  [Hart's multidimensional analysis][hart] · [Pint][pint] · [F# units of measure][fsharp] ·
  [`uom`][uom] · [`dimensioned`][dimensioned] · [`dimensional`][dimensional] ·
  [mp-units][mp-units] · [Au][au] · [Boost.Units][boost] ·
  [the comparison capstone][comparison]

<!-- References -->

<!-- Pinned clone (Unitful.jl @ 829da44) -->

[repo]: https://github.com/JuliaPhysics/Unitful.jl
[types]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/src/types.jl
[dimensions]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/src/dimensions.jl
[units]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/src/units.jl
[quantities]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/src/quantities.jl
[user]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/src/user.jl
[conversion]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/src/conversion.jl
[promotion]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/src/promotion.jl
[utils]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/src/utils.jl
[pkgdefaults]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/src/pkgdefaults.jl
[logarithm]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/src/logarithm.jl
[readme]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/README.md
[news]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/NEWS.md
[license]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/LICENSE.md
[runtests]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/test/runtests.jl
[types-md]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/docs/src/types.md
[highlights-md]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/docs/src/highlights.md
[temperature-md]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/docs/src/temperature.md
[trouble-md]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/docs/src/trouble.md
[extending-md]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/docs/src/extending.md
[newunits-md]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/docs/src/newunits.md
[conversion-md]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/docs/src/conversion.md
[logarithm-md]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/docs/src/logarithm.md
[index-md]: https://github.com/JuliaPhysics/Unitful.jl/blob/829da449919e7edda1403cfcf2dda3157b4955d2/docs/src/index.md

<!-- Official docs, issues & ecosystem -->

[docs]: https://juliaphysics.github.io/Unitful.jl/stable/
[issue402]: https://github.com/JuliaPhysics/Unitful.jl/issues/402
[unitful-us]: https://github.com/PainterQubits/UnitfulUS.jl
[dimensionful-angles]: https://github.com/JuliaOceanWaves/DimensionfulAngles.jl
[unitful-bpi]: https://github.com/rmsrosa/UnitfulBuckinghamPi.jl

<!-- Julia language references -->

[julia-valuetypes]: https://docs.julialang.org/en/v1/manual/types/#%22Value-types%22
[julia-generated]: https://docs.julialang.org/en/v1/manual/metaprogramming/#Generated-functions
[pr20530]: https://github.com/JuliaLang/julia/pull/20530

<!-- Same-tree theory -->

[kennedy]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md
[buckingham]: ./theory/buckingham-pi.md
[hart]: ./theory/hart-multidimensional.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[pint]: ./python-pint.md
[fsharp]: ./fsharp-uom.md
[uom]: ./rust-uom.md
[dimensioned]: ./rust-dimensioned.md
[dimensional]: ./haskell-dimensional.md
[mp-units]: ./cpp-mp-units.md
[au]: ./cpp-au.md
[boost]: ./cpp-boost-units.md
