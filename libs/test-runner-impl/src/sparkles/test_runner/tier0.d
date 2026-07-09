/**
 * Tier-0 cheap resource counters, in pure D — the always-available I/O-bound
 * signal that needs no `perf_event`, no tracepoints, and no elevated privilege.
 *
 * Two process-wide cumulative sources are sampled as deltas across a counting
 * pass (mirroring `perf.d`'s separate pass, so the reported ns/iter timings are
 * never perturbed):
 *
 * $(LIST
 *   * `getrusage(RUSAGE_SELF)` — minor/major page faults and voluntary /
 *     involuntary context switches (the direct blocked-on-I/O vs preempted
 *     signal);
 *   * `/proc/self/io` — `syscr`/`syscw` (read/write syscall counts), `rchar`/
 *     `wchar` (bytes through the syscall layer, cache included) and `read_bytes`/
 *     `write_bytes` (bytes that actually hit the block device). The gap between
 *     `rchar` and `read_bytes` is the page-cache-hit signal, for free.
 * )
 *
 * All metrics are `quantitative`: each `timed()` call is bracketed by its own
 * pair of cheap snapshots, so — like `perf.d`'s ioctl `ENABLE`/`DISABLE` — the
 * untimed `between()` teardown (a `benchCase`'s result release) is excluded from
 * the counted window. The snapshots cannot pause, so each one's own `/proc` read
 * adds a small constant to `syscr`/`syscw` per iteration; the getrusage-sourced
 * page-fault and context-switch columns are unaffected. Off Linux the group is
 * permanently unavailable.
 */
module sparkles.test_runner.tier0;

/// Per-iteration Tier-0 counter deltas of one counting pass. A field is `nan`
/// when its source could not be read on this machine.
struct Tier0Stats
{
    ulong iters;      /// counting-pass iterations
    double minflt = 0; /// minor page faults per iteration (getrusage)
    double majflt = 0; /// major page faults per iteration (getrusage)
    double volCs = 0;  /// voluntary context switches per iteration (blocked on I/O)
    double involCs = 0; /// involuntary context switches per iteration (preempted)
    double syscr = 0;  /// read syscalls per iteration (/proc/self/io)
    double syscw = 0;  /// write syscalls per iteration
    double rdChars = 0; /// bytes read through the syscall layer (cache included)
    double wrChars = 0; /// bytes written through the syscall layer
    double rdBytes = 0; /// bytes that actually hit the block device (reads)
    double wrBytes = 0; /// bytes that actually hit the block device (writes)
}

/// Page-cache hit rate in percent: the fraction of bytes served without touching
/// the block device (`1 − read_bytes ÷ rchar`). `nan` when nothing was read (or
/// `read_bytes` is unavailable). A cold read's kernel readahead can pull more from
/// disk than userspace consumed (`read_bytes > rchar`), so the ratio is clamped to
/// a 0% hit rate rather than reported as `nan` — the cold case the metric reveals.
double cacheHitPercent(in Tier0Stats t) @safe pure nothrow @nogc
{
    import std.algorithm.comparison : min;

    return t.rdChars > 0 && t.rdBytes >= 0
        ? (1 - min(t.rdBytes, t.rdChars) / t.rdChars) * 100 : double.nan;
}

@("tier0.cacheHitPercent")
@safe pure nothrow @nogc
unittest
{
    import std.math : isClose, isNaN;

    assert(cacheHitPercent(Tier0Stats(rdChars: 4096, rdBytes: 0)).isClose(100));
    assert(cacheHitPercent(Tier0Stats(rdChars: 4096, rdBytes: 1024)).isClose(75));
    // Readahead: read_bytes > rchar → clamp to 0%, not nan.
    assert(cacheHitPercent(Tier0Stats(rdChars: 4096, rdBytes: 8192)).isClose(0));
    // Unknown block-device counter (nan) or nothing read → nan.
    assert(cacheHitPercent(Tier0Stats(rdChars: 4096, rdBytes: double.nan)).isNaN);
    assert(cacheHitPercent(Tier0Stats(rdChars: 0, rdBytes: 0)).isNaN);
}

