/**
The macOS/BSD peer backend: a completion-synthesizing proactor over kqueue
readiness (SPEC §3.5, PLAN M10). kqueue is a $(I readiness) interface, so
unlike io_uring and IOCP this backend does the I/O itself: `trySubmit`
registers interest (`EVFILT_READ`/`EVFILT_WRITE`, one-shot) and remembers the
op; when `kevent` reports the fd ready, the backend performs the actual
`recv`/`send` syscall and emits the resulting `RawCompletion` — the
Boost.Asio "emulated proactor" shape. Regular files have no readiness and
would go to a small worker pool (the fs verbs, deferred with the M7-domain
portability).

Each pending op lives in a backend-owned freelist slab; its address is the
kevent `udata`, so a ready event maps straight back to the op's `user_data`
token. `nop` is synthesized inline (no fd), the same way IOCP posts to its
port.

Op coverage: `nop`, `recv`/`send`, `read`/`write`, `accept`, non-blocking
`connect` (`EVFILT_WRITE` + `SO_ERROR`), and timers (`EVFILT_TIMER`). The full
`EventLoop!KqueueBackend` integration — tier-A loop + tier-B fibers + the
`io` verbs — is verified two ways: the data path on real macOS
(`scripts/verify-kqueue-macos.sh`), and the whole stack via a fiber-echo on
Linux over mheily/libkqueue (`scripts/verify-kqueue-linux.sh`). The
regular-file worker pool and native cancellation (`EV_DELETE` on the target
registration) are the remaining refinements.
*/
module sparkles.event_horizon.backend.kqueue;

// The kqueue backend is macOS/BSD-native; `EventHorizonLibkqueue` also builds
// it on Linux over mheily/libkqueue (an epoll shim), so the full
// `EventLoop!KqueueBackend` integration can be tested on Linux CI.
version (OSX)
    version = EventHorizonKqueue;
version (EventHorizonLibkqueue)
    version = EventHorizonKqueue;

version (EventHorizonKqueue)  :

import core.stdc.errno : EAGAIN, ECANCELED, EINPROGRESS, errno;
import core.sys.posix.sys.socket : accept, connect, recv, send;

import sparkles.event_horizon.backend.concept : BackendConfig, RawCompletion;
import sparkles.event_horizon.backend.probe : BackendCaps, BackendId, LoopMode;
import sparkles.event_horizon.errors;
import sparkles.event_horizon.op : KernelTimespec, OpAccept, OpConnect, OpNop,
    OpRead, OpRecv, OpSend, OpSlot, OpTimeout, OpToken, OpWrite;

// ── minimal kqueue bindings (the exact BSD struct layout) ───────────────────

private:

extern (C) nothrow @nogc
{
    int kqueue();
    int kevent(int kq, const(kevent_t)* changelist, int nchanges,
        kevent_t* eventlist, int nevents, const(timespec)* timeout);
    int close(int fd);
}

struct kevent_t
{
    size_t ident;    // fd
    short filter;    // EVFILT_READ / EVFILT_WRITE
    ushort flags;    // EV_ADD | EV_ONESHOT | EV_DELETE | EV_ERROR
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
enum short EVFILT_TIMER = -7;
enum ushort EV_ADD = 0x0001;
enum ushort EV_DELETE = 0x0002;
enum ushort EV_ONESHOT = 0x0010;
enum ushort EV_ERROR = 0x4000;

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
        if (_ops.ptr is null)
        {
            .close(_kq);
            _kq = -1;
            return ioErr!void(12, OpKind.none, IoErrorStage.setup,
                "op-context slab allocation failed");
        }
        foreach (i; 0 .. _cap)
        {
            _ops[i] = KqOp.init;
            _ops[i].nextFree = i + 1 == _cap ? uint.max : cast(uint)(i + 1);
        }
        _freeHead = 0;
        _pendCount = 0;

