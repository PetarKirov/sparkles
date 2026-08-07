# fff (Rust)

The resident file-search engine — the survey's only subject that is a whole
_engine_ rather than a matcher: a long-lived process keeping the index warm,
with a constraint query language, a composite re-ranking formula over a
[frizbee] base score, frecency and query-history stores, and a chunk-deduped
path arena. It is the primary porting source for `sparkles:fuzzy`.

|                   |                                                                                                  |
| ----------------- | ------------------------------------------------------------------------------------------------ |
| Language          | Rust (~48k lines, 7 crates)                                                                      |
| License           | MIT                                                                                              |
| Repository        | [dmtrKovalenko/fff][fff-repo]                                                                    |
| Surveyed revision | [`3a0ce85c`][fff-tree] (all file/line citations pin this commit)                                 |
| Category          | Resident search engine (Neovim frontend; C ABI; MCP server)                                      |
| Algorithm class   | [frizbee]'s SW-with-substitution base (via the `neo_frizbee` 0.11.0 fork) + composite re-ranking |

## Overview

### What it solves

Sub-10 ms file queries on a 500k-file Chromium checkout against 3–9 s per
`rg` spawn — by staying resident: the file index, git status, frecency and
content caches live in one process across queries. **The base fuzzy
algorithm is not in this repo**: `crates/fff-core/src/score.rs` contains no
matching logic — it is a _re-ranking_ layer over `neo_frizbee` (pinned in
[`Cargo.toml:42`][fff-cargo] with the `match_end_col` feature). The
[frizbee] deep-dive covers that kernel; this one covers everything fff adds.

### Design philosophy

Warm state, and a paranoid discipline about who may read it. The post-scan
pipeline carries this header comment
([`scan.rs:301-358`][fff-scan], verbatim):

> THIS IS VERY VERY IMPORTANT THAT ANYTHING INSIDE THIS FUNCTION TO NOT READ
> ANYTHING CLEARABLE OUTSIDE… it can only WRITE information using single
> instructions.

## How it works

A query runs as: parse (`fff-query-parser`) → constraint prefilter →
frizbee `match_list` over the path arena → composite re-ranking →
`select_nth`-style partial sort → paginate → a _second_ frizbee pass
(`match_list_indices`) over only the returned page to produce highlight byte
ranges ([`file_picker.rs:1039-1133`][fff-picker]).

## Algorithm & scoring model

fff configures frizbee with smart-case as a _score-only_ concern
([`score.rs:645-654`][fff-score]) — matching stays case-insensitive; case
affects only bonuses:

```rust
neo_frizbee::Config {
    max_typos: Some(context.max_typos),
    sort: false,                                    // fff sorts itself
    scoring: Scoring {
        capitalization_bonus: if has_uppercase { 8 } else { 0 },
        matching_case_bonus:  if has_uppercase { 4 } else { 0 },
        ..Default::default()
    },
    ..Default::default()
}
```

The typo budget is derived from the query
([`file_picker.rs:1073`][fff-picker]): `(effective_query.len() / 4).clamp(2, 6)`
— len ≤ 8 → 2, 16 → 4, ≥ 24 → 6; parts after the first are further clamped
to the part's length.

The composite re-ranking, per surviving match
(`match_and_score_in_arena`, [`score.rs:605-888`][fff-score]):

```text
total = base_score                                   (frizbee u16)
      + frecency_boost      base · frecency / 100    (i.e. +1 % per point)
      + git_status_boost    base · 15 %              when git-modified
      + distance_penalty    0 .. −20                 vs the current file's dir
      + filename_bonus      ladder below
      + current_file_penalty −base / 4               when it IS the current file
      + combo_match_boost   query-history store, below
      + path_alignment      suffix-overlap gate, below
```

The filename-bonus ladder ([`score.rs:764-792`][fff-score]):

