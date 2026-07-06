/**
 * Full EventLoop!IocpBackend fiber echo on Windows (run under Wine).
 * The connection is established synchronously (winsock listen/connect/accept);
 * the DATA PATH — recv on the server, echo send, client send + recv — runs
 * through the tier-B fibers + the IOCP backend on one completion port.
 */
module echo_win;

import core.lifetime : move;
import core.thread : Thread;
import std.stdio : writefln, writeln;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.event_horizon.io : Stream, recv, send;
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
    SOCKET accept(SOCKET, void*, int*);
    int connect(SOCKET, const void*, int);
    int getsockname(SOCKET, void*, int*);
    ushort htons(ushort);
    uint htonl(uint);
}

__gshared SOCKET g_client;

int main()
{
    Sched sched;
    if (Sched.create(sched).hasError) // WSAStartup + IOCP port
    {
        writeln("SKIP: IOCP unavailable");
        return 0;
    }
    scope (exit) sched.destroy();

    // A synchronous connected loopback pair.
    const listener = socket(AF_INET, SOCK_STREAM, 0);
    assert(listener != INVALID_SOCKET);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr = htonl(INADDR_LOOPBACK);
    assert(bind(listener, &a, sockaddr_in.sizeof) == 0);
    assert(listen(listener, 1) == 0);
    sockaddr_in bound;
    int blen = sockaddr_in.sizeof;
    getsockname(listener, &bound, &blen);
    const port = bound.sin_port;

    auto ct = new Thread({
        g_client = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in to;
        to.sin_family = AF_INET;
        to.sin_port = port;
        to.sin_addr = htonl(INADDR_LOOPBACK);
        connect(g_client, &to, sockaddr_in.sizeof); // blocks until accepted
    });
    ct.start();
    const server = accept(listener, null, null);
    assert(server != INVALID_SOCKET);
    ct.join();

    static immutable payload = cast(immutable ubyte[]) "hello, iocp echo";
    bool verified;
    auto r = sched.run(() {
        // Server fiber: recv the greeting through IOCP, echo it back.
        cast(void) sched.spawn(() {
            auto srv = Stream(cast(int) server);
            SmallBuffer!(ubyte, 64) buf;
            buf.length = 64;
            auto got = srv.recv(move(buf));
            buf = move(got.buf);
            if (!got.res.hasError && got.res.value > 0)
            {
                buf.length = got.res.value;
                cast(void) srv.send(move(buf));
            }
            srv.close();
        });

        // Client fiber (root): send the greeting, recv the echo.
        auto cli = Stream(cast(int) g_client);
        SmallBuffer!(ubyte, 64) msg;
        msg ~= payload[];
        auto sent = cli.send(move(msg));
        assert(!sent.res.hasError);

        SmallBuffer!(ubyte, 64) back;
        back.length = 64;
        auto echoed = cli.recv(move(back));
        if (!echoed.res.hasError)
            verified = echoed.buf[][0 .. echoed.res.value] == payload[];
        cli.close();
    });
    assert(!r.hasError);

    if (verified)
        writefln("ok: %d-byte payload echoed through fibers on IOCP", payload.length);
    else
        writeln("FAILED");
    return verified ? 0 : 1;
}
