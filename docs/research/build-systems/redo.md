# redo (Python/sh, recursive build engine)

redo's engine in one sentence: a target is a shell script that recursively calls
`redo-ifchange` on whatever it read, and a SQLite table of file stamps plus per-run IDs
decides — without re-running any script — whether that target is stale.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                                                                                           |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | Python (`setup.py` declares `python_requires='>=2.7'`); `.do` scripts are POSIX `sh`                                                            |
| License               | Apache-2.0 (`LICENSE`)                                                                                                                          |
| Repository            | [`apenwarr/redo`][repo]                                                                                                                         |
| Documentation         | In-tree `docs/` ([`docs/index.md`][docs-index], [`docs/redo.md`][docs-redo])                                                                    |
| Category              | Recursive / minimalist build engine; engine companion to [redo (monorepo-tooling)][mono-redo]                                                   |
| Clone (pinned)        | `$REPOS/build-systems-research/src/redo` at `7f00abc36be15f398fa3ecf9f4e5283509c34a00` (2021-07-27); tag `redo-0.42d`, one-commit shallow clone |
| Scheduler × rebuilder | Suspending × verifying step traces ([concepts] §5), with a run-scoped dirty-bit fast path and opt-in checksum cutoff                            |
| Persistent state      | `.redo/db.sqlite3` (`Files`, `Deps`, `Runid`, `Schema`), `.redo/locks`, `.redo/log.<fid>`                                                       |

> [!NOTE]
> **Delta against the workspace page.** [redo (monorepo-tooling)][mono-redo] covers the
> `.do` contract, the four verbs, cross-directory builds through one global database, the
> CLI, and the `dub`-workspace verdict. This page stays inside the engine: the
> `deps.isdirty` trace, the SQLite schema and two-phase dependency replacement, the
> lock/cycle protocol, out-of-band rebuilding of stamped targets, `.do` lookup as negative
> dependencies, and why sandboxing and distribution are absent.

## Overview

### What it solves

> "Smaller, easier, more powerful, and more reliable than `make`."
>
> — [`README.md`][readme]

redo replaces Make's global ruleset and ahead-of-time prerequisites with one script per
target that declares its own inputs while it runs; the design is Daniel J. Bernstein's, and
this implementation adds parallel builds, logging, tests, and debugging aids
([`README.md`][readme]).

### Design philosophy

**The shell is the DSL** — there is no rule syntax and no graph language to learn:

> "One of my favourite features of redo is that it doesn't add any new syntax; the syntax
> of redo is _exactly_ the syntax of sh... because sh is the program interpreting your
> .do file."
>
> — [`docs/FAQSemantics.md`][faq-sem]

**Dependencies are a side effect of execution.** "redo is based on this simple insight: you
don't actually care what the dependencies are _before_ you build the target. If the target
doesn't exist, you obviously need to build it" ([`docs/index.md`][docs-index]).

**Output is committed, not written in place**: a script writes `$3` or stdout, and redo
renames the temporary file over the target only on exit code `0` — "redo is designed to
update its targets atomically" ([`docs/redo.md`][docs-redo]).

## How it works

### The `.do` contract

The workspace page covers `$1`/`$2`/`$3` and the rule search; engine-side,
`builder._record_new_state` enforces the output rules: writing `$1` directly is error
`206`, writing both stdout and `$3` is `207`, and a failed rename is `209`
([`redo/builder.py`][builder-py]). On success it records the new stamp and marks the target
changed; the atomic rename is the only commit point. The search order itself lives in
[`redo/paths.py`][paths-py].

### The verbs and what they record

| Invocation         | Engine effect                                                               | Persisted as                         |
| ------------------ | --------------------------------------------------------------------------- | ------------------------------------ |
| `redo T…`          | Always run `T`'s script, even if `T` is current                             | None (forced rebuild)                |
| `redo-ifchange T…` | Record a dependency on `T` and build it only if dirty                       | `Deps.mode = 'm'`                    |
| `redo-ifcreate T…` | Depend on `T` remaining **absent** (`T` must not exist now)                 | `Deps.mode = 'c'`                    |
| `redo-always`      | Add the sentinel `//ALWAYS`, so the caller rebuilds every run               | `Deps.mode = 'm'`, source `//ALWAYS` |
| `redo-stamp`       | Hash stdin; mark the caller changed only if the hash differs from last time | `Files.csum` (SHA-1)                 |

