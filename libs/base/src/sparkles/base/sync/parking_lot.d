/**
The parking lot (SPEC §3): a statically allocated table of buckets, each a
three-state lock and a FIFO queue of waiter records keyed by address.

Every decision that needs to see the queue runs while the bucket is locked:
a park's validation (SYP2) and an unpark's callback (SYP7), which see the
locked key through a `LockedKey`. Wakes are committed under the lock and
delivered after it is released (SYP10). A park's sleep result is tentative;
the parking lot settles its outcome under the bucket lock (SYP4, SYI3).

An unpark that dequeues more records than it can hold handles for commits
and delivers them in rounds: the records wait in a private chain, and a
waiter that finds itself dequeued but not yet committed sleeps again until
its wake arrives, so no handle outlives its record and nothing allocates.
*/
module sparkles.base.sync.parking_lot;

import sparkles.base.sync.parker;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.seam : Deadline, WakeCount;

@safe nothrow @nogc:

/// Buckets in the table (SYP11, SPEC §7).
enum size_t parkingBuckets = 1024;
/// `relax` steps a locker takes before parking (SYK7, SPEC §7).
enum uint spinSteps = 10;
/// Pause-only `relax` steps a designated waker takes before parking again (SYM9, SPEC §7).
enum uint designatedSpinSteps = 40;
/// Lost races before a waiter is handed the lock (SYM8, SPEC §7).
enum uint starvationBound = 4;

private enum uint bucketBits = 10;
static assert(1 << bucketBits == parkingBuckets);

/// Wakes committed per round of a multi-record unpark.
private enum uint deliveryRound = 64;

/// The bucket spin and the round size under `P`: the model uses 1 of each, so
/// contended bucket waits and multi-round unparks are reachable within its bound.
package(sparkles.base.sync) enum uint bucketSpinFor(P) = P.isModel ? 1 : spinSteps;
private enum uint roundFor(P) = P.isModel ? 1 : deliveryRound;

/// Why a park returned (SYP4).
enum ParkOutcome : ubyte
{
    unparked,
    invalid,
    timedOut,
    cancelled,
}

/// A park's outcome and, for `unparked`, the unparker's token.
struct ParkResult
{
    ParkOutcome outcome;
    size_t token;
}

/// What an unpark operation did, passed to its callback under the lock (SYP7).
struct UnparkResult
{
    /// Records dequeued to be woken.
    uint unparked;
    /// Records moved to another key (SYP8).
    uint requeued;
    /// Whether records of the key remain queued.
    bool haveMore;
    /// The park token of the first dequeued record.
    size_t firstParkToken;
}

/// An unpark callback's answer: the token every woken record receives.
struct UnparkDecision
{
    size_t token;
    /// Register the woken record as a designation (SYP15); `unparkOne` only.
    bool designate;
}

/// What a requeue does (SYP8).
enum RequeueOp : ubyte
{
    abort,
    unparkOne,
    requeueOne,
    unparkOneRequeueRest,
    requeueAll,
}

/// A filter's answer for one record (SYP9).
enum FilterOp : ubyte
{
    wake,
    skip,
    stop,
}

/// How a park enqueues its record.
struct ParkOptions
{
    /// The primitive's protocol tag (SYP14).
    ubyte protocol;
    /// What a filter sees (SYP9).
    size_t parkToken;
    Deadline deadline;
    /// Whether the sleep observes cancellation (SYI1).
    bool interruptible;
    /// Enqueue at the head: a waiter promoted by the starvation bound (SYM8).
    bool atHead;
    /// Pins the caller drops before it sleeps (a condition wait's lock; SYK9).
    uint pinAdjust;
}

/// The locked bucket of one key, as validation and callbacks see it.
struct LockedKey(P)
{
    private Bucket!P* bucket;
    private size_t key;

    /// Whether any record of this key is queued.
    bool hasQueued() const @trusted
    {
        for (const(WaitRecord!P)* r = bucket.head; r !is null; r = r.next)
            if (P.peek(r.key) == key)
                return true;
        return false;
    }

