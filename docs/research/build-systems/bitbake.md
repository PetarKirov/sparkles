# BitBake (Python / OpenEmbedded)

BitBake is not one mechanism but a cooperating set of them: a metadata
interpreter and long-lived cooker server, a runqueue over a materialised task
DAG, a pluggable signature generator, a metadata-supplied shared-state cache
protocol, and a separate hash-equivalence service. Treating only the hash in a
stamp filename as "the build system" misses where its correctness and reuse
decisions are actually made.

**Last reviewed:** November 3, 2026

| Field             | Value                                                                                        |
| ----------------- | -------------------------------------------------------------------------------------------- |
| Language          | Python 3.9+ — `lib/bb/__init__.py` refuses older interpreters; `__version__ = "2.20.0"`      |
| License           | GPL-2.0-only (`LICENSE`), with MIT-tagged individual files (`LICENSE.MIT`)                   |
| Repository        | [openembedded/bitbake][repo]                                                                 |
| Documentation     | In-tree Sphinx manual: `doc/bitbake-user-manual/` (execution, metadata, variables)           |
| Category          | Industry — distro-scale embedded Linux; metadata-driven engine plus metadata-owned cache     |
| Clone (pinned)    | `74128534302fbf8164ade07b200b90b731caa0ad`, HEAD commit dated 2026-10-25                     |
| Metadata language | recipes `.bb`, classes `.bbclass`, appends `.bbappend`, config `.conf`, layers `layer.conf`  |
| Scheduler         | `speed` by default; `basic` and `completion` selectable through `BB_SCHEDULER`               |
| Signature handler | `BB_SIGNATURE_HANDLER`: shipped `noop`, `basic`, and `basichash`; OpenEmbedded extends these |
| Rebuild identity  | `basehash` → `taskhash` → `unihash`, materialised as `<stamp>.<task>.<hash>[.<extrainfo>]`   |

## Overview

### What it solves

A distribution image is thousands of recipes times roughly ten tasks each —
`do_fetch`, `do_compile`, `do_install`, `do_package`, on to `do_image` —
cross-compiled for several machines, often under several multiconfigs. A clean
build is hours; the engineering is in never doing one. BitBake is deliberately
the _engine half_ of that system:

> "BitBake is a generic task execution engine that allows shell and Python tasks to be run
> efficiently and in parallel while working within complex inter-task dependency constraints.
> One of BitBake's main users, OpenEmbedded, takes this core and builds embedded Linux software
> stacks using a task-oriented approach."
>
> — [`README`][readme]

That division matters throughout this page. BitBake ships the runqueue,
signature machinery, caches, worker and server processes, and hash-equivalence
server. OpenEmbedded-Core supplies the deployed signature policy
(`OEBasicHash`), sstate archive format and mirroring, sysroot layout, fetch
task conventions, and most reproducibility policy. Some properties users call
"BitBake" therefore cannot be proved from this repository alone, and this page
marks that boundary rather than attributing OE behaviour to the engine.

### The process architecture

A normal invocation is already a client/server system even before any task
runs:

```text
bitbake UI process
  | Unix socket / multiprocessing queues (or optional XML-RPC)
  v
bitbake server (ProcessServer + Cooker + parsed metadata and caches)
  | pickled runtask messages over pipes
  +--> bitbake-worker (normal tasks, one per multiconfig)
  +--> bitbake-worker under fakeroot (tasks flagged [fakeroot])
  |
  +--> hash-equivalence client --> local or remote hashserv
```

`lib/bb/main.py` either reconnects to an existing server for the build
directory, starts `BitBakeServer`, or connects to a remote XML-RPC server. The
local server is daemonised by `lib/bb/server/process.py`, holds the `Cooker`,
receives commands and emits events to the UI, and times out when idle. This is
a control-plane daemon: it avoids re-parsing and retains metadata caches, but
it is not remote execution. Moving the UI to another machine through XML-RPC
moves the entire cooker and its local workers with it; it does not turn tasks
into REAPI actions.

Workers are separate `bin/bitbake-worker` processes started per multiconfig,
plus a fakeroot worker when needed. They receive pickled configuration and
task data over pipes, execute shell/Python functions, and report events and
logs back to the runqueue. The runqueue can stop launching work under CPU, I/O,
or memory pressure, but always keeps at least one task active.

## How it works

### Metadata becomes a complete task graph

