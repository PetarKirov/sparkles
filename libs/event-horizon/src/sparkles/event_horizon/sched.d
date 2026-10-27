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

import core.atomic : atomicLoad, atomicStore, cas, MemoryOrder;
import core.lifetime : move;
import core.stdc.errno : EAGAIN, EINVAL, ENOBUFS, ETIMEDOUT;
// druntime declares ENOTRECOVERABLE only where its C runtime does; macOS's
// and FreeBSD's <sys/errno.h> have it too.
version (OSX) private enum ENOTRECOVERABLE = 104;
else version (FreeBSD) private enum ENOTRECOVERABLE = 95;
else import core.stdc.errno : ENOTRECOVERABLE;
import core.thread.fiber : Fiber;
import core.thread.osthread : Thread;
import core.time : Duration, MonoTime;

import sparkles.base.sync.parker : installParker, pins;
import sparkles.base.sync.parking_lot : callerRegistered;

import sparkles.event_horizon.backend.concept : canSubmitOp, Waker;
import sparkles.event_horizon.backend.select : DefaultBackend;
import sparkles.event_horizon.buffer : Buf;
import sparkles.event_horizon.capability : SpawnOptions;
import sparkles.event_horizon.cause : CancelContext, FiberContext, Interrupt,
    InterruptKind, cancelTree, interruptFiber, interruptRequested;
import sparkles.event_horizon.errors;
import sparkles.event_horizon.fiber_park : FiberParkState, fiberParker, resumeIfAsleep,
    writeRingSleep;
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
    uint slabIndex;      /// this task's index in its scheduler's slab
    /// The fiber parker's per-task state: the park word, the record and
    /// the wake-inbox link (fiber-parker.md EFP2).
    FiberParkState park;

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
        // After the body returns its frame is dead — this call reuses that
        // stack. A context a worker still holds must not live there (EFP2).
        assert(defect !is null || !callerRegistered(),
            "a fiber ended holding a parking-lot registration (EFP2)");

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
    /// How a fiber waiting on a `sparkles.base.sync` primitive parks
    /// (fiber-parker.md EFP6).
    FiberPark fiberPark = FiberPark.auto_;
}

/**
How a fiber parks on a `sparkles.base.sync` primitive (fiber-parker.md EFP6):
in the kernel through io_uring's futex operations, or in its scheduler with
wakes through an inbox.
*/
enum FiberPark : ubyte
{
    /// The ring path where the backend has the futex operations and §7's
    /// recorded decision chooses it; until FB1–FB7 are recorded, wherever
    /// it is supported.
    auto_,
    ring,  /// the ring path wherever the backend has the futex operations
    inbox, /// the inbox path on every backend
}

