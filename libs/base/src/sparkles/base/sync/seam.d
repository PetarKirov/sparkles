/**
The wait seam: the one call per platform that puts a thread to sleep on a
32-bit word, and the call that wakes it (SPEC §2).

Only the thread parker and the bucket lock use the seam; no primitive calls
it directly. `wait` may return spuriously, and `wake` identifies waiters by
the word's address alone, so a wake that reaches an address after its storage
is gone costs at most a spurious return (SYF1, SYK8).

The mechanism per platform is SYF2's table. A build selects the portable
fallback with `version (SparklesSyncPortableParker)`, and so does every
platform without a native mechanism; then `hasNativeSeam` is false and the
thread parker sleeps on its own mutex and condition variable instead.
*/
module sparkles.base.sync.seam;

import core.time : MonoTime;

@safe nothrow @nogc:

version (SparklesSyncPortableParker)
    enum bool hasNativeSeam = false;
else version (linux)
{
    version (X86_64)
        private enum long sysFutex = 202;
    else version (AArch64)
        private enum long sysFutex = 98;
    else version (X86)
        private enum long sysFutex = 240;
    else version (ARM)
        private enum long sysFutex = 240;
    else version (RISCV64)
        private enum long sysFutex = 98;
    else
        private enum long sysFutex = 0;

    /// Whether this build has a native wait-on-address mechanism (SYF2).
    enum bool hasNativeSeam = sysFutex != 0;
}
else version (Windows)
    enum bool hasNativeSeam = true;
else version (OSX)
    enum bool hasNativeSeam = true;
else version (FreeBSD)
    enum bool hasNativeSeam = true;
else
    enum bool hasNativeSeam = false;

/**
An absolute point on the monotonic clock, in `MonoTime` ticks (SYF4). The
model platform uses the same representation for its virtual clock.
*/
struct Deadline
{
    /// `long.max` is "no deadline".
    long ticks = long.max;

    /// The deadline that never passes.
    enum Deadline never = Deadline.init;

    /// Converts a `MonoTime`.
    static Deadline at(MonoTime t) @safe pure nothrow @nogc => Deadline(t.ticks);

    /// Whether this is the deadline that never passes.
    bool isNever() const @safe pure nothrow @nogc => ticks == long.max;

    /// Whether the deadline has passed at `now` (in the same ticks).
    bool passed(long now) const @safe pure nothrow @nogc => !isNever && now >= ticks;
}

/// How many waiters a `wake` wakes.
enum WakeCount : ubyte
{
    one,
    all,
}

/// Why `wait` returned. `woken` includes value mismatches and spurious returns.
enum SeamResult : ubyte
{
    woken,
    timedOut,
}

/**
Test switches for oracle 5: make `wait` return spuriously or report `EINTR`
at chosen calls, and make macOS select `__ulock` over `os_sync_*`. They are
per thread, so one test cannot disturb another, and cost one thread-local
load on a path that is about to enter the kernel.
*/
struct SeamFaults
{
    /// The next this-many `wait` calls return at once, as a spurious wake.
    uint spuriousReturns;
    /// The next this-many `wait` calls fail as if interrupted (`EINTR`).
    uint interruptedReturns;
    /// `wait` calls made on this thread, for tests that count them.
    ulong waits;
    /// `wake` calls made on this thread.
    ulong wakes;
}

/// This thread's fault plan and counters.
package(sparkles.base.sync) SeamFaults seamFaults;

