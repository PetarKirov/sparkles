/**
Tier B — the direct-style I/O verbs (SPEC §7.3): blocking-looking shims over
the scheduler's await seam. Every verb parks the calling fiber at most once
and resumes only at the op's terminal completion.

`Stream`/`Listener`/`DgramSocket`/`FileHandle` are small copyable
fd-carrying handles with an explicit `close()` — they own no memory and
carry no ring state; the verbs resolve the scheduler from the current fiber.
Handles are created by the net/fs capabilities (M6/M7); until those land,
tier-B code wraps raw fds directly.

Buffer genericity (SPEC §6.5): the verbs accept any owned buffer type whose
memory is stable while the value is not moved (`isOwnedIoBuf`) — including
inline-storage types like `SmallBuffer`. The moved-in buffer lives in the
suspended verb's stack frame, and the fiber resumes only at the terminal
completion, so the frame (hence the buffer) provably outlives kernel use;
internally the view is wrapped as a foreign `Buf` for the tier-A slot.
*/
module sparkles.event_horizon.io;

version (linux)  :  // rides the linux Sched; generalizes with M10

import core.lifetime : move;
import core.time : Duration;

import sparkles.event_horizon.buffer : Buf, isOwnedIoBuf;
import sparkles.event_horizon.errors;
import sparkles.event_horizon.op;
import sparkles.event_horizon.sched : AwaitOutcome, FiberTask, Sched;

/// The owned-transfer result shape (SPEC §6.2): the buffer always comes
/// back, success or failure.
struct BufResult(B)
{
    B buf;             /// ownership returned — the kernel is done with it
    IoResult!uint res; /// bytes transferred, or the error
}

/// A connected byte-stream socket.
struct Stream
{
    int fd = -1;

    /// Explicit close (handles are copyable views; exactly one owner
    /// should close).
    void close() @trusted nothrow @nogc
    {
        if (fd < 0)
            return;
        import core.sys.posix.unistd : close_ = close;

        close_(fd);
        fd = -1;
    }
}

/// A listening socket; `accept` yields `Stream`s.
struct Listener
{
    int fd = -1;

    /// ditto
    void close() @trusted nothrow @nogc
    {
        Stream s = {fd: fd};
        s.close();
        fd = -1;
    }
}

/// An unconnected datagram socket.
struct DgramSocket
{
    int fd = -1;

    /// ditto
    void close() @trusted nothrow @nogc
    {
        Stream s = {fd: fd};
        s.close();
        fd = -1;
    }
}

/// An open file.
struct FileHandle
{
    int fd = -1;

    /// ditto
    void close() @trusted nothrow @nogc
    {
        Stream s = {fd: fd};
        s.close();
        fd = -1;
    }
}

// ── the verbs ───────────────────────────────────────────────────────────────

/// Positioned read into the buffer's view (`offset == ulong.max` reads at
/// the current file position — pipes and sockets require it).
BufResult!B read(B)(FileHandle f, B buf, ulong offset = ulong.max)
if (isOwnedIoBuf!B)
    => rw!(OpRead, No.sized)(f.fd, move(buf), offset);

/// Positioned write of the buffer's view.
BufResult!B write(B)(FileHandle f, B buf, ulong offset = ulong.max)
if (isOwnedIoBuf!B)
    => rw!(OpWrite, Yes.sized)(f.fd, move(buf), offset);

/// Receives into the buffer's view.
BufResult!B recv(B)(ref Stream s, B buf) if (isOwnedIoBuf!B)
    => rw!(OpRecv, No.sized)(s.fd, move(buf));

/// Sends the buffer's view.
BufResult!B send(B)(ref Stream s, B buf) if (isOwnedIoBuf!B)
    => rw!(OpSend, Yes.sized)(s.fd, move(buf));

