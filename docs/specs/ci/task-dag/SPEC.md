# `apps/ci` task DAG architecture

_Audience: developers and coding agents implementing or extending `apps/ci`.
This document is normative. It specifies the target architecture and command
semantics. The independently green delivery sequence is in
[PLAN.md](./PLAN.md). The canonical command tree replaces the existing flat
mode flags; repository consumers migrate atomically with the cutover._

## 1. Purpose

`apps/ci` has one execution model: commands plan typed tasks into a directed
acyclic graph, one Event Horizon executor runs that graph, and one reporter
consumes its event stream. Commands do not own worker pools, process polling,
fail-fast loops, live regions, or ad hoc result summaries.

The architecture has these goals:

- Represent dependencies and conditional fallback explicitly.
- Run independent work concurrently without racing dub artifacts or coverage
  listings.
- Bound heterogeneous work with weighted job capacity, not an unbounded thread
  count.
- Cancel process trees and sibling tasks structurally.
- Keep selection, summaries, and ordinary non-TTY output deterministic.
- Preserve useful live output on a TTY and offer explicitly interlaced output
  when immediate logs matter more than ordering.
- Give every current `apps/ci` work class a plan, outcome, and event history.

This is an orchestration architecture, not a general workflow language. Graphs
are built in memory for one invocation. There is no YAML task format, remote
cache protocol, daemon, or persistent scheduler state.

## 2. Command surface

### 2.1 Canonical commands

```text
ci test [--build-only | --special-modes betterc|wasm|all]
        [--from SELECTOR...] [--since REF]
        [--dependencies] [--dependents]
        [--coverage | --no-coverage] [--fail-fast]

ci docs examples [--include-files SELECTOR...] [--exclude-files SELECTOR...]
                 [--fail-fast]
ci docs run|verify|update
        [--include-files SELECTOR...] [--exclude-files SELECTOR...]
        [--fail-fast]
ci docs links check|fix
        [--include-files SELECTOR...] [--exclude-files SELECTOR...]
ci docs vcs-urls check
        [--include-files SELECTOR...] [--exclude-files SELECTOR...]
ci docs sidebar check
ci docs blob-paths check [--clone-root DIR]
        [--include-files SELECTOR...] [--exclude-files SELECTOR...]
ci docs fences audit [--root DIR] [--audit-scope site|all|excluded]
        [--json FILE] [--include-files SELECTOR...]

ci stats [existing stats options]
ci commit-scope [COMMIT_MESSAGE_FILE|-]
```

Every command that executes a graph accepts:

| Option              | Default               | Meaning                                                                                                                                          |
| ------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `--jobs N`          | host-derived capacity | Positive weighted capacity available to running tasks. It is not a count of OS threads.                                                          |
| `--interlaced`      | off                   | Stream line-atomic, task-prefixed output as events arrive instead of replaying complete task blocks in presentation order.                       |
| `--dry-run`         | off                   | Discover, select, plan, validate, and print the DAG without running task actions, making network requests, creating sandboxes, or writing files. |
| `--fail-fast`       | off                   | On the first authoritative failure, stop admission and cancel the command scope as specified in section 8.                                       |
| `--log-level LEVEL` | `info`                | Standard Sparkles logger level.                                                                                                                  |

`--jobs 0` and negative values are errors. `--dry-run --interlaced` is rejected
because a dry run has no task output to interlace. `SPARKLES_CI_JOBS` remains an
environment fallback; an explicit `--jobs` wins. Invalid combinations fail
before task execution.

### 2.2 `ci test` modes

With no mode option, `ci test` creates ordinary `dub test` tasks. Coverage is
on by default for this mode and can be disabled with `--no-coverage`.

`ci test --build-only` creates `dub build` tasks and does not run tests. It is
the canonical replacement for the old `--build` mode. Coverage is invalid.