static if (hasNativeSeam)
{
    /**
    Sleeps while `word` holds `expected`, until woken or `deadline` passes
    (SYF1). A deadline already in the past returns `timedOut` without
    sleeping (SYF4). May return `woken` spuriously.
    */
    SeamResult wait(ref shared uint word, uint expected, Deadline deadline) @trusted
    {
        ++seamFaults.waits;
        if (seamFaults.spuriousReturns)
        {
            --seamFaults.spuriousReturns;
            return SeamResult.woken;
        }
        if (seamFaults.interruptedReturns)
        {
            --seamFaults.interruptedReturns;
            return SeamResult.woken; // EINTR: the caller re-checks, as for a spurious return
        }
        if (deadline.passed(MonoTime.currTime.ticks))
            return SeamResult.timedOut;
        return platformWait(&word, expected, deadline);
    }

    /// Wakes one or all waiters on `word`, without reading or writing it (SYF1).
    void wake(ref shared uint word, WakeCount count) @trusted => wakeAddress(&word, count);

    /**
    Wakes waiters on an address whose storage may already be gone: the
    mechanism keys on the address alone and never dereferences it (SYK8).
    */
    void wakeAddress(const(shared(uint))* word, WakeCount count) @system
    {
        ++seamFaults.wakes;
        platformWake(word, count);
    }
}

// ---------------------------------------------------------------------------
// Linux: futex(FUTEX_WAIT_BITSET | FUTEX_PRIVATE_FLAG), absolute CLOCK_MONOTONIC.

version (SparklesSyncPortableParker) {}
else version (linux)
{
    static if (sysFutex != 0)
    {
        import core.sys.linux.unistd : syscall;
        import core.sys.posix.time : timespec;

        private enum int futexWaitBitset = 9, futexWake = 1, futexPrivate = 128;
        private enum uint futexBitsetMatchAny = uint.max;

        private SeamResult platformWait(shared(uint)* word, uint expected, Deadline deadline) @system
        {
            import core.stdc.errno : errno, ETIMEDOUT;

            timespec ts;
            timespec* pts;
            if (!deadline.isNever)
            {
                ts = toTimespec(deadline.ticks);
                pts = &ts;
            }
            const r = syscall(sysFutex, cast(void*) word, futexWaitBitset | futexPrivate,
                expected, pts, null, futexBitsetMatchAny);
            return r == -1 && errno == ETIMEDOUT ? SeamResult.timedOut : SeamResult.woken;
        }

        private void platformWake(const(shared(uint))* word, WakeCount count) @system
        {
            cast(void) syscall(sysFutex, cast(void*) word, futexWake | futexPrivate,
                count == WakeCount.one ? 1 : int.max, null, null, 0);
        }
    }
}

// ---------------------------------------------------------------------------
// FreeBSD: _umtx_op(UMTX_OP_WAIT_UINT_PRIVATE), absolute CLOCK_MONOTONIC.

version (SparklesSyncPortableParker) {}
else version (FreeBSD)
{
    import core.sys.posix.time : timespec, CLOCK_MONOTONIC;

    private extern (C) int _umtx_op(void* obj, int op, size_t val, void* uaddr, void* uaddr2) @system;

    private enum int umtxOpWaitUintPrivate = 15, umtxOpWakePrivate = 16;
    private enum uint umtxAbsTime = 1;

    private struct UmtxTime
    {
        timespec timeout;
        uint flags;
        uint clockId;
    }

    private SeamResult platformWait(shared(uint)* word, uint expected, Deadline deadline) @system
    {
        import core.stdc.errno : errno, ETIMEDOUT;

        int r;
        if (deadline.isNever)
            r = _umtx_op(cast(void*) word, umtxOpWaitUintPrivate, expected, null, null);
        else
        {
            auto t = UmtxTime(toTimespec(deadline.ticks), umtxAbsTime, CLOCK_MONOTONIC);
            r = _umtx_op(cast(void*) word, umtxOpWaitUintPrivate, expected,
                cast(void*) UmtxTime.sizeof, &t);
        }
        return r == -1 && errno == ETIMEDOUT ? SeamResult.timedOut : SeamResult.woken;
    }

    private void platformWake(const(shared(uint))* word, WakeCount count) @system
    {
        cast(void) _umtx_op(cast(void*) word, umtxOpWakePrivate,
            count == WakeCount.one ? 1 : int.max, null, null);
    }
}