/// Parks until a connection arrives; the result is the connected stream.
IoResult!Stream accept(ref Listener l)
{
    auto o = currentSched().await(OpAccept(l.fd));
    if (o.res < 0)
        return ioErr!Stream(-o.res, OpKind.accept);
    return ioOk(Stream(o.res));
}

/// Parks until the connect completes.
IoResult!void connect(ref Stream s, in SockAddr addr)
{
    auto o = currentSched().await(OpConnect(s.fd, addr));
    if (o.res < 0)
        return ioErr!void(-o.res, OpKind.connect);
    return ioOk();
}

/// Parks the calling fiber for `d` (an in-ring timer, not a thread sleep).
IoResult!void sleep(ref Sched s, Duration d)
{
    long secs, nsecs;
    d.split!("seconds", "nsecs")(secs, nsecs);
    auto o = s.await(OpTimeout(KernelTimespec(secs, nsecs)));
    if (o.res < 0)
        return ioErr!void(-o.res, OpKind.timeout);
    return ioOk();
}

/// Cooperative reschedule (a checkpoint once M5's cancellation lands).
IoResult!void yieldNow(ref Sched s)
{
    s.yieldNow();
    return ioOk();
}

/// A full ring round-trip that does nothing: parks on a NOP submission and
/// resumes on its completion. The canonical await-overhead probe.
IoResult!void nop(ref Sched s)
{
    auto o = s.await(OpNop());
    if (o.res < 0)
        return ioErr!void(-o.res, OpKind.nop);
    return ioOk();
}

// ── plumbing ────────────────────────────────────────────────────────────────

import std.typecons : Flag, No, Yes;

/// The scheduler of the current fiber; asserts off-fiber.
private Sched* currentSched() @safe nothrow @nogc
{
    auto t = Sched.tryCurrent();
    assert(t !is null, "tier-B verbs must run on a scheduler fiber");
    return t.owner;
}

