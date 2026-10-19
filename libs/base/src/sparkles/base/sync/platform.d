/**
The platform policy every primitive and the parking lot are written over
(DS12): atomic operations with their memory orders, the wait seam, the clock,
and each thread's parker state.

`NativePlatform` is `core.atomic` and the operating system; every member is a
thin forwarding template, so the indirection compiles away (oracle 11). The
model platform (`sparkles.base.sync.model`) implements the same members as
scheduling points of a deterministic explorer.
*/
module sparkles.base.sync.platform;

import core.atomic : MemoryOrder;
import core.time : MonoTime;

import sparkles.base.sync.parker : ThreadState;
import sparkles.base.sync.seam : Deadline, SeamResult, WakeCount;
static import sparkles.base.sync.seam;

/// A memory order, in the C++ and D memory models' terms.
enum Order : ubyte
{
    relaxed,
    acquire,
    release,
    acqRel,
    seqCst,
}

/// Whether `P` provides the members `NativePlatform` documents.
enum bool isSyncPlatform(P) = __traits(compiles, {
    P.Atomic!uint word;
    uint expected;
    uint v = P.load!(Order.acquire)(word);
    P.store!(Order.release)(word, v);
    bool ok = P.cas!(Order.acqRel, Order.acquire)(word, expected, v);
    v = P.exchange!(Order.acqRel)(word, v);
    v = P.fetchAdd!(Order.acqRel)(word, v);
    v = P.fetchOr!(Order.acqRel)(word, v);
    v = P.fetchAnd!(Order.acqRel)(word, v);
    long now = P.now();
    SeamResult r = P.seamWait(word, v, Deadline.never);
    P.seamWake(word, WakeCount.one);
    P.pause();
    P.yieldThread();
    ThreadState!P* ts = P.thread();
    bool m = P.isModel;
});

private template mo(Order o)
{
    static if (o == Order.relaxed)
        enum mo = MemoryOrder.raw;
    else static if (o == Order.acquire)
        enum mo = MemoryOrder.acq;
    else static if (o == Order.release)
        enum mo = MemoryOrder.rel;
    else static if (o == Order.acqRel)
        enum mo = MemoryOrder.acq_rel;
    else
        enum mo = MemoryOrder.seq;
}


/// `core.atomic`'s read–modify–writes take relaxed, `acq_rel` or seq: an
/// acquire-only or release-only one is strengthened to `acq_rel`.
private template rmwMo(Order o)
{
    static if (o == Order.relaxed)
        enum rmwMo = MemoryOrder.raw;
    else static if (o == Order.seqCst)
        enum rmwMo = MemoryOrder.seq;
    else
        enum rmwMo = MemoryOrder.acq_rel;
}
/// The failure order of a compare-and-swap whose success order is `o`.
template failureOrder(Order o)
{
    static if (o == Order.release)
        enum failureOrder = Order.relaxed;
    else static if (o == Order.acqRel)
        enum failureOrder = Order.acquire;
    else
        enum failureOrder = o;
}

/// The production policy: `core.atomic` and the operating system.
struct NativePlatform
{
    /// Not the model: no scheduling points, no seeded faults.
    enum bool isModel = false;

