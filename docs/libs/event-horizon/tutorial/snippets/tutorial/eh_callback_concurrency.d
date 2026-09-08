#!/usr/bin/env dub
/+ dub.sdl:
    name "tutorial_eh_callback_concurrency"
    dependency "sparkles:event-horizon" path="../../../../../.."
    platforms "linux"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import core.time : msecs;
import std.stdio : writeln, stderr;
import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op : Completion;

struct Job { int input, result, error; }
void completed(ref Job job, ref Completion done) nothrow @nogc
{
    if (done.res < 0) job.error = done.res;
    else job.result = job.input;
}

int main() @system
{
    Job[2] jobs = [Job(1), Job(2)]; // Outlive the loop and all its callbacks.
    DefaultLoop loop;
    auto started = DefaultLoop.create(loop);
    if (started.hasError) { stderr.writeln(started.error); return 1; }
    scope(exit) loop.destroy();
    foreach (ref job; jobs)
    {
        auto armed = loop.submitAfter!completed(10.msecs, job);
        if (armed.hasError) { stderr.writeln(armed.error); return 1; }
    }
    auto ran = loop.run(); // Explicit fan-in; not a structured fiber scope.
    if (ran.hasError) { stderr.writeln(ran.error); return 1; }
    foreach (job; jobs)
        if (job.error) { stderr.writeln("timer failed: ", job.error); return 1; }
    writeln("joined: ", jobs[0].result * 10 + jobs[1].result);
    return 0;
}
