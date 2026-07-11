/**
 * User-space counter reads (`rdpmc`) over the perf mmap page — the
 * `selfMonitoring` capability's primitive.
 *
 * A perf event fd's first mmapped page (`perf_event_mmap_page`) publishes the
 * counter's hardware index, an accumulated `offset`, and a seqlock; when the
 * kernel grants `cap_user_rdpmc`, a read is a few dozen cycles of pure user
 * space — no `read(2)`, no ioctl — the natural bracket for very short timed
 * bodies where the syscall bracket's own cost dominates the counts.
 *
 * The read loop is the uAPI-documented seqlock (retry while `lock` moves;
 * sign-extend the raw counter to `pmc_width`; add `offset`). An `index` of 0
 * means "not readable here and now" — the event is not scheduled on this CPU
 * or rdpmc is policy-disabled (`/sys/bus/event_source/devices/cpu/rdpmc`) —
 * and degrades like every other probe: the syscall `read(2)` path always
 * remains. x86-64 Linux only; everywhere else the reader is a stub.
 *
 * The counting pass does not use this bracket yet: per the delivery plan,
 * switching is gated on the measured win (`rdpmc.bracketCost` — a
 * `@benchmark` this module registers under `--bench`), not the literature's
 * order-of-magnitude claim.
 */
module sparkles.test_runner.rdpmc;

version (linux) version (X86_64)
{
    version (LDC)
        version = sparklesRdpmc;
    version (DigitalMars)
        version = sparklesRdpmc;
}

version (sparklesRdpmc)
{
    import core.atomic : atomicFence, MemoryOrder;
    import core.sys.linux.perf_event : perf_event_mmap_page;
    import core.volatile : volatileLoad;

    import sparkles.test_runner.attributes : benchmark;

    /// The `rdpmc` instruction: the raw value of hardware counter `idx`.
    private ulong rdpmcInsn(uint idx) @system nothrow @nogc
    {
        version (LDC)
        {
            import ldc.llvmasm : __asm;

            return __asm!ulong("rdpmc; shl $$32, %rdx; or %rdx, %rax",
                "={rax},{ecx},~{rdx}", idx);
        }
        else version (DigitalMars)
        {
            asm nothrow @nogc
            {
                mov ECX, idx;
                rdpmc;
                shl RDX, 32;
                or RAX, RDX;
            }
            // DMD: a function ending in an asm block returns RAX.
        }
        else
            static assert(false);
    }

    /// One event's user-space read view: the mmapped metadata page.
    struct RdpmcCounter
    {
        private perf_event_mmap_page* page;

        /// Maps the fd's metadata page (one page — no ring buffer needed for
        /// a counting event). Failure yields an unmapped reader.
        static RdpmcCounter tryMap(int fd) @trusted nothrow @nogc
        {
            import core.sys.posix.sys.mman : MAP_FAILED, MAP_SHARED, mmap, PROT_READ;

            RdpmcCounter c;
            if (fd < 0)
                return c;
            auto p = mmap(null, pageSize, PROT_READ, MAP_SHARED, fd, 0);
            if (p !is MAP_FAILED)
                c.page = cast(perf_event_mmap_page*) p;
            return c;
        }

        private enum size_t pageSize = 4096;

        /// Releases the mapping.
        void close() @trusted nothrow @nogc
        {
            import core.sys.posix.sys.mman : munmap;

            if (page !is null)
            {
                munmap(page, pageSize);
                page = null;
            }
        }

        bool mapped() const @safe pure nothrow @nogc => page !is null;

        /// Whether the kernel grants user-space reads for this event (the
        /// static capability bit; whether a read succeeds *now* additionally
        /// needs the event scheduled — see `read`).
        bool capRdpmc() const @trusted nothrow @nogc
            => page !is null && page.cap_user_rdpmc;

        /// One seqlock-protected read: `ok` is false when the event is not
        /// readable from user space right now (not scheduled on this CPU, or
        /// rdpmc denied) — the caller falls back to `read(2)`.
        ulong read(out bool ok) @trusted nothrow @nogc
        {
            ok = false;
            if (page is null)
                return 0;
            uint seq;
            ulong count;
            do
            {
                seq = volatileLoad(&page.lock);
                atomicFence!(MemoryOrder.acq)();
                const idx = volatileLoad(&page.index);
                const off = cast(long) volatileLoad(cast(ulong*) &page.offset);
                if (idx == 0)
                {
                    ok = false;
                    count = 0;
                }
                else
                {
                    const width = page.pmc_width;
                    long pmc = cast(long) rdpmcInsn(idx - 1);
                    if (width < 64)
                    {
                        pmc <<= 64 - width;
                        pmc >>= 64 - width; // sign-extend to the counter width
                    }
                    count = cast(ulong)(off + pmc);
                    ok = true;
                }
                atomicFence!(MemoryOrder.acq)();
            }
            while (volatileLoad(&page.lock) != seq);
            return count;
        }
    }

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
        // Created enabled, so the rdpmc case reads a scheduled counter.
        const fd = (() @trusted => cast(int) perf_event_open(
            hw_event: &attr, pid: 0, cpu: -1, group_fd: -1, flags: 0UL))();
        if (fd < 0)
            skipTest("perf_event_open failed — perf_event_paranoid?");
        auto reader = RdpmcCounter.tryMap(fd);
        if (!reader.capRdpmc)
        {
            reader.close();
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
        benchCase(
            name: "rdpmc-read",
            labels: ["bracket": "rdpmc"],
            timed: () @trusted {
                bool ok;
                blackBox(reader.read(ok));
            },
            after: () {});
        benchCase(
            name: "read2-syscall",
            labels: ["bracket": "read2"],
            timed: () @trusted {
                import core.sys.posix.unistd : read;

                ulong[1] buf;
                blackBox(read(fd, buf.ptr, buf.sizeof));
            },
            after: () {},
            teardown: () @trusted {
                import core.sys.posix.unistd : close;

                reader.close();
                close(fd);
            });
    }
}
else
{
    /// Off x86-64 Linux (or an unsupported compiler): user-space reads are
    /// unavailable; the syscall path is the only one.
    struct RdpmcCounter
    {
        static RdpmcCounter tryMap(int) @safe pure nothrow @nogc => RdpmcCounter();
        void close() @safe pure nothrow @nogc {}
        bool mapped() const @safe pure nothrow @nogc => false;
        bool capRdpmc() const @safe pure nothrow @nogc => false;

        ulong read(out bool ok) @safe pure nothrow @nogc
        {
            ok = false;
            return 0;
        }
    }
}
