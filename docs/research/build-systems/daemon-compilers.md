# Daemon Compilers & Memory-Resident Build State (Theme)

A one-shot build system pays a process start per action and remembers nothing
between invocations. A daemon compiler inverts both: one process serves many
builds, and the compiler's caches outlive the input that produced them. This page
separates the two things that inversion buys — a warm process and a persistent
cache — and traces what each system remembers, who may invalidate it, and what
survives when the daemon dies.

**Last reviewed:** November 3, 2026

| Field      | Value                                                                                                              |
| ---------- | ------------------------------------------------------------------------------------------------------------------ |
| Category   | Theme — cross-cutting; no single system                                                                            |
| Question   | What does a compiler hold between builds, and how does that state stay correct across clients, edits and restarts? |
| Systems    | Bloop, TypeScript `tsserver` (5.9 and its native successor), `rustc`, Gradle, Kotlin, sbt/Zinc, Buck2              |
| Vocabulary | [concepts] — _scheduler_, _rebuilder_, _trace_ and _hermeticity_ are used as defined there, not redefined here     |

**Built from (in-corpus):** [concepts] (§2–§3, §6), [sbt] (Zinc's on-disk
`Analysis`), [bazel] (per-process `Skyframe` cache), [buck2] (daemon-scoped dep
files), [buildxl] (orchestrator versus worker), [moon] (daemon with in-process
fallback), [please] (persistent workers removed), [semantic-caching],
[dynamic-deps-distributed], [sandboxing-overheads].

## Overview

### What it solves

Two fixed costs and one variable one. Starting a compiler reloads its standard
library, re-runs optimiser warm-up and, on a JVM, re-JITs the code about to run;
Bloop puts the difference at "up to 20x faster than a short-lived compiler"
([`docs/what-is-bloop.md`][bloop-what]). The variable cost is reuse: a compiler
that keeps its dependency graph skips work the build system never modelled, down
to a query or a file signature. The two are independent — `rustc` has reuse
without warmth, reloading a cache from disk per invocation; Bloop has both; Gradle
keeps the _build engine_ resident and delegates compilation.

### Design philosophy

Once a compiler outlives its input, its memory becomes an input. Every system here
answers the same question — _what makes that input safe to trust?_ — by making the
state discardable, serialised, or generational:

> "because the compiler process exits after being finished and takes the query
> context with its result cache with it into oblivion, we have to persist data to
> disk, so the next compilation session can make use of it"
>
> — rustc-dev-guide [`incremental-compilation-in-detail.md`][rdg-incr-detail]

**Discardable** state is a pure cache: losing it costs time, never correctness.
**Serialised** state is written to disk with enough identity to be revalidated by
a later process. **Generational** state is frozen into an immutable snapshot that
readers lease, so a new generation cannot mutate what an old one reads. Rustc and
Bloop take the second, the native TypeScript server the third; only the first is
free.

## How it works

### 1. The compile server: Bloop

Bloop is a Scala build server: one long-lived JVM per user, reached over a Unix
socket in a per-user daemon directory; the server refuses to start if other users
can read that directory ([`docs/server.md`][bloop-server]). Its guarantees are
the point:

> "The server heavily caches compilations for the same inputs (aka _compile
> deduplication_)"
>
> "If inputs have changed between requests, Bloop will compile the changed
> projects concurrently, avoiding shared state and conflicts with ongoing
> compilations."
>
> — Bloop [`docs/what-is-bloop.md`][bloop-what]

Deduplication keys on **recorded compilation side effects**: a second identical
request is "deduplicated based on the compilation side effects recorded by the
build server". Isolation is spatial — every client gets its own classes directory,
and Bloop keeps a read-only internal copy under `<out>/bloop-internal-classes`.
The opt-in hard-link mode makes those copies aliases:

> "A linked file is shared, so a process that rewrites a class file in place
> inside a client directory Bloop owns also changes Bloop's internal copy, which
> later compilations and every other client use."
>
> — Bloop [`docs/server.md`][bloop-server]

The persistence layer is Zinc's: Bloop writes `<out>/<name>-analysis.bin` beside
the outputs. By default it holds **absolute paths**, so a workspace moved into a
container or CI checkout recompiles fully even with identical sources;
`-Dbloop.analysis.portable=true` rewrites it with `${BASE}`-style roots at the
cost of leaving out-of-root paths absolute ([`docs/server.md`][bloop-server]) —
[semantic-caching]'s "irrelevant differences kill sharing" below the build graph.

