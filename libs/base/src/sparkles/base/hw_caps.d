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

The smaller of "CPUs we are allowed to run on" and "CPUs our quota pays for",
never less than 1. On a host with neither restriction this is the online CPU
count, so it is a safe drop-in for `std.parallelism.totalCPUs`.
*/
uint hwParallelism() @trusted nothrow @nogc
{
    const allowed = allowedCpuCount();
    const quota = quotaCpuCount();
    const n = quota > 0 && quota < allowed ? quota : allowed;
    return n > 0 ? n : 1;
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

private:

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
}

@("base.hw_caps.hwParallelism.isAtLeastOneAndNoWiderThanOnline")
@safe nothrow @nogc
unittest
{
    const n = hwParallelism();
    assert(n >= 1, "a machine always has at least one usable CPU");

    // The whole point: never *wider* than what the OS says exists. A quota or
    // an affinity mask may make it narrower; nothing may make it wider.
    const online = onlineCpuCount();
    if (online > 0)
        assert(n <= online);
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
