#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_linked_sqes"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — linked SQEs via `IOSQE_IO_LINK` (Linux 5.3).
 *
 * `IOSQE_IO_LINK` turns an otherwise unordered batch of submission queue
 * entries into an ordered dependency chain: when an SQE carries the
 * `IO_LINK` flag, the *next* SQE in the batch will not start until the
 * flagged one has completed successfully. This lets you express
 * "do B only after A" — e.g. write-then-fsync — without an extra
 * userspace submit/wait round-trip.
 *
 * This example opens a temp file and submits TWO SQEs in one batch:
 *   1. WRITE a known payload (user_data = 1), flagged `IO_LINK`.
 *   2. FSYNC the same fd (user_data = 2), the link target.
 * Because the WRITE is `IO_LINK`-flagged, the kernel guarantees the FSYNC
 * runs strictly *after* the WRITE has completed — without the link the two
 * could be reordered/run concurrently, and the fsync might flush *before*
 * the bytes ever reached the file.
 *
 * Failure propagation (explained, not triggered here): if a linked SQE
 * fails (or is short), the kernel breaks the chain — every *subsequent*
 * linked SQE is cancelled with `res == -ECANCELED` and never runs. So if
 * the WRITE had failed, the FSYNC would never touch the disk: the chain
 * fails closed. (`IO_HARDLINK` is the variant that keeps going regardless
 * of the predecessor's result.)
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "5.3 — Network message ops (September 2019)".
 *
 * Run with: `dub run --single linked-sqes.d`
 *
 * Portability: if the running kernel has no `io_uring`, or is too old for
 * linked SQEs (pre-5.3), the program prints a `SKIP:` line and exits 0 so
 * it stays green in CI regardless of the host kernel.
 */
module io_uring_linked_sqes;

import during;

import std.stdio : writefln, stderr;

import core.sys.linux.errno : EINVAL, EOPNOTSUPP, ENOSYS, ECANCELED;
import core.sys.posix.stdlib : mkstemp;
import core.sys.posix.unistd : close, unlink;

int main()
{
    enum ulong writeTag = 1; // the link head (runs first)
    enum ulong fsyncTag = 2; // the link target (runs only after the write)

    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // Create a private temp file to write+fsync. mkstemp replaces the XXXXXX
    // template in place and returns an open fd.
    char[] tmpl = "/tmp/io_uring_linked_sqes_XXXXXX\0".dup;
    const fd = mkstemp(&tmpl[0]);
    if (fd < 0)
    {
        stderr.writefln("mkstemp failed");
        return 1;
    }
    // Unlink immediately: the file stays alive via the open fd but leaves no
    // litter behind when we close it.
    unlink(&tmpl[0]);
    scope (exit) close(fd);

    immutable ubyte[] payload = cast(immutable(ubyte[])) "linked-sqes: write then fsync, in order\n";

    // ---- Submit the linked batch (two SQEs, one submit) -------------------
    // SQE #1: WRITE the payload, flagged IO_LINK so SQE #2 depends on it.
    io.putWith!((ref SubmissionEntry e, int f, const(ubyte)[] buf)
    {
        e.prepWrite(f, buf, 0);
        e.user_data = writeTag;
        // IO_LINK: the *next* SQE in this submission won't start until this
        // write completes successfully — the heart of the ordering guarantee.
        e.flags |= SubmissionEntryFlags.IO_LINK;
    })(fd, payload);

    // SQE #2: FSYNC the same fd — the link target. No IO_LINK here: it ends
    // the chain.
    io.putWith!((ref SubmissionEntry e, int f)
    {
        e.prepFsync(f);
        e.user_data = fsyncTag;
    })(fd);

    const submitted = io.submit(2);
    if (submitted < 0)
    {
        // Linked SQEs arrived in 5.3; a pre-5.3 kernel rejects the batch.
        if (submitted == -EINVAL || submitted == -EOPNOTSUPP || submitted == -ENOSYS)
        {
            writefln("SKIP: linked SQEs (IOSQE_IO_LINK) unsupported on this kernel (errno %d)", -submitted);
            return 0;
        }
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }

    // Block until BOTH completions are ready.
    io.wait(2);

    // Drain the completion queue. Completions arrive in chain order: the
    // write (head) first, then the fsync (target).
    int writeRes = int.min;
    int fsyncRes = int.min;
    while (!io.empty)
    {
        const c = io.front;
        if (c.user_data == writeTag)
            writeRes = c.res;
        else if (c.user_data == fsyncTag)
            fsyncRes = c.res;
        io.popFront();
    }

    // A pre-5.3 kernel that *accepted* the batch but ignored the link flag
    // could still reject the flag at completion time — treat that as a SKIP.
    if (writeRes == -EINVAL || fsyncRes == -EINVAL
        || writeRes == -EOPNOTSUPP || fsyncRes == -EOPNOTSUPP)
    {
        writefln("SKIP: linked SQEs (IOSQE_IO_LINK) unsupported on this kernel");
        return 0;
    }

    // If the link had broken (write failed), the kernel would have cancelled
    // the fsync with -ECANCELED. Surface that explicitly for clarity.
    if (fsyncRes == -ECANCELED)
    {
        stderr.writefln("fsync was cancelled (-ECANCELED): the linked write failed (res=%d)", writeRes);
        return 1;
    }

    if (writeRes < 0)
    {
        stderr.writefln("WRITE completed with error: errno %d", -writeRes);
        return 1;
    }
    if (fsyncRes < 0)
    {
        stderr.writefln("FSYNC completed with error: errno %d", -fsyncRes);
        return 1;
    }

    // The write must have transferred the full payload, and the fsync must
    // have returned 0 — and, by the IO_LINK contract, the fsync only ran
    // because the write succeeded first.
    if (writeRes != cast(int) payload.length)
    {
        stderr.writefln("short write: wrote %d of %d bytes", writeRes, payload.length);
        return 1;
    }

    writefln("ok: linked SQEs ordered write-before-fsync — WRITE res=%d (%d bytes), FSYNC res=%d",
        writeRes, payload.length, fsyncRes);
    return 0;
}
