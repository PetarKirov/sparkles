# `ci --ci-stats` — Delivery plan

_Companion to [SPEC.md](./SPEC.md). Each milestone is independently green (builds, tests, lints, style). The SPEC is the contract; this document is the schedule._

## M0 — Specification

- Create `docs/specs/ci/stats/`.
- Write `SPEC.md` (normative overview, CLI, data model, fetch policy seam, live progress contract, error model, pure-vs-IO separation).
- Write `PLAN.md` (this file) with milestone table and explicit gates.
- Commit both before any `.d` implementation that realises the feature.

Gate: files exist, follow the style of `docs/specs/release/{SPEC,PLAN}.md` and `docs/specs/core-cli/tui-components/PLAN.md`, and have been reviewed for clarity.

## M1 — Infrastructure in `apps/ci`

- Add `dependency "expected" version="~>0.4.1"` and `dependency "sparkles:wired" path="../.."` (plus matching selections/lock updates) to `apps/ci/dub.sdl`.
- Extend `CliParams` with the new flags (`--ci-stats`, `--github-token`, `--repo`, `--limit`, `--since`, `--workflow`, `--conclusion`, `--json`, `--no-live`).
- Extend `ProgramMode`, `validateCliMode`, `resolveProgramMode`, and the dispatch in `main`.
- Basic `--help` and conflict/error paths work and are consistent with other modes.

Gate: `dub build :ci` succeeds; `dub run :ci -- --ci-stats --help` renders the new options cleanly; invalid combinations are rejected before any network work.

## M2 — Injectable fetch layer (`std.net.curl` + wired)

- Implement `fetchAndDeserializeJson!T` (or small policy type) that performs GET (REST) and POST (GraphQL), sets the required GitHub headers, and returns `Result!T` using `parseJSON` + `fromJSON`.
- Token handling: `--github-token` > `GITHUB_TOKEN` env, with clear error when missing for private data.
- Pagination helper (Link header or page loop) capped by effective limit.
- The seam is exposed so that `runCiStats!(fetchJson)(...)` (or equivalent) accepts the fetcher as a template/alias parameter.

Gate:

- `dub run :ci -- --ci-stats --repo microsoft/vscode --limit 3` succeeds on a public repo (or with token).
- Error paths (bad token, rate limit, malformed JSON) produce friendly `Result` failures.
- Unit-testable: a local template returning a literal `T` can be passed instead of the real fetcher.

## M3 — Pure domain logic (range pipelines only)

- `Job` / `JobStats` / `RunnerAggregate` types.
- `normalizeRunnerKey` (pure, @nogc).
- `parseJobDuration` (small boundary).
- `computeStats`, `aggregateByRunner`, top-N, filters — all expressed with `std.algorithm` / `std.range` (map/filter/fold/reduce/sort/groupBy/take etc.).
- Duration formatting exclusively via `SmallBuffer` + `writeDuration`.
- All statistical functions are `@safe pure nothrow` (or the maximal safe subset) and have tagged unit tests that use mock data.

Gate: pure tests pass (`dub test :ci` or direct compile with `-unittest`); no hand-rolled accumulation loops remain in the stats path; `checkWriter` / SmallBuffer style used where appropriate.

## M4 — Live TUI rendering + integration

- Use `stdoutLiveRegion` + `TaskReporter` for fetch progress ("Fetching runs 12/30", "Jobs for run 12345").
- Optional live aggregate / slow-job table updated via `drawTableLines` + `LiveRegion.update` (following `table-leaderboard.d`).
- Final human output uses `drawHeader` + `drawTable` (with named `TableProps` arguments).
- Non-tty degradation is clean (no control sequences) — verified by piping to `cat`.
- `--no-live` forces plain output.

Gate:

- In a real terminal the progress UI repaints in place and graduates lines.
- Piped output is a readable progressive log.
- Matches the observable behaviour of `libs/core-cli/examples/live-tasklist.d` and `table-leaderboard.d`.

## M5 — Polish, docs, extraction candidates, release

- `--json` output shape stabilised and documented in SPEC.
- Good error messages for all common failure modes (token, network, empty result set, no completed jobs).
- Update top-level `ci` usage text and any relevant README / research note.
- List in the PR / commit any hand-rolled pieces that are candidates for promotion to sparkles libs (`base`, `core-cli`, `build-primitives`) and any duplication with `apps/release` remote parsing that should later move per the dman effort (`docs/specs/dman/vcs-backend.md`).
- Optional: small reusable helpers (fetch shell, paged list adaptor, duration stats) are proposed as PRs against the appropriate library.

Gate:

- `nix run .#ci -- --ci-stats ...` works.
- `nix run .#ci -- --test --fail-fast` (ci package at minimum) is green.
- Full style / editorconfig / guideline audit passes.
- SPEC and PLAN are updated with any behavioural adjustments discovered during implementation.
- Feature branch (in dedicated worktree) is ready for review.

## Milestone summary table

| #   | Deliverable                              | Key files / changes                   | Gate                              | Status |
| --- | ---------------------------------------- | ------------------------------------- | --------------------------------- | ------ |
| M0  | SPEC + PLAN written                      | `docs/specs/ci/stats/{SPEC,PLAN}.md`  | Files committed before .d code    | —      |
| M1  | CLI surface + dispatch in `ci`           | `apps/ci/dub.sdl`, `app.d`            | `--help` + conflicts work         | —      |
| M2  | curl + wired + injectable fetch          | `ci_stats.d` (fetch layer)            | Real + mock paths; token handling | —      |
| M3  | Pure stats with range pipelines          | stats functions + unit tests          | Pure tests green, no hand loops   | —      |
| M4  | Live TUI (TaskReporter + drawTableLines) | rendering + live paths                | tty + piped behaviour correct     | —      |
| M5  | Polish, docs, extraction notes           | SPEC/PLAN updates, top-level help, PR | Full CI green + audit             | —      |

Each milestone above is the unit of review and merge where practical.
