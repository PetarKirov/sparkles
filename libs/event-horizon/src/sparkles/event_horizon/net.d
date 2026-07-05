/**
Networking vocabulary and the net capability concepts (SPEC §10.3).

$(B Effects-side module): the address types and helpers, the `isNet`/
`isByteStream` concepts, and the deterministic `SimNet` test double live
here with no ring imports; the live ring-backed implementation joins the
loop-side `live` module in M9. (Loop-side modules import this one — the
firewall is one-directional.)
*/
module sparkles.event_horizon.net;

import core.lifetime : move;
import core.stdc.errno : ECONNREFUSED, ECONNRESET, ENOTCONN, EPIPE;

import sparkles.event_horizon.capability : isCapability, isWaker;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr, ioOk;

/// A `sockaddr_storage`-sized POD plus its length — library-owned (SPEC
/// §4.1): peer backends and test doubles use it without any libc coupling.
struct SockAddr
{
    ubyte[128] storage; /// raw sockaddr bytes (or an opaque test-double key)
    uint len;           /// valid length of `storage`

    /// Value equality over the valid bytes (the test doubles key on it).
    bool opEquals(in SockAddr rhs) const @safe pure nothrow @nogc
        => len == rhs.len && storage[0 .. len] == rhs.storage[0 .. len];
}

/// Builds an IPv4 `SockAddr` (`AF_INET`, network byte order).
SockAddr ipv4(string dottedQuad, ushort port) @safe pure nothrow @nogc
{
    // Hand-rolled parse: keeps this @nogc and CTFE-friendly.
    uint addr;
    uint octet;
    uint seen;
    foreach (c; dottedQuad)
    {
        if (c == '.')
        {
            addr = (addr << 8) | octet;
            octet = 0;
            ++seen;
        }
        else
        {
            assert(c >= '0' && c <= '9', "malformed IPv4 literal");
            octet = octet * 10 + (c - '0');
            assert(octet <= 255, "IPv4 octet out of range");
        }
    }
    assert(seen == 3, "malformed IPv4 literal");
    addr = (addr << 8) | octet;

    // struct sockaddr_in { u16 family; u16 port(be); u32 addr(be); … }
    SockAddr a;
    a.storage[0] = 2; // AF_INET, little-endian u16
    a.storage[1] = 0;
    a.storage[2] = cast(ubyte) (port >> 8);
    a.storage[3] = cast(ubyte) port;
    a.storage[4] = cast(ubyte) (addr >> 24);
    a.storage[5] = cast(ubyte) (addr >> 16);
    a.storage[6] = cast(ubyte) (addr >> 8);
    a.storage[7] = cast(ubyte) addr;
    a.len = 16; // sockaddr_in.sizeof
    return a;
}

// ── the concepts (exact-expression traits, `isClock`-style) ─────────────────

/// The byte-stream concept the direct-style verbs and `SimNet.Stream`
/// share: owned-buffer `recv`/`send` shapes plus `close`.
enum bool isByteStream(S) = __traits(compiles, (ref S s) {
    s.close();
});

/// The net capability concept: member handle types plus `listen`/`connect`.
enum bool isNet(C) = isCapability!C && C.capName == "net"
    && is(C.Stream) && is(C.Listener)
    && __traits(compiles, (ref C c) {
        IoResult!(C.Listener) l = c.listen(SockAddr.init);
        IoResult!(C.Stream) s = c.connect(SockAddr.init);
    });

// ── SimNet: the deterministic in-memory test double (SPEC §10.3) ────────────

