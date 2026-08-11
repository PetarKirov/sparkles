/**
Tier B — the fiber scheduler over the callback core (SPEC §7): direct-style,
blocking-looking code with no function coloring. An I/O verb submits through
tier A with the current fiber as the completion target and parks; the
completion callback fills the fiber's mailbox and enqueues it; the tick
resumes it where it yielded.

One `Sched` per thread, never `shared` — the `SINGLE_ISSUER` discipline
extends to all scheduler state. Fibers are pooled in a fixed slab built at
creation (`Fiber.reset` recycling): steady-state `spawn` performs no
allocation.
*/
module sparkles.event_horizon.sched;

version (Posix) version = EhSchedStack;
version (Windows) version = EhSchedStack;
version (EhSchedStack)  :  // rides DefaultLoop; peer backends via backend.select

import core.lifetime : move;
import core.stdc.errno : EAGAIN, ENOBUFS;
import core.thread.fiber : Fiber;
import core.time : Duration;

import sparkles.event_horizon.buffer : Buf;
import sparkles.event_horizon.capability : SpawnOptions;
import sparkles.event_horizon.cause : CancelContext, FiberContext, Interrupt,
    InterruptKind, cancelTree, interruptRequested;
import sparkles.event_horizon.errors;
import sparkles.event_horizon.loop : DefaultLoop, LoopConfig, RunStatus;
import sparkles.event_horizon.op;

/// Why a parked fiber was woken — exactly one wake per park (the one-shot
/// discipline every surveyed runtime uses).
enum WakeKind : ubyte
{
    cqe,    /// terminal completion of the awaited op; the mailbox is valid
    manual, /// `yieldNow` / a future scope join (M5)
}

/**
A pooled fiber task (the `std.concurrency.Generator` pattern): subclassing
`Fiber` makes the current task one downcast of `Fiber.getThis`, and pooling
is `Fiber.reset` on a terminated instance.
*/
package final class FiberTask : Fiber
{
package:
    Sched* owner;        /// the scheduler this fiber is pinned to
    FiberTask nextReady; /// intrusive ready-queue link
    FiberTask nextFree;  /// intrusive free-list link
    FiberContext ectx;   /// the effects-visible slice (SPEC §8)
    bool enqueued;       /// ready-queue membership (dedupes multiple wakes)
    OpToken awaitToken;  /// the op this fiber is parked on (cancel target)
    Throwable pendingDefect; /// escaped Throwable with no scope to route to

    // The park/wake mailbox: written by the completion trampoline, read
    // after `park()` returns.
    WakeKind wakeKind;
    int wakeRes;
    CompletionFlags wakeFlags;
    Buf wakeBuf;
    SockAddr wakePeer;
    ushort wakeBufferId;

    this(size_t stackSize, size_t guardPageSize) nothrow
    {
        super(&shell, stackSize, guardPageSize);
    }

    /// Rebinds a recycled (never-started or terminated) fiber to a new body.
    void rebind(void delegate() body_) nothrow
    {
        _body = body_;
        ectx = FiberContext.init;
        ectx.taskBacklink = (() @trusted => cast(void*) this)();
        awaitToken = OpToken.init;
        pendingDefect = null;
        reset();
    }

private:
    void delegate() _body;

    /// The fiber shell (SPEC §8.6): runs the body, catches an escaping
    /// `Throwable` as a defect, and hands both to the scope's exit hook.
    void shell()
    {
        Throwable defect;
        try
        {
            if (_body !is null)
                _body();
        }
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
            pendingDefect = defect; // no scope: `resume` rethrows it
    }
}

/// Scheduler tuning knobs (SPEC §7.2).
struct SchedOptions
{
    size_t stackSize = 64 * 1024;  /// per-fiber stack (open-issues O4)
    size_t guardPageSize = 4096;   /// guard page below each stack
    uint maxFibers = 256;          /// task-slab size; `spawn` fails past it
    uint resumeBudget = 64;        /// fibers run per tick before re-draining
}

