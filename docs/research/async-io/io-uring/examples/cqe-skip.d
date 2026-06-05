#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_cqe_skip"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — skip the completion for a successful SQE
 * (`IOSQE_CQE_SKIP_SUCCESS`, Linux 5.17).
 *
 * Normally every submitted SQE posts exactly one CQE. Setting
 * `IOSQE_CQE_SKIP_SUCCESS` on an SQE flips that: if the request *succeeds* the
 * kernel posts **no** completion for it (an *error* still posts one, so failures
 * are never silently lost). This is a throughput win for fire-and-forget links
 * where the app only cares that the chain finished, not about the intermediate
 * steps.
 *
 * This program builds a two-SQE hard-ordered link of writes to a temp file:
 *   - SQE #1: `prepWrite` with `IO_LINK | CQE_SKIP_SUCCESS` — on success it is
 *     silent, so its CQE is suppressed;
 *   - SQE #2: `prepWrite`, normal flags — it terminates the link and posts the
 *     one CQE we expect to see.
 * It submits both, drains the completion queue with a bounded wait, and asserts
 * that exactly **one** CQE arrived (the last write) — direct proof that the first
 * write's success CQE was skipped. Both writes are also verified to have landed
 * in the file.
 *
 * The `IO_LINK` matters here: `CQE_SKIP_SUCCESS` only suppresses the completion;
 * we still want the first write to actually run, so the two SQEs are chained so
 * the kernel executes #1 then #2 in order, and we can reason about which single
 * CQE survives.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "5.17 — CQE skip, faster cancel (March 2022)".
 *
 * Run with: `dub run --single cqe-skip.d`
 *
 * Portability: prints `SKIP:` and exits 0 when io_uring is unavailable, or when
 * the running kernel predates `CQE_SKIP_SUCCESS` (detected by the link still
 * posting two CQEs, or a write completing with -EINVAL). Exits nonzero only on a
 * genuinely unexpected syscall failure.
 */
module io_uring_cqe_skip;

import during;

import core.stdc.errno : EINVAL;
import core.sys.posix.fcntl : O_CREAT, O_RDWR, open;
import core.sys.posix.unistd : close, pread, unlink;

import std.stdio : stderr, writefln;

// CQE_SKIP_SUCCESS is enum value 1<<6 in SubmissionEntryFlags; we OR it with
// IO_LINK so the first write both runs *before* the second and stays silent.
private enum ubyte SKIP_AND_LINK =
    cast(ubyte)(SubmissionEntryFlags.IO_LINK | SubmissionEntryFlags.CQE_SKIP_SUCCESS);

int main()
{
    Uring io;
    const setupRet = io.setup(8);
    if (setupRet < 0)
    {
        writefln("SKIP: io_uring_setup failed (errno %d) — io_uring unavailable on this host", -setupRet);
        return 0;
    }

    // A throwaway file in /tmp we read back at the end. O_RDWR so we can pread().
    const(char)* path = "/tmp/io_uring_cqe_skip.tmp";
    const fd = open(path, O_CREAT | O_RDWR, 384); // mode 0600 (rw-------)
    if (fd < 0)
    {
        stderr.writefln("open(%s) failed", path);
        return 1;
    }
    scope (exit)
    {
        close(fd);
        unlink(path);
    }

    // Two disjoint payloads written at different offsets so we can verify both
    // actually landed even though only the second reports a completion.
    static immutable ubyte[6] first = ['s', 'k', 'i', 'p', 'p', 'd'];
    static immutable ubyte[6] second = ['l', 'a', 's', 't', '!', '!'];
    enum ulong UD_FIRST = 0x11;
    enum ulong UD_SECOND = 0x22;

    // SQE #1: silent-on-success, linked to the next SQE.
    io.putWith!((ref SubmissionEntry e, int f) {
        e.prepWrite(f, first[], 0);
        e.user_data = UD_FIRST;
        e.flags |= SKIP_AND_LINK;
    })(fd);

    // SQE #2: terminates the link, normal completion — this is the CQE we expect.
    io.putWith!((ref SubmissionEntry e, int f) {
        e.prepWrite(f, second[], 16);
        e.user_data = UD_SECOND;
    })(fd);

    // Submit with `want = 0`: enqueue both SQEs but do *not* block for N
    // completions. This matters here — `submit(2)` would call `submitAndWait(2)`
    // and block forever, because CQE_SKIP_SUCCESS means only ONE CQE is ever
    // posted for this link. We submit, then wait for exactly the 1 we expect.
    const submitted = io.submit(0);
    if (submitted < 0)
    {
        stderr.writefln("submit failed: errno %d", -submitted);
        return 1;
    }
    if (submitted != 2)
    {
        stderr.writefln("expected to submit 2 SQEs, submitted %d", submitted);
        return 1;
    }

    // Block for the link's single terminal completion.
    io.wait(1);

    int cqeCount;
    bool sawFirst, sawSecond;
    int firstRes, secondRes;
    // Bounded drain: at most the 2 ops we submitted could ever surface.
    foreach (_; 0 .. 2)
    {
        if (io.empty)
            break;
        const ud = io.front.user_data;
        const res = io.front.res;
        io.popFront();
        cqeCount++;
        if (ud == UD_FIRST) { sawFirst = true; firstRes = res; }
        else if (ud == UD_SECOND) { sawSecond = true; secondRes = res; }
    }

    // If the first write reported an error CQE, that error always posts (skip
    // only suppresses *success*). A -EINVAL there is the classic "kernel doesn't
    // understand this flag" signal — treat as feature-unsupported.
    if (sawFirst && firstRes == -EINVAL)
    {
        writefln("SKIP: write rejected with -EINVAL — CQE_SKIP_SUCCESS unsupported on this kernel");
        return 0;
    }

    // Pre-5.17 kernels ignore the flag and post a CQE for the (successful) first
    // write too: two completions instead of one. Not an error — just unsupported.
    if (cqeCount == 2 && sawFirst && firstRes >= 0)
    {
        writefln("SKIP: link posted 2 CQEs (first write completed normally) — "
            ~ "CQE_SKIP_SUCCESS not honored, kernel predates 5.17");
        return 0;
    }

    // From here on the feature is in play: we must have seen exactly the terminal
    // CQE and nothing for the skipped first write.
    if (cqeCount != 1 || !sawSecond || sawFirst)
    {
        stderr.writefln("unexpected CQE pattern: count=%d sawFirst=%s sawSecond=%s",
            cqeCount, sawFirst, sawSecond);
        return 1;
    }

    if (secondRes != cast(int)second.length)
    {
        stderr.writefln("terminal write returned %d, expected %d", secondRes, cast(int)second.length);
        return 1;
    }

    // The skipped write produced no CQE, but it must still have *run* — read both
    // regions back and confirm the bytes are on disk.
    ubyte[6] back = void;
    if (pread(fd, &back[0], back.length, 0) != cast(long)first.length || back[] != first[])
    {
        stderr.writefln("first (skipped) write did not land on disk");
        return 1;
    }
    if (pread(fd, &back[0], back.length, 16) != cast(long)second.length || back[] != second[])
    {
        stderr.writefln("second write did not land on disk");
        return 1;
    }

    writefln("ok: linked writes ran, but only 1 CQE arrived (the terminal op) — "
        ~ "CQE_SKIP_SUCCESS suppressed the first write's success completion");
    return 0;
}
