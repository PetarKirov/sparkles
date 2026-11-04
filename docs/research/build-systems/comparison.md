# Build Systems: Comparison & the Sparkles Delta

The capstone of the build-systems survey. **Part 1** places every system the
catalog reviews on the [concepts] scheduler × rebuilder grid and says which rows
refuse a cell. **Part 2** re-cuts the same evidence along the six spine
dimensions, so the grid's abstractions meet the mechanisms that implement them.
**Part 3** states the consensus the field has converged on, **Part 4** the
trade-offs that keep it from being one design, and **Part 5** the delta against
the Sparkles task DAG in
`libs/build-primitives/src/sparkles/build_primitives/task/`.
**Part 6** lists what the survey could not settle.

> [!NOTE]
> This is the synthesis leaf: it re-derives nothing. Claims about a system are
> the deep-dive's, cited by page; claims about Sparkles are read from the files
> named in [Part 5](#part-5--the-sparkles-delta). The catalog's own inferences are
> marked **Catalog inference**, as on the themes.

| Field            | Value                                                                                     |
| ---------------- | ----------------------------------------------------------------------------------------- |
| Page type        | Synthesis (capstone)                                                                      |
| Covers           | 5 foundations, 20 industry rows, 9 Nix projects, 14 themes                                |
| Grid vocabulary  | [concepts] §2–§5, from JFP 2020                                                           |
| Sparkles subject | `sparkles:build-primitives` task DAG (`model.d`, `graph.d`, `executor.d`, `action.d`)     |
| New clones read  | none for this page; revised inputs re-read Zinc, Wild, Coq artifacts, CAS implementations |
| Status of inputs | every page below reports `reviewed` (priority pages revised in depth on 2026-11-03)       |

**Last reviewed:** November 3, 2026

---

## Part 1 — The master grid

### 1.1 The twenty industry rows

Reproduced from the [master catalog][index] and checked against each deep-dive's
own placement section. `—` means the deep-dive declines to classify.

| System   | Scheduler                 | Rebuilder                                 | Link                 |
| -------- | ------------------------- | ----------------------------------------- | -------------------- |
| BuildXL  | topological               | verifying traces                          | [BuildXL][buildxl]   |
| Bazel    | restarting                | constructive traces                       | [Bazel][bazel]       |
| Buck2    | suspending                | verifying traces                          | [Buck2][buck2]       |
| build2   | topological (recursive)   | mtime dirty bit + `depdb`                 | [build2][build2]     |
| Please   | suspending                | verifying traces                          | [Please][please]     |
| Ninja    | topological               | verifying traces (qualified)              | [Ninja][ninja]       |
| GNU Make | topological               | dirty bit                                 | [GNU Make][gnumake]  |
| redo     | suspending                | verifying step traces                     | [redo][redo]         |
| tup      | topological               | dirty bit (observed)                      | [tup][tup]           |
| Shake    | suspending                | verifying step traces                     | [Shake][shake]       |
| Rattle   | speculative (off-grid)    | constructive in spirit                    | [Rattle][rattle]     |
| Earthly  | static DAG (via BuildKit) | constructive traces + auto-skip           | [Earthly][earthly]   |
| GN       | not a cell (generator)    | —                                         | [GN][gn]             |
| Meson    | not a cell (generator)    | —                                         | [Meson][meson]       |
| Boba     | —                         | —                                         | [Boba][boba]         |
| Pants v2 | suspending                | verifying step traces                     | [Pants][pants]       |
| Moon     | topological               | constructive (action cache)               | [Moon][moon]         |
| BitBake  | topological               | signature-stamp dirty bit + sigdata trace | [BitBake][bitbake]   |
| sbt      | topological + suspension  | per-invocation dirty bit + action cache   | [sbt][sbt]           |
| BuildKit | topological               | constructive traces                       | [BuildKit][buildkit] |

The arithmetic is a finding: **sixteen** rows occupy a cell, **one** is
deliberately off-grid — Rattle is a _forward_ system whose trace replaces the
declaration, and [perfect-dependencies] argues no cell describes it — and
**three** are not engines, since GN and Meson generate a Ninja graph ([gn],
[meson]) and Boba is Fuchsia's in-tree GN + Bazel dual-graph integration layer
rather than an independent engine ([boba]). Two labels carry qualifiers
that matter more than the label. Ninja's `restat` is a dirty-bit refinement
bolted onto a trace, and the manual states both mechanism and limit:

> "`restat`:: if present, causes Ninja to re-stat the command's outputs after
> execution of the command. Each output whose modification time the command did
> not change will be treated as though it had never needed to be built. This may
> cause the output's reverse dependencies to be removed from the list of pending
> build actions."
>
> — [`doc/manual.asciidoc`][ninja-restat]

That is early cutoff implemented as "the mtime did not move" — the false-negative
class [reproducibility] names. sbt is a composite: `Execute` is topological, but
`Left(target)` plus a `Calling` state adds suspension on demand ([sbt]).
Composites are where the grid's orthogonality leaks.

### 1.2 The nine Nix projects: satellites, not cells

None adds a scheduler or a rebuilder; each is a _generator_ or _front end_ that
emits work into Nix's cell. The variable is where the graph is decided.

| Project                                            | What it contributes                                                 | Cell                                         |
| -------------------------------------------------- | ------------------------------------------------------------------- | -------------------------------------------- |
| [nixception][nixception]                           | REAPI actions bridged into `recursive-nix` derivations              | Nix's cell, entered through a proxy          |
| [nix-ninja][nix-ninja]                             | Ninja edges lowered to content-addressed derivations                | topological × deep constructive, split       |
| [sandstone][sandstone]                             | Per-module Haskell derivations with an object/interface split       | Nix's cell, derivation set built at run time |
| [drowse][drowse]                                   | `nix-instantiate` + `crate2nix` as build steps emitting derivations | **no cell** — a lowering layer               |
| [dgd][dgd]                                         | Go builds planned from `go build -n`                                | Nix's cell, plan produced at run time        |
| [nixgg][nixgg]                                     | `gcc`/`g++` invocations intercepted into per-invocation derivations | a front end into Nix's cell                  |
| [nix-cargo-unit][nix-cargo-unit]                   | Cargo's unit graph rendered as per-unit derivations                 | Nix's cell at unit granularity               |
| [MakeNix][makenix]                                 | A `Makefile` expanded into one derivation per object, mid-build     | Nix's cell over a Make-discovered graph      |
| [nix-dynamic-derivations][nix-dynamic-derivations] | Derivations whose output is a derivation                            | Nix's cell with the **key set open**         |

The last row is the only one that changes the grid rather than populating it:
dynamic derivations move the decision of _which derivations exist_ from
evaluation into the scheduler ([nix-dynamic-derivations]). That changes what a
key can be, not how keys are ordered.

### 1.3 What the grid cannot express

Four absences, each a gap in the vocabulary rather than a misclassification:

1. **Change-driven cancellation** — PIE needs a changed-file set as an argument
   ([pie]); a file-watch scheduler has no cell ([concepts] §7, from JFP §8.9).
2. **Forward builds** — Rattle runs the command and reconstructs edges after
   ([perfect-dependencies]); `Build` has nowhere to put that graph.
3. **Generator phases** — GN and Meson build a description, then build from it
   ([gn], [meson]); the grid starts after that phase.
4. **Eviction and provenance** — neither is a scheduler or rebuilder property,
   and neither appears in the paper ([concepts] §6).

---

## Part 2 — Per-dimension comparison

### 2.1 Task model & scheduling

| Question                 | Where the field lands                                                                 | Exemplars                                                         |
| ------------------------ | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| Static or dynamic graph? | Static for declarations; dynamic only where a tool's output is found mid-build        | [Make][gnumake], [Ninja][ninja] vs [Shake][shake], [Buck2][buck2] |
| Which scheduler?         | Topological unless dependencies are unknowable; restarting only with a memoizing host | [Bazel][bazel] is the exception                                   |
| Parallelism budget       | One global budget, published to children where a child is itself a build system       | Ninja pools, Make jobserver ([gnumake])                           |
| Conditional edges        | Rare; where present they make the executed graph a subset of the planned one          | [Pants][pants], Sparkles                                          |

### 2.2 Rebuilding & correctness

| Rebuilder           | Early cutoff | Dynamic deps | Cheapest implementation seen                 |
| ------------------- | ------------ | ------------ | -------------------------------------------- |
| Dirty bit           | no           | over-approx  | one field or one mtime ([gnumake], [tup])    |
| Verifying traces    | yes          | yes          | two timestamps per node ([shake], [redo])    |
| Constructive traces | yes          | yes          | result value + dependency hashes ([bazel])   |
| Deep constructive   | **no**       | yes          | one hash over terminal inputs ([nix-thesis]) |

Early cutoff is the rebuilder's, and its cheap forms are cheap: Shake needs two
integers per node, `built` and `changed` ([shake]); BitBake reaches it through a
second, output-derived identity when paired with OpenEmbedded's hash-equivalence
handler and `bb.hashserv` ([bitbake]); Please through an `Unchanged` outcome
([please]). Nix's deep constructive cell buys cloud capability and
single-round-trip lookups by giving that cutoff up ([nix-thesis]).

Correctness claims differ in kind. Bazel's is conditional — "Correct and perfect
incrementality. If all the input data of all functions [is recorded]"
([`docs/reference/skyframe.mdx`][bazel-skyframe]) — and the condition is the hard
part. Buck2's is unconditional: "The theorem is unconditional: it assumes nothing
about the caller" ([`dice/docs/incrementality.md`][dice-doc]). Nix's dynamic-derivation
resolution returns `std::nullopt` from `tryResolve` when an input realisation is
missing rather than synthesizing a wrong answer ([nix-dynamic-derivations]); PIE is
"partially optimal" ([pie]). **Catalog inference:** claims are strongest where the engine owns
the compute and weakest where an external tool does — the seam
[formal-verification] finds unproved.

### 2.3 Dependency discovery

| Family           | Mechanism                                        | Where it is the primary answer                                                      |
| ---------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------- |
| Declared         | the description names inputs and outputs         | [Bazel][bazel], [Buck2][buck2], [Please][please], [Pants][pants], [Nix][nix-thesis] |
| Compiler-emitted | depfile written by the tool                      | [Ninja][ninja] `.ninja_deps`, [build2][build2] `depdb`, [Meson][meson]              |
| Traced           | syscalls via `ptrace`, FUSE, eBPF, interposition | [tup][tup], [Rattle][rattle], [BuildXL][buildxl]                                    |
| Hybrid           | declared edges plus observed validation          | [BitBake][bitbake] `[file-checksums]`, [BuildXL][buildxl] fingerprints              |

**Depfiles are the practical sweet spot**: a compiler that already parses its
includes emits the edge list for free, while interception costs a syscall tax for
generality the compiler does not need ([sandboxing-overheads]). **Tracing is an
audit, not a runtime dependency** — Rattle's 7% Linux overhead, 5 points of it
tracing ([perfect-dependencies] §5.2), is why every recommending page treats it as
a _checker_ ([graph-autogeneration]). **A miss is a dependency**: a glob matching
nothing or a missing header is an input, and only a recorded miss notices it
filling in ([buildxl], [bitbake]).

### 2.4 Store & caching

| Concern               | What the corpus agrees on                                                      | Page               |
| --------------------- | ------------------------------------------------------------------------------ | ------------------ |
| Two tiers             | action key → result, blob → bytes; collapse them and eviction breaks integrity | [cas-eviction]     |
| Ordering              | touch the action entry before its blobs, or check presence on read             | [cas-eviction]     |
| Key composition       | config, rule, sources, secrets — named separately so a miss is diagnosable     | [please]           |
| Content over identity | key on what the consumer's tool reads, not the producer's whole output         | [semantic-caching] |
| Eviction              | watermarks and a background sweep, not exact budgets on the write path         | [cas-eviction]     |

The deepest divergence is about _what a key is for_. Nix keys on terminal inputs
so a target is current without materialising anything between it and the sources —
a shallow build ([nix-thesis]); Bazel keys on the action and its declared inputs so
every intermediate is reusable and early cutoff works ([bazel]). Both are correct,
and [cas-eviction]'s "shallow builds and hash passthrough" is the only place the
corpus reconciles them.

### 2.5 Hermeticity & provenance

| System   | Determinism is               | Sandbox mechanism                              | Attestation shipped         |
| -------- | ---------------------------- | ---------------------------------------------- | --------------------------- |
| Nix      | the premise of identity      | namespaces + store-only view                   | signatures on the object    |
| Bazel    | an author obligation         | symlink forest / `sandboxfs` / process wrapper | REAPI telemetry only        |
| Buck2    | the environment's obligation | sandbox                                        | none                        |
| BuildKit | a mode of the exporter       | container per step                             | **provenance as a product** |
| BitBake  | a property of the recipe     | network namespace + Landlock; no fs sandbox    | none                        |
| BuildXL  | an assumption                | Detours (Windows), `ptrace` (Linux)            | none                        |

Published overhead numbers exist for three mechanisms and are not comparable:
BuildXL's "1-5% of time overhead to running a process" on Windows
([`Documentation/Specs/Sandboxing.md`][bxl-sandboxing]), Rattle's 7% Linux / 46%
Windows over a fixed command list ([perfect-dependencies] §5.2), and Bazel's
qualitative `sandboxfs` account — "setup costs are lower, but you have to pay a
penalty for the use of each input" — before its 7.0.0 removal
([sandboxing-overheads]). The rest is `none`, which that page treats as a finding.

**Almost no engine checks that its actions are deterministic**: Nix has
`--check`, Bazel documents the procedure and ships no check, Buck2 puts the
obligation outside DICE's theorem, BuildKit's determinism is an exporter mode
([reproducibility]). Provenance is thinner — only BuildKit ships an attestation,
Bazel and REAPI emit telemetry resembling one, and Nix signs the object rather
than the build ([provenance]).

### 2.6 Distribution

| Question                        | Answer the corpus supports                                                                            |
| ------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Wire protocol                   | REAPI: Bazel, Buck2, Please, Pants, moon's cache client, nixception                                   |
| What crosses the seam           | an input root and a command — **not a graph** ([dynamic-deps-distributed])                            |
| Dynamic deps + remote execution | the discovered graph must be published as an artifact before dispatch (`.drv`)                        |
| Daemon state                    | amortizes graph work; must be named in the key or it becomes an undeclared input ([daemon-compilers]) |

An REAPI action is closed: the server receives a `Command` and a `Directory` tree,
so anything discovered at execution time must already exist as content. That is
why Nix publishes a `.drv` and Ninja's `dyndep` patches a local manifest instead
of telling a worker to discover edges ([dynamic-deps-distributed]). **Catalog
inference:** dynamic dependencies plus remote execution makes the discovered graph
a cached artifact — a store requirement before it is a scheduler requirement.

---

## Part 3 — The consensus standard

Ten claims the corpus supports across independent systems, strongest first.

1. **Identity is a hash of inputs, not a timestamp** — the mtime-only systems
   ([gnumake], [build2], [tup]) list false rebuilds as a known cost.
2. **Declare inputs; let the compiler emit depfiles; trace to audit.** With one
   production-scale exception — [BuildXL][buildxl], whose observed file accesses
   validate declarations and feed its cache keys — no system relies on
   interception as its production answer ([sandboxing-overheads]).
3. **Early cutoff is a per-edge output identity**, lost the moment dependency
   hashes collapse into one key ([moon], [nix-thesis]).
4. **Two cache tiers, with ordered touches or a completeness check**, or eviction
   creates dangling references ([cas-eviction]).
5. **A dynamic dependency needs a suspension point or a published plan** —
   `dyndep`, `.drv`, `reqTasks` and DICE's `lookup` are four spellings of one
   requirement ([dynamic-deps-distributed]).
6. **A generator is a phase, not a cell** ([gn], [meson]).
7. **Hermeticity is a precondition for reuse; determinism is rarely checked** —
   only Nix makes it structural ([reproducibility]).
8. **Isolation and observation are different features** — a write-only sandbox
   does not validate a read set ([please], [sandboxing-overheads]).
9. **Provenance is an export at the graph seam** ([provenance], [buildkit]).
10. **Mechanized correctness exists for research models, not shipped engines** —
    CloudMake, forward build systems, and Nix's evaluator have completed proofs;
    no production rebuilder or rebuild-minimality proof was found
    ([formal-verification]).

---

## Part 4 — Architectural trade-offs

| Decision                                     | Rationale                                                            | Trade-off                                                                         |
| -------------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Deep constructive traces for cheap cloud     | one lookup on terminal inputs; shallow builds; single round trip     | no early cutoff; determinism becomes a correctness requirement ([nix-thesis])     |
| Restarting over suspending                   | no continuation machinery; the engine re-derives what it needs       | repeated work; affordable only with a memoizing daemon ([bazel])                  |
| Trace dependencies instead of declaring them | complete by construction; no authoring burden                        | 7–46% overhead and silent misses ([perfect-dependencies], [sandboxing-overheads]) |
| Sandbox for isolation, not observation       | the container cost is already paid for reproducibility               | a sandbox is not an input oracle ([please])                                       |
| One cache for AC and CAS                     | one budget, one eviction order, simplest configuration               | eviction order becomes an integrity invariant ([cas-eviction])                    |
| Keep the plan static                         | validation, cycle diagnosis, deterministic presentation come free    | a plan-producing node cannot extend the graph ([drowse], [makenix])               |
| Daemon-resident graph                        | amortizes loading, dep-file reuse, deferred materialization          | lifecycle, expiry, permission boundary, stale state ([daemon-compilers])          |
| mtime as the dirty bit                       | no hashing on the hot path; the filesystem already maintains it      | no early cutoff; copy and restore produce wrong answers ([ninja])                 |
| Generate BUILD files from observation        | no authoring; the graph is what ran                                  | the trace is a bet on the next run ([graph-autogeneration])                       |
| Hash the interface artifact, not the AST     | the compiler already knows what changed; no extractor to keep honest | one more artifact; width and tool identity become API ([semantic-caching])        |

Two patterns in the corpus are not trade-offs but mistakes with a long half-life:
hashing a _declared_ graph rather than the resolved one ([nix-dynamic-derivations]),
and letting a name stand in for content when the two can drift ([drowse]).

---

## Part 5 — The Sparkles delta

The subject is the implemented task DAG, not the planned build graph:
`model.d`, `graph.d`,
`executor.d` and `action.d`. Its spec
states the boundary:

> "Distributed admission across several executor fibers, persistent scheduler
> state and a workflow file format are out of scope."
>
> — `docs/specs/build-primitives/task-dag/SPEC.md`

That sentence is the delta in one line: the engine is **topological × no
rebuilder**, by declaration rather than by accident.

| Capability                | Consensus (Part 3)         | Sparkles today                                                                                                       | Delta                                                                                         |
| ------------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Scheduler                 | topological or suspending  | `stableTopologicalOrder` returns an order or the shortest cycle; the graph is validated first (`graph.d`)            | **none** — the field's cheapest correct choice                                                |
| Rebuilder                 | claims 1, 3                | nothing: no dirty bit, no trace, no key over inputs; every admitted task runs                                        | **the missing half**                                                                          |
| Identity                  | a hash of inputs           | `TaskId` is stable semantic text (`test:sparkles.base:unittest`) and `toHash` hashes that text (`model.d`)           | no content key; the id is a name, not a function of inputs                                    |
| Persistent state          | claims 4, 5                | out of scope; `graph.d` has no serialization                                                                         | no rebuild memory across runs                                                                 |
| Dynamic dependencies      | claim 5                    | `EdgeReason.planning` is the static analogue; the node set is fixed at validation                                    | no graph-extending node; a plan cannot be a node's output                                     |
| Executed vs planned graph | claims 3, PIE's `reqTasks` | `EdgeCondition` (`onSuccess`, `onFailure`, `onCompletion`, `always`) makes the executed path a subset of the planned | a trace must record edges _taken_, not edges declared                                         |
| Store                     | claim 4                    | none; the executor writes into the workspace                                                                         | no CAS, no action cache, no eviction                                                          |
| Sandbox                   | claim 8                    | `SandboxPolicy.taskDirectory` — a private directory for `DUB_HOME`, build root, spilled output                       | isolation by directory, **not** observation; no declared inputs                               |
| Absent probes             | claims 2, 3                | not representable                                                                                                    | a glob that matched nothing is invisible                                                      |
| Determinism               | claim 7                    | not modelled                                                                                                         | load-bearing the moment a cache exists                                                        |
| Provenance                | claim 9                    | `ProcessAction` carries `argv`, `envDelta` (with `redacted`), `cwd`, `timeout`, `sandbox` (`action.d`)               | `redacted` is already `mode=min`; no statement is emitted                                     |
| Distribution              | §2.6                       | out of scope                                                                                                         | none; the REAPI seam is the only closure-preserving option                                    |
| Speculation               | [speculative-execution]    | admission is deterministic and in presentation order; `usage` is an event, not an admission input                    | no duration record or critical-path priority; demand speculation is premature in a static DAG |
| Dependency pruning        | claim 2                    | `workspace/package_graph.d` builds edges from declarations only; nothing compares them with imports                  | over-declared is a real edge; under-declared is invisible                                     |

### What Sparkles already has that the field mostly does not

1. **A reason on every edge.** `EdgeReason` distinguishes `packageDependency`,
   `planning`, `coverageFallback`, `classification`, `reduction`, `publication`,
   `summary` and `cleanup`; a derivation graph records _that_ a dependency exists,
   never why ([nix-cargo-unit]).
2. **An outcome vocabulary with a cause.** `Succeeded`, `Failed`, `Skipped`,
   `Cancelled`, `Blocked` (with `cause`, `root`, `fromFailure`, `provisional`) and
   `Degraded` are more expressive than any surveyed engine's pass/fail/skip.
3. **Deterministic transcripts by construction.** One owner fiber, presentation
   order, no backfilling past a heavy task — and [speculative-execution] notes a
   critical-path priority or predictor is unmeasurable without exactly that baseline.

**Catalog inference:** the cheapest first increment is not a store but a
_definition_ (claim 10) — JFP §3.6's "recompute from the final store and compare" —
which makes the rebuild decision testable as an executable oracle before any cache
exists ([a-la-carte] agrees).

### Where the delta table's rows collide

- **Identity and persistence.** A content key and a stable presentation order are
  two orderings of one node set: `TaskIndex` _is_ a position in presentation order
  and `PresentationKey` sorts by `owner` and `work`, so
  `graph.d` relies on there being one.
- **Rebuilder and distribution.** A rebuild test consulting local state cannot
  dispatch the same action remotely unless that state is the key; §2.6's closure
  requirement binds the rebuilder before the wire.

---

## Part 6 — Open questions

1. **What is the cheapest rebuilder that pays for itself in a one-shot process?**
   Shake's two integers ([shake]) and BitBake's two-level identity ([bitbake]);
   neither is measured on a `dub test` workload.
2. **Can a static DAG accept a plan-producing node without becoming a different
   scheduler?** [drowse], [makenix] and [dgd] make the plan a store barrier;
   node kind or scheduler change is unresolved.
3. **Do the task DAG and the planned build graph become two caches?** The
   build graph spec (`docs/specs/build-primitives/build-graph/SPEC.md`)
   keys actions by content; the task DAG would key tasks by something else, and
   Boba warns two caches without a shared key disagree about dirtiness ([boba]).
4. **Can the D toolchain emit a depfile cheaply enough to replace declaration?**
   `dmd`/`ldc` dependency dumps exist; nothing here measures their cost.
5. **What is the sandbox overhead for a D compile step?** Nothing published:
   BuildXL's 1–5% is Windows process creation, Rattle's 7% a fixed command list.
6. **Should `TaskId` become a function of inputs, and what breaks?** The answer
   decides whether a cache is reachable at all (see the collision above).
7. **Eviction by reachability or by recency?** [cas-eviction] argues an explicit
   DAG is an eviction oracle the surveyed servers lack — unmeasured against LRU.
8. **Is a link-shaped attestation enough?** Whether ordering edges can stand in
   for `resolvedDependencies` is open ([provenance]).
9. **Which theme gap is load-bearing for `dub`?** The corpus ranks nothing;
   [semantic-caching] and [link-time-pruning] change what a task _is_.
10. **Does the consensus survive a single-language, single-machine toolchain?**
    The pages addressing a small toolchain ([buildxl], [sandboxing-overheads])
    recommend the declare-only column.

---

## Page status relied on

Every page the capstone reads, with the status its catalog row reports.

| Page                                                  | Group       | Status     | Taken from it                                             |
| ----------------------------------------------------- | ----------- | ---------- | --------------------------------------------------------- |
| [Build Systems à la Carte][a-la-carte]                | Foundations | `reviewed` | the grid, minimality, early cutoff, Cloud Shake           |
| [PIE][pie]                                            | Foundations | `reviewed` | the off-grid change-driven scheduler, `reqTasks`          |
| [Build maintenance][build-maintenance]                | Foundations | `reviewed` | authoring cost as a design output                         |
| [Perfect Dependencies][perfect-dependencies]          | Foundations | `reviewed` | traced deps, overhead numbers, the hazard set             |
| [Nix thesis][nix-thesis]                              | Foundations | `reviewed` | deep constructive traces, the closure invariant           |
| [BuildXL][buildxl]                                    | Engine      | `reviewed` | fingerprint arithmetic, absent probes, 1–5%               |
| [Bazel][bazel]                                        | Engine      | `reviewed` | restarting, "correct and perfect incrementality"          |
| [Buck2][buck2]                                        | Engine      | `reviewed` | DICE's unconditional soundness, the certificate           |
| [build2][build2]                                      | Engine      | `reviewed` | `depdb`, tool checksums, the result lattice               |
| [Please][please]                                      | Engine      | `reviewed` | four-part hash split, `Unchanged`, sandbox limits         |
| [Ninja][ninja]                                        | Engine      | `reviewed` | build log, `restat`, `dyndep`, `missingdeps`              |
| [GNU Make][gnumake]                                   | Engine      | `reviewed` | dirty bit, jobserver, re-exec                             |
| [redo][redo]                                          | Engine      | `reviewed` | two-phase dependency replacement, negative deps           |
| [tup][tup]                                            | Engine      | `reviewed` | observed edges, change frontier, output gate              |
| [Shake][shake]                                        | Engine      | `reviewed` | two timestamps, journal, oracles, lint                    |
| [Rattle][rattle]                                      | Engine      | `reviewed` | the forward model, `pending`, `createEdge`                |
| [Earthly][earthly]                                    | Engine      | `reviewed` | recipe→LLB lowering, auto-skip tiers                      |
| [GN][gn]                                              | Engine      | `reviewed` | generator phase, visibility as an allowlist               |
| [Meson][meson]                                        | Engine      | `reviewed` | regeneration edge, introspection split                    |
| [Boba][boba]                                          | Engine      | `reviewed` | no standalone repo; two caches can disagree               |
| [Pants][pants]                                        | Engine      | `reviewed` | generation counters, per-edge dependency records          |
| [Moon][moon]                                          | Engine      | `reviewed` | edge contribution policy, hash-collapse warning           |
| [BitBake][bitbake]                                    | Engine      | `reviewed` | `siggen` handlers, `setscene`, `hashserv`, worker sandbox |
| [sbt][sbt]                                            | Engine      | `reviewed` | suspension in a topological engine, wrapper cache         |
| [BuildKit][buildkit]                                  | Engine      | `reviewed` | `CacheMap`, two key levels, provenance at the seam        |
| [Nix dynamic derivations][nix-dynamic-derivations]    | Nix         | `reviewed` | the open key set; resolved-graph hashing                  |
| [nixception][nixception]                              | Nix         | `reviewed` | canonical action as key; stable over precise              |
| [nix-ninja][nix-ninja]                                | Nix         | `reviewed` | lowering vs execution; order from key resolution          |
| [sandstone][sandstone]                                | Nix         | `reviewed` | narrowest-artifact edges; depfile as a node               |
| [drowse][drowse]                                      | Nix         | `reviewed` | plan as a node; the barrier cost                          |
| [dgd][dgd]                                            | Nix         | `reviewed` | plan as a task output; narrow inputs                      |
| [nixgg][nixgg]                                        | Nix         | `reviewed` | one canonical action; scanner is part of the key          |
| [nix-cargo-unit][nix-cargo-unit]                      | Nix         | `reviewed` | granularity vs keying; reasons Nix cannot hold            |
| [MakeNix][makenix]                                    | Nix         | `reviewed` | plan as a cacheable task; declared-input bounds           |
| [Sandboxing overheads][sandboxing-overheads]          | Theme       | `reviewed` | published numbers, isolation vs observation               |
| [Dynamic deps, distributed][dynamic-deps-distributed] | Theme       | `reviewed` | the closure requirement, termination table                |
| [Dependency pruning][dependency-pruning]              | Theme       | `reviewed` | strictness vs audit, the per-system table                 |
| [Graph auto-generation][graph-autogeneration]         | Theme       | `reviewed` | trace as checker, the fixpoint hazard                     |
| [Semantic caching][semantic-caching]                  | Theme       | `reviewed` | interface artifacts, under-approximation                  |
| [Daemon compilers][daemon-compilers]                  | Theme       | `reviewed` | resident state must be named in the key                   |
| [Link-time pruning][link-time-pruning]                | Theme       | `reviewed` | the link as the coarsest task                             |
| [Compile-time execution][compile-time-execution]      | Theme       | `reviewed` | hermeticity holes per ecosystem                           |
| [CAS eviction][cas-eviction]                          | Theme       | `reviewed` | two budgets, touch ordering, watermarks                   |
| [Cross-language DAGs][cross-language-dags]            | Theme       | `reviewed` | manual glue at generator boundaries                       |
| [Speculative execution][speculative-execution]        | Theme       | `reviewed` | shipped vs research; the baseline need                    |
| [Formal verification][formal-verification]            | Theme       | `reviewed` | the assumption ledger, what is proved                     |
| [Reproducibility][reproducibility]                    | Theme       | `reviewed` | determinism as premise vs obligation                      |
| [Provenance][provenance]                              | Theme       | `reviewed` | the DSSE/ITE-6 stack, who actually emits                  |

---

## Sources

- [Build Systems à la Carte][concepts] (JFP 2020) via [concepts], for the grid and
  its vocabulary; the paper's DOI is [JFP][jfp].
- The 34 system and 14 theme deep-dives listed above, each carrying its own pinned
  citations. This page adds no clone; it re-opened four files to quote them
  exactly — Ninja's manual at `a7d7504`, Bazel's Skyframe doc at `2105aec`, Buck2's
  DICE document at `08b403b`, BuildXL's sandboxing spec at `ea34998`
  ([`restat`][ninja-restat], [skyframe][bazel-skyframe],
  [incrementality][dice-doc], [sandboxing][bxl-sandboxing]).
- Sparkles source at the paths above; the quoted boundary sentence is from
  `docs/specs/build-primitives/task-dag/SPEC.md`.

<!-- References -->

[jfp]: https://doi.org/10.1017/S0956796820000088
[index]: ./index.md
[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[pie]: ./pie.md
[build-maintenance]: ./build-maintenance.md
[perfect-dependencies]: ./perfect-dependencies.md
[nix-thesis]: ./nix-thesis.md
[buildxl]: ./buildxl.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[build2]: ./build2.md
[please]: ./please.md
[ninja]: ./ninja.md
[gnumake]: ./gnumake.md
[redo]: ./redo.md
[tup]: ./tup.md
[shake]: ./shake.md
[rattle]: ./rattle.md
[earthly]: ./earthly.md
[gn]: ./gn.md
[meson]: ./meson.md
[boba]: ./boba.md
[pants]: ./pants.md
[moon]: ./moon.md
[bitbake]: ./bitbake.md
[sbt]: ./sbt.md
[buildkit]: ./buildkit.md
[nixception]: ./nixception.md
[nix-ninja]: ./nix-ninja.md
[sandstone]: ./sandstone.md
[drowse]: ./drowse.md
[dgd]: ./dgd.md
[nixgg]: ./nixgg.md
[nix-cargo-unit]: ./nix-cargo-unit.md
[makenix]: ./makenix.md
[nix-dynamic-derivations]: ./nix-dynamic-derivations.md
[sandboxing-overheads]: ./sandboxing-overheads.md
[dynamic-deps-distributed]: ./dynamic-deps-distributed.md
[dependency-pruning]: ./dependency-pruning.md
[graph-autogeneration]: ./graph-autogeneration.md
[semantic-caching]: ./semantic-caching.md
[daemon-compilers]: ./daemon-compilers.md
[link-time-pruning]: ./link-time-pruning.md
[compile-time-execution]: ./compile-time-execution.md
[cas-eviction]: ./cas-eviction.md
[cross-language-dags]: ./cross-language-dags.md
[speculative-execution]: ./speculative-execution.md
[formal-verification]: ./formal-verification.md
[reproducibility]: ./reproducibility.md
[provenance]: ./provenance.md
[ninja-restat]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/doc/manual.asciidoc
[bazel-skyframe]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/reference/skyframe.mdx
[dice-doc]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/dice/docs/incrementality.md
[bxl-sandboxing]: https://github.com/microsoft/BuildXL/blob/ea34998661867b5959d7f496f8b5650611a3e446/Documentation/Specs/Sandboxing.md
