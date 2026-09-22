#!/usr/bin/env dub
/+ dub.sdl:
    name "component_walk"
    platforms "posix"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The portable fallback: resolving a relative path one component at a time
 * with `openat(parent, name, O_NOFOLLOW | O_DIRECTORY)`.
 *
 * This is the algorithm every surveyed library falls back to when the kernel
 * offers no `openat2` / `O_RESOLVE_BENEATH` / `O_NOFOLLOW_ANY`: reject `..`
 * and absolute paths lexically, then open each intermediate directory relative
 * to the previous one with `O_NOFOLLOW`, so a symlink anywhere in the path is
 * refused instead of followed, and the leaf with `O_NOFOLLOW` too. Every step
 * is atomic with respect to the *previous* handle, which is what a path string
 * can never be. The demonstration plants a symlinked intermediate and a
 * symlinked leaf and shows both refused, and a `..` refused before any syscall.
 *
 * One detail the output makes visible: a symlinked *leaf* is `ELOOP`, but a
 * symlinked *intermediate* opened with `O_NOFOLLOW | O_DIRECTORY` is `ENOTDIR`
 * on Linux — the directory check runs before the symlink check — so a fallback
 * that wants to tell "a symlink" from "a regular file in the way" cannot read
 * it off the errno; it has to `fstatat(AT_SYMLINK_NOFOLLOW)` the component.
 *
 * Companion to docs/research/safe-path-traversal/comparison.md
 * § "The component walk".
 *
 * Run with: `dub run --single component-walk.d`
 */
module component_walk;

import core.stdc.errno : errno, ELOOP, ENOENT, ENOTDIR;
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

import std.algorithm.iteration : filter, splitter;
import std.algorithm.searching : canFind;
import std.array : array;
import std.conv : text;
import std.file : exists, mkdirRecurse, rmdirRecurse, symlink, tempDir, write;
import std.path : buildPath, isAbsolute;
import std.stdio : writefln, writeln;
import std.string : toStringz;

/// The outcome of a walk: an fd (>= 0), or a negative errno, or `-1` with a
/// lexical reason (the walk never reached the kernel).
struct Walked
{
    int fd = -1;
    string lexicalRefusal;
    int err;
}

Walked walk(int rootfd, string relative)
{
    Walked w;
    if (relative.isAbsolute)
    {
        w.lexicalRefusal = "absolute path";
        return w;
    }
    auto parts = relative.splitter('/').filter!(p => p.length && p != ".").array;
    if (parts.canFind(".."))
    {
        w.lexicalRefusal = "`..` component";
        return w;
    }

    int cur = rootfd;
    foreach (i, part; parts)
    {
        const last = i + 1 == parts.length;
        const flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? 0 : O_DIRECTORY);
        const next = openat(cur, part.toStringz, flags);
        const e = errno;
        if (cur != rootfd)
            close(cur);
        if (next < 0)
        {
            w.err = e;
            return w;
        }
        cur = next;
    }
    w.fd = cur;
    return w;
}

string errName(int e)
{
    switch (e)
    {
        case ELOOP: return "ELOOP";
        case ENOENT: return "ENOENT";
        case ENOTDIR: return "ENOTDIR";
        default: return text("errno ", e);
    }
}

void report(int rootfd, string path)
{
    auto w = walk(rootfd, path);
    string outcome;
    if (w.lexicalRefusal.length)
        outcome = "refused lexically: " ~ w.lexicalRefusal;
    else if (w.fd >= 0)
    {
        outcome = "ok";
        if (w.fd != rootfd)
            close(w.fd);
    }
    else
        outcome = errName(w.err);
    writefln("  %-32s %s", path, outcome);
}

int main()
{
    const root = buildPath(tempDir, "component-walk-demo");
    if (root.exists)
        rmdirRecurse(root);
    scope (exit) rmdirRecurse(root);
    mkdirRecurse(buildPath(root, "a", "b"));
    write(buildPath(root, "a", "b", "leaf.txt"), "x");
    symlink("a", buildPath(root, "link-dir")); // a symlinked intermediate
    symlink("b/leaf.txt", buildPath(root, "a", "link-leaf")); // a symlinked leaf

    const rootfd = open(root.toStringz, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    assert(rootfd >= 0);
    scope (exit) close(rootfd);

    writeln("component walk, O_NOFOLLOW on every step:");
    report(rootfd, "a/b/leaf.txt");
    report(rootfd, "./a//b/leaf.txt");
    report(rootfd, "link-dir/b/leaf.txt");
    report(rootfd, "a/link-leaf");
    report(rootfd, "a/../a/b/leaf.txt");
    report(rootfd, "/etc/hostname");
    report(rootfd, "a/b/leaf.txt/deeper");
    report(rootfd, "a/missing");
    return 0;
}
