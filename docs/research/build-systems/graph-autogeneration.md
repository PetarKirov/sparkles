# Graph Autogeneration (Theme)

A build graph can be written by a person, observed from a run, or derived from
source. This page is about the last two: what a generator actually produces, which
half of a build description it is allowed to own, and why a synthesized edge is
trustworthy in one engine and silently wrong in another. The distinction that
organizes the evidence is not "traced versus static" but **edges versus tasks**:
tracing writes down the arrows and leaves the commands to a human, while a
`BUILD` generator writes the commands too — and inherits the merge problem that
follows.

**Last reviewed:** November 2, 2026

| Field      | Value                                                                                                                                  |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Category   | Theme — cross-cutting; no single system                                                                                                |
| Question   | Where do build edges come from when nobody writes them down, and when is a synthesized edge safe to trust?                             |
| Generators | observation (`strace`/`fsatrace`, FUSE, atime), execution-time declaration (`redo-ifchange`, `need`), static analysis (Gazelle, Pants) |
| Systems    | fabricate, tup, Rattle, redo, Shake, BuildXL, Gazelle, Pants v2, GN, Bazel, Buck2                                                      |
| Vocabulary | [concepts] — this page does not redefine _scheduler_, _rebuilder_, _trace_, _minimality_ or _early cutoff_                             |

> [!NOTE]
> **Scope.** This page covers how the edge set is synthesized, not sandbox
> mechanisms ([sandboxing-overheads]), pruning declared edges
> ([dependency-pruning]), or dynamic dependencies discovered _during_ one
> scheduled build ([dynamic-deps-distributed], [pie]). Nix derivations that produce
> derivations are a different act — producing graph _values_ — and belong to
> [nix-dynamic-derivations].

## Overview

### What it solves

A build file is a claim about the future: these outputs need these inputs. The
claim is expensive to maintain by hand and routinely wrong in both directions
([perfect-dependencies] §1). Autogeneration replaces it with either a **trace** —
what the previous run actually read and wrote, consulted to decide whether to run
again — or a **generated description** — a `BUILD` file derived from the sources,
which the engine treats exactly as if a person had written it. They are not
interchangeable: a trace is scoped to one execution, while a generated description
is a durable, reviewable input to a different scheduler.

### Design philosophy

The tracing camp removes the declaration entirely:

> "To write a Rattle build system you need to write a script that builds your
> code. No dependencies, no targets, just a straight-line script that builds
> your code."
>
> — Rattle [`README.md`][rattle-readme]

fabricate states the same promise as a feature list — "Never have to list
dependencies." — and implements it in one Python file plus a JSON store
([`fabricate.py`][fabricate-py]). The generation camp accepts the declaration but
refuses to type it:

> "Gazelle generates and updates Bazel `BUILD` files. It can create new `BUILD`
> files for a project that follows language conventions, and it can update
> existing `BUILD` files to include new sources, dependencies, and options."
>
> — [`README.md`][gazelle-readme]

Neither camp eliminates the hard question; each moves it. Tracing moves it to
whether the tracer saw everything. Generation moves it to whether the parser saw
everything, and to what happens to the parts of the file a human owns.

## What a generator actually generates

A surprising number of "build generators" generate no build file at all, and the
tracing systems generate no tasks — only arrows.

| System         | Generates                      | Product                       | Committed? | Enforcement / escape                        |
| -------------- | ------------------------------ | ----------------------------- | ---------- | ------------------------------------------- |
| fabricate      | edges only (observation)       | `.deps` JSON                  | no         | `ignore`, `inputs_only`, `always_runner`    |
| tup            | edges only (observation)       | `.tup/db` (`normal_link`)     | no         | fatal undeclared read/write; `^` flags      |
| Rattle         | edges only (observation)       | `.rattle/` traces             | no         | `Read`/`Write` options; hazard restart      |
| redo           | edges only (explicit calls)    | `.redo/db.sqlite3` (`Deps`)   | no         | `redo-always`, `redo-stamp`                 |
| Gazelle        | tasks and edges (static parse) | `BUILD` / `BUILD.bazel`       | **yes**    | `# keep`, `resolve`, `ignore`, `-mode=diff` |
| Pants v2       | tasks and edges (static parse) | in-memory graph, action cache | no         | explicit `dependencies`                     |
| GN             | tasks only (lowering)          | `build.ninja`                 | no         | regeneration depfile                        |
| Bazel scan     | input refinement               | action input set              | per action | —                                           |
| Buck2 dep file | input refinement               | dep file                      | per daemon | tag inputs; under-report is silent          |