`ci test --special-modes MODE` creates the test runner's extracted special-mode
tasks. `MODE` is a wired enum whose CLI spellings are `betterc`, `wasm`, and
`all`; core-cli's `?`/`help` value-help forms list those values. A selected
package receives a node only for marker attributes present in its sources and
only if it integrates `sparkles:test-runner`. Every special invocation passes
`--self-test` and `--require-toolchain`. An empty repository-wide special-mode
plan is an error, not a successful no-op. Coverage is invalid for special modes.

`--build-only` and `--special-modes` are mutually exclusive. Supplying
`--special-modes` selects special modes instead of ordinary unittests. Separate
invocations are used when both ordinary and extracted tests are required by CI.

### 2.3 Removed flat mode flags

The former `--build`, `--test`, `--test-extracted`, `--example-files`, default
markdown mode, and other flat mode flags are removed at cutover. Active
workflows, hooks, and documentation migrate in the same change. There is no
legacy parser, alias translation, precedence table, or fallback dispatch path.

## 3. Yarn inspiration and Sparkles differences

The focused package selectors and output vocabulary intentionally resemble
Yarn's workspace `foreach` command:

- `--from` establishes workspace-like package seeds.
- `--since` selects packages changed from a revision.
- `--dependencies` and `--dependents` expand graph closure.
- `--jobs` bounds parallel work.
- `--interlaced` opts into immediate mixed output.
- Dependency edges provide topological execution.

Sparkles differs in load-bearing ways:

| Yarn-inspired idea  | Sparkles definition                                                                                                                              |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| Workspace           | A root `dub.sdl` sub-package with a stable package name and repository-relative directory. The root package is metadata, not an executable task. |
| Topological command | The induced in-tree dub dependency graph. A dependency task must complete successfully before its selected dependent may start.                  |
| Job count           | Weighted capacity. A compiler-heavy task can consume more than one unit.                                                                         |
| `--from`            | Matches Sparkles package name, qualified name, or path. It does not mean "start at this textual position."                                       |
| `--since`           | Uses Git change ownership plus explicit repository-wide invalidators, not workspace manifest timestamps.                                         |
| Recursive selection | Explicit `--dependencies` and `--dependents`; there is no implicit Yarn `-R`/`-A` mode.                                                          |
| Interlacing         | Line-atomic, prefixed event streaming on TTY and non-TTY alike. Raw byte chunks are never written concurrently.                                  |
| Failure             | A structured `Outcome`, with blocked, cancelled, skipped, and degraded distinct from failed.                                                     |
| Execution           | Event Horizon scopes, subprocesses, clocks, and wakeups only. No `std.parallelism` pool or polling thread is permitted.                          |
| Cache               | No task-result cache in v1. Dub may use a sandbox-local dependency cache, but prior task success is never inferred from it.                      |

Yarn behavior is therefore a usability reference, not an external compatibility
contract.

## 4. Package discovery and focused selection

### 4.1 Package graph

Discovery reads the root `dub.sdl`, each sub-package manifest, and the selected
configuration's in-tree dependencies. Each package has:

```d
struct Package
{
    PackageId id;            // stable qualified package name
    string shortName;        // e.g. "base"
    string path;             // e.g. "libs/base"
    PackageId[] dependencies;
    PlatformSet platforms;
}
```

An edge `A -> B` means B depends on A. Graph validation rejects duplicate ids,
unknown in-tree dependencies, self-edges, and cycles before execution. Lists are
normalized by `PackageId`, never associative-array iteration order.

The selected command mode determines the active dub configuration. Dependency
edges are induced only between selected packages. An unselected dependency may
still be compiled by dub, but it does not acquire a separate CI task unless
closure expansion selected it.

### 4.2 `--from`

`--from` may be repeated and each occurrence may take one or more selectors. A
selector matches any of:

- Short package name, such as `base`.
- Qualified name, such as `sparkles:base`.
- Repository-relative directory, such as `libs/base`.
- A git-style glob over any of those forms, such as `sparkles:ui-*` or
  `libs/ui*`.

Matches from all `--from` selectors are unioned. A non-glob selector that
matches nothing is an error. A glob that matches nothing is also an error, so a
misspelled CI selector cannot become a green no-op.