`bblayers.conf` names layers; each `conf/layer.conf` extends `BBPATH` and
`BBFILES`; every matching `.bb` is parsed, `.bbappend` files amend it, and
`.bbclass` files inject shared behaviour. A task is a shell or Python function
promoted by `addtask printdate after do_fetch before do_build`.
Dependencies from `DEPENDS`, `RDEPENDS`, `do_X[depends] = "pn:do_y"`,
`[deptask]`, `[rdeptask]`, `[recrdeptask]`, `[recideptask]`, and
`[mcdepends]` resolve into one task-dependency set. `PROVIDES`,
`PREFERRED_PROVIDER_virtual/kernel`, and `PREFERRED_VERSION` then decide
which recipe satisfies a target.

`RunQueueData` expands providers, variants, multiconfigs, task flags, and
`addtask` chains into task IDs containing multiconfig, recipe file, and task
name. It calculates reverse dependencies and detects circular or unbuildable
chains before execution. There is no primitive by which a running task asks
for a newly discovered build task and suspends until it completes.

Four flags illustrate how much behaviour metadata puts beside a function:
`[noexec]` (placeholder), `[nostamp]` (never current), `[lockfiles]` (mutual
exclusion), and `[file-checksums]`, which adds files to the signature with a
boolean saying whether the path existed — "It is important to record any paths
which the task looked at and which didn't exist"
([`bitbake-user-manual-metadata.rst`][manual-metadata]).

### The signature generator is pluggable, and `noop` is the fallback

Discussions of BitBake often assume the OpenEmbedded hash behaviour is the
engine's only mode. `lib/bb/siggen.py` instead exposes a class hierarchy
selected by `BB_SIGNATURE_HANDLER`:

| Handler       | What it does in this repository                                                                                        |
| ------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `noop`        | Generates a stable task ID hash (`sha256(tid)`), records no dependency signature; fallback when no handler is selected |
| `basic`       | Computes metadata `basehash` values and dependency-sensitive `taskhash` values, sigdata, taints, and file checksums    |
| `basichash`   | `basic` plus the current task hash embedded in the stamp filename and taint-based forced invalidation                  |
| OE extensions | OpenEmbedded subclasses/mixins add its deployed sstate and hash-equivalence policy; not defined in this clone          |

This distinction is load-bearing. The stamp-and-hash account below describes
`basichash` and OE-style deployments, not an arbitrary BitBake invocation. The
`UniHashMixIn` is what lets an equivalence-derived `unihash` replace the
`taskhash` in a stamp name; plain `SignatureGeneratorBasicHash` uses
`taskhash`.

### From metadata closure to `basehash`

For `basic` and `basichash`, `bb.data.generate_dependencies` starts from each
task function and walks referenced variables and functions. Python code is
analysed through its AST-derived references and shell code through BitBake's
shell parser; variable flags such as `vardeps`, `vardepvalue`,
`vardepsexclude`, `exports`, `prefuncs`, and `postfuncs` alter that closure.
`generate_dependency_hash` hashes the collected values, excluding
`BB_BASEHASH_IGNORE_VARS`, to form each task's `basehash`.

This is real static analysis of metadata and task text, and it is cached.
`CodeParserCache` stores shell/Python reference analysis in
`bb_codeparser.dat`; `FileChecksumCache` can persist file checksum work; the
recipe parse cache stores extracted metadata under a cache-file identity that
includes a hash of relevant configuration. On reparse, `_build_data`
recomputes basehashes and errors if one changed without an input change: "The
metadata is not deterministic and this needs to be fixed."

The parser only sees variables and functions. It does not observe files opened
by compilers, shell commands, or Python code. `[file-checksums]`, `SRC_URI`
checksums, `[vardeps]`, and `[vardepsexclude]` are explicit repairs around
that boundary.

### `taskhash`, `unihash`, stamps, and sigdata

`SignatureGeneratorBasic.get_taskhash` sorts the retained runtime
dependencies, appends each dependency's `unihash` to the task's `basehash`,
then appends sorted file checksums and any taint, and SHA-256 hashes the
result. `prep_taskhash` requires dependencies to have been processed first;
the hash propagation is therefore an ordinary bottom-up fold over the static
DAG, not a worklist discovered during execution.

