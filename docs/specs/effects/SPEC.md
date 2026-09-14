# `sparkles:effects` — Effects and durable execution

## 1. Scope and status

This specification owns the proposed `sparkles:effects` package and its durable
execution contract. The four replay and recovery policies in §3 were accepted by
the user on September 14, 2026. The remaining contract is a design proposal;
implementation and compiler feasibility are not established. [PLAN.md](./PLAN.md)
is the sole milestone and evidence tracker. Public signatures below describe
future APIs, not available imports or runnable examples.

A durable program re-executes from its entry point after process loss. Its
capability operations return recorded answers until the journal is exhausted,
then execute live. The journal stores values and protocol transitions; it stores
no stack, continuation, closure, pointer, descriptor, or scheduler state.

**EFF1 — Replay boundary.** A durable program must obtain all external inputs and
perform all external effects through its durable row. Pure computation between
operations must depend only on its recorded input and previously returned values.
The initial execution is replay against an empty journal.

The initial target is sequential durable programs hosted on event-horizon with
`Topology.single`, plus a host-independent in-memory test engine. Ordinary
non-durable scopes, channels and the `Effect!T` veneer retain their existing
concurrency. A durable operation may internally supervise concurrent work, but
the program has at most one outstanding operation. Durable fan-out, racing
program branches, distributed scheduling, continuation snapshots, automatic
rollback, transparent persistence of arbitrary D values, and automatic history
compaction are outside this version. A later concurrency extension requires
recorded scheduling and completion semantics before exposing a parallel API.

Representative consumers include a document-processing pipeline, an operator
approval workflow, and a local release tool. `apps/release` is the first consumer;
its git, forge and prompt policies belong to the application. An external system
need not provide deduplication to be usable, but absence of deduplication limits
automatic recovery (§7).

Terminology follows the [durable-execution vocabulary][concepts]. “Step” means
one logical operation; “attempt” is a recorded retry of that operation; “episode”
is one host invocation that replays and possibly extends a run.

## 2. Package ownership and extraction

### 2.1 Package graph

An arrow means a package depends on another package:

```text
consumer ──> event-horizon ──> effects ──> base
    └──────────────────────> effects ──> expected
```

`effects` owns capability vocabulary, structured effects and the durable
protocol. `event-horizon` owns live I/O, scheduling, subprocess execution and the
first persistent journal adapter. The consumer supplies operation definitions,
code-version registration, reconciliation and compensation handlers, wake-up
delivery, operator authentication and presentation. No service or daemon is a
dependency of the durable protocol.

**EFF2 — Dependency direction.** Production sources in `effects` must not import
`sparkles.event_horizon`, `during`, completion backends or concrete schedulers.
Its tests must build without event-horizon. `core.thread.Fiber` remains permitted
for the existing deterministic executor. Test-runner dependencies are test-only.

### 2.2 Exact move set

At the reviewed baseline `2ef4d520d`, [event-horizon §2][eh-layout] identifies
eleven effects-side modules. The earlier handoff's count of nineteen is not the
move list. These files move from `libs/event-horizon/src/sparkles/event_horizon/`
to `libs/effects/src/sparkles/effects/`:

| Modules                        | Owned contract after extraction                               |
| ------------------------------ | ------------------------------------------------------------- |
| `errors`, `cause`              | I/O results, causes, interrupts and executor-visible contexts |
| `capability`                   | `Ctx`, `CtxOf`, `hasCaps`, capability and executor traits     |
| `scope_`, `schedule`           | Non-durable scopes, cancellation and schedule drivers         |
| `clock`, `net`, `proc`         | Concepts, value vocabulary and deterministic doubles          |
| `channel`, `testing`, `effect` | Channels, deterministic executor and description veneer       |

`proc` already owns `SupervisedProcessConfig`, `SupervisedProcessResult`, events,
resource samples and `LineFramer`. These move with it. `supervise`, `live`, `io`,
`buffer`, `op`, `fs`, `signals`, `watch`, `group`, pools, samplers, cgroups,
backends, loop and scheduler remain in event-horizon. The fact that some remaining
modules happen to have few dependencies does not change their ownership.

**EFF3 — Source compatibility.** Old module paths must become selective public
re-export shims, preserving type identity and old package-level imports. They
must not duplicate definitions. Extraction must audit `package` visibility:
cross-package executor seams become deliberately named public seams, while
implementation details remain private to their new package. The upstream spec
must link here for ownership once extraction lands; until then it describes the
shipped layout. Dub dependencies and both lockfiles change in the extraction
milestone, not in this documentation proposal.

New modules, all under `sparkles.effects.durable`, are:

| Module       | Responsibility                                              |
| ------------ | ----------------------------------------------------------- |
| `model`      | IDs, schemas, event vocabulary, limits, states and errors   |
| `codec`      | Canonical value encoding and bounded record framing         |
| `store`      | Journal-store concept and conditional durable transactions  |
| `operation`  | Operation descriptors, exact-expression traits and registry |
| `journal`    | The single operation-recording combinator and replay cursor |
| `run`        | Episode ownership, durable row and program entry            |
| `scope_`     | Durable scope membership and compensation protocol          |
| `input`      | Persistent waits, inbox delivery and deadlines              |
| `operator`   | Validated commands, auditing and fork construction          |
| `projection` | Read-only fold of journal state with an offset              |
| `testing`    | `MemoryJournal`, scripted world and fault harness           |
| `package`    | Selective public re-exports only                            |

The first live adapter is `sparkles.event_horizon.durable_file`, specified by
§8.3. It may use the host blocking pool for file locking and durability barriers;
it must not block the event-loop thread on those operations.

### 2.3 Supervision through the row

**EFF4 — Supervised capability.** Extend `isProc` with the exact expression below,
in addition to its existing `Child`, `spawn` and `wait` expressions. `RingProc`
forwards to the existing free `supervise(ref Sched, ...)` implementation, which
remains source compatible. `SimProc` must implement the same operation without
creating host processes.

<!-- md-example-skip -->

```d
// Required expression in isProc's existing probe body:
IoResult!SupervisedProcessResult result = p.supervise(
    argv, cfg, stdinBytes, sink);
// argv: scope const(char[])[]; cfg: SupervisedProcessConfig
// stdinBytes: scope const(ubyte)[]; sink: scope ProcessEventSink
```

The existing [supervision contract][eh-supervise] owns draining, cancellation,
reaping, truncation, event borrowing and resource-quality flags. The double adds
exact argv/config/stdin matching, scripted events and result, virtual delays,
spawn failures and invocation counts; it must reject unscripted calls rather
than silently return success. Extending the required concept is a source
compatibility change for third-party handlers and must be called out in release
notes. Existing in-tree handlers change together.

