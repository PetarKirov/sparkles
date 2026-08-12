/**
The macOS/BSD peer backend: a completion-synthesizing proactor over kqueue
readiness (SPEC §3.5, PLAN M10). kqueue is a $(I readiness) interface, so
unlike io_uring and IOCP this backend does the I/O itself: `trySubmit`
registers interest (`EVFILT_READ`/`EVFILT_WRITE`, `EV_DISPATCH`) and remembers the
op; when `kevent` reports the fd ready, the backend performs the actual
`recv`/`send` syscall and emits the resulting `RawCompletion` — the
Boost.Asio "emulated proactor" shape. Regular files have no readiness and
would go to a small worker pool (the fs verbs, deferred with the M7-domain
portability).

Each pending op lives in a backend-owned freelist slab. The kevent `udata`
carries a *slot token* — the slab index plus a generation counter — rather than
the slot's address, so a ready event maps back to the op's `user_data` only
while that slot still holds the op the registration was made for. See
`slotToken`/`opFor`. `nop` is synthesized inline (no fd), the same way IOCP posts to its
port.

Registration is $(I batched) (O27): `trySubmit` appends a `kevent_t` to a
pending change list and `submitAndWait` hands that list to the kernel as the
same `kevent(2)` call that collects events, so a steady-state loop pays one
syscall per turn rather than one per op — the call shape libdispatch's
`_dispatch_kq_drain` is built on. Two consequences worth knowing at the call
site: a `false` from `trySubmit` means only $(I a submission resource is full,
call `flush()`), never that the kernel rejected the registration; and a
rejected registration comes back as an ordinary completion carrying `-errno`
(an `EV_ERROR` change-list entry), exactly as a bad SQE does on io_uring.

Op coverage: `nop`, `recv`/`send`, `read`/`write`, `accept`, non-blocking
`connect` (`EVFILT_WRITE` + `SO_ERROR`), and timers (`EVFILT_TIMER`). The full
`EventLoop!KqueueBackend` integration — tier-A loop + tier-B fibers + the
`io` verbs — is verified two ways: the data path on real macOS
(`scripts/verify-kqueue-macos.sh`), and the whole stack via a fiber-echo on
Linux over mheily/libkqueue —
`dub run --single examples/fiber-echo.d -b checked -c libkqueue`. The
regular-file worker pool is the remaining refinement.
*/
module sparkles.event_horizon.backend.kqueue;

// The kqueue backend is macOS/BSD-native; `EventHorizonLibkqueue` also builds
// it on Linux over mheily/libkqueue (an epoll shim), so the full
// `EventLoop!KqueueBackend` integration can be tested on Linux CI. Android
// ships the same backend + shim combination as its DEFAULT (io_uring is
// seccomp-denied for apps; the APK links libkqueue statically).
version (OSX)
    version = EventHorizonKqueue;
version (Android)
    version = EventHorizonKqueue;
version (EventHorizonLibkqueue)
    version = EventHorizonKqueue;

version (EventHorizonKqueue)  :

import core.stdc.errno : EAGAIN, ECANCELED, EINPROGRESS, errno, ESRCH;
import core.sys.posix.sys.socket : accept, connect, recv, send;

import sparkles.event_horizon.backend.concept : BackendConfig, RawCompletion, Waker;
import sparkles.event_horizon.backend.probe : BackendCaps, BackendId, LoopMode;
import sparkles.event_horizon.errors;
import sparkles.event_horizon.op : KernelTimespec, OpAccept, OpConnect, OpNop,
    OpPollAdd, OpRead, OpRecv, OpSend, OpSlot, OpTimeout, OpToken, OpWaitid,
    OpWrite, PollEvents;

// ── minimal kqueue bindings (the exact BSD struct layout) ───────────────────

private:

extern (C) nothrow @nogc
{
    int kqueue();
    int kevent(int kq, const(kevent_t)* changelist, int nchanges,
        kevent_t* eventlist, int nevents, const(timespec)* timeout);
    int close(int fd);
    // Declared here rather than taken from druntime: core.sys.posix.sys.wait
    // exposes `waitid` only under `version (linux)` in the versions this
    // project builds against, and the BSD/macOS signature is identical.
    int waitid(int idtype, uint id, void* infop, int options);
}

struct kevent_t
{
    size_t ident;    // fd
    short filter;    // EVFILT_READ / EVFILT_WRITE
    ushort flags;    // EV_ADD | EV_DISPATCH | EV_DELETE | EV_ERROR
    uint fflags;
    ptrdiff_t data;  // bytes ready (read) / space (write)
    void* udata;     // our pending-op pointer
}

struct timespec
{
    long tv_sec;
    long tv_nsec;
}

enum short EVFILT_READ = -1;
enum short EVFILT_WRITE = -2;
enum short EVFILT_PROC = -5;
enum short EVFILT_TIMER = -7;
enum short EVFILT_USER = -10;
/// `EVFILT_PROC` fflag: the process exited. The only note this backend asks
/// for — fork/exec tracking has no op to lower onto.
enum uint NOTE_EXIT = 0x8000_0000;
/// `EVFILT_USER` fflag: post a coalesced wake. What `Waker.wake` writes.
enum uint NOTE_TRIGGER = 0x0100_0000;
enum ushort EV_ADD = 0x0001;
enum ushort EV_DELETE = 0x0002;
enum ushort EV_ENABLE = 0x0004;
enum ushort EV_ONESHOT = 0x0010;
enum ushort EV_CLEAR = 0x0020;
enum ushort EV_DISPATCH = 0x0080;
enum ushort EV_ERROR = 0x4000;
enum ushort EV_EOF = 0x8000;

/// A backend-owned pending op; its address is the kevent `udata`.
struct KqOp
{
    ulong token;   // the op's user_data
    int fd;        // socket / timer ident
    ubyte* buf;    // recv/send/read/write buffer (null for accept/connect/timer)
    uint len;      // buffer length
    OpKindLocal kind;
    short filter;  // the registered filter (for EV_DELETE on cancel)
    uint nextFree; // freelist link (uint.max = none)
    bool live;     // acquired and not yet released — the cancel lookup's guard
    bool multishot; // poll_ only: the registration persists across completions
    // waitid only: the reap is performed when NOTE_EXIT arrives, so its
    // arguments have to survive the wait. `fd` carries the pid and `buf` the
    // caller's `siginfo_t*`.
    int idType;
    int waitOptions;
}

enum OpKindLocal : ubyte
{
    recv,
    send,
    read_,
    write_,
    accept_,
    connect_,
    timer,
    poll_,
    waitid_,
    wake,
}

public:

/// The kqueue backend. Thread-affine (one kqueue per loop thread).
struct KqueueBackend
{
    @disable this(this);

    /// Creates the kqueue and the pending-op slab.
    IoResult!void open(in BackendConfig cfg) @trusted nothrow @nogc
    {
        import core.memory : pureMalloc;

        _kq = kqueue();
        if (_kq < 0)
            return ioErr!void(errno, OpKind.none, IoErrorStage.setup,
                "kqueue() failed");

        const cap = cfg.cqEntries != 0 ? cfg.cqEntries : 2 * cfg.sqEntries;
        _cap = cap != 0 ? cap : 256;
        _ops = (cast(KqOp*) pureMalloc(_cap * KqOp.sizeof))[0 .. _cap];
        _gens = (cast(uint*) pureMalloc(_cap * uint.sizeof))[0 .. _cap];
        if (_ops.ptr is null || _gens.ptr is null)
        {
            if (_ops.ptr !is null)
                pureFreeSlab(_ops.ptr);
            if (_gens.ptr !is null)
                pureFreeSlab(_gens.ptr);
            _ops = null;
            _gens = null;
            .close(_kq);
            _kq = -1;
            return ioErr!void(12, OpKind.none, IoErrorStage.setup,
                "op-context slab allocation failed");
        }
        foreach (i; 0 .. _cap)
        {
            _ops[i] = KqOp.init;
            _ops[i].nextFree = i + 1 == _cap ? uint.max : cast(uint)(i + 1);
            // Generations start at 1 so an all-zero `udata` — the value a
            // registration this backend did not make would carry — decodes to
            // generation 0 and matches nothing.
            _gens[i] = 1;
        }
        _freeHead = 0;
        _pendCount = 0;
        _changeCount = 0;

        _caps.backend = BackendId.kqueue;
        _caps.mode = LoopMode.cooperative;
        return ioOk();
    }

