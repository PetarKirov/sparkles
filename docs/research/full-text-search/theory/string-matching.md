# String matching — Boyer-Moore, Two-Way, Aho-Corasick

The single- and multi-literal algorithms every prefilter in this catalog reduces
to. The engineering comparison lives in [`literal-prefilters`][prefilters] and
[`multi-pattern`][multi]; this page defines the algorithms and their bounds.

> **Last reviewed:** August 28, 2026.

---

## Why skipping was the classical answer

Naive search compares the needle at every position: `O(n · m)`. The classical
insight is that a mismatch tells you more than "not here" — it tells you how far
you may safely jump.

**Boyer-Moore** compares right-to-left and takes the larger of two shifts: the
_bad-character_ rule (align the mismatched byte with its last occurrence in the
needle) and the _good-suffix_ rule (align the matched suffix with its next
occurrence). Sublinear in practice, `O(n · m)` in the worst case. **Horspool**
keeps only the bad-character rule — one `size_t[256]` table, most of the benefit.
[ag][ag] ships exactly this.

## Two-Way — linear time, constant space

Crochemore-Perrin computes a **critical factorization** of the needle: a split
point where a mismatch on either side gives a provably safe shift. The result is
`O(n)` worst case with **`O(1)` extra space** — no skip table at all.

glibc's `memmem` is Two-Way. For a fixed-capacity D implementation, the
constant-space property is the attraction: there is no table to size, no capacity
to bound, and no failure mode when the needle is long.

## Why the modern answer is neither

Both classical algorithms optimise the **worst case**. Real corpora are not worst
cases: byte frequencies in source code are wildly skewed, and a single rare byte
rejects almost everything.

[memchr's packed-pair][prefilters] therefore picks the two lowest-frequency
needle bytes from a background frequency table and probes for those, using SIMD
where available and `memchr` where not. On real text this beats skip tables,
because it converts the problem from "how far can I jump" into "where could this
possibly be". The insight is statistical rather than algorithmic, and it is the
one this catalog recommends adopting.

## Aho-Corasick — many needles, one pass

A trie of all patterns plus **failure links** (where to go when the current byte
does not extend the current prefix), giving **one transition per input byte
regardless of pattern count**. Construction is linear in the total pattern
length; space is a transition table per state.

Two representations, and the choice is the usual dial:

- **NFA form** — sparse transitions, compact, an indirection per step.
- **DFA form** — dense `states × 256`, one indexed load per step, memory-hungry
  enough to need a cap.

**Commentz-Walter** grafts Boyer-Moore skipping onto the trie: skip by the
shortest pattern's length when the window cannot match. Wins on few long
patterns; degrades as the pattern set grows, since the minimum length — and hence
the skip — shrinks. [GNU grep][gnu-grep]'s `kwset` is this lineage.

## Bounds, side by side

| Algorithm    | Preprocess | Extra space     | Worst case   | Typical                  |
| ------------ | ---------- | --------------- | ------------ | ------------------------ |
| Naive        | —          | `O(1)`          | `O(n·m)`     | `O(n·m)`                 |
| Horspool     | `O(m + σ)` | `O(σ)`          | `O(n·m)`     | sublinear                |
| Boyer-Moore  | `O(m + σ)` | `O(m + σ)`      | `O(n·m)`     | sublinear                |
| **Two-Way**  | `O(m)`     | **`O(1)`**      | **`O(n)`**   | sublinear                |
| Shift-or     | `O(m + σ)` | `O(σ)` words    | `O(n·⌈m/w⌉)` | same                     |
| Packed pair  | `O(m)`     | `O(σ)` constant | `O(n·m)`     | near-`O(n)` on real text |
| Aho-Corasick | `O(Σm)`    | `O(states·σ)`   | `O(n + occ)` | same                     |

`σ` is the alphabet size (256), `w` the word size, `occ` the number of matches.

## What this catalog concluded

For hue's plain mode: **packed-pair over a Sparkles-derived frequency table**,
with **Two-Way** as the adversarial fallback and **shift-or** where the needle
fits a word and case folding is wanted. All three are `@safe pure nothrow @nogc`
with fixed tables. Aho-Corasick is deferred until an index makes multi-literal
verification the hot path.

## Sources

[`literal-prefilters`][prefilters] and [`multi-pattern`][multi] carry the
`[source-verified]` citations. Historical: Boyer & Moore (CACM 1977), Horspool
(1980), Crochemore & Perrin (JACM 1991), Aho & Corasick (CACM 1975),
Commentz-Walter (1979) `[literature]`.

<!-- References -->

[prefilters]: ../literal-prefilters.md
[multi]: ../multi-pattern.md
[ag]: ../silver-searcher.md
[gnu-grep]: ../gnu-grep.md
