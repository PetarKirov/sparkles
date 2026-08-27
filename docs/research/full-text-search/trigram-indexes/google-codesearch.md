# Google Code Search (Go)

Russ Cox's re-implementation of the trigram index behind the original Google
Code Search — the paper and the code that made "regex over an inverted index" a
solved technique.

| Field             | Value                                               |
| ----------------- | --------------------------------------------------- |
| Language          | Go                                                  |
| License           | BSD-3-Clause                                        |
| Repository        | [google/codesearch][repo]                           |
| Surveyed revision | `b34f2a0c5ce12be3c9dc28038640afece6bee523`          |
| Category          | n-gram index                                        |
| Posting unit      | trigram → file id                                   |
| Query model       | `QAll` / `QNone` / `QAnd` / `QOr` over trigram sets |

> **Last reviewed:** August 28, 2026.

---

## What it solves

Answering a regex over a corpus too large to scan, by turning the regex into a
boolean query over trigram posting lists and scanning only the survivors.

## How it works

### The query model

`index.Query` is a four-way algebra, and its compactness is the point:

```go
type Query struct {
    Op      QueryOp
    Trigram []string
    Sub     []*Query
}

const (
    QAll  QueryOp = iota // Everything matches
    QNone                // Nothing matches
    QAnd                 // All in Sub and Trigram must match
    QOr                  // At least one in Sub or Trigram must match
)
```

`[source-verified]`

A parsed regex is walked to produce this tree. Concatenation becomes `QAnd`,
alternation becomes `QOr`, and anything from which no obligation can be derived
becomes `QAll` — _"everything matches"_ — which is the honest representation of
"the index cannot help here". `QAll` propagating to the root is exactly the
degenerate full scan, and the algebra makes that visible rather than accidental.

### The caps that define what gets indexed

```go
maxFileLen      = 1 << 30
maxLineLen      = 2000
maxTextTrigrams = 20000
```

with the rule stated above them: a file is skipped _"if it contains an invalid
UTF-8 sequence, if it is longer than maxFileLength bytes, if it contains a line
longer than maxLineLen bytes, or if it contains more than maxTextTrigrams
distinct trigrams."_ `[source-verified]`

The last one is the interesting cap. **Distinct-trigram count is a binary
detector** — minified bundles, base64 blobs and generated tables all have
enormous trigram diversity, and they are exactly the files that would bloat every
posting list while never being what anyone searched for. It is a better signal
than a NUL byte for this purpose, and it is free because the indexer is counting
trigrams anyway.

### Building without holding it in memory

> _"It would suffice to make a single large list of (trigram, file#) pairs while
> processing the files one at a time, sort that list by trigram, and then create
> the posting lists from subsequences of the list. However, we do not assume that
> the entire index fits in memory. Instead, we sort and flush the list to a new
> temporary file each time it reaches its maximum in-memory size, and then at the
> end we create the final posting lists by merging the temporary files."_
> — [`index/write.go`][write] `[source-verified]`

An external merge sort. `merge.go` also supports merging an existing index with a
new one, which is the incremental-update story — coarse, but present.

### The ten dimensions, briefly

**Pattern language**: RE2's, since the query planner walks an RE2 parse tree.
**Engine**: none of its own — RE2 verifies. **Prefilter**: it _is_ the
prefilter. **Corpus access**: mmap of the index (`mmap_linux.go` and friends).
**Concurrency**: none notable. **Index**: trigram → sorted file ids, with delta
encoding (`delta.go`). **Result model**: candidate file list. **Unicode**:
UTF-8 validity is an indexing precondition. **Interactive**: none — a batch
tool. **Measured evidence**: the accompanying article's figures are
`[literature]`.

## Strengths

- **The four-op query algebra** is small enough to reimplement in an afternoon
  and expressive enough for the whole family.
- **`QAll` makes "the index cannot help" a first-class value**, so the degenerate
  case is designed rather than discovered.
- **The distinct-trigram cap** doubles as a generated-file detector.
- **External-merge construction** does not assume the index fits in RAM.

## Weaknesses

- **Non-positional**, so verifying a long literal means intersecting many lists.
- **Update is a merge**, not an edit — wrong shape for a working tree.
- **No ranking**; it produces a candidate set, nothing more.
- Written as a demonstration; it is not a maintained production system.

## Key design decisions and trade-offs

| Decision                          | Rationale                                                  | Trade-off                                         |
| --------------------------------- | ---------------------------------------------------------- | ------------------------------------------------- |
| Trigrams, not bigrams             | 3 bytes is selective enough on text, small enough to store | Queries shorter than 3 bytes extract nothing      |
| Document ids, not positions       | Smallest possible index                                    | Many list intersections per long literal          |
| `QAll` as an explicit op          | The "no obligation" case is representable                  | Callers must handle a full-scan answer            |
| Cap on distinct trigrams per file | Excludes generated files that would bloat every list       | A heuristic; an unusual real file can be excluded |
| External merge sort on build      | Index build is not bounded by RAM                          | Temporary files and a merge pass                  |

## Sources

Read at `b34f2a0c5ce12be3c9dc28038640afece6bee523` `[source-verified]`:

- [`index/regexp.go`][regexp] — the `Query` algebra and regex→query derivation
- [`index/write.go`][write] — the caps, and external-merge construction
- `index/{read,merge,delta}.go` — on-disk format, merging, posting encoding

Secondary: Russ Cox, _"Regular Expression Matching with a Trigram Index"_
(`swtch.com/~rsc/regexp/regexp4.html`) `[literature]`.

<!-- References -->

[repo]: https://github.com/google/codesearch
[regexp]: https://github.com/google/codesearch/blob/b34f2a0c5ce12be3c9dc28038640afece6bee523/index/regexp.go
[write]: https://github.com/google/codesearch/blob/b34f2a0c5ce12be3c9dc28038640afece6bee523/index/write.go
