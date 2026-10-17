/**
Guarded data (primitives.md §5): a value reachable only through a guard that
holds its lock.

The guard's reference is `scope`, so under `-preview=dip1000` no reference
into the payload outlives the guard (SYG2). That restricts the reference to
the payload, not what the payload points to, so a payload with mutable
indirections is rejected unless its type declares itself `@contained`: every
indirection it holds is reachable only through `return scope` members
(SYG3, DS19).
*/
module sparkles.base.sync.guarded;

import core.time : MonoTime;
import std.traits : hasAliasing, hasUDA;

import sparkles.base.sync.interruptible_mutex;
import sparkles.base.sync.mutex;
import sparkles.base.sync.platform : NativePlatform;
import sparkles.base.sync.seam : Deadline;

/**
Declares a payload type contained (SYG3): every mutable indirection it holds
is reachable only through member functions whose results are `return scope`,
as an owning buffer's are.
*/
struct contained
{
}

/// Whether `T` may be guarded: no mutable indirections, or declared `@contained`.
enum bool isContainedPayload(T) = !hasAliasing!T || isDeclaredContained!T;

private template isDeclaredContained(T)
{
    static if (is(T == struct) || is(T == union))
        enum isDeclaredContained = hasUDA!(T, contained);
    else
        enum isDeclaredContained = false;
}

private enum string payloadError = "Guarded!T needs a contained payload (SYG3): a slice, a pointer "
    ~ "or a class reference to mutable data would outlive the guard; declare the type @contained if "
    ~ "every indirection it holds is reachable only through `return scope` members";

/// A `T` and a `Mutex` (SYG1), for platform `P`.
struct GuardedT(P, T)
{
    static assert(isContainedPayload!T, payloadError);

    private MutexT!P mutex;
    private T payload;

    @disable this(this);

    /// Constructs the payload.
    this(T value)
    {
        import core.lifetime : move;

        payload = move(value); // a contained payload is often move-only
    }

    /// Locks and returns the guard through which the payload is reached.
    GuardedGuard!(P, T) lock() shared return @trusted => GuardedGuard!(P, T)(mutex.guard(), &payload);

    /// Locks by `deadline`; an empty guard on timeout.
    GuardedGuard!(P, T) lockUntil(MonoTime deadline) shared return @trusted
    {
        if (!mutex.lockUntil(deadline))
            return GuardedGuard!(P, T).init;
        return GuardedGuard!(P, T)(MutexGuard!P(&mutex), &payload);
    }

    /// Locks if free; an empty guard otherwise.
    GuardedGuard!(P, T) tryLock() shared return @trusted
    {
        if (!mutex.tryLock())
            return GuardedGuard!(P, T).init;
        return GuardedGuard!(P, T)(MutexGuard!P(&mutex), &payload);
    }

    GuardedGuard!(P, T) lock() return @trusted => (cast(shared) this).lock();
    GuardedGuard!(P, T) lockUntil(MonoTime deadline) return @trusted => (cast(shared) this).lockUntil(deadline);
    GuardedGuard!(P, T) tryLock() return @trusted => (cast(shared) this).tryLock();
}

/// Guarded data over a `Mutex` (primitives.md §5).
alias Guarded(T) = GuardedT!(NativePlatform, T);

/// Holds a `Guarded`'s mutex and gives access to its payload; unlocks on destruction (SYG2).
struct GuardedGuard(P, T)
{
    package(sparkles.base.sync) MutexGuard!P mutexGuard;
    private shared(T)* payload;

    @disable this(this);

    package(sparkles.base.sync) this(MutexGuard!P g, shared(T)* p) @safe nothrow @nogc
    {
        import core.lifetime : move;

        mutexGuard = move(g);
        payload = p;
    }

    /// Whether this guard holds the lock.
    bool holds() const @safe nothrow @nogc => payload !is null;

    /// The payload, while the lock is held. The reference cannot outlive the guard.
    ref T get() return scope @trusted
    {
        assert(payload !is null, "an empty guard: the acquisition failed");
        // The lock makes the access exclusive, so the payload is not shared here.
        return *cast(T*) payload;
    }
}

/// A `T` and an `InterruptibleMutex` (SYG1), for platform `P`.
struct InterruptibleGuardedT(P, T)
{
    static assert(isContainedPayload!T, payloadError);

    private InterruptibleMutexT!P mutex;
    private T payload;

    @disable this(this);

    this(T value)
    {
        import core.lifetime : move;

        payload = move(value);
    }

    /// Locks interruptibly; on success the guard reaches the payload.
    InterruptibleGuardedAcquisition!(P, T) lock() shared return @trusted
        => wrap(mutex.lock());

    /// Locks interruptibly by `deadline`.
    InterruptibleGuardedAcquisition!(P, T) lockUntil(MonoTime deadline) shared return @trusted
        => wrap(mutex.lockUntil(deadline));

    /// Locks if free and nobody is queued, without waiting (SYJ6).
    InterruptibleGuardedAcquisition!(P, T) tryLock() shared return @trusted
        => wrap(mutex.tryLock());

    InterruptibleGuardedAcquisition!(P, T) lock() return @trusted => (cast(shared) this).lock();
    InterruptibleGuardedAcquisition!(P, T) lockUntil(MonoTime deadline) return @trusted
        => (cast(shared) this).lockUntil(deadline);
    InterruptibleGuardedAcquisition!(P, T) tryLock() return @trusted => (cast(shared) this).tryLock();

    private InterruptibleGuardedAcquisition!(P, T) wrap(Acquisition!P a) shared @trusted
    {
        import core.lifetime : move;

        InterruptibleGuardedAcquisition!(P, T) r;
        r.status = a.status;
        if (a)
        {
            r.guard.inner = move(a.guard);
            r.guard.payload = &payload;
        }
        return r;
    }
}

/// Guarded data over an `InterruptibleMutex` (primitives.md §5).
alias InterruptibleGuarded(T) = InterruptibleGuardedT!(NativePlatform, T);

/// Holds an `InterruptibleGuarded`'s mutex and gives access to its payload.
struct InterruptibleGuardedGuard(P, T)
{
    package(sparkles.base.sync) InterruptibleGuard!P inner;
    private shared(T)* payload;

    @disable this(this);

    /// Whether this guard holds the lock.
    bool holds() const @safe nothrow @nogc => payload !is null;

    /// The payload, while the lock is held.
    ref T get() return scope @trusted
    {
        assert(payload !is null, "an empty guard: the acquisition failed");
        return *cast(T*) payload;
    }

    /// For `Condition`: the interruptible guard it holds (SYG4).
    package(sparkles.base.sync) ref InterruptibleGuard!P mutexGuard() return @safe nothrow @nogc => inner;
}

/// An interruptible acquisition of guarded data: the guard, and how the wait ended.
struct InterruptibleGuardedAcquisition(P, T)
{
    InterruptibleGuardedGuard!(P, T) guard;
    WaitStatus status;

    bool opCast(B : bool)() const @safe nothrow @nogc => status == WaitStatus.ok;
}
