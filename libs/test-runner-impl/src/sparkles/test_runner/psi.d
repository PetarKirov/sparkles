/**
 * Pressure-stall information (PSI): the kernel's stall-time integrals.
 *
 * `/proc/pressure/{io,memory,cpu}` each expose monotonic `total=<µs>`
 * accumulators — the time some (≥ 1) / all non-idle tasks were stalled on
 * that resource since boot — plus decaying averages this module deliberately
 * ignores (SPEC §4: the window delta of the monotonic total IS the stall
 * integral; the averages are UI sugar with a decay horizon).
 *
 * Scope honesty: the `/proc/pressure` files are $(B system-wide). A window
 * delta says "the system accumulated this much stall concurrently with the
 * window" — context that explains a large residual (noisy neighbor vs own
 * blocking), never an attribution to the measured thread. The workload
 * layer therefore reports these as diagnostics (`psi` object, `io-stall`
 * column) and leaves `WallDecomposition.offCpuDisk` unattributed until
 * M8's cgroup-scoped `*.pressure` (same file shape — `parsePsiFile` is
 * reused verbatim there) makes per-workload attribution real.
 *
 * `CONFIG_PSI=n` kernels (or `psi=0` boots) have no `/proc/pressure`; the
 * source degrades to a reasoned capability absence, never fails a run.
 */
module sparkles.test_runner.psi;

import sparkles.test_runner.capability : Capability, CapabilityAbsence,
    CapabilityReport;

/// One pressure file's monotonic stall totals, in µs. `fullUs == -1` marks
/// a missing `full` line (pre-5.13 kernels lack it for cpu); `ok == false`
/// means the file was unreadable or unparsable.
struct PsiFileReading
{
    long someUs = -1;
    long fullUs = -1;
    bool ok;
}

/// One instant's readings across `/proc/pressure/{io,memory,cpu}`.
struct PsiReading
{
    PsiFileReading io;
    PsiFileReading memory;
    PsiFileReading cpu;
}

/// Parses one pressure file's content: per line, `some|full avg10=… avg60=…
/// avg300=… total=<µs>`. Only the monotonic totals are read; a reading is
/// `ok` when the `some` line parsed (the `full` line is optional). M8's
/// per-cgroup `io.pressure` has the identical shape and reuses this.
PsiFileReading parsePsiFile(scope const(char)[] content) @safe pure nothrow @nogc
{
    PsiFileReading r;
    size_t i;
    while (i < content.length)
    {
        // Line label: "some" or "full".
        const isSome = matches(content, i, "some");
        const isFull = !isSome && matches(content, i, "full");
        // Scan the line for "total=" and parse its integer.
        long total = -1;
        while (i < content.length && content[i] != '\n')
        {
            if ((isSome || isFull) && matches(content, i, "total="))
            {
                i += 6;
                if (i < content.length && content[i] >= '0' && content[i] <= '9')
                {
                    total = 0;
                    while (i < content.length && content[i] >= '0' && content[i] <= '9')
                    {
                        total = total * 10 + (content[i] - '0');
                        i++;
                    }
                }
                continue;
            }
            i++;
        }
        if (i < content.length)
            i++; // consume '\n'
        if (isSome && total >= 0)
        {
            r.someUs = total;
            r.ok = true;
        }
        else if (isFull && total >= 0)
            r.fullUs = total;
    }
    if (!r.ok)
        r.fullUs = -1; // a full line without a some line is not a valid reading
    return r;
}

/// Whether `content[i ..]` starts with `word` (bounds-checked prefix test).
private bool matches(scope const(char)[] content, size_t i, string word)
    @safe pure nothrow @nogc
{
    if (i + word.length > content.length)
        return false;
    return content[i .. i + word.length] == word;
}

@("psi.parsePsiFile.realShapes")
@safe pure nothrow @nogc
unittest
{
    // The live /proc/pressure/io shape (values from the dev box).
    const io = parsePsiFile("some avg10=83.80 avg60=83.62 avg300=82.70 total=3960524451711\n"
        ~ "full avg10=77.31 avg60=76.70 avg300=74.71 total=3736825779413\n");
    assert(io.ok);
    assert(io.someUs == 3_960_524_451_711);
    assert(io.fullUs == 3_736_825_779_413);

    // cpu's full line is pinned to total=0 at system scope.
    const cpu = parsePsiFile("some avg10=0.00 avg60=0.00 avg300=0.28 total=10504111166\n"
        ~ "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n");
    assert(cpu.ok);
    assert(cpu.someUs == 10_504_111_166);
    assert(cpu.fullUs == 0);

    // Pre-5.13 kernels: cpu has no full line at all.
    const old = parsePsiFile("some avg10=0.00 avg60=0.00 avg300=0.00 total=42\n");
    assert(old.ok);
    assert(old.someUs == 42);
    assert(old.fullUs == -1, "an absent full line stays -1");
}

