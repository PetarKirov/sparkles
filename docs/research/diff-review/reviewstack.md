# ReviewStack (TypeScript/React)

A serverless single-page web app for reviewing GitHub pull requests with first-class stacked-PR
support: it re-implements diffing, syntax highlighting, and version comparison entirely in the
browser on top of raw git objects fetched from GitHub's APIs.

| Field             | Value                                                                                             |
| ----------------- | ------------------------------------------------------------------------------------------------- |
| Language          | TypeScript (React 18, Primer React design system)                                                 |
| License           | MIT                                                                                               |
| Repository        | <https://github.com/facebook/sapling> (`eden/contrib/reviewstack`)                                |
| Documentation     | <https://sapling-scm.com/docs/addons/reviewstack>                                                 |
| Category          | web-review                                                                                        |
| First release     | November 2022 (announced with Sapling's open-sourcing)                                            |
| Latest release    | Unversioned (`package.json` says `0.1.0`, `private: true`); deployed at <https://reviewstack.dev> |
| Surveyed revision | `c12607104095061ca93ee0539285445785f0f2f7` (2026-08-03)                                           |

> [!NOTE]
> This survey covers `eden/contrib/reviewstack` (the library) plus the pieces of the sibling
> `shared` package it imports (`shared/SplitDiffView/organizeLinesIntoGroups.ts`,
> `shared/createTokenizedIntralineDiff.tsx`, `shared/textmate-lib/`). The `reviewstack.dev`
> directory is a thin CRA-style host app and is not analyzed separately. All bare paths below
> are relative to `eden/contrib/reviewstack`.

## Overview

### What it solves

GitHub's own PR review UI has no concept of a _stack_ of dependent PRs, and its "changes since
last review" support is weak once a branch is rebased. ReviewStack is Sapling's answer for
GitHub-hosted review: a web UI that (a) recognizes stack metadata that `sl pr` (Sapling) and
`ghstack` write into PR bodies, (b) reconstructs per-PR _versions_ from force-push events in the
PR timeline, and (c) can diff two versions of a PR even across a rebase — all without any server
of its own. Per `README.md`: "Note that it has _no server component_ (though it does leverage
Netlify's OAuth signing to authenticate with GitHub)."

### Design philosophy

`README.md` states the positioning: "[ReviewStack] is a novel user interface for GitHub pull
requests with custom support for _stacked changes_. The user experience is inspired by Meta's
internal code review tool, but leverages GitHub's design system to achieve a look and feel that
is familiar to GitHub users."

Two consequences drive the whole architecture:

- **The client is the diff engine.** GitHub's GraphQL API serves raw git objects (commits,
  trees, blobs) but not arbitrary comparisons, so ReviewStack fetches objects and computes tree
  diffs, line diffs, intraline diffs, and syntax highlighting itself, in the browser.
- **Aggressive local caching is a correctness-of-budget concern.** The `GitHubClient` interface
  doc (`src/github/GitHubClient.ts`) is explicit: "GitHub APIs have various quotas. … As such,
  using local caching or perhaps even reading from a local clone via the HTML5 FileSystem API
  could be used to help stay within GitHub quota." Immutable git objects are cached in
  IndexedDB keyed by OID, shared between the main thread and workers.

## How it works

### 1. Diff computation & data model

Diffing happens at two granularities, both client-side:

- **Tree-level diff** (`src/github/diff.ts`): `diffCommits` walks the two commits' git trees
  with a classic sorted merge-join (`compareTreeEntry` returns
  `'less' | 'greater' | 'equal' | 'changed'` on `(name, oid, mode, type)`), recursing into
  subtrees only when their OIDs differ and emitting a flat, depth-first pre-ordered
  `Diff = CommitChange[]` of `{type: 'add'|'remove'|'modify', basePath, entry|before/after}`
  records. Unchanged subtrees are skipped entirely because equal OIDs prove equality — the
  same trick a native git implementation uses, done over GraphQL-fetched `Tree` objects.
