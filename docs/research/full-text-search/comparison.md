# Comparison — what the survey established

The capstone. Resolves the five theses, ranks the leverage, and states what
carries into [recommendations](./recommendations.md).

> **Last reviewed:** August 28, 2026.

---

## At a glance

| Subject                | Engine                           | Prefilter                                         | I/O                           | Index                                    | Interactive contract                |
| ---------------------- | -------------------------------- | ------------------------------------------------- | ----------------------------- | ---------------------------------------- | ----------------------------------- |
| [GNU grep][gnu-grep]   | lazy DFA + POSIX regex           | `kwset` from required literals **+ superset DFA** | `read`; `--mmap` removed      | —                                        | none                                |
| [ripgrep][ripgrep]     | `regex` meta-engine              | inner-literal extraction → vectorised search      | `read` default; mmap `unsafe` | unfinished crate                         | none                                |
| [ugrep][ugrep]         | RE/flex compiled DFA, `-Z` fuzzy | RE/flex analysis + SIMD                           | mmap first-class              | **per-file hashed-ngram, accuracy dial** | `-Q` in-process TUI                 |
| [git grep][git-grep]   | POSIX / PCRE2+JIT                | minimal                                           | object store or worktree      | —                                        | **ordered** parallel output         |
| [ag][ag]               | PCRE per line                    | literal-only fast path                            | mmap default                  | —                                        | none                                |
| [hypergrep][hypergrep] | Hyperscan                        | FDR/Teddy                                         | —                             | git index as file list                   | none                                |
| [fff][fff-grep]        | memmem / `regex` / SW-fuzzy      | whole-file memmem; distinct-char; bigram          | buffer + mmap threshold       | dense bigram bitmaps                     | **budget, abort, cursor, counters** |
| [Zoekt][zoekt]         | candidate + verify               | **positional** trigrams                           | sharded, SSD                  | trigram + **ctags symbols**              | served, <50 ms target               |
| [livegrep][livegrep]   | RE2                              | — (suffix array)                                  | mmap, 3–5× text               | suffix array                             | served, incremental                 |

## The five theses

### T1 — the engine is rarely the bottleneck · **supported, not proven**

The structural evidence is uniform. Every mature scanner spends its cleverness on
_avoiding_ the engine: GNU grep short-circuits to `kwset` and never runs the regex
when the literals are the pattern; ripgrep recovers the line a literal occurs on
and runs the pattern only there; fff runs a whole-file `memmem` before the
searcher is even constructed. Vectorscan's entire architecture is a decomposition
that routes literals away from the automaton. And [hardware automata][hw] make the
point by inversion — where NFA execution is free, the prefilter tower has no
reason to exist, which shows it is an artifact of the CPU rather than of search.

**Not proven**, because this repository has produced no timing under its own
[protocol][measurement]. The ranked-leverage list below follows from T1 and should
be revisited if measurement contradicts it.

### T2 — indexing is a mutation-rate bet · **supported**

Every index surveyed pays for freshness in a different currency and none pays
nothing. Google Code Search merges; Zoekt reshards with a documented
version-upgrade dance; Lucene and tantivy carry segment-and-merge machinery whose
operational surface is the cost; livegrep rebuilds. The one design whose update
cost is genuinely small is [ugrep][ugrep]'s **per-file** filter — one changed
file, one rewritten filter.

The corollary the survey adds: for an _interactive_ tool the adversarial case is
not just mutation but **prefix queries**. `theory/examples/ngram-selectivity.d`
shows a query shorter than the gram size extracts no obligation at all, so the
index cannot help during the first keystrokes — exactly when latency is most
visible.

### T3 — n-gram and self-indexes answer different questions · **confirmed**

Directly. A trigram index cannot answer `\d{3}-\d{4}`, because no literal can be
extracted; a suffix array can. livegrep pays 3–5× the corpus to have that
property, which is the price of "no false positives" stated as a number. And the
`r`-index family's space bound depends on run count, making versioned history its
natural corpus and a heterogeneous source tree its worst one.

Confirmed by construction rather than measurement, and the construction is enough.

### T4 — accelerator wins carry a transfer and compile tax · **unresolved**

Recorded as unresolved rather than answered. The published GPU work measures
throughput over a resident corpus with a large static pattern set, and hue's
workload is first-result latency over a changing corpus with one changing pattern.
Reconstructing each paper's baseline against a prefilter-equipped CPU
implementation is the work that would settle it, and it is larger than the
decision it informs. The platform prerequisite is missing anyway —
`sparkles:vulkan` has no compute path.

### T5 — interactive search is a latency-distribution problem · **confirmed**

