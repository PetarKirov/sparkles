/**
 * The tests of `sparkles.profiling.counters.rdpmc`. They use the harness
 * (`skipTest`, the benchmark layer), which depends on the counters, so
 * they live in the harness rather than self-hosting it in the counters'
 * package (build graph BGR8).
 */
module sparkles.test_runner.counters_test.rdpmc;

version (linux) version (X86_64)
{
    version (LDC)
        version = sparklesRdpmc;
    version (DigitalMars)
        version = sparklesRdpmc;
}

import sparkles.profiling.counters.rdpmc;
import sparkles.test_runner.attributes : benchmark;

version (sparklesRdpmc)
{
    @("rdpmc.RdpmcCounter.crossValidatesWithRead")
    @system
    unittest
    {
        import core.sys.linux.perf_event : PERF_EVENT_IOC_DISABLE,
            PERF_EVENT_IOC_ENABLE, PERF_EVENT_IOC_RESET, perf_event_attr,
            perf_event_open, perf_hw_id, perf_type_id;
        import core.sys.posix.sys.ioctl : ioctl;
        import core.sys.posix.unistd : close, read;
        import sparkles.test_runner.skip : skipTest;

        perf_event_attr attr;
        attr.size = perf_event_attr.sizeof;
        attr.type = perf_type_id.PERF_TYPE_HARDWARE;
        attr.config = perf_hw_id.PERF_COUNT_HW_INSTRUCTIONS;
        attr.exclude_hv = 1;
        const fd = (() @trusted => cast(int) perf_event_open(
            hw_event: &attr, pid: 0, cpu: -1, group_fd: -1, flags: 0UL))();
        if (fd < 0)
            skipTest("perf_event_open failed — perf_event_paranoid?");
        scope (exit)
            (() @trusted => close(fd))();

        auto reader = RdpmcCounter.tryMap(fd);
        scope (exit)
            reader.close();
        if (!reader.capRdpmc)
            skipTest("cap_user_rdpmc denied (kernel rdpmc policy)");

        static ulong sink;
        foreach (i; 0 .. 100_000)
            sink += i * i;

        bool ok;
        const viaRdpmc = reader.read(ok);
        if (!ok)
            skipTest("counter not readable from user space right now");
        ulong[1] buf;
        const got = (() @trusted => read(fd, buf.ptr, buf.sizeof))();
        assert(got == buf.sizeof);
        const viaSyscall = buf[0];

        // Both reads count the same event; the syscall read runs a hair
        // later, so it may only be equal or larger (by the instructions the
        // gap itself retires).
        assert(viaSyscall >= viaRdpmc, "rdpmc must not run ahead of read(2)");
        assert(viaSyscall - viaRdpmc < 1_000_000,
            "the two reads bracket only the read gap");
    }

    // The delivery plan's counting-bracket cost measurement: the per-iteration
    // price of the current ioctl ENABLE/DISABLE pair vs one rdpmc seqlock read
    // vs one read(2), on this host, under `--bench` — the numbers that decide
    // whether the counting pass switches brackets (open-issue O2).
    @("rdpmc.bracketCost")
    @benchmark @system
    unittest
    {
        import core.stdc.config : c_ulong;
        import core.sys.linux.perf_event : PERF_EVENT_IOC_DISABLE,
            PERF_EVENT_IOC_ENABLE, perf_event_attr, perf_event_open,
            perf_hw_id, perf_type_id;
        import core.sys.posix.sys.ioctl : ioctl;
        import sparkles.test_runner.bench : benchCase, blackBox;
        import sparkles.test_runner.skip : skipTest;

        perf_event_attr attr;
        attr.size = perf_event_attr.sizeof;
        attr.type = perf_type_id.PERF_TYPE_HARDWARE;
        attr.config = perf_hw_id.PERF_COUNT_HW_INSTRUCTIONS;
        attr.exclude_hv = 1;
        // Created disabled: a stray enabled event would occupy a PMC across
        // every other benchmark measured this run. Each case enables what it
        // needs in its own untimed setup.
        attr.disabled = 1;
        const fd = (() @trusted => cast(int) perf_event_open(
            hw_event: &attr, pid: 0, cpu: -1, group_fd: -1, flags: 0UL))();
        if (fd < 0)
            skipTest("perf_event_open failed — perf_event_paranoid?");
        auto reader = RdpmcCounter.tryMap(fd);
        if (!reader.capRdpmc)
        {
            reader.close();
            (() @trusted { import core.sys.posix.unistd : close; close(fd); })();
            skipTest("cap_user_rdpmc denied (kernel rdpmc policy)");
        }

        // Deferred execution: the cases run after this body returns, so the
        // fd/reader ride the closures (released by the last case's teardown).
        benchCase(
            name: "ioctl-pair",
            labels: ["bracket": "ioctl"],
            timed: () @trusted {
                cast(void) ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_ENABLE, 0);
                cast(void) ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_DISABLE, 0);
            },
            after: () {});
        auto readOk = new bool;
        benchCase(
            name: "rdpmc-read",
            timed: () @trusted {
                bool ok;
                blackBox(reader.read(ok));
                *readOk = ok;
            },
            after: () {
                assert(*readOk, "the rdpmc case must measure a real read, "
                    ~ "not the index==0 early exit");
            },
            labels: ["bracket": "rdpmc"],
            // The ioctl case leaves the event DISABLED (index 0 in the mmap
            // page — the read would measure its early-exit branch, not the
            // seqlock+rdpmc path); re-enable it untimed first.
            setup: () @trusted {
                cast(void) ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_ENABLE, 0);
            });
        benchCase(
            name: "read2-syscall",
            timed: () @trusted {
                import core.sys.posix.unistd : read;

                ulong[1] buf;
                blackBox(read(fd, buf.ptr, buf.sizeof));
            },
            after: () {},
            labels: ["bracket": "read2"],
            teardown: () @trusted {
                import core.sys.posix.unistd : close;

                reader.close();
                close(fd);
            });
    }

}
