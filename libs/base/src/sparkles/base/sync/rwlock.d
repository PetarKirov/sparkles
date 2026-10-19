/**
The reader–writer lock (primitives.md §7): shared, exclusive and upgradable
modes in one word (SYR1, SYR2).

The word holds a writer bit, an upgradable bit, a parked bit and the reader
count. Nobody barges past parked waiters: every fast path fails while the
parked bit is set, so once a writer or upgrader is parked, new shared
acquirers park behind it (SYR3). A release that finds waiters keeps its mode
until it has run one `unparkFilter` pass over the queue (SYR5): the pass
grants modes to the waiters at the head — one exclusive waiter, or every
shared waiter and at most one upgradable waiter up to the first writer —
and replaces the releaser's mode with those grants in one read–modify–write,
so the waiters return holding what they were granted.

An exclusive acquisition or an upgrade that finds only readers sets the
writer bit, which admits no new reader, and waits for the readers present
then to leave, on a key of its own, one byte past the lock's (SYR4, DS20);
the last of them wakes it. Queued writers cannot acquire while an upgradable
holder exists, so an upgrade outranks them.

Holding any mode pins the caller (SYK9): it is a non-interruptible lock, and
acquisition has deadline forms but no interruptible ones (SYR2).
Acquiring shared mode while already holding the lock is a programming error
(SYR6).
*/
module sparkles.base.sync.rwlock;

import core.time : MonoTime;

import sparkles.base.sync.parker : pin, unpin;
import sparkles.base.sync.parking_lot;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.protocol;
import sparkles.base.sync.seam : Deadline;

private enum size_t writer = 1, upgradable = 2, parked = 4, oneReader = 8;

private size_t readersOf(size_t s) @safe pure nothrow @nogc => s / oneReader;

/// The mode a waiter asks for: its park token in the main queue (SYP9).
private enum Kind : size_t
{
    shared_ = 1,
    upgradable = 2,
    exclusive = 3,
}

/// The reader–writer lock for platform `P`.
struct RwLockT(P)
{
    package(sparkles.base.sync) P.Atomic!size_t state;

    @disable this(this);

    // Exclusive mode.

    /// Locks exclusively, parking while any other mode is held (SYR2).
    void lock() shared @safe nothrow @nogc
    {
        if (!tryLock())
            cast(void) acquireSlow(Kind.exclusive, Deadline.never);
    }

    /// Locks exclusively by `deadline`; `false` holding nothing.
    bool lockUntil(MonoTime deadline) shared @safe nothrow @nogc
        => tryLock() || acquireSlow(Kind.exclusive, Deadline.at(deadline));

    /// Locks exclusively if the lock is free, without parking.
    bool tryLock() shared @safe nothrow @nogc
    {
        size_t e = 0;
        if (!P.cas!(Order.acquire, Order.relaxed)(state, e, writer))
            return false;
        pin!P();
        return true;
    }

    /// Releases exclusive mode.
    void unlock() shared @safe nothrow @nogc
    {
        assert(P.load!(Order.relaxed)(state) & writer, "RwLock: unlock without exclusive mode");
        transition(writer, 0);
        // Pinned until the mode is gone: the release may wait for a bucket (SYK9).
        unpin!P();
    }

    // Shared mode.

    /// Locks in shared mode, parking while a writer holds it or any waiter is parked (SYR3).
    void lockShared() shared @safe nothrow @nogc
    {
        if (!tryLockShared())
            cast(void) acquireSlow(Kind.shared_, Deadline.never);
    }

    /// Locks in shared mode by `deadline`; `false` holding nothing.
    bool lockSharedUntil(MonoTime deadline) shared @safe nothrow @nogc
        => tryLockShared() || acquireSlow(Kind.shared_, Deadline.at(deadline));

