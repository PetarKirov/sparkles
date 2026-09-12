# Concepts and Vocabulary

The shared vocabulary of durable execution, defined once here and used by every
deep-dive in this catalog. The field has no agreed terminology: the same idea is
a _step_ in [Inngest] and [Cloudflare Workflows][cloudflare], an _activity_ in
[Temporal] and [Azure Durable Functions][azure], a _journal entry_ in
[Restate], an _oplog entry_ in [Golem], and an _operation output_ in
[DBOS]. This page fixes one name per idea and records what each system calls it.

**Last reviewed:** September 12, 2026.

---

## The core idea

**Durable execution** is the technique of making a long-running program survive
the death of the process running it, by recording the results of its effects and
re-deriving everything else. It is not checkpointing: nothing of the program's
stack, heap, or local variables is saved. What is saved is a **journal** of
answers, and the program is expected to ask the same questions again.

A **durable program** (the catalog's umbrella term for what systems variously
call a workflow, an orchestration, or a durable function) is therefore split in
two:

| Part            | Property required                                       | Persisted?                    |
| --------------- | ------------------------------------------------------- | ----------------------------- |
| The **program** | deterministic between effects                           | no — re-executed from scratch |
| Its **effects** | may be arbitrary, may fail, may touch the outside world | yes — result recorded         |

> [!IMPORTANT]
> Every system in this catalog that replays enforces the same asymmetry: the
> program must be a pure function of the journal, and everything impure must go
> through the effect boundary. Systems differ almost entirely in _how_ that
> boundary is named, identified, and policed.

---

## Program and effect

### Durable program

The re-executed function. [Temporal] and [Azure Durable Functions][azure] call
it an **orchestration** or **orchestrator function**; [Effect][effect-workflow]
and [Cloudflare][cloudflare] a **workflow**; [DBOS] a **workflow function**;
[Restate] a **handler** (of a service, virtual object, or workflow); [Golem] a
**worker** (an instance of a WebAssembly component); [Vercel][vercel] marks one
with the `"use workflow"` directive. [Inngest] calls it a **function** and
re-invokes it over HTTP for every step.

### Activity (or step)

One journaled effect. The boundary across which nondeterminism, I/O, and failure
are allowed. Named `Activity.make` in [Effect][effect-workflow], `step.run` in
[Inngest], `step.do` in [Cloudflare][cloudflare], `ctx.run` in [Restate],
`@DBOS.step()` in [DBOS], an **activity function** in [Temporal] and
[Azure][azure], and a `"use step"` function in [Vercel][vercel]. In [Golem] the
boundary is implicit: every WASI host call is journaled, with no user-visible
step construct.

The defining property is the same everywhere: **an activity's result is recorded,
so on replay the activity does not run** — its recorded value is returned in
place of executing it.

### Journal (or history, event log, oplog)

The append-only record of what the activities answered. [Temporal] calls it the
**event history** (a sequence of `HistoryEvent` protobufs owned by the server);
[Azure][azure] and [Dapr/DTFx][dapr] the **history** (`TaskScheduled`,
`TaskCompleted`, `TimerFired`, …); [Restate] the **journal** (commands and
notifications); [Golem] the **oplog**; [DBOS] the `operation_outputs` table;
[Inngest] the **op stack**, keyed by hashed step id.

A journal entry is conventionally a **pair**, not a single record: an intent
written before the effect and a result written after it. Temporal's
`ActivityTaskScheduled`/`ActivityTaskCompleted` and Restate's
`RunCommand`/`RunCompletion` are the same shape, and it is the shape
[write-ahead logging][wal] has required since ARIES: the log record describing a
change reaches stable storage before the change does.

### Replay

Re-running the durable program from its first instruction, answering each
activity from the journal until the journal is exhausted, after which execution
goes **live** again. Most systems expose a flag for the phase
(`IsReplaying` in [Azure][azure], [Dapr][dapr] and [Netherite][netherite],
`context.df.isReplaying` in the JavaScript SDK) so that logging and other
unjournaled side effects can be suppressed during it.

### Suspension

Ending the process deliberately while the program is logically still running:
at a long timer, an external event, or a child workflow. Because there is no
continuation to save, suspension is just "stop, and replay later" —
[Effect][effect-workflow] models it as a self-interrupt that persists a
`Suspended` outcome, [Restate] as a first-class protocol state, and
[Temporal] as simply not scheduling another workflow task. The contrast case is
[Trigger.dev][trigger], which suspends by checkpointing the operating-system
process instead.

---

## Identity and matching

### Step identity

How a replayed call is matched to its recorded answer. This is the single
sharpest axis of variation in the catalog, and it takes three forms:

| Scheme         | Key                                     | Systems                                                                       | Breaks when                                               |
| -------------- | --------------------------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------- |
| **Positional** | an ordinal counter assigned in order    | [Temporal], [Azure][azure], [Dapr/DTFx][dapr], [DBOS], [Restate], [Netherite] | a step is inserted, removed, or reordered                 |
| **Named**      | a developer-supplied string (+ attempt) | [Inngest], [Cloudflare][cloudflare], [Effect][effect-workflow]                | two steps share a name; a rename silently re-executes     |
| **Derived**    | a hash of parent id and call site       | [Resonate] (promise ids), [Golem] (idempotency keys)                          | the derivation captures something that legitimately moves |

No system in the catalog makes the **arguments** part of the key, and only
[Restate] compares them at all (as a mismatch _check_, per command type, not as
the key). [Helland][idempotence] is the one source arguing that it should be a
function of the whole request: a retry that differs in its arguments is a
different request, not a repeat of the same one.

### Divergence (nondeterminism error, journal mismatch)

The error raised when the replayed program asks for something the journal does
not have at that position. Temporal's is `[TMPRL1100]`; Restate's is
`JOURNAL_MISMATCH` (RT0016), with a per-handler policy of `retry`, `pause` or
`fail`; DBOS raises `DBOSUnexpectedStepError`; DTFx raises
`NonDeterministicOrchestrationException`, which in Dapr stalls the instance
rather than corrupting it.

> [!WARNING]
> Divergence detection is **partial in every system surveyed**. All of them
> compare the step's identity and usually its name; none compares its arguments
> as a matter of course, so a changed argument to an already-journaled step is
> invisible. [Inngest]'s own SDK specification mandates a warning when step
> order changes, and its current engine never raises one.

### Idempotency key

