# `release` — Specification

_Audience: developers and coding agents building against the tool. This document
is normative and self-contained — it states what the tool does, not why. For the
delivery plan, see [PLAN.md](./PLAN.md); for the policy the tool encodes, see
[Cutting a Release](../../guidelines/release.md)._

## 1. Overview

`release` automates the sparkles release process end to end. It scans git tags
as SemVer, summarizes the commits since the latest one, suggests a SemVer bump
from the conventional commits, gathers the release notes (`$EDITOR` or a CLI
LLM agent), and carries the release as far as `--stage` allows: a local
annotated tag (default), a pushed tag, a draft GitHub release, a published one,
or — last — the app channels.

The tool has two modes, plus the subcommands (§3.1) that act on a tag which
already exists:

- **Classic mode** (default) — one release: latest tag → `HEAD`, one bump, one
  annotated tag (§5).
- **Split mode** (`--split`) — many releases: the unreleased backlog is
  associated with the pull requests that introduced it (§6), segmented into a
  chain of releases by a CLI LLM agent (§7), and each approved segment is then
  driven through the same notes/tag/stage machinery, oldest first.

```ansi
$ release --split --agent claude-code --stage create-tag

Release plan (v0.4.0 → v0.7.0, 416 commits)
┌─────────┬─────────┬──────────────────────┬─────────────────────┬─────────┐
│ Version │ Commits │ PRs                  │ Theme               │ Bump    │
├─────────┼─────────┼──────────────────────┼─────────────────────┼─────────┤
│ v0.5.0  │     143 │ #47 #52 #58 … (+11)  │ test-runner modes   │ minor   │
│ v0.6.0  │     188 │ #61 #64 #66 … (+14)  │ wired + versions    │ minor   │
│ v0.7.0  │      73 │ #83 #86 #89 (+2)     │ tui components      │ minor   │
└─────────┴─────────┴──────────────────────┴─────────────────────┴─────────┘
12 commits left unreleased (remainder): release-tool work in progress
```

## 2. Package and module layout

| Identifier      | Value                                |
| --------------- | ------------------------------------ |
| Dub sub-package | `release` (executable)               |
| Source root     | `apps/release/src/`                  |
| Entry point     | `src/app.d` (`sparkles.release.app`) |

| Module                          | Contents                                                                                                                            |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `sparkles.release.app`          | CLI surface (§3), orchestration of both modes, all terminal UI                                                                      |
| `sparkles.release.git`          | Every `git` invocation, returning parsed D data; pure string→struct parsers                                                         |
| `sparkles.release.conventional` | Conventional-commit subject/body parsing (`type(scope)!: description`)                                                              |
| `sparkles.release.bump`         | `BumpKind`, the bump policy (§4), `applyBump`                                                                                       |
| `sparkles.release.stats`        | `Commit` and stats types; pure tallies feeding the policy and the UI                                                                |
| `sparkles.release.stages`       | The cumulative `--stage` vocabulary (§5.4)                                                                                          |
| `sparkles.release.agents`       | CLI LLM-agent registry (PATH-filtered), one-shot invocation, prompt builders                                                        |
| `sparkles.release.notes`        | `$EDITOR` seeding, comment stripping (§8)                                                                                           |
| `sparkles.release.preflight`    | Pre-tag gating checks (clean tree, branch, `ci` tests)                                                                              |
| `sparkles.release.pr`           | Commit→PR association via the GitHub GraphQL API (§6)                                                                               |
| `sparkles.release.segment`      | Segmentation-plan parsing, validation, bump reconciliation, version chaining (§7)                                                   |
| `sparkles.release.artifacts`    | Best-effort run-artifact persistence under `.result/` (§9)                                                                          |
| `sparkles.release.json_utils`   | The string↔typed JSON boundary: `Result`-wrapped `parseJSON` + wired decode/encode                                                  |
| `sparkles.release.result`       | `Result!T = Expected!(T, string)` — the IO-layer error channel (§10)                                                                |
| `sparkles.release.store.*`      | the app channels (§3.1): the tag→version mapping, artifact staging and signing, F-Droid index generation, and the Play `edits` flow |