    /// Locks in shared mode if no writer holds it and nobody is parked, without parking.
    bool tryLockShared() shared @safe nothrow @nogc
    {
        size_t cur = P.load!(Order.relaxed)(state);
        while (!(cur & (writer | parked)))
        {
            assert(readersOf(cur) < readersOf(size_t.max), "RwLock: too many readers");
            if (P.cas!(Order.acquire, Order.relaxed)(state, cur, cur + oneReader))
            {
                pin!P();
                return true;
            }
        }
        return false;
    }

    /// Releases shared mode; the last reader wakes a pending upgrade or the queue (SYR7).
    void unlockShared() shared @safe nothrow @nogc
    {
        scope (exit)
            unpin!P();
        size_t cur = P.load!(Order.relaxed)(state);
        while (true)
        {
            assert(readersOf(cur) > 0, "RwLock: unlockShared without shared mode");
            const last = readersOf(cur) == 1;
            if (last && (cur & parked) && !(cur & writer))
            {
                // Decided on a relaxed read: the pass reports the value it
                // replaced, which may show an upgrade begun since.
                cur = transitionSlow(oneReader, 0);
                break;
            }
            if (releaseCas(cur, cur - oneReader))
                break;
        }
        // A writer or an upgrader set the writer bit and waits for the
        // readers present then to leave (SYR4); the last one wakes it.
        if (readersOf(cur) == 1 && (cur & writer))
            unparkOne!P(drainKey(), Protocol.rwUpgrade,
                (ref const LockedKey!P lk, UnparkResult res) => UnparkDecision(tokenHandoff));
    }

    // Upgradable mode.

    /// Locks in upgradable mode, which coexists with shared holders (SYR2).
    void lockUpgradable() shared @safe nothrow @nogc
    {
        if (!tryLockUpgradable())
            cast(void) acquireSlow(Kind.upgradable, Deadline.never);
    }

    /// Locks in upgradable mode by `deadline`; `false` holding nothing.
    bool lockUpgradableUntil(MonoTime deadline) shared @safe nothrow @nogc
        => tryLockUpgradable() || acquireSlow(Kind.upgradable, Deadline.at(deadline));

    /// Locks in upgradable mode if no writer or upgradable holder exists and nobody is parked.
    bool tryLockUpgradable() shared @safe nothrow @nogc
    {
        size_t cur = P.load!(Order.relaxed)(state);
        while (!(cur & (writer | upgradable | parked)))
            if (P.cas!(Order.acquire, Order.relaxed)(state, cur, cur | upgradable))
            {
                pin!P();
                return true;
            }
        return false;
    }

    /// Releases upgradable mode; the next upgradable waiter may then acquire (SYR7).
    void unlockUpgradable() shared @safe nothrow @nogc
    {
        assert(P.load!(Order.relaxed)(state) & upgradable, "RwLock: unlockUpgradable without upgradable mode");
        transition(upgradable, 0);
        unpin!P();
    }

    /**
    Upgrades upgradable mode to exclusive, waiting only for the shared
    holders present now, ahead of every queued writer (SYR4).
    */
    void upgrade() shared @safe nothrow @nogc
    {
        cast(void) upgradeTicks(Deadline.never);
    }

    /// As `upgrade`, by `deadline`; `false` still holding upgradable mode (SYR4).
    bool upgradeUntil(MonoTime deadline) shared @safe nothrow @nogc => upgradeTicks(Deadline.at(deadline));

    /**
    Upgrades if no shared holder remains, without waiting for one. With
    waiters parked it takes the bucket lock (SPEC SYP13), which may wait
    briefly, so that it cannot land inside a release pass (DS30).
    */
    bool tryUpgrade() shared @safe nothrow @nogc
    {
        size_t cur = P.load!(Order.relaxed)(state);
        while (readersOf(cur) == 0)
        {
            assert(cur & upgradable, "RwLock: upgrade without upgradable mode");
            if (cur & parked)
                return readersOf(upgradeLocked(true)) == 0;
            if (P.cas!(Order.acquire, Order.relaxed)(state, cur, cur - upgradable + writer))
                return true;
        }
        return false;
    }

    // Downgrades.

