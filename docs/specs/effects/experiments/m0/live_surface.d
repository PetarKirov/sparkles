#!/usr/bin/env dub
/+ dub.sdl:
    name "effects-m0-live-surface"
    dependency "sparkles:event-horizon" path="../../../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// Type-check only: never creates a scheduler or invokes a host process.
import sparkles.event_horizon.sched : Sched;
import sparkles.event_horizon.supervise : supervise;
import std.traits : functionAttributes;
import std.stdio : writeln;

enum ordinaryCall = __traits(compiles, (ref Sched sched) {
    auto result = supervise(sched, ["true"]);
});
enum noThrowCall = __traits(compiles, (ref Sched sched) nothrow {
    auto result = supervise(sched, ["true"]);
});
enum noGcCall = __traits(compiles, (ref Sched sched) @nogc {
    auto result = supervise(sched, ["true"]);
});
enum safeCall = __traits(compiles, (ref Sched sched) @safe {
    auto result = supervise(sched, ["true"]);
});

static assert(ordinaryCall);
static assert(!noThrowCall && !noGcCall && !safeCall);

void main()
{
    writeln("supervise: ordinary=", ordinaryCall, " nothrow=", noThrowCall,
        " nogc=", noGcCall, " safe=", safeCall);
    writeln("attributes=", functionAttributes!supervise);
}