Pure logic (parsers, validation, policy) is separated from process execution:
every string→struct transformation is a standalone `@safe` function unit-tested
on literal inputs; only thin wrappers touch `git`, `gh`, `$EDITOR`, or an agent
binary. JSON (de)serialization uses `sparkles:wired` (`toJSON`/`fromJSON` over
`std.json.JSONValue`).

## 3. CLI surface

```text
release [-s|--stage <stage>] [-a|--auto] [-g|--agent <key>]
        [-b|--bump major|minor|patch] [-n|--notes manual|agent]
        [-S|--split] [-N|--no-verify] [-L|--log-level <level>]
        [<command>]
```

`release` is a command group whose **root is itself runnable** (`isDefault`),
so the bare form above is the cut-a-release flow it has always been. The
subcommands exist because that flow is built to compute the _next_ version and
so structurally cannot express operations on a tag that already exists.

| Flag                | Values / default                                                                    | Meaning                                                                                                              |
| ------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `-s`, `--stage`     | `create-tag` (default), `push-tag`, `create-gh-release-draft`, `publish-gh-release` | Cumulative target stage; each implies the earlier ones (§5.4). In split mode the stage applies to **every** segment. |
| `-a`, `--auto`      | off                                                                                 | Non-interactive: every prompt takes its default, agent notes are used verbatim (no `$EDITOR`).                       |
| `-g`, `--agent`     | none                                                                                | Agent key (`claude-code`, `codex`, `gemini`, …). Only agents found on `PATH` are usable.                             |
| `-b`, `--bump`      | none                                                                                | Classic mode only: override the suggested bump.                                                                      |
| `-n`, `--notes`     | `manual` interactively, `agent` under `--auto`                                      | Release-notes mode (§8).                                                                                             |
| `-S`, `--split`     | off                                                                                 | Split mode: segment the unreleased backlog into multiple chained releases (§7). Requires `gh` and an agent.          |
| `-N`, `--no-verify` | off                                                                                 | Skip the pre-flight checks.                                                                                          |
| `-L`, `--log-level` | `info`                                                                              | `trace`, `info`, `warning`, `error`.                                                                                 |

Option conflicts (hard errors, before any work):

- `--split --bump <x>` — bumps are per-segment in split mode; the plan table
  shows them.
- `--notes manual --auto` — manual notes need `$EDITOR`, `--auto` forbids it.

`--notes manual` **is** valid in split mode: `$EDITOR` opens once per segment.

### 3.1 Subcommands

| Command                     | Does                                                                  |
| --------------------------- | --------------------------------------------------------------------- |
| `release version --tag <t>` | the `versionName`/`versionCode` a tag maps to (§4.1); touches nothing |
| `release path --tag <t>`    | the store path the tag's app artifact resolves to — the CI handoff    |
| `release publish --tag <t>` | sign and publish an existing tag's artifacts to the app channels      |

`publish` carries its own cumulative `--stage` (`build`, `sign`, `pull`,
`index`, `deploy`), a `--channels` selector (`fdroid`, `play`, `both`), and
`--track` for Play. It refuses by default to build an artifact locally rather
than substituting what CI built (`--require-cached`), and refuses to run inside
a git checkout, because fdroidserver records the working directory's git state
— including its untracked files — in the index it publishes.

## 4. Version policy

- Tag discovery: all `git tag --list` entries that parse as SemVer via
  `parseLoose` (so the `v` prefix is accepted); non-SemVer tags are ignored.
  The **latest** tag is the highest by SemVer ordering, not lexically.
- New tags are always `v<major>.<minor>.<patch>`.
- The bump suggested from a commit set's tally (`suggestBump`):

