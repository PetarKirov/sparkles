#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_sendmsg_recvmsg"
    dependency "during" version="~>0.5.0"
    targetPath "build"
+/
/**
 * `io_uring` — network message ops `IORING_OP_SENDMSG` / `IORING_OP_RECVMSG`
 * (Linux 5.3), demonstrated with `SCM_RIGHTS` file-descriptor passing.
 *
 * 5.3 taught `io_uring` to drive the full `sendmsg(2)`/`recvmsg(2)` scatter/gather
 * interface, including the ancillary-data (control-message) channel. This example
 * uses that channel for its most famous trick: passing an open file descriptor
 * across a `AF_UNIX` socket via an `SCM_RIGHTS` control message.
 *
 * The flow:
 *   1. Open a temp file and `socketpair(AF_UNIX)`.
 *   2. Queue a `RECVMSG` on one end and a `SENDMSG` on the other; the send carries
 *      a `cmsghdr{ SOL_SOCKET, SCM_RIGHTS }` whose payload is the temp file's fd.
 *   3. Submit both with one `io_uring_enter`, reap both CQEs.
 *   4. The kernel installs a *new* fd in this process pointing at the same open
 *      file description. We `fstat(2)` both and confirm `st_ino`/`st_dev` match —
 *      proof the descriptor really crossed the socket through the ring.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md § "5.3 — Network message ops".
 *
 * Run with: `dub run --single sendmsg-recvmsg.d`
 *
 * Portability: prints `SKIP:` and exits 0 if `io_uring` is unavailable or if the
 * kernel rejects SEND/RECVMSG (`-EINVAL`/`-EOPNOTSUPP`); 6.18 supports both.
 */
module io_uring_sendmsg_recvmsg;

import during;

import core.stdc.errno : EINVAL, EOPNOTSUPP, ENOSYS;
import core.sys.posix.fcntl : open, O_RDWR, O_CREAT, O_TRUNC;
import core.sys.posix.sys.socket :
    socketpair, AF_UNIX, SOCK_STREAM, SOL_SOCKET, SCM_RIGHTS,
    msghdr, cmsghdr, CMSG_FIRSTHDR, CMSG_DATA, CMSG_SPACE, CMSG_LEN;
import core.sys.posix.sys.stat : stat_t, fstat;
import core.sys.posix.sys.uio : iovec;
import core.sys.posix.unistd : close, unlink, write;