| Condition                                                                              | Value                                         |
| -------------------------------------------------------------------------------------- | --------------------------------------------- |
| exact filename (case-insensitive, lengths equal)                                       | `base / 5 * 2` (40 %)                         |
| fuzzy filename match (via frizbee's `end_col`)                                         | `min(base / 6, 30)`                           |
| fuzzy filename via the fallback second pass                                            | same cap, scaled by `quality / (needle · 16)` |
| filename is a language entry point (`mod.rs`, `index.ts`, `__init__.py`, `main.go`, …) | `base · 5 %`                                  |

Filename placement uses the cheap approximation
`match_start ≈ end_col − needle_len + 1` — a genuine backtrack never runs in
the hot path. When a path match lands before `filename_offset`, a _second_
frizbee call re-matches the bare filename (skipped when the query contains a
separator or there are more than 15,000 path matches). Path alignment fires
only when the query contains a separator: count case-insensitively equal
bytes walking needle and path from the end; if the common suffix exceeds 10
bytes and covers ≥ 30 % of the needle, add `base · coverage%`. The distance
penalty ([`path_utils.rs:86-131`][fff-path-utils]) is
`−(current_dir_depth − common_prefix_depth)` floored at −20 — only the
current file's remaining components count.

Multi-part queries ([`score.rs:46-138`][fff-score]): parts under 2 bytes are
dropped; part 0 matches the full set, later parts re-match only survivors;
scores combine as a running average capped at `u16::MAX`. An _empty_ fuzzy
query ranks by frecency alone with a different weighting
(`access + 4 · modification`).

Every result carries a `Score` breakdown struct (9 × i32 + a `match_type`
label) driving a `:FFFDebug` overlay — a ranking nobody can inspect is one
nobody can fix.

## Prefiltering

Three distinct prefilters, easily conflated:

1. **frizbee's subsequence prefilter** — per candidate, before SW (see the
   [frizbee] deep-dive). This is the _only_ fuzzy-path prefilter.
2. **The constraint prefilter** ([`constraints.rs`][fff-constraints]) —
   evaluates the query's constraint list against path/metadata:
   `Extension` constraints form an OR bucket; everything else ANDs in order
   with short-circuit. `None` means "no constraints, don't filter";
   `Some(empty)` means "nothing survived" — callers distinguish these.
   Git-status mapping: `modified` = worktree/index modified+new+renamed,
   `untracked` = `WT_NEW`, `staged` = index new/modified/deleted/renamed/
   typechange, `clean` = empty status. Glob evaluation is batched
   (a prepass mask measured ~2× faster than a hash set); rayon above 10,000
   items. Two recorded bugs: `type:` is a **silent no-op** (never expanded
   to extensions — so `!type:rust` filters out _everything_), and prefix
   matching makes empty `status:` parse as `Modified`.
3. **The bigram inverted index** ([`bigram_filter.rs`][fff-bigram]) — a
   **grep-only content index**, _not_ a path prefilter: 2-byte case-folded
   printable-ASCII keys direct-addressing a 65,536-entry table of dense
   column-major `u64` bitmaps (plus a skip-1 index ANDed in), columns
   dropped when too rare (< ~3 %) or too common (≥ 90 %). False positives
   allowed, verified downstream by whole-file `memmem`. Peak build memory
   ≈ 625 MB at 500k files (two builders alive simultaneously). Worth
   stealing only if a content-grep mode lands.

## Memory strategy

The path arena ([`simd_path.rs`][fff-simd-path]) is the deepest idea:

> SIMD chunk size in bytes (matches NEON/SSE2 register width). This must
> stay in sync with neo_frizbee's internal chunk size.

Paths are split into 16-byte chunks, **globally deduplicated at chunk
granularity** (`AHashMap<[u8;16], u32>` — repeated directory prefixes
collapse across the whole repo), and items store only `u32` chunk indices
plus `byte_len: u16` and `filename_offset: u16` (4 indices inline — "64
bytes inline, ~85 % of paths"). frizbee's resolver API loads SIMD registers
straight from arena pointers, so matching does zero copies and zero
allocations; the last chunk is zero-padded, which is exactly what SIMD
wants. `FileItem` is ≈ 96 bytes with an `AtomicU8` flag byte; `DirItem` 40
bytes with a `fetch_max` frecency roll-up. The overflow arena (`StableVec`,
capacity fixed at construction + 1024 slots) makes watcher-added files
searchable without relocation — `push` returning `false` _is_ the
full-rescan trigger. Top-K: `select_nth_unstable_by` when
`offset + limit < matched / 2`, then a full sort of the survivors (glidesort
with a shared, `try_lock`-only scratch buffer); comparator = score desc,
then mtime desc.

## SIMD & parallelism

Matching SIMD is [frizbee]'s. fff-side SIMD exists only in grep (rare-byte-
pair `memmem`, bigram normalization). Fuzzy search runs on rayon's global
pool plus frizbee's own `std::thread::scope` work-stealing driver (chunk =
2048, one matcher clone per thread); two dedicated pools exist for other
work — `BACKGROUND_THREAD_POOL` (half the cores; scanning, bigram build) and
`SEARCH_THREAD_POOL` (P-cores only on macOS; **grep only**) — motivated by
asymmetric chips: the global pool oversubscribes E-cores, and `open()`
contends past P-core count (measured on an M4 Max: grep 16t = 6.2 s vs
13t = 4.9 s).

