#!/usr/bin/env dub
/+ dub.sdl:
    name "eve_spawn"
    dependency "eve" repository="git+https://codeberg.org/ddn/eve.git" version="c72f75135de636987e91bcd8ec5a22d32d34a197"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/

import std.stdio : writeln;
import std.process : pipeProcess, Redirect, wait, kill;
import core.sys.posix.signal : SIGTERM;

void main()
{
    // Application process adapter: the networking runtime delivers completion,
    // while this worker owns pipes, signalling and root reaping. No tree claim.
    runWorker({
        auto child = pipeProcess(["sh", "-c", "echo one; echo two; exec sleep 30"], Redirect.stdout);
        string[] lines;
        foreach (line; child.stdout.byLine)
        {
            lines ~= line.idup;
            assert(lines.length <= 2);
            if (lines.length == 2) child.pid.kill(SIGTERM); // child-ready handshake
        }
        const status = child.pid.wait();
        child.stdout.close();
        assert(lines == ["one", "two"]);
        assert(status == -SIGTERM);
        foreach(line; lines) writeln("line: ", line);
        writeln("exited: SIGTERM");
        writeln("end: reaped");
    });
}

void runWorker(void delegate() work)
{
    import eve;
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    auto loop = EventLoop.create();
    scope(exit) loop.dispose();
    shared bool finished;
    auto worker = new Thread({ work(); atomicStore(finished, true); });
    worker.start();
    loop.registerTimer(1, 1, (ref EventLoop l, Token t) @safe nothrow {
        if (atomicLoad(finished)) l.stop();
    });
    loop.run();
    worker.join();
    assert(atomicLoad(finished));
}
