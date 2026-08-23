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
import core.thread.osthread : Thread;
import core.time : Duration, MonoTime;

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
    in (_armedDeadlines is null, "destroy with armed deadlines")
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

    // ── the deadline service (SPEC §8.3) ─────────────────────────────────
    // Deadlines are a scheduler service, not kernel ops: an armed node sits
    // on an intrusive list this scheduler owns, the tick clamps its wait to
    // the earliest expiry, and the sweep cancels expired subtrees between
    // dispatches. Nothing asynchronous ever holds the node's address —
    // disarming is a synchronous severance, so a disarmed node can never be
    // swept. (The kernel-timer design this replaces passed the frame-pinned
    // node as timer userdata; a queued expiry CQE could outlive the scope
    // frame and sweep freed stack. It also never disarmed at all on IOCP,
    // whose cancel lowering is a stub.) Works on every backend.

    /// Arms a one-shot deadline on `node`: expiry cancels its subtree with
    /// `InterruptKind.deadline` (SPEC §8.3). Infallible; undone by
    /// `disarmDeadline`. The node must stay address-stable while armed —
    /// `runScope` pins it on the scope frame and always disarms before the
    /// frame dies.
    void armDeadline(CancelContext* node, Duration timeout) @trusted nothrow @nogc
    in (!node.deadlineArmed, "node already carries a deadline")
    {
        const now = MonoTime.currTime;
        // Saturate: a huge finite timeout must never wrap past MonoTime's
        // range into the past and expire instantly (the Duration→tick
        // conversion itself can overflow, so gate on the coarse half-range
        // bound rather than on the wrapped sum).
        node.deadlineAt = timeout >= Duration.max / 2
            ? MonoTime.max
            : now + timeout;
        node.prevArmed = null;
        node.nextArmed = _armedDeadlines;
        if (_armedDeadlines !is null)
            _armedDeadlines.prevArmed = node;
        _armedDeadlines = node;
        node.deadlineArmed = true;
    }

    /// Disarms `node`'s deadline — synchronous unlink, idempotent; a no-op
    /// for a node that was never armed or was already swept.
    void disarmDeadline(CancelContext* node) @trusted nothrow @nogc
    {
        if (!node.deadlineArmed)
            return;
        if (node.prevArmed !is null)
            node.prevArmed.nextArmed = node.nextArmed;
        else
            _armedDeadlines = node.nextArmed;
        if (node.nextArmed !is null)
            node.nextArmed.prevArmed = node.prevArmed;
        node.prevArmed = node.nextArmed = null;
        node.deadlineArmed = false;
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
            if (_readyHead is null && _liveFibers > 0 && _loop.inFlight == 0
                && !_loop.wakerArmed && _armedDeadlines is null)
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

    Returns `dispatched` (fibers ran, completions arrived, or a deadline
    swept), `timedOut` (nothing within `timeout`; also when every fiber is
    parked with nothing in flight — only an external wake between ticks can
    help), or `drained` (no live fibers, no user ops). Must not be called
    from inside a fiber; `run()` and `tick()` do not interleave concurrently.

    Deadlines are a $(B scheduler) service (SPEC §8.3): an armed deadline
    does not make the ring readable, and only this tick (or `tickHosted`)
    sweeps expiries — an embedder must call the tick on its cadence rather
    than gate it on ring-fd readiness, or deadlines go unnoticed.
    */
    IoResult!RunStatus tick(Duration timeout = Duration.zero) @trusted
    in (_running is null, "tick from inside a fiber")
    {
        // Sweep before resuming, and again after every resume: a fiber that
        // overruns its deadline in CPU work and then yields is re-dequeued
        // within this same budget, so sweeping only at the edges of the
        // loop would let it finish (and disarm) unnoticed. The sweep costs
        // a null check while nothing is armed.
        cast(void) sweepDeadlines();

        uint ran;
        while (ran < _opts.resumeBudget)
        {
            auto t = dequeue();
            if (t is null)
                break;
            resume(t);
            ++ran;
            cast(void) sweepDeadlines();
        }
        if (ran > 0 || _readyHead !is null)
            return ioOk(RunStatus.dispatched);
        if (_liveFibers == 0 && _loop.inFlight == 0)
            return ioOk(RunStatus.drained);

        // Clamp the wait to the earliest armed deadline.
        Duration eff = timeout;
        const until = untilNextDeadline(MonoTime.currTime);
        if (until < eff)
            eff = until;

        // Parked fibers (or detached ops): wait. With an armed waker the
        // wait blocks even when no user op is in flight — the
        // park-until-external-wake pattern (SPEC §5.6). Without one,
        // runOnce reports drained instantly — so when a deadline is the
        // only thing pending, sleep it out here: with no ops, no waker,
        // and no ready fibers, nothing else can wake this thread.
        IoResult!RunStatus wait()
        {
            if (_loop.inFlight == 0 && !_loop.wakerArmed
                && until != Duration.max)
            {
                // Zero-time probe first so a requested stop() surfaces
                // before the sleep rather than after it.
                auto pre = _loop.runOnce(Duration.zero);
                if (pre.hasError || pre.value == RunStatus.stopped)
                    return pre;
                if (eff > Duration.zero)
                    (() @trusted => Thread.sleep(eff))();
                return ioOk(RunStatus.timedOut);
            }
            return _loop.runOnce(eff);
        }

        auto r = wait();
        if (r.hasError)
            return r;
        const swept = sweepDeadlines();
        // A wake completion is infrastructure — dispatch swallows it and
        // no fiber is enqueued. Resume the idle waiter so it can re-check
        // (pool steal, shutdown). Any other dispatched completion is also
        // a reason to look: a just-finished fiber may have submitted work.
        if (_idleWaiter !is null && r.hasValue
            && r.value == RunStatus.dispatched)
        {
            auto t = _idleWaiter;
            _idleWaiter = null;
            if (!t.enqueued)
                enqueue(t);
        }
        if (r.value == RunStatus.stopped)
            return r;
        if (swept || _readyHead !is null)
            return ioOk(RunStatus.dispatched);
        return ioOk(r.value == RunStatus.drained ? RunStatus.timedOut : r.value);
    }

    static if (__traits(hasMember, DefaultLoop, "runHostedOnce"))
    {
        /**
        Scheduler iteration using the native-host wait bridge.

        Ready fibers retain the same budget and FIFO discipline as `tick`.
        Only the final wait changes: Event Horizon combines its completion
        signal with the host's native source through `runHostedOnce`.
        */
        IoResult!RunStatus tickHosted(Host)(ref Host host,
            Duration timeout = Duration.zero) @trusted
        in (_running is null, "tickHosted from inside a fiber")
        {
            cast(void) sweepDeadlines(); // see tick()

            uint ran;
            while (ran < _opts.resumeBudget)
            {
                auto t = dequeue();
                if (t is null)
                    break;
                resume(t);
                ++ran;
                cast(void) sweepDeadlines();
            }
            if (ran > 0 || _readyHead !is null)
                return ioOk(RunStatus.dispatched);
            if (_liveFibers == 0 && _loop.inFlight == 0)
                return ioOk(RunStatus.drained);

            // Clamp to the earliest armed deadline; the hosted wait always
            // blocks on the host source, so no sleep arm is needed here.
            Duration eff = timeout;
            const until = untilNextDeadline(MonoTime.currTime);
            if (until < eff)
                eff = until;

            auto r = _loop.runHostedOnce(host, eff);
            if (r.hasError)
                return r;
            const swept = sweepDeadlines();
            if (_idleWaiter !is null && r.value == RunStatus.dispatched)
            {
                auto t = _idleWaiter;
                _idleWaiter = null;
                if (!t.enqueued)
                    enqueue(t);
            }
            if (swept && r.value != RunStatus.stopped)
                return ioOk(RunStatus.dispatched);
            return r;
        }
    }

    /**
    Parks the current fiber until the loop makes progress — a wake
    completion, or any other CQE `tick` then treats as a reason to
    resume. Used by the pool's idle path (O2/O29): no timer, no payload.
    The loop's waker must be armed (`waker()`) or `run()` reports
    deadlock.
    */
    void parkUntilWake() @trusted nothrow
    {
        auto task = _running;
        assert(task !is null, "parkUntilWake outside a scheduler fiber");
        task.wakeKind = WakeKind.manual;
        _idleWaiter = task;
        park();
        if (_idleWaiter is task)
            _idleWaiter = null;
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

    /// Sweeps expired deadlines: unlink first (one-shot), then cancel the
    /// subtree. Runs only between dispatches on the owning thread — never
    /// concurrently with fiber code — so every armed node is alive (its
    /// scope frame cannot exit without `disarmDeadline`).
    bool sweepDeadlines() @trusted nothrow @nogc
    {
        if (_armedDeadlines is null)
            return false;
        const now = MonoTime.currTime;
        bool swept;
        auto n = _armedDeadlines;
        while (n !is null)
        {
            auto next = n.nextArmed;
            if (n.deadlineAt <= now)
            {
                disarmDeadline(n);
                cancelTree(n, Interrupt(InterruptKind.deadline));
                swept = true;
            }
            n = next;
        }
        return swept;
    }

    /// The earliest armed expiry, as a wait bound relative to `now`;
    /// `Duration.max` when nothing (relevant) is armed. Already-cancelling
    /// nodes are skipped — their sweep would no-op, so waking early for
    /// them buys nothing.
    Duration untilNextDeadline(MonoTime now) const @safe nothrow @nogc
    {
        Duration best = Duration.max;
        for (const(CancelContext)* n = _armedDeadlines; n !is null; n = n.nextArmed)
        {
            if (n.state != CancelContext.State.on)
                continue;
            const until = n.deadlineAt <= now ? Duration.zero : n.deadlineAt - now;
            if (until < best)
                best = until;
        }
        return best;
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
    FiberTask _idleWaiter; /// parked on `parkUntilWake`; resumed from `tick`
    uint _liveFibers;
    /// Armed deadline scopes (intrusive, unsorted — a handful at most, so
    /// the O(n) sweep/min beats heap bookkeeping; see SPEC §8.3).
    CancelContext* _armedDeadlines;
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

@("sched.deadline.disarmIsSynchronousSeverance")
@safe
unittest
{
    import core.time : msecs;

    Sched s;
    schedOrSkip(s);

    // The crash shape of the retired kernel-timer design: a deadline that
    // has ALREADY expired when the disarm runs. The fire-and-forget cancel
    // lost that race — the queued expiry CQE was delivered after the scope
    // frame died and swept freed stack. Disarm is now a synchronous
    // severance: once it returns, no sweep can observe the node, however
    // late the disarm was.
    // (`@trusted` address-taking: the node provably outlives every armed
    // interval in this frame — the same pinning contract runScope keeps.)
    CancelContext node;
    (() @trusted => s.armDeadline(&node, 1.msecs))();
    (() @trusted { Thread.sleep(5.msecs); })(); // expire without a sweep
    (() @trusted => s.disarmDeadline(&node))();

    cast(void) s.tick(Duration.zero);
    assert(node.state == CancelContext.State.on,
        "a disarmed node is never swept, even after its expiry passed");
    assert(!node.deadlineArmed);

    // Idempotent, and re-arming after a disarm works.
    (() @trusted => s.disarmDeadline(&node))();
    (() @trusted => s.armDeadline(&node, 1.msecs))();
    (() @trusted => s.disarmDeadline(&node))();
}

@("sched.capability.deadlineServiceProbe")
@safe pure nothrow @nogc
unittest
{
    import sparkles.event_horizon.capability : hasDeadlineTimer, isFiberExecutor;

    static assert(isFiberExecutor!Sched);
    // The DbI probe must match armDeadline/disarmDeadline's exact shape — a
    // mismatch silently un-instantiates withDeadline for every consumer.
    static assert(hasDeadlineTimer!Sched);
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