The durable process operation returns an owned value containing the complete
supervised result. Live callbacks stay inside the handler; a callback may not
mutate workflow state or feed a decision outside the journal. Captured output
needed by the program is part of the committed result. Streamed progress before
that commit is provisional telemetry, not replay input. PIDs and open child
handles are never durable results. A process that may have changed the world is
not safe to rerun merely because it exited unsuccessfully.

## 3. Accepted policy decisions

These decisions supersede the inherited proposal where they differ. The cited
catalog supplies prior art, not proof of this library's contract.

| Decision          | Accepted contract                                                                                                                    | Alternatives and consequence                                                                                                                                                                                        |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1: arguments     | Same logical step; differing canonical arguments pause before any further effect                                                     | Arguments in identity would silently authorize another execution; configurable mismatch retries can loop without resolving drift. [Comparison §1][comparison] discusses Restate and KurrentDB.                      |
| D2: divergence    | Ordered operation and argument checks, explicit decision checkpoints, terminal output comparison and unconsumed-history detection    | Operation checks alone miss internal changes; automatic machine-state instrumentation is outside scope. [Deterministic replay][replay] supplies the stronger contrast.                                              |
| D3: mutable world | Replay completed answers; reconcile incomplete effects; express fresh observations and renewed approvals as new journaled operations | Refreshing old answers can change the meaning of the completed suffix; requiring an operator for every incomplete effect discards useful domain-specific recovery. [Comparison §2][comparison], [Helland][helland]. |
| D4: intervention  | Basic controls, explicit compensation and audited forks, including replacement input in a fork                                       | Basic controls alone cannot repair a bad recorded input; rewriting the original destroys evidence. [Comparison §10][comparison], [Inngest][inngest].                                                                |

Named identity follows [Effect workflow][effect-workflow] and [Cloudflare][cloudflare],
but strict order checking intentionally forgoes their permissive insertion and
reordering. Compensation registrations are persisted descriptors, following
[Sagas][sagas]; closures cannot serve as recovery data. Versioned payloads and
read-time adapters follow [Marten][marten] and [Akka/Pekko][akka]. Writer claims
and conditional append remain separate, as in [comparison §9][comparison].
Waiting and quarantine are explicit states; [Restate][restate] and the
event-store recovery examples provide precedent.

Automatic refresh/reconciliation of arbitrary mutable external state has no
established general-library policy in the catalog. The limited recovery handler
protocol here is a local design, as are explicit decision checkpoints and the
fault harness. ARIES is useful for write-ahead ordering and recovery records;
its redo also covers committed transactions whose pages were not flushed.
“Only incomplete steps are reconciled” is this workflow contract, not a literal
description of ARIES restart ([ARIES deep-dive][wal]).

## 4. Durable program and public surface

### 4.1 Operation definitions

Each operation descriptor provides stable `name` and `version`, `Args`, `Value`
and `Error` schemas, a recovery class, and an optional compensation descriptor.
The registry maps `(name, version)` to a handler and codecs; D type names are
never wire identity. Required expressions are centralized in named traits.

<!-- md-example-skip -->

```d
alias StepResult(T, E) = Expected!(T, StepError!E);

enum bool isOperationHandler(H, Op) = __traits(compiles,
    (ref H h, ref AttemptContext ac, in Op.Args args) {
        Expected!(Op.Value, Op.Error) r = h.execute(ac, args);
    });

enum bool canRecover(H, Op) = __traits(compiles,
    (ref H h, ref RecoveryContext rc, in Op.Args args) {
        Recovery!(Op.Value, Op.Error) r = h.recover(rc, args);
    });

struct DurableRow(Registry)
{
    StepResult!(Op.Value, Op.Error) call(alias Op)(StepKey key, in Op.Args args);
    StepResult!(T, DurableError) checkpoint(T)(StepKey key, in T value);
    StepResult!(T, DurableError) awaitInput(T)(StepKey key, in WaitSpec spec);
    StepResult!(void, DurableError) sleepUntil(StepKey key, UtcNanos deadline);
    StepResult!(ScopeId, DurableError) openScope(StepKey key);
    StepResult!(void, DurableError) closeScope(ScopeId scopeId);
    StepResult!(void, DurableError) compensate(StepKey key, ScopeId scopeId);
}

EpisodeResult!(Value, Error) run(alias program, Store, Registry, Input,
    Value, Error)(ref Store store, ref Registry registry, RunId runId,
    in Input initialInput, in RunOptions options);
```

These declarations abbreviate constraints and bodies. `run` validates the
registry, encoded input, program identity and limits before entering the
program. `program(ref row, in input)` returns `Expected!(Value, Error)`;
`Value` and `Error` must have registered codecs. On resume, supplied input must
match `RunCreated`; changing it requires a fork. Construction of the live row
and registry is outside the program. The row exposes neither handlers, store,
replay status, writer epoch, episode counter nor raw scheduler access.

`RunOptions` contains the registered program/build identity, manifest digest and
creation limits; resume compares these with the active recorded configuration.
`EpisodeResult` is a tagged value: completed program success/domain error,
waiting descriptor, paused diagnostic, cancelled, terminated, or infrastructure
failure. A failed episode is not automatically a failed durable program.
`RunId`, `WriterId`, `TransactionId`, `WaitToken` and `DeliveryId` are distinct
16-byte value types. `ScopeId` is `ulong`; `StepKey` is the bounded string from
§5. All result families use `Expected` or a tagged value containing a structured
error; none requires exceptions for expected control flow.

**EFF5 — Recordable operations.** A call must have a registered operation and
canonical, bounded input/output schemas. Unsupported operations fail at compile
time when statically known, or as `unsupportedSchema` before invoking a handler.
There is no unjournaled fallback. `Ctx`'s arbitrary plain structs do not acquire
serialization merely by being capabilities: a durable row contains only
registered wrappers, with named capability sugar forwarding to `call`.

`AttemptContext` supplies the stable effect key, attempt number, cancellation
view and fenced writer claim to trusted handlers. It does not expose a second
workflow row. Handler-internal I/O belongs to that operation's crash window;
nested durable calls are rejected as `reentrantOperation`.

### 4.2 Attributes, ownership and the purity gate

**EFF6 — Restricted program.** The target program surface is `@safe pure nothrow
@nogc`. Normal templates infer attributes; purity here is an intrinsic constraint
of the program boundary. The proposed journaling bridge is the only location
allowed to adapt an impure handler call to that surface. No blanket `@trusted`
template or freely callable “make any function pure” helper is permitted.