### 2. The language server: TypeScript

`tsserver` is the same shape with a different owner: an editor spawns the process
and speaks a JSON protocol over stdio ([`src/server/session.ts`][ts-session],
[`src/server/protocol.ts`][ts-protocol]). Its `ProjectService` keeps
`filenameToScriptInfo`, the "Container of all known scripts"
([`editorServices.ts`][ts-editorservices]) — every file the session has opened,
plus a project graph over every discovered `tsconfig.json`. That map is the
daemon's memory and its leak: the process lives as long as its client.

Incrementality inside it is a **signature** per file, held in
`BuilderState.fileInfos` as "its version, signature etc"
([`builderState.ts`][ts-builderstate]). The cheap path uses the file's version
string, which over-invalidates on any edit. The precise path hashes the emitted
`.d.ts` text instead ([`builder.ts`][ts-builder]): a body-only edit then changes
the version but not the signature, so dependents are not re-checked. Which path
runs is a compiler decision (`useFileVersionAsSignature`), not a per-request one
— the same over-approximate/under-approximate trade [semantic-caching] records.

The disk half is `.tsbuildinfo`; `--incremental` is documented as "Save
.tsbuildinfo files to allow for incremental compilation of projects"
([`commandLineParser.ts`][ts-cmdline]), and `SolutionBuilder` caches parsed build
info per config ([`tsbuildPublic.ts`][ts-tsbuild]). A plain `tsserver` session
writes no such file — the in-memory builder state is the whole cache — so a
restart costs a full re-parse and re-check (**catalog inference** from the absence
of a build-info write outside `--build`/`--incremental`).

The native (Go) rewrite changes the generation model, not the idea. Its `Session`
"provides programmatic access to TypeScript language services through the LSP
server", and the project layer "processes them into immutable snapshots as the
data source for LanguageServices", the field being "the current immutable state of
all projects" ([`session.go`][ts-go-session],
[`project/session.go`][ts-go-project]). Each snapshot carries its own symbol and
type registries, and readers hold one while the next is built; `.tsbuildinfo`
survives into the port ([`buildInfo.go`][ts-go-buildinfo]). **Catalog inference:**
freezing generations answers the mutable-`Program` problem — a request can no
longer observe a half-updated graph.

### 3. The query engine without a daemon: `rustc`

`rustc` is the counter-example that makes the taxonomy visible. It memoizes at
**query** granularity: `tcx.type_of(def_id)` either hits a hash table or calls a
provider, and the engine records at run time which queries each query read
([`src/query.md`][rdg-query]). Incremental compilation is that machinery across
processes, coloured red (result changed) or green (unchanged):

> "if all of the inputs to query Q are colored green, then the query Q **must**
> result in the same value as last time and hence need not be re-executed (or
> else the compiler is not deterministic)"
>
> — rustc-dev-guide [`incremental-compilation.md`][rdg-incr]

Because the process dies, three things persist per crate: the dependency graph,
the query-result cache and the work products. Persistence forces stable identity —
`DefPathHash` instead of `DefId`, because numeric ids shift when a file gains a
function — and 128-bit fingerprints for keys and results: "Due to these measures
the practical risk of a hash collision is negligible"
([`incremental-compilation-in-detail.md`][rdg-incr-detail]). The directory layout
_is_ the generation mechanism ([`persist/fs.rs`][rust-fs]):

```text
{incr-comp-dir}/{crate-name-and-disambiguator}/s-{timestamp}-{random}-working
```

