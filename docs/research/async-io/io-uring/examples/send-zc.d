#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_send_zc"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — zero-copy send (`IORING_OP_SEND_ZC`, Linux 6.0).
 *
 * Ordinary `IORING_OP_SEND` copies the payload into the socket buffer before
 * the CQE arrives, so the user buffer is free to reuse immediately. Zero-copy
 * send instead pins the user pages and lets the NIC/loopback DMA straight from
 * them — which means the buffer must stay alive until the *kernel* is done with
 * it, not just until the send is "issued". `io_uring` signals this with a
 * distinctive **two-CQE pattern** for a single `SEND_ZC` SQE:
 *
 *   1. a transfer-result CQE carrying the byte count, flagged `CQEFlags.MORE`
 *      ("more completions for this user_data are coming"); and
 *   2. a later notification CQE flagged `CQEFlags.NOTIF` — emitted once the
 *      kernel has released the buffer, so it is now safe to reuse/free.
 *
 * Passing `IORING_SEND_ZC_REPORT_USAGE` additionally makes the kernel report,
 * in the notification CQE's `res`, whether the path was truly zero-copy or it
 * had to fall back to a copy (`IORING_NOTIF_USAGE_ZC_COPIED`). On loopback the
 * kernel often copies — that is expected and still a successful demonstration
 * of the API and its completion sequence.
 *
 * This example connects a client socket to a listening server, both on
 * 127.0.0.1, sends a payload from the client with `SEND_ZC`, asserts the
 * MORE-then-NOTIF CQE sequence, and reads the bytes back on the server end to
 * confirm the transfer.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 * § "6.0 — Zero-copy send, single-issuer, sync cancel (October 2022)".
 *
 * Run with: `dub run --single send-zc.d`
 *
 * Portability: if `io_uring` is unavailable (old kernel / sandbox) or the
 * kernel predates `SEND_ZC` (< 6.0), the program prints a `SKIP:` line and
 * exits 0 so it stays green in CI regardless of the host kernel.
 */
module io_uring_send_zc;

import during;

import core.sys.linux.errno : EINVAL, EOPNOTSUPP, ENOSYS;
import core.sys.posix.arpa.inet : htonl;
import core.sys.posix.netinet.in_;
import core.sys.posix.sys.socket;
import core.sys.posix.unistd : close, read;

import std.range : iota;
import std.algorithm : copy, equal, map;
import std.stdio : writefln, stderr;

enum N = 4096;

