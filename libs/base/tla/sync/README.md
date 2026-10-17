# Oracle 10: the protocol model of `sparkles.base.sync`

This directory holds oracle 10 of
[testing.md](../../../../docs/specs/base/sync/testing.md#oracle-10-the-protocol-model):
TLA+ specifications of the parking lot and of the `Mutex`,
`InterruptibleMutex` and `Condition` protocols, with TLC configurations
that check their safety invariants, their liveness under weak fairness,
traces the model must accept, and seeded faults it must reject. The model
is written from [SPEC.md](../../../../docs/specs/base/sync/SPEC.md) and
[primitives.md](../../../../docs/specs/base/sync/primitives.md) alone, not
from the D code; whether the code implements it is a manual review
obligation, recorded with each result.

It covers PLAN.md's S1 (the parking lot, `fork` included) and S2 (the
mutex and condition protocols). The semaphore and reader–writer protocols
that oracle 10 also names belong to S3 and are not modelled yet.

## Files

| File                | What it models                                                     |
| ------------------- | ------------------------------------------------------------------ |
| `ParkingLot.tla`    | S1: buckets and their locks, queues, records, the abstract parker  |
| `LockProtocols.tla` | S2: `Mutex` (`LockBits`), `InterruptibleMutex`, `Condition`        |
| `pl-*.cfg`          | configurations of `ParkingLot.tla`                                 |
| `mx-*.cfg`          | `LockProtocols.tla` with `Kind = "mutex"` and lockers only         |
| `im-*.cfg`          | `LockProtocols.tla` with `Kind = "imutex"` and lockers only        |
| `cv-*.cfg`          | `LockProtocols.tla` with condition waiters and a notifier          |
| `check.sh`          | runs every configuration and checks each has its expected verdict  |
| `.editorconfig`     | TLA+ aligns continuation lines under their operator, at any column |

Every configuration starts with a comment that says what it explores and,
for a witness or a fault, which violation it must produce.

## Running

`check.sh` needs `tlc` on `PATH`. From the repository root:

```sh
nix shell nixpkgs#tlaplus18 nixpkgs#jdk21_headless \
    -c libs/base/tla/sync/check.sh
```

It prints one line per configuration and exits non-zero if any
configuration does not end as expected: a passing one with an error, or a
witness or fault one without its named violation (TLC exit 12 with that
invariant, or exit 13 for a liveness property). Arguments restrict the run
to configurations matching shell patterns (`check.sh 'mx-*' pl-wait`).
`TLA_WORKERS` sets TLC's worker count (default `auto`) and `TLA_META_DIR`
its scratch directory (default `$TMPDIR/sparkles-tla-meta`); nothing is
written inside the repository.

One configuration by hand, from this directory:

```sh
tlc -workers auto -metadir /tmp/tla-meta/pl-wait -cleanup \
    -config pl-wait.cfg ParkingLot.tla
```

## Results

Recorded on 2026-10-17 with TLC 2.18 (`nixpkgs#tlaplus18`) and OpenJDK 21,
`TLA_WORKERS=4`, on a 32-core x86-64 Linux machine. The whole `check.sh`
run took 162 s (115 s with `-workers auto`). States are distinct states;
for a witness or a fault they are the states explored before the first
violation, which varies with the worker count.

