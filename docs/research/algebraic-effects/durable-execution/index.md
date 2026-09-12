# Durable Execution

A survey of **durable execution**: making a long-running program survive the
death of its process by journaling the results of its effects and re-deriving
everything else. The technique sits directly downstream of algebraic effects —
the journaling layer is a handler over an effect boundary — but it grew up in a
different literature, and the two have barely met.

This catalog exists to inform a concrete design: rewriting the
[`release`](../../../specs/release/SPEC.md) tool as one durable program over
[`sparkles:event-horizon`](../../../specs/event-horizon/SPEC.md)'s capability
row, so that every significant step is a resumption point.

**Last reviewed:** September 12, 2026.

---

## The eight questions this survey answers

1. **How is an effectful step identified and matched on replay?** →
   [Comparison §1][cmp-1], and every deep-dive's Analysis §1.
2. **When the journal and the world disagree, which wins, and how is
   disagreement detected?** → [Comparison §2][cmp-2], [ARIES][wal],
   [Helland][idempotence].
3. **How is determinism between journaled steps enforced?** →
   [Comparison §3][cmp-3], [deterministic record and replay][replay],
   [deterministic simulation testing][dst].
4. **How are compensations registered, ordered and triggered?** →
   [Comparison §4][cmp-4], [Sagas][sagas], [compensation calculi][calculi].
5. **How does workflow code evolve against journals written by older code?** →
   [Comparison §5][cmp-5], [Golem], [Temporal].
6. **How do concurrent steps replay?** → [Comparison §6][cmp-6],
   [compensation calculi][calculi].
7. **Replay or snapshot: what does each cost and rule out?** →
   [replay versus continuation snapshotting][replay-vs-snapshot],
   [Comparison §7][cmp-7].
8. **How is a durable program tested?** → [Comparison §8][cmp-8],
   [deterministic simulation testing][dst], and the runnable
   [replay-journal example](./examples/replay-journal.d).

Start with [Concepts and Vocabulary][concepts] if the terms are unfamiliar: the
field has no agreed names, and the same idea is a _step_, an _activity_, a
_journal entry_ and an _oplog entry_ depending on whose documentation you are
reading.

---

## Master catalog

### Durable-execution engines and SDKs

| Subject                                | Language                        | Persistence model                | Step identity                 | Link              |
| -------------------------------------- | ------------------------------- | -------------------------------- | ----------------------------- | ----------------- |
| `@effect/workflow` + `@effect/cluster` | TypeScript                      | replay                           | name + attempt                | [effect-workflow] |
| Temporal                               | Go server; Go + TypeScript SDKs | replay                           | positional counter            | [Temporal]        |
| Restate                                | Rust server; TypeScript SDK     | replay                           | positional + header check     | [Restate]         |
| DBOS Transact                          | TypeScript (+ Python, Go, Java) | replay                           | positional `function_id`      | [DBOS]            |
| Azure Durable Functions                | C# (DTFx) + JavaScript          | replay; entities snapshot        | positional ordinal            | [azure]           |
| Dapr Workflow + Durable Task Framework | C#, Go                          | replay                           | positional `idCounter`        | [dapr]            |
| Inngest                                | Go server; TypeScript SDK       | replay                           | hashed name + repeat counter  | [Inngest]         |
| Cloudflare Workflows                   | TypeScript on `workerd`         | replay                           | name + occurrence count       | [cloudflare]      |
| Vercel Workflow DevKit                 | TypeScript (SWC plugin)         | replay                           | seeded deterministic ULID     | [vercel]          |
| Resonate                               | Rust server; TypeScript SDK     | replay                           | derived promise id            | [Resonate]        |
| Golem                                  | Rust runtime; any WASM guest    | replay + optional state snapshot | positional + structural claim | [Golem]           |

### Contrast cases

| Subject            | Language               | Persistence model                  | Why it is here                                        | Link      |
| ------------------ | ---------------------- | ---------------------------------- | ----------------------------------------------------- | --------- |
| Trigger.dev        | TypeScript             | snapshot (CRIU process checkpoint) | the one system that really snapshots a computation    | [trigger] |
| AWS Step Functions | Amazon States Language | explicit state machine             | control flow as data; the rejected design alternative | [asf]     |

### Event-sourced state

| Subject                  | Language           | Persistence model                         | Link      |
| ------------------------ | ------------------ | ----------------------------------------- | --------- |
| Akka / Pekko Persistence | Scala, Java        | event log + snapshots                     | [akka]    |
| Orleans                  | .NET               | snapshot, event log, or both per provider | [Orleans] |
| KurrentDB (EventStoreDB) | .NET               | append-only log + projections             | [kurrent] |
| Marten                   | .NET on PostgreSQL | event log + inline/async projections      | [Marten]  |