        _caps.backend = BackendId.kqueue;
        _caps.mode = LoopMode.cooperative;
        return ioOk();
    }

    /// Closes the kqueue and frees the slab.
    void close() @trusted nothrow @nogc
    {
        import core.memory : pureFree;

        if (_ops.ptr !is null)
        {
            pureFree(_ops.ptr);
            _ops = null;
        }
        if (_kq >= 0)
        {
            .close(_kq);
            _kq = -1;
        }
    }

    /// The negotiated capabilities (kqueue: readiness-synthesized proactor).
    ref const(BackendCaps) caps() const return @safe pure nothrow @nogc => _caps;

    /// Maps raw completion flags to the portable set. kqueue synthesizes one
    /// completion per op, so there are no `MORE`/buffer-select flags.
    import sparkles.event_horizon.op : CompletionFlags;

    CompletionFlags mapFlags(uint) const @safe pure nothrow @nogc
        => CompletionFlags.init;

    /// Never called (kqueue sets no buffer-select flag); present for the
    /// dispatch's static shape.
    static ushort selectedBufferId(uint) @safe pure nothrow @nogc => 0;

    // ── lowering: register readiness interest, remember the op ──────────────

    /// A NOP: no fd — synthesize a completion inline.
    bool trySubmit(in OpNop, OpToken token, ref OpSlot) @trusted nothrow @nogc
    {
        if (_synthCount >= _synth.length)
            return false;
        _synth[_synthCount++] = RawCompletion(token.raw, 0, 0);
        return true;
    }

    /// A socket receive: register `EVFILT_READ`, one-shot.
    bool trySubmit(in OpRecv o, OpToken token, ref OpSlot slot) @trusted nothrow
    {
        auto op = acquire();
        if (op is null)
            return false;
        auto space = slot.pinned.space();
        *op = KqOp(token.raw, o.fd, space.ptr, cast(uint) space.length,
            OpKindLocal.recv, EVFILT_READ, uint.max);
        return armFilter(op, EVFILT_READ);
    }

    /// A socket send: register `EVFILT_WRITE`, one-shot.
    bool trySubmit(in OpSend o, OpToken token, ref OpSlot slot) @trusted nothrow
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
    bool trySubmit(in OpRead o, OpToken token, ref OpSlot slot) @trusted nothrow
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
    bool trySubmit(in OpWrite o, OpToken token, ref OpSlot slot) @trusted nothrow
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
    bool trySubmit(in OpAccept o, OpToken token, ref OpSlot) @trusted nothrow
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
    bool trySubmit(in OpConnect o, OpToken token, ref OpSlot) @trusted nothrow
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

    /// A relative timer via `EVFILT_TIMER` (unique ident from the op index).
    bool trySubmit(in OpTimeout o, OpToken token, ref OpSlot) @trusted nothrow
    {
        auto op = acquire();
        if (op is null)
            return false;
        const ident = cast(int)(_timerBase + (op - _ops.ptr));
        *op = KqOp(token.raw, ident, null, 0, OpKindLocal.timer, EVFILT_TIMER, uint.max);
        const ms = o.rel.tv_sec * 1000 + o.rel.tv_nsec / 1_000_000;
        return armTimer(op, ms < 0 ? 0 : ms);
    }

    /// No changelist to flush separately — registration happens inline.
    IoResult!uint flush() @safe nothrow @nogc => ioOk(0u);

    /**
    Waits for readiness (or `deadline`), performs the ready ops' syscalls, and
    stashes their completions for `reap`. Synthesized (`nop`) completions are
    delivered regardless.
    */
    IoResult!uint submitAndWait(uint want, scope const KernelTimespec* deadline)
        @trusted nothrow
    {
        if (_synthCount > 0)
            return ioOk(_synthCount); // synthesized work is already ready

        kevent_t[maxBatch] evs;
        timespec ts;
        const(timespec)* tsp;
        if (deadline !is null)
        {
            ts = timespec(deadline.tv_sec, deadline.tv_nsec);
            tsp = &ts;
        }
        const n = kevent(_kq, null, 0, evs.ptr, maxBatch, tsp);
        if (n < 0)
            return ioErr!uint(errno, OpKind.none, IoErrorStage.submit, "kevent failed");

        _readyCount = 0;
        foreach (i; 0 .. n)
        {
            auto op = cast(KqOp*) evs[i].udata;
            if (op is null)
                continue;
            _ready[_readyCount++] = RawCompletion(op.token, performOp(op, evs[i]), 0);
            release(op);
        }
        return ioOk(cast(uint) _readyCount);
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

    /// Cancel: delete the registered filter (best-effort). The op slot's
    /// lifetime is the loop's concern (detach discipline).
    bool trySubmitCancel(OpToken, OpToken) @safe nothrow @nogc => true;

private:
    /// Performs the actual syscall for a now-ready op; returns the completion
    /// `res` (bytes / new fd / 0 / -errno).
    int performOp(KqOp* op, ref const kevent_t ev) @trusted nothrow
    {
        import core.sys.posix.sys.socket : getsockopt, socklen_t, SO_ERROR, SOL_SOCKET,
            sockaddr;
        import core.sys.posix.unistd : read, write;

        if (ev.flags & EV_ERROR)
            return -cast(int) ev.data;
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
        }
    }

    bool armFilter(KqOp* op, short filter) @trusted nothrow
    {
        kevent_t change;
        change.ident = cast(size_t) op.fd;
        change.filter = filter;
        change.flags = EV_ADD | EV_ONESHOT;
        change.udata = op;
        if (kevent(_kq, &change, 1, null, 0, null) < 0)
        {
            release(op);
            return false;
        }
        ++_pendCount;
        return true;
    }

    bool armTimer(KqOp* op, long ms) @trusted nothrow
    {
        kevent_t change;
        change.ident = cast(size_t) op.fd; // the unique timer ident
        change.filter = EVFILT_TIMER;
        change.flags = EV_ADD | EV_ONESHOT;
        change.data = cast(ptrdiff_t) ms; // milliseconds (kqueue default unit)
        change.udata = op;
        if (kevent(_kq, &change, 1, null, 0, null) < 0)
        {
            release(op);
            return false;
        }
        ++_pendCount;
        return true;
    }

    static void setNonBlocking(int fd) @trusted nothrow
    {
        import core.sys.posix.fcntl : F_GETFL, F_SETFL, fcntl, O_NONBLOCK;

        const fl = fcntl(fd, F_GETFL, 0);
        if (fl >= 0)
            fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    }

    static int syscallResult(ptrdiff_t r) @safe pure nothrow @nogc
        => r < 0 ? -EAGAIN : cast(int) r;

    KqOp* acquire() @trusted nothrow @nogc
    {
        if (_freeHead == uint.max)
            return null;
        auto op = &_ops[_freeHead];
        _freeHead = op.nextFree;
        return op;
    }

    void release(KqOp* op) @trusted nothrow @nogc
    {
        const idx = cast(uint)(op - _ops.ptr);
        op.nextFree = _freeHead;
        _freeHead = idx;
        if (_pendCount > 0)
            --_pendCount;
    }

    enum size_t maxBatch = 128;
    // Timer idents live in a high range so they never collide with fds.
    enum uint _timerBase = 0x4000_0000;

    int _kq = -1;
    KqOp[] _ops;
    uint _cap;
    uint _freeHead = uint.max;
    uint _pendCount;
    RawCompletion[maxBatch] _ready;
    uint _readyCount;
    RawCompletion[maxBatch] _synth;
    uint _synthCount;
    BackendCaps _caps;
}

version (unittest)
{
    import sparkles.event_horizon.backend.concept : isCompletionBackend;

    static assert(isCompletionBackend!KqueueBackend);
}

version (unittest)
{
    import core.thread : Thread;

    import sparkles.event_horizon.buffer : Buf;
    import sparkles.event_horizon.op : OpClass, OpToken;
}

/// The M10 data-path gate (runs on macOS): register recv/send readiness on a
/// loopback pair, let kqueue synthesize the completions, and confirm the
/// bytes flow — proving the readiness→syscall→completion mapping end to end.
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
        return; // SKIP

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
