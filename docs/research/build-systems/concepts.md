# Build Systems: Concepts & Vocabulary

An incremental build must produce an up-to-date result while avoiding work that
cannot affect it. Two questions recur: which dependencies must finish before a
task can proceed, and what evidence allows the task to be skipped? The
_scheduler_ answers the first; the _rebuilder_ answers the second. Their
composition is the central model of [Build Systems à la Carte][jfp].

This page explains that model and its limits as a vocabulary for comparing
engines. Sections 1–3 introduce tasks, scheduling and rebuilding; §4 separates
correctness from avoiding unnecessary work; §§5–6 explain the design space and
sharing cached results. Section 7 connects the model to implementation layers and to the
theme pages that cover observation, isolation and provenance. The examples are
deductions from the model, not measurements of named tools. Engine-specific
behavior belongs in the deep-dives and [comparison].

**Last reviewed:** November 4, 2026 — conceptual examples and synthesis boundaries;
upstream source revisions remain those listed under Sources.

> [!NOTE]
> Terminology follows the JFP 2020 journal version of
> [Build Systems à la Carte][jfp] (`doi:10.1017/S0956796820000088`), not the 2018
> ICFP paper it extends: all of §7 and the verifying-step-trace material in
> §5.2.2 are new in the journal version (JFP §1). Where the catalog's prose says
> "build script" or "rule", it means the paper's _task description_; where it
> says "build engine", it means a value of type `Build`.

---

## 1. Tasks, keys and values

The paper's base vocabulary is deliberately small (JFP §3.1). A **store**
(`Store i k v`) maps **keys** to **values** and carries the **persistent build
information** `i` — the system's memory between invocations. In software builds
the store is the file system, keys are file names, values are file contents; in
Excel it is the workbook, cell names and cell contents. Values are **inputs**
(user-supplied), **outputs** (end products) or **intermediate**.

> "The goal of any build system is to bring up to date a store that implements a
> mapping from keys to values."
>
> — JFP §3.1

A **task description** says how to recompute one key from the up-to-date values
of its dependencies; input keys have no task (`Nothing`). For example, the task
for `program.o` asks for `generated.h`, then compiles it. The engine supplies the
operation that obtains each dependency, so the task need not choose whether to
build, verify or restore that dependency. This separation is expressed by the
paper's function types (JFP §3.2–§3.3):

```haskell
newtype Task c k v = Task (forall f. c f => (k -> f v) -> f v)
type    Tasks c k v = k -> Maybe (Task c k v)
type    Build c i k v = Tasks c k v -> k -> Store i k v -> Store i k v
```

Polymorphism in `f` lets one task description run under different schedulers
and rebuilders compatible with its constraint in §6 (JFP §3.4). The
the constraint `c` classifies the descriptions — and the systems that can run
them:

| Constraint on `c` | Dependency shape it admits                | Paper's examples                                     |
| ----------------- | ----------------------------------------- | ---------------------------------------------------- |
| `Functor`         | a single linear chain                     | Collatz sequence; Docker layers (JFP §3.4, §3.8)     |
| `Applicative`     | static, recoverable by inspection         | Excel formulas; Make rules (JFP §3.4)                |
| `Selective`       | conditional, statically over-approximable | `IF(C1=1,B2,A2)`; Dune (JFP §3.4, §9.1)              |
| `Monad`           | dynamic, decided at run time              | `INDIRECT("A" & C1)`; Shake; Nix (JFP §3.4, §3.5)    |
| `MonadState i`    | shared cache reachable from a task        | `cloudAckermann`; every cloud model (JFP §3.8, §6.5) |

### Static versus dynamic dependencies

A **static** dependency is visible in the task description alone; a **dynamic**
one depends on a value computed during the build, so the graph cannot be known
before it starts (JFP §2.2, §3.5). The paper uses the distinction twice. First,
an applicative task's dependencies are _extracted_ without running it, by
instantiating `f` to a constant functor (JFP §3.7):

