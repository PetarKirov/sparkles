/**
Tier A — the callback completion core (SPEC §5): `submit(op, callback, ctx)`
over one DbI backend. The loop owns the op-slot slab (buffer pinning,
kernel-stable operands, the cancellation state machine) and delivers
completions only inside `runOnce` — the `DEFER_TASKRUN` contract made
structural.

The loop is thread-affine and non-copyable: every member must be called from
the owning thread (the off-thread `Waker` door lands in M4).
*/
module sparkles.event_horizon.loop;

import core.stdc.errno : EAGAIN, ECANCELED, ENOBUFS, ETIME;
import core.lifetime : move;
import core.time : Duration, MonoTime;

import sparkles.event_horizon.backend.concept;
import sparkles.event_horizon.backend.probe : BackendCaps;
import sparkles.event_horizon.buffer : Buf;
import sparkles.event_horizon.errors;
import sparkles.event_horizon.op;

/// Loop-level configuration; embeds the backend's.
struct LoopConfig
{
    BackendConfig backend; /// sqEntries / cqEntries / mode / modePolicy
    uint opSlots = 0;      /// op-slot slab capacity; 0 = 2 × cqEntries
}

/// What ended a `runOnce` iteration.
enum RunStatus : ubyte
{
    dispatched, /// at least one completion was delivered
    timedOut,   /// the deadline expired with nothing to deliver
    stopped,    /// `stop()` was observed
    drained,    /// no live ops and no timers — nothing to wait for
}

/// The platform default backend's loop (tier A's public front door).
version (linux)
{
    import sparkles.event_horizon.backend.uring : UringBackend;

    alias DefaultLoop = EventLoop!UringBackend;
}

