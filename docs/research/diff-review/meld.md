# Meld (Python / GTK)

Meld is the canonical desktop visual diff/merge tool: 2- and 3-way file and
directory comparison with live editing, curved cross-pane connectors,
proportional scroll synchronization, and pluggable VCS backends — all built as
a Python/PyGObject application on GtkSourceView.

| Field             | Value                                                                   |
| ----------------- | ----------------------------------------------------------------------- |
| Language          | Python 3 (PyGObject; cairo for custom drawing)                          |
| License           | GPL-2.0-or-later                                                        |
| Repository        | <https://gitlab.gnome.org/GNOME/meld>                                   |
| Documentation     | <https://meldmerge.org/help/>                                           |
| Category          | gui-differ                                                              |
| First release     | 0.1, 2002-05-18 (`NEWS`)                                                |
| Latest release    | 3.24.0, 2026-06-20 (`NEWS`); surveyed tree is the 3.99.0 GTK4-port line |
| Surveyed revision | `c0c9e4c491f76cb9eb7f69e9825684e22a27fb34` (2026-07-29)                 |

> [!NOTE]
> The surveyed tree is the in-progress GTK4/libadwaita port (`meson.build`
> declares `gtk4 >= 4.12`, `gtksourceview-5`, `libadwaita-1 >= 1.6`, version
> `3.99.0`), not the shipping GTK3-based 3.24 series. The diff engine and
> data model are unchanged between the two; rendering code paths (snapshot
> API, `Gsk.PathBuilder`) are the new ones.

## Overview

### What it solves

Meld makes two- and three-way comparison an _editing_ experience rather than a
read-only report: every pane is a live `GtkSourceView` buffer, the diff
recomputes incrementally as you type, and chunk-level merge actions (copy
left/right, delete) sit directly in the gutters between panes. The same shell
hosts three document types — file comparison (`meld/filediff.py`), folder
comparison (`meld/dirdiff.py`), and a version-control status view
(`meld/vcview.py`) — that spawn into each other (double-click a modified file
in the VC view to open a file diff against the repository version).

### Design philosophy

From `README.md`:

> "Meld is a visual diff and merge tool targeted at developers. Meld helps
> you compare files, directories, and version controlled projects. […] Meld
> helps you review code changes, understand patches, and makes enormous merge
> conflicts slightly less painful."

Two structural commitments follow from that. First, comparison must never
block editing: the Myers matcher is written as a generator that yields to a
cooperative scheduler (`meld/task.py`), and inline highlighting runs in a
separate OS process (`meld/matchers/helpers.py`). Second, all multi-pane
coordination flows through the middle pane; from `_sync_vscroll` in
`meld/filediff.py`:

> "For three pane scrolling, we want panes to be tied, but need an influence
> mapping. In Meld, all influence flows through the middle pane, e.g., the
> user moves the left pane, that moves the middle pane, and the middle pane
> moves the right pane."

## How it works

### 1. Diff computation & data model

