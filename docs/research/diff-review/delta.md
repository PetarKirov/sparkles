# delta (Rust)

The canonical syntax-highlighting pager for `git`/`diff`/`grep`/`blame` output: a line-oriented state machine that re-parses git's text output from stdin, re-infers intra-line edits with its own alignment algorithm, and re-emits styled ANSI through `less`.

| Field             | Value                                                                      |
| ----------------- | -------------------------------------------------------------------------- |
| Language          | Rust                                                                       |
| License           | MIT                                                                        |
| Repository        | [dandavison/delta][repo]                                                   |
| Documentation     | [dandavison.github.io/delta][manual], `ARCHITECTURE.md` in the source tree |
| Category          | terminal-differ (pipe-through pager, not interactive TUI)                  |
| First release     | `0.0.1`, 2019-07-16 (git tag date)                                         |
| Latest release    | `0.19.2`, 2026-03-28 (git tag date)                                        |
| Surveyed revision | `95a0e224f55ccfdf3a7d1278fdea98a3edb9fbf4` (2026-07-30)                    |

## Overview

### What it solves

Raw `git diff` output is monochrome-per-line: whole lines are red or green, with no syntax highlighting, no word-level emphasis, and fixed layout. delta sits between git and the pager (`core.pager = delta` in `.gitconfig`) and rewrites that byte stream into a richly styled rendering — syntax-highlighted code, within-line edit emphasis, line-number gutters, optional side-by-side panels, OSC 8 hyperlinks, and styled merge-conflict blocks — while remaining a pure filter: stdin in, ANSI out, `less` underneath. The same state machine also restyles `git blame`, `git grep`/ripgrep, `git show`, submodule and diff-stat sections, and `diff -u` output from arbitrary tools.

### Design philosophy

Stay a _text-stream transformer_, not a git client. From `manual/src/introduction.md`:

> "Code evolves, and we all spend time studying diffs. Delta aims to make this both efficient and enjoyable: it allows you to make extensive changes to the layout and styling of diffs, as well as allowing you to stay arbitrarily close to the default git/diff output."

And from `ARCHITECTURE.md`:

> "The purpose of delta is to transform input received from git, diff, git blame, grep, etc to produce visually appealing output, including by syntax highlighting code."

The corollary is that delta never computes a file-level diff itself (except in the `delta file1 file2` convenience mode, which shells out to `git diff --no-index`): everything it knows, it recovers by parsing git's human-readable output — including reverse-engineering which minus line corresponds to which plus line.

## How it works

### 1. Diff computation & data model

delta **parses, it does not diff** — with one two-level exception. The outer loop (`src/delta.rs`) wraps a `StateMachine` whose `State` enum names semantic sections of git output: `CommitMeta`, `DiffHeader(DiffType)`, `HunkHeader(..)`, `HunkMinus`/`HunkZero`/`HunkPlus` (each carrying a `DiffType::Unified | Combined(MergeParents, InMergeConflict)`), plus `MergeConflict`, `SubmoduleLog`, `Blame`, `Grep`, `GitShowFile`. Each input line runs through an ordered chain of ~17 `handle_*` predicates (`handle_commit_meta_header_line() || handle_diff_stat_line() || … || emit_line_unchanged()`), each returning whether it consumed the line. `detect_source()` distinguishes `git diff` from plain `diff -u` streams by the first line's shape.

The exception is **line pairing and intra-line edit inference**, which delta computes in-process because git's output does not contain it:

- Consecutive minus/plus lines are buffered (`Painter::minus_lines`/`plus_lines`, flushed per "subhunk" — a maximal run of `-` then `+` lines — or when `--line-buffer-size` (default 32) overflows, `src/handlers/hunk.rs`).
- `edits::infer_edits()` (`src/edits.rs`) greedily pairs each minus line with a candidate plus line by computing a token-level alignment and accepting the pair if the normalized Levenshtein distance is below `--max-line-distance` (default `0.6`), or below `--max-line-distance-for-naively-paired-lines` when the minus/plus counts are equal (a "probably just edited in place" heuristic).
- The alignment itself (`src/align.rs`) is a hand-rolled **Needleman-Wunsch / Wagner-Fischer** dynamic program over _tokens_, not characters: `tokenize()` splits each line by `--word-diff-regex` (default `\w+`), with inter-token separators exploded into single graphemes. Cost constants (`DELETION_COST = INSERTION_COST = 2`, `INITIAL_MISMATCH_PENALTY = 1`) plus a deliberate candidate ordering bias the traceback toward _grouped_ runs of insertions/deletions rather than interleaved noise (documented inline: "Consider insertions and deletions before matches in order to group changes together").