```haskell
dependencies :: Task Applicative k v -> [k]
dependencies task = getConst $ run task (\k -> Const [k])
```

Second, a monadic task's dependencies are recorded by _running_ it in a writer
context (`track`, JFP §3.7): `Const` has no `Monad` instance, so a dynamic
dependency list exists only after an execution. That asymmetry causes most of the
design space — §4.1 needs the list in advance and therefore rules out `Monad`,
while the rebuilders of §5.2–5.4 consume a previous run's list.

Shake's `need` is the clearest concrete instance: a rule names a file, builds it,
then names files whose _names came out of the first_ — the `release.tar`/`docs.txt`
pattern of JFP §2.3; [`addOracle`][shake-oracle] generalizes the same mechanism
to non-file keys such as tool versions or environment queries. `need` is the
`fetch` callback of `Task` above, at file-name granularity ([`need`][shake-file]):

```haskell
-- src/Development/Shake/Internal/Rules/File.hs
need :: Partial => [FilePath] -> Action ()
need = withFrozenCallStack $ void . apply_ fileNameFromString
```

---

## 2. Schedulers

A scheduler decides _which_ keys to bring up to date and _in what order_. The
paper separates ordering from rebuilding so they compose when their task
constraints are compatible (JFP §6.1). The three schedulers of JFP §4 are:

| Scheduler   | Needs every dependency up front?    | How it recovers from a late discovery                 | Systems the paper places here         |
| ----------- | ----------------------------------- | ----------------------------------------------------- | ------------------------------------- |
| Topological | **Yes** — static, topo-sorted first | It cannot: the graph must be known before any work    | `Make`, `Ninja`, `CloudBuild`, `Buck` |
| Restarting  | No                                  | Aborts the task, builds the missing key, restarts it  | `Excel`, `Bazel`                      |
| Suspending  | No                                  | Suspends the task, builds the missing key, resumes it | `Shake`, `Nix`                        |

**Topological** (JFP §4.1) computes a linear order respecting the dependency
graph, then executes it: simple, and it diagnoses missing keys and cycles before
any work starts. Its cost is the `Applicative` restriction — and per JFP §6.2
_every_ system in that column inherits it, since determining the order is the
same act as extracting static dependencies.

**Restarting** (JFP §4.2) interleaves ordering with execution: start a task; if
it asks for a key that is not up to date, abort it, build that key, and restart
the task from scratch. This is not minimal — work done before an abort is thrown
away — and needs a mechanism to abort a running task. Excel softens it by
persisting the discovered order as a _calc chain_; Bazel keeps a build queue and
re-queues blocked keys when their blockers complete (JFP §4.2, §6.5).

**Suspending** (JFP §4.3) builds a dependency on demand and resumes the caller —
the only one of the three that is minimal _and_ handles dynamic dependencies,
which is why Shake uses it. Implementations are blocking threads/processes or
continuation-passing style; Shake moved from the former to the latter
(JFP §4.3, §7.2). The caveat is plain: suspension pays only when the avoided
duplicate work costs more than suspending.

> [!IMPORTANT]
> "Minimal and dynamic" is a property of the _pair_, not of the scheduler.
> Suspension alone does not buy minimality: JFP §4.3 says the scheduler "when
> combined with a suitable rebuilder" provides it, and JFP §5 shows which
> rebuilders qualify.

---

## 3. Rebuilders

Once a scheduler decides a key's turn has come, the rebuilder answers one
question: is any work actually needed? The paper identifies four fundamental
answers, each with variants (JFP §5).

| Rebuilder                  | Persistent information per key             | Dynamic deps?   | Early cutoff? | Cloud? |
| -------------------------- | ------------------------------------------ | --------------- | ------------- | ------ |
| Dirty bit (JFP §5.1)       | one boolean, transitively closed           | via over-approx | no            | no     |
| Verifying traces (§5.2)    | result hash + hashes of dependency values  | yes             | yes           | no     |
| Constructive traces (§5.3) | result value + hashes of dependency values | yes             | yes           | yes    |
| Deep constructive (§5.4)   | result value + hashes of _terminal inputs_ | yes             | **no**        | yes    |

