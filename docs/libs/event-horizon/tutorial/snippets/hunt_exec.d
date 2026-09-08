#!/usr/bin/env dub
/+ dub.sdl:
    name "hunt_exec"
    dependency "hunt-net" version="0.7.1"
    dependency "hunt" path=".deps/hunt"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/

import std.stdio : writeln;
import std.process : pipeProcess, Redirect, wait;
import core.thread : Thread;

void main()
{
    stopStartupClock();
    runWorker({
        auto child = pipeProcess(["sh", "-c", "echo out; echo err >&2; exit 3"], Redirect.stdout | Redirect.stderr);
        string stdoutText, stderrText;
        auto drainError = new Thread({
            foreach (chunk; child.stderr.byChunk(1024)) stderrText ~= cast(const(char)[]) chunk;
            child.stderr.close();
        });
        drainError.start();
        foreach (chunk; child.stdout.byChunk(1024)) stdoutText ~= cast(const(char)[]) chunk;
        child.stdout.close();
        const code = child.pid.wait();
        drainError.join();
        assert(stdoutText == "out\n" && stderrText == "err\n" && code == 3);
        writeln("stdout: ", stdoutText);
        writeln("stderr: ", stderrText);
        writeln("exit code: ", code);
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