/// Finds `key:` at a line start in a `/proc`-style `key:\tvalue` file and parses
/// the trailing unsigned integer; `-1` when the key is absent or unparsable.
long parseProcField(const(char)[] content, const(char)[] key) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < content.length)
    {
        if (content.length - i > key.length
            && content[i .. i + key.length] == key
            && content[i + key.length] == ':')
        {
            size_t j = i + key.length + 1;
            while (j < content.length && (content[j] == ' ' || content[j] == '\t'))
                j++;
            long value = 0;
            bool any;
            while (j < content.length && content[j] >= '0' && content[j] <= '9')
            {
                value = value * 10 + (content[j] - '0');
                j++;
                any = true;
            }
            return any ? value : -1;
        }
        while (i < content.length && content[i] != '\n')
            i++;
        if (i < content.length)
            i++;
    }
    return -1;
}

@("tier0.parseProcField")
@safe pure nothrow @nogc
unittest
{
    static immutable io = "rchar: 4096\nwchar: 0\nsyscr: 7\nread_bytes: 512\n";
    assert(parseProcField(io, "rchar") == 4096);
    assert(parseProcField(io, "syscr") == 7);
    assert(parseProcField(io, "read_bytes") == 512);
    assert(parseProcField(io, "write_bytes") == -1); // absent
    assert(parseProcField(io, "char") == -1);         // not a line-start key
}

/// Divides raw before/after readings into per-iteration `Tier0Stats`; a source
/// unavailable in either reading yields `nan` for its fields.
package Tier0Stats deltaStats(in Tier0Reading a, in Tier0Reading b, uint iters)
    @safe pure nothrow @nogc
in (iters > 0)
{
    const inv = 1.0 / iters;
    Tier0Stats s;
    s.iters = iters;
    if (a.rusageOk && b.rusageOk)
    {
        s.minflt = (b.minflt - a.minflt) * inv;
        s.majflt = (b.majflt - a.majflt) * inv;
        s.volCs = (b.volCs - a.volCs) * inv;
        s.involCs = (b.involCs - a.involCs) * inv;
    }
    else
        s.minflt = s.majflt = s.volCs = s.involCs = double.nan;
    if (a.ioOk && b.ioOk)
    {
        s.syscr = (b.syscr - a.syscr) * inv;
        s.syscw = (b.syscw - a.syscw) * inv;
        s.rdChars = (b.rdChars - a.rdChars) * inv;
        s.wrChars = (b.wrChars - a.wrChars) * inv;
        // read_bytes / write_bytes come from CONFIG_TASK_IO_ACCOUNTING, separate
        // from rchar/syscr (CONFIG_TASK_XACCT): a kernel with the latter but not
        // the former leaves these at -1 while ioOk is still true. Guard per field
        // so an absent block-device counter reads nan, not a bogus 0-byte delta.
        s.rdBytes = a.rdBytes >= 0 && b.rdBytes >= 0 ? (b.rdBytes - a.rdBytes) * inv : double.nan;
        s.wrBytes = a.wrBytes >= 0 && b.wrBytes >= 0 ? (b.wrBytes - a.wrBytes) * inv : double.nan;
    }
    else
        s.syscr = s.syscw = s.rdChars = s.wrChars = s.rdBytes = s.wrBytes = double.nan;
    return s;
}

