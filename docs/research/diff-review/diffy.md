# diffy (TypeScript / browser extension)

A Manifest-V3 browser extension that replaces GitHub's "Files changed" tab with a full-screen,
continuous PR review overlay — fetching the diff through the GitHub API and rendering it with
Pierre's `@pierre/diffs` `CodeView`, with inline comment threads, batched reviews, and
viewed-file tracking.

| Field             | Value                                                                                    |
| ----------------- | ---------------------------------------------------------------------------------------- |
| Language          | TypeScript (React 19, WXT extension framework, Vite)                                     |
| License           | MIT (© 2026 Suvesh Moza)                                                                 |
| Repository        | <https://github.com/suveshmoza/diffy>                                                    |
| Documentation     | `README.md`, `CHANGELOG.md`; [Chrome Web Store listing][chrome-store]                    |
| Category          | Web review client (GitHub PR overlay extension)                                          |
| First release     | Not determinable from the tree (`CHANGELOG.md` carries no dates; local history squashed) |
| Latest release    | v1.3.0 (`package.json` + `wxt.config.ts` manifest; local commit dated 2026-07-23)        |
| Surveyed revision | `27cdcc9a28c1cf59df3b9e9d84ed0ec1c53acb9c` (2026-07-23)                                  |

> [!NOTE]
> The local checkout is a single squashed commit, so "first release" and per-feature dating rely
> on `CHANGELOG.md` version headings only. The rendering core — `@pierre/diffs` 1.2.11 and
> `@pierre/trees` 1.0.0-beta.4, the diff/file-tree components open-sourced from the Pierre code
> review product ([Diffs][diffs-site], [Trees][trees-site]) — is consumed as npm packages;
> `node_modules` is absent from this checkout, so claims about the library internals below are
> limited to what diffy's own code exercises through its public API.

## Overview

### What it solves

GitHub's own PR diff renderer has hard caps and soft failure modes on large PRs: a 20,000-line /
1 MB total-diff cap ("Diff too large to display"), a 406 error from the unified-diff endpoint
past 300 files, per-file "Load diff" buttons after 400 lines / 20 KB, and a Files-changed tab
that reviewers report as slow and memory-hungry. diffy sidesteps the renderer entirely: a
**View Diff** button (plus a right-click context-menu entry on any PR link) opens a full-screen
iframe overlay that fetches the PR through the REST/GraphQL API and renders every file in one
continuous scroll, with a searchable file tree, inline review threads, batch reviews, and
per-file viewed tracking. The `README.md` feature table is explicit about the positioning:

> "Fetches changes through the GitHub API and renders them in a dedicated viewer, bypassing the
> web UI diff renderer" — `README.md`

Its niche is therefore the opposite of terminal differs like delta or git-split-diffs: it never
touches a working tree or runs git; it is a _review client_ for server-held PRs, competing with
GitHub's own web UI rather than with `git diff` output pipelines.

### Design philosophy

Three commitments recur through the source:

- **Rent the renderer, own the data path.** All diff parsing and painting is delegated to
  `@pierre/diffs` (`parsePatchFiles`, `CodeView`); diffy's own code is the GitHub data
  acquisition cascade, the review workflow, and glue. The README credits the lineage directly:
  "Powered by Pierre Trees and Diffs" (`README.md`), and the project is an acknowledged fork of
  the _Linear View Diff_ extension's idea.
- **Stay small and same-origin.** A custom WXT build module (`src/modules/shiki-pruner.ts`)
  deletes unused Shiki grammar chunks from the bundle by walking the emitted import graph —
  that is how "100+ languages, 50+ themes … under 2 MB" (`README.md`) is achieved. The
  highlighter worker is copied to a stable extension path because, as `src/lib/diff/worker.ts`
  documents:

  > "Pierre's portable worker is a single self-contained classic script (no static ES imports),
  > so it can run directly from a same-origin URL. … The default `shiki-js` highlighter uses a
  > pure-JS regex engine, so the worker never reaches its (conditional) oniguruma WASM import
  > and stays standalone." — `src/lib/diff/worker.ts`