### Theory

| Subject                                                | Year / venue          | Grounds questions | Link                 |
| ------------------------------------------------------ | --------------------- | ----------------- | -------------------- |
| Sagas (Garcia-Molina, Salem)                           | SIGMOD 1987           | 4                 | [sagas]              |
| ARIES write-ahead logging (Mohan et al.)               | TODS 1992             | 1, 2, 4, 8        | [wal]                |
| Compensation calculi (cCSP; Bruni et al.; Helland)     | 2005, 2005, 2009      | 2, 4, 6           | [calculi]            |
| Idempotence and the outside world (Helland)            | CIDR 2007, Queue 2012 | 1, 2, 4           | [idempotence]        |
| Durable Functions: Semantics for Stateful Serverless   | OOPSLA 2021           | 1, 2, 3, 6, 7     | [burckhardt]         |
| Netherite: Efficient Execution of Serverless Workflows | VLDB 2022             | 2, 3, 7           | [Netherite]          |
| Deterministic record and replay (rr and ancestors)     | 1987–2017             | 1, 3, 6, 7        | [replay]             |
| Replay versus continuation snapshotting                | 2006–2026             | 5, 7              | [replay-vs-snapshot] |
| Deterministic simulation testing                       | 2014–2026             | 3, 8              | [dst]                |
| Effect handlers and record/replay                      | 2013–2022             | 1, 3, 4           | [handlers]           |

---

## Taxonomy

### By persistence model

| Model                       | Subjects                                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------------------------- |
| **Replay only**             | [Temporal], [Restate], [DBOS], [dapr], [Inngest], [cloudflare], [vercel], [Resonate], [effect-workflow] |
| **Replay + state snapshot** | [Golem], [azure] (entities), [Netherite], [Orleans], [Marten], [akka], [kurrent]                        |
| **Continuation snapshot**   | [trigger]; historically Termite Scheme and Unison ([replay-vs-snapshot])                                |
| **Explicit state machine**  | [asf]                                                                                                   |

### By step identity

| Scheme         | Subjects                                                             | Consequence                                                       |
| -------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------- |
| **Positional** | [Temporal], [azure], [dapr], [DBOS], [Restate], [Netherite], [Golem] | editing the program is a compatibility event; needs patch markers |
| **Named**      | [Inngest], [cloudflare], [effect-workflow]                           | free reordering; name collisions and silent renames               |
| **Derived**    | [Resonate], [vercel]                                                 | stable without naming discipline; opaque in the journal           |
| **None**       | [trigger], [asf]                                                     | nothing re-executes, so nothing is matched                        |

### By determinism enforcement

| Degree                 | Subjects                                                         |
| ---------------------- | ---------------------------------------------------------------- |
| **By construction**    | [Netherite], [burckhardt]                                        |
| **By sandbox**         | [Golem], [vercel], [Temporal] (TypeScript)                       |
| **By substitution**    | [Temporal] (Go), [azure], [dapr], [Restate]                      |
| **By static analysis** | [azure] (.NET only)                                              |
| **By discipline**      | [Inngest], [DBOS], [cloudflare], [Resonate], [Orleans], [Marten] |
| **Not required**       | [trigger], [asf]                                                 |

### By journal ownership

| Owner                          | Subjects                                                       |
| ------------------------------ | -------------------------------------------------------------- |
| A dedicated server             | [Temporal], [Restate], [Inngest], [Resonate], [asf], [kurrent] |
| The application's own database | [DBOS], [Marten], [effect-workflow], [akka]                    |
| The platform's storage runtime | [cloudflare], [azure], [dapr], [Golem], [Netherite], [Orleans] |
| Local files                    | [vercel] (development world)                                   |

---

## Milestones

Dates are those of the cited publication or release, verified on the linked page.

