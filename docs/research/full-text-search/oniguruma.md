# Oniguruma (C)

The multi-encoding backtracking engine behind Ruby, `jq` and several editors.
Surveyed for one reason: it is the clearest example of **encoding as a first-class
parameter** rather than an assumption.

| Field             | Value                                                      |
| ----------------- | ---------------------------------------------------------- |
| Language          | C                                                          |
| License           | BSD-2-Clause                                               |
| Repository        | [kkos/oniguruma][repo]                                     |
| Surveyed revision | `f95747b462de672b6f8dbdeb478245ddf061ca53` (`v6.9.10-28`)  |
| Category          | Regex engine (library)                                     |
| Engine class      | Backtracking, with compile-time bounds on pattern features |
| Guarantee         | None; bounded by feature limits and a retry limit          |

> **Last reviewed:** August 28, 2026.

---

## Overview

### What it solves

Regex over **many encodings** — UTF-8/16/32, EUC-JP, Shift_JIS, ISO-8859-\*,
KOI8-R — with syntax dialects selectable per pattern (Ruby, Perl, Java, POSIX).
Where other engines assume UTF-8 and treat anything else as the caller's problem,
Oniguruma makes the encoding an object the pattern is compiled against.

### Design philosophy

Configurability over guarantees. Its bounds are **structural caps on the pattern**
rather than a complexity class:

```c
#define ONIG_MAX_BACKREF_NUM                1000
#define ONIG_MAX_REPEAT_NUM               100000
#define ONIG_MAX_MULTI_BYTE_RANGES_NUM     10000
#define ONIG_MAX_CAPTURE_HISTORY_GROUP        31
```

`[source-verified]`

That is a different philosophy from both [RE2][re2] (remove the constructs) and
[PCRE2][pcre2] (budget the search): Oniguruma caps _how much of a construct_ a
pattern may contain, so blowup is bounded at compile time by refusing an
over-large pattern.

## How it works — what matters here

**Encoding is a parameter.** `OnigEncoding` carries the code-point length
function, case-folding behaviour and character-class semantics, so `\w` means
something encoding-specific by construction rather than by a Unicode flag.

**Syntax is a parameter too.** `OnigSyntaxType` selects the dialect, which is why
`jq` and Ruby can differ while sharing the engine.

**Backtracking with a retry limit.** The engine is a backtracking matcher; the
guard is a configurable retry count, the same shape as PCRE2's `match_limit`.

### The ten dimensions, briefly

**Pattern language**: dialect-selectable; backreferences, lookaround, named
groups, capture history. **Engine**: backtracking. **Prefilter**: an optimised
start-position search using literal prefixes and a byte map. **Corpus access**:
none. **Concurrency**: re-entrant with per-match regions. **Index**: none.
**Result model**: `OnigRegion` with capture positions, plus capture _history_ as
a distinctive extra. **Unicode**: full, plus non-Unicode encodings.
**Interactive**: none. **Measured evidence**: none quoted.

## Why it is surveyed but not a candidate

Same disqualification as PCRE2 — backtracking, allocation, no time bound — with
one additional lesson worth carrying: **encoding-parametric matching is
expensive and Sparkles does not need it.** hue's corpus is source text, which is
UTF-8 or is treated as bytes. Recording that Oniguruma pays a real architectural
cost for a generality this project can decline is part of scoping the D engine
honestly.

The capture-history feature is the one idea with no analogue elsewhere in this
catalog: it records every iteration's capture positions, not just the last. It is
irrelevant to grep and is noted so it is not re-discovered.

## Strengths

- **Encoding as a first-class object**, not a Unicode boolean.
- **Selectable syntax dialects** from one engine.
- **Compile-time structural caps** as a distinct bounding strategy.
- **Small, portable, widely embedded.**

## Weaknesses

- **Backtracking**: no time bound, retry-limit guarded.
- **Allocates during matching** (regions, stack).
- **Encoding generality costs** everywhere, for a property most search tools do
  not need.

## Key design decisions and trade-offs

| Decision                       | Rationale                                    | Trade-off                                               |
| ------------------------------ | -------------------------------------------- | ------------------------------------------------------- |
| Encoding as a parameter object | Correct matching in non-Unicode encodings    | Indirection on every character operation                |
| Selectable syntax dialects     | One engine serves Ruby, Perl and POSIX users | Behaviour depends on a second, non-obvious parameter    |
| Structural caps on the pattern | Bounds blowup at compile time                | Caps are arbitrary constants, not derived from a budget |
| Capture history                | Enables iteration-aware submatch analysis    | Storage per iteration; useless for line search          |

## Sources

Read at `f95747b462de672b6f8dbdeb478245ddf061ca53` `[source-verified]`:

- [`src/oniguruma.h`][onig-h] — `ONIG_MAX_*` caps, encoding and syntax objects, `OnigRegion`

<!-- References -->

[repo]: https://github.com/kkos/oniguruma
[onig-h]: https://github.com/kkos/oniguruma/blob/f95747b462de672b6f8dbdeb478245ddf061ca53/src/oniguruma.h
[re2]: ./re2.md
[pcre2]: ./pcre2.md
