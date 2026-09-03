# `sparkles.base.custom_float` — Specification

_Audience: developers and coding agents building against `sparkles:base`. This
document is normative and self-contained — it states what a `CustomFloat` is,
how a value gets into and out of one, and what its operators mean. The
conversion kernel it is built on is specified in
[`float_conv`](./text/float-conv.md); this document only names what it takes
from there. For the library overview see
[`sparkles:base`](../../libs/base/index.md)._

## 1. Overview

D has `float`, `double` and `real`, and no type for the formats that machine
learning and graphics store tensors in: IEEE binary16, bfloat16, and the OCP
Microscaling element formats FP8 E5M2 / E4M3, FP6 E2M3 / E3M2 and FP4 E2M1.
`sparkles.base.custom_float` provides one **storage type per format**,
`CustomFloat!fmt`, holding exactly the format's interchange bits — 16, 8, 6
or 4 of them in the smallest unsigned integer — with:

- **the native types' vocabulary** — `mant_dig`, `max`, `min_normal`,
  `epsilon`, `infinity` and `nan` where the format has them — so generic
  code that reads a type's properties reads these;
- **one rounding per conversion** — a native value is decomposed exactly and
  rounded once into the format (`float` → `Float16` never goes through
  `double` on the way, and `long` → `Float16` never through a `real` that
  would have rounded it first), and `get!float` of a reduced value is the
  value itself;
- **arithmetic in a native type** — the narrowest of `float`/`double`/`real`
  that holds the format exactly, widened to the other operand's type when
  that is wider, the result stored back with one rounding;
- **text at the format's own width** — `readDecimalFloat!Float16` is
  correctly rounded at 11 bits, `writeShortest` prints the fewest digits
  that read back to the same bits.

It is modelled on Phobos' `std.numeric.CustomFloat` — the member names, the
"store only, compute natively" design, the `(precision, exponentWidth,
flags)` spelling — with its defects left out (§5). The format is data, not a
template of integers: `CustomFloat!binary16` is parameterized by the same
`BinaryFloatFormat` the conversion kernel runs on, so the type and the
reader/writer can never disagree about a bias or a special.

| Identifier      | Value                          |
| --------------- | ------------------------------ |
| Dub sub-package | `sparkles:base`                |
| Source root     | `libs/base/src/sparkles/base/` |
| Module          | `sparkles.base.custom_float`   |

## 2. API surface

```d
struct CustomFloat(BinaryFloatFormat fmt)          // storage ≤ 64 bits
{
    enum BinaryFloatFormat format;                  // what formatOf!T reads
    alias Bits;                                     // ubyte / ushort / uint / ulong
    alias Native;                                   // float for every reduced format
    enum mant_dig, min_exp, max_exp, dig, max_10_exp, min_10_exp;
    enum max, min_normal, epsilon, min_subnormal;   // and, where the format has them:
    enum infinity;  enum nan;
    Bits bits();  static CustomFloat fromBits(Bits raw);
    bool sign();  uint exponent();  Bits significand();
    DecodedFloat decoded();  static CustomFloat fromDecoded(DecodedFloat exact); // one rounding
    this(F)(F value);  opAssign(F)(F value);        // any float-like type or integer
    F get(F)();  alias opCast = get;                // exact when F holds the format
    Native opUnary!"+"();  CustomFloat opUnary!"-"();
    auto opBinary/opBinaryRight(op)(rhs);           // + - * / %, in typeof(Native op rhs)
    ref CustomFloat opOpAssign(op)(rhs);
    bool opEquals(F)(F rhs);  float opCmp(F)(F rhs); size_t toHash();
    void toString(Writer)(ref Writer w);            // writeShortest
}
alias Float16, BFloat16, Float8E5M2, Float8E4M3, Float6E2M3, Float6E3M2, Float4E2M1;
enum bool isCustomFloat(T);
template NativeOf(BinaryFloatFormat fmt);
enum CustomFloatFlags { signed, storeNormalized, allowDenorm, infinity, nan, ieee, none };
template CustomFloat(uint precision, uint exponentWidth, CustomFloatFlags flags = ieee);
```

`formatOf!T`, `readDecimalFloat!T`, `writeShortest!T`, `shortestDigits!T`,
`decompose!T`, `compose!T` and `slowFloat!T` in `float_conv` accept a
`CustomFloat` — or any type with `enum BinaryFloatFormat format`, `bits` and
`static fromBits` — through `isFloatLike!T`.

## 3. The formats (`CFL`)

