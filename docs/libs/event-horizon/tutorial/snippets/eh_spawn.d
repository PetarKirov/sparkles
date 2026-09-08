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
        cfg.terminateGrace = 500.msecs; // cancellation: TERM, then bounded KILL grace
        cfg.process.stdinSpec = StdioSpec(StdioMode.nullDev);
        int linesSeen;
        SupervisedProcessResult result;
        bool returned;
        auto scopeResult = withScope!((ref outer) {
            JoinHandle!void task;
            outer.fork(task, () {
                auto got = supervise(s, ["sh", "-c", "echo one; echo two; exec sleep 30"], cfg,
                    null, (in ProcessEvent ev) {
                        final switch (ev.kind)
                        {
                        case ProcessEventKind.line:
                            assert(cast(const(char)[]) ev.line.bytes == (linesSeen == 0 ? "one" : "two"));
                            writeln("line: ", cast(const(char)[]) ev.line.bytes);
                            ++linesSeen;
                            if (linesSeen == 2) outer.cancel(); // readiness handshake, no startup-time race
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
                result = got.value;
                returned = true;
                return ioOk();
            });
            task.join(s);
        })(s);
        assert(!scopeResult.hasError && returned);
        assert(linesSeen == 2);
        assert(result.end == ProcessEnd.cancelled);
        assert(result.reap == ReapOutcome.reaped);
        assert(result.status.signaled && result.status.code == 15);
        assert(!result.eofForced);
        writeln("end: ", result.end, ", reap: ", result.reap);
        return 0;
    });
    assert(run.hasValue);
}
