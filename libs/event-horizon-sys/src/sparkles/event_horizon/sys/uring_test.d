/**
Tests of the vendored `io_uring` binding (`sparkles.event_horizon.sys.uring`):
one per defect fixed here, each failing on upstream's code.

A ring is opened on the real kernel; an environment that refuses io_uring
(seccomp, the `io_uring_disabled` sysctl, a container) or a kernel without the
feature a test needs skips it.
*/
module sparkles.event_horizon.sys.uring_test;

version (unittest):
version (linux):

import core.stdc.errno : ETIME;
import core.time : MonoTime, seconds;

import sparkles.event_horizon.sys.uring;
import sparkles.test_runner.skip : skipTest;

/// Opens `io` with `entries` entries, or skips the test.
private void openRing(ref Uring io, uint entries = 8) @safe nothrow @nogc
{
    if (io.setup(entries) < 0)
        skipTest("io_uring_setup refused (no kernel support, seccomp or io_uring_disabled)");
}

@("uring.submitAndWait.emptyQueueKeepsDeadline")
@safe nothrow @nogc
unittest
{
    Uring io;
    openRing(io);
    if (!(io.params.features & SetupFeatures.EXT_ARG))
        skipTest("no IORING_FEAT_EXT_ARG (Linux 5.11)");

    // A backstop already in the kernel, so a wait that drops its own deadline
    // completes, and fails below, instead of blocking forever.
    KernelTimespec backstop = {tv_sec: 2};
    SubmissionEntry e;
    e.prepTimeout(backstop);
    io.put(e);
    assert(io.submit() == 1);

    // The submission queue is now empty: the path that dropped `args`.
    KernelTimespec deadline = {tv_nsec: 50_000_000};
    io_uring_getevents_arg arg;
    arg.ts = (() @trusted => cast(ulong) &deadline)();

    const start = MonoTime.currTime;
    // The binding does not mark `args` `scope`; the kernel reads it only
    // during the call.
    const r = (() @trusted => io.submitAndWait(1, &arg))();
    const waited = MonoTime.currTime - start;

    assert(r == -ETIME);
    assert(io.empty, "the backstop completed: the deadline was dropped");
    assert(waited < 1.seconds);
}
