# Literal prefilters — `memchr`, `memmem`, packed pairs

The layer where, if [thesis T1][index] holds, most of the wall-clock actually
goes. This page covers single-byte and single-substring search; the
many-patterns case is [multi-pattern](./multi-pattern.md).

| Field             | Value                                                            |
| ----------------- | ---------------------------------------------------------------- |
| Primary source    | [BurntSushi/memchr][repo]                                        |
| Surveyed revision | `bd6068c30e9074a90c285e47912fa0b047d07597` (`2.8.3-7`)           |
| Category          | Acceleration primitive                                           |
| Algorithms        | SIMD byte search · Two-Way · Rabin-Karp · shift-or · packed pair |

> **Last reviewed:** August 28, 2026.

---

## Why this is a first-class subject

Every scanner surveyed in Phase 1 reduces, in its hot path, to "find the next
place this literal could occur". [GNU grep][gnu-grep] reaches it through
`kwset`, [ripgrep][ripgrep] through extracted literals, [fff][fff-grep] through a
whole-file `memmem` pre-check. The engine runs afterwards, on a small fraction of
the bytes.

So the question this page answers is not "which substring algorithm is fastest"
but **which one a `@safe pure nothrow @nogc` D implementation should carry**, and
what each costs in table space and preprocessing.

## The algorithm family

`memchr`'s `src/arch/all/` names the portable set, and it is a good census of the
field: `memchr.rs`, `twoway.rs`, `rabinkarp.rs`, `shiftor.rs`, `packedpair/`.
`[source-verified]`

### Classical skipping — Boyer-Moore and Two-Way

Boyer-Moore and its Horspool simplification precompute skip tables from the
needle and jump forward on a mismatch. [ag][ag] uses exactly this, with
`alpha_skip_lookup` and `find_skip_lookup`.

**Two-Way** (Crochemore-Perrin) is the one that matters for a bounded
implementation: it achieves linear time in **constant space** by computing a
_critical factorization_ of the needle instead of a skip table. glibc's `memmem`
is Two-Way. For D, the constant-space property is the attraction — no table
allocation, no capacity to size.

### Bit-parallel — shift-or

Simulates the needle's automaton in the bits of a machine word: one word of
state, `O(n)` for needles up to the word size, and trivially allocation-free.
Phobos already ships one in [`std.regex`'s kickstart][std-regex], and the
fuzzy-matching research flagged the same family as transferable. **This is the
cheapest thing a D implementation can adopt, and it needs no new dependency.**

### Rabin-Karp

A rolling hash; not competitive for single-needle search, but it is the
substrate under n-gram indexing, which is why it appears again in
[ugrep][ugrep]'s per-file filter and in Phase 4.

### The packed-pair heuristic — the modern answer

`memchr`'s default is neither classical skipping nor bit-parallel:

> _"The 'packed pair' algorithm is based on the generic SIMD algorithm. The main
> difference is that it (by default) uses a background distribution of byte
> frequencies to heuristically select the pair of bytes to search for."_
> — [`arch/all/packedpair/mod.rs`][packedpair] `[source-verified]`

> _"This finder picks two bytes that it believes have high predictive power for
> indicating an overall match of a needle. At search time, it reports offsets
> where the needle could match based on whether the pair of bytes it chose
> match."_

The selection is a ranked scan over the needle, keeping the two lowest-frequency
bytes:

```rust
let (mut rare1, mut index1) = (needle[0], 0);
let (mut rare2, mut index2) = (needle[1], 1);
if ranker.rank(rare2) < ranker.rank(rare1) { … }
```

`[source-verified]`, against a `default_rank` table of background byte
frequencies.

Three things follow, and they are the page's real content:

1. **The insight is statistical, not algorithmic.** Classical skipping optimises
   for the worst case; packed-pair optimises for the _distribution of real text_.
   On source code — where `e`, space and `t` are everywhere and `q`, `z`, `~` are
   not — picking rare bytes beats picking the last byte.
2. **The frequency table is a portable artifact.** A D implementation needs one
   table of 256 ranks. It can be derived from this repository's own corpus, which
   is a better fit than English prose, and it is a compile-time constant.
3. **It degrades to `memchr` gracefully.** The architecture-independent variant
   finds one rare byte with `memchr` and checks the second — so even without
   SIMD, the heuristic pays.

## Choosing for a `@nogc` D implementation

| Algorithm            | Preprocessing            | Space               | Fits `@safe pure nothrow @nogc`? | Verdict                                    |
| -------------------- | ------------------------ | ------------------- | -------------------------------- | ------------------------------------------ |
| Naive                | none                     | none                | ✓                                | The `containsIC` in `tui.d` today          |
| Boyer-Moore/Horspool | skip tables              | 256+ entries        | ✓ (fixed array)                  | Superseded                                 |
| **Two-Way**          | critical factorization   | **constant**        | ✓                                | Strong default; no capacity question       |
| **shift-or**         | one word per needle byte | one word            | ✓                                | Cheapest; caps at word-size needles        |
| Rabin-Karp           | rolling hash             | none                | ✓                                | For indexing, not search                   |
| **Packed pair**      | one rank table lookup    | a 256-byte constant | ✓                                | Best on real text; needs a frequency table |

The recommendation this feeds into Phase 7: **packed-pair over a
Sparkles-derived frequency table, with Two-Way as the fallback for adversarial
needles**, and shift-or where the needle fits a word and case folding is wanted.
None of the three needs an allocator.

## What this says about thesis T1

If the engine were the bottleneck, the field would compete on automata. It
competes on _this_ — a byte-frequency table and a two-byte probe. That is
suggestive rather than conclusive; the [measurement protocol][measurement]
requires this repository's own numbers before T1 is called, and
`examples/memmem-vs-naive.d` is where they come from.

## Sources

Read at `bd6068c30e9074a90c285e47912fa0b047d07597` `[source-verified]`:

- [`src/arch/all/packedpair/mod.rs`][packedpair] — the heuristic and rare-byte selection
- [`src/memmem/mod.rs`][memmem] — the substring API surface
- `src/arch/all/{twoway,shiftor,rabinkarp,memchr}.rs` — the portable algorithm set

Secondary: Wojciech Muła, _"SIMD-friendly algorithms for substring searching"_
(the "first and last" generic-SIMD note the packed-pair module cites)
`[literature]`.

<!-- References -->

[repo]: https://github.com/BurntSushi/memchr
[packedpair]: https://github.com/BurntSushi/memchr/blob/bd6068c30e9074a90c285e47912fa0b047d07597/src/arch/all/packedpair/mod.rs
[memmem]: https://github.com/BurntSushi/memchr/blob/bd6068c30e9074a90c285e47912fa0b047d07597/src/memmem/mod.rs
[index]: ./index.md
[gnu-grep]: ./gnu-grep.md
[ripgrep]: ./ripgrep.md
[fff-grep]: ./fff-grep.md
[ag]: ./silver-searcher.md
[ugrep]: ./ugrep.md
[std-regex]: ./std-regex.md
[measurement]: ./measurement.md