With `basichash`, `stampfile` returns
`<stampbase>.<task>.<hash>[.<extrainfo>]`. A `_setscene` stamp uses the covered
task's ID, so successful restoration and successful execution converge on the
same currency test. `check_stamp_task` treats a missing stamp as not current,
`nostamp` as never current, and a `_setscene` stamp as current under its own
rules. `find_stale_stamps` and clean masks use wildcard hash components to
remove stamps for other hash values when BitBake is asked to clean or a task
is rerun; the stamp directory is an operational artifact with explicit
cleanup operations, not simply an ever-growing database, although interrupted
and historical work can still leave files behind.

A forced task writes a `.taint` file containing a random UUID. The taint
enters that task's hash and therefore every dependent's hash, so `bitbake -f`
invalidates a cone rather than deleting one output and hoping downstream
tasks notice.

Alongside execution, BitBake can dump `<stamp>.<task>.sigdata.<unihash>`: a
zstd-compressed JSON record containing variable values, dependency hashes,
file checksums, and taint. `calc_taskhash` can recompute a task hash from that
record, and `compare_sigfiles` can name the variable or dependency that
diverged. This explanatory trace is separate from the stamp-existence test
that decides currency on an ordinary run.

### The runqueue has a cache phase and a real phase

`RunQueueData` builds `runtaskentries` (task ID, dependencies, reverse
dependencies, weight, hash, and unihash). The weight pass seeds build
endpoints at 10 and propagates weight toward prerequisites: tasks with many
transitive dependents should start early. Three schedulers consume the same
ready set:

- `basic`: deterministic task-number order;
- `speed`: descending structural weight (the default);
- `completion`: speed ordering biased towards finishing recipes already
  started, useful when `rm_work` frees build directories.

Before ordinary execution, the runqueue constructs a scene queue of
`*_setscene` tasks. Ordinary tasks lying between setscene tasks are squashed
into coverage relationships, so one restored artifact can cover a chain. A
setscene success moves covered tasks out of the real queue; failure leaves
them to execute. Duplicate tasks with the same hash are deferred onto one
another to avoid restoring or building the same identity concurrently. Only
after scenequeue processing does the real ready-set execution begin.

The scheduler also back-pressures on Linux pressure-stall information from
`/proc/pressure/{cpu,io,memory}`, or on load average. It samples at most once
per second and never lets back-pressure reduce the active count to zero.
This is structural and environmental scheduling, not history-based critical
path prediction: recorded task durations do not drive the built-in priority.

### `setscene` is a cache protocol, not a store

The engine splits cache lookup from restoration:

| Hook                    | Question it answers                                                              |
| ----------------------- | -------------------------------------------------------------------------------- |
| `BB_HASHCHECK_FUNCTION` | Given `{tid: hash}`, which hashes could metadata supply? It may over-approximate |
| `<task>_setscene`       | Restore this task's outputs, or fail                                             |
| `BB_SETSCENE_DEPVALID`  | Given a successful setscene task, which dependencies must still run?             |
| `BB_SETSCENE_ENFORCE`   | Turn an unexpected real execution into a build failure                           |

The first stage is deliberately approximate: "The returned list need not be
completely accurate. A given setscene task can still later fail."
([`bitbake-user-manual-ref-variables.rst`][manual-ref]). The engine therefore
does not know whether the supplier is a local sstate directory, an HTTP
mirror, a tarball, or something else. It knows hashes, coverage, stamps, and
failure.

`BB_SETSCENE_ENFORCE` deserves separate attention. It converts cache coverage
from an optimisation into a CI assertion: if a task that was supposed to be
supplied from cache reaches real execution, the build errors. That proves a
pre-populated cache is complete for a target closure rather than inferring
completeness from a fast build time.

### Hash equivalence supplies early cutoff — with a governed database

`taskhash` is an input identity. If an irrelevant metadata change alters it,
the change ripples to every dependent even when the rebuilt output is
byte-identical. Hash equivalence introduces a coarser identity:

1. A metadata-provided method hashes a completed task's output (`outhash`).
2. The client reports `(method, taskhash, outhash)` to `hashserv`.
3. If another taskhash produced the same outhash, the server returns its
   existing `unihash`; otherwise the current taskhash becomes the unihash.
4. Dependents fold the unihash, not the original taskhash, into their hashes.

