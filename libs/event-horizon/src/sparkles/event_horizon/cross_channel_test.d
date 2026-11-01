/**
Native tests of the cross-worker channel (SPEC §14.1): producers and
consumers on different workers of a thread-per-core `LoopGroup` and on
threads no scheduler runs; backpressure; close-then-drain; cancellation of a
parked put and a parked take, alone and racing a delivery; an exactly-once
stress; move-only elements and teardown.

Each scenario runs on both fiber-parker paths (fiber-parker.md EFP6). A
worker's failed `assert` would end only its own fiber, so workers report
through shared counters that the test checks after `runEach` joins.
*/
module sparkles.event_horizon.cross_channel_test;

version (unittest):
version (Posix):

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.lifetime : emplace, move;
import core.memory : pureFree, pureMalloc;
import core.stdc.errno : ECANCELED, EPIPE;
import core.thread.osthread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.typecons : No;

import sparkles.event_horizon.capability : hasFiberParker;
import sparkles.event_horizon.cause : FiberContext, Interrupt, InterruptKind, interruptFiber;
import sparkles.event_horizon.cross_channel : CrossChannel;
import sparkles.event_horizon.errors : IoResult, skipReason;
import sparkles.event_horizon.group : LoopGroup, LoopGroupConfig, RootScope, Topology;
import sparkles.event_horizon.sched : currentScheduler, FiberPark, Sched, SchedOptions,
    schedOrSkip;
import sparkles.event_horizon.scope_ : withScope;
import sparkles.event_horizon.testing : TestSched;
import sparkles.test_runner.skip : skipTest;

// A test that bounds a run's wall-clock time is `@serial`, as the supervise
// tests are: beside the other parallel tests the bound would measure the
// host's load, not the channel.
import sparkles.test_runner.attributes : serial;

private:

/// Both paths; the ring path falls back to the inbox without futex ops.
immutable FiberPark[2] parkPaths = [FiberPark.ring, FiberPark.inbox];

/// Starts a thread-per-core group of `workers` on `path`, or skips.
void startGroup(out LoopGroup group, FiberPark path, uint workers = 2) @system
{
    {
        Sched probe;
        schedOrSkip(probe, SchedOptions(fiberPark: path));
        probe.destroy();
    }
    LoopGroupConfig cfg;
    cfg.topology = Topology.threadPerCore;
    cfg.workers = workers;
    cfg.pinToCpu = No.pinToCpu;
    cfg.fiberPark = path;
    auto started = LoopGroup.start(group, cfg);
    if (started.hasError)
        skipTest(skipReason(started.error));
}

/// Yields the current fiber until `cond` holds; `false` if it never does.
bool yieldUntil(ref Sched s, scope bool delegate() cond) @system
{
    const until = MonoTime.currTime + 10.seconds;
    while (!cond())
    {
        if (MonoTime.currTime >= until)
            return false;
        s.yieldNow();
    }
    return true;
}

/// Counts a failed expectation on a worker, where an `assert` would end only
/// that worker's fiber, and reports its line on stderr.
void expect(ref shared uint failures, bool cond, string what = null,
    uint line = __LINE__) @trusted nothrow @nogc
{
    import core.stdc.stdio : fprintf, stderr;

    if (cond)
        return;
    atomicOp!"+="(failures, 1);
    fprintf(stderr, "cross_channel_test.d(%u): expectation failed: %.*s\n", line,
        cast(int) what.length, what.ptr);
}

/// Runs `body_` on a fresh fiber of `s` and joins it. A scope cancelled from
/// its own body latches that body's fiber too (SPEC §8.4), so a test that
/// keeps using the channel afterwards cancels from a fiber it can spare.
void onFreshFiber(ref Sched s, void delegate() body_) @system
{
    cast(void) withScope!((ref sc) { sc.spawn(body_); })(s);
}

/// Starts a thread no scheduler knows, running `fn`.
Thread foreign(void delegate() fn) @system
{
    auto t = new Thread(fn);
    t.start();
    return t;
}

static assert(hasFiberParker!Sched);
static assert(!hasFiberParker!TestSched);
static assert(!__traits(compiles, (ref TestSched s, ref CrossChannel!int ch) => ch.take(s)),
    "the fiber verbs need an executor with a fiber parker");

// ── delivery across workers ─────────────────────────────────────────────────

