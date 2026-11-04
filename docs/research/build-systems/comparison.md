# Build Systems: Comparison

Build engines avoid repeated work by tracking dependencies and retaining enough
evidence to reuse previous results. They differ in when dependencies become
known, what counts as an unchanged result, and which parts of execution they
control. A cache, a dependency evaluator, and a process sandbox answer different
questions even when they belong to one product.

This comparison relates the surveyed mechanisms to the scheduler × rebuilder
model in [concepts]. Its findings are bounded by the pinned sources in the
deep-dives; they do not establish a universal architecture or rank whole products.
Part 1 maps the model to implementation layers. Part 2 compares scheduling,
rebuilding, dependency discovery, storage, hermeticity and distribution.
Part 3 records findings and counterexamples, and Part 4 explains
trade-offs. Part 5 identifies experiments that could strengthen the evidence.

> [!NOTE]
> System claims cite deep-dives and their primary sources. Cross-system
> deductions are marked **Catalog inference**. The [research method][method]
> distinguishes source evidence from observed behavior and explains the limits
> of the inherited `reviewed` label.

| Field           | Value                                                                                                    |
| --------------- | -------------------------------------------------------------------------------------------------------- |
| Page type       | Synthesis (capstone)                                                                                     |
| Covers          | 5 foundations, 20 industry rows, 9 Nix projects, 14 themes                                               |
| Grid vocabulary | [concepts] §2–§5, from JFP 2020                                                                          |
| Evidence scope  | Pinned deep-dives and their source statements; model deductions and catalog inferences are distinguished |

**Last reviewed:** November 4, 2026 (synthesis and internal consistency; upstream revisions unchanged)

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

**Sixteen** rows have a nearest grid placement, **one** is
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

These projects primarily generate or lower work into Nix. Their planning logic
can differ even when execution uses the same store and scheduler. The table
identifies that contribution rather than counting each front end as an
independent engine.

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

Dynamic derivations allow derivations produced during realization to extend the
work to be realized ([nix-dynamic-derivations]). This changes when the key set
becomes known; it does not introduce another scheduler coordinate in the paper's
grid. The front ends explore how to express work through that boundary.

### 1.3 What the grid cannot express

Four absences, each a gap in the vocabulary rather than a misclassification:

1. **Change-driven cancellation** — PIE needs a changed-file set as an argument
   ([pie]); a file-watch scheduler has no cell ([concepts] §7, from JFP §8.9).
2. **Forward builds** — Rattle runs the command and reconstructs edges after
   ([perfect-dependencies]); `Build` has nowhere to put that graph.
3. **Generator phases** — GN and Meson build a description, then build from it
   ([gn], [meson]); the grid starts after that phase.
4. **Eviction policy and provenance** — neither is a grid coordinate. The paper
   discusses eviction and hash passthrough, but does not specify an eviction
   policy or an attestation scheme ([concepts] §6).

### 1.4 Classify the layer before the product

The summary grid identifies a nearest theoretical analogue. It does not assert
that every layer in a product uses that mechanism.

| Product / layer          | Mechanism                                             | Model correspondence and boundary                                                                                           |
| ------------------------ | ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Bazel / Skyframe         | restarting dependency evaluation                      | Ordering and reuse of graph values; external actions still need complete inputs ([Bazel rebuilding][bazel-rebuilding])      |
| Buck2 / DICE             | suspending computes, revision certificates            | Verifying analogue with concurrent branches; the core state does not execute actions ([Buck2 mechanics][buck2-mechanics])   |
| Buck2 / action cache     | action digest and retained artifacts                  | Constructive layer alongside DICE, rather than evidence that DICE itself stores action results ([Buck2 store][buck2-store]) |
| Ninja / executor         | ready graph, timestamp checks, command hash, `restat` | Qualified verifying analogue; content equality is not implied ([Ninja mechanics][ninja-mechanics])                          |
| Earthly / BuildKit       | recipe lowering into LLB and snapshot reuse           | Inherited execution machinery; the two rows are not independent corroboration ([Earthly][earthly], [BuildKit][buildkit])    |
| GN or Meson / generation | emits a build description                             | A preceding phase; Ninja's execution guarantees do not establish generator correctness ([GN][gn], [Meson][meson])           |

