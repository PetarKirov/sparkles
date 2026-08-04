# Graphite (Web platform + TypeScript CLI)

Graphite is a proprietary stacked-PR platform layered on GitHub — a `gt` CLI that automates
creating/restacking dependency chains of branches, a web review app (PR inbox, stack-aware PR
page, version interdiffs), a stack-aware merge queue, and an AI review agent — positioning
itself as "the AI code review platform where teams ship higher quality code, faster"
([graphite.com][home]).

| Field          | Value                                                                                                                                                                                    |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | Web app: closed source (SaaS). CLI `gt`: TypeScript/Node (npm `@withgraphite/graphite-cli`); source now closed, developed in a private monorepo                                          |
| License        | Proprietary SaaS. Last open-source CLI engine survives in the [`freephite` fork][freephite] (AGPL-3.0, last commit 2023-10-06); [`language-services`][lang-services] archived 2023-07-16 |
| Repository     | None (closed). Historical: [`agrinman/freephite`][freephite] (fork of the archived `withgraphite/graphite-cli`), [`withgraphite/language-services`][lang-services]                       |
| Documentation  | [graphite.com/docs][docs] (note: `graphite.dev` 301-redirects to `graphite.com` since the 2025 rebrand)                                                                                  |
| Category       | Stacked-PR platform + CLI (`stacked-pr`)                                                                                                                                                 |
| First release  | CLI public beta 2021; Series B + "Diamond" AI reviewer launch 2025-03; Diamond renamed "Graphite Agent" 2025-10-08                                                                       |
| Latest release | Continuous SaaS; CLI ships continuously on npm ([CLI changelog][cli-changelog])                                                                                                          |

> [!NOTE]
> Web-only subject: no local checkout exists. Claims below cite official docs/blog URLs;
> the two GitHub links pin the last public commits of the archived repos
> (`fd2990a739de801d900e0af106640efac5fcd1b3` for `freephite`,
> `a2a594ed5232b1f3da8dcd68df65d75c2166e8ce` for `language-services`). Internal diff
> algorithms of the closed web app are inferred only where the docs say so; absences are
> reported as absences.

## Overview

### What it solves

GitHub models a pull request as one branch against one base and has no first-class notion of
a _chain_ of dependent PRs: merging the bottom of a chain squash-creates a new commit,
GitHub then sees "already-merged" content in every dependent PR, and authors hand-rebase
the survivors. Graphite makes the chain the primary object. The CLI is
"a tool to help you break up large engineering tasks into a series of small, incremental
code changes directly from the command line" ([CLI overview][cli-overview]); the web app
reviews and merges those chains as units, and the platform is "built on GitHub's APIs" so
every Graphite PR is still a real GitHub PR ([docs home][docs]).

### Design philosophy

Three commitments recur across the docs:

- **Stacking as the default workflow**, imported from Meta's Phabricator and Google's
  Critique lineage: the [stacked diffs guide][stacked-diffs-guide] contrasts stacks with
  "the traditional model where large changes are reviewed in a single, monolithic pull
  request" and traces the practice to Phabricator's Differential and Google's Critique.
- **Independence of each layer.** The reviewing guide's core directive:
  "Review a PR in a stack as though it was an independent change," and
  "Review stacked PRs as soon as you're tagged as a reviewer. Don't wait for downstack
  changes to be approved and merged, as this serializes reviews and greatly reduces the
  time savings of stacking" ([best practices for reviewing stacks][best-practices]).
- **Review speed over decoration.** From the 2025 PR-page redesign postmortem: "The main
  goal was a tidier visual experience. We wanted to reduce visual clutter, noise, redundant
  labels, and any unnecessary decorative elements"; and on floating comments: "Reviewers
  tend to read files line by line, top to bottom. But when a long comment thread breaks up
  the diff view, it disrupts them" ([PR page redesign][pr-redesign]).

## How it works

