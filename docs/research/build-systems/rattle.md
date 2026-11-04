# Rattle (Haskell) — the repository and its practice

[Rattle][repo] is the system behind [perfect-dependencies]: a forward build system that
runs a straight-line command script, learns each command's reads and writes from `fsatrace`,
and recovers parallelism by speculating on the last run's order. The paper supplies the
semantics and measurements; this page reads the repository at its pinned commit — module
layout, trace folding, on-disk state, speculation, hazards and maturity. Vocabulary is
[concepts]'s; the core terms are not redefined here.

**Last reviewed:** November 2, 2026

| Field          | Value                                                                                                                      |
| -------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Language       | Haskell 2010; `tested-with: GHC==9.6, GHC==9.4, GHC==9.2`                                                                  |
| License        | BSD-3-Clause **or** Apache-2.0 — `x-license: BSD-3-Clause OR Apache-2.0`; `LICENSE` carries both texts                     |
| Repository     | [ndmitchell/rattle][repo]                                                                                                  |
| Documentation  | No manual; `README.md` is the design note and future-paper draft; Haddock from `src/`                                      |
| Category       | Industry / research artifact — a **forward** build-system library, not a cell in [a-la-carte]'s grid                       |
| Clone (pinned) | `$REPOS/build-systems-research/src/rattle` at `3c935ca004ec8557ad6edb92d42f8bdf5bc78f46` (2023-10-15)                      |
| Version        | `0.2` (`rattle.cabal`); `CHANGES.txt`: `0.2` released 2020-05-27, `0.1` released 2019-04-17                                |
| Size           | 23 `.hs` modules under `src/`, 7 under `test/`, 7 under `benchmark/`; one exposed module `Development.Rattle`              |
| Build          | `cabal`; library depends on `shake >= 0.19`, `cryptohash-sha256`, `hashable`, `async`, `heaps`, `js-*`, `template-haskell` |

## Overview

### What it solves

> "To write a Rattle build system you need to write a script that builds your code. No
> dependencies, no targets, just a straight-line script that builds your code."
>
> — [`README.md`][readme]

`cmd` blocks until the command ran, was skipped, or was copied from the shared directory;
the argument and its measured costs are in [perfect-dependencies].

### Design philosophy

The module documentation states the two rules the hazard checker enforces but cannot repair:

> "General rules for writing consistent rattle build systems:
>
> - Never write to the same file twice. Never read then write.
> - Don't delete files that have been produced. Each command should make
>   new files, not delete old files."
>
> — [`src/Development/Rattle.hs`][rattle-module]

The engine never sees control logic, so a script edit needs no invalidation and a command's
identity is its command line; anything cacheable must be a command. Trace completeness is
the only correctness input, which is why tracing misses are silent and `fsatrace` is a
runtime dependency.

## How it works

### Repository shape

The library is one exposed module (`Development.Rattle`) over internal modules listed in
[`rattle.cabal`][cabal]: `Server` (state machine and pool), `Hazards`/`Shared`/`Hash`
(conflicts, store, hashing), `CmdOption`/`Program` (engine metadata, Template Haskell
lifting), `Profile`/`UI`, and `General.*`. `pipeline`, `rattle-benchmark` and a disabled
`buildScript` sit beside it.

### A command and its identity

`Cmd` is `Cmd Int [CmdOption] [String]`, where the `Int` is `hash (options, arguments)` and
`Hashable Cmd` returns it, so every map and store key is the command line. The binary
instance special-cases the common option lists into one byte. A changed flag or argument is
a different command — different cache entry, different speculation candidate — while the
script text is never hashed.

| `CmdOption2`                         | Meaning                                                     |
| ------------------------------------ | ----------------------------------------------------------- |
| `Ignored [FilePattern]`              | Paths never hashed even if traced (locks, temp dirs)        |
| `Read [FilePath]` / `Write […]`      | Declare accesses the tracer missed                          |
| `HashNonDeterministic [FilePattern]` | Name outputs whose content must not be compared directly    |
| `WriteFile FilePath`                 | Write the arguments to a file instead of spawning a process |

Each is encoded as `AddEnv "#!RATTLE" (show option)` and partitioned out before the process
starts, so the metadata is invisible to Shake's command runner.

### Tracing: `fsatrace` in, `Touch` out

Rattle does not interpose itself. It calls Shake's command runner with `fsatrace` attached
and folds `FSATrace` events into a `Touch`:

| `fsatrace` event       | Rattle interpretation |
| ---------------------- | --------------------- |
| `FSARead`, `FSAQuery`  | read                  |
| `FSAWrite`, `FSATouch` | write                 |
| `FSADelete`            | **write**             |
| `FSAMove`              | **write** both names  |

