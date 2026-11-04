# PIE: Scalable Incremental Building with Dynamic Task Dependencies (Java)

PIE's contribution is less a new build language than a new _direction of
traversal_: given the files that changed, the engine walks the previous build's
dependency graph upwards from them and touches only what the change reaches,
falling back to Pluto's top-down walk wherever control flow invents dependencies
the old graph cannot name. Vocabulary is [concepts]'s; this page does not redefine
_scheduler_, _rebuilder_, _trace_, _minimality_ or _early cutoff_.

**Last reviewed:** November 2, 2026

| Field    | Value                                                                                                                                                             |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors  | Gabriël Konat, Sebastian Erdweg, Eelco Visser — all Delft University of Technology                                                                                |
| Venue    | ASE 2018, 33rd ACM/IEEE Int. Conf. on Automated Software Engineering, Montpellier, pp. 76–86 (11 pages)                                                           |
| DOI      | [10.1145/3238147.3238196][doi]                                                                                                                                    |
| License  | CC-BY 4.0 — the PDF carries "This work is licensed under a Creative Commons Attribution International 4.0 License." (p. 76)                                       |
| Artifact | Ships as an alternative executor in PIE, [`metaborg/pie`][pie]; the case study script is [`metaborg/spoofax-pie`][spoofax-pie] — both referenced, not opened here |
| Category | Foundations — a scheduler/algorithm contribution, not a product build system                                                                                      |

## Overview

### What it solves

A programmable build script — code that calls tasks, inspects their return values,
and loops over their outputs — defeats static dependency extraction, so an engine
must recover the graph from execution. Pluto does that soundly and optimally, but
only by re-walking the whole graph on every rebuild:

> "To check which tasks need re-execution, Pluto needs to traverse the entire
> dependency graph of the previous build and has to touch every file that was
> read or written in the previous build."
>
> — §1, p. 77

On a large project the cost of _deciding_ that nothing needs rebuilding dominates
the small edits an IDE fires continuously. PIE replaces that traversal: the caller
supplies the changed-file set — "for example, from IDEs that manage their
workspace or by using a file system watch-dog" (§1).

### Design philosophy

