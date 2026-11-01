---
status: draft
owner: apps/ci
reviewed: 2026-11-01
---

# `apps/ci` commands on the task DAG — Specification

## Abstract

`apps/ci` is the repository's CI tool: it tests and builds every package, runs
and verifies documentation examples, checks links, citations and the docs site,
and reports CI statistics. This specification defines its command tree and the
task graph each command plans. Every command runs on one executor and one
reporter, and every compile goes through one content-addressed build graph,
so a `ci pipeline` run checks everything CI checks, in parallel, without
compiling the same library twice.

## Introduction

`apps/ci` grew one flag per job: `--test`, `--build`, `--example-files`,
`--check-vcs-urls` and dozens more. Each owned its own loop, worker pool,
fail-fast logic and output. The jobs could not share work or run together, and
their logs depended on timing.

This specification replaces the flags with a command tree whose commands only
_plan_. Each command turns its inputs into a task graph. The generic
[task DAG](../../build-primitives/task-dag/SPEC.md) executes and reports that
graph, and the [build graph](../../build-primitives/build-graph/SPEC.md)
supplies its compile, link and test actions, shared across commands, worktrees
and machines. `ci pipeline` plans the union of every CI job as one graph.

The task DAG owns the model, edges, admission, cancellation, determinism and
reporting rules, and the build graph owns compilation and caching. This
document does not restate either. It owns the command surface, the
repository's selection policy, the graphs of each command, and coverage
publication. Jobs that need a different host operating system appear in
`ci pipeline` as explicitly skipped tasks rather than being dropped.

Section 1 defines the command surface and §2 the mapping from the removed flags.
Section 3 compares the design with Yarn's workspace commands, and §4 states the
repository's selection policy. Section 5 gives each command's graph, §6 the
build and coverage locations, §7 the module layout, and §8 the acceptance
criteria. Delivery order is in [PLAN.md](./PLAN.md).

## 1. Command surface

### 1.1 Canonical commands

```text
ci pipeline [--from SELECTOR...] [--since REF] [--jobs N] [--fail-fast]

ci test [--build-only | --special-modes betterc|wasm|all]
        [--from SELECTOR...] [--since REF]
        [--dependencies] [--dependents]
        [--coverage | --no-coverage] [--sanitize address] [--slow]

ci docs examples [--include-files SELECTOR...] [--exclude-files SELECTOR...]
ci docs run|verify|update [--include-files SELECTOR...] [--exclude-files SELECTOR...]
ci docs links check|fix [--include-files SELECTOR...] [--exclude-files SELECTOR...]
ci docs vcs-urls check [--include-files SELECTOR...] [--exclude-files SELECTOR...]
ci docs sidebar check
ci docs glossary check
ci docs credits check
ci docs spec-evidence check|update-backlog
ci docs blob-paths check [--clone-root DIR] [--include-files SELECTOR...]
ci docs fences audit [--root DIR] [--audit-scope site|all|excluded] [--json FILE]
ci docs wasm check|stage [module options]

ci commits build-each [--base REF] [--packages NAME...]
ci commit-scope [COMMIT_MESSAGE_FILE|-]
ci cache seed-dub | check-pins | stats | gc
ci host probe [--host-system SYSTEM] [--host-ci-rev REV]
ci checks mirror [--repo R] [--sha SHA] [--dry-run]
ci stats [statistics options]
ci link-rot report [report options]
ci slow-tests list
```

Every command that executes a graph accepts:

