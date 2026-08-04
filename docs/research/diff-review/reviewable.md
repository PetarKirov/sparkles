# Reviewable (proprietary web SaaS, JavaScript/Node.js)

A GitHub-only code-review web app whose defining ideas are an immutable _revision_ timeline per PR (surviving rebases and force-pushes), a per-reviewer file×revision review-state matrix, and diffing between **any** two revisions with base-branch noise classified out.

| Field          | Value                                                                                                                                                                                      |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language       | JavaScript (browser client + Node.js servers); Firebase Realtime Database datastore                                                                                                        |
| License        | Proprietary SaaS; "All public repositories and personal private repositories can use Reviewable free of charge forever" ([subscriptions][docs-subscriptions]); self-hosted Enterprise tier |
| Repository     | Closed source; [`Reviewable/Reviewable`][gh-repo] is the public issue tracker + `CHANGELOG.md` + example completion conditions                                                             |
| Documentation  | [docs.reviewable.io][docs-index]                                                                                                                                                           |
| Category       | web-review                                                                                                                                                                                 |
| First release  | 2015 ("Founded in 2015 by former Google engineers", [reviewable.io][landing])                                                                                                              |
| Latest release | Continuously deployed SaaS; public changelog current through August 2026 (commit `39c09219e5ae509df6094526b11eed8576b9fbde`, 2026-08-03)                                                   |

> [!NOTE]
> Reviewable's client and server are closed source, so everything below is
> reconstructed from official docs, the public `CHANGELOG.md` (which tags every
> entry `client NNNN` or `server NNNN`, incidentally revealing where each
> feature lives), and the vendor blog. No third-party code was inspected.

## Overview

### What it solves

GitHub's built-in PR review loses reviewer state on force-push, has no notion
of "which version of this file did I already read", and resolves comment
threads by fiat rather than agreement. Reviewable's whole design is an answer
to those three losses. The docs index states the pitch directly: it "clearly
shows net deltas since last time you looked, even if commits get rebased or
amended" and tracks "who reviewed which revision of each file to ensure that
no changes are missed" ([docs.reviewable.io][docs-index]). Discussions
"stay visible until everyone involved reaches an agreement and marks them
resolved. This state is independent of any file changes"
([discussions][docs-discussions]).

### Design philosophy

Three principles recur across the docs:

- **Review state is durable data, not UI ephemera.** Each pushed state of the
  PR becomes a _revision_ — "an automatic, unmodifiable capture of one or more
  commits" ([reviews][docs-reviews]) — and every reviewer's "reviewed" mark is
  recorded against a specific `(file, revision)` cell. Force-pushed-away
  revisions are "preserved and marked as obsolete (with a strikethrough)"
  ([files][docs-files]) rather than deleted, and each revision's commits stay
  fetchable via `git fetch origin refs/reviewable/pr[ID]/r[revision]`
  ([tips][docs-tips]).
- **Resolution is a computed consensus, not a button.** "A discussion is
  considered resolved when at least one participant is **Satisfied** or
  **Informing**, and no participants are **Blocking** or **Working**"
  ([discussions][docs-discussions]) — a small per-participant state machine
  replacing GitHub's unilateral "Resolve conversation".
- **Mergeability is programmable.** A repository can install "a custom review
  completion condition" — arbitrary JavaScript deciding `completed: true` —
  instead of a fixed approval count ([reviews][docs-reviews]).

## How it works

### 1. Diff computation & data model

The unit of the data model is the **revision**: the server watches GitHub
webhooks and snapshots each pushed head into "an automatic, unmodifiable
capture of one or more commits" ([reviews][docs-reviews]). Revisions come in
three flavors ([files][docs-files]): _provisional_ (italic — recent pushes
that "may still change up to the point at which someone begins reviewing",
so an author self-reviewing and pushing fixes doesn't mint a revision per
push), _immutable_, and _obsolete_ (struck through — no longer in the PR
"due to being force-pushed out", but still viewable and diffable). A
repository setting controls "whether no-changes rebase and/or merge commits
can be added to a snapshotted revision" ([changelog][changelog], server 4885).

Rebase correspondence is heuristic, and the changelog is candid about it: a
2022 entry "redesign[s] the algorithm that determines whether a revision has
probably been rebased, and from what corresponding original revision. The new
logic is simpler … but may exhibit a different pattern of false positives and
negatives in more complex ones" ([changelog][changelog]). Earlier entries show
the signal set: commit-message matching including "Gerrit-style `Change-Id`
headers", "de-prioritize distance in favor of other signals", and "improve
heuristic mapping of prior revisions for interactive rebases with fixups"
([changelog][changelog]).

