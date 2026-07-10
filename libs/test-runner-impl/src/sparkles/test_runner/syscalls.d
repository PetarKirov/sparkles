/**
 * In-process syscall counting via `perf_event_open` tracepoints, in pure D —
 * `strace -c` without a subprocess or ptrace.
 *
 * A counter group is opened over syscall tracepoints: `raw_syscalls:sys_enter`
 * (the group leader) counts *every* syscall, and one `syscalls:sys_enter_<name>`
 * counter per requested name gives the per-syscall breakdown. The tracepoint ids
 * come from `tracefs` (`/sys/kernel/tracing/events/<group>/<event>/id`). Counting
 * is kernel-side, so — like `perf.d` — a separate counting pass brackets each
 * benchmark's timed body with `ENABLE`/`DISABLE`, and the ioctls never perturb
 * the reported timings.
 *
 * `attr.inherit` is set, so counters clone into every thread the process spawns
 * *after* `perf_event_open` — and the group opens once at bench-mode start,
 * before any case's setup runs, so worker pools created in untimed setup are
 * followed too (their syscalls aggregate into the leader's group read). Only
 * threads that already existed when the group opened are not followed — that
 * needs per-TID attach (a later refinement) or the ptrace backend the roadmap
 * prepares behind the same `--syscalls` flag.
 *
 * Tracepoints need `perf_event_paranoid <= 1`; where they can't be opened — and
 * everywhere off Linux — the group degrades to unavailable and the columns are
 * simply omitted. Pure D over druntime's `core.sys.linux.perf_event`; no ImportC.
 */
module sparkles.test_runner.syscalls;

/// Per-iteration syscall counts of one counting pass. `total` is every syscall
/// (`raw_syscalls:sys_enter`); `counts[i]` is the per-iteration count of the
/// tracepoint named `named[i]` (`nan` if that tracepoint could not be opened).
struct SyscallStats
{
    ulong iters;
    double total = 0;
    const(string)[] named;
    double[] counts;
    double scale = 1;
}

/// Parses the single integer in a tracepoint `id` file (`"1234\n"`); `-1` on
/// empty/garbage.
long parseTracepointId(const(char)[] content) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < content.length && (content[i] == ' ' || content[i] == '\t'))
        i++;
    long value = 0;
    bool any;
    while (i < content.length && content[i] >= '0' && content[i] <= '9')
    {
        value = value * 10 + (content[i] - '0');
        i++;
        any = true;
    }
    return any ? value : -1;
}

@("syscalls.parseTracepointId")
@safe pure nothrow @nogc
unittest
{
    assert(parseTracepointId("1234\n") == 1234);
    assert(parseTracepointId("42") == 42);
    assert(parseTracepointId("") == -1);
    assert(parseTracepointId("\n") == -1);
    assert(parseTracepointId("abc") == -1);
}