§1 frames three properties that pull against each other: **efficiency** (rebuild
time "proportional to how many build tasks are affected by a change"),
**precision** (a rebuild "yields the exact same result as a clean build"), and
**expressiveness** ("build scripting languages should not require build engineers
to apply complicated design patterns (e.g., recursive or generated Makefiles)").
Systems that buy the first two split configuration from execution, which
"contradicts reality, where how to build an artifact depends on the execution of
other build tasks" (§1). The abstract states the claim this page tests:

> "In contrast to prior work on incrementality for such programmable builds, our
> algorithm scales with the number of tasks affected by a change and is
> independent of the size of the software project being built."

## How it works

### The task API is the host language

A _task_ is a function that may read and write paths, call other tasks, and
returns a value. Figure 1's script (§2, p. 77) uses the whole API:

```text
func main() -> string {
    val config = parseYaml(./config.yaml)
    val src = config.srcDir
    if (config.checkStyle) { ... }
    val userTests = ./test/**
    val genTests = genTests(src, ./test-gen)
    var failed = 0
    for (test <- userTests ++ genTests) {
        val testOk = runTest(test)
        if (!testOk) failed += 1
    }
    return "Failed tests: " + failed
}
```

(the `checkStyle` call and `"style error"` return are elided). Tasks are
**parameterized** (`runTest(./test/X)`) and **return values** (`Config`, `path*`,
a count), which the paper says Shake's tasks cannot — they are "not parameterized,
nor can they return values" — "making their use as dynamic task dependencies
tedious" (§7). Paths are first class, so a _directory_ read changes when a file is
added, and `if`/`for` decide at build time which tasks exist — the conditional and
iterative building of §1.

### Dynamic dependencies are recorded, not declared

Every task result `r` carries what the execution discovered: `reqFiles` (read),
`genFiles` (created or written), `reqTasks` (called), plus `output` (§4.2, p. 81).
A graph `DG` is those results keyed by task, and every edge carries a **stamp** —
"a summary of a file's content, such as the last modification date or a hash" —
that `isConsistent` compares with the current file or output value. Nothing is
declared up front; the previous run's graph is the only input, exactly the
position [concepts] describes for a monadic task under a trace-based rebuilder.

### Consistency

Correctness here is a predicate on the graph, not on the store:

> "The dependency graph of a build is consistent if for each invoked task (i) all
> read and written files are up-to-date and (ii) the outputs of all called tasks
> are up-to-date."
>
> — §2, p. 77

"An incremental build algorithm is correct if it always restores consistency [3].
Or intuitively: a correct incremental build algorithm yields the same result as a
clean build" (§2) — a stateful formulation, where [concepts]'s `compute`-based
definition is extensional. §2 walks three edits against a fixed graph (Figure 2,
p. 78):

| Change | Edit                                   | What it forces                                                                                                                     |
| ------ | -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `C1`   | `config.yaml` turns style checking off | Only `parseYaml` and `main` rerun; the new `main` graph _drops_ the `checkStyle` edge                                              |
| `C2`   | user test `./test/X` edited            | One task reruns; if `main`'s value is unchanged the climb stops — early cutoff                                                     |
| `C3`   | source file `./src/C` added            | A directory dependency reruns `checkStyle` and `genTests`, whose output makes `main` discover a _new_ call `runTest(./test-gen/C)` |

`C3` is what a pure bottom-up traversal cannot handle: the edge it needs is not in
the old graph.

### The hybrid: bottom-up by default, top-down on demand

§3 builds the design as five answers to five failure modes. **Bottom-up** (§3.1):
start from the changed files' readers and generators, not from the root.
**Top-down initialization** (§3.2): a first build has no affected set, so it runs
Pluto's algorithm, "since every task is affected in the initial build".
**Early cutoff** (§3.3): stop climbing when a rebuilt task's output is unchanged.
**Order of recomputation** (§3.4): eager execution can run a task twice, which
"causes glitches: inconsistent results that are exposed to users", so tasks enter a
topologically ordered priority queue instead. **Dynamic dependencies** (§3.5):
while executing, switch to top-down and eagerly build newly discovered tasks; if
the discovered task already exists and is queued, switch back to bottom-up until
it has run or been found unaffected.

The entry point is compact (Figure 3, p. 80; subscripted names written plainly):

```text
function buildWithChangedFiles(F, DG_old)
    Te := ∅; Oc := ∅; DG_new := DG_old
    Tq := new PriorityQueue(DG_old.depOrder())
    schedAffByFiles(F, DG_old)
    while Tq ≠ ∅ do
        execAndSchedule(Tq.poll(), DG_old)
```

`Tq` is the queue, `Te` the set of tasks executing now (the cycle detector), `Oc`
the per-run output cache, `DG_new` the graph being rebuilt. `schedAffByFiles`
schedules a task when a file it requires or generates has an inconsistent stamp;
`schedAffCallersOf` schedules callers when an executed task's _output value_ has
changed. `require` (Figure 5) is the interception point: cached output, else a
task from the old graph goes through `requireNow`, which drains the queue from the
bottom until it can execute the task or reuse its old output; a task absent from
`DG_old` runs unconditionally, since "no existing task in `DG_old` can depend or
be affected by the new task".

### Validation invariants and implementation

Executing tasks rebuilds the graph, so §3.6 re-checks three invariants on the fly
and aborts on violation: an **overlapping generated file** (two tasks writing one
path, so no consistent order exists), a **hidden dependency** (a task reads a file
produced by another without a transitive task dependency on the producer), and a
**cyclic task**. The first two are [concepts]'s undeclared outputs and missing
dependencies, promoted from cache misses to build _errors_. The algorithm is a
second executor inside PIE's runtime, "fully conforming to its API", which makes
the comparison fair: "since PIE implements the Pluto build algorithm, we can
compare our algorithm against Pluto's, for the exact same build scripts" (§5).

## Evaluation, as reported

One build script, one workspace, 60 changes. The script is the Spoofax-PIE
pipeline (parse tables, styling, name and type analysis, IDE feedback for Tiger,
Calc and MiniJava); the changes run as one synthesized chain "against one algorithm
in one go, to simulate a full editing session" (§6.1, p. 82). Measured with JMH on
"a MacBook Pro with a 2.7 GHz Intel Core i7 processor, 16 GB of 1600 MHz DDR3
memory, and a SSD, running macOS 10.12.6", with a 64-bit JRE 1.8, 16 MB stack and
4 GB heap.

### Numbers

Figure 6 (p. 85) charts _aggregate_ times per change category on a log scale; its
bar labels sit below beside the sentence §6.2 prints about the same category.

| Change                                  | Pluto (s) | Hybrid (s) | As stated in §6.2                                                                                                        |
| --------------------------------------- | --------- | ---------- | ------------------------------------------------------------------------------------------------------------------------ |
| A initial build                         | 68.1      | 68.7       | "both the Pluto and hybrid algorithm perform identically"                                                                |
| B all editor changes                    | 12.1      | 1.1        | "11 seconds faster, providing a speedup of 1016%"                                                                        |
| C example program file changes          | 9.1       | 0.005      | "takes 0.005 seconds, providing a 9 second (182133%) speedup"                                                            |
| D styling specification change          | 8.8       | 0.7        | "8 seconds faster, providing a 1245% speedup"                                                                            |
| E adding a language specification       | 30.4      | 27.5       | "only a 2.9 second (11%) speedup"                                                                                        |
| F syntax specification small change     | 8.5       | 3.9        | "a 4.5 second (118%) speedup"                                                                                            |
| G syntax specification cascading change | 8.4       | 21.5       | "the hybrid algorithm was 13 seconds slower, causing a 61% slowdown"                                                     |
| H syntax specification refactor         | 17.6      | 3.0        | "a 14.5 second (483%) speedup"                                                                                           |
| I analysis specification change         | 28.6      | 18.8       | "a moderate 9.7 second speedup (52%)"                                                                                    |
| J analysis specification refactor       | 50.9      | 49.1       | "the Pluto and hybrid algorithm perform nearly identically"                                                              |
| K no changes                            | 3.3       | 0.00001    | "completing in sub-millisecond time, while the Pluto algorithm still needs to check the entire dependency graph" (3.3 s) |
| L all files changed                     | 69.8      | 70.1       | the heuristic switches to top-down, "therefore running as fast as the Pluto algorithm does"                              |

Two arithmetic notes from recomputing the printed values: the percentages are
taken against the _hybrid_ time (`C`'s 182133% is `(9.1 − 0.005)/0.005`; `G`'s
61% is `13.1/21.5`), and because bar labels are rounded to three significant
figures, recomputing from them drifts from the printed percentage (`B` gives 1000%
against 1016%). No per-task counts or save ratios are reported, so none are
claimed.

The win is the fixed cost of the top-down walk: `K` spends 3.3 s proving that
nothing changed, and every small edit pays it again. `H` cuts off early on a
"semantically equivalent parser" (§6.2); `G` is the acknowledged price — `main`
would shed its analysis dependency under top-down order, but the hybrid recompiles
the analysis specification first. The 50% heuristic guards the extreme: when "more
than 50% of source files (all required files, for which there is no generator
task) change", the engine runs Pluto's algorithm — "This heuristic seems to work
well, but may require further tweaking." §6.3 offers two threats: one build
script, and a synthesized chain of 60 changes.

## Correctness and optimality, as argued

§4.3 argues correctness in halves mirroring the two traversals. For old-graph
tasks, "if a task is affected, it will be scheduled": direct effects from stamp
mismatch, indirect ones from `schedAffCallersOf` and the queue. New tasks run
top-down, and Pluto's algorithm "is correct [3]", with `requireNow` only reordering
dependencies first. The weak spot is stated, not hidden: every task in the old
graph counts as needed, so a top-down execution that removes an edge can leave
work already done —

> "Therefore, theoretically, the hybrid algorithm is only partially optimal.
> However, this is a rare case, as shown in the evaluation in Section 6."
>
> — §4.3, p. 82

In [concepts]'s terms that is a stated violation of minimality — work executed
that does not transitively feed a changed input — measured by `G`.

## Relation to à la carte

PIE sits in a cell [a-la-carte]'s grid does not have; the mismatch is informative
rather than a labelling problem.

| Dimension ([concepts]) | PIE                                                                                                                                                                          |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Task model             | `Monad`-shaped and beyond: dependencies follow ordinary control flow (`if`, `for`), so no description determines them — they exist only as `reqTasks`/`reqFiles` after a run |
| Rebuilding             | Verifying traces: per-edge stamps over files and output values, with early cutoff on unchanged output                                                                        |
| Scheduler              | None of the three defined kinds: change-driven bottom-up (needs a changed-file set) with on-demand top-down fallback                                                         |
| Minimality             | Claimed for Pluto ("only executes a task if absolutely necessary", §2); explicitly only partial for the hybrid (§4.3)                                                        |
| Store                  | In-place file system plus per-run `Oc`; the only persistent state is `DG` with its stamps — no CAS, no remote cache                                                          |
| Cloud / distribution   | Absent; no constructive traces, no offloading                                                                                                                                |

Three consequences. `Build c i k v` in [concepts] takes a target key and a task
description and nothing else — nowhere to pass "the files that changed", so a
change-driven scheduler is an addition to the model rather than a cell in it (the
gap [concepts] flags for file-watch cancellation). PIE's dependency list is
strictly the recorded-execution kind (`track`, not `dependencies`), and finer than
key→key edges: a _parameterized_ task call and a directory read are both edges.
Its rebuilder is plain verifying-trace machinery, which is why the paper's cliff is
a _scheduling_ artefact.

## Analysis spine

### 1. Task model & scheduling

Parameterized functions returning values; a hybrid scheduler needing the changed
set and the old graph; single-threaded.

### 2. Rebuilding & correctness

Stamps (`mtime` or hash) over files and output values, with early cutoff;
optimality argued, conceded partial.

### 3. Dependency discovery

Observed at the language level, not by `ptrace` or FUSE: a shell-out to an opaque
tool is invisible.

### 4. Store & caching

In-place file system; `DG` caches decisions, not outputs.

### 5. Hermeticity & provenance

Absent. Overlapping outputs and hidden dependencies fail at build time — a
precondition, not a sandbox.

### 6. Distribution

Absent: one process, one `DG`.

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a validated static DAG — `TaskNode`,
`TaskEdge` with an `EdgeCondition`, `OutputPolicy` — plus a single-pass executor;
the package keeps no record of a previous run and takes no changed-file input. Two
borrowings survive contact with PIE's evidence: the change set is an argument, not
a discovery (PIE's efficiency rests on the caller handing it `F`, so an
incremental Sparkles must take that input from `git status` or watch events); and
a trace must record what executed, not what was planned (`reqFiles`/`genFiles`/
`reqTasks`, the `track` side of [a-la-carte]), because `EdgeCondition` makes the
executed path a subset of the planned one. PIE's queue `Tq`, which stops a shared
dependency running twice, is the ordering discipline any memoizing executor
needs.

## Strengths and weaknesses

- **Honest about its trade-off.** The losing case is measured, explained
  mechanically, and quantified (13 s, one change in sixty) rather than dropped
  from the chart; the 50% heuristic is tuning, not truth.
- **Fair baseline, real program.** Same script, same runtime, so the comparison
  isolates traversal order — and Spoofax's script genuinely needs conditional and
  iterative building (§6.1).
- **One script, one machine, no cost model.** Nothing else is compared, no history
  is mined, and correctness rests on an argument plus the absence of divergence.

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                               | Trade-off                                                                      |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Bottom-up from changed files, not top-down from roots | Cost tracks change impact, not project size; an unedited workspace costs nothing        | Needs a changed-file set; one direction cannot see new edges (`C3`)            |
| Keep Pluto's top-down walk for new tasks              | Dynamic dependencies exist only during execution, and top-down is where they surface    | Two traversals, two correctness arguments, and `requireNow`'s queue draining   |
| Topologically ordered priority queue                  | Prevents double execution and glitches exposed to an interactive user                   | Extra order maintenance; draining `DG_old` makes removed edges cost work (`G`) |
| Stamps on files _and_ output values                   | Enables early cutoff on values, not just timestamps; `mtime` and hash both pluggable    | Value precision is untested; hash-versus-`mtime` cost is not measured          |
| Abort on overlapping outputs / hidden dependencies    | An inconsistent graph has no correct order; failing loudly beats a silently wrong build | Scripts that legitimately share a file must be restructured                    |

## Sources

- Konat, Erdweg & Visser, _Scalable Incremental Building with Dynamic Task
  Dependencies_, ASE 2018, pp. 76–86 — [DOI][doi]. Read in full from
  `$REPOS/papers/build-systems/konat-2018-scalable-incremental-building-dynamic-task-dependencies-ase.pdf`
  via `pdftotext -layout`, with Figure 6 (p. 85) rendered by `pdftoppm` at 200 dpi
  because its bar labels do not survive text extraction in column order. Section
  and page numbers are the paper's.
- Pluto — Erdweg, Lichter & Weiel, OOPSLA 2015, [DOI][pluto] — the paper's ref.
  [3], **not** opened; every statement about Pluto here is this paper's. PIE the
  language (Konat et al., Programming 2(3), 2018, ref. [16]) is likewise
  referenced, not opened.
- [`metaborg/pie`][pie] and [`metaborg/spoofax-pie`][spoofax-pie] (paper
  footnotes 2–3) were not cloned: no claim is made about their current state and
  no blob URL is pinned.
- Sibling pages: [concepts], [a-la-carte], [index]. Sparkles side, read for §7:
  `libs/build-primitives/src/sparkles/build_primitives/task/` (`model.d`,
  `executor.d`, `graph.d`).

<!-- References -->

[doi]: https://doi.org/10.1145/3238147.3238196
[pluto]: https://doi.org/10.1145/2814270.2814316
[pie]: https://github.com/metaborg/pie
[spoofax-pie]: https://github.com/metaborg/spoofax-pie
[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[index]: ./index.md