Confirmed from two directions. The [fuzzy-matching][fuzzy] tree reached it from
the picker side; this tree reaches it from the engine side, and they agree.

The decisive evidence is what the field _builds_: every editor integration
surveyed obtains its interactive properties by **killing a process**, because no
general-purpose scanner exposes a budget, a cancellation signal or a cursor. The
one engine that does — fff — is the one written for a picker. Throughput is not
what any of them optimised for at the interaction boundary; stopping quickly is.

## The consensus, and where it stops

**Settled.** Every engine with a linear-time guarantee bought it by refusing
backreferences and lookaround. Prefiltering is architecture rather than
optimisation. Line-orientation is exploited structurally. `mmap` is a hazard a
long-lived process should decline.

**Not settled — genuine product decisions:**

- **Binary detection**: four incompatible positions, all defensible.
- **Unicode**: on by default (ripgrep) or off (fff), each with a stated rationale.
- **Auto-detection of mode**: fff ships two disagreeing ladders in different
  callers.
- **Definition classification**: 131 lines of byte heuristics at one end, a ctags
  index at the other.

## Benchmark methodology — what survives scrutiny

Almost nothing is quoted in this catalog, deliberately. The two numbers that are,
are both `[literature]` from source comments rather than published benchmarks —
fff's per-line UTF-8 validation at ~8% of fuzzy-grep runtime, and its definition
classifier at ~2% on large repos. Both are the authors' observations on unnamed
hardware.

Every published cross-tool comparison encountered fails at least one clause of the
[measurement protocol][measurement]: different corpora, unpinned flags, or
unreported match counts. The protocol's first rule — one harness per table —
disqualifies restating them, and this catalog does not.

## Ranked leverage for a Sparkles implementation

Following T1, and ordered by expected effect per unit of work:

1. **A literal prefilter** — packed-pair over a frequency table derived from this
   repository's own corpus, with Two-Way as the adversarial fallback.
2. **Corpus access** — bounded `read`, a size cap set by hue's re-read-per-query
   model rather than fff's cached one, layered binary detection, one shared walk.
3. **The interactive contract** — per-file budget, generation cancellation polled
   every file, a soft-limited resumable cursor, honest counters.
4. **Match handling** — a 512-byte stored window keeps every line inside the
   full-quality scoring tier and bounds the row model.
5. **The engine** — a Pike VM with a sparse-set thread list, unanchored, with
   match-start slots. Last, because T1 says so, and because the plain and fuzzy
   modes ship without it.

## The delta — where Sparkles stands

| Capability           | Field's answer                           | Sparkles today                           | Gap                                          |
| -------------------- | ---------------------------------------- | ---------------------------------------- | -------------------------------------------- |
| Literal search       | packed-pair + SIMD                       | one `private` naive `containsIC`         | Promote and improve                          |
| Regex engine         | refuse backrefs, Pike VM floor           | `glob.d`: anchored, no positions, bitset | Three gaps closed by `pike-vm-line-search.d` |
| Bounded reading      | roll buffer or whole-file                | `readText`, GC, throws                   | Absent                                       |
| Binary detection     | four positions                           | path/extension only                      | Absent (content)                             |
| Interactive contract | fff alone                                | **already present** in the scheduler     | Reuse                                        |
| Ranking              | structural, not BM25                     | composite formula shipped                | Reuse                                        |
| Case rule            | one, shared                              | **two, disagreeing**                     | Defect                                       |
| SIMD                 | portability + `cpuid` + multi-versioning | none wired                               | Join missing                                 |
| Index                | trigram / per-file / suffix              | none                                     | Deferred (`PKM6`)                            |

The row that stands out is the interactive contract: **hue already has the thing
the entire field lacks.** `PickerScheduler`'s generation counter, duration budget
and synchronous fallback are exactly what every editor integration rebuilds from
process management. The grep source does not need to invent it — it needs to reuse
it.

## What carries forward

Into [recommendations](./recommendations.md): the ranked leverage list, the
resolved answers to questions 2a, 2b, 12 and 13, and the four unsettled product
decisions above — which are decisions for the spec to make, not for further
research to discover.

<!-- References -->

[gnu-grep]: ./gnu-grep.md
[ripgrep]: ./ripgrep.md
[ugrep]: ./ugrep.md
[git-grep]: ./git-grep.md
[ag]: ./silver-searcher.md
[hypergrep]: ./hypergrep.md
[fff-grep]: ./fff-grep.md
[zoekt]: ./trigram-indexes/zoekt.md
[livegrep]: ./livegrep.md
[hw]: ./hardware-automata.md
[fuzzy]: ../fuzzy-matching/index.md
[measurement]: ./measurement.md
