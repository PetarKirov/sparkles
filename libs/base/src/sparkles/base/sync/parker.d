/**
Parkers: what a park enqueues, and how its waiter sleeps and is woken
(SPEC §4).

A $(LINK2 ../../../../docs/glossary.md#parker, parker) supplies the record a
park enqueues and the operations the parking lot cannot perform itself:
`prepare`, `sleep`, `commitWake`, the delivery of a wake, `bucketWait`,
`relax`, `settle`, and the protected-region query of §4a. It is a table of
function pointers, so a scheduler can install its own at run time (SYK1);
`sparkles:event-horizon`'s fiber parker is one.

Each thread has a current parker, the thread parker by default. Holding a
non-interruptible lock pins the caller (SYK9): while pinned, every park,
bucket wait and spin uses the thread parker.
*/
module sparkles.base.sync.parker;

import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.seam : Deadline, SeamResult, WakeCount;
static import sparkles.base.sync.seam;

@safe nothrow @nogc:

/// What a parker's `sleep` reports. The parking lot decides the park's outcome (SYI3).
enum SleepResult : ubyte
{
    woken,
    timedOut,
    cancelled,
}

/**
A committed wake, delivered after the bucket lock is released (SYP10). It
never refers to the woken record's storage (SYK8): the thread parker's names
its word's address, a fiber parker's names scheduler storage.
*/
struct WakeHandle
{
    /// Delivers the wake; `null` for a wake that needs no delivery.
    void function(size_t a, size_t b) @safe nothrow @nogc deliver;
    size_t a, b;

    /// Performs the delivery.
    void perform() const @safe nothrow @nogc => deliver !is null ? deliver(a, b) : cast(void) 0;
}

/**
One waiter, owned by the parking lot while it is enqueued (SYK4). The fields
are guarded by the bucket of the record's current key; `key` alone is read
before the bucket is locked, to find it.
*/
struct WaitRecord(P)
{
package(sparkles.base.sync):
    WaitRecord* next;
    WaitRecord* regNext;
    P.Atomic!size_t key;
    size_t regKey;
    size_t parkToken, unparkToken;
    Deadline deadline;
    Parker!P parker;
    ubyte protocol;
    bool interruptible;
    /// In a queue.
    bool queued;
    /// Dequeued and its wake committed; false while an unpark still holds it.
    bool committed;
    /// Registered as a designation (SYP15) in the bucket of `regKey`.
    bool registered;
}

/// A parker's operations (SYK2). `ctx` is the parker's own state.
struct ParkerVtbl(P)
{
    /// The record this parker's waiter parks with.
    WaitRecord!P* function(void* ctx) @safe nothrow @nogc record;
    /// Run under the bucket lock before every sleep of a park (SYK2, SYP4).
    void function(void* ctx, WaitRecord!P* rec) @safe nothrow @nogc prepare;
    /// Sleeps; `cancelled` only when `interruptible`.
    SleepResult function(void* ctx, WaitRecord!P* rec, Deadline d, bool interruptible) @safe nothrow @nogc sleep;
    /// Run by an unparker under the bucket lock; returns the handle to deliver.
    WakeHandle function(void* ctx, WaitRecord!P* rec) @safe nothrow @nogc commitWake;
    /// One bounded wait for a contended bucket whose word holds `expected` (SYP13).
    void function(void* ctx, ref P.Atomic!uint word, uint expected) @safe nothrow @nogc bucketWait;
    /// One step of a spin (SYK7).
    void function(void* ctx, uint step) @safe nothrow @nogc relax;
    /// Run once a park's final outcome is cancelled (SYI3).
    void function(void* ctx, WaitRecord!P* rec) @safe nothrow @nogc settle;
    /// Whether the caller is in a cancellation-protected region (SYI4).
    bool function(void* ctx) @safe nothrow @nogc inProtectedRegion;
    /// `woken` from `sleep` means the record was dequeued and committed.
    bool exactWake;
    /// Delivery touches the record, so the waiter must absorb it before returning (SYF2).
    bool deliveryTouchesRecord;
}

