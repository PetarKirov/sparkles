# The grep long tail — ack, pt, sift, ucg, BSD grep

Five tools surveyed together, because each contributes at most one idea this
catalog has not already recorded, and none is a candidate architecture.

> **Last reviewed:** August 28, 2026.

> [!NOTE]
> A **breadth page**, not a deep-dive: these subjects do not carry the ten-dimension
> spine individually. They are here so the catalog's coverage claim is honest and so
> a reader who expects them finds out why they were not surveyed further.

---

## Why they are grouped

The scanner lineage has a well-populated middle. Between GNU grep's DFA ladder
and ripgrep's literal-plus-vectorisation, roughly a dozen tools re-implemented
"grep that respects `.gitignore`" in a language of choice. Their surviving
distinctions are ergonomic rather than architectural, and every mechanism they use
appears in a page this catalog already carries.

| Tool                         | Language | The one idea                                                                                               | Where the idea is surveyed properly                          |
| ---------------------------- | -------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `ack`                        | Perl     | File-type classification as a first-class concept — `--perl`, `--ruby` — before ignore files were the norm | Type filtering in [ripgrep][ripgrep]'s `ignore` crate        |
| `pt` (the platinum searcher) | Go       | Encoding detection per file, then search in the decoded text                                               | Encoding handling in [ugrep][ugrep]                          |
| `sift`                       | Go       | Search as a pipeline with output as a query language                                                       | Result models in [ripgrep][ripgrep]                          |
| `ucg` (universal-code-grep)  | C++      | Multi-versioned builds for SSE 4.2 with runtime selection                                                  | Runtime dispatch, done end to end, in [hypergrep][hypergrep] |
| BSD grep                     | C        | A POSIX-conformant baseline with no DFA ladder                                                             | The ladder itself in [GNU grep][gnu-grep]                    |

## What the tail establishes

**The category converged.** Ignore-awareness, type filters and colourised output
stopped being differentiators around 2015; every later tool competes on the
engine and the prefilter instead. That convergence is why this catalog's
scanner phase is short and its engine phase is long.

**Language choice did not decide the outcome.** Go, Perl, C++ and Rust
implementations all exist; the measured spread tracks prefilter quality and I/O
strategy, not runtime. This is a weak form of [thesis T1][index] — the engine,
and the language the engine is written in, are not where the time goes.

**`ucg` is the one worth a second look** if the runtime-dispatch question
reopens: it shipped multi-versioned SSE 4.2 builds before Hyperscan-based tools
made that ordinary. [hypergrep][hypergrep] carries the same idea in a form that is
easier to read, which is why it is surveyed and `ucg` is not.

## Why none of them is a candidate architecture

Each fails at least one requirement this catalog's subject has to meet: a bounded
allocation-free matching path, an interactive contract (budget, cancellation,
cursor), or a pattern engine that can be re-hosted rather than linked. The tail's
tools are all process-shaped CLI tools built on a system regex library — the
combination [ripgrep][ripgrep] documents the consequences of, and the one hue
cannot adopt.

## Sources

Surveyed at the level of documentation and design rather than source; no claims
on this page are load-bearing for a decision. `[literature]`

For anything the tail is cited for, the corresponding deep-dive is the citation
of record: [ripgrep][ripgrep], [GNU grep][gnu-grep], [ugrep][ugrep],
[hypergrep][hypergrep].

<!-- References -->

[ripgrep]: ./ripgrep.md
[gnu-grep]: ./gnu-grep.md
[ugrep]: ./ugrep.md
[hypergrep]: ./hypergrep.md
[index]: ./index.md