The server in `lib/hashserv` is an async RPC service backed by SQLite or
SQLAlchemy. Its schema separates `(method, taskhash) -> unihash` from
`(method, outhash, taskhash)` output observations. It supports authenticated
users and permissions, upstream chaining and backfill, batch/streaming
queries, conditional row removal, deletion of orphaned old output rows, and a
two-phase garbage-collection protocol: clients `gc-mark` rows to retain,
inspect `gc-status`, then `gc-sweep` deletes unmarked unihash rows. That GC
governs equivalence metadata, not build outputs in an sstate store. Conflating
the two would overstate what the engine owns.

Without a server or cached equivalence, `unihash` falls back to `taskhash`.
With one, equivalence is only as sound as the metadata's output-hash method:
hash too little of the output and distinct artifacts collapse; hash volatile
bytes and cutoff disappears.

### Several caches, with different correctness burdens

| Cache                              | Key / identity                                                          | Invalidated or cleaned by                                       |
| ---------------------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------------- |
| Recipe parse cache                 | Cache format version plus relevant configuration and file mtimes/checks | Parse invalidation recorded by the cooker                       |
| CodeParserCache                    | Hashes of shell/Python code fragments                                   | Cache format/codeparser revisions; merged cache files           |
| FileChecksumCache                  | Paths and file metadata                                                 | Persistent cache merge/update                                   |
| Unihash cache (`bb_unihashes.dat`) | Recipe/task key plus expected taskhash                                  | Replaced when taskhash no longer matches                        |
| Stamps + sigdata                   | Task identity and signature hash                                        | Clean masks, taints, stale-stamp operations                     |
| Hashserv DB                        | Method + taskhash / outhash                                             | Conditional `remove`, orphan cleanup, mark/sweep GC             |
| Sstate artifacts                   | Metadata-defined (OE)                                                   | Metadata-defined retention and mirror policy, outside this repo |

There is no engine-owned content-addressed artifact store. Content hashes are
identities and lookup keys; artifact bytes remain in work directories and in
whatever sstate representation the metadata supplies. That is why a stamp can
survive while an output is damaged or removed: BitBake's ordinary currency
test does not content-address and re-materialise every output from a CAS.

### Environment, network, pseudo, and the limits of isolation

Host environment does not flow into tasks wholesale. BitBake preserves the
original environment as `BB_ORIGENV`, imports only variables permitted by
`BB_ENV_PASSTHROUGH` and `BB_ENV_PASSTHROUGH_ADDITIONS` into the datastore,
and a variable reaches a shell task's environment when it is exported. Shell
tasks are materialised as `run.do_<task>.<pid>` scripts containing exported
variables and expanded functions, which makes the executed environment
inspectable after the fact.

Unless a task has `[network] = "1"`, `bin/bitbake-worker` calls
`bb.utils.disable_network()` and then `landlock_restrict_network()`.
`disable_network` invokes libc `unshare(CLONE_NEWNET | CLONE_NEWUSER)` and
writes uid/gid maps for an unprivileged user namespace; failure is logged at
debug level, not treated as fatal. The Landlock helper creates an ABI-v4
ruleset handling TCP bind/connect with no allowed ports and calls
`landlock_restrict_self`; unsupported kernels are skipped. This is meaningful
ambient-input reduction, but it is not filesystem confinement: the same task
can read `/usr/include`, home directories, devices permitted by ordinary Unix
permissions, and other recipes' work directories.

Tasks flagged `[fakeroot]` run in a separate worker under the metadata's
`FAKEROOTCMD`, conventionally OE's `pseudo`. Pseudo is itself an
`LD_PRELOAD` filesystem interposer with a metadata database, but it is not in
this repository and its purpose is fabricated ownership/permissions, not
dependency discovery or sandboxing. BitBake coordinates its logs and disables
it for fetch operations where it can interfere.

Provenance in the SLSA or in-toto sense is absent from the engine. Sigdata is
an input manifest and debugging trace; hashserv can optionally receive task
metadata, but neither is a signed statement binding builder identity,
materials, and output digest.

## Analysis spine

### Placement in the scheduler × rebuilder grid

With `basic`/`basichash`, BitBake is closest to **topological × verifying
traces**, but the stamp mechanism makes that label approximate. The graph and
hash fold are static. Sigdata records the variable values and dependency
hashes behind an identity, which is trace-like. Yet ordinary currency is not
"load the old trace and compare each observed input"; it is "compute the
current transitive identity and ask whether a stamp with that name exists."
That is closer to a content-keyed dirty bit. Hash equivalence then adds an
output-identity rewrite before dependents compute their keys, and setscene
adds a memo/restoration phase before real execution. BitBake is therefore a
useful warning against forcing production engines into one pure cell.

