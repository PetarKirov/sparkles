# diffoscope (Python)

A recursive, content-aware differ from the Debian Reproducible Builds project: it unpacks
archives/binaries/documents into trees of human-readable representations, diffs every leaf with GNU
`diff`, and renders the resulting difference tree to text, HTML, JSON, Markdown, or reStructuredText.

| Field             | Value                                                                                                           |
| ----------------- | --------------------------------------------------------------------------------------------------------------- |
| Language          | Python 3                                                                                                        |
| License           | GPL-3.0-or-later                                                                                                |
| Repository        | [salsa.debian.org/reproducible-builds/diffoscope][repo] (formerly Debian `anonscm`)                             |
| Documentation     | [diffoscope.org][site]                                                                                          |
| Category          | structural-diff (recursive container/binary differ, batch CLI — not interactive)                                |
| First release     | 2014 (as `debbindiff`; renamed diffoscope 2015)                                                                 |
| Latest release    | Actively released; the project uses monotonically increasing integer versions (this survey covers version `78`) |
| Surveyed revision | `dcfffcbb46685081b883d43ae9e4400ffa43c94c` (2017-02-26, tag "Release version 78")                               |

> [!NOTE]
> The surveyed checkout is the 2017 "version 78" release. diffoscope development continued after the
> 2017 move to `salsa.debian.org` (today's tree has far more comparators and a rewritten HTML
> presenter), but the architecture surveyed here — `ComparatorManager`, `specialize()`, the
> `Difference` tree, feeder/FIFO diffing, presenter visitors, and the truncation-budget `Config` —
> is the load-bearing core that later versions still build on.

## Overview

### What it solves

Reproducible-builds work constantly asks "why do two builds of the same package differ?" — where the
artifacts are `.deb`s, tarballs, ISO images, ELF binaries, or PDFs, and a byte-level `cmp` answer is
useless. diffoscope answers with a _tree of unified diffs_: it recognizes each file's format,
transforms it into the most readable representation available (archive member lists, `readelf`
section dumps, decompiled dex, pretty-printed JSON, `xxd` hexdumps as a last resort), recurses into
container members, and reports where in the nesting the difference actually lives. Exit codes (`0`
no differences, `1` differences, `2` error, per `main.py`) make it scriptable in CI.

### Design philosophy

From `README.rst`:

> "diffoscope will try to get to the bottom of what makes files or directories different. It will
> recursively unpack archives of many kinds and transform various binary formats into more human
> readable form to compare them. It can compare two tarballs, ISO images, or PDF just as easily."

Three commitments follow from that sentence and pervade the code:

- **Delegate, don't reimplement.** Format knowledge lives in ~50 external tools (`readelf`,
  `objdump`, `msgunfmt`, `pdftotext`, `sqlite3 .dump`, `apktool`, …) orchestrated as subprocesses;
  the 2017 tree's own diff engine is literally GNU `diff -aU7` (`diff.py`, `run_diff`).
- **Degrade, don't fail.** Every missing tool or crashed subprocess downgrades to a coarser
  comparison (ultimately an `xxd` hexdump) plus an explanatory comment attached to the output
  (`comparators/utils/file.py`, `File.compare`; `external_tools.py` even maps each tool to the
  Debian/Arch/FreeBSD package that provides it, surfaced as "Install 'foo' to get a better output").
- **Bound the output, not the input.** Because a nested tree of diffs over ISO images can be
  gigabytes, a `Config` singleton of size budgets (`config.py`) truncates at three distinct layers
  (diff capture, per-block rendering, whole-report size) with explicit "N lines removed" markers.

## How it works

### 1. Diff computation & data model

All leaf diffs are computed by shelling out to GNU **`diff -aU7`** (`diff.py`, `run_diff`) — there is
no in-process diff algorithm choice (Myers vs histogram etc. is whatever GNU diff does). The novelty
is _what gets diffed_ and _how the results compose_:

- **Feeders + FIFOs.** Each side of a comparison is a "feeder" closure that writes bytes into a named
  FIFO from a background thread (`diff.py`, `FIFOFeeder`), so `diff` consumes transformed content
  (a subprocess's stdout, a re-encoded text stream, a pretty-printed JSON dump) _streamingly_,
  without materializing temp files. `Difference.from_command(Klass, path1, path2)`
  (`difference.py`) runs one tool instance per side and diffs their stdouts; the
  human-readable command line (with the path replaced by `{}`) becomes the node's `source` label.
- **`Difference` tree.** The output data model is a recursive `Difference` node (`difference.py`):
  `source1`/`source2` labels, one optional `unified_diff` string, a list of free-text `comments`, a
  `has_internal_linenos` flag (set when the content carries its own offsets, e.g. `xxd`), and
  `details` — child `Difference`s. A `.changes` file thus yields a root node with children per
  member `.deb`, which have children per `data.tar`, per member file, per ELF section. The tree is
  presenter-agnostic; `get_reverse()` can flip an entire tree (using `reverse_unified_diff`, a
  textual `@@`-header/±-prefix swapper).
- **Capture-side truncation.** `DiffParser` (a small state machine over `diff`'s output:
  `read_headers` → `read_hunk` → `skip_block`) drops the middle of any same-direction run longer
  than `Config().max_diff_block_lines_saved`, writing a literal `-[ 1234 lines removed ]` /
  `+[ 1234 lines removed ]` pseudo-line into the stored diff. Feeders likewise cap input at
  `max_diff_input_lines` (default 2^20), replacing the overflow with
  `[ Too much input for diff (SHA1: …) ]` so equality beyond the cap is still detectable by hash.
- Granularity is **line-level** at capture time; character-level refinement happens only in the HTML
  presenter (§3).

### 2. Rendering & layout

Five presenters consume the same `Difference` tree (`presenters/formats.py` dispatches; several can
run in one invocation, e.g. `--text - --html out.html --json out.json`):

- **Text** (`presenters/text.py`): unified diff per node, nested by drawing a `│ ` prefix per depth
  level and `├── ` node headers — the tree structure _is_ the layout. Optional ANSI coloring is a
  three-color regex pass over `+`/`-`/`@` line prefixes (`diff.py`, `color_unified_diff`) — no
  syntax highlighting anywhere in the project.
- **HTML** (`presenters/html/html.py`, derived from `diff2html.py`): each node is a collapsible
  `<div class="difference">` header; each unified diff is re-parsed line-by-line and re-rendered as
  a **four-column side-by-side table** (line number + content per pane). Adjacent `-`/`+` runs are
  buffered (`empty_buffer`) and paired positionally row-by-row — row _i_ of the removed block aligns
  with row _i_ of the added block, the shorter side padded with empty cells. When
  `has_internal_linenos` is set (hexdumps), the line-number column is dropped and the content spans
  both columns. Whitespace is made visible (`·` for space, `»` for tab via `convert(ponct=1)`),
  control characters are escaped to `\xNN`, lines over 1024 chars are cut with a `✂` marker, and
  zero-width breakable spaces are injected every 20 characters so the table wraps instead of
  scrolling.
- **JSON** (`presenters/json.py`): the tree serialized verbatim (`source1/source2/comments/
unified_diff/differences[]`) — a machine-readable interchange form of the whole model in 47 lines.
- **Markdown / reStructuredText** (`presenters/markdown.py`, `restructuredtext.py`): headings by
  depth (`#` × depth), diffs as 4-space-indented code blocks — built for pasting into bug trackers.

All non-HTML presenters share a tiny `Presenter` visitor base class (depth-tracking pre-order walk,
`presenters/utils.py`).

### 3. Intra-line & noise handling

- **Character-level refinement, HTML only:** rows classified as "changed" run `linediff()`
  (`presenters/html/linediff.py`) — a full O(m·n) Levenshtein DP over the _characters_ of the two
  lines, marking edited runs with `\x01`/`\x02` sentinels that become `<del>`/`<ins>`. No word-level
  tokenization; cost 1 per char substitution, adjacent marks merged by a string replace. Guarded
  only by the 1024-char line cap.
- **Noise classification by canonicalization, comparator-side:** the most interesting pattern in the
  tree. `JSONFile.compare_details` (`comparators/json.py`) diffs _re-serialized_ JSON with sorted
  keys first; only if the canonical forms match does it diff with original key order and attach the
  comment **"ordering differences only"** — semantic change and formatting noise are separated into
  differently-labelled nodes. `TextFile.compare` (`comparators/text.py`, `order_only_difference`)
  does the analogous check at line granularity: if the multiset of added lines equals the multiset
  of removed lines, the whole diff is annotated "ordering differences only". Many comparators also
  install per-line `filter` hooks on feeders to strip known-noise before diffing (e.g. `tar.py`
  listing filters).
- **Whitespace:** no ignore-whitespace mode; instead whitespace is made _visible_ in HTML (§2) so a
  whitespace-only change is at least recognizable. No moved-code detection (the tlsh matching in §4
  is cross-file, not intra-file).

### 4. Navigation, folding & scale

diffoscope is batch, so "navigation" is a property of the HTML report:

- Every node header carries a `¶` **anchor** built from its path in the tree (`escape_anchor`), and a
  `[−]` **collapse control**; ~60 lines of jQuery (`presenters/html/templates.py`) implement
  show/hide per subtree, with shift-click recursing into children.
- **Three-layer output budget** (`config.py` + `presenters/utils.py` + `html.py`):
  1. capture: `max_diff_block_lines_saved` / `max_diff_input_lines` (§1);
  2. per-diff-block rendering: `max_diff_block_lines` (default 256) rows per table, after which a
     styled "Max diff block lines reached; N/M bytes (P%) of diff not shown." row is emitted
     (`DiffBlockLimitReached`);
  3. whole report: `create_limited_print_func` counts characters printed and raises
     `PrintLimitReached` at `max_report_size` (default 2000 KiB), which unwinds the visitor and
     appends "Max output size reached."
- **Pagination (`--html-dir`):** the multi-file presenter shows only the first
  `max_diff_block_lines_parent` (50) rows of a big diff inline on `index.html`, then _rotates_ the
  remaining rows into child pages `<md5>-1.html`, `-2.html`, … capped at `max_report_child_size`
  bytes each (`row_was_output` in `html.py`); the parent gets a "load diff (N pieces)" link that
  jQuery fetches and splices inline on click — on-demand context expansion, 2015-style.
- **Skip-early guards:** before any comparison, `has_same_content_as` short-circuits via size
  compare, direct read (≤64 KiB), or external `cmp -s` (`comparators/utils/file.py`); a `Progress`
  singleton streams completion percent to a TTY bar or, via `--status-fd`, as JSON lines to a parent
  process (`progress.py`).

### 5. VCS & review integration

Essentially none, by design: diffoscope compares two _paths_, not two revisions. It uses no git
plumbing (the only `git.py` is a comparator for `.git/index` files), has no staging/hunk selection,
no conflict handling, and no review-platform integration; the closest thing is `--status-fd` for
embedding in other tools and the Markdown/reST presenters aimed at bug-tracker paste. In the
reproducible-builds pipeline it is invoked _by_ CI, and services like `try.diffoscope.org` wrap it
as a web service. Absence here is a finding: the whole review workflow is delegated to whatever
hosts the reports.

### 6. Architecture & reuse

- **Comparator registry:** `ComparatorManager` (`comparators/__init__.py`) holds an _ordered_ tuple
  of ~50 dotted class names — order encodes priority (most specific first: `directory`, `missing`,
  `symlink`, Debian metadata, ELF sections, … down to generic `zip`). Each entry may list fallbacks
  (`('rpm.RpmFile', 'rpm_fallback.RpmFile')`): if importing the full comparator fails (missing
  Python binding), the degraded one loads instead — dependency-optionality at registry level.
- **`specialize()` — dynamic reclassification** (`comparators/utils/specialize.py`): a generic
  `FilesystemFile`/`ArchiveMember` is matched against each class's `RE_FILE_TYPE` (libmagic output),
  `RE_FILE_EXTENSION`, or custom `recognizes()`; on match, the object's `__class__` is _rewritten in
  place_ to a synthesized `type(cls.__name__, (cls, type(file)), {})` — the file keeps its
  container-member identity but gains format-specific behavior. Detection cost is bounded by
  memoized libmagic calls.
- **Container recursion:** `File.as_container` lazily instantiates the class's `CONTAINER_CLASS`;
  `Container.comparisons` (`comparators/utils/container.py`) pairs members by exact name first, then
  **fuzzy-matches leftovers with tlsh** locality-sensitive hashes (`fuzzy.py`, threshold 60,
  commented "Files similar despite different names (difference score: N)") — catching renamed files
  inside archives — then pairs the rest against `MissingFile('/dev/null')` when `--new-file` is on.
  `Archive`/`ArchiveMember` (`utils/archive.py`) add lazy member extraction into per-member temp
  dirs. Comparison of members recurses through the same top-level `compare_files`.
- **External-tool orchestration:** the `Command` base class (`utils/command.py`) spawns each tool
  with stdout streamed into the diff feeder, stderr drained on a thread and capped at 50 lines, an
  optional per-line `filter`, and early `terminate()` once the feeder saw enough input. `@tool_required('xxd')`
  decorates `cmdline()`; the decorator both registers the tool for `--list-tools` and converts a
  missing binary into a `RequiredToolNotFound` that the caller downgrades gracefully (§ philosophy).
- **Monolith-bound vs reusable:** the `Difference` tree + presenter visitors, the three-layer output
  budget, the registry-with-fallbacks, and canonicalize-then-diff comparators are clean, reusable
  ideas. The 2017 HTML presenter is not: it is module-global mutable state (`spl_print_func`,
  `spl_rows`, …) inherited from `diff2html.py`, single-threaded by construction. Singletons
  (`Config`, `ComparatorManager`, `ProgressManager` — all Borg-pattern shared `__dict__`s) make the
  process one-comparison-per-run.

## Strengths

- The **recursive `Difference` tree** is a genuinely better data model for "what changed" than a flat
  file list: it localizes a difference to `deb → data.tar → usr/bin/foo → .text section disassembly`.
- **Graceful degradation everywhere**: every missing tool, crash, or parse failure produces a coarser
  diff plus a comment telling the user what to install — the report never just dies.
- **Truncation is engineered, not an afterthought**: three independent budgets with explicit in-band
  markers ("N lines removed", "N/M bytes not shown", SHA1 of over-long input) and parent/child page
  rotation keep worst-case reports usable.
- **Canonicalize-then-diff comparators** ("ordering differences only") separate semantic change from
  formatting noise _and say so in the output_ instead of silently hiding either.
- tlsh **fuzzy member matching** pairs renamed files inside containers with a quantified score.
- Presenter fan-out from one tree: text/HTML/JSON/Markdown/reST in a single run; the JSON form makes
  the whole model scriptable.

## Weaknesses

- **No in-process diff engine**: dependency on GNU `diff` semantics and subprocess+FIFO plumbing per
  leaf; no algorithm choice, no word-level diff at capture time.
- Intra-line refinement is an **O(m·n) per-character DP in Python**, HTML-only, with sentinel-char
  in-band markup — slow and lossy (control chars sanitized to `.` before diffing).
- The 2017 **HTML presenter is global-mutable-state spaghetti** (module-level `spl_*` variables,
  page rotation via exceptions), and its jQuery on-demand loading requires a copied/symlinked jQuery.
- **Singletons throughout** (`Config`, `ComparatorManager`, `ProgressManager`) preclude library-style
  embedding or concurrent comparisons in one process.
- No syntax highlighting, no side-by-side alignment smarter than positional pairing of `-`/`+` runs,
  no moved-code detection, no interactivity beyond collapse/expand.
- Comparator matching mutates `__class__` at runtime — clever, but hostile to static reasoning and
  type checking.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                                  | Trade-off                                                                                      |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| Delegate format knowledge to ~50 external CLI tools              | Enormous format coverage for free; each tool is the format's reference implementation      | Runtime tool matrix; output-format drift breaks parsers; subprocess overhead per node          |
| Leaf diffs via GNU `diff -aU7` over FIFOs                        | Battle-tested hunking; streaming transformed content without temp files                    | No algorithm/granularity control; `diff` chokes on huge inputs (hence the 2^20-line input cap) |
| Recursive `Difference` tree as the single output model           | One traversal serves five presenters; nesting mirrors container structure                  | Whole tree held in memory; comments/diffs are strings, so presenters re-parse unified diffs    |
| Ordered comparator registry with per-entry fallback classes      | Priority = specificity; optional Python deps degrade instead of breaking startup           | Ordering is implicit global knowledge; adding a comparator means knowing where to insert it    |
| `specialize()` rewrites `file.__class__` on recognition          | Member objects keep container identity while gaining format behavior; zero copying         | Runtime metaclass tricks defeat static analysis; recognition runs libmagic on every file       |
| Three-layer size budgets with in-band truncation markers         | Bounded reports even for pathological inputs; markers keep line accounting consistent      | Presenters must re-parse `[ N lines removed ]` pseudo-lines; budget interplay is subtle        |
| tlsh fuzzy matching for unmatched container members              | Catches renames/rebuilds inside archives, with a numeric similarity score                  | Optional dependency; O(n·m) pairwise hashing; threshold 60 is a magic number                   |
| Canonicalize-then-diff with "ordering differences only" comments | Users see _that_ a change is formatting-only instead of it being hidden or drowning signal | Each format needs a hand-written canonicalizer; only ordering noise is modelled                |

## Sources

- Local checkout at `/home/petar/code/repos/python/diffoscope`, revision
  `dcfffcbb46685081b883d43ae9e4400ffa43c94c` (2017-02-26, "Release version 78") — primary; key files
  cited inline: `diffoscope/diff.py`, `diffoscope/difference.py`, `diffoscope/config.py`,
  `diffoscope/comparators/__init__.py`, `diffoscope/comparators/utils/{compare,container,archive,file,specialize,fuzzy,command}.py`,
  `diffoscope/comparators/{json,text,elf}.py`, `diffoscope/presenters/{utils,text,json,markdown,formats}.py`,
  `diffoscope/presenters/html/{html,linediff,templates}.py`, `diffoscope/{tools,external_tools,progress,main}.py`, `README.rst`.
- [diffoscope.org][site] — project homepage (tool list, changelog).
- [salsa.debian.org/reproducible-builds/diffoscope][repo] — current upstream repository.
- [reproducible-builds.org][rb] — the initiative diffoscope serves.

<!-- References -->

[site]: https://diffoscope.org/
[repo]: https://salsa.debian.org/reproducible-builds/diffoscope
[rb]: https://reproducible-builds.org/
