# Dynamic Dependencies Under Distributed Execution (Theme)

A dynamic dependency is one the task description cannot name, because it appears
only after some work has run. Remote execution wants the opposite — a closed
action graph for a worker fleet. This page separates the two decisions both called
"dynamic" (graph _shape_ versus action _placement_), follows each through Bazel,
Buck2, Ninja, Nix and PIE, and records what their authors do and do not prove.

**Last reviewed:** November 3, 2026

> [!NOTE]
> **Catalog inference** marks a claim this page derives from the cited sources
> rather than one the source states. Where a system publishes no termination or
> correctness argument, the page says so rather than supplying one.

| Field      | Value                                                                                      |
| ---------- | ------------------------------------------------------------------------------------------ |
| Category   | Theme — cross-cutting; no single system                                                    |
| Question   | How does a build discover an edge mid-build when the executor only accepts closed actions? |
| Mechanisms | restarting, suspending, manifest patching, plan-as-output, script recording                |
| Systems    | Bazel, Buck2, Ninja, Nix dynamic derivations, PIE; REAPI servers as the distribution seam  |
| Vocabulary | [concepts] — _scheduler_, _rebuilder_, _trace_ and _minimality_ are not redefined here     |

**Built from (in-corpus):** [concepts] (§2's static/dynamic split, §5's grid),
[a-la-carte] (JFP §4.3, §5.4, §6.5), [bazel], [buck2], [ninja], [pie],
[nix-dynamic-derivations], [nix-ninja], [nix-cargo-unit], [makenix],
[perfect-dependencies], [rattle] and [sandboxing-overheads].

## Overview

### What it solves

[concepts] §2 defines the problem: an `Applicative` task's dependencies can be
extracted before execution, while a `Monadic` one's exist only after a run. A
topological scheduler needs the former, so every system that accepts the latter
pays in one of three ways — restart, suspend, or mutate the graph. Under remote
execution that becomes an interface question: the protocol's unit is a
self-contained action, and a dependency discovered mid-build is not one.

Two different things travel under the word "dynamic". **Dynamic discovery**
changes the graph's _shape_ — `dyndep`, Buck2's `dynamic_output`, Nix's
`.drv`-producing derivations, PIE's `reqTasks`. **Dynamic scheduling** changes an
action's _placement_ — the local/remote race both Bazel and Buck2 call "dynamic
execution"; there the graph is known and only the executor is chosen at run time.
The first is the subject here; the second shares the adjective and cost model.

### Design philosophy

Three camps, three things a reader must trust: that restarts converge, that a
graph patch preserves the topological order, or that the scheduler's reuse
judgment is sound. Only the last is presented as a theorem.

> "A consequence of this is that any computation performed inside the
> `SkyFunction` prior to the restart must be repeated."
>
> — Bazel [`docs/contribute/codebase.mdx`][bazel-codebase]

> "The theorem is unconditional: it assumes nothing about the caller."
>
> — Buck2 [`dice/docs/incrementality.md`][dice-doc] § preamble

## How it works

### 1. Restarting — Bazel's Skyframe

A `SkyFunction` may ask for an unavailable key. It receives `null`, returns
`null`, and Skyframe evaluates the missing dependency and re-invokes the function
from the beginning ([bazel] §2, [`skyframe.mdx`][bazel-skyframe]). That is
[concepts]'s restarting scheduler and Bazel's dynamic-dependency mechanism at
once: the function discovers its edges by asking for them.

The cost is repeated computation, mitigated by batched requests
(`getValuesAndExceptions()`), splitting one large value across functions, and
`Environment.getState()` ([`codebase.mdx`][bazel-codebase]). Completed dependency
values stay cached; only the function body is repeated. [concepts] §4.2 records
the verdict — correct but not minimal.

### 2. Suspending — Buck2's DICE

Buck2's `compute` awaits a key rather than restarting. DICE records a certificate
— key, result revision, dependency premises and their revisions — so a completed
computation revalidates at pointer scale ([buck2] §2): [concepts]'s suspending ×
verifying cell, with revisions for content hashes. Dynamic dependencies are
deliberately narrower than the model allows:

> "Dynamic dependencies in Buck2 are implemented using `dynamic_output` and are
> restricted in their power compared to fully generic dynamic dependencies."
>
> — Buck2 [`dynamic_dependencies.md`][buck2-dyndeps]

`ctx.actions.dynamic_output(dynamic, inputs, outputs, f)` builds the `dynamic`
artifacts first, hands `f` their contents (`read_string`, `read_lines`,
`read_json`), and requires `f` to bind the declared outputs through
`ctx.actions.run`; `inputs` is ignored. The documented uses are compiler-shaped:
ThinLTO index files, `ocamldeps`, Erlang header and BEAM ordering.

### 3. Patching — Ninja's `dyndep`

Ninja keeps its topological scheduler and lets one input patch the manifest. A
`dyndep` binding names a file produced by an input edge; when that producer
finishes, `Plan::EdgeFinished` calls `Builder::LoadDyndeps`, which appends
implicit outputs, inserts implicit inputs before the order-only tail, and may add
`restat` ([ninja] §`dyndep`, [`src/dyndep.cc`][ninja-dyndep]). The file uses Ninja
syntax, one `build out | imp-outs : dyndep | imp-ins` statement per edge, and its
forward-only invariant is the safety condition:

> "A dyndep file may not change the build graph in a way that causes up-to-date
> build statements to become out-of-date."
>
> — Ninja [`doc/manual.asciidoc`][ninja-manual]

The implementation also enforces one-to-one correspondence: a manifest edge with
no dyndep statement, or vice versa, is an error ([`src/dyndep.cc`][ninja-dyndep]).
Ninja never restarts or suspends an edge; it adds edges to a graph whose order is
still valid. **Catalog inference:** a backward edge would invalidate a decision
the scheduler has already made, which is why the invariant is stated so narrowly.

### 4. Publishing — Nix's dynamic derivations

Nix moves the bind from the evaluator into the scheduler: a derivation's
text-hashed output may itself be a `.drv`, and `builtins.outputOf` names an output
of that not-yet-built derivation ([nix-dynamic-derivations] §How it works).
Resolution rewrites the placeholder once the producer is realised, and the
resolved derivation — not the declared one — is what gets hashed and keyed. Under
distribution the discovered plan is then an ordinary store object: remote-buildable,
substitutable and addressable as `…-foo.drv^out^out`. The cost is termination:

> "For dynamic derivation graphs, however, this is not the case — resolution is
> not guaranteed to terminate."
>
> — Nix [`store/resolution.md`][nix-resolution]

[nix-ninja] demonstrates the idea one level down — a wrapper derivation scans
headers and emits the real compile derivation — while [nix-cargo-unit] keeps the
older import-from-derivation shape and [makenix] expands a `Makefile` inside a
sandbox. All three turn "learn the graph by running a tool" into "a derivation
whose output is the graph".

### 5. Recording — PIE's hybrid

PIE has the most direct statement of the problem: a programmable script can loop,
branch and call tasks, so no description determines its graph. Every result
carries `reqFiles`, `genFiles` and `reqTasks` — the executed edges, not the
planned ones — and the previous run's graph is the input to the next
([pie] §2–§3). A change-driven bottom-up walk handles old edges; a top-down
fallback runs tasks that did not exist before. Its scheduler needs a _changed-file
set_ and a _previous graph_, neither of which a remote executor supplies — the
grid lacks PIE's change-driven discipline ([pie] §Relation to à la carte).

### Where the dynamic decision is made

| System | Discovery lives in                      | Scheduler            | Distribution unit  | An edge crosses the seam as                       |
| ------ | --------------------------------------- | -------------------- | ------------------ | ------------------------------------------------- |
| Bazel  | `SkyFunction` calls, multiple passes    | restarting           | one REAPI `Action` | inputs resolved before the action is dispatched   |
| Buck2  | `dynamic_output` reading an artifact    | suspending           | one action digest  | a built artifact read by analysis, then an action |
| Ninja  | `dyndep` file read at producer finish   | topological          | none native        | an ordinary input file                            |
| Nix    | resolution of a `.drv`-producing output | suspending           | one derivation     | a `.drv` store object, substitutable              |
| PIE    | task execution, recorded per result     | change-driven hybrid | none               | not applicable                                    |

## The distribution seam

