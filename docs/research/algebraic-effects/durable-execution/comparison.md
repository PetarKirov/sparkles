# Comparison and Analysis

The capstone synthesis of this catalog: what the surveyed systems agree on, where
they genuinely differ, and where `sparkles` stands against them. Terminology is
fixed in [Concepts and Vocabulary][concepts].

**Last reviewed:** September 12, 2026.

---

## Reading this comparison correctly

Three families are surveyed here, and conflating them produces nonsense
comparisons:

| Family                  | What is persisted                       | What re-executes                | Subjects                                                                                                                                                                |
| ----------------------- | --------------------------------------- | ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Replay engines**      | a journal of effect results             | the whole program, from the top | [Effect][effect-workflow], [Temporal], [Restate], [DBOS], [Azure][azure], [Dapr/DTFx][dapr], [Inngest], [Cloudflare][cloudflare], [Vercel][vercel], [Resonate], [Golem] |
| **Contrast cases**      | a process image, or interpreter state   | nothing                         | [Trigger.dev][trigger] (CRIU process snapshot), [AWS Step Functions][asf] (JSON state machine)                                                                          |
| **Event-sourced state** | a log of domain events (plus snapshots) | a pure fold, never the program  | [Akka/Pekko][akka], [Orleans], [KurrentDB][kurrent], [Marten]                                                                                                           |

The third family is included because `sparkles` borrows its journal-plus-
projection shape, not its programming model. An event-sourced actor never
re-executes a command handler; it folds events into state. A replay engine
re-executes everything and folds nothing.

---

## Master matrix

| System                             | Persistence                      | Step identity                      | Divergence detection                                | Compensation primitive           | Versioning strategy                         |
| ---------------------------------- | -------------------------------- | ---------------------------------- | --------------------------------------------------- | -------------------------------- | ------------------------------------------- |
| [Effect workflow][effect-workflow] | replay                           | name + attempt                     | none (schema decode failure only)                   | **yes** — scope, LIFO            | none                                        |
| [Temporal]                         | replay                           | positional counter                 | command/event mismatch (`TMPRL1100`)                | no — documented pattern          | patch markers + worker pinning              |
| [Restate]                          | replay                           | positional + per-type header check | `JOURNAL_MISMATCH`, policy `retry`/`pause`/`fail`   | no — documented pattern          | immutable pinned deployments                |
| [DBOS]                             | replay                           | positional `function_id`           | name-at-position (`DBOSUnexpectedStepError`)        | no                               | `application_version` + `DBOS.patch()`      |
| [Azure Durable Functions][azure]   | replay + entity snapshot         | positional ordinal                 | sequence/name mismatch                              | no — documented pattern          | versioned orchestrations, side-by-side hubs |
| [Dapr / DTFx][dapr]                | replay                           | positional `idCounter`             | mismatch → instance **stalls**                      | no — documented pattern          | `VersioningSettings` + `IsPatched`          |
| [Inngest]                          | replay                           | hashed name + `:n` repeat          | spec mandates a warning; engine raises none         | no                               | none (rename to re-run)                     |
| [Cloudflare Workflows][cloudflare] | replay                           | name + occurrence count            | none (pure key lookup)                              | **yes** — `rollback`, LIFO       | **undocumented**                            |
| [Vercel Workflow][vercel]          | replay                           | seeded deterministic ULID draw     | **`ReplayDivergenceError`** (unconsumed events too) | no — documented pattern          | pinned to starting deployment               |
| [Resonate]                         | replay                           | derived promise id (`root:1.2.3`)  | none                                                | no                               | function-level version registry             |
| [Golem]                            | replay + optional state snapshot | positional + structural claim      | `UnexpectedOplogEntry`                              | **yes** — SDK transactions, LIFO | **prove-by-replay**, or snapshot migration  |
| [Trigger.dev][trigger]             | snapshot                         | n/a                                | n/a                                                 | no                               | run pinned to worker version                |
| [AWS Step Functions][asf]          | state machine                    | n/a                                | n/a                                                 | no — graph edges                 | execution pinned to version at start        |

---

## The dimensions

### 1. Step identity: positional dominates, naming is the newer answer

Six of eleven replay engines key a step by **its ordinal position** in the call
sequence. Three key it by a **developer-supplied name**. Two **derive** a key
from the call's ancestry.