Text diffs are computed **in the browser client** — every diff bugfix in the
changelog is tagged `client` (e.g. "don't crash if a unknown language is
encountered when diffing", client 7709). The published algorithm identity
(Myers vs histogram etc.) is not documented; what _is_ documented is the
cross-base classification layered on top: when diffing two revisions with
different bases, each line is decided to be a base change or a PR change
("when diffing two revisions with different bases, do a better job of
deciding which lines are base changes and which are not", [changelog][changelog]),
and "changes between the old and new base will automatically collapse in the
diff so as to avoid distraction from deltas that don't relate to this PR"
([files][docs-files]). The client further renders a per-cell verdict on how
well base changes were absorbed: "detect base changes between file revisions
and distinguish between cleanly integrated ones (green), cleanly integrated
with extra unrelated edits (grey), and potentially badly integrated (orange)"
([changelog][changelog], client 7700). Commit messages themselves are diffable
as a synthetic "virtual Commits file", with "metadata-only diffs … hidden …
when commits were rebased without changing the commit message"
([changelog][changelog]).

### 2. Rendering & layout

Layout is responsive rather than modal: "As you decrease the width of the
browser window, the diff panels will convert from a side-by-side view to a
unified view and vice-versa" ([files][docs-files]), overridable (`Single`
forces unified) along with a user-set wrap column for long lines. Syntax
highlighting is `highlight.js` (updated to v11.11.1 in the changelog), with
language picked by extension map, `linguist-language` overrides in
`.gitattributes`, and even by "pars[ing] language identifiers out of shell
script shebang lines" ([changelog][changelog]).

The signature rendering surface is the **file matrix**: "a history matrix
showing all files and revisions" ([reviews][docs-reviews]) — rows are files,
columns are revisions, and each _revision cell_ is color/asterisk-coded for
changed/unchanged/reviewed/provisional/obsolete, with reviewer avatars and
open-discussion icons layered in. Diff bounds are direct-manipulation: "To
adjust the diff bounds, click on one desired revision bound and drag to the
other one" ([files][docs-files]), also settable per-file, in bulk from the
matrix header, or via URL anchors like `#r3..r5` ([tips][docs-tips]).

### 3. Intra-line & noise handling

Intra-line refinement exists but is under-documented; the changelog confirms
character-level highlighting ("make sure all single character deltas get
special highlighting"; "make single character diffs more visible in two column
mode" — [changelog][changelog]). Noise handling is comparatively rich:

- **Whitespace**: lines with only whitespace changes are flagged with a `␣`
  marker, and a per-review toggle "collapse[s] whitespace changes in all files
  in this review", persisting as the user's default ([files][docs-files]).
  Notably the suppression is _semantics-aware_: "don't hide significant
  whitespace deltas by default (e.g., whitespace changes in string literals)"
  ([changelog][changelog]) — pure indentation churn is collapsible, but
  whitespace that changes program meaning is not.
- **Generated/minified files**: Reviewable "respect[s] `.gitattributes` `diff`
  attributes to suppress diffing of, e.g., generated files, or force diffing /
  pick syntax highlighting language", supports `linguist-generated`, auto-adds
  known lockfiles (e.g. Poetry) to the generated set, and detects minified
  files heuristically ([changelog][changelog]).
- **Base-branch noise**: the rebase classification above is itself a noise
  filter — the whole point is that a post-rebase diff shows only the author's
  delta.
- **Moved-code detection**: not present in docs or changelog; the file matrix
  does auto-group _renamed_ and _reverted_ files ([changelog][changelog]), but
  intra-file block-move detection is absent.

### 4. Navigation, folding & scale

The UX is keyboard-first: "Type `?` to display a popup that lists the current
bindings" ([reviews][docs-reviews]), and every command is rebindable in
Account Settings (commands exist that ship unbound, e.g. first/last unreviewed
file). Default bindings (from a user-captured cheatsheet,
[psanford's gist][gist]) include `j`/`k` next/previous **unreviewed** file,
`m` mark file reviewed, `.`/`,` next/previous item needing attention,
`r`/`enter` reply, `d` reply "Done", `y` acknowledge, and single keys for
setting dispositions. The driving loop is "Show Unreviewed Diffs": when new
revisions arrive, one keystroke re-bounds every file's diff to _your_ last
reviewed revision → latest ([reviews][docs-reviews]); the file matrix also
offers "diff since the last review by a specific reviewer" and "diff since
the last review by anyone" ([changelog][changelog]).

Unchanged regions are collapsed with "Expand tabs" for manual context reveal,
including expansion "by syntactic units, collapsed line categories, or
complete files" ([files][docs-files]). Scale guards are explicit: "Reviewable
automatically enters a single file mode to preserve performance when the
number of visible files exceeds a threshold (configurable in the diffs panel
preferences)" ([files][docs-files]); the file matrix auto-collapses when large,
groups of 200+ files auto-collapse, and earlier revision columns collapse when
they don't fit ([changelog][changelog]). Binary/image diffs are punted: "For
images and other file types you'll need to go view the diff on GitHub"
([files][docs-files]).

### 5. VCS & review integration

Reviewable is a pure GitHub overlay — no other forge, no local git plumbing on
the user's machine. The server syncs PRs via webhooks and the GitHub API,
mirrors review status back as a commit status / check, and preserves every
revision's commits under `refs/reviewable/pr[ID]/r[revision]` in the repo
itself so obsolete revisions remain fetchable ([tips][docs-tips]). Merging
happens from the UI with GitHub's merge styles; "When using the rebase merge
style, Reviewable will indicate if the merge will be a fast-forward"
([reviews][docs-reviews]). Unresolved merge-conflict markers are flagged in
the diff ([changelog][changelog]). There is no staging or hunk-selection —
it is a read/review tool, not an editor.

Line comments are **discussions** with per-participant _dispositions_
(Discussing / Blocking / Working / Satisfied / Informing, plus passive states
like Pondering) and mechanical resolution as quoted above
([discussions][docs-discussions]). Discussions are line-anchored and re-mapped
across revisions: a discussion "will also appear in the diffs of other
revisions, at the nearest corresponding line. It won't disappear until that
discussion is resolved", with a red dog-ear warning "that the current context
may be inaccurate because of significant changes" ([files][docs-files]).
Everything drafts locally and publishes as one batch (one notification).
Review completion is either the default — "all files have been marked
reviewed by at least one person at the most recent revision, and all
discussions have been resolved" ([reviews][docs-reviews]) — or a custom
JavaScript condition fed a rich input structure (per-file review state,
`.gitattributes` maps, `baseChangesOnly` flags, sentiments). Stacked PRs are
supported via [`spr`][blog-spr] tracking: Reviewable links stack members in the
top-level discussion and marks child PRs (which `spr` closes rather than
merges) with "whether it's actually been merged into the head of stack".
A commit-by-commit review style sets per-commit diff bounds, with matching
revision sequences collapsed after rebases "to avoid forcing a review of lots
of empty diffs" ([changelog][changelog]).

### 6. Architecture & reuse

The architecture visible through docs and changelog: a thick browser client
(diffing, highlighting, base-change classification, drafts — all `client`-
tagged) over **Firebase Realtime Database** as the primary datastore, with
Node.js servers doing GitHub sync, revision snapshotting, rebase matching, and
completion-condition execution (`server`-tagged; Enterprise runs the same
stack self-hosted, optionally with AWS Lambda for custom conditions). The
[abnormal-conditions doc][docs-abnormal] shows how load-bearing Firebase is:
the client monitors "the socket itself, the latency of every write, and the
latency of obtaining permissions" and blocks the app on degradation. Recent
releases add **agent identities and an MCP server** ([agents][docs-agents]):
the `reviewable` npm package runs as an MCP server or CLI, exposing revisions,
per-file review status, and draft discussions/review marks to LLM reviewer
agents under author/reviewer/replicant sub-identities — notably it requires
Chrome/Chromium, i.e. it drives the real web client headlessly rather than a
separate API surface.

Nothing is reusable as code (closed source). The reusable ideas are the data
model: revision snapshots with obsolete-preservation via hidden git refs, the
`(file × revision × reviewer)` mark matrix, disposition-based resolution, and
base-change line classification with the green/grey/orange integration verdict.

## Strengths

- The file×revision×reviewer matrix makes "what haven't I seen yet" a queryable
  fact; "Show Unreviewed Diffs" turns multi-round review into one keystroke.
- Rebase/force-push handling is best-in-class among GitHub overlays: obsolete
  revisions preserved (and git-fetchable), heuristic prior matching, base-branch
  deltas collapsed, and an explicit integration-quality verdict per cell.
- Discussion dispositions replace unilateral thread-resolution with computed
  consensus, and line-mapped threads survive pushes "until resolved, not just
  until changes are pushed".
- Deep noise controls: semantics-aware whitespace collapse, `.gitattributes`
  `diff`/`linguist-generated` suppression, minified-file detection.
- Fully rebindable keyboard-driven UX with a `?` cheatsheet.
- Programmable completion conditions (JavaScript) and stacked-PR (`spr`)
  awareness.

## Weaknesses

- Closed source, GitHub-only, and architecturally welded to Firebase (the
  changelog is a decade-long log of Firebase latency/transaction/bandwidth
  firefighting).
- Rebase correspondence is heuristic and admits "false positives and
  negatives in more complex" histories — there is no ground-truth revision
  graph, only inference.
- Diff engine details are opaque; intra-line refinement appears limited to
  character-delta emphasis (no documented word-level algorithm, no moved-code
  detection).
- Text-only diffs; images and binaries defer to GitHub.
- Scale is managed by degradation (single-file mode, matrix auto-collapse)
  rather than virtualization of the full view.
- The UI's information density (matrix, dispositions, bounds) has a real
  learning curve compared to GitHub's native review.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                 | Trade-off                                                                                      |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Immutable revision snapshots + `refs/reviewable/*` preservation | Review state survives force-push; any historic state diffable and fetchable               | Writes refs into user repos; storage grows with every push                                     |
| Rebase matching by heuristic (messages, `Change-Id`, distance)  | No workflow change demanded of authors (unlike Gerrit's mandatory `Change-Id`)            | Misidentification possible in complex interactive rebases; algorithm needed repeated redesigns |
| Base-change line classification inside cross-base diffs         | Post-rebase reviews show only the author's delta — the tool's core value                  | Client-side complexity; "mergeable block range mismatch" class of bugs in the changelog        |
| Per-reviewer `(file, revision)` marks, not per-PR approval      | "No changes are missed"; completion computable per file at latest revision                | Requires reviewers to actively mark files; more state to present (hence the matrix)            |
| Disposition-based consensus resolution                          | Threads can't be dismissed unilaterally; "waiting on" list derives automatically          | Five-plus states per participant is heavier than resolve/unresolve                             |
| Diff + highlight computed in the browser client                 | Server stays a thin sync layer; instant re-bounding between arbitrary revisions           | Large PRs hit client limits → single-file mode, matrix collapse thresholds                     |
| Firebase Realtime Database as datastore                         | Live multi-user sync and offline drafts nearly for free in 2015                           | Deep vendor coupling; connection health becomes a first-class failure mode                     |
| Completion conditions as user JavaScript                        | Arbitrary org policy (LGTM emojis, CODEOWNERS-like rules) without vendor feature requests | Security/sandboxing burden (AWS Lambda option, encryption incident in changelog)               |

## Sources

- [Reviewable documentation index][docs-index] — product framing, section map
- [Code review discussions][docs-discussions] — discussion/disposition/resolution model
- [Code review files][docs-files] — file matrix, revision cells, diff bounds, rebase collapse, whitespace toggle, single-file mode
- [Code reviews][docs-reviews] — revisions, completion, keyboard shortcuts, sidebar/matrices
- [Tips and tricks][docs-tips] — `refs/reviewable/...` fetch, `#r3..r5` URL bounds
- [Abnormal conditions][docs-abnormal] — Firebase dependence, failure handling
- [Agent identities & MCP server][docs-agents] — agent sub-identities, `reviewable` npm CLI/MCP
- [Subscriptions & licenses][docs-subscriptions] — pricing/licensing model
- [Public changelog][changelog] (pinned) — rebase-algorithm redesign, base-change verdict colors, whitespace/generated-file handling, `highlight.js`, `spr`, per-entry client/server attribution
- [Blog: Support for git spr stacked pull requests][blog-spr]
- [reviewable.io landing page][landing] — founding, positioning
- [Community keyboard-shortcut capture][gist] — default key bindings

<!-- References -->

[docs-index]: https://docs.reviewable.io/
[docs-reviews]: https://docs.reviewable.io/reviews.html
[docs-files]: https://docs.reviewable.io/files.html
[docs-discussions]: https://docs.reviewable.io/discussions.html
[docs-tips]: https://docs.reviewable.io/tips.html
[docs-abnormal]: https://docs.reviewable.io/abnormal.html
[docs-agents]: https://docs.reviewable.io/agents.html
[docs-subscriptions]: https://docs.reviewable.io/subscriptions.html
[landing]: https://www.reviewable.io/
[blog-spr]: https://www.reviewable.io/blog/support-for-git-spr-stacked-pull-requests/
[gh-repo]: https://github.com/Reviewable/Reviewable
[changelog]: https://github.com/Reviewable/Reviewable/blob/39c09219e5ae509df6094526b11eed8576b9fbde/CHANGELOG.md
[gist]: https://gist.github.com/psanford/8ed59ae471b2d9d4524dc5a2cfc03d66/ef9307dee384cea32951c3f53758b242e1f3ef86