/// What an awaited op's terminal completion delivered (the mailbox,
/// flattened). `res` is the raw `>= 0` payload or `-errno`; submit-time
/// failures are folded in as negative errno too.
package struct AwaitOutcome
{
    int res;
    CompletionFlags flags;
    Buf buf;
    SockAddr peer;
    ushort bufferId;
}

/**
The per-thread fiber scheduler (SPEC §7.2). Owns its tier-A loop; the FIFO
ready queue is intrusive (no allocation); completion callbacks enqueue,
never resume inline.
*/
struct Sched
{
    @disable this(this);

    /// Builds the loop and pre-allocates the fiber slab (the only
    /// GC-allocating phase; steady-state operation is allocation-free).
    static IoResult!void create(out Sched s, in SchedOptions opts = SchedOptions(),
        in LoopConfig loopCfg = LoopConfig()) @trusted nothrow
    {
        // @trusted: `&s` is stored as the fibers' owner pointer — the Sched
        // must stay at this address for its lifetime (non-copyable; do not
        // move it after create).
        auto looped = DefaultLoop.create(s._loop, loopCfg);
        if (looped.hasError)
            return looped;

        s._opts = opts;
        foreach (_; 0 .. opts.maxFibers)
        {
            auto t = new FiberTask(opts.stackSize, opts.guardPageSize);
            t.owner = &s;
            t.nextFree = s._freeHead;
            s._freeHead = t;
        }
        return ioOk();
    }

    /// Tears down the loop; every fiber must have finished.
    void destroy() @safe nothrow @nogc
    in (_liveFibers == 0, "destroy with live fibers")
    {
        _loop.destroy();
    }

    ~this() @safe nothrow @nogc
    {
        destroy();
    }

    /// Tier-A access (buffer pools, capability probing, raw submits).
    ref DefaultLoop loop() return @safe pure nothrow @nogc => _loop;

    /**
    Spawns a fiber running `body_`, bound to this scheduler.

    `body_` is an ordinary delegate — NOT `scope`: it runs after this call
    returns, so a capturing closure's frame must be heap-allocated (the
    compiler does this automatically). ASan-verified: a `scope` parameter
    here lets the closure frame stay on a stack that dies before the child
    runs. Allocation-free spawns pass a non-capturing delegate (a member
    delegate like `JoinHandle.runShell`, or a function pointer).
    */
    IoResult!void spawn(void delegate() body_) @trusted nothrow
    {
        return spawnFiber(null, SpawnOptions.init, body_) is null
            ? ioErr!void(ENOBUFS, OpKind.none, IoErrorStage.submit,
                "fiber slab exhausted")
            : ioOk();
    }

    // ── the fiber-executor concept (drives scope_.Scope; SPEC §10.3) ─────

    /// The running fiber's effects-visible context.
    FiberContext* currentContext() @safe nothrow @nogc
    in (_running !is null, "not on a scheduler fiber")
        => &_running.ectx;

    /// Spawns a child bound to `node` (may be null for an unscoped fiber —
    /// `run`'s root); enqueued, never run inline; `null` = slab exhausted.
    FiberContext* spawnFiber(scope CancelContext* node, in SpawnOptions opts,
        void delegate() body_) @trusted nothrow
    {
        auto t = _freeHead;
        if (t is null)
            return null;
        _freeHead = t.nextFree;
        t.nextFree = null;
        t.rebind(body_);
        t.ectx.daemon = opts.daemon;
        if (node !is null)
            node.addFiber(&t.ectx);
        ++_liveFibers;
        enqueue(t);
        return &t.ectx;
    }

    /// Suspends the current fiber until exactly one `wake`.
    void park() @trusted nothrow @nogc
    in (_running !is null, "park outside a scheduler fiber")
    {
        Fiber.yield();
    }

    /// Makes a parked fiber runnable (same-thread; cross-worker wakes are
    /// an M9 concern).
    void wake(FiberContext* f) @trusted nothrow @nogc
    {
        auto task = cast(FiberTask) f.taskBacklink;
        task.wakeKind = WakeKind.manual;
        enqueue(task);
    }

