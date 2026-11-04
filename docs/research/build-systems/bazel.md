# Bazel (Java, C++, Starlark)

Bazel's engine in one sentence: a demand-driven, restarting evaluator over one
immutable node graph, where actions are ordinary nodes whose execution is backed by
three caches and, optionally, a REAPI client. This page is the engine companion to
the workspace-shaped survey and stays inside `src/main`.

**Last reviewed:** November 2, 2026

| Field          | Value                                                                       |
| -------------- | --------------------------------------------------------------------------- |
| Language       | Java (engine), C++ (`linux-sandbox`, client), Starlark (build language)     |
| License        | Apache-2.0                                                                  |
| Repository     | [bazelbuild/bazel][repo]                                                    |
| Documentation  | [bazel.build][docs]; [`skyframe.mdx`][skyframe], [`codebase.mdx`][codebase] |
| Category       | Industry — polyglot orchestrator; the reference restarting-scheduler design |
| Clone (pinned) | `$REPOS/build-systems-research/src/bazel`                                   |
| Commit         | `2105aec32b598dcc8e09905e7cf18ccfa4b0358e`                                  |
| Tree version   | `MODULE.bazel` declares `10.0.0-prerelease` — a dev tip, not a release      |

## Overview

### What it solves

The engine-level problem is not "run a command" but "decide, for a graph of
hundreds of thousands of nodes, which ones a change reached, without reading a file
the graph does not know about". Skyframe makes every read an edge: values are
`SkyValue`s, names are `SkyKey`s, and a `SkyFunction` may only get data by asking
for a key. [`skyframe.mdx`][skyframe] claims hermeticity, "Correct and perfect
incrementality" and parallelism, then names the mechanism: the graph is rebuilt
only for "the reverse transitive closure of the set of changed input files".

### Design philosophy

**One graph, two phases.** Loading/analysis and execution share the evaluator:
`BUILD` files, configured targets and actions are all nodes, and the action graph is
mostly _embedded_ into the Skyframe graph ([`codebase.mdx`][codebase]). With no
separate DAG engine underneath, an unchanged target and an unchanged `.o` are both
just clean nodes.

**Restart, don't suspend.** [`concepts`] names Bazel the `Restarting` ×
`Constructive traces` cell, and the source agrees: a `SkyFunction` that asks for a
missing key must return `null` and be re-run from the top.

> [!NOTE]
> **Delta against the workspace page.** [bazel (monorepo-tooling)][mono-bazel]
> covers `MODULE.bazel`/Bzlmod, packages, labels, the two-phase graph and the five
> workspace dimensions, giving Skyframe two paragraphs. This page keeps the subject and
> goes one level down: node lifecycle, the action-cache digest, sandbox mechanics, and
> the gRPC client that speaks REAPI.

## How it works

### The node graph, and why it restarts

Nodes move through `NOT_YET_EVALUATING → CHECK_DEPENDENCIES → VERIFIED_CLEAN` or
`NEEDS_REBUILDING → REBUILDING → DONE` ([`NodeEntry.java`][node-entry]).
`VERIFIED_CLEAN` is where a warm build stops: every dependency's value is unchanged,
so no function body runs. A function that requests an unavailable key receives
`null`, yields, and is re-invoked from the start once the dependency exists:

> "A consequence of this is that any computation performed inside the
> `SkyFunction` prior to the restart must be repeated."
>
> — [`docs/contribute/codebase.mdx`][codebase]

Three mitigations follow: batched requests (`getValuesAndExceptions()`), splitting
large values across functions, and state kept across restarts in
`Environment.getState()`. The `StateMachine` helper exists because "hundreds of
thousands of in-flight Skyframe nodes is common". That is JFP §4.2's non-minimality
as an engineering bill, paid rather than paying for continuations.

### Invalidation: bottom-up, then resurrect

Bazel uses one strategy, stated without hedging: "Bazel only does bottom-up
invalidation" ([`skyframe.mdx`][skyframe]). Changed inputs are `stat`-ed, the
reverse-transitive closure is dirtied, and _change pruning_ runs the other way: a
rebuilt node whose new value equals the old one "resurrects" the nodes invalidated
through it — early cutoff as graph repair, not a rebuilder policy. Hermeticity is per
function: `FunctionHermeticity` has `HERMETIC`, `SEMI_HERMETIC` and `NONHERMETIC`,
and Skyframe "does not explicitly re-evaluate non-hermetic functions on every build:
it just relaxes some of its graph-pruning logic to be more conservative with such
nodes" ([`FunctionHermeticity.java`][hermeticity]).

