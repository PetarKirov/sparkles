# SCons (C/C++/native)

A pure-`Python` software construction tool: the build configuration **is** a
`Python` program, the dependency graph is assembled in memory by executing that
program, and change detection is **content-hash** (`MD5`/`SHA-256`) signatures
rather than `mtime` — the "reliable builds, real programming language" answer to
`Make`.

| Field           | Value                                                                                                                             |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Language        | `Python` (engine and configuration language are both `Python`; `SConstruct`/`SConscript` files are executed as `Python` scripts)  |
| License         | MIT ("Copyright The SCons Foundation")                                                                                            |
| Repository      | [`SCons/scons`][repo] (GitHub; historically SourceForge)                                                                          |
| Documentation   | [User Guide][userguide] · [`scons` man page][manpage] · [API reference][apiref]                                                   |
| Category        | Native Build System                                                                                                               |
| Workspace model | Single source tree rooted at an `SConstruct` file; a hierarchy of `SConscript` files, one per subdirectory, executed into one DAG |
| First released  | 2001 (descended from `Cons`, a Perl tool, via the 2000 _ScCons_ Software Carpentry contest entry)                                 |
| Latest release  | `4.10.1` (November 16, 2025)                                                                                                      |

> **Latest release (as of June 5, 2026):** `4.10.1`, released **2025-11-16**,
> headlined by Visual Studio / `MSVS` 2026 support; `master` is at `4.10.2` (dev).
> The `4.x` line is `Python 3`-only and now ships the **`NewParallel`** scheduler as
> the default for _all_ builds (including `-j1`), with the legacy scheduler demoted
> to opt-in `--experimental=legacy_sched` ([`CHANGES.txt`][changes]). SCons is one of
> the oldest tools in this survey — predating `Bazel`, `CMake`'s ubiquity, and every
> package manager here — and is unusual for being a _native_ build system written
> entirely in a general-purpose scripting language.

---

## Overview

### What it solves

SCons solves the **correct, reliable rebuild** problem for native (C/C++/Fortran/D
…) projects without inventing a domain-specific language. Where `Make` requires a
bespoke `Makefile` syntax plus a separate `make depend` step (and trusts file
timestamps, which lie under clock skew, `touch`, and restored backups), SCons makes
two opposite bets:

1. **The build description is ordinary `Python`.** `SConstruct` (the root) and
   `SConscript` (per-directory) files are not parsed as a config format — they are
   _executed_ as `Python`. Loops, functions, classes, `import` of helper modules,
   and arbitrary computation are all available, because they _are_ `Python`. From
   the project's own pitch ([`README.rst`][readme]):

   > _"Configuration files are Python scripts — use the power of a real programming
   > language to solve build problems; no complex domain-specific language to learn."_

2. **Change detection is content-based, not timestamp-based.** SCons hashes file
   _contents_ (and the command line, and the tools) into a **build signature**, and
   rebuilds only when a signature changes. Again from [`README.rst`][readme]:

   > _"Reliable, automatic dependency analysis built-in for C, C++ and FORTRAN. No
   > more 'make depend' or 'make clean' to get all of the dependencies. … Reliable
   > detection of build changes using cryptographic hashes; optionally can configure
   > other algorithms including traditional timestamps."_

Within this survey SCons is the **"general-purpose-language build system"** data
point. Contrast the generator/executor split of [`GN` + `Ninja`][gn] (a deliberately
_minimally expressive_ DSL feeding a dumb assembler) and the hermetic
content-addressed engines [`Bazel`][bazel] / [`Buck2`][buck2] (Starlark + sandboxed
remote execution). SCons sits at the opposite pole from `Ninja`: it is the
high-level _policy_ tool and _its own_ executor, all in one `Python` process —
expressive, introspectable, and (its long-standing weakness) comparatively slow at
scale. `Make`, `Meson`, `CMake`, `Waf`, and `Ninja` are the sibling native systems;
`Waf` in fact began as a fork of SCons.