- **Degrade, never block.** Every fetch layer has a fallback (diff endpoint → compare endpoint →
  `.diff` web URL → patch reassembled from the files API); review-comment loading failures are
  carried as a `loadError` string instead of failing the diff; viewed-state loading "never
  blocks the diff render" (`src/hooks/useViewedFiles.ts`).

## How it works

### 1. Diff computation & data model

diffy computes no diff itself — the diff is **server-provided** by GitHub and parsed
client-side. `fetchPullRequestDiffData` (`src/lib/github/api.ts`) loads, in parallel, the
paginated `pulls.listFiles` list (100/page, with progress callbacks) and all review comments,
then acquires one aggregate unified-diff text via a fallback cascade:

1. `pulls.get` with `mediaType: { format: 'diff' }` — skipped up front when
   `changed_files > 300` (`GITHUB_MAX_AGGREGATE_DIFF_FILES`, "GitHub rejects unified diffs
   above this file count");
2. on a 406 `too_large` error: `repos.compareCommitsWithBasehead` (`base.sha...head.sha`, diff
   format);
3. the raw web endpoint `https://github.com/{owner}/{repo}/pull/{n}.diff` with browser
   credentials;
4. final fallback `buildPatchFromFiles`: the per-file `patch` fragments from the files API are
   re-wrapped with **synthesized `diff --git` headers** (correct `new file mode` /
   `deleted file mode` / rename headers per `file.status`), and pure renames/copies with no
   hunks get a synthetic `similarity index 100%` stanza so the parser still emits a file entry.

The text is parsed by `parsePatchFiles` from `@pierre/diffs`
(`src/lib/code-view/build-items.ts`) into `FileDiffMetadata` values — the visible shape
(constructed manually for media stubs) is `{ name, prevName, type, hunks, splitLineCount,
unifiedLineCount, isPartial, deletionLines, additionLines }`, i.e. a hunk-list model that
pre-computes per-layout line counts and per-side line indices. Granularity of diffy's own model
is **file + hunk + line**; anything finer lives inside the library. Parsed results become an
ordered `CodeViewItem[]` (`type: 'diff' | 'file'`, following the PR's file order so media files
interleave correctly) and are memoized in a module-level `Map` keyed by
`owner/repo#N@headSha@{count:idSum:newestUpdatedAt}` — a content fingerprint that includes the
review-comment set, so a new comment invalidates exactly one PR's built items.

### 2. Rendering & layout

Rendering is Pierre's `CodeView` React component (wrapped by
`src/components/diff/ThemedCodeView.tsx`), driven by user preferences persisted in
`browser.storage.sync` (`src/lib/diff/display-prefs.ts`):

- **Split or unified** layout toggle (`DiffLayoutToggle.tsx`); the parsed model's
  `splitLineCount`/`unifiedLineCount` indicates the library pre-computes row alignment for both.
- **Diff indicators**: `'classic'` (`+`/`-` signs), `'bars'` (default), or `'none'`; **hunk
  separators** in four styles (`simple`, `metadata`, `line-info` (default), `line-info-basic`).
- Line numbers toggleable; **wrap vs horizontal scroll** per preference (`overflow: 'wrap'`
  default); sticky per-file headers; custom code/tree fonts with size, line-height, and
  OpenType font-feature settings (Google Fonts allowed by the extension CSP).
- **Syntax highlighting** is Shiki, run in a **worker pool**
  (`src/providers/PersistentWorkerPoolShell.tsx`): pool size
  `clamp(1..4, hardwareConcurrency/2)`, a 200-entry `totalASTLRUCacheSize` render cache, and
  the full pruned language list (`src/lib/diff/lang-ids.json`, regenerated by the build
  module). Themes come from `@pierre/theme`/`@shikijs/themes` with separate light/dark picks
  and an auto mode (`src/lib/theming/`).
