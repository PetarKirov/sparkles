# Build Systems: Application to Sparkles

Build-system research can guide two different decisions in Sparkles: how to
orchestrate repository checks, and whether to build an incremental engine for
D compilation. The first needs dependable ordering, isolation, and reporting.
The second also needs a definition of reusable results and complete inputs.
Capabilities useful to one are not automatically requirements for the other.

This page connects the [research comparison][comparison] to those decisions.
It separates the task-DAG branch implementation from its execution contract
and from experiments that could justify extending it. A task DAG is a directed
acyclic graph of work and ordering constraints; its branch-specific specification
is identified in §1. This page does not select a cache protocol, promise a build
engine, or amend that specification.
The baseline below establishes what can be relied on; the investigation plan
identifies what evidence is still needed.

**Last reviewed:** November 4, 2026

## 1. Baseline and evidence boundary

The research is published independently of the task-DAG implementation.
Its application baseline is the separate `feat/task-dag` branch, inspected
at commit `8c39474f2f9e5f0ecf1e0095c4de9b87c528d704`. The Git locators below
identify local source objects; they do not assume the branch is published.
For example, a repository containing that commit can retrieve its model with:

```bash
git show 8c39474f2f9e5f0ecf1e0095c4de9b87c528d704:libs/build-primitives/src/sparkles/build_primitives/task/model.d
```

For the branch evidence below, `task/` expands to
`libs/build-primitives/src/sparkles/build_primitives/task/` at that commit.
The task-DAG specification and delivery plan are
`docs/specs/build-primitives/task-dag/{SPEC,PLAN}.md` in the same Git tree.
These locators remain separate from the clickable sources available in the
standalone research checkout.

| Subject            | Evidence inspected                            | What it establishes                                                                                                          |
| ------------------ | --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Recipe vocabulary  | [`dub_manifest.d`][manifest]                  | Shared types describe declared DUB settings; effective settings belong to `dub describe`                                     |
| Recipe lookup      | [`dub_recipe.d`][recipe]                      | SDL, JSON, and single-file recipes expose package names, configurations, and subpackages                                     |
| Repository inputs  | [`glob_walk.d`][glob], [`git_env.d`][git-env] | File selection and a scrubbed Git child environment are available primitives                                                 |
| Task vocabulary    | `task/model.d` and `task/action.d`            | Stable semantic task ids, separate presentation keys, conditional edges, typed outcomes, and process actions exist in source |
| Graph and executor | `task/graph.d` and `task/executor.d`          | Graph validation and stable ordering are separate from weighted admission and action execution                               |
| Task-DAG contract  | Task-DAG `SPEC.md`, Introduction              | The execution contract excludes persistent scheduler state and distributed admission                                         |
| Delivery boundary  | Task-DAG `PLAN.md`                            | A specification is not evidence that every associated build-graph capability has been delivered                              |

The application analysis is conditional on that pinned branch baseline.
The source inspection establishes the structures described here; it does not
rerun the branch's acceptance suite or establish delivery of a content-addressed
build engine.