    // Deadlines need the loop's timer, which exists only when the backend
    // lowers OpTimeout (io_uring/kqueue; not the current IOCP data path). On
    // a timer-less backend, withDeadline/timeout are simply unavailable.
    static if (__traits(hasMember, DefaultLoop, "submitAfter"))
    {
        /// Arms a one-shot deadline: expiry cancels `node`'s subtree with
        /// `InterruptKind.deadline` (SPEC §8.3). The token disarms it.
        ulong armDeadline(CancelContext* node, Duration timeout) @trusted nothrow
        {
            auto h = _loop.submitAfter(timeout, &onDeadline, cast(void*) node);
            return h.hasError ? 0 : h.value.token.raw;
        }

        /// Disarms a deadline; a no-op for an already-fired or invalid token.
        void disarmDeadline(ulong token) @safe nothrow
        {
            if (token == 0)
                return;
            OpHandle h = {token: OpToken(token)};
            cast(void) _loop.cancel(h);
        }
    }

    /// Fibers spawned and not yet finished.
    uint liveFibers() const @safe pure nothrow @nogc => _liveFibers;

    /// The fiber-slab capacity (`spawn` fails past it).
    uint maxFibers() const @safe pure nothrow @nogc => _opts.maxFibers;

    /**
    Runs `root` as a fiber and drives the loop until every fiber has
    finished and no op is in flight. A `Throwable` escaping a fiber body is
    rethrown here (M5 maps it to `Cause.die` instead).
    */
    IoResult!void run(scope void delegate() root) @trusted
    {
        auto spawned = spawn(root);
        if (spawned.hasError)
            return spawned;

        while (_liveFibers > 0 || _loop.inFlight > 0)
        {
            if (_readyHead is null && _liveFibers > 0 && _loop.inFlight == 0)
                assert(0, "deadlock: parked fibers with nothing in flight");
            auto r = tick(Duration.max);
            if (r.hasError)
                return ioErr!void(r.error);
        }
        return ioOk();
    }

    /**
    One scheduler iteration — the embedding hatch (SPEC §7.2) for a host
    that must interleave this scheduler with a loop it does not own: run
    ready fibers (up to `resumeBudget`), then — if none became ready and
    ops are in flight — one `runOnce(timeout)`.

    Returns `dispatched` (fibers ran or completions arrived), `timedOut`
    (nothing within `timeout`; also when every fiber is parked with nothing
    in flight — only an external wake between ticks can help), or `drained`
    (no live fibers, no user ops). Must not be called from inside a fiber;
    `run()` and `tick()` do not interleave concurrently.
    */
    IoResult!RunStatus tick(Duration timeout = Duration.zero) @trusted
    in (_running is null, "tick from inside a fiber")
    {
        uint ran;
        while (ran < _opts.resumeBudget)
        {
            auto t = dequeue();
            if (t is null)
                break;
            resume(t);
            ++ran;
        }
        if (ran > 0 || _readyHead !is null)
            return ioOk(RunStatus.dispatched);
        if (_liveFibers == 0 && _loop.inFlight == 0)
            return ioOk(RunStatus.drained);
        // Parked fibers (or detached ops): wait. With an armed waker the
        // wait blocks even when no user op is in flight — the
        // park-until-external-wake pattern (SPEC §5.6). Without one,
        // runOnce reports drained instantly; surface that as timedOut
        // (only an external wake between ticks can make progress).
        auto r = _loop.runOnce(timeout);
        if (r.hasError)
            return r;
        return ioOk(r.value == RunStatus.drained ? RunStatus.timedOut : r.value);
    }

