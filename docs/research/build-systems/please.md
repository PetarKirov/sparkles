# Please (Go)

Please's engine in one sentence: a goroutine per target blocked on its declared
dependencies, a rebuild record kept in extended attributes on the outputs
themselves, and a cache keyed by a folded hash of rule, config and sources — with
REAPI as the only way work leaves the machine. Engine companion to the workspace
survey, scoped to `src/`.

**Last reviewed:** November 2, 2026

| Field            | Value                                                                                                |
| ---------------- | ---------------------------------------------------------------------------------------------------- |
| Language         | `Go` (engine, ~54.5k lines in 251 files under `src/`); restricted `Python` dialect for `BUILD` files |
| License          | Apache-2.0                                                                                           |
| Repository       | [thought-machine/please][repo]                                                                       |
| Documentation    | [please.build][docs]; [`docs/cache.html`][cache-doc], [`docs/remote_builds.html`][remote-doc]        |
| Category         | Industry — polyglot orchestrator; engine companion to [please (monorepo-tooling)][mono-please]       |
| Clone (pinned)   | `$REPOS/build-systems-research/src/please`                                                           |
| Commit           | `d7bea3388e4ddd311891d8ccccd2c53caae724cd` (2026-10-31)                                              |
| Tree version     | `VERSION` is `17.35.0-beta.1`; tag `v17.35.0-beta.1`; depth-1 clone, so no history                   |
| Sandbox / remote | Linux mount/user/PID/net namespaces; REAPI v2 client accepting `2.1`–`2.12`, no-op sandbox elsewhere |

## Overview

### What it solves

Reuse across checkouts: `plz` must answer "is this target current?" after a branch
swap makes every file look new, without trusting mtimes. It hashes everything that
produced a target onto the target's outputs and re-derives it next run; if the
comparison fails, a cache — directory, HTTP, command or REAPI — supplies bytes
instead of a rebuild. From the README's "How is it so fast?" section
([`README.md`][readme]):

> "Caching is based on the hashes of inputs (both files, and environment variables)
> to each rule rather than last modified timestamps. Builds are hermetic so don't
> have access to anything they haven't explicitly defined as inputs."

### Design philosophy

**The file tree is the database.** No graph file, cache database or daemon:
`plz-out` holds outputs, their xattrs hold the rule/config/source/secret hashes, and
a `.target_build_metadata_<name>` gob holds stdio and post-build additions, so
deleting `plz-out` is always safe. The package comment in
[`incrementality.go`][incrementality] states the input model:

> "There are four things we consider for each rule:
>
> - the global config, some parts of which affect all rules
> - the rule definition itself (the command to run, etc)
> - any input files it might have
> - any dependencies.
>
> If all of those are the same as the last time the rule was run, we can safely
> assume that the output will be the same this time and so we don't have to re-run
> it again."

Hermeticity is a contract, not a mechanism: declared inputs are hardlinked into a
temp directory, and the optional sandbox adds a private `/tmp` and read-only root.
Nothing observes reads, so the hash is only as good as the `BUILD` file.

> [!NOTE]
> **Delta against the workspace page.** [please (monorepo-tooling)][mono-please]
> covers `.plzconfig` layering, labels, `subinclude`, plugins, the five workspace
> dimensions, `plz query changes` and the CLI; this page goes one level down.

## How it works

### No queue: a join per target

`runner.Build` parses the label, claims it in `buildOnce`, then `buildOne` →
`buildTargetAndDeps` opens an `errgroup`, spawns a goroutine per declared dependency
and per target-naming source, and blocks in `g.Wait()` ([`plz.go`][plz]). Only then
does `runBuildAction` take a slot from `localLimiter` or `remoteLimiter` and call
`build.Build`. Readiness is the join — no ready queue, no topological order — and
`buildOnce` makes it at-most-once; a cycle is a deadlock, so `checkForCycles` waits
five seconds for inactivity, then runs a label DFS ([`cycle_detector.go`][cycles]).

### The record lives on the output