`redo-ifchange` is both the build request and the graph edge; outside a `.do` script it
builds but records no edge. `redo-always` uses a reserved invalid filename — "an invalid
filename that is always marked as dirty" — whose `changed_runid` advances on every open
([`redo/state.py`][state-py]).

### The dirty check: `deps.isdirty`

`redo-ifchange` asks `deps.isdirty` about each target; it returns `CLEAN`, `DIRTY`, or a
list of targets that must be built before the answer is known ([`redo/deps.py`][deps-py]).
A failed last build, a never-built key, or a `changed_runid` newer than the parent's last
check is dirty; a key already checked this run is clean (the `checked_runid` fast path);
otherwise the stored stamp is compared with current metadata (`mtime`, `size`, `inode`,
`mode`, `uid`, `gid`; a symlink compares link and target). A changed stamp is dirty —
unless the key has a `csum` (`redo-stamp`), when it is only **maybe** dirty and its script
must run once to compare the stamp data. Mode `'c'` dependencies are dirty when the path now
exists; mode `'m'` dependencies recurse with the parent's `changed_runid` as `max_changed`.

When the answer is "maybe", `redo-unlocked` builds those targets out of band and
`redo-ifchange` asks again — "Out-of-band redo of some sub-objects. This happens when we're
not quite sure if t needs to be built or not (because some children look dirty, but might
turn out to be clean thanks to redo-stamp checksums)" ([`redo/builder.py`][builder-py]).
This is redo's only early-cutoff mechanism, and it is opt-in per target.

## Analysis spine

### Placement in the scheduler × rebuilder grid

[Concepts] §5 records the paper's own placement: redo "almost exactly matches Shake" —
**suspending × verifying traces**. A script is suspended inside `redo-ifchange` while a
dependency is brought up to date, then resumes; the persistent object is a trace of the
previous execution, not a declared graph.

The trace is a **verifying step trace** ([concepts] §5.2.2): redo stores `changed_runid`,
`checked_runid`, `failed_runid`, and a metadata stamp — not hashes of dependency values.
`redo-stamp` is not constructive: it stores a hash, not a value, so a miss can only rebuild,
never materialize.

### 1. Task model & scheduling

- **The task is a script**, one target per script, with no typed input/output declaration.
- **Dependencies are calls that suspend.** `redo-ifchange a b` builds the needed
  sub-targets and blocks until they are current; the caller then resumes. The process tree
  is the scheduler.
- **Parallelism is process-level and token-bounded.** One call with several targets builds
  them concurrently; a loop of separate calls cannot, which is why the docs recommend
  batching through `xargs` ([`docs/redo-ifchange.md`][ifchange]).
- **Ordering aids, not speculation.** `--shuffle` randomizes order to expose missing
  dependencies; `-k` keeps going after failures; `-j` sets the token count.

### 2. Rebuilding & correctness

`redo-ifchange` is minimal only if scripts declare every input they read; `redo` is
deliberately **not** minimal because it always rebuilds the named target
([`docs/redo.md`][docs-redo]). Within a run a key is checked at most once
(`checked_runid`), so shared dependencies are not rebuilt twice.

The trace is replaced, not appended. Before a target runs, `zap_deps1` marks its old
dependency rows `delete_me`; after the run, `zap_deps2` deletes rows the run did not
re-reference ([`redo/state.py`][state-py]). A failed run is separately marked
`failed_runid`, so it is dirty on the next check.

**`redo-stamp`** compares a SHA-1 of stdin with the stored `csum`; equal means the target is
checked but not changed, so dependents stay clean — "This is the only time that `redo` ever
rebuilds a target that hasn't been explicitly asked for…" ([`docs/redo-stamp.md`][stamp]).
**Manual-override detection** compares mtime and size; a hand-edited generated file gets
"you modified it; skipping" and is treated as static ([`redo/state.py`][state-py]). Without
a stamp, a rebuilt target is always marked changed.

### 3. Dependency discovery

- **Declared at runtime by the script**, not inferred by the engine. A compiler depfile
  helps only because the script reads it and passes names to `redo-ifchange`: "You can
  generate your target first, then declare its dependencies"
  ([`docs/redo-ifchange.md`][ifchange]).
