# `sparkles.base.text.float_conv` — Specification

_Audience: developers and coding agents building against `sparkles:base`. This
document is normative and self-contained — it states what the module guarantees
when converting decimal text to `double` and back. It is a format-agnostic text
primitive with no grammar opinions beyond the decimal literal itself; the
`sparkles:wired` JSON engine ([SPEC §11](../../wired/SPEC.md#11-the-native-json-engine))
is one consumer. For the library overview see
[`sparkles:base`](../../../libs/base/index.md)._

## 1. Overview

`sparkles.base.text.float_conv` converts between decimal text and IEEE-754
`double` **exactly** in both directions:

- **Parse** — the returned `double` is always the correctly-rounded
  (round-to-nearest, ties-to-even) value of the full decimal, no matter how
  many digits the input carries.
- **Format** — the emitted text is the _shortest_ decimal string that
  re-parses to the identical bit pattern.

| Identifier      | Value                               |
| --------------- | ----------------------------------- |
| Dub sub-package | `sparkles:base`                     |
| Source root     | `libs/base/src/sparkles/base/text/` |
| Module          | `sparkles.base.text.float_conv`     |

## 2. API surface

```d
// Building blocks for fused grammar loops (e.g. a JSON number scanner):
size_t readDigits(uint maxDigits = 19)(scope const(char)[] s, ref ulong sig);
size_t readDigits(scope const(char)[] s, ref ulong sig, size_t maxDigits);
bool   tryFastDouble(ulong sig10, int exp10, out double result);
double slowDouble(scope const(char)[] intDigits,
                  scope const(char)[] fracDigits, int explicitExp10);

// Cursor-style reader for the general decimal-literal grammar:
ParseExpected!double readDecimalFloat(ref scope const(char)[] s);

// Shortest round-trip formatting:
size_t formatShortestDouble(scope char[] buf, double value); // buf.length ≥ 40
void   writeShortestDouble(Writer)(ref Writer w, double value);

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
    foreach (v; [0.1, 1.0 / 3.0, 1e20, 1e21, 5e-324, -0.0])
    {
        const len = formatShortestDouble(buf[], v);
        const(char)[] text = buf[0 .. len];
        auto back = readDecimalFloat(text);
        writefln("%-24s round-trips: %s", buf[0 .. len],
            doubleToBits(back.value) == doubleToBits(v));
    }
}
```

```[Output]
0.1                      round-trips: true
0.3333333333333333       round-trips: true
100000000000000000000.0  round-trips: true
1e21                     round-trips: true
5e-324                   round-trips: true
-0.0                     round-trips: true
```

## 5. The power-of-ten table

One CTFE-generated table serves both directions: for each `q` in
`[-343, 324]`, the top 128 bits of `10^q` normalized to `[2^127, 2^128)`
and **truncated** (the yyjson convention; the Schubfach writer applies its
own ceiling adjustment). Generation is exact big-integer arithmetic at
compile time — there is no external generator step to keep in sync, and a
full rebuild of `sparkles:base` stays around two seconds.

## 6. CTFE

`readDigits`, `tryFastDouble`, `slowDouble`, `readDecimalFloat`,
`doubleToBits`, and `bitsToDouble` are CTFE-callable; at compile time the
Clinger tier is skipped so results flow through the deterministic integer
tiers, and tests pin CTFE results bit-identical to runtime ones.
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

---

→ [`sparkles:wired` SPEC §11](../../wired/SPEC.md#11-the-native-json-engine) — the JSON engine consuming these primitives
→ [case-style](./case-style.md) — sibling text primitive specification
