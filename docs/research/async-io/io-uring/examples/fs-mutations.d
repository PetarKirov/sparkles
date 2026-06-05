#!/usr/bin/env dub
/+ dub.sdl:
    name "io_uring_fs_mutations"
    dependency "during" version="~>0.5.0"
    platforms "linux"
    targetPath "build"
+/
/**
 * `io_uring` — asynchronous filesystem mutation ops (Linux 5.11 / 5.15).
 *
 * Before 5.11, path-based metadata operations (create, rename, unlink, …) had
 * no `io_uring` opcode and had to run on a worker thread or out-of-band. Linux
 * 5.11 added `RENAMEAT` and `UNLINKAT`; 5.15 rounded out the set with `MKDIRAT`,
 * `SYMLINKAT`, and `LINKAT`, so a whole directory-mutation workflow can be driven
 * through the ring.
 *
 * This example builds a small workflow inside a fresh `mkdtemp` scratch directory,
 * issuing every step as an `io_uring` SQE rather than a blocking libc syscall:
 *   1. `MKDIRAT`   — create a `sub/` subdirectory.
 *   2. (libc)      — create a regular file `sub/file` (so there is something to act on).
 *   3. `SYMLINKAT` — make `link` point at `sub/file`.
 *   4. `RENAMEAT`  — rename `sub/file` to `sub/renamed`.
 *   5. `UNLINKAT`  — remove `sub/renamed`, then remove `link`.
 *   6. `UNLINKAT`  — remove the now-empty `sub/` (with `AT_REMOVEDIR`).
 * Each op's CQE `res` must be `>= 0`, and we verify the on-disk state with `stat`
 * between the relevant steps. The scratch directory is always cleaned up.
 *
 * Companion to the io_uring chronology:
 * see docs/research/async-io/io-uring/timeline.md
 *   § "5.11 — Filesystem mutation ops, SQPOLL without root".
 *
 * Run with: `dub run --single fs-mutations.d`
 *
 * Portability: if the running kernel has no `io_uring`, or lacks any of these
 * filesystem opcodes (probe / `-EINVAL`), the program prints a `SKIP:` line and
 * exits 0 so it stays green in CI regardless of the host kernel.
 */
module io_uring_fs_mutations;

import during;

import core.stdc.string : strlen;
import core.sys.posix.stdlib : mkdtemp;
import core.sys.posix.fcntl : AT_FDCWD, open, O_CREAT, O_WRONLY;
import core.sys.posix.sys.stat : stat, stat_t, lstat, S_ISDIR, S_ISLNK, S_ISREG;
import core.sys.posix.unistd : close, rmdir, unlink;

import std.stdio : stderr, writefln;
import std.string : toStringz;

// `AT_REMOVEDIR` (== 0x200) tells unlinkat(2) to remove a directory instead of a
// file. core.sys.posix.fcntl doesn't expose it portably, so define it locally.
enum int AT_REMOVEDIR = 0x200;

/// Submit one prepared SQE, wait for its single CQE, and return its `res` field.
/// Returns the (possibly negative) kernel result; the caller decides how to react.
int runOne(Op)(ref Uring io, scope Op prep, ulong cookie)
{
    io.putWith!((ref SubmissionEntry e, scope Op p, ulong c) {
        p(e);
        e.user_data = c;
    })(prep, cookie);

    const submitted = io.submit(1);
    if (submitted < 0)
        return submitted; // surface submit failure as a negative result

    io.wait(1);
    const res = io.front.res;
    assert(io.front.user_data == cookie, "CQE cookie mismatch");
    io.popFront();
    return res;
}