- **Negative dependencies are first class.** `redo-ifcreate` records a path that must stay
  absent; `redo-always` records the sentinel; `.do` lookup records every skipped candidate.
- **No tracing and no sandbox.** No `ptrace`, FUSE, or syscall interception; an undeclared
  read succeeds silently and is not in the graph.
- **Introspection is diagnostic.** `redo-ood` lists stale targets and `redo-whichdo` prints
  the rule search path ([`redo/cmd_ood.py`][cmd-ood], [`redo/cmd_whichdo.py`][cmd-whichdo]);
  neither fails a build for an undeclared dependency.

### 4. Store & caching

The store is one SQLite database at `$REDO_BASE/.redo/db.sqlite3`, schema version `2`
([`redo/state.py`][state-py]):

```sql
create table Files (name not null primary key, is_generated int, is_override int,
                    checked_runid int, changed_runid int, failed_runid int,
                    stamp, csum)
create table Deps  (target int, source int, mode not null, delete_me int,
                    primary key (target, source))
create table Runid (id integer primary key autoincrement)
create table Schema (version int)
```

`Runid` is the logical clock: each top-level invocation allocates an id, and `*_runid`
columns are compared against it rather than wall-clock times. The database opens with
`synchronous = off` and WAL (PERSIST when locks are known broken); an unknown schema version
aborts with "manually delete .redo dir to start over".

There is **no content-addressed store, no action cache, and no remote cache**. The only
content-addressed datum is `redo-stamp`'s SHA-1, stored as a hash rather than bytes, so it
can suppress work but cannot supply an output. Logs are separate `.redo/log.<fid>` files,
replayed by `redo-log`; they are debugging artifacts, not cache entries. There is no
eviction beyond the user's own `clean.do`.

The single database is the main structural limit: the base is guessed by walking up from
the common prefix of the requested targets until a `.redo` is found
([`redo/env.py`][env-py]), and symlinked or nested projects can disagree. The roadmap
proposes one `.redo` per target directory ([`docs/Roadmap.md`][roadmap]).

### 5. Hermeticity & provenance

- **No sandbox.** Scripts run in the real filesystem with the working directory set to the
  script's directory and inherit the environment (plus `REDO_*`); nothing prevents an
  undeclared file read or environment lookup. The enforced discipline is output, not input:
  `$3` plus `rename(2)` makes replacement atomic, while writing `$1` is rejected.
- **Environment sharing is a known hole.** The roadmap proposes wiping all but a short
  whitelist, because "running `redo-ifchange /path/to/file` should always run `file`'s .do
  script with exactly the same settings" ([`docs/Roadmap.md`][roadmap]).
- **No provenance or attestation.** Logs are local, overwritten per build, and unsigned;
  there is no SLSA, in-toto, action digest, or signed graph in the clone.

### 6. Distribution

Absent, and documented as absent: "So far, nobody has tried redo in a distributed build
environment" ([`docs/FAQParallel.md`][faq-par]). The roadmap's distributed-redo idea
depends on first removing environment sharing and still describes separate workers, not a
content-addressed cache or remote protocol ([`docs/Roadmap.md`][roadmap]).

What exists is local coordination: the jobserver for tokens, per-target `fcntl` locks, and
`redo-log`'s pipe. `redo` and `make` can recurse into each other and share one token pool,
and `distcc` works because it is a compiler wrapper — neither is engine-level distribution.
There is no network code, no REAPI client, and no cross-machine artifact.

### 7. Sparkles relevance

`libs/build-primitives/src/sparkles/build_primitives/task/` keeps its task DAG in memory;
redo is the smallest complete model of what persistence would add. Borrow the shape: a
per-run clock with `checked`/`changed`/`failed` marks; two-phase dependency replacement that
preserves the last known-good graph; negative dependencies; and opt-in content stamps for
early cutoff. Avoid the single global database, the Python process cost, and stdout capture.

## Strengths

- **The graph is discovered by execution**, so the recorded set is exactly what the script
  used — no hand-maintained prerequisites, no rule-language parser.
- **Correct incremental checks without re-running scripts**: a clean pass reads SQLite rows
  and file metadata only.
- **Atomic outputs and first-class negative dependencies**: `$3` plus rename leaves the old
  target intact; `redo-ifcreate` and skipped `.do` candidates capture "absence is an input".
