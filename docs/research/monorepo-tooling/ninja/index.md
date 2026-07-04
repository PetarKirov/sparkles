# Ninja (C/C++/native)

A deliberately minimal, maximally-fast build _executor_ — "an assembler for
build systems" — that consumes a machine-generated `build.ninja` graph and runs
the commands needed to bring it up to date, with near-instant incremental
rebuilds at Chromium scale.

| Field           | Value                                                                                                                            |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Language        | `C++` (C++11; a ~10k-line single binary, no runtime dependencies)                                                                |
| License         | Apache-2.0 ("Copyright 2011 Google Inc.")                                                                                        |
| Repository      | [`ninja-build/ninja`][repo]                                                                                                      |
| Documentation   | [`Ninja` manual][manual] · [`ninja-build.org`][home]                                                                             |
| Category        | Native Build System                                                                                                              |
| Workspace model | Single generated `build.ninja` per output tree; no member list — the graph _is_ the workspace, composed via `subninja`/`include` |
| First released  | `Ninja` 1.0 in 2012 (Evan Martin, for the Chromium browser; first commit 2010)                                                   |
| Latest release  | `v1.13.2` (stable); `main` is `1.14.0.git` ([`src/version.cc`][version] — `kNinjaVersion = "1.14.0.git"`)                        |

> **Latest release (as of June 5, 2026):** the current stable line is **`v1.13.2`**
> (the `1.13.0` release of June 2025 landed [GNU Make jobserver][jobserver-blog]
> _client_ support after nine years of proposals; `1.13.1`/`1.13.2` are bug-fix
> point releases). The development tree on `main` reports `1.14.0.git`
> ([`src/version.cc`][version]). `Ninja` follows `major.minor.patch` where _"the
> major version is increased on backwards-incompatible syntax/behavioral changes
> and the minor version is increased on new behaviors"_ ([manual][manual]); a
> build file can pin a floor with `ninja_required_version = 1.13`.

---

## Overview

### What it solves

`Ninja` exists because the **edit-compile cycle on huge C/C++ trees was slow to
_start_** — not slow to compile, slow to _decide what to compile_. From the
manual's introduction ([`doc/manual.asciidoc`][manual]):

> _"It is born from my work on the Chromium browser project, which has over
> 30,000 source files and whose other build systems (including one built from
> custom non-recursive Makefiles) would take ten seconds to start building after
> changing one file. Ninja is under a second."_

The design conclusion was radical: strip the build _executor_ of every feature
that requires it to "make decisions" at build time, push all of that work into a
separate **generator** program (run once, up front), and leave `Ninja` with only
the barest machinery to describe and walk a dependency graph. `Ninja` is
therefore almost never invoked directly by a human writing build files; it is the
backend for [CMake][cmake], [Meson][meson], [`GN`][gn], Kati (Android), premake,
and many others — they emit `build.ninja`, `Ninja` runs it. The two-layer
generator+executor split, viewed from the generator side, is covered in the
[`GN` + `Ninja`][gn] deep-dive; **this page is about the executor itself** — its
file format, change-detection, scheduler, and the on-disk logs that make restart
cheap.

Within the survey, `Ninja` is the canonical **"dumb fast executor"** data point:
contrast the hermetic, content-addressed, package-managing engines
[Bazel][bazel]/[Buck2][buck2]/[Pants][pants], the sibling native generators
[CMake][cmake]/[Meson][meson]/[SCons][scons] that _target_ `Ninja`, and the
minimalist research tools [redo][redo]/[tup][tup] that Evan Martin explicitly
credits as influences.

### Design philosophy

The manual states the thesis in one sentence ([manual][manual]):

> _"Where other build systems are high-level languages, Ninja aims to be an
> assembler."_

and the operative rule that follows from it:

> _"Build systems get slow when they need to make decisions. … when convenience
> and speed are in conflict, prefer speed."_

The design goals are correspondingly austere: _"very fast (i.e., instant)
incremental builds, even for very large projects"_; _"very little policy about
how code is built"_; and _"get dependencies correct, and in particular situations
that are difficult to get right with Makefiles."_ The **non-goals** are the
revealing part ([manual][manual]):

> _"convenient syntax for writing build files by hand. **You should generate your
> ninja files using another program.** … built-in rules. **Out of the box, Ninja
> has no rules for e.g. compiling C code.** … build-time decision-making ability
> such as conditionals or search paths. **Making decisions is slow.**"_

