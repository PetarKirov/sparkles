---
status: draft
owner: sparkles:test-runner
reviewed: 2026-11-02
---

# `sparkles:test-runner` — Process model and runner protocol

## Abstract

`sparkles:test-runner` splits a test run between two processes. The test
binary, built from the working tree, holds the tests and executes them, along
with the measurement code that times and counts them. A separate runner
executable, built from a pinned revision of the repository for `dub test`
users, parses the command line, schedules tests across worker processes, renders the reports,
and drives the compile-time and extracted modes. The two speak a versioned,
line-framed protocol over the binary's standard streams, which opens with a
handshake, so a runner never misreads a binary built for another protocol
version. `sparkles:ci` drives the same protocol through the same core library,
its task executor admitting the work and its reporters rendering it. A test binary
started without a runner still runs its tests on its
own, sequentially and with a minimal report.

## Introduction

Every package in this repository tests through one runner, and the runner
depends on much of the repository: its reports use the `sparkles:ui`
toolkit, which depends on `sparkles:base`, whose own tests need the runner.
Linking a runner library into each test binary closes a dependency cycle for
every package below the toolkit. Those packages broke the cycle by compiling
the runner's sources into their own test builds. That hides real edges from
the build graph, and it rebuilds the whole runner with every one of them.

Linking a runner prebuilt from a pinned revision does not remove the problem.
Its archive must carry its own copies of `base` and the toolkit beside the
copies under test. Isolating those copies needs object-file symbol rewriting,
which has no equivalent for Windows' object format. Even with that rewriting,
the test process would hold two copies of `base`'s global state. And
consumers call the runner's D API, such as `skipTest` and `benchIter`, so the
interface the two copies share is far wider than one `extern(C)` entry point.

The approach is the one cargo-nextest takes for Rust: keep the runner out of
the test process. What must run beside a test body stays in the binary: the
registration hook, the execution of one test at a time, and the benchmark and
workload measurement layer. That in-binary code depends on no other package
of this repository, so every package can depend on it without a cycle.
Everything else lives in a runner executable that talks to the binary over
pipes. The runner is a tool, like the compiler, so it can be built from a
pinned revision and replaced without relinking a single test binary.

