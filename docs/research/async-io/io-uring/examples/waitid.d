#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_waitid"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — asynchronously reap a child process (`IORING_OP_WAITID`, Linux 6.7).
 *
 * Before 6.7, the only way to reap a child without blocking a thread was to
 * juggle `SIGCHLD` handlers or poll `waitid(WNOHANG)` in your event loop.
 * `IORING_OP_WAITID` folds the reap into the ring like any other op: you submit
 * a `WAITID` SQE naming the child, and the completion fires when the child
 * changes state. No signal plumbing, no busy-polling.
 *
 * This example forks a child that immediately exits with a known code, submits a
 * `prepWaitid(P_PID, childpid, &siginfo, WEXITED, 0)`, waits for the CQE, and
 * verifies `res == 0` plus the `siginfo_t` the kernel filled in (`si_code ==
 * CLD_EXITED`, `si_status ==` the child's exit code). Modeled on the `during`
 * library's own `tests/waitid.d`.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 * § "6.7 — Futex, waitid, read-multishot (January 2024)".
 *
 * Run with: `dub run --single waitid.d`
 *
 * Portability: if the running kernel has no `io_uring`, or lacks `IORING_OP_WAITID`
 * (kernel < 6.7), the program prints a `SKIP:` line and exits 0 so it stays green
 * in CI regardless of the host kernel.
 */
module io_uring_waitid;

import during;

import std.stdio : writefln, stderr;

import core.sys.linux.errno : EINVAL, EOPNOTSUPP, ENOSYS;
import core.sys.posix.signal : siginfo_t;
import core.sys.posix.sys.wait : waitpid;
import core.sys.posix.unistd : fork, _exit;

// idtype_t values from <sys/wait.h>. druntime doesn't expose these portably, so
// we hardcode the well-known constants.
private enum P_PID = 1;

// `options` bits from <sys/wait.h>. `WEXITED` is mandatory for waitid(2): it asks
// to wait for children that have terminated.
private enum WEXITED = 0x00000004;

// si_code value the kernel sets for a normally-exited child (from <bits/siginfo-consts.h>).
private enum CLD_EXITED = 1;

// The exit code our child reports; we verify it round-trips through siginfo_t.
private enum int childExitCode = 42;

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // Probe up front: on a kernel older than 6.7 `IORING_OP_WAITID` is unknown and
    // we should skip cleanly rather than fork a child we'd have to reap by hand.
    const probe = io.probe();
    if (cast(bool) probe && !probe.isSupported(Operation.WAITID))
    {
        writefln("SKIP: IORING_OP_WAITID unsupported on this kernel (needs Linux >= 6.7)");
        return 0;
    }

    // Fork the child *after* the ring is up. The child exits immediately with a
    // known code; the parent reaps it asynchronously through the ring.
    const pid = fork();
    if (pid < 0)
    {
        stderr.writefln("fork failed: errno %d", -pid);
        return 1;
    }
    if (pid == 0)
        _exit(childExitCode); // child path — never returns.

    // The kernel writes the reaped child's status into this struct. It must stay
    // alive (and addressable) until the completion arrives, hence a plain stack local.
    siginfo_t info;

    // Place the WAITID SQE: wait on this specific pid (P_PID), accept terminated
    // children (WEXITED), and have the kernel fill `&info` with the child status.
    io.putWith!(
        (ref SubmissionEntry e, int p, siginfo_t* infop)
        {
            e.prepWaitid(P_PID, cast(uint) p, infop, WEXITED, 0);
            e.user_data = 1;
        })(pid, &info);

    const submitted = io.submit(1);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        // Avoid leaving a zombie behind on the error path.
        int status;
        waitpid(pid, &status, 0);
        return 1;
    }

    // Block for the single completion. Bounded: exactly one CQE is expected.
    io.wait(1);
    const res = io.front.res;
    io.popFront();

    // Some kernels surface "op unknown" only at completion time. Treat the
    // canonical unsupported errnos as a SKIP, reaping the child synchronously so
    // we don't leak a zombie.
    if (res == -EINVAL || res == -EOPNOTSUPP || res == -ENOSYS)
    {
        int status;
        waitpid(pid, &status, 0);
        writefln("SKIP: IORING_OP_WAITID rejected with errno %d (kernel < 6.7?)", -res);
        return 0;
    }

    if (res < 0)
    {
        stderr.writefln("WAITID completed with error: errno %d", -res);
        int status;
        waitpid(pid, &status, 0);
        return 1;
    }

    // The kernel reaped the child for us and populated `info`.
    // For a WEXITED reap, si_code is CLD_EXITED and si_status is the raw exit code.
    if (info.si_code != CLD_EXITED || info.si_status != childExitCode)
    {
        stderr.writefln("siginfo mismatch: si_code=%d (want %d), si_status=%d (want %d)",
            info.si_code, CLD_EXITED, info.si_status, childExitCode);
        return 1;
    }

    // Confirm the child really is gone — a second waitpid should find no such child.
    int status;
    const wp = waitpid(pid, &status, 0);
    if (wp > 0)
    {
        stderr.writefln("child %d was NOT reaped by IORING_OP_WAITID (waitpid returned it)", pid);
        return 1;
    }

    writefln("ok: IORING_OP_WAITID reaped child %d asynchronously (si_code=CLD_EXITED, exit code %d)",
        pid, info.si_status);
    return 0;
}
