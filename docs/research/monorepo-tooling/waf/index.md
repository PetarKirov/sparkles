# Waf (C/C++/native)

A self-contained, `Python`-based build _framework_ in which the build
description **is** a `Python` program (`wscript`), the multi-directory project
tree is assembled imperatively by `recurse()`-ing into sub-directory scripts, and
change detection is **content-hashing of task signatures** (input files + command

- environment variables) rather than timestamps.

| Field           | Value                                                                                                                    |
| --------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Language        | `Python` (2.7–3.x, `Jython`, `PyPy`); the build configuration language is `Python` itself — `wscript` files are executed |
| License         | BSD (3-clause; `Thomas Nagy`)                                                                                            |
| Repository      | [`ita1024/waf`][repo] (GitLab; canonical), [`waf-project/waf`][gh] mirror                                                |
| Documentation   | [The Waf Book][book] · [API docs][apidocs] · [`waf.io`][home]                                                            |
| Category        | Native Build System                                                                                                      |
| Workspace model | **Single source tree rooted at one `wscript`**; sub-directories joined imperatively by `ctx.recurse('sub')` into one DAG |
| First released  | 2005 (forked conceptually from `SCons`/`Cons` lineage by `Thomas Nagy`; `waf 1.0` mid-2000s)                             |
| Latest release  | `2.1.9` (self-reported `WAFVERSION = "2.1.9"`, `HEXVERSION = 0x2010900`)                                                 |

> **Latest release (as of June 5, 2026):** `2.1.9`, per `waflib/Context.py`
> (`WAFVERSION="2.1.9"`, revision `387d01c…`); the `master` checkout used for the
> file paths quoted below is at commit `4d54214` (2026-05-19). Waf ships as a
> **single ≈100 KiB executable script** with the `waflib/` library base64-embedded
> inside it — there is nothing to install but `Python`. The `2.0`/`2.1` lines are
> `Python 3`-friendly (`2.0` still runs on `Python 2.7`); `2.1` is the current
> development line. Within this survey Waf is the canonical _imperative, single-file,
> hash-based native build system_ — contrast the declarative
> generate-then-execute model of [`Meson`][meson]/[`GN`][gn] and the
> content-signature kinship with [`SCons`][scons].

---

## Overview

### What it solves

