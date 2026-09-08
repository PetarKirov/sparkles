#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_exec"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writeln, stderr;
import sparkles.event_horizon;

int main() @system
{
    auto result = runApplication((ref RootScope root, ref Env env) {
        ProcessConfig config;
        config.stderrSpec = StdioSpec(StdioMode.pipe);
        auto captured = capture(currentScheduler(),
            ["sh", "-c", "echo out; echo err >&2; exit 3"], config);
        if (captured.hasError) return ioErr!void(captured.error);
        writeln("stdout: ", cast(const(char)[]) captured.value.stdout_[]);
        writeln("stderr: ", cast(const(char)[]) captured.value.stderr_[]);
        writeln("exit code: ", captured.value.status.code); // Nonzero exit is data.
        return ioOk();
    });
    if (result.hasError) stderr.writeln(result.error);
    return result.hasError ? 1 : 0;
}
