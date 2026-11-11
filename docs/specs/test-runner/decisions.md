---
status: draft
owner: sparkles:test-runner
reviewed: 2026-11-02
---

# `sparkles:test-runner` — Decisions

Each record states its question, the alternatives, the choice and when to
revisit it. **Accepted** records were accepted by the owner, TRD1 and TRD7–TRD9
on 2026-11-02; **proposed**
ones await the owner's decision. The contract they shape is
[process-model.md](./process-model.md).

## TRD1: The runner runs out of process (accepted)

**Question.** Every package's tests depend on the runner, and the runner
depends on `sparkles:ui`, `base` and much of the rest of the repository. How
does a package below the toolkit test through it without a dependency cycle?

**Alternatives.**

- **Source includes.** Each package in the runner's closure compiles the
  runner's sources into its own test build. This hides edges from the build
  graph
  ([BGR8](../build-primitives/build-graph/SPEC.md#_2-recipe-resolution)) and
  recompiles the runner for every such package.
- **A prebuilt, pinned library.** Build the runner, with its whole closure,
  from a pinned revision and link it into every test binary. A prototype on
  Linux passed `base`'s 982 tests (an observation not recorded in the tree), but only after a partial link and a
  rewrite that made every symbol but the runner's own local, and dropped COMDAT
  groups. Windows' object format has no equivalent. The test process holds two
  copies of `base`'s state. Consumers call the runner's D API, so the
  interface between the copies is wider than its `extern(C)` entry point, and
  a change to `base` breaks or silently skews it until the pin moves.
- **An out-of-process runner.** Keep what must run beside a test body in the
  binary, and move the rest into an executable that drives the binary over a
  pipe, as cargo-nextest does.

**Choice.** The out-of-process runner, decided by the owner on 2026-11-02
(question Q29 of the build-engine design interview).

**Revisit when** a test needs the runner's reporting code inside its own
process.

## TRD2: Measurement stays in the binary (proposed)

**Question.** `--bench` and workload windows time and count a test body.
Which process measures?

**Alternatives.**

- The runner measures the binary from outside: performance counters opened
  on the worker's thread, and wall time from the frames.
- The binary measures and reports rows over the protocol.

**Choice.** The binary measures. `benchIter`, `benchCase` and
`workloadWindow` mark regions inside a body, and a timing loop that crossed a
pipe on every sample would time the pipe. The measurement layer moves into
the harness, which depends on no other repository package (TRP1), and the runner
receives finished rows.

**Revisit when** a source can only be read from outside the measured process.

## TRD3: Worker processes, one test at a time (proposed)

**Question.** How does the runner run tests in parallel?

**Alternatives.**

- **One worker, many threads.** One binary runs tests on its own thread
  pool. A crash ends the whole run, and output cannot be told apart by test.
- **A process per test,** as cargo-nextest does. Every test pays the
  binary's start-up, including module constructors, and loses any warm state.
- **A pool of worker processes,** each running one test at a time.

**Choice.** A pool of worker processes. Running one test at a time makes
output capture by test exact and a crash costs one test. A pool keeps
start-up to once per worker.

**Revisit when** a suite's tests interfere through process-wide state often
enough that a process per test pays for itself.

## TRD4: Frames on standard output, test output on standard error (proposed)

**Question.** Which channels carry frames and the tests' own output?

**Alternatives.**

- An extra pipe passed as a third inherited descriptor. On Windows a child
  inherits extra handles only through a handle list given at spawn time and a
  handle value passed in its arguments.
- A named pipe or a Unix-domain socket at a path the runner chooses.
- Frames on the worker's standard output, moved aside before any test runs,
  and test output captured through a pipe the worker reads and forwards as
  frames.
- Frames on standard output, moved aside, and test output on standard error,
  a pipe the runner reads, with descriptor 1 pointed at it.

**Choice.** The last. Every platform's process-spawning API connects three
standard streams. A pipe the worker reads itself loses what it has not
forwarded when the worker crashes, which is the output a crash report needs
most, so the runner owns the output pipe and a sentinel line marks where a
test's output ends (TRP24). A module constructor that prints before the
protocol starts produces stray bytes the runner shows (TRP8), not corrupt
frames.

**Revisit when** a test needs its standard output and standard error kept
apart in the report.

## TRD5: The attributes have their own package (proposed)

**Question.** The owner's outline put discovery, registration and the
attributes in the shim. Which of them can a `sourceLibrary` own?

**Choice.** The shim holds only the registration hook.

- **The attributes:** library builds import them, so they need a package that
  library configurations can depend on. A `sourceLibrary` is compiled into
  every target that depends on it, and the harness would bring the
  measurement layer into every application and WebAssembly module. So they get
  `sparkles:test-attributes`, which holds nothing else (TRP3).
- **Discovery:** a set of templates that the harness's own tests instantiate
  too (TRP4), so it lives in the harness, and the shim instantiates it against
  `dub_test_root`.

**Revisit when** library builds need nothing from the attributes module.

## TRD6: The pin is a file, not a flake input (proposed)

**Question.** Where is the runner's revision recorded?

**Alternatives.**

- A flake input. Only Nix can read it, and the Windows CI leg has no Nix.
- A file holding the revision and its source hash, read by Nix's fetcher and
  by any leg without Nix.

**Choice.** The file, `nix/test-runner-pin.json` (TRN1).

**Revisit when** every leg that builds tests runs Nix.

## TRD7: One runner core, two clients (accepted)

**Question.** The runner must serve third-party `dub test` users with no
`sparkles:ci`, and `ci` must run the same test binaries under its own
executor, reporters and result reuse. Where does the code that talks to a
worker live?

**Alternatives.**

- ci starts the standalone runner per test binary and parses its report. ci's
  executor then sees one opaque process, its reporters a second report, and
  result reuse an output it cannot interpret.
- ci implements the protocol client itself. The two clients drift.
- One library that both link: the option model, the protocol client, the run
  plan and the verdict. Each client supplies process spawning, I/O,
  scheduling and rendering.

**Choice.** The library, `sparkles:test-runner-core`, as a protocol state
machine that performs no I/O (TRM1–TRM4). The owner required the two modes on
2026-11-02. The standalone runner drives it with threads and pipes; ci drives
it with supervised process groups on Event Horizon, which its task-DAG rules
require.

**Trade-offs.** The state machine is harder to write than a client with
blocking reads, and each client owns the I/O loop around it. In return the
core runs under either runtime, and a transcript test exercises it with no
process at all.

**Revisit when** a client needs something the event stream cannot carry.

## TRD8: The client schedules, and ci's unit is a leg (accepted)

**Question.** Who decides how many workers run and which test each runs, and
what is the unit ci schedules?

**Alternatives.**

- **An executor seam in the core.** The core asks its client for capacity and
  places tests itself: the core becomes a scheduler, and depends on ci's
  executor to be one inside ci.
- **A task node per test,** or a process per test as cargo-nextest runs. The
  executor sees every test, but a graph holds thousands of nodes, the build
  graph's reuse unit becomes a test, and every test pays the binary's
  start-up: the spawn and druntime's and the modules' initialization, dearer
  on Windows and macOS than on Linux.
- **A worker node per session, pulling from a shared queue.** The nodes share
  mutable state the task model does not have, which test a node runs is a
  race, and a node's result cannot be reused.
- **A node per leg of a binary,** claiming `N` tokens and running up to `N`
  sessions, as a linker runs its threads within its claim.

**Choice.** The client schedules (TRM3), and ci's unit is a leg (TRM5). The
leg is the build graph's test action and its unit of reuse; placement inside
it is the same pool logic the standalone runner uses, bounded by the claim the
executor granted. Admission still decides which legs run across packages.

**Trade-offs.** The executor does not see individual tests; their results
reach it as the leg's output and observations (TRM6). A slow test holds its
leg's claim to the end, as a slow linker does. A crash still costs one test
(TRP26).

**Revisit when** the executor gains sub-tasks that make per-test units cheap,
or a suite's tests interfere often enough to pay for a process per test.

## TRD9: The pin is the standalone runner's (accepted)

**Question.** D16 pinned the runner because test binaries linked it. With the
runner out of process, what does the pin cover, and does ci use it?

**Alternatives.**

- ci runs tests through the pinned standalone runner, as a toolchain
  component.
- ci links the core compiled into it, and the pin covers only the standalone
  runner.

**Choice.** The second (TRM8). Test actions key on the core inside the ci
build that runs them. The pin keeps a developer's `dub test` from rebuilding
the runner when the tree changes; the handshake rejects a protocol mismatch
between either client and a binary.

**Trade-offs.** A change to the core reruns every test action; a change to the
standalone runner reruns none of them.

**Revisit when** the dev shell can build the runner from the tree without
rebuilding on unrelated changes.

## TRD10: A worker's end outside a test fails the run (accepted)

**Question.** A worker can end with no test running: on its own between
commands (TRP27), or, asked to exit, with a status other than 0 (TRP22), for
example a module destructor that aborts after every test passed. No test is
to blame. Does the run still fail, and does the runner start another worker?

**Alternatives.**

- Ignore the ending when every test has a result, and start a new worker
  for any work that remains.
- Fail the run with the ending and the worker's unattributed output, and
  start no other worker.

**Choice.** The second (TRP22, TRP27), accepted by the owner on 2026-11-11.
The ending is a defect of the binary under test, as real as a failing test;
a runner that passed it would report what a plain druntime run reports as a
failure as a success. Restarting would hide a worker that dies after every
test the same way.

**Trade-offs.** No test result names the defect; the run's error line and
exit status do, and the tests that ran keep their results. Work that remained
is not run.

**Revisit when** a binary needs a worker restarted after an ending that is
not a crash, such as a test that ends the process on purpose.

## TRD11: A dead worker's channels are read for one second after its end (proposed)

**Question.** A test can fork a child that holds the worker's pipes open
after the worker dies, quiet or writing. When does the runner learn of the
end, and when does it stop reading (TRP28)?

**Alternatives.**

- Wait for the frames' end of file, then for the process; stop reading the
  output once no byte has arrived for a second.
- Watch the process itself; stop reading both channels at end of file or one
  second after the end, whichever comes first.

**Choice.** The second. With the first, a child that sleeps holds the end
back for as long as it sleeps, and one that keeps writing holds it back for
as long as it writes. Everything the worker wrote before it ended is already
in the pipes when it ends, so a second is ample for it; what arrives later
is the child's.

**Trade-offs.** A child that writes in that second has its bytes taken as
the worker's. The client looks for the end every tenth of a second while it
waits for frames, so an end is seen up to that late.

**Revisit when** a platform offers a wait that wakes on both a process's end
and a pipe's bytes, or a test's child needs its output kept.