@("crossChannel.putTake.producerAndConsumerOnDifferentWorkers")
@system
unittest
{
    enum uint items = 10_000;
    foreach (path; parkPaths)
    {
        LoopGroup group;
        startGroup(group, path);

        auto ch = new CrossChannel!(uint, 4);
        shared uint failures, received;
        group.runEach((uint id, ref RootScope root, ref env) {
            ref Sched s = currentScheduler();
            if (id == 0)
            {
                foreach (i; 0 .. items)
                    expect(failures, !ch.put(s, i).hasError);
                ch.close();
                return;
            }
            uint next;
            for (;;)
            {
                auto r = ch.take(s);
                if (r.hasError)
                {
                    expect(failures, r.error.code == EPIPE);
                    break;
                }
                expect(failures, r.value == next); // one producer: FIFO
                ++next;
            }
            atomicStore(received, next);
        });
        assert(atomicLoad(failures) == 0);
        assert(atomicLoad(received) == items, "every item arrived");
        assert(ch.length == 0 && ch.parkedPutters == 0 && ch.parkedTakers == 0);
    }
}

@("crossChannel.putTake.threadsWithoutASchedulerPutAndTake")
@system
unittest
{
    // A foreign producer thread and a foreign consumer thread, each beside a
    // fiber on a worker: the thread verbs park on the thread parker.
    enum uint items = 5_000;
    foreach (path; parkPaths)
    {
        LoopGroup group;
        startGroup(group, path, workers: 1);

        auto toFiber = new CrossChannel!(uint, 2);
        auto toThread = new CrossChannel!(uint, 2);
        shared uint failures, threadGot, fiberGot;
        auto producer = foreign(() {
            foreach (i; 0 .. items)
                expect(failures, !toFiber.put(i).hasError);
            toFiber.close();
        });
        auto consumer = foreign(() {
            uint next;
            for (auto r = toThread.take(); !r.hasError; r = toThread.take())
                expect(failures, r.value == next++);
            atomicStore(threadGot, next);
        });
        group.runEach((uint id, ref RootScope root, ref env) {
            ref Sched s = currentScheduler();
            uint next;
            for (auto r = toFiber.take(s); !r.hasError; r = toFiber.take(s))
            {
                expect(failures, r.value == next++);
                expect(failures, !toThread.put(s, r.value).hasError);
            }
            atomicStore(fiberGot, next);
            toThread.close();
        });
        producer.join();
        consumer.join();
        assert(atomicLoad(failures) == 0);
        assert(atomicLoad(fiberGot) == items && atomicLoad(threadGot) == items);
    }
}

// ── backpressure ────────────────────────────────────────────────────────────

@("crossChannel.backpressure.aFullChannelParksTheProducerUntilATake")
@system
unittest
{
    foreach (path; parkPaths)
    {
        LoopGroup group;
        startGroup(group, path);

        auto ch = new CrossChannel!(uint, 4);
        shared uint failures, ticks;
        shared bool putterDone, tickerDone;
        group.runEach((uint id, ref RootScope root, ref env) {
            ref Sched s = currentScheduler();
            if (id == 0)
            {
                // A ticker on the producer's worker: the parked put must
                // leave the worker running.
                auto sp = &s;
                root.spawn(() {
                    while (!atomicLoad(tickerDone))
                    {
                        atomicOp!"+="(ticks, 1);
                        sp.yieldNow();
                    }
                });
                foreach (i; 0 .. 5) // the fifth parks
                    expect(failures, !ch.put(s, i).hasError);
                atomicStore(putterDone, true);
                atomicStore(tickerDone, true);
                return;
            }
            expect(failures, yieldUntil(s, () => ch.parkedPutters == 1));
            expect(failures, ch.length == 4 && !atomicLoad(putterDone));
            const before = atomicLoad(ticks);
            expect(failures, yieldUntil(s, () => atomicLoad(ticks) > before + 10));
            expect(failures, ch.parkedPutters == 1 && !atomicLoad(putterDone));

            auto first = ch.take(s);
            expect(failures, first.hasValue && first.value == 0);
            expect(failures, yieldUntil(s, () => atomicLoad(putterDone)), "the take woke the putter");
            foreach (i; 1 .. 5)
            {
                auto r = ch.take(s);
                expect(failures, r.hasValue && r.value == i);
            }
            expect(failures, ch.length == 0);
        });
        assert(atomicLoad(failures) == 0);
        assert(atomicLoad(putterDone));
    }
}

// ── close and drain ─────────────────────────────────────────────────────────

