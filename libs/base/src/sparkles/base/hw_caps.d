/++
Hardware capability probing: how many workers this process may usefully run in
parallel ($(LREF hwParallelism)), and which CPUs it is actually permitted to run
on ($(LREF nthAllowedCpu)).

This is the single place the "how wide is this machine, for us" *decision* is
made, the same way
$(REF terminalSize, sparkles,base,term_caps) owns "how big is this terminal".
It lives in `sparkles:base` because it is an **environment query**: a thread
pool, an event-loop group and a test runner all need it, and none of them should
have to re-derive it.

$(B Why not `std.parallelism.totalCPUs`.) That answers "how many CPUs exist",
which is a different question from "how many may we use", and the two diverge in
ordinary deployments:

$(LIST
    * A container with a CPU quota (`cpu.max` under cgroup v2,
        `cpu.cfs_quota_us` under v1) is charged for more parallelism than it is
        allowed to consume, so an oversized pool just adds context switches and
        scheduler latency.
    * A process under a restricted affinity mask — `taskset`, a cpuset, a
        partitioned host — may not run on most of the CPUs it can see.
)

The second one is the sharper of the two, because it also breaks $(I pinning):
distributing workers round-robin over a CPU count includes CPUs the process
cannot run on, and pinning a thread to one of those is not a slow worker but a
stopped one. $(LREF nthAllowedCpu) exists so a caller pins $(I within) the mask
rather than within the count.

$(B Deliberately uncached.) Both answers can change under a running process, and
both are asked at worker start rather than in a hot path — so a syscall per call
is free and a stale cache is a bug waiting to happen. Nothing here re-reads, so
a mid-run affinity change is simply not observed.

$(B Memory and load are part of the same decision.) A CPU count is not "how
wide may we usefully run" on an overcommitted host. GitHub-hosted macOS VMs
are the motivating case: they advertise a handful of vCPUs and ~7–14 GiB of
RAM, and the hypervisor can steal both. Extra workers there do not go faster;
they compete for the same pages and start swapping. $(LREF hwParallelism)
therefore also consults available RAM, swap-in-use, and the 1-minute load
average (see $(LREF applyResourceCaps)). The probes are
$(LREF hwMemoryBytes), $(LREF hwAvailableMemoryBytes),
$(LREF hwSwapUsedBytes), and $(LREF hwLoadAverageCenti). Callers that know
their own working set (a compiler farm budgeting 2 GiB per job) still apply
a tighter cap on top.

$(B Not QoS-aware, yet.) On Apple silicon the kernel's answer is per-QoS: the
background class is confined to the efficiency cluster, so
`pthread_qos_max_parallelism` reports far fewer CPUs for it than for any other
class. Nothing in the repository assigns a QoS to a worker today, so a QoS
parameter would have exactly one caller passing exactly one value; the deferral
and its reasoning are recorded as `event-horizon`'s O30.
+/
module sparkles.base.hw_caps;

/**
How many workers this process may usefully run in parallel.

The smaller of "CPUs we are allowed to run on", "CPUs our quota pays for",
and the memory/load/swap cap ($(LREF applyResourceCaps)), never less than 1.
On a host with no restriction and no pressure this is the online CPU count,
so it is a safe drop-in for `std.parallelism.totalCPUs`.
*/
uint hwParallelism() @trusted nothrow @nogc
{
    const allowed = allowedCpuCount();
    const quota = quotaCpuCount();
    const n = quota > 0 && quota < allowed ? quota : allowed;
    const cpu = n > 0 ? n : 1;
    return applyResourceCaps(
        cpu, hwAvailableMemoryBytes(), hwLoadAverageCenti(), hwSwapUsedBytes());
}