> [!NOTE]
> delta does **not** use the `similar` crate (it appears in the tree only as a transitive dev-dependency of the `insta` snapshot-test framework). The word-level engine is entirely `align.rs` + `edits.rs`, ~1,470 lines including tests.

The output model is an _annotated line_: `Vec<(EditOperation, &str)>` where the `&str` slices point into the original line and concatenate back to it, plus a `line_alignment: Vec<(Option<usize>, Option<usize>)>` recording which minus row pairs with which plus row — the exact structure a side-by-side layout needs.

### 2. Rendering & layout

Two orthogonal per-line style streams are computed and then merged: syntect **syntax sections** (foreground) and delta **diff sections** (background + emph). `superimpose_style_sections()` (`src/paint.rs`) explodes both into per-`char` pairs, zips them, and run-length coalesces the result — an O(line length) but conceptually clean "style compositor". A `Style` whose `is_syntax_highlighted` flag is set takes its foreground from syntect and its background from the diff role (`minus_style`, `minus_emph_style`, `minus_non_emph_style`, and the plus/zero equivalents).

Syntax highlighting is syntect (`HighlightLines`) over bat's asset bundle; language selection is by filename/extension from the diff header (`Painter::get_syntax`), with `--default-language` fallback. Lines longer than `--max-syntax-length` are only partially highlighted; input lines are hard-truncated at `--max-line-length` (default 3000) except hunk headers and ripgrep JSON.

Layout features:

- **Line numbers** (`src/features/line_numbers.rs`): a two-column gutter driven by format strings (`--line-numbers-left-format` default `{nm:^4}⋮`, right `{np:^4}│`) parsed by a small placeholder engine (`src/format.rs`) supporting alignment/width specs — the gutter is templated text, not hardcoded columns.
- **Side-by-side** (`src/features/side_by_side.rs`): the terminal is split into two fixed-width `Panel`s (half of `--width` or the detected width). The `line_alignment` from edit inference drives row emission: each `(Some(i), Some(j))` pair renders minus line _i_ in the left panel and plus line _j_ in the right on the same row; unpaired lines get an empty opposite panel. Because ANSI clear-to-EOL cannot right-fill a _left_ panel, the left panel pads with literal spaces while the right may use the ANSI sequence (`BgFillMethod::TryAnsiSequence` vs `Spaces`).
- **Wrapping** (`src/wrapping.rs`, ~1,200 lines): long lines in side-by-side mode are wrapped up to `--wrap-max-lines` (default 2) with continuation symbols (`↵`, `↴`), _re-splitting both style-section streams_ and synthesizing `HunkMinusWrapped`/`HunkPlusWrapped` states so line numbers are not double-incremented; beyond the limit, lines are truncated with a right-aligned tail. Unified mode never wraps (the terminal does).
- Decorations (`src/handlers/draw.rs`): commit/file/hunk headers get configurable `box`/`ul`/`ol` border drawing via style strings like `file-decoration-style = bold yellow ul`.

### 3. Intra-line & noise handling

The emph model distinguishes **three** style roles per changed line, not two: `minus_emph_style` for tokens the alignment marked as edited, `minus_non_emph_style` for the unchanged remainder _of a paired line_, and plain `minus_style` for unpaired lines (`update_diff_style_sections()` in `src/paint.rs`, gated on `lines_have_homolog`). This means a whole-line rewrite reads differently from a one-token tweak — precisely the property that separates "real change" from re-alignment noise visually.

Additional noise-relevant mechanics:

- Whitespace-only aligned sections between an emph run on both sides are _coalesced into the emph run_ (`annotate()` in `src/edits.rs`), so `foo bar` → `baz qux` reads as one emphasized span, not two islands.
- Distance normalization ignores leading/trailing whitespace (`distance_contribution()` trims), so re-indentation alone does not defeat line pairing.
- Trailing-whitespace errors get a dedicated `whitespace-error-style` on added lines.
- The tokenization regex is user-configurable: the `--word-diff-regex` help text explicitly documents `\S+` + `--max-line-distance 1.0` as a coarser, `git --word-diff`-like mode.
- **Moved-code detection is delegated to git**: with `--color-moved` upstream and `inspect-raw-lines = true` (default), delta parses the ANSI styles git already painted on the raw line (`parse_style_sections()`), and `--map-styles` lets users remap those colors into delta styles — delta itself never searches for moved blocks.
- There is **no formatting-noise classifier or ignore-whitespace mode inside delta** — `-w`/`-b` style suppression must be requested from git; delta then simply never sees the suppressed hunks.

### 4. Navigation, folding & scale

