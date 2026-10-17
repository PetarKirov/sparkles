/**
Locks, condition variables and waiting primitives over one parking lot
($(LINK2 ../../../../docs/specs/base/sync/SPEC.md, specification)).

Every primitive is a few bits of atomic state and allocates nothing; its
waiters queue in a statically allocated table keyed by address, so the same
primitive serves threads and, through a scheduler's parker, fibers.

- `Mutex` and `LockBits`: a non-interruptible lock for short critical
    sections, one byte or three bits of a caller's word. Holding one pins the
    caller to the thread parker.
- `InterruptibleMutex`: a lock a cancelled fiber stops waiting for, acquired
    only through guards.
- `Guarded!T`, `InterruptibleGuarded!T`: data reachable only through a guard.
- `Condition`: a condition variable that moves notified waiters onto the
    lock's queue.
- `Once`: a one-time initializer.

Schedulers install their own parker with `installParker` (SPEC §4).
*/
module sparkles.base.sync;

public import sparkles.base.sync.condition : Condition, ConditionT;
public import sparkles.base.sync.guarded : contained, Guarded, GuardedGuard, GuardedT,
    InterruptibleGuarded, InterruptibleGuardedT, isContainedPayload;
public import sparkles.base.sync.interruptible_mutex : Acquisition, InterruptibleGuard,
    InterruptibleMutex, InterruptibleMutexT, WaitStatus;
public import sparkles.base.sync.mutex : LockBits, Mutex, MutexGuard, MutexT;
public import sparkles.base.sync.once : Once, OnceT;
public import sparkles.base.sync.parker : installParker, Parker, ParkerVtbl, SleepResult,
    WaitRecord, WakeHandle;
public import sparkles.base.sync.parking_lot : parkingBuckets, spinSteps, starvationBound;
public import sparkles.base.sync.platform : NativePlatform;
public import sparkles.base.sync.seam : Deadline;