    /// Closes the kqueue and frees the slab.
    void close() @trusted nothrow @nogc
    {
        import core.memory : pureFree;

        // Pending changes name a kqueue that is about to stop existing.
        _changeCount = 0;
        if (_ops.ptr !is null)
        {
            pureFree(_ops.ptr);
            _ops = null;
        }
        if (_gens.ptr !is null)
        {
            pureFree(_gens.ptr);
            _gens = null;
        }
        if (_kq >= 0)
        {
            .close(_kq);
            _kq = -1;
        }
    }

    /// The negotiated capabilities (kqueue: readiness-synthesized proactor).
    ref const(BackendCaps) caps() const return @safe pure nothrow @nogc => _caps;

    /// Maps raw completion flags to the portable set. The only raw flag this
    /// backend produces is its own more-marker on retained multishot polls.
    import sparkles.event_horizon.op : CompletionFlags;

    CompletionFlags mapFlags(uint rawFlags) const @safe pure nothrow @nogc
        => (rawFlags & rawFlagMore) ? CompletionFlags.more : CompletionFlags.init;

    /// Never called (kqueue sets no buffer-select flag); present for the
    /// dispatch's static shape.
    static ushort selectedBufferId(uint) @safe pure nothrow @nogc => 0;

    // ── lowering: register readiness interest, remember the op ──────────────

    /**
    Persistent `EVFILT_USER` knote bound to `token` (O29, SPEC §5.6).
    `Waker.wake` is a `NOTE_TRIGGER` on this ident — thread-safe, coalescing,
    no payload. The ADD is flushed before the handle is handed out so a
    wake-before-wait is not `ENOENT`.
    */
    Waker nativeWaker(OpToken token) @trusted nothrow @nogc
    {
        auto op = acquire();
        if (op is null)
            return Waker.init;
        *op = KqOp(token.raw, wakeIdent, null, 0, OpKindLocal.wake,
            EVFILT_USER, uint.max);
        if (!armFilter(op, EVFILT_USER, cast(ushort)(EV_ADD | EV_CLEAR)))
            return Waker.init;
        auto flushed = flush();
        if (flushed.hasError)
        {
            release(op, true);
            return Waker.init;
        }
        Waker w;
        w.fd = _kq;
        w.ident = wakeIdent;
        return w;
    }

    /// A NOP: no fd — synthesize a completion inline.
    bool trySubmit(in OpNop, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        if (_synthCount >= _synth.length)
            return false;
        _synth[_synthCount++] = RawCompletion(token.raw, 0, 0);
        return true;
    }

    /// A socket receive: register `EVFILT_READ`, dispatched.
    bool trySubmit(in OpRecv o, OpToken token, ref OpSlot slot) @trusted nothrow @nogc
    {
        auto op = acquire();
        if (op is null)
            return false;
        auto space = slot.pinned.space();
        *op = KqOp(token.raw, o.fd, space.ptr, cast(uint) space.length,
            OpKindLocal.recv, EVFILT_READ, uint.max);
        return armFilter(op, EVFILT_READ);
    }

    /// A socket send: register `EVFILT_WRITE`, dispatched.
    bool trySubmit(in OpSend o, OpToken token, ref OpSlot slot) @trusted nothrow @nogc
    {
        auto op = acquire();
        if (op is null)
            return false;
        auto bytes = slot.pinned[];
        *op = KqOp(token.raw, o.fd, cast(ubyte*) bytes.ptr, cast(uint) bytes.length,
            OpKindLocal.send, EVFILT_WRITE, uint.max);
        return armFilter(op, EVFILT_WRITE);
    }

    /// A positioned read (pipe/socket): `EVFILT_READ` + `read`.
    bool trySubmit(in OpRead o, OpToken token, ref OpSlot slot) @trusted nothrow @nogc
    {
        auto op = acquire();
        if (op is null)
            return false;
        auto space = slot.pinned.space();
        *op = KqOp(token.raw, o.fd, space.ptr, cast(uint) space.length,
            OpKindLocal.read_, EVFILT_READ, uint.max);
        return armFilter(op, EVFILT_READ);
    }

    /// A positioned write (pipe/socket): `EVFILT_WRITE` + `write`.
    bool trySubmit(in OpWrite o, OpToken token, ref OpSlot slot) @trusted nothrow @nogc
    {
        auto op = acquire();
        if (op is null)
            return false;
        auto bytes = slot.pinned[];
        *op = KqOp(token.raw, o.fd, cast(ubyte*) bytes.ptr, cast(uint) bytes.length,
            OpKindLocal.write_, EVFILT_WRITE, uint.max);
        return armFilter(op, EVFILT_WRITE);
    }

    /// Accept: register `EVFILT_READ` on the listener; on readiness `accept`.
    bool trySubmit(in OpAccept o, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        auto op = acquire();
        if (op is null)
            return false;
        *op = KqOp(token.raw, o.listenFd, null, 0, OpKindLocal.accept_,
            EVFILT_READ, uint.max);
        return armFilter(op, EVFILT_READ);
    }

    /// Connect: start a non-blocking `connect`; if it is still in progress,
    /// register `EVFILT_WRITE` and check `SO_ERROR` on writability. `addr` is
    /// consumed synchronously here, so the descriptor may die immediately.
    bool trySubmit(in OpConnect o, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        import core.sys.posix.netinet.in_ : sockaddr;

        setNonBlocking(o.fd);
        const rc = connect(o.fd, cast(const sockaddr*) o.addr.storage.ptr, o.addr.len);
        if (rc == 0)
        {
            if (_synthCount >= _synth.length)
                return false;
            _synth[_synthCount++] = RawCompletion(token.raw, 0, 0); // connected inline
            return true;
        }
        if (errno != EINPROGRESS)
        {
            if (_synthCount >= _synth.length)
                return false;
            _synth[_synthCount++] = RawCompletion(token.raw, -errno, 0);
            return true;
        }
        auto op = acquire();
        if (op is null)
            return false;
        *op = KqOp(token.raw, o.fd, null, 0, OpKindLocal.connect_, EVFILT_WRITE, uint.max);
        return armFilter(op, EVFILT_WRITE);
    }

    /**
    Lowers a child reap onto `EVFILT_PROC`/`NOTE_EXIT`, then performs the
    `waitid` when the exit notification arrives.

    Two-step because the two kernels answer different questions: io_uring's
    `WAITID` both waits and reaps, while kqueue only reports that the process
    ended — so the reap itself is the completion's work (see `performOp`), and
    the caller's `siginfo_t*` must stay alive until then, not merely until
    submission.

    $(B The already-exited case is the interesting one): a child that died
    before the op was submitted has no process left to watch, so the `EV_ADD`
    is rejected with `ESRCH`. That is not an error — it is the common case for
    a reap issued after the exit was noticed. Since O27 batched the change
    list, the rejection is no longer visible here; it arrives as the
    `EV_ERROR` entry `ingest` turns into this op's completion, and that is
    where the inline reap now happens.
    */
    bool trySubmit(in OpWaitid o, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        auto op = acquire();
        if (op is null)
            return false;
        *op = KqOp(token.raw, cast(int) o.id, cast(ubyte*) o.siginfo, 0,
            OpKindLocal.waitid_, EVFILT_PROC, uint.max);
        op.idType = o.idType;
        op.waitOptions = o.options;
        return armFilter(op, EVFILT_PROC, cast(ushort)(EV_ADD | EV_DISPATCH), NOTE_EXIT);
    }

