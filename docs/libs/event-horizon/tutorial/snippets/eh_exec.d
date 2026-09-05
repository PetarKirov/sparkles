#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_exec"
    dependency "sparkles:event-horizon" path="../../../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import std.stdio : writeln;
import sparkles.event_horizon;

void main()
{
    LoopGroup group;
    if (LoopGroup.start(group).hasError)
        assert(false, "no completion backend");
    scope (exit) group.shutdown();

    auto run = group.run((ref RootScope sc, ref Env env) {
        ref Sched s = currentScheduler();
        ProcessConfig cfg;
        cfg.stderrSpec = StdioSpec(StdioMode.pipe);
        auto got = capture(s, ["sh", "-c", "echo out; echo err >&2; exit 3"], cfg);
        assert(got.hasValue);
        assert(got.value.status.code == 3);
        assert(cast(const(char)[]) got.value.stdout_[] == "out\n");
        assert(cast(const(char)[]) got.value.stderr_[] == "err\n");
        writeln("stdout: ", cast(const(char)[]) got.value.stdout_[]);
        writeln("stderr: ", cast(const(char)[]) got.value.stderr_[]);
        writeln("exit code: ", got.value.status.code);
        return 0;
    });
    assert(run.hasValue);
}