### Three caches

Three layers hold state: in-memory `SkyValue`s keyed by `SkyKey`; a local action cache
keyed by primary output exec path and serialized to disk; and a remote/disk cache
keyed by action key, holding REAPI `ActionResult`s plus CAS blobs. The middle layer's
source disowns its own name:

> "The name of this class is misleading; it doesn't cache the actual actions, only
> a fingerprint of all action properties that matter for cache invalidation
> (action key, path and contents of input and output files, environment
> variables, execution properties, and certain flags), so we can tell if we need
> to rerun an action given the current state of the file system."
>
> — [`ActionCache.java`][action-cache]

Locally, then, Bazel holds a _verifying_ trace — outputs sit on disk and only their
metadata is compared. Remotely it is _constructive_, since the cache must supply
bytes the local store lacks: one `concepts` cell, two implementations, chosen by
reachability. The action key is the correctness-critical half, and
[`Action.java`][action] warns that "you may be tempted to intentionally exclude data
from the cache key, but be aware that every time we've done that, it later resulted
in expensive debugging sessions and bug fixes".

### Sandbox mechanics

The default local strategy is `sandboxed`, resolved to `linux-sandbox` where
namespaces exist ([`SandboxModule.java`][sandbox-module]). The mechanism is
`clone(2)` with `CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWIPC | CLONE_NEWPID`, plus
`CLONE_NEWNET` when network isolation is requested and `CLONE_NEWUTS` for a fake
hostname ([`linux-sandbox.cc`][linux-sandbox]) — not `ptrace`, not Detours, and no
seccomp filtering of the payload. Inside, PID 1 privatizes the mount namespace,
bind-mounts declared inputs, then remounts everything read-only except the working
directory, writable outputs and tmpfs mounts ([`linux-sandbox-pid1.cc`][pid1]).
Each spawn gets a fresh root under `sandboxBase/<runner>/<id>`, and the execroot
ends in the workspace name so paths match a plain build. Inputs are symlinked by
default; hermetic mode hardlinks them:

> "If set to true, do not mount root, only mount whats provided with
> `sandbox_add_mount_pair`. Input files will be hardlinked to the sandbox instead
> of symlinked to from the sandbox."
>
> — [`SandboxOptions.java`][sandbox-options]

Two caveats remain: network access is allowed by default
(`--sandbox_default_allow_network` defaults to `true`), and the
`processwrapper-sandbox` fallback isolates no filesystem — now a hard error, since it
"exposes the whole host filesystem, so fail rather than silently dropping
hermeticity" ([`SandboxModule.java`][sandbox-module]).

### The REAPI client

`--remote_cache` and `--remote_executor` are separate endpoints that may share a
server. The client is a plain gRPC v2 implementation: `ExecutionGrpc` with
long-running operations and `WaitExecution` ([`GrpcRemoteExecutor.java`][grpc-exec]),
`ActionCacheGrpc` and `ContentAddressableStorageGrpc` for results and blobs, and
`ByteStream` for large ones ([`GrpcCacheClient.java`][grpc-cache]). Input trees
become REAPI `Directory` messages via a Merkle-tree computer, and
`RemoteServerCapabilities` negotiates the window — this tree accepts REAPI `2.0`
through `2.11` ([`ApiVersion.java`][api-version]). `RemoteOutputsMode` names
"build without the bytes": `ALL`, `TOPLEVEL`, and `MINIMAL`, the last downloading
only "stdout, stderr and .d and .jdeps files for C++ and Java compilation actions".
Bazel defaults to a local strategy and races the remote executor only under dynamic
execution, whose Javadoc argues the cost case: saving half a second locally is a poor
trade against "5 seconds to upload the results" for an action scheduled remotely
([`DynamicSpawnStrategy.java`][dynamic]).

## Analysis spine