| Year | Milestone                                                                                                                 |
| ---- | ------------------------------------------------------------------------------------------------------------------------- |
| 1987 | [Sagas][sagas] defines compensation and backward recovery for long-lived transactions                                     |
| 1992 | [ARIES][wal] fixes the write-ahead protocol, "repeating history", and compensation log records                            |
| 2005 | [Compensation calculi][calculi] give compensable processes a trace semantics and the LIFO law                             |
| 2006 | Termite Scheme ships serializable continuations for process migration ([replay-vs-snapshot])                              |
| 2007 | [Helland][idempotence] argues at CIDR that distributed transactions must be replaced by idempotent activities             |
| 2009 | Building on Quicksand reframes compensation as apology ([calculi])                                                        |
| 2011 | Cloud Haskell shows arbitrary closures cannot be serialized, only static labels ([replay-vs-snapshot])                    |
| 2013 | Ramalingam and Vaswani prove fault tolerance via idempotence for a replayed effect log ([handlers])                       |
| 2017 | [rr][replay] makes whole-process record and replay deployable on commodity hardware                                       |
| 2018 | Pyro's `poutine` ships the `trace`/`replay` handler pair — the mechanism, without persistence ([handlers])                |
| 2021 | [Burckhardt et al.][burckhardt] give durable functions a formal semantics and prove replay equivalent to direct execution |
| 2021 | [FoundationDB's][dst] simulation testing is published with the SIGMOD paper                                               |
| 2022 | [Netherite][Netherite] shows a partitioned event-sourced engine beating per-step storage round trips                      |
| 2025 | [Cloudflare Workflows][cloudflare] reaches general availability, putting `step.do` on an edge runtime                     |

---

## Suggested reading paths

**"I want the shortest honest summary."** [Concepts][concepts], then
[Comparison][comparison].

**"I am designing the `sparkles` durable layer."** [Comparison][comparison]
(especially its delta table and the closing "Questions for the `sparkles`
design"), then [ARIES][wal] and [Helland][idempotence] for the journal-versus-
world problem, then [Sagas][sagas] and the [calculi][calculi] for compensation,
then [Golem] for the one serious answer to versioning, and
[Resonate] for the testing bar to clear.

**"I want the formal ground."** [Burckhardt et al.][burckhardt], then
[handlers] for what the effects literature does and does not have, then
[Netherite] for the engineering the semantics permits.

**"I want to see it work."** The runnable
[replay-journal example](./examples/replay-journal.d): about 200 lines of D that
journal a miniature release, crash at every index, resume, and detect a diverged
program. `ci --example-files` compiles and runs it.

**"I want the closest prior art to what we are building."**
[effect-workflow] (the design this was sketched from), [Restate] (the closest
journal shape), and [DBOS] (the closest deployment shape — a library over a
database, no server).

---

## Sources

Each deep-dive carries its own primary citations: 430-plus GitHub file
references, every one pinned to a commit hash and verified to resolve, plus the
papers and official documentation listed on each page. The catalog reads
upstream source trees cloned under `$REPOS` at the revisions its metadata tables
name.

<!-- References -->

[akka]: ./akka-pekko-persistence.md
[asf]: ./aws-step-functions.md
[azure]: ./azure-durable-functions.md
[burckhardt]: ./burckhardt-durable-functions-semantics.md
[calculi]: ./compensation-calculi.md
[cloudflare]: ./cloudflare-workflows.md
[cmp-1]: ./comparison.md#_1-step-identity-positional-dominates-naming-is-the-newer-answer
[cmp-2]: ./comparison.md#_2-journal-versus-world-unanimity-and-why-it-is-not-transferable
[cmp-3]: ./comparison.md#_3-determinism-a-five-rung-ladder-and-most-systems-sit-on-the-bottom-rung
[cmp-4]: ./comparison.md#_4-compensation-three-primitives-out-of-thirteen-and-one-instructive-bug
[cmp-5]: ./comparison.md#_5-versioning-pin-patch-or-prove
[cmp-6]: ./comparison.md#_6-concurrency-identity-scheme-decides-the-difficulty
[cmp-7]: ./comparison.md#_7-replay-or-snapshot-the-axis-is-narrower-than-it-looks
[cmp-8]: ./comparison.md#_8-testing-one-excellent-suite-and-a-gap-every-system-shares
[comparison]: ./comparison.md
[concepts]: ./concepts.md
[dapr]: ./dapr-workflow.md
[DBOS]: ./dbos.md
[dst]: ./deterministic-simulation-testing.md
[effect-workflow]: ./effect-workflow.md
[Golem]: ./golem.md
[handlers]: ./effect-handlers-record-replay.md
[idempotence]: ./idempotence.md
[Inngest]: ./inngest.md
[kurrent]: ./kurrentdb.md
[Marten]: ./marten.md
[Netherite]: ./netherite.md
[Orleans]: ./orleans.md
[replay]: ./deterministic-replay.md
[replay-vs-snapshot]: ./replay-vs-snapshot.md
[Resonate]: ./resonate.md
[Restate]: ./restate.md
[sagas]: ./sagas.md
[Temporal]: ./temporal.md
[trigger]: ./trigger-dev.md
[vercel]: ./vercel-workflow.md
[wal]: ./write-ahead-logging.md
