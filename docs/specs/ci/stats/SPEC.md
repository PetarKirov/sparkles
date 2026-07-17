# `ci --ci-stats` — GitHub Actions CI usage statistics

_Audience: developers and coding agents building against or consuming the `ci` tool. This document is normative — it states what the `--ci-stats` subcommand does (and, for sections marked as targets, what it is specified to do once the corresponding PLAN milestone lands). For the delivery plan see [PLAN.md](./PLAN.md)._

Sections describing unimplemented behaviour carry an explicit **(target — Mn)** marker.

## 1. Overview

`ci --ci-stats` queries the GitHub REST (and optionally GraphQL) API to produce human-readable statistics on CI job execution for a repository:

- Overall per-job timing: count, min, max, mean, median, p95, total wall-clock time.
- Aggregated "CI minutes" (and optionally ceiling-to-minute billed minutes) broken down by runner type (derived from job `labels`).
- Supporting views: top slow jobs, per-workflow breakdowns where useful, and live progress during fetch.

The command is a subcommand of the existing `sparkles:ci` tool (invoked as `dub run :ci -- --ci-stats ...` or `nix run .#ci -- --ci-stats ...`). It follows the same logging, pre-flight, and output conventions as other `ci` modes.

All network I/O uses `std.net.curl`. Auth is via `--github-token` (with `GITHUB_TOKEN` environment fallback). No dependency on the `gh` CLI binary is required.

Pure computation (filtering, duration derivation, statistical aggregation, runner key normalisation) is expressed with `std.algorithm` + `std.range` pipelines and is unit-testable via an injectable fetch policy.

Live terminal progress uses the `LiveRegion` / `TaskReporter` + `drawTableLines` stack (see the idioms in `libs/core-cli/examples/{live-tasklist.d,table-leaderboard.d,streaming-box.d}`).

## 2. Package and module layout

| Identifier      | Value                  |
| --------------- | ---------------------- |
| Dub sub-package | `ci` (executable)      |
| Source root     | `apps/ci/src/`         |
| Entry point     | `src/app.d` (extended) |

| Module / file                                | Responsibility                                                                                                                          |
| -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `apps/ci/src/app.d`                          | CLI surface extension, mode dispatch, top-level orchestration for `--ci-stats`                                                          |
| `apps/ci/src/ci_stats.d` (or `ci_stats/*.d`) | Data models, `fetchAndDeserializeJson` policy, REST/GraphQL call helpers, pure stats pipelines, rendering, the `--ci-stats` entry point |
| (future) promoted helpers                    | Any generally-useful pieces (fetch shell, duration stats, remote helpers) moved to `sparkles:base` / `core-cli` / `build-primitives`    |

Pure logic is separated from I/O: JSON→domain transformations and all statistical functions are standalone `@safe` (or attribute-inferred) functions. Only thin wrappers perform curl requests.

## 3. CLI surface

```text
ci --ci-stats
   [--repo OWNER/REPO]
   [--github-token TOKEN | $GITHUB_TOKEN]
   [--limit N] [--since YYYY-MM-DD]
   [--workflow NAME] [--conclusion success|failure|...]
   [--json] [--no-live]
   [--log-level trace|info|...]
```

| Flag / env                        | Default                         | Meaning                                                                                       |
| --------------------------------- | ------------------------------- | --------------------------------------------------------------------------------------------- |
| `--repo`                          | discovered (future) or required | `owner/repo` (case-insensitive on GitHub)                                                     |
| `--github-token` / `GITHUB_TOKEN` | (none)                          | Bearer token. Precedence: flag > env. Sent as `Authorization: Bearer ...`.                    |
| `--limit`                         | 100                             | Maximum workflow runs to consider (client-side cap after pagination).                         |
| `--since`                         | (none)                          | Only runs created on or after this date (`created>=...` query param).                         |
| `--workflow`                      | (all)                           | Substring filter on `name` or workflow filename.                                              |
| `--conclusion`                    | (all completed)                 | Filter jobs by conclusion (`success`, `failure`, `cancelled`, ...).                           |
| `--json`                          | off                             | Emit machine-readable JSON (structure defined in §6.3) instead of (or in addition to) tables. |
| `--no-live`                       | off                             | Disable in-place live updates (force plain progressive output).                               |
| `--log-level`                     | `info`                          | Standard sparkles logger levels.                                                              |

Conflicts and errors are reported before any network work (consistent with other `ci` modes).