/**
The `i`-th CPU this process is permitted to run on, for pinning.

`i` wraps, so a caller with more workers than CPUs distributes them round-robin
without doing its own modulo — and, unlike `i % totalCPUs`, every value it
returns is a CPU the process can actually be scheduled on.

$(B It wraps over the CPUs you may use, not over $(LREF hwParallelism).) The two
differ whenever a quota rather than an affinity mask is the binding constraint:
a 1.5-CPU quota on a 32-CPU host asks for two workers, and those two should land
on two $(I different) CPUs rather than both on CPU 0. Feeding a worker index
straight in does the right thing in either case.

Where the platform exposes no affinity mask (Darwin's thread-affinity API is an
advisory hint, and is ignored entirely on Apple silicon), this is the identity
and pinning is a no-op.
*/
uint nthAllowedCpu(uint i) @trusted nothrow @nogc
{
    version (linux)
    {
        import core.sys.linux.sched : CPU_ISSET, cpu_set_t, sched_getaffinity;

        cpu_set_t set;
        const n = allowedCpuCount();
        if (n > 0 && sched_getaffinity(0, cpu_set_t.sizeof, &set) == 0)
        {
            // Walk to the (i mod n)-th set bit. `__CPU_SETSIZE` bits is what
            // druntime's `cpu_set_t` covers; a CPU beyond it cannot be
            // represented and so cannot be selected.
            uint want = i % n;
            foreach (cpu; 0 .. cpuSetBits)
            {
                if (!CPU_ISSET(cpu, &set))
                    continue;
                if (want == 0)
                    return cast(uint) cpu;
                --want;
            }
        }
    }

    // No mask to honour: wrap over what exists, so the round-robin contract
    // holds on every platform even where pinning itself is a no-op.
    const online = onlineCpuCount();
    return online > 0 ? i % online : i;
}

/// Online CPUs the OS reports, or 0 when that cannot be answered.
uint hwOnlineCpuCount() @trusted nothrow @nogc => onlineCpuCount();

/// Total physical RAM in bytes, or 0 when unknown.
ulong hwMemoryBytes() @trusted nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.unistd : _SC_PAGESIZE, _SC_PHYS_PAGES, sysconf;

        const pages = sysconf(_SC_PHYS_PAGES);
        const page = sysconf(_SC_PAGESIZE);
        if (pages > 0 && page > 0)
            return cast(ulong) pages * cast(ulong) page;
    }
    return 0;
}

/**
Currently available RAM in bytes, or 0 when unknown.

Linux reads `MemAvailable` (reclaimable cache included). Darwin sums free +
inactive + speculative pages. A fallback of `_SC_AVPHYS_PAGES` is used only
when the platform-specific probe is silent.
*/
ulong hwAvailableMemoryBytes() @trusted nothrow @nogc
{
    version (linux)
    {
        char[2048] buf = void;
        auto s = readSmallFile("/proc/meminfo", buf[]);
        const kb = parseMeminfoKb(s, "MemAvailable");
        if (kb > 0)
            return kb * 1024;
    }
    else version (OSX)
    {
        const page = sysctlULong("hw.pagesize");
        if (page > 0)
        {
            const pages = sysctlULong("vm.page_free_count")
                + sysctlULong("vm.page_inactive_count")
                + sysctlULong("vm.page_speculative_count");
            if (pages > 0)
                return pages * page;
        }
    }

    version (Posix)
    {
        import core.sys.posix.unistd : _SC_AVPHYS_PAGES, _SC_PAGESIZE, sysconf;

        const pages = sysconf(_SC_AVPHYS_PAGES);
        const page = sysconf(_SC_PAGESIZE);
        if (pages > 0 && page > 0)
            return cast(ulong) pages * cast(ulong) page;
    }
    return 0;
}

/// Swap currently in use, in bytes. 0 when there is no swap, none is used,
/// or the figure cannot be read.
ulong hwSwapUsedBytes() @trusted nothrow @nogc
{
    version (linux)
    {
        char[2048] buf = void;
        auto s = readSmallFile("/proc/meminfo", buf[]);
        const total = parseMeminfoKb(s, "SwapTotal");
        const free_ = parseMeminfoKb(s, "SwapFree");
        if (total >= free_)
            return (total - free_) * 1024;
    }
    else version (OSX)
    {
        XswUsage xsw;
        size_t n = xsw.sizeof;
        if (sysctlbyname("vm.swapusage", &xsw, &n, null, 0) == 0
            && n >= XswUsage.xsu_used.offsetof + ulong.sizeof)
            return xsw.xsu_used;
    }
    return 0;
}

/// Sentinel for $(LREF hwLoadAverageCenti): the 1-minute load average could
/// not be read. Distinct from a genuine 0.00 load.
enum uint hwLoadUnknown = uint.max;

/**
1-minute load average in hundredths of a CPU (`250` = 2.50), or
$(LREF hwLoadUnknown).
*/
uint hwLoadAverageCenti() @trusted nothrow @nogc
{
    version (Posix)
    {
        double[3] load = void;
        if (getloadavg(load.ptr, 1) >= 1 && load[0] >= 0)
        {
            const c = load[0] * 100.0 + 0.5;
            if (c >= hwLoadUnknown)
                return hwLoadUnknown - 1;
            return cast(uint) c;
        }
    }
    return hwLoadUnknown;
}

