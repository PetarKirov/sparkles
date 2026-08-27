# Full-Text Search Research Plan

A working plan for the source-grounded full-text-search catalog under
`docs/research/full-text-search/`. The catalog surveys how a byte pattern is found in a
corpus of text — from `grep`'s DFA over a single file, through ripgrep's literal
prefilters and Zoekt's positional trigram shards, to compressed self-indexes, ranked
inverted indexes, and GPU/FPGA automata engines — and asks which of those techniques a
D implementation inside Sparkles can actually carry.

**Plan updated:** August 27, 2026

> [!IMPORTANT]
> This is an execution plan, not a findings page. Every claim intended for readers
> belongs in a deep-dive or synthesis page carrying a pinned primary-source citation.
> Remove this plan from the published VitePress source set (or fold it into the final
> design issue) once the tree is complete.

---

## 1. Outcome

Deliver a VitePress-integrated research tree that separates six layers of the
full-text-search problem instead of conflating them under "search is fast now":

1. **Pattern semantics** — what language the query denotes: literal, glob, POSIX BRE/ERE,
   PCRE, multi-pattern set, approximate (edit-distance bounded), structural, ranked
   bag-of-terms.
2. **Match engine** — the automaton or algorithm that decides membership: backtracking,
   Thompson NFA simulation, lazy/hybrid DFA, bit-parallel NFA, Glushkov + SIMD,
   derivative-based.
3. **Acceleration** — the prefilter that avoids running the engine at all: `memchr` on a
   rare byte, Two-Way/Boyer-Moore, Teddy, Aho-Corasick, bitap, packed-pair heuristics,
   candidate generation from an index.
4. **Corpus access** — how bytes reach the engine: `read` vs `mmap` vs `io_uring`,
   parallel directory traversal, ignore-file semantics, binary sniffing, transcoding,
   decompression, page-cache and NUMA effects.
5. **Precomputation** — what an index buys and what it costs: n-gram/trigram postings,
   suffix arrays and automata, FM-index/r-index/move structures, inverted indexes with
   impact ordering, and the freshness/merge machinery each one drags along.
6. **Result presentation** — ordering, ranking, deduplication, context lines, caps,
   streaming, cancellation, and the latency budget an interactive UI imposes.

The synthesis must recommend a staged full-text-search architecture for Sparkles —
specifically the content-search path behind `hue`'s picker — while keeping the
research/design boundary explicit: deep-dives establish prior art, `comparison.md` and
`recommendations.md` interpret it, and any implementation specification lands later
under `docs/specs/`.

## 2. Relationship to existing catalogs

Three trees already touch this territory. The plan's first obligation is to not
duplicate them, and to state the seam in `index.md` so a reader lands in the right place.

| Existing tree                                     | What it owns                                                                                                                     | Seam                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`fuzzy-matching/`](../fuzzy-matching/index.md)   | Ranked **subsequence** scoring over a candidate list: fzf, fzy, nucleo, frizbee, fff, picker hosts, the `tick`/injector contract | That tree answers "given 500k paths and the query `usr`, which rank highest". This tree answers "given 2 GB of file _content_ and a regex, which bytes match". `fzf`/`fff` are **not** re-surveyed here; they appear only as the consumer of a content-search backend (`fzf --reload 'rg …'`). |
| [`parsing/hyperscan.md`](../parsing/hyperscan.md) | Hyperscan as a scanning/lexing engine for the syntax pipeline                                                                    | Extend rather than move. This tree cites it for the automata decomposition and adds Vectorscan's portable fork, licensing, and the streaming-mode contract that matters for search but not for lexing.                                                                                         |
| [`parsing/theory/`](../parsing/theory/index.md)   | Formal languages, derivatives, general parsing                                                                                   | Regex-specific automata theory (Thompson vs Glushkov, determinization blow-up, lazy DFA caching, bit-parallel simulation) belongs **here**, in `theory/`, cross-linked to `parsing/theory/derivatives.md`.                                                                                     |