    /// Exclusive to shared mode; parked readers may then join (SYR2).
    void downgrade() shared @safe nothrow @nogc
    {
        assert(P.load!(Order.relaxed)(state) & writer, "RwLock: downgrade without exclusive mode");
        transition(writer, oneReader);
    }

    /// Exclusive to upgradable mode.
    void downgradeToUpgradable() shared @safe nothrow @nogc
    {
        assert(P.load!(Order.relaxed)(state) & writer, "RwLock: downgrade without exclusive mode");
        transition(writer, upgradable);
    }

    /// Upgradable to shared mode.
    void downgradeUpgradable() shared @safe nothrow @nogc
    {
        assert(P.load!(Order.relaxed)(state) & upgradable, "RwLock: downgrade without upgradable mode");
        transition(upgradable, oneReader);
    }

    /// Locks in `mode` and returns a guard that releases it when destroyed.
    RwGuard!P read() shared return @trusted nothrow @nogc
    {
        lockShared();
        return RwGuard!P(&this, RwMode.shared_);
    }

    /// ditto
    RwGuard!P write() shared return @trusted nothrow @nogc
    {
        lock();
        return RwGuard!P(&this, RwMode.exclusive);
    }

    /// ditto
    RwGuard!P upgradableRead() shared return @trusted nothrow @nogc
    {
        lockUpgradable();
        return RwGuard!P(&this, RwMode.upgradable);
    }

    // The same operations on an unshared lock, such as a `__gshared` one.
    void lock() @safe nothrow @nogc => sh.lock();
    bool lockUntil(MonoTime deadline) @safe nothrow @nogc => sh.lockUntil(deadline);
    bool tryLock() @safe nothrow @nogc => sh.tryLock();
    void unlock() @safe nothrow @nogc => sh.unlock();
    void lockShared() @safe nothrow @nogc => sh.lockShared();
    bool lockSharedUntil(MonoTime deadline) @safe nothrow @nogc => sh.lockSharedUntil(deadline);
    bool tryLockShared() @safe nothrow @nogc => sh.tryLockShared();
    void unlockShared() @safe nothrow @nogc => sh.unlockShared();
    void lockUpgradable() @safe nothrow @nogc => sh.lockUpgradable();
    bool lockUpgradableUntil(MonoTime deadline) @safe nothrow @nogc => sh.lockUpgradableUntil(deadline);
    bool tryLockUpgradable() @safe nothrow @nogc => sh.tryLockUpgradable();
    void unlockUpgradable() @safe nothrow @nogc => sh.unlockUpgradable();
    void upgrade() @safe nothrow @nogc => sh.upgrade();
    bool upgradeUntil(MonoTime deadline) @safe nothrow @nogc => sh.upgradeUntil(deadline);
    bool tryUpgrade() @safe nothrow @nogc => sh.tryUpgrade();
    void downgrade() @safe nothrow @nogc => sh.downgrade();
    void downgradeToUpgradable() @safe nothrow @nogc => sh.downgradeToUpgradable();
    void downgradeUpgradable() @safe nothrow @nogc => sh.downgradeUpgradable();
    RwGuard!P read() return @safe nothrow @nogc => sh.read();
    RwGuard!P write() return @safe nothrow @nogc => sh.write();
    RwGuard!P upgradableRead() return @safe nothrow @nogc => sh.upgradableRead();

    // With deadlines in platform ticks (the model's virtual clock).

    package(sparkles.base.sync) bool lockTicks(Deadline d) shared @safe nothrow @nogc
        => tryLock() || acquireSlow(Kind.exclusive, d);

    package(sparkles.base.sync) bool lockSharedTicks(Deadline d) shared @safe nothrow @nogc
        => tryLockShared() || acquireSlow(Kind.shared_, d);

    package(sparkles.base.sync) bool lockUpgradableTicks(Deadline d) shared @safe nothrow @nogc
        => tryLockUpgradable() || acquireSlow(Kind.upgradable, d);

