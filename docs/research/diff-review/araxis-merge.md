# Araxis Merge (proprietary, Windows/macOS)

Araxis Merge is a long-lived commercial desktop GUI for two- and three-way text
comparison/merging, folder synchronization, and image/binary comparison — a
useful benchmark for the feature ceiling of a paid, native, general-purpose
visual differ.

| Field          | Value                                                                                                              |
| -------------- | ------------------------------------------------------------------------------------------------------------------ |
| Language       | Not published (closed source; native Windows + macOS applications with COM / AppleScript automation surfaces)      |
| License        | Commercial, per-user perpetual license in two editions (Standard, Professional); one license covers both platforms |
| Repository     | None (proprietary; no public source)                                                                               |
| Documentation  | [araxis.com/merge][home] — full per-platform manuals under `merge/windows/` and `merge/macos/`                     |
| Category       | gui-differ                                                                                                         |
| First release  | Not published; release notes document versions back to at least Merge 2012.4246 ([release notes][relnotes])        |
| Latest release | Merge 2026.0, 19 June 2026 ([release notes][relnotes])                                                             |

> [!NOTE]
> This survey is grounded entirely in the official Araxis documentation (mostly
> the Windows manual; the macOS manual is structured identically). Because the
> product is closed source, algorithm-level claims below are limited to what
> the vendor documents; where the docs are silent (notably the core diff
> algorithm), that silence is reported as a finding.

## Overview

### What it solves

Merge targets professionals who need to _see_ and _reconcile_ differences
across pairs or triples of files and whole folder hierarchies: developers
merging divergent branches, and also legal/publishing users comparing
documents — both editions can "directly open and compare text from Microsoft
Office (Word and Excel), OpenDocument, PDF and RTF files" ([features][features]).
The Professional Edition adds three-way file and folder comparison with
automatic merging; the Standard Edition is the same product restricted to
two-way operations ([features][features]).

Beyond text it ships three sibling comparison modes: folder trees (with
synchronization and archive support), images (pixel-level), and binary files
(byte-level with insert/remove alignment) — all reachable from one
application and one automation API.

### Design philosophy

The signature UI idea is the _linking line_: instead of forcing panes into
lock-step row alignment, Merge draws explicit connectors across the gap
between panes. From the file-comparison overview: "Linking lines connect
corresponding parts of the files, showing exactly how they are related"
([file comparison overview][overview]). The same mechanism carries the
three-way conflict story: "the linking lines connect the changes from the
derived files to the same section of the ancestor file"
([three-way comparison][threeway]).

The second pillar is that comparison panes are live editors, not read-only
views: "You can edit either file directly in-place. The file comparison
dynamically updates as you make changes" ([file comparison overview][overview]).
Merging is therefore editing — point-and-click block transfer plus free-form
typing, with unlimited undo — rather than a separate "resolve" mode.

## How it works

### 1. Diff computation & data model

- **Algorithm undocumented.** Nowhere in the manual does Araxis name the
  underlying diff algorithm (Myers, patience, histogram, …). The only
  algorithmic knobs exposed are heuristics _layered on top_ of the line diff.
  For a 30-year-old commercial product this is a deliberate stance: the
  algorithm is a black box; the _tuning surface_ is the product.
- **Line-level diff with a configurable pairing pass.** After block-level
  differences are found, a _line pairing_ stage decides which changed lines
  correspond. Three strategies are offered: _intelligent_ (default —
  "examines line contents using heuristics and line-pairing rules"),
  _consecutive_ (positional, content-blind), and _adaptive_ (consecutive when
  both sides have equal line counts, else intelligent)
  ([line pairing options][linepairing]). User-editable _line-pairing rules_
  (regexes) can steer which lines are considered pair candidates.
- **Intelligent block splitting.** An option makes Merge "endeavour to split
  multiline blocks of changed text into smaller blocks of inserted, removed,
  and changed text" based on matched line pairs — decomposing one opaque
  "changed" block into adjacent insert/remove/change runs
  ([line pairing options][linepairing]).
- **Computed in-process, not parsed from `git`.** Merge compares the files it
  is given (from disk, archives, SCM plugins, or Office/PDF text extraction);
  it never consumes patch/`git diff` output.