### 1. Diff computation & data model

The diff shown on the PR page is **server-computed by the closed web app from GitHub data**;
no algorithm (Myers/histogram/patience) is documented anywhere in the docs — an absence
worth recording for a survey: the product's differentiation is _around_ the diff, not _in_
it. The one public artifact is [`withgraphite/language-services`][lang-services]
("Core parts of our code to detect language, syntax highlight, and diff"), which in
practice contains only `ext-to-language`, "a simple library that maps extensions to
languages" for choosing highlighting — the diff engine itself was never published.

The distinctive part of the data model is **versions as first-class diffable states**:
"On first submit, a PR is `v1` and is incremented each time a PR is updated and submitted
through `gt submit`" ([PR versions][versions]). The compare dropdown lets the reviewer pick
"a version for the 'right' and 'left' sides of the diff", i.e. arbitrary interdiffs
(v2..v4), defaulting to v1..vN. Granularity is line-level with intra-line highlighting
visible in the product but undocumented.

On the CLI side there is no diff engine at all — `gt` shells out to git. Its data model is
branch metadata: the archived engine stores, per branch, a JSON blob written via
`git hash-object -w --stdin` and pointed at by `refs/branch-metadata/<branch>`, with schema
`{parentBranchName, parentBranchRevision, prInfo{number, base, url, title, body, state,
reviewDecision, isDraft}}` (`apps/cli/src/lib/engine/metadata_ref.ts` in the
[pinned `freephite` tree][freephite-metaref]). `parentBranchRevision` — the parent commit
the branch was last based on — is what makes `gt restack` deterministic: a branch is
"stacked" iff its recorded parent revision is in its history, and restacking is
`rebase --onto <newParentTip> <parentBranchRevision>`.

### 2. Rendering & layout

Split (side-by-side) view is the default — "changes to the PR are shown on the right, in
comparison to the base view on the left" — with a unified toggle in the PR header's `...`
menu ([update PRs][update-prs]; the toggle shipped in the [2023-02-15 changelog][cl-2023]).
Syntax highlighting is applied per file via the `ext-to-language` mapping. Two layout
decisions differ deliberately from GitHub:

- **Floating comments**: threads render _beside_ the diff rather than splicing into it, so
  the code column stays contiguous ([PR page redesign][pr-redesign]).
- **Stack strip above the diff**: the stack visualization is horizontal at the top of the
  page (a sidebar variant was tried and reverted for cramping information density —
  [PR page redesign][pr-redesign]); the version selector also sits "above the diff, making
  it easier to move across iterations."

A file tree is expanded by default (toggle `F`); collapsed, it degrades to a
"table of contents visualizer on the left side of the page" ([PR page overview][pr-page]).
Descriptions and comments use a rich-text editor (Markdown still accepted), explicitly to
lower the barrier for non-engineer reviewers ([PR page redesign][pr-redesign]).

### 3. Intra-line & noise handling

Intra-line highlighting exists in the product but has **no documented options**: no
ignore-whitespace toggle, no formatting-noise classification, no moved-code detection
anywhere in the docs (their [git-diff whitespace guide][ws-guide] teaches `git diff -w`,
i.e. the CLI, not their viewer). Graphite's answer to noise is _temporal and structural_
rather than textual:

- **"Hide reviewed changes"**: when a PR updates after your review, a banner offers to
  re-anchor the diff to "a comparison between the last reviewed version and the latest
  version" ([PR versions][versions]) — noise suppression by interdiff rather than by
  classifying hunks.
- **Stacking itself** is their noise-control story: mechanical churn (a rename, a format
  pass) goes in its own stack layer, reviewed once, instead of polluting the semantic PR
  ([how to structure stacks][structure-stacks]).
- **Upstack-change awareness**: "If code in the stacked PR you're reviewing changes again
  upstack (indicated by an orange bar on the right in Graphite), click to view the upstack
  change" ([best practices][best-practices]) — a gutter channel GitHub has no equivalent
  of: _this line you are approving is already modified later in the stack_.