### Design philosophy

SCons descends from `Cons` (Bob Sidebotham, 1996, in Perl) and was rewritten in
`Python` after winning the 2000 Software Carpentry build-tool design competition. The
philosophy that survived both rewrites: a build tool should be **correct first, and
correctness comes from modelling the build as a graph of `Node`s with real content
signatures, driven by a real language.** Three consequences shape the entire API:

1. **Everything is a `Node` in one in-memory DAG.** Source files, derived files,
   directories, `Value`s (in-memory strings), and `Alias`es are all `Node` objects.
   Executing every `SConstruct`/`SConscript` builds the _whole_ graph before
   anything is built — SCons is a **two-phase** system (read all scripts → walk the
   DAG), not a recursive-descent `Make` where each directory is a separate process
   with a partial view. This is the cure for "recursive make considered harmful":
   there is one global graph, so cross-directory dependencies are always correct.

2. **Construction Environments, not global flags.** A build is parameterized through
   `Environment` objects — dictionaries of construction variables (`CC`, `CCFLAGS`,
   `CPPPATH`, `LIBS`, …) plus the `Builder` methods (`Program`, `Library`,
   `Object`, `SharedLibrary`, …) that consume them. Multiple `Environment`s can
   coexist (debug vs. release, host vs. target), `Clone()`d and locally tweaked,
   without global mutable state.

3. **Signatures over timestamps, by default.** The default `Decider` is content
   hashing. SCons stores per-target signature info in an `SConsign` dbm database
   (`.sconsign.dblite`) so an incremental run reloads prior signatures and rebuilds
   exactly the targets whose inputs (content, command line, or implicit header deps)
   actually changed.

---

## How it works

### The two phases: read the scripts, then walk the DAG

```bash
# One invocation does both phases:
scons               # read SConstruct (+ all SConscripts), build the default targets
scons -j8           # ... with 8 parallel jobs
scons build/prog    # build just one target by path
scons -c            # "clean": remove the derived files SCons knows how to build
scons -n            # dry run: print what WOULD be built, build nothing
```

**Phase 1 (read)** executes `SConstruct`. Any `Builder` call (`env.Program(...)`,
`env.Library(...)`) does **not** build anything — it _registers_ target/source
`Node`s and their edges in the graph and returns the target `Node`s. `SConscript(...)`
calls recurse into subdirectory scripts, accreting their nodes into the same global
graph. **Phase 2 (build)** hands the graph to the **`Taskmaster`**, which walks it,
asks each `Node` whether it is up to date (via its `Decider`), and dispatches the
out-of-date ones to the scheduler.

### Builders, Environments, and construction variables

A minimal `SConstruct`:

```python
# SConstruct
env = Environment(CCFLAGS='-O2 -Wall', CPPPATH=['include'])
env.Program('hello', ['hello.c', 'util.c'])   # -> builds ./hello (or hello.exe)
```

`env.Program` is a `Builder`. It expands the command from construction variables —
roughly `$CC $CCFLAGS $CPPFLAGS $_CPPINCFLAGS -c -o $TARGET $SOURCES` for the
compile step and a link step for the program — using SCons's `$`-substitution
language over the `Environment` dict. Because the configuration is `Python`, you can
compute sources, branch on platform, and define your own `Builder`s as first-class
values:

```python
debug   = Environment(CCFLAGS='-g -O0', CPPDEFINES=['DEBUG'])
release = debug.Clone(CCFLAGS='-O2', CPPDEFINES=[])     # independent copy
for env, sub in [(debug, 'build/debug'), (release, 'build/release')]:
    env.Program(f'{sub}/app', Glob(f'{sub}/*.c'))
```

### Implicit dependency scanning

SCons ships **`Scanner`s** that parse source files to discover _implicit_
dependencies the user never declared — most importantly the C/C++ preprocessor
scanner that follows `#include` directives (respecting `CPPPATH`), plus Fortran,
D, LaTeX, and SWIG scanners. The discovered headers become real graph edges, so
editing a header rebuilds exactly the translation units that include it. This is the
built-in replacement for `make depend`, and it is recomputed every run rather than
cached into a stale `.d` file.