### 4.3 `--since`

`--since REF` computes changes from `merge-base(REF, HEAD)` through the working
tree, including staged, unstaged, and untracked paths. `--since` with no value
resolves the current branch's upstream; if there is none, it tries
`origin/main`. Failure to resolve a base is an actionable selection error.

A path belongs to the package with the longest directory-prefix match. A
deleted path is resolved against both the base tree and current package map.
Changes outside every package do not normally select a package.

These repository-wide inputs select every package because they can change all
builds:

- Root `dub.sdl`, `dub.selections.json`, and `nix/dub-lock.json`.
- Compiler and package construction under `nix/d-toolchain.nix` and
  `nix/packages/dub-builder/`.
- CI command construction or package-discovery modules under `apps/ci/` when
  the selected set would otherwise omit `ci`.

The invalidator list is declarative and unit-tested. It must not silently grow
from arbitrary top-level changes.

### 4.4 Selection algebra

Selection is evaluated in this order:

1. Discover and validate the full package graph.
2. If neither `--from` nor `--since` is present, seed all packages.
3. If only `--from` is present, seed its union of matches.
4. If only `--since` is present, seed changed packages.
5. If both are present, seed the union of both match sets.
6. If `--dependencies` is present, add the transitive dependency closure.
7. If `--dependents` is present, add the transitive reverse-dependency closure.
8. If both closure flags are present, compute both to a fixed point from the
   original seed. The result is the union, not an order-dependent expansion.
9. Apply platform eligibility. Ineligible packages remain visible as skipped
   nodes rather than disappearing.
10. Sort by stable package id and build the induced task graph.

An empty final selection is an error unless every seed was represented by an
explicit platform-skipped node. Focused selectors are accepted only by
`ci test`; docs and example commands retain their file selectors.

## 5. Core model

### 5.1 Task nodes

```d
struct TaskNode
{
    TaskId id;                 // stable, unique, printable
    TaskKind kind;
    string label;
    PresentationKey order;
    ResourceClaim resources;
    TaskAction action;
    FailurePolicy failurePolicy;
    OutputPolicy outputPolicy;
}
```

`TaskId` is derived from semantic identity, for example
`test:sparkles.base:unittest` or `docs:verify:README.md:readme_versions`. It does
not contain a memory address, random number, temporary path, or discovery index.

`PresentationKey` is a tuple of command phase, package/file key, work-kind key,
and within-owner ordinal. It defines dry-run output, buffered output replay,
failure replay, and summaries.

`TaskAction` is a closed sum type for known work, not an arbitrary shell string.
The process variant contains argv, environment delta, cwd, stdin policy,
timeout, and sandbox policy as data. In-process actions identify a typed command
handler. Secrets may be marked redacted and are never included in events or dry
runs.

### 5.2 Edges

```d
enum EdgeCondition { onSuccess, onFailure, onCompletion, always }

struct TaskEdge
{
    TaskId prerequisite;
    TaskId dependent;
    EdgeCondition condition;
    EdgeReason reason;
}
```

Normal dependency edges use `onSuccess`. Reducers that must summarize failed
work use `onCompletion`. Cleanup uses `always`. Coverage fallback uses
`onFailure`, with the first attempt's failure policy suppressing fail-fast until
the fallback classifies the package result.

An edge condition that becomes impossible produces a blocked outcome for the
dependent. Cleanup nodes are idempotent and execute under a cancellation
protection region.

### 5.3 Resource claims

```d
struct ResourceClaim
{
    uint jobsWeight;       // >= 1 for runnable work
    ulong memoryHintBytes; // planning/reporting hint, not a second scheduler
    string[] exclusiveKeys;
}
```

The executor owns `--jobs N` weighted tokens. A node starts only when all its
exclusive keys are free and `jobsWeight` tokens are available. A claim larger
than total capacity is clamped to total capacity so it runs alone rather than
deadlocking.

Default weights are declared by work kind and may have narrowly documented
package overrides:

| Work kind                               | Default weight                  |
| --------------------------------------- | ------------------------------- |
| Pure scan, parse, reduce, or git query  | 1                               |
| One standalone or markdown D build/run  | 2                               |
| `dub build` or ordinary `dub test`      | 2                               |
| Extracted `--better-c` or `--wasm` test | 2                               |
| Known DMD-frontend-heavy package task   | 4                               |
| Mutating docs rewrite                   | 1 plus `workspace-write:<path>` |

The host-derived capacity starts from `hwParallelism`, is constrained by the
existing memory/load policy, and retains a hard safety cap. Explicit `--jobs`
sets capacity exactly. Compiler subprocesses receive an LDC codegen-thread cap
derived from their claim and currently free capacity so task-level parallelism
does not multiply into unbounded compiler threads.

Exclusive keys protect semantic resources, not implementation mutexes. Examples
are `workspace-write:README.md`, `coverage-publish`, and a final destination
artifact. stdout is not an exclusive task resource because the reporter is its
only writer.

### 5.4 Outcomes

```d
alias TaskOutcome = SumType!(
    Succeeded,
    Failed,
    Skipped,
    Cancelled,
    Blocked,
    Degraded,
);
```

| Outcome     | Meaning                                                                                 | Fails command                                                                           |
| ----------- | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `Succeeded` | Authoritative work completed and its contract holds.                                    | No                                                                                      |
| `Failed`    | Work ran, or could not start, and its authoritative contract does not hold.             | Yes                                                                                     |
| `Skipped`   | A declared eligibility rule excluded the work, such as platform support.                | No                                                                                      |
| `Cancelled` | Work was admitted or pending but interrupted by fail-fast, signal, or shutdown.         | No additional failure; the initiating cause controls exit.                              |
| `Blocked`   | A required predecessor did not succeed or its edge condition was impossible.            | Yes if the block descends from failure; otherwise reported with the cancellation cause. |
| `Degraded`  | The authoritative contract passed, but optional evidence or measurement is unavailable. | No                                                                                      |

Every non-success outcome carries a typed reason and causal task ids where
applicable. Process status, timeout, signal, bounded output references, elapsed
time, and sampled usage are observations attached to an outcome, not booleans
that replace it.

### 5.5 Events

```d
alias TaskEvent = SumType!(
    GraphPlanned,
    TaskReady,
    TaskStarted,
    TaskOutput,
    TaskUsage,
    TaskFinished,
    CancellationRequested,
    RunFinished,
);
```

Every event has a run-local monotonic sequence number and monotonic timestamp.
Task output additionally has task-local stream and chunk sequence numbers. The
executor is the sole producer of lifecycle events; process and CPU adapters
send observations back to it through Event Horizon channels. Reporters are
consumers and cannot alter scheduling.

Events contain no borrowed child buffers. Output is line-assembled at the
boundary, with an explicit final unterminated line event. Per-task output is
bounded in memory and spills to its sandbox when necessary. A failed task's
diagnostic tail and spill path remain available until final reporting.

## 6. Graphs for current work

The diagrams show graph shape. Real node ids include package/file identity.

### 6.1 Package build-only

```text
discover packages -> select packages -> validate graph
                                      -> build dependency A -> build dependent B
                                      -> build independent C
all selected build nodes --onCompletion--> run summary
```

Each build node executes `dub build :name` with the checked/debug behavior
already selected by command construction. Dependency edges are induced among
selected packages. A failed dependency blocks its selected dependents.

### 6.2 Ordinary package tests and coverage

```text
discover -> select -> prepare run
                  -> coverage test A --success-------------------+
                                     --failure--> plain test A ---+-> classify A
                  -> coverage test B --success-------------------+-> classify B
all classifications --onCompletion--> merge coverage -> coverage report
all classifications --onCompletion--> run summary
```

Without coverage, each package has one ordinary test node and one classification
node. With coverage, every package writes listings to its own task directory.
A coverage attempt failure schedules a plain retry. If plain tests pass, the
package classification is `Degraded(noCoverage)`; if plain tests fail, it is
`Failed`, retaining both attempts. The initial coverage failure is provisional
and does not trigger fail-fast.