/**
The shared verb body. For the loop's own pinned `Buf` the descriptor takes
it by move (pool/registered lowering preserved); for any other owned buffer
the view is wrapped as a deleter-less foreign `Buf` — sound because this
frame is parked until the terminal completion (SPEC §6.5). `sized` selects
between the valid-bytes view (send/write) and the capacity view (recv/read).
*/
private BufResult!B rw(Op, Flag!"sized" sized, B, Args...)(
    int fd, B buf, Args args)
{
    auto sched = currentSched();

    static if (is(B == Buf))
    {
        auto o = sched.await(Op(fd, move(buf), args));
        BufResult!B r = {buf: move(o.buf), res: fromRes(o.res, Op.kind)};
        return r;
    }
    else
    {
        static if (sized)
            auto view = buf[];
        else static if (__traits(compiles, buf.space()))
            auto view = buf.space();
        else
            auto view = buf[];

        auto foreign = (() @trusted => Buf.fromForeign(view, null))();
        static if (!sized)
            foreign.length = foreign.capacity; // expose the whole window
        else
            foreign.length = cast(uint) view.length;

        auto o = sched.await(Op(fd, move(foreign), args));
        // o.buf is the foreign handle coming back; dropping it is a no-op
        // release. The caller's buffer never left this frame.
        BufResult!B r = {buf: move(buf), res: fromRes(o.res, Op.kind)};
        return r;
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

@("io.pipe.directStyleReadWrite")
@safe
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    Sched s;
    if (Sched.create(s).hasError)
        return; // SKIP: io_uring unavailable
    scope (exit) s.destroy();

    int[2] fds;
    if ((() @trusted {
        import core.sys.posix.unistd : pipe;

        return pipe(fds);
    })() != 0)
        return;

    auto rd = FileHandle(fds[0]);
    auto wr = FileHandle(fds[1]);
    scope (exit)
    {
        rd.close();
        wr.close();
    }

    static immutable payload = cast(immutable ubyte[]) "direct style";

    bool verified;
    auto r = s.run(() {
        // Writer fiber: SmallBuffer on this frame — the inline-storage
        // soundness case of SPEC §6.5.
        cast(void) s.spawn(() {
            SmallBuffer!(ubyte, 64) out_;
            out_ ~= payload[];
            auto w = write(wr, move(out_));
            assert(!w.res.hasError && w.res.value == payload.length);
        });

        SmallBuffer!(ubyte, 64) in_;
        in_.length = 64;
        auto got = read(rd, move(in_));
        assert(!got.res.hasError);
        assert(got.res.value == payload.length);
        verified = got.buf[][0 .. got.res.value] == payload[];
    });
    assert(!r.hasError);
    assert(verified);
}

@("io.loopback.directStyleEcho")
@safe
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.event_horizon.buffer : BufferPool;

    Sched s;
    if (Sched.create(s).hasError)
        return; // SKIP
    scope (exit) s.destroy();

    // libc loopback listener on a kernel-assigned port.
    int listenFd;
    SockAddr addr;
    if (!(() @trusted {
        import core.sys.posix.arpa.inet : htonl;
        import core.sys.posix.netinet.in_ : INADDR_LOOPBACK, sockaddr_in;
        import core.sys.posix.sys.socket;

        listenFd = socket(AF_INET, SOCK_STREAM, 0);
        if (listenFd < 0)
            return false;
        sockaddr_in a;
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(listenFd, cast(sockaddr*) &a, a.sizeof) != 0
            || listen(listenFd, 1) != 0)
            return false;
        socklen_t len = a.sizeof;
        getsockname(listenFd, cast(sockaddr*) &a, &len);
        addr.storage[0 .. a.sizeof] = (cast(ubyte*) &a)[0 .. a.sizeof];
        addr.len = a.sizeof;
        return true;
    })())
        return;

    auto listener = Listener(listenFd);
    scope (exit) listener.close();

    static immutable payload = cast(immutable ubyte[]) "fiber echo";

    BufferPool pool;
    assert(!BufferPool.create(pool, 2, 256).hasError);

    bool verified;
    auto r = s.run(() @trusted {
        // Server fiber: accept one connection, echo one message.
        cast(void) s.spawn(() {
            auto conn = listener.accept;
            assert(conn.hasValue);
            auto peer = conn.value;
            scope (exit) peer.close();

            auto b = pool.acquire();
            auto got = peer.recv(move(b.value));
            assert(!got.res.hasError && got.res.value == payload.length);
            auto sent = peer.send(move(got.buf)); // pinned pool Buf path
            assert(!sent.res.hasError && sent.res.value == payload.length);
        });

        // Client fiber (the root): connect, send, verify the echo.
        Stream client;
        (() @trusted {
            import core.sys.posix.sys.socket : AF_INET, SOCK_STREAM, socket;

            client.fd = socket(AF_INET, SOCK_STREAM, 0);
        })();
        assert(client.fd >= 0);
        scope (exit) client.close();

        assert(!client.connect(addr).hasError);

        SmallBuffer!(ubyte, 64) msg;
        msg ~= payload[];
        auto sent = client.send(move(msg));
        assert(!sent.res.hasError && sent.res.value == payload.length);

        SmallBuffer!(ubyte, 64) back;
        back.length = 64;
        auto got = client.recv(move(back));
        assert(!got.res.hasError && got.res.value == payload.length);
        verified = got.buf[][0 .. got.res.value] == payload[];
    });
    assert(!r.hasError);
    assert(verified);
}

@("io.sleep.parksTheFiber")
@safe
unittest
{
    import core.time : MonoTime, msecs;

    Sched s;
    if (Sched.create(s).hasError)
        return; // SKIP
    scope (exit) s.destroy();

    const before = MonoTime.currTime;
    auto r = s.run(() { assert(!sleep(s, 5.msecs).hasError); });
    assert(!r.hasError);
    assert(MonoTime.currTime - before >= 5.msecs);
}