int main()
{
    // --- Loopback TCP pair, all via libc (the ring only does the SEND) ------
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { stderr.writefln("socket(srv) failed"); return 1; }
    scope (exit) close(srv);

    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, one.sizeof);

    sockaddr_in saddr;
    saddr.sin_family = AF_INET;
    saddr.sin_port = 0;                       // let the kernel pick a free port
    saddr.sin_addr.s_addr = htonl(0x7f000001); // 127.0.0.1
    if (bind(srv, cast(sockaddr*) &saddr, saddr.sizeof) != 0) { stderr.writefln("bind failed"); return 1; }
    if (listen(srv, 1) != 0) { stderr.writefln("listen failed"); return 1; }

    // Read back the port the kernel assigned so the client can connect to it.
    sockaddr_in actual;
    socklen_t alen = actual.sizeof;
    if (getsockname(srv, cast(sockaddr*) &actual, &alen) != 0) { stderr.writefln("getsockname failed"); return 1; }

    int cli = socket(AF_INET, SOCK_STREAM, 0);
    if (cli < 0) { stderr.writefln("socket(cli) failed"); return 1; }
    scope (exit) close(cli);
    if (connect(cli, cast(sockaddr*) &actual, alen) != 0) { stderr.writefln("connect failed"); return 1; }

    int acc = accept(srv, null, null);
    if (acc < 0) { stderr.writefln("accept failed"); return 1; }
    scope (exit) close(acc);

    // --- io_uring setup -----------------------------------------------------
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // Probe first: SEND_ZC arrived in 6.0. On older kernels the op is unknown,
    // so we SKIP cleanly rather than submitting an SQE the kernel can't decode.
    auto probe = io.probe();
    if (cast(bool) probe && !probe.isSupported(Operation.SEND_ZC))
    {
        writefln("SKIP: IORING_OP_SEND_ZC unsupported (kernel < 6.0)");
        return 0;
    }

    // Deterministic payload: bytes 0,1,2,...,255,0,1,... so we can verify it
    // round-trips intact on the receiving end.
    ubyte[N] payload;
    iota(0, N).map!(a => cast(ubyte)(a & 0xff)).copy(payload[]);

    // Enqueue a single zero-copy send. IORING_SEND_ZC_REPORT_USAGE makes the
    // notification CQE report whether the kernel managed a true zero-copy.
    io.putWith!((ref SubmissionEntry e, int fd, ubyte[] buf) {
        e.prepSendZc(fd, buf, MsgFlags.NONE, IORING_SEND_ZC_REPORT_USAGE);
        e.user_data = 1;
    })(cli, payload[]);

    // submit(0) just flushes the SQ; we don't ask submit to wait on a count.
    const submitted = io.submit(0);
    if (submitted != 1) { stderr.writefln("submit=%d (expected 1)", submitted); return 1; }

    // --- The two-CQE dance --------------------------------------------------
    // A single SEND_ZC produces two completions: the transfer result (with
    // CQEFlags.MORE set) and a separate notification (CQEFlags.NOTIF) once the
    // buffer is released. Consume exactly two.
    int sendRes = int.min;
    bool gotMore, gotNotif, zcCopied;
    foreach (_; 0 .. 2)
    {
        io.wait(1);
        const cqe = io.front;
        scope (exit) io.popFront();

        // Belt-and-suspenders: even if the probe lied, a kernel without SEND_ZC
        // fails the op itself — treat that as an unsupported-feature SKIP.
        if (cqe.res == -EINVAL || cqe.res == -EOPNOTSUPP || cqe.res == -ENOSYS)
        {
            writefln("SKIP: SEND_ZC rejected by kernel (res=%d) — unsupported (kernel < 6.0)", cqe.res);
            return 0;
        }

        if (cqe.flags & CQEFlags.NOTIF)
        {
            // Notification CQE: kernel is done with the buffer. With
            // REPORT_USAGE, res tells us whether it had to fall back to a copy.
            gotNotif = true;
            zcCopied = (cast(uint) cqe.res & IORING_NOTIF_USAGE_ZC_COPIED) != 0;
        }
        else
        {
            // Transfer-result CQE: byte count + the MORE flag promising a NOTIF.
            if (cqe.res < 0) { stderr.writefln("send failed: errno %d", -cqe.res); return 1; }
            sendRes = cqe.res;
            gotMore = (cqe.flags & CQEFlags.MORE) != 0;
        }
    }

    if (!gotMore) { stderr.writefln("transfer CQE lacked CQEFlags.MORE"); return 1; }
    if (!gotNotif) { stderr.writefln("missing CQEFlags.NOTIF notification CQE"); return 1; }
    if (sendRes != N) { stderr.writefln("short send: %d of %d bytes", sendRes, N); return 1; }

    // Confirm the bytes actually arrived intact on the server side.
    ubyte[N] rx;
    const rd = read(acc, &rx[0], rx.length);
    if (rd != N) { stderr.writefln("short read: %d of %d bytes", cast(int) rd, N); return 1; }
    if (!rx[].equal(payload[])) { stderr.writefln("payload mismatch on receive"); return 1; }

    writefln("ok: SEND_ZC sent %d bytes (transfer CQE F_MORE, then F_NOTIF; path=%s); payload round-tripped",
        sendRes, zcCopied ? "kernel-copied" : "true zero-copy");
    return 0;
}