/**
Fold memory pressure, swap, and load into a CPU count so a pool is not
wider than the host can usefully run.

$(LIST
    * Below 2 GiB available → at most 1 worker; below 4 GiB → at most 2.
        That is the GitHub-hosted macOS shape (~7 GiB advertised, often half
        of it already gone) and any ballooned VM. Above 4 GiB this clamp is
        silent — a 16-core workstation is not punished for having RAM.
    * ≥ 1 GiB of swap in use *and* less than 8 GiB available → at most 2
        workers. Already paging *and* tight on RAM; more workers make it
        worse. Swap alone is not a signal: a workstation with tens of GiB
        free will happily hold idle pages on swap.
    * A 1-minute load of `L` on `N` CPUs leaves `max(1, N - floor(L))`
        spare workers. Inside a VM this is the *guest* load (other guests
        on the host do not appear), so it catches "this VM is already busy"
        rather than hypervisor steal.
)

Unknown inputs (`availableBytes == 0`, `loadCenti == hwLoadUnknown`) are
skipped, never treated as zero. The result is never less than 1 and never
greater than `cpuCount` (or 1 when `cpuCount` is 0).
*/
uint applyResourceCaps(
    uint cpuCount,
    ulong availableBytes,
    uint loadCenti,
    ulong swapUsedBytes = 0,
) @safe pure nothrow @nogc
{
    uint n = cpuCount > 0 ? cpuCount : 1;

    if (availableBytes > 0)
    {
        uint memCap = uint.max;
        if (availableBytes < (2UL << 30))
            memCap = 1;
        else if (availableBytes < (4UL << 30))
            memCap = 2;
        if (memCap < n)
            n = memCap;
    }

    // Swap-in-use only bites when RAM is also tight. A 60 GiB workstation
    // with some swapped-out idle pages is not the GitHub-macOS case.
    if (swapUsedBytes >= (1UL << 30)
        && availableBytes > 0 && availableBytes < (8UL << 30) && n > 2)
        n = 2;

    if (loadCenti != hwLoadUnknown && cpuCount > 0)
    {
        const busy = loadCenti / 100;
        const spare = cpuCount > busy ? cpuCount - busy : 1;
        if (spare < n)
            n = spare;
    }

    return n > 0 ? n : 1;
}

@("base.hw_caps.applyResourceCaps.memoryLoadAndSwap")
@safe pure nothrow @nogc
unittest
{
    // No extra info: the CPU count stands (or 1, when the caller had none).
    assert(applyResourceCaps(8, 0, hwLoadUnknown) == 8);
    assert(applyResourceCaps(0, 0, hwLoadUnknown) == 1);

    // Tight available RAM — the GitHub-hosted macOS case.
    assert(applyResourceCaps(8, 3UL << 30, hwLoadUnknown) == 2); // 3 GiB
    assert(applyResourceCaps(8, (2UL << 30) - 1, hwLoadUnknown) == 1);
    assert(applyResourceCaps(8, 8UL << 30, hwLoadUnknown) == 8); // 8 GiB: no clamp

    // Swap + less than 8 GiB free: do not keep a wide pool. Swap with
    // plenty of RAM is ignored (idle pages on a workstation).
    assert(applyResourceCaps(8, 5UL << 30, hwLoadUnknown, 1UL << 30) == 2);
    assert(applyResourceCaps(8, 16UL << 30, hwLoadUnknown, 1UL << 30) == 8);
    assert(applyResourceCaps(1, 5UL << 30, hwLoadUnknown, 1UL << 30) == 1);

    // Load 0.10 on 4 CPUs → 4 spare; load 2.50 → 2 spare; load 8.00 → 1.
    assert(applyResourceCaps(4, 0, 10) == 4);
    assert(applyResourceCaps(4, 0, 250) == 2);
    assert(applyResourceCaps(4, 0, 800) == 1);

    // The tightest cap wins.
    assert(applyResourceCaps(8, 3UL << 30, 800) == 1);
}

private:

version (Posix)
{
    extern (C) int getloadavg(double* loadavg, int nelem) @nogc nothrow;
}

