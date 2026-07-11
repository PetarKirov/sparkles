/**
 * The capability seam: what can this host measure, as a first-class value.
 *
 * Every acquisition backend advertises a `CapabilityReport` after its open
 * handshake — one `Capability` flag per survey concern, with a reasoned
 * `CapabilityAbsence` entry for everything it cannot deliver on this host,
 * this run. Capability is a *runtime probe result*, never a compile-time
 * assumption: the same binary reports differently under a hardened
 * `perf_event_paranoid`, a root-only tracefs, or a PMU-less container.
 *
 * `isCounterBackend` names the instance contract `CounterGroups` has always
 * demanded of a tier (`available`/`status`/`capabilities`/`close`/`count`);
 * optional primitives (`hasSnapshot`, `hasNamedColumns`) unlock optional
 * behavior by presence, per the DbI guidelines. Construction is deliberately
 * outside the trait — `tryOpen` arity varies per tier (perf: `bool`;
 * syscalls: `bool` + names) and stays a per-tier concern of
 * `CounterGroups.open`.
 *
 * The evidence base is the CPU-PMU research catalog
 * (`docs/research/cpu-pmu/backend-proposal.md` §2); the shipped shapes
 * deviate from its sketch where the real surface demanded it (see
 * `docs/specs/test-runner/SPEC.md` §6.2).
 */
module sparkles.test_runner.capability;

/// One flag per survey concern (plus real-world sub-splits). Advertised per
/// backend instance after its open handshake.
enum Capability : uint
{
    none            = 0,
    counting        = 1 << 0, /// concern 1: scalar counting
    countingRaw     = 1 << 1, ///   + raw/µarch event selectors
    countingScaled  = 1 << 2, ///   + multiplexed estimates (labeled)
    selfMonitoring  = 1 << 3, ///   + user-space reads (rdpmc/PMUSERENR)
    ipSampling      = 1 << 4, /// concern 2: overflow/IP sampling
    preciseMemory   = 1 << 5, /// concern 3: data-source/address sampling
    symbolization   = 1 << 6, /// concern 4: address → symbol/line
    eventTracing    = 1 << 7, /// concern 5: OS-event gating (tracepoints/ETW)
    numaAttribution = 1 << 8, /// concern 6: page → node classification
    eventNaming     = 1 << 9, /// concern 7: name → encoding tables
}

/// Every single-flag member in declaration order — the deterministic order
/// reports render in.
static immutable Capability[10] allCapabilities = [
    Capability.counting, Capability.countingRaw, Capability.countingScaled,
    Capability.selfMonitoring, Capability.ipSampling, Capability.preciseMemory,
    Capability.symbolization, Capability.eventTracing,
    Capability.numaAttribution, Capability.eventNaming,
];

/// The stable name of one flag. A combined mask is a caller bug — callers
/// iterate `allCapabilities` and name flags one at a time.
string capabilityName(Capability c) @safe pure nothrow @nogc
{
    final switch (c)
    {
        case Capability.none:            return "none";
        case Capability.counting:        return "counting";
        case Capability.countingRaw:     return "countingRaw";
        case Capability.countingScaled:  return "countingScaled";
        case Capability.selfMonitoring:  return "selfMonitoring";
        case Capability.ipSampling:      return "ipSampling";
        case Capability.preciseMemory:   return "preciseMemory";
        case Capability.symbolization:   return "symbolization";
        case Capability.eventTracing:    return "eventTracing";
        case Capability.numaAttribution: return "numaAttribution";
        case Capability.eventNaming:     return "eventNaming";
    }
}

@("capability.capabilityName.everyMember")
@safe pure nothrow @nogc
unittest
{
    foreach (c; allCapabilities)
        assert(capabilityName(c).length > 4);
    assert(capabilityName(Capability.none) == "none");
    assert(capabilityName(Capability.preciseMemory) == "preciseMemory");
}

/// One absent capability with its host-grounded reason.
struct CapabilityAbsence
{
    Capability capability; /// exactly one flag
    string reason;         /// e.g. "tracefs event ids unreadable — usually root"
}

/// What a backend can deliver on this host, this run: the present flags OR-ed
/// together, and a reasoned entry per absent flag (in `allCapabilities`
/// order). A flag mentioned in neither is outside the backend's domain.
struct CapabilityReport
{
    Capability available;                /// OR of the present flags
    const(CapabilityAbsence)[] absences; /// absent flags with reasons
}

/// Whether `flag` is advertised present.
bool has(in CapabilityReport r, Capability flag) @safe pure nothrow @nogc
    => (r.available & flag) != 0;

/// The reason `flag` is absent; `null` when present or outside the report's
/// domain. (Returning the second-level slice out of an `in` report is legal
/// under dip1000 — `scope` is non-transitive; a helper returning the
/// first-level `absences` slice itself would not compile.)
string reasonFor(in CapabilityReport r, Capability flag) @safe pure nothrow @nogc
{
    foreach (ref a; r.absences)
        if (a.capability == flag)
            return a.reason;
    return null;
}