delta is a one-pass filter, so "navigation" is outsourced to the pager. `--navigate` (`src/features/navigate.rs`) works by a genuinely cute hack: delta labels file headers and hunks with sentinel glyphs (`Δ`, `•`), builds a regex matching those labels, and **prepends that regex as the most recent search entry in a private copy of the user's `less` history file** — so `n`/`N` inside `less` jump between diff sections without polluting real history and without `less --pattern`'s side effects. There is no folding, no context expansion, and no file tree — the input stream is all delta will ever know.

Scale guards are streaming-oriented: the 32-line minus/plus buffer bound (a large pure insertion/deletion paints incrementally instead of buffering the file), `--max-line-length` truncation, `--max-syntax-length` highlight cutoff, and a deliberately quadratic-but-token-bounded alignment (the DP table is per line pair, and pairing is greedy with early accept). The calling-process probe runs in a background thread started first thing in `main()` because enumerating processes costs ~50 ms on Linux (`src/main.rs`).

### 5. VCS & review integration

No libgit2 object access in the hot path — `git2` is used only to _read_ `.gitconfig` (`src/git_config/`), which doubles as delta's own config store. Integration is textual and environmental:

- **Calling-process detection** (`src/utils/process.rs`, ~1,250 lines): delta walks the process tree via `sysinfo` to find who piped into it (`git diff`, `git show`, `git log`, `git blame`, `git grep`, `rg`…), parses that command line, and adapts — e.g. `--word-diff` upstream switches hunk handling, `--relative` changes path resolution for hyperlinks, grep output gets grep formatting. Effectively: recovering flags it was never passed.
- **Interactive staging**: `interactive.diffFilter = delta --color-only` supports `git add -p`; `--color-only` guarantees 1:1 input/output line correspondence (side-by-side is force-disabled for it, `src/options/set.rs`).
- **Merge conflicts** (`src/handlers/merge_conflict.rs`): inside a combined diff, `++<<<<<<<`/`++|||||||`/`++=======`/`++>>>>>>>` markers push the machine into a `MergeConflict(Ours|Ancestral|Theirs)` sub-state that buffers each commit's lines, then renders **two sub-diffs — ancestor→ours and ancestor→theirs — each with full intra-line emphasis**, framed by box-drawn headers ("ancestor ⟶ HEAD") and bar decorations. This turns a zdiff3 conflict into a pair of reviewable mini-diffs.
- **Hyperlinks** (`src/features/hyperlinks.rs`): OSC 8 links on commit hashes (`--hyperlinks-commit-link-format`, e.g. a GitHub/GitLab commit URL) and on file/line references (`--hyperlinks-file-link-format`, default `file://{path}`, with `{line}` for editor schemes) — grep output becomes click-to-open.
- No PR/review-platform awareness of any kind: no comments, no revisions, no stacks.

### 6. Architecture & reuse

Process model: `git → delta → less`, with delta spawning and managing the pager via bat's `OutputType`/`PagingMode` machinery (`src/utils/bat/`), ignoring SIGINT so the pager is never orphaned. Sub-commands (`delta file1 file2`, `--show-themes`, `--show-colors`, shell completions) shell out or re-enter the same pipeline.

The **config cascade** is the most reusable design idea. Everything is a named _feature_ — a set of (option, value) pairs. Builtin features (`line-numbers`, `side-by-side`, `navigate`, `hyperlinks`, `diff-so-fancy`/`diff-highlight` emulation, `raw`, `color-only`) are maps from option name to a _function_ `(cli::Opt, GitConfig) → ProvenancedOptionValue` so defaults can depend on other options (e.g. dark/light mode) (`src/features/mod.rs`). Custom features are `[delta "name"]` gitconfig sections; features can enable other features, forming a tree resolved by pre-order traversal with de-duplication. Option lookup order (`src/options/get.rs`): explicit CLI flag → main `[delta]` section → each enabled feature right-to-left (custom section first, then builtin) → default. Shipped color themes (`themes.gitconfig`, 21 entries) are _just features_, previewable via `--show-themes` inside a live diff. Values are provenance-tagged (`GitConfigValue` vs `DefaultValue`), and a `check_names` pass asserts at startup that every CLI field is wired — config drift is a hard error.

Monolith-bound pieces: the state machine is inseparable from git's textual quirks (the `EndCRLF` ANSI-between-`\r\n` workaround in `ingest_line_utf8`, rename-header dedup, the `AmbiguousDiffMinusCounter` for bare `diff -u` detection). Cleanly extractable ideas: `align.rs` (self-contained token aligner), the annotated-line + `line_alignment` data model, `superimpose_style_sections`, the `MinusPlus<T>`/`LeftRight<T>` index newtype (`src/minusplus.rs`) that makes minus/plus symmetric code read declaratively, and the feature cascade.

## Strengths

