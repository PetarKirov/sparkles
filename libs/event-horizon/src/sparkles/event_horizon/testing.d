/**
The deterministic test executor (SPEC §10.3): `TestSched` runs fibers with
no ring and no real time — it satisfies `isFiberExecutor` (so every `scope_`
semantic works on it) and provides the `isWaker` view that `TestClock` and
`SimNet` park through. `advanceAndSettle` packages the quiescence
discipline: run until nothing is ready, advance virtual time to the next
deadline, repeat.

$(B Effects-side module): it builds on `core.thread.Fiber` directly, which
the import firewall permits (the ban covers ring/loop/scheduler modules).
GC-backed storage is fine here — this is test infrastructure.
*/
module sparkles.event_horizon.testing;

import core.thread.fiber : Fiber;
import core.time : Duration;

import sparkles.event_horizon.capability : SpawnOptions, isFiberExecutor, isWaker;
import sparkles.event_horizon.cause : CancelContext, FiberContext;
import sparkles.event_horizon.clock : TestClock;

/// The deterministic executor.
struct TestSched
{
    @disable this(this);

    /// The one-shot park/wake view (`isWaker`) capabilities suspend through.
    static struct Waker
    {
        /// A prepared park identity: the task's context.
        alias Handle = FiberContext*;

        private TestSched* sched;

        /// The current task's handle.
        Handle prepare() @safe nothrow @nogc
            => sched.currentContext();

        /// Parks until `wake(h)`; wake-before-park is a no-op park.
        void park(Handle h) @trusted nothrow
        {
            auto task = cast(TestTask) h.taskBacklink;
            if (task.wakePending)
            {
                task.wakePending = false;
                return;
            }
            Fiber.yield();
        }

        /// Makes a parked task runnable (idempotent per prepared handle).
        void wake(Handle h) @trusted nothrow
        {
            auto task = cast(TestTask) h.taskBacklink;
            if (task.state == Fiber.State.EXEC)
            {
                task.wakePending = true; // wake-before-park guard
                return;
            }
            sched.enqueue(task);
        }
    }

    /// ditto
    Waker waker() return @safe nothrow @nogc
        => Waker((() @trusted => &this)());

    // ── the fiber-executor concept ───────────────────────────────────────

    /// The running task's effects-visible context.
    FiberContext* currentContext() @safe nothrow @nogc
    in (_running !is null, "not on a TestSched fiber")
        => &_running.ectx;

    /// Spawns a child bound to `node`; enqueued, never run inline.
    FiberContext* spawnFiber(scope CancelContext* node, in SpawnOptions opts,
        void delegate() body_) @trusted nothrow
    {
        auto t = new TestTask(&this, body_);
        t.ectx.daemon = opts.daemon;
        if (node !is null)
            node.addFiber(&t.ectx);
        ++_liveFibers;
        enqueue(t);
        return &t.ectx;
    }

    /// Suspends the current task until one `wake`.
    void park() @trusted nothrow
    in (_running !is null)
    {
        Fiber.yield();
    }

    /// Makes a parked task runnable.
    void wake(FiberContext* f) @trusted nothrow @nogc
    {
        enqueue(cast(TestTask) f.taskBacklink);
    }

    // ── driving ──────────────────────────────────────────────────────────

    /// Spawns `root` and settles.
    void run(void delegate() root) @trusted
    {
        cast(void) spawnFiber(null, SpawnOptions.init, root);
        settle();
    }

    /// Runs ready tasks until none remain (quiescence: everything live is
    /// parked on a capability — a clock sleeper or a net waiter).
    void settle() @trusted
    {
        while (_readyHead !is null)
        {
            auto t = dequeue();
            _running = t;
            auto thrown = t.call(Fiber.Rethrow.no);
            _running = null;
            assert(thrown is null, "the shell catches all Throwables");
            if (t.state == Fiber.State.TERM)
                --_liveFibers;
        }
    }

    /// Tasks spawned and not yet finished.
    uint liveFibers() const @safe pure nothrow @nogc => _liveFibers;

private:
    final static class TestTask : Fiber
    {
        TestSched* owner;
        FiberContext ectx;
        TestTask nextReady;
        bool enqueued;
        bool wakePending;
        void delegate() body_;

        this(TestSched* owner, void delegate() dg) @trusted nothrow
        {
            super(&shell, 64 * 1024);
            this.owner = owner;
            this.body_ = dg;
            ectx.taskBacklink = cast(void*) this;
        }

        void shell()
        {
            Throwable defect;
            try
                body_();
            catch (Throwable t)
                defect = t;
            const fn = ectx.onExitFn;
            if (fn !is null)
            {
                auto ctx = ectx.onExitCtx;
                ectx.onExitFn = null;
                (() @trusted => fn(ctx, &ectx, defect))();
            }
            else
                assert(defect is null, "defect escaped a scope-less test fiber");
        }
    }

    void enqueue(TestTask t) @safe nothrow @nogc
    {
        if (t.enqueued)
            return;
        t.enqueued = true;
        t.nextReady = null;
        if (_readyTail is null)
            _readyHead = _readyTail = t;
        else
        {
            _readyTail.nextReady = t;
            _readyTail = t;
        }
    }

    TestTask dequeue() @safe nothrow @nogc
    {
        auto t = _readyHead;
        _readyHead = t.nextReady;
        if (_readyHead is null)
            _readyTail = null;
        t.nextReady = null;
        t.enqueued = false;
        return t;
    }

    TestTask _readyHead, _readyTail;
    TestTask _running;
    uint _liveFibers;
}

