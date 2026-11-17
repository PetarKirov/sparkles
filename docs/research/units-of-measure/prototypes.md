# Prototype evaluation — the thirteen D probes

The [`examples/`](#sources) tree holds thirteen runnable, CI-verified D programs. Each
isolates **one** design decision for a future Sparkles units library and proves it end to
end — the intended compile-time failures are turned into passing
`static assert(!__traits(compiles, …))` checks, so every program compiles, runs, and is
exercised by `dub run :ci -- examples standalone` on each pass. This page evaluates them side
by side across a fixed set of axes and ends with what a Sparkles library should take from
each, mapped to the [comparison capstone][comparison]'s open decisions.

**Last reviewed:** July 5, 2026

## The shared spine

Twelve of the thirteen share one skeleton, so the comparison is really about where each
_departs_ from it:

- a dimension is a compile-time value — a `struct Dim` of integer (or `Rational`) exponents
  passed as a **template value parameter**, its own unique normal form;
- `combine(a, b, sign)` is the free-abelian-group operation (multiply / divide);
- arithmetic is `opBinary` + `mixin`, with `+`/`-` confined to one grade and `*`/`/` total;
- a CTFE `unitString` renders the label;
- cross-dimension misuse is rejected by `static assert(!__traits(compiles, …))`.

Every core is `@safe pure nothrow @nogc`. The single structural outlier is
[`quantity-runtime-expected.d`][ex-runtime], which moves the dimension into a **runtime**
field. Read [`quantity-zn-graded.d`][ex-z] first; the others are diffs against it.

## Evaluation axes

- **Representation** — how a dimension is encoded, its exponent domain, and its basis.
- **Checking & cost** — when a mismatch is caught, and what a quantity costs at run time.
- **Extensibility** — how a _new_ dimension or unit is introduced (the most
  library-relevant axis, and the one that cuts the field most cleanly).
- **Integration** — how the approach composes with `sparkles:math`'s `Vector`.
- **Capability fingerprint** — the expressiveness features (fractional powers, affine,
  kind, logarithmic, engineered diagnostics, generic polymorphism). This grid is **sparse
  by design**: each prototype deliberately owns ~one capability, and the empty cells are the
  point — they map the design space by _division of labour_, not by each probe doing
  everything.

Near-constant properties are left to the prose: **dependencies** track the Vector column
(anything touching `Vector` pulls `sparkles:math`); **attribute discipline** is uniform
(`@safe pure nothrow @nogc`); size and the shared D features (CTFE, template value
parameters, `opBinary`, `mixin`) carry no signal — only the _distinctive_ feature per file
does.

## At-a-glance

| Prototype                                   | Models (system · theory)                    | Dimension encoding                           | Exponent · basis  | Checked                   | Runtime cost                 | A new dimension is added by             | `Vector` composition                          |
| ------------------------------------------- | ------------------------------------------- | -------------------------------------------- | ----------------- | ------------------------- | ---------------------------- | --------------------------------------- | --------------------------------------------- |
| [`quantity-zn-graded`][ex-z]                | [free abelian group][fag]                   | `Dim` value parameter                        | `ℤ³` · closed     | compile                   | erased (bare `double`)       | editing the central `Dim`               | scalar (n/a)                                  |
| [`quantity-rational-exponents`][ex-q]       | [mechanisms][mech] (fractional)             | `Dim{Rational …}` value parameter            | `ℚ³` gcd · closed | compile                   | erased                       | editing the central `Dim`               | scalar (n/a)                                  |
| [`quantity-erasure`][ex-e]                  | [mechanisms][mech] (erasure theorem)        | `Dim` value parameter                        | `ℤ³` · closed     | compile                   | **erased — layout-proven**¹  | editing the central `Dim`               | scalar (n/a)                                  |
| [`quantity-affine-torsor`][ex-affine]       | [torsor][torsor] · [Swift][swift]           | `Quantity!(dim, Payload)`                    | `ℤ³` · closed     | compile²                  | `Vec3` payload               | editing the central `Dim`               | **ordering A** (real `Vector`)                |
| [`quantity-kind-tags`][ex-kind]             | [uom][rust-uom] · §kinds                    | `Quantity!(dim, Kind, Payload)`              | `ℤ⁴` · closed     | compile                   | erased                       | central `Dim` + a `Kind` enum           | A-ready (`Payload` param)                     |
| [`quantity-nominal`][ex-nominal]            | [squants][squants] · [Swift][swift]         | **one struct per quantity**                  | none (nominal)    | compile                   | erased / `Vec3`              | **a new struct + wiring every product** | **bespoke struct per quantity**³              |
| [`quantity-runtime-expected`][ex-runtime]   | [Pint][pint] · [UCUM/QUDT][ucum]            | **runtime `Dim` field**                      | `ℤ⁴` runtime int  | **runtime — `Expected`**⁴ | **carries a `Dim` (4 ints)** | **a runtime table row**                 | ordering A (`RVec3`)                          |
| [`quantity-unit-in-type`][ex-unit]          | [mp-units][mp] · [Au][au] · [uom][rust-uom] | `Quantity!(Unit{dim + rational scale})`      | `ℤ³` + `ℚ` scale  | compile                   | erased (scale in the type)   | editing the central `Dim`               | ordering A                                    |
| [`quantity-diagnostics`][ex-diag]           | [Au][au] · [mp-units][mp] · §6              | `Quantity!(dim, kind, unit)`                 | `ℤ⁴` · closed     | compile — **engineered**⁵ | erased                       | editing the central `Dim`               | ordering A                                    |
| [`quantity-polymorphism`][ex-poly]          | [mechanisms][mech] · [Kennedy][kennedy]     | `Quantity!(dim, Payload)`                    | `ℤ³` · closed     | compile                   | `Vec3`                       | editing the central `Dim`               | **A + generic `dot`/`cross`**                 |
| [`quantity-open-basis`][ex-open]            | [Au][au] · [mp-units][mp] (basis)           | **CTFE `Gen[]` of `(name, exp)`**            | `ℤ` · **open**    | compile                   | erased                       | **minting a name** (`base("sr")`)       | ordering A                                    |
| [`quantity-logarithmic`][ex-log]            | [Pint][pint] · [Unitful][unitful]           | `struct Stops` / `Decibels`                  | none (log)        | compile                   | erased                       | n/a (not a grade)                       | ordering B noted (nonlinear)                  |
| [`quantity-vector-composition`][ex-compose] | [mechanisms][mech] · [torsor][torsor]       | `Quantity!(dim, Payload)` + local `Vec(T,N)` | `ℤ³` · closed     | compile                   | `Vec3`                       | editing the central `Dim`               | **A vs B — proves the `isNumeric!T` blocker** |

<sub>¹ `static foreach` asserts `sizeof`/`alignof`/`offsetof`/array-layout equal a bare
`double` for four grades — the checkable half of erasure (codegen identity is left to the
optimizer, stated honestly). ² Affine misuse is rejected by a mix of `!__traits(compiles,
…)` and an _engineered_ `static assert(0, "… not an affine operation")`. ³ The composition
anti-pattern: with no `dim` to parameterize on, `Position` and `Displacement` each wrap the
same `Vec3` in their own bespoke struct — nominal typing multiplies the surface that
composes with `Vector` instead of factoring it. ⁴ `add`/`sub` return
`Expected!(RQuantity, DimError, NoGcHook)` — an `err`, not a throw; the one deliberate
throwing path uses `recycledErrorInstance` to stay `@nogc`. ⁵ `checkAddable!(A, B)` fires
`static assert(false, "cannot add Radiance [W·m⁻²·sr⁻¹] to Irradiance [W·m⁻²] — dimensions
differ")`, plus a `pragma(msg, …)` printing the engineered sentence next to the raw
mangled type.</sub>

## Capability fingerprint

Which expressiveness axis each prototype owns (`✓` = demonstrated here; blank = out of
scope for that probe, covered by another):

| Prototype                             | Fractional | Affine | Kind       | Logarithmic | Engineered diagnostics | Generic polymorphism |
| ------------------------------------- | ---------- | ------ | ---------- | ----------- | ---------------------- | -------------------- |
| [`quantity-rational-exponents`][ex-q] | ✓          |        |            |             |                        |                      |
| [`quantity-affine-torsor`][ex-affine] |            | ✓      |            |             |                        |                      |
| [`quantity-kind-tags`][ex-kind]       |            |        | ✓ tag¹     |             |                        |                      |
| [`quantity-nominal`][ex-nominal]      |            | ✓      | ✓ nominal² |             |                        |                      |
| [`quantity-diagnostics`][ex-diag]     |            |        |            |             | ✓                      |                      |
| [`quantity-polymorphism`][ex-poly]    |            |        |            |             |                        | ✓                    |
| [`quantity-logarithmic`][ex-log]      |            |        |            | ✓           |                        |                      |

<sub>¹ A flat comparability tag: `Hz` ≠ `Bq`, plane-angle ≠ ratio — but **erased under
`×`/`÷`** (`AngularVelocity × Time` reverts to the default kind), so it is a tag, not an
algebra. ² Nominal typing gives `Torque` ≠ `Energy` (and `Radiance` ≠ `Irradiance`) _for
free_, but forfeits the exponent group entirely and cannot name an undeclared product —
`Position × Position` has no type. A genuine **fork** against the exponent-vector-plus-tag
model, not a stacking option.</sub> The seven prototypes absent from this grid own a
_representation_ axis instead (erasure → runtime cost, runtime-expected → checking epoch,
unit-in-type → unit storage, open-basis → basis, vector-composition → linear-algebra
composition, and the two core ℤ/ℚ probes → exponent domain).

## Findings by axis

**Exponent domain is settled; the basis is the real fork.** ℤ and ℚ are one CTFE
parameter apart ([`ex-z`][ex-z] vs [`ex-q`][ex-q]'s gcd-normalized `Rational`, which makes
`sqrt` total while `m^(1/2) + m` stays rejected), matching the survey's finding that
practice drifted to ℚ. The sharper split is **closed vs open basis**:
[`quantity-open-basis`][ex-open] mints a new base dimension by _naming_ it
(`base("sr")`, `base("sample")`) with no core edit — at the cost of per-instantiation CTFE
normalization and the loss of the fixed-width `int[3]` layout guarantee that
[`quantity-erasure`][ex-e] leans on.

**Checking is compile-time almost everywhere; the one runtime probe pays for it in bytes.**
Twelve prototypes reject `m + s` at compile time; [`quantity-runtime-expected`][ex-runtime]
alone carries a `Dim` field at run time and returns an `Expected` `err` rather than a
compile error or a throw — the honest cost of the Pint/UCUM registry pole is four `int`s per
value where the others store a bare `double`. [`quantity-erasure`][ex-e] is the mirror
image: it machine-checks that the grade is _fully_ erased from the object layout.

**Extensibility is the most decision-relevant axis, and it cuts four ways.** Adding a
dimension means: editing the central `Dim` (the ℤ³ family — simple, closed); minting a name
(open-basis — extensible, unnormalized); writing a new struct and hand-wiring every product
(nominal — the surface explodes); or inserting a runtime table row (runtime-expected —
data-driven, unchecked). This axis, not the exponent domain, is what a library actually
lives with.

**The kind question is a fork, not a ladder.** [`quantity-kind-tags`][ex-kind] shows the
flat-tag rung (distinguishes same-dimension quantities, but the tag is erased under
multiplication); [`quantity-nominal`][ex-nominal] shows the opposite pole (kind for free
via distinct types, but no exponent algebra and no nameable products). They are mutually
exclusive designs, and [`quantity-diagnostics`][ex-diag] demonstrates the third lever —
making the mismatch _message_ a product: a `checkAddable` template emits domain-language
prose instead of a mangled `typenum`-style leak.

**Four prototypes independently rediscover the same three `Vector` gaps.**
[`affine-torsor`][ex-affine], [`nominal`][ex-nominal], [`polymorphism`][ex-poly], and
[`vector-composition`][ex-compose] all compose a `Quantity` with `sparkles:math`'s `Vector`,
and each hits the same wall: `Vector(T, N)` is constrained `if (isNumeric!T)` (so
`Vector!(Quantity, N)` is unnameable), its `dot` is dimension-blind `cast(CommonType)` (a
length·length dot comes back a scalar, not an area), and it ships no 3-D
`cross`/`magnitude`/`normalize`. [`quantity-vector-composition`][ex-compose] makes this a
machine-checked fact and shows a ~30-line element-generic `Vec` compiling ordering B where
`Vector` refuses. The convergence of four independent probes on the same finding is itself
the signal — this is the co-design pressure detailed in the capstone's
[composition subsection][comparison].

**Forward inference is enough; a solver is not.** Every compile-time prototype infers
result grades through `×`/`÷` for free; [`quantity-polymorphism`][ex-poly] extends this to
generic `dot`/`cross`/`magnitude`/`normalize` and then names the ceiling — D dispatches on
_argument_ types, never on the result type, so there is no inverse of `sqr` and no
Kennedy-style AG-unification. D is an evaluator, not a solver; the survey shows that rung is
a two-system niche and a maintenance liability, so the ceiling is not a loss.

## What a Sparkles units library should take

Each probe contributes one decision, mapped to the [comparison capstone][comparison]'s
Part IV open decisions:

| From                                                      | Take                                                                                                                           | Open decision it settles / frames |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | --------------------------------- |
| [`ex-z`][ex-z] + [`ex-q`][ex-q]                           | a CTFE value-`Dim` exponent vector; ship an ℤ surface with a ℚ escape hatch                                                    | Exponent domain                   |
| [`quantity-erasure`][ex-e]                                | keep the `sizeof`/`offsetof` layout asserts as a CI guard on the zero-cost claim                                               | Erasure guarantee                 |
| [`quantity-affine-torsor`][ex-affine]                     | a distinct affine `Point`/`Vec` (torsor) split, N-generic and unit-aware                                                       | Affine quantities                 |
| [`quantity-kind-tags`][ex-kind] · [`nominal`][ex-nominal] | choose the kind model as a **fork**: a flat erased tag _or_ nominal per-quantity types — not both                              | Kind system                       |
| [`quantity-unit-in-type`][ex-unit]                        | decide unit-in-type + lazy conversion vs normalize-to-base (this probe shows the former works)                                 | Unit storage                      |
| [`quantity-diagnostics`][ex-diag]                         | a `checkAddable` gate that emits domain-language `static assert` prose                                                         | Diagnostics strategy              |
| [`quantity-open-basis`][ex-open]                          | decide open generator set vs closed vector (this probe shows mint-by-name works)                                               | Registry vs closed / basis        |
| [`quantity-runtime-expected`][ex-runtime]                 | if a runtime companion is wanted, make it `Expected`-returning, `@nogc`, never a throw                                         | Runtime companion                 |
| [`quantity-logarithmic`][ex-log]                          | treat logarithmic units as their own algebra (defer to a later version)                                                        | Angle & logarithmic policy        |
| [`quantity-polymorphism`][ex-poly]                        | rely on forward IFTI; do **not** chase a solver — D cannot, and the survey says do not                                         | Solver (evaluators vs solvers)    |
| [`quantity-vector-composition`][ex-compose]               | relax `Vector`'s `isNumeric!T` → an `isScalar` concept; make `dot`/`cross`/`magnitude` element-driven; add the missing 3-D ops | Composition with `sparkles:math`  |

**Composite recommendation.** The prototypes point at a coherent design: a compile-time
CTFE value-`Dim` core (ℤ surface, ℚ escape) with erased representation guarded by layout
asserts; a distinct affine `Point`/`Vec` torsor layer; engineered `checkAddable` diagnostics
as a first-class feature; an optional `Expected`-based runtime companion for data-driven
units; and a **co-designed `sparkles:math`** whose `Vector` accepts `Quantity` elements
(`isScalar` concept, element-driven `dot`/`cross`, N-generic unit-aware affine types). The
two genuine forks left for the `docs/specs/` proposal to decide are the **kind model** (flat
tag vs nominal) and the **basis** (closed vector vs open generators).

## Sources

The thirteen prototypes under `examples/` (each linked individually above) — each
CI-verified by `dub run :ci -- examples standalone` and cross-linked to the system and theory
pages it models — together with the [comparison capstone][comparison] (Part IV open
decisions and the "Composition with `sparkles:math`" subsection) this evaluation feeds. No
claim here is not already grounded in a runnable prototype.

<!-- References -->

<!-- Prototypes -->

[ex-z]: ./examples/quantity-zn-graded.d
[ex-q]: ./examples/quantity-rational-exponents.d
[ex-e]: ./examples/quantity-erasure.d
[ex-affine]: ./examples/quantity-affine-torsor.d
[ex-kind]: ./examples/quantity-kind-tags.d
[ex-nominal]: ./examples/quantity-nominal.d
[ex-runtime]: ./examples/quantity-runtime-expected.d
[ex-unit]: ./examples/quantity-unit-in-type.d
[ex-diag]: ./examples/quantity-diagnostics.d
[ex-poly]: ./examples/quantity-polymorphism.d
[ex-open]: ./examples/quantity-open-basis.d
[ex-log]: ./examples/quantity-logarithmic.d
[ex-compose]: ./examples/quantity-vector-composition.d

<!-- Theory -->

[fag]: ./theory/free-abelian-group.md
[mech]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md
[kennedy]: ./theory/kennedy-types.md

<!-- Systems -->

[rust-uom]: ./rust-uom.md
[squants]: ./scala-squants.md
[swift]: ./swift-units.md
[pint]: ./python-pint.md
[ucum]: ./ucum-qudt.md
[mp]: ./cpp-mp-units.md
[au]: ./cpp-au.md
[unitful]: ./julia-unitful.md

<!-- Synthesis -->

[comparison]: ./comparison.md
