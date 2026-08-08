#!/usr/bin/env dub
/+ dub.sdl:
    name "ui_gallery_pty_drive"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Drives a full-screen terminal application on a pty of a chosen size — the
harness `script(1)` cannot be (it hands a 0×0 pty when stdin is not a tty).

Feeds timed byte steps, optionally resizes the pty mid-run (`TIOCSWINSZ` +
`SIGWINCH`, exactly what a terminal emulator does when its window changes),
captures everything the application writes, and reaps it. Used to reproduce
and verify resize/scrollback behaviour of the gallery's Terminal page from a
test script, with no display and no human.

---
dub run --single tools/pty-drive.d -- --cols 90 --rows 24 \
    --step 1500:09 --step 300:6e --step 2000:1d --step 300:71 \
    --resize 3000:130:30 --out /tmp/cap.log -- ./build/ui-gallery --tui
---

A `--step ms:hex` writes the hex-decoded bytes at `ms` since start; a
`--resize ms:cols:rows` resizes then. Steps and resizes interleave by time.
*/
module ui_gallery_pty_drive;

import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
import core.sys.posix.poll : poll, POLLIN, pollfd;
import core.sys.posix.signal : kill, SIGHUP;

// glibc's <signal.h> value; druntime's core.sys.posix.signal does not carry it.
version (linux) private enum SIGWINCH = 28;
else private enum SIGWINCH = 28;
import core.sys.posix.sys.ioctl : ioctl, TIOCSWINSZ, winsize;
import core.sys.posix.sys.types : pid_t;
import core.sys.posix.sys.wait : waitpid, WNOHANG;
import core.sys.posix.unistd : close, execvp, read, write, _exit;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs;

import std.algorithm : sort;
import std.array : array;
import std.conv : to;
import std.format : format;
import std.getopt : getopt;
import std.file : write_ = write;
import std.stdio : stderr, writefln;
import std.string : split, toStringz;

extern (C) int forkpty(int* amaster, char* name, const void* termp,
    const winsize* winp);

struct Action
{
    int atMs;
    const(ubyte)[] bytes;   // empty for a resize
    ushort cols, rows;      // for a resize
    bool isResize;
}

int main(string[] args)
{
    int cols = 80, rows = 24, settleMs = 800;
    string outPath = "pty-capture.log";
    string[] stepSpecs, resizeSpecs;

    auto parsed = getopt(args,
        "cols", &cols,
        "rows", &rows,
        "step", &stepSpecs,
        "resize", &resizeSpecs,
        "settle", &settleMs,
        "out", &outPath);
    if (parsed.helpWanted || args.length < 2)
    {
        stderr.writefln("usage: pty-drive [--cols N --rows N] [--step ms:hex]... "
            ~ "[--resize ms:cols:rows]... [--out FILE] -- <command...>");
        return 2;
    }

    Action[] actions;
    foreach (s; stepSpecs)
    {
        const p = s.split(":");
        actions ~= Action(atMs: p[0].to!int, bytes: fromHex(p[1]));
    }
    foreach (s; resizeSpecs)
    {
        const p = s.split(":");
        actions ~= Action(atMs: p[0].to!int, isResize: true,
            cols: p[1].to!ushort, rows: p[2].to!ushort);
    }
    actions.sort!((a, b) => a.atMs < b.atMs);

    winsize ws = { ws_row: cast(ushort) rows, ws_col: cast(ushort) cols };
    int master;
    const pid = forkpty(&master, null, null, &ws);
    if (pid < 0)
    {
        stderr.writefln("pty-drive: forkpty failed");
        return 1;
    }
    if (pid == 0)
    {
        auto argv = new const(char)*[](args.length);
        foreach (i, a; args[1 .. $])
            argv[i] = a.toStringz;
        argv[args.length - 1] = null;
        execvp(argv[0], cast(char**) argv.ptr);
        _exit(127);
    }

    const flags = fcntl(master, F_GETFL);
    fcntl(master, F_SETFL, flags | O_NONBLOCK);

    ubyte[] captured;
    const start = MonoTime.currTime;
    size_t next = 0;
    bool childGone;

    void drain()
    {
        ubyte[4096] buf = void;
        while (true)
        {
            const n = read(master, buf.ptr, buf.length);
            if (n > 0)
                captured ~= buf[0 .. n];
            else
                break;
        }
    }

    const lastAt = actions.length ? actions[$ - 1].atMs : 0;
    while (true)
    {
        const elapsed = cast(int) (MonoTime.currTime - start).total!"msecs";
        while (next < actions.length && actions[next].atMs <= elapsed)
        {
            auto a = actions[next++];
            if (a.isResize)
            {
                winsize nws = { ws_row: a.rows, ws_col: a.cols };
                ioctl(master, TIOCSWINSZ, &nws);
                kill(pid, SIGWINCH);
            }
            else if (a.bytes.length)
                write(master, a.bytes.ptr, a.bytes.length);
        }

        drain();

        int status;
        if (waitpid(pid, &status, WNOHANG) == pid)
        {
            childGone = true;
            break;
        }
        if (next >= actions.length && elapsed > lastAt + settleMs)
            break;

        pollfd pfd = { fd: master, events: POLLIN };
        poll(&pfd, 1, 20);
    }

    if (!childGone)
    {
        kill(pid, SIGHUP);
        waitpid(pid, null, 0);
    }
    drain();
    close(master);

    write_(outPath, captured);
    writefln("captured %s bytes to %s", captured.length, outPath);
    return 0;
}

const(ubyte)[] fromHex(scope const(char)[] hex)
{
    assert(hex.length % 2 == 0, "hex bytes come in pairs");
    auto bytes = new ubyte[](hex.length / 2);
    foreach (i, ref b; bytes)
        b = cast(ubyte) hex[i * 2 .. i * 2 + 2].to!ubyte(16);
    return bytes;
}
