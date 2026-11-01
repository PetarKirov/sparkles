---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# `sparkles:build-primitives` task DAG — Specification

## Abstract

The task DAG runs a set of typed tasks with dependencies, and reports them.
A command plans its work as a validated graph of tasks. Each task has a stable
identity, a weighted resource claim and a typed action, and each edge a
condition such as "on success" or "on failure". One executor runs the graph
on Event Horizon fibers under a single job budget, with structured
cancellation. One reporter turns its event stream into deterministic
transcripts, live terminal views or streamed logs. The result is the same
whichever order the work completes in: the outcome, its primary cause and the
plain transcript.

## Introduction

Repository tooling runs many independent jobs: package builds and tests,
documentation examples, link checks, statistics fetches. Run one at a time,
they waste the machine. Run with ad hoc thread pools and polling loops, they
produce logs that change from run to run, failures that depend on timing, and
child processes that outlive an interrupted command.

The hard part is not concurrency itself. Fallback work must run only after a
failure, and summaries even after one. Fail-fast must stop new work, kill
process trees and still drain their output. Heavy jobs must not starve behind a
stream of light ones. And the report must name one primary failure, the same
one on every run.

This package models every unit of work as a task node in a directed acyclic
graph whose edges carry conditions. A single executor fiber owns all graph
state: it admits ready tasks in a fixed presentation order against a weighted
capacity, resolves edges as prerequisites finish, and publishes typed events.
Task actions run on any scheduler worker and report back over bounded
cross-worker channels. Because decisions are made by one owner, in presentation
order, outcomes and the primary failure do not depend on completion order.

The task DAG does not know any particular command. Commands, their graphs, and
the CLI belong to the consumer; the reference consumer is `apps/ci`, specified
in the [`apps/ci` command specification](../../ci/task-dag/SPEC.md). Compiling
packages is the [build graph](../build-graph/SPEC.md)'s job: it lowers builds
into task nodes for this executor. The interactive terminal reporter is
supplied by the consumer, because it needs a UI library this package does not
depend on. Distributed admission across several executor fibers, persistent
scheduler state and a workflow file format are out of scope.

Section 1 states the invariants. Section 2 defines package discovery and focused
selection, §3 the core model, and §4 the execution environment. Then come §5
cancellation, §6 determinism, §7 reporting, including CI-provider integration,
§8 the dry-run projection and §9 the module layout. Delivery history lives in
[PLAN.md](./PLAN.md), and the choices behind the design in
[decisions.md](./decisions.md).

## 1. Invariants

1. **One owner.** A single executor fiber owns admission, edge resolution,
   outcomes and event sequence numbers. Action fibers report observations and
   never change graph state.
2. **Order-independent results.** Outcomes, the primary failure, the exit status
   and the plain transcript (with timings off) are functions of the graph and
   the actions' results, not of completion order.
3. **No polling.** Waiting is parking on Event Horizon: timers, channels,
   process completions. No task path sleeps, polls or spins.
4. **Nothing outlives the run.** When the executor returns, no task fiber,
   child process, pipe or channel user remains.
5. **Bounded memory.** Event channels, output buffers and replay storage are
   bounded; overflow spills to the task's directory or is counted, never
   silently dropped.
6. **One writer.** The reporter fiber is the only writer to the user-facing
   output streams.

## 2. Package discovery and focused selection

### 2.1 Package graph

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

The selected command mode determines the active dub configuration. A test
mode activates the `unittest` configuration when the recipe declares one;
otherwise, and for build modes, it activates the first configuration whose
`platforms` allow the host, as dub does. A package's edges are its top-level
in-tree dependencies plus those of its active configuration. A dependency on
the root package adds no edge, and neither does an optional dependency that is
not on by default.

Package edges are selection data, not ordering edges. They drive the
`--dependencies` and `--dependents` closures (§2.4). A consumer decides which of
them become task edges. A package's test never waits for another package's
test. It waits only for the build actions its own binary needs, which the
[build graph](../build-graph/SPEC.md) derives from these same edges. An
unselected dependency is still built when a selected package needs it. It
acquires no test task of its own unless closure expansion selected it.