`needsBuilding` checks, in order, the metadata file, config hash, rule hash, source
hash, secret hash, missing outputs, then `--rebuild`
([`incrementality.go`][incrementality]). The record is five SHA-1 sections in
`user.plz_build` on each output — rule pre-build, rule post-build, config, source,
secret; a target with no outputs falls back to a file named after itself
([`build_target.go`][target]). The two rule hashes are phases: a post-build function
that can change the target is run, then re-checked with `postBuild: true` against the
second section.

`targetHash` is `RuleHash(pre) ‖ RuleHash(post) ‖ config ‖ sourceHash`, where
`RuleHash` serialises declared fields in sorted order — label, deps, sources,
outputs, command, `requires`/`provides`, `PassEnv` **values**, env, content — guarded
by a test: "incrementality_test will warn if new fields are added to the struct but
not here." `config.Hash()` covers only `Build.Lang`, `Build.Nonce` (default `1402`),
rejected licences and non-`SECRET` env ([`config.go`][config]); `PathHasher` uses
SHA-256 by default while the accumulators stay SHA-1. `plz hash --detailed` prints
every part ([`please.go`][hash-cmd]).

### Cache: target key in, tree out

`CollapseHash` XORs the four 20-byte sections to 20 bytes
([`core/utils.go`][collapse]); entries are
`<cache-dir>/<package>/<name>/<base64url(key)>` with a `.lock`
([`dir_cache.go`][dir-cache]). One interface covers directory, HTTP blobs, command
and no-op ([`cache.go`][cache]); retrieval promotes hits upward and stores fan out on
`[cache]` workers ([`async_cache.go`][async-cache]). Entries hardlink to and from
`plz-out` ([`copy.go`][copy]), so eviction counts only unshared bytes and cleans by
LRU to watermarks, age and free-space floors.

Two-phase lookup exists for post-build functions: metadata under the old key, then
outputs under the new key after mutation ([`build_step.go`][build-step]). Early
cutoff lives here too: `moveOutput` hashes the new file against the old, reports
`Unchanged` without moving it, and dependents see identical source hashes.

### Sandbox: a write boundary, not an input boundary

On Linux, `plz sandbox` re-execs the action ([`sandbox_linux.go`][sandbox],
[`exec_linux.go`][exec-linux]): privatise `/`, mount a tmpfs on `/tmp`, bind the
target temp dir to `/tmp/plz_sandbox`, remount `/` read-only, mount `proc` and a
tmpfs over each `[sandbox] dir`, rewrite the temp path in the environment, and
`exec`; non-Linux is a plain `exec.Command` ([`sandbox_other.go`][sandbox-other]).

This is narrower than the README's phrasing. Inputs are **hardlinks**, so a rule
that writes an input edits the source tree unless the read-only root stops it — and
the sandbox is off by default. Paths outside the repo stay readable; only
`[sandbox] dir` entries are hidden. No read is recorded, so an undeclared input
leaves no evidence.

### REAPI: one action at a time

The action is a `Command` plus an `InputRoot` directory proto, uploaded to the CAS,
submitted, and monitored through `ExecuteAndWaitProgress` ([`remote.go`][remote],
[`action.go`][action]). Please checks local metadata, then the remote action cache;
afterwards it downloads only what `ShouldDownload` selects — original targets,
`--download`/debug, or linkable targets ([`state.go`][state]). Remote outputs are
also an `io/fs.FS` over the CAS, so subrepo trees parse without a full download:
"This will download files as they are needed from the CAS when they are opened"
([`remote/fs/fs.go`][cas-fs]). `remote_file` uses the Remote Asset API, filegroups
and text files get synthetic actions (a wart the package README admits), and
persistent workers are gone: `build()` returns "Persistent workers are no longer
supported" for a `$(worker)` command ([`build_step.go`][build-step]).

## Analysis spine

**Suspending × verifying traces — the `Shake` cell of [concepts], minus the dynamism
that motivates suspension.** Each target blocks on its dependencies and resumes,
which is JFP §4.3's mechanism, but the dependency list is declared, so there is no
late discovery to recover from. The rebuilder is a verifying trace (JFP §5.2): the
result hash sits on the output and the consumed values' hashes are re-derived. The
cache layer, though, is constructive — it supplies bytes a local store lacks — so
Please straddles two cells the paper keeps apart.

