# Ninja (C++, build executor)

Ninja's engine in one sentence: it reads one generated edge list into a graph, walks it twice —
a recursive dirty scan, then a priority queue of ready edges — and remembers each output in two
append-only logs whose only job is to make the _next_ process start cheaply.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                                  |
| --------------------- | -------------------------------------------------------------------------------------- |
| Language              | C++17 (`configure.py`, `CMakeLists.txt`); the manifest language is Ninja's own         |
| License               | Apache-2.0 (`COPYING`)                                                                 |
| Repository            | [`ninja-build/ninja`][repo]                                                            |
| Documentation         | [`doc/manual.asciidoc`][manual]                                                        |
| Category              | Executor / build engine; companion to [Ninja (monorepo-tooling)][mono-ninja]           |
| Clone (pinned)        | `$REPOS/build-systems-research/src/ninja`                                              |
| Commit                | `a7d7504e98d07f05a60f37411206907c00cb4ef7` (2026-11-01); **the clone has no tags**     |
| Version in tree       | `kNinjaVersion = "1.14.0.git"` ([`src/version.cc`][version])                           |
| Scheduler × rebuilder | Topological × verifying traces ([concepts] §5), with two qualifications below          |
| Persistent state      | `.ninja_log` (text, v7), `.ninja_deps` (binary, v4), `.ninja_lock` (the command clock) |

> [!NOTE]
> **Delta against the workspace page.** [Ninja (monorepo-tooling)][mono-ninja] covers the
> format, `-t` tooling, the CLI, pools as a user knob, and the no-package-manager verdict;
> this page stays inside the process: the logs, the dirty ladder, `dyndep`, and the queue.

## Overview

### What it solves

> "Ninja is a small build system with a focus on speed."
>
> — [`README.md`][readme]

The manual locates the speed in _not deciding_:

> "Where other build systems are high-level languages, Ninja aims to be an assembler."
>
> — [`doc/manual.asciidoc`][manual]

### Design philosophy

**The graph is an input, not a result** — nothing is found by walking the tree, resolving
packages, or evaluating a language; post-parse additions come only from a depfile (second
build onward) or a `dyndep` file (during the first). **Memory is a log** — both databases are
appended, read whole, versioned, compacted by threshold, repaired by deletion. **Dirtiness is
a comparison of numbers** — mtimes plus one hash of the command string.

## How it works

### Scan, then schedule

`Builder::AddTarget` runs `DependencyScan::RecomputeNodeDirty` over the closure — a DFS marking
edges `VisitInStack` (the cycle detector) and `VisitDone`, applying the ladder below — and only
then does `Plan::PrepareQueue` fill the ready queue.

### `.ninja_log`: one line per output, keyed by command hash

> "Each run's log appends to the log file. To load, we run through all log entries in
> series, throwing away older runs. Once the number of redundant entries exceeds a
> threshold, we write out a new file and replace the existing one with it."
>
> — [`src/build_log.cc`][build-log]

`# ninja log v7`, then tab-separated `start_time  end_time  mtime  output  command_hash`.
`kOldestSupportedVersion` and `kCurrentVersion` are both `7`, so any other version is deleted
with "build log version is too old/new; starting over" — a missing log costs a rebuild, never
correctness. The hash is `rapidhash` over `EvaluateCommand(/*incl_rsp_file=*/true)`, so a
response file's _contents_ invalidate the edge too.

The `mtime` field is a _known-current_ timestamp, not the output's mtime: the command's start
clock, raised to the newest post-build output mtime for `restat`/`generator` edges and reset
when `restat` cleaned a node. Comparing it against the newest input catches interrupted runs.

### `.ninja_deps`: a binary id table

`# ninjadeps\n` + `int32` version `4` (the version doubles as a byte-order mark, so the header
is 16 bytes). Two record kinds share a 32-bit size word: a **path record** (path padded to 4
bytes, then a checksum of `~id`) assigns a node its integer id; a **deps record** sets the high
bit (`size |= 0x80000000`) and stores `out_id, mtime_lo, mtime_hi, input ids…`
([`src/deps_log.cc`][deps-log]). Loading is forgiving: a bad signature or version deletes the
file, and a truncated record truncates to the last fully read offset and continues with
`"…; recovering"`. An entry is used only while the output is no newer than `deps->mtime`;
otherwise "stored deps info out of date" and the edge is dirty ([`src/graph.cc`][graph]).

