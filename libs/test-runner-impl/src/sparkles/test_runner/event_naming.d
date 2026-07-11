/**
 * Event-name resolution via libpfm4, as a **soft** dependency — the
 * `eventNaming` capability.
 *
 * A `--metrics=pfm:<name>` selector names a hardware event symbolically
 * (`RETIRED_INSTRUCTIONS`, `RETIRED_SSE_AVX_FLOPS:ADD_SUB_FLOPS`, generic
 * `PERF_COUNT_HW_CPU_CYCLES`, with `:u`/`:k` privilege modifiers); libpfm's
 * per-microarchitecture tables turn it into the `perf_event_attr`
 * `type`/`config`/`exclude_*` payload, which then rides the raw counter
 * group (`raw.d`) like any `raw:r<hex>` request. Encoding goes through
 * `PFM_OS_PERF_EVENT`, so privilege modifiers land in the attr's
 * `exclude_*` fields, not in config bits.
 *
 * libpfm is loaded with `dlopen` at first use — never linked — so a host
 * without it degrades to an advertised `eventNaming` absence and numeric
 * `raw:` selectors keep working. Two survey-verified hazards are encoded
 * (see `docs/research/cpu-pmu/event-naming.md` and the
 * `pfm4-name-roundtrip.d` probe):
 *
 * $(LIST
 *   * **Auto-detect lags silicon** — stock libpfm 4.13.0 does not detect
 *     this Zen 4 (family 25, model 0x61). `LIBPFM_ENCODE_INACTIVE=1` is set
 *     before `pfm_initialize` and a name that fails bare resolution is
 *     retried with the host's table prefix derived from `/proc/cpuinfo`
 *     (mirroring the fixed `amd64_get_revision`). `LIBPFM_FORCE_PMU` is
 *     deliberately not used — it is exclusive and breaks generic names.
 *   * **The 40-byte ABI check** — `pfm_perf_encode_arg_t` must be exactly
 *     40 bytes on LP64 (including the trailing pad) or every encode fails
 *     libpfm's size check; pinned by a `static assert`.
 * )
 */
module sparkles.test_runner.event_naming;

import sparkles.test_runner.capability : Capability, CapabilityAbsence,
    CapabilityReport;
import sparkles.test_runner.raw : RawEvent;

/// The libpfm core-PMU table name for an AMD `/proc/cpuinfo` (vendor, family,
/// model) triple — the CPUID mapping a fixed libpfm auto-detect would apply
/// (null = no hand-mapped table; bare resolution is the only path). Pure over
/// the file's text, so the mapping is fixture-testable.
string amdPmuTableName(const(char)[] cpuinfoText) @safe pure
{
    import std.algorithm.searching : startsWith;
    import std.conv : to;
    import std.string : lineSplitter, strip;

    const(char)[] vendor;
    int family = -1, model = -1;
    foreach (line; cpuinfoText.lineSplitter)
    {
        if (line.startsWith("vendor_id") && vendor is null)
            vendor = line["vendor_id".length .. $].strip(" \t:");
        else if (line.startsWith("cpu family") && family < 0)
        {
            try
                family = line["cpu family".length .. $].strip(" \t:").to!int;
            catch (Exception)
                return null;
        }
        else if (line.startsWith("model") && !line.startsWith("model name") && model < 0)
        {
            try
                model = line["model".length .. $].strip(" \t:").to!int;
            catch (Exception)
                return null;
        }
    }
    if (vendor != "AuthenticAMD" || family < 0 || model < 0)
        return null;
    switch (family)
    {
    case 23: // 17h
        return model >= 0x30 ? "amd64_fam17h_zen2" : "amd64_fam17h_zen1";
    case 25: // 19h
        return (model >= 0x60 || (model >= 0x10 && model <= 0x1f))
            ? "amd64_fam19h_zen4" : "amd64_fam19h_zen3";
    case 26: // 1ah
        return (model <= 0x4f || (model >= 0x60 && model <= 0x7f))
            ? "amd64_fam1ah_zen5" : "amd64_fam1ah_zen6";
    default:
        return null;
    }
}