    /// The park token of the earliest queued record of this key, or `size_t.max`.
    size_t headParkToken() const @trusted
    {
        for (const(WaitRecord!P)* r = bucket.head; r !is null; r = r.next)
            if (P.peek(r.key) == key)
                return r.parkToken;
        return size_t.max;
    }

    /// Whether any record holds a registration under this key (SYP15).
    bool hasRegistration() const @trusted
    {
        for (const(WaitRecord!P)* r = bucket.registered; r !is null; r = r.regNext)
            if (r.regKey == key)
                return true;
        return false;
    }
}

alias Validate(P) = bool delegate(ref const LockedKey!P) @safe nothrow @nogc;
alias BeforeSleep = void delegate() @safe nothrow @nogc;
alias OnRemoved(P) = void delegate(ref const LockedKey!P, bool haveMore) @safe nothrow @nogc;
alias Callback(P) = UnparkDecision delegate(ref const LockedKey!P, UnparkResult) @safe nothrow @nogc;
alias RequeueValidate(P) = RequeueOp delegate(ref const LockedKey!P from,
    ref const LockedKey!P to) @safe nothrow @nogc;
alias RequeueCallback(P) = UnparkDecision delegate(ref const LockedKey!P from,
    ref const LockedKey!P to, UnparkResult) @safe nothrow @nogc;
alias Filter = FilterOp delegate(size_t parkToken) @safe nothrow @nogc;

// ---------------------------------------------------------------------------
// The table.

/// One bucket: its lock word, its queue and its registrations, on a line of its own.
align(64) struct Bucket(P)
{
package(sparkles.base.sync):
    /// 0 unlocked, 1 locked, 2 locked with waiters (SYP13).
    P.Atomic!uint word;
    WaitRecord!P* head, tail;
    WaitRecord!P* registered;
}

private template table(P)
{
    // The model's table is per thread: each test thread runs its own explorer.
    static if (P.isModel)
        Bucket!P[parkingBuckets] table;
    else
        __gshared Bucket!P[parkingBuckets] table;
}

/// The bucket index of `key`: Fibonacci hashing of the address.
size_t bucketIndex(size_t key) pure
{
    static if (size_t.sizeof == 8)
        return (key * 0x9E37_79B9_7F4A_7C15UL) >> (64 - bucketBits);
    else
        return (key * 0x9E37_79B9U) >> (32 - bucketBits);
}

private Bucket!P* bucketAt(P)(size_t index) @trusted => &table!P[index];

/// Resets every bucket: the fork child handler (SYX1) and the model between executions.
package(sparkles.base.sync) void resetTable(P)() @trusted
{
    foreach (ref b; table!P)
        b = Bucket!P.init;
}

// ---------------------------------------------------------------------------
// The bucket lock (SYP13).

private enum uint unlocked = 0, locked = 1, lockedWaiters = 2;

private Bucket!P* lockBucket(P)(size_t key)
{
    auto b = bucketAt!P(P.bucketOf(key));
    lockWord!P(b);
    return b;
}

private void lockWord(P)(Bucket!P* b)
{
    uint expected = unlocked;
    if (!P.cas!(Order.acquire, Order.relaxed)(b.word, expected, locked))
        lockWordSlow!P(b);
    P.bucketLocked();
}

private void lockWordSlow(P)(Bucket!P* b)
{
    // Bucket waits and spins use the effective parker: the thread parker
    // while pinned, so a pinned fiber sleeps its thread (SYK1, SYK9).
    auto eff = effectiveParker!P();
    foreach (step; 0 .. bucketSpinFor!P)
    {
        uint expected = unlocked;
        if (P.load!(Order.relaxed)(b.word) == unlocked
            && P.cas!(Order.acquire, Order.relaxed)(b.word, expected, locked))
            return;
        eff.vtbl.relax(eff.ctx, step);
    }
    // An acquirer that has waited takes the lock with waiters marked.
    while (P.exchange!(Order.acquire)(b.word, lockedWaiters) != unlocked)
        eff.vtbl.bucketWait(eff.ctx, b.word, lockedWaiters);
}

private void unlockBucket(P)(Bucket!P* b)
{
    if (releaseWord!P(b))
        P.seamWake(b.word, WakeCount.one);
}

