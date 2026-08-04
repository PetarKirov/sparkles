# git-split-diffs (TypeScript / Node.js)

A git pager that re-renders `git diff`/`git log -p` output as GitHub-style side-by-side,
syntax-highlighted, word-wrapped diffs in the terminal — a pure streaming text transform
sitting between git and `less`.

| Field             | Value                                                            |
| ----------------- | ---------------------------------------------------------------- |
| Language          | TypeScript (Node.js ≥ 18, ESM, esbuild-bundled)                  |
| License           | MIT                                                              |
| Repository        | [github.com/banga/git-split-diffs][repo]                         |
| Documentation     | `README.md` in the repository (usage, themes, performance table) |
| Category          | terminal-differ (git pager filter)                               |
| First release     | First commit 2021-04-10; published to npm as `git-split-diffs`   |
| Latest release    | `v2.3.0` (per `package.json` at the surveyed revision)           |
| Surveyed revision | `e08c4e09bd7e233d82127131d36b02abb9f035bb` (2026-06-26)          |

## Overview

### What it solves

Plain `git diff` output is a unified interleave of `-`/`+` lines with at best
whole-line coloring. GitHub's PR view popularized two refinements — side-by-side
panes and syntax highlighting layered under the add/remove tint — that terminal
users lose the moment they leave the browser. `git-split-diffs` restores both by
installing itself as `core.pager` (`git-split-diffs --color | less -RFX`): it
parses git's already-computed diff from stdin, re-lays it out as two aligned
columns with line-number gutters, word-level change highlights, and
shiki/TextMate syntax colors, and pipes the styled result onward to `less`
(`README.md`, `src/index.ts`).

### Design philosophy

The project states its goal in one line at the top of `README.md`:

> "GitHub style split (side by side) diffs with syntax highlighting in your terminal."

Everything is organized around a lazy streaming pipeline of async generators —
`transformContentsStreaming` composes `iterlinesFromReadable` →
`iterReplaceTabsWithSpaces` → `iterSideBySideDiffs` → `iterWithNewlines` and hands
the result to `stream.pipeline` for backpressure (`src/transformContentsStreaming.ts`).
Styling is kept out of the transform logic via an attributed-string abstraction;
its doc comment states the contract (`src/SpannedString.ts`):

> "A string whose substrings can be marked by arbitrary objects. The string can be
> iterated over to get substrings with the list of objects applied to them, in the
> order they were applied."

The acknowledgements name `diff-so-fancy` ("for showing what's possible") and
`delta` ("which approaches the same problem in Rust") as the surrounding
ecosystem (`README.md`).

## How it works

### 1. Diff computation & data model

No diff is computed at the file level: the tool **parses git's own unified/combined
diff output** from stdin. `iterSideBySideDiffsFormatted`
(`src/iterSideBySideDiffs.ts`) is a hand-written line-oriented state machine over
nine states (`unknown`, `commit-header`, `commit-body`, `unified-diff`,
`unified-diff-hunk-header`, `unified-diff-hunk-body`, and `combined-diff`
variants). Incoming lines are first stripped of any ANSI codes git emitted
(`ansi-regex`), so the tool composes with `--color` upstream. State transitions
key off literal prefixes: `commit `, `diff --git`, `@@ `, `diff --cc` /
`diff --combined`, and a `@{2,}` regex for combined hunk headers.

The data model is minimal: a hunk is an array of `HunkPart`
(`{ fileName, startLineNo, lines: (string | null)[] }`, `src/iterFormatHunk.ts`)
— two parts for a normal diff, N+1 parts for a combined (merge-commit) diff with
N parents. Pane alignment is encoded **during parsing**: `-` lines go to part A,
`+` lines to part B, and when a context line arrives, the shorter side is padded
with `null`s until both arrays are equal length before the context line is pushed
to both (`unified-diff-hunk-body` case). `null` therefore means "missing line —
render a blank filler cell". Within a contiguous change run, removed line _k_
pairs positionally with added line _k_; there is no similarity matching between
removed and added lines. Combined-diff hunk bodies are re-split from the
multi-column prefix format into per-parent panes plus a final "current state"
pane (`combined-diff-hunk-body` case, with a long explanatory comment citing the
git docs).