    /// Foreign-fd readiness: the readiness event IS the completion — no
    /// syscall is performed on the fd (SPEC §15.1). Multishot keeps the op
    /// live and re-arms with `EV_ENABLE` after each delivery (O28).
    bool trySubmit(in OpPollAdd o, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        auto op = acquire();
        if (op is null)
            return false;
        const filter = (o.events & PollEvents.writable) ? EVFILT_WRITE : EVFILT_READ;
        *op = KqOp(token.raw, o.fd, null, 0, OpKindLocal.poll_, filter, uint.max);
        op.multishot = o.multishot;
        return armFilter(op, filter, cast(ushort)(EV_ADD | EV_DISPATCH));
    }

    /// A relative timer via `EVFILT_TIMER` (unique ident from the op index).
    bool trySubmit(in OpTimeout o, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        auto op = acquire();
        if (op is null)
            return false;
        const ident = cast(int)(_timerBase + (op - _ops.ptr));
        *op = KqOp(token.raw, ident, null, 0, OpKindLocal.timer, EVFILT_TIMER, uint.max);
        // Round UP to the millisecond: a timer must never fire EARLY, and
        // truncation makes every fractional-ms deadline do exactly that
        // (found by absolute-deadline pacing: sleepUntil remainders are
        // fractional, and early wakes let a Ticker lap its own grid).
        const ms = o.rel.tv_sec * 1000 + (o.rel.tv_nsec + 999_999) / 1_000_000;
        return armTimer(op, ms < 0 ? 0 : ms);
    }

    /**
    Hands the accumulated change list to the kernel without waiting, and
    returns the number of change entries submitted.

    "Change entries", not ops: one op is one entry today, but a cancel adds an
    `EV_DELETE` of its own and O28's re-arm will add more, so the two counts
    are not the same quantity. `concept.d` states the contract as
    submission-side units flushed, backend-defined — no caller reads the number
    beyond "did progress happen".

    A zero timeout means this can still collect events that were already
    queued; they are stashed for `reap` exactly as `submitAndWait`'s are. It
    has to: the `EV_ERROR` entries reporting rejected changes come back through
    the same event list.
    */
    IoResult!uint flush() @trusted nothrow @nogc
    {
        if (_changeCount == 0)
            return ioOk(0u);
        const before = _changeCount;
        timespec zero;
        if (drainKevent(&zero) < 0)
            return ioErr!uint(errno, OpKind.none, IoErrorStage.submit,
                "kevent (change flush) failed");
        // Not `before`: `drainKevent` declines to run at all when there is no
        // room left to stash completions, and reporting a flush that did not
        // happen is how a caller ends up retrying a submit that cannot succeed.
        return ioOk(before - _changeCount);
    }

    /**
    Submits the pending change list and waits for readiness (or `deadline`) in
    $(I one) `kevent(2)`, performs the ready ops' syscalls, and stashes their
    completions for `reap`. Already-stashed completions are delivered without
    waiting.
    */
    IoResult!uint submitAndWait(uint want, scope const KernelTimespec* deadline)
        @trusted nothrow @nogc
    {
        // Completions already in hand short-circuit the *wait* — but not the
        // change list. Returning here without flushing would starve every
        // pending registration for as long as synthesized work keeps arriving,
        // and synthesized work arrives from `nop`, from an inline `connect`,
        // and from every cancellation.
        if (_synthCount > 0 || _readyCount > 0)
        {
            auto f = flush();
            if (f.hasError)
                return f;
            return ioOk(_synthCount + _readyCount);
        }

        // libkqueue 2.7.0 writes EV_ERROR receipts in copyin, then waits, and
        // a wait-timeout returns 0 — hiding those receipts from the return
        // value. `drainKevent` harvests them from the buffer, but only after
        // the wait returns, so a rejected change would sit on the caller's
        // deadline (the 2 s stall the batched-submission example saw). Darwin
        // returns the EV_ERROR as n > 0 without waiting; this prelude is the
        // shim-only tax. A zero-timeout drain applies the change list and
        // lets the harvest run; already-ready fds still complete in that
        // same call (epoll reports them at timeout 0).
        version (EventHorizonLibkqueue)
        {
            if (_changeCount > 0)
            {
                timespec zero;
                if (drainKevent(&zero) < 0)
                    return ioErr!uint(errno, OpKind.none, IoErrorStage.submit,
                        "kevent failed");
                if (_synthCount + _readyCount > 0)
                    return ioOk(_synthCount + _readyCount);
            }
        }

        timespec ts;
        const(timespec)* tsp;
        if (deadline !is null)
        {
            ts = timespec(deadline.tv_sec, deadline.tv_nsec);
            tsp = &ts;
        }
        if (drainKevent(tsp) < 0)
            return ioErr!uint(errno, OpKind.none, IoErrorStage.submit, "kevent failed");
        return ioOk(_synthCount + _readyCount);
    }

    /// Non-blocking drain: the synthesized completions plus the readiness ones.
    uint reap(Sink)(scope Sink sink) @trusted
    {
        uint n;
        foreach (i; 0 .. _synthCount)
        {
            const c = _synth[i];
            sink(c);
            ++n;
        }
        _synthCount = 0;
        foreach (i; 0 .. _readyCount)
        {
            const c = _ready[i];
            sink(c);
            ++n;
        }
        _readyCount = 0;
        return n;
    }