Waf targets the **portable native build** problem — compile and link C/C++ (plus
D, Fortran, Vala, C#, Java, assembly, …) across GCC/Clang/MSVC and across
Unix/macOS/Windows — but it makes a distinctive set of bets that separate it from
both `Make`-style tools and the declarative-DSL generation tools. Quoting the
project's own `README.md` ([`README.md`][readme]):

> _"Waf is a Python-based framework for configuring, compiling and installing
> applications."_

It then lists the features that matter for a multi-package tree:

> - _"**Automatic build order**: the build order is computed from input and output
>   files, among others"_
> - _"**Automatic dependencies**: tasks to execute are detected by hashing files
>   and commands"_
> - _"**Performance**: tasks are executed in parallel automatically, the startup
>   time is meant to be fast (separation between configuration and build)"_
> - _"**Flexibility**: new commands and tasks can be added very easily through
>   subclassing … through dynamic method replacement"_
>   ([`README.md`][readme])

Unlike [`Meson`][meson]/[`GN`][gn] (which _generate_ a `build.ninja` and hand it
to a separate executor) or [`CMake`][cmake] (which generates `Makefile`s/IDE
projects), **Waf is its own executor**: a single `Python` process reads the
`wscript`s, builds an in-memory task DAG, and schedules the compile/link commands
itself with its own thread-pool runner. There is no generated intermediate build
file. This makes Waf closest in spirit to [`SCons`][scons] — both execute the
configuration program directly and both detect change by **hashing**, not
`mtime` — but Waf is engineered for a fast startup and a small, embeddable core.

### Design philosophy

From the Waf Book's introduction ([The Waf Book][book]), the four constraints
that shape everything:

> 1. _"Waf requires only Python to function and does not depend on any additional
>    software or libraries."_
> 2. _"Waf does not introduce a new language, as it is built using reusable Python
>    modules."_
> 3. _"Waf does not rely on a code generator such as Makefiles, resulting in
>    efficient and extensible builds."_
> 4. _"Waf defines targets as objects, distinguishing between the definition of
>    targets and the execution of commands."_

Three consequences follow that govern the monorepo behavior analyzed below:

1. **The build description is a program, not data.** A `wscript` is a `Python`
   module with predefined functions (`options`, `configure`, `build`, `dist`, …);
   any of them can run arbitrary `Python`. There is no membership array, no
   restricted DSL — the "topology" of a multi-package tree is whatever the
   `build()` function chooses to `recurse()` into.
2. **Configure once, build many.** Waf separates a heavyweight `configure` step
   (probe compilers, resolve flags, write a config cache `c4che/`) from a fast
   `build` step. The configuration result is persisted so subsequent builds skip
   re-probing — the "separation between configuration and build" the README cites.
3. **Hash-based, not timestamp-based.** A task re-runs when its **signature**
   (a hash of its inputs, its command line / `hcode`, scanned implicit
   dependencies, and the environment variables it reads) differs from the stored
   one — the foundation that lets Waf bolt on a content-addressed shared
   [`wafcache`](#4-caching--remote-execution) across machines.

---

## How it works

### The single file, the `wscript`, and the command words

Waf is invoked as `./waf <command> [<command> …]`. Each command word maps to a
same-named function in the top `wscript`. The canonical lifecycle:

```bash
./waf configure    # probe toolchain, resolve options → write build/c4che/
./waf build        # assemble the task DAG and run it (alias: ./waf)
./waf install      # stage build outputs to the prefix
./waf dist         # roll a source tarball
./waf distclean    # remove the build directory + lock file
```

`waf_entry_point` ([`waflib/Scripting.py`][scripting]) bootstraps a run: it
creates an `options` context, parses the command line, then **climbs the directory
tree upward** looking for the project lock file (`.lock-waf_<platform>_build`,
default from `Options.lockfile`) or the first `wscript` — so `./waf` works from
any sub-directory of a configured project. A minimal top `wscript`
([`demos/c/wscript`][democ]):

```python
# wscript  (project root)
VERSION = '0.0.1'
APPNAME = 'cc_test'

top = '.'          # source root
out = 'build'      # build (variant) directory

def options(opt):
    opt.load('compiler_c gnu_dirs')

def configure(conf):
    conf.load('compiler_c gnu_dirs')

def build(bld):
    bld.recurse('program stlib stlib-deps shlib')   # descend into sub-packages
```

The `options`/`configure`/`build` functions each receive a context
(`OptionsContext`, `ConfigurationContext`, `BuildContext`) — Waf "defines targets
as objects, distinguishing … definition of targets and … execution of commands."
Targets are declared by **task generators** (`bld.program(...)`, `bld.stlib(...)`,
`bld.shlib(...)`, or a raw `bld(rule=..., ...)`) which are _posted_ into concrete
`Task` objects only when the build runs.

### 1. Workspace declaration & topology

Waf has **no workspace manifest and no membership glob**. A "workspace" is simply
a tree of `wscript` files, and topology is **constructed imperatively** by calls
to `recurse()`. There is exactly one root `wscript` (found by the upward climb);
every sub-package is pulled in only because some parent function explicitly
recurses into it.

`Context.recurse(dirs, name=None, mandatory=True, once=True)`
([`waflib/Context.py`][context]) is the whole mechanism. For each directory it
loads that directory's `wscript` and invokes the **same-named function** as the
current command (so `bld.recurse('src')` calls `src/wscript`'s `build`, while
`conf.recurse('src')` calls its `configure`):

```python
# waflib/Context.py — Context.recurse (abridged)
for d in Utils.to_list(dirs):
    if not os.path.isabs(d):
        d = os.path.join(self.path.abspath(), d)
    WSCRIPT     = os.path.join(d, WSCRIPT_FILE)            # 'wscript'
    WSCRIPT_FUN = WSCRIPT + '_' + (name or self.fun)       # e.g. 'wscript_build'
    node = self.root.find_node(WSCRIPT_FUN)
    if node and (not once or node not in cache):
        # a bare `wscript_build` file: exec its body directly
        exec(compile(node.read(...), node.abspath(), 'exec'), self.exec_dict)
    elif not node:
        node = self.root.find_node(WSCRIPT)                # a full 'wscript'
        user_function = getattr(load_module(node.abspath()), name or self.fun, None)
        user_function(self)                                # call build()/configure()/…
```

Two file conventions exist: a full **`wscript`** (a `Python` module whose
`build`/`configure`/… functions are looked up by name) or a lighter
**`wscript_build`** (a bare script body `exec`'d directly in the build phase — the
common case for leaf directories). A real multi-package tree
([`demos/c/stlib-deps/`][demostlib]) is just nested `recurse`s:

```python
# demos/c/stlib-deps/wscript_build  (a sub-package "workspace" root)
bld.recurse('libA')
bld.recurse('libB')
bld.recurse('libC')

bld.program(source='main.c', target='test_static_link_chain', use='B C')
```

```python
# demos/c/stlib-deps/libA/wscript_build
bld.stlib(target='A', source='external_vars.c',
          includes='.', export_includes='.')   # exports its public include dir
```

Because `recurse` runs **arbitrary `Python`**, "membership" can be computed — e.g.
`bld.recurse([n for n in os.listdir('libs') if …])` — but there is no declarative
list a tool can read without executing the build. This is the polar opposite of
[`Cargo`][cargo]'s `members = ["libs/*"]` or [`pnpm`][pnpm]'s `packages:` glob:
Waf's topology is **imperative and demand-driven**, discovered only by running the
script. The `once=True` default makes each `wscript` execute at most once per
context, so diamond recursion is idempotent rather than re-entrant.

> [!NOTE]
> The default `out = 'build'` puts **all** outputs of the whole recursed tree
> into a single root build directory — Waf is an _out-of-source_ build with one
> shared variant dir for the entire monorepo, not one per sub-package. This is the
> structural reason cross-package artifact reuse works at all (compare
> [`Meson`][meson], which also unifies into one `builddir`).

### 2. Dependency handling & isolation

Waf is **not** a package manager: there is no registry, no lockfile of external
versions, no symlink store, and no hoisting. Third-party libraries are either
detected on the system at `configure` time (`conf.check`, `conf.check_cfg` →
`pkg-config`) or **vendored as source** into the tree and built as ordinary
sub-packages. The interesting dimension is therefore **local cross-references
between sibling packages**, and Waf's answer is the **`use` keyword**.

A task generator names the libraries it consumes via `use='A B'`; the
`process_use` method ([`waflib/Tools/ccroot.py`][ccroot]) resolves those names to
sibling task generators, **topologically sorts** the transitive `use` graph
(raising on cycles), and propagates linker inputs and exported metadata
downstream:

```python
# waflib/Tools/ccroot.py — process_use (abridged)
names = self.to_list(getattr(self, 'use', []))
for x in names:
    self.use_rec(x)                      # recurse the transitive use graph
# topological sort of self.tmp_use_seen …
if use_prec:
    raise Errors.WafError('Cycle detected in the use processing %r' % use_prec)
# downstream inherits each used lib's exported include dirs & defines:
if getattr(y, 'export_includes', None):
    self.includes = self.includes + y.to_incnodes(y.export_includes)
if getattr(y, 'export_defines', None):
    self.env.append_value('DEFINES', self.to_list(y.export_defines))
```

So `use='A'` does three things at once: (a) adds `A`'s output (the `.a`/`.so`) as
a **link input**, creating a `run_after` ordering edge in the task DAG; (b) folds
`A`'s `export_includes` into the consumer's include path; (c) folds `A`'s
`export_defines` into the consumer's macros. This is Waf's equivalent of a local
cross-reference ([Yarn's `workspace:` protocol][yarn-berry], [`Cargo` path
deps][cargo]) — but resolved **by task-generator name within one build**, not by a
manifest dependency declaration. `use` also chains transitively (`B` uses `A`, the
program uses `B C`, and `A` is pulled in automatically).

Waf even lets a package opt out of one isolation default: `libC` above carries
`features='skip_stlib_link_deps'`, documented in the demo as preventing static
libraries from depending on each other so "the only way `libC` is re-archived is
if … `diff.c` or any of its dependencies change." Isolation between sibling
packages is therefore tunable per task generator, not a fixed policy.

> [!IMPORTANT]
> Because every sub-package builds into the **same** `build/` directory and shares
> the same `BuildContext`, Waf gets cross-package reuse _for free within one
> tree_: `libA` is compiled once and linked into every dependent. But there is **no
> cross-_project_ store** — two separate repos that both vendor `zlib` each build
> their own copy (the same limitation as [`Meson`][meson]; contrast the
> content-addressed sharing of [`Bazel`][bazel]/[`pnpm`][pnpm], or Waf's own
> opt-in [`wafcache`](#4-caching--remote-execution), which _can_ bridge that gap).

### 3. Task orchestration & scheduling

This is Waf's strongest dimension and where it differs most from the
generate-then-execute tools. Waf **is** the scheduler: it builds a task DAG in
memory and runs it with its own producer/consumer thread pool — there is no
`ninja` underneath.

**The DAG.** Each task generator is _posted_ into one or more `Task` objects with
explicit `inputs`, `outputs`, and `run_after` predecessor edges (the edges that
`use` and `bld.add_manual_dependency` create). Tasks are partitioned into ordered
**build groups** (`bld.add_group()` / `bld.set_group()`,
[`waflib/Build.py`][build]); all tasks in group _N_ complete before group _N+1_
begins, which is how cross-cutting ordering (codegen before compile) is expressed
when a pure data dependency is not enough.

**Change detection by signature.** A task's `runnable_status()`
([`waflib/Task.py`][task]) compares a freshly computed `signature()` against the
value stored from the previous build:

```python
# waflib/Task.py — Task.signature (abridged)
self.m = Utils.md5(self.hcode, usedforsecurity=False)
self.sig_explicit_deps()         # hash the input files
self.sig_vars()                  # hash the env vars / task.vars the command reads
if self.scan:
    self.sig_implicit_deps()     # hash scanner results (e.g. #include graph)
ret = self.cache_sig = self.m.digest()
```

```python
# waflib/Task.py — Task.runnable_status (abridged)
for t in self.run_after:
    if not t.hasrun:        return ASK_LATER        # predecessor not done yet
    elif t.hasrun < SKIPPED: return CANCEL_ME       # predecessor failed
new_sig = self.signature()
prev_sig = bld.task_sigs[self.uid()]                # from the persisted DB
if new_sig != prev_sig:     return RUN_ME           # inputs/command/env changed
# … also verify each output still exists and was produced by *this* task …
return (self.always_run and RUN_ME) or SKIP_ME
```

The signature mixes **`hcode`** (a hash of the command/rule itself, so changing a
compiler flag invalidates), **explicit input hashes**, **implicit-dependency
hashes** from language scanners (the C preprocessor `#include` scan lives in
`c_preproc.py`), and **`sig_vars`** (the environment variables the task reads). A
task `SKIP_ME`s only if all of these match _and_ every output file still exists and
is still attributed to it.

**Parallel execution.** `Runner.Parallel` ([`waflib/Runner.py`][runner]) is a
producer that feeds ready tasks to a `Spawner` thread, which spins up one
short-lived `Consumer` thread per task, bounded by a semaphore set to `--jobs`:

```python
# waflib/Runner.py — Spawner (abridged)
class Spawner(Utils.threading.Thread):
    def __init__(self, master):
        self.sem = Utils.threading.Semaphore(master.numjobs)  # cap concurrency
        ...
    def loop(self):
        while 1:
            task = master.ready.get()
            self.sem.acquire()
            Consumer(self, task)        # one consumer thread runs one task
```

`refill_task_list` walks the build-group iterator, calls `prio_and_split` to
separate tasks whose predecessors are done (`outstanding`, runnable now) from
those still waiting (`incomplete`), and as each task finishes, `mark_finished`
un-freezes any successor all of whose `run_after` predecessors have now run. A
**deadlock detector** fires if `postponed` tasks stop making progress — the common
cause being "conflicting build order declaration, for example `X run_after Y` and
`Y run_after X`" ([`waflib/Runner.py`][runner]). So within one process Waf gives
automatic, dependency-correct **parallelism** and **incremental** rebuilds with no
external executor.

> [!NOTE]
> There is **no affected-by-Git-ref slicing** (`--since <ref>`) and no content
> hashing across repository revisions the way [`Nx`][nx]/[`Turborepo`][turborepo]
> compute affected projects. Incrementality is purely "did this task's signature
> change since the last local build", read from the persisted DB below. The
> `--targets`/`--files` flags (see §5) provide the only built-in slicing.

### 4. Caching & remote execution

Waf has three layers of caching, increasing in scope:

**(a) The persisted build database — local incrementality.** After each build,
`BuildContext.store` ([`waflib/Build.py`][build]) pickles a fixed set of
attributes to `build/.wafpickle-<platform>-<pyver>-<abi>`:

```python
# waflib/Build.py
SAVED_ATTRS = 'root node_sigs task_sigs imp_sigs raw_deps node_deps'.split()
```

`task_sigs` (task UID → last signature) and `node_sigs` (output file → producing
task) are exactly what `runnable_status` consults next time, so this pickle **is**
the incremental cache. The `configure` step separately writes the resolved
environment to the config cache directory `build/c4che/` (`CACHE_DIR = 'c4che'`),
which is why a reconfigure is unnecessary on a plain rebuild. The project lock
file `.lock-waf_<platform>_build` records the configured `run_dir`/`top_dir`/
`out_dir` so the entry-point climb can re-anchor.

**(b) `wafcache` — a content-addressed _shared_ object cache.** The optional
`wafcache` tool turns task signatures into cache keys and stores task **outputs**
keyed by `(task.uid, signature)`, so an identical compile on another checkout — or
another machine — is fetched instead of re-run. It is configured entirely through
the environment ([wafcache docs][wafcache]):

```bash
# local shared folder (default ~/.cache/wafcache_user), or a cloud bucket:
WAFCACHE=gs://my-bucket/    ./waf build      # Google Cloud Storage
WAFCACHE=s3://my-bucket/    ./waf build      # S3
WAFCACHE=minio://my-bucket/ ./waf build      # MinIO
WAFCACHE_NO_PUSH=1 ./waf build               # read-only (CI consumers)
WAFCACHE_EVICT_MAX_BYTES=… WAFCACHE_EVICT_INTERVAL_MINUTES=…   # LRU trim
```

Because the key is the **content signature**, `wafcache` is Waf's content-addressed
analogue to a [`Bazel`][bazel] action cache — bridging the cross-_project_ reuse
gap §2 noted — but it caches _compile/link outputs_, not hermetic actions, and
trusts the signature rather than sandboxing inputs.

**(c) `netcache_client` — a network cache protocol.** A second extra
([`waflib/extras/netcache_client.py`][netcache]) implements a push/pull client
against a small cache server (`NETCACHE=host:port`, default push `11001` / pull
`12001`): `bld.load('netcache_client')` makes the build fetch task outputs over a
socket before executing them locally.

> [!WARNING]
> None of these is a **REAPI** remote-_execution_ backend. Waf can cache and fetch
> task **outputs** remotely (`wafcache` to a cloud bucket, `netcache` to a server),
> but it always _executes_ tasks in its own local process pool — there is no
> farming of actions out to a cluster the way [`Bazel`][bazel]/[`Buck2`][buck2]/
> [`Pants`][pants] drive `BuildBuddy`/`Buildbarn`/`NativeLink`. Remote = remote
> _cache_, not remote _execution_.

### 5. CLI / UX ergonomics

Waf's command boundary is **command words that map to `wscript` functions**, with
a small set of global flags rather than a per-package `--filter` grammar
([`waflib/Options.py`][options]):

| Flag / form              | Role                                                                            |
| ------------------------ | ------------------------------------------------------------------------------- |
| `./waf configure build`  | Run several commands in sequence; each calls the same-named `wscript` function  |
| `-j N`, `--jobs N`       | Parallel job count for the runner's semaphore (defaults to CPU count / `$JOBS`) |
| `--targets=t1,t2`        | Build only the named task generators (and their dependencies) — package slicing |
| `--files=*/main.c,*/x.o` | "Step" mode: process only files matching the regexp (per-file slicing)          |
| `-o`, `--out DIR`        | Override the build (variant) directory                                          |
| `-t`, `--top DIR`        | Override the source root (skip the upward `wscript` climb)                      |
| `-p`, `--progress`       | Progress bar (`-pp` = IDE-style output)                                         |
| `--zones=…`, `-v`        | Debug zones / verbosity (`task_gen`, `deps`, `tasks`, …)                        |
| `--prefix`, `--destdir`  | Install layout                                                                  |

The closest thing to a "run X across every member" loop is built into the model
itself: because `./waf build` already recurses the whole tree into one DAG, a
single command **is** the broadcast — there is no `yarn workspaces foreach`
([`yarn-berry`][yarn-berry]) equivalent because the build is unified. Slicing
_down_ to a sub-package is done with **`--targets`** (by task-generator name) or
**`--files`** (by path regexp), not a `-p <package>` / `--filter <pattern>` /
`--since <ref>` vocabulary like [`pnpm`][pnpm]/[`Nx`][nx]/[`Turborepo`][turborepo].

New commands are trivially added — subclass `BuildContext` and the class name
becomes a `./waf <name>` command — so projects routinely grow custom verbs
(`./waf docs`, `./waf benchmark`) that themselves `recurse()` the tree. The
ergonomics are thus "one process, many command words, arbitrary `Python` per
command," which is maximally flexible and minimally standardized.

---

## Strengths

- **Zero install, single file.** Waf is one ≈100 KiB `Python` script with the
  library embedded; "requires only Python to function and does not depend on any
  additional software." A project vendors `waf` and is self-contained.
- **Its own fast parallel executor.** No generated `Makefile`/`build.ninja` and no
  second tool: Waf builds the DAG and runs it with a semaphore-bounded thread pool,
  with automatic build order and a deadlock detector.
- **Hash-based, command-aware incrementality.** Signatures fold input hashes, the
  command/`hcode`, scanner-discovered implicit dependencies, and the environment
  variables a task reads — so flag changes and header changes both invalidate
  correctly, without `mtime` games.
- **Imperative `recurse()` topology.** A multi-package tree is just nested
  `wscript`s; "membership" can be _computed_ in `Python`, and everything compiles
  into one shared `build/` for free cross-package reuse within the tree.
- **`use`-based local cross-references** with transitive `export_includes`/
  `export_defines` propagation and a topological sort with cycle detection.
- **Content-addressed shared cache (`wafcache`)** to local folders or GCS/S3/MinIO
  buckets, plus a `netcache` network-cache client — cross-machine output reuse.
- **Extensible to the core.** New commands, task classes, and tools are subclasses;
  "bottlenecks for specific builds can be eliminated through dynamic method
  replacement."

## Weaknesses

- **No declarative manifest.** Topology, dependencies, and options are all
  expressed as executing `Python`; a tool cannot read the member set or the
  dependency graph without _running_ the build, defeating static analysis.
- **No external package manager / version resolution.** No registry, no lockfile of
  upstream versions, no `workspace:`-style protocol — external deps are
  system-probed or vendored as source by hand.
- **Remote _cache_, not remote _execution_.** `wafcache`/`netcache` fetch outputs;
  there is no REAPI action execution on a cluster.
- **No affected-by-ref slicing.** Incrementality is per-local-build signature
  diffing; no `--since <ref>`/Git-aware affected-project computation.
- **`Python`-program builds are powerful but un-sandboxed.** Arbitrary code in
  `wscript`s makes builds hard to reason about, cache hermetically, or audit —
  the same double edge as [`SCons`][scons].
- **Smaller, niche community.** Long associated with specific large C/C++ codebases
  (e.g. Samba) and a single primary author; documentation is good but the
  ecosystem is far smaller than [`CMake`][cmake]/[`Meson`][meson].
- **Single-machine scaling ceiling.** Parallelism is one process's thread pool;
  scaling beyond one host means the optional caches, not distributed execution.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                       | Trade-off                                                                                       |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Build description is a `Python` program (`wscript`)            | Full language power, no new DSL, "dynamic method replacement" for tricky builds | Topology/deps are opaque to tooling; nothing is statically readable without executing the build |
| Be its own executor (no generated `Makefile`/`ninja`)          | One tool, one process; full control over scheduling and incrementality          | No reuse of `ninja`'s mature executor; parallelism is bounded by one host's thread pool         |
| Imperative `recurse()` topology (no membership array/glob)     | A package tree is just nested scripts; membership can be computed               | No declarative "all members" view; CI/IDE tooling must run Waf to learn the graph               |
| Hash task signatures (inputs + `hcode` + scanner + env vars)   | Correct, command-aware incrementality; foundation for a shared content cache    | Hashing cost per task; trusts signatures rather than sandboxing inputs                          |
| `use` = name-based local cross-reference, topologically sorted | Sibling libraries wire up by name with transitive include/define export         | References resolve only _within_ one build; not a cross-project dependency declaration          |
| One shared `out = 'build'` for the whole recursed tree         | Free cross-package artifact reuse; out-of-source by default                     | No per-package isolation of outputs; no cross-_project_ store without `wafcache`                |
| Caching layered as optional extras (`wafcache`, `netcache`)    | Core stays a tiny single file; cloud/shared caching is opt-in                   | Remote = cache only, never remote _execution_; configured via env vars, not first-class flags   |
| Ship as one embedded single-file script                        | Zero-dependency, vendorable, reproducible toolchain                             | Upgrades mean re-vendoring the file; the embedded `waflib` can drift from the host `Python`     |

---

## Sources

- [`ita1024/waf` — canonical GitLab repository][repo] (source for all quoted file paths; `master` @ `4d54214`, `WAFVERSION 2.1.9`)
- [`waf-project/waf` — GitHub mirror][gh]
- [The Waf Book — design goals, model, `wscript` functions][book]
- [Waf API documentation][apidocs] · [`waf.io` home][home]
- [`README.md` — "ABOUT WAF" feature list (verbatim)][readme]
- [`waflib/Context.py` — `recurse()`, `wscript`/`wscript_build`, run-dir constants][context]
- [`waflib/Scripting.py` — `waf_entry_point`, command dispatch, lock-file climb][scripting]
- [`waflib/Build.py` — `BuildContext`, build groups, `SAVED_ATTRS` persisted DB, `c4che`][build]
- [`waflib/Task.py` — `signature()`, `runnable_status()`, `RUN_ME`/`SKIP_ME` states][task]
- [`waflib/Runner.py` — `Parallel` producer, `Spawner`/`Consumer` thread pool, deadlock detector][runner]
- [`waflib/Tools/ccroot.py` — `process_use`, `export_includes`/`export_defines`, topological sort][ccroot]
- [`waflib/Options.py` — CLI flags (`-j`, `--targets`, `--files`, `-o`, `-t`, `-p`)][options]
- [`waflib/extras/netcache_client.py` — network cache push/pull client][netcache]
- [wafcache — content-addressed shared cache (`WAFCACHE`, GCS/S3/MinIO)][wafcache]
- Sibling tools: [`SCons`][scons] · [`Meson`][meson] · [`CMake`][cmake] · [`GN` + `Ninja`][gn] · [`Cargo`][cargo] · [`pnpm`][pnpm] · [`Yarn Berry`][yarn-berry] · [`Nx`][nx] · [`Turborepo`][turborepo] · [`Bazel`][bazel] · [`Buck2`][buck2] · [`Pants`][pants] · [the D landscape][d-landscape]

<!-- References -->

[repo]: https://gitlab.com/ita1024/waf
[gh]: https://github.com/waf-project/waf
[book]: https://waf.io/book/
[apidocs]: https://waf.io/apidocs/
[home]: https://waf.io/
[readme]: https://gitlab.com/ita1024/waf/-/blob/master/README.md
[context]: https://gitlab.com/ita1024/waf/-/blob/master/waflib/Context.py
[scripting]: https://gitlab.com/ita1024/waf/-/blob/master/waflib/Scripting.py
[build]: https://gitlab.com/ita1024/waf/-/blob/master/waflib/Build.py
[task]: https://gitlab.com/ita1024/waf/-/blob/master/waflib/Task.py
[runner]: https://gitlab.com/ita1024/waf/-/blob/master/waflib/Runner.py
[ccroot]: https://gitlab.com/ita1024/waf/-/blob/master/waflib/Tools/ccroot.py
[options]: https://gitlab.com/ita1024/waf/-/blob/master/waflib/Options.py
[netcache]: https://gitlab.com/ita1024/waf/-/blob/master/waflib/extras/netcache_client.py
[democ]: https://gitlab.com/ita1024/waf/-/blob/master/demos/c/wscript
[demostlib]: https://gitlab.com/ita1024/waf/-/tree/master/demos/c/stlib-deps
[wafcache]: https://waf.io/apidocs/tools/wafcache.html
[scons]: ../scons/
[meson]: ../meson/
[cmake]: ../cmake/
[gn]: ../gn/
[cargo]: ../cargo/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[nx]: ../nx/
[turborepo]: ../turborepo/
[bazel]: ../bazel/
[buck2]: ../buck2/
[pants]: ../pants/
[d-landscape]: ../../async-io/d-landscape.md