---

## Part 2 — Per-dimension comparison

### 2.1 Task model & scheduling

| Question                 | Mechanisms represented                                                         | Exemplars                                                         |
| ------------------------ | ------------------------------------------------------------------------------ | ----------------------------------------------------------------- |
| Static or dynamic graph? | Fixed execution graphs and dependencies requested during evaluation both occur | [Make][gnumake], [Ninja][ninja] vs [Shake][shake], [Buck2][buck2] |
| Which scheduler?         | Topological, restarting and suspending mechanisms serve different task models  | [Concepts §2][schedulers], [Bazel][bazel], [Shake][shake]         |
| Parallelism budget       | Pools constrain selected work; a jobserver shares tokens with child builds     | [Ninja][ninja], [Make][gnumake]                                   |
| Conditional edges        | Dependencies consumed can depend on values obtained during evaluation          | [Pants][pants], [Shake][shake]                                    |

### 2.2 Rebuilding & correctness

| Rebuilder           | Early cutoff                                     | Dynamic deps | Representative state (not total cost)                                                                   |
| ------------------- | ------------------------------------------------ | ------------ | ------------------------------------------------------------------------------------------------------- |
| Dirty bit           | no in base model; implementations can add cutoff | over-approx  | one field or one mtime ([gnumake], [tup])                                                               |
| Verifying traces    | yes                                              | yes          | result and dependency identities; step variants use timestamps and dependency records ([shake], [redo]) |
| Constructive traces | yes                                              | yes          | result value + dependency hashes ([bazel])                                                              |
| Deep constructive   | **no**                                           | yes          | one hash over terminal inputs ([nix-thesis])                                                            |

Early cutoff depends on the unchanged-result signal. Shake's step traces use
`built` and `changed` alongside dependency records and result comparison; the two
integers are not the total verification or persistence cost ([shake]); BitBake reaches it through a
second, output-derived identity when paired with OpenEmbedded's hash-equivalence
handler and `bb.hashserv` ([bitbake]); Please through an `Unchanged` outcome
([please]). Nix's deep constructive cell buys cloud capability and
single-round-trip lookups by giving that cutoff up ([nix-thesis]).

The [behavioral suite][behavioral-evidence] also observes GNU Make skipping a
consumer when its generator preserves the output timestamp. Tup's `^o` explicitly
compares outputs. Neither observation is captured by an unqualified statement
that every implementation in the dirty-bit row lacks early cutoff.

Correctness claims concern different objects. An unconditional statement about a
core data structure does not imply unconditional correctness of external builds.

| Claim / object                    | Property                                                      | Assumptions and exclusions                                                                            | Evidence                                                                            |
| --------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Skyframe graph evaluation         | Correct incremental results when function inputs are recorded | Dependency completeness; does not validate arbitrary process reads                                    | Upstream design claim, [Skyframe][bazel-skyframe]; [analysis][bazel-rebuilding]     |
| DICE core state                   | Returned revisions are justified by the operation history     | Unconditional at this interface; the core does not execute computes or validate reported dependencies | Stated theorem and algorithm, [DICE §§1, 3][dice-doc]; [mechanics][buck2-mechanics] |
| DICE execution environment        | From-scratch consistency                                      | Functional certificates, honest traces and complete change reporting                                  | Conditional argument, [DICE §3.4][dice-doc]; [analysis][buck2-rebuilding]           |
| Nix dynamic-derivation resolution | Missing realisations leave `tryResolve` unresolved            | Local fail-closed behavior, not a whole-engine correctness proof                                      | Inspected implementation, [dynamic derivations][nix-dynamic-derivations]            |
| PIE incremental execution         | Consistency and partial optimality                            | Task/resource contracts; partial optimality differs from JFP minimality                               | Paper argument, [PIE correctness][pie-correctness]                                  |

