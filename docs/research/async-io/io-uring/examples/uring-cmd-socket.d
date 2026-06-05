#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_uring_cmd_socket"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — `IORING_OP_URING_CMD` passthrough on a socket (Linux 5.19).
 *
 * `IORING_OP_URING_CMD` (Linux 5.19) is a generic "command" channel that lets a
 * file's underlying driver service an `ioctl`/`setsockopt`-like request straight
 * out of the ring, with no per-call syscall. The socket sub-commands
 * (`SOCKET_URING_OP_*`, the `cmd_op` field — socket support landed in Linux 6.7)
 * ride that channel. Here we drive a `getsockopt`/`setsockopt` round-trip on a
 * loopback TCP socket entirely through the ring via `prepCmdSock`, instead of
 * calling `getsockopt(2)` / `setsockopt(2)` directly.
 *
 * What it does:
 *   1. Creates and binds a TCP socket to 127.0.0.1:0 with libc.
 *   2. Submits one `uring_cmd` SQE: `SOCKET_URING_OP_GETSOCKOPT` of
 *      `SO_REUSEADDR`, reading the option value through the ring; the option
 *      length comes back in the CQE `res` and the value buffer is filled
 *      in-place.
 *   3. Submits a `SOCKET_URING_OP_SETSOCKOPT` to flip `SO_REUSEADDR` on, then a
 *      second `GETSOCKOPT` to confirm the new value round-tripped — proving the
 *      passthrough moves data into the kernel and back out, not just succeeds.
 *
 * `uring_cmd` on a socket needs no special hardware (unlike NVMe/block or ZCRX
 * passthrough), so it runs on any 6.7+ loopback host — including this 6.18 box,
 * where the feature MUST be exercised.
 *
 * (Note: a `SOCKET_URING_OP_GETSOCKNAME` sub-command was proposed but never
 * merged into mainline; on a live kernel it returns `-EOPNOTSUPP`. We therefore
 * demonstrate the getsockopt/setsockopt sub-commands that the kernel actually
 * implements.)
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "5.19 — Buffer rings, zero-copy groundwork, big SQE/CQE".
 *
 * Run with: `dub run --single uring-cmd-socket.d`
 *
 * Portability: if the running kernel lacks `io_uring` (setup < 0) or this
 * specific op is unsupported (`-EINVAL` / `-EOPNOTSUPP` / `-ENOSYS`), the
 * program prints a `SKIP:` line and exits 0 so it stays green in CI.
 */
module io_uring_uring_cmd_socket;

import during;

import core.sys.linux.errno : EINVAL, EOPNOTSUPP, ENOSYS;
import core.sys.posix.arpa.inet : htonl;
import core.sys.posix.netinet.in_ : sockaddr_in, AF_INET, IPPROTO_TCP;
import core.sys.posix.sys.socket : socket, bind, sockaddr, socklen_t,
    SOCK_STREAM, SOL_SOCKET, SO_REUSEADDR;
import core.sys.posix.unistd : close;

import std.stdio : writefln, stderr;

// during exposes the socket uring_cmd sub-commands as plain enums; spell them
// out here so the example is self-contained and the cmd_op values are explicit.
enum uint SOCKET_URING_OP_GETSOCKOPT = 2;
enum uint SOCKET_URING_OP_SETSOCKOPT = 3;

/// Submit one socket `uring_cmd` and return its CQE `res` (or a negative -errno).
int runCmdSock(ref Uring io, uint cmdOp, int fd, uint level, uint optname,
    void* optval, uint optlen)
{
    // Pass everything as explicit args so the prep lambda captures nothing — a
    // closure would force a GC-allocated dual-context delegate (rejected under
    // putWith's @nogc).
    io.putWith!((ref SubmissionEntry e, uint c, int f, uint lv, uint on, ulong ov, uint ol) {
        e.prepCmdSock(c, f, lv, on, cast(void*)ov, ol);
    })(cmdOp, fd, level, optname, cast(ulong)optval, optlen);

    const submitted = io.submit(1);
    if (submitted < 0)
        return submitted; // -errno from submit

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
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host",
            -setupRet);
        return 0;
    }

    // --- Bind a TCP socket to an ephemeral loopback port with plain libc. ---
    const int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0)
    {
        stderr.writefln("socket() failed");
        return 1;
    }
    scope (exit) close(fd);

    sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = 0; // 0 => kernel picks an ephemeral port
    addr.sin_addr.s_addr = htonl(0x7f00_0001); // 127.0.0.1
    if (bind(fd, cast(sockaddr*)&addr, sockaddr_in.sizeof) != 0)
    {
        stderr.writefln("bind() failed");
        return 1;
    }

    // --- 1) Read SO_REUSEADDR through the ring (SOCKET_URING_OP_GETSOCKOPT). ---
    // The socket driver fills `before` in-place; the returned optlen lands in res.
    int before = -1;
    socklen_t vlen = before.sizeof;
    const getRes = runCmdSock(io, SOCKET_URING_OP_GETSOCKOPT, fd,
        SOL_SOCKET, SO_REUSEADDR, &before, vlen);

    // URING_CMD itself, or the socket sub-command, may be absent on older
    // kernels — treat those as a clean SKIP rather than a hard failure.
    if (getRes == -EINVAL || getRes == -EOPNOTSUPP || getRes == -ENOSYS)
    {
        writefln("SKIP: IORING_OP_URING_CMD / SOCKET_URING_OP_GETSOCKOPT unsupported (errno %d)",
            -getRes);
        return 0;
    }
    if (getRes < 0)
    {
        stderr.writefln("uring_cmd getsockopt failed: errno %d", -getRes);
        return 1;
    }
    // On success, getsockopt reports the option length (sizeof(int)) in res.
    if (getRes != cast(int) before.sizeof)
    {
        stderr.writefln("unexpected getsockopt optlen: res=%d (expected %d)",
            getRes, cast(int) before.sizeof);
        return 1;
    }

    // --- 2) Flip SO_REUSEADDR on through the ring (SOCKET_URING_OP_SETSOCKOPT). ---
    int on = 1;
    const setRes = runCmdSock(io, SOCKET_URING_OP_SETSOCKOPT, fd,
        SOL_SOCKET, SO_REUSEADDR, &on, on.sizeof);
    if (setRes < 0)
    {
        stderr.writefln("uring_cmd setsockopt failed: errno %d", -setRes);
        return 1;
    }

    // --- 3) Read it back to confirm the write took effect (round-trip proof). ---
    int after = -1;
    const getRes2 = runCmdSock(io, SOCKET_URING_OP_GETSOCKOPT, fd,
        SOL_SOCKET, SO_REUSEADDR, &after, vlen);
    if (getRes2 < 0)
    {
        stderr.writefln("uring_cmd getsockopt (after set) failed: errno %d", -getRes2);
        return 1;
    }
    if (after == 0)
    {
        stderr.writefln("SO_REUSEADDR still off after uring_cmd setsockopt (got %d)", after);
        return 1;
    }

    writefln("ok: IORING_OP_URING_CMD socket passthrough — getsockopt SO_REUSEADDR=%d, "
        ~ "setsockopt=1, re-read=%d (all through the ring)", before, after);
    return 0;
}