### 2.2 `--from`

`--from` may be repeated and each occurrence may take one or more selectors. A
selector matches any of:

- Short package name, such as `base`.
- Qualified name, such as `sparkles:base`.
- Repository-relative directory, such as `libs/base`.
- A git-style glob over any of those forms, such as `sparkles:ui-*` or
  `libs/ui*`. `*` and `?` stop at `/` and `**` crosses it. `\` escapes the
  next character. There are no `[...]` classes.

Matches from all `--from` selectors are unioned. A non-glob selector that
matches nothing is an error. A glob that matches nothing is also an error, so a
misspelled CI selector cannot become a green no-op.

### 2.3 `--since`

`--since REF` computes changes from `merge-base(REF, HEAD)` through the working
tree, including staged, unstaged, and untracked paths. `--since` with no value
resolves the current branch's upstream; if there is none, it tries
`origin/main`. Failure to resolve a base is an actionable selection error.

A path belongs to the package with the longest directory-prefix match. A
deleted path selects both its owner in the current package map and the package
that owned it in the base tree, if that package still exists. A package that
moved therefore stays selected. Changes outside every package do not normally
select a package. Renames count as a deletion plus an addition.

Paths that can change every build select every package. The consumer supplies
these **invalidators** as a declarative list, and the list is unit-tested. It
must not silently grow from arbitrary top-level changes. The repository's list
is part of the [`apps/ci` command specification](../../ci/task-dag/SPEC.md).

### 2.4 Selection algebra

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
explicit platform-skipped node. Which commands accept focused selectors is the
consumer's choice.

## 3. Core model

### 3.1 Task nodes

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
timeout, and task-directory policy as data. In-process actions identify a typed command
handler. Secrets may be marked redacted and are never included in events or dry
runs. A redacted value is passed to the child, and every occurrence of it in a
line the child prints is masked as `<redacted>` before the line reaches an
event or a spool.

### 3.2 Edges

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

A prerequisite's terminal outcome satisfies an edge as follows:

| Condition      | Satisfied by                       |
| -------------- | ---------------------------------- |
| `onSuccess`    | `Succeeded`, `Degraded`, `Skipped` |
| `onFailure`    | `Failed`                           |
| `onCompletion` | every outcome except `Cancelled`   |
| `always`       | every outcome                      |

A skipped prerequisite satisfies `onSuccess`. A skip is an eligibility rule,
not a broken contract, and the build graph still compiles a dependency that has no task.

An edge condition that becomes impossible produces a blocked outcome for the
dependent. A node is decided only once every prerequisite is terminal, so its
outcome never depends on completion order. A blocked node names its
lowest-index impossible prerequisite that descends from a failure, or else its
lowest-index impossible prerequisite. Cleanup nodes are idempotent and execute under a cancellation
protection region.

### 3.3 Resource claims

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

Ready nodes are admitted in presentation order. A node that waits only for an
exclusive key does not hold back later nodes. A node that waits for capacity
stops admission of every later node until it starts. There is no backfilling
past it, so a stream of light nodes cannot starve a heavy one.

Default weights are declared by work kind and may have narrowly documented
package overrides:

| Work kind                               | Default weight                  |
| --------------------------------------- | ------------------------------- |
| Pure scan, parse, reduce, or git query  | 1                               |
| One standalone or markdown D build/run  | 2                               |
| A package build or ordinary test run    | 2                               |
| Extracted `--better-c` or `--wasm` test | 2                               |
| Known DMD-frontend-heavy package task   | 4                               |
| Mutating docs rewrite                   | 1 plus `workspace-write:<path>` |

The host-derived capacity starts from `hwParallelism`, is constrained by the
existing memory/load policy, and retains a hard safety cap. Explicit `--jobs`
sets capacity exactly. LDC compiles a module set on one thread, so a compiler
subprocess needs no codegen-thread cap. Work that does spawn its own threads,
such as the test runner's `-t N`, takes its thread count from the claim the
planner gives it, so task-level parallelism does not multiply into unbounded
threads.

Exclusive keys protect semantic resources, not implementation mutexes. Examples
are `workspace-write:README.md`, `coverage-publish`, and a final destination
artifact. stdout is not an exclusive task resource because the reporter is its
only writer.

### 3.4 Outcomes

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

Every non-success outcome carries a typed reason and causal tasks where
applicable. Outcomes and events name tasks by their index in the validated
graph's presentation order, not by `TaskId`. Their members then hold no
pointers, so a `SumType` of them stays `@safe` to assign and crosses a channel
without borrowing. The graph maps an index back to its node and id. Process status, timeout, signal, bounded output references, elapsed
time, and sampled usage are observations attached to an outcome, not booleans
that replace it.

### 3.5 Events

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
send observations back to it through bounded Event Horizon channels, including
between scheduler workers. Cross-worker delivery preserves ownership and
backpressure; the intra-worker-only `Channel` is not sufficient. Reporters are
consumers and cannot alter scheduling.

Events contain no borrowed child buffers. Event payloads hold no pointers and
name tasks by graph index. An output line travels in the event envelope's
`text` field beside the payload, which keeps the payload `@safe` to move. Output is line-assembled at the
boundary, with an explicit final unterminated line event. Per-task output is
bounded in memory and spills to its task directory when necessary. A failed task's
diagnostic tail and spill path remain available until final reporting.

## 4. Event Horizon-only execution

`sparkles:event-horizon` is the sole concurrency and asynchronous-I/O runtime
inside a task-DAG consumer.

- The command starts one `LoopGroup` and one root structured scope.
- Scheduler tasks are Event Horizon fibers.
- Subprocesses use Event Horizon M19's `supervise` API, piped stdio, async reap,
  and an owned POSIX process group or Windows Job Object.
- Timers and timeouts use the Event Horizon clock. There is no sleep/poll loop.
- Executor communication uses bounded Event Horizon channels with cross-worker
  delivery; the executor is not restricted to one scheduler worker.
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

## 5. Structured cancellation and fail-fast

The root command scope owns all scheduler fibers, child processes, channels,
task directories, and the reporter. A task may not outlive it.

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
8. Cleanup, task-directory removal, and final reporters run inside a protected cleanup
   scope. A `cleanup` node still starts once ready, and its action runs under
   `protect`.

The primary cause is the lowest-index authoritative failure among the
completions the executor collects in one turn. A node the executor interrupted
that then reports `Failed` is recorded as `Cancelled(interrupted)`, because the
interrupt, not the node, caused the failure.

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

## 6. Determinism

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

## 7. Reporting and output

### 7.1 Single writer

One reporter fiber is the only writer to stdout/stderr UI streams. Logger
records that are part of task presentation enter the event channel rather than
writing from workers. This makes every emitted line atomic and keeps terminal
control sequences owned by one component.

### 7.2 Interactive TTY

The TTY reporter is supplied by the consumer, because it depends on a UI
library this package must not import. `apps/ci`'s adapts `sparkles:ui`'s
`TaskReporter` over task events, and must behave as follows:

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

### 7.3 Non-TTY default

Non-TTY output contains no cursor movement, spinner frames, color when terminal
capabilities disable it, or rewritten lines. Task output is buffered/spooled per
node and emitted as a complete prefixed block in `PresentationKey` order once
all earlier blocks are terminal. Each task has exactly one terminal transition
line. This transcript is stable even when jobs finish in a different order.

A block is the task's lines, each prefixed `[<id> <stream>] ` as in interlaced
mode, followed by `<id>: <outcome>`. Elapsed times are the only part that
varies with execution, and they are optional. With them off, the transcript is
byte-identical for the same graph and outcomes.

A heartbeat may report aggregate `completed/total` progress to stderr for a
long silent run, but it contains no task output and is disabled when stderr is
not independently writable. Heartbeats are omitted from machine-readable
output.

### 7.4 `--interlaced`

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
remain sorted. The terminal lines are therefore written together at the end,
in presentation order, rather than as tasks finish.

On a TTY, `--interlaced` disables per-task live tails and prints above a compact
aggregate TaskReporter frame. On non-TTY it is the opt-in path for immediate CI
logs. With `--jobs 1` it still prefixes output but naturally does not mix tasks.

### 7.5 Machine output

A command that owns a JSON mode emits one JSON document and no human UI on
stdout. Logs and warnings go to stderr. Task events may later gain a separate
JSON-lines option, but that is outside v1 and must not be conflated with a
command's report JSON.

### 7.6 CI-provider integration

A reporter that runs under a CI service **must** use that service's log
conventions through one provider module, never by testing environment
variables itself. The module detects the provider and exposes these
operations:

| Operation       | GitHub Actions                   | GitLab CI                                   | Buildkite                  | Azure Pipelines                                             | CircleCI and others        |
| --------------- | -------------------------------- | ------------------------------------------- | -------------------------- | ----------------------------------------------------------- | -------------------------- |
| Detect          | `GITHUB_ACTIONS=true`            | `GITLAB_CI=true`                            | `BUILDKITE=true`           | `TF_BUILD=True`                                             | `CIRCLECI=true`, else none |
| Open a group    | `::group::<title>`               | `section_start:<time>:<id>[collapsed=true]` | `--- <title>`              | `##[group]<title>`                                          | a plain heading line       |
| Close a group   | `::endgroup::`                   | `section_end:<time>:<id>`                   | none                       | `##[endgroup]`                                              | none                       |
| Annotate a line | `::error file=…,line=…::<msg>`   | none                                        | none                       | `##vso[task.logissue type=error;sourcepath=…;linenumber=…]` | none                       |
| Mask a secret   | `::add-mask::<value>`            | none (configured masking)                   | none                       | `##vso[task.setvariable issecret=true]`                     | none                       |
| Step summary    | append to `$GITHUB_STEP_SUMMARY` | none                                        | `buildkite-agent annotate` | none                                                        | none                       |