/**
The tier-A event loop over a completion backend (SPEC §5.1).
*/
struct EventLoop(Backend)
if (isCompletionBackend!Backend)
{
    @disable this(this);

    /**
    Out-parameter factory (SPEC §9.1: `IoResult` cannot return a
    non-copyable owner by value): backend setup → capability probe (the
    hard-error semantics of SPEC §3.4) → slab allocation. All-or-nothing.
    */
    static IoResult!void create(out EventLoop loop, in LoopConfig cfg = LoopConfig())
    {
        auto opened = loop._backend.open(cfg.backend);
        if (opened.hasError)
            return opened;

        const cq = cfg.backend.cqEntries != 0
            ? cfg.backend.cqEntries
            : 2 * cfg.backend.sqEntries;
        const slots = cfg.opSlots != 0 ? cfg.opSlots : 2 * cq;
        auto slabbed = loop._slab.initialize(slots);
        if (slabbed.hasError)
        {
            loop._backend.close();
            return slabbed;
        }
        loop._open = true;
        return ioOk();
    }

    /// Structured teardown; the scope discipline (M5) guarantees the
    /// precondition at higher tiers.
    void destroy()
    in (_slab.liveCount == 0, "destroy with ops in flight")
    {
        if (!_open)
            return;
        _slab.terminate();
        _backend.close();
        _open = false;
    }

    ~this()
    {
        destroy();
    }

    /// The negotiated capability surface (SPEC §3.3).
    ref const(BackendCaps) caps() const return => _backend.caps();

    /**
    Submits `op` with a completion callback (SPEC §5.2). Owned buffers move
    into the op slot and come back via `Completion.buf`; on a submission
    error the buffer is recycled to its origin (it does not come back —
    there will be no completion).

    Backpressure: on a full submission queue the loop performs one implicit
    `flush` retry, then returns `EAGAIN`; an exhausted slab returns
    `ENOBUFS`.
    */
    IoResult!OpHandle submit(Op)(Op op, OpCallback cb, void* ctx = null)
    if (isOpDesc!Op && canSubmitOp!(Backend, Op))
    {
        const token = _slab.acquire(Op.kind, OpClass.user, cb, ctx);
        if (!token)
            return ioErr!OpHandle(ENOBUFS, Op.kind, IoErrorStage.submit,
                "op slab full");
        auto slot = _slab.resolve(token);

        static if (__traits(hasMember, Op, "buf"))
            slot.pinned = move(op.buf);

        if (!trySubmitWithRetry(op, token, *slot))
        {
            _slab.release(token); // recycles the pinned buffer to its origin
            return ioErr!OpHandle(EAGAIN, Op.kind, IoErrorStage.submit,
                "submission queue full");
        }
        return ioOk(OpHandle(token));
    }

    /// Arms a relative timer (in-ring `TIMEOUT`, SPEC §5.3); the callback
    /// fires with `res == 0` on expiry.
    IoResult!OpHandle submitAfter(Duration rel, OpCallback cb, void* ctx = null)
    {
        long secs, nsecs;
        rel.split!("seconds", "nsecs")(secs, nsecs);
        return submit(OpTimeout(KernelTimespec(secs, nsecs)), cb, ctx);
    }

    /// ditto, absolute against `now()`.
    IoResult!OpHandle submitAt(MonoTime deadline, OpCallback cb, void* ctx = null)
    {
        const rel = deadline - now();
        return submitAfter(rel > Duration.zero ? rel : Duration.zero, cb, ctx);
    }

    /**
    Requests cancellation — fire-and-forget (SPEC §8.5): the target's own
    callback later observes `-ECANCELED` (or the real result, if completion
    won the race). The slot and its pinned buffer stay alive until that
    terminal completion, always. Cancelling an already-completed handle is
    a no-op.
    */
    IoResult!void cancel(OpHandle h)
    {
        auto slot = _slab.resolve(h.token);
        if (slot is null || slot.state != OpState.armed)
            return ioOk(); // already completed / already cancel-requested

        const cancelToken = _slab.acquire(OpKind.cancel, OpClass.internal, null, null);
        if (!cancelToken)
            return ioErr!void(ENOBUFS, OpKind.cancel, IoErrorStage.cancel,
                "op slab full");
        if (!_backend.trySubmitCancel(cancelToken, h.token))
        {
            cast(void) _backend.flush();
            if (!_backend.trySubmitCancel(cancelToken, h.token))
            {
                _slab.release(cancelToken);
                return ioErr!void(EAGAIN, OpKind.cancel, IoErrorStage.cancel,
                    "submission queue full");
            }
        }
        slot.state = OpState.cancelRequested;
        slot.provenance = CancelProvenance.explicit_;
        return ioOk();
    }

    /// Monoio "Ignored": the callback never runs; the slot and buffer are
    /// recycled silently on the terminal completion (SPEC §4.3).
    void detach(OpHandle h)
    {
        auto slot = _slab.resolve(h.token);
        if (slot is null)
            return;
        if (slot.state == OpState.armed || slot.state == OpState.cancelRequested)
            slot.state = OpState.detached;
    }

    /**
    One iteration (SPEC §5.4): flush → wait (≥ 1 completion or `timeout`) →
    drain-and-dispatch. Callbacks run on this thread and may submit freely,
    but must not re-enter `runOnce`.
    */
    IoResult!RunStatus runOnce(Duration timeout = Duration.max)
    in (!_dispatching, "runOnce is not reentrant — callbacks must not drive the loop")
    {
        if (_stopRequested)
            return ioOk(RunStatus.stopped);
        if (_slab.liveCount == 0)
            return ioOk(RunStatus.drained);

        KernelTimespec deadline;
        const(KernelTimespec)* deadlinePtr = null;
        if (timeout != Duration.max)
        {
            long secs, nsecs;
            timeout.split!("seconds", "nsecs")(secs, nsecs);
            deadline = KernelTimespec(secs, nsecs);
            deadlinePtr = &deadline;
        }
        auto waited = _backend.submitAndWait(1, deadlinePtr);
        if (waited.hasError)
            return ioErr!RunStatus(waited.error);

        _dispatching = true;
        scope (exit) _dispatching = false;
        const n = _backend.reap((ref const RawCompletion c) { dispatch(c); });
        return ioOk(n > 0 ? RunStatus.dispatched : RunStatus.timedOut);
    }

    /// Runs until `stop()` or until drained (no live ops).
    IoResult!void run()
    {
        for (;;)
        {
            auto r = runOnce();
            if (r.hasError)
                return ioErr!void(r.error);
            final switch (r.value)
            {
                case RunStatus.dispatched:
                case RunStatus.timedOut:
                    continue;
                case RunStatus.stopped:
                    _stopRequested = false;
                    return ioOk();
                case RunStatus.drained:
                    return ioOk();
            }
        }
    }

    /// Makes the next (or current, once M4's waker lands) `runOnce` return
    /// `stopped`. Loop-thread only in M3 — callbacks may call it.
    void stop()
    {
        _stopRequested = true;
    }

    /// Ops (of every class) currently in flight.
    uint inFlight() const => _slab.liveCount;

    /// The loop's monotonic clock.
    MonoTime now() const => MonoTime.currTime;

private:
    bool trySubmitWithRetry(Op)(in Op op, OpToken token, ref OpSlot slot)
    {
        if (_backend.trySubmit(op, token, slot))
            return true;
        cast(void) _backend.flush(); // one implicit retry (SPEC §5.2)
        return _backend.trySubmit(op, token, slot);
    }

    void dispatch(ref const RawCompletion raw)
    {
        const token = OpToken(raw.userData);
        auto slot = _slab.resolve(token);
        if (slot is null)
            return; // stale generation: a recycled slot's late completion

        // Internal completions (cancel bookkeeping, future waker) are
        // consumed silently.
        if (slot.cls == OpClass.internal || slot.cls == OpClass.wake)
        {
            _slab.release(token);
            return;
        }

        const flags = _backend.mapFlags(raw.rawFlags);
        const isFinal = (flags & CompletionFlags.more) == 0;

        if (slot.state == OpState.detached)
        {
            if (isFinal)
                _slab.release(token);
            return;
        }

        Completion done;
        done.token = token;
        done.kind = slot.kind;
        done.res = raw.res;
        done.flags = flags;

        // A timer's expiry is its success, not an error.
        if (slot.kind == OpKind.timeout && raw.res == -ETIME)
            done.res = 0;

        if (isFinal)
            done.buf = move(slot.pinned);

        // Receive paths: the valid-byte count comes from the completion.
        if (raw.res > 0 && !done.buf.empty
            && (slot.kind == OpKind.read || slot.kind == OpKind.recv
                || slot.kind == OpKind.recvFrom))
            done.buf.length = cast(uint) raw.res <= done.buf.capacity
                ? cast(uint) raw.res : done.buf.capacity;

        if (slot.kind == OpKind.recvFrom)
        {
            done.peer = slot.peerOut;
            done.peer.len = slot.operands.msg.hdr.msg_namelen;
        }

        const cb = slot.callback;
        auto ctx = slot.ctx;
        if (isFinal)
            _slab.release(token); // before the callback: it may submit anew

        // The one deliberate trust boundary of tier A: callback pointers are
        // caller-provided `nothrow @nogc` function pointers (the C-ABI
        // floor); their bodies own the safety of their `ctx` cast.
        if (cb !is null)
            (() @trusted => cb(ctx, done))();
        // done.buf recycles to its origin here unless the callback moved it.
    }

    Backend _backend;
    OpSlab _slab;
    bool _open;
    bool _dispatching;
    bool _stopRequested;
}