The coverage reducer runs after all package classifications, even when some
failed. It merges only valid successful coverage attempts, reports failed and
unmeasured packages, and publishes the final listing set atomically.

### 6.3 Extracted test modes

```text
discover -> select -> scan marker attributes
                  -> better-c(package A)
                  -> wasm(package A)
                  -> wasm(package B)
all special nodes --onCompletion--> run summary
```

The marker scan is a planning action. Special nodes use the same selected
package dependency edges within each mode. Different modes for the same package
are independent unless resource capacity serializes them.

### 6.4 Markdown examples

```text
discover markdown -> parse each file -> execute each runnable example
                                     -> skipped directive outcome
execute nodes --onCompletion--> file run/verify reducer
file reducers --onCompletion--> command summary

update only:
file reducer --onSuccess--> atomic rewrite(file)
```

`docs run`, `docs verify`, and `docs update` share discovery, extraction,
in-tree dependency rewriting, process execution, and result models. Run renders
captured output. Verify compares normalized output or wildcard patterns. Update
computes a complete replacement in memory and writes a file only when every
required example in that file succeeded. Multiple files may rewrite in
parallel; one file has one exclusive write key and one atomic rename.

Each markdown example gets a private source directory, `DUB_HOME`, and temp
build root. Input order defines presentation order even when execution is
parallel.

### 6.5 Standalone examples

```text
discover example files -> parse platform/directive
                       -> skipped(platform)
                       -> dub run(file)
                       -> dub build(file marked build-only)
all terminal nodes --onCompletion--> command summary
```

`// ci: build-only` selects a build action and never executes the binary.
Run arguments remain part of the parsed directive. Platform-ineligible examples
are explicit skipped outcomes. Missing selected files are failed planning
nodes, so fail-fast and summaries treat them consistently.

### 6.6 Documentation commands

All current documentation work is represented as follows:

| Command                 | DAG                                                                                                                                                                                       |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `docs links check`      | file reads -> pure duplicate groups -> report node. Duplicate groups make the report fail.                                                                                                |
| `docs links fix`        | file reads -> duplicate groups -> one atomic rewrite node per changed file -> report. Reads complete before writes.                                                                       |
| `docs vcs-urls check`   | one scan node per selected markdown file -> deterministic violation reducer.                                                                                                              |
| `docs sidebar check`    | load sidebar + load docs config + enumerate tracked docs -> pure bidirectional consistency check -> report.                                                                               |
| `docs blob-paths check` | parse citations -> index local clones -> one batched git query node per clone/revision group -> report. Missing clone/revision evidence is degraded; a resolvable missing path is failed. |
| `docs fences audit`     | load site config + select corpus -> one parse/classification node per file -> aggregate inventory -> optional atomic JSON write -> report.                                                |

File selection preserves `--include-files`/`--files` and `--exclude-files`
semantics. Inputs and diagnostics are sorted by normalized repository-relative
path, then source position. Mutating commands never write under `--dry-run`.

### 6.7 CI statistics

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

### 6.8 Commit-scope check

```text
read message -> parse subject -> optional staged-path query -> policy check
```

This small command still uses the common models and summary but defaults to a
compact reporter suitable for a commit hook. stdin is an explicit input action,
not inherited by subprocess tasks.

## 7. Event Horizon-only execution

`sparkles:event-horizon` is the sole concurrency and asynchronous-I/O runtime
inside `apps/ci`.

- The command starts one `LoopGroup` and one root structured scope.
- Scheduler tasks are Event Horizon fibers.
- Subprocesses use Event Horizon M19's `supervise` API, piped stdio, async reap,
  and an owned POSIX process group or Windows Job Object.
- Timers and timeouts use the Event Horizon clock. There is no sleep/poll loop.
- Executor communication uses bounded Event Horizon channels.
- Blocking or CPU work that should leave the loop thread uses Event Horizon's
  scheduler-integrated `BlockingPool`; completion wakes the loop through its
  supported seam.
