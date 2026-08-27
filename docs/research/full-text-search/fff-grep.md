# fff — the grep engine (Rust)

The content-search organ of a resident file-picker daemon: three modes behind one
dispatch point, a soft page limit over a wall-clock budget, and a resumable
file-offset cursor. It is [hue's stated design source][picker] for grep's budget,
cursor and mode-fallback behaviour, which is why it is surveyed here rather than
in the [fuzzy-matching][fuzzy-matching] tree that owns fff's _path_ matcher.

| Field             | Value                                                                        |
| ----------------- | ---------------------------------------------------------------------------- |
| Language          | Rust                                                                         |
| Repository        | [dmtrKovalenko/fff][repo]                                                    |
| Surveyed revision | `3a0ce85c54875563bc55888b6b9829b44aeca911`                                   |
| Size              | 2,684 lines (`fff-core/src/grep/`) + 1,024 (`fff-grep/`, a vendored fork)    |
| Category          | Unindexed scanner, resident                                                  |
| Engine class      | Three: `memmem` literal · Rust `regex` (bytes, Unicode off) · Smith-Waterman |
| Index             | Optional bigram content index (grep-only; see `trigram-indexes` (Phase 4))   |
| Interactive       | In-process, resident; budget + abort + file cursor                           |

> **Last reviewed:** August 28, 2026.

> [!NOTE]
> This page covers **two organs in one repository**. `fff-core/src/grep/` is the
> search engine; `fff-grep/` is a **vendored fork of ripgrep's `grep-searcher`**,
> stripped to a fraction of its size. The fork is the more useful artifact for
> Sparkles, because it is a worked answer to _"what is the minimum a
> line-oriented searcher must own"_.

---

## Overview

### What it solves

fff is a file picker that keeps its index and a content cache warm in one
long-lived process. Its grep path exists to answer a content query _inside a
frame_, over a corpus it has already walked, without the process-spawn tax that
every editor-side live-grep integration pays per keystroke.

The module's own header states the architecture:

> _"Live grep. `grep.rs` implements the main plain-text path, the parallel scan
> engine, and the `grep_search` entry point that picks the matcher/sink for every
> mode in one place; `regex`, `multi_pattern`, and `fuzzy_grep` hold the
> mode-specific machinery on top of the shared `prefilter`/`sink`."_
> — [`grep/mod.rs`][mod-rs] `[source-verified]`

### Design philosophy

Three commitments run through the code, and each is stated in a comment beside
the thing it justifies.

**Degrade, and say so.** No input is a hard error. An uncompilable regex falls
back to literal search and returns the compiler's message in a result field for
the UI to show. A constrained query that scanned everything and found nothing is
retried raw. A path constraint that filtered every file is dropped and retried.
Each rung sets a flag the caller can render.

**Bound the wrong answer, not the right one.** The page limit is soft — the file
that tips the count over is finished, not truncated — and the budget is checked
between files rather than between lines. Cheap, coarse bounds; no partial file.

**Prefilter before machinery, not just before the engine.** The whole-file
`memmem` check runs before the `Searcher` is built at all, skipping allocation
and line-splitting rather than merely skipping the match loop.

## How it works

`grep_search` parses the query into constraints plus a search text, prefilters
the file list, then dispatches on mode. Plain text and regex share a searcher and
differ only in matcher/sink; fuzzy returns early into its own path, because it
needs whole-file line vectors that the line-oriented searcher does not produce.

The dispatch is deliberately one site, and says so:

```rust
// The single sink-selection point: every mode's matcher/sink pairing
// is decided here based on the compiled pattern.
|file_bytes: &[u8], max_matches: usize| { … }
```

— [`grep.rs`][grep-rs] `[source-verified]`

### The fallback ladder

Three rungs, in three different places, and **they do not agree with each other**
— which is itself the finding for a picker deciding how modes should behave.

1. **Constraint → literal**, in `grep_search`: if the constrained search scanned
   the whole corpus and found nothing, the raw query is retried as literal text
   with all constraints dropped, and `literal_fallback` is set. The comment gives
   the motivating case: _"Constraint parsing can swallow tokens the user meant
   literally (e.g. `!=` becoming an exclusion)."_
2. **Regex → literal**, at compile time: a pattern that fails to compile becomes
   a literal search, and the error string is returned in `regex_fallback_error`
   so, in the field's own words, _"The UI can display this to inform the user
   their regex was invalid."_
3. **Path-constraint retry**, in the prefilter: zero files after constraints and
   a `FilePath` constraint present ⇒ retry without it, because _"the path token
   was likely part of the search text."_

Mode **selection** is not in the engine at all. It lives in callers, via a
one-line test:

```rust
pub fn has_regex_metacharacters(text: &str) -> bool {
    regex::escape(text) != text
}
```

— [`regex.rs`][regex-rs]. Escape the pattern; if escaping changed it, it contains
metacharacters. `[source-verified]`

### The ten dimensions

#### 1. Pattern language

Three, chosen by `GrepMode::{PlainText, Regex, Fuzzy}` — `PlainText` is
`Default`. Regex is the Rust `regex` crate over **bytes with Unicode disabled**
and `multi_line(true)`; `\n` escapes in the pattern are expanded to real
newlines before compilation, and a multiline pattern automatically widens the
after-context so the whole match is shown. Fuzzy is subsequence-with-typos over
`neo_frizbee` (surveyed as [frizbee][frizbee] in the sibling tree), not a regular
language at all.

Smart case is a per-search option; the regex builder derives
`case_insensitive` from _"any uppercase in the pattern"_.

#### 2. Engine architecture

- **Plain**: `NeedleFinder`, a two-variant enum over `memchr::memmem::Finder`
  (case-sensitive) or a pre-lowered needle searched with `memmem::find`
  (case-insensitive). The case branch is resolved **once per line**, not per
  occurrence — `for_each_occurrence` matches on the variant outside its loop.
- **Regex**: the `regex` crate's own meta-engine, unexamined here; see
  `rust-regex` (Phase 2).
- **Fuzzy**: Smith-Waterman with an `exact_match_bonus` of 100 and **default gap
  penalties**, and the comment explains why the obvious tuning is wrong:
  raising gap penalties makes the aligner _"prefer dropping needle chars over
  paying gap costs, which inflates the typo count and breaks transposition
  matching"_ — `shcema` → `schema` becomes three typos instead of one.
- **Multi-pattern**: Aho-Corasick for an OR-of-literals.

Worst case is bounded by the corpus and the budget rather than by the automaton;
no engine here can backtrack catastrophically.

#### 3. Prefilter and literal extraction

Four layers, applied in order of cost:

1. **Bigram content index** (optional) → a candidate file bitmap. Grep-only; see
   `trigram-indexes` (Phase 4).
2. **Constraint prefilter** over the file list — path, extension, git status —
   with the `FilePath` retry above.
3. **Whole-file `memmem`**, before the searcher exists: _"Fast whole-file memmem
   check before entering the grep-searcher machinery. Skips Vec alloc, Searcher
   setup, and line-splitting for files that can't match."_ Enabled **only when
   `regex.is_none()`** — there is no literal extraction from a compiled regex, so
   regex mode forfeits this layer entirely.
4. **Fuzzy only — distinct-character presence**: collect the needle's unique
   bytes (both cases), require `unique_count - max_typos` of them to appear
   _anywhere_ in the file via `memchr`, else skip the file.

That fourth layer is the one worth stealing: it is a `memchr`-per-distinct-byte
test that costs almost nothing and rejects most files for a typical identifier
query, and it is _derived from the typo budget_ rather than tuned.

#### 4. Corpus access

Files arrive from the resident index, already walked and flagged. Content comes
from `get_content_for_search`, which serves a reusable 64 KiB read buffer for
small files and a fresh mmap slot for cache-miss files above a threshold, under
a content-cache budget. Caps: `MAX_FFFILE_SIZE` = **10 MiB**,
`max_matches_per_file` = 200.

**Binary detection is not in the grep path.** It is a flag set at index time from
a sniff, and grep simply honours the filtered list — cheap, and stale if the file
changed since the walk.

Line iteration is `LineStep` from the vendored fork; the fuzzy path materialises
`Vec<&str>` line and metadata vectors per file, sized `len / 40`.

#### 5. Concurrency

Rayon, with **files as the unit** and a growth policy that is the most
carefully-reasoned code in the module:

> _"Each chunk is a rayon barrier. A flat small chunk over 500k files = ~7800
> barriers; x2 growth makes it logarithmic. But a too-aggressive growth
> over-scans: when a page fills mid-chunk, the whole submitted chunk still runs.
> So only grow when the prefilter is weak (large candidate set); when bigram cut
> the set in half, keep fixed small chunks for cheap page-fill termination."_
> — [`grep.rs`][grep-rs] `[source-verified]`

Concretely: `base_chunk = threads * 4`; growth is ×2 and the cap is
`max(base * 256, 8192)` when the prefilter is weak, and ×1 at `base_chunk` when
it is strong (`candidates * 2 < total`). Per-worker state — matcher clone, read
buffer, mmap slot — is created by `map_init`, once per worker rather than per
file.

Abort and budget are polled **every eighth file**: _"perform all the atomic
machinery on every 8th"_. In the plain/regex path the budget is additionally
gated on `all_matches.len() > 1`, so a search that has found nothing keeps going
past its deadline; the fuzzy path checks unconditionally. The two paths disagree,
and neither comments on the difference.

#### 6. Index

None required. The optional bigram index is a **content** index — 2-byte
case-folded keys over dense column-major bitmaps — and is covered with the rest
of the n-gram family in `trigram-indexes` (Phase 4). It narrows the file list
before any of the above runs.

#### 7. Ranking and result model — including classification

A `GrepMatch` is deliberately rich: file index into a deduplicated file list,
1-based line, 0-based byte column, absolute byte offset (so, per its own doc,
_"the preview can seek directly without scanning from the top"_), the truncated
line text, a `SmallVec<[(u32,u32); 4]>` of highlight spans, an optional fuzzy
score, an `is_definition` flag computed at match time _"so output formatters
don't need to re-scan"_, and context vectors.

There is **no ranking**: results are in scan order, and only the fuzzy path
carries a score. Ordering is a caller's problem.

**Definition classification** is `classify.rs`, 131 lines, and its own header is
the most important sentence on this page for anyone considering porting it:

> _"Definition and import line classification (vibe coded POC) … Used to
> rank/annotate grep results for AI/MCP consumers. Gated behind the
> `definitions` feature since only such consumers need it."_ `[source-verified]`

Mechanically: trim leading whitespace, skip any number of modifier keywords
(ten of them, plus `pub(crate)`-style visibility by scanning to `)`), then test
the first token against thirteen definition keywords with an ASCII word-boundary
check. `is_import_line` is a separate, simpler prefix test. It is **entirely
language-agnostic** — `type` and `object` are in the keyword set — and it never
checks whether the _match_ falls inside the identifier the keyword introduces,
so a line that merely calls the needle inside a function definition classifies as
a definition. The option's own doc puts the cost at _"~2% overhead on large
repos"_ and advises disabling it _"for interactive grep where it is not needed"_.

#### 8. Unicode

Minimal, and deliberately. Regex compiles with `.unicode(false)`; case-insensitive
plain search pre-lowers the needle bytes; the classifier is ASCII-only. The one
Unicode-correct behaviour is display truncation, which walks back to a character
boundary. The fuzzy path validates the **whole file** as UTF-8 once and then uses
`from_utf8_unchecked` per line, because — measured — the per-line checks were
_"~8% of fuzzy grep time"_.

#### 9. Interactive behaviour

- **Budget**: `time_budget_ms`, 0 = unlimited; checked between files.
- **Abort**: an optional external `Arc<AtomicBool>` that _"overrides the picker's
  internal cancellation flag"_.
- **Pagination**: `file_offset` in, `next_file_offset` out — a file-granular
  cursor, `0` meaning "no more". `page_limit` defaults to 50 and is **soft**: the
  file that fills the page completes, and `files_consumed` is tightened to it so
  the next page resumes correctly.
- **Partial results are the normal case**, and `GrepResult` carries the counters
  (`total_files`, `filtered_file_count`, `total_files_searched`,
  `files_with_matches`) a UI needs to render "332 / 2350" honestly.

There is no streaming: a call returns a page, and the caller asks for the next.

#### 10. Measured evidence

The repository states two numbers relevant here, both as code comments rather
than published benchmarks: the per-line UTF-8 validation at _"~8% of fuzzy grep
time"_, and definition classification at _"~2% overhead on large repos"_. Both
are `[literature]` by this catalog's [labels][measurement] — they are the
authors' observations on unnamed hardware, not reproduced here. No cross-tool
comparison appears in the tree, and none should be inferred from these.

## The vendored searcher — what a line-oriented searcher must own

`fff-grep/` is ripgrep's `grep-searcher` reduced to 1,024 lines across seven
files, and its header states the deletion:

> _"Simplified grep-searcher for fff.nvim. Provides line-oriented search over
> byte slices with optional multi-line support. Only `search_slice` is supported
> -- no file/reader/mmap search."_ — [`fff-grep/src/lib.rs`][fff-grep-lib]

What survived:

- **`Matcher`** — a trait with **one required method**, `find_at(haystack, at)`,
  plus a defaulted `find` and a `line_terminator()` that returns `None` for a
  matcher that can cross lines.
- **`lines.rs`** (232 lines) — `LineStep`/`LineIter`, the line-boundary walk.
- **`searcher/`** — `SliceByLine` and `MultiLine` strategies over a `Config` of
  exactly **three fields**: `line_term`, `line_number`, `multi_line`.
- **`sink.rs`** — `Sink`, `SinkMatch`, `SinkFinish`.

What was deleted: reader and mmap search, binary detection, transcoding,
`passthru`, inverted match, before/after context (fff re-implements context in
its own `SinkState`), and most of `ConfigError`.

**That deletion list is close to a scope statement for a `@nogc` D
implementation**, and it is evidence rather than opinion: someone needed exactly
this subset for an interactive picker and shipped it.

## Strengths

- **One dispatch point** for three modes, marked as such in a comment — the
  structure `PKS2` should copy.
- **Degradation is visible.** Every fallback sets a field the UI can render; the
  regex path returns the compiler's own error string.
- **Prefilters are layered by cost** and the cheapest one runs before any
  machinery is constructed.
- **The chunk-growth policy reasons about barriers versus over-scan** explicitly,
  with the failure mode of each extreme written down.
- **Thresholds carry their motivating example.** Every constant in the fuzzy
  quality filter names the case it prevents — `ff_flv_encode_picture_header` for
  the density floor, `flvencodeX` for the typo cap.
- **The result model is complete**: absolute byte offset for seeking, byte
  columns, span list, all computed once at match time.

## Weaknesses

- **Mode selection lives outside the engine**, in more than one caller, and the
  callers disagree about the ladder.
- **The budget rule differs between paths** — plain/regex refuses to abort before
  two matches exist, fuzzy does not — with no comment acknowledging it.
- **Regex mode loses the whole-file prefilter entirely**, because no literal is
  extracted from the compiled pattern. This is the single largest structural gap
  against ripgrep.
- **The classifier is a POC by its own admission**: language-agnostic, no check
  that the match lands in the introduced identifier, feature-gated, and never on
  the interactive path.
- **Binary status is walk-time and cached**, so a file that became binary since
  the walk is still read.
- **No ranking at all** — scan order, with a score only in fuzzy mode.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                          | Trade-off                                                                              |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| One sink-selection point for all modes                  | Mode pairing is a single readable decision                                         | Fuzzy still returns early, so it is _not_ actually in that switch                      |
| Soft `page_limit`, finish the tipping file              | No partial file in a page; the cursor stays coherent                               | A page can overshoot by up to `max_matches_per_file`                                   |
| Abort polled every 8th file                             | Amortises the atomic over a per-line loop                                          | Up to seven files of latency after cancellation                                        |
| Budget ignored until ≥ 2 matches (plain/regex)          | The user always sees _something_ rather than an empty result                       | A pathological query with one match runs past its deadline; fuzzy does not do this     |
| Chunk growth only when the prefilter is weak            | Barriers are logarithmic on big sets; small chunks terminate cheaply on small ones | Two policies to reason about, tied to a `candidates * 2 < total` heuristic             |
| Whole-file `memmem` before the searcher                 | Skips allocation and line-splitting, not just matching                             | Unavailable in regex mode — the mode that needs it most                                |
| `.unicode(false)` for regex                             | Code search rarely needs Unicode classes; much smaller automata                    | `\w`, `\b` and `\p{…}` mean ASCII, silently                                            |
| Validate UTF-8 once per file, then `unchecked` per line | Measured at ~8% of fuzzy grep time                                                 | An `unsafe` block, and a mixed-encoding file degrades to per-line checks               |
| Truncate display lines to 512 bytes                     | Bounds the row model and the re-match cost                                         | Match indices must be recomputed on the truncated line; a match past 512 bytes is lost |
| Classification computed at match time                   | Formatters never re-scan                                                           | Paid on every match even when unused, hence the feature gate and the "~2%" advice      |

## Sources

Read in full at `3a0ce85c54875563bc55888b6b9829b44aeca911`
`[source-verified]`:

- [`fff-core/src/grep/mod.rs`][mod-rs] — the architecture statement
- [`fff-core/src/grep/grep.rs`][grep-rs] — dispatch, fallback, `NeedleFinder`, `perform_grep`
- [`fff-core/src/grep/types.rs`][types-rs] — `GrepMode`, `GrepMatch`, `GrepSearchOptions`, `GrepResult`
- [`fff-core/src/grep/fuzzy_grep.rs`][fuzzy-rs] — typo budget, character prefilter, quality filters
- [`fff-core/src/grep/regex.rs`][regex-rs] — `has_regex_metacharacters`, `build_regex`
- [`fff-core/src/grep/prefilter.rs`][prefilter-rs] — constraint prefilter and the `FilePath` retry
- [`fff-core/src/grep/sink.rs`][sink-rs] — truncation, context, char→byte offset mapping
- [`fff-core/src/grep/classify.rs`][classify-rs] — the definition/import heuristic
- [`fff-core/src/constants.rs`][constants-rs] — `MAX_FFFILE_SIZE`
- [`fff-grep/src/lib.rs`][fff-grep-lib], [`matcher.rs`][fff-grep-matcher], [`searcher/mod.rs`][fff-grep-searcher] — the vendored fork

<!-- References -->

[repo]: https://github.com/dmtrKovalenko/fff
[mod-rs]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/grep/mod.rs
[grep-rs]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/grep/grep.rs
[types-rs]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/grep/types.rs
[fuzzy-rs]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/grep/fuzzy_grep.rs
[regex-rs]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/grep/regex.rs
[prefilter-rs]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/grep/prefilter.rs
[sink-rs]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/grep/sink.rs
[classify-rs]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/grep/classify.rs
[constants-rs]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/constants.rs
[fff-grep-lib]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-grep/src/lib.rs
[fff-grep-matcher]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-grep/src/matcher.rs
[fff-grep-searcher]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-grep/src/searcher/mod.rs
[picker]: ../../specs/hue/picker.md
[fuzzy-matching]: ../fuzzy-matching/fff.md
[frizbee]: ../fuzzy-matching/frizbee.md
[measurement]: ./measurement.md