### 1. Task model & scheduling

Static: dependencies are labels in `BUILD` files, so the graph is a DAG. Scheduling is
demand-driven joins plus two semaphores; parallelism is per action with independent
local and remote pools, and tests follow their target. A post-build function that adds
outputs or dependencies makes `ModifiedByCallback` re-run the loops — bounded, not
general dynamism.

### 2. Rebuilding & correctness

Correctness is constructed from declarations: the trace records what the `BUILD` file
said. Comparison is hash equality, never mtime, so `touch` is inert and a branch swap
exact; early cutoff stops at the first byte-identical output. An undeclared read is
invisible, hence neither reported nor pruned — the gap [perfect-dependencies] measures
and [rattle] closes.

### 3. Dependency discovery

Declared, with `require`/`provide` expanding one label into several targets
([`plz.go`][plz]). No depfiles, no syscall or FUSE tracing: `plz query whatinputs`
maps files to targets from declarations alone, and only outputs are discovered
mid-build.

### 4. Store & caching

The build store is `plz-out` (outputs plus xattrs); the cache store is target-keyed
trees — directory entries, HTTP blobs, command invocations, REAPI action cache/CAS.
Only the remote layer is content-addressed; the local cache maps a hash to a file
list, so a hit is a verified tree, and hardlink-aware LRU lets checkout and cache
share inodes.

### 5. Hermeticity & provenance

Layered and opt-in: hardlinked inputs, a sandbox off by default, `PassEnv` hashed and
`PassUnsafeEnv` not. Provenance is **absent** — a tree-wide grep for `attestation`,
`SLSA`, `in-toto` and `provenance` finds nothing; `src/audit` logs locally and an
`ActionResult` carries digests, neither a signed claim.

### 6. Distribution

A REAPI v2 client and nothing else; no proprietary protocol and no server-side graph
scheduling, so placement, queueing and affinity belong to the backend. The window is
in code: 2.1 is the floor (`Command.output_paths`), 2.12 the ceiling for a client
using only SHA-1/SHA-256 ([`remote.go`][remote]).

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a static, in-process DAG with no persistent store,
so the borrowings are structural. Worth taking: the **four-part hash split** (config,
rule, sources, secrets), which turns "why rebuild?" into a diagnosis; the **per-output
record** with a non-xattr fallback, so a short-lived CLI can trust a tree it did not
build; **byte-level early cutoff** with `Unchanged` as an outcome; and **separate local
and remote budgets**. Worth avoiding: goroutine-per-target (cheap in Go, expensive in
D — use a ready queue keyed on in-degree); and a write-only sandbox is not an input
oracle, so [rattle]-style validation still needs read observation. Carry over the
measurement too: a one-shot `dub` run re-hashes every source unless a persistent hash
cache exists.

## Strengths

- **A rebuild record that travels with the artifacts.** No side database to corrupt
  or migrate; hashes, stdout and post-build outputs live beside the outputs.
- **Cheap sandbox.** A handful of namespace calls and one bind mount instead of a
  mount farm or `ptrace`.
- **Interoperable, observable execution.** A conforming REAPI client, asynchronous
  caches with layer promotion, and distinct `Unchanged`/`Built`/`Cached (unchanged)`
  states.

## Weaknesses

- **The sandbox does not see reads.** "No access to anything they haven't explicitly
  defined" is an aspiration: `/` is read-only, not filtered.
- **Hardlinked inputs are a foot-gun.** Without the sandbox, writing an input edits
  the source tree in place; with it, the write fails only via the read-only mount.
- **Cycles are diagnosed, not prevented.** Five seconds of inactivity must pass
  before the DFS runs, so a slow parse delays the report.
- **The cache key is an XOR fold.** Four 20-byte digests become one, order-insensitive
  across sections by construction — compact, with a weaker collision margin.
