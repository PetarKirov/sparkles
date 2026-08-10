#!/usr/bin/env dub
/+ dub.sdl:
    name "gcd_target_queue_funnel"
    platforms "osx"
    targetPath "build"
+/
/**
 * GCD — target queues: mutual exclusion without a lock, composed at run time.
 *
 * Every dispatch object has a *target queue*. A queue you create owns no
 * threads; it is a lane that re-enqueues its work onto its target, and only the
 * root queue at the bottom of the chain is backed by the kernel's workqueue.
 * Retargeting several serial queues onto one serial queue therefore funnels
 * them into a single execution context — the subsystem-wide mutual exclusion
 * Apple recommends in place of a shared lock, with no lock ever taken.
 *
 * This program runs the same workload twice: three serial queues targeting the
 * default root queue (free to run concurrently), and the same three retargeted
 * onto one funnel queue. It measures the peak observed concurrency in each case
 * and asserts that the funnelled run never exceeds one, and that a
 * deliberately unsynchronised counter is exact under the funnel.
 *
 * Companion to the GCD deep-dive:
 * see docs/research/async-io/gcd/index.md § "Target queues: the hierarchy is the design".
 *
 * Run with: `dub run --single target-queue-funnel.d`
 *
 * Portability: macOS only (`platforms "osx"`).
 */
module gcd_target_queue_funnel;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.stdc.stdint : intptr_t, uintptr_t;

import std.stdio : writefln, writeln;

alias dispatch_queue_t = void*;
alias dispatch_group_t = void*;
alias dispatch_function_t = extern (C) void function(void*) nothrow;

extern (C) nothrow @nogc
{
    dispatch_queue_t dispatch_queue_create(const(char)* label, void* attr);
    dispatch_queue_t dispatch_get_global_queue(intptr_t identifier, uintptr_t flags);
    void dispatch_set_target_queue(void* object, dispatch_queue_t queue);
    dispatch_group_t dispatch_group_create();
    void dispatch_group_async_f(dispatch_group_t group, dispatch_queue_t queue,
        void* context, dispatch_function_t work);
    long dispatch_group_wait(dispatch_group_t group, ulong timeout);
    void dispatch_release(void* object);
}

enum DISPATCH_TIME_FOREVER = ~0UL;
enum QOS_CLASS_DEFAULT = 0x15;

enum laneCount = 3;
enum itemsPerLane = 200;

struct Run
{
    shared int inFlight;
    shared int peakInFlight;
    /// Deliberately not atomic: it is exact only if the work is serialised.
    int unguardedCounter;
}

__gshared Run run;

extern (C) void workItem(void* context) nothrow
{
    const now = atomicOp!"+="(run.inFlight, 1);

    // Track the high-water mark of simultaneous executions.
    for (;;)
    {
        const peak = atomicLoad(run.peakInFlight);
        if (now <= peak)
            break;
        import core.atomic : cas;

        if (cas(&run.peakInFlight, peak, now))
            break;
    }

    // A read-modify-write with no synchronisation of its own. Under a funnel it
    // is exact; run concurrently it loses updates.
    const scratch = run.unguardedCounter;
    run.unguardedCounter = scratch + 1;

    atomicOp!"-="(run.inFlight, 1);
}

/// Runs `laneCount * itemsPerLane` items across `lanes`, returning the peak
/// observed concurrency and the value the unguarded counter reached.
auto measure(dispatch_queue_t[] lanes)
{
    atomicStore(run.inFlight, 0);
    atomicStore(run.peakInFlight, 0);
    run.unguardedCounter = 0;

    auto group = dispatch_group_create();
    scope (exit)
        dispatch_release(group);

    foreach (item; 0 .. itemsPerLane)
        foreach (lane; lanes)
            dispatch_group_async_f(group, lane, null, &workItem);

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    struct Result
    {
        int peak;
        int counter;
    }

    return Result(atomicLoad(run.peakInFlight), run.unguardedCounter);
}

int main()
{
    dispatch_queue_t[laneCount] lanes;
    static immutable string[laneCount] labels = [
        "dev.sparkles.research.gcd.lane.0\0",
        "dev.sparkles.research.gcd.lane.1\0",
        "dev.sparkles.research.gcd.lane.2\0",
    ];
    foreach (i, ref lane; lanes)
        lane = dispatch_queue_create(labels[i].ptr, null);
    scope (exit)
        foreach (lane; lanes)
            dispatch_release(lane);

    const expected = laneCount * itemsPerLane;

    // 1. Default targeting: each lane is serial with respect to itself, but the
    //    three lanes reach the root queue independently.
    const independent = measure(lanes[]);
    writefln("three independent serial queues: peak concurrency = %d, counter = %d/%d",
        independent.peak, independent.counter, expected);

    // 2. Funnel them: one serial queue becomes the target of all three.
    auto funnel = dispatch_queue_create("dev.sparkles.research.gcd.funnel", null);
    scope (exit)
        dispatch_release(funnel);
    dispatch_set_target_queue(funnel, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
    foreach (lane; lanes)
        dispatch_set_target_queue(lane, funnel);

    const funnelled = measure(lanes[]);
    writefln("the same three, retargeted to one: peak concurrency = %d, counter = %d/%d",
        funnelled.peak, funnelled.counter, expected);

    assert(funnelled.peak == 1, "the funnel queue did not serialise its lanes");
    assert(funnelled.counter == expected, "an unsynchronised counter lost updates under the funnel");
    assert(independent.peak >= 1, "no work ran");

    writeln();
    if (independent.peak > funnelled.peak)
        writeln("retargeting alone converted three concurrent lanes into one serial context");
    else
        writeln("this host never overlapped the independent lanes; the funnel guarantee still holds");
    return 0;
}