/// Releases a bucket's word; whether a waiter must be woken, after every bucket is released (SYP10).
private bool releaseWord(P)(Bucket!P* b)
{
    P.bucketUnlocked();
    static if (P.isModel)
        if (P.faultActive(P.Fault.bucketUnlockSkipsWake))
        {
            P.store!(Order.release)(b.word, unlocked);
            return false;
        }
    return P.exchange!(Order.release)(b.word, unlocked) == lockedWaiters;
}

/// Locks the bucket that holds `rec` under its current key, which a requeue may change.
private Bucket!P* lockRecordBucket(P)(WaitRecord!P* rec) @trusted
{
    while (true)
    {
        const key = P.load!(Order.acquire)(rec.key);
        auto b = lockBucket!P(key);
        if (P.peek(rec.key) == key)
            return b;
        unlockBucket!P(b);
    }
}

/// Takes a bucket's word if it is free, without waiting.
private bool tryLockWord(P)(Bucket!P* b)
{
    uint expected = unlocked;
    if (!P.cas!(Order.acquire, Order.relaxed)(b.word, expected, locked))
        return false;
    P.bucketLocked();
    return true;
}

/// Locks two keys' buckets (SYP8). Nothing waits while holding a bucket
/// (SYP13): it takes one, tries the other, and if that is held releases the
/// first and waits for the other instead.
private void lockPair(P)(size_t k1, size_t k2, out Bucket!P* b1, out Bucket!P* b2)
{
    b1 = bucketAt!P(P.bucketOf(k1));
    b2 = bucketAt!P(P.bucketOf(k2));
    if (b1 is b2)
        return lockWord!P(b1);
    auto first = b1, second = b2;
    while (true)
    {
        lockWord!P(first);
        if (tryLockWord!P(second))
            return;
        unlockBucket!P(first);
        auto t = first;
        first = second;
        second = t;
    }
}

private void unlockPair(P)(Bucket!P* b1, Bucket!P* b2)
{
    // Both words first: no seam wake while the other bucket is still held.
    const w2 = b1 !is b2 && releaseWord!P(b2);
    const w1 = releaseWord!P(b1);
    if (w2)
        P.seamWake(b2.word, WakeCount.one);
    if (w1)
        P.seamWake(b1.word, WakeCount.one);
}

// ---------------------------------------------------------------------------
// Queue and registration edits, all under the bucket lock.

private void enqueue(P)(Bucket!P* b, WaitRecord!P* rec, bool atHead) @trusted
{
    rec.next = null;
    if (b.head is null)
        b.head = b.tail = rec;
    else if (atHead)
    {
        rec.next = b.head;
        b.head = rec;
    }
    else
    {
        b.tail.next = rec;
        b.tail = rec;
    }
}

/// Unlinks `rec`, whose predecessor is `prev` (null at the head).
private void unlink(P)(Bucket!P* b, WaitRecord!P* prev, WaitRecord!P* rec) @trusted
{
    if (prev is null)
        b.head = rec.next;
    else
        prev.next = rec.next;
    if (b.tail is rec)
        b.tail = prev;
    rec.next = null;
}

private bool remove(P)(Bucket!P* b, WaitRecord!P* rec) @trusted
{
    WaitRecord!P* prev;
    for (auto r = b.head; r !is null; prev = r, r = r.next)
        if (r is rec)
        {
            unlink!P(b, prev, r);
            return true;
        }
    return false;
}

private bool anyQueued(P)(Bucket!P* b, size_t key) @trusted
    => LockedKey!P(b, key).hasQueued;

private void register(P)(Bucket!P* b, WaitRecord!P* rec, size_t key) @trusted
{
    assert(!rec.registered, "a record holds one registration at a time (SYP15)");
    rec.registered = true;
    rec.regKey = key;
    rec.regNext = b.registered;
    b.registered = rec;
}