    /**
    Cancels an in-flight op: `EV_DELETE` its registered filter, then synthesize
    the two completions io_uring's `ASYNC_CANCEL` would have produced — a
    terminal `-ECANCELED` for the target, and success for the cancel op itself.

    The synthetic completions are what make this work: `submitAndWait`
    short-circuits while `_synthCount > 0`, so the loop wakes immediately
    instead of staying in `kevent` until the target's own timeout. That
    unblocking is the whole point — a fiber parked on a long sleep must unwind
    when a sibling fails (SPEC §8), and it is why this must not be a stub.

    The delete goes through the same change list as the registration it
    undoes, so their order is a property of one FIFO array rather than a rule
    to remember: a submit-then-cancel before any wait would otherwise race its
    own `EV_ADD` and leave a registration behind. Better still, when that
    `EV_ADD` has not reached the kernel yet there is nothing to delete —
    `dropPendingChange` removes it and no delete is appended at all.

    Returns `false` when the target is not live (already completed, or an
    unknown token) or when either submission resource is full — a truthful
    `false`, because a cancel that reports success while doing nothing fails
    silently at the call site.
    */
    bool trySubmitCancel(OpToken cancelSlot, OpToken target) @trusted nothrow @nogc
    {
        auto op = findLive(target.raw);
        if (op is null)
            return false; // already completed, or never ours
        // Both completions must fit, or the target would be cancelled with no
        // terminal completion — a permanently parked fiber.
        if (_synthCount + 2 > _synth.length)
            return false;

        // Before `release`, which bumps the generation and so changes the token.
        if (!dropPendingChange(slotToken(op)))
        {
            // Timer idents live in their own range (see `armTimer`); everything
            // else is registered by fd.
            const ident = op.kind == OpKindLocal.timer
                ? cast(size_t)(_timerBase + (op - _ops.ptr))
                : cast(size_t) op.fd;
            // A null `udata` on purpose: the delete may come back as an
            // `EV_ERROR`/`ENOENT` entry when the knote already fired and is
            // queued, and `ingest` must ignore that rather than mistake it for
            // a rejected registration — the op's terminal completion is the
            // synthetic `-ECANCELED` below, exactly once, either way.
            if (!enqueueChange(ident, op.filter, EV_DELETE, 0, 0, null))
                return false;
        }

        _synth[_synthCount++] = RawCompletion(op.token, -ECANCELED, 0);
        release(op);
        _synth[_synthCount++] = RawCompletion(cancelSlot.raw, 0, 0);
        return true;
    }

private:
    /**
    The one `kevent(2)` this backend makes: the accumulated change list goes
    down, whatever is ready comes back, and the returned events are ingested.
    Returns the raw `kevent` result (`< 0` = the call itself failed).

    Bounded by the room left in `_ready`: the caller must reap before the
    backend can take another full batch. Zero room is not starvation — there
    are already `readyCap` completions to dispatch, and the loop reaps every
    turn — but it does mean the change list waits one turn, so `flush`
    truthfully reports zero submitted.
    */
    int drainKevent(scope const(timespec)* tsp) @trusted nothrow @nogc
    {
        const room = readyCap - _readyCount;
        if (room == 0)
            return 0;

        // Never send more changes than event slots. A rejected change that
        // cannot fit in the eventlist makes `kevent` return -1 (Darwin:
        // `EBADF`; libkqueue: `EFAULT`) instead of an `EV_ERROR` entry, and
        // the op would stay live forever. libkqueue's own comment is the
        // same rule: "always provide a kevent array with >= entries as the
        // changelist" (`src/common/kevent.c`, `kevent_copyin`).
        const pending = _changeCount;
        const nchanges = pending < room ? pending : room;
        const nevents = room;

        kevent_t[readyCap] evs = void;
        // Zero the prefix we might harvest. libkqueue 2.7.0 `kevent_copyin`
        // writes `EV_ERROR` receipts into the eventlist, then
        // `kevent_wait` times out and the public `kevent` returns 0 —
        // discarding the count but leaving the entries in the buffer. Darwin
        // returns them as `n > 0` and never needs the harvest.
        evs[0 .. nchanges] = kevent_t.init;

        const n = kevent(_kq, nchanges ? _changes.ptr : null, cast(int) nchanges,
            evs.ptr, cast(int) nevents, tsp);

        // Consumed either way, including on failure: `kevent` applies the
        // sent prefix *before* it waits. Re-sending a prefix the kernel
        // already has would re-register rather than retry. The unsent tail
        // stays, in order — the FIFO is the submit-then-cancel guarantee.
        if (nchanges < pending)
        {
            foreach (i; 0 .. pending - nchanges)
                _changes[i] = _changes[nchanges + i];
        }
        _changeCount = pending - nchanges;

        int delivered = n;
        if (n == 0 && nchanges > 0)
        {
            delivered = 0;
            foreach (i; 0 .. nchanges)
            {
                if (!(evs[i].flags & EV_ERROR))
                    break; // copyin writes receipts sequentially from slot 0
                ++delivered;
            }
        }
        if (delivered <= 0)
            return n;
        foreach (i; 0 .. delivered)
            ingest(evs[i]);
        return delivered;
    }

    /// Turns one delivered `kevent_t` into a stashed completion (or drops it).
    void ingest(ref const kevent_t ev) @trusted nothrow @nogc
    {
        // Darwin (and libkqueue) deliver EVFILT_USER with a null udata —
        // probed: ident/filter come back, udata does not. Identify the
        // persistent wake knote by ident instead of the slot token.
        if (ev.filter == EVFILT_USER && ev.ident == wakeIdent)
        {
            auto wakeOp = findWake();
            if (wakeOp is null)
                return;
            pushReady(RawCompletion(wakeOp.token, 0, 0));
            return;
        }

        auto op = opFor(ev.udata);
        if (op is null)
            return; // a stale registration, a cancel's EV_DELETE receipt, or not ours

        if (ev.flags & EV_ERROR)
        {
            // The kernel rejected a *change* entry: the registration never
            // happened, so no event will ever arrive for it and this is the
            // op's terminal completion. That is O27's contract repair — a bad
            // registration fails as a completion, the way a bad SQE does on
            // io_uring, instead of as a `false` the loop reads as backpressure
            // and retries forever.
            int res = -cast(int) ev.data;
            // ESRCH on an `EVFILT_PROC` add is not a failure: the child is
            // already gone, so there is nothing left to watch and the reap can
            // be performed right here (see `trySubmit(OpWaitid)`).
            if (op.kind == OpKindLocal.waitid_ && ev.data == ESRCH)
                res = doWaitid(op.idType, op.fd, cast(void*) op.buf, op.waitOptions);
            pushReady(RawCompletion(op.token, res, 0));
            release(op);
            return;
        }

        // A multishot poll's knote is disabled by EV_DISPATCH, not consumed.
        // Re-arm with EV_ENABLE so the next edge is a change entry rather than
        // a fresh add (O28). One-shot ops delete on release instead.
        const retained = op.kind == OpKindLocal.poll_ && op.multishot;
        pushReady(RawCompletion(op.token, performOp(op, ev), retained ? rawFlagMore : 0));
        if (retained)
        {
            // drainKevent consumed the sent prefix before ingest, so there is
            // always room for one re-arm per delivered event (same accounting
            // as the delete in `release`).
            cast(void) enqueueChange(cast(size_t) op.fd, op.filter,
                cast(ushort)(EV_ENABLE | EV_DISPATCH), 0, 0, slotToken(op));
        }
        else
            release(op, true);
    }

    /// Stashes a completion for `reap`. `drainKevent` never asks the kernel for
    /// more events than `_ready` can take, so the guard is a belt-and-braces
    /// invariant check rather than a policy.
    void pushReady(RawCompletion c) @safe nothrow @nogc
    in (_readyCount < readyCap, "ready ring overflowed its reserved room")
    {
        if (_readyCount < readyCap)
            _ready[_readyCount++] = c;
    }

    /// Appends one entry to the pending change list; `false` = the list is
    /// full, which is what makes `trySubmit` return `false` (flush and retry).
    bool enqueueChange(size_t ident, short filter, ushort flags, uint fflags,
        ptrdiff_t data, void* udata) @safe nothrow @nogc
    {
        if (_changeCount >= maxChanges)
            return false;
        auto c = &_changes[_changeCount++];
        c.ident = ident;
        c.filter = filter;
        c.flags = flags;
        c.fflags = fflags;
        c.data = data;
        c.udata = udata;
        return true;
    }

    /// Removes a not-yet-submitted change carrying `udata`, if any. Linear and
    /// order-preserving: the list is small, cancellation is rare, and the FIFO
    /// order is the guarantee the whole batching scheme rests on.
    bool dropPendingChange(scope const(void)* udata) @trusted nothrow @nogc
    {
        foreach (i; 0 .. _changeCount)
        {
            if (_changes[i].udata !is udata)
                continue;
            foreach (j; i + 1 .. _changeCount)
                _changes[j - 1] = _changes[j];
            --_changeCount;
            return true;
        }
        return false;
    }

