# Difftastic (Rust)

A batch CLI structural diff tool that parses both file versions with tree-sitter, lossily flattens the CSTs into a two-variant atom/list syntax model, and finds the minimal edit script as a Dijkstra shortest path — falling back to a word-refined line diff when the language is unsupported or limits are exceeded.

| Field             | Value                                                                                           |
| ----------------- | ----------------------------------------------------------------------------------------------- |
| Language          | Rust (2021 edition)                                                                             |
| License           | MIT                                                                                             |
| Repository        | <https://github.com/Wilfred/difftastic>                                                         |
| Documentation     | <https://difftastic.wilfred.me.uk/> (mdBook under `manual/src/`)                                |
| Category          | structural-diff                                                                                 |
| First release     | 0.1 (experiments); 0.2, 2021-07-04, "First version using Dijkstra's algorithm" (`CHANGELOG.md`) |
| Latest release    | 0.70.0 in `Cargo.toml`, unreleased at surveyed revision                                         |
| Surveyed revision | `a6611b97a35a240a3751594234540dfccbd104a6` (2026-08-03)                                         |

## Overview

### What it solves

Line-oriented diffs report _where bytes changed_, not _what code changed_: a reformat that re-wraps an expression across lines, re-indents a block, or adds a trailing comma produces walls of noise. Difftastic diffs the _syntax_: "Difftastic is a structural diff tool that compares files based on their syntax" (`README.md`). It ships parsers for 30+ languages, prints a side-by-side view where only genuinely novel syntax nodes are highlighted, and answers "No syntactic changes." for pure reformatting. It is a display tool only — patches and merging are explicit non-goals: "Difftastic output is intended for human consumption, and it does not generate patches that you can apply later" (`README.md` § Non-goals; for AST merging it points at mergiraf).

### Design philosophy

Three commitments recur throughout the source:

1. **Optimal-and-readable over fast-and-greedy.** The diff engine is literally a shortest-path search: "Implements Dijkstra's algorithm for shortest path, to find an optimal and readable diff between two ASTs" (`src/diff/shortest_path.rs`). A\* was tried and rejected — "it's really hard to write a good heuristic … you end up with something buggy and/or reimplementing much of the graph in the heuristic. Dijkstra works well enough in practice, and preprocessing the input to find smaller subsections to diff tends to be much more effective" (`src/diff/shortest_path.rs` module doc).
2. **A deliberately lossy syntax model.** Tree-sitter CSTs are collapsed to atoms and delimited lists: "Difftastic only cares about list delimiters and atom contents. This ensures that `"x"` and `" x"` are different, but `[x]` and `[ x]` are not" (`src/parse/tree_sitter_parser.rs`, `TreeSitterConfig::atom_nodes` doc). Whitespace _between_ tokens is not represented at all.
3. **Graceful degradation.** Every failure mode — unsupported language, oversized file, too many parse errors, exploding search graph — lands on the same word-refined line diff, with the reason printed in the file header (`FileFormat::TextFallback { reason }` in `src/main.rs`).

## How it works

### 1. Diff computation & data model