**fff's fuzzy path has no time budget, no abort signal, and no pagination
cursor.** Those exist only in grep
([`grep.rs:537-610`][fff-grep]): `time_budget_ms`, an
`Arc<AtomicBool>` abort polled every 8th file, never honored before at
least 2 matches exist, and ramping chunk sizes. Any interactive-cancellation
design for `sparkles:fuzzy` is new machinery informed by grep, not a port.

## Unicode & case handling

Inherited from [frizbee] (UTF-8 bytes, no normalization). fff's own string
primitives (constraint matching) are ASCII-case-insensitive scalar code with
`is_char_boundary` guards throughout — added in response to real Korean-path
panics. Both `/` and `\` are accepted as separators on every platform.

## Incremental & streaming architecture

Resident-process incrementality rather than per-keystroke incrementality: a
watcher appends to the overflow arena, git status refreshes asynchronously
(flags are atomics so no write lock), and the frecency/combo stores update
on file-open. Each keystroke still re-runs the full match. The overflow
arena is searched _before_ the base arena so newly created files win ties.

### The query language

`fff-query-parser` uses **shape-based first-byte dispatch** — no `ext:` or
`path:` prefixes to memorize. Tokens split on whitespace (no quoting);
per-token dispatch order ([`parser.rs:261-332`][fff-parser]): `\` escape
(bypass, backslash retained) → `*.X` extension (wildcards in `X` demote to
glob) → `!` negation → `/`-prefixed or `/`-suffixed path segment → glob
(wildcard chars `* ? [ {`) → `key:value` on the _first_ colon (`type`,
`status/st/g/git`) → fuzzy text. Negated _text_ requires ≥ 3 bytes and one
alphanumeric, so `!=` and `!!` stay literal. Git-status values
prefix-match `modified`/`untracked`/`staged`/`clean` in that fixed order.
A trailing `:line[:col]` / `:12-14:20` / `(line,col)` parses as a
`Location` so pasting `src/app.d:120` from a diagnostic opens where it
points ([`location.rs`][fff-location]); single-token queries that _look_
like paths deliberately stay fuzzy text (`treat_lone_path_as_text` is true
in every shipped config). Constraint evaluation order is source order;
`Extension`s OR, the rest AND.

### Frecency and the combo store

[`dbs/frecency.rs`][fff-frecency]:

```rust
const DECAY_CONSTANT: f64 = 0.0693;      // ln(2)/10 → 10-day half-life
const MAX_HISTORY_DAYS: f64 = 30.0;
const MAX_TIMESTAMPS_PER_FILE: usize = 128;
const AI_DECAY_CONSTANT: f64 = 0.231;    // ln(2)/3 → 3-day half-life (AI mode, 7-day window)
```

Access score = Σ `exp(−k · days_ago)` over a per-file chronological
`VecDeque` (≤ 128 stamps, 30-day write-side cutoff), newest-first with early
exit, then a soft knee: linear to 10, `10 + √(excess)` above — practical max
≈ 21. The modification score is **gated on git-modified status** and
piecewise-linear over `[(16, 2 min), (8, 15 min), (4, 1 h), (2, 1 d),
(1, 1 w)]` with a hard cliff to 0 past a week. Both enter ranking as
+1 % of base per point. Keys are `blake3(path)`; storage is LMDB.

The **query→file combo store** ([`query_tracker.rs`][fff-query-tracker]):
each `(project, raw query)` maps to exactly **one** file —
same-file re-open increments `open_count`, a different file _replaces_ the
entry and resets to 1. Boost: `open_count ≥ 3` → `open_count × 100`; below
→ `open_count × 5`. One DB read per search (not per candidate), applied by
relative-path suffix match. The store is unbounded (no LRU/TTL; only an
8 MiB whole-DB nuke at open) — a recorded flaw, not a feature.

## Strengths

- The only end-to-end proof that the frizbee family + re-ranking works for
  file picking at Chromium scale.
- The composite formula with a per-result breakdown struct (inspectable
  ranking).
- Chunk-deduped zero-copy path arena feeding the matcher's registers
  directly.
- Shape-based query grammar — discoverable, no prefix vocabulary.
- Frecency model with a modification-recency curve and a query-history
  combo boost — recency signals fzf-family tools lack entirely.

## Weaknesses

- Score/highlight tier divergence inherited from frizbee's unverified typo
  budget (plus its own approximated `match_start`).
- No cancellation or budgeting on the fuzzy path.
- `type:` no-op, empty-`status:` mis-parse, unbounded combo store, and a
  `SIZE_CAP > MAP_SIZE` inversion in the frecency DB (can never fire).
- `StableVec`'s `&mut`-with-live-`Arc`-clones pattern is documented latent
  UB in its own comments.
- Two of everything (arena split, formula duplicated for files/dirs, config
  duplicated per call site) — port-hostile duplication.

## Key design decisions and trade-offs

| Decision                                  | Rationale                                           | Trade-off                                                        |
| ----------------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------- |
| Resident engine, warm index               | Sub-10 ms queries vs seconds per cold spawn         | Daemon lifecycle, cache-invalidation discipline (the scan quote) |
| Re-rank over a stock matcher              | Product "feel" iterates without touching the kernel | Base score and boosts interact multiplicatively (`base · x %`)   |
| 16-byte chunk-dedup arena                 | Zero-copy SIMD loads; prefix dedup across the repo  | Chunk table + resolver indirection; 16-byte granularity waste    |
| Typo budget from query length             | Longer queries tolerate more error                  | Budget unverified on the score path                              |
| One file per (project, query) combo entry | One DB read per search; trivially small             | Alternating between two files resets the combo every time        |
| Overflow arena searched first             | New files win ties; no relocation                   | Hard 1024-item cap; overflow triggers a full rescan              |
| Smart-case as score-only                  | Case never filters, only ranks                      | Diverges from fzf's per-term case-sensitive matching             |

## Sources

- [`crates/fff-core/src/score.rs`][fff-score] — re-ranking layer (config,
  ladder, path alignment, multi-part, breakdown struct).
- [`crates/fff-core/src/file_picker.rs`][fff-picker] — orchestration, typo
  budget, combo lookup, arena build.
- [`crates/fff-core/src/simd_path.rs`][fff-simd-path] — the chunked arena
  (chunk-size quote).
- [`crates/fff-core/src/index/constraints.rs`][fff-constraints] and
  [`…/index/bigram_filter.rs`][fff-bigram] — the two non-fuzzy prefilters.
- [`crates/fff-core/src/dbs/frecency.rs`][fff-frecency] and
  [`…/dbs/query_tracker.rs`][fff-query-tracker] — the stores.
- [`crates/fff-query-parser/src/parser.rs`][fff-parser] and
  [`…/src/location.rs`][fff-location] — the grammar.
- [`crates/fff-core/src/grep/grep.rs`][fff-grep] — budget/abort (grep-only).
- [`crates/fff-core/src/scan.rs`][fff-scan] — the post-scan snapshot
  discipline (quoted above).
- [`neo_frizbee` 0.11.0][neo-frizbee] — the pinned matcher fork (its
  `repository` field points at [saghen/frizbee][frizbee-repo]).

<!-- References -->

[fff-repo]: https://github.com/dmtrKovalenko/fff
[fff-tree]: https://github.com/dmtrKovalenko/fff/tree/3a0ce85c54875563bc55888b6b9829b44aeca911
[fff-cargo]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/Cargo.toml#L42
[fff-score]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/score.rs
[fff-picker]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/file_picker.rs
[fff-simd-path]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/simd_path.rs
[fff-constraints]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/index/constraints.rs
[fff-bigram]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/index/bigram_filter.rs
[fff-frecency]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/dbs/frecency.rs
[fff-query-tracker]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/dbs/query_tracker.rs
[fff-parser]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-query-parser/src/parser.rs
[fff-location]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-query-parser/src/location.rs
[fff-grep]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/grep/grep.rs
[fff-scan]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/scan.rs
[fff-path-utils]: https://github.com/dmtrKovalenko/fff/blob/3a0ce85c54875563bc55888b6b9829b44aeca911/crates/fff-core/src/path_utils.rs
[neo-frizbee]: https://crates.io/crates/neo_frizbee/0.11.0
[frizbee-repo]: https://github.com/saghen/frizbee
[frizbee]: ./frizbee.md
[fzf]: ./fzf.md