    /// Performs the actual syscall for a now-ready op; returns the completion
    /// `res` (bytes / new fd / 0 / -errno). Change-list rejections never reach
    /// here — `ingest` completes those directly.
    int performOp(KqOp* op, ref const kevent_t ev) @trusted nothrow @nogc
    {
        import core.sys.posix.sys.socket : getsockopt, socklen_t, SO_ERROR, SOL_SOCKET,
            sockaddr;
        import core.sys.posix.unistd : read, write;

        final switch (op.kind)
        {
            case OpKindLocal.recv:
                return syscallResult(recv(op.fd, op.buf, op.len, 0));
            case OpKindLocal.send:
                return syscallResult(send(op.fd, op.buf, op.len, 0));
            case OpKindLocal.read_:
                return syscallResult(read(op.fd, op.buf, op.len));
            case OpKindLocal.write_:
                return syscallResult(write(op.fd, op.buf, op.len));
            case OpKindLocal.accept_:
                return syscallResult(accept(op.fd, null, null));
            case OpKindLocal.connect_:
                int err;
                socklen_t elen = err.sizeof;
                getsockopt(op.fd, SOL_SOCKET, SO_ERROR, &err, &elen);
                return err == 0 ? 0 : -err;
            case OpKindLocal.timer:
                return 0; // expiry is success (the loop maps timeout res)
            case OpKindLocal.poll_:
                // The readiness event IS the result: the ready-events mask.
                int events = op.filter == EVFILT_WRITE
                    ? PollEvents.writable : PollEvents.readable;
                if (ev.flags & EV_EOF)
                    events |= PollEvents.hangup;
                return events;
            case OpKindLocal.waitid_:
                // NOTE_EXIT only says the process ended; the reap is still
                // ours to perform, and now cannot block.
                return doWaitid(op.idType, op.fd, cast(void*) op.buf,
                    op.waitOptions);
            case OpKindLocal.wake:
                return 0;
        }
    }

    /// `waitid`, as the completion result convention wants it: 0 on success,
    /// `-errno` on failure.
    static int doWaitid(int idType, int id, void* siginfo, int options)
        @trusted nothrow @nogc
    {
        import core.sys.posix.signal : siginfo_t;

        const rc = waitid(idType, cast(uint) id, cast(siginfo_t*) siginfo, options);
        return rc == 0 ? 0 : -errno;
    }

    bool armFilter(KqOp* op, short filter,
        ushort flags = cast(ushort)(EV_ADD | EV_DISPATCH),
        uint fflags = 0) @trusted nothrow @nogc
    {
        // Mark liveness HERE, not in `acquire`: every `trySubmit` overwrites
        // the slot wholesale (`*op = KqOp(…)`), which would clear a flag set
        // at acquisition. `armFilter`/`armTimer` are the single point every
        // submit path converges on, after that assignment.
        op.live = true;
        if (!enqueueChange(cast(size_t) op.fd, filter, flags, fflags, 0, slotToken(op)))
        {
            release(op);
            return false; // change list full — the caller flushes and retries
        }
        ++_pendCount;
        return true;
    }

    bool armTimer(KqOp* op, long ms) @trusted nothrow @nogc
    {
        op.live = true; // see the note in `armFilter`
        // `op.fd` holds the unique timer ident; `data` is the interval, in
        // milliseconds (kqueue's default unit).
        if (!enqueueChange(cast(size_t) op.fd, EVFILT_TIMER,
                cast(ushort)(EV_ADD | EV_DISPATCH), 0, cast(ptrdiff_t) ms, slotToken(op)))
        {
            release(op);
            return false;
        }
        ++_pendCount;
        return true;
    }

    static void setNonBlocking(int fd) @trusted nothrow @nogc
    {
        import core.sys.posix.fcntl : F_GETFL, F_SETFL, fcntl, O_NONBLOCK;

        const fl = fcntl(fd, F_GETFL, 0);
        if (fl >= 0)
            fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    }

    static int syscallResult(ptrdiff_t r) @safe pure nothrow @nogc
        => r < 0 ? -EAGAIN : cast(int) r;

    /**
    The `udata` a registration carries: which slot, and which *use* of it.

    Not the slot's address. `release` returns a slot to the freelist
    immediately, so a raw pointer stays dereferenceable and plausible after the
    op it belonged to is gone — and a kernel event already queued against the
    abandoned registration would then be attributed to whatever op took the
    slot next, completing the wrong token. Pairing the index with a generation
    makes that stale event identifiable, which is what `opFor` checks.

    This is the same move `io_uring`'s `user_data` and this library's own
    `OpToken` already make: an opaque value validated on the way back, not a
    pointer trusted on sight.
    */
    void* slotToken(const(KqOp)* op) const @trusted pure nothrow @nogc
    {
        const idx = cast(ulong)(op - _ops.ptr);
        return cast(void*)((cast(ulong) _gens[cast(size_t) idx] << 32) | idx);
    }

    /// The live op a delivered `udata` names, or `null` if the registration it
    /// came from has since been released (or it was never ours).
    KqOp* opFor(scope const(void)* udata) @trusted nothrow @nogc
    {
        const packed = cast(ulong) udata;
        const idx = cast(uint)(packed & 0xffff_ffff);
        const gen = cast(uint)(packed >>> 32);
        if (idx >= _cap)
            return null;
        if (_gens[idx] != gen)
            return null;
        auto op = &_ops[idx];
        return op.live ? op : null;
    }

    /// `pureFree` behind a name the error path can call before `_ops`/`_gens`
    /// are known-good, without importing it twice.
    static void pureFreeSlab(void* p) @trusted nothrow @nogc
    {
        import core.memory : pureFree;

        pureFree(p);
    }

    KqOp* acquire() @trusted nothrow @nogc
    {
        if (_freeHead == uint.max)
            return null;
        auto op = &_ops[_freeHead];
        _freeHead = op.nextFree;
        return op;
    }

    /// The live op carrying `token`, or `null`. A linear scan over the slab —
    /// cancellation is rare (a failing sibling, an expiring deadline), so this
    /// stays off the hot path and needs no second index to keep in sync.
    /// `live` is the guard that matters: a released slot has already delivered
    /// its terminal completion, and cancelling it again would double-release
    /// it onto the freelist.
    /// The persistent wake op, or `null`. One per backend; a linear scan
    /// is fine — `nativeWaker` runs once per loop life.
    KqOp* findWake() @trusted nothrow @nogc
    {
        foreach (i; 0 .. _cap)
        {
            auto op = &_ops[i];
            if (op.live && op.kind == OpKindLocal.wake)
                return op;
        }
        return null;
    }

    KqOp* findLive(ulong token) @trusted nothrow @nogc
    {
        foreach (i; 0 .. _cap)
        {
            auto op = &_ops[i];
            if (op.live && op.token == token)
                return op;
        }
        return null;
    }

    /**
    Returns the slot to the freelist. `dropKnote` is set when the kernel still
    holds a registration — `EV_DISPATCH` disables the knote on delivery
    instead of consuming it, so a release that does not delete leaks it
    across the next op on the same fd (O28).

    Not set when the add never happened (enqueue failed, `EV_ERROR` rejection)
    or when the caller already queued the delete (cancel). `dropPendingChange`
    still wins if the add has not gone down yet: there is then nothing to
    delete, and we must not append a spurious `EV_DELETE`.
    */
    void release(KqOp* op, bool dropKnote = false) @trusted nothrow @nogc
    {
        if (dropKnote)
        {
            // Capture before the generation bump: `dropPendingChange` matches
            // the token the still-queued add carries.
            const token = slotToken(op);
            if (!dropPendingChange(token))
            {
                // drainKevent consumed the sent prefix before ingest, so a
                // delete per delivered event always fits. Cancel takes the
                // other path (`dropKnote` false) after queueing its own delete.
                cast(void) enqueueChange(cast(size_t) op.fd, op.filter,
                    EV_DELETE, 0, 0, null);
            }
        }
        const idx = cast(uint)(op - _ops.ptr);
        // Bump BEFORE the slot can be handed out again: any kernel event still
        // queued against the registration we are abandoning now carries a stale
        // generation and will be dropped by `opFor` rather than attributed to
        // whichever op takes this slot next.
        ++_gens[idx];
        op.live = false;
        op.nextFree = _freeHead;
        _freeHead = idx;
        if (_pendCount > 0)
            --_pendCount;
    }

