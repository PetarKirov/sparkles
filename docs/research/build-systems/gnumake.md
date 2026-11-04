# GNU Make (C, build engine)

GNU Make's engine in one sentence: it parses every makefile into one in-memory graph,
walks it depth-first deciding staleness from cached `stat` timestamps, starts each
recipe as a shell string — and treats its own makefiles as targets, so regenerating one
re-executes the engine.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                            |
| --------------------- | -------------------------------------------------------------------------------- |
| Language              | C99 (`src/`; `README.git` requires ISO C99 via Gnulib)                           |
| License               | GPL-3.0-or-later (`COPYING`)                                                     |
| Repository            | [`git://git.savannah.gnu.org/make.git`][repo] (Savannah; browsable cgit)         |
| Documentation         | [`doc/make.texi`][manual] — Edition 0.77, source of the manual and `make.1`      |
| Category              | Executor / build engine; companion to [Make (monorepo-tooling)][mono-make]       |
| Clone (pinned)        | `$REPOS/build-systems-research/src/gnumake`                                      |
| Commit                | `b3802782de3eff2c0f1eda9e7c0befd8cd142162` (2026-04-29); grafted, **no tags**    |
| Version in tree       | `AC_INIT` `4.4.90` ([`configure.ac`][configure]); newest `NEWS` section `4.4.90` |
| Scheduler × rebuilder | Topological × dirty bit ([concepts] §5), with two qualifications below           |
| Persistent state      | **None of its own** — the working tree's mtimes are the database                 |

> [!NOTE]
> **Delta against the workspace page.** [Make (monorepo-tooling)][mono-make] covers the
> DSL, automatic variables, recursive-make workspaces, and the jobserver as a user knob.
> This page stays inside the process: `struct file`, `f_mtime`, implicit-rule search,
> the re-exec loop, and the token arithmetic.

## Overview

### What it solves

The manual states the contract — and the whole rebuilder — in one sentence:

> "A target is out of date if it does not exist or if it is older than any of the
> prerequisites (by comparison of last-modification times)."
>
> — [`doc/make.texi`][manual] § Rules (Texinfo markup removed)

### Design philosophy

That is the entire rebuilder. **The file is the key and its timestamp is the state**:
no database, no action cache, no log — `make` re-`stat`s the world each invocation.
**The task is a string**: a rule says when a target is out of date and how to update
it, and the "how" goes to `/bin/sh` unexamined. **The makefile is a target too.**

## How it works

### The task is a rule; the graph is parsed once per process

`read.c` expands variables and conditionals while reading, so every prerequisite name
is known before the first recipe; `snap_deps` folds `.PHONY`, `.PRECIOUS`,
`.SECONDARY`, `.NOTINTERMEDIATE`, `.LOW_RESOLUTION_TIME` and `.WAIT` into flags on
`struct file` ([`src/file.c`][file]). The graph is an array of `struct file` records —
`deps`, `cmds`, `also_make`, `last_mtime`, `command_state`, `update_status` — with no
serialized form ([`src/filedef.h`][filedef]); `.SECONDEXPANSION` defers prerequisite
expansion to consideration time; `VPATH`/`GPATH` resolve a name at `stat` time.

### The dirty test: `f_mtime`, cached and lied about

`file_mtime` is a macro over a one-field cache: `last_mtime == UNKNOWN_MTIME` means
"not yet stat'ed"; the first query fills it from `stat`, `VPATH`, an archive member,
or a `-l` library search ([`src/filedef.h`][filedef], [`src/remake.c`][remake]).
`update_file_1` then runs a short ladder:

| #   | Test                                          | Effect                                   |
| --- | --------------------------------------------- | ---------------------------------------- |
| 1   | `NONEXISTENT_MTIME` (missing, or `.PHONY`)    | `must_make`, unconditionally             |
| 2   | a grouped-target peer missing or older        | adopt its older mtime, `must_make`       |
| 3   | no `cmds` and not yet tried                   | search implicit rules for a recipe       |
| 4   | any dep `NONEXISTENT_MTIME` or `> this_mtime` | `must_make` (`this_mtime` is pre-update) |
| 5   | `-B`, or `-W` stamped `NEW_MTIME`             | `must_make`                              |

`check_dep` compares each prerequisite against the **parent's pre-update**
`this_mtime`, which is why a rebuilt dependency forces its consumer in the same run
([`src/remake.c`][remake]); nothing asks whether an output actually changed, so there
is no early cutoff.

