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
ci pipeline [--from SELECTOR...] [--since REF] [--dependencies] [--dependents]
            [--backend local|nix] [--require-cached KIND...]
            [--determinism-sample N] [--placement NAME]
ci placements list [--provider github|circleci] [--github-output FILE]
                   [--history-remote URL]

ci test [--build-only [--host CONFIG...] | --special-modes off|betterc|wasm|all]
        [--from SELECTOR...] [--since REF]
        [--dependencies] [--dependents]
        [--coverage | --no-coverage] [--sanitize off|address]
        [--slow [--tests NAME...]] [--backend local|nix]
        [--require-cached KIND...] [--watch]
        [--placement NAME --shard K/N [--history-tip COMMIT]]
        [--history-remote URL]

ci examples run|verify|update [--include-files SELECTOR...] [--exclude-files SELECTOR...]
ci examples standalone [--include-files SELECTOR...] [--exclude-files SELECTOR...]

ci check commit-scope [COMMIT_MESSAGE_FILE|-]
ci check reference-links|vcs-urls [--include-files SELECTOR...] [--exclude-files SELECTOR...]
ci check blob-paths [--clone-root DIR] [--include-files SELECTOR...]
ci check sidebar|glossary|credits|spec-evidence
ci check adhoc-sdl|opaque-recipes
ci check pin-cache
ci check wasm-modules|nix-wasm [module options]
ci fix reference-links [--include-files SELECTOR...] [--exclude-files SELECTOR...]
ci fix spec-evidence-backlog

ci docs fences-audit [--root DIR] [--audit-scope site|all|excluded] [--json FILE]
ci docs stage-wasm

ci github mirror-checks [--repo R] [--sha SHA] [--skip-check NAME...] [--no-write]
ci github link-rot-issue [--repo R] [--report FILE] [--rotten] [--run-url URL]
ci stats [--merges [--badge-dir DIR]] [statistics options]

ci commits build-each [--base REF] [--packages NAME...]
ci cache seed-dub | stats | list | gc
ci cache pin-costs FILE [--history-remote URL]
ci cache gc-r2 [--keep-commits N] [--grace-days N] [--no-delete]
ci cache verify [--rerun [--determinism-sample N]] [--key KEY...] [--task TASK...]
ci cache remove --key KEY... | --task TASK... | --package NAME... | --toolchain ID
ci cache replace TASK...
ci cache explain TASK
ci host probe
ci slow-tests list
ci gc-report RECORDING [--baseline RECORDING] [--top N]

ci perf record TASK -- COMMAND...
ci perf push [--allow-dirty] [--signing-key KEY] [--history-remote URL]
ci perf import RUN --repo R
ci perf append --records DIR --run-id ID [--run-attempt N] --run-date DATE
               --landed-commit COMMIT [--signing-key KEY] [--history-remote URL]
ci perf show|compare|history|fetch [options]
```

Every command that executes a graph accepts:

| Option              | Default                            | Meaning                                                                                                                                                                                       |
| ------------------- | ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--jobs N`          | host-derived capacity              | Positive weighted capacity available to running tasks. It is not a count of OS threads.                                                                                                       |
| `--interlaced`      | off                                | Stream line-atomic, task-prefixed output as events arrive instead of replaying complete task blocks in presentation order.                                                                    |
| `--dry-run`         | off                                | Discover, select, plan, validate, and print the DAG without running task actions, making network requests, creating directories, or writing files.                                            |
| `--output MODE`     | `auto`                             | `ci test` only: status lines (CIC19), with the live view (CIC18) on a terminal outside CI (`auto`), always (`live`) or never (`lines`); `plain` writes the ordered transcript (TDO3) instead. |
| `--table STYLE`     | `clean`                            | `ci test` only: the status lines' task rows in aligned columns (`clean`), or framed, separated and headed as well (`boxed`) (CIC19).                                                          |
| `--no-timeline`     | timeline on                        | `ci test` only: leave the timeline out of the live view.                                                                                                                                      |
| `--legs LEGS`       | `auto`                             | `ci test` only: the ordinary tests' legs (CIC6). `auto` runs the placement's, or `-t N` alone; `parallel`, `serial` or `both` overrides.                                                      |
| `--fail-fast`       | off                                | On the first authoritative failure, stop admission and cancel the command scope.                                                                                                              |
| `--log-level LEVEL` | `info`                             | Standard Sparkles logger level.                                                                                                                                                               |
| `--cache-dir DIR`   | `$XDG_CACHE_HOME`, else `~/.cache` | The cache home: the store, the run directories and the perf history live beneath `DIR/sparkles`. An empty directory runs with nothing cached (CIC20).                                         |