The first four answer "what did the last run do?"; Gazelle and Pants answer "what
do the sources say?"; the last three do not autogenerate a graph at all. GN lowers a
hand-written model to Ninja ([gn] §"The generated plan, and the loop back"). Catalog
inference: a stale `build.ninja` is a stale _lowering_ of a correct model, whereas a
stale synthesized edge set is a wrong _model_.

### 1. Observation: the trace is the graph

**fabricate.** `run()` executes a command only if its recorded inputs or outputs
changed, and the builder hashes both into `.deps` as `path → input-<md5>` or
`output-<md5>`, keyed by command line; `deps_version = 2` invalidates the file when
the format changes ([`fabricate.py`][fabricate-py]). `autoclean` walks the same
table and deletes every recorded output. The task description — the Python script —
is never generated, and the trace never becomes a file anyone edits.

`SmartRunner` picks the observation grade: `StraceRunner` if `strace` exists,
otherwise `AtimesRunner`, otherwise `AlwaysRunner`, which never skips. The `strace`
runner traces a fixed set — `open`, `openat`, `stat`, `lstat`, `execve`,
`exit_group`, `chdir`, `mkdir`, `rename`, `clone`, `vfork`, `fork`, `symlink`,
`creat` and the `64` variants — but not `getdents`/`readdir`, `access` or `readlink`,
so directory listings and symlink resolution fall outside the trace. The atime
fallback warns that when a subdirectory is mounted on a file system that does not
support atimes, "the build may fail to identify a dependency"
([`fabricate.py`][fabricate-py]).

**tup.** tup makes the two kinds of edge different rows: `sticky_link` holds inputs
declared in a `Tupfile`, `normal_link` holds reads observed at execution.

> "Inputs listed in the Tupfile only enforce ordering among the commands, while
> file accesses during execution determine when commands are re-executed."
>
> — [`tup.1`][tup-manual]

The synthesized graph is the durable artifact — one SQLite database, queried and
rewritten every update ([tup] §"A DAG in one SQLite file"). It can be exported,
but only as a one-shot: `tup generate` "will parse all Tupfiles and create a shell
script that can build the program without running in a tup environment", and "The
shell script does not work incrementally, so it is effectively a one-time use";
`tup graph` prints the database as Graphviz ([`tup.1`][tup-manual]). Neither writes
a `Tupfile` back.

**Rattle** is the limiting case: it records each command's reads and writes with
content hashes and never materializes a graph. Every command is considered on every
build; skipping is a per-command hash comparison, and parallelism comes from
speculating on the previous run's order ([rattle] §"Rebuilding, hashing and
forwarding"). Nothing enters the source tree, so the generated-file problem
disappears and tracer completeness appears in its purest form: a missed access is a
silent missed rebuild ([perfect-dependencies] §3.5).

**BuildXL** is the industrial version of the same bet: runtime file-access
monitoring feeds caching and distribution, so an under-declared legacy build still
caches correctly ([buildxl] §2; [sandboxing-overheads]). Its observation is one part
of a full execution service; fabricate's and Rattle's are not.

### 2. Declaration during execution: the script writes its own edges

