#!/usr/bin/env dub
/+ dub.sdl:
    name "vibe_spawn"
    dependency "vibe-core" version="2.14.0"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
import std.algorithm.iteration : splitter;
import std.stdio : writeln;
import vibe.core.core : runTask, setTimer, Timer;
import vibe.core.process : pipeProcess, Redirect;
import vibe.core.stream : IOMode;

void main()
{
    auto pipes = pipeProcess(["sh", "-c", "echo one; echo two; exec sleep 30"], Redirect.stdout);
    bool timedOut = false;
    Timer timer;
    scope(exit) timer.stop();

    // Manual line framing and streaming
    int linesSeen = 0;
    string pending;
    auto reader = runTask(() nothrow {
        try {
            ubyte[128] buf;
            while (!pipes.stdout.empty) {
                const n = pipes.stdout.read(buf[], IOMode.once);
                pending ~= cast(const(char)[]) buf[0 .. n];
                import std.string : indexOf;
                for (auto end = pending.indexOf('\n'); end >= 0; end = pending.indexOf('\n')) {
                    auto line = pending[0 .. end];
                    pending = pending[end + 1 .. $];
                    if (line.length) {
                        assert(line == (linesSeen == 0 ? "one" : "two"));
                        writeln("line: ", line);
                        ++linesSeen;
                        if (linesSeen == 2) timer = setTimer(100.msecs, () nothrow {
                            timedOut = true;
                            try pipes.process.kill(); catch (Exception e) { assert(false, e.msg); }
                        });
                    }
                }
            }
        } catch (Exception e) { assert(false, e.msg); }
    });

    const status = pipes.process.wait();
    reader.join();

    assert(linesSeen == 2);
    assert(pending.length == 0 && status == -15);
    assert(timedOut);
    writeln("exited: timedOut, signaled by 15");
    writeln("end: timedOut, reap: reaped");
}