The only diff computed in-process is **intra-line**: `diffWords` from the
[jsdiff][jsdiff] package (`diff` on npm, Myers at word granularity), applied to
each aligned A/B line pair (`src/highlightChangesInLine.ts`).

Two edge cases show the cost of parsing text instead of using plumbing: binary
file names are recovered by regex from the unescaped
`Binary files a/… and b/… differ` sentence (comment in
`src/iterSideBySideDiffs.ts` admits it can only "hopefully find the right
match"), and `/dev/null` in `---`/`+++` headers is special-cased to detect
creations/deletions.

### 2. Rendering & layout

Side-by-side is the default. Column width is simply
`SCREEN_WIDTH / hunkParts.length` (`src/iterFormatHunkSplit.ts`); each cell is
rendered by `formatAndFitHunkLine` as
`<lineNo:5> <prefix> <text>` with per-role colors (deleted / inserted /
unmodified line and line-number colors from the theme). Rows are produced by
`zip`-ing the pre-aligned `lines` arrays of all parts, so a deletion pairs with a
blank `MISSING_LINE_COLOR` cell in the other pane. Line numbers are tracked with
a `numDeletes` counter so deletions don't advance the B-side counter.

Wrapping (`WRAP_LINES`, default on) happens **inside a column**:
`iterFitTextToWidth` (`src/iterFitTextToWidth.ts`) either word-wraps via
`wrapSpannedStringByWord` or truncate-slices. The wrapper computes per-character
terminal widths with `wcwidth` (so double-width CJK is budgeted correctly),
breaks at whitespace boundaries, and hard-breaks words longer than a line
(`src/wrapSpannedStringByWord.ts`). When the left and right cells wrap to
different heights, `zipAsync` pads the shorter side with blank filler lines so
panes stay row-aligned; continuation rows get an empty line-number gutter
(`isFirstLine` logic in `src/formatAndFitHunkLine.ts`).

Syntax highlighting uses [shiki][shiki] (VS Code's TextMate grammars + themes),
**one line at a time**: `highlightSyntaxInLine`
(`src/highlightSyntaxInLine.ts`) picks the grammar from the file extension,
lazily calls `highlighter.loadLanguage`, runs `codeToTokens` on the single
line's text, and adds one span per token. Highlighting a line in isolation means
multi-line constructs (block comments, template strings) lose grammar state
across lines — a deliberate trade for streaming operation.

All styling accumulates on a `FormattedString = SpannedString<ThemeColor>`
(`src/formattedString.ts`). Spans are stored as start/end markers indexed by
string offset; crucially `slice()` preserves and re-closes active spans, which is
what makes wrap-after-style possible: the pipeline styles a whole logical line
(word-diff spans, then syntax spans, then whole-line tint), and only then cuts it
into screen rows. Final ANSI emission (`applyFormatting`) walks
`iterSubstrings()`, reduces the span stack to one `ThemeColor`, and calls
`chalk.rgb`/`bgRgb` (24-bit).

The theme layer (`src/themes.ts`, JSON files in `themes/`) is notable: colors
are `#rrggbb(aa)` with an **alpha channel**, and `reduceThemeColors` composites
overlapping spans by alpha blending (`mergeColors`), applying spans in reverse
so "specific formatting (like syntax highlighting) first … more generic colors
(like line colors) last". A translucent inserted-line background therefore tints
syntax-highlighted tokens instead of replacing them — GitHub's layered look,
computed at emission time. Themes carry 20 named slots (`ThemeColorName`) plus a
default shiki theme name; user overrides come from
`git config split-diffs.*` (`src/getGitConfig.ts`), including a
`theme-directory` for custom JSON themes.

### 3. Intra-line & noise handling

Word-level refinement is on by default (`highlight-line-changes`).
`getChangesInLine` (`src/highlightChangesInLine.ts`) runs jsdiff's `diffWords`
(with `ignoreWhitespace: false`) on each aligned line pair, then applies a
usefulness gate: it counts changed vs unchanged word tokens and **suppresses the
word highlights entirely when `changedWords > totalWords * HIGHLIGHT_CHANGE_RATIO`**
(ratio `1.0`) — the doc comment says granular changes are only shown "if the
ratio of change to unchanged parts in the line is below a threshold, otherwise
the lines have changed substantially enough for the granular diffs to not be
useful". Rendering then paints only the `added`/`removed` runs relevant to that
pane's side (`highlightChangesInLine`).

There is no whitespace-ignore mode, no formatting-noise classification, and no
moved-code detection — the tool renders exactly the hunks git emitted, and any
`git diff -w`-style suppression must be requested upstream from git itself.
A comment in `src/iterFormatHunk.ts` (`// TODO: Fix to handle multiple hunk
parts`) notes that intra-line refinement only considers the first two parts, so
combined diffs get approximate word highlights.

### 4. Navigation, folding & scale

Not applicable by design: the process is a one-pass filter with no TTY input of
its own. Navigation, search, and quitting are delegated to the downstream pager
(`less -RFX`; the README documents a `-+LFX` variant to re-enable scrolling), and
context/folding decisions are delegated upstream to git. There is no file tree,
no hunk jumping, no collapsing. Scale is handled by streaming: async generators
plus `stream.pipeline` give backpressure end-to-end, `EPIPE` is swallowed so
quitting `less` mid-stream exits cleanly, and `index.ts` explicitly waits for a
stdout `drain` before exit so `less` receives complete output. The README's
benchmark (`git log -p` piped to `/dev/null`) reports ≈45 ms/kloc with all
features, 15 ms/kloc without syntax highlighting, 13 ms/kloc with word
highlighting also off — i.e. shiki dominates the cost (`benchmark.ts` exists for
reproduction).

### 5. VCS & review integration

Integration is the thinnest possible: the tool never invokes git plumbing for
content. It runs `git config -l` once at startup to read its `split-diffs.*`
settings (`src/index.ts`, `src/getGitConfig.ts`) and otherwise consumes whatever
git pipes to the pager — which is why it transparently supports `git diff`,
`git show`, `git log -p`, `git stash show -p`, and merge-commit combined diffs.
There is no PR/review-platform integration, no comments, no stacked-change
model, no staging or hunk selection, and no merge-conflict UI. Commit headers
and bodies in `git log -p` streams are recognized and restyled
(`iterFormatCommitHeaderLine.ts`, `iterFormatCommitBodyLine.ts`), which is the
extent of "review" awareness.

### 6. Architecture & reuse

Single short-lived process, spawned by git per pager invocation; the CLI entry
(`src/index.ts`) is ~40 lines. The architecture is a straight-line composition
of async-generator stages over two vocabularies: raw `string` lines on the way
in, `FormattedString` values on the way out, with ANSI serialization confined to
the final `applyFormatting` step. Dependencies are few and focused: `shiki`
(highlighting), `diff` (word diff), `chalk` (ANSI emission + color-level
detection), `wcwidth` (column widths), `ansi-regex`, `terminal-size`.

Cleanly reusable ideas rather than a reusable library: the package exposes only
the CLI binary. The extractable pieces are (a) `SpannedString` — attributed
string with span-preserving `slice`, the keystone that decouples styling from
wrapping; (b) the alpha-compositing theme model in `themes.ts`; (c) the
`wrapSpannedStringByWord` width-aware word wrapper; (d) the pager-parser state
machine, including the combined-diff-to-N-panes conversion. Tests
(`jest` + snapshots, e.g. `index.test.ts`, `wrapSpannedStringByWord.test.ts`)
pin the transform end-to-end. The per-line shiki call and extension-based
language detection are the main monolith-bound simplifications.

## Strengths

- Zero-friction adoption: one `git config core.pager` line upgrades every
  diff-emitting git command, with git itself still computing the diff (all git
  diff options keep working).
- `SpannedString` cleanly solves the style-then-wrap problem: word-diff, syntax,
  and line-tint spans survive slicing into wrapped screen rows.
- Alpha-blended theme compositing reproduces GitHub's layered look (syntax color
  under translucent add/remove tint) with plain 24-bit ANSI.
- Correct-by-construction pane alignment falls out of the parse (`null` padding
  at context boundaries), including the rarely-supported N+1-pane rendering of
  combined merge-commit diffs.
- Principled degradation: unified layout below `min-line-width × panes` columns,
  truncation as an alternative to wrapping, syntax highlighting fully optional.
- Genuinely streaming with backpressure and careful `EPIPE`/`drain` handling
  around `less`.

## Weaknesses

- Per-line shiki tokenization loses grammar state across lines: block comments,
  multi-line strings, and markdown fences mis-highlight; language choice is by
  file extension only.
- Removed/added lines pair positionally inside a change run — no
  similarity-based line matching — so word-level highlights degrade when git's
  hunk interleave doesn't correspond 1:1.
- No noise handling beyond the word-change-ratio gate: no whitespace-ignore, no
  moved-code detection, no formatting-noise classification.
- Parsing porcelain text is fragile at the edges (regex recovery of binary-diff
  file names, `/dev/null` special cases, hunk-header string surgery).
- `wcwidth` per code point, not grapheme clusters — ZWJ emoji and combining
  sequences can mis-budget column widths in the wrapper.
- Node.js startup plus shiki initialization on every pager invocation; syntax
  highlighting triples per-kloc cost (45 vs 15 ms/kloc per the README).
- Terminal width is sampled once at startup (`terminal-size`); no re-layout on
  resize (inherent to the pipe-filter model).

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                       | Trade-off                                                                                    |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Parse git's pager stream instead of computing diffs        | All git commands/options work unchanged; no repo access or diff engine needed   | Fragile porcelain parsing; locked to git's line-level hunks; no re-diff for better alignment |
| Async-generator pipeline over `stream.pipeline`            | Streaming with backpressure; first output appears before input ends             | One-pass model forbids global layout (no cross-hunk alignment, no resize re-layout)          |
| `SpannedString` attributed strings, ANSI emitted last      | Style layers compose independently; `slice` makes wrapping styled text trivial  | Extra abstraction and per-line span bookkeeping vs direct ANSI concatenation                 |
| RGBA theme colors with alpha compositing at emission       | GitHub-style layered tints from independent theme slots; themes stay small JSON | Requires truecolor; blending math per substring; modifiers merge additively                  |
| Per-line shiki `codeToTokens`                              | Works on arbitrary hunk fragments without file contents; streams line by line   | Multi-line grammar constructs highlight wrong; per-line tokenization is the dominant cost    |
| Positional A/B line pairing with `null` padding at context | Alignment computed during parsing, O(1) per line; panes stay row-locked         | No similarity matching; word-diff quality depends on git's interleave order                  |
| Word-diff suppression above a change ratio                 | Avoids highlight noise when a line was substantially rewritten                  | Single global threshold (`1.0`); no per-language or whitespace-aware refinement              |
| Unified fallback when `width < min-line-width × panes`     | Split panes below ~80 columns each are unreadable; user-tunable                 | Binary switch — no intermediate compact layouts                                              |
| Delegate paging/navigation to `less`                       | Tiny scope; users keep familiar pager keybindings                               | No hunk navigation, folding, file tree, or interactivity of any kind                         |

## Sources

- Primary: source tree at `/home/petar/code/repos/typescript/git-split-diffs` at the
  surveyed revision — notably `src/iterSideBySideDiffs.ts` (parser state machine),
  `src/iterFormatHunkSplit.ts` / `src/iterFormatHunkUnified.ts` (layouts),
  `src/SpannedString.ts`, `src/wrapSpannedStringByWord.ts`,
  `src/highlightChangesInLine.ts`, `src/highlightSyntaxInLine.ts`,
  `src/themes.ts`, `themes/*.json`, `README.md`, `todo.md`, `package.json`
- [git-split-diffs repository][repo] (pinned to the surveyed revision)
- [shiki documentation][shiki]
- [jsdiff (`diff` on npm)][jsdiff]
- [chalk (`chalk` on npm)][chalk]

<!-- References -->

[repo]: https://github.com/banga/git-split-diffs/tree/e08c4e09bd7e233d82127131d36b02abb9f035bb
[shiki]: https://shiki.style/
[jsdiff]: https://www.npmjs.com/package/diff
[chalk]: https://www.npmjs.com/package/chalk
