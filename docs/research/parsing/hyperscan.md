# Hyperscan (C / C++)

A SIMD-accelerated **multi-pattern** regular-expression matcher that decomposes each regex into string and finite-automata components, matches tens of thousands of patterns simultaneously, and scans **across streams** of data with bounded state — "[a] high-performance multiple regex matching library" whose lineage runs straight into [`simdjson`][simdjson] (Geoff Langdale co-authored both).

| Field               | Value                                                                                                                         |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Language            | C API + C runtime; C++ compiler (the pattern-compilation backend)                                                             |
| License             | BSD-3-Clause ([`LICENSE`][license])                                                                                           |
| Repository          | [`intel/hyperscan`][repo] · maintained fork [`VectorCamp/vectorscan`][vectorscan] (portable/non-x86)                          |
| Documentation       | [Developer Reference Guide][devref] · [`doc/dev-reference/`][devref-src]                                                      |
| Key authors         | Xiang Wang, Yang Hong, Harry Chang, KyoungSoo Park (KAIST), **Geoff Langdale (branchfree.org)**, Jiayu Hu, Heqing Zhu (Intel) |
| Category            | SIMD / data-parallel (multi-pattern regex matcher)                                                                            |
| Algorithm class     | Hybrid NFA/DFA + SIMD literal matching (FDR/Teddy string matchers, LimEx bit-NFA), driven by regex decomposition              |
| Performance posture | SIMD-accelerated, streaming, tens-of-thousands of patterns in one pass                                                        |
| Latest release      | `v5.4.2` (April 19, 2023 — [`CHANGELOG.md`][changelog], [`hs.h`][hs-h])                                                       |
| Notes               | libpcre-**subset** syntax, standalone C API; the canonical DPI (deep packet inspection) regex engine                          |

> [!NOTE]
> Hyperscan is not a parser _generator_ or a combinator library, and it does not build a syntax tree — it is a **matcher**: it reports which of a compiled set of regexes match, and where they end, via a callback. Its interest to this survey is entirely in **how** it matches: it recasts multi-regex matching as SIMD-parallel string + bit-automata work, the same data-parallel philosophy that [`simdjson`][simdjson] applies to JSON structure. The two share an author (Geoff Langdale) and a worldview — replace per-byte branchy automata with wide branchless vector arithmetic. Compare it against the character-at-a-time [table-driven LR][bottom-up] and [recursive-descent][top-down] engines that dominate the rest of the catalog in the [capstone comparison][comparison].

---

## Overview

### What it solves

Deep packet inspection (DPI) — intrusion detection, application identification, web-application firewalls — needs to match a large ruleset of regexes against every byte of traffic, and "_it often becomes the performance bottleneck as it involves compute-intensive scan of every byte of packet payload_" ([Wang et al. 2019][paper], Abstract). Two structural facts make the naïve approach slow: matching one regex at a time requires a pass per pattern, and converting a whole complex regex to a single automaton either explodes the DFA state count or falls back to a slow NFA doing "_O(m) memory lookups_" per input character ([paper][paper], §1–2).

The de-facto workaround before Hyperscan was **prefiltering**: extract a literal string per regex, run fast multi-string matching (typically Aho–Corasick), and invoke the expensive regex engine only when its literal is seen. Hyperscan's thesis is that prefiltering is doubly wasteful — the literals are hand-chosen and don't scale, and "_string matching and regex matching are executed as two separate tasks_," re-matching the same literal twice ([paper][paper], §1). Hyperscan folds string matching _into_ regex matching and makes it drive the whole schedule.

The headline result, from the abstract:

> _"Hyperscan employs two core techniques for efficient pattern matching. First, it exploits graph decomposition that translates regular expression matching into a series of string and finite automata matching. … Second, Hyperscan accelerates both string and finite automata matching using SIMD operations, which brings substantial throughput improvement. Our evaluation shows that Hyperscan improves the performance of Snort by a factor of 8.7 for a real traffic trace."_
> — [Wang, Hong, Chang, Park, Langdale, Hu, Zhu, _Hyperscan: A Fast Multi-pattern Regex Matcher for Modern CPUs_, NSDI '19][paper]

The [`README`][repo-readme] states the product framing plainly: Hyperscan "_uses hybrid automata techniques to allow simultaneous matching of large numbers (up to tens of thousands) of regular expressions and for the matching of regular expressions across streams of data,_" and is "_typically used in a DPI library stack._" It "_follows the regular expression syntax of the commonly-used libpcre library, but is a standalone library with its own C API._"

### Design philosophy

Three ideas run through the codebase and the paper:

1. **Regex decomposition first.** Rather than compile each regex to one automaton, split it into a chain of literal-string components and finite-automata (FA) components, and let fast string matching decide when each FA needs to run. "_Regex decomposition splits a regex pattern into a series of disjoint string and FA components_" ([paper][paper], Abstract); because each decomposed FA "_tend[s] to be smaller than the original pattern_" it is more likely to fit a fast DFA rather than fall back to an NFA ([paper][paper], Abstract).

2. **SIMD everywhere, branchless where possible.** Both halves — string matching (FDR/Teddy) and FA matching (the bit-based NFA) — are built to "_leverage CPU's compute capability on data parallelism_" ([paper][paper], §1). String matching extends the shift-or algorithm to run on 128-bit vectors; the NFA holds automaton states as bit positions in a SIMD register and computes transitions with vector shifts and ANDs.

3. **Bounded-state streaming.** Because DPI sees traffic as packets, a match may straddle packet boundaries. Hyperscan supports scanning "_multiple blocks without retaining old data and with a fixed-at-pattern-compile-time amount of stream state_" ([paper][paper], §7.1) — the memory footprint is known at compile time, and no allocation happens on the scan path.

Hyperscan is peer-reviewed ([NSDI '19][paper]), open-sourced by Intel under a BSD license in 2015, and, by the paper's own account, "_adopted by over 40 commercial projects globally … in production use by tens of thousands of cloud servers_" ([paper][paper], §7.1).

---

## How it works

Hyperscan is split into a **compile-time** path (C++: regex → NFA graph → decomposition → matcher bytecode, producing an immutable `hs_database_t`) and a **run-time** path (C: `hs_scan` and friends walk the database over input, firing a callback per match). From [`intro.rst`][intro]:

> _"These functions take a group of regular expressions … and compile them into an immutable database that can be used by the Hyperscan scanning API. This compilation process performs considerable analysis and optimization work in order to build a database that will match the given expressions efficiently."_

### 1. Regex decomposition on the Glushkov NFA graph

Hyperscan builds a **Glushkov NFA** for each pattern — chosen because "_it does not have epsilon transitions … [and] all transitions into a given state are triggered by the same input symbol_" ([paper][paper], §2), which is exactly the invariant the bit-NFA later exploits. A _linear_ regex is then expressed as

```text
/FAn strn FAn−1 strn−1 · · · str2 FA1 str1 FA0/
```

where each `str` is an indivisible literal and each `FA` a (possibly empty) finite-automaton component. "_For any successful match of the original regex, all strings must be matched in the same order as they appear_" ([paper][paper], §3.1) — so string matching is the entry point, and each FA has its own switch that is off by default and is only turned on once its left neighbour has matched (rule quoted verbatim in [paper][paper], §3.1). This is why an FA runs "_only when it is needed_," slashing wasted automaton work.

Finding the _right_ literals is not textual — a string can hide behind a character class (`[il1]`), an alternation, or a bounded repeat. Hyperscan runs three graph analyses over the NFA to extract literals on the critical path ([paper][paper], §3.3):

| Analysis            | Idea                                                                                                                 |
| ------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **Dominant path**   | Find the longest string common to every dominant path of every accept state (a necessary-condition string)           |
| **Dominant region** | Find a cut-set region of string/small-character-set vertices that separates start from all accept states             |
| **Network flow**    | For generic graphs, score edges by inverse string length and run **max-flow min-cut** to pick the longest-string cut |

On real IDS rulesets these find good literals for 97.2%–99.2% of decomposable rules, and "_87% to 94% of the regex rules in IDSes have at least one extractable string_" ([paper][paper], §3.1, Table 1). The decomposition/scheduling machinery is the **Rose** subsystem ([`src/rose/`][rose] — "_Everything you ever needed to feed literals in and get a `RoseEngine` out_," [`rose_build.h`][rose-build]), which supersedes the original prefiltering design ([paper][paper], §7.1).

### 2. FDR and Teddy — SIMD multi-literal matching

The literals feed a SIMD multi-string matcher, **FDR** (`src/fdr/` — the runtime entry is [`fdrExec`][fdr-h], "_Block-mode scan_"). FDR is a two-stage filter-then-verify design ([paper][paper], §4.1, Fig. 6): a fast **extended shift-or** first pass flags candidate positions, then a hash + exact-compare verification stage confirms real matches.

The shift-or extension is the SIMD core. Classical shift-or matches a _single_ pattern by keeping a state mask and, per input byte `x`, doing `st = (st << 1) | sh_mask[x]`; a zero bit propagating to the pattern-length position signals a match ([paper][paper], §4.1, Fig. 7). Hyperscan generalizes it to _many_ patterns at once:

- Patterns are sorted by length and partitioned into **8 buckets** by a dynamic-programming cost model that keeps similar-length patterns together ([paper][paper], §4.1, "Pattern grouping").
- Each `sh_mask` byte encodes, per bit, which buckets have that character at that position — so one mask update advances all buckets in parallel.
- Byte position is counted from the _right_, which lets FDR **pre-shift masks for 8 input bytes in parallel** and OR them, turning the serially-dependent shift-or recurrence into instruction-level-parallel SIMD (`pslldq` / `por` on 128-bit masks): "_FDR exploits instruction-level parallelism by pre-shifting the sh-masks with multiple input characters in parallel … effectively increas[ing] instructions per cycle_" ([paper][paper], §4.1, "SIMD acceleration"; Algorithm 1).
- **Super-characters** (an m-bit char folding in low bits of the next byte, m ≈ 9–15) suppress cross-pattern false positives within a bucket ([paper][paper], §4.1).

**Teddy** ([`src/fdr/teddy.h`][teddy-h] — "_Teddy literal matcher_") is the shorter-literal sibling: a `PSHUFB`-based shuffle matcher that classifies input nibbles against 1–4 mask lanes, matching short literals (≤ 8 bytes) at very high throughput. Hyperscan 5.4 added "**Fat Teddy**" with AVX-512 VBMI support and shuffle-based DFA engines ("Sheng32"/"Sheng64") ([`CHANGELOG.md`][changelog], 5.4.0).

### 3. LimEx — the bit-based Glushkov NFA

When an FA component can't be a small DFA (Hyperscan falls back to NFA above a threshold of **16,384 DFA states**, [paper][paper], §4.2), it runs the **bit-based NFA** (the `LimEx` engine, [`src/nfa/limex_*`][limex]). Each NFA state is one bit in a SIMD register (up to a hard limit of **512 states** in "_one or more SIMD registers_," [paper][paper], §7.1); a set of active states is a bitmask, and a transition on input `c` is three vector steps ([paper][paper], §4.2, Algorithm 2):

1. Compute successors reachable by **typical** transitions (span ≤ shift-limit) as `OR over k of ((S & shift_k_mask) << k)` — shared shift-`k` masks, no per-state lookups.
2. Add successors from **exceptional** transitions (long-span or backward edges) via per-state successor masks.
3. AND with `reach[c]` (states enterable on `c`) — valid because a Glushkov NFA enters each state only on one symbol.

The shift-limit is tuned to 7 ([paper][paper], §4.2). The whole step is branchless vector arithmetic on 128- to 512-bit masks — the SIMD analogue of a per-byte NFA step, which is where the "_24.8x to 40.1x performance improvement over PCRE_" comes from ([paper][paper], §1).

### 4. Block, streaming, and vectored scanning

A database is compiled for exactly one of three scan modes ([`compilation.rst`][compilation]; flags in [`hs_compile.h`][hs-compile]):

| Mode          | Flag                                  | Data model                                                       | State                                  |
| ------------- | ------------------------------------- | ---------------------------------------------------------------- | -------------------------------------- |
| **Block**     | `HS_MODE_BLOCK` (`hs_scan`)           | one contiguous buffer, scanned in a single call                  | none retained                          |
| **Streaming** | `HS_MODE_STREAM` (`hs_scan_stream`)   | a continuous stream of blocks; matches may span block boundaries | fixed-size **stream state** per stream |
| **Vectored**  | `HS_MODE_VECTORED` (`hs_scan_vector`) | a list of non-contiguous blocks available all at once            | none retained                          |

Streaming is the differentiator: "_blocks of data are scanned in sequence and matches may span multiple blocks in a stream … each stream requires a block of memory to store its state between scan calls_" ([`compilation.rst`][compilation]). The sizes of both scratch and stream state are fixed at compile time, so "_no memory allocations occur at runtime_" and "_any pattern that has successfully been compiled … can be scanned against any input_" with no runtime resource errors ([`intro.rst`][intro]). Matches are delivered synchronously through a user callback, `match_event_handler(id, from, to, flags, context)` ([`hs_runtime.h`][hs-runtime]) — `id` is the pattern's user-assigned integer, `to` the end offset.

---

## Algorithm & grammar class

Hyperscan matches **regular languages** — the class recognized by finite automata ([formal languages][formal]) — but never as a textbook does. It is a hybrid of three engine families, chosen per component at compile time:

- **String components are matched with SIMD-parallel shift-or / shuffle** (FDR, Teddy), not a DFA walk. This is finite-automaton work (each literal is a trivial DFA) reformulated as branchless bit/vector arithmetic over fixed-width windows — the same data-parallel-automaton reformulation [`simdjson`][simdjson] uses for structural scanning.
- **FA components are matched with a fast DFA where the state count is small, else the LimEx bit-NFA.** Both are classical constructions ([Glushkov NFA][formal]); the novelty is packing states into SIMD lanes so a transition is a vector op, not a table lookup.
- **Scheduling is by literal matching (Rose)**, so most FA engines never run.

The theory underneath is finite automata over regular expressions — the same `regex → NFA/DFA` pipeline surveyed under [formal languages][formal] and, from the other direction, the [derivatives][derivatives] view of regex matching. What Hyperscan adds is not expressive power (it is strictly a **subset** of libpcre — see below) but a data-parallel _implementation_ of that power.

**Grammar class is fixed and regular.** Hyperscan has no grammar DSL beyond the regex syntax itself, and matches a **libpcre subset**. It explicitly rejects the context-sensitive constructs that would take it beyond regular languages ([`compilation.rst`][compilation]): "_Backreferences and capturing sub-expressions_," "_Arbitrary zero-width assertions_," "_Subroutine references and recursive patterns_," "_Atomic grouping and possessive quantifiers_," and "_Callouts and embedded code_" are all unsupported; capturing parentheses parse but "_capturing is ignored_." For full-PCRE cases, Hyperscan 5.0 ships **Chimera**, "_a hybrid matcher of Hyperscan and PCRE_" that uses Hyperscan as a prefilter and confirms with PCRE ([paper][paper], §7.1).

**Ambiguity does not arise the way it does for a CFG parser.** Because Hyperscan reports _all_ matches rather than one parse, greedy/non-greedy quantifiers collapse to a no-op (below).

## Interface & composition model

There is **no combinator, no generated code, no AST** — the interface is regexes-in, match-events-out through a C API:

| Function                                                | Role                                                                             |
| ------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `hs_compile` / `hs_compile_multi`                       | Compile one / many expressions (each with an id + flags) into an `hs_database_t` |
| `hs_alloc_scratch`                                      | Allocate the fixed-size per-thread scratch used during scanning                  |
| `hs_scan`                                               | Block-mode scan of a buffer                                                      |
| `hs_open_stream` / `hs_scan_stream` / `hs_close_stream` | Streaming scan across sequential blocks                                          |
| `hs_scan_vector`                                        | Vectored scan across non-contiguous blocks                                       |
| `hs_serialize_database` / `hs_deserialize_database`     | Persist / relocate a compiled database across hosts                              |

Databases are "_immutable_" and "_can be serialized and relocated, so that they can be stored to disk or moved between hosts_" and even "_targeted to particular platform features (for example … Intel AVX2)_" ([`intro.rst`][intro]). Composition is with the host program — you register a callback and correlate matches by their integer `id` — not with other parsers. Hyperscan 5.0 added **logical combinations** (user-defined AND/OR/NOT over patterns) so a match can require a boolean combination of sub-patterns ([paper][paper], §7.1).

## Performance

Performance is the entire raison d'être, and the [paper][paper] is concrete (Intel Xeon Platinum 8180 @ 2.5 GHz, single core, Hyperscan v5.0):

- **Whole-application.** Porting the Snort IDS to Hyperscan (HS-Snort) lifts throughput from 113 Mbps to 986 Mbps on a real web-traffic trace — "_a factor of 8.73 performance improvement_" ([paper][paper], §6.4).
- **Multi-string (FDR) vs. the state of the art.** FDR beats DFC by **1.1×–3.2×** on random packets and **1.3×–2.5×** on real traffic (and Aho–Corasick by 3.2×–8.8×) ([paper][paper], §6.3, Figs. 11–12).
- **Regex vs. PCRE/RE2.** Matching one regex at a time, Hyperscan-s outperforms PCRE by **40.1×** (Talos) / **24.8×** (Suricata) and PCRE2 (JIT) by 2.3× / 1.8×; matching all patterns in parallel, Hyperscan-m beats RE2-m by 13.5× / 8.4× ([paper][paper], §6.3, Table 5).
- **Decomposition payoff.** Regex-matching invocations drop by **over two orders of magnitude** versus prefiltering — up to 697.7× fewer on the Talos ruleset — because FA components run only when their literals fire ([paper][paper], §6.2, Tables 3–4).
- **Scale.** Designed for "_up to tens of thousands_" of patterns in one scan ([`README`][repo-readme]); the bit-NFA caps at 512 states and DFAs at 16,384 before NFA fallback ([paper][paper], §4.2, §7.1).
- **Streaming / allocation.** Fixed-size scratch + stream state, "_no memory allocations occur at runtime_" ([`intro.rst`][intro]) — O(n) single-pass scanning with bounded, compile-time-known memory.

> [!NOTE]
> All quoted numbers are the paper's own single-core measurements on the authors' hardware and rulesets (v5.0); they are grounded in the local PDF, not independently reproduced here. The current release is `v5.4.2`.

## Error handling & recovery

Error recovery **does not apply** — Hyperscan is a matcher, not a parser. There is no syntax tree to repair and no notion of resynchronization; a scan either finds matches or doesn't, and reports each match through the callback with the pattern `id` and its `to` (end) offset. Two matching-semantics choices follow from the DPI/streaming setting and set it apart from libpcre ([`compilation.rst`][compilation], §Semantics):

- **End offsets only, by default.** "_Hyperscan's default behaviour is only to report the end offset of a match._" Start-of-match is opt-in per pattern via `HS_FLAG_SOM_LEFTMOST`, and enabling it shrinks the supported-pattern set (many bounded repeats become uncompilable with SOM on).
- **All matches reported.** Scanning `/foo.*bar/` against `fooxyzbarbar` "_will return two matches … at the ends of `fooxyzbar` and `fooxyzbarbar`_," whereas libpcre reports one. Consequently "_switching between greedy and non-greedy semantics is a no-op in Hyperscan_" — matching every occurrence is impossible to reconcile with libpcre's leftmost-greedy single-match semantics in a streaming setting where a better later match cannot be known.

Compile-time is where errors surface: an unsupported construct or an exceeded resource limit "_will be returned by the pattern compiler_" as an `hs_compile_error_t` ([`intro.rst`][intro]). Once compiled, a database is guaranteed to scan any input without runtime errors. This is the opposite end of the design space from the tolerant, tree-building, error-recovering [`tree-sitter`][tree-sitter]; the contrast is one of the sharpest in the [comparison][comparison].

## Ecosystem & maturity

Hyperscan is mature and widely deployed. It "_has been developed since 2008, and was first open-sourced in 2013_," open-sourced under BSD by Intel (after Intel acquired Sensory Networks), "_adopted by over 40 commercial projects_" and "_integrated into 37 open-source projects_," on Linux, FreeBSD, and Windows ([paper][paper], §7.1). It is the regex engine behind Snort, Suricata, and much of the DPI stack. Language bindings exist for Java, Python, Go, Node.js, Ruby, Lua, and Rust ([paper][paper], §7.1).

The one significant caveat is **hardware scope**: upstream `intel/hyperscan` targets x86-64 with SSSE3+ and is tuned for Intel SIMD (SSE, AVX2, AVX-512 VBMI). Portability to Arm/POWER and continued open development after Intel slowed upstream work is carried by the community fork **[`VectorCamp/vectorscan`][vectorscan]** — a drop-in-compatible maintained fork that adds NEON/SVE/VSX backends. New engine work in the last upstream release (5.4) — Fat Teddy, the Sheng32/Sheng64 shuffle DFAs — leans on AVX-512 VBMI ([`CHANGELOG.md`][changelog]).

Hyperscan's deepest tie to this survey is genealogical: **Geoff Langdale co-authored Hyperscan and then [`simdjson`][simdjson]** ([paper][paper] author list; simdjson author list). The FDR/Teddy "classify input bytes with `PSHUFB` shuffles, match branchlessly" technique is the direct ancestor of simdjson's `pshufb`-based structural classification — the same person carrying the same data-parallel toolkit from regex matching to JSON parsing.

---

## Strengths

- **Massively multi-pattern**: tens of thousands of regexes matched in a single pass, not one pass per pattern — the property RE2/PCRE lack.
- **Regex decomposition** cuts expensive FA work by two-plus orders of magnitude by letting cheap literal matching gate every automaton.
- **SIMD end to end**: FDR/Teddy for literals, LimEx bit-NFA and shuffle-DFAs for automata — branchless vector arithmetic instead of per-byte table walks.
- **Streaming with bounded state**: matches span block boundaries with a fixed, compile-time-known stream-state size; no runtime allocation, no runtime scan errors.
- **Serializable, platform-targetable databases**; a clean C API; synchronous callback delivery.
- **Battle-tested** DPI engine (Snort, Suricata), BSD-licensed, peer-reviewed, with broad language bindings.

## Weaknesses

- **A libpcre _subset_, not a superset.** No backreferences, no capturing (parsed but ignored), no arbitrary lookaround/zero-width assertions, no atomic groups/possessive quantifiers, no recursion. Chimera (Hyperscan + PCRE) exists only to paper over this.
- **Not a parser**: no parse tree, no capture spans, no error recovery — it answers "which patterns match and where do they end," nothing more.
- **Non-libpcre match semantics**: all-matches (greedy/non-greedy is a no-op), end-offset-only by default; start-of-match is opt-in and restricts the compilable pattern set.
- **x86-centric upstream**: tuned for Intel SIMD; Arm/POWER portability and ongoing maintenance largely live in the [`vectorscan`][vectorscan] fork.
- **Hard internal limits** (512 NFA states, 16,384 DFA states before NFA fallback) and a compile step that "_performs considerable analysis_" — compilation is far heavier than the scan.
- **Modifying the SIMD core needs microarchitecture expertise** — latency-tuned per-ISA shuffle/shift kernels.

## Key design decisions and trade-offs

| Decision                                                                             | Rationale                                                                                                             | Trade-off                                                                                           |
| ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| **Decompose each regex into string + FA components** (Rose) instead of one automaton | Cheap literal matching gates each FA; smaller FAs fit fast DFAs; 2+ orders of magnitude fewer FA invocations          | Heavy compile-time graph analysis (dominant path/region, max-flow min-cut); complex scheduling      |
| **SIMD multi-string via extended shift-or with 8 buckets** (FDR)                     | 128-bit masks + right-counted positions give instruction-level-parallel shifts; beats DFC/Aho–Corasick                | Bucket false positives need super-chars + a hash/verify second stage; literals capped at 8 bytes    |
| **`PSHUFB` shuffle matcher** (Teddy) for short literals                              | Nibble-shuffle classification matches short strings at very high throughput                                           | Separate engine from FDR; best gains need AVX-512 VBMI (Fat Teddy)                                  |
| **Bit-based Glushkov NFA** (LimEx): one state per bit, transitions as vector ops     | Avoids per-state transition-table lookups; the Glushkov single-symbol-entry invariant makes AND-with-`reach[c]` exact | Hard 512-state cap; shift-limit tuning; long/backward edges become slower "exceptional" transitions |
| **DFA where small, NFA above 16,384 states**                                         | DFA is O(1)/byte when it fits; NFA avoids state explosion for the rest                                                | Two engine families to build, tune, and choose between                                              |
| **Streaming with fixed compile-time stream state**                                   | Matches span packets; bounded, pre-allocatable memory; no runtime allocation or scan errors                           | Cannot implement libpcre greedy semantics in a stream (a better later match is unknowable)          |
| **libpcre _subset_ syntax, matches via callback, end-offset default**                | Keeps the hot path to regular-language work; all-matches semantics fits DPI                                           | No capture/backrefs/recovery; SOM is opt-in and restricts pattern support; Chimera for full PCRE    |
| **x86 SIMD-tuned upstream + community `vectorscan` fork**                            | Squeeze Intel microarchitecture; let the fork carry Arm/POWER and ongoing maintenance                                 | Upstream portability gaps; the living codebase is increasingly the fork                             |

---

## Sources

- [`intel/hyperscan` — GitHub repository][repo] · [`README.md`][repo-readme] · [Developer Reference Guide][devref]
- [`LICENSE` — BSD-3-Clause, "Copyright (c) 2015, Intel Corporation"][license]
- [`doc/dev-reference/intro.rst` — compile/scan split, streaming guarantees, no runtime allocation][intro]
- [`doc/dev-reference/compilation.rst` — scan modes, unsupported constructs, all-matches / end-offset semantics][compilation]
- [`src/fdr/fdr.h` — `fdrExec` block-mode literal scan][fdr-h] · [`src/fdr/teddy.h` — Teddy shuffle matcher][teddy-h]
- [`src/nfa/limex_*` — the LimEx bit-based Glushkov NFA][limex] · [`src/rose/rose_build.h` — Rose decomposition/scheduling][rose-build]
- [`src/hs_compile.h` — `hs_compile`, `HS_MODE_*` flags][hs-compile] · [`src/hs_runtime.h` — `hs_scan*`, `match_event_handler`][hs-runtime] · [`CHANGELOG.md` — v5.4.x][changelog]
- Xiang Wang, Yang Hong, Harry Chang, KyoungSoo Park, Geoff Langdale, Jiayu Hu, Heqing Zhu, [_Hyperscan: A Fast Multi-pattern Regex Matcher for Modern CPUs_, NSDI '19][paper]
- Maintained portable fork: [`VectorCamp/vectorscan`][vectorscan]
- Related: [umbrella][umbrella] · [concepts glossary][concepts] · [comparison][comparison] · SIMD siblings [`simdjson`][simdjson] · [`simd-json`][simd-json] · [`sonic-rs`][sonic-rs] · [`yyjson`][yyjson] · [`rapidjson`][rapidjson] · theory: [formal languages][formal] · [derivatives][derivatives]

<!-- References -->

[repo]: https://github.com/intel/hyperscan
[repo-readme]: https://github.com/intel/hyperscan/blob/828b4fef341759e05292741a6c89cb66055986f8/README.md
[vectorscan]: https://github.com/VectorCamp/vectorscan
[devref]: http://intel.github.io/hyperscan/dev-reference/
[devref-src]: https://github.com/intel/hyperscan/tree/828b4fef341759e05292741a6c89cb66055986f8/doc/dev-reference
[license]: https://github.com/intel/hyperscan/blob/828b4fef341759e05292741a6c89cb66055986f8/LICENSE
[intro]: https://github.com/intel/hyperscan/blob/828b4fef341759e05292741a6c89cb66055986f8/doc/dev-reference/intro.rst
[compilation]: https://github.com/intel/hyperscan/blob/828b4fef341759e05292741a6c89cb66055986f8/doc/dev-reference/compilation.rst
[fdr-h]: https://github.com/intel/hyperscan/blob/828b4fef341759e05292741a6c89cb66055986f8/src/fdr/fdr.h
[teddy-h]: https://github.com/intel/hyperscan/blob/828b4fef341759e05292741a6c89cb66055986f8/src/fdr/teddy.h
[limex]: https://github.com/intel/hyperscan/tree/828b4fef341759e05292741a6c89cb66055986f8/src/nfa
[rose]: https://github.com/intel/hyperscan/tree/828b4fef341759e05292741a6c89cb66055986f8/src/rose
[rose-build]: https://github.com/intel/hyperscan/blob/828b4fef341759e05292741a6c89cb66055986f8/src/rose/rose_build.h
[hs-compile]: https://github.com/intel/hyperscan/blob/828b4fef341759e05292741a6c89cb66055986f8/src/hs_compile.h
[hs-runtime]: https://github.com/intel/hyperscan/blob/828b4fef341759e05292741a6c89cb66055986f8/src/hs_runtime.h
[hs-h]: https://github.com/intel/hyperscan/blob/828b4fef341759e05292741a6c89cb66055986f8/src/hs.h
[changelog]: https://github.com/intel/hyperscan/blob/828b4fef341759e05292741a6c89cb66055986f8/CHANGELOG.md
[paper]: https://www.usenix.org/conference/nsdi19/presentation/wang-xiang
[umbrella]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[simdjson]: ./simdjson.md
[simd-json]: ./simd-json.md
[sonic-rs]: ./sonic-rs.md
[yyjson]: ./yyjson.md
[rapidjson]: ./rapidjson.md
[tree-sitter]: ./tree-sitter.md
[top-down]: ./theory/top-down.md
[bottom-up]: ./theory/bottom-up.md
[formal]: ./theory/formal-languages.md
[derivatives]: ./theory/derivatives.md
