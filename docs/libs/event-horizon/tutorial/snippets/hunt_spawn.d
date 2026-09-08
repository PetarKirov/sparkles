#!/usr/bin/env dub
/+ dub.sdl:
    name "hunt_spawn"
    dependency "hunt-net" version="0.7.1"
    dependency "hunt" path=".deps/hunt"
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
    stopStartupClock();
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

// Hunt Task supplies state transitions, not an owning lexical task scope.
// This adapter explicitly owns the OS thread and joins it.
void runWorker(void delegate() work)
{
    import hunt.util.worker.Task : Task;
    import core.thread : Thread;
    auto job = new class Task {
        override protected void doExecute() { work(); }
    };
    auto thread = new Thread(&job.execute);
    thread.start();
    thread.join();
    assert(job.isDone());
}

// Standalone-process workaround for the pinned Hunt DateTime daemon: its
// destructor stops but does not join. Join before creating application threads.
void stopStartupClock()
{
    import core.thread : Thread;
    import hunt.util.DateTime : DateTime;
    auto startupThreads = Thread.getAll();
    assert(startupThreads.length <= 2, "review startup ownership if dependencies change");
    DateTime.stopClock();
    foreach (thread; startupThreads)
        if (thread !is Thread.getThis())
        {
            assert(thread.isDaemon);
            thread.join();
        }
}
