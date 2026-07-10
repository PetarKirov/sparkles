#!/usr/bin/env dub
/+ dub.sdl:
    name "gen_tree"
    platforms "linux"
    targetPath "build"
    buildType "release"
+/
/**
 * Synthetic directory-tree generator for the walk benchmark — lets the harness
 * vary the two axes that matter for a parallel walker: BREADTH (fan-out per
 * directory) and DEPTH (nesting), plus files-per-directory (dense vs sparse).
 *
 * A uniform tree of `breadth`^`depth` interior directories, each holding
 * `files` empty files; total dirs = (breadth^(depth+1) - 1) / (breadth - 1).
 *
 * Usage: gen-tree <root> <breadth> <depth> <files-per-dir>
 *
 * Fast: builds paths with a reused buffer and creates entries via `openat`/
 * `mkdirat` relative to a directory fd, so the kernel never re-resolves the
 * full path per entry.
 */
module gen_tree;

import core.stdc.stdio : printf;
import core.sys.posix.fcntl : O_CREAT, O_RDONLY, O_WRONLY;
import core.sys.posix.unistd : close;

import std.conv : octal, to;

// Not in druntime's posix bindings; declare the *at() variants by hand.
enum int O_DIRECTORY = 0x10000; // Linux value
enum int AT_FDCWD = -100;
extern (C) nothrow @nogc
{
    int openat(int dirfd, const(char)* pathname, int flags, uint mode = 0);
    int mkdirat(int dirfd, const(char)* pathname, uint mode);
}

int main(string[] argv)
{
    if (argv.length != 5)
    {
        printf("usage: gen-tree <root> <breadth> <depth> <files-per-dir>\n");
        return 2;
    }
    const root = argv[1];
    const breadth = argv[2].to!int;
    const depth = argv[3].to!int;
    const files = argv[4].to!int;

    import core.sys.posix.sys.stat : mkdir;
    import std.string : toStringz;

    mkdir(root.toStringz, octal!755);
    const rootFd = (() @trusted => openat(AT_FDCWD, root.toStringz,
        O_RDONLY | O_DIRECTORY))();
    if (rootFd < 0)
    {
        printf("gen-tree: cannot open root\n");
        return 1;
    }

    long dirs, made;
    build(rootFd, breadth, depth, files, dirs, made);
    close(rootFd);
    printf("%ld dirs, %ld files\n", dirs + 1, made);
    return 0;
}

/// Populates the directory behind `dfd` with `files` files and `breadth`
/// subtrees to `depth`, closing nothing but `dfd`'s children.
void build(int dfd, int breadth, int depth, int files, ref long dirs, ref long made) @trusted
{
    char[32] name = void;
    foreach (f; 0 .. files)
    {
        const n = fmtName(name, 'f', f);
        const fd = openat(dfd, name.ptr, O_CREAT | O_WRONLY, octal!644);
        if (fd >= 0)
        {
            close(fd);
            ++made;
        }
    }
    if (depth == 0)
        return;
    foreach (b; 0 .. breadth)
    {
        fmtName(name, 'd', b);
        if (mkdirat(dfd, name.ptr, octal!755) != 0)
            continue;
        ++dirs;
        const sub = openat(dfd, name.ptr, O_RDONLY | O_DIRECTORY);
        if (sub < 0)
            continue;
        build(sub, breadth, depth - 1, files, dirs, made);
        close(sub);
    }
}

/// Writes `prefix` + decimal `n` + NUL into `buf`; returns the length.
size_t fmtName(ref char[32] buf, char prefix, int n) @safe pure nothrow @nogc
{
    buf[0] = prefix;
    size_t i = 1;
    if (n == 0)
        buf[i++] = '0';
    else
    {
        char[16] tmp = void;
        size_t j;
        for (int v = n; v > 0; v /= 10)
            tmp[j++] = cast(char)('0' + v % 10);
        while (j > 0)
            buf[i++] = tmp[--j];
    }
    buf[i] = '\0';
    return i;
}