A fourth seam is internal: approximate matching. Edit-distance-bounded search over
content (Levenshtein automata, Myers' bit-vector algorithm, agrep, `ugrep -Z`) is in
scope; affine-gap subsequence scoring is not — it is the fuzzy-matching tree's subject.

## 3. Research questions

`index.md` must link each question to the page that answers it.

1. What does each tool's pattern language actually denote, and where do POSIX BRE/ERE,
   PCRE, RE2-style regular languages, and Hyperscan's PCRE subset diverge in ways a user
   can observe?
2. Which engine class does each tool use, and what is the worst case it is protecting
   against — catastrophic backtracking, DFA state explosion, or memory blow-up?
3. Where does the wall-clock actually go in an unindexed scan, and how much of the
   observed spread between `grep`, `rg`, and `ugrep` is engine versus prefilter versus
   I/O versus output formatting?
4. What is the minimum literal information extractable from a regex, and how do the
   field's prefilters (`memchr`, Two-Way, Teddy, Aho-Corasick, bitap) exploit it?
5. When does an index pay for itself? What are the crossover points in corpus size,
   query rate, and mutation rate, and what does each index cost in build time, RAM,
   on-disk size, and staleness?
6. How do trigram postings, suffix arrays, and BWT-runs indexes differ in what queries
   they can answer at all — not merely how fast?
7. What does ranked retrieval (BM25, Block-Max WAND, impact-ordered postings, learned
   sparse) add over Boolean matching, and when is ranking the wrong frame for code?
8. Which parts of this problem does specialized hardware genuinely win, and by how much
   under an honest end-to-end measurement including transfer?
9. What must a search backend expose so an interactive UI stays responsive: first-result
   latency, streaming, cancellation, backpressure, result caps, stable ordering?
10. Which published benchmark numbers survive scrutiny, and what corpus/methodology
    protocol should this repository adopt for its own measurements?
11. What is the smallest staged path from Sparkles' current state to a credible content
    search behind `hue`, and which techniques are realistic in D with LDC?

## 4. Scope

### 4.1 In scope

- Unindexed scanners: GNU grep, BSD grep, `git grep`, ripgrep, ugrep, the Silver
  Searcher, `ucg`, `hypergrep`, plus the ack/pt/sift long tail as a single page.
- Regex engine internals: `regex`/`regex-automata`, RE2, PCRE2 (interpreter + JIT),
  Hyperscan/Vectorscan, Oniguruma, glibc/musl `regexec`, Go `regexp`, and .NET's
  non-backtracking engine as the mainstream derivative-based comparator.
- Literal and multi-pattern acceleration primitives, treated as first-class subjects.
- Corpus-access mechanics: traversal, ignore semantics, `mmap` policy, `io_uring`,
  binary detection, encoding handling, compressed-corpus search.
- Unicode semantics: case folding, normalization, `\w`/`\b` under Unicode, UTF-8 DFAs,
  invalid-UTF-8 policy, and their measured cost.
- Index families: n-gram/trigram postings, suffix arrays/automata, compressed
  self-indexes (FM-index, r-index, move structure), inverted indexes with BM25/WAND.
- Index operations: build cost, sharding, incremental update, segment merge, deletion,
  memory-mapping, and index-on-object-storage designs.
- Hardware acceleration: GPU automata and bit-parallel engines, GPU inverted-index
  retrieval, FPGA/ASIC automata processors, and wide-SIMD (AVX-512, SVE2) ports.
- Approximate content search bounded by edit distance.
- Structural/semantic search (`ast-grep`, Comby, Semgrep, tree-sitter queries, embedding
  retrieval) — surveyed as a **boundary**, to establish what regex cannot express, not
  as a competing implementation target.
- Interactive-search contracts and editor/agent integrations.
- Benchmark methodology and corpus design.
- A source audit of Sparkles' current search surface.

### 4.2 Out of scope

- Subsequence/fuzzy-picker scoring — owned by [`fuzzy-matching/`](../fuzzy-matching/index.md).
- Vector databases and ANN index internals (HNSW, IVF-PQ). Dense retrieval appears only
  in the hybrid-fusion discussion, with a one-paragraph pointer.
- Bioinformatics read alignment as an application. The pangenome literature is cited for
  its **index engineering** (Movi, b-move, prefix-free parsing), not for its biology.
- Network intrusion detection as an application, likewise: DPI papers are cited for
  automata engineering.
- General-purpose database query planning beyond the FTS extension surface.
- Web-scale crawling, spam, link analysis, and query understanding.
- LLM/RAG pipeline design. Embedding retrieval is a boundary subject, not a survey area.
- Writing search code in `libs/` during the research phase.

## 5. Local-first grounding protocol

Identical discipline to [`application-packaging/PLAN.md`](../application-packaging/PLAN.md),
restated because the subject mix here is unusually paper-heavy.

For every open-source subject:

1. Check `$REPOS` (`/home/petar/code/repos`) for an existing clone.
2. Clone missing upstreams into `$REPOS/search/`.
3. Record `git remote get-url origin`, the full 40-character reviewed SHA, and the
   nearest tag from `git describe --tags --always`.
4. Read source, tests, design docs, and benchmark harnesses — not just READMEs. Several
   subjects here ship their own design prose that is the best available primary source
   (Zoekt's `doc/design.md`, ripgrep's `regex-automata` module docs, fzy's `ALGORITHM.md`
   in the sibling tree).
5. Cite permanent `blob/<sha>/path` URLs, never floating `main`.
6. Verify pinned blob paths offline with `nix run .#ci -- --check-blob-paths` before
   publishing.

For academic subjects, the protocol differs and must be stated on the page:

- Cite the **published venue** (DOI or LIPIcs/ACM/arXiv identifier) plus, when it exists,
  the authors' artifact repository at a pinned SHA.
- Distinguish `[paper-claim]` from `[artifact-verified]` (see §8). A speedup figure from
  an abstract is a claim about the authors' hardware and baseline, not a portable fact.
- Record the baseline the paper compares against and the hardware generation. A GPU
  result measured against an unspecified "state-of-the-art CPU engine" is not comparable
  to a ripgrep number, and the page must say so rather than tabulate them side by side.

### 5.1 Candidate clone ledger

To be filled with reviewed SHAs as each deep-dive lands.

| Cluster      | Subjects to clone                                                                                                                                 |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scanners     | `grep` (GNU), `ripgrep`, `ugrep`, `the_silver_searcher`, `ucg`, `hypergrep`, `git`                                                                |
| Engines      | `regex` (rust-lang), `re2`, `pcre2`, `vectorscan`, `oniguruma`, `runtime` (.NET, regex subtree)                                                   |
| Primitives   | `memchr`, `aho-corasick`, `fst`, `sse4-strstr` (Muła)                                                                                             |
| Indexes      | `zoekt`, `codesearch` (Google), `livegrep`, `tantivy`, `lucene`, `pisa`, `sdsl-lite`, `Move-r`, `Movi`, `b-move`, `sqlite` (FTS5), `duckdb` (fts) |
| Structural   | `ast-grep`, `comby`, `semgrep`, `tree-sitter`                                                                                                     |
| Acceleration | `cudf` (strings/regex), `hyperscan` (pre-relicense tag), published GPU artifacts                                                                  |

## 6. Catalog structure

```text
docs/research/full-text-search/
├── index.md
├── concepts.md
├── sparkles-baseline.md
│
├── theory/
│   ├── index.md
│   ├── automata.md              # Thompson vs Glushkov, determinization, lazy DFA
│   ├── bit-parallel.md          # shift-or/bitap, Myers, BNDM, word-RAM tricks
│   ├── string-matching.md       # Boyer-Moore, Two-Way, Commentz-Walter, Aho-Corasick
│   ├── approximate.md           # Levenshtein automata, Myers bit-vector, k-mismatch
│   ├── succinct-indexes.md      # suffix arrays, BWT, FM-index, r-index, move structure
│   └── ranked-retrieval.md      # TF-IDF/BM25, WAND/Block-Max, impact ordering
│
├── gnu-grep.md
├── ripgrep.md
├── ugrep.md
├── git-grep.md
├── silver-searcher.md
├── hypergrep.md
├── grep-long-tail.md            # ack, pt, sift, ucg, BSD grep
│
├── rust-regex.md                # regex + regex-automata (the meta-engine)
├── re2.md
├── pcre2.md
├── vectorscan.md                # extends parsing/hyperscan.md, does not replace it
├── oniguruma.md
├── dotnet-nonbacktracking.md
├── engine-comparison.md
│
├── literal-prefilters.md        # memchr, memmem, Teddy, packed pairs
├── multi-pattern.md             # Aho-Corasick, Commentz-Walter, Hyperscan FDR/Teddy
│
├── trigram-indexes/
│   ├── index.md                 # the n-gram family
│   ├── google-codesearch.md
│   ├── zoekt.md
│   └── livegrep.md
├── suffix-structures.md         # suffix arrays/automata, sparse SA, LCP
├── compressed-self-indexes.md   # FM-index, r-index, Move-r, Movi, b-move
├── lucene.md
├── tantivy.md
├── pisa.md
├── embedded-fts.md              # SQLite FTS5, DuckDB FTS
│
├── gpu-automata.md              # HybridSA, bitstream execution, speculative FSM
├── gpu-retrieval.md             # GPU inverted-index / learned-sparse retrieval
├── hardware-automata.md         # AP lineage, RAP, FPGA
├── wide-simd.md                 # AVX-512, SVE2, portable-SIMD ports
│
├── corpus-access.md             # traversal, ignore rules, mmap/io_uring, binary, encodings
├── unicode-semantics.md
├── approximate-search.md        # agrep, ugrep -Z, TRE, FST-based fuzzy terms
├── structural-search.md         # ast-grep, Comby, Semgrep, tree-sitter (boundary page)
├── interactive-contracts.md     # streaming, cancellation, caps, editor/agent integration
├── measurement.md               # corpora + methodology protocol
│
├── comparison.md
└── recommendations.md
```

Start flat; graduate a subject to `<subject>/index.md` the moment it acquires
`examples/` or sub-deep-dives. `trigram-indexes/` starts graduated because three
subjects share one design lineage and one set of examples.

### 6.1 Fixed analysis spine

Every scanner/engine/index deep-dive answers the same ten dimensions in the same order,
recording the absence explicitly where a dimension does not apply:

1. **Pattern language** — syntax accepted, semantics chosen (leftmost-first vs
   leftmost-longest), documented divergences.
2. **Engine architecture** — automaton class, fallbacks, memory bounds, worst case.
3. **Prefilter and literal extraction** — what is extracted, how it is dispatched.
4. **Corpus access** — read strategy, traversal, filtering, binary/encoding policy.
5. **Concurrency** — unit of parallelism, work distribution, ordering guarantees.
6. **Index (if any)** — structure, build cost, size ratio, freshness, mutation path.
7. **Ranking and result model** — ordering, dedup, caps, context, output formats.
8. **Unicode** — case folding, normalization, classes, boundaries, cost.
9. **Interactive behaviour** — first-result latency, streaming, cancellation.
10. **Measured evidence** — what the upstream benchmarks claim, under what protocol, and
    what survives the [measurement] critique.

### 6.2 Deep-dive skeleton

1. `# Subject (ecosystem/role)` and a one-sentence position.
2. Metadata table: language, license, repository, reviewed SHA/version, category.
3. `**Last reviewed:** <date>` on umbrella and synthesis pages.
4. `## Overview` → `### What it solves`, `### Design philosophy`, at least one verbatim
   primary-source quotation.
5. `## How it works`, with real identifiers and short labelled excerpts.
6. The ten-dimension spine from §6.1.
7. `## Strengths`, `## Weaknesses`, `## Key design decisions and trade-offs` table.
8. `## Sources` plus the reference-link block.

## 7. Cross-cutting theses

Five claims the catalog should either establish or refute. They give the tree a spine
beyond "here are twenty tools", and each must resolve in `comparison.md` with evidence.

- **T1 — The engine is rarely the bottleneck.** In a realistic scan, the dominant costs
  are candidate rejection (prefilter quality), byte delivery (traversal, syscalls, page
  cache), and match _handling_ (line-number counting, formatting, output). The regex
  engine is exercised on a small fraction of the corpus. If true, the ranked leverage for
  a Sparkles implementation is prefilter → I/O → formatting → engine, in that order.
- **T2 — Indexing is a mutation-rate bet, not a size bet.** A trigram index converts
  scan cost into build-plus-staleness cost; it wins where the corpus is large _relative to
  its churn_ and where query rate is high. A working tree edited every few seconds is the
  adversarial case, and the field's answer is hybrid (indexed default branch + unindexed
  fast path), not one or the other.
