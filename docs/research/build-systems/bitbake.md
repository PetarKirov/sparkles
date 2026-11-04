# BitBake (Python / OpenEmbedded)

BitBake is the task engine underneath OpenEmbedded and the Yocto Project: a metadata interpreter
that turns recipes into a task DAG, and a runqueue that executes it. Its answer to "is this task
up to date?" is neither an mtime nor an observed file access but a **hash of the task's declared
inputs**, carried into every dependent and written into the _filename_ of a stamp. Vocabulary is
[concepts]'s; this page does not redefine _scheduler_, _rebuilder_, _trace_, _minimality_ or
_early cutoff_.

**Last reviewed:** November 2, 2026

| Field             | Value                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------- |
| Language          | Python 3.9+ — `lib/bb/__init__.py` refuses older interpreters; `__version__ = "2.20.0"`     |
| License           | GPL-2.0-only (`LICENSE`), with MIT-tagged individual files (`LICENSE.MIT`)                  |
| Repository        | [openembedded/bitbake][repo]                                                                |
| Documentation     | In-tree Sphinx manual: `doc/bitbake-user-manual/` (execution, metadata, variables)          |
| Category          | Industry — distro-scale embedded Linux; metadata-driven, no sandbox, no remote execution    |
| Clone (pinned)    | `74128534302fbf8164ade07b200b90b731caa0ad`, HEAD commit dated 2026-10-25                    |
| Metadata language | recipes `.bb`, classes `.bbclass`, appends `.bbappend`, config `.conf`, layers `layer.conf` |
| Scheduler         | `speed` by default; `basic` and `completion` selectable through `BB_SCHEDULER`              |
| Rebuild identity  | `basehash` → `taskhash` → `unihash`, materialised as `<stamp>.<task>.<hash>[.<extrainfo>]`  |

## Overview

### What it solves

A distribution image is thousands of recipes times roughly ten tasks each — `do_fetch`,
`do_compile`, `do_install`, `do_package`, on to `do_image` — cross-compiled for several machines. A
clean build is hours; the engineering is in never doing one. BitBake is deliberately the _engine
half_:

> "BitBake is a generic task execution engine that allows shell and Python tasks to be run
> efficiently and in parallel while working within complex inter-task dependency constraints.
> One of BitBake's main users, OpenEmbedded, takes this core and builds embedded Linux software
> stacks using a task-oriented approach."
>
> — [`README`][readme]

That is also the page's caveat: the shared-state cache, the `OEBasicHash` signature generator and
the sstate archive layout live in OpenEmbedded-Core's metadata, not here; BitBake ships only the
_protocol_ by which metadata supplies a cache.

### Design philosophy

**The graph is complete before work starts**: `RunQueueData` walks providers, task flags and
`addtask` chains into one static DAG, and a cycle is fatal rather than a runtime discovery.
**Identity is a hash, not a timestamp**: the stamp's _name_ carries the hash of its inputs, so
"up to date" is a filename lookup and a metadata edit invalidates everything downstream by
construction. **Caching is a protocol**, not a feature: the engine asks metadata
`BB_HASHCHECK_FUNCTION` ("which of these hashes can you supply?") and calls a `*_setscene`
function per task, and the metadata answers.

> "If a signature is the same, an object can be reused."
>
> — [`bitbake-user-manual-execution.rst`][manual-execution]

## How it works

### Metadata is the task graph

`bblayers.conf` names layers; each `conf/layer.conf` extends `BBPATH` and `BBFILES`; every matching
`.bb` is parsed, `.bbappend` files amend it, `.bbclass` files inject shared behaviour. A task is a
shell or Python function promoted by `addtask printdate after do_fetch before do_build`.
Dependencies from `DEPENDS`, `RDEPENDS`, `do_X[depends] = "pn:do_y"`, `[deptask]`, `[rdeptask]`,
`[recrdeptask]`, `[recideptask]` and `[mcdepends]` all resolve into one `depends` set. `PROVIDES`,
`PREFERRED_PROVIDER_virtual/kernel` and `PREFERRED_VERSION` then decide which recipe satisfies a
target.

