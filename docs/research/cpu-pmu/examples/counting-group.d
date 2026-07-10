#!/usr/bin/env dub
/+ dub.sdl:
    name "cpu_pmu_counting_group"
    platforms "linux"
    targetPath "build"
+/
/**
 * Grouped scalar counting via `perf_event_open(2)` and PMC multiplexing, pure D.
 *
 * Two demonstrations of the Linux *counting* path, both over druntime's
 * `core.sys.linux.perf_event` (the attr layout + syscall wrapper) — no C shim:
 *
 *   1. A `PERF_FORMAT_GROUP` group — a `cycles` leader plus `instructions` —
 *      read in one `read(2)` as `{nr, time_enabled, time_running, value[nr]}`.
 *      The two values give IPC. Because the events share one group the kernel
 *      schedules them as a unit, so `time_running == time_enabled` and the
 *      counts are exact (`scale == 1.0`).
 *   2. Deliberate oversubscription: N independent single-event groups (N greater
 *      than the PMU's general-purpose counters — 6 on Zen 4) opened over one
 *      workload window so the kernel round-robin-*multiplexes* them. Each event
 *      then reports `time_running < time_enabled`; perf recovers an estimate by
 *      scaling `raw * time_enabled / time_running`. This is the accuracy cost
 *      the grouped path in (1) is designed to avoid.
 *
 * Companion to docs/research/cpu-pmu/linux-perf-events.md
 *   § "Scalar counting: groups, `PERF_FORMAT_GROUP`, and multiplexing".
 *
 * Run with: dub run --single counting-group.d
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX (Zen 4; 6 core PMCs),
 * `/proc/sys/kernel/perf_event_paranoid` = -1, LDC 1.41 druntime
 * `core.sys.linux.perf_event`.
 *
 * Portability: any `perf_event_open` failure (`perf_event_paranoid`, seccomp,
 * no PMU, non-Linux) prints a `SKIP:` line and exits 0 so CI stays green on any
 * host.
 */
module cpu_pmu_counting_group;

