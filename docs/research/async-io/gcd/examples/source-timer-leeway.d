#!/usr/bin/env dub
/+ dub.sdl:
    name "gcd_source_timer_leeway"
    platforms "osx"
    targetPath "build"
+/
/**
 * GCD — timers are a source type, and `leeway` is a first-class parameter.
 *
 * `dispatch_source_set_timer(source, start, interval, leeway)` has no
 * equivalent in `timerfd`, `setitimer` or `EVFILT_TIMER` as most loops use it:
 * the fourth argument tells the kernel how much *later* than the deadline the
 * timer may fire, so unrelated timers across the whole system coalesce into one
 * wakeup. It lowers to kqueue's `NOTE_LEEWAY` (`DISPATCH_HAVE_TIMER_COALESCING`
 * in `src/event/event_config.h`); libdispatch clamps a leeway larger than half
 * the interval down to `interval / 2` (`_dispatch_timer_config_create`,
 * `src/source.c`).
 *
 * A leeway is a licence to be late, never to be early. This program arms a
 * repeating timer with a leeway equal to half its interval, records the arrival
 * time of each of five fires, and asserts that no fire landed before its
 * nominal deadline.
 *
 * Companion to the GCD deep-dive:
 * see docs/research/async-io/gcd/index.md § "Timers, leeway and coalescing".
 *
 * Run with: `dub run --single source-timer-leeway.d`
 *
 * Portability: macOS only (`platforms "osx"`).
 */
module gcd_source_timer_leeway;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.stdc.stdint : uintptr_t;
import core.time : MonoTime, msecs, nsecs;

import std.stdio : writefln, writeln;

alias dispatch_queue_t = void*;
alias dispatch_source_t = void*;
alias dispatch_semaphore_t = void*;
alias dispatch_function_t = extern (C) void function(void*) nothrow;

extern (C) nothrow @nogc
{
    /// `DISPATCH_SOURCE_TYPE_TIMER` is `&_dispatch_source_type_timer`.
    extern __gshared const ubyte _dispatch_source_type_timer;

    dispatch_queue_t dispatch_queue_create(const(char)* label, void* attr);
    dispatch_source_t dispatch_source_create(const(void)* type, uintptr_t handle,
        uintptr_t mask, dispatch_queue_t queue);
    void dispatch_source_set_timer(dispatch_source_t source, ulong start,
        ulong interval, ulong leeway);
    void dispatch_source_set_event_handler_f(dispatch_source_t source, dispatch_function_t handler);
    void dispatch_source_set_cancel_handler_f(dispatch_source_t source, dispatch_function_t handler);
    void dispatch_source_cancel(dispatch_source_t source);
    void dispatch_resume(void* object);
    void dispatch_release(void* object);
    ulong dispatch_time(ulong when, long delta);
    dispatch_semaphore_t dispatch_semaphore_create(long value);
    long dispatch_semaphore_wait(dispatch_semaphore_t sema, ulong timeout);
    long dispatch_semaphore_signal(dispatch_semaphore_t sema);
}

enum DISPATCH_TIME_NOW = 0UL;
enum DISPATCH_TIME_FOREVER = ~0UL;

enum intervalMs = 20;
enum fireBudget = 5;

struct Timer
{
    dispatch_source_t source;
    dispatch_semaphore_t finished;
    MonoTime armedAt;
    shared int fires;
    shared long[fireBudget] arrivalsUsecs;
}

__gshared Timer timer;

extern (C) void onFire(void* context) nothrow
{
    const elapsed = MonoTime.currTime - timer.armedAt;
    const n = atomicOp!"+="(timer.fires, 1);
    if (n <= fireBudget)
        atomicStore(timer.arrivalsUsecs[n - 1], elapsed.total!"usecs");
    if (n >= fireBudget)
        dispatch_source_cancel(timer.source);
}

extern (C) void onCancel(void* context) nothrow
{
    dispatch_semaphore_signal(timer.finished);
}

int main()
{
    auto queue = dispatch_queue_create("dev.sparkles.research.gcd.timer", null);
    scope (exit)
        dispatch_release(queue);

    timer.finished = dispatch_semaphore_create(0);
    timer.source = dispatch_source_create(&_dispatch_source_type_timer, 0, 0, queue);
    dispatch_source_set_event_handler_f(timer.source, &onFire);
    dispatch_source_set_cancel_handler_f(timer.source, &onCancel);

    const intervalNs = intervalMs * 1_000_000L;
    // Leeway == interval / 2 is the largest value libdispatch will honour for
    // this interval; anything bigger is clamped to exactly this.
    const leewayNs = intervalNs / 2;

    timer.armedAt = MonoTime.currTime;
    dispatch_source_set_timer(timer.source, dispatch_time(DISPATCH_TIME_NOW, intervalNs),
        intervalNs, leewayNs);
    dispatch_resume(timer.source);

    dispatch_semaphore_wait(timer.finished, DISPATCH_TIME_FOREVER);
    dispatch_release(timer.source);

    writefln("interval = %d ms, leeway = %d ms", intervalMs, leewayNs / 1_000_000);
    writeln();
    writeln("fire  deadline (ms)  arrival (ms)  lateness (ms)");
    foreach (i; 0 .. fireBudget)
    {
        const deadlineMs = (i + 1) * intervalMs;
        const arrivalMs = atomicLoad(timer.arrivalsUsecs[i]) / 1000.0;
        writefln("%4d  %13d  %12.1f  %13.1f", i + 1, deadlineMs, arrivalMs,
            arrivalMs - deadlineMs);

        // The contract: a leeway lets the kernel fire late, never early. A
        // 1 ms slack absorbs the clock read inside the handler itself.
        assert(arrivalMs + 1.0 >= deadlineMs, "timer fired before its deadline");
    }

    assert(atomicLoad(timer.fires) >= fireBudget, "timer under-delivered");
    writeln();
    writeln("leeway buys coalescing with other timers; it never moves a deadline earlier");
    return 0;
}