@("capability.CapabilityReport.hasAndReasonFor")
@safe pure nothrow @nogc
unittest
{
    static immutable CapabilityAbsence[2] absences = [
        CapabilityAbsence(Capability.eventTracing, "tracefs unreadable"),
        CapabilityAbsence(Capability.preciseMemory, "no engine"),
    ];
    const r = CapabilityReport(Capability.counting, absences[]);
    assert(r.has(Capability.counting));
    assert(!r.has(Capability.eventTracing));
    assert(r.reasonFor(Capability.eventTracing) == "tracefs unreadable");
    assert(r.reasonFor(Capability.preciseMemory) == "no engine");
    assert(r.reasonFor(Capability.counting) is null, "present flags carry no reason");
    assert(r.reasonFor(Capability.eventNaming) is null, "outside the domain");
}

/// One backend's labeled report — the element `CounterGroups.capabilities`
/// yields. Labels use the metric catalog's `source` vocabulary (`"perf"`,
/// `"tier0"`, `"syscall"`) plus `"harness"` for concerns no backend owns yet.
struct BackendCapabilities
{
    string backend;
    CapabilityReport report;
}

/// Concerns no shipped backend owns yet, reported harness-level so the
/// vocabulary is complete; B5/B6 move these into their backends.
CapabilityReport harnessPendingCapabilities() @safe pure nothrow @nogc
    => CapabilityReport(Capability.none, harnessPending[]);

private static immutable CapabilityAbsence[2] harnessPending = [
    CapabilityAbsence(Capability.symbolization,
        "address → symbol/line resolution lands in B6 (elfutils)"),
    CapabilityAbsence(Capability.numaAttribution,
        "page → NUMA-node classification lands in B5 (move_pages)"),
];

@("capability.harnessPendingCapabilities.shape")
@safe pure nothrow @nogc
unittest
{
    const r = harnessPendingCapabilities();
    assert(r.available == Capability.none);
    assert(r.reasonFor(Capability.symbolization) !is null);
    assert(r.reasonFor(Capability.numaAttribution) !is null);
}

/**
 * The required backend surface — `CounterGroups`' implicit per-tier contract
 * made nameable: const-callable probe observers (`available`, `status`,
 * `capabilities`), resource release, and the bracketed counting pass
 * returning that backend's row-stats value. The return type of `count` is
 * deliberately unconstrained (it differs per tier), as are attributes
 * (`count` is a template with inferred attributes).
 */
enum bool isCounterBackend(B) = __traits(compiles, {
    B b;
    const B c;
    bool a = c.available;
    string s = c.status;
    CapabilityReport r = c.capabilities;
    b.close();
    auto stats = b.count(() {}, () {}, 1u); // auto rejects a void count
});

/// Optional: a cheap cumulative snapshot (the snapshot/delta source shape —
/// tier-0 today, the workload window model tomorrow). Presence, not
/// declaration, unlocks it.
enum bool hasSnapshot(B) = __traits(compiles, {
    B b;
    auto r = b.snapshot();
    static assert(!is(typeof(r) == void));
});

/// Optional: dynamic per-column names parallel to a row's counts (the
/// syscall tier's named tracepoints).
enum bool hasNamedColumns(B) = __traits(compiles, {
    const B b;
    const(string)[] n = b.names();
});

@("capability.isCounterBackend.detection")
@safe pure
unittest
{
    static struct Good
    {
        bool available() const => true;
        string status() const => "ok";
        CapabilityReport capabilities() const => CapabilityReport();
        void close() {}
        int count(Timed, Between)(scope Timed timed, scope Between between, uint iters) => 0;
    }

    static struct NoCapabilities
    {
        bool available() const => true;
        string status() const => "ok";
        void close() {}
        int count(Timed, Between)(scope Timed timed, scope Between between, uint iters) => 0;
    }

    static struct VoidCount
    {
        bool available() const => true;
        string status() const => "ok";
        CapabilityReport capabilities() const => CapabilityReport();
        void close() {}
        void count(Timed, Between)(scope Timed timed, scope Between between, uint iters) {}
    }

    static assert(isCounterBackend!Good);
    static assert(!isCounterBackend!NoCapabilities);
    static assert(!isCounterBackend!VoidCount, "a void count is not a counting pass");
    static assert(!hasSnapshot!Good && !hasNamedColumns!Good);
}

@("capability.optionalPrimitives.detection")
@safe pure
unittest
{
    static struct WithExtras
    {
        bool available() const => true;
        string status() const => "ok";
        CapabilityReport capabilities() const => CapabilityReport();
        void close() {}
        int count(Timed, Between)(scope Timed timed, scope Between between, uint iters) => 0;
        long snapshot() => 0;
        const(string)[] names() const => null;
    }

    static assert(isCounterBackend!WithExtras);
    static assert(hasSnapshot!WithExtras);
    static assert(hasNamedColumns!WithExtras);
}

// ---------------------------------------------------------------------------
// Host probes: cheap sysfs/procfs reads grounding absence reasons in host
// facts. Pure parsers up top (fixture-testable); the file reads degrade to
// "unknown" — a probe never fails a run.

