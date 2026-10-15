#!/usr/bin/env dub
/+ dub.sdl:
    name "term_replies_capture"
    dependency "sparkles:base" path="../../.."
    targetPath "build"
    // Optimised, assertions live, `debug {}` blocks out — the build every nix
    // artifact uses. Neither `debug` (which compiles those blocks in) nor
    // `release` (which deletes assert *expressions*, side effects included).
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// ci: build-only
/++
Captures one `O5` transcript: sends `queryBattery` to the terminal it runs in,
collects the replies until the DA1 fence (or 3 s), and writes them in the
format `libs/base/test/data/term_replies/` holds, control bytes spelled `ESC`
and `BEL`.

    term_replies_capture "kitty 0.48.2 (Linux, xvfb)" > kitty.txt
    term_replies_capture --out /tmp/iterm2.txt "iTerm2 3.6.10 (macOS 27)"

Run it inside the terminal being recorded, with `TMUX`, `ZELLIJ` and
`TERM_PROGRAM*` unset unless a multiplexer is the subject. With `--out` the
transcript goes to a file, so a GUI terminal launched to run it can close
straight away; without it, the terminal is restored before stdout is written.
+/
module term_replies_capture;

import core.stdc.stdlib : getenv;
import core.sys.posix.poll : poll, pollfd, POLLIN;
import core.sys.posix.termios;
import core.sys.posix.unistd : read, STDIN_FILENO, STDOUT_FILENO, write;
import core.time : MonoTime, seconds;

import std.array : appender;
import std.file : fileWrite = write;
import std.stdio : stderr, stdout;
import std.string : fromStringz;

import sparkles.base.term_control : CtlSeq;
import sparkles.base.term_replies : parseReplies, queryBattery, TerminalReplies;

int main(string[] args)
{
    string label, outPath;
    for (size_t i = 1; i < args.length; i++)
    {
        if (args[i] == "--out" && i + 1 < args.length)
            outPath = args[++i];
        else
            label = args[i];
    }
    if (label.length == 0)
    {
        stderr.writeln("usage: term_replies_capture [--out FILE] \"<terminal version (host)>\"");
        return 2;
    }

    termios saved;
    if (tcgetattr(STDIN_FILENO, &saved) != 0)
    {
        stderr.writeln("term_replies_capture: stdin is not a terminal");
        return 1;
    }
    auto raw = saved;
    raw.c_lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);

    // The battery runs where a live probe does: inside a `sparkles:tui` session,
    // which has pushed its kitty keyboard flags (so `CSI ? u` reports them).
    enum string probe = CtlSeq.pushKeyboardMode ~ queryBattery;
    write(STDOUT_FILENO, probe.ptr, probe.length);

    TerminalReplies replies;
    ubyte[] received, rest;
    const deadline = MonoTime.currTime + 3.seconds;
    while (!replies.fenced)
    {
        const left = (deadline - MonoTime.currTime).total!"msecs";
        if (left <= 0)
            break;
        auto pfd = pollfd(STDIN_FILENO, POLLIN, 0);
        if (poll(&pfd, 1, cast(int) left) <= 0)
            continue;
        ubyte[256] chunk;
        const n = read(STDIN_FILENO, chunk.ptr, chunk.length);
        if (n <= 0)
            continue;
        received ~= chunk[0 .. n];
        // Re-parse from the start: a reply split across reads completes later.
        replies = TerminalReplies.init;
        rest = null;
        parseReplies(received, replies, rest);
    }
    write(STDOUT_FILENO, CtlSeq.popKeyboardMode.ptr, CtlSeq.popKeyboardMode.length);
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved);

    auto text = appender!string;
    text ~= "terminal: " ~ label ~ "\n";
    foreach (name; ["TERM", "COLORTERM"])
        text ~= name ~ ": " ~ env(name) ~ "\n";
    foreach (name; ["TMUX", "ZELLIJ"])
        text ~= name ~ ":" ~ (env(name).length ? " set" : "") ~ "\n";
    text ~= "replies: ";
    foreach (b; received)
    {
        if (b == 0x1b)
            text ~= "ESC";
        else if (b == 0x07)
            text ~= "BEL";
        else
            text ~= cast(char) b;
    }
    text ~= "\n";

    if (!replies.fenced)
        stderr.writeln("term_replies_capture: no DA1 fence within 3 s; recording what arrived");
    if (outPath.length)
        fileWrite(outPath, text[]);
    else
        stdout.write(text[]);
    return 0;
}

private string env(string name)
{
    import std.string : toStringz;

    auto v = getenv(name.toStringz);
    return v is null ? "" : v.fromStringz.idup;
}
