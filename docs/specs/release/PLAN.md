# `release` — Delivery plan

_Companion to [SPEC.md](./SPEC.md): the milestones that build the tool to the
specification. Each milestone is independently green (builds + tests + lints).
The classic single-release mode (SPEC §5) shipped earlier; M2–M6 deliver the
split mode (SPEC §6–§9) on top of it._

## M1 — Specification

[SPEC.md](./SPEC.md) — the normative surface: the CLI (§3), the version policy
(§4), the classic pipeline (§5), PR association (§6), segmentation with its
agent contract and validation rules (§7), the notes formats (§8), run
artifacts (§9), and error/exit behavior (§10).

## M2 — git plumbing and the wired dependency

- `createAnnotatedTag` gains an optional target committish (tags a boundary
  commit instead of `HEAD`; SPEC §7.5).
- `remoteUrl(remote = "origin")` wrapper (SPEC §6).
- `apps/release` gains `dependency "sparkles:wired" path="../.."` with the
  matching `dub.selections.json` entries (`optional`, `bolts`).

Gate: `dub test :release`; classic-mode behavior unchanged.

## M3 — PR association (`sparkles.release.pr`)

`RepoSlug` + `parseRemoteUrl` (the accepted URL grammar of SPEC §6),
`buildAssociationQuery` (aliased OIDs, 40-hex validated), the wired-typed
`parseAssociationReply` (null object / no merged PR ⇒ `pr 0`, `errors`-array
tolerance), and `associatePrs` batching `gh api graphql` 50 commits per query
with a progress callback.

Gate: `dub test :release` — all parsers unit-tested on literal strings/JSON;
plus one live smoke test of the query shape against this repository.

## M4 — segmentation (`sparkles.release.segment`)

The reply schema types, `stripJsonFence`, the `Result`-wrapped JSON parse,
wired decode (SPEC §7.3 step 1), `resolveBoundaries` (unique-prefix
resolution, strict ordering, trailing remainder), `checkPrIntegrity`,
`buildPlan` (bump floors, escalation/fallback origins, version chaining), and
`buildSegmentationPrompt` (SPEC §7.1–§7.2) in `agents.d`.

Gate: `dub test :release` — validation-rule matrix covered pure (happy path,
unknown/out-of-order/ambiguous boundaries, split PRs, under-bump escalation,
invalid bump fallback, pre-/post-1.0 floors, remainder handling).

## M5 — orchestration, artifacts, `--split`

`sparkles.release.artifacts` (SPEC §9); the range-aware refactor of notes
acquisition and stage execution (explicit to-ref/target, behavior-preserving
for classic mode); the `--split` flag with its conflicts (SPEC §3); `runSplit`
(gh probe, single agent pick, association progress, retry-once, plan table,
remainder decision, preflight, the all-tags confirm gate, the per-segment
loop, the summary receipt).

Gate: `dub test :release`; end-to-end run against this repository's real
backlog at `--stage create-tag` (plan table sane, tags land on their boundary
commits, notes honor highlights, artifacts present), then local tags deleted;
one classic-mode regression run.

## M6 — docs & verification

The split-mode section in
[Cutting a Release](../../guidelines/release.md), the VitePress sidebar entry
for this spec, and reconciliation of any SPEC drift discovered during
implementation.

Gate: `npm run docs:build` clean; SPEC matches the shipped behavior.