The delete and move mappings are why the module rule forbids deleting produced files: a
deletion is a write-write hazard with whatever created the file. `normalizeTouch` sorts
reads, de-duplicates writes, and drops a read the same command also wrote. Before hashing,
the server discards `/dev/` entries, directory paths and `Ignored` matches; `Read`/`Write`
options cover the blind spots the README lists (Go and static binaries on Linux/macOS, macOS
system binaries under SIP). Directory _listings_ are never reported.

### The store on disk

Everything lives under `rattleFiles` (default `.rattle`), behind one lock:

| Path                       | Contents                                                                 | Mode      |
| -------------------------- | ------------------------------------------------------------------------ | --------- |
| `command/<2hex>/<resthex>` | append-only `[Trace (FileName, ModTime, Hash)]`; `.txt` sidecar names it | append    |
| `speculate/<hash>`         | the `required` list of the last run, keyed by `rattleSpeculate`          | overwrite |
| `files/<2hex>/<resthex>`   | output bytes, named by SHA-256                                           | once      |
| `run/<hash>`               | monotonically increasing `RunIndex` per `rattleMachine`                  | overwrite |
| `program/<hash>.hs`        | generated Template Haskell program source                                | once      |

The two-hex-digit fan-out keeps directories small; `setFile` copies to `<hash>.tmp`,
re-hashes the copy, and renames only if the check passes, so a failed write never becomes a
hit. `rattleShare` decides whether an existing entry wins or is overwritten; `rattleDump`
prints the whole store. The `File` record is serialised as mtime, hash, then path — "to get
better word orientated diffs when looking at the output in a text editor" ([`Shared.hs`][shared]).
There is no eviction, size accounting or compaction.

### Speculation and the state machine

`S` holds `started` (dedup map from `Cmd` to a running `IO`), `running` (start time, command,
previous trace trimmed to possible speculated writes), `hazard` (live access set), `pending`
(completed traces awaiting commit), `required` (commands the script asked for), `speculatable`
and `speculateNext`. The guess is recomputed on every state change:

> "speculate on a process iff it is the first process in speculate that:"
>
> — [`Server.hs`][server]

The five conditions add: free parallelism, first eligible, not already started, no read/write
conflict with anything completed, and no read conflict with anything running or any earlier
speculation. The conflict checks use a `TouchSet` of running commands' predicted accesses
plus the live `HazardSet`, so the engine guesses more than one step ahead without two
speculations colliding. Speculation starts only when `rattleProcesses > 1`, and the candidate
list is truncated at the first command with no previous trace, so a script change makes the
next cold build serial. `withRattle` adds one capability beyond the process count for the
speculation worker, and the pool gives `PoolRequired` priority over `PoolSpeculate`.
Failures of speculative commands are discarded; whoever later requires the command sees the
error. At exit `required` becomes the next `speculate` list, but only when `rattleSpeculate`
is `Just key` (default `Just ""`); `Nothing` disables both.

### Rebuilding, hashing and forwarding

A command is skipped when a previous trace's reads all hash-match and its writes all
hash-match; the first consistent trace wins. If none is consistent, with `rattleShare` on,
any historical trace whose every write is present in `files/` is copied in and recorded as
done. Otherwise the command runs, is traced and hashed, its outputs are optionally stored,
and a trace is appended. Early cutoff is implicit: a rebuilt file with identical bytes leaves
dependents' read hashes matching. There is no graph to walk, so every command is considered
every build.

Hashes are SHA-256, cached in memory by `(path → (mtime, hash))`. `hashFileIfStale` stats,
reuses the cached hash when the mtime matches, re-stats after hashing and caches only if the
file did not change mid-read. With `rattleForward` on, each normal output gets a `.rattle.hash`
companion holding `hash (show (cmd, reads, non-deterministic writes))`, where
`HashNonDeterministic` names the outputs not to compare directly; the trace records the
_companion_. `checkHashForwardConsistency` rejects a forwarding file written without its
source, or a source written without updating its companion. Trace
commits are deferred: a finished command lands in `pending`, and a trace reaches disk only
once every command that was running when it finished has also finished (`fst3 x < earliest`),
so a clean trace is never recorded while a concurrent command may still write its files.

### Hazards in practice

The live set records each file's earliest possible read and latest possible write, so any
interleaving can be checked by merging two touches:

> "Read is recorded as soon as it can, Write as late as it can, as that increases hazards."
>
> — [`Server.hs`][server]

Merging in [`Hazards.hs`][hazards] yields the repository's dispositions:

| Situation                        | Disposition                                                                             |
| -------------------------------- | --------------------------------------------------------------------------------------- |
| two writes                       | `NonRecoverable` when both commands are required, `Restartable` when one was speculated |
| read before write                | `Recoverable` if the reader was speculated, `Restartable` if the writer was             |
| read before write, both required | `NonRecoverable` if the script put the reader first, `Restartable` if the writer first  |
| write before read                | safe unless the reader was required and the writer speculative                          |

The both-required row is optimistic, because parallelism can race two required commands:

> "FIXME: We might have had them race because of parallelism, so this is optimistically
> restartable"
>
> — [`Hazards.hs`][hazards]

Recovery is narrower than the paper's four strategies. `withRattle` catches a hazard, prints
`Warning: Speculation lead to a hazard, retrying without speculation`, resets to the initial
state with `speculatable = []`, and reruns; `NonRecoverable` is rethrown at once. The
`speculated` `IORef` is read on that path, but the retry branch tests only the disposition.

The tests show hazards are not reproducible on demand. `Test.Simple` build 4 runs the
executable before relinking it, wraps the run in `handle`, and admits:

> "Hoped it failed, but doesn't always"
>
> — [`test/Test/Simple.hs`][test-simple]

with `fail "Expected a hazard"` commented out. Build 7 forces a restartable hazard by
running `touch` on every source, which the tracer records as a write. Separately,
`Profile.createEdge` reconstructs write-write and read-write edges from recorded traces, so
a hazard can be diagnosed from a store dump rather than only observed live.

### Maturity signals

The clone is shallow — one commit, no tags — so it cannot show upstream history. The tree
records a research artifact kept compiling: `0.2` (2020-05-27) is the last `CHANGES.txt`
entry, `0.1` (2019-04-17) was "not ready for public use", and copyright runs to 2023. HEAD
is 2023-10-15, `Upgrade to a newer Stackage so hopefully cereal starts working` — dependency
maintenance, not design. CI is a Linux matrix over GHC 9.2–9.6 plus Windows. `README.md`
calls itself "a dumping ground for things that will either go into a user manual or an
academic paper (if one ever gets written)". `.weeder.yaml` suppresses `Profile` as "Module
still in development"; `General/FileInfo.hs` is copied from Shake commit `645c99b`; and
`rattle.cabal` promises "speculation and remote caching" while the implemented share is a
mounted directory, and the HTML profile ([`html/profile.html`][profile-html]) is still titled
"Shake report".

## Analysis spine

### Placement in the scheduler × rebuilder grid

Rattle does not occupy a cell of [concepts]'s Table 2: no keys, targets or `fetch`, so the
unit is a command line and the schedule is the author's order weakened by speculation — a
fourth scheduler. Its store keeps output bytes by content hash, constructive in spirit but
keyed by command line. [perfect-dependencies] gives the full comparison.

### 1. Task model & scheduling

The script is the task description and `cmd` the only primitive; `forP` adds explicit
parallelism, everything else is speculation. `cmdRattleStarted` deduplicates by `Cmd`, so a
repeated command waits on the first one's `IO`. The process count defaults to `0`, resolved
to `getProcessorCount` (Shake defaults to one); policy is otherwise thin.

### 2. Rebuilding & correctness

File-granular content comparison: a command is skipped only when every recorded read and
write still matches. Early cutoff falls out of identical bytes; minimality does not, since
every command is considered each build. Correctness is conditional on trace completeness and
determinism; deferred commits and the mtime recheck are the race mitigations.

### 3. Dependency discovery

Tracing only, at syscall-interposition strength, with no strictness checking or pruning. The
server subtracts ignored paths and directories and drops reads the same command wrote.
Manual `Read`/`Write` options cover blind spots and reintroduce the declaration problem.
Listings are unrecorded, so a new file does not invalidate a directory-listing command.

### 4. Store & caching

Three keyed stores plus a content-addressed file map behind one lock; command histories are
append-only and unbounded. `rattleShare` is a boolean over a mounted directory, not a
service — no eviction, accounting, authentication or concurrency protocol. `.rattle.hash`
forwarding is the only content-key relaxation.

### 5. Hermeticity & provenance

No sandbox: nothing prevents an undeclared access, the engine records it and calls the result
a dependency. `$PWD` substitution and ignored patterns are cache hygiene, not isolation.
There is no provenance or attestation; a shared trace is trusted because it is there.

### 6. Distribution

Absent. The share distributes results, execution is local. `pipeline` composes `;`, `&&` and
`||` so a multi-step tool becomes one traced command; `Program` makes host logic cacheable.
The README's [BuildXL][buildxl] pointer is to its sandboxing design, not an integration.

### 7. Sparkles relevance

The paper page draws the design lessons; the repository adds four mechanics:

- **Commit a node's record only after concurrent nodes finish.** `pending` makes "on disk"
  mean "no still-running command can invalidate it"; a Sparkles journal needs that rule.