Whether version interdiffs are rebase-aware (suppressing hunks that exist only because the
stack was restacked onto new trunk) is **not documented** — a notable gap, since restacks
are constant in this workflow and naive v(N-1)..vN diffs after a restack would be pure noise.

### 4. Navigation, folding & scale

Navigation is keyboard-first: `F` file tree, `V` toggles versions, review chords `R C` /
`R N` / `R A` / `R Y` (comment / request changes / approve / quick-approve), `Cmd+Enter`
submits, `Cmd+Shift+↓` walks down the stack, `Cmd+K` fuzzy-searches PRs "across PR title,
description, author, and more" ([PR page overview][pr-page]; [PR inbox][inbox]). Clicking a
file in the tree scrolls the single-column diff to it.

Above the single PR sits the **PR inbox** — "an 'email client' for your PRs" — with six
default sections (Needs your review / Approved / Returned to you / Merging and recently
merged / Drafts / Waiting for review), user-defined sections with custom filters, and
shareable section configs ([PR inbox][inbox]). This is triage-level navigation GitHub's
flat PR list lacks. Large-diff performance guards (virtualization, per-file lazy render)
are not documented.

### 5. VCS & review integration

This is the subject's center of mass.

**CLI stacking model.** `gt create` stacks a branch on the current one and commits staged
changes; `gt modify` "amend[s] its commit … Automatically restacks descendants";
`gt restack` "ensure[s] each branch in the current stack has its parent in its Git commit
history, rebasing if necessary"; `gt sync` pulls trunk, "prompting to delete any branches
for PRs that have been merged or closed," then restacks everything conflict-free
([command reference][cmd-ref]). History-surgery verbs treat the stack as an editable
sequence: `gt absorb` ("amend staged changes to the relevant commits in the current
stack" — an `hg absorb` clone that routes each hunk to the downstack commit that last
touched those lines), `gt split` (by commit, hunk, or file pattern), `gt fold`,
`gt move --onto`, `gt reorder` (editor buffer with one line per branch). `gt submit`
"idempotently force push[es] all branches in the current stack from trunk to the current
branch to GitHub, creating or updating distinct pull requests for each" — one PR per
branch, each based on its parent branch.

**Server-side stack maintenance.** Merging from the web app merges a prefix of the stack
(`Merge N` merges PRs 1..N), then Graphite "automatically rebases the remote branches
corresponding to the PRs 'upstack' of the one(s) you merged," staging through temporary
`graphite-base/*` branches so "there is never a moment where the new base of the stack
points to a branch or pull request that no longer exists" ([merge PRs][merge-prs]). It does
this via "a shallow clone of the repository" plus "Graphite's knowledge of the stack" —
cutting out the already-squash-merged commits that make GitHub misreport conflicts in
dependent PRs, while "Graphite can't resolve any legitimate merge conflicts as a result of
racing PRs." This upstack-repair loop is precisely what GitHub does not do.

**Merge queue.** Stack-aware: a whole stack enqueued together is "process[ed] and
validate[d] … in parallel," then landed by fast-forward without re-running per-PR CI;
"Parallel CI uses speculative execution, similar to branch prediction, to run CI for
multiple enqueued stacks at the same time" (claimed 1.5–2.5x faster merges), with batching
in beta ([merge queue][mq]; [optimizations][mq-opts]). "Merge when ready" is the automerge
analog: enabled on the top PR it offers to arm "all downstack PRs," each of which merges
independently as it becomes ready ([merge when ready][mwr]).

**AI review.** Graphite Agent (né Diamond, launched 2025-03 with the $52M Series B,
renamed 2025-10-08) "analyze[s] every pull request … identifying potential issues and
suggesting fixes instantly," claims codebase-wide context, one-click accepted fixes, and
per-team rule customization ([AI reviews][ai-reviews]; [Series B post][series-b];
[Agent rename][agent-rename]).