| Option              | Default               | Meaning                                                                                                                                            |
| ------------------- | --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--jobs N`          | host-derived capacity | Positive weighted capacity available to running tasks. It is not a count of OS threads.                                                            |
| `--interlaced`      | off                   | Stream line-atomic, task-prefixed output as events arrive instead of replaying complete task blocks in presentation order.                         |
| `--dry-run`         | off                   | Discover, select, plan, validate, and print the DAG without running task actions, making network requests, creating directories, or writing files. |
| `--fail-fast`       | off                   | On the first authoritative failure, stop admission and cancel the command scope.                                                                   |
| `--log-level LEVEL` | `info`                | Standard Sparkles logger level.                                                                                                                    |

`--jobs 0` and negative values are errors. `--dry-run --interlaced` is rejected,
because a dry run has no task output to interlace. `SPARKLES_CI_JOBS` remains an
environment fallback, and an explicit `--jobs` wins. Invalid combinations fail
before any task runs. Repository workflows pass `--interlaced`.

A command that is a single check, such as `ci docs sidebar check`, plans a
one-node graph. It still runs through the executor and reporter, so its
outcome, exit status and output follow the same rules as every other command.

### 1.2 `ci test` modes

With no mode option, `ci test` creates ordinary unittest tasks. Coverage is on
by default for this mode and can be disabled with `--no-coverage`.

`ci test --build-only` builds each selected package's library and application
variants and runs nothing. Coverage is invalid.

`ci test --special-modes MODE` creates the test runner's extracted special-mode
tasks:

- `MODE` is a wired enum whose CLI spellings are `betterc`, `wasm` and `all`;
  core-cli's `?`/`help` value-help forms list them.
- A selected package gets a task only for marker attributes present in its
  sources, and only if it integrates `sparkles:test-runner`.
- Every special invocation passes `--self-test` and `--require-toolchain`.
- An empty repository-wide special-mode plan is an error, not a successful
  no-op.
- Coverage is invalid.

`--sanitize address` builds and tests every selected package under
AddressSanitizer, as a separate variant; it requires LDC on Linux. `--slow` runs
the `@slow` tests instead of the ordinary ones.

`--build-only` and `--special-modes` are mutually exclusive.

### 1.3 `ci pipeline`

`ci pipeline` plans, as one graph:

- every `ci test` mode CI runs;
- `ci docs examples` and the markdown verification CI runs;
- every `ci docs … check`;
- `ci commit-scope` for the commits of the range.

It runs on the build graph's shared store. Its `--from` and `--since` narrow
the package-derived tasks only. Tasks that require another host operating
system or another architecture are `Skipped(platform)` under the local
backend. Under the [Nix backend](../../build-primitives/build-graph/SPEC.md#10-the-nix-backend)
they run on remote builders of that system.

## 2. Removed flags

The flat mode flags are removed at cutover, and active workflows, hooks and
documentation migrate in the same change. There is no legacy parser, alias,
precedence table, or fallback dispatch.

| Removed flag                     | Replacement                            |
| -------------------------------- | -------------------------------------- |
| `--test`, `-t`                   | `ci test`                              |
| `--build`                        | `ci test --build-only`                 |
| `--test-extracted`               | `ci test --special-modes all`          |
| `--test-sanitize`                | `ci test --sanitize address`           |
| `--test-slow`, `--tests`         | `ci test --slow`                       |
| `--list-slow-tests`              | `ci slow-tests list`                   |
| `--coverage`                     | `ci test --coverage`                   |
| `--example-files`, `-x`          | `ci docs examples`                     |
| default markdown mode            | `ci docs run`                          |
| `--verify`, `-V`                 | `ci docs verify`                       |
| `--update`, `-u`                 | `ci docs update`                       |
| `--dedup-reference-links`, `-d`  | `ci docs links check`                  |
| `--fix-reference-links`, `-f`    | `ci docs links fix`                    |
| `--check-vcs-urls`               | `ci docs vcs-urls check`               |
| `--check-docs-sidebar`           | `ci docs sidebar check`                |
| `--check-glossary`               | `ci docs glossary check`               |
| `--check-credits`                | `ci docs credits check`                |
| `--check-spec-evidence`          | `ci docs spec-evidence check`          |
| `--update-spec-evidence-backlog` | `ci docs spec-evidence update-backlog` |
| `--check-blob-paths`             | `ci docs blob-paths check`             |
| `--audit-fences`                 | `ci docs fences audit`                 |
| `--check-wasm-modules`           | `ci docs wasm check`                   |
| `--stage-docs-wasm`              | `ci docs wasm stage`                   |
| `--build-each-commit`            | `ci commits build-each`                |
| `--check-commit-scope`           | `ci commit-scope`                      |
| `--seed-dub-cache`               | `ci cache seed-dub`                    |
| `--check-pin-cache`              | `ci cache check-pins`                  |
| `--linux-host-probe`             | `ci host probe`                        |
| `--mirror-checks`                | `ci checks mirror`                     |
| `--ci-stats`, `-C`               | `ci stats`                             |
| `--report-link-rot`              | `ci link-rot report`                   |

Option-only flags keep their spelling on the command that owns them; for
example, `--json`, `--root` and `--audit-scope` move to `ci docs fences audit`.

## 3. Yarn inspiration and Sparkles differences

The focused package selectors and output vocabulary intentionally resemble
Yarn's workspace `foreach` command:

- `--from` establishes workspace-like package seeds.
- `--since` selects packages changed from a revision.
- `--dependencies` and `--dependents` expand graph closure.
- `--jobs` bounds parallel work.
- `--interlaced` opts into immediate mixed output.

Sparkles differs in load-bearing ways:

| Yarn-inspired idea  | Sparkles definition                                                                                                                              |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Workspace           | A root `dub.sdl` sub-package with a stable package name and repository-relative directory. The root package is metadata, not an executable task. |
| Topological command | Builds follow the in-tree dependency graph. Tests do not wait for other packages' tests, only for the builds their binaries need.                |
| Job count           | Weighted capacity. A compiler-heavy task can consume more than one unit.                                                                         |
| `--from`            | Matches Sparkles package name, qualified name, or path. It does not mean "start at this textual position."                                       |
| `--since`           | Uses Git change ownership plus explicit repository-wide invalidators, not workspace manifest timestamps.                                         |
| Recursive selection | Explicit `--dependencies` and `--dependents`; there is no implicit Yarn `-R`/`-A` mode.                                                          |
| Interlacing         | Line-atomic, prefixed event streaming on TTY and non-TTY alike. Raw byte chunks are never written concurrently.                                  |
| Failure             | A structured outcome, with blocked, cancelled, skipped, and degraded distinct from failed.                                                       |
| Execution           | Event Horizon scopes, subprocesses, clocks, and wakeups only. No `std.parallelism` pool or polling thread is permitted.                          |
| Cache               | A content-addressed build store shared by every worktree. Test results are reused only under the build graph's rules.                            |

## 4. Selection policy

Focused selection follows the [task DAG's selection
algebra](../../build-primitives/task-dag/SPEC.md#2-package-discovery-and-focused-selection).
Only `ci test` and `ci pipeline` accept focused selectors; docs and example
commands keep their file selectors.

The repository's invalidators, which select every package, are:

- the root `dub.sdl`, `dub.selections.json` and `nix/dub-lock.json`;
- toolchain construction under `nix/d-toolchain.nix`;
- the modules that discover packages, construct tasks or build:
  `sparkles.build_primitives.task`, `.workspace` and the build graph, and
  `apps/ci/src/commands/`.

Other `apps/ci/` changes select only `ci`, which owns them.

## 5. Graphs for current work

The diagrams show graph shape. Real node ids include package and file
identity. Build nodes are the build graph's actions, shared by every command in
one run and reused from the store across runs.

### 5.1 Package build-only

```text
discover -> select -> plan builds
                   -> compile/archive/link (variant A) -> compile/archive/link (dependent B)