/**
A deterministic in-memory network: `listen`/`connect` pair by `SockAddr`,
streams are loss-free duplex byte pipes, and `partition` severs a link for
fault-injection. Fibers park through the loop-free `isWaker` seam; there is
no real I/O anywhere. (A test double: GC-backed storage is fine here.)
*/
struct SimNet(W)
if (isWaker!W)
{
    enum string capName = "net";

    /// Constructs over the executor's park/wake view.
    this(W waker) @safe nothrow @nogc
    {
        _waker = waker;
    }

    /// One direction of a duplex pipe.
    private static struct Pipe
    {
        ubyte[] data;      // buffered bytes in flight
        W.Handle waiter;   // a parked reader, if any
        bool hasWaiter;
        bool closed;       // writer side closed (EOF after drain)
        bool severed;      // partitioned: reads/writes fail
    }

    private static struct Conn
    {
        Pipe[2] pipes;     // [0]: client→server, [1]: server→client
        SockAddr client;
        SockAddr server;
    }

    private static struct ListenerState
    {
        SockAddr at;
        Conn*[] backlog;   // connections awaiting accept
        W.Handle waiter;   // a parked acceptor
        bool hasWaiter;
        bool open = true;
    }

    /// A connected stream endpoint.
    static struct Stream
    {
        private SimNet* net;
        private Conn* conn;
        private ubyte sendIdx; // which pipe this endpoint writes to

        /// Receives up to `buf.length` bytes into `buf`; parks until data,
        /// EOF (`0`), or a fault.
        IoResult!uint recv(scope ubyte[] buf)
            => net.pipeRecv(&conn.pipes[1 - sendIdx], buf);

        /// Sends all of `bytes`; a severed link fails with `ECONNRESET`.
        IoResult!uint send(scope const(ubyte)[] bytes)
            => net.pipeSend(&conn.pipes[sendIdx], bytes);

        /// Closes this endpoint's write side (the peer reads EOF after the
        /// buffered bytes drain).
        void close() @safe nothrow
        {
            if (conn is null)
                return;
            net.pipeClose(&conn.pipes[sendIdx]);
            conn = null;
        }
    }

    /// A listening endpoint; `accept` parks until a connection arrives.
    static struct Listener
    {
        private SimNet* net;
        private size_t idx;

        /// Accepts one connection (the server-side stream).
        IoResult!Stream accept()
            => net.acceptOn(idx);

        /// Stops listening; parked acceptors fail with `ECONNRESET`.
        void close() @safe nothrow
        {
            net.closeListener(idx);
        }
    }

    static assert(isByteStream!Stream);

    /// Starts listening at `at`.
    IoResult!Listener listen(SockAddr at) @trusted nothrow
    {
        _listeners ~= ListenerState(at);
        return ioOk(Listener((() @trusted => &this)(), _listeners.length - 1));
    }

    /// Connects to a listener at `to`; `ECONNREFUSED` when nobody listens.
    IoResult!Stream connect(SockAddr to) @trusted nothrow
    {
        foreach (i, ref l; _listeners)
        {
            if (!l.open || l.at != to)
                continue;
            auto conn = new Conn;
            conn.server = to;
            l.backlog ~= conn;
            if (l.hasWaiter)
            {
                l.hasWaiter = false;
                _waker.wake(l.waiter);
            }
            return ioOk(Stream(&this, conn, 0));
        }
        return ioErr!Stream(ECONNREFUSED, OpKind.connect, IoErrorStage.completion,
            "no listener at that address");
    }

    /// Severs (or heals) both directions between every established
    /// connection of `a` and `b` — the fault-injection knob.
    void partition(SockAddr a, SockAddr b, bool severed) @safe nothrow
    {
        foreach (ref l; _listeners)
        {
            if (l.at != a && l.at != b)
                continue;
            foreach (conn; l.backlog)
                severConn(conn, severed);
        }
        foreach (conn; _accepted)
            if (conn.server == a || conn.server == b)
                severConn(conn, severed);
    }

private:
    void severConn(Conn* conn, bool severed) @safe nothrow
    {
        foreach (ref p; conn.pipes)
        {
            p.severed = severed;
            if (severed && p.hasWaiter)
            {
                p.hasWaiter = false;
                _waker.wake(p.waiter);
            }
        }
    }

    IoResult!Stream acceptOn(size_t idx) @trusted nothrow
    {
        for (;;)
        {
            auto l = &_listeners[idx];
            if (!l.open)
                return ioErr!Stream(ECONNRESET, OpKind.accept,
                    IoErrorStage.completion, "listener closed");
            if (l.backlog.length > 0)
            {
                auto conn = l.backlog[0];
                l.backlog = l.backlog[1 .. $];
                _accepted ~= conn;
                return ioOk(Stream(&this, conn, 1));
            }
            l.waiter = _waker.prepare();
            l.hasWaiter = true;
            _waker.park(l.waiter);
        }
    }

    void closeListener(size_t idx) @safe nothrow
    {
        auto l = &_listeners[idx];
        l.open = false;
        if (l.hasWaiter)
        {
            l.hasWaiter = false;
            _waker.wake(l.waiter);
        }
    }

    IoResult!uint pipeRecv(Pipe* p, scope ubyte[] buf) @trusted nothrow
    {
        for (;;)
        {
            if (p.severed)
                return ioErr!uint(ECONNRESET, OpKind.recv,
                    IoErrorStage.completion, "link severed");
            if (p.data.length > 0)
            {
                const n = p.data.length < buf.length ? p.data.length : buf.length;
                buf[0 .. n] = p.data[0 .. n];
                p.data = p.data[n .. $];
                return ioOk(cast(uint) n);
            }
            if (p.closed)
                return ioOk(0u); // EOF
            p.waiter = _waker.prepare();
            p.hasWaiter = true;
            _waker.park(p.waiter);
        }
    }

    IoResult!uint pipeSend(Pipe* p, scope const(ubyte)[] bytes) @trusted nothrow
    {
        if (p.severed)
            return ioErr!uint(ECONNRESET, OpKind.send, IoErrorStage.completion,
                "link severed");
        if (p.closed)
            return ioErr!uint(EPIPE, OpKind.send, IoErrorStage.completion,
                "peer closed");
        p.data ~= bytes;
        if (p.hasWaiter)
        {
            p.hasWaiter = false;
            _waker.wake(p.waiter);
        }
        return ioOk(cast(uint) bytes.length);
    }

    void pipeClose(Pipe* p) @safe nothrow
    {
        p.closed = true;
        if (p.hasWaiter)
        {
            p.hasWaiter = false;
            _waker.wake(p.waiter);
        }
    }

    W _waker;
    ListenerState[] _listeners;
    Conn*[] _accepted;
}

@("net.ipv4.encodesSockaddrIn")
@safe pure nothrow @nogc
unittest
{
    const a = ipv4("127.0.0.1", 8080);
    assert(a.len == 16);
    assert(a.storage[0] == 2); // AF_INET
    assert(a.storage[2] == 0x1F && a.storage[3] == 0x90); // 8080 BE
    assert(a.storage[4] == 127 && a.storage[7] == 1);

    const b = ipv4("127.0.0.1", 8080);
    assert(a == b);
    assert(a != ipv4("127.0.0.1", 8081));

    static assert(ipv4("10.0.0.1", 80).len == 16, "CTFE-usable");
}
