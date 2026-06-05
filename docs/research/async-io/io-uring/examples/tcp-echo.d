#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_tcp_echo"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` networking foundation — `ACCEPT` + `CONNECT` + `SEND` + `RECV`
 * over a single ring (Linux 5.5 for accept/connect, 5.6 for send/recv).
 *
 * Before 5.5, sockets had to be driven indirectly through `POLL_ADD` plus a
 * separate `accept(2)`/`connect(2)` syscall (the `echo_server` fork example
 * still polls). 5.5 added first-class `IORING_OP_ACCEPT` and
 * `IORING_OP_CONNECT`; 5.6 added `IORING_OP_SEND` / `IORING_OP_RECV`. Together
 * they let a TCP echo round-trip run entirely inside the ring.
 *
 * This program drives a one-shot loopback echo with a SINGLE ring, strictly
 * sequentially:
 *   1. libc creates a listening socket bound to 127.0.0.1:0 (SO_REUSEADDR,
 *      listen); `getsockname` recovers the kernel-assigned port.
 *   2. libc creates a client socket.
 *   3. CONNECT (client) + ACCEPT (listener) are submitted on the same ring and
 *      both completions are drained. ACCEPT yields the server-side accepted fd.
 *   4. SEND a known payload on the client; RECV it on the accepted server fd.
 *   5. Verify the received bytes match what was sent.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "5.5 — Accept/connect, cancel, link-timeout (January 2020)".
 *
 * Run with: `dub run --single tcp-echo.d`
 *
 * Portability: if `io_uring` is unavailable, or this kernel lacks the
 * accept/connect/send/recv ops (anything before ~5.5/5.6), the program prints
 * a `SKIP:` line and exits 0 so it stays green in CI regardless of host kernel.
 */
module io_uring_tcp_echo;

import during;

import std.stdio : writefln, stderr;

import core.sys.posix.arpa.inet : htonl, ntohs;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.socket;
import core.sys.posix.unistd : close;

// user_data cookies so each completion can be correlated to its op.
enum ulong CONNECT_TAG = 1;
enum ulong ACCEPT_TAG = 2;
enum ulong SEND_TAG = 3;
enum ulong RECV_TAG = 4;

// Known payload echoed across loopback.
static immutable ubyte[] PAYLOAD = cast(immutable ubyte[]) "io_uring echo \xF0\x9F\x9A\x80";

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // Probe for the socket ops. ACCEPT/CONNECT arrived in 5.5, SEND/RECV in
    // 5.6; on an older kernel any of these will be missing, so we skip cleanly.
    auto probe = io.probe();
    if (cast(bool) probe)
    {
        foreach (op; [Operation.ACCEPT, Operation.CONNECT, Operation.SEND, Operation.RECV])
        {
            if (!probe.isSupported(op))
            {
                writefln("SKIP: io_uring op %d unsupported on this kernel (needs Linux 5.5/5.6)",
                    cast(int) op);
                return 0;
            }
        }
    }

    // --- 1. Listening socket on 127.0.0.1:0 (kernel picks the port) --------
    immutable srv = socket(AF_INET, SOCK_STREAM, 0);
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
    saddr.sin_port = 0; // kernel-assigned
    saddr.sin_addr.s_addr = htonl(0x7f00_0001); // 127.0.0.1

    if (bind(srv, cast(sockaddr*)&saddr, sockaddr_in.sizeof) != 0)
    {
        stderr.writefln("bind() failed");
        return 1;
    }
    if (listen(srv, 4) != 0)
    {
        stderr.writefln("listen() failed");
        return 1;
    }

    // Recover the actual bound address (the port the kernel chose) — this is
    // what the client CONNECTs to.
    sockaddr_in bound;
    socklen_t blen = bound.sizeof;
    if (getsockname(srv, cast(sockaddr*)&bound, &blen) != 0)
    {
        stderr.writefln("getsockname() failed");
        return 1;
    }

    // --- 2. Client socket --------------------------------------------------
    immutable cli = socket(AF_INET, SOCK_STREAM, 0);
    if (cli < 0)
    {
        stderr.writefln("socket(cli) failed");
        return 1;
    }
    scope (exit) close(cli);

    // --- 3. CONNECT (client) + ACCEPT (listener) on a single ring ----------
    // ACCEPT writes the peer address + length into these out-params.
    sockaddr_in peer;
    socklen_t plen = peer.sizeof;

    // CONNECT must reference an address that lives until the op completes;
    // `bound` is a stack local that outlives the synchronous submit/wait below.
    io.putWith!((ref SubmissionEntry e, int fd, sockaddr_in* a) {
        e.prepConnect(fd, *a);
        e.user_data = CONNECT_TAG;
    })(cli, &bound);

    io.putWith!((ref SubmissionEntry e, int fd, sockaddr_in* a, socklen_t* al) {
        e.prepAccept(fd, *a, *al);
        e.user_data = ACCEPT_TAG;
    })(srv, &peer, &plen);

    if (io.submit(2) < 0)
    {
        stderr.writefln("submit(connect+accept) failed");
        return 1;
    }

    // Drain both completions. ACCEPT's res is the new server-side fd.
    int acceptedFd = -1;
    foreach (_; 0 .. 2)
    {
        io.wait(1);
        const c = io.front;
        const tag = c.user_data;
        const res = c.res;
        io.popFront();

        if (tag == CONNECT_TAG)
        {
            if (res < 0)
            {
                stderr.writefln("CONNECT failed: errno %d", -res);
                return 1;
            }
        }
        else if (tag == ACCEPT_TAG)
        {
            if (res < 0)
            {
                stderr.writefln("ACCEPT failed: errno %d", -res);
                return 1;
            }
            acceptedFd = res; // accept(2) returns the new connected fd
        }
    }

    if (acceptedFd < 0)
    {
        stderr.writefln("did not obtain an accepted fd");
        return 1;
    }
    scope (exit) close(acceptedFd);

    // --- 4. SEND on the client, RECV on the accepted server fd -------------
    io.putWith!((ref SubmissionEntry e, int fd) {
        e.prepSend(fd, PAYLOAD);
        e.user_data = SEND_TAG;
    })(cli);

    ubyte[64] rxbuf;
    io.putWith!((ref SubmissionEntry e, int fd, ubyte[] b) {
        e.prepRecv(fd, b);
        e.user_data = RECV_TAG;
    })(acceptedFd, rxbuf[]);

    if (io.submit(2) < 0)
    {
        stderr.writefln("submit(send+recv) failed");
        return 1;
    }

    // Drain SEND and RECV completions; remember how many bytes RECV produced.
    int received = -1;
    foreach (_; 0 .. 2)
    {
        io.wait(1);
        const c = io.front;
        const tag = c.user_data;
        const res = c.res;
        io.popFront();

        if (tag == SEND_TAG)
        {
            if (res < 0)
            {
                stderr.writefln("SEND failed: errno %d", -res);
                return 1;
            }
        }
        else if (tag == RECV_TAG)
        {
            if (res < 0)
            {
                stderr.writefln("RECV failed: errno %d", -res);
                return 1;
            }
            received = res;
        }
    }

    if (received != cast(int) PAYLOAD.length || rxbuf[0 .. received] != PAYLOAD)
    {
        stderr.writefln("payload mismatch: sent %d bytes, received %d bytes",
            PAYLOAD.length, received);
        return 1;
    }

    writefln("ok: TCP loopback echo on 127.0.0.1:%d — ACCEPT+CONNECT+SEND+RECV round-tripped %d bytes through one ring",
        ntohs(bound.sin_port), received);
    return 0;
}