    /// An atomic word: the plain `shared` type, so a primitive's size is its state's.
    alias Atomic(T) = shared(T);

static:
    pragma(inline, true)
    {
        T load(Order o = Order.seqCst, T)(ref const shared T a) @safe nothrow @nogc
        {
            import core.atomic : atomicLoad;

            return atomicLoad!(mo!o)(a);
        }

        /// Reads a location the caller's bucket lock protects.
        T peek(T)(ref const shared T a) @safe nothrow @nogc
        {
            import core.atomic : atomicLoad;

            return atomicLoad!(MemoryOrder.raw)(a);
        }

        void store(Order o = Order.seqCst, T)(ref shared T a, T v) @safe nothrow @nogc
        {
            import core.atomic : atomicStore;

            atomicStore!(mo!o)(a, v);
        }

        /// Compare-and-swap; on failure `expected` receives the current value.
        bool cas(Order s = Order.seqCst, Order f = failureOrder!s, T)(ref shared T a,
            ref T expected, T desired) @trusted nothrow @nogc
        {
            import core.atomic : cas;

            return cas!(mo!s, mo!f)(&a, &expected, desired);
        }

        T exchange(Order o = Order.seqCst, T)(ref shared T a, T v) @safe nothrow @nogc
        {
            import core.atomic : atomicExchange;

            return atomicExchange!(rmwMo!o)(&a, v);
        }

        T fetchAdd(Order o = Order.seqCst, T)(ref shared T a, T v) @safe nothrow @nogc
        {
            import core.atomic : atomicFetchAdd;

            return atomicFetchAdd!(rmwMo!o)(a, v);
        }

        T fetchOr(Order o = Order.seqCst, T)(ref shared T a, T v) @safe nothrow @nogc
        {
            T cur = load!(Order.relaxed)(a);
            while (!cas!(o, Order.relaxed)(a, cur, cast(T)(cur | v))) {}
            return cur;
        }

        T fetchAnd(Order o = Order.seqCst, T)(ref shared T a, T v) @safe nothrow @nogc
        {
            T cur = load!(Order.relaxed)(a);
            while (!cas!(o, Order.relaxed)(a, cur, cast(T)(cur & v))) {}
            return cur;
        }

        /// The bucket of `key` (SYP1).
        size_t bucketOf(size_t key) @safe nothrow @nogc
        {
            import sparkles.base.sync.parking_lot : bucketIndex;

            return bucketIndex(key);
        }

        /// The monotonic clock, in `MonoTime` ticks.
        long now() @safe nothrow @nogc => MonoTime.currTime.ticks;

        /// A processor pause hint.
        void pause() @safe nothrow @nogc
        {
            import core.atomic : pause;

            pause();
        }

        /// Gives the processor to another thread.
        void yieldThread() @trusted nothrow @nogc
        {
            import core.thread : Thread;

            Thread.yield();
        }

        /// This thread's parker state.
        ThreadState!NativePlatform* thread() @trusted nothrow @nogc => &tlsState;

        // Model hooks; nothing in a native build.
        void bucketLocked() @safe nothrow @nogc {}
        void bucketUnlocked() @safe nothrow @nogc {}
        void recordTouched(const(void)* record) @safe nothrow @nogc {}
        void parkReturned(const(void)* record) @safe nothrow @nogc {}
    }

    static if (sparkles.base.sync.seam.hasNativeSeam)
    {
        SeamResult seamWait(ref shared uint word, uint expected, Deadline d) @safe nothrow @nogc
            => sparkles.base.sync.seam.wait(word, expected, d);

        void seamWake(ref shared uint word, WakeCount count) @safe nothrow @nogc
            => sparkles.base.sync.seam.wake(word, count);

        /// Wakes an address that may no longer hold live storage (SYK8).
        void seamWakeAddress(size_t word, WakeCount count) @trusted nothrow @nogc
            => sparkles.base.sync.seam.wakeAddress(cast(shared(uint)*) word, count);
    }
    else
    {
        // The portable fallback (SYF2): no seam. The bucket lock spins and
        // yields, and the thread parker sleeps on its own condition variable.
        SeamResult seamWait(ref shared uint word, uint expected, Deadline d) @safe nothrow @nogc
        {
            yieldThread();
            return SeamResult.woken;
        }

        void seamWake(ref shared uint word, WakeCount count) @safe nothrow @nogc {}

        void seamWakeAddress(size_t word, WakeCount count) @safe nothrow @nogc {}
    }
}

private ThreadState!NativePlatform tlsState;

static assert(isSyncPlatform!NativePlatform);

/**
Gives an atomic word its first value, in a constructor, before the word is
shared: not a store, so the model records it as the location's initial value.
A platform's own word type constructs with its own attributes; only the
native `shared` word is trusted, its plain store being to a word no other
thread can see yet.
*/
package(sparkles.base.sync) void initState(A, T)(ref A word, T v)
{
    static if (is(A == shared(T)))
        () @trusted { word = A(v); }();
    else
        word = A(v);
}
