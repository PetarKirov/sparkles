# GitLens (TypeScript / VS Code extension)

GitLens is GitKraken's Git super-extension for VS Code: it renders **no diff panes of its
own** — instead it resolves any two `(path, revision)` pairs into virtual-document URIs and
hands them to VS Code's built-in diff editor, while investing its own rendering budget in
blame annotations, hovers, a vendored Lit commit-graph engine, an interactive-rebase custom
editor, and PR-platform integrations.

| Field             | Value                                                                        |
| ----------------- | ---------------------------------------------------------------------------- |
| Language          | TypeScript (extension host: Node; webviews: Lit 3 + `@lit-labs/virtualizer`) |
| License           | MIT (everything except `plus/` directories) + proprietary `LICENSE.plus`     |
| Repository        | [gitkraken/vscode-gitlens][repo]                                             |
| Documentation     | [help.gitkraken.com/gitlens][docs]                                           |
| Category          | editor-diff (VS Code git extension)                                          |
| First release     | November 2016 (VS Code Marketplace)                                          |
| Latest release    | 18.2.0 (surveyed working tree's `package.json`)                              |
| Surveyed revision | `347b61d19bf6b7742a9ab9f78d5f058e8fb6382b` (2026-08-04)                      |

> [!NOTE]
> The extension host code lives in `src/`; shared libraries were extracted into a pnpm
> workspace under `packages/` (`git`, `git-cli`, `ipc`, `utils`, `plus/commit-graph`,
> `plus/integrations`, `plus/git-github`, …). Directories named `plus` are under the
> proprietary license; everything else is MIT. This survey covers both but flags the split.

## Overview

### What it solves

VS Code ships a capable diff editor and a minimal git integration; it does not answer
"who wrote this line, when, and why", does not visualize branch topology, gives rebase-todo
files no UI, and knows nothing about pull requests. GitLens fills exactly those gaps while
**reusing** the host editor for the one thing it already does well — rendering two-pane
diffs with intra-line highlighting. From `README.md`:

> "Supercharge Git and unlock **untapped knowledge** within your repo to better
> **understand**, **write**, and **review** code. Focus, collaborate, accelerate."

### Design philosophy

Two philosophies are legible in the tree. First, _delegate rendering, own resolution_: the
entire diff-viewing feature is URI plumbing (`src/commands/diffWith.ts`,
`src/git/fsProvider.ts`) feeding `vscode.diff`. Second, _incremental, proportional work_ in
the pieces GitLens does render. The vendored commit-graph engine's rows-delta classifier
(`packages/plus/commit-graph/src/engine/delta.ts`) states it verbatim:

> "The renderer receives a fresh rows array on every host push (IPC deserialization mints
> new objects), so identity says nothing about WHAT changed. This classifier compares the
> engine-relevant TOPOLOGY of each row — sha, parents, kind, date … and names the change so
> each downstream derivation can do proportional work instead of a full rebuild"

and the graph view-model keeps rendering concerns out of the engine
(`packages/plus/commit-graph/src/view.ts`): "No DOM, no rendering framework — keep it that
way."

## How it works

### 1. Diff computation & data model

GitLens computes **no diffs in-process**. Everything is either (a) delegated to VS Code's
diff editor, which runs its own char-level diff over the two documents GitLens supplies, or
(b) shelled out to the `git` CLI and parsed.

The CLI surface (`packages/git-cli/src/providers/diff.ts`) runs
`git diff --no-ext-diff --minimal` with optional `-U<n>` context, `-M<threshold>%` rename
detection, `--diff-filter=…`, under forced configs
`-c color.diff=false -c diff.mnemonicPrefix=false` (`packages/git-cli/src/exec/git.ts`).
Dirty editor buffers are diffed against a revision with `git diff --no-index -U0 --minimal`
feeding the buffer via stdin (`diffContents`). The algorithm is therefore whatever git's
Myers `--minimal` produces; there is no histogram/patience selection and no structural
(AST) diffing anywhere in the tree.

