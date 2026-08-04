# Diff Viewers & PR Review Tools

How do diff viewers, structural differs, TUI/GUI git clients, and pull-request
review platforms compute, render, align, de-noise, and navigate diffs? This
survey is the evidence base for hue's [diff & PR view](../../specs/hue/diff-view.md)
spec (`DVM`/`DVS`/`DVL`/`DVN`/`DVG`/`DPR`), whose motivating pain is a
formatter re-aligning **unrelated markdown-table rows** and drowning the real
change in alignment noise.

**Last reviewed:** August 4, 2026

The survey answers six questions, each a dimension analyzed uniformly in every
deep-dive (the fixed spine) and synthesized in the [comparison](./comparison.md):

1. **Where does the diff come from** — computed in-process, re-parsed from
   git's output, delegated to a host engine, or server-computed?
2. **How is it rendered** — unified vs side-by-side, how rows align across
   panes, and how syntax highlighting composes with diff decorations?
3. **How is noise handled** — intra-line refinement, whitespace policy,
   formatting-only classification, structural equivalence, moved code?
4. **How does it navigate and scale** — hunk/file navigation, unchanged-region
   folding, large-diff guards?
5. **How does it integrate with the VCS and review platforms** — plumbing,
   staging, PR comments, revisions, stacks?
6. **What is reusable** — which mechanisms transplant into hue's
   engine/widget architecture, and which are monolith-bound?

## Master catalog

