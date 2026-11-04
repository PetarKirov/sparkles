# tup (C, file-based build engine)

tup's engine in one sentence: a persistent SQLite graph records which files each command
_actually_ read, and an update takes the list of files that changed since last time, walks
only the commands reachable from that list, and executes them in topological order, rejecting
writes and generated-file reads the graph does not declare.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                                                |
| --------------------- | ---------------------------------------------------------------------------------------------------- |
| Language              | C; vendored SQLite, PCRE2, Lua and `inih` under `src/`                                               |
| License               | GPL-2.0 (`COPYING`)                                                                                  |
| Repository            | [`gittup/tup`][repo]                                                                                 |
| Documentation         | [`tup.1`][manual] (the fuller manual lives on the website, not in this clone)                        |
| Category              | Minimalist file-based build engine; companion to [tup (monorepo-tooling)][mono-tup]                  |
| Clone (pinned)        | `$REPOS/build-systems-research/src/tup`                                                              |
| Commit                | `c6f565e216a0820e39d65fa84ddaf830be03a476` (2026-07-29); single-commit clone, **no tags or history** |
| Version in tree       | not declared: [`src/tup/link.sh`][link-sh] derives it from `git describe` at link time               |
| Scheduler × rebuilder | Topological × dirty bit ([concepts] §5), refined by an observed read set and opt-in `^o` cutoff      |
| Persistent state      | `.tup/db` (SQLite, `DB_VERSION` 19), `.tup/options`, `.tup/tmp`, `.tup/mnt`                          |

> [!NOTE]
> **Delta against the workspace page.** [tup (monorepo-tooling)][mono-tup] covers the
> workspace verdict, `:`-rule grammar, variables, groups/bins, variants, caching absence and
> the CLI. This page stays inside the engine: the graph, the change frontier, the scheduler,
> the interception substrates, and what strictness buys.

## Overview

### What it solves

> "Tup is a file-based build system for Linux, OSX, and Windows. It takes as input a list of
> file changes and a directed acyclic graph (DAG). It then processes the DAG to execute the
> appropriate commands required to update dependent files."
>
> — [`README.md`][readme]

The change list is the load-bearing input. A Make-style tool must re-read every rule and `stat`
every file to answer "what is stale?", which is `O(project)`; tup asks what changed and follows
the graph upward from there. The residual scan is the only remaining `O(project)` cost, and the
monitor removes it: "With the monitor running, 'tup' does not need to do the initial scan, and
can start constructing the build graph immediately" ([`tup.1`][manual]).

### Design philosophy

**Nothing is discovered by reading the source tree at update time.** Rules are parsed once per
affected directory; dependencies are whatever the command touched during its previous run.
**The graph is the correctness argument**, and it is enforced rather than advised: a command that
reads another command's output without declaring it, or writes a file it did not declare, fails
the build. **There is no clean target**, because the graph also knows which generated files lost
their producer:

> "As a very useful side-effect of the well-defined database structure, tup can determine when a
> generated file is no longer needed. What this means is there is no clean target."
>
> — [`tup.1`][manual]

## How it works

### A DAG in one SQLite file

`tup init` creates `.tup/db` from a fixed schema ([`src/tup/db.c`][db-c], `DB_VERSION` 19):

| Table                        | Contents                                                             |
| ---------------------------- | -------------------------------------------------------------------- |
| `node`                       | files, dirs, commands, variables, ghosts, groups; `mtime`/`mtime_ns` |
| `normal_link`                | `(from_id, to_id)` edges: observed reads and command → output pairs  |
| `sticky_link`                | `(from_id, to_id)` edges declared in a `Tupfile`                     |
| `modify_list`, `create_list` | the change frontier: commands to revisit, directories to re-parse    |

Node kinds are a closed enum ([`src/tup/db_types.h`][db-types]); each edge is stored once and
read both ways — a command's forward edges are its outputs, a file's are its consumers — so one
traversal alternates command → output → consumer. A `db_version` mismatch migrates the schema
after a backup; a `parser_version` mismatch (16 here) re-parses every `Tupfile`
([`src/tup/db.c`][db-c]).

### Change intake: scan or monitor

