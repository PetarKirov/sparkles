#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_vibe_exec"
    dependency "vibe-core" version="2.14.0"
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : seconds;
import std.stdio : writeln;
import vibe.core.concurrency : async;
import vibe.core.process : pipeProcess, Redirect;
import vibe.core.stream : IOMode;

string drain(Stream)(Stream stream)
{
    string text;
    ubyte[1024] bytes;
    while (!stream.empty)
        text ~= cast(const(char)[]) bytes[0 .. stream.read(bytes[], IOMode.once)];
    return text;
}
void main() @system
{
    auto pipes = pipeProcess(["sh", "-c", "echo out; echo err >&2; exit 3"], Redirect.all);
    pipes.stdin.close();
    auto stdout = async(() => drain(pipes.stdout));
    auto stderr = async(() => drain(pipes.stderr));
    const status = pipes.process.waitOrForceKill(5.seconds);
    stdout.task.join();
    stderr.task.join(); // Both streams must drain concurrently.
    writeln("stdout: ", stdout.getResult());
    writeln("stderr: ", stderr.getResult());
    writeln("exit code: ", status);
}
