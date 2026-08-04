# Beyond Compare (Delphi/Object Pascal, proprietary)

Commercial cross-platform GUI compare/merge/sync suite whose distinguishing ideas are
per-file-format _grammars_ that classify differences as important vs unimportant, a
column-aware Table Compare session with key/standard/unimportant column roles, and
user-selectable line-alignment algorithms with manual overrides.

| Field          | Value                                                                                                           |
| -------------- | --------------------------------------------------------------------------------------------------------------- |
| Language       | Object Pascal (Wikipedia categorizes it under "Software programmed in Pascal"); Qt 6 UI on Linux [wiki] [v5new] |
| License        | Proprietary, per-user commercial; Standard and Pro editions [editions]                                          |
| Repository     | None public (closed source)                                                                                     |
| Documentation  | [v5 help][v5help], [knowledge base][kb-unimportant], [What's New in v5][v5new]                                  |
| Category       | gui-differ (folder/text/table/hex/picture/registry compare + merge + sync)                                      |
| First release  | Mid-1990s (Scooter Software); exact date not stated in consulted sources                                        |
| Latest release | 5.2.5, released 2026-08-03 [wiki]; Windows, macOS, Linux [home]                                                 |

## Overview

### What it solves

Beyond Compare ("BC") is the archetypal commercial standalone differ: "a software
application used by developers, system administrators and others to compare, merge,
and synchronize data" [home]. Rather than being a text differ with extras bolted on,
it is a _session_ framework: each comparison type (Folder Compare, Folder Merge,
Folder Sync, Text Compare, Text Edit, Text Merge, Table Compare, Hex Compare,
Picture Compare, Media Compare, Registry Compare, Version Compare) is a session with
its own data model, alignment rules, and settings, all sharing one shell, one
important/unimportant color vocabulary (red = important, blue = unimportant), and
one scripting/automation layer [viewtable] [viewtext] [editions].

Two capabilities matter most for this survey:

- **Grammar-based unimportance** — every file format carries a lexer-like grammar
  whose elements (comments, strings, keywords, user-defined patterns) can be
  individually marked unimportant, so whole _classes_ of change (a timestamp line, a
  log level, a comment) are demoted to noise rather than being suppressed
  positionally [kb-unimportant] [importance].
- **Table Compare** — delimited/tabular data is compared _cell-by-cell_ after rows
  are aligned on user-designated key columns, with per-column importance, numeric
  and date tolerance, and column re-mapping between the two sides [viewtable]
  [tablecols] [colhandling].

### Design philosophy

The company tagline is blunt about the problem domain: "Change is inevitable, so
manage it with the best tools." [home] The design center is _classification over
suppression_: differences are never silently discarded by default — they are
colored as unimportant (blue) and remain visible until the user toggles
`View > Ignore Unimportant Differences`, at which point "differences that match
your element's definition" are "treated as matching text" [kb-unimportant]
[importance]. The KB article on unimportant text states the two-step model
explicitly: to ignore something you must first "define a new Grammar element (what
the text is), then mark it as unimportant" [kb-unimportant] — i.e. _naming_ the
text class is a prerequisite to demoting it, and importance is a per-session
decision layered over a reusable per-format grammar.

A second thread is _user control of alignment_: the alignment algorithm itself is a
session setting (Unaligned / Standard / Myers O(ND) / Patience), skew tolerance is a
number the user can turn up, and when the heuristics fail, "to manually align two
lines, right-click one line and pick `Align With` and then click the second line"
[alignment] [forum-align].

## How it works

### 1. Diff computation & data model

All comparison is computed in-process by the closed-source engine; nothing is parsed
from `git diff` output (VCS integration hands BC whole file revisions to compare —
see §5). For Text Compare, the line-alignment algorithm is user-selectable in
`Session Settings > Alignment` [alignment]:

- **Standard alignment** (default) — a proprietary divide-and-conquer scheme that
  aligns "by comparing successively smaller sections of each file. Parts of the
  alignment can be shown before the entire comparison is finished" [alignment] —
  i.e. it is _incremental/streaming_, chosen so huge files paint progressively.
- **Myers O(ND)** — "a common LCS (Longest Common Subsequence) algorithm. This can
  give better matches in certain cases, such as large inserts or when the files
  contain a lot of repeating text", but "processes all data simultaneously", is
  slower on large scans, cannot display until complete, and "lacks similarity
  comparison support, grouping mismatches in blocks" [alignment].
- **Patience Diff** — "Bram Cohen's algorithm" [alignment].
- **Unaligned** — positional row-by-row comparison with no content alignment.