| Current version   | Breaking present | `feat` present | Suggested bump |
| ----------------- | ---------------- | -------------- | -------------- |
| `0.y.z` (pre-1.0) | yes              | —              | minor          |
| `0.y.z` (pre-1.0) | no               | yes            | minor          |
| `0.y.z` (pre-1.0) | no               | no             | patch          |
| `≥ 1.0.0`         | yes              | —              | major          |
| `≥ 1.0.0`         | no               | yes            | minor          |
| `≥ 1.0.0`         | no               | no             | patch          |

- `applyBump` increments the bumped component and zeroes the lower ones; any
  prerelease/build metadata is dropped.
- First release (no SemVer tags): the whole history is the range and the
  version is `v0.1.0`.
- **Chaining (split mode):** versions chain from the latest real tag —
  `v₀ = latest`, `vᵢ = applyBump(vᵢ₋₁, bumpᵢ)` in segment order, oldest first.

A pushed tag is immutable: code.dlang.org ingests any pushed `vX.Y.Z` tag on
its own schedule, so **pushing the tag is the point of no return**, in both
modes gated by the confirmation in §5.3.

### 4.1 The app-channel version mapping

Android orders builds by an integer `versionCode`, which is exactly what
[`sparkles:versions`](../versions/SPEC.md) §3.2 calls an _order key_. The
mapping is therefore composed from two shipped schemes rather than invented:
`SemVer` parses the tag, and `Tiny.orderKey` packs `major:16 | minor:8 |
patch:8`.

Two bounds fall out of that composition rather than being asserted: `SemVer`
caps `major` at 15 bits and `Tiny` caps `minor`/`patch` at 8, so the largest
representable code is exactly `int.max` — Android's signed ceiling, reached and
never passed. A tag that cannot be mapped (a prerelease, or `minor`/`patch`
above 255) is refused **before** the tag is created when an app-channel stage
is requested, and warned about otherwise.

## 5. Classic mode (single release)

### 5.1 Pipeline

1. Parse/validate options (§3), detect terminal capabilities, build the theme.
2. Locate the range: latest SemVer tag → `HEAD` (whole history on first
   release). Zero commits ⇒ "nothing to release", exit 0.
3. Render stats: overview, commits by type, changed-by-area tree, authors.
4. Decide the next version: suggested bump (§4) → `--bump` override or an
   interactive select (default = suggestion; `--auto` takes it silently).
5. Fail fast if a GitHub stage is requested but `gh` is missing or
   unauthenticated.
6. Pre-flight (unless `--no-verify`): clean working tree, expected branch, `ci`
   tests — rendered as a live checklist; any failure aborts.
7. Acquire the notes (§8). Empty notes ⇒ abort, exit 0, no tag.
8. Confirm gate (§5.3) when the stage is outward-facing.
9. Execute the stages (§5.4) and print a receipt (tag, subject, push state,
   release link, natural next command).

### 5.2 Commit enumeration

`git log <range> --no-merges` with `\x1f`/`\x1e` field/record separators;
captured fields per commit: full SHA, author name, author email, subject, body.
Every commit is parsed as a conventional commit (unknown types ⇒ `other`;
breaking = `!` marker or a `BREAKING CHANGE:`/`BREAKING-CHANGE:` body line).

### 5.3 Confirm gate