REAPI's `Execution.Execute` takes one `action_digest`; the client must already
have uploaded the inputs, command and action, and the server runs _that action_
and streams an operation ([`remote_execution.proto`][reapi-proto]). There is no
field for a dependency graph, no "run this after that", and no callback for "the
action discovered a new edge". The README describes the purpose as distributing
"build and test actions through a worker pool" ([`README.md`][reapi-readme]).

> "The server does not need to guarantee that a call to this method leads to at
> most one execution of the action. The server MAY execute the action multiple
> times, potentially in parallel."
>
> — REAPI [`remote_execution.proto`][reapi-proto]

An `Action`'s input root must also be in the CAS before execution. The action is
closed at dispatch time; discovery that has not finished is not an input.

1. **The graph stays client-side.** Bazel, Buck2 and Nix schedule locally and
   send individual actions; a remote scheduler can order its queue but cannot see
   that one queued action would unlock three others. **Catalog inference:** REAPI
   servers compete on queue policy, worker locality and cache placement rather
   than graph scheduling — the graph never reaches them.
2. **Discovery must be materialised as an action output.** A `dyndep` file, a
   `dynamic_output` artifact, a `.drv` and a PIE result are all records produced
   before the dependent work starts. **Catalog inference:** every scheme
   serialises graph growth through the store or the file system.
3. **The seam adds a round trip per discovery boundary.** Locally, reading a
   depfile is a file read; remotely, the producer must complete, its output must be
   recorded or uploaded, and only then can the dependent input root be assembled.
   `FindMissingBlobs` avoids re-sending bytes, not the round trip
   ([`remote_execution.proto`][reapi-proto]).
4. **Deferred materialisation ends where a dynamic read begins.** Buck2 normally
   avoids downloading outputs until a local action needs them, but
   `dynamic_output` must read an artifact's contents, so that artifact has to be
   materialised ([buck2] §2, [`dynamic_dependencies.md`][buck2-dyndeps]).
   **Catalog inference:** a dynamic edge is a forced download point.

### Reducing stalls without breaking action closure

The seam does not have to cost a naive client/worker ping-pong for every edge,
but every optimisation works around — not through — REAPI's closed action:

- **Batch discovery into an index action.** ThinLTO's indexer reads all
  summaries once and emits per-backend import lists, turning many potential
  discoveries into one synchronisation point ([link-time-pruning] §5). The
  cost is a barrier; the benefit is that backends become ordinary parallel
  closed actions.
- **Inline the small discovery record.** REAPI `Execute` requests can ask for
  `inline_stdout`/`inline_stderr` and named `inline_output_files` in the
  `ExecuteResponse` ([`remote_execution.proto`][reapi-proto]). A tiny depfile
  or imports list can therefore return with the operation instead of requiring
  a second CAS fetch, though the client still cannot dispatch dependents until
  it reads and interprets the record.
- **Prefetch likely inputs while the producer runs.** Candidate blobs can be
  staged from history, but the dependent action's input root/digest cannot be
  finalised until discovery says which subset is real. Prefetch hides transfer
  latency; it does not remove the dependency on the producer's result.
- **Collocate the planner with the CAS.** If analysis runs beside the store,
  reading a discovery artifact is local metadata work rather than a client
  download. This moves the seam, it does not eliminate it: the planner still
  has to serialise graph growth through completed actions.
- **Keep discovery depth shallow.** A chain of k dynamic boundaries costs at
  least k producer completions in series. Designs that let one discovery
  artifact describe a whole subgraph (Nix generated derivations, a ThinLTO
  combined index) pay fewer round trips than one-edge-at-a-time rewriting.

**Catalog inference:** the metric that matters is not dynamic-edge count but
_dynamic depth on the critical path_ — how many discovery records must be
produced, transferred, and interpreted serially before the longest chain of
real work can be dispatched.

### Dynamic execution is a different axis

> "Dynamic execution is a feature in Bazel where local and remote execution of the
> same action are started in parallel, using the output from the first branch that
> finishes, cancelling the other branch."
>
> — Bazel [`docs/remote/dynamic.mdx`][bazel-dynamic]