By default `tup` walks the tree with `watch_path()`, comparing stored `mtime`/`mtime_ns` against
`fstatat()` ([`src/tup/path.c`][path-c]). A changed file calls `tup_db_modify_cmds_by_input()` to
flag its consumers; a missing file deletes its node and marks the parent for re-parsing.
`tup monitor` replaces the walk with inotify watches and writes events into the same frontier
([`src/tup/monitor/inotify.c`][monitor]); `--no-scan` asserts it is current. The monitor is
Linux-only, and neither route sees outside the hierarchy unless `updater.full_deps=1`
([`src/tup/option.c`][option-c]).

### The update: change list → sub-DAG → queue

`updater()` runs three phases ([`src/tup/updater.c`][updater-c]): `process_config_nodes` builds
the variant state; `process_create_nodes` re-parses only directories in `create_list`, on exactly
one thread "since no locking is done"; `process_update_nodes` graphs `modify_list` and runs it. A
parse failure rolls the whole transaction back. Graph construction walks forward from each flagged
command through its outputs to their consumers ([`src/tup/graph.c`][graph-c]); `make_edge` counts
incoming edges and reports cycles before any work starts. `execute_graph` runs Kahn's algorithm:
a ready list holds nodes with no outstanding incoming edges, a fixed worker pool takes one each,
and `pop_node` decrements successors and releases the newly ready. `-j`/`updater.num_jobs` bounds
the pool, `-k` keeps going after failure. There is no suspending or restarting: the dependency
list was fixed by the previous run, so a newly observed generated input is an error.

### Interception, strictness, variables

Linux defaults to the `fuse3` server (`linux.tup`; `TUP_SERVER` overrides it).
[`fuse_fs.c`][fuse-fs] turns each `open`/`create`/`unlink`/`rename`/`mkdir` under the `.tup/mnt`
view into an access event (`O_WRONLY`/`O_RDWR` → `ACCESS_WRITE`, else `ACCESS_READ`), and writes
go to a per-command temp name under `.tup/tmp/` until `update_write_info` validates the set and
renames it into place ([`src/tup/file.c`][file-c], [`src/tup/server/fuse_server.c`][fuse-server]).
Isolation is narrow: `master_fork.c` uses a user namespace with uid/gid maps plus a private mount
namespace, falling back to `chroot` for `full_deps` or an unnamespaced `^c`; otherwise tup warns
that "some dependencies may be missed" ([`src/tup/server/master_fork.c`][master-fork]).

Hosts without FUSE can use an `LD_PRELOAD` shim writing `TUP_DEPFILE`
([`src/ldpreload/ldpreload.c`][ldpreload], [`src/tup/server/depfile.c`][depfile]), an injected DLL
on Windows (`windepfile.c`), or `tup generate`, which emits a script and abandons interception;
the parser is watched the same way, so editing an included file re-parses the `Tupfile`
([`src/tup/parser.c`][parser-c]).

The most important distinction is that declared and observed inputs are _different edge kinds_:

> "Inputs listed in the Tupfile only enforce ordering among the commands, while file accesses
> during execution determine when commands are re-executed."
>
> — [`tup.1`][manual]

`Tupfile` inputs become `sticky_link` rows (plain order-only sources excepted); reads become
`normal_link` rows and are reconciled every run — a read that disappears removes its link, a new
read adds one — so the graph prunes itself with no `makedepend` pass and no stale header edge.
Enforcement is symmetric and fatal: an undeclared generated read fails because "without the input
link the commands may execute out of order" ([`src/tup/db.c`][db-c]); an undeclared write fails
with "was written to, but is not in .tup/db" ([`src/tup/file.c`][file-c]); a declared output the
command never writes fails with "Expected to write to file … but didn't" ([`src/tup/db.c`][db-c]).
The suite states the rationale: "Verify that if a command writes to a file that it wasn't already
linked to, it explodes. Things can't possibly work if the DAG is incomplete"
([`test/t2014-output-unspecified.sh`][test-output]).

Two `^` flags refine outputs: `^o` compares each new output against the pre-run copy and clears
dependents when nothing changed — "Any outputs that are the same will not cause dependent commands
in the DAG to be executed" ([`tup.1`][manual]) — the only early cutoff in the engine, per-rule and
opt-in; `^t` marks outputs transient, deleted after their last consumer
([`src/tup/parser.c`][parser-c]).

`@(VAR)` substitution happens at parse time, but `tup varsed` reads variables at run time. Both
routes are tracked: a binary `tup_vardict` is exported to the command, and each `tup_config_var()`
lookup sends `ACCESS_VAR` over the virtual `@tup@` path, recorded as a dependency on that variant's
variable ([`src/tup/vardict.c`][vardict], [`src/tup/access_event.h`][access-event]). `PATH` and
`HOME` are always dependencies; `export` adds more ([`src/tup/environ.c`][environ]).

