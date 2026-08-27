# GNU grep (C)

The original, and still the clearest illustration of the catalog's central
claim: a three-tier ladder in which the regex engine is the _last_ thing tried,
and often not tried at all.

| Field             | Value                                                                   |
| ----------------- | ----------------------------------------------------------------------- |
| Language          | C                                                                       |
| License           | GPL-3.0-or-later                                                        |
| Repository        | [git.savannah.gnu.org/grep][repo]                                       |
| Surveyed revision | `79da8e07613966b9e53c7ef31b4765d39f98044d` (`v3.12-40-g79da8e0`)        |
| Category          | Unindexed scanner                                                       |
| Engine class      | Lazy DFA (gnulib `dfa.c`) + POSIX `regex`, fronted by a `kwset` matcher |
| Index             | None                                                                    |
| Interactive       | None — a process                                                        |

> **Last reviewed:** August 28, 2026.

> [!NOTE]
> `dfa.c` and `kwset.c` live in **gnulib**, which is a submodule and was not
> cloned; this page is read from grep's own `src/` — the glue that decides which
> engine runs when — and is explicit where a claim depends on gnulib internals it
> did not read. Those are marked `[literature]`.

---

## Overview

### What it solves

Line-oriented pattern search over files and streams, POSIX-specified, with the
DFA lineage that every later tool measures itself against. Its historical
contribution is the demonstration that **avoiding work beats doing work faster**,
an argument its original author made directly:

> _"The key to making programs fast is to make them do practically nothing."_
> — Mike Haertel, "why GNU grep is fast" `[literature]`

### Design philosophy

Three engines, tried cheapest-first, with an explicit short-circuit at each
level. The code says so in a comment that is the single best summary of the
design:

> _"Number of compiled fixed strings known to exactly match the regexp. If
> `kwsexec` returns < `kwset_exact_matches`, then we don't need to call the
> regexp matcher at all."_ — [`src/dfasearch.c`][dfasearch] `[source-verified]`

## How it works

### The ten dimensions

#### 1. Pattern language

POSIX BRE (`grep`), ERE (`-E`), fixed strings (`-F`), and PCRE via `-P`
(`pcresearch.c`). Each is a separate compiled representation with its own
execute function, selected once.

#### 2. Engine architecture — the ladder

Three tiers, and the interesting part is the _gates_ between them:

1. **`kwset`** — a multi-string matcher (Commentz-Walter lineage) built at
   compile time from the literals the pattern _must_ contain, obtained from
   gnulib's `dfamust`. `dfasearch.c` builds it: _"which must occur in the match,
   then we build a kwset matcher"_.
2. **Superset DFA** — `dfasuperset(dc->dfa)` returns a cheaper DFA that
   over-accepts. Running it first rejects most positions without touching the
   real automaton. There is also `dfaisfast(dc->dfa)`, so the strategy adapts to
   how expensive the compiled DFA turned out to be.
3. **The real DFA, then POSIX `regex`** — the backtracking-free DFA locates
   candidate lines, and `re_search` is used only where exact submatch semantics
   are required.

The short-circuit above is the payoff: for a pattern whose required literals
_are_ the whole pattern, `kwset` answers directly and neither DFA nor regex
runs. `-F` takes this further, with `Fcompile` building a `kwset` from the
pattern list and appending _"extra one-character words … one for each
troublesome character that will require a DFA search"_.

#### 3. Prefilter and literal extraction