Buck2's hybrid executor does the same at action level — "whichever claims the
request first will get to execute it", with a remote failure re-queued locally
([`hybrid.rs`][buck2-hybrid]). Both are placement decisions over a known graph, so
neither solves discovery. The docs warn the race "assumes there are enough
resources available locally and remotely that it's worth spending some extra
resources", delay the local branch by `--dynamic_local_execution_delay` (default
1000 ms) after a remote cache hit, and either cancel the loser or let it populate
the remote action cache ([`dynamic.mdx`][bazel-dynamic]). **Catalog inference:**
the race compounds discovery's cost, because a discovery boundary creates the
round-trip latency the local branch exists to hide.

Speculation is the third decision deferred to run time: Rattle argues remote
execution would _remove_ speculative-write-read hazards, since speculative writes
land in a remote sandbox rather than the local tree ([perfect-dependencies]
§6.2) — an argument for combining speculation with an execution service.

## Termination and correctness, as published

| System | Published claim                                                                                       | Holds under                                              | Not claimed                                                |
| ------ | ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------- |
| Bazel  | "Correct and perfect incrementality" if all input data is recorded ([`skyframe.mdx`][bazel-skyframe]) | hermetic `SkyFunction`s; an acyclic node graph           | termination; minimality (restarts repeat work)             |
| Buck2  | `lookup` soundness is unconditional ([`incrementality.md`][dice-doc] §3.3)                            | nothing about the caller                                 | completeness; from-scratch agreement without honest traces |
| Ninja  | a patch leaves the graph "as if the information was known originally" ([`manual`][ninja-manual])      | one-to-one mapping; forward-only edges; acyclic manifest | termination beyond the topological invariant               |
| Nix    | resolution is total for static graphs ([`resolution.md`][nix-resolution])                             | static derivation graphs                                 | termination for dynamic graphs; a correct generated graph  |
| PIE    | correctness for old and new tasks; "partially optimal" ([pie] §4.3)                                   | tasks terminate; cycles disallowed; a changed-file set   | distribution; full minimality                              |
| JFP    | any scheduler × rebuilder is correct ([concepts] §5)                                                  | an acyclic task description                              | a distributed implementation of every cell                 |

**Bazel.** `skyframe.mdx` targets hermetic, deterministic functions and describes
a "directed acyclic graph"; it does not argue termination. **Catalog inference:**
termination follows from that acyclicity plus each restart being triggered by the
missing key, so the unevaluated set shrinks.

**Buck2.** Soundness is a theorem about the recorded history alone; from-scratch
consistency needs honest traces and complete change reporting. Completeness is
deliberately not a goal, and §6 is a `FIXME` rather than a result
([`incrementality.md`][dice-doc]). Cycles use the least relation: "no acyclicity
precondition appears anywhere in this document, for soundness or for termination",
because the core never recurses through the certificate graph — the cleanest
published separation of "the graph may be wrong" from "the answers are sound".

**Ninja.** The invariant is a correctness condition for _patching_, not a
termination proof. It works because the scheduler is topological: after the patch
the ready queue is re-checked and dependents are scheduled in the new order
([ninja] §`dyndep`). **Catalog inference:** a dyndep file violating the
forward-only rule is a user error, not a case the engine repairs.

**PIE.** Correctness is argued in three cases — old tasks scheduled bottom-up, old
tasks reached through `requireNow`, and new tasks executed top-down — and the paper
concedes the hybrid "is only partially optimal" because it treats every task in the
old graph as needed ([pie] §4.3). Termination is conditional on the script:

> "Unless a task itself does not terminate (for example by recursively calling new
> tasks ad infinitum), the queue becomes empty at some point since cyclic tasks
> are disallowed, terminating the algorithm."
>
> — PIE §4.2

**Nix.** Resolution is a function for static graphs and a partial relation for
dynamic ones; `tryResolve` returns `std::nullopt` rather than a wrong answer, and
filled-in derivations "may have more transitive dependencies than the original
derivation" ([`store/resolution.md`][nix-resolution]).

### A minimal proof/obligation checklist for a new dynamic scheme

The published systems suggest six separate obligations; collapsing them into
"the scheduler is correct" hides where dynamic rewrites usually fail:

1. **Local task termination** — each producer/task terminates and returns a
   finite discovery record.
2. **Finite graph growth** — generated nodes/edges are drawn from a finite or
   well-founded universe; a task cannot mint fresh identities forever.