This page specifies the process boundary: which package owns which code, how a
binary finds its runner, the wire protocol, the scheduling, crash and coverage
rules, the fallback, how a test runs without dub, the Windows
obligations, and the two clients of the protocol: the standalone runner and
`ci`, over the library they share. [SPEC.md](./SPEC.md) owns the measurement protocol, the metric
catalog and the command line's options; this page only says which process
carries each of them out. Timeouts for hung tests, sharding a run across
machines, and reusing results across runs are out of scope. The build graph
owns result reuse
([BGX3](../build-primitives/build-graph/SPEC.md#_9-test-actions-and-result-reuse)).

The choices behind this page, and the alternatives they rejected, are in
[decisions.md](./decisions.md). Delivery is milestone
[P1 in PLAN.md](./PLAN.md#p1--the-out-of-process-runner). Questions this page
leaves open are in [open-issues.md](./open-issues.md). How the build graph
keys test actions run through the core is
[BGT4](../build-primitives/build-graph/SPEC.md#_8-toolchain-identity).

## 1. The contract at a glance

1. **Test bodies run only in a test binary.** So do the timing and counting
   of benchmarks and workloads, because they bracket a test body.
2. **No test binary links the runner.** The runner is a separate executable.
3. **The in-binary code depends on no other repository package.** No package's
   tests close a cycle through it.
4. **Every session opens with a handshake.** A binary and a runner without a
   common protocol version stop with an error that names both ranges, and run
   no test.
5. **Plain `dub test` always works.** With no runner found, the binary runs
   its own tests.
6. **A runner told not to use dub never starts it.**
7. **One core, two clients.** The standalone runner and `ci` drive workers
   through the same library, which schedules nothing and prints nothing.

## 2. Packages

| Package                     | Kind                  | Holds                                                                                                                                                  | Depends on                                  |
| --------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------- |
| `sparkles:test-attributes`  | library               | The marker attributes, `sparkles.test_runner.attributes`                                                                                               | nothing                                     |
| `sparkles:test-harness`     | library               | The test model, discovery, the protocol's binary side, execution with the stack budget, the fallback, `skipTest`, the measurement layer                | `sparkles:test-attributes`                  |
| `sparkles:test-runner`      | `sourceLibrary`, shim | The registration hook, compiled into each test root                                                                                                    | `sparkles:test-harness`                     |
| `sparkles:test-runner-core` | library               | The runner core both clients share: options, the protocol client, worker sessions, the run plan and verdict, the compile-time and extracted modes (§9) | `sparkles:test-harness`, `base`             |
| `sparkles:test-runner-impl` | executable            | The standalone [runner](../../glossary.md#test-runner-executable), `sparkles-test-runner`: a `main`, the worker pool, the reports, `--bench-json`      | `sparkles:test-runner-core`, `ui`, `syntax` |

**TRP1: The in-binary packages depend on no other repository package.** The
recipes of `sparkles:test-attributes`, `sparkles:test-harness` and
`sparkles:test-runner` **must not** declare a dependency on any `sparkles:`
package outside these three and the two leaves `sparkles:metadata` and
`sparkles:metrics`, in any configuration, and their sources **must not**
import a module of one. A leaf is admitted only while it depends on no
repository package but the other leaf (`sparkles:metrics` on
`sparkles:metadata`, which depends on nothing) and tests itself without the
shim.

_Rationale:_ every package's tests depend on these three. Any edge from them
to another repository package is a cycle for that package. The leaves close
none: dub rejects a cycle through any configuration, and a leaf whose tests
used the shim would close one through its unittest configuration. They are
admitted for the observability spec (`docs/specs/build-primitives/observability/`,
OBV1–OBV2), which declares the bench catalog's metric types in
`sparkles:metrics`; until its milestone O4 moves them there, the harness keeps
them and depends on neither leaf.

**TRP2: Tests depend on the shim the ordinary way.** A package's unittest
configuration **must** reach the runner through `dependency
"sparkles:test-runner"` alone. No recipe **may** name
`sparkles:test-runner-impl` as a dependency, no recipe but `apps/ci`'s and
`sparkles:test-runner-impl`'s **may** name `sparkles:test-runner-core`, and none
**may** reach into the directory of
the attributes, the shim, the harness, the core or the runner through a path
setting.

**TRP3: Library builds see only the attributes.** A package whose modules
import `sparkles.test_runner.attributes` outside `unittest` code **must**
depend on `sparkles:test-attributes` in its library configuration, directly
or transitively. A library configuration of any other package **must not**
depend on the harness or the shim; the shim's own library configuration
depends on the harness, and the core's on the harness.

_Rationale:_ modules carry the marker attributes in every build, so library
builds import them; they need nothing else from the runner. Keeping the
measurement layer out of library builds keeps it out of every application and
WebAssembly module those libraries reach.

**TRP4: The harness tests itself.** The harness's unittest configuration
**must** register its tests through a module of the harness, and **must not**
depend on the shim.

**TRP5: In-binary set-up.** Before it runs any test, in worker mode and in
fallback alike, the harness **must** install the stack-budget fault handler
and, on macOS, its in-process trace handler.

## 3. Finding the runner

A test binary runs in one of three modes: as a
[launcher](../../glossary.md#test-launcher), which delegates the run to a
runner; as a [worker](../../glossary.md#test-worker), which serves a runner
over the protocol; and in [fallback](../../glossary.md#test-fallback), which
runs the tests itself.

**TRL1: Worker mode.** A binary started with
`--sparkles-test-protocol=<min>-<max>` as its first argument **must** serve
the protocol (§4) and **must not** look for a runner.

**TRL2: Runner resolution.** Otherwise the binary **must** resolve a runner
in this order:

1. `--no-runner`, which the binary consumes, selects fallback;
2. a `--runner=PATH` argument, which the binary consumes;
3. the environment variable `SPARKLES_TEST_RUNNER`;
4. no runner: fallback (§7).

A path from step 2 or 3 that does not name an executable file **must** stop
the run with an error naming the path and where it came from, and a non-zero
exit status. It **must not** fall back silently.

_Rationale:_ `dub test` passes only the arguments after `--`, so a dev shell
can point every test binary at its runner only through the environment. The
variable follows the convention for toolchain locations the dev shell exports;
it is not a switch.

**TRL3: Delegation.** A launcher **must** start the runner with
`--test-binary=<the absolute path of its own executable>`, then every
druntime option (`--DRT-…`) from its original argument vector, then its
remaining arguments, each group in its original order. It **must** wait for
the runner and then end its process with the runner's exit status, without
running a test, without running druntime's termination, and so without
writing coverage.

_Rationale:_ druntime removes `--DRT-` options from the arguments a program
sees, so the launcher reads them from the original vector. A launcher that
terminated normally would write coverage counts of its own over the ones its
workers merged (TRS5).

**TRL4: Direct invocation.** A runner started directly with `--test-binary`
**must** behave as it does when a launcher starts it.

_Rationale:_ a developer or a script may start the standalone runner on a
binary it already built, with no launcher in between.

**TRL5: Debugging.** `--no-runner` runs every test in the process that a
debugger started. A worker can also be started by hand with
`--sparkles-test-protocol` and driven by typing frames.

## 4. The protocol

### 4.1 Transport and framing

**TRP6: Channels.** A worker has three channels:

- **commands:** its standard input, written by the runner;
- **frames:** a duplicate of the standard output it started with, made
  before any test runs, close-on-exec on POSIX and not inheritable on
  Windows;
- **output:** its standard error, a pipe the runner reads. Before any test
  runs, the worker points file descriptor 1 at the same pipe as descriptor 2.

**TRP7: Frames.** A [frame](../../glossary.md#runner-frame) is the byte `0x1E` (ASCII record separator), a JSON
object in UTF-8 with no unescaped line feed, and a line feed. Its `"t"`
member names its type. Commands use the same framing. A worker **must**
write a line feed before its first frame.

**TRP8: Stray output.** Bytes on the frames channel outside a frame, such as a
module constructor's print before the protocol starts, are stray output. The
runner **must** find a frame at a `0x1E` anywhere in a line, show the stray
bytes as the worker's unattributed output, and **must not** treat them as an
error.

**TRP9: Malformed frames.** A frame that is not a JSON object with a known
`"t"` for the negotiated version is a protocol error. Within one protocol
version, unknown members of a known frame **must** be ignored. On a protocol
error the runner **must** stop that worker, report
`protocol error from <binary>: <detail>`, and fail the run. A worker that
reads a malformed command, or one it cannot run, **must** write an `error`
frame with a `message` and exit with status 4.

### 4.2 Handshake

**TRP10: Version selection.** The runner passes the protocol versions it
speaks as `--sparkles-test-protocol=<min>-<max>`. The worker **must** select
the highest version that both ranges contain.

**TRP11: Incompatible versions.** When the ranges share no version, the worker
**must** write a `hello` frame whose `version` is `null` and whose `supported`
member holds its own range, then exit with status 3 without running a test.
The runner **must** then stop with an error naming the binary, both ranges,
and the remedy: rebuild the binary against a matching harness, or move the
runner's pin.

**TRP12: Hello.** On a common version, the worker's first frame **must** be
`hello`, with these members:

| Member      | Value                                                                                    |
| ----------- | ---------------------------------------------------------------------------------------- |
| `version`   | The selected protocol version                                                            |
| `supported` | The worker's range, `[min, max]`                                                         |
| `harness`   | The harness's own version string                                                         |
| `compiler`  | `{vendor, version}`, from `__VENDOR__` and `__VERSION__`                                 |
| `build`     | `{asserts, coverage}`: whether assertions and coverage are compiled in                   |
| `roots`     | The source roots of the attributes, the harness and the shim, as the binary was compiled |
| `token`     | The token of this worker's output sentinels (TRP24)                                      |
| `tests`     | The number of `test` frames that follow                                                  |

**TRP13: The listing.** The `hello` frame **must** be followed by one `test`
frame per discovered test, in discovery order, and a `listed` frame. A `test`
frame carries `id`, the test's zero-based position in that order, and its
name, fully qualified symbol, file, line, column, and traits (the
[`TestTraits`](./SPEC.md#_3-attribute-and-in-body-surface) a discovered test
carries). A runner that receives anything else before `listed` has a protocol
error.

**TRP14: A stable listing.** Every worker of one binary **must** send an
identical listing. The runner **must** compare each later worker's listing
with the first and fail the run on a difference.

**TRP15: A binary without the protocol.** When the first frame is not
`hello`, or the worker exits before sending one, the runner **must** stop
with an error saying the binary does not speak the runner protocol, and show
the worker's output.

### 4.3 Commands

A worker runs at most one command at a time. A command that arrives while
another runs is a protocol error, and so is an id outside the listing.

**TRP16: Run.** `{"t":"run","id":N,"mainThread":B}` runs test `N`. The
worker **must** reply `started` with the id, then exactly one `result` frame,
whose members are:

| Member        | Value                                                                       |
| ------------- | --------------------------------------------------------------------------- |
| `id`          | The test's id                                                               |
| `status`      | `passed`, `failed` or `skipped`                                             |
| `durationNs`  | Wall time of the body, from the harness's monotonic clock                   |
| `failures`    | Every caught `Throwable` in its chain: `{type, message, file, line, trace}` |
| `skip`        | The `skipTest` reason, for a skipped test                                   |
| `stackBudget` | Whether the body crossed the worker-stack watermark                         |
| `usage`       | Optional: the test's measured usage, below                                  |

`usage` holds what the worker measured across the test, each value with its
quality tag: the worker's CPU time, its peak resident set (on Linux, reset
through `/proc/self/clear_refs` before the test and read as `VmHWM` after
it), and the bytes the test allocated from the GC with the collections and
pause time the GC spent during it. The observability spec
(`docs/specs/build-primitives/observability/`) owns the metrics and their
qualities, OBT1–OBT3. The member is an addition within a protocol version: a
runner that predates it ignores it (TRP9), and a client reading a worker that
sends none records those metrics as absent. A change to its meaning, as
opposed to a new member inside it, takes a new protocol version (TRP10).

The runner never sends `run` for a `@ctfe` test.

**TRP17: Thread placement.** A worker **must** run a test on a fresh thread
with the worker-stack budget, unless the test's traits ask for the main
thread or the command's `mainThread` is true; then it **must** run the test
on its main thread, under the same 384 KiB stack watermark. The runner sets
`mainThread` under `-t 1`.

**TRP18: Register.** `{"t":"register","ids":[…],"config":{…}}` runs the
listed `@benchmark` tests' bodies to register their cases, measuring
nothing. `config` is the bench configuration the runner derives from the
[command line](./SPEC.md#_7-cli-contract) for those tests. The worker
**must** reply, for each test, its `case` frames, then a `result` frame for
the registration itself; then one `provenance` frame per suite provenance
line not reported before; then `registered`. A `case` frame carries the
worker's case id, the test's id, the case's name, labels and declared client
metrics. The worker keeps the registered cases until it exits.

**TRP19: Measure.** `{"t":"measure","case":C,"config":{…}}` measures
registered case `C`. The worker **must** reply `caseStarted`, then one `row`
frame, then `measured`. The `row` frame carries `stats`, the measured
statistics a table row and a `--bench-json` row
([SPEC §8.3](./SPEC.md#_8-3-the-bench-json-document)) are rendered from, and
`thrown`, what a hard throw during the measurement carried. A `skipTest`
during the measurement yields a skipped row, not a `thrown`.

**TRP20: Workload.** `{"t":"workload","id":N}` runs `@workload` test `N`.
The worker **must** reply with any `note` frames, then one `window` frame per
measured window, carrying the window's totals and decomposition as `window`,
then a `result` frame.

**TRP21: Probe.** `{"t":"probe","options":{…},"list":B}` opens the
measurement sources the bench options select, closing any a previous probe
opened. The worker **must** reply with one `note` frame per header line, such
as an absent-but-requested capability; with `list` true, a `catalog` frame:
the metric descriptors and every backend's capability report, with every
source probed; and then a `probed` frame naming the tracepoints and raw
events the run counts. `--list-metrics` and the bench header render them.

**TRP22: Exit.** On `{"t":"exit","coverageMerge":B}`, or on end of file on its
standard input between commands, a worker **must** exit with status 0. With
`coverageMerge` true it **must** first set druntime's coverage merge mode, so
that its counts add to the listing files already written. On end of file
while a command runs, it **must** finish the command first.

The runner sorts, groups, filters by dataset, lists datasets and label keys,
renders tables, and writes `--bench-json` from these frames alone.

### 4.4 Output

**TRP23: Unbuffered output.** In worker mode the harness **must** make C
stdio's `stdout` and `stderr` unbuffered before any test runs.

**TRP24: Attribution.** After a test's body returns, and before its `result`
frame, the worker **must** write a sentinel line to its output channel:
`0x1E`, `sparkles-test-end`, the test's id, a token chosen per worker, and a
line feed. The runner **must** attribute the output it reads between a
`started` frame and that sentinel to the test, and output at any other time
to the worker. Output a thread writes after its test has ended goes to
whatever is running when the runner reads it.

**TRP25: Output survives a crash.** Because the runner owns the output pipe,
output a test wrote before its worker died **must** reach the report of that
test (TRP26).

### 4.5 Workers that die

**TRP26: A crash during a test.** When a worker exits, or is killed by a
signal or an exception, while a command runs, the runner **must** report that
test as failed, with the exit status, signal or exception code, and the
output read for it. A crash while registering or measuring fails that test,
or that case's row. The runner **must** then start a new worker for the work
that remains. Registration is deterministic: the new worker registers the
same tests in the same order, so a case keeps its id, which is its index in
that registration order.

**TRP27: A crash between commands.** When a worker exits between commands
without being asked to, the runner **must** fail the run with the exit status
and the worker's unattributed output.

**TRP28: Reading a dead worker.** The runner **must** stop reading a dead
worker's output at end of file, or once the worker has exited and no byte has
arrived for one second, whichever comes first.

_Rationale:_ a child process the test started may hold the pipe open after
the worker has died.

## 5. Scheduling and coverage

**TRS1: Workers.** For a runtime run, the runner **must** start at most `T`
workers, where `T` is the `-t` count, or the hardware thread count when `-t`
is absent or zero. It **must not** start more workers than there are tests to
run.

**TRS2: Phases.** The runner **must** run every non-serial test before any
`@serial` test. It **must** then run the serial tests one at a time, on one
worker, with no other test running.

**TRS3: Benchmarks.** A `--bench` run **must** register, measure and run
workloads on one worker, with no other test running in any worker.

**TRS4: Exits are ordered.** The runner **must** end its workers one at a
time, each after the previous one has exited.

**TRS5: Coverage.** When `hello` reports coverage compiled in, the runner
**must** pass every worker the druntime options of TRL3. It **must** send the
first worker it ends `coverageMerge` false, unless those options already ask
for merging, and every later one `coverageMerge` true.

_Rationale:_ druntime writes coverage when a process exits, so workers that
exit together race on the same listing files, and a worker that does not
merge replaces what the others wrote. A crashed worker writes nothing, and the
counts of the tests it ran are lost; the report says so.

## 6. Compile-time and extracted modes

The `@ctfe` probe, `--ctfe-trace`, `--better-c`, `--wasm` and `--wasm-bare`
compile new programs from the tested package's sources. They run in the
runner, from the listing's file, line and traits, the `roots` of `hello`, and
a compile context.

**TRX1: The compile context.** The runner **must** accept the compile
context as arguments. The arguments the
[CLI reference](../../libs/test-runner/reference/cli.md) lists for the
extracted modes keep their meaning, including the compiler's default chain and
`--require-toolchain`; these join them:

| Argument                   | Meaning                                                 |
| -------------------------- | ------------------------------------------------------- |
| `--string-import-path=DIR` | A string import path, repeatable                        |
| `--version=ID`             | A version identifier, repeatable                        |
| `--dflag=FLAG`             | A compiler flag, such as `-preview=dip1000`, repeatable |
| `--probe-dir=DIR`          | Where the runner writes probe sources and objects       |
| `--no-dub`                 | Never derive the compile context from dub               |

**TRX2: No dub.** With `--no-dub`, the runner **must not** start dub. Its
compile context is then exactly its arguments, the `roots` of `hello`, and
the compiler that the default chain selects.

**TRX3: Plain dub.** Without `--no-dub`, the runner **may** add import paths
and language flags from `dub describe`, as a convenience for a developer's
`dub test`.

**TRX4: Whose sources.** The runner **must not** add its own source root, or
any path of its pinned checkout, to a compile. It takes the harness's roots
from `hello`. Relative paths in the listing and in `roots` resolve against
the runner's working directory.

_Rationale:_ the build engine passes the variant's resolved settings
explicitly and `--no-dub` with them
([BGX1](../build-primitives/build-graph/SPEC.md#_9-test-actions-and-result-reuse));
a developer's `dub test` has no other source for them. The pinned runner's
own copy of the attributes is not the one the tested package was compiled
against.

## 7. Fallback

**TRF1: Fallback execution.** In fallback, the binary **must** run every
selected runtime test itself, one at a time, in discovery order, each placed
as TRP17 places it. It runs no `@benchmark` or `@workload` test and evaluates
no `@ctfe` test.

**TRF2: Fallback options.** Fallback **must** accept `-i`, `-e`, `-v`, `-l`,
`-t`, `--no-colors`, `--skip-slow`, `--only-slow` and `--help`, with the
runner's meanings, except that `-t` still runs one test at a time, on the main
thread under `-t 1` as TRP17 places it. The
compile-context arguments are accepted and unused. Any other option **must**
stop the run, before any test, with a one-line error saying the option needs
the runner and how to provide one (TRL2), and a non-zero exit status.

**TRF3: Fallback report.** Fallback **must** print one line per test: `✓`,
`✗` or `⊘` and the test's name, with a failure's message beneath it and, under
`-v`, its trace. It **must** end with a summary of the passed, failed and
skipped counts, and the number of compile-time tests left unevaluated.

**TRF4: Fallback exit status.** Fallback **must** exit with status 0 if and
only if no selected test failed.

## 8. Windows

The protocol uses only facilities every supported platform has: three
standard streams, anonymous pipes, and spawning a process and waiting for it.

**TRW1: No handle tricks.** On Windows the runner **must** connect a worker
through its standard input, output and error alone, created by the
process-spawning call. It **must not** need named pipes or inherited handles
beyond those three.

**TRW2: Output on Windows.** A Windows worker **must** point C runtime file
descriptor 1 at the same handle as descriptor 2, and **must** also point the
Win32 standard output handle at it, so that writes through `WriteFile` on
that handle reach the output channel too.

**TRW3: Delegation on Windows.** Delegation **must** spawn the runner and
wait for it, on Windows and elsewhere alike. No platform replaces the
launcher's process image.

**TRW4: No object-file tricks.** No part of the runner, the harness, or the
pin's build **may** depend on rewriting symbols in object files or archives.

## 9. Two clients: the standalone runner and `ci`

The protocol has two clients. The **standalone** runner, `sparkles-test-runner`,
is what a `dub test` user gets, inside this repository or outside it: it
starts its own worker processes, schedules them, and renders its own reports.
**`ci`** runs the same test binaries as actions of its task graph: the
task-DAG executor admits them, ci's reporters render them, and the build
graph's result reuse covers them
([ci task DAG](../ci/task-dag/SPEC.md#_5-2-ordinary-package-tests-and-coverage)).
Both are built on one library, the
[runner core](../../glossary.md#test-runner-core), so a binary means the same
thing to either. §2 owns the package table; the core is
`sparkles:test-runner-core`.

In this page "the runner" names whichever client drives a worker. The
requirements of §3–§7 bind both clients; where one differs, the requirement
below says so.

**TRM1: The core performs no I/O.** The core **must** be a protocol state
machine: it consumes the bytes a client read from a worker's frames and
output channels, and that worker's end, and produces the commands to write
to the worker and events for the client. It **must not** start processes,
create threads, read or write a file descriptor, or print, and **must not**
depend on `sparkles:ui`, on `sparkles:event-horizon`, or on any package of
`sparkles:ci`.

_Rationale:_ the clients' process models differ. The standalone runner may
use threads and pipes; ci must run children as supervised process groups that
fail-fast can end ([TDE1, TDE2](../build-primitives/task-dag/SPEC.md#_4-event-horizon-only-execution)). A core
that did its own I/O would fit one of them.

**TRM2: The events.** The core **must** produce, in the order the worker's
frames and output imply:

| Event            | Carries                                                                          |
| ---------------- | -------------------------------------------------------------------------------- |
| `WorkerReady`    | The session, its `hello` and listing                                             |
| `TestStarted`    | The session and the test                                                         |
| `TestOutput`     | The session, the test or none, and one chunk of output, in the order it was read |
| `TestFinished`   | The session and the test's `TestResult`                                          |
| `CaseRegistered` | A registered bench case                                                          |
| `Provenance`     | A suite provenance line                                                          |
| `BenchRow`       | A measured row                                                                   |
| `WorkloadWindow` | A measured window                                                                |
| `Note`           | A header line, such as an absent-but-requested capability                        |
| `Catalog`        | The metric catalog and capability reports of a probe (TRP21)                     |
| `WorkerEnded`    | The session and how its process ended                                            |

**TRM3: The core does not schedule.** The core **must not** decide how many
sessions run at once or which test a session runs next. It supplies the run
plan its clients follow: the selected tests, their phases (TRS2), and the
order and coverage-merge flags of the workers' exits (TRS4, TRS5) as data.
The client places tests on sessions.

**TRM4: One meaning for the options.** Both clients **must** parse the runner's
options with the core's parser, and **must** compute a run's exit status with
the core's verdict: `0` if and only if everything selected passed or was
skipped. The selection and runtime options, `-i`, `-e`, `-t`, `--skip-slow`
and `--only-slow`, select the same tests in both. `-v`, `-l`, `--no-colors`,
live progress and the failure recap are each client's rendering of the same
events. `--bench`, `--list-metrics` and their options are the standalone
runner's: ci has no bench mode.

**TRM5: A test action in `ci`.** In ci a test action is one leg of one test
binary ([CIC11](../ci/task-dag/SPEC.md#_5-2-ordinary-package-tests-and-coverage)),
and it is the build graph's unit of reuse
([BGX3](../build-primitives/build-graph/SPEC.md#_9-test-actions-and-result-reuse)).
Its node claims `N` weighted tokens and runs up to `N` worker sessions, the
thread-count rule of
[TDM10](../build-primitives/task-dag/SPEC.md#_3-3-resource-claims):
like a linker's threads, the sessions are work inside one admitted node, and
the executor's admission decides which nodes run across packages. The node
places its tests on its sessions as the standalone runner's pool does, and
runs the `@serial` tests after the others.

**TRM6: What a test action reports.** A test action's output **must** be the
lines the core's plain-text renderer makes of its events, one test's lines
together, in the order its tests finished, so ci's reporters show it like any
other task's output (TDM12–TDM14). Its observations **must** include the
counts of passed, failed and skipped tests and the failed tests' names
(TDM11). A reused result replays the same lines.

**TRM7: Coverage in `ci`.** A coverage leg's workers **must** write their
listings to the leg's own task directory, and **must** follow TRS4 and TRS5
there; a worker that replaces a crashed one (TRP26) merges. ci's merge then
combines the legs' directories (CIC7).

**TRM8: Which client the pin is.** The pinned artifact **must** be the
standalone runner. ci links the core compiled into ci itself, and a test
action's key **must** cover that core's identity: the identity of the ci
build that runs it
([BGT4](../build-primitives/build-graph/SPEC.md#_8-toolchain-identity)).

_Rationale:_ the source includes existed because the runner was linked into
test binaries. Out of process, the core is a tool's library like ci's others.
The handshake rejects a protocol mismatch between that tool and a binary; it
cannot see a change to the core's selection or verdict, which is why the key
covers the core.

## 10. The pinned runner

The standalone runner is built from a pinned revision of this repository and
exported to the dev shell (TRM8). The pin is one file,
`nix/test-runner-pin.json`, holding the revision and its source hash, so that
a host without Nix can read it.

**TRN1: One pin.** The Nix derivation that builds the runner, and every leg
that builds it without Nix, **must** take the revision from
`nix/test-runner-pin.json`. When the file names no revision, they build the
runner from the repository's own source.

**TRN2: The dev shell.** The dev shell **must** export
`SPARKLES_TEST_RUNNER` as the absolute path of the pinned runner, and so
**must** the `ci` wrapper as long as `ci --test` runs `dub test`, before ci
runs tests through the core (CIC11).

**TRN3: Protocol overlap across a pin move.** A change to the protocol
**must** keep the harness speaking every version the pinned runner speaks
until the pin moves past it. The handshake (TRP11) makes a violation visible
on the first test run.

_Rationale:_ the pin moves only to a revision of `main`, and a revision of
`main` can only carry a protocol change after the change has landed. So the
working tree's harness and the pinned runner overlap for at least one pin
move.

## 11. Verification

Each scenario names the requirements it falsifies and its oracle.

| Scenario                                                                                                                                                                                            | Falsifies          | Oracle                                                                               |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ | ------------------------------------------------------------------------------------ |
| Scan every recipe and the in-binary packages' imports for a `sparkles:` edge                                                                                                                        | TRP1–TRP3          | The recipes, read by a script independent of dub                                     |
| `dub test :test-harness` runs the harness's own tests, and the count equals the number of its `unittest` blocks                                                                                     | TRP4               | A count of `unittest` blocks in its sources                                          |
| Start a binary with `--sparkles-test-protocol=99-99`: one `hello` with `version: null`, exit status 3                                                                                               | TRP10, TRP11       | The frame stream, read byte by byte                                                  |
| A runner whose range excludes the binary's: the error names both ranges; no test runs                                                                                                               | TRP11              | The runner's output and exit status                                                  |
| A module constructor prints `x` with no line feed before `hello`: shown as unattributed output; the run passes                                                                                      | TRP7, TRP8         | The runner's output and exit status                                                  |
| A test writes to `stdout`, `stderr`, `printf` and `write(2, …)`: all four appear in that test's output, in order                                                                                    | TRP6, TRP23, TRP24 | The test's reported output against the order it wrote                                |
| A test prints a line, then calls `abort()`: it fails with the signal and the line; the tests after it run and pass                                                                                  | TRP25, TRP26       | The report against the listing                                                       |
| A test starts a child that keeps descriptor 2 open, then crashes: the run ends within a few seconds                                                                                                 | TRP28              | Wall time and exit status                                                            |
| Every `-t` from 1 to 8 runs the same tests with the same results                                                                                                                                    | TRS1, TRS2, TRP17  | The per-test statuses, compared across `-t`                                          |
| A `@serial` test asserts no other test is running                                                                                                                                                   | TRS2               | A process-shared count of running tests, in a fixture directory                      |
| `--bench --group-by=list`, `--list-datasets` and `--datasets=X` give the output the in-process runner gave for the same tests                                                                       | TRP18, TRS3        | Outputs recorded from the in-process runner on the same sources                      |
| A coverage build under `-t 4`: the set of covered lines equals a `-t 1` run's, and the launcher's own start-up is not counted                                                                       | TRL3, TRS4, TRS5   | The covered-line sets of the `.lst` files                                            |
| `--no-dub` with a `@ctfe` test and `PATH` holding no `dub`: the probe compiles from the arguments and `roots` only                                                                                  | TRX2, TRX4         | A wrapper on `PATH` that records every program started                               |
| `--no-runner -i X`: only matching tests run; `--no-runner --bench` stops before any test                                                                                                            | TRF1, TRF2         | The fallback's lines and exit status                                                 |
| `SPARKLES_TEST_RUNNER=/nonexistent`: the run stops naming the variable                                                                                                                              | TRL2               | The exit status and message                                                          |
| The Windows CI leg runs the output, crash and fallback scenarios                                                                                                                                    | TRW1–TRW3          | The same assertions, on `windows-latest`                                             |
| Change the runner's sources in the working tree: only `test-runner-impl`'s test root rebuilds                                                                                                       | TRP2, BGT4         | [Oracle 15](../build-primitives/build-graph/testing.md#oracle-15-pinned-test-runner) |
| The runner core's sources import none of `std.process`, `std.stdio`, `core.thread`, `core.sys.*.unistd` or `core.stdc.stdio`, nor a `sparkles.ui`, `sparkles.event_horizon` or `sparkles.ci` module | TRM1               | A scan of the core's sources                                                         |
| The core fed a recorded worker transcript produces the same events whether the bytes arrive whole or one at a time                                                                                  | TRM1, TRM2         | The event lists, compared                                                            |
| A binary run standalone and under `ci test` reports the same per-test statuses and exit status for the same `-i`, `-e`, `--skip-slow`                                                               | TRM4               | The two runs' results, compared                                                      |
| `ci test` with capacity `2N` runs the `-t N` legs of two packages at once; a reused leg replays its lines                                                                                           | TRM5, TRM6         | The executor's event log                                                             |

## Requirement status

Evidence below was observed on Linux x86_64 with LDC and on native Windows, at the commits that
delivered P1. A requirement is `partial` where its scenario of §10 has been
run by hand but is not yet an automated test, or where a platform is
unverified.

| ID         | Status     | Evidence                                                                                                                                          |
| ---------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| TRP1–TRP3  | partial    | A scan of every `dub.sdl` and of the harness's imports finds no edge; not yet a `ci` check                                                        |
| TRP4       | verified   | `dub test :test-harness` runs its 154 tests through `sparkles.test_runner.self_host`                                                              |
| TRP5       | partial    | `sparkles.test_runner.entry.installHarnessHandlers`; the macOS handler unverified                                                                 |
| TRP6–TRP28 | partial    | `sparkles.test_runner.session` transcript tests; `sparkles.test_runner.scenarios_test` (mismatch, output, crash); TRP16's `usage` is not sent yet |
| TRL1–TRL5  | partial    | `sparkles.test_runner.scenarios_test` (a bad `SPARKLES_TEST_RUNNER`, the launcher)                                                                |
| TRS1–TRS4  | partial    | `sparkles.test_runner.pool.startTestWorkers`; `-t 1` and `-t N` legs of `ci --test`                                                               |
| TRS5       | partial    | `sparkles.test_runner.pool.retire`; `ci --test` coverage listings; the covered-line comparison not run                                            |
| TRX1–TRX4  | partial    | `sparkles.test_runner.driver.DriverOptions`; the `PATH`-without-dub scenario not run                                                              |
| TRF1–TRF4  | partial    | `sparkles.test_runner.scenarios_test` (`--no-runner` filters, `--bench` refused)                                                                  |
| TRW1–TRW4  | unverified | The Windows code paths type-check for `x86_64-windows-msvc`; the Windows leg has not run them                                                     |
| TRM1–TRM3  | partial    | `sparkles.test_runner.session.WorkerSession`; its transcript tests; the import scan not automated                                                 |
| TRM4       | partial    | `sparkles.test_runner.plan.selectTests`, `sparkles.test_runner.options.parseRunnerOptions`; no ci client yet                                      |
| TRM5–TRM8  | unverified | The ci client is the task DAG's M7                                                                                                                |
| TRN1–TRN3  | partial    | `nix/packages/test-runner.nix` builds the bootstrap; no revision is pinned yet                                                                    |