version (linux)
{
    import core.sys.linux.perf_event : perf_event_attr, perf_event_open,
        perf_type_id, perf_event_read_format;
    import core.sys.posix.unistd : posixClose = close;

    private enum maxNamed = 62; /// group read buffer is `double[1 + maxNamed]`

    /// Reads a tracepoint's numeric id from `tracefs`; `-1` if unavailable.
    long tracepointId(string group, string event) @safe
    {
        static long readId(string path) @safe
        {
            import core.sys.posix.fcntl : open, O_RDONLY;
            import core.sys.posix.unistd : read, close;

            const cPath = path ~ "\0";
            const fd = (() @trusted => open(cPath.ptr, O_RDONLY))();
            if (fd < 0)
                return -1;
            scope (exit)
                (() @trusted => close(fd))();
            char[32] buf;
            const n = (() @trusted => read(fd, buf.ptr, buf.length))();
            return n > 0 ? parseTracepointId(buf[0 .. n]) : -1;
        }

        const suffix = "events/" ~ group ~ "/" ~ event ~ "/id";
        const id = readId("/sys/kernel/tracing/" ~ suffix);
        return id >= 0 ? id : readId("/sys/kernel/debug/tracing/" ~ suffix);
    }

    /// The syscall tracepoint counter group (Linux). `tryOpen` once; `count`
    /// brackets one benchmark's timed body per iteration.
    struct SyscallGroup
    {
        private int[] fds;          /// [leader(total), named...]; -1 = unavailable
        private const(string)[] names_;
        private int nOpen;
        private bool opened;

        /// Whether syscall counters are usable on this machine.
        bool available() const @safe pure nothrow @nogc => opened;

        /// The requested per-syscall names (parallel to a row's `counts`).
        const(string)[] names() const @safe pure nothrow @nogc => names_;

        /// Human-readable availability, for a report header.
        string status() const @safe pure nothrow
            => opened
                ? "raw_syscalls:sys_enter + per-syscall tracepoints"
                : "unavailable (needs readable tracefs and perf_event_paranoid ≤ 1 — usually root)";

        /// Opens the group unless disabled: the `raw_syscalls:sys_enter` leader
        /// plus one `syscalls:sys_enter_<name>` counter per requested name. A
        /// name whose tracepoint can't be resolved gets a `-1` fd (its column
        /// reads `nan`). Failure to open the leader leaves the group unavailable.
        static SyscallGroup tryOpen(bool enabled, const(string)[] named) @safe
        {
            SyscallGroup g;
            if (!enabled)
                return g;
            if (named.length > maxNamed)
                named = named[0 .. maxNamed];
            g.names_ = named;
            g.fds = new int[](1 + named.length);
            g.fds[] = -1;

            const leaderId = tracepointId("raw_syscalls", "sys_enter");
            if (leaderId < 0)
                return g;
            const leader = g.openCounter(leaderId, -1);
            if (leader < 0)
                return g;
            g.fds[0] = leader;
            g.nOpen = 1;
            foreach (i, name; named)
            {
                const id = tracepointId("syscalls", "sys_enter_" ~ name);
                if (id < 0)
                    continue;
                const fd = g.openCounter(id, leader);
                if (fd >= 0)
                {
                    g.fds[1 + i] = fd;
                    g.nOpen++;
                }
            }
            g.opened = true;
            return g;
        }

        /// Opens one tracepoint counter; `group_fd` is `-1` for the leader.
        private int openCounter(long id, int leader) @safe
        {
            perf_event_attr attr;
            attr.size = perf_event_attr.sizeof;
            attr.type = perf_type_id.PERF_TYPE_TRACEPOINT;
            attr.config = cast(ulong) id;
            attr.disabled = leader < 0;
            attr.inherit = 1; // follow threads spawned during the timed body
            if (leader < 0)
                with (perf_event_read_format)
                    attr.read_format = PERF_FORMAT_GROUP
                        | PERF_FORMAT_TOTAL_TIME_ENABLED
                        | PERF_FORMAT_TOTAL_TIME_RUNNING;

            return (() @trusted => cast(int) perf_event_open(
                hw_event: &attr, pid: 0, cpu: -1, group_fd: leader, flags: 0UL))();
        }

        private void closeFds() @safe
        {
            foreach (ref fd; fds)
            {
                if (fd >= 0)
                    (() @trusted => posixClose(fd))();
                fd = -1;
            }
            nOpen = 0;
        }

        /// Releases the counter fds.
        void close() @safe
        {
            if (opened)
            {
                closeFds();
                opened = false;
            }
        }

        /// The counting pass: brackets each `timed()` with `ENABLE`/`DISABLE` so
        /// `between()` runs uncounted, then reads the group. Returns per-iteration
        /// counts; the `named` tracepoints are exact.
        SyscallStats count(Timed, Between)(scope Timed timed, scope Between between,
            uint iters)
        in (iters > 0)
        {
            import sparkles.test_runner.perf_group : bracketCountingPass, readScaledGroup;

            const base = bracketCountingPass(fds[0], timed, between, iters);

            SyscallStats s;
            s.iters = iters;
            s.named = names_;
            s.counts = new double[](names_.length);
            s.counts[] = double.nan;

            // One scaled per-iteration value per opened counter, in fds order; a
            // short read → total unavailable (named counts stay nan).
            double[1 + maxNamed] values;
            if (!readScaledGroup(fds[0], nOpen, iters, s.scale, values[], base))
            {
                s.total = double.nan;
                return s;
            }

            size_t slot;
            foreach (i, fd; fds)
            {
                if (fd < 0)
                    continue;
                const perIter = values[slot++];
                if (i == 0)
                    s.total = perIter;
                else
                    s.counts[i - 1] = perIter;
            }
            return s;
        }
    }

    @("syscalls.SyscallGroup.countGetpid")
    @system
    unittest
    {
        import core.sys.posix.unistd : getpid;

        auto g = SyscallGroup.tryOpen(true, ["getpid"]);
        scope (exit)
            g.close();
        import sparkles.test_runner.skip : skipTest;

        if (!g.available) // perf_event_paranoid > 1 / root-only tracefs
            skipTest(g.status());

        static void body_()
        {
            import core.sys.posix.unistd : getpid;

            () @trusted { cast(void) getpid(); }();
        }

        const s = g.count(&body_, () {}, 200);
        assert(s.iters == 200);
        // The named getpid tracepoint is exact: ~1 getpid per iteration.
        import std.math : isNaN;

        if (!s.counts[0].isNaN)
            assert(s.counts[0] >= 0.9 && s.counts[0] <= 1.5);
        assert(s.total >= 1.0); // at least the getpid; plus the DISABLE ioctl
    }
}
else
{
    /// Non-Linux stub: syscall counters are permanently unavailable.
    struct SyscallGroup
    {
        bool available() const @safe pure nothrow @nogc => false;
        const(string)[] names() const @safe pure nothrow @nogc => null;
        string status() const @safe pure nothrow => "unavailable (not Linux)";
        static SyscallGroup tryOpen(bool, const(string)[]) @safe pure nothrow @nogc
            => SyscallGroup();
        void close() @safe pure nothrow @nogc {}

        SyscallStats count(Timed, Between)(scope Timed, scope Between, uint)
        {
            assert(false, "syscall counters are Linux-only");
        }
    }
}
