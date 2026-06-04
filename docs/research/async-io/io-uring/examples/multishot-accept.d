#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_multishot_accept"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — multishot accept (`IORING_ACCEPT_MULTISHOT`, Linux 5.19).
 *
 * Classic `IORING_OP_ACCEPT` (5.5) consumes one SQE per connection: you must
 * re-arm an accept after every client. Multishot accept inverts that — a
 * *single* accept SQE stays armed and posts one CQE per incoming connection,
 * each carrying a fresh accepted fd in `res` and `CQEFlags.MORE` set to signal
 * "this completion is not the last; the request lives on". This removes the
 * per-connection submit round-trip from the accept loop of a server.
 *
 * This program builds a libc TCP listener on `127.0.0.1:<ephemeral>`, arms one
 * `prepMultishotAccept` SQE, then opens and connects two loopback clients. It
 * waits for the two accept CQEs and verifies each yields a valid fd (`res >= 0`)
 * with `CQEFlags.MORE` set, proving the one SQE served multiple connections.
 *
 * Companion to the io_uring chronology: see
 * docs/research/async-io/io-uring/timeline.md
 * § "5.19 — Buffer rings, zero-copy groundwork, big SQE/CQE (July 2022)".
 *
 * Run with: `dub run --single multishot-accept.d`
 *
 * Portability: if `io_uring` is unavailable (too old / sandboxed) the program
 * prints `SKIP:` and exits 0. If multishot accept itself is unsupported
 * (kernel < 5.19 — the accept CQE comes back `-EINVAL`), it likewise prints
 * `SKIP:` and exits 0, so it stays green on the older kernels CI runs on.
 */
module io_uring_multishot_accept;

import during;

import core.sys.linux.errno : EINVAL, EOPNOTSUPP, ENOSYS;
import core.sys.posix.arpa.inet : htonl;
import core.sys.posix.netinet.in_ : sockaddr_in, AF_INET;
import core.sys.posix.sys.socket : socket, setsockopt, bind, listen, connect,
    getsockname, sockaddr, socklen_t, SOCK_STREAM, SOL_SOCKET, SO_REUSEADDR;
import core.sys.posix.unistd : close;

import std.stdio : writefln, stderr;

int main()
{
    enum ACCEPT_TAG = 1; // user_data cookie for the multishot accept SQE
    enum CLIENTS = 2; // how many loopback connections we drive through

    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host",
            -setupRet);
        return 0;
    }

    // --- libc TCP listener on 127.0.0.1:<ephemeral> -------------------------
    const int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0)
    {
        stderr.writefln("socket(srv) failed");
        return 1;
    }
    scope (exit) close(srv);

    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, one.sizeof);

    sockaddr_in saddr;
    saddr.sin_family = AF_INET;
    saddr.sin_port = 0; // ask the kernel for an ephemeral port
    saddr.sin_addr.s_addr = htonl(0x7f00_0001); // 127.0.0.1
    if (bind(srv, cast(sockaddr*)&saddr, saddr.sizeof) != 0)
    {
        stderr.writefln("bind() failed");
        return 1;
    }
    if (listen(srv, CLIENTS) != 0)
    {
        stderr.writefln("listen() failed");
        return 1;
    }

    // Read back the kernel-assigned port so the clients can connect to it.
    sockaddr_in actual;
    socklen_t alen = actual.sizeof;
    if (getsockname(srv, cast(sockaddr*)&actual, &alen) != 0)
    {
        stderr.writefln("getsockname() failed");
        return 1;
    }

    // --- arm ONE multishot accept SQE ---------------------------------------
    // The kernel fills `peer`/`peerLen` for each accepted connection; one SQE
    // keeps posting CQEs (each with CQEFlags.MORE) until cancelled or it errors.
    static sockaddr_in peer;
    static socklen_t peerLen = peer.sizeof;
    io.putWith!(
        (ref SubmissionEntry e, int fd)
        {
            e.prepMultishotAccept(fd, peer, peerLen);
            e.user_data = ACCEPT_TAG;
        })(srv);

    const submitted = io.submit(0); // just flush the SQ; we wait explicitly below
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // --- drive CLIENTS loopback connections, collecting one CQE each --------
    int[CLIENTS] clientFds = -1;
    scope (exit)
        foreach (cfd; clientFds)
            if (cfd >= 0) close(cfd);

    int accepted; // count of successfully accepted server-side fds
    bool sawMore; // did at least one accept CQE carry CQEFlags.MORE?

    foreach (i; 0 .. CLIENTS)
    {
        const int cli = socket(AF_INET, SOCK_STREAM, 0);
        if (cli < 0)
        {
            stderr.writefln("socket(cli %d) failed", i);
            return 1;
        }
        clientFds[i] = cli;

        // Loopback connect completes synchronously enough that the matching
        // accept CQE is ready by the time we wait for it.
        if (connect(cli, cast(sockaddr*)&actual, alen) != 0)
        {
            stderr.writefln("connect(cli %d) failed", i);
            return 1;
        }

        io.wait(1); // bounded: exactly one CQE per connection we just made
        const c = io.front;
        const res = c.res;
        const flags = c.flags;
        io.popFront();

        if (res < 0)
        {
            // -EINVAL/-EOPNOTSUPP/-ENOSYS on the very first accept => the kernel
            // does not implement multishot accept (predates 5.19). Skip cleanly.
            if (accepted == 0 && (res == -EINVAL || res == -EOPNOTSUPP || res == -ENOSYS))
            {
                writefln("SKIP: multishot accept unsupported (accept CQE res=%d) — needs Linux >= 5.19",
                    res);
                return 0;
            }
            stderr.writefln("accept CQE %d failed: errno %d", i, -res);
            return 1;
        }

        // `res` is a freshly accepted server-side fd — close it once observed.
        close(res);
        accepted++;
        if (flags & CQEFlags.MORE)
            sawMore = true;
    }

    if (accepted != CLIENTS)
    {
        stderr.writefln("expected %d accepted connections, got %d", CLIENTS, accepted);
        return 1;
    }

    // CQEFlags.MORE on each completion is the defining signal of a multishot
    // request: the one accept SQE remains armed for further connections.
    if (!sawMore)
    {
        stderr.writefln("no accept CQE carried CQEFlags.MORE — request was not multishot");
        return 1;
    }

    writefln("ok: one multishot accept SQE served %d loopback connections (CQEFlags.MORE set, request stays armed)",
        accepted);
    return 0;
}