- **Image diffs** reuse the annotation channel (see §3 for the mechanism): before/after images
  are placed as annotations on the `deletions`/`additions` _sides_ of a synthetic zero-line
  diff, "so split view is truly side-by-side" while "unified view keeps both slots in one row"
  (`src/lib/code-view/build-items.ts`); a lightbox offers 2-up, swipe, and onion-skin compare
  modes. Non-image binaries get a placeholder annotation linking to GitHub.

### 3. Intra-line & noise handling

diffy itself contains **no intra-line refinement and no noise handling**: a search across `src/`
finds no occurrence of word-/char-level diffing, whitespace-ignore, or moved-code logic. Any
token-level emphasis is whatever `@pierre/diffs` does internally (not verifiable from this
checkout — `node_modules` is absent). There is no ignore-whitespace toggle, no
formatting-noise classification, and no way to re-request the diff with
`ignore_whitespace` semantics (the GitHub API's diff media type has no such parameter, and
diffy adds no client-side pass). Absence is the finding: a tool whose diff arrives as opaque
server-rendered patch text has ceded this entire dimension to the forge.

The one adjacent mechanism is the **generic annotation channel** it builds everything else on:
`DiffLineAnnotation<Metadata>` = `{ lineNumber, side: 'deletions' | 'additions', metadata }`.
`src/lib/review/comments.ts` defines a metadata union
(`thread | draft | queued | media-image | media-binary`) and maps GitHub review comments onto
items through it; `build-items.ts` reuses the same channel for image panes. One typed seam
serves comments, drafts, queued batch comments, and media panels.

### 4. Navigation, folding & scale

- **File tree**: `@pierre/trees` `FileTree` with fuzzy search, comment badges
  (`src/lib/file-tree/comment-badge.ts`), and icon theming. Notably the tree library is
  _patched_ (`patches/@pierre__trees.patch`, via `patch-package`) to remember
  manual expand/collapse overrides made _while a search filter is active_ — a
  fork-and-fix of the vendored controller's search-visibility state machine.
- **Folding**: per-file collapse chevrons, Expand All / Collapse All, and auto-collapse of
  files marked viewed (`DiffOverlay.tsx` `setItemCollapsed` / `handleCollapseAll`). "Jump to
  next unviewed" walks the PR's file order from the current selection
  (`findNextUnviewedPath`, `src/lib/review/viewed-files.ts`).
- **Scroll anchoring**: `src/lib/code-view/scroll-anchor.ts` wraps any item mutation
  (collapse, annotation insert) in `capturePendingLayoutAnchor()` + a double-`requestAnimationFrame`
  scroll restore that re-pins `scrollTop` if the mutation jumped it by more than 2 px — layout
  changes never teleport the viewport.
- **Large-PR guard**: `isLargePullRequestData` (> 150 files or > 500 KB patch,
  `src/lib/code-view/build-items.ts`) routes item building through
  `requestIdleCallback` + React `startTransition` (`src/hooks/useCodeViewItems.ts`) so parsing
  a huge patch does not block first paint; smaller PRs build synchronously in `useMemo`.
  Prefetching starts on page load (`prefetchPullRequestDiff`), before the user clicks
  **View Diff**, with a TanStack Query cache (`staleTime: Infinity`, 30 min GC).
- **No context expansion**: the viewer shows exactly the hunks GitHub sent; there is no
  "expand 20 lines" affordance and no blob fetch for text files (the Contents API is used only
  for media bytes, capped at 10 MB — `src/lib/github/blobs.ts`).

### 5. VCS & review integration

No git plumbing at all — the extension's only backends are `api.github.com` (REST via Octokit,
GraphQL via raw `fetch`) and the github.com web origin. Review features
(`src/lib/github/review-write.ts`, `src/lib/github/graphql.ts`):

