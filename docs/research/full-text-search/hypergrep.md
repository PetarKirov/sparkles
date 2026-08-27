# hypergrep (C++)

A grep built directly on Hyperscan, and — uniquely in this catalog — one that
does **runtime CPU dispatch** and **content-based binary detection by magic
number**. Both are gaps in Sparkles' baseline, answered here concretely.

| Field             | Value                                                    |
| ----------------- | -------------------------------------------------------- |
| Language          | C++                                                      |
| License           | MIT                                                      |
| Repository        | [p-ranav/hypergrep][repo]                                |
| Surveyed revision | `ee85b713aa84e0050a3b36030000778ccfd4882f` (`v0.1.1-13`) |
| Category          | Unindexed scanner                                        |
| Engine class      | Hyperscan block-mode NFA/DFA hybrid (`hs_scan`)          |
| Index             | None; can search the **git index**                       |
| Interactive       | None                                                     |

> **Last reviewed:** August 28, 2026.

---

## Overview

### What it solves

Throughput search using Hyperscan as the matching engine rather than a
backtracking or lazy-DFA regex library. Hyperscan's own design is surveyed in
[`parsing/hyperscan.md`][hs]; this page covers what a _grep_ built on it has to
supply around it.

### Design philosophy

Let the automata engine do the matching, and spend the surrounding code on the
three things Hyperscan does not do: deciding which files to open, deciding which
are text, and picking an ISA at runtime.

## How it works

### The ten dimensions

#### 1. Pattern language

Hyperscan's PCRE subset, compiled once with `HS_MODE_BLOCK`. The subset is the
constraint that matters: constructs Hyperscan refuses — backreferences, most
lookaround — simply cannot be expressed.

#### 2. Engine architecture

`hs_scan` over a buffer, with per-thread `scratch`. Matching is
**callback-driven** — `on_match` fires per match — which inverts the usual loop
and is why `match_handler.cpp` exists as a separate component.

A practical constraint worth recording: _"hs_scan takes an `unsigned int` buffer
size (2^32-1)"_, so files above 4 GiB must be chunked by the caller.
`[source-verified]`

#### 3. Prefilter and literal extraction

Delegated entirely to Hyperscan, which does its own literal decomposition
(FDR/Teddy). hypergrep adds a _path_ prefilter: `file_filter.cpp` compiles the
`--filter` globs into a second Hyperscan database and runs `hs_scan` **over the
path string** — an unusual reuse of the automata engine for filename matching.

#### 4. Corpus access — content-based binary detection

`is_binary.cpp` is the most directly reusable artifact here. Rather than sniffing
for NUL bytes, it tests **magic numbers**: `\x7fELF`, `!<arch>`, `\xFF\xD8\xFF`
(JPEG), `\x89PNG\r\n\x1A\n`, and more. `[source-verified]`

That is a third position in a design space this catalog has now seen three
answers to — [ripgrep][ripgrep] decides mid-stream on a NUL byte,
[fff][fff-grep] caches a flag from index time, and hypergrep matches headers up
front. Magic numbers have a property the other two lack: **no false positives on
text**, at the cost of missing formats not in the table.

`git_index_search.cpp` searches the git index directly, so a repository can be
searched without a directory walk.

#### 5. Concurrency — with runtime ISA dispatch

`cpu_features.cpp` is a hand-rolled `__cpuid` probe:

```cpp
bool has_avx2_support();
bool has_avx512_support();
```

built on `__cpuid(1, …)` checking `bit_SSE4_2`, `bit_AVX2` and the AVX-512 bits.
`[source-verified]` Hyperscan itself ships multiple ISA-specialised engines, and
this is how the right one is chosen at run time.

**This is the join Sparkles' baseline is missing.** hypergrep demonstrates the
shape end to end: probe with `cpuid`, select an implementation, keep the portable
one as the floor. That it is only ~40 lines of C is itself the finding — the
dispatch half is cheap; the multi-versioned _code_ is the expensive half.

#### 6. Index

None of its own.

#### 7–8. Result model and Unicode

Matching lines, no ranking. Unicode is Hyperscan's UTF-8 mode where enabled.

#### 9. Interactive behaviour

None.

#### 10. Measured evidence

The project publishes comparisons against ripgrep; none are reproduced here, per
the [measurement protocol][measurement]. They are the authors' corpora and flags,
and stand as `[paper-claim]`-equivalent.

## Strengths

- **Runtime ISA dispatch, demonstrated in ~40 lines** — the missing join, made
  concrete.
- **Magic-number binary detection**: no false positives on text.
- **The path filter reuses the automata engine**, so one mechanism serves both
  filename and content matching.
- **Git-index search** without a walk.

## Weaknesses

- **Hyperscan's PCRE subset is a hard ceiling** on expressible patterns.
- **Callback-driven matching** complicates cancellation and ordering.
- **A 4 GiB buffer limit** the caller must handle.
- **Magic numbers miss unknown formats**, where a NUL sniff would catch them.
- A small project with limited platform coverage relative to the others surveyed.

## Key design decisions and trade-offs

| Decision                              | Rationale                                             | Trade-off                                                        |
| ------------------------------------- | ----------------------------------------------------- | ---------------------------------------------------------------- |
| Hyperscan as the engine               | Streaming automata throughput, multi-pattern for free | A restricted pattern language, and a large dependency            |
| Runtime `cpuid` dispatch              | One binary, best available ISA                        | Multi-versioned code paths must all be built and kept equivalent |
| Magic-number binary detection         | No false positives on text                            | Unknown binary formats are searched as text                      |
| `hs_scan` over the _path_ for filters | One matching mechanism for names and content          | Compiles a second database; overkill for simple globs            |
| Callback match handling               | Hyperscan's native model                              | Inverted control flow; harder to bound or cancel mid-file        |

## Sources

Read at `ee85b713aa84e0050a3b36030000778ccfd4882f` `[source-verified]`:

- [`src/cpu_features.cpp`][cpu-features] — the `cpuid` probe
- [`src/is_binary.cpp`][is-binary] — magic-number detection
- [`src/file_search.cpp`][file-search], [`src/directory_search.cpp`][dir-search] — `hs_scan` driving
- [`src/file_filter.cpp`][file-filter] — Hyperscan over path strings
- `src/git_index_search.cpp`, `src/match_handler.cpp`

<!-- References -->

[repo]: https://github.com/p-ranav/hypergrep
[cpu-features]: https://github.com/p-ranav/hypergrep/blob/ee85b713aa84e0050a3b36030000778ccfd4882f/src/cpu_features.cpp
[is-binary]: https://github.com/p-ranav/hypergrep/blob/ee85b713aa84e0050a3b36030000778ccfd4882f/src/is_binary.cpp
[file-search]: https://github.com/p-ranav/hypergrep/blob/ee85b713aa84e0050a3b36030000778ccfd4882f/src/file_search.cpp
[dir-search]: https://github.com/p-ranav/hypergrep/blob/ee85b713aa84e0050a3b36030000778ccfd4882f/src/directory_search.cpp
[file-filter]: https://github.com/p-ranav/hypergrep/blob/ee85b713aa84e0050a3b36030000778ccfd4882f/src/file_filter.cpp
[hs]: ../parsing/hyperscan.md
[ripgrep]: ./ripgrep.md
[fff-grep]: ./fff-grep.md
[measurement]: ./measurement.md