version (linux)  :  // tests drive the uring backend directly

version (unittest)
{
    /// Creates a loop for a test; `false` = SKIP (no io_uring / old kernel).
    private bool createOrSkip(ref DefaultLoop loop, LoopConfig cfg = LoopConfig())
        @safe nothrow @nogc
    {
        auto r = DefaultLoop.create(loop, cfg);
        if (r.hasError)
        {
            assert(r.error.stage == IoErrorStage.setup
                || r.error.stage == IoErrorStage.probe);
            return false;
        }
        return true;
    }
}

@("loop.nop.callbackRoundTrip")
@safe nothrow @nogc
unittest
{
    DefaultLoop loop;
    if (!createOrSkip(loop))
        return; // SKIP
    scope (exit) loop.destroy();

    static struct Seen
    {
        int calls;
        int res = int.min;
    }

    static void onDone(void* ctx, ref Completion done) nothrow @nogc
    {
        auto seen = cast(Seen*) ctx;
        ++seen.calls;
        seen.res = done.res;
        assert(done.kind == OpKind.nop);
        assert(done.isFinal);
    }

    Seen seen;
    auto h = (() @trusted => loop.submit(OpNop(), &onDone, &seen))();
    assert(h.hasValue);
    assert(loop.inFlight == 1);

    auto status = loop.runOnce();
    assert(status.hasValue && status.value == RunStatus.dispatched);
    assert(seen.calls == 1);
    assert(seen.res == 0);
    assert(loop.inFlight == 0);
}

@("loop.timer.firesWithSuccess")
@safe nothrow @nogc
unittest
{
    import core.time : msecs;

    DefaultLoop loop;
    if (!createOrSkip(loop))
        return; // SKIP
    scope (exit) loop.destroy();

    static void onTimer(void* ctx, ref Completion done) nothrow @nogc
    {
        auto fired = cast(int*) ctx;
        ++*fired;
        assert(done.kind == OpKind.timeout);
        assert(done.res == 0, "expiry is success");
    }

    int fired;
    const before = loop.now();
    auto h = (() @trusted => loop.submitAfter(5.msecs, &onTimer, &fired))();
    assert(h.hasValue);

    auto r = loop.run();
    assert(!r.hasError);
    assert(fired == 1);
    assert(loop.now() - before >= 5.msecs);
}