/// Whether the default backend can lower the ring path's operations at all.
private enum bool ringParkLowerable = canSubmitOp!(DefaultBackend, OpFutexWait);

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
        // The ring path holds one op slot per task for its park, beyond the
        // caller's budget, and needs room for a wait and its linked timeout
        // (fiber-parker.md EFP22).
        const mayRing = ringParkLowerable && opts.fiberPark != FiberPark.inbox;
        if (opts.fiberPark == FiberPark.ring && loopCfg.backend.sqEntries < 2)
            return ioErr!void(EINVAL, OpKind.none, IoErrorStage.setup,
                "the ring path needs two submission entries");
        LoopConfig cfg = loopCfg;
        if (mayRing)
            cfg.heldSlots += opts.maxFibers;
        auto looped = DefaultLoop.create(s._loop, cfg);
        if (looped.hasError)
            return looped;
        s._ringPark = mayRing && s._loop.caps().futexOps;

        s._opts = opts;
        s._tasks = new FiberTask[opts.maxFibers];
        foreach_reverse (i; 0 .. opts.maxFibers)
        {
            auto t = new FiberTask(opts.stackSize, opts.guardPageSize);
            t.owner = &s;
            t.slabIndex = i;
            s._tasks[i] = t;
            t.nextFree = s._freeHead;
            s._freeHead = t;
        }
        // A fiber parked on a `sparkles.base.sync` primitive may be woken
        // from any thread, so the wake routing is armed before any fiber
        // can park (fiber-parker.md EFP22).
        auto w = s._loop.waker();
        if (w.hasError)
        {
            s._loop.destroy();
            return ioErr!void(w.error);
        }
        s._waker = w.value;
        return ioOk();
    }

    /// Tears down the loop; every fiber must have finished.
    void destroy() @safe nothrow @nogc
    in (_liveFibers == 0, "destroy with live fibers")
    in (_armedDeadlines is null, "destroy with armed deadlines")
    in (_armedAlarms is null, "destroy with armed alarms")
    {
        awaitDeliveries();
        // With no fiber left, an entry still in the wake inbox is stale
        // (EFP13): draining it resumes nothing.
        cast(void) drainWakeInbox();
        _loop.destroy();
        _destroyed = true;
    }

    ~this() @safe nothrow @nogc
    {
        if (_destroyed || _leaked)
            return;
        if (_liveFibers == 0)
            destroy();
        else
            abandon();
    }

    /**
    Gives up a run a defect ended early, with fibers still live (SPEC §11,
    fiber-parker.md EFP21). An op of theirs may still name the slab or a
    fiber's frame, so the loop and every task are leaked, not freed. Failing
    `destroy`'s contract instead, while the defect unwinds, would rethrow the
    one thread-local `AssertError` druntime keeps and overwrite that defect.

    A fiber parked on a `sparkles.base.sync` primitive is beyond a leak: its
    parking-lot record, and every later wake of it, name this scheduler,
    whose own storage ends here. The process then ends through the loop's
    fatal hook, after reporting the defect.
    */
    private void abandon() @trusted nothrow @nogc
    {
        import core.memory : GC;

        awaitDeliveries();
        if (_lotSleepers > 0)
        {
            reportAbandonment();
            _loop.fatal(ioError(ENOTRECOVERABLE, OpKind.none, IoErrorStage.completion,
                "a defect ended the run with fibers parked on sparkles.base.sync primitives"));
        }
        GC.addRoot(cast(void*) _tasks.ptr);
        _loop.abandon();
    }

    /// Writes the defect that ended the run, and what it stranded, to
    /// standard error.
    private void reportAbandonment() @trusted nothrow @nogc
    {
        import core.stdc.stdio : fprintf, stderr;

        fprintf(stderr, "event-horizon: a defect ended Sched.run with %u fiber(s) "
            ~ "parked on sparkles.base.sync primitives, whose records and wakes "
            ~ "would outlive the scheduler (fiber-parker.md EFP21)\n", _lotSleepers);
        if (_abortedBy !is null)
            fprintf(stderr, "event-horizon: the defect: %.*s at %.*s:%zu\n",
                cast(int) _abortedBy.msg.length, _abortedBy.msg.ptr,
                cast(int) _abortedBy.file.length, _abortedBy.file.ptr, _abortedBy.line);
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
    in (pins() == 0, "a fiber suspended while holding a non-interruptible lock (SYK9)")
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

    // ── the wake-only alarm service (SPEC §7.2) ──────────────────────────
    // A deadline (above) is a CANCELLATION mechanism: expiry runs
    // `cancelTree`, latches `InterruptKind.deadline`, and leaves the node
    // non-`on`, so it can neither wake a fiber without interrupting it nor
    // be re-armed for repeated cycles. An alarm is the other thing a parked
    // fiber sometimes needs — "resume me at T, nothing else" — ring-free,
    // reusable, and never a latch: expiry unlinks the entry, marks it fired,
    // and wakes the waiter; an outer cancellation latch is untouched and
    // keeps its precedence. The supervised-run backoff loops ride this.

    /**
    Arms `alarm` to wake the calling fiber after `after`. Infallible
    (intrusive, unsorted list — a handful at most, like deadlines). The
    entry must stay address-stable while armed; use an unconditional
    `scope (exit) disarmAlarm(alarm)` so no early exit leaves a recycled
    fiber pointer on the list.
    */
    void armAlarm(ref Alarm alarm, Duration after) @trusted nothrow @nogc
    in (!alarm._armed, "alarm already armed")
    in (_running !is null, "armAlarm outside a scheduler fiber")
    {
        const now = MonoTime.currTime;
        alarm._at = after >= Duration.max / 2 ? MonoTime.max : now + after;
        alarm._waiter = &_running.ectx;
        alarm._owner = &this;
        alarm._fired = false;
        alarm._prev = null;
        alarm._next = _armedAlarms;
        if (_armedAlarms !is null)
            _armedAlarms._prev = &alarm;
        _armedAlarms = &alarm;
        alarm._armed = true;
    }

    /// Disarms `alarm` — synchronous unlink, idempotent; a no-op for an
    /// entry that was never armed or already fired. Only the arming
    /// scheduler may disarm.
    void disarmAlarm(ref Alarm alarm) @trusted nothrow @nogc
    in (alarm._owner is null || alarm._owner is &this,
        "alarm belongs to another scheduler")
    {
        if (!alarm._armed)
            return;
        if (alarm._prev !is null)
            alarm._prev._next = alarm._next;
        else
            _armedAlarms = alarm._next;
        if (alarm._next !is null)
            alarm._next._prev = alarm._prev;
        alarm._prev = alarm._next = null;
        alarm._armed = false;
    }

    // ── the blocking-completion inbox (SPEC §13.8) ───────────────────────
    // A `BlockingPool` worker finishes a job whose caller fiber is parked
    // here and posts the job back: an intrusive lock-free push onto this
    // scheduler's inbox plus one coalescing `Waker.wake()`. The owner thread
    // drains the inbox at its tick points and wakes each waiter. Sched-owned
    // by design (no registration, no capacity, no stale callbacks): a
    // pending job ⇒ its caller is parked ⇒ this Sched cannot be destroyed.

    /**
    Arms the loop's waker for cross-thread completion delivery (idempotent;
    consumes one op slot the first time). `BlockingPool.prepare` calls this
    $(B before) a supervised child is spawned so that later slab saturation
    cannot block a mandatory reap.
    */
    package IoResult!void ensureBlockingInboxWaker() @trusted
    {
        _externalWakeUsed = true;
        _blockingWakerArmed = true;
        return ioOk();
    }

    /// `true` once `ensureBlockingInboxWaker` succeeded.
    package bool blockingInboxReady() const @safe pure nothrow @nogc
        => _blockingWakerArmed;

    /// The armed waker, copied into a job at submission so a worker thread
    /// never touches scheduler state beyond the shared inbox head.
    package Waker blockingWaker() @safe pure nothrow @nogc
        => _waker;

    /// The one no-return seam for supervision-level ownership failures
    /// (SPEC §13.7): a reap that can neither succeed nor prove external
    /// loss has no ownership boundary to return through, so it ends the
    /// process through the loop's configured `FatalHook`. Called on the
    /// scheduler thread by the supervisor fiber — never by a pool worker.
    package noreturn fatal(in IoError why) @trusted nothrow @nogc
        => _loop.fatal(why);

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
        // A request names the run it reaches; the next run starts afresh,
        // however this one ends — unless it ends leaked, never to run again.
        scope (exit)
            if (!_leaked)
            {
                _shutdownBegun = false;
                atomicStore(_shutdownState, ShutdownState.none);
            }

        while (_liveFibers > 0 || _loop.inFlight > 0)
        {
            if (!_shutdownBegun
                && atomicLoad!(MemoryOrder.acq)(_shutdownState) == ShutdownState.requested)
                beginShutdown();
            Duration timeout = Duration.max;
            if (_shutdownBegun)
            {
                const now = MonoTime.currTime;
                if (now >= _shutdownBy)
                {
                    // EFP21: what is still live may yet be woken from any
                    // thread, so nothing of this scheduler may be freed.
                    _leaked = true;
                    return ioErr!void(ETIMEDOUT, OpKind.none, IoErrorStage.cancel,
                        "the shutdown's grace period expired with fibers or operations live");
                }
                timeout = _shutdownBy - now;
            }
            if (_readyHead is null && _liveFibers > 0 && _loop.inFlight == 0
                && !_externalWakeUsed && _lotSleepers == 0
                && _armedDeadlines is null && _armedAlarms is null)
                assert(0, "deadlock: parked fibers with nothing in flight");
            auto r = tickRecordingDefect(timeout);
            if (r.hasError)
                return ioErr!void(r.error);
        }
        return ioOk();
    }

    /**
    Asks this scheduler's `run` to shut down; callable from any thread, and
    before the run starts (SPEC §11, fiber-parker.md EFP21). At its next
    tick the owner cancels the outermost scope of every live fiber with
    `InterruptKind.shutdown`, or interrupts a fiber no scope holds, so each
    ends at its next cancellation point (SPEC §8.4). If fibers or
    operations outlive `grace`, `run` returns `ETIMEDOUT` and the scheduler
    is `leaked`: its storage must then never be freed, since a fiber still
    parked can be woken later from any thread. So a scheduler that may be
    asked to shut down must not live in a frame that ends while it runs:
    `LoopGroup` keeps its schedulers on the GC heap and roots a leaked one.
    The first request's grace counts; later ones only repeat the wake. A run
    that ends resets the request. The scheduler must not have been destroyed.
    */
    void requestShutdown(Duration grace) @trusted nothrow @nogc
    {
        if (cas(&_shutdownState, ShutdownState.none, ShutdownState.claimed))
        {
            _shutdownGrace = grace;
            atomicStore!(MemoryOrder.rel)(_shutdownState, ShutdownState.requested);
        }
        _waker.wake();
    }

    /// Whether a shutdown's grace period expired during `run`: the
    /// scheduler, its task slab, its inbox and its loop must be leaked.
    bool leaked() const @safe pure nothrow @nogc => _leaked;

    /// Begins a requested shutdown on the owner thread.
    private void beginShutdown() @trusted nothrow @nogc
    {
        _shutdownBegun = true;
        const now = MonoTime.currTime;
        _shutdownBy = _shutdownGrace >= Duration.max / 2 ? MonoTime.max : now + _shutdownGrace;
        const why = Interrupt(InterruptKind.shutdown);
        foreach (t; _tasks)
        {
            if (t._body is null)
                continue; // free
            auto node = t.ectx.cancelContext;
            if (node is null)
            {
                interruptFiber(&t.ectx, why);
                continue;
            }
            while (node.parent !is null)
                node = node.parent;
            cancelTree(node, why);
        }
    }

    /// `tick` for `run`, keeping the `Throwable` that ends the run early so
    /// that a teardown unable to leak the run can report it (`abandon`).
    private IoResult!RunStatus tickRecordingDefect(Duration timeout) @system
    {
        try
            return tick(timeout);
        catch (Throwable t)
        {
            _abortedBy = t;
            throw t;
        }
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
        // a null check while nothing is armed. The blocking inbox drains at
        // the same points: a worker's post may have landed at any time.
        cast(void) sweepDeadlines();
        cast(void) sweepAlarms();
        cast(void) drainBlockingInbox();
        cast(void) drainWakeInbox();

        uint ran;
        while (ran < _opts.resumeBudget)
        {
            auto t = dequeue();
            if (t is null)
                break;
            resume(t);
            ++ran;
            cast(void) sweepDeadlines();
            cast(void) sweepAlarms();
        }
        if (ringSubmissionPoint(ran))
            return ioOk(RunStatus.dispatched);
        if (_liveFibers == 0 && _loop.inFlight == 0)
            return ioOk(RunStatus.drained);

        // Clamp the wait to the earliest armed deadline or alarm.
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
        bool swept = sweepDeadlines();
        swept |= sweepAlarms();
        swept |= drainBlockingInbox();
        swept |= drainWakeInbox();
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
            cast(void) sweepAlarms();
            cast(void) drainBlockingInbox();
            cast(void) drainWakeInbox();

            uint ran;
            while (ran < _opts.resumeBudget)
            {
                auto t = dequeue();
                if (t is null)
                    break;
                resume(t);
                ++ran;
                cast(void) sweepDeadlines();
                cast(void) sweepAlarms();
            }
            if (ringSubmissionPoint(ran))
                return ioOk(RunStatus.dispatched);
            if (_liveFibers == 0 && _loop.inFlight == 0)
                return ioOk(RunStatus.drained);

            // Clamp to the earliest armed deadline or alarm; the hosted wait
            // always blocks on the host source, so no sleep arm is needed.
            Duration eff = timeout;
            const until = untilNextDeadline(MonoTime.currTime);
            if (until < eff)
                eff = until;

            auto r = _loop.runHostedOnce(host, eff);
            if (r.hasError)
                return r;
            bool swept = sweepDeadlines();
            swept |= sweepAlarms();
            swept |= drainBlockingInbox();
            swept |= drainWakeInbox();
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
        _externalWakeUsed = true;
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
            return AwaitOutcome(-submitted.error.code);

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
    void yieldNow() @trusted nothrow @nogc
    {
        auto task = _running;
        assert(task !is null, "yieldNow outside a scheduler fiber");
        task.wakeKind = WakeKind.manual;
        enqueue(task);
        park();
    }

    // ── the fiber parker's scheduler side (fiber-parker.md) ────────────

    /// The task at slab index `i`, which a wake handle names.
    package FiberTask taskAt(size_t i) @safe pure nothrow @nogc => _tasks[i];

    /// Makes a parked fiber runnable on its owner's thread: the winning
    /// resumption's enqueue at the tail of the ready queue (EFP9, EFP12).
    package void resumeParked(FiberTask t) @safe nothrow @nogc
    {
        t.wakeKind = WakeKind.manual;
        enqueue(t);
    }

    /// Counts a fiber into or out of a fiber-parker sleep: one any thread
    /// may end, so `run` does not call it deadlock.
    package void noteLotSleep(bool entering) @safe pure nothrow @nogc
    {
        if (entering)
            ++_lotSleepers;
        else
            --_lotSleepers;
    }

    /// Arms `alarm` to run `onFire(ctx)` at `at` on this thread, between
    /// dispatches: the fiber parker's deadline (EFP14).
    package void armCallbackAlarm(ref Alarm alarm, MonoTime at,
        void function(void*) nothrow @nogc onFire, void* ctx) @trusted nothrow @nogc
    in (!alarm._armed, "alarm already armed")
    {
        alarm._at = at;
        alarm._waiter = null;
        alarm._onFire = onFire;
        alarm._onFireCtx = ctx;
        alarm._owner = &this;
        alarm._fired = false;
        alarm._prev = null;
        alarm._next = _armedAlarms;
        if (_armedAlarms !is null)
            _armedAlarms._prev = &alarm;
        _armedAlarms = &alarm;
        alarm._armed = true;
    }

    /// The armed waker, through which another thread reaches this one.
    package Waker waker() @safe pure nothrow @nogc => _waker;

    /// Fibers asleep on the fiber parker right now.
    uint lotSleepers() const @safe pure nothrow @nogc => _lotSleepers;

    /// Whether this scheduler's fibers park on the ring path (EFP6).
    bool ringPark() const @safe pure nothrow @nogc => _ringPark;

    /// Ring waits written and not yet completed (EFP8).
    uint ringWaits() const @safe pure nothrow @nogc => _ringWaits;

    /// Queues a ring sleep for the submission point (EFP8).
    package void queueRingSleep(FiberTask t) @safe nothrow @nogc
    in (!t.park.ringPending, "a ring sleep queued twice")
    {
        t.park.ringPending = true;
        t.park.ringPrev = null;
        t.park.ringNext = _ringSleeps;
        if (_ringSleeps !is null)
            _ringSleeps.park.ringPrev = t;
        _ringSleeps = t;
    }

    /// Takes a ring sleep off the submission point's queue, if it is on it.
    package void unqueueRingSleep(FiberTask t) @safe nothrow @nogc
    {
        if (!t.park.ringPending)
            return;
        if (t.park.ringPrev !is null)
            t.park.ringPrev.park.ringNext = t.park.ringNext;
        else
            _ringSleeps = t.park.ringNext;
        if (t.park.ringNext !is null)
            t.park.ringNext.park.ringPrev = t.park.ringPrev;
        t.park.ringPrev = t.park.ringNext = null;
        t.park.ringPending = false;
    }

    /// Makes `t` runnable unless it already is (the submission point's
    /// resumption, which a winner on this thread may have done first).
    package void resumeParkedOnce(FiberTask t) @safe nothrow @nogc
    {
        if (!t.enqueued)
            resumeParked(t);
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
            // Never lost: backpressure queues the request on the loop's
            // pending set (retried at every drive); the only failure is a
            // hard backend fault, which does not return.
            auto r = task.owner._loop.cancel(h);
            assert(!r.hasError, "cancel is infallible on a driven loop");
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

    /// The earliest armed expiry — deadline or alarm — as a wait bound
    /// relative to `now`; `Duration.max` when nothing (relevant) is armed.
    /// Already-cancelling nodes are skipped — their sweep would no-op, so
    /// waking early for them buys nothing.
    Duration untilNextDeadline(MonoTime now) const @safe nothrow @nogc
    {
        Duration best = Duration.max;
        for (const(CancelContext)* n = _armedDeadlines; n !is null; n = n.nextArmed)
        {
            if (n.state != CancelContext.State.on)
                continue;
            if (n.deadlineAt == MonoTime.max)
                continue;
            const until = n.deadlineAt <= now ? Duration.zero : n.deadlineAt - now;
            if (until < best)
                best = until;
        }
        for (const(Alarm)* a = _armedAlarms; a !is null; a = a._next)
        {
            if (a._at == MonoTime.max)
                continue;
            const until = a._at <= now ? Duration.zero : a._at - now;
            if (until < best)
                best = until;
        }
        return best;
    }

    /// Sweeps expired alarms: unlink first, then mark fired, then wake —
    /// never an interrupt. Same thread discipline as `sweepDeadlines`.
    bool sweepAlarms() @trusted nothrow @nogc
    {
        if (_armedAlarms is null)
            return false;
        const now = MonoTime.currTime;
        bool swept;
        auto a = _armedAlarms;
        while (a !is null)
        {
            auto next = a._next;
            if (a._at <= now)
            {
                disarmAlarm(*a);
                a._fired = true;
                if (a._onFire !is null)
                    a._onFire(a._onFireCtx);
                else
                    wake(a._waiter);
                swept = true;
            }
            a = next;
        }
        return swept;
    }

    /// Owner-thread drain of the blocking-completion inbox: every posted
    /// job is marked done and its parked caller woken. Returns whether any
    /// job was delivered.
    bool drainBlockingInbox() @trusted nothrow @nogc
    {
        import core.atomic : atomicExchange, atomicStore;

        auto head = cast(BlockingJob*) atomicExchange(&_blockingInbox,
            cast(shared(BlockingJob*)) null);
        if (head is null)
            return false;
        for (auto job = head; job !is null;)
        {
            auto next = job.next;
            job.next = null;
            atomicStore(job.done, true);
            wake(job.waiter);
            job = next;
        }
        return true;
    }

    /// Owner-thread drain of the wake inbox: each task a winning resumption
    /// pushed from another thread goes to the tail of the ready queue, in
    /// the order the pushes landed (EFP13).
    bool drainWakeInbox() @trusted nothrow @nogc
    {
        import core.atomic : atomicExchange, atomicStore;

        auto head = cast(FiberTask) atomicExchange(&_wakeInbox, cast(shared(FiberTask)) null);
        if (head is null)
            return false;
        // The stack is newest-first; reverse it into push order.
        FiberTask ordered;
        while (head !is null)
        {
            auto next = cast(FiberTask) head.park.nextWake;
            head.park.nextWake = cast(shared(FiberTask)) ordered;
            ordered = head;
            head = next;
        }
        while (ordered !is null)
        {
            auto next = cast(FiberTask) ordered.park.nextWake;
            ordered.park.nextWake = null;
            // Cleared before the task is checked: a delivery that then finds
            // the flag clear pushes the task again (EFP13).
            atomicStore(ordered.park.inInbox, false);
            resumeIfAsleep(ordered);
            ordered = next;
        }
        return true;
    }

    /**
    The end of a tick's resumes: the ring path's submission point (EFP8),
    then whether the tick is done without waiting — fibers ran, or are
    ready. A tick whose fibers ran does not wait for completions, so while
    ring waits are written it still flushes and reaps without blocking: a
    worker that always has a fiber to run must not starve its parked fibers'
    wakes and deadlines.
    */
    bool ringSubmissionPoint(uint ran) @trusted nothrow @nogc
    {
        const resolved = _ringPark && writeRingSleeps();
        if (ran == 0 && _readyHead is null && !resolved)
            return false;
        static if (ringParkLowerable)
            if (_ringWaits > 0)
                cast(void) _loop.runOnce(Duration.zero);
        return true;
    }

    /// Counts a ring wait in or out of the kernel (fiber-parker.md EFP7,
    /// EFP11): while any is, a busy tick still reaps.
    package void noteRingWait(bool entering) @safe pure nothrow @nogc
    {
        if (entering)
            ++_ringWaits;
        else
            --_ringWaits;
    }

    /// The submission point of the ring path (EFP8): writes every queued
    /// ring sleep's wait, or resumes a sleep resolved since it queued without
    /// an operation. Whether any fiber became runnable, so that the tick runs
    /// it rather than waiting.
    bool writeRingSleeps() @safe nothrow @nogc
    {
        bool resumed;
        while (_ringSleeps !is null)
        {
            auto t = _ringSleeps;
            unqueueRingSleep(t);
            resumed |= writeRingSleep(t);
        }
        return resumed;
    }

    /// Waits until no committed wake can still touch this scheduler: a
    /// delivery is bounded and never blocks, so the wait is short (EFP4).
    void awaitDeliveries() @trusted nothrow @nogc
    {
        import core.atomic : atomicLoad;

        while (atomicLoad(_pendingDeliveries) != 0)
            Thread.yield();
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
        // The fiber parker is current while the fiber runs, the thread
        // parker everywhere else (EFP1).
        auto outer = installParker(fiberParker(t));
        auto thrown = t.call(Fiber.Rethrow.no);
        cast(void) installParker(outer);
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
    /// Armed wake-only alarms (same shape and discipline).
    Alarm* _armedAlarms;
    /// The blocking-completion inbox: an intrusive lock-free stack pushed by
    /// pool workers, drained by this thread at its tick points.
    shared(BlockingJob*) _blockingInbox;
    bool _blockingWakerArmed;
    bool _destroyed;
    /// The loop's waker, armed at creation: the blocking inbox and the
    /// fiber parker's wake inbox are reached through it (EFP22).
    Waker _waker;
    /// Something outside the scheduler may wake it — a blocking job or
    /// an idle waiter — so `run` cannot call a parked state deadlock. The
    /// flag is one-way: once set, the check stays off for this scheduler.
    bool _externalWakeUsed;
    /// Fibers asleep on the fiber parker, which any thread may wake.
    uint _lotSleepers;
    /// Every task, by slab index: a wake handle names its task this way.
    FiberTask[] _tasks;
    /// The fiber parker's wake inbox: tasks resumed by another thread,
    /// an intrusive lock-free stack drained at the tick points (EFP12).
    package shared(FiberTask) _wakeInbox;
    /// Wakes committed and not yet delivered (EFP4).
    package shared uint _pendingDeliveries;
    /// The `Throwable` that ended `run` early, if one did.
    Throwable _abortedBy;
    /// Fibers park on the ring path (EFP6).
    bool _ringPark;
    /// Ring sleeps queued for the submission point (EFP8).
    FiberTask _ringSleeps;
    /// Ring waits written and not yet completed.
    uint _ringWaits;
    /// A shutdown requested from any thread (`requestShutdown`).
    shared ShutdownState _shutdownState;
    /// The first request's grace, published by its state's release.
    Duration _shutdownGrace;
    /// The owner has begun the requested shutdown.
    bool _shutdownBegun;
    /// When the shutdown's grace period ends.
    MonoTime _shutdownBy;
    /// The grace period expired: nothing of this scheduler may be freed.
    bool _leaked;
}

/// The progress of a requested shutdown.
private enum ShutdownState : ubyte
{
    none,      /// no request
    claimed,   /// a request is publishing its grace
    requested, /// the grace is published
}

/**
A reusable wake-only timer entry for the calling fiber (see
`Sched.armAlarm`). Address-pinned while armed; the caller owns it and must
disarm it before its frame dies. `fired` is level-triggered — check it before
every park, so a wake that lands before the park is never lost:

---
Alarm a;
s.armAlarm(a, 10.msecs);
scope (exit) s.disarmAlarm(a); // unconditional: no early exit leaves it listed
while (!a.fired)
    s.park();
---

`reset` is legal only while disarmed and readies the entry for another arm.
*/
struct Alarm
{
    @disable this(this);

    /// `true` once the alarm expired (until `reset`).
    bool fired() const @safe pure nothrow @nogc => _fired;

    /// `true` while listed on a scheduler.
    bool armed() const @safe pure nothrow @nogc => _armed;

    /// Clears `fired` so the entry can be armed again.
    void reset() @safe pure nothrow @nogc
    in (!_armed, "reset while armed")
    {
        _fired = false;
    }

package:
    /// Run at expiry instead of waking `_waiter` (the fiber parker's deadline).
    void function(void* ctx) nothrow @nogc _onFire;
    void* _onFireCtx;

private:
    MonoTime _at;
    FiberContext* _waiter;
    Sched* _owner;
    bool _armed;
    bool _fired;
    Alarm* _prev;
    Alarm* _next;
}

/// The shape of a blocking host call run by a `BlockingPool` worker (SPEC
/// §13.8): it writes its typed result into caller-owned `context`.
alias BlockingCall = void function(void* context) nothrow;

/**
One blocking job, living on the parked caller's frame for its whole life
(SPEC §13.8 — "the parked frame remains the ordinary lifetime proof"). The
pool queues it, a worker runs `call(context)` and posts it back through
$(LREF postBlockingCompletion); the owner scheduler's drain sets `done` and
wakes `waiter`. A pending job therefore implies a parked (live) caller fiber,
which is exactly what forbids destroying `owner` meanwhile.
*/
package struct BlockingJob
{
    BlockingCall call;
    void* context;
    Sched* owner;          /// the caller's scheduler; only its inbox is touched
    FiberContext* waiter;  /// the parked caller
    Waker waker;           /// `owner`'s armed waker, copied at submission
    BlockingJob* next;     /// inbox link (worker push → owner drain)
    shared bool done;      /// set by the owner's drain, read by the caller
}

/// Worker-thread side: pushes a finished job onto its owner's inbox and
/// wakes that loop. Touches nothing of the scheduler but the shared inbox
/// head; the waker is the job's own copy.
package void postBlockingCompletion(BlockingJob* job) @trusted nothrow @nogc
{
    import core.atomic : atomicLoad, cas;

    auto inbox = &job.owner._blockingInbox;
    for (;;)
    {
        auto old = atomicLoad(*inbox);
        job.next = cast(BlockingJob*) old;
        if (cas(inbox, old, cast(shared(BlockingJob*)) job))
            break;
    }
    job.waker.wake();
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

@("sched.alarm.wakesOnceIsReusableAndLeavesNoLatch")
@safe
unittest
{
    import core.time : msecs;

    Sched s;
    schedOrSkip(s);

    uint resumes;
    bool latched;
    auto r = s.run(() {
        Alarm a;
        foreach (cycle; 0 .. 3)
        {
            // The one shape: arm, guard, level-triggered park.
            s.armAlarm(a, 2.msecs);
            scope (exit) s.disarmAlarm(a);
            while (!a.fired)
                s.park();
            ++resumes;
            assert(!a.armed, "expiry unlinks before it wakes");
            a.reset();
            assert(!a.fired);
        }
        auto ctx = s.currentContext();
        latched = ctx.interrupted || interruptRequested(*ctx);
    });
    assert(!r.hasError);
    assert(resumes == 3, "one resume per arm, and the entry is reusable");
    assert(!latched, "an alarm is a wake, never a deadline latch");
}

@("sched.alarm.keepsOuterInterruptPrecedence")
@safe
unittest
{
    import core.time : msecs;
    import sparkles.event_horizon.cause : interruptFiber;
    import sparkles.event_horizon.scope_ : protect;

    Sched s;
    schedOrSkip(s);

    // A fiber parked on an alarm under `protect` is interrupted by a
    // sibling: the alarm still wakes it exactly once, the interrupt stays
    // latched (delivered at its first checkpoint after the shield), and
    // nothing about the alarm consumed or replaced that latch.
    FiberContext* sleeper;
    bool interruptedAfterShield;
    uint wakes;
    auto r = s.run(() {
        assert(!s.spawn(() {
            sleeper = s.currentContext();
            cast(void) protect!(() {
                Alarm a;
                s.armAlarm(a, 5.msecs);
                scope (exit) s.disarmAlarm(a);
                while (!a.fired)
                    s.park();
                ++wakes;
                return 0;
            })(s);
            interruptedAfterShield = interruptRequested(*s.currentContext());
        }).hasError);
        assert(!s.spawn(() {
            // Let the sleeper park first, then interrupt it directly.
            s.yieldNow();
            (() @trusted => interruptFiber(sleeper,
                Interrupt(InterruptKind.cancelled)))();
        }).hasError);
    });
    assert(!r.hasError);
    assert(wakes == 1);
    assert(interruptedAfterShield, "the outer interrupt keeps precedence");
}

@("sched.alarm.rejectsDoubleArm")
@system
unittest
{
    import core.exception : AssertError;
    import core.time : msecs;

    Sched s;
    schedOrSkip(s);

    bool rejected;
    auto r = s.run(() {
        Alarm a;
        s.armAlarm(a, 50.msecs);
        try
            s.armAlarm(a, 50.msecs);
        catch (AssertError)
            rejected = true;
        s.disarmAlarm(a);
        s.disarmAlarm(a); // idempotent
        assert(!a.armed);
    });
    assert(!r.hasError);
    assert(rejected, "an armed entry cannot be armed again");
}

@("sched.blockingInbox.crossThreadPostWakesTheParkedCaller")
@system
unittest
{
    import core.atomic : atomicLoad;
    import core.time : msecs;

    Sched s;
    schedOrSkip(s);

    // Three jobs on the caller's frame, completed by three foreign threads
    // in the reverse order, each posting through the Sched-owned inbox: the
    // parked caller resumes for every one and never sees a torn job.
    auto r = s.run(() {
        assert(!s.ensureBlockingInboxWaker().hasError);
        assert(s.blockingInboxReady);

        // One closure frame per thread: a lambda written inside the loop
        // body would capture the loop's single `jp` slot for all three
        // threads and post the last job three times.
        static Thread poster(BlockingJob* jp, int delayMs)
        {
            return new Thread({
                Thread.sleep(delayMs.msecs);
                postBlockingCompletion(jp);
            }).start();
        }

        BlockingJob[3] jobs;
        Thread[3] workers;
        foreach (i, ref job; jobs)
        {
            job.owner = &s;
            job.waiter = s.currentContext();
            job.waker = s.blockingWaker;
            workers[i] = poster(&job, (3 - cast(int) i) * 3);
        }
        foreach (ref job; jobs)
            while (!atomicLoad(job.done))
                s.park();
        foreach (w; workers)
            w.join();
    });
    assert(!r.hasError);
}

@("sched.blockingInbox.sameThreadPostDrainsAtTheNextTick")
@system
unittest
{
    import core.atomic : atomicLoad;

    Sched s;
    schedOrSkip(s);

    // Posted from the loop thread itself (no worker, no wake needed): the
    // next tick drains the inbox and the parked caller resumes.
    auto r = s.run(() {
        assert(!s.ensureBlockingInboxWaker().hasError);
        BlockingJob job;
        job.owner = &s;
        job.waiter = s.currentContext();
        job.waker = s.blockingWaker;
        postBlockingCompletion(&job);
        while (!atomicLoad(job.done))
            s.park();
    });
    assert(!r.hasError);
}

@("sched.defect.survivesTheDestructorOfAnAbortedRun")
@system
unittest
{
    import core.exception : AssertError;
    import core.time : msecs;
    import sparkles.event_horizon.io : sleep;

    // The defect ends the run while a sibling sleeps, so the scheduler goes
    // out of scope with a live fiber; its destructor must not overwrite the
    // defect with a failed teardown of its own.
    string caught;
    try
    {
        Sched s;
        schedOrSkip(s);
        cast(void) s.run(() {
            assert(!s.spawn(() { cast(void) sleep(s, 20.msecs); }).hasError);
            s.yieldNow();
            assert(false, "the defect");
        });
    }
    catch (AssertError e)
        caught = e.msg.idup;
    assert(caught == "the defect", caught);
}
