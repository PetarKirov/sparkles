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
    string configuration;    // the active configuration
    PackageId[] dependencies;
    PlatformSet platforms;
}
```

**TDS1: Graph validation.** Discovery **must** reject duplicate ids, unknown
in-tree dependencies, self-edges and cycles before execution. An edge `A -> B`
means B depends on A. Lists are normalized by `PackageId`, never by
associative-array iteration order.

**TDS2: The active configuration.** A test mode **must** activate the
`unittest` configuration when the recipe declares one. Otherwise, and for build
modes, it activates the first configuration whose `platforms` allow the host,
as dub does. A package's edges are its top-level in-tree dependencies plus
those of its active configuration. A dependency on the root package adds no
edge, and neither does an optional dependency that is not on by default.

**TDS3: Package edges are selection data.** Package edges **must** drive only
the `--dependencies` and `--dependents` closures (TDS7). A consumer decides
which of them become task edges.

_Rationale:_ a package's test never waits for another package's test. It
waits only for the build actions its own binary needs, which the
[build graph](../build-graph/SPEC.md) derives from these same edges.

### 2.2 `--from`

**TDS4: Selector matching.** `--from` **may** be repeated, and each occurrence
**may** take one or more selectors. A selector **must** match any of:

- a short package name, such as `base`;
- a qualified name, such as `sparkles:base`;
- a repository-relative directory, such as `libs/base`;
- a git-style glob over any of those forms, such as `sparkles:ui-*` or
  `libs/ui*`. `*` and `?` stop at `/`, `**` crosses it, and `\` escapes the
  next character. There are no `[...]` classes.

Matches from all `--from` selectors are unioned. A selector, glob or not, that
matches nothing **must** be an error, so a misspelled CI selector cannot become
a green no-op.

### 2.3 `--since`

**TDS5: The base revision.** `--since REF` **must** compute changes from
`merge-base(REF, HEAD)` through the working tree, including staged, unstaged
and untracked paths. `--since` with no value resolves the current branch's
upstream, and `origin/main` when there is none. Failure to resolve a base is an
actionable selection error.

**TDS6: Path ownership.** A changed path **must** select:

- every package, if it matches one of the consumer's **invalidators**, checked
  before package ownership;
- otherwise, the package with the longest directory-prefix match;
- for a deleted path, also the package that owned it in the base tree, if that
  package still exists, so a package that moved stays selected.

A rename counts as a deletion plus an addition. A path outside every package
selects nothing. The invalidator list is declarative and unit-tested, and it
does not silently grow from arbitrary top-level changes. The repository's list
is part of the [`apps/ci` command specification](../../ci/task-dag/SPEC.md#4-selection-policy).

### 2.4 Selection algebra

**TDS7: Evaluation order.** Selection **must** be evaluated in this order:

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
10. Sort by stable package id and induce the package edges among the selected
    packages.

**TDS8: Empty selections.** An empty final selection **must** be an error
unless every seed is represented by an explicit platform-skipped node.

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

**TDM1: Stable ids.** A `TaskId` **must** be derived from semantic identity, for
example `test:sparkles.base:unittest` or
`docs:verify:README.md:readme_versions`. It **must not** contain a memory
address, random number, temporary path or discovery index.

**TDM2: Presentation keys.** A `PresentationKey` is a tuple of command phase,
package or file key, work-kind key, and within-owner ordinal. It **must** define
the order of dry-run output, buffered output replay, failure replay and
summaries.

**TDM3: Closed actions.** A `TaskAction` **must** be a closed sum type for known
work, not an arbitrary shell string. A process action carries its argument
vector, environment delta, working directory, stdin policy, timeout and
task-directory policy as data. An in-process action names a typed handler.

**TDM4: Redaction.** An environment value marked redacted **must** be passed to
the child and **must never** appear in an event or a dry run. Every occurrence
of it in a line the child prints is masked as `<redacted>` before the line
reaches an event or a spool.

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

Normal dependency edges use `onSuccess`. Reducers that summarize failed work
use `onCompletion`. Cleanup uses `always`. A fallback uses `onFailure` on its
prerequisite, which has a provisional failure policy (TDC4).

**TDM5: Edge satisfaction.** A prerequisite's terminal outcome **must** satisfy an
edge as follows:

| Condition      | Satisfied by                       |
| -------------- | ---------------------------------- |
| `onSuccess`    | `Succeeded`, `Degraded`, `Skipped` |
| `onFailure`    | `Failed`, provisional `Blocked`    |
| `onCompletion` | every outcome except `Cancelled`   |
| `always`       | every outcome                      |

A skipped prerequisite satisfies `onSuccess`: a skip is an eligibility rule, not
a broken contract. A **provisional block** is a `Blocked` outcome whose root
cause is a failure under a provisional policy (TDC4). It satisfies `onFailure`,
so a fallback attached to the last node of a provisional chain still fires when
an earlier node of that chain failed.

**TDM6: Blocked and unneeded nodes.** A node is decided only once every
prerequisite is terminal, so its outcome never depends on completion order.
When one of its edge conditions is impossible, the first of these rules that
applies decides it:

1. **Unneeded:** if every impossible edge is an `onFailure` edge whose
   prerequisite ended `Succeeded`, `Degraded` or `Skipped`, the node is
   `Blocked(conditionUnmet)`. That outcome never fails the command, and
   summaries count it apart from other blocks: a fallback that was not needed.
2. **Blocked by a failure:** if any impossible prerequisite failed or is a
   block that descends from a failure, the node is `Blocked` and names the
   lowest-index such prerequisite. A failure outranks a cancellation beside it
   (TDC2 item 4). A block whose root cause is a provisional failure is a
   provisional block, which does not fail the command.
3. **Cancelled:** if every impossible prerequisite was cancelled, apart from
   unneeded `onFailure` edges as in rule 1, the node is `Cancelled(notAdmitted)`.
4. **Blocked:** otherwise the node is `Blocked` and names its lowest-index
   impossible prerequisite that is itself blocked.

Cleanup nodes are idempotent and run under a cancellation protection region.

### 3.3 Resource claims

```d
struct ResourceClaim
{
    uint jobsWeight;       // >= 1 for runnable work
    ulong memoryHintBytes; // planning/reporting hint, not a second scheduler
    string[] exclusiveKeys;
}
```

**TDM7: Weighted admission.** The executor **must** own `--jobs N` weighted tokens.
A node starts only when all its exclusive keys are free and `jobsWeight` tokens
are available. A claim larger than total capacity is clamped to total capacity,
so it runs alone rather than deadlocking.

**TDM8: Admission order.** Ready nodes **must** be admitted in presentation order.
A node that waits only for an exclusive key does not hold back later nodes. A
node that waits for capacity stops admission of every later node until it
starts. There is no backfilling past it, so a stream of light nodes cannot
starve a heavy one.

**TDM9: Default weights.** Default weights are declared by work kind. A planner
**may** override them for documented packages:

| Work kind                              | Default weight                  |
| -------------------------------------- | ------------------------------- |
| Pure scan, parse, reduce, or git query | 1                               |
| Build-graph actions                    | per the build graph's BGA8      |
| One standalone or markdown example run | 2                               |
| Known DMD-frontend-heavy package task  | 4                               |
| Mutating docs rewrite                  | 1 plus `workspace-write:<path>` |

**TDM10: Capacity.** Without `--jobs`, capacity **must** be the smaller of
`sparkles.base.hw_caps.hwParallelism()`, which already folds in CPU quotas,
available memory, load and swap, and one unit per GiB of total memory, so a
weight-2 compile has 2 GiB. Explicit `--jobs` sets capacity exactly. Work that
starts its own threads, such as the test runner's `-t N` or a linker, takes its
thread count from its claim, so task-level parallelism does not multiply into
unbounded threads. A single LDC compile is single-threaded and needs no cap.

Exclusive keys protect semantic resources, not implementation mutexes. Examples
are `workspace-write:README.md`, `coverage-publish`, and a final destination
artifact. stdout is not an exclusive task resource, because the reporter is its
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

| Outcome     | Meaning                                                                                 | Fails command                                                                                                    |
| ----------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `Succeeded` | Authoritative work completed and its contract holds.                                    | No                                                                                                               |
| `Failed`    | Work ran, or could not start, and its authoritative contract does not hold.             | Yes                                                                                                              |
| `Skipped`   | A declared eligibility rule excluded the work, such as platform support.                | No                                                                                                               |
| `Cancelled` | Work was admitted or pending but interrupted by fail-fast, signal, or shutdown.         | No additional failure; the initiating cause controls exit.                                                       |
| `Blocked`   | A required predecessor did not succeed or its edge condition was impossible.            | Yes if the block descends from failure; no for `conditionUnmet`; otherwise reported with the cancellation cause. |
| `Degraded`  | The authoritative contract passed, but optional evidence or measurement is unavailable. | No                                                                                                               |

**TDM11: Causes and observations.** Every non-success outcome **must** carry a
typed reason and, where applicable, its causal tasks. Outcomes and events name
tasks by their index in the validated graph's presentation order, not by
`TaskId`, so their members hold no pointers. Process status, timeout, signal,
bounded output references, elapsed time and sampled usage are observations
attached to an outcome, not booleans that replace it.

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

**TDM12: Event sequence.** Every event **must** carry a run-local monotonic
sequence number and a monotonic timestamp. Task output also carries task-local
stream and chunk sequence numbers.

**TDM13: Event producers.** The executor **must** be the sole producer of
lifecycle events. Process and CPU adapters send observations back to it through
bounded Event Horizon channels that deliver across scheduler workers, preserving
ownership and backpressure. Reporters consume events and cannot alter
scheduling.

**TDM14: Owned output.** Events **must not** borrow child buffers. Event payloads
hold no pointers. An output line travels in the event envelope's `text` field,
beside the payload. Output is line-assembled at the boundary, with an explicit
final unterminated line event. Per-task output is bounded in memory and spills
to its task directory when necessary. A failed task's diagnostic tail and spill
path remain available until final reporting.

## 4. Event Horizon-only execution

**TDE1: One runtime.** `sparkles:event-horizon` **must** be the sole concurrency
and asynchronous-I/O runtime inside a task-DAG consumer:

- The command starts one `LoopGroup` and one root structured scope.
- Scheduler tasks are Event Horizon fibers.
- Subprocesses use Event Horizon's supervised runs (`supervise`), with piped
  stdio, asynchronous reap, and an owned POSIX process group or Windows Job
  Object.
- Timers and timeouts use the Event Horizon clock.
- Executor communication uses bounded cross-worker Event Horizon channels.
- Blocking work, including a blocking HTTP client, runs on Event Horizon's
  scheduler-integrated `BlockingPool`, never on a scheduler worker.

**TDE2: Forbidden constructs.** Command and executor modules **must not** use
`std.parallelism.TaskPool`, detached `core.thread.Thread` workers,
`std.process.execute` for task execution, sleep or poll loops, or ad hoc
atomic status polling.

**TDE3: No fallback executor.** Anything represented as a `TaskNode` **must**
execute through the Event Horizon executor. If loop creation fails, the command
reports a structured setup failure. Small bounded planning reads **may** run
synchronously before `LoopGroup.run`.

The executor is generic over the Event Horizon capability row where practical.
Pure graph tests use a deterministic fake action driver and `TestSched` with a
fake clock. Process integration tests use real short-lived children.

## 5. Structured cancellation and fail-fast

**TDC1: Scope ownership.** The root command scope **must** own all scheduler
fibers, child processes, channels, task directories and the reporter. A task
does not outlive it.

**TDC2: Fail-fast.** On an authoritative task failure with `--fail-fast`, the
executor **must**:

1. record `TaskFinished(Failed)` completely;
2. emit `CancellationRequested(failFast, causalTaskId)` exactly once;
3. close admission, so no newly ready ordinary node starts;
4. turn pending nodes into `Cancelled(notAdmitted)`, unless TDM6 decides them
   `Blocked`, for a failed dependency or an unneeded fallback;
5. let running in-process tasks observe scope cancellation at defined yield
   points;
6. send running child process groups `SIGTERM` on POSIX, then `SIGKILL` after a
   bounded grace period; peer platforms use their owned-tree termination;
7. drain stdout and stderr through terminal completion and reap every child;
8. run cleanup, task-directory removal and the final reporters inside a
   protected cleanup scope. A `cleanup` node still starts once ready, and its
   action runs under `protect`.

**TDC3: The primary cause.** The primary cause **must** be the lowest-index
authoritative failure among the completions the executor collects in one turn.
A node the executor interrupted that then reports `Failed` is recorded as
`Cancelled(interrupted)`, because the interrupt, not the node, caused the
failure.

**TDC4: Provisional failures.** A failure of a node with a provisional failure
policy, and a provisional block descending from one, **must not** initiate
fail-fast, fail the command or become the primary cause. Its `onFailure` fallback classifies the authoritative result. A degraded
result does not initiate fail-fast either.

**TDC5: Signals and exit codes.** SIGINT and SIGTERM **must** follow the
fail-fast path with an external-interrupt cause. Exit codes are `130` for
SIGINT, `143` for SIGTERM, and `1` for task or planning failure. Success,
skips and degradations return `0`. A second interrupt shortens the grace
period but still reaps children and restores the terminal.

**TDC6: Without fail-fast.** Without `--fail-fast`, independent branches
**must** continue. Nodes with unsuccessful required predecessors are blocked,
and reducers connected by `onCompletion` still run and summarize the complete
attempted set.

## 6. Determinism

**TDD1: Deterministic results.** For the same repository state, options and
action results, these **must** be identical:

- node ids, the edge set, resource claims and the dry-run plan;
- package and file selection;
- ready-queue tie-breaking, by `PresentationKey` then `TaskId`;
- buffered task-block replay, diagnostics within a block, failure replay and
  final summaries;
- reducer output order;
- the exit status and the primary cause (TDC3).

Task completion times are not deterministic. TTY animation reflects real
completion order, and `--interlaced` exposes runtime output order. Neither
affects final ordering or outcome selection.

**TDD2: Order-independent planning.** Graph construction **must not** depend on
associative-array iteration, directory iteration, completion order, wall-clock
timestamps, random ids or temporary paths. A graph cycle reports the stable
shortest discovered cycle, with ids ordered from its lowest member.

## 7. Reporting and output

### 7.1 Single writer

**TDO1: One writer.** One reporter fiber **must** be the only writer to the
user-facing stdout and stderr streams. Logger records that are part of task
presentation enter the event channel rather than being written from workers.
So every emitted line is atomic, and terminal control sequences have one owner.

### 7.2 Interactive TTY

The TTY reporter is supplied by the consumer, because it depends on a UI
library this package does not import. `apps/ci`'s reporter adapts
`sparkles:ui`'s `TaskReporter` over task events.

**TDO2: TTY behaviour.** A TTY reporter **must**:

- register all planned nodes before execution, so totals do not move;
- show each running task's spinner, elapsed time and a bounded tail;
- graduate terminal transitions into scrollback, in real event order;
- retain a bounded diagnostic tail per failure, and replay failures in
  presentation order after the live region finishes;
- end with a summary of succeeded, failed, degraded, skipped, blocked and
  cancelled counts, plus wall, CPU and RSS statistics when available;
- restore the terminal on success, failure or cancellation, as protected
  cleanup.

It **may** collapse pending tasks past a height limit, with visible counts.

### 7.3 Non-TTY default

**TDO3: Deterministic blocks.** Non-TTY output **must** contain no cursor
movement, spinner frames or rewritten lines, and no colour when terminal
capabilities disable it. Each task's output is buffered or spooled and emitted
as one block in `PresentationKey` order, once all earlier blocks are terminal.

A block is the task's lines, each prefixed `[<id> <stream>] `, followed by
exactly one `<id>: <outcome>` line. The node's output policy decides which lines
the block holds: `replay` holds all of them, `tailOnFailure` only the bounded
tail and only when the task did not succeed, and `none` holds none. Elapsed times are the only part that varies
with execution, and they are optional. With them off, the transcript is
byte-identical for the same graph and outcomes.

A heartbeat **may** report aggregate `completed/total` progress to stderr during
a long silent run. It carries no task output, is disabled when stderr is not
independently writable, and is omitted from machine-readable output.

### 7.4 `--interlaced`

**TDO4: Interlaced lines.** Interlaced mode **must** emit each assembled output
line as soon as the reporter receives it:

```text
[test:sparkles.base:unittest stdout] ...
[test:sparkles.ui:unittest stderr] ...
```

- Prefixes are mandatory even when one task runs.
- A line is never split by another task, and stdout and stderr identity is
  retained.
- An unterminated final fragment is emitted once.
- Ordering across tasks is nondeterministic.

The terminal lines, the failure replay and the summary are written together at
the end, sorted in presentation order.

On a TTY, `--interlaced` disables per-task live tails and prints above a compact
aggregate `TaskReporter` frame. With `--jobs 1` it still prefixes output.

### 7.5 Machine output

**TDO5: JSON documents.** A command that owns a JSON mode **must** emit one JSON
document and no human UI on stdout. Logs and warnings go to stderr. A command's
report JSON is not a task-event stream, and a JSON-lines event stream is out of
scope.

### 7.6 CI-provider integration

**TDO6: One provider module.** A reporter that runs under a CI service **must**
use that service's log conventions through one provider module, never by
testing environment variables itself. The module detects the provider and
exposes these operations:

| Operation       | GitHub Actions                   | GitLab CI                                                             | Buildkite                       | Azure Pipelines                                                  | CircleCI and others        |
| --------------- | -------------------------------- | --------------------------------------------------------------------- | ------------------------------- | ---------------------------------------------------------------- | -------------------------- |
| Detect          | `GITHUB_ACTIONS=true`            | `GITLAB_CI=true`                                                      | `BUILDKITE=true`                | `TF_BUILD=True`                                                  | `CIRCLECI=true`, else none |
| Open a group    | `::group::<title>`               | `\e[0Ksection_start:<unix-time>:<name>[collapsed=true]\r\e[0K<title>` | `--- <title>`                   | `##[group]<title>`                                               | a plain heading line       |
| Close a group   | `::endgroup::`                   | `\e[0Ksection_end:<unix-time>:<name>\r\e[0K`                          | none                            | `##[endgroup]`                                                   | none                       |
| Annotate a line | `::error file=…,line=…::<msg>`   | none                                                                  | none                            | `##vso[task.logissue type=error;sourcepath=…;linenumber=…]<msg>` | none                       |
| Mask a secret   | `::add-mask::<value>`            | none (configured masking)                                             | none                            | `##vso[task.setvariable variable=<name>;issecret=true]<value>`   | none                       |
| Step summary    | append to `$GITHUB_STEP_SUMMARY` | none                                                                  | `buildkite-agent annotate`      | none                                                             | none                       |
| Set an output   | append to `$GITHUB_OUTPUT`       | none (dotenv artifacts)                                               | `buildkite-agent meta-data set` | `##vso[task.setvariable variable=<name>;isOutput=true]<value>`   | none                       |

The provider module's golden tests are checked against each provider's
published syntax, cited in its sources.

**TDO7: Provider rules.**

- A provider without an operation **must** degrade to plain output. It never
  emits another provider's syntax.
- A group never contains a partial line. Opening and closing a group are
  ordinary line-atomic writes by the single writer.
- In block mode, each replayed task block is wrapped in a group titled with the
  task id and outcome.
- In interlaced mode, interleaved lines are never grouped. The closing terminal
  lines and the failure replay are each wrapped in one group.
- A failure that carries a source location is annotated where the provider
  supports it.
- Redacted values (TDM4) are masked on the provider as well as in task output.

The provider module has no dependency on the task DAG, so other tools that
report to a CI service, such as the test runner, can use it.

## 8. Dry-run contract

**TDY1: What a dry run does.** `--dry-run` **must** perform all side-effect-free
discovery needed for a faithful plan: manifest reads, package graph
construction, git change queries for `--since`, the planner's own extraction
and scans, platform evaluation and graph validation.

**TDY2: What a dry run does not do.** A dry run **must not**:

- run task actions or make network requests;
- create build, temporary, coverage, cache or output directories;
- write any file;
- probe optional toolchains by executing them;
- report success for tasks.

**TDY3: Dry-run output.** The output **must** list selection reasons, nodes in
presentation order, resource claims, redacted action summaries, and edges with
their conditions and reasons. It ends with counts by kind and the total
weighted capacity. A planning error exits nonzero. A valid dry run exits zero
and emits no `TaskStarted` events.

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

The CI-provider module is its own leaf package, `sparkles:ci-provider` (see
[decisions.md](./decisions.md#t8-the-ci-provider-module-is-a-leaf-package)).

The pure modules — `action`, `model`, `graph` and `workspace` — import neither
Event Horizon nor UI modules. No module in this package imports a UI library.
Reporter modules know events, not commands, and the executor knows action
drivers, not command-line parameters.