    /// Events requested per `kevent(2)`.
    enum uint maxBatch = 128;
    /// Room reserved for stashed completions. Larger than `maxBatch` so a
    /// `flush()` that happens to collect a full batch still leaves the
    /// following wait somewhere to put its own.
    enum uint readyCap = 2 * maxBatch;
    /// Change entries that may accumulate before a flush is forced.
    enum uint maxChanges = 256;
    // Timer idents live in a high range so they never collide with fds.
    enum uint _timerBase = 0x4000_0000;
    /// `EVFILT_USER` ident for the persistent wake knote. Not an fd.
    enum uint wakeIdent = 1;
    // This backend's one raw completion flag: a retained multishot poll's
    // non-final marker (mapFlags translates it to CompletionFlags.more).
    enum uint rawFlagMore = 1;

    int _kq = -1;
    KqOp[] _ops;
    /// Generation per slot, parallel to `_ops` rather than a field of `KqOp`:
    /// every `trySubmit` assigns the slot wholesale (`*op = KqOp(…)`), which
    /// would reset a counter living inside it on each reuse — the same hazard
    /// `armFilter`'s note about `live` describes.
    uint[] _gens;
    uint _cap;
    uint _freeHead = uint.max;
    uint _pendCount;
    /// Registrations and deletes awaiting the next `kevent(2)` (O27). One FIFO
    /// array for both, so an add and the delete that undoes it cannot be
    /// reordered against each other.
    kevent_t[maxChanges] _changes;
    uint _changeCount;
    RawCompletion[readyCap] _ready;
    uint _readyCount;
    RawCompletion[maxBatch] _synth;
    uint _synthCount;
    BackendCaps _caps;
}

version (unittest)
{
    import sparkles.event_horizon.backend.concept : hasNativeWake, isCompletionBackend;

    static assert(isCompletionBackend!KqueueBackend);
    static assert(hasNativeWake!KqueueBackend);
}

version (unittest)
{
    import core.thread : Thread;

    import sparkles.event_horizon.buffer : Buf;
    import sparkles.event_horizon.op : OpClass, OpToken;
    import sparkles.test_runner.skip : skipTest;

    /// Opens a backend or skips — every test here needs a live kqueue, and on
    /// Linux+libkqueue the shim can be present but refuse to create one.
    private bool openOrSkip(ref KqueueBackend b, BackendConfig cfg = BackendConfig())
    {
        if (b.open(cfg).hasError)
        {
            skipTest("kqueue unavailable");
            return false;
        }
        return true;
    }

    /// A bounded wait: never `null` as the deadline in a test, so a mechanism
    /// that fails to deliver fails the run instead of hanging it.
    private uint pumpOnce(ref KqueueBackend b,
        scope void delegate(ref const RawCompletion) sink)
    {
        auto dl = KernelTimespec(0, 100_000_000); // 100 ms
        cast(void) b.submitAndWait(1, &dl);
        return b.reap(sink);
    }
}

// ── O27: the change list ────────────────────────────────────────────────────

/// The tax O27 removes: submission used to be a syscall of its own, so a
/// steady-state loop paid register-then-wait per op. Registrations now
/// accumulate and ride down with the wait that collects their events.
@("kqueue.changeList.registrationsAccumulateUntilTheWaitCarriesThemDown")
@system
unittest
{
    KqueueBackend b;
    if (!openOrSkip(b))
        return;
    scope (exit)
        b.close();

    enum n = 4;
    foreach (i; 0 .. n)
    {
        OpSlot slot;
        assert(b.trySubmit(OpTimeout(KernelTimespec(0, 1_000_000)),
            OpToken.pack(cast(uint)(i + 1), 1, OpClass.user), slot),
            "a timer that fits in both the slab and the change list queues");
    }
    assert(b._changeCount == n, "no registration has reached the kernel yet");

    uint got;
    foreach (spin; 0 .. 20)
    {
        got += pumpOnce(b, (ref const RawCompletion c) { assert(c.res == 0); });
        if (got == n)
            break;
    }
    assert(got == n, "every batched registration produced its completion");
    // EV_DISPATCH leaves the knote registered, so each terminal completion
    // queues an EV_DELETE (O28). The adds themselves were consumed.
    assert(b._changeCount == n, "each one-shot completion queued its delete");
    foreach (i; 0 .. n)
        assert(b._changes[i].flags == EV_DELETE);
}

/// The contract repair that falls out of the same change: `trySubmit`'s
/// `false` means "a submission resource is full", never "the kernel said no".
/// A rejected registration is a completion — the shape a bad SQE already has
/// on io_uring. Before O27 this returned `false`, which the loop reads as
/// backpressure and retries forever.
@("kqueue.changeList.aRejectedRegistrationArrivesAsACompletion")
@system
unittest
{
    import core.stdc.errno : EBADF, EFAULT;

    KqueueBackend b;
    if (!openOrSkip(b))
        return;
    scope (exit)
        b.close();

    // A descriptor number that never named anything. Closing a freshly
    // allocated fd and then registering it is a race against the parallel
    // runner: another test can recycle the number before `kevent` sees the
    // change, and the add succeeds against the wrong file.
    enum dead = 1_000_000;

    ubyte[16] store;
    auto buf = Buf.fromForeign(store[], null);
    buf.length = buf.capacity;
    OpSlot slot;
    slot.pinned = () @trusted { import core.lifetime : move; return move(buf); }();

    assert(b.trySubmit(OpRecv(dead), OpToken.pack(7, 1, OpClass.user), slot),
        "submission-time truth is exactly what batching gives up: queued is all "
        ~ "`trySubmit` can honestly report");

    int res = 1;
    uint n;
    foreach (spin; 0 .. 10)
    {
        n += pumpOnce(b, (ref const RawCompletion c) { res = c.res; });
        if (n > 0)
            break;
    }
    assert(n == 1, "the rejection came back as a completion, not a submit failure");
    // Darwin reports EBADF. libkqueue 2.7.0's kn_create substitutes EFAULT
    // when the filter leaves errno unset (`src/common/kevent.c`) — and its
    // public kevent then hides that EV_ERROR behind a wait-timeout of 0,
    // which `drainKevent` harvests. Either way the completion carries the
    // backend's own errno, not a submit-time `false`.
    assert(res == -EBADF || res == -EFAULT, "carrying the backend's own errno");
    assert(b._freeHead != uint.max, "and the op's slot went back to the freelist");
}