- **T3 — Compressed self-indexes and n-gram indexes answer different questions.** An
  FM-index/r-index answers arbitrary-substring locate in compressed space; a positional
  trigram index answers "which documents plausibly contain this pattern" and delegates
  verification to a scanner. The repetitive-text literature's `O(r)`-space results are a
  poor fit for a heterogeneous source tree and an excellent fit for versioned history —
  which suggests where each could sit in a Sparkles design.
- **T4 — Accelerator wins are real but arrive with a transfer tax and a compile tax.**
  Published GPU speedups are measured against automata-heavy multi-pattern workloads with
  the corpus already resident. The honest end-to-end question is bytes/second including
  host→device transfer, pattern compilation, and result readback, against a CPU baseline
  that has an equally good prefilter. The catalog must reconstruct that comparison rather
  than repeat abstract-level speedup ratios.
- **T5 — Interactive search is a latency-distribution problem, not a throughput problem.**
  First-result latency, cancellation on keystroke, and bounded result handling determine
  perceived speed; total scan time is nearly irrelevant above a few hundred milliseconds
  because the query has already changed. This is the same conclusion the fuzzy-matching
  tree reached from the other side, and the two syntheses should agree.

## 8. Evidence labels

| Label                        | Meaning                                                                                   |
| ---------------------------- | ----------------------------------------------------------------------------------------- |
| `[source-verified]`          | Read in pinned implementation, tests, or checked-in design docs.                          |
| `[spec-verified]`            | Read in an authoritative specification (POSIX, Unicode UTS, a file-format spec).          |
| `[host-verified: <os/arch>]` | Behaviour executed on that host, with the command and corpus recorded.                    |
| `[measured: <protocol>]`     | A number produced by this repository's own harness under the [measurement] protocol.      |
| `[paper-claim]`              | A figure reported by a publication; baseline and hardware named alongside it.             |
| `[artifact-verified]`        | A paper's own artifact built and run locally; the delta from the paper's figure recorded. |
| `[literature]`               | Secondary or historical source; never the sole support for a current mechanic.            |
| `[unverified]`               | Open question retained explicitly, not written as fact.                                   |