@("crossChannel.close.drainsBufferedItemsThenEpipe")
@system
unittest
{
    foreach (path; parkPaths)
    {
        LoopGroup group;
        startGroup(group, path);

        auto ch = new CrossChannel!(uint, 8);
        shared uint failures, drained;
        group.runEach((uint id, ref RootScope root, ref env) {
            ref Sched s = currentScheduler();
            if (id == 0)
            {
                foreach (i; 1 .. 4)
                    expect(failures, !ch.put(s, i).hasError);
                ch.close();
                ch.close(); // idempotent
                auto p = ch.put(s, 4);
                expect(failures, p.hasError && p.error.code == EPIPE);
                uint four = 4;
                expect(failures, !ch.tryPut(four) && four == 4);
                return;
            }
            expect(failures, yieldUntil(s, () => ch.closed));
            foreach (i; 1 .. 4)
            {
                auto r = ch.take(s);
                expect(failures, r.hasValue && r.value == i);
                atomicOp!"+="(drained, r.hasValue);
            }
            foreach (_; 0 .. 2) // EPIPE stays
            {
                auto end = ch.take(s);
                expect(failures, end.hasError && end.error.code == EPIPE);
            }
        });
        assert(atomicLoad(failures) == 0);
        assert(atomicLoad(drained) == 3);
    }
}

@("crossChannel.close.aForeignThreadWakesParkedWaitersOnEveryWorker")
@system
unittest
{
    foreach (path; parkPaths)
    {
        LoopGroup group;
        startGroup(group, path);

        auto empty = new CrossChannel!(uint, 2);
        auto full = new CrossChannel!(uint, 1);
        uint filler = 0;
        assert(full.tryPut(filler));
        shared uint failures, takersEnded, puttersEnded;
        auto closer = foreign(() {
            const until = MonoTime.currTime + 10.seconds;
            while ((empty.parkedTakers < 4 || full.parkedPutters < 2) && MonoTime.currTime < until)
                Thread.sleep(1.msecs);
            empty.close();
            full.close();
        });
        group.runEach((uint id, ref RootScope root, ref env) {
            ref Sched s = currentScheduler();
            foreach (_; 0 .. 2)
                root.spawn(() {
                    auto r = empty.take(currentScheduler());
                    expect(failures, r.hasError && r.error.code == EPIPE);
                    atomicOp!"+="(takersEnded, 1);
                });
            root.spawn(() {
                auto r = full.put(currentScheduler(), 1);
                expect(failures, r.hasError && r.error.code == EPIPE);
                atomicOp!"+="(puttersEnded, 1);
            });
        });
        closer.join();
        assert(atomicLoad(failures) == 0);
        assert(atomicLoad(takersEnded) == 4 && atomicLoad(puttersEnded) == 2);
        assert(full.length == 1, "the put refused by close stored nothing");
    }
}

// ── cancellation ────────────────────────────────────────────────────────────

@("crossChannel.cancel.aParkedPutStoresNothing")
@system
unittest
{
    foreach (path; parkPaths)
    {
        LoopGroup group;
        startGroup(group, path);

        auto ch = new CrossChannel!(uint, 2);
        shared uint failures;
        shared bool cancelledPut;
        group.runEach((uint id, ref RootScope root, ref env) {
            ref Sched s = currentScheduler();
            if (id == 0)
            {
                foreach (i; 0 .. 2)
                    expect(failures, !ch.put(s, i).hasError);
                int code = -1, checkpointCode = -1;
                FiberContext* victim;
                cast(void) withScope!((ref sc) {
                    sc.spawn(() {
                        victim = currentScheduler().currentContext();
                        auto r = ch.put(currentScheduler(), 99);
                        code = r.hasError ? r.error.code : 0;
                        // Latched: the next put fails at its checkpoint.
                        auto again = ch.put(currentScheduler(), 98);
                        checkpointCode = again.hasError ? again.error.code : 0;
                    });
                    expect(failures, yieldUntil(s, () => ch.parkedPutters == 1));
                    interruptFiber(victim, Interrupt(InterruptKind.cancelled));
                })(s);
                expect(failures, code == ECANCELED);
                expect(failures, checkpointCode == ECANCELED, "the latch refuses the next put");
                expect(failures, ch.parkedPutters == 0 && ch.length == 2);
                atomicStore(cancelledPut, true);
                return;
            }
            expect(failures, yieldUntil(s, () => atomicLoad(cancelledPut)));
            uint v;
            foreach (i; 0 .. 2)
                expect(failures, ch.tryTake(v) && v == i);
            expect(failures, !ch.tryTake(v), "the cancelled put stored nothing");
        });
        assert(atomicLoad(failures) == 0);
        assert(atomicLoad(cancelledPut));
    }
}

