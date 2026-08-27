# livegrep (C++)

A **suffix-array** index rather than an n-gram one: it answers arbitrary regex
without literal extraction, and pays 3–5× the corpus in space to do it. The
family's counterexample, and the concrete price of "no false positives".

| Field             | Value                                      |
| ----------------- | ------------------------------------------ |
| Language          | C++                                        |
| License           | BSD-3-Clause                               |
| Repository        | [livegrep/livegrep][repo]                  |
| Surveyed revision | `923d5ad71dfe60900e6c2017b2fa4a5ff902ad71` |
| Category          | Suffix-array index, served                 |
| Engine            | [RE2][re2] for verification                |
| Index size        | **3–5× the indexed text**                  |

> **Last reviewed:** August 28, 2026.

---

## What it solves

Interactive regex search — results as you type — over a large corpus, without the
n-gram family's blind spot. Where a trigram index cannot help with a pattern from
which no literal can be extracted, a suffix array can.

## How it works

Two processes: `codesearch` holds the index and answers queries, `livegrep` is a
stateless frontend over a TCP connection. Regex support is inherited wholesale:

> _"Livegrep uses Google's re2 regular expression engine, and inherits its
> supported [syntax]"_ — [`README.md`][readme] `[source-verified]`

So the pattern-language refusals are [RE2's][re2], and the index's job is purely
to find candidate positions fast.

### The index, and its price

> _"livegrep builds an index file of your source code, and then works entirely
> out of that index, with no further access to the original git repositories.
> The index file will vary somewhat in size, but will usually be **3-5x the size
> of the indexed text**. `livegrep` memory-maps the index file into RAM, so it
> can work out of index files larger than (available) RAM, but will perform
> better if the file can be loaded entirely into memory."_ `[source-verified]`

That is the suffix-array trade stated plainly, and it matches the theory: an
array of `n` positions at 4–8 bytes each, plus auxiliary structures.
See [`theory/succinct-indexes.md`](./theory/succinct-indexes.md) for why the
compressed self-index families exist to attack exactly this number.

The build is a batch job with a `-index_only` / `-dump_index` mode producing a
standalone file, so index construction and serving are cleanly separated — but
there is no incremental update: a changed corpus is a rebuilt index.

### The ten dimensions, briefly

**Pattern language**: RE2's. **Engine**: RE2, over candidates. **Prefilter**:
the suffix array — no literal extraction needed. **Corpus access**: mmap of one
standalone index file. **Concurrency**: per-query in the server.
**Index**: suffix array, 3–5× text, rebuilt not updated. **Result model**:
matches with file and line, served to a web frontend. **Unicode**: UTF-8.
**Interactive**: the whole point — search-as-you-type is the product.
**Measured evidence**: none reproduced; the size multiple is a documented
property, not a benchmark.

## Strengths

- **Answers patterns with no extractable literal**, which is the n-gram family's
  structural weakness.
- **No false positives** — the index locates real occurrences, so verification is
  confirming a regex on a known position rather than scanning a candidate file.
- **A standalone, mmap-able index file** that can exceed RAM.
- **Interactive by design**, not a batch tool with a UI bolted on.

## Weaknesses

- **3–5× the corpus in space**, which for a working tree is a large multiple of a
  thing that is already on disk.
- **No incremental update**: rebuild.
- **A served architecture** — two processes and a socket.
- **Construction is expensive** in both time and memory relative to n-gram
  indexing.

## Key design decisions and trade-offs

| Decision                                | Rationale                                               | Trade-off                                        |
| --------------------------------------- | ------------------------------------------------------- | ------------------------------------------------ |
| Suffix array over n-grams               | Arbitrary substrings, including where no literal exists | 3–5× space; expensive construction               |
| RE2 for verification                    | Do not write a regex engine                             | Inherits RE2's refusals, which is fine           |
| Standalone mmap-able index file         | Index larger than RAM; reusable across runs             | Cold performance depends on the storage medium   |
| Rebuild rather than update              | Simple, and correct                                     | Unusable for a corpus edited continuously        |
| Split index server / stateless frontend | Scale and restart independently                         | An IPC boundary a single-user tool does not want |

## What this catalog concluded

livegrep is the strongest argument that **the n-gram family's weakness is real** —
patterns with no extractable literal are common enough that a serious system
chose a 3–5× space multiple to avoid the problem. It is also the strongest
argument that the fix is unaffordable for hue: the space is large, the build is
batch, and the update story is a rebuild.

It sharpens [thesis T3][index]: n-gram and suffix-based indexes are not competing
implementations of one idea, they answer different questions. A trigram index
cannot answer `\d{3}-\d{4}`; a suffix array can, at 3–5×.

## Sources

Read at `923d5ad71dfe60900e6c2017b2fa4a5ff902ad71` `[source-verified]`:

- [`README.md`][readme] — architecture, index size multiple, mmap behaviour, RE2 inheritance, `-index_only`/`-dump_index`

<!-- References -->

[repo]: https://github.com/livegrep/livegrep
[readme]: https://github.com/livegrep/livegrep/blob/923d5ad71dfe60900e6c2017b2fa4a5ff902ad71/README.md
[re2]: ./re2.md
[index]: ./index.md
