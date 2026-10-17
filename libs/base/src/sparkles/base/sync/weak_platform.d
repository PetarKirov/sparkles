/**
A deliberately broken platform for oracles 4 and 9: `NativePlatform` with
every ordering of the primitives' own operations weakened to relaxed. The
parking lot keeps its orderings (see `bucketLocked`).

Both halves go, the acquires with the releases. With the releases alone, a
stale read needs the writer's stores to become visible out of order, and the
arm64 cores tested (Apple, Neoverse) commit a lock's stores in order; with
both gone, the optimizer may move the protected accesses across the
primitive's atomics, and the litmus tests see it (`litmus_test.d`).

The litmus tests (oracle 9) run each primitive over it and must see the
weakening on a weakly ordered machine, and the ThreadSanitizer run (oracle 4)
must report it; otherwise their silence about the real primitives proves
nothing. Nothing outside those tests may use it.
*/
module sparkles.base.sync.weak_platform;

import core.atomic : atomicFence, MemoryOrder;

import sparkles.base.sync.parker : ThreadState;
import sparkles.base.sync.platform : failureOrder, NativePlatform, Order;
import sparkles.base.sync.seam : Deadline, SeamResult, WakeCount;

/// Every ordering, weakened.
enum Order weakened(Order o) = Order.relaxed;

/// The weakened platform.
struct WeakPlatform
{
    enum bool isModel = false;
    alias Atomic(T) = shared(T);

static:
    T load(Order o = Order.seqCst, T)(ref const shared T a) @safe nothrow @nogc
        => NativePlatform.load!(Order.relaxed)(a);

    T peek(T)(ref const shared T a) @safe nothrow @nogc => NativePlatform.peek(a);

    void store(Order o = Order.seqCst, T)(ref shared T a, T v) @safe nothrow @nogc
        => NativePlatform.store!(Order.relaxed)(a, v);

    bool cas(Order s = Order.seqCst, Order f = failureOrder!s, T)(ref shared T a, ref T expected,
        T desired) @safe nothrow @nogc
        => NativePlatform.cas!(weakened!s, weakened!f)(a, expected, desired);

    T exchange(Order o = Order.seqCst, T)(ref shared T a, T v) @safe nothrow @nogc
        => NativePlatform.exchange!(weakened!o)(a, v);

    T fetchAdd(Order o = Order.seqCst, T)(ref shared T a, T v) @safe nothrow @nogc
        => NativePlatform.fetchAdd!(weakened!o)(a, v);

    T fetchOr(Order o = Order.seqCst, T)(ref shared T a, T v) @safe nothrow @nogc
        => NativePlatform.fetchOr!(weakened!o)(a, v);

    T fetchAnd(Order o = Order.seqCst, T)(ref shared T a, T v) @safe nothrow @nogc
        => NativePlatform.fetchAnd!(weakened!o)(a, v);

    size_t bucketOf(size_t key) @safe nothrow @nogc => NativePlatform.bucketOf(key);
    long now() @safe nothrow @nogc => NativePlatform.now();
    void pause() @safe nothrow @nogc => NativePlatform.pause();
    void yieldThread() @safe nothrow @nogc => NativePlatform.yieldThread();
    ThreadState!WeakPlatform* thread() @trusted nothrow @nogc => &weakState;

    SeamResult seamWait(ref shared uint word, uint expected, Deadline d) @safe nothrow @nogc
        => NativePlatform.seamWait(word, expected, d);

    void seamWake(ref shared uint word, WakeCount count) @safe nothrow @nogc
        => NativePlatform.seamWake(word, count);

    void seamWakeAddress(size_t word, WakeCount count) @safe nothrow @nogc
        => NativePlatform.seamWakeAddress(word, count);

    // The parking lot itself stays sound: its bucket critical sections and
    // the return from a park keep their orderings, as fences. Without them a
    // weakened primitive loses wake-ups inside the lot and its waiter sleeps
    // forever, which a litmus test cannot tell from a slow run.
    // ThreadSanitizer does not model standalone fences, so oracle 4 still
    // sees every operation relaxed.
    void bucketLocked() @safe nothrow @nogc => atomicFence!(MemoryOrder.acq)();
    void bucketUnlocked() @safe nothrow @nogc => atomicFence!(MemoryOrder.rel)();
    void recordTouched(const(void)* record) @safe nothrow @nogc {}
    void parkReturned(const(void)* record) @safe nothrow @nogc
        => atomicFence!(MemoryOrder.acq)();
}

private ThreadState!WeakPlatform weakState;
