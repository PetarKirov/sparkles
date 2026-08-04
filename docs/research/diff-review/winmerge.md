# WinMerge (C++ / MFC, Windows)

The longest-lived open-source GUI differ on Windows (developed since 2000): a 2/3-way
file, folder, table, image, and web-page comparer built around a forked GNU
diffutils engine, with an unusually deep toolbox for declaring differences
_ignorable_ — regex line filters, regex substitution filters, comment filters,
prediffer plugins, and a dedicated table/CSV mode.

| Field             | Value                                                          |
| ----------------- | -------------------------------------------------------------- |
| Language          | C++ (MFC), C (diff engines), JScript/VBScript (`.sct` plugins) |
| License           | GPL-2.0-or-later (`LICENSE.md`)                                |
| Repository        | [github.com/WinMerge/winmerge][repo]                           |
| Documentation     | [manual.winmerge.org][manual]                                  |
| Category          | gui-differ                                                     |
| First release     | 2000 (SourceForge era; per `README.md`)                        |
| Latest release    | 2.16.58 (`Version.h`, `STRFILEVER "2.16.58.0"`)                |
| Surveyed revision | `e782ec813734dd548b61803bec8fa46653482d31` (2026-08-04)        |

## Overview

### What it solves

WinMerge is the default answer to "visual diff/merge on Windows without paying
for Beyond Compare": compare two or three files side by side, compare folder
trees recursively, resolve VCS conflict files, and copy differences between
panes with full editing (both panes are live editors, not read-only views).
Beyond plain text it compares binary files (via the bundled `frhed` hex
editor), images (via a separate `WinIMergeLib.dll` component), web pages (via
`WinWebDiffLib.dll` / WebView2), archives (7-Zip), and — notably for this
survey — delimited tables (CSV/TSV/DSV) in a column-aligned grid view.

### Design philosophy

From `README.md`:

> It compares files and folders and presents differences in a clear, visual
> format that is easy to understand and work with.

Two implementation-level convictions show up everywhere in the code. First,
_ignorable differences are still differences_: filters do not delete hunks,
they mark them `trivial` and the UI renders them in a distinct "ignored" color
(`OP_TRIVIAL` in `Src/DiffList.h`, `LF_TRIVIAL` in `Src/MergeLineFlags.h`).
Second, ignoring is conservative — from `CDiffWrapper::PostFilter` in
`Src/DiffWrapper.cpp`:

> Our strategy is that every line in both sides must match regexp before we
> mark difference as ignored.

## How it works

### 1. Diff computation & data model

WinMerge ships **two in-process diff engines** behind one edit-script type:

- A forked **GNU diffutils** (`Src/diffutils/src/analyze.c` — the classic
  Myers O(ND) bidirectional search with Eggert's `too_expensive` ≈ √N cutoff
  and the `SNAKE_LIMIT`/`heuristic` early-exit, per the header comment citing
  "An O(ND) Difference Algorithm and its Variations"). This is the
  `DIFF_ALGORITHM_DEFAULT` path (`diff_2_files`, called from
  `CDiffWrapper::Diff2Files` in `Src/DiffWrapper.cpp`).
- Git's **xdiff** (`Externals/xdiff`, bridged by
  `Src/xdiff_gnudiff_compat.cpp`), selected when the user picks `minimal`,
  `patience`, or `histogram` in the options (`enum DiffAlgorithm` in
  `Src/CompareOptions.h`). `make_xdl_flags` maps WinMerge options onto
  `XDF_*` flags, including two WinMerge-specific extensions to xdiff:
  `XDF_IGNORE_NUMBERS` and `XDF_NONE_DIFF` (a "treat everything as one diff"
  mode). `diff_2_buffers_xdiff` converts xdiff's output back into diffutils
  `struct change` chains, so everything downstream is engine-agnostic.

The raw engine output (`struct change` linked list, with WinMerge-added
`match0`/`match1` fields for moved blocks and a `trivial` flag) is translated
into a `DiffList` of `DIFFRANGE` records — per-hunk begin/end line numbers for
up to three panes plus an `OP_TYPE` (`OP_DIFF`, `OP_TRIVIAL`, `OP_1STONLY`,
`OP_2NDONLY`, `OP_3RDONLY`; `Src/DiffList.h`).

