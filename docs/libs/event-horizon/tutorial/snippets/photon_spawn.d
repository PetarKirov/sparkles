#!/usr/bin/env dub
/+ dub.sdl:
    name "photon_spawn"
    dependency "photon" version="0.19.3"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.sys.posix.signal : SIGTERM, kill;
import core.time : msecs;
import std.process : Config, pipeProcess, Redirect, wait;
import std.stdio : writeln;
import photon;

void main()
{
    initPhoton();

    go({
        // Photon lacks native process supervision. Streaming output and enforcing timeouts
        // require manual pipes and auxiliary watchdog threads offloaded from the scheduler.
        auto res = offload({
            auto pipes = pipeProcess(["sh", "-c", "echo one; echo two; exec sleep 30"], Redirect.stdout);

            import core.thread : Thread;

            string[] lines;
            foreach (line; pipes.stdout.byLine)
            {
                writeln("line: ", line);
                lines ~= line.idup;
                if (lines.length == 2) assert(kill(pipes.pid.osHandle, SIGTERM) == 0);
            }
            int code = wait(pipes.pid);
            assert(code == -SIGTERM);
            assert(lines == ["one", "two"]);
            return lines;
        });

        assert(res.length == 2);
        writeln("exited: SIGTERM");
        writeln("end: reaped");
    });

    runScheduler();
}
