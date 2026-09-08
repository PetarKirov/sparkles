#!/usr/bin/env dub
/+ dub.sdl:
    name "libasync_spawn"
    dependency "libasync" version="0.9.8"
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
    import libasync;
    import core.thread : Thread;
    auto loop = new EventLoop();
    scope(exit) { loop.exit(); loop.destroy(); }
    auto notifier = new AsyncNotifier(loop);
    bool delivered;
    notifier.run({ delivered = true; notifier.kill(); });
    auto worker = new Thread({ work(); notifier.trigger(); });
    worker.start();
    while (!delivered) loop.loop();
    worker.join();
    assert(delivered);
}