So there is no `if`, no globbing, no functions, no search paths, no package
manager, no toolchain detection — none of it. A `.ninja` file is an intermediate
representation, like an object file: legible enough to debug, but written by a
machine. The whole tool is ~10k lines of dependency-free `C++` that compiles to a
single static binary, deliberately small enough to vendor.

---

## How it works

### The file format: `rule` + `build`

A `build.ninja` file has exactly two load-bearing constructs ([manual][manual]):
a **`rule`** (a named command template) and a **`build`** statement (one edge of
the DAG binding outputs to a rule and inputs).

```ninja
cflags = -Wall

rule cc
  command = gcc $cflags -c $in -o $out

build foo.o: cc foo.c
```

`$in` expands to the edge's inputs, `$out` to its outputs. _"Conceptually, `build`
statements describe the dependency graph of your project, while `rule` statements
describe how to generate the files along a given edge."_ Variables are
immutable **bindings** (_"a given variable cannot be changed, only shadowed"_) and
expand immediately — except inside a `rule`, where they expand **late**, when the
rule is _used_, so `$in`/`$out` and per-edge shadows resolve correctly.

The full edge syntax encodes the three dependency flavors and (since 1.7) implicit
outputs in punctuation:

```ninja
build out1 out2 | implicit_out : rulename in1 in2 | implicit_in || order_only_in |@ validation
```