**CIC20: The cache home is an option.** Every `ci` command **must** accept
`--cache-dir DIR`, before or after its name, and keep what it caches beneath
`DIR/sparkles`. Without it, `ci` **must** read `XDG_CACHE_HOME` as the
option's [environment fallback](../../core-cli/environment-fallback.md), and
then use `~/.cache`; every command's `--help` names the option and the
variable. Pointing it at an empty directory, `--cache-dir "$(mktemp -d)"`, is
how a run builds and tests everything from scratch without disturbing the
shared store.

**CIC1: Common options.** `--jobs 0` and negative values **must** be errors.
`--dry-run --interlaced` **must** be rejected, because a dry run has no task
output to interlace. Without `--jobs`, `SPARKLES_CI_JOBS` sets the capacity,
and an explicit `--jobs` wins over both. Both count weighted capacity units
(TDM7), not concurrent tasks, so a workflow that meant two concurrent builds
sets 4. Invalid combinations fail before any
task runs. Repository workflows pass `--interlaced`.

**CIC18: The live view.** On a terminal, `ci test` **must** keep its status
lines (CIC19) and draw a live view beneath them (task-DAG TDO8, TDO9), unless
`--output lines`, `--output plain` or a CI service says otherwise; `--output
live` draws it anywhere. While the view is up, every line the console writes
**must** print above it, never beneath it. The view **must** show, from the
top: the tasks still to finish as a tree, each under the task waiting on it,
the roots flush left, failures first, then the longest-running, fitted to its
rows (`fitTree`), each named as the status lines name it; the failures, newest first,
with the reason and the last lines of the newest; the slowest finished tasks
and the running ones as a timeline against a round axis that only grows (10s,
20s, 30s, 1m, 2m … `roundAxis`), so a running bar grows to the right, in the
rows left, when the terminal is at least 50 columns wide, unless
`--no-timeline`; and a tally of running,
executed, reused, pending and failed tasks with the elapsed time. Every
duration it shows — a running task's, a bar's, the elapsed time — **must** be
written and placed as the status lines write theirs: one decimal, ending at
the terminal's right edge. It is drawn
with `sparkles:ui` widgets in the terminal's own 16 colours and erased once
the transcript's summary is above it, so the scrollback is the same with the
view or without it. `--output live` with `--dry-run` **must** be rejected.

**CIC19: Status lines.** Unless `--output plain`, `ci test` **must** report
through `ci`'s console, in the one line form of `sparkles.base.status_line`
(base CON1): a verb right-aligned in twelve columns and coloured by what
happened, the subject, the details muted. Every log record `ci` writes takes
the same form, its level as the verb. Each task's line is a row of columns —
the verb, the package, the variant (a test's leg, another task's role), the
task's handle, a note and the time — each column as wide as its widest
entry in the planned graph, so every row lines up with the first. The time
is always the last column, right-aligned to the terminal's right edge as
the live view's durations are, and always has one decimal (`423.0ms`,
`8.9s`, `2.6m`). The handle, `kind:key[:leg]` with the key
cut to six digits, names the task to `ci cache explain`. The rows are laid
out by the table component (`sparkles.ui.components.table`): `--table clean`
aligns them alone, `--table boxed` frames them under a header, with a
failure's lines spanning the columns beneath its row. By default the console
**must** show:

- a heading naming the selected packages and the compiler;
- each compile, link and test that ran, with its time, and why it ran when a
  file changed; a test with its counts, failures first;
- each failure, with the lines its child wrote that explain it (a test leg's
  passing tests and summary left out), fenced and masked for the CI service
  as the plain transcript is (task-DAG TDO7);
- a summary: the packages, the time, how many results were reused and how
  many tasks ran; then each package's coverage, past six packages the total
  and the three lowest.

What explains a run but asks nothing of anyone — each result reused from the
store, the fallback variants a run did not need, archives and generated
modules, tasks blocked behind a failure, the host and the run directory —
**must** be reported at `LogLevel.trace`, shown by `--log-level trace`. A
failed run says so in its lines and writes no further error message.

