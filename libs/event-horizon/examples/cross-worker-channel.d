#!/usr/bin/env dub
/+ dub.sdl:
    name "event_horizon_cross_worker_channel"
    dependency "sparkles:event-horizon" path="../../.."
    dependency "sparkles:base" path="../../.."
    platforms "linux" "osx"
    targetPath "build"
    // Platform default, or `-c libkqueue` for the Linux peer path.
    configuration "default-backend" {
        targetType "executable"
    }
    configuration "libkqueue" {
        targetType "executable"
        subConfiguration "sparkles:event-horizon" "libkqueue"
    }
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * A `CrossChannel` (SPEC §14.1) between the fibers of two thread-per-core
 * workers and a thread no scheduler runs: the executor-to-reporter handoff of
 * the `apps/ci` task DAG, on whichever backend this build selects. Unit-test
 * builds cover only io_uring, so this is how the kqueue path (libkqueue on
 * Linux, native on macOS) is exercised.
 *
 * Four fiber producers and a producer thread push 20 000 items each through
 * a 16-slot channel to four fiber consumers and a consumer thread; then a
 * parked take is cancelled. It checks that every item arrived exactly once,
 * by count, checksum and a per-item tally, and that the cancelled take
 * consumed nothing.
 *
 * ---
 * dub run --single cross-worker-channel.d -b checked               # platform default
 * dub run --single cross-worker-channel.d -b checked -c libkqueue  # kqueue via libkqueue
 * ---
 *
 * Prints `SKIP:` and exits 0 if the backend cannot open.
 */
module event_horizon_cross_worker_channel;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.stdc.errno : ECANCELED, EPIPE;
import core.thread : Thread;
import core.time : MonoTime, seconds;
import std.typecons : No;

import sparkles.base.logger : error, info, initLogger, LogLevel, warning;
import sparkles.event_horizon.backend.select : DefaultBackend;
import sparkles.event_horizon.cross_channel : CrossChannel;
import sparkles.event_horizon.errors : IoResult;
import sparkles.event_horizon.group : LoopGroup, LoopGroupConfig, RootScope, Topology;
import sparkles.event_horizon.sched : currentScheduler, Sched;
import sparkles.event_horizon.scope_ : withScope;

/// Backend this build resolved to (for ok/SKIP messages).
version (EventHorizonLibkqueue)
    enum backend = DefaultBackend.stringof ~ " (mheily/libkqueue)";
else
    enum backend = DefaultBackend.stringof;

enum uint fiberProducers = 4, producers = fiberProducers + 1, perProducer = 20_000;
enum uint fiberConsumers = 4;
enum ulong total = ulong(producers) * perProducer;

int main()
{
    initLogger(LogLevel.info);

    LoopGroupConfig cfg;
    cfg.topology = Topology.threadPerCore;
    cfg.workers = 2;
    cfg.pinToCpu = No.pinToCpu;
    LoopGroup group;
    auto started = LoopGroup.start(group, cfg);
    if (started.hasError)
    {
        warning(i"SKIP: $(backend) unavailable (errno $(started.error.code)) — $(started.error.context)");
        return 0;
    }

    auto ch = new CrossChannel!(ulong, 16);
    auto seen = new shared(ubyte)[total];
    shared uint failures, producersLeft = producers, workersRan;
    shared ulong count, checksum;

    void produce(uint p, scope IoResult!void delegate(ulong) put)
    {
        foreach (seq; 0 .. perProducer)
            if (put((ulong(p) << 32) | seq).hasError)
                atomicOp!"+="(failures, 1);
        if (atomicOp!"-="(producersLeft, 1) == 0)
            ch.close();
    }

    void consume(scope IoResult!ulong delegate() take)
    {
        ulong n, sum;
        for (auto r = take(); !r.hasError; r = take())
        {
            const v = r.value, p = v >> 32, seq = v & uint.max;
            if (p >= producers || seq >= perProducer)
            {
                atomicOp!"+="(failures, 1);
                continue;
            }
            atomicOp!"+="(seen[p * perProducer + seq], 1);
            ++n;
            sum += v;
        }
        atomicOp!"+="(count, n);
        atomicOp!"+="(checksum, sum);
    }

    const t0 = MonoTime.currTime;
    auto threadProducer = new Thread(() => produce(fiberProducers, (ulong v) => ch.put(v))).start();
    auto threadConsumer = new Thread(() => consume(() => ch.take())).start();
    group.runEach((uint id, ref RootScope root, ref env) {
        atomicOp!"+="(workersRan, 1);
        foreach (k; 0 .. fiberProducers / 2)
            root.spawn(((uint p) => () {
                produce(p, (ulong v) => ch.put(currentScheduler(), v));
            })(id * (fiberProducers / 2) + k));
        foreach (_; 0 .. fiberConsumers / 2)
            root.spawn(() { consume(() => ch.take(currentScheduler())); });
    });
    threadProducer.join();
    threadConsumer.join();
    const elapsed = MonoTime.currTime - t0;

    ulong expectedSum;
    foreach (p; 0 .. producers)
        foreach (seq; 0 .. perProducer)
            expectedSum += (ulong(p) << 32) | seq;
    uint wrongTally;
    foreach (i; 0 .. total)
        wrongTally += atomicLoad(seen[i]) != 1;

    // A take parked on worker 1, cancelled by its scope; a later put on
    // worker 0 reaches the next taker.
    auto second = new CrossChannel!(uint, 2);
    shared int cancelledCode = -1;
    shared bool cancelled, sent;
    shared uint later;
    group.runEach((uint id, ref RootScope root, ref env) {
        ref Sched s = currentScheduler();
        if (id == 0)
        {
            while (!atomicLoad(cancelled))
                s.yieldNow();
            if (second.put(s, 7).hasError)
                atomicOp!"+="(failures, 1);
            atomicStore(sent, true);
            return;
        }
        root.spawn(() {
            cast(void) withScope!((ref sc) {
                sc.spawn(() {
                    auto r = second.take(currentScheduler());
                    atomicStore(cancelledCode, r.hasError ? r.error.code : 0);
                });
                ref Sched me = currentScheduler();
                while (second.parkedTakers != 1)
                    me.yieldNow();
                sc.cancel();
            })(currentScheduler());
            atomicStore(cancelled, true);
        });
        while (!atomicLoad(sent))
            s.yieldNow();
        auto r = second.take(s);
        atomicStore(later, r.hasValue ? r.value : 0);
    });

    const ok = atomicLoad(workersRan) == 2 && atomicLoad(failures) == 0
        && atomicLoad(count) == total && atomicLoad(checksum) == expectedSum && wrongTally == 0
        && atomicLoad(cancelledCode) == ECANCELED && atomicLoad(later) == 7
        && second.length == 0;
    const sumState = atomicLoad(checksum) == expectedSum ? "ok" : "wrong";
    const ms = elapsed.total!"msecs";
    if (!ok)
    {
        error(i"FAIL: $(backend): workers $(atomicLoad(workersRan))/2, failures $(atomicLoad(failures)), count $(atomicLoad(count))/$(total), checksum $(sumState), tally $(wrongTally) wrong, cancelled take $(atomicLoad(cancelledCode)), later take $(atomicLoad(later))");
        return 1;
    }
    info(i"ok: $(backend): $(total) items, each delivered once, in $(ms) ms; a cancelled take consumed nothing");
    return 0;
}
