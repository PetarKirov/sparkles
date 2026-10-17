/**
Tests of `sparkles.base.sync` from outside its package, where its users are:
no guard can be made without acquiring its lock, and an empty acquisition is
never a success (SYG2, SYJ1, SYI5).
*/
module sparkles.base.sync_access_test;

import sparkles.base.sync.guarded : GuardedGuard, InterruptibleGuarded, InterruptibleGuardedAcquisition,
    InterruptibleGuardedGuard;
import sparkles.base.sync.interruptible_mutex : Acquisition, InterruptibleGuard, InterruptibleMutex, WaitStatus;
import sparkles.base.sync.mutex : LockBits, Mutex, MutexGuard;
import sparkles.base.sync.platform : NativePlatform;

private alias P = NativePlatform;

@("sync.access.guardsNeedTheirLocks")
@safe nothrow @nogc
unittest
{
    shared int value;
    shared Mutex m;
    shared InterruptibleMutex im;
    shared uint word;
    alias LB = LockBits!(uint, 1, 2, 4);

    // Each guard type exists only through an acquisition.
    static assert(!__traits(compiles, MutexGuard!P(&m)));
    static assert(!__traits(compiles, InterruptibleGuard!P(&im)));
    static assert(!__traits(compiles, LB.Guard(&word)));
    static assert(!__traits(compiles, GuardedGuard!(P, int)(MutexGuard!P.init, &value)));
    static assert(!__traits(compiles,
        InterruptibleGuardedGuard!(P, int)(InterruptibleGuard!P.init, &value)));

    // The control: acquiring is how a guard is made.
    {
        auto g = m.guard();
        auto lg = LB.guard(word);
    }
    auto a = im.lock();
    assert(a && a.guard.holds);
}

@("sync.access.emptyAcquisitionIsNoSuccess")
@safe nothrow @nogc
unittest
{
    assert(!Acquisition!P.init, "a default result holds nothing");
    assert(!InterruptibleGuardedAcquisition!(P, int).init, "a default result holds nothing");
    assert(!Acquisition!P(InterruptibleGuard!P.init, WaitStatus.ok), "`ok` with an empty guard holds nothing");

    InterruptibleGuarded!int g = InterruptibleGuarded!int(1);
    auto a = g.lock();
    assert(a && a.guard.holds && a.guard.get() == 1);
}