@("crossChannel.cancel.aParkedTakeTakesNothing")
@system
unittest
{
    foreach (path; parkPaths)
    {
        LoopGroup group;
        startGroup(group, path);

        auto ch = new CrossChannel!(uint, 2);
        shared uint failures;
        shared bool cancelledTake, sent;
        group.runEach((uint id, ref RootScope root, ref env) {
            ref Sched s = currentScheduler();
            if (id == 1)
            {
                expect(failures, yieldUntil(s, () => atomicLoad(cancelledTake)));
                expect(failures, !ch.put(s, 7).hasError);
                atomicStore(sent, true);
                return;
            }
            int code = -1;
            FiberContext* victim;
            cast(void) withScope!((ref sc) {
                sc.spawn(() {
                    victim = currentScheduler().currentContext();
                    auto r = ch.take(currentScheduler());
                    code = r.hasError ? r.error.code : 0;
                });
                expect(failures, yieldUntil(s, () => ch.parkedTakers == 1));
                interruptFiber(victim, Interrupt(InterruptKind.cancelled));
            })(s);
            expect(failures, code == ECANCELED && ch.parkedTakers == 0);
            atomicStore(cancelledTake, true);
            expect(failures, yieldUntil(s, () => atomicLoad(sent)));
            auto r = ch.take(s);
            expect(failures, r.hasValue && r.value == 7, "the item reached the next taker");
            expect(failures, ch.length == 0);
        });
        assert(atomicLoad(failures) == 0);
        assert(atomicLoad(sent));
    }
}

@("crossChannel.cancel.aTakeRacingAPutDeliversExactlyOnce")
@serial
@system
unittest
{
    // Each round parks a taker on worker 0, lets worker 1 put one item, and
    // cancels the taker at a varying moment. Either the taker received the
    // item or it is still buffered: never both, never neither.
    enum uint rounds = 300;
    foreach (path; parkPaths)
    {
        LoopGroup group;
        startGroup(group, path);

        auto ch = new CrossChannel!(uint, 4);
        auto seen = new shared(uint)[rounds];
        shared uint failures, round, sentRound;
        group.runEach((uint id, ref RootScope root, ref env) {
            ref Sched s = currentScheduler();
            if (id == 1)
            {
                foreach (i; 0 .. rounds)
                {
                    if (!yieldUntil(s, () => atomicLoad(round) == i + 1))
                        return expect(failures, false);
                    expect(failures, !ch.put(s, i).hasError);
                    atomicStore(sentRound, i + 1);
                }
                return;
            }
            foreach (i; 0 .. rounds)
            {
                onFreshFiber(s, () {
                    cast(void) withScope!((ref sc) {
                        sc.spawn(() {
                            auto r = ch.take(currentScheduler());
                            if (r.hasValue)
                                atomicOp!"+="(seen[r.value], 1);
                            else
                                expect(failures, r.error.code == ECANCELED);
                        });
                        expect(failures, yieldUntil(s, () => ch.parkedTakers == 1));
                        atomicStore(round, i + 1);
                        foreach (_; 0 .. i % 5)
                            s.yieldNow();
                        sc.cancel();
                    })(s);
                });
                expect(failures, yieldUntil(s, () => atomicLoad(sentRound) == i + 1));
                uint v;
                while (ch.tryTake(v))
                    atomicOp!"+="(seen[v], 1);
            }
        });
        assert(atomicLoad(failures) == 0);
        foreach (i; 0 .. rounds)
            assert(atomicLoad(seen[i]) == 1, "an item was lost or duplicated");
        assert(ch.parkedTakers == 0 && ch.length == 0);
    }
}