version (OSX)
{
    extern (C) int sysctlbyname(
        const(char)* name, void* oldp, size_t* oldlenp, void* newp, size_t newlen,
    ) @nogc nothrow;

    /// `struct xsw_usage` from Darwin's `sys/vmmeter.h`.
    struct XswUsage
    {
        ulong xsu_total;
        ulong xsu_avail;
        ulong xsu_used;
        uint xsu_pagesize;
        int xsu_encrypted;
    }

    ulong sysctlULong(const(char)* name) @trusted nothrow @nogc
    {
        ulong v;
        size_t n = v.sizeof;
        if (sysctlbyname(name, &v, &n, null, 0) != 0 || n == 0)
            return 0;
        if (n == 8)
            return v;
        if (n == 4)
            return *cast(uint*)&v;
        return 0;
    }
}

version (linux)
{
    import core.sys.linux.sched : cpu_set_t;

    /// Bits the mask covers. druntime does not export `__CPU_SETSIZE`, but the
    /// struct it sizes is exactly that many bits wide.
    enum size_t cpuSetBits = cpu_set_t.sizeof * 8;
}

/// CPUs this process is permitted to run on, or 0 when that cannot be answered.
uint allowedCpuCount() @trusted nothrow @nogc
{
    version (linux)
    {
        import core.sys.linux.sched : CPU_COUNT, cpu_set_t, sched_getaffinity;

        cpu_set_t set;
        if (sched_getaffinity(0, cpu_set_t.sizeof, &set) == 0)
        {
            const n = CPU_COUNT(&set);
            if (n > 0)
                return cast(uint) n;
        }
    }
    return onlineCpuCount();
}

/// Online CPUs, the floor every platform can answer.
uint onlineCpuCount() @trusted nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.unistd : _SC_NPROCESSORS_ONLN, sysconf;

        const n = sysconf(_SC_NPROCESSORS_ONLN);
        return n > 0 ? cast(uint) n : 0;
    }
    else
        return 0;
}

/**
CPUs a cgroup CPU quota pays for, rounded up, or 0 when unquota'd.

$(B The limit is not at the root.) A process is charged against $(I its own)
cgroup, named on the `0::` line of `/proc/self/cgroup`, and a limit set on any
ancestor applies to it too — so the effective quota is the tightest `cpu.max` on
the chain from that cgroup up to the root. Reading `/sys/fs/cgroup/cpu.max`
alone finds nothing: the root cgroup has no such file, which reads as
"unquota'd" for every process on the machine.

cgroup v2 states it as `"<quota> <period>"` (or `"max <period>"`) in one file;
v1 splits it across two, with `-1` for unlimited. A partial CPU rounds **up**: a
half-CPU quota still needs one worker to use it.
*/
uint quotaCpuCount() @trusted nothrow @nogc
{
    version (linux)
    {
        char[256] relBuf = void;
        auto rel = cgroupV2Path(relBuf[]);
        if (rel.length)
        {
            uint tightest = 0;
            for (;;)
            {
                const q = readCpuMaxAt(rel);
                if (q > 0 && (tightest == 0 || q < tightest))
                    tightest = q;
                if (rel.length <= 1)
                    break;
                rel = parentCgroup(rel);
            }
            if (tightest > 0)
                return tightest;
        }

        // cgroup v1: two files, -1 for unlimited. Left at the conventional
        // mount point — v1 hosts that also nest quotas are rare enough that the
        // walk above is not worth duplicating for a legacy layout.
        char[32] qbuf = void, pbuf = void;
        auto qs = readSmallFile("/sys/fs/cgroup/cpu/cpu.cfs_quota_us", qbuf[]);
        auto ps = readSmallFile("/sys/fs/cgroup/cpu/cpu.cfs_period_us", pbuf[]);
        if (qs.length && ps.length && qs[0] != '-')
            return quotaToCpus(readULong(qs), readULong(ps));
    }
    return 0;
}

/// `ceil(quota / period)`, guarding a zero or absent period.
uint quotaToCpus(ulong quota, ulong period) @safe pure nothrow @nogc
{
    if (quota == 0 || period == 0)
        return 0;
    const n = (quota + period - 1) / period;
    return n > uint.max ? uint.max : cast(uint) n;
}

@("base.hw_caps.quotaToCpus.roundsPartialCpusUp")
@safe pure nothrow @nogc
unittest
{
    enum period = 100_000;

    assert(quotaToCpus(200_000, period) == 2); // exactly two CPUs
    assert(quotaToCpus(250_000, period) == 3); // 2.5 → a third worker uses the rest
    assert(quotaToCpus(50_000, period) == 1);  // half a CPU still needs one worker
    assert(quotaToCpus(1, period) == 1);       // never rounds down to zero workers

    // "Unquota'd" and "malformed" both mean "no answer", not "no CPUs".
    assert(quotaToCpus(0, period) == 0);
    assert(quotaToCpus(200_000, 0) == 0);
}