- **File-level line diff** (`src/diffServiceWorker.ts`): the [`diff`][jsdiff] npm package
  (jsdiff, Myers O(ND)) computes `structuredPatch(before, after, {context: 3})` on the two
  blob texts. `NUM_LINES_OF_CONTEXT = 3` (`src/constants.ts`) deliberately matches GitHub's
  own hunk layout (see §5 on comment positions).

Two derived diff computations are notable:

- **Version-to-version diff across rebases** (`src/github/diffVersions.ts` +
  `gitHubPullRequestVersionDiffAtom` in `src/jotai/atoms.ts`): if the user compares PR version
  V1 against V2 and both have the _same_ merge-base, the versions are diffed directly as two
  commits. If the bases differ (a rebase happened), ReviewStack computes each version's diff
  against _its own_ base and then merges the two `Diff` lists path-by-path — a **diff of
  diffs**. `diffVersions` inverts changes present only in the before-diff (`createInverse`)
  and case-analyzes `add/remove/modify × add/remove/modify` collisions (e.g. "add in V1,
  modify in V2 ⇒ V2 was rebased onto a commit where the file already exists ⇒ report modify").
  This is how "what changed since your last review" survives a rebase without any server-side
  help.
- **Merge-base discovery** uses GitHub's REST `compare` endpoint
  (`src/github/GraphQLGitHubClient.ts`: "The GitHub GraphQL API v4 does not appear to support
  comparison of two commits") to obtain `merge_base_commit` plus the branch's commit list.

### 2. Rendering & layout

Side-by-side only, as a plain HTML `<table>` with a 4-column `<colgroup>` (`50px` gutter /
`50%` code / `50px` gutter / `50%` code) — no virtualization, no canvas, no Monaco (a
`monaco-editor` dependency lingers in `package.json` but nothing in `src/` imports it).
`src/SplitDiffView.tsx` converts each hunk to rows via
`shared/SplitDiffView/organizeLinesIntoGroups.ts`, which splits a hunk's lines into groups of
(common\*, removed\*, added\*); within a group, removed/added lines are **paired by index** —
row _i_ shows `removed[i]` on the left and `added[i]` on the right as a `modify` row with
intraline highlighting, and the longer side runs on alone. This is alignment-by-position, not
by similarity: there is no cross-pane line-matching heuristic beyond what Myers grouping gives.

Syntax highlighting is VS Code's stack compiled to the web: `vscode-textmate` grammars driven
by the `vscode-oniguruma` WASM regex engine, with `VSCodeLightPlusTheme` / `VSCodeDarkPlusTheme`
(`src/textmate/`). A generated `TextMateGrammarManifest` plus `FilepathClassifier` maps file
paths to TextMate scope names. Files are tokenized **whole** (both versions) in the worker
(`tokenizeFileContents`), and `applyTokenizationToLine` re-applies token color spans per
rendered line; tokenization failure (the WASM engine "can crash with 'memory access out of
bounds' on large or problematic files", `src/diffServiceWorker.ts`) degrades to plain text.
Theme is a two-state Primer `colorMode` (`day`/`night`); each mode gets its own grammar store
and color map.

### 3. Intra-line & noise handling

Modified row pairs get an intraline diff, computed one of two ways
(`src/SplitDiffView.tsx`):

- **Plain path**: jsdiff `diffChars(before, after)` — character-level; added/removed runs are
  wrapped in `patch-add-word` / `patch-remove-word` spans.
- **Tokenized path** (`shared/createTokenizedIntralineDiff.tsx`): jsdiff `diffWordsWithSpace`
  produces word-level chunks which are then _interleaved_ with the TextMate token spans, so a
  changed word keeps its syntax color inside the add/remove background — a two-layer span
  merge (chunk boundaries × token boundaries) rather than one overwriting the other.

Both paths are guarded by `MAX_INPUT_LENGTH_FOR_INTRALINE_DIFF = 300` (sum of both line
lengths); the comment justifies it against Myers pathology ("a large blob of JSON on a single
line … could be an expensive diff to compute while telling the user nothing of interest") and
compares with VS Code's _time-budget_ approach to tokenization, flagged as worth adopting.

There is **no whitespace-ignore option, no formatting-noise classification, and no moved-code
detection** anywhere in the tree — the diff is exactly what jsdiff's default Myers emits.
For a review tool this is a real gap (a rebase-noise problem is solved at the _version_ level
by `diffVersions`, but line-level noise inside one version is untreated).

### 4. Navigation, folding & scale

- **Context folding**: unchanged regions between hunks render as a `HunkSeparator` row
  ("Expand N lines"); clicking swaps in an `ExpandingSeparator` that fetches the hidden line
  range _from the locally cached blob_ via the worker's `lineRange` method (never from the
  network) and renders it inline. Leading and trailing unchanged regions are folded too — with
  the caveat, noted in a comment, that the file's total line count is only known when
  tokenization succeeded, so the trailing separator silently disappears for unhighlighted
  files.
- **Large-diff guard**: a file whose hunks contain more than `LARGE_DIFF_LINE_THRESHOLD = 500`
  lines renders a `LargeDiffPlaceholder` ("Load diff") instead of rows until clicked
  (`src/SplitDiffView.tsx`); per-file headers are collapsible. There is no virtualization, so
  a loaded large file still materializes every `<tr>`.
- **Navigation**: files are a sequential list (no file-tree panel). Keyboard shortcuts
  (`src/KeyboardShortcuts.ts`) are review-centric: `⇧N`/`⇧P` move to the next/previous PR _in
  the stack_, `⌥A`/`⌥C`/`⌥R` approve/comment/request-changes, `⌘.` toggles the timeline
  sidebar.
- **Binary/oversize files**: blob text is sniffed with `hasBinaryContent.ts`; GitHub's blob
  API `isTruncated` flag is carried but (per a `TODO`) not fully handled.

### 5. VCS & review integration

There is no local VCS at all — "git plumbing" is GitHub's API surface:

- **GraphQL** (generated typed client via `graphql-codegen`; queries in `src/queries/`) for
  the PR (timeline items, review threads, reviews, labels, check runs), commits, and trees.
- **REST** where GraphQL has holes, each documented in `src/github/GraphQLGitHubClient.ts`:
  `/git/blobs/:oid` (GraphQL "does not appear to support fetching the content for binary
  blobs") and `/compare/:base...:head` for merge-bases.
- **Caching**: `CachingGitHubClient` wraps any `GitHubClient` with IndexedDB object stores
  `commit` / `tree` / `blob` / `pr-fragment`, keyed by OID (immutable ⇒ trivially cacheable);
  duplicate-key insert races are counted and tolerated. The SharedWorker gets a
  `CachingGitHubClient` wrapped around a `RejectingGitHubClient`, i.e. **cache-only**: the
  main thread is responsible for fetching blobs before asking the worker to diff them
  ("It is paramount that the blob for each non-null GitObjectID is written to indexedDB so it
  can be read by a Web Worker", `src/SplitDiffView.tsx`). Logout broadcasts across tabs and
  drops the whole database.
- **Versions**: each `HeadRefForcePushedEvent` in the PR timeline contributes a version
  (`gitHubPullRequestVersionsAtom`); the current head is the latest version. A version
  selector lists "Version N · date · M commits · comment count"; a separate
  `ComparableVersions {beforeCommitID | null, afterCommitID}` pair drives the diff, so the
  user can view any version against its base or any two versions against each other (§1).
- **Stacks**: `stackedPullRequestAtom` parses the PR _body_ — `src/saplingStack.ts` recognizes
  the Sapling footer (`[//]: # (BEGIN SAPLING FOOTER)` in `prefix` or `hr-suffix` position,
  a bullet list of `#PR` entries with the current one marked `__->__`, optional
  `(N commits)` counts), and `src/ghstackUtils.ts` recognizes ghstack's
  `Stack from [ghstack]` header. The stack's other PRs are fetched in one batched query
  (`getStackPullRequests`) and rendered as a navigable stack panel; for a non-bottom stack
  entry, the diff base is **the parent PR's `headRefOid`**, not the repo's main branch —
  the key trick that makes each stacked PR show only its own commits. Sapling stacks also
  special-case multi-commit PRs, slicing the shared commit list by each entry's
  `numCommits`.
- **Comments**: review threads come from GraphQL `reviewThreads`, are grouped per side
  (`DiffSide.Left/Right`) and by `originalLine`, and render inline under the matching
  `SplitDiffRow`; clicking a line number opens an inline comment input. Because GitHub's
  comment-anchoring REST concept of _position_ is "lines below the first `@@` header",
  `src/lineToPosition.ts` **regenerates the patch with the same 3-line context GitHub uses**
  and walks it to produce a `line → position` map per side — reproducing GitHub's diff
  byte-for-byte in-browser so mutations (`addPullRequestReviewComment`,
  `submitPullRequestReview`, …) anchor correctly. Pending reviews, approvals, labels, and
  reviewer requests are all GraphQL mutations (`src/mutations/`).
- Merge/conflict handling and staging/hunk-selection do not exist — ReviewStack is
  read-and-review only; landing happens elsewhere (CLI/GitHub).

### 6. Architecture & reuse

Process model: a React SPA plus a **SharedWorker** (`src/diffServiceWorker.ts`) doing the
heavy lifting (line diff, whole-file tokenization, line-range extraction, `lineToPosition`)
over a tiny JSON-RPC-ish `postMessage` protocol with request-availability broadcast to
coordinate multiple tabs. State is Jotai atoms (`src/jotai/atoms.ts`, ~2000 lines, migrated
from Recoil — comments still narrate the migration); async derived atoms compose the whole
pipeline declaratively: `pullRequest → forcePushes → versions → comparableVersions →
versionDiff → per-file diffAndTokenize`. Libraries: jsdiff (all diffing), vscode-textmate +
vscode-oniguruma (highlighting), Primer React (UI), graphql-codegen (typed API), jotai.

Relationship to Sapling's ISL: the reusable diff-view layer lives in the sibling `shared`
package (`addons/shared`, mirrored at `eden/contrib/shared`) — `organizeLinesIntoGroups`,
`createTokenizedIntralineDiff`, the textmate-lib, keyboard-shortcut dispatcher — and ISL's
`ComparisonView/SplitDiffView` builds on the same pieces. ReviewStack was effectively the
incubator for the split-diff componentry ISL now uses; the GitHub-object-model layer
(`GitHubClient` + caching + version/stack atoms) is ReviewStack-specific but cleanly seamed
behind the `GitHubClient` interface (`GraphQL`, `Caching`, `Rejecting`, `Test`
implementations).

Reusable ideas: OID-keyed immutable-object cache with a cache-only worker client; tree-diff
over lazily fetched trees; diff-of-diffs for rebase-invariant version comparison; PR-body
footers as a zero-infrastructure stack registry; token-span × diff-chunk interleaving.
Monolith-bound: the Jotai atom graph and Primer-specific rendering.

## Strengths

- **Rebase-aware version comparison** via merge-base equality check + `diffVersions`
  diff-of-diffs — a genuinely uncommon capability, done with zero server support.
- **Stack model needs no infrastructure**: PR bodies are the source of truth, parseable by
  any client; base selection per stack entry (parent PR head) keeps each diff minimal.
- **Immutable-object caching** by OID in IndexedDB is simple, correct, and makes repeat
  visits and context expansion nearly free of API quota.
- **Worker offload** of Myers diff + WASM tokenization keeps the UI thread responsive; the
  cache-only `RejectingGitHubClient` in the worker is a tidy capability-narrowing seam.
- Intraline diff that **preserves syntax coloring inside add/remove spans** (token × chunk
  interleave) with an explicit cost guard and a documented rationale.
- `lineToPosition` shows how to interoperate with a review platform's diff-anchored comments
  by reproducing its diff parameters exactly.

## Weaknesses

- **No noise controls at all**: no ignore-whitespace, no formatting-noise classification, no
  moved-code detection; intraline pairing is index-based, so an off-by-one insertion inside
  a changed block produces misleading pairings.
- **Scale ceiling**: full-file tokenization of both sides, no row virtualization, and a
  crude 500-line click-through guard; jsdiff Myers with no fallback for pathological inputs
  beyond the 300-char intraline cutoff.
- **GitHub-shaped everywhere**: versions come only from `HeadRefForcePushedEvent`s, blobs
  from a REST quirk, comment anchors from GitHub's `position` concept — nothing ports to
  another forge without rework.
- Trailing-context expansion silently unavailable when tokenization is absent (line count
  unknown); `isTruncated` blobs and sub-bullet stack entries are acknowledged `TODO`s.
- Effectively **maintenance-mode**: `0.1.0`, `private: true`, a stale Monaco dependency, and
  migration scaffolding comments left in place.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                         | Trade-off                                                                                         |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Serverless SPA; browser computes all diffs                 | Nothing to host/trust; works for any repo the token can read                      | Every capability is bounded by GitHub API shape and quota; heavy client                           |
| Tree-level diff over lazily fetched git objects            | Equal-OID pruning skips unchanged subtrees; objects are cacheable forever         | Many small requests on first visit; rename detection impossible without content comparison        |
| jsdiff (Myers) for lines, words, and chars                 | One well-known dependency; `structuredPatch` matches GitHub's hunk format         | No histogram/patience option; pathological cases handled by length cutoffs, not better algorithms |
| Versions reconstructed from force-push timeline events     | GitHub keeps pre-force-push commits reachable; no snapshot storage needed         | Depends on timeline completeness; non-force-push updates blur version boundaries                  |
| Diff-of-diffs (`diffVersions`) for cross-rebase comparison | Cancels rebase noise without a server-side interdiff                              | Case analysis is approximate (several documented edge cases return the raw change)                |
| Stack metadata embedded in PR bodies                       | Zero infrastructure; ghstack-compatible; human-readable fallback on github.com    | Fragile text parsing (HTML delimiter heuristics "will NOT work in the presence of sub-bullets")   |
| SharedWorker + cache-only client for diff/tokenize         | Off-main-thread; multiple tabs share one worker; worker can never spend API quota | Main thread must pre-populate IndexedDB; implicit ordering contract flagged as "paramount"        |
| VS Code TextMate/Oniguruma stack for highlighting          | Huge grammar coverage; exact VS Code fidelity                                     | WASM regex engine can crash on large files; whole-file tokenization cost; two fixed themes        |

## Sources

- `README.md` — positioning, serverless deployment, localStorage/IndexedDB warning
- `src/github/diff.ts`, `src/github/diffVersions.ts` — tree diff, diff-of-diffs
- `src/diffServiceWorker.ts`, `src/diffServiceClient.ts` — worker protocol, `structuredPatch`, tokenization
- `src/SplitDiffView.tsx`, `src/SplitDiffRow.tsx` — table layout, folding, intraline dispatch
- `eden/contrib/shared/createTokenizedIntralineDiff.tsx`, `eden/contrib/addons/shared/SplitDiffView/organizeLinesIntoGroups.ts` — shared diff-view layer (paths relative to the sapling repo root)
- `src/jotai/atoms.ts`, `src/jotai/README.md` — atom pipeline, versions, comparable versions, stack detection
- `src/saplingStack.ts`, `src/ghstackUtils.ts` — stack body formats
- `src/github/GitHubClient.ts`, `src/github/GraphQLGitHubClient.ts`, `src/github/CachingGitHubClient.ts` — API seam, REST fallbacks, IndexedDB cache
- `src/lineToPosition.ts` — GitHub comment-position reconstruction
- [ReviewStack docs][rs-docs] — hosted-instance overview

<!-- References -->

[jsdiff]: https://www.npmjs.com/package/diff
[rs-docs]: https://sapling-scm.com/docs/addons/reviewstack