[Formal verification][formal-verification] separately identifies machine-checked
models and their external-execution assumptions. A source inspection or a design
argument is not a mechanized proof of the implementation.

### 2.3 Dependency discovery

| Family           | Mechanism                                        | Where it is the primary answer                                                      |
| ---------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------- |
| Declared         | the description names inputs and outputs         | [Bazel][bazel], [Buck2][buck2], [Please][please], [Pants][pants], [Nix][nix-thesis] |
| Compiler-emitted | depfile written by the tool                      | [Ninja][ninja] `.ninja_deps`, [build2][build2] `depdb`, [Meson][meson]              |
| Traced           | syscalls via `ptrace`, FUSE, eBPF, interposition | [tup][tup], [Rattle][rattle], [BuildXL][buildxl]                                    |
| Hybrid           | declared edges plus observed validation          | [BitBake][bitbake] `[file-checksums]`, [BuildXL][buildxl] fingerprints              |

Compiler-emitted dependencies reuse the compiler's knowledge, but this corpus
does not measure their marginal emission cost. Observation serves runtime
discovery in Rattle and tup and declaration validation in BuildXL. Using it only
as an audit is an application choice ([graph-autogeneration]). Rattle's overhead
belongs to its measured workloads, not to all tracers ([sandboxing-overheads]).
A failed file probe or empty glob can affect output; detecting a later appearance
requires representing that observation or conservative invalidation ([buildxl],
[bitbake]).

### 2.4 Store & caching

| Concern               | Observed mechanism or constraint                                                          | Page               |
| --------------------- | ----------------------------------------------------------------------------------------- | ------------------ |
| Two tiers             | action key → result and blob → bytes; shared or separate storage must preserve references | [cas-eviction]     |
| Ordering              | touch the action entry before its blobs, or check presence on read                        | [cas-eviction]     |
| Key composition       | config, rule, sources, secrets — named separately so a miss is diagnosable                | [please]           |
| Content over identity | key on what the consumer's tool reads, not the producer's whole output                    | [semantic-caching] |
| Eviction              | watermarks, sweeps and bounded caches trade enforcement precision against write-path cost | [cas-eviction]     |

The deepest divergence is about _what a key is for_. Nix keys on terminal inputs
so a target is current without materialising anything between it and the sources —
a shallow build ([nix-thesis]); Bazel keys on the action and its declared inputs so
every intermediate is reusable and early cutoff works ([bazel]). Both are correct,
and [cas-eviction]'s "shallow builds and hash passthrough" is the only place the
corpus reconciles them.

### 2.5 Hermeticity & provenance

| System   | Determinism is                      | Sandbox mechanism                                                      | Attestation shipped                                          |
| -------- | ----------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------ |
| Nix      | an assumption behind input identity | namespaces and restricted store view when sandboxing is enabled        | signatures on the object                                     |
| Bazel    | an author obligation                | strategy dependent; `sandboxfs` removed in 7.0.0                       | execution metadata; no attestation identified in cited paths |
| Buck2    | the environment's obligation        | local-only actions lack filesystem isolation; RE has an input boundary | no attestation identified in cited paths                     |
| BuildKit | a mode of the exporter              | container per step                                                     | **provenance as a product**                                  |
| BitBake  | a property of the recipe            | network namespace + Landlock; no fs sandbox                            | no attestation identified in cited paths                     |
| BuildXL  | an assumption                       | Detours (Windows); Linux interposition and tracing paths               | no attestation identified in cited paths                     |