/// True if `path` exists and matches the predicate over its `st_mode`.
bool checkMode(scope const(char)* path, bool delegate(uint) pred, bool useLstat = false)
{
    stat_t st;
    const rc = useLstat ? lstat(path, &st) : stat(path, &st);
    if (rc != 0) return false;
    return pred(st.st_mode);
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

    // Capability probe: every op we use must be advertised by the kernel. If any
    // is missing this kernel predates 5.11/5.15 for that opcode — skip cleanly.
    auto probe = io.probe();
    if (!cast(bool) probe)
    {
        writefln("SKIP: io_uring probe failed — cannot determine supported ops");
        return 0;
    }
    foreach (op; [Operation.MKDIRAT, Operation.SYMLINKAT, Operation.RENAMEAT, Operation.UNLINKAT])
    {
        if (!probe.isSupported(op))
        {
            writefln("SKIP: io_uring op %s unsupported on this kernel (needs 5.11/5.15)", op);
            return 0;
        }
    }

    // Fresh scratch directory under the system temp dir. mkdtemp mutates the
    // template in place and returns null on failure.
    char[] tmpl = "/tmp/iouring_fs_XXXXXX\0".dup;
    if (mkdtemp(tmpl.ptr) is null)
    {
        stderr.writefln("mkdtemp failed");
        return 1;
    }
    const base = cast(string) tmpl[0 .. strlen(tmpl.ptr)];
    scope (exit) rmdir(base.toStringz); // remove the top-level scratch dir last

    // Build absolute paths once; toStringz gives us GC'd, NUL-terminated copies
    // that stay alive for the whole submit/complete cycle of each op.
    const subDir   = (base ~ "/sub").toStringz;
    const filePath = (base ~ "/sub/file").toStringz;
    const renamed  = (base ~ "/sub/renamed").toStringz;
    const linkPath = (base ~ "/link").toStringz;
    // Symlink target is relative-as-stored; we point the link at the absolute file.
    const linkTarget = filePath;

    // 1. MKDIRAT: create base/sub with mode 0755.
    {
        const res = runOne(io,
            (ref SubmissionEntry e) => e.prepMkdirat(AT_FDCWD, subDir, octal!755),
            1);
        if (res == -EINVAL)
        {
            writefln("SKIP: MKDIRAT rejected with -EINVAL — unsupported on this kernel");
            return 0;
        }
        if (res < 0)
        {
            stderr.writefln("MKDIRAT failed: errno %d", -res);
            return 1;
        }
    }
    if (!checkMode(subDir, m => S_ISDIR(m)))
    {
        stderr.writefln("post-MKDIRAT: sub/ is not a directory");
        return 1;
    }

    // 2. Create the regular file via libc (there's no IORING_OP_CREATE; openat
    //    direct/fixed exists but a plain file is all we need to mutate below).
    {
        const fd = open(filePath, O_CREAT | O_WRONLY, octal!644);
        if (fd < 0)
        {
            stderr.writefln("open(sub/file) failed");
            return 1;
        }
        close(fd);
    }

    // 3. SYMLINKAT: base/link -> base/sub/file.
    {
        const res = runOne(io,
            (ref SubmissionEntry e) => e.prepSymlinkat(linkTarget, AT_FDCWD, linkPath),
            3);
        if (res < 0)
        {
            stderr.writefln("SYMLINKAT failed: errno %d", -res);
            return 1;
        }
    }
    // lstat the link itself (don't follow) to confirm it's a symlink, and stat it
    // (follow) to confirm it resolves to the regular file.
    if (!checkMode(linkPath, m => S_ISLNK(m), /*useLstat*/ true))
    {
        stderr.writefln("post-SYMLINKAT: link is not a symlink");
        return 1;
    }
    if (!checkMode(linkPath, m => S_ISREG(m)))
    {
        stderr.writefln("post-SYMLINKAT: link does not resolve to a regular file");
        return 1;
    }

    // 4. RENAMEAT: sub/file -> sub/renamed (flags 0 == plain renameat semantics).
    {
        const res = runOne(io,
            (ref SubmissionEntry e) => e.prepRenameat(AT_FDCWD, filePath, AT_FDCWD, renamed, 0),
            4);
        if (res < 0)
        {
            stderr.writefln("RENAMEAT failed: errno %d", -res);
            return 1;
        }
    }
    if (checkMode(filePath, m => true) || !checkMode(renamed, m => S_ISREG(m)))
    {
        stderr.writefln("post-RENAMEAT: rename did not take effect");
        return 1;
    }

    // 5a. UNLINKAT: remove sub/renamed (the regular file).
    {
        const res = runOne(io,
            (ref SubmissionEntry e) => e.prepUnlinkat(AT_FDCWD, renamed, 0),
            5);
        if (res < 0)
        {
            stderr.writefln("UNLINKAT(file) failed: errno %d", -res);
            return 1;
        }
    }
    // 5b. UNLINKAT: remove the dangling symlink (flags 0 unlinks the link itself).
    {
        const res = runOne(io,
            (ref SubmissionEntry e) => e.prepUnlinkat(AT_FDCWD, linkPath, 0),
            6);
        if (res < 0)
        {
            stderr.writefln("UNLINKAT(symlink) failed: errno %d", -res);
            return 1;
        }
    }
    if (checkMode(renamed, m => true, true) || checkMode(linkPath, m => true, true))
    {
        stderr.writefln("post-UNLINKAT: file or symlink still present");
        return 1;
    }

    // 6. UNLINKAT with AT_REMOVEDIR: remove the now-empty sub/ directory.
    {
        const res = runOne(io,
            (ref SubmissionEntry e) => e.prepUnlinkat(AT_FDCWD, subDir, AT_REMOVEDIR),
            7);
        if (res < 0)
        {
            stderr.writefln("UNLINKAT(dir) failed: errno %d", -res);
            return 1;
        }
    }
    if (checkMode(subDir, m => true, true))
    {
        stderr.writefln("post-UNLINKAT: sub/ directory still present");
        return 1;
    }

    writefln("ok: drove MKDIRAT/SYMLINKAT/RENAMEAT/UNLINKAT through the ring in %s — final state verified", base);
    return 0;
}

// errno + octal helpers (kept local to avoid extra imports cluttering the header).
import core.sys.linux.errno : EINVAL;

/// Compile-time octal literal (D dropped the `0NNN` syntax; std.conv.octal works too).
template octal(int n) { enum octal = octalImpl(n); }
private int octalImpl(int decimalDigits) pure nothrow @nogc @safe
{
    int result = 0, mult = 1;
    while (decimalDigits > 0)
    {
        result += (decimalDigits % 10) * mult;
        mult *= 8;
        decimalDigits /= 10;
    }
    return result;
}