Four flags carry behaviour the scheduler and rebuilder honour: `[noexec]` (placeholder), `[nostamp]`
(never current), `[lockfiles]` (mutual exclusion: "any task that attempts to lock an already locked
file will block until the lock is released") and `[file-checksums]`, which adds files to the
signature with a **boolean saying whether the path existed** — "It is important to record any paths
which the task looked at and which didn't exist"
([`bitbake-user-manual-metadata.rst`][manual-metadata]).

### The runqueue is a ready-set weighted by reverse dependencies

`RunQueueData` produces `runtaskentries` (id, `depends`, `revdeps`, `weight`, `hash`, `unihash`).
The weight pass seeds build endpoints at 10 and pushes weight down the reverse-dependency edges —
"heavier weighted tasks have more dependencies and hence should be executed sooner for maximum
speed" (`calculate_task_weights`) — and the same pass detects unbuildable tasks and prints the
offending chains, so a cycle fails before a worker is forked ([`runqueue.py`][runqueue]).

Three schedulers consume that map: `basic` (parse order), `speed` (default, weight order) and
`completion`, which reorders so a started recipe is finished, "where disk space is at a premium
and classes like OE's `rm_work` are in force". `BB_NUMBER_THREADS` sets worker count; each worker is
a forked `bin/bitbake-worker` over a pipe. Two throttles sit above the ready set without ever
starving the build: pressure-stall data from `/proc/pressure/{cpu,io,memory}`
(`BB_PRESSURE_MAX_CPU`, `…_IO`, `…_MEMORY`), falling back to `BB_LOADFACTOR_MAX` — "Bitbake requires
that at least one task be active".

### A stamp file keyed by the task's hash is the trace

With the `basichash` generator the stamp name is `<STAMP>.<task>.<hash>[.<extrainfo>]`, where
`extrainfo` comes from `[stamp-extra-info]` (OpenEmbedded uses it for machine-specific tasks) and
`hash` is the `unihash` when one is known, else the `taskhash` ([`siggen.py`][siggen],
`stampfile`). A `_setscene` stamp reuses the _covered task's_ hash, which is why a
restored-from-cache task counts as current.

`check_stamp_task` is then small: a missing stamp is not current, a `nostamp` task is never current,
a `_setscene` stamp is current by definition, and mtimes matter only between tasks of the same
recipe. As the manual says, "a hash is appended to the stamp so that if the configuration changes,
the stamp becomes invalid and the task is automatically rerun"
([`bitbake-user-manual-execution.rst`][manual-execution]).

`bitbake -f` writes a `.taint` file whose random UUID enters the task's hash, so the forced task _and_
everything downstream rebuild.

### Three hashes: `basehash`, `taskhash`, `unihash`

- **`basehash`** hashes the task's own metadata closure: `bb.data.generate_dependencies` walks every
  variable and function the task's text references (shell and Python parsed separately), closes the
  set transitively, then hashes values minus `BB_BASEHASH_IGNORE_VARS`.
- **`taskhash`** folds in the sorted dependency `unihashes`, the `[file-checksums]`/`SRC_URI`
  checksums and any taint:

  ```python
  def calc_taskhash(sigdata):
      data = sigdata['basehash']
      for dep in sigdata['runtaskdeps']:
          data = data + sigdata['runtaskhashes'][dep]
      for c in sigdata['file_checksum_values']:
          if c[1]:
              if "./" in c[0]:
                  data = data + c[0]
              data = data + c[1]
      return hashlib.sha256(data.encode("utf-8")).hexdigest()
  ```

  That is a [verifying trace][concepts]: dependency _hashes_, not names and not timestamps, are
  what the next build checks.

- **`unihash`** is the `taskhash` unless a hash-equivalence server knows better.

The engine checks the metadata half of its own premise: `_build_data` recomputes the basehash on
reparse and fails loudly if it moved — "the basehash value changed … The metadata is not
deterministic and this needs to be fixed" ([`siggen.py`][siggen]).

Every hashed task also dumps a zstd-compressed JSON record named
`<stamp>.<task>.sigdata.<unihash>` holding `taskdeps`, `basehash`, `varvals`, `runtaskdeps`,
`runtaskhashes`, `taskhash`, `unihash` and any `taint`. `compare_sigfiles` walks two of them and names
the variable or dependency hash that diverged — the `-Sprintdiff` answer to "couldn't be used from the
cache because…". A trace that records _why_ it is not equal turns "why did this rebuild?" into a diff:
the single most copyable idea in the engine.

### `setscene`: the cache protocol the engine does not implement

Lookup is split from restoration, because one bulk question beats thousands of individual ones:

| Hook                    | Question it answers                                                       |
| ----------------------- | ------------------------------------------------------------------------- |
| `BB_HASHCHECK_FUNCTION` | given `{tid: hash}`, which hashes could you supply? (fast; may lie)       |
| `<task>_setscene`       | restore that task's outputs, or fail                                      |
| `BB_SETSCENE_DEPVALID`  | given a successful setscene task, which of its dependencies must also run |
| `BB_SETSCENE_ENFORCE`   | a cache miss is a build failure, not a rebuild                            |

The first stage is an admitted over-approximation: "The returned list need not be completely
accurate. A given setscene task can still later fail."
([`bitbake-user-manual-ref-variables.rst`][manual-ref]). The runqueue then builds a **scene
queue** containing only `*_setscene` tasks, with ordinary tasks between them squashed into the
setscene task above, so one restored artifact covers many tasks — "it is pointless to obtain a
compiler if you already have the compiled binary"
([`bitbake-user-manual-execution.rst`][manual-execution]). Tasks sharing a hash are **deferred**
onto one another (`sq_deferred`, "Deferring %s after %s") so duplicates cannot race for one artifact.

Coverage falls out mechanically: a successful setscene task marks the tasks it covers
`tasks_covered`; a failure or unvalidated hash leaves them `tasks_notcovered` and the real tasks
run. `BB_SETSCENE_ENFORCE` closes the loop for CI — a covered task that would have to execute for
real errors with "Task %s.%s attempted to execute unexpectedly and should have been setscened"
([`runqueue.py`][runqueue]): a _cache-completeness gate_ rather than a cache.

### Hash equivalence: the only source of early cutoff

`taskhash` is an input identity, so two builds differing irrelevantly (a path, an unused variable)
ripple through the graph. BitBake pushes that out of the engine into a service: `lib/hashserv` is a
small async RPC server over SQLite (or SQLAlchemy) with two tables, `(method, taskhash) → unihash`
and `(method, outhash) → …`. When a task finishes, the metadata's hashequiv method hashes its
_output_, and the server decides whether that output has been seen:

> "A matching output hash was found. Set our taskhash to the same unihash since they are
> equivalent"
>
> — [`lib/hashserv/server.py`][hashserv-server], `handle_report`

Input hash identifies the work, output hash identifies the _result_, and `unihash` names the class
downstream tasks hash — so an irrelevant change stops at the task that absorbed it. Without a server
the fallback is the identity mapping ([`siggen.py`][siggen]).

## Analysis spine

### Placement in the scheduler × rebuilder grid

**Topological × verifying traces** — the `Ninja`-shaped cell of [concepts]'s Table 2. The graph is
materialised before execution, a cycle is fatal, and currency is decided by a trace of dependency
hashes recorded beside the stamp. Three deviations the grid has no axis for: a **memo table is
consulted before the topological order runs** (`BB_HASHCHECK_FUNCTION` + `*_setscene`), the
`CloudBuild` cell's mechanism grafted onto a static scheduler; the memo table is keyed on the full
signature, not task identity, so it buys reuse across builds and machines but no _minimality_ the
trace did not already give; and **early cutoff is external**, existing only where a hash-equivalence
server collapses two input identities into one output identity.

It does not fit a dynamic-dependency cell: `runtaskentries.depends` is frozen before any task runs,
the scheduler has no suspend/resume primitive, and an undeclared read is neither detected nor
followed — the stance opposite to [BuildXL][buildxl].

### 1. Task model & scheduling

The unit is `(recipe or virtual target, task name)`. Execution is a ready-set over that static DAG,
ordered by structural weight (count of transitive dependents, endpoints seeded at 10), on
`BB_NUMBER_THREADS` forked workers. There is no speculation, no historical runtime estimate and no
critical-path priority from recorded durations — the priority signal is purely structural.

### 2. Rebuilding & correctness

Currency is the existence of a stamp whose name embeds the current hash: exact with respect to
recorded inputs, and cheap (one `stat`). `nostamp` opts a task out permanently, taint opts one build
out, `[file-checksums]` extends the input set to files the task body reads _including paths that
were absent_ — the rare and valuable half of input recording.

The correctness argument is conditional: hash equality implies input equality, which implies output
equality only if the task is deterministic. A `do_compile` that reaches `/usr/include/foo.h` through
the host toolchain leaves no trace: the build stays green and its cache entry is wrong. That is why
OpenEmbedded's metadata is enormous, and why the manual spends a section on
`[vardeps]`/`[vardepsexclude]` repair. Early cutoff exists only through `unihash`: with no server, a
rebuilt-but-identical output still changes every dependent's `taskhash` — "any metadata change will
change the task hash, automatically causing the task to be run again"
([`bitbake-user-manual-execution.rst`][manual-execution]).

### 3. Dependency discovery

Declared, at two levels: between tasks, explicit flags and nothing inferred; within a task, BitBake
_does_ infer — its code parser walks shell and Python function bodies to find referenced variables
and functions, and that closure becomes the `basehash`. That is real static analysis of the task's
own text — editing an unrelated variable does not invalidate every task. It is not observation of
execution — no syscalls, no FUSE, no depfiles, no sandbox, exactly the gap [Rattle][rattle] closes.
Where the parser cannot model something, the remedies are declarative — `[vardeps]` to add,
`[vardepsexclude]` to remove, `[file-checksums]` to add files with existence booleans, `-DDD` to
surface what it could not resolve. Undeclared file reads are not errors, not warnings and not
dependencies: they are silence. That single fact explains BitBake's shape more than any other.

### 4. Store & caching

Three separate things are called "cache", and only one lives in the engine. The **parse cache**
(`lib/bb/cache.py`, `__cache_version__ = "156"`) pickles recipe metadata so a second invocation
skips parsing, keyed by a checksum of the base configuration with `BB_HASHCONFIG_IGNORE_VARS` to
exclude variables like `TIME`. **Build outputs** are stamps in the engine and sstate archives by
metadata convention — the engine knows only the lookup/restore protocol. **Hash equivalences** are
the `hashserv` database, optionally chained upstream (`BB_HASHSERVE_UPSTREAM`), with per-user
permissions and an explicit warning that `BB_HASHSERVE_DB_DIR` cannot be NFS because SQLite locking
corrupts. There is no content-addressed store, no dedup and no eviction policy in the engine: a
task's identity is entirely its inputs, which makes the equivalence server necessary.

### 5. Hermeticity & provenance

No sandbox: a search of `lib/bb` for `unshare`, `seccomp` or namespace setup finds nothing, and the
only wrapper is an optional `FAKEROOT` command (OpenEmbedded uses `pseudo`) on `[fakeroot]` tasks,
which fakes ownership rather than isolating. A shell task is written to `${T}/run.do_<task>.<pid>`
with exported variables expanded and run as a normal process, logging to `log.do_*` — a
reproducibility asset, but a debugging aid rather than a boundary. Provenance in the SLSA/in-toto
sense is absent; the nearest artefact is the sigdata record, an _input manifest_ that can also ship
`PN`/`PV`/`PR` and its siginfo to the hash server with `SSTATE_HASHEQUIV_REPORT_TASKDATA` — auditing
why an entry was trusted, not attesting who produced it.

### 6. Distribution

None in the engine, deliberately: a grep of the tree for `REAPI` finds nothing, and there is no
remote execution client or worker protocol beyond the local fork. Distribution happens **through the
cache** — builders share an sstate directory or mirror and a hash-equivalence server, and each
re-executes only what neither can supply. Unlike an REAPI system, correctness depends on that shared
filesystem or HTTP mirror rather than on a CAS protocol, and the SQLite-backed equivalence server
constrains where it may run.

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a validated static DAG with a single-pass executor and no
memory of a previous run, so the cheap borrowings matter most:

- **Store a structured trace, not a verdict.** A `TaskTrace` of the variable and file digests behind
  a task turns "why did this rerun?" into a diff instead of an experiment.
- **Two-level identity is the cheapest early cutoff available.** Hashing inputs is simple and exact;
  a second, output-derived identity that dependents hash instead stops an irrelevant change from
  rippling — even, on one machine, via a local `taskhash → output digest` table.
- **Record absent probes.** `[file-checksums]`'s file-and-existence pairs are the insight
  [BuildXL][buildxl] reaches through syscalls: a path that matched nothing is a dependency on
  emptiness, and only a recorded miss notices it filling in.
- **`BB_SETSCENE_ENFORCE` is a CI pattern worth copying verbatim:** "every task must be
  cache-served" as a hard gate, which proves a cache complete rather than hoping it is.

## Strengths and weaknesses

- **A hash chain that is easy to reason about.** `basehash` → `taskhash` → `unihash` are three
  hashes with distinct jobs, each inspectable in a sigdata file.
- **A replaceable cache.** The engine never learns what an archive is; OpenEmbedded's sstate and a
  directory of tarballs are equally valid suppliers.
- **Explanatory traces.** `compare_sigfiles`, `-Sprintdiff` and the sigdata JSON separate a cache
  miss you can debug from one you learn to live with.
- **Operational realism.** Pressure-stall throttling, lockfiles, deferred duplicate setscene tasks
  and `BB_SETSCENE_ENFORCE` are details written by people who have run this at distro scale.
- **Correctness rests on declarations nobody checks.** An undeclared read, a non-deterministic task
  body or a stamp left by a hand-edited output all produce a confidently wrong build.
- **The split hides the interesting half.** sstate's format, retention and mirroring are not in this
  repository, so the store is not legible from the source.

## Key design decisions and trade-offs

| Decision                                     | Rationale                                                            | Trade-off                                                                         |
| -------------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Hash in the stamp filename, not a side table | Currency is one `stat`; no database to corrupt or migrate            | One file per task per hash; stamp directories grow without bound                  |
| Dependency hashes folded into `taskhash`     | A change propagates by construction; no dirty-set closure to compute | No early cutoff without an equivalence service; every edit ripples                |
| Signature from the metadata closure          | Static analysis of shell and Python catches most real inputs cheaply | Invisible to file reads; `[vardeps]` repair when it guesses wrong                 |
| Cache supply as a metadata protocol          | Engine stays policy-free; sstate, mirrors and plain dirs all fit     | The store is undocumented in-tree; behaviour differs per metadata layer           |
| Bulk `BB_HASHCHECK_FUNCTION` before setscene | One pass over hashes beats thousands of individual probes            | Over-approximation allowed; misses surface later as real task execution           |
| `unihash` from an external server            | Output identity, not input identity, is what dependents should hash  | Service plus SQLite plus upstream chaining; unusable on NFS; optional in practice |
| No sandbox, no remote execution              | Metadata declares its inputs; the toolchain is already on the host   | Under-declaration is silent; no REAPI ecosystem interop                           |
| `BB_SETSCENE_ENFORCE` as a gate              | Proves a cache is complete before shipping a build farm              | Any gap is a build failure, which needs `IGNORE_TASKS` carve-outs                 |

## Sources

- [`openembedded/bitbake`][repo] at commit `74128534302fbf8164ade07b200b90b731caa0ad` (clone at
  `$REPOS/build-systems-research/src/bitbake`; HEAD commit dated 2026-10-25, version `2.20.0` per
  `pyproject.toml` and `lib/bb/__init__.py`; the shallow clone carries no tags).
- Execution model and hooks: [`README`][readme], [execution][manual-execution],
  [metadata][manual-metadata], [variables][manual-ref].
- Engine: [runqueue][runqueue] (schedulers, weights, setscene), [siggen][siggen] (hashes, sigdata,
  equivalence client), [build][build] (run scripts, `FAKEROOT`), [data][data] and [cache][cache].
- Hash equivalence: [server][hashserv-server], [sqlite][hashserv-sqlite], [protocol][hashserv-init].
- Sibling pages: [concepts] and [a-la-carte] for the vocabulary and grid, [buildxl] for the opposite
  stance, [rattle] and [shake] for the tracing and trace-storage extremes.

<!-- References -->

[repo]: https://github.com/openembedded/bitbake
[readme]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/README
[manual-execution]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/doc/bitbake-user-manual/bitbake-user-manual-execution.rst
[manual-metadata]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/doc/bitbake-user-manual/bitbake-user-manual-metadata.rst
[manual-ref]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/doc/bitbake-user-manual/bitbake-user-manual-ref-variables.rst
[runqueue]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/runqueue.py
[siggen]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/siggen.py
[build]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/build.py
[data]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/data.py
[cache]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/cache.py
[hashserv-server]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/hashserv/server.py
[hashserv-sqlite]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/hashserv/sqlite.py
[hashserv-init]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/hashserv/__init__.py
[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[buildxl]: ./buildxl.md
[rattle]: ./rattle.md
[shake]: ./shake.md
