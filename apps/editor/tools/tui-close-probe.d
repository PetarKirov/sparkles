#!/usr/bin/env dub
/+ dub.sdl:
    name "editor-tui-close-probe"
    targetPath "../build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/// Exercise the real terminal interrupt/dirty-close policy on a private PTY.
module editor_tui_close_probe;

import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
import core.sys.posix.poll : poll, POLLIN, pollfd;
import core.sys.posix.signal : kill, SIGKILL;
import core.sys.posix.sys.ioctl : winsize;
import core.sys.posix.sys.wait : waitpid, WNOHANG;
import core.sys.posix.unistd : close, execvp, read, write, _exit;
import core.time : MonoTime, msecs, seconds;
import core.thread : Thread;
import std.algorithm.searching : canFind;
import std.file : mkdir, rmdirRecurse, tempDir;
import std.path : buildPath, dirName;
import std.process : environment;
import std.stdio : writeln;
import std.string : toStringz;
import std.uuid : randomUUID;

extern (C) int forkpty(int* master, char* name, const void* termp, const winsize* winp);

int main() @system
{
    const state = buildPath(tempDir, "editor-tui-state-" ~ randomUUID().toString());
    mkdir(state);
    scope (exit) rmdirRecurse(state);
    const editor = buildPath(__FILE_FULL_PATH__.dirName.dirName, "build", "editor");
    auto args = [editor, "--tui", "--state-dir", state];
    environment["TERM"] = "xterm-256color";
    winsize size = {ws_row: 30, ws_col: 90};
    int master;
    const child = forkpty(&master, null, null, &size);
    assert(child >= 0);
    if (child == 0)
    {
        auto argv = new const(char)*[args.length + 1];
        foreach (i, arg; args) argv[i] = arg.toStringz;
        execvp(argv[0], cast(char**) argv.ptr);
        _exit(127);
    }
    bool reaped;
    int status;
    scope (exit)
    {
        if (!reaped)
        {
            kill(child, SIGKILL); // Only the probe-owned child.
            waitpid(child, &status, 0);
        }
        close(master);
    }
    assert(fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK) == 0);
    char[] captured;
    void drain()
    {
        char[8192] bytes;
        while (true)
        {
            const count = read(master, bytes.ptr, bytes.length);
            if (count <= 0) break;
            captured ~= bytes[0 .. count];
        }
        if (!reaped) reaped = waitpid(child, &status, WNOHANG) == child;
    }
    void awaitText(string expected, size_t since = 0)
    {
        const deadline = MonoTime.currTime + 5.seconds;
        while (!captured[since .. $].canFind(expected) && !reaped && MonoTime.currTime < deadline)
        {
            pollfd descriptor = {fd: master, events: POLLIN};
            poll(&descriptor, 1, 10);
            drain();
        }
        assert(captured[since .. $].canFind(expected), "Missing terminal text: " ~ expected ~ "\n" ~ captured.idup);
        assert(!reaped, "Terminal exited before the close decision: " ~ captured.idup);
    }
    void send(string bytes) { assert(write(master, bytes.ptr, bytes.length) == bytes.length); }
    awaitText("Sparkles Editor");
    send("a");
    awaitText("Modified");
    send("\x03"); // Ctrl+C must request closure while the terminal is alive.
    awaitText("Save, Discard or Cancel?");
    send("\x1B"); // Cancel; then use the ordinary Quit command.
    Thread.sleep(100.msecs); // Let the terminal's standalone-Escape deadline expire.
    drain();
    const before = captured.length;
    send("\x11"); // Ctrl+Q.
    awaitText("Save, Discard or Cancel?", before);
    send("d");
    const deadline = MonoTime.currTime + 5.seconds;
    while (!reaped && MonoTime.currTime < deadline)
    {
        pollfd descriptor = {fd: master, events: POLLIN};
        poll(&descriptor, 1, 10);
        drain();
    }
    assert(reaped && status == 0, "Discard did not flush and exit cleanly: " ~ captured.idup);
    writeln("terminal Ctrl+C deferred dirty close; Escape retained the draft; Ctrl+Q and Discard flushed and exited");
    return 0;
}