- **Non-text models.** The binary comparator computes a genuine byte-level
  alignment (inserts/removes, not just fixed-offset XOR), tunable via an
  _Effort_ control: "permitted range is `1` to `9999`; the default is `5` …
  Smaller effort values never miss a difference, but they may not provide an
  optimal set of changes" ([binary comparison][binary]) — i.e. effort buys a
  _smaller/better-aligned_ edit script, never correctness. The image
  comparator is pixel-difference based (no structural model).

### 2. Rendering & layout

- **Side-by-side only** — two or three vertical panes; there is no unified
  view for interactive comparison (unified/UNIX-diff output exists only as a
  _report_ format). Three-way layout deliberately places the common ancestor
  in the **centre** pane with derived versions on either side
  ([three-way comparison][threeway]).
- **Linking lines instead of row padding.** Panes scroll in sync, aligned "in
  the centre of the display", and connectors bridge corresponding blocks —
  so insertions do not force phantom blank rows into the opposite pane; the
  connector's slope conveys the size mismatch. (The binary view uses the same
  device: "Changes between the two files are highlighted with colours and
  faint linking lines" ([binary comparison][binary]).)
- **Overview strip.** A per-comparison summary strip marks every difference:
  "Each colour-coded mark on the strip represents a difference"
  ([file comparison overview][overview]).
- **Syntax highlighting** is built in "to help you better comprehend a wide
  range of source files" ([features][features]) and coexists with diff
  colouring (change state as background, syntax as foreground).
- **Merge affordances in the gutter**: per-block merge buttons copy a block to
  the other pane "replacing any corresponding block", with modifier keys for
  insert-before/after and delete variants ([file comparison overview][overview]).
- Since 2026.0, changed regions render with a "translucent version of the
  relevant inserted/removed/changed background colour" for legibility
  ([release notes][relnotes]).

### 3. Intra-line & noise handling

This is Merge's densest feature area — the commercial ceiling for
"unimportant difference" machinery:

- **Inline refinement** with two display granularities: _detailed_ highlights
  "every inserted, removed, or changed character or word"; _simple_ highlights
  from first to last changed character. A separate toggle switches between
  character-level and word-by-word inline comparison
  ([line pairing options][linepairing]).
- **Whitespace/case/EOL suppression** as independent toggles: ignore leading
  whitespace, trailing whitespace, "differences caused by the introduction of
  extra whitespace characters" (runs collapse), all whitespace, character
  case, and CR LF / LF / CR line-ending differences
  ([text comparison options][textopts]).
- **Line Expressions** — user regexes for unimportant text, in two forms:
  "force lines that contain a match … to be unchanged (that is, make Merge
  ignore those lines entirely when comparing files)", or ignore only the
  matching character sequences within a line
  ([line expressions][lineexpr]). Crucially, suppressed differences are
  **de-emphasized, not hidden**: "A line matched by the first type of line
  expression is shown using the fonts and colours you have configured for
  unchanged text", and only when _every_ line of a corresponding block
  matches are the linking lines removed and the change count decremented
  ([line expressions][lineexpr]). Canonical example: SCM keyword expansion
  such as Subversion's `$Date$`.
- **Block Expressions** — begin/end regex pairs that mark whole multi-line
  regions (e.g. auto-generated blocks) as ignorable
  ([block expressions][blockexpr]).
- **Column filtering** — ignore character columns by spec (`1-8,10,12,14,80-`),
  a punched-card-era feature that is effectively positional table-noise
  suppression for fixed-width data ([text comparison options][textopts]).
- **Numeric tolerance** — treat numbers as equal within an absolute and/or
  ratio tolerance ([text comparison options][textopts]) — semantic
  equivalence for one value domain, something almost no free differ offers.
- **No moved-code detection** is documented anywhere in the manual.

### 4. Navigation, folding & scale

- Previous/next-change buttons plus the clickable overview strip are the
  primary navigation; automatic merges add previous/next _conflict_
  navigation (Ctrl+9 / Ctrl+0) ([automatic merging][automerge]).
- **No collapsing of unchanged regions** in the file view is documented — the
  overview strip plus synchronized scrolling stands in for folding.
- **Scale is a headline claim**: the 64-bit build lets you "compare huge files
  (for example, 100 MB or larger)" using "the very large amounts of memory
  potentially available on modern 64-bit systems" ([features][features]);
  "Automatic Merging enables swift reconciliation of even the largest files"
  ([automatic merging][automerge]).