version (linux)
{
    /// This process's cgroup-v2 path, from the `0::<path>` line of
    /// `/proc/self/cgroup`. Empty when the host is v1-only (no unified line).
    const(char)[] cgroupV2Path(char[] buf) @system nothrow @nogc
    {
        char[512] raw = void;
        auto s = readSmallFile("/proc/self/cgroup", raw[]);
        while (s.length)
        {
            // One record per line: "<hier>:<controllers>:<path>". The unified
            // v2 hierarchy is the one with an empty controller list: "0::".
            size_t eol = 0;
            while (eol < s.length && s[eol] != '\n')
                ++eol;
            auto line = s[0 .. eol];
            s = eol < s.length ? s[eol + 1 .. $] : null;

            if (line.length > 3 && line[0 .. 3] == "0::")
            {
                auto path = line[3 .. $];
                if (path.length == 0 || path.length > buf.length)
                    return null;
                buf[0 .. path.length] = path[];
                return buf[0 .. path.length];
            }
        }
        return null;
    }

    /// `rel` minus its last component: `/a/b` → `/a`, `/a` → `/`.
    const(char)[] parentCgroup(return scope const(char)[] rel) @safe pure nothrow @nogc
    {
        size_t i = rel.length - 1;
        while (i > 0 && rel[i] != '/')
            --i;
        return i == 0 ? rel[0 .. 1] : rel[0 .. i];
    }

    /// Parses `/sys/fs/cgroup<rel>/cpu.max`, or 0 when absent/unlimited.
    uint readCpuMaxAt(scope const(char)[] rel) @system nothrow @nogc
    {
        import sparkles.base.text.cstring : CString, tryToCString;

        enum root = "/sys/fs/cgroup";
        enum leaf = "/cpu.max";

        // A `rel` of "/" would double the separator; harmless on Linux, but
        // keep the path canonical so a failure is legible in strace.
        CString!320 path;
        const built = rel.length == 1 && rel[0] == '/'
            ? tryToCString(path, [root, leaf])
            : tryToCString(path, [root, rel, leaf]);
        if (!built)
            return 0;

        char[64] buf = void;
        auto v = readSmallFile(path.ptr, buf[]);
        if (v.length == 0 || (v.length >= 3 && v[0 .. 3] == "max"))
            return 0;
        const q = readULong(v);
        skipSpaces(v);
        const p = readULong(v);
        return quotaToCpus(q, p);
    }

    @("base.hw_caps.parentCgroup.walksToTheRoot")
    @safe pure nothrow @nogc
    unittest
    {
        // A quota set on any ancestor applies, so the walk must reach the root.
        assert(parentCgroup("/user.slice/app.scope") == "/user.slice");
        assert(parentCgroup("/user.slice") == "/");
        assert(parentCgroup("/") == "/"); // terminal — the caller stops here
    }

    /// Reads a small pseudo-file into `buf`, returning the slice read (empty on
    /// any failure). `@nogc`, so no `std.file`.
    const(char)[] readSmallFile(scope const(char)* path, char[] buf) @system nothrow @nogc
    {
        import core.sys.posix.fcntl : O_RDONLY, open;
        import core.sys.posix.unistd : close, read;

        const fd = open(path, O_RDONLY);
        if (fd < 0)
            return null;
        scope (exit)
            cast(void) close(fd);

        const n = read(fd, buf.ptr, buf.length);
        return n > 0 ? cast(const(char)[]) buf[0 .. n] : null;
    }
}

/// Leading unsigned decimal, advancing `s`. Non-digits stop it.
ulong readULong(ref const(char)[] s) @safe pure nothrow @nogc
{
    ulong v;
    while (s.length && s[0] >= '0' && s[0] <= '9')
    {
        v = v * 10 + (s[0] - '0');
        s = s[1 .. $];
    }
    return v;
}

void skipSpaces(ref const(char)[] s) @safe pure nothrow @nogc
{
    while (s.length && (s[0] == ' ' || s[0] == '\t'))
        s = s[1 .. $];
}