The cost of positional identity is stated most bluntly by [Dapr/DTFx][dapr],
whose own error message asks whether "a change made to the orchestrator code
after this instance had already started running" caused the mismatch: inserting,
removing, or reordering a call breaks every in-flight instance, which is
precisely why the positional systems are also the ones that needed to invent
patch markers ([Temporal]'s `GetVersion`, [DBOS]'s `DBOS.patch()`,
[Dapr][dapr]'s `IsPatched`). The name-keyed systems need no such mechanism:
[Inngest] can add, remove and reorder steps freely, because an orphaned memo is
simply never looked up.

**No durable-execution system makes the arguments part of the key.** Only
[Restate] compares them at all, as a per-command-type header equality _check_
rather than as the key, and it deliberately excludes computed fields (a
`Sleep`'s wake-up time is ignored, only its name is compared).
[Helland][idempotence] is the sole source arguing the key should be a function
of the whole request, on the grounds that a retry carrying different arguments
is a different request.

The event stores disagree with each other on what to do about it, and the
disagreement is worth preserving rather than resolving prematurely.
[KurrentDB][kurrent]'s idempotence rule is strong when an explicit version is
given — same stream, same event id, same event number — and a violation is
refused as corrupted idempotency rather than reconciled. [Restate]'s is a check
with three configurable outcomes (`retry`, `pause`, `fail`). So one tradition
says an argument mismatch is a different step, the other says it is the same
step reporting drift. They differ in what a resumed run should do next, and
that is a decision, not a detail.

[Deterministic record and replay][replay] then bounds how much an argument
comparison can buy at all. `rr` compares the **entire register file at every
event**, including scheduling events the program never requested; an argument
hash only fires when the program issues an op. A program that consumes a
replayed value differently but goes on to issue the same op with the same
arguments replays silently wrong under an argument hash, and is caught by `rr`.
Closing that gap means hashing the _inputs to decisions_, not only the arguments
of effects.

### 2. Journal versus world: unanimity, and why it is not transferable

**Every replay engine surveyed makes the journal absolutely authoritative, and
none re-observes the world on resume.** This is not an oversight; it is the
precondition that makes their model sound. The program is forbidden from
observing the world outside a step, so by construction there is nothing to
reconcile. [Azure][azure] states the rule as a documented code constraint;
[Golem] enforces it through the WebAssembly sandbox, where there is no ambient
source of nondeterminism at all.

[Burckhardt et al.][burckhardt] make the boundary formal, and explicitly exclude
external calls from the proved result because "duplication of external calls
(unlike internal calls) is observable". The exactly-once guarantee of durable
execution covers _internal state only_.

Two sources reconcile rather than dictate, and they are both outside the durable-
execution literature:

- [ARIES][wal] applies redo **conditionally**, comparing the log record's
  sequence number against the one stamped on the page itself. Crucially, it does
  this only for work that started and did not complete; completed work is
  replayed as a value.
- [Helland][idempotence] supplies the vocabulary for when reconciliation is
  impossible — memories, guesses and apologies — and the observation that a
  started-without-completed step is "the point of confusion" that only an
  application-level reply can resolve.

### 3. Determinism: a five-rung ladder, and most systems sit on the bottom rung

| Rung                   | Mechanism                                                  | Systems                                                                                     |
| ---------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| **By construction**    | nondeterministic inputs are logged events; state is a fold | [Netherite], [Burckhardt's calculus][burckhardt]                                            |
| **By sandbox**         | the host language's nondeterminism is unavailable          | [Golem] (WASM), [Vercel][vercel] (`node:vm` + seeded PRNG), [Temporal] (TypeScript isolate) |
| **By substitution**    | clock, RNG, timers replaced with journaled versions        | [Temporal] (Go), [Azure][azure], [Dapr][dapr], [Restate]                                    |
| **By static analysis** | an analyzer rejects forbidden calls                        | [Azure][azure] (.NET only)                                                                  |
| **By discipline**      | documented rules, detected after the fact if at all        | [Inngest], [DBOS], [Cloudflare][cloudflare], [Resonate], [Orleans]                          |

[Vercel][vercel] is the strongest of the general-purpose systems: the workflow
bundle runs in a context whose `Math.random` is seeded from the run id, whose
`Date` is the replay clock, and whose timers and `fetch` throw outright. It also
has the catalog's best divergence detector, raising `ReplayDivergenceError` both
when a replayed event has no consumer _and_ when the replay finishes with events
left unconsumed — the only system that catches a step the new code stopped
asking for.

### 4. Compensation: three primitives out of thirteen, and one instructive bug

[Effect][effect-workflow], [Cloudflare][cloudflare] and [Golem] are the only
engines with a compensation primitive; all three run compensations LIFO. Everyone
else documents a pattern: keep an array of closures, reverse it in a `catch`.

[Cloudflare][cloudflare] supplies the empirical argument for why the pattern is
not enough. Its rollback handlers are RPC stubs that are "dead across Durable
Object restarts", so terminating a hibernated instance with rollback must first
**re-run the workflow in a replay phase to rebuild the closures** before it can
run them. That is exactly the failure [Sagas][sagas] anticipated in 1987 by
requiring compensations to be registered in the log with their name and
arguments, so that a process which never saw the forward step can still run the
compensation.

The [compensation calculi][calculi] supply two laws the pattern silently relies
on and frequently gets wrong: compensations of _concurrent_ steps are themselves
concurrent and do not depend on the observed interleaving, and a compensation is
flat — it is retried forward, never itself compensated.

### 5. Versioning: pin, patch, or prove

Four strategies, in increasing order of ambition:

1. **Nothing.** [Inngest] (rename to force a re-run), [Effect][effect-workflow],
   and — remarkably for a generally-available product — [Cloudflare][cloudflare],
   whose documentation does not say what happens to a running instance when a
   new Worker version deploys.
2. **Pin the execution to the code that started it.** [Restate], [Vercel][vercel],
   [Temporal] (Worker Versioning), [Trigger.dev][trigger], [AWS Step
   Functions][asf]. Simple, and it makes old code immortal.
3. **Patch markers inside the program.** [Temporal]'s `GetVersion`, [DBOS]'s
   `DBOS.patch()`, [Dapr][dapr]'s `IsPatched`. Old histories take the old branch.
   The markers accumulate forever.
4. **Prove equivalence by replay.** [Golem]'s automatic update replays the entire
   oplog under the new component and **fails the update** unless every recorded
   result and side effect is reproduced. It is the only system in the catalog
   that treats "is the new code compatible with this history?" as a decidable
   question rather than a human judgement.

In the event-sourcing family the equivalent is an **upcaster** applied on read,
and this family is markedly further ahead than the durable-execution one.
[Marten] carries `type` and `mt_dotnet_type` per row so a rename is a mapping
change, never a data migration, and its documentation argues the stronger
discipline that the past should not be rewritten at all.
[Akka/Pekko][akka] stores a **manifest** with every event and applies an
`EventAdapter` at the read boundary whose `fromJournal` returns an `EventSeq`,
so one stored event may be split, dropped or replaced on the way in.
[Orleans] records a **format key per journal entry** and forces a fresh snapshot
when it changes.

The asymmetry is worth stating plainly: durable-execution systems mostly cope
with code evolution by refusing it (pinning) or by accumulating markers, while
event stores solved the corresponding problem a decade ago with a versioned
record and a read-time adapter. The record being versioned is what makes the
adapter possible.

### 6. Concurrency: identity scheme decides the difficulty

Name-keyed and derivation-keyed systems get concurrent steps almost for free:
distinct names or distinct derived ids mean completions can be journaled in any
order and replayed by lookup. Positional systems must assign ids at **schedule
time, in program order**, and then resolve completions by id — which
[Dapr/DTFx][dapr] does, and which is why its fan-out replays correctly without
any continuation capture. [DBOS] gets the same effect by reserving ids
synchronously before the first `await`, and consequently forbids racing
sub-sequences.

Two systems record the **completion order** separately from the schedule order
([Inngest]'s stack, [Temporal]'s history), which is what allows a replay to
resolve concurrent steps in the order they actually finished.

### 7. Replay or snapshot: the axis is narrower than it looks

Only [Trigger.dev][trigger] truly snapshots a running computation, using CRIU on
the container process, and it pays for it with a seccomp profile that must forbid
`io_uring` because the kernel cannot checkpoint those descriptors. Everything
else in the catalog replays, and the "snapshot" systems snapshot _state_, not
continuations:

- [Golem]'s user-defined snapshots are an exported save/load pair used to
  truncate the replay prefix and to migrate across incompatible code changes.
- [Azure][azure] entities, [Orleans] `StateStorage`, [Netherite]'s FASTER
  checkpoints, [Marten]'s inline projections: all fold-state snapshots beside a
  log.
- **Continue-as-new** ([Temporal], [Azure][azure], [Dapr][dapr]) is a manual
  snapshot in disguise: end the execution, start a fresh one with the carried
  state as its argument.

The [replay-versus-snapshot][replay-vs-snapshot] page establishes why: nobody
ships an arbitrary continuation across a code-version boundary, and the two
languages that can serialize continuations at all (Termite Scheme, Unison) manage
it only because their runtimes identify code by something stable.

### 8. Testing: one excellent suite, and a gap every system shares

| Technique                                     | Who does it                                                                                                                                       |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| In-process engine for unit tests              | nearly everyone ([Effect][effect-workflow] memory layer, [Inngest] test engine, [Dapr][dapr]/[DTFx][dapr] emulator, [Vercel][vercel] Local World) |
| Replay stored histories in CI                 | [Temporal] (`WorkflowReplayer`), [Golem] (checked-in golden oplogs)                                                                               |
| Real crash-and-recover integration            | [Golem], [Trigger.dev][trigger], [DBOS] (debug trigger points)                                                                                    |
| Machine-checked specification                 | [Resonate] (a Lean 4 abstract machine with 92 checked properties)                                                                                 |
| Differential testing                          | [Resonate] (one request sequence against SQLite, an oracle model, Postgres)                                                                       |
| Deterministic simulation                      | [Resonate] (seeded clock, network faults, worker kills)                                                                                           |
| **Crash at every journal index**              | **nobody**                                                                                                                                        |
| **Mutate the world between crash and resume** | **nobody**                                                                                                                                        |

[Resonate]'s three-layer suite is the strongest in the catalog and the model to
copy. The two gaps at the bottom are unsurprising: no engine re-observes the
world, so no engine has a reason to test what happens when the world moved.

---

## The consensus standard

A durable-execution system in 2026 is expected to provide:

- a program/effect split, where only effect results are persisted;
- a journal written as an intent/result **pair**, so an interrupted effect is
  distinguishable from one that never started;
- at-least-once effect execution with an idempotency key, and exactly-once
  recording of the outcome;
- substituted clock, randomness and timers;
- suspension without continuation capture;
- per-step retry with backoff, and a documented saga pattern for rollback;
- some story for code evolution — pinning at minimum;
- an in-process engine for tests.

It is _not_ expected to provide compensation as a primitive, argument-level
divergence detection, or any reconciliation with an externally mutable world.

---

## Architectural trade-offs

| Decision                      | Taken by                                                       | Buys                                                         | Costs                                                              |
| ----------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------ | ------------------------------------------------------------------ |
| Positional step identity      | most engines                                                   | zero developer burden; trivial fan-out via schedule-time ids | every code edit is a compatibility event; patch markers accumulate |
| Named step identity           | [Inngest], [Cloudflare][cloudflare], [Effect][effect-workflow] | free reordering and insertion                                | name collisions; a rename silently re-executes                     |
| Forbid observing the world    | all replay engines                                             | the journal can be authoritative; no reconciliation logic    | the program cannot react to a world that changed under it          |
| Sandbox-enforced determinism  | [Golem], [Vercel][vercel], [Temporal] (TS)                     | divergence becomes impossible rather than detectable         | a restricted language subset; a heavier runtime                    |
| Server-owned journal          | [Temporal], [Restate], [AWS][asf]                              | operational visibility; cross-language SDKs                  | a service to run; the journal is not a file you can read           |
| Library-over-database journal | [DBOS], [Marten], [Effect][effect-workflow]                    | no new infrastructure; SQL is the query interface            | the application owns schema migration and retention                |
| Process snapshot              | [Trigger.dev][trigger]                                         | no determinism rules at all; arbitrary in-memory state       | kernel-level machinery; no cross-version resume; `io_uring` banned |
| Control flow as data          | [AWS Step Functions][asf]                                      | no determinism problem; redrive from the failed state        | the program is a JSON graph, not code                              |

---

## Delta: where `sparkles` stands

Two columns, because the design spans two layers: what
[`sparkles:event-horizon`](../../../specs/event-horizon/SPEC.md) already
provides, and what the [`release`](../../../specs/release/SPEC.md) tool does
today.

| Capability                        | `sparkles:event-horizon` today                                        | `release` today                                                                                       |
| --------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Effect boundary                   | **present** — the `Ctx` capability row, handlers as values, `withCap` | absent; every effect is a direct call                                                                 |
| Deterministic test doubles        | **present** — `TestClock`, `SimNet`, `SimProc`, `TestSched`           | absent                                                                                                |
| Journal                           | absent                                                                | four partial substitutes: the `--stage` ladder, re-run-and-shrink, `plan.json`, the publish manifest  |
| Step identity                     | absent                                                                | implicit: the tag name                                                                                |
| Divergence detection              | absent                                                                | absent                                                                                                |
| Suspension without continuations  | **present by construction** — every capability op is tail-resumptive  | n/a                                                                                                   |
| Compensation                      | absent (structured-concurrency cancellation is not compensation)      | absent; a failed run leaves its tags standing                                                         |
| Versioning against an old journal | absent                                                                | absent; `--plan` re-anchors by boundary SHA and refuses on drift                                      |
| Projection                        | absent                                                                | absent; the UI prints inline                                                                          |
| Crash testing                     | the seam exists; no harness                                           | absent                                                                                                |
| **Reconciliation with the world** | absent                                                                | **partially present, and unique** — `--plan` drops already-created tags and re-anchors surviving ones |

The last row is the finding that matters. `release`'s existing `--plan` resume
already does something no surveyed engine does: it re-observes git and adjusts.
The design's rule table generalizes it.

---

## Questions for the `sparkles` design

The catalog was commissioned to confirm, revise or reopen the decisions taken
before it was written. Its verdicts:

**Confirmed.**

- _Replay over snapshot._ Unanimous, and [replay-versus-snapshot][replay-vs-snapshot]
  shows why continuation capture would be a dead end for a tool whose code
  changes constantly.
- _The journaling handler as the single impure boundary._ This is
  [Burckhardt's][burckhardt] three-model stack; Theorem 6.4 and Lemma 6.7 give
  the correctness claim a citable shape. A second, closer precedent exists:
  Ramalingam and Vaswani's idempotence monad logs each effectful step under an
  identifier plus a step counter and proves the translation failure-free modulo
  retries (Theorem 3.9), with a compensation extension attached
  ([effect handlers and record/replay][handlers]). Its proof puts the log in the
  same atomic store as the effects, so it covers journal consistency and not the
  outside world — but it is the nearest thing in the literature to what the
  combinator claims.
- _Capabilities as values, with no continuation capture._ Ahman and Bauer's
  runners are exactly the `Ctx` row's shape — tail-resumptive handlers with a
  finalisation-exactly-once theorem — which is also the precedent for
  scope-registered LIFO compensations ([handlers]). Separately, Koppel, Scherer
  and Solar-Lezama prove that replay from a recording _implements_ delimited
  control, so refusing continuation capture costs no expressiveness.
- _Compensations registered on a scope, LIFO, explicit-only._ Three engines and
  both compensation sources agree on the shape, and no engine rolls back
  automatically.
- _One program for classic and split mode._ Every system has exactly one durable
  program abstraction.
- _Suspension without continuation capture._ Universal.
- _Started-and-completed as a pair._ Universal, and required by [ARIES][wal].

**Revised by the evidence.**

- _"Every observation is re-observed on resume" is too broad._ [ARIES][wal]
  consults the world only for work that started without completing; completed
  work replays as a value. The rule table should be scoped to the interrupted
  step and to the reconciliation the plan explicitly needs.
- _Compensations must not be in-memory closures._ [Sagas][sagas] requires them
  registered with name and arguments; [Cloudflare][cloudflare] demonstrates the
  bug that results from closures. Journal the registration.
- _The args hash should be a divergence check, not part of the key — but what a
  mismatch means is now an open choice, not a detail._ [Restate] separates
  matching from drift detection and excludes computed fields; [KurrentDB][kurrent]
  takes the opposite line and refuses a mismatch outright as corrupted
  idempotency. Keying on the hash makes every incidental argument change a new
  step; refusing on mismatch makes it a stop. The design must say which, per op
  kind.
- _The args hash is a weaker oracle than assumed._ Per
  [deterministic record and replay][replay], it only fires when the program
  issues an op, so a program that consumes a replayed value differently and then
  issues an identical op replays silently wrong. Hash decision inputs, not only
  effect arguments.
- _Concurrent compensations are structural, not interleaving-reversed._ The
  [calculi][calculi] state this as a law.
- _Side effects after a journaled write are not automatically at-least-once._
  [Akka/Pekko][akka] documents its post-persist side effects as **at-most-once**
  — they simply do not run if the process dies after the write — and pushes
  at-least-once back into replayed state. A `started` record is what buys the
  stronger guarantee, and it only does so if resume actually re-examines every
  started-without-completed op.

**Reopened.**

- _Versioning_ was parked; it can no longer be. [Golem]'s prove-by-replay is a
  genuinely better answer than patch markers for a tool whose journal lives days,
  not years, and whose code changes between every run. The spec must choose.
- _What "the UI is a projection" means for the final receipt._ [Helland][idempotence]'s
  closing-stage ambiguity means the receipt must be derivable from the world, not
  from the journal alone.
- _Whether a `pause` outcome belongs beside fail and retry._ [Restate] has three
  policies for a mismatch; the design has one.

**Mechanisms worth adopting**, each already load-bearing somewhere:

- **Append with an expected length.** [KurrentDB][kurrent]'s `ExpectedVersion`
  is asserted per append and is a _different_ guard from its process-wide
  exclusive lock. A `journal.jsonl` append that asserts "expected length N"
  makes a second resume safe even when the lock file is stale, which a lock
  alone does not.
- **A run id on every line, plus a contiguity check.** [Akka/Pekko][akka]'s
  `writerUuid` and its replay filter exist to detect two incarnations writing one
  stream. The same check catches a journal that two `release` runs interleaved.
- **A format version per line with a read-time adapter.** [Akka/Pekko][akka]'s
  manifest plus `EventAdapter`, [Orleans]'s format key with forced re-snapshot,
  [Marten]'s `type` column plus upcasters. This is the versioning tool the design
  currently lacks entirely.
- **Fold before write.** [Akka/Pekko][akka] applies an event to state before
  appending it, so a record that the projection cannot consume never reaches the
  journal.
- **Atomic multi-record append.** [KurrentDB][kurrent] writes a batch across
  streams atomically; the `started`/`completed` pair, or a step plus its
  compensation registration, want the same treatment.
- **An in-journal snapshot.** [Marten]'s `Compacted<T>` marks a fold point inside
  the log rather than beside it — the shape `plan.json` and the publish manifest
  should take once they become journal records.
- **A hard stop when the projection throws.** [Orleans] swallows fold exceptions
  and advances the version anyway, diverging silently. D's `pure` on the
  projection plus a hard stop on a replay error is the opposite, and better.

**Still parked** (they need the spec, not more research): the durable scope's
API, the journal event schema field by field, and the `sparkles:effects`
extraction boundary.

---

## Sources

Every claim above is carried by the deep-dive it links to; those pages hold the
primary citations. The synthesis leans hardest on [Burckhardt et
al.][burckhardt] for the formal model, [ARIES][wal] and [Sagas][sagas] for the
disciplines the field rediscovered, and [Helland][idempotence] for the framing of
what a journal can and cannot promise about the outside world.

<!-- References -->

[akka]: ./akka-pekko-persistence.md
[asf]: ./aws-step-functions.md
[azure]: ./azure-durable-functions.md
[burckhardt]: ./burckhardt-durable-functions-semantics.md
[calculi]: ./compensation-calculi.md
[cloudflare]: ./cloudflare-workflows.md
[concepts]: ./concepts.md
[dapr]: ./dapr-workflow.md
[DBOS]: ./dbos.md
[effect-workflow]: ./effect-workflow.md
[Golem]: ./golem.md
[handlers]: ./effect-handlers-record-replay.md
[idempotence]: ./idempotence.md
[Inngest]: ./inngest.md
[kurrent]: ./kurrentdb.md
[Marten]: ./marten.md
[Netherite]: ./netherite.md
[replay]: ./deterministic-replay.md
[Orleans]: ./orleans.md
[replay-vs-snapshot]: ./replay-vs-snapshot.md
[Resonate]: ./resonate.md
[Restate]: ./restate.md
[sagas]: ./sagas.md
[Temporal]: ./temporal.md
[trigger]: ./trigger-dev.md
[vercel]: ./vercel-workflow.md
[wal]: ./write-ahead-logging.md
