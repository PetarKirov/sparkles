#!/usr/bin/env dub
/+ dub.sdl:
name "blocking-pool-bench"
targetPath "build"
dependency "sparkles:event-horizon" path="../../.."
buildType "checked" {
    buildOptions "optimize" "inline" "debugInfo"
}
+/
/** Sequential scheduler → worker → scheduler completion latency. */
module blocking_pool_bench;

import core.time : MonoTime;

import std.stdio : writefln;

import sparkles.event_horizon.blocking_pool : BlockingPool;
import sparkles.event_horizon.sched : Sched;

private void increment(void* context) @system nothrow
{
    ++*cast(uint*) context;
}

void main() @system
{
    foreach (rep; 0 .. 5)
    {
        Sched s;
        assert(!Sched.create(s).hasError);
        BlockingPool pool;
        assert(!BlockingPool.create(pool, workers: 1, queueCapacity: 64).hasError);
        scope (exit) cast(void) pool.shutdown();

        uint calls;
        const start = MonoTime.currTime;
        assert(!s.run(() {
            foreach (_; 0 .. 10_000)
                assert(!pool.run(s, &increment, &calls).hasError);
        }).hasError);
        const elapsed = MonoTime.currTime - start;
        assert(calls == 10_000);
        writefln("rep=%s calls=%s ns/call=%s", rep, calls, elapsed.total!"nsecs" / calls);
    }
}
