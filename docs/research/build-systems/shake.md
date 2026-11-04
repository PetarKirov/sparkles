# Shake (Haskell)

Shake is the industrial implementation of one cell in [concepts]'s design space: a
**suspending scheduler** composed with **verifying step traces**, packaged as a
Haskell library in which the build script _is_ a program. The JFP paper models Shake and
reports on its cloud build; the system later grew a shared cache, becoming `Cloud Shake` — so
this page reads as the reference implementation of JFP §5.2.2 and §7.3.

**Last reviewed:** November 2, 2026

| Field          | Value                                                                                   |
| -------------- | --------------------------------------------------------------------------------------- |
| Language       | Haskell; `tested-with: GHC==9.14 … GHC==9.4`                                            |
| License        | BSD-3-Clause — `license: BSD3`, "Copyright Neil Mitchell 2011-2026"                     |
| Repository     | [ndmitchell/shake][repo]; homepage `shakebuild.com`                                     |
| Documentation  | In-tree `docs/` (`Architecture.md`, `Manual.md`, `Why.md`, `Cloud.md`, `Lint.md`)       |
| Category       | Industry — a build-system _library_, not a build system                                 |
| Clone (pinned) | `$REPOS/build-systems-research/src/shake` at `526051c894aa88addb845e3e6b52b02a69becf8a` |
| Version        | `0.19.9` (`shake.cabal`); `CHANGES.txt`: "0.19.9, released 2026-01-19"                  |
| Size, tests    | 126 `.hs` modules (~17.9k lines) under `src/`; `test-suite shake-test`, 39 test modules |

## Overview

### What it solves

Shake makes one class of build problem expressible: a rule that cannot know its
dependencies until it has produced something — the generated header, parser or `.c`
file. `docs/Why.md` states the bet:

> "Shake build systems can discover additional dependencies after running previous
> rules, allowing the build system to generate files and then examine them to
> determine their dependencies, rather than predict the dependencies in advance."
>
> — [`docs/Why.md`][why]

Everything else follows: a rule runs before its dependency list is complete, so the engine
must _suspend_ it, and the discovered list must be recorded for the next run — the
suspending-scheduler × verifying-trace pair.

### Design philosophy

**Rules are values, keys are typed.** The core is not file-based: a rule is registered
for a `key` type with `type instance RuleResult key = value`, and the file layer is a
builtin rule over `FileQ` — file paths, oracle questions and user keys are peers in one
interned key→id table.

**Work is a continuation, not a thread.** `docs/Architecture.md` describes the model:
every `Action` is either blocked waiting on a `Running` key or queued in a thread pool
that "runs them in a given priority order, respecting parallelism constraints"
([`docs/Architecture.md`][arch]).

## How it works

### Rules and the file layer

```haskell
"_build//*.o" %> \out -> do
    let c = dropDirectory1 $ out -<.> "c"
    let m = out -<.> "m"
    cmd_ "gcc -c" [c] "-o" [out] "-MMD -MF" [m]
    neededMakefileDependencies m
```