It is not suspending or dynamic: task dependencies must be known when the
runqueue is built. A compiler depfile can influence metadata-level file
checksums only where metadata wires it in; it cannot extend the task graph
mid-run.

### 1. Task model & scheduling

Tasks are named shell/Python functions on recipes, expanded across variants
and multiconfigs. Edges come from recipe dependencies, task flags, class
injections, and `addtask` ordering. The scheduler sees a complete DAG and
prioritises ready tasks structurally. Its distinguishing operational features
are the setscene pre-phase, duplicate-hash deferral, lockfiles, pressure/load
back-pressure, and separate normal/fakeroot workers.

### 2. Rebuilding & correctness

The correctness chain is conditional at three separate points:

1. **Metadata closure completeness.** Every variable/function that can affect
   the task must be found by the code parser or declared with flags.
2. **File-input completeness.** Every file read outside declared sources and
   sysroots must be represented by SRC_URI/file checksums or recipe
   dependencies.
3. **Task determinism.** Equal recorded inputs must produce interchangeable
   outputs. Network isolation removes one ambient source; host files, clocks,
   randomness, process scheduling, and filesystem iteration remain task
   responsibilities.

Failure modes follow directly. An undeclared `/usr/include` read can poison a
stamp and an sstate artifact. Deleting an output without deleting its stamp
can leave the engine believing work is current. A non-deterministic task can
make hash equivalence harmful if its output-hash method overlooks the byte
that varies. Conversely, exact input hashing without equivalence is safe but
pessimistic: harmless metadata edits rebuild a cone.

### 3. Dependency discovery

BitBake combines declared task edges with static inference inside task and
metadata text. It does not discover dependencies by observing execution,
except in the narrower sense that fetch machinery knows declared source URIs
and checksum machinery hashes named files. The absence of a task is itself
recorded in two places worth copying: `[file-checksums]` records non-existent
paths, and sigdata preserves the values used to derive identity so a human
can diff them later.

### 4. Store & caching

The engine owns identities, stamps, parse/code/checksum caches, and the
equivalence database. It does not own a CAS or sstate artifact format. This
separation is flexible but makes end-to-end cache correctness a property of
the combined BitBake + metadata system, not of BitBake in isolation.
Hashserv's authenticated upstreaming and mark/sweep GC are unusually mature
for equivalence metadata; artifact retention remains somebody else's policy.

### 5. Hermeticity & provenance

Environment filtering and default network isolation reduce ambient inputs,
and run scripts make the exported environment auditable. But there is no
filesystem view constructed from declared inputs, no syscall policy for file
access, and no build attestation. `pseudo` changes apparent ownership, not
authority. BitBake is declaration-trusting with a network boundary, not
hermetic in the Bazel/Nix sense.

### 6. Distribution

The cooker server can be remote and long-lived, and hashserv/sstate mirrors
can be shared across a farm. Those are distributed control and cache sharing,
not distributed execution. Workers are subprocesses of the server's host;
there is no REAPI client, worker lease protocol, action digest, or remote
CAS in the engine. A build farm scales by making cache hits cover as much of
the DAG as possible, then executing the remainder locally.

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a validated static DAG with a single-pass
executor and no persisted rebuild state. BitBake suggests four concrete
borrowings, in increasing cost order:

- **Record absent probes.** A dependency on a path that did not exist is as
  real as a dependency on bytes.
- **Dump a diffable trace.** A structured record of the values and dependency
  identities behind a task turns "why did this rerun?" into a comparison.
- **Add a cache-coverage gate.** `BB_SETSCENE_ENFORCE` is a CI mode where an
  unexpected real execution fails, proving cache completeness.
- **Separate input identity from output identity.** A local
  `taskhash -> output digest` equivalence table is the cheapest early cutoff:
  dependents key on output identity, so irrelevant input changes stop at the
  task that absorbed them.

## Strengths

- **Layered identity.** Parse, task-input, output-equivalence, and artifact
  identities are separate concepts with separate mechanisms.
- **Replaceable cache protocol.** The engine can use any metadata supplier
  that answers hash coverage and restoration.
- **Explanatory traces.** Sigdata and `compare_sigfiles` make cache misses
  debuggable rather than mystical.
