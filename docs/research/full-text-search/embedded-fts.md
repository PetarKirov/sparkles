# Embedded FTS — SQLite FTS5 and DuckDB

The "you already have a database" answer. Surveyed because it is a real option
for a desktop application and because FTS5's design contains one idea — an
**external-content** index — that maps unusually well onto a source tree.

| Field    | Value                                |
| -------- | ------------------------------------ |
| Subjects | SQLite FTS5 · DuckDB `fts` extension |
| Category | Embedded inverted index              |
| Ranking  | BM25 (FTS5 `bm25()`), BM25 (DuckDB)  |
| Unit     | Analyzed terms                       |

> **Last reviewed:** August 28, 2026.

> [!NOTE]
> A **boundary page** written from documented behaviour rather than a pinned
> source read; no decision here turns on their internals. Claims are
> `[literature]`.

---

## SQLite FTS5

An inverted index inside a SQLite database file, queried through SQL, with `bm25()`
available as a ranking function and prefix indexes as an option.

Two properties matter for a desktop tool:

**External-content tables.** FTS5 can index content that lives _outside_ the FTS
table, storing only the index and fetching the original rows from a
user-supplied source. For a source tree that is the natural shape — the files are
already on disk, and duplicating them into a database would be absurd. The
application is then responsible for keeping the index and the content in sync,
which is where the idea meets [thesis T2][index]: FTS5 gives the storage and the
query, and hands the freshness problem straight back.

**Trigram tokenizer.** FTS5 ships a `trigram` tokenizer specifically to support
`LIKE`/`GLOB`-style substring matching, which is a candid admission that the term
model does not serve substring search — and it is the same
[trigram index](./trigram-indexes/index.md) this catalog surveys, wearing a
tokenizer's clothes.

## DuckDB `fts`

A BM25 inverted index built as an extension, aimed at analytical queries over
text columns rather than interactive lookup. The index is built by a macro over a
table and rebuilt when content changes — a batch model, and the wrong end of T2
for a working tree.

## Why neither is adopted

1. **Term analysis is the wrong model for code**, per
   [`theory/ranked-retrieval.md`](./theory/ranked-retrieval.md) and
   [Lucene](./lucene.md) — and FTS5's own trigram tokenizer concedes it.
2. **Freshness is still the caller's problem.** External-content tables do not
   solve the update question, they relocate it.
3. **A new dependency and a new file format** for a capability the scanner path
   must provide anyway, since short queries and no-literal patterns bypass any
   index.
4. `sparkles:fuzzy`'s constraints — `@safe pure nothrow @nogc`, borrowed spans —
   are not reachable through a C library boundary with its own allocator and
   error model.

## The idea worth keeping

**External content.** Whatever Sparkles ever indexes, the index should reference
files rather than copy them, and the sync obligation should be explicit and
owned by the application. FTS5 makes that a first-class table type, and naming it
is more useful than the rest of the page.

## Sources

`[literature]`: SQLite FTS5 documentation (external content tables, the trigram
tokenizer, `bm25()`); DuckDB `fts` extension documentation. The alternatives this
catalog prefers are in [`trigram-indexes/`](./trigram-indexes/index.md) and
[ugrep](./ugrep.md)'s per-file filter.

<!-- References -->

[index]: ./index.md