The cited accounts use different baselines and are not comparable:
BuildXL's "1-5% of time overhead to running a process" on Windows
([`Documentation/Specs/Sandboxing.md`][bxl-sandboxing]), Rattle's 7% Linux / 46%
Windows over a fixed command list ([perfect-dependencies] §5.2), and Bazel's
qualitative `sandboxfs` account — "setup costs are lower, but you have to pay a
penalty for the use of each input" — before its 7.0.0 removal
([sandboxing-overheads]). An absent measurement is an evidence gap, not evidence of zero cost.

The surveyed detection mechanisms differ: Nix exposes `--check`, Bazel documents
a comparison procedure, and DICE leaves external-compute determinism to its
environment. BuildKit's exporter options control selected sources of variation.
Nix's environment control narrows nondeterminism without eliminating it
([reproducibility]). In the provenance paths examined, BuildKit emits attestations,
REAPI carries execution metadata, and Nix signs store objects. These observations
do not exclude integrations outside the inspected paths ([provenance]).

### 2.6 Distribution

| Question                        | Answer the corpus supports                                                                    |
| ------------------------------- | --------------------------------------------------------------------------------------------- |
| Wire protocol                   | REAPI: Bazel, Buck2, Please, Pants, moon's cache client, nixception                           |
| What crosses the seam           | an input root and a command — **not a graph** ([dynamic-deps-distributed])                    |
| Dynamic deps + remote execution | each action needs its input closure at dispatch; a published plan is one approach             |
| Daemon state                    | amortizes work; state affecting results needs an explicit reuse contract ([daemon-compilers]) |

An REAPI action is closed: the server receives a `Command` and a `Directory` tree.
Inputs needed by that dispatched action must already be available as content.
Nix publishes derivations and Ninja patches a local manifest with `dyndep`; these
are different coordination mechanisms ([dynamic-deps-distributed]).
**Catalog inference:** a cacheable plan can make discovery reusable. The action
boundary does not require every coordinator to persist its entire graph.

---

## Part 3 — Findings, assumptions and counterexamples

These findings describe the inspected corpus. A theoretical guarantee, a common
mechanism and an application recommendation have different evidential weight.
The [research method][method] defines the evidence labels; related front ends
do not count as independent confirmations of their inherited engine.

| Finding                                                               | Supporting evidence                                                                                    | Counterexamples or limits                                                                         | Assumptions and scope                                                                | Assessment                                                      |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------------------------- |
| Content checks distinguish edits that timestamps cannot               | [Ninja rebuilding][ninja-rebuilding], [reproducibility][reproducibility]                               | Make and tup deliberately retain timestamp-based checks                                           | Correctly captured inputs; hashing and metadata costs are workload dependent         | Mechanism distinction; no universal speed claim                 |
| Dependency reporting and observation are alternative sources of edges | [Ninja depfiles][ninja-discovery], [Rattle tracing][rattle], [tup][tup]                                | Rattle and tup use observation in the build path; tracing is not only an audit                    | Compiler reports and tracers each have coverage limits                               | Source-supported diversity; no universal winner                 |
| Early cutoff needs an unchanged-result signal                         | [Shake][shake], [Please][please], [Ninja restat][ninja-restat-section]                                 | tup adds opt-in `^o` to dirty-bit propagation; deep constructive traces omit intermediate results | Equality may mean bytes, an mtime proxy or a revision; these are not interchangeable | Model property with implementation qualifications               |
| Cache results and their bytes have distinct lifetimes                 | [CAS eviction][cas-integrity]                                                                          | Shared storage and separate AC/CAS budgets both occur                                             | A returned result needs retrievable outputs, or a safe miss/recompute path           | Integrity constraint; storage layout remains a choice           |
| Dynamic evaluation requires a way to obtain late dependencies         | [Schedulers][schedulers], [Ninja dyndep][ninja-dyndep], [dynamic derivations][nix-dynamic-derivations] | Restarting can re-evaluate; suspension is not the only solution                                   | A closed remote action needs inputs at dispatch; a persistent plan is one design     | Model and protocol constraints, with multiple implementations   |
| Generation and execution are separate analysis layers                 | [GN][gn], [Meson][meson], [Earthly][earthly]                                                           | A product can host both phases; one cell cannot describe every layer                              | State which phase a classification describes                                         | Classification convention                                       |
| Environment control reduces variance but does not prove determinism   | [Reproducibility][repro-detection]                                                                     | Nix offers `--check`; tools can still use entropy or vary with execution order                    | Repeated comparisons cover only the variations exercised                             | Source-supported limitation; detection coverage remains partial |
| Isolation does not by itself discover reads                           | [Sandbox mechanisms][sandbox-mechanisms], [Buck2 discovery][buck2-discovery]                           | BuildXL combines enforcement and observation                                                      | Platform, executor and configuration must be named                                   | Mechanism distinction                                           |
| Attestation is a separate product capability                          | [Provenance][provenance], [BuildKit][buildkit]                                                         | Nix object signatures and REAPI metadata establish different facts                                | Search limited to cited implementations and integrations                             | Bounded observation, not an exhaustive absence claim            |
| Proofs establish properties of their named models                     | [Formal verification][formal-verification]                                                             | CloudMake models execution axiomatically; Nix-language proofs concern evaluators                  | External tools, reporting and termination have their own assumptions                 | Evidence of model properties; no implementation proof inferred  |