### 6. Architecture & reuse

Closed three-part SaaS: (a) the `gt` CLI — a Node program shelling out to git, whose entire
persistent state is the `refs/branch-metadata/*` JSON blobs plus a cache; (b) the web app
on GitHub's APIs; (c) server-side merge/queue machinery operating on shallow clones. The
CLI was open source through 2023 (`withgraphite/graphite-cli`), then archived —
"developing v1.0 of the Graphite CLI within their monorepo and leaving the public
repository archived as an artifact" — with the last open engine preserved in the AGPL
[`freephite` fork][freephite]. Reusable _ideas_ rather than reusable code:

- **Metadata-in-refs**: parent name + parent revision per branch, stored in git's own
  object store under a custom ref namespace — no sidecar files, survives clones that fetch
  the namespace, invisible to vanilla git. Directly implementable by any tool
  ([`metadata_ref.ts`][freephite-metaref]).
- **Versions + interdiff + "hide reviewed changes"** as a data model (GitLab and Gerrit
  have kin; GitHub's "changes since last review" is the weak form).
- **One-PR-per-branch bridging**: representing a stack on a host that lacks stacks, with a
  server janitor keeping bases correct through merges.

## Strengths

- The most complete productization of the Phabricator/Critique stacked-diff workflow on
  top of stock GitHub; every layer stays a normal GitHub PR (no lock-in of the record).
- `refs/branch-metadata` design is minimal and robust: two fields (`parentBranchName`,
  `parentBranchRevision`) are enough to make restacking deterministic and corruption
  detectable (`gt track` "can fix corrupted metadata" — [command reference][cmd-ref]).
- Review-workflow noise controls GitHub lacks: version interdiffs, "hide reviewed
  changes", the orange upstack-modification bar, floating comments that never break the
  code column.
- Stack-aware merge queue with speculative parallel CI and fast-forward stack landing —
  the queue understands the dependency DAG instead of a linear list.
- PR inbox turns review triage into a filterable, shareable, sectioned surface.
- Rich history-surgery verbs (`absorb`, `split`, `fold`, `reorder`, `move`) make
  "rewrite the stack to match reviewer feedback" cheap.

## Weaknesses

- Proprietary and hosted: the diff engine, versions store, and queue are unreproducible;
  the once-open CLI is closed (community forks like `freephite` froze at 2023).
- The textual diff layer is commodity: no documented ignore-whitespace, moved-code
  detection, structural/AST diffing, or formatting-noise classification — all noise
  handling is workflow-level (stacks + versions), none is content-level.
- No documented rebase-aware interdiff; after a restack, version compares may show trunk
  churn as PR churn.
- GitHub-only; `git` (not `gt`) users on the same repo can silently invalidate metadata
  (mitigated by `gt track`, but the failure mode exists).
- The platform's value concentrates in the server: offline/self-hosted review of a stack
  is not possible.

## Key design decisions and trade-offs

| Decision                                                                       | Rationale                                                                               | Trade-off                                                                                              |
| ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| One GitHub PR per stack branch, platform bridges the gaps                      | Stacks work on a host with no stack primitive; record of review stays on GitHub         | Server must perpetually repair bases (`graphite-base/*` janitor); N PRs of ceremony per logical change |
| Branch metadata as JSON blobs under `refs/branch-metadata/*`                   | No sidecar files; travels with the object store; vanilla git ignores it                 | Plain-`git` operations (rename, delete) desync it; needs `gt track` repair paths                       |
| `parentBranchRevision` recorded per branch                                     | Restack is a precise `rebase --onto` with a known base, detectable as needed/not-needed | Every stack mutation must rewrite metadata for descendants                                             |
| Versions (`v1..vN`) + arbitrary compare + hide-reviewed                        | Re-review cost scales with what changed, not PR size                                    | Version store lives server-side only; rebase noise in interdiffs apparently unaddressed                |
| Floating comments beside the diff                                              | Keeps the code column contiguous for top-to-bottom reading                              | Less thread context inline; horizontal space cost                                                      |
| Stack-aware merge queue with speculative parallel CI                           | 1.5–2.5x faster landings; trunk stays green; stacks land atomically via fast-forward    | Wasted CI on mis-speculation; queue is a hosted, closed component                                      |
| Noise control via workflow (stack layers, interdiffs), not diff classification | Avoids fragile heuristics; "mechanical change → own PR" is teachable policy             | Does nothing for a mixed hunk where a formatter re-aligned lines around a real edit                    |
| CLI moved from open source to private monorepo (2023)                          | "Ideal integrated Graphite experience" — tight coupling of CLI, app, queue              | Community trust cost; forks (`freephite`) froze; no self-hosting story                                 |

## Sources

- [Graphite docs home][docs] and [homepage][home]
- [CLI overview][cli-overview], [command reference][cmd-ref], [CLI changelog][cli-changelog]
- [PR page overview][pr-page], [PR versions][versions], [PR inbox][inbox], [update PRs][update-prs]
- [Reimagining the PR page (blog)][pr-redesign], [changelog 2023-02-15][cl-2023]
- [Best practices for reviewing stacks][best-practices], [how to structure stacks][structure-stacks], [stacked diffs guide][stacked-diffs-guide]
- [Merge pull requests][merge-prs], [merge when ready][mwr], [merge queue][mq], [merge queue optimizations][mq-opts]
- [AI reviews][ai-reviews], [Series B + Diamond launch][series-b], [Graphite Agent rename][agent-rename]
- Archived code: [`freephite` fork][freephite] (engine incl. [`metadata_ref.ts`][freephite-metaref]), [`language-services`][lang-services]

<!-- References -->

[home]: https://graphite.com/
[docs]: https://graphite.com/docs
[cli-overview]: https://graphite.com/docs/cli-overview
[cmd-ref]: https://graphite.com/docs/command-reference
[cli-changelog]: https://graphite.com/docs/cli-changelog
[pr-page]: https://graphite.com/docs/pr-page-overview
[versions]: https://graphite.com/docs/pull-request-versions
[inbox]: https://graphite.com/docs/use-pr-inbox
[update-prs]: https://graphite.com/docs/update-pull-requests
[pr-redesign]: https://graphite.com/blog/pr-page-redesign
[cl-2023]: https://graphite.com/blog/product-update-2-15-23
[best-practices]: https://graphite.com/docs/best-practices-for-reviewing-stacks
[structure-stacks]: https://graphite.com/docs/how-to-structure-your-stacks
[stacked-diffs-guide]: https://graphite.com/guides/stacked-diffs
[merge-prs]: https://graphite.com/docs/merge-pull-requests
[mwr]: https://graphite.com/docs/merge-when-ready
[mq]: https://graphite.com/docs/graphite-merge-queue
[mq-opts]: https://graphite.com/docs/merge-queue-optimizations
[ai-reviews]: https://graphite.com/docs/ai-reviews
[series-b]: https://graphite.com/blog/series-b-diamond-launch
[agent-rename]: https://graphite.com/blog/introducing-graphite-agent-and-pricing
[ws-guide]: https://graphite.com/guides/git-diff-ignore-whitespace
[freephite]: https://github.com/agrinman/freephite/tree/fd2990a739de801d900e0af106640efac5fcd1b3
[freephite-metaref]: https://github.com/agrinman/freephite/blob/fd2990a739de801d900e0af106640efac5fcd1b3/apps/cli/src/lib/engine/metadata_ref.ts
[lang-services]: https://github.com/withgraphite/language-services/tree/a2a594ed5232b1f3da8dcd68df65d75c2166e8ce
