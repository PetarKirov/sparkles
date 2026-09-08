#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_callback_timers"
    dependency "sparkles:event-horizon" path="../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
@system:
import core.time : msecs;
import std.stdio : writeln;
import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op : Completion;

struct State
{
    DefaultLoop* loop;
    int ticks;
    int[3] deliveries;
}

void tick(void* context, ref Completion done) nothrow @nogc
{
    auto state = cast(State*) context;
    assert(done.isFinal && done.res == 0);
    state.deliveries[state.ticks] = state.ticks + 1;
    if (++state.ticks < 3)
        assert(state.loop.submitAfter(10.msecs, &tick, context).hasValue);
}

void main()
{
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop).hasError, "no completion backend");
    scope(exit) loop.destroy();
    State state = State(&loop);
    assert(loop.submitAfter(10.msecs, &tick, &state).hasValue);
    // State stays alive until every submitted callback has been dispatched.
    assert(!loop.run().hasError);
    assert(loop.inFlight == 0 && state.ticks == 3);
    assert(state.deliveries[] == [1, 2, 3]);
    foreach (number; state.deliveries) writeln("tick ", number);
}