Two rules deserve emphasis for this tree specifically. First, **no cross-tool timing
appears in a table unless the same harness produced every row** — the field's published
comparisons disagree precisely because their corpora, flags, and match counts differ.
Second, **no GPU or FPGA figure is reported without its baseline**; a speedup ratio with
an unnamed denominator is not evidence.

## 9. Runnable examples

The tree's strongest grounding. Each is a single-file `dub` program under a graduated
subject's `examples/`, compiled and run by `ci --example-files`, cross-linked to the
prose section it backs. Candidates, in rough order of value:

| Example                   | Claim it grounds                                                                        |
| ------------------------- | --------------------------------------------------------------------------------------- |
| `memchr-skip.d`           | Rare-byte skipping dominates naive scanning; measured on a fixed in-repo corpus.        |
| `two-way-search.d`        | Critical factorization and its constant-space guarantee.                                |
| `bitap-shift-or.d`        | Bit-parallel NFA simulation for patterns ≤ word size.                                   |
| `myers-edit-distance.d`   | Bit-vector edit distance; the approximate-search primitive.                             |
| `levenshtein-automaton.d` | Bounded-distance matching as a DFA over the pattern.                                    |
| `aho-corasick-build.d`    | Goto/fail/output construction and single-transition-per-byte behaviour.                 |
| `teddy-shape.d`           | Why SIMD multi-pattern prefilters cap at small pattern counts and short lengths.        |
| `lazy-dfa-cache.d`        | DFA state explosion and the cache-reset behaviour a lazy DFA must handle.               |
| `trigram-postings.d`      | Build a positional trigram index over the repo; show candidate-set shrinkage.           |
| `trigram-query-plan.d`    | Regex → trigram boolean query, and the patterns that degenerate to a full scan.         |
| `suffix-array-locate.d`   | SA construction + binary-search locate; the space/time baseline for compressed indexes. |
| `bwt-lf-mapping.d`        | LF-mapping and backward search — the FM-index core in ~60 lines.                        |
| `bm25-topk.d`             | BM25 over a toy postings list with a top-K heap; then the Block-Max early exit.         |
| `read-vs-mmap.d`          | The mmap policy question: single large file vs many small files.                        |
| `parallel-walk.d`         | Work-stealing traversal and the ordering guarantee it gives up.                         |
| `utf8-case-fold.d`        | Simple vs full case folding, and what "smart case" actually decides.                    |
| `binary-sniff.d`          | NUL-byte heuristics and the false-positive corpus.                                      |
| `gpu-scan-compute.d`      | A Vulkan compute prefilter over a mapped buffer, using the repo's existing erupted      |
|                           | bindings — the one example that makes the GPU cluster concrete rather than cited.       |