- Legacy blocking adapters, including an HTTP implementation not yet native to
  `sparkles:http`, run only through that Event Horizon-owned CPU-job path. They
  never block a scheduler worker.
- `std.parallelism.TaskPool`, detached `core.thread.Thread` workers,
  `std.process.execute` for task execution, and ad hoc atomic status polling are
  forbidden in command and executor modules.

Small bounded planning reads may run synchronously before `LoopGroup.run`.
Anything represented as a `TaskNode` executes through the Event Horizon
executor. There is no fallback executor when Event Horizon loop creation fails;
the command reports a structured setup failure.

The executor is generic over the Event Horizon capability row where practical.
Pure graph tests use a deterministic fake action driver and `TestSched`/fake
clock. Process integration tests use real short-lived children.

## 8. Structured cancellation and fail-fast

The root command scope owns all scheduler fibers, child processes, channels,
sandboxes, and the reporter. A task may not outlive it.

On an authoritative task failure with `--fail-fast`:

1. The executor records `TaskFinished(Failed)` completely.
2. It emits `CancellationRequested(failFast, causalTaskId)` exactly once.
3. It closes admission. No newly ready ordinary node starts.
4. Pending nodes become `Cancelled(notAdmitted)` unless a failed dependency
   makes them `Blocked`.
5. Running in-process tasks observe scope cancellation at defined yield points.
6. Running child process groups receive `SIGTERM` on POSIX, then `SIGKILL`
   after a bounded grace period. Peer platforms use the equivalent owned-tree
   termination primitive.
7. stdout/stderr pipes are drained through terminal completion and every child
   is reaped.
8. Cleanup, sandbox removal, and final reporters run inside a protected cleanup
   scope.

Coverage-attempt failure is provisional and does not initiate fail-fast. Its
plain fallback classifies the authoritative package result. A degraded result
does not initiate fail-fast.

SIGINT and SIGTERM follow the same path with an external-interrupt cause. Exit
codes are `130` for SIGINT, `143` for SIGTERM, and `1` for task/planning failure.
Success, skips, and degradations return `0`. A second interrupt shortens the
grace period but still attempts child reap and terminal restoration.

Without `--fail-fast`, independent branches continue. Nodes with unsuccessful
required predecessors become blocked; reducers connected by `onCompletion`
still run and summarize the complete attempted set.

## 9. Determinism

The following are deterministic for the same repository state, options, and
declared action outcomes:

- Node ids, edge set, resource claims, and dry-run plan.
- Package and file selection.
- Ready-queue tie-breaking by `PresentationKey`, then `TaskId`.
- Buffered task-block replay, diagnostics within a block, failure replay, and
  final summaries.
- Coverage merge and report ordering.
- Exit status and causal failure selection. If multiple failures arrive in one
  loop turn, the lowest presentation key is the primary cause.

Actual task completion times are not deterministic. TTY live animation reflects
real completion order, and `--interlaced` intentionally exposes runtime output
order. Neither may affect final ordering or outcome selection.

Graph construction must not depend on associative-array iteration, directory
iteration, completion order, wall-clock timestamps, random ids, or temporary
paths. A graph cycle reports the stable shortest discovered cycle with ids
ordered from its lowest member.

## 10. Reporting and output

### 10.1 Single writer

One reporter fiber is the only writer to stdout/stderr UI streams. Logger
records that are part of task presentation enter the event channel rather than
writing from workers. This makes every emitted line atomic and keeps terminal
control sequences owned by one component.

### 10.2 Interactive TTY

The default TTY reporter adapts `TaskReporter` over task events:

- All planned nodes register before execution so totals do not move.
- Running tasks show spinner, elapsed time, and a bounded tail.
- Pending tasks may be collapsed after a height limit, with visible counts.
- Terminal transitions graduate into scrollback.
- Failures retain a bounded diagnostic tail and are replayed in deterministic
  presentation order after the live region finishes.
