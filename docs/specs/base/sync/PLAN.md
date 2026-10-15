---
status: draft
owner: sparkles:base
reviewed: 2026-10-12
---

# Synchronization primitives — Plan

Delivery order for [SPEC.md](./SPEC.md) and [primitives.md](./primitives.md).
Each milestone names its obligations, prerequisites, deliverable and
acceptance; the checks behind each acceptance are in
[testing.md](./testing.md).

## S0: Specification

**Obligations.** The contract, decisions and oracles of this tree.
**Deliverable.** `SPEC.md`, `primitives.md`, `decisions.md`, `testing.md`, this
plan, and their glossary entries.
**Acceptance.** Docs checks pass; the owner has reviewed the decisions
(see [decisions.md](./decisions.md)).

## S1: Seam, parking lot and model

**Obligations.** SYF1–SYF4, SYP1–SYP15, SYK1–SYK4, SYK6–SYK9, SYI1–SYI5,
SYH2, SYA1–SYA6 for
the parking lot, SYX1–SYX3.
**Prerequisites.** S0.
**Deliverable.** `sparkles.base.sync` modules for the seam on Linux, Windows,
macOS and FreeBSD, the thread parker, the parking lot over a platform policy,
the model platform and its weak-memory explorer with seeded-fault variants,
a test parker that cancels, the fork
handler, a FreeBSD CI leg that runs on every pull request within 15 minutes,
and the Linux leg's portable-parker configuration.
**Acceptance.** Oracle 1 explores every parking-lot scenario in
[testing.md](./testing.md#the-seam-and-the-parking-lot) and reports every
seeded fault; oracle 10 checks the parking-lot protocol, `fork` included;
oracles 3, 5, 6 and 7 pass on the Linux, Windows, macOS and FreeBSD legs,
on the Linux leg built with the portable parker too, and under Wine (DS24).
**Excludes.** Every primitive.

## S2: Mutex, lock bits, guarded data, condition, once

**Obligations.** SYL1–SYL3, SYM1–SYM9, SYJ1–SYJ5, SYG1–SYG4, SYC1–SYC9,
SYO1–SYO6, SYH1 for these primitives.
**Prerequisites.** S1.
**Deliverable.** The primitives, their scenarios and automata, and the
benchmark suite.
**Acceptance.** Oracles 1–7, 9 and 11 pass for these primitives on every leg,
and oracle 10 for the mutex and condition protocols; gates
B1–B4 and B6 pass and B5 and B7 are recorded on the reference machine; the owner sets B5's
pass threshold from that record (DS2); the same machine sets `parkingBuckets`,
`spinSteps` and `starvationBound`.

## S3: Reader–writer lock, semaphore, events, barrier, latch, address wait

**Obligations.** SYR1–SYR6, SYS1–SYS5, SYE1–SYE4, SYB1–SYB3, SYW1–SYW3, SYH1
for these primitives.
**Prerequisites.** S2.
**Acceptance.** Oracles 1–7 and 9 pass for these primitives on every leg, and
oracle 10 for the semaphore and reader–writer protocols.

## S4: Migration

**Obligations.** None new; consumers move to the library.
**Prerequisites.** S2 for mutexes and conditions; S3 for anything else; for
event-horizon's own users, its fiber parker (below).
**Deliverable.** Every in-repository user of `core.sync.mutex`,
`core.sync.condition` and `pthread_mutex_t` switched to `sparkles.base.sync`,
one package per commit, with before-and-after measurements where a hot path
changes.
**Acceptance.** `ci --test` and the example and documentation checks pass; no
`core.sync.mutex`, `core.sync.condition` or `pthread_mutex_t` remains outside
the seam and the portable thread parker.

## Dependent work in other specifications

`sparkles:event-horizon` specifies the fiber parker (SYK2, SYK5, SYK8, SYK9,
SPEC §4a) in its [fiber-parker.md](../../event-horizon/fiber-parker.md), with
latched cancellation, and delivers it, the blocking pool on these primitives
and its use of the address wait in its milestone M20, which owns their
acceptance.

## Deferred

- **Deadlock detection** (DS9). Enters when a consumer needs it.
- **Predicate waits** (`Await`-style). Enters with a consumer and a measured
  case against a condition variable.
- **Process sharing and priority inheritance** (DS8).
- **Local resumption on handoff** — resuming a fiber that is handed a lock on
  the releasing thread ([König et al. 2025](../../../research/fine-grained-locking/koenig-2025-combine-and-exchange.md)).
  Enters with event-horizon's fiber parker and a measurement.

## Progress

| Milestone | State       | Pull request |
| --------- | ----------- | ------------ |
| S0        | in review   | —            |
| S1        | not started | —            |
| S2        | not started | —            |
| S3        | not started | —            |
| S4        | not started | —            |