- **Shared-dependency correctness under parallelism**: per-target locks and cycle detection
  make recursive builds safe across independent invocations.

## Weaknesses

- **Correctness depends on the script author.** No sandbox, tracing, or strict-deps check: a
  missed `redo-ifchange` silently under-approximates the graph.
- **No content-addressed store or remote execution**, so results cannot be shared between
  machines and there is no action-cache key.
- **One global database per project** creates root-discovery, symlink, and nested-project
  ambiguity; the per-directory fix is unimplemented.
- **Process-per-target plus Python fork/exec** is the performance ceiling, and **early cutoff
  is opt-in** and only as good as the chosen stamp data.
- **No provenance or attestation**: logs are local and overwritten, so a build's inputs are
  not independently auditable afterwards; stdout capture can silently corrupt a target.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                        | Trade-off                                                             |
| --------------------------------------------------- | ---------------------------------------------------------------- | --------------------------------------------------------------------- |
| One `.do` script per target; `sh` is the DSL        | No parser or rule language; debuggable with ordinary shell tools | Logic is spread across many scripts; script quality is graph quality  |
| Dependencies declared by running the script         | Records what was actually read, including late-discovered inputs | A missed call is invisible; no engine-side enforcement                |
| Persistent SQLite database per project              | Fast no-op checks, transactional updates, one queryable graph    | Root discovery and symlinks are ambiguous; schema changes are manual  |
| Metadata stamp (mtime, size, inode, mode, uid, gid) | Cheap and more resilient than plain mtime                        | Cannot see content; needs `redo-stamp` for byte-level cutoff          |
| `redo-stamp` as opt-in SHA-1 of stdin               | Early cutoff only where it pays; no cost on ordinary targets     | Author must choose the right bytes; stores no value to materialize    |
| Suspending scheduler via recursive processes        | Reuses the shell as the continuation; no central scheduler       | Fork/exec cost per call; parallelism only across batched targets      |
| Per-target `fcntl` locks plus `REDO_CYCLES`         | Safe shared dependencies across concurrent recursive invocations | POSIX lock quirks; WSL needs a broken-lock fallback                   |
| No sandbox, no CAS, no distribution                 | Tiny, portable, dependency-free engine                           | Undeclared inputs silent; no sharing, provenance, or remote execution |

## Sources

- [`apenwarr/redo`][repo] at commit
  `7f00abc36be15f398fa3ecf9f4e5283509c34a00` (2021-07-27), clone at
  `$REPOS/build-systems-research/src/redo`; engine claims rest on [`redo/state.py`][state-py],
  [`redo/deps.py`][deps-py], [`redo/builder.py`][builder-py], [`redo/paths.py`][paths-py],
  [`redo/env.py`][env-py], [`redo/cycles.py`][cycles-py], [`redo/jobserver.py`][jobserver];
  the reference block lists every file opened.
- Siblings: [concepts] (the vocabulary), [Shake][shake] (the canonical
  suspending × verifying-traces system), [Ninja][ninja] (a topological executor with the
  same mtime weakness), and [GNU make][gnumake] (the jobserver baseline). Workspace view:
  [redo (monorepo-tooling)][mono-redo].

<!-- References -->

[repo]: https://github.com/apenwarr/redo
[readme]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/README.md
[docs-index]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/docs/index.md
[docs-redo]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/docs/redo.md
[faq-sem]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/docs/FAQSemantics.md
[faq-par]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/docs/FAQParallel.md
[ifchange]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/docs/redo-ifchange.md
[stamp]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/docs/redo-stamp.md
[roadmap]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/docs/Roadmap.md
[state-py]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/redo/state.py
[deps-py]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/redo/deps.py
[builder-py]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/redo/builder.py
[paths-py]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/redo/paths.py
[env-py]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/redo/env.py
[cycles-py]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/redo/cycles.py
[jobserver]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/redo/jobserver.py
[cmd-ood]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/redo/cmd_ood.py
[cmd-whichdo]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/redo/cmd_whichdo.py
[concepts]: ./concepts.md
[shake]: ./shake.md
[ninja]: ./ninja.md
[gnumake]: ./gnumake.md
[mono-redo]: ../monorepo-tooling/redo/
