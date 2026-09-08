#!/usr/bin/env dub
/+ dub.sdl:
    name "photon_exec"
    dependency "photon" version="0.19.3"
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
    import photon;
    initPhoton();
    bool finished;
    go({ offload({ work(); return 0; }); finished = true; });
    runScheduler();
    assert(finished);
}
