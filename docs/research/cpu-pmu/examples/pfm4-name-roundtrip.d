#!/usr/bin/env dub
/+ dub.sdl:
    name "cpu_pmu_pfm4_name_roundtrip"
    platforms "linux"
    libs "pfm"
    targetPath "build"
+/
/**
 * libpfm4 human-name → `perf_event_attr.{type,config}` round trip, then live count.
 *
 * The *event-naming & encoding* concern of the analysis spine, exercised end to
 * end on this host. libpfm4 is the name-resolution layer under `perf`, PAPI, and
 * many profilers: it owns per-microarchitecture event tables and turns a symbolic
 * string into the `type`/`config`/`exclude_*` fields the `perf_event_open(2)` ABI
 * expects. This probe:
 *
 *   1. `pfm_get_os_event_encoding(str, …, PFM_OS_PERF_EVENT, &arg)` with `arg.attr`
 *      pointing at druntime's `perf_event_attr` — the same struct `perf_event_open`
 *      consumes — so libpfm fills it directly (no hand-built encodings).
 *   2. Encodes four names spanning the naming layers and prints the resulting
 *      `type`/`config` hex plus the fully-qualified string libpfm echoes back:
 *        - `PERF_COUNT_HW_CPU_CYCLES` — a *generic* perf name → `PERF_TYPE_HARDWARE`
 *          (type 0), config 0: the OS-abstracted event, portable across vendors.
 *        - `RETIRED_INSTRUCTIONS` — a *Zen 4-specific* name from libpfm's
 *          `amd64_fam19h_zen4` table → `PERF_TYPE_RAW` (type 4), config `0xc0`
 *          (the raw AMD PMC event-select), proving the per-µarch table is what
 *          supplies the bits.
 *        - `RETIRED_SSE_AVX_FLOPS:ADD_SUB_FLOPS` — a name carrying a *unit mask* →
 *          the umask lands in config bits [15:8] (`0x103`), showing libpfm's
 *          `event:umask` grammar.
 *        - `RETIRED_INSTRUCTIONS:u` — a name carrying a *modifier* → config is
 *          unchanged (`0xc0`) but `attr.exclude_kernel` is set: user/kernel/hv
 *          filtering is lifted OUT of the raw config into the perf_event ABI's
 *          `exclude_*` fields (`pfm_amd64_get_perf_encoding` zeroes the OS/USR
 *          MSR bits; the common perf layer sets the attr fields). This split is
 *          the whole reason `PFM_OS_PERF_EVENT` exists.
 *   3. `perf_event_open`s each encoding on the calling thread and counts a fixed
 *      workload window (integer mixing + scalar SSE FP), proving the encodings
 *      are *live*, not just plausible.
 *
 * Auto-detect caveat (source-verified, load-bearing): stock **libpfm 4.13.0**
 * (the current nixpkgs build) does NOT auto-detect this CPU's core PMU. Its
 * family-19h detect (`lib/pfmlib_amd64.c`) maps only `model == 0x11` to Zen 4, so
 * the Ryzen 9 7940HX (family 25/`0x19`, model **0x61**, Dragon Range) matches no
 * branch, `revision` stays `PFM_PMU_NONE`, and only the software `perf`/`perf_raw`
 * PMUs activate — a bare `pfm_get_os_event_encoding("RETIRED_INSTRUCTIONS", …)`
 * then returns `PFM_ERR_NOTFOUND` (-4). libpfm git HEAD fixes this (`model >= 0x60`).
 * To stay robust we (a) derive the correct table name from `/proc/cpuinfo`
 * ourselves — exactly what a fixed `detect()` would pick — and address events with
 * the explicit `amd64_fam19h_zen4::` prefix, and (b) set `LIBPFM_ENCODE_INACTIVE=1`
 * before `pfm_initialize`, which places even un-detected tables on the searchable
 * list. The lesson for a backend: do not trust libpfm auto-detect on very recent
 * silicon — force the PMU by a name you resolve from CPUID, or require a new libpfm.
 *
 * Companion to docs/research/cpu-pmu/event-naming.md
 *   § "libpfm4: the name→encoding pipeline" and § "The OS-layer split".
 *
 * Run with (nixpkgs libpfm has no pkg-config .pc, and `nix shell` does not run
 * setup hooks, so feed its lib dir through LIBRARY_PATH/LD_LIBRARY_PATH):
 *
 *   P=$(nix eval --raw nixpkgs#libpfm)/lib; \
 *   env LIBRARY_PATH="$P:$LIBRARY_PATH" LD_LIBRARY_PATH="$P:$LD_LIBRARY_PATH" \
 *       dub run --single pfm4-name-roundtrip.d
 *
 * (Adding `libpfm` to the flake devShell's buildInputs would let a plain
 * `dub run --single` resolve `libs "pfm"` via NIX_LDFLAGS — the intended CI path.)
 *
 * Environment recorded: Linux 6.18.26, AMD Ryzen 9 7940HX (Zen 4, family 25 /
 * model 0x61), `/proc/sys/kernel/perf_event_paranoid` = -1, libpfm 4.13.0
 * (nixpkgs), LDC 1.41 druntime `core.sys.linux.perf_event`.
 *
 * Portability: on a host without libpfm the build fails to link (libpfm is a
 * link-time dependency, like `libdw` in the sibling probes). At runtime, a raised
 * `perf_event_paranoid`, a non-AMD CPU, or any `perf_event_open` failure prints a
 * `SKIP:` line and exits 0 so CI stays green on any host.
 */