version (linux)
{
    import core.sys.linux.perf_event;
    import core.sys.posix.unistd : read, close;
    import core.sys.posix.sys.ioctl : ioctl;
    import core.stdc.config : c_ulong;
    import std.stdio : writefln, writeln;

    /// A hardware event to count, named for the report.
    struct Ev
    {
        string name;
        ulong config; // a `perf_hw_id`
    }

    /// Opens one `PERF_TYPE_HARDWARE` event on the calling thread (`pid == 0`),
    /// any CPU (`cpu == -1`). `groupFd == -1` makes it a group leader; a leader
    /// carries the read format (`PERF_FORMAT_GROUP` when `grouped`, plus the two
    /// time fields) and starts `disabled`. Returns the fd, or -1 on failure.
    int openEvent(ulong config, int groupFd, bool grouped, bool excludeKernel) @trusted
    {
        perf_event_attr attr;
        attr.size = perf_event_attr.sizeof;
        attr.type = perf_type_id.PERF_TYPE_HARDWARE;
        attr.config = config;
        attr.exclude_hv = 1;
        attr.exclude_kernel = excludeKernel ? 1 : 0;
        const isLeader = groupFd < 0;
        attr.disabled = isLeader ? 1 : 0; // enabling the leader enables the group
        if (isLeader)
        {
            attr.read_format = perf_event_read_format.PERF_FORMAT_TOTAL_TIME_ENABLED
                | perf_event_read_format.PERF_FORMAT_TOTAL_TIME_RUNNING;
            if (grouped)
                attr.read_format |= perf_event_read_format.PERF_FORMAT_GROUP;
        }
        return cast(int) perf_event_open(&attr, 0, -1, groupFd, 0);
    }

    void ctl(int fd, uint request, bool wholeGroup) @trusted
    {
        ioctl(fd, cast(c_ulong) request,
            wholeGroup ? perf_event_ioc_flags.PERF_IOC_FLAG_GROUP : 0);
    }

    long readN(int fd, ulong[] buf) @trusted => read(fd, buf.ptr, buf.length * ulong.sizeof);

    /// A fixed amount of work: multiply-shift-xor mixing, enough retired
    /// instructions that counter noise is negligible. `__gshared` sink defeats
    /// dead-code elimination.
    __gshared ulong sink;
    void workload()
    {
        ulong acc = 0x9E3779B97F4A7C15UL;
        foreach (i; 0 .. 3_000_000UL)
            acc = (acc + i) * 2654435761UL ^ (acc >> 13);
        sink += acc;
    }

    int run()
    {
        // ---- Demo 1: a fitting group → exact IPC, scale == 1 --------------
        // Probe permission once: prefer kernel+user, fall back to user-only.
        bool excludeKernel = false;
        int leader = openEvent(perf_hw_id.PERF_COUNT_HW_CPU_CYCLES, -1, true, false);
        if (leader < 0)
        {
            excludeKernel = true;
            leader = openEvent(perf_hw_id.PERF_COUNT_HW_CPU_CYCLES, -1, true, true);
        }
        if (leader < 0)
        {
            writefln("SKIP: perf_event_open failed — perf_event_paranoid too high, "
                ~ "seccomp, or no PMU on this host");
            return 0;
        }
        const insns = openEvent(perf_hw_id.PERF_COUNT_HW_INSTRUCTIONS, leader, true, excludeKernel);
        if (insns < 0)
        {
            writefln("SKIP: could not add instructions to the group (errno on member open)");
            close(leader);
            return 0;
        }

        ctl(leader, PERF_EVENT_IOC_RESET, true);
        ctl(leader, PERF_EVENT_IOC_ENABLE, true);
        workload();
        ctl(leader, PERF_EVENT_IOC_DISABLE, true);

        // Group read: nr, time_enabled, time_running, value[cycles], value[insns].
        ulong[5] g;
        const got = readN(leader, g[]);
        close(insns);
        close(leader);
        if (got < cast(long)(5 * ulong.sizeof))
        {
            writefln("SKIP: short group read (%d bytes) — counters unavailable", got);
            return 0;
        }
        const nr = g[0], enabled = g[1], running = g[2], cyc = g[3], ins = g[4];
        const groupScale = running > 0 ? cast(double) enabled / running : double.nan;
        writefln("== Demo 1: fitting group (%s) ==", excludeKernel ? "user-only" : "kernel+user");
        writefln("  nr=%d  time_enabled=%d ns  time_running=%d ns  scale=%.4f",
            nr, enabled, running, groupScale);
        writefln("  cycles=%d  instructions=%d  IPC=%.3f", cyc, ins,
            cyc > 0 ? cast(double) ins / cyc : double.nan);
        writeln("  (grouped events co-schedule → time_running == time_enabled → exact)");

        // ---- Demo 2: oversubscribe the PMCs → multiplexing scaling --------
        // N separate single-event groups counting the SAME event over ONE
        // workload window. With N > general-purpose counters the kernel rotates
        // them, so each sees only part of the window (running < enabled).
        enum N = 10;
        int[N] fds = -1;
        int opened = 0;
        foreach (ref fd; fds)
        {
            fd = openEvent(perf_hw_id.PERF_COUNT_HW_INSTRUCTIONS, -1, false, excludeKernel);
            if (fd >= 0)
                opened++;
        }
        if (opened == 0)
        {
            writefln("SKIP: oversubscription demo could not open any event");
            return 0;
        }

        foreach (fd; fds)
            if (fd >= 0)
                ctl(fd, PERF_EVENT_IOC_RESET, false);
        foreach (fd; fds)
            if (fd >= 0)
                ctl(fd, PERF_EVENT_IOC_ENABLE, false);
        workload();
        foreach (fd; fds)
            if (fd >= 0)
                ctl(fd, PERF_EVENT_IOC_DISABLE, false);

        writefln("\n== Demo 2: %d instruction counters, %d general-purpose PMCs ==", opened, 6);
        writeln("  ev   raw_running_count      enabled_ns    running_ns   scale   estimate");
        bool sawMux = false;
        foreach (i, fd; fds)
        {
            if (fd < 0)
                continue;
            ulong[3] s; // value, time_enabled, time_running
            if (readN(fd, s[]) >= cast(long)(3 * ulong.sizeof))
            {
                if (s[2] < s[1])
                    sawMux = true;
                if (s[2] == 0)
                    // Enabled but never got a counter this window: the kernel's
                    // `<not counted>` state — a zero read is not a measurement.
                    writefln("  %2d   %18d   %12d  %12d       —   <not scheduled>",
                        i, s[0], s[1], s[2]);
                else
                {
                    const sc = cast(double) s[1] / s[2];
                    writefln("  %2d   %18d   %12d  %12d   %5.2f   %d",
                        i, s[0], s[1], s[2], sc, cast(ulong)(s[0] * sc));
                }
            }
            close(fd);
        }
        writefln("  multiplexing observed: %s", sawMux ? "yes (time_running < time_enabled — "
            ~ "raw counts are partial; the scaled estimate recovers the whole-window value)"
            : "no (this PMU has enough counters to co-schedule all events)");
        return 0;
    }
}

int main()
{
    version (linux)
        return run();
    else
    {
        import std.stdio : writefln;

        writefln("SKIP: perf_event_open is Linux-only");
        return 0;
    }
}
