#!/usr/bin/env dub
/+ dub.sdl:
    name "gcd_sync_on_caller_thread"
    platforms "osx"
    targetPath "build"
+/
/**
 * GCD — `dispatch_sync_f` borrows the calling thread; `dispatch_async_f` does not.
 *
 * A dispatch queue is not a thread. `dispatch_sync_f` does not hand the work
 * item to a worker and block: on the fast path libdispatch acquires the queue's
 * barrier state and invokes the function *inline on the caller's own thread*
 * (`_dispatch_lane_barrier_sync_invoke_and_complete`, `src/queue.c`). Only when
 * the queue is already busy does it fall back to enqueuing a waiter and parking
 * (`_dispatch_sync_f_slow`). `dispatch_async_f` always runs on a worker thread
 * drawn from the kernel's workqueue.
 *
 * The program also demonstrates the FIFO guarantee of a serial queue, and the
 * druntime rule for D code that runs on GCD worker threads: those threads are
 * not known to the GC, so a handler must either stay allocation-free or call
 * `thread_attachThis()`/`thread_detachThis()` around its body.
 *
 * Companion to the GCD deep-dive:
 * see docs/research/async-io/gcd/index.md § "`dispatch_sync` runs on the caller's thread".
 *
 * Run with: `dub run --single sync-on-caller-thread.d`
 *
 * Portability: macOS only (`platforms "osx"`).
 */
module gcd_sync_on_caller_thread;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.stdint : uintptr_t;
import core.thread.osthread : thread_attachThis;
import core.thread.threadbase : thread_detachThis;

import std.stdio : writefln, writeln;

alias dispatch_queue_t = void*;
alias dispatch_semaphore_t = void*;
alias dispatch_function_t = extern (C) void function(void*) nothrow;

extern (C) nothrow @nogc
{
    dispatch_queue_t dispatch_queue_create(const(char)* label, void* attr);
    void dispatch_sync_f(dispatch_queue_t queue, void* context, dispatch_function_t work);
    void dispatch_async_f(dispatch_queue_t queue, void* context, dispatch_function_t work);
    void dispatch_release(void* object);
    dispatch_semaphore_t dispatch_semaphore_create(long value);
    long dispatch_semaphore_wait(dispatch_semaphore_t sema, ulong timeout);
    long dispatch_semaphore_signal(dispatch_semaphore_t sema);

    // pthread_self is only ever compared here, never dereferenced.
    void* pthread_self();
}

enum DISPATCH_TIME_FOREVER = ~0UL;

struct Probe
{
    shared size_t observedThread;
    shared int ordering; // decimal digits appended in completion order
    shared bool attached;
    dispatch_semaphore_t done;
}

__gshared Probe probe;

/// Records which thread ran it. Allocation-free, so it is safe on any thread.
extern (C) void recordThread(void* context) nothrow
{
    atomicStore(probe.observedThread, cast(size_t) pthread_self());
}

/// Same, plus the druntime attach dance: after `thread_attachThis()` this
/// worker thread is a first-class D thread and may allocate from the GC.
extern (C) void recordThreadAndAllocate(void* context) nothrow
{
    atomicStore(probe.observedThread, cast(size_t) pthread_self());

    // A D exception must never unwind into libdispatch's C frames, so the whole
    // body is caught here. `thread_attachThis` is itself not `nothrow`.
    try
    {
        thread_attachThis();
        scope (exit)
            thread_detachThis();

        // Legal only because of the attach above.
        auto scratch = new int[16];
        atomicStore(probe.attached, scratch.length == 16);
    }
    catch (Throwable)
    {
        atomicStore(probe.attached, false);
    }

    dispatch_semaphore_signal(probe.done);
}

/// Appends its index (passed as an integer-in-a-pointer) to `ordering`.
extern (C) void appendDigit(void* context) nothrow
{
    import core.atomic : atomicOp;

    atomicOp!"+="(probe.ordering, cast(int)(cast(uintptr_t) context));
    atomicOp!"*="(probe.ordering, 10);
}

int main()
{
    auto queue = dispatch_queue_create("dev.sparkles.research.gcd.sync", null);
    scope (exit)
        dispatch_release(queue);
    probe.done = dispatch_semaphore_create(0);

    const caller = cast(size_t) pthread_self();

    // 1. dispatch_sync_f on an idle serial queue: invoked inline.
    dispatch_sync_f(queue, null, &recordThread);
    const syncThread = atomicLoad(probe.observedThread);
    writefln("dispatch_sync_f  ran on the calling thread: %s", syncThread == caller);
    assert(syncThread == caller, "dispatch_sync_f did not use the caller's thread");

    // 2. dispatch_async_f: always a workqueue thread.
    atomicStore(probe.observedThread, 0);
    dispatch_async_f(queue, null, &recordThreadAndAllocate);
    dispatch_semaphore_wait(probe.done, DISPATCH_TIME_FOREVER);
    const asyncThread = atomicLoad(probe.observedThread);
    writefln("dispatch_async_f ran on the calling thread: %s", asyncThread == caller);
    assert(asyncThread != caller, "dispatch_async_f reused the caller's thread");
    writefln("worker thread could allocate after thread_attachThis: %s", atomicLoad(probe.attached));
    assert(atomicLoad(probe.attached), "GC allocation on an attached worker thread failed");

    // 3. A serial queue dequeues in FIFO order, whichever thread each item lands
    //    on: the digits 1..5 accumulate as 12345 followed by the trailing zero
    //    of the last multiply.
    atomicStore(probe.ordering, 0);
    foreach (i; 1 .. 6)
        dispatch_async_f(queue, cast(void*) cast(uintptr_t) i, &appendDigit);
    dispatch_sync_f(queue, null, &recordThread); // barrier: drains everything before it
    const ordering = atomicLoad(probe.ordering);
    writefln("serial queue completion order:              %d", ordering);
    assert(ordering == 123_450, "serial queue did not run its work items in FIFO order");

    writeln();
    writeln("a queue is a lane, not a thread: `sync` borrows one, `async` rents one");
    return 0;
}
