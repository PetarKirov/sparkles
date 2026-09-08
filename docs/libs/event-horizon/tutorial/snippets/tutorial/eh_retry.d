#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_retry"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : msecs;
import core.stdc.errno : EAGAIN;
import std.stdio : writeln, stderr;
import sparkles.event_horizon;

int main() @system
{
    auto result = runApplication((ref RootScope root, ref Env env) {
        int attempts;
        enum policy = exponential(5.msecs) & recurs(4);
        auto tried = retry(root, env.clock, policy, () {
            if (++attempts < 3) return ioErr!int(EAGAIN, OpKind.none);
            return ioOk(attempts);
        });
        if (tried.hasError) root.fail(tried.error);
        else writeln("succeeded on attempt ", tried.value);
        return ioOk();
    });
    if (result.hasError) stderr.writeln(result.error);
    return result.hasError ? 1 : 0;
}