| Configuration           | Checks            | States    | Time | Verdict                       |
| ----------------------- | ----------------- | --------- | ---- | ----------------------------- |
| `pl-wait`               | safety, liveness  | 29 409    | 19 s | pass                          |
| `pl-designate`          | safety            | 125 700   | 3 s  | pass                          |
| `pl-filter`             | safety            | 51 918    | 2 s  | pass                          |
| `pl-requeue`            | safety            | 496 922   | 7 s  | pass                          |
| `pl-requeue-shared`     | safety            | 385 337   | 5 s  | pass                          |
| `pl-fork`               | safety            | 261 561   | 4 s  | pass                          |
| `pl-live-designate`     | safety, liveness  | 3 738     | 3 s  | pass                          |
| `pl-live-requeue`       | safety, liveness  | 7 336     | 3 s  | pass                          |
| `pl-witness-withdraw`   | `NoWithdrawal`    | 245       | 1 s  | violated, as required         |
| `pl-witness-race`       | `NoLostRace`      | 483       | 1 s  | violated, as required         |
| `pl-witness-late`       | `NoLateDelivery`  | 5 096     | 1 s  | violated, as required         |
| `pl-fault-validate`     | safety            | 346       | 1 s  | `NoLostWakeup` violated       |
| `pl-fault-timeout`      | safety            | 354       | 1 s  | `ReturnConsistent` violated   |
| `pl-fault-delivery`     | safety            | 6 738     | 1 s  | `QueueConsistent` violated    |
| `pl-fault-retire`       | safety            | 795       | 1 s  | `RegistrationsSound` violated |
| `pl-fault-settle`       | safety            | 5 831     | 1 s  | `SettleOnlyOnCancel` violated |
| `pl-fault-requeue`      | safety            | 2 108     | 1 s  | `ReturnConsistent` violated   |
| `mx-deadline`           | safety, liveness  | 22 516    | 9 s  | pass                          |
| `mx-bound2`             | safety, liveness  | 5 328     | 3 s  | pass                          |
| `mx-fork`               | safety, liveness  | 10 716    | 5 s  | pass                          |
| `mx-witness-handoff`    | `NoHandoff`       | 251       | 1 s  | violated, as required         |
| `mx-witness-withdraw`   | `NoWithdrawal`    | 87        | 1 s  | violated, as required         |
| `mx-fault-nohandoff`    | `AcquisitionsEnd` | 1 920     | 1 s  | liveness violated             |
| `mx-fault-purevalidate` | `AcquisitionsEnd` | 1 842     | 1 s  | liveness violated             |
| `mx-fault-nopasson`     | `AcquisitionsEnd` | 24 736    | 5 s  | liveness violated             |
| `mx-fault-twodesig`     | `Designation`     | 1 631     | 1 s  | violated                      |
| `im-basic`              | safety, liveness  | 67 349    | 24 s | pass                          |
| `im-fork`               | safety, liveness  | 34 463    | 14 s | pass                          |
| `im-witness-baton`      | `NoBatonPass`     | 637       | 1 s  | violated, as required         |
| `im-witness-withdraw`   | `NoWithdrawal`    | 280       | 1 s  | violated, as required         |
| `im-fault-cancel`       | `MutualExclusion` | 741       | 1 s  | violated                      |
| `cv-mutex`              | safety            | 2 107 194 | 20 s | pass                          |
| `cv-imutex`             | safety            | 1 029 454 | 10 s | pass                          |
| `cv-mutex-live`         | safety, liveness  | 10 983    | 4 s  | pass                          |
| `cv-imutex-live`        | safety, liveness  | 12 977    | 4 s  | pass                          |
| `cv-witness-withdraw`   | `NoWithdrawal`    | 479       | 1 s  | violated, as required         |
| `cv-fault-reacquire`    | `WaitReturn`      | 14 761    | 2 s  | violated                      |

Liveness checking costs about twenty times the safety search, so the
three-thread configurations with the largest spaces check safety only and
a two-thread configuration of the same feature checks liveness
(`pl-live-*`, `cv-*-live`). The three-thread lock configurations turn the
parker's spurious returns off (`EnableSpurious = FALSE`); a late delivery
still wakes a sleep that then re-sleeps. Spurious returns stay on in
`mx-bound2`, the two-thread `cv-*-live` configurations, every witness and
fault configuration, and all of `ParkingLot.tla`, which always has them.

## What the model abstracts

- **Bucket locks.** `ParkingLot.tla` makes them explicit: an operation
  acquires its bucket (a requeue both, in ascending order) in one step and
  runs its body, the bounded code of SYP12, in the next. `LockProtocols.tla`
  runs each parking-lot operation as one atomic step. That is exact for
  the protocols because each body performs at most one read-modify-write of
  the lock word, the only state the lock-free fast paths share with it. The
  three-state bucket word of SYP13 and its `bucketWait` are not modelled.