Rules:

- A provider without an operation degrades to plain output. It never emits
  another provider's syntax.
- A group never contains a partial line. Opening and closing a group are
  ordinary line-atomic writes by the single writer.
- The plain reporter wraps each replayed task block in a group, titled with
  the task id and outcome. In interlaced mode, groups are not used, because
  lines of several tasks interleave.
- A failure that carries a source location is annotated where the provider
  supports it.
- Redacted values are masked on the provider as well as in the task output
  (§3.1).

The module has no dependency on the task DAG and may be used by any tool,
such as the test runner, that reports to a CI service.

## 8. Dry-run contract

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

## 9. Module layout

| Module                                          | Responsibility                                                                                    |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `sparkles.build_primitives.task.action`         | The closed action vocabulary and its redacted summary. A leaf.                                    |
| `sparkles.build_primitives.task.model`          | Task ids, presentation keys, claims, nodes, edges, outcomes and events.                           |
| `sparkles.build_primitives.task.graph`          | The graph builder, validation, stable topological order, edge resolution and the dry-run plan.    |
| `sparkles.build_primitives.task.executor`       | Weighted admission, edge resolution, Event Horizon scopes and cancellation. No command knowledge. |
| `sparkles.build_primitives.task.output`         | The bounded per-task output spool.                                                                |
| `sparkles.build_primitives.task.process`        | The Event Horizon subprocess adapter.                                                             |
| `sparkles.build_primitives.task.reporter`       | The reporter interface, the event consumer and ordered block buffering.                           |
| `sparkles.build_primitives.task.reporter_plain` | The deterministic non-TTY and interlaced reporter.                                                |
| `sparkles.build_primitives.task.testing`        | The fake action driver for executor and reporter tests.                                           |
| `sparkles.build_primitives.workspace.*`         | Package discovery and focused selection (§2).                                                     |
| `sparkles.build_primitives.ci_provider`         | CI-provider detection and log conventions (§7.6).                                                 |

The pure modules — `action`, `model`, `graph` and `workspace` — import neither
Event Horizon nor UI modules. No module in this package imports a UI library.
Reporter modules know events, not commands, and the executor knows action
drivers, not command-line parameters.
