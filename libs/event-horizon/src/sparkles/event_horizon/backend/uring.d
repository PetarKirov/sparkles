/**
The reference backend: `io_uring` via the `during` binding (SPEC §3.5).

Lowering is a statically dispatched overload set: each `trySubmit(op, token)`
fills the next SQE via the matching `prep` helper and sets
`user_data = token.raw`. The M2 surface covers ring setup with operating-mode
negotiation, the capability probe on the real ring, the NOP round-trip, and
deadline waits via `EXT_ARG` inline timespecs; buffer-carrying lowering lands
with the callback tier (M3).
*/
module sparkles.event_horizon.backend.uring;

version (linux)  :  // io_uring is Linux-only; peer backends land in M10/M11.

import during : AcceptFlags, CancelFlags, CQEFlags, FsyncFlags, MsgFlags, Operation,
    SetupFlags, SubmissionEntry, TimeoutFlags, Uring, io_uring_getevents_arg,
    prepAccept, prepClose, prepConnect, prepFsync, prepMultishotAccept, prepNop,
    prepOpenat, prepRW, prepRead, prepReadFixed, prepRecv, prepRecvMsg, prepSend,
    prepSendMsg, prepStatx, prepTimeout, prepWaitid, prepWrite, prepWriteFixed,
    setup;
import during : DuringTimespec = KernelTimespec;

import sparkles.event_horizon.backend.concept : BackendConfig, RawCompletion;
import sparkles.event_horizon.backend.probe;
import sparkles.event_horizon.errors;
import sparkles.event_horizon.op : CompletionFlags, KernelTimespec, OpAccept,
    OpAcceptMultishot, OpClose, OpConnect, OpFsync, OpNop, OpOpenAt, OpRead,
    OpRecv, OpRecvFrom, OpSend, OpSendTo, OpSlot, OpStatx, OpTimeout, OpToken,
    OpWaitid, OpWrite, SockAddr;

import core.stdc.errno : ETIME;

/// One `io_uring` ring plus its negotiated capabilities. Thread-affine and
/// non-copyable (`SINGLE_ISSUER` made structural, SPEC §5.1).
struct UringBackend
{
    @disable this(this);

    /**
    Sets up the ring: negotiates the operating mode per
    `cfg.mode`/`cfg.modePolicy`, verifies the kernel floor, and probes
    capabilities on the real ring (one setup, not two).

    Linux hard-error semantics (SPEC §3.4): no epoll fallback — a host
    without a working `io_uring` gets `IoError(stage: setup)`; a pre-6.1
    kernel or a rejected exact mode gets `IoError(stage: probe)`.
    */
    IoResult!void open(in BackendConfig cfg) @safe nothrow @nogc
    {
        if (!kernelVersion().atLeast(kernelFloor.major, kernelFloor.minor))
        {
            // Distinguish "no io_uring at all" from "kernel too old".
            Uring probeRing;
            const probeRet = probeRing.setup(8);
            if (probeRet < 0)
                return ioErr!void(-probeRet, OpKind.none, IoErrorStage.setup,
                    "io_uring unavailable");
            return ioErr!void(0, OpKind.none, IoErrorStage.probe,
                "kernel below the 6.1 baseline");
        }

        const requested = cast(LoopMode) cfg.mode;
        auto ret = setupMode(requested, cfg.sqEntries);
        LoopMode negotiated = requested;
        if (ret < 0 && cast(ModePolicy) cfg.modePolicy == ModePolicy.bestAvailable
            && requested == LoopMode.exclusive)
        {
            negotiated = LoopMode.cooperative;
            ret = setupMode(negotiated, cfg.sqEntries);
        }
        if (ret < 0)
        {
            // A floor kernel accepts both modes; reaching this means the
            // ring itself is unavailable (seccomp/sysctl lockdown).
            const stage = ret == -22 /* EINVAL */ ? IoErrorStage.probe : IoErrorStage.setup;
            return ioErr!void(-ret, OpKind.none, stage,
                "io_uring setup rejected");
        }

        const exclusive = negotiated == LoopMode.exclusive;
        _caps = buildUringCaps(_io, negotiated, exclusive, exclusive, true);
        return ioOk();
    }

