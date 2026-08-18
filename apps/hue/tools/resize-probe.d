#!/usr/bin/env dub
/+ dub.sdl:
    name "resize_probe"
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// The oracle for hue's resize contract (`NAV5`/`NAV6`, issue #299).
//
// The scroll offset is defined against the SOURCE, not against a visual row,
// so resizing the terminal must change only how much of the file follows the
// first visible line — never which line that is. The unit tests drive
// `resize` + `relayout` directly; this drives the whole chain: a real pty, a
// real SIGWINCH, the workspace's `arrange`, and the dock's own clamp.
//
//   dub run --single apps/hue/tools/resize-probe.d -- \
//       --bin apps/hue/build/hue --file libs/ui/src/sparkles/ui/state.d
//
// Two details are load-bearing, and each cost an afternoon when missing:
//
//   * The child must own the pty as its CONTROLLING terminal, or the kernel
//     delivers no `SIGWINCH` at all and the probe silently measures nothing
//     (it reads as a pass). `setsid -c` is what establishes that.
//   * Both readings must come from a FULL repaint. hue's compositor writes
//     cell diffs, so a screen scrolled to by keystrokes cannot be
//     reconstructed without a VT. Hence two resizes: a one-row nudge to get
//     a clean "before" frame (itself an anchor case), then the real change.
//
// Exit status: 0 the first line held, 1 it moved, 2 a setup problem.
module resize_probe;

import core.sys.posix.fcntl : F_GETFL, F_SETFL, fcntl, O_NONBLOCK;
import core.sys.posix.sys.ioctl : ioctl, TIOCSWINSZ, winsize;
import core.sys.posix.termios : termios;
import core.sys.posix.unistd : read, write;
import core.thread : Thread;
import core.time : msecs;

import std.algorithm : max;
import std.process : Config, environment, spawnProcess, wait;
import std.stdio : File, stderr, writefln, writeln;
import std.string : indexOf, startsWith, stripRight;

import sparkles.core_cli.args : HelpInfo, Option, parseCli, reportCliError;

extern (C) int openpty(int* amaster, int* aslave, char* name,
    const termios* termp, const winsize* winp) @system;

/// CLI surface (parsed by `sparkles:core-cli`, per the D-tooling guideline).
struct Params
{
    @(Option("bin|b", description: "The hue binary to probe"))
    string bin = "apps/hue/build/hue";

    @(Option("file|f", description: "The file to open in the viewer"))
    string file = "libs/ui/src/sparkles/ui/state.d";

    @(Option("cols", description: "Starting terminal width"))
    int cols = 100;

    @(Option("rows", description: "Starting terminal height"))
    int rows = 24;

    @(Option("to-cols", description: "Width to resize to"))
    int toCols = 60;

    @(Option("to-rows", description: "Height to resize to"))
    int toRows = 40;

    @(Option("down", description: "Lines to scroll before resizing"))
    int down = 20;

    @(Option("settle", description: "Milliseconds to wait for each frame"))
    int settleMs = 1500;

    @(Option("show", description: "Print both first lines even when they agree"))
    bool show;
}

