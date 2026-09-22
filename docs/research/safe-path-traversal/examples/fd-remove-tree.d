#!/usr/bin/env dub
/+ dub.sdl:
    name "fd_remove_tree"
    platforms "posix"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The `rm -r` shape that Rust's CVE-2022-21658 fix, CPython's `rmtree`
 * (`avoids_symlink_attacks`) and gnulib's `fts` (`FTS_CWDFD`) converged on:
 * recursive deletion through directory *handles*, never through paths.
 *
 * Each directory is opened relative to its parent with `O_NOFOLLOW`, listed
 * with `fdopendir`, and every entry removed with `unlinkat` relative to that
 * handle (`AT_REMOVEDIR` for a subdirectory once it is empty). A symlink is a
 * name to unlink, never a directory to descend — so the demonstration plants
 * a symlink to a directory *outside* the tree and shows that directory's
 * contents survive the removal.
 *
 * Companion to docs/research/safe-path-traversal/rust-std.md
 * § "Dimension 7 — enumeration and deletion".
 *
 * Run with: `dub run --single fd-remove-tree.d`
 */
module fd_remove_tree;

import core.stdc.errno : errno;
import core.sys.posix.dirent : DIR, closedir, dirent, readdir;
import core.sys.posix.fcntl : O_RDONLY, O_NOFOLLOW, open, openat;

// Darwin's druntime `core.sys.posix.fcntl` declares neither; the values are
// XNU's `bsd/sys/fcntl.h`.
version (OSX)
{
    enum O_DIRECTORY = 0x100000;
    enum O_CLOEXEC = 0x1000000;
}
else
    import core.sys.posix.fcntl : O_DIRECTORY, O_CLOEXEC;
import core.sys.posix.unistd : close;

import std.conv : text;
import std.exception : enforce;
import std.file : dirEntries, exists, mkdirRecurse, rmdirRecurse, SpanMode,
    symlink, tempDir, write;
import std.path : buildPath;
import std.stdio : writefln, writeln;
import std.string : fromStringz, toStringz;

// Neither is in druntime's core.sys.posix as of LDC 1.42.
extern (C) nothrow @nogc
{
    DIR* fdopendir(int fd);
    int unlinkat(int dirfd, const char* path, int flags);
}

// `AT_REMOVEDIR` differs per platform — the price of a portable `*at` layer.
version (linux)
    enum AT_REMOVEDIR = 0x200;
else version (OSX)
    enum AT_REMOVEDIR = 0x080;
else version (FreeBSD)
    enum AT_REMOVEDIR = 0x800;
else
    static assert(0, "AT_REMOVEDIR for this platform");

/// Removes everything inside the directory open at `dirfd`; the caller removes
/// the directory itself. `depth` bounds recursion so a pathological tree
/// cannot exhaust the stack or the fd table.
void removeContents(int dirfd, uint depth, ref uint removed)
{
    enforce(depth < 64, "tree too deep");
    // `fdopendir` takes ownership of the fd it is given — and of its *file
    // description*, whose offset `readdir` then moves. A `dup` would share that
    // description with our own `dirfd`, so rustix re-opens the directory
    // through the handle instead (`openat(fd, ".")`): a fresh description that
    // still cannot be redirected, because `.` is resolved relative to the
    // handle, not to a path.
    const listfd = openat(dirfd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    enforce(listfd >= 0, "reopen for listing failed");
    DIR* d = fdopendir(listfd);
    enforce(d !is null, "fdopendir failed");
    scope (exit) closedir(d);

    while (true)
    {
        errno = 0;
        dirent* e = readdir(d);
        if (e is null)
            break;
        const name = e.d_name.ptr.fromStringz;
        if (name == "." || name == "..")
            continue;

        // Try as a directory first, WITHOUT following: a symlink to a
        // directory fails here (`ENOTDIR` on Linux, `ELOOP` on older kernels
        // and other systems — Rust std accepts both) and is unlinked below.
        const child = openat(dirfd, name.toStringz,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (child >= 0)
        {
            removeContents(child, depth + 1, removed);
            close(child);
            enforce(unlinkat(dirfd, name.toStringz, AT_REMOVEDIR) == 0,
                text("rmdir ", name));
        }
        else
            enforce(unlinkat(dirfd, name.toStringz, 0) == 0, text("unlink ", name));
        removed++;
    }
}

int main()
{
    const base = buildPath(tempDir, "fd-remove-tree-demo");
    if (base.exists)
        rmdirRecurse(base);
    scope (exit) rmdirRecurse(base);

    const outside = buildPath(base, "outside");
    const victim = buildPath(base, "victim");
    mkdirRecurse(buildPath(outside));
    write(buildPath(outside, "precious.txt"), "keep me");
    mkdirRecurse(buildPath(victim, "sub", "deeper"));
    write(buildPath(victim, "top.txt"), "x");
    write(buildPath(victim, "sub", "deeper", "leaf.txt"), "x");
    symlink(outside, buildPath(victim, "sub", "escape")); // the trap

    const fd = open(victim.toStringz, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    assert(fd >= 0);
    uint removed;
    removeContents(fd, 0, removed);
    close(fd);
    rmdirRecurse(victim); // the now-empty root, by path — it is ours

    writefln("removed %d entries beneath victim/", removed);
    writefln("victim/ exists afterwards: %s", victim.exists);
    writefln("outside/precious.txt survived: %s",
        buildPath(outside, "precious.txt").exists);
    return 0;
}