all selected build nodes --onCompletion--> run summary
```

A failed build blocks the builds that link against it.

### 5.2 Ordinary package tests and coverage

```text
discover -> select -> plan builds
dependency-library builds of A --onSuccess--> link test binary A -> coverage test A --failure--> plain test A
                                                                  \--success--+-----------------+-> classify A
all classifications --onCompletion--> merge coverage -> coverage-publish
all classifications --onCompletion--> run summary
```

A package's test task depends only on its own test binary. Its binary depends
on its test-root compile and on the dependency-library archives it links. No
test waits for another package's test. A dependency whose library fails to
build blocks the link of each test binary that needs it.

Without coverage, each package has one test node and one classification node.
With coverage, the test binary is a coverage variant, and each attempt writes
listings to its own task directory:

- **Retry:** a failed coverage attempt schedules a plain retry against the
  plain variant.
- **Classification:** if the plain tests pass, the package is
  `Degraded(noCoverage)`. If they fail, it is `Failed`, retaining both
  attempts.
- **Fail-fast:** the initial coverage failure is provisional and does not
  trigger fail-fast.

### 5.3 Extracted test modes

```text
discover -> select -> scan marker attributes
                   -> better-c(package A)
                   -> wasm(package A)
                   -> wasm(package B)
all special nodes --onCompletion--> run summary
```

The marker scan is a planning action. Different modes for the same package
are independent unless resource capacity serializes them.

### 5.4 Markdown examples

```text
discover markdown -> parse each file -> build and run each runnable example
                                     -> skipped directive outcome