Every example must be portable-green: gate on `platforms` in the embedded `dub.sdl`, and
print `SKIP:` + exit `0` where the host lacks a capability (no Vulkan device, no AVX2).
The GPU example in particular must skip cleanly on a headless CI runner.

Corpus discipline: examples that measure anything must run against a **fixed, in-repo
corpus** (a generated file with a known match distribution), never against the working
tree — otherwise the numbers in the prose drift with every commit and the `ci --verify`
output diff goes red for the wrong reason.

## 10. The measurement protocol

`measurement.md` is authored **before** any comparative claim is written, and is the page
`comparison.md` defers to. It must specify:

- **Corpora** — at minimum: a large single file with a rare literal, a large single file
  with a high match count, a many-small-files tree, a tree with deep ignore rules, a
  non-ASCII corpus, and a repetitive corpus (versioned history) where run-length indexes
  are supposed to shine.
- **Query classes** — rare literal, common literal, case-insensitive literal, alternation
  of literals, regex with a literal prefix, regex with no extractable literal, anchored,
  bounded-repetition, Unicode class.
- **What is held constant** — match counts must be reported per row; a tool that finds a
  different number of lines is not a comparable data point.
- **Cold vs warm cache** — both, stated explicitly, with the drop procedure recorded.
- **Process overhead** — millisecond-scale results measure `fork`/`exec`, not search.
  Corpus sizes must push the measured phase well above that floor.
