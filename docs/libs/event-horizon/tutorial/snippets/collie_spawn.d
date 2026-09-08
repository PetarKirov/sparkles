#!/usr/bin/env dub
/+ dub.sdl:
    name "collie_spawn"
    dependency "collie" path=".deps/collie"
    dependency "kiss" path=".deps/kiss"
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
    import kiss.event;
    import kiss.event.task : newTask;
    import core.thread : Thread;
    auto loop = new EventLoop();
    scope(exit) loop.dispose();
    bool delivered;
    auto worker = new Thread({
        work();
        loop.postTask(newTask({ delivered = true; loop.stop(); }));
    });
    worker.start();
    loop.run();
    worker.join();
    assert(delivered);
}