Two knobs modify whichever algorithm runs: **skew tolerance** — "the maximum number
of lines that the algorithm will check when looking for a match to a particular
line" (raise it for files with large displaced blocks, at comparison-time cost)
[alignment] — and **closeness matching**, which will "attempt to align the
remaining mismatched lines based on their similarity" so a changed line pairs with
its counterpart instead of rendering as delete+insert [alignment]. A `Never align
differences` option does the opposite: it shows "lines with important differences
as blocks of added and deleted text rather than changed text" [alignment].

Granularity is line-level alignment plus within-line (character-range) refinement
rendered in the editor panes and in a per-line "detail" strip (§2). Table Compare
replaces line alignment entirely with a relational model: rows are records, aligned
by key-column equality (optionally after sorting both sides), and compared
cell-by-cell [viewtable]. There is no AST-level structural diffing; the structural
awareness lives in the grammar layer (token classification, §3) and in the
specialized sessions (Table, Registry, Version Compare's PE-resource tree
[forum-version]).

### 2. Rendering & layout

Text Compare shows "side-by-side or over-under layout" with two editor panes that
"scroll together" [viewtext]. Coloring: "red to flag important differences
(insertions, deletions, and changes) and blue for unimportant differences"; a
"light red background indicates an important difference somewhere on the line,
while light blue indicates an unimportant difference" — the same convention in
Table Compare's grid [viewtext] [viewdata]. Syntax highlighting comes from the same
per-format grammar that drives importance (§3), so the lexer is shared between
colorizing and noise classification.

Navigation aids: a thumbnail map on the left edge renders "each line of the
comparison as a colored line, one pixel high", with "the white rectangle
represent[ing] the main display's current view" [viewtext] — a minimap of the
diff, not of the text. Below the panes, a **detail strip** shows "the current line
from each file … using the entire width of the window", with text, hex, and
character-alignment detail modes; the panes are full editors, so differences can be
reconciled by typing in place [viewtext]. BC5 added word wrap in Text Compare/Edit
and light/dark modes [v5new]. Table Compare renders "two grids that scroll
together" (side-by-side or stacked), and the grid shows _comparison columns_ — "not
necessarily the columns as they are organized in the data files" — an explicit
mapping layer between file layout and displayed comparison (§3) [viewtable]
[tablecols].

### 3. Intra-line & noise handling

This is BC's signature area, split across three mechanisms:

**Grammar elements + importance.** Each file format has a `Grammar` tab defining
lexer elements; five element types exist: **Basic** ("Match on a specific section
of text. Can be represented as a regular expression"), **Delimited** ("Match on a
beginning point of text and an end point of text. Can stop at end of line"),
**List** ("A list of basic matches"), **Columns** ("A text section defined at a
numerical beginning position in a line and an end position"), and **Lines** ("Match
a beginning point of text or the first line and end a user-defined number of lines
down") [kb-unimportant]. In a session's `Importance` tab, "Checked Items are
important. Unchecked items are unimportant" [importance]; whitespace is
pre-factored into three separately toggleable elements (leading, embedded,
trailing), plus `Character case` and `Compare line endings (PC/Mac/Unix)` (line
endings ignored by default), and an "Everything else" bucket for non-grammar text
[importance]. An `Orphan lines are always important` checkbox re-promotes an
inserted blank line (or a line containing only unimportant text) to an important
difference [importance] — the tool acknowledges that an _added_ noise-only line is
different in kind from a _changed_ noise span.

**Ignore vs demote.** Unimportant differences stay visible (blue) until
`View > Ignore Unimportant Differences` treats them as matches [kb-unimportant].
The classification (grammar) is stored per file format; the importance decision is
per session type.

**Pro-only text replacements.** The Pro edition adds a rule that "specifies text as
unimportant if it is changed to a specific value on the other side" [editions] — a
_paired_ rewrite rule (e.g. an intentional rename `foo → bar` becomes unimportant)
rather than a one-sided pattern.

**Table Compare's column-role model** is the tabular analogue. Columns take one of
three roles — **Key**, **Standard** (important), or **Unimportant** — settable by
right-clicking the column header or via `Session Settings > Columns`
[forum-columns] [tablecols]. Keys drive row alignment: "Define as many columns as
keys as necessary to uniquely identify each row"; "If multiple keys are defined,
precedence follows the order in the comparison" [tablecols]. By default BC "sorts
your files before comparing them and aligns rows with matching key columns"; an
unsorted mode "will not sort the files, but will still align rows with matching
keys" [viewdata]. Per-column handling (double-click the column line) adds a type
(`Detected, Boolean, Date, Numeric, Text`), **numeric tolerance** and **date
tolerance** (differ by up to the given amount before being important), and
per-column case/whitespace insensitivity for text columns [colhandling]. Column
_mapping_ between sides is itself configurable: unaligned (file order), align by
left/right name, or fully manual custom alignment with move-up/down [tablecols].
BC5 extended input formats to multiple Excel sheets and multiple HTML tables per
file [v5new]. There is no moved-code (cross-hunk relocation) detection in Text
Compare in the consulted documentation — sorted-key alignment in Table Compare is
the closest analogue (a moved _row_ is a non-event by construction).

### 4. Navigation, folding & scale

Difference-centric navigation: next/previous difference commands, the pixel-per-line
thumbnail minimap for jump-to-region [viewtext], and display filters to show
differences only or differences with context (the classic BC "Just show me what
changed" workflow). The Standard alignment algorithm is explicitly designed for
scale — progressive display before the full comparison finishes [alignment] — and
the docs warn that Myers trades that away ("larger scans slower", no display until
completion) [alignment]. Skew tolerance bounds the search window per line, making
worst-case cost a user-visible dial [alignment]. Folder Compare handles the
multi-file dimension: a tree of both sides with per-file comparison status,
launched into per-file sessions on demand — file-content comparison is lazy, not
up-front.

### 5. VCS & review integration

BC is a _difftool_, not a review platform. The supported model is git (or any VCS)
handing it file pairs/triples: `git config --global diff.tool bc` /
`merge.tool bc` with `bcomp` as the configured path; the shipped command-line
launchers distinguish `bcomp` (waits for the session to close — required for
difftool protocols) from `bcompare` (returns immediately) [kb-vcs]. The Pro
edition's "source control integration" adds VCS commands inside BC (Windows only)
[editions]. Merge is a first-class session: Text Merge does "two- and three-way
text merging … compar[ing] independent changes against a common ancestor to create
new merged content, for folders or individual files" (Pro) [editions], and BC5's
Text Merge "allows manually aligning multiline selections" [v5new]. There is no
concept of PR review, comments, revisions, or stacked changes — BC predates and
sits below that layer; it is the pluggable pairwise viewer such platforms shell out
to.

### 6. Architecture & reuse

Closed-source monolith: a native Object Pascal application (Qt 6 on Linux as of
BC 5.2) [wiki] [v5new], with all engines in-process. Nothing is reusable as a
library. What _is_ reusable is the design vocabulary:

- The **session** abstraction — one shell, N typed comparison views sharing color
  semantics and settings machinery.
- The **grammar → importance** split: one per-format lexer feeding both syntax
  highlighting and noise classification, with importance as a separate,
  per-session checklist over grammar elements.
- The **Key/Standard/Unimportant** column-role triple with per-column tolerance,
  and comparison-columns-as-a-mapping-layer distinct from file columns.
- The **algorithm-as-a-setting** stance (Standard/Myers/Patience + skew tolerance +
  closeness matching) plus manual `Align With` overrides as the escape hatch.
- The `bcomp`-waits / `bcompare`-detaches launcher split for difftool protocol
  compliance [kb-vcs].

Scripting/automation (batch reports, folder syncs) is built over the same sessions,
so the interactive and headless paths share one engine.

## Strengths

- The grammar/importance model is the most complete "formatting-noise" story of any
  surveyed differ: noise classes are _named_, reusable per format, demoted (blue)
  before being hidden, and re-promotable per session [kb-unimportant] [importance].
- Table Compare solves table diffing _relationally_ — key-aligned, cell-scoped,
  tolerance-aware — instead of treating tables as text, so row reordering and
  cosmetic realignment are non-events [viewdata] [colhandling].
- Alignment is inspectable and overridable at three levels: algorithm choice, skew
  tolerance dial, and manual `Align With` [alignment] [forum-align].
- `Orphan lines are always important` shows unusual care about a subtle
  classification corner (noise-only _insertions_ vs noise _changes_) [importance].
- Progressive display from the Standard aligner keeps huge comparisons interactive
  [alignment].
- Twelve session types under one consistent red/blue important/unimportant
  vocabulary lower the cost of learning each new view [viewtext] [viewdata].

## Weaknesses

- Closed source: none of the engines (aligner, grammar system, table model) can be
  reused, studied, or embedded; findings here rest on documentation only.
- No structural/AST diffing — grammars are lexical (regex/delimiter/position), so
  they cannot express "this change is a re-wrap of the same sentence" or match
  nested syntax [kb-unimportant].
- No review-platform layer: no comments, no revision stacks, no PR model; BC ends
  where review begins.
- Grammar authoring is manual GUI work per format; there is no ecosystem of
  shareable community grammars comparable to tree-sitter's.
- Key Pro features gate exactly the interesting bits (3-way merge, replacements,
  alignment overrides for folders, VCS commands) [editions].
- Table Compare requires the user to know and configure keys; there is no automatic
  key inference documented.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                 | Trade-off                                                                                       |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Classify noise (blue) before hiding it (`Ignore Unimportant`)     | Users can audit what the tool is about to disregard                                       | Two-step mental model; a mis-authored grammar silently demotes real changes once ignoring is on |
| Grammar elements shared by highlighting and importance            | One lexer to maintain; noise rules inherit the format's token structure                   | Lexical only — no cross-line or syntactic structure; regex-authoring burden on the user         |
| Table rows aligned by user-declared key columns (sort-then-align) | Row moves/reorders become non-diffs; cell-scoped changes are precise                      | Needs unique keys; misdeclared keys mis-pair rows; no automatic inference                       |
| Alignment algorithm is a user-facing setting                      | Different file shapes (repetitive text, big inserts) genuinely favor different algorithms | Users must understand Myers vs Patience vs "Standard"; default remains proprietary              |
| Proprietary "Standard" aligner with progressive display           | Huge files paint before the comparison completes                                          | Unpublished algorithm; behavior can't be reproduced or verified externally                      |
| Manual `Align With` / alignment overrides as escape hatch         | Heuristics always fail somewhere; the user has final say                                  | Per-session manual state; overrides don't generalize into rules                                 |
| One shell, many typed sessions                                    | Consistent UX and settings machinery across 12 comparison types                           | Monolithic app; no embeddable components                                                        |
| `bcomp` (blocking) vs `bcompare` (detaching) launchers            | Difftool protocols need a blocking process; humans want a detached GUI                    | Two binaries to explain; classic source of difftool misconfiguration                            |

## Sources

- Scooter Software homepage — product positioning, platforms, current version [home]
- Table Compare Overview (v4 help; v5 equivalent `viewtable.html`) — grids, key alignment, sorted/unsorted modes [viewdata] [viewtable]
- Table Compare Column Settings (v5 help) — comparison columns, key precedence, column alignment modes [tablecols]
- Editing a Column Definition (v4 help) — column types, numeric/date tolerance, per-column case/whitespace [colhandling]
- Define Unimportant Text (KB) — grammar element types, two-step define-then-demote workflow [kb-unimportant]
- Text Compare Importance Settings (v5 help) — importance checklist, whitespace split, orphan lines, line endings [importance]
- Text Compare Alignment Settings (v5 help) — Unaligned/Standard/Myers/Patience, skew tolerance, closeness matching [alignment]
- Text Compare Overview (v5 help) — panes, thumbnail, detail strip, red/blue coloring [viewtext]
- Standard vs Pro Editions (v5 help) — Pro feature list verbatim [editions]
- Using Beyond Compare with Version Control Systems (KB) — difftool/mergetool wiring, `bcomp` vs `bcompare` [kb-vcs]
- What's New in Version 5 — Qt, dark mode, word wrap, Table Compare Excel/HTML, merge alignment [v5new]
- Scooter forums — column-role how-to, `Align With`, Version Compare PE tree [forum-columns] [forum-align] [forum-version]
- Wikipedia: Beyond Compare — language category, release data [wiki]

<!-- References -->

[home]: https://www.scootersoftware.com/
[viewdata]: https://www.scootersoftware.com/v4help/viewdata.html
[viewtable]: https://www.scootersoftware.com/v5help/viewtable.html
[tablecols]: https://www.scootersoftware.com/v5help/sessiontablecolumns.html
[colhandling]: https://www.scootersoftware.com/v4help/dlgdatacolhandling.html
[kb-unimportant]: https://www.scootersoftware.com/kb/unimportantv3
[importance]: https://www.scootersoftware.com/v5help/sessiontextimportance.html
[alignment]: https://www.scootersoftware.com/v5help/sessiontextalignment.html
[viewtext]: https://www.scootersoftware.com/v5help/viewtext.html
[editions]: https://www.scootersoftware.com/v5help/standard_vs_pro.html
[kb-vcs]: https://www.scootersoftware.com/kb/vcs
[v5new]: https://www.scootersoftware.com/home/v5whatsnew
[forum-columns]: https://forum.scootersoftware.com/forum/beyond-compare-4-discussion/general/85667-how-to-ignore-the-differences-of-lines-in-table-compare
[forum-align]: https://forum.scootersoftware.com/forum/beyond-compare-4-discussion/general/91402-alignment-override-help
[forum-version]: https://forum.scootersoftware.com/forum/beyond-compare-4-discussion/general/13973-exe-comparison
[wiki]: https://en.wikipedia.org/wiki/Beyond_Compare