@("eventNaming.amdPmuTableName.fixtures")
@safe pure
unittest
{
    enum zen4 = "vendor_id\t: AuthenticAMD\ncpu family\t: 25\nmodel\t\t: 97\nmodel name\t: AMD Ryzen 9 7940HX\n";
    assert(amdPmuTableName(zen4) == "amd64_fam19h_zen4");
    enum zen3 = "vendor_id\t: AuthenticAMD\ncpu family\t: 25\nmodel\t\t: 33\n";
    assert(amdPmuTableName(zen3) == "amd64_fam19h_zen3");
    enum intel = "vendor_id\t: GenuineIntel\ncpu family\t: 6\nmodel\t\t: 154\n";
    assert(amdPmuTableName(intel) is null);
    assert(amdPmuTableName("") is null);
    assert(amdPmuTableName("cpu family\t: junk\n") is null);
}

version (linux)
{
    import core.sys.linux.perf_event : perf_event_attr;
    import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;

    private enum PFM_OS_PERF_EVENT = 1; /// pfm_os_t: the perf_events layer
    private enum PFM_PLM0 = 0x01; /// privilege: kernel
    private enum PFM_PLM3 = 0x08; /// privilege: user
    private enum PFM_SUCCESS = 0;

    /// `pfm_perf_encode_arg_t` (pfmlib_perf_event.h) — 40 bytes on LP64
    /// including the trailing pad; libpfm ABI-checks the size field.
    private struct pfm_perf_encode_arg_t
    {
        perf_event_attr* attr;
        char** fstr;
        size_t size;
        int idx;
        int cpu;
        int flags;
        int pad0;
    }

    static assert(pfm_perf_encode_arg_t.sizeof == 40,
        "pfm_perf_encode_arg_t must match PFM_PERF_ENCODE_ABI0 (40 bytes on LP64)");

    private alias PfmInitialize = extern (C) int function() nothrow @nogc;
    private alias PfmGetOsEventEncoding =
        extern (C) int function(const(char)*, int, int, void*) nothrow @nogc;
    private alias PfmStrerror = extern (C) const(char)* function(int) nothrow @nogc;

    /// The dlopen-ed libpfm surface. `tryLoad` once per run; unusable hosts
    /// yield `available == false` and a reasoned capability absence.
    struct PfmResolver
    {
        private PfmInitialize pfmInitialize;
        private PfmGetOsEventEncoding pfmGetOsEventEncoding;
        private PfmStrerror pfmStrerror;
        private bool loaded;
        private bool initialized;
        private string tablePrefix; /// host µarch table ("" = none known)

        /// Whether names can be resolved on this host.
        bool available() const @safe pure nothrow @nogc => initialized;

        /// Human-readable availability, for a report header.
        string status() const @safe pure nothrow @nogc
        {
            if (initialized)
                return "libpfm4 event-name tables";
            if (loaded)
                return "unavailable (pfm_initialize failed)";
            return "unavailable (libpfm not found — dlopen libpfm.so.4)";
        }

        /// What the resolver delivers: symbolic event names.
        CapabilityReport capabilities() const @safe pure nothrow
        {
            if (initialized)
                return CapabilityReport(Capability.eventNaming, null);
            return CapabilityReport(Capability.none,
                [CapabilityAbsence(Capability.eventNaming,
                    loaded ? "pfm_initialize failed"
                        : "libpfm not found (dlopen libpfm.so.4) — raw:r<hex> selectors still work")]);
        }

        /// Loads and initializes libpfm; every failure degrades. The
        /// `LIBPFM_ENCODE_INACTIVE` workaround must precede `pfm_initialize`
        /// (survey hazard: 4.13.0 does not auto-detect recent silicon).
        static PfmResolver tryLoad() @trusted nothrow
        {
            import core.sys.posix.stdlib : setenv;

            PfmResolver r;
            auto lib = dlopen("libpfm.so.4", RTLD_NOW | RTLD_LOCAL);
            if (lib is null)
                lib = dlopen("libpfm.so", RTLD_NOW | RTLD_LOCAL);
            if (lib is null)
                return r;
            r.pfmInitialize = cast(PfmInitialize) dlsym(lib, "pfm_initialize");
            r.pfmGetOsEventEncoding =
                cast(PfmGetOsEventEncoding) dlsym(lib, "pfm_get_os_event_encoding");
            r.pfmStrerror = cast(PfmStrerror) dlsym(lib, "pfm_strerror");
            if (r.pfmInitialize is null || r.pfmGetOsEventEncoding is null)
                return r;
            r.loaded = true;
            setenv("LIBPFM_ENCODE_INACTIVE", "1", 1);
            if (r.pfmInitialize() != PFM_SUCCESS)
                return r;
            r.initialized = true;
            r.tablePrefix = hostTableName();
            return r;
        }

        /// Resolves one symbolic name to a raw event (id `pfm:<name>`). A
        /// bare name that libpfm's stale auto-detect cannot find is retried
        /// with the host's table prefix. Returns false with a reason.
        bool resolve(string name, out RawEvent ev, out string error) @trusted
        {
            import std.algorithm.searching : canFind;

            if (!initialized)
            {
                error = status();
                return false;
            }
            perf_event_attr attr;
            if (encode(name, attr) == PFM_SUCCESS)
            {
                ev = toRawEvent(name, attr);
                return true;
            }
            if (tablePrefix.length && !name.canFind("::"))
            {
                const prefixed = tablePrefix ~ "::" ~ name;
                if (encode(prefixed, attr) == PFM_SUCCESS)
                {
                    ev = toRawEvent(name, attr);
                    return true;
                }
            }
            const rc = encode(name, attr); // re-encode for the error text
            error = errorText(rc);
            return false;
        }

        private int encode(string name, ref perf_event_attr attr) @trusted
        {
            attr = perf_event_attr.init;
            attr.size = perf_event_attr.sizeof;
            pfm_perf_encode_arg_t arg;
            arg.attr = &attr;
            arg.size = pfm_perf_encode_arg_t.sizeof;
            return pfmGetOsEventEncoding((name ~ '\0').ptr,
                PFM_PLM0 | PFM_PLM3, PFM_OS_PERF_EVENT, &arg);
        }

        private static RawEvent toRawEvent(string name, in perf_event_attr attr)
            @safe pure nothrow
            => RawEvent("pfm:" ~ name, attr.config, attr.type,
                attr.exclude_user != 0, attr.exclude_kernel != 0);

        private string errorText(int rc) @trusted
        {
            import core.stdc.string : strlen;

            if (pfmStrerror !is null)
                if (auto p = pfmStrerror(rc))
                    return p[0 .. strlen(p)].idup;
            import sparkles.base.smallbuffer : SmallBuffer;
            import sparkles.base.text.writers : writeInteger;

            SmallBuffer!(char, 32) buf;
            buf ~= "pfm error ";
            writeInteger(buf, rc);
            return buf[].idup;
        }
    }

    /// The host's µarch table name from the live `/proc/cpuinfo`.
    private string hostTableName() @safe nothrow
    {
        import std.file : readText;

        try
            return amdPmuTableName(readText("/proc/cpuinfo"));
        catch (Exception)
            return null;
    }

    @("eventNaming.PfmResolver.resolve")
    @system
    unittest
    {
        import sparkles.test_runner.skip : skipTest;

        auto r = PfmResolver.tryLoad();
        if (!r.available)
            skipTest(r.status());

        RawEvent ev;
        string err;
        // The generic name resolves on every host libpfm supports.
        assert(r.resolve("PERF_COUNT_HW_CPU_CYCLES", ev, err), err);
        assert(ev.id == "pfm:PERF_COUNT_HW_CPU_CYCLES");
        assert(ev.type == 0, "generic names map to PERF_TYPE_HARDWARE");

        // A privilege modifier lands in exclude_*, not in config.
        if (r.resolve("PERF_COUNT_HW_CPU_CYCLES:u", ev, err))
            assert(ev.excludeKernel && !ev.excludeUser);

        assert(!r.resolve("NO_SUCH_EVENT_ANYWHERE", ev, err));
        assert(err.length);
    }
}
else
{
    /// Non-Linux stub: name resolution is Linux-only (libpfm has no other
    /// OS layer).
    struct PfmResolver
    {
        private static immutable CapabilityAbsence[1] stubAbsence = [
            CapabilityAbsence(Capability.eventNaming, "not Linux"),
        ];

        bool available() const @safe pure nothrow @nogc => false;
        string status() const @safe pure nothrow @nogc => "unavailable (not Linux)";
        CapabilityReport capabilities() const @safe pure nothrow @nogc
            => CapabilityReport(Capability.none, stubAbsence[]);
        static PfmResolver tryLoad() @safe pure nothrow @nogc => PfmResolver();

        bool resolve(string, out RawEvent, out string error) @safe pure nothrow
        {
            error = "unavailable (not Linux)";
            return false;
        }
    }
}

/// The naming capability block for `CounterGroups.capabilities` — the load
/// probe runs once per thread and is cached (the resolver used for actual
/// resolution is separate state).
CapabilityReport namingCapabilities() @safe nothrow
{
    static bool probed;
    static CapabilityReport cached;
    if (!probed)
    {
        cached = PfmResolver.tryLoad().capabilities;
        probed = true;
    }
    return cached;
}
