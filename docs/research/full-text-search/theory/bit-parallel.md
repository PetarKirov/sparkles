# Bit-parallel matching — shift-or, Myers, BNDM

Simulating an automaton in the bits of a machine word. The cheapest technique in
this catalog: no allocation, no tables beyond one word per alphabet symbol, and
already present in D's standard library.

> **Last reviewed:** August 28, 2026.

---

## Shift-or

Represent the "how much of the needle matches ending here" state as a bitmask,
one bit per needle position. Precompute, for each byte, a mask of the positions
it _cannot_ occupy. Then each input byte costs one shift and one OR:

```
state = (state << 1) | mask[byte]
```

A match ends at this position when the bit for the needle's last position is
clear. For needles up to the word size — 64 characters on a 64-bit machine —
this is `O(n)` with a constant of two instructions, and the entire preprocessing
is a `uint[256]`-shaped table.

**D already ships one.** `std.regex`'s `kickstart.d` is a shift-or engine used as
a coarse prefilter in front of both of its matchers, with a `charsetThreshold` of
32,000 above which a character class is not worth encoding. See
[`std-regex`][std-regex].

## Why it matters here

Three properties, all of which the [`@nogc` constraint][baseline] cares about:

1. **The state is a scalar.** No live set, no closure, no allocation, no capacity
   question.
2. **Case folding is free.** Fold when building the mask table, not per
   comparison — which is exactly what hue's two divergent in-document searches
   are doing badly by hand.
3. **It degrades predictably.** Needles longer than the word size need multiple
   words, and the cost grows in whole-word steps rather than falling off a cliff.

## Myers' bit-vector algorithm

The same idea extended to **edit distance**: represent the dynamic-programming
column's differences as bit vectors and update them with a fixed sequence of
word operations. Computes Levenshtein distance in `O(n · ⌈m/w⌉)` rather than
`O(n · m)`.

This is the algorithm behind fast approximate matching, and it is what
[`approximate`](./approximate.md) builds on. Its relevance here is that
**approximate matching does not require a scoring matrix**: for a bounded edit
distance over a short needle, bit-parallel is both faster and dramatically
simpler than the affine-gap Smith-Waterman `sparkles:fuzzy` uses for subsequence
scoring — a different problem with a different right answer.

## BNDM — backward nondeterministic DAWG matching

Shift-or run **backwards** over a window of needle length, which allows skipping
like Boyer-Moore while keeping the bit-parallel state update. In practice it
competes with the packed-pair heuristic in [`literal-prefilters`][prefilters];
BNDM wins on longer needles and structured alphabets, packed-pair on real text
where byte frequencies are skewed.

## Word-RAM caveats

The technique's bounds assume a word-sized machine integer with cheap shifts —
true everywhere Sparkles builds. What is _not_ portable is assuming a 64-bit
word: a needle of 40 characters is one word on x86-64 and one word on aarch64,
but the fallback path for longer needles must exist and be tested, since it is
the path a real query hits less often and therefore the one that rots.

## What this catalog concluded

Shift-or is the **first thing a bounded D implementation should build**: it is
tiny, it needs no dependency, it gives plain mode a real matcher with correct
case folding in one place, and it is independent of how the regex question
resolves. `examples/bitap-shift-or.d` is the grounding.

## Sources

[`std-regex`][std-regex] for the in-tree implementation; [`literal-prefilters`][prefilters]
for where it sits among the alternatives. Historical: Baeza-Yates & Gonnet
(shift-or, 1992), Myers (JACM 1999), Navarro & Raffinot (BNDM) `[literature]`.

<!-- References -->

[std-regex]: ../std-regex.md
[prefilters]: ../literal-prefilters.md
[baseline]: ../sparkles-baseline.md