/// A parker: its operations and its state.
struct Parker(P)
{
    const(ParkerVtbl!P)* vtbl;
    void* ctx;

    /// Whether this is a parker at all; the default `.init` is not.
    bool opCast(T : bool)() const => vtbl !is null;
}

/// Each thread's parker state (SYK1, SYK9).
struct ThreadState(P)
{
package(sparkles.base.sync):
    Parker!P current;
    uint pins;
    ThreadParker!P threadParker;
}

/// The thread parker of the calling thread.
Parker!P threadParkerOf(P)(ThreadState!P* ts) @trusted
    => Parker!P(&threadParkerVtbl!P, cast(void*) &ts.threadParker);

/**
The effective parker (SYK1): the current parker, or the thread parker while
the caller is pinned. `pinAdjust` discounts pins the caller is about to drop,
as a condition wait does for its lock's pin (SYK9).
*/
Parker!P effectiveParker(P)(uint pinAdjust = 0)
{
    auto ts = P.thread();
    assert(ts.pins >= pinAdjust);
    if (ts.pins - pinAdjust > 0 || !ts.current)
        return threadParkerOf!P(ts);
    return ts.current;
}

/// Pins the caller: a non-interruptible lock was acquired (SYK9). Pins nest.
void pin(P = NativePlatform)() => cast(void) ++P.thread().pins;

/// Drops one pin.
void unpin(P = NativePlatform)()
{
    auto ts = P.thread();
    assert(ts.pins > 0, "unpin without a pin");
    --ts.pins;
}

/// The caller's pin count.
uint pins(P = NativePlatform)() => P.thread().pins;

/**
Installs `p` as the calling thread's current parker and returns the previous
one, which the scheduler restores when it stops (SYK1). `Parker.init` is the
thread parker.
*/
Parker!P installParker(P = NativePlatform)(Parker!P p)
{
    auto ts = P.thread();
    auto previous = ts.current;
    ts.current = p;
    return previous;
}

// ---------------------------------------------------------------------------
// The thread parker (SYK3).

/// Values of the thread parker's word.
private enum uint parkIdle = 0, parkSleeping = 1;

/// Whether `P`'s thread parker is the portable fallback (SYF2).
template isPortable(P)
{
    static if (P.isModel)
        enum isPortable = P.portableThreadParker;
    else
        enum isPortable = !sparkles.base.sync.seam.hasNativeSeam;
}

/**
The thread parker's state: its record in thread-local storage, and the word
it sleeps on through the seam, or, for the portable fallback, its own mutex,
condition variable and flag (SYF2).
*/
struct ThreadParker(P)
{
package(sparkles.base.sync):
    WaitRecord!P record;
    static if (isPortable!P && !P.isModel)
        PortableSleeper sleeper;
    else static if (isPortable!P)
        P.PortableSleeper sleeper;
    else
        P.Atomic!uint word;
}

/// The thread parker's operations.
template threadParkerVtbl(P)
{
    static immutable ParkerVtbl!P threadParkerVtbl = ParkerVtbl!P(
        &tpRecord!P, &tpPrepare!P, &tpSleep!P, &tpCommit!P, &tpBucketWait!P,
        &tpRelax!P, &tpSettle!P, &tpProtected!P,
        // `woken` comes only from a commit (the word) or a delivery (the flag).
        exactWake: true,
        deliveryTouchesRecord: isPortable!P,
    );
}

private ThreadParker!P* tp(P)(void* ctx) @trusted => cast(ThreadParker!P*) ctx;

private WaitRecord!P* tpRecord(P)(void* ctx) @trusted => &tp!P(ctx).record;

private void tpPrepare(P)(void* ctx, WaitRecord!P* rec)
{
    static if (isPortable!P)
        tp!P(ctx).sleeper.prepare();
    else
        P.store!(Order.relaxed)(tp!P(ctx).word, parkSleeping);
}