### `restat`: an mtime proxy for early cutoff

> "if present, causes Ninja to re-stat the command's outputs after execution of the command.
> Each output whose modification time the command did not change will be treated as though it
> had never needed to be built. This may cause the output's reverse dependencies to be
> removed from the list of pending build actions."
>
> — [`doc/manual.asciidoc`][manual]

`StartCommand` writes a one-byte `.ninja_lock` and stats it, storing that timestamp as
`edge->command_start_time_` ([`src/build.cc`][build-cc]) — a _file system_ clock, comparable
with the mtimes it will be checked against. `FinishCommand` compares each output's **pre-build**
mtime (cached by the scan) with its post-build mtime; equality means the command did not
rewrite the file (or never created it), and `Plan::CleanNode` clears the dirty flag, re-checks
each dependent whose non-order-only inputs are all clean, and removes clean edges from the plan.
Next run the log decides: a `restat` edge's file mtime is ignored, and the recorded mtime is
compared to the newest input ([`src/graph.cc`][graph]).

So `restat` is early cutoff by proxy: _mtime unchanged_ stands in for _value unchanged_ — full
pruning for a generator that writes only on change, none for one that rewrites identical bytes,
and no way to tell "never touched" from "same content".

### `dyndep`: the graph patched mid-build

> "Ninja will update the build graph accordingly and the build will proceed as if the
> information was known originally."
>
> — [`doc/manual.asciidoc`][manual]

A `dyndep` binding names an input; when its producer finishes, `Plan::EdgeFinished` calls
`Builder::LoadDyndeps` before re-checking dependents ([`src/build.cc`][build-cc]) — or at scan
time if it is already ready ([`src/graph.cc`][graph]). `UpdateEdge` appends implicit outputs,
inserts implicit inputs _before_ the order-only tail, and adds a `restat` binding when asked —
a late-arriving early-cutoff flag ([`src/dyndep.cc`][dyndep]). The file is Ninja syntax:
`ninja_dyndep_version = 1.0` and one `build out | imp-outs : dyndep | imp-ins` statement per
edge, one-to-one with the manifest ([`src/dyndep_parser.cc`][dyndep-parser]). The topological
invariant is the manual's: a dyndep file "may not change the build graph in a way that causes
up-to-date build statements to become out-of-date".

### `pool`: a delayed set, not a thread pool

`Pool` holds `depth_`, `current_use_`, and a `delayed_` set ([`src/state.h`][state-h]); depth
`0` means infinite and is the default. An edge in a finite pool is first delayed by
`ScheduleWork`, then released by `RetrieveReadyEdges` while `current_use_ + weight <= depth_`;
`EdgeFinished` releases and retrieves again ([`src/state.cc`][state-cc]). The delayed set is
ordered by weight, then by the ready queue's comparator, so a full pool returns its most
critical edge first. `weight()` is always `1`, making pools concurrency counts, not resource
vectors; `console` has depth 1 and grants its task the terminal. `ComputeCriticalPath` orders
the queue by previous `end_time - start_time`, propagated from consumers to producers, ties
broken by ascending edge id ([`src/build.cc`][build-cc], [`src/graph.h`][graph-h]).

## Analysis spine

### Placement in the scheduler × rebuilder grid

[Concepts] §5 puts Ninja at topological × verifying traces, the right cell for the _shape_:
every dependency is known before any command runs, and each key carries a record checkable
without re-execution. The trace is thinner than the paper's — it hashes the **command**, not
dependency values, and verifies inputs by mtime, so "changed and changed back" is invisible.
The cell is reached with two documented escapes, depfiles (second build) and `dyndep` (first),
which mutate the graph without changing the scheduler's nature: dependents are re-checked, then
scheduled.

### 1. Task model & scheduling

- **The task is an edge; the command is a string** — a `rule` template plus edge bindings,
  rendered by `EvaluateCommand`; nothing is typed, interpreted, or inspected.
- **Topological and iterative**, with `VerifyDAG` reporting the `a -> b -> a` path before any
  work starts ([`src/graph.cc`][graph]); **no speculation**, only ready edges are queued.