redo needs no tracer because the edge is a side effect of the build language.
`redo-ifchange` both builds a target and records a `Deps` row; a failed build or a
newer `changed_runid` makes the caller dirty ([redo] §"The verbs and what they
record"). The list is written _while running_, so it is exact for that run — the
author still had to name the file, but at the point of use rather than in a header.
Shake's `need` is the same primitive in a Haskell DSL ([concepts] §1), and PIE
turns the idea into a scheduler ([pie]).

Catalog inference: this is the cheapest generator of the three, needing neither an
interposer nor a parser. Its weakness is that it is still a declaration —
`redo-ifchange` on the wrong file is Make's missing dependency, written closer to
the code; redo's guard is output discipline, not edge verification
([redo] §"The `.do` contract", §5).

### 3. Static analysis: the source writes the BUILD

Gazelle's pipeline is documented as five steps ([gazelle-how]). **Configure** parses
the existing `BUILD`, lists files and applies `# gazelle:exclude`/`.bazelignore`.
**Generate** asks a language extension for rules; the Go extension emits
`go_library`, `go_binary`, `go_test` and proto rules
([`language/go/generate.go`][gazelle-go-generate]). **Index** collects each rule's
import strings — `-index=lazy` visits only directories extensions ask for,
`-index=all` everything, `-index=none` conventions only. **Resolve** maps imports to
labels through the index and `# gazelle:resolve` overrides. **Write** formats to disk
(`-mode=fix`), stdout (`-mode=print`), or a diff (`-mode=diff`) ([gazelle-ref]).

What step two does _not_ do is rewrite the file from scratch. `merger.MergeFile`
matches generated rules to existing ones by kind and name (or an attribute such as
`importpath`), merges each attribute separately, and deletes a rule only when the
result is empty ([`v2/merger/merger.go`][gazelle-merger]). Mergeable attributes are
declared per kind, and the merge runs before and after resolution because `srcs` and
`importpath` affect indexing while `deps` is the output of resolution.

The escape hatch is a comment. `# keep` protects a rule, an attribute, or one string
inside a list:

> "Gazelle won't know what imports to resolve, so you may need to add
> dependencies manually with `# keep` comments."
>
> — [`gazelle-reference.md`][gazelle-ref]

`# gazelle:ignore` stops modification of a file, and
`# gazelle:generation_mode update_only` forbids creating files;
`# gazelle:map_kind` renames generated kinds while leaving existing rules alone
([gazelle-ref]); `-strict` fails CI on errors.

**Pants v2** reaches the same result without a file. Rust parsers under
`src/rust/dep_inference` derive file-to-file edges from Python, JavaScript and
Dockerfile source, merged with explicit `dependencies` in `resolve_dependencies`
([pants] §3). The graph is recomputed and cached, never committed: no merge problem,
no reviewable artifact, inference bound to the daemon.

**Bazel and Buck2** refine edges without promoting them to declarations. Bazel's
include scanner registers `#include`d headers and C++ `.d` files record what the
compiler used ([dependency-pruning] §3); Buck2 dep files record a used subset per
action ([buck2] §3). These feed the _same_ action's cache key, not a new description.

## Correctness of synthesized edges

### Two approximations and their failure directions

Let `E*` be the accesses a command would make on this run. Tracing can only produce
`E_obs ⊆ E*`: it reports what happened, never what would have happened under a
different input. Static analysis typically produces `E_gen ⊇ E_used`, because a
parser sees imports a configuration may not use; but it can also under-approximate,
and it can produce a _label that names the wrong target_, which is neither.

| Source               | Relation to truth                   | If it is wrong                               | Who notices                      |
| -------------------- | ----------------------------------- | -------------------------------------------- | -------------------------------- |
| Observation          | `E_obs ⊆ E*` for the observed run   | a later build skips a needed action          | nobody — the output is stale     |
| Execution-time claim | author's claim about this run       | same as observation, but authored            | nobody, unless the engine checks |
| Static analysis      | usually `⊇`, sometimes `⊂` or wrong | missing dep → build error; extra → overbuild | the engine or compiler, often    |

A trace error is trusted by the engine; a generated-`BUILD` error is usually executed
and caught, but only where the executor is strict — Bazel's Java classpath is
transitive, so a missing direct dependency still compiles, hence `--strict_java_deps`
([dependency-pruning] §1).

### The trace is a bet on the next run

| Failure                           | Mechanism                                                                    | Consequence                                                     | Source                                  |
| --------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------- | --------------------------------------- |
| The tracer cannot see the process | `LD_PRELOAD` misses Go and static binaries; macOS SIP blocks system binaries | a read is never recorded; the command skips wrongly             | Rattle §3.5, via [perfect-dependencies] |
| The syscall is not on the list    | fabricate traces a fixed set; `getdents`, `access` and `readlink` are absent | a new file in a listed directory does not invalidate the lister | [`fabricate.py`][fabricate-py]          |
| Atime resolution is coarse        | FAT stores atime at one-day resolution; a submount may not update it at all  | "the build may fail to identify a dependency"                   | [`fabricate.py`][fabricate-py]          |
| The command is non-deterministic  | a trace samples a relation that depends on time, environment or randomness   | skip when a fresh run would differ                              | Rattle §2.4, via [perfect-dependencies] |
| The first build has no trace      | nothing has been observed yet                                                | declarations must already be correct                            | [tup] §Weaknesses                       |

The rows above are why most tracing systems trust the trace blindly. tup instead
makes it enforceable: an undeclared generated read fails because "without the input
link the commands may execute out of order", and an undeclared write fails with "was
written to, but is not in .tup/db" ([tup] §3). fabricate and Rattle accept whatever
the tracer reports and call it a dependency ([rattle] §5).

### The generated file is a fixpoint, not a projection

Gazelle's input includes the existing `BUILD`, so it is an iteration
`BUILD_{n+1} = f(BUILD_n, sources)`, and what matters is that it reaches a fixpoint
quickly. The merger is built for that — matching by kind and name, per-attribute
mergeability, `# keep` to pin a value, `-mode=diff` to observe whether a rerun would
change anything, `-strict` to fail CI when it would ([gazelle-merger], [gazelle-ref]).
A whole-file rewrite would be a pure projection and easier to reason about, but it
would delete every hand-written attribute the generator does not understand.

Catalog inference: three properties follow, none automatic. **Idempotence** — running
twice must not change the file twice; `-mode=diff` is the test. **Ownership** — every
attribute must be classified mergeable or not, or a human edit is lost or blocks
updates forever. **Convergence under conflict** — extensions generating the same rule
must agree, which is why `Kinds` metadata and extension order are part of the
contract ([gazelle-how]).

The review gate cuts both ways: a bad edge is visible in a diff, but the same commit
is build-maintenance work. The large-scale study excludes generated low-level
specifications from its churn counts, assuming "generated low-level specifications
are not committed" ([build-maintenance] §8.1). Catalog inference: a repository that
commits Gazelle output is invisible to that study's headline numbers.

## What it costs, as published

| What is paid                            | Published figure                                                               | Source                                |
| --------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------- |
| Observing a command with `fsatrace`     | +5 percentage points over `make -j1` on Linux; +21 on Windows                  | [perfect-dependencies] §5.2           |
| The full Rattle stack                   | 107% of Make on Linux, 146% on Windows (plumbing only, no incrementality test) | [perfect-dependencies] §5.2           |
| fabricate's tracing overhead            | no figure published                                                            | [`README.md`][fabricate-readme]       |
| A no-change tup update with the monitor | "about 2 or 3ms when everything is in the disk cache"                          | [`tup.1`][tup-manual]                 |
| Gazelle with lazy indexing              | "milliseconds rather than seconds or minutes" for targeted directories         | [`extend.md`][gazelle-extend]         |
| Gazelle with `-index=all`               | "can take a long time in large repositories"                                   | [`how-gazelle-works.md`][gazelle-how] |
| Review and merge churn                  | no figure; generated specs are excluded from the maintenance study             | [build-maintenance] §8.1              |

The tracing numbers are the only ones measured against a baseline. Gazelle publishes
latency for its own invocation, not a before/after build-time comparison, and no
reviewed source measures adoption of a `BUILD` generator.

## Strengths

- **Tracing cannot be wrong about the run it observed.** No parser competes with an
  actual read; Rattle's whitespace-edit result — one compile where Make rebuilt a
  cascade — is the measured ceiling ([perfect-dependencies] §5.1).
- **Tracing never touches the source tree.** No merge, no `# keep`, no
  generated-file review, no risk of overwriting intent — a large advantage the
  static camp pays for in merge machinery.
- **Generation is reviewable and portable.** A committed `BUILD` is an artifact a
  second engine can read, a human can diff, and CI can check with `-mode=diff`; a
  `.deps` file is meaningful only to the tool that wrote it.

## Weaknesses

- **Each is only as good as its observation.** A tracer's blind spots are silent
  (Go and static binaries, directory listings, coarse atimes); a parser's are the
  generated `.go` file whose imports Gazelle cannot resolve, repaired by a human
  comment ([perfect-dependencies] §3.5, [gazelle-ref]). Only tup converts a
  seen-but-undeclared access into a build error, because it owns both edge kinds
  ([tup] §3).

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                      | Trade-off                                                   |
| -------------------------------------------------- | -------------------------------------------------------------- | ----------------------------------------------------------- |
| Key the trace on the command line                  | No target names to invent; a changed flag is a different entry | Script edits are invisible; no subtree build key            |
| Keep observed and declared edges as separate kinds | Ordering and invalidation are different questions              | Two graphs to maintain; the declared one can still be wrong |
| Record content hashes, not mtimes                  | Touch-immunity and early cutoff fall out of the store          | Hashing cost; atime fallback is much weaker                 |
| Enforce undeclared access fatally                  | Makes the trace trustworthy enough to be the graph             | Tools with surprise outputs need exclusions or fail         |
| Generate rules and merge into the existing file    | Preserves hand-written attributes the generator cannot model   | The generator becomes a fixpoint with an ownership protocol |
| Commit the generated `BUILD`                       | Reviewable, diffable, usable by another engine                 | Churn; generated files escape maintenance metrics           |
| Recompute inference in memory                      | No merge problem, always consistent with the sources           | No reviewable artifact; bound to one daemon                 |

## Sparkles relevance

`sparkles.build_primitives` starts from declarations. `workspace/package_graph.d`
reads each root `dub.sdl` through the `dub_manifest` schema and builds the package
graph purely from the active configuration's declared dependencies; unknown
dependencies, self-dependencies and cycles are validated
(`libs/build-primitives/src/sparkles/build_primitives/workspace/package_graph.d`).
`task/graph.d` admits only validated `TaskGraph` values, and `writePlan` renders the
dry-run projection with each edge's condition and reason
(`libs/build-primitives/src/sparkles/build_primitives/task/graph.d`).
Nothing observes a process, and nothing writes a manifest.

That makes the first lesson the relevant one: **keep the declaration the source of
truth.** Every tracing system here leaves the task description to a human and
synthesizes only the arrows; Gazelle generates rules and pays with a merge protocol.
A compiler that emitted `dub.sdl` files would inherit that protocol without
Gazelle's attribute-merge rules.

- **Use a trace as a checker, not an emitter.** Rattle's `Profile.createEdge`
  reconstructs write-write and read-write edges after the run ([rattle] §"Hazards in
  practice"). The Sparkles analogue validates a declared `TaskGraph` against what a
  run touched, and reports; it needs no persistence beyond one run.
- **If a generator is ever built, copy the merge contract, not the format.**
  Per-attribute ownership, a keep marker for human intent, and a `--check`/diff mode
  in CI are the portable parts ([gazelle-merger], [gazelle-ref]); the `BUILD` syntax
  is incidental. D comments (`/+ … +/`) are available for a marker, but inventing one
  is a design decision, not a port.
- **Two edge kinds, if persistence arrives.** `TaskEdge` today has one notion of
  dependency, carrying `EdgeCondition` and `EdgeReason`
  (`libs/build-primitives/src/sparkles/build_primitives/task/model.d`).
  tup's split — declared edges order work, observed edges decide staleness — is the
  smallest model that does not over- or under-invalidate ([tup] §3). Adding
  `reason = observedRead` would conflate them.

Catalog inference: the immediate cheap win is not a generator but an **audit**.
`package_graph.d` already knows every declared in-tree dependency, and a `dub`-aware
import scan can compare the two without a tracer or parser dependency
([dependency-pruning] §"Sparkles relevance"). It reports over-declaration;
under-declaration still needs strict checking or an observed read set, and neither
exists in `sparkles:build-primitives` today.

## Sources

**Pages synthesized.** [concepts] (trace vocabulary and tup's placement),
[perfect-dependencies] §3.5/§5.2 (tracer blind spots and plumbing overhead),
[rattle] (trace store, `Profile.createEdge`), [tup] §3 (two edge kinds,
enforcement, `tup generate`), [redo] §"The verbs and what they record", [pants] §3,
[bazel] and [buck2] §3 (action-input refinement), [gn] (lowering), and the theme
pages [build-maintenance] §8.1, [dependency-pruning] §1/§3, [sandboxing-overheads],
[dynamic-deps-distributed], [pie], [nix-dynamic-derivations].

**Primary sources fetched.** fabricate at
`24a3acfc86129fda56c48a6ec1594e2cd5cd8e0c` — [`README.md`][fabricate-readme],
[`fabricate.py`][fabricate-py] (version 1.29.3; `deps_version = 2`; the runner
classes; `AtimesRunner.has_atimes`). Gazelle at
`6b575b681f2a05257f04e98c02e83b92c1fb766f` — [`README.md`][gazelle-readme],
[`how-gazelle-works.md`][gazelle-how], [`gazelle-reference.md`][gazelle-ref],
[`extend.md`][gazelle-extend], [`language/go/generate.go`][gazelle-go-generate],
[`v2/merger/merger.go`][gazelle-merger]. tup at
`c6f565e216a0820e39d65fa84ddaf830be03a476` — [`tup.1`][tup-manual] (`generate`,
`graph`). Clones under `$REPOS/build-systems-research/src/` at the SHAs their
deep-dives cite.

**Catalog inference is marked in place**; the two-approximation framing, the
fixpoint account of merger correctness, the lowering-versus-generation distinction,
and the Sparkles recommendations are this page's analysis, not claims any cited
source makes.

<!-- References -->

[concepts]: ./concepts.md
[perfect-dependencies]: ./perfect-dependencies.md
[rattle]: ./rattle.md
[tup]: ./tup.md
[redo]: ./redo.md
[pants]: ./pants.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[buildxl]: ./buildxl.md
[gn]: ./gn.md
[build-maintenance]: ./build-maintenance.md
[dependency-pruning]: ./dependency-pruning.md
[sandboxing-overheads]: ./sandboxing-overheads.md
[dynamic-deps-distributed]: ./dynamic-deps-distributed.md
[pie]: ./pie.md
[nix-dynamic-derivations]: ./nix-dynamic-derivations.md
[fabricate-readme]: https://github.com/brushtechnology/fabricate/blob/24a3acfc86129fda56c48a6ec1594e2cd5cd8e0c/README.md
[fabricate-py]: https://github.com/brushtechnology/fabricate/blob/24a3acfc86129fda56c48a6ec1594e2cd5cd8e0c/fabricate.py
[gazelle-readme]: https://github.com/bazel-contrib/bazel-gazelle/blob/6b575b681f2a05257f04e98c02e83b92c1fb766f/README.md
[gazelle-how]: https://github.com/bazel-contrib/bazel-gazelle/blob/6b575b681f2a05257f04e98c02e83b92c1fb766f/how-gazelle-works.md
[gazelle-ref]: https://github.com/bazel-contrib/bazel-gazelle/blob/6b575b681f2a05257f04e98c02e83b92c1fb766f/gazelle-reference.md
[gazelle-extend]: https://github.com/bazel-contrib/bazel-gazelle/blob/6b575b681f2a05257f04e98c02e83b92c1fb766f/extend.md
[gazelle-go-generate]: https://github.com/bazel-contrib/bazel-gazelle/blob/6b575b681f2a05257f04e98c02e83b92c1fb766f/language/go/generate.go
[gazelle-merger]: https://github.com/bazel-contrib/bazel-gazelle/blob/6b575b681f2a05257f04e98c02e83b92c1fb766f/v2/merger/merger.go
[tup-manual]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/tup.1
[rattle-readme]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/README.md