**3-way compare is composed from two pairwise diffs**, not a native 3-way
algorithm: `CDiffWrapper::RunFileDiff` diffs middle↔left (`diff10`) and
middle↔right (`diff12`), then `Make3wayDiff` (`Src/Diff3.h`, a header-only
template commented "It is almost the same as GNU diff3's algorithm") merges
overlapping blocks into 3-pane `DIFFRANGE`s, using a `Comp02Functor` to test
whether the outer panes' text is identical (to classify middle-only changes).

The diff runs on **temp-file snapshots** of the in-memory edit buffers: every
rescan saves each pane's buffer to a temp file and re-runs the file-level diff
(`RESCAN_TEMP_ERR` in `Src/MergeDoc.h`); an edit (re)starts a timer so the
document re-diffs shortly after typing pauses (`Src/MergeEditView.cpp`,
"(Re)start timer to rescan only when user edits text").

### 2. Rendering & layout

Side-by-side only (2 or 3 vertical panes; no unified view for files — unified
output exists only in the patch generator, `Src/PatchTool.cpp`). Each pane is
a full **CrystalEdit** editor (`Externals/crystaledit/editlib`), so rendering
inherits line numbers, word wrap, selection margin, and syntax highlighting.

Cross-pane row alignment uses **ghost lines**: `CGhostTextBuffer`
(`Src/GhostTextBuffer.h`) subclasses the editor buffer and maintains
`RealityBlock` runs mapping "apparent" (screen) lines to real lines, so blank
ghost rows pad the shorter side of a hunk and both panes scroll in lockstep.
Line background colors come from per-line flag bits stamped during rescan
(`Src/MergeLineFlags.h`: `LF_DIFF`, `LF_TRIVIAL`, `LF_MOVED`, `LF_GHOST`,
`LF_DIFF_1STONLY/2NDONLY/3RDONLY`).

