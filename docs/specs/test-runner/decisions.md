---
status: draft
owner: sparkles:test-runner
reviewed: 2026-11-02
---

# `sparkles:test-runner` — Decisions

Each record states its question, the alternatives, the choice and when to
revisit it. **Accepted** records were accepted by the owner; **proposed**
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
  Linux, kept outside the tree, passed `base`'s 982 tests, but only after a partial link and a
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
