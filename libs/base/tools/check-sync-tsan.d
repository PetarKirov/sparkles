#!/usr/bin/env dub
/+ dub.sdl:
    name "check_sync_tsan"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Oracle 4 of `docs/specs/base/sync/testing.md`: base.sync's native stress
under LDC's ThreadSanitizer, on Linux.

Each program protects plain data with a primitive across several threads.
Built over `NativePlatform`, TSan must report nothing: a report shows a
missing ordering edge in a schedule the run reached. The seeded faults are
the same programs over `WeakPlatform`, whose orderings are all relaxed —
among them a mutex's release, and the thread parker's wake store, which every
park publishes through — and each must produce a report, or the
configuration's silence proves nothing. The primitives annotate no
happens-before edge for TSan: every edge it sees comes from an atomic
operation.

    dub run --single --temp-build libs/base/tools/check-sync-tsan.d
*/
module check_sync_tsan;

import std.algorithm : canFind;
import std.array : join;
import std.file : dirEntries, SpanMode, tempDir, write;
import std.path : buildPath;
import std.process : execute;
import std.stdio : writefln, writeln;

/// A program over platform `P` (`NativePlatform` or `WeakPlatform`).
enum string header = q{
import core.thread : Thread;
import sparkles.base.sync.barrier : BarrierT;
import sparkles.base.sync.condition : ConditionT;
import sparkles.base.sync.event : AutoResetEventT;
import sparkles.base.sync.interruptible_mutex : InterruptibleMutexT;
import sparkles.base.sync.latch : LatchT;
import sparkles.base.sync.mutex : MutexT;
import sparkles.base.sync.once : OnceT;
import sparkles.base.sync.parking_lot;
import sparkles.base.sync.platform : NativePlatform;
import sparkles.base.sync.rwlock : RwLockT;
import sparkles.base.sync.seam : Deadline;
import sparkles.base.sync.semaphore : SemaphoreT;
import sparkles.base.sync.weak_platform : WeakPlatform;

void run(void delegate() body, uint threads = 4)
{
    Thread[] ts;
    foreach (_; 0 .. threads)
        ts ~= new Thread(body).start();
    foreach (t; ts)
        t.join();
}
};