@("crossChannel.cancel.aPutRacingATakeStoresAtMostOnce")
@serial
@system
unittest
{
    // Each round fills a one-slot channel on worker 0 and parks a putter
    // behind the filler; worker 1 takes the filler while worker 0 cancels
    // the putter. The putter's item is buffered exactly when its put
    // succeeded.
    enum uint rounds = 300;
    foreach (path; parkPaths)
    {
        LoopGroup group;
        startGroup(group, path);

        auto ch = new CrossChannel!(uint, 1);
        auto seen = new shared(uint)[2 * rounds];
        auto putOk = new shared(bool)[rounds];
        shared uint failures, round, roundDone;
        group.runEach((uint id, ref RootScope root, ref env) {
            ref Sched s = currentScheduler();
            if (id == 1)
            {
                foreach (i; 0 .. rounds)
                {
                    if (!yieldUntil(s, () => atomicLoad(round) == i + 1))
                        return expect(failures, false);
                    auto r = ch.take(s);
                    expect(failures, r.hasValue && r.value == 2 * i);
                    if (r.hasValue)
                        atomicOp!"+="(seen[r.value], 1);
                    if (!yieldUntil(s, () => atomicLoad(roundDone) == i + 1))
                        return expect(failures, false);
                    uint v;
                    while (ch.tryTake(v))
                        atomicOp!"+="(seen[v], 1);
                    atomicStore(roundDone, uint.max - i); // drained
                }
                return;
            }
            foreach (i; 0 .. rounds)
            {
                expect(failures, !ch.put(s, 2 * i).hasError);
                onFreshFiber(s, () {
                    cast(void) withScope!((ref sc) {
                        sc.spawn(() {
                            auto r = ch.put(currentScheduler(), 2 * i + 1);
                            atomicStore(putOk[i], !r.hasError);
                            expect(failures, !r.hasError || r.error.code == ECANCELED);
                        });
                        expect(failures, yieldUntil(s, () => ch.parkedPutters == 1));
                        atomicStore(round, i + 1);
                        foreach (_; 0 .. i % 5)
                            s.yieldNow();
                        sc.cancel();
                    })(s);
                });
                atomicStore(roundDone, i + 1);
                expect(failures, yieldUntil(s, () => atomicLoad(roundDone) == uint.max - i));
            }
        });
        assert(atomicLoad(failures) == 0);
        foreach (i; 0 .. rounds)
        {
            assert(atomicLoad(seen[2 * i]) == 1, "the filler was lost or duplicated");
            assert(atomicLoad(seen[2 * i + 1]) == (atomicLoad(putOk[i]) ? 1 : 0),
                "a cancelled put stored, or a successful one was lost");
        }
        assert(ch.parkedPutters == 0 && ch.length == 0);
    }
}

// ── the exactly-once stress ─────────────────────────────────────────────────

@("crossChannel.stress.producersAndConsumersSeeEveryItemOnce")
@serial
@system
unittest
{
    // Four fiber producers and four fiber consumers on two workers, plus a
    // producer thread and a consumer thread no scheduler runs, through a
    // 16-slot channel. Every item is seen once; the counts and the checksums
    // agree; each consumer sees each producer's items in order.
    enum uint fiberProducers = 4, producers = fiberProducers + 1, perProducer = 20_000;
    enum uint fiberConsumers = 4;
    enum ulong total = ulong(producers) * perProducer;
    foreach (path; parkPaths)
    {
        LoopGroup group;
        startGroup(group, path);

        auto ch = new CrossChannel!(ulong, 16);
        auto seen = new shared(ubyte)[total];
        shared uint failures, producersLeft = producers;
        shared ulong count, checksum;

        void produce(uint p, scope IoResult!void delegate(ulong) put)
        {
            foreach (seq; 0 .. perProducer)
                expect(failures, !put((ulong(p) << 32) | seq).hasError);
            if (atomicOp!"-="(producersLeft, 1) == 0)
                ch.close();
        }

        void consume(scope IoResult!ulong delegate() take)
        {
            uint[producers] next;
            ulong n, sum;
            for (auto r = take(); ; r = take())
            {
                if (r.hasError)
                {
                    expect(failures, r.error.code == EPIPE);
                    break;
                }
                const v = r.value, p = cast(uint)(v >> 32), seq = cast(uint) v;
                expect(failures, p < producers && seq < perProducer);
                if (p >= producers || seq >= perProducer)
                    continue;
                expect(failures, seq >= next[p]); // per-producer FIFO
                next[p] = seq + 1;
                atomicOp!"+="(seen[ulong(p) * perProducer + seq], 1);
                ++n;
                sum += v;
            }
            atomicOp!"+="(count, n);
            atomicOp!"+="(checksum, sum);
        }

        auto threadProducer = foreign(() => produce(fiberProducers, (ulong v) => ch.put(v)));
        auto threadConsumer = foreign(() => consume(() => ch.take()));
        group.runEach((uint id, ref RootScope root, ref env) {
            foreach (k; 0 .. fiberProducers / 2)
                root.spawn(((uint p) => () {
                    produce(p, (ulong v) => ch.put(currentScheduler(), v));
                })(id * (fiberProducers / 2) + k));
            foreach (_; 0 .. fiberConsumers / 2)
                root.spawn(() { consume(() => ch.take(currentScheduler())); });
        });
        threadProducer.join();
        threadConsumer.join();

        ulong expectedSum;
        foreach (p; 0 .. producers)
            foreach (seq; 0 .. perProducer)
                expectedSum += (ulong(p) << 32) | seq;
        assert(atomicLoad(failures) == 0);
        assert(atomicLoad(count) == total, "the item count");
        assert(atomicLoad(checksum) == expectedSum, "the checksum");
        foreach (i; 0 .. total)
            assert(atomicLoad(seen[i]) == 1, "an item was lost or duplicated");
        assert(ch.length == 0 && ch.parkedPutters == 0 && ch.parkedTakers == 0);
    }
}