private void retireLocked(P)(Bucket!P* b, WaitRecord!P* rec) @trusted
{
    if (!rec.registered)
        return;
    WaitRecord!P* prev;
    for (auto r = b.registered; r !is null; prev = r, r = r.regNext)
        if (r is rec)
        {
            if (prev is null)
                b.registered = r.regNext;
            else
                prev.regNext = r.regNext;
            break;
        }
    rec.registered = false;
    rec.regNext = null;
}

/// SYP14: every record of `key` in the bucket belongs to `protocol`.
private void checkProtocol(P)(Bucket!P* b, size_t key, ubyte protocol) @trusted
{
    version (assert)
        for (auto r = b.head; r !is null; r = r.next)
            if (P.peek(r.key) == key)
                assert(r.protocol == protocol,
                    "one protocol per key (SYP14): a record of another primitive is queued here");
}

// ---------------------------------------------------------------------------
// Fork (SYX1).

version (Posix)
{
    /// Set once the child handler is registered. The slow paths read it: the
    /// lock code is all templates, which a program may instantiate in its own
    /// objects, and the read makes the linker keep this module, and with it
    /// the load-time registration.
    private shared bool forkHandlerRegistered;

    /// Registers the child handler when the image loads, before any caller
    /// can use a bucket (SYX1). Registration may allocate (glibc grows its
    /// handler list past 48 entries), so no lock operation performs it (SYA1).
    pragma(crt_constructor)
    private extern (C) void installForkHandler() @trusted nothrow @nogc
    {
        import core.atomic : atomicStore;
        import core.sys.posix.pthread : pthread_atfork;
        import core.stdc.stdlib : abort;

        // Without the handler a child could inherit a held bucket.
        if (pthread_atfork(null, null, &forkChild) != 0)
            abort();
        atomicStore(forkHandlerRegistered, true);
    }

    private void checkForkHandler() @trusted nothrow @nogc
    {
        import core.atomic : atomicLoad, MemoryOrder;

        if (!atomicLoad!(MemoryOrder.raw)(forkHandlerRegistered))
            assert(0, "the fork handler is not registered (SYX1)");
    }

    private extern (C) void forkChild() @trusted nothrow @nogc
    {
        // The child has one thread: every bucket unlocked and empty, and this
        // thread's record in no queue. Primitives keep their bits and recover
        // through SYP15 on their next contended operation.
        resetTable!NativePlatform();
        auto ts = NativePlatform.thread();
        ts.threadParker = typeof(ts.threadParker).init;
    }
}

private void enterSlowPath(P)()
{
    static if (!P.isModel)
        version (Posix)
            checkForkHandler();
}

// ---------------------------------------------------------------------------
// Park (SYP2–SYP5, SYP14, SYI3).

