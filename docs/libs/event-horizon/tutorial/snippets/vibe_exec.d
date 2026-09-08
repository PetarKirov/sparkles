#!/usr/bin/env dub
/+ dub.sdl:
    name "vibe_exec"
    dependency "vibe-core" version="2.14.0"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.array : appender;
import std.stdio : writeln;
import vibe.core.core : runTask;
import vibe.core.process : pipeProcess, Redirect;
import vibe.core.stream : IOMode;

void main()
{
    auto pipes = pipeProcess(["sh", "-c", "echo out; echo err >&2; exit 3"], Redirect.all);

    auto outBuf = appender!string;
    auto errBuf = appender!string;

    // Must drain stdout and stderr concurrently to prevent pipe buffer deadlocks
    auto tOut = runTask(() nothrow {
        try {
            ubyte[128] buf;
            while (!pipes.stdout.empty) {
                const n = pipes.stdout.read(buf[], IOMode.once);
                outBuf.put(cast(const(char)[]) buf[0 .. n]);
            }
        } catch (Exception error) { assert(false, error.msg); }
    });

    auto tErr = runTask(() nothrow {
        try {
            ubyte[128] buf;
            while (!pipes.stderr.empty) {
                const n = pipes.stderr.read(buf[], IOMode.once);
                errBuf.put(cast(const(char)[]) buf[0 .. n]);
            }
        } catch (Exception error) { assert(false, error.msg); }
    });

    const status = pipes.process.wait();
    tOut.join();
    tErr.join();

    assert(status == 3);
    assert(outBuf.data == "out\n");
    assert(errBuf.data == "err\n");

    writeln("stdout: ", outBuf.data);
    writeln("stderr: ", errBuf.data);
    writeln("exit code: ", status);
}
