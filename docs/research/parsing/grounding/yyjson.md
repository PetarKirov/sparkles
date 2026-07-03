# Grounding ledger — `yyjson.md`

Verification of `docs/research/parsing/yyjson.md` against the **local** pinned tree
`$REPOS/c/yyjson` `12797c6` (2026-07-02). `$REPOS = /home/petar/code/repos`.

Status key: ✓ verified · ≈ faithful paraphrase · ⚠ discrepancy · ◯ opinion · 🌐 web/secondary.

| #   | Claim                                                                                     | Type   | Source (local + locator)                   | Status |
| --- | ----------------------------------------------------------------------------------------- | ------ | ------------------------------------------ | ------ |
| 1   | "Fast: can read or write gigabytes of JSON data per second on modern CPUs."               | QUOTE  | `README.md` Features                       | ✓      |
| 2   | **"Portable: complies with ANSI C (C89), no explicit SIMD."** (the load-bearing framing)  | QUOTE  | `README.md:14`                             | ✓      |
| 3   | "Strict: complies with RFC 8259 … strict number formats and UTF-8 validation."            | QUOTE  | `README.md` Features                       | ✓      |
| 4   | "Developer-Friendly: easy integration with just one `.h` and one `.c` file."              | QUOTE  | `README.md` Features                       | ✓      |
| 5   | "Accuracy: can accurately read and write int64, uint64, and double numbers."              | QUOTE  | `README.md` Features                       | ✓      |
| 6   | License MIT                                                                               | fact   | `LICENSE` "MIT License"                    | ✓      |
| 7   | Single-allocation contiguous `yyjson_doc` owning a `yyjson_val` array (tape/DOM hybrid)   | fact   | `src/yyjson.h` (`yyjson_doc`/`yyjson_val`) | ✓      |
| 8   | Immutable-doc vs mutable-doc; read/write flags (INSITU, NUMBER_AS_RAW, …)                 | fact   | `src/yyjson.h` flag enums; `yyjson.c`      | ✓      |
| 9   | Own fast number reader/writer (not libc `strtod`)                                         | fact   | `src/yyjson.c` number routines             | ≈      |
| 10  | JSON Pointer / Patch / Merge-Patch support                                                | fact   | `src/yyjson.h` (pointer/patch APIs)        | ✓      |
| 11  | Category framing: high-perf JSON that reaches GB/s **without** SIMD (scalar counterpoint) | interp | rows 1–2 (its own claims)                  | ◯      |
| 12  | Strengths / Weaknesses / trade-off tables                                                 | synth  | derived                                    | ◯      |

## Discrepancies

None. All five README Feature bullets are verbatim; the no-SIMD framing (the page's spine) is
`README.md:14` verbatim; MIT license exact.

## Web-fallback / not-locally-groundable

- **Comparative benchmark numbers** vs simdjson/RapidJSON — the page cites yyjson's own "GB/s" claim
  (README) but does not assert third-party head-to-head figures as fact.

## Opinion (◯)

- The "careful scalar C rivals SIMD" thesis (a legitimate reading of yyjson's own no-SIMD + GB/s claims);
  Strengths/Weaknesses/decision tables.

**Net:** 0 discrepancies. The whole page rests on five verbatim README Feature quotes + the MIT license +
the arena/doc-val structure read in-header; the "no-SIMD high-performance counterpoint" is yyjson's own stance.