| Subject                                       | Ecosystem       | Category         | One-line role                                                                                       |
| --------------------------------------------- | --------------- | ---------------- | --------------------------------------------------------------------------------------------------- |
| [delta](./delta.md)                           | Rust            | terminal differ  | git-output re-styling pager: line state machine + Needleman–Wunsch token alignment                  |
| [git-split-diffs](./git-split-diffs.md)       | TypeScript      | terminal differ  | streaming side-by-side git pager with shiki highlighting and span-preserving wrap                   |
| [Difftastic](./difftastic.md)                 | Rust            | structural diff  | tree-sitter CST → atom/list model → Dijkstra minimal edit script; whitespace-immune by construction |
| [Mergiraf](./mergiraf.md)                     | Rust            | structural merge | tree-sitter 3-way merge driver with per-language commutativity profiles                             |
| [diffoscope](./diffoscope.md)                 | Python          | structural diff  | recursive archive/binary differ: canonicalize-then-diff with labelled noise disclosure              |
| [SemanticDiff](./semanticdiff.md)             | proprietary     | structural diff  | AST diff hiding changes proven irrelevant by curated per-language invariance rules                  |
| [codediff.nvim](./codediff-nvim.md)           | Lua/C           | editor diff      | VSCode diff computer ported to C + FFI, rendered with extmarks and filler alignment                 |
| [diffview.nvim](./diffview-nvim.md)           | Lua             | editor diff      | session orchestrator driving Vim's built-in diff mode through declarative layouts                   |
| [diffview-plus.nvim](./diffview-plus-nvim.md) | Lua             | editor diff      | maintained fork adding inline unified layout + guarded subword/char refinement                      |
| [diffs.nvim](./diffs-nvim.md)                 | Lua             | editor diff      | extmark-only diff layer with a difftastic structural-alignment oracle behind a JSON seam            |
| [Neovim linematch](./neovim-linematch.md)     | C               | editor diff      | merged core pass (PR #14537) re-pairing xdiff blocks via character-LCS DP across 2–8 buffers        |
| [Neovim charmatch](./neovim-charmatch.md)     | C               | editor diff      | unmerged PR #23569: cross-line char/word DP refinement, superseded by `diffopt+=inline:`            |
| [VS Code diff editor](./vscode.md)            | TypeScript      | editor diff      | worker-computed Myers/DP diff with the richest readability-heuristic pipeline surveyed              |
| [GitLens](./gitlens.md)                       | TypeScript      | editor diff      | renders no diffs: resolves `(path, revision)` URIs into the host diff editor                        |
| [gitui](./gitui.md)                           | Rust            | TUI client       | async hash-deduplicated libgit2 diff pane doubling as a hunk/line staging surface                   |
| [lazygit](./lazygit.md)                       | Go              | TUI client       | outsources diff rendering; owns staging via a pure parse→transform→format patch model               |
| [Meld](./meld.md)                             | Python/GTK      | GUI differ       | live-editable 2/3-way panes, regex noise filters, curved link-map connectors                        |
| [WinMerge](./winmerge.md)                     | C++             | GUI differ       | forked diffutils engine with trivial-flagged hunks, substitution-filter re-diff, CSV table mode     |
| [Araxis Merge](./araxis-merge.md)             | proprietary     | GUI differ       | commercial ceiling of UI mechanics + the richest regex/positional unimportant-text toolkit          |
| [Beyond Compare](./beyond-compare.md)         | proprietary     | GUI differ       | grammar-based unimportant-text classification + key-aligned, tolerance-aware Table Compare          |
| [Gerrit](./gerrit.md)                         | Java/TypeScript | web review       | server-computed histogram + intraline diffs streamed as classified chunks to `gr-diff`              |
| [ReviewStack](./reviewstack.md)               | TypeScript      | web review       | serverless SPA computing tree/line/interdiff entirely in the browser from raw git objects           |
| [Reviewable](./reviewable.md)                 | proprietary     | web review       | per-reviewer file×revision matrix + cross-rebase diffing with base-change classification            |
| [diffy](./diffy.md)                           | TypeScript      | web review       | browser extension replacing GitHub's Files-changed tab; four-stage API diff-fallback cascade        |
| [av (Aviator)](./av.md)                       | Go              | stacked PR       | parent-pointer branch metadata + branching-point SHAs; serializable restack sequencer               |
| [git-spice](./git-spice.md)                   | Go              | stacked PR       | branch-graph state versioned inside a git ref; multi-forge capability discovery                     |
| [git-branchless](./git-branchless.md)         | Rust            | stacked PR       | event-sourced smartlog/undo suite; its extracted `scm-record` TUI hunk selector                     |
| [GitButler](./gitbutler.md)                   | Rust/Svelte     | stacked PR       | virtual branches partitioning one worktree diff via hunk ownership + line-level locks               |
| [Graphite](./graphite.md)                     | proprietary     | stacked PR       | stacked-PR platform: version interdiffs, "hide reviewed changes", speculative merge queue           |

## Taxonomies

### By where the diff is computed

| Model                       | Subjects                                                                                                                                                                                                                                                                                                                                                                                                | Consequence                                                                     |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Own in-process engine       | [VS Code](./vscode.md), [Meld](./meld.md), [WinMerge](./winmerge.md), [Difftastic](./difftastic.md), [Mergiraf](./mergiraf.md), [ReviewStack](./reviewstack.md), [codediff.nvim](./codediff-nvim.md), [Beyond Compare](./beyond-compare.md), [Araxis Merge](./araxis-merge.md), [SemanticDiff](./semanticdiff.md), Neovim core ([linematch](./neovim-linematch.md), [charmatch](./neovim-charmatch.md)) | owns the noise policy; can classify, refine, and align freely                   |
| Re-parses git's text output | [delta](./delta.md), [git-split-diffs](./git-split-diffs.md), [lazygit](./lazygit.md), [GitButler](./gitbutler.md) (UI tier)                                                                                                                                                                                                                                                                            | must re-infer pairing/alignment; noise policy limited to what survives the text |
| Delegates to a host engine  | [diffview.nvim](./diffview-nvim.md) (Vim), [GitLens](./gitlens.md) (VS Code), [diffs.nvim](./diffs-nvim.md) (xdiff + difftastic oracle)                                                                                                                                                                                                                                                                 | inherits the host's policy; cannot add classification later                     |
| Server-computed             | [Gerrit](./gerrit.md), [Reviewable](./reviewable.md), [Graphite](./graphite.md), [diffy](./diffy.md) (GitHub-fed)                                                                                                                                                                                                                                                                                       | client renders a classified chunk stream; wire model becomes the seam           |

### By formatting-noise strategy

The survey's motivating axis — what happens when a formatter re-aligns
unrelated rows:

| Strategy                         | Subjects                                                                                                                                                                                                                                                                                                                     | Verdict for hue                                                      |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| None (line red/green only)       | [gitui](./gitui.md), [lazygit](./lazygit.md), [git-branchless](./git-branchless.md), [av](./av.md), [git-spice](./git-spice.md), [diffy](./diffy.md), [GitButler](./gitbutler.md)                                                                                                                                            | negative evidence: responsiveness alone doesn't solve the table pain |
| Whitespace flags / trim-only     | [VS Code](./vscode.md) (`ignoreTrimWhitespace`), [codediff.nvim](./codediff-nvim.md), [diffview-plus.nvim](./diffview-plus-nvim.md) (xdiff flags)                                                                                                                                                                            | interior re-padding still lights up                                  |
| Lexical rules, filters & re-diff | [Meld](./meld.md) (regex filters), [WinMerge](./winmerge.md) (substitution + re-diff, `OP_TRIVIAL`), [Araxis Merge](./araxis-merge.md) (line expressions), [Beyond Compare](./beyond-compare.md) (grammar importance), [Gerrit](./gerrit.md) (`common:true` chunks), [Reviewable](./reviewable.md) (policy + semantic guard) | demote-don't-hide is the consensus UX contract                       |
| Structural invariance            | [Difftastic](./difftastic.md), [Mergiraf](./mergiraf.md), [SemanticDiff](./semanticdiff.md), [diffs.nvim](./diffs-nvim.md) (via difftastic), [diffoscope](./diffoscope.md) (canonicalize-then-diff)                                                                                                                          | whitespace-immune by construction — but none covers markdown tables  |
| Temporal / workflow              | [Graphite](./graphite.md) (interdiffs, mechanical-layer stacking), [Reviewable](./reviewable.md) (revision marks), [ReviewStack](./reviewstack.md) (diff-of-diffs)                                                                                                                                                           | orthogonal axis: review the formatter pass once, never again         |

### By intra-line refinement

| Refinement                        | Subjects                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| None                              | [gitui](./gitui.md), [lazygit](./lazygit.md), [git-branchless](./git-branchless.md), [diffview.nvim](./diffview-nvim.md) (host's)                                                                                                                                                                                                                                                                                                                          |
| Naive positional pairing          | [GitButler](./gitbutler.md), [ReviewStack](./reviewstack.md), [GitLens](./gitlens.md) (model only)                                                                                                                                                                                                                                                                                                                                                         |
| Similarity-paired token alignment | [delta](./delta.md) (Needleman–Wunsch + grouping bias), [VS Code](./vscode.md) (DP + boundary snapping), [Gerrit](./gerrit.md) (char Myers + hygiene passes), [Meld](./meld.md) (equal-run post-filter), [diffview-plus.nvim](./diffview-plus-nvim.md) (guarded two-stage), [WinMerge](./winmerge.md) (capped word engine), [Neovim charmatch](./neovim-charmatch.md) (cross-line char/word DP; mainline chose `inline:`'s per-block xdiff re-run instead) |
| Structural sub-line               | [Difftastic](./difftastic.md) (word LCS inside changed regions), [SemanticDiff](./semanticdiff.md), [Beyond Compare](./beyond-compare.md) (grammar elements)                                                                                                                                                                                                                                                                                               |

## Milestones

| When       | Milestone                                                                                                                                                                                                                                                    |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| mid-1990s  | [Beyond Compare](./beyond-compare.md) establishes the commercial compare-suite category (Table Compare, importance grammar)                                                                                                                                  |
| 2000–2002  | [WinMerge](./winmerge.md) (2000) and [Meld](./meld.md) (`0.1`, 2002-05-18) bring open-source visual diffing with filter stacks                                                                                                                               |
| 2008       | [Gerrit](./gerrit.md) ships server-computed review diffs (Mondrian/Rietveld lineage) — the classified chunk stream is born                                                                                                                                   |
| 2015–2016  | [Reviewable](./reviewable.md) (2015) per-reviewer revision matrices; VS Code (2015) and [GitLens](./gitlens.md) (2016) editor stack                                                                                                                          |
| 2018–2020  | TUI wave: [lazygit](./lazygit.md) (`v0.1`, 2018-08), [gitui](./gitui.md) (2020-05)                                                                                                                                                                           |
| 2019       | [delta](./delta.md) `0.0.1` (2019-07-16) — syntax-highlighted re-styling of git's own output goes mainstream                                                                                                                                                 |
| 2021       | Structural wave: [Difftastic](./difftastic.md) `0.2` "first version using Dijkstra" (2021-07-04); [diffview.nvim](./diffview-nvim.md); [git-split-diffs](./git-split-diffs.md); [Graphite](./graphite.md) CLI beta                                           |
| 2022       | [ReviewStack](./reviewstack.md) (2022-11, with Sapling's open-sourcing); [Neovim linematch](./neovim-linematch.md) squash-merged (2022-11-04, ships in 0.9, on by default since 0.11)                                                                        |
| 2023-05-04 | [VS Code](./vscode.md) 1.78 ships the "advanced" diff computer (moved-code detection, subword refinement, unchanged-region hiding)                                                                                                                           |
| 2024       | [git-spice](./git-spice.md) `v0.1.0` (2024-07-21); [Mergiraf](./mergiraf.md) `v0.1.0` (2024-11-01) — structural merging lands                                                                                                                                |
| 2025–2026  | AI review ([Graphite](./graphite.md) Diamond, 2025-03); Neovim ports Vim's `inline:char/word` (2025-03-28), closing the [charmatch](./neovim-charmatch.md) PR; difftastic-as-oracle editor integrations ([diffs.nvim](./diffs-nvim.md) `v0.1.0`, 2026-02-03) |

## Suggested reading paths

- **"I'm designing hue's diff view"** (the spec feed):
  [Difftastic](./difftastic.md) → [Mergiraf](./mergiraf.md) →
  [Beyond Compare](./beyond-compare.md) → [Gerrit](./gerrit.md) →
  [VS Code](./vscode.md) → [delta](./delta.md) → [comparison](./comparison.md).
- **Terminal rendering**: [delta](./delta.md) →
  [git-split-diffs](./git-split-diffs.md) → [gitui](./gitui.md) →
  [lazygit](./lazygit.md) → [diffs.nvim](./diffs-nvim.md).
- **The noise problem**: [SemanticDiff](./semanticdiff.md) →
  [WinMerge](./winmerge.md) → [Araxis Merge](./araxis-merge.md) →
  [Beyond Compare](./beyond-compare.md) → [Meld](./meld.md) →
  [Gerrit](./gerrit.md).
- **PR review & stacks**: [Gerrit](./gerrit.md) →
  [Reviewable](./reviewable.md) → [ReviewStack](./reviewstack.md) →
  [Graphite](./graphite.md) → [av](./av.md) → [git-spice](./git-spice.md) →
  [GitButler](./gitbutler.md) → [diffy](./diffy.md).

## Sources

Each deep-dive carries its own `Sources` section pinned to the surveyed
revision (local checkouts) or the consulted official docs (proprietary
products). The synthesis across subjects is [comparison.md](./comparison.md);
the design it feeds is the
[hue diff & PR view spec](../../specs/hue/diff-view.md).

<!-- References -->