The operators layer over one `addBuiltinRule`/`addUserRule` mechanism: `%>` (pattern),
`?>` (predicate), `&%>` (multiple outputs, all built if any is needed), `~>` (forward),
`phony` (an action with no file value, re-run whenever demanded and never twice in a build
— [concepts]'s degenerate trace). A file's value is `(mtime, size, digest)`; `FileHash` is
a salted `hashable` fold packed into a 32-bit `Word32` ([`FileInfo.hs`][fileinfo]), a change
detector rather than a content address.

### `Action` and the scheduler

`Action` is a state-and-continuation monad over `IO`; suspension rests on the internal
`captureRAW`, whose invariant — every continuation passed to it is called exactly once —
is, per `docs/Architecture.md`, "(sadly!) not tracked by the type system". A key moves
`Missing → Running → Ready | Failed`, with `Loaded` for a disk value never demanded this
run; anyone demanding a `Running` key is appended to its callback. A blocked rule hands its
continuation to the pool rather than sleeping, so a suspended key holds no thread
([`Core/Build.hs`][build]).

Parallelism is per call site: `need [a,b]` builds both concurrently, and since 0.18 so
does `need [a] >> need [b]` (the bind is applicative-like, [`Core/Types.hs`][types]).
The pool queues actions, not threads, and `shakeThreads` defaults to **1** — a script must
pass `-j` for any parallelism. `newResource`/`withResource` caps a _class_ of work below
that (8 compilers, 4 linkers), while `priority`/`alternatives` only choose which user rule
matches.

### The database: an append-only chunk journal

State lives in `shakeFiles` (default `.shake`): `.shake.lock`, `.shake.database`,
`.shake.storage.log`. The format is deliberately not a database:

> "When Shake computes a new value for `k`, it appends it to the end of the file. When
> Shake starts, it loads the list, keeping only the last value for any given `k`, and
> producing a `Map k v`. On disk, each entry is prefixed by its size, so that if the file
> is truncated (e.g. machine shutdown), any trailing incomplete data can be discarded."
>
> — [`docs/Architecture.md`][arch]

[`Core/Storage.hs`][storage] adds what durability needs: a header
`SHAKE-DATABASE-14-<os>-<arch>-<shakeVersion>` whose mismatch prints "All rules will be
rebuilt"; a **witness table** mapping each key type to a `Ver` and binary codec, so a
removed or re-typed rule is reported instead of mis-decoded; **compaction** when live
entries fall below half the chunks; recovery that renames a corrupt file and starts empty;
and a write-behind buffer flushed every `shakeFlush` seconds (default 10), so "on abnormal
termination … any rules that completed in the last `shakeFlush` seconds will be lost"
([`Options.hs`][options]).

### The step machine

Each `Result` records `result`, `built`, `changed`, `depends`, `execution` and `traces`;
`built` and `changed` are `Step`s, a per-run counter, so the rebuild test is one
comparison per dependency with no dependency hashes anywhere ([`Core/Build.hs`][build]):

```haskell
test (Right dep) | changed dep <= built me = Nothing
test _ = Just ()
```

That is exactly [concepts]'s **verifying step trace**: `O(n)` in dependencies, and it
answers "did anything I used change since I last ran?" without reading another key's
content. The `changed` field is where early cutoff lives: a rule that re-runs and
produces an equal value reports `ChangedRecomputeSame` and keeps its old `changed` step,
so `built` advances, `changed` does not, and dependents stay clean
([`Rules/File.hs`][file], `answer`).

### Oracles and the cloud cache

`addOracle` registers a rule keyed by a newtype question type, so a script can depend on
the GHC version or a git revision without a stamp file. Its action "will be run in every
build they are required, even if nothing else changes … If the result of an oracle does
not change it will not invalidate any rules depending on it" ([`Rules/Oracle.hs`][oracle]).

`--share=DIR` adds a second store: `.shake.cache/<hex>` per key, content files named by
identity hash, and a `_key/` subdirectory of entry blobs written atomically
([`History/Shared.hs`][shared]). An entry holds the key, three versions,
`[[(Key, BS_Identity)]]` dependencies, the result and its produced files. A lookup
matches the versions, walks the dependency list asking the live database for each
identity, bails on the first mismatch, and otherwise copies the entry's files back and
returns the stored result — a **constructive trace** used as a cache, i.e. `Cloud
Shake`. The HTTP half is unfinished; `docs/Cloud.md` records why the shared drive won:

> "That was the plan, but then Simon Peyton Jones suggested that actually the shared
> drive approach is sufficient. You can map a drive over the internet, use NFS, rsync,
> you can control permissions, you can explore it with the file system."
>
> — [`docs/Cloud.md`][cloud]

## Analysis spine

### Placement in the scheduler × rebuilder grid

**Suspending × verifying step traces — the `Shake` cell of [concepts]'s Table 2.** Rules
block on `Later`/`continue` instead of being re-run (suspending, JFP §4.3), and validity is
`changed <= built` over a recorded dependency list with no dependency-content hashes (step
traces, JFP §5.2.2). With `--share` the engine _also_ consults a constructive trace as a
slow path, keeping step traces as the fast one (JFP §7.3): it does not replace the local
rebuilder.

The cache key carries **three** versions — global (`hash(shakeVersion)`), builtin and user —
where the paper names two; the extra covers Shake itself changing under an unchanged script.

### 1. Task model & scheduling

The task description is a Haskell program: monadic, so the graph is decided at run time
(JFP §3.5), expressed through `need`, `apply`, `getDirectoryFiles`, `getEnv` and oracles;
`want` names the roots. Scheduling is suspending in the strict sense — a blocked key holds
no thread — so nothing runs twice for ordering reasons, which is what buys minimality.
Policy is thin: `-j` bounds concurrent rules but not resources, `newResource` adds named
semaphores, and errors fail fast with the call stack (`addStack`) attached.

### 2. Rebuilding & correctness

Correctness rests on the recorded dependency list being complete, and Shake never lets a
rule declare that list statically — it is whatever the tracked primitives actually
demanded last execution. Rebuild iff some dependency's `changed` exceeds my `built`, and
advance `changed` only when the value differs: **minimality** and **early cutoff**
together, at the price of the known step-trace artefact — change a dependency away and
back between builds and Shake rebuilds where a verifying trace would hash and skip.

Overrides are per-pattern ([`docs/Rebuilds.md`][rebuilds]): `RebuildNow`
(`--rebuild=PAT`), `RebuildLater` (`--skip=PAT`), `RebuildNormal` (`--no-rebuild`).
`alwaysRerun` makes a rule run whenever demanded, and the manual's compiler-version
recipe pairs it with `writeFileChanged` so an unchanged answer does not propagate. What
equality means is `shakeChange`: `ChangeModtime` (default — "very fast, `touch` causes
files to rebuild"), `ChangeDigest`, `ChangeModtimeAndDigest`, or
`ChangeModtimeAndDigestInput`, with mtime short-circuiting the hash. No proof substitutes
for this; [`src/Test/Random.hs`][random] generates a random rule graph (inputs, multi-input
rules, random sleeps, several `want` sets), runs it, and checks sufficient rebuilding and
agreement with a reference computation.

### 3. Dependency discovery

Discovery is **declared by execution**. `need` records a file edge; `getDirectoryFiles`
records the _listing_ (the manual restricts it to source directories, since the answer
could otherwise change mid-build); `getEnv` records a variable's value;
`neededMakefileDependencies` parses a `gcc -MMD` depfile produced _by the rule just run_
and demands its contents — the canonical generated-header fix; `&%>`/`produces` declare
extra outputs.

Nothing is traced by default. Tracing exists only as lint: `--lint-fsatrace=DIR` wraps
commands in `fsatrace` and turns observed reads/writes into `trackRead`/`trackWrite`, while
`AutoDeps` turns observed reads into real `need`s (excluding anything the command also
wrote). Both need `fsatrace` on `$PATH` and a `shakeLintInside` allowlist, and `AutoDeps`
cannot combine with asynchronous execution ([`Command.hs`][command]). The wrapper costs
what [perfect-dependencies] measured: Shake `cmd` 10.58 s → +`fsatrace` 12.66 s on Windows
(+21%), 1.17 s → 1.23 s on Linux (+5%). Without it an undeclared read is invisible until
lint notices it changed something.

### 4. Store & caching

The primary store is the **in-place filesystem** plus the metadata journal. No CAS: outputs
are ordinary files at ordinary paths, and the only content-derived value is the per-file
digest used for equality. A dependency's identity is its result's `builtinIdentity` — for
files `(size, digest)`; `noIdentity` disables sharing downstream, and an identity "should
return only one member from each equivalence class, as values will be compared for literal
equality."

Maintenance is manual: `--share-list`, `--share-remove=SUBSTRING`, `--share-sanity`
(re-hash content files against their names), and `historyDisable` for rules that mutate
pre-existing files. There is no eviction, no size accounting and no collection of
unreachable entries: a shared directory grows until someone deletes it.

### 5. Hermeticity & provenance

No sandbox: commands inherit the environment and working directory, and nothing stops a
rule reading or writing anything. Shake has an _invariant checker_ instead
([`docs/Lint.md`][lint]):

> "You can only read a file that is either your dependency, or a transitive dependency.
> … You can only write a file that you are declared to write, or that no one calls `need` on."
>
> — [`docs/Lint.md`][lint]

`LintBasic` also forbids changing the current directory (rules share it, concurrently) and
re-checks outputs after they are built — catching a second rule writing the same file, and
filesystems whose mtime resolution shifts mid-build. Under lint, `needed` becomes an
assertion: it must _not_ cause a rebuild, because its caller already consumed the contents.
Nothing in the tree touches SLSA, in-toto or signing — a cache hit is trusted because three
versions match. Environment dependence is tracked only where the script asks (`getEnv`,
`shakeVersion`).

### 6. Distribution

No remote execution: no REAPI client, no worker protocol, no cross-machine scheduling, no
shallow builds — a hit materialises the entry's files locally before the rule counts as
done. What exists is distribution of _results_: the shared directory, plus an unfinished
HTTP server that `docs/Cloud.md` says "hasn't been finished, so doesn't work at all" — its
`--cloud` flag is commented out in [`Args.hs`][args]. The one implemented boundary is Ninja ingestion:
`shake` reads `build.ninja`, including `deps`, `pool` and `restat`, but does not rebuild
when a command line changes ([`docs/Ninja.md`][ninja]) — the same gap Shake's own rules
have.

### 7. Sparkles relevance

`sparkles:build_primitives.task` builds a fully declared DAG in one pass, so
discovery-by-execution is not what to borrow. The cheap parts are:

- **Two timestamps per node.** `built` plus `changed`, with `changed dep <= built me` as the
  whole test: early cutoff for one integer per node and no hashing — the smallest correct
  incremental protocol in this survey.
- **An append-only, length-prefixed journal with truncation tolerance and compaction.** A
  task runner is killed by Ctrl-C, CI timeouts and OOM; "discard the trailing partial
  record, compact when half the chunks are live" is a full durability story.
- **A witness table keyed by node type + version**, turning a task-schema change into
  clean invalidation rather than a decode failure, and **recorded `execution` per node**
  for ETA and profiling from data already written. **Oracles** extend the same idea to a
  computed value (toolchain version, git SHA, env var): re-run every build, propagate only
  on change — directly applicable to `dub`-driven builds.
- **Lint as debug-build assertions** — `trackRead`/`trackWrite` and the `needed`
  invariant — instead of production syscall tracing.

Avoid: a 32-bit digest as a shared-cache identity; untracked rule/command changes, which
`docs/Manual.md` mitigates only socially; and a cloud cache before outputs are declared.

## Strengths

- **The cleanest suspension implementation here.** Continuations plus a priority pool mean
  a blocked rule costs no thread and duplicate work is structurally impossible — the property
  that makes minimality reachable with dynamic dependencies.
- **A tiny, durable, inspectable trace.** Two steps, a dependency list, one digest per
  file; it survives truncation, self-heals from corruption, compacts itself, and
  invalidates wholesale when the rule schema changes.
- **Early cutoff that works on generated files**, the case that motivated the system: a
  regenerated-but-identical file stops the cascade. Oracles, multiple outputs, resources,
  phony/forward rules, lint, profiling and Ninja ingestion are likewise library features, so
  a build system can be refactored like code rather than configured.

## Weaknesses

- **No sandbox, no observed-input validation, no provenance.** Completeness is the author's
  job; lint finds some lies and `fsatrace` finds more at 5–21% cost, but an undeclared input
  is caught only when it happens to hurt. There is also no eviction, no size accounting and
  no shallow builds, and Haskell as the configuration language means the error surface is a
  compiler's — `docs/Why.md` concedes Shake "is not likely to be installed by default".

## Key design decisions and trade-offs

| Decision                    | Rationale                                         | Trade-off                                                   |
| --------------------------- | ------------------------------------------------- | ----------------------------------------------------------- |
| Suspension on continuations | Dynamic deps without re-execution, no thread tied | Exactly-once invariant unchecked; a lost continuation hangs |
| Two step timestamps         | `O(1)` state, no content reads when current       | A→B→A rebuilds; no cross-machine key without the cache      |
| Append-only journal         | Crash tolerance, inspectable, fast bulk load      | Whole-file load; a 10 s flush window loses completions      |
| Filesystem as the store     | Outputs where tools expect them                   | No CAS, dedup or shallow builds; a hit copies files         |
| Three-version cache key     | Cheap staleness detection, no sandbox needed      | Undeclared I/O surfaces only via lint or a broken hit       |

## Sources

- [`ndmitchell/shake`][repo] at `526051c894aa88addb845e3e6b52b02a69becf8a` (clone at
  `$REPOS/build-systems-research/src/shake`, clean worktree); quotes are verbatim at that SHA.
- Docs and engine: [`Architecture.md`][arch], [`Why.md`][why], [`Manual.md`][manual],
  [`Rebuilds.md`][rebuilds], [`Lint.md`][lint], [`Cloud.md`][cloud], [`Ninja.md`][ninja]; and
  [`Core/Types.hs`][types], [`Core/Build.hs`][build], [`Core/Storage.hs`][storage],
  [`Core/Pool.hs`][pool], [`Rules/File.hs`][file], [`Rules/Oracle.hs`][oracle],
  [`Command.hs`][command], [`Options.hs`][options], [`FileInfo.hs`][fileinfo],
  [`History/Shared.hs`][shared].
- Packaging, tests and provenance of this page: [`shake.cabal`][cabal], [`CHANGES.txt`][changes],
  [`LICENSE`][license], [`src/Test/Random.hs`][random].
- Sibling pages: [concepts] for the scheduler × rebuilder vocabulary and Table 2 (this page
  does not redefine _suspending_, _verifying step traces_, _minimality_ or _early cutoff_);
  [a-la-carte] for Shake and Cloud Shake in the paper; [perfect-dependencies] for the
  measured `fsatrace` overhead; [buildxl] for the opposite stance on sandboxing.

<!-- References -->

[repo]: https://github.com/ndmitchell/shake
[arch]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/docs/Architecture.md
[why]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/docs/Why.md
[manual]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/docs/Manual.md
[rebuilds]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/docs/Rebuilds.md
[lint]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/docs/Lint.md
[cloud]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/docs/Cloud.md
[ninja]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/docs/Ninja.md
[types]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Internal/Core/Types.hs
[build]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Internal/Core/Build.hs
[storage]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Internal/Core/Storage.hs
[pool]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Internal/Core/Pool.hs
[file]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Internal/Rules/File.hs
[oracle]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Internal/Rules/Oracle.hs
[command]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Command.hs
[options]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Internal/Options.hs
[fileinfo]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Internal/FileInfo.hs
[shared]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Internal/History/Shared.hs
[args]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Development/Shake/Internal/Args.hs
[cabal]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/shake.cabal
[changes]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/CHANGES.txt
[license]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/LICENSE
[random]: https://github.com/ndmitchell/shake/blob/526051c894aa88addb845e3e6b52b02a69becf8a/src/Test/Random.hs
[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[perfect-dependencies]: ./perfect-dependencies.md
[buildxl]: ./buildxl.md