All diffs are computed in-process, in pure Python, by
`meld/matchers/myers.py`. `MyersSequenceMatcher` subclasses
`difflib.SequenceMatcher` but replaces the algorithm with the **O(NP)
variant** of Myers (Wu, Manber, Myers, Miller, "An O(NP) Sequence Comparison
Algorithm", 1989 — cited in the `initialise` docstring). Notable engineering
around the core loop:

- **Preprocessing**: `preprocess_remove_prefix_suffix` strips the common
  prefix/suffix using a bisection (`find_common_prefix`/`find_common_suffix`
  binary-search on slice equality, not a linear scan);
  `preprocess_discard_nonmatching_lines` builds a `frozenset` of each side's
  lines and drops lines that cannot match anything on the other side — but
  only commits to the reduced sequences when more than 10 lines were
  discarded ("the constant represents a heuristic of how many lines
  constitute 'worthwhile'"). Discarded-line indices are kept (`aindex`/
  `bindex`) so `build_matching_blocks` can split snakes back onto original
  line numbers.
- **Incrementality**: `initialise` is a generator that yields every 100
  iterations of the outer `p` loop, so the UI scheduler can interleave
  redraws with diffing of huge files.
- **Postprocessing**: `postprocess` scans matching blocks backwards and
  re-merges adjacent blocks that the greedy algorithm split, reducing "chaff".
- **Data model**: the unit is `DiffChunk`, a `NamedTuple`
  `(tag, start_a, end_a, start_b, end_b)` with `tag ∈ {replace, insert,
delete, conflict, equal}` over **line indices**. The same shape is reused
  at character granularity for inline highlights.

Three-way comparison never runs a 3-way algorithm. `Differ`
(`meld/matchers/diffutil.py`) stores exactly two pairwise diffs, both
anchored on the middle pane: "Internally, diffs are stored from
text1 -> text0 and text1 -> text2." `_merge_diffs` walks the two chunk
streams in lockstep, grouping chunks whose middle-pane ranges overlap;
`_auto_merge` classifies each group by literally comparing the outer texts —
if `texts[0][l0:h0] == texts[2][l2:h2]` both sides made the same change
(`replace`/`insert`/`delete`), otherwise the group becomes a `conflict` pair.
`AutoMergeDiffer` (`meld/matchers/merge.py`) optionally re-diffs the two
outer sides of a conflict against each other to carve genuinely-conflicting
sub-ranges out of mergeable ones.

Edits do not re-diff the whole file: `Differ.change_sequence` locates the
chunks bracketing the edited line range, re-runs the matcher only on the
lines between the surrounding equal regions (`_change_sequence`), and
integer-offsets every later chunk. It also computes exact
removed/added/modified chunk sets so downstream consumers (inline
highlighting) can update only what changed.

Two matcher variants specialize the base class:

- `InlineMyersSequenceMatcher` — character-level; replaces the
  discard-nonmatching-lines pass with a **3-gram (k-mer) index** so isolated
  characters that happen to appear on both sides don't defeat the reduction.
- `SyncPointMyersSequenceMatcher` — takes user-placed _sync points_ (line
  pairs) and runs an independent Myers diff per segment between consecutive
  points, concatenating the results. Sync points are `GtkSource.Mark`s
  managed by `meld/syncpoints.py`, with a small per-pane state machine
  (`MATCHED`/`SHORT`/`DANGLING`) deciding which action (add/match/move/
  delete) the UI offers on the current line.

### 2. Rendering & layout

Strictly side-by-side: 1–3 `GtkSourceView` panes (`set_num_panes` in
`meld/filediff.py`). Syntax highlighting is inherited for free from
GtkSourceView's language manager (`guess_language` in `meld/sourceview.py`);
diff chunk backgrounds are painted _under_ the syntax layer per line, so
highlighting and diff coloring compose without any interaction between the
two systems.

The signature visual is the **link map** (`meld/linkmap.py`): a
`Gtk.DrawingArea` strip between adjacent panes that draws each chunk as a
closed cairo path — cubic Béziers from the source lines' y-extent to the
target lines' y-extent, with control points at the horizontal midpoint —
filled with the chunk-type color and stroked. Chunks whose far endpoint is
entirely off-screen are **culled to a rounded-rectangle stub** hugging the
near pane edge (radius 3 px), so the gutter never draws misleading
full-height curves. The current chunk gets a second translucent
"current-chunk-highlight" fill pass.

Between each pane pair sit two `ActionGutter`s (`meld/actiongutter.py`)
showing per-chunk action icons (apply left/right, delete, copy) that track
the pointer and the chunk under the cursor. The line-number gutter itself is
diff-aware: `GutterRendererChunkLines` (`meld/gutterrendererchunk.py`) draws
bold line numbers over the chunk's fill color and strokes top/bottom chunk
borders per line (with a special extra border for zero-height insert chunks).

Rows are **not** aligned by inserting filler lines. Panes scroll
independently, and alignment is an illusion produced by proportional scroll
sync: `_sync_vscroll` maps the master pane's sync line through the chunk
list — inside a chunk it interpolates fractionally
(`fraction = (target_line - mbegin) / (mend - mbegin)`); between chunks it
interpolates through the inter-chunk gap — then positions each other pane so
the corresponding (fractional) line sits at the same viewport fraction.
`calc_syncpoint` (`meld/misc.py`) slides the synchronization anchor from the
top of the screen (at document start) through the middle to the bottom (at
document end), so unequal-length files still pin their first and last lines.
Each pane also gets a `ChunkMap` (`meld/chunkmap.py`) overview bar: chunk
rectangles rendered once into a cached cairo surface keyed by size/theme,
with a draggable viewport handle overdrawn live.

### 3. Intra-line & noise handling

Inline (word/char-level) highlighting runs only on `replace` chunks. The
chunk's two texts are shipped to a `MatcherWorker` — a **separate
`multiprocessing.Process`** running `InlineMyersSequenceMatcher` — via task
and bounded result queues (`meld/matchers/helpers.py`); the result queue is
deliberately capped at 5 so highlight application interleaves with
computation instead of starving until the end. Results are LRU-cached by
text pair (`CachedSequenceMatcher.clean` keeps ~2–3× the current chunk
count). Because the `diffs-changed` signal carries exact
removed/added/modified chunk sets, only affected chunks are re-highlighted
after an edit (`meld/filediff.py`, `on_diffs_changed`).

Application-side cleanup in `apply_highlight` is where readability is won:
`equal` runs shorter than 3 characters are dropped (unless they touch the
chunk boundary), merging noisy fragmented matches into readable blocks; and
highlight bounds are widened outward to cursor positions so a difference in
a combining diacritic highlights the whole visible grapheme. Chunks whose
combined text exceeds `inline_limit = 20000` chars skip refinement entirely
(whole chunk tinted) and surface a "highlight anyway?" prompt setting
`force_highlight`.

Formatting-noise suppression is regex-based, not structural. _Text filters_
(`meld/filters.py`, GSettings-backed, with shipped presets in
`data/org.gnome.Meld.gschema.xml`: CVS/SVN keywords, C/C++/script comments,
all/leading/trailing whitespace) are applied to the text **fed to the
matcher** while the buffer displays the original: `BufferLines`
(`meld/meldbuffer.py`) wraps each `GtkTextBuffer` as a lazily-cached list of
filtered lines, and `_filter_text` additionally paints a `dimmed` tag over
filtered spans so the user can see what was ignored. If a filter changes the
line count the comparison is declared inaccurate via a one-time warning
dialog — filters must be line-preserving. Match-group semantics: if a regex
has groups, only participating groups are removed (`apply_text_filters` in
`meld/misc.py`). Blank-line noise is handled separately _after_ diffing:
`consume_blank_lines` (`meld/matchers/diffutil.py`) shrinks each chunk's
range past leading/trailing blank lines and retags (`replace` → `insert`/
`delete`) or drops chunks that become empty. There is **no moved-code
detection** anywhere.

### 4. Navigation, folding & scale

`Differ._update_line_cache` precomputes, for every line of every pane, a
`(current_chunk, prev_chunk, next_chunk)` triple — so cursor-follows-chunk
UI, previous/next-change actions, and action-gutter sensitivity are all O(1)
lookups per cursor move. The `ChunkMap` supports click/drag navigation over
the whole document. There is **no folding or collapsing of unchanged
regions** — a deliberate consequence of panes being live editors over full
buffers; for large files the scale guards are instead: generator-based
diffing on the idle scheduler, the discard-nonmatching-lines reduction, the
out-of-process inline matcher, and the 20 000-char inline bail-out.
Directory scans are likewise cooperative iterators
(`_search_recursively_iter` in `meld/dirdiff.py`) yielding progress strings.

Directory comparison aligns entries by name through `CanonicalListing`,
which canonicalizes per user options (case folding for case-insensitive
matching, Unicode NFC normalization) and _reports_ rather than hides
pathologies: same-canonical-name collisions become row errors, and
names differing only in surrounding whitespace are flagged as "misleading
whitespace". File equality (`_files_same`) is tiered: shallow
(size + mtime with configurable time resolution, for network mounts) →
size mismatch → chunked byte comparison (mmap over 4 KiB) → and only if
different _and_ text filters/blank-line options are active, a normalization
pass (`_normalize`: newline normalization, blank-line removal, filter
application, then blank-line removal again) yielding the distinct
`SameFiltered` state, all behind a stat-validated cache.

### 5. VCS & review integration

`meld/vc/` is a small adapter framework (`_vc.Vc` base) with backends for
git, mercurial, bazaar, svn, cvs, and darcs — each shelling out to the
CLI. The git backend (`meld/vc/git.py`) reads status by combining
`git diff-index --cached HEAD --relative` (index vs HEAD) with
`git diff-files -0 --relative` (index vs worktree), materializes historical
versions with `git show :<stage>:<path>` into temp files, and offers
add/remove/revert/commit/push/unstage actions (plus a commit-message prefill
hook). Conflict files open as a 3-way comparison of index stages 1/2/3; the
standout trick is `remerge_with_ancestor`, which runs
`git merge-file -p --diff3` and post-processes the output
(`base_from_diff3` in `meld/vc/_vc.py`) to synthesize a _pre-merged_ middle
pane — pre-merged everywhere without conflict, common-ancestor text where
there is one — so the user only hand-resolves true conflicts. After saving
the middle pane of a conflict comparison, Meld offers to run the VC's
`resolve` command. Granularity of merge actions is the chunk (copy/delete
via action gutters); there is no hunk-level _staging_ (no `git add -p`
equivalent), and no code-review-platform integration of any kind — no PR
models, comments, or revision stacks. Meld's review role is purely local, as
a `git difftool`/`mergetool`.

### 6. Architecture & reuse

Single-process GTK app (plus the one inline-matcher worker process), pure
Python throughout — even the O(NP) core, which is why so much effort goes
into input reduction rather than raw speed. Layering is unusually clean for
a 24-year-old codebase:

- `meld/matchers/` — algorithm layer; pure Python, UI-free except the
  `DiffChunk.to_iters` convenience. `Differ`/`AutoMergeDiffer` +
  `MyersSequenceMatcher` variants are directly liftable as a specification
  for any reimplementation: the pairwise-through-the-middle 3-way model, the
  merge cache, the line cache, and incremental `change_sequence` re-diffing
  are all here.
- `meld/filediff.py` (2 800 lines) — the monolithic controller wiring
  buffers, differ, gutters, link maps, and actions; not reusable, but the
  widgets it composes (`LinkMap`, `ChunkMap`, `ActionGutter`,
  `GutterRendererChunkLines`) are small, self-contained drawing components.
- `meld/vc/` — adapter-pattern VCS layer usable as a catalog of the exact
  plumbing commands needed per VCS.
- Scheduling is cooperative and home-grown (`meld/task.py`
  `SchedulerBase`/FIFO variants pumped from the GTK idle loop) — a design
  from 2002 that predates asyncio and still works.

## Strengths

- **Editing-first comparison**: panes are real editor buffers; the diff
  updates incrementally on keystroke via localized re-diffing
  (`change_sequence`), not whole-file recomputation.
- The **filtered-text-for-matching / real-text-for-display** split
  (`BufferLines` + dimmed tags) is the cleanest formatting-noise UX in this
  survey class: noise is ignored by the engine yet visibly marked, and
  line-count preservation keeps coordinates trivially mappable.
- **Proportional scroll sync with a sliding sync point** aligns unequal
  panes without filler lines, keeping both documents authentic.
- Inline refinement quality: 3-gram reduction, <3-char equal-run merging,
  grapheme-boundary widening, and out-of-process computation with bounded
  queues for interactivity.
- 3-way merge assists that reduce work before the human arrives:
  `_auto_merge` same-change detection, `AutoMergeDiffer` conflict carving,
  and `git merge-file --diff3`-synthesized middle panes.
- User-placed **sync points** rescue the matcher when block moves or large
  rewrites defeat automatic alignment.

## Weaknesses

- Line/character diff only — no structural or syntax-aware matching, and no
  moved-block detection; a moved function is a delete plus an insert.
- Noise handling is regex-only and must be line-count-preserving; it cannot
  express "this table was re-aligned" or any cross-line normalization.
- Pure-Python O(NP) on line lists: fine interactively, but large files rely
  on heuristics (discard threshold, inline bail-out) rather than raw speed;
  the whole file is always loaded into GTK buffers.
- No collapsing of unchanged regions, so review of a huge file with three
  small hunks means scrolling through everything (mitigated by chunk map +
  next-change navigation).
- No review-platform layer: no comments, PR revisions, or stacked-change
  concepts.
- 3-way is derived from two pairwise diffs through the middle pane; changes
  aligned between the two outer panes but absent from the base can produce
  awkward chunking (acknowledged in-source by the disabled interpolation
  branch in `AutoMergeDiffer._auto_merge`).

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                      | Trade-off                                                                                    |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------- |
| Panes are live `GtkSourceView` editors, not rendered reports   | Merge = edit; syntax highlighting and undo come free from the toolkit          | No virtualized rendering; whole file in memory; folding effectively impossible               |
| 3-way stored as two pairwise diffs anchored on the middle pane | One algorithm serves 2- and 3-way; merge semantics reduce to overlap grouping  | Outer-pane-vs-outer-pane agreement must be re-derived by text comparison; chunking artifacts |
| Diff as cooperative generator + worker process for inline      | UI never blocks, even on multi-MB files, without threads touching GTK          | Home-grown scheduler; cross-process queues add lifecycle/cleanup complexity (see `stop()`)   |
| Scroll-sync alignment instead of filler-line alignment         | Buffers stay authentic (editable, saveable byte-for-byte)                      | Panes only _approximately_ align mid-scroll; complex sync code with an influence map         |
| Text filters remove text from comparison but not from display  | Noise suppression with full visibility (dimmed spans); coordinates stay stable | Filters must preserve line counts; purely lexical, no structural equivalence                 |
| Equality tiers + normalization cache in folder compare         | Scales folder scans; `SameFiltered` distinguishes "same modulo noise"          | `DodgySame` (mtime-based) can lie on shallow mode; cache keyed on stats can miss ACL changes |
| VCS via CLI adapter classes                                    | Six VCSes supported with one small surface; easy to audit                      | Fork-per-query latency; no libgit2-style in-process access                                   |

## Sources

- Local checkout at `/home/petar/code/repos/python/meld`, revision
  `c0c9e4c491f76cb9eb7f69e9825684e22a27fb34` (2026-07-29): primarily
  `meld/matchers/myers.py`, `meld/matchers/diffutil.py`,
  `meld/matchers/merge.py`, `meld/matchers/helpers.py`, `meld/filediff.py`,
  `meld/linkmap.py`, `meld/chunkmap.py`, `meld/actiongutter.py`,
  `meld/gutterrendererchunk.py`, `meld/syncpoints.py`, `meld/filters.py`,
  `meld/misc.py`, `meld/meldbuffer.py`, `meld/dirdiff.py`,
  `meld/vcview.py`, `meld/vc/git.py`, `meld/vc/_vc.py`,
  `data/org.gnome.Meld.gschema.xml`, `README.md`, `NEWS`, `meson.build`.
- [Meld website][meld-site] — user documentation and feature overview.
- [Meld GitLab repository][meld-gitlab] — upstream source and issue tracker.
- Wu, Manber, Myers, Miller, _An O(NP) Sequence Comparison Algorithm_
  (1989) — cited in the `initialise` docstring of `meld/matchers/myers.py`.

<!-- References -->

[meld-site]: https://meldmerge.org/
[meld-gitlab]: https://gitlab.gnome.org/GNOME/meld
