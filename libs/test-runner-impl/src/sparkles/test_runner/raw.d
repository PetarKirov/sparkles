/**
 * Raw hardware-event counting (`PERF_TYPE_RAW`), in pure D — the escape hatch
 * past the seven generic `PERF_COUNT_*` events.
 *
 * A `--metrics=raw:r<hex>` selector names a microarchitecture-specific event
 * by its raw config (the `perf` tool's `rNNNN` notation — on x86 the event
 * select and umask bytes); each becomes one diagnostic column. The events
 * open as one counter group separate from `perf.d`'s calibrated default
 * group, so requesting a raw event never perturbs the default columns'
 * exactness — the raw group scales by its own pass's `enabled`/`running`
 * deltas when the PMU multiplexes it.
 *
 * Availability mirrors every other tier: `tryOpen` probes, `capabilities()`
 * reports `countingRaw` with a reasoned absence, and off Linux — or under a
 * refusing `perf_event_paranoid` — the columns are simply omitted. Raw
 * configs are inherently µarch-specific; the named-event resolution layer
 * (libpfm4) lands separately and feeds the same group.
 */
module sparkles.test_runner.raw;

import sparkles.test_runner.capability : Capability, CapabilityAbsence,
    CapabilityReport, has, hasNamedColumns, hasSnapshot, isCounterBackend,
    reasonFor;

/// One raw event request: the selector as the user wrote it (the column id
/// rides it) plus the decoded `perf_event_attr` payload.
struct RawEvent
{
    string selector; /// e.g. "r04c2" (the `raw:` prefix stripped)
    ulong config;    /// the raw config value (`0x04c2`)
}

/// Parses one `r<hex>` selector (the `perf` tool's raw-event notation, the
/// `raw:` prefix already stripped). Returns false on anything malformed.
bool parseRawEvent(string selector, out RawEvent ev) @safe pure nothrow @nogc
{
    if (selector.length < 2 || selector.length > 17 || selector[0] != 'r')
        return false;
    ulong config = 0;
    foreach (c; selector[1 .. $])
    {
        uint digit;
        if (c >= '0' && c <= '9')
            digit = c - '0';
        else if (c >= 'a' && c <= 'f')
            digit = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F')
            digit = c - 'A' + 10;
        else
            return false;
        config = (config << 4) | digit;
    }
    ev = RawEvent(selector, config);
    return true;
}

@("raw.parseRawEvent.fixtures")
@safe pure nothrow @nogc
unittest
{
    RawEvent ev;
    assert(parseRawEvent("r04c2", ev) && ev.config == 0x04c2 && ev.selector == "r04c2");
    assert(parseRawEvent("r00C0", ev) && ev.config == 0xc0);
    assert(parseRawEvent("r0", ev) && ev.config == 0);
    assert(!parseRawEvent("04c2", ev), "missing the r prefix");
    assert(!parseRawEvent("r", ev), "no digits");
    assert(!parseRawEvent("rxyz", ev), "not hex");
    assert(!parseRawEvent("r00000000000000000", ev), "wider than 64 bits");
}

/// Per-iteration counts of one raw counting pass: `values[i]` belongs to
/// `selectors[i]` (`nan` where that event could not be opened).
struct RawStats
{
    ulong iters;                 /// counting-pass iterations
    const(string)[] selectors;   /// requested selectors, in request order
    double[] values;             /// per-iteration averages (nan = unavailable)
    double scale = 1;            /// running/enabled ratio of the pass (1 = clean)
}