    /// Releases the ring (the `during` handle is RAII/refcounted).
    void close() @safe nothrow @nogc
    {
        _io = Uring.init;
    }

    /// The capability surface negotiated by `open`.
    ref const(BackendCaps) caps() const return @safe pure nothrow @nogc
        => _caps;

    // ── lowering overload set (SPEC §3.5) ───────────────────────────────
    // Every overload returns `false` when the submission queue is full (the
    // loop owns the flush-and-retry policy, SPEC §5.2). The loop has already
    // moved owned buffers into `slot.pinned` and address/timespec operands
    // into `slot.operands` — the SQE points only at slot-stable memory.

    /// Lowers a NOP.
    bool trySubmit(in OpNop, OpToken token, ref OpSlot) @safe nothrow @nogc
    {
        if (_io.full)
            return false;
        _io.putWith!((ref SubmissionEntry e, ulong ud) {
            e.prepNop();
            e.user_data = ud;
        })(token.raw);
        return true;
    }

    /// Lowers a positioned read into the pinned buffer's full capacity;
    /// a registered buffer automatically selects `READ_FIXED` (SPEC §6.3).
    bool trySubmit(in OpRead op, OpToken token, ref OpSlot slot) @safe nothrow @nogc
    {
        if (_io.full)
            return false;
        if (slot.pinned.isRegistered)
            _io.putWith!((ref SubmissionEntry e, int fd, ubyte[] space,
                    ushort bufIdx, ulong off, ulong ud) {
                e.prepReadFixed(fd, cast(long) off, space, bufIdx);
                e.user_data = ud;
            })(op.fd, slot.pinned.space(), slot.pinned.bufIndex, op.offset, token.raw);
        else
            _io.putWith!((ref SubmissionEntry e, int fd, ubyte[] space, ulong off, ulong ud) {
                e.prepRead(fd, space, cast(long) off);
                e.user_data = ud;
            })(op.fd, slot.pinned.space(), op.offset, token.raw);
        return true;
    }

    /// Lowers a positioned write of the pinned buffer's valid bytes;
    /// a registered buffer automatically selects `WRITE_FIXED`.
    bool trySubmit(in OpWrite op, OpToken token, ref OpSlot slot) @safe nothrow @nogc
    {
        if (_io.full)
            return false;
        if (slot.pinned.isRegistered)
            _io.putWith!((ref SubmissionEntry e, int fd, ubyte[] bytes,
                    ushort bufIdx, ulong off, ulong ud) {
                e.prepWriteFixed(fd, cast(long) off, bytes, bufIdx);
                e.user_data = ud;
            })(op.fd, cast(ubyte[]) slot.pinned[], slot.pinned.bufIndex,
                op.offset, token.raw);
        else
            _io.putWith!((ref SubmissionEntry e, int fd, const(ubyte)[] bytes, ulong off, ulong ud) {
                e.prepWrite(fd, bytes, cast(long) off);
                e.user_data = ud;
            })(op.fd, slot.pinned[], op.offset, token.raw);
        return true;
    }

    /// Lowers a socket receive into the pinned buffer's full capacity.
    bool trySubmit(in OpRecv op, OpToken token, ref OpSlot slot) @safe nothrow @nogc
    {
        if (_io.full)
            return false;
        _io.putWith!((ref SubmissionEntry e, int fd, ubyte[] space, ulong ud) {
            e.prepRecv(fd, space, MsgFlags.NONE);
            e.user_data = ud;
        })(op.fd, slot.pinned.space(), token.raw);
        return true;
    }

    /// Lowers a socket send of the pinned buffer's valid bytes.
    bool trySubmit(in OpSend op, OpToken token, ref OpSlot slot) @safe nothrow @nogc
    {
        if (_io.full)
            return false;
        _io.putWith!((ref SubmissionEntry e, int fd, const(ubyte)[] bytes, ulong ud) {
            e.prepSend(fd, bytes, MsgFlags.NONE);
            e.user_data = ud;
        })(op.fd, slot.pinned[], token.raw);
        return true;
    }