- Zero-friction adoption: one gitconfig line; no git wrapper, no TUI, no state. Degrades to a plain pager for anything it does not recognize (`emit_line_unchanged` fallback).
- The three-tier emph/non-emph/unpaired style model plus grouped-edit alignment bias produces unusually low-noise word-level highlighting for a line-based tool.
- `line_alignment` as a first-class product of edit inference makes side-by-side, wrapping, and unified modes consume one data model.
- The feature/theme cascade is a genuinely good config architecture: themes, emulation modes (`diff-so-fancy`), and user presets are all the same mechanism, with provenance and startup-time completeness checking.
- Merge-conflict rendering as two ancestor-relative sub-diffs is more informative than any marker coloring.
- Repurposing `less` (history-seeded `n`/`N` navigation, hyperlinks through OSC 8) extracts interactivity from a non-interactive design.
- Broad input coverage from one machine: unified + combined diffs, blame, grep (incl. ripgrep JSON), submodules, `git show`, `--color-moved` passthrough.

## Weaknesses

- Reconstructing semantics from presentation is inherently fragile: the handler chain and states like `HunkMinus(DiffType, Option<String>)` encode years of git output quirks; every new git output tweak is a potential parser bug.
- Process-tree sniffing (`utils/process.rs`) is a heavyweight, heuristic substitute for actually being told the invocation context; it costs a thread and ~50 ms of process enumeration and can guess wrong.
- No structural or format-aware diffing: a formatter re-aligning a table produces N paired lines each with scattered emph — delta lightens unchanged tokens but cannot say "this hunk is alignment-only".
- Line pairing is greedy and window-less: it never reorders, so a moved line inside a subhunk pairs badly; moved-code detection exists only as git `--color-moved` passthrough.
- Per-character explode/zip in `superimpose_style_sections` and per-line-pair DP tables are fine for hunks but embody a "lines are short, hunks are small" assumption (guarded by truncation limits rather than better algorithms).
- No interactivity of its own: no folding, no context expansion, no per-file collapse — impossible without abandoning the filter model.
- Side-by-side line-number bookkeeping requires acknowledged hacks (the wrapped-line decrement fixups in `side_by_side.rs` marked `HACK`).

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                                 | Trade-off                                                                                         |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Parse git's text output instead of using libgit2              | Works with anything that emits diff-shaped text; zero repo coupling; trivial install      | Fragile heuristic parsing; no access to file contents, so context can never be expanded           |
| Own Needleman-Wunsch token aligner instead of a diff crate    | Full control of cost model (grouping bias, whitespace coalescing, configurable tokenizer) | ~1.5 kLoC to maintain; O(n·m) per candidate line pair; greedy pairing can misalign moved lines    |
| Buffer only subhunks (≤ `--line-buffer-size` lines)           | Streaming latency; giant added/deleted files paint incrementally                          | Edit inference cannot see across buffer flushes; pathological pairings at the 32-line boundary    |
| Delegate paging/searching to `less`, seed its history for nav | Inherits mature scrolling/search for free; keeps delta stateless                          | Navigation is a regex hack; no folding, no cursor, no semantic jumps beyond label matching        |
| Features as first-class named option-sets in gitconfig        | Themes, emulations, and user presets unify; composable; provenance-checked                | Resolution order (CLI vs section vs feature tree) is complex enough to need a 60-line doc comment |
| Detect the calling process via the OS process tree            | Adapts to `--word-diff`, `--relative`, grep vs diff without any protocol change           | sysinfo dependency + background thread; guesswork that can and does mis-detect                    |
| Two independent style streams superimposed per character      | Syntax and diff styling stay orthogonal; either can be re-themed alone                    | Per-char explode/coalesce cost; foreground/background merge rules get intricate (`map-styles`)    |

## Sources

- Local checkout at `/home/petar/code/repos/rust/delta`, revision `95a0e224f55ccfdf3a7d1278fdea98a3edb9fbf4` (2026-07-30): `src/delta.rs`, `src/edits.rs`, `src/align.rs`, `src/paint.rs`, `src/handlers/hunk.rs`, `src/handlers/merge_conflict.rs`, `src/features/{mod,side_by_side,line_numbers,navigate,hyperlinks}.rs`, `src/wrapping.rs`, `src/options/{set,get}.rs`, `src/utils/process.rs`, `src/main.rs`, `Cargo.toml`, `ARCHITECTURE.md`, `themes.gitconfig`, `manual/src/`
- [delta user manual][manual]
- [`ARCHITECTURE.md` at the surveyed revision][arch]

<!-- References -->

[repo]: https://github.com/dandavison/delta
[manual]: https://dandavison.github.io/delta/
[arch]: https://github.com/dandavison/delta/blob/95a0e224f55ccfdf3a7d1278fdea98a3edb9fbf4/ARCHITECTURE.md