version (linux)
{
    import core.sys.linux.perf_event : perf_event_attr, perf_event_open,
        perf_type_id, perf_event_read_format;
    import core.sys.posix.unistd : posixClose = close;

    /// The raw-event counter group (Linux). `tryOpen` once; `count` brackets
    /// one benchmark's timed body per iteration. With no events it degrades
    /// to a permission probe (one throwaway config-0 open), so
    /// `--list-metrics` can report `countingRaw` truthfully without columns.
    struct RawGroup
    {
        private enum maxEvents = 16; /// well past any PMC budget; passes scale

        private int[] fds;           /// one per requested event; -1 = refused
        private const(string)[] selectors_;
        private int nOpen;
        private bool requested;
        private bool probeOk;        /// a raw event opened (probe or real)
        private bool opened;         /// events opened — columns will appear

        /// Whether raw counters will be collected on this run.
        bool available() const @safe pure nothrow @nogc => opened;

        /// The requested selectors (parallel to a row's `values`).
        const(string)[] names() const @safe pure nothrow @nogc => selectors_;

        /// The bare reason raw counting is unavailable.
        private string rawAbsence() const @safe pure nothrow @nogc
        {
            if (!requested)
                return "not requested";
            return "perf_event_open refused raw events — perf_event_paranoid?";
        }

        /// Human-readable availability, for a report header.
        string status() const @safe pure nothrow
            => opened
                ? "raw hardware events (PERF_TYPE_RAW)"
                : "unavailable (" ~ rawAbsence() ~ ")";

        /// What this backend can deliver: raw/µarch event selectors. A
        /// successful permission probe counts — the capability exists even
        /// when no event was named this run.
        CapabilityReport capabilities() const @safe pure nothrow
        {
            if (opened || probeOk)
                return CapabilityReport(Capability.countingRaw, null);
            return CapabilityReport(Capability.none,
                [CapabilityAbsence(Capability.countingRaw, rawAbsence())]);
        }

        /// Opens one group over `events` (first opened event = leader) unless
        /// disabled. An event the kernel refuses gets a `-1` fd (its column
        /// reads `nan`); no event opening at all leaves the group unavailable.
        /// With an empty `events` list, a lone config-0 probe answers "would
        /// raw events open on this host?" and is closed again.
        static RawGroup tryOpen(bool enabled, const(RawEvent)[] events) @safe
        {
            RawGroup g;
            g.requested = enabled;
            if (!enabled)
                return g;
            if (!events.length)
            {
                const fd = openRaw(0, -1);
                g.probeOk = fd >= 0;
                if (fd >= 0)
                    (() @trusted => posixClose(fd))();
                return g;
            }
            if (events.length > maxEvents)
                events = events[0 .. maxEvents];
            g.fds = new int[](events.length);
            g.fds[] = -1;
            auto sels = new string[](events.length);
            int leader = -1;
            foreach (i, ref ev; events)
            {
                sels[i] = ev.selector;
                const fd = openRaw(ev.config, leader);
                g.fds[i] = fd;
                if (fd >= 0)
                {
                    g.nOpen++;
                    if (leader < 0)
                        leader = fd;
                }
            }
            g.selectors_ = sels;
            g.opened = leader >= 0;
            g.probeOk = g.opened;
            return g;
        }

        /// Opens one raw event; `leader` is `-1` for the group leader.
        private static int openRaw(ulong config, int leader) @safe
        {
            perf_event_attr attr;
            attr.size = perf_event_attr.sizeof;
            attr.type = perf_type_id.PERF_TYPE_RAW;
            attr.config = config;
            attr.disabled = leader < 0;
            attr.exclude_hv = 1;
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

        /// The counting pass: brackets each `timed()` with `ENABLE`/`DISABLE`
        /// so `between()` runs uncounted, then reads the group. Returns
        /// per-iteration averages scaled by the pass's own time deltas.
        RawStats count(Timed, Between)(scope Timed timed, scope Between between,
            uint iters)
        in (iters > 0)
        {
            import sparkles.test_runner.perf_group : bracketCountingPass, readScaledGroup;

            int leaderFd = -1;
            foreach (fd; fds)
                if (fd >= 0)
                {
                    leaderFd = fd;
                    break;
                }

            RawStats s;
            s.iters = iters;
            s.selectors = selectors_;
            s.values = new double[](selectors_.length);
            s.values[] = double.nan;
            if (leaderFd < 0)
                return s;

            const base = bracketCountingPass(leaderFd, timed, between, iters);

            double[maxEvents] values;
            if (!readScaledGroup(leaderFd, nOpen, iters, s.scale, values[], base))
                return s;

            size_t slot;
            foreach (i; 0 .. selectors_.length)
                if (fds[i] >= 0)
                    s.values[i] = values[slot++];
            return s;
        }
    }

    @("raw.RawGroup.countRetiredInstructions")
    @system
    unittest
    {
        import sparkles.test_runner.skip : skipTest;

        // Event select 0xC0 = retired instructions on both AMD and Intel x86.
        version (X86_64)
            enum selector = "r00c0";
        else
            enum selector = "r0";

        RawEvent ev;
        assert(parseRawEvent(selector, ev));
        auto g = RawGroup.tryOpen(true, [ev]);
        scope (exit)
            g.close();
        if (!g.available)
            skipTest(g.status());
        assert(g.capabilities.has(Capability.countingRaw));

        static ulong sink;
        const s = g.count(() {
            foreach (i; 0 .. 10_000)
                sink += i * i;
        }, () {}, 5);
        assert(s.iters == 5);
        assert(s.selectors == [selector]);
        version (X86_64)
        {
            import std.math : isNaN;

            // ~30k+ retired instructions per iteration; anything clearly
            // nonzero proves the plumbing (exact value is µarch-dependent).
            if (!s.values[0].isNaN)
                assert(s.values[0] > 1000);
        }
    }
}
else
{
    /// Non-Linux stub: raw counters are permanently unavailable.
    struct RawGroup
    {
        private static immutable CapabilityAbsence[1] stubAbsence = [
            CapabilityAbsence(Capability.countingRaw, "not Linux"),
        ];

        bool available() const @safe pure nothrow @nogc => false;
        const(string)[] names() const @safe pure nothrow @nogc => null;
        string status() const @safe pure nothrow => "unavailable (not Linux)";
        CapabilityReport capabilities() const @safe pure nothrow @nogc
            => CapabilityReport(Capability.none, stubAbsence[]);
        static RawGroup tryOpen(bool, const(RawEvent)[]) @safe pure nothrow @nogc
            => RawGroup();
        void close() @safe pure nothrow @nogc {}

        RawStats count(Timed, Between)(scope Timed, scope Between, uint)
        {
            assert(false, "raw counters are Linux-only");
        }
    }
}

// Whichever body the platform built (real or stub) satisfies the backend
// contract, including the optional named-columns primitive.
static assert(isCounterBackend!RawGroup);
static assert(hasNamedColumns!RawGroup);
static assert(!hasSnapshot!RawGroup);

@("raw.RawGroup.capabilities.notRequested")
@safe
unittest
{
    auto g = RawGroup.tryOpen(false, null);
    assert(!g.capabilities.has(Capability.countingRaw));
    version (linux)
        assert(g.capabilities.reasonFor(Capability.countingRaw) == "not requested");
    else
        assert(g.capabilities.reasonFor(Capability.countingRaw) == "not Linux");
}
