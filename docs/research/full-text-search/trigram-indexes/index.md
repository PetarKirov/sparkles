# Trigram and n-gram indexes

The family that narrows a candidate set by **literal obligation**: decompose a
pattern into strings it must contain, look those up, and hand the survivors to a
scanner. Three implementations, one lineage, and three different answers to what
a posting list should hold.

> **Last reviewed:** August 28, 2026.

---

## The idea

A regex that must match somewhere in a document implies literals that document
must contain. If an index maps _n_-grams to documents, that implication becomes a
boolean query over posting lists — and everything the query rejects need never be
read.

The construction is the same one [RE2][re2] publishes as `FilteredRE2`, and the
same one [fff][fff-grep] runs at bigram granularity. RE2 states the seam most
clearly: it produces the literal obligations and **deliberately does not
implement the string matching**, because the caller already has an index or an
automaton to evaluate them with.

Two properties follow, and they define the family:

- **False positives are allowed.** A candidate is a document that _might_ match;
  verification is a scan. This is what makes the index small.
- **False negatives are not.** An index that can miss a match is not a prefilter,
  it is a bug. Every implementation here is careful about the cases where no
  obligation can be extracted, and degrades to a full scan rather than to silence.

## The subjects

| Page                                         | What it indexes              | Distinctive                                        |
| -------------------------------------------- | ---------------------------- | -------------------------------------------------- |
| [Google Code Search](./google-codesearch.md) | trigram → file               | The original; a regex→boolean query planner        |
| [Zoekt](./zoekt.md)                          | trigram → **(file, offset)** | Positional, so two lookups verify a long substring |
| [livegrep](../livegrep.md)                   | suffix array                 | Not an n-gram index — the family's counterexample  |

Two more sit outside this directory because their unit is not the file:
[ugrep][ugrep]'s per-file hashed-ngram filter with an accuracy dial, and
[fff][fff-grep]'s dense column-major bigram bitmaps.

## The axis that separates them: what a posting holds

**Document ids** (Code Search). The smallest index. Verifying `"/usr/local"`
requires intersecting the posting lists of all eight of its trigrams, and the
answer is still only "this file might contain it".

**Positions** (Zoekt). Larger, but a substring can be verified with far fewer
lookups — its own design doc makes the argument:

> _"If we are searching for a string (eg. 'The quick brown fox'), then we look
> for two trigrams (eg. 'The' and 'fox'), and check that they are found at the
> right distance apart."_ … _"for each substring, we only have to intersect just
> a couple of posting-lists: one for the beginning, and one for the end. Since we
> touch few posting lists per query, they can be stored on slower media, such as
> SSD."_ `[source-verified]`

That is a genuinely different cost model: positional trigrams trade index size
for **fewer, larger random reads**, which is why Zoekt can serve from SSD.

**Presence bitmaps** (fff, ugrep). No posting lists at all — a bitmap per gram
(fff) or per file (ugrep). Cheapest to build and to update; least selective.

## What the measurement says

`theory/examples/ngram-selectivity.d` runs both granularities over a fixed
generated corpus. The shape of the result:

- **Trigrams narrow compound queries by an order of magnitude** where bigrams do
  not — `render_window_offset` went from 1,414 candidates to 38 out of 2,000.
- **Short queries extract no obligation at all.** A two-character query against a
  trigram index has nothing to look up, and the index degenerates to a full scan.
  Every implementation must handle this, and it is the case an interactive picker
  hits constantly, because the user is still typing.
- **Common-gram queries stay unselective** at either granularity.

The absolute percentages are corpus-dependent and the example says so; the shape
is the finding.

## Cost, honestly

Build cost and memory are the family's real constraint. [fff][fff-grep] states
its own: `MAX_BIGRAM_COLUMNS = 5000`, and roughly 305 MB at 500k files with two
builders alive. Code Search's writer cannot assume the index fits in memory at all
and sorts-and-merges through temporary files. Zoekt shards.

And the update story is what decides the fit for a working tree — see
[thesis T2][index]. Per-file bitmaps (ugrep) reindex one file when one file
changes. Global posting lists do not.

## What this catalog concluded

`PKM6` stays deferred, and now for a stated reason rather than a hunch:

1. **The interactive case is the adversarial case.** A user typing `re`, `ren`,
   `rend` extracts no trigram obligation for the first two keystrokes, so the
   index cannot help exactly when latency matters most.
2. **A working tree's mutation rate is the wrong end of T2.** hue's corpus is
   edited continuously, and global posting lists must be rebuilt or merged.
3. **The unindexed path must exist anyway**, for verification and for the
   short-query case. Building it first is not a detour; it is the prerequisite.

If an index is ever added, the evidence points at **per-file presence filters**
(the ugrep shape) rather than global postings — because one changed file rewrites
one filter — with positional trigrams reserved for a static corpus like git
history.

<!-- References -->

[re2]: ../re2.md
[fff-grep]: ../fff-grep.md
[ugrep]: ../ugrep.md
[index]: ../index.md
