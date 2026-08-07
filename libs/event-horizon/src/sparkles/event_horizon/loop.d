/**
Tier A — the callback completion core (SPEC §5): `submit(op, callback, ctx)`
over one DbI backend. The loop owns the op-slot slab (buffer pinning,
kernel-stable operands, the cancellation state machine) and delivers
completions only inside `runOnce` — the `DEFER_TASKRUN` contract made
structural.

The loop is thread-affine and non-copyable: every member must be called from
the owning thread — except `Waker.wake()` (SPEC §5.6), the one off-thread
door, obtained via `waker()`.
*/
module sparkles.event_horizon.loop;

import core.stdc.errno : EAGAIN, ECANCELED, EINTR, ENOBUFS, ETIME;
import core.lifetime : move;
import core.time : Duration, MonoTime;

import std.experimental.allocator.mallocator : Mallocator;

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

/// The platform default backend's loop (tier A's public front door). The
/// backend is chosen per platform in `backend.select` (`UringBackend` on
/// Linux, `KqueueBackend` on macOS, `IocpBackend` on Windows; the
/// `EventHorizonLibkqueue` override forces kqueue on Linux).
version (Posix) version = EhDefaultLoop;
version (Windows) version = EhDefaultLoop;
version (EhDefaultLoop)
{
    import sparkles.event_horizon.backend.select : DefaultBackend;

    alias DefaultLoop = EventLoop!DefaultBackend;
}

