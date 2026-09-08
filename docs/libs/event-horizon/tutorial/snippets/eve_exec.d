#!/usr/bin/env dub
/+ dub.sdl:
    name "eve_exec"
    dependency "eve" repository="git+https://codeberg.org/ddn/eve.git" version="c72f75135de636987e91bcd8ec5a22d32d34a197"
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