3. **Acyclicity or a defined cycle semantics** — newly added edges cannot make
   a task wait on itself unless the scheduler gives cycles a least-fixed-point
   meaning (DICE) rather than a deadlock.
4. **Monotonic, idempotent discovery** — re-reading the same record adds the
   same edges once; retries and duplicate remote executions cannot create
   distinct graph identities for one logical task.
5. **No work executed on an obsolete graph version** — if an input changes
   while discovery/execution is in flight, results are tied to the graph/input
   revision that produced them and are discarded or revalidated.
6. **Discovery-record completeness** — the record contains every input the
   consumer will read, including absent-path probes and environment/toolchain
   facts; otherwise graph termination is proved for the wrong graph.

Most production systems discharge 2–4 by construction (finite static task
identities, forward-only patches, content-addressed records) and leave 1 and
6 to the tool author. A scheme that generates task identities from arbitrary
build outputs — dynamic derivations taken to their limit — has to state 2
explicitly or termination becomes a property of user code.

## Analysis spine

Discovery is `Monad`-shaped throughout, but the rebuilder stays orthogonal:
Bazel, Buck2, Ninja, Nix and PIE keep constructive, verifying or stamp-based
traces, and only Nix makes the new edge part of the key. None traces a process;
each records what a cooperating tool reported, and that record needs a home
between producer and consumer — the file system for Ninja, the REAPI CAS for
Bazel and Buck2, the Nix store for a `.drv`. **Catalog inference:** the store
decides how well discovery distributes, because a `.drv` has a content address a
worker can fetch while a `dyndep` file is only readable where the build runs.

## Strengths

- **Publishing is the only encoding that survives distribution cleanly**,
  because the fragment becomes a store object with a content address.
- **Patching is the smallest change to an existing scheduler**: it buys
  first-build correctness for Fortran and C++20 modules without touching
  topological order.

## Weaknesses

- **Neither restarting nor suspending comes free**: restarting is cheapest to
  implement and most expensive to run, while suspending matches a modern
  engine's shape but needs a daemon and a completeness claim explicitly not
  made.
- **Patching and recording trade generality or distribution**: patching is
  limited to one file and forward-only one-to-one edges, while recording
  (loops and conditionals) is the least distributable because it needs the
  previous graph and a changed-file set.

## Key design decisions and trade-offs

| Decision                                  | Rationale                                                            | Trade-off                                                             |
| ----------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Restart rather than suspend (Bazel)       | No continuations; plain Java; one evaluator for analysis and actions | Repeated work; `getState()`/`StateMachine` complexity                 |
| Expose only `dynamic_output` (Buck2)      | A bounded, analysable form of dynamic dependency                     | Cannot express fully general monadic rules                            |
| Patch the manifest (Ninja)                | First-build module correctness without a restarting scheduler        | One-to-one mapping; forward-only invariant; user error if violated    |
| Make the graph a store object (Nix)       | Discovery becomes cacheable, substitutable and remote-buildable      | Resolution may not terminate; feature flags on every participant      |
| Record executed edges (PIE)               | Handles control flow no description can express                      | Needs a prior graph and a changed-file set; partially optimal         |
| Keep graph scheduling client-side (REAPI) | One action is a simple, cacheable, closeable unit                    | Remote scheduler cannot see or prioritise the graph                   |
| Race local and remote (dynamic execution) | Hides incremental-build latency without a graph rewrite              | Double resource use; round-trip cost; either branch failing fails all |

## Sparkles relevance

`sparkles.build_primitives.task` is a validated in-memory DAG with
`TaskNode`/`TaskEdge`, `EdgeCondition` and `EdgeReason`, executed by one owner
fiber; the spec puts "distributed admission across several executor fibers,
persistent scheduler state and a workflow file format" out of scope
(`libs/build-primitives/src/sparkles/build_primitives/task/model.d`,
`docs/specs/build-primitives/task-dag/SPEC.md`). Its lessons
therefore concern where a future seam would go:

- **`EdgeReason.planning` already names the right shape.** "A planning step feeds
  the work it planned" is the static analogue of a discovery edge; a dynamic
  version would need the edge's target set to be an output of the planning node,
  not a fixed `TaskIndex`.
