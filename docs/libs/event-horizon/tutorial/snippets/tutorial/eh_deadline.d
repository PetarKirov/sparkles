#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_deadline"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : msecs, seconds;
import core.stdc.errno : ECANCELED;
import std.stdio : writeln, stderr;
import sparkles.event_horizon;

int main() @system
{
    auto result = runApplication((ref RootScope root, ref Env env) {
        ref scheduler = currentScheduler();
        bool cleaned;
        auto timed = withDeadline!((ref scope_) {
            auto slept = env.clock.sleep(10.seconds);
            if (slept.hasError && slept.error.errnoValue != ECANCELED)
                scope_.fail(Cause!IoError.fromFailure(slept.error));
            writeln("sleep returned: ", slept.hasError ? "ECANCELED" : "ok");
            // Cleanup is allowed to finish even with cancellation latched.
            auto cleanup = protect!(() => env.clock.sleep(5.msecs))(scheduler);
            cleaned = !cleanup.hasError;
            if (cleanup.hasError) scope_.fail(Cause!IoError.fromFailure(cleanup.error));
        })(scheduler, 50.msecs);
        if (timed.hasError && !timed.error.isTimeout) root.fail(timed.error);
        writeln("timed out: ", timed.hasError && timed.error.isTimeout);
        writeln("cleaned up: ", cleaned);
        return ioOk();
    });
    if (result.hasError) stderr.writeln(result.error);
    return result.hasError ? 1 : 0;
}