    /// Lowers an accept; the kernel writes the peer address into the slot's
    /// operand store (discarded — SPEC §4.1 fetches peers on demand).
    bool trySubmit(in OpAccept op, OpToken token, ref OpSlot slot) @trusted nothrow @nogc
    {
        import core.sys.posix.sys.socket : sockaddr, socklen_t;

        if (_io.full)
            return false;
        slot.operands.addr.len = cast(uint) slot.operands.addr.storage.length;
        _io.putWith!((ref SubmissionEntry e, int fd, ref OpSlot s, ulong ud) {
            e.prepAccept(fd, *cast(sockaddr*) s.operands.addr.storage.ptr,
                *cast(socklen_t*) &s.operands.addr.len, AcceptFlags.NONE);
            e.user_data = ud;
        })(op.listenFd, slot, token.raw);
        return true;
    }

    /// Lowers a multishot accept: one armed SQE posts a completion per
    /// connection (`CQE_F_MORE`) until cancelled — no re-arm syscall
    /// (SPEC §4.3). The peer address store is shared across the stream.
    bool trySubmit(in OpAcceptMultishot op, OpToken token, ref OpSlot slot)
        @trusted nothrow @nogc
    {
        import core.sys.posix.sys.socket : sockaddr, socklen_t;

        if (_io.full)
            return false;
        slot.operands.addr.len = cast(uint) slot.operands.addr.storage.length;
        _io.putWith!((ref SubmissionEntry e, int fd, ref OpSlot s, ulong ud) {
            e.prepMultishotAccept(fd, *cast(sockaddr*) s.operands.addr.storage.ptr,
                *cast(socklen_t*) &s.operands.addr.len, AcceptFlags.NONE);
            e.user_data = ud;
        })(op.listenFd, slot, token.raw);
        return true;
    }

    /// Lowers a connect; the address was copied into the operand store.
    bool trySubmit(in OpConnect op, OpToken token, ref OpSlot slot) @trusted nothrow @nogc
    {
        import core.sys.posix.sys.socket : sockaddr;

        if (_io.full)
            return false;
        slot.operands.addr = op.addr;
        _io.putWith!((ref SubmissionEntry e, int fd, ref OpSlot s, ulong ud) {
            e.prepConnect(fd, *cast(const(sockaddr)*) s.operands.addr.storage.ptr);
            // prepConnect derives the length from the ADDR type; patch the
            // real sockaddr length in afterwards.
            e.off = s.operands.addr.len;
            e.user_data = ud;
        })(op.fd, slot, token.raw);
        return true;
    }

    /// Lowers a datagram send via `SENDMSG` (msghdr/iovec in the slot).
    bool trySubmit(in OpSendTo op, OpToken token, ref OpSlot slot) @trusted nothrow @nogc
    {
        if (_io.full)
            return false;
        slot.operands.msg.hdr = typeof(slot.operands.msg.hdr).init;
        slot.peerOut = op.to;
        slot.operands.msg.iov.iov_base = cast(void*) slot.pinned[].ptr;
        slot.operands.msg.iov.iov_len = slot.pinned.length;
        slot.operands.msg.hdr.msg_name = slot.peerOut.storage.ptr;
        slot.operands.msg.hdr.msg_namelen = slot.peerOut.len;
        slot.operands.msg.hdr.msg_iov = &slot.operands.msg.iov;
        slot.operands.msg.hdr.msg_iovlen = 1;
        _io.putWith!((ref SubmissionEntry e, int fd, ref OpSlot s, ulong ud) {
            e.prepSendMsg(fd, s.operands.msg.hdr, MsgFlags.NONE);
            e.user_data = ud;
        })(op.fd, slot, token.raw);
        return true;
    }

    /// Lowers a datagram receive via `RECVMSG`; the source address lands in
    /// `slot.peerOut` and is copied into the completion.
    bool trySubmit(in OpRecvFrom op, OpToken token, ref OpSlot slot) @trusted nothrow @nogc
    {
        if (_io.full)
            return false;
        slot.operands.msg.hdr = typeof(slot.operands.msg.hdr).init;
        slot.peerOut = SockAddr.init;
        slot.operands.msg.iov.iov_base = cast(void*) slot.pinned.space().ptr;
        slot.operands.msg.iov.iov_len = slot.pinned.capacity;
        slot.operands.msg.hdr.msg_name = slot.peerOut.storage.ptr;
        slot.operands.msg.hdr.msg_namelen = cast(uint) slot.peerOut.storage.length;
        slot.operands.msg.hdr.msg_iov = &slot.operands.msg.iov;
        slot.operands.msg.hdr.msg_iovlen = 1;
        _io.putWith!((ref SubmissionEntry e, int fd, ref OpSlot s, ulong ud) {
            e.prepRecvMsg(fd, s.operands.msg.hdr, MsgFlags.NONE);
            e.user_data = ud;
        })(op.fd, slot, token.raw);
        return true;
    }