    /**
    The await seam (SPEC §7.3): submit through tier A with the current
    fiber as the completion target, park, and hand back the mailbox.
    Must be called from a fiber of this scheduler.
    */
    package AwaitOutcome await(Op)(Op op)
    {
        import core.stdc.errno : ECANCELED;

        auto task = _running;
        assert(task !is null, "await outside a scheduler fiber");

        // Checkpoint (SPEC §7.3 step 1): a cancelled scope does no new work.
        if (interruptRequested(task.ectx))
            return AwaitOutcome(-ECANCELED);

        auto submitted = _loop.submit(move(op), &onCqe, cast(void*) task);
        if (submitted.hasError)
            return AwaitOutcome(-submitted.error.errnoValue);

        // Arm the one-shot in-flight cancel function (SPEC §8.4): it submits
        // ASYNC_CANCEL for this op; the single wake stays the terminal CQE.
        task.awaitToken = submitted.value.token;
        task.ectx.cancelFn = &cancelInFlight;
        task.ectx.cancelCtx = cast(void*) task;

        park();
        assert(task.wakeKind == WakeKind.cqe);
        task.ectx.cancelFn = null; // completion won: disarm
        task.ectx.cancelCtx = null;
        task.awaitToken = OpToken.init;
        return AwaitOutcome(task.wakeRes, task.wakeFlags,
            move(task.wakeBuf), task.wakePeer, task.wakeBufferId);
    }

    /// Cooperative reschedule: requeue the current fiber and yield the CPU.
    void yieldNow() @trusted nothrow
    {
        auto task = _running;
        assert(task !is null, "yieldNow outside a scheduler fiber");
        task.wakeKind = WakeKind.manual;
        enqueue(task);
        park();
    }

    /// The running task, or `null` off-fiber.
    package static FiberTask tryCurrent() @trusted nothrow @nogc
        => cast(FiberTask) Fiber.getThis();

private:
    /// The tier-A completion trampoline: mailbox fill + enqueue — never an
    /// inline resume (the tick owns resumption).
    static void onCqe(void* p, ref Completion done) nothrow @nogc
    {
        auto task = (() @trusted => cast(FiberTask) p)();
        task.wakeKind = WakeKind.cqe;
        task.wakeRes = done.res;
        task.wakeFlags = done.flags;
        task.wakeBuf = move(done.buf);
        task.wakePeer = done.peer;
        task.wakeBufferId = done.bufferId;
        task.owner.enqueue(task);
    }

    /// The one-shot in-flight cancel function (SPEC §8.5): submit
    /// `ASYNC_CANCEL` for the awaited op — do NOT wake the fiber; the wake
    /// is always the terminal CQE (`-ECANCELED`, or the real result if
    /// completion won the race).
    static void cancelInFlight(void* p, Interrupt) nothrow @nogc
    {
        auto task = (() @trusted => cast(FiberTask) p)();
        OpHandle h = {token: task.awaitToken};
        if (h)
        {
            auto r = task.owner._loop.cancel(h);
        }
    }

    /// The deadline-timer callback: expiry sweeps the node's subtree.
    static void onDeadline(void* p, ref Completion done) nothrow @nogc
    {
        if (done.res != 0)
            return; // the deadline was disarmed (-ECANCELED): no sweep
        auto node = (() @trusted => cast(CancelContext*) p)();
        cancelTree(node, Interrupt(InterruptKind.deadline));
    }

