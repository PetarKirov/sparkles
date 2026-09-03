# `sparkles.base.text.float_conv` — Specification

_Audience: developers and coding agents building against `sparkles:base`. This
document is normative and self-contained — it states what the module guarantees
when converting decimal text to `float`, `double` or `real` and back. It is a format-agnostic text
primitive with no grammar opinions beyond the decimal literal itself; the
`sparkles:wired` JSON engine ([SPEC §11](../../wired/SPEC.md#11-the-native-json-engine))
is one consumer. For the library overview see
[`sparkles:base`](../../../libs/base/index.md)._

## 1. Overview

`sparkles.base.text.float_conv` converts between decimal text and IEEE-754
binary floating point **exactly** in both directions — `double` on the tiers
it was built around, and every format `float`, `double` or `real` takes across
this repository's targets (binary32, binary64, x87 extended, binary128) through
one format-parameterized exact kernel:

- **Parse** — the returned value is always the correctly-rounded
  (round-to-nearest, ties-to-even) value of the full decimal, no matter how
  many digits the input carries.
- **Format** — the emitted text is the _shortest_ decimal string that
  re-parses to the identical bit pattern.

The format is data, not a type (`BinaryFloatFormat`, §3): a kernel
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
struct BinaryFloatFormat { int mantDig, minExp, maxExp; /* + derived: */
    int maxDigits10(); int exactPow10Max(); int maxExactDigits(); int decimalCapacity(); … }
enum binary32, binary64, extended80, binary128;   // every format `real` takes here
template formatOf(T);                             // a float type's own format
struct DecodedFloat { ulong hi, lo; int exp2; bool negative, isInf; }
DecodedFloat slowDecode(BinaryFloatFormat fmt)(scope const(char)[] intDigits,
                  scope const(char)[] fracDigits, int explicitExp10);
size_t       shortestDigits(BinaryFloatFormat fmt)(in DecodedFloat v,
                  scope char[] digitBuf, out int exp10);      // digitBuf ≥ maxDigits10
DecodedFloat decompose(T)(T value);
T            compose(T)(in DecodedFloat d);

// Building blocks for fused grammar loops (e.g. a JSON number scanner):
size_t readDigits(uint maxDigits = 19)(scope const(char)[] s, ref ulong sig);
size_t readDigits(scope const(char)[] s, ref ulong sig, size_t maxDigits);
bool   tryFastDouble(ulong sig10, int exp10, out double result);
double slowDouble(scope const(char)[] intDigits,
                  scope const(char)[] fracDigits, int explicitExp10);
T      slowFloat(T)(scope const(char)[] intDigits,
                  scope const(char)[] fracDigits, int explicitExp10);

// Cursor-style reader for the general decimal-literal grammar:
ParseExpected!T readDecimalFloat(T = double)(ref scope const(char)[] s);

// Shortest round-trip formatting:
size_t formatShortestDouble(scope char[] buf, double value); // buf.length ≥ 40
void   writeShortestDouble(Writer)(ref Writer w, double value);
size_t shortestDigits(T)(T value, scope char[] digitBuf, out int exp10);
void   writeShortest(T, Writer)(ref Writer w, T value);      // [-]d[.ddd]e[-]x

// IEEE-754 bit access (CTFE-safe both ways):
ulong  doubleToBits(double d);
double bitsToDouble(ulong bits);
```

## 3. Parse guarantees

`readDecimalFloat` accepts the grammar
`[-]digits[.digits][(e|E)[±]digits]` and advances the cursor past the
literal on success. Its result is decided by three tiers, fastest first —
**every tier is exact**, so callers never observe a tier boundary:

1. **Clinger fast path** — when the significand fits the 53-bit mantissa
   and `|exp10| ≤ 22`, one FP multiply or divide is correctly rounded by
   construction.
2. **Eisel–Lemire** — a 128-bit multiply against a precomputed power-of-ten
   significand table settles almost every remaining case in pure 64-bit
   integer arithmetic. Cases it cannot _prove_ (true ties, subnormal
   results, overflow boundaries, table-truncation ambiguity) fall through.
3. **Exact big-decimal fallback** (`slowDouble`) — an arbitrary-precision
   decimal (up to 800 significant digits in fixed storage, sticky
   truncation bit beyond) scaled by exact power-of-two shifts; settles
   every remaining input with exact ties-to-even information.

Inputs with more than 19 significant digits are first decided by
_bracketing_: when the truncated 19-digit significand and its successor
both round to the same `double`, that value is proven correct without the
exact tier.

**Saturation policy** — magnitudes above `double.max` become
`±double.infinity`; positive magnitudes below half the smallest subnormal
become `±0`. Subnormals are fully supported (`5e-324` parses to bit
pattern `1`).

`fracDigits` passed to `slowDouble` may be empty; both digit runs may
carry leading zeros. `exp10` passed to `tryFastDouble` is the decimal
exponent of the significand's **last** digit.

### Any format

`readDecimalFloat!T` routes on `formatOf!T` — the full
`(mant_dig, min_exp, max_exp)` triple, never `mant_dig` alone (x87 with a
53-bit significand, Phobos' `ieeeExtended53`, has x87's exponent range):

| `formatOf!T`                                   | fast tier                                 | exact tier              |
| ---------------------------------------------- | ----------------------------------------- | ----------------------- |
| `binary64` — `double`, and `real` where it is  | Clinger, Eisel–Lemire, bracketing (above) | `slowDouble`            |
| `binary32` — `float`                           | Clinger, in `float` arithmetic            | `slowDecode!binary32`   |
| `extended80` — `real` on x86_64                | Clinger, in `real` arithmetic             | `slowDecode!extended80` |
| `binary128` — `real` on AArch64 Linux, Android | Clinger, in `real` arithmetic             | `slowDecode!binary128`  |
| double-double (`mant_dig == 106`)              | —                                         | `static assert`         |

- **The exact tier is one kernel.** `slowDecode!fmt` is `slowDouble`'s
  algorithm with its four `double`-specific parts derived from the format —
  the saturation bounds, the normal-exponent clamps, the significand readout
  (128 bits wide, since 113 do not fit a `ulong`) and the big-decimal
  storage. Storage must track the format: decimal truncation is
  order-preserving, so a value is decided correctly once the rounding tie it
  is compared against expands completely inside the buffer, and binary128's
  ties run to 11 564 digits. `decimalCapacity` is 200 / 800 / 11 600 / 11 600
  — 800 being what `slowDouble` always had.
- **No Eisel–Lemire above 53 bits.** For binary128 its table would be
  ~9 900 × 256-bit entries (317 KB of rodata) and ~`4.5e8` CTFE limb
  operations to generate, against §5's two-second rebuild. The exact tier
  costs on the order of milliseconds at `real.max`'s magnitude; nothing calls
  it in a loop, and the writer (§4) never parses candidates.
- **`float` is not the `double` result cast down.** A decimal a hair below
  a `float` midpoint rounds onto it as a `double`, and the tie then breaks to
  even — the classic `(float) strtod(s) != strtof(s)`. Clinger's division
  side runs in `float` for the same reason.
- **The result is integers first.** `slowDecode` returns a `DecodedFloat` —
  significand `hi:lo`, the exponent of its last bit, the overflow verdict —
  and `compose!T` turns it into a native value by exact power-of-two scaling
  (no bit punning: D has no portable `realToBits`, and x87's explicit integer
  bit makes synthesis format-specific). `decompose!T` is the inverse. Both
  run at CTFE and use nothing from Phobos.
- **Environment.** The fast tier and `compose` are floating-point arithmetic
  and assume round-to-nearest-even with traps masked; `std.math.hardware.
FloatingPointControl` can change both and this module does not defend
  against it. The exact tier is integer arithmetic and does not care.
- **Stack.** The decoder's digits live in its frame — 11.6 KB at binary128
  — and a druntime `Fiber`'s default stack is 16 KiB on 4 KiB-page Linux.
  Both directions at `real.max`'s magnitude are tested to fit a 32 KiB
  fiber in the unoptimized test build, whose frames are about twice the
  shipping build's; give a fiber that decodes wide `real`s room.

## 4. Format guarantees

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
  renders any type as `[-]d[.ddd]e[-]x` plus `nan`/`inf`/`-inf`.
  `formatShortestDouble` keeps Schubfach and its own notation for the JSON
  hot path.
- The result never exceeds `maxDigits10` digits (9 / 17 / 21 / 36), and is
  often shorter: `real.max` at binary128 is 34 digits.

## 5. The power-of-ten table

One CTFE-generated table serves both directions: for each `q` in
`[-343, 324]`, the top 128 bits of `10^q` normalized to `[2^127, 2^128)`
and **truncated** (the yyjson convention; the Schubfach writer applies its
own ceiling adjustment). Generation is exact big-integer arithmetic at
compile time — there is no external generator step to keep in sync, and a
full rebuild of `sparkles:base` stays around two seconds.

## 6. CTFE

`readDigits`, `tryFastDouble`, `slowDouble`, `slowDecode`, `slowFloat`,
`readDecimalFloat`, `decompose`, `compose`, `shortestDigits`, `doubleToBits`,
and `bitsToDouble` are CTFE-callable; at compile time the `double` Clinger
tier is skipped so results flow through the deterministic integer tiers, and
tests pin CTFE results bit-identical to runtime ones — including a binary128
decode and a binary64 shortest rendering settled entirely at compile time.
`formatShortestDouble` is runtime-only (pointer-based digit rendering).

## 7. Verification

- Exactness pins: `1e22`/`1e23` (the canonical halfway literal),
  `double.max` and its overflowing neighbor, `2^53 ± 1` ties, the largest
  subnormal (`2.2250738585072011e-308`), `5e-324`, both saturation ends.
- 20k-case in-tree differential against glibc `strtod` (bit-exact, 100%
  resolution); a 1M-case sweep validated the table convention change.
- 100k random-bit-pattern round-trip corpus (format → parse → identical
  bits) spanning every exponent regime.
- Shortest-ness differential: for random values, one significant digit
  fewer (via `%.*g`) never round-trips.
- **Every width, on every host.** An independent correctly-rounded oracle by
  `std.bigint` division agrees with `slowDecode` at 24, 53, 64 and 113 bits
  over ties at each width (`2^p + 1`), the double edges, both ends of
  binary128's range and a 1 500-input corpus of up to 38 digits; on Linux
  `binary32` and `readDecimalFloat!float` are also checked against `strtof`,
  including the decimal on which `(float) strtod` gets it wrong.
- `shortestDigits!binary64` agrees with `f64ToDecimal` digit for digit over
  the 100k corpus; at all four widths every result decodes back exactly and
  neither of the two nearest decimals one digit shorter does.
- `compose ∘ decompose` is the identity, bit for bit, over the corners of all
  three types and 5 000 random double patterns, and `compose` over
  `slowDecode!binary64` lands on the very bits `slowDouble` assembles.
- Our `formatOf!T` classification agrees with Phobos' `floatTraits!T` for
  every type the host has; both directions at `real.max`'s magnitude run on
  a 32 KiB fiber in the unoptimized test build.

---

→ [`sparkles:wired` SPEC §11](../../wired/SPEC.md#11-the-native-json-engine) — the JSON engine consuming these primitives
→ [case-style](./case-style.md) — sibling text primitive specification