- **The parker.** A sleep returns woken (fairly, once a delivery set the
  waiter's parker word), spuriously, timed out when armed with a deadline,
  or cancelled when armed interruptible and a request is pending; the
  parking lot decides the outcome. The scheduler consumes a request at
  `settle` (Zig's rule); a latching scheduler differs only in leaving it
  pending, which no invariant depends on.
- **Not modelled:** the seam (SYF1–SYF4), parker installation and pinning
  (SYK1, SYK9), spinning (SYK7, SYM9), memory ordering (SYH1, SYH2: oracles
  1, 4 and 9), bits outside `LockBits`'s three (SYL2), a condition used with
  two locks (SYC4), allocation and attributes.

## Requirement map

### `ParkingLot.tla` (S1)

| Requirement | Actions                                                                             | Checked by                                                                   |
| ----------- | ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| SYP1        | `BucketOf`, `SharedBucket`                                                          | `pl-requeue-shared` against `pl-requeue`                                     |
| SYP2        | `WLock`, `WBody`; fault `ReadEarly`                                                 | `NoLostWakeup`; `pl-fault-validate`                                          |
| SYP3        | (no client code runs between enqueue and sleep in S1; see `LockProtocols`' `CPark`) | —                                                                            |
| SYP4        | `Sleep*`, `WRes`, `WRBody`                                                          | `ReturnConsistent`, `QueueConsistent`                                        |
| SYP5        | `WRes`, `WRBody` (`dequeued` wins)                                                  | `ReturnConsistent`; `pl-witness-race`; `pl-fault-timeout`                    |
| SYP6, SYP7  | `SBody`, `KBody`, `Commit`                                                          | `QueueConsistent`, `WakesReturn`                                             |
| SYP8        | `StartRequeue`, `RLock1`, `RLock2`, `RBody`, the key re-check in `WRBody`           | `pl-requeue*`, `SignalsComplete`                                             |
| SYP9        | `FBody`                                                                             | `pl-filter`                                                                  |
| SYP10, SYK8 | `Commit`, `Deliver`                                                                 | `pl-witness-late`; `pl-fault-delivery`                                       |
| SYP14       | `Moved`, `WRBody`'s spurious branch                                                 | `TagsConsistent`, `ReturnConsistent`; `pl-fault-requeue`                     |
| SYP15       | `KBody` registers, `WRet`/`RetLock`/`RetBody` retire                                | `RegistrationsSound`, `RegistrationsRetire`; `pl-fault-retire`               |
| SYK2, SYK4  | `WBody`/`WRBody` prepare, `Finish`                                                  | `ReturnConsistent`                                                           |
| SYI1, SYI3  | `SleepCancel`, `WRBody`'s cancelled branch                                          | `SettleOnlyOnCancel`, `ReturnConsistent`; `pl-fault-settle`                  |
| SYX1        | `Fork`                                                                              | `BucketsHeldByHolders` and every invariant in `pl-fork`, `pl-live-designate` |
| withdrawal  | `SleepTimeout`, `SleepCancel`                                                       | `pl-witness-withdraw`                                                        |

### `LockProtocols.tla` (S2)

| Requirement | Actions                                                                                   | Checked by                                                                                        |
| ----------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| SYL1, SYM2  | `MTry`, `MUnlock` (fast paths)                                                            | `MutualExclusion`                                                                                 |
| SYM3        | `MGiveUp`, `Resolve`'s timeout branch                                                     | `mx-witness-withdraw`, `AcquisitionsEnd`                                                          |
| SYM5        | `MUnlock`, `MUnlockSlow`                                                                  | `MutualExclusion`                                                                                 |
| SYM6        | `MUnlock` (no wake while designated), `MUnlockSlow`, `MGiveUp` passes on                  | `Designation`, `DesignationsEnd`, `DesignatedBitClears`; `mx-fault-twodesig`, `mx-fault-nopasson` |
| SYM7        | `MTry` on a free lock, whoever is designated                                              | `mx-deadline`                                                                                     |
| SYM8        | `MPark` counts losses, promotes; `MUnlockSlow` hands off                                  | `HandoffAtHead`, `AcquisitionsEnd`; `mx-witness-handoff`, `mx-fault-nohandoff`                    |
| SYP15       | `Backed` recomputed in `MPark`, `MRetire`, `MUnlockSlow`                                  | `Designation`, `ParkedBit`, `DesignatedBitClears`, `mx-fork`                                      |
| SYJ1, SYJ2  | `ITry`, `IPark`, `IUnlock`, `IUnlockSlow`                                                 | `MutualExclusion`, `im-witness-withdraw`                                                          |
| SYJ3        | `IUnlockSlow` commits; `Resolve` keeps a committed grant                                  | `MutualExclusion`; `im-witness-baton`, `im-fault-cancel`                                          |
| SYJ5        | `IUnlockSlow` (handoff whenever parked)                                                   | `HandoffLockNeverFreeWithWaiters`, `AcquisitionsEnd`                                              |
| SYC1, SYC8  | `CPark` binds; `Notify`'s one-load path; `Resolve` unbinds                                | `ConditionBit`                                                                                    |
| SYC2        | `CPark`, `Unparked` (handoff, designation, notified)                                      | `WaitReturn`, `SelectedReturn`                                                                    |
| SYC3        | `Reacquire` (never interruptible, no deadline)                                            | `WaitReturn`; `cv-witness-withdraw`, `cv-fault-reacquire`                                         |
| SYC5, SYC6  | `Notify` (move onto a held lock; wake one and move the rest; acquire a free handoff lock) | `cv-*`, `NoLostWakeup`                                                                            |
| SYC7        | `MovedRec`, `Unparked`                                                                    | `WaitReturn`, `SelectedReturn`                                                                    |
| SYC9        | `Kind`                                                                                    | `cv-mutex*` and `cv-imutex*`                                                                      |
| SYI3        | `Resolve`'s cancelled branch                                                              | `SettleOnce`, `WaitReturn`                                                                        |
| SYX1        | `Fork`, `Stuck`                                                                           | `HeldStaysHeld`; `mx-fork`, `im-fork`                                                             |

Oracle 1's safety invariants appear as `MutualExclusion`,
`QueueConsistent` (exactly one outcome per park: a dequeued record is in no
queue and is never dequeued again), `NoLostWakeup`, `Designation` (at most
one designated waker) and `TagsConsistent`. TLC's deadlock check is on
for every configuration; a child whose lock was held by a vanished thread
stutters (`Stuck`), since POSIX makes it wait forever.

Liveness assumes, as oracle 10 states, that every holder releases, every
committed wake is delivered and every loop keeps running: weak fairness on
every thread's steps and every delivery. Starting an operation, timeouts,
cancellations, spurious returns and the fork are not fair.

## Findings against the specification

**F1. Barging and weak fairness (SYM7, SYM8, oracle 10).** Oracle 10
requires that every mutex waiter that neither times out nor is cancelled
acquires the mutex, under weak fairness. If the park's validation only
checks that the mutex is still held and returns `false` otherwise, a
locker can alternate forever between a failed compare-and-swap (the mutex
is held) and an invalid park (it was released in between, then re-taken
by a barger), and it is never woken, so SYM8, which counts only races lost
after a wake, never promotes it. Two readings: (a) validation only
checks, and the liveness property needs strong fairness on acquisition;
(b) validation, under the bucket lock, is one read-modify-write that sets
the parked bit if the mutex is held and takes the mutex if it is free.
The model chooses (b), for `Mutex` and `InterruptibleMutex` alike;
`mx-fault-purevalidate` shows that (a) violates `AcquisitionsEnd` under
weak fairness. SPEC.md should say which, since SYP2's `validate` returns
only a boolean.

**F2. What a lost race is (SYM8).** "Woken and then loses the race to a
barging locker `starvationBound` times in a row" does not define a loss
or what restarts the count. The model counts, per `lock` call, each time a
designated waker's park validation finds the mutex held, and promotes the
waiter when the count reaches the bound; a waiter's first park, before
any wake, is not a loss.

**F3. Passing a designation on (SYM6).** A designated waker that returns
without the mutex must, "if waiters remain parked, wake one of them". The
spec does not say whether the woken waiter becomes the new designated
waker (registered, its bit set) or is woken plainly. The model designates
it, so that SYM6's at-most-one holds and the wake is backed by a
registration (SYP15); a plain wake would let a later unlock wake a second
waiter. It also leaves open when `lockUntil` may notice its deadline
outside a park; the model lets it give up at the point where it would
park.

**F4. Who reconciles the designated bit (SYP15, SYM6, testing.md).**
SYP15 requires reconciliation "whenever an operation finds [the state]
inconsistent", and testing.md's SYP15 row says the next contended
operation clears a stale bit. But an unlock that finds the designated bit
set makes no parking-lot call (SYM6, and its testing.md row), so it cannot
find the inconsistency: after a fork, a stale designated bit survives
every fast unlock. The model reconciles in every park on the mutex's key
and in every slow unlock, so the first waiter to park in the child clears
the bit and is then woken normally. Oracle 10's "no designation lasts
forever" therefore holds for registrations (`DesignationsEnd`) and for a
designated bit with a waiter behind it (`DesignatedBitClears`), but not
for a bare stale bit with no waiter, which is harmless. SPEC.md should
name the operations that reconcile.

**F5. A waiter woken by a notification on a free `Mutex` (SYC5, SYC6,
SYM6).** `notifyAll` on a free mutex "wakes one and moves the rest"; the
spec does not say whether the woken waiter is designated. The model does
not designate it (no unlock woke it): the moved waiters are parked on a
free mutex with no designated waker, and the woken waiter's own unlock, or
any barger's, wakes them. Liveness holds (`cv-mutex-live`), and the
no-lost-wakeup invariant has to count a notified waiter as "on its way".
If the intent is that a free mutex with parked waiters always has a
designated waker, SYC6 should say the notification designates it.

**F6. Bucket-lock fairness (SYP13, oracle 10).** S1's liveness properties
(every committed wake makes its park return, every registration retires,
every unpark completes) need each bucket acquisition to succeed
eventually. SYP13 promises nothing about fairness, and under weak fairness
alone a thread whose bucket is free only intermittently can be overtaken
forever. `ParkingLot.tla` assumes strong fairness for bucket acquisition
and says so; the specification should either state that assumption for
oracle 10 or require the bucket lock to be starvation-free.

**F7. Combined condition forms (SYC3).** `waitUntil` and
`waitInterruptible` are separate forms; no condition wait with both a
deadline and interruptibility is specified, while `InterruptibleMutex`'s
lock has an interruptible deadline form (SYJ2). The model gives each
condition waiter one of the two forms.