int main(string[] rawArgs)
{
    auto parsed = parseCli!Params(rawArgs, HelpInfo("resize-probe",
        "Prove hue's viewer keeps the same SOURCE line at the top of the pane "
        ~ "across a terminal resize, through a real pty and a real SIGWINCH.",
        null));
    if (!parsed)
        return reportCliError(parsed.error);
    auto p = parsed.value;

    int master, slave;
    auto ws = winsize(cast(ushort) p.rows, cast(ushort) p.cols, 0, 0);
    if (openpty(&master, &slave, null, null, &ws) != 0)
    {
        stderr.writeln("resize-probe: openpty failed");
        return 2;
    }
    // Non-blocking, so a quiet frame ends the drain instead of wedging it.
    fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK);

    auto sl = File();
    sl.fdopen(slave, "r+");
    // `setsid -c`: a new session with THIS pty as the controlling terminal —
    // without it the resize below signals nobody.
    auto pid = spawnProcess(
        ["setsid", "-c", p.bin, "view", "--tui", p.file],
        sl, sl, sl, null, Config.retainStdout | Config.retainStderr);

    char[65_536] buf;
    string drain(int ms)
    {
        string all;
        foreach (_; 0 .. max(1, ms / 50))
        {
            Thread.sleep(50.msecs);
            const n = read(master, buf.ptr, buf.length);
            if (n > 0)
                all ~= buf[0 .. n].idup;
        }
        return all;
    }

    void send(string s) { write(master, s.ptr, s.length); }

    void resize(int cols, int rows)
    {
        auto next = winsize(cast(ushort) rows, cast(ushort) cols, 0, 0);
        ioctl(master, TIOCSWINSZ, &next);
    }

    drain(p.settleMs);
    foreach (_; 0 .. p.down)
        send("j");
    drain(p.settleMs / 2);

    resize(p.cols, p.rows + 1); // the nudge: a clean "before" repaint
    const before = drain(p.settleMs);
    resize(p.toCols, p.toRows); // the real change
    const after = drain(p.settleMs);

    send("q");
    drain(300);
    wait(pid);

    const b = firstContentLine(before);
    const a = firstContentLine(after);
    if (b.length == 0 || a.length == 0)
    {
        stderr.writeln("resize-probe: no full repaint captured — the child "
            ~ "may lack a controlling terminal (is `setsid` on PATH?)");
        return 2;
    }
    // The narrower pane re-wraps, so the AFTER line is a prefix of the BEFORE
    // one: the same source line, clipped by the shorter row.
    const held = b.startsWith(a) || a.startsWith(b);
    if (!held || p.show)
    {
        writefln("before (%sx%s): %s", p.cols, p.rows + 1, b);
        writefln("after  (%sx%s): %s", p.toCols, p.toRows, a);
    }
    if (!held)
    {
        stderr.writeln("resize-probe: the resize MOVED the first visible line");
        return 1;
    }
    writeln("resize-probe: the first visible source line held across the resize");
    return 0;
}

/**
The text a full repaint painted on the pane's first content row.

A repaint addresses each row absolutely (`CUP`), so the first body row is
whatever follows `ESC[2;1H` up to the next cursor address — no VT needed, and
deliberately so: this tool must work on a capture, not on a live screen. Escape
sequences inside the run are dropped, which leaves the row's text.
*/
private string firstContentLine(string frame) @safe
{
    const at = frame.indexOf("\x1b[2;1H");
    if (at < 0)
        return null;
    auto rest = frame[at + 6 .. $];
    const end = rest.indexOf("\x1b[3;1H");
    if (end > 0)
        rest = rest[0 .. end];
    string text;
    size_t i;
    while (i < rest.length)
    {
        if (rest[i] == '\x1b')
        {
            // CSI/OSC: skip to the sequence's final byte.
            i++;
            if (i < rest.length && rest[i] == '[')
            {
                i++;
                while (i < rest.length && (rest[i] < '@' || rest[i] > '~'))
                    i++;
                i++;
            }
            else if (i < rest.length && rest[i] == ']')
            {
                while (i < rest.length && rest[i] != '\x07')
                    i++;
                i++;
            }
            continue;
        }
        if (rest[i] >= 32 || rest[i] < 0)
            text ~= rest[i];
        i++;
    }
    return text.trimRow;
}

/**
Drops the row's trailing chrome: the scrollbar cell the pane reserves on the
right, plus the padding before it. What remains is the row's content, which is
what a resize must preserve.
*/
private string trimRow(string row) @safe
{
    import std.string : stripRight;

    auto r = row.stripRight;
    foreach (bar; ["\u2588", "\u2593", "\u2592", "\u2591"])
        while (r.length >= bar.length && r[$ - bar.length .. $] == bar)
            r = r[0 .. $ - bar.length].stripRight;
    return r;
}