/// The other half of the contract: a full change list *is* backpressure, and
/// `flush()` is what clears it — so the loop's flush-and-retry path works
/// rather than turning into an unclearable spin.
@("kqueue.changeList.exhaustionIsBackpressureThatFlushClears")
@system
unittest
{
    KqueueBackend b;
    BackendConfig cfg;
    cfg.cqEntries = KqueueBackend.maxChanges + 8; // more op slots than change entries
    if (!openOrSkip(b, cfg))
        return;
    scope (exit)
        b.close();

    uint queued;
    foreach (i; 0 .. KqueueBackend.maxChanges + 4)
    {
        OpSlot slot;
        if (!b.trySubmit(OpTimeout(KernelTimespec(9, 0)),
                OpToken.pack(cast(uint)(i + 1), 1, OpClass.user), slot))
            break;
        ++queued;
    }
    assert(queued == KqueueBackend.maxChanges, "the change list is what ran out");
    assert(b._freeHead != uint.max, "a refused submit hands its slot back");

    const f = b.flush();
    assert(!f.hasError);
    assert(f.value == KqueueBackend.maxChanges,
        "flush reports change entries submitted — the backend-defined unit");

    OpSlot slot;
    assert(b.trySubmit(OpTimeout(KernelTimespec(9, 0)),
        OpToken.pack(9999, 1, OpClass.user), slot), "and the retry now fits");
}

/// Cancellation goes through the same array, which is the point: an
/// `EV_DELETE` issued immediately would have raced its target's own still-queued
/// `EV_ADD` and left the registration armed. When the add has not gone down
/// yet there is nothing to delete at all.
@("kqueue.cancel.dropsAnAddTheKernelHasNotSeen")
@system
unittest
{
    KqueueBackend b;
    if (!openOrSkip(b))
        return;
    scope (exit)
        b.close();

    const target = OpToken.pack(3, 1, OpClass.user);
    OpSlot slot;
    assert(b.trySubmit(OpTimeout(KernelTimespec(9, 0)), target, slot));
    assert(b._changeCount == 1);

    assert(b.trySubmitCancel(OpToken.pack(4, 1, OpClass.internal), target));
    assert(b._changeCount == 0, "the add was withdrawn, and no delete replaced it");

    int targetRes = 1, cancelRes = 1;
    const n = b.reap((ref const RawCompletion c) {
        if (c.userData == target.raw)
            targetRes = c.res;
        else
            cancelRes = c.res;
    });
    assert(n == 2, "both completions the loop needs to unpark the fiber");
    assert(targetRes == -ECANCELED && cancelRes == 0);
}

/// Once the add has reached the kernel, the delete is a change entry like any
/// other — and carries a null `udata`, so the `ENOENT` it earns when the knote
/// already fired is ignored instead of being mistaken for a rejected
/// registration and completed twice.
@("kqueue.cancel.queuesADeleteForAnAddTheKernelAlreadyHas")
@system
unittest
{
    KqueueBackend b;
    if (!openOrSkip(b))
        return;
    scope (exit)
        b.close();

    const target = OpToken.pack(3, 1, OpClass.user);
    OpSlot slot;
    assert(b.trySubmit(OpTimeout(KernelTimespec(9, 0)), target, slot));
    assert(!b.flush().hasError);
    assert(b._changeCount == 0);

    assert(b.trySubmitCancel(OpToken.pack(4, 1, OpClass.internal), target));
    assert(b._changeCount == 1, "the delete is queued behind the add it undoes");
    assert(b._changes[0].flags == EV_DELETE);
    assert(b._changes[0].udata is null, "a delete must not decode to a live op");

    assert(!b.flush().hasError);
    const n = b.reap((ref const RawCompletion c) { cast(void) c; });
    assert(n == 2, "exactly the cancel pair — the delete produced no completion");
}

// ── O28: EV_DISPATCH re-arm + explicit delete ───────────────────────────────

/// `EV_ONESHOT` consumed the knote on delivery. `EV_DISPATCH` only disables
/// it, so a terminal completion must queue an `EV_DELETE` or the knote leaks
/// onto the next op that reuses the fd.
@("kqueue.dispatch.aOneShotCompletionQueuesADelete")
@system
unittest
{
    KqueueBackend b;
    if (!openOrSkip(b))
        return;
    scope (exit)
        b.close();

    OpSlot slot;
    assert(b.trySubmit(OpTimeout(KernelTimespec(0, 1_000_000)),
        OpToken.pack(1, 1, OpClass.user), slot));

    uint n;
    foreach (spin; 0 .. 20)
    {
        n += pumpOnce(b, (ref const RawCompletion c) { assert(c.res == 0); });
        if (n > 0)
            break;
    }
    assert(n == 1);
    assert(b._changeCount == 1, "the knote is still registered until this delete");
    assert(b._changes[0].flags == EV_DELETE);
    assert(b._changes[0].udata is null);
}

/// A multishot poll re-arms with `EV_ENABLE` after each delivery, so a second
/// write is observed without a fresh `EV_ADD`.
@("kqueue.dispatch.multishotRearmsWithEnable")
@system
unittest
{
    import core.sys.posix.unistd : close_ = close, pipe, read, write;

    KqueueBackend b;
    if (!openOrSkip(b))
        return;
    scope (exit)
        b.close();

    int[2] p;
    assert(pipe(p) == 0);
    scope (exit)
    {
        close_(p[0]);
        close_(p[1]);
    }
    immutable ubyte one = 1;
    assert(write(p[1], &one, 1) == 1);

    OpSlot slot;
    assert(b.trySubmit(OpPollAdd(p[0], PollEvents.readable, true),
        OpToken.pack(2, 1, OpClass.user), slot));

    uint first;
    foreach (spin; 0 .. 10)
    {
        first += pumpOnce(b, (ref const RawCompletion c) {
            assert(c.res & PollEvents.readable);
        });
        if (first > 0)
            break;
    }
    assert(first == 1, "the first byte woke the poll");
    assert(b._changeCount == 1, "the knote was re-armed, not re-added");
    assert(b._changes[0].flags == (EV_ENABLE | EV_DISPATCH));
    assert(b._changes[0].udata !is null, "the re-arm names the live op");

    // Drain so the second wakeup is the second write, not leftover data
    // on a level-triggered re-enable.
    ubyte drained;
    assert(read(p[0], &drained, 1) == 1);
    assert(write(p[1], &one, 1) == 1);
    uint second;
    foreach (spin; 0 .. 10)
    {
        second += pumpOnce(b, (ref const RawCompletion c) {
            assert(c.res & PollEvents.readable);
        });
        if (second > 0)
            break;
    }
    assert(second == 1, "the re-arm observed the second byte");
}

/// A process that is already gone has nothing left to watch, so the
/// `EVFILT_PROC` add is rejected with `ESRCH`. That is the common case for a
/// reap issued after the exit was noticed, not a failure — and batching moved
/// where it is noticed: the reap now happens when the rejection is ingested.
///
/// The discriminator is the errno. A pid that never existed cannot be reaped,
/// so the inline `waitid` fails with `ECHILD`; seeing `-ESRCH` here instead
/// would mean the rejection was passed straight through and the reap never
/// attempted. (The successful reap is covered end to end by `live.d`'s spawn
/// tests, which run a real child through `RingProc`.)
@("kqueue.waitid.aRejectedProcAddStillAttemptsTheReap")
@system
unittest
{
    import core.stdc.errno : ECHILD;
    import core.sys.posix.signal : siginfo_t;
    import core.sys.posix.sys.wait : idtype_t, WEXITED;

    KqueueBackend b;
    if (!openOrSkip(b))
        return;
    scope (exit)
        b.close();

    // Above every pid this OS hands out, so it names nothing and never will.
    enum uint ghost = 999_999;

    siginfo_t si;
    OpSlot slot;
    assert(b.trySubmit(OpWaitid(cast(int) idtype_t.P_PID, ghost,
        () @trusted { return &si; }(), WEXITED),
        OpToken.pack(5, 1, OpClass.user), slot));

    int res = 1;
    uint n;
    foreach (spin; 0 .. 10)
    {
        n += pumpOnce(b, (ref const RawCompletion c) { res = c.res; });
        if (n > 0)
            break;
    }
    assert(n == 1, "the rejection was delivered as this op's completion");
    assert(res == -ECHILD,
        "the reap was attempted; -ESRCH would mean the rejection passed through");
}