/**
The tier-A event loop over a completion backend (SPEC §5.1), generic over
the `Allocator` its op-slot slab draws from (the composable-allocator
guidelines; `Mallocator` default).
*/
struct EventLoop(Backend, Allocator = Mallocator)
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
    /// precondition at higher tiers. An armed waker (SPEC §5.6) is loop
    /// infrastructure, not work — destroy disarms it itself.
    void destroy()
    in (_slab.liveCount == (_wakeArmed ? 1 : 0), "destroy with ops in flight")
    {
        if (!_open)
            return;
        disarmWaker();
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

    // Registered-buffer / provided-ring passthroughs exist only when the
    // backend supports them (io_uring); peer backends that don't advertise
    // them simply don't expose these methods (SPEC §3.1 — absence degrades,
    // never breaks).
    static if (__traits(hasMember, Backend, "registerBuffers"))
    {
        /// Registers `slabs` as kernel-pinned buffers on the backend
        /// (`BufferPool.register` drives this; SPEC §6.3).
        IoResult!void registerBuffers(scope ubyte[][] slabs)
            => _backend.registerBuffers(slabs);

        /// Releases the registered-buffer table.
        IoResult!void unregisterBuffers() => _backend.unregisterBuffers();
    }

    static if (__traits(hasMember, Backend, "registerBufRing"))
    {
        /// Registers a provided buffer ring for group `gid` (SPEC §6.4);
        /// `BufRing.register`-style callers drive this.
        IoResult!void registerBufRing(ushort gid, uint entries, void* ringAddr)
            => _backend.registerBufRing(gid, entries, ringAddr);

        /// Releases the provided buffer ring for group `gid`.
        IoResult!void unregisterBufRing(ushort gid) => _backend.unregisterBufRing(gid);
    }

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

    // Timers exist only when the backend can lower `OpTimeout` (io_uring's
    // in-ring TIMEOUT, kqueue's EVFILT_TIMER); a backend without them (the
    // current IOCP data path) simply doesn't expose the timer API.
    static if (canSubmitOp!(Backend, OpTimeout))
    {
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
        // EINTR is a spurious wakeup (a signal — e.g. the GC's suspend —
        // interrupted the wait), not a failure: drain whatever did arrive
        // and report the iteration; callers loop anyway.
        if (waited.hasError && waited.error.errnoValue != EINTR)
            return ioErr!RunStatus(waited.error);

        _dispatching = true;
        scope (exit) _dispatching = false;
        const n = _backend.reap((ref const RawCompletion c) { dispatch(c); });
        return ioOk(n > 0 ? RunStatus.dispatched : RunStatus.timedOut);
    }

    /// Runs until `stop()` or until drained (no live user/timer ops — an
    /// armed waker alone does not keep `run()` alive; SPEC §5.6).
    IoResult!void run()
    {
        for (;;)
        {
            if (inFlight == 0)
                return ioOk();
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

    /// Makes the next `runOnce` return `stopped`. Loop-thread callable
    /// (callbacks may call it); to stop from another thread, set it up as
    /// `loop.stop()` on the loop thread's behalf is not possible — instead
    /// pair a shared flag with `waker().wake()` (SPEC §5.4/§5.6).
    void stop()
    {
        _stopRequested = true;
    }

    // ── the external waker (SPEC §5.6) ──────────────────────────────────
    // Portable fd path where the backend lowers reads (uring, kqueue):
    // eventfd on Linux, a pipe elsewhere, drained by one persistently
    // re-armed internal read. Native path where the backend can post a wake
    // completion directly (IOCP). A backend with neither has no waker().

    version (Posix)
        private enum bool fdWaker = canSubmitOp!(Backend, OpRead);
    else
        private enum bool fdWaker = false;

    static if (fdWaker)
    {
        /**
        Returns the thread-safe wake handle, arming the wake channel on
        first call. The armed read is `OpClass.wake` infrastructure:
        excluded from `inFlight`, invisible to `run()`'s drained decision —
        but `runOnce(timeout)` on an otherwise-empty loop DOES wait, which
        is the "park until something external happens" entry point.
        */
        IoResult!Waker waker()
        {
            if (_wakeArmed)
                return ioOk(Waker(_wakeWriteFd));

            if (_wakeReadFd < 0)
            {
                auto opened = openWakeFds();
                if (opened.hasError)
                    return ioErr!Waker(opened.error);
            }
            const token = _slab.acquire(OpKind.read, OpClass.wake, null, null);
            if (!token)
                return ioErr!Waker(ENOBUFS, OpKind.read, IoErrorStage.submit,
                    "op slab full");
            auto slot = _slab.resolve(token);
            // The drain target lives in the slot's operand store — slab
            // memory, address-stable for the loop's whole life (§4.1).
            slot.pinned = (() @trusted => Buf.fromForeign(slot.operands.wake[], null))();
            if (!trySubmitWithRetry(OpRead(_wakeReadFd, Buf.init, ulong.max),
                    token, *slot))
            {
                _slab.release(token);
                return ioErr!Waker(EAGAIN, OpKind.read, IoErrorStage.submit,
                    "submission queue full");
            }
            _wakeArmed = true;
            return ioOk(Waker(_wakeWriteFd));
        }
    }
    else static if (hasNativeWake!Backend)
    {
        /// ditto — the backend posts wake completions natively (no armed op).
        IoResult!Waker waker()
        {
            if (_wakeArmed)
                return ioOk(_nativeWaker);
            const token = _slab.acquire(OpKind.nop, OpClass.wake, null, null);
            if (!token)
                return ioErr!Waker(ENOBUFS, OpKind.nop, IoErrorStage.submit,
                    "op slab full");
            auto w = _backend.nativeWaker(token);
            if (!w)
            {
                _slab.release(token);
                return ioErr!Waker(ENOBUFS, OpKind.nop, IoErrorStage.submit,
                    "backend wake-op slab full");
            }
            _wakeToken = token;
            _nativeWaker = w;
            _wakeArmed = true;
            return ioOk(w);
        }
    }

    /// User and timer ops currently in flight (an armed waker is excluded —
    /// infrastructure, not work; SPEC §5.6).
    uint inFlight() const => _slab.liveCount - (_wakeArmed ? 1 : 0);

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

        // The persistent wake op (SPEC §5.6): drain consumed; re-arm unless
        // tearing down. Wakes carry no payload by design.
        if (slot.cls == OpClass.wake)
        {
            static if (fdWaker)
            {
                if (_wakeShutdown || raw.res < 0)
                {
                    _slab.release(token);
                    _wakeArmed = false;
                }
                else if (!trySubmitWithRetry(
                        OpRead(_wakeReadFd, Buf.init, ulong.max), token, *slot))
                {
                    // SQ full even after a flush — degrade: the handle stays
                    // valid (writes accumulate); a later waker() re-arms.
                    _slab.release(token);
                    _wakeArmed = false;
                }
            }
            // Native-wake backends keep no armed op; nothing to re-arm.
            return;
        }

        // Internal completions (cancel bookkeeping) are consumed silently.
        if (slot.cls == OpClass.internal)
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

        // A buffer-selecting recv: recover the kernel-chosen buffer id from
        // the raw flags (SPEC §6.4); the caller leases it from the ring.
        if (flags & CompletionFlags.bufferSelected)
            done.bufferId = Backend.selectedBufferId(raw.rawFlags);

        if (isFinal)
            done.buf = move(slot.pinned);

        // Receive paths: the valid-byte count comes from the completion.
        if (raw.res > 0 && !done.buf.empty
            && (slot.kind == OpKind.read || slot.kind == OpKind.recv
                || slot.kind == OpKind.recvFrom))
            done.buf.length = cast(uint) raw.res <= done.buf.capacity
                ? cast(uint) raw.res : done.buf.capacity;

        // The datagram source address is read from the POSIX msghdr the
        // RECVMSG lowering filled (peer backends without recvmsg skip this).
        version (Posix)
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

    static if (fdWaker)
    {
        /// Opens the wake channel: an eventfd on Linux (8-byte counter,
        /// coalescing by construction), a non-blocking pipe elsewhere.
        IoResult!void openWakeFds() @trusted nothrow @nogc
        {
            version (linux)
            {
                import core.sys.linux.sys.eventfd : EFD_CLOEXEC, EFD_NONBLOCK, eventfd;

                const fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
                if (fd < 0)
                    return ioErr!void(24 /* EMFILE */, OpKind.read,
                        IoErrorStage.setup, "eventfd failed");
                _wakeReadFd = fd;
                _wakeWriteFd = fd;
                return ioOk();
            }
            else
            {
                import core.sys.posix.fcntl : F_SETFD, F_SETFL, FD_CLOEXEC,
                    O_NONBLOCK, fcntl;
                import core.sys.posix.unistd : pipe;

                int[2] fds;
                if (pipe(fds) != 0)
                    return ioErr!void(24 /* EMFILE */, OpKind.read,
                        IoErrorStage.setup, "wake pipe failed");
                foreach (fd; fds)
                    cast(void) fcntl(fd, F_SETFD, FD_CLOEXEC);
                cast(void) fcntl(fds[1], F_SETFL, O_NONBLOCK);
                _wakeReadFd = fds[0];
                _wakeWriteFd = fds[1];
                return ioOk();
            }
        }

        /// Unwinds the armed wake read by self-waking (the read completes
        /// normally; the dispatch branch releases instead of re-arming) —
        /// no cancel machinery, identical on every fd backend.
        void disarmWaker() @trusted
        {
            if (_wakeArmed)
            {
                _wakeShutdown = true;
                Waker(_wakeWriteFd).wake();
                while (_wakeArmed)
                {
                    auto waited = _backend.submitAndWait(1, null);
                    if (waited.hasError)
                        break; // leak the slot rather than hang teardown
                    cast(void) _backend.reap(
                        (ref const RawCompletion c) { dispatch(c); });
                }
                _wakeShutdown = false;
            }
            closeWakeFds();
        }

        void closeWakeFds() @trusted nothrow @nogc
        {
            import core.sys.posix.unistd : close;

            if (_wakeReadFd >= 0)
                cast(void) close(_wakeReadFd);
            if (_wakeWriteFd >= 0 && _wakeWriteFd != _wakeReadFd)
                cast(void) close(_wakeWriteFd);
            _wakeReadFd = -1;
            _wakeWriteFd = -1;
        }
    }
    else static if (hasNativeWake!Backend)
    {
        /// The native wake keeps no armed op — just release the routing slot.
        void disarmWaker() @safe nothrow @nogc
        {
            if (!_wakeArmed)
                return;
            _slab.release(_wakeToken);
            _wakeToken = OpToken.init;
            _nativeWaker = Waker.init;
            _wakeArmed = false;
        }
    }
    else
    {
        void disarmWaker() @safe pure nothrow @nogc
        {
        }
    }

    Backend _backend;
    OpSlab!Allocator _slab;
    bool _open;
    bool _dispatching;
    bool _stopRequested;
    bool _wakeArmed;
    bool _wakeShutdown;
    static if (fdWaker)
    {
        int _wakeReadFd = -1;
        int _wakeWriteFd = -1;
    }
    else static if (hasNativeWake!Backend)
    {
        OpToken _wakeToken;
        Waker _nativeWaker;
    }
}

version (linux)  :  // tests drive the uring backend directly

version (unittest)
{
    import sparkles.event_horizon.errors : skipReason;
    import sparkles.test_runner.skip : skipTest;

    /// Creates a loop for a test, or SKIPs it (no io_uring / old kernel).
    /// Call before arming any `scope (exit)`: it does not return on the skip.
    private void createOrSkip(ref DefaultLoop loop, LoopConfig cfg = LoopConfig())
        @safe nothrow @nogc
    {
        auto r = DefaultLoop.create(loop, cfg);
        if (r.hasError)
        {
            // Asserted before the skip, and deliberately not folded into it:
            // §3.4 says creation can only fail these two ways, so a violated
            // contract must still fail the test rather than be laundered
            // into a skip.
            assert(r.error.stage == IoErrorStage.setup
                || r.error.stage == IoErrorStage.probe);
            skipTest(skipReason(r.error));
        }
    }
}

@("loop.nop.callbackRoundTrip")
@safe nothrow @nogc
unittest
{
    DefaultLoop loop;
    createOrSkip(loop);

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
    createOrSkip(loop);

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
    createOrSkip(loop);

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
    createOrSkip(loop);

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
    createOrSkip(loop);

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

    BufferPool!() pool;
    assert(!BufferPool!().create(pool, 1, 64).hasError);

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
    createOrSkip(loop);

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
    createOrSkip(loop);

    auto status = loop.runOnce();
    assert(status.hasValue && status.value == RunStatus.drained);
    assert(!loop.run().hasError);
}

@("loop.registeredBuffers.fixedReadPath")
@safe nothrow @nogc
unittest
{
    import sparkles.event_horizon.buffer : BufferPool, BufOrigin;

    DefaultLoop loop;
    createOrSkip(loop);

    if (!loop.caps().registeredBuffers)
    {
        // Tear down explicitly: an `Error` unwinding out of a `nothrow` frame
        // is not guaranteed to run destructors, so the usual RAII teardown
        // cannot be relied on here. `destroy` is idempotent, so calling it
        // and letting `~this` run too is correct.
        loop.destroy();
        skipTest("registered buffers unsupported");
    }

    BufferPool!() pool;
    assert(!BufferPool!().create(pool, 2, 64).hasError);
    assert(!pool.register(loop).hasError);
    scope (exit) cast(void) loop.unregisterBuffers();

    // Acquired buffers now carry the registered origin — lowering picks
    // READ_FIXED automatically.
    auto acquired = pool.acquire();
    assert(acquired.hasValue);
    assert(acquired.value.origin == BufOrigin.registered);
    assert(acquired.value.bufIndex < 2);

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

    static immutable payload = cast(immutable ubyte[]) "fixed buffer";
    const wrote = (() @trusted {
        import core.sys.posix.unistd : write;

        return write(fds[1], payload.ptr, payload.length);
    })();
    assert(wrote == payload.length);

    static struct Seen
    {
        int calls;
        uint bytes;
        bool ok;
    }

    static void onRead(void* ctx, ref Completion done) nothrow @nogc
    {
        auto seen = cast(Seen*) ctx;
        ++seen.calls;
        auto r = done.result;
        if (r.hasError)
            return;
        seen.bytes = r.value;
        seen.ok = done.buf[] == payload[];
    }

    Seen seen;
    auto h = (() @trusted => loop.submit(
        OpRead(fds[0], move(acquired.value), ulong.max), &onRead, &seen))();
    assert(h.hasValue);
    assert(!loop.run().hasError);
    assert(seen.calls == 1 && seen.bytes == payload.length && seen.ok,
        "READ_FIXED delivered the bytes through the registered buffer");
}

@("loop.waker.crossThreadWakesBlockedWait")
@system
unittest
{
    import core.thread : Thread;
    import core.time : msecs, seconds;

    DefaultLoop loop;
    createOrSkip(loop);

    auto w = loop.waker();
    assert(w.hasValue);
    assert(loop.inFlight == 0, "an armed waker is not user work");

    // A foreign thread wakes the loop after a delay; the blocked wait must
    // return well before its own deadline.
    auto waker = w.value;
    auto t = new Thread({
        Thread.sleep(20.msecs);
        waker.wake();
    });
    t.start();

    const before = loop.now();
    // Spurious EINTR wakeups (the GC suspending this thread while parked in
    // io_uring_enter — tests run in parallel) surface as timedOut; loop
    // until the real wake arrives.
    RunStatus st;
    do
    {
        auto status = loop.runOnce(5.seconds);
        assert(status.hasValue);
        st = status.value;
    }
    while (st == RunStatus.timedOut && loop.now() - before < 5.seconds);
    const elapsed = loop.now() - before;
    t.join();

    assert(st == RunStatus.dispatched,
        "the wake surfaced as a dispatched iteration");
    assert(elapsed >= 15.msecs && elapsed < 2.seconds,
        "the wait ended on the wake, not the deadline");
}

@("loop.waker.wakeBeforeWaitCoalesces")
@safe nothrow @nogc
unittest
{
    import core.time : seconds;

    DefaultLoop loop;
    createOrSkip(loop);

    auto w = loop.waker();
    assert(w.hasValue);

    // Several wakes before any wait: the next wait returns immediately,
    // exactly once — eventfd coalescing.
    w.value.wake();
    w.value.wake();
    w.value.wake();

    auto first = loop.runOnce(1.seconds);
    assert(first.hasValue && first.value == RunStatus.dispatched);

    // run() with only the armed waker left returns drained-equivalent
    // immediately: an armed waker alone is not work.
    assert(!loop.run().hasError);
    assert(loop.inFlight == 0);
}

@("loop.pollAdd.multishotReadinessStream")
@safe nothrow @nogc
unittest
{
    DefaultLoop loop;
    createOrSkip(loop);

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

    static struct Watch
    {
        int fires;
        bool sawMore;
        bool sawReadable;
        int readFd;
        DefaultLoop* loop;
        OpHandle handle;
    }

    static void onReady(void* ctx, ref Completion done) nothrow @nogc
    {
        auto w = cast(Watch*) ctx;
        if (done.res < 0)
            return; // the cancelled terminal completion
        ++w.fires;
        w.sawReadable |= (done.res & PollEvents.readable) != 0;
        w.sawMore |= !done.isFinal;
        // Drain the pipe so a level-triggered re-arm does not flood, then
        // end the stream after the first delivery.
        (() @trusted {
            import core.sys.posix.unistd : read;

            ubyte[8] sink;
            cast(void) read(w.readFd, sink.ptr, sink.length);
        })();
        cast(void) w.loop.cancel(w.handle);
    }

    Watch w;
    w.readFd = fds[0];
    w.loop = &loop;
    auto h = (() @trusted => loop.submit(
        OpPollAdd(fds[0], PollEvents.readable, true), &onReady, &w))();
    assert(h.hasValue);
    w.handle = h.value;

    const wrote = (() @trusted {
        import core.sys.posix.unistd : write;

        ubyte one = 1;
        return write(fds[1], &one, 1);
    })();
    assert(wrote == 1);

    assert(!loop.run().hasError);
    assert(w.fires >= 1, "readiness delivered");
    assert(w.sawReadable, "the completion res carries the ready mask");
    assert(w.sawMore, "multishot completions are flagged non-final");
    assert(loop.inFlight == 0);
}

@("loop.multishotAccept.streamsConnections")
@safe nothrow @nogc
unittest
{
    DefaultLoop loop;
    createOrSkip(loop);

    if (!loop.caps().multishotAccept)
    {
        loop.destroy(); // see loop.registeredBuffers.fixedReadPath
        skipTest("multishot accept unsupported");
    }

    // A loopback listener.
    int listenFd;
    ushort port;
    if (!(() @trusted {
        import core.sys.posix.arpa.inet : htonl, ntohs;
        import core.sys.posix.netinet.in_ : INADDR_LOOPBACK, sockaddr_in;
        import core.sys.posix.sys.socket;

        listenFd = socket(AF_INET, SOCK_STREAM, 0);
        if (listenFd < 0)
            return false;
        sockaddr_in a;
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(listenFd, cast(sockaddr*) &a, a.sizeof) != 0
            || listen(listenFd, 8) != 0)
            return false;
        socklen_t len = a.sizeof;
        getsockname(listenFd, cast(sockaddr*) &a, &len);
        port = ntohs(a.sin_port);
        return true;
    })())
        return;
    scope (exit) () @trusted {
        import core.sys.posix.unistd : close;

        close(listenFd);
    }();

    static struct Accepts
    {
        int count;
        bool sawMore;
        DefaultLoop* loop;
        OpHandle handle;
    }

    static void onAccept(void* ctx, ref Completion done) nothrow @nogc
    {
        auto a = cast(Accepts*) ctx;
        if (done.res < 0)
            return;
        ++a.count;
        if (!done.isFinal)
            a.sawMore = true; // CQE_F_MORE: the armed op stays live
        (() @trusted {
            import core.sys.posix.unistd : close;

            close(done.res); // close the accepted connection
        })();
        if (a.count >= 2)
            a.loop.cancel(a.handle); // stop the multishot stream
    }

    Accepts accepts;
    accepts.loop = &loop;
    auto h = (() @trusted => loop.submit(
        OpAcceptMultishot(listenFd), &onAccept, &accepts))();
    assert(h.hasValue);
    accepts.handle = h.value;

    // Two clients connect; one armed accept serves both.
    foreach (_; 0 .. 2)
        (() @trusted {
            import core.sys.posix.arpa.inet : htonl, htons;
            import core.sys.posix.netinet.in_ : INADDR_LOOPBACK, sockaddr_in;
            import core.sys.posix.sys.socket;
            import core.sys.posix.unistd : close;

            const c = socket(AF_INET, SOCK_STREAM, 0);
            sockaddr_in a;
            a.sin_family = AF_INET;
            a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            a.sin_port = htons(port);
            cast(void) connect(c, cast(sockaddr*) &a, a.sizeof);
            close(c);
        })();

    assert(!loop.run().hasError);
    assert(accepts.count == 2, "one armed accept served both connections");
    assert(accepts.sawMore, "non-final completions carry CQE_F_MORE");
    assert(loop.inFlight == 0);
}