- **An append-only, human-inspectable journal.** Per-command history, `.txt` sidecars and
  `dump` make the store debuggable; Sparkles keeps no cross-run state.
- **Validate a declared DAG from observed accesses.** `Profile.createEdge` reconstructs
  write-write and read-write edges after the run — a check a static graph cannot self-apply.
- **Profile from recorded durations.** Work, span and their ratio come from data already
  written; avoid linear rebuild, no eviction, and a tracer as a runtime dependency.

## Strengths

- **A minimal, honest implementation of the paper.** The public surface is `cmd` plus a few
  options, and every mechanism has a small, readable module behind it.
- **The store is designed to be inspected.** Two-level fan-out, `.txt` sidecars, an
  append-only journal and a `dump` that prints all three stores.
- **Hazards are first-class, with dispositions.** The taxonomy turns "retry or fail" into a
  property of the conflict, and traces can be re-checked after the fact.

## Weaknesses

- **The tracing dependency is unresolved.** `fsatrace` must be installed and misses Go,
  static and macOS system binaries; the fallback is manual `Read`/`Write`, and
  `Test.Simple` cannot assert that its hazard reproduces.
- **Small-scale and unfinished.** One release in 2020, no manual, a shallow 2023 dependency
  fix, an HTML report titled "Shake report", and comments admitting a non-terminating pool
  case and an optimistic hazard classification.
- **No scale story.** Linear rebuild, one speculation key, one lock, no eviction, no remote
  execution; the paper's evidence stops at one project measured in hours.

## Key design decisions and trade-offs

| Decision                                  | Rationale                                                              | Trade-off                                                                              |
| ----------------------------------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Command line as cache and speculation key | No targets to invent; a changed command is naturally a different entry | Script edits invisible; no subtree build; no key another tool can address              |
| `fsatrace` behind Shake's runner          | Reuses a working tracer and process API                                | Runtime dependency; silent blind spots; manual declarations reintroduce Make's problem |
| Content hashes for reads and writes       | Whitespace-only edits free; early cutoff falls out                     | Hashing every touched file; no byte-level granularity                                  |
| Deferred trace commit (`pending`)         | A stored trace cannot be invalidated by a still-running command        | Traces lag completion; a crash loses the tail                                          |
| Hazard dispositions instead of a graph    | Finds script defects before they corrupt a rebuild                     | Needs coverage; the read/write case is "optimistically restartable"                    |
| Restart-without-speculation recovery      | Simple and provably equivalent to the sequential baseline              | Discards work; speculative writes to inputs are unrecoverable                          |
| Shared directory, no cache service        | NFS/Samba suffices for a research artifact                             | No eviction, accounting, authentication or concurrency control                         |

## Sources

- [`ndmitchell/rattle`][repo] at `3c935ca004ec8557ad6edb92d42f8bdf5bc78f46`, clone at
  `$REPOS/build-systems-research/src/rattle` (shallow, clean). Opened: [`README.md`][readme],
  [`CHANGES.txt`][changes], [`rattle.cabal`][cabal], [`LICENSE`][license], [CI][ci],
  [weeder][weeder]; [`Server.hs`][server], [`Hazards.hs`][hazards], [`Shared.hs`][shared],
  [`Hash.hs`][hash], [`Options.hs`][options], [`CmdOption.hs`][cmdoption],
  [`Program.hs`][program], [`Profile.hs`][profile], [`Pool.hs`][pool],
  [`FileInfo.hs`][fileinfo], [`Test/Simple.hs`][test-simple]. The paper and context are
  [perfect-dependencies], [concepts], [a-la-carte], [shake], [buildxl] and [index].

<!-- References -->

[repo]: https://github.com/ndmitchell/rattle
[readme]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/README.md
[changes]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/CHANGES.txt
[cabal]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/rattle.cabal
[license]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/LICENSE
[ci]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/.github/workflows/ci.yml
[weeder]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/.weeder.yaml
[rattle-module]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle.hs
[server]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Server.hs
[hazards]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Hazards.hs
[shared]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Shared.hs
[hash]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Hash.hs
[options]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Options.hs
[cmdoption]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/CmdOption.hs
[program]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Program.hs
[profile]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Profile.hs
[profile-html]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/html/profile.html
[fileinfo]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/General/FileInfo.hs
[pool]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/General/Pool.hs
[test-simple]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/test/Test/Simple.hs
[concepts]: ./concepts.md
[perfect-dependencies]: ./perfect-dependencies.md
[a-la-carte]: ./a-la-carte.md
[shake]: ./shake.md
[buildxl]: ./buildxl.md
[index]: ./index.md
