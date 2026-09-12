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

## Delta: what `sparkles` has today

`sparkles` has no durable-execution layer. What it does have is the substrate
one would be built on — [`sparkles:event-horizon`](../../../specs/event-horizon/SPEC.md)'s
capability row — and measuring that against the consensus standard above shows
which half of the problem is already solved.

| Capability of the consensus standard    | `sparkles:event-horizon` today                                          |
| --------------------------------------- | ----------------------------------------------------------------------- |
| An effect boundary a handler can wrap   | **present** — the `Ctx` row, handlers as plain struct values, `withCap` |
| Deterministic doubles for every effect  | **present** — `TestClock`, `SimNet`, `SimProc`, `TestSched`             |
| Suspension without continuation capture | **present by construction** — every capability op is tail-resumptive    |
| Structured cancellation                 | **present** — scopes, deadlines, the cancellation tree                  |
| A journal, in any form                  | absent                                                                  |
| Step identity and replay matching       | absent                                                                  |
| Divergence detection                    | absent                                                                  |
| Compensation                            | absent — structured-concurrency cancellation is not compensation        |
| Versioning of code against a record     | absent                                                                  |
| A projection with a recorded offset     | absent                                                                  |
| Journal integrity and writer fencing    | absent                                                                  |
| An operator surface over a run          | absent                                                                  |
| Crash-and-resume testing                | the seam exists; no harness                                             |

The shape of the gap is worth naming. Every system in this survey had to build
its own effect boundary and its own deterministic doubles, usually against a
host language that fought it — Temporal patches a JavaScript isolate, Vercel
runs a seeded `node:vm`, Golem needs a WebAssembly sandbox. That work is already
done here and is the harder half. What is missing is the journal and everything
that hangs off it, which is the part every surveyed system implements in a few
thousand lines over a storage interface.

---

## Implications for a durable-execution library

Reading the catalog as a whole, these are the decisions a library cannot avoid,
each one a place where the surveyed systems genuinely diverge rather than
converge. They are stated as open questions because the evidence does not settle
them; a design must.

1. **Is step identity positional, named, or derived?** Positional costs a patch
   mechanism and makes every edit a compatibility event. Named costs a
   uniqueness discipline and silently re-executes on a rename. The choice is
   forced by whether the library expects its programs to be edited between a
   crash and its resume — which, for a library used by developer tooling, it
   should.
2. **Is an argument mismatch a different step, or the same step reporting
   drift?** [KurrentDB][kurrent] refuses it; [Restate] makes it a policy with
   three outcomes. The two produce different behaviour on resume, and the
   literature does not prefer either.
3. **How much divergence is worth detecting?** [Deterministic record and
   replay][replay] shows the ceiling: comparing the full machine state at every
   event catches what an argument comparison cannot. A library must decide where
   between "nothing" ([Cloudflare][cloudflare]) and "everything" (`rr`) it sits,
   knowing that the cheap options miss a real class of silent wrongness.
4. **May a durable program observe the world at all?** Every replay engine here
   says no, and every one of them is a service whose effects are network calls
   to systems that deduplicate. A library whose effects touch a local, mutable,
   human-editable world has no prior art to copy and must invent a policy or
   inherit the prohibition.
5. **Is compensation a primitive or a pattern?** Three engines provide one; the
   rest document a recipe. [Sagas][sagas] and [Cloudflare][cloudflare] together
   show the recipe's specific failure — closures do not survive the process that
   registered them — so a library that omits the primitive should at least
   journal the registration.
6. **How does code evolve against an old record?** The event stores answer with
   a version per record and a read-time adapter; the workflow engines mostly
   answer by pinning or by accumulating markers. [Golem]'s prove-by-replay is the
   only mechanism that decides compatibility rather than asserting it.
7. **What can a person do to a stuck run?** The answers range from nothing to
   fork-from-step, redrive, and rewind-to-an-index. This is the dimension where
   the field is least converged and where a library's choices leak most directly
   into its consumers' operational story.

**What no system in the survey provides**, and a library therefore cannot copy:
reconciliation between a journal and an independently mutable world; an argument
hash as part of step identity; crash-at-every-index testing as a shipped
harness; and any correctness statement about replay that covers external
effects — [Burckhardt et al.][burckhardt] and Ramalingam and Vaswani both
deliberately exclude them.

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