- The final summary contains succeeded, failed, degraded, skipped, blocked, and
  cancelled counts plus wall/CPU/RSS statistics when available.

TaskReporter graduation follows real event order because it is a live view. The
post-live failure replay and summary are deterministic. Terminal restoration is
protected cleanup and runs on success, failure, or cancellation.

### 10.3 Non-TTY default

Non-TTY output contains no cursor movement, spinner frames, color when terminal
capabilities disable it, or rewritten lines. Task output is buffered/spooled per
node and emitted as a complete prefixed block in `PresentationKey` order once
all earlier blocks are terminal. Each task has exactly one terminal transition
line. This transcript is stable even when jobs finish in a different order.

A heartbeat may report aggregate `completed/total` progress to stderr for a
long silent run, but it contains no task output and is disabled when stderr is
not independently writable. Heartbeats are omitted from machine-readable
output.

### 10.4 `--interlaced`

Interlaced mode emits each assembled output line as soon as the reporter
receives it:

```text
[test:sparkles.base:unittest stdout] ...
[test:sparkles.ui:unittest stderr] ...
```

Prefixes are mandatory even when only one task currently runs. A line is never
split by another task, stdout and stderr identity is retained, and an
unterminated final fragment is emitted once. Ordering across tasks is explicitly
nondeterministic. Final terminal lines, failure summaries, and aggregate tables
remain sorted.

On a TTY, `--interlaced` disables per-task live tails and prints above a compact
aggregate TaskReporter frame. On non-TTY it is the opt-in path for immediate CI
logs. With `--jobs 1` it still prefixes output but naturally does not mix tasks.

### 10.5 Machine output

A command that owns a JSON mode emits one JSON document and no human UI on
stdout. Logs and warnings go to stderr. Task events may later gain a separate
JSON-lines option, but that is outside v1 and must not be conflated with a
command's report JSON.

## 11. Build and coverage isolation

Every compiler-bearing node has a sandbox under a run directory such as
`build/ci/runs/<run-id>/<task-key>/`. The printable task id remains stable;
`run-id` is filesystem-only and never affects ordering.

Each sandbox owns:

- Temporary source material generated for markdown examples.
- A private writable `DUB_HOME`.
- A private dub build root selected with `--temp-build` or the equivalent
  explicit build setting.
- Captured/spilled output.
- Coverage listings for that attempt.

Concurrent tasks never write a package's checked-in `build/` directory, the
repository root, another task's `DUB_HOME`, or the final coverage directory.
Dependency downloads may be seeded from a prepared read-only cache snapshot;
the task always writes to its private cache. Correctness must not depend on the
snapshot.

Coverage publication has two stages:

1. Successful coverage attempts are parsed from private directories and merged
   by normalized source path and line. Hit counts are summed with saturation;
   coverability disagreements are errors in that file's evidence and degrade
   its report rather than guessing.
2. A single `coverage-publish` node writes a fresh temporary destination and
   atomically replaces `build/coverage`. A cancelled or failed run leaves no
   half-published directory. Whether the previous complete directory is kept or
   removed is reported explicitly; stale data is never presented as this run's
   result.

Package percentages count only files owned by that package. Low coverage is
informational and never fails a task. A package that passes only without
coverage is degraded and omitted from numeric aggregation, not rendered as
zero percent.

Sandbox cleanup runs after reporting. Failed sandboxes are retained when
requested by the diagnostic policy and their paths are printed; successful
sandboxes are removed. Dry-run creates none.

## 12. Dry-run contract

`--dry-run` performs all side-effect-free discovery needed for a faithful plan,
including manifest reads, package graph construction, git change queries for
`--since`, markdown extraction, marker scans, platform evaluation, and graph
validation.

It does not:

- Spawn task actions or contact GitHub.
- Create build, temp, coverage, cache, or output directories.
- Rewrite documentation.
- Probe optional toolchains by executing them.
- Claim success for tasks.

The output lists selection reasons, nodes in presentation order, resource
claims, redacted action summaries, and edges with conditions/reasons. It ends
with counts by kind and total weighted capacity. A planning error still exits
nonzero. A valid dry run exits zero and emits no `TaskStarted` events.