### Signatures and the `SConsign` database

SCons distinguishes two hashes ([man page][manpage], `--hash-format`):

- a **content signature** — _"a hash of the contents of a file participating in the
  build (dependencies as well as targets)"_; and
- a **build signature** — _"a hash of the elements needed to build a target, such as
  the command line, the contents of the sources, and possibly information about
  tools used in the build."_

The build signature is the **content-address of a target**: change the sources, the
flags, _or_ the command line and the build signature changes, forcing a rebuild (and
becoming the key for caching, below). Signatures persist in `.sconsign.dblite` (the
`SConsign` dbm), so a clean checkout's first incremental run knows precisely what is
current. The hash algorithm is configurable — `md5`, `sha1`, or `sha256`
(`--hash-format=sha256`; the default has migrated from `MD5` toward `SHA-256` for
FIPS environments).

### The `Decider`: pluggable change detection

What "changed" _means_ is a policy chosen with `Decider()`
([`SCons/Environment.py`][env-py]):

```python
# SCons/Environment.py — Environment.Decider (abridged)
if function in ('MD5', 'content'):
    function = self._changed_content                      # hash file contents (DEFAULT)
elif function in ('MD5-timestamp', 'content-timestamp'):
    function = self._changed_timestamp_then_content       # mtime gate, then hash
elif function in ('timestamp-newer', 'make'):
    function = self._changed_timestamp_newer              # Make-style: source newer than target
elif function == 'timestamp-match':
    function = self._changed_timestamp_match
```

The default `'content'` is maximally correct but hashes every input; `'MD5-timestamp'`
is the common performance compromise — _skip_ the hash when the `mtime` is unchanged,
hash only when it moved — getting most of `Make`'s speed with content-hash
correctness on the files that actually changed. `Decider('make')` opts back into pure
timestamp semantics.

---

## The five dimensions

### 1. Workspace declaration & topology

- **Root marker = the `SConstruct` file.** A SCons "workspace" is the source tree
  rooted at the directory containing `SConstruct` (SCons searches the current and
  ancestor directories for it, like `git` finds `.git`). There is **no member array
  and no glob of packages** — contrast [Cargo][cargo]'s `[workspace] members` or
  [pnpm][pnpm]'s `pnpm-workspace.yaml`. The "members" are simply the `SConscript`
  files the root chooses to pull in.