/**
Kilobyte value of `key:` in a `/proc/meminfo` blob, or 0 when the key is
absent. `key` is the label without the colon (`"MemAvailable"`).
*/
ulong parseMeminfoKb(scope const(char)[] text, scope const(char)[] key)
    @safe pure nothrow @nogc
{
    auto s = text;
    while (s.length)
    {
        size_t eol = 0;
        while (eol < s.length && s[eol] != '\n')
            ++eol;
        auto line = s[0 .. eol];
        s = eol < s.length ? s[eol + 1 .. $] : null;

        if (line.length <= key.length || line[0 .. key.length] != key
            || line[key.length] != ':')
            continue;
        auto rest = line[key.length + 1 .. $];
        skipSpaces(rest);
        return readULong(rest);
    }
    return 0;
}

@("base.hw_caps.readULong.parsesCgroupPairs")
@safe pure nothrow @nogc
unittest
{
    // The shape cgroup v2 writes: two numbers separated by a space.
    const(char)[] s = "200000 100000\n";
    assert(readULong(s) == 200_000);
    skipSpaces(s);
    assert(readULong(s) == 100_000);

    // A non-numeric field yields 0 without advancing, which `quotaToCpus`
    // then reads as "no answer" rather than as a zero-CPU quota.
    const(char)[] m = "max 100000\n";
    assert(readULong(m) == 0);
    assert(m.length == "max 100000\n".length);
}

@("base.hw_caps.parseMeminfoKb.readsAvailableAndSwap")
@safe pure nothrow @nogc
unittest
{
    enum sample =
        "MemTotal:       16384000 kB\n" ~
        "MemAvailable:    4096000 kB\n" ~
        "SwapTotal:       2048000 kB\n" ~
        "SwapFree:        1024000 kB\n";
    assert(parseMeminfoKb(sample, "MemAvailable") == 4_096_000);
    assert(parseMeminfoKb(sample, "SwapTotal") == 2_048_000);
    assert(parseMeminfoKb(sample, "SwapFree") == 1_024_000);
    assert(parseMeminfoKb(sample, "Nope") == 0);
    assert(parseMeminfoKb("", "MemAvailable") == 0);
}

@("base.hw_caps.hwParallelism.isAtLeastOneAndNoWiderThanOnline")
@safe nothrow @nogc
unittest
{
    const n = hwParallelism();
    assert(n >= 1, "a machine always has at least one usable CPU");

    // The whole point: never *wider* than what the OS says exists. A quota,
    // an affinity mask, tight RAM, or a high load may make it narrower;
    // nothing may make it wider.
    const online = onlineCpuCount();
    if (online > 0)
        assert(n <= online);
    assert(hwOnlineCpuCount() == online);
}

@("base.hw_caps.hwMemoryBytes.reportsThisHost")
@safe nothrow @nogc
unittest
{
    version (Posix)
    {
        const n = hwMemoryBytes();
        assert(n >= (64UL << 20), "a POSIX host has at least 64 MiB of RAM");
        const avail = hwAvailableMemoryBytes();
        // Available can be 0 if the probe failed; when it works it cannot
        // exceed total.
        if (avail > 0)
            assert(avail <= n);
        const load = hwLoadAverageCenti();
        assert(load == hwLoadUnknown || load < 100_000);
    }
}

@("base.hw_caps.nthAllowedCpu.wrapsAndStaysInsideTheMask")
@safe nothrow @nogc
unittest
{
    // The wrap is over the CPUs we may use — NOT over `hwParallelism()`, which
    // a quota can pull below it. Getting this modulus wrong stacks every worker
    // of a quota-limited pool onto the first few CPUs.
    const n = allowedCpuCount();
    if (n == 0)
        return;

    // Wrapping is the caller's convenience: more workers than CPUs is legal.
    assert(nthAllowedCpu(0) == nthAllowedCpu(n * 3));

    // Every answer must be a CPU we may actually be scheduled on. On Linux that
    // is checkable directly against the mask; elsewhere the identity is all
    // there is to check.
    version (linux)
    {
        import core.sys.linux.sched : CPU_ISSET, cpu_set_t, sched_getaffinity;

        cpu_set_t set;
        if ((() @trusted => sched_getaffinity(0, cpu_set_t.sizeof, &set))() == 0)
            foreach (i; 0 .. n)
            {
                const cpu = nthAllowedCpu(i);
                assert((() @trusted => CPU_ISSET(cpu, &set))(),
                    "pinning target is outside the process's affinity mask");
            }
    }
}