version (SparklesSyncPortableParker) {}
else version (Posix)
{
    static if (hasNativeSeam)
    {
        version (OSX) {}
        else
        {
            import core.sys.posix.time : timespec;

            /// `MonoTime` ticks to an absolute `CLOCK_MONOTONIC` timespec.
            private timespec toTimespec(long ticks) pure @trusted
            {
                import core.time : convClockFreq;

                const ns = convClockFreq(ticks, MonoTime.ticksPerSecond, 1_000_000_000L);
                timespec ts;
                ts.tv_sec = cast(typeof(ts.tv_sec))(ns / 1_000_000_000L);
                ts.tv_nsec = cast(typeof(ts.tv_nsec))(ns % 1_000_000_000L);
                return ts;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Windows: WaitOnAddress with the remaining time recomputed per call.

version (SparklesSyncPortableParker) {}
else version (Windows)
{
    import core.sys.windows.windef : BOOL, DWORD;

    pragma(lib, "synchronization");

    private extern (Windows) @system
    {
        BOOL WaitOnAddress(void* address, void* compareAddress, size_t size, DWORD milliseconds);
        void WakeByAddressSingle(void* address);
        void WakeByAddressAll(void* address);
    }

    private enum DWORD infinite = 0xFFFF_FFFF;

    private SeamResult platformWait(shared(uint)* word, uint expected, Deadline deadline) @system
    {
        DWORD ms = infinite;
        if (!deadline.isNever)
        {
            const remaining = remainingNanoseconds(deadline);
            if (remaining <= 0)
                return SeamResult.timedOut;
            // Round up, so the call never returns before the deadline.
            const ceil = (remaining + 999_999) / 1_000_000;
            ms = ceil >= infinite ? infinite - 1 : cast(DWORD) ceil;
        }
        if (WaitOnAddress(cast(void*) word, &expected, uint.sizeof, ms))
            return SeamResult.woken;
        return deadline.passed(MonoTime.currTime.ticks) ? SeamResult.timedOut : SeamResult.woken;
    }

    private void platformWake(const(shared(uint))* word, WakeCount count) @system
    {
        if (count == WakeCount.one)
            WakeByAddressSingle(cast(void*) word);
        else
            WakeByAddressAll(cast(void*) word);
    }
}

// ---------------------------------------------------------------------------
// macOS: os_sync_* where present at run time, else __ulock (SYF2, SYF3).

version (SparklesSyncPortableParker) {}
else version (OSX)
{
    private extern (C) @system
    {
        int __ulock_wait2(uint operation, void* addr, ulong value, ulong timeoutNs, ulong value2);
        int __ulock_wake(uint operation, void* addr, ulong wakeValue);
    }

    private enum uint ulCompareAndWait = 1, ulfWakeAll = 0x100, ulfNoErrno = 0x0100_0000;
    private enum int eTimedOut = 60; // ETIMEDOUT on Darwin

    private alias OsSyncWait = extern (C) int function(void*, ulong, size_t, uint) @system nothrow @nogc;
    private alias OsSyncWaitTimeout = extern (C) int function(void*, ulong, size_t, uint, uint, ulong) @system nothrow @nogc;
    private alias OsSyncWake = extern (C) int function(void*, size_t, uint) @system nothrow @nogc;

    private enum uint osClockMachAbsoluteTime = 32;

    /// The mechanism chosen for this process.
    enum DarwinSeam : ubyte
    {
        unresolved,
        osSync,
        ulock,
    }

    private struct OsSync
    {
        OsSyncWait wait;
        OsSyncWaitTimeout waitTimeout;
        OsSyncWake wakeAny, wakeAll;
    }

    private __gshared OsSync osSync;
    private shared DarwinSeam darwinSeam;

    /// The macOS mechanism, looking the public symbols up once per process (SYF3).
    DarwinSeam darwinMechanism() @trusted
    {
        import core.atomic : atomicLoad, atomicStore, MemoryOrder;

        auto m = atomicLoad!(MemoryOrder.acq)(darwinSeam);
        if (m != DarwinSeam.unresolved)
            return m;
        return resolveDarwin(false);
    }

    /**
    Looks the `os_sync_*` symbols up and caches the choice. Oracle 5 passes
    `forceUlock` to run the fallback on a system that has the public API; no
    production path calls it after the first resolution.
    */
    package(sparkles.base.sync) DarwinSeam resolveDarwin(bool forceUlock) @system
    {
        import core.atomic : atomicStore, MemoryOrder;
        import core.sys.posix.dlfcn : dlsym;
        import core.sys.darwin.dlfcn : RTLD_DEFAULT;

        OsSync found;
        found.wait = cast(OsSyncWait) dlsym(RTLD_DEFAULT, "os_sync_wait_on_address");
        found.waitTimeout = cast(OsSyncWaitTimeout) dlsym(RTLD_DEFAULT, "os_sync_wait_on_address_with_timeout");
        found.wakeAny = cast(OsSyncWake) dlsym(RTLD_DEFAULT, "os_sync_wake_by_address_any");
        found.wakeAll = cast(OsSyncWake) dlsym(RTLD_DEFAULT, "os_sync_wake_by_address_all");
        const usable = !forceUlock && found.wait !is null && found.waitTimeout !is null
            && found.wakeAny !is null && found.wakeAll !is null;
        if (usable)
            osSync = found;
        const m = usable ? DarwinSeam.osSync : DarwinSeam.ulock;
        atomicStore!(MemoryOrder.rel)(darwinSeam, m);
        return m;
    }

    private SeamResult platformWait(shared(uint)* word, uint expected, Deadline deadline) @system
    {
        import core.stdc.errno : errno, ETIMEDOUT;

        const useOsSync = darwinMechanism() == DarwinSeam.osSync;
        ulong timeoutNs;
        if (!deadline.isNever)
        {
            // SYF4: recompute the remaining time for this call, return without
            // the call when none remains, and pass at least 1 ns: __ulock reads
            // 0 as "no timeout" and os_sync rejects it.
            const remaining = remainingNanoseconds(deadline);
            if (remaining <= 0)
                return SeamResult.timedOut;
            timeoutNs = remaining;
        }
        if (useOsSync)
        {
            int r = deadline.isNever
                ? osSync.wait(cast(void*) word, expected, uint.sizeof, 0)
                : osSync.waitTimeout(cast(void*) word, expected, uint.sizeof, 0,
                    osClockMachAbsoluteTime, timeoutNs);
            return r < 0 && errno == ETIMEDOUT ? SeamResult.timedOut : SeamResult.woken;
        }
        const r = __ulock_wait2(ulCompareAndWait | ulfNoErrno, cast(void*) word, expected,
            timeoutNs, 0);
        return r == -eTimedOut ? SeamResult.timedOut : SeamResult.woken;
    }

    private void platformWake(const(shared(uint))* word, WakeCount count) @system
    {
        if (darwinMechanism() == DarwinSeam.osSync)
        {
            if (count == WakeCount.one)
                cast(void) osSync.wakeAny(cast(void*) word, uint.sizeof, 0);
            else
                cast(void) osSync.wakeAll(cast(void*) word, uint.sizeof, 0);
            return;
        }
        cast(void) __ulock_wake(ulCompareAndWait | ulfNoErrno | (count == WakeCount.all
                ? ulfWakeAll : 0), cast(void*) word, 0);
    }
}

/// Nanoseconds from now until `deadline`, at least 1 when any remain (SYF4).
package(sparkles.base.sync) long remainingNanoseconds(Deadline deadline) @trusted
{
    import core.time : convClockFreq;

    const now = MonoTime.currTime.ticks;
    if (now >= deadline.ticks)
        return 0;
    const ns = convClockFreq(deadline.ticks - now, MonoTime.ticksPerSecond, 1_000_000_000L);
    return ns < 1 ? 1 : ns;
}