The sentinels are the rebuilder's interface for pretending: `-o file` sets
`last_mtime = OLD_MTIME` and marks the file finished, `-W file` sets `NEW_MTIME`, and
`.PHONY` sets `NONEXISTENT_MTIME` — "Mark this file as phony nonexistent target" in
`file.c` ([`src/main.c`][main], [`src/file.c`][file]). `.LOW_RESOLUTION_TIME` rounds
coarse stamps to the next second, and a future stamp ends the build with
`clock skew detected` ([`src/remake.c`][remake]).

### Pattern rules: the task template is searched, not declared

A rule without a recipe is a template query. `try_implicit_rule` collects every
pattern rule whose target matches, sorts matches by **shortest stem** ("the pattern
that matches most specifically"), drops non-terminal match-anything rules once a
specific rule matched, then makes two passes — "Try each rule once without intermediate
files, then once with them" ([`src/implicit.c`][implicit]). Pass two recurses into each
missing prerequisite, which is how a chain like `%.o` from `%.c` from `%.y` is found,
and why `make` can invent an intermediate, build it, use it, and `rm` it.

### Remaking makefiles re-execs the engine

> "After all makefiles have been checked, if any have actually been changed, make
> starts with a clean slate and reads all the makefiles over again."
>
> — [`doc/make.texi`][manual] § How Makefiles Are Remade

"Clean slate" is literal: on POSIX the parent `exec_command`s a fresh `make` image with
the same argv and environment, incrementing `MAKE_RESTARTS` ([`src/main.c`][main]).
Every makefile is a goal too (`read_files`), so `Makefile: Makefile.in` works — and so
does a rule generating an included `.d` file:

```make
sources = foo.c bar.c
include $(sources:.c=.d)
```

A `.PHONY` makefile, or one with a bare double-colon rule, is not remade — the
alternative is infinite restart — and `MAKE_RESTARTS` is exported for the second pass.

### The jobserver: a byte per slot in a pipe

> "In both implementations of the jobserver, the pipe will be pre-loaded with one
> single-character token for each available job. To obtain an extra slot you must read
> a single character from the jobserver; to release a slot you must write a single
> character back into the jobserver."
>
> — [`doc/make.texi`][manual] § Sharing Job Slots

`jobserver_setup` writes `slots` copies of the byte `'+'` into a pipe or named FIFO
(the default where supported) and publishes `--jobserver-auth=fifo:PATH` or `=R,W` in
`MAKEFLAGS` ([`src/posixos.c`][posixos], [`src/job.c`][job]). A plain child gets the
descriptors closed; a `+`-marked or `$(MAKE)` line gets them — that textual marker is
how recursion shares one budget, and any tool can join by reading the same bytes.
Scheduling is a ready-set loop: `update_goal_chain` alternates `start_waiting_jobs`,
`reap_children`, `update_file`; `-l` diverts a job to `waiting_jobs`, and `--output-sync`
serializes each target's output under a lock file passed to children in `MAKEFLAGS`
([`src/output.c`][output]). Tokens are taken before the fork, and the source is candid:

> "This can be inefficient. There's a decent chance this job won't actually have to
> run any subprocesses: the command script may be empty or otherwise optimized away."
>
> — [`src/job.c`][job]

## Analysis spine

### Placement in the scheduler × rebuilder grid

[Concepts] §5 puts `Make` at topological × dirty bit, and that is the right cell: no
dependency is discovered mid-build, and one bit per key decides everything. Two
qualifications: "topological" promises no precomputed order — the sequence emerges
from a depth-first walk, or a ready queue under `-j` — and the makefile loop _is_ a
restart, but at program level, discarding the graph and re-execing rather than
restarting a task.

### 1. Task model & scheduling

- **Task = (target path, prerequisites, recipe string)** — a tab-indented shell
  fragment, one `/bin/sh` per line unless `.ONESHELL`, no per-target directory.
- **Static and `Applicative`**: prerequisites expand at parse time;
  `.SECONDEXPANSION` moves expansion later, not into execution.
- **Depth-first with a ready set**: `update_file_1` recurses through `check_dep`, and
  parallel builds start whatever is ready. No speculation, cancellation, or task cost.
- **Parallelism is process-level**: `-j` (alone: unbounded, no pool at all), `-l`,
  `.NOTPARALLEL`, `.WAIT`, the jobserver; recursive `make` re-reads `MAKEFLAGS`.

### 2. Rebuilding & correctness

- **One dirty bit per key, from `mtime`** — cached in `last_mtime`, compared against
  the parent's pre-update stamp. Nothing hashes content, command text, flags,
  environment, or toolchain.
- **No early cutoff**: a newer prerequisite always rebuilds its consumer (grouped
  targets adopt the oldest peer's stamp); `$?` compares mtimes but never prunes.
- **Minimality is the weak, mtime kind**: at most one rebuild per target per run,
  over-approximated — `touch` over-builds, a restored stamp under-builds.
- **Correctness is the user's**: complete prerequisites and honest timestamps are
  assumed; `--shuffle` and the clock-skew warning are the only admissions otherwise.

### 3. Dependency discovery

- **Declared only.** Header dependencies arrive by the `.d`/`include` idiom — the
  compiler writes a makefile fragment and the remake loop surfaces it on the first
  build. `make` never reads a depfile format, traces a syscall, or sandboxes a recipe.
- **Wildcards** consult a cached directory listing (`src/dir.c`): one snapshot per run.
- **Strictness is a flag, and the flag is a fuzzer.** `--shuffle` reorders goals and
  prerequisites (seeded, reproducible, `.WAIT` lists exempt), so an undeclared order
  dependency fails intermittently, not on a customer's machine; reads stay undetected.

### 4. Store & caching

- **The output tree is the store**: no CAS, no action cache, no key, no sharing across
  machines or checkouts.
- **Intermediates are deleted after use** (`remove_intermediates`) unless `.PRECIOUS`,
  `.SECONDARY`, `.NOTINTERMEDIATE`, or `-t`/`-q` say otherwise ([`src/file.c`][file]).
- **Nothing survives the process** but the files written; the only repair tool is
  `-t`/`touch`.

### 5. Hermeticity & provenance

- **No sandbox, no isolation, no filtering.** Recipes inherit the environment,
  `MAKEFLAGS`, and the working directory; `export`/`unexport` and target-specific
  variables _add_ leakage rather than containment.
- **Provenance: nothing.** No attestation, signature, or record of what a recipe read;
  `-p` prints the parsed database and `--trace` prints what ran and why, once.

### 6. Distribution

Absent by design, with one archaeological exception: `src/remote-cstms.c` is a client
for pmake's **Customs** daemon, built only under `--with-customs=DIR` when a
`customs.h` is found ([`configure.ac`][configure], [`src/remote-cstms.c`][cstms]); its
header says "THIS CODE IS NOT SUPPORTED BY THE GNU PROJECT", and a default build links
`remote-stub.c`, where `start_remote_job_p` returns 0. The jobserver is the only live
protocol, and it distributes permits, not work.

### Sparkles relevance

`libs/build-primitives/src/sparkles/build_primitives/task/` is an in-memory validated
DAG with weighted admission and exclusive keys — no persistence, no rebuild layer, no
notion of a key's value. GNU Make is the cheapest complete model of what is missing:

- **A dirty bit can be one field.** `-o`/`-W`/`.PHONY` are three settings of one
  sentinel; a Sparkles task key could carry "pretend" inputs for tests.
- **Regenerate the plan, then restart the engine.** Re-exec is blunt but correct for
  "the manifest changed while we were reading it" — relevant to generated `dub.sdl` or
  task manifests, and cheaper than incremental graph mutation.
- **Adopt the jobserver as a child-facing contract**: a task that shells out to `dub`,
  `make`, or `ninja` can publish and honour `--jobserver-auth`, keeping one budget
  without teaching the child about the DAG.
- **Do not copy mtime as the key.** The DAG knows task identity, so a content or
  command digest is available where Make had only `stat`.

## Strengths

- **Zero state to corrupt**: no database, lock file, or format version; damaged state
  is only a wrong timestamp in the tree.
- **A complete ordered scheduler in a few thousand lines**, parallel and recursive,
  with a published cross-tool concurrency protocol.
- **Self-hosting configuration**: the remake loop makes generated makefiles and
  compiler depfiles first-class.

## Weaknesses

- **mtime is the only signal**, so touched files over-build, restored or coarse
  timestamps under-build, and a flag/toolchain/environment change is invisible.
- **No early cutoff and no content identity**, hence no sharing, remote cache, or
  deduplication even between two targets with identical inputs.
- **Undeclared reads are silent**; the only discovery aid is a fuzzed ordering that
  must be run repeatedly to find them.
- **Restart is all-or-nothing**: any makefile change re-reads everything and re-walks
  the graph, with no incremental re-parse.

## Key design decisions and trade-offs

| Decision                                 | Rationale                                                        | Trade-off                                                  |
| ---------------------------------------- | ---------------------------------------------------------------- | ---------------------------------------------------------- |
| The filesystem is the state store        | Zero setup, universal, survives any crash                        | No history, no sharing, no key beyond `path` plus `mtime`  |
| One dirty bit from `mtime`               | One `stat` per file; no digesting, no bytes on disk              | Over- and under-building; no early cutoff; flags invisible |
| Recipes are opaque shell strings         | Any language, any tool, no interface to learn                    | No sandbox, no input capture, no output declaration        |
| Implicit rules searched by shortest stem | Concise makefiles; chains found without being written            | Heuristic, order-sensitive, can invent intermediates       |
| Makefiles are goals; restart by re-exec  | Generated makefiles and depfiles need no separate mechanism      | Whole-program restart; `.PHONY`/`:: ;` guards required     |
| Jobserver: one byte per slot in a pipe   | Inheritable across `exec`, usable by non-`make` tools, no daemon | Token leaks deadlock; recursion detection is textual       |

## Sources

- GNU Make, clone at `$REPOS/build-systems-research/src/gnumake`, commit
  `b3802782de3eff2c0f1eda9e7c0befd8cd142162` (2026-04-29), origin
  [`git://git.savannah.gnu.org/make.git`][repo]; a grafted clone with no tags, so dates
  and versions come from the tree rather than `git describe`.
- Read in the clone: [`doc/make.texi`][manual] (Edition 0.77 — Rules, Implicit Rule
  Search, How Patterns Match, How Makefiles Are Remade, Generating Prerequisites
  Automatically, Parallel Execution, Sharing Job Slots, Options Summary);
  [`NEWS`][news], [`configure.ac`][configure], and in `src/`:
  [`remake.c`][remake], [`implicit.c`][implicit], [`job.c`][job], [`posixos.c`][posixos],
  [`main.c`][main], [`file.c`][file], [`filedef.h`][filedef], [`output.c`][output],
  [`remote-cstms.c`][cstms]; plus the `tests/scripts/features/` tree, where
  `jobserver`, `implicit_search` and `grouped_targets` live. Quotes are verbatim with
  Texinfo markup (`@code{}`, `@var{}`) removed; source comments are quoted as-is.
- Siblings: [concepts] (the vocabulary), [Ninja][ninja] (the verifying-trace executor
  Make's generators target), [GN][gn] (a generator emitting Makefiles and Ninja alike),
  [Shake][shake] (the suspending contrast), [Bazel][bazel] (the content-addressed
  contrast), [build2][build2] (a Make-lineage toolchain); view [Make][mono-make].

<!-- References -->

[repo]: https://cgit.git.savannah.gnu.org/cgit/make.git/
[manual]: https://cgit.git.savannah.gnu.org/cgit/make.git/tree/doc/make.texi?id=b3802782de3eff2c0f1eda9e7c0befd8cd142162
[news]: https://cgit.git.savannah.gnu.org/cgit/make.git/tree/NEWS?id=b3802782de3eff2c0f1eda9e7c0befd8cd142162
[configure]: https://cgit.git.savannah.gnu.org/cgit/make.git/tree/configure.ac?id=b3802782de3eff2c0f1eda9e7c0befd8cd142162
[remake]: https://cgit.git.savannah.gnu.org/cgit/make.git/tree/src/remake.c?id=b3802782de3eff2c0f1eda9e7c0befd8cd142162
[implicit]: https://cgit.git.savannah.gnu.org/cgit/make.git/tree/src/implicit.c?id=b3802782de3eff2c0f1eda9e7c0befd8cd142162
[job]: https://cgit.git.savannah.gnu.org/cgit/make.git/tree/src/job.c?id=b3802782de3eff2c0f1eda9e7c0befd8cd142162
[posixos]: https://cgit.git.savannah.gnu.org/cgit/make.git/tree/src/posixos.c?id=b3802782de3eff2c0f1eda9e7c0befd8cd142162
[main]: https://cgit.git.savannah.gnu.org/cgit/make.git/tree/src/main.c?id=b3802782de3eff2c0f1eda9e7c0befd8cd142162
[file]: https://cgit.git.savannah.gnu.org/cgit/make.git/tree/src/file.c?id=b3802782de3eff2c0f1eda9e7c0befd8cd142162
[filedef]: https://cgit.git.savannah.gnu.org/cgit/make.git/tree/src/filedef.h?id=b3802782de3eff2c0f1eda9e7c0befd8cd142162
[output]: https://cgit.git.savannah.gnu.org/cgit/make.git/tree/src/output.c?id=b3802782de3eff2c0f1eda9e7c0befd8cd142162
[cstms]: https://cgit.git.savannah.gnu.org/cgit/make.git/tree/src/remote-cstms.c?id=b3802782de3eff2c0f1eda9e7c0befd8cd142162
[concepts]: ./concepts.md
[ninja]: ./ninja.md
[gn]: ./gn.md
[shake]: ./shake.md
[bazel]: ./bazel.md
[build2]: ./build2.md
[mono-make]: ../monorepo-tooling/make/