Parsing lives in `packages/git/src/parsers/diffParser.ts`. `parseGitDiff` splits raw output
on `diff --git` boundaries, extracts per-file status/metadata (binary, mode change with
file-type-boundary detection, rename/copy similarity) with a single combined regex, then
`parseGitFileDiff` parses hunks into a notable model: each hunk carries a
`Map<number, ParsedGitDiffHunkLine>` **keyed by current-file line number**, where a run of
`-` lines immediately followed by `+` lines is _paired positionally_ into
`state: 'changed'` entries holding both `previous` and `current` text — added/removed
states only when unpaired. File-list stats come from
`git diff --numstat --summary -z` (`parseGitDiffNumStatFiles`), with the `--summary` pass
refining statuses numstat cannot distinguish (copy → `C`, cross-type mode change → `T`).

### 2. Rendering & layout

Diff rendering is entirely VS Code's: side-by-side or inline, gutters, intra-line
highlighting, wrapping, and pane alignment all come free from the host.
GitLens' contribution is `gitlens.diffWith` (`src/commands/diffWith.ts`), which resolves
each side (`resolveRevision`), handles renames by _retrying with swapped paths_ when both
sides come back missing, rewrites the RHS URI for `R`/`C` statuses, degrades to a
`deletedOrMissing` sentinel URI for deleted sides, composes the tab title
(`file (rev) ⟷ file (rev)`, with `Added in`/`Deleted in`/`Not in Working Tree` suffixes),
and calls `openDiffEditor` — optionally with a `DiffRange` converted to an editor selection
so hovers can deep-link to the changed lines.

Revision content is served through a readonly `FileSystemProvider` for the `gitlens://`
scheme (`src/git/fsProvider.ts`): the URI authority hex-encodes `{repoPath, ref,
submoduleSha}` (`GitUri` in `src/git/gitUri.ts`, which subclasses `Uri` through an
undocumented components constructor — "Use this ctor, because vscode doesn't validate it").
`readFile` fetches blob content per revision; submodule entries are synthesized as
`Subproject commit <sha>\n` to mirror git's own diff text; `stat` is backed by a
`TernarySearchTree` of the full revision tree cached in a `PromiseCache` (capacity 50,
10-minute idle TTL). Because revisions are real (virtual) documents, they get tree-sitter-
free but full host-native syntax highlighting, search, folding — every editor feature.