- **Inline comments**: immediate single comments (`pulls.createReviewComment` with
  `line`/`side` and multi-line `start_line`/`start_side` derived from the `CodeView` line
  selection), replies, edits, deletes. Threads are _reconstructed client-side_ from the flat
  comment list by chasing `in_reply_to_id` to a root (cycle-guarded) and sorting by
  `created_at`; threads whose anchor has no current line (outdated) are surfaced as an
  "orphaned comments" badge per file rather than dropped.
- **Batch review**: queued comments publish in a single `POST /pulls/{n}/reviews` with a
  `COMMENT` / `APPROVE` / `REQUEST_CHANGES` verdict.
- **Viewed-file tracking**: GitHub's own `markFileAsViewed` / `unmarkFileAsViewed` GraphQL
  mutations with optimistic updates — so progress state is shared with the native GitHub UI.
  The README documents a sharp edge: fine-grained PATs cannot call these GraphQL mutations, so
  the full review flow needs a classic `repo`-scoped token.
- Errors are mapped to a typed `GitHubReviewWriteError` code enum with user-actionable
  messages; rate-limit state is tracked globally and surfaced in the header.

There is **no multi-revision model**: the viewer always shows base…head of the current PR head
SHA (a Refresh button refetches after new pushes), with no per-commit slicing, no interdiff
between force-pushes, and no stacked-PR awareness. No staging, no local apply, no merge/conflict
handling — out of scope by construction.

### 6. Architecture & reuse

Process model: a **content script** on `github.com` (`src/entrypoints/github-pr.content/`)
installs the button and a full-screen `chrome-extension://` **iframe overlay**
(`src/lib/overlay/frame.ts`) with a `postMessage` ready/close handshake and page scroll-lock; a
**background** service worker handles the context menu and standalone-tab opens; a **popup**
manages the token (`browser.storage.local`) with capability hints. The overlay can detach into
a standalone tab. Two build-system war stories are instructive: Chrome rejects content scripts
containing non-ASCII bytes, so a Vite plugin re-escapes emitted chunks to `\uXXXX`
(`toAscii()`, `wxt.config.ts`); and dev-server workers are cross-origin, hence the
copied-portable-worker scheme quoted above.

Reusable ideas vs monolith: the diff renderer, file tree, and theming are _already_ external
packages (`@pierre/diffs`, `@pierre/trees`, `@pierre/theme`) — diffy is evidence that a
standalone, worker-pooled, annotation-extensible diff-rendering library with a clean
`parsePatchFiles → CodeViewItem[] → CodeView` pipeline can carry an entire review product.
diffy's own transferable pieces are the GitHub diff-acquisition cascade with synthetic-patch
fallback (`src/lib/github/api.ts`), the thread-reconstruction + annotation mapping
(`src/lib/review/comments.ts`), and the scroll-anchored mutation helpers
(`src/lib/code-view/scroll-anchor.ts`). The React/extension shell is monolith-bound.

## Strengths

- Concrete, documented answers to GitHub's diff caps: the four-stage fallback cascade means a
  3,000-file PR still renders, where the native tab refuses.
- One generic annotation seam (`side` + `lineNumber` + typed metadata) carries review threads,
  drafts, batch-queue markers, image panes, and binary placeholders — small API, wide reuse.
- Review-loop UX is complete, not decorative: batch reviews with verdicts, viewed-state synced
  through GitHub's own GraphQL mutations (interoperable with the native UI), auto-collapse of
  viewed files, jump-to-next-unviewed, orphaned-thread surfacing.
- Serious bundle/runtime discipline for a "wrapper" extension: post-build grammar pruning with
  import-graph traversal, worker-pool highlighting with an AST LRU cache, idle-callback item
  building gated on a measured large-PR predicate, content-fingerprinted memoization.
- Scroll anchoring around layout mutations is handled explicitly rather than hoped for.

## Weaknesses

