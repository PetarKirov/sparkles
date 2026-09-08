#!/usr/bin/env dub
/+ dub.sdl:
    name "eh_callback_deadline"
    dependency "sparkles:event-horizon" path="../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
@system:
import core.time : msecs, seconds;
import core.stdc.errno : ECANCELED;
import std.stdio : writeln;
import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op : Completion, OpHandle;

struct State
{
    DefaultLoop* loop;
    OpHandle operation;
    bool deadlineFired, terminalSeen, cleaned;
}

void cleaned(void* context, ref Completion done) nothrow @nogc
{
    auto state = cast(State*) context;
    assert(done.res == 0 && state.terminalSeen);
    state.cleaned = true;
}

void interrupted(void* context, ref Completion done) nothrow @nogc
{
    auto state = cast(State*) context;
    assert(done.isFinal && done.res == -ECANCELED);
    assert(state.deadlineFired && !state.terminalSeen);
    state.terminalSeen = true;
    assert(state.loop.submitAfter(5.msecs, &cleaned, context).hasValue);
}

void deadline(void* context, ref Completion done) nothrow @nogc
{
    auto state = cast(State*) context;
    assert(done.res == 0 && !state.terminalSeen);
    state.deadlineFired = true;
    assert(!state.loop.cancel(state.operation).hasError);
    // cancel() is not completion: context and buffers must remain alive.
    assert(!state.terminalSeen && !state.cleaned);
}

void main()
{
    DefaultLoop loop;
    assert(!DefaultLoop.create(loop).hasError, "no completion backend");
    scope(exit) loop.destroy();
    State state = State(&loop);
    auto operation = loop.submitAfter(10.seconds, &interrupted, &state);
    assert(operation.hasValue);
    state.operation = operation.value;
    assert(loop.submitAfter(50.msecs, &deadline, &state).hasValue);
    assert(!loop.run().hasError);
    assert(loop.inFlight == 0 && state.terminalSeen && state.cleaned);
    writeln("sleep returned: ECANCELED");
    writeln("timed out: ", state.deadlineFired);
    writeln("cleaned up: ", state.cleaned);
}
