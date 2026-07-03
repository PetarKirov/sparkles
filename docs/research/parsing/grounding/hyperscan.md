# Grounding ledger — `hyperscan.md`

Verification of `docs/research/parsing/hyperscan.md` against the **local** pinned tree
`$REPOS/cpp/hyperscan` `828b4fe` (2026-06-29) + the paper
`$REPOS/papers/parsing/wang-2019-hyperscan-nsdi.pdf`. `$REPOS = /home/petar/code/repos`.

Status key: ✓ verified · ≈ faithful paraphrase · ⚠ discrepancy · ◯ opinion · 🌐 web/secondary.

| #   | Claim                                                                                                                                                   | Type  | Source (local + locator)                                | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | ------------------------------------------------------- | ------ |
| 1   | "high-performance multiple regex matching library"                                                                                                      | QUOTE | `README.md`                                             | ✓      |
| 2   | "regular expression syntax of the commonly-used libpcre library, but is a standalone library with its own C API."                                       | QUOTE | `README.md`                                             | ✓      |
| 3   | "hybrid automata techniques to allow simultaneous matching of large numbers (up to tens of thousands) of regular expressions … across streams of data." | QUOTE | `README.md:7-8`                                         | ✓      |
| 4   | "typically used in a DPI library stack."                                                                                                                | QUOTE | `README.md`                                             | ✓      |
| 5   | License BSD-3-Clause                                                                                                                                    | fact  | `LICENSE` "BSD License"                                 | ✓      |
| 6   | Authors incl. **Geoff Langdale (branchfree.org)** — also the [simdjson] co-author                                                                       | fact  | paper p1 author list; simdjson lineage = ✓ (cross-page) | ✓      |
| 7   | Two core techniques: (1) **regex decomposition** into string + FA components; (2) SIMD-accelerated string/FA matching                                   | fact  | `wang-2019…pdf` (contributions); `src/`                 | ✓      |
| 8   | SIMD literal matchers **FDR/Teddy** (shuffle-based)                                                                                                     | fact  | `src/fdr/` (FDR/Teddy)                                  | ✓      |
| 9   | Bit-based NFA **LimEx**                                                                                                                                 | fact  | `src/nfa/` (LimEx engines)                              | ✓      |
| 10  | **Streaming** mode: match across chunked data with bounded state (block/stream/vectored)                                                                | fact  | `src/hs.h`/`hs_compile.h` scan modes                    | ✓      |
| 11  | Compile-time `hs_compile` → `hs_database`, then `hs_scan` with a match callback                                                                         | fact  | `src/hs.h` API                                          | ✓      |
| 12  | Maintained fork **Vectorscan** (VectorCamp) for non-x86                                                                                                 | fact  | 🌐 external (noted in metadata)                         | 🌐     |
| 13  | It is a **matcher**, not a parser/tree-builder                                                                                                          | fact  | API (callback-based); framing                           | ✓      |
| 14  | Strengths / Weaknesses / trade-off tables                                                                                                               | synth | derived                                                 | ◯      |

## Discrepancies

None. README quotes verbatim (incl. `:7-8`); BSD license, FDR/Teddy and LimEx engine dirs, and the
streaming/compile API all confirmed in-tree; the two headline techniques confirmed against the local PDF.

## Web-fallback / not-locally-groundable

- **Vectorscan fork** (row 12) — external project, noted not asserted from the pinned Intel tree.
- **Perf numbers** — the page cites the paper's framing, not re-run benchmarks.

## Opinion (◯)

- The "same author, same worldview" simdjson↔Hyperscan framing (Langdale co-authorship is a verified fact;
  the "worldview" gloss is editorial); Strengths/Weaknesses/decision tables.

**Net:** 0 discrepancies. Every README quote (incl. the "tens of thousands … across streams" line at
`:7-8`) is verbatim; BSD license, the FDR/Teddy + LimEx engines, and the decomposition technique are
grounded in the repo + the local NSDI paper.