- Entirely GitHub-shaped: no local git, no other forges, and the diff is whatever patch text
  GitHub emits — no context expansion, no whitespace-ignore, no re-diffing at different
  granularity, no moved-code detection.
- Single-snapshot review model: no per-commit or push-to-push (interdiff) views, no stacked-PR
  support; comments anchor to the head SHA only.
- The rendering core is a third-party dependency the project does not control (already patched
  once for a search-state bug), and its intra-line behavior is a black box from this tree.
- Full review flow requires a classic PAT (`repo` scope) because GitHub's GraphQL viewed-file
  mutations reject fine-grained tokens — a platform limitation, but user-visible.
- No tests anywhere in the tree (no test runner in `package.json`); correctness of e.g. the
  synthetic-patch builder rests on manual QA.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                   | Trade-off                                                                                       |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Consume GitHub's patch text instead of computing diffs             | Zero diff engine to maintain; byte-identical to what GitHub reviewed elsewhere              | Inherits GitHub's granularity and caps; no whitespace/structural options; forge lock-in         |
| Rent `@pierre/diffs`/`@pierre/trees` for all rendering             | A tiny team ships a polished split/unified, highlighted, virtual-feeling viewer immediately | Core behavior (intra-line, alignment) is upstream's; needed `patch-package` for a tree bug      |
| Iframe overlay on github.com rather than a separate app            | One click from the PR page; inherits the user's session for the `.diff` fallback            | Extension CSP/same-origin gymnastics (portable worker, ASCII-escaped scripts)                   |
| Four-stage diff-source fallback ending in synthetic patch assembly | Some diff always renders, even past the 300-file / 1 MB API caps                            | Fallback output can lack hunks for renames/large files; four code paths to keep honest          |
| Annotations as the single extension channel                        | Comments, drafts, batch queue, and image diffs share one typed mechanism                    | Media-as-annotation is a hack (zero-line diff shells with fabricated `FileDiffMetadata`)        |
| Batch reviews + viewed state via GitHub's own APIs                 | State interoperates with the native UI; nothing proprietary to sync                         | Classic-PAT requirement for GraphQL mutations; client-side thread reconstruction from flat data |
| `staleTime: Infinity` caching keyed by head SHA + comment digest   | Reopening a PR is instant; explicit Refresh action controls staleness                       | New pushes/comments invisible until manual refresh or key change                                |

## Sources

- Local checkout at `/home/petar/code/repos/typescript/diffy`, revision
  `27cdcc9a28c1cf59df3b9e9d84ed0ec1c53acb9c` (2026-07-23): `README.md`, `CHANGELOG.md`,
  `wxt.config.ts`, `src/lib/github/api.ts`, `src/lib/code-view/build-items.ts`,
  `src/lib/review/comments.ts`, `src/lib/github/review-write.ts`, `src/lib/github/graphql.ts`,
  `src/lib/diff/display-prefs.ts`, `src/lib/diff/worker.ts`, `src/modules/shiki-pruner.ts`,
  `src/providers/PersistentWorkerPoolShell.tsx`, `src/lib/code-view/scroll-anchor.ts`,
  `src/hooks/useCodeViewItems.ts`, `src/hooks/useViewedFiles.ts`,
  `src/components/diff/DiffOverlay.tsx`, `patches/@pierre__trees.patch`
- [diffy repository][diffy-repo] (upstream)
- [Chrome Web Store listing][chrome-store]
- [Pierre Diffs][diffs-site] and [Pierre Trees][trees-site] (the rendering libraries)
- [`@pierre/diffs` on npm][pierre-diffs-npm]

<!-- References -->

[diffy-repo]: https://github.com/suveshmoza/diffy
[chrome-store]: https://chromewebstore.google.com/detail/diffy/oaakiockkfndnholpbeijclfbnldnpfn
[diffs-site]: https://diffs.com
[trees-site]: https://trees.software
[pierre-diffs-npm]: https://www.npmjs.com/package/@pierre/diffs