    void enqueue(FiberTask t) @safe nothrow @nogc
    {
        if (t.enqueued)
            return; // several children may wake one joiner
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

    FiberTask dequeue() @safe nothrow @nogc
    {
        auto t = _readyHead;
        if (t is null)
            return null;
        _readyHead = t.nextReady;
        if (_readyHead is null)
            _readyTail = null;
        t.nextReady = null;
        t.enqueued = false;
        return t;
    }

    void resume(FiberTask t) @system
    {
        _running = t;
        auto thrown = t.call(Fiber.Rethrow.no);
        _running = null;
        assert(thrown is null, "the fiber shell catches all Throwables");
        if (t.state == Fiber.State.TERM)
        {
            --_liveFibers;
            t._body = null;
            auto defect = t.pendingDefect;
            t.pendingDefect = null;
            t.nextFree = _freeHead;
            _freeHead = t;
            if (defect !is null)
                throw defect; // a scope-less fiber's defect surfaces here
        }
    }

    DefaultLoop _loop;
    SchedOptions _opts;
    FiberTask _freeHead;
    FiberTask _readyHead, _readyTail;
    FiberTask _running;
    uint _liveFibers;
}

/**
Whether the caller is running on a scheduler fiber.

The question $(LREF currentScheduler) cannot answer, and the reason it does
not have to: a caller deciding between a parked path and a polled one asks
this, and "there is no loop here" is a routine answer rather than a defect.
*/
bool onScheduler() @safe nothrow @nogc => Sched.tryCurrent() !is null;

/**
The scheduler driving the calling fiber.

The tier-B verbs already work this way — `read`, `write`, `accept` take no
scheduler because a fiber knows which loop resumed it. This exposes the same
answer to code that has to name one: `waitReadable`, `capture`, anything
taking `ref Sched`.

$(B It exists because a daemon body cannot be handed a scheduler.) An
application parks background work through its host's `spawnDaemon`, which
takes a plain `void delegate()` — the host deliberately does not publish the
loop, since two of the three targets have none. A fiber that needs the
scheduler therefore has to ask at the top, and this is the ask.

$(B By `ref`, never by pointer.) Every consumer wants `ref Sched`, so handing
back a pointer would make each of them dereference one — and a dereference in
`@safe` code is not free, it is a `@trusted` escape hatch per call site. A
`ref` return plus a `ref` local (`ref Sched s = currentScheduler();`) keeps
the whole chain `@safe`. The nullability that a pointer also carried moves to
$(LREF onScheduler), where it reads as the question it always was.
*/
ref Sched currentScheduler() @trusted nothrow @nogc
in (onScheduler, "currentScheduler is only callable on a scheduler fiber")
    // @trusted: `owner` is the address stored by `run` for the fiber that is
    // executing right now, so it is non-null and its `Sched` outlives this
    // call — `run` blocks on that frame until every fiber it spawned is done.
    => *Sched.tryCurrent().owner;

@("sched.currentScheduler.isTheLoopThatResumedYou")
@safe
unittest
{
    // Off a fiber there is no loop, and that is a question rather than a
    // defect: a component asking is usually choosing between a parked path
    // and a polled one, and the polled one is a legitimate outcome.
    assert(!onScheduler, "no fiber, no loop");

    Sched s;
    schedOrSkip(s);

    bool rootIsSelf, childIsSelf;
    auto r = s.run(() {
        // `ref` locals, not pointers (2.111): the identity check below is the
        // whole assertion, and comparing the addresses of two `ref`s is
        // `@safe` under dip1000 — where dereferencing a returned pointer to
        // make the same comparison would have needed `@trusted`.
        ref Sched mine = currentScheduler();
        rootIsSelf = &mine is &s;

        // A spawned daemon is the case this exists for: its body is a plain
        // delegate, handed no scheduler by whoever parked it.
        assert(!s.spawn(() {
            ref Sched theirs = currentScheduler();
            childIsSelf = &theirs is &s;
        }).hasError);
    });
    assert(!r.hasError);

    assert(rootIsSelf, "the root fiber's loop is the one it runs on");
    assert(childIsSelf, "and so is a fiber spawned from it");
    assert(!onScheduler, "the run is over");
}

@("sched.spawn.runsToCompletion")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    int order;
    int rootSaw, childSaw;
    auto r = s.run(() {
        rootSaw = ++order;
        assert(!s.spawn(() { childSaw = ++order; }).hasError);
    });
    assert(!r.hasError);
    assert(rootSaw == 1 && childSaw == 2);
    assert(s.liveFibers == 0);
}

@("sched.yieldNow.interleaves")
@safe
unittest
{
    Sched s;
    schedOrSkip(s);

    int[6] log;
    size_t i;
    auto r = s.run(() @trusted {
        cast(void) s.spawn(() {
            log[i++] = 1;
            s.yieldNow();
            log[i++] = 1;
        });
        log[i++] = 0;
        s.yieldNow();
        log[i++] = 0;
        s.yieldNow();
    });
    assert(!r.hasError);
    assert(i == 4);
    assert(log[0] == 0 && log[1] == 1 && log[2] == 0 && log[3] == 1,
        "FIFO ready queue must interleave the two fibers");
}