private SleepResult tpSleep(P)(void* ctx, WaitRecord!P* rec, Deadline d, bool interruptible)
{
    auto t = tp!P(ctx);
    static if (isPortable!P)
        return t.sleeper.sleep(d) ? SleepResult.woken : SleepResult.timedOut;
    else
    {
        while (true)
        {
            if (P.load!(Order.acquire)(t.word) != parkSleeping)
                return SleepResult.woken;
            if (P.seamWait(t.word, parkSleeping, d) == SeamResult.timedOut
                && P.load!(Order.acquire)(t.word) == parkSleeping)
                return SleepResult.timedOut;
        }
    }
}

private WakeHandle tpCommit(P)(void* ctx, WaitRecord!P* rec) @trusted
{
    auto t = tp!P(ctx);
    static if (isPortable!P)
        return WakeHandle(&portableDeliver!P, cast(size_t) ctx, 0);
    else
    {
        static if (P.isModel)
            if (P.faultActive(P.Fault.commitRelaxed))
            {
                // Seeded fault: the commit's release store weakened to relaxed.
                P.store!(Order.relaxed)(t.word, parkIdle);
                return WakeHandle(&seamDeliver!P, cast(size_t) &t.word, 0);
            }
        P.store!(Order.release)(t.word, parkIdle);
        return WakeHandle(&seamDeliver!P, cast(size_t) &t.word, 0);
    }
}

private void seamDeliver(P)(size_t word, size_t)
{
    static if (__traits(compiles, P.seamWakeAddress(word, WakeCount.one)))
        P.seamWakeAddress(word, WakeCount.one);
}

private void portableDeliver(P)(size_t ctx, size_t)
{
    static if (isPortable!P)
        tp!P(cast(void*) ctx).sleeper.deliver();
}

private void tpBucketWait(P)(void* ctx, ref P.Atomic!uint word, uint expected)
    => cast(void) P.seamWait(word, expected, Deadline.never);

private void tpRelax(P)(void* ctx, uint step)
{
    // SYK7: processor pause hints, then thread yields.
    if (step < 3)
        foreach (_; 0 .. 2 << step)
            P.pause();
    else
        P.yieldThread();
}

private void tpSettle(P)(void* ctx, WaitRecord!P* rec)
{
    assert(0, "the thread parker never reports cancelled (SYK3)");
}

private bool tpProtected(P)(void* ctx) => false;

// ---------------------------------------------------------------------------
// The portable fallback's sleeper (SYF2): a mutex, a condition variable and a
// flag per thread. The waiter reads the flag only under its own mutex, and
// delivery sets it and signals under that mutex, so the waiter cannot return
// before delivery has released the mutex.

// The bindings live at module scope: a declaration inside a function body
// takes D mangling, whatever its linkage, and then fails to link.
version (Windows)
{
    private struct SRWLOCK
    {
        void* ptr;
    }

    private struct CONDITION_VARIABLE
    {
        void* ptr;
    }

    private extern (Windows) nothrow @nogc @system
    {
        void AcquireSRWLockExclusive(SRWLOCK*);
        void ReleaseSRWLockExclusive(SRWLOCK*);
        void WakeConditionVariable(CONDITION_VARIABLE*);
        int SleepConditionVariableSRW(CONDITION_VARIABLE*, SRWLOCK*, uint, uint);
    }
}
else version (OSX)
{
    import core.sys.posix.sys.types : pthread_cond_t, pthread_mutex_t;
    import core.sys.posix.time : timespec;

    private extern (C) int pthread_cond_timedwait_relative_np(pthread_cond_t*,
        pthread_mutex_t*, const timespec*) nothrow @nogc @system;
}

/// The portable sleeper, per OS.
struct PortableSleeper
{
nothrow @nogc:
    version (Windows)
    {
        private SRWLOCK lock;
        private CONDITION_VARIABLE cond;
    }
    else version (Posix)
    {
        import core.sys.posix.pthread : pthread_cond_t, pthread_mutex_t,
            PTHREAD_MUTEX_INITIALIZER;

        private pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
        private pthread_cond_t cond;
        private bool condReady;
    }
    private bool flag;

    /// Clears the flag before a sleep.
    void prepare() @trusted
    {
        acquire();
        flag = false;
        release();
    }