import std.stdio : writefln, stderr;
import std.string : toStringz;

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // ---- A real on-disk file whose fd we will hand to our peer -------------
    enum path = "/tmp/io_uring_scm_rights_demo.tmp";
    const int srcFd = open(path.toStringz, O_RDWR | O_CREAT | O_TRUNC, octal!"600");
    if (srcFd < 0)
    {
        stderr.writefln("open(%s) failed", path);
        return 1;
    }
    scope (exit) { close(srcFd); unlink(path.toStringz); }
    write(srcFd, "io_uring".ptr, 8); // give the file some content / a real inode

    stat_t srcStat;
    if (fstat(srcFd, &srcStat) != 0)
    {
        stderr.writefln("fstat(srcFd) failed");
        return 1;
    }

    // ---- The transport: a connected pair of AF_UNIX stream sockets ---------
    int[2] sock;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sock) != 0)
    {
        stderr.writefln("socketpair() failed");
        return 1;
    }
    scope (exit) { close(sock[0]); close(sock[1]); }

    // A 1-byte normal payload rides alongside the ancillary fd. SCM_RIGHTS
    // messages must carry at least one data byte, otherwise the kernel may drop
    // the ancillary data.
    ubyte[1] sendData = [0x2A];
    ubyte[1] recvData = [0x00];

    iovec sendIov = iovec(sendData.ptr, sendData.length);
    iovec recvIov = iovec(recvData.ptr, recvData.length);

    // ---- Control-message buffers (the SCM_RIGHTS channel) ------------------
    // CMSG_SPACE(int.sizeof) reserves room for one cmsghdr + an aligned int fd.
    enum size_t controlLen = CMSG_SPACE(int.sizeof);
    ubyte[controlLen] sendControl = 0;
    ubyte[controlLen] recvControl = 0;

    msghdr sendMsg;
    sendMsg.msg_iov = &sendIov;
    sendMsg.msg_iovlen = 1;
    sendMsg.msg_control = sendControl.ptr;
    sendMsg.msg_controllen = controlLen;

    // Fill the single control message: level SOL_SOCKET, type SCM_RIGHTS,
    // payload = the fd we want the peer to receive.
    cmsghdr* cm = CMSG_FIRSTHDR(&sendMsg);
    cm.cmsg_level = SOL_SOCKET;
    cm.cmsg_type = SCM_RIGHTS;
    cm.cmsg_len = CMSG_LEN(int.sizeof);
    *(cast(int*) CMSG_DATA(cm)) = srcFd;

    msghdr recvMsg;
    recvMsg.msg_iov = &recvIov;
    recvMsg.msg_iovlen = 1;
    recvMsg.msg_control = recvControl.ptr;
    recvMsg.msg_controllen = controlLen;

    // ---- Queue RECVMSG (user_data 0) then SENDMSG (user_data 1) ------------
    // Posting the receive first guarantees there is a reader waiting; both
    // complete asynchronously off the same submission.
    io.putWith!((ref SubmissionEntry e, int fd, ref msghdr m) {
        e.prepRecvMsg(fd, m);
        e.user_data = 0;
    })(sock[0], recvMsg);

    io.putWith!((ref SubmissionEntry e, int fd, ref msghdr m) {
        e.prepSendMsg(fd, m);
        e.user_data = 1;
    })(sock[1], sendMsg);

    const submitted = io.submit(2);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // ---- Reap both completions; capture the received fd from the recv CQE --
    int recvRes = int.min;
    int sendRes = int.min;
    foreach (_; 0 .. 2)
    {
        io.wait(1);
        const ud = io.front.user_data;
        const res = io.front.res;
        io.popFront();
        if (ud == 0) recvRes = res;
        else sendRes = res;
    }

    // Either op returning -EINVAL/-EOPNOTSUPP/-ENOSYS means this kernel lacks
    // SEND/RECVMSG support — that is an expected SKIP, not a failure.
    foreach (res; [recvRes, sendRes])
    {
        if (res == -EINVAL || res == -EOPNOTSUPP || res == -ENOSYS)
        {
            writefln("SKIP: kernel rejected SEND/RECVMSG (errno %d) — unsupported here", -res);
            return 0;
        }
    }

    if (sendRes < 0)
    {
        stderr.writefln("SENDMSG completed with error: errno %d", -sendRes);
        return 1;
    }
    if (recvRes < 0)
    {
        stderr.writefln("RECVMSG completed with error: errno %d", -recvRes);
        return 1;
    }

    // ---- Extract the passed fd from the received control message -----------
    cmsghdr* rcm = CMSG_FIRSTHDR(&recvMsg);
    if (rcm is null || rcm.cmsg_level != SOL_SOCKET || rcm.cmsg_type != SCM_RIGHTS)
    {
        stderr.writefln("no SCM_RIGHTS control message received");
        return 1;
    }

    const int passedFd = *(cast(int*) CMSG_DATA(rcm));
    if (passedFd < 0)
    {
        stderr.writefln("invalid received fd %d", passedFd);
        return 1;
    }
    scope (exit) close(passedFd);

    // The clincher: the received fd is a brand-new descriptor number, yet it
    // refers to the same open file. Matching device + inode proves it.
    stat_t passedStat;
    if (fstat(passedFd, &passedStat) != 0)
    {
        stderr.writefln("fstat(passedFd) failed");
        return 1;
    }

    if (passedStat.st_dev != srcStat.st_dev || passedStat.st_ino != srcStat.st_ino)
    {
        stderr.writefln("received fd refers to a different file (dev/ino mismatch)");
        return 1;
    }

    if (passedFd == srcFd)
    {
        stderr.writefln("received fd should be a distinct descriptor number, got the same one");
        return 1;
    }

    writefln(
        "ok: SCM_RIGHTS fd-passing via io_uring SENDMSG/RECVMSG — sent fd %d, received fd %d, same file (dev=%d ino=%d)",
        srcFd, passedFd, passedStat.st_dev, passedStat.st_ino);
    return 0;
}

// `0o600`-style octal literal helper (D dropped the `0o`/`0NNN` syntax).
private template octal(string s)
{
    enum uint octal = {
        uint v = 0;
        foreach (c; s) v = v * 8 + (c - '0');
        return v;
    }();
}