A finished session is renamed `s-{timestamp}-{svh}`; the next invocation scans the
crate directory, locks the newest **finalised** session as its source and replays
try-mark-green against it. Three costs are documented rather than hidden: on-disk
structures are rewritten whole each session ("a few percent of total compilation
time"), results never loaded are preserved by a **cache-promotion** pass, and
`no_hash` queries force dependents to re-run. The walk order of a node's reads is
load-bearing — visiting them out of order "can lead to ICEs and other problems in
the compiler" ([`incremental-compilation.md`][rdg-incr]) — the price of replaying a
trace whose control flow may have changed.

So rustc's daemon is a directory, not a process: no socket, no shared heap, no way
for two builds of one crate to observe each other's half-written state. What it
gives up is what Bloop buys: no JIT warmth, a deserialisation cost per invocation,
and no compile deduplication. The flag is modest: incremental compilation "takes a
path to a directory where incremental files will be stored"
([`codegen-options/index.md`][rust-codegen]).

### 4. The general build daemon: Gradle and Kotlin

Gradle's daemon is the build engine, not the compiler: "a long-lived, persistent
process that runs in the background and hosts Gradle's execution engine"
([`gradle_daemon.adoc`][gradle-daemon]). The client/daemon split lets a build
script be evaluated once, with a warm classloader and a JIT that has already seen
it; the two talk over a local socket. Reuse is deliberately narrow — identity, not
compatibility:

> "Gradle reuses an existing daemon only if its Java home/version and JVM args
> (e.g., `org.gradle.jvmargs`, `GRADLE_OPTS`) are identical."
>
> — Gradle [`gradle_daemon.adoc`][gradle-daemon]

Changing `-Xmx` spawns a _new_ daemon rather than reusing a misconfigured one, and
the old one lingers until idle for three hours or until memory runs low. The same
document gives the universal first remedy for a daemon-shaped bug: "If builds
start behaving unexpectedly, try stopping and restarting the Daemon."

Kotlin adds a compiler-specific daemon and is the most explicit about isolation:

> "The Kotlin daemon is a separate process that has its own memory space,
> isolated from the client."
>
> — Kotlin [`kotlin-daemon.html`][kotlin-daemon-doc]

Lifetime is policy: an **attached** daemon shuts down shortly after its client, a
**detached** one waits for follow-up work. Defaults are two hours idle, one minute
unused and a one-second shutdown delay, both in the docs and as constants in
`DaemonParams.kt` (`7200 // 2 hours`, `60`, `1000L`)
([`DaemonParams.kt`][kotlin-params]). The protocol is session-based —
`leaseCompileSession` / `releaseCompileSession` ([`CompileService.kt`][kotlin-service]).
Kotlin/JVM incrementality itself "relies on classpath snapshots" and works with
Gradle's build cache ([kotlin-caches]). The build-tools API offers
`useInProcessStrategy()` or `useDaemonStrategy(jvmArguments)`, with **in-process as
the default** there ([`CompilerExecutionStrategyConfigurationImpl.kt`][kotlin-strategy]):
a daemon is an optimisation a build tool opts into, and the fallback is a normal
compiler run — [moon]'s "archive in-process instead of failing a task" is the same
instinct.

### 5. Persistent workers inside a batch engine

Bazel and BuildXL show a middle generation between one-shot actions and a
whole build daemon. Bazel persistent workers execute many actions in one
tool process; multiplex workers serve concurrent requests, with per-key
instance bounds in `WorkerPoolImpl` and worker creation keyed by executable,
arguments, environment, and execution properties ([bazel] “Persistent
workers”). BuildXL service pips keep an uploader or compiler service alive
while small IPC pips delegate operations to it, but explicitly trust the
service's file accesses and never cache the service itself
([buildxl] “Service pips”).

The important difference from Bloop/Gradle is lifetime scope. The resident
process is normally a child of one build/server generation and serves actions
in that build; it is not the build engine and does not decide what is dirty.
Its cache is therefore compiler-internal (loaded jars, JIT code, parsed
headers, authenticated sessions), while the outer action cache still has to
decide whether running the worker is necessary at all. A worker can make a
cache miss cheap; it cannot by itself produce a sound cache hit.

### What lives where

| System              | Resident (dies with the process)            | Persisted (survives a generation)                    | Invalidated by                                    |
| ------------------- | ------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------- |
| Bloop               | JIT, classloaders, Zinc in-memory analysis  | `<out>/<name>-analysis.bin`, class files             | source/classpath change; analysis paths; restart  |
| `tsserver` (5.9)    | `ProjectService`, `Program`, `BuilderState` | `.tsbuildinfo` only under `--incremental`/`--build`  | file version or `.d.ts` signature change          |
| `tsserver` (native) | snapshot host, per-snapshot registries      | `.tsbuildinfo`                                       | snapshot diff; build-info comparison              |
| `rustc`             | nothing — the process exits                 | dep-graph, query cache, work products in `s-…-{svh}` | query fingerprint (128-bit)                       |
| Gradle              | classloader cache, configuration model, VFS | build cache, configuration cache, file-watch state   | JVM-arg identity; task inputs; 3 h idle           |
| Kotlin              | compiler caches in the daemon heap          | Gradle build cache plus incremental caches on disk   | session end; 2 h idle; JVM-arg inheritance        |
| Bazel workers       | tool heap/JIT, parsed inputs per worker key | action outputs + Bazel caches outside the worker     | worker-key change, pool bound, server shutdown    |
| BuildXL services    | service session/auth/batching state         | IPC pip outputs in the ordinary graph/cache          | build end, service death, every worker starts one |

One level up, Bazel's constructive trace lives in memory per server process and
Buck2's dep-file cache is explicitly daemon-scoped, dropped on restart
([bazel], [buck2]) — the same generation problem at engine scale.

## Isolation and memory safety

**Process boundary.** Kotlin's daemon is a separate process "isolated from the
client"; Bloop gives every user their own server and refuses a world-readable
daemon directory; Gradle spawns a second daemon rather than reuse one with
different JVM arguments. At the far end `rustc` shares nothing — the session
directory is the only channel, and it is locked. The boundary is cheapest to
reason about when the daemon owns no writable state another build can reach.

**Shared filesystem** is where guarantees get thin. Bloop's hard-link mode is an
explicit aliasing contract: a client that rewrites a class file in place corrupts
the server's copy for every later client ([`docs/server.md`][bloop-server]). Its
default copy mode avoids that at the cost of I/O, and per-client output
directories stop two clients fighting over one target.

**Resident untrusted code.** Gradle's daemon is responsible for "executing build
scripts" ([`gradle_daemon.adoc`][gradle-daemon]); a build script is arbitrary
code, and in a daemon it runs in a process that outlives the invocation and holds
other projects' caches. **Catalog inference:** that is a weaker boundary than
process-per-build for untrusted inputs, and why CI generally runs one build per
container even when developers run a daemon.

**Memory.** A daemon trades address-space hygiene for retention: long-lived
TypeScript sessions retain every script they opened, and the native port's
immutable snapshots bound _mutation_, not _retention_ (**catalog inference**). A
JVM or Go daemon is at least memory-safe, so a bug yields wrong answers or an OOM
rather than corruption; a native compiler daemon would have to earn that property.
Rustc sidesteps the question by dying, which is also why its on-disk format has to
carry explicit stable-identity machinery (`DefPathHash`, fingerprints).

> [!WARNING]
> A resident compiler is an **undeclared input** to every action it serves. If the
> build graph's key says `compile(sources) → classes` while the daemon also reads
> yesterday's analysis, the key is a lie unless the daemon's state is discardable
> or folded into the key. Gradle's JVM-argument identity and rustc's fingerprint
> check are two ways to make that true; "we restarted the server" is not.

#### A daemon lifecycle checklist

The surveyed systems converge on five controls, whether or not they name them:

1. **Identity before reuse** — executable/version, JVM or runtime flags,
   environment, working directory, and configuration must select a new
   process or generation when they differ (Gradle and Bazel worker keys).
2. **Request isolation** — state retained between requests must be a pure
   cache keyed by declared inputs; mutable "current project" state needs a
   generation/snapshot boundary.
3. **Bounded retention** — idle timeout alone is not a memory policy; there
   needs to be a heap/artifact budget, eviction, and a stop path.
4. **Failure containment** — a crashed or wedged daemon must degrade to a
   cold process or a clear build failure, never silently serve the previous
   request's answer. Kotlin's daemon fallback strategy is the explicit
   version of this choice.
5. **Cold-path equivalence** — deleting daemon state may be slower but must
   produce the same outputs. If it does not, the resident state is an
   undeclared input and belongs in the cache key.

## Analysis spine

These systems are **rebuilders inside a task**, not schedulers. [concepts] §5
classifies a build system by (scheduler, rebuilder) over keys that are usually
files; a daemon compiler pushes a second rebuilder _below_ that granularity —
query-level in `rustc`, file-signature-level in TypeScript, name-hash-level in
Zinc ([semantic-caching]). The outer DAG still sees one opaque action:

- **Early cutoff does not propagate for free.** A daemon that decides "nothing
  changed" and exits without touching its outputs looks, to the DAG, exactly like
  a task that did work. Bloop's per-client class directories and rustc's
  work-product index are how a cache hit still leaves the artifacts the next task
  consumes.
- **The daemon's trace is not the DAG's trace.** Zinc's `Analysis`, the rustc
  dep-graph and `.tsbuildinfo` are traces at a finer grain; the task graph keeps a
  coarser one. The coarser one wins for scheduling — safe only because the finer
  one lives _inside_ the action's meaning.
- **A daemon is orthogonal to distribution.** None of these ships remote
  compilation: Bloop says "There is currently no support for remote compilation",
  Gradle distributes through a build cache rather than a worker fleet, and rustc's
  cache is local-disk by construction. Daemon compilers optimise the _fixed_ cost
  of a local action; [dynamic-deps-distributed] optimises where it runs.

## Strengths

- **Fixed costs collapse.** Keeping the runtime, JIT, and parsed headers warm
  amortises process startup across actions.
- **Sub-file reuse becomes possible.** A query cache or a `.d.ts` signature skips
  work no file-granularity DAG could name.
- **Removing the daemon is a legitimate design point.** Please deleted persistent
  workers outright — `build()` returns "Persistent workers are no longer
  supported" for a `$(worker)` command ([please]).

## Weaknesses

- **Cache identity is the hard part.** Every system here spends its design
  budget on identity — JVM args, fingerprints, session directories — not on
  compiling.
- **Failure modes are qualitative.** A stale daemon produces a green build with
  yesterday's class files; a crashed daemon produces a slow one.

## Key design decisions and trade-offs

| Decision                                       | Rationale                                                    | Trade-off                                                                 |
| ---------------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Keep the compiler resident (Bloop, Kotlin)     | Amortise JVM start-up, class loading and JIT warm-up         | A lifecycle, a socket, a permission boundary and a stale-state bug class  |
| Deduplicate on recorded side effects (Bloop)   | Concurrent clients asking for the same inputs do one compile | Correct only if the side-effect model is complete; plugins can escape it  |
| Give each client its own output directory      | Two clients cannot corrupt each other's classes              | Copies or hard links; link mode makes sharing explicit and dangerous      |
| Persist analysis next to outputs (Bloop, Zinc) | Warm starts without a live process                           | Absolute paths make the analysis non-portable unless opted in             |
| Persist a query cache with stable ids (rustc)  | Cross-process incrementality without a daemon                | Rewrite cost each session; deserialisation; fingerprints must stay stable |
| Freeze state into snapshots (TS native)        | A request never observes a half-updated project graph        | Retention still unbounded; a second representation of "current"           |
| Reuse a daemon only on identical JVM args      | Removes "wrong heap, wrong classpath" bugs                   | Changing memory spawns a cold daemon                                      |

## Sparkles relevance

`sparkles.build_primitives.task` is a validated static DAG executed by one owner
fiber in-process: `TaskId` is stable text, `toHash` hashes that text, and the spec
puts "persistent scheduler state" out of scope
(`libs/build-primitives/src/sparkles/build_primitives/task/model.d`,
`docs/specs/build-primitives/task-dag/SPEC.md`). With no daemon
and no store, the transferable lessons are about ordering the work:

- **Prefer rustc's shape before Bloop's.** A disk cache is inspectable, killable,
  content-addressable and has no lifecycle; a resident process adds a socket, a
  permission boundary, expiry policy and a stale-state failure mode before it adds
  a single skipped compilation. If a `dub` engine ever caches compilation,
  `-C incremental`-style state under a per-task directory is the first rung.
- **Any resident state must be named in the key.** Today the key is the `TaskId`
  text, so a daemon would silently become an undeclared input. The spec should
  grow an explicit generation token — Gradle's JVM-argument identity and rustc's
  `svh`-named session are the two proven spellings — before a daemon exists.
- **D's fixed cost is small; the reuse argument is not.** Neither the DMD nor the
  LDC toolchain here exposes a persistent compilation cache (**catalog inference**
  from the build settings), so Bloop's 20x start-up argument does not obviously
  transfer to a one-shot `dub test`. What would transfer is query- or
  declaration-level reuse, which needs a compiler-emitted artifact, not a
  longer-lived process. Keep the fallback first-class when it arrives: Kotlin's
  build-tools API defaults to in-process, and [moon] falls back in-process when
  its daemon RPC fails.

## Sources

In-corpus pages synthesized: [concepts] (rebuilder/trace vocabulary, §6), [sbt]
(Zinc `Analysis`), [bazel] (`Skyframe` cache), [buck2] (daemon-scoped dep files),
[buildxl] (orchestrator/worker split), [moon] (in-process fallback), [please]
(persistent workers removed), [semantic-caching] (key strength, tool identity),
[dynamic-deps-distributed] (daemon versus graph scheduling),
[sandboxing-overheads] (process boundary as isolation).

Primary sources, opened at these pinned revisions:

- Bloop `7baa8508a3b536e414b89d6fc0a6e302a3e40d91`: [`what-is-bloop.md`][bloop-what], [`server.md`][bloop-server].
- TypeScript `c63de15a992d37f0d6cec03ac7631872838602cb` (5.9.3): [`session.ts`][ts-session],
  [`protocol.ts`][ts-protocol], [`editorServices.ts`][ts-editorservices], [`builder.ts`][ts-builder],
  [`builderState.ts`][ts-builderstate], [`tsbuildPublic.ts`][ts-tsbuild], [`commandLineParser.ts`][ts-cmdline].
- TypeScript native `622d4f779368e3d8cc721b329f8d1fb9066b528c`: [`api/session.go`][ts-go-session],
  [`project/session.go`][ts-go-project], [`incremental/buildInfo.go`][ts-go-buildinfo].
- rustc `1c3a6506966e21845b31de0b075d2527660db132`: [`persist/fs.rs`][rust-fs],
  [`persist/mod.rs`][rust-persist], [`codegen-options/index.md`][rust-codegen].
- rustc-dev-guide `a29f8285990b8254783202aa0d86322eb21edf61`: [`query.md`][rdg-query],
  [`incremental-compilation.md`][rdg-incr], [`incremental-compilation-in-detail.md`][rdg-incr-detail].
- Gradle `f7643bf228a2635f290c0f5f95edd3e30c91d711`: [`gradle_daemon.adoc`][gradle-daemon].
- Kotlin `46e49566aa062c50c0009ebd9594b64565c34e01`: [`DaemonParams.kt`][kotlin-params],
  [`CompileService.kt`][kotlin-service], [`KotlinCompilerClient.kt`][kotlin-client],
  [`CompilerExecutionStrategyConfigurationImpl.kt`][kotlin-strategy],
  [`CompilationServiceImpl.kt`][kotlin-impl]. Daemon lifetime: [kotlin-daemon.html][kotlin-daemon-doc];
  incremental compilation and caches: [kotlin-caches] (both unpinned; official docs,
  not a source tree).

Unverified: no benchmark isolating daemon warmth from cache reuse was found for
Bloop, Kotlin or Gradle; Bloop's 20x and rustc's "a few percent" are the only
published figures repeated here, and both are the projects' own. Statements marked
**catalog inference** are analysis, not measurements.

<!-- References -->

[concepts]: ./concepts.md
[sbt]: ./sbt.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[buildxl]: ./buildxl.md
[moon]: ./moon.md
[please]: ./please.md
[semantic-caching]: ./semantic-caching.md
[dynamic-deps-distributed]: ./dynamic-deps-distributed.md
[sandboxing-overheads]: ./sandboxing-overheads.md
[bloop-what]: https://github.com/scalacenter/bloop/blob/7baa8508a3b536e414b89d6fc0a6e302a3e40d91/docs/what-is-bloop.md
[bloop-server]: https://github.com/scalacenter/bloop/blob/7baa8508a3b536e414b89d6fc0a6e302a3e40d91/docs/server.md
[ts-session]: https://github.com/microsoft/TypeScript/blob/c63de15a992d37f0d6cec03ac7631872838602cb/src/server/session.ts
[ts-protocol]: https://github.com/microsoft/TypeScript/blob/c63de15a992d37f0d6cec03ac7631872838602cb/src/server/protocol.ts
[ts-editorservices]: https://github.com/microsoft/TypeScript/blob/c63de15a992d37f0d6cec03ac7631872838602cb/src/server/editorServices.ts
[ts-builder]: https://github.com/microsoft/TypeScript/blob/c63de15a992d37f0d6cec03ac7631872838602cb/src/compiler/builder.ts
[ts-builderstate]: https://github.com/microsoft/TypeScript/blob/c63de15a992d37f0d6cec03ac7631872838602cb/src/compiler/builderState.ts
[ts-tsbuild]: https://github.com/microsoft/TypeScript/blob/c63de15a992d37f0d6cec03ac7631872838602cb/src/compiler/tsbuildPublic.ts
[ts-cmdline]: https://github.com/microsoft/TypeScript/blob/c63de15a992d37f0d6cec03ac7631872838602cb/src/compiler/commandLineParser.ts
[ts-go-session]: https://github.com/microsoft/TypeScript/blob/622d4f779368e3d8cc721b329f8d1fb9066b528c/tsc/internal/api/session.go
[ts-go-project]: https://github.com/microsoft/TypeScript/blob/622d4f779368e3d8cc721b329f8d1fb9066b528c/tsc/internal/project/session.go
[ts-go-buildinfo]: https://github.com/microsoft/TypeScript/blob/622d4f779368e3d8cc721b329f8d1fb9066b528c/tsc/internal/execute/incremental/buildInfo.go
[rust-fs]: https://github.com/rust-lang/rust/blob/1c3a6506966e21845b31de0b075d2527660db132/compiler/rustc_incremental/src/persist/fs.rs
[rust-persist]: https://github.com/rust-lang/rust/blob/1c3a6506966e21845b31de0b075d2527660db132/compiler/rustc_incremental/src/persist/mod.rs
[rust-codegen]: https://github.com/rust-lang/rust/blob/1c3a6506966e21845b31de0b075d2527660db132/src/doc/rustc/src/codegen-options/index.md
[rdg-query]: https://github.com/rust-lang/rustc-dev-guide/blob/a29f8285990b8254783202aa0d86322eb21edf61/src/query.md
[rdg-incr]: https://github.com/rust-lang/rustc-dev-guide/blob/a29f8285990b8254783202aa0d86322eb21edf61/src/queries/incremental-compilation.md
[rdg-incr-detail]: https://github.com/rust-lang/rustc-dev-guide/blob/a29f8285990b8254783202aa0d86322eb21edf61/src/queries/incremental-compilation-in-detail.md
[gradle-daemon]: https://github.com/gradle/gradle/blob/f7643bf228a2635f290c0f5f95edd3e30c91d711/platforms/documentation/docs/src/docs/userguide/reference/runtime-configuration/gradle_daemon.adoc
[kotlin-params]: https://github.com/JetBrains/kotlin/blob/46e49566aa062c50c0009ebd9594b64565c34e01/compiler/daemon/daemon-common/src/org/jetbrains/kotlin/daemon/common/DaemonParams.kt
[kotlin-service]: https://github.com/JetBrains/kotlin/blob/46e49566aa062c50c0009ebd9594b64565c34e01/compiler/daemon/daemon-common/src/org/jetbrains/kotlin/daemon/common/CompileService.kt
[kotlin-client]: https://github.com/JetBrains/kotlin/blob/46e49566aa062c50c0009ebd9594b64565c34e01/compiler/daemon/daemon-client/src/main/kotlin/KotlinCompilerClient.kt
[kotlin-strategy]: https://github.com/JetBrains/kotlin/blob/46e49566aa062c50c0009ebd9594b64565c34e01/compiler/build-tools/kotlin-build-tools-impl/src/main/kotlin/org/jetbrains/kotlin/buildtools/internal/CompilerExecutionStrategyConfigurationImpl.kt
[kotlin-impl]: https://github.com/JetBrains/kotlin/blob/46e49566aa062c50c0009ebd9594b64565c34e01/compiler/build-tools/kotlin-build-tools-impl/src/main/kotlin/org/jetbrains/kotlin/buildtools/internal/CompilationServiceImpl.kt
[kotlin-daemon-doc]: https://kotlinlang.org/docs/kotlin-daemon.html
[kotlin-caches]: https://kotlinlang.org/docs/gradle-compilation-and-caches.html