// ── move-only elements and teardown ─────────────────────────────────────────

/// A move-only element that counts the destruction of live values.
struct Box
{
    @disable this(this);
    uint v;
    static shared uint destroyed;

    ~this() @safe nothrow @nogc
    {
        if (v != 0)
            atomicOp!"+="(destroyed, 1);
    }
}

@("crossChannel.moveOnly.elementsMoveAcrossWorkersAndBufferedOnesDieWithTheChannel")
@system
unittest
{
    foreach (path; parkPaths)
    {
        LoopGroup group;
        startGroup(group, path);

        atomicStore(Box.destroyed, 0);
        {
            auto mem = pureMalloc(CrossChannel!(Box, 4).sizeof);
            assert(mem !is null);
            auto ch = emplace(cast(CrossChannel!(Box, 4)*) mem);
            shared uint failures, got;
            group.runEach((uint id, ref RootScope root, ref env) {
                ref Sched s = currentScheduler();
                if (id == 0)
                {
                    foreach (v; 1 .. 5)
                        expect(failures, !ch.put(s, Box(v)).hasError);
                    return;
                }
                expect(failures, yieldUntil(s, () => ch.length == 4));
                auto r = ch.take(s);
                expect(failures, r.hasValue);
                if (r.hasValue)
                {
                    auto box = move(r.value);
                    atomicStore(got, box.v);
                }
            });
            assert(atomicLoad(failures) == 0);
            assert(atomicLoad(got) == 1);
            assert(atomicLoad(Box.destroyed) == 1, "only the taken box died");
            destroy(*ch);
            pureFree(mem);
        }
        assert(atomicLoad(Box.destroyed) == 4, "each buffered box died once, with the channel");
    }
}

@("crossChannel.teardown.closeJoinThenFreeWithWaitersOnEveryWorker")
@system
unittest
{
    // Waiters parked on both workers and on a thread are woken by close; once
    // every scope has joined, the channel's storage is freed. Under
    // AddressSanitizer a late touch of the channel by a wake fails here.
    foreach (path; parkPaths)
    {
        LoopGroup group;
        startGroup(group, path);

        alias Ch = CrossChannel!(uint, 2);
        auto mem = pureMalloc(Ch.sizeof);
        assert(mem !is null);
        auto ch = emplace(cast(Ch*) mem);
        shared uint failures, ended;
        auto threadTaker = foreign(() {
            auto r = ch.take();
            expect(failures, r.hasError && r.error.code == EPIPE);
            atomicOp!"+="(ended, 1);
        });
        group.runEach((uint id, ref RootScope root, ref env) {
            ref Sched s = currentScheduler();
            foreach (_; 0 .. 2)
                root.spawn(() {
                    auto r = ch.take(currentScheduler());
                    expect(failures, r.hasError && r.error.code == EPIPE);
                    atomicOp!"+="(ended, 1);
                });
            if (id == 0)
            {
                expect(failures, yieldUntil(s, () => ch.parkedTakers == 5));
                ch.close();
            }
        });
        threadTaker.join();
        assert(atomicLoad(failures) == 0);
        assert(atomicLoad(ended) == 5);
        destroy(*ch); // asserts that nobody is parked
        (cast(ubyte*) mem)[0 .. Ch.sizeof] = 0xA5;
        pureFree(mem);
    }
}