- **Statistics** — reuse the repository's existing
  [benchmarking guidelines](../../guidelines/benchmarking-and-profiling.md): repeated
  trials, bootstrap confidence intervals, and a nonparametric test rather than a
  single-run ratio.
- **Output normalisation** — line numbers, colour, and counting change the answer
  materially in some tools and not others; the protocol must fix the flags and say so.

## 11. `sparkles-baseline.md`

Audit only what is observably true in the tree today:

- what `hue`'s picker currently does for content search versus path search, and where the
  [`sparkles:fuzzy`](../../specs/fuzzy/SPEC.md) boundary sits;
- whether any content search exists at all, and what it shells out to if so;
- the `libs/base` text facilities available to a matcher (readers, Unicode analysis,
  `@nogc` text handling) and what is missing;
- SIMD availability under LDC (`core.simd`, `ldc.simd`, intrinsics, target attributes,
  runtime dispatch) and what the repo already does about runtime feature detection;
- the async-I/O substrate already researched in [`async-io/`](../async-io/index.md) —
  particularly `io_uring` — and whether a search backend could plausibly use it;
- the Vulkan/`erupted` compute path available for the GPU example;
- the CI hosts available, so the plan does not promise host-verification it cannot do.

## 12. Execution phases

Each phase is small enough to finish and commit atomically.

### Phase 0 — Frame and vocabulary

`concepts.md`, `theory/index.md`, `measurement.md`, `sparkles-baseline.md`, and the
seam statement in `index.md`. Nothing comparative yet.

**Exit condition:** every term the later pages need is defined once, and the measurement
protocol exists before the first number is written.

### Phase 1 — Scanners

GNU grep, ripgrep, ugrep, `git grep`, the Silver Searcher, hypergrep, long tail. Read
each one's actual source; the interesting divergences (ugrep's unaffected `-n` cost,
ripgrep's deliberate mmap policy, `git grep`'s object-store access) are visible only
there.

**Exit condition:** the ten-dimension spine is filled for every scanner, with match
counts recorded for any timing claim.

### Phase 2 — Engines and primitives

`rust-regex` first — it is the field's most thoroughly documented meta-engine and the
best organising frame for RE2, PCRE2, Vectorscan, Oniguruma, and .NET's non-backtracking
engine. Then `literal-prefilters.md` and `multi-pattern.md`, which Phase 1 will have
demanded repeatedly.

**Exit condition:** `engine-comparison.md` can state, per engine, the worst case it
prevents and the price it pays.

### Phase 3 — Theory backfill

Write `theory/` from what Phases 1–2 actually needed, not from a textbook table of
contents. Attach the runnable examples here; this is where they carry the most weight.

**Exit condition:** every algorithm named in a scanner or engine page has a definition
page and, where demonstrable, a compiled example.

### Phase 4 — Indexes