- **Operational maturity.** Pressure back-pressure, lockfiles, multiconfig,
  duplicate deferral, setscene enforcement, and mark/sweep equivalence GC
  reflect distro-scale use.

## Weaknesses

- **Correctness rests on unchecked declarations.** Undeclared file reads and
  non-deterministic tasks produce confidently wrong stamps and cache entries.
- **The deployed system is split across repositories.** Signature policy,
  sstate format/retention, sysroots, and reproducibility policy cannot be
  audited from BitBake alone.
- **Currency trusts stamps and work directories.** Without a CAS, damaged or
  missing outputs are not automatically detected and re-materialised.
- **Pluggability complicates claims.** Statements true for OE's `basichash`
  deployment are not true for `noop` or a differently configured handler.

## Key design decisions and trade-offs

| Decision                                   | Rationale                                                       | Trade-off                                                                      |
| ------------------------------------------ | --------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Static graph before execution              | Whole-distro planning, cycle/provider errors before work        | No dynamic dependencies or suspending discovery                                |
| Hash in the stamp filename                 | Currency is a filesystem lookup; no central trace DB to migrate | Trusts stamp/output coexistence; many small operational files                  |
| Dependency hashes folded into `taskhash`   | Changes propagate by construction                               | No early cutoff without output equivalence                                     |
| Static metadata closure as signature input | Catches most task inputs without tracing execution              | Blind to file reads and dynamic metadata the parser cannot model               |
| Setscene as a metadata protocol            | Any artifact supplier/mirror can participate                    | Store format, trust, and retention live outside the engine                     |
| Hash equivalence as a service              | Output identity can be shared and governed across builders      | Extra service/database, output-hash soundness burden, upstream trust decisions |
| Network off by default, filesystem open    | Removes a common ambient input without constructing a sandbox   | Host file reads remain silent; isolation is best-effort on unsupported kernels |
| Long-lived cooker server                   | Avoids reparsing and retains metadata/code caches               | Daemon invalidation and lifecycle become part of correctness/operations        |

## Sources

- [`openembedded/bitbake`][repo] at commit
  `74128534302fbf8164ade07b200b90b731caa0ad` (clone at
  `$REPOS/build-systems-research/src/bitbake`; version `2.20.0`).
- Process and execution: [`lib/bb/main.py`][main],
  [`lib/bb/server/process.py`][server-process], [`lib/bb/runqueue.py`][runqueue],
  [`lib/bb/build.py`][build], [`bin/bitbake-worker`][bitbake-worker].
- Signatures and caches: [`lib/bb/siggen.py`][siggen],
  [`lib/bb/data.py`][data], [`lib/bb/codeparser.py`][codeparser],
  [`lib/bb/cache.py`][cache], [`lib/bb/utils.py`][bb-utils].
- Hash equivalence: [`lib/hashserv/server.py`][hashserv-server],
  [`lib/hashserv/sqlite.py`][hashserv-sqlite],
  [`lib/hashserv/__init__.py`][hashserv-init].
- Manual: [execution][manual-execution], [metadata][manual-metadata],
  [variables][manual-ref].
- Sibling pages: [concepts] and [a-la-carte] for vocabulary, [buildxl] for
  observed-input validation, [rattle] for traced script dependencies, and
  [nix-thesis] for a store that owns outputs rather than stamps.

<!-- References -->

[repo]: https://github.com/openembedded/bitbake
[readme]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/README
[manual-execution]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/doc/bitbake-user-manual/bitbake-user-manual-execution.rst
[manual-metadata]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/doc/bitbake-user-manual/bitbake-user-manual-metadata.rst
[manual-ref]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/doc/bitbake-user-manual/bitbake-user-manual-ref-variables.rst
[main]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/main.py
[server-process]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/server/process.py
[runqueue]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/runqueue.py
[siggen]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/siggen.py
[build]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/build.py
[bb-utils]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/utils.py
[bitbake-worker]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/bin/bitbake-worker
[data]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/data.py
[codeparser]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/codeparser.py
[cache]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/bb/cache.py
[hashserv-server]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/hashserv/server.py
[hashserv-sqlite]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/hashserv/sqlite.py
[hashserv-init]: https://github.com/openembedded/bitbake/blob/74128534302fbf8164ade07b200b90b731caa0ad/lib/hashserv/__init__.py
[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[buildxl]: ./buildxl.md
[rattle]: ./rattle.md
[nix-thesis]: ./nix-thesis.md