execute nodes --onCompletion--> file run/verify reducer
file reducers --onCompletion--> command summary

update only:
file reducer --onSuccess--> atomic rewrite(file)
```

- **Shared machinery:** `docs run`, `docs verify` and `docs update` share
  discovery, extraction, in-tree dependency rewriting, building, process
  execution and result models.
- **Run** renders captured output, and **verify** compares normalized output
  or wildcard patterns.
- **Update** computes a complete replacement in memory and writes a file only
  when every required example in that file succeeded.
- **Concurrency:** multiple files may rewrite in parallel; one file has one
  exclusive write key and one atomic rename.

Each example is a single-file package. The build graph builds it against the
same shared library variants as the package tests. Input order defines
presentation order even when execution is parallel.

### 5.5 Standalone examples

```text
discover example files -> parse platform/directive
                       -> skipped(platform)
                       -> build and run(file)
                       -> build(file marked build-only)
all terminal nodes --onCompletion--> command summary
```

`// ci: build-only` selects a build and never executes the binary. Run
arguments remain part of the parsed directive. Platform-ineligible examples
are explicit skipped outcomes. Missing selected files are failed planning
nodes, so fail-fast and summaries treat them consistently.

### 5.6 Documentation commands

| Command                                     | DAG                                                                                                                                                                                       |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `docs links check`                          | file reads -> pure duplicate groups -> report node. Duplicate groups make the report fail.                                                                                                |
| `docs links fix`                            | file reads -> duplicate groups -> one atomic rewrite node per changed file -> report. Reads complete before writes.                                                                       |
| `docs vcs-urls check`                       | one scan node per selected markdown file -> deterministic violation reducer.                                                                                                              |
| `docs sidebar check`                        | load sidebar + load docs config + enumerate tracked docs -> pure bidirectional consistency check -> report.                                                                               |
| `docs blob-paths check`                     | parse citations -> index local clones -> one batched git query node per clone/revision group -> report. Missing clone/revision evidence is degraded; a resolvable missing path is failed. |
| `docs fences audit`                         | load site config + select corpus -> one parse/classification node per file -> aggregate inventory -> optional atomic JSON write -> report.                                                |
| `docs glossary`, `credits`, `spec-evidence` | one check node, reading its inputs and reporting its violations.                                                                                                                          |
| `docs wasm check`                           | build the WebAssembly modules and their native counterparts -> one comparison node per module.                                                                                            |

File selection preserves `--include-files`/`--files` and `--exclude-files`
semantics. Inputs and diagnostics are sorted by normalized repository-relative
path, then source position. Mutating commands never write under `--dry-run`.

### 5.7 CI statistics

```text
resolve repository/options -> fetch workflow-run pages
                           -> fetch jobs for each selected run
job fetches --onCompletion--> normalize available jobs
normalize -> aggregate jobs/runners/steps/comparisons -> render report
```

`ci stats` keeps the data and filtering contract in
[`../stats/SPEC.md`](../stats/SPEC.md). Its network and decoding operations are
task actions and emit ordinary progress events.

Statistics use these degraded semantics:

- Failure to fetch the run list, authenticate, decode required response data,
  or obtain any authoritative population is `Failed` and exits nonzero.
- Failure of one jobs page after at least one complete run remains is
  `Degraded(partialPopulation)`. The report names omitted run ids, counts the
  complete population only, marks all totals partial, and exits zero.
- A requested comparison side with no complete observations is `Failed`; a
  partial side is degraded and visibly marked.
- Missing step timing, runner labels, or optional rate-limit metadata degrades
  only the affected view. It does not invent zero-duration observations.
- Unavailable process RSS/CPU sampling is `Degraded(usageUnavailable)` metadata
  on the task/run. It never changes an otherwise authoritative command outcome.

A degraded report must contain a warning in human output and a structured
`degradations[]` field in JSON. It must never look identical to a complete
report.

### 5.8 Commit checks

```text
read message -> parse subject -> optional staged-path query -> policy check
```

`ci commit-scope` uses the common models and summary but defaults to a compact
reporter suitable for a commit hook. stdin is an explicit input action, not
inherited by subprocess tasks. `ci commits build-each` plans one build of the
selected packages per commit of the range, each in its own scratch worktree,
all on the shared store.