| Type         | Format     | Layout     | Largest finite | Smallest normal | Smallest subnormal | Specials                                     |
| ------------ | ---------- | ---------- | -------------- | --------------- | ------------------ | -------------------------------------------- |
| `Float16`    | `binary16` | 1 + 5 + 10 | 65 504         | 2⁻¹⁴            | 2⁻²⁴               | `±inf`, NaN (IEEE 754-2008 binary16)         |
| `BFloat16`   | `bfloat16` | 1 + 8 + 7  | (2 − 2⁻⁷)·2¹²⁷ | 2⁻¹²⁶           | 2⁻¹³³              | `±inf`, NaN (the top half of a `float`)      |
| `Float8E5M2` | `fp8e5m2`  | 1 + 5 + 2  | 57 344         | 2⁻¹⁴            | 2⁻¹⁶               | `±inf` (`S.11111.00`), NaN                   |
| `Float8E4M3` | `fp8e4m3`  | 1 + 4 + 3  | 448            | 2⁻⁶             | 2⁻⁹                | NaN only (`S.1111.111`); `S.1111.110` is 448 |
| `Float6E2M3` | `fp6e2m3`  | 1 + 2 + 3  | 7.5            | 1               | 0.125              | none                                         |
| `Float6E3M2` | `fp6e3m2`  | 1 + 3 + 2  | 28             | 0.25            | 0.0625             | none                                         |
| `Float4E2M1` | `fp4e2m1`  | 1 + 2 + 1  | 6              | 1               | 0.5                | none                                         |

The FP8/FP6/FP4 values are the element-format tables of the OCP Microscaling
Formats (MX) Specification v1.0 (§5.3); the FP8 pair is also the one of
Micikevicius et al., _FP8 Formats for Deep Learning_ (2022). OCP's E8M0
scale type — no sign, no zero, NaN only — is not an interchange layout and is
not provided. `CustomFloat!binary32` and `CustomFloat!(formatOf!double)` are
admitted too: bit for bit a `float` and a `double`, which is how the
construction is tested against the FPU.

**Overflow.** A value past the largest finite one — from a native value,
an integer, another format or a decimal — becomes what the format can say:
`±infinity` for the three IEEE-shaped types; the NaN for `Float8E4M3` (what
PyTorch's `float8_e4m3fn` and Google's `ml_dtypes` do); the largest finite
value with the sign for the FP6 and FP4 types, which have nothing else. The
tie exactly halfway past `max` rounds to even like any other tie, which is
_up_ into the overflow answer for every all-ones format and _down_ to 448
for `Float8E4M3`, whose largest significand is even. A NaN assigned to a
format without one is a precondition violation (an assertion), as in Phobos.
Saturation reaches the writer too: since every decimal past a saturating
format's `max` reads back as `max`, its shortest spelling is the shortest
decimal that does — `Float6E2M3.max` prints `8e0`, `Float6E3M2.max` `3e1`.

**Arithmetic type.** `h op x` is computed in `typeof(Native op x)`: two
`Float16`s in `float`; `Float16 + double` in `double`, so the `double` is not
narrowed first — `Float16(1) + (2⁻¹¹ + 2⁻³⁵)` stored back is `1 + 2⁻¹⁰`, where
narrowing the operand to `float` first would have landed it on the midpoint
`1 + 2⁻¹¹` and broken the tie down to 1. Same-format arithmetic in `float` is
correctly rounded for `+ − × ÷` at every reduced width, `float` having at
least `2·mant_dig + 2` bits for each (binary16 sits exactly on that bound).

**Comparison.** `opEquals` is by value: `-0 == +0`, and a NaN equals nothing,
itself included. `opCmp` returns a `float` and `float.nan` when unordered, so
every ordering with a NaN operand is false — the native types' behaviour,
which Phobos' integer `opCmp` cannot express. `toHash` gives both zeros one
hash.

**`epsilon`** is a subnormal for `Float6E2M3` and `Float4E2M1`, whose
smallest normal is 1.

### Requirements

| ID     | Requirement                                                                                                                                                                                                          | Status  |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `CFL1` | `CustomFloat!fmt` must be its format's interchange bits and nothing else, with `bits`/`fromBits` the identity on every pattern and the padding above `storageBits` zero.                                             | full    |
| `CFL2` | Every conversion in — from `float`, `double`, `real`, another `CustomFloat`, or any integer — must round exactly once, ties to even, subnormals exact, matching the FPU's own narrowing cast.                        | full    |
| `CFL3` | `get!F` must be exact whenever `F` holds the format, and correctly rounded otherwise.                                                                                                                                | full    |
| `CFL4` | Overflow must follow the format's specials (`±inf` / NaN / largest finite), and the tie past `max` must round to even.                                                                                               | decided |
| `CFL5` | Mixed-type arithmetic and comparison must happen in `typeof(Native op rhs)`, never by narrowing the wider operand first.                                                                                             | full    |
| `CFL6` | `opEquals` must be by value (`-0 == +0`, `nan != nan`) and `opCmp` unordered on NaN, with a `toHash` consistent with `opEquals`.                                                                                     | full    |
| `CFL7` | The properties `mant_dig`, `min_exp`, `max_exp`, `dig`, `max_10_exp`, `min_10_exp`, `max`, `min_normal`, `epsilon` must equal the native type's on `CustomFloat!binary32`, and the OCP tables' on the reduced types. | full    |
| `CFL8` | Construction, conversion and the text round trip must run at CTFE with results bit-identical to runtime.                                                                                                             | full    |