@("psi.parsePsiFile.rejectsGarbage")
@safe pure nothrow @nogc
unittest
{
    assert(!parsePsiFile("").ok);
    assert(!parsePsiFile("garbage\n").ok);
    assert(!parsePsiFile("some avg10=0.00 avg60=0.00 avg300=0.00\n").ok,
        "a some line without total= is not a reading");
    assert(!parsePsiFile("some avg10=0.00 total=\n").ok, "total= with no digits");
    assert(!parsePsiFile("full avg10=0.00 total=5\n").ok,
        "a full line without a some line is not a valid reading");
    // The decaying averages must never be mistaken for the total.
    const avgOnly = parsePsiFile("some avg10=99.99 avg60=99.99 avg300=99.99 total=7\n");
    assert(avgOnly.someUs == 7);
    // Truncated mid-total: the digits read so far still parse (a torn /proc
    // read yields a shorter-but-valid prefix, and the delta stays sane).
    const truncated = parsePsiFile("some avg10=0.00 total=123");
    assert(truncated.ok && truncated.someUs == 123);
    // No trailing newline on the last line.
    const noNl = parsePsiFile("some avg10=0.00 total=5\nfull avg10=0.00 total=3");
    assert(noNl.someUs == 5 && noNl.fullUs == 3);
}

/// The PSI diagnostic source: snapshot-shaped like `WallSource` (it has no
/// counting pass and never enters `CounterGroups` — window edges only).
struct PsiSource
{
    private bool enabled;
    private bool ok_;

    private static immutable CapabilityAbsence[1] notRequestedAbsence = [
        CapabilityAbsence(Capability.counting, "not requested"),
    ];
    private static immutable CapabilityAbsence[1] noPsiAbsence = [
        CapabilityAbsence(Capability.counting,
            "/proc/pressure/io unreadable — CONFIG_PSI=n or psi=0 boot"),
    ];
    private static immutable CapabilityAbsence[1] stubAbsence = [
        CapabilityAbsence(Capability.counting, "not Linux"),
    ];

    /// Whether the pressure files are readable on this host.
    bool available() const @safe pure nothrow @nogc => enabled && ok_;

    /// Human-readable availability, for a report header.
    string status() const @safe pure nothrow
    {
        if (available)
            return "system-wide stall integrals (/proc/pressure)";
        if (!enabled)
            return "unavailable (not requested)";
        version (linux)
            return "unavailable (/proc/pressure/io unreadable — CONFIG_PSI=n or psi=0 boot)";
        else
            return "unavailable (not Linux)";
    }

    /// What this source can deliver: scalar counting of stall time. Unlike
    /// schedstat inside `WallSource`, PSI absence covers the whole source,
    /// so it is a proper reasoned `CapabilityAbsence` (SPEC §6.2).
    CapabilityReport capabilities() const @safe nothrow
    {
        if (available)
            return CapabilityReport(Capability.counting, null);
        if (!enabled)
            return CapabilityReport(Capability.none, notRequestedAbsence[]);
        version (linux)
            return CapabilityReport(Capability.none, noPsiAbsence[]);
        else
            return CapabilityReport(Capability.none, stubAbsence[]);
    }

    /// Opens the source unless disabled; probes `/proc/pressure/io`'s
    /// readability (and parsability) once.
    static PsiSource tryOpen(bool enabled) @safe nothrow
    {
        PsiSource s;
        s.enabled = enabled;
        if (!enabled)
            return s;
        version (linux)
        {
            import sparkles.test_runner.capability : readSmallFile;

            char[256] buf = void;
            s.ok_ = parsePsiFile(readSmallFile("/proc/pressure/io", buf[])).ok;
        }
        return s;
    }

    /// Releases nothing — the source holds no descriptors.
    void close() @safe pure nothrow @nogc
    {
    }

    /// Captures one window-edge reading across all three pressure files.
    PsiReading snapshot() const @safe nothrow @nogc
    {
        PsiReading r;
        version (linux)
        {
            import sparkles.test_runner.capability : readSmallFile;

            if (!available)
                return r;
            char[256] buf = void;
            r.io = parsePsiFile(readSmallFile("/proc/pressure/io", buf[]));
            r.memory = parsePsiFile(readSmallFile("/proc/pressure/memory", buf[]));
            r.cpu = parsePsiFile(readSmallFile("/proc/pressure/cpu", buf[]));
        }
        return r;
    }
}

@("psi.PsiSource.notRequested")
@safe
unittest
{
    import sparkles.test_runner.capability : has, reasonFor;

    const off = PsiSource.tryOpen(false);
    assert(!off.available);
    assert(!off.capabilities.has(Capability.counting));
    assert(off.capabilities.reasonFor(Capability.counting) == "not requested");
    assert(off.status == "unavailable (not requested)");
}

version (linux)
{
    @("psi.PsiSource.liveSnapshotMonotonic")
    @system
    unittest
    {
        import sparkles.test_runner.skip : skipTest;

        auto s = PsiSource.tryOpen(true);
        scope (exit)
            s.close();
        if (!s.available)
            skipTest(s.status()); // CONFIG_PSI=n / psi=0

        const a = s.snapshot();
        static ulong sink;
        foreach (i; 0 .. 200_000)
            sink += i * i;
        const b = s.snapshot();

        assert(a.io.ok && b.io.ok);
        assert(a.io.someUs >= 0);
        assert(b.io.someUs >= a.io.someUs, "the total is monotonic");
        assert(b.memory.ok && b.cpu.ok, "all three files read on a PSI host");
        assert(b.cpu.someUs >= a.cpu.someUs);
    }
}
