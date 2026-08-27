# Zoekt (Go)

Positional trigrams, git-native sharding, and a **ctags-derived symbol index** —
the last of which is this catalog's strongest counter-position on how a
definition should be recognised.

| Field             | Value                                      |
| ----------------- | ------------------------------------------ |
| Language          | Go                                         |
| License           | Apache-2.0                                 |
| Repository        | [sourcegraph/zoekt][repo]                  |
| Surveyed revision | `5f833dde1bc4b1a8f99007617b4b721e44506c4f` |
| Category          | n-gram index, served                       |
| Posting unit      | trigram → **(file, offset)**               |
| Ranking           | Structural signals, with optional BM25     |

> **Last reviewed:** August 28, 2026.

---

## What it solves

Its design doc states the target precisely:

> _"Provide full text code search for git based corpuses. Goals: sub-50ms results
> on large codebases, such as Android (~2G text) or Chrome; works well on a
> single standard Linux machine, with stable storage on SSD; search multiple
> repositories and multiple branches; provide rich query language, with boolean
> operators."_ — [`doc/design.md`][design] `[source-verified]`

**Sub-50 ms on 2 GB from one machine** is the same latency class hue needs, from
an index rather than a scan.

## How it works

### Positional trigrams

The distinguishing choice, with a worked example in its own words:

> _"We build an index of ngrams (n=3), where we store the offset of each ngram's
> occurrence within a file. For example, if the corpus is 'banana' then we
> generate the index `"ban": 0`, `"ana": 1,3`, `"nan": 2`."_

and the payoff:

> _"If we are searching for a string (eg. 'The quick brown fox'), then we look
> for two trigrams (eg. 'The' and 'fox'), and check that they are found at the
> right distance apart."_ `[source-verified]`

So a long literal costs **two** posting-list reads plus a distance check, rather
than one intersection per trigram. The design doc draws the comparison to
[Code Search][gcs] explicitly:

> _"for each substring, we only have to intersect just a couple of posting-lists:
> one for the beginning, and one for the end. Since we touch few posting lists
> per query, they can be stored on slower media, such as SSD."_

That is the whole architectural bet: **spend index size to buy fewer, larger
random reads**, which is what makes SSD-resident serving viable.

### Regex, the same way as everyone else

> _"Regular expressions are handled by extracting normal strings from the regular
> expressions. For example, to search for `(Path|PathFragment).*=.*/usr/local` we
> look for `(AND (OR substr:"Path" substr:"PathFragment") substr:"/usr/local")`
> and any documents thus found would be searched for the regular expression."_
> `[source-verified]`

The same AND/OR obligation tree as [RE2's `FilteredRE2`][re2] and
[Code Search's `Query`][gcs], reached independently.

### Ranking — the part that matters for `PKL6`

The design doc enumerates the signals it considers, and the list is a direct
alternative to term-frequency ranking:

> _"number of atoms matched; closeness to matches for other atoms; quality of
> match: does match boundary coincide with a word boundary?; file latest update
> time; filename length; tokenizer ranking: does a match fall [in a] comment or
> string literal?; **symbol ranking: it the match a symbol definition?**"_
>
> _"For the latter, it is necessary to find symbol definitions and other sections
> within files on indexing. Several (imperfect) programs to do this already
> exist, eg. `ctags`."_ `[source-verified]`

Zoekt ships an `install-ctags-alpine.sh` and runs ctags at index time.

**This is the far end of the definition-classification spectrum.** [fff][fff-grep]
answers with 131 lines of byte heuristics its own header calls a POC; Zoekt
answers with a real symbol extractor run once per file at index time, and treats
"is this a definition" as an _indexed fact_ rather than a per-hit guess. It also
notes, honestly, that such programs are "imperfect".

Zoekt additionally supports **optional BM25** (`UseBM25Scoring`), where _"each
match in a file is treated as a term"_ — useful for multi-term queries. So the
same system carries both the structural and the statistical model, and defaults
to structural.

### The ten dimensions, briefly

**Pattern language**: substring, regex, and a boolean query language with
repo/branch/file predicates. **Engine**: candidate narrowing by index, then
verification. **Prefilter**: the index. **Corpus access**: shards, mmap,
SSD-resident. **Concurrency**: per-shard parallelism. **Index**: positional
trigrams plus a ctags symbol table, sharded, with a documented format-version
upgrade path (build new shards, swap the service, delete old). **Result model**:
ranked, with structural signals. **Unicode**: UTF-8 corpora. **Interactive**:
sub-50 ms is the design goal; no per-query budget or cursor in the scanner sense.
**Measured evidence**: the 50 ms/2 GB target is a stated goal, not a measurement
this catalog reproduces — `[literature]`.

## Strengths

- **Positional postings** turn a long-literal query into two reads.
- **Symbol ranking as an indexed fact**, not a per-hit heuristic.
- **Both ranking models available**, with the structural one as default.
- **A stated format-migration procedure**, which most index designs omit.
- **git-native**: branches and repositories are first-class query dimensions.

## Weaknesses

- **A served system.** Sharding, format versions and a migration procedure are
  the cost of the design, and hue has none of that apparatus.
- **Index size** is materially larger than non-positional trigrams.
- **ctags is an external dependency** and, as the doc says, imperfect.
- **Freshness is a reindex**, which is the wrong end of thesis T2 for a working
  tree.

## Key design decisions and trade-offs

| Decision                                   | Rationale                                          | Trade-off                                                |
| ------------------------------------------ | -------------------------------------------------- | -------------------------------------------------------- |
| Positional trigrams                        | Two posting reads verify a long substring          | A materially larger index                                |
| Index on SSD, few large reads              | Follows from the above; one machine serves 2 GB    | Latency depends on the storage assumption                |
| ctags symbol index at build time           | "Is this a definition" becomes a fact, not a guess | An external, imperfect tool in the indexing pipeline     |
| Structural ranking by default, BM25 opt-in | Code is not prose; term frequency is a weak signal | Two scoring paths to maintain                            |
| Shards with a version-upgrade dance        | Format can evolve without downtime                 | Operational complexity a single-user tool cannot justify |

## What transfers to hue

**The symbol-ranking position, adapted.** Zoekt's insight is that definition-ness
should be _computed once and stored_, not re-derived per hit. hue cannot run
ctags at index time — it has no index — but it has tree-sitter, and the decided
design (byte heuristic during the scan, precise classification on the visible
top-K from a parse the preview already performed) is the same insight under a
no-index constraint: **do the expensive classification once, where it is
affordable, and let the cheap one rank.**

## Sources

Read at `5f833dde1bc4b1a8f99007617b4b721e44506c4f` `[source-verified]`:

- [`doc/design.md`][design] — objectives, positional trigrams, regex handling, ranking signals, BM25, shard upgrade
- `install-ctags-alpine.sh` — the symbol-extraction dependency

<!-- References -->

[repo]: https://github.com/sourcegraph/zoekt
[design]: https://github.com/sourcegraph/zoekt/blob/5f833dde1bc4b1a8f99007617b4b721e44506c4f/doc/design.md
[gcs]: ./google-codesearch.md
[re2]: ../re2.md
[fff-grep]: ../fff-grep.md
