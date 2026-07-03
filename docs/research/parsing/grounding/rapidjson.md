# Grounding ledger — `rapidjson.md`

Verification of `docs/research/parsing/rapidjson.md` against the **local** pinned tree
`$REPOS/cpp/rapidjson` `24b5e7a` (2025-02-05). `$REPOS = /home/petar/code/repos`.

Status key: ✓ verified · ≈ faithful paraphrase · ⚠ discrepancy · ◯ opinion · 🌐 web/secondary.

| #   | Claim                                                                                      | Type   | Source (local + locator)                                                    | Status |
| --- | ------------------------------------------------------------------------------------------ | ------ | --------------------------------------------------------------------------- | ------ |
| 1   | "A fast JSON parser/generator for C++ with both SAX/DOM style API"                         | QUOTE  | `readme.md`                                                                 | ✓      |
| 2   | "Copyright (C) 2015 THL A29 Limited, a Tencent company, and Milo Yip."                     | QUOTE  | `readme.md`                                                                 | ✓      |
| 3   | Release `v1.1.0` (2016-08-25)                                                              | fact   | `readme.md` badge + "Highlights in v1.1" section                            | ✓      |
| 4   | License MIT (source); `bin/jsonchecker/` alone under the "JSON License" (do-no-evil)       | fact   | `license.txt`; `bin/jsonchecker/readme.txt`                                 | ✓      |
| 5   | Dual **SAX** (event) + **DOM** (`GenericDocument`/`GenericValue`) API                      | fact   | `doc/sax.md`, `doc/dom.md`; `include/rapidjson/`                            | ✓      |
| 6   | **In-situ** parsing (`ParseInsitu`) — zero-copy by destructively editing the source buffer | fact   | `doc/dom.md`; `include/rapidjson/document.h`                                | ✓      |
| 7   | `MemoryPoolAllocator` for DOM allocation                                                   | fact   | `include/rapidjson/` allocator                                              | ✓      |
| 8   | SIMD **only** for `SkipWhitespace`/string scan (SSE2/SSE4.2/NEON) — NOT a full-SIMD parser | fact   | `include/rapidjson/reader.h` (`SkipWhitespace_SIMD`, `ParseStringToStream`) | ✓      |
| 9   | Compile-time-gated SIMD, no runtime dispatch (contrast simdjson)                           | fact   | `reader.h` `#if defined(RAPIDJSON_SSE2)…`                                   | ✓      |
| 10  | Header-only; `Encoding`/UTF transcoding; error offset on failure                           | fact   | `include/rapidjson/`; `doc/`                                                | ≈      |
| 11  | "4× faster / 18.7 vs 8.3 instr/byte" figures                                               | figure | **simdjson's** numbers (attributed to simdjson, not measured here)          | 🌐     |
| 12  | Strengths / Weaknesses / trade-off tables                                                  | synth  | derived                                                                     | ◯      |

## Discrepancies

**D-R1 (in-tree source disagreement, surfaced in a page NOTE, not a page error).** `readme.md` cites
RFC 7159/ECMA-404; `doc/features.md` cites the older RFC 4627/ECMA-404. The page treats the README
(newer RFC) as authoritative and flags the discrepancy in a NOTE. No fabrication.

## Web-fallback / not-locally-groundable

- **No in-repo throughput figures:** `doc/performance.md` only links external suites (nativejson-benchmark).
  The "4×/instructions-per-byte" numbers are **simdjson's**, cited to simdjson for the contrast — no
  RapidJSON-measured throughput is asserted as fact (row 11).

## Opinion (◯)

- The historical "pre-simdjson fast-C++ standard" positioning; Strengths/Weaknesses/decision tables.

**Net:** 0 fabricated claims. Quotes + license + version + the narrow-SIMD design are verbatim/exact-grounded;
the one in-tree RFC discrepancy is surfaced honestly, and the only external numbers are attributed to simdjson.
