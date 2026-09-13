# Replay versus continuation snapshotting

There are two ways to make a computation survive the death of its process: **replay** re-executes deterministic code against a journal of the non-deterministic results it saw the first time, and **snapshotting** serializes the live continuation (stack frames, heap reachable from them, closures) and later restores it. This page reads six systems that sit at different points on that axis — two Lisp/Haskell-lineage designs that ship continuations or closures as values, one language whose runtime can serialize any value including a captured continuation, two WebAssembly durable-execution engines, and one product that snapshots a whole OS process with CRIU — and asks what each approach costs and rules out.

| Field        | Value                                                                                                                                                                                                                                                                                                                                                                               |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Germain, Feeley, Monnier (Termite); Epstein, Black, Peyton Jones (Cloud Haskell); Unison Computing (Unison runtime); Golem Cloud, Inc. (Golem); Flawless (Flawless); Trigger.dev, Inc. (Trigger.dev)                                                                                                                                                                                |
| Venue / year | Scheme and Functional Programming Workshop 2006 (Termite); Haskell Symposium 2011 (Cloud Haskell); the `unison` runtime tree, reviewed at `trunk` (Unison); the `golem` tree and in-tree docs (Golem); official docs (Flawless); the `trigger.dev` tree and in-tree docs (Trigger.dev)                                                                                              |
| DOI or URL   | [Termite paper PDF][termite-pdf] · [Termite DOI][termite-doi] · [Cloud Haskell DOI][ch-doi] · [Cloud Haskell PDF][ch-pdf] · [Unison runtime design notes][unison-runtime-docs] · [Golem snapshotting docs][golem-snapshotting] · [Flawless docs][flawless-docs] · [Trigger.dev how-it-works][trigger-how-it-works]                                                                  |
| Category     | theory                                                                                                                                                                                                                                                                                                                                                                              |
| Grounds      | 7 (replay or snapshot), 5 (versioning against old histories), 3 (determinism enforcement)                                                                                                                                                                                                                                                                                           |
| Local clones | `$REPOS/distributed-process` at `20f033740c10f1cb0a05aee8e0c7485ab2bbace2` · `$REPOS/unison/unison` at `0452fcab2635cdbf0d1f717812a1168d300ebbcb` · `$REPOS/golem` at `d43c34ddb6f99335ed2d43c13465377a0f474b37` · `$REPOS/trigger.dev` at `66ff818eb41fab762bd4f615a42d30b559db59f0`. No clone of Termite or Flawless exists; both are cited from the paper and the official docs. |

**Last reviewed:** September 12, 2026.

## What it establishes

Across the six systems the finding is that **nobody ships an arbitrary continuation across a code-version boundary, and the two systems that ship continuations at all (Termite, Unison) can only do so because their runtime identifies code by something stable — a procedure name plus control-point index, or a content hash — so a serialized frame is a pointer into code that must exist, byte-identical, on the receiving side.** Cloud Haskell refuses arbitrary closures outright and admits only `static` code labels plus an explicitly serialized environment. The two durable-execution engines built for production (Golem, Flawless) both chose replay of a host-call log, with Golem adding a user-defined state snapshot as an optimization and as its only route across an incompatible code change. Trigger.dev is the lone true process-snapshot system, and it pays for it with a seccomp profile that must forbid `io_uring` because the kernel cannot checkpoint those file descriptors.

The definitions the page relies on:

- **Replay**: the program is re-run from its entry point; each effectful step consults a journal and, if a recorded result exists for that step, returns it instead of performing the effect. Requires the code between steps to be deterministic. The persisted state is the journal.
- **Continuation snapshot**: the runtime serializes the delimited or full continuation of the running computation, including every value it references, and a fresh process deserializes and invokes it. Requires the code the frames point into to exist on the restoring side. The persisted state is the continuation.
- **State snapshot**: the program serializes its own application state (not its stack) at a quiescent point; recovery reconstructs a fresh instance from that state and replays only the journal tail after it. Golem's "user-defined snapshotting" is this third thing, and it is neither of the first two.

The Cloud Haskell paper states the underlying obstruction in one sentence ([`ch-pdf`][ch-pdf], §5): "_serializability of a function is not a structural property of the function, because Haskell's view of a function is purely extensional. In other words, all we can do with a function is apply it; we can't introspect on its internal structure_".

## Termite Scheme