/**
Parks the caller under `key` while `validate` holds (SYP2): locks the key's
bucket, retires the caller's registration (SYP15), runs `validate`, and on
`true` enqueues the caller's record and sleeps until it is unparked, its
deadline passes, or, if interruptible, it is cancelled. `beforeSleep` runs
after the record is enqueued and the bucket released (SYP3). `onRemoved`
runs under the bucket lock when the park ends timed out or cancelled, with
whether records of the key remain.
*/
ParkResult park(P = NativePlatform)(size_t key, ParkOptions o, scope Validate!P validate,
    scope BeforeSleep beforeSleep = null, scope OnRemoved!P onRemoved = null)
{
    enterSlowPath!P();
    auto sp = effectiveParker!P(o.pinAdjust);
    auto rec = sp.vtbl.record(sp.ctx);
    scope (exit)
        P.parkReturned(rec);
    auto b = lockBucket!P(key);
    {
        // The registration is retired only once the park goes ahead: a
        // designated waker whose validation fails is still on its way.
        const lk = LockedKey!P(b, key);
        if (!validate(lk))
        {
            unlockBucket!P(b);
            return ParkResult(ParkOutcome.invalid);
        }
    }
    if (rec.registered)
    {
        assert(P.bucketOf(rec.regKey) == P.bucketOf(key),
            "a designated waker parks again under the key it was designated for");
        retireLocked!P(b, rec);
    }
    static if (P.isModel)
        if (P.faultActive(P.Fault.validateOutsideLock))
        {
            // Seeded fault: release the bucket between validation and enqueue.
            unlockBucket!P(b);
            b = lockBucket!P(key);
        }
    checkProtocol!P(b, key, o.protocol);
    P.recordTouched(rec);
    P.store!(Order.relaxed)(rec.key, key);
    rec.parkToken = o.parkToken;
    rec.unparkToken = 0;
    rec.deadline = o.deadline;
    rec.interruptible = o.interruptible;
    rec.protocol = o.protocol;
    rec.queued = true;
    rec.committed = false;
    rec.parker = sp;
    sp.vtbl.prepare(sp.ctx, rec);
    enqueue!P(b, rec, o.atHead);
    unlockBucket!P(b);
    if (beforeSleep !is null)
        beforeSleep();

    auto d = o.deadline;
    bool interruptible = o.interruptible;
    while (true)
    {
        const r = sp.vtbl.sleep(sp.ctx, rec, d, interruptible);
        if (r == SleepResult.woken && sp.vtbl.exactWake)
            return ParkResult(ParkOutcome.unparked, rec.unparkToken);
        b = lockRecordBucket!P(rec);
        if (!rec.queued)
        {
            // An unparker dequeued the record first: the park ends unparked
            // (SYP5), once its wake is committed and, for a parker whose
            // delivery touches the record, delivered.
            const committed = rec.committed;
            const token = rec.unparkToken;
            unlockBucket!P(b);
            static if (P.isModel)
                if (P.faultActive(P.Fault.timeoutIgnoresToken) && r == SleepResult.timedOut)
                    return ParkResult(ParkOutcome.timedOut);
            if (committed && (r == SleepResult.woken || !sp.vtbl.deliveryTouchesRecord))
                return ParkResult(ParkOutcome.unparked, token);
            d = Deadline.never;
            interruptible = false;
            continue;
        }
        // Still enqueued: judge the tentative result by its reason, against
        // the record's current registration (SYP14).
        const now = r == SleepResult.timedOut ? P.now() : 0;
        const valid = r == SleepResult.timedOut ? rec.deadline.passed(now)
            : r == SleepResult.cancelled ? rec.interruptible : false;
        if (valid)
        {
            const k = P.peek(rec.key);
            remove!P(b, rec);
            rec.queued = false;
            if (onRemoved !is null)
            {
                const lk = LockedKey!P(b, k);
                onRemoved(lk, anyQueued!P(b, k));
            }
            unlockBucket!P(b);
            if (r == SleepResult.cancelled)
            {
                sp.vtbl.settle(sp.ctx, rec);
                return ParkResult(ParkOutcome.cancelled);
            }
            return ParkResult(ParkOutcome.timedOut);
        }
        // Spurious: sleep again, re-prepared under the lock (SYP4).
        d = rec.deadline;
        interruptible = rec.interruptible;
        sp.vtbl.prepare(sp.ctx, rec);
        unlockBucket!P(b);
    }
}

/**
Retires the caller's registration (SYP15) under `key` and runs `callback`
under the bucket lock, so a primitive can end its designation in the same
critical section. `pinAdjust` as for `park`.
*/
void retire(P = NativePlatform)(size_t key, scope void delegate(ref const LockedKey!P) @safe nothrow @nogc callback = null,
    uint pinAdjust = 0)
{
    auto sp = effectiveParker!P(pinAdjust);
    auto rec = sp.vtbl.record(sp.ctx);
    auto b = lockBucket!P(key);
    if (rec.registered)
    {
        assert(rec.regKey == key, "a registration is retired under its own key");
        retireLocked!P(b, rec);
    }
    if (callback !is null)
    {
        const lk = LockedKey!P(b, key);
        callback(lk);
    }
    unlockBucket!P(b);
}

/// Whether the caller's record holds a registration (SYP15), for assertions.
bool callerRegistered(P = NativePlatform)(uint pinAdjust = 0)
{
    auto sp = effectiveParker!P(pinAdjust);
    return sp.vtbl.record(sp.ctx).registered;
}

// ---------------------------------------------------------------------------
// Unpark (SYP6–SYP10).