The available recipe types are not a resolved build graph. In particular,
the [recipe module's contract][recipe] leaves effective import paths,
versions, and compiler flags to `dub describe`. Hashing the recipe text alone
would not establish complete action identity.

## 2. Orchestration and build reuse

The task-DAG specification's Introduction separates task execution from the
consumer's build graph and excludes persistent scheduler state. This is
a scope choice. A scheduler that runs requested checks does not need to own
the compiler's incremental cache to provide useful orchestration. Planned
build-store behavior is a separate contract; its specification is not evidence
that the task executor already implements a rebuilder.

| Concern          | Specified behavior                                                                                              | Research implication                                                                         |
| ---------------- | --------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Logical identity | `TaskId` names semantic work; `PresentationKey` orders output (`model.d`)                                       | Keep user-facing identity distinct from cache validity                                       |
| Conditional work | Edges carry success, failure, completion, or unconditional conditions (`model.d`)                               | A future reuse mechanism needs a defined meaning for branches and failures                   |
| Outcomes         | Success, failure, skip, cancellation, blocking, and degradation are modeled (`model.d`)                         | Reusing a process exit code alone may discard relevant orchestration semantics               |
| Reporting        | The task contract requires deterministic buffered replay and summaries (§6–§7)                                  | Preserve reporting behavior independently of any cache lookup order                          |
| Isolation        | `SandboxPolicy.taskDirectory` names private DUB homes, build roots, output, and coverage locations (`action.d`) | Directory separation addresses write collisions; it does not establish read-set completeness |
| Persistence      | Persistent scheduler state is outside the task contract's scope (Introduction)                                  | Reusing dependency sources differs from reusing task results                                 |

These are design properties to validate against the specification's
acceptance criteria. The survey does not establish that they are unique to
Sparkles, or that richer outcome types alone make an engine more correct.

An orchestration edge does not necessarily identify an input artifact.
Cleanup ordering and failure fallback are control dependencies in the
specified edge model (`SPEC.md` §3.2). A future cache trace or provenance
statement needs to distinguish those edges from the data actually consumed;
recording every declared edge, or only every taken edge, is insufficient
without that distinction.

### Logical identity and reusable results

**Candidate design:** retain stable `TaskId` values and introduce a separate
action key only for work whose reuse contract is defined. A logical task such
as a package test remains recognizable when its inputs change; an action key
changes when a relevant input, tool, or execution setting changes. Output
digests describe resulting bytes. These identities serve different purposes,
as the [concepts page][concepts] explains.

There is no demonstrated requirement to replace `TaskId` with a content hash.
The model in `task/model.d` already separates task identity from presentation order.
A prototype needs to test whether one logical task can map to several
action keys across configurations while retaining stable reports. That is an
interface question, not evidence that caching is unreachable with stable ids.

A process action's declared arguments, environment, and working directory
are only a starting point for an action key. A sound reuse contract also
needs relevant tool and input identities, output completeness, and a policy
for ambient state. Redacting secrets from logs does not by itself implement
an attestation format or define whether a secret affects cache validity;
[provenance][provenance] and [reproducibility][reproducibility] treat these as
separate concerns.

## 3. Candidate capabilities and their justification

The order below is a research priority, not a delivery commitment.
**Catalog inference:** measuring the local workload should precede choosing
distributed storage or semantic caching. The corpus contains relevant
mechanisms but does not measure their benefit for Sparkles.

| Priority    | Workload and demonstrated need                                           | Candidate benefit                                            | Prerequisite and unresolved question                                                       |
| ----------- | ------------------------------------------------------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| First       | Repeated local package checks; redundant work has not been quantified    | Identify avoidable planning, compilation, and test execution | Measure the existing DUB cache before adding another reuse layer                           |
| First       | A hypothetical task-result cache must distinguish relevant edits         | Reuse safe results while retaining stable task names         | Define complete inputs and output validity; decide which tests may depend on ambient state |
| Next        | D compilation with generated imports or non-source inputs                | Discover dependencies without duplicating compiler semantics | Measure DMD/LDC dependency reporting and test its coverage                                 |
| Next        | Concurrent checks with private build roots, as required by the task spec | Avoid write races and preserve trustworthy coverage          | Measure isolation cost and check which reads remain ambient                                |
| Conditional | Repeated generators producing identical artifacts                        | Stop downstream work when consumed artifacts are unchanged   | Define artifact boundaries; demonstrate avoided work exceeds identity-check cost           |
| Conditional | A measured working set exceeding a cache budget                          | Bound storage without serving incomplete results             | First establish a cache workload, retention needs, and missing-blob recovery               |
| Deferred    | Remote workers or shared results                                         | Share expensive actions across machines                      | Establish demand, input closure, toolchain provisioning, and failure semantics             |
| Deferred    | Consumers requiring build-origin evidence                                | Export a statement about an artifact's production            | Define the consumer, trust boundary, materials, and signing authority                      |

The [semantic-caching][semantic-caching], [CAS-eviction][cas-eviction], and
[distributed-dependency][dynamic-deps] pages supply candidate mechanisms.
Their presence in the survey is not evidence that this workload needs them.

## 4. Investigation plan

Each investigation records tool revisions, command lines, build mode, machine,
input edits, execution logs, and final artifacts. Timing studies separate
cold and warm DUB caches, use repeated runs, and report dispersion. Correctness
scenarios compare with a clean execution and deliberately remove or corrupt
retained state. A passing timing run cannot establish dependency completeness.

### A. Establish the cost of repeated checks

**Decision blocked:** whether a task-result cache adds value above DUB's
existing behavior. **Hypothesis:** some repeated checks spend enough time
outside reusable compilation to justify persistent task metadata.

Run an unchanged check twice, then repeat after a private implementation edit,
a public interface edit, a compiler-flag change, and a deleted output. Record
wall time, planning time where observable, compiler invocations, test-process
invocations, and bytes read or written. Hold package selection, coverage,
build type, and compiler fixed; separate source-cache and compiled-cache
warmth. A negligible avoidable cost argues for retaining orchestration alone.
A substantial cost identifies which task kind warrants a reuse prototype.

### B. Test identity and invalidation before persistence

**Decision blocked:** the key model for reusable work. **Hypothesis:** stable
logical task ids can coexist with configuration-specific action keys.

Use one small package in two configurations. Change source content, flags,
compiler identity, environment, and a generated input independently. Assert
which action keys change and which logical ids remain stable; delete an
output and require reconstruction or execution. Compare resulting artifacts
with clean builds. Avoid using the same key-building function as the oracle.
If two behaviorally different actions collide, the input model is incomplete;
if stable reporting breaks, revise the mapping rather than assuming logical
identity itself must become content-addressed.

### C. Measure dependency discovery and isolation

**Decision blocked:** whether compiler reports suffice for D actions, and
whether observation is needed as an audit. **Hypothesis:** compiler-emitted
dependencies cover ordinary imports at lower cost than general observation.

Create fixtures with generated imports, conditional imports, a missing file
that later appears, and compile-time file access. Compare emitted dependency
sets with deliberate edits and clean-build results. Measure reporting cost
separately from compilation, then compare execution in ordinary and private
build roots. Record compiler version, configuration, filesystem, and kernel;
do not transfer Rattle's or BuildXL's published overhead to a D compile step.
An omitted behavior-changing input rejects the proposed coverage claim,
even when the timing result is favorable.

### D. Test additional mechanisms only after their trigger is observed

| Decision                         | Minimal experiment                                                    | Metrics and confounders                                                          | Result that changes the recommendation                                                     |
| -------------------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Static stages or graph extension | A generator emits a dependency plan consumed by a later compile       | Extra planning latency, changed-edge correctness; hold compiler work fixed       | Correct staged execution may avoid a more general dynamic scheduler                        |
| Artifact-level early cutoff      | Edit a generator input while preserving generated bytes               | Downstream actions avoided versus hashing cost; control timestamp handling       | Net savings justify a distinct consumed-artifact identity                                  |
| Reachability or recency eviction | Replay a measured action/output access trace under equal byte budgets | Hit rate, retained bytes, incomplete-result recovery; use the same initial cache | A repeatable benefit is needed before adding graph-aware retention                         |
| Build-origin export              | Map a real consumer's required materials to one completed action      | Missing materials, secret exposure, verification behavior                        | Ordering edges alone are insufficient if required input identities cannot be reconstructed |

## Sources

- Task-DAG specification and delivery plan, at the Git locators in §1:
  target orchestration semantics, not implementation-completion evidence.
- Pinned task model, action, graph, and executor modules: inspected branch
  implementation. The linked recipe and repository-input modules describe
  reusable primitives in the research checkout.
- [Comparison][comparison] and [concepts][concepts]: prior-art findings and
  model vocabulary. Proposed experiments above have no measured outcomes yet.

<!-- References -->

[comparison]: ./comparison.md
[concepts]: ./concepts.md
[manifest]: ../../../libs/build-primitives/src/sparkles/build_primitives/dub_manifest.d
[recipe]: ../../../libs/build-primitives/src/sparkles/build_primitives/dub_recipe.d
[glob]: ../../../libs/build-primitives/src/sparkles/build_primitives/glob_walk.d
[git-env]: ../../../libs/build-primitives/src/sparkles/build_primitives/git_env.d
[provenance]: ./provenance.md
[reproducibility]: ./reproducibility.md
[semantic-caching]: ./semantic-caching.md
[cas-eviction]: ./cas-eviction.md
[dynamic-deps]: ./dynamic-deps-distributed.md