- Folder comparisons act as the multi-file shell: background colours encode
  per-row insert/remove/change/unchanged state, "the icon of the newest file
  in any given row is indicated by a red square adornment", wildcard
  exclusions prune the walk, byte-by-byte verification is optional, archives
  (`.zip`, `.tar`; `.rar`/`.7z` via 7-Zip) mount as folders, and file
  comparisons launch per row ([folder comparison][folders]).

### 5. VCS & review integration

- Merge is a **pluggable external tool, not a VCS client**: "Merge integrates
  with most version control (VC), software configuration management (SCM) and
  other applications that allow a third-party file comparison (diff) or file
  merging tool to be specified" ([SCM integration][scm]). Shipped shims
  include `Compare.exe`, `ConsoleCompare.exe`, `AraxisSVNDiff3.exe`,
  `araxisp4winmrg.exe`, etc., with documented recipes for Git (incl. WSL and
  Cygwin), Mercurial (Extdiff), Subversion, Perforce, and TFS.
- A Subversion **file-system plugin** lets Merge "browse Subversion depots
  directly" and populate version-history menus ([SCM integration][scm]) —
  repository browsing without a working copy.
- Three-way merge output convention: the resolved file _is_ the centre
  (ancestor) pane — "The central file panel will contain the resolved
  (merged) file" ([automatic merging][automerge]); left/right inputs are
  never modified. Conflicts get "a red conflict icon … at the beginning of
  each line within a change that could not be automatically merged", and
  "Because automatic merging can be undone, it is safe to try an automatic
  merge to see what it will do" ([automatic merging][automerge]).
- **No PR/review-platform features at all**: no comments, no review states,
  no GitHub/GitLab connectivity, no stacked-change model, no index/hunk
  staging. An integration wart is documented honestly: "The exit code from
  compare does not indicate whether the output file has been updated"
  ([SCM integration][scm]), which complicates IDE mergetool wiring.

### 6. Architecture & reuse

- **Closed, native, per-platform monolith** — a Windows application and a
  separate macOS application sharing feature set and manual structure but
  exposing platform-native automation: a COM Automation API on Windows,
  AppleScript on macOS ([features][features]).
- The COM object model is the reusable _shape_: a root `Application` object
  yields `TextComparison`, `BinaryComparison`, `ImageComparison`, and
  `FolderComparison` objects plus `Preferences`, `Encoding`, `Filter`, and
  `RegularExpression` support objects; usable from JScript, VBScript, VB,
  C#, C++ via early or late (`IDispatch`) binding
  ([automation API][autoapi]). File comparisons run synchronously; folder
  comparisons run asynchronously behind a `Busy` property /
  `ComparisonComplete` event ([automation API][autoapi]).
- Everything the GUI does — comparisons, option changes, printing, saving
  merged output, and HTML/XML/UNIX-diff **report generation** — is reachable
  headlessly through that API, which is what makes Merge scriptable in CI-ish
  pipelines despite being a GUI product.
- Nothing is reusable as a library: no diff engine is exported, no file
  format is documented beyond the report outputs. The exportable ideas are
  the UI mechanisms (linking lines, editable panes, ancestor-centre merge)
  and the noise-rule vocabulary (line/block expressions, column filters,
  numeric tolerance).

## Strengths

- The most complete documented "unimportant differences" toolkit surveyed:
  regex line/block expressions with de-emphasize-don't-hide rendering,
  column ignores, numeric tolerance, and layered whitespace/case/EOL toggles.
- Linking-line alignment avoids phantom padding rows and scales naturally to
  three panes; the same visual language covers text and binary modes.
- Panes are real editors: merge-by-click, merge-by-typing, unlimited undo,
  live re-diff — the merge result is always a plain saveable file.
- Ancestor-in-the-centre three-way model with previewable, fully undoable
  automatic merge and per-line conflict icons.
- Byte-level binary diff with a cost/quality _Effort_ dial, and pixel-level
  image compare with blend/isolate controls — one tool spans text, tree,
  image, and binary domains.
- Full automation surface (COM/AppleScript + CLI shims) over a GUI product,
  including headless report generation.

## Weaknesses

- Core diff algorithm entirely undocumented and unswappable; no
  patience/histogram-style user choice, and no moved-code detection.
- No unified interactive view; no collapsing of unchanged regions — large
  files rely on the overview strip alone.
- Zero review-platform awareness: no PRs, comments, revisions, or stacks;
  VCS integration is one-file-pair-at-a-time external-tool plumbing.
- Noise rules are regex/positional, not structural: nothing understands a
  markdown table, an AST, or formatter output as such.
