/**
Litmus tests (oracle 9): for each ordering pair of primitives.md §13, a
message-passing test writes plain data, performs the releasing operation,
and checks the data after the acquiring operation.

Each round streams through `instances` independent copies of the primitive,
one message apiece, with the reader running ahead of the writer. That shape
is what makes a reordering visible on arm64: the reader's sequential walk
leaves a stale copy of the payload in its cache, so a payload load satisfied
early returns old data. A single primitive reused a million times shows none,
on Apple cores at least, even fully weakened — its lines bounce between the
two cores every round.

Each test runs over `NativePlatform`, where a stale read is a failure, and over
`WeakPlatform`, whose orderings are all relaxed: on arm64, a weakly ordered
machine, the weakened variant must show a stale read within its budget of
rounds, or the test proves nothing. The x86-64 legs run both as a control, and
there the weakened variant passes.

That requirement holds for the optimized build
(`libs/base/tools/check-sync-litmus.d`) only. Unoptimized, as `dub test` builds
it, the weakened locks show no stale read on Apple or Neoverse cores: both
commit a lock's stores in order, and the reordering a dropped ordering allows
comes from the compiler moving the protected accesses across the relaxed
atomics.
*/
module sparkles.base.sync.litmus_test;

import core.atomic : atomicLoad, atomicStore, MemoryOrder;
import core.thread : Thread;
import core.time : MonoTime, msecs;

import sparkles.base.sync.condition : ConditionT;
import sparkles.base.sync.interruptible_mutex : InterruptibleMutexT;
import sparkles.base.sync.mutex : MutexT;
import sparkles.base.sync.once : OnceT;
import sparkles.base.sync.platform : NativePlatform;
import sparkles.base.sync.seam : Deadline;
import sparkles.base.sync.weak_platform : WeakPlatform;

private enum size_t instances = 20_000;

/// The rounds each platform runs: the real primitives a fixed number, the
/// weakened ones until the first stale read, within a budget. The oracle is
/// the optimized build (`SparklesSyncLitmus`); `dub test` runs both as a
/// check of the real primitives and asserts nothing about the weakened ones.
version (SparklesSyncLitmus)
{
    private enum uint nativeRounds = 100;
    version (AArch64)
        private enum uint weakBudget = 5000;
    else
        private enum uint weakBudget = 10;
}
else
{
    private enum uint nativeRounds = 10;
    private enum uint weakBudget = 10;
}

/// One message per instance: plain payload and a relaxed flag.
private final class Messages
{
    ulong[] data;
    shared(ulong)[] flag;

    this()
    {
        data = new ulong[instances];
        flag = new shared(ulong)[instances];
    }

    void send(size_t k)
    {
        data[k] = k + 1;
        atomicStore!(MemoryOrder.raw)(flag[k], 1);
    }

    bool sent(size_t k) const => atomicLoad!(MemoryOrder.raw)(flag[k]) != 0;

    bool stale(size_t k) const => data[k] != k + 1;
}

/// Runs `reader` and `writer` over fresh messages, the reader started first.
private ulong round(void delegate(Messages, ref ulong) reader,
    void delegate(Messages) writer) @system
{
    auto msgs = new Messages;
    shared bool go;
    ulong stale;
    auto t = new Thread({
        atomicStore(go, true);
        reader(msgs, stale);
    }).start();
    while (!atomicLoad(go)) {}
    writer(msgs);
    t.join();
    return stale;
}

/// The mutex pair: `unlock` happens before the next `lock` (§13).
private ulong mutexMp(P)() @system
{
    auto ms = new MutexT!P[instances];
    return round((Messages msgs, ref ulong stale) {
        foreach (k; 0 .. instances)
            for (;;)
            {
                ms[k].lock();
                const sent = msgs.sent(k), bad = msgs.stale(k);
                ms[k].unlock();
                if (sent)
                {
                    stale += bad;
                    break;
                }
            }
    }, (Messages msgs) {
        foreach (k; 0 .. instances)
        {
            ms[k].lock();
            msgs.send(k);
            ms[k].unlock();
        }
    });
}

/// The interruptible mutex pair: guard destruction happens before the next acquisition.
private ulong interruptibleMp(P)() @system
{
    auto ms = new InterruptibleMutexT!P[instances];
    shared(InterruptibleMutexT!P)* at(size_t k) => cast(shared(InterruptibleMutexT!P)*) &ms[k];
    return round((Messages msgs, ref ulong stale) {
        foreach (k; 0 .. instances)
            for (;;)
            {
                cast(void) at(k).acquireRaw(Deadline.never, false);
                const sent = msgs.sent(k), bad = msgs.stale(k);
                at(k).release();
                if (sent)
                {
                    stale += bad;
                    break;
                }
            }
    }, (Messages msgs) {
        foreach (k; 0 .. instances)
        {
            cast(void) at(k).acquireRaw(Deadline.never, false);
            msgs.send(k);
            at(k).release();
        }
    });
}

/// The condition pair: the notifier's writes before `notify` happen before the selected wait's return.
private ulong conditionMp(P)() @system
{
    auto ms = new MutexT!P[instances];
    auto cs = new ConditionT!P[instances];
    return round((Messages msgs, ref ulong stale) {
        foreach (k; 0 .. instances)
        {
            auto g = ms[k].guard();
            // A deadline, so a weakened variant that loses the notify (its
            // mutex let the waiter read a stale flag) rechecks rather than
            // sleeping forever.
            while (!msgs.sent(k))
                cast(void) cs[k].waitUntil(g, MonoTime.currTime + 10.msecs);
            stale += msgs.stale(k);
        }
    }, (Messages msgs) {
        foreach (k; 0 .. instances)
        {
            auto g = ms[k].guard();
            msgs.send(k);
            cs[k].notifyOne();
        }
    });
}

/// The `Once` pair: completion of `init` happens before every `call` that observes it.
private ulong onceMp(P)() @system
{
    auto onces = new OnceT!P[instances];
    return round((Messages msgs, ref ulong stale) {
        foreach (k; 0 .. instances)
        {
            // Spin until the writer has completed it, then check its data.
            while (!(cast(shared) onces[k]).isComplete) {}
            stale += msgs.stale(k);
        }
    }, (Messages msgs) {
        foreach (k; 0 .. instances)
            onces[k].call(() { msgs.data[k] = k + 1; });
    });
}

private void check(alias test)(string pair) @system
{
    import std.stdio : stdout, writefln;

    foreach (_; 0 .. nativeRounds)
        assert(test!NativePlatform() == 0,
            "a stale read through " ~ pair ~ ": an ordering edge is missing (SYH1)");
    ulong weak;
    uint rounds;
    while (weak == 0 && rounds < weakBudget)
    {
        weak += test!WeakPlatform();
        ++rounds;
    }
    writefln("litmus %s: weakened variant, %d stale reads in %d rounds", pair, weak, rounds);
    stdout.flush();
    version (SparklesSyncLitmus) version (AArch64)
        assert(weak > 0, "the weakened " ~ pair ~ " showed no stale read on arm64: "
            ~ "the litmus test proves nothing (oracle 9)");
}

@("sync.litmus.SYH1.mutex")
@system unittest
{
    check!mutexMp("Mutex unlock -> lock");
}

@("sync.litmus.SYH1.interruptibleMutex")
@system unittest
{
    check!interruptibleMp("InterruptibleMutex release -> acquisition");
}

@("sync.litmus.SYH1.condition")
@system unittest
{
    check!conditionMp("Condition notify -> wait");
}

@("sync.litmus.SYH1.once")
@system unittest
{
    check!onceMp("Once completion -> call");
}
