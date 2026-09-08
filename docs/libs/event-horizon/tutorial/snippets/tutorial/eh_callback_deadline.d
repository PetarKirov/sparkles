#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_callback_deadline"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : msecs, seconds;
import core.stdc.errno : ECANCELED;
import std.stdio : writeln, stderr;
import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op : Completion, OpHandle;

struct State
{
    DefaultLoop* loop;
    OpHandle operation;
    bool timedOut, finished, cleaned, stopping;
    int result, error;
}
void cleaned(ref State state, ref Completion done) nothrow @nogc
{
    if (done.res < 0) state.error = done.res;
    else state.cleaned = true;
}
void finished(ref State state, ref Completion done) nothrow @nogc
{
    if (state.stopping) return;
    state.finished = true;
    state.result = done.res;
    // Cleanup starts only after terminal completion, not after cancel().
    auto armed = state.loop.submitAfter!cleaned(5.msecs, state);
    if (armed.hasError) state.error = -armed.error.errnoValue;
}
void deadline(ref State state, ref Completion done) nothrow @nogc
{
    if (state.stopping) return;
    if (done.res < 0) { state.error = done.res; return; }
    if (state.finished) return;
    state.timedOut = true;
    auto cancelled = state.loop.cancel(state.operation);
    if (cancelled.hasError) state.error = -cancelled.error.errnoValue;
}

int main() @system
{
    State state;
    DefaultLoop loop;
    auto started = DefaultLoop.create(loop);
    if (started.hasError) { stderr.writeln(started.error); return 1; }
    scope(exit) { state.stopping = true; loop.destroy(); }
    state.loop = &loop;
    auto work = loop.submitAfter!finished(10.seconds, state);
    if (work.hasError) { stderr.writeln(work.error); return 1; }
    state.operation = work.value;
    auto timer = loop.submitAfter!deadline(50.msecs, state);
    if (timer.hasError) { stderr.writeln(timer.error); return 1; }
    auto ran = loop.run();
    if (ran.hasError) { stderr.writeln(ran.error); return 1; }
    if (state.error || (state.result < 0 && state.result != -ECANCELED))
    { stderr.writeln("operation failed: ", state.error, " / ", state.result); return 1; }
    writeln("sleep returned: ", state.result == -ECANCELED ? "ECANCELED" : "ok");
    writeln("timed out: ", state.timedOut);
    writeln("cleaned up: ", state.cleaned);
    return 0;
}
