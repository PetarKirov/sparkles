/**
 * Shared `perf_event` counter-group mechanics: the `ENABLE`/`DISABLE` counting
 * bracket and the `PERF_FORMAT_GROUP` scaled read. Both the hardware-counter
 * group (`perf.d`) and the syscall-tracepoint group (`syscalls.d`) open a
 * `perf_event` group led by an fd, bracket a benchmark's timed body with the
 * same ioctls, and read the group with the same layout (`nr`, `time_enabled`,
 * `time_running`, then one value per opened counter). This module holds that
 * common core so a change to the scaling/rounding is made once, not twice.
 */
module sparkles.test_runner.perf_group;

version (linux)
{
    import core.sys.linux.perf_event : perf_event_ioc_flags,
        PERF_EVENT_IOC_DISABLE, PERF_EVENT_IOC_ENABLE, PERF_EVENT_IOC_RESET;
    import core.sys.posix.sys.ioctl : ioctl;
    import core.sys.posix.unistd : read;

    /// Rounds to three decimals so counter columns stay short. Shared by the perf
    /// and syscall projections (kept in one place so they can't drift).
    package double round3(double v) @safe pure nothrow @nogc
    {
        import std.math.rounding : round;

        return round(v * 1000) / 1000;
    }

    /// Sends a group-wide `perf_event` ioctl to the group leader `leaderFd`.
    package void groupIoctl(int leaderFd, uint request) @safe
    {
        import core.stdc.config : c_ulong;

        (() @trusted => ioctl(leaderFd, cast(c_ulong) request,
                perf_event_ioc_flags.PERF_IOC_FLAG_GROUP))();
    }

    /// The counting pass's ioctl bracket: `RESET` once, then per iteration
    /// `ENABLE`, `timed()`, `DISABLE`, `between()` — so only `timed()` is counted
    /// and `between()` (a benchmark's result release) runs uncounted.
    package void bracketCountingPass(Timed, Between)(int leaderFd,
        scope Timed timed, scope Between between, uint iters)
    {
        groupIoctl(leaderFd, PERF_EVENT_IOC_RESET);
        foreach (_; 0 .. iters)
        {
            groupIoctl(leaderFd, PERF_EVENT_IOC_ENABLE);
            timed();
            groupIoctl(leaderFd, PERF_EVENT_IOC_DISABLE);
            between();
        }
    }

    /// Reads a `PERF_FORMAT_GROUP` group from `leaderFd` (`nOpen` counters opened,
    /// values returned in fd order). On success fills `values[0 .. nOpen]` with the
    /// per-iteration, multiplex-corrected averages `round3(raw · enabled/running ÷
    /// iters)`, sets `scale` to `round3(running/enabled)` (`1` = no multiplexing),
    /// and returns `true`. On a short/interrupted read returns `false` and leaves
    /// `values`/`scale` untouched (the caller fills `nan`).
    package bool readScaledGroup(int leaderFd, uint nOpen, uint iters,
        ref double scale, scope double[] values) @safe
    in (values.length >= nOpen)
    {
        enum maxCounters = 64; // perf group opens 7; syscall group up to 1 + 62
        ulong[3 + maxCounters] buf;
        const want = cast(long)(ulong.sizeof * (3 + nOpen));
        const got = (() @trusted => read(leaderFd, buf.ptr, buf.sizeof))();
        if (got < want)
            return false;

        const enabled = buf[1], running = buf[2];
        const ratio = (running > 0 && enabled > 0 && running < enabled)
            ? double(enabled) / double(running) : 1.0;
        scale = enabled > 0 ? round3(double(running) / double(enabled)) : 1.0;
        foreach (k; 0 .. nOpen)
            values[k] = round3(double(buf[3 + k]) * ratio / iters);
        return true;
    }
}
