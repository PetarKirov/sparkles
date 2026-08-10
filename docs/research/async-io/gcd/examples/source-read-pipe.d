#!/usr/bin/env dub
/+ dub.sdl:
    name "gcd_source_read_pipe"
    platforms "osx"
    targetPath "build"
+/
/**
 * GCD — `DISPATCH_SOURCE_TYPE_READ` is `EVFILT_READ` with the loop hidden.
 *
 * A dispatch source is libdispatch's whole event-loop surface: you never call
 * `kqueue()` or `kevent()`, you attach a handler to a source and the kernel
 * delivers the event straight to a workqueue thread. `_dispatch_source_type_read`
 * (`src/event/event.c`) is literally `{ .dst_filter = EVFILT_READ, .dst_flags =
 * EV_UDATA_SPECIFIC|EV_DISPATCH|EV_VANISHED }`, so the observable behaviour is
 * kqueue's: `dispatch_source_get_data()` returns the same byte count kqueue puts
 * in `kevent.data`, the registration auto-disables itself while the handler runs
 * (`EV_DISPATCH`), and a closed writer surfaces as a wakeup with zero bytes.
 *
 * The program drives a pipe through three states — readable, drained, EOF —
 * sequencing each with a semaphore so the output is deterministic, and asserts
 * the byte counts and the cancel-handler ordering.
 *
 * Companion to the GCD deep-dive:
 * see docs/research/async-io/gcd/index.md § "Dispatch sources: a kqueue vocabulary".
 *
 * Run with: `dub run --single source-read-pipe.d`
 *
 * Portability: macOS only (`platforms "osx"`).
 */
module gcd_source_read_pipe;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.stdc.stdint : uintptr_t;
import core.sys.posix.unistd : close, pipe, read, write;

import std.stdio : writefln, writeln;

alias dispatch_queue_t = void*;
alias dispatch_source_t = void*;
alias dispatch_semaphore_t = void*;
alias dispatch_function_t = extern (C) void function(void*) nothrow;

extern (C) nothrow @nogc
{
    // `DISPATCH_SOURCE_TYPE_READ` is `&_dispatch_source_type_read` — an opaque
    // descriptor record, referenced only by address.
    extern __gshared const ubyte _dispatch_source_type_read;

    dispatch_queue_t dispatch_queue_create(const(char)* label, void* attr);
    dispatch_source_t dispatch_source_create(const(void)* type, uintptr_t handle,
        uintptr_t mask, dispatch_queue_t queue);
    void dispatch_source_set_event_handler_f(dispatch_source_t source, dispatch_function_t handler);
    void dispatch_source_set_cancel_handler_f(dispatch_source_t source, dispatch_function_t handler);
    void dispatch_set_context(void* object, void* context);
    uintptr_t dispatch_source_get_data(dispatch_source_t source);
    uintptr_t dispatch_source_get_handle(dispatch_source_t source);
    void dispatch_source_cancel(dispatch_source_t source);
    void dispatch_resume(void* object);
    void dispatch_release(void* object);
    dispatch_semaphore_t dispatch_semaphore_create(long value);
    long dispatch_semaphore_wait(dispatch_semaphore_t sema, ulong timeout);
    long dispatch_semaphore_signal(dispatch_semaphore_t sema);
}

enum DISPATCH_TIME_FOREVER = ~0UL;

struct Watch
{
    dispatch_source_t source;
    dispatch_semaphore_t wakeup; // signalled once per event handler invocation
    dispatch_semaphore_t cancelled;
    shared int events;
    shared long lastAvailable;
    shared long lastRead;
    shared long totalRead;
}

__gshared Watch watch;

