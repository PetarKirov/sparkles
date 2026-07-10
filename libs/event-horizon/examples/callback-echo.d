#!/usr/bin/env dub
/+ dub.sdl:
    name "event_horizon_callback_echo"
    dependency "sparkles:event-horizon" path="../../.."
    platforms "linux"
    targetPath "build"
+/
/**
 * Tier A end to end: a loopback TCP echo round-trip driven entirely through
 * the callback event loop (SPEC §5) — accept, connect, send, and recv all as
 * completion callbacks on one ring, with owned pool buffers moving into ops
 * and coming back through `Completion.buf`.
 *
 * Flow (one `EventLoop`, six callbacks):
 *   1. libc creates a listening socket on 127.0.0.1:0 and a client socket;
 *      `getsockname` recovers the kernel-assigned port.
 *   2. `OpAccept` (server) and `OpConnect` (client) are submitted; both
 *      complete on the same ring.
 *   3. The client sends a payload (`OpSend`); the server receives it
 *      (`OpRecv`), echoes it back by moving the completion's buffer into a
 *      new `OpSend`, and the client's final `OpRecv` verifies the bytes.
 *   4. The last callback calls `loop.stop()`.
 *
 * Run with: `dub run --single callback-echo.d`
 *
 * Portability: if `io_uring` is unavailable (old kernel / seccomp sandbox /
 * `io_uring_disabled`), the program prints a `SKIP:` line and exits 0 so it
 * stays green in CI regardless of host kernel.
 */
module event_horizon_callback_echo;

import core.lifetime : move;
import core.sys.posix.arpa.inet : htonl, htons, ntohs;
import core.sys.posix.netinet.in_ : INADDR_LOOPBACK, sockaddr_in;
import core.sys.posix.sys.socket;
import core.sys.posix.unistd : close;

import std.stdio : stderr, writefln;

import sparkles.event_horizon.buffer : BufferPool;
import sparkles.event_horizon.errors : IoErrorStage;
import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.event_horizon.op;

static immutable ubyte[] payload = cast(immutable ubyte[]) "event horizon \xF0\x9F\x8C\x8C";

struct EchoCtx
{
    DefaultLoop* loop;
    BufferPool!()* pool;
    int clientFd = -1;
    int serverFd = -1;
    bool echoed;
    bool verified;
}

void submitOrDie(T)(T result, string what)
{
    if (result.hasError)
    {
        stderr.writefln("%s failed: errno %d (%s)", what,
            result.error.errnoValue, result.error.context);
        assert(0);
    }
}

extern (D) void onAccept(void* p, ref Completion done) nothrow @nogc
{
    auto ctx = cast(EchoCtx*) p;
    if (done.res < 0)
        assert(0, "accept failed");
    ctx.serverFd = done.res;

    // Await the client's payload on the accepted connection.
    auto buf = ctx.pool.acquire();
    assert(buf.hasValue);
    cast(void) ctx.loop.submit(OpRecv(ctx.serverFd, move(buf.value)), &onServerRecv, p);
}

extern (D) void onConnect(void* p, ref Completion done) nothrow @nogc
{
    auto ctx = cast(EchoCtx*) p;
    if (done.res < 0)
        assert(0, "connect failed");

    // Send the payload from an owned pool buffer.
    auto buf = ctx.pool.acquire();
    assert(buf.hasValue);
    buf.value.space()[0 .. payload.length] = payload[];
    buf.value.length = cast(uint) payload.length;
    cast(void) ctx.loop.submit(OpSend(ctx.clientFd, move(buf.value)), &onClientSent, p);
}

extern (D) void onClientSent(void* p, ref Completion done) nothrow @nogc
{
    auto ctx = cast(EchoCtx*) p;
    assert(done.res == payload.length, "short send");

    // The send's buffer recycles to the pool here (not moved out); arm the
    // final receive for the echoed bytes.
    auto buf = ctx.pool.acquire();
    assert(buf.hasValue);
    cast(void) ctx.loop.submit(OpRecv(ctx.clientFd, move(buf.value)), &onClientRecv, p);
}

extern (D) void onServerRecv(void* p, ref Completion done) nothrow @nogc
{
    auto ctx = cast(EchoCtx*) p;
    assert(done.res > 0, "server recv failed");

    // Echo: the received buffer (length already set from the completion)
    // moves straight into the send — zero copies in userspace.
    ctx.echoed = true;
    cast(void) ctx.loop.submit(OpSend(ctx.serverFd, move(done.buf)), &onServerEchoed, p);
}

extern (D) void onServerEchoed(void*, ref Completion done) nothrow @nogc
{
    assert(done.res == payload.length, "short echo");
}

extern (D) void onClientRecv(void* p, ref Completion done) nothrow @nogc
{
    auto ctx = cast(EchoCtx*) p;
    assert(done.res == payload.length, "short final recv");
    ctx.verified = done.buf[] == payload[];
    ctx.loop.stop();
}

int main()
{
    DefaultLoop loop;
    auto created = DefaultLoop.create(loop);
    if (created.hasError)
    {
        writefln("SKIP: io_uring unavailable (stage %s, errno %d) — %s",
            created.error.stage, created.error.errnoValue, created.error.context);
        return 0;
    }
    scope (exit) loop.destroy();

    // libc socket setup: a loopback listener on a kernel-assigned port.
    const listenFd = socket(AF_INET, SOCK_STREAM, 0);
    assert(listenFd >= 0);
    scope (exit) close(listenFd);

    int one = 1;
    setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &one, one.sizeof);

    sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(listenFd, cast(sockaddr*) &addr, addr.sizeof) != 0
        || listen(listenFd, 1) != 0)
    {
        stderr.writefln("bind/listen failed");
        return 1;
    }
    socklen_t len = addr.sizeof;
    getsockname(listenFd, cast(sockaddr*) &addr, &len);

    const clientFd = socket(AF_INET, SOCK_STREAM, 0);
    assert(clientFd >= 0);
    scope (exit) close(clientFd);

    BufferPool!() pool;
    submitOrDie(BufferPool!().create(pool, 4, 4096), "pool create");

    EchoCtx ctx;
    ctx.loop = &loop;
    ctx.pool = &pool;
    ctx.clientFd = clientFd;

    // Arm the accept, then drive the connect through the same ring.
    submitOrDie(loop.submit(OpAccept(listenFd), &onAccept, &ctx), "accept submit");

    SockAddr to;
    to.storage[0 .. addr.sizeof] = (cast(ubyte*) &addr)[0 .. addr.sizeof];
    to.len = addr.sizeof;
    submitOrDie(loop.submit(OpConnect(clientFd, to), &onConnect, &ctx), "connect submit");

    submitOrDie(loop.run(), "loop run");
    scope (exit) if (ctx.serverFd >= 0) close(ctx.serverFd);

    assert(ctx.echoed, "server never echoed");
    assert(ctx.verified, "payload mismatch after the round-trip");
    writefln("ok: %d-byte payload echoed through the callback loop (port %d)",
        cast(int) payload.length, ntohs(addr.sin_port));
    return 0;
}