**Catalog inference:** the corpus supports choosing mechanisms by workload and
failure model. It does not establish that a small local executor needs the same
cache, sandbox, daemon or distribution architecture as a remote build service.

---

## Part 4 — Architectural trade-offs

| Decision                                     | Rationale                                                            | Trade-off                                                                                                           |
| -------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Deep constructive traces for cheap cloud     | one lookup on terminal inputs; shallow builds; single round trip     | no early cutoff; determinism becomes a correctness requirement ([nix-thesis])                                       |
| Restarting over suspending                   | no continuation machinery; the engine re-derives what it needs       | repeated work; cost depends on repeated work and memoization ([bazel])                                              |
| Trace dependencies instead of declaring them | observes accesses on the executed path; reduces declaration work     | workload-dependent overhead; coverage gaps can cause silent misses ([perfect-dependencies], [sandboxing-overheads]) |
| Sandbox for isolation, not observation       | the container cost is already paid for reproducibility               | a sandbox is not an input oracle ([please])                                                                         |
| One cache for AC and CAS                     | one budget, one eviction order, simplest configuration               | eviction order becomes an integrity invariant ([cas-eviction])                                                      |
| Keep the plan static                         | validation, cycle diagnosis, deterministic presentation come free    | a plan-producing node cannot extend the graph ([drowse], [makenix])                                                 |
| Daemon-resident graph                        | amortizes loading, dep-file reuse, deferred materialization          | lifecycle, expiry, permission boundary, stale state ([daemon-compilers])                                            |
| mtime as the dirty bit                       | no hashing on the hot path; the filesystem already maintains it      | requires a separate cutoff signal; preserved mtimes can hide content changes ([ninja])                              |
| Generate BUILD files from observation        | no authoring; the graph is what ran                                  | the trace is a bet on the next run ([graph-autogeneration])                                                         |
| Hash the interface artifact, not the AST     | the compiler already knows what changed; no extractor to keep honest | one more artifact; width and tool identity become API ([semantic-caching])                                          |

Two patterns in the corpus are not trade-offs but mistakes with a long half-life:
hashing a _declared_ graph rather than the resolved one ([nix-dynamic-derivations]),
and letting a name stand in for content when the two can drift ([drowse]).

---

## Part 5 — Research gaps and experiments

The [behavioral evidence][behavioral-evidence] separates model predictions from
observed engine behavior. It is a small scenario suite, not a performance ranking.
The following protocols address remaining cross-system questions. Application
priorities belong to a separate design analysis.