- **Parallelism is process-level** — one thread drives `CommandRunner`, bounded by `-j`, `-l`,
  pools, and jobserver tokens. At this SHA Ninja is also a jobserver _server_
  (`--jobserver-pool`), so the workspace page's "client-only" note is stale
  ([`doc/manual.asciidoc`][manual]).

### 2. Rebuilding & correctness

The ladder in `RecomputeOutputDirty` ([`src/graph.cc`][graph]), in order:

| #   | Test                                                         | Explains as                                 |
| --- | ------------------------------------------------------------ | ------------------------------------------- |
| 1   | output missing                                               | `output %s doesn't exist`                   |
| 2   | output older than newest input (skipped for logged `restat`) | `output %s older than most recent input %s` |
| 3   | command hash differs (skipped for `generator`)               | `command line changed for %s`               |
| 4   | recorded log mtime older than newest input                   | `recorded mtime of %s older than …`         |
| 5   | no log entry (skipped for `generator`)                       | `command line not found in log for %s`      |

Each branch records a string for `-d explain` ([`src/explanations.h`][explain]), so "why did
this rebuild?" is answered by the engine. **Minimality** holds as "at most once per build",
over-approximated by mtime; early cutoff exists only through `restat`'s proxy. **Correctness**
leans on the command hash for recipes and mtimes for inputs; neither covers the environment, the
toolchain binary, or an undeclared input.

### 3. Dependency discovery

- **Declared** statically; **observed** for headers via `depfile`/`deps` into `.ninja_deps`;
  **dynamic** for Fortran and C++20 modules via `dyndep`. **No syscall interception, no FUSE, no
  sandbox observation** in `src/`; an undeclared read simply succeeds.
- **Strictness is a diagnostic**: `-t missingdeps` reports targets that consume a generated file
  without a transitive dependency on its generator ([`src/missing_deps.cc`][missing-deps]) and
  does not fail the build.
- **The first build is the weak point**: header dependencies are correct only from the second
  build on, enforced by the deps-log mtime check rebuilding on a miss.

### 4. Store & caching

- **The output tree is the store** — no CAS, no action cache, no content key; a log entry is
  keyed by output path and validated by command hash.
- **Three manual tools**: `-t recompact` rewrites both logs densely, `-t cleandead` deletes files
  the manifest no longer produces ([`src/ninja.cc`][ninja-cc]), `-t restat` rewrites recorded
  mtimes from disk — a repair for drifted timestamps, not a build mode.

### 5. Hermeticity & provenance

- **No sandbox of any kind.** Commands inherit environment and working directory; the only
  bookkeeping file besides the logs is `.ninja_lock`, written for its mtime. **The only
  hermeticity is the command hash** — recipe text including response-file contents, not the
  world the recipe runs in.
- **Provenance: nothing** — no `SLSA`, no `in-toto`, no attestation or signature in the clone;
  the logs record what ran and how long, not who ran it or what it read.

### 6. Distribution

Absent by design: no network code in `src/`, no REAPI client, no remote cache. The one
cross-process protocol is the GNU Make jobserver — a shared token pool, not action distribution
— and the workaround lives outside the engine (`ccache`/`sccache`, a REAPI rewrapper, or a
replacement executor).

### 7. Sparkles relevance

The in-process DAG in `libs/build-primitives/src/sparkles/build_primitives/task/` keeps no
state between runs, so Ninja is the smallest useful model for a first increment of persistence,
not a design to imitate wholesale.

- **Copy the log discipline, not the format.** Append-only records plus threshold compaction
  buys crash tolerance in a few hundred lines; deleting on a version mismatch is the right
  failure mode when the log is only a cache.
- **Copy `restat`'s propagation, not its proxy.** "All inputs clean and outputs unchanged ⇒
  this edge and its dependents are not wanted" is the cheap early cutoff a task DAG wants;
  keying it on content removes the false negatives without changing the propagation.
- **Copy the load-order rule**: loading discovered dependencies only when an edge is otherwise
  clean saves real time incrementally.
- **Do not copy mtime as the dirty key.** `-t restat`, `-t missingdeps`, and the "first build is
  wrong" caveat are the price of a dirty bit that cannot see content.

## Strengths