## 4. Example

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "custom_float_tour"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writefln;
import sparkles.base.custom_float;

void main()
{
    Float16 h = 0.1f;                       // one rounding: 0.0999755859375
    writefln("%04X  %s  %.13g", h.bits, h, h.get!float);
    writefln("%02X  %s", Float8E4M3(1000).bits, Float8E4M3(1000)); // no infinity: NaN
    writefln("%X  %s", Float4E2M1(7).bits, Float4E2M1(7));          // no NaN either: saturates
    writefln("%s", (h + h) * 3 == 0.599853515625f);                   // arithmetic in float
}
```

```ansi
2E66  1e-1  0.0999755859375
7F  nan
7  6e0
true
```

## 5. What was taken from Phobos, and what was not

Kept: the member names of the native types (`mant_dig` … `min_normal`), the
raw `sign`/`exponent`/`significand` accessors, `get!F`/`opCast`, construction
and assignment from any real-compatible type, arithmetic by extraction to a
native type, and the `CustomFloat!(precision, exponentWidth, flags)` spelling
with Phobos' default bias `2^(exponentWidth − 1) − 1` (`CustomFloat!(10, 5)`
is `Float16`; `CustomFloat!(3, 4, ieee ^ infinity)` is `Float8E4M3`). The
`(precision, exponentWidth, flags)` overload accepts the flag combinations a
`BinaryFloatFormat` expresses — signed, normalised, with subnormals — and
rejects the rest at compile time.

Left out, each pinned by a test:

- `(sign + precision + exponentWidth) % 8 == 0` — Phobos cannot name a 6- or
  4-bit format at all.
- `roundedShift` sets a shift of 64 or more to zero and, for subnormal
  results, shifts by one and then by the rest, rounding twice — a value
  three quarters of the way to the smallest subnormal comes out as 0 there
  and as the smallest subnormal here.
- Overflow in a format without infinity is `assert(0)` in Phobos; here it is
  the format's rule.
- `real opBinary(...)` returns `real` for everything; here the result is the
  type D would compute in, so a `double` operand keeps its width and a
  `float` operand does not pay for `real`.
- `int opCmp` makes `nan <= x` true; here `opCmp` returns a `float`.
- NaN-only formats (E4M3) are inexpressible in Phobos' flag model, whose
  `nan` flag reserves the whole top exponent field.

`sparkles:wired`'s serialisers dispatch on `std.traits.isFloatingPoint` and do
not yet know these types; a schema-level float kind for them is a separate
piece of work.

## 6. Verification

```bash
dub test :base -- -i CustomFloat                                          # everything below
dub test :base                                                            # with float_conv's own pins
nix run .#ci -- --verify --files docs/specs/base/custom-float.md          # the example above
```

- `CFL1`: `CustomFloat.widenIsExact` (every pattern of every ≤16-bit format
  → `float` → back), `CustomFloat.properties` (the raw accessors).
- `CFL2`: `CustomFloat.conversionPins` (the one-rounding pins, integers,
  between formats), `CustomFloat.matchesNativeBits` (`CustomFloat!binary32`
  from 200 k doubles against `cast(float)`, `CustomFloat!(formatOf!double)`
  against `doubleToBits`), `CustomFloat.agreesWithPhobos` (`std.numeric`'s
  `CustomFloat!(10, 5)` over the normal range — where it is right).
- `CFL3`: `CustomFloat.widenIsExact`, `CustomFloat.conversionPins`.
- `CFL4`: `CustomFloat.conversionPins`, `CustomFloat.everyMidpointParses`
  (the threshold of every format).
- `CFL5`/`CFL6`: `CustomFloat.operators`.
- `CFL7`: `CustomFloat.properties`.
- `CFL8`: the `static assert`s throughout, and `CustomFloat.readAndWrite`.
- The text round trip and its shortness: `CustomFloat.shortestIsShortest`,
  `CustomFloat.toString`, `CustomFloat.agreesWithBigIntOracle` — see
  [`float_conv` §7](./text/float-conv.md#7-verification).

---

→ [`float_conv`](./text/float-conv.md) — the kernel: `BinaryFloatFormat`, the tiers, `encode`/`decode`/`roundTo`
→ [buffer](./buffer.md) — sibling `sparkles:base` specification