    package(sparkles.base.sync) bool upgradeTicks(Deadline d) shared @safe nothrow @nogc
    {
        size_t cur = P.load!(Order.relaxed)(state);
        while (true)
        {
            assert(cur & upgradable, "RwLock: upgrade without upgradable mode");
            if (cur & parked)
            {
                cur = upgradeLocked(false);
                break;
            }
            if (P.cas!(Order.acquire, Order.relaxed)(state, cur, cur - upgradable + writer))
                break;
        }
        if (readersOf(cur) == 0 || drain(d))
            return true;
        // Timed out: back to upgradable mode, which readers parked behind
        // the writer bit may now join (SYR4, SYR7).
        transition(writer, upgradable);
        return false;
    }

    package(sparkles.base.sync) bool lockTicks(Deadline d) @safe nothrow @nogc => sh.lockTicks(d);
    package(sparkles.base.sync) bool lockSharedTicks(Deadline d) @safe nothrow @nogc => sh.lockSharedTicks(d);
    package(sparkles.base.sync) bool lockUpgradableTicks(Deadline d) @safe nothrow @nogc
        => sh.lockUpgradableTicks(d);
    package(sparkles.base.sync) bool upgradeTicks(Deadline d) @safe nothrow @nogc => sh.upgradeTicks(d);

    // The contended paths.

    /// Whether `kind` can be acquired from state `s` with nobody queued ahead.
    private static bool admits(Kind kind, size_t s) @safe pure nothrow @nogc
    {
        final switch (kind)
        {
        case Kind.shared_:
            return !(s & writer);
        case Kind.upgradable:
        case Kind.exclusive:
            return !(s & (writer | upgradable));
        }
    }

    /// The bit or count `kind` adds when it acquires.
    private static size_t bitOf(Kind kind) @safe pure nothrow @nogc
        => kind == Kind.shared_ ? oneReader : kind == Kind.upgradable ? upgradable : writer;

    private bool acquireSlow(Kind kind, Deadline d) shared @safe nothrow @nogc
    {
        const key = keyOf();
        while (true)
        {
            bool acquired, mustDrain;
            const r = park!P(key, ParkOptions(Protocol.rwLock, parkToken: kind, deadline: d),
                (ref const LockedKey!P lk) {
                    size_t cur = P.load!(Order.relaxed)(state);
                    while (true)
                    {
                        if ((cur & parked) && !lk.hasQueued())
                        {
                            // A parked bit with nobody behind it (SYP15).
                            if (P.cas!(Order.relaxed, Order.relaxed)(state, cur, cur & ~parked))
                                cur &= ~parked;
                            continue;
                        }
                        if (!(cur & parked) && admits(kind, cur))
                        {
                            if (P.cas!(Order.acquire, Order.relaxed)(state, cur, cur + bitOf(kind)))
                            {
                                acquired = true;
                                mustDrain = kind == Kind.exclusive && readersOf(cur) > 0;
                                return false;
                            }
                            continue;
                        }
                        if ((cur & parked) || P.cas!(Order.relaxed, Order.relaxed)(state, cur, cur | parked))
                            return true;
                    }
                },
                null,
                (ref const LockedKey!P lk, bool haveMore) {
                    if (!haveMore)
                        clear(parked);
                    return false;
                });
            final switch (r.outcome)
            {
            case ParkOutcome.invalid:
                if (!acquired)
                    continue;
                if (mustDrain && !drain(d))
                {
                    // The readers outlasted the deadline: give the writer
                    // bit back, and let readers parked behind it in (SYR7).
                    transition(writer, 0);
                    return false;
                }
                pin!P();
                return true;
            case ParkOutcome.unparked:
                // A release's pass granted the mode (SYR5). The park's return
                // orders only the pass's releaser before this; a reader that
                // left earlier, with a plain release, is ordered by this
                // acquire, which continues every release's sequence: the
                // word changes only by read–modify–writes (§13).
                assert(r.token == tokenHandoff, "an RwLock waiter woken with a foreign token");
                cast(void) P.load!(Order.acquire)(state);
                pin!P();
                return true;
            case ParkOutcome.timedOut:
            case ParkOutcome.cancelled:
                // Leaving may let the waiters behind acquire (SYR7).
                if (P.load!(Order.relaxed)(state) & parked)
                    cast(void) transitionSlow(0, 0);
                return false;
            }
        }
    }