| Token                | Meaning                                                                                                   |
| -------------------- | --------------------------------------------------------------------------------------------------------- |
| `out1 out2`          | **Explicit outputs** — appear in `$out`                                                                   |
| `\| implicit_out`    | **Implicit outputs** (1.7+) — built, but _not_ in `$out`                                                  |
| `in1 in2`            | **Explicit inputs** — appear in `$in`; a change rebuilds the output, a missing one aborts the build       |
| `\| implicit_in`     | **Implicit inputs** — same dirty semantics as explicit, but not in `$in` (e.g. a script's hardcoded file) |
| `\|\| order_only_in` | **Order-only inputs** — must be built _first_, but a change in them alone does **not** trigger a rebuild  |
| `\|@ validation`     | **Validations** (1.11+) — pulled into the build whenever the edge is, but their state never dirties it    |

Other declaration types: variable assignments, `default target…` (the targets
built when none are named), `pool name`, and the two file-composition keywords
`subninja path` / `include path` (below).

### Rule attributes that matter for monorepos

A handful of `rule` keys ([manual § Rule variables][manual]) carry the real
semantics:

- **`depfile`** — path to a Makefile-syntax dependency file the command writes
  (`gcc -MD -MF $out.d`). `Ninja` reads it to pick up **header dependencies it
  could not know statically**.
- **`deps = gcc` / `deps = msvc`** _(1.3+)_ — instead of re-reading `.d` files on
  every startup (slow, _"particularly on Windows, where the file system is
  slow"_), `Ninja` parses the compiler's dependency output _once_, immediately
  after the command finishes, and folds it into a compact binary database
  (`.ninja_deps`), deleting the `.d`. `msvc` parses `cl /showIncludes` stdout with
  a configurable `msvc_deps_prefix`.
- **`restat`** — _"causes Ninja to re-stat the command's outputs after execution.
  Each output whose modification time the command did not change will be treated
  as though it had never needed to be built"_ — pruning the downstream rebuild
  cascade when a regenerated file is byte-identical. (Generators set this on
  codegen edges.)
- **`generator`** — marks the rule that re-runs the meta-build; its outputs are
  _"not rebuilt if the command line changes"_ and not cleaned by default.
- **`rspfile` / `rspfile_content`** — write a response file before the command
  (Windows command-line-length workaround for huge link lines).
- **`pool`** — cap this rule's concurrency (below).

### Change detection: `mtime` + a command hash, not content hashing

`Ninja` _"evaluates a graph of dependencies between files, and runs whichever
commands are necessary to make your build target up to date **as determined by
file modification times**"_ ([manual][manual]). The dirty check, in
`DependencyScan::RecomputeOutputDirty` ([`src/graph.cc`][graph]), is a short
ladder. An output is rebuilt if:

1. it is **missing**;
2. its `mtime` is **older than the newest input** —
   `output->mtime() < most_recent_input->mtime()` ([`src/graph.cc:335`][graph]);
3. the **command line changed** — `Ninja` hashes the final command and compares it
   against the hash recorded in `.ninja_log`:

   ```cpp
   // src/graph.cc — RecomputeOutputDirty (abridged)
   if (!generator &&
       BuildLog::LogEntry::HashCommand(command) != entry->command_hash) {
     explanations_.Record(output, "command line changed for %s", …);
     return true;   // dirty: the recipe itself changed
   }
   ```

This is a deliberate divergence from the content-addressed engines: `Ninja`
**does not hash file contents by default**, so a touched-but-byte-identical input
_will_ trigger a rebuild (the `restat` attribute mitigates the cascade for
generators). The payoff is startup speed — comparing `mtime`s and one command
hash is far cheaper than digesting every file, which is the whole point at 30,000
files.

### Two on-disk logs make restart cheap

`Ninja` keeps two databases in `builddir` (default: the build root):

- **`.ninja_log`** — for every built output, the hash of the command used and the
  recorded start/end mtimes. Used for the command-changed check above _and_ to
  seed the **critical-path scheduler** with historical run times.
- **`.ninja_deps`** — the compacted header-dependency database produced by `deps =
gcc/msvc`. It is a binary log of path records and per-output dependency records,
  with the version stamped in the header (`kCurrentVersion = 4`,
  [`src/deps_log.cc`][deps]). Each dep record sets a high bit in its size word to
  distinguish it from a path record:

  ```cpp
  // src/deps_log.cc — RecordDeps (abridged)
  unsigned size = 4 * (1 + 2 + node_count);
  size |= 0x80000000;   // Deps record: set the high bit
  // ... then write: id, mtime_lo, mtime_hi, and node_count input ids
  ```

  The log is append-only and self-compacting: `ninja -t recompact` (and an
  automatic threshold) rewrites it to drop dead records.

### The scheduler: a critical-path-weighted ready queue

The executor side lives in `Plan` ([`src/build.h`][buildh], [`src/build.cc`][build]).
`AddTarget` walks the transitive closure of requested targets, marking each edge
with a `Want` (`kWantNothing` / `kWantToStart` / `kWantToFinish`). Then
`PrepareQueue` runs two passes:

1. **`ComputeCriticalPath`** topologically sorts the reachable edges and propagates
   a `critical_path_weight` from leaves to roots — each edge's weight is its own
   cost plus the heaviest path beneath it:

   ```cpp
   // src/build.cc — ComputeCriticalPath (abridged)
   int64_t candidate_weight = edge_weight + EdgeWeightHeuristic(producer);
   if (candidate_weight > producer_weight)
     producer->set_critical_path_weight(candidate_weight);
   ```

   The weight heuristic is intentionally cheap (`is_phony() ? 0 : 1`,
   [`src/build.cc`][build]) but historical durations from `.ninja_log` refine it,
   so the longest build chains start first.

2. **`ScheduleInitialEdges`** pushes every ready (`kWantToStart`) edge into an
   `EdgePriorityQueue` keyed on that weight.

The build loop then repeatedly `FindWork()`s the highest-priority ready edge,
runs it via a `CommandRunner` (which spawns subprocesses — `sh -c` on POSIX,
`CreateProcess` on Windows), and on completion re-evaluates dependents
(`EdgeFinished` → `NodeFinished` → `EdgeMaybeReady`). _"Builds are always run in
parallel, based by default on the number of CPUs your system has"_ ([manual][manual]),
overridable with `-j`. There is no thread pool for the build logic itself — it is
a single-threaded scheduler driving N concurrent subprocesses.

### Pools and the `console` pool

A **`pool`** caps concurrency below the global `-j` for a subset of edges — _"to
restrict a particular expensive rule (like link steps for huge executables)"_:

```ninja
pool link_pool
  depth = 4

rule link
  command = …
  pool = link_pool       # at most 4 links run at once
```

A pre-defined `console` pool (`depth = 1`, [`src/state.cc`][state] —
`Pool State::kConsolePool("console", 1)`) gives its single task direct access to
`Ninja`'s stdin/stdout/stderr (for interactive or progress-printing tasks like
test suites), buffering other output while it runs.

### Dynamic dependencies (`dyndep`)

Most dependency discovery (headers) is needed only on the _second_ build. Some
languages (Fortran modules, C++20 modules) need it on the _first_ — you cannot
know the edge inputs until you read a freshly-built file. The `dyndep` binding
_(1.10+)_ names an input that `Ninja` reads _during_ the build to add implicit
inputs/outputs and patch the graph in flight, with the constraint that _"a dyndep
file may not change the build graph in a way that causes up-to-date build
statements to become out-of-date"_ ([manual § Dynamic Dependencies][manual]).

---

## The five dimensions

### 1. Workspace declaration & topology

- **There is no workspace manifest and no member list.** A `Ninja` "workspace" is
  a single `build.ninja` file (default name) in the build root; `ninja` _"looks
  for a file named `build.ninja` in the current directory"_ ([manual][manual]).
  There is no `members = […]` array, no glob, no root-vs-virtual distinction —
  contrast [Cargo][cargo]'s `[workspace]`, [pnpm][pnpm]'s globbed
  `pnpm-workspace.yaml`, or [`go.work`][go-work]. **The dependency graph _is_ the
  workspace**: whatever the generator emitted into edges.
- **Composition is by textual inclusion, with two scoping rules.** Large graphs
  are split across many files and stitched with `subninja path` and `include
path` ([manual § Evaluation and scoping][manual]):
  - **`subninja`** _introduces a new scope_ — the child may read and shadow the
    parent's variables/rules but cannot mutate the parent. This is how a generator
    gives each sub-directory or sub-package its own `cflags` without leakage.
  - **`include`** splices the file into the current scope, like a C `#include`.

    The lookup order for a variable is fixed: built-ins (`$in`/`$out`) → build-edge
    bindings → rule bindings → file-level → the `subninja`-including file.

- **One build tree per configuration.** The conventional pattern (inherited from
  the generators) is one output directory per build variant — `out/Debug`,
  `out/Release` — each a fully independent `build.ninja` with its own
  `.ninja_log`/`.ninja_deps`. `Ninja` itself is agnostic; `ninja -C dir` just
  `cd`s there first.
- **Implication for `dub`.** `Ninja`'s topology answer is the _opposite_ of the
  package-manager tools: it has no notion of "package" at all, only files and
  edges. It demonstrates that a monorepo graph can be expressed _entirely_ as a
  flat, generated edge list — but it pushes 100% of the "which packages exist,
  where, and at what version" question up into the generator (which is exactly the
  job `dub`'s resolver already does). See the [`GN`+`Ninja`][gn] page for how a
  generator slices a tree into that flat graph.

### 2. Dependency handling & isolation

- **No package manager, no resolver, no lockfile, no fetching — by design.** This
  is the sharpest contrast with every language-package-manager in the survey.
  `Ninja` has _zero_ concept of versions, registries, hoisting, symlink trees, or
  virtual stores. There is nothing analogous to `dub.selections.json`,
  `Cargo.lock`, or [pnpm][pnpm]'s content-addressed store. Every file that
  participates must already exist on disk (or be produced by another edge); a
  missing _explicit_ input that no edge produces aborts the build.
- **Cross-references are graph edges, and that is the whole isolation story.** A
  library produced in one part of the tree is depended on from another purely by
  naming its output path as an input. There is no `workspace:` protocol
  ([yarn-berry][yarn-berry]), no `path=` dependency — because there are no
  _packages_, only nodes. Topological build order falls out of the DAG for free.
- **Header dependencies are the one place `Ninja` _discovers_ dependencies**, via
  `depfile`/`deps` into `.ninja_deps` (above). When `Ninja` loads these implicit
  edges it _"implicitly adds extra build edges such that it is not an error if the
  listed dependency is missing"_ — so deleting a header and rebuilding doesn't
  abort.
- **No sandboxing, no hermeticity.** Unlike [Bazel][bazel]/[Buck2][buck2], `Ninja`
  runs commands in the ambient filesystem with no per-action namespace; an
  undeclared read is invisible to it. The shipped guard-rail is the
  **`ninja -t missingdeps`** tool _(1.11+)_, which finds _"targets that depend on a
  generated file, but do not have a properly (possibly transitive) dependency on
  the generator … [which] may cause build flakiness on clean builds"_
  ([manual][manual]) — a _diagnostic_, not an _enforcement_.

### 3. Task orchestration & scheduling

- **`Ninja` does build a real DAG and execute it concurrently** — this is its core
  competency. The generator emits edges; `Ninja` constructs the file-level DAG,
  computes critical-path weights, and runs every ready edge in parallel up to `-j`
  (default = CPU count). The `Plan`/`EdgePriorityQueue`/`CommandRunner` machinery
  ([`src/build.cc`][build]) is the engine.
- **Change detection is `mtime` + command-hash** (§ How it works), not content
  hashing and not git-diff-based. An edge re-runs when an input is newer, the
  output is missing, or the recorded command changed. Header changes propagate
  correctly through `.ninja_deps`. This is fast but can over-build on
  touched-but-unchanged files; `restat` prunes the cascade for idempotent
  generators.
- **Affected-target / monorepo slicing is a _query_, not a `--since` flag.**
  `Ninja` has no built-in "build what changed since git ref" affordance like
  [Turborepo][turborepo]'s `--filter=…[ref]` or [Nx][nx]'s `affected`. Instead it
  ships graph-query tools you run yourself:
  - `ninja -t query <target>` — inputs and outputs of one target;
  - `ninja -t inputs <targets>` _(1.11+)_ — the full transitive input set;
  - `ninja -t multi-inputs <targets>` _(1.13+)_ — `<target>⇥<input>` pairs, _"helpful
    if one would like to know which targets are affected by a certain input"_;
  - `ninja -t targets` / `ninja -t graph` (Graphviz) / `ninja -t browse` (web UI).

    The CI idiom is to feed a git diff into `-t multi-inputs`/`-t inputs` and build
    only the affected outputs — affected-detection assembled from primitives, not a
    first-class command.

- **Concurrency controls:** global `-j N` (jobs), `-l N` (load-average cap), and
  per-subset `pool depth`. Since **1.13**, `Ninja` is also a **GNU Make jobserver
  _client_** ([`src/jobserver.cc`][jobserver], [blog][jobserver-blog]): when invoked
  under a top-level `make -jN` (POSIX FIFO protocol, GNU Make ≥ 4.4) with no
  explicit `-j`, it draws job slots from the shared jobserver pool instead of its
  own, so nested builds share one global job budget rather than oversubscribing
  the machine.

### 4. Caching & remote execution

- **No build cache, no remote cache, no remote execution — none.** This is
  `Ninja`'s starkest gap versus [Bazel][bazel]/[Buck2][buck2]/[Pants][pants]. The
  _only_ form of "caching" is **incrementality within one output tree**: the
  `.ninja_log` + `.ninja_deps` databases let a re-run skip up-to-date edges. There
  is no content-addressed store, nothing shared across machines, and no
  [REAPI][reapi] client anywhere in the binary.
- **Caching/RBE must be bolted on at the _command_ level.** Because a `rule`'s
  `command` is an opaque string, large shops wrap the compiler — prefixing
  `cc`/`cxx` with `ccache`/`sccache` for local content caching, or with a
  `reclient`/`reproxy` rewrapper that speaks [REAPI][reapi] to a remote cluster.
  `Ninja` is entirely unaware this is happening; it just runs the string. REAPI
  backends one might point such a wrapper at are surveyed under
  [BuildBuddy][buildbuddy], [Buildbarn][buildbarn], and [NativeLink][nativelink].

  > [!NOTE]
  > This is the inverse of the hermetic engines, where remote caching and REAPI
  > execution are _core features keyed on input hashes_. With `Ninja` the engine
  > is cache-agnostic and the organization assembles the RBE stack (ccache /
  > reclient / a CAS cluster) around it. Google's strategic answer is to **replace
  > the executor**: `Siso`, a Go drop-in for `Ninja` with native remote
  > execution/caching, is mid-rollout across Chromium — see the [`GN`+`Ninja`][gn]
  > deep-dive. `Ninja` proper stays cache-free.

### 5. CLI / UX ergonomics

- **One binary, one default verb.** Bare `ninja` builds the default targets of
  `build.ninja` in the cwd; `ninja foo.o bar` builds named targets (which are
  _file paths_, not package names). `-C dir` changes directory first, `-j N` sets
  parallelism, `-n` is dry-run, `-v` prints full commands. _"Many of Ninja's flags
  intentionally match those of Make"_ ([manual][manual]).
- **Targets are output paths; there is no package selector.** Unlike the
  `--filter`/`-p` selectors of [pnpm][pnpm]/[Turborepo][turborepo] or
  [Cargo][cargo]'s `-p`, `Ninja` selection is by **output file or path** — e.g.
  `ninja chrome` builds the edge producing `chrome`. The `target^` syntax builds
  _"the first output of some rule containing the source you put on the command
  line"_ (handy for "compile just this one `.c`").
- **`-t` subcommands are the entire introspection surface.** `query`, `inputs`,
  `multi-inputs`, `targets`, `graph`, `browse`, `commands`, `deps`, `missingdeps`,
  `compdb` (emit a Clang JSON compilation database), `compdb-targets`, `clean`,
  `cleandead`, `recompact`, `restat`, `rules`. `compdb` in particular is why
  `Ninja`-backed projects get IDE/`clangd` integration for free.
- **Verbosity & explanation.** `-d explain` prints _why_ each dirty edge is being
  rebuilt (the `explanations_` records seen in `graph.cc`), and `-d stats` dumps
  the `METRIC_RECORD` timers — first-class debuggability for "why did this
  rebuild?"

---

## Strengths

- **Blazing incremental startup.** `mtime` + one command hash + two compact binary
  logs means "what changed?" is answered in well under a second on 30k-file trees
  — the founding requirement, still its headline.
- **Correct header dependencies.** `deps = gcc/msvc` into `.ninja_deps` solves the
  Makefile header-tracking problem that motivated the project, with no manual edge
  maintenance and minimal startup cost.
- **A real parallel DAG scheduler.** Critical-path-weighted ready queue, pools for
  throttling expensive rules, `-l` load capping, and (1.13+) GNU Make jobserver
  participation for nested builds.
- **Tiny, dependency-free, ubiquitous.** ~10k lines of `C++` in one vendorable
  binary; the de-facto backend for CMake, Meson, GN, Kati, and more — the
  executor's generality is proven by how many generators target it.
- **Excellent introspection.** `-t graph`/`browse`/`compdb`/`inputs`/`multi-inputs`
  plus `-d explain` make the graph queryable and rebuilds explainable.
- **Predictable, policy-free.** No magic, no decisions, no hidden state — what the
  generator emits is exactly what runs.

## Weaknesses

- **No dependency management whatsoever.** No fetch, no versions, no lockfile, no
  registry — every input must already exist; a separate tool must supply them.
- **No caching or remote execution.** Native `Ninja` caches only via the local
  output tree; cross-machine reuse and RBE require wrapping the compiler
  (ccache/reclient) or swapping the executor (`Siso`).
- **No hermeticity / no content hashing.** `mtime`-based detection over-builds on
  touched files and, without sandboxing, silently misses undeclared reads;
  correctness leans on `-t missingdeps` and generator discipline.
- **Not meant to be authored by hand.** The format is deliberately featureless —
  no conditionals, loops, functions, or globs — so you _need_ a generator, making
  `Ninja` half of a two-tool workflow.
- **No package/workspace concept.** Selection is by output path, not by package;
  there is no `--filter`/`-p`/`--since`, so monorepo slicing is hand-assembled
  from `-t` queries.
- **Crude scheduling cost model.** The critical-path heuristic is `phony ? 0 : 1`
  refined by historical log times — fine, but far from a true cost-aware
  scheduler.

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                      | Trade-off                                                                                        |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| "Aims to be an assembler"; speed over convenience             | Sub-second incremental startup on 30k-file trees — the founding requirement    | The format is unwritable by hand; you _must_ pair it with a generator                            |
| All decisions pushed into a separate generator                | Keeps the executor branch-free and policy-free, hence fast and predictable     | A two-tool workflow; no globs/conditionals/search-paths in `Ninja` itself                        |
| No package manager / resolver / lockfile                      | `Ninja` is a pure executor; deps are whatever exists on disk                   | Needs an entirely separate tool to fetch/version/place inputs; no registry story                 |
| `mtime` + command-hash change detection (not content hashing) | Comparing mtimes and one hash is far cheaper than digesting every file         | Over-builds on touched-but-unchanged files; `restat` only partly mitigates                       |
| `deps = gcc/msvc` → compact `.ninja_deps` database            | Avoids re-reading thousands of `.d` files on startup (esp. on slow Windows FS) | A binary log format to version/recompact; header info is only correct from the _second_ build on |
| Two append-only logs (`.ninja_log` / `.ninja_deps`)           | O(1)-ish restart; seeds the critical-path scheduler with real timings          | Logs can grow and need `-t recompact`; corruption forces a clean rebuild                         |
| Critical-path-weighted ready queue                            | Starts the longest dependency chains first to shorten wall-clock               | Heuristic weight (`phony?0:1` + history) is crude vs. a real cost model                          |
| No built-in caching / remote execution                        | Keeps the binary tiny and the engine cache-agnostic; org picks any backend     | RBE/caching must be wrapped on (ccache/reclient) or the executor replaced (`Siso`)               |
| No sandbox; correctness via `-t missingdeps` + discipline     | Zero sandbox overhead; runs commands in the ambient filesystem                 | Not hermetic — undeclared reads are invisible; `missingdeps` only _diagnoses_, doesn't prevent   |
| Selection by output path, no package/`--filter`/`--since`     | Matches the "files and edges, not packages" model; mirrors Make's CLI          | Monorepo affected-target slicing must be hand-built from `-t inputs`/`multi-inputs` + a git diff |
| GNU Make jobserver _client_ (1.13+)                           | Nested builds share one global job budget instead of oversubscribing cores     | POSIX needs the FIFO protocol (GNU Make ≥ 4.4); client-only, not a server                        |

---

## Sources

- [`ninja-build/ninja` — GitHub repository (source for all quoted file paths)][repo]
- [`Ninja` manual (`doc/manual.asciidoc`) — philosophy/non-goals, file format,
  `deps`/`depfile`/`restat`/`generator`, pools, scoping, `dyndep`, `-t` tools, jobserver][manual]
- [`ninja-build.org` — project landing page][home]
- [`src/version.cc` — `kNinjaVersion = "1.14.0.git"`, `ninja_required_version` check][version]
- [`src/graph.cc` — `RecomputeOutputDirty`: missing/mtime/command-hash dirty ladder][graph]
- [`src/build.cc` / `src/build.h` — `Plan`, `Want`, `ComputeCriticalPath`,
  `EdgePriorityQueue`, the build loop][build]
- [`src/deps_log.cc` — `.ninja_deps` binary format (`kCurrentVersion = 4`, high-bit dep records)][deps]
- [`src/state.cc` — default and `console` pools][state]
- [`src/jobserver.cc` — GNU Make jobserver client][jobserver]
- ["After nine years, Ninja merged GNU Make jobserver support" (TheBrokenRail)][jobserver-blog]
- Sibling deep-dives: the [`GN` + `Ninja`][gn] two-layer page (generator side) ·
  generators that target `Ninja`: [CMake][cmake] · [Meson][meson] · [SCons][scons] ·
  hermetic engines [Bazel][bazel] · [Buck2][buck2] · [Pants][pants] ·
  orchestrators [Turborepo][turborepo] · [Nx][nx] · package managers
  [Cargo][cargo] · [pnpm][pnpm] · [yarn-berry][yarn-berry] · [Go (`go.work`)][go-work] ·
  research minimalists [redo][redo] · [tup][tup]; REAPI backends
  [BuildBuddy][buildbuddy] / [Buildbarn][buildbarn] / [NativeLink][nativelink];
  the [survey umbrella][umbrella] and the [D async/`dub` landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/ninja-build/ninja
[home]: https://ninja-build.org/
[manual]: https://ninja-build.org/manual.html
[version]: https://github.com/ninja-build/ninja/blob/master/src/version.cc
[graph]: https://github.com/ninja-build/ninja/blob/master/src/graph.cc
[build]: https://github.com/ninja-build/ninja/blob/master/src/build.cc
[buildh]: https://github.com/ninja-build/ninja/blob/master/src/build.h
[deps]: https://github.com/ninja-build/ninja/blob/master/src/deps_log.cc
[state]: https://github.com/ninja-build/ninja/blob/master/src/state.cc
[jobserver]: https://github.com/ninja-build/ninja/blob/master/src/jobserver.cc
[jobserver-blog]: http://web.archive.org/web/20260511015624/http://thebrokenrail.com/2025/06/30/ninja-jobserver.html
[reapi]: https://github.com/bazelbuild/remote-apis
[gn]: ../gn/
[cmake]: ../cmake/
[meson]: ../meson/
[scons]: ../scons/
[bazel]: ../bazel/
[buck2]: ../buck2/
[pants]: ../pants/
[turborepo]: ../turborepo/
[nx]: ../nx/
[cargo]: ../cargo/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[go-work]: ../go-work/
[redo]: ../redo/
[tup]: ../tup/
[buildbuddy]: ../buildbuddy/
[buildbarn]: ../buildbarn/
[nativelink]: ../nativelink/
[umbrella]: ../
[d-landscape]: ../../async-io/d-landscape.md