**Syntax model.** `src/parse/syntax.rs` defines the entire vocabulary: `enum Syntax<'a> { List { open_content, children, close_content, open/close_position, num_descendants, .. }, Atom { content, position, kind, .. } }`. `AtomKind` is `Normal | String(_) | Type | Keyword | Comment | TreeSitterError | CanIgnore`. `src/parse/tree_sitter_parser.rs` walks the tree-sitter cursor: per-language `TreeSitterConfig` declares `atom_nodes` (subtrees forced to single atoms, e.g. string literals — protecting against tree-sitter's missing-children problem), `delimiter_tokens` (token pairs like `(`/`)` absorbed into `List` open/close instead of being child atoms; `list_from_cursor` even wraps `foo[0]`-style mixed lists in an outer anonymous list), and `ignore_trailing_tokens` (trailing commas → `AtomKind::CanIgnore`). Single-child lists with empty delimiters are elided (`Syntax::new_list`), shrinking deep grammar spines like `(compilation-unit (top-level-def …))`.

**Equality is content interning, not node identity.** `init_all_info` assigns every node a `content_id` by structural interning (`set_content_id`): a `List` key is (open, close, children's content ids filtered of `CanIgnore` atoms); an `Atom` key is its content — with multi-line comments normalized by trimming each line's leading whitespace. `impl PartialEq for Syntax` is just `self.content_id() == other.content_id()`. Positions never participate, so identical subtrees match regardless of location or depth.

**The graph.** `src/diff/graph.rs`: a `Vertex` is a pair of cursors — "one to the next unmatched LHS syntax, and one to the next unmatched RHS syntax" — plus a stack of `EnteredDelimiter`s distinguishing lists entered on both sides together (`PopBoth` — must be exited together, so `(a b c)` vs `(a b) c` is a change) from lists entered on one side (`PopEither`). Edges from `compute_neighbours`, with hand-tuned costs (`Edge::cost`):

| Edge                                             | Cost                                                  | Meaning                            |
| ------------------------------------------------ | ----------------------------------------------------- | ---------------------------------- |
| `UnchangedNode`                                  | `min(40, depth_difference + 1)` (+200 if punctuation) | whole subtrees equal — skip both   |
| `EnterUnchangedDelimiter`                        | `100 + min(40, depth_difference)`                     | same delimiters, recurse into both |
| `ReplacedComment`/`ReplacedString`               | `500 + (100 − levenshtein_pct)`                       | similar comment/string pair        |
| `NovelAtomLHS/RHS`, `EnterNovelDelimiterLHS/RHS` | `300`                                                 | node exists on one side only       |

The `depth_difference` term lets nodes match at _different_ nesting depths (a small penalty rather than a prohibition) — this is how wrapping `x` into `(x)` highlights only the parens (`manual/src/tricky_cases.md` § Adding Delimiters). The punctuation penalty (only `,` `;` `.`, deliberately conservative — `looks_like_punctuation`) prevents matching a comma instead of a variable name. `ReplacedComment` cost is calibrated to beat 2×300 novel only when content is similar (`strsim::normalized_levenshtein`), and `populate_change_map` demotes matches under 21 % similarity back to `Novel`.

**The search.** `src/diff/shortest_path.rs` runs Dijkstra with a `RadixHeapMap` (monotone priority queue), bump-arena-allocated vertices (`bumpalo`), lazily materialized neighbour lists (`OnceCell`), and a seen-map that deduplicates vertices — capped at **2** stored parenthesis-nesting variants per (LHS, RHS) node pair (`allocate_if_new`), an explicit exponential-blowup guard. Vertex equality itself only compares the top of the delimiter stack — a documented soundness/size trade-off ("the first vertex we see 'wins' … In practice this seems to work well", `graph.rs`). The route is converted to a `ChangeMap: node → ChangeKind {Unchanged, ReplacedComment, ReplacedString, Novel, IgnoredPunctuation}`.

**Preprocessing shrinks the problem.** `src/diff/unchanged.rs` (`mark_unchanged`) strips equal nodes at both ends, splits the top level at "mostly unchanged" list pairs sharing ≥ 4 content-unique subtrees (`MOSTLY_UNCHANGED_MIN_COMMON_CHILDREN`), and marks equal singletons unchanged outright — but only trees above `TINY_TREE_THRESHOLD = 10` nodes, so a stray matching `(` doesn't anchor a bogus split. Dijkstra then runs per changed section. The module doc calls this out as _the_ performance lever (more effective than a smarter search).

**Postprocessing.** `src/diff/sliders.rs` fixes "sliders" (ambiguous novel-region placement), preferring contiguous novel nodes on the same line — two one-step passes plus a nested-delimiter pass whose inner-vs-outer preference is per-language (`prefer_outer_delimiter`: Lisps/JSON/TOML/SQL outer, everything else inner).

**Fallback line diff.** `src/line_parser.rs` + `src/diff/lcs_diff.rs`: line-level LCS via the **Wu algorithm** (`wu-diff` crate) over hashed lines, then contiguous novel runs are re-diffed word-by-word (`split_words`) to mark `UnchangedPartOfNovelItem` vs `NovelWord`. All computed in-process from file contents; git only supplies file pairs (§ 5).

### 2. Rendering & layout

`--display` selects `side-by-side` (default), `side-by-side-show-both`, `inline`, or `json` (`src/options.rs`; JSON is gated behind `DFT_UNSTABLE=yes`). The core display currency is `MatchedPos { kind: MatchKind, pos: SingleLineSpan }` per side, where `MatchKind::UnchangedToken` carries **both** `self_pos` and `opposite_pos` — every unchanged token knows its counterpart's line — and this is what drives cross-pane alignment: `src/display/context.rs` (`all_matched_lines_filled`) folds those pairings into a `Vec<(Option<LineNumber>, Option<LineNumber>)>`, padding either side with `None` rows so unchanged lines sit opposite each other. Missing rows print dimmed dot line numbers; a line wrapped to terminal width prints continuation rows with dotted gutters (`format_missing_line_num` in `src/display/side_by_side.rs`). `src/display/hunks.rs` groups novel lines into hunks (gap > `MAX_DISTANCE = 4` lines splits hunks) and merges after adding `--context` lines (default 3). Syntax highlighting is _not_ a separate pass: the same tree-sitter highlight queries used for parsing classify atoms (`AtomKind::Keyword/Type/String/Comment`), and `src/display/style.rs` maps `MatchKind` × `TokenKind` to ANSI styles — novel tokens get color + bold, `NovelWord`s inside replaced strings/comments get stronger emphasis than the unchanged words around them. Inline mode (`src/display/inline.rs`) prints removed-then-added blocks with both line-number columns.

### 3. Intra-line & noise handling

This is difftastic's defining dimension, handled _by construction_ rather than by suppression rules:

- **Inter-token whitespace does not exist.** Atoms store only their own source range; nothing between tokens is ever modeled, so indentation, alignment, and line-wrapping changes produce byte-identical syntax trees → `has_syntactic_changes: false` → "No syntactic changes." (`src/main.rs`, `print_diff_result`) and exit code 0. There is no `--ignore-whitespace` flag because there is nothing to ignore.
- **Whitespace inside atoms is significant.** `"x"` vs `" x"` differs (string contents are atom content); the JSX text node is the one place content is `trim()`ed (`atom_from_cursor`). Multi-line comments get per-line leading-whitespace normalization in their `content_id` (`set_content_id`), so re-indenting a block comment is also invisible.
- **Trailing tokens.** `AtomKind::CanIgnore` (opt-in per language via `ignore_trailing_tokens`) makes `[1, 2]` = `[1, 2,]` for equality, while the diff still _sees_ the comma so `[]` → `[1,]` highlights it. Punctuation additionally carries the +200 matching penalty so anchors are identifiers, not commas.
- **Word-level refinement** exists in exactly two places: inside `ReplacedComment`/`ReplacedString` pairs (`split_atom_words` in `src/parse/syntax.rs`: `split_words_and_numbers` + LCS, whitespace-only novel words skipped, all-novel if no common words) and inside novel line runs of the plain-text fallback (`src/line_parser.rs`).
- **Comments** can be dropped entirely with `--ignore-comments`; `--strip-cr on` normalizes CRLF.
- **No moved-code detection.** The vertex cursors only advance forward, so a moved function is Novel on both sides; nothing pairs them. Absence is structural: cross-hunk matching doesn't fit the shortest-path formulation.

> [!IMPORTANT]
> **The markdown-table case.** Markdown is _not_ in the `Language` enum (`src/parse/guess_language.rs` — 60+ languages, no Markdown; nothing in `vendored_parsers/` either). A realigned markdown table therefore takes the plain-text path, where whitespace is fully significant — the test `test_positions_whitespace_is_change` (`src/line_parser.rs`) pins `"foo"` vs `" foo"` as novel. Every re-padded row shows as a changed line pair; the only mercy is word-level refinement dimming the unchanged cell text (`UnchangedPartOfNovelItem`) so only shifted `|` and padding read as fully novel — and even that dies above `MAX_WORDS_IN_LINE = 1000` words per novel run. So difftastic's whitespace-invariance is a _property of the atom/list model_, available only where a grammar maps the format into it. A markdown grammar with cell contents as atoms and `|` as delimiter/punctuation would get realignment-invariance for free — difftastic simply hasn't wired one up.

### 4. Navigation, folding & scale

Not interactive: difftastic is a one-shot printer (pipe to a pager); there is no in-tool hunk navigation, folding, or file tree — a sentence suffices because the design point is batch output. Scale is instead handled by a **fallback ladder**, each rung landing on the line diff with the reason in the header (`src/main.rs`, `diff_file_content`):

| Guard                   | Default                     | Trigger → behaviour                                       |
| ----------------------- | --------------------------- | --------------------------------------------------------- |
| `DFT_BYTE_LIMIT`        | 1,000,000 bytes             | either file larger → skip parsing, text fallback          |
| `DFT_PARSE_ERROR_LIMIT` | 0                           | more tree-sitter `ERROR` nodes → text fallback            |
| `DFT_GRAPH_LIMIT`       | 3,000,000 vertices          | Dijkstra seen-set exceeds → abandon search, text fallback |
| `MAX_WORDS_IN_LINE`     | 1000 (`src/line_parser.rs`) | skip word refinement inside a huge novel run              |

Additional scale machinery: the quadratic `size_hint` for the seen-map is capped at the graph limit (`mark_syntax`); directory diffs run per-file in parallel with `rayon` (`diff_directories`); `--check-only` short-circuits after tree equality (`check_only_text`) for fast changed/unchanged answers; `--skip-unchanged` suppresses "No changes" entries in directory mode.

### 5. VCS & review integration

Deliberately thin. Difftastic reads two files (or two directories, for mercurial's `extdiff`) and never invokes git plumbing itself. Integration surfaces (`src/options.rs`, `Mode` parsing): the two-path form; the **7- or 9-argument `GIT_EXTERNAL_DIFF` form** (git passes path, old-file, old-hex, old-mode, new-file, new-hex, new-mode [+ rename info], and `GIT_DIFF_PATH_COUNTER`/`GIT_DIFF_PATH_TOTAL` env vars give the `1/3` header counters); `git difftool`; jj and fossil recipes in the manual. One genuinely novel VCS feature: **conflict mode** (`src/conflicts.rs`) parses diff3-style conflict markers (`<<<<<<<`/`|||||||`/`=======`/`>>>>>>>`) out of a single file and diffs the two conflicting sides against each other. Exit codes: 0 no syntactic changes, 1 changes found (with `--exit-code`), 2 usage error (`src/exit_codes.rs`). There is no PR/review-platform integration, no comments, no staging or hunk selection, and no merge resolution — all out of scope for a pure differ (patch emission is an explicit non-goal, § Overview).

### 6. Architecture & reuse

A single ~15,700-line Rust binary (`src/`), cleanly layered: `parse/` (language detection à la linguist — extensions, shebangs, Emacs/vim modelines; CST → `Syntax` lowering), `diff/` (graph + Dijkstra + preprocessing + sliders), `display/` (positions → hunks → styled text), thin `main.rs` orchestration. Grammars are mostly compiled in from crates.io tree-sitter crates, with five vendored in-tree (`vendored_parsers/`: hare, janet-simple, kotlin, latex, smali) — all statically linked, so the binary is self-contained but adding a language means recompiling difftastic. Key third-party pieces: `tree-sitter`, `wu-diff` (line LCS), `radix_heap` (monotone Dijkstra queue), `bumpalo`/`typed-arena` (arena allocation of vertices/nodes), `strsim` (Levenshtein for replaced comments/strings), `rayon`, `owo-colors`. The reusable _ideas_ — the atom/list lossy lowering (one diff engine, N languages, per-language config tables), content-id interning as O(1) subtree equality, the unchanged-region splitter, the cost-tuned edge vocabulary, the graph-limit fallback ladder, and `opposite_pos`-driven pane alignment — are all articulated in self-contained modules with heavy doc comments, but nothing is published as a library crate; consumers either shell out to the binary (JSON output still unstable) or fork.

## Strengths

- Formatting-noise immunity is _structural_, not heuristic: reformat-only changes in any supported language yield "No syntactic changes." with no flags needed.
- Optimality: Dijkstra over a cost-tuned graph gives minimal, stable diffs, with documented cost rationale (punctuation penalties, depth differences, comment similarity) encoding display _readability_ into the objective function.
- Matches nodes across depth changes — wrapping/unwrapping in delimiters highlights only the delimiters (`manual/src/tricky_cases.md`), a case most tree differs fail.
- Excellent degradation story: every limit lands on a usable word-refined line diff with the reason printed; `--check-only` gives cheap boolean answers.
- The manual is a research artifact in itself: `tree_diffing.md` surveys competing tools (Autochrome, GumTree, Tristan Hume's A\* differ), `tricky_cases.md` is an honest test-case catalog.
- Alignment metadata (`self_pos`/`opposite_pos` on every unchanged token) is richer than line-pair anchors and drives pixel-solid side-by-side rows.

## Weaknesses

- Not a library: monolithic binary, unstable JSON output, no reusable crate boundary around the diff engine.
- Quadratic-ish graph growth on large change sets; the 3 M-vertex limit means big refactors silently fall back to line diff (README § Known Issues concedes performance and memory).
- No moved-code detection; a relocated function is pure add + delete.
- No Markdown (or any prose format) grammar, so the tool's headline noise immunity does not apply to the documentation files where alignment noise is worst.
- Whole-file model: no incremental reuse of previous parses/diffs; every invocation reparses and re-searches (fine for batch, wrong for an interactive viewer).
- Language support requires compiled-in grammars plus hand-written per-language tables (`atom_nodes`, `delimiter_tokens`, slider preferences) — quality varies by how well a grammar fits the atom/list mold (string interpolation is a documented failure mode, `tree_sitter_parser.rs`).
- Display-only: no patches, no merging, no review workflow — by design, but it means difftastic is one pane of a review tool, never the tool.

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                                         | Trade-off                                                                                              |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Lossy atom/list model instead of full CST diffing                     | One engine + one cost model for 30+ languages; whitespace invariance by construction              | Node roles are lost (a `,` and an identifier differ only by content); interpolated strings mis-model   |
| Dijkstra over a lazily built graph, not A\* or GumTree-style matching | Provably minimal edit script; readability encoded as edge costs; "easy to reason about"           | Graph can blow up on large change sets → hard vertex limit → fallback                                  |
| Content-id interning as node equality                                 | O(1) deep subtree comparison; enables `UnchangedNode` mega-edges and unchanged-region splitting   | Equality is exact-content only; near-identical subtrees get no partial credit outside comments/strings |
| Delimiter stack with `PopBoth`/`PopEither`, shallow vertex equality   | Correctly flags `(a b c)` → `(a b) c`; keeps vertex count near-quadratic instead of exponential   | Path-dependent "first vertex wins" — acknowledged unsoundness that "seems to work well"                |
| Hand-tuned integer edge costs (1/100/300/500–600, +200 punctuation)   | Encodes display preferences (anchor on identifiers, pair similar comments) directly in the search | Magic numbers; changing one cost re-tunes the whole system (comments document the couplings)           |
| Fallback ladder to word-refined line diff on every limit              | Never fails to produce _a_ diff; reason surfaced in header                                        | Silent quality cliff: the files that most need structural help (huge diffs) get the least              |
| Batch printer, no interactivity, no patch output                      | Composability with git/jj/hg/pagers; small, testable core                                         | No navigation, folding, staging, or review features; JSON escape hatch still unstable                  |

## Sources

- Local checkout at `/home/petar/code/repos/rust/difftastic`, revision `a6611b97a35a240a3751594234540dfccbd104a6` (2026-08-03): `src/diff/graph.rs`, `src/diff/shortest_path.rs`, `src/diff/unchanged.rs`, `src/diff/sliders.rs`, `src/diff/lcs_diff.rs`, `src/parse/syntax.rs`, `src/parse/tree_sitter_parser.rs`, `src/parse/guess_language.rs`, `src/line_parser.rs`, `src/words.rs`, `src/display/{context,hunks,side_by_side,style,inline,json}.rs`, `src/main.rs`, `src/options.rs`, `src/conflicts.rs`, `src/exit_codes.rs`, `README.md`, `CHANGELOG.md`, `manual/src/tree_diffing.md`, `manual/src/tricky_cases.md`
- [Difftastic manual][manual]
- [Difftastic repository][repo]
- [Tristan Hume, "Designing a Tree Diff Algorithm Using Dynamic Programming and A\*"][thume] — cited by `src/diff/shortest_path.rs` as the A\* precedent

<!-- References -->

[manual]: https://difftastic.wilfred.me.uk/
[repo]: https://github.com/Wilfred/difftastic
[thume]: https://thume.ca/2017/06/17/tree-diffing/