**CIC2: One-node graphs.** A command that is a single check, such as
`ci check sidebar`, **must** plan a one-node graph. It runs through the
executor and reporter, so its outcome, exit status and output follow the same
rules as every other command.

**CIC3: Backends.** `--backend local`, the default, runs build actions on the
local executor and the shared store. `--backend nix` lowers them to Nix
derivations, which run on the configured remote builders as well
([build graph §10](../../build-primitives/build-graph/SPEC.md#_10-the-nix-backend)).
Non-build tasks run locally under both.

`ci test`, `ci pipeline` and the `ci examples` commands also accept
`--host-system SYSTEM` and `--host-ci-rev REV`, which re-run the command inside
a Linux VM from macOS, as the old flags did.

`ci github mirror-checks` reads the GitHub API even when it writes nothing. So its
rehearsal option is `--no-write`, not the common `--dry-run`, which forbids
network access. `ci cache gc-r2 --no-delete` lists the bucket for the same
reason.

**CIC16: Commands report through `Expected`.** Each command's handler
**must** return its outcome as an `Expected` value: success, a failure with
its message and exit status, or a skip. The program's entry point turns that
value into the exit status and the diagnostic. No handler calls `exit` or
returns a bare status integer. A command that runs a child process, such as
`ci perf record`, fails with the child's exit status.

### 1.2 `ci test` modes

With no mode option, `ci test` creates ordinary unittest tasks. Coverage is on
by default for this mode and can be disabled with `--no-coverage`.

`ci test --build-only` builds, for each selected package, its test binary, its
dependency-library variant when a selected package depends on it, and its
application variant when it is an executable. It runs nothing. Coverage is
invalid.

`ci test --special-modes MODE` creates the test runner's extracted special-mode
tasks:

- `MODE` is a wired enum whose CLI spellings are `off` (the default: ordinary
  tests), `betterc`, `wasm` and `all`;
  core-cli's `?`/`help` value-help forms list them.
- A selected package gets a task only for marker attributes present in its
  sources, and only if it integrates `sparkles:test-runner`.
- Every special invocation passes `--require-toolchain`.
- An empty repository-wide special-mode plan is an error, not a successful
  no-op.
- Coverage is invalid.

`--sanitize address` builds and tests every selected package under
AddressSanitizer, as a separate variant; it requires LDC on Linux. `--slow` runs
the `@slow` tests instead of the ordinary ones, optionally only those named by
`--tests`.

`--build-only` and `--special-modes` are mutually exclusive.

`--host CONFIG`, with `--build-only`, builds each selected package's default
configuration for that host platform, named by its nixpkgs `config`, instead of
its test root (build-graph BGH2); it may be repeated. Its tests do not run
(build-graph BGH8), so without `--build-only` it is an error.

**CIC12: Required hits.** `--require-cached KIND...` **must** fail every
build-graph action of a listed kind (`compile`, `archive`, `link`, `generate`)
that would execute instead of reusing a result. The action fails before it
starts, with the miss's explanation
([BGS8](../../build-primitives/build-graph/SPEC.md#_6-the-shared-store)) as its
diagnostic. A dry run reports which actions would fail. The actions the
determinism check (CIC13) re-executes are exempt, since executing them is its
purpose.

### 1.3 `ci pipeline`

`ci pipeline` plans, as one graph:

- every `ci test` mode CI runs;
- `ci examples standalone` and the markdown verification CI runs;
- every `ci check …`;
- `ci check commit-scope` for the commits of the range;
- `ci check pin-cache`, the build-settings check
  (`standardize-build-settings --check`), and the native comparison archives
  that the Event Horizon examples link;
- the configuration-specific test jobs CI runs, such as `terminal`'s
  `unittest-vulkan` and `base`'s `unittest-portable`, and the GPU shader lane,
  which is skipped where no GPU exists.

It runs on the build graph's shared store. Its `--from` and `--since` narrow
the package-derived tasks only. Tasks that require another host operating
system or another architecture are `Skipped(platform)` under the local
backend. Under the [Nix backend](../../build-primitives/build-graph/SPEC.md#_10-the-nix-backend)
they run on remote builders of that system.

**CIC13: The determinism check runs on every run.** Every CI run **must** run
the build graph's cold, unshared check
([BGS9](../../build-primitives/build-graph/SPEC.md#_6-the-shared-store)) over a
sample of the actions its builds ran or reused, once they have finished.
`ci pipeline` plans it as a task of its graph. A workflow that splits its builds
across jobs runs `ci cache verify --rerun --determinism-sample N` in a job
that shares their store, or in each job over that job's actions.

- **The sample:** order the run's cacheable actions (`compile`, `archive`,
  `link`, `generate`) by the SHA-256 digest of the `HEAD` commit id followed by
  the result key. Take the first four compiles, and the first four actions of
  the other kinds together. `--determinism-sample N` changes four to `N`; zero
  is an error.
- **Rotation:** the order changes with every commit, so successive runs check
  different actions, while a rerun of one commit checks the same ones.
- **Whatever the run did:** the sample is drawn whether the run reused or
  executed an action. Each sampled action's result is compared with a fresh
  execution that bypasses its own lookup and publishes only to the check's
  private store.

A difference fails the task as an authoritative failure, naming the action
and what differed, and removes the suspect result from the store. The
determinism-check task itself is never skipped by a stored result, a shared
verdict ([BGX4](../../build-primitives/build-graph/SPEC.md#_9-test-actions-and-result-reuse))
or any other memo of an earlier run.

**CIC14: Placements.** `ci pipeline` **must** partition its graph into named
**placements**, each a host system, a runner class, a capacity, the test legs it
runs and whether it collects coverage, declared in
one data file:

- **Running one:** `ci pipeline --placement NAME` runs that placement's tasks
  and the build actions they need. Every other task ends `Skipped(placement)`,
  a skip reason beside `platform`; none is dropped from the graph.
- **Listing them:** `ci placements list` prints the placements and their
  shards as JSON, and sets it as an output through the CI-provider module
  (TDO6). The repository's workflows are generated from that output. Listing
  is its own command, not an option of `ci pipeline`, because it plans nothing
  and runs on the API-only build of `ci`.
- **Shards:** a placement's tasks are packed into its shards longest first, by
  the `task.wall` that the
  [run records](../../build-primitives/observability/SPEC.md#_11-run-records)
  hold. A task
  with no recorded wall time takes a declared default weight.
- **One packing per run:** every shard of a run **must** pack from the same
  records. The workflow's planning job passes the `refs/perf/data` commit it
  read to each shard (`--history-tip`). A shard given none reads the newest
  commit of the ref whose committer time is not later than the measured
  commit's, so CI providers with no planning job agree too.

Before `ci pipeline` exists, the same placements serve `ci test` in its
ordinary, `--sanitize address` and `--special-modes all` forms, and the
toolchain's build plan: `ci test --placement NAME --shard K/N` runs a shard's
packages
([PLAN M3a](./PLAN.md#m3a-placements-before-the-build-graph),
[OD21](../../build-primitives/observability/decisions.md#od21-test-wall-times-reach-the-history-before-the-build-graph-accepted)).

**CIC15: No diffs on CI.** The repository's workflows **must not** pass
`--since`. On CI, reuse comes from keys, not from diffs. `--since` stays a
local convenience.

_Rationale:_ a diff depends on the base a run is compared with, which changes
across rebases, reruns and the merge queue. A key depends only on the inputs.
See [build graph D43](../../build-primitives/build-graph/decisions.md#d43-amendments-from-the-nix-generated-ci-pr-accepted).

## 2. Removed flags

The flags in the first column below are not part of the command line. There is
no legacy parser, alias, precedence table, or fallback dispatch.

| Removed flag                      | Replacement                           |
| --------------------------------- | ------------------------------------- |
| `--test`, `-t`                    | `ci test`                             |
| `--build`                         | `ci test --build-only`                |
| `--test-extracted`                | `ci test --special-modes all`         |
| `--test-sanitize`                 | `ci test --sanitize address`          |
| `--test-slow`                     | `ci test --slow`                      |
| `--packages` (with `--test-slow`) | `ci test --slow --from`               |
| `--packages` (with `--test`)      | `ci test --from`                      |
| `--files`                         | `--include-files`                     |
| `--list-slow-tests`               | `ci slow-tests list`                  |
| `--coverage`                      | `ci test --coverage`                  |
| `--example-files`, `-x`           | `ci examples standalone`              |
| default markdown mode             | `ci examples run`                     |
| `--verify`, `-V`                  | `ci examples verify`                  |
| `--update`, `-u`                  | `ci examples update`                  |
| `--dedup-reference-links`, `-d`   | `ci check reference-links`            |
| `--fix-reference-links`, `-f`     | `ci fix reference-links`              |
| `--check-vcs-urls`                | `ci check vcs-urls`                   |
| `--check-docs-sidebar`            | `ci check sidebar`                    |
| `--check-glossary`                | `ci check glossary`                   |
| `--check-credits`                 | `ci check credits`                    |
| `--check-spec-evidence`           | `ci check spec-evidence`              |
| `--update-spec-evidence-backlog`  | `ci fix spec-evidence-backlog`        |
| `--check-blob-paths`              | `ci check blob-paths`                 |
| `--audit-fences`                  | `ci docs fences-audit`                |
| `--check-wasm-modules`            | `ci check wasm-modules`               |
| `--stage-docs-wasm`               | `ci docs stage-wasm`                  |
| `--build-each-commit`             | `ci commits build-each`               |
| `--check-commit-scope`            | `ci check commit-scope`               |
| `--seed-dub-cache`                | `ci cache seed-dub`                   |
| `--check-pin-cache`               | `ci check pin-cache`                  |
| `--linux-host-probe`              | `ci host probe`                       |
| `--mirror-checks`                 | `ci github mirror-checks`             |
| `--mirror-checks --dry-run`       | `ci github mirror-checks --no-write`  |
| `--ci-stats`, `-C`                | `ci stats`                            |
| `--report-link-rot`               | `ci github link-rot-issue`            |
| `--watch` (with `--test`)         | `ci test --watch`                     |
| `--watch` (with `--build`)        | `ci test --build-only --watch`        |
| `--list-placements`               | `ci placements list`                  |
| `--check-adhoc-sdl`               | `ci check adhoc-sdl`                  |
| `--check-opaque-recipes`          | `ci check opaque-recipes`             |
| `--check-nix-wasm`                | `ci check nix-wasm`                   |
| `--gc-report`                     | `ci gc-report`                        |
| `--write-pin-costs`               | `ci cache pin-costs`                  |
| `--gc-r2`                         | `ci cache gc-r2`                      |
| `--gc-r2 --dry-run`               | `ci cache gc-r2 --no-delete`          |
| `--record-task`                   | `ci perf record`                      |
| `--perf-push`                     | `ci perf push`                        |
| `--perf-import-github-run`        | `ci perf import`                      |
| `--perf-append`                   | `ci perf append`                      |
| `--perf-records`, `--perf-run-*`  | `ci perf append --records`, `--run-*` |
| `--ci-stats --merges`             | `ci stats --merges`                   |
| `--skip-packages`                 | `ci test --placement --shard`         |

**CIC4: No removed flag survives.** The parser **must** reject every flag in the
table's first column as it rejects any unknown option, naming it and printing
the help; the table is the migration map, not a list the parser keeps. Option-only
flags keep their spelling on the command that owns them; for example, `--json`,
`--root` and `--audit-scope` move to `ci docs fences-audit`, and `--tests` to
`ci test --slow`.

**CIC17: Commands are verbs over subjects.** A pass/fail check is a command of
`ci check`, and a check that rewrites what it checks is a command of `ci fix`,
so `ci check --help` lists every check the repository's hooks and workflows
run. Commands that act on GitHub are commands of `ci github`. A command group
has no default action: a bare group reports the missing command with its help,
and exits non-zero.

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
| `--since`           | Uses Git's changed paths judged by the packages' input sets, not directory ownership or workspace manifest timestamps.                           |
| Recursive selection | Explicit `--dependencies` and `--dependents`; there is no implicit Yarn `-R`/`-A` mode.                                                          |
| Interlacing         | Line-atomic, prefixed event streaming on TTY and non-TTY alike. Raw byte chunks are never written concurrently.                                  |
| Failure             | A structured outcome, with blocked, cancelled, skipped, and degraded distinct from failed.                                                       |
| Execution           | Event Horizon scopes, subprocesses, clocks, and wakeups only. No `std.parallelism` pool or polling thread is permitted.                          |
| Cache               | A content-addressed build store shared by every worktree. Test results are reused only under the build graph's rules.                            |

## 4. Selection policy

Focused selection follows the [task DAG's selection
algebra](../../build-primitives/task-dag/SPEC.md#_2-package-discovery-and-focused-selection).
Only `ci test` and `ci pipeline` accept focused selectors; docs and example
commands keep their file selectors.

**CIC5: The repository's workspace inputs.** A change to any of these
**must** select every package under `--since`
([BGW12](../../build-primitives/build-graph/fileset-native-workspace.md#_6-change-affected-sets-invalidation-and-watching)):

- the files planning reads that no package's input set claims: `dub.sdl`
  and the lockfiles `dub.selections.json`, `nix/dub-lock.json` and
  `nix/ci-dub-lock.json`;
- the toolchain's and the shells' definition, which no plan reads and so is
  stated: `flake.nix`, `flake.lock`, `nix/d-toolchain.nix`, `nix/shells/**`,
  and `nix/packages/**`, which builds the native libraries and import paths
  every package's actions read;
- the planner's inputs: the closure of `sparkles:build-primitives`, which
  plans and runs the work, and the input set of `sparkles:ci` itself
  ([D54](../../build-primitives/build-graph/decisions.md#d54-the-planner-s-inputs-are-its-planning-library-s-closure-and-its-own-sources-accepted));
- what the compiler's working-directory lookup could find: the D and C
  sources directly beneath the root, and the trees `sparkles/`, `std/`,
  `core/`, `etc/` and `ldc/` there.

Only the second and the module names are a list, in
`apps/ci/src/repository_inputs.d`; the rest is derived, so it cannot name a
path that is not there. A package's own recipe, and every other path, selects
the packages whose requests claim it.

## 5. Command graphs

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
coverage build A = [-cov dependency libraries -> -cov compile -> -cov link]   (provisional)
coverage build A --onSuccess--> coverage test A                               (authoritative)
coverage build A --onFailure--> [plain compile -> plain link -> plain test]
coverage test A, plain test A --onCompletion--> classify A
all classifications --onCompletion--> merge coverage -> coverage-publish
all classifications --onCompletion--> run summary
```

**CIC6: Test edges.** A package's test task **must** depend only on its own test
binary. Its binary depends on its test-root compile and on the
dependency-library archives it links. No test waits for another package's test.
A dependency whose library fails to build blocks the link of each test binary
that needs it.

An ordinary test runs in the legs its placement names (CIC14): `-t N` on
every placement, and `-t 1`, on each worker's main thread, on the one
placement that also collects coverage. Both run with `--skip-slow`. The `-t N`
leg runs tests on worker threads under the stack watermark, so a test that
overflows a worker's stack cannot hide on the main thread, and a test that
needs the main thread is marked `@serial(threadAffinity: mainThread)` and runs
there in the same leg (TRS2). A sanitizer test runs one `-t N` leg on 4 MiB
workers. Without a placement, as on a developer's machine, the `-t N` leg runs
alone; `--legs parallel|serial|both` names the legs instead, with or without a
placement ([OD22](../../build-primitives/observability/decisions.md#od22-one-placement-runs-the-serial-leg-and-collects-coverage-accepted)).

**CIC11: Tests through the runner core.** ci **must** run a test binary through
the test runner's core library, never through the standalone runner or dub
([test-runner §9](../../test-runner/process-model.md#_9-two-clients-the-standalone-runner-and-ci)):

- **Nodes:** each leg is one test action and one node, the build graph's unit
  of reuse. Its claimed weight `N` is its `-t N`: it runs up to `N` worker
  sessions as supervised process groups (TDE1), places the binary's tests on
  them, and runs the `@serial` tests after the others. The `-t 1` leg has
  weight one and runs each test on its worker's main thread.
- **Output:** the leg's output is the lines the core's plain-text renderer
  makes of its events, and its observations include the passed, failed and
  skipped counts and the failed tests' names (TDM11). ci's reporters render
  them as any task's output; ci has no test reporter of its own.
- **Options:** ci passes the runner options through the core's parser, and a
  leg's outcome is the core's verdict, so `ci test` and a plain `dub test`
  agree on which tests ran and on what failed.
- **Coverage:** a coverage leg's workers write to the leg's task directory,
  ended one at a time with the coverage merge (CIC7).

**CIC7: Coverage attempts.** Without coverage, each package has one test node
and one classification node. With coverage:

- **The coverage build:** the `-cov` builds of a package's test binary form one
  chain: the `-cov` dependency libraries, the compile and the link. Every node
  in it has a provisional failure policy. A failure anywhere in it, and the
  provisional blocks it causes, neither triggers fail-fast nor fails the
  command (TDC4).
- **The fallback:** the plain compile, link and test sit behind an `onFailure`
  edge from the coverage link. They run only when the coverage build failed, and
  otherwise end `Blocked(conditionUnmet)`, which the summary counts as
  unneeded.
- **The test is authoritative:** once the coverage build succeeded, the
  coverage test is the package's only test. A failing coverage test is a
  failure, never retried without coverage.
- **Classification:** a passing coverage test classifies the package
  `Succeeded`. A failed coverage build with passing plain tests is
  `Degraded(noCoverage)`. A failing plain or coverage test is `Failed`.
- **Listings:** each coverage test writes its listings to its own task
  directory. LDC coverage variants use `--cov-increment=atomic`, because tests
  run on several threads. The test binary receives `--DRT-covopt` with
  `dstpath:` set to its task directory and `srcpath:` set to the worktree root,
  so the root-relative paths it records resolve.

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

**CIC8: Examples reuse planned variants.** Each example **must** be a
single-file package. Its planner picks the build type whose dependency-library
variants the same run already plans, so examples add no library compiles.
Without tests in the run, it picks the application variants. A build type that
removes assertions is never chosen. Its extracted source
**must** live at a content-addressed path (build graph BGG4), so an unchanged
example is not recompiled. Input order defines presentation order even when
execution is parallel.

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
- Unavailable process RSS/CPU sampling is a reported absence in the run
  record and a run degradation
  ([observability OBD11](../../build-primitives/observability/SPEC.md#_11-run-records)),
  never a task outcome.

A degraded report must contain a warning in human output and a structured
`degradations[]` field in JSON. It must never look identical to a complete
report.

### 5.8 Commit checks

```text
read message -> parse subject -> optional staged-path query -> policy check
```

`ci check commit-scope` uses the common models and summary but defaults to a compact
reporter suitable for a commit hook. stdin is an explicit input action, not
inherited by subprocess tasks.

**CIC21: Every commit in one run.** `ci commits build-each` **must** check out
each commit of the range in a scratch worktree of its own, plan the selected
packages there, and run every commit's plan as one graph against the shared
store, each action in its own commit's worktree with the key, result and run
paths a run of that commit alone would give it. An action **must** wait for
its namesake in the commit before it exactly when it is predicted to share
that one's key: the same action and outputs, no in-tree path its arguments
name changed between the two commits, and every producer it reads predicted
the same. It is then looked up after the earlier one publishes, and hits;
every other action **must** start as soon as its own commit allows. A wrong
prediction **must** cost only time. The packages the graph does not build
**must** build with dub in one more worktree, walked oldest first, as tasks of
the same run. A package **must** count as built at a commit when its
application's link, or its dub build, succeeds there.

### 5.9 Maintenance commands

**CIC10: Slow-test listing.** `ci slow-tests list` **must** print the `@slow` tests
as the JSON array the `slow-tests` CI matrix expands, and set it as the
`matrix` output through the CI-provider module (TDO6). A `@slow` test without a
name, or an empty list, is an error.

The other maintenance commands, `ci cache`, `ci host probe`, `ci github mirror-checks`
and `ci github link-rot-issue`, are one-node graphs (CIC2) over their existing
behaviour.

## 6. Build and coverage locations

Compiled output lives in the build graph's shared store, never in a package's
checked-in `build/` directory, the repository root or a private `DUB_HOME`.
Each task that writes anything else gets a task directory under
`<cache home>/sparkles/ci/runs/<run-id>/<task-key>/` (`--cache-dir`, CIC20), outside the worktree. The printable task id stays stable, and
`run-id` is a filesystem name only, never an ordering input. A task directory
holds:

- spilled output;
- the coverage listings of one coverage attempt, written there through the test
  binary's coverage destination option.

Coverage publication has two stages:

1. Successful coverage attempts are parsed from their task directories and
   merged by normalized source path and line. Hit counts are summed with
   saturation. A line is coverable if any listing compiled code for it, because
   a test root and a dependency library compile different code from one file.
   Only listings of one file that disagree on its source lines are an error,
   which degrades that file's report rather than guessing.
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
creates none. The `runs/` directory holds a `CACHEDIR.TAG` file (BGS7), and
`ci cache gc` removes the directories of runs that have ended.

Every run that executes a graph also writes a
[run record](../../../glossary.md#run-record) of its measurements, outside the
worktree and outside this directory. The `ci perf` commands read and share
them; both are specified by
[observability](../../build-primitives/observability/SPEC.md#_11-run-records).

## 7. Module layout

| Module                   | Responsibility                                                                                                                                   |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ci_main.d`              | Executable entry point only.                                                                                                                     |
| `app.d`                  | The composition root: commands wire planners to the executor and reporters.                                                                      |
| `cli.d`                  | Canonical subcommands, validation, and help.                                                                                                     |
| `reporter_tty.d`         | The interactive reporter over `sparkles:ui`'s `TaskReporter`.                                                                                    |
| `commands/test_.d`       | `test`, `slow-tests list` and `placements list`: build-only, ordinary, coverage-fallback, sanitizer, slow and special test planners.             |
| `commands/pipeline.d`    | The union graph of every CI job.                                                                                                                 |
| `commands/examples.d`    | `examples`: the Markdown run/verify/update graph and reducers, and the standalone example planner and directives.                                |
| `commands/check.d`       | `check` and `fix`: commit-scope, reference, URL, sidebar, glossary, credits, spec-evidence, blob, SDL, recipe, pin-cache and WebAssembly checks. |
| `commands/docs.d`        | `docs`: the fence audit and the staging of the docs' WebAssembly.                                                                                |
| `commands/github.d`      | `github`: the check mirror and the link-rot issue.                                                                                               |
| `commands/stats.d`       | `stats`: the statistics graph; pure stats remain in `ci_stats.d`.                                                                                |
| `commands/perf.d`        | `perf`: recording run records and publishing them to `refs/perf/data`.                                                                           |
| `commands/maintenance.d` | `commits` and `cache`: each commit's build, and seeding, costing and collecting the caches.                                                      |
| `commands/files.d`       | The file selection every command shares (`--include-files`, `--exclude-files`).                                                                  |
| `commands/output.d`      | The plain rendering every command shares: headers, result boxes and summaries.                                                                   |
| `commands/toolchain.d`   | The dub and compiler command lines and environments the planners share.                                                                          |
| Pure domain modules      | `coverage.d`, `dub_deps.d`, `example_manifest.d`, `blob_paths.d`, `docs_sidebar.d` and `fence_audit.d`, as reusable leaves.                      |

The generic layers live in `sparkles:build-primitives` (see the [task DAG's
module layout](../../build-primitives/task-dag/SPEC.md#_9-module-layout)).
Command modules may import them and their domain leaves. They must not import
concrete reporters.

## 8. Acceptance criteria

**CIC9: Completion.** The implementation is complete when all of these hold:

- Every command reaches execution through a validated task graph.
- There is no `std.parallelism` or task-status polling path in `apps/ci`.
- A failed or cancelled command leaves no live child or unreaped process.
- No compile runs through dub, and no library variant is compiled twice in one
  run.
- A second run in another worktree with no source change compiles nothing:
  it passes under `--require-cached compile archive link` (CIC12).
- `--jobs` enforces weighted capacity and exclusive keys.
- Focused package selection is visible under `--dry-run`.
- Default non-TTY transcripts and final summaries are stable under randomized
  completion order.
- TTY output uses `TaskReporter`, degrades without control sequences, and
  restores the terminal on interruption.
- Interlaced output is immediate, line-atomic and prefixed. On CI providers that
  support groups, block-mode task blocks, and the closing sections of an
  interlaced run, are grouped (TDO7).
- Coverage fallback cannot trigger fail-fast before plain-test classification.
- Degraded stats and coverage are visibly distinct from complete success.
- The parser exposes only the canonical command tree and rejects every removed
  flag.
- `ci pipeline` covers every job `.github/workflows/ci.yml` runs, or names it
  as skipped with its reason.