- **xattr fidelity is backend-dependent.** HTTP retrieval loses xattrs and they are
  rewritten only for the HTTP cache; `fs/hash.go` carries a matching TODO.

## Key design decisions and trade-offs

| Decision                                | Rationale                                                  | Trade-off                                                           |
| --------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------- |
| Goroutine per target, blocked on deps   | Readiness for free; no scheduler state machine             | Deadlock-as-cycle; a watchdog and label DFS replace static checks   |
| Rebuild record in xattrs on outputs     | No database; survives branch swaps; `plz clean` is safe    | xattrs can be lost by copies/caches; outputs must exist to be clean |
| Four separate hashes                    | Precise diagnosis of _what_ changed; `plz hash --detailed` | Four re-derivations per target per invocation                       |
| XOR-folded 20-byte cache key            | Short keys, cheap comparison, one digest to thread through | Loses section identity; weaker collision margin than the tuple      |
| Metadata-first two-phase cache lookup   | Post-build functions can mutate a target after it is built | Second lookup and dual-key store; ordering is delicate              |
| Read-only root + private `/tmp` sandbox | Near-zero setup; no `ptrace` or seccomp machinery          | Undeclared reads allowed; isolation is write-only                   |
| Hash sources every build, memoised once | Correctness without trusting mtimes                        | A one-shot CLI pays full rehash cost; only a daemon amortises it    |

## Sources

- [`thought-machine/please`][repo] at commit
  `d7bea3388e4ddd311891d8ccccd2c53caae724cd` (clone at
  `$REPOS/build-systems-research/src/please`; HEAD dated 2026-10-31). Quotes are
  verbatim from the files cited inline; the depth-1 clone has no history to assess.
- Engine, config and storage: [`build_step.go`][build-step],
  [`incrementality.go`][incrementality], [`plz.go`][plz],
  [`cycle_detector.go`][cycles], [`core/utils.go`][collapse], [`config.go`][config],
  [`state.go`][state], [`build_target.go`][target], [`hash.go`][hash],
  [`copy.go`][copy], [`cache.go`][cache], [`dir_cache.go`][dir-cache],
  [`async_cache.go`][async-cache].
- Isolation and distribution: [`sandbox_linux.go`][sandbox],
  [`sandbox_other.go`][sandbox-other], [`exec_linux.go`][exec-linux],
  [`remote.go`][remote], [`action.go`][action], [`remote/fs/fs.go`][cas-fs],
  [`src/remote/README.md`][remote-readme].
- Docs and CLI: [`docs/cache.html`][cache-doc], [`docs/remote_builds.html`][remote-doc],
  [`please.go`][hash-cmd]. Siblings: [concepts], [bazel], [buck2], [buildxl], [rattle],
  [buildkit], [mono-please].

<!-- References -->

[repo]: https://github.com/thought-machine/please
[docs]: https://please.build/
[readme]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/README.md
[build-step]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/build/build_step.go
[incrementality]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/build/incrementality.go
[plz]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/plz/plz.go
[cycles]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/plz/cycle_detector.go
[collapse]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/core/utils.go
[config]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/core/config.go
[state]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/core/state.go
[target]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/core/build_target.go
[hash]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/fs/hash.go
[copy]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/fs/copy.go
[cache]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/cache/cache.go
[dir-cache]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/cache/dir_cache.go
[async-cache]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/cache/async_cache.go
[sandbox]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/sandbox/sandbox_linux.go
[sandbox-other]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/sandbox/sandbox_other.go
[exec-linux]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/process/exec_linux.go
[remote]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/remote/remote.go
[action]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/remote/action.go
[cas-fs]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/remote/fs/fs.go
[remote-readme]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/remote/README.md
[cache-doc]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/docs/cache.html
[remote-doc]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/docs/remote_builds.html
[hash-cmd]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/src/please.go
[concepts]: ./concepts.md
[mono-please]: ../monorepo-tooling/please/
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[buildxl]: ./buildxl.md
[rattle]: ./rattle.md
[buildkit]: ./buildkit.md
[perfect-dependencies]: ./perfect-dependencies.md
