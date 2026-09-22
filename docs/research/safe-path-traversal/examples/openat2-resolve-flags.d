#!/usr/bin/env dub
/+ dub.sdl:
    name "openat2_resolve_flags"
    platforms "linux"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * `openat2(2)` — what each `RESOLVE_*` flag accepts and refuses (Linux 5.6+).
 *
 * Builds a scratch tree, then opens nine paths relative to its root with
 * different `resolve` masks and prints the outcome of each. The point is the
 * table this produces: a relative symlink that stays inside the root is fine
 * under `RESOLVE_BENEATH` but refused under `RESOLVE_NO_SYMLINKS`; a `..` that
 * stays beneath is fine in the kernel even though a portable component check
 * must refuse it; an absolute symlink, an absolute path and a `..` climb are
 * all `EXDEV`; a procfs magic link is `ELOOP` under `RESOLVE_NO_MAGICLINKS`.
 *
 * Companion to docs/research/safe-path-traversal/linux-openat2.md
 * § "Dimension 3 — symlink and `..` policy".
 *
 * Run with: `dub run --single openat2-resolve-flags.d`
 *
 * Portability: on a kernel without `openat2` (pre-5.6, or a seccomp policy
 * that returns `ENOSYS`), prints a `SKIP:` line and exits 0.
 */
module openat2_resolve_flags;

import core.stdc.errno : errno, EXDEV, ELOOP, ENOSYS, ENOENT;
import core.sys.linux.unistd : syscall;
import core.sys.posix.fcntl : O_RDONLY, O_DIRECTORY, O_CLOEXEC, open;
import core.sys.posix.unistd : close;

import std.conv : text;
import std.file : exists, mkdirRecurse, rmdirRecurse, symlink, tempDir, write;
import std.path : buildPath;
import std.stdio : writefln, writeln;
import std.string : toStringz;

// From <linux/openat2.h>. Not in druntime as of LDC 1.42.
enum RESOLVE_NO_XDEV = 0x01;
enum RESOLVE_NO_MAGICLINKS = 0x02;
enum RESOLVE_NO_SYMLINKS = 0x04;
enum RESOLVE_BENEATH = 0x08;
enum RESOLVE_IN_ROOT = 0x10;

// From <sys/syscall.h>: 437 on every architecture that has openat2 (it was
// added after the syscall tables were unified).
enum SYS_openat2 = 437;

// `struct open_how` — extensible: the size argument lets the kernel tell an
// old struct from a new one (`E2BIG` if we pass trailing non-zero bytes it
// does not know about).
struct open_how
{
    ulong flags;
    ulong mode;
    ulong resolve;
}

/// Returns the fd, or `-errno`.
int openat2(int dirfd, string path, ulong flags, ulong resolve)
{
    auto how = open_how(flags, 0, resolve);
    const r = syscall(SYS_openat2, dirfd, path.toStringz, &how, how.sizeof);
    return r < 0 ? -errno : cast(int) r;
}

string errName(int e)
{
    switch (e)
    {
        case EXDEV: return "EXDEV";
        case ELOOP: return "ELOOP";
        case ENOENT: return "ENOENT";
        case ENOSYS: return "ENOSYS";
        default: return text("errno ", e);
    }
}

void report(string label, int dirfd, string path, ulong resolve)
{
    const fd = openat2(dirfd, path, O_RDONLY | O_CLOEXEC, resolve);
    if (fd >= 0)
    {
        close(fd);
        writefln("  %-42s %-30s ok", path, label);
    }
    else
        writefln("  %-42s %-30s %s", path, label, errName(-fd));
}

int main()
{
    // Probe first: an `ENOSYS` here means no openat2 at all.
    {
        const fd = openat2(-100 /* AT_FDCWD */, ".", O_RDONLY | O_DIRECTORY, 0);
        if (fd == -ENOSYS)
        {
            writeln("SKIP: openat2 unavailable on this kernel (ENOSYS)");
            return 0;
        }
        if (fd >= 0)
            close(fd);
    }

    const root = buildPath(tempDir, "openat2-resolve-flags-demo");
    if (root.exists)
        rmdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "inside"));
    write(buildPath(root, "inside", "file.txt"), "x");
    symlink("inside", buildPath(root, "link-in")); // relative, stays beneath
    symlink("/", buildPath(root, "link-out")); // absolute: leaves the root

    const dirfd = open(root.toStringz, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    assert(dirfd >= 0);
    scope (exit) close(dirfd);

    writeln("relative to the scratch root:");
    report("BENEATH", dirfd, "inside/file.txt", RESOLVE_BENEATH);
    report("BENEATH", dirfd, "inside/../inside/file.txt", RESOLVE_BENEATH);
    report("BENEATH", dirfd, "../", RESOLVE_BENEATH);
    report("BENEATH", dirfd, "/etc", RESOLVE_BENEATH);
    report("BENEATH", dirfd, "link-out/etc", RESOLVE_BENEATH);
    report("BENEATH", dirfd, "link-in/file.txt", RESOLVE_BENEATH);
    report("BENEATH|NO_SYMLINKS", dirfd, "link-in/file.txt",
        RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS);
    report("IN_ROOT", dirfd, "link-out/inside/file.txt", RESOLVE_IN_ROOT);

    // A magic link: `/proc/self/cwd` is not a symlink to a path but a jump to
    // a kernel object, which is what `RESOLVE_NO_MAGICLINKS` refuses.
    const procfd = open("/proc/self", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (procfd >= 0)
    {
        scope (exit) close(procfd);
        writeln("relative to /proc/self:");
        report("(none)", procfd, "cwd", 0);
        report("NO_MAGICLINKS", procfd, "cwd", RESOLVE_NO_MAGICLINKS);
        report("BENEATH", procfd, "cwd", RESOLVE_BENEATH);
    }
    return 0;
}