/// The M10 data-path gate (runs on macOS): register recv/send readiness on a
/// loopback pair, let kqueue synthesize the completions, and confirm the
/// bytes flow — proving the readiness→syscall→completion mapping end to end.
@("kqueue.slotToken.aStaleRegistrationCannotHitTheRecycledSlot")
@system
unittest
{
    KqueueBackend b;
    if (b.open(BackendConfig()).hasError)
        skipTest("kqueue unavailable");
    scope (exit)
        b.close();

    // A slot, registered and then abandoned — exactly what `release` leaves
    // behind when a batched `EV_DELETE` has not reached the kernel yet, or when
    // an event was already queued when the op completed.
    auto first = b.acquire();
    assert(first !is null);
    first.token = 0xAAAA;
    first.live = true;
    const stale = b.slotToken(first);
    assert(b.opFor(stale) is first, "a live registration must resolve");

    b.release(first);
    assert(b.opFor(stale) is null, "a released slot must not answer its old token");

    // The freelist is LIFO, so the very next acquire takes the same storage.
    // This is the case a raw `KqOp*` in `udata` gets wrong: the pointer is
    // still valid and still points at a live op — just not the one the kernel
    // was told about, so its completion would be reported against 0xBBBB.
    auto second = b.acquire();
    assert(second is first, "precondition: the slab hands the same slot back");
    second.token = 0xBBBB;
    second.live = true;

    assert(b.opFor(stale) is null,
        "the recycled slot answered a registration that belonged to a dead op");
    assert(b.opFor(b.slotToken(second)) is second, "the current op must still resolve");

    // Nothing else may decode: a zero `udata` is what a registration this
    // backend never made carries, and generations start at 1 so it matches no
    // slot -- including slot 0, whose index is also zero.
    assert(b.opFor(null) is null);
    b.release(second);
}

@("kqueue.dataPath.recvSendSynthesis")
@system
unittest
{
    import core.sys.posix.arpa.inet : htonl, htons;
    import core.sys.posix.netinet.in_ : in_addr, INADDR_LOOPBACK, sockaddr_in;
    import core.sys.posix.sys.socket : accept, AF_INET, bind, connect, getsockname,
        listen, sockaddr, socket, socklen_t, SOCK_STREAM;
    import core.sys.posix.unistd : close_ = close;

    KqueueBackend b;
    if (b.open(BackendConfig()).hasError)
        skipTest("kqueue unavailable");

    const listener = socket(AF_INET, SOCK_STREAM, 0);
    assert(listener >= 0);
    sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = 0;
    addr.sin_addr = in_addr(htonl(INADDR_LOOPBACK));
    assert(bind(listener, cast(sockaddr*) &addr, sockaddr_in.sizeof) == 0);
    assert(listen(listener, 1) == 0);
    sockaddr_in bound;
    socklen_t blen = sockaddr_in.sizeof;
    assert(getsockname(listener, cast(sockaddr*) &bound, &blen) == 0);
    const port = bound.sin_port;

    __gshared int clientSock;
    __gshared bool clientGotEcho;
    auto client = new Thread({
        import core.sys.posix.sys.socket : recv, send;

        clientSock = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in to;
        to.sin_family = AF_INET;
        to.sin_port = port;
        to.sin_addr = in_addr(htonl(INADDR_LOOPBACK));
        if (connect(clientSock, cast(sockaddr*) &to, sockaddr_in.sizeof) != 0)
            return;
        immutable(char)[5] hello = "hello";
        send(clientSock, hello.ptr, 5, 0);
        char[16] rbuf;
        const got = recv(clientSock, rbuf.ptr, 16, 0);
        clientGotEcho = got == 5 && rbuf[0 .. 5] == "hello";
    });
    client.start();

    const server = accept(listener, null, null);
    assert(server >= 0);

    // Server: recv the greeting via kqueue readiness synthesis.
    ubyte[64] rxStore;
    auto rxBuf = Buf.fromForeign(rxStore[], null);
    rxBuf.length = rxBuf.capacity;
    OpSlot rxSlot;
    rxSlot.pinned = () @trusted { import core.lifetime : move; return move(rxBuf); }();
    assert(b.trySubmit(OpRecv(server), OpToken.pack(1, 1, OpClass.user), rxSlot));
    uint recvBytes;
    for (int spins = 0; spins < 100 && recvBytes == 0; ++spins)
    {
        cast(void) b.submitAndWait(1, null);
        b.reap((ref const RawCompletion c) { if (c.res > 0) recvBytes = cast(uint) c.res; });
    }
    assert(recvBytes == 5, "server received the greeting via kqueue");
    assert(rxSlot.pinned[][0 .. 5] == cast(const(ubyte)[]) "hello");

    // Server: echo it back via EVFILT_WRITE readiness.
    ubyte[5] txStore = cast(ubyte[5]) "hello";
    auto txBuf = Buf.fromForeign(txStore[], null);
    txBuf.length = 5;
    OpSlot txSlot;
    txSlot.pinned = () @trusted { import core.lifetime : move; return move(txBuf); }();
    assert(b.trySubmit(OpSend(server), OpToken.pack(2, 1, OpClass.user), txSlot));
    uint sentBytes;
    for (int spins = 0; spins < 100 && sentBytes == 0; ++spins)
    {
        cast(void) b.submitAndWait(1, null);
        b.reap((ref const RawCompletion c) { if (c.res > 0) sentBytes = cast(uint) c.res; });
    }
    assert(sentBytes == 5, "server echoed via kqueue");

    client.join();
    assert(clientGotEcho, "client received the echo");

    close_(server);
    close_(listener);
    close_(clientSock);
    b.close();
}

// ── O29: EVFILT_USER wake ───────────────────────────────────────────────────

/// A `NOTE_TRIGGER` before any wait is not lost: the ADD is flushed when
/// the handle is created, so the next wait returns immediately.
@("kqueue.wake.triggerBeforeWaitCoalesces")
@system
unittest
{
    KqueueBackend b;
    if (!openOrSkip(b))
        return;
    scope (exit)
        b.close();

    const token = OpToken.pack(8, 1, OpClass.internal);
    auto w = b.nativeWaker(token);
    assert(w);
    w.wake();
    w.wake();
    w.wake();

    uint n;
    int res = 1;
    foreach (spin; 0 .. 10)
    {
        n += pumpOnce(b, (ref const RawCompletion c) {
            assert(c.userData == token.raw);
            res = c.res;
        });
        if (n > 0)
            break;
    }
    assert(n == 1, "three triggers coalesced into one completion");
    assert(res == 0);
}

/// A foreign-thread trigger unparks a blocked wait well before its deadline.
@("kqueue.wake.noteTriggerUnparksTheWait")
@system
unittest
{
    import core.time : msecs;

    KqueueBackend b;
    if (!openOrSkip(b))
        return;
    scope (exit)
        b.close();

    const token = OpToken.pack(9, 1, OpClass.internal);
    auto w = b.nativeWaker(token);
    assert(w);

    auto t = new Thread({
        Thread.sleep(20.msecs);
        w.wake();
    });
    t.start();

    uint n;
    auto dl = KernelTimespec(2, 0);
    foreach (spin; 0 .. 20)
    {
        cast(void) b.submitAndWait(1, &dl);
        n += b.reap((ref const RawCompletion c) {
            assert(c.userData == token.raw);
        });
        if (n > 0)
            break;
    }
    t.join();
    assert(n == 1, "the wait ended on the NOTE_TRIGGER");
}
