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
import sparkles.test_runner.attributes : benchCases;

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
    // One bracket per case. Each case opens its own counting event in `setup`
    // and closes it in `teardown`, so the rows share no state and any subset,
    // in any order, measures what it says.
    private struct BracketCost
    {
        import core.stdc.config : c_ulong;
        import core.sys.linux.perf_event : PERF_EVENT_IOC_DISABLE,
            PERF_EVENT_IOC_ENABLE;
        import core.sys.posix.sys.ioctl : ioctl;
        import sparkles.test_runner.bench : blackBox;

        enum Bracket { ioctlPair, rdpmcRead, read2Syscall }

        Bracket bracket;
        int fd = -1;
        RdpmcCounter reader;
        bool readOk;

        void setup() @trusted
        {
            fd = openInstructions();
            assert(fd >= 0, "perf_event_open worked in the probe and failed now");
            if (bracket == Bracket.rdpmcRead)
                reader = RdpmcCounter.tryMap(fd);
            // The reads measure a counting event: enabled, or the mmap page
            // reads index 0 and `read` measures its early-exit branch, not the
            // seqlock+rdpmc path. The ioctl pair toggles it itself.
            if (bracket != Bracket.ioctlPair)
                cast(void) ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_ENABLE, 0);
        }

        void timed() @trusted
        {
            import core.sys.posix.unistd : read;

            final switch (bracket)
            {
                case Bracket.ioctlPair:
                    cast(void) ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_ENABLE, 0);
                    cast(void) ioctl(fd, cast(c_ulong) PERF_EVENT_IOC_DISABLE, 0);
                    break;
                case Bracket.rdpmcRead:
                    blackBox(reader.read(readOk));
                    break;
                case Bracket.read2Syscall:
                    ulong[1] buf;
                    blackBox(read(fd, buf.ptr, buf.sizeof));
                    break;
            }
        }

        void after()
        {
            if (bracket == Bracket.rdpmcRead)
                assert(readOk, "the rdpmc case must measure a real read, "
                    ~ "not the index==0 early exit");
        }

        void teardown() @trusted
        {
            import core.sys.posix.unistd : close;

            reader.close();
            reader = RdpmcCounter.init;
            close(fd);
            fd = -1;
        }
    }

    // A disabled instructions counter: a stray enabled event would occupy a
    // PMC across every other benchmark measured this run.
    private int openInstructions() @trusted
    {
        import core.sys.linux.perf_event : perf_event_attr, perf_event_open,
            perf_hw_id, perf_type_id;

        perf_event_attr attr;
        attr.size = perf_event_attr.sizeof;
        attr.type = perf_type_id.PERF_TYPE_HARDWARE;
        attr.config = perf_hw_id.PERF_COUNT_HW_INSTRUCTIONS;
        attr.exclude_hv = 1;
        attr.disabled = 1;
        return cast(int) perf_event_open(hw_event: &attr, pid: 0, cpu: -1,
            group_fd: -1, flags: 0UL);
    }

    // The delivery plan's counting-bracket cost measurement: the per-iteration
    // price of the current ioctl ENABLE/DISABLE pair vs one rdpmc seqlock read
    // vs one read(2), on this host, under `--bench` — the numbers that decide
    // whether the counting pass switches brackets (open-issue O2).
    @("rdpmc.bracketCost")
    @benchCases @system
    unittest
    {
        import core.sys.posix.unistd : close;
        import sparkles.test_runner.bench : benchCase;
        import sparkles.test_runner.skip : skipTest;

        // Probe once, so an unprivileged host skips instead of erroring per row.
        const fd = openInstructions();
        if (fd < 0)
            skipTest("perf_event_open failed — perf_event_paranoid?");
        auto probe = RdpmcCounter.tryMap(fd);
        const capRdpmc = probe.capRdpmc;
        probe.close();
        close(fd);
        if (!capRdpmc)
            skipTest("cap_user_rdpmc denied (kernel rdpmc policy)");

        alias B = BracketCost.Bracket;
        benchCase(BracketCost(B.ioctlPair), name: "ioctl-pair", labels: ["bracket": "ioctl"]);
        benchCase(BracketCost(B.rdpmcRead), name: "rdpmc-read", labels: ["bracket": "rdpmc"]);
        benchCase(BracketCost(B.read2Syscall), name: "read2-syscall",
            labels: ["bracket": "read2"]);
    }

}
