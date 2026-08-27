# git grep (C)

The only surveyed scanner whose corpus is not the filesystem: it searches **git
objects** as readily as working-tree files, which changes what a query can even
mean.

| Field             | Value                                                        |
| ----------------- | ------------------------------------------------------------ |
| Language          | C                                                            |
| License           | GPL-2.0                                                      |
| Repository        | [git/git][repo]                                              |
| Surveyed revision | `f78ce2f7b6df702f93d40b85d6bda92a3f65da79` (`v2.55.0-731`)   |
| Category          | Unindexed scanner over an object store                       |
| Engine class      | POSIX `regex` / `kwset`-style fixed, optional PCRE2 with JIT |
| Index             | None for content; the git **index** selects what is searched |
| Interactive       | None                                                         |

> **Last reviewed:** August 28, 2026.

---

## Overview

### What it solves

Search the tracked corpus — which may be the working tree, the index, a commit,
or an arbitrary tree — without materialising it. `git grep TODO v2.0` searches a
tag; no other tool here can do that without a checkout.

### Design philosophy

Reuse the object store as the corpus abstraction, and make the _source_ of bytes
a variant rather than a filesystem assumption.

## How it works

### The ten dimensions

#### 1. Pattern language

BRE by default, ERE with `-E`, fixed with `-F`, PCRE2 with `-P`. Patterns
combine with `--and` / `--or` / `--not` and parentheses — a boolean expression
layer over the match, which is unusual among scanners and closer to a query
language than a pattern.

#### 2. Engine architecture

The platform `regex` for BRE/ERE and a fixed-string path; PCRE2 when built with
`USE_LIBPCRE2`, including a JIT path guarded by a `pcre2_jit_functional()` probe
and custom `pcre2_malloc`/`pcre2_free` hooks so allocation goes through git's
allocator. `[source-verified]`

#### 3. Prefilter and literal extraction

Minimal. git-grep's leverage comes from _searching fewer objects_, not from
rejecting bytes faster — pathspecs, `--cached`, and tree arguments cut the
corpus before any matching happens.

#### 4. Corpus access — the distinguishing dimension

`struct grep_source` carries a three-way origin:

```c
GREP_SOURCE_OID,   /* a blob in the object store */
GREP_SOURCE_FILE,  /* a path in the working tree */
GREP_SOURCE_BUF,   /* bytes already in memory */
```

`[source-verified]`. Blob sources inflate on demand from the object database, so
searching a tag costs decompression rather than checkout. `allow_textconv` routes
a blob through a configured `textconv` filter first, which means git-grep can
search the _textual rendering_ of a binary format — the only content-transform
hook in this catalog.

Binary policy is three-valued —`GREP_BINARY_DEFAULT`, `GREP_BINARY_NOMATCH`,
`GREP_BINARY_TEXT` — matching GNU grep's `--binary-files` trichotomy.

#### 5. Concurrency

One producer thread and _N_ consumers over a modulo ring of `work_item`s, with
each item owning an output `strbuf`:

> _"We use one producer thread and THREADS consumer threads. The producer adds
> struct work_items to 'todo' and the consumers pick work items from the same
> array."_ — [`builtin/grep.c`][builtin-grep] `[source-verified]`

The ring is split into `[todo_done, todo_start)` (in flight or finished) and
`[todo_start, todo_end)` (queued), so **output stays in corpus order** while work
completes out of order. That is precisely the property a picker needs and
ripgrep's parallel walk gives up.

#### 6. Index

No content index. The git index is a _file list_, and `--cached` makes it the
corpus.

#### 7. Ranking and result model

None; matching lines in traversal order, with the usual context flags.

#### 8. Unicode

Whatever the platform `regex` and PCRE2 provide; git itself is byte-oriented and
takes no position.

#### 9. Interactive behaviour

None.

#### 10. Measured evidence

None quoted. Structurally, the ordered producer/consumer ring is the transferable
artifact.

## Strengths

- **The corpus is a variant, not an assumption** — OID, file, or buffer.
- **Ordered output from unordered work**, via the split ring.
- **Boolean pattern composition** (`--and`/`--or`/`--not`) as a first-class layer.
- **`textconv`** gives content search a transform hook nothing else here has.
- **PCRE2 JIT is probed at runtime**, not assumed from the build.

## Weaknesses

- **Little byte-level acceleration**; the win is corpus reduction.
- **Tied to a repository** — not a general-purpose scanner.
- **No interactive contract.**

## Key design decisions and trade-offs

| Decision                            | Rationale                                                | Trade-off                                            |
| ----------------------------------- | -------------------------------------------------------- | ---------------------------------------------------- |
| `grep_source` as a three-way origin | Searching history costs inflation, not checkout          | Every consumer must handle a source it cannot `mmap` |
| Producer/consumer ring with ranges  | Ordered output despite out-of-order completion           | A bounded queue and its synchronisation              |
| `textconv` before matching          | Binary formats become searchable through their rendering | Arbitrary user code in the search path               |
| Boolean pattern combinators         | Multi-term queries without a shell pipeline              | A second grammar above the regex grammar             |
| PCRE2 JIT probed at runtime         | A build-time feature may still be non-functional         | Two code paths to keep equivalent                    |

## Sources

Read at `f78ce2f7b6df702f93d40b85d6bda92a3f65da79` `[source-verified]`:

- [`grep.h`][grep-h] — `grep_source`, `GREP_BINARY_*`, `allow_textconv`
- [`grep.c`][grep-c] — PCRE2 integration, JIT probe, allocator hooks
- [`builtin/grep.c`][builtin-grep] — the producer/consumer ring

<!-- References -->

[repo]: https://github.com/git/git
[grep-h]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/grep.h
[grep-c]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/grep.c
[builtin-grep]: https://github.com/git/git/blob/f78ce2f7b6df702f93d40b85d6bda92a3f65da79/builtin/grep.c