- **Sub-second startup at scale from two small files** — a text log and a compact id table.
- **Restart is cheap and safe**: any broken log degrades to a rebuild, never a wrong build.
- **`restat` prunes a cascade without hashing**, and **`dyndep` adds first-build dynamic
  dependencies** inside a topological scheduler, with an invariant that keeps clean statements
  clean.

## Weaknesses

- **mtime is the weakest link**: touched files over-build, restored mtimes under-build, and
  `restat` cannot tell "same bytes" from "not rewritten".
- **No content identity anywhere**, so nothing is shareable across machines and a toolchain
  upgrade that leaves the command string unchanged is invisible.
- **No sandbox, so undeclared reads are silent**; `-t missingdeps` diagnoses one subset.
- **Graph mutation has ordering hazards**: `dyndep` correctness depends on the manifest
  declaring the file as an input, and the manual must forbid backward invalidation.

## Key design decisions and trade-offs

| Decision                                   | Rationale                                                         | Trade-off                                                          |
| ------------------------------------------ | ----------------------------------------------------------------- | ------------------------------------------------------------------ |
| Append-only logs with threshold compaction | O(1) restart; a crash leaves a prefix, not a corrupt structure    | Two formats and two policies; `-t recompact` is manual             |
| Delete a log whose version is unknown      | The log is a cache; rebuilding is always correct                  | A Ninja upgrade can force a full rebuild                           |
| Command hash instead of input hashes       | One hash per edge from text alone; no I/O                         | Cannot see environment, toolchain, or input content                |
| mtime plus log mtime as the dirty bit      | Cheapest possible comparison; no digesting                        | Over-builds on touch, under-builds on restored timestamps          |
| `restat` as mtime-equality early cutoff    | Codegen that writes only on change prunes dependents for free     | Identical-content rewrites get no cutoff; the proxy is invisible   |
| `dyndep` patches the graph mid-build       | First-build module correctness without a restarting scheduler     | One-to-one file mapping, forward-only invariant, late `restat`     |
| No sandbox, no network, no CAS             | Tiny, portable, embeddable binary; policy pushed to the generator | Undeclared reads silent; sharing and remote execution live outside |

## Sources

- [`ninja-build/ninja`][repo] at commit `a7d7504e98d07f05a60f37411206907c00cb4ef7`
  (2026-11-01), clone at `$REPOS/build-systems-research/src/ninja`; quotes are verbatim from
  the cited files.
- Read in the clone: [`README.md`][readme], [`doc/manual.asciidoc`][manual]; [`src/build_log.cc`][build-log],
  [`src/deps_log.cc`][deps-log], [`src/dyndep.cc`][dyndep], [`src/dyndep_parser.cc`][dyndep-parser],
  [`src/graph.cc`][graph], [`src/graph.h`][graph-h], [`src/build.cc`][build-cc], [`src/build.h`][build-h],
  [`src/state.h`][state-h], [`src/state.cc`][state-cc], [`src/ninja.cc`][ninja-cc],
  [`src/explanations.h`][explain], [`src/missing_deps.cc`][missing-deps], [`src/version.cc`][version];
  tests `src/build_test.cc` (`Restat*`, `Dyndep*`) and `src/deps_log_test.cc`.
- Siblings: [concepts] (the scheduler × rebuilder vocabulary), [GN][gn] (the generator that
  emits the plan), [Shake][shake] (the traced-dependency contrast), [Bazel][bazel] (the
  content-addressed contrast); workspace views [Ninja][mono-ninja] and [GN][mono-gn].

<!-- References -->

[repo]: https://github.com/ninja-build/ninja
[readme]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/README.md
[manual]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/doc/manual.asciidoc
[version]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/version.cc
[build-log]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/build_log.cc
[deps-log]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/deps_log.cc
[dyndep]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/dyndep.cc
[dyndep-parser]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/dyndep_parser.cc
[graph]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/graph.cc
[graph-h]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/graph.h
[build-cc]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/build.cc
[build-h]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/build.h
[state-h]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/state.h
[state-cc]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/state.cc
[ninja-cc]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/ninja.cc
[explain]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/explanations.h
[missing-deps]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/src/missing_deps.cc
[concepts]: ./concepts.md
[gn]: ./gn.md
[shake]: ./shake.md
[bazel]: ./bazel.md
[mono-ninja]: ../monorepo-tooling/ninja/
[mono-gn]: ../monorepo-tooling/gn/
