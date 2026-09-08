#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_callback_retry"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : msecs;
import core.stdc.errno : EAGAIN;
import std.stdio : writeln, stderr;
import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op : Completion;
import sparkles.event_horizon.errors : IoResult, OpKind, ioOk, ioErr;

struct State { DefaultLoop* loop; int attempts, error; bool stopping; }
IoResult!int request(int attempt) @safe nothrow @nogc
    => attempt < 3 ? ioErr!int(EAGAIN, OpKind.none) : ioOk(42);

void attempt(ref State state, ref Completion done) nothrow @nogc
{
    if (state.stopping) return;
    if (done.res < 0) { state.error = done.res; return; }
    auto result = request(++state.attempts);
    if (!result.hasError) return;
    if (result.error.errnoValue != EAGAIN || state.attempts >= 5)
    { state.error = -result.error.errnoValue; return; }
    auto timer = state.loop.submitAfter!attempt((5 << (state.attempts - 1)).msecs, state);
    if (timer.hasError) state.error = -timer.error.errnoValue;
}

int main() @system
{
    State state;
    DefaultLoop loop;
    auto started = DefaultLoop.create(loop);
    if (started.hasError) { stderr.writeln(started.error); return 1; }
    scope(exit) { state.stopping = true; loop.destroy(); }
    state.loop = &loop;
    auto first = loop.submitAfter!attempt(0.msecs, state);
    if (first.hasError) { stderr.writeln(first.error); return 1; }
    auto ran = loop.run();
    if (ran.hasError) { stderr.writeln(ran.error); return 1; }
    if (state.error) { stderr.writeln("request failed: ", state.error); return 1; }
    writeln("succeeded on attempt ", state.attempts);
    return 0;
}