    /**
    With the writer bit set, waits for the readers to leave, on the drain
    key (SYR4). Returns `false` if `d` passes first; the writer bit is then
    still set.
    */
    private bool drain(Deadline d) shared @safe nothrow @nogc
    {
        while (true)
        {
            const r = park!P(drainKey(), ParkOptions(Protocol.rwUpgrade, deadline: d),
                (ref const LockedKey!P lk) => readersOf(P.load!(Order.relaxed)(state)) > 0);
            final switch (r.outcome)
            {
            case ParkOutcome.invalid:
            case ParkOutcome.unparked:
                // Every reader's release is in the release sequence this
                // read continues (§13: shared release before exclusive).
                if (readersOf(P.load!(Order.acquire)(state)) == 0)
                    return true;
                continue;
            case ParkOutcome.timedOut:
            case ParkOutcome.cancelled:
                return false;
            }
        }
    }

    /**
    An upgrade with waiters parked: swaps the upgradable bit for the writer
    bit under the bucket lock, so it cannot land between a release pass's
    choice of grants and its read–modify–write (SYR2, SYR4). With
    `ifDrained`, only while no reader remains. Returns the value replaced,
    or the value seen when `ifDrained` declined.
    */
    private size_t upgradeLocked(bool ifDrained) shared @safe nothrow @nogc
    {
        size_t seen;
        unparkFilter!P(keyOf(), Protocol.rwLock, (size_t token) => FilterOp.stop,
            (ref const LockedKey!P lk, UnparkResult res) {
                seen = P.load!(Order.relaxed)(state);
                while (!(ifDrained && readersOf(seen) > 0)
                    && !P.cas!(Order.acquire, Order.relaxed)(state, seen, seen - upgradable + writer)) {}
                return UnparkDecision(0);
            });
        return seen;
    }

    /// Replaces the caller's mode bits `remove` with `add`; wakes the queue if anyone is parked.
    private void transition(size_t remove, size_t add) shared @safe nothrow @nogc
    {
        size_t cur = P.load!(Order.relaxed)(state);
        while (!(cur & parked))
            if (releaseCas(cur, cur - remove + add))
                return;
        cast(void) transitionSlow(remove, add);
    }

    /**
    The release pass (SYR5, SYR7): under the bucket lock, grants modes to the
    head of the queue and, in one read–modify–write, replaces the caller's
    `remove` with `add` and the grants. The caller keeps its mode until then,
    so nothing can acquire behind the pass's back. Returns the value the
    first pass's read–modify–write replaced.

    A reader can still leave during a pass, by a plain release while the
    writer bit is set: if it was the last, and the pass declined a waiter
    that the readers kept out, the pass runs again, since nobody else will
    (SYR7: a writer timing out of its drain as the last reader leaves).
    */
    private size_t transitionSlow(size_t remove, size_t add) shared @safe nothrow @nogc
    {
        bool again;
        const replaced = pass(remove, add, again);
        while (again)
            cast(void) pass(0, 0, again);
        return replaced;
    }