/// A probed integer: `ok` is false when the file was unreadable or
/// unparsable (needed because -1 is a *valid* perf_event_paranoid value).
struct ProbedValue
{
    bool ok;
    long value;
}

/// Parses the first decimal integer (optional leading whitespace, optional
/// `-`) of a sysfs/procfs one-value file.
ProbedValue parseLongValue(const(char)[] content) @safe pure nothrow @nogc
{
    size_t i = 0;
    while (i < content.length && (content[i] == ' ' || content[i] == '\t' || content[i] == '\n'))
        i++;
    bool negative = false;
    if (i < content.length && content[i] == '-')
    {
        negative = true;
        i++;
    }
    bool any = false;
    long v = 0;
    while (i < content.length && content[i] >= '0' && content[i] <= '9')
    {
        v = v * 10 + (content[i] - '0');
        i++;
        any = true;
    }
    if (!any)
        return ProbedValue(false, 0);
    return ProbedValue(true, negative ? -v : v);
}

@("capability.parseLongValue.fixtures")
@safe pure nothrow @nogc
unittest
{
    assert(parseLongValue("-1\n") == ProbedValue(true, -1));
    assert(parseLongValue("2") == ProbedValue(true, 2));
    assert(parseLongValue(" 11") == ProbedValue(true, 11));
    assert(parseLongValue("") == ProbedValue(false, 0));
    assert(parseLongValue("abc") == ProbedValue(false, 0));
    assert(parseLongValue("-") == ProbedValue(false, 0));
    assert(parseLongValue("0\n") == ProbedValue(true, 0));
}

version (linux)
{
    /// Reads a small pseudo-file into `buf` via raw `open`/`read`/`close`
    /// (`std.file` reports size 0 for /proc and some /sys entries). The path
    /// must be null-terminated; returns the filled slice (empty on failure).
    private char[] readSmallFile(scope const(char)* path, return scope char[] buf) @safe nothrow @nogc
    {
        import core.sys.posix.fcntl : open, O_RDONLY;
        import core.sys.posix.unistd : read, close;

        const fd = (() @trusted => open(path, O_RDONLY))();
        if (fd < 0)
            return null;
        scope (exit)
            (() @trusted => close(fd))();
        const n = (() @trusted => read(fd, buf.ptr, buf.length))();
        return n > 0 ? buf[0 .. n] : null;
    }

    /// The perf `type` id of a named PMU (`/sys/bus/event_source/devices/
    /// <name>/type`), or -1 when the PMU is absent. An `ibs_op` entry is the
    /// AMD IBS precise-memory engine; `cpu` is the core PMU.
    long probePmuType(scope const(char)[] name) @safe nothrow @nogc
    {
        enum prefix = "/sys/bus/event_source/devices/";
        enum suffix = "/type";
        char[128] path = void;
        if (prefix.length + name.length + suffix.length + 1 > path.length)
            return -1;
        size_t n = 0;
        path[n .. n + prefix.length] = prefix;
        n += prefix.length;
        path[n .. n + name.length] = name;
        n += name.length;
        path[n .. n + suffix.length] = suffix;
        n += suffix.length;
        path[n] = '\0';
        char[32] buf = void;
        const content = readSmallFile(&path[0], buf[]);
        const parsed = parseLongValue(content);
        return parsed.ok ? parsed.value : -1;
    }

    /// Intel PEBS precision depth (`cpu/caps/max_precise`): 0 = none (AMD),
    /// -1 = unknown (file absent).
    long probeMaxPrecise() @safe nothrow @nogc
    {
        char[32] buf = void;
        const content = readSmallFile(
            "/sys/bus/event_source/devices/cpu/caps/max_precise", buf[]);
        const parsed = parseLongValue(content);
        return parsed.ok ? parsed.value : -1;
    }

    /// The kernel's `perf_event_paranoid` level (-1 … 4); `ok` false when
    /// unreadable.
    ProbedValue probeParanoid() @safe nothrow @nogc
    {
        char[32] buf = void;
        const content = readSmallFile("/proc/sys/kernel/perf_event_paranoid", buf[]);
        return parseLongValue(content);
    }

    @("capability.probePmuType.absentPmu")
    @safe
    unittest
    {
        assert(probePmuType("nonexistent-pmu") == -1);
        assert(probePmuType("a-name-far-too-long-to-fit-the-fixed-path-buffer-"
            ~ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") == -1);
    }

    @("capability.probeParanoid.hostRange")
    @system
    unittest
    {
        import sparkles.test_runner.skip : skipTest;

        const p = probeParanoid();
        if (!p.ok)
            skipTest("/proc/sys/kernel/perf_event_paranoid unreadable");
        assert(p.value >= -1 && p.value <= 4);
    }
}
else
{
    long probePmuType(scope const(char)[]) @safe pure nothrow @nogc => -1;
    long probeMaxPrecise() @safe pure nothrow @nogc => -1;
    ProbedValue probeParanoid() @safe pure nothrow @nogc => ProbedValue(false, 0);
}