    /// Lowers a relative timer (in-ring `TIMEOUT`); the timespec lives in
    /// the operand store (layout-identical to during's).
    bool trySubmit(in OpTimeout op, OpToken token, ref OpSlot slot) @trusted nothrow @nogc
    {
        if (_io.full)
            return false;
        slot.operands.ts = op.rel;
        _io.putWith!((ref SubmissionEntry e, ref OpSlot s, ulong ud) {
            e.prepTimeout(*cast(DuringTimespec*) &s.operands.ts, 0, TimeoutFlags.REL);
            e.user_data = ud;
        })(slot, token.raw);
        return true;
    }

    /// Lowers an open (the path pointer must be kernel-stable, SPEC §4.1).
    bool trySubmit(in OpOpenAt op, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        if (_io.full)
            return false;
        _io.putWith!((ref SubmissionEntry e, in OpOpenAt o, ulong ud) {
            e.prepOpenat(o.dirFd, o.path, o.flags, o.mode);
            e.user_data = ud;
        })(op, token.raw);
        return true;
    }

    /// Lowers a close.
    bool trySubmit(in OpClose op, OpToken token, ref OpSlot) @safe nothrow @nogc
    {
        if (_io.full)
            return false;
        _io.putWith!((ref SubmissionEntry e, int fd, ulong ud) {
            e.prepClose(fd);
            e.user_data = ud;
        })(op.fd, token.raw);
        return true;
    }

    /// Lowers an fsync.
    bool trySubmit(in OpFsync op, OpToken token, ref OpSlot) @safe nothrow @nogc
    {
        if (_io.full)
            return false;
        _io.putWith!((ref SubmissionEntry e, int fd, ulong ud) {
            e.prepFsync(fd, FsyncFlags.NORMAL);
            e.user_data = ud;
        })(op.fd, token.raw);
        return true;
    }

    /// Lowers a statx (path and out-buffer must be kernel-stable).
    bool trySubmit(in OpStatx op, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        if (_io.full)
            return false;
        _io.putWith!((ref SubmissionEntry e, in OpStatx o, ulong ud) {
            e.prepStatx(o.dirFd, o.path, o.flags, o.mask,
                *cast(ubyte[256]*) o.statxBuf);
            e.user_data = ud;
        })(op, token.raw);
        return true;
    }

    /// Lowers a child reap (the siginfo out-buffer must be kernel-stable).
    bool trySubmit(in OpWaitid op, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        import core.sys.posix.signal : siginfo_t;

        if (_io.full)
            return false;
        _io.putWith!((ref SubmissionEntry e, in OpWaitid o, ulong ud) {
            e.prepWaitid(o.idType, o.id, cast(siginfo_t*) o.siginfo, o.options);
            e.user_data = ud;
        })(op, token.raw);
        return true;
    }

    /// Submits an `ASYNC_CANCEL` keyed on `target.raw`, tagged with the
    /// internal `cancelSlot` token. Hand-rolled: during 0.5.0's `prepCancel`
    /// default-flag path is mis-typed (SPEC §3.5).
    bool trySubmitCancel(OpToken cancelSlot, OpToken target) @trusted nothrow @nogc
    {
        if (_io.full)
            return false;
        _io.putWith!((ref SubmissionEntry e, ulong targetRaw, ulong ud) {
            e.prepRW(Operation.ASYNC_CANCEL, -1, cast(void*) targetRaw);
            e.cancel_flags = CancelFlags.init;
            e.user_data = ud;
        })(target.raw, cancelSlot.raw);
        return true;
    }