The bridge is conditional on [M0's feasibility gate](./PLAN.md#m0-purity-and-protocol-feasibility).
A cast is not a proof of soundness. If it cannot be justified under supported D
compiler semantics, the pure direct-style API is blocked and this contract must
be revised before implementation proceeds. A passing compiler probe alone is
insufficient justification. An impure program API must not silently be called
an equivalent enforcement mechanism.

D weak purity permits mutation through arguments, and debug statements can
bypass purity checking. The program receives a fresh decoded input and an
opaque, borrowed row for each episode; it may not retain mutable aliases from
the host, invoke user-written attribute casts, perform impure debug work, or
depend on addresses, hash-table iteration, uninitialized bytes or unstable
floating-point environment state. `pure` is a useful restriction, not a sandbox
against hostile D code. [D's purity rules](https://dlang.org/spec/function.html#pure-functions)
and [the effect-handler research][handlers] bound this claim.

`DurableRow` is noncopyable, nonconstructible by callers and borrowed only for
the program invocation. Arguments are borrowed for the call and encoded before
the intent commit. Returned buffers have independent ownership, never reference
a store read buffer, and survive later calls. Codecs reconstruct values from
bytes; they never memcpy pointer-bearing D structs. Handlers and codecs must
satisfy the required `nothrow @nogc` call expressions; safety infers from them.
Expected domain failures are values. Allocation uses explicit owned buffers;
allocation failure is `resourceExhausted`, not a fabricated domain result.

`StepError!E` distinguishes recorded domain error `E` from episode-control and
infrastructure failures. On suspension, cancellation, drift, store failure or
fencing loss, the row latches a stop before returning that error. The caller
must propagate it. Even if ignored, every later call must return the latched
stop without performing ordinary effects; `run` must not commit a successful
terminal result. Cancellation alone permits the explicit compensation controls
of §10; these cannot clear the cancellation latch or resume forward work.
An infinite pure loop remains an application bug; termination cannot forcibly
unwind arbitrary native computation in-process.

## 5. Identity, matching and versioning

**EFF7 — Step identity.** A step is identified by `(runId, scopePath, key)`.
`scopePath` is the ordered list of explicit scope keys from the root. Keys are
nonempty UTF-8 strings, compared by bytes without normalization. Loop iterations
must supply explicit stable keys; a repeated key in a scope is `duplicateStep`.
The library never derives identity from a source line, call-site address, argv
hash or wall clock. Attempts start at zero and increase only by a committed
`RetryScheduled`; rerunning an uncertain attempt keeps its original number.

The effect idempotency key is the canonical tuple `(runId, scopePath, key)`;
it is stable across both recovery invocations and explicit retry attempts.
Handlers whose receiver needs attempt IDs may additionally send the attempt,
but must declare that receiver's deduplication semantics. Compensation uses a
separate key domain `(runId, "compensation", registrationSeq)`.

**EFF8 — Ordered matching.** Replay consumes the next program-originated intent
in logical order. It compares scope, key, operation name/version, kind, schemas
and complete canonical arguments. Hashes may accelerate comparison but cannot
replace byte equality. Recovery, inbox and operator records are processed by
the engine and are not extra program calls. A missing, changed or reordered
historical call pauses as `drift` before any new handler invocation. Returning
with program intents unconsumed is drift, including an old call that new code
deleted. A missing result on the next matching intent invokes §7, not a lookup
for a later named result. No new call goes live while an earlier intent remains
unresolved.

**EFF9 — Decision and terminal checks.** `checkpoint(key, value)` records and
compares its newly computed value on replay; it must not merely substitute the
old checkpoint for the new computation. It uses an intent with the encoded
value and a result acknowledging it. On completed histories the program's
recomputed terminal success or domain error must equal the recorded terminal
schema and bytes. These checks do not prove equivalence of internal computation:
changed intermediate values absent from checkpoints, later arguments and final
output can remain invisible. Replay validation is a finite trace check, not
general program equivalence, even when compared with [Golem's update check][golem].

**EFF10 — Code compatibility.** `RunCreated` pins a program name, an opaque build
ID and a registry-manifest digest covering codecs, handlers, recovery rules and
compensation versions. Normal resume rejects a different manifest or build as
`incompatibleCode`. `validateReplay` may run a candidate against a read-only
snapshot: it must compare the entire recorded program prefix and terminal
result, and stop at an unresolved intent or the live frontier without touching
the world. It returns `prefixCompatible`, `completedTraceCompatible` or drift,
with the exact checked offset; neither success proves the unexecuted suffix.

An operator may adopt a candidate with a successful validation through
`adoptCode`, conditioned on that same journal offset and with an audit reason.
This records `CodeAdopted`; recovery and compensation descriptors referenced by
history must still resolve. A changed recovery implementation is an explicit
manifest change, not an invisible library upgrade. Unknown event versions
quarantine execution. Pure registered upcasters may decode an old payload into
a new in-memory representation; the original bytes and matching codec identity
remain authoritative and are never rewritten. Upcasters may not invent effects
or discard program intents. Pinning and read-time adaptation have prior art in
[Restate][restate], [Temporal][temporal] and [Marten][marten].

## 6. Journal format

### 6.1 Canonical values and framing

**EFF11 — Wire encoding.** Format version 1 uses little-endian unsigned integers
of the declared width; signed values use two's-complement fixed widths. Byte
strings are `u32 byteLength` followed by bytes; lists are `u32 count` followed by
elements. Text is a byte string containing valid UTF-8, without NUL. Booleans are
one byte, exactly 0 or 1. Optional fields have a Boolean presence tag. IDs are
16 opaque bytes; digests are SHA-256, 32 bytes. Instants are signed 64-bit UTC
nanoseconds since the Unix epoch; durations are signed 64-bit nanoseconds.
Durable deadlines cannot use process-relative `MonoTime` values.

Each application schema defines a fixed field order, stable numeric enum tags
and canonical map ordering by encoded key. It must state its floating-point
policy if it permits floats; raw D memory layouts and padding are forbidden.
Value payloads carry `(schemaName:text, schemaVersion:u32, bytes:byteString)`.
Schema names are nonempty. Decode rejects trailing bytes, invalid tags, duplicate
map keys, excess nesting and lengths beyond configured limits.

A transaction frame is the atomic persistence unit:

| Field, in wire order     | Type        | Meaning                                                |
| ------------------------ | ----------- | ------------------------------------------------------ |
| `magic`                  | 8 bytes     | ASCII `SPKEFF01`                                       |
| `frameBytes`             | `u64`       | Total frame size, including trailer                    |
| `formatVersion`          | `u16`       | Exactly 1                                              |
| `runId`, `transactionId` | ID each     | Owning run and retry-stable append identity            |
| `writerId`               | ID          | Writer process identity                                |
| `epoch`                  | `u64`       | Monotonically increasing fencing claim                 |
| `expectedSeq`            | `u64`       | Last committed sequence before this frame; 0 for empty |
| `previousDigest`         | digest      | Previous complete frame's digest; zero for empty       |
| `eventCount`             | `u32`       | Positive event count                                   |
| `events`                 | event array | Exactly `eventCount` event envelopes                   |
| `digest`                 | digest      | SHA-256 of all preceding bytes in this frame           |
| `commitMagic`            | 8 bytes     | ASCII `EFFCOM01`                                       |
| `frameBytesAgain`        | `u64`       | Must equal `frameBytes`                                |

An event envelope is `(seq:u64, tag:u16, eventVersion:u16, body:byteString)`.
Sequences start at 1 and are contiguous, including control events. Tags and
versions below are normative; version is 1 for every initial event. The digest
detects corruption and links frames; it is not an authentication signature and
does not defend against a writer that can rewrite the whole journal.

### 6.2 Event bodies

Fields below are serialized in the order listed. `text`, `bytes`, `value`,
`id`, `digest`, `instant`, `duration`, `optional(T)` and `list(T)` use §6.1.
`step` is `(scopePath:list(text), key:text)`; `op` is `(name:text, version:u32)`.
`audit` is `(commandId:id, actor:text, reason:text)`; actor and reason are
nonempty host-authenticated descriptions, not proof of authentication.

| Tag / event                | Body fields                                                                                                                                   |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 `RunCreated`             | `program:text, build:text, manifest:digest, input:value, limits:Limits, parent:optional(Parent)`                                              |
| 2 `Intent`                 | `step:step, ordinal:u64, attempt:u32, kind:u8, operation:op, args:value, recovery:u8, retry:RetryPolicy, compensation:optional(Compensation)` |
| 3 `Result`                 | `intentSeq:u64, outcome:u8, payload:value, origin:u8`                                                                                         |
| 4 `RetryScheduled`         | `intentSeq:u64, nextAttempt:u32, wakeAt:instant`                                                                                              |
| 5 `RecoveryStarted`        | `intentSeq:u64, recoveryNo:u32, handler:op`                                                                                                   |
| 6 `RecoveryResolved`       | `recoverySeq:u64, disposition:u8, evidence:value`                                                                                             |
| 7 `ScopeOpened`            | `scopeId:u64, path:list(text), parentScope:u64`                                                                                               |
| 8 `ScopeClosed`            | `scopeId:u64`                                                                                                                                 |
| 9 `CompensationRegistered` | `forwardIntent:u64, scopeId:u64, operation:op, args:value, recovery:u8`                                                                       |
| 10 `CompensationRequested` | `scopeId:u64, audit:optional(audit)`                                                                                                          |
| 11 `CompensationFinished`  | `registrationSeq:u64, resultSeq:u64`                                                                                                          |
| 12 `WaitOpened`            | `intentSeq:u64, token:id, topic:text, schema:text, schemaVersion:u32, deadline:optional(instant)`                                             |
| 13 `InputAccepted`         | `token:id, deliveryId:id, payload:value`                                                                                                      |
| 14 `WaitResolved`          | `intentSeq:u64, winner:u8, inputSeq:optional(u64)`                                                                                            |
| 15 `StateChanged`          | `state:u8, reason:u16, relatedSeq:optional(u64), detail:text`                                                                                 |
| 16 `OperatorCommand`       | `audit:audit, command:u8, expectedSeq:u64, args:value`                                                                                        |
| 17 `CodeAdopted`           | `build:text, manifest:digest, checkedSeq:u64, audit:audit`                                                                                    |
| 18 `RunFinished`           | `outcome:u8, payload:value`                                                                                                                   |

`Parent` is `(runId:id, throughSeq:u64, digest:digest, audit:audit,
prefixFrames:bytes, replacement:optional(Replacement))`. `prefixFrames` contains
the complete original frames through `throughSeq`, with no rewritten IDs or
references. Its digest must match the last inherited frame; an empty prefix
uses the zero digest. The child reader indexes this ancestry separately from
its own sequence space. An inherited reference is qualified by its parent run
ID in memory; child wire references name only child records. A fork too large
to fit the child's initial frame/value limits is rejected before its audit
reservation; external ancestry blobs are deferred.

`Replacement` is `(target:step, operation:op, originalArgs:value, args:value)`;
replacement of initial input instead uses the
fork's `RunCreated.input`. `Compensation` is `(scopeId:u64, operation:op,
args:value, recovery:u8)` with arguments known before the forward effect.
Operations needing result-derived undo arguments must preallocate a stable
resource ID or use a recovery handler that reconstructs them before resolving
the forward intent. They cannot postpone registration until unjournaled code
after success.

`RetryPolicy` is `(maxAttempts:u32, initialDelay:duration, multiplier:u32,
maxDelay:duration)`. Counts include attempt zero; `maxAttempts >= 1`;
delays are nonnegative and `multiplier >= 1`. Backoff saturates at `maxDelay`,
with checked arithmetic. Jitter, when used, is a separate recorded random draw.
The registry fixes which domain-error tags are retryable; the manifest pins it.
Eligible domain errors are retried internally before `call` returns, up to
`maxAttempts`. If automatic scheduling is interrupted by an operator pause,
`retry` can schedule the still-eligible next attempt. An exhausted retry budget
returns the last domain error to the program; starting more work after a terminal
failure requires a fork, not an unbounded operator retry.

| Vocabulary           | Wire values                                                                                                      |
| -------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Intent kind          | 0 activity, 1 observation, 2 decision, 3 checkpoint, 4 wait, 5 timer, 6 compensation, 7 scopeControl             |
| Recovery class       | 0 manual, 1 repeatable, 2 deduplicated, 3 reconcile                                                              |
| Result outcome       | 0 success, 1 domainError                                                                                         |
| Result origin        | 0 live, 1 recovered, 2 engine                                                                                    |
| Recovery disposition | 0 completed, 1 safeToRetry, 2 unresolved                                                                         |
| Wait winner          | 0 input, 1 deadline, 2 cancelled                                                                                 |
| Run state            | 0 runnable, 1 waiting, 2 paused, 3 compensating, 4 succeeded, 5 failed, 6 cancelled, 7 terminated, 8 quarantined |
| Operator command     | 0 pause, 1 resume, 2 retry, 3 cancel, 4 terminate, 5 compensate, 6 fork, 7 adoptCode, 8 resolve                  |

**EFF12 — Semantic integrity.** Loading must validate references, contiguous
ordinals, legal states, one terminal result per attempt and one terminal run
outcome. `Intent.ordinal` starts at 1 for each new logical program step;
retry attempts retain its ordinal. Engine compensation intents use a separate
ordinal sequence. `Result.intentSeq` identifies an existing unresolved intent.
Successful results and their compensation registrations commit in one frame.
Scope control records and their matching intent/result also commit together.
An invalid frame or transition quarantines the run before program execution.

`StateChanged.reason` uses `DurableErrorCode` (§12), with zero meaning no error.
`detail` is diagnostic text only and cannot affect replay. `RunFinished` records
the program's encoded success/domain error; its frame also changes state to
`succeeded`/`failed`. Cancel/terminate have no fabricated program return value.
Known control operations use reserved operation/schema names under `effects/`;
applications cannot register that prefix. Scope-control intent arguments name
the action and scope; their engine result contains the scope ID or unit. A wait
deadline/cancellation result uses the reserved durable-error schema rather than
the application input schema. Unknown reserved names are unsupported schemas.

## 7. Recording, replay and uncertain effects

**EFF13 — Write-ahead protocol.** `journal.call` is the sole combinator for
program operations. It must validate and encode inputs, commit an intent to
durable storage, invoke the handler, encode the outcome, commit the result and
any compensation registration, then return the value. Failure to acknowledge
the intent prevents handler invocation. Failure to acknowledge the result
prevents returning the value. An uncertain acknowledgement is resolved by
transaction ID lookup, never by assuming that nothing was stored.

| Historical state of matching step         | Required action                                                                                 |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------- |
| No intent at live frontier                | Commit intent, then invoke                                                                      |
| Completed success or domain error         | Return recorded outcome; no world access                                                        |
| Intent without result                     | Enter recovery by the intent's declared class                                                   |
| Result plus scheduled retry               | Replay the failed attempt internally, honor persisted deadline, advance to the recorded attempt |
| Incompatible args, kind, version or order | Pause as drift; do not invoke                                                                   |

A retryable result without its next `RetryScheduled` is a valid crash prefix.
The engine must apply the same retry policy before returning that result to
the program, commit the missing deadline, and continue or suspend. Computing
that deadline uses a host clock sample whose decision is persisted in
`RetryScheduled`; once present, its value is replayed unchanged. Retry waits
use the durable timer path, never an unrecorded in-process sleep.

**EFF14 — Recovery classification.** An incomplete `manual` operation pauses as
`uncertainEffect`. `repeatable` may be invoked again only under its registered
semantic guarantee that duplication is acceptable. `deduplicated` reuses the
same effect key and requires the receiver to return the same durable answer
for that key. `reconcile` first commits `RecoveryStarted`, then calls its
registered recovery handler with the original request and identity. Recovery
returns completed outcome, safe-to-retry, or unresolved, plus encoded evidence.

Completed recovery commits `RecoveryResolved`, `Result` and compensation
registration together. Safe-to-retry commits `RecoveryResolved` before another
invocation of the same attempt. Unresolved commits the evidence and pauses.
A crash during recovery may repeat the recovery handler; therefore its probes
must be read-only or themselves deduplicated. No arbitrary repair side effect
may hide inside a probe. A new recovery round increments `recoveryNo`; recovery
does not increment the logical attempt counter. Explicit retries after a
completed retryable domain error use `RetryScheduled` and a new intent with the
same key and incremented attempt. Transport ambiguity is not a domain error.

**EFF15 — World observations.** Completed observations, decisions, randomness,
clock reads and human replies replay verbatim. A fresh observation is a new key
at the live frontier. Reconfirmation is an explicit later wait with a new key;
process restart alone neither invalidates a previous approval nor prompts again.
Consumers needing approval tied to a changed resource must include its version
or digest in the approval request and condition the later mutation on that
version. A probe followed by a mutation is subject to a race unless the receiver
offers an atomic precondition or equivalent guard. A local mutable world can
remain unresolved indefinitely; this library must not guess success.

**EFF16 — Guarantee boundary.** Given deterministic program computation, a valid
compatible journal, correct codecs and a store meeting §8, replay of completed
steps must reproduce their outcomes without invoking their handlers. Under
finitely many crashes and eventual successful recovery, repeatable or
deduplicated operations may execute more than once but commit at most one
outcome per attempt. Effectively-once external behavior additionally requires
the receiver's deduplication/reconciliation contract. Manual operations may
execute zero or one times and remain ambiguous; no universal at-least-once
liveness promise applies to a paused run.

This is an implementation obligation, not a proved theorem. [Burckhardt et
al.'s Lemma 6.7][burckhardt] and [Ramalingam and Vaswani's Theorem 3.9][handlers]
motivate transparency tests, but their models do not prove equivalence for
arbitrary external effects in a separately mutable world. Journal writer fencing
does not fence an already-running process or a remote request (§8).

## 8. Journal store, durability and writer fencing

### 8.1 Store concept

<!-- md-example-skip -->

```d
enum bool isJournalStore(S) = __traits(compiles,
    (ref S s, RunId run, WriterId writer, in Claim claim,
     in AppendBatch batch, TransactionId transaction, ulong seq) {
        StoreResult!Claim c = s.acquire(run, writer);
        StoreResult!void r = s.renew(claim);
        StoreResult!Commit a = s.append(claim, batch);
        StoreResult!Lookup l = s.lookup(run, transaction);
        StoreResult!Snapshot h = s.read(run, seq);
        StoreResult!void f = s.release(claim);
    });
```

`Claim` contains run ID, writer ID and epoch; expiry is adapter-owned metadata,
not a workflow input. `AppendBatch` contains a stable transaction ID, expected
last sequence/digest and one or more complete event envelopes. `Commit` returns
the committed final sequence/digest. `Lookup` distinguishes absent from committed
with exact batch bytes/digest; it cannot report absence based on an obsolete
replica. `Snapshot` owns an immutable contiguous committed prefix and its offset.
`read(run, 0)` reads the full current committed prefix; another sequence bounds
it inclusively. The adapter enforces configured read limits before allocation.
Arguments are borrowed for the call; snapshots and receipts own their data.
Acquiring a previously absent run reserves an empty journal. It is not a
published run until its first transaction commits `RunCreated`. Reopening an
empty reservation after process loss is permitted; a committed `RunCreated`
cannot be overwritten by another creator. Fork creation uses these same
primitives for the child and verifies its recorded parent command ID on retry.

**EFF17 — Store linearization.** Acquire, epoch allocation, conditional append
and transaction deduplication must be linearizable for a run. Append atomically
checks an active claim and expected sequence/digest and durably commits all
events or none. Repeating a transaction ID with identical content returns its
original receipt even after a lost acknowledgement; different content is
`transactionConflict`. A stale claim cannot make a new commit. A lock and an
expected-sequence check are separate obligations; neither substitutes for the
other ([journal integrity comparison][comparison]).

### 8.2 Ownership and external fencing

**EFF18 — Writer lifetime.** One episode owns a run claim. Control commands and
input acceptance use that same owner, or acquire ownership after it releases
the claim. They never append beside it. Stores may implement leased claims or
process-lifetime locks; they must document the mechanism and prevent an expired
writer from appending. Epochs monotonically increase across acquisitions and
must never wrap. Renewal failure latches a stop and requests handler cleanup.

Checking a claim before I/O cannot prevent loss immediately afterwards. A stale
worker's external effect can still happen even when its result append is
rejected. Receivers that support fencing receive the epoch and enforce it;
others require duplicate-safe operations or operator recovery. A PID appearing
absent, an expired lease, or a reclaimed journal does not prove a subprocess's
descendants or remote requests stopped. Fencing loss must not be translated
into safe-to-retry evidence.

### 8.3 First persistent adapter

**EFF19 — Local-file adapter.** The initial adapter supports local POSIX
filesystems with documented advisory-lock and `fsync` semantics. Network
filesystems, distributed leases and malicious concurrent file editing are
unsupported. A run directory contains `journal.bin` and a stable `writer.lock`;
the lock file is never replaced while the run exists. The adapter holds an
exclusive kernel lock for the episode. Claim epoch changes are stored durably
in adapter metadata under that lock before returning the claim. The next epoch
must exceed both metadata and every committed frame epoch.

The adapter writes a whole frame, flushes the file before acknowledging, and
flushes the parent directory when creating a run or publishing metadata by
rename. Recovery under the exclusive lock validates every complete frame and
the hash chain. A physically incomplete final frame may be removed to the last
complete boundary and the truncation flushed. A complete frame with invalid
digest, invalid semantics or unknown version quarantines the run; it must not
be treated as a harmless torn tail. Corruption in the middle is never skipped.
The adapter must bound frame length before allocating. Disk-full and short-write
paths never acknowledge a partial frame. Process-kill tests establish process
recovery; power-loss claims additionally require filesystem durability evidence.

## 9. Durable scopes and compensation

**EFF20 — Scope membership.** `openScope` records a named child of the current
scope, returning its journal-derived `ScopeId`; nesting is strictly lexical and
LIFO. `closeScope` must name the innermost open scope and prevents further forward
registrations there. Closing does not erase compensations or execute them.
Durable scopes are journal data, distinct from transient executor scopes.
Successful program return requires every child scope closed. The root scope
exists from run creation with ID 0.
Child scope IDs are contiguous logical scope-creation ordinals beginning at 1,
not frame sequence numbers; a fork continues above its inherited maximum.

**EFF21 — Persistent undo descriptors.** Forward intents contain compensation
name, version, arguments and scope before invoking the effect. A successful
result atomically activates a `CompensationRegistered` descriptor. A failed
effect that partially changed the world must first be reconciled; a domain error
does not imply absence of effects. Registrations never contain closures.

`compensate(key, scope)` and the operator command explicitly append a request.
The engine first resolves any uncertain forward attempt in that scope; it may
pause and require evidence. It freezes forward execution for the scope and its
descendants, then visits active registrations in reverse registration sequence.
The first version is sequential, so this defines LIFO without claiming a law
for concurrent branches ([compensation calculi][calculi]). Closed descendants
are included. Already finished compensations are skipped.

**EFF22 — Resumable compensation.** Each compensation is an ordinary journaled
operation in the compensation identity domain, with its own intent, attempts
and result. Success and `CompensationFinished` commit together. Failure stops
the sweep at that entry; explicit retry resumes it before earlier entries.
An uncertain compensation obeys its declared recovery class. Compensation never
registers another compensation. A second request on a fully compensated scope
is a recorded no-op. The engine can load descriptors and perform an
operator-requested sweep without replaying workflow code, but must have the
pinned handler versions available.

After a program-requested sweep completes, the original `compensate` call gets
its result and execution may continue outside the compensated scope. An
operator-requested sweep leaves the run paused (or preserves its prior terminal
state); it does not resume forward work. Automatic rollback on exception,
process death, cancellation or scope exit is forbidden. This combines the
persistent registration discipline of [Sagas][sagas] with explicit invocation;
it does not promise restoration of the world to a past snapshot.

## 10. Suspension, input and cancellation

**EFF23 — Durable waits.** A wait commits its intent and `WaitOpened` atomically
before publishing its token. `WaitSpec` contains a topic, accepted schema and
optional absolute deadline. Missing deadline explicitly means unbounded wait.
A timer is the same protocol with no input token exposed and a mandatory
deadline. A waiting episode returns `EpisodeResult.waiting` with a descriptor;
there is no captured continuation. The host may retain a process for efficiency,
but short and long waits use the same committed protocol.

**EFF24 — Input acceptance.** `deliver(run, token, deliveryId, payload)` returns
`accepted`, `duplicate`, `alreadyResolved`, `unknownWait` or a structured error.
The first valid delivery commits `InputAccepted`, `WaitResolved` and the wait's
`Result` atomically. Same delivery ID and bytes is a duplicate with the original
receipt; reused delivery ID with different bytes is `inputConflict`. Another
delivery to a resolved wait returns `alreadyResolved`. Wrong schemas leave the
wait unchanged. Tokens are addresses, not authentication credentials; the host
authenticates and authorizes senders. Tokens are 128-bit host-generated unique
values persisted before use; a detected collision is rejected before publication.

Deadline resolution and delivery are serialized by the writer. At adjudication,
the host clock is sampled: if `now >= deadline`, the deadline wins, including
an input first processed after that instant. Otherwise a valid input wins.
The chosen winner and result commit together; once committed the clock is not
consulted again for that wait. A crash before the transaction may change the
winner because no winner was committed. Hosts must document clock accuracy;
the library does not promise a monotonic wall clock. Publishers must retry
unacknowledged delivery; no in-memory inbox is durable acceptance.

**EFF25 — Host scheduling.** Waiting descriptors expose the run, wait key,
token/topic and deadline to the host, which owns wake-up scheduling. On restart,
enumerating waiting runs and checking deadlines must suffice to recover missed
wake-ups. A library without a running host makes no wake-up liveness promise.
Transport hints may wake an owner but never become program input until accepted
into the journal. [Restate][restate], [Effect workflow][effect-workflow] and
[Golem][golem] provide the wait/token precedent.

**EFF26 — Cancel and terminate.** Cancellation is a journaled request delivered
at the next durable boundary. It cancels a pending wait with a recorded result
or asks an active handler to clean up; recorded completed steps still replay
before that boundary. The row returns cancellation and permits only explicitly
requested compensation/cleanup controls thereafter. The host records
`cancelled` when the program returns. No compensation starts merely because
cancellation was requested.

Termination records `terminated` and forbids further program progress without
giving it a cleanup turn. The host separately owns stopping the process and
its external work. This cannot undo committed external effects or guarantee
that a remote call has ceased. If an owner is busy, a command is not
acknowledged as durable until it is appended by that owner or a legitimate
successor. A blocked host may need an external process stop before claim
reacquisition. Cancellation and termination differ as in [Temporal][temporal]
and [Restate][restate], without assuming their server infrastructure.

## 11. Operator surface, forks and projections

### 11.1 Commands

<!-- md-example-skip -->

```d
OperatorResult inspect(Store)(ref Store store, RunId run);
OperatorResult command(Store, Registry)(ref Store store, ref Registry registry,
    RunId run, in Command request);
ValidationResult validateReplay(alias program, Registry)(
    in Snapshot history, ref Registry registry);
ForkResult forkRun(Store)(ref Store store, RunId parent, RunId child,
    in ForkRequest request);
DeliveryResult deliver(Store)(ref Store store, RunId run, WaitToken token,
    DeliveryId delivery, in EncodedValue payload);
```

**EFF27 — Audited transitions.** Mutating commands carry command ID, expected
offset, actor and reason. The operation and audit append atomically; the host
authenticates before append. Exact duplicate commands return their previous
receipt; reused IDs with changed content conflict. A stale expected offset
returns `staleRevision`, with no command applied. Inspect is read-only.

State is a fold of control records, not an instruction to repeat every old
pause during replay. Resumed pauses and completed sweeps remain audit history.
A still-pending cancellation is delivered at the program frontier identified by
the command's offset, after the completed program prefix has replayed. Host
control may stop a live operation immediately, but its outcome is not exposed
to the program until recorded. Wait resolution while operator-paused records
the result and retains `paused`; otherwise it changes `waiting` to `runnable`.
Opening an unresolved wait changes `runnable` to `waiting`. Scope compensation
changes the state to `compensating` and returns to the continuation state defined
in §9. No other implicit transition out of a terminal state is permitted.

| Command    | Valid states and effect                                                                 |
| ---------- | --------------------------------------------------------------------------------------- |
| pause      | runnable/waiting; stop forward work at a boundary, retain unresolved work               |
| resume     | paused; retry replay; unresolved drift or uncertainty pauses again                      |
| retry      | paused with completed retryable domain failure; schedule next allowed attempt           |
| cancel     | runnable/waiting/paused; deliver §10 cancellation at a boundary                         |
| terminate  | any nonterminal nonquarantined state; forbid forward execution                          |
| compensate | paused or terminal, excluding quarantined; sweep a named scope explicitly               |
| fork       | valid readable paused or terminal history; create a separate run (§11.2)                |
| adoptCode  | paused or terminal; require §5 validation at this offset                                |
| resolve    | paused on uncertain intent; record attested completed outcome or safe-to-retry evidence |

Invalid commands return `invalidState`. Succeeded, failed, cancelled and
terminated are terminal for forward execution. Quarantine forbids execution,
forking and compensation until an offline repair supplies a valid readable
artifact; repair is not an in-place journal-edit API. An unsupported codec can
be addressed by installing a compatible reader, which must revalidate the whole
history before removing quarantine. A corrupt journal's quarantine diagnostic
is adapter metadata when appending to that journal would be unsafe.

Operator `resolve` uses the same recovery records and atomic result/registration
rules as §7, records the command audit, and validates all supplied schemas. It
is an attestation by the operator, not a fact established by the engine. It
cannot replace an already committed outcome. Transient host failure returns an
episode error without making up a domain failure. A paused run preserves its
record for diagnosis instead of silently retrying indefinitely.

### 11.2 Fork contract

**EFF28 — Immutable ancestry.** A fork names a fresh run ID and a boundary just
before a selected logical step, or the beginning for replacement initial input.
The parent must be paused or terminal, and the inherited prefix must contain
only resolved program steps and complete atomic frames. No pending wait,
uncertain effect or compensation sweep may cross the boundary. Scope-open
records may be inherited. The source remains unchanged except for its audit
command. The child stores an immutable copy of the prefix, identified by parent
ID, final sequence and digest; it does not depend on a mutable parent file.

Fork creation uses a command-ID reservation for the child ID. The parent first
commits the fork command; the child is published atomically with `RunCreated`
and its ancestry/prefix artifact. A crash between them leaves an inspectable
pending fork; retrying the same command completes creation, never creates a
second child. `forkRun` acknowledges only after the child is durable. The child
validates prefix bytes/digest before running and is initially paused.

Inherited control records explain ancestry but do not pause, terminate or issue
commands against the child. The child reuses the prefix's program answers,
logical ordinals and scope membership; its own control state comes from its own
frames. Completed ancestor input deliveries do not make a child token live.

Inherited calls replay against the copied prefix. At the selected frontier,
the child creates new intents using its own run ID, so effects in the discarded
suffix can happen again. Replacement operation arguments are injected once at
that frontier after matching target identity and operation version; the new
intent records the replacement bytes. Later child replay checks the program's
originally computed arguments against the saved pre-replacement request, then
applies the same override. Both original and replacement requests must be kept
in the fork artifact. A mismatch in either identity or original request pauses.
Replacing initial input instead starts from an empty prefix with the new input.

Forking does not reverse external effects in the parent's suffix. A fork request
must include explicit acknowledgement of that consequence in its audited args.
Inherited compensation registrations are visible but not executable in the child:
they refer to shared ancestor effects. Compensation of those effects must be
requested against the owning ancestor run. New child effects register child-owned
compensations. The host must prevent simultaneous forward execution of parent
and child if their domain requires exclusion; the library does not infer it.

### 11.3 Projection and presentation

**EFF29 — Projection.** `inspect` folds a committed snapshot into a bounded run
view: state, last sequence/digest, current build/manifest, scopes, pending step,
attempt counts, waits, compensation status, lineage and audit entries. A view
must carry the offset it represents. UI rendering consumes that view, never
performs program effects. Program-facing replay flags are unnecessary.
Missing progress events do not alter execution. Rebuilding the view from the
same prefix must yield the same state ([event-sourced projections][marten]).

Payloads may contain secrets, command output or human text. Inspect defaults to
schema names, lengths and identities, not raw payloads; revealing values is an
explicit host decision. Redaction applies to presentation, not destructive edits
to canonical replay bytes. The store owner controls access, retention and
encryption at rest. Format 1 provides integrity detection, not confidentiality.

## 12. Errors, limits and testing contract

### 12.1 Closed error vocabulary and limits

`DurableError` contains `code:u16`, `relatedSeq:optional(u64)` and bounded
`detail:text`. Details are diagnostic, never control flow. Host I/O errors may
add a numeric native error as structured adapter data; applications branch on
the durable code, not its prose.

| Code | Name                | Required response                                     |
| ---- | ------------------- | ----------------------------------------------------- |
| 0    | none                | No error                                              |
| 1    | invalidInput        | Reject before effect                                  |
| 2    | duplicateStep       | Pause before duplicate effect                         |
| 3    | drift               | Pause at first mismatch                               |
| 4    | incompatibleCode    | Refuse episode                                        |
| 5    | unsupportedSchema   | Refuse new call; quarantine unreadable history        |
| 6    | corruptJournal      | Quarantine                                            |
| 7    | staleWriter         | Stop episode and request cleanup                      |
| 8    | staleRevision       | Reject mutation                                       |
| 9    | transactionConflict | Reject mutation                                       |
| 10   | storeUnavailable    | Stop episode; preserve uncertain commit status        |
| 11   | uncertainEffect     | Pause                                                 |
| 12   | resourceExhausted   | Stop before new intent, or recover outstanding intent |
| 13   | invalidState        | Reject control operation                              |
| 14   | inputConflict       | Reject delivery                                       |
| 15   | reentrantOperation  | Latch episode stop                                    |
| 16   | cancelled           | Deliver cancellation                                  |
| 17   | suspended           | Return waiting episode                                |
| 18   | terminated          | Refuse forward execution                              |
| 19   | deadlineExceeded    | Recorded wait result                                  |

`Limits` serializes these `u32` fields in table order, then `maxJournalBytes:u64`:

| Field             | Default |
| ----------------- | ------- |
| `maxKeyBytes`     | 256     |
| `maxScopeDepth`   | 64      |
| `maxValueBytes`   | 16 MiB  |
| `maxFrameBytes`   | 64 MiB  |
| `maxSteps`        | 100,000 |
| `maxAttempts`     | 100     |
| `maxCodecDepth`   | 64      |
| `maxDetailBytes`  | 4,096   |
| `maxJournalBytes` | 1 GiB   |

All limits are positive; a host may impose tighter read limits and refuse the
run rather than truncate data. Frame/value maxima must fit their wire widths;
oversize input is rejected before intent. Result overflow after an effect
leaves its intent uncertain; handlers must bound their output and expose
truncation in a registered result when that is an intended domain behavior.
No result may be silently shortened. Capacity for mandatory terminal/control
frames must be reserved when admitting new intents; disk exhaustion remains a
recoverable store failure even with this logical reservation.

**EFF30 — Bounded recovery.** Every length, count, sequence and attempt increment
must use checked arithmetic. Limits apply before allocation or traversal. At
capacity, refuse new work and preserve the readable journal; never discard
history to continue. Replay is O(journal bytes + re-executed program work), with
index memory O(steps + waits + compensation registrations). There is no bound
on arbitrary user computation. Continue-as-new is deferred until input carry,
lineage and compensation ownership have a separate accepted contract.

### 12.2 Verification obligations

**EFF31 — Independent fault oracle.** `MemoryJournal` must model volatile versus
durable data, atomic batches, lost acknowledgements, stale claims, short writes,
corruption and resource limits. The harness must compare a reference state
machine and scripted world's externally observable trace, not merely run the
same parser twice. The seed and exact fault schedule must be printable and
replayable. [Deterministic simulation][dst] and [Resonate][resonate] are precedents.

**EFF32 — Crash boundaries.** For each representative program, cut every durable
event boundary and every persistence/effect seam: before intent commit, after
intent but before invocation, after external mutation but before result,
after result commit but before acknowledgement, and during recovery and
compensation. Cuts inside an atomic frame expose either the old or whole new
frame, never a partial logical transaction. Compare program output, logical
step outcomes and world invariants with an uninterrupted run when the operation
contracts permit equivalence. Compare normalized semantic histories; writer
epochs, recovery/audit records and measured timing legitimately differ.

**EFF33 — Mutation and negative tests.** Mutate external state after each crash,
including after a completed observation and between reconciliation probe and
mutation. Assert completed handlers are not invoked, incomplete operations use
their declared policy, ambiguity pauses, and failed fencing never authorizes
retry. Include changed/deleted/reordered steps, changed checkpoint and terminal
values, plus an intentionally undetectable internal computation change to
document the detector's limit. Test named-loop collisions, all invalid event
references, every wait race/duplicate, repeated compensation failures, fork
publication crashes and ancestor compensation exclusion.

**EFF34 — Boundary verification.** Compile-negative tests cover raw clock/I/O
access from the restricted program, raw handler escape, nonrecordable values
and ignored control errors followed by attempted effects. Compiler tests cover
both debug and checked builds, aliasing, inlining and supported LDC/DMD versions.
Storage integration tests exercise process kills, two writers, lock release,
partial tails, acknowledged-data recovery and disk-full behavior. Unsupported
host facilities are recorded as skips, never conformance passes.

The [catalog example][example] is a mechanism demonstration, not an oracle for
external crash windows or the complete schema above. Publication checks prove
rendering and navigation only. Delivery gates and outstanding evidence remain
in [PLAN.md](./PLAN.md).

<!-- References -->

[concepts]: ../../research/algebraic-effects/durable-execution/concepts.md
[comparison]: ../../research/algebraic-effects/durable-execution/comparison.md
[replay]: ../../research/algebraic-effects/durable-execution/deterministic-replay.md
[helland]: ../../research/algebraic-effects/durable-execution/idempotence.md
[inngest]: ../../research/algebraic-effects/durable-execution/inngest.md
[effect-workflow]: ../../research/algebraic-effects/durable-execution/effect-workflow.md
[cloudflare]: ../../research/algebraic-effects/durable-execution/cloudflare-workflows.md
[sagas]: ../../research/algebraic-effects/durable-execution/sagas.md
[marten]: ../../research/algebraic-effects/durable-execution/marten.md
[akka]: ../../research/algebraic-effects/durable-execution/akka-pekko-persistence.md
[restate]: ../../research/algebraic-effects/durable-execution/restate.md
[wal]: ../../research/algebraic-effects/durable-execution/write-ahead-logging.md
[handlers]: ../../research/algebraic-effects/durable-execution/effect-handlers-record-replay.md
[golem]: ../../research/algebraic-effects/durable-execution/golem.md
[temporal]: ../../research/algebraic-effects/durable-execution/temporal.md
[burckhardt]: ../../research/algebraic-effects/durable-execution/burckhardt-durable-functions-semantics.md
[calculi]: ../../research/algebraic-effects/durable-execution/compensation-calculi.md
[dst]: ../../research/algebraic-effects/durable-execution/deterministic-simulation-testing.md
[resonate]: ../../research/algebraic-effects/durable-execution/resonate.md
[example]: ../../research/algebraic-effects/durable-execution/examples/replay-journal.d
[eh-layout]: ../event-horizon/SPEC.md#_2-package-and-module-layout
[eh-supervise]: ../event-horizon/SPEC.md#_13-5-supervised-runs-m19
