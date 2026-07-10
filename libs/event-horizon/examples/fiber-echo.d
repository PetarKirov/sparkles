#!/usr/bin/env dub
/+ dub.sdl:
    name "event_horizon_fiber_echo"
    dependency "sparkles:event-horizon" path="../../.."
    platforms "linux"
    targetPath "build"
+/
/**
 * Tier B end to end: the same loopback TCP echo as `callback-echo.d`, in
 * direct style (SPEC §7) — no callbacks, no state machine, no function
 * coloring. Each side is a fiber running blocking-looking code; every
 * `accept`/`connect`/`send`/`recv` parks the fiber on an SQE and resumes on
 * its terminal CQE, and buffers move in and come back (`BufResult`).
 *
 * Compare `echo()` here with the six callbacks of `callback-echo.d`: same
 * kernel traffic, same completion loop underneath — the fiber tier is a
 * scheduler over tier A, not a second implementation.
 *
 * Run with: `dub run --single fiber-echo.d`
 *
 * Portability: prints a `SKIP:` line and exits 0 if `io_uring` is
 * unavailable, so it stays green in CI regardless of host kernel.
 */
module event_horizon_fiber_echo;

import core.lifetime : move;
import core.sys.posix.arpa.inet : htonl, ntohs;
import core.sys.posix.netinet.in_ : INADDR_LOOPBACK, sockaddr_in;
import core.sys.posix.sys.socket;

import std.stdio : writefln;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.event_horizon.io;
import sparkles.event_horizon.op : SockAddr;
import sparkles.event_horizon.sched : Sched;

static immutable ubyte[] payload = cast(immutable ubyte[]) "event horizon \xF0\x9F\x8C\x8C";

/// One connection's whole life, in direct style.
void echo(Stream conn)
{
    scope (exit) conn.close();
    SmallBuffer!(ubyte, 4096) buf;
    buf.length = 4096;
    for (;;)
    {
        auto r = conn.recv(move(buf)); // parks; resumes on the CQE
        buf = move(r.buf);             // the buffer comes back
        if (r.res.hasError || r.res.value == 0)
            return;                    // error / EOF
        buf.length = r.res.value;
        auto w = conn.send(move(buf));
        buf = move(w.buf);
        buf.length = 4096;
        if (w.res.hasError)
            return;
    }
}

int main()
{
    Sched sched;
    auto created = Sched.create(sched);
    if (created.hasError)
    {
        writefln("SKIP: io_uring unavailable (errno %d) — %s",
            created.error.errnoValue, created.error.context);
        return 0;
    }
    scope (exit) sched.destroy();

    // libc: a loopback listener on a kernel-assigned port.
    const listenFd = socket(AF_INET, SOCK_STREAM, 0);
    assert(listenFd >= 0);
    sockaddr_in a;
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listenFd, cast(sockaddr*) &a, a.sizeof) != 0 || listen(listenFd, 4) != 0)
    {
        writefln("SKIP: bind/listen failed");
        return 0;
    }
    socklen_t len = a.sizeof;
    getsockname(listenFd, cast(sockaddr*) &a, &len);
    SockAddr addr;
    addr.storage[0 .. a.sizeof] = (cast(ubyte*) &a)[0 .. a.sizeof];
    addr.len = a.sizeof;

    auto listener = Listener(listenFd);

    bool verified;
    auto r = sched.run(() {
        // Server: accept one connection, serve it in a child fiber.
        cast(void) sched.spawn(() {
            auto conn = listener.accept;
            if (conn.hasValue)
                echo(conn.value);
        });

        // Client (the root fiber): one round-trip.
        Stream client;
        client.fd = socket(AF_INET, SOCK_STREAM, 0);
        assert(client.fd >= 0);
        scope (exit) client.close();
        assert(!client.connect(addr).hasError);

        SmallBuffer!(ubyte, 4096) msg;
        msg ~= payload[];
        auto sent = client.send(move(msg));
        assert(!sent.res.hasError && sent.res.value == payload.length);

        SmallBuffer!(ubyte, 4096) back;
        back.length = 4096;
        auto got = client.recv(move(back));
        assert(!got.res.hasError && got.res.value == payload.length);
        verified = got.buf[][0 .. got.res.value] == payload[];
    });
    assert(!r.hasError);
    listener.close();

    assert(verified, "payload mismatch after the round-trip");
    writefln("ok: %d-byte payload echoed through fibers, direct style (port %d)",
        cast(int) payload.length, ntohs(a.sin_port));
    return 0;
}
