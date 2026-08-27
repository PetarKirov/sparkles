# ugrep (C++)

The only mainstream grep with **built-in approximate matching**, and the only one
that ships a companion **indexer** — which makes it the single tool in this
catalog that has already answered both of the questions hue is asking.

| Field             | Value                                                                  |
| ----------------- | ---------------------------------------------------------------------- |
| Language          | C++                                                                    |
| License           | BSD-3-Clause                                                           |
| Repository        | [Genivia/ugrep][repo]                                                  |
| Surveyed revision | `2db7c2b3e9eba81b96ba72abc3b5f9f3e816dbfc` (`v7.8.4-4-g2db7c2b`)       |
| Category          | Unindexed scanner + optional index                                     |
| Engine class      | RE/flex DFA, plus `reflex::FuzzyMatcher` for `-Z`, plus PCRE2 for `-P` |
| Index             | `ugrep-indexer` — per-file hashed-ngram filter with an accuracy dial   |
| Interactive       | `-Q` query TUI (in-process incremental search)                         |

> **Last reviewed:** August 28, 2026.

---

## Overview

### What it solves

Everything GNU grep does, plus three things this catalog cares about: fuzzy
matching as a first-class flag, an optional index, and an interactive query mode
inside the same binary. It is the closest existing tool to what hue's picker is
being asked to become.

### Design philosophy

Where ripgrep is one engine plus aggressive prefiltering, ugrep is **many
engines behind one CLI**: its own RE/flex DFA compiler, a fuzzy matcher, PCRE2,
and Boost regex, selected per invocation. Breadth over minimalism, with the
configuration cost that implies.

## How it works

### The ten dimensions

#### 1. Pattern language

POSIX BRE/ERE by default; `-P` for PCRE2; `-F` fixed; `-G`, `-w`, `-x` as usual.
The distinctive one is **`-Z`/`--fuzzy`**, which admits matches within an edit
distance, and — unlike every other fuzzy matcher in this catalog — lets the user
choose _which edits are permitted_: the flag word combines a maximum distance
cost in the low byte with `INS`, `DEL`, `SUB` and `BIN` flags in the high byte,
mapped onto `reflex::FuzzyMatcher::{INS,DEL,SUB}`. `[source-verified]`