When the chosen stage is `push-tag` or later, the tool enumerates exactly what
will leave the machine ("push v0.5.0 to origin and create a draft GitHub
release") and asks for confirmation. Declining aborts with **no tag created**
(classic mode creates the tag only after the gate). `--auto` accepts the
default (yes).

### 5.4 Stages

Ordered, cumulative:

| Stage token               | Adds                                                               |
| ------------------------- | ------------------------------------------------------------------ |
| `create-tag`              | local annotated tag (body = the notes)                             |
| `push-tag`                | `git push origin <tag>`                                            |
| `create-gh-release-draft` | `gh release create <tag> --draft --notes-from-tag`                 |
| `publish-gh-release`      | `gh release edit <tag> --draft=false` (fires the release workflow) |
| `publish-apps`            | sign and publish the app channels (F-Droid and Play)               |

Execution renders all rows up front as a live checklist; rows beyond the chosen
stage are skipped with "beyond --stage". A failing stage stops the pipeline; a
tag already created locally survives (the error names the retry command).

`publish-apps` is last, and is one stage for both channels rather than one
each: they are peers, and a linear ladder cannot express "these two, in no
particular order". It only works where the signing tokens are — reaching it
from CI is meant to fail — and the default stage remains `create-tag`, so
nothing drifts into publishing an app by accident.

## 6. PR association (split mode)

This repository merges PRs by **rebase**: no merge commits, no squash `(#N)`
subject suffixes. The only reliable commit→PR association is the GitHub API.

- The repo slug (`owner`, `name`) is parsed from `git remote get-url origin`.
  Accepted forms: `git@github.com:Owner/repo(.git)`,
  `https://github.com/Owner/repo(.git)`, `ssh://git@github.com/Owner/repo(.git)`.
  Anything else is an error (split mode requires a GitHub origin).
- Association is batched GraphQL via `gh api graphql`, **50 commits per
  query**, each commit an alias:

```text
query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    c0: object(oid: "<sha0>") { ... on Commit {
      associatedPullRequests(first: 5) { nodes { number title mergedAt } } } }
    c1: object(oid: "<sha1>") { ... }
    ...
  }
}
```

- Per commit, the first associated PR with a non-null `mergedAt` wins.
- A commit resolves to **PR 0** (no PR) when: the OID is unknown to GitHub
  (unpushed local commit ⇒ GraphQL returns a `null` object), it has no
  associated PRs, or none of them is merged (open/closed-unmerged only).
- A reply with GraphQL `errors` alongside usable `data` is tolerated; a reply
  with no `data` is an error.
- Progress is reported per batch on the live checklist.

## 7. Segmentation (split mode)

### 7.1 Agent input

The backlog is presented as **PR-atomic units**, oldest first, embedded in the
prompt as compact JSON. A unit is one merged pull request with all of its
commits, or a single direct commit (`pr: 0`, §6):

```json
{
  "units": [
    {
      "i": 0,
      "pr": 47,
      "title": "feat(x): y",
      "commits": ["feat(x): part 1", "fix(x): part 2"]
    },
    {
      "i": 1,
      "pr": 0,
      "title": "chore: direct push",
      "commits": ["chore: direct push"]
    }
  ]
}
```

Units are contiguous slices covering the whole range: a unit ends at the first
row where every PR opened so far has closed, so a PR whose commits interleave
with another's yields one wider unit rather than a split. No commit SHA appears
in the prompt — the tool maps a unit back to the commit its tag lands on.

The prompt states the current version, the bump-policy table matching §4 for
the current major, and the reply contract below. Each JSON block is fenced with
more backticks than its content contains, so a commit subject that itself holds
a fence cannot close the block early.

### 7.2 Agent reply contract

The agent must reply with **only** this JSON object (fenced or bare — see
§7.3):

```json
{
  "segments": [
    {
      "boundary": 12,
      "theme": "<short theme for the `vX.Y.Z — <theme>` subject>",
      "bump": "patch|minor|major",
      "highlights": ["<completed, user-visible work to document>", "…"]
    }
  ],
  "remainderNote": "<why trailing units were left unreleased; optional>"
}
```

Semantics the prompt demands and the tool enforces or uses:

- `boundary` is the `i` of the segment's **last unit** — a number, strictly
  increasing across segments. A quoted (`"12"`) or float-shaped (`12.0`)
  boundary means the same thing.
- Segments are **contiguous slices** of the oldest-first unit list, in order.
- A PR is never split across releases: it is one unit, and units are atomic.
  The agent cannot express a split, so it cannot make that mistake.
- A **trailing remainder** may be left out of all segments (unreleasable WIP);
  `remainderNote` explains it. Mid-range units cannot be excluded — a git tag
  always contains its full ancestry.
- Segment boundaries need **not** wait for an area's work to complete: WIP may
  land inside a segment undocumented. `highlights` names only the completed
  work this release's notes cover; a highlight may complete an arc begun in an
  earlier segment (its notes then summarize the whole arc). Un-highlighted work
  is silently deferred to the release where it completes.
- `highlights` and `remainderNote` are optional (default empty).

### 7.3 Reply parsing and validation

1. **Fence stripping:** ` ```json `/` ``` ` fences are removed;
   with surrounding prose, the substring from the first `{` to the last `}` is
   taken. The result must parse as JSON (`std.json`); each `boundary` is
   normalized to its decimal text, then the reply decodes into the reply shape
   (`sparkles:wired`; unknown keys are ignored). A boundary of any other shape
   (an old-style SHA, say) still decodes, so step 2 rejects it with a message
   about unit indices rather than one about JSON types.
2. **Boundary resolution:** each `boundary` must be a unit index in range, and
   the indices must be strictly increasing. Each resolves to the exclusive end
   of its unit. The last boundary may fall short of the newest unit (that
   suffix becomes the remainder). At least one segment is required.
3. **PR integrity:** for every PR number ≠ 0, all its commits must land in one
   segment (or all in the remainder). Unit-atomic boundaries make this
   structurally true; the check remains as the invariant's guard.

4. **Bump reconciliation:** per segment, the policy floor is `suggestBump`
   (§4) of that segment's tally against the chained previous version. The
   agent's bump is accepted if ≥ the floor; an under-bump is **escalated** to
   the floor (warned, marked in the plan table); an unparsable bump token
   falls back to the floor. `patch < minor < major`.
5. **Version chaining** per §4; every planned tag must not already exist.

On a parse or validation failure the agent is retried **once** with the
original prompt plus a corrective coda quoting the error. A second failure
aborts, showing the error and the reply (truncated; the full text is in
`.result/`, §9).

### 7.4 Plan review and the remainder decision

The validated plan renders as a table — Version, Commits, PRs (`#47 #52 …
(+11)`), Theme, Bump (escalations and fallbacks marked; a pre-1.0 `major` is
highlighted) — plus footer warnings:

- `N commits left unreleased (remainder): <remainderNote>`
- `N commits have no associated PR`
- `M tip commits are not on origin/main — pushing a tag publishes them`

When a remainder exists the user chooses (interactive select; `--auto` takes
the default): **leave unreleased** (default) or **extend the last release** to
include it (that segment's tally, bump floor, and version are recomputed).

The user then approves the plan (confirm; decline ⇒ exit 0, nothing created).
Pre-flight runs once (against `HEAD`). When the stage is outward-facing, one
confirm gate enumerates **all** tags that will be pushed/released.

### 7.5 Per-segment execution

For each segment, oldest first:

1. Notes are acquired per §8 with the segment's range
   (`prev-boundary..boundary`), theme, and highlights. Empty notes abort the
   remaining segments — tags already created stand, and the receipt names the
   resume path (re-running `--split`: the latest tag has moved, so the backlog
   shrinks naturally).
2. The annotated tag is created **on the segment's boundary commit**
   (`git tag -a <tag> -F <file> <boundary-sha>`).
3. The remaining stages run as in §5.4 (`push`, draft, publish per `--stage`),
   one checklist per segment.

Publishing oldest-first leaves GitHub's "Latest release" marker on the newest
tag. A failing stage stops the loop; the summary receipt lists every tag that
was created/pushed and the retry command.

## 8. Notes

### 8.1 Format

The notes are the annotated-tag body — there is no separate changelog file:

- Subject line: `vX.Y.Z — <short theme>` (em dash).
- Blank line, then sections grouped by area, each an underlined heading
  (the area name, then a line of dashes).
- Every breaking change under a `BREAKING — <area>` heading with a concrete
  `Migration:` block.

### 8.2 Modes

- `manual` — `$EDITOR` (`$VISUAL` → `$EDITOR` → `vi`) opens on a seeded buffer:
  suggested subject, `#`-commented instructions, `#`-prefixed
  `git log --stat` of the range. `#`-leading lines are stripped; an empty
  result aborts (git-commit semantics).
- `agent` — the chosen agent is invoked once with a prompt embedding the
  range's `git log --stat`; the reply is reviewed in `$EDITOR` (skipped under
  `--auto`, where it is used verbatim). The embedded log is capped at 96 KiB
  (truncated at a line boundary, elision marked) so a hundreds-of-commits
  range's diffstat noise cannot crowd the notes out of the model's context;
  the editor path is never truncated. The cap is not a delivery limit — the
  prompt reaches the agent as a file (§8.4).

### 8.3 Split-mode additions

The per-segment agent prompt additionally carries:

- the segment's `highlights` — the notes must cover **only** these;
- compact context (`sha7 subject` per commit) of the **earlier** segments, to
  be referenced only where a highlight completes an arc started there;
- the instruction that incomplete/WIP work must be omitted — it is documented
  in the release where it completes.

The same agent is used for segmentation and all per-segment notes; it is
picked once (via `--agent` or one interactive select).

### 8.4 Prompt delivery

**A prompt is never an argv element.** Linux caps one element at
`MAX_ARG_STRLEN` (32 pages — 128 KiB where a page is 4 KiB), and a `--split`
segmentation prompt over a long backlog runs several times that, so passing it
as an argument fails to spawn at all (`E2BIG` → "Argument list too long",
status 127).

Instead every prompt is written to a file, and each registry entry says how its
agent is handed one. A flag may contain the placeholder `{}`, replaced with the
prompt file's path:

| Form                                                 | Agents                                               | How the agent gets the prompt         |
| ---------------------------------------------------- | ---------------------------------------------------- | ------------------------------------- |
| no `{}`                                              | `claude -p`, `codex exec`, `amp -x`                  | the file on standard input            |
| `{}` in a path flag                                  | `aider --message-file`, `goose run -i`               | the tool opens it itself              |
| `{}` inside a prompt string ("Read the file `{}` …") | `gemini`, `copilot`, `opencode`, `q`, `crush`, `agy` | the agent reads it with its own tools |

The third form exists for tools that accept only a prompt string (`agy --print`
ignores standard input); the argument stays a single short line whatever the
prompt's size. The file lives in the system temp directory and is removed when
the run returns. Agents that do not name the file are still given a redirected
(empty) standard input, so none can block on the terminal.

The remaining 96 KiB cap on a notes prompt's `git log --stat` (§8.2) is a model
budget, not a spawn limit.

## 9. Artifacts

Split mode persists its intermediate products for later review under the
(gitignored) `.result/` directory at the repository root:

````text
.result/release-split/<yyyymmdd-HHMMSS>/
├── segmentation-prompt.md          # valid markdown; JSON pretty-printed in
│                                   # ```json fences (the agent itself gets
│                                   # the compact, token-efficient rendering)
├── segmentation-reply-1.json       # per attempt (…-2 on retry): the reply
│                                   # pretty-printed when its fence-stripped
│                                   # text parses as JSON, else raw as …-N.txt
├── plan.json                       # the validated ReleasePlan
├── notes-prompt-<tag>.txt
└── notes-<tag>.txt                 # the body as tagged
````

Artifact writes are **best-effort**: a failure logs a warning and never aborts
the run. Reviewing artifacts is never a blocker for the release process.

## 10. Errors and exit behavior

- IO wrappers (`git`, `gh`, agents, `$EDITOR`) return
  `Result!T = Expected!(T, string)`; the orchestrator renders the message and
  exits `1`. Nothing in the IO layer throws for expected failures.
- Exit `0`: success; nothing to release; user-initiated aborts (declined
  confirm, empty notes).
- Exit `1`: option conflicts, failed pre-flight, git/gh/agent failures,
  invalid segmentation after the retry.
- Split-mode partial failure: already-created tags stand (tags are cheap
  locally and immutable only once pushed); the receipt reports what completed.
  Re-running `--split` resumes naturally — the latest tag has advanced, so the
  remaining backlog is re-segmented on its own.
- `gh` readiness: classic mode requires `gh` only for GitHub stages; split
  mode requires it always (association, §6). Both check `gh auth status` up
  front.