@("sched.slab.recyclesFibers")
@safe
unittest
{
    Sched s;
    SchedOptions opts;
    opts.maxFibers = 2;
    schedOrSkip(s, opts);

    // Far more sequential spawns than slots: recycling must cover it.
    int completed;
    auto r = s.run(() {
        foreach (_; 0 .. 16)
        {
            assert(!s.spawn(() { ++completed; }).hasError);
            s.yieldNow(); // let the child run and recycle
        }
    });
    assert(!r.hasError);
    assert(completed == 16);
}

@("sched.tick.embedsInAForeignLoop")
@safe
unittest
{
    import core.time : Duration, msecs;

    import sparkles.event_horizon.op : KernelTimespec, OpTimeout;

    Sched s;
    schedOrSkip(s);

    // The O7 embedding shape: a host loop the scheduler does not own calls
    // tick() per iteration — here until the workload drains.
    bool slept;
    assert(!s.spawn(() {
        auto o = s.await(OpTimeout(KernelTimespec(0, 5_000_000)));
        assert(o.res == 0);
        slept = true;
    }).hasError);

    uint iterations;
    for (;;)
    {
        auto r = s.tick(10.msecs);
        assert(r.hasValue);
        ++iterations;
        if (r.value == RunStatus.drained)
            break;
        assert(iterations < 1000, "tick must converge");
    }
    assert(slept, "the fiber ran to completion under tick-driven pacing");
    assert(s.liveFibers == 0);
}

@("sched.await.timerParksAndResumes")
@safe
unittest
{
    import core.time : msecs;

    Sched s;
    schedOrSkip(s);

    bool fired;
    const before = MonoTimeStamp();
    auto r = s.run(() {
        auto o = s.await(OpTimeout(KernelTimespec(0, 5_000_000)));
        assert(o.res == 0, "timer expiry is success");
        fired = true;
    });
    assert(!r.hasError);
    assert(fired);
    assert(MonoTimeStamp() - before >= 5.msecs);
}

// NB the gate below is `unittest`, not `linux`: `Sched` rides whichever backend
// `backend.select` picks (io_uring on Linux, kqueue on the BSDs/macOS), so
// gating this helper to Linux while leaving its callers ungated made a module
// fail to compile off Linux with `undefined identifier Sched` — a break that
// stayed latent until macOS CI first ran on this branch. The tests that use it
// are not Linux-specific; `schedOrSkip` is what makes them portable.
version (unittest)
{
    import core.time : MonoTime;

    import sparkles.event_horizon.errors : skipReason;
    import sparkles.test_runner.skip : skipTest;

    private MonoTime MonoTimeStamp() @safe nothrow @nogc
        => MonoTime.currTime;

    /**
    Creates a `Sched` for a test, or SKIPs the test: on a host whose backend
    cannot be created — container/seccomp, `kernel.io_uring_disabled`, a
    pre-6.1 kernel — SPEC §3.4 makes that a hard error with no fallback, and
    the test is recorded SKIPPED rather than silently green.

    Does not return on the skip path, which constrains where it may be called:
    $(UL
    $(LI before arming any `scope (exit)` — an `Error` unwinding out of a
        `nothrow` frame is not guaranteed to run cleanup handlers;)
    $(LI never from inside a fiber body or a `run` callback — `FiberTask.shell`
        catches every `Throwable`, so under a scope the skip is folded into a
        `die` cause and resurfaces as a *failure* on the next outcome assert.))
    */
    package void schedOrSkip(ref Sched s, in SchedOptions opts = SchedOptions(),
        in LoopConfig loopCfg = LoopConfig()) @trusted nothrow
    {
        auto created = Sched.create(s, opts, loopCfg);
        if (created.hasError)
            skipTest(skipReason(created.error));
    }
}