n-gram family (Google Code Search → Zoekt → livegrep) → suffix structures →
compressed self-indexes → Lucene/tantivy/PISA → embedded FTS. Zoekt's design doc and
tantivy's on-disk format are the two richest primary sources.

**Exit condition:** T2 and T3 are answerable with crossover reasoning, not intuition.

### Phase 5 — Acceleration

GPU automata, GPU retrieval, hardware automata, wide SIMD. Reconstruct each paper's
baseline before tabulating anything. Build at least one artifact if it builds cleanly;
otherwise say so and label the figures `[paper-claim]`.

**Exit condition:** T4 resolved with named baselines, or explicitly recorded as
unresolvable from available evidence.

### Phase 6 — Systems, semantics, and boundaries

`corpus-access.md`, `unicode-semantics.md`, `approximate-search.md`,
`structural-search.md`, `interactive-contracts.md`.

**Exit condition:** T1 and T5 have evidence; the structural-search boundary is stated
without turning into a second survey.

### Phase 7 — Synthesis

`comparison.md` then `recommendations.md`. The comparison resolves all five theses,
records the benchmark-methodology critique, and produces a ranked-leverage list. The
recommendations stage a Sparkles path and name, per milestone: the deliverable, the
selected prior art, the D/LDC feasibility risk, the measurement that would falsify the
choice, and what is deliberately deferred.

**Exit condition:** the synthesis is derivable entirely from the deep-dives; no orphan
assertions.

### Phase 8 — VitePress integration and validation

Sidebar groups under Research: umbrella/concepts/baseline; Theory; Scanners; Engines and
primitives; Indexes; Acceleration; Systems and semantics; Synthesis. Then:

```bash
npx prettier --write 'docs/research/full-text-search/**/*.md' docs/.vitepress/config.mts
npm run docs:build
dub run :ci -- --verify --files 'docs/research/full-text-search/**/*.md'
dub run :ci -- --example-files 'docs/research/full-text-search/**/examples/*.d'
nix run .#ci -- --check-blob-paths
git diff --check
```

`SKIP=lychee,verify-md-examples` is acceptable for the large docs commit; run the link
check separately afterward. Bypassing a hook is not evidence of passing it.

## 13. Commit plan

1. `chore(research): register full-text-search tree` — sidebar, `.editorconfig`,
   `ignoreDeadLinks` for `.d` example links.
2. `docs(research): frame full-text search` — concepts, theory index, measurement,
   baseline.
3. `docs(research): survey grep-lineage scanners`.
4. `docs(research): survey regex engines and literal prefilters`.
5. `docs(research): add full-text search theory and examples`.
6. `docs(research): survey text index structures`.
7. `docs(research): survey hardware-accelerated matching`.
8. `docs(research): survey search systems and semantics layers`.
9. `docs(research): add full-text search synthesis`.
10. Review fixups, autosquashed only after approval.

Because the tree cross-links densely, commits 2–9 may not each pass the dead-link build
in isolation; either order the sidebar commit last or combine, as
[`research-docs.md`](../../guidelines/research-docs.md) permits.

## 14. Definition of done

- [ ] Every planned page exists or is explicitly removed from scope with rationale.
- [ ] The seam with `fuzzy-matching/` and `parsing/` is stated in `index.md` and no
      subject is surveyed twice.
- [ ] Every deep-dive follows the skeleton and the ten-dimension spine.
- [ ] Every deep-dive carries at least one verbatim, pinned primary-source quote.
- [ ] Every open-source subject records its clone and 40-character reviewed SHA.
- [ ] Every academic subject records venue, baseline, and hardware, labelled
      `[paper-claim]` or `[artifact-verified]`.
- [ ] No cross-tool timing table mixes harnesses; every row reports its match count.
- [ ] `measurement.md` predates every comparative claim and is cited by them.
- [ ] All five theses are resolved or explicitly recorded as unresolved.
- [ ] Runnable examples compile and run in CI, skip cleanly where the host lacks a
      capability, and measure only the fixed in-repo corpus.
- [ ] `index.md` and `comparison.md` carry `**Last reviewed:**` dates.
- [ ] `npm run docs:build`, `ci --verify`, `ci --example-files`, and
      `--check-blob-paths` all pass.
- [ ] Recommendations reflect the evidence rather than preceding it, and name the
      measurement that would falsify each choice.
- [ ] Nothing pushed without explicit authorization.

<!-- References -->

[measurement]: ./measurement.md
