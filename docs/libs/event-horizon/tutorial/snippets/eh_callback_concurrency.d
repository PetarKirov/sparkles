#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_callback_concurrency"
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

struct State { uint completed; int[2] results; }
struct Child { State* owner; size_t index; }

void completed(void* context, ref Completion done) nothrow @nogc
{
    auto child = cast(Child*) context;
    assert(done.res == 0 && done.isFinal);
    assert(child.owner.results[child.index] == 0);
    child.owner.results[child.index] = cast(int) child.index + 1;
    ++child.owner.completed;
}

void main()
{
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop).hasError, "no completion backend");
    scope(exit) loop.destroy();
    State state;
    Child[2] children = [Child(&state, 0), Child(&state, 1)];
    foreach (ref child; children)
        assert(loop.submitAfter(10.msecs, &completed, &child).hasValue);
    assert(state.completed == 0 && loop.inFlight == 2);
    assert(!loop.run().hasError);
    assert(loop.inFlight == 0 && state.completed == 2);
    assert(state.results[] == [1, 2]);
    // Explicit fan-in, not a structured child scope or CPU parallelism.
    writeln("joined: ", state.results[0] * 10 + state.results[1]);
}
