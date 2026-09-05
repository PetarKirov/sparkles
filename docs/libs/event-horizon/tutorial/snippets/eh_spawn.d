#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_spawn"
    dependency "sparkles:event-horizon" path="../../../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.time : msecs;
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
        SupervisedProcessConfig cfg;
        cfg.timeout = 100.msecs; // TERM at 100 ms …
        cfg.terminateGrace = 500.msecs; // … KILL 500 ms later if still alive
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        int linesSeen;
        auto got = supervise(s, ["sh", "-c", "echo one; echo two; sleep 30"], cfg,
            null, (in ProcessEvent ev) {
                final switch (ev.kind)
                {
                case ProcessEventKind.line:
                    writeln("line: ", cast(const(char)[]) ev.line.bytes);
                    ++linesSeen;
                    break;
                case ProcessEventKind.exited:
                    writeln("exited: ", ev.end, ", signaled by ",
                        ev.status.signaled ? ev.status.code : 0);
                    break;
                case ProcessEventKind.sample:
                    break; // periodic resource samples; not printed here
                }
            });
        assert(got.hasValue);
        assert(linesSeen == 2);
        assert(got.value.end == ProcessEnd.timedOut);
        writeln("end: ", got.value.end, ", reap: ", got.value.reap);
        return 0;
    });
    assert(run.hasValue);
}