**Restarting × constructive traces** — the `Bazel` cell of [concepts]'s Table 2,
reached by a mechanism the paper does not name: a memoizing graph evaluator whose
functions are re-entered rather than resumed. Three deviations keep it off the cell
exactly. The constructive trace lives in memory and per server process, so a cold
server rebuilds analysis even when a remote cache answers instantly; the action-level
local cache is verifying, not constructive; and early cutoff is graph resurrection.
There are no continuations, so it cannot fit a _suspending_ cell at all.

### 1. Task model & scheduling

Static at the action level: a rule declares `inputs` and `outputs`, and the bipartite
action graph is a DAG. Evaluation is dynamic at the node level, since a `SkyFunction`
discovers edges by asking for keys mid-computation. Scheduling is thus implicit —
graph readiness plus a thread pool — not a sorted queue. Parallelism is per action
(`--jobs`, the local resource manager) and per mnemonic via `--strategy`.

### 2. Rebuilding & correctness

Two mechanisms at two granularities. Node level: bottom-up dirtying of the
reverse-transitive closure, then change pruning resurrects dependents when a
recomputed value is identical. Action level: a digest over action key, input metadata
and output metadata, serialized so a fresh server still hits it. Correctness is
constructed, not checked: an undeclared read is an unregistered edge, which the
Skyframe doc names as producing "incorrect incremental builds".

### 3. Dependency discovery

Declared, with two narrow exceptions: C++ include scanning may add inputs before
execution, and a compiler's `.d` file may report inputs unused after it
(`Action.discoverInputs()` / `updateInputs()`) — the docs concede that "This can
result in incorrect incremental builds if a used input is reported as unused". The
sandbox is _not_ an oracle: nothing observes reads, so a command that opens an
undeclared file succeeds while the graph stays wrong — the sharpest fork from
[BuildXL][buildxl] and [Rattle][rattle], which treat that as a finding.

### 4. Store & caching

No content-addressed store in the build's own working area: outputs live in the
execroot and the sandbox links them in. Content addressing appears in the disk cache —
a digest-keyed local blob store with automatic and manual GC (`src/tools/diskcache`) —
and in the REAPI CAS. Deduplication is a property of the shared cache, not the local
build, which is why `MINIMAL` downloads matter: hashes can stand in for bytes until
something materializes them.

### 5. Hermeticity & provenance

Layered and honest about its seams: namespaces and read-only remounts, opt-in network
isolation, hardlink materialization in hermetic mode, and a `FunctionHermeticity` tag
telling the evaluator which nodes cannot be trusted for pruning. Provenance in the
SLSA/in-toto sense is **absent** from the action path — `attestation` appears only in
release roadmaps about verifying registry modules. The Build Event Protocol is an
observability stream, not a signed claim about who ran what.

### 6. Distribution

A conforming REAPI v2 client is the whole story: remote cache, remote execution,
remote downloader, and an experimental remote output service. No proprietary executor
protocol, no sharding layer — Bazel hands each action to a server and retries on
`RetryInfo` backoff rather than scheduling a graph across workers. Dynamic execution
is the only invention above the protocol.

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a static task DAG with no persistent graph, so
direct borrowings are small and structural lessons large. Worth taking: the _layered
cache_ discipline (in-memory check, metadata digest, content-addressed lookup) and the
idea that a non-hermetic task must be tagged so pruning backs off — an attribute on a
task, not a new engine. Worth avoiding: restarts, affordable only because Bazel
memoizes hundreds of thousands of nodes in a long-lived JVM; a one-shot D process would
pay the repetition with nothing to amortize it against. The open question is the one
`concepts` flags as out of scope: how a D toolchain could observe reads cheaply enough
to verify declarations — the [Rattle][rattle] and [BuildXL][buildxl] direction.

## Strengths

- **One incrementality model for everything.** Packages, configurations, actions
  and artifacts are the same kind of node: no second scheduler, no "graph cache".
- **Early cutoff by construction.** Change pruning supplies it without a
  per-rebuilder policy: a comment-only edit stops at the first unchanged node.
- **A real shared cache.** Local/remote is an explicit split, the disk cache is
  first-class with its own GC tool, and `MINIMAL` downloads answer materialization.

## Weaknesses