## Analysis spine

**Placement.** [Concepts] §5 puts tup at **topological × dirty bit**; JFP §9.1 calls it
"functions much like Make, but with a refined dirty-bit implementation" that watches the file
system. The graph is complete before execution, and the persistent fact per key is a timestamp
plus a flag. The code adds the _read set_ — the bit propagates along observed edges — and `^o`,
an optional comparison that restores early cutoff without entering the verifying-trace row.

### 1. Task model & scheduling

- **A task is a command string plus an output set**, stored as a `TUP_NODE_CMD` whose name is
  the expanded command line. No typed action, no in-memory task graph between runs.
- **Dependencies are static at execution time** — the previous run's reads from SQLite.
  Discovery happens before execution (parse) or after it (next run), never during a run.
- **Parallelism is a fixed worker pool over a ready queue**, with no speculation.

### 2. Rebuilding & correctness

- **Dirtiness is mtime plus a flag.** A changed file flags consumers; a changed command string is
  flagged by the parser; a deleted output flags its producer. There is no input digest, so a
  content change that preserves `mtime`/`mtime_ns` is invisible — Make's weakness, kept on purpose.
- **The read set is the trace**: each `normal_link` is a dependency the command proved it used
  last time, so verifying a key checks those mtimes rather than re-running.
- **Minimality** holds (at most once per build), and the checked set is the change cone. Early
  cutoff exists only under `^o`. Correctness is claimed behaviourally — any number of updates
  should equal a from-scratch build ([`tup.1`][manual]) — and exercised by 993 numbered tests.

### 3. Dependency discovery

- **Hybrid by design**: declarations give ordering (`sticky_link`), observation gives invalidation
  (`normal_link`); the engine keeps them separate rather than merging them.
- **Interception is the mechanism**: FUSE on Linux/macOS, `LD_PRELOAD` on the alternative build,
  an injected DLL/depfile on Windows. Compiler depfiles are not the primary route.
- **Strict-deps is mandatory**, with `^` exclusions as the only escape hatch.

### 4. Store & caching

- **The working tree is the store.** `node` and the link tables are metadata; contents never enter
  `.tup`. No CAS, no action cache, no content key.
- **Durability is a knob**: `db.sync` defaults to `1`; `tup init --no-sync` writes `.tup/options`
  with `sync = false`, issuing `PRAGMA synchronous=OFF` ([`src/tup/init.c`][init-c]).

### 5. Hermeticity & provenance

- **A sandbox for observation, not isolation.** FUSE plus a namespace hides temp writes and
  catches accesses, but the command keeps the network, the clock and every readable path unless
  `full_deps` adds a chroot.
- **Writes are staged and validated**: no half-written output can satisfy a build, and every
  declared output must exist at the end.
- **Environment is partially modelled** (`PATH`, `HOME`, `export`). **No provenance** — no
  attestation, signature or per-action record beyond the node flags.

### 6. Distribution

Absent: no network client, no REAPI, no remote cache. The only distributed process is the local
`monitor`; `tup generate` emits a shell script for CI hosts without FUSE.

### Sparkles relevance

`libs/build-primitives/src/sparkles/build_primitives/task/` keeps nothing between runs —
`graph.d` has no serialization or cache key — so tup is the smallest credible model for a first
persistence layer, not a design to copy whole.

- **Copy the two edge kinds.** Declared edges order work; observed edges decide staleness; a
  `TaskEdge` with one notion of dependency must over- or under-invalidate.
- **Copy the change frontier, not the schema**: a persistent changed-input → flagged-command map
  plus a read set gets the same effect without SQLite.
- **Copy the output gate**: unlink or stage declared outputs before running, require all of them
  afterwards, fail on extras.
- **Do not copy mtime or FUSE**: content hashes and a declarable dependency API avoid the
  false-negative class and the platform dependency.

## Strengths

- **Update cost tracks the change, not the repository** — the beta algorithm is the reason the
  project exists, and the monitor removes the last `O(n)` scan.
- **Self-maintaining and enforced**: reads prune themselves, and undeclared access fails loudly.
- **No clean target**: generated files that lost their producer are removed, so repeated updates
  converge on a from-scratch result, and 993 numbered tests back the claim.

## Weaknesses

