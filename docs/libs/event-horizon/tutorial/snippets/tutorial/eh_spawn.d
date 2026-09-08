#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_spawn"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : msecs;
import std.stdio : writeln, stderr;
import sparkles.event_horizon;

int main() @system
{
    bool requestedStop, supervisionFailed;
    auto result = runApplication((ref RootScope root, ref Env env) {
        SupervisedProcessConfig config;
        config.terminateGrace = 500.msecs;
        config.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        auto child = supervise(currentScheduler(),
            ["sh", "-c", "echo one; echo two; exec sleep 30"], config,
            null, (in ProcessEvent event) {
                if (event.kind == ProcessEventKind.line)
                {
                    auto line = cast(const(char)[]) event.line.bytes;
                    writeln("line: ", line);
                    if (line == "two") { requestedStop = true; root.cancel(); }
                }
                else if (event.kind == ProcessEventKind.exited)
                    writeln("exited: ", event.end, ", signaled by ",
                        event.status.signaled ? event.status.code : 0);
            });
        if (child.hasError) { supervisionFailed = true; return ioErr!void(child.error); }
        writeln("end: ", child.value.end, ", reap: ", child.value.reap);
        return ioOk();
    });
    // This example deliberately cancels its root after the second line.
    if (!result.hasError || (requestedStop && !supervisionFailed
        && result.error.kind == Cause!IoError.Kind.interrupt
        && result.error.interrupt.kind == InterruptKind.cancelled)) return 0;
    stderr.writeln(result.error);
    return 1;
}
