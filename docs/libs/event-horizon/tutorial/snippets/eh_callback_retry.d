#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_callback_retry"
    dependency "sparkles:event-horizon" path="../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
@system:
import core.time : msecs;
import core.stdc.errno : EAGAIN;
import std.stdio : writeln;
import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op : Completion;

struct State { DefaultLoop* loop; int attempts, failures, value; }

// Deterministic dependency failure, independent of timer scheduling jitter.
int tryOperation(int attempt, out int value) @safe nothrow @nogc
{
    if (attempt < 3) return EAGAIN;
    value = 42;
    return 0;
}

void attempt(void* context, ref Completion done) nothrow @nogc
{
    assert(done.res == 0);
    auto state = cast(State*) context;
    auto error = tryOperation(++state.attempts, state.value);
    if (!error) return;
    assert(error == EAGAIN && state.attempts < 5);
    ++state.failures;
    assert(state.loop.submitAfter((5 << (state.attempts - 1)).msecs,
        &attempt, context).hasValue);
}

void main()
{
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop).hasError, "no completion backend");
    scope(exit) loop.destroy();
    State state = State(&loop);
    assert(loop.submitAfter(0.msecs, &attempt, &state).hasValue);
    assert(!loop.run().hasError);
    assert(loop.inFlight == 0 && state.attempts == 3);
    assert(state.failures == 2 && state.value == 42);
    writeln("succeeded on attempt ", state.attempts);
}
