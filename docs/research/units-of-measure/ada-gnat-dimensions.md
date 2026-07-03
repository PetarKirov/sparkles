# GNAT dimensionality checking (Ada)

Static dimensional analysis as a **compiler-vendor extension**: GNAT attaches dimension vectors to ordinary Ada numeric subtypes through two implementation-defined aspects (`Dimension_System`, `Dimension`), checks every expression during the compiler's own semantic phase (`sem_dim.adb`), and discards the vectors before code generation — zero run-time cost by construction, and zero portability beyond GNAT.

| Field            | Value                                                                                                                                                                          |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language         | Ada 2012+ — but the aspects are **GNAT-only**; no Ada standard defines dimensional analysis                                                                                    |
| License          | GPL-3.0+ (compiler); GPL-3.0+ with GCC Runtime Library Exception (the `System.Dim` runtime packages)                                                                           |
| Repository       | [gcc-mirror/gcc][repo] (`gcc/ada/` subtree)                                                                                                                                    |
| Documentation    | [GNAT RM, Implementation Defined Aspects][rm-live] (§ `Dimension` / `Dimension_System`) · [GNAT UGN §6.5, "Performing Dimensionality Analysis in GNAT"][ugn-live]              |
| Key authors      | AdaCore (GNAT originally developed at NYU; `sem_dim` is © FSF 2011–2026 per its header); the design was presented by AdaCore's Vincent Pucci and Edmond Schonberg at HILT 2012 |
| Category         | Compiler-native static units — as a vendor extension, not a language feature and not a library                                                                                 |
| Mechanism        | Aspects on a derived numeric type + its subtypes; per-node dimension vectors (`array` of `Rational`) in a compiler-side hash table, synthesized bottom-up during resolution    |
| Exponent domain  | `ℚ` — a `Rational` record per slot ([`sem_dim.adb` L63][sem-dim-adb]); restricted to `ℤ` when the carrier is an integer type ([RM][rm-live])                                   |
| Checking time    | Compile time only — vectors are removed as analysis ascends and never reach the back end                                                                                       |
| Analyzed version | [`gcc-mirror/gcc`][repo] @ `8363c23` (2026-07-03, master; `BASE-VER` `17.0.0`) — sparse clone at `$REPOS/ada/gcc`                                                              |
| Latest release   | Ships in every GCC/GNAT release since GNAT 7.0.1 ([UGN][ugn-live]); the machinery has been essentially stable since 2012                                                       |