That is a genuinely different model from
[fff's typo budget][fff-grep], which is a single needle-deletion count. ugrep
lets you say "substitutions but not insertions, distance ≤ 2", which is closer to
what a code-search user usually means.

#### 2. Engine architecture

RE/flex's own DFA compiler is the default path — a _compiled_ DFA rather than a
lazy one, which is why ugrep can be fast on patterns where a lazy DFA thrashes,
and why pathological patterns cost at compile time instead of at match time.
`FuzzyMatcher` extends the same machinery with an edit budget. PCRE2 is available
for the constructs a regular language cannot express.

#### 3. Prefilter and literal extraction

RE/flex performs its own literal/first-character analysis, and ugrep compiles
with SIMD: the build exposes `--disable-sse2` (_"disable SSE2 and AVX
optimizations"_) and `--disable-avx2` (_"disable AVX2 and AVX512BW
optimizations, but compile with SSE2 when supported"_) — so unlike everything
else surveyed here, **AVX-512 is a supported target**. `[source-verified]`

#### 4. Corpus access

`mmap.hpp` is a first-class component rather than an opt-in hazard, and ugrep
searches inside archives and compressed files (`-z`), including nested archives,
with a task-parallel decompression thread feeding a pipe. Binary detection and
archive detection are computed during indexing and during search.

#### 5. Concurrency

A thread pool over files, with decompression on its own task thread so a
compressed corpus does not serialise behind inflate.

#### 6. Index — the third index family in this catalog

`ugrep-indexer` is a separate tool producing a **per-file hash table**, not a
corpus-wide posting list. The core is a rolling hash over byte n-grams:

```c
// prime 61 mod 2^16 file indexing hash function
inline uint32_t indexhash(uint32_t h, uint8_t b)
{
  return static_cast<uint16_t>((h << 6) - h - h - h + b);
}
```

Each file gets a `hashes[]` bitmap plus a **noise** measure and binary/archive
flags. Search consults the per-file filter to skip files that cannot contain the
pattern, and verifies survivors by scanning. An `--accuracy` dial (documented
range 2–7) trades index size against false positives:
_"A low accuracy reduces the indexing … increased indexing storage overhead."_
`[source-verified]`

This is architecturally distinct from both of the other families surveyed here:
not a corpus-wide inverted index like a
trigram index (Phase 4), and not a dense
bitmap column store like [fff's bigram filter][fff-grep], but a **Bloom-filter-per-file**
with a tunable false-positive rate. For a working tree it has an obvious
advantage — reindexing one changed file rewrites one file's filter.

#### 7. Ranking and result model

None. Ordering is walk order; no scoring even in fuzzy mode, which is a notable
gap given `-Z` produces genuinely rankable matches.

#### 8. Unicode

Unicode-aware patterns, multiple input encodings, and `\p{…}` support through
RE/flex. Encoding conversion is part of the pipeline rather than bolted on.

#### 9. Interactive behaviour

**`-Q` is an in-process query TUI** (`query.cpp`, `screen.cpp`, `vkey.cpp`):
type, and results update. This makes ugrep the only surveyed scanner whose
interactive mode is _not_ a process-spawn loop — which is the same architectural
choice hue is making, arrived at independently.

#### 10. Measured evidence

The project maintains a separate [`ugrep-benchmarks`][benchmarks] repository.
Under the [measurement protocol][measurement] none of its numbers are quoted
here: the corpora, flags and match counts are the authors', and its comparisons
are exactly the kind this catalog refuses to restate.

## Strengths

- **Fuzzy matching with per-operation control** (`INS`/`DEL`/`SUB`), which is
  more expressive than any other approximate matcher surveyed.
- **An index whose unit is the file**, so incremental reindexing is trivial and
  the accuracy/size trade is a user-facing dial.
- **An in-process interactive mode**, rather than the spawn-and-kill pattern
  every editor integration uses.
- **AVX-512 is a real target**, with build-time opt-outs.
- **Archive and compressed search** are integrated, not a wrapper script.

## Weaknesses

- **Breadth costs coherence**: four engines and a very large flag surface.
- **No ranking at all**, even where `-Z` makes ranking meaningful.
- **A compiled DFA moves the pathological case to compile time** rather than
  removing it.
- **The index is a separate tool and a separate decision**, so the common case
  remains unindexed.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                          | Trade-off                                                                    |
| ------------------------------------------------ | -------------------------------------------------- | ---------------------------------------------------------------------------- |
| Fuzzy as a flag on the same matcher              | Approximate search is a mode, not a separate tool  | Edit-distance semantics differ from subsequence scoring; users conflate them |
| Per-operation edit flags (`INS`/`DEL`/`SUB`)     | "Typo" means different things in different corpora | More configuration surface than most users will touch                        |
| Compiled DFA (RE/flex) rather than lazy          | Fast steady-state matching, no cache management    | Compilation cost, and state blow-up becomes a compile-time failure           |
| Per-file hash filter rather than global postings | One changed file invalidates exactly one filter    | Cannot answer "which files contain X" without visiting every filter          |
| `--accuracy` as a user dial                      | False-positive rate is a legitimate user trade     | Requires the user to understand what they are trading                        |
| In-process `-Q` TUI                              | Interactive search without process-spawn latency   | The tool now owns terminal handling, which is a lot of non-search code       |
| AVX-512 supported                                | Real throughput gains on capable hardware          | A build matrix and runtime capability questions                              |

## Sources

Read at `2db7c2b3e9eba81b96ba72abc3b5f9f3e816dbfc` `[source-verified]`:

- [`src/ugrep.cpp`][ugrep-cpp] — flag surface, fuzzy flag composition, engine selection
- [`src/ugrep-indexer.cpp`][indexer-cpp] — `indexhash`, the per-file filter, `--accuracy`
- [`src/query.cpp`][query-cpp], `src/screen.cpp`, `src/vkey.cpp` — the `-Q` interactive mode
- [`README.md`][readme] — SIMD build options
- `src/mmap.hpp`, `src/glob.cpp`, `src/cnf.cpp` — corpus access and pattern combination

Not read: RE/flex itself (a separate upstream); claims about `FuzzyMatcher`
internals are limited to the flags ugrep passes it.

<!-- References -->

[repo]: https://github.com/Genivia/ugrep
[ugrep-cpp]: https://github.com/Genivia/ugrep/blob/2db7c2b3e9eba81b96ba72abc3b5f9f3e816dbfc/src/ugrep.cpp
[indexer-cpp]: https://github.com/Genivia/ugrep/blob/2db7c2b3e9eba81b96ba72abc3b5f9f3e816dbfc/src/ugrep-indexer.cpp
[query-cpp]: https://github.com/Genivia/ugrep/blob/2db7c2b3e9eba81b96ba72abc3b5f9f3e816dbfc/src/query.cpp
[readme]: https://github.com/Genivia/ugrep/blob/2db7c2b3e9eba81b96ba72abc3b5f9f3e816dbfc/README.md
[benchmarks]: https://github.com/Genivia/ugrep-benchmarks
[fff-grep]: ./fff-grep.md
[measurement]: ./measurement.md