/// The workloads: each takes the platform as `P`.
enum string[string] workloads = [
    "mutex": q{
        __gshared MutexT!P m;
        __gshared ulong counter;
        void main() { run({ foreach (_; 0 .. 20_000) { m.lock(); ++counter; m.unlock(); } }); }
    },
    "interruptible": q{
        __gshared InterruptibleMutexT!P m;
        __gshared ulong counter;
        void main()
        {
            run({
                foreach (_; 0 .. 5_000)
                {
                    auto a = m.lock();
                    ++counter;
                }
            });
        }
    },
    "condition": q{
        __gshared MutexT!P m;
        __gshared ConditionT!P c;
        __gshared int queued, consumed;
        void main()
        {
            Thread[] ts;
            foreach (_; 0 .. 2)
                ts ~= new Thread({
                    foreach (__; 0 .. 2_000)
                    {
                        auto g = m.guard();
                        while (queued == 0)
                            c.wait(g);
                        --queued;
                        ++consumed;
                    }
                }).start();
            foreach (_; 0 .. 2)
                ts ~= new Thread({
                    foreach (__; 0 .. 2_000)
                    {
                        auto g = m.guard();
                        ++queued;
                        c.notifyOne();
                    }
                }).start();
            foreach (t; ts)
                t.join();
        }
    },
    "once": q{
        __gshared OnceT!P[2_000] onces;
        __gshared ulong[2_000] payload;
        void main()
        {
            run({
                foreach (k; 0 .. 2_000)
                {
                    onces[k].call(() { payload[k] = k + 1; });
                    if (payload[k] != k + 1)
                        assert(0);
                }
            });
        }
    },
    "rwlock": q{
        __gshared RwLockT!P l;
        __gshared ulong counter;
        void main()
        {
            run({
                foreach (i; 0 .. 10_000)
                    if (i % 4 == 0)
                    {
                        l.lock();
                        ++counter;
                        l.unlock();
                    }
                    else
                    {
                        l.lockShared();
                        const x = counter;
                        l.unlockShared();
                        if (x == ulong.max)
                            assert(0);
                    }
            });
        }
    },
    "semaphore": q{
        __gshared SemaphoreT!P s;
        __gshared ulong counter;
        void main()
        {
            s = SemaphoreT!P(1);
            run({ foreach (_; 0 .. 10_000) { s.acquire(); ++counter; s.release(); } });
        }
    },
    // An auto-reset event as a token: `wait` takes it, `set` passes it on.
    "event": q{
        __gshared AutoResetEventT!P e;
        __gshared ulong counter;
        void main()
        {
            e.set();
            run({ foreach (_; 0 .. 5_000) { e.wait(); ++counter; e.set(); } });
        }
    },
    "latch": q{
        __gshared LatchT!P[2_000] latches;
        __gshared ulong[2_000] payload;
        void main()
        {
            foreach (ref l; latches)
                l = LatchT!P(1);
            auto reader = new Thread({
                foreach (k; 0 .. 2_000)
                {
                    latches[k].wait();
                    if (payload[k] != k + 1)
                        assert(0);
                }
            }).start();
            foreach (k; 0 .. 2_000)
            {
                payload[k] = k + 1;
                latches[k].countDown();
            }
            reader.join();
        }
    },
    "barrier": q{
        __gshared BarrierT!P b;
        __gshared ulong[4] slots;
        void main()
        {
            b = BarrierT!P(4);
            Thread[] ts;
            foreach (i; 0 .. 4)
                ts ~= new Thread(((size_t id) => () {
                    foreach (gen; 1 .. 2_001)
                    {
                        slots[id] = gen;
                        cast(void) b.arriveAndWait();
                        foreach (s; slots)
                            if (s < gen)
                                assert(0);
                        cast(void) b.arriveAndWait();
                    }
                })(i)).start();
            foreach (t; ts)
                t.join();
        }
    },
    // Publication through park and unpark alone: the thread parker's wake
    // store carries the edge (SYH2).
    "park": q{
        __gshared ulong data;
        shared bool parked;
        void main()
        {
            import core.atomic : atomicLoad, atomicStore;

            const key = cast(size_t) &data;
            auto waiter = new Thread({
                const r = park!P(key, ParkOptions(1), (ref const LockedKey!P lk) {
                    atomicStore(parked, true);
                    return true;
                });
                if (r.outcome == ParkOutcome.unparked && data != 7)
                    assert(0);
            }).start();
            while (!atomicLoad(parked))
                Thread.yield();
            Thread.sleep(dur!"msecs"(1));
            data = 7;
            while (unparkOne!P(key, 1, (ref const LockedKey!P lk, UnparkResult r)
                    => UnparkDecision(1)).unparked == 0)
                Thread.yield();
            waiter.join();
        }
    },
];

int main()
{
    const dir = buildPath(tempDir, "sparkles-sync-tsan");
    import std.file : mkdirRecurse;

    mkdirRecurse(dir);
    string[] sources;
    foreach (e; dirEntries("libs/base/src/sparkles/base/sync", "*.d", SpanMode.shallow))
        if (!e.name.canFind("_test.d") && !e.name.canFind("model.d"))
            sources ~= e.name;
    bool ok = true;
    foreach (name, body_; workloads)
        foreach (platform; ["NativePlatform", "WeakPlatform"])
        {
            const src = buildPath(dir, name ~ "_" ~ platform ~ ".d");
            write(src, header ~ "import core.time : dur;\nalias P = " ~ platform ~ ";\n" ~ body_);
            const bin = src[0 .. $ - 2];
            const b = execute(["ldc2", "-g", "-O1", "-fsanitize=thread", "-preview=in",
                "-preview=dip1000", "-Ilibs/base/src", "-of=" ~ bin, src] ~ sources);
            if (b.status != 0)
            {
                writeln(b.output);
                return 1;
            }
            // Without ASLR: under the address entropy of recent kernels, TSan's
            // runtime can find a mapping where its shadow memory goes and abort
            // ("unexpected memory mapping") before the program runs.
            const r = execute(["setarch", "-R", bin],
                ["TSAN_OPTIONS": "halt_on_error=1 exitcode=66"]);
            const reported = r.output.canFind("ThreadSanitizer: data race");
            const expectReport = platform == "WeakPlatform";
            // The weakened mutex variants race on their protected data; the
            // `park` fault is the thread parker's relaxed wake store.
            const pass = reported == expectReport && (reported || r.status == 0);
            ok &= pass;
            writefln("%-14s %-15s %s: %s", name, platform,
                reported ? "data race reported" : "no report", pass ? "ok" : "FAIL");
            if (!pass)
                writeln(r.output);
        }
    return ok ? 0 : 1;
}