**Dirty bit** (JFP §5.1). One bit per key, set for anything that changed since
the last build, cleared once the key is rebuilt. Excel holds the bits explicitly
and demands a _transitively closed_ dirty set: over-approximation is safe,
under-approximation is not. Make's bit is the file system's mtime, repurposed —
a file is dirty when older than its dependencies. The paper's Make model assumes
rebuilding advances that timestamp, so it cannot distinguish rebuilding from a
changed result. A recipe that preserves the timestamp of an unchanged output
can let GNU Make skip consumers; the [behavioral suite][behavioral-evidence]
demonstrates this implementation qualification.
Tup refines the bit by watching the file system (JFP §9.1).

These are properties of the paper's dirty-bit model. An implementation may add
another mechanism: [tup's opt-in `^o` comparison][tup-output-comparison] suppresses
downstream work when output bytes are unchanged. The label alone does not rule
out such an extension.

**Verifying traces** (JFP §5.2). Per key, the build records the result hash and
the hashes of the values it consumed (`recordVT`), then checks they still match
(`verifyVT`). Dynamic dependencies work because the _previous_ execution's trace
supplies the list the task description cannot. For suspending schedulers the
rebuild check itself drives the build, since verifying a key suspends on its
dependencies.

**Verifying step traces** (JFP §5.2.2), Shake's actual structure, store no
dependency hashes — only each key's `built` and `changed` timestamps plus the
dependency list. The second timestamp is what preserves early cutoff; one
timestamp degrades to roughly Make. The cost is observable: if a dependency's
content changes away and back, step traces rebuild where verifying traces would
not (JFP §5.2.2, Figure 7).

**Constructive traces** (JFP §5.3) store the result value itself, so a trace can
not only confirm a key is current but _supply_ a value the local store lacks.
`constructCT` returns a list of possible values because tasks may be
non-deterministic: empty means rebuild, a match means skip, a non-matching
non-empty list means copy a candidate into the store. Sharing such traces is what
makes a cloud build (JFP §6.5).

**Deep constructive traces** (JFP §5.4) record only terminal input hashes, so a
target can be judged current without materialising anything between it and the
inputs — a shallow build. The price is determinism, violation of which is an
incorrect build rather than a slow one (JFP §8.4, Figure 12), and:

> "Deep constructive traces cannot support early cutoff (Section 2.3), since the
> results of intermediate computations are not considered."
>
> — JFP §5.4

### Worked example: an edit that changes no generated bytes

Consider two deterministic tasks. `generate` reads `schema.txt` and produces
`generated.h`; `compile` reads that header and produces `program.o`. Both tasks
declare all relevant inputs, including their tool and rule versions. A completed
build has recorded the dependencies and left both outputs in the store.

```text
schema.txt --generate--> generated.h --compile--> program.o
```

Edit a comment in `schema.txt`. Its bytes change, but `generate` produces the
same header bytes. The following predictions apply to the paper's models
(JFP §2.3, §5), with no cache entry for the edited source configuration:

| Rebuilder                | What is remembered                                  | What executes, and why                                                                                               |
| ------------------------ | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Dirty bit                | The change dirties the target's dependency cone     | Both tasks; the bit does not distinguish execution from output change.                                               |
| Verifying traces         | Each result hash and dependency-value hashes        | `generate`; `compile` sees the same header hash and is skipped.                                                      |
| Verifying step traces    | Dependency lists, plus `built` and `changed` steps  | `generate` advances `built` but keeps `changed`; `compile` is skipped.                                               |
| Constructive traces      | Reusable results indexed by dependency-value hashes | `generate`; the existing compile result remains reusable for the unchanged header value.                             |
| Deep constructive traces | Reusable results indexed by terminal-input hashes   | The edited source invalidates the target's previous trace; unchanged intermediate bytes cannot provide early cutoff. |

The distinction between content traces and step traces appears in a longer edit
history. Build header value `A` and its object; then build only the header with
value `B`; then build only the header with value `A` again. On the next object
request, a verifying trace still matches its recorded `A` hash. A step trace
sees a `changed` step newer than the object's last build and rebuilds it. The
history matters even though the header bytes have returned to their original
value (JFP §5.2.2, Figure 7).

Two changes to the scenario test different properties:

- **Generated dependency names.** If `generate` emits a manifest choosing
  `left.h` or `right.h`, `compile` must obtain the manifest before it knows which
  header to request. Dependency discovery supplies the edge; scheduling makes
  its producer finish before the consumer uses its value. The paper's restarting
  and suspending schedulers handle this demand during evaluation (§2); an
  engine may instead divide planning and execution into separate phases.
- **Deleted output.** Delete `program.o` while retaining build metadata.
  A verifying trace can detect the missing result but cannot supply its bytes.
  A constructive trace can restore them if the matching value remains
  available. An action-cache entry whose blobs have been evicted is insufficient;
  [cache completeness][cache-completeness] is an additional implementation
  obligation (JFP §5.2–§5.3, §8.4).

These predictions concern task execution and result availability separately.
A restored output avoids executing its producer; it still incurs lookup and
materialization work. The model does not establish which mechanism has lower
wall-clock cost on a particular workload.

### Applicative versus monadic traces

The constraint leaks into the trace layout. With `Applicative` dependencies the
keys are recoverable from the key alone (§1), so a trace may omit them and shrink
to `O(1)`; with `Monad` they must be recorded, making it `O(n)` (JFP §5.2.1,
§5.2.2, §5.4) — which is why `track` exists. Shake shows the boundary from the
other side: a **phony** rule names an action rather than a file, re-runs on every
build that demands it, and never runs twice in one build ([`phony`][shake-file])
— the degenerate trace, where no output can be verified because there is none.

---

## 4. Correctness and minimality

**Minimality** is stated in JFP §2.1, before any of the machinery:

> "A build system is minimal if it executes tasks at most once per build, and
> only if they transitively depend on inputs that changed since the previous
> build."
>
> — JFP §2.1

That sentence explains the verdicts of the paper's Table 1 (§2.5): Make is
minimal (assuming you do not `touch` files to fake a change), Excel is not
(dirty bits over-approximate), Shake is, Bazel is not (restarting may redo
work). Minimality is a joint property of scheduler and rebuilder, not of either
alone.

**Correctness** (JFP §3.6) is defined against a `compute` that re-evaluates a
task on a finished store, and has two conditions: the result agrees with the
initial store on every input key (nothing was corrupted), and every non-input key
holds exactly what `compute` returns. A system is correct if it does this for
_any_ task description, target and store. Three caveats apply:

- it presumes an **acyclic** task description; every system in the paper is
  correct only under that assumption (JFP §3.6, §8.5);
- for **non-deterministic** tasks it weakens from equality to membership in the
  set of possible results (JFP §8.3);
- for **shallow** cloud builds it weakens further, requiring agreement only on
  the target and the reachable inputs, not on intermediates that were never
  materialised (JFP §8.4).

**Early cutoff** stops a build as soon as a rebuilt key's value is unchanged,
since its dependents cannot then be affected (JFP §2.3, Figure 3). It belongs to
the rebuilder row: Shake and Bazel have it, the paper's Make and Excel models do not, deep
constructive traces cannot (JFP §2.3, §5.1, §5.4, Table 1). Clearing a rebuilt
key's own dirty bit does not tell a later consumer whether its value changed.
The paper discusses the need to preserve that information across target requests;
verifying step traces distinguish the last execution from the last value change
(JFP §5.1, §5.2.2).

---

## 5. The design space

The paper composes each scheduler with each rebuilder under compatible task
constraints and the correctness assumptions in §4 (JFP §6.1). Its Table 2 fills
that 3 × 4 grid. This is the catalog's
master reference table: a deep-dive's classification matches a cell, or says why
it does not.

| Rebuilder ↓ / Scheduler →  | Topological (§4.1) | Restarting (§4.2) | Suspending (§4.3) |
| -------------------------- | ------------------ | ----------------- | ----------------- |
| Dirty bit (§5.1)           | `Make`             | `Excel`           | —                 |
| Verifying traces (§5.2)    | `Ninja`            | —                 | `Shake`           |
| Constructive traces (§5.3) | `CloudBuild`       | `Bazel`           | — (Cloud Shake)   |
| Deep constructive (§5.4)   | `Buck`             | —                 | `Nix`             |

> "Of the remaining four spots, all result in workable build systems."
>
> — JFP §6

The paper calls **no** combination impossible; four are merely _uninhabited_. It
singles one out — suspending × constructive traces is `Cloud Shake`, "a
cloud-capable build system that is minimal and supports both early cutoff and
monadic dependencies" (JFP §6.5), later built and used for GHC's Hadrian build
(JFP §7.3). A dash therefore means _unavailable when written_, not forbidden.

Further placements live in prose rather than in Table 2, and are the paper's own
classifications (JFP §9.1):

| System      | Placement the paper gives it                                                                                                    |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `redo`      | "almost exactly matches Shake" — suspending × verifying traces, developed independently                                         |
| `tup`       | "functions much like Make, but with a refined dirty-bit implementation" that watches the file system, and deletes stale results |
| `dune`      | selective functors; originally arrows, which simplified static approximation                                                    |
| `pluto`     | Shake's model plus cyclic rules resolved by a user-supplied strategy                                                            |
| `fabricate` | "cannot be modelled in our framework": it declares no reads or writes, and OS-level tracing supplies them                       |

Fabricate is the paper's only encounter with dependency _discovery by tracing_,
and even there it is an encoding question (JFP §9.1) — see §7.

---

## 6. Cloud and distribution

Bazel is the paper's worked example of cloud building (JFP §2.4): a
**content-addressable cache** from content hash to content, plus a **memo
table** of executed commands annotated with input and output hashes. A lookup
predicts a task's output hashes from its input hashes and the cache supplies the
bytes, so a target can be produced from sources plus a hash pipeline, skipping
compilation. `Buck` and `Nix` get the same effect from deep constructive
traces — a deterministic build needs one lookup keyed on terminal inputs
(JFP §5.4, §8.3) — though Nix's coarse-grained package dependencies serve a
different purpose (JFP §9.1).

Turning Shake into `Cloud Shake` needed two functions, which Shake's source names
`addCloud` and `lookupCloud` — "suspiciously like" the paper's `recordCT` and
`constructCT` (JFP §7.3):

```haskell
-- src/Development/Shake/Internal/History/Cloud.hs
addCloud    :: Cloud -> Key -> Ver -> Ver -> [[(Key, BS_Identity)]] -> BS_Store -> [FilePath] -> IO ()
lookupCloud :: Cloud -> (Key -> Wait Locked (Maybe BS_Identity)) -> Key -> Ver -> Ver -> Wait Locked (Maybe (BS_Store, [[Key]], IO ()))
```

The two `Ver` arguments are the delta between theory and practice: one is the
build-script version, one the rule version, and a change to either invalidates
every matching trace (JFP §7.3). The dependency argument is a _list of lists_
because Shake lets a rule demand a set of files at once so they build in parallel
(JFP §7.3, §8.2). Shake keeps verifying traces as the fast path and consults the
constructive trace only on a miss (JFP §7.3).

Three findings from that experience are the catalog's best evidence on what
hermeticity costs (JFP §7.4):

- **Irrelevant differences kill sharing.** A compiler path (`/usr/bin/gcc` vs
  `/usr/local/bin/gcc`) or an embedded timestamp causes cache misses with no
  semantic cause; remedies are relative paths, version-number dependencies,
  controlling the environment as Nix does, and asking compilers for determinism.
- **Under-declared outputs break remote builds.** Producing `Foo.hi` and `Foo.o`
  but declaring only `Foo.hi` works locally and fails once `Foo.hi` arrives
  without `Foo.o` — "most issues encountered during the move to cloud builds for
  GHC were caused by failing to declare produced files" (JFP §7.4).
- **Missing dependencies get worse.** A local build re-executes a command at
  least once per user; a cloud build may execute it once ever, so an undeclared
  input can be wrong forever. Shake's lint modes were coupled to FSATrace to find
  both classes of error (JFP §7.4).

The cloud model also lists what an implementation still owes (JFP §8.4):
minimising **communication** (hashes, not contents), **offloading** (workers
executing remotely), **eviction** (shallow builds gain from _keeping_ traces
whose values were evicted, so a hash passes through until materialised), and
**shallow builds** themselves.

> [!WARNING]
> The paper does **not** cover provenance, attestation, sandbox mechanisms, or
> mechanised proofs of correctness. Its nearest neighbours are §3.6's
> correctness definitions and §7.4's cache hygiene; "proof-producing" appears
> only as the claim that the models are executable and tested (JFP §7.1). Those
> topics belong to the theme pages named in §7.

---

## 7. How this catalog uses these terms

### From the model to an implementation

The grid describes an evaluation mechanism, not every layer of a product.
A graph evaluator can verify dependency revisions while a separate action
cache restores process outputs. [Buck2][buck2-layers] is an example of that
composition. Classification therefore names the layer under discussion; a
verifying graph and a constructive action cache can coexist.

The same distinction applies to identity. In the worked example, `program.o`
is a logical key whose value may change between builds. A cache lookup must
also distinguish the compiler, arguments and relevant input values; the output
digest identifies the resulting bytes. Two different action configurations may
produce identical bytes without becoming the same logical task. The
[action-cache and content-store distinction][cache-layers] supplies the
implementation detail; the paper's key parameter does not require all three
roles to use one identifier.

Equality also needs a stated domain. The model compares values; an implementation
may compare content hashes, modification times or interned revisions as evidence
about values. Equal timestamps do not establish equal bytes, and a revision
comparison is meaningful under the evaluator's revision contract. The
[reproducibility risks][equality-risks] and [DICE revision model][buck2-revisions]
give the corresponding qualifications. An early-cutoff claim states which
comparison it uses.

Dependency discovery and scheduling answer different questions. A depfile, source
parser or tracer provides an edge set; the scheduler decides how the consumer
waits for the producers on those edges. Learning an edge after execution is not
the same operation as requesting a producer during graph evaluation. Likewise,
restarting a graph-evaluation function need not mean launching its compiler
process repeatedly. The [graph-autogeneration mechanisms][discovery-mechanisms]
and each engine's task model specify where discovery and execution occur.

### Vocabulary outside the paper

The catalog's spine has six dimensions: the paper defines two fully, three only
in part, and one not at all. The table is the contract with the deep-dives.

| Spine dimension          | Vocabulary this page supplies                                                                                        | Status in the paper                         |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| Task model & scheduling  | store, keys, values, task description, `Task c k v`, `Applicative`/`Monad`, topological / restarting / suspending    | Fully defined, JFP §3–§4                    |
| Rebuilding & correctness | dirty bit, verifying (step) traces, constructive and deep constructive traces, minimality, correctness, early cutoff | Fully defined, JFP §2, §5, §3.6             |
| Dependency discovery     | static extraction (`dependencies`) vs recorded execution (`track`) only                                              | Partial: declared or executed, never traced |
| Store & caching          | `Store i k v`, persistent build information, constructive traces, CAS + memo table, eviction                         | Partial: mechanism yes, policy no           |
| Hermeticity & provenance | cache-hit hygiene (paths, versions, declared outputs, undeclared inputs)                                             | Not covered as a topic                      |
| Distribution             | cloud cache lookup, shallow builds, offloading, communication                                                        | Partial: cache yes, execution no            |

The paper does not supply the whole operational vocabulary. The following
links lead to the treatments used by the catalog; they are not additional
properties inferred from a scheduler × rebuilder cell:

- **Discovery by tracing** (syscall interception, FUSE, depfiles, strict-deps
  pruning). The paper starts from a task description that already says what it
  depends on, and its only tracing example is Fabricate, an encoding question
  (JFP §9.1). Treatment: [graph-autogeneration], [dependency-pruning].
- **Sandbox mechanism and overhead** (namespaces, `ptrace`, eBPF, Landlock,
  FUSE). The paper treats environment control as a cache-hit remedy, not a
  mechanism with a cost (JFP §7.4). Treatment: [sandboxing-overheads].
- **Provenance and attestation** (SLSA, in-toto, signed action graphs). Absent
  entirely; §3.6's correctness says nothing about _who_ ran the action.
  Treatment: [provenance].
- **Hermeticity, determinism and reproducibility.** Controlling an action's
  environment and reproducing its output are separate questions. Treatment:
  [reproducibility], especially its per-system qualifications.
- **Action-cache completeness.** A matching result record is useful only when
  the required output content can be supplied. Treatment: [CAS eviction][cache-completeness].

Two conventions follow. Classify the relevant layer by its §5 cell and mark a
mismatch rather than stretching the table. And when a page
describes a scheduler or rebuilder the paper lacks — one that cancels obsolete
tasks on file-watch events, which topological schedulers cannot easily support
(JFP §8.9) — say so: this vocabulary stops at three schedulers and four
rebuilders.

---

## Sources

- Mokhov, Mitchell & Peyton Jones, _Build systems à la carte: Theory and
  practice_, JFP 30, e11 (2020) — [DOI][jfp]. Text read from the local PDF
  `$REPOS/papers/build-systems/mokhov-2020-build-systems-a-la-carte-theory-and-practice-jfp.pdf`
  (55 pp.) via `pdftotext`; section numbers are the journal version's.
- Shake, clone at `$REPOS/build-systems-research/src/shake`, commit
  `526051c894aa88addb845e3e6b52b02a69becf8a` — [`need`/`phony`][shake-file],
  [`addOracle`][shake-oracle], [`addCloud`/`lookupCloud`][shake-cloud].
- Sibling and cross-cutting pages: [Writing Research Docs][research-docs] (house
  style), [Monorepo & Workspace Concepts][monorepo-concepts] (the analogous
  shared-vocabulary page for the workspace-shaped survey).

<!-- References -->

[jfp]: https://doi.org/10.1017/S0956796820000088
[comparison]: ./comparison.md
[behavioral-evidence]: ./behavioral-evidence.md
[tup-output-comparison]: ./tup.md#interception-strictness-variables
[cache-completeness]: ./cas-eviction.md#correctness-risks
[cache-layers]: ./cas-eviction.md#_1-one-budget-or-two
[buck2-layers]: ./buck2.md#analysis-spine
[buck2-revisions]: ./buck2.md#how-it-works
[equality-risks]: ./reproducibility.md#correctness-risks
[discovery-mechanisms]: ./graph-autogeneration.md#what-a-generator-actually-generates
[reproducibility]: ./reproducibility.md
[research-docs]: ../../guidelines/research-docs.md
[monorepo-concepts]: ../monorepo-tooling/concepts.md
[graph-autogeneration]: ./graph-autogeneration.md
[dependency-pruning]: ./dependency-pruning.md
[sandboxing-overheads]: ./sandboxing-overheads.md
[provenance]: ./provenance.md
[shake-file]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Internal/Rules/File.hs
[shake-oracle]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Internal/Rules/Oracle.hs
[shake-cloud]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Internal/History/Cloud.hs