    /// Maps raw uring CQE flags onto the portable projection.
    CompletionFlags mapFlags(uint rawFlags) const @safe pure nothrow @nogc
    {
        CompletionFlags f;
        if (rawFlags & CQEFlags.MORE)
            f |= CompletionFlags.more;
        if (rawFlags & CQEFlags.BUFFER)
            f |= CompletionFlags.bufferSelected;
        return f;
    }

    /// Pushes queued SQEs to the kernel without waiting; the count consumed.
    IoResult!uint flush() @safe nothrow @nogc
    {
        const r = _io.submit(0u);
        return r < 0
            ? ioErr!uint(-r, OpKind.none, IoErrorStage.submit)
            : ioOk(cast(uint) r);
    }

    /**
    Flushes and waits for at least `want` completions, or until `deadline`
    (an `EXT_ARG` inline timespec — floor-guaranteed). A deadline expiry is
    not an error: it returns `ok(submitted)` and the caller observes an
    empty completion queue.
    */
    IoResult!uint submitAndWait(uint want, scope const KernelTimespec* deadline)
        @trusted nothrow @nogc
    {
        if (deadline is null)
        {
            const r = _io.submitAndWait(want);
            return r < 0
                ? ioErr!uint(-r, OpKind.none, IoErrorStage.submit)
                : ioOk(cast(uint) r);
        }

        // Substrate trap (during 0.5.0): `submitAndWait(want, args)` silently
        // DROPS `args` when the submission queue is empty (it falls back to
        // the bare `wait(want)`), turning a deadline wait into an unbounded
        // block. Flush explicitly, then wait with the EXT_ARG deadline.
        auto flushed = flush();
        if (flushed.hasError)
            return flushed;

        DuringTimespec ts = {tv_sec: deadline.tv_sec, tv_nsec: deadline.tv_nsec};
        io_uring_getevents_arg arg;
        arg.ts = cast(ulong) &ts;
        const r = _io.wait(want, &arg);
        if (r == -ETIME)
            return ioOk(flushed.value);
        return r < 0
            ? ioErr!uint(-r, OpKind.none, IoErrorStage.submit)
            : ioOk(flushed.value);
    }

    /// Non-blocking completion drain into a `scope` sink (no closure
    /// allocation); returns the number of completions delivered.
    uint reap(Sink)(scope Sink sink)
    {
        uint n;
        while (!_io.empty)
        {
            const c = RawCompletion(
                _io.front.user_data, _io.front.res, cast(uint) _io.front.flags);
            _io.popFront();
            sink(c);
            ++n;
        }
        return n;
    }

    /// Runtime-caps-backed multishot support (SPEC §3.1).
    bool supportsMultishot(OpKind k) const @safe pure nothrow @nogc
    {
        switch (k)
        {
            case OpKind.accept, OpKind.acceptMultishot: return _caps.multishotAccept;
            case OpKind.recv, OpKind.recvSelect: return _caps.multishotRecv;
            default: return false;
        }
    }

    /// Pins `slabs` as registered buffers (`REGISTER_BUFFERS`), so
    /// `READ_FIXED`/`WRITE_FIXED` skip per-op page pinning (SPEC §6.3).
    IoResult!void registerBuffers(scope ubyte[][] slabs) @trusted nothrow @nogc
    {
        const r = _io.registerBuffers(slabs);
        return r < 0
            ? ioErr!void(-r, OpKind.none, IoErrorStage.registration,
                "registerBuffers failed")
            : ioOk();
    }

    /// Releases the registered-buffer table.
    IoResult!void unregisterBuffers() @trusted nothrow @nogc
    {
        const r = _io.unregisterBuffers();
        return r < 0
            ? ioErr!void(-r, OpKind.none, IoErrorStage.registration,
                "unregisterBuffers failed")
            : ioOk();
    }

private:
    int setupMode(LoopMode mode, uint sqEntries) @safe nothrow @nogc
    {
        const flags = mode == LoopMode.exclusive
            ? SetupFlags.SINGLE_ISSUER | SetupFlags.DEFER_TASKRUN | SetupFlags.COOP_TASKRUN
            : SetupFlags.COOP_TASKRUN | SetupFlags.TASKRUN_FLAG;
        _io = Uring.init;
        return _io.setup(sqEntries, flags);
    }

