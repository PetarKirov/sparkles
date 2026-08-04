# Comparison: What a Diff Viewer Owes Its Reader

_The cross-subject synthesis of the [diff-review survey](./index.md), and the
bridge into hue's [diff & PR view spec](../../specs/hue/diff-view.md)._

**Last reviewed:** August 4, 2026

## At a glance

| Subject                                       | Engine                         | Intra-line                  | Noise classification                                   | Layouts                         | Review/stack layer          |
| --------------------------------------------- | ------------------------------ | --------------------------- | ------------------------------------------------------ | ------------------------------- | --------------------------- |
| [delta](./delta.md)                           | re-parse git + own NW aligner  | token NW, grouping-biased   | whitespace-zero distance, no verdict                   | unified + split                 | none                        |
| [git-split-diffs](./git-split-diffs.md)       | re-parse git, `diffWords`      | word, ratio-gated           | none                                                   | split, unified fallback         | none                        |
| [Difftastic](./difftastic.md)                 | CST → Dijkstra                 | word LCS in changed regions | structural (whitespace-immune)                         | split (aligned rows)            | none                        |
| [Mergiraf](./mergiraf.md)                     | CST 3-way, PCS triples         | —                           | isomorphism hashes, formatting-preserving              | conflict files                  | merge driver                |
| [diffoscope](./diffoscope.md)                 | GNU diff over canonical forms  | char DP (HTML only)         | canonicalize + label ("ordering only")                 | unified tree                    | none                        |
| [SemanticDiff](./semanticdiff.md)             | AST + invariance rules         | structural                  | curated per-language invariances, 4-level ladder       | split, block-aligned            | GitHub app                  |
| [codediff.nvim](./codediff-nvim.md)           | VSCode computer (C port)       | char, word-extended         | trim-whitespace tier only                              | split + fillers                 | staging, 3-way              |
| [diffview.nvim](./diffview-nvim.md)           | Vim diff mode                  | host's                      | host's `diffopt`                                       | 1/2/3/4-window layouts          | staging, history, merge     |
| [diffview-plus.nvim](./diffview-plus-nvim.md) | xdiff + own refinement         | subword/char, guarded       | xdiff whitespace flags                                 | + inline unified                | jj/Sapling/P4 adapters      |
| [diffs.nvim](./diffs-nvim.md)                 | xdiff + difftastic oracle      | span-level                  | pair-then-normalize dimming; "formatting only" verdict | unified/stacked/split           | staging, review sections    |
| [Neovim linematch](./neovim-linematch.md)     | post-pass over xdiff blocks    | — (line pairing only)       | `iwhite`-aware pairing, no verdict                     | vimdiff panes + fillers         | Neovim core (merged)        |
| [Neovim charmatch](./neovim-charmatch.md)     | linematch DP over chars/words  | cross-line char/word DP     | `iwhite` variants, no verdict                          | vimdiff panes                   | unmerged PR (superseded)    |
| [VS Code](./vscode.md)                        | Myers + DP, worker             | char, heuristic pipeline    | trim tier + lazy whitespace re-scan                    | split + inline; folding         | multi-diff surface          |
| [GitLens](./gitlens.md)                       | delegates to VS Code           | host's                      | git passthrough                                        | host's                          | PR platforms, rebase editor |
| [gitui](./gitui.md)                           | libgit2                        | none                        | `ignore_whitespace` flag                               | unified                         | hunk/line staging           |
| [lazygit](./lazygit.md)                       | git shell-out                  | none (pager's)              | git flags passthrough                                  | unified (pager)                 | patch-building, staging     |
| [Meld](./meld.md)                             | own O(NP) Myers                | char + equal-run filter     | regex filters, dimmed-not-hidden                       | 2/3-way linked panes            | VCS adapters                |
| [WinMerge](./winmerge.md)                     | forked diffutils + xdiff       | capped word engine          | substitution + re-diff → `OP_TRIVIAL`                  | 2/3-way, table mode             | none                        |
| [Araxis Merge](./araxis-merge.md)             | own                            | yes                         | line expressions, de-emphasized                        | 2/3-way linking lines           | none                        |
| [Beyond Compare](./beyond-compare.md)         | own + grammar                  | grammar elements            | importance classes; key-aligned tables                 | 2/3-way, table sessions         | none                        |
| [Gerrit](./gerrit.md)                         | JGit histogram (server)        | char Myers + hygiene        | `common:true` chunks, `due_to_rebase`                  | split + unified from one stream | full review platform        |
| [ReviewStack](./reviewstack.md)               | browser Myers over git objects | naive positional            | none (but diff-of-diffs)                               | split                           | stacked GitHub review       |
| [Reviewable](./reviewable.md)                 | server                         | unknown                     | policy layer + semantic guard                          | split/unified                   | file×revision matrix        |
| [diffy](./diffy.md)                           | GitHub-fed                     | closed lib                  | none                                                   | overlay                         | batch review, viewed marks  |
| [av](./av.md)                                 | none                           | —                           | — (stack-granularity only)                             | —                               | stacked-PR sequencer        |
| [git-spice](./git-spice.md)                   | none                           | —                           | tree-hash equality tier                                | —                               | multi-forge stacks          |
| [git-branchless](./git-branchless.md)         | in-process (scm-record)        | none                        | none                                                   | unified select UI               | smartlog, undo              |
| [GitButler](./gitbutler.md)                   | gitoxide + UI re-parse         | naive positional word       | none                                                   | unified                         | virtual branches, locks     |
| [Graphite](./graphite.md)                     | server                         | unknown                     | temporal (interdiffs)                                  | split/unified                   | stacked-PR platform         |

## Per-dimension synthesis

### 1. Diff computation & data model

The field splits into **owners** and **borrowers** (see the
[taxonomy](./index.md#by-where-the-diff-is-computed)), and the survey's
clearest architectural finding is that **whoever owns the diff owns the noise
policy**: [diffview.nvim](./diffview-nvim.md) (borrows Vim's), [GitLens](./gitlens.md)
(borrows VS Code's), and [diffy](./diffy.md) (borrows GitHub's) all ship zero
noise handling and structurally cannot add it. Every subject with a noise
story computes (or post-processes) its own diff.

The convergent data model among the strongest subjects is a **chunk/row stream
with per-row intra-line spans and explicit pairing**: Gerrit's
`ab`/`a`/`b`/`common`/`skip` chunk stream with `[skip, mark]` intraline pairs,
VS Code's `DetailedLineRangeMapping` + `RangeMapping` inner changes, delta's
annotated lines + `line_alignment` vector, git-split-diffs' `(line|null)[]`
per-pane rows, scm-record's `File → Section → ChangedLine` tree. All are
renderer-neutral; Gerrit's is proven across a server/client seam. This is
the shape hue's `DVM1`–`DVM4` diff document should take.

Line pairing quality is a differentiator: delta pairs by normalized
Levenshtein with a distance gate; VS Code scores anchors (long lines) in its
DP; GitButler and ReviewStack pair positionally — and their word-diffs are
visibly worse for it. [Neovim's linematch](./neovim-linematch.md) is the
purest form of the pairing pass: a standalone character-LCS DP that re-pairs
an already-computed xdiff block across up to eight buffers — exactly the
shape of a post-diff alignment stage, and proof it can ship independently of
the base algorithm.

### 2. Rendering & layout

Side-by-side alignment has three solutions, in ascending fidelity cost:

- **Filler/ghost rows** — codediff.nvim's inner-change-driven fillers,
  WinMerge's `RealityBlock` apparent-vs-real mapping, git-split-diffs'
  null-padded panes, difftastic's dotted-gutter padding. Data-model-simple;
  the right fit for a cell grid.
- **Proportional scroll-sync** — Meld's sliding sync anchor keeps both
  documents authentic (no phantom rows) and composes with wrapping.
- **Linking lines** — Araxis draws sloped connectors instead of padding;
  GPU-cheap, generalizes to 3-way, but terminal-hostile.

Syntax highlighting composes with diff decoration as **two independent span
streams merged late** everywhere it is done well: delta's superimposed
syntect-foreground × diff-background streams, ReviewStack's interleaved
word-diff + highlight token layers, git-split-diffs' alpha-composited theme
layers. Nobody bakes diff colors into syntax spans. Both diffview-plus.nvim
and codediff.nvim go further and run the **real syntax highlighter over
deleted text** so removed lines keep their colors.

Narrow-width policy is a solved problem: split iff
`width >= minLineWidth × panes`, else unified (git-split-diffs), plus
diffs.nvim's "stacked" single-rail layout as a better narrow-terminal unified.

### 3. Intra-line & noise handling

The dimension hue exists to get right. Findings, strongest first:

- **Demote, don't hide** is the unanimous UX contract among the tools that
  classify noise: WinMerge renders `OP_TRIVIAL` hunks dimmed but visible,
  Araxis de-emphasizes and skips them in counts/navigation, Beyond Compare
  colors unimportant differences blue with one toggle to ignore, Gerrit ships
  `common:true` chunks with both texts and renders them unhighlighted,
  diffs.nvim dims (`DiffsDim`) rather than deletes, diffoscope labels
  ("ordering differences only") rather than suppresses. Reviewable adds the
  **semantic guard**: never suppress whitespace that changes meaning.
- **The classification mechanics** appear in four maturity tiers:
  (1) whitespace flags (git/xdiff passthrough); (2) trim-tier line hashing
  with lazy re-scan (VS Code's `scanForWhitespaceChanges`); (3)
  **normalize-then-re-diff** — WinMerge's substitution filters rewrite both
  sides of a hunk and re-diff to split trivial from real,
  Meld diffs a filtered shadow while displaying real text, diffoscope
  canonicalizes first; (4) **structural equivalence** — difftastic's
  atom/list model never represents inter-token whitespace, Mergiraf's
  isomorphism-invariant node hashes, SemanticDiff's curated invariance rules.
- **Nobody solves markdown tables.** Difftastic has no markdown grammar (falls
  back to text), Mergiraf's profile makes `pipe_table_cell` atomic (padding
  can still read as content), SemanticDiff doesn't support markdown, Beyond
  Compare's Table Compare handles CSV but not pipe tables. The closest
  existing model is Beyond Compare's Table Compare — rows aligned on key
  columns, cell-scoped changes, per-column importance — which is exactly what
  a `MdDoc`-based table diff gives hue for free. The gap is real and hue's
  `DVN4` fills it.
- **Refinement needs guards or it produces confetti**: diffview-plus.nvim's
  hunk-count cap + shared-prefix anchor before char-level refinement, Meld's
  drop-equal-runs-shorter-than-3, Gerrit's coalesce-within-5-chars +
  slide-to-line-tail hygiene, git-split-diffs' change-ratio gate, WinMerge's
  20480-word/500 ms budget, ReviewStack's 300-char cutoff. Every mature
  implementation caps the pass and falls back to whole-span highlight.
- **Orphan rule** (Beyond Compare): an inserted/deleted row whose content is
  all "unimportant" must stay important — the guard that stops a noise filter
  from eating genuinely added table rows.

### 4. Navigation, folding & scale

- **Unchanged-region folding**: VS Code's `UnchangedRegion.fromDiffs` is a
  pure, portable function (invert mappings + thresholds → placeholder rows);
  Gerrit adds **key locations** (comment anchors, search hits must never
  fold) and the ≤3-lines rule (don't collapse if the control row costs as
  much as the code).
- **Scale guards are a ladder, disclosed in-band**: difftastic's byte →
  parse-error → graph-size limits each degrading to a word-refined line diff
  with the reason printed; diffoscope's three-layer truncation budget with
  "N lines not shown" markers; diffs.nvim's viewport-lazy highlight budget;
  gitui's instant-plain-then-restyle. Silent truncation appears nowhere in a
  well-regarded tool.
- **Async identity**: gitui's params-hash request dedup (latest-wins single
  slot) and GitButler's content-hash row cache with O(n) per-frame overlays
  are the two proven recipes for recompute-on-toggle UIs.

### 5. VCS & review integration

- **Display vs apply must stay separate** (lazygit's `forUI` flag): noise
  suppression affects what you see, never the patch you stage. Any hue noise
  layer must respect this.
- **Staging without index surgery**: zero-context sub-patch synthesis +
  `git apply` (lazygit, codediff.nvim, diffs.nvim) beats index manipulation.
- **Stack topology is convergently tiny**: parent name + branching-point
  SHA per branch (av's `av.db` JSON, git-spice's versioned ref, Graphite's
  `refs/branch-metadata`, ReviewStack's PR-body footers). A viewer can
  reconstruct any of them read-only.
- **Review durability**: Reviewable's per-reviewer file×revision marks,
  ReviewStack's force-push-surviving version timeline + diff-of-diffs,
  GitButler's content-anchored comments — all pure data-model ideas,
  implementable locally.

### 6. Architecture & reuse

The strongest reusable shapes, each cited in its deep-dive: the
renderer-neutral classified chunk stream (Gerrit), the model-first selection
tree with pure derived views (scm-record), the alignment-oracle JSON seam
that lets a structural engine drop in behind a textual renderer (diffs.nvim ×
difftastic), the two-tier cached-row + cheap-overlay pipeline (GitButler),
and the anti-pattern to avoid: shipping diffs as patch text and re-parsing
them in every tier (GitButler does this in three places).

## The consensus standard

A diff viewer meeting 2026 expectations: computes its own diff from full file
contents (not hunk windows); pairs changed lines by similarity; refines
intra-line with guards and falls back gracefully; renders unified and
side-by-side from one model with syntax highlighting composed as a separate
span layer; folds unchanged regions around never-foldable key locations;
discloses every degradation in-band; and — among the best — classifies
formatting-only changes and **demotes them visibly instead of hiding them**.

## Architectural trade-offs

| Decision                | Option A                                          | Option B                                                          | Field's verdict                                                                                                    |
| ----------------------- | ------------------------------------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Diff ownership          | own the engine (VS Code, Meld, difftastic)        | borrow git/host output (delta, lazygit, diffview.nvim)            | owning is the only path to noise policy; borrowing is the only path to pager UX — hue needs both (`DVM1` + `DVM3`) |
| Noise suppression point | pre-diff normalization (Meld filters, diffoscope) | post-diff classification (WinMerge re-diff, Gerrit `common:true`) | post-diff classification preserves ground truth and auditability                                                   |
| Hidden vs demoted noise | hide (SemanticDiff aggressive levels)             | demote/dim, skip in navigation (WinMerge, Araxis, BC, Gerrit)     | demote; add Reviewable's semantic guard and BC's orphan rule                                                       |
| Side-by-side alignment  | filler rows (codediff, WinMerge)                  | proportional scroll-sync (Meld) / linking lines (Araxis)          | filler rows for cell grids; scroll-sync where panes stay editable                                                  |
| Structural diffing      | full structural display (difftastic)              | structural as classification oracle only (diffs.nvim mode)        | oracle mode composes with familiar line-diff display; full structural for opt-in                                   |
| Intra-line pairing      | positional (GitButler, ReviewStack)               | similarity-gated (delta, VS Code)                                 | similarity-gated, always                                                                                           |
| Stacked-PR state        | sidecar DB (av)                                   | versioned git refs (git-spice, Graphite)                          | refs win (worktree-shared, undoable, no pollution); read both                                                      |

## Delta table: prior art → hue

Where each [diff-view spec](../../specs/hue/diff-view.md) area stands relative
to the surveyed field:

| Spec area                          | Strongest prior art                                                                                                                                                                                                                                         | hue's gap / edge                                                                                              |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `DVM1`–`DVM2` line diff + pairing  | [VS Code](./vscode.md) two-phase Myers/DP + boundary snapping; [delta](./delta.md) distance-gated pairing; [Neovim linematch](./neovim-linematch.md) character-LCS pairing DP (3-way-capable, cap-guarded)                                                  | new D code; adopt the chunk-stream model + similarity pairing from day one                                    |
| `DVM3` patch parser                | [delta](./delta.md)'s state machine; [lazygit](./lazygit.md)'s ~600-line pure patch model                                                                                                                                                                   | small, well-trodden; hue re-highlights from worktree when reachable                                           |
| `DVM4` word refinement             | [Gerrit](./gerrit.md) hygiene passes; [diffview-plus.nvim](./diffview-plus-nvim.md) guards; [Meld](./meld.md) equal-run filter; the [Neovim charmatch](./neovim-charmatch.md)-vs-`inline:` design fork (integrated DP lost to a separate per-block re-diff) | port the guard recipes verbatim; subword tokens with hex-run coalescing; keep refinement a separate pass      |
| `DVM6` scale guards                | [Difftastic](./difftastic.md) fallback ladder; [diffoscope](./diffoscope.md) truncation budget                                                                                                                                                              | disclose degradations in-band, always                                                                         |
| `DVL1`–`DVL3` layouts              | [git-split-diffs](./git-split-diffs.md) width policy; [codediff.nvim](./codediff-nvim.md) filler alignment + scroll sync                                                                                                                                    | hue's cell-space display list renders fillers natively in all four sinks                                      |
| `DVL5` theme slots                 | [delta](./delta.md) emph/non-emph/plain three-tier roles; [codediff.nvim](./codediff-nvim.md) auto-derived char tier                                                                                                                                        | maps onto `Slot`/`Palette`; derive the two-tier palette from any hue theme                                    |
| `DVN1`–`DVN2` noise classification | [WinMerge](./winmerge.md) normalize + re-diff → trivial; [Gerrit](./gerrit.md) `common:true` + provenance tags                                                                                                                                              | hue combines: post-diff re-diff under a normalizer, rendered as demoted chunks with a `due to formatting` tag |
| `DVN3` structural mode             | [Difftastic](./difftastic.md); [Mergiraf](./mergiraf.md) isomorphism hashes; [SemanticDiff](./semanticdiff.md) invariances                                                                                                                                  | run structural as an **oracle** behind the line renderer (diffs.nvim pattern); full structural display later  |
| `DVN4` markdown-table cells        | [Beyond Compare](./beyond-compare.md) Table Compare (CSV only)                                                                                                                                                                                              | **nobody does pipe tables** — hue's `MdDoc` cell model + BC's column-role vocabulary is a genuine first       |
| `DVN6` rendered-preview diff       | — (no subject diffs a rendered document model)                                                                                                                                                                                                              | genuinely novel; nearest analog is [SemanticDiff](./semanticdiff.md)'s block alignment                        |
| `DVG2` folding                     | [VS Code](./vscode.md) `UnchangedRegion.fromDiffs`; [Gerrit](./gerrit.md) key locations                                                                                                                                                                     | port both: pure function + never-fold anchors (search hits, future comments)                                  |
| `DPR1`–`DPR3` PR sessions          | [ReviewStack](./reviewstack.md) client-side GitHub fetch; [diffy](./diffy.md) fallback cascade; [Gerrit](./gerrit.md) threads                                                                                                                               | native D GraphQL client; steal the >300-file cascade and thread reconstruction                                |
| `DPR4`–`DPR5` revisions & stacks   | [Reviewable](./reviewable.md) marks; [Graphite](./graphite.md) interdiffs; [av](./av.md)/[git-spice](./git-spice.md) topology                                                                                                                               | deferred by spec; the read-only topology parsers are cheap when the time comes                                |

## Sources

The 27 [deep-dives](./index.md#master-catalog), each pinned to a surveyed
revision or documented URL set with verbatim quotes; the
[hue diff & PR view spec](../../specs/hue/diff-view.md) this synthesis feeds.

<!-- References -->