@("tier0.deltaStats.absentBlockDeviceFields")
@safe pure nothrow @nogc
unittest
{
    import std.math : isClose, isNaN;

    // A kernel without CONFIG_TASK_IO_ACCOUNTING: rchar/syscr present, read_bytes/
    // write_bytes absent (-1) — ioOk is still true.
    const a = Tier0Reading(syscr: 10, syscw: 2, rdChars: 4096, wrChars: 0,
        rdBytes: -1, wrBytes: -1, ioOk: true);
    const b = Tier0Reading(syscr: 20, syscw: 4, rdChars: 8192, wrChars: 0,
        rdBytes: -1, wrBytes: -1, ioOk: true);
    const s = deltaStats(a, b, 2);
    assert(s.syscr.isClose(5) && s.rdChars.isClose(2048));
    assert(s.rdBytes.isNaN && s.wrBytes.isNaN, "absent block-device fields → nan");
    assert(cacheHitPercent(s).isNaN, "cache-hit unknown when read_bytes absent");
}

/// A single instant's raw cumulative counters.
struct Tier0Reading
{
    long minflt, majflt, volCs, involCs; /// getrusage
    long syscr, syscw, rdChars, wrChars, rdBytes, wrBytes; /// /proc/self/io
    bool rusageOk, ioOk;
}