Germain, Feeley and Monnier, _Concurrency Oriented Programming in Termite Scheme_ ([PDF][termite-pdf], [DOI][termite-doi]). The abstract: "_Termite Scheme is a variant of Scheme intended for distributed computing. … We exploit the existence of first class continuations in order to allow the expression of high-level concepts such as process migration._"

Termite is the cleanest statement of the snapshot pole. Section 3.1 (_Serialization_) sets the requirement: "_it is important that the runtime system of the language supports serialization of every first class value in the language, including closures and continuations._" It then names the boundary: "_It will not be possible to serialize a closure or a continuation if it has a direct reference to one of these objects in their environment_" (ports, physical devices), and the fix is to move such objects behind a process so that "_the serialization of such an object will be just a pid_". Process migration is then a three-line library function over `call/cc` (§4.9):

```scheme
(define (migrate-task node)
  (call/cc
    (lambda (k)
      (remote-spawn node (lambda () (k #t)))
      (halt!))))
```

The paper is equally explicit about what makes the frames restorable. Section 6 describes Gambit-C's representation: closures and continuation frames are flat vectors of free variables plus "_a pointer to the entry point in the compiled code_", and when compiled with the `block` option "_entry points and return points are identified using the name of the procedure that contains them and the integer index of the control point within that procedure._" The cost of that identification scheme is stated in the next sentence: "_the Scheme program performing the deserialization must have the same compiled code, either statically linked or dynamically loaded._" The format itself is portable — "_machine independent (endianness, machine word size, instruction set, memory layout, etc.)_" — but the code it indexes into is not versioned. Section 7.3.2 measures the operation and concludes "_the main cost of a migration is in the serialization and transmission of the continuation_".

## Cloud Haskell (`distributed-static`)

Epstein, Black and Peyton Jones, _Towards Haskell in the Cloud_ ([DOI][ch-doi], [PDF][ch-pdf]), implemented today as the `distributed-static` package in the `haskell-distributed/distributed-process` repository ([`Static.hs`][dp-static], version `0.3.11` per [`distributed-static.cabal`][dp-cabal]).

The paper's contribution is the refusal. "_It is not acceptable to say that functions are simply not serializable, because any implementation of spawn needs to be able to specify what function to run on the remote node_" (§5), but the "bake in" answer — "_the runtime system allows one to serialize any value at all_", which "_is used by every other higher-order distributed language that we know of, including Erlang_" — is rejected (§5.1) for relying on a single built-in notion of serializability and for making everything serializable when "_It is crucial that some types are not serializable_" (receive ports, `TVar`s). The replacement is `Static`: "_For the present we make the simplifying assumption that every node is running the same code_", under which "_a closure without free variables can be readily serialized as a single symbolic code address (aka linker label)_" (§5.2). The typing rule admits `static e` only when every free variable of `e` is top-level bound, and "_the defining property of a value of type (Static τ) is that it can be serialized, and moreover, that it can be serialized without knowledge of how to serialize τ_". A closure is then a static decoder plus an already-encoded environment:

```haskell
data Closure a where
  MkClosure :: Static (ByteString -> a) -> ByteString -> Closure a

unClosure :: Closure a -> a
unClosure (MkClosure f x) = unstatic f x
```