    private size_t pass(size_t remove, size_t add, out bool again) shared @safe nothrow @nogc
    {
        size_t base, granted, replaced;
        bool started, exclusiveGranted;
        unparkFilter!P(keyOf(), Protocol.rwLock,
            (size_t token) {
                if (!started)
                {
                    base = granted = (P.load!(Order.relaxed)(state) - remove + add) & ~parked;
                    started = true;
                }
                if (exclusiveGranted)
                    return FilterOp.stop;
                final switch (cast(Kind) token)
                {
                case Kind.exclusive:
                    if ((granted & (writer | upgradable)) || readersOf(granted) > 0)
                        return FilterOp.stop;
                    granted |= writer;
                    exclusiveGranted = true;
                    return FilterOp.wake;
                case Kind.shared_:
                    if (granted & writer)
                        return FilterOp.stop;
                    granted += oneReader;
                    return FilterOp.wake;
                case Kind.upgradable:
                    if (granted & writer)
                        return FilterOp.stop;
                    if (granted & upgradable)
                        return FilterOp.skip;
                    granted |= upgradable;
                    return FilterOp.wake;
                }
            },
            (ref const LockedKey!P lk, UnparkResult res) {
                const grants = granted - base;
                size_t cur = P.load!(Order.relaxed)(state);
                while (true)
                {
                    size_t next = cur - remove + add + grants;
                    next = res.haveMore ? next | parked : next & ~parked;
                    if (releaseCas(cur, next))
                        break;
                }
                replaced = cur;
                again = started && res.haveMore && readersOf(cur - remove + add) < readersOf(base);
                return UnparkDecision(tokenHandoff);
            });
        return replaced;
    }

    /// A release compare-and-swap; the model's seeded fault weakens it (oracle 1).
    private bool releaseCas(ref size_t expected, size_t desired) shared @safe nothrow @nogc
    {
        static if (P.isModel)
            if (P.faultActive(P.Fault.releaseRelaxed))
                return P.cas!(Order.relaxed, Order.relaxed)(state, expected, desired);
        return P.cas!(Order.release, Order.relaxed)(state, expected, desired);
    }

    private void clear(size_t bits) shared @safe nothrow @nogc
    {
        size_t cur = P.load!(Order.relaxed)(state);
        while (!P.cas!(Order.relaxed, Order.relaxed)(state, cur, cur & ~bits)) {}
    }

    private size_t keyOf() shared @trusted nothrow @nogc => cast(size_t) &state;

    /// The key an upgrade or a writer waits on for the readers to leave (SYR4).
    private size_t drainKey() shared @trusted nothrow @nogc => cast(size_t) &state + 1;

    private ref shared(RwLockT) sh() return @trusted nothrow @nogc => *cast(shared(RwLockT)*) &this;
}

/// The reader–writer lock (primitives.md §7).
alias RwLock = RwLockT!NativePlatform;

/// The mode an `RwGuard` holds.
enum RwMode : ubyte
{
    shared_,
    upgradable,
    exclusive,
}

/// Holds an `RwLock` in one mode; releases it on destruction.
struct RwGuard(P)
{
    private shared(RwLockT!P)* lock;
    private RwMode mode_;

    @disable this(this);

    /// Only the lock's guard methods make one, holding the mode.
    package(sparkles.base.sync) this(shared(RwLockT!P)* l, RwMode m) @safe nothrow @nogc
    {
        lock = l;
        mode_ = m;
    }

    ~this() @safe nothrow @nogc
    {
        if (lock is null)
            return;
        final switch (mode_)
        {
        case RwMode.shared_:
            lock.unlockShared();
            break;
        case RwMode.upgradable:
            lock.unlockUpgradable();
            break;
        case RwMode.exclusive:
            lock.unlock();
            break;
        }
    }

    /// The mode held.
    RwMode mode() const @safe nothrow @nogc => mode_;

    /// Upgrades an upgradable guard to exclusive (SYR4).
    void upgrade() @safe nothrow @nogc
    {
        assert(mode_ == RwMode.upgradable, "RwGuard: upgrade of a guard that is not upgradable");
        lock.upgrade();
        mode_ = RwMode.exclusive;
    }

    /// Downgrades to shared mode.
    void downgrade() @safe nothrow @nogc
    {
        final switch (mode_)
        {
        case RwMode.shared_:
            return;
        case RwMode.upgradable:
            lock.downgradeUpgradable();
            break;
        case RwMode.exclusive:
            lock.downgrade();
            break;
        }
        mode_ = RwMode.shared_;
    }
}

static assert(RwLock.sizeof == size_t.sizeof, "SYR1");
static assert(!__traits(compiles, { RwLock a; RwLock b = a; }), "SYA4");
