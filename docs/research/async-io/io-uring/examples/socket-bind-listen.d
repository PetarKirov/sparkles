#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_socket_bind_listen"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — the async socket lifecycle: `SOCKET` + `BIND` + `LISTEN` (Linux 6.11).
 *
 * Pre-6.11, setting up a listener still required synchronous syscalls
 * (`socket(2)`, `bind(2)`, `listen(2)`) outside the ring. 5.19 added
 * `IORING_OP_SOCKET`; 6.11 completed the picture with `IORING_OP_BIND` and
 * `IORING_OP_LISTEN`, so the *entire* server-side setup can flow through the
 * ring without ever leaving io_uring's submit/complete loop.
 *
 * This example drives that full lifecycle on TCP/127.0.0.1:
 *   1. `SOCKET(AF_INET, SOCK_STREAM)` — kernel creates the fd, returns it in `res`.
 *   2. `BIND(fd, 127.0.0.1:0)`        — kernel picks an ephemeral port.
 *   3. `LISTEN(fd, backlog)`          — fd becomes a passive listener.
 * Then it proves the listener actually serves connections: a libc `connect(2)`
 * from a client fd, matched by an in-ring `ACCEPT` that hands back the server
 * side of the connection.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md § "6.11 — Async bind/listen".
 *
 * Run with: `dub run --single socket-bind-listen.d`
 *
 * Portability: if io_uring is unavailable, or `SOCKET` (<5.19) / `BIND`/`LISTEN`
 * (<6.11) are not supported on the running kernel (op returns `-EINVAL` /
 * `-EOPNOTSUPP`), the program prints a `SKIP:` line and exits 0.
 */
module io_uring_socket_bind_listen;

import during;

import core.sys.linux.errno : EINVAL, EOPNOTSUPP, ENOSYS;
import core.sys.posix.arpa.inet : htonl;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.socket;
import core.sys.posix.unistd : close;

import std.stdio : writefln, stderr;

// A feature is "unsupported on this kernel" if the op CQE comes back with one of
// these. Treated as SKIP (exit 0) rather than a hard failure.
private bool unsupported(int res) @safe @nogc nothrow pure
{
    return res == -EINVAL || res == -EOPNOTSUPP || res == -ENOSYS;
}

// Submit exactly one already-queued SQE and block (bounded by the kernel) for its
// single completion. Returns the CQE's `res` and pops it. We submit one op at a
// time because BIND/LISTEN/ACCEPT each depend on the fd produced by the prior op.
private int submitOne(ref Uring io) @trusted
{
    const submitted = io.submit(1);
    if (submitted < 0)
        return submitted;
    io.wait(1);
    const res = io.front.res;
    io.popFront();
    return res;
}

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // 1) SOCKET — create the listening socket through the ring (5.19).
    //    The new fd is returned in the CQE's `res` field (like socket(2)).
    io.putWith!(
        (ref SubmissionEntry e)
        {
            e.prepSocket(AF_INET, SOCK_STREAM, 0, 0);
            e.user_data = 1;
        })();

    int srvRes = submitOne(io);
    if (unsupported(srvRes))
    {
        writefln("SKIP: IORING_OP_SOCKET unsupported (errno %d) — needs Linux 5.19+", -srvRes);
        return 0;
    }
    if (srvRes < 0)
    {
        stderr.writefln("SOCKET failed: errno %d", -srvRes);
        return 1;
    }
    const int srv = srvRes; // the kernel-created server fd
    scope (exit) close(srv);

    // 127.0.0.1:0 — port 0 lets the kernel assign an ephemeral port.
    sockaddr_in saddr;
    saddr.sin_family = AF_INET;
    saddr.sin_port = 0;
    saddr.sin_addr.s_addr = htonl(0x7f000001);

    // 2) BIND — async bind(2) on the in-ring fd (6.11). res == 0 on success.
    io.putWith!(
        (ref SubmissionEntry e, int fd, sockaddr_in* a)
        {
            e.prepBind(fd, *a, sockaddr_in.sizeof);
            e.user_data = 2;
        })(srv, &saddr);

    const bindRes = submitOne(io);
    if (unsupported(bindRes))
    {
        writefln("SKIP: IORING_OP_BIND unsupported (errno %d) — needs Linux 6.11+", -bindRes);
        return 0;
    }
    if (bindRes != 0)
    {
        stderr.writefln("BIND failed: errno %d", -bindRes);
        return 1;
    }

    // 3) LISTEN — async listen(2), backlog 4 (6.11). res == 0 on success.
    io.putWith!(
        (ref SubmissionEntry e, int fd)
        {
            e.prepListen(fd, 4);
            e.user_data = 3;
        })(srv);

    const listenRes = submitOne(io);
    if (unsupported(listenRes))
    {
        writefln("SKIP: IORING_OP_LISTEN unsupported (errno %d) — needs Linux 6.11+", -listenRes);
        return 0;
    }
    if (listenRes != 0)
    {
        stderr.writefln("LISTEN failed: errno %d", -listenRes);
        return 1;
    }

    // Discover the kernel-assigned ephemeral port so the client knows where to dial.
    sockaddr_in bound;
    socklen_t blen = bound.sizeof;
    if (getsockname(srv, cast(sockaddr*)&bound, &blen) != 0)
    {
        stderr.writefln("getsockname failed");
        return 1;
    }
    const ushort port = ntohs(bound.sin_port);

    // Now prove the listener works end to end. Connect from a second (libc) fd
    // first: on loopback the TCP handshake completes into the listen backlog
    // immediately, so a blocking connect() returns without needing an accept yet.
    // Doing the connect *before* queuing the ring ACCEPT keeps the demo
    // deadlock-free and bounded — there is already a pending connection when we
    // submit, so ACCEPT completes on the first wait.
    int cli = socket(AF_INET, SOCK_STREAM, 0);
    if (cli < 0)
    {
        stderr.writefln("client socket() failed");
        return 1;
    }
    scope (exit) close(cli);

    if (connect(cli, cast(sockaddr*)&bound, blen) != 0)
    {
        stderr.writefln("client connect() failed");
        return 1;
    }

    // ACCEPT through the ring — the pending connection is dequeued and the new
    // server-side fd is returned in the CQE's `res`, mirroring accept(2).
    sockaddr_in caddr;
    socklen_t clen = caddr.sizeof;

    io.putWith!(
        (ref SubmissionEntry e, int fd, sockaddr_in* a, socklen_t* l)
        {
            e.prepAccept(fd, *a, *l);
            e.user_data = 4;
        })(srv, &caddr, &clen);

    if (io.submit(1) < 0)
    {
        stderr.writefln("submit(ACCEPT) failed");
        return 1;
    }

    io.wait(1);
    const accRes = io.front.res;
    io.popFront();

    if (unsupported(accRes))
    {
        writefln("SKIP: IORING_OP_ACCEPT unsupported (errno %d)", -accRes);
        return 0;
    }
    if (accRes < 0)
    {
        stderr.writefln("ACCEPT failed: errno %d", -accRes);
        return 1;
    }
    const int accepted = accRes; // server-side fd for the accepted connection
    close(accepted);

    writefln("ok: full async lifecycle through the ring — SOCKET(fd=%d) + BIND(127.0.0.1:%d) + LISTEN, ACCEPT(fd=%d)",
        srv, port, accepted);
    return 0;
}