> [!NOTE]
> GNAT is this survey's data point for the **vendor-extension** route: dimensional
> analysis implemented inside a production compiler for a language whose standard says
> nothing about it. [F#][fsharp-uom] gets units from the language itself, the GHC
> [`uom-plugin`][uom-plugin] from a sanctioned plugin API, and everything else in the
> catalog from library encodings; GNAT hard-codes the checker into its semantic
> analyzer, so Ada code using these aspects compiles **only** with GNAT — a
> portability finding in both directions (best diagnostics money can't buy elsewhere;
> no second implementation). The mechanism taxonomy places it in
> [`type-system-mechanisms.md`][mechanisms].

---

## Overview

### What it solves

Dimensional consistency for engineering code, checked by the compiler the engineer
already uses, with no operator boilerplate and no wrapper types. The checker's own
spec states the model ([`sem_dim.ads`][sem-dim-ads] L26–36, pinned clone):

> "This package provides support for numerical systems with dimensions. A 'dimension'
> is a compile-time property of a numerical type which represents a relation between
> various quantifiers such as length, velocity, etc. … Dimensionality checking is part
> of type analysis performed by the compiler. It ensures that manipulation of
> quantified numeric values is sensible with respect to the system of units."

The ready-made SI vocabulary is one `with` away — `System.Dim.Mks` instantiates the
generic MKS system over `Long_Long_Float` ([`s-dimmks.ads`][s-dimmks] L34) — and the
User's Guide names the pay-off that distinguishes this design from the
operator-overloading tradition ([UGN §6.5][ugn-live], local capture
`gnat-ugn-dimensionality-analysis.html`):

> "The major advantage of this model is that it does not require the declaration of
> multiple operators for all possible combinations of types: you is only need [sic] to
> use the proper subtypes in object declarations."

### Design philosophy

**Aspects on subtypes, not a lattice of types.** Every quantity in a system is a value
of _one_ numeric type (`Mks_Type is new Long_Long_Float`); `Length`, `Time`, `Force`
are Ada **subtypes** of it, differing only in the `Dimension` aspect. Ada's predefined
`+`, `*`, `**` on the base type just work — no operator declarations, no phantom
parameters, no instantiation per unit combination. The dimension information rides on
a separate annotation channel that the semantic analyzer reads and ordinary type
checking never sees.

**Structural, name-free checking.** Compatibility is decided by comparing dimension
_vectors_, never subtype names. `Dimensions_Match` ([`sem_dim.ads`][sem-dim-ads]
L198–200) verifies "that two subtypes have the same dimensions", and the UGN is
explicit that even across two different `Dimension_System`s "vector equality does not
require that the corresponding `Unit_Names` be the same" — a length in metres converts
to a length in inches (with an explicit factor) but not to a mass ([UGN][ugn-live]).

**Erasure by construction.** Dimensions are a property of AST nodes during analysis,
not of the data representation. The spec comment describes the discipline
([`sem_dim.ads`][sem-dim-ads] L86–94):

> "In principle every node that is a component of a floating-point expression may have
> a dimension vector. However, the dimensionality checking is for the most part a
> bottom-up tree traversal, and the dimensions of operands become irrelevant once the
> dimensions of an operation have been computed. To minimize space use, the dimensions
> of operands are removed after the computation of the dimensions of the parent
> operation."

---

## How it works

### Declaring a system and its subtypes

A `Dimension_System` aspect on a **derived numeric type** mints a system: an ordered
list of up to 7 base dimensions, each with a `Unit_Name` (used in `Dimension`
aggregates), a `Unit_Symbol` (used by dimensioned output), and a `Dim_Symbol` (used in
error messages). The shipped SI system, verbatim ([`s-digemk.ads`][s-digemk] L52–61):

```ada
-- gcc @ 8363c23: gcc/ada/libgnat/s-digemk.ads (generic over Float_Type)
type Mks_Type is new Float_Type
  with
   Dimension_System => (
     (Unit_Name => Meter,    Unit_Symbol => 'm',   Dim_Symbol => 'L'),
     (Unit_Name => Kilogram, Unit_Symbol => "kg",  Dim_Symbol => 'M'),
     (Unit_Name => Second,   Unit_Symbol => 's',   Dim_Symbol => 'T'),
     (Unit_Name => Ampere,   Unit_Symbol => 'A',   Dim_Symbol => 'I'),
     (Unit_Name => Kelvin,   Unit_Symbol => 'K',   Dim_Symbol => '@'),
     (Unit_Name => Mole,     Unit_Symbol => "mol", Dim_Symbol => 'N'),
     (Unit_Name => Candela,  Unit_Symbol => "cd",  Dim_Symbol => 'J'));
```

(The `'@'` stands in for `Θ` — the RM notes it avoids "extended Latin-1 characters in
this context" ([RM][rm-live]).) A `Dimension` aspect on a **subtype** then assigns a
vector of rational exponents over those names, plus an optional display symbol
([`s-digemk.ads`][s-digemk] L65–69, L221–227):

```ada
-- gcc @ 8363c23: gcc/ada/libgnat/s-digemk.ads
subtype Length is Mks_Type
  with
   Dimension => (Symbol => 'm',
     Meter  => 1,
     others => 0);

subtype Force is Mks_Type
  with
   Dimension => (Symbol => 'N',
     Meter    => 1,
     Kilogram => 1,
     Second   => -2,
     others   => 0);
```

Unit values are plain constants — `m : constant Length := 1.0;` and the prefixed
family `mm`/`cm`/`km` as scaled constants, `min`/`hour`/`day`/`year` as products
([`s-digemk.ads`][s-digemk] L115–121, L347–354, L380–383; more prefixes live in a
child package `System.Dim.Generic_Mks.Generic_Other_Prefixes`, per L34–36). The
library instantiates the generic three times: `System.Dim.Float_Mks`,
`System.Dim.Long_Mks`, and `System.Dim.Mks` over `Long_Long_Float`
([UGN][ugn-live]; [`s-dimmks.ads`][s-dimmks]).

### The checking pass

`Analyze_Dimension` is invoked from the compiler's resolution/analysis routines for
each relevant node kind — the `OK_For_Dimension` array ([`sem_dim.adb`][sem-dim-adb]
L195–224) enumerates the ~27 node kinds that may carry a vector — and runs in two
phases: dimension **checking**, then **propagation** to the parent node
([`sem_dim.ads`][sem-dim-ads] L74–84). The synthesis rules are exactly the
[free-abelian-group][fag] operations on exponent vectors, spelled out in the UGN as
`DV(expr)` equations and implemented as vector arithmetic
([`sem_dim.adb`][sem-dim-adb] L1462–1568):

- `+`, `-`, `mod`, `rem`, `:=`, parameter passing, comparisons: vectors must be
  **equal** (dimensionless literals get a pass with a warning in comparisons).
- `*`, `/`: vectors **add** / **subtract** componentwise.
- `**`: the vector is **scaled** by the exponent, which must be static —
  `"exponent of dimensioned operand must be known at compile time"` otherwise
  (L1523–1526); a static `(1/2)` is read as an exact `Rational` by
  `Create_Rational_From` (L2551).
- `Sqrt` from `Ada.Numerics.Generic_Elementary_Functions` is special-cased to **halve**
  the vector (L1709–1723); every other elementary function requires dimensionless
  actuals (`"dimensions mismatch in call of&"`, L1736–1744).

### Dimensioned output

`System.Dim.Float_IO` / `System.Dim.Integer_IO` provide `Put`, `Put_Dim_Of`, and
`Image` that render the unit. There is no run-time dimension data to consult — instead
the compiler rewrites the call: `Expand_Put_Call_With_Symbol` adds the symbol string
(the subtype's `Symbol`, or a string synthesized from the vector) as an extra
compile-time actual ([`sem_dim.adb`][sem-dim-adb] L3008–3062;
[`s-diflio.ads`][s-diflio] L32–35, `Image` at L178). A locally-verified end-to-end
program (the UGN's free-fall example, re-run against GNAT 13.4.0):

```ada
-- locally reproduced: freefall.adb — GNAT 13.4.0 (nixpkgs), 2026-07-03
with System.Dim.Mks;    use System.Dim.Mks;
with System.Dim.Mks_IO; use System.Dim.Mks_IO;
with Ada.Text_IO;       use Ada.Text_IO;

procedure Freefall is
   subtype Acceleration is Mks_Type
     with Dimension => ("m/sec^2", Meter => 1, Second => -2, others => 0);

   G        : constant Acceleration := 9.81 * m / (s ** 2);
   T        : constant Time := 10.0 * s;
   Distance : Length;
begin
   Distance := 0.5 * G * T ** 2;
   Put (Distance, Aft => 2, Exp => 0);  New_Line;   -- "490.50 m"
   Put (G * T, Aft => 2, Exp => 0);     New_Line;   -- "98.10 m.s**(-1)"
end Freefall;
```

The second `Put` shows the synthesized-symbol path: `G * T` has no declared subtype,
so the compiler renders its vector from unit symbols (`m.s**(-1)`).

---

## Dimension representation

A dimension is a **fixed-length vector of rationals over the compiler's own tables** —
no type-level encoding exists because the checker lives inside the compiler
([`sem_dim.adb`][sem-dim-adb] L63–170):

```ada
-- gcc @ 8363c23: gcc/ada/sem_dim.adb (abridged)
type Rational is record
   Numerator   : Whole;            -- new Int
   Denominator : Positive_Whole;
end record;

Max_Number_Of_Dimensions : constant := 7;

type Dimension_Type is
  array (Dimension_Position range
           Low_Position_Bound .. High_Position_Bound) of Rational;

--  The following table associates nodes with dimensions
package Dimension_Table is new
  GNAT.HTable.Simple_HTable
    (Header_Num => Dimension_Table_Range,
     Element    => Dimension_Type,
     Key        => Node_Id, ...);
```

- **Per-system, closed 7-slot vector; open set of systems.** Each
  `Dimension_System` registers a `System_Type` (names, symbols, count) in a
  `System_Table`; a subtype's aspect fills a `ℚ⁷` vector positionally against its own
  system. More than 7 base dimensions is a hard error — `"too many dimensions in
system"` ([`sem_dim.adb`][sem-dim-adb] L950). Contrast the open generator set of
  [F#][fsharp-uom] and the fixed-but-library-chosen vectors of
  [Boost.Units][boost-units] and [`uom`][rust-uom].
- **Rational exponents are first-class in the aspect grammar.** The RM syntax is
  `RATIONAL ::= [-] NUMERIC_LITERAL [/ NUMERIC_LITERAL]` ([RM][rm-live]), parsed into
  exact `Rational`s by `Create_Rational_From` ([`sem_dim.adb`][sem-dim-adb] L2551) with
  a dedicated rational-arithmetic mini-library (L56–93: `+`, `-`, `*`, `/`, `GCD`,
  `Reduce`). Integer-typed carriers are restricted to integer exponents ([RM][rm-live]).
- **Vectors attach to AST nodes and entities, not to values or types-as-data.**
  `Dimension_Table` is keyed by `Node_Id` (expression nodes during analysis);
  `Symbol_Table` maps subtype entities to their display symbol (L176–190). This is the
  entire representation — nothing exists in the program image.
- **Aggregate bookkeeping has a sharp edge** (locally reproduced): the consistency
  check counts the `others` association as a dimension
  ([`sem_dim.adb`][sem-dim-adb] L803, L819–824), so in a 2-dimension system
  `(Bit => 1, Second => -1, others => 0)` is rejected with
  `"type "Bandwidth" has more dimensions than system allows"` — name all `N`
  dimensions **or** use `others`, never both covering everything.

## Checking & inference

There is **no inference and no unification** — the algorithm is a single bottom-up
synthesis pass with equality tests, i.e. the degenerate, trivially-decidable corner of
the design space mapped in [`type-system-mechanisms.md`][mechanisms]. Dimensions flow
from declarations (aspects) upward through expressions via the `DV` rules above;
checks fire at the join points (assignment L1357, binary operators L1427–1434, calls
L1785, aggregates L1309, case/if expressions L1821). Nothing is ever solved for: a
variable's dimension is fixed by its subtype, an expression's dimension is computed,
and mismatch is an error. Since exponents are rationals under vector addition and
scalar multiplication, every operation is total — no divisibility failures, no
occurs-check, no search.

**Dimensional polymorphism is not expressible.** A generic `sqr : α → α²` cannot be
written: a function's formal and result must name concrete subtypes whose aspects
carry literal exponent vectors, and there is no way to abstract over the vector. What
GNAT offers instead is a **view-conversion loophole for same-dimension generics**
([UGN][ugn-live]): converting a dimensioned value to its dimensionable _base_ type
preserves the dimension vector —

> "If `T` is the base type for `expr` (and the dimensionless root type of the
> dimension system), then `DV(T(expr))` is `DV(expr)`. … This rule means you can write
> generic code that can be instantiated with compatible dimensioned subtypes."

— so a generic instantiated at `Length` stays dimension-correct at `Length`, but no
single subprogram can be exponent-generic across dimensions. Exponent-changing
operations exist only as compiler special cases (`**` with static exponent, `Sqrt`).
Kennedy-style principal types and unit variables ([theory][kennedy-types]) have no
counterpart here.

**Literals are dimensionless, with pragmatic escape hatches.** `Distance := 5.0` is an
error, but `Acc > 10.0` is accepted with a warning (`"assumed to be"`,
[`sem_dim.adb`][sem-dim-adb] L2767 — locally observed as
`warning: assumed to be "1.0 b" [enabled by default]`). The runtime's own unit
constants need the same pass: `m : constant Length := 1.0` is a dimensionless
assignment, so `s-digemk.ads` wraps them in `pragma Warnings (Off, "*assumed to be*")`
with the comment "we can't assign `1.0*m` to `m`" ([`s-digemk.ads`][s-digemk]
L109–113).

## Extensibility

Defining a fresh system is one aspect on one derived type — no registration, no
traits, no macro. A two-dimension information system, locally compiled (GNAT 13.4.0):

```ada
-- locally reproduced: infosys.adb — custom Dimension_System
type Info_Type is new Long_Long_Float
  with Dimension_System =>
    ((Unit_Name => Bit,    Unit_Symbol => "b",  Dim_Symbol => "B"),
     (Unit_Name => Second, Unit_Symbol => "s",  Dim_Symbol => "T"));

subtype Data is Info_Type
  with Dimension => (Symbol => "b", Bit => 1, others => 0);

subtype Bandwidth is Info_Type
  with Dimension => (Symbol => "b/s", Bit => 1, Second => -1);

Rate : constant Bandwidth := 512.0 * b / s;      -- checks
Bad  : constant Bandwidth := 512.0 * b * s;      -- error, see Diagnostics
```

- **Scoping is Ada scoping.** A system is a type; its dimensioned subtypes and unit
  constants are ordinary declarations exported from a package. Two systems are two
  unrelated types — mixing them is caught by ordinary Ada type checking before
  dimensions are even consulted.
- **Cross-system interop is positional and explicit.** A type conversion between
  dimensioned subtypes of _different_ systems checks vector equality by position, not
  by name ([UGN][ugn-live]) — the supported idiom for metric/imperial or cgs/MKS
  bridging, with the numeric factor supplied by hand.
- **Prefixes are constants, not machinery.** `km` is `1.0E+03 : constant Length` —
  a value-level convention identical to F#'s, with the same limitation: nothing checks
  the factor ([`s-digemk.ads`][s-digemk] L347–354).
- **The ceiling is 7 base dimensions per system** ([RM][rm-live];
  `Max_Number_Of_Dimensions`, [`sem_dim.adb`][sem-dim-adb] L99) — exactly SI-shaped;
  an 8th (say, `Angle` or `Currency` alongside the SI seven) does not fit.

## Expressiveness edges

- **Fractional powers: yes, `ℚ` throughout** (locally reproduced, `rational.adb`):
  `Meter => 1/2` in an aspect, `X ** (1/2)` with a static rational, and
  `Sqrt (4.0 * m)` assigning to a `Dimension => (Meter => 1/2, …)` subtype all
  compile. GNAT and [F#][fsharp-uom] are the two compiler-resident systems in this
  survey with exact rational exponents.
- **Affine quantities: no — and the stdlib demonstrates the gap.**
  `Celsius_Temperature` is declared with the _Kelvin_ vector and display symbol `"°C"`
  ([`s-digemk.ads`][s-digemk] L152–156), with the offset baked into a constant
  `dC : constant Celsius_Temperature := 273.15` (L337). Locally reproduced:
  `TC : Celsius_Temperature := TK;` for a Kelvin-valued `TK` compiles without
  complaint — the °C/K distinction is display-only, the 273.15 is the programmer's
  problem, and mixing absolute and relative temperatures type-checks. The missing
  structure is this survey's [torsor page][torsor].
- **Logarithmic quantities: no.** `log`/`exp`/trig demand dimensionless actuals
  ([`sem_dim.adb`][sem-dim-adb] L1728–1748); dB and pH have no representation.
- **Angles: dimensionless with a cosmetic symbol.** `Angle` and `Solid_Angle` carry
  the empty vector plus symbols `"rad"`/`"sr"` ([`s-digemk.ads`][s-digemk] L134–137,
  L296–299). Locally reproduced: `A + 2.0` on an `Angle` compiles silently — radian
  correctness is unchecked, and `rad` vs `sr` confusion is invisible to the checker.
- **Kind vs dimension: collapses, in the shipped SI package itself.** `Frequency`
  (`Hz`) and `Radioactivity` (`Bq`) are both `Second => -1`
  ([`s-digemk.ads`][s-digemk] L229–233, L290–294); `Absorbed_Dose` (`Gy`) and
  `Equivalent_Dose` (`Sv`) are both `m²/s²` (L127–132, L214–219); torque would equal
  `Energy`. Locally reproduced: `F + B` for `Frequency F`, `Radioactivity B`
  compiles. The same collapse as F#'s abbreviations — and precisely the gap
  [mp-units][mp-units]' quantity-kind hierarchy exists to close.
- **No unit-level tracking within a system.** `cm` is `0.01`; all values are stored in
  coherent SI magnitudes, so `Put (2.3 * dm)` prints `0.23 m`, not `2.3 dm`
  ([`s-diflio.ads`][s-diflio] L98–104). There is no quantity-vs-unit distinction to
  misuse — and none to exploit ([Au][au] and [mp-units][mp-units] make the opposite
  choice).
- **Aspect placement is narrower than documented.** The `sem_dim.ads` header claims
  the `Dimension` aspect "applies for subtype and object declarations"
  ([`sem_dim.ads`][sem-dim-ads] L54–57), but the body rejects anything but a subtype
  declaration (L581–584) — locally reproduced:
  `error: aspect "Dimension" must apply to subtype declaration` for an
  object-declaration aspect. The spec comment is stale.

## Zero-cost story

Erasure is structural, not an optimization:

- **The representation is the plain float.** `Mks_Type is new Long_Long_Float` —
  a dimensioned value _is_ its carrier; there is no wrapper to unbox and no field to
  strip ([`s-digemk.ads`][s-digemk] L52; [`s-dimmks.ads`][s-dimmks] L34).
- **Vectors die during analysis.** Operand dimensions are removed as soon as the
  parent's are computed ([`sem_dim.ads`][sem-dim-ads] L86–94), and
  `Remove_Dimensions` scrubs the remainder when the expander runs
  ([`sem_dim.adb`][sem-dim-adb] L1614–1620, L3677). The back end never sees a
  dimension.
- **Observable: identical assembly** (locally reproduced, GNAT 13.4.0, `-O2 -S`). A
  function computing `0.5 * G * T ** 2` over `Mks_Type`/`Time`/`Length` subtypes and
  the same function over bare `Long_Long_Float` compile to byte-identical assembly
  modulo symbol names — both constant-fold to a single `fldt` of `490.5`. Dimensioned
  and undimensioned code are the same code.
- **Dimensioned IO is compile-time string splicing.** The unit suffix in
  `Put`/`Image` output is a literal actual injected by
  `Expand_Put_Call_With_Symbol` during expansion ([`sem_dim.adb`][sem-dim-adb]
  L3008–3062) — the run-time cost is printing a string constant.
- **Cross-unit checking needs no metadata channel.** Ada compiles against package
  _specs_; the aspects are re-analyzed from source in every compilation that `with`s
  the package, so dimensions propagate across compilation units for free (contrast
  F#'s pickled-metadata blob, which exists precisely because .NET signatures erase).

## Diagnostics

The mismatch program (adding metres to seconds):

```ada
-- mismatch.adb
with System.Dim.Mks; use System.Dim.Mks;

procedure Mismatch is
   D : Mks_Type := 1.0 * m + 1.0 * s;
begin
   null;
end Mismatch;
```

produces exactly:

```text
mismatch.adb:4:28: error: both operands for operation "+" must have same dimensions
mismatch.adb:4:28: error: left operand has dimension [L]
mismatch.adb:4:28: error: right operand has dimension [T]
```

\[reproduced locally, `gnatmake -gnat2012`, GNAT 13.4.0 (nixpkgs), 2026-07-03\]. The
message template lives in `Error_Dim_Msg_For_Binary_Op`
([`sem_dim.adb`][sem-dim-adb] L1427–1434); the operand lines are rendered from the
vectors by `Dimensions_Msg_Of` / `From_Dim_To_Str_Of_Dim_Symbols` (L2674, L3349) using
the system's declared `Dim_Symbol`s. The other check sites keep the same two-part
shape — locally reproduced under the same toolchain:

```text
objdim.adb:6:06: error: dimensions mismatch in assignment
objdim.adb:6:06: error: left-hand side is dimensionless
objdim.adb:6:06: error: right-hand side has dimension [L.T**(-1)]

infosys.adb:22:04: error: dimensions mismatch in object declaration
infosys.adb:22:43: error: expected dimension [B.T**(-1)], found [B.T]
```

The second pair is from the custom two-dimension system above — diagnostics
automatically speak the user's own `Dim_Symbol` vocabulary (`[B.T**(-1)]`). The UGN
documents the same shape for the MKS system (`left-hand side has dimension [L]` /
`right-hand side has dimension [M]`, [UGN][ugn-live]). Three properties worth naming:
the errors come **from the compiler itself** (real source coordinates, no encoding
artifacts, nothing template-mangled); they are **short** — operator, then one line per
offending operand; and they print vectors in **dimension-symbol algebra** (`[L]`,
`[B.T**(-1)]`), not unit names — the `Θ`-as-`@` compromise in the MKS declaration
exists solely for this rendering.

## Ergonomics & compile-time cost

- **Declaration overhead is one aspect per subtype.** `with System.Dim.Mks;` buys the
  SI system; a project-specific quantity is 3–6 lines of `subtype … with Dimension`.
  Values need explicit unit factors (`10.0 * s`) — slightly heavier than F#'s
  `10.0<s>` literals, much lighter than any C++ system's type spelling.
- **Error readability is compiler-grade** (above) — the strongest diagnostics in this
  survey alongside F#, and for the same reason: the checker owns the error channel.
- **Compile-time cost is a hash-table lookup per expression node.** The whole feature
  is ~3,800 lines of `sem_dim.adb` piggybacked on resolution: vector arithmetic on
  7-slot arrays and two `GNAT.HTable` maps. No template instantiation, no solver
  iterations, no per-unit code generation; no published benchmark isolates it, and
  compile-time cost has never been a documented complaint in 14 years of the feature.
- **Footguns, all locally reproduced above:** the `others`-counts-as-a-dimension
  aggregate quirk; literals `"assumed to be"` dimensioned in comparisons (warning, not
  error); exponents must be static; the aspect refuses object declarations despite the
  spec comment; and everything silently degrades to plain floats the moment a value
  passes through a conversion to a non-dimensioned type ([UGN][ugn-live]: it "of
  course then escapes dimensionality analysis").
- **The deepest ergonomic cost is strategic, not syntactic:** the code is welded to
  one vendor's compiler. There is no `-fdimensions` in any other Ada implementation,
  and the aspects are (by design) rejected as unrecognized elsewhere.

---

## Strengths

- **Compiler-native diagnostics and zero encoding tax** — errors are two-to-three
  plain lines with source positions and dimension-symbol vectors, from the production
  compiler Ada projects already use.
- **Erasure by construction** — vectors live in compiler hash tables keyed by AST
  node; the generated code is byte-identical to undimensioned code (verified locally
  by assembly diff).
- **Exact rational exponents** — `ℚ⁷` vectors with a real rational-arithmetic kernel;
  `Meter => 1/2`, `** (1/3)`, and a dimension-halving `Sqrt` all work.
- **No operator boilerplate** — one numeric type per system, subtypes for quantities,
  predefined arithmetic; the UGN calls this out as the model's "major advantage".
- **Trivial custom systems** — any `≤ 7`-dimension system is a single aspect;
  diagnostics automatically use its symbols; structural conversion bridges systems.
- **Dimension-aware output for free** — `Put`/`Put_Dim_Of`/`Image` splice the unit
  symbol at compile time (`490.50 m`, `98.10 m.s**(-1)` reproduced locally).

## Weaknesses

- **GNAT-only, standard-free** — the Ada standard has no dimensional analysis;
  code using these aspects is unportable to every other Ada compiler. One
  implementation, no spec beyond the vendor manual.
- **No dimensional polymorphism** — no unit variables, no principal types, no
  `sqr : α → α²`; only the base-type view-conversion idiom for same-dimension
  generics ([theory contrast][kennedy-types]).
- **Kind collapse in the shipped stdlib** — `Hz`/`Bq`, `Gy`/`Sv` are vector-equal and
  freely mixable (reproduced locally); torque = energy; no kind layer exists
  ([mp-units][mp-units] is the counterpoint).
- **No affine, logarithmic, or angular checking** — °C is Kelvin with a costume and a
  loose `273.15` constant; `rad`/`sr` are display-only; dB unrepresentable.
- **Hard 7-dimension ceiling** per system (`Max_Number_Of_Dimensions`).
- **Value-level unit constants are unchecked** — `km = 1.0E+03` is a convention;
  a wrong factor type-checks, as in every checking-not-conversion system.
- **Documentation drift** — the `sem_dim.ads` object-declaration claim is stale, and
  the feature's precise aggregate rules (`others` counting) are discoverable only by
  experiment or by reading the checker.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                 | Trade-off                                                                                             |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Implement in the compiler's semantic phase, as vendor aspects     | Real diagnostics, zero encoding machinery, works with predefined arithmetic               | GNAT lock-in; no standard, no second implementation, evolves at vendor speed                          |
| Dimensions on **subtypes** of one numeric type                    | No operator declarations for unit combinations; plain Ada subtyping and conversions apply | Subtypes are freely interconvertible, so all checking rides on the aspect channel; no new-type safety |
| Structural vector equality, names ignored                         | Cross-system conversion by position; renaming-proof checking                              | Kind distinctions (`Hz` vs `Bq`) are unrepresentable; vector-equal means interchangeable              |
| Fixed `ℚ⁷` vector per system                                      | Compact compiler tables; SI fits exactly; rational `Sqrt`/`**` exact                      | Hard 7-dimension ceiling; closed base set per system (vs F#'s open generators)                        |
| Vectors on AST nodes, erased as analysis ascends                  | True zero cost; no runtime artifact; assembly-identical output (verified)                 | Nothing survives to run time: no runtime queries, no reflection, unit-blind FFI                       |
| Literals dimensionless; comparisons warn-and-assume               | Usability: `T > 10.0` is too common to reject                                             | A class of real mismatches becomes a suppressible warning; stdlib itself must suppress it             |
| IO by compile-time call rewriting (`Expand_Put_Call_With_Symbol`) | Dimension-aware `Put`/`Image` with no runtime dimension data                              | Only the blessed `System.Dim.*_IO` packages get the treatment; user IO must pass symbols manually     |

## Sources

- [`gcc-mirror/gcc`][repo] pinned @ `8363c23` (sparse clone `$REPOS/ada/gcc`,
  `gcc/ada/` subtree) — [`sem_dim.ads`][sem-dim-ads] (model & phase comments L26–94,
  `Dimensions_Match` L198, `Eval_Op_Expon_For_Dimensioned_Type` L202,
  `Expand_Put_Call_With_Symbol` L210); [`sem_dim.adb`][sem-dim-adb] (`Rational` L63,
  `Max_Number_Of_Dimensions` L99, `Dimension_Type`/`Dimension_Table` L152–170,
  aspect analysis L578–863, binary-op checking L1377–1623, elementary-function/`Sqrt`
  handling L1655–1755, `Create_Rational_From` L2551, `"assumed to be"` L2767, IO
  expansion L3008+, `Remove_Dimensions` L3677); [`s-digemk.ads`][s-digemk] (the MKS
  `Dimension_System` and all SI subtypes/constants); [`s-dimmks.ads`][s-dimmks];
  [`s-diflio.ads`][s-diflio] (dimensioned IO contract).
- [GNAT Reference Manual — Implementation Defined Aspects][rm-live], entries "Aspect
  Dimension" and "Aspect Dimension_System" (aspect grammar, `RATIONAL` syntax, 7-max,
  integer-type restriction; local capture
  `vendor-docs/gnat-rm-implementation-defined-aspects.html`).
- [GNAT User's Guide §6.5 — Performing Dimensionality Analysis in GNAT][ugn-live]
  (`DV` rules, conversion semantics, generics idiom, free-fall example, documented
  error texts; local capture `vendor-docs/gnat-ugn-dimensionality-analysis.html`).
- Local reproductions (`mismatch.adb`, `freefall.adb`, `infosys.adb`, `rational.adb`,
  `edges.adb`, `objdim.adb`, `calc_dim.adb`/`calc_raw.adb` assembly diff) —
  `gnatmake -gnat2012`, GNAT 13.4.0 from nixpkgs, 2026-07-03.
- Related deep-dives in this survey: [type-system mechanisms][mechanisms] ·
  [Kennedy's type system][kennedy-types] (what inference would add) ·
  [free abelian group][fag] · [torsors (affine gap)][torsor] · [F#][fsharp-uom] ·
  [`uom-plugin`][uom-plugin] · [Boost.Units][boost-units] · [mp-units][mp-units] ·
  [Au][au] · [`uom` (Rust)][rust-uom] · [D `quantities`][d-quantities] ·
  [concepts][concepts] · [the comparison capstone][comparison].

<!-- References -->

<!-- Same-tree theory pages -->

[kennedy-types]: ./theory/kennedy-types.md
[fag]: ./theory/free-abelian-group.md
[mechanisms]: ./theory/type-system-mechanisms.md
[torsor]: ./theory/torsor-representation.md

<!-- Tree umbrella / concepts / comparison -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md

<!-- Sibling system pages -->

[fsharp-uom]: ./fsharp-uom.md
[uom-plugin]: ./haskell-uom-plugin.md
[boost-units]: ./cpp-boost-units.md
[mp-units]: ./cpp-mp-units.md
[au]: ./cpp-au.md
[rust-uom]: ./rust-uom.md
[d-quantities]: ./d-quantities.md

<!-- Pinned clone (gcc-mirror/gcc @ 8363c2392832a6600e49d4ac8361bf3e2052601b) -->

[repo]: https://github.com/gcc-mirror/gcc
[sem-dim-ads]: https://github.com/gcc-mirror/gcc/blob/8363c2392832a6600e49d4ac8361bf3e2052601b/gcc/ada/sem_dim.ads
[sem-dim-adb]: https://github.com/gcc-mirror/gcc/blob/8363c2392832a6600e49d4ac8361bf3e2052601b/gcc/ada/sem_dim.adb
[s-digemk]: https://github.com/gcc-mirror/gcc/blob/8363c2392832a6600e49d4ac8361bf3e2052601b/gcc/ada/libgnat/s-digemk.ads
[s-dimmks]: https://github.com/gcc-mirror/gcc/blob/8363c2392832a6600e49d4ac8361bf3e2052601b/gcc/ada/libgnat/s-dimmks.ads
[s-diflio]: https://github.com/gcc-mirror/gcc/blob/8363c2392832a6600e49d4ac8361bf3e2052601b/gcc/ada/libgnat/s-diflio.ads

<!-- Official docs (locally captured under vendor-docs/) -->

[rm-live]: https://gcc.gnu.org/onlinedocs/gnat_rm/Implementation-Defined-Aspects.html
[ugn-live]: https://gcc.gnu.org/onlinedocs/gnat_ugn/Performing-Dimensionality-Analysis-in-GNAT.html