## 13. Module layout

The target layout keeps models and planners independent from execution and UI:

| Module                       | Responsibility                                                                                                                                                                         |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ci_main.d`                  | Executable entry point only.                                                                                                                                                           |
| `app.d`                      | Composition root during migration; domain code leaves it as planners move out.                                                                                                         |
| `cli.d`                      | Canonical subcommands, validation, and help.                                                                                                                                           |
| `task/model.d`               | Task ids, nodes, edges, resources, outcomes, events. Leaf module.                                                                                                                      |
| `task/graph.d`               | Graph builder, validation, stable topological utilities, dry-run projection.                                                                                                           |
| `task/executor.d`            | Weighted admission, edge resolution, Event Horizon scopes, cancellation. No command knowledge.                                                                                         |
| `task/action.d`              | Closed action vocabulary and handler dispatch.                                                                                                                                         |
| `task/process.d`             | Event Horizon child-process adapter, pipe events, timeout, process-group termination.                                                                                                  |
| `task/reporter.d`            | Event consumer interface and shared ordered buffering.                                                                                                                                 |
| `task/reporter_tty.d`        | `TaskReporter` live implementation.                                                                                                                                                    |
| `task/reporter_plain.d`      | Deterministic non-TTY and interlaced implementation.                                                                                                                                   |
| `workspace/package_graph.d`  | Dub package discovery and dependency graph.                                                                                                                                            |
| `workspace/select.d`         | `--from`, `--since`, dependency/dependent closure, selection reasons.                                                                                                                  |
| `workspace/sandbox.d`        | Run/task paths, private dub homes/build roots, cleanup.                                                                                                                                |
| `commands/test_.d`           | Build-only, ordinary, coverage-fallback, and special test planners.                                                                                                                    |
| `commands/docs_standalone.d` | `ci docs examples` standalone example planner and directives.                                                                                                                          |
| `commands/docs.d`            | Docs subcommand dispatch and shared file selection.                                                                                                                                    |
| `commands/docs_examples.d`   | Markdown run/verify/update graph and reducers.                                                                                                                                         |
| `commands/docs_checks.d`     | Reference, URL, sidebar, blob, and fence-audit planners.                                                                                                                               |
| `commands/stats.d`           | Statistics graph; pure stats remain in `ci_stats.d` until separately reorganized.                                                                                                      |
| Existing pure modules        | `coverage.d`, `dub_deps.d`, `example_manifest.d`, `blob_paths.d`, `docs_sidebar.d`, and `fence_audit.d` remain reusable leaves and move only when a split materially improves imports. |

Command modules may import model/graph/workspace and their domain leaves. They
must not import concrete reporters. Reporter modules know events, not commands.
The executor knows action handlers, not CLI parameter structs. Pure modules do
not import Event Horizon or UI modules.

## 14. Invariants and acceptance criteria

The implementation is complete when all of these hold:

- Every current work class reaches execution through a validated `TaskGraph`.
- There is no `std.parallelism` or task-status polling path in `apps/ci`.
- A failed/cancelled command leaves no live child or unreaped process.
- No concurrent compiler task shares a writable build/cache/coverage location.
- `--jobs` enforces weighted capacity and exclusive keys.
- Focused package selection follows section 4 exactly and is visible under
  `--dry-run`.
- Default non-TTY transcripts and final summaries are stable under randomized
  completion order.
- TTY output uses TaskReporter, degrades without control sequences, and restores
  the terminal on interruption.
- Interlaced output is immediate, line-atomic, and prefixed.
- Coverage fallback cannot trigger fail-fast before plain-test classification.
- Degraded stats and coverage are visibly distinct from complete success.
- The parser exposes only the canonical command tree and rejects removed flat
  mode flags.

Performance is bounded by useful work: the executor has no periodic polling
wakeup while idle, event buffering is bounded, and planning remains linear in
nodes plus edges apart from explicit sorting for deterministic presentation.