module cpu_pmu_pfm4_name_roundtrip;

version (linux)
{
    import core.sys.linux.perf_event : perf_event_attr, perf_event_open,
        perf_type_id, perf_event_read_format, PERF_EVENT_IOC_RESET,
        PERF_EVENT_IOC_ENABLE, PERF_EVENT_IOC_DISABLE;
    import core.sys.posix.unistd : read, close;
    import core.sys.posix.sys.ioctl : ioctl;
    import core.sys.posix.stdlib : setenv;
    import core.stdc.config : c_ulong;
    import core.stdc.string : strlen;
    import std.stdio : writefln, writeln;
    import std.string : lineSplitter, startsWith, strip;

    // ---- libpfm4 (extern(C), verified against $REPOS/c/libpfm4@6870a9f0
    //      include/perfmon/pfmlib.h + pfmlib_perf_event.h) --------------------
    enum PFM_OS_PERF_EVENT = 1; // pfm_os_t: perf_events attribute subset + PMU
    enum PFM_PLM0 = 0x01;       // priv level 0 (kernel)
    enum PFM_PLM3 = 0x08;       // priv level 3/2/1 (user)
    enum PFM_SUCCESS = 0;

    /// `pfm_perf_encode_arg_t` (pfmlib_perf_event.h): 40 bytes on LP64.
    struct pfm_perf_encode_arg_t
    {
        perf_event_attr* attr; // in/out: the struct libpfm fills
        char** fstr;           // out: fully-qualified event string
        size_t size;           // sizeof(*this) — libpfm ABI-checks this
        int idx;               // out: opaque event id
        int cpu;               // out: cpu to program, -1 = unset
        int flags;             // out: perf_event_open flags
        int pad0;
    }

    extern (C) int pfm_initialize();
    extern (C) int pfm_get_version();
    extern (C) const(char)* pfm_strerror(int);
    extern (C) int pfm_get_os_event_encoding(const(char)*, int, int, void*);

    string cstr(const(char)* p) @trusted =>
        p is null ? "(null)" : cast(string) p[0 .. strlen(p)];

    /// Result of one encode.
    struct Encoded
    {
        bool ok;
        int err;            // pfm_err_t when !ok
        perf_event_attr attr;
        string fstr;
    }

    /// Name → `perf_event_attr` via libpfm. Counting at both priv levels
    /// (PLM0|PLM3) is the default; per-name `:u`/`:k` modifiers override it.
    Encoded encode(string name) @trusted
    {
        Encoded e;
        e.attr.size = perf_event_attr.sizeof;
        char* fstr;
        pfm_perf_encode_arg_t arg;
        arg.attr = &e.attr;
        arg.fstr = &fstr;
        arg.size = pfm_perf_encode_arg_t.sizeof;
        const r = pfm_get_os_event_encoding(
            (name ~ '\0').ptr, PFM_PLM0 | PFM_PLM3, PFM_OS_PERF_EVENT, &arg);
        e.err = r;
        e.ok = r == PFM_SUCCESS;
        if (e.ok)
            e.fstr = cstr(fstr).idup;
        return e;
    }

    // ---- perf_event_open counting (mirrors counting-group.d) ----------------
    void ctl(int fd, uint request) @trusted => cast(void) ioctl(fd, cast(c_ulong) request, 0);
    long readN(int fd, ulong[] buf) @trusted => read(fd, buf.ptr, buf.length * ulong.sizeof);

    /// A fixed workload: integer mixing (retired instructions) plus scalar SSE
    /// double arithmetic (SSE/AVX FLOPS — one multiply and one add per iter).
    /// `__gshared` sinks defeat dead-code elimination.
    __gshared ulong iSink;
    __gshared double fSink;
    void workload()
    {
        ulong acc = 0x9E3779B97F4A7C15UL;
        double f = 1.0;
        foreach (i; 0 .. 3_000_000UL)
        {
            acc = (acc + i) * 2654435761UL ^ (acc >> 13);
            f = f * 1.0000000001 + 0.5; // 1 MULT + 1 ADD_SUB FLOP
        }
        iSink += acc;
        fSink += f;
    }

    /// Open the already-encoded `attr` on this thread (pid 0, any cpu), run the
    /// workload, and return the multiplexing-scaled count, or `ulong.max` on
    /// failure. Adds the two time fields so a rotated counter still scales.
    ulong countWith(ref perf_event_attr attr) @trusted
    {
        attr.read_format = perf_event_read_format.PERF_FORMAT_TOTAL_TIME_ENABLED
            | perf_event_read_format.PERF_FORMAT_TOTAL_TIME_RUNNING;
        attr.disabled = 1;
        attr.exclude_hv = 1;
        const fd = cast(int) perf_event_open(&attr, 0, -1, -1, 0);
        if (fd < 0)
            return ulong.max;
        ctl(fd, PERF_EVENT_IOC_RESET);
        ctl(fd, PERF_EVENT_IOC_ENABLE);
        workload();
        ctl(fd, PERF_EVENT_IOC_DISABLE);
        ulong[3] s; // value, time_enabled, time_running
        const got = readN(fd, s[]);
        close(fd);
        if (got < cast(long)(3 * ulong.sizeof) || s[2] == 0)
            return ulong.max;
        return s[2] < s[1] ? cast(ulong)(s[0] * (cast(double) s[1] / s[2])) : s[0];
    }

    /// Report one name: encode, print type/config/exclude, then count.
    void report(string label, string name) @trusted
    {
        auto e = encode(name);
        if (!e.ok)
        {
            writefln("  %-13s %-42s ENCODE FAILED: %s (%d)",
                label, name, cstr(pfm_strerror(e.err)), e.err);
            return;
        }
        auto attr = e.attr; // copy: countWith mutates read_format/flags
        const cnt = countWith(attr);
        writefln("  %-13s %s", label, name);
        writefln("        type=%d config=0x%x  exclude_user=%d exclude_kernel=%d",
            e.attr.type, e.attr.config, e.attr.exclude_user, e.attr.exclude_kernel);
        writefln("        fstr=%s", e.fstr);
        if (cnt == ulong.max)
            writefln("        count: <perf_event_open/read failed on this host>");
        else
            writefln("        count over workload window: %d", cnt);
    }

    /// Map /proc/cpuinfo (vendor + family + model) to the libpfm core-PMU table
    /// name — mirroring the *fixed* `amd64_get_revision` (libpfm HEAD). Returns
    /// null for anything this probe does not have a hand table for (non-AMD, or
    /// an AMD family we don't enumerate) → the µarch-specific section is skipped.
    string amdPmuName() @trusted
    {
        import std.conv : to;

        string vendor;
        int family = -1, model = -1;
        try
        {
            import std.file : readText;

            foreach (line; readText("/proc/cpuinfo").lineSplitter)
            {
                if (line.startsWith("vendor_id") && vendor is null)
                    vendor = line["vendor_id".length .. $].strip(" \t:").idup;
                else if (line.startsWith("cpu family") && family < 0)
                    family = line["cpu family".length .. $].strip(" \t:").to!int;
                else if (line.startsWith("model") && !line.startsWith("model name") && model < 0)
                    model = line["model".length .. $].strip(" \t:").to!int;
            }
        }
        catch (Exception)
            return null;
        if (vendor != "AuthenticAMD")
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

    int run()
    {
        // Work around libpfm 4.13.0's auto-detect gap (see the header): place
        // un-detected per-µarch tables on the searchable list so an explicit
        // `pmu::event` prefix resolves. Must precede pfm_initialize.
        setenv("LIBPFM_ENCODE_INACTIVE", "1", 1);

        const initRc = pfm_initialize();
        if (initRc != PFM_SUCCESS)
        {
            writefln("SKIP: pfm_initialize failed (%s) — libpfm unusable on this host",
                cstr(pfm_strerror(initRc)));
            return 0;
        }
        const v = pfm_get_version();
        writefln("libpfm interface version %d.%d (release: see nixpkgs libpfm)",
            v >> 16, v & 0xffff);

        // --- Generic (OS-abstracted) name: resolves via the always-present
        //     `perf` PMU regardless of hardware. ---
        writeln("\n== generic perf name (PERF_TYPE_HARDWARE) ==");
        report("generic", "PERF_COUNT_HW_CPU_CYCLES");

        // Probe whether we can count at all; if the generic open failed for
        // permission reasons, everything else will too.
        {
            auto probe = encode("PERF_COUNT_HW_CPU_CYCLES");
            if (probe.ok)
            {
                auto a = probe.attr;
                if (countWith(a) == ulong.max)
                {
                    writefln("SKIP: perf_event_open failed — perf_event_paranoid too high, "
                        ~ "seccomp, or no PMU on this host");
                    return 0;
                }
            }
        }

        // --- Microarchitecture-specific names via the host's libpfm table. ---
        const pmu = amdPmuName();
        if (pmu is null)
        {
            writeln("\n== µarch-specific names: SKIPPED (no hand table for this CPU; "
                ~ "generic path above still demonstrates the round trip) ==");
            return 0;
        }
        writefln("\n== µarch-specific names via the %s table (PERF_TYPE_RAW) ==", pmu);
        report("zen4-native", pmu ~ "::RETIRED_INSTRUCTIONS");
        report("with-umask", pmu ~ "::RETIRED_SSE_AVX_FLOPS:ADD_SUB_FLOPS");
        report("with-modifier", pmu ~ "::RETIRED_INSTRUCTIONS:u");
        writeln("\n  (config unchanged between native and :u — user/kernel filtering "
            ~ "moved into attr.exclude_*, the PFM_OS_PERF_EVENT split.)");
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

        writefln("SKIP: libpfm4 / perf_event_open is Linux-only");
        return 0;
    }
}