    Uring _io;
    BackendCaps _caps;
}

version (unittest)
{
    import sparkles.event_horizon.backend.concept : canSubmitOp, isCompletionBackend;
    import sparkles.event_horizon.op : OpClass;

    static assert(isCompletionBackend!UringBackend);
    static assert(canSubmitOp!(UringBackend, OpNop));

    /// Opens a backend for a test; `false` = SKIP (no io_uring / old kernel).
    private bool openOrSkip(ref UringBackend b) @safe nothrow @nogc
    {
        auto r = b.open(BackendConfig());
        if (r.hasError)
        {
            assert(r.error.stage == IoErrorStage.setup
                || r.error.stage == IoErrorStage.probe);
            return false;
        }
        return true;
    }
}

@("backend.uring.attributes")
@safe nothrow @nogc
unittest
{
    // Lock in the inferred attributes of the generic members the loop's hot
    // path calls (the non-templates are explicitly attributed above).
    // (Not `pure`: during's refcounted Uring destructor is impure.)
    UringBackend b;
    OpSlot dummySlot;
    static assert(is(typeof(() @safe nothrow @nogc {
        cast(void) b.trySubmit(OpNop(), OpToken.init, dummySlot);
    })));
}

@("backend.uring.openClose")
@safe nothrow @nogc
unittest
{
    UringBackend b;
    OpSlot dummySlot;
    if (!openOrSkip(b))
        return; // SKIP: io_uring unavailable on this host
    scope (exit) b.close();

    const caps = b.caps();
    assert(caps.backend == BackendId.uring);
    assert(caps.kernel.atLeast(6, 1));
    assert(caps.supports(OpKind.nop));
    assert(caps.nodrop);
    // The floor guarantees both modes; exclusive is the default request.
    assert(caps.mode == LoopMode.exclusive);
    assert(caps.singleIssuer && caps.deferTaskrun);
}

@("backend.uring.nopRoundTrip")
@safe nothrow @nogc
unittest
{
    UringBackend b;
    OpSlot dummySlot;
    if (!openOrSkip(b))
        return; // SKIP
    scope (exit) b.close();

    const token = OpToken.pack(1, 1, OpClass.user);
    assert(b.trySubmit(OpNop(), token, dummySlot));

    auto waited = b.submitAndWait(1, null);
    assert(waited.hasValue && waited.value == 1);

    ulong seenUserData;
    int seenRes = -1;
    uint n = b.reap((ref const RawCompletion c) @safe nothrow @nogc {
        seenUserData = c.userData;
        seenRes = c.res;
    });
    assert(n == 1);
    assert(seenUserData == token.raw);
    assert(seenRes == 0);
}

@("backend.uring.deadlineWait")
@safe nothrow @nogc
unittest
{
    UringBackend b;
    OpSlot dummySlot;
    if (!openOrSkip(b))
        return; // SKIP
    scope (exit) b.close();

    // Nothing armed: a 1ms deadline wait must return (not hang) and report
    // no completions — the ETIME-is-not-an-error contract.
    const deadline = KernelTimespec(0, 1_000_000);
    auto waited = b.submitAndWait(1, &deadline);
    assert(waited.hasValue);

    const n = b.reap((ref const RawCompletion c) @safe nothrow @nogc {});
    assert(n == 0);
}

@("backend.uring.sqBackpressure")
@safe nothrow @nogc
unittest
{
    UringBackend b;
    OpSlot dummySlot;
    auto cfg = BackendConfig();
    cfg.sqEntries = 4;
    auto opened = b.open(cfg);
    if (opened.hasError)
        return; // SKIP
    scope (exit) b.close();

    // Fill the SQ without flushing: the 5th trySubmit must report full.
    uint queued;
    foreach (i; 0 .. 8)
    {
        if (!b.trySubmit(OpNop(), OpToken.pack(cast(uint) i, 1, OpClass.user), dummySlot))
            break;
        ++queued;
    }
    assert(queued == 4);

    auto waited = b.submitAndWait(queued, null);
    assert(waited.hasValue && waited.value == queued);
    const n = b.reap((ref const RawCompletion c) @safe nothrow @nogc {});
    assert(n == queued);
}