A caller-supplied unique id that makes a repeated request a lookup rather than a
second execution. It appears as the workflow/run id ([DBOS]'s `workflowID`,
[Temporal]'s workflow id, [Cloudflare][cloudflare]'s instance id), as an
explicit key on an invocation ([Restate]), as the primary key of a durable
promise ([Resonate]), or as a storage-level uniqueness constraint
([Effect][effect-workflow]'s `UNIQUE (message_id)`). [Helland][idempotence]
names the general requirement: the recipient must remember what it has already
processed, and must return the _same_ answer to a duplicate.

---

## Guarantees

### At-least-once, exactly-once, effectively-once

An activity that has run but whose result has not yet been journaled will run
again after a crash. That window cannot be closed, only narrowed, so **activity
execution is at-least-once in every replay system in this catalog**.

What can be exactly-once is the _recorded outcome_: the journal admits one
answer per step. [Burckhardt et al.][burckhardt] prove this for the internal
state of a durable function, and explicitly exclude external calls from the
result, because "duplication of external calls (unlike internal calls) is
observable". [DBOS]'s documentation states the split plainly: steps get
at-least-once guarantees, workflow outcomes are persisted exactly-once.

**Effectively-once** is the composite property the field actually delivers:
at-least-once execution plus idempotent effects. It is a property of the
_effects_, not of the engine.

### Determinism

The requirement that the program produce the same sequence of activity calls
given the same sequence of answers. Systems enforce it along a spectrum:

| Degree                 | Mechanism                                                                          | Systems                                          |
| ---------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------ |
| **By construction**    | every nondeterministic input is a logged event; state transition is a pure fold    | [Netherite], [Burckhardt's calculus][burckhardt] |
| **By substitution**    | the runtime replaces the clock, RNG, timers, and scheduler with journaled versions | [Temporal], [Azure][azure], [Restate]            |
| **By sandbox**         | the host language's nondeterministic APIs are patched or removed                   | [Temporal] (TypeScript v8 isolate)               |
| **By static analysis** | an analyzer flags forbidden calls in orchestrator code                             | [Azure][azure] (.NET only)                       |
| **By discipline**      | documented rules, detected after the fact if at all                                | [Inngest], [DBOS], [Cloudflare][cloudflare]      |

The substituted primitives recur across systems: a **journaled clock** (Azure's
`currentUtcDateTime` is the orchestration episode's start timestamp; Dapr's
`NewGuid` is a UUID v5 derived from journal-stable inputs) and a **seeded
random** (Restate's `ctx.rand`).

---

## Failure and rollback

### Compensation

A semantic undo: an action that reverses the _business_ effect of a completed
step, rather than restoring a previous state. The concept and its guarantee come
from [Sagas][sagas] (1987), which pairs each sub-transaction `T1..Tn` with a
compensating transaction `C1..Cn-1` and runs the compensations in reverse on
failure.

Almost no engine in this catalog provides it. [Effect][effect-workflow]'s
`withCompensation` is the exception, registering a scope finalizer that runs
LIFO on failure. Everywhere else — [Temporal], [Dapr][dapr], [Azure][azure],
[DBOS], [Restate], [Inngest] — the documented answer is a **pattern**: keep a
list of closures, reverse it in a `catch`. The [compensation calculi][calculi]
supply the laws that pattern is silently relying on, including the result that
compensations of _concurrent_ steps are themselves concurrent and do not depend
on the observed interleaving.

### Forward recovery

Retrying the failed step instead of undoing the completed ones. [Sagas][sagas]
treats it as a first-class alternative, using save-points; the compensation
calculi give it a separate operator. Most engines implement it as per-step retry
policies with backoff, and reserve "failure" for the case where retries are
exhausted.

---

## Growth, evolution and observation

### Snapshot, checkpoint, continue-as-new

Replay cost grows with journal length, so every system bounds it. [Netherite]
and [Akka/Pekko][akka] write periodic **state snapshots** beside the log.
[Temporal], [Azure][azure] and [Dapr][dapr] instead offer
**continue-as-new**: end the current execution and start a fresh one with the
carried-over state as its argument, truncating the history to a single entry.
[Golem] is the one system that can snapshot the _program_, not just its state,
via a component-exported save/load pair.

### Versioning

Running new code against a journal written by old code. The approaches are:
inline **patch markers** ([Temporal]'s `GetVersion`/`patched`, [DBOS]'s
`DBOS.patch()`, [Dapr][dapr]'s `IsPatched`), **pinning** an in-flight execution
to the code version that started it ([Restate]'s `PinnedDeployment`,
[Temporal]'s Worker Versioning, [Azure][azure]'s versioned orchestrations), or
**side-by-side deployment** with drain. In the event-sourcing tradition the
equivalent is an **upcaster** ([Marten], [Akka/Pekko][akka]'s `EventAdapter`):
a function that reads an old event shape into the new one.

### Projection

A read model derived by folding the journal, kept separate from the journal
itself and carrying the **offset** it reflects. Standard in event sourcing
([Kurrent]'s catch-up subscriptions, [Marten]'s async daemon and its
`mt_event_progression` table, [Akka/Pekko][akka]'s `persistence-query`), and the
same mechanism [Netherite] uses internally when it validates that folding an
event onto a freshly deserialized state equals folding it onto the live one.

### Journal versus world

The question this catalog exists to answer for `sparkles`: when the recorded
journal and the current state of the outside world disagree, which is
authoritative?

Every replay engine surveyed answers **the journal**, and can do so only because
it forbids the program from observing the world outside an activity. The world
is then reached exclusively through at-least-once effects that the receiver is
expected to deduplicate. [ARIES][wal] is the one source that reconciles rather
than dictating: redo is applied conditionally, by comparing the log record's
sequence number against the one stamped on the page itself. [Helland][idempotence]
supplies the framing for when reconciliation is impossible — memories, guesses
and apologies — and [the compensation calculi][calculi] state the underlying
constraint directly: the real world cannot be check-pointed.

---

## Testing vocabulary

**Replay test.** Run new code against a stored journal and assert it does not
diverge. [Temporal]'s `WorkflowReplayer` makes this a CI gate against real
production histories.

**Crash-at-every-index.** Truncate the journal after each entry, resume, and
assert the final journal equals the uninterrupted one. No system surveyed ships
this; [Burckhardt's][burckhardt] Lemmas 6.6 and 6.7 state it as a property, and
the [example program](./examples/replay-journal.d) in this catalog demonstrates
it in about 200 lines of D.

**Deterministic simulation testing.** Own the scheduler, clock, network and
disk; draw fault schedules from a seed; replay a failing seed exactly. See
[deterministic simulation testing][dst] for FoundationDB, TigerBeetle and
Antithesis, and [deterministic record and replay][replay] for the process-level
tradition that precedes it.

---

## Sources

Each term above is grounded in the deep-dive it links to; those pages carry the
primary citations. The terminology-fixing sources for this page are:

- [Sagas][sagas] — compensation, backward and forward recovery
- [ARIES][wal] — write-ahead logging, repeating history, compensation log records
- [Helland][idempotence] — idempotence, uniquifiers, the outside world
- [Burckhardt et al.][burckhardt] — the formal replay semantics and its exactly-once boundary

<!-- References -->

[akka]: ./akka-pekko-persistence.md
[azure]: ./azure-durable-functions.md
[burckhardt]: ./burckhardt-durable-functions-semantics.md
[calculi]: ./compensation-calculi.md
[cloudflare]: ./cloudflare-workflows.md
[dapr]: ./dapr-workflow.md
[DBOS]: ./dbos.md
[dst]: ./deterministic-simulation-testing.md
[effect-workflow]: ./effect-workflow.md
[Golem]: ./golem.md
[idempotence]: ./idempotence.md
[Inngest]: ./inngest.md
[Kurrent]: ./kurrentdb.md
[Marten]: ./marten.md
[Netherite]: ./netherite.md
[replay]: ./deterministic-replay.md
[Resonate]: ./resonate.md
[Restate]: ./restate.md
[sagas]: ./sagas.md
[Temporal]: ./temporal.md
[trigger]: ./trigger-dev.md
[vercel]: ./vercel-workflow.md
[wal]: ./write-ahead-logging.md