    /// Sleeps until delivered or the deadline passes; true when delivered.
    bool sleep(Deadline d) @trusted
    {
        import core.time : MonoTime;

        acquire();
        scope (exit)
            release();
        while (!flag)
        {
            if (d.passed(MonoTime.currTime.ticks))
                return false;
            waitOnce(d);
        }
        return true;
    }

    /// Sets the flag and signals, under the mutex.
    void deliver() @trusted
    {
        acquire();
        flag = true;
        signal();
        release();
    }

    version (Windows)
    {
        private void acquire() @system
        {

            AcquireSRWLockExclusive(&lock);
        }

        private void release() @system
        {

            ReleaseSRWLockExclusive(&lock);
        }

        private void signal() @system
        {

            WakeConditionVariable(&cond);
        }

        private void waitOnce(Deadline d) @system
        {
            import sparkles.base.sync.seam : remainingNanoseconds;

            uint ms = uint.max;
            if (!d.isNever)
            {
                const ns = remainingNanoseconds(d);
                const ceil = (ns + 999_999) / 1_000_000;
                ms = ceil >= uint.max ? uint.max - 1 : cast(uint) ceil;
            }
            cast(void) SleepConditionVariableSRW(&cond, &lock, ms, 0);
        }
    }
    else version (Posix)
    {
        private void acquire() @system
        {
            import core.sys.posix.pthread : pthread_mutex_lock;

            cast(void) pthread_mutex_lock(&lock);
            if (!condReady)
                initCond();
        }

        private void release() @system
        {
            import core.sys.posix.pthread : pthread_mutex_unlock;

            cast(void) pthread_mutex_unlock(&lock);
        }

        private void signal() @system
        {
            import core.sys.posix.pthread : pthread_cond_signal;

            cast(void) pthread_cond_signal(&cond);
        }

        private void initCond() @system
        {
            import core.sys.posix.pthread : pthread_cond_init;

            version (OSX)
                cast(void) pthread_cond_init(&cond, null);
            else
            {
                import core.sys.posix.pthread : pthread_condattr_t, pthread_condattr_init,
                    pthread_condattr_setclock, pthread_condattr_destroy;
                import core.sys.posix.time : CLOCK_MONOTONIC;

                pthread_condattr_t attr;
                cast(void) pthread_condattr_init(&attr);
                cast(void) pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
                cast(void) pthread_cond_init(&cond, &attr);
                cast(void) pthread_condattr_destroy(&attr);
            }
            condReady = true;
        }

        private void waitOnce(Deadline d) @system
        {
            import core.sys.posix.pthread : pthread_cond_wait;

            if (d.isNever)
            {
                cast(void) pthread_cond_wait(&cond, &lock);
                return;
            }
            version (OSX)
            {
                import core.sys.posix.time : timespec;
                import sparkles.base.sync.seam : remainingNanoseconds;

                const ns = remainingNanoseconds(d);
                timespec ts;
                ts.tv_sec = cast(typeof(ts.tv_sec))(ns / 1_000_000_000L);
                ts.tv_nsec = cast(typeof(ts.tv_nsec))(ns % 1_000_000_000L);
                cast(void) pthread_cond_timedwait_relative_np(&cond, &lock, &ts);
            }
            else
            {
                import core.sys.posix.pthread : pthread_cond_timedwait;
                import core.sys.posix.time : timespec;
                import core.time : convClockFreq, MonoTime;

                const ns = convClockFreq(d.ticks, MonoTime.ticksPerSecond, 1_000_000_000L);
                timespec ts;
                ts.tv_sec = cast(typeof(ts.tv_sec))(ns / 1_000_000_000L);
                ts.tv_nsec = cast(typeof(ts.tv_nsec))(ns % 1_000_000_000L);
                cast(void) pthread_cond_timedwait(&cond, &lock, &ts);
            }
        }
    }
}

/**
Whether an interruptible operation's sleep observes cancellation now: only
outside a protected region of the effective parker (SYI1, SYI4).
*/
bool observesCancellation(P)(bool interruptible, uint pinAdjust = 0)
{
    if (!interruptible)
        return false;
    auto eff = effectiveParker!P(pinAdjust);
    return !eff.vtbl.inProtectedRegion(eff.ctx);
}
