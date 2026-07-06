/**
 * Full async EventLoop!IocpBackend fiber echo on Windows (run under Wine):
 * accept (AcceptEx) and connect (ConnectEx) go through the loop too, so the
 * whole echo — accept, connect, recv, send — is driven by the fibers + IOCP.
 */
module echo_iocp_async;

import core.lifetime : move;
import std.stdio : writefln, writeln;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.event_horizon.io : Listener, Stream, accept, connect, recv, send;
import sparkles.event_horizon.net : SockAddr;
import sparkles.event_horizon.sched : Sched;

alias SOCKET = size_t;
enum SOCKET INVALID_SOCKET = ~cast(SOCKET) 0;
enum int AF_INET = 2, SOCK_STREAM = 1;
enum uint INADDR_LOOPBACK = 0x7f00_0001;
struct sockaddr_in { short sin_family; ushort sin_port; uint sin_addr; ubyte[8] sin_zero; }
extern (Windows) nothrow @nogc
{
    SOCKET socket(int, int, int);
    int bind(SOCKET, const void*, int);
    int listen(SOCKET, int);
    int getsockname(SOCKET, void*, int*);
    ushort htons(ushort);
    uint htonl(uint);
}

static immutable payload = cast(immutable ubyte[]) "hello, iocp async";

void echo(Stream conn)
{
    scope (exit) conn.close();
    SmallBuffer!(ubyte, 64) buf;
    buf.length = 64;
    auto r = conn.recv(move(buf));
    buf = move(r.buf);
    if (r.res.hasError || r.res.value == 0)
        return;
    buf.length = r.res.value;
    cast(void) conn.send(move(buf));
}

int main()
{
    Sched sched;
    if (Sched.create(sched).hasError)
    {
        writeln("SKIP: IOCP unavailable");
        return 0;
    }
    scope (exit) sched.destroy();

    const listenFd = socket(AF_INET, SOCK_STREAM, 0);
    assert(listenFd != INVALID_SOCKET);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr = htonl(INADDR_LOOPBACK);
    assert(bind(listenFd, &a, sockaddr_in.sizeof) == 0);
    assert(listen(listenFd, 4) == 0);
    sockaddr_in bound;
    int blen = sockaddr_in.sizeof;
    getsockname(listenFd, &bound, &blen);

    SockAddr addr;
    (cast(ubyte*) &addr.storage[0])[0 .. sockaddr_in.sizeof] =
        (cast(ubyte*) &bound)[0 .. sockaddr_in.sizeof];
    addr.len = sockaddr_in.sizeof;

    auto listener = Listener(cast(int) listenFd);
    bool verified;
    auto r = sched.run(() {
        // Server fiber: accept a connection through the loop (AcceptEx).
        cast(void) sched.spawn(() {
            auto conn = listener.accept;
            if (conn.hasValue)
                echo(conn.value);
        });

        // Client fiber (root): connect through the loop (ConnectEx).
        auto client = Stream(cast(int) socket(AF_INET, SOCK_STREAM, 0));
        scope (exit) client.close();
        if (client.connect(addr).hasError)
            return;
        SmallBuffer!(ubyte, 64) msg;
        msg ~= payload[];
        auto sent = client.send(move(msg));
        assert(!sent.res.hasError);
        SmallBuffer!(ubyte, 64) back;
        back.length = 64;
        auto echoed = client.recv(move(back));
        if (!echoed.res.hasError)
            verified = echoed.buf[][0 .. echoed.res.value] == payload[];
    });
    assert(!r.hasError);

    if (verified)
        writefln("ok: %d-byte payload echoed — accept+connect+recv+send all through the IOCP loop",
            payload.length);
    else
        writeln("FAILED");
    return verified ? 0 : 1;
}
