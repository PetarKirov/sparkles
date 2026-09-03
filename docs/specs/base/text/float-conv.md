# `sparkles.base.text.float_conv` — Specification

_Audience: developers and coding agents building against `sparkles:base`. This
document is normative and self-contained — it states what the module guarantees
when converting decimal text to `float`, `double` or `real` and back. It is a
format-agnostic text primitive with no grammar opinions beyond the decimal
literal itself; the `sparkles:wired` JSON engine
([SPEC §11](../../wired/SPEC.md#11-the-native-json-engine)) and its SDL codec
([SDL SPEC §9](../../wired/sdl/SPEC.md#9-canonical-semantic-writer)) are its
consumers. For the library overview see
[`sparkles:base`](../../../libs/base/index.md)._

## 1. Overview

`sparkles.base.text.float_conv` converts between decimal text and IEEE-754
binary floating point **exactly** in both directions, for every format
`float`, `double` or `real` takes across this repository's targets (binary32,
binary64, x87 extended80, binary128) and for the reduced-precision formats D
has no type for — IEEE binary16, bfloat16 and the OCP Microscaling FP8 E5M2 /
E4M3, FP6 E2M3 / E3M2 and FP4 E2M1 element formats, carried by the storage
types of [`sparkles.base.custom_float`](../custom-float.md) — through one
format-parameterized kernel:

- **Parse** — the returned value is always the correctly-rounded
  (round-to-nearest, ties-to-even) value of the full decimal, no matter how
  many digits the input carries.
- **Format** — the emitted text is the _shortest_ decimal string that
  re-parses to the identical bit pattern.

The format is data, not a type (`BinaryFloatFormat`, §2): a kernel
parameterized by it can be exercised at 113 bits on a host whose `real` has
53, which is how the binary128 path is verified on every machine rather than
only on the one that has it.

| Identifier      | Value                               |
| --------------- | ----------------------------------- |
| Dub sub-package | `sparkles:base`                     |
| Source root     | `libs/base/src/sparkles/base/text/` |
| Module          | `sparkles.base.text.float_conv`     |

## 2. API surface

```d
// The target format as data (§3), and a value as integers, for any format:
struct BinaryFloatFormat { int mantDig, minExp, maxExp; Specials specials = ieee; /* + derived: */
    int maxDigits10(); int exactPow10Max(); int maxExactDigits(); int decimalCapacity();
    int saturateHighExp10(); int saturateLowExp10(); long explicitExp10Bound(size_t digitSpan);
    int bias(); int expBits(); int mantBits(); int storageBits(); bool hasInfinity(); bool hasNaN();
    ulong maxFiniteSignificand(); int dig(); int max10Exp(); int min10Exp();
    enum Specials { ieee, nanOnly, none } }         // how the top exponent field is spent
enum binary32, binary64, extended80, binary128;   // every format `real` takes here
enum binary16, bfloat16, fp8e5m2, fp8e4m3, fp6e2m3, fp6e3m2, fp4e2m1; // the reduced formats
enum bool isFloatLike(T);                         // native, or `format`/`bits`/`fromBits`-bearing
template formatOf(T);                             // a float-like type's format
template BitsOf(BinaryFloatFormat fmt);           // ubyte/ushort/uint/ulong by storageBits
struct DecodedFloat { ulong hi, lo; int exp2; bool negative, isInf, isNaN; }
DecodedFloat slowDecode(BinaryFloatFormat fmt)(scope const(char)[] intDigits,
                  scope const(char)[] fracDigits, int explicitExp10);
size_t       shortestDigits(BinaryFloatFormat fmt)(in DecodedFloat v,
                  scope char[] digitBuf, out int exp10);      // digitBuf ≥ maxDigits10
DecodedFloat decompose(T)(T value);                            // exact
T            compose(T)(DecodedFloat d);
DecodedFloat roundTo(BinaryFloatFormat fmt)(DecodedFloat exact, out bool halfway); // one RNE rounding
BitsOf!fmt   encode(BinaryFloatFormat fmt)(DecodedFloat d);    // IEEE interchange bits, storage ≤ 64
DecodedFloat decode(BinaryFloatFormat fmt)(BitsOf!fmt bits);

// Building blocks for fused grammar loops (e.g. a JSON number scanner):
size_t readDigits(uint maxDigits = 19)(scope const(char)[] s, ref ulong sig);
size_t readDigits(scope const(char)[] s, ref ulong sig, size_t maxDigits);
bool   tryFastDouble(ulong sig10, int exp10, out double result);
double slowDouble(scope const(char)[] intDigits,
                  scope const(char)[] fracDigits, int explicitExp10);
T      slowFloat(T)(scope const(char)[] intDigits,
                  scope const(char)[] fracDigits, int explicitExp10);

// Cursor-style reader for the general decimal-literal grammar, any float-like T:
ParseExpected!T readDecimalFloat(T = double)(ref scope const(char)[] s);

// Shortest round-trip formatting:
size_t formatShortestDouble(scope char[] buf, double value); // buf.length ≥ 40
void   writeShortestDouble(Writer)(ref Writer w, double value);
size_t shortestDigits(T)(T value, scope char[] digitBuf, out int exp10); // any float-like T
void   writeShortest(T, Writer)(ref Writer w, T value);      // [-]d[.ddd]e[-]x

// IEEE-754 bit access (CTFE-safe both ways):
ulong  doubleToBits(double d);
double bitsToDouble(ulong bits);
```

The wide formats' fast tier (`decodeWide`, `tryFastWide`, the anchor table)
is private: `readDecimalFloat!real` is its surface.

## 3. Parse guarantees (`PRS`)

`readDecimalFloat` accepts the grammar
`[-]digits[.digits][(e|E)[±]digits]` and advances the cursor past the
literal on success. Its result is decided by tiers, fastest first —
**every tier is exact**, so callers never observe a tier boundary. Which
tiers a format has:

| `formatOf!T`                                                                                    | tier 1                          | tier 2                                                       | exact tier              |
| ----------------------------------------------------------------------------------------------- | ------------------------------- | ------------------------------------------------------------ | ----------------------- |
| `binary64` — `double`, and `real` where it is                                                   | Clinger, in `double` arithmetic | Eisel–Lemire, 64 × 128 bits; bracketing past 19 digits       | `slowDouble`            |
| `binary32` — `float`                                                                            | Clinger, in `float` arithmetic  | narrowing: the `double` result rounded once more             | `slowDecode!binary32`   |
| `binary16`, `bfloat16`, `fp8e5m2`, `fp8e4m3`, `fp6e2m3`, `fp6e3m2`, `fp4e2m1` — a `CustomFloat` | —                               | narrowing, as for `float`                                    | `slowDecode!fmt`        |
| `extended80` — `real` on x86_64                                                                 | Clinger, in `real` arithmetic   | wide Eisel–Lemire, 128 × 128 bits; bracketing past 38 digits | `slowDecode!extended80` |
| `binary128` — `real` on AArch64 Linux, Android                                                  | Clinger, in `real` arithmetic   | wide Eisel–Lemire, 128 × 128 bits; bracketing past 38 digits | `slowDecode!binary128`  |
| double-double (`mant_dig == 106`)                                                               | —                               | —                                                            | `static assert`         |

1. **Clinger fast path** — when the significand fits the mantissa and the
   power of ten is exactly representable (`|exp10| ≤ exactPow10Max`: 10, 22,
   27, 48), one FP multiply or divide is correctly rounded by construction.
   Skipped at CTFE for every format, so compile-time results flow through the
   integer tiers.
2. **Eisel–Lemire** — a wide multiply against a precomputed power-of-ten
   significand table settles almost every remaining case in pure integer
   arithmetic. Cases it cannot _prove_ (true ties, subnormal results,
   overflow boundaries, table-truncation ambiguity) fall through. For
   `double` this is the Go `strconv` formulation over a 19-digit `ulong`
   significand. For the wide formats it is the same idea over a 38-digit
   128-bit significand and a 256-bit product (below).
3. **Exact big-decimal fallback** (`slowDecode`) — an arbitrary-precision
   decimal in fixed storage sized by the format, with a sticky truncation
   bit, scaled by exact power-of-two shifts; settles every remaining input
   with exact ties-to-even information.

Inputs with more significant digits than the tier-2 significand holds are
first decided by _bracketing_: when the truncated significand and its
successor both round to the same value, that value is proven correct without
the exact tier.

**The narrowing tier** (every format below 53 bits) takes the
correctly-rounded `double` of the literal and rounds it once more with
`roundTo`. Every rounding boundary of such a format — the midpoints between
neighbours, half the smallest subnormal, the overflow threshold — is itself a
`double`, and the correctly-rounded `double` lies within half of its own ulp
of the literal, so the two sit on the same side of every boundary unless the
`double` _is_ one. `roundTo` reports that case as an exact half, and it takes
the exact tier: the `double` could be a true tie or the literal a hair to
either side, and the classic `(float) strtod(s) != strtof(s)` is exactly a
cast that breaks such a tie without looking. Shortest spellings land on a
midpoint more often than random input does (Steele–White emits the midpoint
for an even significand when it is the shortest — about 1.6 % of binary16's
values, 3 % of E4M3's), and those spellings read correctly through the exact
tier.

**The explicit exponent is bounded by the literal, not by a constant.** A
literal's combined decimal exponent is the explicit one plus a digit-position
offset of at most the digit span, so `readDecimalFloat` clamps the explicit
exponent at `explicitExp10Bound(digitSpan)` — past which the value saturates
whatever the digits say — and never earlier. A fixed clamp (the old 400)
misread `0.<500 zeros>1e800` as 1e-101 and, on the wide formats, `1e500` as
1e400.

**Saturation policy** — magnitudes at or above `2^maxExp` overflow: to
`±infinity` where the format has one, to its NaN where it has only that
(E4M3, as PyTorch's `float8_e4m3fn` and `ml_dtypes` do), to the largest
finite value with the sign where it has neither (FP6, FP4). Positive
magnitudes below half the smallest subnormal become `±0`. Subnormals are
fully supported (`5e-324` parses to bit pattern `1`).
`saturateHighExp10`/`saturateLowExp10` (40/−47, 310/−325, 4934/−4952,
4934/−4967) are the point positions past which a decimal is decided by
saturation alone.

### Infinity-less formats

`BinaryFloatFormat.specials` says how the top exponent field is spent: `ieee`
reserves it (a zero significand is `±infinity`, anything else NaN), `nanOnly`
keeps it finite except for the all-ones significand, the single NaN, and
`none` keeps every pattern finite. The layout derivations follow: the bias is
`2 − minExp`, the exponent field holds `maxExp − minExp + 3` values (`+ 2`
without the reserved field), and the largest finite significand is all ones,
or one below that under `nanOnly` — E4M3's top pattern `S.1111.111` is its
NaN, so a decoded 480 is overflow, not a value, and the tie at 464 rounds
_down_ to 448 (whose significand is even) where every all-ones format's tie
past its maximum rounds up. `encode` is where the overflow rule lives; the
decoders never see it.

| format     | mantDig | minExp | maxExp | specials  | bits | bias | largest finite | smallest subnormal |
| ---------- | ------- | ------ | ------ | --------- | ---- | ---- | -------------- | ------------------ |
| `binary16` | 11      | −13    | 16     | `ieee`    | 16   | 15   | 65 504         | 2⁻²⁴               |
| `bfloat16` | 8       | −125   | 128    | `ieee`    | 16   | 127  | (2 − 2⁻⁷)·2¹²⁷ | 2⁻¹³³              |
| `fp8e5m2`  | 3       | −13    | 16     | `ieee`    | 8    | 15   | 57 344         | 2⁻¹⁶               |
| `fp8e4m3`  | 4       | −5     | 9      | `nanOnly` | 8    | 7    | 448            | 2⁻⁹                |
| `fp6e2m3`  | 4       | 1      | 3      | `none`    | 6    | 1    | 7.5            | 0.125              |
| `fp6e3m2`  | 3       | −1     | 5      | `none`    | 6    | 3    | 28             | 0.0625             |
| `fp4e2m1`  | 2       | 1      | 3      | `none`    | 4    | 1    | 6              | 0.5                |

OCP's E8M0 scale type (no sign, no zero, NaN only) is not a
`1 + expBits + mantBits` layout and is out of scope.

### The wide tier

`tryFastWide!fmt` decides `sig × 10^q` for a significand of up to 38 digits
(`sig < 2^127`) with one 256-bit product:

- The significand normalized to `[2^127, 2^128)` times a 128-bit entry
  `E` with `10^q ∈ [E, E + width) × 2^e` is a **lower bound** of the true
  product, short by less than `width` entry units times the significand —
  under `2^128 × width` — so only the bottom 128 bits are uncertain plus a
  carry of at most `width` into the top half (twice that after the one
  normalizing shift).
- The top `p` bits of the top half are the mantissa, the next bit the round
  bit, and the `127 − p` bits below it (63 at x87, 14 at binary128) a guard
  window. The case is proven unless a carry could reach the round bit, or
  the tail could be exactly one half with the mantissa even — the tie the
  product cannot tell from just above it. Overflow is decided (a lower
  bound past `2^maxExp` is conclusive); a subnormal result punts, so the
  exact tier rounds at the format's floor.
- **Entries.** The fine table covers `q ∈ [−343, 324]` with `width = 1`.
  The wide formats need `[−5005, 4933]` — every `q` a 38-digit significand
  can carry without the verdict being saturation alone. Twenty-nine
  CTFE-generated anchors, `10^(324·j)` for `j = 1..15` and `10^(−343·j)`
  for `j = 1..14`, each stored with the exact exponent of its big integer,
  compose with a fine entry into a normalized 128-bit entry of `width = 5`
  for the rest of the range. The fixed-point exponent formula the fine table
  uses is exact only on the fine range (it first drifts at `|q| = 643`),
  which is why composed entries carry the exponent their product actually
  has.
- **Punt rate.** Under 1 % of shortest spellings, and about `(width + 1) ·
2^(p − 127)` of random inputs — 4 in 2^14 at binary128 in the fine range,
  12 in 2^14 in the composed range — go to the exact tier; the subnormal
  band (`1e-4932 … 1e-4966`) always does.
- **Result shape.** The tier returns a `DecodedFloat` — significand `hi:lo`,
  exponent of its last bit, the overflow verdict — and the existing exact
  `compose!T` turns it into the native value by power-of-two scaling, so no
  bit assembly was added.

### Any format

- **The exact tier is one kernel.** `slowDecode!fmt` is `slowDouble`'s
  algorithm with its four `double`-specific parts derived from the format —
  the saturation bounds, the normal-exponent clamps, the significand readout
  (128 bits wide, since 113 do not fit a `ulong`) and the big-decimal
  storage. Storage must track the format: decimal truncation is
  order-preserving, so a value is decided correctly once the rounding tie it
  is compared against expands completely inside the buffer, and binary128's
  ties run to 11 564 digits. `decimalCapacity` is 200 / 800 / 11 600 / 11 600
  — 800 being what `slowDouble` always had.
- **`float` is not the `double` result cast down.** A decimal a hair below
  a `float` midpoint rounds onto it as a `double`, and the tie then breaks to
  even — the classic `(float) strtod(s) != strtof(s)`. Clinger's division
  side runs in `float` for the same reason.
- **The result is integers first.** `slowDecode` and `tryFastWide` return a
  `DecodedFloat`, and `compose!T` turns it into a native value by exact
  power-of-two scaling (no bit punning: D has no portable `realToBits`, and
  x87's explicit integer bit makes synthesis format-specific). `decompose!T`
  is the inverse. Both run at CTFE, accept a `const` argument, and use
  nothing from Phobos. A storage type (`isFloatLike`: `enum format`, `bits`,
  `static fromBits`) goes through `decode`/`encode` instead — the IEEE
  interchange layout, which every format whose storage fits 64 bits has.
- **Between formats, one rounding.** `roundTo!fmt` rounds an exact
  `DecodedFloat` — up to 113 significand bits, any exponent — to a format
  with ties to even, the last bit pinned at the format's floor, a carry out
  of an all-ones significand moving up a binade, overflow as `isInf`, and a
  value below half the smallest subnormal (however far below) to zero. Over
  `decompose` it is the one rounding of every native → reduced conversion,
  where a chain of casts rounds twice; the FPU's own `cast(float)` is the
  oracle it is pinned against.
- **Environment.** The fast tier and `compose` are floating-point arithmetic
  and assume round-to-nearest-even with traps masked;
  `std.math.hardware.FloatingPointControl` can change both and this module
  does not defend against it. The integer tiers do not care.
- **Stack.** The decoder's digits live in its frame — 11.6 KB at binary128 —
  and a druntime `Fiber`'s default stack is 16 KiB on 4 KiB-page Linux.
  Both directions at `real.max`'s magnitude are tested to fit a 32 KiB
  fiber in the unoptimized test build, whose frames are about twice the
  shipping build's; give a fiber that decodes wide `real`s room. The wide
  tier adds a few hundred bytes.

### Requirements

| ID      | Requirement                                                                                                                                                                                                 | Status  |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `PRS1`  | `readDecimalFloat!T` must return the correctly-rounded (ties-to-even) value of the full literal for `float`, `double` and `real` at binary64, extended80 and binary128, however many digits it has.         | full    |
| `PRS2`  | Every tier must be exact: a fast tier returns a value only when it can prove it is the correctly-rounded one, and punts otherwise.                                                                          | full    |
| `PRS3`  | The explicit exponent must be bounded by `explicitExp10Bound(digitSpan)` and never by a fixed magnitude; a run of zeros paid for by the exponent decodes to the value it names.                             | full    |
| `PRS4`  | Magnitudes at or past `2^maxExp` must read as `±infinity`, and positive magnitudes below half the smallest subnormal as `±0`; subnormals must be exact.                                                     | full    |
| `PRS5`  | The wide formats must have a fast tier that decides typical spellings (21 digits at x87, 36 at binary128) without the exact tier, over the whole exponent range they can carry.                             | full    |
| `PRS6`  | The exact tier must agree with an independent big-integer oracle at 24, 53, 64 and 113 bits, and with libc on hosts that have a correctly-rounded one.                                                      | full    |
| `PRS7`  | `float` must be read at its own width, never as a narrowed `double`.                                                                                                                                        | full    |
| `PRS8`  | `compose ∘ decompose` must be the identity, bit for bit, for every finite value of every type, and `compose` over `slowDecode!binary64` must land on `slowDouble`'s bits.                                   | full    |
| `PRS9`  | Both directions at `real.max`'s magnitude must run on a 32 KiB fiber in the unoptimized test build.                                                                                                         | full    |
| `PRS10` | Double-double `real` is rejected at compile time rather than mis-decoded.                                                                                                                                   | full    |
| `PRS11` | The fast tier and `compose` assume the default floating-point environment; the module does not defend against `FloatingPointControl`.                                                                       | decided |
| `PRS12` | The subnormal band of the wide formats takes the exact tier; a `p'`-bit variant of the wide tier for it is a follow-up, not a v1 requirement.                                                               | decided |
| `PRS13` | `readDecimalFloat!T` must be correctly rounded for every storage type of every reduced format — binary16, bfloat16, E5M2, E4M3, E2M3, E3M2, E2M1 — however many digits the literal has.                     | full    |
| `PRS14` | The narrowing tier must decide only when the correctly-rounded `double` is not on a rounding boundary of the target format, and must punt on every exact half.                                              | full    |
| `PRS15` | Overflow must follow the format's specials: `±infinity` under `ieee`, the NaN under `nanOnly`, the largest finite value under `none`; a `nanOnly` format's all-ones top pattern is overflow, never a value. | decided |
| `PRS16` | `decode ∘ encode` must be the identity over every pattern of every format whose layout fits 64 bits, and `roundTo ∘ decompose` must agree with the FPU's narrowing cast bit for bit.                        | full    |

## 4. Format guarantees (`FMT`)

`formatShortestDouble` renders the shortest decimal representation that
re-parses to the identical bits (Schubfach, with a full-precision fast
path), and returns the number of characters written:

- **Round-trip**: `readDecimalFloat(formatShortestDouble(x)) == x`
  bit-exactly, for every finite `double` including subnormals and `-0.0`.
- **Shortest**: no representation with fewer significant digits
  round-trips.
- **Notation** (ECMAScript `Number.prototype.toString()` with two
  deviations): plain notation while the decimal point offset lies in
  `(-6, 21]`, scientific (`d.ddde±X`) outside; `-0.0` keeps its sign; and
  integral values keep a trailing `.0` (`"1234.0"`) so the text stays
  unambiguously floating-point.
- Non-finite values render as `nan` / `inf` / `-inf`; callers with
  stricter grammars (JSON) must reject them upstream.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "float_conv_round_trip"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writefln;
import sparkles.base.text.float_conv;

void main()
{
    char[40] buf;
    foreach (v; [0.1, 1.0 / 3.0, 1e20, 1e21, double.min_normal * double.epsilon, -0.0])
    {
        const len = formatShortestDouble(buf[], v);
        const(char)[] text = buf[0 .. len];
        auto back = readDecimalFloat(text);
        writefln("%-24s round-trips: %s", buf[0 .. len],
            doubleToBits(back.value) == doubleToBits(v));
    }
}
```

```ansi
0.1                      round-trips: true
0.3333333333333333       round-trips: true
100000000000000000000.0  round-trips: true
1e21                     round-trips: true
5e-324                   round-trips: true
-0.0                     round-trips: true
```

### Any format

`shortestDigits!fmt` renders a `DecodedFloat` as the fewest significant
digits any correctly-rounded reader maps back to it, with the exponent of the
last digit — Steele & White's free-format algorithm as Burger & Dybvig state
it, over exact big integers sized by the format:

- **No reader is consulted.** The value and its rounding interval share one
  denominator; digits come off one at a time, and the first prefix whose
  round-down or round-up lands inside the interval is provably the shortest.
  The interval is inclusive iff the significand is even (what
  round-half-even makes true), a power-of-two significand above the smallest
  normal has a quarter ulp below, and of two prefixes both inside the nearer
  wins with an exact tie to the even digit — Schubfach's conventions, so on
  `double` the digits agree with `formatShortestDouble` exactly.
- `shortestDigits!T` decomposes a native value first; `writeShortest`
  renders any type as `[-]d[.ddd]e[-]x` plus `nan`/`inf`/`-inf` — **always
  scientific**. A consumer whose grammar has no exponent expands it: the SDL
  writer turns `1.189…e4932` into a 4 933-digit token
  ([SDL SPEC §9](../../wired/sdl/SPEC.md#9-canonical-semantic-writer)).
  `formatShortestDouble` keeps Schubfach and its own notation for the JSON
  hot path.
- The result never exceeds `maxDigits10` digits (9 / 17 / 21 / 36; 5, 4, 2,
  3, 3, 2, 2 for the reduced formats), and is often shorter: `real.max` at
  binary128 is 34 digits.
- At the reduced widths the guarantee is proven by enumeration rather than
  sampling: every finite value of every ≤16-bit format round-trips through
  its shortest spelling, and every spelling with fewer significant digits
  inside its rounding interval is read and shown to land elsewhere.
- **The reader is this module's, saturation included.** A format with
  neither infinity nor NaN maps every decimal past its largest value back to
  that value, so that value's rounding interval has no end above it and its
  shortest spelling is the shortest decimal that saturates to it: `8e0` for
  `Float6E2M3.max` (7.5), `3e1` for `Float6E3M2.max` (28). E4M3's 448 keeps
  its half-ulp interval, since past 464 the reader gives NaN.

### Requirements

| ID     | Requirement                                                                                                                                                                                  | Status  |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `FMT1` | `formatShortestDouble` must round-trip every finite `double`, `-0.0` and subnormals included, bit for bit, and no spelling with fewer significant digits may.                                | full    |
| `FMT2` | `formatShortestDouble` must follow ECMAScript notation except for the signed zero and the trailing `.0`, and render non-finite values as `nan`/`inf`/`-inf`.                                 | full    |
| `FMT3` | `shortestDigits!fmt` must produce, for every format, the shortest digits this module's correctly-rounded reader — its overflow rule included — maps back to the value, consulting no reader. | full    |
| `FMT4` | On `double`, `shortestDigits` must agree with Schubfach digit for digit.                                                                                                                     | full    |
| `FMT5` | `writeShortest` renders every type in scientific notation; expansion to an exponent-free grammar is the consumer's.                                                                          | decided |
| `FMT6` | A result never exceeds `maxDigits10` digits.                                                                                                                                                 | full    |
| `FMT7` | Every finite value of every reduced format must round-trip through `writeShortest`, and no spelling with fewer significant digits may read back to it.                                       | full    |

## 5. Tables and CTFE (`CTF`)

One CTFE-generated fine table serves both directions: for each `q` in
`[-343, 324]`, the top 128 bits of `10^q` normalized to `[2^127, 2^128)`
and **truncated** (the yyjson convention; the Schubfach writer applies its
own ceiling adjustment). The 29 anchors of the wide tier are the same
routines over `5^(324j)` and `5^(−343j)`, with a limb capacity sized for
`5^4860`. Generation is exact big-integer arithmetic at compile time — there
is no external generator step to keep in sync.

`readDigits`, `tryFastDouble`, `slowDouble`, `slowDecode`, `slowFloat`,
`readDecimalFloat`, `decompose`, `compose`, `roundTo`, `encode`, `decode`,
`shortestDigits`, `doubleToBits`, and `bitsToDouble` are CTFE-callable; the Clinger tier is skipped at compile
time so results flow through the deterministic integer tiers, and tests pin
CTFE results bit-identical to runtime ones — including a binary128 decode
through the wide tier and a binary64 shortest rendering settled entirely at
compile time. `formatShortestDouble` is runtime-only (pointer-based digit
rendering).

The anchors cost a forced debug rebuild of `sparkles:base` about half a
second, measured with `dub build :base --force` on LDC 1.42: 1.48 s → 1.83 s
on an Apple M4 Max, 3.43 s → 3.99 s on an AMD Ryzen 9 7940HX (inside
`nix develop -c`, three runs each).

### Requirements

| ID     | Requirement                                                                                                                                                                                                                                                                                                                                | Status  |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------- |
| `CTF1` | Every power-of-ten entry — fine or anchor — must bracket the true power: `E·2^e ≤ 10^q < (E + width)·2^e`, by exact big-integer arithmetic.                                                                                                                                                                                                | full    |
| `CTF2` | The functions listed above must be CTFE-callable, with results bit-identical to runtime.                                                                                                                                                                                                                                                   | full    |
| `CTF3` | The tables are generated at compile time from exact arithmetic; no generated source is checked in.                                                                                                                                                                                                                                         | decided |
| `CTF4` | The module must stay importable without druntime (`-betterC` consumers of the digit writers).                                                                                                                                                                                                                                              | full    |
| `CTF5` | `encode`, `decode` and `roundTo` must run at CTFE with results bit-identical to runtime; `compose`, `encode` and `roundTo` take their `DecodedFloat` by value because LDC 1.42's interpreter crashes reading a `bool` field through an `in` reference to a struct another CTFE call returned (in this package's full unittest build only). | decided |

## 6. Cost

`dub test :base -b bench -- --bench -i float_conv.bench --group-by=format`,
medians per call. Apple M4 Max, LDC 1.42, macOS; and the x86_64 host where
`real` is extended80: AMD Ryzen 9 7940HX, the devshell's LDC, Linux.

| format     | tier         | input                 | M4 Max |  7940HX |
| ---------- | ------------ | --------------------- | -----: | ------: |
| binary64   | fast         | `2.99792458`          | 1.6 ns |  3.3 ns |
| binary64   | Schubfach    | `1.5599`              | 8.6 ns | 13.7 ns |
| binary64   | exact        | 22 digits near 1      | 187 ns |  216 ns |
| binary64   | exact        | `double.max` spelling |  21 µs |   17 µs |
| binary64   | Steele–White | near 1.5              | 365 ns |  406 ns |
| extended80 | fast (wide)  | 20 digits near 1      |  26 ns |   13 ns |
| extended80 | fast (wide)  | `1.19e4932`, composed |  29 ns |   19 ns |
| extended80 | exact        | 20 digits near 1      | 342 ns |  354 ns |
| extended80 | exact        | `1.19e4932`           | 4.3 ms |  2.7 ms |
| extended80 | exact        | `3.36e-4932`          | 1.9 ms |  2.7 ms |
| extended80 | Steele–White | `real.max`            | 114 µs |  117 µs |
| binary128  | fast (wide)  | 20 digits near 1      |  27 ns |       — |
| binary128  | fast (wide)  | `1.19e4932`, composed |  29 ns |       — |
| binary128  | exact        | 20 digits near 1      | 385 ns |       — |
| binary128  | exact        | `1.19e4932`           | 4.2 ms |       — |
| binary128  | Steele–White | `real.max`            | 154 µs |       — |
| binary32   | narrowing    | `3.14159265358979`    |  33 ns |   43 ns |
| binary32   | exact        | `3.14159265358979`    | 114 ns |  124 ns |
| binary16   | narrowing    | `3.14159`             |  23 ns |   51 ns |
| binary16   | exact        | `3.14159`             |  51 ns |   73 ns |
| binary16   | Steele–White | `0.1`                 |  28 ns |   33 ns |
| fp8e4m3    | narrowing    | `3.5`                 |  19 ns |   48 ns |

The narrowing rows time the whole `readDecimalFloat`, grammar included, and
the exact rows `slowFloat` on the same digits. The exact tier's cost at the
exponent extremes is the bound for untrusted input: a value the wide tier punts — the subnormal band, or one of the
2^-14-scale window cases — costs milliseconds per token there. The typical
`real` spelling, at any exponent, costs tens of nanoseconds.

## 7. Verification

```bash
dub test :base                                                           # every pin and differential below
dub test :base -- -t 1                                                   # the 512 KiB worker stack
dub test :base -b bench -- --bench -i float_conv.bench --group-by=format # §6
dub test :base -- --better-c                                             # CTF4
nix run .#ci -- --verify --files docs/specs/base/text/float-conv.md      # the example above
```

Each requirement is pinned by named tests in `float_conv.d`:

- `PRS1`/`PRS2`: `readDecimalFloat.grammar`, `.typed`, `.wideDigits`,
  `.roundTripsShortestReal`; the libc differentials
  `readDecimalFloat.differentialVsStrtod` (20 k literals, zero runs
  included), `.floatDifferentialVsStrtof`, `slowDecode.binary32DifferentialVsStrtof`
  on every Posix host, and `readDecimalFloat.realDifferentialVsStrtold` on
  Linux (glibc, 20 k literals of up to 38 digits, exponents to ±5200);
  `tryFastWide.agreesWithSlowDecode` (a stratified 44 k-case corpus per
  width, decision rate ≥ 99 % outside the subnormal band),
  `tryFastWide.agreesWithBigIntOracle`, `tryFastWide.pins`,
  `decodeWide.digitsAndBracketing`.
- `PRS3`: `readDecimalFloat.grammar` (the zero-run literals),
  `BinaryFloatFormat.derivations` (the bounds); the JSON reader's
  `reader.numbers.pins` carries the same literals.
- `PRS4`: `tryFastDouble.pins`, `slowDouble.exactPins`, `slowDecode.fields`,
  `tryFastWide.pins`.
- `PRS5`: `tryFastWide.roundTripsShortestDigitsAtEveryWidth` (under 1 %
  punts), `float_conv.bench.tiers`.
- `PRS6`: `slowDecode.agreesWithBigIntOracle` (ties at every width, the
  double edges, both ends of binary128, a 1 500-input corpus of up to 38
  digits) and the libc differentials.
- `PRS7`: `readDecimalFloat.typed` (the `(float) strtod` trap).
- `PRS8`: `compose.invertsDecompose`, `compose.matchesTheBitAssembly`,
  `decompose.canonicalFields`.
- `PRS9`: `slowDecode.fitsAFiberStack`.
- `PRS10`: the `static assert` in `compose`; `BinaryFloatFormat.agreesWithPhobos`
  pins the classification against `floatTraits`.
- `PRS13`/`PRS14`: `readDecimalFloat.floatMidpoints` (3 000 random `float`
  neighbour pairs: the exact midpoint reads as the even one, one decimal
  unit either side as the neighbours; the overflow threshold and half the
  smallest subnormal spelled exactly), `readDecimalFloat.narrowTierCtfeMatchesRuntime`,
  and in `custom_float.d` `CustomFloat.everyMidpointParses` (every boundary
  of every reduced format), `CustomFloat.agreesWithBigIntOracle` (4 000
  decimals of up to 25 digits per format), `CustomFloat.readAndWrite`.
- `PRS15`: `bits.matchesTheHandAssembly`, `CustomFloat.conversionPins`,
  `CustomFloat.everyMidpointParses` (the threshold per format).
- `PRS16`: `bits.roundTripEveryPattern`, `roundTo.pins`,
  `roundTo.matchesHardwareNarrowing` (400 k doubles against `cast(float)`,
  and `real` against `cast(double)` on x87), `CustomFloat.matchesNativeBits`,
  `CustomFloat.widenIsExact`; `BinaryFloatFormat.reducedDerivations` pins
  every column of the table in §3.
- `FMT1`/`FMT2`: `formatShortestDouble.pins`, `.roundTripCorpus` (100 k
  random bit patterns), `.shortestVsPrintf`.
- `FMT3`/`FMT6`: `shortestDigits.pins`,
  `shortestDigits.roundTripsAndIsShortestAtEveryWidth`.
- `FMT4`: `shortestDigits.agreesWithSchubfach` (100 k values, digit for
  digit).
- `FMT7`: `CustomFloat.shortestIsShortest`, `CustomFloat.toString`.
- `FMT5`: `writeShortest.notation`; the SDL writer's `checkFloatingRoundTrip`
  is the consumer-side proof.
- `CTF1`: `pow10Table.knownEntries`, `pow10Anchors.knownEntries`,
  `pow10Anchors.bracketTruePowers`.
- `CTF2`: `tryFastDouble.ctfeMatchesRuntime`, `tryFastWide.ctfeMatchesRuntime`,
  `slowDecode.fields`, `shortestDigits.pins` (the `static assert`s).
- `CTF5`: the `static assert`s of `BinaryFloatFormat.reducedDerivations`,
  `roundTo.pins`, `CustomFloat.properties` and `CustomFloat.conversionPins`.

---

→ [`sparkles.base.custom_float`](../custom-float.md) — the storage types over the reduced formats
→ [`sparkles:wired` SPEC §11](../../wired/SPEC.md#11-the-native-json-engine) — the JSON engine consuming these primitives
→ [SDL SPEC §9](../../wired/sdl/SPEC.md#9-canonical-semantic-writer) — the exponent-free consumer of `writeShortest`
→ [case-style](./case-style.md) — sibling text primitive specification