## 6. Build and coverage locations

Compiled output lives in the build graph's shared store, never in a package's
checked-in `build/` directory, the repository root or a private `DUB_HOME`.
Each task that writes anything else gets a task directory under
`build/ci/runs/<run-id>/<task-key>/`. The printable task id stays stable, and
`run-id` is a filesystem name only, never an ordering input. A task directory
holds:

- generated source material for markdown examples;
- spilled output;
- the coverage listings of one coverage attempt, written there through the test
  binary's coverage destination option.

Coverage publication has two stages:

1. Successful coverage attempts are parsed from their task directories and
   merged by normalized source path and line. Hit counts are summed with
   saturation. A coverability disagreement is an error in that file's
   evidence and degrades its report rather than guessing.
2. A single `coverage-publish` node writes a fresh, versioned destination and
   then atomically replaces the `build/coverage` pointer. A cancelled or failed
   run leaves no half-published result. Whether the previous result is kept or
   removed is reported explicitly, and stale data is never presented as this
   run's result.

Package percentages count only files owned by that package. Low coverage is
informational and never fails a task. A package that passes only without
coverage is degraded and omitted from numeric aggregation, not rendered as
zero percent.

Task directories are removed after reporting. A failed task's directory is kept
when the diagnostic policy asks for it, and its path is printed. A dry run
creates none.

## 7. Module layout

| Module                       | Responsibility                                                                                                                 |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `ci_main.d`                  | Executable entry point only.                                                                                                   |
| `app.d`                      | Composition root during migration; domain code leaves it as planners move out.                                                 |
| `cli.d`                      | Canonical subcommands, validation, and help.                                                                                   |
| `reporter_tty.d`             | The interactive reporter over `sparkles:ui`'s `TaskReporter`.                                                                  |
| `commands/test_.d`           | Build-only, ordinary, coverage-fallback, sanitizer, slow and special test planners.                                            |
| `commands/pipeline.d`        | The union graph of every CI job.                                                                                               |
| `commands/docs.d`            | Docs subcommand dispatch and shared file selection.                                                                            |
| `commands/docs_examples.d`   | Markdown run/verify/update graph and reducers.                                                                                 |
| `commands/docs_standalone.d` | Standalone example planner and directives.                                                                                     |
| `commands/docs_checks.d`     | Reference, URL, sidebar, glossary, credits, spec-evidence, blob, fence-audit and WebAssembly planners.                         |
| `commands/stats.d`           | Statistics graph; pure stats remain in `ci_stats.d`.                                                                           |
| `commands/maintenance.d`     | `commits`, `commit-scope`, `cache`, `host`, `checks`, `link-rot` and `slow-tests` planners.                                    |
| Existing pure modules        | `coverage.d`, `dub_deps.d`, `example_manifest.d`, `blob_paths.d`, `docs_sidebar.d` and `fence_audit.d` remain reusable leaves. |

The generic layers live in `sparkles:build-primitives` (see the [task DAG's
module layout](../../build-primitives/task-dag/SPEC.md#9-module-layout)).
Command modules may import them and their domain leaves. They must not import
concrete reporters.

## 8. Acceptance criteria

The implementation is complete when all of these hold:

- Every current work class reaches execution through a validated task graph.
- There is no `std.parallelism` or task-status polling path in `apps/ci`.
- A failed or cancelled command leaves no live child or unreaped process.
- No compile runs through dub, and no library variant is compiled twice in one
  run.
- A second run in another worktree with no source change compiles nothing.
- `--jobs` enforces weighted capacity and exclusive keys.
- Focused package selection is visible under `--dry-run`.
- Default non-TTY transcripts and final summaries are stable under randomized
  completion order.
- TTY output uses `TaskReporter`, degrades without control sequences, and
  restores the terminal on interruption.
- Interlaced output is immediate, line-atomic and prefixed. Replayed task
  blocks are grouped on CI providers that support groups.
- Coverage fallback cannot trigger fail-fast before plain-test classification.
- Degraded stats and coverage are visibly distinct from complete success.
- The parser exposes only the canonical command tree and rejects every removed
  flag.
- `ci pipeline` covers every job `.github/workflows/ci.yml` runs, or names it
  as skipped with its reason.