What GitLens _does_ render itself: editor decorations (blame gutter, changes gutter,
heatmap), markdown hovers, and the webviews (commit graph, rebase, commit details,
timeline). The changes gutter (`src/annotations/gutterChangesAnnotationProvider.ts`) maps
the parsed hunk-line states onto three `TextEditorDecorationType`s
(added/removed/changed); hovers render the hunk as a fenced ` ```diff ` block inside a
`MarkdownString` (`src/hovers/hovers.ts`), reusing the host's diff grammar for coloring.

### 3. Intra-line & noise handling

Intra-line refinement is wholly delegated to the VS Code diff editor; GitLens ships no
word/char-level algorithm. Noise controls it does own are git passthroughs:
`blame.ignoreWhitespace` (adds `-w` to `git blame`,
`packages/git-cli/src/providers/blame.ts`), `--minimal` on every diff invocation, and the
`commits.similarityThreshold` config feeding `-M<threshold>%` so renames don't appear as
delete+add pairs. There is no formatting-noise classification, no
whitespace-only-hunk suppression of its own, and no moved-code detection — absences
consistent with the delegation architecture, since the host diff editor owns those toggles
(`diffEditor.ignoreTrimWhitespace`).

### 4. Navigation, folding & scale

Within a diffed/annotated file, `nextChange`/`previousChange` jump between
`sortedHunkStarts` with wrap-around (`gutterChangesAnnotationProvider.ts`). File-level
navigation is tree-view-based: comparison result nodes (Search & Compare view,
`src/views/searchAndCompareView.ts`) list changed files as a flattenable tree; folder-level
comparisons shell out to `git difftool --dir-diff` or open VS Code's directory compare.

Scale engineering concentrates in the Commit Graph. Rows stream from a long-running
`git log` parse (`packages/git-cli/src/providers/graph.ts`,
`src/git/graphRowProcessor.ts` enriches rows once each with avatars, emoji, grouped refs,
and serialized context menus). The webview holds a windowed session; paging uses an
**adaptive page size** — `computeAdaptivePageLimit` scales the base `pageItemLimit` with
how deep the window already is — and deep links ("Open in Commit Graph" for an old sha) use
an _uncapped targeted walk_ (`limit: 0`) because the default cap (~2000 rows) would never
reach it (`src/webviews/plus/graph/graphWebview.ts`). On the renderer side the engine
resumes from a snapshot on `append`, skips layout entirely on `payload`-only changes
(`engine/delta.ts`, `engine/session.ts`), rows are virtualized (`@lit-labs/virtualizer`),
and the per-row SVG gutter bakes unchanging pass-through lanes into a shared cached raster
`<image>` layer instead of re-emitting DOM `<line>`s per row
(`src/webviews/apps/plus/graph/graph-wrapper/graph-gutter-raster.ts`). Lane allocation
supports pinned branch heads with reserved low columns and lane
clamping/collapsing for width control (`engine/layout.ts`, `laneClamp.ts`,
`laneCollapse.ts`).

### 5. VCS & review integration

All local VCS access shells to the git CLI through `packages/git-cli` (parsers for blame,
log, status, tree, reflog, worktrees, merge-tree, rebase-todo under
`packages/git-cli/src/parsers/` and `packages/git/src/parsers/`). A second `GitProvider`
implementation (`packages/plus/git-github`) answers the same interface from the GitHub API
for virtual `vscode.dev` workspaces — the provider seam (`src/git/gitProvider.ts`) is real,
not decorative.

The **interactive rebase editor** (`src/webviews/rebase/rebaseEditor.ts`) is a
`CustomTextEditorProvider` registered for `git-rebase-todo` files: git itself launches the
"editor" (VS Code), GitLens parses the todo (`rebaseTodoParser.ts`), renders a Lit webview
with drag-and-drop entry reordering and action dropdowns
(`src/webviews/apps/rebase/`), and writes edits back through the text document — git
remains the executor, the webview is only a structured view of the todo file.

**PR integration** spans hosting providers (GitHub, GitLab, Azure DevOps, Bitbucket +
Server via `@gitkraken/provider-apis`, plus issue trackers Jira/Linear —
`packages/plus/integrations/src/providers/`). Commits and branches are enriched with their
associated PR (hover/CodeLens/graph rows show PR links); **Launchpad**
(`src/plus/launchpad/`) categorizes your open PRs (needs review, blocked, ready to merge)
into a quick-pick command center, and `startReview` checks a PR out into a **worktree** so
review doesn't disturb the working tree. GitLens also interoperates with Microsoft's
GitHub Pull Requests extension rather than competing with its comment UI: it accepts GHPR
tree nodes in its own commands (`src/commands/ghpr/openOrCreateWorktree.ts`) and parses
GHPR's `pr:` URI scheme (JSON query with `baseCommit`/`headCommit`/`isBase`) inside
`GitUri.fromUri` so blame and hovers keep working inside GHPR's diff editors. Inline PR
review _comments_ are otherwise out of scope; GitLens Pro's "Code Suggest" instead uploads
cloud patches as suggestions (`src/plus/drafts/draftsService.ts`). Staging is file-level
(`packages/git-cli/src/providers/staging.ts` — no hunk staging; that remains the host
SCM's job); merge-conflict tooling parses `git merge-tree` and tracks paused rebase/merge
operations (`pausedOperations.ts`, `@gitkraken/conflict-tools`).

### 6. Architecture & reuse

Process model: one extension host (Node) plus sandboxed webviews communicating over a typed
IPC protocol (`packages/ipc`, `src/webviews/protocol.ts`); webview apps are Lit 3
components. A DI-ish `Container` (`src/container.ts`) wires ~40 services. The pnpm
workspace split makes several pieces genuinely reusable:

- `packages/git` — pure models + parsers (diff, rebase-todo), no VS Code imports.
- `packages/git-cli` — git process execution + output parsers.
- `packages/plus/commit-graph` — "High-performance, themable commit-graph engine —
  vendored into GitLens as its Commit Graph (Lit) renderer"
  (`packages/plus/commit-graph/package.json`); the `engine/` (layout, edges, delta,
  session) and `view.ts` layers are framework-free by charter.
- The annotation/hover/URI layers in `src/` are monolith-bound (deep VS Code API
  coupling), as is the webview host plumbing.

## Strengths

- The URI/provider delegation architecture gets side-by-side rendering, intra-line
  refinement, editing affordances, and future host improvements for free — the diff
  feature is ~200 lines of resolution logic plus a `FileSystemProvider`.
- Revision documents are first-class: anything the editor can do to a file (hover, blame,
  search, further diffs) works at any revision, recursively.
- The commit-graph incremental pipeline (`initial`/`append`/`payload`/`replace`
  classification, session snapshot resume, rasterized lane layer, virtualization) is a
  careful, measured approach to 10⁵-row graphs in a DOM renderer.
- Rebase editor design — structured UI over the real todo file with git as executor — is
  robust to interruption and preserves interop with plain-text editing.
- The hunk-line `Map` model (current-line keyed, positional `-`/`+` pairing into
  `changed`) is a compact bridge from unified diff text to editor decorations.
- Worktree-based PR review (Launchpad `startReview`) avoids trashing local state.
- The `GitProvider` seam is proven by a second, API-backed implementation (vscode.dev).

## Weaknesses

- No diff rendering of its own means no control over it: GitLens cannot add
  formatting-noise suppression, moved-code detection, or structural diffing without a
  whole new editor surface.
- Diff quality is capped at `git diff --minimal`; no histogram/patience option is exposed.
- Word-level and whitespace handling depend on host settings GitLens doesn't own.
- PR review commenting is delegated (GHPR extension / browser); GitLens' own review story
  (Launchpad, Code Suggest) is split between free and Pro/cloud features.
- The `plus/` licensing split means the most interesting renderer (commit graph) is not
  MIT.
- Heavy platform coupling: outside `packages/`, nearly everything imports `vscode` APIs.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                       | Trade-off                                                                        |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Delegate diff rendering to VS Code via URIs + `FileSystemProvider` | Free side-by-side/intra-line/edit features; tiny surface to maintain            | Zero control over diff algorithm, noise handling, or layout                      |
| Shell out to git CLI; parse text output                            | Full fidelity with user's git version/config; no libgit2 binding maintenance    | Process-spawn latency; parser fragility across git versions; regex-heavy parsing |
| Encode revision identity in URI authority (hex metadata)           | Survives VS Code URI round-trips; works with any host API taking a `Uri`        | Opaque URIs; requires custom `Uri` subclass constructed via unvalidated ctor     |
| Rows-delta classification + session snapshots in graph engine      | Proportional work per refresh; `payload`-only pushes skip layout entirely       | Engine must define and maintain an exact "topology identity" contract for rows   |
| Rebase UI as `CustomTextEditorProvider` over `git-rebase-todo`     | Git stays the executor; plain-text fallback always works                        | UI limited to what the todo file can express; state sync via file watching       |
| Interop with GHPR extension (`pr:` scheme) instead of own comments | Avoids duplicating a complex review-comment UI                                  | Review UX fragmented across two extensions plus the browser                      |
| pnpm workspace extraction of models/parsers/graph engine           | Testable, framework-free cores; graph engine reusable across GitKraken products | Two-license repo; extraction boundary adds indirection for contributors          |

## Sources

- Local checkout at the surveyed revision — primary: `src/commands/diffWith.ts`,
  `src/git/gitUri.ts`, `src/git/fsProvider.ts`,
  `packages/git/src/parsers/diffParser.ts`, `packages/git-cli/src/providers/diff.ts`,
  `src/annotations/gutterChangesAnnotationProvider.ts`, `src/hovers/hovers.ts`,
  `packages/plus/commit-graph/src/engine/{layout,delta,session}.ts`,
  `src/webviews/plus/graph/{graphWebview,graphDataController}.ts`,
  `src/webviews/rebase/rebaseEditor.ts`, `src/plus/launchpad/`,
  `src/commands/ghpr/openOrCreateWorktree.ts`, `README.md`, `LICENSE`, `LICENSE.plus`
- [GitLens repository][repo] (pinned to the surveyed revision)
- [GitLens documentation][docs]

<!-- References -->

[repo]: https://github.com/gitkraken/vscode-gitlens/tree/347b61d19bf6b7742a9ab9f78d5f058e8fb6382b
[docs]: https://help.gitkraken.com/gitlens/gitlens-home/