`dfamust` is the ancestor of every literal-extraction scheme in this catalog,
including [ripgrep's][ripgrep]. The difference is where the extracted literals
go: GNU grep feeds them to a **multi-pattern automaton** built once, while
ripgrep feeds them to a vectorized single-literal search and re-runs the regex
on the recovered line.

#### 4. Corpus access

`read` into a growable buffer; `--mmap` existed and was **removed**, because the
`SIGBUS`-on-truncation hazard [ripgrep documents][ripgrep] is real and a
general-purpose tool cannot take it. Line handling uses a configurable EOL byte
(`eolbyte`), which is how `-z/--null-data` works.

Binary handling is a three-way user-facing policy —
`--binary-files=binary|text|without-match`, mapping to
`BINARY_BINARY_FILES` / `TEXT_BINARY_FILES` / `WITHOUT_MATCH_BINARY_FILES` — and
the default suppresses output rather than printing control bytes.
`[source-verified]`

#### 5. Concurrency

None. One process, one thread, one file at a time. Parallelism is the shell's
job (`xargs -P`, `find -exec`), which is exactly the design ripgrep rejected.

#### 6. Index

None, and none contemplated.

#### 7. Ranking and result model

None. Matching lines in file order, with offsets and line numbers on request.
No classification, no scoring, no context beyond `-A`/`-B`/`-C`.

#### 8. Unicode

Locale-driven rather than Unicode-native: multibyte handling is threaded through
`searchutils.c` and `localeinfo.c`, and the well-known consequence is that
`LC_ALL=C` is dramatically faster than a UTF-8 locale for the same pattern. The
cost of correctness is visible in the code as a separate multibyte path rather
than a parameter.

#### 9. Interactive behaviour

None. No budget, no cancellation, no partial results, no cursor.

#### 10. Measured evidence

The `LC_ALL=C` speedup and the general "grep is fast because it skips" story are
widely reported and **not reproduced here**; under the
[measurement protocol][measurement] they are `[literature]` until this
repository's own harness produces them. What is `[source-verified]` is
structural: three engines, two short-circuit gates, and a `kwset` that can answer
without the regex engine running.

## Strengths

- **The ladder is explicit and gated**, with the fast path able to return a final
  answer rather than merely a candidate.
- **A superset automaton as a prefilter** is a technique no other tool in this
  catalog uses, and it needs no literals at all — it works on patterns from which
  nothing can be extracted.
- **Adaptive**: `dfaisfast` lets the strategy depend on what the pattern compiled
  to.
- **Binary policy is a user-facing three-way choice**, not a boolean.

## Weaknesses

- **Single-threaded, single-file** — the walk and the parallelism are outside the
  tool.
- **Locale-dependent performance cliff**: the same pattern is far slower in a
  UTF-8 locale, which is a correctness cost users routinely defeat with
  `LC_ALL=C`.
- **No interactive contract whatsoever.**
- **`mmap` was tried and withdrawn**, which is itself the field's most-cited
  evidence against it for a general tool.

## Key design decisions and trade-offs

| Decision                                     | Rationale                                                       | Trade-off                                                               |
| -------------------------------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `kwset` from the pattern's required literals | Most patterns contain a literal; find it with a cheap automaton | Extraction fails on patterns with no required literal                   |
| `kwset_exact_matches` short-circuit          | When the literals _are_ the pattern, no engine needs to run     | Bookkeeping to know when the answer is exact                            |
| Superset DFA before the real DFA             | Rejects without literals, so it works where extraction fails    | A second automaton to build and keep                                    |
| Lazy DFA rather than full determinization    | Bounds the state explosion at construction                      | A cache with eviction — the same structure that is hard to make `@nogc` |
| `--mmap` removed                             | `SIGBUS` on concurrent truncation is unacceptable for a tool    | Gives up the fastest path on large single files                         |
| Locale-driven multibyte, not Unicode-native  | POSIX conformance                                               | A large performance cliff users learn to work around with `LC_ALL=C`    |

## Sources

Read at `79da8e07613966b9e53c7ef31b4765d39f98044d` `[source-verified]`:

- [`src/dfasearch.c`][dfasearch] — the ladder, `kwset_exact_matches`, `dfasuperset`
- [`src/kwsearch.c`][kwsearch] — `Fcompile` and the `-F` path
- [`src/grep.c`][grep-c] — the binary-files policy
- `src/search.h`, `src/pcresearch.c`, `src/searchutils.c` — the engine seam

Not read (gnulib submodule, claims marked `[literature]`): `lib/dfa.c`,
`lib/kwset.c`.

Secondary: Mike Haertel, _"why GNU grep is fast"_, freebsd-current mailing list,
August 2010 `[literature]`.

<!-- References -->

[repo]: https://cgit.git.savannah.gnu.org/cgit/grep.git/
[dfasearch]: https://cgit.git.savannah.gnu.org/cgit/grep.git/tree/src/dfasearch.c?id=79da8e07613966b9e53c7ef31b4765d39f98044d
[kwsearch]: https://cgit.git.savannah.gnu.org/cgit/grep.git/tree/src/kwsearch.c?id=79da8e07613966b9e53c7ef31b4765d39f98044d
[grep-c]: https://cgit.git.savannah.gnu.org/cgit/grep.git/tree/src/grep.c?id=79da8e07613966b9e53c7ef31b4765d39f98044d
[ripgrep]: ./ripgrep.md
[measurement]: ./measurement.md