/// Commits `rec`'s wake under the lock: token, committed flag, then the parker's commit.
private WakeHandle commit(P)(WaitRecord!P* rec, size_t token) @trusted
{
    P.recordTouched(rec);
    rec.unparkToken = token;
    rec.committed = true;
    return rec.parker.vtbl.commitWake(rec.parker.ctx, rec);
}

/**
Dequeues the earliest record of `key` (SYP6) and, under the bucket lock, runs
`callback` with what it found; the callback's token is delivered to the
dequeued record, and `designate` registers it (SYP15). With `retireSelf`, the
caller's own registration under `key` is retired in the same critical
section. `precheck`, run under the lock before anything is dequeued, may
decline the wake; the callback then sees no record dequeued. Returns what the
callback saw.
*/
UnparkResult unparkOne(P = NativePlatform)(size_t key, ubyte protocol, scope Callback!P callback,
    bool retireSelf = false, uint pinAdjust = 0, scope Validate!P precheck = null)
{
    enterSlowPath!P();
    WaitRecord!P* self;
    if (retireSelf)
    {
        auto sp = effectiveParker!P(pinAdjust);
        self = sp.vtbl.record(sp.ctx);
    }
    auto b = lockBucket!P(key);
    if (self !is null && self.registered)
    {
        assert(self.regKey == key, "a registration is retired under its own key");
        retireLocked!P(b, self);
    }

    WaitRecord!P* found, prev;
    bool proceed = true;
    if (precheck !is null)
    {
        const lk = LockedKey!P(b, key);
        proceed = precheck(lk);
    }
    if (proceed)
        for (auto r = b.head; r !is null; prev = r, r = r.next)
            if (P.peek(r.key) == key)
            {
                assert(r.protocol == protocol, "one protocol per key (SYP14)");
                found = r;
                unlink!P(b, prev, r);
                break;
            }
    UnparkResult res;
    res.unparked = found !is null;
    res.haveMore = anyQueued!P(b, key);
    res.firstParkToken = found !is null ? found.parkToken : 0;
    const lk = LockedKey!P(b, key);
    const d = callback(lk, res);
    WakeHandle h;
    if (found !is null)
    {
        found.queued = false;
        if (d.designate)
            register!P(b, found, key);
        h = commit!P(found, d.token);
    }
    unlockBucket!P(b);
    static if (P.isModel)
        if (P.faultActive(P.Fault.unlockSkipsWake))
            return res;
    h.perform();
    return res;
}

/// Dequeues every record of `key`; the callback's token reaches all of them (SYP7).
UnparkResult unparkAll(P = NativePlatform)(size_t key, ubyte protocol, scope Callback!P callback)
    => unparkSelected!P(key, protocol, (size_t) => FilterOp.wake, callback);

/**
Offers each record of `key`, in queue order, to `filter` (SYP9), dequeues
those it wakes, and runs `callback` under the bucket lock; the callback's
token reaches every dequeued record.
*/
UnparkResult unparkFilter(P = NativePlatform)(size_t key, ubyte protocol, scope Filter filter,
    scope Callback!P callback)
    => unparkSelected!P(key, protocol, filter, callback);

private UnparkResult unparkSelected(P)(size_t key, ubyte protocol, scope Filter filter,
    scope Callback!P callback)
{
    enterSlowPath!P();
    auto b = lockBucket!P(key);
    // Detach the selected records into a private chain, in queue order. They
    // stay uncommitted, so their waiters cannot return before their wake.
    WaitRecord!P* chain, chainTail, prev;
    uint n;
    for (auto r = b.head; r !is null;)
    {
        auto next = r.next;
        if (P.peek(r.key) == key)
        {
            assert(r.protocol == protocol, "one protocol per key (SYP14)");
            const op = filter(r.parkToken);
            if (op == FilterOp.stop)
                break;
            if (op == FilterOp.wake)
            {
                unlink!P(b, prev, r);
                r.queued = false;
                r.committed = false;
                if (chain is null)
                    chain = chainTail = r;
                else
                {
                    chainTail.next = r;
                    chainTail = r;
                }
                ++n;
                r = next;
                continue;
            }
        }
        prev = r;
        r = next;
    }
    UnparkResult res;
    res.unparked = n;
    res.haveMore = anyQueued!P(b, key);
    res.firstParkToken = chain !is null ? chain.parkToken : 0;
    const lk = LockedKey!P(b, key);
    const d = callback(lk, res);
    assert(!d.designate || n <= 1, "only unparkOne designates (SYP15)");

    // Commit and deliver in rounds.
    WakeHandle[roundFor!P] handles;
    while (true)
    {
        uint k;
        while (chain !is null && k < roundFor!P)
        {
            auto r = chain;
            chain = r.next;
            r.next = null;
            if (d.designate)
                register!P(b, r, key);
            handles[k++] = commit!P(r, d.token);
        }
        unlockBucket!P(b);
        foreach (ref h; handles[0 .. k])
            h.perform();
        if (chain is null)
            break;
        lockWord!P(b);
    }
    return res;
}