| Question                                              | Hypothesis and minimal experiment                                                                            | Measurements and confounders                                                                           | Result that changes the finding                                                                |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| When does hashing repay its cost?                     | Compare timestamp, content and step-trace checks on one edit sequence with identical tasks                   | Scan, hash, metadata I/O, avoided execution and no-op latency; separate warm OS cache from cold state  | Cheap tasks or large inputs make verification slower than rerunning; narrow the workload scope |
| Does observation find dependencies declarations miss? | Run a command with generated inputs, a failed probe and directory enumeration under each available mechanism | Detected reads and stale outputs against a clean execution; record platform and static/dynamic linking | A missed access falsifies completeness for that configuration                                  |
| Must discovery produce a persistent plan?             | Compare an in-memory coordinator with a serialized plan before dispatching the same closed actions           | Planning work, restart recovery and action keys; keep input closure identical                          | Equal correctness without plan persistence rules out a protocol-level necessity                |
| How should a cache survive eviction?                  | Delete selected output blobs while retaining result metadata, then request the target                        | Missing-blob detection, restoration, execution, bytes transferred; separate AC and CAS lifetimes       | A successful result naming unavailable bytes falsifies the completeness check                  |
| What does a correctness claim cover?                  | Reproduce a documented invariant with a deliberately incomplete dependency report                            | Graph-value correctness and external-artifact correctness separately                                   | A justified graph revision with stale process output demonstrates the layer boundary           |

No experiment here establishes a universal cost threshold. Report tool revision,
configuration, input sizes, edit history, expected executions and observed
executions alongside a clean-build artifact comparison.

---

## Evidence coverage

The [index] inventories five foundations, twenty industry rows, nine Nix
subjects and fourteen themes. Each deep-dive carries its source pins and
qualifications. This comparison audits their synthesis without advancing those
pins or claiming executable validation of every row.

The [method] distinguishes source statements, inspected mechanisms, model
deductions, executable observations and catalog inferences. The historical
`reviewed` labels establish coverage of the source-review process, not a
uniform level of assurance. [Behavioral evidence][behavioral-evidence] supplies
a separate, explicitly scoped record of observed executions.

## Sources

- [Build Systems à la Carte][concepts] (JFP 2020) via [concepts], for the grid and
  its vocabulary; the paper's DOI is [JFP][jfp].
- The 34 system and 14 theme deep-dives listed above, each carrying its own pinned
  citations. This page adds no clone; it re-opened four files to quote them
  exactly — Ninja's manual at `a7d7504`, Bazel's Skyframe doc at `2105aec`, Buck2's
  DICE document at `08b403b`, BuildXL's sandboxing spec at `ea34998`
  ([`restat`][ninja-restat], [skyframe][bazel-skyframe],
  [incrementality][dice-doc], [sandboxing][bxl-sandboxing]).

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
[method]: ./method.md
[behavioral-evidence]: ./behavioral-evidence.md
[schedulers]: ./concepts.md#_2-schedulers
[bazel-rebuilding]: ./bazel.md#_2-rebuilding-correctness
[buck2-mechanics]: ./buck2.md#how-it-works
[buck2-rebuilding]: ./buck2.md#_2-rebuilding-correctness
[buck2-discovery]: ./buck2.md#_3-dependency-discovery
[buck2-store]: ./buck2.md#_4-store-caching
[ninja-mechanics]: ./ninja.md#how-it-works
[ninja-rebuilding]: ./ninja.md#_2-rebuilding-correctness
[ninja-discovery]: ./ninja.md#_3-dependency-discovery
[ninja-restat-section]: ./ninja.md#restat-an-mtime-proxy-for-early-cutoff
[ninja-dyndep]: ./ninja.md#dyndep-the-graph-patched-mid-build
[pie-correctness]: ./pie.md#correctness-and-optimality-as-argued
[cas-integrity]: ./cas-eviction.md#correctness-risks
[repro-detection]: ./reproducibility.md#detection-as-documented
[sandbox-mechanisms]: ./sandboxing-overheads.md#how-it-works-—-the-mechanism-families
