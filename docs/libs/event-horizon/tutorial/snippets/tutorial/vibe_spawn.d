#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_vibe_spawn"
    dependency "vibe-core" version="2.14.0"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : seconds;
import std.stdio : writeln;
import std.string : indexOf;
import vibe.core.concurrency : async;
import vibe.core.process : pipeProcess, Redirect;
import vibe.core.stream : IOMode;

void main() @system
{
    auto pipes = pipeProcess(["sh", "-c", "echo one; echo two; exec sleep 30"], Redirect.stdout);
    auto reader = async({
        string pending;
        ubyte[128] bytes;
        while (!pipes.stdout.empty)
        {
            pending ~= cast(const(char)[]) bytes[0 .. pipes.stdout.read(bytes[], IOMode.once)];
            for (auto end = pending.indexOf('\n'); end >= 0; end = pending.indexOf('\n'))
            {
                const line = pending[0 .. end];
                writeln("line: ", line);
                if (line == "two") pipes.process.kill(); // TERM after readiness.
                pending = pending[end + 1 .. $];
            }
        }
        if (pending.length) writeln("line: ", pending);
        return 0;
    });
    const status = pipes.process.waitOrForceKill(5.seconds); // Bounded root wait.
    reader.getResult();
    writeln("exited: signaled by ", status < 0 ? -status : 0);
    writeln("end: stopped, reap: reaped");
}
