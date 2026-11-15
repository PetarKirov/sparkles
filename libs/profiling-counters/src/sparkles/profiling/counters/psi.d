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
module sparkles.profiling.counters.psi;

import sparkles.profiling.counters.capability : Capability, CapabilityAbsence,
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
///
/// Torn reads are REJECTED, not truncated: a total's digit run must be
/// terminated by a further character (the kernel always ends lines with
/// `\n`), because a digit run cut at end-of-buffer is a valid-looking but
/// wrong prefix — a torn BEFORE edge would otherwise fabricate a
/// near-boot-sized "stall delta" that passes every downstream gate.
PsiFileReading parsePsiFile(scope const(char)[] content) @safe pure nothrow @nogc
{
    PsiFileReading r;
    size_t i;
    while (i < content.length)
    {
        // Line label: "some " or "full " (the trailing space rejects glued
        // tokens like "sometotal=").
        const isSome = matches(content, i, "some ");
        const isFull = !isSome && matches(content, i, "full ");
        // Scan the line for "total=" and parse its integer.
        long total = -1;
        while (i < content.length && content[i] != '\n')
        {
            if ((isSome || isFull) && matches(content, i, "total="))
            {
                i += 6;
                size_t digits;
                long value = 0;
                while (i < content.length && content[i] >= '0' && content[i] <= '9')
                {
                    value = value * 10 + (content[i] - '0');
                    digits++;
                    i++;
                }
                // Valid only when non-empty, in range (a real total is
                // ~13 digits; 19+ overflows long), and terminated — a run
                // ending exactly at end-of-buffer may be torn.
                if (digits > 0 && digits < 19 && i < content.length)
                    total = value;
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

/// The PSI diagnostic source: snapshot-shaped like `WallSource` (it has no
/// counting pass and never enters `CounterGroups` — window edges only).
struct PsiSource
{
    private bool enabled;
    private bool ok_; /// /proc/pressure/io readable+parsable (the availability gate)
    private bool memOk_; /// memory/cpu probed separately: a hardened /proc can
    private bool cpuOk_; /// mask files individually, and ✓ must not overclaim

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

    /// Human-readable availability, for a report header. A partially-masked
    /// /proc (io readable, memory/cpu not — ProtectProc=, lxcfs) is
    /// disclosed here so the block's ✓ never silently overclaims all three
    /// files; the masked files' window deltas read nan.
    string status() const @safe pure nothrow
    {
        if (available)
        {
            if (memOk_ && cpuOk_)
                return "system-wide stall integrals (/proc/pressure)";
            if (!memOk_ && !cpuOk_)
                return "system-wide stall integrals (/proc/pressure; io only — memory/cpu unreadable)";
            return memOk_
                ? "system-wide stall integrals (/proc/pressure; cpu unreadable)"
                : "system-wide stall integrals (/proc/pressure; memory unreadable)";
        }
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

    /// Opens the source unless disabled; probes each pressure file's
    /// readability (and parsability) once — per file, because a hardened
    /// /proc can mask them individually.
    static PsiSource tryOpen(bool enabled) @safe nothrow
    {
        PsiSource s;
        s.enabled = enabled;
        if (!enabled)
            return s;
        version (linux)
        {
            import sparkles.profiling.counters.capability : readSmallFile;

            char[256] buf = void;
            s.ok_ = parsePsiFile(readSmallFile("/proc/pressure/io", buf[])).ok;
            s.memOk_ = parsePsiFile(readSmallFile("/proc/pressure/memory", buf[])).ok;
            s.cpuOk_ = parsePsiFile(readSmallFile("/proc/pressure/cpu", buf[])).ok;
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
            import sparkles.profiling.counters.capability : readSmallFile;

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

version (linux)
{
}