When neither `--repo` nor discovery succeeds, a clear actionable error is printed.

## 4. Authentication & production requirements

- Token is never logged.
- `User-Agent: sparkles-ci` (or similar) is always sent.
- Required headers: `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`.
- Public repositories may succeed without a token; private repositories or high-volume usage require one.
- Rate-limit responses (403/429 with `x-ratelimit-*` headers) are surfaced as friendly errors containing reset time when available.

## 5. Data model (domain types)

(These are internal but appear in the JSON output and are the vocabulary of the pure functions.)

```d
struct Job {
    string id;
    string name;
    string workflow;      // workflow name or path
    Duration duration;    // completed_at - started_at (0 when incomplete)
    string[] labels;      // raw GitHub labels
    string runnerName;
    string conclusion;    // success | failure | ...
    SysTime startedAt;
    SysTime completedAt;
}

struct JobStats { size_t count; Duration total, min, max, mean, median, p95; }

struct RunnerAggregate {
    string runnerType;    // normalised key (see §6.2)
    size_t jobCount;
    Duration total;
    double minutes;       // total / 60.0
    // + per-runner JobStats subset
}
```

Only jobs that possess both `started_at` and `completed_at` contribute a positive duration.

## 6. Behaviour

### 6.1 Fetch policy (the injectable seam)

The command accepts an injectable fetcher:

```d
alias FetchJson(T) = Result!T delegate(string url, string method = "GET",
                                       string body = null, string[string] extraHeaders = null);

Result!Report runCiStats(alias fetchJson)(string repo, in Options opts) { ... }
```

- Real implementation: `fetchAndDeserializeJson!T` built on `std.net.curl.HTTP` + `parseJSON` + `fromJSON!T` (via `sparkles.wired`).
- Test implementation: a local template that ignores the URL and returns a pre-built `T`.
- REST list endpoints use GET + query parameters.
- GraphQL (when used) uses POST with `{"query": "..."}` body and appropriate `Content-Type`.

Pagination for `/actions/runs` and `/actions/runs/{id}/jobs` respects `per_page=100` and either follows `Link` headers or performs simple page loops up to the effective `--limit`.

### 6.2 Runner type normalisation (pure)

- If `labels` contains `"self-hosted"`, the key is `"self-hosted"` plus the remaining labels sorted and joined by `+` (example: `self-hosted+linux+x64`).
- Otherwise the first label is used (typical values: `ubuntu-latest`, `ubuntu-22.04`, `macos-14`, `windows-latest`).
- The resulting key is used for `groupBy` / associative aggregation.

### 6.3 Output

**Human (default):**

- Header via `drawHeader`.
- Overall `JobStats` summary (durations via `writeDuration` into `SmallBuffer`).
- Table of runner aggregates (runner type, jobs, total, avg, min, max, minutes).
- Optional "Top slow jobs" table.
- Live progress during fetch using `TaskReporter` + detail lines; optional live-updating aggregate table via `drawTableLines` + `LiveRegion.update`.

**Machine (`--json`):**

A single JSON object containing the report (exact shape defined in the implementation but stable across minor versions; contains `generatedAt`, `repo`, `filters`, `overall`, `byRunner[]`, `slowJobs[]`).

Non-tty output never emits terminal control sequences.

### 6.4 Error model

All fallible operations return a `Result!T` (alias to `Expected!(T, string)`) following the pattern in `apps/release/src/sparkles/release/result.d`.

Top-level errors produce a single-line message on stderr and exit code 1 (or richer structured output under `--json`).

## 7. Limits & quality

- Default `--limit 100` (two pages of 100). Higher values are allowed but documented as potentially hitting secondary rate limits.
- Only completed jobs (both timestamps present) are counted for timing stats.
- Durations are rendered exclusively with `sparkles.base.text.writers.writeDuration`.
- All statistical reductions after the domain objects exist are expressed with range pipelines (`map`, `filter`, `fold`/`reduce`, `sort` + indexing for median/p95, `groupBy` after sort, etc.).

## 8. Future work (non-normative)

- Automatic repo discovery from git remote (may reuse/extend logic from `build-primitives` or the dman VCS backend).
- Billing-rate multipliers (Windows ×2, macOS ×10, self-hosted ×0).
- Persistent caching of recent results.
- Export to CSV / Prometheus.

(See [PLAN.md](./PLAN.md) for what is actually scheduled.)