- **Topology is an explicit `SConscript` hierarchy.** The root composes subdirectory
  scripts with the `SConscript()` function ([User Guide ch. "Hierarchical
  Builds"][userguide]):

  > _"The top-level `SConstruct` file can use the `SConscript` function to include
  > other subsidiary scripts in the build. These subsidiary scripts can, in turn, use
  > the `SConscript` function to include still other scripts … By convention, these
  > subsidiary scripts are usually named `SConscript`."_

  ```python
  # SConstruct — list the members explicitly
  SConscript([
      'drivers/display/SConscript',
      'drivers/mouse/SConscript',
      'parser/SConscript',
      'utilities/SConscript',
  ])
  ```

  Membership is _imperative and explicit_: a directory is "in" the build only if some
  `SConscript()` call names it (or names a parent that does). Because it is `Python`,
  you can also discover members dynamically — `SConscript(Glob('libs/*/SConscript'))`
  is a one-liner — but there is no first-class globbed-member declaration; you write
  the `Python` that finds them.

- **One global DAG, not recursive sub-processes.** Every `SConscript` accretes nodes
  into the _same_ in-memory graph in _one_ `scons` process. This is the structural
  cure for recursive-`Make`: cross-directory dependencies (a `parser` that links
  `utilities`) are first-class edges with correct ordering, not a fragile sub-make
  invocation order.
- **Variant directories separate source from build.** `VariantDir(build, src)`
  (or `SConscript(..., variant_dir=..., duplicate=...)`) maps a source subtree onto a
  build subtree so multiple configurations (debug/release, per-arch) build the same
  sources into distinct output trees — the topology axis that `GN`'s out-dirs and
  `CMake`'s build dirs also provide. With `duplicate=0` SCons builds in place without
  copying sources; the default `duplicate=1` mirrors sources so generated files never
  pollute the source tree.

### 2. Dependency handling & isolation

- **No package manager, no registry, no lockfile.** Like [`GN`][gn] and `Make`, SCons
  has **no concept of fetching or versioning external packages** — there is no
  `dub.selections.json`/`Cargo.lock` equivalent. Everything that participates in the
  build must already exist on disk (or be produced by the build). SCons _finds_
  system libraries and headers at configure time via the **`Configure`** context
  (Autoconf-style feature probes: `CheckLibWithHeader`, `CheckCHeader`,
  `CheckFunc`), but it does not _install_ them.
- **Cross-references are graph edges and exported variables.** A library built in
  `utilities/SConscript` is depended on from `parser/SConscript` by passing the
  returned target `Node` across scripts. SCons threads variables between scripts with
  **`Export()` / `Import()` / `Return()`** ([`SCons/Script/SConscript.py`][sconscript-py]):

  ```python
  # utilities/SConscript
  Import('env')
  libutil = env.Library('util', Glob('*.c'))
  Return('libutil')                      # hand the target Node back up

  # SConstruct
  env = Environment()
  Export('env')
  libutil = SConscript('utilities/SConscript')
  SConscript('parser/SConscript', exports={'env': env, 'libutil': libutil})
  ```

  There is **no hoisting, no symlink tree, no virtual store** ([npm][npm]/[pnpm][pnpm]
  concepts) and no `workspace:` protocol ([yarn-berry][yarn-berry]) — because there
  are no _packages_, only `Node`s in one graph. The graph edge _is_ the cross-reference,
  and topological build order falls out of it automatically.

- **Repositories: a shared source/derived tree (a proto-distributed-cache).** The
  `Repository(dir)` method (CLI `-Y dir` / `--repository=dir`) tells SCons to look in
  one or more **central trees** for source _and_ derived files before building
  locally ([User Guide ch. "Building From Code Repositories"][userguide]):

  > _"It's often useful to allow multiple programmers working on a project to build
  > software from source files and/or derived files that are stored in a
  > centrally-accessible repository, a directory copy of the source code tree."_

  If a repository already contains an up-to-date derived file (validated by the
  _same signature calculation_, using the repository's `.sconsign` files), SCons uses
  it instead of rebuilding locally — _"SCons will perform its normal signature
  calculation to decide if a derived file in a repository is up-to-date, or if it
  needs to be rebuilt."_ This is SCons's pre-`CacheDir` answer to sharing build
  output across a team, and the conceptual ancestor of a content-addressed cache.

- **Isolation by `Python` scoping, not sandbox.** Each `SConscript` runs in its own
  namespace and only sees what it `Import()`s — but actions are **not** sandboxed
  the way [`Bazel`][bazel]/[`Buck2`][buck2] sandbox them. Undeclared file reads are
  not prevented; correctness leans on the implicit scanner finding `#include`s and on
  the user declaring dependencies, not on hermetic enforcement.

### 3. Task orchestration & scheduling

- **One global `Node` DAG, walked by the `Taskmaster`.** After phase 1 builds the
  graph, the **`Taskmaster`** ([`SCons/Taskmaster/__init__.py`][taskmaster-py]) _"is
  the main engine for walking the dependency graph and calling things to decide what
  does or doesn't need to be built."_ It hands ready `Task`s to a scheduler and
  collects results, ordering strictly by the DAG.
- **Change detection by content signature.** Unlike `Ninja`/`Make` (`mtime`), the
  default `Decider` rebuilds a `Node` when its **build signature** changes — i.e. the
  hashed contents of its sources, its scanned implicit deps, _or_ the command line
  differ from the stored `SConsign` value. Changing a compile flag rebuilds the
  affected objects even though no file `mtime` moved; restoring an identical file does
  _not_ trigger a rebuild even though its `mtime` jumped. The `'MD5-timestamp'`
  decider adds an `mtime` fast-path to skip hashing unchanged files.
- **Parallelism: the `NewParallel` leader/follower scheduler.** `-j N` /
  `--jobs=N` runs independent DAG legs concurrently on a thread pool. As of `4.7.0`
  the **`NewParallel`** job class ([`SCons/Taskmaster/Job.py`][job-py]) is the
  default for _all_ builds. It is a leader/follower design: exactly one worker holds
  the **`tm_lock`** ("ensures that we only have one thread interacting with the
  taskmaster at a time") and _searches_ the graph for ready work, while followers
  wait on a condition variable and execute the tasks they are handed; completed tasks
  are retired off a `results_queue` by the next thread to acquire the lock. The state
  machine is `READY → SEARCHING → STALLED → COMPLETED`:

  ```python
  # SCons/Taskmaster/Job.py — NewParallel.State
  class State(Enum):
      READY = 0
      SEARCHING = 1
      STALLED = 2
      COMPLETED = 3
  ```

  Two refinements landed with the default switch ([`CHANGES.txt`][changes]): the
  scheduler _"only adds threads as new work requiring execution is discovered, up to
  the limit set by -j"_ (so shallow DAGs don't spin up idle threads), and **`CacheDir`
  writes no longer happen within the taskmaster critical section**, so cache stores run
  in parallel with the DAG walk.

- **Affected-target slicing is manual / partial.** SCons has **no first-class
  `--since <git-ref>` affected-detection** ([Turborepo][turborepo]/[Nx][nx] do; SCons
  does not). What it offers instead: (a) you build any subset by naming target paths
  on the command line (`scons parser/`), and (b) content signatures mean that even a
  full `scons` invocation does _no work_ for unchanged targets — the graph walk is
  cheap relative to compilation, so "build everything, rebuild nothing" is the
  default affected-detection. There is no built-in reverse-dependency query
  (`gn refs`-style) to compute the changed set from a diff; you'd script it.

### 4. Caching & remote execution

- **`CacheDir`: a local/shared content-addressed derived-file cache.** `CacheDir(dir)`
  ([`SCons/CacheDir.py`][cachedir-py]) caches every derived file keyed by its **build
  signature**. The cache path is literally `dir/<sig-prefix>/<full-sig>`
  (`cachepath()` uses `node.get_cachedir_bsig()` and a configurable `prefix_len`
  subdir fan-out) — a true content-addressed store. Before building a target, SCons
  `retrieve()`s it from the cache if a file under that signature exists; after
  building, it pushes the result in.
- **The cache is shareable across a team over NFS.** This is SCons's headline
  monorepo win and it predates the modern remote-cache era ([User Guide
  ch. "Caching Built Files"][userguide]):

  > _"On multi-developer software projects, you can sometimes speed up every
  > developer's builds a lot by allowing them to share a cache of the derived files
  > that they build. … In environments where developers are using separate systems
  > (like individual workstations) for builds, this directory would typically be on a
  > shared or NFS-mounted file system."_

  Because the key is a content hash, a derived file another developer (or CI) already
  built is fetched instead of recompiled — the same value proposition as
  [Turborepo][turborepo]'s remote cache or [`Bazel`][bazel]'s action cache, achieved
  with a shared filesystem and no server.

- **Cache control flags.** `--cache-disable` (ignore the cache this run),
  `--cache-force` / `--cache-populate` (push even targets that were retrieved, to seed
  a cache), `--cache-readonly` (retrieve but never write — the CI-builder pattern),
  `--cache-show` (print the would-be build command for cache hits), and a per-build
  `--cache-debug` log. Recent hardening targets **shared-cache races**: SCons now uses
  a `uuid` (not the `pid`) for the cache tmpfile and performs the cache-store behind
  an atomic rename to avoid two machines clobbering the same entry ([`CHANGES.txt`][changes]).

  > [!NOTE]
  > `CacheDir` is a **content-addressed cache over a filesystem**, not a Remote
  > Execution API (REAPI) client. SCons does **not** speak REAPI and has **no built-in
  > remote _execution_** — it never ships compile actions to a [`BuildBuddy`][bazel] /
  > `Buildbarn` / `NativeLink` worker farm the way [`Bazel`][bazel] / [`Buck2`][buck2]
  > do. Remote _caching_ is "put `CacheDir` on a network filesystem"; remote
  > _execution_ is out of scope. (For a true REAPI story you would generate `Ninja`
  > and use a `Ninja`-RBE wrapper, or use SCons's `--experimental=ninja` export — see
  > below.)

- **`Ninja` export escape hatch.** SCons can emit a `build.ninja` from its graph
  (`--experimental=ninja`, the `NINJA` tool), so a project can keep SCons as the
  high-level _generator_ but run [`Ninja`][gn] (and a `Ninja`-level RBE wrapper) as a
  faster executor — bolting on the remote-execution path SCons itself lacks.

### 5. CLI / UX ergonomics

- **One binary, one verb.** Everything is `scons`. No generate-then-build two-step
  ([`GN`][gn]) and no subcommand zoo: `scons` builds, `scons -c` cleans, `scons -n`
  dry-runs, `scons -Q` quiets the "Reading SConscript files…" chatter. The build
  description's `Default(...)` call sets what bare `scons` builds.
- **Target selection is by path/`Alias`, not `--filter`.** You scope a build by
  naming targets — `scons build/app`, `scons utilities` (an `Alias`), or a directory
  to build everything under it. There is **no package selector** like [pnpm][pnpm]'s
  `--filter` or [Cargo][cargo]'s `-p`; the "package" granularity is the path/`Alias`
  you name. `Alias('test', [...])` then `scons test` is the idiomatic task entry
  point (SCons has no built-in `test` phase — you wire it as an alias of an action).
- **Configuration via `Variables` + command-line `key=value`.** Build options are
  declared with the `Variables` system and overridden on the command line:
  `scons debug=1 PREFIX=/opt`. `ARGUMENTS`/`ARGLIST` expose raw `key=value` pairs to
  the `Python`, so flag parsing is whatever you write — `AddOption()` even registers
  genuine new `--long-options`.
- **Diagnostics and introspection.** `--tree=all` prints the dependency tree;
  `--debug=explain` prints _why_ each target is being rebuilt (which signature
  changed); `--taskmastertrace=-` dumps the `Taskmaster`'s node-by-node decisions;
  `-j N` sets parallelism; `--random` shuffles build order to flush out missing
  dependencies. The introspection is rich because the graph is a live `Python` object,
  not an opaque generated file.

---

## Strengths

- **Real language, no DSL.** `Python` configuration means loops, functions, classes,
  helper modules, and arbitrary computation are free — no `Make` macro contortions and
  no learning a bespoke config grammar. Custom `Builder`s and `Scanner`s are
  first-class.
- **Correct-by-default change detection.** Content-hash **build signatures** (not
  `mtime`) catch flag changes and ignore spurious `touch`es; the C/C++ scanner
  replaces `make depend`. This is the reliability `Make` lacks.
- **One global DAG cures recursive-make.** All `SConscript`s build one in-memory
  graph in one process, so cross-directory dependencies and parallelism are always
  correct — no sub-make ordering bugs.
- **Shared content-addressed cache, decades early.** `CacheDir` over NFS gives a team
  a derived-file cache keyed by content hash — the modern remote-cache value
  proposition with zero server infrastructure. `Repository`/`-Y` adds a shared
  source+derived tree.
- **Variant directories and multiple `Environment`s** make debug/release and
  multi-arch builds clean and parallel without polluting the source tree.
- **Mature, stable, broad.** 25 years of production use (MongoDB, Blender precursors,
  Godot historically, many embedded toolchains); broad language/tool support;
  excellent `--debug=explain` introspection.

## Weaknesses

- **Historically slow at scale.** Executing all `SConscript`s up front and hashing
  contents is more work than `Ninja`'s `mtime` check; large trees pay a noticeable
  graph-build + signature cost. `NewParallel`, `MD5-timestamp`, and the `Ninja`
  export exist precisely to mitigate this, and SCons's own wiki has a long
  `NeedForSpeed` page of tuning advice.
- **No package management / no lockfile.** No fetch, no version resolution, no
  registry dependencies — you vendor or rely on system libraries probed by
  `Configure`. No answer to [Cargo][cargo]/[uv][uv]-style dependency resolution.
- **No remote execution and no REAPI.** Remote _caching_ is only "`CacheDir` on a
  network share"; there is no engine-native action cache, no sandboxing, and no
  worker-farm execution like [`Bazel`][bazel]/[`Buck2`][buck2].
- **No first-class affected-target / `--since` slicing.** No built-in reverse-dep
  query or git-diff-driven change set ([Turborepo][turborepo]/[Nx][nx]); you script it
  or rely on signatures making a full build cheap.
- **No sandboxing / hermeticity.** Undeclared reads aren't prevented; correctness
  depends on scanners and discipline, so builds can be non-reproducible across
  environments.
- **The `Python`-is-the-config double edge.** Full programmability invites slow,
  side-effecting, hard-to-analyze `SConstruct` files; there is no enforced "well-lit
  path" the way [`GN`][gn] is deliberately _minimally expressive_.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                          | Trade-off                                                                                           |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Configuration **is** `Python` (no DSL)                              | A real language solves real build problems; no grammar to learn; custom `Builder`s/`Scanner`s free | Slow, side-effecting configs are easy to write; no enforced legible "well-lit path"                 |
| Content-hash **build signatures** by default (not `mtime`)          | Reliable rebuilds: catches flag changes, ignores spurious `touch`es                                | Hashing every input is slower than an `mtime` stat; mitigated by `MD5-timestamp` / `NewParallel`    |
| One global in-memory `Node` DAG (read all scripts, then build)      | Cures recursive-make: correct cross-directory deps and parallelism in one process                  | Whole graph is built up front every run — a startup cost that grows with tree size                  |
| Workspace = `SConstruct` root + explicit `SConscript` hierarchy     | Zero ceremony; membership is whatever the scripts pull in (and is plain `Python`, so scriptable)   | No first-class member array/glob or named sub-workspaces; you write the `Python` that finds members |
| Cross-refs via graph edges + `Export`/`Import`/`Return`             | No registry, no hoisting, no symlink store — the edge _is_ the reference                           | No `workspace:` protocol, no isolation guarantees; sharing state is manual variable plumbing        |
| `CacheDir` = content-addressed derived-file cache over a filesystem | Team-wide build sharing keyed by content hash, no server needed; NFS-shareable                     | Filesystem-only (no REAPI); shared-cache races needed `uuid`/atomic-rename hardening                |
| `NewParallel` leader/follower scheduler, default for all builds     | One thread touches the `Taskmaster` at a time; threads added lazily as work appears                | A single critical section serializes graph search; throughput bounded by that lock for tiny tasks   |
| **No** remote execution / sandbox / REAPI                           | Keeps SCons a self-contained `Python` tool; remote _caching_ via a shared `CacheDir`               | No hermeticity, no worker farm; for RBE you export `Ninja` and wrap the compiler externally         |
| **No** package manager / lockfile / resolver                        | Stays a build tool; deps are on disk, probed by `Configure`                                        | No registry-dependency story; vendoring or system libs only                                         |
| `Decider` is pluggable (`content` / `MD5-timestamp` / `make`)       | Projects trade correctness for speed explicitly per their needs                                    | Choosing `make` (timestamps) reintroduces the `mtime` unreliability SCons set out to fix            |

---

## Sources

- [`SCons/scons` — GitHub repository (engine + DocBook user guide)][repo]
- [`README.rst` — "configuration files are Python scripts"; content-hash change
  detection; built-in C/C++/Fortran dependency analysis][readme]
- [`SCons/CacheDir.py` — content-addressed cache keyed by build signature
  (`cachepath`/`get_cachedir_bsig`/`retrieve`)][cachedir-py]
- [`SCons/Taskmaster/__init__.py` — the DAG-walking engine ("decide what does or
  doesn't need to be built")][taskmaster-py]
- [`SCons/Taskmaster/Job.py` — `NewParallel` leader/follower scheduler, `tm_lock`,
  `READY/SEARCHING/STALLED/COMPLETED` state machine][job-py]
- [`SCons/Environment.py` — `Decider()` (`content` / `MD5-timestamp` /
  `timestamp-newer` / `timestamp-match`)][env-py]
- [`SCons/Script/SConscript.py` — `SConscript`/`VariantDir`/`Export`/`Import`/`Return`][sconscript-py]
- [`doc/user/caching.xml` — shared NFS `CacheDir` for multi-developer teams][userguide]
- [`doc/user/repositories.xml` — `Repository`/`-Y` shared source+derived trees][userguide]
- [`doc/user/hierarchy.xml` — hierarchical `SConscript` builds][userguide]
- [`CHANGES.txt` — `NewParallel` made default; lazy thread spawn; `CacheDir` writes
  outside the critical section; shared-cache `uuid`/atomic-rename hardening][changes]
- [SCons User Guide (rendered)][userguide-html] · [`scons` man page (signatures,
  hash format, cache/decider/`-j`/`-Y` options)][manpage] · [Releases][repo-releases]
- Sibling deep-dives: [`GN` + `Ninja`][gn] · [Bazel][bazel] · [Buck2][buck2] · [Cargo][cargo] ·
  [Turborepo][turborepo] · [Nx][nx] · [pnpm][pnpm] · [npm][npm] · [Yarn Berry][yarn-berry] ·
  [Go (`go.work`)][go-work] · [uv][uv]; `Make`, `Meson`, `CMake`, `Waf`, `Ninja`,
  `redo`, `tup` (sibling native systems); REAPI backends `BuildBuddy` / `Buildbarn` /
  `NativeLink`; the [umbrella survey index][umbrella] and the
  [D async/`dub` landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/SCons/scons
[repo-releases]: https://github.com/SCons/scons/releases
[readme]: https://github.com/SCons/scons/blob/master/README.rst
[changes]: https://github.com/SCons/scons/blob/master/CHANGES.txt
[cachedir-py]: https://github.com/SCons/scons/blob/master/SCons/CacheDir.py
[taskmaster-py]: https://github.com/SCons/scons/blob/master/SCons/Taskmaster/__init__.py
[job-py]: https://github.com/SCons/scons/blob/master/SCons/Taskmaster/Job.py
[env-py]: https://github.com/SCons/scons/blob/master/SCons/Environment.py
[sconscript-py]: https://github.com/SCons/scons/blob/master/SCons/Script/SConscript.py
[userguide]: https://github.com/SCons/scons/tree/master/doc/user
[userguide-html]: https://scons.org/doc/production/HTML/scons-user/index.html
[manpage]: https://scons.org/doc/production/HTML/scons-man.html
[apiref]: https://scons.org/doc/production/HTML/scons-api/index.html
[gn]: ../gn/
[bazel]: ../bazel/
[buck2]: ../buck2/
[cargo]: ../cargo/
[turborepo]: ../turborepo/
[nx]: ../nx/
[pnpm]: ../pnpm/
[npm]: ../npm/
[yarn-berry]: ../yarn-berry/
[go-work]: ../go-work/
[uv]: ../uv/
[umbrella]: ../
[d-landscape]: ../../async-io/d-landscape.md