- **The first build has no observations**, so order-only declarations must already be correct; a
  fresh checkout can fail where an incremental build succeeds.
- **mtime is the only content signal** (plus opt-in `^o`): `touch` over-builds, a restored
  timestamp under-builds.
- **Interception is platform-specific and privileged** — FUSE or `LD_PRELOAD`, an injected DLL,
  user namespaces or `suid` — all awkward in containers and CI.
- **No cache, remote execution or provenance**, so nothing is shareable across machines and there
  is no isolation boundary against a hostile command.
- **One SQLite database per hierarchy** bounds concurrency (single writer); the clone has no
  history or tags to judge maintenance cadence.

## Key design decisions and trade-offs

| Decision                                  | Rationale                                                    | Trade-off                                                                |
| ----------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------ |
| Consume a change list, walk only its cone | `O(changes)` updates instead of `O(project)`; the beta model | Needs a persistent graph and, ideally, a monitor; a bare run still scans |
| Learn dependencies from real accesses     | No missing `#include` edges; the read set prunes itself      | Requires interception; the first build must already be declared in order |
| Make undeclared access fatal              | The DAG must match reality; prevents silent stale builds     | Tools with surprise outputs need exclusions or fail                      |
| Stage writes, validate, then rename       | Partial or extra outputs cannot satisfy a build              | An extra rename per output; temp space during the command                |
| `^o` byte-compare for early cutoff        | Cheap pruning when codegen usually writes identical bytes    | Per-rule opt-in; incompatible with `^t`; costs a full comparison         |
| `^t` transient outputs                    | Large intermediates need not persist after their consumers   | Changing an early input rebuilds every consumer of the deleted files     |
| No cache, sandbox boundary, or network    | Tiny, portable, single-host tool; policy left to the command | No cross-machine reuse, no isolation, no attestation                     |

## Sources

- [`gittup/tup`][repo] at `c6f565e216a0820e39d65fa84ddaf830be03a476` (2026-07-29), clone at
  `$REPOS/build-systems-research/src/tup`; a single-commit checkout, so no history or tags.
- Read in the clone: [`README.md`][readme], [`tup.1`][manual], [`src/tup/link.sh`][link-sh];
  [`src/tup/db.c`][db-c], [`src/tup/db_types.h`][db-types], [`src/tup/updater.c`][updater-c],
  [`src/tup/graph.c`][graph-c], [`src/tup/parser.c`][parser-c], [`src/tup/file.c`][file-c],
  [`src/tup/path.c`][path-c], [`src/tup/option.c`][option-c], [`src/tup/init.c`][init-c],
  [`src/tup/vardict.c`][vardict], [`src/tup/environ.c`][environ],
  [`src/tup/access_event.h`][access-event], [`src/tup/monitor/inotify.c`][monitor],
  [`src/tup/server/fuse_server.c`][fuse-server], [`src/tup/server/fuse_fs.c`][fuse-fs],
  [`src/tup/server/master_fork.c`][master-fork], [`src/tup/server/depfile.c`][depfile],
  [`src/ldpreload/ldpreload.c`][ldpreload], [`test/t2014-output-unspecified.sh`][test-output].
- Siblings: [Ninja][ninja], [Make][gnumake], [redo][redo], [Shake][shake], [Bazel][bazel]; workspace [tup][mono-tup].

<!-- References -->

[repo]: https://github.com/gittup/tup
[readme]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/README.md
[manual]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/tup.1
[link-sh]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/link.sh
[db-c]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/db.c
[db-types]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/db_types.h
[updater-c]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/updater.c
[graph-c]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/graph.c
[parser-c]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/parser.c
[file-c]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/file.c
[path-c]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/path.c
[option-c]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/option.c
[init-c]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/init.c
[vardict]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/vardict.c
[environ]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/environ.c
[access-event]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/access_event.h
[monitor]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/monitor/inotify.c
[fuse-server]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/server/fuse_server.c
[fuse-fs]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/server/fuse_fs.c
[master-fork]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/server/master_fork.c
[depfile]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/tup/server/depfile.c
[ldpreload]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/src/ldpreload/ldpreload.c
[test-output]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/test/t2014-output-unspecified.sh
[concepts]: ./concepts.md
[ninja]: ./ninja.md
[gnumake]: ./gnumake.md
[redo]: ./redo.md
[shake]: ./shake.md
[bazel]: ./bazel.md
[mono-tup]: ../monorepo-tooling/tup/
