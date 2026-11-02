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
executable, built from a pinned revision of the repository, parses the
command line, schedules tests across worker processes, renders the reports,
and drives the compile-time and extracted modes. The two speak a versioned,
line-framed protocol over the binary's standard streams, which opens with a
handshake, so a runner never misreads a binary built for another protocol
version. A test binary started without a runner still runs its tests on its
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
workload measurement layer. That in-binary code depends on nothing but
druntime and Phobos, so every package can depend on it without a cycle.
Everything else lives in a runner executable that talks to the binary over
pipes. The runner is a tool, like the compiler, so it can be built from a
pinned revision and replaced without relinking a single test binary.

This page specifies the process boundary: which package owns which code, how a
binary finds its runner, the wire protocol, the scheduling, crash and coverage
rules, the fallback, how a test runs without dub, and the Windows
obligations. [SPEC.md](./SPEC.md) owns the measurement protocol, the metric
catalog and the command line's options; this page only says which process
carries each of them out. Timeouts for hung tests, sharding a run across
machines, and reusing results across runs are out of scope. The build graph
owns result reuse
([BGX3](../build-primitives/build-graph/SPEC.md#_9-test-actions-and-result-reuse)).

The choices behind this page, and the alternatives they rejected, are in
[decisions.md](./decisions.md). Delivery is milestone
[P1 in PLAN.md](./PLAN.md#p1--the-out-of-process-runner). Questions this page
leaves open are in [open-issues.md](./open-issues.md). The build graph's
treatment of the pinned runner as a toolchain component is
[BGT4](../build-primitives/build-graph/SPEC.md#_8-toolchain-identity).

## 1. The contract at a glance

1. **Test bodies run only in a test binary.** So do the timing and counting
   of benchmarks and workloads, because they bracket a test body.
2. **No test binary links the runner.** The runner is a separate executable.
3. **The in-binary code depends on druntime and Phobos only.** No package's
   tests close a cycle through it.
4. **Every session opens with a handshake.** A binary and a runner without a
   common protocol version stop with an error that names both ranges, and run
   no test.
5. **Plain `dub test` always works.** With no runner found, the binary runs
   its own tests.
6. **A runner told not to use dub never starts it.**

## 2. Packages

| Package                     | Kind                  | Holds                                                                                                                                                               | Depends on                                      |
| --------------------------- | --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| `sparkles:test-attributes`  | library               | The marker attributes, `sparkles.test_runner.attributes`                                                                                                            | nothing                                         |
| `sparkles:test-harness`     | library               | The test model, discovery, the protocol's binary side, execution with the stack budget, the fallback, `skipTest`, the measurement layer                             | `sparkles:test-attributes`                      |
| `sparkles:test-runner`      | `sourceLibrary`, shim | The registration hook, compiled into each test root                                                                                                                 | `sparkles:test-harness`                         |
| `sparkles:test-runner-impl` | executable            | The [runner](../../glossary.md#test-runner-executable), `sparkles-test-runner`: command line, scheduling, reports, compile-time and extracted modes, `--bench-json` | `sparkles:test-harness`, `base`, `ui`, `syntax` |

**TRP1: The in-binary packages depend on no other repository package.** The
recipes of `sparkles:test-attributes`, `sparkles:test-harness` and
`sparkles:test-runner` **must not** declare a dependency on any `sparkles:`
package outside these three, in any configuration, and their sources **must
not** import a module of one.

_Rationale:_ every package's tests depend on these three. Any edge from them
to another repository package is a cycle for that package.

**TRP2: Tests depend on the shim the ordinary way.** A package's unittest
configuration **must** reach the runner through `dependency
"sparkles:test-runner"` alone. No recipe **may** name
`sparkles:test-runner-impl` as a dependency, or reach into the directory of
the attributes, the shim, the harness or the runner through a path setting.

**TRP3: Library builds see only the attributes.** A package whose modules
import `sparkles.test_runner.attributes` outside `unittest` code **must**
depend on `sparkles:test-attributes` in its library configuration, directly
or transitively. A library configuration **must not** depend on the harness
or the shim.

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

_Rationale:_ the build engine starts the runner directly, as a toolchain
component, and never starts a launcher.

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

**TRP7: Frames.** A frame is the byte `0x1E` (ASCII record separator), a JSON
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
`protocol error from <binary>: <detail>`, and fail the run.

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

The runner never sends `run` for a `@ctfe` test.

**TRP17: Thread placement.** A worker **must** run a test on a fresh thread
with the worker-stack budget, unless the test's traits ask for the main
thread or the command's `mainThread` is true; then it **must** run the test
on its main thread. The runner sets `mainThread` under `-t 1`.

**TRP18: Register.** `{"t":"register","ids":[…],"config":{…}}` runs the
listed `@benchmark` tests' bodies to register their cases, measuring
nothing. `config` carries the bench options of the
[command line](./SPEC.md#_7-cli-contract). The worker **must** reply, for
each test, its `case` frames, then a `result` frame for the registration
itself, then `registered`. A `case` frame carries the worker's case id, the
test's id, the case's name, labels and declared client metrics. The worker
keeps the registered cases until it exits, and also writes a `provenance`
frame for each suite provenance line registered.

**TRP19: Measure.** `{"t":"measure","case":C}` measures registered case `C`.
The worker **must** reply `caseStarted`, then one `row` frame, with the
members of a `--bench-json` row
([SPEC §8.3](./SPEC.md#_8-3-the-bench-json-document)) and the rendered metric
cells, then `measured`.

**TRP20: Workload.** `{"t":"workload","id":N,"config":{…}}` runs `@workload`
test `N`. The worker **must** reply with one `window` frame per measured
window, with the members of a `--bench-json` window, then a `result` frame.

**TRP21: Probe.** `{"t":"probe","config":{…}}` opens the measurement sources
the bench options select. The worker **must** reply with one `catalog` frame:
the available metric descriptors, every backend's capability report, and one
`note` per header line, such as an absent-but-requested capability.
`--list-metrics` and the bench header render it.

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
that remains, registering again before it measures.

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
runner's meanings, except that `-t` still runs one test at a time. The
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

## 9. The pinned runner

The runner executable is built from a pinned revision of this repository and
exposed as a toolchain component. The pin is one file,
`nix/test-runner-pin.json`, holding the revision and its source hash, so that
a host without Nix can read it.

**TRN1: One pin.** The Nix derivation that builds the runner, and every leg
that builds it without Nix, **must** take the revision from
`nix/test-runner-pin.json`. When the file names no revision, they build the
runner from the repository's own source.

**TRN2: The dev shell.** The dev shell and the `ci` wrapper **must** export
`SPARKLES_TEST_RUNNER` as the absolute path of the pinned runner.

**TRN3: Protocol overlap across a pin move.** A change to the protocol
**must** keep the harness speaking every version the pinned runner speaks
until the pin moves past it. The handshake (TRP11) makes a violation visible
on the first test run.

_Rationale:_ the pin moves only to a revision of `main`, and a revision of
`main` can only carry a protocol change after the change has landed. So the
working tree's harness and the pinned runner overlap for at least one pin
move.

## 10. Verification

Each scenario names the requirements it falsifies and its oracle.

| Scenario                                                                                                                      | Falsifies          | Oracle                                                                               |
| ----------------------------------------------------------------------------------------------------------------------------- | ------------------ | ------------------------------------------------------------------------------------ |
| Scan every recipe and the in-binary packages' imports for a `sparkles:` edge                                                  | TRP1–TRP3          | The recipes, read by a script independent of dub                                     |
| `dub test :test-harness` runs the harness's own tests, and the count equals the number of its `unittest` blocks               | TRP4               | A count of `unittest` blocks in its sources                                          |
| Start a binary with `--sparkles-test-protocol=99-99`: one `hello` with `version: null`, exit status 3                         | TRP10, TRP11       | The frame stream, read byte by byte                                                  |
| A runner whose range excludes the binary's: the error names both ranges; no test runs                                         | TRP11              | The runner's output and exit status                                                  |
| A module constructor prints `x` with no line feed before `hello`: shown as unattributed output; the run passes                | TRP7, TRP8         | The runner's output and exit status                                                  |
| A test writes to `stdout`, `stderr`, `printf` and `write(2, …)`: all four appear in that test's output, in order              | TRP6, TRP23, TRP24 | The test's reported output against the order it wrote                                |
| A test prints a line, then calls `abort()`: it fails with the signal and the line; the tests after it run and pass            | TRP25, TRP26       | The report against the listing                                                       |
| A test starts a child that keeps descriptor 2 open, then crashes: the run ends within a few seconds                           | TRP28              | Wall time and exit status                                                            |
| Every `-t` from 1 to 8 runs the same tests with the same results                                                              | TRS1, TRS2, TRP17  | The per-test statuses, compared across `-t`                                          |
| A `@serial` test asserts no other test is running                                                                             | TRS2               | A process-shared count of running tests, in a fixture directory                      |
| `--bench --group-by=list`, `--list-datasets` and `--datasets=X` give the output the in-process runner gave for the same tests | TRP18, TRS3        | Outputs recorded from the in-process runner on the same sources                      |
| A coverage build under `-t 4`: the set of covered lines equals a `-t 1` run's, and the launcher's own start-up is not counted | TRL3, TRS4, TRS5   | The covered-line sets of the `.lst` files                                            |
| `--no-dub` with a `@ctfe` test and `PATH` holding no `dub`: the probe compiles from the arguments and `roots` only            | TRX2, TRX4         | A wrapper on `PATH` that records every program started                               |
| `--no-runner -i X`: only matching tests run; `--no-runner --bench` stops before any test                                      | TRF1, TRF2         | The fallback's lines and exit status                                                 |
| `SPARKLES_TEST_RUNNER=/nonexistent`: the run stops naming the variable                                                        | TRL2               | The exit status and message                                                          |
| The Windows CI leg runs the output, crash and fallback scenarios                                                              | TRW1–TRW3          | The same assertions, on `windows-latest`                                             |
| Change the runner's sources in the working tree: only `test-runner-impl`'s test root rebuilds                                 | TRP2, BGT4         | [Oracle 15](../build-primitives/build-graph/testing.md#oracle-15-pinned-test-runner) |

## Requirement status

| ID         | Status     | Evidence |
| ---------- | ---------- | -------- |
| TRP1–TRP28 | unverified | —        |
| TRL1–TRL5  | unverified | —        |
| TRS1–TRS5  | unverified | —        |
| TRX1–TRX4  | unverified | —        |
| TRF1–TRF4  | unverified | —        |
| TRW1–TRW4  | unverified | —        |
| TRN1–TRN3  | unverified | —        |