- **Restart is the scheduler.** JFP §4.2's non-minimality is paid for with
  `getState()`, `StateMachine` and batched requests — unavailable to any task
  description that is not a Java function.
- **A filesystem sandbox only.** No read observation, no input validation, no
  violation taxonomy: the bug classes [perfect-dependencies] is about are invisible.
  Network access is allowed by default, and the isolation fallback had to be made a
  hard error after years of silent leaks.
- **No provenance**, and cache state is process-shaped: a cold server rebuilds
  analysis from scratch, which is why "keep the daemon alive" is load-bearing.

## Key design decisions and trade-offs

| Decision                                | Rationale                                                      | Trade-off                                                               |
| --------------------------------------- | -------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Everything is a `SkyValue`              | One incrementality model; uniform invalidation and parallelism | Analysis nodes dominate memory; a cold server re-derives the graph      |
| Restart instead of suspend              | No continuations, no blocked threads, plain Java               | Repeated work; `getState()`/`StateMachine` complexity at scale          |
| Per-function hermeticity tag            | Non-hermetic nodes exist, so pruning must weaken for them      | A manual annotation that can be wrong, with silent fallout              |
| Action cache stores metadata, not bytes | Outputs are already in the execroot; copying would duplicate   | The local cache cannot supply a missing output; only the remote can     |
| Namespace sandbox, no syscall tracing   | Cheap, portable, no `ptrace` tax, works for every toolchain    | Undeclared reads are undetectable, so correctness rests on declarations |
| REAPI as the only distribution protocol | Interoperates with every compatible backend; no bespoke code   | No graph-level scheduling and no transport optimizations                |

## Sources

- [`bazelbuild/bazel`][repo] at commit `2105aec32b598dcc8e09905e7cf18ccfa4b0358e`
  (clone at `$REPOS/build-systems-research/src/bazel`; HEAD dated 2026-11-02).
  Every quote is verbatim from the file cited inline, opened at that SHA.
- Evaluator and actions: [`skyframe.mdx`][skyframe], [`codebase.mdx`][codebase],
  [`NodeEntry.java`][node-entry], [`FunctionHermeticity.java`][hermeticity],
  [`Action.java`][action], [`ActionCache.java`][action-cache].
- Sandboxing and remote execution: [`SandboxModule.java`][sandbox-module],
  [`SandboxOptions.java`][sandbox-options], [`linux-sandbox.cc`][linux-sandbox],
  [`linux-sandbox-pid1.cc`][pid1], [`GrpcRemoteExecutor.java`][grpc-exec],
  [`GrpcCacheClient.java`][grpc-cache], [`ApiVersion.java`][api-version],
  [`RemoteOutputsMode.java`][outputs-mode], [`DynamicSpawnStrategy.java`][dynamic].
- Sibling pages: [concepts] for the scheduler × rebuilder grid, [mono-bazel] for the
  workspace treatment, and [buildxl], [rattle], [buildkit] for related engines.

<!-- References -->

[repo]: https://github.com/bazelbuild/bazel
[docs]: https://bazel.build
[skyframe]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/reference/skyframe.mdx
[codebase]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/contribute/codebase.mdx
[node-entry]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/skyframe/NodeEntry.java
[hermeticity]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/skyframe/FunctionHermeticity.java
[action]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/actions/Action.java
[action-cache]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/actions/cache/ActionCache.java
[sandbox-module]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/sandbox/SandboxModule.java
[sandbox-options]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/sandbox/SandboxOptions.java
[linux-sandbox]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/tools/linux-sandbox.cc
[pid1]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/tools/linux-sandbox-pid1.cc
[grpc-exec]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/remote/GrpcRemoteExecutor.java
[grpc-cache]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/remote/GrpcCacheClient.java
[api-version]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/remote/ApiVersion.java
[outputs-mode]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/remote/options/RemoteOutputsMode.java
[dynamic]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/dynamic/DynamicSpawnStrategy.java
[concepts]: ./concepts.md
[mono-bazel]: ../monorepo-tooling/bazel/
[buildxl]: ./buildxl.md
[rattle]: ./rattle.md
[buildkit]: ./buildkit.md
[perfect-dependencies]: ./perfect-dependencies.md