@("loop.cancel.timerObservesEcanceled")
@safe nothrow @nogc
unittest
{
    import core.time : minutes;

    DefaultLoop loop;
    if (!createOrSkip(loop))
        return; // SKIP
    scope (exit) loop.destroy();

    static struct Seen
    {
        int calls;
        int res;
    }

    static void onTimer(void* ctx, ref Completion done) nothrow @nogc
    {
        auto seen = cast(Seen*) ctx;
        ++seen.calls;
        seen.res = done.res;
    }

    Seen seen;
    auto h = (() @trusted => loop.submitAfter(1.minutes, &onTimer, &seen))();
    assert(h.hasValue);

    assert(!loop.cancel(h.value).hasError);

    // Drain: the cancelled timer's terminal CQE plus the internal cancel CQE.
    auto r = loop.run();
    assert(!r.hasError);
    assert(seen.calls == 1);
    assert(seen.res == -ECANCELED);
    assert(loop.inFlight == 0);
}

@("loop.detach.callbackNeverRuns")
@safe nothrow @nogc
unittest
{
    import core.time : msecs;

    DefaultLoop loop;
    if (!createOrSkip(loop))
        return; // SKIP
    scope (exit) loop.destroy();

    static void onTimer(void* ctx, ref Completion) nothrow @nogc
    {
        ++*cast(int*) ctx;
    }

    int fired;
    auto h = (() @trusted => loop.submitAfter(1.msecs, &onTimer, &fired))();
    assert(h.hasValue);
    loop.detach(h.value);

    auto r = loop.run();
    assert(!r.hasError);
    assert(fired == 0, "detached op's callback must never run");
    assert(loop.inFlight == 0);
}

@("loop.read.pipeDeliversBytes")
@safe nothrow @nogc
unittest
{
    import sparkles.event_horizon.buffer : BufferPool;

    DefaultLoop loop;
    if (!createOrSkip(loop))
        return; // SKIP
    scope (exit) loop.destroy();

    int[2] fds;
    if ((() @trusted {
        import core.sys.posix.unistd : pipe;

        return pipe(fds);
    })() != 0)
        return;
    scope (exit) () @trusted {
        import core.sys.posix.unistd : close;

        close(fds[0]);
        close(fds[1]);
    }();

    static immutable payload = cast(immutable ubyte[]) "event horizon";
    const wrote = (() @trusted {
        import core.sys.posix.unistd : write;

        return write(fds[1], payload.ptr, payload.length);
    })();
    assert(wrote == payload.length);

    BufferPool pool;
    assert(!BufferPool.create(pool, 1, 64).hasError);

    static struct Seen
    {
        int calls;
        uint bytes;
        bool contentOk;
    }

    static void onRead(void* ctx, ref Completion done) nothrow @nogc
    {
        auto seen = cast(Seen*) ctx;
        ++seen.calls;
        auto r = done.result;
        if (r.hasError)
            return;
        seen.bytes = r.value;
        seen.contentOk = done.buf[] == payload[];
        // Not moving done.buf out: the loop recycles it to the pool.
    }

    Seen seen;
    auto acquired = pool.acquire();
    assert(acquired.hasValue);
    auto h = (() @trusted => loop.submit(
        OpRead(fds[0], move(acquired.value), ulong.max), &onRead, &seen))();
    assert(h.hasValue);

    auto r = loop.run();
    assert(!r.hasError);
    assert(seen.calls == 1);
    assert(seen.bytes == payload.length);
    assert(seen.contentOk);
    assert(pool.available == 1, "un-moved completion buffer recycles to the pool");
}

@("loop.stop.fromCallback")
@safe nothrow @nogc
unittest
{
    import core.time : minutes;

    DefaultLoop loop;
    if (!createOrSkip(loop))
        return; // SKIP
    scope (exit) loop.destroy();

    static void onFirst(void* ctx, ref Completion) nothrow @nogc
    {
        (cast(DefaultLoop*) ctx).stop();
    }

    // A long-lived second op keeps the loop from draining; stop() must end
    // run() anyway.
    static void onNever(void*, ref Completion) nothrow @nogc
    {
    }

    auto sentinel = (() @trusted => loop.submitAfter(1.minutes, &onNever, null))();
    assert(sentinel.hasValue);
    auto first = (() @trusted => loop.submit(OpNop(), &onFirst, &loop))();
    assert(first.hasValue);

    auto r = loop.run();
    assert(!r.hasError);
    assert(loop.inFlight == 1, "the sentinel is still armed");

    // Tidy: cancel the sentinel and drain so destroy()'s contract holds.
    assert(!loop.cancel(sentinel.value).hasError);
    assert(!loop.run().hasError);
    assert(loop.inFlight == 0);
}

@("loop.drained.immediately")
@safe nothrow @nogc
unittest
{
    DefaultLoop loop;
    if (!createOrSkip(loop))
        return; // SKIP
    scope (exit) loop.destroy();

    auto status = loop.runOnce();
    assert(status.hasValue && status.value == RunStatus.drained);
    assert(!loop.run().hasError);
}