static assert(isFiberExecutor!TestSched);
static assert(isWaker!(TestSched.Waker));

/// The quiescence discipline (SPEC §10.3): settle, advance virtual time to
/// the next deadline, repeat — until no task is ready and no sleeper is
/// pending. Returns the number of clock advances performed.
size_t advanceAndSettle(W)(ref TestSched sched, scope ref TestClock!W clock)
{
    size_t advances;
    sched.settle();
    while (clock.advanceToNext())
    {
        ++advances;
        sched.settle();
    }
    return advances;
}

// ── the M6 gate: a workflow entirely under virtual time, no real I/O ────────

@("testing.gate.retryUnderTestClockAndSimNet")
@safe
unittest
{
    import core.time : MonoTime, msecs, seconds;

    import sparkles.event_horizon.capability : ctx, hasCaps;
    import sparkles.event_horizon.cause : Outcome;
    import sparkles.event_horizon.clock : TestClock, isClock;
    import sparkles.event_horizon.errors : IoError, IoResult, ioErr, ioOk;
    import sparkles.event_horizon.net : SimNet, ipv4, isNet;
    import sparkles.event_horizon.schedule : exponential, recurs, retry;
    import sparkles.event_horizon.scope_ : withScope;

    const wallStart = MonoTime.currTime;

    TestSched sched;
    alias W = TestSched.Waker;
    auto env = ctx(TestClock!W(sched.waker()), SimNet!W(sched.waker()));
    static assert(hasCaps!(typeof(env), "clock", "net"));
    static assert(isClock!(TestClock!W));
    static assert(isNet!(SimNet!W));

    const addr = ipv4("10.0.0.1", 443);
    size_t attempts;
    bool served, gotGreeting;

    sched.run(() @trusted {
        cast(void) withScope!((ref sc) {
            // The "server side comes up late" controller: at virtual
            // t=25ms a listener appears and serves one greeting.
            sc.spawnDaemon({
                cast(void) env.clock.sleep(25.msecs);
                auto l = env.net.listen(addr);
                assert(l.hasValue);
                auto conn = l.value.accept();
                assert(conn.hasValue);
                served = true;
                cast(void) conn.value.send(cast(const(ubyte)[]) "hi");
                conn.value.close();
            });

            // The client: connect with exponential backoff under virtual
            // time — attempts at t = 0, 10, 30 (the last one lands after
            // the server appears at t=25).
            auto outcome = retry(sc, env.clock,
                exponential(10.msecs) & recurs(5),
                delegate IoResult!uint() {
                    ++attempts;
                    auto conn = env.net.connect(addr);
                    if (conn.hasError)
                        return ioErr!uint(conn.error);
                    ubyte[8] buf;
                    auto got = conn.value.recv(buf[]);
                    assert(got.hasValue && got.value == 2);
                    gotGreeting = buf[0 .. 2] == cast(const(ubyte)[]) "hi";
                    conn.value.close();
                    return ioOk(got.value);
                });
            assert(!outcome.hasError, "the retry must eventually succeed");
            assert(outcome.value == 2);
        })(sched);
    });
    advanceAndSettle(sched, env.clock);

    assert(attempts == 3, "t=0 refused, t=10 refused, t=30 succeeds");
    assert(served && gotGreeting);
    assert(env.clock.now() - MonoTime.zero == 30.msecs,
        "virtual time advanced exactly through the backoff");
    assert(MonoTime.currTime - wallStart < 5.seconds,
        "no real sleeping happened");
    assert(sched.liveFibers == 0);
}

@("testing.gate.timeoutUnderVirtualTime")
@safe
unittest
{
    import core.time : msecs;

    import sparkles.event_horizon.clock : TestClock;
    import sparkles.event_horizon.errors : IoResult, ioOk;
    import sparkles.event_horizon.schedule : timeout;
    import sparkles.event_horizon.scope_ : withScope;

    TestSched sched;
    alias W = TestSched.Waker;
    auto clock = TestClock!W(sched.waker());

    bool sawTimeout;
    sched.run(() @trusted {
        cast(void) withScope!((ref sc) {
            auto slow = timeout(sc, clock, 50.msecs, delegate IoResult!int() {
                cast(void) clock.sleep(100.msecs); // far past the deadline
                return ioOk(1);
            });
            assert(slow.hasError);
            sawTimeout = slow.error.isTimeout;
        })(sched);
    });
    advanceAndSettle(sched, clock);
    assert(sawTimeout, "the deadline surfaces as Cause.interrupt(deadline)");
    assert(sched.liveFibers == 0);
}

@("testing.gate.raceFirstWinnerCancelsLosers")
@safe
unittest
{
    import core.time : msecs;

    import sparkles.event_horizon.clock : TestClock;
    import sparkles.event_horizon.errors : IoResult, ioOk;
    import sparkles.event_horizon.schedule : race;
    import sparkles.event_horizon.scope_ : withScope;

    TestSched sched;
    alias W = TestSched.Waker;
    auto clock = TestClock!W(sched.waker());

    int winner;
    sched.run(() @trusted {
        cast(void) withScope!((ref sc) {
            auto r = race(sc,
                delegate IoResult!int() {
                    cast(void) clock.sleep(30.msecs);
                    return ioOk(1);
                },
                delegate IoResult!int() {
                    cast(void) clock.sleep(10.msecs);
                    return ioOk(2);
                });
            assert(!r.hasError);
            winner = r.value;
        })(sched);
    });
    advanceAndSettle(sched, clock);
    assert(winner == 2, "the faster contender wins");
    assert(sched.liveFibers == 0);
}