- Closed source, paid, desktop-only (no Linux, no terminal, no web); the
  automation API is platform-specific (COM vs AppleScript) rather than one
  cross-platform surface.
- Documented exit-code gap (`compare` cannot signal "output updated") shows
  the limits of bolting a GUI onto scripted merge flows.

## Key design decisions and trade-offs

| Decision                                                                     | Rationale                                                                                 | Trade-off                                                                                    |
| ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Linking lines between panes instead of padded row alignment                  | Shows exactly how unequal-sized blocks correspond; generalizes to 3 panes and binary view | Costs horizontal gutter space; harder to skim than strictly row-aligned panes                |
| Comparison panes are live editors                                            | Merging = editing; unlimited undo makes every action reversible                           | Diff must re-run continuously; view state is mutable, complicating "what changed" provenance |
| Ancestor as the centre pane, resolved in place                               | Both derived diffs read outward from one reference; result is just a file to save         | Ancestor content is destroyed in the view; no separate 4th output pane                       |
| Regex-driven unimportance (line/block expressions), de-emphasized not hidden | Users keep visual ground truth while counts/navigation skip the noise                     | Regexes can't express structural equivalence (tables, ASTs); per-user config burden          |
| Diff algorithm hidden, heuristics (pairing, splitting, Effort) exposed       | Vendor can evolve internals; users tune outcomes, not algorithms                          | Impossible to reason about or reproduce results; no community verification                   |
| Platform-native automation (COM / AppleScript) over the GUI                  | Deep OS integration; every GUI capability scriptable, incl. headless reports              | Two divergent automation surfaces; nothing portable; no library-level reuse                  |
| One app spanning text/folder/image/binary                                    | Single purchase and UI language for all comparison domains                                | Breadth over depth: no structural/semantic text model, no review workflow                    |

## Sources

- [Araxis Merge product page][home] — positioning, feature summary
- [Features & edition comparison][features] — Standard vs Professional, syntax highlighting, Office/PDF, 64-bit scale claims
- [Instant overview of file comparison and merging][overview] — linking lines, in-place editing, merge buttons, overview strip
- [Three-way file comparison and merging][threeway] — ancestor-centre layout, conflict linking
- [Automatic file merging][automerge] — merge walk, conflict icons, undoable auto-merge, centre-pane result
- [Text comparison options][textopts] — whitespace/case/EOL toggles, column filtering, numeric tolerance
- [Line pairing options][linepairing] — intelligent/consecutive/adaptive pairing, block splitting, inline granularity
- [Line expressions][lineexpr] and [Block expressions][blockexpr] — regex unimportance rules and their rendering
- [Comparing folders][folders] — folder compare/sync, archives, filters
- [Comparing image files][images] — pixel diff modes, blend slider
- [Comparing binary files][binary] — byte alignment, Effort control
- [Automation API introduction][autoapi] — COM object model, sync/async, report generation
- [Integrating with source control and other applications][scm] — difftool/mergetool shims, SVN plugin, exit-code caveat
- [Release notes][relnotes] — Merge 2026.0 (19 June 2026)

<!-- References -->

[home]: https://www.araxis.com/merge/index.en
[features]: https://www.araxis.com/merge/features.en
[overview]: https://www.araxis.com/merge/documentation-windows/file-comparison-overview.en
[threeway]: https://www.araxis.com/merge/documentation-windows/three-way-file-comparison-and-merging.en
[automerge]: https://araxis.com/merge/documentation-windows/automatic-file-merging
[textopts]: https://www.araxis.com/merge/documentation-windows/dialog-options-text-comparisons.en
[linepairing]: https://www.araxis.com/merge/documentation-windows/dialog-options-text-comparisons-line-pairing.en
[lineexpr]: https://www.araxis.com/merge/windows/dialog-options-text-comparisons-expressions.en
[blockexpr]: https://www.araxis.com/merge/windows/dialog-options-text-comparisons-block-expressions.en
[folders]: https://www.araxis.com/merge/documentation-windows/comparing-folders.en
[images]: https://www.araxis.com/merge/documentation-windows/comparing-image-files.en
[binary]: https://www.araxis.com/merge/documentation-windows/comparing-binary-files.en
[autoapi]: https://www.araxis.com/merge/windows/automation-api-introduction.en
[scm]: https://www.araxis.com/merge/windows/integrating-with-other-applications.en
[relnotes]: https://www.araxis.com/merge/documentation-windows/release-notes.en