- **If the DAG is distributed, an action must be closed before it leaves the
  process.** The REAPI seam accepts an input root and a command, not a graph, so a
  discovery task's output must land in a content-addressed store before a
  dependent action is dispatched — the Nix/`.drv` pattern, not `dyndep` mutation.
- **Record executed edges as events even while the graph is static.** PIE's
  `reqFiles`/`genFiles`/`reqTasks` and Nix's resolved `.drv` both exist because the
  planned graph is not the executed one; Sparkles already emits per-task events.
  A daemon is not worth it separately: Buck2 amortises certificates across a
  long-lived process.

## Sources

In-corpus pages consulted: [concepts] (§2, §5, §6's deferred topics),
[a-la-carte] (JFP §4.3, §5.4, §6.5), [bazel], [buck2], [ninja], [pie],
[nix-dynamic-derivations], [nix-ninja], [nix-cargo-unit], [makenix],
[perfect-dependencies], [rattle], [sandboxing-overheads].

- Bazel `2105aec32b598dcc8e09905e7cf18ccfa4b0358e` ([`skyframe.mdx`][bazel-skyframe],
  [`codebase.mdx`][bazel-codebase], [`dynamic.mdx`][bazel-dynamic]); Buck2
  `08b403b138373f506de90d15370162677526e388`
  ([`dynamic_dependencies.md`][buck2-dyndeps], [`incrementality.md`][dice-doc],
  [`hybrid.rs`][buck2-hybrid]); Ninja `a7d7504e98d07f05a60f37411206907c00cb4ef7`
  ([`manual.asciidoc`][ninja-manual], [`dyndep.cc`][ninja-dyndep]).
- Nix upstream tip `1ed54a0fd62da96d4f5e9c806555861e46f65341` (2026-09-12), read
  via `git show` from `$REPOS/build-systems-research/src/nix`:
  [`store/resolution.md`][nix-resolution]. RFC 92 is cited through
  [nix-dynamic-derivations].
- Remote Execution API `c2c07e3d718d3d490a4958344d9c3e47de0bfaf3`:
  [`README.md`][reapi-readme], [`remote_execution.proto`][reapi-proto].
- Mokhov, Mitchell & Peyton Jones, JFP 30, e11 (2020) — [DOI][jfp]; §4.3 and §9.1
  from the local PDF. Konat, Erdweg & Visser, ASE 2018 — [DOI][pie-doi]; §4.2 and
  §4.3 from the local PDF. Both PDFs live under `$REPOS/papers/build-systems/`.

<!-- References -->

[concepts]: ./concepts.md
[link-time-pruning]: ./link-time-pruning.md
[a-la-carte]: ./a-la-carte.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[ninja]: ./ninja.md
[pie]: ./pie.md
[nix-dynamic-derivations]: ./nix-dynamic-derivations.md
[nix-ninja]: ./nix-ninja.md
[nix-cargo-unit]: ./nix-cargo-unit.md
[makenix]: ./makenix.md
[perfect-dependencies]: ./perfect-dependencies.md
[rattle]: ./rattle.md
[sandboxing-overheads]: ./sandboxing-overheads.md
[jfp]: https://doi.org/10.1017/S0956796820000088
[pie-doi]: https://doi.org/10.1145/3238147.3238196
[bazel-skyframe]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/reference/skyframe.mdx
[bazel-codebase]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/contribute/codebase.mdx
[bazel-dynamic]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/remote/dynamic.mdx
[buck2-dyndeps]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/docs/rule_authors/dynamic_dependencies.md
[dice-doc]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/dice/docs/incrementality.md
[buck2-hybrid]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/app/buck2_execute_impl/src/executors/hybrid.rs
[ninja-manual]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/doc/manual.asciidoc
[ninja-dyndep]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/dyndep.cc
[nix-resolution]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/store/resolution.md
[reapi-readme]: https://github.com/bazelbuild/remote-apis/blob/c2c07e3d718d3d490a4958344d9c3e47de0bfaf3/README.md
[reapi-proto]: https://github.com/bazelbuild/remote-apis/blob/c2c07e3d718d3d490a4958344d9c3e47de0bfaf3/build/bazel/remote/execution/v2/remote_execution.proto