The shipped library keeps this shape exactly ([`Static.hs`][dp-static]): `data Closure a = Closure !(Static (ByteString -> a)) !ByteString`, and `newtype Static a = Static StaticLabel` where `StaticLabel` is a registered string label, a `StaticApply` of two labels, or (with GHC's `StaticPointers`) a `StaticPtr` fingerprint. The module header explains the departure from the paper: "_the main motivation for 'static' is not that they are known at compile time but rather that they provide a free 'Binary' instance_", so `staticApply` makes `Static` compositional. Labels resolve through a `RemoteTable` the program must build, usually with the Template Haskell splice `remotable` ([`TH.hs`][dp-th]), and `unClosure` in [`Node.hs`][dp-node] fails with a `String` when a label is absent.

The versioning consequence is in the paper's §7 on deployment: "_this imposes on the programmer the responsibility to ensure that all hosts are running the same version of the compiled executable. Because TypeReps are nominal … sending messages between executables that use the same name to refer to message types with different structure would most probably crash the deserializing process._" Cloud Haskell has no continuation capture at all; a process that dies is restarted by a supervisor from its `Closure`, which is a code label plus arguments — a replay-shaped recovery unit, not a snapshot.

## Unison

Unison's runtime design notes ([`docs.markdown`][unison-runtime-docs]) list as the first constraint: "_It should be possible at runtime to hash, serialize, deserialize, and compute the dependencies of any value in the language, including functions._" The reason given is distribution: "_These capabilities are needed for the implementation of Unison's distributed programming API which ships arbitrary values over the network_", with the target signatures `encode : forall a . a -> Bytes` and `decode : forall a . Bytes -> Either Err a`. The fourth constraint is "_The runtime should support algebraic effects, which requires being able to manipulate continuations of a running program._"

Both are delivered, and they compose: a captured continuation is an ordinary value, and ordinary values serialize. The runtime's value model in [`ANF.hs`][unison-anf] has a `Cont` constructor beside partial applications and data:

```haskell
data Value ref
  = Partial (GroupRef ref) (ValList ref)
  | Data ref Word64 (ValList ref)
  | Cont (ValList ref) (Cont ref)
  | BLit (BLit ref)

data Cont ref
  = KE
  | Mark Word64 [ref] [(ref, Value ref)] (Cont ref)
  | Push Word64 Word64 (GroupRef ref) (Cont ref)
```

`Push` is a stack frame: frame size, pending argument count, a `GroupRef` (the code group the frame returns into, addressed by `ref`, which is a content `Reference`), and the parent frame; `Mark` is a handler installation. The serializer in [`ANF/Serialize.hs`][unison-serialize] has a `putCont` that writes exactly these (`KET`, `MarkT`, `PushT` tags) and a versioned `getCont` that still reads the pre-version-4 layout. The builtins are typed in [`Builtin.hs` (parser-typechecker)][unison-builtin-types] as `Value.serialize : Value -> Bytes`, `Value.deserialize : Bytes -> Either Text Value`, `Value.value : a -> Value`, and `Value.load : Value ->{IO} Either [Link.Term] a` — the `Either [Link.Term]` failure is the list of code hashes the loading side does not have. `Code.serialize`/`Code.lookup` do the same for code. The runtime side registers them in [`Runtime/Builtin.hs`][unison-runtime-builtin] (`Value_serialize`, `Value_serialize_versioned`, `Value_deserialize`).

So the precise claim is: **Unison serializes values including captured continuations, and serializes code separately, by hash.** A frame does not carry its code; it carries a `Reference` to it, and the language docs describe the transfer protocol ([The big idea][unison-big-idea]): "_the sender ships the bytecode tree to the recipient, who inspects the bytecode for any hashes it's missing. If it already has all the hashes, it can run the computation; otherwise, it requests the ones it's missing and the sender syncs them on the fly._" This is what dissolves Termite's "same compiled code" constraint: the code a snapshot points into is immutable by construction, because a changed definition is a different hash, and the `Value.load` failure mode enumerates the missing ones.

What Unison Cloud does with this is less documented than the mechanism. The Cloud docs ([core concepts][unison-cloud-concepts]) describe `Remote` as "_the 'I/O of the Cloud.' It's an ability which describes the runtime for a distributed system_" that "_handles forking arbitrary computations to different locations in a cluster_", and state that "_every deployed service is known by its `ServiceHash`_" — "_update your code and the Cloud will return a different hash representing the new version._" No fetched page states whether a running `Remote` computation survives a node failure by continuation snapshot or by re-running it; the survey does not claim either. The [abilities][unison-abilities] page documents `resume` as "_a function which is expecting the result of the ability operation being called as its argument_", i.e. the captured continuation is user-visible as a first-class value, which is the precondition for either strategy.

## Golem

Golem runs WebAssembly components as durable "agents" (previously "workers"). Its persistence model is a **replayed host-call log**, and the in-tree documentation says so in its first sentence ([`snapshotting.mdx`][golem-snapshotting-src], published at [learn.golem.cloud][golem-snapshotting]): "_Golem recovers agent state by **replaying the oplog** — the log of all operations performed by the agent. For long-running or CPU-heavy agents, this replay can become slow. Golem 1.5 introduces **user-defined snapshotting**, allowing agents to opt in to periodic snapshots so that recovery only needs to replay entries recorded after the last snapshot._"

The journal is the `OplogEntry` enum in [`golem-common/src/base_model/oplog/mod.rs`][golem-oplog]. A host call is a `Start` entry (identified by its own `OplogIndex`, carrying `parent_start_index`, an optional `request` payload, and an `observational_owner` for calls that "_do not participate in replay_") paired with an `End` carrying the `response`, or a `Cancelled`; around them sit `AgentInvocationStarted`/`Finished`, `BeginAtomicRegion`/`EndAtomicRegion` ("_All oplog entries after `BeginAtomicRegion` are to be ignored during recovery except if there is a corresponding `EndAtomicRegion` entry_"), `Jump` and `Revert` regions, `Error` with a `retry_from` index, `PendingUpdate`/`SuccessfulUpdate`/`FailedUpdate`, `GrowMemory` (a memory-accounting hint, `hint: true`, not a memory image), `Restart`, and `Snapshot`. `Snapshot` is also `hint: true` and its payload is `data: OplogPayload<Vec<u8>>` plus a `mime_type` — opaque bytes the agent produced. The oplog is append-only and layered (primary in Redis streams, then compressed secondary and tertiary blob layers) per [`persistence.mdx`][golem-persistence].

Replay is driven by [`durable_host/durability.rs`][golem-durability] and the `replay_state` module ([`mod.rs`][golem-replay-state], [`claims.rs`][golem-claims]). The [`durability.mdx`][golem-durability-doc] page describes the low-level contract the SDK combinators wrap: `begin-custom-durable-invocation` "_returns `live(live-invocation)` for a new or incomplete operation, or `replayed(recorded-response)` for an operation that already completed_", and "_On replay, decode and return the recorded response without executing the operation body._" Identity is not the call's arguments: "_Golem derives the UUID from the top-level idempotency key, the parent custom invocation when nested, and a deterministic ordinal in that logical parent's namespace._" `claims.rs` makes the matching explicit as a descriptor of the recorded `Start` entry "_a concurrent-replay claim is looking for_", so concurrently issued host calls can be claimed out of order.

Two facts settle the replay-versus-snapshot question for Golem:

1. **The snapshot is application state, not a continuation and not linear memory.** The docs: "_Saving runs on the live instance. Loading is a separate factory that returns the complete state or instance; the SDK never runs the normal agent initialization path first and then hands that instance to the loader._" The Rust SDK's default is serde JSON of the agent struct; the custom form is a `save_snapshot`/`load_snapshot` pair. No `OplogEntry` carries a WebAssembly memory image, and no code path in `durable_host` snapshots linear memory.
2. **A snapshot is validated by replaying the tail, and abandoned on divergence.** From [`durable_host/mod.rs`][golem-durable-host]: "_The snapshot restores the agent's own state but not every implementation detail of the guest (for example caches of an embedded database), so the replayed tail can issue a host-call sequence different from the recorded one. Such a divergence is a snapshot recovery failure: the snapshot is abandoned and the worker replays the full oplog instead._"

Versioning uses both halves. [`agents.mdx`][golem-agents] describes the **automatic update**: the executor "_reloads it using the new component version and then replays the agent's oplog from the beginning of time_", with **divergence detection** — "_If the new component produces a different result value for a past invocation than the old one_" or "_would perform different side effects … than the ones that have been recorded_" — reverting to the old version on failure, "_only useful when the changed code is minor or it affects code paths that haven't run yet_". The **manual update** is the snapshot route: the old version's `saveSnapshot` bytes are handed to the new version's `loadSnapshot`, which "_may return with a failure in which case the agent's component version gets reverted_".

## Flawless

Flawless ([home][flawless-home], [docs][flawless-docs]) is a Rust-and-WebAssembly durable-execution engine, and it states its mechanism plainly: "_the functions are compiled to WebAssembly and executed in a completely deterministic environment. The only nondeterminism is introduced when interacting with the 'real world', like performing HTTP requests or generating random numbers. We use that knowledge to persist a log of non-deterministic side effects. This means that if the execution of a workflow is ever interrupted, we can just re-run it and catch up to the same state without the need to perform the side effects again._" The docs repeat it at the operation level: "_Everything that has a side effect, like HTTP calls, is executed only once and the result of the operation persisted to a log file. The log turns side effects into deterministic executions, if we ever need to re-execute the function._"

Two details bear on the theory. First, determinism is not a discipline but a property of the sandbox: "_Flawless also uses WebAssembly as the compilation target, to guarantee determinism across operating systems and CPU architectures_", from which follows "_You can start a workflow on one machine and finish it on another_" — the log, not a memory image, is what moves. Second, the size argument: "_This makes the amount of data we need to persist minimal, and the rest is just re-calculated on-demand in case of failure._" Time and randomness are logged side effects (`flawless::rand::random()` is marked as one), and a long-running HTTP call that dies mid-flight is retried only when the code marks it `.idempotent()`. No fetched page describes a snapshot, a checkpoint, or a story for changing workflow code while old logs exist; the survey records that absence rather than guessing.

## Trigger.dev

Trigger.dev v3/v4 is the one true **process snapshot** system in this set, and the mechanism is documented in [`docs/how-it-works.mdx`][trigger-how-it-works-src] ([published][trigger-how-it-works]): "_While waiting for a subtask or during a long programmed pause (e.g. `wait.for({ minutes: 5 })`), the system uses CRIU (Checkpoint/Restore In Userspace) to create a checkpoint of the task's entire state, including memory, CPU registers, and open file descriptors._" Restoration "_is loaded back into a new execution environment, restoring the task to its exact state before suspension_". A wait shorter than 60 seconds is not checkpointed.

The code confirms that this is an orchestration concern, not a language one. The supervisor's Kubernetes workload manager carries a `checkpointsEnabled` flag ([`types.ts`][trigger-wm-types], "_Whether CRIU checkpoint/restore is enabled for this deployment_"), the `ComputeSnapshotService` in [`computeSnapshotService.ts`][trigger-snapshot-service] schedules delayed snapshots and verifies HMAC-signed callbacks from the snapshotting gateway, and the wire contract is a Zod schema in [`schemas/checkpoints.ts`][trigger-checkpoints-schema]:

```ts
export const CheckpointServiceSuspendRequestBody = z.object({
  type: CheckpointType,
  runId: z.string(),
  snapshotId: z.string(),
  runnerId: z.string(),
  projectRef: z.string(),
  deploymentVersion: z.string(),
  reason: z.string().optional(),
});

export const CheckpointServiceRestoreRequestBody = DequeuedMessage.required({
  checkpoint: true,
});
```

Note `deploymentVersion`: the checkpoint is pinned to the image it was taken from, because it is that image's memory. The price of snapshotting a real process shows up in [`kubernetesPodSpec.ts`][trigger-podspec], which applies a node-local seccomp profile when checkpoints are enabled: "_node >= 24 always creates io_uring fds, which can't be checkpointed, and blocking io_uring_setup makes libuv fall back to epoll._" The service also treats snapshots as optional: the supervisor comments that "_Snapshots are an optimization, not a correctness requirement - runs continue fine without them_", and the docs pair checkpointing with idempotency keys for the actual durability story ("_Trigger.dev's Checkpoint-Resume System, combined with idempotency keys, enables durable execution_"). In other words the snapshot exists to release compute during a wait, and correctness on a lost checkpoint falls back to re-running the task.

## Relevance to durable execution

### 3. Determinism enforcement

The snapshot systems do not need determinism at all: Termite and Trigger.dev restore bytes and continue, and nothing between two effects has to repeat. The replay systems each buy determinism a different way. Flawless and Golem get it from the WebAssembly sandbox — every source of non-determinism is a host import and therefore journaled; Golem's `Start`/`End` pairs are exactly the set of imports. Cloud Haskell has no replay, so the question does not arise. Golem's state snapshot re-introduces the requirement in a weaker form: the snapshot plus the replayed tail must reproduce the recorded host-call sequence, and the runtime checks that rather than trusting it.

### 5. Versioning against old histories

The two poles pin different things. **A continuation snapshot pins code.** Termite's frames index into "_the same compiled code_" by procedure name and control-point number; Trigger.dev's checkpoint carries a `deploymentVersion` because it is a memory image of that image; Cloud Haskell's labels resolve only against "_the same version of the compiled executable_". Unison alone escapes, and only by making code immutable and content-addressed so that "the same code" is a hash the loader can demand-fetch, with `Value.load` returning the list of missing `Link.Term`s instead of crashing. **A replay journal pins history.** Golem's automatic update replays the whole oplog under the new code and reverts on any result or side-effect divergence; that is the correct semantics for a journal, and the docs are candid that it works only for minor changes. Golem's manual update shows the escape hatch a replay system needs across an incompatible change: a state snapshot with an explicit `save`/`load` pair, which is a versioned schema migration in disguise. No system in this set migrates a live continuation across a code change.

### 7. Replay or snapshot

What each costs, from the sources:

| Concern                       | Replay (Golem, Flawless)                                                                                              | Continuation / process snapshot (Termite, Trigger.dev; Unison-capable)                                                                     |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Size of persisted state       | Proportional to the number of effects ("_minimal_" per Flawless); grows without bound, hence Golem's opt-in snapshots | Proportional to live heap reachable from the stack; Termite measured serialization as "_the main cost of a migration_"                     |
| Recovery time                 | Proportional to history length; Golem 1.5 added snapshots because replay "_can become slow_"                          | Proportional to snapshot size; no re-execution                                                                                             |
| Determinism requirement       | Total, between effects; provided by the WASM sandbox in both engines                                                  | None                                                                                                                                       |
| Language independence         | Any language that targets the sandbox and routes effects through the host                                             | Termite/Unison: one runtime; Trigger.dev: any process, but every fd type must be checkpointable (no `io_uring`)                            |
| Code upgrade                  | Old journal replayed under new code, with divergence detection (Golem); or a state migration (`save`/`load`)          | Ruled out: frames point into code that must be byte-identical (Termite), or the image is the deployment (Trigger.dev); Unison pins by hash |
| What cannot be captured       | Nothing extra: effects already pass through the host                                                                  | Ports, devices, foreign data (Termite §3.1), `MVar`/`TVar`/receive ports (Cloud Haskell §2.3), `io_uring` fds (Trigger.dev)                |
| What the runtime must provide | A journal keyed per effect, and an effect boundary that intercepts every non-determinism                              | A serializer for closures and frames (Gambit, Unison) or a kernel facility (CRIU)                                                          |

The sources converge on one rule: snapshotting is the right tool for **releasing resources during a wait** (Trigger.dev, and Termite's migration to a less loaded node), and replay is the right tool for **surviving a crash and a redeploy**, because a crash-plus-redeploy is precisely the situation where the code the snapshot points into no longer exists. Golem, which has both, uses the log as the source of truth and the snapshot as a validated cache of it.

### 9. Journal integrity and the single writer

**A snapshot system has no journal to keep intact, and that is its whole appeal on this
dimension.** Trigger.dev's durable artifact is a process image, so there is no append
protocol, no expected version, no torn record and no writer to fence. The integrity
question becomes "is this image restorable", which is the kernel's problem rather than
the library's.

**The price is paid in what the image may contain.** Because the checkpointer cannot
capture every kind of kernel object, the sandbox must forbid the ones it cannot —
`io_uring` descriptors among them. So a snapshot system constrains what the program is
allowed to do at all, where a journal system constrains only what it must route through
the record. That is the trade stated precisely: snapshotting is transparent to the
program's _logic_ and restrictive about its _resources_.

**A continuation-shipping system needs identical code on both sides.** Termite can
serialise a continuation because a frame is a procedure name plus a control-point index,
and Unison because code is identified by content hash — in both cases the receiving
runtime must already hold the exact code the frame points into. The integrity unit is
therefore code identity, not a record version, and Cloud Haskell's refusal to serialise
arbitrary closures is the honest version of the same constraint.

**Golem's hybrid keeps the journal authoritative.** Its user-defined snapshot truncates
the replay prefix but does not replace the oplog, so integrity remains the log's
property and the snapshot is an optimisation — the same relationship `rr` keeps between
its trace and its checkpoints.

### 10. Operator recovery and intervention

**Rewinding is available exactly where a journal exists.** Golem can revert to an oplog
index or undo the last N invocations, because there is a record to move a pointer within.
Trigger.dev cannot rewind at all: a process image is a single point, not a timeline, and
the only moves are restore-it or start over. That is the sharpest practical consequence
of the choice in this whole page.

**A failed attempt in the snapshot model restarts the whole function.** There is no
step memoisation, so "recover from step seven" is not expressible — the unit of recovery
is the attempt. An operator's options are therefore to retry everything or to give up.

**Versioning collapses into pinning.** A run is locked to the worker version it started
on, and a restored image necessarily lands in the code it was captured from, so the
question of new code meeting an old record cannot arise. This is genuinely simpler, and
it means an in-flight run can never be fixed by deploying a correction.

**Golem's automatic update is the opposite position**: replay the whole record under new
code and refuse the upgrade if anything diverges. Only a journal makes that check
possible.

### 11. Suspension and external input

**Snapshotting makes a wait free of determinism obligations**, which is the model's
strongest selling point. Nothing is re-executed on resume, so the program may call the
clock, the random source and the network anywhere, and a wait of arbitrary length costs
only the image.

**But the wait needs a threshold, and the threshold is a wart.** A checkpoint is only
taken after a minimum wait, so short waits hold a container and a concurrency slot.
Replay systems have no such split: every wait, short or long, ends the process the same
way. One code path is easier to reason about than two.

**Concurrent waits are restricted rather than journaled.** Because there is no record of
which wait is outstanding, the runtime forbids a second concurrent wait and offers a
batch primitive instead. A journal-based system needs no such rule: several outstanding
waits are several records.

**Continuation shipping turns a wait into a migration.** Termite's process migration is
the same mechanism as its wait — serialise the continuation, send it elsewhere, resume —
which is elegant and is exactly what makes it unusable across a code change.

---

## Implications for a durable-execution library

- **Snapshotting removes the determinism obligation and adds a resource one.** A
  restored image re-executes nothing, so the program may be arbitrarily impure; in
  exchange the sandbox must forbid every kernel object the checkpointer cannot capture.
  A library inside an existing language and runtime cannot usually make that trade.
- **A journal buys the timeline; an image buys only a point.** Rewinding, forking,
  resuming from a chosen step and proving new code against an old record all require a
  record. Choosing a snapshot forecloses the entire operator dimension, which is the
  cost most easily overlooked when the appeal is "no determinism rules".
- **No continuation survives a code change**, and the two languages that can ship
  continuations at all manage it only because they identify code by something stable —
  a procedure name and control point, or a content hash. A library whose programs are
  edited between crash and resume must replay.
- **Serialisability of a function is not a structural property**, as the Cloud Haskell
  paper puts it, which is why the honest designs admit only static labels plus an
  explicit environment. Any scheme that promises to serialise arbitrary closures is
  either restricting the language or lying.
- **A state snapshot is neither of the two.** Golem's save-and-load pair is the
  program's own state, not its stack, and it truncates a replay prefix rather than
  replacing the record. That third option is the practical one for bounding replay cost,
  and it is what event-sourced systems have always called a snapshot.
- **Keep the record authoritative and the snapshot derived.** Golem and `rr` both do
  this; it means a snapshot can be discarded, re-derived, or distrusted without losing
  anything.
- **A wait threshold is a design smell.** Splitting waits into "held in memory" and
  "checkpointed" gives a system two code paths where a replay system has one, and the
  short path is the one that will be wrong under load.
- **Restricting concurrent waits is a symptom of having no record of them.** If
  outstanding waits are records, several are no harder than one.

---

## Sources

- Germain, Feeley, Monnier, _Concurrency Oriented Programming in Termite Scheme_, Scheme and Functional Programming Workshop 2006 — [PDF][termite-pdf], [DOI][termite-doi]
- Epstein, Black, Peyton Jones, _Towards Haskell in the Cloud_, Haskell Symposium 2011 — [DOI][ch-doi], [PDF][ch-pdf]
- `distributed-static` — [`Static.hs`][dp-static], [`distributed-static.cabal`][dp-cabal]; `distributed-process` — [`Closure/TH.hs`][dp-th], [`Node.hs`][dp-node]
- Unison — [runtime design notes][unison-runtime-docs], [`ANF.hs`][unison-anf], [`ANF/Serialize.hs`][unison-serialize], [`Runtime/Builtin.hs`][unison-runtime-builtin], [builtin types][unison-builtin-types], [The big idea][unison-big-idea], [abilities][unison-abilities], [Unison Cloud core concepts][unison-cloud-concepts]
- Golem — [`OplogEntry`][golem-oplog], [`durability.rs`][golem-durability], [`replay_state/mod.rs`][golem-replay-state], [`replay_state/claims.rs`][golem-claims], [`durable_host/mod.rs`][golem-durable-host], docs: [snapshotting][golem-snapshotting-src] ([published][golem-snapshotting]), [durability][golem-durability-doc], [agents][golem-agents], [persistence][golem-persistence]
- Flawless — [home][flawless-home], [docs][flawless-docs]
- Trigger.dev — [`how-it-works.mdx`][trigger-how-it-works-src] ([published][trigger-how-it-works]), [`workloadManager/types.ts`][trigger-wm-types], [`kubernetesPodSpec.ts`][trigger-podspec], [`computeSnapshotService.ts`][trigger-snapshot-service], [`schemas/checkpoints.ts`][trigger-checkpoints-schema], [`checkpointClient.ts`][trigger-checkpoint-client]
- sparkles — [event-horizon SPEC][eh-spec], [Unison in the algebraic-effects survey][unison-page]

<!-- References -->

[termite-pdf]: http://www.schemeworkshop.org/2006/09-germain.pdf
[termite-doi]: https://doi.org/10.1145/1159789.1159795
[ch-doi]: https://doi.org/10.1145/2034675.2034690
[ch-pdf]: https://www.microsoft.com/en-us/research/wp-content/uploads/2016/07/remote.pdf
[dp-static]: https://github.com/haskell-distributed/distributed-process/blob/20f033740c10f1cb0a05aee8e0c7485ab2bbace2/packages/distributed-static/src/Control/Distributed/Static.hs
[dp-cabal]: https://github.com/haskell-distributed/distributed-process/blob/20f033740c10f1cb0a05aee8e0c7485ab2bbace2/packages/distributed-static/distributed-static.cabal
[dp-th]: https://github.com/haskell-distributed/distributed-process/blob/20f033740c10f1cb0a05aee8e0c7485ab2bbace2/packages/distributed-process/src/Control/Distributed/Process/Internal/Closure/TH.hs
[dp-node]: https://github.com/haskell-distributed/distributed-process/blob/20f033740c10f1cb0a05aee8e0c7485ab2bbace2/packages/distributed-process/src/Control/Distributed/Process/Node.hs
[unison-runtime-docs]: https://github.com/unisonweb/unison/blob/0452fcab2635cdbf0d1f717812a1168d300ebbcb/unison-runtime/src/Unison/Runtime/docs.markdown
[unison-anf]: https://github.com/unisonweb/unison/blob/0452fcab2635cdbf0d1f717812a1168d300ebbcb/unison-runtime/src/Unison/Runtime/ANF.hs
[unison-serialize]: https://github.com/unisonweb/unison/blob/0452fcab2635cdbf0d1f717812a1168d300ebbcb/unison-runtime/src/Unison/Runtime/ANF/Serialize.hs
[unison-runtime-builtin]: https://github.com/unisonweb/unison/blob/0452fcab2635cdbf0d1f717812a1168d300ebbcb/unison-runtime/src/Unison/Runtime/Builtin.hs
[unison-builtin-types]: https://github.com/unisonweb/unison/blob/0452fcab2635cdbf0d1f717812a1168d300ebbcb/parser-typechecker/src/Unison/Builtin.hs
[unison-big-idea]: https://www.unison-lang.org/docs/the-big-idea/
[unison-abilities]: https://www.unison-lang.org/docs/fundamentals/abilities/
[unison-cloud-concepts]: https://www.unison.cloud/docs/core-concepts/
[golem-oplog]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-common/src/base_model/oplog/mod.rs
[golem-durability]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/src/durable_host/durability.rs
[golem-replay-state]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/src/durable_host/replay_state/mod.rs
[golem-claims]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/src/durable_host/replay_state/claims.rs
[golem-durable-host]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/golem-worker-executor/src/durable_host/mod.rs
[golem-snapshotting-src]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/develop/snapshotting.mdx
[golem-snapshotting]: https://learn.golem.cloud/develop/snapshotting
[golem-durability-doc]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/develop/durability.mdx
[golem-agents]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/concepts/agents.mdx
[golem-persistence]: https://github.com/golemcloud/golem/blob/d43c34ddb6f99335ed2d43c13465377a0f474b37/docs/src/content/next/operate/persistence.mdx
[flawless-home]: https://flawless.dev/
[flawless-docs]: https://flawless.dev/docs/
[trigger-how-it-works-src]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/docs/how-it-works.mdx
[trigger-how-it-works]: https://trigger.dev/docs/how-it-works
[trigger-wm-types]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/apps/supervisor/src/workloadManager/types.ts
[trigger-podspec]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/apps/supervisor/src/workloadManager/kubernetesPodSpec.ts
[trigger-snapshot-service]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/apps/supervisor/src/services/computeSnapshotService.ts
[trigger-checkpoints-schema]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/packages/core/src/v3/schemas/checkpoints.ts
[trigger-checkpoint-client]: https://github.com/triggerdotdev/trigger.dev/blob/66ff818eb41fab762bd4f615a42d30b559db59f0/packages/core/src/v3/serverOnly/checkpointClient.ts
[eh-spec]: ../../../specs/event-horizon/SPEC.md
[unison-page]: ../unison.md
