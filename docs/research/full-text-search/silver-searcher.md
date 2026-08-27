# The Silver Searcher — `ag` (C)

The tool that made "grep that respects `.gitignore`" a category. Its algorithms
are the pre-SIMD state of the art, which makes it a useful control: everything
ripgrep does faster, `ag` does the textbook way.

| Field             | Value                                                       |
| ----------------- | ----------------------------------------------------------- |
| Language          | C                                                           |
| License           | Apache-2.0                                                  |
| Repository        | [ggreer/the_silver_searcher][repo]                          |
| Surveyed revision | `a61f1780b64266587e7bc30f0f5f71c6cca97c0f` (`2.2.0-60`)     |
| Category          | Unindexed scanner                                           |
| Engine class      | Boyer-Moore / hashed substring for literals; PCRE for regex |
| Index             | None                                                        |
| Interactive       | None                                                        |

> **Last reviewed:** August 28, 2026.

---

## Overview

### What it solves

Recursive search that skips what version control already says to skip. `ag`
established the default that ripgrep inherited, and its literal path is a clean
two-algorithm implementation with an explicit platform gate.

## How it works

### The ten dimensions

#### 1. Pattern language

PCRE for regex; a literal fast path when the pattern has no metacharacters.
Case sensitivity is a tri-state (`CASE_SENSITIVE`, `CASE_INSENSITIVE`, smart).

#### 2. Engine architecture

Two literal searchers, selected by platform capability:

```c
/* hash_strnstr only for little-endian platforms that allow unaligned access */
```

On those platforms `hash_strnstr` runs — a rolling-hash substring search over a
precomputed table; elsewhere, `boyer_moore_strnstr` with `alpha_skip_lookup` and
`find_skip_lookup` skip tables. `[source-verified]` Regex falls through to PCRE
per line.

This is the pre-`memmem` design: **skip tables rather than vectorised
candidate-finding**, and the field's measured answer since has been that
rare-byte SIMD scanning beats classical skipping on realistic text.

#### 3. Prefilter and literal extraction

None from a regex. The literal path is chosen only when the whole pattern is
literal.

#### 4. Corpus access

`mmap` by default on POSIX (`MapViewOfFile` on Win32), with binary files skipped
before mapping when binary search is disabled — the comment notes that _"if not
using mmap, binary files have already been skipped"_, so the two paths detect at
different points. `[source-verified]`

#### 5. Concurrency

A worker pool over files, with `uthash` for the ignore structures.

#### 6. Index

None.

#### 7–8. Result model and Unicode

Matching lines in walk order; no ranking. Unicode is whatever PCRE was built
with; the literal path is byte-oriented with ASCII case folding.

#### 9–10. Interactive behaviour and evidence

None, and none quoted. `ag`'s historical benchmark claims predate ripgrep and are
`[literature]`.

## Strengths

- **Established the ignore-aware default** the whole category now assumes.
- **Two literal algorithms with an explicit portability gate** — unaligned access
  and endianness are checked rather than assumed.
- **Small and readable**: the whole search core is a few hundred lines.

## Weaknesses

- **Classical skip tables rather than vectorised search**, which is where the
  measured gap against ripgrep comes from.
- **`mmap` by default**, with the truncation hazard [GNU grep withdrew][gnu-grep]
  and [ripgrep made `unsafe`][ripgrep].
- **PCRE per line** for regex, with no literal extraction to avoid it.
- **Maintenance has largely stopped**, so it is a snapshot of 2014-era practice.

## Key design decisions and trade-offs

| Decision                            | Rationale                               | Trade-off                                                  |
| ----------------------------------- | --------------------------------------- | ---------------------------------------------------------- |
| Respect `.gitignore` by default     | Source trees contain build output       | A correctness surface of its own (nested rules, negations) |
| Hash-based substring where possible | Faster than Boyer-Moore on typical text | Requires little-endian + unaligned access; two code paths  |
| `mmap` by default                   | Avoids a copy                           | `SIGBUS` on concurrent truncation                          |
| PCRE per line for regex             | Full regex features with no engine work | No literal prefilter; every line pays the engine           |

## Sources

Read at `a61f1780b64266587e7bc30f0f5f71c6cca97c0f` `[source-verified]`:

- [`src/util.c`][util-c] — `boyer_moore_strnstr`, `hash_strnstr`
- [`src/search.c`][search-c] — algorithm selection, `mmap`, binary skipping
- `src/ignore.c`, `src/lang.c` — ignore handling and type filters

<!-- References -->

[repo]: https://github.com/ggreer/the_silver_searcher
[util-c]: https://github.com/ggreer/the_silver_searcher/blob/a61f1780b64266587e7bc30f0f5f71c6cca97c0f/src/util.c
[search-c]: https://github.com/ggreer/the_silver_searcher/blob/a61f1780b64266587e7bc30f0f5f71c6cca97c0f/src/search.c
[gnu-grep]: ./gnu-grep.md
[ripgrep]: ./ripgrep.md