Within a multi-line hunk, WinMerge does a second alignment pass:
`CMergeDoc::AdjustDiffBlocks` (`Src/MergeDocDiffSync.cpp`, "Code to layout
diff blocks, to find matching lines, and insert ghost lines") computes
word-level diffs across the hunk, derives a per-line-pair **match cost**
(`GetMatchCost`, documented as Levenshtein-style dissimilarity measured in
matched characters), then recursively picks the best-matching line pair and
splits the problem above/below it (`AdjustDiffBlock`) — producing a
`DiffMap` that decides which left line sits beside which right line and where
ghost rows go. A 3-way variant (`AdjustDiffBlocks3way`) builds a
virtual-line → real-line table per pane and re-fragments `DIFFRANGE`s by
ghost-pattern runs.

Syntax highlighting is per-pane via CrystalEdit's 46 hand-written line-based
parsers (`Externals/crystaledit/editlib/parsers/`, `ISyntaxParser` +
`SyntaxParserRegistry`) — and, since 2026, an optional **tree-sitter bridge**
(`Src/TreeSitterParser.cpp`): grammar DLLs and `<lang>-highlights.scm` query
files are loaded at runtime from a `TreeSitterGrammars` directory, the full
document is parsed to an AST, and captures are mapped to the editor's
`COLORINDEX` per-line color blocks.

**Table/CSV mode** is a rendering mode of the same text buffers, not a
separate document type. `CMergeDoc::MakeTablePropertiesByFileName`
(`Src/MergeDoc.cpp`) matches the filename against configurable CSV/TSV/DSV
file patterns (`OPT_CMP_CSV_FILEPATTERNS` etc.) to pick a delimiter and quote
character; `SetTableProperties` then flips each buffer into table editing
(`SetTableEditing(true)`), sets delimiter/enclosure, optionally re-joins
records whose quoted fields contain newlines (`JoinLinesForTableEditingMode`),
and — the key trick — **shares one column-width array across all panes**
(`ShareColumnWidths(*m_ptBuf[0])`, backed by
`m_pSharedTableProps->m_aColumnWidths` in
`Externals/crystaledit/editlib/ccrystaltextbuffer.h`). The editor draws each
record as a grid row with vertical column separators, so the same column lines
up in every pane regardless of field widths; the diff itself still runs on
raw record text.

### 3. Intra-line & noise handling

This is WinMerge's deepest subsystem — a five-layer ignore stack, applied at
different points in the pipeline:

1. **Engine-level flags** — case, whitespace amount/all, blank lines, EOL
   differences, and (unusual) **ignore numeric differences**
   (`m_bIgnoreNumbers`), supported natively in both engines (diffutils
   options; custom `XDF_IGNORE_NUMBERS` in the xdiff fork).
2. **Prediffer plugins** — COM automation plugins (`.sct` scriptlets or DLLs
   in `Plugins/`) that transform the temp-file text _before_ the engine runs:
   `IgnoreColumns`, `IgnoreFieldsComma`, `IgnoreFieldsTab`,
   `IgnoreLeadingLineNumbers`, `PrediffLineFilter` (user-regex scriptlet),
   `IgnoreCommentsC`. The display shows the original text; only the compare
   input is transformed (`PrediffingInfo` in `Src/DiffWrapper.h`).
3. **Line filters** — a user-managed list of Poco (PCRE-style) regexes
   (`Src/LineFiltersList.cpp`, `Src/FilterList.cpp`). Applied _after_ the
   diff in `CDiffWrapper::PostFilter` (`Src/DiffWrapper.cpp`): a hunk is
   downgraded to `trivial` only if **every line on both sides** matches a
   filter regex.
4. **Substitution filters** — pattern → replacement rewrites (regex or
   literal, per-item case/whole-word toggles; `Src/SubstitutionFiltersList.cpp`,
   applied via `SubstitutionList::Subst`). `PostFilter` applies them to both
   sides of a hunk, additionally strips whitespace/digits per the ignore
   options, and if the rewritten sides become equal the hunk goes `trivial`.
   When they are _partially_ equal, `PostFilter` **re-diffs the rewritten hunk
   text with xdiff** (`diff_2_buffers_xdiff`) and splits the original hunk,
   inserting `trivial` sub-hunks for the now-equal spans
   (`InsertTrivialChanges`) — so one real cell edit inside a reformatted block
   surfaces alone.
5. **Comment filters** — `PostFilter` can run the editor's syntax parser over
   both sides (`SyntaxParserHelper::GetCommentsFilteredText`) and compare
   comment-stripped text, marking comment-only hunks trivial
   (`m_filterCommentsLines`).

Intra-line refinement (`Src/stringdiffs.cpp`) is a separate engine from the
line diff: lines are split into words (whitespace + configurable break chars,
default `,.;:`), then compared with the **Wu–Manber–Myers O(NP) algorithm**
(`stringdiffs::onp`, cited in-source as "An O(NP) Sequence Comparison
Algorithm"). Guards: the word-level DP only runs below 20 480 words per side
(64-bit; 2 048 on 32-bit) — beyond that the whole range becomes one change —
and there is a 500 ms timeout constant. Word diffs can be refined to byte
level (`wordLevelToByteLevel`), and the same whitespace/number ignore options
are honored per word-edit during edit-script materialization. Word diffs also
feed pane alignment (§2) and the per-hunk "line diff" highlight
(`Src/MergeDocLineDiffs.cpp`).

**Moved-block detection** (`Src/MovedBlocks.cpp`, opt-in) runs inside
`diff_2_files` right after script construction. It reuses diffutils'
already-computed line-equivalence codes (`file_data.equivs`): all changed
lines are bucketed into equivalence groups; a group with exactly one line on
each side (`isPerfectMatch`) seeds a move, which is then extended up and down
while adjacent lines share equivalence groups and stay inside diff blocks.
Matched runs are **split out of their hunks** into separate `change` nodes
carrying `match0`/`match1` line numbers; the UI colors them `LF_MOVED` and the
location pane draws connector lines between the two halves
(`Src/LocationView.cpp`). In 3-way mode, `InsertMovedBlocks3Way`
(`Src/DiffWrapper.cpp`) re-fragments merged hunks around moved lines.

### 4. Navigation, folding & scale

Navigation is hunk-based: next/previous difference, first/last, "current
difference" selection that both panes highlight, plus per-pane bookmarks from
CrystalEdit. There is **no folding of unchanged regions** — both files are
always shown in full (WinMerge is an editor showing whole documents, not a
patch viewer), so context expansion is moot. The primary large-file aid is
the **location pane** (`Src/LocationView.cpp`): a full-height miniature map
drawing each pane as a colored bar of diff blocks with a visible-area
indicator and moved-block connector lines.

Folder compare is a separate document type (`Src/DirDoc.cpp`,
`Src/ComparisonResultFilterDlg.cpp` result filtering, report export via
`Src/DirCmpReport.cpp`). It scales through pluggable per-file compare
engines (`Src/CompareEngines/`): full-content diffutils compare, "quick
contents" byte compare (`ByteCompare`), `TimeSizeCompare`, `BinaryCompare`,
`ImageCompare`, `ExistenceCompare` — and runs multi-threaded
(`Src/DiffThread.h`, Poco threads with a collect/compare split and abortable
progress). File filters (`Filters/*.flt` masks and expression filters) prune
the tree before comparing.

Large-file guards on the text path are modest: the word-diff caps and timeout
(§3), the diffutils √N `too_expensive` heuristic, and rescan
suppression/timers — there is no virtualized rendering beyond what an MFC
editor control already does, and full-document tree-sitter parses run on the
UI thread's document load.

### 5. VCS & review integration

WinMerge deliberately stays a _tool invoked by_ VCS rather than a VCS client:
there is no git plumbing in-process. Integration points are:

- **Command line / external-difftool contract** (`Src/MergeCmdLineInfo.cpp`):
  2–3 paths, `/base`/`/mine`/`/theirs`-style usage via ordering, output path
  for saving merge results — the shape TortoiseGit/`git difftool` expect.
- **Conflict-file parsing** (`Src/ConflictFileParser.cpp`, code derived from
  TortoiseCVS): opens a single file containing `<<<<<<<`/`|||||||`/`>>>>>>>`
  markers and splits it into 2 or 3 panes (nested-conflict aware), turning a
  merge conflict into an ordinary 3-way compare with save-back.
- **Patch generation** (`Src/PatchTool.cpp`, `Src/PatchHTML.cpp`): normal,
  context, and unified diffs, plus standalone HTML compare reports.
- **Shell extension** (`ShellExtension/`) for Explorer context-menu compare.

There is no PR/review-platform integration, no comments, no staging or
hunk-level VCS apply (copying hunks between panes and saving is the merge
model), and no notion of revisions/stacks.

### 6. Architecture & reuse

A classic MFC document/view monolith (`CMergeDoc` + three `CMergeEditView`s;
`CDirDoc`; `CImgMergeFrame`; `CWebPageDiffFrame`) with clearly-cut engine
seams below the UI:

- `CDiffWrapper` (`Src/DiffWrapper.cpp`, ~1 900 lines) isolates _all_ diff
  policy: engine choice, options mapping, moved blocks, post-filters, 3-way
  composition. Both engines emit the same diffutils `struct change`, which is
  the system's real interchange format.
- The editor is a reusable library (CrystalEdit fork under
  `Externals/crystaledit` with its own `ISyntaxParser`/`ITextBuffer`
  interfaces); WinMerge subclasses it (`CGhostTextBuffer`,
  `CMergeEditView`) rather than patching it.
- Image and web-page compare are **separate binary components** loaded at
  runtime (`WinIMergeLib.dll` via `GetProcAddress` in `Src/ImgMergeFrm.cpp`,
  exposing an abstract `IImgMergeWindow` with block-size / color-distance
  threshold / insertion-deletion detection / overlay-blink knobs in
  `Src/WinIMergeLib.h`; similarly `WinWebDiffLib.dll`). They are developed in
  sibling repos (`Externals/winimerge`, `Externals/winwebdiff`) and usable
  outside WinMerge.
- The plugin system is Windows COM automation: `.sct` scriptlets and DLLs
  implementing prediffer / unpacker / editor-script events, including
  document unpackers that turn Excel/Word/PowerPoint files into comparable
  text (`Plugins/CompareMSExcelFiles.sct` et al.).
- Third-party engines are vendored under `Externals/`: git xdiff, 7-Zip,
  Poco (threads + PCRE regex), md4c, frhed, tree-sitter (+ grammars).

Reusable _ideas_ travel better than the code (GPL-2.0, MFC/Win32-bound): the
trivial-not-deleted ignore model, the post-diff re-diff of filtered text, the
equivalence-class moved-block pass, and the shared-column-width table view are
all portable designs; the concrete implementation is tightly coupled to MFC
and `tchar_t` Windows text handling.

## Strengths

- Deepest formatting-noise toolbox of any surveyed GUI differ: five distinct
  ignore layers (engine flags, prediffer plugins, line filters, substitution
  filters, comment filters) that compose, all rendering as visibly-ignored
  rather than hidden.
- `PostFilter`'s re-diff-after-rewrite (`InsertTrivialChanges`) splits hunks
  so real edits inside reformatted regions surface individually — precisely
  the "one cell changed, formatter realigned everything" case.
- Table mode treats delimited files as first-class: shared column widths
  across panes, quote-aware record joining, per-extension delimiter config —
  while keeping the proven line-diff underneath.
- Moved-block detection is cheap (reuses the diff engine's own equivalence
  hashes) and integrated end-to-end: split hunks, distinct color, location-
  pane connectors, 3-way aware.
- Engine pluralism behind one edit-script type: users can switch
  Myers/minimal/patience/histogram per the input's pathology without any
  downstream code caring.
- Everything is editable in place; the diff re-computes on an edit timer, so
  compare and merge are one activity.

## Weaknesses

- Windows-only by construction (MFC, COM plugins, `tchar_t`); nothing builds
  elsewhere, and the GPL-2.0 license limits code reuse regardless.
- No unified view, no collapsing of unchanged regions, no context-window
  model — full-document panes only, which does not scale visually to
  PR-sized multi-file review.
- No VCS awareness beyond being an external tool: no blame, no commit
  ranges, no review workflow.
- 3-way is synthesized from two pairwise diffs; alignment across three panes
  degrades when the pairwise hunks interleave badly (the
  `AdjustDiffBlocks3way` re-fragmentation is a patch over this, with
  assert-guarded edge cases).
- The word-level engine is separate from the line engine, with hard caps
  (20 480 words) and a 500 ms budget after which refinement silently degrades
  to whole-range highlight.
- Table mode aligns _rendering_, not _comparison_: the diff still sees raw
  record text, so a delimiter-count change or column reorder produces
  ordinary line noise (only the `IgnoreColumns`/`IgnoreFields*` prediffer
  plugins address columns, by deletion).

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                           | Trade-off                                                                                 |
| --------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Filters mark hunks `trivial` instead of deleting them                 | Users can always see that _something_ changed; ignoring stays auditable             | Ignored noise still occupies screen rows and diff counts need two totals                  |
| Post-diff filtering (re-diff rewritten hunk text)                     | Filters see whole-hunk context; partial matches split into real + trivial sub-hunks | Runs an extra xdiff per filtered hunk; filter cost scales with hunk count                 |
| Two vendored engines normalized to diffutils `struct change`          | Algorithm choice (Myers/patience/histogram) without touching consumers              | Carries a forked 1993-era C codebase with TLS globals alongside modern xdiff              |
| Moved detection from diffutils equivalence codes, perfect-match seeds | Near-free reuse of existing hashes; unambiguous seeds avoid false pairings          | Only unique-line moves seed blocks; duplicated lines (e.g. `}`) never start a move        |
| Ghost lines materialized in the text buffer (`CGhostTextBuffer`)      | Panes align by construction; editing, undo, and rendering all see one line space    | Real↔apparent mapping (`RealityBlock`) complicates every buffer operation and undo record |
| 3-way = merge of two pairwise diffs (`Make3wayDiff`)                  | Reuses the battle-tested 2-way engines; matches GNU diff3 semantics                 | No true 3-way LCS; interleaved hunks over-merge and need post-hoc re-splitting            |
| Table mode = view-layer grid over line diff, shared column widths     | CSV diffing with zero new diff machinery; panes stay column-aligned                 | Cell-level changes are not first-class; column insert/reorder defeats the line diff       |
| Image/web compare as runtime-loaded sibling DLL components            | Independent development and reuse; core app has no image/WebView2 deps              | `GetProcAddress` seams and version skew between app and component interfaces              |
| Plugins via Windows COM automation (`.sct` scriptlets)                | User-extensible prediff/unpack without recompiling; script-language freedom         | Windows-locked, security-sensitive, and slow per-file marshalling                         |

## Sources

- Local checkout at `/home/petar/code/repos/cpp/winmerge`, revision
  `e782ec813734dd548b61803bec8fa46653482d31` (2026-08-04) — primary; key files
  cited inline: `Src/diffutils/src/analyze.c`, `Src/xdiff_gnudiff_compat.cpp`,
  `Src/DiffWrapper.cpp`, `Src/MovedBlocks.cpp`, `Src/Diff3.h`,
  `Src/stringdiffs.cpp`, `Src/MergeDocDiffSync.cpp`, `Src/GhostTextBuffer.h`,
  `Src/MergeDoc.cpp`, `Src/TreeSitterParser.h`, `Src/WinIMergeLib.h`,
  `Externals/crystaledit/editlib/ccrystaltextbuffer.h`
- [WinMerge repository][repo] and [`README.md` at the surveyed revision][readme]
- [WinMerge manual][manual] (user-level documentation of filters, table
  compare, and plugins)

<!-- References -->

[repo]: https://github.com/WinMerge/winmerge
[readme]: https://github.com/WinMerge/winmerge/blob/e782ec813734dd548b61803bec8fa46653482d31/README.md
[manual]: https://manual.winmerge.org/