/**
Requeues records of `from` onto `to` (SYP8): locks both buckets in a fixed
order, and as `validate` decides wakes one record of `from`, moves one or all
of them, or both, or aborts. A moved record keeps its relative order, joins
the tail of `to`'s queue, takes `toProtocol`'s tag (which `validate` may set), becomes
non-interruptible with no deadline (SYP14), and does not wake.
*/
UnparkResult unparkRequeue(P = NativePlatform)(size_t from, ubyte fromProtocol, size_t to,
    ref ubyte toProtocol, scope RequeueValidate!P validate, scope RequeueCallback!P callback)
{
    assert(from != to, "a requeue onto its own key");
    enterSlowPath!P();
    Bucket!P* bf, bt;
    lockPair!P(from, to, bf, bt);
    const lkf = LockedKey!P(bf, from), lkt = LockedKey!P(bt, to);
    const op = validate(lkf, lkt);
    if (op == RequeueOp.abort)
    {
        unlockPair!P(bf, bt);
        return UnparkResult.init;
    }
    const wakeOne = op == RequeueOp.unparkOne || op == RequeueOp.unparkOneRequeueRest;
    const moveAll = op == RequeueOp.requeueAll || op == RequeueOp.unparkOneRequeueRest;
    const moveOne = op == RequeueOp.requeueOne;

    // Collect the moved records first, so appending them to `to` (possibly
    // the same bucket) cannot revisit them.
    WaitRecord!P* woken, moved, movedTail, prev;
    uint nMoved;
    for (auto r = bf.head; r !is null;)
    {
        auto next = r.next;
        if (P.peek(r.key) == from)
        {
            assert(r.protocol == fromProtocol, "one protocol per key (SYP14)");
            if (wakeOne && woken is null)
            {
                unlink!P(bf, prev, r);
                woken = r;
                if (!moveAll)
                    break;
                r = next;
                continue;
            }
            if (moveAll || (moveOne && nMoved == 0))
            {
                unlink!P(bf, prev, r);
                if (moved is null)
                    moved = movedTail = r;
                else
                {
                    movedTail.next = r;
                    movedTail = r;
                }
                ++nMoved;
                if (!moveAll)
                    break;
                r = next;
                continue;
            }
            break;
        }
        prev = r;
        r = next;
    }
    checkProtocol!P(bt, to, toProtocol);
    for (auto r = moved; r !is null;)
    {
        auto next = r.next;
        P.recordTouched(r);
        P.store!(Order.release)(r.key, to);
        r.protocol = toProtocol;
        // The token meant something to the old protocol only.
        r.parkToken = 0;
        r.interruptible = false;
        r.deadline = Deadline.never;
        enqueue!P(bt, r, false);
        r = next;
    }
    UnparkResult res;
    res.unparked = woken !is null;
    res.requeued = nMoved;
    res.haveMore = anyQueued!P(bf, from);
    res.firstParkToken = woken !is null ? woken.parkToken : 0;
    const d = callback(lkf, lkt, res);
    assert(!d.designate, "a requeue's woken record is not a designation");
    WakeHandle h;
    if (woken !is null)
    {
        woken.queued = false;
        h = commit!P(woken, d.token);
    }
    unlockPair!P(bf, bt);
    h.perform();
    return res;
}