/// The event handler. Runs on the source's target queue, on a workqueue thread —
/// so it stays allocation-free and reports through `printf` and atomics.
extern (C) void onReadable(void* context) nothrow
{
    import core.stdc.stdio : printf;

    // kqueue's `kevent.data` for EVFILT_READ: bytes available right now.
    const available = cast(long) dispatch_source_get_data(watch.source);
    const fd = cast(int) dispatch_source_get_handle(watch.source);

    char[512] buffer = void;
    const wanted = available > 0 && available < buffer.length ? cast(size_t) available
        : buffer.length;
    const got = available == 0 ? 0 : read(fd, buffer.ptr, wanted);

    atomicOp!"+="(watch.events, 1);
    atomicStore(watch.lastAvailable, available);
    atomicStore(watch.lastRead, cast(long) got);
    if (got > 0)
        atomicOp!"+="(watch.totalRead, cast(long) got);

    printf("  event %d: get_data()=%lld read()=%lld\n",
        atomicLoad(watch.events), available, cast(long) got);

    // EOF is not a distinct event: kqueue keeps reporting the descriptor
    // readable with zero bytes, and `EV_DISPATCH` re-arms the registration as
    // soon as this handler returns. A source that is not cancelled here spins
    // at full speed. Cancelling from inside the handler is the only way to stop
    // it deterministically.
    if (available == 0)
        dispatch_source_cancel(watch.source);

    dispatch_semaphore_signal(watch.wakeup);
}

/// Runs after the source is fully cancelled — the only point at which the file
/// descriptor may be closed.
extern (C) void onCancel(void* context) nothrow
{
    import core.stdc.stdio : printf;

    printf("  cancel handler: safe to close the descriptor now\n");
    dispatch_semaphore_signal(watch.cancelled);
}

int main()
{
    int[2] fds;
    if (pipe(fds) != 0)
    {
        writeln("SKIP: pipe(2) failed");
        return 0;
    }
    const readEnd = fds[0], writeEnd = fds[1];

    auto queue = dispatch_queue_create("dev.sparkles.research.gcd.pipe", null);
    scope (exit)
        dispatch_release(queue);

    watch.wakeup = dispatch_semaphore_create(0);
    watch.cancelled = dispatch_semaphore_create(0);
    watch.source = dispatch_source_create(&_dispatch_source_type_read, readEnd, 0, queue);
    dispatch_set_context(watch.source, &watch);
    dispatch_source_set_event_handler_f(watch.source, &onReadable);
    dispatch_source_set_cancel_handler_f(watch.source, &onCancel);

    // Sources are created suspended; nothing is registered with kqueue until
    // the first resume.
    dispatch_resume(watch.source);

    writeln("state 1 — writer writes 11 bytes:");
    write(writeEnd, "hello world".ptr, 11);
    dispatch_semaphore_wait(watch.wakeup, DISPATCH_TIME_FOREVER);
    assert(atomicLoad(watch.lastAvailable) == 11, "EVFILT_READ data was not the byte count");
    assert(atomicLoad(watch.lastRead) == 11, "short read");

    writeln("state 2 — writer writes 4 more bytes:");
    write(writeEnd, "more".ptr, 4);
    dispatch_semaphore_wait(watch.wakeup, DISPATCH_TIME_FOREVER);
    assert(atomicLoad(watch.lastAvailable) == 4, "second wakeup reported the wrong count");

    writeln("state 3 — writer closes its end (the handler cancels the source):");
    close(writeEnd);
    dispatch_semaphore_wait(watch.wakeup, DISPATCH_TIME_FOREVER);
    assert(atomicLoad(watch.lastAvailable) == 0, "EOF wakeup carried a non-zero byte count");
    assert(atomicLoad(watch.lastRead) == 0, "read at EOF returned data");

    // Cancellation is asynchronous even when requested from the handler: the
    // cancel handler is the completion signal, and the only point at which the
    // descriptor may be closed.
    dispatch_semaphore_wait(watch.cancelled, DISPATCH_TIME_FOREVER);
    close(readEnd);
    dispatch_release(watch.source);

    writeln();
    writefln("handler invocations: %d, bytes delivered: %d",
        atomicLoad(watch.events), atomicLoad(watch.totalRead));
    assert(atomicLoad(watch.events) == 3, "expected exactly three wakeups");
    assert(atomicLoad(watch.totalRead) == 15, "expected 15 bytes across the two data wakeups");
    return 0;
}
