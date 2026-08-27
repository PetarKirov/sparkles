# Vectorscan (C++) — the portable Hyperscan

Hyperscan's algorithms, forked to run outside x86 and kept under a BSD licence
after upstream's changed. This page covers what a _search_ consumer needs and
defers the automata decomposition to the existing [parsing survey][hs].

| Field             | Value                                                          |
| ----------------- | -------------------------------------------------------------- |
| Language          | C++                                                            |
| License           | BSD (following Hyperscan up to 5.4)                            |
| Repository        | [VectorCamp/vectorscan][repo]                                  |
| Surveyed revision | `4724cff398f81818b28b373ff67c41b9ed95d317` (`v5.3.0-941`)      |
| Category          | Multi-pattern regex engine                                     |
| Engine class      | Glushkov NFA decomposition + SIMD literal engines (FDR, Teddy) |
| Modes             | Block and **streaming**                                        |

> **Last reviewed:** August 28, 2026.

> [!NOTE]
> [`parsing/hyperscan.md`][hs] already surveys Hyperscan as a scanning engine for
> the syntax pipeline — FDR, Teddy, LimEx and the NSDI'19 paper. This page adds
> only what changes for _search_: portability, licensing, and the streaming
> contract.

---

## Overview

### What it solves

Matching **thousands of patterns simultaneously** in one pass, which is a
different problem from matching one pattern quickly. That is why it underpins
intrusion detection, and why [hypergrep][hypergrep] can use it for a grep at all.

### Why the fork exists

Two reasons, both stated in the README:

> _"A fork of Intel's Hyperscan, modified to run on more platforms. Currently ARM
> NEON/ASIMD and Power VSX are 100% functional. ARM SVE2 support is ongoing…"_

and, decisively for anyone choosing a dependency today:

> _"The recent license change of Hyperscan makes Vectorscan even more relevant
> for the FLOSS ecosystem."_ `[source-verified]`

Upstream Hyperscan changed licence after 5.4; Vectorscan continues the BSD line.
**Any dependency decision in this catalog must cite Vectorscan, not Hyperscan**,
and pin before the change.

Since 5.4.12 there is also a [SIMDe][simde] port, so the engine can run where no
native SIMD backend exists — the same portability strategy
[`intel-intrinsics`][baseline] takes for D.

## How it works — what matters for search

**Streaming mode** is the property no other engine here has: a pattern may match
across buffer boundaries, with bounded per-stream state. For a searcher this is
what allows scanning a file in fixed-size chunks without a roll buffer — the
problem [ripgrep][ripgrep] solves with a growable `line_buffer` instead. A
`@nogc` implementation with fixed capacity would find streaming state far more
congenial than a growable buffer, which makes this the most architecturally
interesting idea on the page.

**The pattern subset is the cost.** Hyperscan's PCRE subset excludes
backreferences and most lookaround — the same refusal [RE2][re2] makes, for the
same reason.

**Match reporting is callback-driven and unordered**, and matches may be reported
for patterns as they are found rather than in position order. Callers that need
ordering impose it themselves.

### The ten dimensions, briefly

**Pattern language**: PCRE subset, multi-pattern by construction.
**Engine**: Glushkov NFA decomposed into literal (FDR/Teddy) and automata
components. **Prefilter**: the literal engines _are_ the prefilter — the
decomposition is the design. **Corpus access**: none. **Concurrency**:
per-scratch, per-thread. **Index**: none. **Result model**: callbacks with
pattern id and end offset; start offsets require `SOM`, which costs.
**Unicode**: UTF-8 mode available. **Interactive**: none. **Measured
evidence**: published benchmarks not reproduced here.

## Strengths

- **Multi-pattern is free**, which changes what a query language can offer.
- **Streaming with bounded state** — chunked scanning without a roll buffer.
- **Genuinely portable now**: NEON/ASIMD, VSX, SVE2 in progress, SIMDe fallback.
- **BSD-licensed continuation** of a line whose upstream relicensed.

## Weaknesses

- **A large C++ dependency** with a heavyweight compile step per pattern set.
- **Start-of-match is opt-in and expensive** (`SOM`), and a grep needs it for
  highlighting.
- **Callback-driven, unordered** results.
- **The PCRE subset is a ceiling**, as with every automata engine here.
- **Compilation is slow enough** that per-keystroke recompilation is not viable —
  a hard constraint for an interactive picker.

## Key design decisions and trade-offs

| Decision                           | Rationale                                          | Trade-off                                               |
| ---------------------------------- | -------------------------------------------------- | ------------------------------------------------------- |
| Decompose into literals + automata | Literals run in SIMD; automata only where needed   | A complex compiler; long pattern-set compile times      |
| Streaming with bounded state       | Scan arbitrarily large input in fixed chunks       | Per-stream state to carry; more complex than block mode |
| Callback reporting, unordered      | No buffering of results inside the engine          | Ordering and cancellation become the caller's problem   |
| Start-of-match opt-in              | Most consumers only need "did it match, where end" | Highlighting needs `SOM`, and pays for it               |
| Fork for portability and licence   | ARM/Power support and a BSD continuation           | Divergence from upstream; two projects to track         |

## Sources

Read at `4724cff398f81818b28b373ff67c41b9ed95d317` `[source-verified]`:

- [`README.md`][readme] — the fork rationale, platform support, SIMDe port, licence history

Deferred to [`parsing/hyperscan.md`][hs] for FDR/Teddy/LimEx internals.

<!-- References -->

[repo]: https://github.com/VectorCamp/vectorscan
[readme]: https://github.com/VectorCamp/vectorscan/blob/4724cff398f81818b28b373ff67c41b9ed95d317/README.md
[simde]: https://github.com/simd-everywhere/simde
[hs]: ../parsing/hyperscan.md
[hypergrep]: ./hypergrep.md
[ripgrep]: ./ripgrep.md
[re2]: ./re2.md
[baseline]: ./sparkles-baseline.md