version (linux)
{
    import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;

    /// The Tier-0 counter group. Stateless (no fds): `count` snapshots the
    /// cumulative counters before and after its own iteration loop.
    struct Tier0Group
    {
        private bool enabled;

        /// Whether Tier-0 counters will be collected (Linux and requested).
        bool available() const @safe pure nothrow @nogc => enabled;

        /// Human-readable availability, for a report header.
        string status() const @safe pure nothrow
            => enabled ? "getrusage + /proc/self/io" : "not requested";

        /// Enables collection when `enabled`; otherwise an unavailable group
        /// (mirrors `PerfGroup.tryOpen(false)`), so the same call sites work.
        static Tier0Group tryOpen(bool enabled) @safe pure nothrow @nogc
            => Tier0Group(enabled);

        /// Nothing to release; present for surface parity with `PerfGroup`.
        void close() @safe pure nothrow @nogc {}

        /// Reads the cumulative counters now.
        Tier0Reading snapshot() @safe
        {
            Tier0Reading r;
            rusage ru;
            if ((() @trusted => getrusage(RUSAGE_SELF, &ru))() == 0)
            {
                r.minflt = ru.ru_minflt;
                r.majflt = ru.ru_majflt;
                r.volCs = ru.ru_nvcsw;
                r.involCs = ru.ru_nivcsw;
                r.rusageOk = true;
            }
            char[1024] buf = void;
            const io = readProcSelfIo(buf[]);
            if (io.length)
            {
                r.syscr = parseProcField(io, "syscr");
                r.syscw = parseProcField(io, "syscw");
                r.rdChars = parseProcField(io, "rchar");
                r.wrChars = parseProcField(io, "wchar");
                r.rdBytes = parseProcField(io, "read_bytes");
                r.wrBytes = parseProcField(io, "write_bytes");
                // A field the kernel omits (older kernels, restricted) reads -1;
                // treat the source as usable iff the always-present counts are.
                r.ioOk = r.syscr >= 0 && r.rdChars >= 0;
            }
            return r;
        }

        /// The counting pass: brackets each `timed()` call with its own pair of
        /// snapshots so `between()` runs outside the counted window, sums the
        /// per-call deltas, and averages once. Returns per-iteration deltas; an
        /// unavailable source reads `nan` (it propagates through the sum).
        Tier0Stats count(Timed, Between)(scope Timed timed, scope Between between, uint iters)
        in (iters > 0)
        {
            Tier0Stats sum; // running sum of per-call deltas (nan propagates)
            foreach (_; 0 .. iters)
            {
                const start = snapshot();
                timed();
                const end = snapshot();
                between(); // untimed teardown, outside the start..end window
                const one = deltaStats(start, end, 1); // this call's counts, with validity
                sum.minflt += one.minflt;
                sum.majflt += one.majflt;
                sum.volCs += one.volCs;
                sum.involCs += one.involCs;
                sum.syscr += one.syscr;
                sum.syscw += one.syscw;
                sum.rdChars += one.rdChars;
                sum.wrChars += one.wrChars;
                sum.rdBytes += one.rdBytes;
                sum.wrBytes += one.wrBytes;
            }
            const inv = 1.0 / iters;
            sum.iters = iters;
            sum.minflt *= inv;
            sum.majflt *= inv;
            sum.volCs *= inv;
            sum.involCs *= inv;
            sum.syscr *= inv;
            sum.syscw *= inv;
            sum.rdChars *= inv;
            sum.wrChars *= inv;
            sum.rdBytes *= inv;
            sum.wrBytes *= inv;
            return sum;
        }
    }

    /// Reads `/proc/self/io` into `buf` via a raw `open`/`read`/`close`; returns
    /// the filled slice (empty on failure). `std.file` reports size 0 for `/proc`,
    /// so a direct read is required.
    private char[] readProcSelfIo(return scope char[] buf) @safe
    {
        import core.sys.posix.fcntl : open, O_RDONLY;
        import core.sys.posix.unistd : read, close;

        const fd = (() @trusted => open("/proc/self/io", O_RDONLY))();
        if (fd < 0)
            return null;
        scope (exit)
            (() @trusted => close(fd))();
        const n = (() @trusted => read(fd, buf.ptr, buf.length))();
        return n > 0 ? buf[0 .. n] : null;
    }

    @("tier0.Tier0Group.countSmoke")
    @system
    unittest
    {
        auto g = Tier0Group.tryOpen(true);
        assert(g.available);
        // A body that forces at least one write syscall so a count is observable.
        static void body_()
        {
            import core.sys.posix.unistd : write;

            char[1] c = ['x'];
            () @trusted { write(2, c.ptr, 0); }(); // 0-length write to stderr: a syscall, no output
        }

        const s = g.count(&body_, () {}, 64);
        assert(s.iters == 64);
        import std.math : isNaN;
        // On a normal Linux host both sources read; syscall count is non-negative.
        if (!s.syscw.isNaN)
            assert(s.syscw >= 0);
    }

    @("tier0.Tier0Group.countExcludesBetween")
    @system
    unittest
    {
        import std.conv : text;
        import std.math : isNaN;

        // Per-iteration bracketing must exclude the untimed `between` from the
        // window. The same write counts when it runs as `timed` but not as
        // `between`. Compare the two so process-wide noise from concurrent test
        // threads (getrusage/proc are per-process) cancels and only the signal
        // — one write/iter — remains.
        auto g = Tier0Group.tryOpen(true);
        if (!g.available)
            return;
        static void nop() {}
        static void writeOnce()
        {
            import core.sys.posix.unistd : write;

            char[1] c = ['x'];
            () @trusted { write(2, c.ptr, 0); }(); // 0-length write: a syscall, no output
        }

        const inTimed = g.count(&writeOnce, &nop, 64); // write inside the window
        const inBetween = g.count(&nop, &writeOnce, 64); // write outside the window
        if (!inTimed.syscw.isNaN && !inBetween.syscw.isNaN)
            assert(inTimed.syscw - inBetween.syscw > 0.5,
                text("a write in timed must count but in between must not; timed=",
                    inTimed.syscw, " between=", inBetween.syscw));
    }
}
else
{
    /// Non-Linux stub: Tier-0 counters are permanently unavailable.
    struct Tier0Group
    {
        bool available() const @safe pure nothrow @nogc => false;
        string status() const @safe pure nothrow => "unavailable (not Linux)";
        static Tier0Group tryOpen(bool) @safe pure nothrow @nogc => Tier0Group();
        void close() @safe pure nothrow @nogc {}

        Tier0Stats count(Timed, Between)(scope Timed, scope Between, uint)
        {
            assert(false, "Tier-0 counters are Linux-only");
        }

        Tier0Reading snapshot() @safe pure nothrow @nogc => Tier0Reading();
    }
}
